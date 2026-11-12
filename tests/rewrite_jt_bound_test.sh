#!/bin/bash
# 改写器跳转表界检查远离 b.hi 的识别单测（runtime/rewriter/rewriter.c 的 jt_general，合成 NSO，约 3 秒）：bash tests/rewrite_jt_bound_test.sh
# 门禁覆盖：runtime/rewriter/*
# 形态取自塞尔达 1.6.0 main 0x5a3858–0x5a3894：cmp w9,#9 与 b.hi 之间编译器排了 9 条 str（改前只看 7 条，记缺口「找不到下标 x9 的界检查」，整个模块退出码 3）。
# 合成代码段从 0x100 起，表在 ro 段 0x800（3 项）：
#   正例：cmp w9,#2 / 9 条 str w1,[x20,#4k] / b.hi 0x158 / adrp x18 / add x18,#0x800 / ldrsw x0,[x18,x9,lsl#2] / add x18,x0,x18 / br x18(0x13c)
#         → 0x140 / 0x148 / 0x150（各 nop + b 0x158）
#   反例：同正例，但第 5 条 str 换成 cmp w3,#0——标志位被换掉，b.hi 判的不是下标的界，必须仍记缺口、退出码 3、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）
# ① 苹果 / 安卓：正例 0 缺口、退出码 0
# ② 0x134（ldrsw）改成跳补丁区，分派后的桩逐项跳到手算目标（期望按 AArch64 编码手算，不跑被测实现）
# ③ 反例拒绝
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mk() { mkdir -p "$T/$1/exefs"; $PY - "$T/$1/exefs/main" "$1" <<'EOF'
import struct, sys
# adrp 的页号已手填为 0x1000（immlo = 1）；str w1,[x20,#4k] = 0xb9000281 | k << 10
mid = [0xb9000281 | (k << 10) for k in range(9)]
if sys.argv[2] == 'neg': mid[4] = 0x7100007f   # cmp w3, #0
code = [0x7100093f] + mid + [0x54000188, 0xb0000012, 0x91200252, 0xb8a97a40, 0x8b120012, 0xd61f0240,
        0xd503201f, 0x14000005, 0xd503201f, 0x14000003, 0xd503201f, 0x14000001, 0xd65f03c0]
tabs = ((0x800, (0x140, 0x148, 0x150)),)
# 模块骨架同 tests/rewrite_jt_open_test.sh：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
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
# ldrsw 处的 B → 分派块（… add x16,x16,x17,lsl #6 / br x16）→ 其后每 64 字节一个桩，取每个桩里第一条 b 的目标，取前 n 个
stubs() { $PY - "$T/$1" "$2" "$3" <<'EOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, a, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3])
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
w, = struct.unpack_from('<I', b, a)
if w >> 26 != 0b000101: print(f'不是 B：{w:#x}'); sys.exit()
imm = w & 0x3ffffff; t = a + 4 * (imm - (1 << 26) if imm >> 25 else imm); base = None
for i in md.disasm(b[t:t + 256], t):
    if i.mnemonic == 'br' and i.op_str == 'x16': base = i.address + 4; break
if base is None: print('没找到分派块'); sys.exit()
out = []
for k in range(n):
    bs = [i for i in md.disasm(b[base + 64 * k:base + 64 * k + 64], base + 64 * k) if i.mnemonic == 'b']
    out.append(f'{bs[0].operands[0].imm:#x}' if bs else '无')
print(','.join(out))
EOF
}
for o in apple android; do
  ng=$(grep -c '^GAP' "$T/$o.log"); r=$([ $o = apple ] && echo "$ra" || echo "$rn")
  ck "① ${o}：退出码 ${r}、缺口 ${ng}" '[ "$r" = 0 ] && [ "$ng" = 0 ]'
  s=$(stubs $o 0x134 3 2>&1)
  ck "② ${o}：桩目标 ${s}" '[ "$s" = "0x140,0x148,0x150" ]'
done
gx=$(grep '^GAP' "$T/negx.log" | cut -f3,4 | tr '\t' ' ')
ck "③ 反例：退出码 ${rx}、缺口「${gx}」、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）" '[ "$rx" = 3 ] && grep -q "^0x13c br_x18: .*找不到下标 x9 的界检查" <<< "$gx" && [ -e "$T/negx/main.patched.bin" ]'
[ $bad = 0 ] && echo "✅ 跳转表远界检查识别全通" || { echo "🔴 跳转表远界检查识别有不通项"; exit 1; }
