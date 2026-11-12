#!/bin/bash
# 抽 Switch 着色器（10-25 维护者「抽着色器只做一次」）：bash graphics/tools/direct/extract.sh <产物根（含 romfs/ exefs/main，可有 aoc/）> <输出目录>
# 出包里的抽取都走这一份：共享抽取阶段 pack/stage_extract.sh 出到 <产物根>/extract/（按游戏输入 + 抽取代码的键，键不变就不重抽）；
#   直连库 direct_lib.sh 有 <产物根>/extract/ok 就克隆来用，没有（单独调用 / 单测）就当场调本脚本，两边结果同一份代码出。
# 输出：ue_shaders/（RomFS 有 .pak 时 pack/ue_pak.py 解出的 Unreal 着色器代码存档，shader_split 读）、
#   glslc_capture/（游戏运行时才用自带 glslcCompile 编着色器的款：translator/glslc_offline.py 出包期调游戏的编译器离线编 main 与 RomFS NRO 里的 GLSL 源码，shader_split 按 DM_GLSLC_CAPTURE 读）、pkg/ + split/{shader_map,shader_facts,shader_pairs}.tsv（直连抽取 shader_split.py）、
#   s2x/（S2Arm nxsh_extract.py，rows.tsv + src/）、各自的 .log、ok（全部成功才写）。追加内容（aoc/<序号>/）两边都并进来，同 direct_lib.sh 原先的 ①②。
# 配置档：shader_split 读 DM_GAME / DM_GAMES_DIR 选的档（shader_groups / shader_note / modules、shader_facts_manual.tsv），调用方设好（stage_extract.sh、direct_lib.sh 都设）。
# 并行：J 路（J / S2A_CPU_BAKE = 本阶段分到的路数，tools/cores.sh；都没给才用 S2A_JOBS / 本机核数），两个抽取器内部都按 J 开进程池。
# 进度：出包进度协议（tools/progress.sh）阶段「抽取」= 第几步 / 4 步，两个抽取器内部各有 Ticker
# 退出码：0 = 三份都出成；3 = 只给直连用的几份（Unreal 存档、GLSLC 离线编、直连抽取）出不来，或两边抽取合起来 0 支着色器（直连库一个键都出不了），
#   打「🔴 直连库失败：<原因>」，调用方只出通用包（10-26 运维线：空洞骑士 Unity 无类型树，原先整次出包 rc=1、连通用包都没有；10-29 神之天平 外传：运行时 GLSLC 款抽到 0 支，
#   原先照常往下出库、到换库核验「一个键都没出」才 rc=1 整包停住；通用着色器阶段自己抽，不依赖这里）；1 = 其余（缺文件、S2Arm 抽取失败——通用也要用它）
set -u
PD=-P; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) PD=-L;; esac   # Windows 工作区走短根联接，-P 会展开回长路径
ROOT=$(cd "${1:?产物根}" && pwd $PD) || exit 1; X=${2:?输出目录}
R=$(cd "$(dirname "$0")/../../.." && pwd); NX=$R/graphics/nvn
# Windows（Git Bash / MSYS）：pwd 给的是 /r/... 写法，只有命令行参数会被自动转成 R:/...，经环境变量或文件交给 Windows 原生 Python 的不会转
#   （11-04 Windows 出包机旷野之息：shader_split 读 /r/.../exefs/main 报找不到路径）。产物根、输出目录、仓库路径统一换成 R:/... 混合写法（bash 自己也认）
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ROOT=$(cygpath -m "$ROOT"); X=$(cygpath -m "$X"); R=$(cygpath -m "$R"); NX=$R/graphics/nvn;; esac
PY=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; PY=${PY:-$(command -v python3)}
export J=${J:-${S2A_CPU_BAKE:-${S2A_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}}}
# 抽取每路吃内存（#711：Windows 16 GB 抽取 MemoryError）：给了 S2A_CPU_BAKE（按内存封顶的重活路数，tools/cores.sh / oneclick_win）就不超过它——
#   调用方常把 J 设成直连库编译的路数（每路只吃一个 metal 进程，16 GB 可开 23 路），抽取照它开就绕过了内存封顶
[ -n "${S2A_CPU_BAKE:-}" ] && [ "$S2A_CPU_BAKE" -ge 1 ] 2> /dev/null && [ "$J" -gt "$S2A_CPU_BAKE" ] && export J=$S2A_CPU_BAKE
source "$R/tools/progress.sh"
say() { echo "[抽取] $*"; }
why() { local w; w=$(grep -a '\[RED\]\|【红】' "$1" 2> /dev/null | tail -1); [ -n "$w" ] || w=$(grep -a . "$1" 2> /dev/null | tail -1); echo "$w" | sed 's/^\[RED\] *//' | cut -c1-200; }   # 失败原因：红行优先，没有取末行
PS=0; prog() { PS=$((PS + 1)); say "第 ${PS}/4 步 $*"; prog_tick 抽取 $((PS - 1)) 4; }
[ -d "$ROOT/romfs" ] && [ -f "$ROOT/exefs/main" ] || { say "🔴 $ROOT 缺 romfs/ 或 exefs/main"; exit 1; }
rm -rf "$X"; mkdir -p "$X/split" "$X/pkg" || exit 1
# 资源目录列表走列表文件（一行一个，参数写 @<文件>），不拼进命令行：11-05 Windows 出包机怪猎崛起 273 个追加内容，逗号串超过 Windows 命令行 32767 字符上限，
#   起 Python 就报「Argument list too long」
AOCS=(); for a in "$ROOT"/aoc/*/; do [ -d "$a" ] || continue; AOCS+=("${a%/}"); done
printf '%s\n' "$ROOT/romfs" ${AOCS[@]+"${AOCS[@]}"} > "$X/roms.lst"
for a in "$ROOT/romfs" ${AOCS[@]+"${AOCS[@]}"}; do echo "$ROOT/exefs/main"; done > "$X/mains.lst"
# S2Arm 抽取（nxsh_extract）只读 romfs / exefs / aoc，不依赖下面 Unreal 存档 / GLSLC / 直连抽取三步的产出：开头就在后台起，与三步并行，
#   末尾等它（11-03 Switch 2 出包线：火纹 S2Arm 293 秒 + 直连抽取 132 秒原先串行；两边结果只在 direct_lib.sh 的 merge_extract.py 取并集）。
#   nxsh_extract 自带 J 路进程池（在 shbake 下、进通用烘焙键，不在它里面逐项接）；J 默认是 S2A_CPU_BAKE，已按内存封顶
#   各步不设固定墙钟超时，改无进展看门狗（tools/nostall.py：S2A_NOSTALL_S，缺省 600 秒里输出目录 / 日志没有新写入、进程树 CPU 没涨、也没有编译子进程活着，才判挂死、退 124）。
#   10-30 维护者 / 维护者 出包管线深修①：固定超时把满载下的正常慢当挂死杀——塞尔达 S2Arm 抽取平时 443 秒、满载下过了 timeout 900 被杀两次，s2x.log 只剩信号量泄漏告警
#   前面三步出错提前退出时，EXIT 钩子 TERM 后台这一路（nostall.py 把 TERM 转给整棵子进程树）
# 两路并行时合计不超过本阶段分到的 J（11-04 一次成功线：原先 nxsh_extract 后台 J 路 + 下面三步各 J 路同时跑 = 2J，超了 tools/cores.sh 分给本单的核；
#   普查 3 道 + 手测包同机时 1 分钟负载冲到 212）：S2Arm 抽取分 JX = ⌈J/2⌉ 路，三步分其余 JR = J − JX 路（下限 1）；ok 里 jobs 仍记本阶段总路数 JT
JT=$J; JX=$(( (J + 1) / 2 )); JR=$(( J - JX )); [ "$JR" -ge 1 ] || JR=1
sx=$SECONDS
J=$JX "$PY" "$R/tools/nostall.py" --watch "$X" "${S2A_NOSTALL_S:-600}" -- "$PY" "$R/graphics/tools/shbake/nxsh_extract.py" "$X/s2x" "@$X/roms.lst" --nso "$ROOT/exefs/main" > "$X/s2x.log" 2>&1 &
SXP=$!; trap '[ -n "${SXP:-}" ] && kill -TERM "$SXP" 2> /dev/null' EXIT
export J=$JR
s=$SECONDS
# Unreal 着色器（10-25 维护者：上游靠它的 NSP 脚本出 ue_shaders、我方原来没有这一步，八方2 直连库出不来）：RomFS 里有 .pak 就由 pack/ue_pak.py 取出 / 合成解好的着色器代码存档
prog "Unreal 着色器存档"
# RomFS 里有没有 Unreal 包：经 graphics/nvn/tools/romfs_list.py（仓库里唯一的 RomFS 遍历；同 find -iname … -print -quit）
if "$PY" "$R/graphics/nvn/tools/romfs_list.py" has-ext "$ROOT/romfs" .pak .utoc 2> /dev/null; then
  "$PY" "$R/pack/ue_pak.py" "$ROOT/romfs" "$X/ue_shaders" > "$X/ue_pak.log" 2>&1 || { say "🔴 直连库失败：Unreal 着色器存档抽不出（$(why "$X/ue_pak.log")；$X/ue_pak.log）"; exit 3; }
  say "$(tail -1 "$X/ue_pak.log")"
fi
tu=$((SECONDS - s)); s=$SECONDS
# 运行时 GLSLC 款（main 或 RomFS 的 NRO 模块有 GLSL 源码、main 导入 glslcCompile、另有模块定义它）：出包期用游戏自带的编译器离线编（要不要编由 glslc_offline.py 自己判，不需要就一行、不出文件）
# Windows 还不能在出包期跑游戏自带的 GLSLC（pack/orch/oneclick_win.py glslc_gate 设 S2A_GLSLC_RUNTIME_ONLY=1）：不编，运行时由游戏自带编译器编、直连首遇现编接住（11-08 DQB2 实测进游戏，提交线程等 < 1 ms）
if [ "${S2A_GLSLC_RUNTIME_ONLY:-}" = 1 ]; then
  prog "GLSLC 离线编（本平台跳过）"; say "GLSLC 离线编：本平台跳过，运行时现编"; mkdir -p "$X/glslc_capture"
else
  prog "GLSLC 离线编（${J} 路）"
  "$PY" "$R/tools/nostall.py" --watch "$X" "${S2A_NOSTALL_S:-600}" -- "$PY" "$NX/../../translator/glslc_offline.py" "$ROOT" "$X/glslc_capture" > "$X/glslc.log" 2>&1 \
    || { say "🔴 直连库失败：GLSLC 离线编失败（$(why "$X/glslc.log")；$X/glslc.log）"; exit 3; }
  say "$(tail -1 "$X/glslc.log")"
fi
GC=(); ls "$X/glslc_capture"/*.glslc > /dev/null 2>&1 && GC=(DM_GLSLC_CAPTURE="$X/glslc_capture")   # 编出了才指给 shader_split（没编的款照旧读 <版本目录>/glslc_capture）
tg=$((SECONDS - s)); s=$SECONDS
prog "抽取着色器（直连抽取，${J} 路）"
env ${GC[@]+"${GC[@]}"} "DM_UE_SHADERS=$X/ue_shaders" "DM_OODLE_LOG_DIR=$X" "$PY" "$R/tools/nostall.py" --watch "$X" "${S2A_NOSTALL_S:-600}" -- "$PY" "$NX/../../translator/shader_split.py" "@$X/roms.lst" "@$X/mains.lst" "$X/pkg" \
  "$X/split/shader_map.tsv" "$X/split/shader_facts.tsv" "$X/split/shader_pairs.tsv" > "$X/split.log" 2>&1 \
  || { say "🔴 直连库失败：直连抽取失败（$(why "$X/split.log")；$X/split.log）"; tail -3 "$X/split.log"; exit 3; }
ts=$((SECONDS - s)); s=$SECONDS
prog "抽取着色器（S2Arm，${JX} 路，开头已在后台起）"
wait "$SXP"; sxrc=$?; SXP=
# S2Arm 抽取没跑成（v0.3.1 拿不准不停；#711 Windows MemoryError 原先就停在这里）：只用直连抽取的结果往下走，S2Arm 那份置空、记一笔
if [ $sxrc != 0 ]; then
  sw=$(grep -a '\[RED\]\|【红】\|Error' "$X/s2x.log" 2> /dev/null | tail -1 | cut -c1-200); [ -n "$sw" ] || sw=$(grep -a . "$X/s2x.log" 2> /dev/null | tail -1 | cut -c1-200); [ -n "$sw" ] || sw="退出码 ${sxrc}"
  say "🟡 S2Arm 抽取没跑成（${sw}；$X/s2x.log），只用直连抽取的结果"; tail -3 "$X/s2x.log"
  mkdir -p "$X/s2x/src" && printf '# 键\t阶段\t来源\t变体号\n' > "$X/s2x/rows.tsv" && printf '# 键\t阶段\t首个来源\t变体号\n' > "$X/s2x/index.tsv" || exit 1
  printf 'extract\ts2x_failed\t1\t\tS2Arm 抽取没跑成（%s），只用直连抽取的结果\n' "$sw" > "$X/s2x/degrade.tsv"
fi
tx=$((SECONDS - sx))
# 两边合起来 0 支（直连库并集为空，direct_lib.sh 出到最后换库核验「一个键都没出」）：本款这次出不了直连库，按内容缺口退 3、红行写清缺口类别，通用包照出（同上面直连抽取失败）
nsp=$(grep -cv -e '^#' -e '^package	' "$X/split/shader_map.tsv" 2> /dev/null); nsx=$(grep -cv '^#' "$X/s2x/rows.tsv" 2> /dev/null)
if [ "${nsp:-0}" = 0 ] && [ "${nsx:-0}" = 0 ]; then
  w=$(grep -a '^\[RED\]' "$X/split.log" | tail -1 | sed 's/^\[RED\] *//' | cut -c1-200); [ -n "$w" ] || w='游戏文件里没有认得出的着色器容器'
  say "🔴 直连库失败：直连抽取 0 支着色器（缺口：${w}；$X/split.log）"; exit 3
fi
prog_tick 抽取 4 4
printf 'ue\t%s\nglslc\t%s\nsplit\t%s\ns2a_extract\t%s\njobs\t%s\n' "$tu" "$tg" "$ts" "$tx" "$JT" > "$X/ok"
say "🟢 ${JT} 路（S2Arm ${JX} + 其余 ${JR}）：Unreal 存档 ${tu} 秒、GLSLC 离线编 ${tg} 秒、直连抽取 ${ts} 秒、S2Arm ${tx} 秒；追加内容 ${#AOCS[@]} 份"
