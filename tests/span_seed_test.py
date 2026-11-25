#!/usr/bin/env python3
"""tools/span_seed.py 单测（11-24 快照被关根修：版本过滤、贴顶带 max(2 GiB, 10%)、p99、要整个窗口）。每份合成日志是一局；期望值按 span_seed.py 头注释的规则手算，不跑实现取期望。"""
import json, os, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FF = '[起局] nnMain → 首帧上屏（游戏自身加载 + 渲染器首帧） +1500.0 ms'
def lay(pid): return '[s2a] 布局：程序号 %s 类型 3 SystemResourceSize 0｜别名 0x7780000000+0x200000000' % pid.lower()
def span(win, need, s, oob=None):
    t = '[s2a] 地址按需 [收局]：宿主占到 0x70c0000000 +%d MB（标准布局要 %d MB），本局所需跨度 %d MB' % (win, need, s)
    return t + ('（碰到的最高地址 − 窗口基址），越界映射 %d 次' % oob if oob is not None else '')
def far(n): return '[s2a] 远端 [收局]：影子区用 0 MB（堆区外 0 MB）；缺页 %d 次、代执行 0 次、跳过（缓存维护 / 预取）0 次、失败 0 次；游戏代码访存点 0 个' % n
def sq(n): return '[s2a] 远端 [收局]：快照区让掉的那段窗口 0x7f00000000 +3072 MB 被碰 %d 次（不让的话都在窗口里）' % n
A, B, C, D, E, F = ('0100000000000%s00' % x for x in 'ABCDEF')   # 程序号要十六进制（布局行按 [0-9a-f] 认）
PG, PH, PI, PJ = ('0100000000000%s00' % x for x in '1234')
V = '0.6.9'
logs = {   # 键 → (版本（None = 没有 report.json）, 行)
    # A：一局贴顶（62080 ≥ 62464 − 6246.4 = 56217.6）不收，一局 16000 收 → 种子 16000、1 条
    'a1': (V, [lay(A), FF, span(62464, 70000, 62080, 0), far(0)]),
    'a2': (V, [lay(A), FF, span(62464, 70000, 16000, 0)]),
    # B：贴顶但越界映射 3 次 → 收 62400
    'b1': (V, [lay(B), FF, span(62464, 70000, 62400, 3)]),
    # C：贴顶、越界 0，但远端缺页 12 次 → 收 62300
    'c1': (V, [lay(C), FF, span(62464, 70000, 62300, 0), far(12)]),
    # D：只有贴顶样本（旧格式行，没有越界次数；窗口 49152 带宽 4915.2）→ 不收、不出现
    'd1': (V, [lay(D), FF, span(49152, 70120, 49152)]),
    # E：56217 < 56217.6 不算贴顶 → 收；56218 算贴顶不收；另一局没出首帧（不收）
    'e1': (V, [lay(E), FF, span(62464, 70000, 56217, 0)]),
    'e2': (V, [lay(E), span(62464, 70000, 300, 0)]),
    'e3': (V, [lay(E), FF, span(62464, 70000, 56218, 0)]),
    # F：版本 0.5.2（#1441 前）不收、0.5.3 收、读不到版本不收 → (20000, 1)
    'f1': ('0.5.2', [lay(F), FF, span(40000, 70000, 30000, 0)]),
    'f2': ('0.5.3', [lay(F), FF, span(40000, 70000, 20000, 0)]),
    'f3': (None, [lay(F), FF, span(40000, 70000, 25000, 0)]),
    # H：让过窗口 3 局、被碰的 2 局（≥ 2 且 2 × 20 ≥ 3）→ 要整个窗口；跨度一局 12000
    'h1': (V, [lay(PH), FF, span(40000, 70000, 12000, 0), sq(5)]),
    'h2': (V, [lay(PH), sq(3)]),
    'h3': (V, [lay(PH), sq(0)]),
    # J：只有让窗口的局（2 局都被碰）、没有跨度样本 → 照收，跨度 0、样本 0、要整个窗口
    'j1': (V, [lay(PJ), sq(1)]), 'j2': (V, [lay(PJ), sq(2)]),
}
# G：p99（最近秩）：100 局跨度 100、200 … 10000 MB → 第 ⌈0.99 × 100⌉ = 99 小 = 9900（取最大是 10000）
for k in range(1, 101): logs['g%d' % k] = (V, [lay(PG), FF, span(40000, 70000, 100 * k, 0)])
# I：让过窗口 50 局、被碰的 2 局（2 × 20 = 40 < 50，不到 5%）→ 不算；跨度一局 11000
for k in range(1, 51): logs['i%d' % k] = (V, [lay(PI), FF] + ([span(40000, 70000, 11000, 0)] if k == 1 else []) + [sq(1 if k <= 2 else 0)])
bad = 0
def ck(ok, msg):
    global bad
    bad += 0 if ok else 1
    print(('✓ ' if ok else '✗ ') + msg)
