#!/bin/bash
# 门禁只看：tools/gate.sh tools/gate_decl.py tools/gate_ios.sh tests/*_test.* */gate.sh
# （层声明写在单测 / 钩子文件头，任何单测或钩子改动都可能改 ⑥ 的名单：11-05 work_cleaner_test 新声明合入后、本测没被路由，合入后 main 红。本测约 5 秒）
# 门禁分层（tools/gate.sh GATE_LAYER + 钩子文件头「# 门禁层：合入后」，tools/gate_decl.py layer 收）。约 10 秒。
# 假仓库：语法 + 单测 x_test（不写 = 合入前）、y_test（声明合入后）+ 钩子 a（声明合入后）、b（不写 = 合入前）；各步把自己的名字记进 trace。
# 期望（按规则手写）：
#   ① 不设 GATE_LAYER：5 步全跑、无「另一层」行；② pre：a、y 不跑，3 / 3 绿，结论前「另一层：单测 y_test 钩子 a/gate.sh」
#   ③ post：只跑 a、y，2 / 2 绿，「另一层」列语法、单测 x_test、钩子 b/gate.sh；④ GATE_LIST=1 三种同样按层过滤；⑤ GATE_LAYER 写错 → 退出 1
#   ⑥ 本仓库声明：合入后 = android、graphics、tests/visual、launchers/macos 四个钩子 + iOS 全量编译（路由命中时合入前也跑），其余不在
# 反证：S2A_GATE_SH=<旧版 gate.sh> 跑本单测应红（旧版不认 GATE_LAYER：② a 照跑）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST
export GATE_NO_LOADQ=1 HOME=$T/home
mkdir -p $T/home $T/repo/tools $T/repo/tests $T/repo/a $T/repo/b; cd $T/repo || exit 1
git init -q; git config user.email t@t; git config user.name t
cp "$GS" tools/gate.sh; cp $H/tools/gate_decl.py tools/
printf '#!/bin/bash\necho x >> %s/trace\n' "$T" > tests/x_test.sh
printf '#!/bin/bash\n# 门禁层：合入后\necho y >> %s/trace\n' "$T" > tests/y_test.sh
printf '#!/bin/bash\n# 门禁层：合入后\necho a >> %s/trace; echo a 过\n' "$T" > a/gate.sh
printf '#!/bin/bash\necho b >> %s/trace; echo b 过\n' "$T" > b/gate.sh
git add -A; git commit -qm 1
g() { : > $T/trace; bash tools/gate.sh > "$T/$1" 2>&1; echo $?; }
tr1() { sort $T/trace | tr '\n' ' '; }

