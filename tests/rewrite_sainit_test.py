#!/usr/bin/env python3
"""分配器初始化闸（改写器 sdk_sainit）契约：合成 sdk 导出 nn::mem::StandardAllocator 初始化，核入口改成跳进补丁岛、
补丁岛逐条编码、门表行（aregion 参数 1）。期望字按 ARM 架构手编，不调改写器的编码宏。

  入口第一条能搬（stp x29, x30, [sp, #-0x30]! / mov w3, wzr）→ 有闸：
    str x0, [sp, #-16]!   F81F0FE0     x0 压栈
    mov x0, #0            D2800000     清零（旧宿主的 aregion 处理看到 w0 = 0 不报红）
    stp x29, x30, [sp, #-16]!  A9BF7BFD
    …取门入口（gatecall）… blr x30 —— 门返回点登记为 aregion 1 <入口>
    ldp x29, x30, [sp], #16    A8C17BFD
    ldr x0, [sp], #16     F84107E0     恢复 x0
    <原第一条>
    b <入口 + 4>
  入口第一条不能搬（adrp、以 x8 为基址的存数）→ 不挂闸、入口原样、统计记 sdk_sainit_skip，不算缺口
  地址削减关（S2A_SDK_ADDR_CUT=0）→ 不挂闸；安卓出包缺省开，同苹果
"""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import importlib.util

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('corpus', ROOT / 'tests/rewrite_corpus/run.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)
NAMES = (b'_ZN2nn3mem17StandardAllocator10InitializeEPvmb', b'_ZN2nn3mem17StandardAllocator10InitializeEPvm', b'_ZN2nn3mem17StandardAllocatorC2EPvm')
FIRST = {'stp': ('stp x29, x30, [sp, #-0x30]!', 0xA9BD7BFD, True), 'movw3': ('mov w3, wzr', 0x2A1F03E3, True),
         'adrp': ('adrp x8, #0', None, False), 'store_x8': ('str x1, [x8]', 0xF9000101, False)}


def build(path, first, name):
    asm = f"""
      nop
.org 0x600
      {FIRST[first][0]}
      mov x29, sp
      ldp x29, x30, [sp], #0x30
      ret
"""
    words = corpus.assemble('sainit-' + first, asm)
    corpus.nso(words, {}, len(words) * 4, str(path))
    raw = bytearray(path.read_bytes())
    ro_file = 0x1100
    struct.pack_into('<i', raw, ro_file + 4, 0x300)
    for off, tag, value in ((0x300, 6, 0x1400), (0x310, 5, 0x1600), (0x320, 0, 0)):
        struct.pack_into('<QQ', raw, ro_file + off, tag, value)
    raw[ro_file + 0x601:ro_file + 0x602 + len(name)] = name + b'\0'
    struct.pack_into('<IBBHQQ', raw, ro_file + 0x418, 1, 2, 0, 1, 0x700, 0x10)
    path.write_bytes(raw)
    return struct.unpack_from('<I', raw, 0x100 + 0x700)[0]


def b_target(word, at):
    assert word >> 26 == 0b000101, hex(word)
    imm = word & 0x3FFFFFF
    return at + 4 * (imm - (1 << 26) if imm >> 25 else imm)


def check(out, orig_first, movable, enabled, stdout):
    patched = (out / 'sdk.patched.bin').read_bytes()
    gates = [l.split('\t') for l in (out / 'sdk.gates.tsv').read_text().splitlines()]
    mine = [f for f in gates if f[1] == 'aregion' and f[2] == '1']
    entry = struct.unpack_from('<I', patched, 0x700)[0]
    if not (movable and enabled):
        assert not mine, mine
        assert entry == orig_first, hex(entry)
        assert ("sdk_sainit_skip" in stdout) == (enabled and not movable), stdout[-400:]
        return
    assert len(mine) == 1 and int(mine[0][3], 16) == 0x700, mine
    stub = b_target(entry, 0x700)
    w = lambda k: struct.unpack_from('<I', patched, stub + 4 * k)[0]
    assert (w(0), w(1), w(2)) == (0xF81F0FE0, 0xD2800000, 0xA9BF7BFD), [hex(w(k)) for k in range(3)]
    ret = int(mine[0][0], 16)
    assert struct.unpack_from('<I', patched, ret - 4)[0] == 0xD63F03C0, '门返回点前一条是 blr x30'
    tail = struct.unpack_from('<4I', patched, ret)
    assert tail[:3] == (0xA8C17BFD, 0xF84107E0, orig_first), [hex(x) for x in tail]
    assert b_target(tail[3], ret + 12) == 0x704, '跳回入口 + 4'


def main():
    native = Path(os.environ['REW']).resolve()
    n = 0
    with tempfile.TemporaryDirectory(prefix='rewrite-sainit-') as tmp:
        root = Path(tmp)
        try:
            for first, (_, _, movable) in FIRST.items():
                for name in NAMES:
                    src = root / 'sdk.nso'
                    orig = build(src, first, name)
                    for target, cut in (('apple', None), ('apple', '0'), ('android', None)):
                        env = dict(os.environ, S2A_TARGET=target)
                        env.pop('S2A_SDK_ADDR_CUT', None)
                        if cut is not None:
                            env['S2A_SDK_ADDR_CUT'] = cut
                        out = root / 'out'
                        if out.exists():
                            shutil.rmtree(out)
                        r = subprocess.run([str(native), str(src), str(out), 'sdk'], env=env, capture_output=True, text=True, timeout=60)
                        assert r.returncode == 0 and not r.stderr, (first, name, target, r.stdout[-600:], r.stderr)
                        enabled = cut is None   # 命令行缺省开削减（runtime/rewriter/main.c），安卓出包同样缺省开（android/tools/make_pack.py）
                        check(out, orig, movable, enabled, r.stdout)
                        n += 1
        finally:
            shutil.rmtree(corpus.T, ignore_errors=True)
    print(f'分配器初始化闸：{n} 组（4 种入口第一条 × 3 个导出名 × 苹果开 / 苹果关 / 安卓开）全部符合')


if __name__ == '__main__':
    main()
