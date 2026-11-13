#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/Translation/* translator/dmsh_xlate_bin/*
# 片元深度寄存器（#869）：合成片元程序过生产翻译器，核 gl_FragDepth 取的寄存器（部分写的目标读 R9、写满的目标读 R5）：bash tests/frag_depth_register_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/frag_depth_register_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "片元深度寄存器单测全过" || { echo "片元深度寄存器单测有不通"; exit 1; }
