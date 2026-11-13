#!/bin/bash
# 社区补丁双路跳板单测（改写器 S2A_CPATCH_TSV，合成 NSO + unicorn 跑改写产物，约 5 秒）：bash tests/cpatch_twopath_test.sh
# 合成 main 代码段（映像偏移，期望全部手算，不跑被测实现）：
#   0x100 mov w0,#1          p 位 0 → mov w0,#2
#   0x104 b.ne 0x10c         p 位 1 → nop（标志 Z=0：原路跳过 0x108；补丁路落到 0x108）
#   0x108 mov w1,#5
#   0x10c adr x2,0x200       p 位 2 → adr x2,0x300（PC 相对重定位）
#   0x110 ldr w3,0x180       p 位 3 → ldr w3,0x184（字面量重定位；0x180 = 0x11111111、0x184 = 0x22222222）
#   0x114 mov w4,#3          p 位 4 → b 0x1a0（入口跳进填充区）
#   0x118 ret
#   0x1a0 / 0x1a4 原为 0（填充）  w 行常写：mov w4,#7 / b 0x118
# ① 掩码 0：w0=1、w1=0（b.ne 跳过）、x2=基址+0x200、w3=0x11111111、w4=3
# ② 掩码 0x1f：w0=2、w1=5、x2=基址+0x300、w3=0x22222222、w4=7
# ③ 两次都：x16 进出不变（0xdead）、sp 进出不变、标志位 NZCV 不变
# ④ 补丁点 0x118 改 ret → nop 但它同时是 x18 改写点？不用：另测「p 点原字不符」→ 缺口 cpatch、该点不改
# ⑥ 每执行一条指令前往当前 sp 以下 256 字节灌乱码（模拟信号帧压在客体栈上）：两路结果与 x16 照旧——跳板先下移 sp 再存，存的在新 sp 之上
# ⑤ 好行 / 坏行 / 远跳三份补丁表：输出目录的文件名与每个文件 SHA-256 = 金样（GOLD；10-31 由 Python 改写器与 C 改写器同产物时生成，两边逐字节相同、两次运行一致；
#    有意改变改写产物时在提交里写明并更新金样；坏行 11-13 随 0e53ad8b「缺口降级继续」更新，另直接核那条没写、原字保持）
# ⑦ 补丁点搬进补丁区后跳转超 ±128 MB（往回跳 128 MB 的 b，近布局补丁区够不着）：10-30 起整轮按双补丁岛重做，前岛（基址前 1 MB）接住——
#    退出码 0、无缺口、表头 PATCH2_OFF = −(FRONT 0x100000 + LOAD_BIAS 0x2000) = −0x102000（data 0x2000 与 text 末同在第一个 16 KB 页）（两岛都够不着的缺口 / brk 见 tests/rewrite_islands_test.sh）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
"$PY" - "$H" "$T" "$REW" <<'EOF'
import os, struct, subprocess, sys
H, T, REW = sys.argv[1:]
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
def adr(pc, t, rd): d = t - pc; return 0x10000000 | ((d & 3) << 29) | (((d >> 2) & 0x7FFFF) << 5) | rd
def ldrw(pc, t, rt): return 0x18000000 | ((((t - pc) >> 2) & 0x7FFFF) << 5) | rt
def b(pc, t): return 0x14000000 | (((t - pc) >> 2) & 0x3FFFFFF)
words = {0x100: 0x52800020, 0x104: 0x54000041, 0x108: 0x528000A1, 0x10c: adr(0x10c, 0x200, 2), 0x110: ldrw(0x110, 0x180, 3), 0x114: 0x52800064, 0x118: 0xD65F03C0,
         0x180: 0x11111111, 0x184: 0x22222222}
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
for o, w in words.items(): struct.pack_into('<I', text, o, w)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200; NCODE = 7
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * NCODE)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, bytes(0x1000)))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
os.makedirs(T + '/out'); open(T + '/main', 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(0x1000))
open(T + '/sites.tsv', 'w').write('模块\t偏移\t种类\t证据\n')
rows = [('p', 0x100, words[0x100], 0x52800040, 0), ('p', 0x104, words[0x104], 0xD503201F, 1), ('p', 0x10c, words[0x10c], adr(0x10c, 0x300, 2), 2),
        ('p', 0x110, words[0x110], ldrw(0x110, 0x184, 3), 3), ('p', 0x114, words[0x114], b(0x114, 0x1a0), 4),
        ('w', 0x1a0, 0, 0x528000E4, None), ('w', 0x1a4, 0, b(0x1a4, 0x118), None)]
