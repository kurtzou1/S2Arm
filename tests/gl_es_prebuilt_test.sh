#!/bin/bash
# 门禁覆盖：translator/gl_shaders.py launchers/windows/bundle_prepare_win.py tests/gl_es_prebuilt_test.py
# GLSL 改写工具先用启动器预编件（#852 Windows 玩家机没有 C 编译器）：约 2 秒；见 tests/gl_es_prebuilt_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/gl_es_prebuilt_test.py
