#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/ReconIntra.cs compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/Types/Surface.cs tests/vp9_intra_border/*
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
export MSBUILDDISABLENODEREUSE=1
cd "$H/compat/tree"
dotnet build "$H/tests/vp9_intra_border/Vp9IntraBorder.csproj" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_intra_border/bin/Release/net10.0/Vp9IntraBorder.dll"
