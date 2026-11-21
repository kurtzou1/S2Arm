#!/bin/bash
# 一个原件里有多个本体（pack/srcs.sh src_ids；假 nx_unpack + 假原件目录，约 3 秒）：bash tests/srcs_multi_base_test.sh
# 背景：11-05 普查 #26 索尼克×夏特 世代重启，一份卡带里有游戏 + 「艺术集&原声集」两个本体程序号；src_ids 不带 --title-id 调
#   nx_unpack --nacp-only，它报「基础程序应恰好 1 个（按程序号），实际 2」退出 1，这份原件被记成「-」，解包报「没有程序号的原始包」。
# 假 nx_unpack 按文件名代表内容：multi.xci = 两个本体 0100AAAA00000000 / 0100BBBB00000000，single.nsp = 一个本体 0100CCCC00000000，
#   upd.nsp = 只有更新（没有本体）；不带 --title-id 而命中本体数 ≠ 1 时与真工具同形报错退出 1；--inspect 输出与真工具同形的 JSON。
# 期望（按规则手写，不跑被测实现推）：
#   ① src_ids 出 4 行：multi.xci → AAAA、multi.xci → BBBB（按程序号排序）、single.nsp → CCCC、upd.nsp → -；退出 0
#   ② 缓存：multi 两行 + single 一行进缓存，upd 不进；再调输出逐字相同、不再调 nx_unpack 认包
#   ③ 单本体照旧：single.nsp 只调一次 --nacp-only、不调 --inspect
#   ④ --inspect 读不出（退出 3）→ multi 记「-」、不进缓存、不报机器原因；--inspect 没跑成（退出 131）→ 【红】机器原因点名 --inspect、src_ids 退出 1
#   ⑤ unpack.sh extract --title-id <两个程序号各一次> → 都找得到 multi.xci、nx_unpack 带 --title-id=<该号>，退出 0
#   ⑥ srcver.sh / game_icons.sh / stages/aoc.sh：现行程序号 BBBB → 调 nx_unpack 时带 --title-id=0100BBBB00000000、给的是 multi.xci
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
A=0100AAAA00000000; B=0100BBBB00000000; C=0100CCCC00000000
mkdir -p "$T/src"; echo multi > "$T/src/multi.xci"; echo single > "$T/src/single.nsp"; echo upd > "$T/src/upd.nsp"; : > "$T/keys"
cat > "$T/nxu" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CALLS"
bases() { case $(basename "$1") in multi.xci) echo 0100AAAA00000000 0100BBBB00000000;; single.nsp) echo 0100CCCC00000000;; esac; }
if [ "${2:-}" = --inspect ]; then
  [ -n "${FAKE_INSPECT_RC:-}" ] && { echo "Container metadata could not be decrypted or verified. Check keys, tickets and file integrity." >&2; exit "$FAKE_INSPECT_RC"; }
  p=; for b in $(bases "$3"); do p="$p${p:+,}{\"titleId\":\"$b\",\"baseId\":\"$b\",\"type\":\"base\"}"; done
  [ "$(basename "$3")" = upd.nsp ] && p='{"titleId":"0100CCCC00000800","baseId":"0100CCCC00000000","type":"update"}'
  echo "{\"schema\":1,\"packages\":[$p]}"; exit 0; fi
OUT=$2; shift 2; MODE=extract; TID=; SRC=()
for a in "$@"; do case $a in --nacp-only) MODE=nacp;; --aoc-only) MODE=aoc;; --aoc-index) ;; --title-id=*) TID=${a#--title-id=};; *) SRC+=("$a");; esac; done
apps=$(for f in "${SRC[@]}"; do bases "$f"; done | tr ' ' '\n' | grep . | sort -u | { [ -n "$TID" ] && grep -ix "$TID" || cat; })
n=$(printf '%s' "$apps" | grep -c .)
[ "$n" = 1 ] || { echo "🔴 基础程序应恰好 1 个（按程序号），实际 $n" >&2; exit 1; }
mkdir -p "$OUT"; tid=$(printf '%s' "$apps" | tr 'A-F' 'a-f')
case $MODE in
  nacp) printf 'title_id\t%s\n' "$tid" > "$OUT/unpack.tsv"; printf 'jpg' > "$OUT/icon.jpg";;
  aoc) printf 'idx\ttitle_id\tversion\tfiles\tbytes\n' > "$OUT/aoc.tsv";;
  extract) mkdir -p "$OUT/exefs" "$OUT/romfs"; printf 'main\n' > "$OUT/exefs/main"
    printf 'title_id\t%s\ndisplay_version\t1.0\nupdate\t\nbase\t0\n' "$tid" > "$OUT/unpack.tsv";;
esac
exit 0
EOF
chmod +x "$T/nxu"; : > "$T/nxu.dll"
export S2A_NX_UNPACK=$T/nxu S2A_KEYS=$T/keys S2A_GAME_SRC=$T/src S2A_SRC_IDS=$T/ids.tsv FAKE_CALLS=$T/calls S2A_UNPACK_CACHE=off
calls() { grep -c -- "$1" "$T/calls" 2> /dev/null || true; }
ids() { bash -c 'source "$1/pack/srcs.sh"; src_ids' _ "$H"; }
rows() { printf '%s\n' "$1" | awk -F'\t' '{n = split($1, p, "/"); printf "%s=%s ", p[n], $4}'; }
o1=$(ids 2> "$T/e1"); r1=$?
ck "① 多本体出两行、单本体 / 更新照旧（退出 ${r1}，$(rows "$o1")）" \
   '[ $r1 = 0 ] && [ "$(rows "$o1")" = "multi.xci=$A multi.xci=$B single.nsp=$C upd.nsp=- " ] && [ ! -s "$T/e1" ]'
