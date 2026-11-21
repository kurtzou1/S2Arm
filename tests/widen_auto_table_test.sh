#!/bin/bash
# 宽屏自动出表单测（graphics/widen/scan/auto_table.sh，闭环换成桩、不起局，约 1 秒）：bash tests/widen_auto_table_test.sh
# 假产物根：候选 5 个——main 0x10 f2w、0x20 movz、0x30 aspdiv、0x40 movz（探测局里没执行）、0x50 asp（界面镜头点，不试）。
# 桩：探测局（屏宽 1922）写 MARK 帧 100 与 0x10 / 0x20 / 0x30 首次命中；闭环局点集同时含 0x10 与 0x20 才过；--rejudge-write 把点集写成表。
# 期望（手算，不跑被测实现）：
#   ① 过：执行到 3 个 → 整组过 → 逐个去点：去 0x10 不过、去 0x20 不过、去 0x30 过 → 表 = main:0x10,main:0x20；闭环 4 局（含整组）；录像窗 mark+150:4（跟各局自己的 MARK）；0x40 / 0x50 从没进点集
#   ② 同一工具版本再跑：直接回「已有结论」，桩一次都不调
#   ④ 起局前就退（没判据）：status 记未判（不是结论，10-29 三态）、退出非 0；探测局（同构建号、到了 MARK）下次复用，不再起
#   ⑤ 先验（10-25 动森 3.0.3）：同款别的构建号有自动表、启用种类 f2w + movz → 第 1 局就试 {0x10 f2w, 0x20 movz}（过），不先跑整组
#   ⑥ f32 + 宽高比类：多一个分辨率表点 0x60 f32（探测里执行），桩只认 {0x30 aspdiv, 0x60 f32} → 整组（1）不过 → 第 2 局就是 main:0x30,main:0x60（过）
#   ⑦ 跨版本移植（10-26 动森更新后表失效）：假款 yy，新版 main 在 0x100 / 0x200 有两个点（另有探测里执行到、旧表没有的 0x300）；旧构建号目录只有特征（同样代码在旧版里各早 0x40，
#      widen_sig.py make 生成）。⑦a 探测后第 1 局 = 移植出的 main:0x100,main:0x200（桩只认它）、过、日志「移植自」；⑦b 旧特征对不上（旧版代码不同）→ 日志记黄、第 1 局退回整组 3 个点。
#      旧代码反证：auto_table.sh 不认特征，⑦a 第 1 局是整组 main:0x100,main:0x200,main:0x300（红）
#   ⑧ 两档互借：见文件末尾
#   ③ 永远不过的桩：整组（1）→ 去宽高比类 {0x10,0x20}（2）→ f32 没有、f2w {0x10}（3）、movz {0x20}（4）= 4 局，status 不过、不写表；S2A_AUTO_MAX=2 时只跑 2 局
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=1; fi; }
root() { local r=$T/roots/zz@v1; mkdir -p "$r/exefs"; printf '%s\n' zz@v1 > "$T/roots/zz@现行"
  { head -c 64 /dev/zero; printf 'BIDBIDBIDBIDBID1'; } > "$r/exefs/main"
  printf '模块\t偏移\t种类\t证据\nmain\t0x10\tf2w\tx\nmain\t0x20\tmovz\tx\nmain\t0x30\taspdiv\tx\nmain\t0x40\tmovz\tx\nmain\t0x50\tasp\tx\n' > "$r/widen_sites.tsv"; }
