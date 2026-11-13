#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Audio/Renderer/Dsp/ResamplerHelper.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/S2ADspMixHelper.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/S2ADspFast.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/BiquadFilterHelper.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/DataSourceHelper.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/Command/DownMixSurroundToStereoCommand.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/Command/MixRampCommand.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/Command/MixRampGroupedCommand.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/Command/VolumeRampCommand.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/Command/DeviceSinkCommand.cs tests/audio_dsp_simd/* tests/audio_dsp_fast/*
#   （逐个写全路径：路由按 fnmatch 匹配，不认 {a,b} 花括号——原先那行花括号写法一个都没命中）
# 音频 DSP 内核的 S2Arm AdvSimd 快路径（S2A_AUDIO_DSP_FAST，缺省开）必须与上游标量循环逐位一致；
# 跑两遍：缺省（快路径开）与 S2A_AUDIO_DSP_FAST=0（快路径关），分派器接线两种模式都必须绿。
# 在非 ARM64 上没有 AdvSimd，只打印 off。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/audio_dsp_simd/AudioDspSimd.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
cd "$H/compat/tree"
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
BIN="$H/tests/audio_dsp_simd/bin/Release/net10.0/AudioDspSimd.dll"
dotnet "$BIN"
S2A_AUDIO_DSP_FAST=0 dotnet "$BIN"
# 双二阶 / 波形缓冲两处快路径（走公开接口，单独一个工程）：双二阶照原循环逐位比；波形缓冲栈上先填两种垃圾、两遍输出必须一样（#630 合入时补）
P2="$H/tests/audio_dsp_fast/AudioDspFast.csproj"
dotnet build "$P2" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
BIN2="$H/tests/audio_dsp_fast/bin/Release/net10.0/AudioDspFast.dll"
dotnet "$BIN2"
S2A_AUDIO_DSP_FAST=0 dotnet "$BIN2"
