#!/bin/bash
# 门禁手动：要私有游戏数据：起游戏局录逐绘制对拍录像（要传款与局目录）
# 双后端逐绘制对拍的录像（画面·着色器线）：tests/visual/diff_rec.sh <款> <局目录> [MARK 后跳过上屏数] [录上屏数]
# 程序必须全部以 SPIR-V 建（CreateProgram），参照（Ryujinx Vulkan @ MoltenVK）才建得出：包内着色器局 Ryujinx 从包里种的磁盘缓存载主机二进制（LoadProgramBinary），
#   参照全部 NotImplemented、绘制不执行，上屏图却可能逐位相同——假通过（10-20 画幅线）。做法：私有数据根（没有 Ryujinx 着色器缓存）+ 私有着色器包目录 = 产物根着色器包
#   去掉 shcache/（只克隆离线库 gal.* / 管线归档 / 宽屏元数据）：Ryujinx 首遇现翻出 SPIR-V 交 CreateProgram，我方按 SPIR-V 键直取包内函数（同产品、不现编）。
#   10-21 实测纯空包（S2A_SHADER_PACK=<空目录>，首遇全部现编）在整机负载 90+ 时动森 / 暗黑2 / 暗黑3 都卡在读盘页、出图停 60 秒被自动玩家收局，到不了 MARK。
#   DIFF_EMPTY_PACK=1 仍用纯空包。
# 录窗：自动玩家打 MARK 后跳过 K 次上屏再录 N 次（S2A_GALREC_FRAMES=mark+K:N，缺省 30 / 90）；起局 150 秒（DIFF_FALLBACK_S）还没 MARK 照样开窗、不跳（到不了 MARK 的款也录一段，rec.txt 注明）。
# DIFF_FRAMES=a-b：按上屏序号定窗（到不了 MARK、又在退路时刻之前就停帧的款：暗黑2 标题页、巫师3 读盘页）。
# 起局：先用干净 origin/main 树刷现行产物根（DIFF_MAIN_TREE，分支树刷不了共享根），本树 runtime/run_mac.sh 起局（本树宿主带按 MARK 开窗）；
#   存档同 tools/mac_health.sh（saves/<款>_<main 构建号>，暗黑2 的是 维护者 真机账号存档）；DIFF_D2R_OWN=1 改用 own_saves/ 测试设备1 备份拷进私有数据根
#   （10-21 实测这样拷进 bis/user/save 的暗黑2 角色页是空的，没认出存档）。
# 出：<局目录>/rec/gal.rec、rec.txt（录窗、MARK、大小）；局 ≤300 秒（run_mac.sh 270 秒 + 宿主墙钟上限 30 秒；外层 1800 秒只兜排 Mac 槽的等待）。
set -u
G=${1:?款}; D=${2:?局目录}; K=${3:-30}; N=${4:-90}
# 跑长批时用冻结副本（脚本边跑边读，原地改会错位）：副本里 DIFF_TREE=<起局用的代码树>
H=$(cd "$(dirname "$0")" && pwd); R=${DIFF_TREE:-$(cd "$H/../.." && pwd)}; MAIN=${DIFF_MAIN_TREE:?DIFF_MAIN_TREE=<干净 origin/main 树>}
S=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm; [ -e "$D/host.log" ] && { echo "🔴 局目录 $D 已用过（有 host.log），换一个"; exit 1; }; mkdir -p "$D/pack" "$D/ryu" "$D/gal" "$D/macro"
# DIFF_NO_REFRESH=1：不刷产物根（刷新的着色器阶段会排出包槽重烘；出包槽被占 / 维护者禁新出包时用，录像只用现行根里的改写产物与离线库，rec.txt 记现行版本）
if [ "${DIFF_NO_REFRESH:-0}" = 1 ]; then echo "未刷新，现行 $(basename "$(cd -P "$S/roots/$(cat "$S/roots/$G@现行")" && pwd)")" > "$D/refresh.log"
else bash "$MAIN/pack/refresh.sh" "$G" > "$D/refresh.log" 2>&1 || { echo "🔴 $G 产物根刷新红：$(tail -1 "$D/refresh.log")"; exit 1; }; fi
src=$(cd -P "$S/roots/$(cat "$S/roots/$G@现行")" && pwd); sn=$D/in_snap
python3 "$R/tools/clonedir.py" "$src" "$sn" || { echo "🔴 $G 快照失败"; exit 1; }
BID=$(xxd -s 0x40 -l 16 -p "$sn/exefs/main"); X=()
if [ "${DIFF_EMPTY_PACK:-0}" != 1 ]; then
  for f in "$sn"/shaders/*; do [ -f "$f" ] && cp -c "$f" "$D/pack/"; done
  [ -f "$D/pack/gal.idx" ] || { echo "🔴 $G 产物根没有着色器包离线库（$sn/shaders/gal.idx）"; exit 1; }
fi
if [ "$G" = d2r ] && [ "${DIFF_D2R_OWN:-0}" = 1 ]; then
  J=$(ls -d "$S"/own_saves/d2r_testphone1_* | sort | tail -1)
  mkdir -p "$D/ryu/bis/user/save"; cp -cR "$J/user_save/"* "$D/ryu/bis/user/save/" || { echo "🔴 暗黑2 存档拷贝失败"; exit 1; }
  echo "存档：${J}（拷进私有数据根）" > "$D/save.txt"
else
  SA=$S/saves/${G}_$BID
  if [ -d "$SA" ]; then X+=("S2A_SAVE_DIR=$SA"); for k in system_time:S2A_SYSTEM_TIME language:S2A_SYSTEM_LANGUAGE region:S2A_REGION timezone:S2A_TIMEZONE; do
    [ -s "$SA/${k%%:*}" ] && X+=("${k#*:}=$(cat "$SA/${k%%:*}")"); done; echo "存档：$SA" > "$D/save.txt"; else echo "存档：无" > "$D/save.txt"; fi
fi
env ${X[@]+"${X[@]}"} S2A_CS=1 S2A_GFX=generic S2A_SHADER_PACK="$D/pack" S2A_GALREC="$D/rec" S2A_GALREC_FRAMES="${DIFF_FRAMES:-mark+$K:$N}" S2A_GALREC_MARK_FALLBACK_S=${DIFF_FALLBACK_S:-150} S2A_GALREC_MAX_MB=${DIFF_REC_MB:-1800} \
  S2A_MACRO_DUMP="$D/macro" S2A_RYU_DATA="$D/ryu" NXGAL_SHADER_CACHE_DIR="$D/gal" S2A_IN="$sn" COST_LINE=画面着色器 COST_WHY="双后端对拍录像（程序全以 SPIR-V 建）${G}" \
  timeout 1800 bash "$R/runtime/run_mac.sh" "$G" "$D" "${DIFF_REC_SEC:-270}" > "$D/run.out" 2>&1; rc=$?
chmod -R u+w "$sn" 2> /dev/null; rm -rf "$sn"
L=$D/host.log
mk=$(LC_ALL=C /usr/bin/grep -a -o 'S2A 标记 MARK：帧 [0-9]*' "$L" | head -1)
win=$(LC_ALL=C /usr/bin/grep -a '\[录像\] .*开窗：上屏' "$L" | head -1 | sed 's/^\[录像\] //')
sz=$(stat -f %z "$D/rec/gal.rec" 2>/dev/null || echo 0)
{ echo "款 ${G}；局 rc=${rc}；${mk:-没到 MARK}；${win:-录窗没开}；录像 $((sz >> 20)) MB；构建号 $BID"; cat "$D/save.txt"; tail -1 "$D/refresh.log"; } > "$D/rec.txt"
cat "$D/rec.txt"
[ -n "$win" ] && [ "$sz" -gt 0 ]
