#!/bin/bash
# 挪起点确定性判据（tools/ab_fixed_snapcmp.py）合成图单测：同一画面一致、横移不一致、缺图读不出
# 门禁覆盖：tools/ab_fixed_snapcmp.py tools/ab_fixed.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" "$H/tests/ab_fixed_snapcmp_test.py"
