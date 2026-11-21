#!/bin/bash
# #604：真实生产宿主、前端、Metal 和时钟；不联网，不提供替身。
# FPS_WIDEN_LIB 指向与被测源码一致、预先准备的生产 Widen。
# FPS_SOURCE_ROOT 可指固定旧工作树；测试源码始终使用本脚本旁的同一份，用于旧红 / 新绿。
set -euo pipefail
test_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
root=${FPS_SOURCE_ROOT:-$test_root}
cd "$root"
source "$root/tools/toolchain.sh"
high=${FPS_HIGH_REFRESH:-0}
[[ "$high" == 0 || "$high" == 1 ]] || { echo 'FPS_HIGH_REFRESH 只接受 0/1' >&2; exit 2; }
default_out="$test_root/build/tests/fps-limit"
if [[ "$high" == 1 ]]; then default_out="$test_root/build/tests/fps-limit-high-refresh"; fi
out=${FPS_LIMIT_BUILD:-$default_out}
[[ "$out" = /* ]] || out="$test_root/$out"
[[ -n ${FPS_WIDEN_LIB:-} && -r "$FPS_WIDEN_LIB" ]] || { echo 'FPS_WIDEN_LIB 必须指向预先准备、与被测源码一致的生产 Widen' >&2; exit 2; }
widen=$FPS_WIDEN_LIB
mkdir -p "$out/host"
make -j1 -C "$root/graphics/nvn" mac OUT="$out/nvn" > "$out/nvn-build.log" 2>&1
make -j1 -C "$root/graphics/metal" mac OUT="$out/gal" > "$out/gal-build.log" 2>&1
make -j1 -C "$root/graphics/dsx" mac OUT="$out/dsx" > "$out/dsx-build.log" 2>&1   # 直连翻译库（翻译段 + SPIRV-Cross，11-08 从 libnxgal 拆出）
common=(-O1 -g -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -I"$root/runtime/include" -I"$root/runtime/ns2pro/include" -DNS2_SCAN_SECONDS=60)   # Mac 前端源文件含 Switch 2 Pro 连接（macos/ns2_controller.c、runtime/ns2pro，#277），同 launchers/macos/build.mk
objects=()
for src in "$root"/runtime/src/*.c "$root"/runtime/src/*.S "$root/platform/apple/plat_apple.c" "$root/graphics/track/track.c" "$root/graphics/track/glue.c"; do
    rel=${src#"$root"/}
    [[ "$rel" != runtime/src/host_main.c ]] || continue
    object="$out/host/${rel//\//_}.o"
    xcrun --sdk macosx clang "${common[@]}" -c "$src" -o "$object" >> "$out/host-build.log" 2>&1
    objects+=("$object")
done
front_srcs=$(printf '%s\n' 'fps-limit-front:;@echo $(HOST_SRCS)' | make -s -f "$root/launchers/macos/build.mk" -f - fps-limit-front S2A_MAC_FRONTEND=1)
read -r -a front_srcs <<< "$front_srcs"
[[ ${#front_srcs[@]} -gt 0 ]] || { echo '生产 Mac 前端源文件清单为空' >&2; exit 2; }
for rel in "${front_srcs[@]}"; do
    object="$out/front_${rel//\//_}.o"
    xcrun --sdk macosx clang "${common[@]}" -fobjc-arc -c "$root/$rel" -o "$object" >> "$out/host-build.log" 2>&1
    objects+=("$object")
done
# 原生层链接库同生产（runtime/build.mk 的 HOST_LIBS：Foundation、Security 等）：本脚本整目录编 runtime/src，手写框架表会漏新依赖（11-17 selfsign.c 加 Security 后这里链接红）
weak_output=$(printf '%s\n' 'fps-limit-weak:;@echo $(NVN_TEST_WEAK) $(HOST_LIBS)' | make -s -f "$root/runtime/build.mk" -f - fps-limit-weak)
read -r -a weak_flags <<< "$weak_output"
xcrun --sdk macosx clang "${common[@]}" -std=gnu11 -fobjc-arc \
    -I"$root/graphics/nvn/gfx/nvn" -I"$root/graphics/nvn/gfx/nvn/include" -I"$root/graphics/nvn/host" \
    -I"$root/graphics/nvn/third_party/vulkan-headers/include" \
    "$test_root/graphics/nvn/tests/t_fps_limit.m" "${objects[@]}" "$out/nvn/mac/libnvn.a" "$out/gal/mac/libnxgal.a" "$out/dsx/mac/libdsx.a" "$widen" \
    -o "$out/t_fps_limit" -Wl,-dead_strip -Wl,-export_dynamic -Wl,-u,_s2a_mac_front_layer -Wl,-u,_nxgal_gpu_hold "${weak_flags[@]}" \
    -Wl,-rpath,"$(dirname "$widen")" -framework AppKit -framework GameController -framework CoreHaptics -framework CoreBluetooth -framework IOKit -framework Metal -framework Foundation \
    -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++ > "$out/link.log" 2>&1
shasum -a 256 "$test_root/graphics/nvn/tests/t_fps_limit.m" "${objects[@]}" "$out/nvn/mac/libnvn.a" "$out/gal/mac/libnxgal.a" "$out/dsx/mac/libdsx.a" "$widen" "$out/t_fps_limit" > "$out/link-inputs.sha256"
if [[ ${FPS_BUILD_ONLY:-0} == 1 ]]; then exit 0; fi
bad=0; cases=0; incomplete=0
run_case() {
    local backend=$1 link=$2 api=$3 fps=$4 interval=$5 hz=$6 expected=$7 window=$8 hud=${9:-0} dynamic=${10:-0} pin=${11:-0} return_one=${12:-0} focus=${13:-0} stall=${14:-0} split=${15:-0} flap=${16:-0}
    local name="$backend-link$link-$api-fps$fps-itv$interval-hz$hz-window$window"
    if [[ "$hud" == 1 ]]; then name="$name-hud1"; fi
    if [[ "$dynamic" == 1 ]]; then name="$name-dynamic"; fi
    if [[ "$pin" != 0 ]]; then name="$name-pin$pin"; fi
    if [[ "$return_one" == 1 ]]; then name="$name-return1"; fi
    if [[ "$focus" == 1 ]]; then name="$name-focus"; fi
    if [[ "$stall" == 1 ]]; then name="$name-stall"; fi
    if [[ "$split" == 1 ]]; then name="$name-split"; fi
    if [[ "$flap" == 1 ]]; then name="$name-flap"; fi
    local runtime="$out/$name" status=0
    mkdir -p "$runtime"
    local run_env=(env -u NXGAL_BE -u DM_FPS -u DM_DETCLOCK -u DM_DETCLOCK_PACE -u S2A_INPUT_CONFIG -u FPS_TEST_DYNAMIC -u FPS_TEST_RETURN_ONE -u FPS_TEST_DEACTIVATE -u FPS_TEST_FOCUS -u FPS_TEST_STALL -u FPS_TEST_SPLIT -u DM_TEST_LINK_STALL \
        -u MTL_SHADER_VALIDATION -u MTL_SHADER_VALIDATION_DEFAULT_STATE -u MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING \
        S2A_GFX=direct S2A_WIDEN_DIRECT=0 S2A_FPS="$fps" S2A_FPS60=0 S2A_GAME_DATA="$runtime" S2A_DOCS="$runtime" \
        S2A_HUD="$hud" FPS_TEST_HUD="$hud" FPS_TEST_HUD_TARGET="$fps" \
        S2A_GAME_NAME="S2Arm #604 $name" S2A_INPUT_GUIDE_PREFS="$runtime/input-guide.json" \
        DM_PRESENT_LINK="$link" DM_PRESENT_HZ="$hz" DM_PRESENT_INTERVAL=game MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert)
    if [[ "$backend" == mtl3 ]]; then run_env+=(NXGAL_BE=mtl3); fi
    if [[ "$dynamic" == 1 ]]; then run_env+=(FPS_TEST_DYNAMIC=1); fi
    if [[ "$pin" != 0 ]]; then run_env+=(DM_FPS="$pin"); fi
    if [[ "$return_one" == 1 ]]; then run_env+=(FPS_TEST_RETURN_ONE=1); fi
    if [[ "$focus" == 1 ]]; then run_env+=(FPS_TEST_FOCUS=1); fi
    if [[ "$stall" == 1 ]]; then run_env+=(FPS_TEST_STALL=1 DM_TEST_LINK_STALL=0.5,0.5); fi
    if [[ "$split" == 1 ]]; then run_env+=(FPS_TEST_SPLIT=1); fi
    if [[ "$flap" == 1 ]]; then run_env+=(FPS_TEST_FLAP=1); fi
    "${run_env[@]}" "$out/t_fps_limit" "$api" "$interval" "$expected" "$window" > "$out/$name.log" 2>&1 || status=$?
    if [[ "$dynamic" == 1 ]]; then
        local switches
        switches=$(awk '/present pacing mode/ { frame=$NF; gsub(/[^0-9]/,"",frame); frame+=0; if (frame >= 327 && frame < 436) n++ } END {print n+0}' "$out/$name.log")
        # 逐帧 2↔3：30 Hz 表示不了 50 ms，进阶段立即回 60 Hz 一次，之后不逐帧换档（11-04，原期望 0 次 = 留在 30 Hz）
        if [[ "$switches" == 1 ]]; then
            printf 'PASS 逐帧2/3只回60Hz一次：范围setter次数1\n' >> "$out/$name.log"
        else
            printf 'FAIL 逐帧2/3触发范围setter %s 次，期望1（回60Hz一次）\n' "$switches" >> "$out/$name.log"; status=1
        fi
    fi
    if [[ "$flap" == 1 ]]; then
        # 退避：间隔 2 稳 1 秒降 30 Hz，转间隔 3 立即回 60（30 Hz 给不出 50 ms），间隔 3 稳 1 秒降 20 Hz、被一帧间隔 2 打回 60；
        #   之后 1.45 秒的间隔 3 段不够翻倍后的 2 秒，不再降档：全程换档 ≤6 次（起链 + 4 次 + 1 次余量）；不退避时每 1.5 秒来回一次，约 14 次以上
        local flaps
        flaps=$(/usr/bin/grep -c 'present pacing mode' "$out/$name.log" || true)
        if [[ "$flaps" -le 6 ]]; then printf 'PASS 来回切换档 %s 次（≤6）\n' "$flaps" >> "$out/$name.log"
        else printf 'FAIL 来回切换档 %s 次，期望 ≤6（退避）\n' "$flaps" >> "$out/$name.log"; status=1; fi
    fi
    if [[ "$focus" == 1 && "$status" == 0 ]]; then
        # Independent lifecycle oracle: no batch may bridge the keyless
        # interval; a new 30-interval batch needs at least 30 * 45 ms.
        if awk '
            /FOCUS_LOST / { lost=1 }
            /sampling reset/ && lost && /active=0/ { reset=1 }
            /FOCUS_RESTORED / { restored=$3; lost=0 }
            /30 real callback intervals median/ {
                if (!restored || lost || /unavailable/) bad=1;
                if (/granted at/) { split($0,a,"granted at "); split(a[2],b," "); if (b[1]-restored >= 1350000000) fresh=1; else bad=1 }
            }
            /20 Hz unavailable|present pacing mode 4 → 1/ { bad=1 }
            END { exit !(reset && fresh && !bad) }
        ' "$out/$name.log"; then
            printf 'PASS 真实失焦清批次，恢复后新30间隔合格、20Hz仍可用\n' >> "$out/$name.log"
        else
            printf 'FAIL 真实失焦/恢复采样边界（原始时间戳与中位日志见上）\n' >> "$out/$name.log"; status=1
        fi
    fi
    if [[ "$stall" == 1 && "$status" == 0 ]]; then
        if ! /usr/bin/grep -q 'display link recovered:' "$out/$name.log"; then
            printf 'UNTESTED 正式诊断暂停未触发真实stall/recovered\n' >> "$out/$name.log"; status=2
        elif awk '
            /DM_TEST_LINK_STALL: pausing/ { paused=1 }
            /sampling reset/ && /stall=[1-9]/ { split($0,a,"reset at "); reset=a[2]+0 }
            /display link recovered:/ { recovered=1 }
            /30 real callback intervals median/ {
                if (!reset || !recovered || /unavailable/) bad=1;
                if (/granted at/) { split($0,a,"granted at "); split(a[2],b," "); if (b[1]-reset >= 1350000000) fresh=1; else bad=1 }
            }
            /20 Hz unavailable|present pacing mode 4 → 1/ { bad=1 }
            END { exit !(paused && reset && recovered && fresh && !bad) }
        ' "$out/$name.log"; then
            printf 'PASS 正式诊断真实暂停/recovered清批次，恢复20Hz仍可用\n' >> "$out/$name.log"
        else
            printf 'FAIL 真实stall/recovered采样边界\n' >> "$out/$name.log"; status=1
        fi
    fi
    cases=$((cases + 1))
    local expected_backend='direct backend: Metal 4 (GPU in the Metal 4 family)'
    if [[ "$backend" == mtl3 ]]; then expected_backend='direct backend: Metal 3 (forced by NXGAL_BE=mtl3)'; fi
    if [[ "$status" == 0 ]] && /usr/bin/grep -Fq "$expected_backend" "$out/$name.log" && \
        ! /usr/bin/grep -Ei 'command buffer.*error|GPU Address Fault|PageFault|Page Fault|FATAL|failed assertion|Metal Validation Error|^FAIL ' "$out/$name.log"; then
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s (exit=%s, log=%s)\n' "$name" "$status" "$out/$name.log" >&2; bad=$((bad + 1))
        if [[ "$status" == 2 ]]; then incomplete=$((incomplete + 1)); fi
        # 门禁的树会被下一局复用，格子日志留不住、只剩红摘要：把这一格判红的那几行和末 4 行随红打出来。
        #   行首用「✗」：graphics/gate.sh evidence 摘 ^(✗ |不通 |FAIL) 前 20 行（同 t_present_settings.sh）
        { /usr/bin/grep -aE '^(FAIL |UNTESTED)|command buffer.*error|GPU Address Fault|Page ?Fault|FATAL|failed assertion|Metal Validation Error' "$out/$name.log" | head -n 6
          tail -n 4 "$out/$name.log"; } 2> /dev/null | cut -c1-200 | sed "s/^/✗ 尾 ${name}｜/" >&2
    fi
    /usr/bin/grep -E '实际窗口屏幕|实际显示链接计数频率|真实时钟|实际显示周期|NVN present 只入队|HUD有效目标|HUD慢帧|UNTESTED|fps limit:' "$out/$name.log" || true
}
if [[ ${FPS_FOCUS_ONLY:-0} == 1 ]]; then
    for backend in mtl4 mtl3; do run_case "$backend" 1 nvn 30 3 60 50 1 0 0 0 0 1; done
    printf 'fps limit focus probes: %d/2 passed, %d untested (logs: %s)\n' "$((cases - bad))" "$incomplete" "$out"
elif [[ ${FPS_SPLIT_ONLY:-0} == 1 ]]; then
    # 取图与上屏分在两个线程（牧场物语形态）：节拍仍是 60 / 30 帧，不随上屏线程走丢
    run_case mtl4 0 nvn 0 1 60 16.666667 0 0 0 0 0 0 0 1; run_case mtl4 0 nvn 30 1 60 33.333333 0 0 0 0 0 0 0 1
    printf 'fps limit split-thread probes: %d/2 passed, %d untested (logs: %s)\n' "$((cases - bad))" "$incomplete" "$out"
elif [[ ${FPS_STALL_ONLY:-0} == 1 ]]; then
    for backend in mtl4 mtl3; do run_case "$backend" 1 nvn 30 3 60 50 1 0 0 0 0 0 1; done
    printf 'fps limit stall probes: %d/2 passed, %d untested (logs: %s)\n' "$((cases - bad))" "$incomplete" "$out"
elif [[ "$high" == 0 ]]; then
    if [[ ${FPS_INTERVAL3_ONLY:-0} != 1 ]]; then
    # 核心24个无窗口场景：原生60/30不被较高上限解除，诊断无锁时分别限制30/60/120。
    for cap in 0 30 60 120; do
        period=16.666667; [[ "$cap" != 30 ]] || period=33.333333
        run_case mtl4 0 nvn "$cap" 1 60 "$period" 0
        run_case mtl4 0 vk "$cap" 1 60 "$period" 0
        period=0; [[ "$cap" == 0 ]] || period=$(awk -v cap="$cap" 'BEGIN { printf "%.6f", 1000 / cap }')
        run_case mtl4 0 nvn "$cap" 1 0 "$period" 0
        run_case mtl4 0 gl "$cap" 0 60 "$period" 0
        run_case mtl4 0 nvn "$cap" 2 60 33.333333 0
        run_case mtl4 0 gl "$cap" 2 60 33.333333 0
    done
    # 取图与上屏分在两个线程（11-02 牧场物语：主线程取图、渲染线程上屏）：节拍跟着出帧的取图线程，原生 60 帧不解除
    run_case mtl4 0 nvn 0 1 60 16.666667 0 0 0 0 0 0 0 1
    # 10个真实30Hz链接场景：interval1/2不叠加成15帧。
    for backend in mtl4 mtl3; do
        for api in nvn gl vk; do
            run_case "$backend" 1 "$api" 30 1 60 33.333333 1
            if [[ "$api" != vk ]]; then run_case "$backend" 1 "$api" 30 2 60 33.333333 1; fi
        done
    done
    # 6个HUD场景：真实200ms停顿，目标30、慢帧分子/108个真实间隔。
    for backend in mtl4 mtl3; do
        for api in nvn gl vk; do run_case "$backend" 1 "$api" 30 1 60 33.333333 1 1; done
    done
    fi
    # interval3原生20fps不被自动30Hz取整为两拍(66.7ms)，30上限也不能改变50ms。
    for backend in mtl4 mtl3; do
        for cap in 0 30 60 120; do run_case "$backend" 1 nvn "$cap" 3 60 50 1; done
        run_case "$backend" 1 nvn 0 2 60 33.333333 1 0 1
        run_case "$backend" 1 nvn 30 2 60 33.333333 1 0 1 0 1
        # 显式DM_FPS30是backend测试pin，不是用户上限；保留既有强制30Hz诊断。
        run_case "$backend" 1 nvn 30 3 60 66.666667 1 0 0 30
        run_case "$backend" 1 nvn 30 3 60 50 1 0 0 60
        # 金刚形态：间隔 3 为主、每 30 帧一帧 2；不得 60↔20 Hz 来回换档，也不得留在 30 Hz 把 50 ms 取整成 67 ms
        run_case "$backend" 1 nvn 0 3 60 50 1 0 0 0 0 0 0 0 1
    done
    expected_cases=59; [[ ${FPS_INTERVAL3_ONLY:-0} != 1 ]] || expected_cases=18   # 57：11-02 加分线程取图一例（牧场物语形态）
    [[ "$cases" == "$expected_cases" ]] || { echo "核心场景数量错误：${cases}（应${expected_cases}）" >&2; exit 1; }
    printf 'fps limit core matrix: %d/%d passed (logs: %s)\n' "$((cases - bad))" "$expected_cases" "$out"
    echo '120 Hz专项未执行：有真实120Hz屏幕时另设 FPS_HIGH_REFRESH=1（仅运行26项）。'
else
    # 26个120Hz专项；能力不足由真实屏幕和链接采样返回UNTESTED/exit2，不能计绿。
    # GL interval0的120上限只等一实际拍；NVN无锁诊断仍保留原先interval1两拍的60步进。
    for backend in mtl4 mtl3; do
        for cap in 0 60 120; do
            period=0; [[ "$cap" == 0 ]] || period=$(awk -v cap="$cap" 'BEGIN { printf "%.6f", 1000 / cap }')
            run_case "$backend" 2 gl "$cap" 0 60 "$period" 1
            run_case "$backend" 2 nvn "$cap" 1 0 16.666667 1
        done
        # #619 F-hud-cap-above-game：GL 交换间隔 0 + 上限 120 的浮层目标应是 120（慢帧阈值 12.5 ms），不是 nvn_game_fps 缺省 60
        run_case "$backend" 2 gl 120 0 60 8.333333 1 1
        for cap in 0 30 60 120; do run_case "$backend" 2 nvn "$cap" 3 60 50 1; done
        run_case "$backend" 2 nvn 0 2 60 33.333333 1 0 1
        run_case "$backend" 2 nvn 30 2 60 33.333333 1 0 1 0 1
    done
    [[ "$cases" == 26 ]] || { echo "120Hz场景数量错误：${cases}（应26）" >&2; exit 1; }
    printf 'fps limit 120 Hz matrix: %d/26 passed, %d untested (logs: %s)\n' "$((cases - bad))" "$incomplete" "$out"
fi
if [[ "$bad" == 0 ]]; then exit 0; fi
if [[ "$bad" == "$incomplete" ]]; then exit 2; fi
exit 1
