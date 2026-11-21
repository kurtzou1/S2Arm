#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/roots.sh
# root_gc 单测（#338：取现行时顺手修剪 + 残余回收，约 3 秒）：bash tests/roots_gc_test.sh
# 期望值手算：同款 4 个根 v1 最旧 < v2 < v3 < v4（现行），只留现行 v4 + 上一版 v3；活钉不删、死钉清掉；
#   提交锁被占时整次跳过；.trash 按名字里的 pid 判死；.tmp / .tmp.rb 只按 .root_pid 记录判死，没有记录的一律不碰。
#   ⑨–⑪：出包收尾的强制回收（pack/refresh.sh 的 tail_gc / S2A_ROOT_GC_FORCE，11-17 补 #338 的收尾缺口）——
#     最后一笔提交时并行段进程还活着钉着的版本剪不动，段进程退出后收尾强制收成现行 + 上一版。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"; [ -z "${SP:-}" ] || kill "$SP" 2> /dev/null' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$2」真结果「$3」"; bad=1; fi; }
mk() { export S2A_ROOTS=$T/roots; rm -rf "$S2A_ROOTS"; mkdir -p "$S2A_ROOTS"; for i in 1 2 3 4; do mkdir "$S2A_ROOTS/g@v$i"; touch -t 20260101000$i "$S2A_ROOTS/g@v$i"; done; printf '%s\n' g@v4 > "$S2A_ROOTS/g@现行"; }
mk2() { export S2A_ROOTS=$T/roots; rm -rf "$S2A_ROOTS"; mkdir -p "$S2A_ROOTS/g@v3" "$S2A_ROOTS/g@v4"; printf '%s\n' g@v4 > "$S2A_ROOTS/g@现行"; }
ls_roots() { ls "$S2A_ROOTS" | grep -v '^\.' | grep -v 现行 | tr '\n' ' '; }
. "$H/pack/roots.sh"
mk; echo "999999 Mon Jan  1 00:00:00 2001" > "$S2A_ROOTS/.pin.g@v1.999999"
R=$(root_cur g); ck "① 取现行后只留 v3+v4（死钉 v1 与无钉 v2 被收）" "g@v3 g@v4 " "$(ls_roots)"
ck "①b 取现行仍返回现行实际路径（stdout 不被回收输出污染）" "g@v4" "$(basename "$R")"
ck "①c 死钉自己清掉" "0" "$(ls -a "$S2A_ROOTS" | grep -c '^\.pin\.g@v1\.')"
mk; ( sleep 60 ) & SP=$!; printf '%s %s\n' "$SP" "$(_root_lstart $SP)" > "$S2A_ROOTS/.pin.g@v1.$SP"
root_cur g > /dev/null; ck "② v1 被活进程钉住：v1 v3 v4 留、v2 收" "g@v1 g@v3 g@v4 " "$(ls_roots)"
kill $SP; wait $SP 2> /dev/null; SP=
mk; source "$H/tools/plock.sh"; plock_take "$S2A_ROOTS/.g.commit.lock" 0 > /dev/null; LH=$PLOCK_PID
root_cur g > /dev/null; ck "③ 提交锁被占：整次跳过不修剪" "g@v1 g@v2 g@v3 g@v4 " "$(ls_roots)"
plock_release "$LH"
mk2; LIVE="g@_v9.$$.$RANDOM"; mkdir -p "$S2A_ROOTS/.trash/g@_v0.999999.123" "$S2A_ROOTS/.trash/$LIVE"
root_gc g; ck "④ .trash：名字里 pid 已死的残余清掉、活 pid 的留着" "$LIVE " "$(ls "$S2A_ROOTS/.trash" | tr '\n' ' ')"
mk2; mkdir -p "$S2A_ROOTS/g@_dead.tmp" "$S2A_ROOTS/g@_live.tmp" "$S2A_ROOTS/g@_old.tmp" "$S2A_ROOTS/g@_fresh.tmp.rb" "$S2A_ROOTS/g@_deadreplay.tmp.rb"
echo "999999 Mon Jan  1 00:00:00 2001" > "$S2A_ROOTS/g@_dead.tmp/.root_pid"
_root_owner > "$S2A_ROOTS/g@_live.tmp/.root_pid"; touch -t 202601010000 "$S2A_ROOTS/g@_old.tmp"
_root_owner > "$S2A_ROOTS/g@_fresh.tmp.rb/.root_pid"
echo "999999 Mon Jan  1 00:00:00 2001" > "$S2A_ROOTS/g@_deadreplay.tmp.rb/.root_pid"
root_gc g; ck "⑤ .tmp/.tmp.rb 只收有记录且持有者已死的；无记录（含旧目录）与活持有者一律不碰" "g@_fresh.tmp.rb g@_live.tmp g@_old.tmp " "$(ls "$S2A_ROOTS" | grep -e '\.tmp' | tr '\n' ' ')"
mk2; mkdir -p "$S2A_ROOTS/.romfs_store/g/orphan" "$S2A_ROOTS/.romfs_store/g/used"; ln -s ../.romfs_store/g/used "$S2A_ROOTS/g@v4/romfs"
root_gc g; ck "⑥ RomFS 存储：无主身份清掉、现行指向的留着" "used " "$(ls "$S2A_ROOTS/.romfs_store/g" | tr '\n' ' ')"
mk; R=$(S2A_ROOT_CUR=$S2A_ROOTS/g@v2 root_cur g); ck "⑦ 只算键（S2A_ROOT_CUR）：返回指定根、不触发回收" "g@v2 g@v1 g@v2 g@v3 g@v4 " "$(basename "$R") $(ls_roots)"
mk; ( sleep 60 ) & SP=$!; printf '%s %s\n' "$SP" "$(_root_lstart $SP)" > "$S2A_ROOTS/.pin.g@v1.$SP"
root_gc g; ck "⑧ 负对照：活钉的 v1 直接过 root_gc 也不删；无钉的 v2 照删" "g@v1 g@v3 g@v4 " "$(ls_roots)"
kill $SP; wait $SP 2> /dev/null; SP=
mk; touch "$S2A_ROOTS/.gc.g.stamp"   # 节流戳刚写（10 分钟内）：出包收尾前开工的取现行就是这个形态
root_gc g; ck "⑨ 节流：10 分钟内收过、不强制 → 整次跳过" "g@v1 g@v2 g@v3 g@v4 " "$(ls_roots)"
S2A_ROOT_GC_FORCE=1 root_gc g; ck "⑩ 出包收尾的强制回收（S2A_ROOT_GC_FORCE=1，refresh.sh tail_gc）：越过节流当场修剪" "g@v3 g@v4 " "$(ls_roots)"
mk; ( sleep 60 ) & SP=$!; printf '%s %s\n' "$SP" "$(_root_lstart $SP)" > "$S2A_ROOTS/.pin.g@v2.$SP"   # 并行段：最后一笔提交时 v2 被活进程钉着
root_begin g v5 > /dev/null && root_commit g v5; ck "⑪a 最后一笔提交：活钉的 v2 剪不动、漏给出包收尾" "g@v2 g@v4 g@v5 " "$(ls_roots)"
kill $SP; wait $SP 2> /dev/null; SP=
S2A_ROOT_GC_FORCE=1 root_gc g; ck "⑪b 出包收尾强制回收：段进程已退出（钉失效），收成现行 + 上一版" "g@v4 g@v5 " "$(ls_roots)"
[ $bad = 0 ] && echo "roots_gc 单测全过" || { echo "roots_gc 单测有不通"; exit 1; }