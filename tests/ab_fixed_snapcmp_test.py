#!/usr/bin/env python3
"""挪起点确定性判据（tools/ab_fixed_snapcmp.py）单测：合成两张 a_last.png，期望按构造写死——
  ① 同一张图（只加一点逐像素噪声）→ 一致、退出 0 ② 同一张图横移 1/4 屏 → 不一致、退出 1 ③ 缺图 → 读不出、退出 2"""
import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

H = Path(__file__).resolve().parents[1]
bad = 0


def check(ok, msg):
    global bad
    print(('✓ ' if ok else '✗ ') + msg)
    bad += not ok


def scene(d, shift=0, noise=0, seed=7):
    rnd = random.Random(seed)
    w, h = 512, 288
    base = [[rnd.randrange(256) for _ in range(w // 16)] for _ in range(h // 16)]   # 16 像素一格的随机块纹理
    nz = random.Random(seed + 1)
    im = Image.new('L', (w, h))
    im.putdata([max(0, min(255, base[y // 16][((x + shift) % w) // 16] + (nz.randint(-noise, noise) if noise else 0))) for y in range(h) for x in range(w)])
    Path(d).mkdir(parents=True, exist_ok=True)
    im.convert('RGB').save(f'{d}/a_last.png')


def run(a, b):
    p = subprocess.run([sys.executable, str(H / 'tools/ab_fixed_snapcmp.py'), a, b], capture_output=True, text=True)
    return p.returncode, json.loads(p.stdout.strip().splitlines()[-1])


with tempfile.TemporaryDirectory() as t:
    scene(f'{t}/a'); scene(f'{t}/b', noise=8)
    rc, j = run(f'{t}/a', f'{t}/b')
    check(rc == 0 and j['verdict'] == '一致', f"① 同一画面加 ±8 噪声：一致、退出 0（实 {rc}、{j['verdict']}、相关 {j['corr']}）")
    # 【负对照开始】走到的地方不同：横移 1/4 屏
    scene(f'{t}/c', shift=128)
    rc, j = run(f'{t}/a', f'{t}/c')
    check(rc == 1 and j['verdict'] == '不一致', f"② 横移 1/4 屏：不一致、退出 1（实 {rc}、{j['verdict']}、相关 {j['corr']}）")
    # 【负对照结束】
    rc, j = run(f'{t}/a', f'{t}/none')
    check(rc == 2 and j['verdict'] == '读不出', f"③ 缺 a_last.png：读不出、退出 2（实 {rc}、{j['verdict']}）")

print(f"{'✗' if bad else '✓'} ab_fixed_snapcmp：{bad} 项不符")
sys.exit(1 if bad else 0)
