#!/bin/bash
slot_run() { local n=$1 c=$2; shift 3; if [ -n "${S2A_PRIVATE_TOOLS:-}" ]; then bash "$S2A_PRIVATE_TOOLS/mac_slot_frozen.sh" run "$n" "$c" -- "$@"; else "$@"; fi; }   # 局槽仲裁是维护方设施：没设 S2A_PRIVATE_TOOLS 直接跑
# 宽屏第二层闭环验证（画幅线，新架构）：graphics/widen/scan/closed_loop.sh <款> <局目录> <点集> <录像帧 a-b> [--write | --rejudge-write]
#   --rejudge-write：不起局，对已跑完的同一局目录按同样判据离线重判（host.log + 录像），全过才写表（局起时忘了带 --write 用）。
#   退出码三态（10-29）：0 全过；1 不过（局起来了、到了判断点、判出画面问题）；75 未判（基础设施失败 / 没到判断点，判定与信号见 graphics/widen/scan/loop_state.sh）；2 用法错。
#   点集 = S2A_WIDEN_SITES 口径（main:0x1152390,main:0x11523f0）；录像帧取 MARK 之后游戏场景里的 3–4 帧（上屏序号）。
# 一律按产品档位跑（10-20 维护者定：闭环只用产品档位；旧试验台跑主机 1080p 档验出的塞尔达 / 暗黑3 启用表在产品掌机 720p 档全都不执行）：
#   新架构 Mac 局（runtime/run_mac.sh，自动玩家，零配置）= 产品同一档位；屏幕宽 S2A_SCREEN_W（缺省 2346 = 17 Pro Max 横屏）。
# 判据（全过才算；期望值不来自被测实现）：
#   ① 0 崩、到 MARK；② 点集里每个点都首次命中（没执行的点不该进表）；
#   ③ 出图满宽：最后一次「出图参数」的源宽高比 = 屏幕比（±0.01）；③b 上屏满屏：host.log 宿主上屏判据（tools/widen_accept.py judge_host_log，与满屏验收同一函数）——
#     源比例对了不等于上屏铺满（#862：丝之歌 19.5:9 游戏画幅 100%、上屏画布 82%），截图量的是游戏画幅、量不到上屏留边；
#   ④ 3D 镜头 = 屏幕比：tests/visual/proj_aspect.py 退出码 0；
#   ⑤ 露空 ≤ 0.5%：录像中间帧场景深度（galplay --depth）→ tests/visual/widen_holes.py --w0 高×16/9，两侧带占比。
# 直连局（只有直连，11-07 拆通用模式；判法看 host.log「图形模式」）：③ 量上屏截图宽高比；
#   ④ 宽屏核心替游戏改投影的笔占比本局 ≤ 对照局一半（游戏自己出宽投影，CPU 视锥剔除随之变宽）；⑤ 截图 16:9 断崖 < 0.5（tools/widen_cliff.py）；⑩ 不判（量法靠通用回放）。
# 点集里有界面拷屏点（lytsz / capsz）：原第二局走手录界面路线判 ⑥–⑨，10-31 随手录路线删除（自动玩家改 AI 看屏驾驶），本脚本只打黄行提示、不判。
#   ⑩ 界面裁剪不多切（10-23 塞尔达雷达：镜头点 main:0xb4e840 让游戏按宽屏像素算界面剪裁，包装层又把读改写矩阵的界面层局部剪裁收进中间 = 重复换算，雷达右半被切；
#      修法见 WidenFrame.LayoutWide。判据不看机制，只量「界面剪裁有没有比 16:9 多切」）：
#      同存档同录像帧另起一局不开第二层点（游戏出 16:9）当对照；两局录像各回放两遍——正常 / galplay --ui-noscissor（不开深度测的绘制裁剪放成整张），
#      两遍出图差的像素 = 界面裁剪切掉的像素；本局逐帧最大值 ≤ 对照局最大值 × 1.5 + 2000（雷达半圆约 1.1 万）。S2A_LOOP_UICLIP=0 跳过。
# 起局按产品条件（包内预编着色器照开）；回放时 galplay 用 S2A_SHADER_PACK=<产物根>/shaders 开同一份离线库（不开则包内程序建不出、绘制不执行，量出来是假的），回放里「离线库未命中」须为 0。
# 档位（10-20 维护者：缺省主机 1080p，掌机 720p 留作低性能手机可选）：S2A_LOOP_MODE=docked|handheld（必给）。游戏按档位分支写两组尺寸，
#   每档位各一张表，装载器按 S2A_DOCKED 只读当前档位那张（10-21 起不再合并两档：塞尔达主机档的 main:0xb4e7d8 在掌机档也执行，并集把没验过的点带进掌机档）。
# --write：全过时把这一档位验过的点集写到本树 ${S2A_WIDEN_DIR:-graphics/widen/tables}/<款>_<main 构建号>/widen_enable.<档位>.tsv（提交进仓库、走列车；候选取产物根 widen_sites.tsv）；
#   来源.txt 追加一行读数（带档位）；提交合入后 pack/refresh.sh 改写阶段按构建号从仓库拷进产物根（旧表看 git 历史，不再留 .prev 副本）。
# 单局时限：S2A_LOOP_CAP 秒（缺省 295；10-24 维护者 只给 xc3 放到 600：S2A_LOOP_CAP=595 S2A_LOOP_SEC=560），局长 S2A_LOOP_SEC（缺省 260）。
# 起局缺省不刷产物根（直接用共享现行）；S2A_LOOP_REFRESH=1 才刷，刷时分支树刷不了共享根，S2A_RUN_TREE=<干净 origin/main 树> 指定起局用的树（缺省本树）。
#   验证分支（如原生层改动）：S2A_RUN_TREE=<分支树> S2A_ROOTS=<私有产物根目录>（pack/roots.sh 同口径，从共享现行克隆起步）。
set -u
G=${1:?款}; D=${2:?局目录}; SITES=${3:?点集}; FR=${4:?录像帧 a-b 或 mark+K:N}; WRITE=${5:-}
# 录像帧两种写法（录像层 S2A_GALREC_FRAMES 同口径，services/aot/Compose.cs）：a-b = 第 a..b 次上屏；mark+K:N = MARK 后第 K 次上屏起 N 次（跟着本局自己的 MARK 走——
#   10-25 动森 3.0.3：探测局 MARK 在 1800、闭环局在 1579，按探测局定死的 1950-1953 录到的不是场景，⑤ 退到截图口径判不过）
case $FR in mark+*:*) NFR=${FR##*:};; *-*) NFR=$(( ${FR#*-} - ${FR%-*} + 1 ));; *) echo "🔴 录像帧 $FR 不认（a-b 或 mark+K:N）"; exit 2;; esac
MODE=${S2A_LOOP_MODE:?S2A_LOOP_MODE=docked|handheld（产品档位；起局设服务层 S2A_DOCKED=1/0，服务接入线 95710dc）}; case $MODE in docked|handheld) ;; *) echo "🔴 S2A_LOOP_MODE 只认 docked / handheld"; exit 2;; esac
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../.." && pwd); source "$R/pack/roots.sh"; T=${S2A_RUN_TREE:-$R}; W=${S2A_SCREEN_W:-2346}; PY=/usr/bin/python3
PYS=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; PYS=${PYS:-$(command -v python3)}   # 读原版 NSO 要 lz4（widen_sig.py），同 pack/stage_rewrite.sh 口径
PYA=$(command -v python3); "$PYA" -c "import numpy, PIL" 2>/dev/null || { echo "🔴 $PYA 缺 numpy / PIL（tests/visual 量具要用）"; exit 75; }
mkdir -p "$D"; : > "$D/verdict.tsv"
export COST_LINE=${COST_LINE:-画幅} COST_WHY=${COST_WHY:-"宽屏第二层闭环（档位 ${MODE}）：$G 点集 $SITES"}
REJ=0; [ "$WRITE" = --rejudge-write ] && REJ=1
if [ "$WRITE" = --rejudge-write ]; then   # 离线重判：局目录里必须有上次起局留下的 host.log / 录像 / 候选表 / 构建号
  [ -s "$D/host.log" ] && [ -s "$D/widen_sites.tsv" ] && [ -s "$D/bid" ] || { echo "🔴 $D 不是跑完的闭环局目录（缺 host.log / widen_sites.tsv / bid）"; exit 75; }
  src=$(root_cur_in "$S2A_ROOTS" "$G"); BID=$(cat "$D/bid"); rc=$(cat "$D/rc" 2>/dev/null || echo 0); WRITE=--write
  [ "$(xxd -s 0x40 -l 16 -p "$src/exefs/main")" = "$BID" ] || { echo "🔴 现行产物根 main 构建号与局目录不同，不能重判"; exit 75; }
