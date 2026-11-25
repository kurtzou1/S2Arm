#!/bin/bash
# 门禁覆盖：tools/gate.sh
# 空跑判红（11-24：一台门禁机的 Mac 局槽旧副本不认 share，门禁显卡步「退出 0、一行输出都没有」被记成绿，3 天 210 次）。假仓库真跑 tools/gate.sh。期望按规则手写：
#   ① 正常单测 foo（打一行、退 0）→ 🟢；静默单测 silent（什么都不打、退 0）→ 🔴 且点名「空跑」；整份门禁红（退 1）
#   ② 再跑一次：foo 走缓存命中照绿；silent 不许因缓存命中变绿（空跑不进单测缓存），仍 🔴 空跑
# 反证：S2A_GATE_SH=<旧版 gate.sh> 跑本单测应红（旧版把 silent 记 🟢 且缓存）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST GATE_LEDGER GATE_ROLE GATE_IN_STEP GATE_FAST
export S2A_REMOTE_FREE_GB=999 GATE_NO_LOADQ=1 S2A_RUN_ROOT=$T/run HOME=$T/home S2A_TRAIN_NO_POST=1 GATE_LEDGER=-
mkdir -p $T/home $T/repo/tools $T/repo/tests; cd $T/repo || exit 1
git init -q; git config user.email t@t; git config user.name t
cp "$GS" tools/gate.sh; cp $H/tools/test_cache.py $H/tools/gate_route.py $H/tools/gate_decl.py $H/tools/idle_timeout.sh $H/tools/safe_killpg.sh tools/
echo build/ > .gitignore; echo 'X=1' > tools/toolchain.env; echo ': # 单测桩' > tools/toolchain.sh
printf '#!/bin/bash\necho foo 过\n' > tests/foo_test.sh; printf '#!/bin/bash\nexit 0\n' > tests/silent_test.sh
git add -A; git commit -qm 1
bash tools/gate.sh > $T/o1 2>&1; r1=$?
ck "① foo 🟢（$(grep -a 'foo_test' $T/o1 | head -1 | cut -c1-80)）" 'grep -aq "^🟢 单测 foo_test" $T/o1'
ck "① silent 🔴 且点名空跑（$(grep -a 'silent_test' $T/o1 | head -1 | cut -c1-100)）" 'grep -aq "^🔴 单测 silent_test.*空跑" $T/o1'
ck "① 整份门禁红、退 1（实得 ${r1}）" '[ $r1 = 1 ] && grep -aq "^门禁 红" $T/o1'
bash tools/gate.sh > $T/o2 2>&1
ck "② 再跑 foo 缓存命中照绿" 'grep -aq "^🟢 单测 foo_test（缓存命中）" $T/o2'
ck "② silent 不因缓存变绿，仍 🔴 空跑（$(grep -a 'silent_test' $T/o2 | head -1 | cut -c1-100)）" 'grep -aq "^🔴 单测 silent_test.*空跑" $T/o2'
[ $bad = 0 ] && echo "gate_hollow_step 单测全过" || { echo "gate_hollow_step 单测有不通"; exit 1; }
