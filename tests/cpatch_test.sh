#!/bin/bash
# 社区补丁应用层·出包期单测（pack/cpatch.py，合成 NSO + 合成补丁，约 5 秒）：bash tests/cpatch_test.sh
# 期望全部手算，不跑被测实现：
#   ① pchtxt 解析：带 @flag offset_shift 0x100 的偏移就是映像偏移；不带的减 0x100；@disabled 段不收；字符串行 / 模板占位的段标 bad
#   ①b 规范语义：@stop 整个文件停、offset_shift 任意整数按行生效、空行结束段
#   ② IPS：PATCH 头、普通记录 + 行程记录（大小 0 → 2 字节次数 + 1 字节值）、EOF；IPS32：4 字节偏移、EEOF；偏移含 0x100 文件头
#   ③ scan：程序号前 13 位与构建号（去尾部 0 字节后作前缀）都对上才收；别的程序号、别的构建号不收；编号 = 内容 SHA-256 前 16 位，索引列与内容不符、路径逃出索引目录、IPS 缺结束标记整份不收（审计 #829）
#   ④ plan：合成 main（代码段 0x100 起 mov w0,#1 / mov x0,x18 / ret，0x200 起全 0 填充，ro 段 0x1000 起）；补丁（同程序号同构建号）：
#      A 0x100 → nop（有效指令）→ p 行 位 0；B 0x200 → nop（原字全 0）→ w 行；C2 0x4800（data 段）→ 数据写入 4800:00000000:aabbccdd、位 2（位按索引顺序分：A 0、B 1、C2 2）；
#      F 0x3800（ro 段，但在代码段末页 [0x3000, 0x4000) 里：代码段 0x3000 向上取整到 16 KB）→ 不收；
#      D 0x100 → mov w0,#9（与 A 同处不同值）→ 不收；E 0x104（产物根 main.sites.tsv 登记的改写点）→ 不收
#   ⑤ prune：main.gaps.tsv 有一条 0x100 cpatch 缺口 → 退出码 10、A 进 cpatch_excluded.tsv；重跑 plan → A 不在、D2 轮上（p 行 0x100 新字 0x52800120、位 2：A 出局后 B 0、C2 1、D2 2）
#   ⑥ 多 @nsobid 块各自绑定构建号与 offset_shift；真实 scan 只匹配目标块、缺构建号及非法段不收
#   ⑧ 抢同一处按目标选（11-01）：60 / 120 帧两档都收（11-13）、60 帧优先于取不到帧数；同 60 帧不缺 romfs 参数表优先；IPS 与写入相同的 pchtxt 共用参数表结论；平手按原顺序（细节见 ⑧ 段）
#   ⑦ 数据流旁路（11-01 动森 fps:370eb70 定因）：补丁设又读的寄存器，原版有 cbz / 跳转表从区间外跳进两者之间 → 不收；跳到用之后、读原代码设的寄存器、表项在区间外 → 收（细节见 ⑦ 段）
# 旧代码反证：本单测随 pack/cpatch.py 首次加入（之前没有补丁应用层，pack/cpatch.py 不存在 → 全红）；④⑤ 的 plan / prune 在 10-27 双路改版时替换「叠加安全」check / apply
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
"$PY" - "$H" "$T" <<'EOF' || bad=1
import os, shutil, struct, subprocess, sys
H, T = sys.argv[1:]; sys.path.insert(0, H + '/pack'); import cpatch
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
# ① pchtxt
t = """@nsobid-AABBCCDD00112233445566778899AABB
@flag offset_shift 0x100
@enabled
00000104 1F2003D5
@disabled
00000108 C0035FD6
// 字符串
@enabled
00000110 "abc"
@enabled
00000120 {hex1}
@stop
"""
bid, secs = cpatch.parse_pchtxt(t)
ck(f'① 构建号 {bid}', bid == 'AABBCCDD00112233445566778899AABB')
ck('① 带 offset_shift：0x104 映像偏移、字节 1F2003D5', secs[0]['enabled'] and secs[0]['writes'] == [(0x104, bytes.fromhex('1F2003D5'))] and not secs[0]['bad'])
ck('① @disabled 段标关', not secs[1]['enabled'])
ck('① 字符串行、模板占位的段标 bad', bool(secs[2]['bad']) and bool(secs[3]['bad']))
_, s2 = cpatch.parse_pchtxt('@nsobid-AA\n@enabled\n00000204 00000000\n@stop\n')
ck('① 不带 offset_shift：文件偏移 0x204 → 映像 0x104', s2[0]['writes'] == [(0x104, bytes(4))])
# ①b IPSwitch 规范 / Ryujinx 语义（11-02 根修三处出入），期望手算：映像偏移 = 行首偏移 + offset_shift − 0x100
#   @stop 之后整个文件不再解析：之后的 @enabled 段不收（原先会重新开段）
_, s3 = cpatch.parse_pchtxt('@nsobid-AA\n@flag offset_shift 0x100\n@enabled\n00000104 00000000\n@stop\n@enabled\n00000200 11111111\n')
ck('①b @stop 后的 @enabled 段不收（只剩 1 段、写入 0x104）', len(s3) == 1 and s3[0]['writes'] == [(0x104, bytes(4))])
#   offset_shift 任意整数、按行生效：0x80 时 0x184 + 0x80 − 0x100 = 0x104；中途改成 -0x10 后 0x214 − 0x10 − 0x100 = 0x104
_, s4 = cpatch.parse_pchtxt('@nsobid-AA\n@enabled\n@flag offset_shift 0x80\n00000184 01020304\n@flag offset_shift -0x10\n00000214 05060708\n')
ck('①b offset_shift 0x80 与中途 -0x10 都按行生效', s4[0]['writes'] == [(0x104, bytes.fromhex('01020304')), (0x104, bytes.fromhex('05060708'))] and not s4[0]['bad'])
#   空行结束当前段：空行后的字节行没有段，不收
_, s5 = cpatch.parse_pchtxt('@nsobid-AA\n@enabled\n00000204 00000000\n\n00000208 FFFFFFFF\n')
ck('①b 空行结束段：只收空行前的 0x104', len(s5) == 1 and s5[0]['writes'] == [(0x104, bytes(4))])
# ②
ips = b'PATCH' + (0x204).to_bytes(3, 'big') + (4).to_bytes(2, 'big') + bytes.fromhex('1F2003D5') + (0x300).to_bytes(3, 'big') + (0).to_bytes(2, 'big') + (3).to_bytes(2, 'big') + b'\xaa' + b'EOF'
ck('② IPS：0x204 → 0x104、行程 0x300 → 0x200 三个 AA', cpatch.parse_ips(ips) == [(0x104, bytes.fromhex('1F2003D5')), (0x200, b'\xaa\xaa\xaa')])
ips32 = b'IPS32' + (0x1000204).to_bytes(4, 'big') + (2).to_bytes(2, 'big') + b'\x01\x02' + b'EEOF'
ck('② IPS32：4 字节偏移 0x1000204 → 0x1000104', cpatch.parse_ips(ips32) == [(0x1000104, b'\x01\x02')])
ck('② 不是 IPS → None', cpatch.parse_ips(b'NOPE') is None)

