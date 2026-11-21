# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁手动：依赖尚未公开的 runtime/rewriter/nro_container.py（不在本仓库），公开后接进 ohos/gate.sh；单跑：python3 -B ohos/tests/test_nro_container.py
"""Pure Python container tests; all executable inputs are synthetic bytes.

Run: python -B ohos/tests/test_nro_container.py
No game files, keys, compiler, native runtime, or device are used.
"""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[2] / "runtime/rewriter/nro_container.py"
spec = importlib.util.spec_from_file_location("nro_container", TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(text_size=0x1000, ro_size=0x1000, data_size=0x1000, bss_size=0x2000):
    data = bytearray(b"T" * text_size + b"R" * ro_size + b"D" * data_size)
    data[:0x80] = bytes(0x80)
    # Preserve a branch, the module pointer, and nonzero start metadata too.
    struct.pack_into("<IIII", data, 0, 0x14000020, 0x100, 0x13579BDF, 0)
    struct.pack_into("<4sIII", data, 0x10, b"NRO0", 0, len(data), 0)
    struct.pack_into("<6I", data, 0x20, 0, text_size, text_size, ro_size,
                     text_size + ro_size, data_size)
    struct.pack_into("<I", data, 0x38, bss_size)
    data[0x40:0x60] = bytes(range(32))
    struct.pack_into("<I", data, 0x60, len(data))
    struct.pack_into("<6I", data, 0x68, 0x10, 0x20, 0x30, 0x40, 0x80, 0x60)
    data[0x100:0x104] = b"MOD0"
    return bytes(data)


def change(data, offset, value):
    result = bytearray(data)
    struct.pack_into("<I", result, offset, value)
    return bytes(result)


class ContainerTests(unittest.TestCase):
    def test_round_trip_preserves_entire_virtual_image(self):
        original = fixture()
        output = module.nro_to_nso(original)
        self.assertEqual(output[:4], b"NSO0")
        self.assertEqual(struct.unpack_from("<III", output, 4), (0, 0, 0x38))
        self.assertEqual(output[0x40:0x60], bytes(range(32)))
        self.assertEqual(struct.unpack_from("<I", output, 0x3C)[0], 0x2000)
        self.assertEqual(output[0x100:], original)
        image = bytearray(0x5000)
        for i, expected_offset in enumerate((0, 0x1000, 0x2000)):
            file_offset, virtual_offset, size = struct.unpack_from("<III", output, 0x10 + i * 0x10)
            stored_size = struct.unpack_from("<I", output, 0x60 + i * 4)[0]
            self.assertEqual((virtual_offset, size, stored_size), (expected_offset, 0x1000, 0x1000))
            segment = output[file_offset:file_offset + stored_size]
            self.assertEqual(segment, original[expected_offset:expected_offset + size])
            self.assertEqual(output[0xA0 + i * 32:0xC0 + i * 32], hashlib.sha256(segment).digest())
            image[virtual_offset:virtual_offset + size] = segment
        self.assertEqual(image[:len(original)], original)
        self.assertEqual(image[len(original):], bytes(0x2000))
        self.assertEqual(module.nro_to_nso(original), output)

    def test_zero_bss_and_empty_optional_segments(self):
        for sizes in ((0x2000, 0x1000, 0x1000, 0), (0x1000, 0, 0, 0), (0x1000, 0, 0x1000, 0x1000)):
            with self.subTest(sizes=sizes):
                original = fixture(*sizes)
                output = module.nro_to_nso(original)
                self.assertEqual(output[0x100:], original)
                self.assertEqual(struct.unpack_from("<I", output, 0x3C)[0], sizes[3])

    def test_truncated_or_wrong_header(self):
        original = fixture()
        for length in (0, 0x10, 0x7F, len(original) - 1):
            with self.subTest(length=length), self.assertRaises(ValueError):
                module.nro_to_nso(original[:length])
        with self.assertRaisesRegex(ValueError, "magic"):
            module.nro_to_nso(change(original, 0x10, 0))

    def test_unknown_version_flags_and_reserved_fields(self):
        original = fixture()
        for offset, value in [(0x14, 1), (0x3C, 1), (0x64, 1)] + [(0x1C, 1 << bit) for bit in range(32)]:
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                module.nro_to_nso(change(original, offset, value))

    def test_declared_size_and_trailing_assets(self):
        original = fixture()
        for value in (0, len(original) - 0x1000, len(original) + 0x1000, 0xFFFFFFFF):
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.nro_to_nso(change(original, 0x18, value))
        with self.assertRaises(ValueError):
            module.nro_to_nso(original + b"ASET" + bytes(100))

    def test_segment_overlap_gap_alignment_and_overflow(self):
        original = fixture()
        cases = [(0x20, 0x1000), (0x24, 0), (0x24, 0x1001),
                 (0x28, 0), (0x28, 0x2000), (0x28, 0x1001),
                 (0x2C, 0x2000), (0x30, 0x1000), (0x30, 0x4000),
                 (0x30, 0xFFFFF000), (0x34, 0), (0x34, 0x2000),
                 (0x34, 0xFFFFF000), (0x38, 1), (0x38, 0xFFFFF000)]
        for offset, value in cases:
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                module.nro_to_nso(change(original, offset, value))

    def test_file_conversion_hashes_and_input_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "source.nro", Path(directory) / "output.nso"
            original = fixture()
            source.write_bytes(original)
            result = module.convert_file(source, target)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(target.read_bytes()[0x100:], original)
            self.assertEqual(result["input_sha256"], hashlib.sha256(original).hexdigest())
            self.assertEqual(result["output_sha256"], hashlib.sha256(target.read_bytes()).hexdigest())
            self.assertEqual(result["build_id"], bytes(range(32)).hex())

    def test_existing_output_and_same_file_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "source.nro", Path(directory) / "output.nso"
            original = fixture()
            source.write_bytes(original)
            target.write_bytes(b"existing artifact")
            for path in (target, source):
                with self.subTest(path=path.name), self.assertRaises(FileExistsError):
                    module.convert_file(source, path)
            self.assertEqual(target.read_bytes(), b"existing artifact")
            self.assertEqual(source.read_bytes(), original)

    def test_validation_failure_creates_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "source.nro", Path(directory) / "output.nso"
            source.write_bytes(change(fixture(), 0x1C, 1))
            with self.assertRaises(ValueError):
                module.convert_file(source, target)
            self.assertFalse(target.exists())

    def test_competing_creators_cannot_overwrite_output(self):
        with tempfile.TemporaryDirectory() as directory:
            sources = [Path(directory) / f"{i}.nro" for i in range(2)]
            target = Path(directory) / "output.nso"
            for i, source in enumerate(sources):
                data = bytearray(fixture())
                data[-1] = i
                source.write_bytes(data)
            def attempt(source):
                try:
                    return module.convert_file(source, target)
                except FileExistsError:
                    return None
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(attempt, sources))
            self.assertEqual(sum(result is not None for result in results), 1)
            winner = next(result for result in results if result is not None)
            self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), winner["output_sha256"])

    def test_cli_success_then_refuses_overwrite_and_bad_input(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "合成 source.nro", Path(directory) / "output file.nso"
            source.write_bytes(fixture())
            command = [sys.executable, "-B", str(TOOL), str(source), str(target)]
            good = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertEqual(json.loads(good.stdout)["input_bytes"], 0x3000)
            saved = target.read_bytes()
            refused = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("conversion failed", refused.stderr)
            self.assertEqual(target.read_bytes(), saved)
            source.write_bytes(b"invalid")
            absent = Path(directory) / "absent.nso"
            bad = subprocess.run(command[:-1] + [str(absent)], capture_output=True, text=True, encoding="utf-8")
            self.assertNotEqual(bad.returncode, 0)
            self.assertFalse(absent.exists())


if __name__ == "__main__":
    unittest.main()
