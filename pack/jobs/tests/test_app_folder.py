"""独立 App 的电脑产物（pack/jobs/app_folder.py、install.export_app）：文件名、只留一份 ipa、README 只留一份且中文版带英文摘要、成功页下一步按签名方式给"""
import contextlib
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app_folder  # noqa: E402
import install  # noqa: E402
import jobcase  # noqa: E402

G1 = "0100000000010000"


class Names(unittest.TestCase):
    def test_ipa_name(self):
        self.assertEqual(app_folder.ipa_name("Game: One", G1, "1.2.0"), "Game  One v1.2.0.ipa")
        self.assertEqual(app_folder.ipa_name("", G1, ""), G1 + ".ipa")

    def test_place_keeps_one_per_game(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); src = d.parent / f"{d.name}.src.ipa"; src.write_bytes(b"new"); self.addCleanup(src.unlink, True)
            for n in ("Game One v1.0.0.ipa", "Game One.ipa", "Game One Two v1.0.0.ipa", "Other v1.ipa"):
                (d / n).write_bytes(b"old")
            out = app_folder.place_ipa(src, d, "Game One", G1, "1.2.0")
            self.assertEqual(out.name, "Game One v1.2.0.ipa"); self.assertEqual(out.read_bytes(), b"new")
            self.assertEqual(sorted(p.name for p in d.glob("*.ipa")), ["Game One Two v1.0.0.ipa", "Game One v1.2.0.ipa", "Other v1.ipa"],
                             "只删这款的旧版本，别的游戏、名字只是前缀相同的不动")
            self.assertFalse(list(d.glob(".*partial")), "不留临时文件")


