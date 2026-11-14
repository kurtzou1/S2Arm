#!/bin/bash
# 门禁覆盖：pack/cpatch.py
# 自适应画幅出包单测（pack/cpatch.py adapt_families + plan，合成 NSO + 合成 6 种画幅的一族，约 3 秒）：bash tests/cpatch_adapt_test.sh
# 合成 main：代码段 [0, 0x4000)，0x100 mov w9,#0 / 0x104 nop / 0x108 ret，其余全 0；ro 0x4000、data 0x5000（0x5100 原值 0）。
# 一族（上游目录名带「宽-高」）：窄 1-1 / 5-4 / 3-2（A = 1、1.25、1.5），宽 2-1 / 5-2 / 3-1（A = 2、2.5、3）；每份写：
#   0x100 fmov s0,#A；0x104 b 0x200（挂钩）；0x200 adrp x0,0 / 0x204 ldr s<窄 2 · 宽 1>,[x0,#0x300] / 0x208 b 0x108（填充区补丁代码）；
#   0x300 浮点字面量（窄 (16/9)÷A、宽 A÷(16/9)）；0x5100 浮点 A（data）
# 期望（按编码规则手算，不跑被测实现）：
#   ① 合成成两份 wsauto:<族>:w（位 0）/ :n（位 1），各份数据写入 = 5100:00000000:@a4 k1016::@a4 k1017::@w4 k1018::@n4
#      （值槽按处理顺序：宽模板 fmov → 1016 = A；宽字面量 → 1017 = A÷(16/9)；窄字面量 → 1018 = (16/9)÷A）
#   ② 宽模板行：p 100 → ldr s0,[x16,#0x1fc0] = bd5fc200「@k」；p 104 → b 0x200 = 1400003f；w 200 adrp x0「@k」= 90000000；
#      w 204 ldr s1,[x0,#0x1fc8] = bd5fc801；w 208 b 0x108 = 17ffffc0（字面量 0x300 不写）
#   ③ 窄模板：0x204 与宽不同（ldr s2 读槽 1018 = bd5fd002）→ 整段填充区代码挪到第一个同 16 字节余数、没人用的零空隙 0x10：
#      w 10 90000000「@k」、w 14 bd5fd002、w 18 b 0x108 = 1400003c；挂钩 p 104 改指 0x10 = 17ffffc3；p 100 同宽（位 1）
#   ④ 族里只有两种画幅（不够多份对比）→ 单份参数化、宽 / 窄两侧分开（11-13）：宽侧 2:1（A = 2）0x100 fmov 2.0 落在 a 上 → 读槽 1016、数据 0x5100 → @a4；
#      窄侧 1:1 同样认出，但两份在填充区 0x204 写的新代码不同（读 s1 / s2，填充区常写、分不了路）→ 窄侧「不收 … 改同一处 main+0x204」，只进宽侧一份
#   ⑤ movz / movk 拼单精度的一族（11-13 荒野大镖客式；目录名用撇号 21'9、段名写 21:9）：0x110 movz w10,#lo / 0x114 movk w10,#hi 拼 A；
#      宽 21'9 / 32'9 / 43'18 三种、窄只有 16'10 一种（借宽侧认出的式 a，16:10 的值 1.6 也落在 a 上才收）。0x110 / 0x114 原是我方宽屏候选 asp 点，产物根没有我方宽屏表 → 让给补丁：
#      两份都是 p 110 5291c72a → ldr w10,[x16,#1016×8] = 0xB9400000 | 2032<<10 | 16<<5 | 10 = b95fc20a「@k」、p 114 72a7fc6a → nop d503201f；数据写入 k1016::@a4
#   ⑥ 同 ⑤ 但产物根有我方整套放宽表 widen_full.handheld.tsv → 两份照收、出表与 ⑤ 相同（11-13 补丁优先：社区宽屏类不让我方宽屏候选点，运行时我方满屏让位）
#   ⑧ 宽屏补丁写死的渲染尺寸（PC 模拟器用的 3440×1440）按手机口径缩成高 1080、宽等比；不超过 1080 的不动
#   ⑦ 定画幅变体（11-13 起单份参数化）：2:1、5:2 两份只改 main+0x100（fmov 立即数）与数据 0x5100，再加一份同 2:1 的别家（数据 1.75，不在画幅式上）：
#      三份都比 16:9 宽：宽侧代表挑最接近手机屏的 2:1（上游那家，排前），窄侧没有补丁 → 用它外推，宽 / 窄两份（位 0 / 1，第 11 列画幅空），
#      p 100 → ldr s0 读槽 1016 = bd5fc200；另两份「已覆盖」；有我方宽屏表时照收
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
"$PY" - "$H" "$T" <<'EOF'
import hashlib, os, shutil, struct, sys
H, T = sys.argv[1:]; sys.path.insert(0, H + '/pack'); import cpatch
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
code = [0x52800009, 0xD503201F, 0xD65F03C0]
TX = 0x4000
text = bytearray(TX); struct.pack_into('<II', text, 0, 0x14000040, TX); struct.pack_into('<3I', text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (TX + EF) - (TX + EH + 4), 1, 0x100 - (TX + EH), (TX + EF + 0x18) - (TX + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = TX + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (TX + EF), 0x100 - (f + 8), 4 * len(code))
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (TX, ro), (TX + 0x1000, bytes(0x1000)))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + mo, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
BID = 'AABBCCDD00112233445566778899AABB'; h[0x40:0x50] = bytes.fromhex(BID)
root = T + '/root'; os.makedirs(root + '/exefs')
open(root + '/exefs/main', 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(0x1000))
npdm = bytearray(0x200); npdm[:4] = b'META'; struct.pack_into('<I', npdm, 0x70, 0x100); npdm[0x100:0x104] = b'ACI0'; struct.pack_into('<Q', npdm, 0x110, 0x0100A3501946E000)
open(root + '/exefs/main.npdm', 'wb').write(bytes(npdm))
open(root + '/widen_sites.tsv', 'w').write('模块\t偏移\t种类\t证据\n')
R = 16 / 9
FMOV = {1.0: 0x1E2E1000, 1.25: 0x1E2E9000, 1.5: 0x1E2F1000, 2.0: 0x1E201000, 2.5: 0x1E209000, 3.0: 0x1E211000}   # imm8 手算：1.0 = 0x70、1.25 = 0x74、1.5 = 0x78、2.0 = 0x00、2.5 = 0x04、3.0 = 0x08
def fam(idx, aspects):
    os.makedirs(idx); rows = ['game\ttitle_id\tpath\ttype\tsource\tlicense\tin_pack\tsha256\taspect\torigin']
    for i, (w, hh) in enumerate(aspects):
        A = w / hh; wide = A > R
        lit = struct.unpack('<I', struct.pack('<f', A / R if wide else R / A))[0]
        ldr = 0xBD430001 if wide else 0xBD430002   # ldr s1 / s2, [x0, #0x300]
        body = (f'@nsobid-{BID}\n@flag offset_shift 0x100\n@enabled\n'
                f'00000100 {FMOV[A].to_bytes(4, "little").hex().upper()}\n00000104 {(0x1400003F).to_bytes(4, "little").hex().upper()}\n'
                f'00000200 {(0x90000000).to_bytes(4, "little").hex().upper()}\n00000204 {ldr.to_bytes(4, "little").hex().upper()}\n'
                f'00000208 {(0x17FFFFC0).to_bytes(4, "little").hex().upper()}\n00000300 {lit.to_bytes(4, "little").hex().upper()}\n'
                f'00005100 {struct.pack("<f", A).hex().upper()}\n@stop\n')
        os.makedirs(f'{idx}/f/{i}'); open(f'{idx}/f/{i}/main.pchtxt', 'w').write(body)
        rows.append(f'\t0100A3501946E000\tf/{i}/main.pchtxt\tpchtxt\to/r\tMIT\tyes\t\t\to/r/mods/Wide {w}-{hh} Mod/exefs/main.pchtxt')
    open(idx + '/INDEX.tsv', 'w').write('\n'.join(rows) + '\n')
