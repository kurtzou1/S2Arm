#!/bin/bash
# 门禁只看：launchers/macos/* launchers/shared/*
# Mac 启动器 Swift 主目标 + 测试目标只编不跑（约 1 分钟，增量更快）：bash tests/macos_swift_build_test.sh
# 起因（11-11）：launchers/macos/gate.sh（含 XCTest）只在合入后层跑；h13-mac 给 JobOutcome.State 加了 paused、phone-job-outcome 的测试里 switch 没覆盖，
#   两支各自绿、合在一起编不过，列车放过、守望才红（launchers/macos 编译期错误）。合入前层改到 launchers/macos/ 就把主目标和测试目标编一遍，编不过就红；不跑测试（跑在合入后层）
# 非 macOS：没有 Swift / AppKit，退 75（环境未就绪，已登记 tools/contrib_tools.tsv「Xcode」）
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "macos_swift_build：要 macOS（Swift / AppKit），本机 $(uname -s) 没跑（环境未就绪）"; exit 75; }
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"
source "$R/tools/toolchain.sh" > /dev/null
export CLANG_MODULE_CACHE_PATH="$R/build/macos/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$R/build/macos/swift-cache"
mkdir -p build/macos/tests
t0=$SECONDS; rc=0
swift build --build-tests --disable-sandbox --cache-path "$R/build/macos/spm-cache" --package-path launchers/macos --scratch-path build/macos/spm > build/macos/tests/swift-build.log 2>&1 || rc=$?
if [ $rc != 0 ]; then grep -a -E 'error:' build/macos/tests/swift-build.log | head -20; echo "macos_swift_build：主目标 / 测试目标编译不过（$((SECONDS - t0)) 秒，日志 build/macos/tests/swift-build.log）"; exit 1; fi
echo "macos_swift_build：主目标 + 测试目标编译通过（$((SECONDS - t0)) 秒）"
