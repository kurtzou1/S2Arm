#!/bin/bash
# 门禁只看：graphics/nvn/tests/t_present_settings.sh tests/present_settings_term_test.sh
# 上屏设置矩阵被 SIGTERM（门禁步超时）时先把正在跑的那一格的现场写进本步输出再退出（11-27）：不用显卡，约 1 秒。
#   从 t_present_settings.sh 原样抽出 stuck_awk 与「门禁到点」那段（cells_done= 到 trap on_term），造一格假现场（run.log 含【卡】行与心跳），
#   前台 wait 一个睡着的子进程时发 SIGTERM。期望（手写）：退出码 143；输出有「已跑完 3 格」「正在跑：mtl4-SmaaMedium-Bilinear」、
#   「✗ 卡 …｜【卡】…」、「✗ 红 …」（已知 npdm 红行滤掉）、「✗ 尾 …」（心跳行被滤掉）；子进程被收掉。反证：脚本里没有这段（main 11-27 之前）→ 抽不出、本测不通
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
S="$H/graphics/nvn/tests/t_present_settings.sh"
awk_part=$(awk "/^stuck_awk='/{f=1} f{print} f&&/^'\$/{exit}" "$S")
term_part=$(awk '/^cells_done=0; /{f=1} f{print} f&&/^trap on_term TERM INT$/{exit}' "$S")
ck "脚本里有 SIGTERM 现场那段（cells_done= … trap on_term）" '[ -n "$term_part" ] && [[ "$term_part" == *"trap on_term TERM INT"* ]]'
mkdir -p "$T/cell"
printf '启动\n【红】地址窗口：读不到本款 main.npdm（可执行文件同目录 / 模块目录），不知道要多大，不占窗口\n[dm] [nvn-mtl] 【红】 present ticket 1: drawable taken but not presented (Metal 3 encode failed; the reason is the line above)\n【卡】mtl4-SmaaMedium-Bilinear ticket 3 等呈现回调 6.0 秒：遮挡=是\n[s2a] [心跳] 帧 0\n最后一步：等呈现\n' > "$T/cell/run.log"
cat > "$T/h.sh" <<EOF
set -u
$awk_part
$term_part
sleep 30 & pid=\$!; echo \$pid > "$T/child"
cells_done=3; name=mtl4-SmaaMedium-Bilinear; runtime="$T/cell"
wait "\$pid"
echo 不该走到这里
EOF
bash "$T/h.sh" > "$T/out" 2>&1 & hp=$!
for i in $(seq 1 50); do [ -s "$T/child" ] && break; sleep 0.1; done; sleep 0.2
kill -TERM $hp; wait $hp; rc=$?
o=$(cat "$T/out"); child=$(cat "$T/child" 2> /dev/null)
ck "退出码 143（rc=${rc}）" '[ "$rc" = 143 ]'
ck "点名已跑完格数与正在跑的格" '[[ "$o" == *"已跑完 3 格"* && "$o" == *"正在跑：mtl4-SmaaMedium-Bilinear"* ]]'
ck "带出【卡】行" 'grep -q "^✗ 卡 mtl4-SmaaMedium-Bilinear｜【卡】" <<< "$o"'
ck "带出日志尾、滤掉心跳" 'grep -q "^✗ 尾 mtl4-SmaaMedium-Bilinear｜最后一步：等呈现" <<< "$o" && ! grep -q "✗ 尾.*心跳" <<< "$o"'
ck "带出这一格的红行、滤掉已知的 npdm 那条" 'grep -q "^✗ 红 mtl4-SmaaMedium-Bilinear｜.*drawable taken but not presented" <<< "$o" && ! grep -q "✗ 红.*main.npdm" <<< "$o"'
ck "没往下走" '! grep -q 不该走到这里 <<< "$o"'
ck "子进程收掉" '! kill -0 "$child" 2> /dev/null'
[ $bad = 0 ] && echo "✓ present_settings_term：被结束时现场写进本步输出" || { echo "$o" | head -12; echo "✗ present_settings_term 有不通"; exit 1; }
