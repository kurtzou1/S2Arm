# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳「导出通用 S2Arm.ipa」（pack/jobs/install.py export_shell_ipa，「导出新版 S2Arm」= installUpdate mode=export）：只有壳、不带游戏，
写进「S2Arm 游戏包」文件夹。游戏库是真的（library.setup），组壳用替身（写一个带小组件扩展的假 ipa），期望按替身写的内容手写。"""
import sys
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import ipa as packer  # noqa: E402
import program_pack  # noqa: E402
import tests.test_jobs as tj  # noqa: E402

APP = "Payload/S2Arm.app/S2Arm"
WIDGET = "Payload/S2Arm.app/PlugIns/Widget.appex/Widget"


class ShellIpaExport(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def fake_shell(self, c, *, dest=None):
        Path(dest).mkdir(parents=True, exist_ok=True)
        ipa = Path(dest) / "S2Arm.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr(APP, b"shell")
            z.writestr(WIDGET, b"widget")
        self.assembled += 1
        return ipa, [], "SHELL1"

    def export(self, on=True, shell=None):
        self.assembled = 0
        def no_catalog():
            raise AssertionError("导出通用 ipa 不读游戏库")
        self.c.catalog = no_catalog
        self.c.r.update(mode="export")
        with patch.object(packer, "assemble_shell", shell or self.fake_shell), \
                patch.object(install, "patches_results", lambda c: []):
            return install.export_shell_ipa(self.c)

    def names(self, p):
        with zipfile.ZipFile(p) as z:
            return sorted(z.namelist())

    def test_shell_only_ipa_into_game_packs_folder(self):
        old = Path(self.c.library) / "S2Arm 自签导出"
        old.mkdir(); (old / "S2Arm.ipa").write_bytes(b"0.5.x")
        r = self.export()
        folder = Path(self.c.library) / "S2Arm 游戏包"
        self.assertEqual(r["ipa"], str(folder / "S2Arm.ipa"))
        self.assertEqual(self.names(r["ipa"]), sorted([APP, WIDGET]))
        self.assertEqual((r["games"], r["files"], r["shellId"], r["exported"]), ([], [], "SHELL1", True))
        text = (folder / "怎么导入.txt").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("S2Arm.ipa：S2Arm App 本体（不带游戏、未签名），给自签工具用：在 LiveContainer 里直接导入它，或用 SideStore、AltStore 等签好装到手机。"), "导出了 ipa：说明最前面是 ipa 那句，写清用途")
        self.assertIn("点开 .s2arm 文件", text)
        self.assertEqual((old / "S2Arm.ipa").read_bytes(), b"0.5.x", "0.5.x 的自签导出文件夹不碰")
        self.assertEqual(sorted(p.name for p in Path(self.c.library).iterdir() if p.name.startswith(".export-")), [], "不留临时目录")

    def test_readme_ipa_sentence_only_when_ipa_exported(self):
        # 只导出过 .s2arm 的文件夹（没 S2Arm.ipa）：说明里没有 ipa 那句；之后导出 ipa 再写 .s2arm，ipa 那句留着
        import install as ins
        folder = Path(self.c.library) / "S2Arm 游戏包"; folder.mkdir()
        ins.write_s2arm_readme(folder, "zh")
        self.assertNotIn("S2Arm.ipa", (folder / "怎么导入.txt").read_text(encoding="utf-8"))
        self.export()
        ins.write_s2arm_readme(folder, "en")
        self.assertTrue((folder / "How to import.txt").read_text(encoding="utf-8").startswith("S2Arm.ipa: the S2Arm app itself (no games, unsigned), for self-signing tools: import it directly in LiveContainer"))

    def test_widget_off_strips_extension(self):
        self.c.r["widget"] = False
        r = self.export()
        self.assertEqual(self.names(r["ipa"]), [APP])

    def test_replaces_in_place_keeps_others_and_existing_folder(self):
        en = Path(self.c.library) / "S2Arm Game Packs"; en.mkdir()
        (en / "S2Arm.ipa").write_bytes(b"old"); (en / "Game.s2arm").write_bytes(b"pack")
        self.c.r["uiLanguage"] = "zh-Hans"
        r = self.export()
        self.assertEqual(Path(r["ipa"]).parent, en, "库根已有英文那个文件夹：换中文界面也写进它")
        self.assertEqual(self.names(r["ipa"]), sorted([APP, WIDGET]))
        self.assertEqual((en / "Game.s2arm").read_bytes(), b"pack")
        self.assertEqual([p.name for p in en.iterdir() if p.name.endswith(".partial")], [])

    def test_failure_keeps_previous_ipa(self):
        folder = Path(self.c.library) / "S2Arm 游戏包"; folder.mkdir()
        (folder / "S2Arm.ipa").write_bytes(b"previous")
        def broken(c, *, dest=None):
            raise RuntimeError("组壳失败")
        with self.assertRaises(RuntimeError):
            self.export(shell=broken)
        self.assertEqual((folder / "S2Arm.ipa").read_bytes(), b"previous")
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["S2Arm.ipa"])
        # 已经往文件夹里写了一半（去小组件另存时出错）：半个临时文件也清掉，上一份照旧
        def half(src, dst):
            Path(dst).write_bytes(b"half"); raise OSError("盘满")
        self.c.r["widget"] = False
        with patch.object(install, "ipa_strip_widget", half), self.assertRaises(OSError):
            self.export()
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["S2Arm.ipa"])
        self.assertEqual((folder / "S2Arm.ipa").read_bytes(), b"previous")

    def test_update_phone_export_routes_here(self):
        # 「导出新版 S2Arm」（更新作业带 mode=export）开关开着也出通用 ipa
        self.assembled = 0
        self.c.catalog = lambda: {"games": []}
        self.c.r.update(mode="export")
        with patch.object(packer, "assemble_shell", self.fake_shell), \
                patch.object(install, "patches_results", lambda c: []):
            r = install._update_phone(self.c)
        self.assertTrue(r["updated"])
        self.assertEqual((self.assembled, Path(r["ipa"]).parent.name), (1, "S2Arm 游戏包"))



    def test_folder_export_brings_current_shell_ipa_once(self):
        # #502：「导出…」通用 S2Arm、一台都不勾 = 导出到文件夹，原先只出 .s2arm；单独导出 S2Arm.ipa 只在总控台登记过的手机下面，
        #   LiveContainer / 没连过电脑的玩家拿不到新版 S2Arm.ipa。期望（手写）：同文件夹放上本版壳号的 S2Arm.ipa；已是本版就不重组；壳号变了才换
        self.assembled = 0
        with patch.object(packer, "assemble_shell", self.fake_shell), patch.object(packer, "current_shell_id", lambda c: "SHELL1"):
            out = install.ensure_shell_ipa(self.c)
            again = install.ensure_shell_ipa(self.c)
        folder = Path(self.c.library) / "S2Arm 游戏包"
        self.assertEqual((out, again), (folder / "S2Arm.ipa", folder / "S2Arm.ipa"))
        self.assertEqual(self.assembled, 1, "第二次已是本版壳号，不重组")
        self.assertEqual((folder / install.SHELL_IPA_MARK).read_text(encoding="utf-8").strip(), "SHELL1")
        with patch.object(packer, "assemble_shell", lambda c, dest=None: (self.fake_shell(c, dest=dest)[0], [], "SHELL2")), \
                patch.object(packer, "current_shell_id", lambda c: "SHELL2"):
            install.ensure_shell_ipa(self.c)
        self.assertEqual(self.assembled, 2, "壳号变了就换")
        self.assertEqual((folder / install.SHELL_IPA_MARK).read_text(encoding="utf-8").strip(), "SHELL2")

    def test_install_export_shell_layout_calls_ensure_before_s2arm(self):
        order = []
        self.c.r.update(gameId="0100000000010000", mode="export")
        import downstream
        with patch.object(downstream, "requested", lambda c, g: None), patch.object(install, "ios_pack", lambda c, g: None), \
                patch.object(install, "chosen_layout", lambda c, g=None: "shell"), \
                patch.object(install, "ensure_shell_ipa", lambda c: order.append("ipa") or Path("/x/S2Arm.ipa")), \
                patch.object(install, "export_s2arm", lambda c, g: order.append("s2arm") or dict(exported=True)):
            r = install._install(self.c)
        self.assertEqual(order, ["ipa", "s2arm"])
        self.assertEqual(r["shellIpa"], "/x/S2Arm.ipa")

    def device_push(self, ensure=None):
        """「导出…」勾了设备 = 通用 S2Arm 推到这台（不带 mode）：推完照样在「S2Arm 游戏包」放本版 S2Arm.ipa + 说明"""
        self.assembled = 0
        self.c.r.update(gameId="0100000000010000")
        self.c.r.pop("mode", None)
        import downstream
        with patch.object(downstream, "requested", lambda c, g: None), patch.object(install, "ios_pack", lambda c, g: None), \
                patch.object(install, "chosen_layout", lambda c, g=None: "shell"), patch.object(install, "push_phone", lambda c: "PH"), \
                patch.object(install, "push_game", lambda c, g, ph: dict(games=[g], bundleId="io.s2arm.games.x")), \
                patch.object(packer, "assemble_shell", self.fake_shell), patch.object(packer, "current_shell_id", lambda c: "SHELL1"), \
                patch.object(install, "ensure_shell_ipa", ensure or install.ensure_shell_ipa):
            return install._install(self.c)

    def test_device_push_also_brings_shell_ipa(self):
        # 11-21 维护者：「导出…」不论勾不勾设备，导出文件夹里都带上本版 S2Arm.ipa。期望（手写）：推完的结果原样 + shellIpa 指向
        #   「S2Arm 游戏包/S2Arm.ipa」（替身组的壳），说明文件开头是写清用途的 ipa 那句；同一版再推不重组
        r = self.device_push()
        folder = Path(self.c.library) / "S2Arm 游戏包"
        self.assertEqual((r["games"], r["bundleId"], r["shellIpa"]), (["0100000000010000"], "io.s2arm.games.x", str(folder / "S2Arm.ipa")))
        self.assertEqual(self.names(folder / "S2Arm.ipa"), sorted([APP, WIDGET]))
        self.assertTrue((folder / "怎么导入.txt").read_text(encoding="utf-8").startswith("S2Arm.ipa：S2Arm App 本体"))
        self.assertEqual(self.assembled, 1)
        self.device_push()
        self.assertEqual(self.assembled, 0, "本版已在文件夹里：第二次推不重组")

    def test_device_push_keeps_result_when_ipa_fails(self):
        # 组壳失败不把已推好的这一款判成失败：结果照旧带推送字段，原因放 shellIpaError
        def broken(c):
            raise install.Failure("组不出壳", code="job_failed")
        r = self.device_push(ensure=broken)
        self.assertEqual((r["games"], r["shellIpaError"], "shellIpa" in r), (["0100000000010000"], "组不出壳", False))


if __name__ == "__main__":
    unittest.main()