idx = T + '/widescreen'; fam(idx, [(1, 1), (5, 4), (3, 2), (2, 1), (5, 2), (3, 1)])
rc = cpatch.plan(root, '', [idx])
tsv = [l.split('\t') for l in open(root + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]]
fid = hashlib.sha256('o/r/mods/Wide {A} Mod/exefs/main.pchtxt'.encode()).hexdigest()[:12]
spec = '5100:00000000:@a4 k1016::@a4 k1017::@w4 k1018::@n4'
got = sorted((c[0], c[2], c[7]) for c in tsv)
ck(f'① 合成两份、位 0 / 1、数据写入带画幅式（实得 {got}）', rc == 0 and got == [(f'wsauto:{fid}:n', '1', spec), (f'wsauto:{fid}:w', '0', spec)])
rows = {tuple(l.split('\t# ')[0].split('\t')) for l in open(root + '/cpatch_rows.tsv').read().splitlines()}
W = {('p', 'main', '100', '52800009', 'bd5fc200', '0', '@k'), ('p', 'main', '104', 'd503201f', '1400003f', '0'),
     ('w', 'main', '200', '00000000', '90000000', '@k'), ('w', 'main', '204', '00000000', 'bd5fc801'), ('w', 'main', '208', '00000000', '17ffffc0')}
