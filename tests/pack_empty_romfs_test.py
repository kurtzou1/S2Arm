#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Empty standard RomFS containers must survive resource packaging."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACK = Path(os.environ.get("S2A_TEST_PACK_FILE", ROOT / "pack/pack.py"))


class EmptyRomfsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="s2arm-empty-romfs-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        # Standard header and root directory; no file metadata or payload.
        end = 0xFFFFFFFF
        self.blob = struct.pack("<10Q", 0x50, 0x50, 4, 0x54, 24,
                                0x6C, 4, 0x70, 0, 0x70)
        self.blob += struct.pack("<I6II", end, 0, end, end, end, end, 0, end)
        (self.source / "romfs.std").write_bytes(self.blob)
        self.output = self.root / "pack.files"
        self.args = [str(self.output), f"romfs={self.source / 'romfs'}"]

    def run_script(self, script, *args):
        result = subprocess.run([sys.executable, str(script), *args],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def pack(self):
        self.run_script(PACK, *self.args)

    def verify(self):
        result = self.run_script(ROOT / "pack/verify.py", *self.args)
        self.assertFalse(Path(str(self.output) + ".verify_warn.txt").exists(),
                         result.stdout)

    def test_empty_container_is_copied_and_verified(self):
        self.pack()
        self.verify()
        self.assertEqual((self.output / "romfs.std").read_bytes(), self.blob)
        self.assertEqual((self.output / "index.tsv").read_bytes(), b"")

    def test_empty_container_with_other_resources(self):
        npdm = self.source / "main.npdm"
        npdm.write_bytes(b"synthetic npdm")
        self.args.append(f"exefs/main.npdm={npdm}")
        self.pack()
        self.assertEqual((self.output / "romfs.std").read_bytes(), self.blob)
        self.assertEqual((self.output / "exefs/main.npdm").read_bytes(),
                         b"synthetic npdm")
        self.verify()

    def test_missing_container_invalidates_check_and_is_repaired(self):
        self.pack()
        self.run_script(PACK, *self.args, "--check")
        (self.output / "romfs.std").unlink()
        result = subprocess.run([sys.executable, str(PACK), *self.args, "--check"],
                                capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.pack()
        self.verify()

    def test_corrupt_container_invalidates_check_and_is_repaired(self):
        self.pack()
        (self.output / "romfs.std").write_bytes(b"X" * len(self.blob))
        result = subprocess.run([sys.executable, str(PACK), *self.args, "--check"],
                                capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.pack()
        self.assertEqual((self.output / "romfs.std").read_bytes(), self.blob)
        self.verify()

    def test_nested_empty_container(self):
        self.args = [str(self.output), f"aoc/title/romfs={self.source / 'romfs'}"]
        self.pack()
        self.assertEqual((self.output / "aoc/title/romfs.std").read_bytes(),
                         self.blob)
        self.verify()


if __name__ == "__main__":
    unittest.main()
