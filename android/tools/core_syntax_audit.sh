#!/usr/bin/env bash
# 只读审计：runtime/src 能不能编到 Android（头 / 类型这一层）。
#
# 为什么有它：A-W3（A2 原生核心接入）的第一步是「CMake / 符号审计 / s2a_native_stub 替换清单」。
# 这个脚本把「编译」这一层固定下来：谁动了 runtime/src，跑一次就知道多了哪几处缺口。
# 它不改任何文件、不进产品链、不产出二进制（-fsyntax-only），只回答一个问题：
# 「现在把 runtime/src 编到 aarch64 Android，卡在哪、卡在什么类型上」。
#
# 用法：
#   bash android/tools/core_syntax_audit.sh             # 人读报告
#   bash android/tools/core_syntax_audit.sh --tsv       # 机器可读（可 diff 当基线）
#   bash android/tools/core_syntax_audit.sh --shim      # 额外挂一个 TargetConditionals.h 垫片
#   bash android/tools/core_syntax_audit.sh --strict    # 有文件编不过就退 1
#
# 退出码：0 = 审计跑完（无论结果）；1 = --strict 且有文件编不过；2 = 环境不满足（找不到 NDK）。
#
# 结果分类：
#   OK      直接编过
#   HEADER  缺头文件（苹果头，或没加对的 -I）
#   SHAPE   头有了但类型/常量对不上（mcontext_t、F_SETNOSIGPIPE 这类，加头解决不了）
set -uo pipefail

strict=0
shim=0
tsv=0
for arg in "$@"; do
    case $arg in
        --strict) strict=1 ;;
        --shim) shim=1 ;;
        --tsv) tsv=1 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo" || exit 2

# NDK：优先环境变量，其次 SDK 下的 ndk/<版本>（取版本号最大的）。
ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [ -z "$ndk" ]; then
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /opt/android-sdk "$HOME/Android/Sdk"; do
        [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
        ndk=$sdk/ndk/$(ls "$sdk/ndk" | sort -V | tail -1)
        break
    done
fi
clang=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/clang 2>/dev/null | head -1)
if [ -z "$ndk" ] || [ ! -x "$clang" ]; then
    echo "core_syntax_audit: 找不到 NDK（设 ANDROID_NDK_HOME，或把 NDK 放到 \$ANDROID_HOME/ndk/）" >&2
    exit 2
fi

target=aarch64-none-linux-android34
includes=(-I runtime/include -I runtime/src -I platforms -I graphics/track)

# --shim：苹果的 TargetConditionals.h 只在苹果 SDK 里有，值全 0 就走非苹果分支。
shim_dir=
cleanup() { [ -n "$shim_dir" ] && rm -rf "$shim_dir"; }
trap cleanup EXIT
if [ "$shim" = 1 ]; then
    shim_dir=$(mktemp -d)
    cat > "$shim_dir/TargetConditionals.h" <<'EOF'
#pragma once
#define TARGET_OS_MAC 0
#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_ANDROID 1
EOF
    includes+=(-I "$shim_dir")
fi

ok=0; header=0; shape=0; total=0
rows=()
for f in runtime/src/*.c; do
    total=$((total + 1))
    first=$("$clang" -fsyntax-only -std=gnu11 --target="$target" "${includes[@]}" "$f" 2>&1 | grep -m1 'error:')
    if [ -z "$first" ]; then
        ok=$((ok + 1)); rows+=("OK"$'\t'"$(basename "$f")"$'\t'"")
    elif printf '%s' "$first" | grep -q 'file not found'; then
        header=$((header + 1)); rows+=("HEADER"$'\t'"$(basename "$f")"$'\t'"$(printf '%s' "$first" | sed 's/.*error: //')")
    else
        shape=$((shape + 1)); rows+=("SHAPE"$'\t'"$(basename "$f")"$'\t'"$(printf '%s' "$first" | sed 's/.*error: //')")
    fi
done

if [ "$tsv" = 1 ]; then
    printf '%s\n' "${rows[@]}"
else
    echo "runtime/src → ${target}（$(basename "$(dirname "$(dirname "$clang")")")）"
    echo "共 $total 个文件：OK $ok / HEADER $header / SHAPE $shape$([ "$shim" = 1 ] && echo '（已挂 TargetConditionals 垫片）')"
    echo
    printf '%-7s %-16s %s\n' 状态 文件 首个错误
    printf '%-7s %-16s %s\n' -------- ---------------- ----------------------------------------
    printf '%s\n' "${rows[@]}" | sort | while IFS=$'\t' read -r st name detail; do
        printf '%-7s %-16s %s\n' "$st" "$name" "$detail"
    done
fi

if [ "$strict" = 1 ] && [ $((header + shape)) -gt 0 ]; then
    exit 1
fi
exit 0
