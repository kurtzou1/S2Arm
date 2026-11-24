#!/bin/bash
# 门禁覆盖：tools/gate.sh
# 显卡锁要在拼步骤时就认得私有工具（11-24：S2A_PRIVATE_TOOLS 原先到后面「门禁机配置自找」才从 machine.local 补上，各线自检不带这个变量，
#   「门禁显卡：独占」的 present_settings_test 一律裸跑、不拿锁，和开窗口的组同时跑挂起）。临时仓库，约 5 秒。期望手写：
#   ① 调用方不带 S2A_PRIVATE_TOOLS、本树 tools/machine.local 写了它 → 独占单测经私有工具 mac_slot_frozen.sh prio 跑（记录文件有 prio + 步名），单测本身照跑绿；
#   ② 共享单测经 share 跑；③ 反证：machine.local 里没有 → 不套锁、单测照跑（公开仓贡献者没有私有工具不受影响）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_BUDGET_Q S2A_PRIVATE_TOOLS S2A_MACHINE_LOCAL
mkdir -p $T/r/tools $T/r/tests $T/priv; cd $T/r || exit 1; cp $H/tools/gate.sh $H/tools/gate_plan.sh tools/
printf '#!/bin/bash\necho "$1 $2" >> %s/lock.log; while [ "$1" != -- ]; do shift; done; shift; exec "$@"\n' "$T" > $T/priv/mac_slot_frozen.sh
printf '#!/bin/bash\n# 门禁显卡：独占\ntouch %s/ranX; echo "X 期望 → 真结果 绿"\n' "$T" > tests/x_test.sh
printf '#!/bin/bash\n# 门禁显卡：共享\ntouch %s/ranS; echo "S 期望 → 真结果 绿"\n' "$T" > tests/s_test.sh
printf "S2A_PRIVATE_TOOLS='%s/priv'\n" "$T" > tools/machine.local
git init -q; git config user.email t@t; git config user.name t; git add -A; git commit -qm 1
o=$(GATE_HOOK_S=30 bash tools/gate.sh 2>&1)
ck "① 不带变量、machine.local 有 → 独占单测走 prio、照跑绿" 'grep -q "^prio 单测 x_test$" $T/lock.log && [ -e $T/ranX ] && grep -q "🟢 单测 x_test" <<< "$o"'
ck "② 共享单测走 share" 'grep -q "^share 单测 s_test$" $T/lock.log && [ -e $T/ranS ]'
rm -f $T/lock.log $T/ranX; git rm -q tools/machine.local; git commit -qm 2
o=$(GATE_HOOK_S=30 bash tools/gate.sh 2>&1)
ck "③ 反证：没有 machine.local → 不套锁、独占单测照跑绿" '[ ! -e $T/lock.log ] && [ -e $T/ranX ] && grep -q "🟢 单测 x_test" <<< "$o"'
cd $H
[ $bad = 0 ] && echo "gate_gpu_lock_selffind 单测全过" || { echo "gate_gpu_lock_selffind 单测有不通"; echo "$o" | tail -5; exit 1; }
