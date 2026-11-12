#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# zstd 字典收集按文件头先筛、有界排队的单测（graphics/tools/shbake/nxsh_extract.py find_zsdicts，#639）：约 2 秒，退出 0 = 全过。
# 背景：资源里只要有一个带字典号的 zstd 帧，find_zsdicts 就把每个 ≤ 8 MB 的文件整份读进内存再看开头；开头不是字典 / SARC / 不带字典号的
#   zstd 帧的文件整读完也只会返回空。文件头 RomFS 清单里已有（romfs_list.heads 前 32 字节）。不带字典号的 zstd 帧原先整读整解只为看解出来
#   是不是 SARC，只解开头 4 字节就够。另外原先 ex.map 一开始就把全部文件提交成任务。
# 构造（期望按输入手写，不跑被测实现推）：
#   字典 A（号 101）直接放；字典 B（号 102）放 SARC 成员；字典 C（号 103）放 SARC 再普通 zstd 压（帧头不写字典号）；
#   一个用字典 A 压的 zstd 帧（帧头写 101，让「资源用到字典」成立）；N 个普通小文件；K 个普通 zstd 压的随机数据（不带字典号、解出来不是 SARC，
#   每个压缩后都比首块读取上限大）；一个 9 MB 带字典的 SARC（超 8 MB 不收，同原先）
#   ① 收到的字典 = {101, 102, 103}，内容逐字节等于输入；
#   ② find_zsdicts 读到文件尾的文件 = 真带字典的那 3 个（原先 = 全部 ≤ 8 MB 的 N + K + 4 个）；
#   ③ N 个开头像 SARC 的坏文件（都要整读）：排队里同时压着的任务 ≤ 4 × 读线程数（原先 = 全部提交）。
import os, sys, shutil, subprocess, tempfile, collections, concurrent.futures as cf
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
sys.path.insert(0, os.path.normpath(os.path.join(H, '..')))
import nxsh_extract as X, nxfmt
fail = 0
def ck(ok, msg):
    global fail
    print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1

