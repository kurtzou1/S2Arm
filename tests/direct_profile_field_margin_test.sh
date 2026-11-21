#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：android/native/direct/json.h android/tests/vk/profiles/devices/*.json graphics/tools/direct/compiler/DirectProfileCompose.cs
# 用生产生成器的输出统计设备端要解析的 capabilities 直接键（#1273）。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/direct-profile-margin.XXXXXX")
trap 'rm -rf "$out"' EXIT
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
[[ -x "$dotnet" ]] || dotnet=dotnet

"${CC:-cc}" -x c -I"$repo/android/native/direct" -o "$out/limit" - <<'C'
#include "json.h"
#include <stdio.h>
int main(void) { printf("%d\n", S2A_JSON_MAX_FIELDS); }
C
limit=$("$out/limit")

cli=S2A.DirectCompiler.Cli
"$dotnet" build "$repo/graphics/tools/direct/compiler/cli/$cli.csproj" -c Release \
    --artifacts-path "$out/art" -p:NuGetAudit=false --verbosity quiet
mkdir "$out/profiles"
for caps in "$repo"/android/tests/vk/profiles/devices/*.json; do
    "$dotnet" "$out/art/bin/$cli/release/$cli.dll" profile --caps "$caps" \
        --output "$out/profiles/$(basename "$caps")"
done

python3 - "$limit" "$out"/profiles/*.json <<'PY'
import json
import sys
from pathlib import Path

limit = int(sys.argv[1])
for filename in sys.argv[2:]:
    path = Path(filename)
    caps = json.loads(path.read_bytes())['capabilities']
    if not isinstance(caps, dict):
        sys.exit(f'{path.name}: capabilities 必须是 JSON 对象')
    count = len(caps)
    margin = limit - count
    result = f'{path.name} profile.capabilities: {count} 键，上限 {limit}，余量 {margin}（要求 ≥ 16）'
    if margin < 16:
        sys.exit(f'红：{result}')
    print(result)
PY