else
# 不刷产物根（10-24 维护者 整改：Mac 局复用共享根现有产物，缺的着色器运行时现编；只有改了着色器翻译 / 烘焙才重烘）。S2A_LOOP_REFRESH=1 才刷
if [ "${S2A_LOOP_REFRESH:-0}" = 1 ]; then bash "$T/pack/refresh.sh" "$G" > "$D/refresh.log" 2>&1 || { echo "🔴 $G 产物根刷新红：$(tail -1 "$D/refresh.log")"; exit 75; }; fi
src=$(root_cur_in "$S2A_ROOTS" "$G"); sn=$D/in_snap; rm -rf "$sn"
# 产物根快照只在本脚本跑着时有效（10-29 出包线：局在远端被超时杀掉时第 66 行的删快照没走到，维护方工具 --pull 用 rsync 把整个局目录拉回本机，
#   克隆变成实拷贝——wire-c/fullbg 6 份 in_snap 每份 26.5 GB、共 159 GB）：任何方式退出都删本局的快照
trap 'rm -rf "$D/in_snap" "$D"/*/in_snap' EXIT
$PY "$T/tools/clonedir.py" "$src" "$sn" || { echo "🔴 快照失败"; exit 75; }
BID=$(xxd -s 0x40 -l 16 -p "$sn/exefs/main")
SA=$(bash "$H/save_pick.sh" "$G" "$BID" "$sn")   # 同构建号 > 同构建号带后缀 > 同款别的构建号（存档是只读种子）
# 图形模式（11-01 满屏线：闭环原先写死通用；通用冻结后马车8 卡标题、怒之铁拳4 探测局崩、胡闹宇航员进不了局，主力直连从没被验）：
#   与 维护方 entry_check.sh 同口径：根里没有本链号直连库（NVN b-<链>/lib.idx，或 Vulkan vk/ / OpenGL gl/）就不起局、未判退出（原先退回通用局；11-07 拆通用模式）
CH=$(sed -n 's/^#define DMSH_CHAIN "\([0-9a-f]*\)".*/\1/p' "$T/graphics/nvn/gfx/nvn/dmsh_chain.h" 2> /dev/null)
GFX=direct
{ { [ -n "$CH" ] && [ -f "$sn/shaders/direct/b-$CH/lib.idx" ]; } || [ -d "$sn/shaders/direct/vk" ] || [ -d "$sn/shaders/direct/gl" ]; } || { echo "🔴 $G 根里没有本链号直连库（${CH:-链号读不到}）：不起局"; exit 75; }
[ -n "$SA" ] && [ "$(basename "$SA")" != "${G}_$BID" ] && echo "【黄】$G 没有构建号 ${BID:0:8} 的同名存档，用 $(basename "$SA")"
X=(); if [ -d "$SA" ]; then X+=("S2A_SAVE_DIR=$SA"); for k in system_time:S2A_SYSTEM_TIME language:S2A_SYSTEM_LANGUAGE region:S2A_REGION timezone:S2A_TIMEZONE; do
  [ -s "$SA/${k%%:*}" ] && X+=("${k#*:}=$(cat "$SA/${k%%:*}")"); done; fi