cmd = [REW]
def rew(rows_, out):
    os.makedirs(out, exist_ok=True)
    with open(out + '.tsv', 'w') as f:
        for k, o, a, n, bit in rows_: f.write(f'{k}\tmain\t{o:x}\t{a:08x}\t{n:08x}' + (f'\t{bit}' if bit is not None else '') + '\n')
    r = subprocess.run(cmd + [T + '/main', out, 'main', T + '/sites.tsv'], env=dict(os.environ, S2A_CPATCH_TSV=out + '.tsv'), capture_output=True, text=True)
    return r.returncode, (open(out + '/main.gaps.tsv').read() if os.path.exists(out + '/main.gaps.tsv') else '')
rc0, g0 = rew(rows, T + '/out')
ck(f'⓪ 好行全收：rc=0、无缺口（rc={rc0}）', rc0 == 0 and 'cpatch' not in g0)
rc4, g4 = rew([('p', 0x108, 0xDEADBEEF, 0, 5)], T + '/bad')
ck(f'④ 原字不符的 p 点 0x108 记缺口 cpatch（rc={rc4}）', rc4 != 0 and 'cpatch' in g4 and '108' in g4)
img = open(T + '/out/main.patched.bin', 'rb').read()
key = next(int(l.split('\t')[1], 16) for l in open(T + '/out/main.fixups.tsv') if l.startswith('# KEY_PAGE_OFF\t'))
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3, UC_ARM64_REG_X4, UC_ARM64_REG_X16, UC_ARM64_REG_SP, UC_ARM64_REG_LR, UC_ARM64_REG_NZCV, UC_ARM64_REG_PC
BASE, STK, END = 0x10000000, 0x20000000, 0x30000000
def run(mask, clobber=False):
    u = Uc(UC_ARCH_ARM64, UC_MODE_ARM); size = (len(img) + key + 0x10000 + 0xFFFF) & ~0xFFFF
    u.mem_map(BASE, size); u.mem_write(BASE, img); u.mem_write(BASE + key + 2046 * 8, struct.pack('<Q', mask))
    u.mem_map(STK, 0x10000); u.mem_map(END, 0x1000); u.mem_write(END, struct.pack('<I', 0xD503201F))
    for rg in (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3, UC_ARM64_REG_X4): u.reg_write(rg, 0)
    u.reg_write(UC_ARM64_REG_X16, 0xdead); u.reg_write(UC_ARM64_REG_SP, STK + 0x8000); u.reg_write(UC_ARM64_REG_LR, END); u.reg_write(UC_ARM64_REG_NZCV, 0)
    if clobber:   # ⑥ 模拟信号帧压在客体栈上：每执行一条指令前把当前 sp 以下 256 字节灌乱码（无红区；存的 x16 必须在 sp 之上才不被踩）
        from unicorn import UC_HOOK_CODE
        def hk(uc, addr, size_, _):
            sp = uc.reg_read(UC_ARM64_REG_SP); uc.mem_write(sp - 256, bytes([0xA5]) * 256)
        u.hook_add(UC_HOOK_CODE, hk)
    u.emu_start(BASE + 0x100, END, count=500)
    g = lambda r_: u.reg_read(r_)
    return g(UC_ARM64_REG_X0) & 0xffffffff, g(UC_ARM64_REG_X1) & 0xffffffff, g(UC_ARM64_REG_X2) - BASE, g(UC_ARM64_REG_X3) & 0xffffffff, g(UC_ARM64_REG_X4) & 0xffffffff, g(UC_ARM64_REG_X16), g(UC_ARM64_REG_SP) - STK, g(UC_ARM64_REG_NZCV), g(UC_ARM64_REG_PC)
