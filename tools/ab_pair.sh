#!/bin/bash
# 能力关 / 开对照局（名单线 10-28 梳理「合 2」：60 帧与满屏的 Mac 读数共用一个入口，取代各次手写的一次性起局脚本）：
#   bash tools/ab_pair.sh <款> fps60 [局目录]
#   bash tools/ab_pair.sh <款> widen:<档位> [局目录]      档位 19.5:9 / 16:10 / 1.42 / 4:3（同 docs/名单_满屏比例/ 表头）
# 同根、同存档、同进局路线（维护方 entry_check.sh，掌机档）先关后开各一局，然后跑该能力的判据，最后一行打印可登记的结论：
#   fps60  → S2A_FPS60=0 / 1 + S2A_AP_SPEED=1（MARK 后逻辑速度探测），判据 tools/fps_speed_judge.py（画面横移速度比 ρ≈1 绿、≈帧率倍数红）→ docs/名单_60帧/ 的「逻辑速度」
#   widen  → S2A_WIDEN_VERIFIED=0 / 1 + 档位屏幕尺寸，判据 tools/widen_accept.py（关局 MARK 截图当 16:9 对照）→ docs/名单_满屏比例/ 一行（平台 Mac）；
#            路线有 SHOT:scene_<名>（读盘页锚后固定帧的游戏场景）时两局同名截图当主判据对，MARK 帧只认「不过」；
#            另把开局进局路线沿途存的其余截图（shots/*.png，菜单页）逐张量占宽 / 占高 / 黑边，任一张不过整档不过
#            （10-28 0100152000022000 4:3：比赛 MARK 帧满屏，轮胎菜单页占高 75.4%、上下黑带——只判 MARK 漏菜单缺陷）
# 两局任一没到 MARK 就不判（退出 3），不拿半截局出结论。判据退出码原样透传：0 过 / 绿，1 不过 / 红，2 未验 / 判不出。
# --rejudge（放在最前）：不起局，对已跑完的同一局目录（第 3 个参数必给）重判——判据改了不重跑局。
# --write（放在最前，可与 --rejudge 同用）：满屏整档结论写进 docs/名单_满屏比例/，全过且没有不过时补 verified.tsv（widen_accept.py --write，只加不删）。
# 满屏判据三层：MARK 帧 + 关局对照（占宽 / 占高 / 黑边 / 拉伸 / 拉丝）、开局 host.log 上屏层（宿主每次出图判几何，截图只是游戏画幅量不到）、开局路线截图（菜单页）。
# 产物根照 entry_check：${S2A_ROOTS:-~/.s2arm/run/s2arm/roots} 里 <款> 的现行版本（指针文件 <款>@现行，pack/roots.sh root_cur_in）；在 gate-host / Spare-host 上跑时把 S2A_ROOTS 指到远端常驻根，不每局同步根：
#   bash 维护方工具 --host gate-host -- bash -c 'S2A_ROOTS=$HOME/rpack/roots bash tools/ab_pair.sh octopath2 widen:4:3'
set -u
RJ=0; WR=0
while :; do case ${1:-} in --rejudge) RJ=1; shift;; --write) WR=1; shift;; *) break;; esac; done
G=${1:?款}; CAP=${2:?fps60 或 widen:<档位>}
R=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
D=${3:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/ab_pair/${G}_${CAP//[:.]/_}_$(date +%m%d%H%M)}
case $CAP in
  fps60) KEY=S2A_FPS60; SCR=();;
  widen:19.5:9) KEY=S2A_WIDEN_VERIFIED; SCR=(S2A_SCREEN_W=2340 S2A_SCREEN_H=1080);;
  widen:16:10) KEY=S2A_WIDEN_VERIFIED; SCR=(S2A_SCREEN_W=1920 S2A_SCREEN_H=1200);;
  widen:1.42) KEY=S2A_WIDEN_VERIFIED; SCR=(S2A_SCREEN_W=1920 S2A_SCREEN_H=1350);;
  widen:4:3) KEY=S2A_WIDEN_VERIFIED; SCR=(S2A_SCREEN_W=1920 S2A_SCREEN_H=1440);;
  *) echo "🔴 能力只认 fps60 / widen:<19.5:9|16:10|1.42|4:3>"; exit 2;;
