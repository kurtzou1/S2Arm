#!/bin/bash
# 门禁只看：tools/gate.sh tools/gate_plan.sh tests/gate_fast_step_test.sh
# 门禁点名快路（tools/gate.sh GATE_FAST=1，11-16 门禁刀五）。约 5 秒。
# 假仓库：语法 + 单测 x_test（绿）、r_test（红）+ 钩子 a/gate.sh；tools/gate_route.py、tools/gate_decl.py 是桩，每次被调把子命令记进 calls。
# 期望（按规则手写）：
#   ① GATE_FAST=1 + 点名「单测 x_test」：只跑 x、1 / 1 绿，路由器与声明收集一次都没调（calls 空），打「快路：」行
#   ② 同样点名不给 GATE_FAST：照现路规划（calls 含 route why / tests），结论行与步行（去掉秒数）与 ① 逐字相同
#   ③ 快路点名红单测「单测 r_test」：步行 🔴、退出 1，与现路同一结论行
#   ④ 点名里夹钩子（「单测 x_test<TAB>钩子 a/gate.sh」）：不走快路（calls 有 route），两步都跑、2 / 2 绿
#   ⑤ 快路点名不存在的单测：跑了 0 步 / 应跑 0 步（与现路同；gate2 step.sh 按「跑了 1 步 / 应跑 1 步」缺失判红）
#   ⑥ 快路点名「语法」与「公开仓扫描」以外的固定步照现路的命令跑：语法 1 / 1 绿
#   ⑦ 分层（GATE_LAYER=pre）时不走快路（calls 有 route）
# 反证：S2A_GATE_SH=<旧版 gate.sh> 跑本单测应红（旧版不认 GATE_FAST：① calls 非空）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST GATE_FAST GATE_BUDGET_Q
export GATE_NO_LOADQ=1 HOME=$T/home GATE_LEDGER=- CALLS=$T/calls
mkdir -p $T/home $T/repo/tools $T/repo/tests $T/repo/a; cd $T/repo || exit 1
git init -q; git config user.email t@t; git config user.name t
cp "$GS" tools/gate.sh; cp $H/tools/gate_plan.sh tools/
cat > tools/gate_route.py << 'EOF'
import os, sys
open(os.environ["CALLS"], "a").write("route " + sys.argv[1] + "\n")
c = sys.argv[2:]
print({"why": "桩", "ios": "no", "hooks": "a/gate.sh", "claimed": ""}.get(sys.argv[1], "\n".join(x for x in c if x.startswith("tests/"))))
EOF
cat > tools/gate_decl.py << 'EOF'
import os, sys
open(os.environ["CALLS"], "a").write("decl " + sys.argv[1] + "\n")
EOF
printf '#!/bin/bash\necho x >> %s/trace; echo x 过\n' "$T" > tests/x_test.sh
printf '#!/bin/bash\necho r >> %s/trace; echo r 不过; exit 1\n' "$T" > tests/r_test.sh
printf '#!/bin/bash\necho a >> %s/trace; echo a 过\n' "$T" > a/gate.sh
git add -A; git commit -qm 1
g() { local o=$1; shift; : > $T/trace; : > $CALLS; env GATE_TIER=full "$@" bash tools/gate.sh > "$T/$o" 2>&1; echo $?; }
tr1() { sort $T/trace | tr '\n' ' '; }
cl() { tr '\n' '|' < $CALLS; }
steps() { grep -E '^(🟢|🔴)' "$T/$1" | sed -E 's/ [0-9]+ 秒([：（])/ N 秒\1/'; tail -1 "$T/$1"; }   # 红步行是「N 秒（rc=1）：」，秒数也抹掉（负载下两次 0 / 1 秒不同就误判）

r=$(g o1 GATE_FAST=1 GATE_RERUN="单测 x_test" GATE_CHANGED=tests/x_test.sh); t=$(tr1); c=$(cl)
ck "① 快路：只跑 x、1 / 1 绿、不调路由与声明（trace ${t}，calls ${c}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "x " ] && [ -z "$c" ] && tail -1 $T/o1 | grep -qF "跑了 1 步 / 应跑 1 步" && grep -q "^快路：" $T/o1'
r=$(g o2 GATE_RERUN="单测 x_test" GATE_CHANGED=tests/x_test.sh); t=$(tr1); c=$(cl)
ck "② 现路照规划、步行与结论行同 ①（calls ${c}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "x " ] && grep -q "route why" $CALLS && grep -q "route tests" $CALLS && [ "$(steps o1)" = "$(steps o2)" ]'
r=$(g o3 GATE_FAST=1 GATE_RERUN="单测 r_test" GATE_CHANGED=tests/r_test.sh); r3=$(g o3b GATE_RERUN="单测 r_test" GATE_CHANGED=tests/r_test.sh)
ck "③ 快路红单测：🔴、退出 1，与现路同（rc=${r} / 现路 ${r3}）" '[ $r = 1 ] && [ $r3 = 1 ] && grep -q "^🔴 单测 r_test" $T/o3 && [ "$(steps o3)" = "$(steps o3b)" ]'
r=$(g o4 GATE_FAST=1 GATE_RERUN="单测 x_test	钩子 a/gate.sh" GATE_CHANGED="tests/x_test.sh a/gate.sh"); t=$(tr1); c=$(cl)
ck "④ 点名夹钩子不走快路：两步都跑（trace ${t}，calls ${c}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "a x " ] && grep -q "route" $CALLS && ! grep -q "^快路：" $T/o4 && tail -1 $T/o4 | grep -qF "跑了 2 步 / 应跑 2 步"'
r=$(g o5 GATE_FAST=1 GATE_RERUN="单测 nope_test" GATE_CHANGED=tests/nope_test.sh)
ck "⑤ 快路点名不存在的单测：跑了 0 步（rc=${r}）" 'grep -qF "跑了 0 步 / 应跑 0 步" $T/o5 && ! grep -qF "跑了 1 步" $T/o5'
r=$(g o6 GATE_FAST=1 GATE_RERUN="语法"); c=$(cl)
ck "⑥ 快路点名语法：1 / 1 绿、不调路由（calls ${c}，rc=${r}）" '[ $r = 0 ] && [ -z "$c" ] && grep -q "^🟢 语法" $T/o6 && tail -1 $T/o6 | grep -qF "跑了 1 步 / 应跑 1 步"'
r=$(g o7 GATE_FAST=1 GATE_LAYER=pre GATE_RERUN="单测 x_test" GATE_CHANGED=tests/x_test.sh); c=$(cl)
ck "⑦ 分层时不走快路（calls ${c}，rc=${r}）" '[ $r = 0 ] && grep -q "route" $CALLS && ! grep -q "^快路：" $T/o7'
[ $bad = 0 ] && echo "gate_fast_step 单测全过" || { echo "gate_fast_step 单测有不通"; exit 1; }
