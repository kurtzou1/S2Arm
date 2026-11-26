#!/bin/bash
# 对照局模板（docs/对照局模板.md）：同一份即时存档起点 + 固定输入 + 按进度结束。性能 / 内存 / 游戏速度的前后对照都走这里，不用 AI 自动玩家。
#   bash tools/ab_fixed.sh snap  <款> <快照目录> [局目录]
#        进局（自动玩家只用这一次）到 MARK，原地存一份即时存档当起点（S2A_AP_ROUTE_SNAP）。之后所有对照局都从它恢复
#   bash tools/ab_fixed.sh move  <款> <旧快照目录> <手柄录像.tsv@起始帧> <新快照目录> [局目录]
#        挪起点：从旧起点恢复、放完手柄录像、原地存新起点；同一段输入走两次（第二次存到 <新快照目录>.check），两次新起点画面一致
#        （tools/ab_fixed_snapcmp.py）才算输入确定、新起点能用；不一致退 1。旧起点不合适时用（社区存档只有一份、落在水面上之类）
#   bash tools/ab_fixed.sh speed <款> <快照目录> [局目录]
#        同起点两局（都按存快照时的 60 帧开恢复，原帧率局录前局内切回原帧率），各推住左摇杆向前、按真实时间存路线缩略图；判据 tools/route_speed.py（两局走到同一处的现实时刻比）
#   bash tools/ab_fixed.sh perf  <款> <快照目录> <手柄录像.tsv@起始帧> '<A 组环境>' '<B 组环境>' [轮数 2] [局目录]
#        同起点、同一段手柄回放（按上屏帧数对齐），A B B A（每轮两局，前后交替抵消发热）；判据 tools/ab_fixed_perf.py（只取回放段的帧）
# 环境照 entry_check（维护方工具，S2A_PRIVATE_TOOLS 必给）：S2A_ROOTS 指产物根；存档用缺省（已有进度的社区存档），别给空的 S2A_SAVES（新开局开场动画长，自动玩家常过不去）。
#   局时 S2A_LOOP_SEC 只是兜底（缺省 1800 秒）：对照局喂完固定输入就收局，不按墙钟截。
# 退出码：0 判完；1 判据红（speed）；2 判不出 / 不判；3 有一局没跑成（没到 MARK 或回放没放成），不拿半截局出结论。
set -u
MODE=${1:?snap / move / speed / perf}; G=${2:?款}; SNAP=${3:?快照目录}; shift 3
R=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
: "${S2A_PRIVATE_TOOLS:?要设 S2A_PRIVATE_TOOLS（entry_check 所在目录）}"
LOOP=${S2A_LOOP_SEC:-1800}
run() {   # run <局目录> <环境…>：起一局，没到 MARK / 回放没放成退 3
    local d=$1; shift; mkdir -p "$(dirname "$d")"
    env "$@" S2A_LOOP_SEC="$LOOP" S2A_AP_LOOP_S="$LOOP" S2A_LOOP_CAP=$((LOOP + 335)) bash "$S2A_PRIVATE_TOOLS/entry_check.sh" "$G" handheld "$d" > "$d.entry.out" 2>&1
    local rc=$?
    if [ $rc != 0 ] || ! LC_ALL=C grep -aq "S2A 标记 MARK" "$d/host.log" 2>/dev/null || LC_ALL=C grep -aq "回放没放成" "$d/host.log" 2>/dev/null; then
        echo "🔴 $d 没跑成（entry_check 退出 ${rc}；见 $d.entry.out），不判"; exit 3; fi
}
case $MODE in
  snap)
    D=${1:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/ab_fixed/${G}_snap_$(date +%m%d%H%M)}
    mkdir -p "$(dirname "$SNAP")"   # 即时存档只建快照目录本身（<快照>.new 再换上），上级目录不在就存不成（errno 2）
    LOOP=${S2A_LOOP_SEC:-420}; run "$D" S2A_FPS60=1 S2A_AP_SPEED=route S2A_AP_ROUTE_SNAP="$SNAP"   # 开着 60 帧存（见 speed）
    LC_ALL=C grep -a "固定路线起点快照" "$D/host.log" | tail -1
    LC_ALL=C grep -aq "固定路线起点快照：存好" "$D/host.log" || { echo "🔴 起点快照没存好（见 $D/host.log）"; exit 3; }
    echo "起点快照：${SNAP}（MARK 截图 $D/ap_mark.png，核是不是要比的场景）";;
  move)
    PAD=${1:?手柄录像.tsv@起始帧}; NEW=${2:?新快照目录}
    D=${3:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/ab_fixed/${G}_move_$(date +%m%d%H%M)}
    mkdir -p "$(dirname "$NEW")"
    for k in 1 2; do T=$NEW; [ $k = 2 ] && T=$NEW.check
        run "$D/move$k" S2A_FPS60=1 S2A_SNAP_RESTORE="$SNAP" S2A_SNAP_SAVE_ROLLBACK=1 S2A_AP_PADREC="$PAD" S2A_AP_ROUTE_SNAP="$T"
        LC_ALL=C grep -aq "固定路线起点快照：存好" "$D/move$k/host.log" || { echo "🔴 第 $k 次没存出新起点（见 $D/move$k/host.log）"; exit 3; }
    done
    "$PY" "$R/tools/ab_fixed_snapcmp.py" "$NEW" "$NEW.check"; rc=$?
    [ $rc = 0 ] && echo "新起点：${NEW}（核对用的第二份 ${NEW}.check 可删）"
    exit $rc;;
  speed)
    D=${1:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/ab_fixed/${G}_speed_$(date +%m%d%H%M)}
    # 两局都按存快照时的设置（60 帧开）恢复；原帧率局录之前在局内切回原帧率（S2A_AP_ROUTE_HOLD=1，与玩家在设置页关 60 帧同一条路径），等 5 秒再录。
    #   不用「关着存、开着恢复」：游戏开局时按补丁算好的帧率 / 交换间隔在快照内存里，开着恢复只改了补丁槽，游戏不会再算一遍
    #   （11-26 实测一款：关存开恢复 300 秒仍 30 帧；冷起开 60 帧是 59.9）
    run "$D/fps0" S2A_SNAP_RESTORE="$SNAP" S2A_SNAP_SAVE_ROLLBACK=1 S2A_AP_SPEED=route S2A_AP_ROUTE_OUT="$D/fps0.route" S2A_FPS60=1 S2A_AP_ROUTE_HOLD=1
    run "$D/fps1" S2A_SNAP_RESTORE="$SNAP" S2A_SNAP_SAVE_ROLLBACK=1 S2A_AP_SPEED=route S2A_AP_ROUTE_OUT="$D/fps1.route" S2A_FPS60=1 S2A_AP_ROUTE_WAIT60="${S2A_AP_ROUTE_WAIT60:-300}"
    for f in 0 1; do LC_ALL=C grep -a "固定路线录像：\|the game sets present interval" "$D/fps$f/host.log" | sed "s/^/[fps$f] /"; done
    f0=$(LC_ALL=C grep -a -o "录像期间出图 [0-9.]*" "$D/fps0/host.log" | tail -1 | awk '{print $2}'); f1=$(LC_ALL=C grep -a -o "录像期间出图 [0-9.]*" "$D/fps1/host.log" | tail -1 | awk '{print $2}')
    q=$("$PY" -c "print(round($f1/$f0,3))" 2>/dev/null) || { echo "🔴 录像期间出图帧率读不到"; exit 2; }
    "$PY" "$R/tools/route_speed.py" "$D/fps0.route" "$D/fps1.route" --q "$q"; rc=$?
    exit $rc;;
  perf)
    PAD=${1:?手柄录像.tsv@起始帧}; A=${2:?A 组环境}; B=${3:?B 组环境}; N=${4:-2}
    D=${5:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/ab_fixed/${G}_perf_$(date +%m%d%H%M)}
    AS=(); BS=()
    for ((i = 1; i <= N; i++)); do
        for arm in $( ((i % 2)) && echo "a b" || echo "b a"); do   # 第 1 轮 A B、第 2 轮 B A……：发热敏感的读数前后交替
            if [ $arm = a ]; then E=$A; else E=$B; fi
            # shellcheck disable=SC2086
            run "$D/$arm$i" S2A_SNAP_RESTORE="$SNAP" S2A_SNAP_SAVE_ROLLBACK=1 S2A_AP_PADREC="$PAD" $E
            if [ $arm = a ]; then AS+=("$D/a$i"); else BS+=("$D/b$i"); fi
        done
    done
    "$PY" "$R/tools/ab_fixed_perf.py" --a "${AS[@]}" --b "${BS[@]}"; exit $?;;
  *) echo "🔴 模式只认 snap / move / speed / perf"; exit 2;;
esac
