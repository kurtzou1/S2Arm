#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# 门禁覆盖：pack/roots.sh pack/orch/current.py
# bash 侧现行指针文件单测（玩家诊断 #0fd185：现行不再是目录软链，<款>@现行 是普通文件、内容 = 版本目录名；约 15 秒）：bash tests/roots_current_ptr_test.sh
# 期望值全部手写：
#   ① 读写：root_commit 后 <款>@现行 是普通文件、内容「g@c1 + 换行」，root_cur 打印该版本目录；空 / 带路径 / 指向不在的目录 / 指向 .tmp、.tmp.rb /
#      别的款 /「现行」本身 / 多行 → 当没有现行（root_cur_in 返回 1、不打印）；Windows 换行照认；写坏值被拒、原指针不动
#   ② 老库迁移：软链现行 → 第一次 root_cur 改成指针文件（版本目录原样）；实目录模式的真目录（.root_tag 记版本名）→ 改名成版本目录 + 指针
#   ③ 迁移断在中间状态（只写了临时指针 / 旧链接已改名到旁边、新指针没就位 / 新指针已就位、旧链接没删 / 只剩旁边的旧链接；
#      实目录：只写了临时指针 / 目录已改名、指针没就位）：再取现行都是原来那一版、版本一个不少；之后强制回收收掉残留
#   ④ 并发：后台反复真提交（root_begin / root_commit）切现行，同时反复读指针：每次都有现行、读到的版本目录里记的 id 就是它自己的名字
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_ROOTS_SHARED=$T/shared S2A_ROOTS_PRIV=$T/priv
fresh() { export S2A_ROOTS=$T/$1; rm -rf "$S2A_ROOTS"; mkdir -p "$S2A_ROOTS"; }
source "$H/pack/roots.sh"
P() { root_cur_in "$S2A_ROOTS" g; }   # 只解析（含迁移）

# ① 读写
fresh r1; W=$(root_begin g c1) && echo c1 > "$W/id" && root_commit g c1
ck "① 提交后现行是普通文件、内容 g@c1、root_cur 指向它" '[ -f $S2A_ROOTS/g@现行 ] && [ ! -L $S2A_ROOTS/g@现行 ] && [ "$(cat $S2A_ROOTS/g@现行)" = g@c1 ] && [ "$(basename "$(root_cur g)")" = g@c1 ] && [ "$(cat "$(root_cur g)/id")" = c1 ]'
ck "① 没留下临时指针" '[ -z "$(ls -A $S2A_ROOTS | grep "现行.new")" ]'
mkdir -p $S2A_ROOTS/g@w_x.tmp $S2A_ROOTS/g@w_x.tmp.rb $S2A_ROOTS/h@v1 $S2A_ROOTS/sub/g@c1
for raw in '' 'sub/g@c1' '../r1/g@c1' 'g@gone' 'g@w_x.tmp' 'g@w_x.tmp.rb' 'h@v1' 'g@现行' 'g@' 'c1' $'g@c1\ng@c1'; do
  printf '%s\n' "$raw" > $S2A_ROOTS/g@现行
  out=$(P); rc=$?
  ck "① 坏值「${raw//$'\n'/⏎}」→ 没有现行（rc=${rc}、打印「${out}」）" '[ $rc != 0 ] && [ -z "$out" ]'
done
printf 'g@c1\r\n' > $S2A_ROOTS/g@现行
ck "① Windows 换行照认" '[ "$(basename "$(P)")" = g@c1 ]'
printf 'g@c1\n' > $S2A_ROOTS/g@现行
for raw in 'g@gone' 'g@w_x.tmp' 'sub/g@c1' 'h@v1'; do
  _root_ptr_py write "$S2A_ROOTS" g "$raw" 2> /dev/null; rc=$?
  ck "① 写坏值 ${raw} 被拒（rc=${rc}）、原指针不动" '[ $rc != 0 ] && [ "$(cat $S2A_ROOTS/g@现行)" = g@c1 ]'
done

# ② 老库迁移
fresh r2; mkdir -p $S2A_ROOTS/g@v0 $S2A_ROOTS/g@v1; echo v1 > $S2A_ROOTS/g@v1/id; ln -s g@v1 $S2A_ROOTS/g@现行
C=$(root_cur g)
ck "② 软链现行 → 指针文件（内容 g@v1）、root_cur 是 g@v1、版本目录原样" '[ "$(basename "$C")" = g@v1 ] && [ -f $S2A_ROOTS/g@现行 ] && [ ! -L $S2A_ROOTS/g@现行 ] && [ "$(cat $S2A_ROOTS/g@现行)" = g@v1 ] && [ "$(cat $S2A_ROOTS/g@v1/id)" = v1 ] && [ -d $S2A_ROOTS/g@v0 ]'
fresh r3; mkdir -p $S2A_ROOTS/g@现行; echo live > $S2A_ROOTS/g@现行/id; echo g@seed > $S2A_ROOTS/g@现行/.root_tag
C=$(root_cur g)
ck "② 实目录现行 → 版本目录 g@seed + 指针（内容不丢、.root_tag 去掉）" '[ "$(basename "$C")" = g@seed ] && [ "$(cat $S2A_ROOTS/g@seed/id)" = live ] && [ ! -e $S2A_ROOTS/g@seed/.root_tag ] && [ "$(cat $S2A_ROOTS/g@现行)" = g@seed ]'
W=$(root_begin g c2) && echo c2 > "$W/id" && root_commit g c2
ck "② 迁移后照常提交：现行 g@c2、上一版 g@seed 还在" '[ "$(cat $S2A_ROOTS/g@现行)" = g@c2 ] && [ "$(cat $S2A_ROOTS/g@seed/id)" = live ]'

