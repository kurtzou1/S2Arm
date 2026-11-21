#!/bin/bash
# RomFS 存储清扫与并行提交的交错（审计 #1508 P1-108，pack/roots.sh root_commit / root_romfs_sweep）单测：临时目录，秒级。bash tests/roots_romfs_sweep_race_test.sh
# 交错按事件制造、不赌墙钟：清扫刚读完现行的 romfs 链接（名单已拍下、还没删）时放行界面布局阶段 B（声明 romfs）去提交，
#   再等 B 发出两个事件之一：「已把新身份收进存储」或「拿提交锁被挡」，清扫才往下走。
# 期望按规则手写（不复述实现）：
#   一、提交里的清扫（改写阶段 A 的 root_commit）：清扫与收纳同一把提交锁串行 → B 一定被锁挡；B 提交后现行 romfs 指向的新身份还在、内容是 B 写的
#   二、单独调的清扫（不在提交里，如维护方清扫器调 root_romfs_sweep）：清扫自己拿提交锁 → B 一定被锁挡；新身份还在、现行 romfs 可读。
#      空当钉死：清扫读到 B 的 g@ui1.tmp/romfs 链接那一刻暂停，等 B 把 .tmp 改名成正式名（最多 3 秒）再读——原先不拿锁、只靠「删前再读一次链接」，
#      这一刻 .tmp 已不在、正式名又不在已列出的版本里，刚收纳的新身份被当成无主删掉（满载下偶发红的真因）；旧码在这里必红（负对照）
#   两种都要：没有任何版本指向的旧身份照样删（不放宽「没人指向就删」）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/tools/plock.sh"
waitev() { local i e; for i in $(seq 1 600); do for e in "$@"; do [ -e "$EV/$e" ] && return 0; done; sleep 0.05; done; echo "【红】等事件 $* 超时" >&2; return 1; }
# 清扫读完名单里最后一条 romfs 链接（g@s0：版本按名字排 g@rw1 < g@s0 < g@ui1.tmp，现行指针 g@现行 是文件、没有 romfs）时放行 B，
#   等 B 收纳完或被锁挡住再往下（布防后只触发一次）
readlink() {
  command readlink "$@"; local rc=$?
  if [[ " ${FUNCNAME[*]} " == *" root_romfs_sweep "* ]] && [[ "$*" == *@s0/romfs ]] && [ -e $EV/armed ] && mkdir $EV/fired 2> /dev/null; then touch $EV/go; waitev interned blocked >&2; fi
  return $rc
}
# 清扫要读 B 的 g@ui1.tmp/romfs 时（交错已放行之后）先等 B 把 .tmp 改名成正式名，最多 3 秒——把「再读链接时版本正被改名」这一刻钉死。
#   要在 source pack/roots.sh 之后定义（它会重定义 _root_romfs_used）；B 那边切现行前等清扫做完（见 run 里 B 的 _root_ptr_py write），
#   否则 B 刚改完名就切现行，空当又靠墙钟
hook_used() {
  _root_romfs_used() {
    # 交错放行之后的第几次读链接：候选按名字排是 orphan、s0-…（在先拍的名单里，不再读）、ui1-…，第 1 次再读是 orphan 的、第 2 次就是 B 新身份的
    local v n=0; [ -e $EV/fired ] && { n=$(( $(cat $EV/calls 2> /dev/null || echo 0) + 1 )); echo $n > $EV/calls; }
    for v in "$S2A_ROOTS/$1"@*; do   # 版本列表在这里拍下（此刻还是 g@ui1.tmp）
      # 为 B 的新身份再读、读到 B 的 .tmp 时：放行 B 改名，等它改完再读
      if [[ $v == *@ui1.tmp ]] && [ $n = 2 ] && mkdir $EV/window 2> /dev/null; then
        touch $EV/reread; local i; for i in $(seq 1 60); do [ -e $EV/renamed ] && break; sleep 0.05; done; fi
      [ -L "$v/romfs" ] && readlink "$v/romfs"; done; :
  }
}
waitev_short() { local i; for i in $(seq 1 60); do [ -e "$EV/$1" ] && return 0; sleep 0.05; done; return 1; }   # 最多 3 秒（新码没有再读，不会来）
# run <名> <commit|gc>：播种 → A、B 同一现行开工 → B 等放行 → 清扫（A 提交里的，或 gc 式单独调）中途放行 B
run() {
  local n=$1 how=$2 A B W BP c d v
  export S2A_ROOTS=$T/$n/roots S2A_ROOTS_SHARED=$T/shared S2A_ROOTS_PRIV=$T/priv; EV=$T/$n/ev; mkdir -p $EV; source "$H/pack/roots.sh"; hook_used
  W=$(root_begin g s0) && mkdir -p $W/romfs/Layout && echo lyt > $W/romfs/Layout/x.bflyt && root_commit g s0
  A=$(root_begin g rw1); echo rw > $A/rw.txt
  B=$(ROOT_OWN_ROMFS=1 root_begin g ui1); rm -f $B/romfs/Layout/x.bflyt && echo wide > $B/romfs/Layout/x.bflyt
  (
    eval "_real_plock_take() $(declare -f plock_take | tail -n +2)"
    plock_take() { _real_plock_take "$1" 0 && return 0; touch $EV/blocked; _real_plock_take "$@"; }
    eval "_real_intern() $(declare -f _root_romfs_intern | tail -n +2)"
    _root_romfs_intern() { _real_intern "$@" || return 1; touch $EV/interned; }
    eval "_real_ptr_py() $(declare -f _root_ptr_py | tail -n +2)"
    _root_ptr_py() { [ "$1" != write ] || waitev sweptdone; _real_ptr_py "$@"; }
    mv() { if [[ "${1:-}" == *@ui1.tmp && "${2:-}" == *@ui1 ]]; then waitev_short reread; command mv "$@"; local rc=$?; touch $EV/renamed; return $rc; fi; command mv "$@"; }   # 只卡 .tmp → 正式名这一下（重放也会挪 .tmp）
    waitev go && ROOT_REPLAY='romfs' root_commit g ui1 2> $T/$n/b.err; echo $? > $EV/b.rc
  ) & BP=$!
  if [ $how = commit ]; then touch $EV/armed; ROOT_REPLAY='rw.txt' root_commit g rw1 2> $T/$n/a.err; ARC=$?
  else ROOT_REPLAY='rw.txt' root_commit g rw1 2> $T/$n/a.err; ARC=$?; mkdir -p $T/$n/roots/.romfs_store/g/orphan; touch $EV/armed; root_romfs_sweep g 2> /dev/null; fi
  touch $EV/sweptdone
  wait $BP; BRC=$(cat $EV/b.rc 2> /dev/null)
  C=$(root_cur g); L=$(command readlink $C/romfs 2> /dev/null); D=$S2A_ROOTS/.romfs_store/g/${L##*/}
  EVS=$( [ -e $EV/blocked ] && echo B被锁挡 || { [ -e $EV/interned ] && echo B在清扫中收纳; } )
  OK=0; [ "$(basename $C)" = g@ui1 ] && [ -d "$D" ] && [ "$(cat $C/romfs/Layout/x.bflyt 2> /dev/null)" = wide ] && OK=1
  for c in s2 s3; do W=$(root_begin g $c) && root_commit g $c 2> /dev/null; done
  ORPH=0; for d in $S2A_ROOTS/.romfs_store/g/*; do grep -qxF "../.romfs_store/g/${d##*/}" <<< "$(for v in $S2A_ROOTS/g@*; do [ -L $v/romfs ] && command readlink $v/romfs; done)" || ORPH=$((ORPH + 1)); done
  RD=$(cat $(root_cur g)/romfs/Layout/x.bflyt 2> /dev/null)
}
# 一、提交里的清扫（A 先拿锁提交，清扫中途 B 来提交）
run c1 commit
ck "提交里的清扫：交错已制造（${EVS:-没触发}）、两笔都成功（A rc=${ARC}，B rc=${BRC:-无}）" '[ -e $EV/fired ] && [ -n "$EVS" ] && [ $ARC = 0 ] && [ "${BRC:-1}" = 0 ]'
ck "提交里的清扫与收纳同一把提交锁串行：B 被锁挡（实际：${EVS:-没触发}）" '[ "$EVS" = B被锁挡 ]'
ck "提交里的清扫：现行 = ui1，romfs 指向的新身份（${L:-无链接}）还在、内容 wide" '[ $OK = 1 ]'
ck "提交里的清扫：之后再提交两笔，无主身份 ${ORPH} 个、现行 romfs 可读（${RD:-读不到}）" '[ $ORPH = 0 ] && [ "$RD" = wide ]'
# 二、单独调的清扫：A 提交完之后单独清扫，存储里另放一个无主身份 orphan；清扫中途放行 B 来提交
run c2 gc
ck "单独调的清扫：交错已制造（${EVS:-没触发}）、清扫自己拿锁 → B 被锁挡、两笔都成功（A rc=${ARC}，B rc=${BRC:-无}）" '[ -e $EV/fired ] && [ "$EVS" = B被锁挡 ] && [ $ARC = 0 ] && [ "${BRC:-1}" = 0 ]'
ck "单独调的清扫：再读链接时版本正被改名（空当已钉住：$([ -e $EV/window ] && echo 是 || echo 否)），新身份（${L:-无链接}）还在、内容 wide" '[ $OK = 1 ]'
ck "单独调的清扫：无主的 orphan 照样删、之后无主身份 ${ORPH} 个、现行 romfs 可读（${RD:-读不到}）" '[ ! -e $T/c2/roots/.romfs_store/g/orphan ] && [ $ORPH = 0 ] && [ "$RD" = wide ]'
chmod -R u+w $T 2> /dev/null; rm -rf $T; [ $bad = 0 ] && echo "RomFS 清扫并行提交单测全过" || { echo "RomFS 清扫并行提交单测有不通"; exit 1; }
