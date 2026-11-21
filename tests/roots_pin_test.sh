#!/bin/bash
# 产物根「钉住」检查（约 2 秒）：被进程钉住的旧根，root_commit 的修剪不删（11-02 体验线 Tools Up! 一键出包刷新时播种根被并行阶段的连续 commit 剪掉）
# 期望值手算：同款 4 个根 v1 最旧 < v2 < v3 < v4（现行）；修剪只留现行 v4 + 上一版 v3，v1 / v2 该删。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"; [ -z "${SP:-}" ] || kill "$SP" 2> /dev/null' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$2」真结果「$3」"; bad=1; fi; }
mk() { export S2A_ROOTS=$T/roots; rm -rf "$S2A_ROOTS"; mkdir -p "$S2A_ROOTS"; for i in 1 2 3 4; do mkdir "$S2A_ROOTS/g@v$i"; touch -t 20260101000$i "$S2A_ROOTS/g@v$i"; done; printf '%s\n' g@v4 > "$S2A_ROOTS/g@现行"; }
ls_roots() { ls "$S2A_ROOTS" | grep -v '^\.' | grep -v 现行 | tr '\n' ' '; }
. "$H/pack/roots.sh"
mk; _root_prune g g@v4; ck "① 没人钉：只剩上一版 v3 + 现行 v4" "g@v3 g@v4 " "$(ls_roots)"
mk; ( sleep 60 ) & SP=$!; _root_pin_as() { printf '%s %s\n' "$SP" "$(_root_lstart $SP)" > "$S2A_ROOTS/.pin.$1.$SP"; }; _root_pin_as g@v1
_root_prune g g@v4; ck "② v1 被活进程钉住：v1 留、v2 删、v3 v4 留" "g@v1 g@v3 g@v4 " "$(ls_roots)"
kill $SP; wait $SP 2> /dev/null; SP=; mk; echo "999999 Mon Jan  1 00:00:00 2001" > "$S2A_ROOTS/.pin.g@v1.999999"
_root_prune g g@v4; ck "③ 钉的进程已死：v1 照删，死钉自己清掉" "g@v3 g@v4  0" "$(ls_roots) $(ls -a "$S2A_ROOTS" | grep -c '^\.pin\.')"
mk; ( _root_pin "$S2A_ROOTS/g@v2" ); ck "④ root_cur 取现行时钉住：取到 v4 → .pin.g@v4.<pid> 存在" "1" "$( ( root_cur g > /dev/null; ls -a "$S2A_ROOTS" | grep -c '^\.pin\.g@v4\.' ) )"
[ $bad = 0 ] && echo "roots_pin 单测全过" || { echo "roots_pin 单测有不通"; exit 1; }
