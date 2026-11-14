#!/bin/bash
# Mac-only frontend checks; no game files, device access or network installation.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R"
source "$R/tools/toolchain.sh"   # 门禁用统一工具链（tools/toolchain.env）；S2A_DEVELOPER_DIR 可覆盖
export CLANG_MODULE_CACHE_PATH="$R/build/macos/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$R/build/macos/swift-cache"
mkdir -p build/macos/tests
python3 -B -m unittest discover -s pack/jobs/tests -v
python3 -B -m unittest discover -s launchers/macos/Tests -p 'test_*.py' -v
python3 -B -m unittest discover -s launchers/macos/gui_jobs/tests -v
python3 launchers/macos/sparkle_vendor.py > /dev/null   # Sparkle 二进制包不随仓库，按校验值备到 frontend/Vendor/
swift_args=(--disable-sandbox --cache-path "$R/build/macos/spm-cache" --package-path launchers/macos --scratch-path build/macos/spm)
swift test "${swift_args[@]}" list > build/macos/tests/swift-discovery.log
swift_rc=0
swift test "${swift_args[@]}" > build/macos/tests/swift-execution.log 2>&1 || swift_rc=$?
cat build/macos/tests/swift-execution.log
python3 launchers/macos/check_xctest.py build/macos/tests/swift-discovery.log build/macos/tests/swift-execution.log
[ "$swift_rc" = 0 ] || exit "$swift_rc"
# 原生输入（input_test.m）与系统键盘桥接（textinput_test.m）的 C / ObjC 单测挪到 tests/macos_native_input_test.sh（合入前层、按依赖文件路由；
#   11-10：#417 Joy-Con 体感改走 HID 后 input_test 漏链 joycon_imu.m，这里只在合入后层跑，守望才发现）