esac
[ $RJ = 1 ] && { [ -s "$D/off/host.log" ] && [ -s "$D/on/host.log" ] || { echo "🔴 --rejudge：$D 下没有 off / on 两局"; exit 2; }; }
mkdir -p "$D"
for m in off on; do [ $RJ = 1 ] && break; v=0; [ $m = on ] && v=1
  echo "== $G $CAP ${m}（${KEY}=${v}）"
  env "$KEY=$v" ${SCR[@]+"${SCR[@]}"} $([ "$CAP" = fps60 ] && echo S2A_AP_SPEED=1) COST_LINE=名单 COST_WHY="能力对照 $G $CAP $m" bash "${S2A_PRIVATE_TOOLS:?跑局对照要设 S2A_PRIVATE_TOOLS（--rejudge 离线重判不需要）}/entry_check.sh" "$G" handheld "$D/$m"; rc=$?
  [ $rc = 0 ] || { echo "🔴 $G $CAP $m 局没到 MARK（entry_check 退出 ${rc}），不判；局目录 $D/$m"; exit 3; }
done
if [ "$CAP" = fps60 ]; then
  # 逻辑速度：两局都带 S2A_AP_SPEED=1，自动玩家 MARK 后按时钟推摇杆量画面横移速度（tests/autoplay/autoplay.c speed_probe），判据比两局速度比与帧率比
  "$PY" "$R/tools/fps_speed_judge.py" "$D/off" "$D/on"; exit $?
fi
TID=$(LC_ALL=C grep -a -o -m1 '程序号 [0-9a-f]\{16\}' "$D/on/host.log" | awk '{print toupper($2)}')
BID=$(LC_ALL=C grep -a -o -m1 '主程序构建号 [0-9a-f]\{32\}' "$D/on/host.log" | awk '{print $2}')
W=("$PY" "$R/tools/widen_accept.py" --game "$G" --tid "${TID:-0000000000000000}" --build "${BID:-0}" --profile "${CAP#widen:}" --platform Mac)
# 主判据对：路线 SHOT:scene_<名> 两局同名截图（读盘页锚后同一帧拍 = 同一游戏时刻）优先，没有才用 MARK 帧——MARK 落在哪一刻取决于
#   探测前视觉判读等了多久（10-28 0100152000022000 4:3：开局一题等 52.6 秒，两局 MARK 差 2684 帧、比赛不同时刻，拉伸量不出）
P=(); for f in "$D"/on/shots/scene_*.png; do [ -f "$f" ] && [ -f "$D/off/shots/${f##*/}" ] && P+=("$f" "$D/off/shots/${f##*/}"); done
P+=("$D/on/ap_mark.png" "$D/off/ap_mark.png")
final=$("${W[@]}" --image "${P[0]}" --reference "${P[1]}" --host-log "$D/on/host.log"); rc=$?
echo "$final"
for ((i = 2; i < ${#P[@]}; i += 2)); do   # 其余场景对、以及有场景对时的 MARK 帧：只认「不过」（MARK 两局不同时刻，拉伸判不出不算数）
  row=$("${W[@]}" --image "${P[i]}" --reference "${P[i + 1]}"); r=$?
  [ $r = 1 ] && { echo "$row"; [ $rc = 1 ] || final=$row; rc=1; }
done
for f in "$D"/on/shots/*.png; do   # 菜单页：占宽 / 占高 / 黑边 / 拉丝，16:9 居中纯黑留边算按设计（--page）；关局有同名页时再量界面横向比；只认「不过」
  [ -f "$f" ] || continue; case ${f##*/} in scene_*) continue;; esac
  U=(); [ -f "$D/off/shots/${f##*/}" ] && U=(--ui-reference "$D/off/shots/${f##*/}")   # 关局同名页 = 同一界面页 k=1 对照：量界面横向比（10-30，不同页 widen_accept 自己记未验）
  row=$("${W[@]}" --page --image "$f" ${U[@]+"${U[@]}"}); r=$?
  [ $r = 1 ] && { echo "$row"; [ $rc = 1 ] || final=$row; rc=1; }
done
if [ $WR = 1 ] && [ $rc != 2 ]; then
  CH=$(sed -n 's/^#define DMSH_CHAIN "\([0-9a-f]*\)".*/\1/p' "$R/graphics/nvn/gfx/nvn/dmsh_chain.h")
  final=$(printf '%s\n' "$final" | awk -F'\t' -v OFS='\t' -v e="链 ${CH}，tools/ab_pair.sh 关 / 开对照局 ${D}（$(hostname -s)）" '{$9 = e; print}')
  "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1] + "/tools"); import widen_accept as w; [print(n) for n in w.write_tables(__import__("pathlib").Path(sys.argv[1]), sys.argv[2])]' "$R" "$final"
fi
exit $rc
