#!/usr/bin/env python3
"""PKZ / DAT 合成回归：自造容器与代码字节，不读游戏、不联网。"""

import collections
import contextlib
import ctypes
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import nxfmt
import nxsh_extract as X
import pkz
import pkz_inventory


def shader(stage='vs', seed=1, control_size=2001):
    ctl = bytearray(control_size)
    ctl[:8] = bytes.fromhex('3412769801000000')
    struct.pack_into('<I', ctl, 0x20, control_size)
    struct.pack_into('<II', ctl, 0x700, 0x100, 0x180)
    struct.pack_into('<4I', ctl, 0x748, 8, 4, 1, 32)
    ctl[0x100] = seed
    code = bytearray(0x180)
    if stage != 'cs':
        code[:4] = bytes.fromhex('78563412')
        ty = {'vs': 1, 'hs': 2, 'ds': 3, 'gs': 4, 'ps': 5}[stage]
        struct.pack_into('<I', code, 0x30, ty << 10)
    struct.pack_into('<Q', code, 0x80, 0xe30000000007000f)
    code[-1] = seed
    magic = next(m for m, s in pkz.STAGES.items() if s == stage)
    record = magic + struct.pack('<5I', 1, len(ctl), 24, len(code), 24 + len(ctl)) + ctl + code
    return record, bytes(ctl), bytes(code)


def dat(members):
    count = len(members)
    if not count:
        return b'DAT\0' + bytes(28)
    stride = max(len(name.encode()) + 1 for name, _ in members)
    offsets_at, ext_at, names_at = 32, 32 + 4 * count, 32 + 8 * count
    sizes_at = names_at + 4 + count * stride
    payload_at = sizes_at + 4 * count
    data = bytearray(payload_at)
    data[:4] = b'DAT\0'
    struct.pack_into('<5I', data, 4, count, offsets_at, ext_at, names_at, sizes_at)
    struct.pack_into('<I', data, names_at, stride)
    for i, (name, payload) in enumerate(members):
        struct.pack_into('<I', data, offsets_at + i * 4, len(data))
        struct.pack_into('<I', data, sizes_at + i * 4, len(payload))
        ext = name.rsplit('.', 1)[1].encode() + b'\0'
        assert len(ext) <= 4
        data[ext_at + i * 4:ext_at + (i + 1) * 4] = ext.ljust(4, b'\0')
        name_at = names_at + 4 + i * stride
        data[name_at:name_at + len(name.encode())] = name.encode()
        data.extend(payload)
    return bytes(data)


def compress(data):
    z = X._zstd_lib()
    z.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    z.ZSTD_compressBound.restype = ctypes.c_size_t
    z.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                              ctypes.c_size_t, ctypes.c_int]
    z.ZSTD_compress.restype = ctypes.c_size_t
    buf = ctypes.create_string_buffer(z.ZSTD_compressBound(len(data)))
    n = z.ZSTD_compress(buf, len(buf), data, len(data), 1)
    assert not z.ZSTD_isError(n)
    return buf.raw[:n]


def archive(members):
    """成员 = (名字, 原文, 压缩方式)，所有字段按公开结构自行造。"""
    names = bytearray()
    fields = []
    for name, payload, method in members:
        no = len(names); names.extend(name.encode() + b'\0')
        mo = len(names); names.extend(method.encode() + b'\0')
        stored = compress(payload) if method == 'ZStandard' else payload
        fields.append((no, mo, len(payload), stored))
    data = bytearray(32 + len(members) * 32)
    data[:4] = b'pkzl'
    struct.pack_into('<3I', data, 16, len(members), 32, len(names))
    data.extend(names)
    for i, (no, mo, size, stored) in enumerate(fields):
        struct.pack_into('<IIQQQ', data, 32 + i * 32, no, mo, size, len(data), len(stored))
        data.extend(stored)
    struct.pack_into('<Q', data, 8, len(data))
    return bytes(data)


def scan(data):
    rows, blobs, stat = [], {}, collections.Counter()
    with contextlib.redirect_stderr(io.StringIO()):
        X.visit('arbitrary.bin', data, rows, blobs, stat)
    return rows, blobs, stat


def sarc(data):
    writer = nxfmt.SarcWriter(nxfmt.Endianness.Little)
    writer.files['ordinary.bin'] = data
    return bytes(writer.write()[1])


