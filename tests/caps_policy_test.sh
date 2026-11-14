#!/bin/bash
export S2A_CAPS_OWN=1   # 本测的是我方 60 帧 / 满屏旧口径（11-13 起发布缺省只用社区补丁，见 tests/caps_patch_only_test.py）
# caps_policy 引擎通用第一层来源单测（假引擎推导，不读游戏数据）
# 门禁覆盖：tools/caps_policy.py tools/caps_ledger.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
"${S2A_PY:-python3}" "$R/tests/caps_apple_compat_test.py"
exec "${S2A_PY:-python3}" "$R/tests/caps_policy_test.py" "$@"
