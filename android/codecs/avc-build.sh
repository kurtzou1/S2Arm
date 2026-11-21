avc_verify() {
    python3 "$repo_dir/android/codecs/avc_source.py" "$1" "$avc_content_sha"
}

avc_source() {
    local path=${1:-} canonical legacy
    canonical=$(codec_source_path "$avc_content_sha")
    legacy=$(codec_source_path "$avc_sha")
    if [ -z "$path" ]; then
        if [ -e "$canonical" ]; then path=$canonical; else path=$legacy; fi
    fi
    [ -f "$path" ] || { echo "Missing pinned libavc source; explicitly run codecs/build.sh --prepare-sources <local-directory>" >&2; return 1; }
    avc_verify "$path" || return 1
    printf '%s\n' "$path"
}

avc_prepare() (
    set -euo pipefail
    local from=${1:-} path legacy work name
    path=$(codec_source_path "$avc_content_sha")
    legacy=$(codec_source_path "$avc_sha")
    if [ -e "$path" ] || [ -e "$legacy" ]; then avc_source > /dev/null; return; fi
    mkdir -p "$(dirname "$path")"
    work=$(mktemp "${path}.prepare.XXXXXX")
    trap 'rm -f "$work"' EXIT
    name="libavc-$avc_commit.tar.gz"
    if [ -n "$from" ]; then
        [ -f "$from/$name" ] || { echo "Missing local codec source $from/$name" >&2; return 1; }
        cp "$from/$name" "$work"
    else
        # Gitiles 包字节不固定，不进按 SHA 的共享缓存；只用共用下载（进展看守 + 整体上限），按内容校验。
        s2a_download "https://android.googlesource.com/platform/external/libavc/+archive/$avc_commit.tar.gz" "$work"
    fi
    avc_verify "$work"
    mv "$work" "$path"
)

avc_cache_key() {
    { printf '%s\n' "$avc_tag" "$avc_commit" "$avc_content_sha" "$toolchain_key" 'Release PIC arm64-v8a android-34 aarch64 tests=OFF mvc=OFF svc=OFF';
      "${CMAKE:-$ANDROID_HOME/cmake/$S2A_ANDROID_CMAKE/bin/cmake}" --version;
      # The shared helper layer is part of the recipe: cache.sh owns toolchain/
      # publish semantics and build.sh owns source verification/dispatch.
      cat "$repo_dir/android/codecs/avc-build.sh" \
          "$repo_dir/android/codecs/cache.sh" \
          "$repo_dir/android/codecs/build.sh" \
          "$repo_dir/android/codecs/avc_source.py" \
          "$repo_dir/android/codecs/s2a_avc.c" \
          "$repo_dir/android/codecs/s2a_avc.h";
    } | s2a_sha256 | cut -d' ' -f1
}

# Sourced by build.sh. Compilation consumes verified local source only.
build_avc() {
    local cmake_bin=${CMAKE:-$ANDROID_HOME/cmake/$S2A_ANDROID_CMAKE/bin/cmake} jobs=${S2A_CODEC_JOBS:-2} key target work archive
    local cmake_version
    local shim=$repo_dir/android/codecs/s2a_avc.c
    # The shim is mandatory: a bare libavcdec.a would silently lose every
    # s2a_avc_* entry point and only fail later at runtime.
    [ -f "$shim" ] || { echo 'missing libavc shim source s2a_avc.c; refusing to publish a bare libavcdec.a' >&2; return 1; }
    cmake_version=$("$cmake_bin" --version | head -n1)
    # Android SDK pinned CMake reports a vendor git suffix (<ver>-g<hash>).
    if [ "${q19_avc:-0}" = 1 ]; then
        [[ "$cmake_version" =~ ^cmake\ version\ ([0-9]+)\.([0-9]+)\.([0-9]+)(-g[0-9a-f]+)?$ ]] &&
            { [ "${BASH_REMATCH[1]}" -gt 3 ] ||
              { [ "${BASH_REMATCH[1]}" -eq 3 ] && { [ "${BASH_REMATCH[2]}" -gt 31 ] ||
                { [ "${BASH_REMATCH[2]}" -eq 31 ] && [ "${BASH_REMATCH[3]}" -ge 6 ]; }; }; }; } ||
            { echo "Q19 libavc requires CMake >=${S2A_ANDROID_CMAKE}" >&2; return 1; }
    else
        [[ "$cmake_version" =~ ^cmake\ version\ ${S2A_ANDROID_CMAKE//./\.}(-g[0-9a-f]+)?$ ]] || { echo "libavc requires CMake $S2A_ANDROID_CMAKE" >&2; return 1; }
    fi
    grep -q '^Pkg.Revision = '$S2A_ANDROID_NDK'$' "$ndk/source.properties" || { echo "libavc requires NDK $S2A_ANDROID_NDK" >&2; return 1; }
    local flags='Release PIC arm64-v8a android-34 aarch64 tests=OFF mvc=OFF svc=OFF'
    archive=$(avc_source "${S2A_AVC_ARCHIVE:-}") || return 1
    init_codec_toolchain
    key=$(avc_cache_key)
    target=$cache_root/codecs/avc-$key
    mkdir -p "$cache_root/codecs" "$licenses"
    if ! codec_cached "$target"; then
        work=$(mktemp -d "$cache_root/codecs/avc-build.XXXXXX")
        # 函数返回后 EXIT trap 才跑，local work 已出作用域：set -u 下会报 unbound，
        # 把真正的红因（libavc 构建失败）盖掉（10-29 #919 实测）。
        trap 'rm -rf "${work:-}"' EXIT
        mkdir "$work/src" "$work/result"
        # Verify the private copy that will actually be extracted, even if the
        # source cache is changed concurrently after the first verification.
        cp "$archive" "$work/source.tar.gz"
        avc_verify "$work/source.tar.gz" || return 1
        tar -xzf "$work/source.tar.gz" -C "$work/src"
        "$cmake_bin" -S "$work/src" -B "$work/obj" \
            -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-34 \
            -DSYSTEM_NAME=Android -DSYSTEM_PROCESSOR=aarch64 \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DENABLE_TESTS=OFF -DENABLE_MVC=OFF -DENABLE_SVC=OFF >&2
        "$cmake_bin" --build "$work/obj" --target libavcdec --parallel "$jobs" >&2
        "$cc" -std=c11 -O2 -fPIC -I"$work/src/common" -I"$work/src/decoder" \
            -c "$shim" -o "$work/shim.o" || return 1
        llvm-ar qcL "$work/result/libs2a_avc.a" "$work/obj/libavcdec.a" "$work/shim.o" || return 1
        llvm-ranlib "$work/result/libs2a_avc.a"
        cp "$work/src/LICENSE" "$work/src/NOTICE" "$work/result/"
        printf 'AOSP libavc %s\ncommit=%s\ncontent_sha256=%s\narchive_sha256=%s\nbuild_key=%s\n' \
            "$avc_tag" "$avc_commit" "$avc_content_sha" "$(s2a_sha256 "$work/source.tar.gz" | cut -d' ' -f1)" "$key" > "$work/result/SOURCE.txt"
        codec_publish "$work/result" "$target"
        rm -rf "$work"
        trap - EXIT
    fi
    cp "$target/LICENSE" "$licenses/libavc-LICENSE.txt"
    cp "$target/NOTICE" "$licenses/libavc-NOTICE.txt"
    cp "$target/SOURCE.txt" "$licenses/libavc-SOURCE.txt"
    echo "$target/libs2a_avc.a"
}
