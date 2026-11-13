"""装到 iPhone（pack/jobs/install.py，10-26）：选团队、包名、报错分类、整条流程（签名 / 装机 / 拷资源包打桩，IPA 夹具用 ditto 真解）。期望按规则手写"""
import json, os, plistlib, shutil, subprocess, sys, tempfile, time, types, unittest, zipfile
import unittest.mock as um
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install
from core import Failure, atomic
import tests.test_jobs as tj   # 只借 JobsTests 的夹具；不 from-import 类名，免得 unittest 把它整组再跑一遍
from tests.jobcase import ios_fixture
import layout


class ContainerVariantTest(unittest.TestCase):
    """S2A_CONTAINER_SUFFIX / S2A_CONTAINER_NAME：开发用的并存安装，不设时与玩家一致"""
    def test_suffix_changes_bundle_id_only_when_set(self):
        with um.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("S2A_CONTAINER_SUFFIX", None)
            self.assertEqual(install.container_bundle_id("TEAM1"), "io.s2arm.games.team1")
        with um.patch.dict(os.environ, {"S2A_CONTAINER_SUFFIX": "Feat/iCloud_Save Sync"}):
            self.assertEqual(install.container_bundle_id("TEAM1"), "io.s2arm.games.team1.featicloudsavesync")   # 只留小写字母 / 数字 / 连字符

    def test_display_name_rewrites_plist_strings_only_when_set(self):
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "S2Arm.app"; (app / "zh-Hans.lproj").mkdir(parents=True)
            strings = app / "zh-Hans.lproj/InfoPlist.strings"
            strings.write_text('"CFBundleDisplayName" = "S2Arm";\n"Other" = "x";\n', encoding="utf-8")
            with um.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("S2A_CONTAINER_NAME", None)
                self.assertIsNone(install.container_display_name(app))
                self.assertIn('"S2Arm"', strings.read_text(encoding="utf-8"))
            with um.patch.dict(os.environ, {"S2A_CONTAINER_NAME": "S2Arm·iCloud"}):
                self.assertEqual(install.container_display_name(app), "S2Arm·iCloud")
            text = strings.read_text(encoding="utf-8")
            self.assertIn('"CFBundleDisplayName" = "S2Arm·iCloud";', text)
            self.assertIn('"Other" = "x";', text)


class CableFirstTest(unittest.TestCase):
    """线连的优先：插线的一台 + 同网配对的另一台 = 一台（手算：只留 wired=True 的那行）；没有线连的就看网络的"""
    def test_cable_first(self):
        import target
        a, b = dict(id="USB", wired=True), dict(id="NET", wired=False)
        self.assertEqual(target.cable_first([b, a]), [a])
        self.assertEqual(target.cable_first([b]), [b])
        self.assertEqual(target.cable_first([]), [])

    def test_windows_usb_first(self):
        W = type("W", (), {"mux_devices": staticmethod(lambda: [("U1", "USB", 1), ("U2", "Network", 2), ("U1", "Network", 3)])})
        self.assertEqual(install.win_udids(W), ["U1"])
        W2 = type("W", (), {"mux_devices": staticmethod(lambda: [("U2", "Network", 2)])})
        self.assertEqual(install.win_udids(W2), ["U2"])

    def test_macos_usb_names_tolerate_invalid_ioreg_bytes(self):
        import target
        raw = b'"USB Product Name" = "iPad Pro"\n' + b'\xca' * 4 + b'"USB Product Name" = "iPhone 17"'
        def run_process(*args, **kwargs):
            output = raw.decode("utf-8") if kwargs.get("text") else raw
            return types.SimpleNamespace(stdout=output)
        with um.patch.object(target.subprocess, "run", side_effect=run_process) as run:
            self.assertEqual(target.usb_idevices(), ["iPad Pro", "iPhone 17"])
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertNotIn("text", run.call_args.kwargs)


class PickTests(unittest.TestCase):
    def test_team_choice_and_container_bundle_id(self):
        free = dict(id="TEAM1", name="个人", free=True); paid = dict(id="PAID1", name="付费", free=False)
        self.assertEqual(install.pick_team([free, paid])["id"], "PAID1")   # 有付费团队用付费的
        self.assertEqual(install.pick_team([free])["id"], "TEAM1")          # 只有免费的用免费的
        self.assertEqual(install.pick_team([free, paid], "TEAM1")["id"], "TEAM1")
        with um.patch.object(install, "xcode_account", return_value=(False, [])), self.assertRaises(Failure) as e: install.pick_team([])
        self.assertEqual(e.exception.code, "xcode_account_missing")   # 没登录
        with um.patch.object(install, "xcode_account", return_value=(True, [])), self.assertRaises(Failure) as e: install.pick_team([])
        self.assertEqual(e.exception.code, "xcode_team_pending")      # 登录了但团队没同步（11-08 Spare-host 实走）
        self.assertEqual(install.classify("error: No signing certificate \"iOS Development\" found"), "signing_certificate_missing")
        self.assertEqual(install.container_bundle_id("TEAM1"), "io.s2arm.games.team1")                  # 多款容器：团队专属固定包名，与款无关
        self.assertEqual(install.game_docs("0100c2500fc20000"), "Documents/games/0100C2500FC20000")            # 每款设备侧文档根（游戏号大写，同容器 Games/<游戏号>）
        self.assertEqual(install.game_pack("0100c2500fc20000"), "Library/Application Support/S2Arm/games/0100C2500FC20000/资源包")   # 资源包根挪出 Documents（11-11）
        self.assertEqual(install.game_pack_old("0100c2500fc20000"), "Documents/games/0100C2500FC20000/资源包")
        self.assertEqual(install.game_ctx("0100c2500fc20000"), "@bundle/Games/0100C2500FC20000/launch.ctx")

    def test_classify_signing_errors(self):
        # Apple 9120（7 天 10 个包名，删 App 不退）与设备同时 3 个自签 App 是两件事，各报各的码
        self.assertEqual(install.classify("error: Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days."), "free_appid_limit")
        self.assertEqual(install.classify("The maximum number of apps for free development profiles has been reached."), "free_app_limit")   # 较早 iOS 的装机原文：说的是装上的 apps
        self.assertEqual(install.classify("This device has reached the maximum number of installed apps using a free developer profile"), "free_app_limit")   # 11-06 iOS 27 原文
        self.assertEqual(install.classify('error: No Account for Team "TEAM1".'), "xcode_account_missing")
        self.assertEqual(install.classify("error: something else"), "signing_failed")

    FAKE_TEAM = "ABCDE" + "12345"
    FAKE_OU = "TEAM12" + "3456"

    def test_manual_team_id_is_tried_even_when_not_detected(self):
        self.assertEqual(install.pick_team([], self.FAKE_TEAM), dict(id=self.FAKE_TEAM, name="", free=True))
        with self.assertRaises(Failure) as e: install.pick_team([], "bad id")
        self.assertIn("Team ID", str(e.exception))

    @unittest.skipUnless(shutil.which("openssl") and os.path.exists("/usr/bin/openssl"), "需要 /usr/bin/openssl")
    def test_keychain_certificate_gives_team_without_xcode_cache(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN=Apple Development: X ({self.FAKE_TEAM})/OU={self.FAKE_OU}/O=X/C=US",
                            "-keyout", d + "/k", "-out", d + "/c"], check=True, capture_output=True)
            pem = open(d + "/c").read()
        good, other = "A" * 40, "B" * 40
        def security(args, env):
            if args[0] == "find-identity":
                return f'  1) {good} "Apple Development: X ({self.FAKE_TEAM})"\n  2) {other} "Developer ID Application: X ({self.FAKE_OU})"\n'
            return f"SHA-1 hash: {good}\n{pem}SHA-1 hash: {other}\n{pem}"
        with um.patch.object(install, "_security_text", security):
            self.assertEqual(install.keychain_teams(), [dict(id=self.FAKE_OU, name="", free=True)])   # 同一团队去重，Developer ID 不算
            with um.patch.object(install, "_xcode_prefs", return_value={}), um.patch.object(install, "profile_teams", return_value=[]):
                self.assertEqual(install.xcode_account()[1], [dict(id=self.FAKE_OU, name="", free=True)])
                self.assertEqual(install.pick_team(install.xcode_account()[1])["id"], self.FAKE_OU)
        with um.patch.object(install, "_security_text", return_value=""), um.patch.object(install, "_xcode_prefs", return_value={}):
            self.assertEqual(install.xcode_account(), (False, []))

    def test_signing_summary_has_counts_not_names(self):
        prefs = {"DVTDeveloperAccountManagerAppleIDLists": {"a": [{"identifier": "secret@example.com"}]}, "IDEProvisioningTeamByIdentifier": {"x": [{"teamID": "SECRET" + "1234", "teamName": "秘密团队"}]}}
        with um.patch.object(install, "_xcode_prefs", return_value=prefs), um.patch.object(install, "development_identities", return_value={"A"}), \
                um.patch.object(install.subprocess, "run", return_value=um.Mock(stdout="Xcode 27.1\nBuild")):
            text = install.signing_summary()
        self.assertEqual(text, "Xcode 27.1；账号 1 个；团队缓存键有；可用团队 1 个；开发证书 1 张")
        self.assertNotIn("secret", text); self.assertNotIn("秘密", text)

    def test_signing_project_is_stable_and_buildable_shape(self):
        import types, plistlib as _p
        with tempfile.TemporaryDirectory() as d:
            c = types.SimpleNamespace(private=Path(d))
            path = install.signing_project(c)["path"]
            text = (Path(path) / "project.pbxproj").read_text(encoding="utf-8")
            self.assertRegex(text, r'PRODUCT_BUNDLE_IDENTIFIER = "io\.s2arm\.signing\.h[0-9a-f]{10}"')
            self.assertNotIn("@BUNDLE@", text); self.assertNotIn("DEVELOPMENT_TEAM", text)
            self.assertEqual(install.signing_project(c)["path"], path)
            self.assertTrue((Path(d) / "signing-helper/App.swift").is_file())

    def test_prefs_with_control_characters_still_show_account(self):
        body = plistlib.dumps(dict(DVTDeveloperAccountManagerAppleIDLists=dict(a=[dict(identifier="x")]))).replace(b"<dict>", b"<dict><key>ext\x1bkey</key><string>v</string>", 1)
        with um.patch.object(install.subprocess, "run", return_value=um.Mock(returncode=0, stdout=body)):
            self.assertIn("DVTDeveloperAccountManagerAppleIDLists", install._xcode_prefs(None))
        with um.patch.object(install.subprocess, "run", return_value=um.Mock(returncode=0, stdout=b"not a plist")):
            self.assertEqual(install._xcode_prefs(None), {install.PREFS_UNREADABLE: True})

    def test_xcode_teams_reads_prefs(self):
        d = tempfile.mkdtemp(); fake = Path(d) / "defaults"
        prefs = plistlib.dumps({"IDEProvisioningTeamByIdentifier": {"acc": [{"teamID": "TEAM1", "teamName": "我", "isFreeProvisioningTeam": True}, {"teamID": "TEAM1"}]}})
        (Path(d) / "p.plist").write_bytes(prefs)
        fake.write_text(f'#!/bin/sh\ncat "{d}/p.plist"\n'); fake.chmod(0o755)
        self.assertEqual(install.xcode_teams(dict(os.environ, PATH=d + ":" + os.environ["PATH"])), [dict(id="TEAM1", name="我", free=True)])


class ShellSdkTests(unittest.TestCase):
    # 11-07 Duo 实测：旧 SDK 链接的壳在 iOS 新一代机型上按旧尺寸缩小居中 → 装机时比「壳链接 SDK 大版本」与「iPhone 系统大版本」
    def _app(self, sdk):
        import struct
        d = Path(tempfile.mkdtemp()) / "S2Arm.app"; d.mkdir()
        (d / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "S2Arm"}))
        seg = struct.pack("<II", 0x19, 72) + bytes(64)                                   # 先放一条无关的 LC_SEGMENT_64，确认按 cmdsize 往后走
        bv = struct.pack("<IIIIII", 0x32, 24, 2, 0x00120000, sdk, 0) if sdk is not None else b""   # LC_BUILD_VERSION：platform 2（iOS）、minos 18.0
        cmds = seg + bv
        hdr = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2 if bv else 1, len(cmds), 0, 0)
        (d / "S2Arm").write_bytes(hdr + cmds); return d

    def test_linked_sdk_decodes_nibbles(self):
        self.assertEqual(install.linked_sdk(self._app(0x001A0500) / "S2Arm"), (26, 5, 0))   # 0x1A=26、0x05=5
        self.assertEqual(install.linked_sdk(self._app(0x001B0100) / "S2Arm"), (27, 1, 0))
        self.assertIsNone(install.linked_sdk(self._app(None) / "S2Arm"))                  # 没有 LC_BUILD_VERSION
        bad = Path(tempfile.mkdtemp()) / "x"; bad.write_bytes(b"#!/bin/sh\n"); self.assertIsNone(install.linked_sdk(bad))

    def test_warns_only_when_phone_newer_than_sdk(self):
        for sdk, os_ver, want in ((0x001A0500, "27.1", 1), (0x001B0100, "27.1", 0), (0x001A0500, "26.4", 0), (0x001A0500, "", 0)):
            c = um.Mock(); install.check_shell_sdk(c, self._app(sdk), {"os": os_ver})
            self.assertEqual(c.diagnostic.call_count, want, (hex(sdk), os_ver))
            if want:
                self.assertEqual(c.diagnostic.call_args.kwargs, dict(code="shell_sdk_old", severity="warning"))
                self.assertIn("iOS 26.5", c.diagnostic.call_args.args[0]); self.assertIn("iOS 27.1", c.diagnostic.call_args.args[0])


_phone_games = install.phone_games   # 真的那份：下面的夹具把 install.phone_games 换成「手机上没有别的游戏」，要走真读法的用例再换回来


def _jobs_setup_no_phone_games(self):
    """JobsTests 的夹具 + 手机上没有别的游戏（install.phone_games 替身：这些用例不测「读手机游戏清单」，那条另有用例）"""
    tj.JobsTests.setUp(self)
    p = um.patch.object(install, "phone_games", lambda c, ph: set()); p.start(); self.addCleanup(p.stop)


