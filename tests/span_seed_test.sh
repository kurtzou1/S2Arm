#!/bin/bash
# 种子表生成（tools/span_seed.py）单测：合成局日志，期望按规则手写——贴顶（跨度 ≥ 窗口 − 512 MB）不收，贴顶但有越界映射 / 远端缺页照收，没出首帧的局不收
# 门禁覆盖：tools/span_seed.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" "$H/tests/span_seed_test.py"
