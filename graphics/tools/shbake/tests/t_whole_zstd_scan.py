#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 整文件 zstd 解开的数据不再盲搜 zlib 流 / 内嵌 zstd 帧 / CRILAYLA 的单测（graphics/tools/shbake/nxsh_extract.py visit，#744）：约 1 秒，退出 0 = 全过。
# 背景：顶层文件整份是 zstd / Yaz0 时先解开（whole），之后早已不再盲搜内嵌 gzip / xz / LZ4（scan_streams）；scan_zlib / scan_zstd_frames /
#   scan_crilayla 还对解开后的数据整段盲搜。0400486024DEC000 的 10 万个整文件 zstd 里这样搜出 5 万多个内嵌帧、38 万个假起点，抽到的键是 0。
# 构造（期望按输入手写，不跑被测实现推）：同一段内容 P = 模型头 + zlib 流（包着着色器对 A）+ zstd 帧（包着着色器对 B）
#   ① P 直接当顶层文件（不是整文件压缩）：照旧盲搜，抽出 A、B 两个键，统计里 zlib 流 1、内嵌 zstd 帧 1；
#   ② P 整份再用 zstd 压一次当顶层文件：解开后不再盲搜，键 0 个，统计里没有 zlib 流 / 内嵌 zstd 帧。
import sys, os, struct, hashlib, zlib, subprocess, tempfile, shutil, collections
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
CM = bytes.fromhex('3412769801000000'); MG = bytes.fromhex('78563412') + bytes(12)
NOP, EXIT = 0x50b0000000070f00, 0xe30000000007000f
def shader(ty, seed, n=0x200, c1o=0x100):   # 同 t_unpack_generic：机器码过 code_ok（区内有 EXIT、指令区末字是 NOP）
    code = bytearray(n); code[:16] = MG; struct.pack_into('<I', code, 0x30, ty << 10)
    struct.pack_into('<Q', code, 0x50, EXIT); struct.pack_into('<Q', code, 0x58, seed | 1 << 40); struct.pack_into('<Q', code, c1o - 8, NOP)
    ctl = bytearray(0x880); ctl[:8] = CM; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, n); struct.pack_into('<I', ctl, 0x700, c1o); ctl[0x100] = seed & 0xff
    return bytes(ctl), bytes(code)
def key(ctl, code): return hashlib.sha256(ctl + code).hexdigest()[:16]
fail = 0
def check(ok, what):
    global fail
    print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
def keys(rows): return sorted({r[0] for r in rows})
def zstd(b):
    p = os.path.join(T, 'in'); open(p, 'wb').write(b)
    subprocess.run(['zstd', '-q', '-f', p, '-o', p + '.zs'], check=True); return open(p + '.zs', 'rb').read()
T = tempfile.mkdtemp()
try:
    A, B = shader(1, 7), shader(5, 9, 0x300, 0x180)
    P = b'MODEL' + bytes(27) + zlib.compress(A[0] + A[1], 9) + bytes(16) + zstd(b'MODEL' + bytes(27) + B[0] + B[1]) + bytes(16)
    rows, st = [], collections.Counter(); X.visit('plain.bin', P, rows, {}, st)
    want = sorted([key(*A), key(*B)])
    check(keys(rows) == want and st['zlib 流'] == 1 and st['内嵌 zstd 帧'] == 1,
          f'非整文件照旧盲搜：抽出 2 个键（期望 {want}）、zlib 流 1、内嵌 zstd 帧 1：真结果 键 {keys(rows)}、统计 {dict(st)}')
    rows, st = [], collections.Counter(); X.visit('whole.bin.zs', zstd(P), rows, {}, st)
    check(st['zstd'] == 1 and keys(rows) == [] and st['zlib 流'] == 0 and st['内嵌 zstd 帧'] == 0,
          f'整文件 zstd 解开后不再盲搜：zstd 1、键 0 个、zlib 流 0、内嵌 zstd 帧 0：真结果 键 {keys(rows)}、统计 {dict(st)}')
finally:
    shutil.rmtree(T, ignore_errors=True)
print(f'整文件 zstd 不盲搜单测：{"全过" if fail == 0 else f"{fail} 项不过"}'); sys.exit(1 if fail else 0)