class FlowTests(unittest.TestCase):
    setUp = _jobs_setup_no_phone_games; tearDown = tj.JobsTests.tearDown   # 只借夹具（临时游戏库 / 私有目录 / 任务上下文），不继承它的用例

    def _fixture(self, gid):
        """这款出好的 iPhone 版（本壳 SHELL1 出的容器件 + 资源包 cafe01）→ (image/ios, 资源包)"""
        kit, pack = ios_fixture(self.c, gid, shell="SHELL1")
        return kit.parent, pack

    def _real_ipa(self, path):
        """写真 zip ipa（sign_and_install 用 ditto 真解，要 PKZip 签名）"""
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "io.s2arm.games", "CFBundleExecutable": "S2Arm"}))
            z.writestr("Payload/S2Arm.app/S2Arm", b"bin")

    def _install(self, gid, pushed, applied_before, mbps=0, unpack_ok=True, existing=(), cant_open=False, locked=False):
        """跑 install.install（容器流程）：替身 assemble 出容器（含已有各款 + 本款）、签名装机、只推 fresh 的款。
        existing = 这台手机上已有的款（同壳、资源包号与设备记录一致），现组时带上、不再推。替身按 push_pack.apply 口径记起 App 解包"""
        if existing:
            self.c.catalog = lambda: {"games": [{"id": g, "name": g} for g in (gid, *existing)]}
            layout.save_device(self.c, "00000000-0000000000000002", dict(games={g: dict(pack="cafe01") for g in existing}))
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        runs, seen, launches, state = [], {}, [], {"applied": applied_before, "unpack": "10-01 09:00:00 解开 3 个包 9 个文件 1 MB，.applied = cafe01（0.2 秒）\n"}
        all_games = list(existing) + [gid]
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]; runs.append(args)
            if len(args) > 5 and args[4].endswith("ship_ext.py") and args[5] == "container":
                o = Path(args[args.index("--out") + 1]); o.mkdir(parents=True, exist_ok=True)
                (o / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "shell_id": "SHELL1", "games": [{"title_id": x} for x in all_games]}))
            if len(args) > 5 and args[4].endswith("app_bundle.py") and args[5] == "write_ipa":
                self._real_ipa(Path(args[7]))
            if args[1].endswith("dev_sign.py"): seen["bid"] = plistlib.loads((Path(args[2]) / "Info.plist").read_bytes())["CFBundleIdentifier"]
            if args[2].endswith("tools/push_pack.py"):
                seen["env"] = env; seen["progress_flag"] = "--progress-lines" in args
                if seen["progress_flag"]:   # 推包工具每推完一批打的机器读行（tools/push_pack.py --progress-lines）
                    for d, k in ((0, 0), (1 << 20, 1), (3 << 20, 2)): on_line(f"S2A_PUSH_PROGRESS {d} {3 << 20} {k} 2")
                if locked:   # #333：推之前写探针就写不进（探针在推送之前，和带不带 --apply 无关）
                    Path(log).parent.mkdir(parents=True, exist_ok=True)
                    Path(log).write_text("【红】" + ("iPhone 写不进资源包（Operation timed out; abandoned）。手机没有锁屏，是电脑和手机的连接出了问题：拔下数据线重新插好，再点一次。"
                                                    if locked == "conn" else "iPhone 写不进资源包：手机锁屏了。解锁手机、保持亮屏，再点一次。") + "\n", encoding="utf-8")
                    raise install.Failure("tool", code="tool_exit")
                on_line(f"[12:00:00] 资源包：推 {pushed} 个文件 3 MB，分 1 批 + 索引 + 清单（1 秒）")
                if "--apply" in args and not (pushed == 0 and state["applied"] == "cafe01"):
                    launches.append({"S2A_PACK_APPLY_ONLY": "1"})
                    on_line("[12:00:05] 机上解包 13/17")
                    if cant_open:
                        Path(log).parent.mkdir(parents=True, exist_ok=True)
                        Path(log).write_text("【红】资源包已传完，还差最后一步：在 iPhone 上打开 S2Arm（电脑这边打不开手机上的 App：起 App 失败：RSD 里没有 app_service）\n", encoding="utf-8")
                        raise install.Failure("tool", code="tool_exit")
                    if not unpack_ok:
                        Path(log).parent.mkdir(parents=True, exist_ok=True)
                        Path(log).write_text("【红】资源包推进去了，但机上解包 180 秒没有新进展（停在第 13 包）：打开这款游戏、保持在前台等它导入完\n", encoding="utf-8")
                        raise install.Failure("tool", code="tool_exit")
                    state["applied"] = "cafe01"
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "process", "launch"):
                launches.append(a)
                if unpack_ok: state["applied"] = "cafe01"; state["unpack"] += "11-06 12:00:00 解开 1 个包 2 个文件 0 MB，.applied = cafe01（0.1 秒）\n"
                return 0, {}, ""
            if a[:3] == ("device", "copy", "from"):
                src = a[a.index("--source") + 1]
                Path(a[a.index("--destination") + 1]).write_text(state["unpack"] if src.endswith("unpack.log") else state["applied"] + "\n", encoding="utf-8"); return 0, {}, ""
            return 0, {}, ""
        import core, diag, itertools, ipa as packer
        tick = itertools.count(1000.0, 1.0)   # 作业层进度节流按单调时钟 0.2 秒：替身里各行紧挨着打，让每次取时钟走 1 秒（真实推送每批几十秒、解包每包十几秒）
        with um.patch.object(install, "xcode_teams", return_value=[dict(id="TEAM1", name="我", free=True)]), \
             um.patch.object(install, "phone", return_value=dict(id="C891", name="测试设备2")), um.patch.object(install, "udid_of", return_value="00000000-0000000000000002"), \
             um.patch.object(install, "usb_mbps", return_value=mbps), \
             um.patch.object(packer, "current_shell_id", return_value="SHELL1"), um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(self.c, "run", run), um.patch.object(diag, "devicectl", devicectl), um.patch.object(install.time, "sleep"), \
             um.patch.object(install, "pick_pack_root", lambda c, ph, g: f"Library/Application Support/S2Arm/games/{g}/资源包"), \
             um.patch.object(core.time, "monotonic", lambda: next(tick)):
            r = install.install(self.c)
        return r, runs, seen, launches

    def test_push_batches_become_byte_progress(self):   # #266：推送阶段按批发字节计数（分母 = 本次待传 3 MB）；容器装机传完即装好，不再另起机上解包计数
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        r, runs, seen, launches = self._install(gid, pushed=2, applied_before="", unpack_ok=True)
        self.assertTrue(seen["progress_flag"])
        ev = [json.loads(l) for l in self.c.events.read_text(encoding="utf-8").splitlines() if l.strip()]
        push = [(e["done"], e["total"], e.get("unit")) for e in ev if e.get("message") == install.PUSHING and e["type"] == "progress"]
        self.assertEqual(push[-1], (3 << 20, 3 << 20, "B")); self.assertTrue(all(t == 3 << 20 and u == "B" for _, t, u in push))
        self.assertFalse(any(str(e.get("message", "")).startswith("机上解包") for e in ev))   # 不等机上解开
        self.assertTrue(r["openToFinish"])

    def test_locked_phone_push_reports_device_locked(self):   # #333：推包探针写不进 → device_locked，原因原话上屏（不是笼统的 resource_transfer_failed）
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        with self.assertRaises(install.Failure) as e:
            self._install(gid, pushed=2, applied_before="", locked=True)
        self.assertEqual(e.exception.code, "device_locked")
        self.assertIn("锁屏", str(e.exception))

    def test_probe_write_failure_unlocked_is_not_device_locked(self):   # 11-13：手机没锁、探针写不进（devicectl 超时）→ 连接问题带原文，不报 device_locked
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        with self.assertRaises(install.Failure) as e:
            self._install(gid, pushed=2, applied_before="", locked="conn")
        self.assertEqual(e.exception.code, "resource_transfer_failed")
        self.assertIn("Operation timed out", str(e.exception))
        self.assertNotIn("锁屏了", str(e.exception))

    def test_img_pack_is_done_once_transferred(self):   # 11-11：单一 IMG 形态传完并核过长度即装好，不带 --apply、不起 App 等机上解开，结果带 openToFinish
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        m = pack / "manifest.json"; data = json.loads(m.read_text()); data.update(version=3, format="img"); m.write_text(json.dumps(data))
        r, runs, seen, launches = self._install(gid, pushed=2, applied_before="")
        push = next(a for a in runs if a[2].endswith("tools/push_pack.py"))
        self.assertIn("run", push[3:]); self.assertNotIn("--apply", push)
        self.assertEqual(launches, [])                          # 没有为解包起 App
        self.assertTrue(r["openToFinish"]); self.assertNotIn("unpackPending", r)

    def test_install_signs_installs_and_pushes(self):
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        r, runs, seen, launches = self._install(gid, pushed=2, applied_before="")
        bid = "io.s2arm.games.team1"   # 容器包名：团队 + .games，与款无关
        ensure_profile = next(a for a in runs if "ensure_profile.sh" in a[1])
        self.assertEqual(ensure_profile[-2:], [str(self.c.engine / "pack/app.entitlements"), "00000000-0000000000000002"])   # 描述文件申请带设备 UDID（登记这台）
        self.assertIn(bid, ensure_profile); self.assertEqual(seen["bid"], bid)                                    # 签名前 Info.plist 已换成团队专属包名
        push = next(a for a in runs if a[2].endswith("tools/push_pack.py"))
        # 「装到手机卡 99%」：容器装机旧形态资源包也传完即装好，不带 --apply、不为解包起 App（App 打开时游戏库解开）
        self.assertIn("run", push[3:]); self.assertNotIn("--apply", push)
        self.assertIn(f"Documents/games/{gid}", push)   # 资源包推进本款文档根
        self.assertTrue(seen["env"]["S2A_DEVICECTL"].endswith("Resources/bin/devicectl"))
        self.assertEqual(seen["env"]["S2A_PUSH_UDID"], "00000000-0000000000000002")   # 推包脚本据 UDID 走 s2a-devpush 流式（11-06）
        self.assertEqual(launches, [])                                                                     # 不为解包起 App、不等机上解开
        self.assertEqual((r["device"], r["bundleId"], r["packFiles"], r["free"]), ("测试设备2", bid, 2, True))
        self.assertNotIn("unpackPending", r)
        self.assertTrue(r["openToFinish"])     # 成功页写「已传到 iPhone，打开 S2Arm 会自动完成安装」


    def test_container_install_paths(self):
        """装机走容器流程：包名 s2arm.<团队>.games；装前按 Documents/games/<游戏号> 拉见过的键、列存档；装后本款资源包推进本款文档根带启动上下文"""
        A, B = "0100000000010000", "0100000000020000"
        packs = {g: self._fixture(g)[1] for g in (A, B)}
        self.c.r.update(gameId=A)
        r, runs, seen, launches = self._install(A, pushed=1, applied_before="", existing=(B,))
        bid = "io.s2arm.games.team1"
        self.assertEqual(seen["bid"], bid)
        self.assertEqual(r["bundleId"], bid)
        push = [a[3:] for a in runs if a[2].endswith("tools/push_pack.py")]
        # put_game 只对 fresh 的款（本次 = A）推资源包；B 已在容器里，不再推
        self.assertEqual(len(push), 1)
        self.assertIn(f"Documents/games/{A}", push[0])
        self.assertEqual(push[0][push[0].index("--pack-root") + 1], f"Library/Application Support/S2Arm/games/{A}/资源包")   # 资源包根单独给（pick_pack_root 选的那处）
        self.assertIn(f"@bundle/Games/{A}/launch.ctx", push[0])

    def test_container_missing_pack_refuses_before_install(self):
        gid = "0100000000010000"
        # 有容器件但没有资源包（image/ios/pack）：ios_pack 拒绝，不走到找设备 / 组装
        kit = layout.image_ios(self.c, gid) / "kit"; kit.mkdir(parents=True); (kit / "main.npdm").write_bytes(b"META")
        self.c.r.update(gameId=gid)
        with um.patch.object(install, "phone_for", side_effect=AssertionError("不该走到找设备")):
            with self.assertRaises(Failure) as e: install.install(self.c)
        self.assertEqual(e.exception.code, "pack_missing")
        # 连容器件也没有（没出过 iPhone 版）：报「先打 iPhone 包」
        self.c.r.update(gameId="0100000000090000")
        with self.assertRaises(Failure) as e: install.install(self.c)
        self.assertEqual(e.exception.code, "job_failed"); self.assertIn("打 iPhone 包", str(e.exception))

    def test_container_assemble_uses_each_games_kit(self):
        """assemble：每款都从这款文件夹的 image/ios/kit 现组（--game），不带 --base 底包；--host-abi 必传；产物出到游戏库里的临时目录，只留 S2Arm.ipa"""
        import ipa as packer, host_update
        A, B = "0100000000010000", "0100000000020000"
        kits = {g: ios_fixture(self.c, g, shell="SID1")[0] for g in (A, B)}
        self.c.catalog = lambda: {"games": [{"id": A, "name": "甲"}, {"id": B, "name": "乙"}]}
        shell = self.c.private / "shell"; shell.mkdir(); (shell / "manifest.json").write_text("{}")
        runs = []
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]; runs.append(args)
            if len(args) > 5 and args[4].endswith("ship_ext.py") and args[5] == "container":
                o = Path(args[args.index("--out") + 1]); o.mkdir(parents=True, exist_ok=True)
                gs = [A] if args.count("--game") == 1 else [A, B]
                (o / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "shell_id": "SID1", "games": [{"title_id": x} for x in gs]}))
            if len(args) > 5 and args[4].endswith("app_bundle.py") and args[5] == "write_ipa":
                Path(args[7]).write_bytes(b"ipa")
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), \
             um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(packer, "release_version", return_value="9.8.7"), \
             um.patch.object(packer, "display_version", return_value="v9.8.7-dev+abc1234"), \
             um.patch.object(self.c, "run", run):
            ipa1, games1, sid1 = packer.assemble(self.c, A)
            ipa2, games2, sid2 = packer.assemble(self.c, A, [B])
        c1, c2 = [a for a in runs if len(a) > 5 and a[5] == "container"]
        for cmd in (c1, c2):
            self.assertNotIn("--base", cmd)
            self.assertEqual(cmd[cmd.index("--host-abi") + 1], str(host_update.HOST_ABI))
            self.assertEqual(cmd[cmd.index("--version") + 1], "9.8.7")   # 三端同号：电脑上 S2Arm 的发版号写进容器
            self.assertEqual(cmd[cmd.index("--display-version") + 1], "v9.8.7-dev+abc1234")   # 界面版本字同一来源
            # 组装时不签，写完容器摘要（#845，改 Info.plist）再统一 ad-hoc 签：签完再改会破坏签名（v0.3.6 候选 ⑥ codesign 不过）
            self.assertEqual((cmd[cmd.index("--sign") + 1], cmd[cmd.index("--shell") + 1]), ("none", str(shell)))
        signs = [i for i, a in enumerate(runs) if len(a) > 5 and a[5] == "sign"]
        conts = [i for i, a in enumerate(runs) if len(a) > 5 and a[5] == "container"]
        self.assertEqual(len(signs), 2)   # 每次组装签一次，排在各自的 container 之后
        for ci, si in zip(conts, signs):
            self.assertLess(ci, si); self.assertEqual(runs[si][runs[si].index("--sign") + 1], "adhoc")
        self.assertEqual([c1[i + 1] for i, x in enumerate(c1) if x == "--game"], [str(kits[A].resolve())])
        self.assertEqual([c2[i + 1] for i, x in enumerate(c2) if x == "--game"], [str(kits[A].resolve()), str(kits[B].resolve())])
        self.assertEqual((games1, games2, sid1, sid2), ([A], [A, B], "SID1", "SID1"))
        for ipa in (ipa1, ipa2):
            self.assertEqual(ipa.parent.parent, self.c.library); self.assertTrue(ipa.parent.name.startswith(".container-"))
            self.assertEqual(sorted(p.name for p in ipa.parent.iterdir()), ["S2Arm.ipa", "custom.json"])   # 组完删 S2Arm.app
        self.assertFalse(layout.phone_ipa(self.c).exists())   # 组装不碰默认位置根（装上之后才 commit_phone_ipa）
        # 没出过 iPhone 版的款报 container_stale（没有容器件）
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), \
             um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(self.c, "run", run):
            with self.assertRaises(Failure) as e: packer.assemble(self.c, "0100000000090000")
        self.assertEqual(e.exception.code, "container_stale")

    def test_container_program_number_mismatch_says_files_dont_match(self):
        """组装结果里这款的程序号（main.npdm）和游戏库的号（导入时 CNMT 发行号）不一样 → game_files_mismatch，原因说人话、两个号都给出；
        核对本身保留（玩家实报：把别的游戏的程序换进了这款的包里，放过去就推到手机上错的目录）"""
        import ipa as packer
        A, OTHER = "0100DD2053220000", "010051F0207B2000"
        ios_fixture(self.c, A, shell="SID1")
        self.c.catalog = lambda: {"games": [{"id": A, "name": "甲"}]}
        shell = self.c.private / "shell"; shell.mkdir(); (shell / "manifest.json").write_text("{}")
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]
            if len(args) > 5 and args[4].endswith("ship_ext.py") and args[5] == "container":
                o = Path(args[args.index("--out") + 1]); o.mkdir(parents=True, exist_ok=True)
                (o / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "shell_id": "SID1", "games": [{"title_id": OTHER}]}))
            if len(args) > 5 and args[4].endswith("app_bundle.py") and args[5] == "write_ipa":
                Path(args[7]).write_bytes(b"ipa")
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), \
             um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(packer, "release_version", return_value="9.8.7"), \
             um.patch.object(self.c, "run", run):
            with self.assertRaises(Failure) as e: packer.assemble(self.c, A)
        self.assertEqual(e.exception.code, "game_files_mismatch")
        text = str(e.exception)
        self.assertIn(OTHER, text); self.assertIn(A, text); self.assertIn("原版游戏文件重新导入", text)
        self.assertNotIn("产物根", text)

    def _ready(self, devices, teams=(dict(id="team-a", name="我", free=True),), rc=0, usb=(), raises=None, want="测试设备2"):
        """跑装机前清单：devicectl list devices 回 devices（手造的 devicectl 行），Xcode 团队 teams；want = 玩家选的那台（None = 没选）"""
        import diag
        if want is None: self.c.r.pop("device", None)
        else: self.c.r["device"] = want
        data = {"result": {"devices": list(devices)}}
        import target
        def devicectl(c, *a, timeout=0):
            if raises: raise raises
            if a[:3] == ("device", "info", "details"):
                return rc, {"result": next((d for d in devices if d["identifier"] == a[-1]), {})}, ""
            return rc, data, ""
        with um.patch.object(install, "xcode_teams", return_value=list(teams)), um.patch.object(diag, "devicectl", devicectl), \
             um.patch.object(target, "usb_idevices", return_value=list(usb)):
            r = install.readiness(self.c)
        return r, {i["id"]: i for i in r["items"]}

    @staticmethod
    def _dev(name="测试设备2", transport="wired", pairing="paired", devmode="enabled", tunnel="disconnected", platform="iOS", reality="physical"):
        return {"identifier": name, "hardwareProperties": {"reality": reality, "platform": platform},
                "connectionProperties": {"transportType": transport, "pairingState": pairing, "tunnelState": tunnel},
                "deviceProperties": {"name": name, "developerModeStatus": devmode}}

    def test_readiness_all_ready(self):
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        r, it = self._ready([self._dev()])
        self.assertTrue(r["ready"]); self.assertEqual(r["device"], "测试设备2")
        self.assertEqual([i["id"] for i in r["items"]], ["package", "appleId", "connected", "trusted", "developerMode", "deviceReady"])
        self.assertEqual(r["ipaPath"], "")   # 「显示 IPA」只指真有的那份：还没装过、默认位置根没有 S2Arm.ipa → 空（原先指这款 image/ios，打开的是游戏目录）
        layout.phone_ipa(self.c).write_bytes(b"ipa")                                  # 装过一次：默认位置根有整库共用的那份
        self.assertEqual(self._ready([self._dev()])[0]["ipaPath"], str(layout.phone_ipa(self.c)))
        self.assertEqual((r["account"], it["appleId"]["title"]), ("我", "已登录 Apple ID"))
        self.assertTrue(all(i["detail"] == "" for i in r["items"]))   # 好了的项不带说明

    def test_readiness_network_only_says_so(self):
        """没插线、只在同一网络上配对着（transport localNetwork）：能装，但「已连接」那项如实写网络连接、带建议插线（原先照样打勾「已用数据线连上」，11-11 玩家反馈）"""
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        r, it = self._ready([self._dev(transport="localNetwork")])
        self.assertTrue(it["connected"]["ok"])
        self.assertIn("同一 Wi-Fi", it["connected"]["title"]); self.assertEqual(it["connected"]["detail"], install.S_NETWORK)   # 标题写明走 Wi-Fi，说明提醒插线更稳
        r, it = self._ready([self._dev()])
        self.assertIn("（数据线）", it["connected"]["title"]); self.assertEqual(it["connected"]["detail"], "")   # 插着线：不提醒

    def test_probe_reports_why_device_list_unreadable(self):
        """出包页设备探测：读不到设备列表（超时）→ connected 空 + connectedError 带原因，界面据此说「读不到」而不是「把 iPhone 插上」；读得到 → connectedError 空"""
        import target
        with um.patch.object(target, "device_list", return_value=([], "读取设备列表超时：解锁手机，重新插一次数据线再试。", "timeout", "")), \
             um.patch.object(target, "models", return_value=[]), um.patch.object(target, "os_choices", return_value=[]), um.patch.dict(self.c.r, {}, clear=False):
            self.c.r.pop("quick", None)
            r = target.probe(self.c)
        self.assertEqual((r["connected"], r["connectedError"]), ([], "读取设备列表超时：解锁手机，重新插一次数据线再试。"))
        with um.patch.object(target, "device_list", return_value=([self._dev()], "", 0, "")), um.patch.object(target, "gpu_arch", return_value="g"), \
             um.patch.object(target, "models", return_value=[]), um.patch.object(target, "os_choices", return_value=[]):
            r = target.probe(self.c)
        self.assertEqual(([d["id"] for d in r["connected"]], r["connectedError"]), (["测试设备2"], ""))

    def test_readiness_steps_in_order(self):
        gid = "0100535012974000"; self.c.r.update(gameId=gid)   # 没出 iPhone 包
        r, it = self._ready([], teams=())                       # 没登录、没连
        self.assertFalse(r["ready"])
        self.assertEqual([i["id"] for i in r["items"] if i["blocking"]], ["package"])
        self.assertEqual(r["ipaPath"], "")
        self.assertEqual((it["package"]["ok"], it["package"]["who"]), (False, "app"))
        self.assertFalse(it["appleId"]["ok"]); self.assertIn("Apple Accounts", it["appleId"]["detail"]); self.assertIn("团队列表", it["appleId"]["detail"])
        self.assertFalse(it["connected"]["ok"])
        self.assertTrue(it["trusted"]["waiting"]); self.assertTrue(it["developerMode"]["waiting"])   # 没连上：后两项是「等前一步」，不报没打开
        self.assertEqual((it["trusted"]["detail"], it["developerMode"]["detail"]), ("", ""))
        # 连上了但没点信任：信任这项要玩家做，开发者模式仍在等
        r, it = self._ready([self._dev(pairing="unpaired", devmode=None)])
        self.assertTrue(it["connected"]["ok"]); self.assertFalse(it["trusted"]["ok"]); self.assertFalse(it["trusted"]["waiting"])
        self.assertTrue(it["developerMode"]["waiting"])
        # 信任了、开发者模式没开
        r, it = self._ready([self._dev(devmode="disabled")])
        self.assertTrue(it["trusted"]["ok"]); self.assertFalse(it["developerMode"]["ok"]); self.assertFalse(it["developerMode"]["waiting"])
        self.assertIn("开发者模式", it["developerMode"]["detail"])

    def test_readiness_only_package_blocks(self):
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)   # 出好了包，但没登录、没连手机
        r, it = self._ready([], teams=())
        self.assertTrue(r["ready"])
        self.assertFalse(it["appleId"]["ok"]); self.assertFalse(it["connected"]["ok"])
        self.assertEqual([i["id"] for i in r["items"] if i["blocking"]], [])

    def test_readiness_device_filtering(self):
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        # 模拟器、Mac、只走无线隧道没通的不算连上
        r, it = self._ready([self._dev(reality="simulated"), self._dev(platform="macOS"), self._dev(transport=None, tunnel="unavailable")])
        self.assertFalse(it["connected"]["ok"])
        # 两台都连着：只看玩家选的那台（不再要求只留一台）
        r, it = self._ready([self._dev(), self._dev(name="测试设备1")], want="测试设备1")
        self.assertTrue(it["connected"]["ok"]); self.assertEqual(r["device"], "测试设备1")
        # 没选设备：不替玩家挑一台来打勾（11-11 玩家实报：没插线却亮「已用数据线连上」）
        r, it = self._ready([self._dev()], want=None)
        self.assertFalse(it["connected"]["ok"]); self.assertIn("没说要装到哪台", it["connected"]["detail"]); self.assertEqual(r["device"], "")
        # 读不到设备列表（devicectl 失败）= 当没连
        r, it = self._ready([self._dev()], rc=1)
        self.assertFalse(it["connected"]["ok"]); self.assertIn("读不到设备列表", it["connected"]["detail"])

    def test_readiness_single_paired_network_device_counts(self):
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        r, it = self._ready([self._dev(transport="localNetwork")])
        self.assertTrue(it["connected"]["ok"]); self.assertEqual(r["device"], "测试设备2")
        self.assertEqual(it["connected"]["title"], "iPhone「测试设备2」已连上（同一 Wi-Fi）")   # 写实际类型、名字和连接方式，不写死「数据线」
        _, it = self._ready([self._dev(transport="localNetwork"), self._dev(name="另一台", transport="localNetwork")])
        self.assertTrue(it["connected"]["ok"])   # 只看选的那台，同网另一台不相干
        _, it = self._ready([self._dev(transport=None, tunnel="unavailable"), self._dev(name="线连的")])
        self.assertFalse(it["connected"]["ok"]); self.assertIn("不在线", it["connected"]["detail"])   # 选的那台拔了线：不拿插着的另一台打勾
        self.assertEqual(self._ready([self._dev()])[1]["connected"]["title"], "iPhone「测试设备2」已连上（数据线）")

    def _link(self, states, want="", polling=False, usb=(), results=None, raises=None, details=None):
        """states 是列表快照；details 独立给详情回包，缺省沿用下一张快照的同一设备；results 可给错误或异常"""
        import diag, target
        calls, seen, detail_seen = [], [0], [0]
        def devicectl(c, *a, timeout=0):
            if a[:2] == ("list", "devices"):
                if raises: raise raises
                state = states[min(seen[0], len(states) - 1)]; seen[0] += 1
                return state if isinstance(state, tuple) else (0, {"result": {"devices": state}}, "")
            calls.append(a[:3])
            result = (results or {}).get(a[1], (0, ""))
            if isinstance(result, Exception): raise result
            rc, raw = result
            if a[:3] == ("device", "info", "details"):
                if details is not None:
                    row = details[min(detail_seen[0], len(details) - 1)]
                else:
                    rows = states[min(detail_seen[0] + 1, len(states) - 1)]
                    row = next((d for d in rows if d["identifier"] == a[-1]), {})
                detail_seen[0] += 1
                return rc, {"result": row}, raw
            return rc, {}, raw
        with um.patch.object(diag, "devicectl", devicectl), um.patch.object(target, "usb_idevices", return_value=list(usb)):
            return install.device_link(self.c, want, polling=polling), calls

    def _p(self, name="甲", transport="wired", pairing="paired", tunnel="disconnected", devmode="enabled", ddi=True, ident="D1", udid="SAMPLE-UDID-00112233"):
        d = self._dev(name=name, transport=transport, pairing=pairing, tunnel=tunnel, devmode=devmode)
        d["identifier"] = ident; d["hardwareProperties"]["udid"] = udid; d["deviceProperties"]["ddiServicesAvailable"] = ddi
        return d

    def test_link_reports_why_the_list_is_unreadable(self):
        self.assertIn("超时", self._link([], raises=subprocess.TimeoutExpired("devicectl", 60), usb=["iPad"])[0]["problem"])   # 读不到优先：不说成「没插」
        self.assertIn("CoreDevice", self._link([(127, {}, "x")])[0]["problem"])
        link, _ = self._link([(1, {}, "boom")])
        self.assertIn("读不到设备列表", link["problem"]); self.assertEqual(link["trace"][0]["rc"], 1); self.assertEqual(link["trace"][0]["raw"], "boom")

    def test_link_usb_branches(self):
        self.assertIn("USB 上没看到", self._link([[]])[0]["problem"])
        link, _ = self._link([[self._p(transport=None, tunnel="unavailable")]], usb=["iPad"])
        self.assertEqual(link["stage"], "connected"); self.assertIn("还没列出", link["problem"])

    def test_link_pairs_an_untrusted_phone(self):
        link, calls = self._link([[self._p(pairing="unpaired")], [self._p()]])
        self.assertEqual(link["stage"], ""); self.assertIn(("manage", "pair", "--device"), calls)
        link, _ = self._link([[self._p(pairing="unpaired")]], results={"pair": (1, "user denied")})
        self.assertEqual(link["stage"], "trusted"); self.assertIn("信任", link["problem"]); self.assertIn("user denied", link["problem"])

    def test_link_polling_does_not_repeat_the_trust_prompt(self):
        states = [[self._p(pairing="unpaired")]]
        self.assertIn(("manage", "pair", "--device"), self._link(states, polling=True)[1])
        link, calls = self._link(states, polling=True)
        self.assertEqual(calls, []); self.assertEqual(link["stage"], "trusted")

    def test_link_rechecks_disabled_mode_from_details_not_stale_list(self):
        stale = self._p(devmode="disabled", ddi=False)
        fresh = self._p(tunnel="connected")
        other = self._p(ident="D2", transport="localNetwork")
        for polling in (False, True):
            with self.subTest(polling=polling):
                link, calls = self._link([[stale, other]], details=[fresh], polling=polling)
                self.assertEqual(link["stage"], "")
                self.assertEqual(calls, [("device", "info", "details")])
                self.assertEqual(link["device"], fresh)
                self.assertEqual(link["devices"], [fresh, other])

    def test_link_confirmed_disabled_mode_stops_before_ddi_update(self):
        link, calls = self._link([[self._p(devmode="disabled", ddi=False)]])
        self.assertEqual(link["stage"], "developerMode")
        self.assertEqual(calls, [("device", "info", "details")]); self.assertIn("开发者模式", link["problem"])

    def test_link_detail_query_failure_does_not_claim_mode_disabled(self):
        for result, rc in [((1, "device locked"), 1), (subprocess.TimeoutExpired("devicectl", 20), "timeout"), (OSError("disconnected"), "oserror")]:
            with self.subTest(result=result):
                link, calls = self._link([[self._p(devmode="disabled")]], results={"info": result})
                self.assertEqual(link["stage"], "prepare")
                self.assertIn("开发连接", link["problem"])
                self.assertEqual(link["trace"][-1]["rc"], rc)
                self.assertEqual(calls, [("device", "info", "details")])

    def test_link_details_must_identify_same_phone_and_mode(self):
        stale = self._p(devmode="disabled")
        for row in (None, [], {}, {"identifier": "D1", "deviceProperties": None}, self._p(ident="D2"), self._p(devmode=None), self._p(devmode="unknown")):
            with self.subTest(row=row):
                link, calls = self._link([[stale]], details=[row])
                self.assertEqual(link["stage"], "prepare")
                self.assertEqual(calls, [("device", "info", "details")])

    def test_link_fresh_disabled_mode_overrides_enabled_list(self):
        link, calls = self._link([[self._p(ddi=False)]], details=[self._p(devmode="disabled", ddi=False)])
        self.assertEqual(link["stage"], "developerMode")
        self.assertEqual(calls, [("device", "info", "details")])

    def test_link_rechecked_enabled_mode_can_prepare_ddi(self):
        stale = self._p(devmode="disabled", ddi=False)
        down = self._p(tunnel="connected", ddi=False)
        fresh = self._p(tunnel="connected")
        link, calls = self._link([[stale]], details=[down, fresh])
        self.assertEqual(link["stage"], "")
        self.assertEqual(link["device"], fresh)
        self.assertEqual(calls, [("device", "info", "details"), ("manage", "ddis", "update"), ("device", "info", "details")])

    def test_link_ddi_recheck_does_not_accept_unreadable_or_disabled_details(self):
        down = self._p(tunnel="connected", ddi=False)
        for row, stage in [({}, "prepare"), (self._p(devmode="disabled", ddi=False), "developerMode")]:
            with self.subTest(row=row):
                link, calls = self._link([[down]], details=[down, row])
                self.assertEqual(link["stage"], stage)
                self.assertEqual(calls, [("device", "info", "details"), ("manage", "ddis", "update"), ("device", "info", "details")])

    def test_readiness_failed_mode_query_waits_and_shows_connection_error(self):
        link, _ = self._link([[self._p(devmode="disabled")]], results={"info": (1, "device locked")})
        with um.patch.object(install, "device_link", return_value=link):
            _, items = self._ready([])
        self.assertFalse(items["developerMode"]["ok"])
        self.assertTrue(items["developerMode"]["waiting"])
        self.assertEqual(items["developerMode"]["detail"], "")
        self.assertFalse(items["deviceReady"]["ok"])
        self.assertFalse(items["deviceReady"]["waiting"])
        self.assertIn("device locked", items["deviceReady"]["detail"])

    def test_link_brings_up_an_idle_tunnel(self):
        link, calls = self._link([[self._p(ddi=False)], [self._p(tunnel="connected")]])
        self.assertEqual(link["stage"], ""); self.assertEqual(calls, [("device", "info", "details")])
        link, calls = self._link([[self._p(tunnel="connected")]], polling=True)
        self.assertEqual((link["stage"], calls), ("", []))   # 清单轮询：已经通了不折腾
        link, calls = self._link([[self._p(tunnel="connected")]])
        self.assertEqual((link["stage"], calls), ("", [("device", "info", "details")]))   # 真装机：选中的那台一律现查一次（列表里在不等于此刻连得上）
        link, _ = self._link([[self._p(transport="localNetwork", ddi=False)]], results={"info": (1, "device locked")})
        self.assertEqual(link["stage"], "prepare"); self.assertIn("不在线", link["problem"]); self.assertIn("iPhone「甲」", link["problem"])   # 走 Wi-Fi 的那台现查不通 = 不在线，说是哪台
        link, _ = self._link([[self._p(ddi=False)]], results={"info": (1, "device locked")})
        self.assertIn("开发连接", link["problem"]); self.assertIn("device locked", link["problem"])   # 插着线却建不起连接：照旧说开发连接失败

    def test_link_updates_disk_images_when_services_stay_down(self):
        down = [self._p(tunnel="connected", ddi=False)]
        link, calls = self._link([down, down, [self._p(tunnel="connected")]])
        self.assertEqual(link["stage"], ""); self.assertEqual(calls, [("device", "info", "details"), ("manage", "ddis", "update"), ("device", "info", "details")])
        link, _ = self._link([down], results={"info": (0, "still no ddi")})
        self.assertEqual(link["stage"], "prepare"); self.assertIn("开发者服务", link["problem"])

    def test_link_only_the_chosen_device(self):
        """装到哪台由玩家选、作业照办（维护者 11-11 玩家实报：续签时选的 iPhone 拔了线，同网的 iPad 被装上，完成页还写「已装到 iPhone」）：
        选的那台在线（有线或同网）就用它；配对过但不在线 → 说「iPhone「名字」不在线」；没见过 → 没找到；都不换装别的设备"""
        ipad = self._p(name="小平板", ident="D2", transport="localNetwork", tunnel="connected", udid="PAD-UDID")
        ipad["hardwareProperties"]["platform"] = "iPadOS"
        offline_phone = self._p(name="我的手机", ident="D1", transport=None, tunnel="unavailable", udid="PHONE-UDID")
        link, _ = self._link([[offline_phone, ipad]], want="PHONE-UDID")
        self.assertIsNone(link["device"]); self.assertEqual(link["stage"], "connected")
        for text in ("iPhone", "我的手机", "不在线", "Wi-Fi"): self.assertIn(text, link["problem"])
        self.assertNotIn("小平板", link["problem"])
        link, _ = self._link([[ipad]], want="旧手机")   # 没见过的设备：没找到，不装旁边唯一在线的那台
        self.assertIsNone(link["device"]); self.assertIn("没找到", link["problem"])
        self.assertIn("「旧手机」", link["problem"]); self.assertIn("Wi-Fi", link["problem"])
        link, _ = self._link([[ipad]], want="0000AAAA-0000-BBBB-0000BB")   # 没见过的设备号：上屏只写末尾 6 位（整串会被诊断脱敏成 [DEVICE_ID]，11-11 真机验收测出）
        self.assertIn("编号末尾 0000BB", link["problem"]); self.assertNotIn("AAAA", link["problem"])   # 前面的部分不上屏
        link, _ = self._link([[offline_phone, ipad]], want="PAD-UDID")   # 选的是走 Wi-Fi 的 iPad：装它
        self.assertEqual(link["device"]["identifier"], "D2")
        link, _ = self._link([[self._p(name="甲", tunnel="connected"), self._p(name="乙", ident="D2", tunnel="connected")]], want="乙")
        self.assertEqual(link["device"]["identifier"], "D2")
        offline_ipad = dict(ipad, connectionProperties={"transportType": None, "pairingState": "paired", "tunnelState": "unavailable"})
        self.assertIn("iPad「小平板」", self._link([[offline_ipad]], want="PAD-UDID")[0]["problem"])

    def test_phone_requires_a_chosen_device(self):
        """真装机（phone）不带设备号就拒：哪怕只连着一台也不自己挑（s2armctl install 不带 --device 同样被拒）"""
        import diag, target
        data = {"result": {"devices": [self._p(name="唯一一台", tunnel="connected")]}}
        self.c.r.pop("device", None)
        with um.patch.object(diag, "devicectl", lambda c, *a, timeout=0: (0, data, "")), um.patch.object(target, "usb_idevices", return_value=[]), \
                self.assertRaises(Failure) as e:
            install.phone(self.c)
        self.assertEqual(e.exception.code, "device_required")

    def test_phone_failure_writes_a_redacted_report(self):
        import diag, target
        udid = "00008140-" + "AB" * 8
        data = {"result": {"devices": [self._p(name="张三的手机", ddi=False, udid=udid)]}}
        def devicectl(c, *a, timeout=0):
            return (0, data, "") if a[:2] == ("list", "devices") else (1, {}, f"error on {udid}")
        self.c.r["device"] = udid
        with um.patch.object(diag, "devicectl", devicectl), um.patch.object(target, "usb_idevices", return_value=[]), self.assertRaises(Failure) as e:
            install.phone(self.c)
        self.assertEqual(e.exception.code, "device_not_ready"); self.assertNotIn(udid, str(e.exception))
        report = (self.c.logs / f"{self.c.task}-device.log").read_text(encoding="utf-8")
        self.assertNotIn(udid, report); self.assertNotIn("张三", report)
        for field in ("rc=1", "transport=wired", "pairing=paired", "tunnel=disconnected", "developerMode=enabled", "ddi=False", "boot="): self.assertIn(field, report)

    def test_no_pack_dir_fails_before_install(self):
        # 审计 18:00 P1-58：没有「…资源包」目录不装、不报成功（原先照装，启动器写死「资源包也拷好了」）
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        import shutil; shutil.rmtree(pack)
        with self.assertRaises(install.Failure) as e:
            self._install(gid, pushed=0, applied_before="")
        self.assertEqual(e.exception.code, "pack_missing"); self.assertIn("资源包", str(e.exception))

    def test_usb2_link_no_hint_when_nothing_to_push(self):
        # 11-11 维护者截图：只换壳更新一个资源包都不推，也报「资源包 0.0 GB 第一次全拷约 1 分钟，换 USB 3 能快约 10 倍」→ 不推就不报
        from unittest import mock as um2
        ph = install.MacPhone.__new__(install.MacPhone); ph.c = self.c; ph.udid = "U"
        with um2.patch.object(install, "usb_mbps", return_value=480):
            ph.before_push({})
        self.assertEqual([x for x in self.c.job.get("diagnostics", []) if x["code"] == "usb_slow"], [])

    def test_reinstall_nothing_changed_skips_apply(self):
        # 免费账号 7 天到期重装：资源包没变（推 0 个文件）且机上 .applied 已是本包 → 不起 App 解包
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        r, runs, seen, launches = self._install(gid, pushed=0, applied_before="cafe01")
        self.assertEqual(launches, []); self.assertEqual(r["packFiles"], 0)

    def test_usb2_link_warns_usb3_hint(self):
        # 10-26：测试设备经集线器只有 480 Mb/s → 黄字 usb_slow 提示换 USB 3；5 Gb/s 不提示；装机照常完成
        gid = "0100535012974000"
        for mbps, want in ((480, 1), (5000, 0), (0, 0)):
            self.tearDown(); self.setUp(); out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
            r, *_ = self._install(gid, pushed=1, applied_before="", mbps=mbps)
            d = [x for x in self.c.job["diagnostics"] if x["code"] == "usb_slow"]
            self.assertEqual(len(d), want, mbps); self.assertEqual(r["packFiles"], 1)
            if want:
                self.assertEqual(d[0]["severity"], "warning"); self.assertIn("USB 2.0（480 Mb/s）", d[0]["summary"])

    def test_usb_mbps_matches_serial(self):
        # system_profiler 的序列号 = 去掉横杠的 UDID；别的设备、没插的不算
        d = tempfile.mkdtemp(); fake = Path(d) / "system_profiler"
        data = {"SPUSBHostDataType": [{"_name": "hub", "_items": [
            {"_name": "iPhone", "USBDeviceKeySerialNumber": "000000000000000000000002", "USBDeviceKeyLinkSpeed": "480 Mb/s"},
            {"_name": "iPhone", "USBDeviceKeySerialNumber": "000000000000000000000001", "USBDeviceKeyLinkSpeed": "5 Gb/s"}]}]}
        (Path(d) / "o.json").write_text(json.dumps(data)); fake.write_text(f'#!/bin/sh\ncat "{d}/o.json"\n'); fake.chmod(0o755)
        env = dict(os.environ, PATH=d + ":" + os.environ["PATH"])
        self.assertEqual(install.usb_mbps("00000000-0000000000000002", env), 480)
        self.assertEqual(install.usb_mbps("00000000-0000000000000001", env), 5000)
        self.assertEqual(install.usb_mbps("00000000-0000000000000004", env), 0)
        self.assertEqual(install.usb_mbps("", env), 0)

    def test_locked_phone_maps_device_locked(self):
        # 10-26 测试设备2 锁屏：ensure_profile.sh 带出 xcodebuild 的目的设备报错，归成「iPhone 锁屏了」（原先是含糊的「签名没成」）
        line = "{ platform:iOS, arch:arm64, id:00000000-0000000000000002, name:测试设备2, error:The device needs to be unlocked to continue Unlock the device"
        self.assertEqual(install.classify(line), "device_locked")

    def test_profile_failure_maps_free_limit(self):
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        import ipa as packer
        def run(args, log=None, env=None, cwd=None, on_line=None):
            Path(log).parent.mkdir(parents=True, exist_ok=True); Path(log).write_text("error: Your maximum App ID limit has been reached.\n")
            raise Failure("S2Arm 工具退出，当前阶段未完成。", code="tool_exit")
        def fake_assemble(c, g, others=(), failed=(), root=None, dest=None):
            ipa = out / "t.ipa"; self._real_ipa(ipa)
            return ipa, [gid], "SID1"
        with um.patch.object(install, "xcode_teams", return_value=[dict(id="TEAM1", name="我", free=True)]), \
             um.patch.object(install, "phone", return_value=dict(id="C891", name="测试设备2")), um.patch.object(install, "udid_of", return_value=""), \
             um.patch.object(packer, "assemble", side_effect=fake_assemble), \
             um.patch.object(self.c, "run", run):
            with self.assertRaises(Failure) as e: install.install(self.c)
        self.assertEqual(e.exception.code, "free_appid_limit")   # 签名前注册包名被拒 = 包名额度，不是设备上装满
        self.assertIn("10 个包名", str(e.exception))
        self.assertNotIn("删掉", str(e.exception))


