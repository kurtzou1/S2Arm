#!/bin/bash
# libopus（Xiph 参考实现，BSD）静态库：给 Horizon 硬件 Opus 解码服务（hwopus）用，替掉 Concentus 托管实现（每包分配 18–36 KB，iOS 上 gen0 回收是阻塞式的）。
# 用法：bash services/opus/build.sh [osx-arm64|osx-x64|ios-arm64] → 最后一行输出 libs2a_opus.a 路径（libopus + C 垫片 s2a_opus.c）。按版本 / 垫片哈希缓存在 ~/.s2arm/run/s2arm/cache/opus，命中秒过。
# S2A_OPUS_SYSTEM=1（仅 osx-*）：单流/多流、8–48 kHz 全部走系统 AudioToolbox（s2a_opus_apple.c），宿主静态库不再包含 libopus；
#   单测动态库仍载入 libopus（只作参考解码器 + 测试编码器），不进宿主 / App。
# 源码按固定版本 + sha256（与 downloads.xiph.org/releases/opus/SHA256SUMS.txt 一致）取，不进仓库；源码包按 sha256 缓存在 ${S2A_BUILD_CACHE:-~/.cache/s2arm-build}/sources/（android/tools/fetch_source.sh）。做法同 services/vpx/build.sh。
# 版本取当前稳定版 1.6.1（2026-01）：Concentus 2.2.2 移植自 libopus 1.1.2 定点版（2015），旧版没有 1.2 之后的 NEON 优化与解码修正；
#   真 Switch 用的 libopus 版本不知道（没有公开来源），解码器输出跨版本本来就不逐位相同（RFC 6716 / 8251 只规定误差上限），不为逐位对齐旧移植退回老版本
set -euo pipefail
RID=${1:-osx-arm64}
VER=1.6.1; SHA=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/android/tools/fetch_source.sh"   # 源码包按 sha256 进本机共享缓存（S2A_BUILD_CACHE/sources），命中不联网；下载按进展判挂死
# 整机级缓存：键 = 本脚本内容（含版本与 sha256）+ 平台，各工作树共用
C=${S2A_OPUS_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/opus}; mkdir -p "$C"
TCE=$ROOT/tools/toolchain.env; MMAC=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$TCE"); MIOS=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$TCE")   # 产物下限只取统一工具链那两行
[ -n "$MMAC" ] && [ -n "$MIOS" ] || { echo "🔴 $(basename "$(dirname "$0")")：$TCE 里没有部署目标" >&2; exit 1; }
OUT=$C/$RID-$VER-$( { cat "$0"; echo "$MMAC $MIOS"; } | shasum -a 256 | cut -c1-12)   # 下限进键：改了就重编
# 几棵树同时编同一键时排队（.tmp 名字不撞）
until mkdir "$C/.lock" 2> /dev/null; do p=$(cat "$C/.lock/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock"; sleep 0.5; done
echo $$ > "$C/.lock/pid"; trap 'rm -rf "$C/.lock"' EXIT
ARCH=arm64; HOST=aarch64-apple-darwin; EXTRA=()
case $RID in
  osx-arm64) MIN=-mmacosx-version-min=$MMAC; SDK=macosx ;;
  osx-x64) ARCH=x86_64; HOST=x86_64-apple-darwin; EXTRA=(--disable-asm --disable-intrinsics); MIN=-mmacosx-version-min=$MMAC; SDK=macosx ;;
  ios-arm64) MIN=-miphoneos-version-min=$MIOS; SDK=iphoneos ;;
  *) echo "🔴 opus：不认识的平台 $RID" >&2; exit 1 ;;
