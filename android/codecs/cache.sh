init_codec_toolchain() {
    # Production recipes set their own flags; ambient host flags are not inputs.
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
    grep -q '^Pkg.Revision = '$S2A_ANDROID_NDK'$' "$ndk/source.properties" || { echo "codecs require NDK $S2A_ANDROID_NDK" >&2; return 1; }
    toolchain_key=$({ cat "$ndk/source.properties"; "$cc" --version; printf '%s\n' 'arm64-v8a android-34 PIC'; } | s2a_sha256 | cut -d' ' -f1)
}

# Shared offline source/cache operations. No build path performs a download.
codec_source_path() { printf '%s/codecs/sources/%s.tar.gz\n' "$cache_root" "$1"; }

codec_source() {
    local sha=$1 path=${2:-}
    [ -n "$path" ] || path=$(codec_source_path "$sha")
    [ -f "$path" ] || { echo "Missing pinned codec source $sha; explicitly run codecs/build.sh --prepare-sources <local-directory>" >&2; return 1; }
    echo "$sha  $path" | s2a_sha256_check - >&2 || return 1
    printf '%s\n' "$path"
}

# Explicit preparation only. A local directory never falls back to the network.
codec_prepare() (
    set -euo pipefail
    local name=$1 url=$2 sha=$3 from=${4:-} path work src
    path=$(codec_source_path "$sha")
    if [ -e "$path" ]; then codec_source "$sha" > /dev/null; return; fi
    mkdir -p "$(dirname "$path")"
    work=$(mktemp "${path}.prepare.XXXXXX")
    trap 'rm -f "$work"' EXIT
    if [ -n "$from" ]; then
        [ -f "$from/$name" ] || { echo "Missing local codec source $from/$name" >&2; return 1; }
        cp "$from/$name" "$work"
    else
        # 共用下载 + 按 SHA 的本机共享缓存（tools/fetch_source.sh，codecs/build.sh 已 source）。
        src=$(s2a_source_fetch "$name" "$url" "$sha")
        cp "$src" "$work"
    fi
    echo "$sha  $work" | s2a_sha256_check - >&2
    mv "$work" "$path"
)

codec_unpack() {
    local archive
    archive=$(codec_source "$1" "${4:-}") || return 1
    mkdir "$2/src"
    if [ "$3" = gitiles ]; then tar -xzf "$archive" -C "$2/src"
    else tar -xzf "$archive" -C "$2/src" --strip-components 1; fi
}

# codec_recipe_key <name> <source sha> <recipe file>...：配方文件按给出顺序进键（vpx 另带 S2Arm 补丁）
codec_recipe_key() {
    { printf '%s\n' "$1" "$2" "$toolchain_key"; cat "${@:3}"; } | s2a_sha256 | cut -d' ' -f1
}

codec_cached() {
    [ -d "$1" ] || return 1
    (cd "$1" && [ -s manifest.sha256 ] && s2a_sha256_check manifest.sha256) >&2 \
        || { echo "Corrupt/incomplete codec artifact cache: $1 (remove this regenerable entry explicitly)" >&2; exit 1; }
}

codec_publish() {
    # Each result is complete before publication. Never remove an in-use entry.
    (cd "$1" && find . -type f ! -name manifest.sha256 -print | LC_ALL=C sort | while IFS= read -r file; do s2a_sha256 "$file"; done > manifest.sha256)
    if [ -e "$2" ]; then
        # 同一 recipe key 的产物已经在缓存里：并行门禁冷建同一个缓存项时，后到的那份
        # 校验并复用已发布的条目（10-29 #919 实测 2 路并发 1 红在 appeared during build）。
        # 本地这份重建的产物丢弃；缓存校验不过就是真损坏，照旧报红。
        codec_cached "$2" || return 1
        rm -rf "$1"
        return 0
    fi
    mv "$1" "$2"
}

# codec_shim <name> <archive> <include> <parent> <source.c>...：C 垫片（可多个，按给出顺序进键）与第三方静态库合成 lib<name>.a
codec_shim() (
    set -euo pipefail
    local name=$1 archive=$2 include=$3 parent=$4 key target work source
    local -a objects=()
    shift 4
    [ "$#" -gt 0 ] || { echo "codec_shim $name: no shim sources" >&2; return 1; }
    key=$({ declare -f codec_shim; printf '%s\n' 'shim-v2 -std=c11 -O2 -fPIC llvm-ar-qcL' "$toolchain_key"; for source in "$@"; do printf '%s\n' "${source##*/}"; cat "$source"; done; s2a_sha256 "$archive"; } | s2a_sha256 | cut -d' ' -f1)
    target=$parent/s2a-$key
    if ! codec_cached "$target"; then
        work=$(mktemp -d "$cache_root/codecs/shim-build.XXXXXX")
        trap 'rm -rf "$work"' EXIT
        for source in "$@"; do
            objects+=("$work/$(basename "${source%.c}").o")
            "$cc" -std=c11 -O2 -fPIC -I"$include" -c "$source" -o "${objects[${#objects[@]}-1]}"
        done
        llvm-ar qcL "$work/lib$name.a" "$archive" "${objects[@]}"
        llvm-ranlib "$work/lib$name.a"
        codec_publish "$work" "$target"
    fi
    printf '%s/lib%s.a\n' "$target" "$name"
)
