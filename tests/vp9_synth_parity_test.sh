#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec/Vp9*.cs compat/tree/src/Ryujinx.Graphics.Nvdec/Vpx/* compat/tree/src/Ryujinx.Graphics.Nvdec/Types/Vp9/* compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/** compat/tree/src/Ryujinx.Graphics.Video/*Vp9* services/vpx/** tests/vp9_native_parity/* tests/vp9_synth_parity/* tests/data/vp9_synth/* platform/apple/cs/video/AppleVideo.cs platform/apple/cs/video/VideoToolboxVp9Backend.cs
# 原生 VP9（libvpx + S2Arm 补丁，Vp9NativeFrame.cs 写帧头 / 参考槽）与托管解码器的逐作业对拍，合成码流版（t_vp9_native_parity.sh 要设备抓取、门禁跑不了）：
#   不打补丁的 libvpx 1.17.0（同 services/vpx/build.sh 的源码包）加测试专用钩子（tests/vp9_synth_parity/jobgen_hook.patch，默认 NULL）解 tests/data/vp9_synth
#   的合成码流，jobgen.c 把每个解出的帧写成游戏驱动交给 NVDEC 的作业（S2V9 v1，与设备抓取同格式），再由 tests/vp9_native_parity 逐作业跑原生与托管：
#   画面、MV 回写、计数逐字节相同，且画面等于 libvpx 自己解出的（三方一致）。不含任何游戏数据。
# VT 腿（--vt）：同一对拍再跑一遍苹果 VideoToolbox 硬解后端（platform/apple/cs/video/VideoToolboxVp9Backend.cs，与安卓
#   McVp9Backend 同一契约、不产 MV/计数）——每个 Decoded 作业的画面必须等于 libvpx 参考；隐藏帧 / 尺寸变化 / 压缩头
#   检查拦下的作业按原因归桶（与 Vp9NativePath 的回退同语义）。探针不过的机器（无系统 VP9 解码器 / 非 macOS）
#   程序退 75，如实记「跳过」不算失败；本机有系统 VP9 硬解时不许跳过。
# 负对照（每次都跑）：只给托管解码器错的锐度 → 原生≠托管必须红；两边同样错 → 原生=托管但≠libvpx，必须靠参考哈希红（证明三方那一条不瞎）。
#   VT 腿的负对照（VT 跑了的机器）：两边同样错 → 重打包非压缩头的 FilterLevel 变了、硬解画面跟着变，必须靠参考哈希红。
# 已知缺口：fp_ragged（350x198）的托管画面在右下角最后一个不满的超级块与 libvpx 不同（原生一致），该流只要求原生=libvpx、MV / 计数原生=托管。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo "vp9_synth_parity：要苹果配方的 libs2a_vpx.dylib（macOS），本机 $(uname -s)" >&2; exit 75; }
command -v xcrun >/dev/null || { echo 'missing Xcode' >&2; exit 75; }
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
export MSBUILDDISABLENODEREUSE=1
RID=osx-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64 )
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# 1. 作业生成器：不打 S2Arm 补丁的 libvpx（版本与 sha256 取 services/vpx/build.sh 那一行）+ 钩子，只解码、单线程。
#   libvpx.a 与编生成器要的头文件（源码树的 *.h + configure 生成的 vpx_config.h / *_rtcd.h）按「版本 + sha256 + 钩子补丁 + configure 参数」缓存，
#   目录名另带本机 clang 版本行的哈希（同 services/vpx/build.sh：两套 Xcode 不互删）；命中就不解包、不 configure、不 make（#313 维护者复审）
eval "$(grep -m1 '^VER=' "$H/services/vpx/build.sh")"
CFG=(--disable-vp8 --disable-vp9-encoder --enable-vp9-decoder --disable-examples --disable-tools --disable-docs --disable-unit-tests
     --disable-webm-io --disable-libyuv --enable-static --disable-shared)
