#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute synthetic OHOS rewritten instructions using Unicorn; no game data or real keys.
Usage: python test_rewrite_ohos.py REPO OUT [PREVIOUS_REWRITER]
Rewriter: the C command line (S2A_REWRITER_C, else `pack/rewriter.py c-path`, which needs
S2A_REWRITER_DEPS); the Python patch_nso.py was removed upstream. Requires unicorn 2.1.4.
"""
from pathlib import Path
import os, re, struct, subprocess, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import *

repo, out = map(Path, sys.argv[1:3]); out.mkdir(parents=True, exist_ok=True)
rewriter = Path(subprocess.run([sys.executable, str(repo / 'pack/rewriter.py'), 'c-path'], check=True,
                               capture_output=True, text=True).stdout.strip().splitlines()[-1])
# Reuse the upstream synthetic NSO fixture, not production program bytes.
fixture = (repo / 'tests/rewrite_target_test.sh').read_text(encoding='utf-8').split("<<'EOF'", 1)[1].split('\nEOF', 1)[0]
nso = out / 'main.nso'
subprocess.run([sys.executable, '-c', fixture, str(nso)], check=True)

def rewrite(target, script, dest):
    dest.mkdir(exist_ok=True)
    cmd = [sys.executable, str(script)] if str(script).endswith('.py') else [str(script)]
    r = subprocess.run(cmd + [str(nso), str(dest), 'main'],
        env=dict(os.environ, S2A_TARGET=target, PYTHONUTF8='1'), capture_output=True)
    (dest / 'rewrite.log').write_bytes(r.stdout + r.stderr)
    assert r.returncode == 0, (target, r.returncode)

for target in ('apple', 'android', 'ohos'):
    rewrite(target, rewriter, out / target)
    if len(sys.argv) > 3 and target != 'ohos':
        old = out / ('old-' + target); rewrite(target, Path(sys.argv[3]), old)
        for p in old.iterdir():
            if p.name != 'rewrite.log': assert p.read_bytes() == (out / target / p.name).read_bytes(), (target, p.name)
        print(target + ': output matches the original rewriter byte-for-byte')

d = out / 'ohos'
hdr = dict(line[2:].strip().split('\t', 1) for line in (d / 'main.fixups.tsv').read_text().splitlines() if line.startswith('# '))
assert hdr['TARGET'] == 'ohos' and hdr['REWRITE_ABI'] == 'ohos-sp-safe-v1' and hdr['KEY_TSDOFF_IDX'] == '4'
blob = (d / 'main.patched.bin').read_bytes()
patch = int(hdr['PATCH_OFF'], 16); keyoff = int(hdr['KEY_PAGE_OFF'], 16)
for ins in Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(blob[patch:], patch):
    assert 'tpidrro_el0' not in ins.op_str
    assert not (re.search(r'\[sp, #-', ins.op_str) and ']!' not in ins.op_str), (ins.mnemonic, ins.op_str)

regs = [globals()['UC_ARM64_REG_X' + str(i)] for i in range(31)]
base, tp, table, sp = 0x100000, 0x300800, 0x400800, 0x500800
keys = [0, 7, 21, 32]  # key zero is valid on musl
slot_values = [0x13579, 0x24680, 0xabcdef, 0x600000]
count = 0
for offset in (-0x80, 0x48):
    for site in (0x100, 0x104, 0x108, 0x10c, 0x110, 0x114, 0x118):
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        uc.mem_map(base, (len(blob) + 4095) & ~4095); uc.mem_write(base, blob)
        for address in (0x300000, 0x400000, 0x500000, 0x600000): uc.mem_map(address, 4096)
        uc.mem_write(0x600000, struct.pack('<I', 0xd65f03c0))  # synthetic host gate returns
        uc.reg_write(UC_ARM64_REG_TPIDR_EL0, tp)
        uc.mem_write(tp + offset, struct.pack('<Q', table))
        uc.mem_write(base + keyoff, struct.pack('<4Qq', *[(k + 1) * 8 for k in keys], offset))
        for k, value in zip(keys, slot_values): uc.mem_write(table + k * 8, struct.pack('<Q', value))
        values = [0x1000 + i * 16 for i in range(31)]
        for reg, value in zip(regs, values): uc.reg_write(reg, value)
        uc.reg_write(UC_ARM64_REG_SP, sp)
        uc.emu_start(base + site, base + site + 4, count=200)
        assert uc.reg_read(UC_ARM64_REG_PC) == base + site + 4, hex(site)
        want = list(values); slots = list(slot_values)
        if site == 0x100: want[0] = slots[1]
        elif site == 0x104: slots[1] = values[1]
        elif site == 0x108: want[2] = slots[2]
        elif site == 0x10c: want[3] = slots[0] + 8
        elif site == 0x110: slots[0] = values[4]
        elif site == 0x118: slots[0] = sp + 8
        assert [uc.reg_read(r) for r in regs] == want, ('register corruption', hex(site), offset)
        assert uc.reg_read(UC_ARM64_REG_SP) == sp, ('stack corruption', hex(site))
        actual = [struct.unpack('<Q', uc.mem_read(table + k * 8, 8))[0] for k in keys]
        assert actual == slots, ('slot mismatch', hex(site), actual, slots)
        count += 1
print(f'OHOS: {count} instruction executions passed; key zero, both signed TSD offsets, scratch/SP preserved, no red-zone access')