class Readme(unittest.TestCase):
    def test_one_readme_per_folder(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            app_folder.write_readme(d, "zh", app="Game One", ipa="Game One v1.ipa", gid=G1, s2arm="Game One.s2arm")
            app_folder.write_readme(d, "en", app="Game One", ipa="Game One v1.ipa", gid=G1, s2arm="Game One.s2arm")
            self.assertEqual([p.name for p in d.iterdir()], ["README.txt"], "切了界面语言再出：只留一份")
            app_folder.write_readme(d, "zh", app="Game One", ipa="Game One v1.ipa", gid=G1, s2arm="Game One.s2arm")
            self.assertEqual([p.name for p in d.iterdir()], ["请先读我.txt"])

    def test_zh_sections_and_english_summary(self):
        t = app_folder.readme_text("zh", app="Game One", ipa="Game One v1.ipa", gid=G1, s2arm="Game One.s2arm", img="Game One.img")
        for head in ("【这是什么】", "【怎么装】", "【到期与续签】", "【存档在哪】", "【怎么整体删除】", "—— English summary ——"):
            self.assertIn(head, t)
        self.assertIn("Game One.s2arm 和 Game One.img", t, "导入那步点名两个文件")
        self.assertIn(f".programs/{G1}", t, "点名不在文件夹里的程序备份")
        self.assertIn("用启动器删除最干净", t)
        self.assertNotIn("访达", t, "访达直装没核实，不写")
        self.assertEqual(t.split("—— English summary ——")[1].strip().count("\n") + 1, 4, "英文摘要 4 行")

    def test_five_languages(self):
        # 五语（0.6.4）：文件名只分中文 / 英文；正文按界面语言；非英文末尾附英文摘要；繁中界面用中文那份
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            for ui, name, head in (("zh-Hant", "请先读我.txt", "【这是什么】"), ("ja", "README.txt", "【これは何か】"), ("es-ES", "README.txt", "QUÉ ES ESTO"),
                                   ("fr", "README.txt", "DE QUOI S’AGIT-IL"), ("en", "README.txt", "WHAT THIS IS"), ("de", "README.txt", "WHAT THIS IS")):
                out = app_folder.write_readme(d, app_folder.lang_of(ui), app="G", ipa="G v1.ipa", gid=G1, s2arm="G.s2arm")
                t = out.read_text(encoding="utf-8")
                self.assertEqual(out.name, name, ui); self.assertIn(head, t, ui)
                self.assertEqual("—— English summary ——" in t, app_folder.lang_of(ui) != "en", ui)
                self.assertEqual([p.name for p in d.iterdir()], [name], "只留一份")
        self.assertIn("Import Here", app_folder.next_steps("ja", "external", app="G", ipa="G.ipa", s2arm="G.s2arm", exported=True)[1])

    def test_img_elsewhere(self):
        t = app_folder.readme_text("en", app="G", ipa="G.ipa", gid=G1, img_elsewhere="/lib/x/game.img")
        self.assertIn("It is at: /lib/x/game.img", t)


class NextSteps(unittest.TestCase):
    def test_by_sign_mode(self):
        kw = dict(app="G", ipa="G v1.ipa", s2arm="G.s2arm")
        self.assertEqual(len(app_folder.next_steps("zh", "appleId", **kw)), 1)
        got = app_folder.next_steps("zh", "appleId", exported=True, **kw)
        self.assertEqual(len(got), 3); self.assertTrue(got[0].startswith("AltStore"), "导出的 Apple ID 包是未签名的：先给 AltStore / SideStore")
        self.assertIn("放这里导入", got[2])
        got = app_folder.next_steps("en", "devCert", exported=True, **kw)
        self.assertTrue(got[0].startswith("Developer")); self.assertIn("G.s2arm", got[1])


class ExportApp(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = jobcase.fake_context(self.t, r=dict(gameId=G1, mode="export", uiLanguage="en"))
        self.gdir = self.t / "games" / "Game One"; self.gdir.mkdir(parents=True)
        Path(self.c.library).mkdir(parents=True, exist_ok=True)

    def run_export(self, mode="appleId"):
        import ipa as packer
        import rewrite_refresh
        import sgrade_bf
        def assemble(c, g, dest=None, **k):
            p = Path(dest) / "S2Arm.ipa"
            with zipfile.ZipFile(p, "w") as z:
                z.writestr("Payload/S2Arm.app/S2Arm", b"x")
            return p, [g], "SID"
        def s2arm(c, g, *, folder=None, sign=True, step=0, total=3):
            self.s2arm_args = (folder, sign)
            out = Path(folder) / "Game One.s2arm"; out.write_bytes(b"s")
            img = Path(folder) / "Game One.img"; img.write_bytes(b"i")
            return dict(gameId=g, s2armPath=str(out), resourcePath=str(img), resourceLinked=True, exported=True, signedWith=dict(mode="none"))
        with patch.object(install, "ios_pack", lambda c, g: self.t), patch.object(packer, "assemble", assemble), \
                patch.object(packer, "program_locks", lambda c, g: contextlib.nullcontext()), patch.object(rewrite_refresh, "refresh_ios", lambda c, g: None), \
                patch.object(sgrade_bf, "rechain_ios", lambda c, g: "skip"), patch.object(install, "export_s2arm", s2arm), \
                patch.object(install, "export_sign_mode", lambda c: mode), patch.object(install, "app_meta", lambda c, g: (self.gdir, "Game One", "1.2.0")):
            return install.export_app(self.c, G1)

    def test_unsigned_export_lands_in_game_folder(self):
        out = self.run_export()
        self.assertEqual(self.s2arm_args, (self.gdir, False), "游戏包写进这款的文件夹、程序不签")
        self.assertEqual(sorted(p.name for p in self.gdir.iterdir()), ["Game One v1.2.0.ipa", "Game One.img", "Game One.s2arm", "README.txt"])
        self.assertEqual((out["layout"], out["exported"], out["signedWith"]["mode"], out["signMode"]), ("standalone", True, "none", "appleId"))
        self.assertEqual(len(out["nextSteps"]), 3)
        self.assertEqual(out["resourceBytes"], 1, "资源本体按实际大小报（硬链接界面注「不另占空间」）")
        self.assertFalse([p for p in Path(self.c.library).iterdir() if p.name.startswith(".container-")], "临时容器清掉")


class Hints(unittest.TestCase):
    def test_standalone_hint_by_sign_mode(self):
        import devcert
        c = object()
        # 11-21：显式 App ID 的描述文件 → explicit（只允许一个包名，装一款顶掉前一款，装之前就说）；读不到描述文件 → None。期望手写
        for mode, facts, want in (("external", {}, "external"), ("appleId", {}, "appleId"), ("devCert", {"wildcard": True}, "wildcard"),
                                  ("devCert", {"wildcard": False}, "explicit"), ("devCert", {}, None)):
            with patch.object(install, "chosen_sign_mode", lambda c, m=mode: m), patch.object(devcert, "profile_facts", lambda c, f=facts: f):
                self.assertEqual(install.standalone_hint(c), want, (mode, facts))

    def test_standalone_hints_follow_chosen_sign_not_setting(self):
        """导出确认页按这次选的签名方式给那句：设置里是 Apple ID，证书那一项照样按描述文件给 explicit。期望手写"""
        import devcert
        with patch.object(install, "chosen_sign_mode", lambda c: "appleId"), patch.object(devcert, "profile_facts", lambda c: {"wildcard": False}):
            self.assertEqual(install.standalone_hints(object()), dict(appleId="appleId", devCert="explicit", none="external"))

    def test_layout_recommend_by_debug_permission(self):
        # #1760：不带调试权限（分发 / 企业证书）推荐独立 App；开发证书、Apple ID、自签推荐通用 S2Arm；都没有 = 识别不了
        import devcert
        c = object()
        cases = (("external", False, None, ("shell", "external")), ("devCert", True, None, ("standalone", "distribution")),
                 ("devCert", False, None, ("shell", "devCertDebug")), ("appleId", False, {"account": "a"}, ("shell", "appleId")), ("appleId", False, None, (None, "unknown")))
        for mode, dist, acct, want in cases:
            with patch.object(install, "chosen_sign_mode", lambda c, m=mode: m), patch.object(install, "distribution_cert", lambda c, d=dist: d), \
                    patch.object(install, "win_install_mod", lambda c: None), patch.object(install, "plume_account", lambda c, W, a=acct: a):
                self.assertEqual(install.layout_recommend(c), want, (mode, dist, acct))

    def test_missing_game_folder_says_so(self):
        import layout
        with tempfile.TemporaryDirectory() as d:
            c = jobcase.fake_context(Path(d), r={})
            with patch.object(layout, "state", lambda c, g: ("missing", Path(d))):
                with self.assertRaises(install.Failure) as e:
                    install.ios_pack(c, G1)
            self.assertEqual(e.exception.code, "game_folder_missing")


if __name__ == "__main__":
    unittest.main()
