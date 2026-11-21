#!/usr/bin/env bash
# OpenSSL 3 for the app, run by docker/build.sh or host/build.sh. .NET's crypto on
# linux-bionic (RandomNumberGenerator, hashes, AES) goes through its OpenSSL shim, which
# calls abort() when no libssl is loadable, and Android gives apps none. The shim's Android
# path dlopens the unversioned "libssl.so", which is what OpenSSL's android-arm64 target
# builds. The source is SHA-256 checked (GitHub release and openssl.org agree), built once
# per version / NDK / API level into S2A_BUILD_CACHE (default $HOME/.cache/s2arm-build),
# then copied into the APK's jniLibs.
set -euo pipefail
version=3.5.9   # LTS; .NET prefers 3.x and takes 4.x only as a fallback
sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
api=34          # app minSdk
repo_dir=$(cd "$(dirname "$0")/../.." && pwd -P)
. "$repo_dir/android/tools/versions.sh"
ndk=${ANDROID_HOME:?ANDROID_HOME is required for OpenSSL compilation}/ndk/$S2A_ANDROID_NDK
out=$repo_dir/build/android-cs/jniLibs/arm64-v8a
cache_root=${S2A_BUILD_CACHE:-$HOME/.cache/s2arm-build}
. "$repo_dir/android/tools/ndk_toolchain.sh"
. "$repo_dir/android/tools/fetch_source.sh"
# buildinf.h 的 "built on" 时刻固定为常量（2025-10-31 00:00:00 UTC），两路 / 重跑字节一致。
export SOURCE_DATE_EPOCH=1761868800
# 缓存键含配方摘要与固定 NDK 版本：改 Configure/CFLAGS 或换 NDK 必须换键，旧缓存不得复用。
recipe_sha=$({ cat "$repo_dir/android/openssl/build.sh" \
                   "$repo_dir/android/tools/ndk_toolchain.sh"; } \
             | s2a_sha256 | cut -d' ' -f1)
cache=$cache_root/openssl/$version-ndk$S2A_ANDROID_NDK-api$api-$recipe_sha
if [ ! -s "$cache/libssl.so" ] || [ ! -s "$cache/libcrypto.so" ] || [ ! -s "$cache/LICENSE.txt" ]; then
    mkdir -p "$cache_root/openssl"
    work=$(mktemp -d "$cache_root/openssl/build.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    # 共用下载 + 按 SHA 的本机共享缓存（命中不联网；下载按进展判挂死），返回的文件已核过 sha256。
    src=$(s2a_source_fetch "openssl-$version.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz" "$sha256")
    tar -xzf "$src" -C "$work"
    (
        cd "$work/openssl-$version"
        export ANDROID_NDK_ROOT=$ndk
        # 宿主不同（Linux/macOS）时 llvm/host prebuilt 目录名不同；统一由 tools/ndk_toolchain.sh 解析。
        . "$repo_dir/android/tools/ndk_toolchain.sh"
        llvm_tag=$(s2a_ndk_prebuilt_tag "$ndk") || { echo "NDK $ndk 没有可用的 llvm prebuilt 目录" >&2; exit 1; }
        export PATH=$ndk/toolchains/llvm/prebuilt/$llvm_tag/bin:$(s2a_ndk_host_bin "$ndk" || true):$PATH
        # Default algorithms stay: the shim aborts when a symbol it requires is missing.
        ./Configure android-arm64 -D__ANDROID_API__=$api shared no-module no-apps no-tests no-docs \
            -Wl,-z,max-page-size=16384 > "$work/configure.log"
        make -j"$(s2a_jobs)" build_libs > "$work/make.log" 2>&1 || { tail -20 "$work/make.log"; exit 1; }
        mkdir -p "$cache.tmp"
        for lib in libssl.so libcrypto.so; do llvm-strip --strip-unneeded -o "$cache.tmp/$lib" "$lib"; done
        cp LICENSE.txt "$cache.tmp/"   # Apache-2.0: the license text travels with the binaries
    )
    rm -rf "$cache" && mv "$cache.tmp" "$cache"
fi
mkdir -p "$out" "$repo_dir/build/android-cs/assets/licenses"
cp "$cache/libssl.so" "$cache/libcrypto.so" "$out/"
cp "$cache/LICENSE.txt" "$repo_dir/build/android-cs/assets/licenses/openssl-LICENSE.txt"
echo "OpenSSL $version: $out/libssl.so, libcrypto.so"