TCV=$(xcrun clang --version 2> /dev/null | sed -n 1p) || TCV=
[ -n "$TCV" ] || { echo "🔴 vp9_synth_parity：取不到 clang 的版本行（xcrun 失败）" >&2; exit 1; }
KEY=$( { echo "$VER $SHA ${CFG[*]}"; cat "$H/tests/vp9_synth_parity/jobgen_hook.patch"; } | shasum -a 256 | cut -c1-12)
# 缓存根先取真路径（#313 门禁：根经过符号链接时 cpio -p 拒绝「穿过符号链接」解出，头文件一个没落、cpio 仍返回 0，
#   半套缓存被 mv 落位，jobgen.c 找不到 vpx/vp8dx.h）。头文件改用 tar 管道拷；落位前、命中时都按 jobgen_complete 点名检查，缺了就不落位 / 重建。
jobgen_root() { mkdir -p "$1" && (cd "$1" && pwd -P); }
jobgen_complete() {   # <缓存目录>：libvpx.a 与 jobgen.c 直接或间接要的头文件都在
    local f
    for f in libvpx.a include/vpx/vp8dx.h include/vpx/vpx_decoder.h include/vp9/common/vp9_onyxc_int.h include/vp9/common/vp9_entropymode.h \
             include/vp9/decoder/vp9_decoder.h include/vpx_config.h include/vp9_rtcd.h include/vpx_dsp_rtcd.h; do
        [ -s "$1/$f" ] || return 1
    done
}
jobgen_place() {   # <libvpx 源码树> <构建目录> <缓存目录>：先进临时目录，检查齐了才一次 mv 落位
    local t=$3.tmp.$$
    rm -rf "$t"; mkdir -p "$t/include"
    ( cd "$1" && find . -name '*.h' -print0 | tar --null -cf - -T - ) | tar -xf - -C "$t/include"
    cp "$2"/*.h "$t/include/"; cp "$2/libvpx.a" "$t/"; printf '%s\n' "$TCV" > "$t/toolchain.txt"
    jobgen_complete "$t" || { echo "🔴 vp9_synth_parity：生成器缓存不全（${t}），不落位" >&2; rm -rf "$t"; return 1; }
    rm -rf "$3"; mv "$t" "$3"
}

# 1a. 回归（#313 门禁红）：缓存根是符号链接时，落位后头文件与 libvpx.a 齐全（用一棵假的小源码树，不构建）
R=$W/symroot; mkdir -p "$R/real" "$R/src/vpx" "$R/src/vp9/common" "$R/src/vp9/decoder" "$R/obj"; ln -s "$R/real" "$R/link"
for f in vpx/vp8dx.h vpx/vpx_decoder.h vp9/common/vp9_onyxc_int.h vp9/common/vp9_entropymode.h vp9/decoder/vp9_decoder.h; do echo x > "$R/src/$f"; done
for f in vpx_config.h vp9_rtcd.h vpx_dsp_rtcd.h libvpx.a; do echo x > "$R/obj/$f"; done
RC=$(jobgen_root "$R/link")
if jobgen_place "$R/src" "$R/obj" "$RC/jobgen-test" && jobgen_complete "$R/link/jobgen-test"; then echo "通 符号链接缓存根：头文件与 libvpx.a 齐全"
else echo "🔴 符号链接缓存根：生成器缓存落位后不全"; exit 1; fi

C=$(jobgen_root "${S2A_VPX_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/vpx}")
G=$C/jobgen-$VER-$KEY-$(printf '%s' "$TCV" | shasum -a 256 | cut -c1-8)
if ! jobgen_complete "$G"; then
    until mkdir "$C/.lock-jobgen" 2> /dev/null; do p=$(cat "$C/.lock-jobgen/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock-jobgen"; sleep 0.5; done
    echo $$ > "$C/.lock-jobgen/pid"; trap 'rm -rf "$W" "$C/.lock-jobgen"' EXIT   # 几棵树同时跑时排队
    if ! jobgen_complete "$G"; then   # 没有，或是旧的半套（含 0bbff046 在符号链接根上留下的）：重建
        source "$H/android/tools/fetch_source.sh"
        TGZ=$(s2a_source_fetch "libvpx-$VER.tar.gz" "https://github.com/webmproject/libvpx/archive/refs/tags/v$VER.tar.gz" "$SHA")
        mkdir -p "$W/src" "$W/obj"; tar xzf "$TGZ" -C "$W/src" --strip-components 1
        patch -p1 -s -d "$W/src" < "$H/tests/vp9_synth_parity/jobgen_hook.patch"
        ( cd "$W/obj" && CC="xcrun clang" "$W/src/configure" "${CFG[@]}" > "$W/configure.log" 2>&1 && make -j8 > "$W/make.log" 2>&1 ) ||
            { echo "🔴 vp9_synth_parity：生成器用的 libvpx 构建失败" >&2; tail -5 "$W"/*.log >&2; exit 1; }
        jobgen_place "$W/src" "$W/obj" "$G"
    fi
    rm -rf "$C/.lock-jobgen"; trap 'rm -rf "$W"' EXIT
fi
xcrun clang -std=c11 -O2 -I"$G/include" "$H/tests/vp9_synth_parity/jobgen.c" "$G/libvpx.a" -o "$W/jobgen"

# 2. 被测的原生库（产品配方）与对拍程序
lib=$(bash "$H/services/vpx/build.sh" "$RID" | tail -1)
cd "$H/compat/tree"   # SDK（global.json）与包源（nuget.config）跟当前目录走
dotnet build "$H/tests/vp9_native_parity/Vp9NativeParity.csproj" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
run() { dotnet "$H/tests/vp9_native_parity/bin/Release/net10.0/Vp9NativeParity.dll" "$W/jobs/$1" "${lib%/*}/libs2a_vpx.dylib" "$2"; }

# 3. 对拍
fails=0
for s in adapt_720 resize fp_ragged; do
    mkdir -p "$W/jobs/$s"; "$W/jobgen" "$H/tests/data/vp9_synth/$s.ivf" "$W/jobs/$s"
    mode=--ref; [ "$s" = fp_ragged ] && mode=--ref-native
    if run "$s" "$mode"; then echo "通 ${s}（${mode}）"; else echo "🔴 ${s}：原生 / 托管 / libvpx 不一致"; fails=$((fails + 1)); fi
done

# 3b. VT 腿：苹果 VideoToolbox 硬解后端（--vt）走同一对拍。探针不过（程序退 75）按「跑不了」记跳过不算失败，
#     也不算通过——第一条流跳过后面几条不再重复试；本机有系统 VP9 硬解（维护者机器）时全部三条都要绿。
vt_skip=0
for s in adapt_720 resize fp_ragged; do
    [ "$vt_skip" = 1 ] && continue
    rc=0; out=$(S2A_NVDEC_VP9_VT=1 run "$s" --vt 2>&1) || rc=$?   # 硬解缺省关：VT 腿显式打开
    if [ "$rc" -eq 75 ]; then vt_skip=1; echo "跳过 vt-${s}：$out"
    elif [ "$rc" -eq 0 ]; then echo "通 vt-${s}（--vt）"
    else echo "🔴 vt-${s}：VideoToolbox 硬解画面与 libvpx 参考不一致"; echo "$out"; fails=$((fails + 1)); fi
done

# 4. 负对照：必须红
# 4a. VT 腿负对照（VT 跑了的机器）：两边同样错 → 重打包非压缩头的 FilterLevel 变了、硬解画面跟着变，必须靠参考哈希红
if [ "$vt_skip" = 0 ]; then
    if S2A_VP9_PARITY_PERTURB=both run adapt_720 --vt > "$W/vtneg.log" 2>&1; then
        echo "🔴 VT 腿负对照没红：硬解对拍看不出差别"; cat "$W/vtneg.log"; fails=$((fails + 1))
    else echo "通 VT 腿负对照红了：$(tr "\n" " " < "$W/vtneg.log")"; fi
fi
for p in managed both; do
    if S2A_VP9_PARITY_PERTURB=$p run adapt_720 --ref > "$W/neg.log"; then
        echo "🔴 负对照 $p 没红：对拍看不出差别"; cat "$W/neg.log"; fails=$((fails + 1))
    else echo "通 负对照 $p 红了：$(tr "\n" " " < "$W/neg.log")"; fi
done
[ "$fails" = 0 ] && echo "vp9_synth_parity 单测全过" || { echo "vp9_synth_parity：$fails 项不过"; exit 1; }
