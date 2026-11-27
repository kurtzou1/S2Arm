#!/usr/bin/env python3
"""pack/fn_match.py 单测（python3 tests/fn_match_test.py；tests/fn_match_test.sh 调）。
合成两版 NSO（不含任何游戏代码）：同一批函数在第二版里整体后移、adrp 指向的页也不同，期望值按指令编码手算。"""
import struct
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'pack'))
import fn_match as fm  # noqa: E402

RET, NOP = 0xd65f03c0, 0xd503201f


def bl(pc, target): return 0x94000000 | (((target - pc) >> 2) & 0x3ffffff)


def adrp(pc, target, rd):
    d = ((target & ~0xfff) - (pc & ~0xfff)) >> 12
    return 0x90000000 | ((d & 3) << 29) | (((d >> 2) & 0x7ffff) << 5) | rd


def nso(funcs, bid, shift=0, data_page=0x2000):
    """funcs: [(名, 起点, 生成器(起点, 地址表) → 指令字列表)]；返回 (NSO 字节, {名: 起点})"""
    addr = {n: s + shift for n, s, _ in funcs}
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
    for n, s, gen in funcs:
        code = gen(addr[n], addr, data_page)
        struct.pack_into(f'<{len(code)}I', text, addr[n], *code)
    ro = bytearray(0x1000)
    EH, EF = 0x100, 0x200
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x80)
    cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    ro[EF:EF + 0x18] = cie
    hdr = 0x1000 + EH
    struct.pack_into('<BBBBiI', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (hdr + 4), len(funcs))
    for i, (n, s, gen) in enumerate(sorted(funcs, key=lambda f: addr[f[0]])):
        f = 0x1000 + EF + 0x18 + i * 0x18
        size = 4 * len(gen(addr[n], addr, data_page))
        struct.pack_into('<IIii', ro, f - 0x1000, 0x10, (f + 4) - (0x1000 + EF), addr[n] - (f + 8), size)
        struct.pack_into('<ii', ro, EH + 12 + i * 8, addr[n] - hdr, f - hdr)
    data = bytes(0x1000)
    h = bytearray(0x100)
    h[:4] = b'NSO0'
    for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
        struct.pack_into('<III', h, 0x10 + 0x10 * k, 0x100 + 0x1000 * k, mo, len(seg))
        struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
    h[0x40:0x50] = bytes.fromhex(bid)
    return bytes(h + text + ro + data), addr


# f_add 与 f_dup 完全相同（都 bl f_five）；f_data 读数据段；f_uniq 独一份；f_call 在第二版里改调 f_seven
F = [
    ('f_add', 0x100, lambda pc, a, dp: [0x91000400, bl(pc + 4, a['f_five']), RET]),
    ('f_dup', 0x180, lambda pc, a, dp: [0x91000400, bl(pc + 4, a['f_five']), RET]),
    ('f_five', 0x200, lambda pc, a, dp: [0x528000a0, RET]),
    ('f_seven', 0x240, lambda pc, a, dp: [0x528000e0, RET]),
    ('f_data', 0x280, lambda pc, a, dp: [adrp(pc, dp + 0x10, 8), 0xb9400000 | (4 << 10) | (8 << 5), RET]),
    ('f_uniq', 0x300, lambda pc, a, dp: [0x52800021, NOP, 0x52800042, RET]),
    ('f_call', 0x380, lambda pc, a, dp: [0x52800063, bl(pc + 4, a['f_five']), RET]),
]
F2 = [f if f[0] != 'f_call' else ('f_call', 0x380, lambda pc, a, dp: [0x52800063, bl(pc + 4, a['f_seven']), RET]) for f in F]
B1, B2 = '11' * 16, '22' * 16


