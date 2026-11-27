#!/bin/bash
# 门禁覆盖：tools/gate.sh
# 门禁被停（TERM）时把仍在跑的步的日志尾打出来再退（11-27 present_settings：门禁到点整份 TERM，5 次红的门禁日志只有进度行，
#   测试被 TERM 时自己写的【卡】摘要留在临时目录的步日志里随之删掉）。临时仓库两个钩子，期望手写：
#   ① 快步 a 跑完、慢步 b 在跑时 TERM 门禁：门禁输出有「✗ 门禁被停时仍在跑：bash b/gate.sh」、有 b 起跑时打的「b 起」
#   ② b 自己收到 TERM 时写的「【卡】停在第 3 格」也在门禁输出里（门禁先停步、等它写完再打）
#   ③ 跑完的 a 不在「仍在跑」名单里；门禁退出码 143
# 反证：S2A_GATE_SH=<旧 gate.sh> 跑应红（①② 都没有）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}; G=
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap '[ -n "$G" ] && kill -KILL "$G" 2> /dev/null; pkill -KILL -f "$T/" 2> /dev/null; rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST GATE_IN_STEP GATE_ROLE
export GATE_NO_LOADQ=1 HOME=$T/home TMPDIR=$T/tmp PATH="$H/tools/bin:$PATH" GATE_NOSTALL_S=0 GATE_DET_STOP=0
mkdir -p $T/home $T/tmp $T/repo/tools $T/repo/a $T/repo/b; cd $T/repo || exit 1
git init -q; git config user.email t@t; git config user.name t
cp "$GS" tools/gate.sh; cp $H/tools/gate_decl.py $H/tools/safe_killpg.sh $H/tools/gate_reap.py tools/
printf '#!/bin/bash\necho a 过\n' > a/gate.sh
printf '#!/bin/bash\ntrap "echo 【卡】停在第 3 格; exit 143" TERM\necho b 起; touch %s/b.up; sleep 120 & wait $!\n' "$T" > b/gate.sh
git add -A; git commit -qm 1
(exec bash tools/gate.sh > $T/g.out 2>&1) & G=$!
for _ in $(seq 150); do [ -e $T/b.up ] && grep -q 'a 过' $T/g.out 2> /dev/null && break; [ -e $T/b.up ] && sleep 1 && break; sleep 0.2; done
kill -TERM $G; wait $G; rc=$?; G=
o=$(cat $T/g.out)
ck "① 门禁输出点名仍在跑的 b、带它的日志尾（rc ${rc}）" 'grep -q "✗ 门禁被停时仍在跑：bash b/gate.sh" <<< "$o" && grep -q "┆ b 起" <<< "$o"'
ck "② b 被 TERM 时写的【卡】摘要进了门禁输出" 'grep -q "┆ 【卡】停在第 3 格" <<< "$o"'
ck "③ a 不在仍在跑名单、退出码 143" '! grep -q "仍在跑：bash a/gate.sh" <<< "$o" && [ "$rc" = 143 ]'
[ $bad = 0 ] || { echo "== 门禁输出"; tail -20 $T/g.out; }
exit $bad
