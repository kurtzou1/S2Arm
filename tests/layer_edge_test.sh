#!/bin/bash
# 门禁只看：tools/layer_edge.py tools/layer_map.py tools/layer_map.tsv tools/layer_exempt.tsv runtime/* services/* graphics/* android/* ios/* macos/* platform/* shell/* pack/* Makefile
# 分层边检查（tools/layer_edge.py，架构分层方案 4.3 阶段一 1-1）单测，约 2 秒：bash tests/layer_edge_test.sh
# 合成小仓（最小地图：runtime/src 核心、platform/plat.h 契约、android 平台壳、graphics/nvn/gfx/nvn 图形共用层）。期望按方案 4.3.2 / 4.3.5 手写：
#   ① 核心 .c 新增 #include 安卓私有头（负对照：核心 → 安卓）→ 红，点名 文件:行 与 R-01；包含平台契约 plat.h → 不红
#   ② 把这条边登记进豁免表 → 绿
#   ③ 删掉这行 include、豁免还留着 → 红「豁免过时」（只减不增）
#   ④ 核心 .c 包含 <mach/mach.h> → 红 R-02；核心目录里的测试文件（tests/ 下、t_*.c）包含安卓头 → 不算
#   ⑤ 安卓壳包含图形内部头 nvn_mtl.h → 红 R-05；包含公开头 nvn_backend.h → 不红
#   ⑥ 真仓库：未登记 0、豁免过时 0（rc=0）；墙钟只打读数、不当判据（门禁把这一步当确定性步：结果只由内容定，负载高时计时会随机挡车）
#   ⑦ 门禁路由：改 runtime/src/ 下的文件会选中本单测；只改 docs/ 不选中
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/r; mkdir -p "$R/tools" "$R/runtime/src/tests" "$R/android" "$R/graphics/nvn/gfx/nvn" "$R/docs" "$R/platform"
cp "$H/tools/layer_edge.py" "$H/tools/layer_map.py" "$R/tools/"
printf 'runtime/src/\t核心\t原生\t共用层\nplatform/plat.h\t平台接口\t契约\t共用层\nandroid/\t平台壳\t安卓\t安卓自己\ngraphics/nvn/gfx/nvn/\t图形后端\t直连前端\t共用层\ntools/\t工具与测试\t工具\t工具与文档\ndocs/\t文档与约定\t文档\t工具与文档\n' > "$R/tools/layer_map.tsv"
echo '// 契约' > "$R/platform/plat.h"; echo '// 安卓私有' > "$R/android/fault.h"
echo '// 公开' > "$R/graphics/nvn/gfx/nvn/nvn_backend.h"; echo '// 内部' > "$R/graphics/nvn/gfx/nvn/nvn_mtl.h"; echo x > "$R/docs/a.md"
printf '#include "../../platform/plat.h"\nint a;\n' > "$R/runtime/src/a.c"
git -C "$R" init -q
chk() { (cd "$R" && git add -A > /dev/null && python3 tools/layer_edge.py check 2>&1); }
printf '#include "../../platform/plat.h"\n#include "../../android/fault.h"\nint a;\n' > "$R/runtime/src/a.c"
o1=$(chk); r1=$?
ck "① 核心 → 安卓 → 红、点名 a.c:2 与 R-01；含契约 plat.h 不红（rc=${r1}）" '[ $r1 = 1 ] && grep -q "【红】runtime/src/a.c:2 核心反向包含平台实现 android/fault.h（R-01" <<< "$o1" && ! grep -q "plat.h" <<< "$o1"'
printf '# 表头\nR-01\truntime/src/a.c\tandroid/fault.h\t单测登记：清零条件 删 include\n' > "$R/tools/layer_exempt.tsv"
o2=$(chk); r2=$?
ck "② 登记进豁免表 → 绿（rc=${r2}）" '[ $r2 = 0 ] && grep -q "豁免 1 行；未登记 0、豁免过时 0" <<< "$o2"'
printf '#include "../../platform/plat.h"\nint a;\n' > "$R/runtime/src/a.c"
o3=$(chk); r3=$?
ck "③ 边删了、豁免还在 → 红「豁免过时」（rc=${r3}）" '[ $r3 = 1 ] && grep -q "tools/layer_exempt.tsv:2 豁免过时：R-01 runtime/src/a.c → android/fault.h" <<< "$o3"'
: > "$R/tools/layer_exempt.tsv"
printf '#include <mach/mach.h>\nint b;\n' > "$R/runtime/src/b.c"
printf '#include "../../../android/fault.h"\n' > "$R/runtime/src/tests/x.c"; printf '#include "../../android/fault.h"\n' > "$R/runtime/src/t_y.c"
o4=$(chk); r4=$?
ck "④ 核心含 <mach/mach.h> → 红 R-02；测试文件含安卓头不算（rc=${r4}）" '[ $r4 = 1 ] && grep -q "【红】runtime/src/b.c:1 共用文件直接包含苹果头 <mach/mach.h>（R-02" <<< "$o4" && ! grep -q "tests/x.c\|t_y.c" <<< "$o4"'
rm -f "$R/runtime/src/b.c"
printf '#include "../graphics/nvn/gfx/nvn/nvn_backend.h"\n#include "../graphics/nvn/gfx/nvn/nvn_mtl.h"\n' > "$R/android/shim.c"
o5=$(chk); r5=$?
ck "⑤ 壳含图形内部头 nvn_mtl.h → 红 R-05；公开头 nvn_backend.h 不红（rc=${r5}）" '[ $r5 = 1 ] && grep -q "【红】android/shim.c:2 平台壳包含图形内部头 graphics/nvn/gfx/nvn/nvn_mtl.h（R-05" <<< "$o5" && ! grep -q "nvn_backend.h" <<< "$o5"'
s0=$(python3 -c 'import time;print(time.time())'); o6=$(cd "$H" && python3 tools/layer_edge.py check 2>&1); r6=$?; el=$(python3 -c "import time;print(round(time.time()-$s0,1))")
ck "⑥ 真仓库：未登记 0、豁免过时 0（用时 ${el} 秒，只作读数）（$(grep '^分层边' <<< "$o6")）" '[ $r6 = 0 ] && grep -q "未登记 0、豁免过时 0" <<< "$o6"'
q1=$(cd "$H" && GATE_TIER=full python3 tools/gate_route.py tests runtime/src/os.c 2> /dev/null); q2=$(cd "$H" && GATE_TIER=full python3 tools/gate_route.py tests docs/贡献指南.md 2> /dev/null)
ck "⑦ 路由：改 runtime/src/os.c 选中本单测、只改 docs 不选中" 'grep -qx "tests/layer_edge_test.sh" <<< "$q1" && ! grep -qx "tests/layer_edge_test.sh" <<< "$q2"'
[ $bad = 0 ] && echo "layer_edge 单测全过"; exit $bad
