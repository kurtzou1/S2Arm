#!/usr/bin/env python3
"""对照局性能 / 内存读数（docs/对照局模板.md 的 perf 模式，tools/ab_fixed.sh 调）。

每局都是同一份即时存档起点 + 同一段手柄回放（tests/autoplay/autoplay.c 对照局分支），宿主日志里有一行
「对照局：固定输入回放段 帧 a–b（n 帧）」。只取这段帧（按进度定窗口，不按墙钟）：
  逐帧表 frames.tsv（宿主每帧一行：wall_us 帧间隔、gpu_us、alloc_b 托管分配、gc_pause_us）→ 帧间隔 p50 / p95 / 最大、GPU 均值、每帧分配、GC 停顿；
  host.log「power up to frame N: CPU energy X W, Y mJ per frame」N 落在段内的行 → 每帧 CPU 能耗均值；
  host.log「[S2A 内存] … 进程足迹 X MB」→ 整局峰值（恢复局从起点到回放完，整局就是这段）。
两组（A / B）各取各局的中位，给 B ÷ A；同组各局的最小–最大当波动，B 的范围与 A 的范围不重叠才写「超出同组波动」。
两组回放段帧数差 > 1% 时整份不判（输入没放成同一段，读数不可比）。

用法：ab_fixed_perf.py --a <局目录>… --b <局目录>…   末行 JSON {verdict, metrics:{名: {a, b, ratio, a_range, b_range, beyond}}, why}
"""
import argparse
import json
import re
import statistics
import sys
from pathlib import Path

SEG = re.compile(r'对照局：固定输入回放段 帧 (\d+)–(\d+)')
POWER = re.compile(r'power up to frame (\d+): CPU energy ([\d.]+) W, ([\d.]+) mJ per frame')
FOOT = re.compile(r'\[S2A 内存\].*?进程足迹 (\d+) MB')


def pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]


def one(d):
    d = Path(d)
    log = (d / 'host.log').read_text(encoding='utf-8', errors='replace')
    m = SEG.search(log)
    if not m:
        raise ValueError(f'{d}: host.log 没有「对照局：固定输入回放段」行（不是对照局，或回放没放成）')
    a, b = int(m.group(1)), int(m.group(2))
    wall, gpu, alloc, gcp = [], [], 0, 0
    with open(d / 'frames.tsv', encoding='utf-8') as f:
        head = f.readline().rstrip('\n').split('\t')
        ix = {k: head.index(k) for k in ('frame', 'wall_us', 'gpu_us', 'alloc_b', 'gc_pause_us')}
        for line in f:
            c = line.rstrip('\n').split('\t')
            try:
                fr = int(c[ix['frame']])
            except (ValueError, IndexError):
                continue
            if not a < fr <= b:
                continue
            if c[ix['wall_us']]:
                wall.append(int(c[ix['wall_us']]) / 1000)
            if c[ix['gpu_us']]:
                gpu.append(int(c[ix['gpu_us']]) / 1000)
            alloc += int(c[ix['alloc_b']] or 0)
            gcp += int(c[ix['gc_pause_us']] or 0)
    if not wall:
        raise ValueError(f'{d}: frames.tsv 在帧 {a}–{b} 之间没有行')
    mj = [float(x[2]) for x in POWER.findall(log) if a < int(x[0]) <= b]
    foot = [int(x) for x in FOOT.findall(log)]
    r = {'帧间隔p50_ms': statistics.median(wall), '帧间隔p95_ms': pct(wall, 95), '帧间隔最大_ms': max(wall),
         'GPU均值_ms': statistics.mean(gpu) if gpu else None, '每帧分配_KB': alloc / len(wall) / 1024, 'GC停顿_ms': gcp / 1000,
         '每帧CPU能耗_mJ': statistics.mean(mj) if mj else None, '进程足迹峰值_MB': max(foot) if foot else None}
    return b - a, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--a', nargs='+', required=True)
    ap.add_argument('--b', nargs='+', required=True)
    o = ap.parse_args()
    runs = {k: [one(d) for d in getattr(o, k)] for k in ('a', 'b')}
    na = [n for n, _ in runs['a']]
    nb = [n for n, _ in runs['b']]
    allf = na + nb
    if max(allf) > min(allf) * 1.01:
        print(json.dumps({'verdict': '不判', 'metrics': {}, 'why': f'回放段帧数不一致：A {na}、B {nb}（差 > 1%，输入没放成同一段）'}, ensure_ascii=False))
        return 2
    out = {}
    for k in runs['a'][0][1]:
        va = [r[k] for _, r in runs['a'] if r[k] is not None]
        vb = [r[k] for _, r in runs['b'] if r[k] is not None]
        if not va or not vb:
            out[k] = None
            continue
        ma, mb = statistics.median(va), statistics.median(vb)
        beyond = max(vb) < min(va) or min(vb) > max(va)
        out[k] = {'a': round(ma, 3), 'b': round(mb, 3), 'ratio': round(mb / ma, 3) if ma else None,
                  'a_range': [round(min(va), 3), round(max(va), 3)], 'b_range': [round(min(vb), 3), round(max(vb), 3)], 'beyond': beyond}
        print(f"{k}\tA {ma:.3f}（{min(va):.3f}–{max(va):.3f}）\tB {mb:.3f}（{min(vb):.3f}–{max(vb):.3f}）\tB÷A {mb / ma if ma else float('nan'):.3f}\t{'超出同组波动' if beyond else '在同组波动内'}")
    print(json.dumps({'verdict': '已比', 'metrics': out, 'why': f'回放段 {allf[0]} 帧，A {len(na)} 局、B {len(nb)} 局'}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
