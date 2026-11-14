#!/bin/bash
# 宽屏第二层候选扫描 + 改写跳板单测（graphics/widen/scan/wide_scan.py → runtime/rewriter/rewriter.c，合成 NSO，约 3 秒）：bash tests/widen_sites_test.sh
# 合成模块的代码段（从 0x100 起，下表偏移 + 0x100 = 模块偏移；期望按 AArch64 编码与 graphics/widen/README.md 规则手算，不跑被测实现）：
#   0x00 movz x8,#0x44a0,lsl#16 / 0x04 movk x8,#0x4434,lsl#48   = float2 (1280.0f, 720.0f)，X 一次拼成      → f2w 候选（0x00）+ f2h 候选（0x04，同一对的高半，11-04）
#   0x08 movz w9,#0x44a0,lsl#16 / 0x0c movz w10,#0x4434,lsl#16  = W 寄存器分两次拼                       → 不出
#   0x10 movz x11,#0x44f0,lsl#16 / 0x14 add x11,x11,#1 / 0x18 movk x11,#0x4487,lsl#48  中间改了 x11         → 不出
#   0x1c movz x12,#0x44a0,lsl#16 / 0x20 movk x12,#0x4487,lsl#48 = (1280, 1080) 不是 16:9 档                → 不出
#   0x24 movz w13,#0x8e3b / 0x28 movk w13,#0x3fe3,lsl#16       = 0x3fe38e3b（十进制 1.777778 舍入的浮点） → asp 候选
#   0x2c movz w14,#0x8e39 / 0x30 movk w14,#0x3fe3,lsl#16       = 0x3fe38e39                           → asp 候选
#   0x34 ret
#   界面布局画布 / 拷屏控件尺寸（LDP S（32 位、有符号偏移）= 0x2D400000 | imm7<<15 | Rt2<<10 | Rn<<5 | Rt，imm7 = 字节偏移 / 4；LDR X 无符号偏移 = 0xF9400000 | (偏移/8)<<10 | Rn<<5 | Rt）：
#   0x38 ldp s8,s9,[x0,#0x50] = 0x2d4a2408  后面同函数里有 lytsz                                         → capsz 候选
#   0x3c ldr x9,[x22,#0xc0]   = 0xf94062c9 / 0x40 ldp s2,s4,[x9,#0x28] = 0x2d451122                     → lytsz 候选
#   0x44 ret
#   0x48 ldr x10,[x22,#0xc0]  = 0xf94062ca / 0x4c mov x10,x1 = 0xaa0103ea / 0x50 ldp s0,s1,[x10,#0x28] = 0x2d450540   中间改写了 x10 → 不出
#   0x54 ldr x11,[x22,#0xb8]  = 0xf9405ecb / 0x58 ldp s0,s1,[x11,#0x28] = 0x2d450560                     取的不是 +0xc0 → 不出
#   0x5c ldp s8,s9,[x0,#0x50] = 0x2d4a2408 / 0x60 ret                                                   到 RET 都没有 lytsz → 不出
#   0x64 ldr x12,[x22,#0xc0]  = 0xf94062cc / 0x68 bl #+8 = 0x94000002 / 0x6c ldp s0,s1,[x12,#0x28] = 0x2d450580 / 0x70 ret   调用冲掉 x12 → 不出
#   0x74 movz x14,#1280 = 0xd280a00e / 0x78 movk x14,#720,lsl#32 = 0xf2c05a0e / 0x7c ret   整数 (1280, 720) 打包进一个 X → movz 候选（0x74）+ i2h 候选（0x78，11-04）
# ① 扫描器只出 8 行：0x100 f2w、0x104 f2h、0x124 asp、0x12c asp、0x138 capsz、0x140 lytsz、0x174 movz、0x178 i2h
# ② 改写器 0 缺口，widen.tsv = 0 0x100 f2w 0xd2a89408 / 1 0x104 f2h 0xf2e88688 / 2 0x124 asp 0x5291c76d / 3 0x12c asp 0x5291c72e / 4 0x138 capsz 0x2d4a2408 / 5 0x140 lytsz 0x2d451122 / 6 0x174 movz 0xd280a00e / 7 0x178 i2h 0xf2c05a0e
# ⑤ 0x138 / 0x140 换成宿主门：原位是 B，门表 gates.tsv 有两行种类 wide、号 4 / 5、原址 0x138 / 0x140
# ③ 0x100 改成跳板：adrp x8,键页 → str x8,[x8,#(1024+0)×8] → ldr w8,[x8,#(16+0)×8] → b 0x104（只换 MOVZ）
# ③b 0x104（f2h）改成跳板：adrp x8,键页 → str x8,[x8,#(1024+1)×8] → ldr x8,[x8,#(16+1)×8]（装整个 8 字节：宽 | 高 << 32）→ b 0x108
# ③c 0x178（i2h）改成跳板：adrp x14,键页 → str x14,[x14,#(1024+7)×8] → ldr x14,[x14,#(16+7)×8] → b 0x17c
# ⑥ 坏候选不挡出包（11-02 丹干V3）：候选表再加两行——0x1100 movz（在代码段外、只读段里）、0x100 movz（已是 f2w 改写点）→ 改写器 rc 0、widen.tsv 仍是 ② 那五行（序号连续）、日志两行「满屏候选 … 跳过（不计缺口）」
# ④ 0x124 改成跳板：adrp x13 → str x13,[x13,#(1024+2)×8] → ldr w13,[x13,#(16+2)×8] → b 0x12c（连 MOVK 一起换）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 改写器钉死的解释器（tools/rewriter-requirements.txt；gate-host 的 /usr/bin/python3 没有 capstone）
SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs" "$T/out"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0xd2a89408, 0xf2e88688, 0x52a89409, 0x52a8868a, 0xd2a89e0b, 0x9100056b, 0xf2e890eb, 0xd2a8940c, 0xf2e890ec,
        0x5291c76d, 0x72a7fc6d, 0x5291c72e, 0x72a7fc6e, 0xd65f03c0,
        0x2d4a2408, 0xf94062c9, 0x2d451122, 0xd65f03c0,
        0xf94062ca, 0xaa0103ea, 0x2d450540, 0xf9405ecb, 0x2d450560, 0x2d4a2408, 0xd65f03c0,
        0xf94062cc, 0x94000002, 0x2d450580, 0xd65f03c0,
        0xd280a00e, 0xf2c05a0e, 0xd65f03c0]
