#!/bin/bash
# 门禁覆盖：runtime/fix/2094f152836683a3.tsv runtime/rewriter/rewriter.c
# 01007EF00011E000 1.0.0 游戏缺陷修补表（runtime/fix/2094f152836683a3.tsv，EmergencyHeap 上报前判单例 +0x38）：bash tests/fix_botw100_test.sh
# 仓库不带游戏原件：合成模块代码段 0x100 起放调用方同形状的 7 条，表里每一对（ldr + cbz）各平移一次（真偏移 0xf395fc / 0xf39600、0xf39444 / 0xf39448 → 0x108 / 0x10c），原字 / 新字原样取自真表：
#   0x100 ldr x8,[x8]（f9400108）/ 0x104 cbz x8,0x118（b40000a8）/ 0x108 ldr x8,[x8,#0x28]（f9401508）/ 0x10c cbz x8,0x118（b4000068）/
#   0x110 mov x0,x19（aa1303e0）/ 0x114 nop（d503201f，原位是 bl 上报）/ 0x118 ret（d65f03c0）
# 期望按 AArch64 编码手算，不跑被测实现：
#   ① 真表恰好四行 c main word（两个调用方各一对），原字依次 f9401508 / b4000068 / f9401508 / b4000068
#   ② 每一对平移后改写：0x108 = ldr x9, [x8, #0x38]、0x10c = cbz x9, #0x118（判 +0x38、同一落点），其余原样；日志两行「游戏缺陷修补」、0 缺口、退出码 0
#   ③ 反证：不给表时 0x108 / 0x10c 仍是 ldr x8, [x8, #0x28] / cbz x8, #0x118（判的是 +0x28，空的 +0x38 照样进上报）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
TAB=$H/runtime/fix/2094f152836683a3.tsv
mkdir -p "$T/exefs"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0xf9400108, 0xb40000a8, 0xf9401508, 0xb4000068, 0xaa1303e0, 0xd503201f, 0xd65f03c0]
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(code))
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
EOF
rows=$(grep -v '^#' "$TAB" | grep -c .); orig=$(grep -v '^#' "$TAB" | awk -F'\t' '{print $1, $2, $4, $5}' | tr '\n' ';')
ck "① 真表四行 c main word、原字两对 f9401508 / b4000068（实：${rows} 行 ${orig}）" '[ "$rows" = 4 ] && [ "$orig" = "c main word f9401508;c main word b4000068;c main word f9401508;c main word b4000068;" ]'
dis() { $PY - "$1/main.patched.bin" <<'EOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
b = open(sys.argv[1], 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
print(';'.join(f'{i.mnemonic} {i.op_str}'.strip() for i in md.disasm(b[0x100:0x11c], 0x100)))
EOF
}
gaps() { local c; c=$(grep -vc '^#' "$1/main.gaps.tsv" 2>/dev/null); echo "${c:-0}"; }
want2='ldr x8, [x8];cbz x8, #0x118;ldr x9, [x8, #0x38];cbz x9, #0x118;mov x0, x19;nop;ret'
want3='ldr x8, [x8];cbz x8, #0x118;ldr x8, [x8, #0x28];cbz x8, #0x118;mov x0, x19;nop;ret'
for k in 0 1; do
$PY -c "import sys
rows=[l.rstrip('\\n').split('\\t') for l in open(sys.argv[1]) if l.strip() and not l.startswith('#')][2*int(sys.argv[2]):2*int(sys.argv[2])+2]
sh=int(rows[0][2],16)-0x108
for f in rows: f[2]='%x' % (int(f[2],16)-sh); print('\\t'.join(f))" "$TAB" $k > "$T/shift$k.tsv"
mkdir -p "$T/fix$k"; S2A_FIX_TSV="$T/shift$k.tsv" "$REW" "$T/exefs/main" "$T/fix$k" main > "$T/fix$k.log" 2>&1; r2=$?; d2=$(dis "$T/fix$k")
ck "② 第 $((k + 1)) 对（真偏移 $(grep -v '^#' "$TAB" | sed -n "$((2 * k + 1))p" | cut -f3)）：判 +0x38、同一落点，日志两行修补、0 缺口、rc 0（实：${d2}，修补行 $(grep -c '游戏缺陷修补：main+0x10[8c]' "$T/fix$k.log")，缺口 $(gaps "$T/fix$k")，rc ${r2}）" \
  '[ "$d2" = "$want2" ] && [ "$(grep -c "游戏缺陷修补：main+0x10[8c]" "$T/fix$k.log")" = 2 ] && [ "$(gaps "$T/fix$k")" = 0 ] && [ "$r2" = 0 ]'
done
mkdir -p "$T/none"; env -u S2A_FIX_TSV "$REW" "$T/exefs/main" "$T/none" main > "$T/none.log" 2>&1; r3=$?; d3=$(dis "$T/none")
ck "③ 反证：不给表仍判 +0x28（实：${d3}，rc ${r3}）" '[ "$d3" = "$want3" ] && [ "$r3" = 0 ]'
[ $bad = 0 ] && echo "✓ fix_botw100_test" || { echo "✗ fix_botw100_test"; exit 1; }