# T130：偏移恰好拼成结束标记仍是记录；期望偏移独立手算，夹具仅原创字节。
for label, magic, ow, end, sentinel, expected_off in (
    ('IPS', b'PATCH', 3, b'EOF', 0x454F46, 4542022),
    ('IPS32', b'IPS32', 4, b'EEOF', 0x45454F46, 1162169926),
):
    def record(off, payload):
        return off.to_bytes(ow, 'big') + len(payload).to_bytes(2, 'big') + payload
    first = record(0x1000, b'\x01\x02')
    last = record(0x2000, b'\x03')
    collision = record(sentinel, b'\xaa\xbb')
    rle = sentinel.to_bytes(ow, 'big') + b'\x00\x00\x00\x03\xcc'
    ck(f'② {label}：哨兵同值偏移及后续记录均保留',
       cpatch.parse_ips(magic + first + collision + last + end) ==
       [(3840, b'\x01\x02'), (expected_off, b'\xaa\xbb'), (7936, b'\x03')])
    ck(f'② {label}：哨兵同值 RLE 及后续记录均保留',
       cpatch.parse_ips(magic + first + rle + last + end) ==
       [(3840, b'\x01\x02'), (expected_off, b'\xcc\xcc\xcc'), (7936, b'\x03')])
    ck(f'② {label}：普通末尾标记不变',
       cpatch.parse_ips(magic + first + end) == [(3840, b'\x01\x02')])
    ck(f'② {label}：末尾三字节截断扩展不改变写入列表',
       cpatch.parse_ips(magic + first + end + b'\x00\x20\x00') == [(3840, b'\x01\x02')])
    ck(f'② {label}：哨兵同值记录后缺结束标记整份拒绝',
       cpatch.parse_ips(magic + first + collision) is None)
    ck(f'② {label}：普通记录载荷截断整份拒绝',
       cpatch.parse_ips(magic + first + last[:-1]) is None)
    ck(f'② {label}：RLE 记录截断整份拒绝',
       cpatch.parse_ips(magic + first + rle[:-1]) is None)
    # 三字节尾部按任务契约解释为截断扩展，不能当作缺结束标记负例。
    for tail in (b'\x01', b'\x01\x02', b'\x00\x08\x01\x02', b'\x00\x08\x01\x02\x03'):
        ck(f'② {label}：标记后非法尾长 {len(tail)} 整份拒绝',
           cpatch.parse_ips(magic + first + end + tail) is None)

