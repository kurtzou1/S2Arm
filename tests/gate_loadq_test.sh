#!/bin/bash
# 门禁负载排队单测（10-24 维护者 重新分工：本机 15 分钟负载超过 36 时新门禁先排队，双轨 / 列车豁免）：bash tests/gate_loadq_test.sh，约 10 秒
# 期望（按规则手写）：CPU 实际空闲 3% < 15% → 打「先排队」、等到上限（2 秒）照跑并打黄字；GATE_DUAL=1 / GATE_NO_LOADQ=1 → 不排；空闲 60% → 不排；读不到空闲 → 不排
# 假仓库一支空单测（1 步）；0 步用例用 GATE_RERUN 选一个不存在的步
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 只测排队机制，使用无 Apple 工具链/路由器的合成仓；真实 Linux 仓会按合同拒绝不存在的步骤，尚未走到排队。
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/tools"
cp "$H/tools/gate.sh" "$H/tools/gate_plan.sh" "$T/tools/"
mkdir -p "$T/tests"; printf '#!/bin/bash\nexit 0\n' > "$T/tests/a_test.sh"   # 有 1 步可跑（11-11 起排队挪到算出步数之后：0 步不排）
git -C "$T" init -q
# 外层门禁的角色变量不许漏进来（11-11：列车起的门禁带 GATE_NO_LOADQ=1，改 tools/gate.sh 的支在列车里跑本单测，「先排队」那条恒红）
g() { (cd "$T" && env -u GATE_NO_LOADQ -u S2A_GATE_CPU_IDLE_MIN -u GATE_DUAL -u GATE_ROLE -u GATE_RERUN -u GATE_PLAN -u GATE_LAYER "$@" S2A_GATE_LOAD_WAIT_S=2 S2A_GATE_LOAD_POLL_S=0.5 GATE_HOST=local GATE_TIER=tool GATE_CHANGED="tools/gc.sh" GATE_TEST_CACHE=0 GATE_LEDGER=- timeout 600 bash tools/gate.sh 2>&1); }
o1=$(g S2A_GATE_IDLE_TEST=3); o2=$(g S2A_GATE_IDLE_TEST=3 GATE_DUAL=1); o3=$(g S2A_GATE_IDLE_TEST=3 GATE_NO_LOADQ=1); o4=$(g S2A_GATE_IDLE_TEST=60)
ck "CPU 空闲 3%：先排队、到上限照跑（打黄字）" 'grep -q "门禁先排队" <<< "$o1" && grep -q "到上限照跑" <<< "$o1"'
ck "双轨门禁（GATE_DUAL=1）、列车门禁（GATE_NO_LOADQ=1）：CPU 空闲 3% 也不排" '! grep -q "CPU 实际空闲" <<< "$o2" && ! grep -q "CPU 实际空闲" <<< "$o3"'
ck "CPU 空闲 60%：不排" '! grep -q "CPU 实际空闲" <<< "$o4"'
# 11-11：热修（GATE_ROLE=热修）不排；0 步不排（排队挪到算出步数之后——热修 post 层 0 步原先白等 601 秒）
o6=$(g S2A_GATE_IDLE_TEST=3 GATE_ROLE=热修); o7=$(g S2A_GATE_IDLE_TEST=3 GATE_RERUN="没有这一步")
ck "热修门禁（GATE_ROLE=热修）：CPU 空闲 3% 也不排" '! grep -q "CPU 实际空闲" <<< "$o6"'
ck "0 步（要跑的步本树都不涉及）：CPU 空闲 3% 也不排" '! grep -q "CPU 实际空闲" <<< "$o7" && grep -q "跑了 0 步" <<< "$o7"'
# 读不到负载（Linux 没有 vm.loadavg；审计 #829 F-gate-loadq-comment：跳出写在了行尾注释里被吃掉，空等满上限）→ 不排、不打负载行
FB=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$FB/top"; chmod +x "$FB/top"; o5=$(g PATH="$FB:$PATH"); rm -rf "$FB"
ck "读不到 CPU 空闲（没有 top）：不排、不打排队行" '! grep -q "CPU 实际空闲" <<< "$o5"'
[ $bad = 0 ] && echo "gate_loadq 单测全过" || { echo "gate_loadq 单测有不通"; exit 1; }
