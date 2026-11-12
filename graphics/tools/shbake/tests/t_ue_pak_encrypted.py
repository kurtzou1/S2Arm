"""Synthetic PAK bytes + OpenSSL encryption, independent of the reader under test."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

H = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(H))
import pak_crypto
import unreal_pak as ue_pak
import nxsh_extract
import srcpack   # S2Arm 抽取的着色器字节（src/*.pk）

KEY = bytes(range(32))  # Public synthetic fixture, never a game key.


def pad(b): return b + bytes(-len(b) % 16)
def fstr(s):
    b = s.encode() + b'\0'
    return struct.pack('<i', len(b)) + b
def encrypt(b, key=KEY):
    return subprocess.run(['/usr/bin/openssl', 'enc', '-aes-256-ecb', '-K', key.hex(), '-nopad'],
                          input=pad(b), check=True, capture_output=True).stdout


def nso(key=KEY):
    # ADRP X8, page 1; LDR Q0,[X8]; ADRP X9,page 2; LDR Q1,[X9,#32];
    # STP Q0,Q1,[X0]; RET. Nonadjacent constants, plus a gap between NSO segments.
    text = bytes.fromhex('080000b00001c03d090000d02109c03d000400adc0035fd6')
    ro = bytearray(0x1030); ro[:16] = key[:16]; ro[0x1020:0x1030] = key[16:]
    head = bytearray(256); head[:4] = b'NSO0'
    for i, (fo, mo, b) in enumerate([(256, 0, text), (256 + len(text), 4096, ro), (256 + len(text) + len(ro), 12288, b'')]):
        struct.pack_into('<III', head, 0x10 + i * 16, fo, mo, len(b))
        struct.pack_into('<I', head, 0x60 + 4 * i, len(b))
    return bytes(head) + text + ro


def shader_record():
    ctl = bytearray(0x710); ctl[:8] = bytes.fromhex('3412769801000000')
    struct.pack_into('<I', ctl, 0x20, len(ctl)); struct.pack_into('<II', ctl, 0x700, 0x100, 0x100)
    code = bytearray(0x100); code[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', code, 0x30, 1 << 10)
    struct.pack_into('<Q', code, 0x80, 0xe30000000007000f); struct.pack_into('<Q', code, 0xf8, 0x50b0000000070f00)
    return b'LSLGSV' + struct.pack('<I', len(code)) + code + struct.pack('<I', len(ctl)) + ctl, bytes(ctl), bytes(code)


def shader_archive(raw, compressed=True, freq=0, stored=None):
    import lz4.block
    stored = stored if stored is not None else lz4.block.compress(raw, store_size=False) if compressed else raw
    head = struct.pack('<II', 2, 1) + bytes(20) + struct.pack('<I', 1) + bytes(20)
    head += struct.pack('<IIIIII', 1, 0, 1, 0, 0, 1) + struct.pack('<QIIB', 0, len(stored), len(raw), freq)
    return head + struct.pack('<III', 0, 1, 0) + stored


def make_pak(path, files, encrypted=True, compressed=False, ver=11, encrypted_files=None):
    body = bytearray(); encoded = bytearray(); directory = []
    for name, raw in files:
        off = len(body); crypt = int(encrypted if encrypted_files is None else name in encrypted_files)
        zs = [zlib.compress(raw[i:i + 65536]) for i in range(0, len(raw), 65536)] if compressed else []
        hdr = bytes(53 + (4 + 16 * len(zs) if compressed else 0))
        body += hdr
        body += b''.join(encrypt(z) if crypt else z for z in zs) if compressed else (encrypt(raw) if crypt else raw)
        bits = (1 << 31) | (1 << 30) | (1 << 29) | (crypt << 22)
        if compressed:
            bits |= (65536 >> 11) | (len(zs) << 6) | (1 << 23)
        e = struct.pack('<III', bits, off, len(raw))
        if compressed:
            e += struct.pack('<I', sum(map(len, zs)))
            if len(zs) > 1 or crypt: e += b''.join(struct.pack('<I', len(z)) for z in zs)
        directory.append((name, len(encoded))); encoded += e
    fd = struct.pack('<i', 1) + fstr('Game/') + struct.pack('<i', len(files)) + b''.join(fstr(n) + struct.pack('<i', off) for n, off in directory)
    if encrypted: fd = pad(fd)
    fdo = len(body); body += encrypt(fd) if encrypted else fd
    index = fstr('../../../') + struct.pack('<iQi', len(files), 0, 0)
    index += struct.pack('<iQQ', 1, fdo, len(fd)) + hashlib.sha1(fd).digest()
    index += struct.pack('<i', len(encoded)) + encoded + struct.pack('<i', 0)
    if encrypted: index = pad(index)
    io = len(body); body += encrypt(index) if encrypted else index
    footer = bytes(16) + bytes([encrypted]) + struct.pack('<IIQQ', 0x5A6F12E1, ver, io, len(index))
    footer += hashlib.sha1(index).digest() + b'Zlib'.ljust(32, b'\0') + bytes(128)
    path.write_bytes(body + footer)


class EncryptedPakTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.p = self.root / 'test.pak'
    def opened(self, **kw):
        pk = ue_pak.Pak(self.p, **kw); self.addCleanup(pk.close); return pk
    def test_nist_aes256_vector(self):
        key = bytes.fromhex('603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4')
        self.assertEqual(pak_crypto.aes_ecb(key, bytes.fromhex('f3eed1bdb5d2a03c064b5a7e3db181f8')), bytes.fromhex('6bc1bee22e409f96e93d7e117393172a'))
    def test_split_vector_constants_with_virtual_gap(self):
        make_pak(self.p, [('plain.bin', b'not block aligned')])
        pk = self.opened(images=[nso()])
        self.assertEqual(pk.read(pk.files[0][1]), b'not block aligned')
    def test_encrypted_zlib_multiple_blocks(self):
        raw = bytes(range(251)) * 900
        make_pak(self.p, [('many.bin', raw)], compressed=True)
        pk = self.opened(images=[nso()]); self.assertEqual(pk.read(pk.files[0][1]), raw)
    def test_v10_same_encrypted_layout(self):
        make_pak(self.p, [('v10.bin', b'v10')], ver=10)
        pk = self.opened(key=KEY); self.assertEqual(pk.read(pk.files[0][1]), b'v10')
    def test_wrong_key_rejected(self):
        make_pak(self.p, [('x', b'body')])
        with self.assertRaisesRegex(ue_pak.Corrupt, 'SHA-1'): self.opened(key=bytes(32))
    def test_missing_key_rejected(self):
        make_pak(self.p, [('x', b'body')])
        with self.assertRaisesRegex(ue_pak.Unsupported, '索引加密'): self.opened()
    def test_primary_index_corruption(self):
        make_pak(self.p, [('x', b'body')]); b = bytearray(self.p.read_bytes())
        off, = struct.unpack_from('<Q', b, len(b) - 221 + 25); b[off] ^= 1; self.p.write_bytes(b)
        with self.assertRaises(ue_pak.Corrupt): self.opened(key=KEY)
    def test_directory_index_corruption(self):
        make_pak(self.p, [('x', b'body')]); b = bytearray(self.p.read_bytes()); b[53 + 16] ^= 1; self.p.write_bytes(b)
        with self.assertRaisesRegex(ue_pak.Corrupt, 'SHA-1'): self.opened(key=KEY)
    def test_truncated_footer(self):
        make_pak(self.p, [('x', b'body')]); self.p.write_bytes(self.p.read_bytes()[:180])
        with self.assertRaises(ue_pak.Corrupt): self.opened(key=KEY)
    def test_unencrypted_path(self):
        make_pak(self.p, [('clear', b'unchanged')], encrypted=False)
        pk = self.opened(); self.assertEqual(pk.read(pk.files[0][1]), b'unchanged')
    def test_unencrypted_index_with_encrypted_entry_cli(self):
        raw, ctl, code = shader_record()
        romfs = self.root / 'romfs'; romfs.mkdir()
        for ver in (10, 11):
            for compressed in (False, True):
                with self.subTest(ver=ver, compressed=compressed):
                    make_pak(romfs / 'g.pak', [('clear.ushaderbytecode', shader_archive(raw)),
                                             ('locked.bin', b'private synthetic entry')],
                             encrypted=False, compressed=compressed, ver=ver, encrypted_files={'locked.bin'})
                    out = self.root / f'out-{ver}-{compressed}'
                    p = subprocess.run([sys.executable, str(H / 'nxsh_extract.py'), str(out), str(romfs)],
                                       capture_output=True, text=True, env=dict(os.environ, J='2'), timeout=30)
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertIn("'pak 条目不支持：条目加密': 1", p.stdout)
                    self.assertNotIn('【红】', p.stdout + p.stderr)
                    key = hashlib.sha256(ctl + code).hexdigest()[:16]
                    self.assertEqual(srcpack.Src(str(out)).get(key)[0], code)
                    self.assertNotIn(KEY.hex(), p.stdout + p.stderr)
    def test_zero_key_and_last_literal_window(self):
        index = pad(fstr('../../../') + bytes(32))
        cipher = encrypt(index, bytes(32))
        self.assertEqual(pak_crypto.find_key(b'prefix!!' + bytes(32), cipher, hashlib.sha1(index).digest()), bytes(32))
    def test_hash_required_for_constructed_candidate(self):
        index = pad(fstr('../../../') + bytes(32)); cipher = encrypt(index)
        self.assertIsNone(pak_crypto.find_key(nso(), cipher, bytes(20)))
    def test_bad_aes_lengths(self):
        with self.assertRaises(ValueError): pak_crypto.aes_ecb(KEY, bytes(15))
        with self.assertRaises(ValueError): pak_crypto.aes_ecb(KEY[:16], bytes(16))
    def test_cli_workers_and_missing_key(self):
        ctl = bytearray(0x710); ctl[:8] = bytes.fromhex('3412769801000000')
        struct.pack_into('<I', ctl, 0x20, len(ctl)); struct.pack_into('<I', ctl, 0x704, 0x100)
        code = bytearray(0x100); code[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', code, 0x30, 1 << 10)
        romfs = self.root / 'romfs'; romfs.mkdir(); make_pak(romfs / 'g.pak', [('test.bin', bytes(ctl) + code)])
        main = self.root / 'main'; main.write_bytes(nso())
        command = [sys.executable, str(H / 'nxsh_extract.py'), str(self.root / 'out'), str(romfs)]
        p = subprocess.run(command + ['--nso', str(main)], capture_output=True, text=True, env=dict(os.environ, J='2'))
        self.assertEqual(p.returncode, 0, p.stderr)
        expected = hashlib.sha256(ctl + code).hexdigest()[:16]
        self.assertIn(expected, srcpack.Src(str(self.root / 'out')))
        self.assertNotIn(KEY.hex(), p.stdout + p.stderr)
        p = subprocess.run(command[:2] + [str(self.root / 'bad'), str(romfs)], capture_output=True, text=True, env=dict(os.environ, J='1'))
        # v0.3.1 拿不准不停：索引读不到的 pak 跳过、记降级（原先退 1 整款停），逐条红行照打
        self.assertEqual(p.returncode, 0, p.stderr); self.assertIn('【红】pak 索引加密', p.stderr); self.assertIn('【黄】抽取：跳过读不了的部分', p.stderr)
        self.assertIn('extract\ts2x:pak 索引加密\t1', (self.root / 'bad' / 'degrade.tsv').read_text(encoding='utf-8'))
    def test_pack_cli_auto_main_and_explicit_main(self):
        romfs = self.root / 'romfs'; romfs.mkdir(); exefs = self.root / 'exefs'; exefs.mkdir()
        (exefs / 'main').write_bytes(nso())
        raw = b'LSLGS' + b'synthetic-shader' * 8
        archive = struct.pack('<II', 2, 1) + bytes(20) + struct.pack('<I', 1) + bytes(20)
        archive += struct.pack('<IIIIII', 1, 0, 1, 0, 0, 1) + struct.pack('<QIIB', 0, len(raw), len(raw), 0)
        archive += struct.pack('<III', 0, 1, 0) + raw
        make_pak(romfs / 'g.pak', [('ShaderArchive-Test.ushaderbytecode', archive)])
        tool = H.parents[2] / 'pack/ue_pak.py'
        for i, extra in enumerate([[], ['--main', str(exefs / 'main')]]):
            out = self.root / f'pack{i}'
            p = subprocess.run([sys.executable, str(tool), str(romfs), str(out)] + extra, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual((out / 'ShaderArchive-Test.ushaderbytecode').read_bytes(), archive)
    def test_pack_cli_auto_main_romfs_store_symlink(self):
        # 11-04 普查 c1104_r2：a25bf3785 起产物根的 romfs 是指向 $S2A_ROOTS/.romfs_store/<款>/<身份>/ 的相对软链（pack/roots.sh），
        #   不带 --main 时 main 必须取「产物根/exefs/main」，不能顺软链取到存储目录旁（那里没有 exefs/main → 索引加密报红，电光炸裂 / 小小梦魇3）
        store = self.root / '.romfs_store/g/id1'; store.mkdir(parents=True)
        root = self.root / 'g@v1'; (root / 'exefs').mkdir(parents=True); (root / 'exefs/main').write_bytes(nso())
        os.symlink(os.path.relpath(store, root), root / 'romfs')
        raw = b'LSLGS' + b'synthetic-shader' * 8
        archive = struct.pack('<II', 2, 1) + bytes(20) + struct.pack('<I', 1) + bytes(20)
        archive += struct.pack('<IIIIII', 1, 0, 1, 0, 0, 1) + struct.pack('<QIIB', 0, len(raw), len(raw), 0)
        archive += struct.pack('<III', 0, 1, 0) + raw
        make_pak(store / 'g.pak', [('ShaderArchive-Test.ushaderbytecode', archive)])
        out = self.root / 'out_store'
        p = subprocess.run([sys.executable, str(H.parents[2] / 'pack/ue_pak.py'), str(root / 'romfs'), str(out)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((out / 'ShaderArchive-Test.ushaderbytecode').read_bytes(), archive)
    def test_encrypted_shared_archive_cli(self):
        raw, ctl, code = shader_record()
        romfs = self.root / 'romfs'; romfs.mkdir()
        make_pak(romfs / 'g.pak', [('ShaderArchive-Test.ushaderbytecode', shader_archive(raw))])
        main = self.root / 'main'; main.write_bytes(nso())
        p = subprocess.run([sys.executable, str(H / 'nxsh_extract.py'), str(self.root / 'out'), str(romfs), '--nso', str(main)],
                           capture_output=True, text=True, env=dict(os.environ, J='2'))
        self.assertEqual(p.returncode, 0, p.stderr)
        key = hashlib.sha256(ctl + code).hexdigest()[:16]
        self.assertEqual(srcpack.Src(str(self.root / 'out')).get(key)[0], code)
        self.assertIn("'UE 存档条目': 1", p.stdout)
    def test_v7_encrypted_index_and_entry(self):
        raw = b'legacy encrypted body'
        entry = struct.pack('<qqqI', 0, len(raw), len(raw), 0) + bytes(20) + b'\1' + struct.pack('<I', 65536)
        body = entry + encrypt(raw)
        index = pad(fstr('../../../') + struct.pack('<i', 1) + fstr('legacy.bin') + entry)
        footer = bytes(16) + b'\1' + struct.pack('<IIQQ', 0x5A6F12E1, 7, len(body), len(index)) + hashlib.sha1(index).digest()
        self.p.write_bytes(body + encrypt(index) + footer)
        pk = self.opened(key=KEY); self.assertEqual(pk.read(pk.files[0][1]), raw)
    def test_archive_bad_stage_or_truncation_rejected(self):
        import collections
        raw, _, _ = shader_record()
        for data in (shader_archive(raw, freq=3), shader_archive(raw)[:-5]):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                nxsh_extract.scan_ue_archive('synthetic', data, [], {}, collections.Counter())
    def test_archive_legacy_layout(self):
        # 11-02 普查血污：无版本号旧布局（u32 条数 + 每条 32 字节 {哈希 20, 偏移, 存储长, 原长}，代码区紧跟、到文件尾），阶段只在记录的 LSLG 标签里；
        #   原先 scan_ue_archive 只认版本 2，整份报「着色器存档版本不支持」
        import collections, lz4.block
        raw, _, _ = shader_record(); blob = lz4.block.compress(raw, store_size=False)
        data = struct.pack('<I', 1) + bytes(20) + struct.pack('<3I', 0, len(blob), len(raw)) + blob
        rows, stat = [], collections.Counter()
        nxsh_extract.scan_ue_archive('synthetic', data, rows, {}, stat)
        self.assertEqual(([r[1] for r in rows], stat['UE 存档条目']), (['vs'], 1))
    def test_archive_v1_layout(self):
        # 11-02 普查 Minecraft Dungeons：版本 1（u32 1、u32 支数，每支 37 字节 {SHA-1 20, u64 偏移, u32 存储长, u32 原长, u8 阶段}，代码区紧跟、到文件尾），zlib 压缩；
        #   原先 ue_pak 报「着色器代码存档版本 1（只认 2，也不是无版本号的旧布局）」、scan_ue_archive 报「着色器存档版本不支持」
        import collections, importlib.util
        raw, _, _ = shader_record(); z = zlib.compress(raw)   # 第 1 支 zlib、第 2 支同一记录不压缩
        data = struct.pack('<II', 1, 2) + bytes(20) + struct.pack('<QIIB', 0, len(z), len(raw), 0) + bytes(20) + struct.pack('<QIIB', len(z), len(raw), len(raw), 0) + z + raw
        rows, stat = [], collections.Counter()
        nxsh_extract.scan_ue_archive('synthetic', data, rows, {}, stat)
        self.assertEqual((sorted(r[1] for r in rows), stat['UE 存档条目']), (['vs', 'vs'], 2))
        spec = importlib.util.spec_from_file_location('ue_pak_cli', str(H.parents[2] / 'pack/ue_pak.py')); M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
        b, n, nc = M.archive_rewrite(data)
        a = ue_pak.v1_layout(data); self.assertEqual((n, nc, a[0]), (2, 1, 8 + 37 * 2))
        self.assertIsNone(ue_pak.v1_layout(data[:-1]))   # 代码区少一字节：首尾相接对不上 → 不认（不猜）
    def test_archive_oodle_record_goes_to_game_decoder(self):
        # 11-02 霍格沃茨之遗：着色器存档里 Oodle 压缩的支原先按 LZ4 解，整份判红；改走与 pack/ue_pak.py 同一份解压（unreal_pak.unpack_shader）
        import collections
        raw, _, _ = shader_record(); blob = b'\x8c\x0a' + b'oodle-stub'   # Mermaid 块头 + 假载荷：解码交给传进来的游戏解码器
        seen = []
        def oodle(b, n): seen.append((bytes(b), n)); return raw
        rows, stat = [], collections.Counter()
        nxsh_extract.scan_ue_archive('synthetic', shader_archive(raw, stored=blob), rows, {}, stat, oodle=oodle)
        self.assertEqual((seen, len(rows), stat['UE 存档条目']), ([(blob, len(raw))], 1, 1))
        with self.assertRaisesRegex(ValueError, 'Oodle'):   # 没有游戏解码器：照实判红、写明是 Oodle
            nxsh_extract.scan_ue_archive('synthetic', shader_archive(raw, stored=blob), [], {}, collections.Counter())
    def test_bad_encrypted_archive_cli_fails(self):
        romfs = self.root / 'romfs'; romfs.mkdir()
        make_pak(romfs / 'g.pak', [('bad.ushaderbytecode', b'broken')])
        main = self.root / 'main'; main.write_bytes(nso())
        p = subprocess.run([sys.executable, str(H / 'nxsh_extract.py'), str(self.root / 'out'), str(romfs), '--nso', str(main)],
                           capture_output=True, text=True, env=dict(os.environ, J='1'))
        self.assertEqual(p.returncode, 0, p.stderr); self.assertIn('【红】pak 着色器存档', p.stderr); self.assertIn('【黄】抽取：跳过读不了的部分', p.stderr)   # v0.3.1：跳过、记降级


if __name__ == '__main__': unittest.main()
