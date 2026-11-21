#!/bin/bash
# 门禁覆盖：services/S2A.Services/SaveTransfer*.cs tests/save_transfer/
# 存档从电脑推进来、还没起过局就导出：报 save_user 并说清「先进一次游戏」，不留半个备份、不动存档。造的存档根，不要私有数据
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet="${DOTNET:-$HOME/.dotnet/dotnet}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$dotnet" build tests/save_transfer/SaveTransferTest.csproj -c Release --nologo -v q --artifacts-path "$T/artifacts" -p:GeneratePackageOnBuild=false >/dev/null
"$dotnet" "$T/artifacts/bin/SaveTransferTest/release/SaveTransferTest.dll" --export-unstarted
