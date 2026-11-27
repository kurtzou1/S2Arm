#!/bin/bash
# 门禁覆盖：pack/fn_match.py runtime/fix/match runtime/fps/match graphics/nvn/tools/lz4blk.py
# 逐款表按函数指纹跨版本匹配（pack/fn_match.py）单测外壳：python3 tests/fn_match_test.py（合成 NSO，13 例，本机不到 1 秒）
set -u
cd "$(dirname "$0")/.." || exit 1
exec "${S2A_PY:-python3}" -B tests/fn_match_test.py
