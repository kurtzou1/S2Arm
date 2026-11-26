#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/run.sh 默认发现 standalone/*.sh。单跑用 --replay-1d。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
out="$repo/build/vk-replay-1d"
mkdir -p "$out/shaders"
: "${S2A_LAVAPIPE_ICD:?lavapipe required}" "${S2A_VK_LAYER_DIR:?validation required}"
[ -f "$repo/build/c883-ndk/vulkan/vulkan_core.h" ] || { echo 'NDK 29 headers missing' >&2; exit 2; }
for shader in replay_1d.comp replay_1d_store.comp; do
    "${GLSLC:-glslc}" --target-env=vulkan1.1 "$repo/android/tests/vk/shaders/$shader" -o "$out/shaders/$shader.spv"
done
inc=()
for dir in build/c883-ndk android/tests/vkhost graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn \
    graphics/nvn/gfx/nvn/include graphics/nvn/gfx/tex android/native android/native/nvn android/native/direct runtime/include; do
    inc+=(-I "$repo/$dir")
done
src=(
    android/tests/vk/t_replay_1d.c
    graphics/nvn/replay/{rp_buf,rp_clear_tex,rp_entry,rp_pass,rp_res,rp_state,nvn_unimpl}.c
    graphics/nvn/gfx/nvn/{nvn_dirty,nvn_fmt_expand,nvn_tex}.c
    graphics/nvn/gfx/tex/nvn_deswizzle.c
    android/native/nvn/{backend_vulkan,nvn_pipe_flight,nvn_vk_pipe_once,nvn_vk_format,nvn_vk_bcdec,nvn_vk_driver_cache}.c
    android/native/direct/{vk_device,gs_path,sha256}.c
    android/native/capprobe/capprobe_host.c
)
cc -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 \
    "${inc[@]}" "${src[@]/#/$repo/}" -Wl,--gc-sections -Wl,--wrap=nvn_gpu_pass_begin -lvulkan -lpthread -lm -o "$out/test"
export VK_DRIVER_FILES="$S2A_LAVAPIPE_ICD" VK_LAYER_PATH="$S2A_VK_LAYER_DIR" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
printf '%s\n' 'khronos_validation.validate_sync = true' 'khronos_validation.syncval_shader_accesses_heuristic = true' > "$out/vk_layer_settings.txt"
export VK_LAYER_SETTINGS_PATH="$out/vk_layer_settings.txt"
rc=0
timeout 90 "$out/test" "$out/shaders" > "$out/run.log" 2>&1 || rc=$?
cat "$out/run.log"
if [ "$rc" -ne 0 ] || ! grep -q '^device: llvmpipe' "$out/run.log" ||
   ! grep -q '^replay 1D sampled=60/60 zero=2/2 layered=3$' "$out/run.log" || grep -qE 'Validation Error|VUID-|SYNC-HAZARD-' "$out/run.log"; then
    echo "【红】1D replay Vulkan rc=$rc" >&2
    exit 1
fi
