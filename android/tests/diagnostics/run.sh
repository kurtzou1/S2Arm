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
    "$root/android/tests/diagnostics/DiagnosticBundlePolicyTest.java" \
    "$root/android/tests/diagnostics/DiagnosticRedactorTest.java" \
    "$root/android/tests/diagnostics/DiagnosticBundleWriterTest.java"
java -ea -cp "$out" org.s2arm.android.DiagnosticBundlePolicyTest
# 对拍语料：期望值由 tools/redact.py（共用的 Python 实现）算，不跑被测的 Java 类；不读任何密钥文件。
python3 "$root/android/tests/diagnostics/redact_oracle.py" 20000 > "$out/oracle.tsv"
java -ea -cp "$out" org.s2arm.android.DiagnosticRedactorTest "$root/tests/fixtures/redact_cases.tsv" "$out/oracle.tsv"
java -ea -cp "$out" org.s2arm.android.DiagnosticBundleWriterTest
