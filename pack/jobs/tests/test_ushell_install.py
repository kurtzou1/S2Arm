"""通用壳装机的两个作业（pack/jobs/install.py push_game / install_shell；0.6.0 起是唯一的装机方式）。
期望值按维护者 11-17 定的规则手写，不靠被测代码算：
  ② 「装到 iPhone」只走 push_game、「更新 S2Arm」只走 install_shell
  ③ push_game：手机上没装壳记录 → shell_install_required；壳号不是本版 → shell_update_required；都不推、不装
  ④ push_game 正常：推这一款的程序包（push_programs 收到这一款与这台的团队 / 包名）与资源包，绝不调 ph.install；设备记录这款带 program 与 pack
  ⑤ install_shell：组只有壳的容器、ph.install 收到空游戏表，绝不推程序包 / 资源包；记壳号；手机上已是同一个也照样签名安装（续签要的就是重签）
"""
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

from jobcase import JobCase
import install
import ipa as packer
import layout
import program_pack

GID = "0100000000010000"


class FakePhone:
    def __init__(self):
        self.key, self.bid, self.udid = "UDID1", "io.s2arm.games.t1", "UDID1"
        self.team = dict(id="TEAM1", name="T", free=True)
        self.info = dict(device="iPhone", deviceName="iPhone", deviceKind="iPhone", team="T", free=True)
        self.pending, self.calls = None, []
    def install(self, ipa, games, steps=True): self.calls.append(("install", list(games)))
    def push(self, g, pack): self.calls.append(("push", g)); return 3, 30
    def before_push(self, packs): pass
    def pull_kept(self, games): return 0
    def app_running(self): return False
    def client(self, work): return SimpleNamespace()
    def backup(self, g): return None   # 装壳 / 推前先拉存档（snapshot_phone_saves）：本替身手机上没存档


class RouteTests(JobCase):
    def setUp(self):
        super().setUp()
        self.ph = FakePhone()
        self.c.r = dict(self.c.r, gameId=GID)
        self.hits = []
        for name in ("push_game",):
            p = mock.patch.object(install, name, lambda c, gid, ph, *a, n=name, **k: self.hits.append(n) or {})
            p.start(); self.addCleanup(p.stop)
        for p in (mock.patch.object(install, "phone_for", lambda c: self.ph), mock.patch.object(install, "push_phone", lambda c: self.ph), mock.patch.object(install, "ios_pack", lambda c, g: Path("/p")),
                  mock.patch.object(install, "wants_export", lambda c: False)):
            p.start(); self.addCleanup(p.stop)

    def test_install_uses_push_game(self):
        install._install(self.c)
        self.assertEqual(self.hits, ["push_game"])

    def test_update_uses_install_shell_only(self):
        # 「更新 S2Arm」只装壳、不推各款；之后只重签壳号旧了的独立 App（update_apps，各款资源不动）
        with mock.patch.object(install, "install_shell", lambda c, ph: self.hits.append("install_shell") or dict(updated=True, toShell="S1")), \
             mock.patch.object(install, "update_apps", lambda c, ph, sid: self.hits.append("update_apps:" + sid) or []):
            install._update_phone(self.c)
        self.assertEqual(self.hits, ["install_shell", "update_apps:S1"])

