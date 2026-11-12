#!/bin/bash
# 改写器「目标认不出的 br x18」一律记缺口单测（runtime/rewriter/rewriter.c analyze / gensite，合成 NSO，约 3 秒）：bash tests/rewrite_br_unknown_target_test.sh
# 门禁覆盖：runtime/rewriter/*
# 目标认不出时唯一能生成的是 dynbr：借 x16 / x17 取目标再跳。借用安全要证明落点之后不用它们的旧值、且落点不在多指令改写窗口中间——
#   目标未知两样都证明不了，所以不管函数里有没有指令读 x16 / x17，都记缺口、出包报出来，不生成映像。
#   （11-01 35f42e14a 起，分析漏掉的 br x18 在 gensite 一律 dynbr：朋友收集 梦想生活 x16 循环指针被盖、加载页死循环，产物静默错；
#    11-04 起漏点在 gensite 报错记缺口，见 tests/rewrite_undecodable_word_test.sh 的来由）
# 两个合成函数都从 0x100 起（编码由 llvm-mc -triple=aarch64 汇编）：
#   dead：mov x18,x1 / br x18(0x104) / ret                      —— 函数里没有读 x16 / x17 的指令
#   live：mov x18,x1 / br x18(0x104) / mov x0,x16 / ret         —— 0x108 读 x16
# ①② dead / live × 苹果 / 安卓：退出码 3、缺口恰 1 条「0x104 br_x18」、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mk() { mkdir -p "$T/$1/exefs"; $PY - "$T/$1/exefs/main" "$1" <<'PYEOF'
import struct, sys
code = {'dead': [0xaa0103f2, 0xd61f0240, 0xd65f03c0],
        'live': [0xaa0103f2, 0xd61f0240, 0xaa1003e0, 0xd65f03c0]}[sys.argv[2]]
# 模块骨架同 tests/rewrite_jt_open_test.sh：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
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
PYEOF
}
mk dead; mk live
rew() { local m=$1 o=$2; shift 2; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$REW" "$T/$m/exefs/main" "$T/$o" main > "$T/$o.log" 2>&1; echo $?; }
for o in apple android; do
  for m in dead live; do
    r=$(rew $m ${m}_$o S2A_TARGET=$o); gx=$(grep '^GAP' "$T/${m}_$o.log" | cut -f3,4 | cut -d: -f1 | tr '\t' ' ')
    ck "${m} ${o}：退出码 ${r}、缺口「${gx}」、产物照出（v0.3.1 拿不准不停：缺口点保持原指令）" '[ "$r" = 3 ] && [ "$gx" = "0x104 br_x18" ] && [ -e "$T/${m}_$o/main.patched.bin" ]'
  done
done
[ $bad = 0 ] && echo "✅ 认不出目标的 br x18 一律记缺口" || { echo "🔴 认不出目标的 br x18 没记缺口"; exit 1; }