# ③ 断在中间状态（按 current.py normalize 的步骤顺序手搭：先写临时指针 → 旧链接 / 目录改名 → 临时指针改名成 g@现行 → 删旧链接 / .root_tag）
mid() { fresh "$1"; mkdir -p $S2A_ROOTS/g@v0 $S2A_ROOTS/g@v1; echo v1 > $S2A_ROOTS/g@v1/id; }
left() { ls -A $S2A_ROOTS | grep -c -e '现行.new-' -e '现行.migr-'; }
check() {   # check <状态>
  local c; c=$(P)
  ck "③ $1：取现行 = g@v1、v0 v1 都在" '[ "$(basename "$c")" = g@v1 ] && [ "$(cat $S2A_ROOTS/g@v1/id)" = v1 ] && [ -d $S2A_ROOTS/g@v0 ] && [ "$(cat $S2A_ROOTS/g@现行)" = g@v1 ]'
  S2A_ROOT_GC_FORCE=1 root_gc g
  ck "③ $1：强制回收后残留 0（$(left)）、版本还在" '[ "$(left)" = 0 ] && [ -d $S2A_ROOTS/g@v1 ] && [ -d $S2A_ROOTS/g@v0 ]'
}
mid m1; ln -s g@v1 $S2A_ROOTS/g@现行; echo g@v1 > $S2A_ROOTS/.g@现行.new-k1; check "软链：只写了临时指针"
mid m2; ln -s g@v1 $S2A_ROOTS/g@现行.migr-k2; echo g@v1 > $S2A_ROOTS/.g@现行.new-k2; check "软链：旧链接已改名、新指针没就位"
mid m3; ln -s g@v1 $S2A_ROOTS/g@现行.migr-k3; echo g@v1 > $S2A_ROOTS/g@现行; check "软链：新指针已就位、旧链接没删"
mid m4; ln -s g@v1 $S2A_ROOTS/g@现行.migr-k4; check "软链：只剩旁边的旧链接（临时指针也没了）"
fresh m5; mkdir -p $S2A_ROOTS/g@v0 $S2A_ROOTS/g@现行; echo v1 > $S2A_ROOTS/g@现行/id; echo g@v1 > $S2A_ROOTS/g@现行/.root_tag; echo g@v1 > $S2A_ROOTS/.g@现行.new-k5
check "实目录：只写了临时指针"
fresh m6; mkdir -p $S2A_ROOTS/g@v0 $S2A_ROOTS/g@v1; echo v1 > $S2A_ROOTS/g@v1/id; echo g@v1 > $S2A_ROOTS/g@v1/.root_tag; echo g@v1 > $S2A_ROOTS/.g@现行.new-k6
check "实目录：目录已改名、指针没就位"

# ④ 并发：写方后台真提交（不修剪：留存规则与切换无关），读方同时反复读
fresh r4; W=$(root_begin g w0) && echo g@w0 > "$W/id" && root_commit g w0
( _root_prune() { :; }; end=$((SECONDS + 6)); i=0
  while [ $SECONDS -lt $end ]; do i=$((i + 1)); W=$(root_begin g w$i) && echo g@w$i > "$W/id" && root_commit g w$i 2> /dev/null || echo fail >> $T/wfail; done
  echo $i > $T/commits ) &
WP=$!; reads=0; errs=0; seen=
while kill -0 $WP 2> /dev/null; do
  c=$(_root_ptr_read "$S2A_ROOTS" g) || { errs=$((errs + 1)); continue; }
  id=$(< "$c/id"); reads=$((reads + 1))
  [ "$id" = "${c##*/}" ] || errs=$((errs + 1))
  case " $seen " in *" $id "*) ;; *) seen="$seen $id";; esac
done
wait $WP; n=$(wc -w <<< "$seen" | tr -d ' ')
ck "④ 写方提交 $(cat $T/commits) 次（失败 $(cat $T/wfail 2> /dev/null | wc -l | tr -d " ") 次）；读 ${reads} 次、见到 ${n} 个版本、错 ${errs} 次" '[ $errs = 0 ] && [ ! -e $T/wfail ] && [ "$(cat $T/commits)" -gt 5 ] && [ $reads -gt 100 ] && [ $n -gt 3 ]'

[ $bad = 0 ] && echo "现行指针 bash 单测全过" || { echo "现行指针 bash 单测有不通"; exit 1; }