class PullSeenTests(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def _pull(self, device_text):
        got = {}
        def devicectl(c, *a, timeout=0):
            got["src"] = a[a.index("--source") + 1]
            if device_text is None: return 1, {}, "no such file"
            Path(a[a.index("--destination") + 1]).write_text(device_text); return 0, {}, ""
        import diag
        with um.patch.object(diag, "devicectl", devicectl):
            r = install.pull_seen(self.c, "C891", "s2arm.z.0100c2500fc20000", "0100c2500fc20000", "00000000-0000000000000002")
        return r, got

    def test_append_overwrite_and_fork(self):
        seen = self.c.library / "games/0100c2500fc20000/seen"
        r, got = self._pull(None)
        self.assertEqual((r, got["src"], seen.exists()), (False, "Documents/wire/0100C2500FC20000/pso_user.tsv", False))   # 机上没有不算错
        self.assertTrue(self._pull("S\ta\n")[0]); self.assertEqual((seen / "00000000-0000000000000002.tsv").read_text(), "S\ta\n")
        self.assertFalse(self._pull("S\ta\n")[0])                                       # 没变
        self.assertTrue(self._pull("S\ta\nS\tb\n")[0])                                  # 续写 → 覆盖
        self.assertEqual((seen / "00000000-0000000000000002.tsv").read_text(), "S\ta\nS\tb\n")
        self.assertTrue(self._pull("S\tc\n")[0])                                        # 换包后重新记 → 另存，旧的保留
        self.assertEqual(sorted(p.read_text() for p in seen.glob("*.tsv")), ["S\ta\nS\tb\n", "S\tc\n"])


class SaveBackupTests(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def _run(self, files, fail=None, list_rc=0, installed=False, apps_rc=0):
        got = []
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "info", "apps"):
                if apps_rc:
                    return apps_rc, {}, "devicectl 等了 60 秒没有返回，已停止等待"
                return 0, {"result": {"apps": [{"bundleIdentifier": "s2arm.z.0100c2500fc20000"}] if installed else []}}, ""
            if a[:3] == ("device", "info", "files") and list_rc:
                return list_rc, {}, "The operation couldn’t be completed"
            if a[:3] == ("device", "info", "files"):
                return 0, {"result": {"files": [dict(relativePath=r, resources=dict(isDirectory=d)) for r, d in files]}}, ""
            src = a[a.index("--source") + 1]; got.append(src)
            if fail and src.endswith(fail): return 1, {}, "Device locked"
            Path(a[a.index("--destination") + 1]).write_text("内容:" + src); return 0, {}, ""
        import diag
        with um.patch.object(diag, "devicectl", devicectl):
            return install.backup_saves(self.c, "C891", "s2arm.z.0100c2500fc20000", "0100C2500FC20000"), got

    def test_backs_up_every_file(self):
        d, got = self._run([("0000000000000001", True), ("0000000000000001/0", True), ("0000000000000001/0/save.dat", False),
                            ("0000000000000001/1/save.dat", False), ("0000000000000001/.lock", False)])
        self.assertEqual(got, [install.SAVE_DIR + "/0000000000000001/0/save.dat", install.SAVE_DIR + "/0000000000000001/1/save.dat"])   # 目录与 .lock 不拷
        self.assertEqual((d / "0000000000000001/0/save.dat").read_text(), "内容:" + got[0])
        self.assertEqual(d.parent, self.c.library / "games/0100C2500FC20000/save_backup")

    def test_nothing_on_device(self):
        self.assertEqual(self._run([])[0], None)                       # 第一次装：机上没有存档，不备份不报错

    def _accept(self, on=True):   # 玩家在确认页点了「仍然继续」：同一请求带 acceptNoBackup 重发
        if on: self.c.r["acceptNoBackup"] = True
        else: self.c.r.pop("acceptNoBackup", None)

    def _decisions(self):
        f = self.c.logs / f"{self.c.task}-decisions.log"
        return f.read_text(encoding="utf-8") if f.is_file() else ""

    def test_list_failure(self):
        self.assertEqual(self._run([], list_rc=1, installed=False)[0], None)   # App 不在机上：第一次装，照装
        with self.assertRaises(Failure) as e:
            self._run([], list_rc=1, installed=True)                           # App 在却列不出：停在确认（装机原则 11-11：认得出的风险让用户确认）
        self.assertEqual(e.exception.code, "save_backup_failed")
        self.assertIn("可能丢档", str(e.exception))
        self._accept()
        self.assertEqual(self._run([], list_rc=1, installed=True)[0], None)    # 确认后带 acceptNoBackup：照装、不备份
        self.assertIn("玩家已确认继续", self._decisions())

    def test_unknown_install_state_asks_instead_of_skipping_backup(self):
        # #333：列存档超时（124）后连「装没装过」都问不出：不能悄悄当成第一次装（跳过备份直接覆盖），停在确认；玩家确认后才照装
        with self.assertRaises(Failure) as e:
            self._run([], list_rc=124, apps_rc=124)
        self.assertEqual(e.exception.code, "save_backup_failed")
        self.assertIn("确认不了 iPhone 上有没有装过这款", e.exception.internal)
        self._accept()
        self.assertEqual(self._run([], list_rc=124, apps_rc=124)[0], None)

    def _tree(self, tree, docs, locked=()):
        # 假设备文件系统（11-07 满屏线 Duo 实测）：列不存在的目录 devicectl 也报「failed to get a list of files」——和锁屏同一个错，只能靠父目录分辨
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "info", "apps"):
                return 0, {"result": {"apps": [{"bundleIdentifier": "s2arm.z.games"}]}}, ""   # App 在机上
            if a[:3] == ("device", "info", "files"):
                sub = a[a.index("--subdirectory") + 1]
                if sub in locked or not any(t == sub or t.startswith(sub + "/") for t in tree):
                    return 1, {}, "StreamingAction: The system failed to get a list of files on the remote device."
                return 0, {"result": {"files": [dict(relativePath=t[len(sub) + 1:], resources=dict(isDirectory=True)) for t in tree if t.startswith(sub + "/")]}}, ""
            raise AssertionError(a)
        import diag
        with um.patch.object(diag, "devicectl", devicectl):
            return install.backup_saves(self.c, "C891", "s2arm.z.games", "0100C2500FC20000", docs=docs)

    def test_missing_save_dir_under_listable_parent_installs(self):
        # 容器第一次装半途失败 / 从没进过游戏：机上 Documents/games 是空目录，存档目录不在 → 没有存档，照装（原先每次都拒装，玩家永久卡死）
        g = "Documents/games/0100C2500FC20000"
        self.assertIsNone(self._tree({"Documents", "Documents/games"}, g))
        self.assertIsNone(self._tree({"Documents", "Documents/games", g, g + "/资源包"}, g))       # 本款目录在、S2A 不在
        self.assertIsNone(self._tree({"Documents", "Documents/logs"}, "Documents"))                # 单款：Documents 在、S2A 不在

    def test_unlistable_parent_or_existing_save_dir_asks(self):
        g = "Documents/games/0100C2500FC20000"
        with self.assertRaises(Failure) as e:   # Documents 也列不出（锁屏 / 隧道断）：分不清有没有存档，停在确认
            self._tree({"Documents", "Documents/games"}, g, locked={"Documents", "Documents/games", g, g + "/" + install.SAVE_REL})
        self.assertEqual(e.exception.code, "save_backup_failed")
        with self.assertRaises(Failure) as e:   # 父目录里看得到存档目录、它本身却列不出：有档读不到，停在确认
            self._tree({"Documents", g + "/" + install.SAVE_REL + "/0000000000000001"}, g, locked={g + "/" + install.SAVE_REL})
        self.assertEqual(e.exception.code, "save_backup_failed")
        self._accept()
        self.assertIsNone(self._tree({"Documents", g + "/" + install.SAVE_REL + "/0000000000000001"}, g, locked={g + "/" + install.SAVE_REL}))

    def test_copy_failure_asks_then_continues(self):
        with self.assertRaises(Failure) as e:
            self._run([("0000000000000001/0/save.dat", False)], fail="save.dat")
        self.assertEqual(e.exception.code, "save_backup_failed")
        self._accept()
        self.assertIsNone(self._run([("0000000000000001/0/save.dat", False)], fail="save.dat")[0])




