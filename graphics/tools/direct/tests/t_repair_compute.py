#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Library switch, rollback, integrity and cache-reader tests; no game assets."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import repair_compute as repair


class RepairTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name).resolve()
        self.image = root / "image"
        self.lib = self.image / "shaders/direct/b-0123456789ab"
        self.lib.mkdir(parents=True)
        self.work = root / "repair"
        self.work.mkdir()
        header = bytearray(48)
        header[:8] = b"S2ALIB\0\0"
        struct.pack_into("<III", header, 8, 1, 1, 1)
        header[24:36] = b"0123456789ab"
        self.before = header + struct.pack("<QQ", 3, 0) + struct.pack("<QBBHIQ", 7, 0, 0, 0, 3, 0)
        (self.lib / "lib.idx").write_bytes(self.before)
        (self.lib / "lib.000.pak").write_bytes(b"old")
        self.manifest = self.image / "manifest.json"
        self.manifest.write_text(json.dumps({"files": {"shaders/direct/b-0123456789ab/lib.idx": [len(self.before), repair.digest(self.before)]}}))
        self.manifest_before = self.manifest.read_bytes()
        header[16:20] = struct.pack("<I", 2)
        self.after = header + struct.pack("<QQQQ", 3, 0, 3, 0) + struct.pack("<QBBHIQ", 7, 0, 1, 0, 3, 0)
        (self.work / "original.idx").write_bytes(self.before)
        (self.work / "patched.idx").write_bytes(self.after)
        (self.work / "lib.001.pak").write_bytes(b"new")
        self.report = {"library": str(self.lib), "before": repair.digest(self.before), "after": repair.digest(self.after), "shard": "lib.001.pak", "shard_sha256": repair.digest(b"new"), "compute_replaced": ["0000000000000007"]}
        tool = root / "tool.dll"
        tool.write_bytes(b"synthetic tool fingerprint")
        tool.with_name("S2A.Dsh.dll").write_bytes(b"synthetic translator fingerprint")
        repair.prepare_manifest(self.manifest, tool, repair.Library(self.lib), self.work, self.report)
        (self.work / "repair.json").write_text(json.dumps(self.report))
        self.closed = patch.object(repair, "closed")
        self.closed.start()

    def tearDown(self):
        self.closed.stop()
        self.temp.cleanup()

    def switch(self, rollback=False):
        repair.switch(repair.Library(self.lib), self.work, rollback)

    def test_apply_idempotence_and_rollback(self):
        self.switch()
        self.assertEqual(repair.Library(self.lib).read(7, 0), b"new")
        self.assertEqual((self.lib / "lib.000.pak").read_bytes(), b"old")
        meta = json.loads(self.manifest.read_text())
        self.assertEqual(meta["files"]["shaders/direct/b-0123456789ab/lib.idx"], [len(self.after), repair.digest(self.after)])
        self.switch()
        self.switch(True)
        self.assertEqual((self.lib / "lib.idx").read_bytes(), self.before)
        self.assertEqual(self.manifest.read_bytes(), self.manifest_before)
        self.assertTrue((self.lib / "lib.001.pak").exists())
        self.switch(True)

    def test_interrupted_switch_recovers(self):
        (self.lib / "lib.idx").write_bytes(self.after)
        self.switch()
        self.assertEqual(repair.digest(self.manifest.read_bytes()), self.report["manifest_after"])
        (self.lib / "lib.idx").write_bytes(self.before)
        self.switch(True)
        self.assertEqual(self.manifest.read_bytes(), self.manifest_before)

    def test_corrupt_prepared_manifest_rejected_before_any_switch(self):
        (self.work / "patched-manifest.json").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "manifest checksum"):
            self.switch()
        self.assertEqual((self.lib / "lib.idx").read_bytes(), self.before)
        self.assertFalse((self.lib / "lib.001.pak").exists())

    def test_changed_installation_is_not_overwritten(self):
        changed = bytearray(self.before)
        changed[20] = 1
        (self.lib / "lib.idx").write_bytes(changed)
        with self.assertRaisesRegex(ValueError, "Library changed"):
            self.switch()
        self.assertEqual((self.lib / "lib.idx").read_bytes(), changed)

    def test_cache_key_and_content_integrity(self):
        cache_key = b"xl/synthetic"
        data = b"DSE1" + struct.pack("<I", 1) + struct.pack("<I", 8) + b"_b.metal" + struct.pack("<I", 3) + b"msl" + cache_key
        data += hashlib.sha256(data).digest()
        path = Path(self.temp.name) / (repair.digest(cache_key) + ".e")
        path.write_bytes(b"DSZ1" + zlib.compress(data))
        self.assertEqual(repair.cache_files(path), {"_b.metal": b"msl"})
        bad = bytearray(data)
        bad[20] ^= 1
        path.write_bytes(b"DSZ1" + zlib.compress(bad))
        with self.assertRaisesRegex(ValueError, "checksum"):
            repair.cache_files(path)

    def test_stale_atomic_files_do_not_block_switch(self):
        (self.lib / "lib.idx.compute-stale").write_bytes(b"partial")
        self.manifest.with_name("manifest.json.compute-stale").write_bytes(b"partial")
        self.switch()
        self.switch(True)
        self.assertEqual(self.manifest.read_bytes(), self.manifest_before)

    def test_atomic_failure_can_be_retried(self):
        with patch.object(repair.os, "replace", side_effect=OSError("injected interruption")):
            with self.assertRaisesRegex(OSError, "injected"):
                self.switch()
        self.switch()
        self.switch(True)

    def test_shard_publication_failure_leaves_no_partial_final_file(self):
        with patch.object(repair.os, "link", side_effect=OSError("injected shard interruption")):
            with self.assertRaisesRegex(OSError, "injected shard"):
                self.switch()
        self.assertFalse((self.lib / "lib.001.pak").exists())
        self.assertEqual((self.lib / "lib.idx").read_bytes(), self.before)
        self.switch()
        self.switch(True)

    def test_replacement_reflection_has_no_shared_batch_identity(self):
        library = self.lib.parent / "shared"
        library.mkdir()
        meta = json.dumps({"stage": "cs", "fn_lib": "shared_batch", "fn_prefix": "s0123456789abcdef_"}).encode()
        payload = b"old batch" + meta
        (library / "lib.000.pak").write_bytes(payload)
        header = bytearray(48)
        header[:8] = b"S2ALIB\0\0"
        struct.pack_into("<III", header, 8, 1, 4, 1)
        records = b"".join(struct.pack("<QBBHIQ", key, kind, 0, 0, len(b"old batch") if kind == 0 else len(meta), 0 if kind == 0 else len(b"old batch")) for key in (7, 8) for kind in (0, 1))
        (library / "lib.idx").write_bytes(header + struct.pack("<QQ", len(payload), 0) + records)
        out = self.work / "shared"
        out.mkdir()
        repair.write_replacements(repair.Library(library), out, {7: b"new single function"})
        (library / "lib.idx").write_bytes((out / "patched.idx").read_bytes())
        (library / "lib.001.pak").write_bytes((out / "lib.001.pak").read_bytes())
        patched = repair.Library(library)
        replaced = json.loads(patched.read(7, 1))
        self.assertNotIn("fn_lib", replaced)
        self.assertEqual(replaced["fn_prefix"], "s0123456789abcdef_")
        self.assertEqual(json.loads(patched.read(8, 1))["fn_lib"], "shared_batch")
        self.assertEqual(patched.read(8, 0), b"old batch")


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RepairTest))
    print(("✓" if result.wasSuccessful() else "✗") + f" t_repair_compute: {result.testsRun} tests, {len(result.failures) + len(result.errors)} failures")
    sys.exit(0 if result.wasSuccessful() else 1)
