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
        for result in ("updated", "unavailable"):
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
