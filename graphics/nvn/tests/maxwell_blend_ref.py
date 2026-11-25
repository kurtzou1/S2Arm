#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Maxwell 浮点混合参考模型（#674 / #2183 根修的期望值来源，不读被测实现）。

Switch 的 NVN 驱动在初始化命令序列里把 SET_BLEND_FLOAT_OPTION（Maxwell B 3D 类方法 0x19c0，NVIDIA open-gpu-doc classes/3d/clb197.h）
的 ZERO_TIMES_ANYTHING_IS_ZERO 置 TRUE：6 款游戏（SDK 版本各不同）的 sdk 模块只读段里各恰好一处立即数写 0x80010670（值 1），
前一条都是 0x800103f7（SET_BLEND_OPT_CONTROL = 1），没有一处写 0。D3D11.3 规范与 Metal 的混合按 IEEE（0 × NaN = NaN），等于这一位关。
本模型按「位 = TRUE：混合里每一次 系数 × 颜色，只要一个因子为 0 积就是 0」逐通道算（NaN / ±Inf 乘 0 都得 0），其余按 IEEE。
MIN / MAX 方程不乘系数（同 GL / NVN）。混合单元遇 NaN 怎么取没有硬件依据（头文件没写）：沿用着色器 FMNMX 的取舍（IEEE minNum / maxNum，
一方是 NaN 取另一方；gfx/spirv-nan-minmax 7ed61fcbd 按同一规则发 NMin / NMax），在 MINMAX_UNKNOWN 里标出来。
"""
import math

ZERO, ONE, SRC_COLOR, ONE_MINUS_SRC_COLOR, SRC_ALPHA, ONE_MINUS_SRC_ALPHA = 0x1, 0x2, 0x3, 0x4, 0x5, 0x6
DST_ALPHA, ONE_MINUS_DST_ALPHA, DST_COLOR, ONE_MINUS_DST_COLOR, SRC_ALPHA_SATURATE = 0x7, 0x8, 0x9, 0xA, 0xB
SRC1_COLOR, ONE_MINUS_SRC1_COLOR, SRC1_ALPHA, ONE_MINUS_SRC1_ALPHA = 0x10, 0x11, 0x12, 0x13
CONSTANT_COLOR, ONE_MINUS_CONSTANT_COLOR, CONSTANT_ALPHA, ONE_MINUS_CONSTANT_ALPHA = 0x61, 0x62, 0x63, 0x64
FUNCS = (ZERO, ONE, SRC_COLOR, ONE_MINUS_SRC_COLOR, SRC_ALPHA, ONE_MINUS_SRC_ALPHA, DST_ALPHA, ONE_MINUS_DST_ALPHA, DST_COLOR,
         ONE_MINUS_DST_COLOR, SRC_ALPHA_SATURATE, SRC1_COLOR, ONE_MINUS_SRC1_COLOR, SRC1_ALPHA, ONE_MINUS_SRC1_ALPHA,
         CONSTANT_COLOR, ONE_MINUS_CONSTANT_COLOR, CONSTANT_ALPHA, ONE_MINUS_CONSTANT_ALPHA)   # nvn.h NVNblendFunc
ADD, SUB, REVERSE_SUB, MIN, MAX = 0x1, 0x2, 0x3, 0x4, 0x5   # nvn.h NVNblendEquation
EQS = (ADD, SUB, REVERSE_SUB, MIN, MAX)
MINMAX_UNKNOWN = (MIN, MAX)
DST_FUNCS = (DST_ALPHA, ONE_MINUS_DST_ALPHA, DST_COLOR, ONE_MINUS_DST_COLOR, SRC_ALPHA_SATURATE)   # 系数要读目标像素


def factor(f, ch, s, s1, d, c):
    """系数 f 在通道 ch（0..2 = RGB，3 = A）的值；s / s1 / d / c = 源 / 第二源 / 目标 / 混合常量（各 4 元）。按 IEEE 算（1 - NaN = NaN）"""
    a = 3
    if f == ZERO: return 0.0
    if f == ONE: return 1.0
    if f == SRC_COLOR: return s[ch]
    if f == ONE_MINUS_SRC_COLOR: return 1.0 - s[ch]
    if f == SRC_ALPHA: return s[a]
    if f == ONE_MINUS_SRC_ALPHA: return 1.0 - s[a]
    if f == DST_ALPHA: return d[a]
    if f == ONE_MINUS_DST_ALPHA: return 1.0 - d[a]
    if f == DST_COLOR: return d[ch]
    if f == ONE_MINUS_DST_COLOR: return 1.0 - d[ch]
    if f == SRC_ALPHA_SATURATE: return 1.0 if ch == a else _fmin(s[a], 1.0 - d[a])
    if f == SRC1_COLOR: return s1[ch]
    if f == ONE_MINUS_SRC1_COLOR: return 1.0 - s1[ch]
    if f == SRC1_ALPHA: return s1[a]
    if f == ONE_MINUS_SRC1_ALPHA: return 1.0 - s1[a]
    if f == CONSTANT_COLOR: return c[ch]
    if f == ONE_MINUS_CONSTANT_COLOR: return 1.0 - c[ch]
    if f == CONSTANT_ALPHA: return c[a]
    if f == ONE_MINUS_CONSTANT_ALPHA: return 1.0 - c[a]
    raise ValueError(f"不认识的混合系数 {f:#x}")


def _fmin(x, y):
    if math.isnan(x): return y
    if math.isnan(y): return x
    return min(x, y)


def _fmax(x, y):
    if math.isnan(x): return y
    if math.isnan(y): return x
    return max(x, y)


def mul(x, y, ztaiz=True):
    """混合单元的一次乘法：位 = TRUE 时任一因子为 0（含 -0）积为 0，否则 IEEE"""
    if ztaiz and (x == 0.0 or y == 0.0): return 0.0
    try: return x * y
    except OverflowError: return math.inf


def channel(eq, sf, df, ch, s, s1, d, c, ztaiz=True):
    if eq == MIN: return _fmin(s[ch], d[ch])
    if eq == MAX: return _fmax(s[ch], d[ch])
    ps, pd = mul(factor(sf, ch, s, s1, d, c), s[ch], ztaiz), mul(factor(df, ch, s, s1, d, c), d[ch], ztaiz)
    if eq == ADD: return ps + pd
    if eq == SUB: return ps - pd
    if eq == REVERSE_SUB: return pd - ps
    raise ValueError(f"不认识的混合方程 {eq:#x}")


def blend(state, s, s1, d, c, ztaiz=True):
    """state = (eq_rgb, sf_rgb, df_rgb, eq_a, sf_a, df_a) → 混合结果 RGBA（浮点附件不夹取，同 D3D11.3 对 float16 / 11 / 10 的例外）"""
    eq_rgb, sf_rgb, df_rgb, eq_a, sf_a, df_a = state
    return tuple(channel(eq_rgb, sf_rgb, df_rgb, ch, s, s1, d, c, ztaiz) for ch in range(3)) + (channel(eq_a, sf_a, df_a, 3, s, s1, d, c, ztaiz),)


def same(x, y):
    """逐位意义上的同值：NaN 与 NaN 相同、+0 与 -0 相同（附件存 half 时 -0 与 +0 都显示 0，NaN 载荷不比）"""
    return (math.isnan(x) and math.isnan(y)) or x == y


if __name__ == "__main__":   # 自检：期望按规则手写，不调 blend 以外的路
    nan, inf = math.nan, math.inf
    SA = (ADD, SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ADD, ZERO, ONE_MINUS_SRC_ALPHA)   # #674 那一遍的混合状态
    checks = [
        ("#674：源 (NaN,NaN,NaN,0) 混进 (0,0,0,1) 得 (0,0,0,1)", blend(SA, (nan, nan, nan, 0.0), (0,) * 4, (0.0, 0.0, 0.0, 1.0), (0,) * 4), (0.0, 0.0, 0.0, 1.0)),
        ("#674 同状态 IEEE（位关，Metal）得 (NaN,NaN,NaN,1)", blend(SA, (nan, nan, nan, 0.0), (0,) * 4, (0.0, 0.0, 0.0, 1.0), (0,) * 4, ztaiz=False), (nan, nan, nan, 1.0)),
        ("正常半透明 (1,.5,.25,.5) 混进 (0,0,0,1) 得 (.5,.25,.125,.5)", blend(SA, (1.0, 0.5, 0.25, 0.5), (0,) * 4, (0.0, 0.0, 0.0, 1.0), (0,) * 4), (0.5, 0.25, 0.125, 0.5)),
        ("dst 项：目标全 NaN、ONE_MINUS_SRC_ALPHA 且源 alpha=1 → RGB 只剩源、A = 0×1 + 0×NaN = 0", blend(SA, (1.0, 2.0, 3.0, 1.0), (0,) * 4, (nan, nan, nan, nan), (0,) * 4), (1.0, 2.0, 3.0, 0.0)),
        ("Inf × 0 = 0（ONE / ZERO，源 Inf）", blend((ADD, ZERO, ONE, ADD, ZERO, ONE), (inf, inf, inf, inf), (0,) * 4, (1.0, 1.0, 1.0, 1.0), (0,) * 4), (1.0, 1.0, 1.0, 1.0)),
        ("源为 0、系数 NaN（SRC_ALPHA，alpha NaN）→ 0", blend((ADD, SRC_ALPHA, ZERO, ADD, ONE, ZERO), (0.0, 0.0, 0.0, nan), (0,) * 4, (5.0,) * 4, (0,) * 4), (0.0, 0.0, 0.0, nan)),
        ("系数非 0 时 NaN 照传（ONE / ZERO，源 NaN）", blend((ADD, ONE, ZERO, ADD, ONE, ZERO), (nan, 1.0, 2.0, 3.0), (0,) * 4, (0.0,) * 4, (0,) * 4), (nan, 1.0, 2.0, 3.0)),
        ("SRC1_ALPHA = 0 清掉源 NaN（双源）", blend((ADD, SRC1_ALPHA, ONE, ADD, ONE, ZERO), (nan, nan, nan, 1.0), (0, 0, 0, 0.0), (0.25,) * 4, (0,) * 4), (0.25, 0.25, 0.25, 1.0)),
        ("CONSTANT_COLOR 逐通道：常量 (0,1,0,1) 只清 R / B", blend((ADD, CONSTANT_COLOR, ZERO, ADD, ONE, ZERO), (nan, 2.0, nan, 1.0), (0,) * 4, (0.0,) * 4, (0.0, 1.0, 0.0, 1.0)), (0.0, 2.0, 0.0, 1.0)),
        ("SUB：0×NaN 也是 0", blend((SUB, ONE, ONE_MINUS_SRC_ALPHA, ADD, ONE, ZERO), (1.0, 1.0, 1.0, 1.0), (0,) * 4, (nan, nan, nan, 0.0), (0,) * 4), (1.0, 1.0, 1.0, 1.0)),
    ]
    bad = 0
    for name, got, want in checks:
        ok = all(same(g, w) for g, w in zip(got, want)); bad += not ok
        print(("通 " if ok else "不通 ") + name + ("" if ok else f"：得 {got}，期望 {want}"))
    print(f"{'✓' if not bad else '✗'} maxwell_blend_ref 自检：{len(checks)} 项，不通 {bad}")
    raise SystemExit(1 if bad else 0)
