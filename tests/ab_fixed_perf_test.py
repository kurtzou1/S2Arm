#!/usr/bin/env python3
"""对照局读数（tools/ab_fixed_perf.py）单测：合成局目录（host.log + frames.tsv），期望按构造手算。
  每局回放段帧 100–200（100 帧）；段外的帧故意放极端值，只要漏取段界就会算错。
  A 组两局帧间隔 20 ms、B 组两局 10 ms（B 的一局 p95 处有一帧 30 ms）→ 帧间隔 p50 B÷A = 0.5、超出同组波动；
  ① 中位与比值 ② 段外的帧不进读数 ③ power 行只取段内 ④ 足迹取整局峰值 ⑤ 两组回放段帧数差 > 1% → 不判、退出 2
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

H = Path(__file__).resolve().parents[1]
bad = 0


def check(ok, msg):
    global bad
    print(('✓ ' if ok else '✗ ') + msg)
    bad += not ok


def mk(root, name, a, b, ms, spike=None, power=(1.0, 2.0), foot=(1000, 1200)):
    d = Path(root) / name
    d.mkdir()
    rows = ['frame\twall_us\tdisp_us\tgpu_us\tdraw_n\tpass_n\talloc_b\tgc0\tgc1\tgc2\tgc_pause_us']
    for fr in range(1, b + 50):
        inside = a < fr <= b
        w = ms * 1000 if inside else 999000           # 段外 999 ms：漏了段界 p95 / 最大会变成 999
        if inside and spike and fr == b:
            w = spike * 1000
        rows.append(f'{fr}\t{w}\t\t{5000 if inside else 0}\t1\t1\t{1024 if inside else 10 ** 9}\t0\t0\t0\t{100 if inside else 10 ** 6}')
    (d / 'frames.tsv').write_text('\n'.join(rows) + '\n', encoding='utf-8')
    log = [f'[s2a] [nvn] power up to frame {a - 10}: CPU energy 9.00 W, 999.0 mJ per frame (60.0 fps)',   # 段前，不取
           f'[s2a] [nvn] power up to frame {a + 50}: CPU energy 1.00 W, {power[0]} mJ per frame (60.0 fps)',
           f'[s2a] [nvn] power up to frame {b}: CPU energy 1.00 W, {power[1]} mJ per frame (60.0 fps)',
           f'[S2A 内存] 第 30 秒：GC 堆 1 MB；进程足迹 {foot[0]} MB、系统给本进程剩余 取不到',
           f'[S2A 内存] 第 60 秒：GC 堆 1 MB；进程足迹 {foot[1]} MB、系统给本进程剩余 取不到',
           f'对照局：固定输入回放段 帧 {a}–{b}（{b - a} 帧）']
    (d / 'host.log').write_text('\n'.join(log) + '\n', encoding='utf-8')
    return str(d)


def run(a, b):
    p = subprocess.run([sys.executable, str(H / 'tools/ab_fixed_perf.py'), '--a', *a, '--b', *b], capture_output=True, text=True)
    return p.returncode, json.loads(p.stdout.strip().splitlines()[-1])


with tempfile.TemporaryDirectory() as t:
    A = [mk(t, 'a1', 100, 200, 20), mk(t, 'a2', 100, 200, 20, foot=(1000, 1400))]
    B = [mk(t, 'b1', 100, 200, 10, spike=30), mk(t, 'b2', 100, 200, 10, power=(3.0, 4.0))]
    rc, j = run(A, B)
    m = j['metrics']
    check(rc == 0 and j['verdict'] == '已比', f"两组各 2 局、回放段同为 100 帧：已比（实 退出 {rc}、{j['verdict']}）")
    check(m['帧间隔p50_ms']['a'] == 20 and m['帧间隔p50_ms']['b'] == 10 and m['帧间隔p50_ms']['ratio'] == 0.5 and m['帧间隔p50_ms']['beyond'],
          f"① 帧间隔 p50：A 20、B 10、B÷A 0.5、超出同组波动（实 {m['帧间隔p50_ms']}）")
    check(m['帧间隔最大_ms']['b_range'] == [10, 30] and m['帧间隔最大_ms']['a'] == 20,
          f"② 段外 999 ms 的帧不进读数：A 最大 20、B 两局最大 30 / 10（实 {m['帧间隔最大_ms']}）")
    check(m['每帧分配_KB']['a'] == 1.0 and m['GC停顿_ms']['a'] == 10.0, f"② 段内每帧分配 1 KB、GC 停顿 100 帧 × 0.1 ms = 10 ms（实 {m['每帧分配_KB']}、{m['GC停顿_ms']}）")
    check(m['每帧CPU能耗_mJ']['a'] == 1.5 and m['每帧CPU能耗_mJ']['b_range'] == [1.5, 3.5],
          f"③ 每帧 CPU 能耗只取段内两行：A (1+2)/2 = 1.5，B 一局 3.5（实 {m['每帧CPU能耗_mJ']}）")
    check(m['进程足迹峰值_MB']['a_range'] == [1200, 1400], f"④ 足迹取整局峰值 1200 / 1400（实 {m['进程足迹峰值_MB']}）")
    # 【负对照开始】回放段帧数不一致：B 只放了 80 帧，读数不可比，不判
    C = [mk(t, 'c1', 100, 180, 10), mk(t, 'c2', 100, 180, 10)]
    rc, j = run(A, C)
    check(rc == 2 and j['verdict'] == '不判', f"⑤ A 100 帧、B 80 帧：不判、退出 2（实 退出 {rc}、{j['verdict']}：{j['why']}）")
    # 【负对照结束】

print(f"{'✗' if bad else '✓'} ab_fixed_perf：{bad} 项不符")
sys.exit(1 if bad else 0)
