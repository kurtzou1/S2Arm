#!/bin/bash
# 门禁覆盖：translator/gl_shaders.py tests/gl_shaders_target_test.py
# gl_shaders.py 两个目标各剔各的编不过（审计 P1-176）：外部命令替身，约 1 秒；见 tests/gl_shaders_target_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/gl_shaders_target_test.py
