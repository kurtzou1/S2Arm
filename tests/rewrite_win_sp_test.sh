#!/bin/bash
# 改写器窗口 / 直写点 sp 平移单测（runtime/rewriter/rewriter.c，合成 NSO，约 3 秒）：bash tests/rewrite_win_sp_test.sh
# 门禁覆盖：runtime/rewriter/*
# 合成模块代码段（从 0x100 起；期望按 AArch64 编码与改写器头注释手算，不跑被测实现）：
#   W1 LL/SC 环内含 ldr x18,[sp,#0xf0]（TotK main 0x65c2dc 同款）：ldxr w8,[x2] / cmp w8,#1 / ldr x18,[sp,#0xf0] / stxr w8,wzr,[x2] / cbz w8 / b 回 / ret
#   W2 环内 sp 写回：W1 的 ldr 前换成 stp x16,x17,[sp,#-0x10]!（不可平移）
#   W3 环内无 sp：ldr 换成 mov x18,x5
#   P1 直写点 str x18,[sp,#-0x10]! / ret（不可逐字平移的老兜底路径）
#   N1 直写点 ldxr x18,[sp] / ret（sp 上独占访存，重编码放不下）
#   W4 环内 ldr x18,[sp]：原偏移 <16 的环内访存按重编码后的偏移判（#1557 复审：拿原偏移判会把这类全打成缺口）
#   W5 环内 ldr x18,[sp,#8]：同上
#   W6 环内 ldur x18,[sp,#-8]：环内负偏移 → minoff<0 → F 抬到 32
#   N2 环内 ldp x18,x19,[sp,#-0x1f0]：负偏移 -496 → 需 F=512 超抬帧上限 504 → 记缺口
# ① 安卓 W1：0 缺口、sp-safe、进岛 STPRE 抬 16、环内 ldr 偏移 0xf0→0x100、补丁区无 sp 下方访存
# ② 安卓 W2：rc=3、gaps.tsv 记窗口缺口、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）
# ③ 安卓 W3：0 缺口、sp-safe（无 sp 环行为不变）
# ④ 安卓 P1：0 缺口、sp-safe、str 写回平移成 stur [sp,#0x10]
# ⑤ 安卓 N1：rc=3 缺口（不可平移记缺口不产 below-sp）
# ⑥ 苹果 W1：rc=0、补丁区仍见 sp 下方暂存（负对照：苹果口径不变）
# ⑦ 安卓 W4：0 缺口、sp-safe、F=16、环内 ldr 偏移 0→0x10、补丁区无 sp 下方访存
# ⑧ 安卓 W5：0 缺口、sp-safe、偏移 8→0x18、补丁区无 sp 下方访存
# ⑨ 安卓 W6：0 缺口、sp-safe、进岛 STPRE 抬 32、偏移 -8→0x18、补丁区无 sp 下方访存
# ⑩ 安卓 N2：rc=3 缺口（抬帧超上限真放不下，记缺口不产 below-sp）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
nso() { # nso <out> <word,word,...>
  $PY - "$1" "$2" <<'EOF'
import struct, sys
code = [int(w, 16) for w in sys.argv[2].split(',')]
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
}
#        ldxr w8,[x2]   cmp w8,#1     ldr/stp/mov..    stxr w8,wzr,[x2] cbz w8       b 回        ret
nso "$T/w1" '885f7c48,7100051f,f9407bf2,88087c5f,34000048,17fffffb,d65f03c0'
nso "$T/w2" '885f7c48,7100051f,a9bf47f0,f9407bf2,88087c5f,34000048,17fffffa,d65f03c0'
nso "$T/w3" '885f7c48,aa0503f2,7100051f,88087c5f,34000048,17fffffb,d65f03c0'
nso "$T/p1" 'f81f0ff2,d65f03c0'   # str x18,[sp,#-0x10]! / ret
nso "$T/n1" 'c85f7ff2,d65f03c0'   # ldxr x18,[sp] / ret
nso "$T/w4" '885f7c48,7100051f,f94003f2,88087c5f,34000048,17fffffb,d65f03c0'   # 环内 ldr x18,[sp]
nso "$T/w5" '885f7c48,7100051f,f94007f2,88087c5f,34000048,17fffffb,d65f03c0'   # 环内 ldr x18,[sp,#8]
nso "$T/w6" '885f7c48,7100051f,f85f83f2,88087c5f,34000048,17fffffb,d65f03c0'   # 环内 ldur x18,[sp,#-8]
nso "$T/n2" '885f7c48,7100051f,a9614ff2,88087c5f,34000048,17fffffb,d65f03c0'   # 环内 ldp x18,x19,[sp,#-0x1f0]
rew() { local o=$1 f=$2; shift 2; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$REW" "$T/$f" "$T/$o" main > "$T/$o.log" 2>&1; echo $?; }
ra=$(rew w1a w1 S2A_TARGET=android); rg=$(rew w2a w2 S2A_TARGET=android); rn=$(rew w3a w3 S2A_TARGET=android)
rp=$(rew p1a p1 S2A_TARGET=android); rx=$(rew n1a n1 S2A_TARGET=android); rp1=$(rew w1p w1 S2A_TARGET=apple)
r4=$(rew w4a w4 S2A_TARGET=android); r5=$(rew w5a w5 S2A_TARGET=android); r6=$(rew w6a w6 S2A_TARGET=android)
r7=$(rew n2a n2 S2A_TARGET=android)
[ "$ra" = 0 ] || tail -8 "$T/w1a.log"; [ "$rg" = 0 ] && tail -8 "$T/w2a.log"
# 逐条看补丁区：岛入口块、全补丁区 sp 下方访存计数、指定形态检索
dis() { local d=$1; shift; $PY - "$T/$d" "$@" <<'EOF'
import re, struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, mode = sys.argv[1], sys.argv[2]
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
hdr = {l.split('\t')[0][2:]: l.rstrip('\n').split('\t')[1] for l in open(d + '/main.fixups.tsv') if l.startswith('# ')}
po = int(hdr['PATCH_OFF'], 16)
if mode == 'blk':   # 0x100 处 B 指向的岛入口前 5 条 + 首个 ldr [sp,#] 行
    w, = struct.unpack_from('<I', b, 0x100); assert w >> 26 == 0b000101, f'0x100 不是 B：{w:#x}'
    imm = w & 0x3ffffff; t = 0x100 + 4 * (imm - (1 << 26) if imm >> 25 else imm); out = []
    ins = list(md.disasm(b[t:t + 96], t))
    out += [f'{i.mnemonic} {i.op_str}' for i in ins[:5]]
    out += [f'{i.mnemonic} {i.op_str}' for i in ins if i.mnemonic == 'ldr' and 'sp,' in i.op_str][:1]
    print(';'.join(out))
elif mode == 'sp':  # 补丁区 sp 下方访存（写回 / 后索引移动 sp 的不算）
    bad = []
    for i in md.disasm(b[po:], po):
        if not i.mnemonic.startswith(('ldr', 'str', 'ldp', 'stp', 'ldur', 'stur', 'ldxr', 'stxr', 'ldaxr', 'stlxr')): continue
        if ']!' in i.op_str or '], #' in i.op_str: continue
        if re.search(r'\[sp, #-', i.op_str):
            bad.append(f'{i.address:#x}:{i.mnemonic} {i.op_str}')
    print(f'below_sp={len(bad)}' + ('' if not bad else ' ' + ';'.join(bad[:3])))
elif mode == 'has': # 补丁区第一条匹配 <mnemonic> <op 子串> 的指令
    m = sys.argv[3]; sub = sys.argv[4]
    hit = [f'{i.address:#x}:{i.mnemonic} {i.op_str}' for i in md.disasm(b[po:], po) if i.mnemonic == m and sub in i.op_str]
    print(hit[0] if hit else '无')
EOF
}
b1=$(dis w1a blk 2>&1); s1=$(dis w1a sp 2>&1)
s2=$(dis p1a sp 2>&1); p1b=$(dis p1a has stur 'sp,' 2>&1)
sp1=$(dis w1p sp 2>&1)
b4=$(dis w4a blk 2>&1); s4=$(dis w4a sp 2>&1)
b5=$(dis w5a blk 2>&1); s5=$(dis w5a sp 2>&1)
b6=$(dis w6a blk 2>&1); s6=$(dis w6a sp 2>&1); h6=$(dis w6a has ldur 'sp,' 2>&1)
abi() { grep -qx "# TARGET	$1" "$T/$2/main.fixups.tsv" && grep -qx "# REWRITE_ABI	$3" "$T/$2/main.fixups.tsv"; }
gap_rows() { if [ -f "$T/$1/main.gaps.tsv" ]; then grep -cv '^#\|^$' "$T/$1/main.gaps.tsv"; else echo 0; fi; }
ck "① 安卓 W1：0 缺口 sp-safe，进岛 STPRE，环内 ldr 偏移 0xf0→0x100，补丁区无 sp 下方访存（rc=${ra}；块：${b1}；sp：${s1}）" \
   '[ "$ra" = 0 ] && abi android w1a android-sp-safe-v1 && [ "$(gap_rows w1a)" = 0 ] && [[ $b1 == "stp x0, x1, [sp, #-0x10]!"* ]] && [[ $b1 == *"ldr x0, [sp, #0x100]" ]] && [ "$s1" = "below_sp=0" ]'
ck "② 安卓 W2：环内 sp 写回 → rc=3、窗口记缺口、产物照出（v0.3.1 拿不准不停，rc=${rg}）" \
   '[ "$rg" = 3 ] && [ "$(gap_rows w2a)" -ge 1 ] && grep -q "0x100" "$T/w2a/main.gaps.tsv" && [ -e "$T/w2a/main.fixups.tsv" ] && [ -e "$T/w2a/main.patched.bin" ]'
ck "③ 安卓 W3：无 sp 环 0 缺口 sp-safe（rc=${rn}）" \
   '[ "$rn" = 0 ] && abi android w3a android-sp-safe-v1 && [ "$(gap_rows w3a)" = 0 ]'
ck "④ 安卓 P1：直写点 str 写回平移成 stur（rc=${rp}；命中：${p1b}；sp：${s2}）" \
   '[ "$rp" = 0 ] && abi android p1a android-sp-safe-v1 && [ "$(gap_rows p1a)" = 0 ] && [[ $p1b == *"stur x0, [sp, #0x10]" ]] && [ "$s2" = "below_sp=0" ]'
ck "⑤ 安卓 N1：sp 上独占访存记缺口（rc=${rx}）" \
   '[ "$rx" = 3 ] && [ "$(gap_rows n1a)" -ge 1 ] && [ -e "$T/n1a/main.patched.bin" ]'
ck "⑥ 苹果 W1：负对照，仍用 sp 下方暂存、产物不变（rc=${rp1}；sp：${sp1}）" \
   '[ "$rp1" = 0 ] && ! grep -q "# TARGET" "$T/w1p/main.fixups.tsv" && [ "${sp1#below_sp=}" != "$sp1" ] && [ "${sp1%% *}" != "below_sp=0" ]'
ck "⑦ 安卓 W4：0 缺口 sp-safe，环内 ldr [sp] 平移 0→0x10（rc=${r4}；块：${b4}；sp：${s4}）" \
   '[ "$r4" = 0 ] && abi android w4a android-sp-safe-v1 && [ "$(gap_rows w4a)" = 0 ] && [[ $b4 == "stp x0, x1, [sp, #-0x10]!"* ]] && [[ $b4 == *"ldr x0, [sp, #0x10]" ]] && [ "$s4" = "below_sp=0" ]'
ck "⑧ 安卓 W5：0 缺口 sp-safe，环内 ldr [sp,#8] 平移 8→0x18（rc=${r5}；块：${b5}；sp：${s5}）" \
   '[ "$r5" = 0 ] && abi android w5a android-sp-safe-v1 && [ "$(gap_rows w5a)" = 0 ] && [[ $b5 == "stp x0, x1, [sp, #-0x10]!"* ]] && [[ $b5 == *"ldr x0, [sp, #0x18]" ]] && [ "$s5" = "below_sp=0" ]'
ck "⑨ 安卓 W6：0 缺口 sp-safe，进岛 STPRE 抬 32，环内 ldur 偏移 -8→0x18（rc=${r6}；块：${b6}；命中：${h6}；sp：${s6}）" \
   '[ "$r6" = 0 ] && abi android w6a android-sp-safe-v1 && [ "$(gap_rows w6a)" = 0 ] && [[ $b6 == "stp x0, x1, [sp, #-0x20]!"* ]] && [[ $h6 == *"ldur x0, [sp, #0x18]" ]] && [ "$s6" = "below_sp=0" ]'
ck "⑩ 安卓 N2：环内负偏移 -496 需 F=512 超上限 → rc=3、窗口记缺口、产物照出（v0.3.1 拿不准不停，rc=${r7}）" \
   '[ "$r7" = 3 ] && [ "$(gap_rows n2a)" -ge 1 ] && grep -q "0x100" "$T/n2a/main.gaps.tsv" && [ -e "$T/n2a/main.fixups.tsv" ] && [ -e "$T/n2a/main.patched.bin" ]'
exit $bad
