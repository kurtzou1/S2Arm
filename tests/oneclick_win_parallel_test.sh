#!/bin/bash
# 门禁覆盖：pack/orch/oneclick_win.py
# Windows 一键出包并行度按内存封顶（#711）：抽取 / 改写与直连库编译路数同 tools/cores.sh 口径；见 tests/oneclick_win_parallel_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 PYTHONWARNINGS=ignore::ResourceWarning "$PY" tests/oneclick_win_parallel_test.py > /dev/null
echo "✓ Windows 一键出包并行度按内存封顶单测全过"