class AssembleTests(unittest.TestCase):
    """现组容器（assemble）/ put_game / 手机侧 S2Arm.ipa 与上一版（commit_phone_ipa、restore_previous）/ remove_from_phone 的细粒度测试（游戏库结构 v3）"""
    setUp = _jobs_setup_no_phone_games; tearDown = tj.JobsTests.tearDown
    A, B, C = "0100000000010000", "0100000000020000", "0100000000030000"
    COMPAT = dict(hostAbi=1, dmshChain="aaaa")   # 替身：本版引擎（新宿主）的兼容判据

    def _library(self, *games):
        """游戏库清单：(游戏号, 名字)…"""
        self.c.catalog = lambda: {"games": [{"id": g, "name": n} for g, n in games]}

    def _run(self, runs):
        """ship_ext container / app_bundle write_ipa 的替身：按 --game 容器件所在游戏文件夹的 game.json 认出各款，出真 zip ipa（带 s2a_catalogue.json）"""
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]; runs.append(args)
            if any(a.endswith("ship_ext.py") for a in args) and "container" in args:
                o = Path(args[args.index("--out") + 1]); o.mkdir(parents=True, exist_ok=True)
                gs = [json.loads((Path(args[i + 1]).parents[2] / "game.json").read_text())["id"] for i, x in enumerate(args) if x == "--game"]
                (o / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "shell_id": self.sid, "games": [{"title_id": g} for g in gs]}))
            if "write_ipa" in args:
                cat = json.loads((Path(args[-2]) / "s2a_catalogue.json").read_text())
                self._ipa(Path(args[-1]), cat["shell_id"], [g["title_id"] for g in cat["games"]])
        return run

    @staticmethod
    def _ipa(path, sid, games):
        """手机侧装机产物（真 zip，ipa_games 读 Payload/*.app/s2a_catalogue.json）"""
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "io.s2arm.games", "CFBundleExecutable": "S2Arm"}))
            z.writestr("Payload/S2Arm.app/s2a_catalogue.json", json.dumps({"schema": 1, "shell_id": sid, "games": [{"title_id": g} for g in games]}))
        return path

    def _assemble(self, gid, others=(), failed=(), sid="SID1", runs=None):
        import ipa as packer, host_update
        self.sid = sid
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        runs = [] if runs is None else runs
        with um.patch.object(packer, "current_shell_id", return_value=sid), um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", self._run(runs)):
            return packer.assemble(self.c, gid, others, failed=failed)

    @staticmethod
    def _games_arg(runs):
        cmd = next(a for a in runs if any(x.endswith("ship_ext.py") for x in a))
        return [json.loads((Path(cmd[i + 1]).parents[2] / "game.json").read_text())["id"] for i, x in enumerate(cmd) if x == "--game"], cmd

    def test_assemble_this_game_only(self):
        """第一次装：只组这一款，不带 --base；→ (ipa, [这款], 本壳号)"""
        self._library((self.A, "甲")); ios_fixture(self.c, self.A)
        runs = []
        ipa, games, sid = self._assemble(self.A, runs=runs)
        got, cmd = self._games_arg(runs)
        self.assertNotIn("--base", cmd)
        self.assertEqual((got, games, sid), ([self.A], [self.A], "SID1"))
        self.assertEqual(install_ipa_games(ipa), ([self.A], "SID1"))

    def test_assemble_passes_library_banner(self):
        """横图是游戏库的元数据（导入时抓好放在这款文件夹）：组装命令带 --banner 游戏号=那份；没有横图的款不带"""
        import layout
        self._library((self.A, "甲"), (self.B, "乙"))
        ios_fixture(self.c, self.A); ios_fixture(self.c, self.B)
        banner = layout.path(self.c, self.A, "banner.jpg"); banner.write_bytes(b"BANNER")
        runs = []
        self._assemble(self.A, others=(self.B,), runs=runs)
        _, cmd = self._games_arg(runs)
        self.assertEqual([cmd[i + 1] for i, x in enumerate(cmd) if x == "--banner"], [f"{self.A}={banner}"])

    def test_assemble_carries_phone_games_of_same_shell(self):
        """这台手机已有的款（同壳出的）现组时一起带上，容器件取各自的 image/ios/kit"""
        self._library((self.A, "甲"), (self.B, "乙"))
        ios_fixture(self.c, self.A); kb, _ = ios_fixture(self.c, self.B)
        runs = []
        ipa, games, sid = self._assemble(self.A, [self.B], runs=runs)
        got, cmd = self._games_arg(runs)
        self.assertEqual((got, games), ([self.A, self.B], [self.A, self.B]))
        self.assertIn(str(kb.resolve()), cmd)

    def test_assemble_other_shell_compatible_swaps_host_only(self):
        """乙是旧壳 SID1 出的、兼容判据与新宿主一致 → 原样带进新壳 SID2（只换宿主，不要求重出）；
        这台手机对 SID2 装回过上一版（failedShells 含 SID2）→ 不带、报 container_stale 点名；failedShells 里是别的壳不影响"""
        self._library((self.A, "甲"), (self.B, "乙款"))
        ios_fixture(self.c, self.A, shell="SID2"); kb, _ = ios_fixture(self.c, self.B, shell="SID1", compat=self.COMPAT)
        runs = []
        _, games, sid = self._assemble(self.A, [self.B], sid="SID2", runs=runs)
        self.assertEqual((games, sid), ([self.A, self.B], "SID2"))
        self.assertIn(str(kb.resolve()), self._games_arg(runs)[1])
        _, games, _ = self._assemble(self.A, [self.B], failed=["SID1"], sid="SID2")
        self.assertEqual(games, [self.A, self.B])
        with self.assertRaises(Failure) as e:
            self._assemble(self.A, [self.B], failed=["SID2"], sid="SID2")
        self.assertEqual(e.exception.code, "container_stale"); self.assertIn("乙款", str(e.exception))

    def test_assemble_other_shell_incompatible_is_stale(self):
        """乙是旧壳出的、新宿主认不得（直连链号不同 / 没记判据按旧版口径）→ container_stale 点名乙，不装半套"""
        self._library((self.A, "甲"), (self.B, "乙款"))
        ios_fixture(self.c, self.A, shell="SID2")
        for compat in (dict(hostAbi=1, dmshChain="bbbb"), dict(hostAbi=2, dmshChain="aaaa"), None):
            ios_fixture(self.c, self.B, shell="SID1", compat=compat)
            if compat is None:   # 没记判据的旧款：game.json 的 ios 里没有 hostAbi / dmshChain
                layout.update_info(self.c, self.B, ios=dict(shellId="SID1", pack="cafe01"))
            with self.assertRaises(Failure) as e:
                self._assemble(self.A, [self.B], sid="SID2")
            self.assertEqual(e.exception.code, "container_stale", compat); self.assertIn("乙款", str(e.exception))

    def test_assemble_stale_others_ask_then_leave_out_on_accept(self):
        """v0.3.1 装机原则：别的款（乙）新宿主认不得 → 没确认时停下报 container_stale、点名乙、说清确认后会怎样；
        玩家确认（acceptStale）→ 这次不带乙照装甲，黄字说明乙的存档和资源还在、重新出包再装就回来"""
        self._library((self.A, "甲"), (self.B, "乙款"))
        ios_fixture(self.c, self.A, shell="SID2"); ios_fixture(self.c, self.B, shell="SID1", compat=dict(hostAbi=1, dmshChain="bbbb"))
        with self.assertRaises(Failure) as e:
            self._assemble(self.A, [self.B], sid="SID2")
        self.assertEqual(e.exception.code, "container_stale"); self.assertIn("乙款", str(e.exception)); self.assertIn("确认继续", str(e.exception))
        self.assertEqual(e.exception.internal, self.B)
        self.c.r["acceptStale"] = True
        notes, runs = [], []
        with um.patch.object(self.c, "diagnostic", lambda m, **k: notes.append((m, k.get("severity")))):
            _, games, _ = self._assemble(self.A, [self.B], sid="SID2", runs=runs)
        self.assertEqual(games, [self.A]); self.assertEqual(self._games_arg(runs)[0], [self.A])
        self.assertEqual(len(notes), 1); self.assertIn("乙款", notes[0][0]); self.assertEqual(notes[0][1], "warning")

    def test_assemble_skips_games_deleted_from_library(self):
        """#194：手机上的某款已从游戏库删除：不点名、不挡，新容器不带它，黄字说明"""
        self._library((self.A, "甲")); ios_fixture(self.c, self.A)
        notes, runs = [], []
        with um.patch.object(self.c, "diagnostic", lambda m, **k: notes.append((m, k.get("severity")))):
            _, games, _ = self._assemble(self.A, [self.B], runs=runs)
        self.assertEqual(games, [self.A]); self.assertEqual(self._games_arg(runs)[0], [self.A])
        self.assertEqual(len(notes), 1); self.assertIn(self.B, notes[0][0]); self.assertEqual(notes[0][1], "warning")

    def test_assemble_own_game_no_kit(self):
        """本款没有容器件 / 容器件不是本壳出的且不兼容 → container_stale"""
        self._library((self.A, "甲"))
        with self.assertRaises(Failure) as e: self._assemble(self.A)
        self.assertEqual(e.exception.code, "container_stale")
        ios_fixture(self.c, self.A, shell="SID1", compat=dict(hostAbi=1, dmshChain="bbbb"))
        with self.assertRaises(Failure) as e: self._assemble(self.A, sid="SID2")
        self.assertEqual(e.exception.code, "container_stale")

    def _phone(self, key="dev1"):
        pushed, signed = [], []
        ph = um.Mock()
        ph.key = key; ph.bid = install.container_bundle_id("TEAM1"); ph.info = dict(device="d", team="t", free=True)
        ph.install.side_effect = lambda ipa, games, steps=True: signed.append((list(games), install_ipa_games(ipa)))
        ph.push.side_effect = lambda g, pack: (pushed.append(g), (1, 0))[1]
        ph.before_push.return_value = None
        return ph, pushed, signed

    def test_put_game_pushes_this_game_and_changed_packs_only(self):
        """put_game：甲（这款）照推，即使资源包号和手机上记的一样；乙资源包号没变不推；丙在游戏库重出过（号变了）要推。
        装上后设备记录记下各款资源包号、壳号、包名，装机产物放默认位置根 S2Arm.ipa"""
        A, B, C = self.A, self.B, self.C
        self._library((A, "甲"), (B, "乙"), (C, "丙"))
        ios_fixture(self.c, A, pack="pa"); ios_fixture(self.c, B, pack="pb"); ios_fixture(self.c, C, pack="pc-new")
        layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="pb"), C: dict(pack="pc-old")}, shellId="SID1"))
        ph, pushed, signed = self._phone()
        import ipa as packer, host_update
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", self._run([])):
            r = install.put_game(self.c, A, ph)
        self.assertEqual(pushed, [A, C])
        self.assertEqual(signed, [([A, B, C], ([A, B, C], "SID1"))])
        rec = layout.load_device(self.c, "dev1")
        self.assertEqual(rec["games"], {A: dict(pack="pa"), B: dict(pack="pb"), C: dict(pack="pc-new")})
        self.assertEqual((rec["shellId"], rec["bundleId"]), ("SID1", "io.s2arm.games.team1"))
        self.assertEqual(install_ipa_games(layout.phone_ipa(self.c)), ([A, B, C], "SID1"))
        self.assertEqual((r["outputPath"], r["games"], r["packFiles"]), (str(layout.phone_ipa(self.c)), [A, B, C], 2))

    def _update(self, sid="SID2", **req):
        """「更新 iPhone 上的 S2Arm」夹具：甲兼容新宿主（只换壳）、乙新宿主认不得（要重新出包）；手机记录是旧壳 SID1、两款资源包都没变"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙款"))
        ios_fixture(self.c, A, shell="SID1", pack="pa", compat=self.COMPAT); ios_fixture(self.c, B, shell="SID1", pack="pb", compat=dict(hostAbi=2, dmshChain="aaaa"))
        layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="pb")}, shellId="SID1"))
        ph, pushed, signed = self._phone()
        import ipa as packer, host_update
        self.sid = sid
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        self.c.r = dict(self.c.r, **req)
        for p in (um.patch.object(packer, "current_shell_id", return_value=sid), um.patch.object(packer, "container_shell", return_value=shell),
                  um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", self._run([])),
                  um.patch.object(install, "phone_for", lambda c: ph)):
            p.start(); self.addCleanup(p.stop)
        return ph, pushed, signed

    def test_update_phone_lists_games_needing_repack_and_stops(self):
        """新壳认不得乙：没确认就停下报 container_stale 点名乙，不签不装、设备记录不动"""
        _, pushed, signed = self._update()
        with self.assertRaises(Failure) as e:
            install.update_phone(self.c)
        self.assertEqual((e.exception.code, signed, pushed), ("container_stale", [], []))
        self.assertIn("乙款", str(e.exception)); self.assertNotIn("甲", str(e.exception))
        self.assertEqual(layout.load_device(self.c, "dev1")["shellId"], "SID1")

    def test_update_phone_accepted_swaps_shell_without_pushing(self):
        """确认后：新壳 SID2 只带甲（原样复用旧程序模块），资源包号没变一个都不推；记录换成 SID2、只剩甲；结果说明跳过了乙"""
        A, B = self.A, self.B
        _, pushed, signed = self._update(acceptStale=True)
        r = install.update_phone(self.c)
        self.assertEqual((signed, pushed), ([([A], ([A], "SID2"))], []))
        self.assertEqual((r["updated"], r["fromShell"], r["toShell"], r["skipped"]), (True, "SID1", "SID2", [B]))
        rec = layout.load_device(self.c, "dev1")
        self.assertEqual((rec["shellId"], rec["games"]), ("SID2", {A: dict(pack="pa")}))

    def test_update_phone_asks_then_drops_games_from_another_computer(self):
        """手机上还有一款只在别的电脑装过（不在本库、不在本机记录）：没确认 → 报 container_would_drop 点名它，不签不装；
        带 acceptDropped → 照常只换壳（甲），外来那款不带（v0.3.0 只换壳验收：原先这条路没有确认入口，永远过不去）"""
        A = self.A
        X = "0100FFFF00000000"
        _, pushed, signed = self._update(acceptStale=True)
        with um.patch.object(install, "phone_games", lambda c, ph: {A, X}), \
             um.patch.object(install, "phone_game_name", lambda c, ph, g, names: "外来款"):
            with self.assertRaises(Failure) as e:
                install.update_phone(self.c)
            self.assertEqual((e.exception.code, signed, pushed), ("container_would_drop", [], []))
            self.assertIn("外来款", str(e.exception))
            self.c.r["acceptDropped"] = True
            r = install.update_phone(self.c)
        self.assertTrue(r["updated"])
        self.assertEqual((signed, pushed), ([([A], ([A], "SID2"))], []))

    def test_update_phone_same_shell_does_nothing(self):
        _, pushed, signed = self._update(sid="SID1")
        r = install.update_phone(self.c)
        self.assertEqual((r["updated"], signed, pushed), (False, [], []))

    def test_phone_updates_from_device_records(self):
        """游戏库页检测：只读设备记录——壳旧了列出各款和要重新出包的乙；壳是本版 → 空"""
        A, B = self.A, self.B
        self._update()
        got = install.phone_updates(self.c)
        self.assertEqual([(u["device"], u["fromShell"], u["toShell"], [g["gameId"] for g in u["games"]], [g["gameId"] for g in u["stale"]]) for u in got],
                         [("dev1", "SID1", "SID2", [A, B], [B])])
        import ipa as packer
        with um.patch.object(packer, "current_shell_id", return_value="SID1"):
            self.assertEqual(install.phone_updates(self.c), [])

    def test_install_mode_defaults_and_persists(self):
        """装到 iPhone 的方式：没设过 = device；不认识的拒收；设成 device / export 写进 install.json；导出作业在 = exportAvailable"""
        self.assertEqual(install.install_mode_job(self.c)["mode"], "device")
        self.c.r = dict(self.c.r, mode="cloud")
        with self.assertRaises(Failure): install.install_mode_job(self.c)
        self.c.r = dict(self.c.r, mode="device")
        self.assertEqual(install.install_mode_job(self.c), dict(mode="device", exportAvailable=True, signMode="appleId"))
        self.assertEqual(json.loads((self.c.private / "install.json").read_text()), {"mode": "device"})
        self.c.r = dict(self.c.r, mode="export")
        self.assertEqual(install.install_mode_job(self.c)["mode"], "export")
        self.c.r = {k: v for k, v in self.c.r.items() if k != "mode"}
        self.assertEqual(install.install_mode(self.c), "export")
        with um.patch.object(install, "export_phone", None):   # 导出作业不在（旧版）：置灰、拒收 export
            self.c.r = dict(self.c.r, mode="export")
            with self.assertRaises(Failure): install.install_mode_job(self.c)
            self.assertFalse(install.export_available(self.c))
    def test_other_signer_install_error_is_named(self):
        """玩家先自签装过同包名的 S2Arm：系统安装服务拒绝覆盖的两种原文都认成 app_other_signer（Mac devicectl / Windows 同一句），不落到笼统的装机失败"""
        import impactor
        for raw in ("ERROR: MismatchedApplicationIdentifierEntitlement",
                    "Upgrade's application-identifier entitlement string (AB12CD34EF.io.s2arm.games.team1) does not match installed application's application-identifier string (ZZ99YY88XX.io.s2arm.games.team1); rejecting upgrade."):
            with self.subTest(raw=raw[:40]):
                self.assertEqual((install.classify(raw, default="device_install_failed"), impactor.explain(raw)), ("app_other_signer", "app_other_signer"))

    def _mac_phone(self, taken):
        """MacPhone 替身：sign_and_install 对 taken 里的包名报 app_id_taken（Apple 9401 原文分类出的码），其余记下装上的包名"""
        ph = object.__new__(install.MacPhone)
        ph.c, ph.team, ph.dev, ph.udid = self.c, dict(id="TEAM1", name="t", free=True), dict(id="D1"), "U1"
        ph.bid = install.container_bundle_id("TEAM1", self.c)
        installed = []
        def sign(c, ipa, team, dev, udid, bid, games, steps=True):
            if bid in taken: raise Failure("An App ID with Identifier '%s' is not available." % bid, code="app_id_taken")
            installed.append(bid)
        p = um.patch.object(install, "sign_and_install", sign); p.start(); self.addCleanup(p.stop)
        return ph, installed

    def test_taken_bundle_id_switches_once_and_is_remembered(self):
        """包名被别处占用（玩家自签时注册过）：自动换 <包名>.s2 装好、记下、黄字说明；之后算包名直接是换过的"""
        ph, installed = self._mac_phone({"io.s2arm.games.team1"})
        ph.install("x.ipa", ["0100A"])
        self.assertEqual((installed, ph.bid), (["io.s2arm.games.team1.s2"], "io.s2arm.games.team1.s2"))
        self.assertEqual(install.container_bundle_id("TEAM1", self.c), "io.s2arm.games.team1.s2")
        self.assertEqual(install.container_bundle_id("TEAM1"), "io.s2arm.games.team1")   # 不给 c（开发用 / 旧调用）照旧
        self.assertEqual([d["code"] for d in self.c.job["diagnostics"] if d["code"] == "bundle_id_switched"], ["bundle_id_switched"])

    def test_alternate_also_taken_reports_app_id_taken(self):
        ph, installed = self._mac_phone({"io.s2arm.games.team1", "io.s2arm.games.team1.s2"})
        with self.assertRaises(Failure) as e: ph.install("x.ipa", ["0100A"])
        self.assertEqual((e.exception.code, installed), ("app_id_taken", []))
        self.assertEqual(install.container_bundle_id("TEAM1", self.c), "io.s2arm.games.team1")   # 没装成不记

    def test_devcert_does_not_switch(self):
        """证书模式的包名由描述文件定，换不了：照报 app_id_taken"""
        ph, installed = self._mac_phone({"io.s2arm.games.team1"})
        with um.patch.object(install.devcert, "active", lambda c: True), self.assertRaises(Failure) as e:
            ph.install("x.ipa", ["0100A"])
        self.assertEqual((e.exception.code, installed), ("app_id_taken", []))

    def test_stamp_container_digest(self):
        """#845 S2AContainerDigest：内容相同 → 摘要相同；只差 _CodeSignature/ 或 Info.plist 里摘要键本身 → 相同；改一个文件 / Info.plist 别的键 → 不同；
        写进 Info.plist（保留原格式）、打成 ipa 后 ipa_digest 读回同一个值"""
        import ipa as packer
        def app(root, extra=b"", sig=b"s1", key=None, ver="1"):
            a = Path(root) / "S2Arm.app"; (a / "Games/X").mkdir(parents=True); (a / "_CodeSignature").mkdir()
            (a / "Games/X/kit.bin").write_bytes(b"kit" + extra); (a / "_CodeSignature/CodeResources").write_bytes(sig)
            info = {"CFBundleIdentifier": "io.s2arm.games", "CFBundleVersion": ver}
            if key: info[packer.CONTAINER_DIGEST_KEY] = key
            (a / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY)); return a
        with tempfile.TemporaryDirectory() as t:
            d = [packer.stamp_container(app(Path(t) / n, **kw)) for n, kw in (("a", {}), ("b", dict(sig=b"other", key="old")), ("c", dict(extra=b"!")), ("d", dict(ver="2")))]
            self.assertEqual(len(d[0]), 24)
            self.assertEqual(d[0], d[1], "只差签名与摘要键本身：相同")
            self.assertNotEqual(d[0], d[2], "改了一个文件：不同"); self.assertNotEqual(d[0], d[3], "Info.plist 别的键变了：不同")
            raw = (Path(t) / "a/S2Arm.app/Info.plist").read_bytes(); self.assertTrue(raw.startswith(b"bplist"), "保留二进制格式")
            self.assertEqual(plistlib.loads(raw)[packer.CONTAINER_DIGEST_KEY], d[0])
            ipa = Path(t) / "x.ipa"
            with zipfile.ZipFile(ipa, "w") as z: z.writestr("Payload/S2Arm.app/Info.plist", raw)
            self.assertEqual(packer.ipa_digest(ipa), d[0])

    def test_put_game_skips_signing_when_phone_has_same_app(self):
        """#845：手机上的 S2Arm 的 S2AContainerDigest = 这次组出的、两天前签过（免费账号，3 天内）→ 不调 ph.install，资源照推（这款照推、变了的推），
        签名时间不刷新；同样条件但签名是 4 天前 → 照常装；手机上的摘要不同（别的电脑装过）→ 照常装"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙"))
        ios_fixture(self.c, A, pack="pa"); ios_fixture(self.c, B, pack="pb")
        import ipa as packer, host_update
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        base = self._run([])
        def run(args, log=None, env=None, cwd=None, on_line=None):   # 替身组的容器另带一份 Info.plist（真壳都有），stamp_container 才写摘要
            args = [str(a) for a in args]
            if any(a.endswith("ship_ext.py") for a in args) and "container" in args:
                o = Path(args[args.index("--out") + 1]); o.mkdir(parents=True, exist_ok=True)
                (o / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "x"}))
            r = base(args, log, env, cwd, on_line)
            if "write_ipa" in args:   # 真 write_ipa 整目录打包：把 App 里 stamp_container 写过摘要的 Info.plist 换进替身 zip
                z0 = Path(args[-1]); items = {n: zipfile.ZipFile(z0).read(n) for n in zipfile.ZipFile(z0).namelist()}
                items["Payload/S2Arm.app/Info.plist"] = (Path(args[-2]) / "Info.plist").read_bytes()
                with zipfile.ZipFile(z0, "w") as z:
                    for n, b in items.items(): z.writestr(n, b)
            return r
        for age, phone_same, want_install in ((2 * 86400, True, False), (4 * 86400, True, True), (2 * 86400, False, True)):
            at = time.time() - age
            layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="pb")}, shellId="SID1", bundleId="io.s2arm.games.team1",
                                                     signed=dict(at=at, free=True, device="d")))
            ph, pushed, signed = self._phone(); ph.udid = "UDID1"
            seen = {}
            class Cl:
                def call(self_, *a):
                    seen["args"] = a; return 0, (seen["want"] if phone_same else "aaaaaaaaaaaaaaaaaaaaaaaa") + "\n"
            orig_digest = packer.ipa_digest
            def digest(ipa):
                d = orig_digest(ipa); seen["want"] = d; return d
            with um.patch.object(packer, "current_shell_id", return_value="SID1"), um.patch.object(packer, "container_shell", return_value=shell), \
                 um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", run), \
                 um.patch.object(packer, "ipa_digest", digest), um.patch.object(install, "devpush_client", lambda *a: Cl()):
                install.put_game(self.c, A, ph)
            self.assertEqual(len(seen["want"]), 24, "组出的容器带 24 位摘要")
            self.assertEqual(seen.get("args"), ("app-attr", "S2AContainerDigest") if age < 3 * 86400 else None)   # 签名过了 3 天：不必问手机，直接照常装
            self.assertEqual(bool(signed), want_install, (age, phone_same))
            self.assertEqual(pushed, [A])   # 乙资源包号没变：两种情况都不推
            rec = layout.load_device(self.c, "dev1")
            if want_install: self.assertGreater(rec["signed"]["at"], at)
            else: self.assertEqual(rec["signed"]["at"], at)   # 没重签：到期时间照旧

    def test_put_game_pushes_all_when_bundle_changed(self):
        """装上的包名和记录里的不同（换过包名 / 签名方式）= 手机上是另一个 App：资源包号没变的款也推"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙"))
        ios_fixture(self.c, A, pack="pa"); ios_fixture(self.c, B, pack="pb")
        layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="pb")}, shellId="SID1", bundleId="io.s2arm.games.team1"))
        ph, pushed, signed = self._phone()
        ph.bid = "io.s2arm.games.team1.s2"
        import ipa as packer, host_update
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", self._run([])):
            install.put_game(self.c, A, ph)
        self.assertEqual(sorted(pushed), [A, B])
        self.assertEqual(layout.load_device(self.c, "dev1")["bundleId"], "io.s2arm.games.team1.s2")

    def _app_gone(self, ph):
        """玩家在手机上删了整个 S2Arm：进不了容器、平台确认这个包名没装（走真的 install.phone_games，不用夹具里的替身）"""
        class Cl:
            def call(self, op, rel): return 1, "取不到 x 的容器（App 没装或不是开发签名）：device socket io failed"
        ph.udid = "U1"; ph.app_missing.return_value = True
        for p in (um.patch.object(install, "phone_games", _phone_games), um.patch.object(install, "devpush_client", lambda c, udid, bid, work: Cl())):
            p.start(); self.addCleanup(p.stop)

    def test_put_game_after_app_deleted_on_phone_installs_this_game_only(self):
        """玩家在手机上删了整个 S2Arm 再装甲：本机记录里的乙不在手机上了，不带；乙是旧壳出的、新宿主认不得，也不再报 container_stale 挡住甲。
        装上后设备记录只剩甲"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙"))
        ios_fixture(self.c, A, pack="pa"); ios_fixture(self.c, B, shell="SID0", pack="pb", compat=dict(hostAbi=1, dmshChain="bbbb"))
        layout.save_device(self.c, "dev1", dict(games={B: dict(pack="pb")}, shellId="SID0"))
        ph, pushed, signed = self._phone(); self._app_gone(ph)
        import ipa as packer, host_update
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", self._run([])):
            r = install.put_game(self.c, A, ph)
        self.assertEqual((pushed, signed, r["games"]), ([A], [([A], ([A], "SID1"))], [A]))
        self.assertEqual(layout.load_device(self.c, "dev1")["games"], {A: dict(pack="pa")})

    def test_commit_phone_ipa_keeps_previous_only_when_shell_changes(self):
        """③ 同壳覆盖 S2Arm.ipa（不动上一版）；换壳时原来的 S2Arm.ipa 留作 S2Arm.previous.ipa；组装用的临时目录删掉"""
        import ipa as packer
        cur, prev = self.c.library / "S2Arm.ipa", self.c.library / "S2Arm.previous.ipa"
        def staged(sid, games):
            return self._ipa(self.c.library / (".container-" + sid + "-" + "-".join(games)) / "S2Arm.ipa", sid, games)
        t1 = staged("SID1", [self.A])
        packer.commit_phone_ipa(self.c, t1, "SID1")                    # 第一次：没有原来的
        self.assertEqual(install_ipa_games(cur), ([self.A], "SID1")); self.assertFalse(prev.exists()); self.assertFalse(t1.parent.exists())
        packer.commit_phone_ipa(self.c, staged("SID1", [self.A, self.B]), "SID1")   # 同壳加款：覆盖
        self.assertEqual(install_ipa_games(cur), ([self.A, self.B], "SID1")); self.assertFalse(prev.exists())
        packer.commit_phone_ipa(self.c, staged("SID2", [self.A]), "SID2")           # 换壳：原来的留作上一版
        self.assertEqual((install_ipa_games(cur), install_ipa_games(prev)), (([self.A], "SID2"), ([self.A, self.B], "SID1")))
        packer.commit_phone_ipa(self.c, staged("SID2", [self.A, self.C]), "SID2")   # 新壳上再加款：上一版不被冲掉
        self.assertEqual((install_ipa_games(cur), install_ipa_games(prev)), (([self.A, self.C], "SID2"), ([self.A, self.B], "SID1")))

    def test_restore_previous_swaps_and_records_failed_shell(self):
        """④ 装回上一版：装的是 S2Arm.previous.ipa；装上后现行与上一版对调；被换下的壳 SID2 记进 failedShells；设备记录壳号改回 SID1、只留上一版里有的款（资源包号保留）"""
        A, B = self.A, self.B
        self._ipa(self.c.library / "S2Arm.ipa", "SID2", [A, B]); self._ipa(self.c.library / "S2Arm.previous.ipa", "SID1", [A])
        layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="pb")}, shellId="SID2", bundleId="io.s2arm.games.team1", failedShells=["SID0"]))
        ph, _, signed = self._phone()
        with um.patch.object(install, "phone_for", return_value=ph):
            r = install.restore_previous(self.c)
        self.assertEqual(signed, [([A], ([A], "SID1"))])
        self.assertEqual(install_ipa_games(self.c.library / "S2Arm.ipa"), ([A], "SID1"))
        self.assertEqual(install_ipa_games(self.c.library / "S2Arm.previous.ipa"), ([A, B], "SID2"))
        rec = layout.load_device(self.c, "dev1")
        self.assertEqual((rec["shellId"], rec["failedShells"], rec["games"]), ("SID1", ["SID0", "SID2"], {A: dict(pack="pa")}))
        self.assertEqual((r["restoredShell"], r["games"]), ("SID1", [A]))
        # 再点一次 = 换回 SID2：SID2 从 failedShells 去掉（装回的这一版不算不好用），换下的 SID1 记进去
        with um.patch.object(install, "phone_for", return_value=ph):
            install.restore_previous(self.c)
        rec = layout.load_device(self.c, "dev1")
        self.assertEqual((rec["shellId"], rec["failedShells"]), ("SID2", ["SID0", "SID1"]))
        self.assertEqual(install_ipa_games(self.c.library / "S2Arm.ipa"), ([A, B], "SID2"))
        # 没有上一版：不找设备、不装
        (self.c.library / "S2Arm.previous.ipa").unlink()
        with um.patch.object(install, "phone_for", side_effect=AssertionError("不该找设备")):
            with self.assertRaises(Failure) as e: install.restore_previous(self.c)
        self.assertEqual(e.exception.code, "job_failed")

    def test_remove_from_phone_not_in_container(self):
        """这台手机的记录里没有这款 → 失败，不装"""
        layout.save_device(self.c, "dev1", dict(games={self.A: {}}))
        ph, _, _ = self._phone()
        self.c.r.update(gameId=self.B)
        with um.patch.object(install, "phone_for", return_value=ph):
            with self.assertRaises(Failure) as e: install.remove_from_phone(self.c)
        self.assertEqual(e.exception.code, "job_failed"); self.assertIn("没有这款", str(e.exception))
        ph.install.assert_not_called()

    def test_remove_from_phone_last_game(self):
        """最后一款（#227）：备份存档、删手机上它的数据，不装空容器；设备记录摘空"""
        layout.save_device(self.c, "dev1", dict(games={self.A: dict(pack="pa")}))
        ph, _, _ = self._phone(); ph.backup.return_value = None; ph.purge.return_value = (True, "")
        self.c.r.update(gameId=self.A)
        with um.patch.object(install, "phone_for", return_value=ph):
            r = install.remove_from_phone(self.c)
        ph.install.assert_not_called()
        ph.backup.assert_called_once_with(self.A); ph.purge.assert_called_once_with(self.A)
        self.assertEqual((r["games"], layout.load_device(self.c, "dev1")["games"]), ([], {}))

    def test_remove_from_phone_after_app_deleted_does_not_reinstall(self):
        """玩家在手机上删了整个 S2Arm，再在电脑上「从 iPhone 删除」甲：记录里的乙也不在手机上，不现组容器、不把 App 装回去；设备记录摘空"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙")); ios_fixture(self.c, B)
        layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="cafe01")}, shellId="SID1"))
        ph, _, _ = self._phone(); ph.backup.return_value = None; ph.purge.return_value = (False, "取不到容器"); self._app_gone(ph)
        self.c.r.update(gameId=A)
        import ipa as packer, host_update
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        with um.patch.object(install, "phone_for", return_value=ph), um.patch.object(packer, "current_shell_id", return_value="SID1"), \
             um.patch.object(packer, "container_shell", return_value=shell), um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), \
             um.patch.object(self.c, "run", self._run([])):
            r = install.remove_from_phone(self.c)
        ph.install.assert_not_called()
        self.assertEqual((r["games"], layout.load_device(self.c, "dev1")["games"]), ([], {}))

    def test_remove_from_phone_reassembles_rest_and_purge_failure_warns(self):
        """删甲：用剩下的乙现组容器装上，设备记录只剩乙，S2Arm.ipa 换成新组的；机上数据没删掉只报 container_purge_failed 黄字"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙")); ios_fixture(self.c, B)
        layout.save_device(self.c, "dev1", dict(games={A: dict(pack="pa"), B: dict(pack="cafe01")}, shellId="SID1"))
        ph, _, signed = self._phone(); ph.backup.return_value = None; ph.purge.return_value = (False, "清不掉")
        self.c.r.update(gameId=A)
        import ipa as packer, host_update
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        with um.patch.object(install, "phone_for", return_value=ph), um.patch.object(packer, "current_shell_id", return_value="SID1"), \
             um.patch.object(packer, "container_shell", return_value=shell), um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), \
             um.patch.object(self.c, "run", self._run([])):
            r = install.remove_from_phone(self.c)
        self.assertEqual(signed, [([B], ([B], "SID1"))])
        self.assertEqual(layout.load_device(self.c, "dev1")["games"], {B: dict(pack="cafe01")})
        self.assertEqual(install_ipa_games(layout.phone_ipa(self.c)), ([B], "SID1"))
        self.assertFalse(r["dataRemoved"])
        diags = [d for d in self.c.job["diagnostics"] if d["code"] == "container_purge_failed"]
        self.assertEqual([d["severity"] for d in diags], ["warning"])

    def test_remove_from_phone_falls_back_to_drop_when_rest_is_stale(self):
        """剩下的款新运行层认不得（升级后没重出）：不报错，退回从 S2Arm.ipa 里摘掉这款（drop_from_ipa，不换壳）"""
        A, B = self.A, self.B
        self._library((A, "甲"), (B, "乙"))
        self._ipa(layout.phone_ipa(self.c), "SID1", [A, B])
        layout.save_device(self.c, "dev1", dict(games={A: {}, B: {}}, shellId="SID1"))
        ph, _, signed = self._phone(); ph.backup.return_value = None; ph.purge.return_value = (True, "")
        self.c.r.update(gameId=A)
        import ipa as packer
        dropped = []
        def drop(c, ipa, gid):
            dropped.append((Path(ipa), gid))
            return self._ipa(self.c.library / ".container-drop" / "S2Arm.ipa", "SID1", [B]), [B], "SID1"
        stale = Failure("认不得", code="container_stale")
        with um.patch.object(install, "phone_for", return_value=ph), um.patch.object(packer, "assemble", side_effect=stale), \
             um.patch.object(packer, "drop_from_ipa", side_effect=drop):
            r = install.remove_from_phone(self.c)
        self.assertEqual(dropped, [(layout.phone_ipa(self.c), A)])
        self.assertEqual(signed, [([B], ([B], "SID1"))])
        self.assertEqual((r["games"], install_ipa_games(layout.phone_ipa(self.c))), ([B], ([B], "SID1")))


