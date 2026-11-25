#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Maxwell 浮点混合矩阵（#674 / #2183 通用根修）：全部系数 × 方程 × {有限, 0, NaN, ±Inf}，期望值由参考模型 maxwell_blend_ref.py 算，不读被测实现。

被测实现（provider）按 cell(state, s, s1, d, c) → RGBA 接进来：
  fixed  —— Metal / D3D 的固定混合（IEEE：0 × NaN = NaN），即修前直连层的做法。它必须红：矩阵查得出 #674 这类差异（负对照），
            并且 #674 原状态那一格必须在不等之列。
  pb / pb16 —— 可编程混合（graphics/dsx/gal_colorround.c 门控版，特化时开附件 0）在真 Metal 上跑（t_pblend_gpu，环境变量 S2A_PBLEND_GPU 给可执行文件）：
            RGBA32F / RGBA16F，要求全等，第二源系数（SRC1_*）照送（片元里用输出 1 的值）。没有可执行文件（非 Mac）→ 跳过并照实说
用法：maxwell_blend_matrix_test.py [--full]   缺省只跑门禁用的子集（每种系数 / 方程组合都在，取值组合缩小），--full 跑满。
"""
import itertools
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import maxwell_blend_ref as M   # noqa: E402

NAN, INF = math.nan, math.inf


def cases(full):
    """(state, s, s1, d, c)：RGB 的 (方程, 源系数, 目标系数) 走遍 5 × 19 × 19 种（A 取三种代表），再单扫 A 的 5 × 19 × 19 种（RGB 固定 ONE / ZERO）；
    full 时取值组合放满"""
    vals = (0.0, 0.5, 1.0, -2.0, NAN, INF, -INF) if full else (0.0, 0.5, NAN, INF)
    alpha_states = [(M.ADD, M.ONE, M.ZERO), (M.ADD, M.ZERO, M.ONE_MINUS_SRC_ALPHA), (M.ADD, M.SRC_ALPHA, M.DST_ALPHA)]
    states = [rgb + a for rgb in itertools.product(M.EQS, M.FUNCS, M.FUNCS) for a in alpha_states] + \
             [(M.ADD, M.ONE, M.ZERO) + a for a in itertools.product(M.EQS, M.FUNCS, M.FUNCS)]
    for state in states:
            for sr, sa, dr, da in itertools.product(vals, repeat=4):
                for k in ((0.0, 1.0) if not full else (0.0, 0.25, 1.0)):
                    yield state, (sr, sr, -sr, sa), (k, k, k, k), (dr, -dr, dr, da), (k, 1.0 - k, k, k)


def fixed(state, s, s1, d, c):
    return M.blend(state, s, s1, d, c, ztaiz=False)


SRC1 = {M.SRC1_COLOR, M.ONE_MINUS_SRC1_COLOR, M.SRC1_ALPHA, M.ONE_MINUS_SRC1_ALPHA}


def pb_batch(cells, fmt="rgba32f"):
    """cells：[(state, s, s1, d, c)] → 结果 [RGBA] 或 None（没有 t_pblend_gpu）。按 (state, c) 分组写给 t_pblend_gpu、读回附件"""
    import struct, subprocess, tempfile
    exe = os.environ.get("S2A_PBLEND_GPU")
    if not exe or not os.path.isfile(exe):
        return None
    groups = {}
    for i, (state, s, s1, d, c) in enumerate(cells):
        groups.setdefault((state, c), []).append(i)
    out = [None] * len(cells)
    with tempfile.TemporaryDirectory() as t:
        src, dst = os.path.join(t, "in.bin"), os.path.join(t, "out.bin")
        order = list(groups.items())
        with open(src, "wb") as f:
            f.write(b"S2PB" + struct.pack("<I", len(order)))
            for (state, c), idx in order:
                f.write(struct.pack("<6I4fI", *state, *c, len(idx)))
                for i in idx:
                    f.write(struct.pack("<12f", *cells[i][1], *cells[i][2], *cells[i][3]))
        subprocess.run([exe, src, dst, fmt], check=True, stdout=subprocess.DEVNULL)
        data = open(dst, "rb").read()
        at = 0
        for _, idx in order:
            for i in idx:
                out[i] = struct.unpack_from("<4f", data, at * 16); at += 1
    return out


PROVIDERS = {"fixed": fixed}
BATCH = {"pb": pb_batch, "pb16": lambda cells: pb_batch(cells, "rgba16f")}   # 游戏常见的半精度附件也跑（门禁取值在 half 下都精确可表示）   # 游戏常见的半精度附件也跑（门禁取值在 half 下都精确可表示）
MUST_DIFFER = {"fixed"}   # 负对照：这些实现必须和模型不等


NEG_STRIDE = 16   # 负对照只需证明这套判据判得出固定混合不对：每 16 格取 1 格（另加 #674 那一格），不用扫满


def run(name, impl, every, wants):
    total = bad = 0; first = None
    for (state, s, s1, d, c), want in zip(every[::NEG_STRIDE], wants[::NEG_STRIDE]):
        total += 1
        got = impl(state, s, s1, d, c)
        if not all(M.same(g, w) for g, w in zip(got, want)):
            bad += 1; first = first or (state, s, d, want, got)
    # #674 原状态那一格（SRC_ALPHA / ONE_MINUS_SRC_ALPHA，A 为 ZERO / ONE_MINUS_SRC_ALPHA；源 (NaN,NaN,NaN,0) 混进 (0,0,0,1)）
    st674 = (M.ADD, M.SRC_ALPHA, M.ONE_MINUS_SRC_ALPHA, M.ADD, M.ZERO, M.ONE_MINUS_SRC_ALPHA)
    cell674 = all(M.same(g, w) for g, w in zip(impl(st674, (NAN, NAN, NAN, 0.0), (0.0,) * 4, (0.0, 0.0, 0.0, 1.0), (0.0,) * 4),
                                                   M.blend(st674, (NAN, NAN, NAN, 0.0), (0.0,) * 4, (0.0, 0.0, 0.0, 1.0), (0.0,) * 4)))
    return total, bad, first, cell674


def run_batch(name, impl, every, wants):
    """批量实现：一次送完全部格子（含第二源系数的状态）"""
    sent = every
    st674 = (M.ADD, M.SRC_ALPHA, M.ONE_MINUS_SRC_ALPHA, M.ADD, M.ZERO, M.ONE_MINUS_SRC_ALPHA)
    cell674 = (st674, (NAN, NAN, NAN, 0.0), (0.0,) * 4, (0.0, 0.0, 0.0, 1.0), (0.0,) * 4)
    got = impl(sent + [cell674])
    if got is None:
        return None
    bad = 0; first = None
    for (state, s, s1, d, c), g, want in zip(sent, got, wants):
        if not all(M.same(x, w) for x, w in zip(g, want)):
            bad += 1; first = first or (state, s, d, c, want, g)
    ok674 = all(M.same(x, w) for x, w in zip(got[-1], M.blend(*cell674)))
    return len(sent), sum(1 for x in sent if SRC1 & set(x[0][1:3] + x[0][4:6])), bad, first, ok674


def main():
    full = "--full" in sys.argv
    fails = 0
    every = list(cases(full)); wants = [M.blend(*x) for x in every]   # 期望只算一次，各实现共用
    for name, impl in BATCH.items():
        r = run_batch(name, impl, every, wants)
        if r is None:
            print(f"跳过 {name}：没有 S2A_PBLEND_GPU（非 Mac 或没编 t_pblend_gpu），可编程混合这次没验")
            continue
        total, src1, bad, first, ok674 = r
        ok = bad == 0 and ok674
        print(f"{'通' if ok else '不通'} {name}（真 Metal）：{total} 格，和模型不等 {bad} 格（要 0），#674 那一格{'相等' if ok674 else '不等'}（要相等）；"
              f"其中第二源系数 {src1} 格" + ("" if ok else f"；第一格 {first}"))
        fails += not ok
    for name, impl in PROVIDERS.items():
        total, bad, first, cell674 = run(name, impl, every, wants)
        if name in MUST_DIFFER:
            ok = bad > 0 and not cell674
            print("【负对照开始】")
            print(f"{'通' if ok else '不通'} 负对照 {name}（每 {NEG_STRIDE} 格取 1）：{total} 格里和模型不等 {bad} 格（要 > 0），#674 那一格{'不等' if not cell674 else '相等'}（要不等）")
            print("【负对照结束】")
        else:
            ok = bad == 0 and cell674
            print(f"{'通' if ok else '不通'} {name}：{total} 格，和模型不等 {bad} 格（要 0）" + ("" if ok else f"；第一格 {first}"))
        fails += not ok
    print(f"{'✓' if not fails else '✗'} maxwell_blend_matrix：{len(PROVIDERS) + len(BATCH)} 个实现，不通 {fails}（{'满矩阵' if full else '门禁子集'}）")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
