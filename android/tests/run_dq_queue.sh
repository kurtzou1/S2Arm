#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 两级回放队列（android/native/nvn/nvn_vk_dq.inc）宿主用例：真队列 + 真录制线程 + 记录桩，外加六种变异的负对照。
#   正控：真实现必须全绿；有 ThreadSanitizer 时再用它编一份，必须零报告（没有就跳过，不算红）；
#   负控：每种变异改一份临时 .inc，必须以「红」收场，并且红在预期的那个阶段（不是别处）：
#     M1 记录还没写完就发布              → 录制线程读到半条记录（C1：序列哈希 / 条数不符、没登记的调用，或崩溃）
#     M2 清空不等录制线程                → 清空返回时欠账（C1 收尾条数不足 / C2 跨线程清空）
#     M3 写满环时不等录制线程腾位置      → 没读的记录被覆盖（C1 / C3：序列错 / 崩溃 / 超时）
#     M4 环尾跳过记录的长度写错          → 录制线程跳到错位的地方（C1 第一次回绕：序列错 / 崩溃 / 超时）
#     M5 先报「已读」再执行这一条        → 清空在最后一条做完之前返回（C2 欠账）
#     M6 先走的清空线程抹掉别人的「在等」标记 → 后到的没人叫醒，等满 1 秒超时（C5；这是修前主线的行为）
#   录制线程等活的三个开关（nvk_dq_spin / nvk_dq_poll_us / nvk_dq_wake_kb）另有五种变异，只跑 C6 那一组（dq_queue_test C6）：
#     M7 按批叫时过线也不叫                → C6b（不清空，过线的那一批没人叫醒）
#     M8 定时醒不定时（睡到被叫醒）        → C6c（谁也不叫，积压没被定时醒取走）
#     M9 定时醒的退避不封顶                → C6d（空闲很久后再来一条，等了几百毫秒）
#     M10 不认 nvk_dq_spin（恒自旋 200）    → C6e（稀疏生产者下录制线程 CPU 没降）
#     M11 按批叫失效（每条都叫）            → C6b（积压不到阈值就被叫醒了）
#   环满 / 清空的叫醒路径、等待分布读数另有六种变异（C6f / C6g / C7）：
#     M12 不记睡着期间第一条记录的发布时刻   → C7a（40 轮里记不到样本）
#     M13 环满不叫醒录制线程                 → C6f（阈值够不着时生产者永远等不到位置，看门狗超时）
#     M14 清空的两处叫醒都去掉               → C6a / C6g（睡着的录制线程没人叫，清空一直等，看门狗超时）
#     M15 清空等待不进直方图                 → C7b
#     M16 等活延迟的起点终点算反             → C7a（记下的比墙钟还长）
#     M17 百分位向下取整                     → C7d（合成直方图 p99 落错桶）
#   暂存填充的代拷另有四种变异，只跑 C8 那一组：
#     M18 代拷完就把水位推到自己的票号       → C8a（旧票号还没拷完，水位越过了它）
#     M19 代拷完不置「拷完」                 → C8a（录制线程 / 再次代拷一直等「正在拷」，看门狗超时）
#     M20 录制线程不认代拷、照拷             → C8a（被代拷的记录又拷一遍，把改过的来源带进暂存）
#     M21 旁挂表复用槽前不先拷旧的那笔       → C8c（旧那笔被录制线程当成已代拷跳过，暂存没拷）
set -euo pipefail
ulimit -c 0 2> /dev/null || true   # 变异用例可能崩溃（M1 常见）：不留 core 文件
repo=$(cd "$(dirname "$0")/../.." && pwd)
if [ "$(uname -s)" != Linux ]; then   # 队列用 pthread 自旋锁，苹果系统没有；android/test.sh 只在 Linux 门禁里调本脚本
    echo '【红】两级回放队列宿主用例只在 Linux 上跑（队列用 pthread 自旋锁，苹果系统没有）' >&2; exit 2
fi
mkdir -p "$repo/build/dq-queue-tmp"
out=$(mktemp -d "$repo/build/dq-queue-tmp/run.XXXXXX")
trap 'rm -rf "$out"' EXIT