def library_pack(c, gid):
    return layout.ios_pack(c, gid)


def img_module():
    """pack/img.py（按文件加载：把 pack/ 放进 sys.path 会让 pack/pack.py 盖住 pack 包）"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("s2a_pack_img", Path(__file__).resolve().parents[2] / "img.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


class ExportPhoneTests(unittest.TestCase):
    """导出，自己签名安装（export_phone）：不连手机、不签名；游戏库根「S2Arm 自签导出」= 未签名 S2Arm.ipa（能放进本壳的各款）+ 各款 <名字>.img + 说明"""
    setUp = _jobs_setup_no_phone_games; tearDown = tj.JobsTests.tearDown
    A, B, C, D = AssembleTests.A, AssembleTests.B, AssembleTests.C, "0100000000040000"
    COMPAT = AssembleTests.COMPAT
    _library, _run, _ipa = AssembleTests._library, AssembleTests._run, staticmethod(AssembleTests._ipa)   # 只借替身，不继承它的用例

    def _img(self, gid, data):
        """把这款的资源包改成单一 IMG 形态：真的 game.img（pack/img.py build，其余文件段放 data）+ 照旧按文件放的着色器库 shaders/direct/lib.bin，
        清单 v3 format=img、index.tsv 登记 game.img 与着色器库"""
        img = img_module()
        _, pk = ios_fixture(self.c, gid)
        for f in pk.iterdir():
            shutil.rmtree(f) if f.is_dir() else f.unlink()
        src = pk.parent / "data.bin"; src.write_bytes(data)
        img.build(None, [("exefs/main", str(src))], str(pk / "game.img"), gid, "p" + gid[-5:], say=lambda *_: None); src.unlink()
        (pk / "shaders/direct").mkdir(parents=True); (pk / "shaders/direct/lib.bin").write_bytes(b"LIB" + gid.encode())
        (pk / "index.tsv").write_text(f"game.img\t{(pk / 'game.img').stat().st_size}\tp\nshaders/direct/lib.bin\t{3 + len(gid)}\th\n")
        (pk / "manifest.json").write_text(json.dumps({"version": 3, "format": "img", "imgFile": "game.img", "index_sha256": "p" + gid[-5:]}))
        return pk

    def _export(self, request, fn=None):
        import ipa as packer, host_update, rewrite_refresh
        self.sid = "SID1"
        shell = self.c.private / "shell"; shell.mkdir(exist_ok=True); (shell / "manifest.json").write_text("{}")
        self.c.r = dict(self.c.r, **request)
        def no_phone(c):
            raise AssertionError("导出不该找手机")
        fake = self._run([])
        def run(args, log=None, env=None, cwd=None, on_line=None):   # 导出单文件 IMG（pack/img.py export）真跑，组装照旧用替身
            if "pack/img.py" in [str(a) for a in args]:
                r = subprocess.run([str(a) for a in args], cwd=cwd, env=env, capture_output=True, text=True)
                if r.returncode: raise AssertionError(r.stdout + r.stderr)
                return
            return fake(args, log, env, cwd, on_line)
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), um.patch.object(packer, "container_shell", return_value=shell), \
             um.patch.object(host_update, "engine_compat", return_value=dict(self.COMPAT)), um.patch.object(self.c, "run", run), \
             um.patch.object(rewrite_refresh, "refresh_ios", lambda c, games: None), um.patch.object(install, "phone_for", no_phone):
            return (fn or install.install)(self.c)

    def test_export_folder_has_ipa_imgs_and_readme(self):
        """装法 export：点甲 → 甲、乙（单一 IMG）进容器和文件夹；丙旧格式点名跳过；丁没出过 iPhone 版不提；文件夹里只有 ipa、两份 .img（内容同库里）、说明"""
        A, B, C = self.A, self.B, self.C
        self._library((A, "甲"), (B, "乙"), (C, "丙"), (self.D, "丁"))
        self._img(A, b"S2AIMG01-a"); self._img(B, b"S2AIMG01-b"); ios_fixture(self.c, C)
        (self.c.private / "install.json").write_text(json.dumps({"mode": "export"}))
        r = self._export(dict(gameId=A))
        out = self.c.library / install.EXPORT_DIRS["zh"]
        self.assertEqual((r["exported"], r["outputPath"], r["games"], r["skipped"]), (True, str(out), [A, B], ["丙"]))
        self.assertEqual(sorted(p.name for p in out.iterdir()), sorted(["S2Arm.ipa", "甲.img", "乙.img", install.EXPORT_READMES["zh"]]))
        # 一款一个文件：原资源包的其余文件段 + 着色器库进了目录表（手机认领后照常解出来）；原 game.img 不动
        img = img_module()
        for f, gid, data in (("甲.img", A, b"S2AIMG01-a"), ("乙.img", B, b"S2AIMG01-b")):
            got = {p: (off, n) for p, off, n in img.entries(str(out / f))}
            with open(out / f, "rb") as fh:
                def rd(p): fh.seek(got[p][0]); return fh.read(got[p][1])
                self.assertEqual((rd("exefs/main"), rd("shaders/direct/lib.bin"), img.header(str(out / f))["gid"]), (data, b"LIB" + gid.encode(), gid))
            self.assertNotIn("shaders/direct/lib.bin", {p for p, _, _ in img.entries(str(library_pack(self.c, gid) / "game.img"))})
        self.assertEqual(install_ipa_games(out / "S2Arm.ipa"), ([A, B], "SID1"))
        readme = (out / install.EXPORT_READMES["zh"]).read_text(encoding="utf-8-sig")
        self.assertIn("甲.img（甲）", readme); self.assertIn("乙.img（乙）", readme); self.assertIn("放这里导入", readme)
        self.assertEqual(r["exportBytes"], sum(p.stat().st_size for p in out.iterdir()))
        self.assertEqual([p.name for p in self.c.library.iterdir() if p.name.startswith(".export-")], [])   # 临时目录收干净

    def test_export_replaces_whole_folder(self):
        """再导出一次：文件夹整个换新（上次的、玩家放进去的别的文件都不在了）"""
        self._library((self.A, "甲")); self._img(self.A, b"S2AIMG01-a")
        out = self.c.library / install.EXPORT_DIRS["zh"]; out.mkdir(); (out / "旧.img").write_bytes(b"old")
        self._export(dict(gameId=self.A, mode="export"))
        self.assertFalse((out / "旧.img").exists())
        self.assertTrue((out / "甲.img").is_file())

    def test_export_names_follow_ui_language(self):
        """i18n：英文界面（uiLanguage = en）→ 文件夹「S2Arm Self-Sign Export」、说明「How to install on iPhone.txt」（英文正文：Import Here、
        Settings → General → VPN & Device Management）；之后换回中文再导出 → 「S2Arm 自签导出」+「怎么装到 iPhone.txt」，英文名的旧导出删掉，只留一份"""
        self._library((self.A, "甲")); self._img(self.A, b"S2AIMG01-a")
        en, zh = self.c.library / "S2Arm Self-Sign Export", self.c.library / "S2Arm 自签导出"
        r = self._export(dict(gameId=self.A, mode="export", uiLanguage="en"))
        self.assertEqual(sorted(p.name for p in en.iterdir()), sorted(["S2Arm.ipa", "甲.img", "How to install on iPhone.txt"]))
        self.assertEqual((r["outputPath"], r["readme"]), (str(en), str(en / "How to install on iPhone.txt")))
        text = (en / "How to install on iPhone.txt").read_text(encoding="utf-8-sig")
        for want in ("甲.img (甲)", "Import Here", "Settings → General → VPN & Device Management"): self.assertIn(want, text)
        self.assertNotIn("放这里导入", text); self.assertFalse(zh.exists())
        self._export(dict(gameId=self.A, mode="export", uiLanguage="zh-Hans"))
        self.assertEqual(sorted(p.name for p in zh.iterdir()), sorted(["S2Arm.ipa", "甲.img", "怎么装到 iPhone.txt"]))
        self.assertFalse(en.exists(), "换回中文：英文名的旧导出删掉")
        self.assertEqual([p.name for p in self.c.library.iterdir() if p.name.startswith(".export-")], [])

    def test_export_requested_old_format_is_named(self):
        """点的这款还是旧格式资源包：导出不了单个 game.img，报 pack_missing 说要重新打 iPhone 包"""
        self._library((self.A, "甲")); ios_fixture(self.c, self.A)
        with self.assertRaises(Failure) as e: self._export(dict(gameId=self.A, mode="export"))
        self.assertEqual(e.exception.code, "pack_missing")

    def test_export_file_names(self):
        """文件名取游戏名：不能做文件名的字符换空格；重名带游戏号"""
        used = set()
        self.assertEqual(install._img_name("a/b", self.A, used), "a b.img")
        self.assertEqual(install._img_name("a b", self.B, used), f"a b {self.B}.img")
        self.assertEqual(install._img_name("", self.C, used), f"{self.C}.img")

    def test_request_mode_overrides_setting(self):
        """完成页临时换一次：设置是 export、请求带 mode=device → 照一键装走（put_game）；设置是 device、请求带 export → 导出"""
        self._library((self.A, "甲")); self._img(self.A, b"S2AIMG01-a")
        (self.c.private / "install.json").write_text(json.dumps({"mode": "export"}))
        with um.patch.object(install, "put_game", return_value=dict(device="x")) as put, um.patch.object(install, "phone_for", return_value=object()):
            self.c.r = dict(self.c.r, gameId=self.A, mode="device")
            self.assertEqual(install.install(self.c), dict(device="x"))
            put.assert_called_once()
        (self.c.private / "install.json").write_text(json.dumps({"mode": "device"}))
        self.assertTrue(self._export(dict(gameId=self.A, mode="export"))["exported"])

    def test_update_in_export_mode_exports(self):
        """导出模式的「导出新版 S2Arm」：不连手机，游戏库里能带的各款出到文件夹，updated = True"""
        self._library((self.A, "甲"), (self.B, "乙")); self._img(self.A, b"a"); self._img(self.B, b"b")
        r = self._export(dict(mode="export"), fn=install.update_phone)
        self.assertEqual((r["exported"], r["updated"], r["games"]), (True, True, [self.A, self.B]))


def install_ipa_games(ipa):
    import ipa as packer
    return packer.ipa_games(ipa)


class DropRestampTests(unittest.TestCase):
    """#845 摘掉一款后重算容器摘要（ipa.finish_container）：摘之前整套的摘要写在 Info.plist 里；摘掉一款后内容变了，
    新 ipa 里的摘要必须非空、且不等于整套的旧值——否则之后再装回整套时 same_app 误判相同、跳过重装，摘掉的那款回不到手机上"""

    def test_drop_restamps_digest(self):
        import ipa as packer
        t = Path(tempfile.mkdtemp()); self.addCleanup(lambda: shutil.rmtree(t, ignore_errors=True))
        app = t / "build" / "Payload" / "S2Arm.app"
        A, B = "0100000000010000", "0100000000020000"
        for g in (A, B):
            (app / "Games" / g).mkdir(parents=True); (app / "Games" / g / "main.npdm").write_bytes(g.encode() + bytes(16))
            (app / "Frameworks").mkdir(exist_ok=True); (app / f"Frameworks/S2AImages-{g}.dylib").write_bytes(g.encode())
        (app / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "shell_id": "SID1", "games": [{"title_id": A}, {"title_id": B}]}))
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.s2arm.games"}))
        full = packer.stamp_container(app)
        ipa = t / "S2Arm.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            for f in sorted((t / "build").rglob("*")):
                if f.is_file(): z.write(f, f.relative_to(t / "build").as_posix())
        self.assertEqual(packer.ipa_digest(ipa), full)
        lib = t / "lib"; lib.mkdir()
        c = types.SimpleNamespace(library=lib, logs=t, task="drop", engine=Path(packer.__file__).resolve().parents[2],
                                  env=lambda: dict(os.environ), run=lambda args, log, env, **kw: subprocess.run([str(a) for a in args], check=True, capture_output=True))
        def zip_app(c, a, out, log):   # 写 ipa 的完整校验（app_bundle write_ipa）不在这里核：照原样打包
            with zipfile.ZipFile(out, "w") as z:
                for f in sorted(Path(a).rglob("*")):
                    if f.is_file(): z.write(f, "Payload/S2Arm.app/" + f.relative_to(a).as_posix())
        with um.patch.object(packer, "sign_container", lambda *a, **k: None), um.patch.object(packer, "write_container_ipa", zip_app):   # 签名要 codesign，这里只核摘要
            new, left, _ = packer.drop_from_ipa(c, ipa, A)
        self.assertEqual(left, [B])
        got = packer.ipa_digest(new)
        self.assertTrue(got); self.assertNotEqual(got, full)


class ShipExtContainerDropTests(unittest.TestCase):
    """④ ship_ext container-drop：其余款字节不变、catalogue 少一款、最后一款拒绝"""

    def setUp(self):
        self.t = tempfile.mkdtemp()
        import shutil; self.addCleanup(lambda: shutil.rmtree(self.t, ignore_errors=True))
        self.base = Path(self.t) / "base.app"
        self.base.mkdir()

    def _make_container(self, games):
        import struct
        for g in games:
            gdir = self.base / "Games" / g; gdir.mkdir(parents=True, exist_ok=True)
            # 写一个伪可执行文件，带游戏特定字节，用于验证字节不变
            (gdir / "main.npdm").write_bytes(g.encode() + bytes(16))
            (self.base / "Frameworks").mkdir(exist_ok=True)
            (self.base / f"Frameworks/S2AImages-{g}.dylib").write_bytes(g.encode())
        (self.base / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "games": [{"title_id": g} for g in games]}))
        return self.base

    def _drop(self, game):
        import sys; sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
        import ship_ext as se
        import argparse
        out = Path(self.t) / "out.app"
        a = argparse.Namespace(base=str(self.base), game=game, out=str(out))
        se.cmd_container_drop(a)
        return out

    def test_drop_removes_game_and_keeps_others(self):
        A, B = "0100000000010000", "0100000000020000"
        self._make_container([A, B])
        out = self._drop(A)
        cat = json.loads((out / "s2a_catalogue.json").read_text())
        left = [g["title_id"] for g in cat["games"]]
        self.assertEqual(left, [B])
        # B 的文件字节不变
        self.assertEqual((out / "Games" / B / "main.npdm").read_bytes(), B.encode() + bytes(16))
        # A 的目录已删
        self.assertFalse((out / "Games" / A).exists())

    def test_drop_last_game_leaves_empty_container(self):
        """#227：摘最后一款不再拒，得到 0 款的容器（游戏库侧下次加款的底子），它的目录和镜像包都没了"""
        A = "0100000000010000"
        self._make_container([A])
        out = self._drop(A)
        self.assertEqual(json.loads((out / "s2a_catalogue.json").read_text())["games"], [])
        self.assertFalse((out / "Games" / A).exists()); self.assertFalse((out / f"Frameworks/S2AImages-{A}.dylib").exists())