with tempfile.TemporaryDirectory() as d:
    for k, (ver, v) in logs.items():
        os.makedirs(os.path.join(d, 'r', k, 'logs'), exist_ok=True)
        if ver: open(os.path.join(d, 'r', k, 'report.json'), 'w', encoding='utf-8').write(json.dumps({'package': {'version': ver}}))
        open(os.path.join(d, 'r', k, 'logs', '0000.txt'), 'w', encoding='utf-8').write('\n'.join(v) + '\n')
    out, tsv = os.path.join(d, 'seed.inc'), os.path.join(d, 'seed.tsv')
    r = subprocess.run([sys.executable, os.path.join(H, 'tools', 'span_seed.py'), os.path.join(d, 'r'), '--out', out, '--min-samples', '1', '--tsv', tsv], capture_output=True, text=True)
    ck(r.returncode == 0, 'span_seed.py 跑通（rc=%d %s）' % (r.returncode, r.stderr.strip()[-200:]))
    got = {}
    for line in open(tsv, encoding='utf-8').read().splitlines()[1:]:
        p, mx, n, w = line.split('\t'); got[p] = (int(mx), int(n), int(w))
    ck(got.get(A) == (16000, 1, 0), 'A 贴顶 62080 不收、16000 收 → (16000, 1, 0)，得 %s' % (got.get(A),))
    ck(got.get(B) == (62400, 1, 0), 'B 贴顶但越界映射 3 次 → 收 (62400, 1, 0)，得 %s' % (got.get(B),))
    ck(got.get(C) == (62300, 1, 0), 'C 贴顶但远端缺页 12 次 → 收 (62300, 1, 0)，得 %s' % (got.get(C),))
    ck(D not in got, 'D 只有贴顶样本（旧格式行）→ 不出现，得 %s' % (got.get(D),))
    ck(got.get(E) == (56217, 1, 0), 'E 带宽 max(2 GiB, 10%%)：56217 收、56218 不收、没首帧那局不收 → (56217, 1, 0)，得 %s' % (got.get(E),))
    ck(got.get(F) == (20000, 1, 0), 'F 0.5.2 不收、0.5.3 收、没版本不收 → (20000, 1, 0)，得 %s' % (got.get(F),))
    ck(got.get(PG) == (9900, 100, 0), 'G 100 局取 p99 = 9900（不是最大 10000）→ (9900, 100, 0)，得 %s' % (got.get(PG),))
    ck(got.get(PH) == (12000, 1, 1), 'H 让窗口 3 局被碰 2 局 → 要整个窗口 (12000, 1, 1)，得 %s' % (got.get(PH),))
    ck(got.get(PI) == (11000, 1, 0), 'I 让窗口 50 局被碰 2 局（不到 5%%）→ 不算 (11000, 1, 0)，得 %s' % (got.get(PI),))
    ck(got.get(PJ) == (0, 0, 1), 'J 只有被碰的让窗口局 → (0, 0, 1)，得 %s' % (got.get(PJ),))
    ck(len(got) == 9, '共 9 款（A B C E F G H I J），得 %d' % len(got))
print('span_seed 单测：%s' % ('全过' if not bad else '%d 处不符' % bad))
sys.exit(1 if bad else 0)
