"""推资源包（tools/push_pack.py，Mac / Windows 共用，11-06 两端合一）：假设备（内存里的 App 容器）上核口径。期望按文件头规则手写，不跑被测实现推导。
Mac 的整条 dev_run 推包回归（假 devicectl）在 tests/dev_run_test.sh，本文件只核规则本身与 Windows 那支（原 tests/oneclick_win_test.py 推包几组搬来）"""
import hashlib, json, os, struct, sys, tempfile, time, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import push_pack as push

RP, INC = "Documents/资源包", "Documents/资源包/.incoming"
WHOLE = b"x" * 512 + b"\0" * 1024   # 推完整的批：512 整倍、末尾 1024 字节全零（同 pack_apply.c 契约 ③）


def sha(b): return hashlib.sha256(b).hexdigest()


class Fake:
    """内存里的 App 容器：get / put / ls / tar_ok / put_tar / listing / free / nospc 同 push.Devpush 接口"""
    kind = "fake"; why = "假设备"; docs = "Documents"; ctx = None; pack = None

    def __init__(self, files, listing=False, full_disk=False):
        self.files = dict(files); self.puts = []; self.lists = []; self.list_ok = listing; self.full_disk = full_disk

    def get(self, rel, dst, t=None):
        v = self.files.get(rel)
        if v is None: return False
        Path(dst).write_bytes(v if isinstance(v, bytes) else v.encode()); return True

    def put(self, src, rel):
        self.puts.append(rel); self.files[rel] = Path(src).read_bytes()

    def ls(self, rel): return [k[len(rel) + 1:] for k in self.files if k.startswith(rel + "/") and "/" not in k[len(rel) + 1:]]

    def tar_ok(self, rel):
        v = self.files.get(rel, b""); return len(v) >= 1024 and len(v) % 512 == 0 and v[-1024:] == b"\0" * 1024

    def put_tar(self, lst, root, rel):
        if self.full_disk: raise push.Fail("写不进去")
        self.puts.append(rel); self.lists.append(Path(lst).read_text(encoding="utf-8").split()); self.files[rel] = WHOLE; return "stream"

    def listing(self): return {k[len(RP) + 1:]: len(v) for k, v in self.files.items() if k.startswith(RP + "/")} if self.list_ok else None

    def free(self): return None

    def nospc(self): return self.full_disk

    def launch(self, env):   # 起 App：按 on_launch 模拟解包（写 .applied / 解包日志），记下环境
        self.launches = getattr(self, "launches", []) + [env]
        if getattr(self, "on_launch", None): self.on_launch(self)


class Base(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); d = Path(self.td.name)
        self.pk = d / "pack"; self.pk.mkdir(); self.w = d / "w"; self.w.mkdir()
        self.data = {"a": b"A", "b": b"BB"}
        for k, v in self.data.items(): (self.pk / k).write_bytes(v)
        (self.pk / "index.tsv").write_text("".join(f"{k}\t{len(v)}\t{sha(v)}\n" for k, v in self.data.items()))
        (self.pk / "manifest.json").write_text('{"version": 2, "index_sha256": "x"}')
        self.log = []

    def tearDown(self): self.td.cleanup()

    def row(self, k): return f"{k}\t{len(self.data[k])}\t{sha(self.data[k])}\n"

    def on_phone(self, *keys, applied=True):   # 机上已解开 keys（文件在、已应用索引记着）
        f = {f"{RP}/manifest.json": '{"version": 2}', f"{RP}/{'index.applied.tsv' if applied else 'index.tsv'}": "".join(self.row(k) for k in keys)}
        f.update({f"{RP}/{k}": self.data[k] for k in keys}); return f

    def go(self, files, full=False, **kw):
        self.dev = Fake(files, **kw)
        return push.run(self.dev, self.pk, self.w, full, say=self.log.append)


class PlanRules(Base):
    def test_batches_cap(self):   # ≤ 上限一批（不超过）；单个超限的文件自成一批；按 index.tsv 顺序
        rows = [["a", "30", "1"], ["b", "30", "2"], ["c", "50", "3"], ["d", "10", "4"], ["e", "90", "5"]]
        old = push.LIM; push.LIM = 60
        try: self.assertEqual([[w[0] for w in b] for b in push.batches_of(self.pk, rows)], [["a", "b"], ["c", "d"], ["e"]])
        finally: push.LIM = old

    def test_new_phone_pushes_all(self):
        self.assertEqual(self.go({})[:2], (1, 2)); self.assertEqual(self.dev.lists, [["a", "b"]])
        self.assertEqual(self.dev.files[f"{RP}/.pushed"].decode(), f"a\t{sha(b'A')}\nb\t{sha(b'BB')}\n")   # 推完这批即记账
        self.assertEqual(self.dev.puts[-2:], [f"{RP}/index.tsv", f"{RP}/manifest.json"])                   # 最后推索引与清单
        # 开推第一件事把机上清单置空（11-09 根修：「清单读得出」= 推送完整，App 据此分清「传完只等解开」和「传断了」）；
        #   在它之前只有推前探针（#333，几字节，不动清单）和给手机游戏库画蒙版的传输清单
        self.assertEqual(self.dev.puts[:3], [f"{RP}/{push.PROBE}", f"{RP}/.transfer", f"{RP}/manifest.json"])
        self.assertEqual(self.dev.files[f"{RP}/manifest.json"], (self.pk / "manifest.json").read_bytes())       # 最后写回的是本包清单

    def test_nothing_to_push_keeps_manifest(self):   # 机上已有全部文件（已应用）、没东西推：不把机上清单置空
        self.go(self.on_phone("a", "b"))
        self.assertNotIn(b"", [self.dev.files.get(f"{RP}/manifest.json")])

    def test_applied_trusted_after_spot_check(self):   # 机上 a 在且 sha 对（抽查过）→ 只推 b
        self.assertEqual(self.go(self.on_phone("a"))[:2], (1, 1)); self.assertEqual(self.dev.lists, [["b"]])
        self.assertTrue(any("机上实况抽查 1 个文件，与已应用索引一致" in l for l in self.log))

    def test_old_app_falls_back_to_index_tsv(self):   # 老 App 没有 index.applied.tsv → 认 index.tsv
        self.go(self.on_phone("a", applied=False)); self.assertEqual(self.dev.lists, [["b"]])

    def test_full_ignores_phone(self):
        self.go(self.on_phone("a", "b"), full=True); self.assertEqual(self.dev.lists, [["a", "b"]])

    def test_not_v2(self):
        (self.pk / "manifest.json").write_text('{"version": 1}')
        with self.assertRaises(push.Fail): self.go({})


class Pending(Base):
    def test_cover_incomplete_keep_complete(self):   # 推到一半的盖成空包；推完整的留着；别的名字不碰
        f = {f"{INC}/20261106061945_000.tar": b"x" * 700, f"{INC}/20261106061945_001.tar": WHOLE, f"{INC}/keep.tar": b"y", f"{INC}/note.txt": b"z"}
        self.go(f)
        self.assertEqual(self.dev.files[f"{INC}/20261106061945_000.tar"], b"\0" * 1024); self.assertEqual(self.dev.files[f"{INC}/20261106061945_001.tar"], WHOLE)
        self.assertEqual((self.dev.files[f"{INC}/keep.tar"], self.dev.files[f"{INC}/note.txt"]), (b"y", b"z"))

    def test_pending_pushed_not_repushed(self):   # 出包重叠：早推的整批还没解 → .pushed 里的文件算已推，只推缺的
        f = {f"{INC}/20261106120000_000.tar": WHOLE, f"{RP}/.pushed": f"a\t{sha(b'A')}\n"}
        self.go(f); self.assertEqual(self.dev.lists, [["b"]])
        self.assertEqual(self.dev.files[f"{RP}/.pushed"].decode(), f"a\t{sha(b'A')}\nb\t{sha(b'BB')}\n")   # 续上旧账

    def test_pushed_ignored_without_pending(self):   # 没有待解批：.pushed 是旧账（解开后机上可能按新索引删了），不算数
        self.go({f"{RP}/.pushed": f"a\t{sha(b'A')}\nb\t{sha(b'BB')}\n"}); self.assertEqual(self.dev.lists, [["a", "b"]])

    def test_stale_distrusts_pushed(self):   # 有截短残批：盖掉、不信 .pushed（推到一半那批的文件可能记过账），只按已应用索引补推
        f = {f"{INC}/1_000.tar": b"x" * 700, f"{INC}/1_001.tar": WHOLE, f"{RP}/.pushed": f"a\t{sha(b'A')}\nb\t{sha(b'BB')}\n"}
        self.go(f); self.assertEqual(self.dev.lists, [["a", "b"]])

    def test_truncated_ignores_index_tsv(self):   # 上次收推送撞截短包：机上 index.tsv 是上次推的目标、文件没落地 → 不退回它，照推
        f = self.on_phone("a", "b", applied=False); f["Documents/unpack.log"] = "10-21 解包失败：解 1_001.tar（截短包，已删）返回 -4\n"
        self.go(f); self.assertEqual(self.dev.lists, [["a", "b"]])


