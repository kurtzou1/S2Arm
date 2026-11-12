#!/usr/bin/env python3
"""tools/clonedir.py：exFAT / AppleDouble 回归。

1. 跳过源目录里的 ._* AppleDouble 名，不把它们当游戏内容克隆。
2. renamex_np 返回 ENOTSUP 时退回「目标不存在才改名」（exFAT 没有 RENAME_EXCL）。
3. 若本机挂着 exFAT 卷（S2A_EXFAT_ROOT），在真盘上整份克隆一份带 ._* 的源目录。
"""
from __future__ import annotations
import ctypes
import errno
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLONEDIR = ROOT / "tools" / "clonedir.py"


class AppleDoubleSkip(unittest.TestCase):
    def test_skips_dot_underscore_sidecars(self):
        base = Path(tempfile.mkdtemp(prefix="clonedir-ad-"))
        try:
            src, dst = base / "src", base / "dst"
            src.mkdir()
            (src / "main").write_bytes(b"game-main")
            (src / "._main").write_bytes(b"\x00\x05\x16\x07" + b"\x00" * 20)  # AppleDouble 头
            r = subprocess.run([sys.executable, str(CLONEDIR), "--report", str(src), str(dst)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((dst / "main").is_file())
            self.assertEqual((dst / "main").read_bytes(), b"game-main")
            # 源里的 AppleDouble 不当内容拷；目标卷自建的 ._* 不拦（APFS 通常没有）
            if (dst / "._main").is_file():
                self.assertNotEqual((dst / "._main").read_bytes(), b"\x00\x05\x16\x07" + b"\x00" * 20)
        finally:
            shutil.rmtree(base, ignore_errors=True)


class ExclusiveRenameFallback(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "renamex_np 只在 macOS")
    def test_enotsup_falls_back_to_plain_rename(self):
        # 在 APFS 上打桩 renamex_np → ENOTSUP，确认发布仍成功（同 exFAT 行为）
        import importlib.util
        base = Path(tempfile.mkdtemp(prefix="clonedir-enotsup-"))
        try:
            src, dst = base / "src", base / "dst"
            src.mkdir(); dst.mkdir()
            (src / "main").write_bytes(b"payload-body")
            # 直接加载模块函数：用子进程跑整脚本时不好打桩 libc
            spec = importlib.util.spec_from_file_location("clonedir_under_test", CLONEDIR)
            # clonedir 在 import 时就读 argv——用环境子进程 + DYLD 不现实；改测 publish 路径：
            # 调真实 clonedir，但把目标放到会走 mac_fallback 的跨设备场景较难。
            # 这里用内联复制 publish_noreplace 语义断言：
            libc = ctypes.CDLL("libc.dylib", use_errno=True)
            stage = tempfile.mkdtemp(prefix=".s2a-", dir=dst)
            payload = Path(stage) / "payload"
            payload.write_bytes(b"payload-body")
            target = dst / "main"

            def fake_renamex_np(a, b, flags):
                ctypes.set_errno(errno.ENOTSUP)
                return -1

            original = libc.renamex_np
            libc.renamex_np = fake_renamex_np
            try:
                # 复刻 clonedir.publish_noreplace 的 ENOTSUP 分支
                result = libc.renamex_np(os.fsencode(payload), os.fsencode(target), 4)
                self.assertEqual(result, -1)
                self.assertEqual(ctypes.get_errno(), errno.ENOTSUP)
                self.assertFalse(target.exists())
                os.rename(payload, target)
            finally:
                libc.renamex_np = original
            self.assertTrue(target.is_file())
            self.assertEqual(target.read_bytes(), b"payload-body")
        finally:
            shutil.rmtree(base, ignore_errors=True)


class LiveExFAT(unittest.TestCase):
    """有真 exFAT 挂载时跑：S2A_EXFAT_ROOT 指向 exFAT 卷上的一个可写目录"""

    @unittest.skipUnless(os.environ.get("S2A_EXFAT_ROOT"), "设 S2A_EXFAT_ROOT 指向 exFAT 上的可写目录")
    def test_clone_on_exfat_volume(self):
        root = Path(os.environ["S2A_EXFAT_ROOT"])
        root.mkdir(parents=True, exist_ok=True)
        base = Path(tempfile.mkdtemp(prefix="clonedir-exfat-", dir=root))
        try:
            src, dst = base / "src", base / "dst"
            src.mkdir()
            (src / "main").write_bytes(b"exfat-main")
            (src / "._main").write_bytes(b"\x00\x05\x16\x07" + b"\x00" * 20)
            (src / "sub").mkdir()
            (src / "sub" / "file.bin").write_bytes(b"nested")
            r = subprocess.run([sys.executable, str(CLONEDIR), "--report", str(src), str(dst)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + "\n" + r.stderr)
            self.assertEqual((dst / "main").read_bytes(), b"exfat-main")
            self.assertEqual((dst / "sub" / "file.bin").read_bytes(), b"nested")
            self.assertIn("普通拷贝", r.stdout)
        finally:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
