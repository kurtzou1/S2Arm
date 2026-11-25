#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_frag_z.py
# 片元着色器读不读 gl_FragCoord.z（S2A.Dsh DshCompiler.FragZ → json frag_z；经 dsh_cmp --fn frag_z 调）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_frag_z.py"