# 合成模块（同 tests/widen_sites_test.sh 的骨架）：main 代码段 0x100 起 mov w0,#1 / mov x0,x18 / ret
code = [0x52800020, 0xaa1203e0, 0xd65f03c0]
text = bytearray(0x3000); struct.pack_into('<II', text, 0, 0x14000040, 0x3000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x3000 + EF) - (0x3000 + EH + 4), 1, 0x100 - (0x3000 + EH), (0x3000 + EF + 0x18) - (0x3000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x3000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x3000 + EF), 0x100 - (f + 8), 4 * len(code))
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x3000, ro), (0x4000, bytes(0x1000)))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + mo, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes.fromhex('AABBCCDD00112233445566778899AABB')
root = T + '/root'; os.makedirs(root + '/exefs')
open(root + '/exefs/main', 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(0x1000))   # 文件偏移 = 0x100 + 内存偏移（段紧挨着放）
npdm = bytearray(0x200); npdm[:4] = b'META'; struct.pack_into('<I', npdm, 0x70, 0x100); npdm[0x100:0x104] = b'ACI0'; struct.pack_into('<Q', npdm, 0x110, 0x0100A3501946E000)
open(root + '/exefs/main.npdm', 'wb').write(bytes(npdm))
open(root + '/widen_sites.tsv', 'w').write('模块\t偏移\t种类\t证据\n')
# ③ 补丁索引：A 0x100、C 别的程序号、D 别的构建号（构建号写成去掉尾部 0 的短形式）
idx = T + '/uw'; os.makedirs(idx)
def p(name, bid, off, val='1F2003D5'): open(f'{idx}/{name}.pchtxt', 'w').write(f'@nsobid-{bid}\n@flag offset_shift 0x100\n@enabled\n{off:08X} {val}\n@stop\n')
BID = 'AABBCCDD00112233445566778899AABB'
p('A', BID, 0x100); p('C', BID, 0x100); p('D', 'FFBBCCDD00112233', 0x100)
import hashlib, re
def sid(n): return hashlib.sha256(open(f'{idx}/{n}.pchtxt', 'rb').read()).hexdigest()   # 索引写真实内容哈希（cpatch 核对，审计 #829）
NAMES = ['A', 'B', 'C', 'C2', 'D', 'D2', 'E', 'F']
def R(text):   # 实际输出里的真实编号 → 夹具占位名（A → AAAAAAAAAAAAAAAA），手写期望不变；映射只看夹具文件内容
    for n in NAMES:
        if os.path.exists(f'{idx}/{n}.pchtxt'): text = text.replace('gfx:' + sid(n)[:16], 'gfx:' + (n * 16)[:16])
    return text