esac
SYS=${S2A_OPUS_SYSTEM:-0}
[[ $RID = osx-* ]] || SYS=0   # 系统后端只接 macOS；iOS 一律 libopus
CC="xcrun --sdk $SDK clang -arch $ARCH $MIN"
# 本机缓存跟编译器走（审计 #1534 P1-107）：构建键不含编译器（发版机与玩家机的预编库按它认，不能带本机版本），本机缓存目录名另带 clang 版本行的哈希，toolchain.txt 记原文备查
TCV=$($CC --version 2> /dev/null | sed -n 1p) || TCV=
[ -n "$TCV" ] || { echo "🔴 opus：取不到 $SDK clang 的版本行（xcrun 失败），不出库" >&2; exit 1; }
# 编译器进本机缓存目录名（11-05 服务层单测偶发 rc=134）：原先同一目录记 toolchain.txt、版本行不同就 rm -rf 整个目录重编；本机两套 Xcode
#   （门禁经 tools/toolchain.sh 用 S2A_DEVELOPER_DIR 那套、直接跑用 xcode-select 那套）版本行不同，轮流互删，把别的树单测正要 dlopen 的动态库删掉。
#   按编译器分目录后已出好的目录不再被改写；构建键（--key / 预编库）仍不含编译器
OUT=$OUT-$(printf '%s' "$TCV" | shasum -a 256 | cut -c1-8)
if [ ! -s "$OUT/libopus.a" ]; then
  TGZ=$(s2a_source_fetch "opus-$VER.tar.gz" "https://downloads.xiph.org/releases/opus/opus-$VER.tar.gz" "$SHA") || { echo "🔴 opus：取不到源码包" >&2; exit 1; }
  W=$OUT.tmp; rm -rf "$W"; mkdir -p "$W/src" "$W/obj"
  tar xzf "$TGZ" -C "$W/src" --strip-components 1
  # 浮点版（缺省）、不带深度学习 / 扩展（DRED / 深度 PLC / OSCE / QEXT 缺省关）；arm64 苹果平台 NEON 恒在，免运行时探测
  # 缓存在带空格目录（启动器：~/Library/Application Support）时 autoconf 报「unsafe srcdir」、make 拆路径：configure / make 走无空格别名（tools/nospace.sh）
  source "$ROOT/tools/nospace.sh"; WN=$(s2a_nospace "$W")
  ( cd "$WN/obj" && CC="$CC" CFLAGS="-O2 -fPIC -ffile-prefix-map=$WN/src=opus" "$WN/src/configure" --host="$HOST" ${EXTRA[@]+"${EXTRA[@]}"} --enable-static --disable-shared \
      --disable-doc --disable-extra-programs --disable-rtcd --disable-dependency-tracking \
      > "$W/configure.log" 2>&1 && make -j8 > "$W/make.log" 2>&1 ) || { echo "🔴 opus：$RID 构建失败（$W/*.log）" >&2; tail -5 "$W"/*.log >&2; exit 1; }
  mkdir -p "$W/out/include"; cp "$W/obj/.libs/libopus.a" "$W/out/"; cp "$W/src/include/"*.h "$W/out/include/"
  printf '%s\n' "$TCV" > "$W/out/toolchain.txt"
  rm -rf "$OUT"; mv "$W/out" "$OUT"; rm -rf "$W"
fi
# 垫片与 libopus 合成一个静态库（DirectPInvoke s2a_opus 链它）；S2A_OPUS_SYSTEM=1 时静态库只含系统垫片
K=$( { cat "$ROOT/services/opus/s2a_opus.c" "$ROOT/services/opus/s2a_opus_apple.c" "$ROOT/services/opus/s2a_opus_test.c" "$0"; printf 'system=%s\n' "$SYS"; } | shasum -a 256 | cut -c1-12)
L=$OUT/s2a-$K/libs2a_opus.a
if [ ! -s "$L" ]; then
  mkdir -p "$OUT/s2a-$K.tmp"
  SHIM_CFLAGS=(-O2 -fPIC -I"$OUT/include")
  APPLE_OBJ=
  if [ "$SYS" = 1 ]; then
    SHIM_CFLAGS+=(-DS2A_OPUS_SYSTEM=1)
    $CC "${SHIM_CFLAGS[@]}" -c "$ROOT/services/opus/s2a_opus_apple.c" -o "$OUT/s2a-$K.tmp/s2a_opus_apple.o"
    APPLE_OBJ=$OUT/s2a-$K.tmp/s2a_opus_apple.o
  fi
  $CC "${SHIM_CFLAGS[@]}" -c "$ROOT/services/opus/s2a_opus.c" -o "$OUT/s2a-$K.tmp/s2a_opus.o"
  if [ "$SYS" = 1 ]; then
    # 全量系统解码：宿主静态库只含垫片，libopus 不进宿主（测试动态库另外整份载入，见下）
    libtool -static -o "$OUT/s2a-$K.tmp/libs2a_opus.a" "$OUT/s2a-$K.tmp/s2a_opus.o" "$APPLE_OBJ" 2>/dev/null
  else
    libtool -static -o "$OUT/s2a-$K.tmp/libs2a_opus.a" "$OUT/libopus.a" "$OUT/s2a-$K.tmp/s2a_opus.o" 2>/dev/null
  fi
  # Mac 另出一份动态库：服务层单测（JIT 跑，不静态链）经它调同一套代码；整份 libopus 载入（单测直调参考解码器对拍、用编码器出测试包），
  #   外加只进动态库的单测编码垫片 s2a_opus_test.c（编码器设置走变参 ctl，P/Invoke 不能直调）
  if [[ $RID = osx-* ]]; then
    $CC "${SHIM_CFLAGS[@]}" -c "$ROOT/services/opus/s2a_opus_test.c" -o "$OUT/s2a-$K.tmp/s2a_opus_test.o"
    DYLIB_OBJS=("$OUT/s2a-$K.tmp/s2a_opus.o" "$OUT/s2a-$K.tmp/s2a_opus_test.o")
    FRAMEWORKS=()
    if [ -n "$APPLE_OBJ" ]; then
      DYLIB_OBJS+=("$APPLE_OBJ")
      FRAMEWORKS=(-framework AudioToolbox -framework CoreFoundation)
    fi
    $CC -dynamiclib -o "$OUT/s2a-$K.tmp/libs2a_opus.dylib" "${DYLIB_OBJS[@]}" -Wl,-force_load,"$OUT/libopus.a" ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}
  fi
  rm -rf "$OUT/s2a-$K"; mv "$OUT/s2a-$K.tmp" "$OUT/s2a-$K"
fi
touch "$OUT"   # 取用即更新目录时间：tools/gc.sh 每平台留 2 份、30 分钟内动过的不删，在用的这份不被别的键挤掉
echo "$L"
