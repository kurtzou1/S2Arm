#!/bin/bash
# #298：真实 Mac 前端 + 生产宿主/NVN/GAL/Widen，不使用宿主或图形替身。
# bash graphics/nvn/tests/t_present_residency.sh
# PRESENT_WIDEN_LIB 可指定已准备好的生产 Widen；测试不发布 Widen、不恢复 NuGet。
# 缺生产 Widen 或本树默认库已过期时退出 2（未完成 / 红），不跳过测试。准备命令见 README_present_residency.md。
# PRESENT_SHADER_VALIDATION=1 可另跑着色器验证；缺省关闭，避免掩盖驻留缺页反例。
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root"
source "$root/tools/toolchain.sh"
unset S2A_DUAL
out=${PRESENT_RESIDENCY_BUILD:-$root/build/tests/present-residency}
[[ "$out" = /* ]] || out="$root/$out"
mkdir -p "$out/host"
shader_validation=${PRESENT_SHADER_VALIDATION:-0}
[[ "$shader_validation" == 0 || "$shader_validation" == 1 ]] || { echo 'PRESENT_SHADER_VALIDATION 必须为 0 或 1' >&2; exit 2; }

if [[ -n ${PRESENT_WIDEN_LIB:-} ]]; then
    widen=$PRESENT_WIDEN_LIB
    [[ "$widen" = /* ]] || widen="$root/$widen"
    [[ -r "$widen" ]] || { printf '生产 Widen 不存在：%s\n' "$widen" >&2; exit 2; }
else
    # 仅使用预先准备的生产 AOT；依赖构建与 GPU 测试分开，测试不触发包还原。
    widen="$out/deps/tests/nvn/widen/S2Arm.Gfx.Widen.dylib"
    rebuild_widen=0
    if [[ ! -r "$widen" ]]; then
        rebuild_widen=1
    else
        while IFS= read -r -d '' input; do
            if [[ "$input" -nt "$widen" ]]; then rebuild_widen=1; fi
        done < <(find "$root/graphics/widen" -type f \( -name '*.cs' -o -name '*.csproj' -o -name '*.props' -o -name '*.targets' \) \
            ! -path '*/bin/*' ! -path '*/obj/*' -print0)
        for input in "$root"/Directory.Build.* "$root/tools/toolchain.env" "$root/runtime/build.mk"; do
            if [[ -f "$input" && "$input" -nt "$widen" ]]; then rebuild_widen=1; fi
        done
    fi
    [[ "$rebuild_widen" == 0 ]] || {
        printf '生产 Widen 缺失或已过期：%s\n请按 graphics/nvn/tests/README_present_residency.md 先准备依赖，再运行测试。\n' "$widen" >&2
        exit 2
    }
fi

# 由生产子 Makefile 判断完整依赖；不在测试里镜像 NVN/GAL 的源码清单。
make -j1 -C "$root/graphics/nvn" mac OUT="$out/nvn"
make -j1 -C "$root/graphics/metal" mac OUT="$out/gal"
make -j1 -C "$root/graphics/dsx" mac OUT="$out/dsx"   # 直连翻译库（翻译段 + SPIRV-Cross，11-08 从 libnxgal 拆出）
nvn="$out/nvn/mac/libnvn.a"
gal="$out/gal/mac/libnxgal.a"
dsx="$out/dsx/mac/libdsx.a"

# 与 runtime/build.mk 的 NVN_TEST_HOST_SRCS 相同：完整 native 源码，排除提供 main 的 host_main.c。
# 每次从本树源码编对象，避免借用别的工作树或陈旧对象。
common=(-O1 -g -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -I"$root/runtime/include" -I"$root/runtime/ns2pro/include" -DNS2_SCAN_SECONDS=60)   # Mac 前端源文件含 Switch 2 Pro 连接（macos/ns2_controller.c、runtime/ns2pro，#277），同 launchers/macos/build.mk
objects=()
for src in "$root"/runtime/src/*.c "$root"/runtime/src/*.S "$root/platform/apple/plat_apple.c" "$root/graphics/track/track.c" "$root/graphics/track/glue.c"; do
    rel=${src#"$root"/}
    [[ "$rel" != runtime/src/host_main.c ]] || continue
    object="$out/host/${rel//\//_}.o"
    xcrun --sdk macosx clang "${common[@]}" -c "$src" -o "$object"
    objects+=("$object")
done
# Mac 前端源文件清单从生产构建 launchers/macos/build.mk 的 HOST_SRCS 读（同下面 NVN_TEST_WEAK 的读法），不手抄：
#   10-25 main 给前端加了 ios/dprompt_reason.m（7457c41a），手抄的三行没跟上，本测试链接报 _s2a_dprompt_reason_body 未定义
front_srcs=$(printf '%s\n' 'present-residency-front:;@echo $(HOST_SRCS)' | make -s -f "$root/launchers/macos/build.mk" -f - present-residency-front S2A_MAC_FRONTEND=1)
read -r -a front_srcs <<< "$front_srcs"
[[ ${#front_srcs[@]} -gt 0 ]] || { echo 'launchers/macos/build.mk 读不出 Mac 前端源文件（HOST_SRCS）' >&2; exit 2; }
front_objects=()
for rel in "${front_srcs[@]}"; do
    object="$out/front_${rel//\//_}.o"
    xcrun --sdk macosx clang "${common[@]}" -fobjc-arc -c "$root/$rel" -o "$object"
    front_objects+=("$object")
done
# 只打印生产构建定义的弱引用参数，不运行 runtime/build.mk 的构建配方。
# 例如自动玩家在本集成测试中不链接；缺省弱引用须保持为空，不能提供替身。
# 原生层链接库同生产（runtime/build.mk 的 HOST_LIBS：Foundation、Security 等）：本脚本整目录编 runtime/src，手写框架表会漏新依赖（11-17 selfsign.c 加 Security 后这里链接红）
# 链进来的 Mac 前端源文件（上面 HOST_SRCS）的弱引用登记在「弱链接[host]」，生产宿主链接行带 S2A_HOST_WEAK 放行；这里同样带上，
#   不然前端新加一个弱引用（如 ios/ldn_lan.m 的 S2A_LdnSetServer，由 C# 服务层提供）本测试就链接红，而生产宿主照样链得过
weak_output=$(printf '%s\n' 'present-residency-weak:;@echo $(NVN_TEST_WEAK) $(S2A_HOST_WEAK) $(HOST_LIBS)' | \
    make -s -f "$root/runtime/build.mk" -f - present-residency-weak)
read -r -a weak_flags <<< "$weak_output"
xcrun --sdk macosx clang "${common[@]}" -std=gnu11 -fobjc-arc \
    -I"$root/graphics/nvn/gfx/nvn" -I"$root/graphics/nvn/gfx/nvn/include" -I"$root/graphics/nvn/host" \
    "$root/graphics/nvn/tests/t_present_residency.m" "${objects[@]}" "${front_objects[@]}" \
    "$nvn" "$gal" "$dsx" "$widen" -o "$out/t_present_residency" \
    -Wl,-dead_strip -Wl,-export_dynamic -Wl,-u,_s2a_mac_front_layer -Wl,-u,_nxgal_gpu_hold "${weak_flags[@]}" \
    -Wl,-rpath,"$(dirname "$widen")" \
    -framework AppKit -framework GameController -framework CoreHaptics -framework CoreBluetooth -framework IOKit -framework Metal -framework Foundation \
    -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
# -u 拉入真实前端与 GAL 定义；只沿用生产的弱引用放行（NVN_TEST_WEAK + 宿主的 S2A_HOST_WEAK），不启用 dynamic_lookup。
shasum -a 256 "$root/graphics/nvn/tests/t_present_residency.m" "${objects[@]}" "$nvn" "$gal" "$dsx" "$widen" \
    "${front_objects[@]}" "$out/t_present_residency" > "$out/link-inputs.sha256"

bad=0
for backend in mtl4 mtl3; do
    for link in 0 1; do
        name="$backend-link$link"
        runtime="$out/$name"
        log="$out/$name.log"
        mkdir -p "$runtime"
        run_env=(env -u NXGAL_BE -u MTL_SHADER_VALIDATION -u MTL_SHADER_VALIDATION_DEFAULT_STATE \
            -u MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING -u S2A_INPUT_CONFIG \
            S2A_GFX=direct S2A_GAME_DATA="$runtime" S2A_DOCS="$runtime" S2A_GAME_NAME="S2Arm #298 $name" \
            S2A_INPUT_GUIDE_PREFS="$runtime/input-guide.json" DM_PRESENT_LINK="$link" \
            MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert)
        if [[ "$backend" == mtl3 ]]; then run_env+=(NXGAL_BE=mtl3); fi
        if [[ "$shader_validation" == 1 ]]; then run_env+=(MTL_SHADER_VALIDATION=1); fi
        status=0
        "${run_env[@]}" "$out/t_present_residency" > "$log" 2>&1 || status=$?
        cat "$log"
        ok=1
        if [[ "$status" != 0 ]]; then ok=0; fi
        if [[ "$backend" == mtl3 ]]; then
            expected='direct backend: Metal 3 (forced by NXGAL_BE=mtl3)'
        else
            expected='direct backend: Metal 4 (GPU in the Metal 4 family)'
        fi
        if ! /usr/bin/grep -Fq "$expected" "$log"; then ok=0; fi
        if ! /usr/bin/grep -Eq '^present residency: [0-9]+/[0-9]+ passed$' "$log"; then ok=0; fi
        if /usr/bin/grep -Ein 'command buffer.*error|GPU Address Fault|PageFault|Page Fault|FATAL|failed assertion|Metal Validation Error' "$log"; then ok=0; fi
        if [[ "$ok" == 1 ]]; then
            printf 'PASS %s (shader validation=%s)\n' "$name" "$shader_validation"
        else
            printf 'FAIL %s (exit=%s, log=%s)\n' "$name" "$status" "$log" >&2
            bad=$((bad + 1))
        fi
    done
done
printf 'present residency matrix: %d/4 passed (logs: %s)\n' "$((4 - bad))" "$out"
[[ "$bad" == 0 ]]