def E(uid): return 'gfx:' + sid(next(n for n in NAMES if (n * 16)[:16] == uid[4:]))[:16]
def index(rows_):
    with open(idx + '/INDEX.tsv', 'w') as f:
        f.write('game\ttitle_id\tbuild_id\tkind\tpath\tin_pack\tlicense\tsha256\n')
        for n, tid in rows_: f.write(f'x\t{tid}\t\tpchtxt\t{n}.pchtxt\tyes\tMIT\t{sid(n)}\n')
index([('A', '0100A3501946E000'), ('C', '0100FFFF1946E000'), ('D', '0100A3501946E000')])
got = sorted(c['path'] for c in cpatch.scan([idx], root + '/exefs'))
ck(f'③ scan 只收 A（程序号前 13 位相同、构建号前缀对上），C 别的程序号、D 别的构建号不收（实得 {got}）', got == ['A.pchtxt'])
idx2 = T + '/uw_r2'; shutil.copytree(idx, idx2)   # 第二轮合集原样含第一轮文件（10-27 gfxpatches）：同一份补丁在两个目录里，按编号只收一次
got = [c['path'] for c in cpatch.scan([idx, idx2], root + '/exefs')]
ck(f'③ 两个目录里同一份补丁只收一次（实得 {got}）', got == ['A.pchtxt'])
# ③b 审计 #829：截断 IPS、索引哈希与内容不符、路径逃出索引目录——都整份不收
rec = (0x204).to_bytes(3, 'big') + (2).to_bytes(2, 'big') + b'\x00\x00'
ck('③b IPS 一条完整记录后没有 EOF（截断）→ None；补上 EOF → 1 条', cpatch.parse_ips(b'PATCH' + rec) is None and cpatch.parse_ips(b'PATCH' + rec + b'EOF') == [(0x104, b'\x00\x00')])
ck('③b IPS32 没有 EEOF → None', cpatch.parse_ips(b'IPS32' + (0x204).to_bytes(4, 'big') + (2).to_bytes(2, 'big') + b'\x00\x00') is None)
bad_idx = T + '/uw_bad'; os.makedirs(bad_idx)
open(T + '/outside.pchtxt', 'w').write(open(f'{idx}/A.pchtxt').read())   # 索引目录外一份合法补丁
shutil.copy(f'{idx}/A.pchtxt', f'{bad_idx}/A.pchtxt')
with open(bad_idx + '/INDEX.tsv', 'w') as f:
    f.write('game\ttitle_id\tbuild_id\tkind\tpath\tin_pack\tlicense\tsha256\n')
    f.write(f'x\t0100A3501946E000\t\tpchtxt\tA.pchtxt\tyes\tMIT\t{"0" * 64}\n')               # 哈希与内容不符
    f.write(f'x\t0100A3501946E000\t\tpchtxt\t../outside.pchtxt\tyes\tMIT\t{sid("A")}\n')     # 内容合法但在目录外
got = cpatch.scan([bad_idx], root + '/exefs')
ck(f'③b 索引哈希与内容不符、路径 ../ 逃出索引目录：两行都不收（实得 {[c["path"] for c in got]}）', got == [])
# ④ plan
p('B', BID, 0x200); p('C2', BID, 0x4800, 'AABBCCDD'); p('F', BID, 0x3800, 'AABBCCDD'); p('D2', BID, 0x100, '20018052'); p('E', BID, 0x104)
index([('A', '0100A3501946E000'), ('B', '0100A3501946E000'), ('C2', '0100A3501946E000'), ('D2', '0100A3501946E000'), ('E', '0100A3501946E000'), ('F', '0100A3501946E000')])
open(root + '/main.sites.tsv', 'w').write('0x104\tx18\n')
r = subprocess.run([sys.executable, H + '/pack/cpatch.py', 'plan', root, E('gfx:BBBBBBBBBBBBBBBB'), idx], capture_output=True, text=True)
rows = R(open(root + '/cpatch_rows.tsv').read()).splitlines(); tab = [l.split('\t') for l in R(open(root + '/cpatch.tsv').read()).splitlines()[1:]]
ck(f'④ 改写行：A → p 0x100 20008052→1f2003d5 位 0；B → w 0x200 0→1f2003d5（实得 {rows}）', rows == ['p\tmain\t100\t52800020\td503201f\t0\t# gfx:AAAAAAAAAAAAAAAA', 'w\tmain\t200\t00000000\td503201f\t# gfx:BBBBBBBBBBBBBBBB'])
ck(f'④ 装载表：A 位 0、B 位 1 缺省开、C2 位 2 数据写入 4800:00000000:aabbccdd（实得 {[(t[0], t[2], t[7], t[8]) for t in tab]}）',
   [(t[0], t[2], t[7], t[8]) for t in tab] == [('gfx:AAAAAAAAAAAAAAAA', '0', '', '0'), ('gfx:BBBBBBBBBBBBBBBB', '1', '', '1'), ('gfx:C2C2C2C2C2C2C2C2', '2', '4800:00000000:aabbccdd', '0')])
