#!/bin/bash
# 原件版本核对单测（pack/srcver.sh；假 nx_unpack + 假原件目录，约 1 秒）：bash tests/srcver_test.sh
# 期望（按规则手写）：
#   ① 原件解出的 main 与现行同版本（假 nx_unpack --nacp-only 退出 0）→ 退出 0、打 🟢；原件 / 工具 / 现行都没变再核 → 命中缓存、不再调 nx_unpack
#   ② 现行换成另一版本（main 构建号变 → 键变）、原件报「版本不符」→ 退出 1、打【红】、写明「要按原件重解」并带 nx_unpack 的原话
#   ③ 原件解不出（不是版本不符的错）→ 退出 2、打 🟡「原件解不出」；不缓存（再核照调 nx_unpack）
#   ④ 本机原件目录里没有该程序号的包 → 退出 2、打 🟡「没有程序号」、不调 nx_unpack
#   ④b 原件目录里多一个没探测过的包、认包时工具没跑成（nx_unpack 退出 131 = 没有 .NET 运行时；退出 1 是按内容的结论，照旧记「-」）→ 退出 2、stderr 一行【红】「机器原因：原件探测出错」带 nx_unpack 原话、
#      stdout 写明「原件探测出错」，不说「没有程序号」也不往下核版本（11-05：探测出错原先被当成读不出程序号）
#   ⑤ 同一份 nx_unpack 换到另一个目录（内容相同、路径不同）→ 键不变、命中缓存、不再调 nx_unpack（键里不许有工具路径）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p "$T/src" "$T/roots/acnh@v1/exefs" "$T/roots/acnh@v2/exefs"; printf '%s\n' acnh@v1 > "$T/roots/acnh@现行"
for v in v1 v2; do { head -c 64 /dev/zero; printf "BUILD_$v.........." | head -c 16; head -c 32 /dev/zero; } > "$T/roots/acnh@$v/exefs/main"; printf 'title_id\t01006f8002326000\n' > "$T/roots/acnh@$v/unpack.tsv"; done
echo base > "$T/src/game.nsp"; echo upd > "$T/src/upd.nsp"
# 原件认包缓存预先写好（src_ids 按「路径 大小 修改时间」命中，不调 nx_unpack 认包）：卡带是本款，更新读不出程序号
for f in game.nsp upd.nsp; do p=$T/src/$f; printf '%s\t%s\t%s\n' "$p" "$(stat -L -c '%s	%.9Y' "$p" 2> /dev/null || stat -L -f '%z	%.9Fm' "$p")" "$([ $f = game.nsp ] && echo 01006F8002326000 || echo -)"; done > "$T/ids.tsv"
cat > "$T/nxu" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CALLS"
case $FAKE_MODE in
  same) exit 0;;
  noruntime) echo "You must install .NET to run this application." >&2; exit 131;;
  diff) echo "🔴 版本不符：包里 main 构建号 FF1D，$3/exefs/main 是 5D91（元数据 3.0.3与已有 exefs 不是同一版本，没写）" >&2; exit 1;;
  *) echo "🔴 密钥缺：title.keys 里没有这个游戏" >&2; exit 1;;
esac
EOF
chmod +x "$T/nxu"; : > "$T/nxu.dll"
export S2A_NX_UNPACK=$T/nxu S2A_GAME_SRC=$T/src S2A_SRC_IDS=$T/ids.tsv S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/roots S2A_SRCVER_CACHE=$T/cache FAKE_CALLS=$T/calls
n() { awk 'END { print NR }' "$T/calls" 2> /dev/null || echo 0; }
o1=$(FAKE_MODE=same bash "$H/pack/srcver.sh" acnh); r1=$?; c1=$(n); o1b=$(FAKE_MODE=diff bash "$H/pack/srcver.sh" acnh); r1b=$?; c1b=$(n)
ck "① 同版本 → 退出 ${r1}、🟢；再核命中缓存（调 nx_unpack ${c1} → ${c1b} 次，退出 ${r1b}）" '[ $r1 = 0 ] && [[ "$o1" == 🟢* ]] && [ "$c1" = 1 ] && [ "$c1b" = 1 ] && [ $r1b = 0 ]'
# ⑤ 同一份工具换到另一个目录（内容相同、路径不同）→ 键不变、命中缓存、不再调 nx_unpack（键里不许有工具路径）
mkdir -p "$T/bin2"; cp "$T/nxu" "$T/bin2/nxu"; cp "$T/nxu.dll" "$T/bin2/nxu.dll"; : > "$T/calls"
o5=$(S2A_NX_UNPACK=$T/bin2/nxu FAKE_MODE=diff bash "$H/pack/srcver.sh" acnh); r5=$?; c5=$(n)
ck "⑤ 工具换目录、内容不变 → 键不变、命中缓存（调 nx_unpack ${c5} 次，退出 ${r5}，缓存 $(ls "$T/cache" | wc -l | tr -d ' ') 份）" \
   '[ $r5 = 0 ] && [ "$c5" = 0 ] && [ "$(ls "$T/cache" | wc -l | tr -d " ")" = 1 ]'