cat > "$T/stub.sh" <<'EOF'
#!/bin/bash
G=$1; D=$2; S=$3; FR=$4; W=${5:-}
echo "$S|$FR|${S2A_SCREEN_W:-}|$W" >> "$STUB_LOG"
if [ "$W" = --rejudge-write ]; then E=$S2A_WIDEN_DIR/${G}_$(cat "$D/bid"); mkdir -p "$E"; echo "$S" > "$E/widen_enable.$S2A_LOOP_MODE.tsv"; exit 0; fi
mkdir -p "$D"; echo "$STUB_BID" > "$D/bid"
[ "${STUB_INFRA:-0}" = 1 ] && [ "${S2A_SCREEN_W:-}" != 1922 ] && exit 1   # 起局前就退（产物根刷新红等）：没有判据
printf '①\t过\tx\n' > "$D/verdict.tsv"
if [ "${S2A_SCREEN_W:-}" = 1922 ]; then [ -n "${STUB_HITS:-}" ] && { printf 'S2A 标记 MARK：帧 100\n'; for h in $STUB_HITS; do printf '[宽] 点 main+%s 首次命中\n' "$h"; done; } > "$D/host.log" && exit 0
  printf 'S2A 标记 MARK：帧 100\n[宽] 点 main+0x10 首次命中\n[宽] 点 main+0x20 首次命中\n[宽] 点 main+0x30 首次命中\n宽屏：main+0x60 f32 表 4 项按屏幕宽放大\n' > "$D/host.log"; exit 1; fi
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_PASS:-}" ] && { [ "$S" = "$STUB_PASS" ]; exit $?; }   # 只认这一个点集
case ",$S," in *,main:0x10,*) case ",$S," in *,main:0x20,*) exit 0;; esac;; esac; exit 1
EOF
run() { env STUB_BID=$(xxd -s 0x40 -l 16 -p "$T/roots/zz@v1/exefs/main") S2A_ROOTS=$T/roots S2A_WIDEN_AUTO=$T/auto STUB_LOG=$T/log S2A_AUTO_LOOP=$T/stub.sh "$@" bash "$H/graphics/widen/scan/auto_table.sh" zz; }
root; : > "$T/log"
o=$(run); E=$T/auto/zz_$(xxd -s 0x40 -l 16 -p "$T/roots/zz@v1/exefs/main")
ck "① 状态过、表 = main:0x10,main:0x20（$(cat "$E/widen_enable.handheld.tsv" 2>/dev/null)）" '[ "$(cut -f1 "$E/handheld.status")" = 过 ] && [ "$(cat "$E/widen_enable.handheld.tsv" 2>/dev/null)" = main:0x10,main:0x20 ]'
n=$(grep -v -c -e '|1922|' -e 'rejudge' "$T/log")
ck "① 闭环 4 局（${n}）、录像窗 mark+150:4、探测局点集 = 去 asp 后 4 个" '[ "$n" = 4 ] && grep -q "|mark+150:4||$" "$T/log" && grep -q "^main:0x10,main:0x20,main:0x30,main:0x40|1-1|1922|" "$T/log"'
ck "① 0x40 / 0x50 从没进闭环点集" '! grep -v "|1922|" "$T/log" | grep -q -e 0x40 -e 0x50'
: > "$T/log"; o=$(run)
ck "② 再跑直接回已有结论、桩 0 次（$(wc -l < "$T/log" | tr -d ' ')）" '[ ! -s "$T/log" ] && grep -q 已有结论 <<< "$o"'
rm -rf "$T/auto"; : > "$T/log"; o=$(run STUB_FAIL=1)
n=$(grep -v -c '|1922|' "$T/log")
ck "③ 永远不过：4 局、status 不过、无表（${n} 局）" '[ "$n" = 4 ] && [ "$(cut -f1 "$E/handheld.status")" = 不过 ] && [ ! -f "$E/widen_enable.handheld.tsv" ]'
rm -rf "$T/auto"; : > "$T/log"; o=$(run STUB_FAIL=1 S2A_AUTO_MAX=2)
n=$(grep -v -c '|1922|' "$T/log")
ck "③ S2A_AUTO_MAX=2 只跑 2 局（${n}）" '[ "$n" = 2 ]'
# ⑤ 先验：别的构建号的自动表启用 f2w + movz
rm -rf "$T/auto"; : > "$T/log"; mkdir -p "$T/auto/zz_otherbid"; printf '模块\t偏移\t种类\t启用\nmain\t0x99\tf2w\t1\nmain\t0x98\tmovz\t1\nmain\t0x97\taspdiv\t0\n' > "$T/auto/zz_otherbid/widen_enable.handheld.tsv"
o=$(run); f=$(grep -v -e '|1922|' -e rejudge "$T/log" | head -1 | cut -d'|' -f1)
ck "⑤ 先验种类 f2w + movz：第 1 局就是 main:0x10,main:0x20（实 ${f}）、过、日志记先验" '[ "$f" = main:0x10,main:0x20 ] && [ "$(cut -f1 "$E/handheld.status")" = 过 ] && grep -q "先验：" "$E/handheld.log"'
rm -rf "$T/auto/zz_otherbid"
# ⑥ f32 + 宽高比类
printf 'main\t0x60\tf32\tx\n' >> "$T/roots/zz@v1/widen_sites.tsv"; rm -rf "$T/auto"; : > "$T/log"
o=$(run STUB_PASS=main:0x30,main:0x60); s2=$(grep -v -e '|1922|' -e rejudge "$T/log" | sed -n 2p | cut -d'|' -f1)
ck "⑥ 整组不过 → 第 2 局 = f32 + 宽高比 main:0x30,main:0x60（实 ${s2}）、过" '[ "$s2" = main:0x30,main:0x60 ] && [ "$(cut -f1 "$E/handheld.status")" = 过 ]'
# ⑦ 跨版本移植：假款 yy（main 头 0x40 字节 + 模块 ID，代码从 0x80 起；旧版同样代码从 0x40 起 → 各点旧偏移 = 新 − 0x40）
PYS=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
mkimg() { "$PYS" - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys
out, start, bid, seed = sys.argv[1], int(sys.argv[2], 16), sys.argv[3], int(sys.argv[4])
x, w = seed, []
for _ in range(0x400):
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF; v = x | 0x01000000
    if (v >> 26) in (0x05, 0x25) or (v & 0xFF000010) == 0x54000000 or (v & 0x7E000000) in (0x34000000, 0x36000000) or (v & 0x1F000000) == 0x10000000 or (v & 0x3B000000) == 0x18000000: v ^= 0x08000000
    w.append(v & 0xFFFFFFFF)
code = struct.pack(f'<{len(w)}I', *w)
img = bytearray(start) + code; img[0x40:0x50] = bid.encode()[:16].ljust(16, b'0')
open(out, 'wb').write(bytes(img))
PY
}
yroot() { local r=$T/roots/yy@v2; mkdir -p "$r/exefs" "$T/old/exefs"; printf '%s\n' yy@v2 > "$T/roots/yy@现行"
  mkimg "$r/exefs/main" 0x80 NEWBIDNEWBIDNEW2 7; mkimg "$T/old/exefs/main" 0x40 OLDBIDOLDBIDOLD1 "$1"
  printf '模块\t偏移\t种类\t证据\nmain\t0x100\taspdiv\tx\nmain\t0x200\tmovz\tx\nmain\t0x300\tmovz\tx\n' > "$r/widen_sites.tsv"
  printf '模块\t偏移\t种类\t证据\nmain\t0xc0\taspdiv\tx\nmain\t0x1c0\tmovz\tx\n' > "$T/old/sites.tsv"
  rm -rf "$T/auto"; mkdir -p "$T/auto/yy_oldbid"
  "$PYS" "$H/graphics/widen/scan/widen_sig.py" make "$T/old/exefs" main:0xc0,main:0x1c0 "$T/old/sites.tsv" "$T/auto/yy_oldbid/widen_sig.handheld.tsv" 2> /dev/null; }
