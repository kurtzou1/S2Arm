#!/usr/bin/env bash
# 构建 vpxbench（测量工具，不进产品）：链发版用的安卓 libvpx 配方产物（android/codecs/build.sh：VP8 + VP9 解码器 + S2Arm 补丁，
# 垫片 s2a_vp8.c / s2a_vp9.c 已合在 libs2a_vpx.a 里），测的就是要上线的那份库。
# 用法：ANDROID_HOME=... build.sh [out_dir]   输出 <out_dir>/vpxbench（缺省 build/vpxbench）
set -euo pipefail
api=34
repo_dir=$(cd "$(dirname "$0")/../../.." && pwd -P)
out=${1:-$repo_dir/build/vpxbench}
source "$repo_dir/android/tools/versions.sh"
source "$repo_dir/android/tools/ndk_toolchain.sh"
ndk=${ANDROID_HOME:?ANDROID_HOME is required}/ndk/$S2A_ANDROID_NDK
host_tag=$(s2a_ndk_prebuilt_tag "$ndk")
cc="$ndk/toolchains/llvm/prebuilt/$host_tag/bin/aarch64-linux-android$api-clang"
shim=$(bash "$repo_dir/android/codecs/build.sh" | grep '/libs2a_vpx\.a$')
[ -f "$shim" ] || { echo "vpxbench: android/codecs/build.sh gave no libs2a_vpx.a" >&2; exit 1; }
include=$(dirname "$(dirname "$shim")")/include
mkdir -p "$out"
"$cc" -std=c11 -O2 -I"$include" -o "$out/vpxbench" \
    "$repo_dir/android/codecs/vpxbench/vpxbench.c" "$repo_dir/android/codecs/vpxbench/hdr.c" "$shim" -lm
echo "$out/vpxbench"