N = {('p', 'main', '100', '52800009', 'bd5fc200', '1', '@k'), ('p', 'main', '104', 'd503201f', '17ffffc3', '1'),
     ('w', 'main', '10', '00000000', '90000000', '@k'), ('w', 'main', '14', '00000000', 'bd5fd002'), ('w', 'main', '18', '00000000', '1400003c')}
ck(f'② 宽模板行（多 {sorted(W - rows)}）', W <= rows)
ck(f'③ 窄模板挪到 0x10、挂钩改指（缺 {sorted(N - rows)}；表里多出 {sorted(rows - W - N)}）', N <= rows and rows == W | N)
r4 = T + '/root4'; shutil.copytree(root, r4, ignore=shutil.ignore_patterns('cpatch*'))
idx4 = T + '/two/widescreen'; fam(idx4, [(1, 1), (2, 1)])
cpatch.plan(r4, '', [idx4])
t4 = sorted((c[0].split(':')[0], c[0].rsplit(':', 1)[1], c[2], c[7]) for c in (l.split('\t') for l in open(r4 + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]))
rej4 = sum(l.startswith('不收\twsauto:') and l.split('\t')[1].endswith(':n') and '改同一处 main+0x204' in l for l in open(r4 + '/cpatch_plan.log', encoding='utf-8'))
ck(f'④ 只有两种画幅：宽 / 窄分开单份参数化，窄侧因填充区新代码不同落选（实得 {t4}、窄侧落选 {rej4}）',
   t4 == [('wsauto', 'w', '0', '5100:00000000:@a4 k1016::@a4')] and rej4 == 1)
r5 = T + '/root5'; shutil.copytree(root, r5, ignore=shutil.ignore_patterns('cpatch*'))
mb = bytearray(open(r5 + '/exefs/main', 'rb').read()); struct.pack_into('<II', mb, 0x100 + 0x110, 0x5291C72A, 0x72A7FC6A); open(r5 + '/exefs/main', 'wb').write(bytes(mb))
open(r5 + '/widen_sites.tsv', 'w').write('模块\t偏移\t种类\t证据\nmain\t0x110\tasp\t5291c72a 72a7fc6a\n')
def fam5(idx):
    os.makedirs(idx); rows = ['game\ttitle_id\tpath\ttype\tsource\tlicense\tin_pack\tsha256\taspect\torigin']
    for i, (w, hh) in enumerate([(21, 9), (32, 9), (43, 18), (16, 10)]):
        u = struct.unpack('<I', struct.pack('<f', w / hh))[0]
        mz, mk = 0x5280000A | ((u & 0xFFFF) << 5), 0x72A0000A | ((u >> 16) << 5)
        body = (f'@nsobid-{BID}\n@flag offset_shift 0x100\n// {w}:{hh} Aspect Ratio\n@enabled\n'
                f'00000110 {mz.to_bytes(4, "little").hex().upper()}\n00000114 {mk.to_bytes(4, "little").hex().upper()}\n@stop\n')
        os.makedirs(f'{idx}/f/{i}'); open(f'{idx}/f/{i}/1.0.4.pchtxt', 'w').write(body)
        rows.append(f"\t0100A3501946E000\tf/{i}/1.0.4.pchtxt\tpchtxt\to/r\tMIT\tyes\t\t\to/r/Aspect Ratio/{w}'{hh}/exefs/1.0.4.pchtxt")
    open(idx + '/INDEX.tsv', 'w').write('\n'.join(rows) + '\n')
idx5 = T + '/five/widescreen'; fam5(idx5); cpatch.plan(r5, '', [idx5])
fid5 = hashlib.sha256('o/r/Aspect Ratio/{A}/exefs/1.0.4.pchtxt'.encode()).hexdigest()[:12]
got5 = sorted((c[0], c[2], c[7]) for c in (l.split('\t') for l in open(r5 + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]))
rows5 = {tuple(l.split('\t# ')[0].split('\t')) for l in open(r5 + '/cpatch_rows.tsv').read().splitlines()}
want5 = {('p', 'main', '110', '5291c72a', 'b95fc20a', b, '@k') for b in '01'} | {('p', 'main', '114', '72a7fc6a', 'd503201f', b) for b in '01'}
ck(f'⑤ movz / movk 一族、窄侧单画幅借式、候选点让给补丁（实得 {got5}；行多 {sorted(rows5 - want5)} 缺 {sorted(want5 - rows5)}）',
   got5 == [(f'wsauto:{fid5}:n', '1', 'k1016::@a4'), (f'wsauto:{fid5}:w', '0', 'k1016::@a4')] and rows5 == want5)
