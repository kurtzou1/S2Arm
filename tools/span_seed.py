#!/usr/bin/env python3
"""各款「实测最高地址」种子表（runtime/src/span_seed.inc）：从诊断报告目录里的局日志按款取最大，随宿主出壳下发。

只收窗口放不下标准布局的局（「地址按需 [收局] / [崩溃时]：宿主占到 +W MB（标准布局要 N MB），本局所需跨度 S MB」且 W < N）：
放得下标准布局的局按标准排，跨度总约等于整份布局，不反映游戏实际要多少。一局的游戏号取它之前最近的「布局：程序号 X」行。
每款取所有读数的最大值（别人设备上的极端值照收，宁可保守），读数少于 --min-samples 的款不收。

用法：tools/span_seed.py <报告目录> [--out runtime/src/span_seed.inc] [--min-samples 2] [--tsv 清单.tsv]

发版：切候选前在有诊断报告库的那台机器上跑一次（报告目录 = 诊断收取的 reports/），生成的 span_seed.inc 有变化就提交进 main 再切。
  span_seed.inc 在壳输入表里（runtime/src），表一变壳号就变，随启动器带的壳下发；不重出游戏包。
用途（runtime/src/vawin.c s2a_span_seed / s2a_window_span_seen，取本机记录与种子表的较大值）：
  ① 窗口放不下标准布局时快照区放不放得下：空洞 ≥ 已知最高跨度 + 2 GB 余量 + 6 GB（宿主 3 GB + 快照区 3 GB）才放，不知道也放；
  ② 「地址空间不够」提示只在已知最高跨度大于窗口时弹；③ 窗口按跨度收窄（× 1.25 + 2 GB）。
"""
import argparse
import os
import re
import sys

LAYOUT = re.compile(r'布局：程序号 ([0-9a-fA-F]{16}) ')
FIRST_FRAME = '首帧上屏'   # 宿主起局计时行「[起局] nnMain → 首帧上屏」（host_main.c）：这局出过第一帧
SPAN = re.compile(r'地址按需 \[(?:收局|崩溃时)\]：宿主占到 0x[0-9a-f]+ \+(\d+) MB（标准布局要 (\d+) MB），本局所需跨度 (\d+) MB')


def readings(text):
    """一份局日志里的 (游戏号, 窗口 MB, 标准布局 MB, 跨度 MB)，只收窗口放不下标准布局的。"""
    pid = None
    for line in text.splitlines():
        m = LAYOUT.search(line)
        if m:
            pid = m.group(1).upper()
            continue
        m = SPAN.search(line)
        if m and pid:
            win, need, span = (int(x) for x in m.groups())
            if 0 < span and win < need:
                yield pid, win, need, span


def collect(root):
    seen = {}
    for dp, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith('.txt'):
                continue
            try:
                text = open(os.path.join(dp, f), encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            if FIRST_FRAME not in text:   # D-PR33 / D-99XJ（11-21）：没出过首帧的局（窗口太小、开局要堆就停掉 / 游戏自己 Break）只碰到几百 MB，
                continue                  #   收进种子会把窗口再收小、下一局照样停——自我强化。只收上过屏的局
            for pid, win, need, span in readings(text):
                mx, n = seen.get(pid, (0, 0))
                seen[pid] = (max(mx, span), n + 1)
    return seen


def render(seen, min_samples):
    rows = sorted((int(p, 16), mx, n) for p, (mx, n) in seen.items() if n >= min_samples)
    out = ['// 生成文件，勿手改：tools/span_seed.py（各款在放不下标准布局的局里实测碰到的最高地址 − 窗口基址，取最大；样本数 = 收局 / 崩溃读数条数）',
           '// {程序号, 最高跨度 MB, 样本数}，按程序号升序（vawin.c s2a_span_seed 二分查）']
    out += ['{0x%016XULL, %d, %d},' % r for r in rows]
    return '\n'.join(out) + '\n', rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('reports')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), '..', 'runtime', 'src', 'span_seed.inc'))
    ap.add_argument('--min-samples', type=int, default=2)
    ap.add_argument('--tsv')
    a = ap.parse_args()
    seen = collect(a.reports)
    text, rows = render(seen, a.min_samples)
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(text)
    if a.tsv:
        with open(a.tsv, 'w', encoding='utf-8') as f:
            f.write('程序号\t最高跨度MB\t样本数\n')
            for p, mx, n in rows:
                f.write('%016X\t%d\t%d\n' % (p, mx, n))
    print('种子表：%d 款（读数 ≥ %d 条），另有 %d 款样本不足未收 → %s' % (len(rows), a.min_samples, len(seen) - len(rows), a.out))


if __name__ == '__main__':
    sys.exit(main())