def cli(data):
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / 'input'; root.mkdir()
        (root / 'resource.bin').write_bytes(data)
        return subprocess.run([sys.executable, X.__file__, str(Path(td) / 'out'), str(root)],
                              env=dict(os.environ, J='1'), capture_output=True, text=True)


class PkzTests(unittest.TestCase):
    def test_inventory_preserves_unknown_methods_without_decoding(self):
        b = archive([('../same.dat', b'abc', 'OodleKraken'),
                     ('../same.dat', b'defgh', 'FutureCodec')])
        members = pkz.index_entries(b)
        self.assertEqual([m.name for m in members], ['../same.dat', '../same.dat'])
        self.assertEqual([m.compression for m in members], ['OodleKraken', 'FutureCodec'])
        self.assertEqual([m.size for m in members], [3, 5])
        first = 32 + 2 * 32 + len(b'../same.dat\0OodleKraken\0../same.dat\0FutureCodec\0')
        self.assertEqual([m.offset for m in members], [first, first + 3])
        self.assertEqual([m.stored for m in members], [3, 5])
        with self.assertRaises(pkz.FormatError):
            pkz.entries(b)
        for member in members:
            with self.subTest(method=member.compression), self.assertRaises(pkz.FormatError):
                pkz.read(b, member, lambda *_: self.fail('Unknown methods must not decode'))

    def test_inventory_keeps_all_index_validation(self):
        original = archive([('x.dat', b'abc', 'OodleKraken')])
        cases = [original[:12], original[:-1]]
        for at, fmt, value in ((8, '<Q', len(original) + 1), (20, '<I', 0xffffffff),
                               (24, '<I', 0xffffffff), (32, '<I', 0xffffffff),
                               (36, '<I', 0xffffffff), (40, '<Q', pkz.MAX_MEMBER + 1),
                               (48, '<Q', 32), (56, '<Q', len(original))):
            changed = bytearray(original)
            struct.pack_into(fmt, changed, at, value)
            cases.append(changed)
        for i, data in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(pkz.FormatError):
                pkz.index_entries(data)
        stored = bytearray(archive([('x.dat', b'abc', 'None')]))
        struct.pack_into('<Q', stored, 40, 4)
        with self.assertRaises(pkz.FormatError):
            pkz.index_entries(stored)
        for method in ('OodleKraken\n', ''):
            with self.subTest(method=method), self.assertRaises(pkz.FormatError):
                pkz.index_entries(archive([('x.dat', b'abc', method)]))

    def test_inventory_cli_is_deterministic_and_never_extracts_members(self):
        data = archive([('../outside.dat', b'abc', 'OodleKraken'),
                        ('../outside.dat', b'defg', 'None')])
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / 'input'; root.mkdir()
            (root / 'resource.bin').write_bytes(data)
            (root / 'ordinary.txt').write_text('ordinary data')
            outputs = []
            for name in ('one.json', 'two.json'):
                out = Path(td) / name
                result = subprocess.run([sys.executable, pkz_inventory.__file__, str(root),
                                         '--output', str(out)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                outputs.append(out.read_bytes())
            self.assertEqual(outputs[0], outputs[1])
            report = json.loads(outputs[0])
            self.assertFalse(report['contentDecoded'])
            self.assertEqual(report['summary'], dict(archives=1, members=2,
                             compressionMembers={'None': 1, 'OodleKraken': 1}))
            item = report['archives'][0]
            self.assertEqual(item['path'], 'resource.bin')
            self.assertEqual(item['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual([m['index'] for m in item['members']], [0, 1])
            self.assertEqual([m['size'] for m in item['members']], [3, 4])
            self.assertEqual(set(p.name for p in root.iterdir()), {'resource.bin', 'ordinary.txt'})
            self.assertFalse((Path(td) / 'outside.dat').exists())
            self.assertNotIn(str(root), outputs[0].decode())

    def test_inventory_cli_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as td:
            source, out = Path(td) / 'input.pkz', Path(td) / 'result.json'
            source.write_bytes(archive([('a.dat', b'a', 'None')]))
            out.write_text('keep existing')
            result = subprocess.run([sys.executable, pkz_inventory.__file__, str(source),
                                     '--output', str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(out.read_text(), 'keep existing')

    def test_inventory_cli_bad_archive_has_no_success_output(self):
        with tempfile.TemporaryDirectory() as td:
            root, out = Path(td) / 'input', Path(td) / 'result.json'
            root.mkdir()
            (root / 'a.pkz').write_bytes(archive([('a.dat', b'a', 'None')]))
            (root / 'b.pkz').write_bytes(b'pkzl' + bytes(28))
            result = subprocess.run([sys.executable, pkz_inventory.__file__, str(root),
                                     '--output', str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(out.exists())

    def test_inventory_empty_or_non_pkz_input_fails(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with self.assertRaises(ValueError):
                pkz_inventory.inventory(root)
            source = root / 'ordinary.bin'; source.write_bytes(b'not PKZ')
            with self.assertRaises(pkz.FormatError):
                pkz_inventory.inventory(source)

    def test_roundtrip_and_runtime_key(self):
        for method in ('None', 'ZStandard'):
            for stage in ('vs', 'ps', 'cs', 'gs', 'hs', 'ds'):
                with self.subTest(method=method, stage=stage):
                    record, ctl, code = shader(stage)
                    b = archive([('unknown.resource', dat([('entry.bin', record)]), method)])
                    rows, blobs, stat = scan(b)
                    expected = hashlib.sha256(ctl + code).hexdigest()[:16]
                    self.assertEqual([(r[0], r[1]) for r in rows], [(expected, stage)])
                    self.assertEqual(blobs, {expected: (code, ctl)})
                    self.assertEqual(stat['PKZ/DAT 着色器'], 1)
                    self.assertFalse(stat['【红】PKZ/DAT 解析失败'])

    def test_variable_control_lengths(self):
        for size in (2001, 2104, 2128, 2176):
            with self.subTest(size=size):
                record, ctl, code = shader(control_size=size)
                self.assertEqual(pkz.shader(record), ('vs', ctl, code))

    def test_duplicate_names_preserve_records_and_deduplicate_blobs(self):
        a, _, _ = shader()
        b, _, _ = shader(seed=2)
        rows, blobs, stat = scan(archive([('different.dat', dat([
            ('same.vso', a), ('same.vso', a), ('same.vso', b)]), 'None')]))
        self.assertEqual((len(rows), len(blobs)), (3, 2))
        self.assertEqual(len({r[2] for r in rows}), 3)
        self.assertEqual(stat['DAT 成员'], 3)

    def test_nested_containers_and_empty_dat(self):
        a, _, _ = shader('cs')
        rows, _, stat = scan(archive([('outer.bin', dat([
            ('nested.dat', dat([('other.cso', a)])), ('empty.dat', dat([]))]), 'ZStandard')]))
        self.assertEqual([r[1] for r in rows], ['cs'])
        self.assertEqual(stat['DAT'], 3)

    def test_empty_dat_member_has_zero_offset(self):
        a, _, _ = shader()
        b = bytearray(dat([('absent.bin', b''), ('present.vso', a)]))
        struct.pack_into('<I', b, 32, 0)
        rows, _, stat = scan(bytes(b))
        self.assertEqual(len(rows), 1)
        self.assertEqual(stat['DAT 空成员'], 1)
        self.assertFalse(stat['【红】PKZ/DAT 解析失败'])

    def test_nesting_limit_fails(self):
        a, _, _ = shader()
        for _ in range(7):
            a = dat([('nested.dat', a)])
        rows, _, stat = scan(a)
        self.assertFalse(rows)
        self.assertEqual(stat['【红】PKZ/DAT 解析失败'], 1)

    def test_corrupt_pkz(self):
        a, _, _ = shader()
        original = archive([('a.vso', a, 'None')])
        cases = []
        for at, fmt, value in ((8, '<Q', len(original) - 1), (16, '<I', 0xffffffff),
                               (20, '<I', 0), (24, '<I', 0xffffffff),
                               (32, '<I', 0xffffffff), (36, '<I', 0xffffffff),
                               (40, '<Q', pkz.MAX_MEMBER + 1),
                               (48, '<Q', len(original)), (48, '<Q', 32),
                               (56, '<Q', len(original))):
            b = bytearray(original); struct.pack_into(fmt, b, at, value); cases.append(b)
        cases.extend((original[:12], original[:-1]))
        for i, b in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(pkz.FormatError):
                pkz.entries(b)

    def test_unknown_compression_and_bad_strings(self):
        a, _, _ = shader()
        for method in ('Oodle', 'ZStandard\n'):
            with self.subTest(method=method), self.assertRaises(pkz.FormatError):
                pkz.entries(archive([('a.vso', a, method)]))
        original = bytearray(archive([('a.vso', a, 'None')]))
        for offset, value in ((64, 0xff), (64, 10), (74, 1)):
            b = original.copy(); b[offset] = value
            with self.subTest(offset=offset), self.assertRaises(pkz.FormatError):
                pkz.entries(b)

    def test_bad_zstd_or_output_size_fails(self):
        a, _, _ = shader()
        original = archive([('a.vso', a, 'ZStandard')])
        for delta in (-1, 1):
            b = bytearray(original)
            struct.pack_into('<Q', b, 40, len(a) + delta)
            self.assertEqual(scan(b)[2]['【红】PKZ/DAT 解析失败'], 1)
        b = bytearray(original); b[-1] ^= 0xff
        self.assertEqual(scan(b)[2]['【红】PKZ/DAT 解析失败'], 1)

    def test_zstd_frame_without_content_size(self):
        z = X._zstd_lib()
        z.ZSTD_createCCtx.restype = ctypes.c_void_p
        z.ZSTD_freeCCtx.argtypes = [ctypes.c_void_p]
        z.ZSTD_CCtx_setParameter.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        z.ZSTD_CCtx_setParameter.restype = ctypes.c_size_t
        z.ZSTD_compress2.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                    ctypes.c_void_p, ctypes.c_size_t]
        z.ZSTD_compress2.restype = ctypes.c_size_t
        a, _, _ = shader()
        context = z.ZSTD_createCCtx()
        self.assertTrue(context)
        try:
            # ZSTD_c_contentSizeFlag = 200（Zstandard 公开 API），0 = 帧头不记录原长。
            result = z.ZSTD_CCtx_setParameter(context, 200, 0)
            self.assertFalse(z.ZSTD_isError(result))
            buf = ctypes.create_string_buffer(len(a) * 2)
            n = z.ZSTD_compress2(context, buf, len(buf), a, len(a))
            self.assertFalse(z.ZSTD_isError(n))
            self.assertGreaterEqual(z.ZSTD_getFrameContentSize(buf, n), 1 << 62)
            self.assertEqual(X.pkz_zstd(buf.raw[:n], len(a)), a)
        finally:
            z.ZSTD_freeCCtx(context)

    def test_corrupt_dat(self):
        a, _, _ = shader()
        original = dat([('a.vso', a)])
        cases = [original[:15], original[:-1]]
        for at, value in ((4, 0xffffffff), (8, 0), (12, len(original)),
                          (16, len(original)), (20, len(original)),
                          (32, 32), (40, 0xffffffff)):
            b = bytearray(original); struct.pack_into('<I', b, at, value); cases.append(b)
        b = bytearray(original); b[36:40] = b'pso\0'; cases.append(b)
        for i, b in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(pkz.FormatError):
                pkz.dat_entries(b)

    def test_bad_shader_layout(self):
        record, _, _ = shader()
        for at, value in ((8, 1), (12, 23), (16, 0xffffffff), (20, 24),
                          (24 + 0x20, 1), (24 + 0x704, 1),
                          (24 + 0x700, 0xffffffff), (24 + 2001 + 0x30, 5 << 10)):
            b = bytearray(record); struct.pack_into('<I', b, at, value)
            with self.subTest(offset=at), self.assertRaises(pkz.FormatError):
                pkz.shader(b)
        with self.assertRaises(pkz.FormatError): pkz.shader(record[:-1])
        cs, _, _ = shader('cs')
        b = bytearray(cs); struct.pack_into('<I', b, 24 + 0x748, 0)
        with self.assertRaises(pkz.FormatError): pkz.shader(b)

    def test_compute_with_header(self):
        # 带 0x12345679 头的计算代码区（猎天使魔女3 .cso 形态）：头 4 字节 + 到 +0x100 全零，指令从 +0x100 起
        record, ctl, _ = shader('cs')
        co = 24 + len(ctl)
        code = bytearray(0x180); code[:4] = bytes.fromhex('79563412')
        struct.pack_into('<Q', code, 0x100, 0xe30000000007000f)
        good = bytes(record[:co]) + bytes(code)
        self.assertEqual(pkz.shader(good), ('cs', ctl, bytes(code)))
        bad = bytearray(good); bad[co + 0x40] = 1   # 头区有非零 = 指令起点不在 +0x100
        with self.assertRaises(pkz.FormatError): pkz.shader(bytes(bad))
        gfx = bytearray(good); gfx[co:co + 4] = bytes.fromhex('78563412')   # 计算阶段带图形头
        with self.assertRaises(pkz.FormatError): pkz.shader(bytes(gfx))

    def test_large_pkz_uses_index_not_blind_split(self):
        record, _, _ = shader()
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'renamed.bin'
            data = bytearray(archive([('a.vso', record, 'None')]))
            struct.pack_into('<Q', data, 8, X.BIG + 1)
            p.write_bytes(data)
            with p.open('r+b') as f: f.truncate(X.BIG + 1)
            self.assertFalse(X.big_split(p))
            out = Path(td) / 'out'; (out / 'src').mkdir(parents=True)
            rows, stat = X.work((td, [str(p)], str(out)))
            self.assertEqual(len(rows), 1)
            self.assertEqual(stat['PKZ'], 1)

    def test_cli_failure_is_not_success(self):
        run = cli(b'pkzl' + bytes(28))
        # v0.3.1 拿不准不停：解析失败的 PKZ / DAT 跳过、记降级（原先退 1 整款停），红行照打
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('【红】PKZ/DAT', run.stderr)
        self.assertIn('【黄】抽取：跳过读不了的部分（PKZ/DAT 解析失败 1）', run.stderr)

    def test_non_pkz_magic_collisions_preserve_original_scan(self):
        _, ctl, code = shader('ps')
        key = hashlib.sha256(ctl + code).hexdigest()[:16]
        for magic in (*pkz.STAGES, b'DAT\0'):
            # 普通数据头碰巧撞魔数，后面的合法相邻对仍须走原扫描。
            data = magic + bytes(range(64)) + ctl + code
            for wrap in (bytes, sarc):
                with self.subTest(magic=magic, wrap=wrap.__name__):
                    rows, blobs, stat = scan(wrap(data))
                    self.assertEqual([r[0] for r in rows], [key])
                    self.assertEqual(blobs, {key: (code, ctl)})
                    self.assertFalse(stat['【红】PKZ/DAT 解析失败'])

    def test_pkz_member_magic_collisions_remain_fatal(self):
        for magic in (*pkz.STAGES, b'DAT\0'):
            data = magic + bytes(range(64))
            for wrap in (bytes, sarc, gzip.compress):
                with self.subTest(magic=magic, wrap=wrap.__name__):
                    rows, _, stat = scan(archive([('arbitrary.bin', wrap(data), 'None')]))
                    self.assertFalse(rows)
                    self.assertEqual(stat['【红】PKZ/DAT 解析失败'], 1)

    def test_dat_members_enable_shader_wrapper_parsing(self):
        data = b'PSO\0' + bytes(range(64))
        rows, _, stat = scan(dat([('arbitrary.bin', data)]))
        self.assertFalse(rows)
        self.assertEqual(stat['【红】PKZ/DAT 解析失败'], 1)

    def test_cli_magic_collision_depends_on_container_context(self):
        for magic in (b'PSO\0', b'DAT\0'):
            data = magic + bytes(range(64))
            for wrap, status in ((bytes, 0), (sarc, 0),
                                 (lambda b: archive([('arbitrary.bin', b, 'None')]), 1)):
                with self.subTest(magic=magic, wrap=wrap.__name__):
                    run = cli(wrap(data))
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)   # v0.3.1：解析失败也退 0、跳过记降级
                    if status:
                        self.assertIn('【红】PKZ/DAT 解析失败', run.stdout)
                        self.assertIn('【红】PKZ/DAT', run.stderr)
                    else:
                        self.assertNotIn('【红】PKZ/DAT 解析失败', run.stdout)
                        self.assertNotIn('【红】PKZ/DAT', run.stderr)


if __name__ == '__main__':
    unittest.main()
