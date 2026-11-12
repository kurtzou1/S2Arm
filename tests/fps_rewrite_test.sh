#!/bin/bash
# 帧率表改指令单测（S2A_FPS_TSV → runtime/rewriter/rewriter.c，合成 NSO，约 10 秒）：bash tests/fps_rewrite_test.sh
# 门禁覆盖：tests/rewriter_table_open_test.py
# 合成模块代码段从 0x100 起（期望按 AArch64 编码手算，不跑被测实现）：
#   0x100 ldrb w1,[x19,#0xbd] = 0x3942f661   表：word → 0x52800021            期望 mov w1, #1
#   0x104 fdiv s2,s3,s2       = 0x1e221862   表：adrp_slot x9                 期望 adrp x9, 键页
#   0x108 fmul s1,s2,s1       = 0x1e210841   表：ldr_slot s1 x9 2040          期望 ldr s1, [x9, #0x3fc0]（2040 × 8）
#   0x10c bl #+8（→ 0x114）   = 0x94000002   表：bl_rec w1 2042               期望原位 BL 跳板；跳板 adrp x16, 键页; str w1, [x16, #0x3fd0]; b #0x114
#   0x110 ret / 0x114 ret
# ① 0 缺口、四处如上 ② 五个产物 SHA-256 = 金样 ③ 同表两行一组、其中一行原字写错：整组不改（两处都原样）、记黄、退出码 0、无缺口，五个产物 SHA-256 = 金样
# ④ bl_rec 的 Wt 写 w16 记缺口、退出码 3
# ⑤ veneer（11-06 旷野之息镜头过渡首帧）：0x108 fmul s1,s2,s1 改成 B 跳板，体字 fcmp s1,#0.0 / b.ne +8 / fmax s0,s0,s8 / fmul s1,s2,s1，
#    期望原位 b <跳板>、跳板依次是这四条（b.ne 落在跳板第 4 条）、再 b #0x10c；0 缺口、退出码 0
# ⑥ 体字里有 B（与位置有关）：记缺口、退出码 3、改写产物照出（v0.3.1 拿不准不停）（v0.3.1 起产物照出、这一行不打）  ⑦ 条件跳出了跳板（b.ne +0x100）：同 ⑥
# ⑧ 原字写错：同 ③，整组不改、记黄、原位不动
# ⑨ veneer 记号（王国之泪布料时钟）：0x10c bl #0x114 改成 B 跳板，体字 adrp:x8 / ldr s0,[x8,#0x3fc0]（= 0xbd7fc100，槽 2040）/ bl:114，
#    期望跳板依次是 adrp x8, 键页; ldr s0, [x8, #0x3fc0]; bl #0x114; b #0x110  ⑩ bl: 目标不在代码段（bl:900000）：记缺口、退出码 3
# 金样：10-31 由 Python 改写器与 C 改写器同产物时生成（两边五个产物逐字节相同、两次运行一致）；有意改变改写产物时在提交里写明并更新金样
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
# 五个产物（fixups gaps gates patched.bin sites 顺序）的 SHA-256 金样
G_OK='2d09c6d1c1227e57ffa85bd31a7241a56a9a01d09568e7995f509030c1d0677a d71599e09fe07b29a7a15d986ccb7154366633df6ae952600906231e641b1c50 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 df9ff9bff0210c0500d3a891285eaa84f2995f09ea2025c6a28e63d4dca04cb2 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
G_BAD='2d09c6d1c1227e57ffa85bd31a7241a56a9a01d09568e7995f509030c1d0677a d71599e09fe07b29a7a15d986ccb7154366633df6ae952600906231e641b1c50 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 695c7231cb493990959f54448f3ec66680f84d3d861b922938a308f26809fd5d e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
sha5() { local f o=; for f in fixups.tsv gaps.tsv gates.tsv patched.bin sites.tsv; do o="$o $(shasum -a 256 "$1/main.$f" 2>/dev/null | cut -d' ' -f1)"; done; echo ${o# }; }
mkdir -p "$T/exefs" "$T/c"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0x3942f661, 0x1e221862, 0x1e210841, 0x94000002, 0xd65f03c0, 0xd65f03c0]
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
printf 'c main 0x100 word 3942f661 52800021\nc main 0x104 adrp_slot 1e221862 x9\nc main 0x108 ldr_slot 1e210841 s1 x9 2040\nc main 0x10c bl_rec 94000002 w1 2042\n' > "$T/fps.tsv"
printf 'c main 0x100 word deadbeef 52800021\nc main 0x104 adrp_slot 1e221862 x9\n' > "$T/bad.tsv"
S2A_FPS_TSV="$T/fps.tsv" "$REW" "$T/exefs/main" "$T/c" main > "$T/c.log" 2>&1; rc_=$?
look() { $PY - "$1" <<'EOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d = sys.argv[1]; key = next(int(l.split('\t')[1], 16) for l in open(d + '/main.fixups.tsv') if l.startswith('# KEY_PAGE_OFF\t'))
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
def one(a): return next(f'{i.mnemonic} {i.op_str}'.replace(f'#{key:#x}', '#键页') for i in md.disasm(b[a:a + 4], a))
out = [one(0x100), one(0x104), one(0x108)]
w, = struct.unpack_from('<I', b, 0x10c); assert w >> 26 == 0b100101, f'0x10c 不是 BL：{w:#x}'
imm = w & 0x3ffffff; t = 0x10c + 4 * (imm - (1 << 26) if imm >> 25 else imm)
out.append('bl 跳板：' + ';'.join(f'{i.mnemonic} {i.op_str}'.replace(f'#{key:#x}', '#键页') for i in md.disasm(b[t:t + 12], t)))
print('|'.join(out))
EOF
}
want='mov w1, #1|adrp x9, #键页|ldr s1, [x9, #0x3fc0]|bl 跳板：adrp x16, #键页;str w1, [x16, #0x3fd0];b #0x114'
gc=$(look "$T/c" 2>&1)
ck "① rc=${rc_}、四处改法（实得：${gc}）" '[ "$rc_" = 0 ] && [ "$gc" = "$want" ]'
gok=$(sha5 "$T/c")
ck "② 五个产物 SHA-256 = 金样（实得：${gok}）" '[ "$gok" = "$G_OK" ]'
look2() { $PY - "$1" <<'EOF2'
import sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d = sys.argv[1]; key = next(int(l.split('\t')[1], 16) for l in open(d + '/main.fixups.tsv') if l.startswith('# KEY_PAGE_OFF\t'))
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
print('|'.join(next(f'{i.mnemonic} {i.op_str}'.replace(f'#{key:#x}', '#键页') for i in md.disasm(b[a:a + 4], a)) for a in (0x100, 0x104)))
EOF2
}
wbad='ldrb w1, [x19, #0xbd]|fdiv s2, s3, s2'; mkdir -p "$T/badc"
S2A_FPS_TSV="$T/bad.tsv" "$REW" "$T/exefs/main" "$T/badc" main > "$T/badc.log" 2>&1; rbc=$?; gbc=$(look2 "$T/badc" 2>&1)
ck "③ 原字写错：rc=${rbc}、无缺口、记黄、整组原样（实得：${gbc}）" '[ "$rbc" = 0 ] && ! grep -qv "^#" "$T/badc/main.gaps.tsv" && grep -q "\[黄\].*1 行原字不符（0x100；" "$T/badc.log" && [ "$gbc" = "$wbad" ]'
printf 'c main 0x10c bl_rec 94000002 w16 2042\n' > "$T/w16.tsv"; mkdir -p "$T/w16c"
S2A_FPS_TSV="$T/w16.tsv" "$REW" "$T/exefs/main" "$T/w16c" main > "$T/w16c.log" 2>&1; r16c=$?
ck "④ bl_rec 用 w16（跳板 adrp x16 会先盖掉它）：记缺口、退出码 3（rc=${r16c}）" '[ "$r16c" = 3 ] && grep -q "w16" "$T/w16c/main.gaps.tsv"'
lookv() { $PY - "$1" <<'EOF3'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
b = open(sys.argv[1] + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
w, = struct.unpack_from('<I', b, 0x108)
if w >> 26 != 0b000101: print(next(f'{i.mnemonic} {i.op_str}' for i in md.disasm(b[0x108:0x10c], 0x108))); sys.exit()
imm = w & 0x3ffffff; t = 0x108 + 4 * (imm - (1 << 26) if imm >> 25 else imm)
print('b 跳板：' + ';'.join(f'{i.mnemonic} {i.op_str}'.replace(f'#{t + 12:#x}', '#跳板+12') for i in md.disasm(b[t:t + 20], t)))
EOF3
}
VB='1e202028 54000041 1e284800 1e210841'
wantv='b 跳板：fcmp s1, #0.0;b.ne #跳板+12;fmax s0, s0, s8;fmul s1, s2, s1;b #0x10c'
for c in ok:"$VB" b:"1e202028 14000001 1e210841" far:"1e202028 54000801 1e210841"; do
  n=${c%%:*}; printf 'c main 0x108 veneer 1e210841 %s\n' "${c#*:}" > "$T/v_$n.tsv"; mkdir -p "$T/v_$n"
  S2A_FPS_TSV="$T/v_$n.tsv" "$REW" "$T/exefs/main" "$T/v_$n" main > "$T/v_$n.log" 2>&1; echo $? > "$T/v_$n.rc"
done
gv=$(lookv "$T/v_ok" 2>&1); rv=$(cat "$T/v_ok.rc")
ck "⑤ veneer：rc=${rv}、0 缺口、原位 B 跳板且跳板如期（实得：${gv}）" '[ "$rv" = 0 ] && ! grep -qv "^#" "$T/v_ok/main.gaps.tsv" && [ "$gv" = "$wantv" ]'
for n in b far; do
  rx=$(cat "$T/v_$n.rc"); gx=$(grep -v "^#" "$T/v_$n/main.gaps.tsv" | cut -f3- | head -1)
  ck "⑥⑦ veneer 体字不能原样搬（${n}）：rc=${rx}、记缺口、改写产物照出（v0.3.1 拿不准不停）（缺口：${gx}）" '[ "$rx" = 3 ] && grep -q "不能原样搬进跳板" "$T/v_$n/main.gaps.tsv" && [ -e "$T/v_$n/main.patched.bin" ]'
done
printf 'c main 0x108 veneer deadbeef %s\n' "$VB" > "$T/v_bad.tsv"; mkdir -p "$T/v_bad"
S2A_FPS_TSV="$T/v_bad.tsv" "$REW" "$T/exefs/main" "$T/v_bad" main > "$T/v_bad.log" 2>&1; rvb=$?; gvb=$(lookv "$T/v_bad" 2>&1)
ck "⑧ veneer 原字写错：rc=${rvb}、无缺口、记黄、原位不动（实得：${gvb}）" '[ "$rvb" = 0 ] && ! grep -qv "^#" "$T/v_bad/main.gaps.tsv" && grep -q "\[黄\].*1 行原字不符（0x108；" "$T/v_bad.log" && [ "$gvb" = "fmul s1, s2, s1" ]'
printf 'c main 0x10c veneer 94000002 adrp:x8 bd7fc100 bl:114\n' > "$T/v_tok.tsv"; mkdir -p "$T/v_tok"
S2A_FPS_TSV="$T/v_tok.tsv" "$REW" "$T/exefs/main" "$T/v_tok" main > "$T/v_tok.log" 2>&1; rvt=$?
gvt=$($PY - "$T/v_tok" <<'EOF4'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d = sys.argv[1]; key = next(int(l.split('\t')[1], 16) for l in open(d + '/main.fixups.tsv') if l.startswith('# KEY_PAGE_OFF\t'))
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
w, = struct.unpack_from('<I', b, 0x10c); assert w >> 26 == 0b000101, f'0x10c 不是 B：{w:#x}'
imm = w & 0x3ffffff; t = 0x10c + 4 * (imm - (1 << 26) if imm >> 25 else imm)
print('b 跳板：' + ';'.join(f'{i.mnemonic} {i.op_str}'.replace(f'#{key:#x}', '#键页') for i in md.disasm(b[t:t + 16], t)))
EOF4
)
ck "⑨ veneer 记号 adrp: / bl:：rc=${rvt}、跳板如期（实得：${gvt}）" '[ "$rvt" = 0 ] && [ "$gvt" = "b 跳板：adrp x8, #键页;ldr s0, [x8, #0x3fc0];bl #0x114;b #0x110" ]'
printf 'c main 0x10c veneer 94000002 bl:900000\n' > "$T/v_far2.tsv"; mkdir -p "$T/v_far2"
S2A_FPS_TSV="$T/v_far2.tsv" "$REW" "$T/exefs/main" "$T/v_far2" main > "$T/v_far2.log" 2>&1; rvf=$?
ck "⑩ bl: 目标不在代码段：rc=${rvf}、记缺口（$(grep -v '^#' "$T/v_far2/main.gaps.tsv" | cut -f3- | head -1)）" '[ "$rvf" = 3 ] && grep -q "bl: 目标不在代码段" "$T/v_far2/main.gaps.tsv"'
gbd=$(sha5 "$T/badc")
ck "③ 整组不改时五个产物 SHA-256 = 金样（实得：${gbd}）" '[ "$gbd" = "$G_BAD" ]'
"$PY" "$H/tests/rewriter_table_open_test.py" "$REW" || bad=1
[ $bad = 0 ] && echo "fps_rewrite_test：全过" || { echo "fps_rewrite_test：有不通"; exit 1; }
