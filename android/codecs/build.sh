#!/usr/bin/env bash
# Fixed-source Opus / VP8 / H.264 static archives. Normal builds are offline.
# Explicit preparation: --prepare-sources [directory containing the pinned tarballs].
# Stdout of a normal build contains only the three archive paths for link.txt.
set -euo pipefail
avc_tag=android-16.0.0_r4
avc_commit=d380d04a78c6c08702e36aca86d0fd4baee390f9
# Historical verified Gitiles archive; retained only to find pre-existing caches.
avc_sha=c0af9b9967854a39c8412e47c6dfbd2b08edd63d33d529707142dd8c04bae08d
# Canonical paths, file bytes, types and modes from that archive. Gitiles tar
# mtimes and gzip headers can vary for the same commit and are not identity.
avc_content_sha=8901129497b2ba38ec2c52c2667d478626d9b554dd87603ffc5fd5be0a84651a
api=34
repo_dir=$(cd "$(dirname "$0")/../.." && pwd -P)
out=$repo_dir/build/android-cs
if [ -z "${S2A_BUILD_CACHE:-}" ] && [ -z "${HOME:-}" ]; then
    echo '【红】codec 缓存需要 HOME 或显式设置 S2A_BUILD_CACHE' >&2
    exit 1
fi
cache_root=${S2A_BUILD_CACHE:-$HOME/.cache/s2arm-build}
licenses=$out/assets/licenses
source "$repo_dir/android/tools/ndk_toolchain.sh"
source "$repo_dir/android/tools/fetch_source.sh"
source "$repo_dir/android/codecs/cache.sh"
source "$repo_dir/android/codecs/avc-build.sh"
source "$repo_dir/android/codecs/opus-build.sh"
source "$repo_dir/android/codecs/vpx-build.sh"

pin() {
    local line
    line=$(grep -m1 -E '^VER=[0-9.]+; SHA=[0-9a-f]{64}$' "$repo_dir/services/$1/build.sh") \
        || { echo "no VER=...; SHA=... line in services/$1/build.sh" >&2; exit 1; }
    eval "$line"
    echo "$VER $SHA"
}
read -r opus_ver opus_sha < <(pin opus)
read -r vpx_ver vpx_sha < <(pin vpx)
case ${1:-} in
--prepare-sources)
    codec_prepare "opus-$opus_ver.tar.gz" "https://downloads.xiph.org/releases/opus/opus-$opus_ver.tar.gz" "$opus_sha" "${2:-}"
    codec_prepare "libvpx-$vpx_ver.tar.gz" "https://github.com/webmproject/libvpx/archive/refs/tags/v$vpx_ver.tar.gz" "$vpx_sha" "${2:-}"
    avc_prepare "${2:-}"
    exit ;;
--check-sources)
    codec_source "$opus_sha" > /dev/null
    codec_source "$vpx_sha" > /dev/null
    avc_source "${S2A_AVC_ARCHIVE:-}" > /dev/null
    exit ;;
''|--avc-only|--cache-keys) ;;
*) echo 'Usage: build.sh [--prepare-sources [local-directory]|--check-sources|--avc-only|--cache-keys]' >&2; exit 2 ;;
esac
q19_avc=0
if [ "${1:-}" = --avc-only ] && [ -n "${S2A_Q19_NDK:-}" ]; then
    ndk=$S2A_Q19_NDK  # Q19 already selected this pinned NDK, including standalone cask installs.
    q19_avc=1
else
    ndk=${ANDROID_HOME:?ANDROID_HOME is required for codec compilation}/ndk/$S2A_ANDROID_NDK
fi
# prebuilt/<host> 目录按宿主实选（darwin-arm64 / darwin-x86_64 / linux-x86_64），不写死。
host_tag=$(s2a_ndk_prebuilt_tag "$ndk") || { echo "NDK $ndk 没有本宿主可用的 llvm prebuilt 目录" >&2; exit 1; }
export PATH=$ndk/toolchains/llvm/prebuilt/$host_tag/bin:$PATH
cc="aarch64-linux-android$api-clang"
codec_jobs=${S2A_CODEC_JOBS:-2}
mkdir -p "$cache_root/codecs" "$licenses"
if [ "${1:-}" = --avc-only ]; then build_avc; exit; fi
init_codec_toolchain
if [ "${1:-}" = --cache-keys ]; then
    printf 'opus %s\n' "$(codec_recipe_key opus "$opus_sha" "$repo_dir/android/codecs/opus-build.sh")"
    printf 'vpx %s\n' "$(codec_recipe_key vpx "$vpx_sha" "$repo_dir/android/codecs/vpx-build.sh" "$repo_dir/services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch")"
    printf 'avc %s\n' "$(avc_cache_key)"
    exit
fi
# Fail before any compilation when local source preparation is incomplete.
codec_source "$opus_sha" > /dev/null
codec_source "$vpx_sha" > /dev/null
avc_source "${S2A_AVC_ARCHIVE:-}" > /dev/null

build_opus
build_vpx
build_avc
