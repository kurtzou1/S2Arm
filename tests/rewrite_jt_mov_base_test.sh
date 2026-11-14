#!/bin/bash
# 改写器：跳转表基址经一次寄存器拷贝（#716 Dead Cells subsdk0 0xbd1d60 / 0xbd210c 两处形态，runtime/rewriter/rewriter.c chain，合成 NSO，约 5 秒）：
#   bash tests/rewrite_jt_mov_base_test.sh
# 门禁覆盖：runtime/rewriter/*
# 形态取自玩家贴的反汇编：cmp w15,#n / b.hi / adrp x18 + add x18,#lo / mov x0,x18（基址拷进别的寄存器）/ ldrsw x18,[x0,x15,lsl#2] /
#   add x18,x18,x0 / 中间夹 adrp x0、mov w16、add x0（编译器排在取表与 br 之间）/ br x18；第二处把基址拷进 x23（0xbd210c）。
# 合成代码段从 0x100 起、一个 FDE 覆盖；表在 ro 0x800（映像 0x1800），项 = 目标 − 表基址；表后到 data 段尾全是按本表基址落在函数里的项（同 #716 两张表首尾相接、
#   后面还有表），只有界检查 cmp w15,#2 / b.hi 定得出 3 项。
# 判据（手算）：苹果 / 安卓退出码 0、缺口 0；两处分派目标都 = 0x140,0x148,0x150。改前（有界识别 jt_targets 只认同一寄存器 adrp+add、
#   跟拷贝的 jt_open 不设界读满 1024 项放弃）两处各记一个 br_x18 缺口、退出码 3
# 指令用 clang 汇编（与被测改写器无关）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
cat > "$T/c.s" <<'EOF'
.text
.p2align 2
      cmp w15, #2
      b.hi aout
      .inst 0xb0000012
      add x18, x18, #0x800
      mov x0, x18
      ldrsw x18, [x0, x15, lsl #2]
      add x18, x18, x0
      .inst 0xb0000000
      mov w16, #0xf
      add x0, x0, #0x10
      br x18
aout: ret
.org 0x40
      ret
      nop
      ret
      nop
      ret
      nop
.org 0x80
      cmp w15, #2
      b.hi bout
      .inst 0xb0000012
      add x18, x18, #0x800
      mov x23, x18
      ldrsw x18, [x23, x15, lsl #2]
      add x18, x18, x23
      mov w16, #0xf
      br x18
bout: ret
EOF
xcrun clang -arch arm64 -c "$T/c.s" -o "$T/c.o" || { echo "🔴 汇编失败"; exit 1; }
otool -t "$T/c.o" | tail -n +3 | awk '{for (i = 2; i <= NF; i++) print $i}' > "$T/words"
$PY - "$T/words" "$T/exefs_main" <<'EOF'
import struct, sys
code = [int(w, 16) for w in open(sys.argv[1]).read().split()]
# 模块骨架同 tests/rewrite_jt_cfg_base_test.sh：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(code))
struct.pack_into('<3i', ro, 0x800, 0x140 - 0x1800, 0x148 - 0x1800, 0x150 - 0x1800)
# 表后紧挨着别的表（#716 0x1482a40 + 20 项 = 0x1482a90 又是一张）：后面 1500 多项按本表基址算都落在函数里，不设界读不到头
filler = struct.pack('<i', 0x140 - 0x1800); ro[0x80c:] = filler * ((0x1000 - 0x80c) // 4); data = filler * (0x1000 // 4)
text, ro = bytes(text), bytes(ro)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[2], 'wb').write(bytes(h) + text + ro + data)
EOF
printf '模块\t偏移\t种类\t证据\n' > "$T/none.tsv"
rew() { local o=$1; shift; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$REW" "$T/exefs_main" "$T/$o" main "$T/none.tsv" > "$T/$o.log" 2>&1; echo $?; }
ra=$(rew apple S2A_TARGET=apple); rn=$(rew android S2A_TARGET=android)
for o in apple android; do
  r=$([ $o = apple ] && echo "$ra" || echo "$rn"); [ "$r" = 0 ] || grep '^GAP' "$T/$o.log" | head -3
  ng=$(grep -c '^GAP' "$T/$o.log")
  ck "① ${o}：退出码 ${r}、缺口 ${ng}（期望 0 / 0）" '[ "$r" = 0 ] && [ "$ng" = 0 ]'
done
out=$([ "$ra" = 0 ] && $PY - "$T/apple/main.patched.bin" <<'EOF' 2>&1
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
b = open(sys.argv[1], 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
def tgt(a):
    w, = struct.unpack_from('<I', b, a); imm = w & 0x3ffffff
    return a + 4 * (imm - (1 << 26) if imm >> 25 else imm) if w >> 26 == 0b000101 else None
for site in (0x128, 0x1a0):
    t = tgt(site); out = []; pg = None
    if t is None: print('不通', f'{site:#x} 没改成跳到分派块'); continue
    for i in md.disasm(b[t:t + 512], t):
        if i.mnemonic == 'adrp' and i.op_str.startswith('x17,'): pg = i.operands[1].imm
        elif i.mnemonic == 'add' and i.op_str.startswith('x17, x17, #') and pg is not None: out.append(pg + i.operands[2].imm); pg = None
        elif i.mnemonic == 'brk': break
    print('通' if out == [0x140, 0x148, 0x150] else '不通', f'{site:#x} 分派目标', ','.join(f'{x:#x}' for x in out), '（手算 0x140,0x148,0x150）')
EOF
); echo "$out" | sed 's/^/  /'
ck "② 两处分派目标都对（脚本出错也算不通）" '[ "$(echo "$out" | grep -c "^通")" = 2 ]'
[ $bad = 0 ] && echo "✅ 跳转表基址经寄存器拷贝全通" || { echo "🔴 跳转表基址经寄存器拷贝有不通项"; exit 1; }
