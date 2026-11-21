# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""独立 App（一 App 一游戏，0.6.3，pack/jobs/install.py put_app / chosen_layout / update_apps）。期望都按规则手写，不跑被测实现推：
  ① 出法：玩家选过的优先（按款 > 缺省），没选过时分发证书 → standalone、其余 → shell；layoutSet 写 / 撤；installMode 带 layout / distribution
  ② 包名：Apple ID → io.s2arm.games.<团队小写>.<程序号 16 位小写>；证书按描述文件（通配 / 前缀通配 / 显式只有一个）
  ③ put_app：按独立包名签装（去掉小组件）、资源推进独立 App；设备记录 apps[号] 写全，通用壳的 bundleId / shellId / games 不碰
  ④ installed_s2arm_on：独立 App 不算通用壳（设备记录 apps + 包名形状），通用壳不再判「装着不止一个、要选」
  ⑤ 升级：壳号旧的逐款重签，一款失败不挡后面，新壳认不得的报 container_stale；update_phone 装完壳接着做
  ⑥ 存档快照按包名分：独立 App 与通用壳里同一款各算各的，还原回备份所属的 App
  ⑦ Windows：install(bid=) 不写设备记录的 bundleId；证书签名按 bid 签、按包名另存 IPA
反证：installed_s2arm_on 不排除 → ④ 判 choose；put_app 写进 games 或改 rec.bundleId → ③ 红；update_apps 一款失败就抛 → ⑤ 红"""
import contextlib
import json
import time
import plistlib
import shutil
import sys
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jobcase  # noqa: E402
import install  # noqa: E402
import devcert  # noqa: E402
import layout  # noqa: E402
from core import Failure  # noqa: E402

G1, G2, G3 = "0100000000010000", "0100000000020000", "0100000000030000"
TEAM = "ABCDE12345"
SHELL_BID = "io.s2arm.games.abcde12345"
APP1 = "io.s2arm.games.abcde12345.0100000000010000"


def ctx(t, **r):
    c = jobcase.fake_context(t, r=dict(r))
    for d in (c.library, c.private, c.logs):
        d.mkdir(parents=True, exist_ok=True)
    return c


def use_devcert(c, distribution, bundle=SHELL_BID, appid=f"{TEAM}.*"):
    """在用的开发者证书（state.json + 三样文件；密码与描述文件读取替身掉）。distribution = 描述文件 get-task-allow 为假（分发）"""
    d = c.private / "devcert"
    d.mkdir(parents=True, exist_ok=True)
    (d / "cert.p12").write_bytes(b"p12")
    (d / "state.json").write_text(json.dumps(dict(active=True, certSha1="aa", bundleId=bundle, teamId=TEAM, teamName="T")))   # 同 11-20 前导入的：没有分发标记
    prof = plistlib.dumps({"ApplicationIdentifierPrefix": [TEAM], "TeamIdentifier": [TEAM], "Entitlements": {"application-identifier": appid, "get-task-allow": not distribution}})
    (d / "profile.mobileprovision").write_bytes(prof)
    return patch.object(devcert, "stored", lambda c_: (d / "cert.p12", prof, "pw"))


class Layout(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)

    def test_defaults(self):
        self.assertEqual(install.chosen_layout(self.c, G1), "shell", "Apple ID：通用壳")
        with use_devcert(self.c, distribution=False):
            self.assertEqual(install.chosen_layout(self.c, G1), "shell", "开发证书：通用壳")
        with use_devcert(self.c, distribution=True):
            self.assertEqual(install.chosen_layout(self.c, G1), "standalone", "分发证书：独立 App")
            r = install.install_mode_job(self.c)
            self.assertEqual((r["layout"], r["distribution"], r["layoutChoice"]), ("standalone", True, {}))

    def test_player_choice_wins(self):
        with use_devcert(self.c, distribution=True):
            r = install.layout_set(jobcase.fake_context(self.t, r=dict(layout="shell")))   # 缺省改成通用壳
            self.assertEqual((r["layout"], r["default"], r["games"]), ("shell", "shell", {}))
            self.assertEqual(install.chosen_layout(self.c, G1), "shell", "分发证书也按玩家选的")
            r = install.layout_set(jobcase.fake_context(self.t, r=dict(layout="standalone", gameId=G2.lower())))   # 这一款单独选独立 App
            self.assertEqual((r["layout"], r["default"], r["games"]), ("standalone", "shell", {G2: "standalone"}))
            self.assertNotIn("freeLimit", r, "用自己的证书：不提示免费账号限制")
            self.assertEqual((install.chosen_layout(self.c, G1), install.chosen_layout(self.c, G2)), ("shell", "standalone"))
            install.layout_set(jobcase.fake_context(self.t, r=dict(layout=None)))   # 撤掉缺省的选择：回到按证书判
            self.assertEqual((install.chosen_layout(self.c, G1), install.chosen_layout(self.c, G2)), ("standalone", "standalone"))
            install.layout_set(jobcase.fake_context(self.t, r=dict(layout=None, gameId=G2)))
            self.assertFalse((self.c.private / install.LAYOUT_CHOICE).exists(), "都撤了：文件删掉")

    def test_apple_id_standalone_warns_free_limit_but_saves(self):
        r = install.layout_set(jobcase.fake_context(self.t, r=dict(layout="standalone")))
        self.assertEqual((r["layout"], r["freeLimit"]), ("standalone", install.FREE_APP_LIMIT), "只提示、照样选上")
        with self.assertRaises(Failure):
            install.layout_set(jobcase.fake_context(self.t, r=dict(layout="both")))


class ShellWithDistributionCert(unittest.TestCase):
    def test_push_signing_says_why_games_wont_open(self):
        # 玩家选了通用壳、证书却是分发的：照推（不拦），黄字照实说起局会被系统拒、换独立 App 就能玩
        import program_pack
        with tempfile.TemporaryDirectory() as d:
            c = ctx(Path(d))
            for dist, want in ((False, []), (True, ["image_exec_cert"])):
                c.diagnostics.clear()
                with self.subTest(distribution=dist), use_devcert(c, distribution=dist), patch.object(program_pack, "devcert_signer", lambda c_: "SIGNER"):
                    self.assertEqual(install.phone_signing(c, types.SimpleNamespace()), (TEAM, SHELL_BID, "SIGNER"))
                    self.assertEqual([x["code"] for x in c.diagnostics], want)


class Bundle(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)

    def test_apple_id(self):
        ph = types.SimpleNamespace(W=types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: TEAM)))
        self.assertEqual(install.app_bundle(self.c, ph, G1), (APP1, TEAM, False))
        ph.W.impactor.selected_team = lambda: None
        with self.assertRaises(Failure) as e:
            install.app_bundle(self.c, ph, G1)
        self.assertEqual(e.exception.code, "apple_not_signed_in")

    def test_devcert_profiles(self):
        for appid, want in ((f"{TEAM}.*", (APP1, TEAM, False)), (f"{TEAM}.com.acme.*", ("com.acme.s2arm.0100000000010000", TEAM, False)),
                            (f"{TEAM}.com.acme.one", ("com.acme.one", TEAM, True))):
            with self.subTest(appid=appid), use_devcert(self.c, distribution=True, appid=appid):
                self.assertEqual(install.app_bundle(self.c, types.SimpleNamespace(), G1), want)


class PutApp(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)
        self.pack = self.t / "pack"; self.pack.mkdir()
        (self.pack / "manifest.json").write_text(json.dumps({"index_sha256": "P1"}))
        self.calls = dict(install=[], push=[], snap=[], assemble=[])
        self.ph = self.phone()
        self.gdir = self.t / "games" / "Game One"; self.gdir.mkdir(parents=True)

    def phone(self):
        calls = self.calls
        class Ph:   # 方法按 self 取包名（同真的手机类）：put_app 复制出的独立 App 对象推到自己的包名
            key = udid = "UDID1"
            bid, pending = SHELL_BID, None
            W = types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: TEAM))
            def __init__(self): self.info = dict(device="d", free=True)
            def pull_kept(self, g): return 0
            def before_push(self, packs): pass
            def client(self, w): return object()
            def install(self, ipa, games, steps=True, bid=None):
                with zipfile.ZipFile(ipa) as z:
                    calls["install"].append((bid, sorted(z.namelist())))
                return bid
            def push(self, g, pack):
                calls["push"].append((self.bid, g)); return 3, 30
        return Ph()

    def run_put(self, gid=G1, ph=None, sid="SID2"):
        import ipa as packer
        import rewrite_refresh
        import sgrade_bf
        def assemble(c, g, others=(), dest=None, **k):
            self.calls["assemble"].append(k.get("standalone"))   # 独立 App：主屏名 / 图标按这款组（ship_ext container --standalone）
            ipa = Path(dest) / "S2Arm.ipa"
            with zipfile.ZipFile(ipa, "w") as z:
                z.writestr("Payload/S2Arm.app/S2Arm", b"x")
                z.writestr(f"Payload/S2Arm.app/Frameworks/S2AImages-{g}.dylib", b"img")
                z.writestr("Payload/S2Arm.app/PlugIns/S2ArmWidget.appex/S2ArmWidget", b"w")
            return ipa, [g], sid
        with patch.object(install, "ios_pack", lambda c, g: self.pack), patch.object(packer, "assemble", assemble), \
                patch.object(packer, "program_locks", lambda c, g: contextlib.nullcontext()), patch.object(rewrite_refresh, "refresh_ios", lambda c, g: None), \
                patch.object(sgrade_bf, "rechain_ios", lambda c, g: "skip"), patch.object(install, "push_mods", lambda c, ph, g, m: {"m1": "fp"}), \
                patch.object(install, "snapshot_phone_saves", lambda c, ph, g: self.calls["snap"].append((ph.bid, ph.standalone, g)) or {}), \
                patch.object(install, "app_meta", lambda c, g: (self.gdir, "Game One", "1.2.0")):
            return install.put_app(self.c, gid, ph or self.ph, steps=False)

    def test_writes_apps_only(self):
        layout.save_device(self.c, "UDID1", dict(shellId="SID2", bundleId=SHELL_BID, games={G2: dict(pack="pb")}))
        out = self.run_put()
        bid, names = self.calls["install"][0]
        self.assertEqual(bid, APP1, "按独立包名签装")
        self.assertEqual(self.calls["assemble"], [True], "按独立 App 组（主屏名 / 图标是这款的）")
        self.assertIn(f"Payload/S2Arm.app/Frameworks/S2AImages-{G1}.dylib", names)
        self.assertFalse([n for n in names if "/PlugIns/" in n], "去掉小组件")
        self.assertEqual(self.calls["push"], [(APP1, G1)], "资源推进独立 App")
        self.assertEqual(self.calls["snap"], [(APP1, True, [G1])], "开头按独立 App 拉存档")
        rec = layout.load_device(self.c, "UDID1")
        self.assertEqual((rec["bundleId"], rec["shellId"], rec["games"]), (SHELL_BID, "SID2", {G2: dict(pack="pb")}), "通用壳的记录不碰")
        app = rec["apps"][G1]
        self.assertEqual((app["bundleId"], app["shellId"], app["team"], app["signer"], app["pack"], app["mods"]), (APP1, "SID2", TEAM, "plumesign", "P1", {"m1": "fp"}))
        self.assertEqual((app["signed"]["free"], app["signed"]["mode"]), (True, "appleId"))
        self.assertEqual(self.ph.bid, SHELL_BID, "手机对象的通用壳包名不变")
        self.assertEqual((out["bundleId"], out["layout"], out["games"], out["toShell"]), (APP1, "standalone", [G1], "SID2"))
        self.assertEqual([d["code"] for d in self.c.diagnostics], ["free_app_limit_note"], "免费账号：提示苹果限制，不拦")
        # 0.6.4：装上的这份进这款的游戏文件夹（<游戏名> v<版本>.ipa）+ 按界面语言的 README；成功页要的到期、主屏名、下一步都带上
        self.assertEqual(sorted(p.name for p in self.gdir.iterdir()), ["Game One v1.2.0.ipa", "请先读我.txt"])
        self.assertEqual((out["appName"], out["ipaPath"], out["gameFolder"]), ("Game One", str(self.gdir / "Game One v1.2.0.ipa"), str(self.gdir)))
        self.assertFalse(out["expiresKnown"]); self.assertAlmostEqual(out["expiresAt"] - time.time(), 7 * 86400, delta=60)   # 免费账号没读到真值：按 7 天估
        self.assertEqual(out["signMode"], "appleId"); self.assertEqual(len(out["nextSteps"]), 1, "直装：只给 Apple ID 那段，不给导入那步")
        self.assertIsNone(self.c.app_installed, "推完资源：失败页不说「App 已装上、资源没推完」")

    def test_explicit_profile_replaces_shell_record(self):
        # 显式描述文件：独立 App 只能用它那一个包名 = 通用壳的包名，装上就顶掉了壳——壳号与各款清掉、apps 里同包名的旧款去掉，结果照实说
        layout.save_device(self.c, "UDID1", dict(shellId="SID2", bundleId="com.acme.one", games={G2: {}}, apps={G3: dict(bundleId="com.acme.one")}))
        self.ph.bid = "com.acme.one"
        with use_devcert(self.c, distribution=True, bundle="com.acme.one", appid=f"{TEAM}.com.acme.one"):
            out = self.run_put()
        rec = layout.load_device(self.c, "UDID1")
        self.assertEqual((sorted(rec["apps"]), rec["shellId"], rec["games"]), ([G1], "", {}))
        self.assertTrue(out["bundleFixed"])
        self.assertIn("app_bundle_fixed", [d["code"] for d in self.c.diagnostics])

    def test_push_fails_after_app_installed(self):
        # 资源推到一半失败：App 已经装上，失败结果要能说「App 已装上，资源没推完」（main.app_installed_result）
        import main
        def boom(g, pack): raise install.Failure("断了", code="device_transfer_failed")
        self.ph.push = boom
        with self.assertRaises(install.Failure):
            self.run_put()
        self.c.operation = "install"
        got = main.app_installed_result(self.c)["appInstalled"]
        self.assertEqual((got["gameId"], got["bundleId"], got["appName"]), (G1, APP1, "Game One"))

    def test_install_routes_by_layout(self):
        import downstream
        seen = []
        with patch.object(downstream, "requested", lambda c, g: None), patch.object(install, "ios_pack", lambda c, g: self.pack), \
                patch.object(install, "phone_for", lambda c: "PH"), patch.object(install, "push_phone", lambda c: "PUSH"), \
                patch.object(install, "put_app", lambda c, g, ph: seen.append(("app", g, ph))), \
                patch.object(install, "push_game", lambda c, g, ph: seen.append(("shell", g, ph))):
            self.c.r = dict(gameId=G1); install._install(self.c)
            install.layout_set(jobcase.fake_context(self.t, r=dict(layout="standalone", gameId=G1)))
            install._install(self.c)
            with patch.object(install, "export_app", lambda c, g: seen.append(("exportApp", g))), patch.object(install, "export_s2arm", lambda c, g: seen.append(("s2arm", g))):
                self.c.r = dict(gameId=G1, mode="export"); install._install(self.c)   # 独立 App 导出：ipa + .s2arm + README 进游戏文件夹
                install.layout_set(jobcase.fake_context(self.t, r=dict(layout="shell", gameId=G1)))
                install._install(self.c)   # 通用壳导出照旧 .s2arm 两件套
        self.assertEqual(seen, [("shell", G1, "PUSH"), ("app", G1, "PH"), ("exportApp", G1), ("s2arm", G1)])


class ShellOwner(unittest.TestCase):
    ROWS = [(SHELL_BID, "S2Arm", TEAM), (APP1, "S2Arm", TEAM), ("com.acme.one", "S2Arm", TEAM)]

    def owner(self, rec):
        with tempfile.TemporaryDirectory() as d:
            c = types.SimpleNamespace(private=d)
            cl = types.SimpleNamespace(apps=lambda: self.ROWS, get=lambda rel, dst: False)
            with patch.object(install, "devpush_client", lambda c, udid, bid, w: cl), patch.object(install, "main_executable", lambda c: "S2Arm"):
                return install.s2arm_owner(c, "UDID1", rec)

    def test_standalone_apps_not_counted(self):
        rec = dict(shellId="S1", bundleId=SHELL_BID)
        self.assertEqual(self.owner(rec), ("choose", None), "显式包名的独立 App 记录里没有：认不出，照旧要选")
        self.assertEqual(self.owner(dict(rec, apps={G1: dict(bundleId=APP1), G2: dict(bundleId="COM.ACME.ONE")})), ("launcher", SHELL_BID),
                         "按设备记录 apps 排除（不分大小写）+ 包名形状排除：只剩通用壳")


class UpdateApps(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)
        self.c.catalog = lambda: {"games": [{"id": G1, "name": "甲"}, {"id": G2, "name": "乙"}, {"id": G3, "name": "丙"}]}
        layout.save_device(self.c, "UDID1", dict(shellId="SID1", bundleId=SHELL_BID, apps={
            G1: dict(bundleId=APP1, shellId="SID1"), G2: dict(bundleId="b2", shellId="SID1"), G3: dict(bundleId="b3", shellId="SID2"),
            "0100000000040000": dict(bundleId="b4", shellId="SID1")}))
        self.ph = types.SimpleNamespace(key="UDID1")

    def run_update(self, failing, stale):
        import ipa as packer
        done = []
        def put(c, gid, ph, steps=True):
            done.append(gid)
            if gid in failing:
                raise Failure("签名没成：账号额度满了", code="free_appid_limit")
        with patch.object(install, "put_app", put), patch.object(packer, "usable_kit", lambda c, g, sid, failed=(): None if g in stale else "/kit"):
            return install.update_apps(self.c, self.ph, "SID2"), done

    def test_each_app_one_failure_does_not_stop(self):
        rows, done = self.run_update(failing={G1}, stale={"0100000000040000"})
        self.assertEqual(done, [G1, G2], "壳号旧的逐款重签；已是本版（丙）不动；新壳认不得的不动")
        self.assertEqual(rows, [dict(gameId=G1, ok=False, code="free_appid_limit", message="签名没成：账号额度满了"),
                                dict(gameId=G2, ok=True),
                                dict(gameId="0100000000040000", ok=False, code="container_stale",
                                     message="「0100000000040000」的独立 App 要按新版重新出包：先给它「打 iPhone 包」，再推到 iPhone。")])
        self.assertEqual([d["code"] for d in self.c.diagnostics], ["free_appid_limit", "container_stale"])

    def test_update_phone_does_shell_then_apps(self):
        import ipa as packer
        done = []
        with patch.object(install, "phone_for", lambda c: self.ph), patch.object(install, "install_shell", lambda c, ph: dict(toShell="SID2", updated=True)), \
                patch.object(install, "put_app", lambda c, g, ph, steps=True: done.append(g)), \
                patch.object(packer, "usable_kit", lambda c, g, sid, failed=(): "/kit"), patch.object(packer, "phone_lock", lambda c: contextlib.nullcontext()), \
                patch("core.preempt_jobs", lambda *a, **k: None):
            out = install.update_phone(self.c)
        self.assertEqual(done, [G1, G2, "0100000000040000"])
        self.assertEqual([r["gameId"] for r in out["apps"]], [G1, G2, "0100000000040000"])


class AppsOnlyPhone(unittest.TestCase):
    """只装了独立 App、没装通用壳的手机（分发证书玩家的常态）：启动器升级后照样出「更新」按钮，更新只重签独立 App、不装通用壳；
    总控台每台手机带 apps 行。期望手写：本版壳号 SID2；甲 SID1（旧）、乙 SID2（新）；甲签名时刻 1000、真实到期 1000 + 10 天"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)
        self.c.catalog = lambda: {"games": [{"id": G1, "name": "甲"}, {"id": G2, "name": "乙"}]}
        self.rec = dict(apps={G1: dict(bundleId=APP1, shellId="SID1", signed=dict(at=1000.0, free=False, expires=1000.0 + 10 * 86400)),
                              G2: dict(bundleId="b2", shellId="SID2", signed=dict(at=2000.0, free=True))})
        layout.save_device(self.c, "UDID1", self.rec)
        self.ph = types.SimpleNamespace(key="UDID1", info=dict(free=False, device="X"))

    def test_update_button_lists_old_apps(self):
        import ipa as packer
        import rewrite_refresh
        with patch.object(packer, "current_shell_id", lambda c: "SID2"), patch.object(rewrite_refresh, "kept_todo", lambda *a: self.fail("没装通用壳不查程序补推")):
            out = install.phone_updates(self.c)
        self.assertEqual(out, [dict(device="UDID1", name="", fromShell="SID1", toShell="SID2", games=[], stale=[], kept=[], apps=[dict(gameId=G1, name="甲")])])
        layout.save_device(self.c, "UDID1", dict(self.rec, apps={G2: self.rec["apps"][G2]}))
        with patch.object(packer, "current_shell_id", lambda c: "SID2"):
            self.assertEqual(install.phone_updates(self.c), [], "独立 App 都是本版：没有按钮")

    def test_update_does_not_install_shell(self):
        import ipa as packer
        done = []
        with patch.object(install, "phone_for", lambda c: self.ph), patch.object(install, "install_shell", lambda c, ph: self.fail("只装了独立 App：不装通用壳")), \
                patch.object(install, "put_app", lambda c, g, ph, steps=True: done.append(g)), patch.object(packer, "current_shell_id", lambda c: "SID2"), \
                patch.object(packer, "usable_kit", lambda c, g, sid, failed=(): "/kit"), patch.object(packer, "phone_lock", lambda c: contextlib.nullcontext()), \
                patch("core.preempt_jobs", lambda *a, **k: None):
            out = install.update_phone(self.c)
        self.assertEqual(done, [G1], "只重签壳号旧的甲")
        self.assertEqual((out["toShell"], out["games"], out["apps"]), ("SID2", [], [dict(gameId=G1, ok=True)]))

    def test_overview_app_rows(self):
        import host_update
        with patch.object(host_update.time, "time", lambda: 1000.0 + 3.5 * 86400):
            rows = host_update._app_rows(self.rec, "SID2")
        self.assertEqual(rows, [
            dict(gameId=G1, bundleId=APP1, shellCurrent=False, signedAt=1000.0, free=False, expiresAtEstimate=1000.0 + 10 * 86400, remainingDays=7, expiresKnown=True),
            dict(gameId=G2, bundleId="b2", shellCurrent=True, signedAt=2000.0, free=True, expiresAtEstimate=606800.0, remainingDays=4, expiresKnown=False)])
        # 甲：到期 865000、此刻 303400 → 6.5 天 → 7；乙：免费按 7 天估 2000 + 604800 = 606800 → 3.51 天 → 4