cflags=(-std=gnu11 -D_GNU_SOURCE -O2 -g -Wall -Wextra -Werror -Wno-unused-parameter)
inc=(-I "$repo/android/tests/vkhost" -I "$repo/graphics/nvn/third_party/vulkan-headers/include" -I "$repo/graphics/nvn/replay")
test_c="$repo/android/tests/dq_queue_test.c"
inc_src="$repo/android/native/nvn/nvn_vk_dq.inc"

build() {   # $1 = 可执行文件，$2 = 额外的 -I（变异 .inc 所在目录；排在前面，包含时先找到它），其余 = 额外编译选项
    local exe=$1 mdir=$2; shift 2
    local extra=(); if [ -n "$mdir" ]; then extra=(-I "$mdir"); fi
    cc "${cflags[@]}" "${extra[@]}" "${inc[@]}" -I "$repo/android/native/nvn" "$@" "$test_c" -o "$exe" -lpthread
}
run() {   # $1 = 可执行文件，$2 = 日志，其余 = 传给可执行文件的参数；返回码留在 rc
    set +e
    "$1" "${@:3}" >"$2" 2>&1
    rc=$?
    set -e
}

# ---- 正控：真实现
build "$out/real" ""
run "$out/real" "$out/log_real"
cat "$out/log_real"
if [ "$rc" -ne 0 ] || ! grep -q '^dq_queue_test：.*，0 项红' "$out/log_real" || grep -q '【红】' "$out/log_real"; then
    echo "【红】两级回放队列宿主用例（真实现）：rc=$rc" >&2; exit 1
fi

# ---- 正控（TSan）：同一份用例换 ThreadSanitizer 编
tsan_pre=(); tsan_ok=0
if echo 'int main(void){return 0;}' | cc -fsanitize=thread -x c - -o "$out/tsan_probe" 2>/dev/null; then
    # 新内核的随机映射范围超出 TSan 的假设（WSL2 常见），而且是随机地时好时坏：探针这次过了，正式跑那次不一定过。
    # 所以只要有 setarch 就一律用它把这一个进程的地址随机化关掉（不动系统设置）；没有 setarch 才直接跑。
    if command -v setarch >/dev/null && setarch "$(uname -m)" -R "$out/tsan_probe" 2>/dev/null; then
        tsan_ok=1; tsan_pre=(setarch "$(uname -m)" -R)
    elif "$out/tsan_probe" 2>/dev/null; then tsan_ok=1
    fi
fi
if [ "$tsan_ok" -eq 1 ]; then
    build "$out/tsan" "" -fsanitize=thread -O1 -DTEST_TIMEOUT_S=900
    set +e
    TSAN_OPTIONS="halt_on_error=1:exitcode=66" ${tsan_pre[@]+"${tsan_pre[@]}"} "$out/tsan" >"$out/log_tsan" 2>&1
    rc=$?
    set -e
    tail -n 3 "$out/log_tsan"
    if [ "$rc" -ne 0 ] || grep -q 'WARNING: ThreadSanitizer' "$out/log_tsan"; then
        cat "$out/log_tsan" >&2; echo "【红】两级回放队列宿主用例（TSan）：rc=$rc" >&2; exit 1
    fi
    echo "TSan：零报告"
else
    echo "（本机没有 ThreadSanitizer，跳过 TSan 那一份）"
fi

