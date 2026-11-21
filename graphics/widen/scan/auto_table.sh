#!/bin/bash
# 宽屏第二层自动出表（画幅线，10-24 维护者「新游戏出包时自动出宽屏」）：graphics/widen/scan/auto_table.sh <款>
#   出包（pack/ipa.sh、一键出包）发现现行产物根这一构建号、这一档位既没有仓库表（graphics/widen/tables，人工验过的，优先）也没有自动表时，
#   由 graphics/widen/scan/auto_kick.sh 在后台起本脚本；本次出包不等它，下一个包带上（pack/stage_rewrite.sh 仓库没表时读自动表）。
# 步骤（判据全是 closed_loop.sh 那一套，不另设：0 崩、到 MARK、点都执行到、出图满宽、3D 镜头比 = 屏幕比、露空 ≤0.5%、界面裁剪不多切）：
#   ① 探测局：全部候选（去界面镜头点 asp、界面拷屏点 lytsz / capsz——它们要界面路线才判得了）开、屏幕宽 1922（≈ 不改行为），收真执行到的点与 MARK 帧；
#      探测局开全部候选崩了：崩前执行到的点当嫌疑剔出候选重探（最多 3 轮，11-01 怒之铁拳4 起），剔掉的点不进组合
#   ② 先验：同款别的构建号有表（仓库表 / 自动表，同档位优先）→ 先试本构建号里执行到的、那张表启用过的种类（10-25 动森 3.0.3：3.0.0 = f32 + aspdiv，
#      旧试法里这一对一次都没试，5 局全不过）；再整组跑闭环；不过就试「分辨率表 f32 + 宽高比类」（拉宽画面 + 改镜头比，最常见的一对），
#      再去掉宽高比类再试，再不过按种类单独试（f32 / f2w / movz）；
#   ③ 过了逐个去点，去掉仍过就不要（取最少点集，同 README「全组里点数最少」）；
#   ④ 闭环局总数不超过 S2A_AUTO_MAX（缺省 8，每局 = 本局 + 对照局两次起局）；最后一组过的用 closed_loop.sh --rejudge-write 写表。
#   都不过 = 不写表，这一档位照旧 16:9 原比例居中留黑边；结论记进 <出表目录>/<档位>.status，同一工具版本不再重跑（工具变了自动重来）。
#   status 三态（10-29）：第 1 行「<态>\t<工具版本>\t<说明>」，态 = 过 / 不过 / 未判。未判 = 基础设施失败或没到判断点（closed_loop.sh 退 75，判定见 loop_state.sh），
#   不算结论：不按工具版本挡、下次触发（出包 / auto_kick.sh）重排，点集缓存不记；上一条结论（过 / 不过）留作第 2 行，出包选表认最近一条结论（auto_pkg.sh list）。
# 出表目录：${S2A_WIDEN_AUTO:-~/.s2arm/run/s2arm/widen/auto}/<款>_<main 构建号>/（widen_enable.<档位>.tsv + 来源.txt + 各局目录）。档位：S2A_LOOP_MODE（缺省 handheld；auto_kick.sh 掌机 / 主机两档各调一次）。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../.." && pwd)
source "$R/pack/roots.sh"   # root_cur_in：现行指针文件（S2A_ROOTS 缺省 = 共享产物根）
export S2A_LOOP_MODE=${S2A_LOOP_MODE:-handheld}; MODE=$S2A_LOOP_MODE
AUTO=${S2A_WIDEN_AUTO:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/widen/auto}; MAX=${S2A_AUTO_MAX:-8}
CL=${S2A_AUTO_LOOP:-$H/closed_loop.sh}
PYS=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; PYS=${PYS:-$(command -v python3)}   # 读原版 NSO 要 lz4（widen_sig.py），同 pack/stage_rewrite.sh 口径
# 单局时限缺省 295 秒；10-24 维护者 只给 xc3 放到 600（开场长，260 秒走不进场景）
case $G in xc3) export S2A_LOOP_CAP=${S2A_LOOP_CAP:-595} S2A_LOOP_SEC=${S2A_LOOP_SEC:-560};; esac   # 单测换成桩（tests/widen_auto_table_test.sh），不起局
src=$(root_cur_in "$S2A_ROOTS" "$G" 2>/dev/null) || { echo "🔴 $G 没有现行产物根"; exit 1; }
BID=$(xxd -s 0x40 -l 16 -p "$src/exefs/main"); [ -n "$BID" ] || { echo "🔴 $G 现行产物根没有 exefs/main"; exit 1; }
[ -f "$R/graphics/widen/tables/${G}_$BID/widen_enable.$MODE.tsv" ] && { echo "🟢 $G 已有仓库启用表（${MODE}），不自动出"; exit 0; }
O=$AUTO/${G}_$BID; ST=$O/$MODE.status; mkdir -p "$O"
VER=$(cat "$H/auto_table.sh" "$H/closed_loop.sh" "$H/wide_scan.py" "$H/enable_write.py" "$H/widen_sig.py" "$H/comm_map.py" "$H/loop_state.sh" | shasum -a 256 | cut -c1-12)   # 工具版本：判据 / 扫描变了就重来
S1=$(sed -n 1p "$ST" 2> /dev/null)   # 只有结论（过 / 不过）按工具版本缓存；未判照跑
case $(cut -f1 <<< "$S1") in 过|不过) [ "$(cut -f2 <<< "$S1")" = "$VER" ] && { echo "🟢 $G 自动出表（${MODE}）已有结论：$(cut -f1,3 <<< "$S1")"; exit 0; };; esac
# 未判连续两次（同一工具版本）→ 当结论缓存、不再重排（11-02 奥德赛：探测局走不到 MARK，每次出包刷新都重挂一份，两份各跑 2 小时、占 Mac 局槽）。
#   第 4 列 = 同工具连续未判次数：偶发的基础设施失败留一次重试；工具变了（判据 / 扫描 / 闭环脚本）自动重来，同「过 / 不过」按工具版本缓存。
#   不按产物根算：刷新任一阶段都出新根，按根算等于每次刷新照样重排。要强制重来删 <出表目录>/<档位>.status
UN=0; [ "$(cut -f1 <<< "$S1")" = 未判 ] && [ "$(cut -f2 <<< "$S1")" = "$VER" ] && UN=$(cut -f4 <<< "$S1"); case $UN in ''|*[!0-9]*) UN=0;; esac
[ "$UN" -ge 2 ] && { echo "🟡 $G 自动出表（${MODE}）同一工具版本已连续未判 $UN 次，不重排（工具变了才重来）：$(cut -f3 <<< "$S1" | cut -c1-160)"; exit 0; }
mkdir "$O/.lock.$MODE" 2>/dev/null || { echo "🟡 $G 自动出表（${MODE}）已在跑（锁 $O/.lock.${MODE}）"; exit 0; }
trap 'rmdir "$O/.lock.$MODE" 2>/dev/null' EXIT
put_() {   # put_ <态> <说明>：写 status 第 1 行；未判不推翻上一条结论（过 / 不过），把它留作第 2 行
  local p=; [ "$1" = 未判 ] && p=$(LC_ALL=C awk -F'\t' '$1 == "过" || $1 == "不过" { print; exit }' "$ST" 2>/dev/null)
  local x=; [ "$1" = 未判 ] && x=$(printf '\t%s' $((UN + 1)))   # 未判记同工具连续次数（见上：两次不再重排）
  { printf '%s\t%s\t%s%s\n' "$1" "$VER" "${2//$'\t'/ }" "$x"; if [ -n "$p" ]; then printf '%s\n' "$p"; fi; } > "$ST.new" && mv "$ST.new" "$ST"; }
