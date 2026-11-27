#!/bin/bash
# 门禁覆盖：pack/cpatch.py runtime/rewriter/rewriter.c
# 社区补丁代码洞搬进补丁区（11-27 D-3AF8 / D-F6ZC：一款大型 3D 游戏的 21:9 宽屏补丁从 main+0x2abe898 跳到它写在 ro 里 main+0x38c851c 的新代码，
#   模拟器不管页的执行权限、能跑；我们这里那段是装载器写的数据页，执行即被系统杀，转横屏必闪退）。合成 NSO，约 5 秒：bash tests/cpatch_cave_test.sh
# 合成模块：代码段 0x200（0x100、0x104 是 ret），ro 段 0x1000 起；洞在 ro 的 0x1400（形状仿那款游戏的那段）：
#   0x1400 stp x19,x20,[sp,#-16]!   a9bf53f3      0x1404 adrp x19,#0（页 0x1000）90000013   0x1408 ldr s0,[x19,#0x420] bd442260
#   0x140c cbz w0,0x1414            34000040      0x1410 nop d503201f                         0x1414 ldp x19,x20,[sp],#16 a8c153f3
#   0x1418 b 0x104                  17fffb3b      0x1420 常量 1.0f 3f800000（数据，不搬）
# 期望按编码手算，不跑被测实现（P = 洞搬进补丁区后的首地址，产物里 a9bf53f3 唯一一处）：
#   ① p 行 0x100（ret → b 0x1400 = 140004c0）+ w 行 0x180（0 → b 0x1400 = 140004a0）+ 7 条 v 行：rc=0、0 缺口；
#      P+4 = adrp x19 指页 0x1000（立即数 1 − (P+4)>>12）；P+8 = bd442260 原样；P+0xc/0x10/0x14 = cbz w0,+8 / b +8 / b +8（洞内跳改指搬后的 ldp：P+0x1c）；
#      P+0x18 nop；P+0x1c a8c153f3；P+0x20 = b 0x104；0x180 = b P；补丁区里有跳到 P 的 b（p 行跳板那一路）；整个产物没有一条 b 跳到 0x1400
#   ② 洞里一字用 x18（0x1410 改成 mov x0,x18 = aa1203e0）：v 行记「代码洞的字」缺口，p 点记「跳进代码洞，洞没搬成」，w 点记缺口（都对回补丁、prune 剔掉）
#   ③ 负对照：同样的 p / w 行、不给 v 行（= 修之前）：补丁区那一路 b 直接跳 0x1400（数据页），0x180 仍是 b 0x1400 —— 修之前的闪退路径
#   ④ 出包端 caves()：洞里的代码字正好是 0x1400–0x1418 七字（0x1420 常量不算）；跳到不是补丁写的地方 → 原因「走出了补丁写入范围」；洞里有 svc → 原因含 svc
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
TEXT = 0x200
text = bytearray(TEXT); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<II', text, 0x100, 0xd65f03c0, 0xd65f03c0)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4)
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg)); fo += len(seg)
h[0x40:0x50] = bytes(range(16))
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
EOF
CAVE='1400 a9bf53f3
1404 90000013
1408 bd442260
140c 34000040
1410 d503201f
1414 a8c153f3
1418 17fffb3b'
rows() {   # rows <0x1410 的字> <要不要 v 行>
  printf 'p\tmain\t100\td65f03c0\t140004c0\t0\t# t:a\nw\tmain\t180\t00000000\t140004a0\t# t:a\n'
  [ "$2" = 1 ] && echo "$CAVE" | while read -r o w; do [ "$o" = 1410 ] && w=$1; printf 'v\tmain\t%s\t00000000\t%s\t# t:a\n' "$o" "$w"; done
}
rows d503201f 1 > "$T/ok.tsv"; rows aa1203e0 1 > "$T/x18.tsv"; rows d503201f 0 > "$T/old.tsv"
for c in ok x18 old; do mkdir -p "$T/$c"; S2A_CPATCH_TSV="$T/$c.tsv" "$REW" "$T/exefs/main" "$T/$c" main > "$T/$c.log" 2>&1; echo $? > "$T/$c.rc"; done
# 产物核对（按编码手算期望；P 取产物里唯一的 a9bf53f3）
chk() { $PY - "$T/$1/main.patched.bin" "$1" <<'EOF'
import struct, sys
b = open(sys.argv[1], 'rb').read(); n = len(b) // 4; W = lambda o: struct.unpack_from('<I', b, o)[0]
def btgt(o):
    w = W(o)
    if (w & 0xfc000000) != 0x14000000: return None
    d = w & 0x3ffffff; d -= (1 << 26) if d >> 25 else 0; return o + 4 * d
def bto(o, t): return 0x14000000 | (((t - o) >> 2) & 0x3ffffff)
def adrp(rd, pc, t):
    imm = (t >> 12) - (pc >> 12); return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5) | rd
