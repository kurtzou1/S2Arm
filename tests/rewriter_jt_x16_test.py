#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 S2Arm contributors
"""x16/x17 跳转表单测：合成 NSO，走真 CLI，期望按 AArch64 编码和分派块布局手算。
形态取自 DQB2 main 0x3fb06c（目标集识别认不出，改前记 br_x18 缺口、整包失败）：
  adrp x18 / add x18,#0x800 / cmp wI,#3 / b.hi out / ldrsw x17,[x18,xI,lsl#2] / add x18,x17,x18 / [mov w17,w16] / br x18
  真实形态：I=T=x17，中间有 mov w17,w16（写表项寄存器 → 落点不写 x17）→ 分派块借 x9/x10
  变体：I=x9，无中间指令（落点要把表项写回 x17）→ x9 是下标，分派块改借 x10/x11
  #716：中间夹 adrp x0（与位置有关）→ 搬进补丁区按原目标重算
  反例：表第 3 项指到函数外 → 仍记缺口、退出码 3
"""
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

CLI = str(Path(sys.argv.pop(1)).resolve())
TBL = 0x1800
ADRP_X18 = 0xb0000012          # at 0x100，页 0x1000：immlo=1
ADD_X18_LO = 0x91200252        # add x18,x18,#0x800
CMP_W17 = 0x71000e3f           # cmp w17,#3
CMP_W9 = 0x71000d3f            # cmp w9,#3
LDRSW_I17 = 0xb8b17a51         # ldrsw x17,[x18,x17,lsl#2]
LDRSW_I9 = 0xb8a97a51          # ldrsw x17,[x18,x9,lsl#2]
ADD_X18 = 0x8b120232           # add x18,x17,x18
MOV_W17_W16 = 0x2a1003f1       # mov w17,w16
ADRP_X0 = 0xb0000000           # adrp x0,#0x1000（在 0x118，页 0：immlo=1 → 下一页）
BR_X18 = 0xd61f0240
NOP, RET = 0xd503201f, 0xd65f03c0


def bhi(at, to):
    return 0x54000008 | (((to - at) >> 2) << 5)


def make_nso(cmp_insn, ldrsw, mid, bad_target=False):
    head = [ADRP_X18, ADD_X18_LO, cmp_insn]
    tail = [ldrsw, ADD_X18] + mid + [BR_X18]
    first = 0x100 + 4 * (len(head) + 1 + len(tail))    # br 的下一条
    targets = [first + 8 * i for i in range(4)]
    out = first + 32
    insns = head + [bhi(0x10c, out)] + tail + [NOP, RET] * 4 + [RET]
    entries = [t - TBL for t in targets]
    if bad_target:
        entries[2] = 0x2000 - TBL
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
    struct.pack_into(f'<{len(insns)}I', text, 0x100, *insns)
    ro = bytearray(0x1000)
    EH, EF = 0x110, 0x200
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
    struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1,
                     0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
    ro[EF:EF + 0x18] = struct.pack('<II', 0x14, 0) + b'\x01zR\x00\x04\x78\x1e\x01\x1b' + bytes(7)
    fde = 0x1000 + EF + 0x18
    struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (fde + 4) - (0x1000 + EF), 0x100 - (fde + 8), 4 * len(insns))
    struct.pack_into('<4i', ro, 0x800, *entries)
    h = bytearray(0x100)
    h[:4] = b'NSO0'
    for k, mo in enumerate((0, 0x1000, 0x2000)):
        struct.pack_into('<III', h, 0x10 + 0x10 * k, 0x100 + 0x1000 * k, mo, 0x1000)
        struct.pack_into('<I', h, 0x60 + 4 * k, 0x1000)
    h[0x40:0x50] = bytes(range(16))
    return bytes(h) + bytes(text) + bytes(ro) + bytes(0x1000), targets, entries


def run(nso, target='apple'):
    with tempfile.TemporaryDirectory(prefix='rw-jt-x16-') as tmp:
        root = Path(tmp)
        (root / 'main').write_bytes(nso)
        (root / 'out').mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith('S2A_')}
        env.update(S2A_TARGET=target, LC_ALL='C')
        r = subprocess.run([CLI, str(root / 'main'), str(root / 'out'), 'main'], env=env,
                           capture_output=True, text=True, timeout=60)
        p = root / 'out' / 'main.patched.bin'
        return r.returncode, r.stdout + r.stderr, p.read_bytes() if p.exists() else None


def gaps(log):
    m = re.search(r'PFRW\b.*\bgaps=(\d+)', log)
    return int(m.group(1)) if m else -1


