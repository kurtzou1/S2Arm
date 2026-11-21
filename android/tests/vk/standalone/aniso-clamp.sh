#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/run.sh 默认档按 standalone/*.sh 通配逐个跑（run.sh 末段 for 循环），单独跑用 run.sh --<名>
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
out="$repo/build/vk-aniso-clamp"
mkdir -p "$out"
: "${S2A_LAVAPIPE_ICD:?lavapipe required}" "${S2A_VK_LAYER_DIR:?validation required}"
backend="$repo/android/native/nvn/backend_vulkan.c"
if [ "${1:-}" = --negative ]; then
    python3 - "$backend" "$out/backend-negative.c" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
clamp = ('const float limit = g.dev->properties.limits.maxSamplerAnisotropy;\n'
         '        ci.maxAnisotropy = p->aniso > limit ? limit : p->aniso;')
assert source.count(clamp) == 1, 'anisotropy clamp anchor changed'
pathlib.Path(sys.argv[2]).write_text(source.replace(clamp, 'ci.maxAnisotropy = p->aniso;'))
PY
    backend="$out/backend-negative.c"
elif [ -n "${1:-}" ]; then
    exit 64
fi
inc=(-I "$repo/graphics/nvn/third_party/vulkan-headers/include")
for d in android/tests/vkhost graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn \
         graphics/nvn/gfx/nvn/include android/native android/native/nvn android/native/direct runtime/include; do
    inc+=(-I "$repo/$d")
done
cc -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 \
    "-DS2A_SAMPLER_BACKEND=\"$backend\"" "${inc[@]}" \
    "$repo/android/tests/vk/t_aniso_clamp.c" "$repo/graphics/nvn/replay/nvn_unimpl.c" \
    -Wl,--wrap=vkCreateSampler -Wl,--gc-sections -lvulkan -lpthread -lm -o "$out/test"
export VK_ICD_FILENAMES="$S2A_LAVAPIPE_ICD" VK_DRIVER_FILES="$S2A_LAVAPIPE_ICD"
export VK_LAYER_PATH="$S2A_VK_LAYER_DIR" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
timeout 30 "$out/test"
