#!/bin/bash
# 金手指自带字面量池（#1321）：pack/cpatch.py literal_pool 认哪些 LDR (literal) / 常量字；夹具是玩家贴的 7 段原文，期望手算。
# 门禁只看：pack/cpatch.py tests/cpatch_literal_pool_test.py
# 门禁覆盖：pack/cpatch.py tests/cpatch_literal_pool_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
"$PY" -m unittest discover -s "$H/tests" -p cpatch_literal_pool_test.py -v
