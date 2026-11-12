#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/Instructions/InstEmitAmpere* compat/tree/src/Ryujinx.Graphics.Shader/Instructions/InstEmitFloatArithmetic.cs compat/tree/src/Ryujinx.Graphics.Shader/Decoders/DecoderAmpere.cs compat/tree/src/Ryujinx.Graphics.Shader/Decoders/AmpereOp.cs graphics/tools/direct/dsh/* graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/nvn/gfx/nvn/nvn_tex.c graphics/nvn/gfx/nvn/nvn_tex.h tests/ampere_isa/* tests/ampere_isa_test.sh
# Switch 2（Ampere）指令单测（约 30 秒，要 Metal）：bash tests/ampere_isa_test.sh
# 合成的 NVN2 片元着色器经出包同一条链（S2A.Dsh Compile，dsh_cmp --fn ampere_compile）翻成 MSL，在 GPU 上画 1 个像素读回，期望按公开规格手算（tests/ampere_isa/cases.py 文件头）。
# 负对照：DSH_CMP_DLL 指向改动前的翻译器跑同一批例，cases.py 里标「新」的例必须红；一维 TLD.LZ 另有 TBUF_FORM=fixed（宿主按固定 16384 列的行绑）越界例必须红（读数见 02_Ampere指令集_报告.md）。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/ampere_isa.XXXXXX"); trap 'rm -rf "$T"' EXIT
make -s -C "$H/graphics/dsx" -j"${S2A_CPU_GATE:-6}" "$H/build/dsx/libdsx.dylib" > "$T/make.log" 2>&1 || { echo "✗ libdsx.dylib 编不过：$(grep -m1 error "$T/make.log" | cut -c1-200)"; exit 1; }
xcrun clang -O1 -fobjc-arc -I"$H/graphics/nvn/gfx/nvn" -o "$T/frag_run" "$H/tests/ampere_isa/frag_run.m" "$H/graphics/nvn/gfx/nvn/nvn_tex.c" -framework Metal -framework Foundation > "$T/cc.log" 2>&1 || { echo "✗ frag_run 编不过：$(head -3 "$T/cc.log")"; exit 1; }
python3 "$H/tests/ampere_isa/cases.py" "$T/frag_run"