r6 = T + '/root6'; shutil.copytree(r5, r6, ignore=shutil.ignore_patterns('cpatch*')); open(r6 + '/widen_full.handheld.tsv', 'w').write('1\n')
cpatch.plan(r6, '', [idx5])
n6 = len(open(r6 + '/cpatch.tsv', encoding='utf-8').read().splitlines()) - 1
rej6 = sum('改到我方改写点' in l for l in open(r6 + '/cpatch_plan.log', encoding='utf-8'))
ck(f'⑥ 有我方整套放宽表：两份照收（补丁优先；实得 进包 {n6}、改到我方改写点 {rej6}）', n6 == 2 and rej6 == 0 and open(r6 + '/cpatch_rows.tsv').read() == open(r5 + '/cpatch_rows.tsv').read())
r7 = T + '/root7'; shutil.copytree(root, r7, ignore=shutil.ignore_patterns('cpatch*')); open(r7 + '/widen_full.handheld.tsv', 'w').write('1\n')
open(r7 + '/widen_sites.tsv', 'a').write('main\t0x100\tmovz\t52800009\n')   # 我方宽屏候选点正落在补丁改的 0x100
idx7 = T + '/seven/widescreen'; os.makedirs(idx7); rows7 = ['game\ttitle_id\tpath\ttype\tsource\tlicense\tin_pack\tsha256\taspect\torigin']
for i, (A, val, org) in enumerate([(2.0, 2.0, 'o/r/[2560x1280 2.1 v1]/exefs/main.pchtxt'), (2.5, 2.5, 'o/r/[3200x1280 5.2 v1]/exefs/main.pchtxt'), (2.0, 1.75, 'p/q/[2:1 alt]/exefs/main.pchtxt')]):
    body = (f'@nsobid-{BID}\n@flag offset_shift 0x100\n@enabled\n00000100 {FMOV[A].to_bytes(4, "little").hex().upper()}\n'
            f'00005100 {struct.pack("<f", val).hex().upper()}\n@stop\n')
    os.makedirs(f'{idx7}/f/{i}'); open(f'{idx7}/f/{i}/main.pchtxt', 'w').write(body)
    rows7.append(f'\t0100A3501946E000\tf/{i}/main.pchtxt\tpchtxt\to/r\tMIT\tyes\t\t{"2:1" if A == 2.0 else "5:2"}\t{org}')
open(idx7 + '/INDEX.tsv', 'w').write('\n'.join(rows7) + '\n')
cpatch.plan(r7, '', [idx7])
t7 = sorted((c[2], c[10]) for c in (l.split('\t') for l in open(r7 + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]))
p7 = sorted((c[2], c[4], c[5]) for c in (l.split('\t# ')[0].split('\t') for l in open(r7 + '/cpatch_rows.tsv').read().splitlines()) if c[0] == 'p')
same7 = sum('同画幅' in l for l in open(r7 + '/cpatch_plan.log', encoding='utf-8'))
cov7 = sum(l.startswith('已覆盖') for l in open(r7 + '/cpatch_plan.log', encoding='utf-8'))
ck(f'⑦ 定画幅变体单份参数化、其余已覆盖、有我方宽屏表照收（实得 表 {t7}、p 行 {p7}、已覆盖 {cov7}）',
   t7 == [('0', ''), ('1', '')] and p7 == [('100', 'bd5fc200', '0'), ('100', 'bd5fc200', '1')] and cov7 == 2)
