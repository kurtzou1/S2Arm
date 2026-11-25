#!/bin/bash
# Maxwell 浮点混合参考模型自检 + 矩阵（#674 通用根修：0 × 任何数 = 0，期望由模型算；Metal 固定混合那一路必须判出不等，由矩阵测试自己做、自己标记）。
# Mac 上另编 t_pblend_gpu：可编程混合（gal_colorround.c gal_color_round_pb_msl）在真 Metal 上跑同一矩阵，RGBA32F / RGBA16F 都要和模型全等。
# 门禁只看：graphics/nvn/tests/maxwell_blend_ref.py graphics/nvn/tests/maxwell_blend_matrix_test.py graphics/nvn/tests/t_pblend_gpu.m graphics/nvn/tests/t_pblend_rewrite.c graphics/dsx/gal_colorround.c graphics/dsx/gal_colorround.h
# 门禁覆盖：graphics/nvn/tests/maxwell_blend_ref.py graphics/nvn/tests/maxwell_blend_matrix_test.py graphics/nvn/tests/t_pblend_gpu.m graphics/nvn/tests/t_pblend_rewrite.c graphics/dsx/gal_colorround.c graphics/dsx/gal_colorround.h
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 -I "$H/graphics/nvn/tests/maxwell_blend_ref.py"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cc -Wall -Wextra -Werror -I "$H/graphics/dsx" "$H/graphics/nvn/tests/t_pblend_rewrite.c" "$H/graphics/dsx/gal_colorround.c" -o "$W/t_pblend_rewrite"
"$W/t_pblend_rewrite"   # 改写的文本面：做不了的报错、形状对（纯 C，各平台都跑）
if [ "$(uname -s)" = Darwin ]; then
  T=$W
  clang -fobjc-arc -O1 -Wall -Werror -I "$H/graphics/dsx" "$H/graphics/nvn/tests/t_pblend_gpu.m" "$H/graphics/dsx/gal_colorround.c" \
    -framework Metal -framework Foundation -o "$T/t_pblend_gpu"
  export S2A_PBLEND_GPU="$T/t_pblend_gpu"
fi
python3 -I "$H/graphics/nvn/tests/maxwell_blend_matrix_test.py"