yrun() { env STUB_BID=$(xxd -s 0x40 -l 16 -p "$T/roots/yy@v2/exefs/main") S2A_ROOTS=$T/roots S2A_WIDEN_AUTO=$T/auto STUB_LOG=$T/log S2A_AUTO_LOOP=$T/stub.sh "STUB_HITS=0x100 0x200 0x300" "$@" bash "$H/graphics/widen/scan/auto_table.sh" yy; }
YE=$T/auto/yy_$(xxd -s 0x40 -l 16 -p "$T/roots/yy@v2/exefs/main" 2>/dev/null)
yroot 7; YE=$T/auto/yy_$(xxd -s 0x40 -l 16 -p "$T/roots/yy@v2/exefs/main"); : > "$T/log"; o=$(yrun STUB_PASS=main:0x100,main:0x200)
f=$(grep -v -e '|1922|' -e rejudge "$T/log" | head -1 | cut -d'|' -f1)
ck "⑦a 旧构建号只有特征：第 1 局 = 移植出的 main:0x100,main:0x200（实 ${f}）、过、日志记移植自" '[ "$f" = main:0x100,main:0x200 ] && [ "$(cut -f1 "$YE/handheld.status")" = 过 ] && grep -q "移植自 yy_oldbid" "$YE/handheld.log"'
yroot 99; : > "$T/log"; o=$(yrun)
f=$(grep -v -e '|1922|' -e rejudge "$T/log" | head -1 | cut -d'|' -f1)
ck "⑦b 旧特征对不上：日志记黄、第 1 局退回整组 main:0x100,main:0x200,main:0x300（实 ${f}）" '[ "$f" = main:0x100,main:0x200,main:0x300 ] && grep -q "🟡 移植 yy_oldbid" "$YE/handheld.log"'
root
rm -rf "$T/auto"; : > "$T/log"; o=$(run STUB_INFRA=1); r=$?
ck "④ 闭环起局前就退：退出非 0、status 未判（rc=${r}）" '[ $r != 0 ] && [ "$(head -1 "$E/handheld.status" | cut -f1)" = 未判 ] && grep -q 未判 "$E/handheld.log"'
: > "$T/log"; o=$(run)
ck "④ 再跑复用探测局（桩里 1922 宽 0 次）、照常出表" '! grep -q "|1922|" "$T/log" && grep -q 复用探测局 "$E/handheld.log" && [ "$(cut -f1 "$E/handheld.status")" = 过 ]'
# ⑨ 同一工具版本连续未判两次 → 第三次触发不再起局（11-02 奥德赛探测局走不到 MARK、每次刷新重挂、各跑 2 小时）。
#    手算期望：未判 ×2（status 第 4 列 1 → 2）→ 第 3 次桩 0 次、输出「不重排」；换了产物根（刷新出新根）也不重排——只有工具版本变才重来
rm -rf "$T/auto"; : > "$T/log"; run STUB_INFRA=1 > /dev/null; run STUB_INFRA=1 > /dev/null; n2=$(head -1 "$E/handheld.status" | cut -f4); : > "$T/log"; o=$(run STUB_INFRA=1)
ck "⑨ 同工具未判两次（第 4 列 ${n2}）→ 第 3 次桩 0 次、记不重排" '[ "$n2" = 2 ] && [ ! -s "$T/log" ] && grep -q 不重排 <<< "$o"'
cp -R "$T/roots/zz@v1" "$T/roots/zz@v2"; printf '%s\n' zz@v2 > "$T/roots/zz@现行"; : > "$T/log"; o=$(run STUB_INFRA=1)
ck "⑨ 刷新出新根（zz@v2）仍不重排（桩 $(wc -l < "$T/log" | tr -d ' ') 次）" '[ ! -s "$T/log" ]'
printf '%s\n' zz@v1 > "$T/roots/zz@现行"
# ⑧ 两档互借（10-26 暗黑2：掌机档过了、主机档没拿那组点试）：主机档跑、同构建号掌机档自动表启用 0x20 movz / 0x30 aspdiv（真表格式：模块 偏移 种类 启用），
#   桩只认 main:0x20,main:0x30 → 探测后第 1 局就是它（本档执行到的同种类分辨率点 movz 只有 0x20，不再加）、过。旧代码反证：第 1 局是整组 main:0x10,main:0x20,main:0x30（红）
rm -rf "$T/auto"; mkdir -p "$E"; printf '模块\t偏移\t种类\t启用\nmain\t0x20\tmovz\t1\nmain\t0x30\taspdiv\t1\nmain\t0x10\tf2w\t0\n' > "$E/widen_enable.handheld.tsv"; : > "$T/log"
o=$(run S2A_LOOP_MODE=docked STUB_PASS=main:0x20,main:0x30); f=$(grep -v -e '|1922|' -e rejudge "$T/log" | head -1 | cut -d'|' -f1)
ck "⑧ 主机档借掌机档：第 1 局 = main:0x20,main:0x30（实 ${f}）、过、日志记两档互借" '[ "$f" = main:0x20,main:0x30 ] && [ "$(cut -f1 "$E/docked.status")" = 过 ] && grep -q 两档互借 "$E/docked.log"'
exit $fail
