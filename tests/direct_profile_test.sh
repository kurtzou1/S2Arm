#!/bin/bash
# Offline synthetic NSO/NPDM contract tests; plain Python 3 (python-lz4 optional: graphics/nvn/tools/lz4blk.py).
# 门禁覆盖：graphics/tools/direct/* graphics/nvn/tools/* graphics/nvn/games/game.py pack/direct_profile_stage.py pack/oneclick/oneclick.sh pack/seed_root.sh pack/srcs.sh pack/stage_direct.sh pack/stage_direct_profile.sh tools/clonedir.py tools/progress.py tools/nostall.py tools/addr_need.py tools/nso_plain.py
#   （10-26：f3943d105 改直连出库、加 graphics/tools/direct/dmsh_par.py，门禁没跑本单测、红着合进 main——路由器只追本 .sh 点名的文件，追不到 .py 里拷用的这些；
#    这份清单 = direct_profile_test.py 里 REPO / "…" 引用的全部文件，直连目录整个用通配，新增文件自动算进来）
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
exec "$PY" "$R/tests/direct_profile_test.py" "$@"