if __name__ == "__main__":
    unittest.main()


class ApplyFailureReasonTests(unittest.TestCase):
    """手机上解开失败（如 #569 目录 App 写不进）：tools/push_pack.py 按解包日志「解包失败：…」当场报原因，装机作业认这一句、原因原样上屏。
    两边原句对不上会红（期望手写）"""
    def test_job_reads_the_push_tool_sentence(self):
        import install
        tool = (Path(install.__file__).resolve().parents[2] / "tools/push_pack.py").read_text(encoding="utf-8")
        self.assertIn('f"资源包推进去了，但手机上解开失败：{', tool)
        log = "[12:00:09] 【红】资源包推进去了，但手机上解开失败：目录 App 写不进：资源包/.incoming（属主 uid 0、权限 755，App 是 uid 501）\n"
        self.assertEqual(install.APPLY_FAILED.search(log).group(1), "目录 App 写不进：资源包/.incoming（属主 uid 0、权限 755，App 是 uid 501）")


class DevicectlTimeoutTests(unittest.TestCase):
    """#333：devicectl 超时（锁屏 / 隧道断时一直挂）转成非零返回码 124 + 人话原因，不再抛 TimeoutExpired 让装机任务裸 traceback 收场"""
    def test_timeout_becomes_rc_124(self):
        import subprocess, diag
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "Resources/bin/devicectl"; exe.parent.mkdir(parents=True); exe.write_text("#!/bin/sh\n"); exe.chmod(0o755)
            c = types.SimpleNamespace(private=Path(d), env=lambda: dict(os.environ))
            with um.patch.object(diag, "COREDEVICE", Path(d)), \
                 um.patch.object(diag.subprocess, "run", side_effect=subprocess.TimeoutExpired("devicectl", 120)):
                rc, data, err = diag.devicectl(c, "device", "info", "files", timeout=120)
        self.assertEqual((rc, data, err), (124, {}, "devicectl 等了 120 秒没有返回，已停止等待"))   # 如实说超时，不猜锁屏（剃刀 H21）