a = run(0); b_ = run(0x1f); ac = run(0, True); bc = run(0x1f, True)
ck(f'⑥ 每步往 sp 以下灌乱码（模拟信号帧）：两路结果与 x16 照旧（实得 {ac[:6]} / {bc[:6]}）', ac[:6] == a[:6] and bc[:6] == b_[:6] and ac[5] == bc[5] == 0xdead)
ck(f'① 掩码 0：w0=1 w1=0 x2=+0x200 w3=0x11111111 w4=3（实得 {a[0]} {a[1]} {a[2]:#x} {a[3]:#x} {a[4]}）', a[:5] == (1, 0, 0x200, 0x11111111, 3))
ck(f'② 掩码 0x1f：w0=2 w1=5 x2=+0x300 w3=0x22222222 w4=7（实得 {b_[0]} {b_[1]} {b_[2]:#x} {b_[3]:#x} {b_[4]}）', b_[:5] == (2, 5, 0x300, 0x22222222, 7))
ck(f'③ x16 / sp / NZCV 进出不变、都跑到返回点（实得 {a[5]:#x} {a[6]:#x} {a[7]} / {b_[5]:#x} {b_[6]:#x} {b_[7]}）', a[5] == b_[5] == 0xdead and a[6] == b_[6] == 0x8000 and a[7] == b_[7] == 0 and a[8] == b_[8] == END)
import hashlib
E0 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'   # 空文件
GOLD = {
    '好': {'main.fixups.tsv': '45cd4e5c7a8b4ffe2720a069e7232f93adb8f2dac012a667566f5725e8675f94', 'main.gaps.tsv': 'fbba2a91f6dfe794d7c09a3149a98d0de87d3c8564b5520b3c27690d6f096c82',
           'main.gates.tsv': E0, 'main.patched.bin': 'e3af535b5bacd2d70eef43a3917631e54fd7bb1d89fa6d838019fed230d0a500', 'main.sites.tsv': E0},
    # 坏行：0e53ad8b（v0.3.1 改写缺口降级继续）起缺口不再中止改写，照常出全部产物、这条不写（原先只出 gaps.tsv）；gaps.tsv 与旧金样相同
    '坏': {'main.fixups.tsv': '45cd4e5c7a8b4ffe2720a069e7232f93adb8f2dac012a667566f5725e8675f94', 'main.gaps.tsv': '51953caa18ffa10b638e63c8fc5a17422f0c6bc032a24f095a14fe986115bc2b',
           'main.gates.tsv': E0, 'main.patched.bin': '4e3a095bc6f3da55170146a5eb749df6ca51a2bddd69429dac136427a24a7624', 'main.sites.tsv': E0},
    '远': {'main.fixups.tsv': 'a00d579c6414a0bf3d3c3090a3abf2ae169361988a3828eb92c2569a0f03c558', 'main.gaps.tsv': 'fbba2a91f6dfe794d7c09a3149a98d0de87d3c8564b5520b3c27690d6f096c82',
           'main.gates.tsv': E0, 'main.patched.bin': 'e5c369ea4733d7045a988720b247f64e346164b2e53d7f3cd9f8479e0a5a3f6a', 'main.sites.tsv': E0},
}
# 远：p 点 0x100 的补丁指令是往回跳 128 MB 的 b，搬进近布局补丁区后够不着（超 ±128 MB）→ 双补丁岛：前岛在基址前 1 MB，跳回距离 0x7effef0 够得着
far = [('p', 0x100, words[0x100], b(0x100, 0x100 - 0x7fffff0), 0)]
for tag, rows_ in (('好', rows), ('坏', [('p', 0x108, 0xDEADBEEF, 0, 5)]), ('远', far)):
    out = T + f'/par_{tag}'; rc_, g_ = rew(rows_, out)
    if tag == '远':
        p2 = next((l.split('\t')[1].strip() for l in open(out + '/main.fixups.tsv') if l.startswith('# PATCH2_OFF\t')), None) if os.path.exists(out + '/main.fixups.tsv') else None
        ck(f'⑦ 远跳补丁由前岛接住：退出码 0、无缺口、PATCH2_OFF −0x102000（实得 {rc_} {p2}）', rc_ == 0 and 'cpatch' not in g_ and p2 == '-0x102000')
    if tag == '坏':   # 降级继续的语义：原字不符的这条不写，0x108 仍是原字（金样之外直接核，金样变了也能看出是不是写坏了）
        w108 = struct.unpack_from('<I', open(out + '/main.patched.bin', 'rb').read(), 0x108)[0]
        ck(f'⑤ 坏行退出码 3、缺口记 0x108、0x108 保持原字 {words[0x108]:#x}（实得 {rc_} {w108:#x}）', rc_ == 3 and 'cpatch' in g_ and w108 == words[0x108])
    got = {n: hashlib.sha256(open(f'{out}/{n}', 'rb').read()).hexdigest() for n in sorted(os.listdir(out))}
    diff = sorted(n for n in set(got) | set(GOLD[tag]) if got.get(n) != GOLD[tag].get(n))
    ck(f'⑤ {tag}行输出 {len(got)} 个文件 SHA-256 = 金样（不同 {diff}）', not diff)
sys.exit(bad)
EOF
rc=$?; [ $rc = 0 ] && echo "✅ cpatch_twopath_test 全过" || { echo "🔴 cpatch_twopath_test 有不通项"; exit 1; }
