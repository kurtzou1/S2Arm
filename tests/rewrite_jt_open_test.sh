#!/bin/bash
# 改写器跳转表目标集超集识别单测（runtime/rewriter/rewriter.c 的 jt_targets_open，合成 NSO，约 3 秒）：bash tests/rewrite_jt_open_test.sh
# 门禁覆盖：runtime/rewriter/*
# 两种形态取自 Blade II（UE4 4.17）main 0x29329c8 / 0x2932fec，改前两处都记缺口、整个模块退出码 3。合成代码段从 0x100 起，表在 ro 段 0x1800 / 0x1820（各 3 项、后接 0）：
#   形态 A：adrp x15 / add x15,#0x800 / cmp w17,#2 / b.hi / ldrsw x17,[x15,x17,lsl#2] / add x18,x17,x15 / mov x17,x10 / br x18(0x11c) → 0x120 / 0x128 / 0x130
#           表项不在 x18，旧规则（jt_targets 要 ldrsw x18 + add x18,x18,xB；jt_general 拒 x16/x17）都不认
#   形态 B：adrp x11 / add x11,#0x820 / mov w0,w18 / cmp w18,#2 / b.hi / 14 条 add x1 / ldrsw x18,[x11,x0,lsl#2] / add x18,x18,x11 / br x18(0x18c) → 0x190 / 0x198 / 0x1a0
#           界检查查的是 w18、离 br 超过 16 条，旧规则找不到下标 x0 的界检查
#   反例：形态 A 但 add x18 与 br 之间是跳入点（cbz w3 跳到 mov x17,x10）→ br 处 x18 可能不是表算出的值，必须仍记缺口、退出码 3、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）
# ① 苹果 / 安卓：0 缺口、退出码 0、br_tab_open = 2
# ② 两处 br 改成跳补丁区，分派块比对的目标集逐项等于手算值（期望按 AArch64 编码手算，不跑被测实现）
# ③ 反例拒绝
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mk() { mkdir -p "$T/$1/exefs"; $PY - "$T/$1/exefs/main" "$1" <<'EOF'
import struct, sys
code = {
  # adrp 的页号已手填为 0x1000（immlo = 1）
  'pos': [0xb000000f, 0x912001ef, 0x71000a3f, 0x54000168, 0xb8b179f1, 0x8b0f0232, 0xaa0a03f1, 0xd61f0240,
          0xd503201f, 0x14000005, 0xd503201f, 0x14000003, 0xd503201f, 0x14000001,
          0xb000000b, 0x9120816b, 0x2a1203e0, 0x71000a5f, 0x540002e8] + [0x91000421] * 14 +
         [0xb8a07972, 0x8b0b0252, 0xd61f0240, 0xd503201f, 0x14000004, 0xd503201f, 0x14000002, 0xd503201f, 0xd65f03c0],
  'neg': [0xb000000f, 0x912001ef, 0x71000a3f, 0x54000168, 0x34000063, 0xb8b179f1, 0x8b0f0232, 0xaa0a03f1, 0xd61f0240,
          0xd503201f, 0x14000004, 0xd503201f, 0x14000002, 0xd503201f, 0xd65f03c0],
}[sys.argv[2]]
tabs = {'pos': ((0x800, (0x120, 0x128, 0x130)), (0x820, (0x190, 0x198, 0x1a0))), 'neg': ((0x800, (0x124, 0x12c, 0x134)),)}[sys.argv[2]]
# 模块骨架同 tests/rewrite_target_test.sh：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(code))
for off, tg in tabs:   # 相对表：项 = 目标 − 表基址
    struct.pack_into('<%di' % len(tg), ro, off, *[t - (0x1000 + off) for t in tg])
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
EOF
}
mk pos; mk neg
rew() { local m=$1 o=$2; shift 2; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$REW" "$T/$m/exefs/main" "$T/$o" main > "$T/$o.log" 2>&1; echo $?; }
ra=$(rew pos apple S2A_TARGET=apple); rn=$(rew pos android S2A_TARGET=android); rx=$(rew neg negx S2A_TARGET=apple)
[ "$ra" = 0 ] || tail -5 "$T/apple.log"; [ "$rn" = 0 ] || tail -5 "$T/android.log"
# br 处的 B → 分派块：逐个 adrp x17 + add x17 取比对目标，到 brk 为止
tab() { $PY - "$T/$1" "$2" <<'EOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, a = sys.argv[1], int(sys.argv[2], 16)
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
w, = struct.unpack_from('<I', b, a)
if w >> 26 != 0b000101: print(f'不是 B：{w:#x}'); sys.exit()
imm = w & 0x3ffffff; t = a + 4 * (imm - (1 << 26) if imm >> 25 else imm); out = []; pg = None
for i in md.disasm(b[t:t + 512], t):
    if i.mnemonic == 'adrp' and i.op_str.startswith('x17,'): pg = i.operands[1].imm
    elif i.mnemonic == 'add' and i.op_str.startswith('x17, x17, #') and pg is not None: out.append(pg + i.operands[2].imm); pg = None
    elif i.mnemonic == 'brk': break
print(','.join(f'{x:#x}' for x in out))
EOF
}
for o in apple android; do
  ng=$(grep -c '^GAP' "$T/$o.log"); op=$(grep -o "'br_tab_open': [0-9]*" "$T/$o.log")
  r=$([ $o = apple ] && echo "$ra" || echo "$rn")
  ck "① ${o}：退出码 ${r}、缺口 ${ng}、${op:-无 br_tab_open}" '[ "$r" = 0 ] && [ "$ng" = 0 ] && [ "$op" = "'"'"'br_tab_open'"'"': 2" ]'
  ta=$(tab $o 0x11c 2>&1); tb=$(tab $o 0x18c 2>&1)
  ck "② ${o}：形态 A 目标 ${ta}；形态 B 目标 ${tb}" '[ "$ta" = "0x120,0x128,0x130" ] && [ "$tb" = "0x190,0x198,0x1a0" ]'
done
gx=$(grep '^GAP' "$T/negx.log" | cut -f3,4 | cut -d: -f1 | tr '\t' ' ')
ck "③ 反例：退出码 ${rx}、缺口「${gx}」、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）" '[ "$rx" = 3 ] && [ "$gx" = "0x120 br_x18" ] && [ -e "$T/negx/main.patched.bin" ]'
[ $bad = 0 ] && echo "✅ 跳转表超集识别全通" || { echo "🔴 跳转表超集识别有不通项"; exit 1; }
