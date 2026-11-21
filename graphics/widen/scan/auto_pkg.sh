#!/bin/bash
# 宽屏表随同一次出包出（画幅线 / 画面·着色器线，10-25 维护者「一次出包就是完整包、不让玩家回来重出」）：graphics/widen/scan/auto_pkg.sh <子命令> …
#   start <款> <档位>         现行产物根这一构建号、这一档位既没仓库表也没自动表结论 → 后台起 auto_table.sh（pack/refresh.sh 改写段一过就调，与着色器 / 直连库并行）
#   wait  <款> <档位> [秒]    等这一档位的自动出表收尾（锁目录没了）；上限缺省 S2A_WIDEN_WAIT_S=300（10-25 维护者：动森 3.0.3 出包干等 713 秒、最后 0 张表，占整包三分之一；出表与着色器 / 直连库同时起跑，等的只是收尾后剩下的部分；原先 5400 = auto_table 一档最多 1 探测 + 8 组闭环）。
#                             到点还在跑 → 打【黄】退出 0，本包这一档位没有表（16:9 居中留黑边，不拉伸），后台照跑、下一个包带上。
#                             出包（pack/ipa.sh）传 0 = 不等，只看此刻收尾了没有（10-25 维护者：宽屏出表不卡出包关键路径）
#   list  <款> <构建号>       打印选中的表文件（每行一个路径）：仓库 graphics/widen/tables/<款>_<构建号>/（人工验过，优先）> 自动表 ${S2A_WIDEN_AUTO}/<款>_<构建号>/
#                             自动表只在这一档位最近一条结论（<档位>.status 里第一条态为过 / 不过的行）是「过」时选：未判不是结论、不推翻上一条；
#                             新结论不过 = 旧的通过表失效（10-29 mhrise 主机档：结论不过，10-26 留下的旧通过表照样进了包）；没有 status = 没验过，不选
#   copy  <款> <目标目录>     按目标目录 exefs/main 的构建号把 list 选中的表拷进去（出包工作根；运行时在模块目录按档位读，见 runtime/src/widen.c）
# 选表规则只在一处：pack/pkg_srcs.py widen_list（list 子命令调它；pack/stage_rewrite.sh 也用 list）
set -u
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../.." && pwd)
source "$R/pack/roots.sh"   # root_cur_in：现行指针文件（S2A_ROOTS 缺省同上面各处的共享产物根）
AUTO=${S2A_WIDEN_AUTO:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/widen/auto}; TB=${S2A_WIDEN_DIR:-$R/graphics/widen/tables}
bid_of() { xxd -s 0x40 -l 16 -p "$1/exefs/main" 2> /dev/null; }
auto_ok() { [ "$(LC_ALL=C awk -F'\t' '$1 == "过" || $1 == "不过" { print $1; exit }' "$1/$2.status" 2> /dev/null)" = 过 ]; }   # auto_ok <自动表目录> <档位>
cur_bid() { local c; c=$(root_cur_in "$S2A_ROOTS" "$1" 2> /dev/null) && bid_of "$c"; }
cmd=${1:?子命令 start / wait / list / copy / wanted}; G=${2:?款}
# 这个包满屏会不会开（维护者 11-02 19:0x 满屏发布缺省关）：--all-caps（ipa.sh 导出 S2A_ALL_CAPS=1）或本款补丁（S2A_PATCH_DIR 给的补丁目录 <程序号>/patch.tsv；没给就不看补丁）
#   [caps] widen 1 / 有 [widen.enable.*] 段才要满屏自动学习；发布口径没补丁的款满屏关，起闭环只占 Mac 局槽（11-02 19:4x 维护者：3 个局槽被这类闭环占着）
wanted() {
  [ "${S2A_ALL_CAPS:-0}" = 1 ] && return 0
  local pid; pid=$(printf '%s' "$1" | sed -n 's/^t\([0-9a-fA-F]\{16\}\)$/\1/p' | tr a-f A-F); [ -n "$pid" ] || return 1
  [ -n "${S2A_PATCH_DIR:-}" ] || return 1   # 补丁目录由环境给（出包机按自己的布局设；仓库不写本机路径）
  local f=$S2A_PATCH_DIR/$pid/patch.tsv; [ -f "$f" ] || return 1
  awk -F'\t' '/^\[/{sec=$0} sec=="[caps]" && $1=="widen" && $2=="1"{w=1} sec ~ /^\[widen\.enable\./{w=1} END{exit !w}' "$f"
}
case $cmd in
  wanted) wanted "$G";;
  list)
    S2A_WIDEN_DIR=$TB S2A_WIDEN_AUTO=$AUTO "${S2A_PY:-python3}" "$R/pack/pkg_srcs.py" widen-list "$G" "${3:?构建号}";;   # 选表规则的实现在 pack/pkg_srcs.py widen_list（出包包键与 Windows 编排共用）
  start)
    M=${3:?档位}; [ "${S2A_WIDEN_AUTO_RUN:-1}" = 0 ] && exit 0
    wanted "$G" || { echo "宽屏自动出表：$G 本包满屏关（发布口径、没有补丁开满屏），不起闭环"; exit 0; }
    B=$(cur_bid "$G") || { echo "宽屏自动出表：$G 没有现行产物根，不起"; exit 0; }
    for d in "$TB/${G}_$B" "$TB"/*_"$B"; do [ -f "$d/widen_enable.$M.tsv" ] && exit 0; done   # 仓库有人工验过的表（同 pack/pkg_srcs.py repo_table_dir：包名对不上时按构建号认）
    mkdir -p "$AUTO" || exit 0
    # 自立会话（perl setsid，macOS 没有 setsid 命令）：有意活得比本次出包久；启动器任务结束按会话收残留进程（pack/jobs/core.py reap_session），不收它
    (trap '' HUP; exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- env S2A_LOOP_MODE="$M" bash "$H/auto_table.sh" "$G") >> "$AUTO/$G.kick.log" 2>&1 < /dev/null &   # 不用 nohup：Spare-host 无登录会话时 nohup 不跑（10-25，见 docs/坑记录.md）
    mkdir -p "$AUTO/${G}_$B" && echo $! > "$AUTO/${G}_$B/.kick.$M"   # 后台进程号（子 shell 一路 exec 到 auto_table.sh，同一个号）：wait 等它退出，不赌它几秒内拿到锁
    echo "宽屏自动出表：${G}（${M}）已起，出包收尾前等它（auto_pkg.sh wait）";;
  wait)
    M=${3:?档位}; CAP=${4:-${S2A_WIDEN_WAIT_S:-300}}; [ "${S2A_WIDEN_AUTO_RUN:-1}" = 0 ] && exit 0
    wanted "$G" || exit 0
    B=$(cur_bid "$G") || exit 0; O=$AUTO/${G}_$B; t0=$SECONDS
    [ -f "$TB/${G}_$B/widen_enable.$M.tsv" ] && { echo "宽屏：${G}（${M}）用仓库表"; exit 0; }
    # 收尾 = start 起的后台进程已退出、且锁不在。按事件等，不赌秒数：原先先睡 2 秒再看锁，满载时后台 2 秒内还没走到拿锁，
    #   wait 当成已收尾、报「没出表」（11-01 main c4bdbe045、10-31 22:10 widen_auto_pkg_test ① 红：等了 2–3 秒）；后台也可能不拿锁就退（已有结论），进程退出两种都覆盖
    P=$(cat "$O/.kick.$M" 2> /dev/null)
    running() { [ -d "$O/.lock.$M" ] || { [ -n "$P" ] && kill -0 "$P" 2> /dev/null; }; }
    while running; do
      [ $((SECONDS - t0)) -ge "$CAP" ] && { echo "【黄】宽屏：${G}（${M}）自动出表$([ "$CAP" -gt 0 ] && echo " ${CAP} 秒")还没收尾，本包这一档位不带表（16:9 留黑边），后台照跑、下一个包带上（$O/$M.log）"; exit 0; }
      sleep 1
    done
    echo "宽屏：${G}（${M}）自动出表 $([ -f "$O/widen_enable.$M.tsv" ] && auto_ok "$O" "$M" && echo 有表 || echo 没出表)，等了 $((SECONDS - t0)) 秒；$(head -1 "$O/$M.status" 2> /dev/null | cut -f1,3 | tr '\t' ' ' | cut -c1-160)";;
  copy)
    D=${3:?目标目录}; B=$(bid_of "$D") || { echo "【红】宽屏表：$D 没有 exefs/main"; exit 1; }
    n=0; while read -r f; do [ -n "$f" ] || continue; cp "$f" "$D/$(basename "$f")" || exit 1; n=$((n + 1)); done < <(bash "$0" list "$G" "$B")
    echo "宽屏表进包：$n 张（$(bash "$0" list "$G" "$B" | xargs -n1 basename 2> /dev/null | tr '\n' ' ')）";;
  *) echo "认不得子命令 $cmd" >&2; exit 2;;
esac
