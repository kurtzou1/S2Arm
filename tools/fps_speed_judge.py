#!/usr/bin/env python3
"""60 帧逻辑速度判据（原生崩溃线 11-02，维护者定为普查开 60 帧的质量硬门）：python3 tools/fps_speed_judge.py <局目录或 host.log> <局目录或 host.log>

要证明的：游戏逻辑时间 ÷ 真实时间不随帧率变。按真实时间推进（或帧率表已补偿）的游戏，60 帧开 / 关两局「同一段时钟里逻辑走的距离」相同；
按帧推进没补偿的，帧率翻倍逻辑也快一倍。
信号：自动玩家 MARK 后的逻辑速度探测（S2A_AP_SPEED=1，tests/autoplay/autoplay.c speed_probe）：按时钟推摇杆（先右摇杆转镜头，没响应再左摇杆），
  量画面横移速度（像素 / 秒）。日志两种行：
    逻辑速度探测：<摇杆><左|右>推 #k 横移 <v> 像素/秒（稳段 <n> 样本）
    逻辑速度探测：<摇杆> <有响应> / <推数> 推画面跟着横移，探测期间出图 <fps> 帧/秒
判法：取两局都有响应的同一根摇杆，各局有效推（稳段 ≥ 5 样本、|v| ≥ 3）的 |v| 中位；高帧率局 ÷ 低帧率局 = ρ，两局探测期间出图帧率比 = q。
  同 tests/autoplay/autoplay.c sp_verdict（11-02 收紧）：低帧率局已 ≥ 55 帧（原生 60）、q < 1.15（帧率没涨）、ρ < 0.8（场景不一致）→ 判不出；
  ρ ≤ min(1.25, √q) → 绿；更快一律红（帧率涨了就一定判，判不准时偏关 60 帧）。
退出码：0 绿 / 1 红 / 2 判不出。最后一行打印结论（docs/名单_60帧/ 的「逻辑速度」格照抄）"""
import os, re, statistics, sys

BAND = 1.25
NATIVE, QMIN = 55.0, 1.15   # 同 autoplay.c SP_NATIVE / SP_QMIN
PUSH = re.compile(r'逻辑速度探测：(右摇杆|左摇杆)(左|右)推 #\d+ 横移 (-?[\d.]+|nan) 像素/秒（稳段 (\d+) 样本）')
SUM = re.compile(r'逻辑速度探测：(右摇杆|左摇杆) (\d+) / (\d+) 推画面跟着横移，探测期间出图 ([\d.]+) 帧/秒')


def read(p):
    h = os.path.join(p, 'host.log') if os.path.isdir(p) else p
    v, fps, ok = {}, {}, {}
    for l in open(h, encoding='utf-8', errors='replace'):
        m = PUSH.search(l)
        if m and m.group(3) != 'nan' and int(m.group(4)) >= 5 and abs(float(m.group(3))) >= 3: v.setdefault(m.group(1), []).append(abs(float(m.group(3))))
        m = SUM.search(l)
        if m: fps[m.group(1)] = float(m.group(4)); ok[m.group(1)] = int(m.group(2)) * 2 >= int(m.group(3))
    return h, v, fps, ok


def judge(a, b):
    (ha, va, fa, oa), (hb, vb, fb, ob) = read(a), read(b)
    st = next((s for s in ('右摇杆', '左摇杆') if oa.get(s) and ob.get(s) and va.get(s) and vb.get(s)), None)
    if not st: return 2, f'判不出：两局没有同一根摇杆都推得动画面（{ha}：{sorted(oa.items())}；{hb}：{sorted(ob.items())}；局里要设 S2A_AP_SPEED=1）'
    (vl, fl), (vh, fh) = sorted([(statistics.median(va[st]), fa[st]), (statistics.median(vb[st]), fb[st])], key=lambda x: x[1])
    q, rho = fh / fl, vh / vl
    what = f'{st}横移 {vl:.1f} → {vh:.1f} 像素/秒、出图 {fl:.1f} → {fh:.1f} 帧/秒，ρ = {rho:.2f}、q = {q:.2f}'
    if fl >= NATIVE: return 2, f'判不出：原生 60，低帧率局已 ≥ 55 帧（{what}）'
    if q < QMIN: return 2, f'判不出：开 60 帧帧率没涨，无倍速风险（{what}）'
    if rho < 1 / BAND: return 2, f'判不出：高帧率局反而变慢，两局场景不一致（{what}）'
    if rho > q * 1.5: return 2, f'判不出：快过帧率倍数，两局量的不是同一种运动（同 tests/autoplay/autoplay.c SP_RHO_MAX，{what}）'
    if rho <= min(BAND, q ** 0.5): return 0, f'绿：逻辑速度不随帧率变（{what}）'
    return 1, f'红：按帧推进未补偿，高帧率下逻辑真快了（{what}）'


if __name__ == '__main__':
    if len(sys.argv) != 3: print(__doc__); sys.exit(2)
    rc, msg = judge(sys.argv[1], sys.argv[2])
    print(f'fps60 逻辑速度：{msg}')
    sys.exit(rc)