class PushGameTests(JobCase):
    def setUp(self):
        super().setUp()
        self.ph = FakePhone()
        self.pushed = []
        prog = dict(sha="s1", team="TEAM1", host_abi=1, rewriter_id="rw", dir="v-s1-pc")
        for p in (mock.patch.object(install, "ios_pack", lambda c, g: Path("/pack")), mock.patch.object(install, "pack_id", lambda pack: "P2"),
                  mock.patch.object(packer, "current_shell_id", lambda c: "S1"), mock.patch.object(install, "pick_pack_root", lambda c, ph, g: "Library/x/资源包"),
                  mock.patch.object(install, "phone_signing", lambda c, ph: ("TEAM1", ph.bid, "signer")),
                  mock.patch("rewrite_refresh.refresh_ios", lambda c, gs: None), mock.patch.object(packer, "program_locks", lambda c, gs: mock.MagicMock()),
                  mock.patch.object(install, "push_mods", lambda c, ph, g, had: {}),
                  mock.patch.object(install, "push_programs", lambda c, cl, games, rec, team, bundle, signer, docs="Documents":
                                    self.pushed.append((list(games), team, bundle)) or {g: prog for g in games})):
            p.start(); self.addCleanup(p.stop)
        self.prog = prog

    def test_requires_shell(self):
        with self.assertRaises(install.Failure) as e:
            install.push_game(self.c, GID, self.ph, steps=False)
        self.assertEqual(e.exception.code, "shell_install_required")
        layout.save_device(self.c, self.ph.key, dict(shellId="S0", games={}))
        with self.assertRaises(install.Failure) as e:
            install.push_game(self.c, GID, self.ph, steps=False)
        self.assertEqual(e.exception.code, "shell_update_required")
        self.assertEqual((self.ph.calls, self.pushed), ([], []), "不推、不装")

    def test_external_older_app(self):
        """#1842：别的电脑 / 别的工具装的 S2Arm（push_phone 判 external，原先不核任何版本）比启动器旧。不堵门（维护者：物理上做得下去的不拦）：
          ① 接口兼容只是旧 → phone_app_outdated、不推；玩家确认（acceptOldApp）后照推、决定记进日志；
          ② 早于接口起始版（COMPAT_SINCE，读不了这一版的程序包）→ phone_app_incompatible，确认了也不推；
          ③ 同版 / 更新、读不到版本、开发树没有版本 → 不提示照推。
        做法按包名分两种（期望手写）：启动器那种包名 → 这台电脑点「更新 S2Arm」；改过包名的 → 用原工具重装 ipa"""
        import cheats
        import host_update
        self.ph.external = True
        layout.save_device(self.c, self.ph.key, dict(games={}))
        def run(have, bid, accept=False, since="0.1.0"):
            self.ph.app_version, self.ph.bid, self.pushed[:] = have, bid, []
            self.c.r = dict(self.c.r, acceptOldApp=accept)
            with mock.patch.object(cheats, "app_version", lambda c: "0.6.7"), mock.patch.object(host_update, "COMPAT_SINCE", since), \
                    mock.patch.object(install, "push_pack", lambda *a, **k: None, create=True), mock.patch.object(install, "put_game", lambda *a, **k: None, create=True):
                try:
                    install.push_game(self.c, GID, self.ph, steps=False)
                    return None, ""
                except install.Failure as e:
                    return e.code, str(e)
        # D-8MVS：包名带 io.s2arm.games 前缀的（AltStore / SideStore 装的也保留这个前缀）同样指向总控台上真有的「导出 S2Arm.ipa」，不再叫玩家点不存在的「更新 S2Arm」
        for have, bid in [("0.6.2", "io.s2arm.games.qb6bcfamys"), ("0.6.4", "com.kdt.livecontainer.ABC")]:
            code, msg = run(have, bid)
            self.assertEqual(code, "phone_app_outdated", have); self.assertIn("重新装一次", msg); self.assertIn("S2Arm.ipa", msg); self.assertNotIn("更新 S2Arm", msg)
            self.assertIn(have, msg); self.assertIn("0.6.7", msg)
            self.assertEqual(self.pushed, [], f"{have} 没确认不推")
            code, msg = run(have, bid, accept=True)
            self.assertNotIn(code, ("phone_app_outdated", "phone_app_incompatible"), f"{have} 确认后照推：{msg}")
            self.assertEqual([g for g, *_ in self.pushed], [[GID]], f"{have} 确认后推了这一款")
        code, msg = run("0.6.2", "io.s2arm.games.qb6bcfamys", accept=True, since="0.6.5")
        self.assertEqual(code, "phone_app_incompatible", "早于接口起始版：确认了也拦"); self.assertIn("读不了", msg); self.assertNotIn("更新 S2Arm", msg)
        self.assertEqual(self.pushed, [], "不兼容不推")
        for have in ("0.6.7", "0.6.8", None):
            self.ph.app_version = have
            with mock.patch.object(cheats, "app_version", lambda c: "0.6.7"):
                self.assertIsNone(install.external_app_outdated(self.c, self.ph), f"{have} 不提示")
        with mock.patch.object(cheats, "app_version", lambda c: ""):
            self.ph.app_version = "0.1"
            self.assertIsNone(install.external_app_outdated(self.c, self.ph), "开发树没有版本：比不了，不提示")

    def test_app_version_from_listing(self):
        """push_phone 取 external App 版本：读本次判归属时列过的那份（installed_s2arm_on 记在作业上），不为取版本再调一次设备；
        本次没列过 → None（照旧推）。期望手写：列表第四列 0.6.2 → 0.6.2；旧工具三列 → None；换一台没列过的 → None"""
        rows = [("io.s2arm.games.qb6bcfamys", "S2Arm", "QB6", "0.6.2"), ("com.kdt.livecontainer.ABC", "LiveContainer", "", "")]
        with mock.patch.object(install, "devpush_client", lambda c, u, b, w: SimpleNamespace(apps=lambda: rows)), \
                mock.patch.object(install, "main_executable", lambda c: "S2Arm"):
            apps = install.installed_s2arm_on(self.c, "U1", {})
        self.assertEqual([a["version"] for a in apps], ["0.6.2"], "LiveContainer 主程序名不是 S2Arm、包名也不是前缀：不算")
        self.assertEqual(install.app_version_on(self.c, "U1", "IO.S2ARM.GAMES.QB6BCFAMYS"), "0.6.2", "包名不分大小写")
        self.assertIsNone(install.app_version_on(self.c, "U2", "io.s2arm.games.qb6bcfamys"), "这台本次没列过")
        rows[0] = ("io.s2arm.games.qb6bcfamys", "S2Arm", "QB6")
        with mock.patch.object(install, "devpush_client", lambda c, u, b, w: SimpleNamespace(apps=lambda: rows)), \
                mock.patch.object(install, "main_executable", lambda c: "S2Arm"):
            install.installed_s2arm_on(self.c, "U1", {})
        self.assertIsNone(install.app_version_on(self.c, "U1", "io.s2arm.games.qb6bcfamys"), "旧工具三列：没有版本")

    def test_compat_since_follows_interface(self):
        """接口起始版跟着接口走：HOST_ABI / 直连链号还是 v0.1.0 那一对时 COMPAT_SINCE = 0.1.0；谁改了接口号没改它，这里红"""
        import host_update
        known = {(1, host_update.LEGACY_CHAIN): "0.1.0"}
        now = host_update.engine_compat(SimpleNamespace(engine=Path(install.__file__).resolve().parents[2]))
        key = (now["hostAbi"], now["dmshChain"])
        self.assertIn(key, known, f"接口变成 {key}：把 host_update.COMPAT_SINCE 改成第一个带这套接口的版本号，并在这里登记")
        self.assertEqual(host_update.COMPAT_SINCE, known[key])

    def test_update_game_stays_on_computer(self):
        """作业 updateGame（11-21 维护者定：游戏页只有「更新」「导出」）：只在电脑上重编 / 刷新，不碰设备、不签名、不推；
        做完回这款还剩的原因（host_update.game_reasons）。期望手写：调用顺序 = 刷新本地 → Mac 着色器库，手机对象一次都没碰"""
        import host_update
        seen = []
        self.c.r = dict(self.c.r, gameId=GID.lower())
        with mock.patch.object(install, "refresh_local", lambda c, g: seen.append(("local", g))), \
                mock.patch.object(install, "update_mac_lib", lambda c, g: seen.append(("mac", g))), \
                mock.patch.object(install, "push_phone", lambda c: self.fail("更新不该找设备")), \
                mock.patch.object(install, "phone_for", lambda c: self.fail("更新不该找设备")), \
                mock.patch.object(install, "phone_signing", lambda c, ph: self.fail("更新不该签名")), \
                mock.patch.object(host_update, "game_reasons", lambda c, g: ["shaderMiss"] if g == GID else ["x"]):
            r = install.update_game(self.c)
        self.assertEqual(seen, [("local", GID), ("mac", GID)])
        self.assertEqual(r, dict(gameId=GID, reasons=["shaderMiss"]))
        self.assertEqual(self.ph.calls, [])

    def test_update_game_needs_iphone_version(self):
        """从没做过 iPhone 版的款：updateGame 照 ios_pack 报（前端本来不给它更新按钮），不做任何重活"""
        self.c.r = dict(self.c.r, gameId="0100000000099000")
        def none(c, g):
            raise install.Failure("这款游戏还没出 iPhone 包", code="job_failed")
        with mock.patch.object(install, "ios_pack", none), mock.patch.object(install, "refresh_local", lambda c, g: self.fail("没做过 iPhone 版不该重编")):
            with self.assertRaises(install.Failure):
                install.update_game(self.c)

    def test_update_incomplete_is_said_not_silent(self):
        """11-21：「更新这款」做不齐时照实给黄字（update_incomplete），不静默。#1961：着色器库重编不了分三种说——没装工具 / 原料不在但原件在
        （facts.action = repack，前端接着从原件整款重出）/ 原件也不在（relinkSource，前端画「重新添加原件…」）；宿主约定号变了要整款重出，
        原件在 → repack、不在 → relinkSource；约定号变了又没原料时只给一条要重出的（重出一次两样都解决）。期望手写"""
        import sgrade_bf, host_update
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=self.ph.bid, games={GID: dict(pack="P1")}))
        for label, rechain, have, abi, want, action in (
                ("没装工具", "no_tools", True, host_update.HOST_ABI, [install.UPDATE_SHADER_NO_TOOLS], None),
                ("没原料·原件在", "no_source", True, host_update.HOST_ABI, [install.UPDATE_NEEDS_REPACK_SOURCE], "repack"),
                ("没原料·原件也不在", "no_source", False, host_update.HOST_ABI, [install.UPDATE_NEEDS_SOURCE], "relinkSource"),
                ("约定号变了", "skip", True, host_update.HOST_ABI + 1, [install.UPDATE_NEEDS_REPACK], "repack"),
                ("约定号变了·原件不在", "skip", False, host_update.HOST_ABI + 1, [install.UPDATE_NEEDS_REPACK_NO_SOURCE], "relinkSource"),
                ("约定号变了·又没原料", "no_source", True, host_update.HOST_ABI + 1, [install.UPDATE_NEEDS_REPACK], "repack"),
                ("都齐", "updated", True, host_update.HOST_ABI, [], None)):
            with self.subTest(label), mock.patch.object(sgrade_bf, "rechain_ios", lambda c, g, r=rechain: r), \
                    mock.patch.object(install, "sources_present", lambda c, g, h=have: h), \
                    mock.patch.object(layout, "program_info", lambda c, g, a=abi: dict(hostAbi=a)), \
                    mock.patch.object(install, "update_mac_lib", lambda c, g: False):
                self.c.job["diagnostics"] = []
                install.push_game(self.c, GID, self.ph, steps=False)
                got = [d for d in self.c.job["diagnostics"] if d.get("code") == "update_incomplete"]
                self.assertEqual([d.get("message") or d.get("summary") for d in got], want)
                self.assertEqual([(d.get("facts") or {}).get("action") for d in got], [action] if want else [])

    def test_pushes_this_game_only_never_installs(self):
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=self.ph.bid, games={"0100000000020000": dict(pack="Q")}))
        r = install.push_game(self.c, GID.lower(), self.ph, steps=False)
        self.assertEqual(self.pushed, [([GID], "TEAM1", "io.s2arm.games.t1")])
        self.assertEqual(self.ph.calls, [("push", GID)])
        rec = layout.load_device(self.c, self.ph.key)
        self.assertEqual(rec["games"][GID], dict(program=self.prog, pack="P2"))
        self.assertEqual(rec["games"]["0100000000020000"], dict(pack="Q"), "别的款记录不动")
        self.assertEqual(r["games"], [GID])
        self.assertEqual(r["unpackPending"], "已送到手机，打开 S2Arm 时自动装好。", "推了程序包、App 没开：不说已装好")


    def test_pushes_even_when_record_says_same_pack(self):
        # 11-18 真机：记录里这款资源包号已是 P2（推过），手机上的 game.img 却不在（删 App 重装 / 手机上删过）→ 原先按记录跳过、推 0 个文件、起局卡「资源包不完整」。
        #   期望：照样交 push_pack（它按 sha256 核手机实况，只推缺的），记录仍是 P2
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=self.ph.bid, games={GID: dict(program=self.prog, pack="P2")}))
        r = install.push_game(self.c, GID, self.ph, steps=False)
        self.assertEqual(self.ph.calls, [("push", GID)])
        self.assertEqual(layout.load_device(self.c, self.ph.key)["games"][GID]["pack"], "P2")
        self.assertNotIn("unpackPending", r, "程序包没变、没推：不等导入")

    def test_shader_chain_rebuilt_on_push_before_programs(self):
        # 11-17 维护者定：着色器链变了在玩家推这一款时只重编着色器库（sgrade_bf.rechain_ios），在改写核对与推程序之前；没原料不挡推送
        import sgrade_bf
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=self.ph.bid, games={}))
        for result in ("updated", "no_source"):
            order = []
            with mock.patch.object(sgrade_bf, "rechain_ios", lambda c, g, r=result: order.append(("rechain", g)) or r), \
                    mock.patch("rewrite_refresh.refresh_ios", lambda c, gs: order.append(("refresh", list(gs)))), \
                    mock.patch.object(install, "push_programs", lambda *a, **k: order.append(("programs",)) or {GID: self.prog}):
                r = install.push_game(self.c, GID, self.ph, steps=False)
            self.assertEqual(order, [("rechain", GID), ("refresh", [GID]), ("programs",)], result)
            self.assertEqual(r["games"], [GID])

