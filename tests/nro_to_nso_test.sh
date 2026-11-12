#!/bin/bash
# romfs NRO → NSO 转换 + C 改写器的 NRO 头跳过（runtime/rewriter/nro_to_nso.py、rewriter.c scan；合成 NRO，约 10 秒）：bash tests/nro_to_nso_test.sh
# 合成 NRO（期望按 switchbrew NRO / NSO 格式手算，不跑被测实现）：text / ro / data 各 0x1000、bss 0x1000；+0x4 MOD0 偏移 0x1000（MOD0 在 ro 开头）；
#   +0x10 'NRO0'、+0x18 大小 0x3000、+0x20 段表；+0x40 构建号头两个字 = hvc #0（d4000002）/ smc #0（d4000003）——是数据，被当指令扫就是缺口；
#   0x100 svc #1（d4000021）、0x104 ret：唯一一个改写点
# ① 转换：NSO 段表（文件偏移 0x100 / 0x1100 / 0x2100、内存偏移 0 / 0x1000 / 0x2000、大小各 0x1000）、bss 0x1000、构建号原样；
#    nro_modules.tsv：同内容两份（a/x.nro、b/X.NRO，扩展名不分大小写）去重成 nro0 两个路径，另一份 z.nro 是 nro1；SHA-256 = 整个 NRO 文件
# ② 坏 NRO（头里大小 ≠ 文件）跳过这一份、带【黄】、退出 0、不出表（#713 起不再整款停）；romfs 没有 NRO 退出 0、不出表
# ③ 改写 nro0：退出码 0、缺口 0、门 1 个（svc 在 0x100）、四个产物 SHA-256 = 金样（10-31 由 Python 改写器与 C 改写器同产物时生成，两边逐字节相同、两次运行一致；
#    有意改变改写产物时在提交里写明并更新金样）
# ④ 反证：把 'NRO0' 抹掉（= 旧扫描口径，头当指令扫）→ 退出码 3、缺口在 0x40（hvc）
# ⑤ 改写不动导出表：patched.bin 的 ro / data 段与原 NRO 逐字节相同（动态符号表 / 串表都在 ro 里）；text 只改了改写点那一个字（0x100 svc），其余逐字节相同
# ⑥ 同一份 romfs 再转一次：nro_modules.tsv 与各 NSO 逐字节相同（不多出模块、不重复改名）
# ⑦ NRR 登记 + 藏在大文件里的 NRO（11-03 大乱斗：764 个 NRO 全以 zstd 帧藏在 romfs/data.arc）。夹具由 x.nro 改构建号末字节（+0x48，不影响格式）得 A / B / C / D：
#    romfs：a.nro = A；data/big.arc = 随机填充 + 假 zstd 魔数 + zstd(C) + 填充 + zstd(B) + 填充 + 原样 D + 填充（zstd 帧用 zstd 命令行压，不跑被测实现）；
#    .nrr/r.nrr 登记 [A, 不存在的哈希, D, B]，C 没登记。期望（偏移由夹具拼接时记下）：nro0 = A（a.nro）；nro1 = D（data/big.arc@<D 偏移>）；
#    nro2 = B（data/big.arc@<B 帧偏移>:zstd）——按 NRR 登记顺序编号；C 不收（没登记）；NSO 正文 = 原 NRO；输出目录没有残留临时文件
#    ⑦b 分块 0x40（zstd 帧与原样 NRO 都跨块边界）结果逐字节相同；⑦c 同一 romfs 去掉 .nrr = 旧行为：只有 nro0 = A；⑦d 坏 NRR（魔数不对）跳过这一份、带【黄】、退出 0 = ⑦c（只有 nro0 = A）
#    ⑦f Switch 2 布局的 NRR（#713：字段整体后移 0x80，大小锚点在 +0x3B8、表在 +0x3D0，+0x340 是乱数）：结果同 ⑦
#    ⑦e 反证（11-03 大乱斗 data.arc 实遇）：2 GB 稀疏大文件开头一个假 NRO 头（NRO0、头里大小 0x80000000 > 2^31-1、三段自洽）→ 不去读它、退出 0、不出表（旧实现 pread 2 GB 回 EINVAL 退出 1）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
# 改写 nro0 的四个产物（patched.bin fixups gates sites 顺序）SHA-256 金样
G3='354617aed3e4558edcbcd1415658066ecc86f2d38f4a0ec0f797d5635d4b053d d35b01c47b4f52540a9ed47f2a0dcf572f11f09324a0fdeebc11522473efa02e 023f006f9c81e3cd8c5b38590b2470e75fcdef52ae0c83e0433972b019201d34 57257223a78f2746c20d09fe2447a2895e2e88927d20daeb0f1dd274caa4fdea'
mkdir -p "$T/romfs/a" "$T/romfs/b" "$T/bad" "$T/empty/x" "$T/out" "$T/c" "$T/c0"
$PY - "$T/romfs" <<'EOF'
import struct, sys
r = sys.argv[1]
def nro(tag):
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0, 0x1000)                              # +0 未用、+4 MOD0 偏移
    text[0x10:0x14] = b'NRO0'; struct.pack_into('<III', text, 0x14, 0, 0x3000, 0)
    struct.pack_into('<6I', text, 0x20, 0, 0x1000, 0x1000, 0x1000, 0x2000, 0x1000)
    struct.pack_into('<I', text, 0x38, 0x1000)
    struct.pack_into('<II', text, 0x40, 0xd4000002, 0xd4000003); text[0x48] = tag   # 构建号：hvc / smc 字 + 区分字节
    struct.pack_into('<II', text, 0x100, 0xd4000021, 0xd65f03c0)
    ro = bytearray(0x1000); EH, EF = 0x100, 0x200
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
    struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
    cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
    struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 8)
    return bytes(text) + bytes(ro) + bytes(0x1000)