printf '%s\n' acnh@v2 > "$T/roots/acnh@现行"
o2=$(FAKE_MODE=diff bash "$H/pack/srcver.sh" acnh); r2=$?
ck "② 现行换版本、原件报版本不符 → 退出 ${r2}、【红】写明要按原件重解（${o2:0:60}…）" '[ $r2 = 1 ] && [[ "$o2" == 【红】* ]] && [[ "$o2" == *要按原件重解* ]] && [[ "$o2" == *"版本不符：包里 main 构建号 FF1D"* ]]'
rm -rf "$T/cache"; : > "$T/calls"
o3=$(FAKE_MODE=err bash "$H/pack/srcver.sh" acnh); r3=$?; o3b=$(FAKE_MODE=err bash "$H/pack/srcver.sh" acnh); c3=$(n)
ck "③ 原件解不出 → 退出 ${r3}、🟡、不缓存（两次共调 ${c3} 次）" '[ $r3 = 2 ] && [[ "$o3" == 🟡*原件解不出*密钥缺* ]] && [ "$c3" = 2 ]'
: > "$T/calls"; printf 'title_id\t0100000000000000\n' > "$T/roots/acnh@v2/unpack.tsv"
o4=$(FAKE_MODE=same bash "$H/pack/srcver.sh" acnh); r4=$?
ck "④ 原件目录里没有该程序号 → 退出 ${r4}、🟡、不调 nx_unpack（$(n) 次）" '[ $r4 = 2 ] && [[ "$o4" == *没有程序号* ]] && [ "$(n)" = 0 ]'
echo new > "$T/src/new.nsp"; : > "$T/calls"
o4b=$(FAKE_MODE=noruntime bash "$H/pack/srcver.sh" acnh 2> "$T/e4b"); r4b=$?; e4b=$(cat "$T/e4b"); rm -f "$T/src/new.nsp"
ck "④b 认包探测出错 → 退出 ${r4b}、【红】机器原因带原话、不说没有程序号、不往下核（调 nx_unpack $(n) 次）" \
   '[ $r4b = 2 ] && [[ "$e4b" == *"【红】机器原因：原件探测出错（nx_unpack --nacp-only 退出 131"*"You must install .NET"*"new.nsp）"* ]] && [[ "$o4b" == *原件探测出错* ]] && [[ "$o4b" != *没有程序号* ]] && [ "$(n)" = 1 ]'
# ⑥ PATH 中真正没有 xxd，仍读出 16 字节构建号；不能拿空构建号复用旧版缓存。
mkdir -p "$T/no-xxd"
for cmd in awk dirname find sort stat mkdir touch shasum cut mktemp cp rm grep mv head sed tail basename readlink python3; do
  ln -s "$(command -v "$cmd")" "$T/no-xxd/$cmd"
done
BASH_BIN=$(command -v bash)
ck "⑥a 隔离 PATH 确无 xxd" '! PATH="$T/no-xxd" "$BASH_BIN" -c "command -v xxd"'
rm -rf "$T/cache"; : > "$T/calls"
printf 'title_id\t01006f8002326000\n' > "$T/roots/acnh@v2/unpack.tsv"
printf '%s\n' acnh@v1 > "$T/roots/acnh@现行"
o6=$(PATH="$T/no-xxd" FAKE_MODE=same "$BASH_BIN" "$H/pack/srcver.sh" acnh); r6=$?
# 42 55 49 4c 44 5f 76 31 是手写的 ASCII BUILD_v1，非从被测实现取期望。
ck "⑥b 无 xxd 同版 → 退出 ${r6}、正确构建号" '[ $r6 = 0 ] && [[ "$o6" == *4255494c445f7631* ]]'
printf '%s\n' acnh@v2 > "$T/roots/acnh@现行"
o6b=$(PATH="$T/no-xxd" FAKE_MODE=diff "$BASH_BIN" "$H/pack/srcver.sh" acnh); r6b=$?
ck "⑥c 无 xxd 换版 → 退出 ${r6b}、不误中旧版缓存" '[ $r6b = 1 ] && [[ "$o6b" == 【红】* ]] && [ "$(n)" = 2 ]'
# ⑦ 短头不是有效构建号，不能用部分 / 空读数查缓存或调用解包器。
rm -rf "$T/cache"; : > "$T/calls"
head -c 72 /dev/zero > "$T/roots/acnh@v2/exefs/main"
o7=$(PATH="$T/no-xxd" FAKE_MODE=same "$BASH_BIN" "$H/pack/srcver.sh" acnh); r7=$?
ck "⑦ 短头 → 退出 ${r7}、未核、不缓存也不解包" '[ $r7 = 2 ] && [[ "$o7" == 🟡*构建号* ]] && [ ! -e "$T/cache" ] && [ "$(n)" = 0 ]'
# ⑧ 既有 Python 依赖也缺失时明确未核，不能落回空构建号。
cp "$T/roots/acnh@v1/exefs/main" "$T/roots/acnh@v2/exefs/main"
rm "$T/no-xxd/python3"
o8=$(PATH="$T/no-xxd" FAKE_MODE=same "$BASH_BIN" "$H/pack/srcver.sh" acnh); r8=$?
ck "⑧ 缺 Python → 退出 ${r8}、未核、不缓存也不解包" '[ $r8 = 2 ] && [[ "$o8" == 🟡*构建号* ]] && [ ! -e "$T/cache" ] && [ "$(n)" = 0 ]'
[ $bad = 0 ] && echo "srcver 单测全过" || { echo "srcver 单测有不通"; exit 1; }