N, K, PJ = 3000, 20, 4
os.environ['NXSH_IO_J'] = str(PJ); os.environ['S2A_ROMFS_WALK'] = 'off'
T = tempfile.mkdtemp()
try:
    samp = os.path.join(T, 'samp'); os.makedirs(samp)
    for i in range(64): open(os.path.join(samp, f'{i}'), 'wb').write((f'layer {i} grass rock water ' * 40).encode() + bytes([i]) * 64)
    sp = [os.path.join(samp, f) for f in sorted(os.listdir(samp))]
    dic = {}
    for did in (101, 102, 103):
        p = os.path.join(T, f'{did}.dic')
        subprocess.run(['zstd', '-q', '--train', f'--dictID={did}', '-o', p, '--maxdict=4096'] + sp, check=True)
        dic[did] = open(p, 'rb').read()
    def sarc(files):
        w = nxfmt.SarcWriter(); w.files.update(files); return bytes(w.write()[1])
    def build(root, filler):
        os.makedirs(os.path.join(root, 'pack'))
        open(os.path.join(root, 'pack', 'a.zsdic'), 'wb').write(dic[101])
        open(os.path.join(root, 'pack', 'b.sarc'), 'wb').write(sarc({'b.zsdic': dic[102]}))
        cs = os.path.join(T, 'c.sarc'); open(cs, 'wb').write(sarc({'c.zsdic': dic[103]}))
        subprocess.run(['zstd', '-q', '-f', cs, '-o', os.path.join(root, 'pack', 'c.sarc.zs')], check=True)
        m = os.path.join(T, 'm.bin'); open(m, 'wb').write(b'MODEL' + bytes(4000))
        subprocess.run(['zstd', '-q', '-f', '-D', os.path.join(T, '101.dic'), m, '-o', os.path.join(root, 'm.bin.zs')], check=True)
        open(os.path.join(root, 'big.sarc'), 'wb').write(sarc({'x.zsdic': dic[102], 'pad': bytes(9 << 20)}))
        d = os.path.join(root, 'res'); os.makedirs(d)
        for i in range(N): open(os.path.join(d, f'{i:05d}.bin'), 'wb').write(filler(i))
        for i in range(K):
            r = os.path.join(T, f'r{i}.bin'); open(r, 'wb').write(os.urandom(300 << 10))
            subprocess.run(['zstd', '-q', '-f', r, '-o', os.path.join(d, f'z{i:02d}.bin.zs')], check=True)
    reads, live = [], [0, 0]
    real_open = open
    class Tracked:   # 记下读到文件尾的文件（read() 不给长度）
        def __init__(self, f, p): self.f, self.p = f, p
        def read(self, n=-1):
            if n is None or n < 0: reads.append(os.path.relpath(self.p, T))
            return self.f.read(n)
        def __enter__(self): return self
        def __exit__(self, *a): self.f.close()
        def __getattr__(self, k): return getattr(self.f, k)
    def counting_open(p, mode='r', *a, **k):
        f = real_open(p, mode, *a, **k)
        return Tracked(f, p) if 'r' in mode and 'b' in mode else f
    Real = cf.ThreadPoolExecutor
    class Counting(Real):
        def submit(self, *a, **k):
            f = super().submit(*a, **k); live[0] += 1; live[1] = max(live[1], live[0]); r = f.result
            def result(*ra, **rk):
                if not getattr(f, '_taken', False): f._taken = True; live[0] -= 1
                return r(*ra, **rk)
            f.result = result; return f
    def run(root):
        del reads[:]; live[0] = live[1] = 0; X.open = counting_open; X.cf.ThreadPoolExecutor = Counting
        try:
            out = os.path.join(T, 'zd-' + os.path.basename(os.path.dirname(root))); n = X.find_zsdicts([root], out)
        finally:
            del X.open; X.cf.ThreadPoolExecutor = Real
        got = {int(f[:-7]): open(os.path.join(out, f), 'rb').read() for f in os.listdir(out) if f.endswith('.zsdict')}
        return n, got
    # ①②：普通小文件开头不像任何容器
    R1 = os.path.join(T, 'r1', 'romfs'); build(R1, lambda i: b'DATA' + i.to_bytes(4, 'little') + bytes(500))
    n, got = run(R1)
    ck(n == 3 and got == {k: dic[k] for k in (101, 102, 103)},
       f'收到字典 3 本（101 直接放 / 102 在 SARC / 103 在 zstd 包的 SARC），内容一致：真结果 {n} 本、号 {sorted(got)}、一致 {got == {k: dic[k] for k in (101, 102, 103)}}')
    want = sorted(os.path.join('r1', 'romfs', 'pack', f) for f in ('a.zsdic', 'b.sarc', 'c.sarc.zs'))
    ck(sorted(reads) == want, f'读到文件尾的只有真带字典的 3 个（期望 {want}）：真结果 {len(reads)} 个{"" if len(reads) > 8 else "：" + str(sorted(reads))}')
    # ③：N 个开头像 SARC 的坏文件，都得整读，排队要有界
    R2 = os.path.join(T, 'r2', 'romfs'); build(R2, lambda i: b'SARC' + bytes(60))
    n, got = run(R2)
    ck(n == 3 and sorted(got) == [101, 102, 103], f'坏 SARC 混在里面不影响收字典：真结果 {n} 本、号 {sorted(got)}')
    ck(live[1] <= 4 * PJ, f'排队里同时压着的任务 ≤ {4 * PJ}（读线程 {PJ}，共 {N + 3} 个要整读）：真结果最多 {live[1]} 个')
finally:
    shutil.rmtree(T, ignore_errors=True)
print(f'字典收集按头筛选单测：{"全过" if fail == 0 else f"{fail} 项不过"}'); sys.exit(1 if fail else 0)
