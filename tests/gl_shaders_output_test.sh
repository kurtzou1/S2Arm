#!/bin/bash
# 门禁覆盖：translator/gl_shaders.py tests/gl_shaders_output_test.py
# gl_shaders.py 外部工具输出按 UTF-8 宽松解、失败原因不丢（D-TCA9）：子进程替身，约 1 秒；见 tests/gl_shaders_output_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/gl_shaders_output_test.py