# ⑧ 宽屏补丁的渲染尺寸按手机口径（11-13）：MOVZ X8,#3440 / MOVK X8,#1440,LSL#32 落在宽屏点 movz / i2h → 高 1080、宽 3440×1080/1440 = 2580；
#    1280×800（不超过 1080）不动；落在别的种类（asp）或不是宽屏点的不动
def mz(imm, hw=0, k=0): return bytearray((((0xD2800000 if not k else 0xF2800000) | (hw << 21) | (imm << 5) | 8)).to_bytes(4, 'little'))
w8 = {0x10: mz(3440), 0x18: mz(1440, 2, 1), 0x20: mz(3440)}; r8 = cpatch.phone_res(w8, {0x10: 'movz', 0x18: 'i2h', 0x20: 'asp'})
g8 = [(int.from_bytes(w8[o], 'little') >> 5) & 0xFFFF for o in (0x10, 0x18, 0x20)]
w8b = {0x10: mz(1280), 0x18: mz(800, 2, 1)}; r8b = cpatch.phone_res(w8b, {0x10: 'movz', 0x18: 'i2h'})
ck(f'⑧ 渲染尺寸按手机口径（实得 {g8}、{r8!r}；1280×800 → {r8b!r}）', g8 == [2580, 1080, 3440] and r8 == '3440×1440 → 2580×1080' and r8b == '')
# ⑨ 目录名只写分辨率的一族（11-13 超宽屏补丁库式：[1680x1050 …] / [3440x1440 21.9 Ultrawide …]，各份注释不同）：
#    原代码 0x120 movz x8,#1280 / 0x124 movk x8,#720,lsl 32（渲染尺寸）/ 0x128 movz w19,#0x1740,lsl 16（显存上限）；data 0x5100 浮点画幅。
#    四份：1680×1050（A 1.6，显存 0x3800）、3440×1440（2.389，0x3800）、5160×2160（同 2.389，0x4000）、5120×1440（3.556，0x4000）
#    期望（手算）：同画幅留像素少的 3440×1440 → 3 种画幅合成，族号 = sha256('o/r/m.zip/{A}/exefs/main.pchtxt')[:12]；
#      0x120 → ldr w8,[x16,#1016×8] = 0xB9400000 | 2032<<10 | 16<<5 | 8 = b95fc208「@k」，槽 1016 = @x4（运行时 1080 × 画幅取偶）；
#      0x124 → movk x8,#1080,lsl 32 = 0xF2C00008 | 1080<<5 = f2c08708；0x128 → 各份最常见的一档（0x3800 与 0x4000 各两份，平手取小）movz w19,#0x3800,lsl 16 = 0x52A00013 | 0x3800<<5 = 52a70013；
#      数据 5100:00000000:@a4；同画幅落下的 5160×2160 不单独进包（族已覆盖）
#    另一档（11-13）：原代码 0x12c movz x9,#1024 / 0x130 movk x9,#576,lsl 32（补丁没改，同 16:9、是主机档的 0.8 倍 = 掌机档）→ 补齐：
#      0x12c → ldr w9,[x16,#1017×8] = 0xB9400000 | 2034<<10 | 16<<5 | 9 = b95fca09「@k」，槽 1017 = @y4/864（高 1080 × 0.8 = 864）；0x130 → movk x9,#864,lsl 32 = f2c06c09；
#      第 12 列模式 both
r9 = T + '/root9'; shutil.copytree(root, r9, ignore=shutil.ignore_patterns('cpatch*'))
mb = bytearray(open(r9 + '/exefs/main', 'rb').read())
struct.pack_into('<IIIII', mb, 0x100 + 0x120, 0xD2800008 | (1280 << 5), 0xF2C00008 | (720 << 5), 0x52A00013 | (0x1740 << 5), 0xD2800009 | (1024 << 5), 0xF2C00009 | (576 << 5)); open(r9 + '/exefs/main', 'wb').write(bytes(mb))
idx9 = T + '/nine/widescreen'; os.makedirs(idx9); rows9 = ['game\ttitle_id\tpath\ttype\tsource\tlicense\tin_pack\tsha256\taspect\torigin']
for i, (w, hh, mem, tag) in enumerate([(1680, 1050, 0x3800, '16.10'), (3440, 1440, 0x3800, '21.9 Ultrawide'), (5160, 2160, 0x4000, '21.9 Ultrawide'), (5120, 1440, 0x4000, '32.9 Ultrawide')]):
    ws = [0xD2800008 | (w << 5), 0xF2C00008 | (hh << 5), 0x52A00013 | (mem << 5)]
    body = (f'@nsobid-{BID}\n@flag offset_shift 0x100\n// HUD note {i}\n@enabled\n' + ''.join(f'{0x120 + 4 * k:08X} {x.to_bytes(4, "little").hex().upper()}\n' for k, x in enumerate(ws)) +
            f'00005100 {struct.pack("<f", w / hh).hex().upper()}\n@stop\n')
    os.makedirs(f'{idx9}/f/{i}'); open(f'{idx9}/f/{i}/main.pchtxt', 'w').write(body)
    rows9.append(f'\t0100A3501946E000\tf/{i}/main.pchtxt\tpchtxt\to/r\tMIT\tyes\t\t\to/r/m.zip/[{w}x{hh} {tag} v1]/exefs/main.pchtxt')
