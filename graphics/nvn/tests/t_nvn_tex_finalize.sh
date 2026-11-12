#!/bin/bash
# t_nvn_tex_finalize.sh <可执行文件>：逐种用例跑 #778 探针，按手写期望判（见 runtime/tests/mk/nvn_tex_finalize.mk）
set -u; BIN=$1; bad=0
got() { S2A_WIDEN_DIRECT=0 S2A_AUTOPLAY=0 "$BIN" "$1" sparse 2>/dev/null | sed -n 's/.* GPU_saved_descriptor=\([0-9]*\).*/\1/p'; }
for c in live:255 early:255 late:255 flight:255 remap:73; do
    m=${c%%:*}; want=${c##*:}; v=$(got "$m")
    if [ "$v" = "$want" ]; then echo "  过 ${m}：期望 ${want} → 真结果 ${v}"; else echo "  败 ${m}：期望 ${want} → 真结果 ${v:-无}"; bad=$((bad + 1)); fi
done
echo "  记 new（已知边界、不判）：$(got new)"
[ $bad = 0 ] && echo "✓ t_nvn_tex_finalize：5 项全过" || { echo "✗ t_nvn_tex_finalize：${bad} 项不通"; exit 1; }