class ConsoleActionsPerLayout(unittest.TestCase):
    """总控台三处按出法分开（0.6.4）：更新所选里选了独立 App 的款重签它自己的 App、其余推进通用壳；从手机删一款独立 App = 备份存档后卸掉这个 App；
    phoneKeptPull 也收独立 App 里留下的 NRO，没在跑就重签补上（在跑等下一轮）。期望手写：甲 = 独立 App（包名 APP1）、乙 = 通用壳"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)
        self.c.catalog = lambda: {"games": [{"id": G1, "name": "甲"}, {"id": G2, "name": "乙"}]}
        layout.save_device(self.c, "UDID1", dict(shellId="SID2", bundleId=SHELL_BID, games={G2: dict(pack="pb")}, apps={G1: dict(bundleId=APP1, shellId="SID2")}))
        self.c.r = dict(layout="standalone", gameId=G1); install.layout_set(self.c); self.c.r = {}
        self.log = []
        log = self.log
        class Cl:
            def __init__(self, bid): self.bid = bid
            def call(self, *a): log.append(("call", self.bid, a)); return 0, "uninstall 完成"
        class Ph:
            key = udid = "UDID1"
            bid = SHELL_BID
            info = dict(device="d")
            def app_running(self): return self.running.get(self.bid, False)
            def backup(self, g): log.append(("backup", self.bid, g)); return None
            def pull_kept(self, games): log.append(("pull", self.bid, list(games))); return 1
            def client(self, w): return Cl(self.bid)
        self.ph = Ph(); self.ph.running = {}

    def test_push_selected_routes_by_layout(self):
        import ipa as packer
        self.c.r = dict(gameIds=[G1, G2])
        with patch.object(install, "push_phone", lambda c: self.ph), patch.object(install, "phone_for", lambda c: self.ph), \
                patch.object(install, "put_app", lambda c, g, ph, steps=True: self.log.append(("put_app", g))), \
                patch.object(install, "push_game", lambda c, g, ph, steps=True: self.log.append(("push_game", g))), \
                patch.object(packer, "phone_lock", lambda c: contextlib.nullcontext()), patch("core.preempt_jobs", lambda *a, **k: None):
            out = install.push_selected(self.c)
        self.assertEqual(self.log, [("put_app", G1), ("push_game", G2)])
        self.assertEqual(out["done"], 2)

    def test_push_selected_only_standalone_skips_shell_owner(self):
        # 所选全是独立 App：不找通用壳（手机上装着几个 S2Arm、没选用哪个也不挡）——Duo 真机抓到的：原先开头 push_phone 就报「先选用哪一个」
        import ipa as packer
        self.c.r = dict(gameIds=[G1])
        def owner(c): raise Failure("这台 iPhone 上装着不止一个 S2Arm", code="phone_app_choice_required")
        with patch.object(install, "push_phone", owner), patch.object(install, "phone_for", lambda c: self.ph), \
                patch.object(install, "put_app", lambda c, g, ph, steps=True: self.log.append(("put_app", g, ph is self.ph))), \
                patch.object(packer, "phone_lock", lambda c: contextlib.nullcontext()), patch("core.preempt_jobs", lambda *a, **k: None):
            out = install.push_selected(self.c)
        self.assertEqual((self.log, out["done"]), ([("put_app", G1, True)], 1))

    def test_remove_standalone_uninstalls_that_app(self):
        import ipa as packer
        self.c.r = dict(gameId=G1)
        with patch.object(install, "phone_for", lambda c: self.ph), patch.object(install, "phone_bid", lambda ph: SHELL_BID), \
                patch.object(install, "phone_games", lambda c, ph: self.fail("独立 App 不查通用壳里的款")), \
                patch.object(packer, "phone_lock", lambda c: contextlib.nullcontext()), patch("core.preempt_jobs", lambda *a, **k: None):
            out = install.remove_from_phone(self.c)
        self.assertEqual(self.log, [("backup", APP1, G1), ("call", APP1, ("uninstall", "-"))], "按独立 App 的包名备份、卸掉")
        rec = layout.load_device(self.c, "UDID1")
        self.assertEqual((rec["apps"], rec["games"], rec["bundleId"]), ({}, {G2: dict(pack="pb")}, SHELL_BID), "通用壳与乙不碰")
        self.assertEqual((out["removed"], out["bundleId"], out["standalone"]), (G1, APP1, True))
        self.ph.running = {APP1: True}
        layout.save_device(self.c, "UDID1", dict(rec, apps={G1: dict(bundleId=APP1)}))
        with patch.object(install, "phone_for", lambda c: self.ph), patch.object(install, "phone_bid", lambda ph: SHELL_BID), \
                patch.object(packer, "phone_lock", lambda c: contextlib.nullcontext()), patch("core.preempt_jobs", lambda *a, **k: None):
            with self.assertRaises(Failure) as e:
                install.remove_from_phone(self.c)
        self.assertEqual(e.exception.code, "phone_app_running")

    def test_kept_pull_covers_apps(self):
        import ipa as packer
        import rewrite_refresh
        with patch.object(rewrite_refresh, "kept_todo", lambda c, g, kit: g == G1), patch.object(layout, "ios_kit", lambda c, g: "/kit"), \
                patch.object(install, "pull_shader_counts", lambda *a: None), patch.object(packer, "current_shell_id", lambda c: "SID2"), \
                patch.object(install, "put_app", lambda c, g, ph, steps=True: self.log.append(("put_app", g))), \
                patch.object(self.c, "idle", lambda k: contextlib.nullcontext(True), create=True):
            out = install._kept_pull_on(self.c, self.ph)
            self.assertEqual(self.log[:2], [("pull", SHELL_BID, [G2]), ("pull", APP1, [G1])], "通用壳与独立 App 各按自己的包名收")
            self.assertEqual((out["new"], out["pushed"], out["kept"]), (2, [G1], []), "独立 App 没在跑：重签补上")
            self.log.clear(); self.ph.running = {APP1: True}
            out = install._kept_pull_on(self.c, self.ph)
        self.assertEqual((out["pushed"], out["kept"]), ([], [G1]), "在跑：等下一轮")
        self.assertNotIn(("put_app", G1), self.log)


class SavesPerApp(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = ctx(self.t)
        self.puts = []
        n = [0]
        test = self
        class Ph:
            key, bid, saves = "UDID1", SHELL_BID, {"a.dat": b"same"}
            def backup(self, g):
                n[0] += 1
                dest = layout.path(test.c, g, "save_backup", f"2026112{n[0]:02d}")
                dest.mkdir(parents=True, exist_ok=True)
                for rel, data in self.saves.items():
                    (dest / rel).write_bytes(data)
                return dest
            def app_running(self): return False
            def client(self, w):
                return types.SimpleNamespace(put=lambda src, rel: test.puts.append((self.bid, rel)), rm=lambda rel: (True, ""))
        self.ph = Ph()

    def test_shell_and_app_kept_apart_and_restore_goes_back(self):
        with patch.object(install, "trace", lambda *a, **k: None):
            shell = install.snapshot_phone_saves(self.c, self.ph, [G1])[G1]
            app = install.snapshot_phone_saves(self.c, install.app_phone(self.ph, APP1), [G1])[G1]
            self.assertNotEqual(shell, app, "同内容：独立 App 与通用壳各留一份，不按对方去重")
            self.assertEqual(install.snapshot_phone_saves(self.c, install.app_phone(self.ph, APP1), [G1])[G1], app, "同一个 App 同内容：不新建")
            self.c.catalog = lambda: {"games": [{"id": G1, "name": "甲"}]}
            rows = {r["id"]: (r["bundleId"], r["standalone"]) for r in install.phone_saves(self.c)["games"][0]["backups"]}
            self.assertEqual(rows, {shell: (SHELL_BID, False), app: (APP1, True)})
            self.c.r = dict(gameId=G1, backup=app)
            with patch.object(install, "phone_for", lambda c: self.ph):
                install.restore_phone_save(self.c)
        self.assertEqual({b for b, _ in self.puts}, {APP1}, "独立 App 的备份还原回独立 App，不写进通用壳")


class WindowsInstall(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = jobcase.fake_context(self.t, r={"device": "U1"}, library=self.t / "lib", private=self.t, logs=self.t / "logs", engine=self.t)
        (self.t / "lib").mkdir(); (self.t / "logs").mkdir()
        self.ipa = self.t / "S2Arm.ipa"
        with zipfile.ZipFile(self.ipa, "w") as z:
            z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "t", "CFBundleExecutable": "S2Arm"}))

    def phone(self):
        from test_win_jobs import FakeW
        w = FakeW([("U1", "USB", 3)], bid=APP1)
        w.team = TEAM
        w.install_signed = lambda exe, app, udid, log: None
        return w

    def test_apple_id_bid_not_recorded(self):
        from jobcase import as_windows
        w = self.phone()
        layout.save_device(self.c, "U1", dict(bundleId=SHELL_BID))
        with patch.object(install, "win_install_mod", return_value=w), as_windows(install):
            ph = install.WinPhone(self.c)
            self.assertEqual(ph.install(self.ipa, [], steps=False, bid=APP1), APP1)
        self.assertEqual((w.calls[0].bundle, ph.bid, layout.load_device(self.c, "U1")["bundleId"]), (APP1, SHELL_BID, SHELL_BID))

    def test_devcert_signs_with_bid(self):
        from jobcase import as_windows
        w = self.phone()
        signed = []
        def sign(c, app, log, bid=None):
            signed.append(bid); return bid or SHELL_BID, {}
        with use_devcert(self.c, distribution=True), patch.object(install, "win_install_mod", return_value=w), as_windows(install), \
                patch.object(devcert, "sign_app", sign):
            ph = install.WinPhone(self.c)
            self.assertEqual(ph.install(self.ipa, [], steps=False, bid=APP1), APP1)
        self.assertEqual((signed, ph.bid), ([APP1], SHELL_BID))
        self.assertTrue(devcert.signed_app_ipa(self.c, APP1).is_file(), "按包名另存在私有目录（之后挪进这款的游戏文件夹），不盖通用壳那份")
        self.assertFalse((self.t / "lib" / f"S2Arm.{APP1}.signed.ipa").exists(), "游戏库根不留独立 App 的 ipa")
        self.assertFalse((self.t / "lib/S2Arm.signed.ipa").exists())
        self.assertEqual(layout.load_device(self.c, "U1")["bundleId"], "", "设备记录的包名没写")


if __name__ == "__main__":
    unittest.main()
