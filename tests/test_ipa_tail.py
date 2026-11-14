#!/usr/bin/env python3
"""出包收尾（pack/ipa_tail.py）单测；期望按规则手写，不跑被测实现推。
① 直连库版本（只有直连，11-07：Info.plist 的 S2AGraphicsMode 恒 direct，这里只判库版本 S2ADirectLibVersion；按宿主运行时判法「NVN b-<链> 或 Vulkan vk/」）：
   NVN b-<链>/ + keys.tsv → b-<链>；缺 keys.tsv → 空；Vulkan 同 GL 以表为准：vk/vk_shaders.tsv（+ metallib）→ vk，只有表头（RomFS 没有 SPIR-V 的款）→ vk，只有 metallib 没有表 → 空；
   OpenGL gl/gl_shaders.metallib + .tsv → gl，离线 0 支（只有表头）→ gl，只有 metallib 没有表 → 空；什么都没有（早装件）→ 空
② 着色器目标：gal_pso.applegpu_g18p.ios27.0.bin / .1.bin、gal_pso.applegpu_g17p.ios26.0.bin、gal_dl.* → 「applegpu_g17p.ios26,applegpu_g18p.ios27」；没有归档 → 空
③ 包号 = <提交号>-<sha256(包键 + 换行) 前 8 位>（本文件另算）
④ 实跑 Info.plist 写入（app_bundle.py update_metadata，同 ipa_tail 用的调用）：包号与着色器目标读回一致、未知布尔键保留；空着色器目标 → 删掉旧键
⑥ 开发设施开关（S2ADevFacilities）：S2A_PACK_PURPOSE=user → "0"（玩家包关）；没设 / 别的用途 → 空串（删键 = 开发设施开）
⑤ 签名方式：非 Mac 上 adhoc / dev → 退 1 报红；dev 没给团队 → 退 1
⑦ 「打 ipa」失败要带出真正的原因（11-08 反馈：出包 2/5、错误码 package_failed「原因没认出来」）：archive_reason 红行优先、否则日志最后一行
   （python traceback 的末行 = 异常本身），日志缺失给空串——调用方据此把原因写进红行与错误摘要
⑧ 资源包要件（check_pack_inputs）认「抽取缺口的空直连库」（runtime_only.txt + b-<链>/{lib.idx,inputs.tsv,shader_map.tsv}）：
   空 keys.tsv / shader_map.tsv 是它的正常形态，不判「直连库不全」；真残缺（无 runtime_only.txt，或 b-<链>/ 缺件）照旧判红
⑨ 出包进度「出包 n/m」（维护者截图「出包 6/5」）：各分支（签名 adhoc / dev / none × 只出程序与否 × 调用方先出壳与否）真跑 assemble（外部命令打桩），
   数写进 S2A_PROGRESS 的进度行：每行步号 ≤ 总数，最后一行步号 = 总数；总数按手数的分支步数写期望（组装 + 签名? + 打 ipa + 资源包三步?）
"""
import contextlib, hashlib, io, os, plistlib, subprocess, sys, tempfile, unittest, zipfile
from unittest import mock
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pack"))
import ipa_tail  # noqa: E402


