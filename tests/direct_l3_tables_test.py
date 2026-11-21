#!/usr/bin/env python3
"""Synthetic files through the real direct_lib.py table collection (Lib.collect over direct_lib.TABLES).

No shader compiler, game input, GPU, signing, or complete package execution.
"""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "graphics/tools/direct/direct_lib.py"
sys.path.insert(0, str(SCRIPT.parent))
import direct_lib  # noqa: E402
L3 = "fps_l3_results.tsv"
EXISTING = (
    "game.tsv", "shader_map.tsv", "shader_facts.tsv", "shader_pairs.tsv",
    "bf_want.tsv", "pso_manifest.tsv", "c1_full.tsv", "cb_extent.tsv",
    "shader_map.tsv.conflicts.tsv",
)
L3_BYTES = b"# original synthetic L3 fixture\r\n0100ABCD00000000\tok\r\n"


def collection_block():
    """The producer's own list (not a second implementation/list)."""
    return direct_lib.TABLES


class DirectL3Tables(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2a_l3_tables_")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / "work"
        self.profile = self.work / "profile/0100ABCD00000000"
        self.output = self.root / "package/shaders/direct"
        self.profile.mkdir(parents=True)
        self.output.mkdir(parents=True)
        for name in EXISTING:
            (self.profile / name).write_bytes(("# synthetic " + name + "\n").encode())
        (self.profile / "unlisted-control.tsv").write_bytes(b"not a shipped table\n")

    def collect(self, block=None):
        lib = direct_lib.Lib.__new__(direct_lib.Lib)
        lib.W, lib.TID, lib.OS = str(self.work), "0100ABCD00000000", str(self.output)
        with mock.patch.object(direct_lib, "TABLES", collection_block() if block is None else block), contextlib.redirect_stderr(io.StringIO()):
            lib.collect()

    def assert_l3_shipped(self):
        target = self.output / L3
        self.assertTrue(target.is_file(), "L3 table missing from shaders/direct")
        self.assertEqual(target.read_bytes(), L3_BYTES)

    def test_supplied_l3_reaches_package_path_byte_for_byte(self):
        (self.profile / L3).write_bytes(L3_BYTES)
        self.collect()
        self.assert_l3_shipped()
        self.assertEqual((self.profile / L3).read_bytes(), L3_BYTES)

    def test_existing_tables_unchanged_and_unlisted_file_excluded(self):
        (self.profile / L3).write_bytes(L3_BYTES)
        self.collect()
        for name in EXISTING:
            with self.subTest(table=name):
                self.assertEqual((self.output / name).read_bytes(), (self.profile / name).read_bytes())
        self.assertFalse((self.output / "unlisted-control.tsv").exists())

    def test_missing_optional_l3_preserves_existing_behavior(self):
        self.collect()
        self.assertFalse((self.output / L3).exists())
        self.assertEqual({p.name for p in self.output.iterdir()}, set(EXISTING))

    def test_removing_l3_from_real_collection_list_is_detected(self):
        block = collection_block()
        self.assertEqual(block.count(L3), 1)
        # Mutate only a private in-memory copy; leave the production source intact.
        before = SCRIPT.read_bytes()
        missing_l3 = tuple(t for t in block if t != L3)
        (self.profile / L3).write_bytes(L3_BYTES)
        self.collect(missing_l3)
        with self.assertRaisesRegex(AssertionError, "L3 table missing"):
            self.assert_l3_shipped()
        self.assertEqual(SCRIPT.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