lg = R(open(root + '/cpatch_plan.log').read())
ck('④ D2（与 A 同处不同值）、E（改写点 0x104）、F（数据 0x3800 在代码末页 [0x3000, 0x4000) 里）不收、原因写明', '不收\tgfx:D2D2D2D2D2D2D2D2' in lg and '与 gfx:AAAAAAAAAAAAAAAA 改同一处' in lg and '不收\tgfx:EEEEEEEEEEEEEEEE' in lg and '改到我方改写点 main+0x104' in lg and '不收\tgfx:FFFFFFFFFFFFFFFF' in lg and '落在代码段末页上' in lg)
# ⑤ prune
open(root + '/main.gaps.tsv', 'w').write('# 需求\t1\n0x100\tcpatch\t造的缺口\n')
r5 = subprocess.run([sys.executable, H + '/pack/cpatch.py', 'prune', root], capture_output=True, text=True)
ck(f'⑤ prune：退出码 10、A 进排除清单（rc={r5.returncode}）', r5.returncode == 10 and R(open(root + '/cpatch_excluded.tsv').read()).startswith('gfx:AAAAAAAAAAAAAAAA\t'))
os.unlink(root + '/main.gaps.tsv'); subprocess.run([sys.executable, H + '/pack/cpatch.py', 'plan', root, '', idx], capture_output=True, text=True)
rows = R(open(root + '/cpatch_rows.tsv').read()).splitlines()
ck(f'⑤ 重跑 plan：A 不在、D2 轮上（p 0x100 新字 52800120 位 2）（实得 {[r_ for r_ in rows if r_.startswith("p")]}）', [r_ for r_ in rows if r_.startswith('p')] == ['p\tmain\t100\t52800020\t52800120\t2\t# gfx:D2D2D2D2D2D2D2D2'])
r6 = subprocess.run([sys.executable, H + '/pack/cpatch.py', 'prune', root], capture_output=True, text=True)
ck(f'⑤ 没有缺口时 prune 退出码 0（rc={r6.returncode}）', r6.returncode == 0)
# ⑥ T131：原创多构建号文本；期望偏移/BID 独立手算，不借解析器生成。块之间靠下一个 @nsobid 切开（@stop 按规范停整个文件，见 ①b）
multi = """@nsobid-AAAA
@flag offset_shift 0x100
@enabled
00001000 0102
@nsobid-BBBB
@enabled
00002000 0304
@stop
"""
_, sections = cpatch.parse_pchtxt(multi)
ck('⑥ 多块各带 BID，shift 不泄漏到下一块',
   [(s.get('bid'), s['writes']) for s in sections] ==
   [('AAAA', [(0x1000, b'\x01\x02')]), ('BBBB', [(0x1F00, b'\x03\x04')])])
reverse = multi.replace('@flag offset_shift 0x100\n', '').replace('@nsobid-BBBB\n', '@nsobid-BBBB\n@flag offset_shift 0x100\n')
_, sections = cpatch.parse_pchtxt(reverse)
ck('⑥ 后块 shift 不反向作用前块', [s['writes'][0][0] for s in sections] == [0xF00, 0x2000])
# 使用真实 scan 入口、真实索引与合成 NSO，而非 mock 匹配函数。
midx = T + '/multi'; os.makedirs(midx)
mroot = T + '/multi_root'; shutil.copytree(root + '/exefs', mroot)
mbid = 'BBBBBBBBBBBBBBBB'
mb = bytearray(open(mroot + '/main', 'rb').read()); mb[0x40:0x60] = bytes.fromhex(mbid) + bytes(24)
open(mroot + '/main', 'wb').write(mb)
def multi_scan(txt):
    open(midx + '/multi.pchtxt', 'w').write(txt)
    with open(midx + '/INDEX.tsv', 'w') as f:
        f.write('title_id\tkind\tpath\tlicense\n0100A3501946E000\tpchtxt\tmulti.pchtxt\t0BSD\n')
    return cpatch.scan([midx], mroot)