class Tail(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())

    def mk(self, name, files):
        r = self.t / name
        for f, b in files.items():
            (r / f).parent.mkdir(parents=True, exist_ok=True)
            if b is None: (r / f).mkdir(exist_ok=True)
            else: (r / f).write_bytes(b)
        (r / "shaders").mkdir(parents=True, exist_ok=True)
        return str(r)

    def test_direct_lib_version(self):
        nvn = self.mk("nvn", {"shaders/direct/b-2b1fd180ed01": None, "shaders/direct/keys.tsv": b"k"})
        nok = self.mk("nok", {"shaders/direct/b-2b1fd180ed01": None})
        vk = self.mk("vk", {"shaders/direct/keys.tsv": b"k", "shaders/direct/vk/vk_shaders.metallib": b"lib", "shaders/direct/vk/vk_shaders.tsv": b"# s2arm-vk-lib 3\nk\tvert\t\t-\n"})
        vk0 = self.mk("vk0", {"shaders/direct/keys.tsv": b"", "shaders/direct/vk/vk_shaders.tsv": b"# s2arm-vk-lib 3\n"})   # RomFS 没有 SPIR-V（银河）：只有表头、没有库
        vknotab = self.mk("vknotab", {"shaders/direct/vk/vk_shaders.metallib": b"lib"})
        gl = self.mk("gl", {"shaders/direct/gl/gl_shaders.metallib": b"lib", "shaders/direct/gl/gl_shaders.tsv": b"# s2arm-gl-lib 2\n"})
        gl0 = self.mk("gl0", {"shaders/direct/gl/gl_shaders.tsv": b"# s2arm-gl-lib 2\n"})
        glnotab = self.mk("glnotab", {"shaders/direct/gl/gl_shaders.metallib": b"lib"})
        none = self.mk("none", {})
        got = [ipa_tail.direct_lib_version(d) for d in (nvn, nok, vk, vk0, vknotab, gl, gl0, glnotab, none)]
        self.assertEqual(got, ["b-2b1fd180ed01", "", "vk", "vk", "", "gl", "gl", "", ""])

    def test_pso_target_and_build_id(self):
        d = self.mk("pt", {f"shaders/{f}": b"" for f in ("gal_pso.applegpu_g18p.ios27.0.bin", "gal_pso.applegpu_g18p.ios27.1.bin",
                                                         "gal_pso.applegpu_g17p.ios26.0.bin", "gal_dl.applegpu_g18p.ios27")})
        self.assertEqual(ipa_tail.pso_target(d), "applegpu_g17p.ios26,applegpu_g18p.ios27")
        self.assertEqual(ipa_tail.pso_target(self.mk("e", {})), "")
        pk = "8cf4073a1 cur=/x/roots/botw@sh-1 vamm=alias sign=adhoc"
        self.assertEqual(ipa_tail.build_id(pk), "8cf4073a1-" + hashlib.sha256((pk + "\n").encode()).hexdigest()[:8])

    def test_archive_reason_prefers_red_line_then_last_line(self):
        red = self.t / "archive.log"
        red.write_text("起步\n【红】App 组装：非 zip64 的 IPA 装不下这份 App：9 个条目、文件合计 123456 字节\n", encoding="utf-8")
        self.assertEqual(ipa_tail.archive_reason(str(red)),
                         "【红】App 组装：非 zip64 的 IPA 装不下这份 App：9 个条目、文件合计 123456 字节")
        trace = self.t / "trace.log"
        trace.write_text("Traceback (most recent call last):\n  File \"app_bundle.py\", line 1, in write_ipa\nOSError: [Errno 28] No space left on device\n",
                         encoding="utf-8")
        self.assertEqual(ipa_tail.archive_reason(str(trace)), "OSError: [Errno 28] No space left on device")
        empty = self.t / "empty.log"
        empty.write_text("", encoding="utf-8")
        self.assertEqual((ipa_tail.archive_reason(str(empty)), ipa_tail.archive_reason(str(self.t / "missing.log"))), ("", ""))

    def test_check_pack_inputs_accepts_runtime_only_lib(self):
        # #11：9.78 GB 的 PERSONA4 The GOLDEN 抽取缺口 → 空直连库（runtime_only_lib.sh），出包被「直连库不全」挡死
        chain = "b-0be3f28548fd"
        root = self.mk("runonly", {"exefs/main.npdm": b"npdm", "ctl/control.nacp": b"nacp", "systemdata/fonts/x.ttf": b"font",
                                   "shaders/direct/keys.tsv": b"", "shaders/direct/shader_map.tsv": b"",
                                   "shaders/direct/runtime_only.txt": "本款离线直连库为空（离线 0 支），运行时首遇现编\n".encode(),
                                   f"shaders/direct/{chain}/lib.idx": b"S2ALIB\0\0\1\0\0\0\0\0\0\0\0\0\u0000be3f28548fd\0\0\0\0\0\0",
                                   f"shaders/direct/{chain}/inputs.tsv": b"game\t010062B01525C000\ninputs\truntime-only-1e76a11a42b5\n"})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            ipa_tail.check_pack_inputs(root, "t010062b01525c000")
        self.assertIn("离线直连库为空", out.getvalue())
        self.assertNotIn("没带直连库", out.getvalue())   # 空库不是「没带库」：包里带着 b-<链>，宿主按直连起

        # 真残缺：b-<链>/ 在、keys.tsv 有内容、shader_map.tsv 空，又没有 runtime_only.txt → 照旧判红
        broken = self.mk("broken", {"exefs/main.npdm": b"npdm", "ctl/control.nacp": b"nacp", "systemdata/fonts/x.ttf": b"font",
                                    "shaders/direct/keys.tsv": b"k\tvert\n", "shaders/direct/shader_map.tsv": b"",
                                    f"shaders/direct/{chain}/lib.idx": b"S2ALIB"})
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ipa_tail.Red) as got:
            ipa_tail.check_pack_inputs(broken, "t010062b01525c000")
        self.assertIn("直连库不全", str(got.exception))

        # runtime_only.txt 在但 b-<链>/ 缺 lib.idx（阶段写了一半）→ 不算空库，照旧判红
        half = self.mk("half", {"exefs/main.npdm": b"npdm", "ctl/control.nacp": b"nacp", "systemdata/fonts/x.ttf": b"font",
                                "shaders/direct/keys.tsv": b"", "shaders/direct/shader_map.tsv": b"",
                                "shaders/direct/runtime_only.txt": b"gap\n", f"shaders/direct/{chain}/inputs.tsv": b"game\tx\n"})
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ipa_tail.Red):
            ipa_tail.check_pack_inputs(half, "t010062b01525c000")

    def test_plist_write(self):
        app = self.t / "S2Arm.app"; app.mkdir(); (app / "S2Arm").write_bytes(b"x")
        with open(app / "Info.plist", "wb") as f: plistlib.dump({"CFBundleExecutable": "S2Arm", "KeepBoolean": True, "S2APsoTarget": "old"}, f)
        d = self.mk("pt2", {"shaders/gal_pso.applegpu_g18p.ios27.0.bin": b""})
        for k, v in (("S2ABuildID", "c1-abcdef12"), ("S2APsoTarget", ipa_tail.pso_target(d))):
            subprocess.run([sys.executable, str(ROOT / "pack/app_bundle.py"), "update_metadata", str(app), "--set", f"{k}={v}"], check=True)
        p = plistlib.load(open(app / "Info.plist", "rb"))
        self.assertEqual((p["S2ABuildID"], p["S2APsoTarget"], p["KeepBoolean"]), ("c1-abcdef12", "applegpu_g18p.ios27", True))
        subprocess.run([sys.executable, str(ROOT / "pack/app_bundle.py"), "update_metadata", str(app), "--set", f"S2APsoTarget={ipa_tail.pso_target(self.mk('e2', {}))}"], check=True)
        p = plistlib.load(open(app / "Info.plist", "rb"))
        self.assertNotIn("S2APsoTarget", p); self.assertEqual(p["S2ABuildID"], "c1-abcdef12")

    def test_sign_mode_guard(self):
        base = [sys.executable, str(ROOT / "pack/ipa_tail.py"), "--work", str(self.t), "--game", "g", "--shell", str(self.t), "--bundle-id", "b",
                "--key", "c k", "--title", "t"]
        r = subprocess.run(base + ["--sign", "dev"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertIn("【红】", r.stdout)
        if sys.platform != "darwin":
            r = subprocess.run(base + ["--sign", "adhoc"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1); self.assertIn("只能在 Mac", r.stdout)


class ProgressTotal(unittest.TestCase):
    """⑨ 期望按分支手数：组装 1 + 签名（adhoc / dev 才有）1 + 打 ipa 1 + 资源包 / 核对 / 单文件镜像（不是只出程序才有）3，再加调用方已走的出壳步"""
    def run_tail(self, sign, app_only, done):
        t = Path(tempfile.mkdtemp()); w = t / "work"; shell = t / "shell"
        (shell / "root/gal_helpers/m3").mkdir(parents=True); (shell / "root/gal_helpers/m3/a.metallib").write_bytes(b"m")
        prog = t / "progress.tsv"
        def step(tl, name, cmd, log=None, mode="a", env=None):
            ipa_tail.tick()
            if name == "组装（预编壳）": (w / "build/ios/S2Arm.app").mkdir(parents=True, exist_ok=True)
            if name == "打ipa":
                with zipfile.ZipFile(cmd[-1], "w") as z: z.writestr("Payload/S2Arm.app/gal_helpers/m3/a.metallib", b"m")
            return 0
        a = mock.Mock(work=str(w), game="g", shell=str(shell), bundle_id="b", suffix="", key="k", title="t", sign=sign, team="T",
                      save_identity="", app_only=app_only)
        argv = ["ipa_tail.py", "--work", str(w), "--game", "g", "--shell", str(shell), "--bundle-id", "b", "--key", "k", "--title", "t", "--sign", sign, "--team", "T"] + (["--app-only"] if app_only else [])
        with mock.patch.dict(os.environ, {"S2A_PROGRESS": str(prog), "S2A_PKG_PROG_DONE": str(done)}), \
             mock.patch.object(ipa_tail, "PROG", [done, 0]), mock.patch.object(ipa_tail, "step", step), mock.patch.object(ipa_tail, "run", lambda *x, **k: 0), \
             mock.patch.object(ipa_tail, "build_id", lambda k: "id"), mock.patch.object(ipa_tail, "pso_target", lambda w: ""), \
             mock.patch.object(ipa_tail, "direct_lib_version", lambda w: ""), mock.patch.object(ipa_tail, "check_pack_inputs", lambda w, g: None), \
             mock.patch.object(ipa_tail.pkg_srcs, "srcs", lambda w: []), mock.patch.object(ipa_tail.sys, "platform", "darwin"), \
             mock.patch.object(ipa_tail, "test_udids", lambda: ""), mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ipa_tail.main(), 0)
        return [tuple(int(x) for x in l.split("\t")[2:4]) for l in prog.read_text(encoding="utf-8").splitlines() if l.split("\t")[1] == "出包"]

    def test_every_branch_ends_exactly_at_total(self):
        for sign in ("adhoc", "dev", "none"):
            for app_only in (False, True):
                for done in (0, 1):   # 1 = 调用方本提交第一次出壳、已记过一步
                    want = done + 1 + (sign != "none") + 1 + (0 if app_only else 3)
                    with self.subTest(sign=sign, app_only=app_only, done=done):
                        rows = self.run_tail(sign, app_only, done)
                        self.assertEqual(rows[-1], (want, want))
                        self.assertTrue(all(n <= total == want for n, total in rows), rows)

    def test_count_steps_matches_plan(self):   # pack/ipa.sh 用它定出壳那步的总数
        for sign, app_only, want in (("dev", False, 6), ("none", False, 5), ("adhoc", True, 3), ("none", True, 2)):
            argv = ["ipa_tail.py", "--count-steps", "--work", "-", "--game", "-", "--shell", "-", "--bundle-id", "-", "--key", "-", "--title", "-", "--sign", sign] + (["--app-only"] if app_only else [])
            out = io.StringIO()
            with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
                self.assertEqual(ipa_tail.main(), 0)
            self.assertEqual(out.getvalue().strip(), str(want))


class DevFacilities(unittest.TestCase):
    def _with(self, v):
        old = os.environ.pop('S2A_PACK_PURPOSE', None)
        try:
            if v is not None: os.environ['S2A_PACK_PURPOSE'] = v
            return ipa_tail.dev_facilities()
        finally:
            os.environ.pop('S2A_PACK_PURPOSE', None)
            if old is not None: os.environ['S2A_PACK_PURPOSE'] = old

    def test_user_pack_off(self):   # 启动器给玩家出包：写 "0"，宿主 s2a_dev_on 判关
        self.assertEqual(self._with('user'), '0')

    def test_dev_packs_keep_on(self):   # 实验 / 普查 / 手测（不设或别的值）：空串 = update_metadata 删键 = 开
        self.assertEqual(self._with(None), '')
        self.assertEqual(self._with('exp'), '')

if __name__ == "__main__":
    unittest.main()
