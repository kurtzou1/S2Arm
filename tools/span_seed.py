#!/usr/bin/env python3
"""各款「实测最高地址」种子表（runtime/src/span_seed.inc）：从诊断报告目录里的局日志按款取最大，随宿主出壳下发。

只收窗口放不下标准布局的局（「地址按需 [收局] / [崩溃时]：宿主占到 +W MB（标准布局要 N MB），本局所需跨度 S MB」且 W < N）：
放得下标准布局的局按标准排，跨度总约等于整份布局，不反映游戏实际要多少。一局的游戏号取它之前最近的「布局：程序号 X」行。
每款取读数的 p99（最近秩），读数少于 --min-samples 的款不收（11-24 快照被关根修 ③：原先取最大，一份 #1441 前的老局把一款 Switch 2 大作（0400486024DEC000）
  顶到 62495 MB，iOS 上 183 局因此关了快照；重生成后 21961）。
只收 #1441 起的版本（--min-version，缺省 0.5.3：报给游戏的别名区收到窗口末从这版起，之前的局别名区伸出窗口、远端缺页上千万次，跨度不代表游戏要多少）；
  版本取局日志所在诊断报告的 report.json（package.version，原始包 app.version），读不到版本的不收。
贴顶样本不收（11-22 宿主下限复核；11-24 带宽从 512 MB 放宽到 max(2 GiB, 窗口 10%)，同 runtime/src/vawin.c s2a_span_top_margin）：跨度贴着窗口末的局，
  跨度是跟着窗口走的（别名区报到窗口末、游戏贴着顶映射：异度神剑3 六局窗口都是 62464、跨度都是 62080；同一款修后窗口缩到 53248 MB 时远端缺页 0 次），
  不代表游戏要多少；收进来会把「地址空间不够」提示和快照区放不放得下判反。例外：那一局有越界映射（「越界映射 N 次」N > 0）或远端缺页
  （「远端 [...]：…缺页 N 次」N > 0）——游戏真碰到了窗口外，贴顶也收。
「要整个窗口」（第 4 列，快照被关根修 ④）：开着快照、快照区让了窗口的局里，让掉的那段被碰过（「快照区让掉的那段窗口 … 被碰 N 次」N > 0，far.c）
  的局 ≥ 2 局且 ≥ 这款让过窗口的局的 5%：这款快照区不再从窗口里让（vawin.c s2a_span_seed_whole）。只按这一行判：更外面的远端缺页不让也有，与快照无关。

用法：tools/span_seed.py <报告目录> [--out runtime/src/span_seed.inc] [--min-samples 2] [--tsv 清单.tsv]

发版：切候选前在有诊断报告库的那台机器上跑一次（报告目录 = 诊断收取的 reports/），生成的 span_seed.inc 有变化就提交进 main 再切。
  span_seed.inc 在壳输入表里（runtime/src），表一变壳号就变，随启动器带的壳下发；不重出游戏包。
用途（runtime/src/vawin.c s2a_span_seed / s2a_window_span_seen，取本机记录与种子表的较大值）：
  ① 窗口放不下标准布局时快照区放不放得下：空洞 ≥ 已知最高跨度 + 2 GB 余量 + 宿主下限 + 快照区 3 GB 才放，不知道也放；
  ② 「地址空间不够」提示只在已知最高跨度大于窗口时弹；③ 窗口按跨度收窄（× 1.25 + 2 GB）。
"""
import argparse
import json
import math
import os
import re
import sys

LAYOUT = re.compile(r'布局：程序号 ([0-9a-fA-F]{16}) ')
FIRST_FRAME = '首帧上屏'   # 宿主起局计时行「[起局] nnMain → 首帧上屏」（host_main.c）：这局出过第一帧
SPAN = re.compile(r'地址按需 \[(?:收局|崩溃时)\]：宿主占到 0x[0-9a-f]+ \+(\d+) MB（标准布局要 (\d+) MB），本局所需跨度 (\d+) MB(?:（[^）]*），越界映射 (\d+) 次)?')
FAR = re.compile(r'远端 \[[^\]]+\]：影子区用 \d+ MB（堆区外 \d+ MB）；缺页 (\d+) 次')
SQUEEZE = re.compile(r'快照区让掉的那段窗口 0x[0-9a-f]+ \+\d+ MB 被碰 (\d+) 次')


