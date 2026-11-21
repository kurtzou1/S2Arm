#!/usr/bin/env bash
# 首用管线后台构建（android/native/nvn/nvn_vk_pipe_demand.c）宿主集成测：fake 建管线驱动后台线程。
# 覆盖 kick→PENDING→建→READY、二次命中、失败→FAILED、仅着色器不同不串管线（P0 回归）、停局有界。无 GPU。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cc="${CC:-cc}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
incs=(-I "$repo/android/tests/vkhost" -I "$repo/android/tests/hostvk" -I "$repo/android/native" \
      -I "$repo/android/native/direct" -I "$repo/android/native/nvn" -I "$repo/runtime/include" \
      -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
      -I "$repo/graphics/nvn/third_party/vulkan-headers/include" -I "$repo/graphics/nvn/replay")
srcs=("$repo/android/tests/nvn_vk_pipe_demand_test.c" "$repo/android/native/nvn/nvn_vk_pipe_demand.c" "$repo/android/native/nvn/nvn_pipe_pend.c")
# s2a_fu_rt_reset 是弱引用（nvn_first_use.c，本测不链）：ELF 认未定义弱符号，苹果 ld 要逐个放行
weak=(); [ "$(uname -s)" = Darwin ] && read -r -a weak <<< "$(python3 "$repo/tools/weak_link_decl.py" flags pipedemand)"   # 清单从源码登记生成（nvn_vk_pipe_demand.c「弱链接[pipedemand]」）
"$cc" -std=gnu11 -DS2A_NVN_PIPE_DEMAND_TEST=1 -O1 -g -pthread -Wall -Wextra -Werror "${incs[@]}" -o "$tmp/t" "${srcs[@]}" "${weak[@]}"
"$tmp/t"
"$cc" -std=gnu11 -DS2A_NVN_PIPE_DEMAND_TEST=1 -O1 -g -pthread -fsanitize=address -fno-omit-frame-pointer "${incs[@]}" -o "$tmp/ta" "${srcs[@]}" "${weak[@]}"
leak=1; [ "$(uname -s)" = Darwin ] && leak=0   # 苹果的 ASan 不支持泄漏检测（设 1 直接中止）
ASAN_OPTIONS=detect_leaks=$leak "$tmp/ta"
echo "demand: GREEN + ASan clean (ok)"
