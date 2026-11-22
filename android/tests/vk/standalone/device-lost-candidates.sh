#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/run.sh 默认档通过 standalone/*.sh，单独跑 --device-lost-candidates。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
out="$repo/build/vk-device-lost-candidates"
mkdir -p "$out"
: "${S2A_LAVAPIPE_ICD:?lavapipe required}"
: "${S2A_VK_LAYER_DIR:?validation required}"
[ -f "$repo/build/c883-ndk/vulkan/vulkan_core.h" ] || { echo 'NDK 29 headers missing' >&2; exit 2; }
printf '#version 450\nlayout(local_size_x=1) in;\nvoid main() {}\n' |
    "${GLSLC:-glslc}" --target-env=vulkan1.1 -fshader-stage=compute -o "$out/identity.comp.spv" -

"${GLSLC:-glslc}" --target-env=vulkan1.1 "$repo/android/native/nvn/blit_shaders/fullscreen.vert" -o "$out/fullscreen.vert.spv"
"${GLSLC:-glslc}" --target-env=vulkan1.1 "$repo/android/tests/vk/shaders/solid_green.frag" -o "$out/solid_green.frag.spv"

inc=()
for d in android/tests/vkhost build/c883-ndk graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn graphics/nvn/gfx/nvn/include android/native android/native/nvn android/native/direct runtime/include; do
    inc+=(-I "$repo/$d")
done
backend="$repo/android/native/nvn"
src=()
for f in android/tests/vk/t_device_lost_candidates.c graphics/nvn/replay/nvn_unimpl.c android/native/nvn/nvn_pipe_flight.c android/native/nvn/nvn_vk_pipe_once.c android/native/direct/vk_device.c android/native/direct/gs_path.c android/native/capprobe/capprobe_host.c android/native/nvn/nvn_vk_format.c graphics/nvn/gfx/nvn/nvn_fmt_expand.c android/native/nvn/nvn_vk_bcdec.c android/native/nvn/nvn_vk_driver_cache.c android/native/direct/sha256.c; do
    src+=("$repo/$f")
done
build() {
    local output="$1" source="$2"
    cc -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
        -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 \
        "${inc[@]}" "${src[@]}" "$source/backend_vulkan.c" -Wl,--gc-sections \
        -Wl,--wrap=vkWaitForFences -Wl,--wrap=vkQueueSubmit -lvulkan -lpthread -lm -o "$output"
}
build "$out/test" "$backend"

export VK_DRIVER_FILES="$S2A_LAVAPIPE_ICD" VK_LAYER_PATH="$S2A_VK_LAYER_DIR" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
export VK_LAYER_VALIDATE_SYNC=1
cat > "$out/vk_layer_settings.txt" <<'SETTINGS'
khronos_validation.validate_sync = true
khronos_validation.syncval_shader_accesses_heuristic = true
SETTINGS
export VK_LAYER_SETTINGS_PATH="$out/vk_layer_settings.txt"
shaders=("$out/identity.comp.spv" "$out/fullscreen.vert.spv" "$out/solid_green.frag.spv")
validation_error='Validation Error|VUID-|SYNC-HAZARD-'
failed=0
for dq in 0 1; do
    for mode in fence submit concurrent truncate; do
        log="$out/dq$dq-$mode.log"
        if ! timeout 20 "$out/test" "${shaders[@]}" "$mode" "$dq" > "$log" 2>&1 ||
           grep -qE "$validation_error" "$log"; then
            echo "【红】device-lost dq=$dq mode=$mode" >&2
            cat "$log" >&2
            failed=1
        else
            grep -E 'device-lost first|^device-lost candidates:' "$log"
        fi
    done
done
[ "$failed" = 0 ] || exit "$failed"

# 负控只改构建输出内的源副本。必须走到行为断言，段错误和超时都不算。
for mutant in writeback omit-uncertain; do
    copy="$out/$mutant"
    mkdir -p "$copy"
    cp "$backend/backend_vulkan.c" "$backend/backend_vulkan_device_lost.inc" "$copy/"
    python3 - "$copy" "$mutant" <<'PYM'
from pathlib import Path
import sys

root, mutant = Path(sys.argv[1]), sys.argv[2]
if mutant == "writeback":
    source = root / "backend_vulkan.c"
    old = "            if (r == VK_ERROR_DEVICE_LOST) device_loss_report(vk, s, LOSS_OBSERVED);"
    new = """            if (r == VK_ERROR_DEVICE_LOST) {
                extern void s2a_capprobe_runtime_lost(void);
                s2a_capprobe_runtime_lost();
                device_loss_report(vk, s, LOSS_OBSERVED);
            }"""
else:
    source = root / "backend_vulkan_device_lost.inc"
    old = "    if (submitting && submitting != trigger) loss_capture(&snap, submitting, LOSS_SUBMIT_UNCERTAIN);"
    new = "    (void)submitting;"
text = source.read_text()
assert text.count(old) == 1, (mutant, old)
source.write_text(text.replace(old, new))
PYM
    build "$out/$mutant-test" "$copy"
    case "$mutant" in
        writeback) mode=fence; assertion='FAIL: DEVICE_LOST must not change the GS verdict, writebacks=1' ;;
        omit-uncertain) mode=concurrent; assertion='FAIL: concurrent candidates expected first/site/observed/inflight/uncertain=1/1/1/0/1, got 1/0/1/0/0' ;;
    esac
    log="$out/$mutant.log"
    rc=0
    timeout 20 "$out/$mutant-test" "${shaders[@]}" "$mode" 0 > "$log" 2>&1 || rc=$?
    if [ "$rc" != 1 ] || grep -qE "$validation_error" "$log" ||
       [ "$(grep -c '^FAIL: ' "$log")" != 1 ] || ! grep -Fxq "$assertion" "$log"; then
        echo "【红】device-lost negative $mutant rc=$rc" >&2
        cat "$log" >&2
        exit 1
    fi
    printf 'device-lost negative %s: %s\n' "$mutant" "${assertion#FAIL: }"
done
echo 'RESULT: PASS（device-lost：8 个正向场景，2 个行为负控）'
