#!/bin/bash
# 门禁覆盖：launchers/shared/experience.v1.json launchers/macos/frontend/Sources/NX2Apple/* launchers/macos/adapter/Sources/S2ArmAppleAdapter/BackendText.swift launchers/windows/launcher/App/* launchers/windows/launcher/Protocol/SharedText.cs
# 顶栏「故障报修」与报错页指引（两端源码与共享规格静态核）：bash tests/report_button_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/report_button_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "故障报修单测全过" || { echo "故障报修单测有不通"; exit 1; }