# ---- 负控：六种变异
mutate() {   # $1 = 变异名，$2 = 原文，$3 = 改成，（可选）$4 = 第二处原文，$5 = 第二处改成
    mkdir -p "$out/m_$1"
    python3 - "$inc_src" "$out/m_$1/nvn_vk_dq.inc" "${@:2}" <<'PYMUT'
import pathlib, sys
src, dst, *rest = sys.argv[1:]
s = pathlib.Path(src).read_text(encoding="utf-8")
for a, b in zip(rest[0::2], rest[1::2]):
    if s.count(a) != 1:
        raise SystemExit('变异锚点变了（应恰好出现 1 次，实为 %d 次）：%s' % (s.count(a), a))
    s = s.replace(a, b)
pathlib.Path(dst).write_text(s, encoding="utf-8")
PYMUT
}
neg() {   # $1 = 变异名，$2 = 日志里必须出现的红（正则），$3 = 第一条红发生时所在阶段（正则），$4 = 1：没有红行但在该阶段崩溃（信号）也算，$5 = 只跑哪一组阶段（传给用例的参数，缺省全跑）
    build "$out/neg_$1" "$out/m_$1" -DTEST_TIMEOUT_S=40
    run "$out/neg_$1" "$out/log_$1" ${5:+"$5"}
    local first_red="" phase_at="（无红行、无崩溃）" ok=0
    first_red=$(grep -m1 '【红】' "$out/log_$1" || true)
    if [ -n "$first_red" ]; then
        phase_at=$(awk '/^阶段开始：/ { ph = $0 } /【红】/ { print ph; exit }' "$out/log_$1")
        if [ "$rc" -ne 0 ] && grep -qE "$2" "$out/log_$1" && printf '%s' "$phase_at" | grep -qE "$3"; then ok=1; fi
    elif [ "${4:-0}" = 1 ] && [ "$rc" -ge 128 ]; then
        phase_at=$(awk '/^阶段开始：/ { ph = $0 } END { print ph }' "$out/log_$1")
        first_red="（崩溃，信号 $((rc - 128))）"
        if printf '%s' "$phase_at" | grep -qE "$3"; then ok=1; fi
    fi
    if [ "$ok" -ne 1 ]; then
        cat "$out/log_$1" >&2
        echo "【红】负控 $1 没有红在预期处：rc=${rc}，第一条红 [${first_red}]，当时阶段 [${phase_at}]，预期红 /${2}/、阶段 /${3}/" >&2; exit 1
    fi
    echo "负控 ${1}：红在预期处（rc=${rc}，${first_red}，${phase_at}）"
}
mutate M1 'h->op = op; h->size = (uint32_t)need; h->cb = cb;' 'h->op = op; h->size = (uint32_t)need; h->cb = cb; atomic_store(&g_dq_pub, g_dq_w + need);   /* M1：没写完就发布 */'
neg M1 '【红】(C1 .*(条数不符|序列哈希不符|没登记)|C[1-4] 超时|超时)' 'C1' 1
mutate M2 '__atomic_fetch_add(&g_dq_drains, 1, __ATOMIC_RELAXED); dq_wake();' '__atomic_fetch_add(&g_dq_drains, 1, __ATOMIC_RELAXED); return;   /* M2：清空不等 */'
neg M2 '【红】(C1 .*条数不符|C2：)' 'C[12]'
mutate M3 'while (g_dq_w + need - atomic_load_explicit(&g_dq_rd, memory_order_acquire) > dq_RING) { dq_wake(); sched_yield(); }' '/* M3：不等环里有地方 */'
neg M3 '【红】(C[13] .*(条数不符|序列哈希不符|没登记)|C[13]：|超时)' 'C[13]' 1
mutate M4 'h->op = OP_WRAP; h->size = (uint32_t)(dq_RING - off);' 'h->op = OP_WRAP; h->size = (uint32_t)(dq_RING - off - 16);   /* M4：跳过的长度写错 */'
neg M4 '【红】(C1 .*(条数不符|序列哈希不符|没登记)|超时)' 'C1' 1
mutate M5 'dq_run(h); r += h->size; atomic_store(&g_dq_rd, r); }' 'const uint32_t sz_ = h->size; r += sz_; atomic_store(&g_dq_rd, r); dq_run(h); }   /* M5：先报已读 */'
neg M5 '【红】(C2：|C[13] .*条数不符)' 'C[123]'
mutate M6 'atomic_fetch_sub(&g_dq_draining, 1);' 'atomic_store(&g_dq_draining, 0);   /* M6：先走的抹掉别人的「在等」标记 */'
neg M6 '【红】C5：(先到的清空已返回、后到的尚未完成|后到的清空等了)' 'C5'
# ---- 录制线程等活的开关：五种变异，只跑 C6 那一组（每种直奔被测的阶段，不用等前面的阶段）
anchor_wake='if (!wb || (w > rd && w - rd >= wb)) dq_wake();'
mutate M7 "$anchor_wake" '(void)rd; if (!wb) dq_wake();   /* M7：按批叫时过线也不叫 */'
neg M7 '【红】C6b：' 'C6' 0 C6
mutate M8 'if (pthread_cond_timedwait(&g_dq_cv, &g_dq_mu, &dl) == ETIMEDOUT)' 'if (pthread_cond_wait(&g_dq_cv, &g_dq_mu) == ETIMEDOUT)   /* M8：定时醒不定时 */'
neg M8 '【红】C6c：' 'C6' 0 C6
mutate M9 'if (wait_us < DQ_POLL_MAX_US) wait_us *= 2;' 'wait_us *= 2;   /* M9：退避不封顶 */'
neg M9 '【红】C6d：' 'C6' 0 C6
mutate M10 'const int spin = atomic_load_explicit(&g_dq_spin, memory_order_relaxed);' 'const int spin = 200;   /* M10：不认 nvk_dq_spin */'
neg M10 '【红】C6e：' 'C6' 0 C6
mutate M11 "$anchor_wake" '(void)wb; (void)rd; dq_wake();   /* M11：按批叫失效，每条都叫 */'
neg M11 '【红】C6b：' 'C6' 0 C6
# ---- 环满 / 清空的叫醒路径、等待分布读数：六种变异（C6f / C6g / C7）
mutate M12 'uint64_t z = 0; atomic_compare_exchange_strong_explicit(&g_dq_t0, &z, dq_now_ns(), memory_order_relaxed, memory_order_relaxed);' 'uint64_t z = 0; (void)z;   /* M12：不记发布时刻 */'
neg M12 '【红】C7a：' 'C7' 0 C7
anchor_full='while (g_dq_w + need - atomic_load_explicit(&g_dq_rd, memory_order_acquire) > dq_RING) { dq_wake(); sched_yield(); }'
mutate M13 "$anchor_full" 'while (g_dq_w + need - atomic_load_explicit(&g_dq_rd, memory_order_acquire) > dq_RING) { sched_yield(); }   /* M13：环满不叫醒 */'
neg M13 '【红】超时' 'C6' 1 C6
mutate M14 '__atomic_fetch_add(&g_dq_drains, 1, __ATOMIC_RELAXED); dq_wake();' '__atomic_fetch_add(&g_dq_drains, 1, __ATOMIC_RELAXED);   /* M14：清空不叫醒 */' \
           'while (atomic_load_explicit(&g_dq_rd, memory_order_acquire) < w) { pthread_cond_signal(&g_dq_cv);' 'while (atomic_load_explicit(&g_dq_rd, memory_order_acquire) < w) {   /* M14：等待圈里也不叫 */'
