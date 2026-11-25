#!/bin/bash
# 宽屏门禁（画幅线；tests/visual/gate.sh 调用，也可单跑）：九款 GAL 金样录像，防宽屏改动回退。退出 0 = 绿；最后一行「期望 → 真结果」。
# 用法：bash tests/visual/widen_gate.sh [<galplay 所在目录（含 libnxgal.dylib）> <libnxgal 构建目录（含 gal_xc）>]   不给就自己编到私有临时目录
# 判据（表 tests/visual/widen_gate.tsv，每款一行；读数来源与根因见表头注释）：
#   ① 中间区：同一录像「不放宽」与「放宽」各回放一次，取表里的帧；放宽按产品配置：模式 G（第二层产品档位启用表 graphics/widen/tables/<款>_*/widen_enable.handheld.tsv 有启用点（产品缺省掌机档，装载器按 S2A_DOCKED 读当前档位那张）
#      = 原生层 s2a_widen_game() = 1，services/aot/Compose.cs 给包装层 gameWide）= --widen 2.1727 --game-wide；否则模式 W = --widen 2.1727。
#      模式在门禁里按启用表现算，与表里登记时的模式不同就报红（启用表变了要重新登记）。10-26 起第三层缺省整套放宽（runtime/src/widen.c s2a_widen_full）：
#      第二层没启用且 widen_full.handheld.tsv 有一行 0（闭环验出放宽会坏）= 模式 O，产品不放宽（16:9 原比例居中留黑边），这一款不回放、宽屏判据不适用。
#      tests/visual/widen_mid.py 比加宽图出图区中间与原图出图区（偏移 = 两出图区宽差 / 2；宽差为奇数 = 半像素偏移，表里没登记就判红）。
#      差异像素 ≤ 登记差异 + 噪声上界，且通道差总和 ≤ 登记总和 + 噪声总和（登记差异 = 已定位根因、未修的真差异，按帧逗号分隔、与「帧」列对位；
#      噪声 = 同录像不放宽重放的实测上界 ×2（统计量两边各带一份噪声））。
#      比登记值明显小（≤ 一半）报「改好了，请把表里登记值改小」，不判红。
#   ② 出图参数变化次数：放宽回放里出图层记的变化次数（gal_present.m「第 N 次变化」）≤ 录像原始变化次数（galplay 只读录像算的「录像出图参数变化」）+ 表里登记的额外次数。
#   ③ 回放错误 0、两遍回放都放完；放宽回放的宽屏红计数（序章补内容除外）≤ 表里登记红计数；出图区非空。
#   ④ 常量「只扫变了的」影子对照（galplay --widen-check）：旧「上传即整段改写」模型逐绘制比读到的字节，读到的矩阵（投影 / 视图投影 / 逆投影）漏改（旧改了新没改）= 0；
#      浮点条目（宽高比对 / 相机系数对 / 屏幕尺寸）的漏改照报不判红（系数对认相机签名，签名学到的时机与旧整段扫描可能不同，见 graphics/widen/README.md）。
# 录像清单 / 录像 / zstd / 回放器缺任何一样：响亮报红，不静默跳过。
# 按款挑（tools/gate.sh 派 gate-host 时由 tests/visual/gate.sh 的子项键 widen/<款> 给）：WIDEN_GATE_SKIP="<款…>" 这几款不跑（别处另跑）、WIDEN_GATE_ONLY="<款…>" 只跑这几款；
#   款名不在判据表里 = 红；末行写明另跑 / 只跑了哪几款。
# 缓存 ${S2A_WIDEN_GATE_CACHE:-~/.s2arm/run/s2arm/cache/widen_gate}（都只省时间、不影响出图）：
#   rec/<录像名>.<压缩包内容哈希前 16 位>.rec 解压后的录像，按内容常驻复用（11-18：每次解到本次临时目录，16 份约 12 GB 落在系统临时目录、跑完才删，并行时把门禁主机内置盘挤到 3 GB；
#   常驻每款只留当前版本一份，旧哈希的删）；缓存所在盘余量 < WIDEN_REC_MIN_FREE_GB（缺省 30）时退回旧做法——解到本次临时目录、退出即删（10-24 盘紧时的口径）；
#   spv/ 回放见过的 SPIR-V（SW_GAL_SPV_DUMP 累积）→ lib/<键>/ 离线着色器库（graphics/metal/tools/gal_offline.py，与运行时现编同一份翻译代码；
#   键 = tests/visual/widen_lib_key.sh：只认翻译代码 + 打包脚本，渲染器里翻译用不到的代码改了不换库）。原因：运行时现编在低优先级线程上，本机负载 60–80 时动森到第 30 帧 167 秒、
#   带离线库 7 秒、出图逐字节相同（10-21 实测）。回放里有现编（库里没有的新 SPIR-V，如包装层改了着色器）就在判完后重建库，下次就快。
set -u
R=$(pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$R/tests/visual/crash_keep.sh"   # 回放器被信号打死时留崩溃报告与日志（不稳定项 15）
RECS=${S2A_GAL_RECS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/replay/gal}
C=${S2A_WIDEN_GATE_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/widen_gate}
TAB=$R/tests/visual/widen_gate.tsv
t0=$SECONDS; red=0
die() { echo "🔴 $1"; echo "宽屏门禁：期望 九款中间区 / 出图参数 / 回放全过 → 真结果 $1，红"; exit 1; }
[ -f "$TAB" ] || die "判据表缺：$TAB"
for k in ${WIDEN_GATE_SKIP:-} ${WIDEN_GATE_ONLY:-}; do cut -f1 "$TAB" | grep -qxF "$k" || die "按款挑的 $k 不在判据表 $TAB 里"; done
[ -f "$RECS/list.tsv" ] || die "金样录像清单缺：$RECS/list.tsv"
command -v zstd > /dev/null || die "没有 zstd（brew install zstd），录像解不了"
mkdir -p "$T/rec" "$C/sh" "$C/rec" || die "缓存目录建不了：$C"
RECC=$C/rec; free_gb=$(df -Pk "$RECC" 2> /dev/null | awk 'NR == 2 { print int($4 / 1048576) }')
[ "${free_gb:-0}" -ge "${WIDEN_REC_MIN_FREE_GB:-30}" ] || { echo "⚪ 录像缓存所在盘只剩 ${free_gb:-?} GB（< ${WIDEN_REC_MIN_FREE_GB:-30}）：本次解到临时目录、退出即删"; RECC=; }
# rec_get <名> <压缩包>：让 $T/rec/<名>.rec 就位。有 RECC：按压缩包内容常驻（同内容直接用，别的树刚解完的也算——mv 原子到位；
#   同一录像的旧版本删），本次临时目录里放软链；没有 RECC：解到本次临时目录。解压失败返回 1
rec_get() {
  local k=$1 z=$2 zh base cf old
  [ -e "$T/rec/$k.rec" ] && return 0
  if [ -n "$RECC" ]; then
    zh=$(shasum -a 256 "$z" | cut -c1-16); base=${z#"$RECS"/}; base=${base%.zst}; base=${base//\//_}; cf=$RECC/$base.$zh.rec   # 基名 = 录像库里的相对路径（多款都叫 <款>/gal.rec.zst，只取文件名会互相当成旧版本删掉）
    if [ ! -f "$cf" ]; then
      zstd -q -d -f "$z" -o "$cf.tmp.$$" && mv "$cf.tmp.$$" "$cf" || { rm -f "$cf.tmp.$$"; return 1; }
      for old in "$RECC/$base".????????????????.rec; do [ "$old" = "$cf" ] || rm -f "$old"; done
    fi
    ln -s "$cf" "$T/rec/$k.rec"
  else
    zstd -q -d -f "$z" -o "$T/rec/$k.rec.tmp.$$" && mv "$T/rec/$k.rec.tmp.$$" "$T/rec/$k.rec" || { rm -f "$T/rec/$k.rec.tmp.$$"; return 1; }
  fi
}

# 量具正对照（判据会绿着失效）：合成一对图，正好居中 → 差异 0；错 1 列 → 差异 > 0
python3 - "$T/pc" <<'EOF' || die "量具正对照没过（widen_mid.py 坏了）"
import json, os, subprocess, sys
import numpy as np
from PIL import Image
d = sys.argv[1]; r = np.random.default_rng(1).integers(0, 256, (720, 1564, 3), dtype=np.uint8)
for name, img, off in (('a', r[:, 142:1422], 0), ('w', r, 0), ('x', np.roll(r, 1, axis=1), 0)):
    os.makedirs(f'{d}/{name}', exist_ok=True); Image.fromarray(img).save(f'{d}/{name}/present_1.png')
    h, w = img.shape[:2]; json.dump({'raw': [w, h, 0, w, 0, h], 'out': [w, h, 0, w, 0, h]}, open(f'{d}/{name}/present_1.json', 'w'))
def n(b, w):
    o = subprocess.run([sys.executable, 'tests/visual/widen_mid.py', f'{d}/{b}', f'{d}/{w}', '1'], capture_output=True, text=True).stdout
    return int([l for l in o.splitlines() if l.startswith('MID')][0].split('\t')[5])
sys.exit(0 if n('a', 'w') == 0 and n('a', 'x') > 0 else 1)
EOF

# 回放器
if [ $# -ge 1 ]; then PLAY=$1
else
  PLAY=$T/play
  make -C graphics/metal OUT="$T/gal" "$T/gal/libnxgal.dylib" -j8 > "$T/make.log" 2>&1 || { tail -5 "$T/make.log"; die "libnxgal 编译失败"; }
  make -C graphics/dsx OUT="$T/dsx" "$T/dsx/libdsx.dylib" >> "$T/make.log" 2>&1 || { tail -5 "$T/make.log"; die "libdsx 编译失败"; }   # 回放器参照端循环上限 DllImport("dsx")
  timeout 400 dotnet build -c Release --artifacts-path "$T/art" -p:OutDir="$PLAY/" tests/visual/galplay > "$T/build.log" 2>&1 || { grep -E ' error ' "$T/build.log" | sort -u | head -5; die "galplay 编译失败"; }
  cp "$T/gal/libnxgal.dylib" "$T/dsx/libdsx.dylib" "$PLAY/"
fi
[ -x "$PLAY/galplay" ] && [ -f "$PLAY/libnxgal.dylib" ] || die "回放器没编出来：$PLAY/galplay / libnxgal.dylib"
if [ $# -ge 2 ]; then GALB=$2; else GALB=$T/gal; make -C graphics/metal OUT="$GALB" "$GALB/gal_xc" > "$T/make_xc.log" 2>&1 || { tail -5 "$T/make_xc.log"; die "gal_xc 编译失败"; }; fi
[ -x "$GALB/gal_xc" ] || die "gal_xc 没编出来：$GALB/gal_xc"
tb=$((SECONDS - t0))
# 离线着色器库：没有本键的库就先用累积的 SPIR-V 建（.air 按 MSL 内容缓存，翻译没变的支不重编）
KEY=$(bash tests/visual/widen_lib_key.sh) && [ ${#KEY} = 16 ] || die "离线着色器库键算不出（tests/visual/widen_lib_key.sh）"
LIB=$C/lib/$KEY; mkdir -p "$C/spv" "$C/lib"
# 被杀的门禁留下的半成品 lib/.<键>.<pid>（各约 110 MB）：建它的进程不在了就删
for d in "$C"/lib/.*.*; do p=${d##*.}; case $p in ''|*[!0-9]*) continue;; esac; [ -d "$d" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$d"; done
mklib() {
  local tmp=$C/lib/.$KEY.$$
  rm -rf "$tmp"; GAL_XC=$GALB/gal_xc python3 graphics/metal/tools/gal_offline.py "$C/spv" "$tmp" macos > "$T/lib.log" 2>&1 && rm -rf "$LIB" && mv "$tmp" "$LIB" \
    || { rm -rf "$tmp"; echo "🔴 离线着色器库建不出（不影响判据，只是慢）：$(tail -1 "$T/lib.log")"; }
  # 只留最近 3 个键；2 小时内用过的不删（别的门禁可能正在用，用时 touch）
  ls -td "$C"/lib/*/ 2> /dev/null | tail -n +4 | while read -r old; do [ -n "$(find "$old" -maxdepth 0 -mmin +120)" ] && rm -rf "$old"; done
}
[ -f "$LIB/gal.shards" ] || { [ -n "$(ls "$C/spv" 2> /dev/null)" ] && mklib; }
tl=$((SECONDS - t0))

# 表：款 模式 帧 噪声差异像素 噪声通道差总和 登记差异像素 登记通道差总和 出图参数额外变化 登记红计数 奇偏移已登记 录像 横向比例 说明
#   录像：相对 $RECS 的路径，「-」= list.tsv 里这一款那份（换录像 = 新文件名放旁边 + 改本列，和新登记值同一提交走列车，门禁数据不先于代码生效）
#   横向比例：「-」= 判中间区逐像素；数值 = 改判横向比例拟合（tests/visual/widen_mid.py --scale，|s − 期望| ≤ 0.01 且最小平均通道差 ≤ 3），登记差异两列填「-」
GAMES=(); GAMES_O=0
while IFS=$'\t' read -r g mode fr nn ns kn ks xc rok odk recc sc note; do
  case $g in ''|'#'*|款) continue;; esac
  if [ -n "${WIDEN_GATE_ONLY:-}" ]; then case " $WIDEN_GATE_ONLY " in *" $g "*) ;; *) continue;; esac; fi
  case " ${WIDEN_GATE_SKIP:-} " in *" $g "*) continue;; esac
  # 产品配置：启用表有启用点 = 游戏自己出宽图（模式 G）
  en=$(cat graphics/widen/tables/"${g}"_*/widen_enable.handheld.tsv 2> /dev/null | awk -F'\t' 'NR > 1 && $4 == 1' | wc -l | tr -d ' ')
  # 第二层启用 = G；否则第三层表写了 0（widen_full.handheld.tsv 有一行 0，闭环验出放宽会坏）= O（不放宽，16:9 原比例居中留黑边，宽屏判据不适用）；其余 = W（10-26 起缺省整套放宽）
  fz=$(cat graphics/widen/tables/"${g}"_*/widen_full.handheld.tsv 2> /dev/null | grep -cx 0)
  pm=W; [ "$fz" -gt 0 ] && pm=O; [ "$en" -gt 0 ] && pm=G
  [ "$pm" = "$mode" ] || { red=1; echo "🔴 ${g}：产品配置是模式 ${pm}（启用表 $en 个启用点、第三层表写 0 的行 ${fz}），表里登记的是 $mode —— 启用表变了，要重新量、重新登记"; continue; }
  [ "$mode" = O ] && { echo "🟢 ${g}：第三层验出放宽会坏、第二层没启用 → 不放宽（16:9 原比例居中留黑边），宽屏判据不适用"; GAMES_O=$((GAMES_O + 1)); continue; }
  if [ "${recc:--}" = - ]; then rec=$(awk -F'\t' -v g="$g" '$1 == g { print $2 }' "$RECS/list.tsv"); else rec=$recc; fi
  [ -n "$rec" ] && [ -f "$RECS/$rec" ] || { red=1; echo "🔴 ${g}：金样录像缺（${rec:-list.tsv 里没有这款}）"; continue; }
  z=$RECS/$rec
  rec_get "$g" "$z" || { red=1; echo "🔴 ${g}：录像解压失败 $z"; continue; }
  GAMES+=("$g	$mode	$fr	$nn	$ns	$kn	$ks	$xc	$rok	$odk	${sc:--}")
done < "$TAB"
[ ${#GAMES[@]} -gt 0 ] || [ "$GAMES_O" -gt 0 ] || die "判据表里一款都没跑成"
tz=$((SECONDS - t0))
# 按产品配置回放：越界 / 循环到上限计数关（NXGAL_BOUNDS_COUNT=0，iOS 产品缺省）。macOS 缺省开时函数常量特化进计数代码，个别像素浮点结果差 1 级
#   （10-21 动森帧 30 中间区 7963 → 7964，关计数即回 7963）；计数由 Mac 局 tools/zero_gate.py 单独判，不混进逐像素登记
ENVS=(NXGAL_BOUNDS_COUNT=0 NXGAL_SHADER_CACHE_DIR=$C/sh SW_GAL_SPV_DUMP=$C/spv); [ -f "$LIB/gal.shards" ] && { ENVS+=(NXGAL_SHLIB_DIR=$LIB); touch "$LIB"; }

# 回放：每款 不放宽（A）+ 放宽（W / G）各一次，全部并行；只放到表里最后一帧
# 收卡死按进展、不按固定墙钟（11-25）：galplay 每次上屏写进展文件，RIDLE 秒没有新上屏或总时长到 RHARD 才收（退出码同 timeout 的 124）。
#   原先每遍 timeout 150：门禁步骤一律 taskpolicy -c utility 跑，18 遍并行回放在高负载门禁主机上最重的两款放到 150 秒被杀、
#   判「回放没放完」，同提交换空闲主机复跑绿（11-24 21:16、11-25 00:32 / 00:51 三次）——慢不是错，卡住才是
RIDLE=${WIDEN_REPLAY_IDLE_S:-120}; RHARD=${WIDEN_REPLAY_HARD_S:-900}
TPLAY=$(date +%s)   # 回放开局时刻：崩溃留证只收这之后的报告
for row in "${GAMES[@]}"; do
  IFS=$'\t' read -r g mode fr _ <<< "$row"
  last=${fr##*,}; ex=(--widen 2.1727 --widen-check); [ "$mode" = G ] && ex+=(--game-wide)
  # 同产品 s2a_widen_layout()：第二层启用了界面布局尺寸点（lytsz）= 游戏界面布局也是宽的
  [ "$mode" = G ] && [ "$(cat graphics/widen/tables/"${g}"_*/widen_enable.handheld.tsv 2> /dev/null | awk -F'\t' 'NR > 1 && $4 == 1 && $3 == "lytsz"' | wc -l | tr -d ' ')" -gt 0 ] && ex+=(--layout-wide)
  ( bash tools/idle_timeout.sh "$RIDLE" "$RHARD" "$T/$g.A.prog" -- env "${ENVS[@]}" NXGAL_XC_LOG="$T/$g.A.xc" GALPLAY_PROGRESS="$T/$g.A.prog" "$PLAY/galplay" "$T/rec/$g.rec" "$T/$g/A" --frames "$fr" --until $((last + 1)) > "$T/$g.A.log" 2>&1; echo $? > "$T/$g.A.rc" ) &
  ( bash tools/idle_timeout.sh "$RIDLE" "$RHARD" "$T/$g.W.prog" -- env "${ENVS[@]}" NXGAL_XC_LOG="$T/$g.W.xc" GALPLAY_PROGRESS="$T/$g.W.prog" "$PLAY/galplay" "$T/rec/$g.rec" "$T/$g/W" --frames "$fr" --until $((last + 1)) "${ex[@]}" > "$T/$g.W.log" 2>&1; echo $? > "$T/$g.W.rc" ) &
done
wait
tr=$((SECONDS - t0))

nf=0; nfp=0; ng=0; ngp=0; known=0
for row in "${GAMES[@]}"; do
  IFS=$'\t' read -r g mode fr nn ns kn ks xc rok odk sc <<< "$row"
  ng=$((ng + 1)); gr=0
  ra=$(cat "$T/$g.A.rc" 2> /dev/null || echo 无); rw=$(cat "$T/$g.W.rc" 2> /dev/null || echo 无)
  ea=$(grep -ao '回放错误 [0-9]*' "$T/$g.A.log" | head -1 | grep -o '[0-9]*$'); ew=$(grep -ao '回放错误 [0-9]*' "$T/$g.W.log" | head -1 | grep -o '[0-9]*$')
  rc=$(grep -ao '游戏行为红计数 [0-9]*' "$T/$g.W.log" | head -1 | grep -o '[0-9]*$')
  # galplay 退出码：0 = 无错且红计数 0，1 = 有回放错误或红计数；其他（124 超时、134 崩）= 没放完
  if [ "$ra" != 0 ] || { [ "$rw" != 0 ] && [ "$rw" != 1 ]; } || [ "${ea:-x}" != 0 ] || [ "${ew:-x}" != 0 ] || [ -z "$rc" ]; then
    gr=1; echo "🔴 ${g}：回放没放完或有错 —— 退出码 不放宽 $ra / 放宽 ${rw}，回放错误 ${ea:-?} / ${ew:-?}"; grep -aE '回放错误|Unhandled|Exception' "$T/$g.W.log" "$T/$g.A.log" | head -3 | sed 's/^/    | /'
    # 被信号打死（≥ 128、不是 timeout 的 124）：留崩溃报告与两遍日志（10-26 witcher3 放宽回放 138 = SIGBUS，没留下报告、定不了因）
    for p in A:"$ra" W:"$rw"; do case ${p#*:} in 124|无) ;; *) [ "${p#*:}" -ge 128 ] 2> /dev/null && crash_keep "widen_${g}_${p%%:*}" "$TPLAY" galplay "$T/$g.A.log" "$T/$g.W.log" "$T/$g.${p%%:*}.xc";; esac; done
  elif [ "$rc" -gt "$rok" ]; then gr=1; echo "🔴 ${g}：宽屏红计数（序章补内容除外）$rc > 登记 $rok"; grep -a '^\[宽屏\] k' "$T/$g.W.log" | grep -o '红：.*' | head -1 | sed 's/^/    | /'
  fi
  # ④ 影子对照：漏改 0
  ck=$(grep -ao '影子对照：比了 [0-9]* 次 vec4 读；不一致（按缓冲 / 偏移 / 内容版本去重）漏改矩阵 [0-9]*、漏改 [0-9]*、多改 [0-9]*' "$T/$g.W.log" | head -1)
  miss=$(echo "$ck" | grep -o '漏改矩阵 [0-9]*' | grep -o '[0-9]*$')
  if [ -z "$miss" ]; then gr=1; echo "🔴 ${g}：影子对照读不到（galplay 没带 --widen-check？）"
  elif [ "$miss" -gt 0 ]; then gr=1; echo "🔴 ${g}：$ck —— 只扫变了的漏改矩阵"; grep -a '^漏改' "$T/$g.W.log" | head -3 | sed 's/^/    | /'
  else echo "🟢 ${g}：${ck#影子对照：}"; fi
  # ② 出图参数变化
  raw=$(grep -ao '录像出图参数变化 [0-9]*' "$T/$g.W.log" | head -1 | grep -o '[0-9]*$')
  act=$(grep -ao '第 [0-9]* 次出图起，第 [0-9]* 次变化' "$T/$g.W.log" | grep -o '第 [0-9]* 次变化' | grep -o '[0-9]*' | sort -n | tail -1)
  if [ -z "$raw" ] || [ -z "$act" ]; then gr=1; echo "🔴 ${g}：出图参数变化读不到（录像 ${raw:-无} / 出图层 ${act:-无}）"
  elif [ "$act" -gt $((raw + xc)) ]; then gr=1; echo "🔴 ${g}：出图参数变化 $act 次 > 期望 ≤ 录像原始 $raw + 登记额外 $xc"
  else echo "🟢 ${g}：出图参数变化 $act 次（期望 ≤ 录像原始 $raw + 登记额外 ${xc}）"; fi
  # ① 横向比例（「游戏出宽缓冲、投影仍 16:9」的录像：不放宽回放本身被拉伸，中间区逐像素不成立）
  if [ "$sc" != - ]; then
    IFS=, read -ra FRS <<< "$fr"
    for f in "${FRS[@]}"; do
      nf=$((nf + 1))
      out=$(python3 tests/visual/widen_mid.py --scale "$T/$g/A" "$T/$g/W" "$f" 2>&1); m=$(echo "$out" | grep '^SCALE')
      if [ -z "$m" ]; then gr=1; echo "🔴 $g 帧 ${f}：$(echo "$out" | head -1)"; continue; fi
      IFS=$'\t' read -r _ s e e1 <<< "$m"
      line="$g 帧 ${f}（${mode}）：横向比例 ${s}（期望 $sc ± 0.01），平均通道差 ${e}（≤ 3；不缩 ${e1}）"
      if python3 -c "import sys; sys.exit(0 if abs($s - $sc) <= 0.01 and $e <= 3 else 1)"; then nfp=$((nfp + 1)); echo "🟢 $line"; else gr=1; echo "🔴 $line"; fi
    done
    [ $gr = 0 ] && ngp=$((ngp + 1)) || red=1
    continue
  fi
  # ① 中间区
  IFS=, read -ra FRS <<< "$fr"; IFS=, read -ra KNS <<< "$kn"; IFS=, read -ra KSS <<< "$ks"
  [ ${#KNS[@]} = ${#FRS[@]} ] && [ ${#KSS[@]} = ${#FRS[@]} ] || { gr=1; red=1; echo "🔴 ${g}：表里登记值个数与帧数对不上"; continue; }
  for i in "${!FRS[@]}"; do
    f=${FRS[$i]}; kn=${KNS[$i]}; ks=${KSS[$i]}
    nf=$((nf + 1))
    out=$(python3 tests/visual/widen_mid.py "$T/$g/A" "$T/$g/W" "$f" 2>&1); m=$(echo "$out" | grep '^MID')
    if [ -z "$m" ]; then gr=1; echo "🔴 $g 帧 ${f}：$(echo "$out" | head -1)"; continue; fi
    IFS=$'\t' read -r _ w0 w1 h off n sad mx odd <<< "$m"
    lim=$((kn + nn)); slim=$((ks + ns)); line="$g 帧 ${f}（${mode}）：出图区 ${w0}→${w1}×$h 偏移 ${off}，中间区差异像素 ${n}（≤ 登记 $kn + 噪声 ${nn}），通道差总和 ${sad}（≤ $ks + ${ns}），最大差 $mx"
    [ "$odd" = 1 ] && line="${line}，宽差奇数（半像素偏移）"
    if [ "$w0" -le 0 ] || [ "$h" -le 0 ]; then gr=1; echo "🔴 ${line}：出图区空"
    elif [ "$odd" = 1 ] && [ "$odk" != 1 ]; then gr=1; echo "🔴 ${line}：出图区宽差为奇数，中间区不在整数像素上（表里没登记）"
    elif [ "$n" -gt "$lim" ] || [ "$sad" -gt "$slim" ]; then gr=1; echo "🔴 $line"; echo "$out" | head -1 | sed 's/^/    | /'
    else nfp=$((nfp + 1)); [ "$kn" -gt 0 ] && known=$((known + 1))
      if [ "$kn" -gt 0 ] && [ $((n * 2)) -le "$kn" ]; then echo "🟢 $line —— 比登记值少一半以上：改好了，请把 widen_gate.tsv 登记值改小"; else echo "🟢 $line"; fi
    fi
  done
  [ $gr = 0 ] && ngp=$((ngp + 1)) || red=1
done
# ⑤ 上屏两侧来历正例（tests/visual/widen_bands.tsv）：放宽回放逐帧「上屏两侧种类」（galplay 报告）前 N 帧与期望逐个相同；按款挑（WIDEN_GATE_ONLY）时不跑
nb=0; nbp=0
if [ -z "${WIDEN_GATE_ONLY:-}" ]; then
  while IFS=$'	' read -r brec bn bexp bnote bargs; do
    case $brec in ''|'#'*|录像) continue;; esac
    nb=$((nb + 1)); bk=bands_$(echo "$brec" | tr '/.' '__')
    [ -f "$RECS/$brec" ] || { red=1; echo "🔴 两侧来历正例录像缺：$RECS/${brec}（${bnote}）"; continue; }
    rec_get "$bk" "$RECS/$brec" || { red=1; echo "🔴 两侧来历正例录像解压失败：$brec"; continue; }
    BA=(--widen 2.1727); [ -n "${bargs:-}" ] && read -r -a BA <<< "$bargs"   # 第 5 列回放参数（空 = 整套放宽）；按空格拆成数组，不靠 zsh / bash 分词差异
    # 录像旁有同名 .widen.idx（出包的宽屏索引）就按产品口径回放：没有它镜头点认不出，读改写镜头的绘制当界面画（10-23 八方2 存档页：无索引逐帧 3、有索引 0 / 2）
    BE=(); bidx="$RECS/${brec%.rec.zst}.widen.idx"; [ -f "$bidx" ] && BE=(S2A_WIDEN_IDX="$bidx")
    env "${ENVS[@]}" ${BE[@]+"${BE[@]}"} timeout 150 "$PLAY/galplay" "$T/rec/$bk.rec" "$T/$bk" --until "$bn" "${BA[@]}" > "$T/$bk.log" 2>&1
    # 取值按字面分隔符「）：」切（不用 [^：] 一类全角反选：C 区域下按字节算，「，」「；」与「：」共用前两个字节会断）
    got=$(awk -F'）：' '/^上屏两侧种类/ { print $2; exit }' "$T/$bk.log" | tr ' ' '\n' | head -n "$bn" | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$bexp" ]; then nbp=$((nbp + 1)); echo "🟢 两侧来历 $brec 前 $bn 帧：$got"
    else red=1; echo "🔴 两侧来历 $brec 前 $bn 帧：期望 $bexp → 真结果 ${got:-（报告里没有逐帧种类）}（${bnote}）"; fi
  done < tests/visual/widen_bands.tsv
fi
# ⑥ 界面全画布元素铺满正例（tests/visual/widen_fill.tsv）：放宽回放该帧出图区里，16:9 边界（内缩 in 列）两侧各 6 列平均亮度差左右都 ≤ 门限（遮罩 / 底板铺到屏幕边、边界上没有跳变）；按款挑时不跑
nfl=0; nflp=0
if [ -z "${WIDEN_GATE_ONLY:-}" ]; then
  while IFS=$'\t' read -r frec ffr flim fnote; do
    case $frec in ''|'#'*|录像) continue;; esac
    nfl=$((nfl + 1)); fk=fill_$(echo "$frec" | tr '/.' '__')
    [ -f "$RECS/$frec" ] || { red=1; echo "🔴 铺满正例录像缺：$RECS/${frec}（${fnote}）"; continue; }
    rec_get "$fk" "$RECS/$frec" || { red=1; echo "🔴 铺满正例录像解压失败：$frec"; continue; }
    env "${ENVS[@]}" timeout 150 "$PLAY/galplay" "$T/rec/$fk.rec" "$T/$fk" --frames "$ffr" --until $((ffr + 1)) --widen 2.1727 > "$T/$fk.log" 2>&1
    line=$(python3 - "$T/$fk" "$ffr" "$flim" <<'EOF'
import json, sys
import numpy as np
from PIL import Image
d, f, lim = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    j = json.load(open(f'{d}/present_{f}.json'))['out']; a = np.asarray(Image.open(f'{d}/present_{f}.png').convert('RGB')).astype(float)[j[4]:j[5], j[2]:j[3]].mean(axis=2)
except Exception as e:
    print(f'NG 读不到出图：{e}'); sys.exit()
h, w = a.shape; i = (w - round(h * 16 / 9)) // 2; cm = a.mean(axis=0)
if i < 8: print(f'NG 出图区 {w}×{h} 不比 16:9 宽'); sys.exit()
l = abs(cm[i - 6:i].mean() - cm[i:i + 6].mean()); r = abs(cm[w - i - 6:w - i].mean() - cm[w - i:w - i + 6].mean())
print(f'{"OK" if l <= lim and r <= lim else "NG"} 出图区 {w}×{h} 内缩 {i}：16:9 边界两侧各 6 列亮度差 左 {l:.1f} 右 {r:.1f}（门限 {lim:g}）')
EOF
)
    case $line in OK*) nflp=$((nflp + 1)); echo "🟢 铺满 $frec 帧 ${ffr}：${line#OK }";; *) red=1; echo "🔴 铺满 $frec 帧 ${ffr}：${line#NG }（${fnote}）";; esac
  done < tests/visual/widen_fill.tsv
fi
tj=$((SECONDS - t0))
# 回放里有现编（离线库没有的 SPIR-V）：重建库，下次就快（不影响本次判据）
nxc=$(cat "$T"/*.xc 2> /dev/null | grep -vc '^#')
[ "$nxc" -gt 0 ] && mklib
tt=$((SECONDS - t0))
echo "墙钟：编回放器 $tb 秒、离线库 $((tl - tb)) 秒、解压 $((tz - tl)) 秒、回放 $((tr - tz)) 秒、判 $((tj - tr)) 秒、现编 $nxc 支$([ "$nxc" -gt 0 ] && echo "→重建库 $((tt - tj)) 秒")，共 $tt 秒（射程 ${#GAMES[@]} 款 $nf 帧，各两遍回放）"
echo "宽屏门禁：期望 九款中间区 ≤ 登记 + 噪声（或横向比例 ≈ 登记）、出图参数变化 ≤ 录像 + 登记、回放无错 → 真结果 $ngp/$ng 款过（另 $GAMES_O 款不放宽）、中间区 $nfp/$nf 帧过、两侧来历正例 $nbp/$nb 段过、全画布铺满正例 $nflp/$nfl 段过（其中 $known 帧带登记差异，根因见 widen_gate.tsv）、$tt 秒，$([ $red = 0 ] && echo 绿 || echo 红)${WIDEN_GATE_SKIP:+（另跑：${WIDEN_GATE_SKIP}）}${WIDEN_GATE_ONLY:+（只跑：${WIDEN_GATE_ONLY}）}"
exit $red
