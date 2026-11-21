#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
javac -encoding UTF-8 -Xlint:all -Werror -d "$out" \
    "$root/android/app/src/main/java/org/s2arm/android/DiagnosticBundlePolicy.java" \
    "$root/android/app/src/main/java/org/s2arm/android/DiagnosticRedactor.java" \
    "$root/android/app/src/main/java/org/s2arm/android/DiagnosticBundleWriter.java" \
    "$root/android/app/src/main/java/org/s2arm/android/DiagnosticExits.java" \
    "$root/android/app/src/main/java/org/s2arm/android/LastSession.java" \
    "$root/android/tests/diagnostics/DiagnosticBundlePolicyTest.java" \
    "$root/android/tests/diagnostics/DiagnosticRedactorTest.java" \
    "$root/android/tests/diagnostics/DiagnosticBundleWriterTest.java" \
    "$root/android/tests/diagnostics/LastSessionTest.java"
java -ea -cp "$out" org.s2arm.android.DiagnosticBundlePolicyTest
# 对拍语料：期望值由 tools/redact.py（共用的 Python 实现）算，不跑被测的 Java 类；不读任何密钥文件。
python3 "$root/android/tests/diagnostics/redact_oracle.py" 20000 > "$out/oracle.tsv"
java -ea -cp "$out" org.s2arm.android.DiagnosticRedactorTest "$root/tests/fixtures/redact_cases.tsv" "$out/oracle.tsv"
# 写包用例带一份真实设备档案（含 factsDigest）进包；包里那份再经导出工具取出、过 tools/devprofile_lint.py（#1749 M0：档案不走日志脱敏）
java -ea -cp "$out" org.s2arm.android.DiagnosticBundleWriterTest "$root/android/tests/devprofiles/mali-g710-r32p1.json" "$out/with-profile.zip"
python3 "$root/android/tools/device_profile.py" --bundle "$out/with-profile.zip" --out "$out/profile-out" --name exported
cmp -s "$out/profile-out/exported.json" "$root/android/tests/devprofiles/mali-g710-r32p1.json" || { echo "【红】诊断包里取出的设备档案和原档案不一致"; exit 1; }
echo "PASS: 诊断包里的设备档案原样、过 lint，导出工具取出后与原档案逐字节相同"
# #528 第 15 项：上一局异常结束提示的会话标记（期望按 iOS sesdiag.c 与 ApplicationExitInfo.REASON_* 手写）
java -ea -cp "$out" org.s2arm.android.LastSessionTest