neg M14 '【红】超时' 'C6' 1 C6
mutate M15 'dq_hist_add(g_dq_hd, &g_dq_hd_max, ns);' '/* M15：清空等待不进直方图 */'
neg M15 '【红】C7b：' 'C7' 0 C7
mutate M16 'dq_hist_add(g_dq_hw, &g_dq_hw_max, dq_now_ns() - t0);' 'dq_hist_add(g_dq_hw, &g_dq_hw_max, dq_now_ns() + t0);   /* M16：起点终点算反 */'
neg M16 '【红】C7a：' 'C7' 0 C7
mutate M17 'uint64_t need = (total * pct + 99) / 100, acc = 0;' 'uint64_t need = (total * pct) / 100, acc = 0;   /* M17：百分位向下取整 */'
neg M17 '【红】C7d：' 'C7' 0 C7
# ---- 暂存填充的代拷：四种变异（C8）
anchor_take_done='atomic_store_explicit(&sl->w, FILL_W(t, FILL_DONE), memory_order_release);'
mutate M18 "$anchor_take_done" "$anchor_take_done"' atomic_store_explicit(&g_fill_done, t, memory_order_release);   /* M18：代拷完推水位 */'
neg M18 '【红】C8a：' 'C8' 0 C8
mutate M19 "$anchor_take_done" '/* M19：代拷完不置「拷完」 */'
neg M19 '【红】超时' 'C8' 1 C8
mutate M20 'if (atomic_compare_exchange_strong_explicit(w, &e, FILL_W(a->seq, FILL_BUSY), memory_order_acquire, memory_order_acquire)) {' \
           'if (((void)atomic_compare_exchange_strong_explicit(w, &e, FILL_W(a->seq, FILL_BUSY), memory_order_acquire, memory_order_acquire), 1)) {   /* M20：不认代拷 */'
neg M20 '【红】C8a：' 'C8' 0 C8
mutate M21 'if ((ow >> 2) && (ow & 3) != FILL_DONE) dq_fill_take(ow >> 2);' '(void)ow;   /* M21：复用槽不先拷旧的 */'
neg M21 '【红】C8c：' 'C8' 0 C8
echo "两级回放队列宿主用例：正控全绿，二十一种变异都红在预期处"
