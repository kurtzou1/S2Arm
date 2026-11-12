#!/bin/bash
# 门禁覆盖：pack/orch/roots.py pack/jobs/embedded.py tests/git_pin_test.py
# git 调用钉死仓库、缺 refs 空目录自动补上（11-11 Windows 覆盖安装后播种 git 128）：python3 tests/git_pin_test.py（4 例，约 1 秒）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" -B "$H/tests/git_pin_test.py" -v