a = nro(1)
open(r + '/a/x.nro', 'wb').write(a); open(r + '/b/X.NRO', 'wb').write(a); open(r + '/z.nro', 'wb').write(nro(2))
b = bytearray(a); struct.pack_into('<I', b, 0x18, 0x4000); open(r + '/../bad/b.nro', 'wb').write(b)
EOF
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/romfs" "$T/out" > "$T/conv.log" 2>&1; rc=$?
S0=$(shasum -a 256 < "$T/romfs/a/x.nro" | cut -c1-64); S1=$(shasum -a 256 < "$T/romfs/z.nro" | cut -c1-64)
ck "① 转换退出 0（实得 ${rc}）" '[ $rc = 0 ]'
ck "① nro_modules.tsv 两行：nro0 去重两份路径、nro1 是 z.nro" "[ \"\$(grep -v '^#' \"$T/out/nro_modules.tsv\")\" = \"\$(printf 'nro0\t%s\t0x3000\t0x1000\ta/x.nro|b/X.NRO\nnro1\t%s\t0x3000\t0x1000\tz.nro' $S0 $S1)\" ]"
H0=$(python3 - "$T/out/nro0" "$T/romfs/a/x.nro" <<'EOF'
import struct, sys
d, n = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
segs = [struct.unpack_from('<III', d, 0x10 + 0x10 * i) for i in range(3)]
ok = d[:4] == b'NSO0' and struct.unpack_from('<I', d, 0xc)[0] == 0 and segs == [(0x100, 0, 0x1000), (0x1100, 0x1000, 0x1000), (0x2100, 0x2000, 0x1000)] \
     and struct.unpack_from('<I', d, 0x3c)[0] == 0x1000 and d[0x40:0x60] == n[0x40:0x60] and struct.unpack_from('<III', d, 0x60) == (0x1000,) * 3 and d[0x100:] == n
print('是' if ok else f'否 {segs}')
EOF
)
ck "① NSO 头：段表 / bss / 构建号 / 未压缩、正文 = 原 NRO（实得 ${H0}）" '[ "$H0" = 是 ]'
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/bad" "$T/badout" > "$T/bad.log" 2>&1; rb=$?
ck "② 坏 NRO 跳过：退出 0、带【黄】、不出表（实得 ${rb}）" '[ $rb = 0 ] && grep -q "【黄】" "$T/bad.log" && [ ! -f "$T/badout/nro_modules.tsv" ]'
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/empty" "$T/eout" > /dev/null 2>&1; re=$?
ck "② 没有 NRO 退出 0、不出表（实得 ${re}）" '[ $re = 0 ] && [ ! -f "$T/eout/nro_modules.tsv" ]'
"$REW" "$T/out/nro0" "$T/c" nro0 > "$T/c.log" 2>&1; rc_=$?
ck "③ 退出 0（${rc_}）" '[ "$rc_" = 0 ]'
ck "③ 缺口 0、门 1 个且在 0x100" "grep -q 'gaps=0' \"$T/c.log\" && [ \"\$(grep -vc '^#' \"$T/c/nro0.gates.tsv\")\" = 1 ] && grep -v '^#' \"$T/c/nro0.gates.tsv\" | grep -q \"\$(printf '\tsvc\t1\t0x100')\$\""
g3=$(for x in patched.bin fixups.tsv gates.tsv sites.tsv; do shasum -a 256 < "$T/c/nro0.$x" | cut -c1-64; done | tr '\n' ' '); g3=${g3% }
ck "③ 四个产物 SHA-256 = 金样（实得：${g3}）" '[ "$g3" = "$G3" ]'
python3 - "$T/out/nro0" "$T/nro0_old" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read()); d[0x100 + 0x10:0x100 + 0x14] = b'\0\0\0\0'; open(sys.argv[2], 'wb').write(d)
EOF
"$REW" "$T/nro0_old" "$T/c0" nro0 > "$T/c0.log" 2>&1; rc0=$?
ck "④ 反证：抹掉 NRO0 → 退出 3（${rc0}）、缺口在 0x40" '[ "$rc0" = 3 ] && grep -q "GAP	nro0	0x40	" "$T/c0.log"'
R5=$(python3 - "$T/romfs/a/x.nro" "$T/c/nro0.patched.bin" <<'EOF'
import sys
n, p = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
ro_data = p[0x1000:0x3000] == n[0x1000:0x3000]
diff = [o for o in range(0, 0x1000, 4) if p[o:o + 4] != n[o:o + 4]]
print('是' if ro_data and diff == [0x100] else f'否 ro/data 相同={ro_data} text 改动={[hex(o) for o in diff]}')
EOF
)
ck "⑤ 改写不动导出表：ro / data 逐字节相同、text 只改 0x100（实得 ${R5}）" '[ "$R5" = 是 ]'
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/romfs" "$T/out2" > /dev/null 2>&1
ck "⑥ 同一 romfs 再转一次：表与 NSO 逐字节相同" 'cmp -s "$T/out/nro_modules.tsv" "$T/out2/nro_modules.tsv" && cmp -s "$T/out/nro0" "$T/out2/nro0" && cmp -s "$T/out/nro1" "$T/out2/nro1" && [ "$(ls "$T/out2" | wc -l)" = "$(ls "$T/out" | wc -l)" ]'
mkdir -p "$T/r7/data" "$T/r7/.nrr"
E7=$(python3 - "$T/romfs/a/x.nro" "$T/r7" <<'EOF'
import hashlib, os, random, struct, subprocess, sys
src, r = sys.argv[1], sys.argv[2]; random.seed(7)
def v(t): d = bytearray(open(src, 'rb').read()); d[0x48] = t; return bytes(d)
def z(d): return subprocess.run(['zstd', '-q', '-c', '-'], input=d, capture_output=True, check=True).stdout
def fill(n): return bytes(random.getrandbits(8) for _ in range(n))
A, B, C, D = v(0x11), v(0x12), v(0x13), v(0x14); sh = lambda d: hashlib.sha256(d).hexdigest()
open(r + '/a.nro', 'wb').write(A)
big = bytearray(fill(0x3001)) + b'\x28\xb5\x2f\xfd' + fill(16) + z(C) + fill(0x777)
ob = len(big); big += z(B) + fill(0x1235); od = len(big); big += D + fill(0x100)
open(r + '/data/big.arc', 'wb').write(big)
hs = [sh(A), sh(b'absent'), sh(D), sh(B)]
nrr = bytearray(0x350); nrr[0:4] = b'NRR0'; struct.pack_into('<IIII', nrr, 0x338, 0x350 + 32 * len(hs), 0, 0x350, len(hs))
open(r + '/.nrr/r.nrr', 'wb').write(bytes(nrr) + b''.join(bytes.fromhex(h) for h in hs))
open(r + '/../D.nro', 'wb').write(D); open(r + '/../B.nro', 'wb').write(B)
print(f'nro0\t{sh(A)}\t0x3000\t0x1000\ta.nro')
print(f'nro1\t{sh(D)}\t0x3000\t0x1000\tdata/big.arc@{od:#x}')
print(f'nro2\t{sh(B)}\t0x3000\t0x1000\tdata/big.arc@{ob:#x}:zstd', end='')
EOF
)
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/r7" "$T/o7" > "$T/o7.log" 2>&1; r7=$?
ck "⑦ 有 NRR：退出 0（实得 ${r7}）" '[ $r7 = 0 ]'
ck "⑦ 表 = A（a.nro）、D（原样@偏移）、B（zstd@偏移），C 与未出现的登记哈希不进表（实得：$(grep -v '^#' "$T/o7/nro_modules.tsv" 2>/dev/null | cut -f1,5 | tr '\n\t' '; ')）" "[ \"\$(grep -v '^#' \"$T/o7/nro_modules.tsv\" 2>/dev/null)\" = \"\$E7\" ]"
ck "⑦ NSO 正文 = 原 NRO（nro1 = D、nro2 = B），输出目录只有 nro0–2 与表" '[ "$(tail -c +257 "$T/o7/nro1" 2>/dev/null | shasum -a 256)" = "$(shasum -a 256 < "$T/D.nro")" ] && [ "$(tail -c +257 "$T/o7/nro2" 2>/dev/null | shasum -a 256)" = "$(shasum -a 256 < "$T/B.nro")" ] && [ "$(ls -A "$T/o7" | tr "\n" " ")" = "nro0 nro1 nro2 nro_modules.tsv " ]'
python3 - "$H/runtime/rewriter" "$T/r7" "$T/o7b" > /dev/null 2>&1 <<'EOF'
import sys; sys.path.insert(0, sys.argv[1]); import nro_to_nso as m
m.CHUNK = 0x40; sys.exit(m.main(sys.argv[2:]))
EOF
ck "⑦b 分块 0x40（zstd 帧与原样 NRO 都跨块边界）：表与 NSO 逐字节相同" 'cmp -s "$T/o7/nro_modules.tsv" "$T/o7b/nro_modules.tsv" && cmp -s "$T/o7/nro1" "$T/o7b/nro1" && cmp -s "$T/o7/nro2" "$T/o7b/nro2"'
mkdir -p "$T/r7c/data"; cp "$T/r7/a.nro" "$T/r7c/"; cp "$T/r7/data/big.arc" "$T/r7c/data/"
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/r7c" "$T/o7c" > /dev/null 2>&1; r7c=$?
ck "⑦c 没有 .nrr = 旧行为：只有 nro0 = a.nro（实得 ${r7c}：$(grep -v '^#' "$T/o7c/nro_modules.tsv" 2>/dev/null | cut -f1,5 | tr '\n\t' '; ')）" "[ $r7c = 0 ] && [ \"\$(grep -v '^#' \"$T/o7c/nro_modules.tsv\")\" = \"\$(echo \"\$E7\" | head -1)\" ] && [ \"\$(ls -A \"$T/o7c\" | tr '\n' ' ')\" = 'nro0 nro_modules.tsv ' ]"
cp -R "$T/r7" "$T/r7d"; printf 'XRR0' | dd of="$T/r7d/.nrr/r.nrr" conv=notrunc 2> /dev/null
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/r7d" "$T/o7d" > "$T/o7d.log" 2>&1; r7d=$?
ck "⑦d 坏 NRR 跳过：退出 0、带【黄】、表只有 nro0 = a.nro（实得 ${r7d}）" "[ $r7d = 0 ] && grep -q '【黄】' \"$T/o7d.log\" && [ \"\$(grep -v '^#' \"$T/o7d/nro_modules.tsv\")\" = \"\$(echo \"\$E7\" | head -1)\" ]"
cp -R "$T/r7" "$T/r7f"
python3 - "$T/r7f/.nrr/r.nrr" <<'EOF'
import os, struct, sys
d = open(sys.argv[1], 'rb').read(); n = (len(d) - 0x350) // 32; hs = d[0x350:]
f = bytearray(os.urandom(0x3d0)); f[0:4] = b'NRR0'   # 签名等用随机字节填（+0x340 读出来是乱数），字段整体后移 0x80
struct.pack_into('<IIII', f, 0x3b8, 0x3d0 + 32 * n, 0, 0x3d0, n)
open(sys.argv[1], 'wb').write(bytes(f) + hs)
EOF
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/r7f" "$T/o7f" > "$T/o7f.log" 2>&1; r7f=$?
ck "⑦f Switch 2 布局的 NRR：退出 0、表同 ⑦（实得 ${r7f}：$(grep -v '^#' "$T/o7f/nro_modules.tsv" 2>/dev/null | cut -f1,5 | tr '\n\t' '; ')）" "[ $r7f = 0 ] && [ \"\$(grep -v '^#' \"$T/o7f/nro_modules.tsv\" 2>/dev/null)\" = \"\$E7\" ]"
mkdir -p "$T/r7e/.nrr"; cp "$T/r7/.nrr/r.nrr" "$T/r7e/.nrr/"
python3 - "$T/r7e/huge.arc" <<'EOF'
import struct, sys
with open(sys.argv[1], 'wb') as f:
    h = bytearray(0x80); h[0x10:0x14] = b'NRO0'; struct.pack_into('<I', h, 0x18, 0x80000000)
    struct.pack_into('<6I', h, 0x20, 0, 0x7fffe000, 0x7fffe000, 0x1000, 0x7ffff000, 0x1000)
    f.write(h); f.truncate(0x80000100)   # 稀疏：不占盘
EOF
python3 "$H/runtime/rewriter/nro_to_nso.py" "$T/r7e" "$T/o7e" > "$T/o7e.log" 2>&1; r7e=$?
ck "⑦e 反证：大文件里头里大小 > 2 GB 的假 NRO 不读、退出 0、不出表（实得 ${r7e}：$(tail -1 "$T/o7e.log" | cut -c1-80)）" '[ $r7e = 0 ] && [ ! -f "$T/o7e/nro_modules.tsv" ]'
[ $bad = 0 ] && echo "🟢 nro_to_nso_test 全通" || { echo "🔴 nro_to_nso_test 有不通"; tail -3 "$T/c.log" "$T/c0.log" 2> /dev/null; exit 1; }
