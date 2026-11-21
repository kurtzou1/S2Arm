#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/run.sh 默认档按 standalone/*.sh 通配逐个跑（run.sh 末段 for 循环），单独跑用 run.sh --<名>
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
out="$repo/build/vk-bc1-rgb-alpha"
mkdir -p "$out"
: "${S2A_LAVAPIPE_ICD:?lavapipe required}" "${S2A_VK_LAYER_DIR:?validation required}"
source="$repo/android/native/nvn/nvn_vk_bcdec.c"
if [ "${1:-}" = --negative ]; then
    python3 - "$source" "$out/bcdec-negative.c" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
for fmt in ('41', '45'):
    anchor = f'[0x{fmt}] = {{{{SH_S3TC, 0, 1}}'
    assert source.count(anchor) == 1, 'BC1 RGB route anchor changed'
    source = source.replace(anchor, f'[0x{fmt}] = {{{{SH_S3TC, 1, 1}}')
pathlib.Path(sys.argv[2]).write_text(source)
PY
    source="$out/bcdec-negative.c"
elif [ -n "${1:-}" ]; then
    exit 64
fi
inc=(-I "$repo/graphics/nvn/third_party/vulkan-headers/include")
for d in android/tests/vkhost graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn \
         graphics/nvn/gfx/nvn/include android/native android/native/nvn android/native/direct runtime/include; do
    inc+=(-I "$repo/$d")
done
cc -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 -DS2A_BCDEC_HOST_TEST \
    "${inc[@]}" "$repo/android/tests/vk/t_bc_decode.c" "$source" \
    "$repo/android/native/direct/vk_device.c" "$repo/android/native/direct/gs_path.c" \
    "$repo/graphics/nvn/gfx/tex/nvn_bcdec.c" -Wl,--gc-sections -lvulkan -lpthread -lm -o "$out/test"
export VK_ICD_FILENAMES="$S2A_LAVAPIPE_ICD" VK_DRIVER_FILES="$S2A_LAVAPIPE_ICD"
export VK_LAYER_PATH="$S2A_VK_LAYER_DIR" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
set +e
S2A_VK_BC_DECODE=force timeout 180 "$out/test" > "$out/run.log" 2>&1
rc=$?
set -e
cat "$out/run.log"
messages=$(grep -cE 'Validation (Error|Warning)|VUID-|UNASSIGNED-' "$out/run.log" || true)
printf 'bc1-rgb-alpha validation-messages=%s rc=%s\n' "$messages" "$rc"
[ "$messages" = 0 ] || exit 1
exit "$rc"