def expected_head(t1, t2, index, mids):
    return [
        ('stur', f'{t1}, [sp, #-0x10]'), ('stur', f'{t2}, [sp, #-0x18]'),
        ('mov', f'{t2}, {index}'), ('stur', f'{t2}, [sp, #-0x20]'),
        ('ldur', f'{t1}, [sp, #-0x10]'), ('ldur', f'{t2}, [sp, #-0x18]'),
    ] + mids + [
        ('stur', f'{t1}, [sp, #-0x10]'), ('stur', f'{t2}, [sp, #-0x18]'),
        ('ldur', f'{t2}, [sp, #-0x20]'),
    ]


class JtX16Test(unittest.TestCase):
    def check(self, cmp_insn, ldrsw, mid, t1, t2, index, mids, set_t):
        nso, targets, entries = make_nso(cmp_insn, ldrsw, mid)
        for tg in ('apple', 'android', 'ohos'):
            rc, log, _ = run(nso, tg)
            self.assertEqual((rc, gaps(log)), (0, 0), f'{tg}：\n{log}')
        _, _, img = run(nso)
        w, = struct.unpack_from('<I', img, 0x110)
        self.assertEqual(w >> 26, 0b000101, f'0x110 应改成 B：{w:#x}')
        imm = w & 0x3ffffff
        disp = 0x110 + 4 * (imm - (1 << 26) if imm >> 25 else imm)
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        ins = list(md.disasm(img[disp:disp + 4096], disp))
        head = expected_head(t1, t2, index, mids)
        self.assertEqual([(i.mnemonic, i.op_str) for i in ins[:len(head)]], head)
        rest = ins[len(head):]
        self.assertEqual([i.mnemonic for i in rest[:2]], ['adrp', 'add'])
        self.assertEqual(rest[0].op_str.split(',')[0], t1)
        self.assertEqual((rest[2].mnemonic, rest[2].op_str), ('add', f'{t1}, {t1}, {t2}, lsl #6'))
        self.assertEqual((rest[3].mnemonic, rest[3].op_str), ('br', t1))
        pad = rest[3].address + 4
        for k, target in enumerate(targets):
            at = pad + 64 * k
            words = struct.unpack_from('<16I', img, at)
            entry = list(md.disasm(img[at:at + 64], at))
            b = next(i for i in entry if i.mnemonic == 'b')
            self.assertEqual(int(b.op_str.lstrip('#'), 16), target, f'第 {k} 项落点')
            self.assertEqual([(i.mnemonic, i.op_str) for i in entry[entry.index(b) - 2:entry.index(b)]],
                             [('ldur', f'{t1}, [sp, #-0x10]'), ('ldur', f'{t2}, [sp, #-0x18]')])
            v, wrote = 0, False
            for x in words[:(b.address - at) // 4]:
                if x & 31 == 17 and (x >> 23) in (0b110100101, 0b111100101):
                    hw, wrote = (x >> 21) & 3, True
                    v = (v & ~(0xffff << (16 * hw))) | (((x >> 5) & 0xffff) << (16 * hw))
            self.assertEqual(wrote, set_t, f'第 {k} 项写 x17')
            if set_t:
                self.assertEqual(v, entries[k] & (2 ** 64 - 1), f'第 {k} 项写回的表项')

    def test_dqb2_shape(self):
        self.check(CMP_W17, LDRSW_I17, [MOV_W17_W16], 'x9', 'x10', 'x17', [('mov', 'w17, w16')], False)

    def test_tmp_avoids_index(self):
        self.check(CMP_W9, LDRSW_I9, [], 'x10', 'x11', 'x9', [], True)

    def test_mid_adrp_is_moved_with_its_target(self):
        # #716（一款游戏 subsdk0 0xbd1c38 / 0xbd1d60）：取表与 br 之间夹着 adrp x0, …——与位置有关，原先「中间指令不可搬移」记缺口。
        #   搬进补丁区按原目标重算：补丁区里那条 adrp 反汇编出来仍指向页 0x1000（v0.3.0 改写器：br_x18 缺口、退 3）
        self.check(CMP_W17, LDRSW_I17, [ADRP_X0], 'x9', 'x10', 'x17', [('adrp', 'x0, #0x1000')], True)

    def test_target_outside_function_still_gap(self):
        nso, _, _ = make_nso(CMP_W17, LDRSW_I17, [MOV_W17_W16], bad_target=True)
        rc, log, img = run(nso)
        self.assertEqual((rc, img is None), (3, False), log)   # v0.3.1 拿不准不停：有缺口照出产物
        self.assertIn('br_x18', log)
        self.assertEqual(struct.unpack_from('<I', img, 0x100 + 4 * 7)[0], BR_X18, '缺口点 br x18 保持原字')


if __name__ == '__main__':
    unittest.main()