class SpotCheck(Base):
    def test_mismatch_with_listing_keeps_good_rows(self):   # 账记着 a、b，机上 b 丢了：抽查不符 → 按机上清单核账，只补推 b
        f = self.on_phone("a", "b"); del f[f"{RP}/b"]
        self.go(f, listing=True); self.assertEqual(self.dev.lists, [["b"]])
        self.assertTrue(any("按机上实际清单核账：1/2 行在且大小对得上留下" in l for l in self.log))

    def test_mismatch_without_listing_full(self):   # 清单拉不回（Windows AFC 列表不带大小）→ 整包重推
        f = self.on_phone("a", "b"); f[f"{RP}/a"] = b"bad"
        self.go(f); self.assertEqual(self.dev.lists, [["a", "b"]])


class Apply(Base):
    """推完起 App 解包并等完成（push_pack.apply）：期望按头注手写——没推东西且 .applied 已是本包 → 不起 App；
    起了且 .applied = 本包、解包日志本次新增「解开 N 个包 … .applied = 本包」→ 成；同包重推时 .applied 推前就对，日志没新增 → 起 App 后 STALL_S 秒没开始报红。
    11-07 按进度等：慢但包数在涨（每包 60 秒、17 包共 1020 秒，远超旧上限 330 秒）→ 不判失败、每包打「机上解包 k/17」；
    解到第 13 包后停住 → 最后一次进展后 STALL_S（180）秒判失败，报停在第 13 包"""
    WANT = "x"   # Base 的 manifest index_sha256
    def ap(self, files, nb, unpack):
        self.dev = Fake(files); clock = [0.0]
        def done(d):
            if unpack: d.files[f"{RP}/.applied"] = self.WANT; d.files["Documents/unpack.log"] = (d.files.get("Documents/unpack.log", "") + f"11-06 解开 1 个包 2 个文件 0 MB，.applied = {self.WANT}（0.1 秒）\n")
        self.dev.on_launch = done
        def sleep(x): clock[0] += x
        return push.apply(self.dev, self.pk, self.w, nb, say=self.log.append, sleep=sleep, now=lambda: clock[0])

    def test_nothing_pushed_already_applied_skips(self):
        self.assertFalse(self.ap({f"{RP}/.applied": self.WANT}, 0, True)); self.assertFalse(hasattr(self.dev, "launches"))

    def test_partial_line_is_needs_player_not_failure(self):
        # v0.3.1 缺件照玩：手机解开了、只缺非核心文件，写「缺 N 个非必需文件 …部分可玩 = <本包>」（不写 .applied）→ 当场报「还差最后一步：还缺 N 个文件」，
        #   是 NeedsPlayer（装机按传输成功 + 提醒收尾），不等 180 秒、不报失败
        self.dev = Fake({}); clock = [0.0]
        def done(d):
            d.files["Documents/unpack.log"] = f"11-12 解开 1 个包 1 个文件 0 MB，缺 2 个非必需文件（例：romfs/b.bin（不在）），部分可玩 = {self.WANT}（0.1 秒）\n"
        self.dev.on_launch = done
        def sleep(x): clock[0] += x
        with self.assertRaises(push.NeedsPlayer) as e:
            push.apply(self.dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0])
        self.assertIn("还缺 2 个文件", str(e.exception)); self.assertIn("资源包已传完，还差最后一步", str(e.exception))
        self.assertLess(clock[0], 30)   # 当场报，不等停住

    def test_pushed_waits_for_new_done_line(self):
        self.assertTrue(self.ap({}, 1, True)); self.assertEqual(self.dev.launches, [{"S2A_PACK_APPLY_ONLY": "1"}])

    def cant_launch(self, player_opens_at=None):
        """电脑拉不起 App（#192）；player_opens_at 给了就在该时刻起算玩家手动打开、解完。返回 (结果或异常, 结束时刻)"""
        dev = Fake({}); self.dev = dev; clock = [0.0]
        def boom(env): raise push.Fail("起 App 失败：RSD 里没有 app_service")
        dev.launch = boom
        def sleep(x):
            clock[0] += x
            if player_opens_at is not None and clock[0] >= player_opens_at:
                dev.files[f"{RP}/.applied"] = self.WANT; dev.files["Documents/unpack.log"] = f"11-08 解开 1 个包 2 个文件 0 MB，.applied = {self.WANT}（0.2 秒）\n"
        try: return push.apply(dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0]), clock[0]
        except push.Fail as e: return e, clock[0]

    def test_cant_launch_player_opens_by_hand(self):   # 玩家在第 60 秒手动打开：等到解完算装好，不报错
        r, t = self.cant_launch(player_opens_at=60)
        self.assertIs(r, True); self.assertGreaterEqual(t, 60); self.assertLess(t, 70)
        self.assertTrue(any(l.startswith("资源包已传完。") and "打开 S2Arm" in l for l in self.log))

    def test_cant_launch_nobody_opens_is_needs_player(self):   # 180 秒没人打开：需要玩家操作，文案不说失败，带原因
        r, t = self.cant_launch()
        self.assertIsInstance(r, push.NeedsPlayer); self.assertGreater(t, 180); self.assertLess(t, 190)
        self.assertTrue(str(r).startswith("资源包已传完，还差最后一步：")); self.assertIn("app_service", str(r)); self.assertNotIn("失败，", str(r))

    def test_cant_launch_not_locked_says_how_to_fix(self):   # 报错不是锁屏那句：原因写开发者模式 / 信任开发者，不说锁屏
        r, _ = self.cant_launch()
        self.assertIn("开发者模式", str(r)); self.assertIn("VPN 与设备管理", str(r)); self.assertNotIn("锁着屏", str(r))

    def locked_then(self, unlock_at=None):
        """锁屏（11-09 测试设备实测：锁屏时写文件照样成功，只有拉 App 失败，报 XPC response missing CoreDevice.output）；unlock_at 给了就在该时刻解锁，之后拉得起、拉起即解完。返回 (结果或异常, 结束时刻, 拉了几次)"""
        dev = Fake({}); self.dev = dev; clock = [0.0]; tries = [0]
        unlocked = lambda: unlock_at is not None and clock[0] >= unlock_at
        def launch(env):
            tries[0] += 1
            if not unlocked(): raise push.Fail("起 io.s2arm.x 失败：unexpected response from device: XPC response missing CoreDevice.output")
            dev.files[f"{RP}/.applied"] = self.WANT; dev.files["Documents/unpack.log"] = f"11-09 解开 1 个包 2 个文件 0 MB，.applied = {self.WANT}（0.2 秒）\n"
        dev.launch = launch
        def sleep(x): clock[0] += x
        try: return push.apply(dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0]), clock[0], tries[0]
        except push.Fail as e: return e, clock[0], tries[0]

    def test_locked_then_unlocked_resumes_by_itself(self):   # 第 45 秒解锁：电脑自己再拉起来解完，算装好，玩家不用去点
        r, t, n = self.locked_then(unlock_at=45)
        self.assertIs(r, True); self.assertGreaterEqual(t, 45); self.assertLess(t, 45 + push.RELAUNCH_S + 5); self.assertGreater(n, 1)
        self.assertIn(f"资源包已传完。{push.LOCKED_WAIT}", self.log)

    def test_locked_all_along_says_unlock(self):   # 一直锁着：需要玩家操作，原因说锁屏
        r, t, _ = self.locked_then()
        self.assertIsInstance(r, push.NeedsPlayer); self.assertIn("锁着屏", str(r)); self.assertNotIn("开发者模式", str(r))

    MAC_LOCKED = """ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
       BundleIdentifier = io.s2arm.x
           The request to open "io.s2arm.x" failed. (FBSOpenApplicationServiceErrorDomain error 1 (0x01))
           BSErrorCodeDescription = RequestDenied
           NSLocalizedFailureReason = The request was denied by service delegate (SBMainWorkspace) for reason: Locked ("Unable to launch io.s2arm.x because the device was not, or could not be, unlocked").
               NSLocalizedFailureReason = Unable to launch io.s2arm.x because the device was not, or could not be, unlocked.
               BSErrorCodeDescription = Locked
See 'devicectl device process launch --help' for more information.
"""

    def test_mac_devicectl_locked_is_recognized(self):   # 11-10 Mac 锁屏实测：devicectl 末行是 --help 提示，锁屏原因在 NSLocalizedFailureReason 行
        reason = push.launch_reason(self.MAC_LOCKED, 1)
        self.assertIn("could not be, unlocked", reason)
        self.assertNotIn("--help", reason)
        self.assertEqual(push.launch_reason("", 3), "3")
        self.assertEqual(push.launch_reason("ERROR: boom\nSee 'devicectl --help'\n", 1), "See 'devicectl --help'")   # 没有原因行照旧取末行
        dev = Fake({}); self.dev = dev; clock = [0.0]
        def launch(env): raise push.Fail("起 App 失败：" + push.launch_reason(self.MAC_LOCKED, 1))
        dev.launch = launch
        def sleep(x): clock[0] += x
        try: r = push.apply(dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0])
        except push.Fail as e: r = e
        self.assertIsInstance(r, push.NeedsPlayer); self.assertIn("锁着屏", str(r)); self.assertNotIn("开发者模式", str(r))
        self.assertIn(f"资源包已传完。{push.LOCKED_WAIT}", self.log)

    def test_mac_launch_without_env_omits_flag(self):   # 多款容器拉起到游戏库 env 为空：devicectl 收 '{}' 会拒，得不带这个参数（11-10 测试设备实测）
        import stat
        argv = Path(self.w) / "argv.txt"; fake = Path(self.w) / "devicectl"
        fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + str(argv) + "'\n"
                        "for a in \"$@\"; do [ \"$a\" = '{}' ] && { echo 'Error: Unable to decode environment variables.' >&2; exit 64; }; done\nexit 0\n")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        d = push.Devicectl("DEV", "io.s2arm.x", self.w, env=dict(os.environ, S2A_DEVICECTL=str(fake)))
        d.launch({})
        args = argv.read_text().split("\n")
        self.assertNotIn("--environment-variables", args); self.assertIn("io.s2arm.x", args)
        d.launch({"S2A_PACK_APPLY_ONLY": "1"})   # 单款只解包照旧带
        self.assertIn('{"S2A_PACK_APPLY_ONLY": "1"}', argv.read_text().split("\n"))

    def test_no_tunnel_says_developer_mode(self):   # s2a-devpush 建不了隧道（CoreDeviceProxy 连不上）：原因只说开发者模式
        dev = Fake({}); self.dev = dev; clock = [0.0]
        def boom(env): raise push.Fail("CoreDeviceProxy 连不上（要 iOS 17+、开发者模式）：x")
        dev.launch = boom
        def sleep(x): clock[0] += x
        with self.assertRaises(push.NeedsPlayer) as e: push.apply(dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0])
        self.assertIn("打开开发者模式", str(e.exception)); self.assertNotIn("锁着屏", str(e.exception))

    def test_same_pack_repush_without_new_line_fails(self):   # .applied 推前已是本包、日志旧行也对得上，但这次没解 → 不能判装好
        old = {f"{RP}/.applied": self.WANT, "Documents/unpack.log": f"10-01 解开 3 个包 9 个文件 1 MB，.applied = {self.WANT}（0.2 秒）\n"}
        with self.assertRaises(push.Fail) as e: self.ap(old, 1, False)
        self.assertIn("起 App 后 180 秒机上解包没有开始", str(e.exception)); self.assertEqual(len(self.dev.launches), 1)
        # 装机原则（11-11）：解包停住 = 资源已全在手机上，报 NeedsPlayer（装机按「传输成功 + 提醒打开 App 接着装」收尾），不是装机失败
        self.assertIsInstance(e.exception, push.NeedsPlayer); self.assertIn("资源包已传完，还差最后一步", str(e.exception))

    def test_device_failure_reported_at_once_with_its_reason(self):
        # App 起来解开、第一包前就失败（#569：目录 App 写不进）：解包日志新增「解包失败：…」→ 当场按原因报，不再等 180 秒后说「没有开始」。期望手写
        self.dev = Fake({}); clock = [0.0]
        def launched(d):
            d.files["Documents/unpack.log"] = "11-11 解包失败：目录 App 写不进：资源包/.incoming（属主 uid 0、权限 755，App 是 uid 501） 返回 -9（已解 0 个包 0 个文件）\n"
        self.dev.on_launch = launched
        def sleep(x): clock[0] += x
        with self.assertRaises(push.Fail) as e:
            push.apply(self.dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0])
        self.assertIn("手机上解开失败：目录 App 写不进：资源包/.incoming（属主 uid 0", str(e.exception))
        self.assertNotIn("没有开始", str(e.exception))
        self.assertLess(clock[0], 10, "当场报，不等满 180 秒")

    def slow(self, stop_at=None, per=60.0, n=17):
        """合成进度：起 App 后每 per 秒解完一包（第 k 包写「进度：解开 x_k.tar（k/n）」），stop_at 给了就解到第 stop_at 包后再无进展；
        n 包都解完写完成行与 .applied。返回 (结果或异常, 失败 / 完成时刻)"""
        self.dev = Fake({}); clock = [0.0]; t0 = [None]
        def launched(d): t0[0] = clock[0]
        self.dev.on_launch = launched
        def sleep(x):
            clock[0] += x
            if t0[0] is None: return
            k = min(n, int((clock[0] - t0[0]) // per)); k = min(k, stop_at) if stop_at else k
            log = "".join(f"11-07 进度：解开 x_{i:03d}.tar（{i}/{n}）10 个文件 1000 MB（{per} 秒）\n" for i in range(1, k + 1))
            if k == n: log += f"11-07 解开 {n} 个包 170 个文件 17000 MB，.applied = {self.WANT}（{n * per} 秒）\n"; self.dev.files[f"{RP}/.applied"] = self.WANT
            self.dev.files["Documents/unpack.log"] = log
        try:
            return push.apply(self.dev, self.pk, self.w, 1, say=self.log.append, sleep=sleep, now=lambda: clock[0]), clock[0]
        except push.Fail as e:
            return e, clock[0]

    def test_slow_but_progressing_does_not_fail(self):   # 17 包 × 60 秒 = 1020 秒，旧口径（≥330 秒上限）会判失败
        r, t = self.slow()
        self.assertIs(r, True); self.assertGreaterEqual(t, 1020)
        self.assertIn("机上解包 13/17", self.log); self.assertEqual(self.log[-1], "资源包：机上已解开（.applied = 本包）")   # 末包与完成行同一轮出现：直接判完成

    def test_stalled_fails_after_stall_window(self):   # 第 13 包在 780 秒解完后停住 → 780 + 180 秒后判失败（3 秒一轮，最多多等一轮）
        r, t = self.slow(stop_at=13)
        self.assertIsInstance(r, push.Fail); self.assertIn("180 秒没有新进展（停在第 13 包）", str(r))
        self.assertTrue(780 + 180 < t <= 780 + 180 + 3 + 3, t)


class ContainerDocs(Base):
    """多款容器（--docs / --launch-ctx，pack/ship_ext.py 容器布局）：资源包、待解批、记账、索引、解包日志都在本款文档根 Documents/games/<游戏号> 下，
    根上的 Documents/资源包 一个不碰；推完起 App 解包带 S2A_LAUNCH_CTX=本款启动上下文"""
    D, CTX = "Documents/games/0100000000010000", "@bundle/Games/0100000000010000/launch.ctx"

    def test_paths_and_launch_ctx(self):
        self.dev = Fake({f"{RP}/manifest.json": '{"version": 2}', f"{RP}/index.applied.tsv": self.row("a") + self.row("b")})   # 根上另一份（单款 App 的）不算本款的账
        self.dev.docs, self.dev.ctx = self.D, self.CTX
        nb, nt, _ = push.run(self.dev, self.pk, self.w, False, say=self.log.append)
        self.assertEqual((nb, nt), (1, 2))
        self.assertEqual(self.dev.puts[0], f"{self.D}/资源包/{push.PROBE}")   # 先写探针（#333），也在本款资源包目录
        self.assertEqual(self.dev.puts[1:3], [f"{self.D}/资源包/.transfer", f"{self.D}/资源包/manifest.json"])   # 传输清单 → 置空本款清单（同一份文档根）
        self.assertTrue(self.dev.puts[3].startswith(f"{self.D}/资源包/.incoming/") and self.dev.puts[3].endswith("_000.tar"), self.dev.puts[3])
        self.assertEqual(self.dev.puts[4:], [f"{self.D}/资源包/.pushed", f"{self.D}/资源包/index.tsv", f"{self.D}/资源包/manifest.json"])
        def done(d):
            d.files[f"{self.D}/资源包/.applied"] = "x"; d.files[f"{self.D}/unpack.log"] = "11-07 解开 1 个包 2 个文件 0 MB，.applied = x（0.1 秒）\n"
        self.dev.on_launch = done; clock = [0.0]
        def sleep(x): clock[0] += x
        self.assertTrue(push.apply(self.dev, self.pk, self.w, nb, say=self.log.append, sleep=sleep, now=lambda: clock[0]))
        self.assertEqual(self.dev.launches, [{}])   # 多款容器：正常拉起到游戏库，由库解开（不用只解包模式、不直接起某一款）

    def test_pack_root_separate_from_docs(self):
        """11-11 资源包挪出 Documents：--pack-root 给了 → 探针、待解批、记账、索引、清单、.applied 都在资源包根下；解包日志仍读 <文档根>/unpack.log"""
        P = "Library/Application Support/S2Arm/games/0100000000010000/资源包"
        self.dev = Fake({f"{self.D}/资源包/manifest.json": '{"version": 2}', f"{self.D}/资源包/index.applied.tsv": self.row("a") + self.row("b")})   # 旧位置的账不算（调用方选了新位置）
        self.dev.docs, self.dev.ctx, self.dev.pack = self.D, self.CTX, P
        nb, nt, _ = push.run(self.dev, self.pk, self.w, False, say=self.log.append)
        self.assertEqual((nb, nt), (1, 2))
        self.assertEqual(self.dev.puts[:3], [f"{P}/{push.PROBE}", f"{P}/.transfer", f"{P}/manifest.json"])
        self.assertTrue(self.dev.puts[3].startswith(f"{P}/.incoming/") and self.dev.puts[3].endswith("_000.tar"), self.dev.puts[3])
        self.assertEqual(self.dev.puts[4:], [f"{P}/.pushed", f"{P}/index.tsv", f"{P}/manifest.json"])
        def done(d):
            d.files[f"{P}/.applied"] = "x"; d.files[f"{self.D}/unpack.log"] = "11-07 解开 1 个包 2 个文件 0 MB，.applied = x（0.1 秒）\n"
        self.dev.on_launch = done; clock = [0.0]
        def sleep(x): clock[0] += x
        self.assertTrue(push.apply(self.dev, self.pk, self.w, nb, say=self.log.append, sleep=sleep, now=lambda: clock[0]))

    def test_windows_install_writes_new_location(self):
        """Windows 装机推包（pack/orch/install_win.push_pack，install.py 把 pick_pack_root 选的根作 pack_root 传进来）：走真的 push.device 的 s2a-devpush 那支
        （Windows 没有 devicectl），只把底层读写换成内存容器 → 探针、待解批、记账、索引、清单都写进 Library 新位置，Documents 下本款资源包一个不写"""
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pack/orch"))
        import install_win
        P = "Library/Application Support/S2Arm/games/0100000000010000/资源包"
        exe = self.w / "s2a-devpush"; exe.write_text(""); exe.chmod(0o755)   # 工具在（不会被真调用：读写换成内存容器）
        mem, made, real = Fake({}), [], push.device
        def device(*a, **k):
            d = real(*a, **k); made.append(d)
            for m in ("get", "put", "ls", "tar_ok", "put_tar", "listing", "free", "nospc", "rm"):
                if hasattr(mem, m): setattr(d, m, getattr(mem, m))
            return d
        push.device = device
        try:
            nt, _ = install_win.push_pack("U1", "s2arm.T.games", str(self.pk), devpush=str(exe), say=self.log.append, docs=self.D, ctx=self.CTX, pack_root=P)
        finally:
            push.device = real
        self.assertEqual(nt, 2)
        self.assertIsInstance(made[0], push.Devpush)   # Windows 那支：s2a-devpush，不是 devicectl
        self.assertEqual((made[0].docs, made[0].pack), (self.D, P))
        self.assertTrue(mem.puts and all(r.startswith(P + "/") for r in mem.puts), mem.puts)
        self.assertIn(f"{P}/manifest.json", mem.files); self.assertIn(f"{P}/index.tsv", mem.files)
        self.assertFalse([r for r in mem.files if r.startswith(f"{self.D}/资源包")])

    def test_device_factory_carries_docs(self):
        d = push.device("C891", "s2arm.z.games", self.w, via="devicectl", env={}, docs=self.D, ctx=self.CTX)
        self.assertEqual((d.docs, d.ctx, push.rp(d)), (self.D, self.CTX, f"{self.D}/资源包"))   # 没给资源包根：按文档根推
        d = push.device("C891", "s2arm.z.games", self.w, via="devicectl", env={}, docs=self.D, ctx=self.CTX, pack="Library/Application Support/S2Arm/games/0100000000010000/资源包")
        self.assertEqual(push.rp(d), "Library/Application Support/S2Arm/games/0100000000010000/资源包")
        d = push.device("C891", "s2arm.z.0100000000010000", self.w, via="devicectl", env={})
        self.assertEqual((d.docs, d.ctx, push.rp(d)), ("Documents", None, "Documents/资源包"))   # 单款缺省不变


class BigFallback(unittest.TestCase):
    """#641：流式写失败后，大于上限的文件不交给 devicectl 整份拷（CoreDeviceService 会把整个文件读进内存、拖垮整机）；小文件照旧退回"""
    def run_put_big(self, size, cap, mem=0):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(push, "avail_mem", lambda: mem):
            src = Path(t) / "game.img"; src.write_bytes(b"\0" * size)
            d = push.Devicectl("C891", "io.s2arm.games.t", t, env={"S2A_DC_FALLBACK_MAX": str(cap)})
            class Stream:
                def put(self, src, rel): raise push.Fail("写文件失败：device socket io failed")
            d.dp = Stream(); said, copied = [], []
            d.say = said.append; d.put = lambda src, rel: copied.append(rel)
            try:
                d.put_big(src, "Documents/资源包/game.img"); return None, copied, said
            except push.Fail as e:
                return str(e), copied, said

    def test_big_file_does_not_fall_back_to_devicectl(self):
        err, copied, _ = self.run_put_big(4096, 1024)
        self.assertEqual(copied, [])
        self.assertIn("不改走 devicectl", err)
        self.assertIn("device socket io failed", err)

    def test_small_file_still_falls_back(self):
        err, copied, said = self.run_put_big(512, 1024)
        self.assertIsNone(err)
        self.assertEqual(copied, ["Documents/资源包/game.img"])
        self.assertTrue(any("改走 devicectl" in m for m in said))

    def test_default_cap_is_two_gib(self):
        self.assertEqual(push.DC_FALLBACK_MAX, 2 << 30)

    def test_fits_in_half_of_free_memory_falls_back(self):
        # 11-12：上限按「固定上限与本机可用内存一半取大」——4096 字节的文件，固定上限 1024、可用内存 10000（一半 5000 ≥ 4096）→ 交给 devicectl
        err, copied, _ = self.run_put_big(4096, 1024, mem=10000)
        self.assertIsNone(err)
        self.assertEqual(copied, ["Documents/资源包/game.img"])

    def test_more_than_half_of_free_memory_does_not(self):
        err, copied, _ = self.run_put_big(4096, 1024, mem=8000)   # 一半 4000 < 4096
        self.assertEqual(copied, [])
        self.assertIn("本机可用内存", err)


class PushReason(unittest.TestCase):
    """推送失败的原文 → 摘要里一眼看得懂的一类（11-12 v0.3.1 Mac 玩家「romfs.img 没传完」看不出是哪种）。期望按 s2a-devpush / devicectl 的报错特征手写"""
    def test_kinds(self):
        self.assertIn("USB 看不到手机", push.push_reason("找不到设备 00008140-0001：DeviceNotFound"))
        self.assertIn("手机锁屏", push.push_reason("取不到 io.s2arm.games.t 的容器（App 装着，可能锁屏 / 不是开发签名）：device socket io failed"))
        self.assertIn("连接断了", push.push_reason("90 秒没有任何进展：和手机的连接可能断了"))
        self.assertIn("连接断了", push.push_reason("写文件失败：device socket io failed"))
        self.assertEqual(push.push_reason("别的原因"), "")

    def make_pack(self, t):
        pk, w = Path(t) / "pack", Path(t) / "work"; pk.mkdir(); w.mkdir()
        (pk / "romfs.img").write_bytes(b"IMAGE"); (pk / "index.tsv").write_text(f"romfs.img\t5\t{sha(b'IMAGE')}\n")
        (pk / "manifest.json").write_text('{"version": 2}')
        return pk, w

    def test_direct_write_retried_once(self):
        with tempfile.TemporaryDirectory() as t:
            pk, w = self.make_pack(t); dev = Fake({}); calls = []
            def flaky(src, rel):
                calls.append(rel)
                if len(calls) == 1: raise push.Fail("写文件失败：device socket io failed")
            dev.put_big = flaky; log = []
            push.plan(dev, pk, w, full=True, say=log.append); push.send(dev, pk, w, say=log.append)
            self.assertEqual(calls, [f"{RP}/romfs.img", f"{RP}/romfs.img"])
            self.assertTrue(any("原地再试一次" in l for l in log))

    def test_two_failures_name_the_reason_and_the_way_out(self):
        with tempfile.TemporaryDirectory() as t:
            pk, w = self.make_pack(t); dev = Fake({}); log = []
            def gone(src, rel): raise push.Fail("找不到设备 00008140-0001：DeviceNotFound")
            dev.put_big = gone
            push.plan(dev, pk, w, full=True, say=log.append)
            with self.assertRaises(push.Fail) as cm: push.send(dev, pk, w, say=log.append)
            m = str(cm.exception)
            self.assertTrue(m.startswith("资源传输中断（USB 看不到手机"), m)
            self.assertIn("romfs.img 没传完", m); self.assertIn("新版已支持单一文件包和断点续传", m); self.assertIn("重新出一次这款的包", m)
            self.assertTrue(localized(m), f"启动器中英对照表里没有对得上这句的句式：{m}")

    def test_resumable_message_is_localized(self):
        m = "资源传输中断（" + push.push_reason("找不到设备 x") + "）：game.img 没传完，重新装到 iPhone 会接着已传的部分续传"
        self.assertTrue(localized(m), m)


def localized(text):
    """同启动器 BackendText 的句式匹配（{n} 占位 = 非贪婪任意串，整句锚定），占位里的值也要能翻（原因一类是整句对照）"""
    import re
    table = json.loads((Path(__file__).resolve().parents[1] / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json").read_text(encoding="utf-8"))
    exact = {e["source"] for e in table}
    for e in table:
        parts = re.split(r"\{\d+\}", e["source"])
        if len(parts) < 2: continue
        m = re.fullmatch("(.*?)".join(map(re.escape, parts)), text, re.S)
        if m and all(g in exact or not re.search(r"[\u4e00-\u9fff]", g) or g.endswith(".img") for g in m.groups()):
            return True
    return False


class SpaceNeed(Base):
    def batches(self, *sizes):
        for i, rows in enumerate(sizes):
            (self.w / f"push_{i:03d}.tsv").write_text("".join(f"f{i}_{k}\t{n}\tsha\n" for k, n in enumerate(rows)))

    def test_peak_not_double(self):   # 手算：10 GB 分两批（6、4 GB）、3 个文件 → 10 + 6 GB + 3 × 4096 + 余量 1 GiB
        self.batches([6 * 10**9], [3 * 10**9, 10**9])
        self.assertEqual(push.need_bytes(self.w, 10**10, {}), 10**10 + 6 * 10**9 + 3 * 4096 + (1 << 30))
        self.assertEqual(push.need_bytes(self.w, 10**10, {"S2A_PUSH_SPARE_GB": "0"}), 10**10 + 6 * 10**9 + 3 * 4096)

    def run_with_free(self, free):
        self.dev = Fake({})
        self.dev.free = lambda: free
        return push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0"})

    # 手算：两个文件共 3 字节，一批 → 3 + 3 + 2 × 4096 = 8198
    def test_exact_need_passes(self):
        self.assertEqual(self.run_with_free(8198)[2], 3)

    # 估算不够（手机报的空闲不含系统可清除空间，偏小）：认得出的风险让玩家确认——没确认停下报 device_space_low、只写了探针；确认过照推、打一行黄
    def test_one_byte_short_asks(self):
        with self.assertRaises(push.LowSpace) as e: self.run_with_free(8197)
        self.assertEqual(e.exception.code, "device_space_low"); self.assertIn("仍然继续", str(e.exception))
        self.assertEqual(self.dev.puts, [f"{RP}/{push.PROBE}"])   # 只写了探针（#333），资源一个没推

    def test_one_byte_short_accepted_pushes(self):
        self.dev = Fake({}); self.dev.free = lambda: 8197
        self.assertEqual(push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0", "S2A_PUSH_ACCEPT_LOW_SPACE": "1"})[2], 3)
        self.assertTrue(any(m.startswith("🟡 iPhone 剩余空间看起来不够") for m in self.log))

    # 真写满：推失败后再量、空闲 < 256 MB → 报 ios_install_no_space，说清要传多少、手机还剩多少；空闲还多 = 别的原因，照原样往上抛
    def test_real_full_says_how_much(self):
        frees = iter([10**9, 5 << 20])
        self.dev = Fake({}, full_disk=True); self.dev.free = lambda: next(frees)
        with self.assertRaises(push.SpaceFull) as e: push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0"})
        self.assertEqual(e.exception.code, "ios_install_no_space"); self.assertIn("只剩 5 MB", str(e.exception))
        frees = iter([10**9, 10**9])
        self.dev = Fake({}, full_disk=True); self.dev.free = lambda: next(frees)
        with self.assertRaises(push.Fail) as e: push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0"})
        self.assertNotIsInstance(e.exception, push.SpaceFull)

    # 手机上的 App 记的「重要用途」可用（Documents/s2a_free.tsv，含可清除空间）比电脑端读到的空闲大：按它判（玩家反馈：设置里剩 70 多 GB，一键安装说只剩 2 GB）
    def phone(self, imp, afc):
        self.dev = Fake({push.PHONE_FREE: f"{imp}\t0\t{afc}\t{int(time.time()) - 120}\n"}); self.dev.free = lambda: afc

    def test_phone_important_enough_pushes(self):   # 电脑端空闲 100 字节、手机记 8198（正好够）→ 不问照推，日志说按哪个口径
        self.phone(8198, 100)
        self.assertEqual(push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0"})[2], 3)
        self.assertTrue(any("重要用途" in m and "2 分钟前" in m for m in self.log), self.log)

    def test_phone_important_short_asks_without_purgeable_claim(self):   # 手机记的也差 1 字节 → 照样问；不再说「实际多半放得下」（已含可清除空间）
        self.phone(8197, 100)
        with self.assertRaises(push.LowSpace) as e: push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0"})
        self.assertIn("含系统随时能清掉的空间", str(e.exception)); self.assertNotIn("多半放得下", str(e.exception)); self.assertIn("仍然继续", str(e.exception))

    def test_phone_smaller_than_afc_ignored(self):   # 手机记的（旧的）比电脑端读到的还小 → 用电脑端的
        self.phone(100, 8198)
        self.assertEqual(push.run(self.dev, self.pk, self.w, full=True, say=self.log.append, env={"S2A_PUSH_SPARE_GB": "0"})[2], 3)
        self.assertFalse(any("重要用途" in m for m in self.log))

    def test_phone_file_garbage_is_none(self):
        self.dev = Fake({push.PHONE_FREE: "坏\n"}); self.assertEqual(push.phone_free(self.dev, self.w), (None, None))

    def test_devpush_free_parses_or_none(self):
        d = push.Devpush("exe", "U", "b", self.w)
        d.call = lambda *a: (0, "1234\n"); self.assertEqual(d.free(), 1234)
        d.call = lambda *a: (1, "不认识的操作 free"); self.assertIsNone(d.free())


class ImagePush(Base):
    def setUp(self):
        super().setUp()
        self.data = {"romfs.img": b"IMAGE", "b": b"BB"}
        for k, v in self.data.items(): (self.pk / k).write_bytes(v)
        (self.pk / "index.tsv").write_text("".join(self.row(k) for k in self.data))

    def phone(self, applied):
        f = {f"{RP}/manifest.json": '{"version": 2}', f"{RP}/index.applied.tsv": self.row("romfs.img") + self.row("b"), f"{RP}/b": b"BB", f"{RP}/romfs.img": b"IMAGE"}
        if applied is not None: f[f"{RP}/.applied"] = applied
        return f

    def test_image_is_direct_not_tar(self):
        self.dev = Fake({}); self.dev.put_big = lambda src, rel: self.dev.puts.append(rel)
        nb, nt, n = push.plan(self.dev, self.pk, self.w, full=True, say=self.log.append)
        self.assertEqual((nb, nt), (1, 2)); self.assertEqual((self.w / "direct_img.tsv").read_text().split("\t")[0], "romfs.img")
        self.assertNotIn("romfs.img", (self.w / "push_000.tsv").read_text())

    def test_interrupted_image_is_pushed_again(self):   # .applied 被清空 = 上次传到一半：账上有也要重传
        self.dev = Fake(self.phone(""))
        nb, nt, n = push.plan(self.dev, self.pk, self.w, say=self.log.append)
        self.assertEqual((nt, (self.w / "direct_img.tsv").read_text().split("\t")[0]), (1, "romfs.img"))
        self.assertTrue(any("被打断" in l for l in self.log))

    def test_image_already_pushed_is_not_called_interrupted(self):
        # #457：上次镜像整份传完、记进 .pushed，又有一批推完没解开（机上留着完整的 tar），之后解包没成，.applied 一直空。
        #   期望（手写）：不重传镜像、也不说「被打断，这次重传」，如实说镜像已传完、问题在解包；b 在推送账上也不重推
        f = self.phone(""); f[f"{INC}/20261110000000_000.tar"] = WHOLE
        f[f"{RP}/.pushed"] = self.row("romfs.img").rsplit("\t", 1)[0].split("\t")[0] + "\t" + sha(b"IMAGE") + "\n" + "b\t" + sha(b"BB") + "\n"
        self.dev = Fake(f)
        nb, nt, n = push.plan(self.dev, self.pk, self.w, say=self.log.append)
        self.assertEqual(nt, 0)
        self.assertFalse(any("被打断" in l for l in self.log), self.log)
        self.assertTrue(any("已整份传完" in l and "unpack.log" in l for l in self.log), self.log)

    def test_applied_image_is_not_pushed_again(self):
        self.dev = Fake(self.phone("abc"))
        self.assertEqual(push.plan(self.dev, self.pk, self.w, say=self.log.append)[1], 0)

    def test_library_pack_materializes_image_and_deletes_after(self):
        # #329：库里的资源包不存 romfs.img、只存 romfs.files/ 硬链接 + 索引 + 偏移表；要推镜像时现拼、推的字节对、推完删
        sys.path.insert(0, str(push.R / "pack")); import romfs_image
        (self.pk / "romfs.img").unlink(); (self.pk / "romfs.files").mkdir(); (self.pk / "romfs.files" / "x").write_bytes(b"IMA"); (self.pk / "romfs.files" / "y").write_bytes(b"GE")
        idx = b"S2ARFS01" + struct.pack("<qi", 5, 2) + struct.pack("<qqii", 0, 3, 0, 1) + struct.pack("<qqii", 3, 2, 1, 1) + struct.pack("<i", 2) + b"xy" + struct.pack("<i", 0)
        (self.pk / "romfs.s2aidx").write_bytes(idx); (self.pk / "romfs.imgmap").write_bytes(romfs_image.MAGIC + struct.pack("<qi", 5, 2) + struct.pack("<2q", 0, 3))
        self.dev = Fake({}); got = []
        self.dev.put_big = lambda src, rel: got.append((rel, Path(src).read_bytes()))
        push.run(self.dev, self.pk, self.w, full=True, say=self.log.append)
        self.assertEqual(got, [(f"{RP}/romfs.img", b"IMAGE")])
        self.assertFalse((self.pk / "romfs.img").exists())

    def test_split_plan_send_materializes_library_pack(self):
        # dev_run 走的两步路（push_pack.sh：plan → send，不走 run）同样要现拼库内形态的镜像（原先只有 run 拼，dev_run 推库里的包 FileNotFoundError: romfs.img）
        sys.path.insert(0, str(push.R / "pack")); import romfs_image
        (self.pk / "romfs.img").unlink(); (self.pk / "romfs.files").mkdir(); (self.pk / "romfs.files" / "x").write_bytes(b"IMA"); (self.pk / "romfs.files" / "y").write_bytes(b"GE")
        idx = b"S2ARFS01" + struct.pack("<qi", 5, 2) + struct.pack("<qqii", 0, 3, 0, 1) + struct.pack("<qqii", 3, 2, 1, 1) + struct.pack("<i", 2) + b"xy" + struct.pack("<i", 0)
        (self.pk / "romfs.s2aidx").write_bytes(idx); (self.pk / "romfs.imgmap").write_bytes(romfs_image.MAGIC + struct.pack("<qi", 5, 2) + struct.pack("<2q", 0, 3))
        self.dev = Fake({}); got = []
        self.dev.put_big = lambda src, rel: got.append((rel, Path(src).read_bytes()))
        push.plan(self.dev, self.pk, self.w, full=True, say=self.log.append)
        push.send(self.dev, self.pk, self.w, say=self.log.append)
        self.assertEqual(got, [(f"{RP}/romfs.img", b"IMAGE")])
        self.assertFalse((self.pk / "romfs.img").exists())

    def test_library_pack_image_already_on_phone_is_not_built(self):
        (self.pk / "romfs.img").unlink(); self.dev = Fake(self.phone("abc"))   # 机上已应用同一镜像：不拼、不推
        push.run(self.dev, self.pk, self.w, say=self.log.append)
        self.assertFalse(any("现拼" in l for l in self.log)); self.assertFalse((self.pk / "romfs.img").exists())

    def test_send_invalidates_applied_before_writing_image(self):
        self.dev = Fake({}); order = []
        put = self.dev.put; self.dev.put = lambda src, rel: (order.append(rel), put(src, rel))[1]
        self.dev.put_big = lambda src, rel: order.append(rel)
        push.plan(self.dev, self.pk, self.w, full=True, say=self.log.append); push.send(self.dev, self.pk, self.w, say=self.log.append)
        self.assertLess(order.index(f"{RP}/.applied"), order.index(f"{RP}/romfs.img"))


P = push.IMG_PAGE


def img(pack_id=b"f" * 64, body=b"D"):   # 假单一 IMG：第 0 页头（魔数、资源包号在 32..96），后面 3 整页 + 100 字节数据
    head = bytearray(P); head[:8] = b"S2AIMG01"; head[32:32 + len(pack_id)] = pack_id
    return bytes(head) + body * (3 * P + 100)


class GameImgResume(Base):
    """v0.3.0 单一 IMG（game.img）断点续传：机上开头一页与本地相同且资源包号不空 → 从机上长度按 16 KB 向下取整处接着写；否则整份重写"""
    def setUp(self):
        super().setUp()
        self.local = img()
        self.data = {"game.img": self.local, "b": b"BB"}
        for k, v in self.data.items(): (self.pk / k).write_bytes(v)
        (self.pk / "index.tsv").write_text("".join(self.row(k) for k in self.data))

    def device(self, on_phone=None, head_ok=True, put_at_fails=False, short_after=False):
        dev = Fake({} if on_phone is None else {f"{RP}/game.img": on_phone}); dev.big, dev.at = [], []
        def put_big(src, rel): dev.big.append(rel); dev.files[rel] = Path(src).read_bytes()
        def head(rel, n):
            if not head_ok: return None
            v = dev.files.get(rel); return (-1, b"") if v is None else (len(v), v[:n])
        def put_at(src, rel, off):
            if put_at_fails: raise push.Fail("断了")
            dev.at.append((rel, off)); data = Path(src).read_bytes()
            dev.files[rel] = dev.files[rel][:off] + data[off:len(data) - (1 if short_after else 0)]
        dev.put_big, dev.head, dev.put_at = put_big, head, put_at
        return dev

    def push_it(self, dev):
        self.dev = dev
        push.plan(dev, self.pk, self.w, full=True, say=self.log.append); push.send(dev, self.pk, self.w, say=self.log.append)

    def test_v3_img_manifest_plans(self):   # v0.3.0 单一 IMG 的清单是 v3（pack/img.py convert）：照推，game.img 直写（原先只认 v2，启动器 / dev_run 推 IMG 报「资源包不是 v2」）
        (self.pk / "manifest.json").write_text('{"version": 3, "format": "img", "imgFile": "game.img", "index_sha256": "x"}')
        self.dev = Fake({}); push.plan(self.dev, self.pk, self.w, full=True, say=self.log.append)
        self.assertEqual((self.w / "direct_img.tsv").read_text().split("\t")[0], "game.img")

    def test_v3_applied_on_phone_pushes_nothing(self):   # 11-13：机上已解开同一个 v3 包（manifest v3、index.applied.tsv 全对、.applied 非空）→ 一个文件都不推（原先只信 v2 的已应用索引，整批重推）
        (self.pk / "manifest.json").write_text('{"version": 3, "format": "img", "imgFile": "game.img", "index_sha256": "x"}')
        rows = (self.pk / "index.tsv").read_text()
        files = {f"{RP}/manifest.json": '{"version": 3, "format": "img"}', f"{RP}/index.applied.tsv": rows, f"{RP}/.applied": "x"}
        files.update({f"{RP}/{l.split(chr(9))[0]}": (self.pk / l.split(chr(9))[0]).read_bytes() for l in rows.splitlines()})
        self.dev = Fake(files)
        self.assertEqual(push.plan(self.dev, self.pk, self.w, say=self.log.append), (0, 0, 0))
        self.assertEqual((self.w / "direct_img.tsv").read_text(), "")

    def test_full_write_checks_length_on_phone(self):   # 整份写完也核机上总长（11-11「传完并校验即成功」）：短一个字节不记账、说清长度
        dev = self.device()
        def short_write(src, rel): dev.big.append(rel); dev.files[rel] = Path(src).read_bytes()[:-1]
        dev.put_big = short_write
        # 直写失败会原地再试一次（11-12），这里两次都整份写短（不走续传），看长度核对本身
        with mock.patch.object(push, "resume_offset", lambda *a: 0), self.assertRaises(push.Fail) as e: self.push_it(dev)
        self.assertIn("game.img 没传完", str(e.exception))
        self.assertTrue(any(f"长度 {len(self.local) - 1} 字节，应为 {len(self.local)} 字节" in l for l in self.log), self.log)
        self.assertNotIn(f"{RP}/.pushed", dev.files)   # 没记账：下次重新判断续传

    def test_full_write_length_ok_completes(self):
        dev = self.device(); self.push_it(dev)
        self.assertEqual(dev.files[f"{RP}/game.img"], self.local)

    def test_game_img_is_direct_not_tar(self):
        self.dev = Fake({}); push.plan(self.dev, self.pk, self.w, full=True, say=self.log.append)
        self.assertEqual((self.w / "direct_img.tsv").read_text().split("\t")[0], "game.img")
        self.assertNotIn("game.img", (self.w / "push_000.tsv").read_text())

    def test_resume_from_page_floor(self):   # 机上有前 2.5 页（同一份）→ 从第 2 页起续写，写完机上与本地逐字节相同
        dev = self.device(self.local[:2 * P + P // 2]); self.push_it(dev)
        self.assertEqual((dev.at, dev.big), ([(f"{RP}/game.img", 2 * P)], []))
        self.assertEqual(dev.files[f"{RP}/game.img"], self.local)
        self.assertTrue(any("续传 game.img" in l for l in self.log), self.log)

    def test_other_pack_id_rewrites(self):   # 机上那份是别的资源包号（旧版本）→ 整份重写
        dev = self.device(img(pack_id=b"e" * 64)[:2 * P]); self.push_it(dev)
        self.assertEqual((dev.at, dev.big), ([], [f"{RP}/game.img"]))

    def test_empty_pack_id_rewrites(self):   # 头里资源包号空：认不出是不是同一份 → 整份重写
        self.local = img(pack_id=b""); (self.pk / "game.img").write_bytes(self.local); self.data["game.img"] = self.local
        (self.pk / "index.tsv").write_text("".join(self.row(k) for k in self.data))
        dev = self.device(self.local[:2 * P]); self.push_it(dev)
        self.assertEqual((dev.at, dev.big), ([], [f"{RP}/game.img"]))

    def test_phone_longer_rewrites(self):
        dev = self.device(self.local + b"X"); self.push_it(dev)
        self.assertEqual((dev.at, dev.big), ([], [f"{RP}/game.img"]))

    def test_only_header_page_rewrites(self):   # 机上不足两页（只有头）：没东西可省，从头写
        dev = self.device(self.local[:P + 10]); self.push_it(dev)
        self.assertEqual((dev.at, dev.big), ([], [f"{RP}/game.img"]))

    def test_old_tool_without_head_rewrites(self):
        dev = self.device(self.local[:2 * P], head_ok=False); self.push_it(dev)
        self.assertEqual((dev.at, dev.big), ([], [f"{RP}/game.img"]))

    def test_resume_failure_falls_back_to_full(self):
        dev = self.device(self.local[:2 * P], put_at_fails=True); self.push_it(dev)
        self.assertEqual(dev.big, [f"{RP}/game.img"]); self.assertEqual(dev.files[f"{RP}/game.img"], self.local)
        self.assertTrue(any("改为整份重写" in l for l in self.log), self.log)

    def test_wrong_length_after_resume_fails(self):   # 续写后机上总长不对：不记账、报中断（说会接着续传）
        dev = self.device(self.local[:2 * P], short_after=True)
        with self.assertRaises(push.Fail) as e: self.push_it(dev)
        self.assertIn("续传", str(e.exception))
        self.assertNotIn(f"{RP}/.pushed", dev.files)

    def test_romfs_img_never_resumes(self):   # 旧形态 romfs.img 没有 IMG 头：不读机上头、整份写
        sys_img = b"OLDIMAGE" * 5000
        (self.pk / "game.img").unlink(); (self.pk / "romfs.img").write_bytes(sys_img)
        self.data = {"romfs.img": sys_img, "b": b"BB"}; (self.pk / "index.tsv").write_text("".join(self.row(k) for k in self.data))
        dev = self.device(); dev.head = lambda *a: self.fail("旧形态不该读机上头"); self.push_it(dev)
        self.assertEqual(dev.big, [f"{RP}/romfs.img"])


class SendProgress(Base):
    """#266：推送进度计数。3 批不同大小（上限 60 字节：a30+b30 | c50 | e90）；口径同手机蒙版：已在机上的 + 本次已到 / 整款"""
    def setUp(self):
        super().setUp()
        self.data = {"a": b"A" * 30, "b": b"B" * 30, "c": b"C" * 50, "e": b"E" * 90}
        for k, v in self.data.items(): (self.pk / k).write_bytes(v)
        (self.pk / "index.tsv").write_text("".join(self.row(k) for k in self.data))
        self.old = push.LIM; push.LIM = 60
        self.calls = []

    def tearDown(self): push.LIM = self.old; super().tearDown()

    def run_push(self, files):
        self.dev = Fake(files)
        return push.run(self.dev, self.pk, self.w, False, say=self.log.append, progress=lambda *a: self.calls.append(a))

    def test_three_batches_cumulative(self):
        self.run_push({})
        self.assertEqual(self.calls, [(0, 200, 0, 3), (60, 200, 1, 3), (110, 200, 2, 3), (200, 200, 3, 3)])

    def test_resume_counts_what_is_already_on_the_phone(self):   # 机上已有 a、b（60）：只推 c、e（两批 50 | 90），计数从 60 起、分母整款 200，和手机蒙版同一个百分比
        self.run_push(self.on_phone("a", "b"))
        self.assertEqual(self.calls, [(60, 200, 0, 2), (110, 200, 1, 2), (200, 200, 2, 2)])

    def test_nothing_to_push_reports_zero_total(self):   # 机上全有：只报一次 0/0，作业层见 total=0 不发计数（不画 0/0）
        self.run_push(self.on_phone("a", "b", "c", "e"))
        self.assertEqual(self.calls, [(0, 0, 0, 0)])

    def test_failed_batch_never_reports_done(self):   # 第一批就写满：不许报任何已完成量
        self.dev = Fake({}, full_disk=True)
        with self.assertRaises(push.Fail):
            push.run(self.dev, self.pk, self.w, False, say=self.log.append, progress=lambda *a: self.calls.append(a))
        self.assertEqual([c for c in self.calls if c[0] > 0], [])

    def test_transfer_list_written_once_before_any_batch(self):
        # 手机游戏库画装机蒙版用的传输清单：开推前写一次（之后不再写），列本次每个包的机上路径与字节数（期望按 3 批手算：a+b 60 | c 50 | e 90）
        self.run_push({})
        tr = f"{RP}/.transfer"
        self.assertEqual(self.dev.puts.count(tr), 1)
        self.assertLess(self.dev.puts.index(tr), min(i for i, r in enumerate(self.dev.puts) if "/.incoming/" in r))
        t = json.loads(self.dev.files[tr])
        self.assertEqual((t["total"], t["base"]), (200, 0))   # 新手机：整包 200 都要传
        self.assertEqual([n for _, n in t["files"]], [60, 50, 90])
        self.assertEqual([p for p, _ in t["files"]], [r[len(RP) + 1:] for r in self.dev.puts if "/.incoming/" in r])

    def test_resume_counts_what_is_already_on_phone(self):   # 机上已有 a、b（60）：这次传 c、e（140），base = 整包 200 − 140
        self.run_push(self.on_phone("a", "b"))
        t = json.loads(self.dev.files[f"{RP}/.transfer"])
        self.assertEqual((t["total"], t["base"]), (140, 60))

    def test_nothing_to_push_writes_no_transfer_list(self):
        self.run_push(self.on_phone("a", "b", "c", "e"))
        self.assertNotIn(f"{RP}/.transfer", self.dev.puts)

    def test_stages_before_pushing(self):
        # ⑫ 推之前的准备子阶段按序报：核对手机上的文件 → 检查手机空间（有东西要推才查）
        stages = []
        self.dev = Fake({})
        push.run(self.dev, self.pk, self.w, False, say=self.log.append, stage=lambda name, d=None, t=None: stages.append(name))
        self.assertEqual(stages, [push.STAGE_CHECK, push.STAGE_SPACE])
        stages.clear(); self.dev = Fake(self.on_phone("a", "b", "c", "e"))
        push.run(self.dev, self.pk, self.w, False, say=self.log.append, stage=lambda name, d=None, t=None: stages.append(name))
        self.assertEqual(stages, [push.STAGE_CHECK])   # 机上全有：不查空间

    def test_stage_line_matches_job_parser(self):   # Mac 装机作业（pack/jobs/install.py push_pack）按这个格式解析准备子阶段
        import re
        line = f"{push.STAGE_PREFIX} {push.STAGE_IMAGE}\t{5}\t{17}"
        m = re.match(r"S2A_PUSH_STAGE (.+?)\t(\d*)\t(\d*)$", line)
        self.assertEqual(m.groups(), (push.STAGE_IMAGE, "5", "17"))
        self.assertEqual(re.match(r"S2A_PUSH_STAGE (.+?)\t(\d*)\t(\d*)$", f"{push.STAGE_PREFIX} {push.STAGE_CHECK}\t\t").groups(), (push.STAGE_CHECK, "", ""))

    def test_cli_progress_lines(self):   # Mac 装机作业读的机器行
        line = push.PROGRESS_PREFIX + " 60 200 1 3"
        self.assertRegex(line, r"^S2A_PUSH_PROGRESS \d+ \d+ \d+ \d+$")


class LockedProbe(Base):
    """#333：推之前先写几字节探针；写不进就停，不核账、不推一个文件。
    11-13：写不进不等于锁屏——手机说锁着（lock_state True）才报 DeviceLocked；没锁 / 判不了先隔一会儿重写一次，
    还不行报连接问题（普通 Fail，带原文），判不了锁屏状态时报错原文带锁屏字样才认锁屏"""
    def failing(self, fails, lock=None, text="Operation timed out; abandoned"):   # 前 fails 次写探针失败（原文 text）；lock_state 回 lock
        dev = Fake(self.on_phone("a")); n = [0]; real = dev.put
        def put(src, rel):
            if rel.endswith(push.PROBE):
                n[0] += 1
                if n[0] <= fails: raise push.Fail(f"资源包写进 iPhone 时中断（{text}）")
            real(src, rel)
        dev.put = put
        if lock is not None: dev.lock_state = lambda: lock
        dev.writes = n   # 写探针的次数
        return dev

    def run_probe(self, dev):
        with mock.patch.object(push.time, "sleep"):
            return push.run(dev, self.pk, self.w, False, say=self.log.append)

    def test_locked_phone_stops_before_any_push(self):
        dev = self.failing(9, lock=True)
        dev.put_tar = lambda *a: self.fail("锁屏时不该推资源")
        with self.assertRaises(push.DeviceLocked) as e:
            self.run_probe(dev)
        self.assertEqual(e.exception.code, "device_locked")
        self.assertIn("锁屏", str(e.exception))
        self.assertEqual(dev.writes[0], 1)   # 手机说锁着：不再白写第二次

    def test_unlocked_transient_stall_retries_and_pushes(self):   # 11-13 实测形态：没锁，写探针挂一次 → 再写一次成了，照推
        dev = self.failing(1, lock=False)
        self.run_probe(dev)
        self.assertEqual(dev.writes[0], 2)
        self.assertIn(f"{RP}/index.tsv", dev.files)

    def test_unlocked_persistent_failure_is_connection_not_locked(self):
        dev = self.failing(9, lock=False)
        dev.put_tar = lambda *a: self.fail("写不进时不该推资源")
        with self.assertRaises(push.Fail) as e:
            self.run_probe(dev)
        self.assertNotIsInstance(e.exception, push.DeviceLocked)
        self.assertIsNone(getattr(e.exception, "code", None))
        self.assertIn("Operation timed out", str(e.exception))
        self.assertIn("没有锁屏", str(e.exception))
        self.assertNotIn("锁屏了", str(e.exception))

    def test_unknown_lock_state_uses_error_text(self):   # Windows / 判不了：原文带锁屏字样才认锁屏
        with self.assertRaises(push.DeviceLocked):
            self.run_probe(self.failing(9, text="unexpected response from device: XPC response missing CoreDevice.output"))
        with self.assertRaises(push.Fail) as e:
            self.run_probe(self.failing(9, text="AFC 连接被重置"))
        self.assertNotIsInstance(e.exception, push.DeviceLocked)
        self.assertIn("AFC 连接被重置", str(e.exception))

    def test_retry_prefers_stream_channel(self):   # Mac：devicectl 写挂了，第二次走推包本身用的 s2a-devpush 通道
        dev = self.failing(9, lock=False); side = Fake({})
        dev.dp = side
        self.run_probe(dev)
        self.assertEqual(side.puts, [f"{RP}/{push.PROBE}"])

    def test_probe_goes_into_the_pack_folder_and_push_continues(self):
        self.go({})
        self.assertEqual(self.dev.puts[0], f"{RP}/{push.PROBE}")
        self.assertIn(f"{RP}/index.tsv", self.dev.files)


class InflightProgress(Base):
    def test_child_progress_is_delivered_before_child_exit(self):
        # 子进程必须等回调写确认文件才退出；capture_output 等退出的旧实现必红。
        script = self.w / "child.py"; ack = self.w / "ack"
        script.write_text('''import pathlib, sys, time
print("S2A_DEVPUSH_PROGRESS 40", flush=True)
end = time.monotonic() + 2
while not pathlib.Path(sys.argv[-1]).exists() and time.monotonic() < end:
    time.sleep(0.01)
sys.exit(0 if pathlib.Path(sys.argv[-1]).exists() else 1)
''')
        dev = push.Devpush(sys.executable, "-u", str(script), self.w)
        seen = []
        def report(n): seen.append(n); ack.touch()
        dev.progress = report
        dev.put(self.pk / "a", ack)
        self.assertEqual(seen, [40])

    def test_old_helper_output_still_succeeds_without_progress(self):
        script = self.w / "old.py"
        script.write_text('print("put 1 字节")\n', encoding="utf-8")
        dev = push.Devpush(sys.executable, "-u", str(script), self.w)
        seen = []; dev.progress = seen.append
        dev.put(self.pk / "a", "remote")
        self.assertEqual(seen, [])
        self.assertIn("put 1 字节", (self.w / "devpush.log").read_text())

    def test_streaming_error_keeps_diagnostics(self):
        script = self.w / "fail.py"
        script.write_text('import sys\nprint("S2A_DEVPUSH_PROGRESS 40", flush=True)\nprint("AFC write failed", file=sys.stderr)\nsys.exit(1)\n')
        dev = push.Devpush(sys.executable, "-u", str(script), self.w)
        seen = []; dev.progress = seen.append
        with self.assertRaisesRegex(push.Fail, "AFC write failed"):
            dev.put(self.pk / "a", "remote")
        self.assertEqual(seen, [40])

    def image_plan(self):
        (self.pk / "romfs.img").write_bytes(b"x" * 100)
        (self.w / "direct_img.tsv").write_text("romfs.img\t100\timage-sha\n")

    def test_image_inflight_is_bounded_and_not_completed_or_ledgered(self):
        self.image_plan(); dev = Fake({}); calls = []
        def put_big(*args):
            for n in (40, 20, 100, 999): dev.progress(n)
            self.assertFalse((self.w / "pushed").exists())
        dev.put_big = put_big
        push.send(dev, self.pk, self.w, progress=lambda *a: calls.append(a))
        self.assertEqual(calls, [(0, 100, 0, 1), (40, 100, 0, 1), (99, 100, 0, 1), (100, 100, 1, 1)])
        self.assertIsNone(dev.progress)

    def test_partial_image_failure_never_reports_completion(self):
        self.image_plan(); dev = Fake({}); calls = []
        def put_big(*args):
            dev.progress(40); raise push.Fail("断开")
        dev.put_big = put_big
        with self.assertRaises(push.Fail):
            push.send(dev, self.pk, self.w, progress=lambda *a: calls.append(a))
        self.assertEqual(calls, [(0, 100, 0, 1), (40, 100, 0, 1), (40, 100, 0, 1)])   # 直写失败原地再试一次（11-12）：第二次又报到 40，仍不报满
        self.assertNotIn(f"{RP}/.pushed", dev.files)
        self.assertIsNone(dev.progress)

    def test_batches_add_payload_to_completed_bytes(self):
        (self.w / "push_000.tsv").write_text("a\t1\ta-sha\n")
        (self.w / "push_001.tsv").write_text("b\t2\tb-sha\n")
        dev = Fake({}); calls = []
        put_tar = dev.put_tar
        def streaming(*args):
            dev.progress(1)
            return put_tar(*args)
        dev.put_tar = streaming
        push.send(dev, self.pk, self.w, progress=lambda *a: calls.append(a))
        self.assertEqual(calls, [(0, 3, 0, 2), (1, 3, 1, 2), (2, 3, 1, 2), (3, 3, 2, 2)])

    def test_mac_delegates_inflight_to_devpush(self):
        self.image_plan(); calls = []
        dev = push.Devicectl("device", "bundle", self.w)
        dev.why = "合成流式工具"
        dev.dp = Fake({}); dev.put = lambda *a: None
        dev.dp.put = lambda *a: dev.dp.progress(40)
        push.send(dev, self.pk, self.w, progress=lambda *a: calls.append(a))
        self.assertEqual(calls, [(0, 100, 0, 1), (40, 100, 0, 1), (100, 100, 1, 1)])
        self.assertIsNone(dev.dp.progress)


class SendFail(Base):
    def test_nospc(self):
        with self.assertRaises(push.Fail) as e: self.go({}, full_disk=True)
        self.assertIn("测试设备空间不足", str(e.exception)); self.assertNotIn(f"{RP}/.pushed", self.dev.files)   # 没写完的批不记账


if __name__ == "__main__":
    unittest.main()