open(idx9 + '/INDEX.tsv', 'w').write('\n'.join(rows9) + '\n')
cpatch.plan(r9, '', [idx9])
fid9 = hashlib.sha256('o/r/m.zip/{A}/exefs/main.pchtxt'.encode()).hexdigest()[:12]
t9 = sorted((c[0], c[2], c[7], c[11]) for c in (l.split('\t') for l in open(r9 + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]))
rows9 = {tuple(l.split('\t# ')[0].split('\t')) for l in open(r9 + '/cpatch_rows.tsv').read().splitlines()}
o120, o124, o128 = (f'{x:08x}' for x in (0xD2800008 | (1280 << 5), 0xF2C00008 | (720 << 5), 0x52A00013 | (0x1740 << 5)))
o12c, o130 = (f'{x:08x}' for x in (0xD2800009 | (1024 << 5), 0xF2C00009 | (576 << 5)))
want9 = {r for b in '01' for r in (('p', 'main', '120', o120, 'b95fc208', b, '@k'), ('p', 'main', '124', o124, 'f2c08708', b), ('p', 'main', '128', o128, '52a70013', b),
                                   ('p', 'main', '12c', o12c, 'b95fca09', b, '@k'), ('p', 'main', '130', o130, 'f2c06c09', b))}
ck(f'⑨ 分辨率目录一族：同画幅去重、渲染宽读槽 @x4、高写 1080、显存取最接近原值、补齐另一档 @y4/864（实得 {t9}；行多 {sorted(rows9 - want9)} 缺 {sorted(want9 - rows9)}）',
   t9 == [(f'wsauto:{fid9}:n', '1', '5100:00000000:@a4 k1016::@x4 k1017::@y4/864', 'both'), (f'wsauto:{fid9}:w', '0', '5100:00000000:@a4 k1016::@x4 k1017::@y4/864', 'both')] and rows9 == want9)
# ⑩ 金手指原文随包（11-13：iPhone 金手指页只读文档根 cheats/*.txt，原文得跟包走）：S2A_CHEATS_DIRS 里两份——
#    AABBCCDD00112233.txt（文件名 = 主程序构建号前 16 位，对得上）与 1111222233334444.txt（对不上）；期望产物根只有 cheat-src.AABBCCDD00112233.txt、与原文逐字节相同，
#    重跑时上一次的随包原文先清掉（目录换成只有对不上那份 → 产物根一个也不剩）
r10 = T + '/root10'; shutil.copytree(root, r10, ignore=shutil.ignore_patterns('cpatch*')); cd10 = T + '/cheats10'; os.makedirs(cd10)
good = b'[X]\n04000000 00005000 00000001\n'; open(cd10 + '/AABBCCDD00112233.txt', 'wb').write(good); open(cd10 + '/1111222233334444.txt', 'wb').write(good)
os.environ['S2A_CHEATS_DIRS'] = cd10; cpatch.plan(r10, '', [])
sh10 = sorted(f for f in os.listdir(r10) if f.startswith('cheat-src.')); same10 = sh10 and open(r10 + '/' + sh10[0], 'rb').read() == good
os.remove(cd10 + '/AABBCCDD00112233.txt'); cpatch.plan(r10, '', []); left10 = [f for f in os.listdir(r10) if f.startswith('cheat-src.')]
del os.environ['S2A_CHEATS_DIRS']
ck(f'⑩ 金手指原文随包：版本对的那份照原文进产物根、对不上的不带、重跑先清（实得 {sh10}、原文一致 {bool(same10)}、重跑后剩 {left10}）',
   sh10 == ['cheat-src.AABBCCDD00112233.txt'] and same10 and left10 == [])
# ⑪ 跨版本移植（11-13，只做画幅）：主程序构建号 AABB…，补丁库里只有别的版本（1111…）的一份 21:9：0x100 fmov s0,#2.375（= 0x1E207000，imm8 0x03）、数据 0x5100 = 2.3333。
#    新版程序里那条挪到 0x140、原值 fmov s0,#1.75（16:9 那档，imm8 0x7C → 0x1E2F9000）；数据挪到 0x5180、原值 1.7778。
#    期望（手算）：移植成 0x140 / 0x5180（log「移植」），再单份参数化（宽侧 21:9，窄侧外推）→ p 140 1e2f9000 → ldr s0,[x16,#1016×8] = bd5fc200「@k」，数据 5180:<1.7778 原字节>:@a4 k1016::@a4
r11 = T + '/root11'; shutil.copytree(root, r11, ignore=shutil.ignore_patterns('cpatch*'))
mb = bytearray(open(r11 + '/exefs/main', 'rb').read()); struct.pack_into('<I', mb, 0x100 + 0x140, 0x1E2F9000)
d0 = 0x100 + TX + 0x1000; struct.pack_into('<f', mb, d0 + 0x180, 16 / 9); open(r11 + '/exefs/main', 'wb').write(bytes(mb))
idx11 = T + '/eleven/widescreen'; os.makedirs(idx11 + '/f/0')
OLD = '11112222333344445555666677778888'
open(idx11 + '/f/0/main.pchtxt', 'w').write(f'@nsobid-{OLD}\n@flag offset_shift 0x100\n@enabled\n00000100 {(0x1E207000).to_bytes(4, "little").hex().upper()}\n'
                                         f'00005100 {struct.pack("<f", 21 / 9).hex().upper()}\n@stop\n')