class InstallShellTests(JobCase):
    def setUp(self):
        super().setUp()
        self.ph = FakePhone()
        self.ipa = self.root / "S2Arm.ipa"; self.ipa.write_bytes(b"ipa")
        for p in (mock.patch.object(packer, "assemble_shell", lambda c: (self.ipa, [], "S2")), mock.patch.object(packer, "commit_phone_ipa", lambda c, ipa, sid: None),
                  mock.patch.object(install, "push_programs", lambda *a, **k: self.fail("装壳不推程序包"))):
            p.start(); self.addCleanup(p.stop)

    def test_certificate_decision_precedes_save_backup(self):
        ph = mock.Mock(spec=install.PlumeMacPhone)
        ph.W = mock.Mock()
        ph.key = "PHONE"
        layout.save_device(self.c, ph.key, dict(games={GID: {}}))
        with mock.patch.object(install, "win_cert_gate", side_effect=install.Failure("confirm", code="cert_revoke_confirm")), \
                mock.patch.object(install, "snapshot_phone_saves") as backup, self.assertRaises(install.Failure) as failed:
            install.install_shell(self.c, ph)
        self.assertEqual(failed.exception.code, "cert_revoke_confirm")
        backup.assert_not_called()
        ph.install.assert_not_called()

    def test_installs_shell_only(self):
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", games={GID: dict(pack="P", program=dict(sha="s"))}))
        r = install.install_shell(self.c, self.ph, steps=False)
        self.assertEqual(self.ph.calls, [("install", [])])
        rec = layout.load_device(self.c, self.ph.key)
        self.assertEqual(rec["shellId"], "S2"); self.assertEqual(rec["games"][GID], dict(pack="P", program=dict(sha="s")), "各款记录原样")
        self.assertTrue(r["updated"])

    def test_other_app_forgets_games(self):
        # 换了团队装上的是另一个 App（包名变了）：原来那个 App 里的程序包、资源包、交过的证书这个 App 里都没有 → 各款按没推过算；包名没变照旧留着
        for old_bid, kept in (("io.example.other", False), (self.ph.bid, True)):
            layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=old_bid, games={GID: dict(pack="P", program=dict(sha="s"))},
                                                         identity=dict(cert_sha1="x"), usage=dict(at=1)))
            install.install_shell(self.c, self.ph, steps=False)
            rec = layout.load_device(self.c, self.ph.key)
            self.assertEqual((GID in (rec.get("games") or {}), "identity" in rec, "usage" in rec), (kept, kept, kept), old_bid)
            self.assertEqual(rec["bundleId"], self.ph.bid)

    def test_same_app_still_resigns(self):
        # 期望手写：手机上已是这一版壳、刚签过（同一个 App）照样签名安装——玩家点「续签 S2Arm」要的就是重签（补回丢了的权限也靠它）
        layout.save_device(self.c, self.ph.key, dict(shellId="S2", bundleId=self.ph.bid, signed=dict(at=__import__("time").time(), free=False)))
        r = install.install_shell(self.c, self.ph, steps=False)
        self.assertEqual((self.ph.calls, r["updated"]), ([("install", [])], True))

    def test_legacy_games_listed_after_install(self):
        # 期望手写：装完 App 后，这台记录里「资源推过、没有程序包」的老款（0.5.x 整包装的）列进结果——游戏库里有这款 iPhone 包的进 legacy（这台电脑能更新），
        #   没有的进 legacyElsewhere（要回装它的电脑更新）；程序包已推过的、资源没推过的都不列
        G2, G3, G4 = "0100000000020000", "0100000000030000", "0100000000040000"
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=self.ph.bid, games={
            GID: dict(pack="P"), G2: dict(pack="P"), G3: dict(pack="P", program=dict(sha="s")), G4: dict(program=dict(sha="s"))}))
        here = {GID}
        cat = {"games": [dict(id=GID, name="甲"), dict(id=G3, name="丙")]}
        with mock.patch.object(self.c, "catalog", lambda: cat, create=True), \
                mock.patch.object(layout, "has_ios_kit", lambda c, g: g in here), mock.patch.object(layout, "ios_pack", lambda c, g: self.root / "pk" / g):
            (self.root / "pk" / GID).mkdir(parents=True); (self.root / "pk" / GID / "manifest.json").write_text("{}")
            r = install.install_shell(self.c, self.ph, steps=False)
        self.assertEqual(r["legacy"], [dict(gameId=GID, name="甲")])
        self.assertEqual(r["legacyDevice"], self.ph.key, "「更新这 N 款」推到刚装好 App 的这台")
        self.assertEqual(r["legacyElsewhere"], [dict(gameId=G2, name=G2)])

    def test_no_legacy_keys_when_none(self):
        layout.save_device(self.c, self.ph.key, dict(shellId="S1", bundleId=self.ph.bid, games={GID: dict(pack="P", program=dict(sha="s"))}))
        r = install.install_shell(self.c, self.ph, steps=False)
        self.assertNotIn("legacy", r); self.assertNotIn("legacyElsewhere", r)