full = multi.replace('AAAA', 'AAAAAAAAAAAAAAAA').replace('BBBB', mbid)
got = multi_scan(full)
ck('⑥ BBBB 模块仅收第二块且正确减文件头',
   [(c['module'], c['writes']) for c in got] == [('main', [(0x1F00, b'\x03\x04')])])
ck('⑥ 没有 nsobid 的字节段不匹配', multi_scan('@enabled\n00002000 0304\n@stop\n') == [])
for invalid in ['"text"', '{hex1}']:
    got = multi_scan(full.replace('00002000 0304', '00002000 0304\n00002004 ' + invalid))
    ck('⑥ 多块字符串/模板整段不收：' + invalid, got == [])
# 新构建号即是段边界，漏写 stop 也不能把后块数据串到前块。
_, sections = cpatch.parse_pchtxt('@nsobid-AAAA\n@enabled\n00001000 0102\n@nsobid-BBBB\n00002000 0304\n')
ck('⑥ nsobid 切块终止前块未 stop 的段', len(sections) == 1 and sections[0]['writes'] == [(0xF00, b'\x01\x02')])
# ⑦ 数据流旁路（11-01）：合成 main，代码段 0x100 起（编码逐条手写、按 ARM 手册算）：
#    0x100 cbz x0, <J>（J = 0x10c 跳进区间中间 / 0x114 跳到用之后）  0x104 mov x1, x2  0x108 nop  0x10c ldr x5, [x4]  0x110 ldr x6, [x4, #8]  0x114 ret
#    0x200 跳转表：cmp w8,#0 / b.hi 0x220 / adrp x9,0x3000 / add x9,x9,#0 / adr x10,0x100 / ldrb w11,[x9,x8] / add x10,x10,x11,lsl #2 / br x10 / 0x220 ret；
#    表在 ro 段 0x3000，1 项（cmp #0 + b.hi → 1 项），项值 k → 目标 0x100 + 4k
#  补丁：0x104 → ldr x9, [x3]（设 x9）；0x110 → ldr x6, [x9, #8]（新读 x9），C 例改成 ldr x6, [x5, #8]（读原代码 0x10c 设的 x5）
#    A cbz → 0x10c、表项 5（→0x114）：0x100 → 0x10c 绕过 0x104 → 不收，原因逐字手写
#    B cbz → 0x114、表项 5：没有旁路 → 收（防误伤）
#    C cbz → 0x10c、补丁读 x5（补丁没设）→ 收（只管补丁自己设又读的寄存器）
#    D cbz → 0x114、表项 3（→0x10c）：跳转表从 0x21c 跳进中间 → 不收
#    E cbz → 0x114、表项 0（→0x100，区间外）→ 收
#    F 同 A，但原版 0x10c 是 ldr x5, [x9]（原代码在落点上还读 x9，旁路上的 x9 是原代码有意义的值，作者接着原状态写；
#      动森 SpeedFix 120/60/45 帧的 +0x7bcd5c 钩子就是这一形，原版 str w22,[x21]）→ 收（防误伤）
#    G 0x100 cbz x0, 0x11c；原版 0x114 nop / 0x118 b.ne 0x10c（回跳进区间中间）/ 0x11c ret，补丁另把 0x114 改成 b 0x11c：
#      0x118 只能从 0x114 落下来，补丁后 0x114 跳走 → 0x118 走不到（死代码，SpeedFix 整段重写后的原循环尾 +0x8ce8d8 就是这一形）→ 收（防误伤）
#    H 同 G 但补丁不改 0x114：0x110 → 0x114 → 0x118 → 0x10c 真能走到，且落点上原版不再用 x9 → 不收
#  旧代码反证：改动前的 pack/cpatch.py 没有这道检查，A / D 都收（期望不收 → 红）
def flow_case(tag, cbz, use, entry, w10c=0xF9400085, more={}, pmore={}):
    r7 = f'{T}/flow_{tag}'; i7 = f'{T}/flow_{tag}_idx'; os.makedirs(r7 + '/exefs'); os.makedirs(i7)
    code = {0x100: cbz, 0x104: 0xAA0203E1, 0x108: 0xD503201F, 0x10c: w10c, 0x110: 0xF9400486, 0x114: 0xD65F03C0,
            0x200: 0x7100011F, 0x204: 0x540000E8, 0x208: 0xF0000009, 0x20c: 0x91000129, 0x210: 0x10FFF78A, 0x214: 0x3868692B, 0x218: 0x8B0B094A, 0x21c: 0xD61F0140, 0x220: 0xD65F03C0}
    code.update(more); t7 = bytearray(0x3000)
    for a, w in code.items(): struct.pack_into('<I', t7, a, w)
    ro7 = bytearray(0x1000); ro7[0] = entry
    h7 = bytearray(0x100); h7[:4] = b'NSO0'; h7[0x40:0x50] = bytes.fromhex(BID)
    for k, (mo, seg) in enumerate(((0, t7), (0x3000, ro7), (0x4000, bytes(0x1000)))):
        struct.pack_into('<III', h7, 0x10 + 0x10 * k, 0x100 + mo, mo, len(seg)); struct.pack_into('<I', h7, 0x60 + 4 * k, len(seg))
    open(r7 + '/exefs/main', 'wb').write(bytes(h7) + bytes(t7) + bytes(ro7) + bytes(0x1000))
    shutil.copy(root + '/exefs/main.npdm', r7 + '/exefs/main.npdm')
    open(i7 + '/F.pchtxt', 'w').write(f'@nsobid-{BID}\n@flag offset_shift 0x100\n@enabled\n00000104 690040F9\n00000110 {use.to_bytes(4, "little").hex().upper()}\n' + ''.join(f'{a:08X} {w.to_bytes(4, "little").hex().upper()}\n' for a, w in pmore.items()) + '@stop\n')
    open(i7 + '/INDEX.tsv', 'w').write('title_id\tkind\tpath\tlicense\n0100A3501946E000\tpchtxt\tF.pchtxt\tMIT\n')
    r = subprocess.run([sys.executable, H + '/pack/cpatch.py', 'plan', r7, '', i7], capture_output=True, text=True)
    lg = open(r7 + '/cpatch_plan.log').read().splitlines() if r.returncode == 0 else [r.stderr]
    return [l.split('\t')[0] + ('\t' + l.split('\t')[4] if l.startswith('不收') else '') for l in lg if l]
