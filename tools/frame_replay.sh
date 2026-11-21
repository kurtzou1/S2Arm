#!/bin/bash
# 帧回放（graphics/nvn/docs/frame_replay.md）：tools/frame_replay.sh <款> <录像目录> [输出目录]
#   用本树编出的宿主（make host，增量）把录下的一帧喂给直连回放层：不装游戏、不导航。输出 <输出目录>/shots/replay.png、host.log；
#   打印回放每遍的渲染遍数 / 绘制笔数 / 每笔指令数，以及满屏判据红行（没有红行 = 满屏）。
# 产物根同 维护方 entry_check.sh：${S2A_ROOTS:-~/.s2arm/run/s2arm/roots} 里 <款> 的现行版本（S2A_ROOT_TAG=<标签> 时取版本目录 <款>@<标签>；着色器库 / 映射表从这里读，只读不改）。
# 录像含游戏数据：录像目录与输出目录都不许在仓库里。环境：S2A_FRAME_REPLAY_N（遍数，缺省 3）
set -u
G=${1:?款}; REC=$(cd "${2:?录像目录}" 2>/dev/null && pwd) || { echo "🔴 录像目录 $2 不存在"; exit 2; }
R=$(cd "$(dirname "$0")/.." && pwd)
OUT=${3:-$REC/replay_$(date +%m%d_%H%M%S)}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
for p in "$REC" "$OUT"; do case "$p/" in "$R"/*) echo "🔴 $p 在仓库里：录像 / 回放输出含游戏数据，只放仓库外"; exit 2;; esac; done
[ -f "$REC/manifest.tsv" ] || { echo "🔴 $REC 不是帧录像（没有 manifest.tsv）"; exit 2; }
source "$R/pack/roots.sh"
if [ -n "${S2A_ROOT_TAG:-}" ]; then src=$(cd -P "$S2A_ROOTS/$G@$S2A_ROOT_TAG" 2>/dev/null && pwd); else src=$(root_cur_in "$S2A_ROOTS" "$G" 2>/dev/null); fi
[ -n "$src" ] || { echo "🔴 $G 没有产物根（S2A_ROOTS 指到别处的给出来）"; exit 2; }
T0=$SECONDS
bash "$R/tools/host_build.sh" > "$OUT/build.log" 2>&1 || { echo "🔴 宿主编不过（见 $OUT/build.log）"; tail -3 "$OUT/build.log"; exit 1; }
TB=$SECONDS
mkdir -p "$OUT/gal"
env DM_NVN_FIRST_SKIP=0 S2A_FRAME_REPLAY="$REC" S2A_GAME_DATA="$src" S2A_IN="$src" S2A_DOCS="$OUT" NXGAL_SHADER_CACHE_DIR="$OUT/gal" S2A_RYU_DATA="$OUT/ryu" \
  timeout "${S2A_REPLAY_TIMEOUT:-180}" "$R/build/s2arm-host" "$src" > "$OUT/host.log" 2>&1; rc=$?
/usr/bin/grep -a "回放\|出图未满屏\|帧回放" "$OUT/host.log" | sed 's/^\[[^]]*\] //' | cut -c1-260
echo "$( [ $rc = 0 ] && echo 🟢 || echo 🔴 ) 回放 rc=${rc}：编译 $((TB - T0)) 秒、回放 $((SECONDS - TB)) 秒；截图 $OUT/shots/replay.png$( ls "$OUT"/shots/fit_red_*.png > /dev/null 2>&1 && echo "，满屏红帧 $(ls "$OUT"/shots/fit_red_*.png | tr '\n' ' ')" )"
exit $rc
