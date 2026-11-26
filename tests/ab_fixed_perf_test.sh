#!/bin/bash
# 对照局读数（tools/ab_fixed_perf.py）合成局目录单测：只取回放段的帧、power 行只取段内、足迹取峰值、回放段帧数不一致不判
# 门禁覆盖：tools/ab_fixed_perf.py tools/ab_fixed.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" "$H/tests/ab_fixed_perf_test.py"
