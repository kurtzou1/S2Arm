#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_pool_image.py
# 图像的整池回退数组（S2A.Dsh DshCompiler.PoolArrays / IsPoolName）：名字带格式后缀的 <阶段>_i…_cb0_40000000_<格式> 也改成池指针、反射成 tex_pool（#2051）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_pool_image.py"
