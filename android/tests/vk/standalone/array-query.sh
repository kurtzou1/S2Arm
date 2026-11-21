#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/run.sh 默认档按 standalone/*.sh 通配逐个跑（run.sh 末段 for 循环），单独跑用 run.sh --array-query
# 数组采样层坐标改写（android/native/nvn/nvn_vk_array_query.h）的静态核对：glslc 编 4 个合成模块，核对改写处数、
# 改写结果过 spirv-val、不改写的保持原字节，另有 3 个截断输入。不建设备，不需要 lavapipe / validation。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
[ -z "${1:-}" ] || exit 64
args=(--cc "${CC:-cc}")
if [ -n "${GLSLC:-}" ] && [ -x "$GLSLC" ]; then args+=(--shader-tools "$(dirname "$GLSLC")"); fi
python3 "$repo/android/tests/array_query_test.py" "${args[@]}"