env ${X[@]+"${X[@]}"} S2A_CS=1 S2A_WIDEN_VERIFIED=1 S2A_GFX=$GFX S2A_DOCKED=$([ "$MODE" = docked ] && echo 1 || echo 0) S2A_SCREEN_W="$W" S2A_WIDEN_SITES="$SITES" S2A_IN="$sn" \
  slot_run "宽屏闭环 $G" "${S2A_LOOP_CAP:-295}" -- bash "$T/runtime/run_mac.sh" "$G" "$D" "${S2A_LOOP_SEC:-260}" > "$D/run.out" 2>&1; rc=$?   # 排队不计入 295 秒局时限（10-21：负载下排 169 秒、局被外层 timeout 杀成 rc=124）
cp "$sn/widen_sites.tsv" "$D/widen_sites.tsv" 2>/dev/null; echo "$BID" > "$D/bid"; echo "$rc" > "$D/rc"
if [ "${S2A_LOOP_UICLIP:-1}" = 1 ] || [ "$GFX" = direct ]; then   # ⑩ / 直连 ④ 的对照局：同存档同录像帧、不开第二层点（S2A_WIDEN_SITES 空 = 整表全关）
  rm -rf "$D/base"; mkdir -p "$D/base"
  env ${X[@]+"${X[@]}"} S2A_CS=1 S2A_WIDEN_VERIFIED=1 S2A_GFX=$GFX S2A_DOCKED=$([ "$MODE" = docked ] && echo 1 || echo 0) S2A_SCREEN_W="$W" S2A_WIDEN_SITES= S2A_IN="$sn" \
    slot_run "宽屏闭环对照 $G" "${S2A_LOOP_CAP:-295}" -- bash "$T/runtime/run_mac.sh" "$G" "$D/base" "${S2A_LOOP_SEC:-260}" > "$D/base/run.out" 2>&1; echo $? > "$D/base/rc"
