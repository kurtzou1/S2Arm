#!/usr/bin/env python3
"""搬库后改链接目标（library._retarget_links，玩家诊断 #0fd185）：期望值手写。
   ① 能建链接：版本 RomFS 链接改指新位置；老库现行链接换成指针文件。
   ② 链接一律建不了（安全软件拦重解析点）：现行照样是指针文件；共享存储里那份 RomFS 整目录挪进现行版本（不拷）；
      同一份被上一版也指着时上一版只删链接、打黄。"""
import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import jobcase  # noqa: F401（把 pack/jobs 放进模块路径；门禁按文件单跑，不能靠同批别的测试先导入）
import library


def build_old(old):
    store = old / "roots/.romfs_store/G/id1"
    store.mkdir(parents=True)
    (store / "a.bin").write_bytes(b"aaa")
    for v in ("G@v1", "G@v2"):
        (old / "roots" / v).mkdir()
        os.symlink(str(store), old / "roots" / v / "romfs")
    os.symlink(str(old / "roots/G@v2"), old / "roots/G@现行")


class RetargetLinks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.old, self.new = self.root / "old", self.root / "new"
        build_old(self.old)
        os.rename(self.old, self.new)

    def tearDown(self):
        self.tmp.cleanup()

    def test_links_retargeted_current_becomes_pointer(self):
        library._retarget_links(self.new, self.old, self.new)
        cur = self.new / "roots/G@现行"
        self.assertTrue(cur.is_file() and not cur.is_symlink())
        self.assertEqual(cur.read_text(encoding="utf-8"), "G@v2\n")
        for v in ("G@v1", "G@v2"):
            link = self.new / "roots" / v / "romfs"
            self.assertTrue(link.is_symlink())
            self.assertEqual(os.readlink(link), str(self.new / "roots/.romfs_store/G/id1"))
            self.assertEqual((link / "a.bin").read_bytes(), b"aaa")

    def test_links_denied_moves_dir_to_current_version(self):
        def denied(*a, **k): raise PermissionError(13, "拒绝访问")
        err = io.StringIO()
        with mock.patch.object(library.os, "symlink", denied), contextlib.redirect_stderr(err):
            library._retarget_links(self.new, self.old, self.new)
        cur = self.new / "roots/G@现行"
        self.assertEqual(cur.read_text(encoding="utf-8"), "G@v2\n")
        v2 = self.new / "roots/G@v2/romfs"
        self.assertTrue(v2.is_dir() and not v2.is_symlink())
        self.assertEqual((v2 / "a.bin").read_bytes(), b"aaa")
        self.assertFalse(os.path.lexists(self.new / "roots/.romfs_store/G/id1"))
        self.assertFalse(os.path.lexists(self.new / "roots/G@v1/romfs"))
        self.assertIn("整目录挪到这里", err.getvalue())
        self.assertIn("已挪给现行版本", err.getvalue())


if __name__ == "__main__":
    unittest.main()