open(idx11 + '/INDEX.tsv', 'w').write('game\ttitle_id\tpath\ttype\tsource\tlicense\tin_pack\tsha256\taspect\torigin\n'
                                       '\t0100A3501946E000\tf/0/main.pchtxt\tpchtxt\to/r\tMIT\tyes\t\t21:9\to/r/old/[21:9]/exefs/main.pchtxt\n')
cpatch.plan(r11, '', [idx11])
t11 = sorted((c[0].split(':')[0], c[2], c[7]) for c in (l.split('\t') for l in open(r11 + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]))
rows11 = {tuple(l.split('\t# ')[0].split('\t')) for l in open(r11 + '/cpatch_rows.tsv').read().splitlines()}
mig11 = sum(l.startswith('移植\t') for l in open(r11 + '/cpatch_plan.log', encoding='utf-8'))
spec11 = '5180:' + struct.pack('<f', 16 / 9).hex() + ':@a4 k1016::@a4'
want11 = {('p', 'main', '140', '1e2f9000', 'bd5fc200', b, '@k') for b in '01'}
ck(f'⑪ 跨版本移植：别的版本的 21:9 移到新版对应处再参数化（实得 {t11}、行 {sorted(rows11)}、移植 {mig11}）',
   t11 == [('wsauto', '0', spec11), ('wsauto', '1', spec11)] and rows11 == want11 and mig11 == 1)
# ⑫ 拼单精度的 movz + movk 不算渲染尺寸（11-13 体检误判）：movz w9,#0x5555 / movk w9,#0x4015,lsl 16（宽 ÷ 高 = 1.3316 ≈ 4:3）在 A = 4/3 下
#    期望：渲染尺寸对为空；真正的一对 movz x8,#1440 / movk x8,#1080,lsl 32（4:3）照认
w12 = [(0x200, (0x52800009 | (0x5555 << 5)).to_bytes(4, 'little') + (0x72A00009 | (0x4015 << 5)).to_bytes(4, 'little')),
       (0x300, (0xD2800008 | (1440 << 5)).to_bytes(4, 'little') + (0xF2C00008 | (1080 << 5)).to_bytes(4, 'little'))]
_, res12, _ = cpatch.aspect_classify(w12, 4 / 3)
ck(f'⑫ 拼单精度的一对不算渲染尺寸（实得 {res12}）', res12 == [(0x300, 0x304, 1440, 1080)])
# ⑬ 自相矛盾的补丁不收（11-13）：一份目录名写 3:2 的补丁，0x100 fmov s0,#2.375（21:9 那档）、0x110 / 0x114 movz / movk 拼 1.5（3:2）
#    （目录名同真实那家：「[3:2 WIP from 3440x1440]」，候选画幅 2.389 / 1.5）期望：各处画幅值指向不同画幅 → 进包 0 份、log「可疑不收」1 行
r13 = T + '/root13'; shutil.copytree(root, r13, ignore=shutil.ignore_patterns('cpatch*'))
idx13 = T + '/thirteen/widescreen'; os.makedirs(idx13 + '/f/0'); u = struct.unpack('<I', struct.pack('<f', 1.5))[0]
open(idx13 + '/f/0/main.pchtxt', 'w').write(f'@nsobid-{BID}\n@flag offset_shift 0x100\n@enabled\n00000100 {(0x1E207000).to_bytes(4, "little").hex().upper()}\n'
    f'00000110 {(0x5280000A | ((u & 0xFFFF) << 5)).to_bytes(4, "little").hex().upper()}\n00000114 {(0x72A0000A | ((u >> 16) << 5)).to_bytes(4, "little").hex().upper()}\n@stop\n')
open(idx13 + '/INDEX.tsv', 'w').write('game\ttitle_id\tpath\ttype\tsource\tlicense\tin_pack\tsha256\taspect\torigin\n'
                                       '\t0100A3501946E000\tf/0/main.pchtxt\tpchtxt\to/r\tMIT\tyes\t\t\to/r/gen/[3:2 WIP from 3440x1440]/exefs/main.pchtxt\n')
