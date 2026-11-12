#!/bin/bash
# 合成 NSO：紧凑字节跳转表允许 SIMD 指令间隔，拒绝被覆盖的定义与跳入路径。
# 原七种形态保留，加通用寄存器间隔半字表、近距x18覆盖和有符号读表；Apple/Android × spin开/关。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}   # 钉版解释器（capstone / lz4），与其它改写器单测一致
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$PY" - "$REW" "$T" <<'PY'
import os, struct, subprocess, sys
from pathlib import Path
rew, temp = map(Path, sys.argv[1:])
# AArch64 编码由合成汇编生成；向量 mov 不应被误认为写通用 x6。
simd = [0x4ea01c02 + i for i in range(6)]
cases = {
    'near': ([0x10000092, 0x386e69e6, 0x8b060a52, 0xd61f0240, 0xd503201f, 0xd65f03c0], 0x110),
    'simd6': ([0x10000152, 0x386e69e6, 0x8b060a52] + simd + [0xd61f0240, 0xd503201f, 0xd65f03c0], 0x128),
    'simd10': ([0x100001d2, 0x386e69e6, 0x8b060a52] + [0x4ea01c02+i for i in range(10)] + [0xd61f0240, 0xd503201f, 0xd65f03c0], 0x138),
    'x18_clobbered': ([0x10000172, 0x386e69e6, 0x8b060a52] + simd + [0xaa0903f2, 0xd61f0240, 0xd503201f, 0xd65f03c0], None),
    'offset_clobbered': ([0x10000172, 0x386e69e6, 0xaa0903e6, 0x8b060a52] + simd + [0xd61f0240, 0xd503201f, 0xd65f03c0], None),
    'branch_skips_definition': ([0x34000081, 0x10000152, 0x386e69e6, 0x8b060a52] + simd + [0xd61f0240, 0xd503201f, 0xd65f03c0], None),
    'combined_spin': ([0x10000152, 0x386e69e6, 0x8b060a52] + simd + [0xd61f0240, 0xb9400008, 0x34ffffe8, 0xd65f03c0], 0x128),
    'gp_mov_halfword': ([268435858, 2020501990, 2332428882, 2852127721, 2852127722, 2852127723, 2852127724, 2852127725, 2852127726, 2852127727, 2852127728, 3592356416, 3573751839, 3596551104], 0x130),
    'near_x18_clobbered': ([0x100000b2, 0x386e69e6, 0x8b060a52, 0xaa0903f2, 0xd61f0240, 0xd503201f, 0xd65f03c0], None),
    'signed_byte': ([0x10000092, 0x38ee69e6, 0x8b060a52, 0xd61f0240, 0xd503201f, 0xd65f03c0], 0x110),
    'signed_halfword': ([0x10000092, 0x78ee69e6, 0x8b060a52, 0xd61f0240, 0xd503201f, 0xd65f03c0], 0x110),
}
def nso(words):
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
    struct.pack_into('<%dI' % len(words), text, 0x100, *words)
    ro = bytearray(0x1000); eh, ef = 0x100, 0x200
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, eh, eh+0x20)
    struct.pack_into('<BBBBiIii', ro, eh, 1, 0x1b, 3, 0x3b, ef-eh-4, 1, 0x100-(0x1000+eh), ef+0x18-eh)
    ro[ef:ef+0x18] = struct.pack('<II', 0x14, 0)+bytes([1])+b'zR\0'+bytes([4, 0x78, 30, 1, 0x1b])+bytes(7)
    fde = 0x1000+ef+0x18
    struct.pack_into('<IIii', ro, ef+0x18, 0x10, fde+4-(0x1000+ef), 0x100-(fde+8), len(words)*4)
    header = bytearray(0x100); header[:4] = b'NSO0'
    for k in range(3):
        struct.pack_into('<III', header, 0x10+16*k, 0x100+0x1000*k, 0x1000*k, 0x1000)
        struct.pack_into('<I', header, 0x60+4*k, 0x1000)
    return header+text+ro+bytes(0x1000)
count = 0
for name, (words, base) in cases.items():
    source = temp/(name+'.nso'); source.write_bytes(nso(words))
    for target in ('apple', 'android'):
        for spin in (False, True):
            label = f'{name}-{target}-spin{int(spin)}'; out = temp/label; out.mkdir()
            env = os.environ.copy(); env['S2A_TARGET'] = target; env.pop('S2A_REWRITE_SPIN', None)
            if spin: env['S2A_REWRITE_SPIN'] = '1'
            proc = subprocess.run(([sys.executable, str(rew)] if rew.suffix == ".py" else [str(rew)]) + [str(source), str(out), 'main'], env=env, capture_output=True, text=True, timeout=30)
            expected = 0 if base is not None else 3
            assert proc.returncode == expected, (label, proc.returncode, proc.stdout, proc.stderr)
            assert (out/'main.patched.bin').exists(), label   # v0.3.1 拿不准不停：有缺口（退 3）也照出产物
            if base is not None:
                rows = [line.split('\t') for line in (out/'main.sites.tsv').read_text().splitlines()]
                jumps = [row for row in rows if len(row) == 4 and row[1] == 'J']
                assert len(jumps) == 1 and int(jumps[0][2], 16) == base and int(jumps[0][3]) == (65536 if name in ('gp_mov_halfword', 'signed_halfword') else 256), (label, jumps)
                spins = sum(len(row) > 1 and row[1] == 'S' for row in rows)
                if name == 'combined_spin': assert spins == int(spin), (label, spins)
            count += 1; print('通', label)
assert count == 44
print('紧凑字节/半字跳转表：原28项与新16项全通')
PY
