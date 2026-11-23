#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：tools/docs_consistency.py tests/docs_consistency_test.py AGENTS.md CONTRIBUTING.md README.zh-CN.md graphics/nvn/tools/README.profile.md tools/train.sh tools/contrib_check.sh
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -I -B tests/docs_consistency_test.py || exit $?
"${S2A_PY:-python3}" tools/docs_consistency.py
