#!/usr/bin/env python3
"""游戏逻辑速度：固定路线计时（11-24 #2201 测法根修，替换同局 A/B 的画面平均位移 ρ）。

两局从同一份即时存档恢复、喂同一段输入（推住左摇杆向前走），一局原帧率、一局 60 帧，自动玩家按真实时间每隔一段存一张亮度缩略图
（tests/autoplay/autoplay.c route_record，文件格式见 load）。比的是「走到同一处的时刻」：取原帧率局推杆后 t 秒那张图，
在 60 帧局序列里找最像的一张（零均值归一化相关，整幅、不搜位移：同一条路线、同一处地方构图一样），它的时刻 t'。
速度比 r = t / t'：按真实时间推进的游戏 r ≈ 1，按帧推进、开 60 帧变快的 r ≈ 帧率比 q。

为什么不再用画面位移：位移像素数取决于景物离镜头多远，同 1 m/s 景深 8 米和 3 米读数差 2.7 倍（#2201 玩家对照），
开 / 关两段在同一局不同时刻量、构图不同，比值不是游戏速度比。这里两局走的是同一条路线、比的是同一处地方，景深与构图一起约掉。

用法：route_speed.py <原帧率局.route> <60 帧局.route> [--q 帧率比]   末行 JSON {verdict, r, n, q, why}；退出码 0 绿、1 红、2 判不出
"""
import json
import struct
import sys

MAGIC = b'S2RT'


def load(path):
    """文件：'S2RT' + u16 宽 + u16 高，之后每张 u64 推杆起算的纳秒 + 宽×高 字节亮度。返回 (宽, 高, [(秒, bytes)…])"""
    with open(path, 'rb') as f:
        d = f.read()
    if d[:4] != MAGIC:
        raise ValueError(f'{path}: 不是路线录像（开头不是 S2RT）')
    w, h = struct.unpack_from('<HH', d, 4)
    n, off, out = w * h, 8, []
    while off + 8 + n <= len(d):
        (t,) = struct.unpack_from('<Q', d, off)
        out.append((t / 1e9, d[off + 8:off + 8 + n]))
        off += 8 + n
    return w, h, out


def _zn(b):   # 零均值、单位范数的向量（纯 Python，128×72 一张约 9 千个数）
    m = sum(b) / len(b)
    v = [x - m for x in b]
    s = sum(x * x for x in v) ** 0.5
    return v, s


def _corr(a, b):
    va, sa = a
    vb, sb = b
    return sum(x * y for x, y in zip(va, vb)) / (sa * sb) if sa > 1e-6 and sb > 1e-6 else -1.0


MIN_T = 1.5       # 推杆后至少这么多秒的原帧率帧才拿来比（起步加速段两种游戏都一样慢，比值不稳）
MIN_CORR = 0.85   # 最像那张的相关不到这个数：这处地方 60 帧局里没出现（走岔了 / 场景变了），这张不算
MIN_N = 5         # 有效对比张数至少这么多才下结论


def match(a, b):
    """a = 原帧率局 [(秒, 亮度)…]，b = 60 帧局。返回 [(t, t', 相关)]：a 里 t ≥ MIN_T 的每张，在 b 里最像的那张。
    b 里找的范围限在 t' ≤ 2.5 t（游戏最多快到 2.5 倍），t' 取最像那张左右两张按相关加权插值（采样间隔量化）"""
    zb = [(tb, _zn(img)) for tb, img in b]
    out = []
    for ta, img in a:
        if ta < MIN_T:
            continue
        za = _zn(img)
        cs = [(_corr(za, z), i) for i, (tb, z) in enumerate(zb) if tb <= 2.5 * ta + 0.5]
        if not cs:
            continue
        c, i = max(cs)
        if c < MIN_CORR:
            continue
        lo, hi = max(0, i - 1), min(len(zb) - 1, i + 1)
        ws = [(max(_corr(za, zb[j][1]), 0) ** 4, zb[j][0]) for j in range(lo, hi + 1)]
        tw = sum(w * t for w, t in ws) / sum(w for w, _ in ws) if sum(w for w, _ in ws) > 0 else zb[i][0]
        out.append((ta, tw, c))
    return out


def verdict(pairs, q):
    """pairs = match 的结果，q = 两局出图帧率比（60 帧局 / 原帧率局）。r = 中位 t / t'。
    判据（按规则写死，不按实现推）：r 落在 [0.8, 1.25] → 绿（按真实时间推进）；r ≥ 1 + 0.6 (q − 1) → 红（按帧推进，开 60 帧变快）；
    其余、有效张数 < MIN_N、q < 1.3（帧率没涨，比不出）→ 判不出"""
    rs = sorted(t / tp for t, tp, _ in pairs if tp > 0.05)
    if q < 1.3:
        return {'verdict': '判不出', 'r': None, 'n': len(rs), 'q': q, 'why': f'帧率比 q {q:.2f} < 1.3：60 帧没真的开起来，比不出'}
    if len(rs) < MIN_N:
        return {'verdict': '判不出', 'r': None, 'n': len(rs), 'q': q, 'why': f'有效对比 {len(rs)} 张 < {MIN_N}：两局没走同一条路线（起点不同 / 推杆没走动 / 场景变了）'}
    r = rs[len(rs) // 2] if len(rs) % 2 else (rs[len(rs) // 2 - 1] + rs[len(rs) // 2]) / 2
    if 0.8 <= r <= 1.25:
        v, why = '绿', f'走到同一处的时刻相同（r {r:.2f}，q {q:.2f}）：按真实时间推进'
    elif r >= 1 + 0.6 * (q - 1):
        v, why = '红', f'60 帧局 {r:.2f} 倍快走到同一处（q {q:.2f}）：按帧推进，开 60 帧游戏变快'
    else:
        v, why = '判不出', f'r {r:.2f} 既不接近 1 也不接近帧率比 q {q:.2f}'
    return {'verdict': v, 'r': round(r, 3), 'n': len(rs), 'q': q, 'why': why}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    q = float(argv[argv.index('--q') + 1]) if '--q' in argv else 2.0
    _, _, a = load(argv[0])
    _, _, b = load(argv[1])
    res = verdict(match(a, b), q)
    print(json.dumps(res, ensure_ascii=False))
    return {'绿': 0, '红': 1}.get(res['verdict'], 2)   # 同 tools/ab_pair.sh 判据口径：0 绿、1 红、2 判不出


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
