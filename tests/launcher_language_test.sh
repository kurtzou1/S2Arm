#!/bin/bash
# 门禁覆盖：launchers/macos/frontend/Sources/NXCore/Localization.swift launchers/macos/frontend/Sources/NXCore/LocalizationFiles.swift launchers/macos/frontend/l10n/* launchers/macos/frontend/Tests/NXCoreTests/* launchers/macos/frontend/Package.swift
# Mac 启动器界面语言：第一次跟随系统（简中 / 繁中 / 英 / 日）、选过重启仍记住、选「跟随系统」回到跟随（Windows 同规则在 Protocol.Tests LauncherLanguageCases）：bash tests/launcher_language_test.sh
set -u; cd "$(dirname "$0")/../launchers/macos/frontend" || exit 1
[ "$(uname)" = Darwin ] || { echo "launcher_language：要 macOS（swift test）"; exit 1; }
out=$(swift test --filter NXCoreTests 2>&1); rc=$?
printf '%s\n' "$out" | grep -E "Executed .* tests" | tail -1
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "with 0 failures" && echo "界面语言单测全过" || { printf '%s\n' "$out" | grep -E "error|failed" | head -10; echo "界面语言单测有不通"; exit 1; }
