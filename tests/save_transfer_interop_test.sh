#!/bin/bash
# 门禁覆盖：services/S2A.Services/SaveTransfer*.cs tests/save_transfer/ pack/jobs/saves.py pack/jobs/core.py pack/jobs/library.py pack/jobs/main.py
# 门禁预算：240
# JIT 验证 Python 与托管存档互操作，NativeAOT 验证关闭反射序列化后的正式包预检路径。
# 同一 Apple Silicon 宿主两轮完整运行 67 / 81 秒，含两次独立构建和真实 LibHac 合成档；门禁两台历史 63～104 秒，上限取约 2.3 倍防负载下超时误红。
# Real LibHac creates/commits public repository files; no game, keys or player saves.
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet="${DOTNET:-$HOME/.dotnet/dotnet}"
# 构建产物落本次私有目录、不打 NuGet 包（同 tests/vulkan_backend_test.sh）：11-01 main 无缓存全套并行跑单测，几支同时构建共享的
#   compat/tree 工程，Ryujinx.Memory 等「构建时打包」抢同一个 .nupkg 报「The process cannot access the file」，本测试被误判红
T=$(mktemp -d "${TMPDIR:-/tmp}/s2a-save-interop.XXXXXXXX")
trap 'rm -rf "$T"' EXIT
"$dotnet" build tests/save_transfer/SaveTransferInterop.csproj -c Release --nologo --artifacts-path "$T/artifacts" -p:GeneratePackageOnBuild=false
# Run inspect inside NativeAOT with reflection serialization disabled, as in the APK.
"$dotnet" publish tests/save_transfer/SaveTransferInterop.csproj -c Release --nologo \
    --artifacts-path "$T/aot-artifacts" -o "$T/aot" \
    -p:S2ASaveAotTests=1 -p:GeneratePackageOnBuild=false
args=("$dotnet" "$T/artifacts/bin/SaveTransferInterop/release/SaveTransferInterop.dll" "$T/aot/SaveTransferInterop")
if [ "$(uname -s)" = Darwin ]; then
    "${CC:-cc}" -Wall -Wextra -Werror -dynamiclib tests/save_transfer/space_faults.c -o "$T/space_faults.dylib"
    args+=("$T/space_faults.dylib")
fi
"${PYTHON:-python3}" tests/save_transfer/interop.py "${args[@]}"