# 代码从 0x100 起；改写器要的模块骨架：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
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
$PY "$SCAN" "$T/exefs" --tsv "$T/sites.tsv" 2> "$T/scan.log"
got=$(tail -n +2 "$T/sites.tsv" | cut -f2,3 | tr '\t\n' ' ,')
ck "① 扫描器只出 0x100 f2w / 0x104 f2h / 0x124 asp / 0x12c asp / 0x138 capsz / 0x140 lytsz / 0x174 movz / 0x178 i2h（实得：${got}）" '[ "$got" = "0x100 f2w,0x104 f2h,0x124 asp,0x12c asp,0x138 capsz,0x140 lytsz,0x174 movz,0x178 i2h," ]'
"$REW" "$T/exefs/main" "$T/out" main "$T/sites.tsv" > "$T/rew.log" 2>&1; rc=$?; [ $rc = 0 ] || tail -5 "$T/rew.log"
wt=$(tr '\t\n' ' ,' < "$T/out/main.widen.tsv" 2>/dev/null)
ck "② 改写器 0 缺口（rc=${rc}）、widen.tsv 八行（实得：${wt}）" '[ $rc = 0 ] && [ "$wt" = "0 0x100 f2w 0xd2a89408,1 0x104 f2h 0xf2e88688,2 0x124 asp 0x5291c76d,3 0x12c asp 0x5291c72e,4 0x138 capsz 0x2d4a2408,5 0x140 lytsz 0x2d451122,6 0x174 movz 0xd280a00e,7 0x178 i2h 0xf2c05a0e," ]'
dis() { $PY - "$T/out" "$1" <<'EOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, a = sys.argv[1], int(sys.argv[2], 16)
key = next(int(l.split('\t')[1], 16) for l in open(d + '/main.fixups.tsv') if l.startswith('# KEY_PAGE_OFF\t'))
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
w, = struct.unpack_from('<I', b, a); assert w >> 26 == 0b000101, f'{a:#x} 不是 B：{w:#x}'
imm = w & 0x3ffffff; t = a + 4 * (imm - (1 << 26) if imm >> 25 else imm)
out = []
for i in md.disasm(b[t:t + 16], t):
    s = f'{i.mnemonic} {i.op_str}'
    s = s.replace(f'#{key:#x}', '#键页')
    out.append(s.replace(f'#{a + 4:#x}', '#+4').replace(f'#{a + 8:#x}', '#+8'))
print(';'.join(out))
EOF
}
t0=$(dis 0x100 2>&1); th=$(dis 0x104 2>&1); ti=$(dis 0x178 2>&1); t1=$(dis 0x124 2>&1)
ck "③ 0x100 跳板（实得：${t0}）" '[ "$t0" = "adrp x8, #键页;str x8, [x8, #0x2000];ldr w8, [x8, #0x80];b #+4" ]'
ck "③b 0x104 f2h 跳板装整个 X（实得：${th}）" '[ "$th" = "adrp x8, #键页;str x8, [x8, #0x2008];ldr x8, [x8, #0x88];b #+4" ]'
ck "③c 0x178 i2h 跳板装整个 X（实得：${ti}）" '[ "$ti" = "adrp x14, #键页;str x14, [x14, #0x2038];ldr x14, [x14, #0xb8];b #+4" ]'
ck "④ 0x124 跳板（实得：${t1}）" '[ "$t1" = "adrp x13, #键页;str x13, [x13, #0x2010];ldr w13, [x13, #0x90];b #+8" ]'
gw=$(awk -F'\t' '$2 == "wide" { print $3 " " $4 }' "$T/out/main.gates.tsv" 2>/dev/null | sort | tr '\n' ',')
b138=$($PY -c "import struct,sys; b=open('$T/out/main.patched.bin','rb').read(); print(int(all(struct.unpack_from('<I',b,a)[0]>>26==0b000101 for a in (0x138,0x140))))" 2>/dev/null)
ck "⑤ 0x138 / 0x140 换成宿主门：原位是 B（${b138:-?}），门表 wide 行（号 原址）= 4 0x138 / 5 0x140（实得：${gw}）" '[ "${b138:-0}" = 1 ] && [ "$gw" = "4 0x138,5 0x140," ]'
{ cat "$T/sites.tsv"; printf 'main\t0x1100\tmovz\t52800000\nmain\t0x100\tmovz\td2a89408\n'; } > "$T/sites6.tsv"; mkdir -p "$T/out6"
"$REW" "$T/exefs/main" "$T/out6" main "$T/sites6.tsv" > "$T/rew6.log" 2>&1; rc6=$?
wt6=$(tr '\t\n' ' ,' < "$T/out6/main.widen.tsv" 2>/dev/null); ny=$(grep -c '满屏候选 0x.* 跳过（不计缺口）' "$T/rew6.log"); ng=$(grep -c '^GAP' "$T/rew6.log")
ck "⑥ 坏候选两行：rc=${rc6}、GAP ${ng} 行、跳过记黄 ${ny} 行、widen.tsv 同 ②（实得：${wt6}）" '[ $rc6 = 0 ] && [ $ng = 0 ] && [ $ny = 2 ] && [ "$wt6" = "0 0x100 f2w 0xd2a89408,1 0x104 f2h 0xf2e88688,2 0x124 asp 0x5291c76d,3 0x12c asp 0x5291c72e,4 0x138 capsz 0x2d4a2408,5 0x140 lytsz 0x2d451122,6 0x174 movz 0xd280a00e,7 0x178 i2h 0xf2c05a0e," ]'
# ⑦ 社区补丁认领同一条指令（11-13：pack/cpatch.py 在本款没有我方宽屏表时放行宽屏候选点）：补丁表 p 行改 0x12c / 0x130（第二对 asp 的 MOVZ / MOVK）
#    → 改写器 rc 0、无 GAP；0x12c 不进 widen.tsv（日志「让给社区补丁」一行），其余序号连续：0 0x100 / 1 0x104 / 2 0x124 / 3 0x138 / 4 0x140 / 5 0x174 / 6 0x178
#    p 行新字手算：ldr w14,[x16,#1016×8] = 0xB9400000 | (8128÷4)<<10 | 16<<5 | 14 = 0xb95fc20e；movk 位换 nop 0xd503201f
printf 'p\tmain\t12c\t5291c72e\tb95fc20e\t0\t@k\np\tmain\t130\t72a7fc6e\td503201f\t0\n' > "$T/cp7.tsv"; mkdir -p "$T/out7"
S2A_CPATCH_TSV="$T/cp7.tsv" "$REW" "$T/exefs/main" "$T/out7" main "$T/sites.tsv" > "$T/rew7.log" 2>&1; rc7=$?
wt7=$(tr '\t\n' ' ,' < "$T/out7/main.widen.tsv" 2>/dev/null); ny7=$(grep -c '0x12c.*让给社区补丁' "$T/rew7.log"); ng7=$(grep -c '^GAP' "$T/rew7.log")
ck "⑦ 补丁认领 0x12c：rc=${rc7}、GAP ${ng7}、让给 ${ny7} 行、widen.tsv 少 0x12c（实得：${wt7}）" '[ $rc7 = 0 ] && [ $ng7 = 0 ] && [ $ny7 = 1 ] && [ "$wt7" = "0 0x100 f2w 0xd2a89408,1 0x104 f2h 0xf2e88688,2 0x124 asp 0x5291c76d,3 0x138 capsz 0x2d4a2408,4 0x140 lytsz 0x2d451122,5 0x174 movz 0xd280a00e,6 0x178 i2h 0xf2c05a0e," ]'
[ $bad = 0 ] && echo "宽屏候选扫描 + 跳板 / 门 期望 9 项全通 → 全通" || { echo "宽屏候选扫描 + 跳板 / 门 期望 9 项全通 → 有不通"; exit 1; }
