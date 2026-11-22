#!/bin/bash
# 社区补丁写进代码段尾巴的新代码要改写（#1628：FPSLocker 把新函数放在旷野之息 1.9.0 主程序代码段结尾的填充里，函数读计时器；
#   改写器原先不扫这段，pack/cpatch.py tail_hazard 只好把读计时器挡掉、整份补丁不进包）。合成 NSO，约 5 秒：bash tests/cpatch_tail_rewrite_test.sh
# 合成模块：代码段 0x200 字节（0x100 ret），ro 段 0x1000 起 → [0x200, 0x1000) 是代码段尾巴。期望按语义手算，不跑被测实现：
#   ① 补丁表 w 行：0x200 mrs x0, cntpct_el0（0xd53be020）、0x204 ret → rc=0、0 缺口；sites 里有 0x200 cntpct；产物 0x200 是 B（跳到补丁区计时器门）、0x204 仍是 ret
#   ② 尾巴新代码用到 x18（0x200 mov x0, x18 = 0xaa1203e0）→ 记 cpatch 缺口（「代码段尾巴新代码…x18」）
#   ③ 没有补丁表：0x200 仍是全 0、sites 里没有 0x200（尾巴里原本的填充不扫）
#   ④ 出包端 tail_hazard：mrs cntpct / cntvct / ctr、tpidr 读写、svc 放行；hvc、msr nzcv、brk #0xB1B0、mov x0, x18 照挡
#   负控：改前的改写器（scan 只看代码段）① 红：0x200 原样是 mrs、sites 里没有 0x200
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
TEXT = 0x200
text = bytearray(TEXT); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<I', text, 0x100, 0xd65f03c0)
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
word() { $PY -c "import struct,sys; print('%08x' % struct.unpack_from('<I', open(sys.argv[1],'rb').read(), int(sys.argv[2],16))[0])" "$1" "$2"; }
printf 'w\tmain\t0x200\t0\td53be020\nw\tmain\t0x204\t0\td65f03c0\n' > "$T/ok.tsv"
mkdir -p "$T/a"; S2A_CPATCH_TSV="$T/ok.tsv" "$REW" "$T/exefs/main" "$T/a" main > "$T/a.log" 2>&1; ra=$?
w200=$(word "$T/a/main.patched.bin" 200); w204=$(word "$T/a/main.patched.bin" 204)
ck "① 尾巴读计时器：rc=${ra}、0 缺口、sites 有 0x200 cntpct、0x200 改成 B（实 ${w200}）、0x204 仍 ret（实 ${w204}）" \
   '[ "$ra" = 0 ] && ! grep -qv "^#" "$T/a/main.gaps.tsv" && grep -qiE "^0x200[[:space:]]+cntpct" "$T/a/main.sites.tsv" && [ $((0x$w200 >> 26)) = 5 ] && [ "$w204" = d65f03c0 ]'
printf 'w\tmain\t0x200\t0\taa1203e0\nw\tmain\t0x204\t0\td65f03c0\n' > "$T/x18.tsv"
mkdir -p "$T/b"; S2A_CPATCH_TSV="$T/x18.tsv" "$REW" "$T/exefs/main" "$T/b" main > "$T/b.log" 2>&1
ck "② 尾巴用 x18：记 cpatch 缺口" 'grep -q "代码段尾巴新代码.*x18" "$T/b/main.gaps.tsv"'
mkdir -p "$T/c"; "$REW" "$T/exefs/main" "$T/c" main > "$T/c.log" 2>&1; w0=$(word "$T/c/main.patched.bin" 200)
ck "③ 没有补丁表：0x200 仍全 0（实 ${w0}）、sites 里没有 0x200" '[ "$w0" = 00000000 ] && ! grep -qiE "^0x200[[:space:]]" "$T/c/main.sites.tsv"'
# ④ 出包端 pack/cpatch.py tail_hazard：改写器能在尾巴里改写的放行（读计时器 / ctr / 线程寄存器 / svc），改写不了的照挡（hvc、别的系统寄存器、brk 0xB000、x18）
th=$($PY - "$H" <<'EOF'
import sys; sys.path.insert(0, sys.argv[1] + '/pack'); import cpatch
ok = [0xd53be020, 0xd53be048, 0xd53b0023, 0xd53bd041, 0xd51bd041, 0xd53bd061, 0xd4000001 | (0x7 << 5)]
no = [0xd4000002, 0xd51b4200, 0xd4360000, 0xaa1203e0]
print('放行全对' if all(cpatch.tail_hazard(w) == '' for w in ok) and all(cpatch.tail_hazard(w) for w in no) else
      '不对：' + ' '.join(f'{w:08x}={cpatch.tail_hazard(w)!r}' for w in ok + no))
EOF
)
ck "④ 出包端尾巴放行 / 拦截（${th}）" '[ "$th" = "放行全对" ]'
[ $bad = 0 ] && echo "社区补丁尾巴新代码改写单测全过" || echo "社区补丁尾巴新代码改写单测有不通"
exit $bad
