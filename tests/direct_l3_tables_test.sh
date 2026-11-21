#!/bin/bash
# Offline original synthetic TSVs; execute only the real table collection (direct_lib.Lib.collect).
# 门禁覆盖：graphics/tools/direct/direct_lib.py tests/direct_l3_tables_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
exec "$PY" "$R/tests/direct_l3_tables_test.py" "$@"
