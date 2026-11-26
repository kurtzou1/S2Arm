#!/usr/bin/env python3
"""固定路线计时（tools/route_speed.py）单测：合成「沿一条路线前进」的两局缩略图序列，期望按构造写死——
  场景：一张大的伪随机纹理，路线进度 p（米）决定画面：纹理按 p 横移、同时按景深缩放（往前走景物变大）；
    原帧率局 p = v·t，60 帧局 p = k·v·t，各加一点逐帧噪声（两局渲染不完全一样）。
  ① k = 1（按真实时间推进）：r ≈ 1 → 绿
  ② k = 2（按帧推进、开 60 帧变快）：r ≈ 2 → 红
  ③ 景深不同（同 v，场景缩放基数 3 倍）：k = 1 仍判绿、r 与 ① 相差 < 5%——画面位移 ρ 在这种对照下差 2.7 倍（#2201），路线计时不受影响
  ④ 60 帧局走的是另一条路线（纹理换一张）：判不出（有效张数不够）
  ⑤ 帧率比 q = 1.0（60 帧没开起来）：判不出
  ⑥ 文件格式往返：写成 S2RT 文件再 load，张数、时刻、内容一致
  反证（11-24 本机）：verdict 去掉 q < 1.3 那道门 → ⑤ 红（判成绿）。MIN_CORR 门槛在这组合成数据里不承重（去掉后 ④ 照样判不出：
    走岔的路线里找出的 t' 杂乱，r 既不近 1 也不近 q）；真机上它挡的是场景切换 / 遮挡那几张"""
import os
import random
import struct
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import route_speed as rs

W, H = 64, 36
bad = n = 0


def ck(name, ok):
    global bad, n
    n += 1
    bad += 0 if ok else 1
    print(('✓ ' if ok else '✗ ') + name)


def texture(seed, size=512):
    r = random.Random(seed)
    base = [[r.random() for _ in range(size)] for _ in range(size)]
    # 平滑一下，像真实画面（纯白噪声任何位移都不相关）
    sm = [[(base[y][x] + base[y][(x + 1) % size] + base[(y + 1) % size][x] + base[(y + 1) % size][(x + 1) % size]) / 4 for x in range(size)] for y in range(size)]
    return sm, size


def frame(tex, p, depth, noise_seed):
    t, size = tex
    s = depth / (depth + 0.0) if depth else 1.0
    zoom = 1.0 + p / (depth * 4.0)                 # 往前走景物变大，景深越近变得越快
    off = p * 6.0 / depth                          # 横移也按景深：近处走同样距离移得多
    r = random.Random(noise_seed)
    out = bytearray(W * H)
    for y in range(H):
        for x in range(W):
            sx = int((x - W / 2) / zoom + W / 2 + off) % size
            sy = int((y - H / 2) / zoom + H / 2 + 100) % size
            v = t[sy][sx] * 220 + r.random() * 6
            out[y * W + x] = max(0, min(255, int(v)))
    return bytes(out)


def run(tex, k, depth, secs=6.0, dt=0.1, v=1.0, seed=0):
    return [(i * dt, frame(tex, k * v * i * dt, depth, seed * 100000 + i)) for i in range(int(secs / dt) + 1)]


def main():
    tex = texture(1)
    a1 = run(tex, 1.0, 8.0, seed=1)
    b1 = run(tex, 1.0, 8.0, seed=2)
    r1 = rs.verdict(rs.match(a1, b1), 2.0)
    ck(f'① k=1：绿、r ≈ 1（{r1}）', r1['verdict'] == '绿' and 0.9 <= r1['r'] <= 1.1)
    b2 = run(tex, 2.0, 8.0, seed=3)
    r2 = rs.verdict(rs.match(a1, b2), 2.0)
    ck(f'② k=2：红、r ≈ 2（{r2}）', r2['verdict'] == '红' and 1.8 <= r2['r'] <= 2.2)
    a3 = run(tex, 1.0, 3.0, seed=4)
    b3 = run(tex, 1.0, 3.0, seed=5)
    r3 = rs.verdict(rs.match(a3, b3), 2.0)
    ck(f'③ 景深 3 米（① 是 8 米）、k=1：仍绿，r 与 ① 差 < 5%（{r3}）', r3['verdict'] == '绿' and abs(r3['r'] - r1['r']) / r1['r'] < 0.05)
    b4 = run(texture(2), 1.0, 8.0, seed=6)
    r4 = rs.verdict(rs.match(a1, b4), 2.0)
    ck(f'④ 60 帧局走了另一条路线：判不出（{r4}）', r4['verdict'] == '判不出')
    r5 = rs.verdict(rs.match(a1, b1), 1.0)
    ck(f'⑤ q = 1.0：判不出（{r5}）', r5['verdict'] == '判不出')
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'a.route')
        with open(p, 'wb') as f:
            f.write(rs.MAGIC + struct.pack('<HH', W, H))
            for t, img in a1:
                f.write(struct.pack('<Q', int(round(t * 1e9))) + img)
        w, h, back = rs.load(p)
    ck(f'⑥ S2RT 往返：{w}×{h}、{len(back)} 张，时刻与内容一致', (w, h) == (W, H) and len(back) == len(a1)
       and all(abs(x[0] - y[0]) < 1e-6 and x[1] == y[1] for x, y in zip(back, a1)))
    print(f'route_speed：{n} 项，红 {bad}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