class FnMatch(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        raw1, self.a1 = nso(F, B1)
        raw2, self.a2 = nso(F2, B2, shift=0x40, data_page=0x2000)
        (self.tmp / 'v1').write_bytes(raw1); (self.tmp / 'v2').write_bytes(raw2)
        self.i1 = fm.Image(*fm.load_nso(self.tmp / 'v1')[:2])
        self.i2 = fm.Image(*fm.load_nso(self.tmp / 'v2')[:2])

    def rule(self, img, name, rows, group='g', checked=B1[:16]):
        s = self.a1[name] if img is self.i1 else self.a2[name]
        return '\n'.join([f'group {group}', f'checked {checked}',
                          f'match {name} main {img.functions[s]:#x} {img.fingerprint(s)}'] + rows + ['end']) + '\n'

    def test_eh_frame_boundaries(self):
        self.assertEqual(self.i2.functions[self.a2['f_uniq']], 16)
        self.assertEqual(self.i2.containing(self.a2['f_uniq'] + 8), self.a2['f_uniq'])

    def test_unique_hit_moves_with_function(self):
        # f_uniq 在第二版里后移 0x40：+0x4 处的 nop 换成 mov w2, #3
        text = self.rule(self.i1, 'f_uniq', [f'c main +0x4 word {NOP:08x} 52800062'])
        out, applied, log = fm.expand(text, self.i2, B2, 'fps')
        self.assertEqual(applied, ['g'])
        self.assertIn(f'c\tmain\t{self.a2["f_uniq"] + 4:#x}\tword\t{NOP:08x}\t52800062', out)
        self.assertIn(f'build {B2[:16]}', out)

    def test_adrp_page_masked(self):
        _, _, _ = fm.load_nso(self.tmp / 'v2')
        raw3, a3 = nso(F, B2, shift=0x40, data_page=0x3000)
        (self.tmp / 'v3').write_bytes(raw3)
        i3 = fm.Image(*fm.load_nso(self.tmp / 'v3')[:2])
        self.assertEqual(self.i1.fingerprint(self.a1['f_data']), i3.fingerprint(a3['f_data']))

    def test_zero_hit_not_applied(self):
        text = f'group g\nchecked {B1[:16]}\nmatch x main 0x10 {"0" * 64}\nc main +0x4 word {NOP:08x} 52800062\nend\n'
        out, applied, log = fm.expand(text, self.i2, B2, 'fps')
        self.assertIsNone(out); self.assertEqual(applied, [])
        self.assertTrue(any('没找到' in l and '【黄】' in l for l in log))

    def test_duplicate_red(self):
        text = self.rule(self.i1, 'f_add', ['c main +0x0 word 91000400 91000800'])
        out, applied, log = fm.expand(text, self.i2, B2, 'fps')
        self.assertIsNone(out)
        self.assertTrue(any('不唯一' in l and '【红】' in l for l in log))
        with self.assertRaises(fm.MatchError):
            fm.derive(f'c main {self.a1["f_add"]:#x} word 91000400 91000800\n', self.i1, B1[:16])

    def test_group_all_or_nothing(self):
        ok = self.rule(self.i1, 'f_uniq', [f'c main +0x4 word {NOP:08x} 52800062']).splitlines()
        text = '\n'.join(ok[:-1] + [f'match x main 0x10 {"0" * 64}', 'end']) + '\n'
        out, applied, _ = fm.expand(text, self.i2, B2, 'fps')
        self.assertIsNone(out); self.assertEqual(applied, [])

    def test_original_word_mismatch_red(self):
        text = self.rule(self.i1, 'f_uniq', ['c main +0x4 word 12345678 52800062'])
        out, applied, log = fm.expand(text, self.i2, B2, 'fps')
        self.assertIsNone(out)
        self.assertTrue(any('原字' in l and '【红】' in l for l in log))

    def test_callee_change_breaks_fingerprint(self):
        self.assertNotEqual(self.i1.fingerprint(self.a1['f_call']), self.i2.fingerprint(self.a2['f_call']))
        self.assertEqual(self.i1.body(self.a1['f_call'])[0], self.i2.body(self.a2['f_call'])[0])   # 函数体本身归一化后相同

    def test_fix_reports_unchecked_build(self):
        text = self.rule(self.i1, 'f_uniq', [f'c main +0x4 word {NOP:08x} 52800062'])
        out, applied, log = fm.expand(text, self.i2, B2, 'fix')
        self.assertIsNone(out)
        self.assertTrue(any('没核过' in l for l in log))
        out, applied, _ = fm.expand(text.replace(f'checked {B1[:16]}', f'checked {B1[:16]} {B2[:16]}'), self.i2, B2, 'fix')
        self.assertEqual(applied, ['g'])
        self.assertNotIn('build ', out)

    def test_bl_token_relocated(self):
        five = self.a1['f_five']
        body = f'c main +0xc veneer {RET:08x} 52800000 bl:@f_five+0x0'   # f_uniq 的第 4 条（ret）
        text = '\n'.join(['group g', f'checked {B1[:16]}',
                          f'match f_uniq main {self.i1.functions[self.a1["f_uniq"]]:#x} {self.i1.fingerprint(self.a1["f_uniq"])}', body,
                          f'match f_five main {self.i1.functions[five]:#x} {self.i1.fingerprint(five)}', 'end']) + '\n'
        out, _, _ = fm.expand(text, self.i2, B2, 'fps')
        self.assertIn(f'bl:{self.a2["f_five"]:x}', out)

    def test_derive_roundtrip_identical(self):
        u, five = self.a1['f_uniq'], self.a1['f_five']
        table = (f'build {B1[:16]}\npresent display\n'
                 f'c main {u + 4:#x} word {NOP:08x} 52800062   # 换一条\n'
                 f'c main {u + 12:#x} veneer {RET:08x} 52800000 bl:{five:x}\n')
        rules = fm.derive(table, self.i1, B1[:16])
        back, applied, _ = fm.expand(rules, self.i1, B1, 'fps')
        want = sorted(l.split('#')[0].split() for l in table.splitlines() if l.startswith('c '))
        have = sorted(l.split('#')[0].split() for l in back.splitlines() if l.startswith('c'))
        self.assertEqual(want, have)
        self.assertIn('present display', back)
        moved, _, _ = fm.expand(rules, self.i2, B2, 'fps')
        self.assertIn(f'c\tmain\t{self.a2["f_uniq"] + 4:#x}\tword', moved)
        self.assertIn(f'bl:{self.a2["f_five"]:x}', moved)

    def test_w_rows_refused(self):
        with self.assertRaises(fm.MatchError):
            fm.derive(f'w main 0x2010 f32 60\nc main {self.a1["f_uniq"] + 4:#x} word {NOP:08x} 52800062\n', self.i1, B1[:16])

    def test_tables_exact_first_and_when(self):
        repo = self.tmp / 'repo'
        for k in ('fix', 'fps'): (repo / f'runtime/{k}/match').mkdir(parents=True)
        pid = '0100ABCD00000000'
        (repo / f'runtime/fix/match/{pid}.tsv').write_text(
            self.rule(self.i1, 'f_uniq', [f'c main +0x4 word {NOP:08x} 52800062'], group='step', checked=f'{B1[:16]} {B2[:16]}'))
        (repo / f'runtime/fps/match/{pid}.tsv').write_text('when fix step\nspeed 2040 0.5 2.0 2041\n')
        fix, fps, log = fm.tables(pid, self.tmp / 'v2', self.tmp / 'work', repo)
        self.assertEqual(fix.name, 'fn_match_fix.tsv'); self.assertEqual(fps.name, 'fn_match_fps.tsv')
        self.assertIn('speed 2040', fps.read_text()); self.assertIn(f'build {B2[:16]}', fps.read_text())
        (repo / f'runtime/fix/{B2[:16]}.tsv').write_text('# 精确表\n')
        fix, fps, log = fm.tables(pid, self.tmp / 'v2', self.tmp / 'work2', repo)
        self.assertEqual(fix, repo / f'runtime/fix/{B2[:16]}.tsv')
        self.assertIsNone(fps)   # 修补组没走规则（精确表优先），跟随它的步长行不随包
        self.assertTrue(any('精确表' in l for l in log))


if __name__ == '__main__':
    unittest.main(verbosity=2)