def top_margin_mb(win):
    """贴顶带（MB）：max(2 GiB, 窗口 10%)，同 vawin.c s2a_span_top_margin。"""
    return max(2048, win // 10)


def version_ok(v, floor):
    try:
        return tuple(int(x) for x in v.split('.')[:3]) >= tuple(int(x) for x in floor.split('.'))
    except (AttributeError, ValueError):
        return False


def report_version(dirpath, cache):
    """局日志所在诊断报告（往上找 report.json）的 app.version；找不到 None。"""
    d = dirpath
    while d and d not in cache:
        f = os.path.join(d, 'report.json')
        if os.path.isfile(f):
            try:
                j = json.load(open(f, encoding='utf-8', errors='ignore'))   # 诊断收取整理后的报告：package.version；原始诊断包：app.version
                cache[d] = (j.get('package') or {}).get('version') or (j.get('app') or {}).get('version')
            except (OSError, ValueError):
                cache[d] = None
            break
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up
    return cache.get(d)


def p99(vals):
    """最近秩 p99。"""
    v = sorted(vals)
    return v[max(0, math.ceil(0.99 * len(v)) - 1)]


def readings(text):
    """一份局日志里的 (游戏号, 窗口 MB, 标准布局 MB, 跨度 MB)，只收窗口放不下标准布局的、不贴顶的（贴顶但碰过窗口外的照收）。"""
    pid = None
    far = max((int(x) for x in FAR.findall(text)), default=0)   # 这份日志里远端缺页最多的一次读数（同一局的 [C# 初始化后] / [收局] 取大）
    for line in text.splitlines():
        m = LAYOUT.search(line)
        if m:
            pid = m.group(1).upper()
            continue
        m = SPAN.search(line)
        if m and pid:
            win, need, span = (int(x) for x in m.groups()[:3])
            oob = int(m.group(4) or 0)
            if 0 < span and win < need and (span < win - top_margin_mb(win) or oob > 0 or far > 0):
                yield pid, win, need, span


def squeeze_runs(text):
    """一份局日志里让过窗口的局：(游戏号, 让掉的那段被碰次数)。游戏号取那一行之前最近的「布局：程序号」。"""
    pid = None
    for line in text.splitlines():
        m = LAYOUT.search(line)
        if m:
            pid = m.group(1).upper()
            continue
        m = SQUEEZE.search(line)
        if m and pid:
            yield pid, int(m.group(1))


def collect(root, min_version='0.5.3'):
    seen, sq, vcache = {}, {}, {}
    for dp, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith('.txt'):
                continue
            if not version_ok(report_version(dp, vcache), min_version):   # #1441 前（或读不到版本）的局不收
                continue
            try:
                text = open(os.path.join(dp, f), encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            last = {}
            for pid, hits in squeeze_runs(text):   # 同一局收局 / 崩溃时各报一次：取这份日志里每款最后一次（累计数）
                last[pid] = hits
            for pid, hits in last.items():
                a, b = sq.get(pid, (0, 0))
                sq[pid] = (a + 1, b + (hits > 0))
            if FIRST_FRAME not in text:   # D-PR33 / D-99XJ（11-21）：没出过首帧的局（窗口太小、开局要堆就停掉 / 游戏自己 Break）只碰到几百 MB，
                continue                  #   收进种子会把窗口再收小、下一局照样停——自我强化。只收上过屏的局
            for pid, win, need, span in readings(text):
                seen.setdefault(pid, []).append(span)
    return seen, sq


def whole(sq_entry):
    """让过窗口的局里让掉的那段被碰过的 ≥ 2 局且 ≥ 5%。"""
    runs, hit = sq_entry
    return hit >= 2 and hit * 20 >= runs


def render(seen, sq, min_samples):
    rows = sorted((int(p, 16), p99(v), len(v), int(whole(sq.get(p, (0, 0))))) for p, v in seen.items() if len(v) >= min_samples)
    have = {r[0] for r in rows}
    rows += [(int(p, 16), 0, 0, 1) for p, e in sq.items() if whole(e) and int(p, 16) not in have]   # 只有「要整个窗口」、跨度样本不够的款也收（跨度 0 = 不知道）
    rows.sort()
    out = ['// 生成文件，勿手改：tools/span_seed.py（#1441 起的版本、放不下标准布局、不贴顶的局里实测碰到的最高地址 − 窗口基址，取 p99；样本数 = 收局 / 崩溃读数条数）',
           '// {程序号, 最高跨度 p99 MB, 样本数, 要整个窗口}，按程序号升序（vawin.c s2a_span_seed / s2a_span_seed_whole 二分查）']
    out += ['{0x%016XULL, %d, %d, %d},' % r for r in rows]
    return '\n'.join(out) + '\n', rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('reports')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), '..', 'runtime', 'src', 'span_seed.inc'))
    ap.add_argument('--min-samples', type=int, default=2)
    ap.add_argument('--tsv')
    ap.add_argument('--min-version', default='0.5.3')
    a = ap.parse_args()
    seen, sq = collect(a.reports, a.min_version)
    text, rows = render(seen, sq, a.min_samples)
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(text)
    if a.tsv:
        with open(a.tsv, 'w', encoding='utf-8') as f:
            f.write('程序号\t最高跨度p99MB\t样本数\t要整个窗口\n')
            for p, mx, n, w in rows:
                f.write('%016X\t%d\t%d\t%d\n' % (p, mx, n, w))
    print('种子表：%d 款（读数 ≥ %d 条），另有 %d 款样本不足未收 → %s' % (len(rows), a.min_samples, sum(1 for v in seen.values() if len(v) < a.min_samples), a.out))


if __name__ == '__main__':
    sys.exit(main())