ck "③ 单本体照旧：single.nsp 调 --nacp-only 1 次（$(calls 'single.nsp')）、不调 --inspect" \
   '[ "$(calls "--nacp-only.*single.nsp")" = 1 ] && [ "$(calls "--inspect.*single.nsp")" = 0 ]'
: > "$T/calls"; o2=$(ids 2> /dev/null); r2=$?
ck "② 缓存：multi 2 行 + single 1 行进缓存（$(awk -F'\t' '{printf "%s ", $4}' "$T/ids.tsv")）；再调输出相同、只重探 upd（调用 $(grep -c . "$T/calls") 次）" \
   '[ $r2 = 0 ] && [ "$o2" = "$o1" ] && [ "$(awk -F"\t" "{printf \"%s \", \$4}" "$T/ids.tsv")" = "$A $B $C " ] && [ "$(grep -c . "$T/calls")" = 1 ] && [ "$(calls upd.nsp)" = 1 ]'
rm -f "$T/ids.tsv"; o4=$(FAKE_INSPECT_RC=3 ids 2> "$T/e4"); r4=$?
ck "④ --inspect 读不出（退出 3）→ multi 记「-」、不进缓存、不报机器原因（退出 ${r4}，$(rows "$o4")）" \
   '[ $r4 = 0 ] && [ "$(rows "$o4")" = "multi.xci=- single.nsp=$C upd.nsp=- " ] && ! grep -q multi.xci "$T/ids.tsv" && [ ! -s "$T/e4" ]'
o4b=$(FAKE_INSPECT_RC=131 ids 2> "$T/e4b"); r4b=$?
ck "④ --inspect 没跑成（退出 131）→ 【红】机器原因点名 --inspect、multi 不出行、src_ids 退出 ${r4b}" \
   '[ $r4b = 1 ] && grep -q "【红】机器原因：原件探测出错（nx_unpack --inspect 退出 131" "$T/e4b" && [ "$(rows "$o4b")" = "single.nsp=$C upd.nsp=- " ]'
rm -f "$T/ids.tsv"
for t in $A $B; do
  : > "$T/calls"; o=$(bash "$H/pack/stages/unpack.sh" extract --src "$T/src" --title-id "$t" --out "$T/x$t" --log "$T/x$t.log" 2>&1); r=$?
  ck "⑤ 解包 --title-id $t → 找到 multi.xci、nx_unpack 带 --title-id=${t}（退出 ${r}：$(printf '%s' "$o" | tail -1 | cut -c1-80)）" \
     '[ $r = 0 ] && grep -q -- "--aoc-index --title-id=$t .*multi.xci" "$T/calls" && ! grep -q -- "--aoc-index.*single.nsp" "$T/calls"'
done
# ⑥ 下游三处按现行程序号找原件：现行产物根 sonic 的程序号 = BBBB（unpack.tsv），三处都要把它传给 nx_unpack
mkdir -p "$T/roots/sonic@v1/exefs"; { head -c 64 /dev/zero; printf 'BUILD_v1........' ; head -c 32 /dev/zero; } > "$T/roots/sonic@v1/exefs/main"
printf 'title_id\t%s\n' "$(printf '%s' $B | tr 'A-F' 'a-f')" > "$T/roots/sonic@v1/unpack.tsv"; printf '%s\n' sonic@v1 > "$T/roots/sonic@现行"
mkdir -p "$T/shared"; export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_SRCVER_CACHE=$T/srcver S2A_ICONS=$T/icons S2A_AOC_CACHE=$T/aoc
: > "$T/calls"; o=$(bash "$H/pack/srcver.sh" sonic 2>&1); r=$?
ck "⑥ srcver：--nacp-only 带 --title-id=${B}、给 multi.xci（退出 ${r}：${o:0:60}）" '[ $r = 0 ] && grep -q -- "--nacp-only --title-id=$B .*multi.xci" "$T/calls"'
: > "$T/calls"; o=$(bash "$H/tools/game_icons.sh" sonic 2>&1); r=$?
ck "⑥ game_icons：--nacp-only 带 --title-id=${B}、抽到图标（退出 ${r}：${o:0:60}）" '[ $r = 0 ] && grep -q -- "--nacp-only --title-id=$B .*multi.xci" "$T/calls" && [ -s "$T/icons/sonic.jpg" ]'
: > "$T/calls"; o=$(bash "$H/pack/stages/aoc.sh" sonic 2>&1); r=$?
ck "⑥ aoc：--aoc-only 带 --title-id=${B}、给 multi.xci（退出 ${r}：$(printf '%s' "$o" | tail -1 | cut -c1-60)）" '[ $r = 0 ] && grep -q -- "--aoc-only --title-id=$B .*multi.xci" "$T/calls"'
[ $bad = 0 ] && echo "✓ srcs_multi_base_test 全通" || echo "✗ srcs_multi_base_test 有不通"
exit $bad
