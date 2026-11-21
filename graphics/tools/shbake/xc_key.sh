#!/bin/bash
# 着色器阶段键的「GAL 翻译代码」分量：bash graphics/tools/shbake/xc_key.sh   → 打印 16 位哈希
# 出包时 gal_xc（graphics/metal/tools/gal_xc.c + libnxgal）把 SPIR-V 翻成 MSL 与离线索引，它链着整个渲染器库，但真正跑到的只是翻译路径（gal_prog / gal_spvx / SPIRV-Cross …）。
# 做法：取 HEAD 的 graphics/metal + graphics/third_party + SMAA 查找表，按 Makefile 的编译参数编全部 gal_*.m 与 SPIRV-Cross，ObjC 类表去根（xc_unroot.py），和 gal_xc.c 静态链接 + 死代码剥离，
#   键 = 剩下的二进制（去符号）哈希 + Makefile 的编译参数（OBJCFLAGS / SPVC_DEF：参数改了也变；10-22 起不哈希整份 Makefile——加个单测目标九款就整份重翻）。渲染器里翻译用不到的代码（出图、绘制、缓冲…）改了键不变；翻译路径上任何一行改了键就变。
#   10-21 实测：改 gal_present.m 出图日志键不变；改 gal_prog.m 的 MSL 版本选项、改 SPIRV-Cross 源码键都变（tests/xc_key_test.sh）。
# 缓存：同一组（graphics/metal 树号、graphics/third_party 树号、SMAA 查找表对象号、clang 版本、macOS SDK 版本、本脚本与 xc_unroot.py）只编一次（约 10 秒），结果存 S2A_XCKEY_CACHE（缺省 ~/.s2arm/run/s2arm/cache/xckey）。
# S2A_XCKEY_TREE=<目录>：不取 HEAD，直接用该目录（含上述源码、查找表与 tools/toolchain.env；单测用）。
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); R=$(cd "$H/../../.." && pwd)
LUT=compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures
C=${S2A_XCKEY_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/xckey}; mkdir -p "$C"
# 渲染器源码在这几个目录之外引的头：出图 gal_present.m 引 HDR 策略头（直连层与 gal 同一份），取 HEAD 源码要一起带上、也进键的输入
HDRP=graphics/nvn/gfx/nvn/nvn_hdr_policy.h
if [ -n "${S2A_XCKEY_TREE:-}" ]; then S=$(cd "$S2A_XCKEY_TREE" && pwd); M=
else M=$({ git -C "$R" rev-parse HEAD:graphics/metal HEAD:graphics/dsx HEAD:graphics/third_party "HEAD:$LUT/SmaaAreaTexture.bin" "HEAD:$LUT/SmaaSearchTexture.bin" HEAD:$HDRP; clang --version | head -1; xcrun --sdk macosx --show-sdk-version 2> /dev/null; cat "$H/xc_key.sh" "$H/xc_unroot.py"; } | shasum -a 256 | cut -c1-32)
  [ -s "$C/$M" ] && { cat "$C/$M"; exit 0; }; S=
  # 同一组只编一份：各款刷新会同时算键（合入后九款并行出包），后到的等先到的出结果（持有者死了接管）
  until mkdir "$C/$M.lock" 2> /dev/null; do [ -s "$C/$M" ] && { cat "$C/$M"; exit 0; }
    p=$(cat "$C/$M.lock/pid" 2> /dev/null); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/$M.lock"; sleep 1; done
  echo $$ > "$C/$M.lock/pid"; fi