cpatch.plan(r13, '', [idx13])
n13 = len(open(r13 + '/cpatch.tsv', encoding='utf-8').read().splitlines()) - 1
sus13 = sum(l.startswith('可疑不收') for l in open(r13 + '/cpatch_plan.log', encoding='utf-8'))
ck(f'⑬ 画幅值自相矛盾的补丁不收（实得 进包 {n13}、可疑 {sus13}）', n13 == 0 and sus13 == 1)
# ⑭ 金手指偏移寄存器（11-13 实测漏收）：同一份里 [A] 04070000 00000100 52800120（R=7 写主程序代码）、[B] 040F0000 00000104 D503201F（R=F）、
#    [C] 580F0000 00005000 / 780F0000 00000010 / 640F0000 00000000 00000001（指针链，写 RF）。期望：R7 没有任何指令写 → A 编进包（0x100 写 20 01 80 52）；
#    RF 被 C 的 58 / 78 写 → B 交运行时（writes None）；C 本身有别的类型 → None。再加一条 [D] 30070000 00000002 / 31070000（循环用 R7）后 A 也交运行时
t14 = '[A]\n04070000 00000100 52800120\n\n[B]\n040F0000 00000104 D503201F\n\n[C]\n580F0000 00005000\n780F0000 00000010\n640F0000 00000000 00000001\n'
e14 = {e['name']: e['writes'] for e in cpatch.parse_cheats(t14)[1]}
e14b = {e['name']: e['writes'] for e in cpatch.parse_cheats(t14 + '\n[D]\n30070000 00000002\n31070000\n')[1]}
ck(f'⑭ 金手指偏移寄存器：文件里没人写的 R 当 0 编进包、有人写的交运行时（实得 {e14}；加循环后 A = {e14b.get("A")}）',
   e14 == {'A': [(0x100, bytes.fromhex('20018052'))], 'B': None, 'C': None} and e14b.get('A') is None)
# ⑮ 金手指同文件同处代码的几档（11-13 实测「x3」被当成与「x2」冲突落选）：合成 main 0x100 原字 mov w9,#0 = 52800009；
#    AABBCCDD00112233.txt：[x2] 写 0x100 = mov w9,#2（52800049），[x3] 写 0x100 = mov w9,#3（52800069）。期望（手算）：两条都进 cpatch.tsv、位各自不同（x2 位 0、x3 位 1，按条目顺序分位）；
#    cpatch_rows.tsv 同点各一行 p、后面的条目在前（几档同开时后写的生效，跳板先测到的生效）。另一份文件（文件名排后）[x5] 写 528000A9 也并存（位 2，行最前）；
#    [x1] 写的就是原字 52800009（「改回原样」那档）：登记进表、位「-」、不出行（运行时按编进包处理，不再标「改代码，不支持」）
r15 = T + '/root15'; shutil.copytree(root, r15, ignore=shutil.ignore_patterns('cpatch*', 'cheat-src*')); cd15 = T + '/cheats15'; os.makedirs(cd15)
open(cd15 + '/AABBCCDD00112233.txt', 'w').write('[x2]\n04000000 00000100 52800049\n\n[x3]\n04000000 00000100 52800069\n\n[x1]\n04000000 00000100 52800009\n')
open(cd15 + '/AABBCCDD00112233.zz.txt', 'w').write('[AABB BID=AABBCCDD00112233]\n[x5]\n04000000 00000100 528000A9\n')
os.environ['S2A_CHEATS_DIRS'] = cd15; cpatch.plan(r15, '', []); del os.environ['S2A_CHEATS_DIRS']
t15 = [(c[4], c[2]) for c in (l.split('\t') for l in open(r15 + '/cpatch.tsv', encoding='utf-8').read().splitlines()[1:]) if c[0].startswith('cheat:')]
p15 = [tuple(l.split('\t# ')[0].split('\t')) for l in open(r15 + '/cpatch_rows.tsv').read().splitlines() if l.startswith('p\t')]
ck(f'⑮ 金手指同处几档（含别的文件）并存、后写的在前（实得 表 {t15}、行 {p15}）',
   t15 == [('x2', '0'), ('x3', '1'), ('x1', '-'), ('x5', '2')] and p15 == [('p', 'main', '100', '52800009', '528000a9', '2'), ('p', 'main', '100', '52800009', '52800069', '1'), ('p', 'main', '100', '52800009', '52800049', '0')])
sys.exit(bad)
EOF
rc=$?; [ $rc = 0 ] && echo "✅ cpatch_adapt_test 全过" || { echo "🔴 cpatch_adapt_test 有不通项"; exit 1; }
