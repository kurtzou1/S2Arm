#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 大文件按 mmap 扫时 SPCH 照样认的单测（graphics/tools/shbake/nxsh_extract.py _scan_blob）：约 1 秒，退出 0 = 全过。
# 背景：超过 BIG 的顶层文件在 work 里按 mmap 交给 scan_blob（big_split），_scan_blob 原先用 `b'HCPS' in data` 判要不要解 SPCH。
#   mmap 不支持子串 in：按序列逐个取单字节和整串比，子串永远判不中（文件里有也返回 False），4.7 GB 的 0100F43008C44000 arc/data.trpfs 上还要走 30 秒。
# 构造（期望按格式手算，同 t_spch.py：键 = sha256(控制段 ‖ 机器码) 前 16 位）：0x40 字节前导 + 一个 SPCH（1 个 SLCT、1 个程序 = vs + ps）写成文件，
#   ① 同一份字节直接给 _scan_blob：2 条 #spch 记录（对照，修前修后都过）；
#   ② 把 BIG 调到文件长以下，走 work 的大文件路（mmap → scan_blob）：同样 2 条 #spch 记录，来源 <文件>#spch0x40.0；修前 0 条。
import sys, os, struct, hashlib, collections, tempfile, shutil
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
CM = bytes.fromhex('3412769801000000'); MG = bytes.fromhex('78563412') + bytes(12); CN = 0x880
def shader(ty, seed, n):   # ty：1 vs / 5 ps
    code = bytearray(n); code[:16] = MG; struct.pack_into('<I', code, 0x30, ty << 10); code[0x40:0x48] = struct.pack('<Q', seed)
    ctl = bytearray(CN); ctl[:8] = CM; struct.pack_into('<I', ctl, 0x20, CN); struct.pack_into('<I', ctl, 0x704, n); ctl[0x100] = seed & 0xff
    return bytes(ctl), bytes(code)
def key(ctl, code): return hashlib.sha256(ctl + code).hexdigest()[:16]
def spch(prog):   # 一个 SLCT、一个程序（prog = [(控制段, 机器码), …]）；头与 SLCT 布局同 t_spch.py
    ctl_area = b''.join(c for c, _ in prog); code_area = b''.join(d for _, d in prog)
    s = bytearray(0x48); s[:4] = b'SLCT'; struct.pack_into('<I', s, 4, 0x1003); struct.pack_into('<I', s, 0x10, 1); struct.pack_into('<I', s, 0x1c, 0x40)
    struct.pack_into('<4I', s, 0x28, 0, len(ctl_area), 0, len(code_area)); struct.pack_into('<II', s, 0x40, 0, 0); s += bytes((-len(s)) % 16)
    to = 0x30; sb = 0x40; co = sb + len(s); co += (-co) % 0x100; xo = co + len(ctl_area); xo += (-xo) % 0x100
    out = bytearray(xo + len(code_area))
    struct.pack_into('<12I', out, 0, 0x53504348, 0x3f2, to, 1, 0, 0, sb, len(s), xo, len(code_area), co, len(ctl_area))
    struct.pack_into('<II', out, to, 0, 0); out[sb:sb + len(s)] = s; out[co:co + len(ctl_area)] = ctl_area; out[xo:] = code_area
    return bytes(out)
fail = 0
def check(ok, what):
    global fail
    print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
V, P = shader(1, 1, 0x200), shader(5, 2, 0x300)
blob = b'\xaa' * 0x40 + spch([V, P]) + b'\0' * 0x40
want = sorted([(key(*V), 'vs', 'big.bin#spch0x40.0', 0), (key(*P), 'ps', 'big.bin#spch0x40.0', 0)])
rows, stat = [], collections.Counter(); X._scan_blob('big.bin', blob, rows, {}, stat)
got = sorted(r for r in rows if '#spch' in r[2])
check(got == want, f'字节直接扫：2 条 #spch 记录（期望 {want}）：真结果 {got}')
T = tempfile.mkdtemp()
try:
    root = os.path.join(T, 'romfs'); out = os.path.join(T, 'out'); os.makedirs(root); os.makedirs(os.path.join(out, 'src'))
    p = os.path.join(root, 'big.bin'); open(p, 'wb').write(blob)
    X.BIG = len(blob) - 1   # 让这个文件走大文件路（big_split：mmap 后交 scan_blob，zlib 流另由 work_zlib 分段）
    check(X.big_split(p), f'文件长 {len(blob)} 超过 BIG → 走大文件路')
    rows, stat = X.work((root, [p], out))
    got = sorted(r for r in rows if '#spch' in r[2])
    check(got == want, f'大文件路（mmap）：同样 2 条 #spch 记录、来源 big.bin#spch0x40.0：真结果 {got}')
finally:
    shutil.rmtree(T, ignore_errors=True)
print(f'mmap 大文件 SPCH 单测：{"全过" if fail == 0 else f"{fail} 项不过"}'); sys.exit(1 if fail else 0)
