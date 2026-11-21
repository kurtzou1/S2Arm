#!/bin/bash
# glslang（Khronos 官方 GLSL 前端，BSD-3 / Apache-2.0 等，见源码包 LICENSE.txt）静态库：给直连 GL 层运行时兜底（graphics/nvn/gfx/gl/gl_xlate.c → libglx：库里没有的 GLSL 首遇时 GLSL → SPIR-V）用。
# 用法：bash graphics/third_party/glslang/build.sh [osx-arm64|ios-arm64] → 最后一行输出 libs2a_glslang.a 路径（libglslang + 缺省资源上限合成一个库）；头文件在同目录 include/（#include <glslang/Include/glslang_c_interface.h>）。
# 官方 tag 原样构建、不维护裁剪分支：16.6.0（与出包离线链 Homebrew glslangValidator 同版本），ENABLE_HLSL=OFF、ENABLE_OPT=OFF（不带 SPIRV-Tools）、不出命令行程序 / 单测。
# 源码包按固定版本 + sha256 取（GitHub 官方 tag 归档），按 sha256 缓存在 ${S2A_BUILD_CACHE:-~/.cache/s2arm-build}/sources/（android/tools/fetch_source.sh，同 services/opus|vpx/build.sh）；
#   构建产物按「本脚本内容 + 部署下限 + 平台」缓存在 ~/.s2arm/run/s2arm/cache/glslang，各工作树共用，命中秒过。
# 安卓不用：安卓 GL 款运行时由系统驱动编 GLSL（graphics/tools/direct/direct_lib.py 安卓分支不出 GL 库），GL 层（graphics/nvn/gfx/gl/*.m）只在苹果平台编。
set -euo pipefail
PLAT=${1:-osx-arm64}
VER=16.6.0; SHA=9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
source "$ROOT/android/tools/fetch_source.sh"
C=${S2A_GLSLANG_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/glslang}; mkdir -p "$C"
TCE=$ROOT/tools/toolchain.env; MMAC=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$TCE"); MIOS=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$TCE"); MTVOS=$(sed -n 's/^TVOS_DEPLOYMENT_TARGET=//p' "$TCE")
[ -n "$MMAC" ] && [ -n "$MIOS" ] || { echo "🔴 glslang：$TCE 里没有部署目标" >&2; exit 1; }
case $PLAT in
  osx-arm64) SDK=macosx; SYS=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MMAC") ;;
  ios-arm64) SDK=iphoneos; SYS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIOS") ;;
  tvos-arm64) SDK=appletvos; SYS=(-DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_DEPLOYMENT_TARGET="$MTVOS") ;;   # Apple TV（11-15）
  *) echo "🔴 glslang：不认识的平台 ${PLAT}（osx-arm64 / ios-arm64）" >&2; exit 1 ;;
esac
OUT=$C/$PLAT-$VER-$( { cat "$0"; echo "$MMAC $MIOS"; } | shasum -a 256 | cut -c1-12)
L=$OUT/libs2a_glslang.a
[ -s "$L" ] && { echo "$L"; exit 0; }
for t in cmake ninja; do command -v $t > /dev/null || { echo "🔴 glslang：要 ${t}（brew install cmake ninja）" >&2; exit 1; }; done
# 几棵树同时编同一键时排队
until mkdir "$C/.lock" 2> /dev/null; do p=$(cat "$C/.lock/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock"; sleep 0.5; done
echo $$ > "$C/.lock/pid"; trap 'rm -rf "$C/.lock"' EXIT
if [ ! -s "$L" ]; then
  TGZ=$(s2a_source_fetch "glslang-$VER.tar.gz" "https://github.com/KhronosGroup/glslang/archive/refs/tags/$VER.tar.gz" "$SHA") || { echo "🔴 glslang：取不到源码包" >&2; exit 1; }
  W=$OUT.tmp; rm -rf "$W"; mkdir -p "$W/src" "$W/out/include/glslang"
  tar xzf "$TGZ" -C "$W/src" --strip-components 1
  source "$ROOT/tools/nospace.sh"; WN=$(s2a_nospace "$W")   # 缓存在带空格目录（启动器）时 cmake / ninja 拆路径
  FL="-Os -ffunction-sections -fdata-sections -ffile-prefix-map=$WN/src=glslang"
  cmake -S "$WN/src" -B "$WN/build" -G Ninja -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF -DENABLE_HLSL=OFF -DENABLE_OPT=OFF -DENABLE_GLSLANG_BINARIES=OFF \
      -DGLSLANG_TESTS=OFF -DBUILD_EXTERNAL=OFF -DENABLE_PCH=OFF -DGLSLANG_ENABLE_INSTALL=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_SYSROOT="$(xcrun --sdk $SDK --show-sdk-path)" "${SYS[@]}" "-DCMAKE_CXX_FLAGS=$FL" "-DCMAKE_C_FLAGS=$FL" > "$W/cmake.log" 2>&1 \
    && cmake --build "$WN/build" -j "${J:-8}" > "$W/build.log" 2>&1 || { echo "🔴 glslang：$PLAT 构建失败（$W/*.log）" >&2; tail -5 "$W"/*.log >&2; exit 1; }
  libtool -static -o "$W/out/libs2a_glslang.a" "$W/build/glslang/libglslang.a" "$W/build/glslang/libglslang-default-resource-limits.a" 2> /dev/null
  # 头文件：C 接口（glslang/Include/glslang_c_interface.h 及其引的类型 / 可见性头）、缺省资源上限（glslang/Public/resource_limits_c.h）、生成的 build_info.h
  mkdir -p "$W/out/include/glslang/Include" "$W/out/include/glslang/Public"
  cp "$W/src/glslang/Include/"*.h "$W/out/include/glslang/Include/"; cp "$W/src/glslang/Public/"*.h "$W/out/include/glslang/Public/"
  cp "$W/build/include/glslang/build_info.h" "$W/out/include/glslang/"
  cp "$W/src/LICENSE.txt" "$W/out/"
  rm -rf "$OUT"; mv "$W/out" "$OUT"; rm -rf "$W"
fi
echo "$L"
