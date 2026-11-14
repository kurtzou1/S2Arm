#!/bin/bash
# 能力清单「只用社区补丁」口径（tools/caps_policy.py decide）；单测本体 tests/caps_patch_only_test.py。
# 门禁覆盖：tools/caps_policy.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
"$PY" "$H/tests/caps_patch_only_test.py"
