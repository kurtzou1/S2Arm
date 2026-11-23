#!/bin/bash
# 门禁覆盖：services/S2A.Services/SaveTransfer*.cs tests/save_transfer/ pack/jobs/saves.py pack/jobs/core.py pack/jobs/library.py pack/jobs/main.py
# 门禁预算：150
# NativeAOT 验证关闭反射序列化后的正式包预检路径（从 save_transfer_interop_test.sh 拆出，#1832 后续）。
# 同一 Apple Silicon 宿主一次构建 + NativeAOT 发布 + 前段夹具约 51 秒（发布一步约 28 秒）；上限取约 3 倍防负载下超时误红。
# 需要托管构建：存档夹具与 JIT 对照结果都由它产生。
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet="${DOTNET:-$HOME/.dotnet/dotnet}"
# 构建产物落本次私有目录、不打 NuGet 包（同 save_transfer_interop_test.sh / tests/vulkan_backend_test.sh）
T=$(mktemp -d "${TMPDIR:-/tmp}/s2a-save-aot.XXXXXXXX")
trap 'rm -rf "$T"' EXIT
"$dotnet" build tests/save_transfer/SaveTransferInterop.csproj -c Release --nologo --artifacts-path "$T/artifacts" -p:GeneratePackageOnBuild=false
# Run inspect inside NativeAOT with reflection serialization disabled, as in the APK.
"$dotnet" publish tests/save_transfer/SaveTransferInterop.csproj -c Release --nologo \
    --artifacts-path "$T/aot-artifacts" -o "$T/aot" \
    -p:S2ASaveAotTests=1 -p:GeneratePackageOnBuild=false
"${PYTHON:-python3}" tests/save_transfer/interop.py aot "$dotnet" "$T/artifacts/bin/SaveTransferInterop/release/SaveTransferInterop.dll" "$T/aot/SaveTransferInterop"
