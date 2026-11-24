#!/bin/bash
# 门禁覆盖：graphics/metal/tools/embed_msl.py
# 生成头的临时文件名每个进程各一份（11-24 runtime 钩子 graphics_session / present_hdr_gal 并行同时生成 gal_aa_neighbour.h：
#   共用 <头>.tmp，一边改名时被另一边挪走 → FileNotFoundError，make 删掉头，另一组「file not found」）。期望手写：
#   ① 「别人正占着 <头>.tmp」（用同名目录占住，确定性地模拟另一进程的临时文件）时照样生成成功、内容对；② 8 路并行生成同一个头 20 轮，全部退 0、头完整；
#   反证：旧写法（固定 .tmp）在 ① 下失败
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
printf 'kernel void k() {}\n// "q"?\n' > "$T/a.metal"
mkdir "$T/x.h.tmp"
if python3 "$H/graphics/metal/tools/embed_msl.py" "$T/a.metal" k_a "$T/x.h" 2> "$T/e1" && grep -q 'static const char k_a\[\]' "$T/x.h"; then echo "通 ① 有人占着 .tmp 照样生成"; else echo "不通 ① $(tail -1 "$T/e1")"; bad=1; fi
fail=0; for r in $(seq 1 20); do for i in 1 2 3 4 5 6 7 8; do python3 "$H/graphics/metal/tools/embed_msl.py" "$T/a.metal" k_a "$T/y.h" 2>> "$T/e2" & done; wait || true
  cmp -s "$T/x.h" "$T/y.h" || fail=$((fail + 1)); done   # 与 ① 单进程生成的那份逐字节相同 = 完整
[ -s "$T/e2" ] && fail=$((fail + 1))
[ $fail = 0 ] && echo "通 ② 8 路并行 20 轮全部成功、头完整" || { echo "不通 ② 失败 $fail 轮：$(head -2 "$T/e2")"; bad=1; }
ls "$T"/y.h.*.tmp > /dev/null 2>&1 && { echo "不通 ② 留下临时文件"; bad=1; } || echo "通 ② 没留临时文件"
exit $bad
