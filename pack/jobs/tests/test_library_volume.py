"""游戏库只能放 APFS（11-02 出包线发现：exFAT 不支持原子的不覆盖改名，出包链必失败）：选库就拦、环境检查就报。
期望按规则手写；真盘格式用本机 /tmp（APFS）实读，exFAT 走打桩。"""
import sys
import tempfile
import unittest
import unittest.mock as um
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import library
from core import Failure
import tests.test_jobs as tj   # 只借夹具，不 from-import 类名


class VolumeFormat(unittest.TestCase):
    def test_reads_real_volume_and_walks_up(self):
        d = Path(tempfile.mkdtemp())
        self.assertEqual(library.volume_format(d), "apfs")   # 普通文件夹（不是挂载点）也要读得出
        self.assertEqual(library.volume_format(d / "还没建" / "游戏库"), "apfs")   # 还不存在：看最近一级已存在的上级

    def test_require_apfs(self):
        with um.patch.object(library, "volume_format", return_value="exfat"):
            with self.assertRaises(Failure) as e:
                library.require_apfs("/外接盘/游戏库")
        self.assertEqual(e.exception.code, "library_not_apfs"); self.assertIn("EXFAT", str(e.exception)); self.assertIn("APFS", str(e.exception))
        for ok in ("apfs", "", "hfs"):   # 读不到格式不拦（不因为探测失败挡住玩家）；HFS+ 放开（v0.3.1：克隆退回普通拷贝、不覆盖改名照常，11-12 映像实测）
            with um.patch.object(library, "volume_format", return_value=ok):
                library.require_apfs("/x")


class SetupAndPreflight(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def test_setup_rejects_exfat_before_writing(self):
        lib = Path(tempfile.mkdtemp()) / "库"; self.c.library = lib
        with um.patch.object(library, "volume_format", return_value="exfat"), self.assertRaises(Failure) as e:
            library.setup(self.c)
        self.assertEqual(e.exception.code, "library_not_apfs"); self.assertFalse(lib.exists())   # 拦在建目录之前

    def test_setup_treats_os_junk_as_empty(self):
        # 11-09 #343 同类：Windows 资源管理器给新文件夹留 desktop.ini / Thumbs.db、访达留 .DS_Store，选这样的文件夹建库不能报「已有别的文件」
        lib = Path(tempfile.mkdtemp()) / "库"; lib.mkdir(); self.c.library = lib
        for junk in (".DS_Store", "desktop.ini", "Thumbs.db"):
            (lib / junk).write_bytes(b"x")
        result = library.setup(self.c)
        self.assertTrue((lib / ".s2arm-library.json").is_file()); self.assertTrue(result["libraryId"])

    def test_setup_still_refuses_real_files(self):
        lib = Path(tempfile.mkdtemp()) / "库"; lib.mkdir(); self.c.library = lib
        (lib / "desktop.ini").write_bytes(b"x"); (lib / "notes.txt").write_bytes(b"x")
        with self.assertRaises(Failure):
            library.setup(self.c)
        self.assertFalse((lib / ".s2arm-library.json").exists())

    def test_has_content(self):
        import layout
        d = Path(tempfile.mkdtemp())
        self.assertFalse(layout.has_content(d)); self.assertFalse(layout.has_content(d / "没有"))
        (d / "Thumbs.db").write_bytes(b"x"); self.assertFalse(layout.has_content(d))
        (d / "save.dat").write_bytes(b"x"); self.assertTrue(layout.has_content(d))

    def test_preflight_reports_library_drive(self):
        import toolchain
        self.c.r["library"] = "/外接盘/游戏库"
        seen = []
        with um.patch.object(library, "volume_format", return_value="exfat"), um.patch.object(self.c, "emit", lambda kind, *a, **kw: seen.append(kw.get("check")) if kind == "check" else None):
            try:
                toolchain.preflight(self.c)
            except Exception:
                pass   # 后面的工具探测与本测无关
        row = next((x for x in seen if x and x["name"] == "游戏库所在磁盘"), None)
        self.assertIsNotNone(row)
        self.assertEqual((row["ok"], row["group"], row["action"]), (False, "storage", "library"))
        self.assertEqual(row["diagnostic"]["code"], "library_not_apfs")


if __name__ == "__main__":
    unittest.main()
