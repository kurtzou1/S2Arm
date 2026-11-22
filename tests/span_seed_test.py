#!/usr/bin/env python3
"""tools/span_seed.py 单测。每份合成日志是一局；期望值按 span_seed.py 头注释的规则手算，不跑实现取期望。"""
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FF = '[起局] nnMain → 首帧上屏（游戏自身加载 + 渲染器首帧） +1500.0 ms'
def lay(pid): return '[s2a] 布局：程序号 %s 类型 3 SystemResourceSize 0｜别名 0x7780000000+0x200000000' % pid.lower()
def span(win, need, s, oob=None):
    t = '[s2a] 地址按需 [收局]：宿主占到 0x70c0000000 +%d MB（标准布局要 %d MB），本局所需跨度 %d MB' % (win, need, s)
    return t + ('（碰到的最高地址 − 窗口基址），越界映射 %d 次' % oob if oob is not None else '')
def far(n): return '[s2a] 远端 [收局]：影子区用 0 MB（堆区外 0 MB）；缺页 %d 次、代执行 0 次、跳过（缓存维护 / 预取）0 次、失败 0 次；游戏代码访存点 0 个' % n
A, B, C, D, E = '0100000000000A00', '0100000000000B00', '0100000000000C00', '0100000000000D00', '0100000000000E00'
logs = {
    # A：一局贴顶（62080 ≥ 62464 − 512 = 61952）不收，一局 16000 收 → 种子 16000、1 条
    'a1': [lay(A), FF, span(62464, 70000, 62080, 0), far(0)],
    'a2': [lay(A), FF, span(62464, 70000, 16000, 0)],
    # B：贴顶但越界映射 3 次 → 收 62400
    'b1': [lay(B), FF, span(62464, 70000, 62400, 3)],
    # C：贴顶、越界 0，但远端缺页 12 次 → 收 62300
    'c1': [lay(C), FF, span(62464, 70000, 62300, 0), far(12)],
    # D：只有贴顶样本（旧格式行，没有越界次数）→ 不收、不出现
    'd1': [lay(D), FF, span(49152, 70120, 49152)],
    # E：61951 = 窗口 − 513，不算贴顶 → 收；另一局没出首帧（不收）
    'e1': [lay(E), FF, span(62464, 70000, 61951, 0)],
    'e2': [lay(E), span(62464, 70000, 300, 0)],
}
bad = 0
def ck(ok, msg):
    global bad
    bad += 0 if ok else 1
    print(('✓ ' if ok else '✗ ') + msg)
with tempfile.TemporaryDirectory() as d:
    for k, v in logs.items():
        os.makedirs(os.path.join(d, 'r', k), exist_ok=True)
        open(os.path.join(d, 'r', k, '0000.txt'), 'w', encoding='utf-8').write('\n'.join(v) + '\n')
    out, tsv = os.path.join(d, 'seed.inc'), os.path.join(d, 'seed.tsv')
    r = subprocess.run([sys.executable, os.path.join(H, 'tools', 'span_seed.py'), os.path.join(d, 'r'), '--out', out, '--min-samples', '1', '--tsv', tsv], capture_output=True, text=True)
    ck(r.returncode == 0, 'span_seed.py 跑通（rc=%d %s）' % (r.returncode, r.stderr.strip()[-200:]))
    got = {}
    for line in open(tsv, encoding='utf-8').read().splitlines()[1:]:
        p, mx, n = line.split('\t'); got[p] = (int(mx), int(n))
    ck(got.get(A) == (16000, 1), 'A 贴顶 62080 不收、16000 收 → (16000, 1)，得 %s' % (got.get(A),))
    ck(got.get(B) == (62400, 1), 'B 贴顶但越界映射 3 次 → 收 (62400, 1)，得 %s' % (got.get(B),))
    ck(got.get(C) == (62300, 1), 'C 贴顶但远端缺页 12 次 → 收 (62300, 1)，得 %s' % (got.get(C),))
    ck(D not in got, 'D 只有贴顶样本（旧格式行）→ 不出现，得 %s' % (got.get(D),))
    ck(got.get(E) == (61951, 1), 'E 窗口 − 513 不算贴顶、没首帧那局不收 → (61951, 1)，得 %s' % (got.get(E),))
    ck(len(got) == 4, '共 4 款（A B C E），得 %d' % len(got))
print('span_seed 单测：%s' % ('全过' if not bad else '%d 处不符' % bad))
sys.exit(1 if bad else 0)
