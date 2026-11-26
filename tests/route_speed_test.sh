#!/bin/bash
# 固定路线计时判据（tools/route_speed.py）合成路线单测：按真实时间推进 r≈1 绿、按帧推进 r≈q 红、路线不同判不出
# 门禁覆盖：tools/route_speed.py tests/autoplay/autoplay.c
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" "$H/tests/route_speed_test.py"
