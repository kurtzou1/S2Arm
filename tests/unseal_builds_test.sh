#!/bin/bash
# 门禁覆盖：pack/jobs/library.py tests/unseal_builds_test.py
# 启动时把旧版本留下的只读产物加回写权限（玩家手动删旧产物删不掉）：秒级；见 tests/unseal_builds_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/unseal_builds_test.py
