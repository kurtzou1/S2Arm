#!/bin/bash
# 审计 P1-173：直连库换进位三步改名不丢上一份直连库（合成目录夹具，见 direct_lib_swap_test.py）
# 门禁覆盖：graphics/tools/direct/direct_lib.py tests/direct_lib_swap_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
exec "$PY" "$R/tests/direct_lib_swap_test.py" "$@"