WHY = '旁路读寄存器 main+0x110 读 x9：补丁在 +0x104 设，原版 1 条路从区间外进到两者之间绕过设置、落点上原版已不用 x9（如 {} → +0x10c；换寄存器补不上这条路上的值）'
for tag, cbz, use, entry, want, *w in (
    ('A', 0xB4000060, 0xF9400526, 5, ['不收\t' + WHY.format('+0x100')]),
    ('B', 0xB40000A0, 0xF9400526, 5, ['收']),
    ('C', 0xB4000060, 0xF94004A6, 5, ['收']),
    ('D', 0xB40000A0, 0xF9400526, 3, ['不收\t' + WHY.format('+0x21c')]),
    ('E', 0xB40000A0, 0xF9400526, 0, ['收']),
    ('F', 0xB4000060, 0xF9400526, 5, ['收'], 0xF9400125),
    ('G', 0xB40000E0, 0xF9400526, 5, ['收'], 0xF9400085, {0x114: 0xD503201F, 0x118: 0x54FFFFA1, 0x11c: 0xD65F03C0}, {0x114: 0x14000002}),
    ('H', 0xB40000E0, 0xF9400526, 5, ['不收\t' + WHY.format('+0x118')], 0xF9400085, {0x114: 0xD503201F, 0x118: 0x54FFFFA1, 0x11c: 0xD65F03C0})):
    got = flow_case(tag, cbz, use, entry, *w)
    ck(f'⑦ {tag}：期望 {want}（实得 {got}）', got == want)
