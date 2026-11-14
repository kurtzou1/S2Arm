#!/usr/bin/env python3
# BNSH 切片不拷到文件尾、没有 grsc 不切的单测（graphics/tools/shbake/nxsh_extract.py _scan_blob，#711）：约 1 秒，退出 0 = 全过。
# 背景：原先每遇一处 BNSH 魔数先切 data[起点:]（到文件尾）再按头里的长度截短；几 GB 的容器（Trinity data.trpfs）mmap 着扫，每处都拷一份到文件尾，
#   Windows 有提交上限，16 GB 机器上抽取报 MemoryError。改成按头里的长度只切这一支。
#   之后：大容器里碰巧是 BNSH 魔数的字节，头里的长度也是乱的（0100F43008C44000 arc/data.trpfs 4.7 GB 里 148 处，长度最大 4.17 GB，合计要拷 168 GB），
#   最后全判「无 grsc」。bnsh_codes 头一步就看 +0x60 是不是 grsc，所以先在原数据上看这 4 字节，不是就不切。
# 构造（期望按输入手写，不跑被测实现推）：
#   A：64 MB 全 0，偏移 0x1000 / 0x200000 / 0x2000000 各放一个带 grsc 的 BNSH 头（魔数 + 0x1c 处长度 + 0x60 处 grsc）：
#     ① 前两个长度 0x100 / 0x4000：交给 bnsh_codes 的切片长度恰为头里的长度；
#     ② 第三个长度写 0（不合法）：照旧给到文件尾（64 MB − 0x2000000 = 32 MB），语义不变；
#     ③ tracemalloc 峰值：只算 ①（合法长度）那两处时 < 1 MB（旧写法每处拷到文件尾，峰值 ≥ 62 MB）。
#   B：64 MB 全 0，偏移 0x1000 放一个长度 48 MB、没有 grsc 的 BNSH 头；偏移 0x3800000 放一个长度 0x40 的头，grsc 写在 +0x60（在它自报的长度之外）：
#     ④ 两处都不交给 bnsh_codes、都记「BNSH 无 grsc」，峰值内存 < 1 MB（修前两处都切：48 MB + 64 字节，峰值 ≥ 48 MB）。
import os, sys, struct, tracemalloc, collections
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
import nxsh_extract as X
fail = 0
def ck(ok, msg):
    global fail
    print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
N = 64 << 20
def blob(heads):   # heads = [(偏移, 头里的长度, 0x60 处写不写 grsc)]
    buf = bytearray(N)
    for off, size, grsc in heads:
        buf[off:off + 8] = b'BNSH\0\0\0\0'; struct.pack_into('<I', buf, off + 0x1c, size)
        if grsc: buf[off + 0x60:off + 0x64] = b'grsc'
    return bytes(buf)
seen = []
X.bnsh_codes = lambda b: seen.append(len(b))   # 只看切给它的长度；返回 None = 「无 grsc」，不往下走
X.scan_adj = lambda *a, **k: 0                  # 相邻扫描与本题无关（64 MB 全 0 里也找不到控制段魔数）
X.RAW = False
data = blob([(0x1000, 0x100, True), (0x200000, 0x4000, True), (0x2000000, 0, True)])
half = data[:0x2000000]   # ③ 只含前两处合法长度（切片在计量开始前做）
tracemalloc.start()
X._scan_blob('t', half, [], {}, collections.Counter())
peak = tracemalloc.get_traced_memory()[1]; tracemalloc.stop()
ck(peak < (1 << 20), f'③ 两处合法长度的 BNSH：峰值内存 < 1 MB（真结果 {peak / 1048576:.2f} MB；旧写法每处拷到文件尾 ≥ 31 MB）')
ck(seen == [0x100, 0x4000], f'① 切片长度 = 头里的长度 [256, 16384]（真结果 {seen}）')
seen.clear()
X._scan_blob('t', data, [], {}, collections.Counter())
ck(seen == [0x100, 0x4000, N - 0x2000000], f'② 长度为 0 的照旧到文件尾 [256, 16384, {N - 0x2000000}]（真结果 {seen}）')
del data, half
data = blob([(0x1000, 0x3000000, False), (0x3800000, 0x40, True)])
seen.clear(); stat = collections.Counter()
tracemalloc.start()
X._scan_blob('t', data, [], {}, stat)
peak = tracemalloc.get_traced_memory()[1]; tracemalloc.stop()
ck(seen == [] and stat['BNSH 无 grsc'] == 2 and peak < (1 << 20),
   f'④ 没有 grsc 的两处（长度 48 MB / 0x40）不切、记「BNSH 无 grsc」2 处、峰值 < 1 MB（真结果 切给 bnsh_codes {seen}、无 grsc {stat["BNSH 无 grsc"]} 处、峰值 {peak / 1048576:.2f} MB）')
print(f'{"✓" if not fail else "✗"} t_bnsh_slice：{fail} 处不符')
sys.exit(1 if fail else 0)
