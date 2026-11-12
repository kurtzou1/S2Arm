#!/bin/bash
# 门禁覆盖：tools/clonedir.py
# clonedir 在 exFAT 上（外部 PR #395）：跳过 AppleDouble「._*」、RENAME_EXCL 不支持时「目标不存在才改名」；见 tests/clonedir_exfat_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONPATH=pack/jobs:tools PYTHONWARNINGS=ignore::ResourceWarning "$PY" -m unittest tests.clonedir_exfat_test > /dev/null 2>&1
echo "✓ clonedir exFAT 单测全过"