# ⑧ 抢同一处按目标选（11-01）：合成 main 同 ④（0x100 原字 mov w0,#1），帧率索引（有 target_fps 列 → fps 类），各份都改 0x100、值各不同（内容不同 → 编号不同）
#    a 120 帧在前、b 60 帧在后 → 两份都收（11-13 起：目标不同的帧率补丁是兄弟，同处多路、运行时按玩家选的档只开一份），按目标排序 b 在前
#    c 60 帧、模组目录下有 romfs 行（缺参数表）在前，d 60 帧、无 romfs 行在后 → 收 d（旧代码收 c → 红）
#    e、f 都 60 帧都不缺 → 平手按原顺序收 e
#    g target_fps 空、路径里也没写帧数（取不到）在前，h 60 帧在后 → 收 h
#    i（IPS，exefs_patches 下看不出模组根 = 判不了）与 k（pchtxt，缺参数表）写入逐字节相同 → i 沿用「缺」；j（IPS，判不了、写入不同）→ 收 j（顺序 i、j、k）
def pick_case(tag, items):
    r8 = f'{T}/pick_{tag}'; i8 = f'{T}/pick_{tag}_idx'; os.makedirs(r8); shutil.copytree(root + '/exefs', r8 + '/exefs'); os.makedirs(i8)
    rows = ['title_id\ttype\tpath\ttarget_fps']; names = {}
    for name, path, fps, val, romfs in items:
        os.makedirs(os.path.dirname(f'{i8}/{path}'), exist_ok=True)
        if path.endswith('.ips'): open(f'{i8}/{path}', 'wb').write(b'PATCH' + (0x200).to_bytes(3, 'big') + (4).to_bytes(2, 'big') + bytes.fromhex(val) + b'EOF')
        else: open(f'{i8}/{path}', 'w').write(f'@nsobid-{BID}\n@flag offset_shift 0x100\n@enabled\n00000100 {val}\n@stop\n')
        names['fps:' + hashlib.sha256(open(f'{i8}/{path}', 'rb').read()).hexdigest()[:16]] = name
        rows.append(f'0100A3501946E000\t{"ips" if path.endswith(".ips") else "pchtxt"}\t{path}\t{fps}')
        if romfs: rows.append(f'0100A3501946E000\tromfs bcsv\t{path.rsplit("/exefs/", 1)[0]}/romfs/Bcsv/P.bcsv\t{fps}')
    open(i8 + '/INDEX.tsv', 'w').write('\n'.join(rows) + '\n')
    subprocess.run([sys.executable, H + '/pack/cpatch.py', 'plan', r8, '', i8], capture_output=True, text=True)
    return [names[l.split('\t')[1]] for l in open(r8 + '/cpatch_plan.log').read().splitlines() if l.startswith('收\t')]
IPSN = 'm/exefs_patches/N/' + BID + '.ips'
for tag, items, want in (
    ('1', [('a', 'a/exefs/m.pchtxt', '120', '40008052', 0), ('b', 'b/exefs/m.pchtxt', '60', '60008052', 0)], ['b', 'a']),
    ('2', [('c', 'c/exefs/m.pchtxt', '60', '40008052', 1), ('d', 'd/exefs/m.pchtxt', '60', '60008052', 0)], ['d']),
    ('3', [('e', 'e/exefs/m.pchtxt', '60', '40008052', 0), ('f', 'f/exefs/m.pchtxt', '60', '60008052', 0)], ['e']),
    ('4', [('g', 'g/exefs/m.pchtxt', '', '40008052', 0), ('h', 'h/exefs/m.pchtxt', '60', '60008052', 0)], ['h']),
    ('5', [('i', IPSN, '60', '40008052', 0), ('j', IPSN.replace('/N/', '/M/'), '60', '60008052', 0), ('k', 'k/exefs/m.pchtxt', '60', '40008052', 1)], ['j'])):
    got = pick_case(tag, items)
    ck(f'⑧ {tag}：期望收 {want}（实得 {got}）', got == want)
sys.exit(bad)
EOF
[ $bad = 0 ] && echo "✅ cpatch_test 全过" || { echo "🔴 cpatch_test 有不通项"; exit 1; }