class PhoneGamesTruthTests(unittest.TestCase):
    """两端混装（同一台手机 Mac 装几款、Windows 再装一款）：手机上有哪些游戏以手机为准（期望按规则手写）"""
    A, B, C, D = "0100000000010000", "0100000000020000", "0100000000030000", "0100000000040000"
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    NEW, OLD = "Library/Application Support/S2Arm/games", "Documents/games"
    MISSING = "S2A_AFC_ERR 8 Object not found"

    def fs(self, dirs, ls_error=None, rms=None):
        """假手机：dirs = {设备侧目录: [条目…]}，不在 dirs 里的目录 ls 报 AFC 不存在；ls_error = 每次 ls 都报这句（锁屏 / 没装）"""
        class Cl:
            def call(self, op, rel):
                if ls_error: return 1, ls_error
                return (0, "\n".join(dirs[rel])) if rel in dirs else (1, test.MISSING)
            def rm(self, rel):
                rms.append(rel); return (False, "清不掉") if rel.startswith(test.NEW) and "fail" in dirs else (True, "")
            def get(self, rel, dst): return False
        test = self
        return lambda c, udid, bid, work: Cl()

    def client(self, games_ls, applied, ls_error=None):   # 旧布局：各款都在 Documents/games/<游戏号>/资源包
        dirs = {self.OLD: games_ls}
        for g in games_ls:
            dirs[f"{self.OLD}/{g.strip().rstrip('/').upper()}/资源包"] = [".applied", "index.tsv"] if g.strip().rstrip("/") in applied else ["index.tsv"]
        return self.fs(dirs, ls_error)

    def ph(self, missing=False):
        return types.SimpleNamespace(udid="U1", bid="io.s2arm.games.abcde12345", app_missing=lambda bid, why: missing, c=self.c)

    def decisions(self):
        f = self.c.logs / f"{self.c.task}-decisions.log"
        return f.read_text(encoding="utf-8") if f.is_file() else ""

    def test_only_game_ids_with_applied_pack_count(self):
        with um.patch.object(install, "devpush_client", self.client([self.A + "/", "notes", self.B, "0100000000099999x", self.C], {self.A, self.C})):
            self.assertEqual(install.phone_games(self.c, self.ph()), {self.A, self.C})   # B 没解开、别的名字跳过

    def test_app_not_installed_is_none_unreadable_continues(self):
        # 装机原则（11-11「认不出的直接装」）：平台确认没装 → None；装着却进不去 / 判不了 → 按「手机上没有别的游戏」照装，只记进日志
        err = self.client([], set(), ls_error="取不到 x 的容器（App 没装或不是开发签名）：device socket io failed")
        with um.patch.object(install, "devpush_client", err):
            self.assertIsNone(install.phone_games(self.c, self.ph(missing=True)))            # 平台确认没装：None，不是「装着、一款都没有」的空集
            self.assertEqual(install.phone_games(self.c, self.ph(missing=False)), set())   # 判不了：空集照装，不再报 device_locked
        self.assertIn("device socket io failed", self.decisions())
        err2 = self.client([], set(), ls_error="找不到设备 00008150-FAKEDEVICE：device not found")
        with um.patch.object(install, "devpush_client", err2):
            self.assertEqual(install.phone_games(self.c, self.ph(missing=False)), set())

    def test_windows_real_device_socket_text(self):
        """11-11 Windows 实机原文：删了手机上的 S2Arm 再装，Windows 上 s2a-devpush 进不了容器只回「device socket io failed」。
        走真的 WinPhone.app_missing：旧工具只有这句原文 → 判不了 → 照装（空集）；新工具查过 installation_proxy 打 S2A_APP_MISSING → None（确实没装）"""
        win = install.WinPhone.__new__(install.WinPhone); win.c = self.c; win.udid = "U1"; win.bid = "io.s2arm.games.d9g8my5fb5"; win.info = {}
        raw = "取不到 io.s2arm.games.d9g8my5fb5 的容器（App 没装或不是开发签名）：device socket io failed"
        with um.patch.object(install, "devpush_client", self.fs({}, ls_error=raw)):
            self.assertEqual(install.phone_games(self.c, win), set())
        new = "S2A_APP_MISSING：手机上没装 io.s2arm.games.d9g8my5fb5（installation_proxy 查过；进容器原文：device socket io failed）"
        with um.patch.object(install, "devpush_client", self.fs({}, ls_error=new)):
            self.assertIsNone(install.phone_games(self.c, win))

    def test_games_folder_not_created_yet_is_zero_games(self):
        """首次装机：App 在、还没有 Documents/games——当 0 款照常装（v0.2.8 热修，玩家实机原文「afc error: Object not found」带空格，原先被当读不出设备挡住）。
        新工具给结构化码 S2A_AFC_ERR 8；旧工具 / devicectl 只有原文，带不带空格、大小写都认。别的 AFC 错误码（如 4 读错误）与锁屏 / 断连照旧停"""
        for out in ("S2A_AFC_ERR 8 Object not found", "afc error: Object not found", "ObjectNotFound", "No such file or directory", "OBJECT NOT FOUND"):
            with self.subTest(out=out), um.patch.object(install, "devpush_client", self.client([], set(), ls_error=out)):
                self.assertEqual(install.phone_games(self.c, self.ph()), set())
        for out in ("S2A_AFC_ERR 4 Read error", "device socket io failed"):   # 别的读错误 / 断连：判不了，照装原则继续（空集），不再挡
            with self.subTest(out=out), um.patch.object(install, "devpush_client", self.client([], set(), ls_error=out)):
                self.assertEqual(install.phone_games(self.c, self.ph()), set())

    def test_new_and_old_pack_locations_both_count(self):
        """11-11 资源包挪到 Library：过渡期新旧两处都认。A 在新位置已解开；B 只在旧位置已解开；C 新位置在但没解开（旧位置的 .applied 不算：按选出的那一处）；
        D 新旧都没有资源包目录。Documents/games 在（存档）也好、不在也好，结果一样"""
        A, B, C, D = self.A, self.B, self.C, self.D
        dirs = {self.NEW: [A, C], self.OLD: [B, C, D],
                f"{self.NEW}/{A}/资源包": [".applied"], f"{self.OLD}/{B}/资源包": [".applied", "index.tsv"],
                f"{self.NEW}/{C}/资源包": ["index.tsv"], f"{self.OLD}/{C}/资源包": [".applied"]}
        with um.patch.object(install, "devpush_client", self.fs(dirs)):
            self.assertEqual(install.phone_games(self.c, self.ph()), {A, B})
        only_new = {self.NEW: [A], f"{self.NEW}/{A}/资源包": [".applied"]}   # 全新装的手机：还没有 Documents/games
        with um.patch.object(install, "devpush_client", self.fs(only_new)):
            self.assertEqual(install.phone_games(self.c, self.ph()), {A})

    def test_pick_pack_root_new_old_or_first_install(self):
        """推到哪：新位置在 → 新；新不在、旧在 → 旧（App 下次启动整个挪过去，增量照旧算）；都不在 → 新；列不出 → 按第一次装推到新位置、记一笔"""
        A = self.A
        new, old = f"Library/Application Support/S2Arm/games/{A}/资源包", f"Documents/games/{A}/资源包"
        for dirs, want in (({new: ["index.tsv"], old: [".applied"]}, new),
                           ({old: [".applied"]}, old),
                           ({}, new)):
            with self.subTest(have=sorted(dirs)), um.patch.object(install, "devpush_client", self.fs(dirs)):
                self.assertEqual(install.pick_pack_root(self.c, self.ph(), A), want)
        with um.patch.object(install, "devpush_client", self.fs({}, ls_error="device socket io failed")):
            self.assertEqual(install.pick_pack_root(self.c, self.ph(), A), new)
        self.assertIn("按第一次装推到新位置", self.decisions())

    def test_purge_removes_docs_root_and_new_pack_location(self):
        """删手机上这款：文档根（含旧位置资源包）和新位置本款目录都删；新位置删不掉 → 报没删干净"""
        rms = []
        install.purge_game(self.fs({}, rms=rms)(None, None, None, None), self.A)
        self.assertEqual(rms, [f"Documents/games/{self.A}", f"Library/Application Support/S2Arm/games/{self.A}", f"Library/S2Arm/games/{self.A}"])
        rms = []
        ok, out = install.purge_game(self.fs({"fail": []}, rms=rms)(None, None, None, None), self.A)
        self.assertEqual((ok, out), (False, "清不掉"))

    def test_alt_location_wins_once_it_exists(self):
        """备用位置 Library/S2Arm/games 在（新壳把整条归 root 的 Application Support 搬出来过）：这款在不在都推它、列它；
        不在：照旧新位置 → 旧位置 → 第一次装推新位置（期望按规则手写）"""
        alt = f"Library/S2Arm/games/{self.A}/资源包"
        cl = self.fs({"Library/S2Arm/games": [self.A], alt: [".applied", "index.tsv"], f"Library/Application Support/S2Arm/games/{self.A}/资源包": ["x"]})(None, None, None, None)
        self.assertEqual(install.pack_listing(cl, self.A), (alt, [".applied", "index.tsv"]))
        cl = self.fs({"Library/S2Arm/games": []})(None, None, None, None)
        self.assertEqual(install.pack_listing(cl, self.A), (alt, None))
        cl = self.fs({})(None, None, None, None)
        self.assertEqual(install.pack_listing(cl, self.A), (f"Library/Application Support/S2Arm/games/{self.A}/资源包", None))

    def test_name_read_from_phone_with_the_bundle_being_installed(self):
        # Windows 第一次装（这台还没记录包名）：确认框里的名字照样按这次要装的包名去手机上读 control.nacp（Windows 实机曾显示成游戏号）
        seen = []
        class Cl:
            def get(self, rel, dst): seen.append(rel); return False
        ph = types.SimpleNamespace(udid="U1", bid=None, bundle_for_signing=lambda: "io.s2arm.games.abcde12345")
        with um.patch.object(install, "devpush_client", lambda c, udid, bid, work: (seen.append(bid), Cl())[1]):
            self.assertEqual(install.phone_game_name(self.c, ph, self.B, {}), self.B)
        self.assertEqual(seen[0], "io.s2arm.games.abcde12345")

    def test_platform_says_whether_app_is_missing(self):
        # Mac：问 devicectl 应用列表（devpush 的原文和断线分不开）；问不出就停。Windows：只认 ApplicationLookupFailed 原文
        mac = install.MacPhone.__new__(install.MacPhone); mac.c = self.c; mac.dev = {"id": "D1"}
        bid = "io.s2arm.games.abcde12345"
        with um.patch("diag.devicectl", return_value=(0, {"result": {"apps": []}}, "")):
            self.assertTrue(mac.app_missing(bid, "device socket io failed"))
        with um.patch("diag.devicectl", return_value=(0, {"result": {"apps": [{"bundleIdentifier": bid}]}}, "")):
            self.assertFalse(mac.app_missing(bid, "device socket io failed"))
        with um.patch("diag.devicectl", return_value=(1, {}, "The device is locked")):   # 问不出：按装着、读不到，交 phone_games 照装（不再停）
            self.assertFalse(mac.app_missing(bid, "device socket io failed"))
        self.assertIn("问不出 iPhone 上有没有装过 S2Arm", self.decisions())
        win = install.WinPhone.__new__(install.WinPhone)
        self.assertTrue(win.app_missing(bid, "unknown error `ApplicationLookupFailed` returned from device"))
        self.assertTrue(win.app_missing(bid, "S2A_APP_MISSING：手机上没装 x"))
        self.assertFalse(win.app_missing(bid, "取不到 x 的容器（App 没装或不是开发签名）：device socket io failed"))
        self.assertFalse(win.app_missing(bid, "connection reset"))

    def test_include_what_we_can_ask_before_dropping_the_rest(self):
        # 本机记录 A；手机上 A、B、C；本机游戏库有 C（另一台电脑装的、这台也导入过）→ 带 A、C；B 只在手机上 → 先问
        atomic(self.c.library / "catalog.json", dict(schema=1, games=[dict(id=self.A, name="甲"), dict(id=self.C, name="丙")]))
        rec = dict(games={self.A: {}})
        with um.patch.object(install, "phone_games", lambda c, ph: {self.A, self.B, self.C}), \
             um.patch.object(install, "phone_game_name", lambda c, ph, g, names: "乙游戏"):
            with self.assertRaises(Failure) as e:
                install.container_others(self.c, self.ph(), rec, leave=self.D)
            self.assertEqual(e.exception.code, "container_would_drop")
            self.assertIn("1 款", str(e.exception)); self.assertIn("乙游戏", str(e.exception))
            self.c.r["acceptDropped"] = True
            self.assertEqual(install.container_others(self.c, self.ph(), rec, leave=self.D), [self.A, self.C])

    def test_app_gone_stops_carrying_this_computers_record(self):
        # 本机记录 A、B。玩家在手机上删了整个 S2Arm（平台确认这个包名没装）→ A、B 也不在手机上，一款都不带。
        # App 还在的两种照旧按本机记录带：还没有 games 目录；只有 A 解开了（B 可能在 App 里、资源包还没解开）
        rec = dict(games={self.A: {}, self.B: {}})
        gone = self.client([], set(), ls_error="取不到 x 的容器（App 没装或不是开发签名）：device socket io failed")
        with um.patch.object(install, "devpush_client", gone):
            self.assertEqual(install.container_others(self.c, self.ph(missing=True), rec, leave=self.D), [])
        with um.patch.object(install, "devpush_client", self.client([], set(), ls_error="No such file or directory")):
            self.assertEqual(install.container_others(self.c, self.ph(), rec, leave=self.D), [self.A, self.B])
        with um.patch.object(install, "devpush_client", self.client([self.A, self.B], {self.A})):
            self.assertEqual(install.container_others(self.c, self.ph(), rec, leave=self.D), [self.A, self.B])