undec_() { put_ 未判 "$1"; echo "$(date '+%m-%d %H:%M') 未判（不是画面结论，不缓存，下次触发重排）：$1" >> "$O/$MODE.log"; echo "🟡 $G 自动出表（${MODE}）未判：$1"; exit 75; }   # 起局 / 构建 / 刷新等基础设施出错、没到判断点 ≠ 判据不过
done_() { put_ "$1" "$2"; echo "$(date '+%m-%d %H:%M') $1：$2" >> "$O/$MODE.log"; echo "$1 $G 自动出表（${MODE}）：$2"; exit 0; }
[ "$(cut -f1 <<< "$S1")" = 未判 ] && echo "$(date '+%m-%d %H:%M') 上次未判（$(cut -f3 <<< "$S1" | cut -c1-160)），重排" >> "$O/$MODE.log"
P=$O/play   # 回放器各局共用一份（closed_loop.sh 按局目录 play/ 找，不在就编）
loop() {   # loop <局名> <点集> <录像帧> [额外环境…] → closed_loop.sh 退出码
  # 同一点集 + 录像窗 + 工具版本已判过（过 / 不过）就复用结论、不再起局（10-24 维护者：少起 Mac 局；中途被打断重跑时不重判已判过的组）。
  #   第 4 列工具版本（10-29）：旧 3 列缓存里混着局没起记成的 rc=1，一律不复用
  local c; c=$(awk -F'\t' -v s="$2" -v f="$3" -v v="$VER" '$1 == s && $2 == f && $4 == v { r = $3 } END { print r }' "$O/$MODE.sets.tsv" 2>/dev/null)
  [ -n "$c" ] && { echo "$(date '+%m-%d %H:%M') $1 点集 ${2:-（空）} 已判过 → rc=${c}（复用）" >> "$O/$MODE.log"; return "$c"; }
  local d=$O/$MODE/$1; rm -rf "$d"; mkdir -p "$d"; [ -x "$P/bin/galplay" ] && ln -s "$P" "$d/play"
  env "${@:4}" S2A_DUAL= COST_LINE=画幅 COST_WHY="宽屏自动出表 $G $MODE $1" bash "$CL" "$G" "$d" "$2" "$3" > "$d.out" 2>&1; local rc=$?
  [ ! -x "$P/bin/galplay" ] && [ -x "$d/play/bin/galplay" ] && [ ! -L "$d/play" ] && mv "$d/play" "$P" && ln -s "$P" "$d/play"
  echo "$(date '+%m-%d %H:%M') $1 点集 ${2:-（空）} → rc=${rc}：$(tail -n +1 "$d/verdict.tsv" 2>/dev/null | cut -f1,2 | tr '\t\n' ' ')" >> "$O/$MODE.log"
  # 三态按 closed_loop.sh 退出码：0 过 / 1 不过（判出画面问题）/ 其余（75 = 局没起、构建失败、快照失败、没到 MARK 等）未判——整次出表停在这里记未判，下次触发重排
  case $rc in 0|1) [ -s "$d/verdict.tsv" ] || undec_ "$1 闭环退 ${rc} 却没出判据（$d.out）";;
    *) undec_ "$1：$(grep -m1 -e '🟡' -e '🔴' "$d.out" 2>/dev/null | cut -c1-200)（rc=${rc}，$d.out）";; esac
  [ "$1" = probe ] || printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$rc" "$VER" >> "$O/$MODE.sets.tsv"
  return $rc
}
# ① 探测：屏幕宽 1922，界面裁剪对照不跑；录像只取第 1 帧（判据在这里不看，只要 host.log）
ALL=$(awk -F'\t' 'NR > 1 && $3 != "asp" && $3 != "lytsz" && $3 != "capsz" { printf "%s%s:%s", (n++ ? "," : ""), $1, $2 }' "$src/widen_sites.tsv")
[ -n "$ALL" ] || done_ 不过 "候选扫描没有可试的点（widen_sites.tsv）"
L=$O/$MODE/probe/host.log
hits() {   # hits <点集> <host.log> → 逐行「模块:偏移:种类」：这一局真执行到的点（数据点 f32 / aspf / i32 看装载改写行，代码点看首次命中行）
  local s k; for s in ${1//,/ }; do k=$(awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o { print $3 }' "$src/widen_sites.tsv")
    if [ "$k" = f32 ]; then LC_ALL=C /usr/bin/grep -a -q "宽屏：${s%%:*}+${s#*:} f32 表 [0-9]* 项按屏幕宽放大" "$2" && echo "$s:$k"
    elif [ "$k" = aspf ]; then LC_ALL=C /usr/bin/grep -a -q "宽屏：${s%%:*}+${s#*:} aspf 16:9 常量改为屏幕比" "$2" && echo "$s:$k"
    elif [ "$k" = i32 ]; then LC_ALL=C /usr/bin/grep -a -q "宽屏：${s%%:*}+${s#*:} i32 整数分辨率表" "$2" && echo "$s:$k"
    else LC_ALL=C /usr/bin/grep -a -q "\[宽\] 点 ${s%%:*}+${s#*:} 首次命中" "$2" && echo "$s:$k"; fi; done; }
# 探测局开着全部候选崩了（11-01 怒之铁拳4：命中 4 个 movz 后空指针，不开点的对照局照常到 MARK）：屏宽 1922 时真宽度点 ≈ 原值，崩溃源只能是
#   崩前执行到的点（把分配大小等别的用途常数当成宽度）——把这些点当嫌疑剔出候选、重探，最多 3 轮；崩的探测局留作 probe_crash<N>，剔掉的点写进日志、不进后面的组合
PN=0
while :; do
  # 同构建号已有到了 MARK 的探测局就复用（10-24 维护者：少起 Mac 局）；探测局只为「哪些点会执行、MARK 在哪」，与工具版本无关
  if LC_ALL=C /usr/bin/grep -a -q 'S2A 标记 MARK' "$L" 2>/dev/null && [ "$(cat "$O/$MODE/probe/bid" 2>/dev/null)" = "$BID" ]; then echo "$(date '+%m-%d %H:%M') 复用探测局 $O/$MODE/probe" >> "$O/$MODE.log"
  else loop probe "$ALL" 1-1 S2A_SCREEN_W=1922 S2A_LOOP_UICLIP=0; fi
  src=$(root_cur_in "$S2A_ROOTS" "$G")   # 探测局起局前刷过产物根（closed_loop.sh → pack/refresh.sh），现行版本可能换了：重取（10-24 xc3 首例：旧路径已删，点表读不到）
  MK=$(LC_ALL=C /usr/bin/grep -a -o 'S2A 标记 MARK：帧 [0-9]*' "$L" 2>/dev/null | head -1 | grep -o '[0-9]*$')
  [ -n "$MK" ] && break   # 起了没崩没到 MARK 是未判（closed_loop.sh 退 75，上面 loop 已停）；到这里只剩崩
  SUS=$(hits "$ALL" "$L" | sed 's/:[^:]*$//' | paste -sd, -)
  [ -n "$SUS" ] && [ $PN -lt 3 ] || done_ 不过 "探测局开着全部候选没到 MARK 就崩了（${L}；已剔嫌疑点 ${PN} 轮，$([ -n "$SUS" ] && echo "本轮崩前执行到 ${SUS}" || echo 崩前一个点都没执行到)）"
  PN=$((PN + 1)); rm -rf "$O/$MODE/probe_crash$PN"; mv "$O/$MODE/probe" "$O/$MODE/probe_crash$PN"
  ALL=$(tr ',' '\n' < <(printf '%s\n' "$ALL") | grep -v -x -F -f <(tr ',' '\n' < <(printf '%s\n' "$SUS")) | paste -sd, -)
  echo "$(date '+%m-%d %H:%M') 探测局崩（第 $PN 轮，留 probe_crash${PN}）：剔除崩前执行到的嫌疑点 ${SUS}，剩 $(tr ',' '\n' < <(printf '%s\n' "$ALL") | grep -c .) 个重探" >> "$O/$MODE.log"
  [ -n "$ALL" ] || done_ 不过 "探测局崩、剔除嫌疑点后候选不剩（${SUS}）"
done
EX=(); while read -r e; do EX+=("$e"); done < <(hits "$ALL" "$L")
[ ${#EX[@]} -gt 0 ] || done_ 不过 "候选 $(tr ',' '\n' < <(printf '%s\n' "$ALL") | wc -l | tr -d ' ') 个，探测局里一个都没执行到"
echo "$(date '+%m-%d %H:%M') 探测：MARK 帧 ${MK}，执行到 ${#EX[@]} 个：${EX[*]}" >> "$O/$MODE.log"
FR=mark+150:4   # 录像窗：各局自己的 MARK 后约 5 秒起 4 帧（同 closed_loop 口径「MARK 之后游戏场景里的 3–4 帧」）；MARK 帧每局不同（10-25 动森 3.0.3 探测 1800 / 闭环 1579），不按探测局定死
sites() { local out= e; for e in "$@"; do out+="${out:+,}${e%:*}"; done; echo "$out"; }   # 去掉种类后缀
pick() { local e; for e in "${EX[@]}"; do case " $* " in *" ${e##*:} "*) echo "$e";; esac; done; }   # 只留给定种类
# 先验种类：同款别的构建号的启用表里「启用 = 1」的种类（仓库表优先、再自动表；同档位优先、没有再另一档位）。表头 模块 偏移 种类 启用
prior_kinds() { local m f; for m in "$MODE" $([ "$MODE" = handheld ] && echo docked || echo handheld); do
    for f in "$R"/graphics/widen/tables/"${G}"_*/widen_enable.$m.tsv "$AUTO"/"${G}"_*/widen_enable.$m.tsv; do
      [ -f "$f" ] && [ "$(basename "$(dirname "$f")")" != "${G}_$BID" ] || continue
      awk -F'\t' 'NR > 1 && $4 == 1 { print $3 }' "$f" | sort -u | tr '\n' ' '; return; done; done; }
try_kinds() { local A; A=($(pick "$@")); [ ${#A[@]} -gt 0 ] && try "${A[@]}"; }
N=0; GOOD=; GD=
try() { [ $N -lt "$MAX" ] || return 1; N=$((N + 1)); loop "t$N" "$(sites "$@")" "$FR" && { GOOD=("$@"); GD=t$N; return 0; }; return 1; }
# 移植：同款别的构建号的表旁有启用点特征（widen_sig.<档位>.tsv，闭环写表时生成）就按特征移植到本版本（widen_sig.py port），移植出且探测局执行到的点先上闭环。
#   游戏一更新构建号就变，按构建号绑定的表不生效（10-26 动森新版：表在 5d913cf7、现行 ff1d1c05，退回整套放宽出拉丝）。移植不了的点记黄，照旧走下面的自动探测
PT=(); for f in "$R"/graphics/widen/tables/"${G}"_*/widen_sig.$MODE.tsv "$AUTO"/"${G}"_*/widen_sig.$MODE.tsv; do
  [ -f "$f" ] && [ "$(basename "$(dirname "$f")")" != "${G}_$BID" ] || continue
  PS=$("$PYS" "$H/widen_sig.py" port "$src/exefs" "$f" "$src/widen_sites.tsv" 2>> "$O/$MODE.log"); prc=$?
  [ $prc = 0 ] || echo "$(date '+%m-%d %H:%M') 🟡 移植 $(basename "$(dirname "$f")")：有点没移植成（明细见上；退回自动探测选点）" >> "$O/$MODE.log"
  for e in "${EX[@]}"; do case ",$PS," in *",${e%:*},"*) PT+=("$e");; esac; done
  [ ${#PT[@]} -gt 0 ] && { echo "$(date '+%m-%d %H:%M') 移植自 $(basename "$(dirname "$f")")：${PT[*]}" >> "$O/$MODE.log"; break; }
done
# 社区超宽屏补丁映射（comm_map.py，10-26 维护者：社区做好的宽屏补丁都要适配进宽屏库）：本构建号有社区补丁时，补丁改到的我方候选点就是答案，探测局执行到的那组最先上闭环。
#   补丁只从本机数据目录读（S2A_UW_PATCHES：环境 → tools/machine.local，开发机在那里指向收集的超宽屏全集），不进仓库；没设 / 没有补丁 / 对不上 = 空，照旧走下面
UW=${S2A_UW_PATCHES:-$(bash "$R/tools/machine.sh" get S2A_UW_PATCHES 2> /dev/null)}
CM=(); CS=; [ -z "$UW" ] || CS=$("$PYS" "$H/comm_map.py" points "$UW" "$src/exefs" "$src/widen_sites.tsv" 2>> "$O/$MODE.log")
for e in "${EX[@]}"; do case ",$CS," in *",${e%:*},"*) CM+=("$e");; esac; done
[ -n "$CS" ] && echo "$(date '+%m-%d %H:%M') 社区补丁映射：${CS}；探测局执行到 ${#CM[@]} 个：${CM[*]}" >> "$O/$MODE.log"
# 两档互借（10-26 维护者「主机档和掌机档这么难同时都支持么」：48 小时主机档 15 份不过里，暗黑2 掌机档过了、主机档没拿那组点试就停）：
#   同构建号另一档位已有表（仓库表优先、再自动表）→ 先试「那张表启用的点 ∩ 本档探测局执行到的」，再加本档执行到的、同种类的分辨率点（movz / f32 / i32 / f2w：
#   游戏两档各写一组分辨率常量，宽高比类点两档共用同一段代码）
OM=$([ "$MODE" = handheld ] && echo docked || echo handheld); XS=; XK=
for f in "$R/graphics/widen/tables/${G}_$BID/widen_enable.$OM.tsv" "$AUTO/${G}_$BID/widen_enable.$OM.tsv"; do
  [ -f "$f" ] || continue
  XS=$(awk -F'\t' 'NR > 1 && $4 == 1 { printf "%s%s:%s", (n++ ? "," : ""), $1, $2 }' "$f"); XK=$(awk -F'\t' 'NR > 1 && $4 == 1 { print $3 }' "$f" | sort -u | tr '\n' ' '); break; done
XM=(); for e in "${EX[@]}"; do case ",$XS," in *",${e%:*},"*) XM+=("$e");; esac; done
XR=("${XM[@]+"${XM[@]}"}"); for e in "${EX[@]}"; do case " f32 i32 f2w movz " in *" ${e##*:} "*) case " $XK " in *" ${e##*:} "*) case " ${XR[*]+${XR[*]}} " in *" $e "*) ;; *) XR+=("$e");; esac;; esac;; esac; done
[ -n "$XS" ] && echo "$(date '+%m-%d %H:%M') 两档互借：${OM} 表启用 ${XS}；本档执行到 ${#XM[@]} 个，加同种类分辨率点后 ${#XR[@]} 个：${XR[*]+${XR[*]}}" >> "$O/$MODE.log"
# ② 社区映射点 → 另一档位的点（加分辨率点 / 不加）→ 移植点 → 先验种类 → 整组 → f32 + 宽高比类 → 去宽高比类 → 各种类单独
PK=$(prior_kinds); [ -n "$PK" ] && echo "$(date '+%m-%d %H:%M') 先验：同款别的构建号的表启用种类 ${PK}" >> "$O/$MODE.log"
{ [ ${#CM[@]} -gt 0 ] && try "${CM[@]}"; } || { [ ${#XR[@]} -gt 0 ] && try "${XR[@]}"; } || { [ ${#XM[@]} -gt 0 ] && [ ${#XM[@]} -lt ${#XR[@]} ] && try "${XM[@]}"; } || { [ ${#PT[@]} -gt 0 ] && try "${PT[@]}"; } || { [ -n "$PK" ] && try_kinds $PK; } || try "${EX[@]}" || { [ -n "$(pick f32)" ] && [ -n "$(pick aspdiv aspstr seadasp)" ] && try_kinds f32 aspdiv aspstr seadasp; } || {
  A=($(pick f32 f2w movz)); [ ${#A[@]} -gt 0 ] && [ ${#A[@]} -lt ${#EX[@]} ] && try "${A[@]}"; } || {
  for k in f32 f2w movz; do A=($(pick $k)); [ ${#A[@]} -gt 0 ] && try "${A[@]}" && break; done; }
[ -n "$GD" ] || done_ 不过 "执行到的 ${#EX[@]} 个点各种组合 ${N} 局闭环都不过（明细 $O/$MODE.log）"
# ③ 逐个去点
if [ ${#GOOD[@]} -gt 1 ]; then for e in "${GOOD[@]}"; do
  [ ${#GOOD[@]} -gt 1 ] || break; B=(); for x in "${GOOD[@]}"; do [ "$x" = "$e" ] || B+=("$x"); done
  keep=("${GOOD[@]}"); kd=$GD; try "${B[@]}" || { GOOD=("${keep[@]}"); GD=$kd; }; [ $N -lt "$MAX" ] || break; done; fi
# ④ 写表（按最后一组过的局目录离线重判，全过才写）
S2A_WIDEN_DIR=$AUTO bash "$CL" "$G" "$O/$MODE/$GD" "$(sites "${GOOD[@]}")" "$FR" --rejudge-write > "$O/$MODE/write.out" 2>&1; wrc=$?
case $wrc in 0) ;; 1) done_ 不过 "最后一组 $GD 重判不过（$O/$MODE/write.out）";; *) undec_ "最后一组 $GD 重判未判（rc=${wrc}，$O/$MODE/write.out）";; esac
done_ 过 "启用 $(sites "${GOOD[@]}")（闭环 $N 局，选 ${GD}）→ $O/widen_enable.$MODE.tsv"