fi
rm -rf "$sn"
fi
L=$D/host.log; ok=1
DIRECT=0; LC_ALL=C /usr/bin/grep -a -q '图形模式：直连' "$L" 2> /dev/null && DIRECT=1   # 判法按局实际走的模式（host.log 为准，离线重判同样）
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$D/verdict.tsv"; [ "$2" = 过 ] || ok=0; }
mk=$(LC_ALL=C /usr/bin/grep -a -o 'S2A 标记 MARK：帧 [0-9]*' "$L" | head -1)
crash=$(LC_ALL=C /usr/bin/grep -a -c CRASH "$L")
[ "$rc" = 0 ] && [ "$crash" = 0 ] && [ -n "$mk" ] && row "①崩溃 / MARK" 过 "rc=${rc}，崩 ${crash}，$mk" || row "①崩溃 / MARK" 不过 "rc=${rc}，崩 ${crash}，${mk:-没到 MARK}"
miss=; for s in ${SITES//,/ }; do
  awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o && ($3 == "lytsz" || $3 == "capsz") { f = 1 } END { exit !f }' "$D/widen_sites.tsv" 2>/dev/null && continue   # 界面拷屏点在界面局（⑨）里判执行   # f32 分辨率表是数据、装载时改值，不会「执行」：以装载日志「宽屏：<模块>+<偏移> f32 表 N 项按屏幕宽放大」为证（10-20 动森主机档）
  if awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o && $3 == "f32" { f = 1 } END { exit !f }' "$D/widen_sites.tsv" 2>/dev/null; then
    LC_ALL=C /usr/bin/grep -a -q "宽屏：${s%%:*}+${s#*:} f32 表 [0-9]* 项按屏幕宽放大" "$L" || miss+=" $s"
  elif awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o && $3 == "aspf" { f = 1 } END { exit !f }' "$D/widen_sites.tsv" 2>/dev/null; then   # aspf 数据点：装载时改了就算
    LC_ALL=C /usr/bin/grep -a -q "宽屏：${s%%:*}+${s#*:} aspf 16:9 常量改为屏幕比" "$L" || miss+=" $s"
  elif awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o && $3 == "i32" { f = 1 } END { exit !f }' "$D/widen_sites.tsv" 2>/dev/null; then   # i32 数据点：装载时改了就算
    LC_ALL=C /usr/bin/grep -a -q "宽屏：${s%%:*}+${s#*:} i32 整数分辨率表" "$L" || miss+=" $s"
  else LC_ALL=C /usr/bin/grep -a -q "\[宽\] 点 ${s%%:*}+${s#*:} 首次命中" "$L" || miss+=" $s"; fi
done
[ -z "$miss" ] && row "②点都执行到" 过 "$SITES" || row "②点都执行到" 不过 "没命中：$miss"
if [ $DIRECT = 1 ]; then   # 直连没有通用渲染器的「出图参数」行：量上屏截图本身（第三层放宽后的出图）的宽高比
  read -r ow oh <<< "$("$PYA" -c 'import sys; from PIL import Image; print(*Image.open(sys.argv[1]).size)' "$D/ap_mark.png" 2> /dev/null)"
  if [ -n "${ow:-}" ] && $PY -c "import sys; sys.exit(0 if abs($ow/$oh - $W/1080) <= 0.01 else 1)"; then row "③出图满宽" 过 "直连上屏截图 ap_mark ${ow}×${oh}（$($PY -c "print(round($ow/$oh,4))")，屏幕比 $($PY -c "print(round($W/1080,4))")）"
  else row "③出图满宽" 不过 "直连上屏截图 ap_mark ${ow:-?}×${oh:-?} 不是屏幕比（或没有截图）"; fi
else
op=$(LC_ALL=C /usr/bin/grep -a '出图参数' "$L" | tail -1)
read -r ow oh <<< "$(sed -nE 's/.*源 \[0,([0-9]+)\)×\[0,([0-9]+)\).*/\1 \2/p' <<< "$op")"
if [ -n "${ow:-}" ] && $PY -c "import sys; sys.exit(0 if abs($ow/$oh - $W/1080) <= 0.01 else 1)"; then row "③出图满宽" 过 "源 ${ow}×${oh}（$($PY -c "print(round($ow/$oh,4))")，屏幕比 $($PY -c "print(round($W/1080,4))")）"
else row "③出图满宽" 不过 "源 ${ow:-?}×${oh:-?}：${op:-没有出图参数行}"; fi
fi
# ③b 有不开点的对照局（⑩ 用的 base）时按边际判：上限 = max(1, 对照局次数)，对照局本来就有的未满屏不算到被测点头上（tools/widen_accept.py judge_host_log base）
hl=$("$PY" -c 'import sys, os; sys.path.insert(0, sys.argv[1] + "/tools"); import widen_accept as w; b = sys.argv[3] if os.path.isfile(sys.argv[3]) else None; m, bad, unv = w.judge_host_log(sys.argv[2], b); print(("不过\t" + "；".join(bad)) if bad else ("未验\t" + "；".join(unv)) if unv else "过\t上屏未满屏 %d 次、末态满屏" % m["unfilled"] + ("（对照局 %d 次）" % m["base_unfilled"] if "base_unfilled" in m else ""))' "$R" "$D/host.log" "$D/base/host.log")
row "③b上屏满屏" "${hl%%	*}" "${hl#*	}"
# ③c 截图两侧画面（10-30 维护者：满屏过不能只看宽高比）：ap_mark / ap_end 过 widen_accept.band_checks（两侧扩展带空洞 / 16:9 边界接缝），与五问快检同一判法；
#   有对照局时空洞按边际判（11-01 胡闹宇航员：舱外本来就暗，开点左带 +0.28 对照局 +0.96 却判不过），接缝照旧按绝对值
bc=$("$PYA" - "$R/tools" "$D" <<'BCEOF'
import os, sys; sys.path.insert(0, sys.argv[1]); import widen_accept as wa; wa.ensure_deps()
from PIL import Image
bad, rd, wide = [], [], 0
for f in ('ap_mark.png', 'ap_end.png'):
    p = os.path.join(sys.argv[2], f)
    if not os.path.exists(p): continue
    im = Image.open(p).convert('RGB'); b, r = wa.band_checks(im)
    q = os.path.join(sys.argv[2], 'base', f)   # 对照局（不开点）同一张截图：空洞按边际判，不比对照局少才算到被测点头上（同 ③b）
    if os.path.exists(q):
        h, hb = wa.measure_side_hole(im), wa.measure_side_hole(Image.open(q).convert('RGB'))
        if h and hb:
            keep = [s for s, n in (('left', '左'), ('right', '右')) if h[s] is not None and h[s] >= wa.HOLE_EXCESS and h[s] >= (1.0 if hb[s] is None else hb[s])]   # 对照局这侧量不出（纯黑，按 16:9 剔除的典型样子）按最坏 1.0 算
            b = [x for x in b if '扩展带空洞' not in x or any(x.startswith(n) for s, n in (('left', '左'), ('right', '右')) if s in keep)]
            r += '，对照局空洞 ' + ' / '.join('—' if hb[k] is None else f'{hb[k]:+.2f}' for k in ('left', 'right'))
    bad += [f'{f}：{x}' for x in b]; rd.append(f'{f} {r}'); wide += not r.startswith('不是加宽图')
# 截图不是加宽图（11-09 哈迪斯 II：Mac 窗口 16:9、2.17:1 画面上下加黑边塞进截图，band_checks 不量）原先记「过」，量都没量 → 未验
print(('不过\t' + '；'.join(bad)) if bad else ('过\t' + '；'.join(rd)) if wide else ('未验\t截图都不是加宽图，两侧没量：' + '；'.join(rd)) if rd else '未验\t没有 ap_mark / ap_end 截图')
BCEOF
)
row "③c截图两侧画面" "${bc%%	*}" "${bc#*	}"
if [ $DIRECT = 1 ]; then
  # ④（直连）游戏自己出宽投影：宽屏核心替游戏改投影的笔占比（「S2Arm widen: … into core C, rewritten R」末行）本局 ≤ 对照局（不开点）的一半——
  #   点让游戏按屏幕比算投影，核心不用再改；游戏 CPU 视锥剔除用的就是这份投影（11-01 马车8：对照局 97% → 开 main:0x3cd314 后 32%）
  rr() { LC_ALL=C /usr/bin/grep -a -o 'into core [0-9]*, rewritten [0-9]*' "$1" 2> /dev/null | tail -1 | awk '{ c = $3 + 0; r = $5 + 0; if (c > 0) printf "%.4f\n", r / c }'; }
  rt=$(rr "$L"); rb=$(rr "$D/base/host.log")
  if [ -z "$rt" ] || [ -z "$rb" ]; then row "④3D 镜头比" 不过 "直连：没有改写计数行（本局 ${rt:-无} / 对照局 ${rb:-无}）"
  elif $PY -c "import sys; sys.exit(0 if $rt <= $rb * 0.5 else 1)"; then row "④3D 镜头比" 过 "直连：核心改投影占比 本局 $rt ≤ 对照局 $rb × 0.5（游戏自己出宽投影）"
  else row "④3D 镜头比" 不过 "直连：核心改投影占比 本局 $rt > 对照局 $rb × 0.5（点没让游戏自己出宽投影）"; fi
  # ⑤（直连）两侧缺渲染：上屏截图 16:9 边界断崖（tools/widen_cliff.py，纯像素；引擎按 16:9 剔除时黑区恰好从边界起），有的截图都 < 0.5
  sh=(); for f in ap_mark ap_mid ap_end; do [ -s "$D/$f.png" ] && sh+=("$D/$f.png"); done
  cl=; [ ${#sh[@]} -gt 0 ] && cl=$("$PYA" "$R/tools/widen_cliff.py" "${sh[@]}" 2> /dev/null | awk 'BEGIN { m = 0 } $1 != "-" { if ($1 + 0 > m) m = $1 + 0; n++ } END { if (n) print m, n }')
  if [ -z "$cl" ]; then row "⑤露空 ≤0.5%" 不过 "直连：没有可量的加宽截图"
  elif $PY -c "import sys; sys.exit(0 if ${cl%% *} < 0.5 else 1)"; then row "⑤露空 ≤0.5%" 过 "直连：截图 16:9 断崖最大 ${cl%% *}（${cl#* } 张）< 0.5"
  else row "⑤露空 ≤0.5%" 不过 "直连：截图 16:9 断崖最大 ${cl%% *}（${cl#* } 张）≥ 0.5（两侧缺渲染）"; fi
elif [ -s "$D/rec/gal.rec" ]; then
  if "$PYA" "$R/tests/visual/proj_aspect.py" "$D/rec/gal.rec" --target "$W/1080" > "$D/proj.txt" 2>&1; then row "④3D 镜头比" 过 "$(tail -1 "$D/proj.txt")"
  elif grep -q '主镜头宽高比 None' "$D/proj.txt"; then   # 投影矩阵认不出（暗黑3 旧试验台起就是 0 次）：改判场景目标（绘制最多的深度附件）宽高比 = 屏幕比
    read -r sw sh <<< "$(sed -nE 's/^场景目标.*：([0-9]+)x([0-9]+).*/\1 \2/p' "$D/proj.txt")"
    if [ -n "${sw:-}" ] && $PY -c "import sys; sys.exit(0 if abs($sw/$sh - $W/1080) <= 0.01 else 1)"; then row "④3D 镜头比" 过 "投影认不出，改判场景目标 ${sw}×${sh}（$($PY -c "print(round($sw/$sh,4))")）"
    else row "④3D 镜头比" 不过 "投影认不出，场景目标 ${sw:-?}×${sh:-?} 不是屏幕比"; fi
  else row "④3D 镜头比" 不过 "$(tail -1 "$D/proj.txt")"; fi
  P=$D/play; if [ ! -x "$P/bin/galplay" ]; then   # 回放器：同 tests/visual/gate.sh 编法，私有目录
    make -C "$R/graphics/metal" OUT="$P/gal" "$P/gal/libnxgal.dylib" -j8 > "$P.make.log" 2>&1 && timeout 400 dotnet build -c Release --artifacts-path "$P/art" -p:OutDir="$P/bin/" "$R/tests/visual/galplay" > "$P.build.log" 2>&1 && cp "$P/gal/libnxgal.dylib" "$P/bin/"; fi
  hp=; how=   # 录像里的上屏序号从 1 起（共 NFR 次）；逐帧找第一张有效场景深度（有绘制、不全是清屏值：游戏 30 帧上屏 60 次时隔一次才画）
  for k in $(seq 1 "$NFR"); do
    S2A_SHADER_PACK="$src/shaders" timeout 200 "$P/bin/galplay" "$D/rec/gal.rec" "$D/replay$k" --depth "$k" --frames "$k" > "$D/replay$k.log" 2>&1
    j=$D/replay$k/depth_$k.json; [ -s "$j" ] || continue
    "$PYA" -c "import json, numpy as np, sys; m = json.load(open('$j')); d = np.fromfile('${j%.json}.f32', np.float32); sys.exit(0 if m['clear'] is not None and (d == m['clear']).mean() < 0.999 else 1)" || continue
    dh=$("$PYA" -c "import json; print(json.load(open('$j'))['h'])")
    "$PYA" "$R/tests/visual/widen_holes.py" "$j" --w0 $(( (dh * 16 / 9 + 1) & ~1 )) > "$D/holes.txt" 2>&1
    hp=$(sed -nE 's/.*露空面积占两侧带 ([0-9.]+)%.*/\1/p' "$D/holes.txt" | head -1); how="深度（录像第 $k 帧，离线库未命中 $(LC_ALL=C /usr/bin/grep -a -c 离线库未命中 "$D/replay$k.log") 处）"; break
  done
  if [ -z "$hp" ]; then   # 没有有效深度（暗黑3 D24S8 读回全是清屏值等）：退到截图口径，MARK / 收尾两张都要过（清屏色与游戏同色的暗场景不适用，见 shot_holes.py）
    hp=0; for f in ap_mark ap_end; do [ -s "$D/$f.png" ] || { hp=100; continue; }
      v=$("$PYA" "$R/tests/visual/shot_holes.py" "$D/$f.png" | tee -a "$D/holes.txt" | sed -nE 's/.*两侧露空占两侧带 ([0-9.]+)%.*/\1/p'); hp=$("$PYA" -c "print(max($hp, ${v:-100}))"); done
    how="截图（ap_mark / ap_end，录像窗里没有有效深度）"
  fi
  $PY -c "import sys; sys.exit(0 if $hp <= 0.5 else 1)" && row "⑤露空 ≤0.5%" 过 "$hp%，$how" || row "⑤露空 ≤0.5%" 不过 "$hp%，${how}；$(head -1 "$D/holes.txt")"
else row "④3D 镜头比" 不过 "没录到 GAL（录像帧 $FR 不在局内？）"; row "⑤露空 ≤0.5%" 不过 "没录到 GAL"; fi
if [ $DIRECT = 1 ]; then echo "【黄】直连局不判 ⑩：界面裁剪量法靠通用回放器 galplay，直连没有 GAL 录像；界面接缝由 ③b / ③c 判"
elif [ "${S2A_LOOP_UICLIP:-1}" = 1 ]; then
  # ⑩ 界面裁剪不多切：本局 / 对照局各回放两遍（正常、--ui-noscissor），逐帧出图差像素（任一通道差 > 8）取最大
  P=$D/play; nfr=$NFR; fl=$(seq -s, 1 "$nfr" | sed 's/,$//')
  # 同产品口径：点集里有界面布局尺寸点（lytsz）= 原生层 s2a_widen_layout() 回 1，回放带 --layout-wide（对照局点集空，不带）
  LYW=(); for s in ${SITES//,/ }; do awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o && $3 == "lytsz" { f = 1 } END { exit !f }' "$D/widen_sites.tsv" 2>/dev/null && LYW=(--layout-wide); done
  clip() {   # clip <录像> <宽高比> <输出前缀> [回放附加参数…] → 打「最大值 逐帧」
    for u in n u; do e=("${@:4}"); [ $u = u ] && e+=(--ui-noscissor)
      S2A_SHADER_PACK="$src/shaders" NXGAL_BOUNDS_COUNT=0 NXGAL_SHADER_CACHE_DIR="$3_sc" timeout 200 "$P/bin/galplay" "$1" "$3_$u" --widen "$2" --game-wide --frames "$fl" ${e[@]+"${e[@]}"} > "$3_$u.log" 2>&1; done
    "$PYA" - "$3_n" "$3_u" "$nfr" <<'PY'
import sys, os, numpy as np
from PIL import Image
a, b, n = sys.argv[1], sys.argv[2], int(sys.argv[3]); v = []
for k in range(1, n + 1):
    p, q = f'{a}/present_{k}.png', f'{b}/present_{k}.png'
    if not (os.path.exists(p) and os.path.exists(q)): continue
    x = np.asarray(Image.open(p).convert('RGB')).astype(int); y = np.asarray(Image.open(q).convert('RGB')).astype(int)
    if x.shape == y.shape: v.append(int((np.abs(x - y).max(-1) > 8).sum()))
print(max(v) if v else -1, ' '.join(map(str, v)))
PY
  }
  if [ -s "$D/rec/gal.rec" ] && [ -s "$D/base/rec/gal.rec" ]; then
    ct=$(clip "$D/rec/gal.rec" "$($PY -c "print($W/1080)")" "$D/uiclip" ${LYW[@]+"${LYW[@]}"}); cb=$(clip "$D/base/rec/gal.rec" 1.7777778 "$D/base/uiclip")
    mt=${ct%% *}; mb=${cb%% *}
    if [ "$mt" -ge 0 ] && [ "$mb" -ge 0 ] && $PY -c "import sys; sys.exit(0 if $mt <= $mb * 1.5 + 2000 else 1)"; then row "⑩界面裁剪不多切" 过 "本局逐帧 ${ct#* }（最大 ${mt}）≤ 对照局 ${cb#* }（最大 ${mb}）×1.5+2000"
    else row "⑩界面裁剪不多切" 不过 "本局逐帧 ${ct#* }（最大 ${mt}）> 对照局 ${cb#* }（最大 ${mb}）×1.5+2000（或回放没出图 -1）"; fi
  else row "⑩界面裁剪不多切" 不过 "录像缺：本局 $D/rec/gal.rec / 对照局 $D/base/rec/gal.rec"; fi
fi
UIK=0; for s in ${SITES//,/ }; do awk -F'\t' -v m="${s%%:*}" -v o="${s#*:}" '$1 == m && $2 == o && ($3 == "lytsz" || $3 == "capsz") { f = 1 } END { exit !f }' "$D/widen_sites.tsv" 2>/dev/null && UIK=$((UIK + 1)); done
# 界面路线局（第二局按 S2A_ROUTE 走到界面页）随手录路线一起删了（10-31 自动玩家改 AI 看屏驾驶）：界面拷屏点不在这里判，交满屏画面线另判
[ "$UIK" -gt 0 ] && echo "【黄】点集有界面拷屏点 $UIK 个：界面路线局已随手录路线删除，⑥–⑨ 本脚本不判"
cp "$D/ap_mark.png" "$D/证据_MARK.png" 2>/dev/null
echo "== $G 闭环（档位 ${MODE}，屏幕宽 ${W}，点集 ${SITES}，main 构建号 ${BID}）"; cat "$D/verdict.tsv"
if [ "$ok" != 1 ]; then   # 三态（graphics/widen/scan/loop_state.sh）：局没起 / 构建失败 / 局超时 / 没到 MARK 等不是画面结论 → 退 75（未判，auto_table.sh 不缓存、下次触发重排）
  s=$(bash "$H/loop_state.sh" "$D"); [ "${s%%	*}" = 未判 ] && { echo "🟡 ${G} 闭环未判（不是画面结论，下次触发重排）：${s#*	}"; exit 75; }
  echo "🔴 ${G} 闭环不过，启用表不动（${s#*	}）"; exit 1
fi
echo "🟢 $G 闭环全过"
if [ "$WRITE" = --write ]; then
  E=${S2A_WIDEN_DIR:-$R/graphics/widen/tables}/${G}_$BID; mkdir -p "$E"
  $PY "$H/enable_write.py" "$D/widen_sites.tsv" "$SITES" "$E" "$MODE" || { echo "🔴 写启用表失败"; exit 75; }
  # 启用点的前后指令特征（widen_sig.py）：游戏更新换了构建号时，出包按它把这张表移植到新版本（auto_table.sh），移植出的点再过闭环
  "$PYS" "$H/widen_sig.py" make "$src/exefs" "$SITES" "$D/widen_sites.tsv" "$E/widen_sig.$MODE.tsv" || echo "🟡 启用点特征没写成（$E/widen_sig.$MODE.tsv）：游戏更新后这张表不能自动移植"
  echo "$(date '+%m-%d %H:%M') 新架构产品档位闭环（graphics/widen/scan/closed_loop.sh，档位 ${MODE}，屏幕宽 ${W}）：启用 ${SITES}；$(cut -f1,3 "$D/verdict.tsv" | tr '\t\n' ' ')；局目录 ${D/#$HOME/\~}" >> "$E/来源.txt"   # 家目录写成 ~（来源.txt 进仓库，公开仓扫描拦本机绝对路径 home_path）
  echo "启用表已写：$E/widen_enable.$MODE.tsv（提交进仓库走列车，合入后 pack/refresh.sh $G 进产物根）"
fi
