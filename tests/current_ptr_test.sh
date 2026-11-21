#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/current.py pack/orch/roots.py pack/jobs/layout.py tests/current_ptr_test.py
# Python 侧现行指针文件单测（玩家诊断 #0fd185）：读写、坏值、旧链接 / 实目录迁移、迁移中途断后恢复、并发，秒级
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
PYTHONUTF8=1 "$PY" "$H/tests/current_ptr_test.py" -v