to1400 = [hex(o) for o in range(0, n * 4, 4) if btgt(o) == 0x1400]
if sys.argv[2] == 'old':
    print('OK' if W(0x180) == 0x140004a0 and any(int(x, 16) >= 0x3000 for x in to1400) else f'不对：0x180={W(0x180):08x}，跳 0x1400 的 b 在 {to1400}'); sys.exit()
ps = [o for o in range(0x3000, n * 4, 4) if W(o) == 0xa9bf53f3]
if len(ps) != 1: print(f'不对：a9bf53f3 出现 {len(ps)} 处'); sys.exit()
P = ps[0]
want = {P + 4: adrp(19, P + 4, 0x1000), P + 8: 0xbd442260, P + 0xc: 0x34000040, P + 0x10: 0x14000002, P + 0x14: bto(P + 0x14, P + 0x1c),
        P + 0x18: 0xd503201f, P + 0x1c: 0xa8c153f3, P + 0x20: bto(P + 0x20, 0x104), 0x180: bto(0x180, P)}
miss = [f'{o:#x} 实 {W(o):08x} 期 {v:08x}' for o, v in want.items() if W(o) != v]
tramp = [o for o in range(0x3000, n * 4, 4) if btgt(o) == P and o != 0x180]
print('OK' if not miss and tramp and not to1400 else f'不对：{miss} 跳 P 的 b {[hex(o) for o in tramp]} 跳 0x1400 的 b {to1400}')
EOF
}
gaps() { grep -v '^#' "$T/$1/main.gaps.tsv" 2>/dev/null | grep -c cpatch; }
r1=$(chk ok); ck "① 洞搬进补丁区：rc=$(cat "$T/ok.rc")、cpatch 缺口 $(gaps ok)、逐字核（${r1}）" '[ "$(cat "$T/ok.rc")" = 0 ] && [ "$(gaps ok)" = 0 ] && [ "$r1" = OK ]'
ck "② 洞里用 x18：v 行、p 点、w 点都记缺口" 'grep -q "^0x1410.*cpatch.*代码洞的字" "$T/x18/main.gaps.tsv" && grep -q "^0x100.*cpatch.*洞没搬成" "$T/x18/main.gaps.tsv" && grep -q "^0x180.*cpatch.*洞没搬成" "$T/x18/main.gaps.tsv"'
printf '【负对照开始】\n'
r3=$(chk old); ck "③ 负对照（不给 v 行 = 修之前）：跳板与 0x180 都直接跳 0x1400（${r3}）" '[ "$r3" = OK ]'
printf '【负对照结束】\n'
# ④ 出包端 caves()：手算期望
r4=$($PY - "$H" <<'EOF'
import struct, sys; sys.path.insert(0, sys.argv[1] + '/pack'); import cpatch
im = bytearray(0x2000); struct.pack_into('<II', im, 0x100, 0xd65f03c0, 0xd65f03c0)
cave = [0xa9bf53f3, 0x90000013, 0xbd442260, 0x34000040, 0xd503201f, 0xa8c153f3, 0x17fffb3b, 0, 0x3f800000]
def run(ws, entry):
    data = {}
    for i, w in enumerate(ws):
        for k, v in enumerate(struct.pack('<I', w)): data[0x1400 + 4 * i + k] = v
    return cpatch.caves(bytes(im), 0x200, {0x100: bytearray(struct.pack('<I', entry))}, data)
got, why = run(cave, 0x140004c0)
ok1 = not why and sorted(got) == list(range(0x1400, 0x141c, 4)) and got[0x1418] == 0x17fffb3b
_, why2 = run(cave, 0x14000700)   # 0x100 处 b 0x1d00：那里不是补丁写的
_, why3 = run(cave[:4] + [0xd4000001] + cave[5:], 0x140004c0)   # 0x1410 svc #0
print('OK' if ok1 and '走出了补丁写入范围' in why2 and 'svc' in why3 else f'不对：{sorted(hex(o) for o in got)} {why!r} | {why2!r} | {why3!r}')
EOF
)
ck "④ 出包端认洞（${r4}）" '[ "$r4" = OK ]'
[ $bad = 0 ] && echo "社区补丁代码洞单测全过" || echo "社区补丁代码洞单测有不通"
exit $bad
