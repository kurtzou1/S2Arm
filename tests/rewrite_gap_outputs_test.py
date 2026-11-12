#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original synthetic NSOs, no assembler or private assets; run via the .sh entry."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

OUTPUTS = ('patched.bin', 'fixups.tsv', 'gates.tsv', 'sites.tsv', 'widen.tsv')


def nso(path, gap):
    # Success: mov x18,x1 / svc #0 / ret. Failure: same, with br x18 at 0x104.
    # Unknown x18 branch must report precisely 0x104 br_x18. Since v0.3.1 (degrade, do not stop) the image is still written:
    # the gap site keeps its original word, every other site is rewritten, and the exit code stays 3.
    code = (0xaa0103f2, 0xd61f0240 if gap else 0xd4000001, 0xd65f03c0)
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
    struct.pack_into('<3I', text, 0x100, *code)
    ro = bytearray(0x1000)
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, 0x100, 0x120)
    struct.pack_into('<BBBBiIii', ro, 0x100, 1, 0x1b, 3, 0x3b,
                     0xfc, 1, 0x100 - 0x1100, 0x1218 - 0x1100)
    ro[0x200:0x218] = (struct.pack('<II', 0x14, 0) + b'\x01zR\0'
                         + bytes((4, 0x78, 30, 1, 0x1b)) + bytes(7))
    struct.pack_into('<IIii', ro, 0x218, 0x10, 0x1c, 0x100 - 0x1220, 12)
    # f32 wide datum, outside MOD0 / unwind information.
    struct.pack_into('<f', ro, 0x400, 16 / 9)
    header = bytearray(0x100)
    header[:4] = b'NSO0'
    header[0x40:0x50] = bytes(range(16))
    for k in range(3):
        struct.pack_into('<III', header, 0x10 + 0x10 * k,
                         0x100 + 0x1000 * k, 0x1000 * k, 0x1000)
        struct.pack_into('<I', header, 0x60 + 4 * k, 0x1000)
    path.write_bytes(header + text + ro + bytes(0x1000))


def run(rew, root, target):
    out = root / target
    out.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith('S2A_')}
    env['S2A_TARGET'] = target
    wide = root / 'wide.tsv'
    wide.write_text('main\t0x1400\tf32\n')
    checks = []

    def check(label, condition):
        checks.append(condition)
        print(('通 ' if condition else '不通 ') + target + ' ' + label)

    def invoke(source, directory=out):
        result = subprocess.run([rew, str(root / source), str(directory), 'main', str(wide)],
                                env=env, capture_output=True, text=True, timeout=30)
        check(source + ' rc=' + str(result.returncode), result.returncode == (3 if source == 'gap' else 0))
        return result

    invoke('good')
    check('成功实际生成五种运行产物', all((out / ('main.' + s)).is_file() for s in OUTPUTS))
    check('成功有真实 gate / widen 行', (out / 'main.gates.tsv').stat().st_size > 0
          and (out / 'main.widen.tsv').stat().st_size > 0)
    saved = {s: (out / ('main.' + s)).read_bytes() for s in (*OUTPUTS, 'gaps.tsv')}
    for s, data in saved.items():
        print('SHA256', target, s, hashlib.sha256(data).hexdigest())
    # Same directory may hold other modules and caller-owned files.
    unrelated = ['other.' + s for s in (*OUTPUTS, 'gaps.tsv')] + ['keep.txt']
    for name in unrelated:
        (out / name).write_bytes(b'keep\n')
    gap_out = []
    for repeat in range(2):
        result = invoke('gap')
        rows = [line.split('\t')[:2] for line in (out / 'main.gaps.tsv').read_text().splitlines()
                if line and not line.startswith('#')]
        check(f'缺口第{repeat + 1}次准确诊断', rows == [['0x104', 'br_x18']]
              and 'gaps=1 fatal=0' in result.stdout)
        for s in OUTPUTS:
            check(f'缺口第{repeat + 1}次照出 {s}', (out / ('main.' + s)).is_file())
        img = (out / 'main.patched.bin').read_bytes() if (out / 'main.patched.bin').is_file() else b''
        check(f'缺口第{repeat + 1}次缺口点 0x104 保持原字 br x18', len(img) >= 0x108 and struct.unpack_from('<I', img, 0x104)[0] == 0xd61f0240)
        gap_out.append({s: (out / ('main.' + s)).read_bytes() for s in OUTPUTS if (out / ('main.' + s)).is_file()})
        check('不碰其它模块和无关文件', all((out / n).read_bytes() == b'keep\n' for n in unrelated))
    check('缺口两次产物逐字节相同', len(gap_out) == 2 and gap_out[0] == gap_out[1] and len(gap_out[0]) == len(OUTPUTS))
    invoke('good')
    check('恢复成功六种产物逐字节不变', all((out / ('main.' + s)).read_bytes() == b for s, b in saved.items()))
    clean = root / (target + '-clean')
    clean.mkdir()
    invoke('gap', clean)
    check('空目录缺口也生成运行产物、与上面同', all((clean / ('main.' + s)).is_file() and (clean / ('main.' + s)).read_bytes() == gap_out[0].get(s) for s in OUTPUTS))
    print(f'{target}: {sum(checks)}/{len(checks)}')
    return sum(not c for c in checks)


with tempfile.TemporaryDirectory(prefix='rewrite-gap-outputs-') as temp:
    root = Path(temp)
    nso(root / 'good', False)
    nso(root / 'gap', True)
    failures = sum(run(str(Path(sys.argv[1]).resolve()), root, t) for t in ('apple', 'android', 'ohos'))
print(f'rewrite_gap_outputs: 不通 {failures}')
sys.exit(bool(failures))
