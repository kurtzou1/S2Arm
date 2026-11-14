#!/bin/bash
# 门禁只看：launchers/macos/Tests/input_test.m launchers/macos/Tests/textinput_test.m macos/*.c macos/*.m macos/*.h runtime/src/input_config.c runtime/src/pad.c runtime/include/*.h ios/input_config.m ios/*.h runtime/ns2pro/*
# Mac 原生输入单测（编 + 链 + 跑 launchers/macos/Tests/input_test.m 与 textinput_test.m，约 20 秒）：bash tests/macos_native_input_test.sh
# 起因（11-10）：这两段原在 launchers/macos/test.sh 里，只在合入后层（守望）跑，路由也只认 launchers/macos/ 与 pack/jobs/；
#   #417 Joy-Con 体感改走 HID（macos/joycon_imu.m）后 input_test 漏链这个文件，合进 main 后守望才红。挪到合入前层，改到它依赖的文件就跑。
#   #703 起 front_mac.m 问 textinput_mac.m「key window 是不是系统输入框」（game_window_focused）：input_test 一并链 textinput_mac.m + text_input.c
# 非 macOS：没有 AppKit / GameController，退 75（环境未就绪，已登记 tools/contrib_tools.tsv「Xcode」）
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "macos_native_input：要 macOS（AppKit / GameController），本机 $(uname -s) 没跑（环境未就绪）"; exit 75; }
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"
source "$R/tools/toolchain.sh" > /dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLANG_MODULE_CACHE_PATH="$T/clang-cache"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Iruntime/include -Iios \
  launchers/macos/Tests/input_test.m runtime/src/input_config.c runtime/src/pad.c ios/input_config.m -o "$T/input" \
  macos/ns2_controller.c macos/joycon_imu.m macos/hid_pad.m runtime/ns2pro/*.c runtime/ns2pro/NS2Transport.m -Iruntime/ns2pro/include \
  macos/textinput_mac.m runtime/src/text_input.c \
  -framework AppKit -framework CoreGraphics -framework GameController -framework CoreHaptics -framework QuartzCore -framework CoreBluetooth -framework IOKit
"$T/input"
# 系统键盘桥接 Mac 端（textinput_mac.m + runtime/src/text_input.c）：真起 AppKit 表单，程序代填字 / 点按钮核回调
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Iruntime/include -Iios \
  launchers/macos/Tests/textinput_test.m -o "$T/textinput" -framework AppKit
"$T/textinput"
echo "macos_native_input 单测全过"