if __name__ == "__main__":
    unittest.main()


class PushSignChoice(JobCase):
    """11-21 导出确认页「这次用什么签」：推到设备也认请求 sign（appleId / devCert），只管这一次、不改设置。期望手写"""

    def run_sign(self, sign, active):
        import devcert, program_pack
        self.c.r = dict(self.c.r, **({"sign": sign} if sign else {}))
        with mock.patch.object(devcert, "active", lambda c: active), mock.patch.object(devcert, "distribution", lambda c: False), \
                mock.patch.object(devcert, "team", lambda c: dict(id="CERTTEAM")), mock.patch.object(devcert, "state", lambda c: dict(bundleId="cert.bid")), \
                mock.patch.object(program_pack, "devcert_signer", lambda c: "cert-signer"), mock.patch.object(install.os, "name", "posix"):
            try:
                return install.phone_signing(self.c, object())
            except AssertionError:
                return "appleId"   # 走到 Apple ID 那条（posix + 不是 PlumeMacPhone 的替身在这里止住）

    def test_request_sign_overrides_setting(self):
        cert = ("CERTTEAM", "cert.bid", "cert-signer")
        self.assertEqual(self.run_sign(None, True), cert, "没带：按设置（在用证书）")
        self.assertEqual(self.run_sign(None, False), "appleId", "没带：按设置（Apple ID）")
        self.assertEqual(self.run_sign("appleId", True), "appleId", "这次选 Apple ID：设置里在用证书也按 Apple ID 签")
        self.assertEqual(self.run_sign("devCert", False), cert, "这次选证书：设置里没在用也按证书签")