r=$(g o1); t=$(tr1)
ck "① 不设：全跑（trace ${t}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "a b x y " ] && tail -1 $T/o1 | grep -qF "跑了 5 步 / 应跑 5 步" && ! grep -q "^另一层" $T/o1'
r=$(GATE_LAYER=pre g o2); t=$(tr1)
ck "② pre：a、y 不跑、3 / 3 绿、另一层列 y、a（trace ${t}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "b x " ] && tail -1 $T/o2 | grep -qF "门禁 绿：full 档，跑了 3 步 / 应跑 3 步" && grep -qxF "另一层：单测 y_test 钩子 a/gate.sh" $T/o2'
r=$(GATE_LAYER=post g o3); t=$(tr1)
ck "③ post：只跑 a、y，2 / 2 绿、另一层列其余（trace ${t}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "a y " ] && tail -1 $T/o3 | grep -qF "跑了 2 步 / 应跑 2 步" && grep -qxF "另一层：语法 单测 x_test 钩子 b/gate.sh" $T/o3'
l0=$(GATE_LIST=1 bash tools/gate.sh 2> /dev/null | tr '\n' '|'); l1=$(GATE_LIST=1 GATE_LAYER=pre bash tools/gate.sh 2> /dev/null | tr '\n' '|'); l2=$(GATE_LIST=1 GATE_LAYER=post bash tools/gate.sh 2> /dev/null | tr '\n' '|')
ck "④ GATE_LIST 按层过滤（不设 ${l0} / pre ${l1} / post ${l2}）" '[ "$l0" = "语法|单测 x_test|单测 y_test|钩子 a/gate.sh|钩子 b/gate.sh|" ] && [ "$l1" = "语法|单测 x_test|钩子 b/gate.sh|" ] && [ "$l2" = "单测 y_test|钩子 a/gate.sh|" ]'
r=$(GATE_LAYER=later g o5)
ck "⑤ GATE_LAYER 写错 → 退出 1（rc=${r}）" '[ $r = 1 ]'
d=$(cd "$H" && python3 tools/gate_decl.py layer | tr '\n' '|')
ck "⑥ 本仓库合入后声明（${d}）" '[ "$d" = "钩子 android/gate.sh	合入后|钩子 graphics/gate.sh	合入后|钩子 launchers/macos/gate.sh	合入后|钩子 tests/visual/gate.sh	合入后|iOS 全量编译	合入后	路由|" ]'
# ⑦ 显卡独占：单测文件头「# 门禁显卡：独占」→ 经 维护方工具 prio 跑（桩记 prio 名），普通单测不经（11-06 present_settings 被并行窗口抢焦点）
printf '#!/bin/bash\n# 门禁显卡：独占\necho z >> %s/trace\n' "$T" > tests/z_test.sh
mkdir -p $T/priv; printf '#!/bin/bash\ncase $1 in prio) echo "prio $2" >> %s/prio; shift 4;; share) echo "share $2" >> %s/prio; shift 3;; esac; exec "$@"\n' "$T" "$T" > $T/priv/mac_slot_frozen.sh; chmod +x $T/priv/mac_slot_frozen.sh; export S2A_PRIVATE_TOOLS=$T/priv
git add -A; git commit -qm 2; : > $T/prio; r=$(g o7); t=$(tr1); pr=$(tr '\n' '|' < $T/prio)
ck "⑦ 显卡独占单测经 prio 锁跑、普通单测不经（trace ${t}，prio ${pr}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "a b x y z " ] && [ "$pr" = "prio 单测 z_test|" ]'
# ⑦b 显卡共享（11-20 读写锁）：单测文件头「# 门禁显卡：共享」→ 经 维护方工具 share 跑（桩记 share 名）
printf '#!/bin/bash\n# 门禁显卡：共享\necho w >> %s/trace\n' "$T" > tests/w_test.sh
git add -A; git commit -qm 2b; : > $T/prio; r=$(g o7b); t=$(tr1); pr=$(sort $T/prio | tr '\n' '|')
ck "⑦b 显卡共享单测经 share 跑、独占经 prio、普通不经（trace ${t}，锁 ${pr}，rc=${r}）" '[ $r = 0 ] && [ "$t" = "a b w x y z " ] && [ "$pr" = "prio 单测 z_test|share 单测 w_test|" ]'
ck "⑧ 本仓库声明显卡独占的单测含 present_settings_test" 'head -6 $H/tests/present_settings_test.sh | grep -q "^# 门禁显卡：独占"'
# ⑨ 「合入后（路由命中时合入前也跑）」（11-10：安卓支 / ios 头改动合入前不跑对应钩子，一天叠多处 main 红）：钩子 c 这样声明、路由 c/。
#   期望（按规则手写）：pre + 改动路由到 c → c 跑；pre + 改动没路由到 c → c 不跑；post + 路由到 c → c 跑；
#   pre 但没给改动集（RT=0，不知道改了什么）→ c 不跑（合入前层保守不加跑）；声明收成第 3 列「路由」
cp $H/tools/gate_plan.sh $H/tools/gate_route.py tools/   # 给了 GATE_CHANGED 时门禁按改动集定档位、按路由选步
printf '#!/bin/bash\n# 门禁路由：b/\necho b >> %s/trace; echo b 过\n' "$T" > b/gate.sh   # b/ 有人认领，⑨b 才测得到「路由到别的钩子」（没人认领的代码路径路由器按宁多勿漏全跑）
mkdir -p c; printf '#!/bin/bash\n# 门禁层：合入后（路由命中时合入前也跑）\n# 门禁路由：c/\necho c >> %s/trace; echo c 过\n' "$T" > c/gate.sh
git add -A; git commit -qm 3
r=$(GATE_LAYER=pre GATE_CHANGED="c/x.c" g o9a); ck "⑨a pre + 路由到 c：c 跑（trace $(tr1)，rc=${r}）" '[ $r = 0 ] && grep -qx c $T/trace'
r=$(GATE_LAYER=pre GATE_CHANGED="b/x.c" g o9b); ck "⑨b pre + 没路由到 c：c 不跑（trace $(tr1)，rc=${r}）" '[ $r = 0 ] && ! grep -qx c $T/trace'
r=$(GATE_LAYER=post GATE_CHANGED="c/x.c" g o9c); ck "⑨c post + 路由到 c：c 跑（trace $(tr1)，rc=${r}）" '[ $r = 0 ] && grep -qx c $T/trace'
r=$(GATE_LAYER=pre g o9e); ck "⑨e pre 没给改动集：c 不跑（trace $(tr1)，rc=${r}）" '[ $r = 0 ] && ! grep -qx c $T/trace'
d9=$(cd $T/repo && python3 tools/gate_decl.py layer | grep "c/gate.sh" | tr '\t' '|'); ck "⑨d 声明收成第 3 列「路由」（${d9}）" '[ "$d9" = "钩子 c/gate.sh|合入后|路由" ]'
[ $bad = 0 ] && echo "gate_layer 单测全过" || { echo "gate_layer 单测有不通"; exit 1; }
