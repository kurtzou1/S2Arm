#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_max_threads.py
# 计算核线程数声明（S2A.Dsh DshCompiler.MaxThreads，#2118；经 dsh_cmp --fn max_threads 调，改写结果真交 Metal 编译核管线上限）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_max_threads.py"