T=$(mktemp -d); trap 'rm -rf "$T"; [ -n "$M" ] && rm -rf "$C/$M.lock"' EXIT
if [ -z "$S" ]; then mkdir -p "$T/src" && git -C "$R" archive HEAD graphics/metal graphics/dsx graphics/third_party tools/toolchain.env "$LUT/SmaaAreaTexture.bin" "$LUT/SmaaSearchTexture.bin" "$HDRP" | tar -x -C "$T/src" || { echo "【红】xc_key：取 HEAD 源码失败" >&2; exit 1; }; S=$T/src; fi
MD=$S/graphics/metal; DD=$S/graphics/dsx; SP=$S/graphics/third_party/spirv_cross; O=$T/o; mkdir -p "$O/gal" "$O/spvc" "$O/gen"
mkv() { make -s --no-print-directory -C "${2:-$MD}" -f Makefile -f <(printf 'xk_print:\n\t@echo $(%s)\n' "$1") OUT="$O" xk_print; }
OF=$(mkv OBJCFLAGS) && SD=$(mkv SPVC_DEF "$DD") && DF=$(mkv DSX_CFLAGS "$DD") && MV=$(mkv MACOSX_DEPLOYMENT_TARGET) && MS=$(mkv MACSYS) && [ -n "$MV" ] || { echo "【红】xc_key：读不出 Makefile 的编译参数" >&2; exit 1; }
# 编源码要的生成头（ABI 指纹、内嵌细分器 MSL …）按 Makefile 的 GENH 生成（10-21 曲面细分加了 gal_tess_msl.h，手写只生成 ABI 头时编不过）
GH=$(mkv GENH); [ -n "$GH" ] || GH=$(mkv ABIH)
# shellcheck disable=SC2086
make -s --no-print-directory -C "$MD" OUT="$O" $GH > /dev/null || { echo "【红】xc_key：生成头 ${GH} 生成失败" >&2; exit 1; }
# SPIRV-Cross 目标文件按其源码内容 + 编译器 + 参数缓存（很少变；spirv_msl.cpp 一支约 20 秒，是这里的关键路径）
SK=$({ cat "$SP"/*; clang --version | head -1; echo "$SD $MV $MS"; cat "$H/xc_key.sh"; } | shasum -a 256 | cut -c1-32); SC=$C/spvc-$SK
if [ -d "$SC" ]; then cp -c "$SC"/*.o "$O/spvc/"; else
  for f in "$SP"/spirv_*.cpp; do (cd "$O/spvc" && clang++ $MS -ffile-prefix-map="$S"/= -ffile-prefix-map="$T"/= -std=c++17 -O2 -fvisibility=hidden -mmacosx-version-min=$MV $SD -c "$f" 2> /dev/null) & done; fi
# 直连翻译段（颜色出口 / 加固 / 溢出 / 曲面翻译 …）在直连翻译库 libdsx（graphics/dsx，11-08 拆出）：按它自己 Makefile 的 DSX_CFLAGS 编，与渲染器目标文件一起进 gal_xc
for f in "$MD"/gal_*.m; do (cd "$O/gal" && clang $MS -ffile-prefix-map="$S"/= -ffile-prefix-map="$T"/= $OF -fvisibility=hidden -I"$SP" -c "$f" 2> /dev/null) & done
for f in "$DD"/*.c; do (cd "$O/gal" && clang $MS -ffile-prefix-map="$S"/= -ffile-prefix-map="$T"/= $DF -mmacosx-version-min=$MV -fvisibility=hidden -I"$SP" -c "$f" 2> /dev/null) & done; wait
[ "$(ls "$O/spvc"/*.o 2> /dev/null | wc -l)" = "$(ls "$SP"/spirv_*.cpp | wc -l)" ] || { echo "【红】xc_key：SPIRV-Cross 有编不过的" >&2; exit 1; }
[ -d "$SC" ] || { mkdir -p "$SC.$$" && cp -c "$O"/spvc/*.o "$SC.$$/" && mv "$SC.$$" "$SC" 2> /dev/null || rm -rf "$SC.$$"; }
[ "$(ls "$O/gal"/*.o 2> /dev/null | wc -l)" = "$(ls "$MD"/gal_*.m "$DD"/*.c | wc -l)" ] || { echo "【红】xc_key：渲染器源码有编不过的" >&2; exit 1; }
python3 "$H/xc_unroot.py" "$O"/gal/*.o || exit 1
clang $MS -ffile-prefix-map="$S"/= -ffile-prefix-map="$T"/= -O1 -mmacosx-version-min=$MV -c "$MD/tools/gal_xc.c" -o "$O/gal_xc.o" 2> /dev/null \
  && clang $MS -mmacosx-version-min=$MV -o "$O/gal_xc" "$O/gal_xc.o" $(ls "$O"/gal/*.o | LC_ALL=C sort) $(ls "$O"/spvc/*.o | LC_ALL=C sort) -lc++ -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -Wl,-dead_strip -Wl,-S -Wl,-x 2> /dev/null \
  || { echo "【红】xc_key：gal_xc 静态链接失败" >&2; exit 1; }
# 编译行带 -ffile-prefix-map（源码树 ${S} 与临时目录 ${T}）：源码 / 生成头的路径会进目标文件，各机临时目录长度不同、排布随之变（同机每次长度一样，所以本机重复算看着稳定）
# 链接顺序按字节序显式排（10-26 22:5x 实证：同一批 .o，bash 通配在本机 macOS 26.4 排成 spirv_cross.o spirv_cross_c.o …、gate-host macOS 27.0 排成
#   spirv_cross_c.o spirv_cross_parsed_ir.o spirv_cross.o …，两边 LC_COLLATE 都是 C；链接顺序一变，排布与弱符号归属跟着变，键就不同、远端出包的着色器段全判重做）
# 编译参数里的输出目录（-I$(OUT)/gen）随临时目录变：换成占位符再进键
K=$({ shasum -a 256 < "$O/gal_xc"; echo "${OF//$O/<OUT>}|$SD|$DF"; } | shasum -a 256 | cut -c1-16)
[ -n "$M" ] && { echo "$K" > "$C/$M.$$" && mv "$C/$M.$$" "$C/$M"; }
echo "$K"
