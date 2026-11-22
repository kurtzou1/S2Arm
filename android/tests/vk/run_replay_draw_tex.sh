#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 真 Vulkan 回放 DrawTexture 读回（#1452）：lavapipe + Khronos validation（含同步校验）。
# 先跑正例（6 组逐像素比对全对、校验层 0 条），再跑撤改负对照（抹掉 NVN_GPU_CAP_DRAW_TEX：同一组比对必须报红、每笔记一次未接）。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$(uname -s)" = Darwin ]; then
    export S2A_VULKAN_CACHE="$repo/build/vulkan-cache"
    exec bash "$repo/tests/vulkan/run.sh" android/tests/vk/run.sh
fi
icd=
for f in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json "$HOME"/.local/share/vulkan/icd.d/lvp_icd*.json; do
    if [ -f "$f" ]; then icd=$f; break; fi
done
layer=
for d in /usr/share/vulkan/explicit_layer.d "$HOME"/.local/share/vulkan/explicit_layer.d; do
    if [ -f "$d/VkLayer_khronos_validation.json" ]; then layer=$d; break; fi
done
if [ -z "$icd" ] || [ -z "$layer" ]; then echo '【红】缺 lavapipe 或 validation layer' >&2; exit 2; fi
mkdir -p "$repo/build/vk-drawtex-tmp"
out=$(mktemp -d "$repo/build/vk-drawtex-tmp/run.XXXXXX")
trap 'rm -rf "$out"' EXIT
cc -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 \
    -I "$repo/android/tests/vkhost" -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
    -I "$repo/graphics/nvn" -I "$repo/graphics/nvn/replay" -I "$repo/graphics/nvn/gfx/nvn" \
    -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/android/native" -I "$repo/android/native/nvn" -I "$repo/android/native/direct" \
    "$repo/android/tests/vk/t_replay_draw_tex.c" "$repo/graphics/nvn/replay/rp_draw_tex.c" \
    "$repo/android/native/nvn/backend_vulkan.c" "$repo/android/native/direct/vk_device.c" "$repo/android/native/direct/gs_path.c" \
    "$repo/android/native/nvn/nvn_vk_format.c" "$repo/graphics/nvn/gfx/nvn/nvn_fmt_expand.c" "$repo/android/native/nvn/nvn_vk_bcdec.c" \
    "$repo/android/native/nvn/nvn_vk_driver_cache.c" "$repo/android/native/direct/sha256.c" \
    "$repo/android/native/nvn/nvn_pipe_flight.c" "$repo/android/native/nvn/nvn_vk_pipe_once.c" \
    -Wl,--wrap=nvn_gpu_caps_get \
    -Wl,--wrap=vkAllocateDescriptorSets -Wl,--wrap=vkGetPhysicalDeviceFormatProperties \
    -Wl,--wrap=vkCreatePipelineCache -Wl,--wrap=vkGetPipelineCacheData \
    -Wl,--wrap=vkCreateGraphicsPipelines -Wl,--wrap=vkCreateComputePipelines -lvulkan -lpthread -lm -o "$out/test"
export VK_DRIVER_FILES=$icd VK_LAYER_PATH=$layer VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
for arm in pos neg; do
    set +e
    timeout 180 "$out/test" "$arm" 2>&1 | tee "$out/$arm.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ] || ! grep -q 'device: llvmpipe' "$out/$arm.log" || grep -qE 'Validation Error|VUID-|SYNC-HAZARD-' "$out/$arm.log"; then
        echo "【红】回放 DrawTexture Vulkan 验证失败（${arm}）rc=$rc" >&2; exit 1
    fi
done
grep -q 'draw-tex pos: cases=6 pixel-failures=0 unimpl-op=0 unimpl-other=0' "$out/pos.log" || { echo '【红】正例读数不对' >&2; exit 1; }
grep -qE 'draw-tex neg: cases=6 pixel-failures=[1-9][0-9]* unimpl-op=6 ' "$out/neg.log" || { echo '【红】负对照没有报红' >&2; exit 1; }
echo '✓ 回放 DrawTexture：lavapipe 6 组逐像素读回全对、校验层（含同步校验）0 条；撤改负对照逐像素报红、每笔记一次未接'
