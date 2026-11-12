#!/usr/bin/env python3
# 旧版 UE4 pak（v1–v7 经典索引）读取与条目内 zlib 着色器抽取单测（graphics/tools/shbake/unreal_pak.py、nxsh_extract.py work_pak，10-23 Blade II v4 一支没抽到）：约 0.2 秒，退出 0 = 全过。
# 构造（按 UE 4.17 / 4.21 FPakEntry::Serialize 与 FPakInfo 手写，不跑被测实现推期望）：每条数据前是同一份序列化条目头，索引 = 挂载点 + 条目数 + 逐条（文件名 + 条目），文件尾 = [GUID 16 + 加密标志 1（v7）] + 魔数 + 版本 + 索引偏移 / 长度 + 哈希 20。
#   ① v4：一条不压缩、一条 Zlib 两块（块起止 = 文件内绝对偏移）→ is_pak、legacy、条目数、两条逐字节解出
#   ② v5：同内容，块起止 = 相对条目偏移 → 逐字节解出
#   ③ v1：不压缩条目多 8 字节时间戳 → 解出；④ v7 只置加密标志、未实际加密 → 拒绝无效 AES 长度；条目加密且无密钥 → read 抛 Unsupported
#   ⑤ 压缩标志 3（LZ5，非 Zlib / Gzip）没给解码器 → read 抛 Unsupported、给了就解；⑥ 文件尾魔数对但版本 8 却是 44 字节旧式文件尾（没有名字表）→ is_pak 假
#   ⑦ 抽取：v4 pak 里一条 uasset = 垃圾 + zlib(控制段 + 机器码头开头的机器码) + 垃圾 → work_pak 抽出 1 支（键 = sha256(控制段 ‖ 机器码) 前 16 位）；
#      同一份数据按 v10 起的口径（visit zl=False）不扫 zlib 流 → 0 支（旧版 pak 才需要再扫，见 work_pak）
#   ⑧ 整个抽取流程（nxsh_extract.py 子进程）：目录里一个只置加密标志的伪 v7 pak → 退出 1、标准错误有「【红】pak 损坏」与该 pak 路径；
#      同目录换成索引不加密的 v7 pak → 退出 0（反证：红只来自加密标志）
#   ⑩ 未加密 Zlib 条目的解压长度必须等于索引里记的原长（审计 #846 F-uepak-usz-slice：原先只有加密条目核长度，未加密的 data[:usz] 切片当完整文件返回）：
#      原长记 16、zlib 原文 460 字节 / 原长记 1000、原文 460 字节 / 压缩标志 1 但块表为空、原长 100 → read 都抛 Corrupt（原先依次返回 16 字节、460 字节、b''）；
#      整个抽取流程：目录里一个 v4 pak 只有一条原长记错的条目 → 退出 1、标准错误有【红】行点名该条目（原先当「不支持」计数、退出 0）
#   ⑪ 版本 8 / 9（11-02 普查 BRAVELY DEFAULT Ⅱ「pak 版本 8」抽不出）：v8 5 个名字、序号 u32 的不压缩 / Zstd / Zlib 三条；v8（4.22）4 个名字、序号 u8；
#      v9 冻结标志 0 → 都逐字节解出；v9 冻结标志 1 → 抛 Unsupported 点名冻结索引
import os, sys, struct, zlib, hashlib, tempfile, collections, subprocess
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
import unreal_pak as ue_pak, nxsh_extract as X, srcpack
fail = 0
def ck(ok, msg):
    global fail
    print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
MAGIC = 0x5A6F12E1
def fstr(s): b = s.encode('latin1') + b'\0'; return struct.pack('<i', len(b)) + b
def ser(ver, off, size, usz, fl, blocks=(), encd=0):   # 序列化条目（索引里与数据前同一份）
    b = struct.pack('<qqqI', off, size, usz, fl) + (struct.pack('<q', 0) if ver == 1 else b'') + bytes(20)
    if ver >= 3:
        if fl: b += struct.pack('<i', len(blocks)) + b''.join(struct.pack('<qq', a, z) for a, z in blocks)
        b += bytes([encd]) + struct.pack('<I', 0x10000)
    return b
def build(ver, files, path, enc_idx=0, encd=0, fl_override=None):
    """files: [(名, 原文, 压缩块数 0 = 不压缩 / -1 = 压缩标志 1 但块表为空[, 索引里记的原长（缺省 = 原文长）])]"""
    body = bytearray(); idx = bytearray(fstr('../../../')) + struct.pack('<i', len(files))
    for name, data, nb, *usz in files:
        off = len(body)
        if nb == 0:
            fl = 0; payload = data; blocks = []
        elif nb < 0:
            fl = 1; payload = b''; blocks = []
        else:
            fl = 1; step = -(-len(data) // nb); zs = [zlib.compress(data[i:i + step]) for i in range(0, len(data), step)]
            hdr_len = len(ser(ver, 0, 0, 0, 1, [(0, 0)] * len(zs), encd)); a = hdr_len; blocks = []
            for z in zs: blocks.append((a, a + len(z)) if ver >= 5 else (off + a, off + a + len(z))); a += len(z)
            payload = b''.join(zs)
        if fl_override is not None and fl: fl = fl_override
        e = ser(ver, off, len(payload), usz[0] if usz else len(data), fl, blocks, encd)
        body += e + payload; idx += fstr(name) + e
    io = len(body); body += idx
    tail = (bytes(16) + bytes([enc_idx]) if ver >= 7 else b'') + struct.pack('<IiQQ', MAGIC, ver, io, len(idx)) + bytes(20)
    open(path, 'wb').write(bytes(body) + tail)
T = tempfile.mkdtemp()
A = bytes(range(256)) * 20; B = (b'shader-bytes-' * 4000)[:50000]
def readall(p):
    pk = ue_pak.Pak(p); return pk, {n: pk.read(e) for n, e in pk.files}
p4 = os.path.join(T, 'v4.pak'); build(4, [('a.bin', A, 0), ('b.uasset', B, 2)], p4)
pk, got = readall(p4)
ck(ue_pak.is_pak(p4) and pk.legacy and pk.ver == 4 and len(pk.files) == 2 and got == {'a.bin': A, 'b.uasset': B},
   f'① v4：认出、2 条、不压缩 / Zlib 两块逐字节解出（legacy={pk.legacy} ver={pk.ver} 条目 {len(pk.files)} 相符 {got == {"a.bin": A, "b.uasset": B}}）')
p5 = os.path.join(T, 'v5.pak'); build(5, [('a.bin', A, 0), ('b.uasset', B, 3)], p5)
pk, got = readall(p5)
ck(got == {'a.bin': A, 'b.uasset': B}, f'② v5：块起止相对条目偏移，逐字节解出（相符 {got == {"a.bin": A, "b.uasset": B}}）')
p1 = os.path.join(T, 'v1.pak'); build(1, [('a.bin', A, 0), ('c.bin', B, 0)], p1)
pk, got = readall(p1)
ck(got == {'a.bin': A, 'c.bin': B}, f'③ v1：带时间戳的条目解出（相符 {got == {"a.bin": A, "c.bin": B}}）')
p7 = os.path.join(T, 'v7e.pak'); build(7, [('a.bin', A, 0)], p7, enc_idx=1)
try: ue_pak.Pak(p7); r = '没抛'
except ue_pak.Unsupported as e: r = str(e)
p7c = os.path.join(T, 'v7c.pak'); build(7, [('b.uasset', B, 2)], p7c, encd=1); pk = ue_pak.Pak(p7c)
try: pk.read(pk.files[0][1]); r2 = '没抛'
except ue_pak.Unsupported as e: r2 = str(e)
ck(r == '加密索引长度无效' and r2 == '条目加密', f'④ v7：加密标志但无 AES 对齐的伪索引 → {r}；无密钥的加密条目 → {r2}')
p2 = os.path.join(T, 'lz5.pak'); build(4, [('b.uasset', B, 2)], p2, fl_override=3); pk = ue_pak.Pak(p2)
try: pk.read(pk.files[0][1]); r = '没抛'
except ue_pak.Unsupported as e: r = str(e)
r3 = pk.read(pk.files[0][1], decode=lambda b, k: zlib.decompress(b)) == B   # 给了解码器（游戏自带的 LZ5 / Oodle 走这条）就解
ck(r.startswith('压缩方式') and r3, f'⑤ 压缩标志 3（LZ5）没给解码器 → {r}；给了解码器 → 逐字节解出 {r3}')   # 11-01 收成一份读取器后 Gzip（标志 2）同 Zlib 在读取器里解，不再算不支持
p8 = os.path.join(T, 'v8.pak'); build(4, [('a.bin', A, 0)], p8)
d = bytearray(open(p8, 'rb').read()); struct.pack_into('<i', d, len(d) - 40, 8); open(p8, 'wb').write(d)
ck(not ue_pak.is_pak(p8), f'⑥ 文件尾版本 8（没有样本）→ is_pak 假（实得 {ue_pak.is_pak(p8)}）')
# ⑦ 抽取：控制段（魔数、+0x20 自身长、+0x704 机器码长）后紧跟机器码头 78563412 + 12 个 0 → scan_adj 正向带头分支
ctl = bytearray(0x710); ctl[:8] = bytes.fromhex('3412769801000000'); struct.pack_into('<I', ctl, 0x20, len(ctl)); struct.pack_into('<I', ctl, 0x704, 0x100)
code = bytearray(0x100); code[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', code, 0x30, 1 << 10)
key = hashlib.sha256(bytes(ctl) + bytes(code)).hexdigest()[:16]
U = b'\x00uasset-head' * 50 + zlib.compress(bytes(ctl) + bytes(code)) + b'tail' * 30
px = os.path.join(T, 'x.pak'); build(4, [('Game/M_Test.uasset', U, 2)], px)
out = os.path.join(T, 'out'); os.makedirs(os.path.join(out, 'src'))
rows, st = X.work_pak((px, ue_pak.Pak(px).files, out))
r0 = []; X.visit('pak:Game/M_Test.uasset', U, r0, {}, collections.Counter(), zl=False)
ck(len(rows) == 1 and rows[0][0] == key and key in srcpack.Src(out) and r0 == [],
   f'⑦ v4 条目内 zlib 着色器：抽出 {len(rows)} 支（键 {rows[0][0] if rows else "-"}，期望 {key}）；按 v10 口径不扫 zlib → {len(r0)} 支')
def extract_rc(enc):
    d = os.path.join(T, f'e{enc}'); os.makedirs(os.path.join(d, 'romfs', 'Content', 'Paks'))
    build(7, [('a.bin', A, 0)], os.path.join(d, 'romfs', 'Content', 'Paks', 'Game-Switch.pak'), enc_idx=enc)
    r = subprocess.run([sys.executable, os.path.join(H, 'nxsh_extract.py'), os.path.join(d, 'out'), os.path.join(d, 'romfs')], capture_output=True, text=True, env=dict(os.environ, J='1'))
    return r.returncode, r.stderr
rc1, err1 = extract_rc(1); rc0, err0 = extract_rc(0)
ck(rc1 == 0 and '【红】pak 损坏：Content/Paks/Game-Switch.pak' in err1 and '【黄】抽取：跳过读不了的部分' in err1 and rc0 == 0 and '【红】' not in err0,   # v0.3.1：损坏的 pak 跳过、记降级（原先退 1）
   f'⑧ 抽取流程：伪加密 v7 pak → 退出 {rc1}、损坏红行{"有" if "【红】pak 损坏" in err1 else "无"}；不加密 → 退出 {rc0}')
# ⑩ 未加密 Zlib 条目长度不符 / 空块表
C460 = bytes(range(230)) * 2
def read_one(name, files):
    p = os.path.join(T, name); build(4, files, p); pk = ue_pak.Pak(p)
    try: d = pk.read(pk.files[0][1]); return f'没抛、返回 {len(d)} 字节'
    except ue_pak.Corrupt as e: return f'Corrupt：{e}'
    except Exception as e: return f'{type(e).__name__}：{e}'
rs = [read_one('usz16.pak', [('m.uasset', C460, 1, 16)]), read_one('usz1000.pak', [('m.uasset', C460, 1, 1000)]), read_one('noblk.pak', [('m.uasset', b'', -1, 100)])]
ck(all(r.startswith('Corrupt') for r in rs), f'⑩ 未加密 Zlib 条目：原长记 16 → {rs[0]}；原长记 1000 → {rs[1]}；空块表原长 100 → {rs[2]}')
d10 = os.path.join(T, 'e_usz'); os.makedirs(os.path.join(d10, 'romfs', 'Content', 'Paks'))
build(4, [('Game/M_Cut.uasset', C460, 1, 16)], os.path.join(d10, 'romfs', 'Content', 'Paks', 'Game-Switch.pak'))
r10 = subprocess.run([sys.executable, os.path.join(H, 'nxsh_extract.py'), os.path.join(d10, 'out'), os.path.join(d10, 'romfs')], capture_output=True, text=True, env=dict(os.environ, J='1'))
ck(r10.returncode == 0 and '【红】' in r10.stderr and 'Game/M_Cut.uasset' in r10.stderr and '【黄】抽取：跳过读不了的部分' in r10.stderr,   # v0.3.1：跳过、记降级（原先退 1）
   f'⑩ 抽取流程：原长记错的条目 → 退出 {r10.returncode}（期望 0）、红行点名条目{"有" if "Game/M_Cut.uasset" in r10.stderr and "【红】" in r10.stderr else "无"}（{r10.stderr.strip().splitlines()[-1] if r10.stderr.strip() else "无标准错误"}）')
# ⑪ 版本 8 / 9（压缩字段 = 文件尾名字表序号）：按 UE 4.22–4.25 FPakEntry::Serialize / FPakInfo 手写
def build8(ver, files, path, names, u8=False, frozen=None):
    """files: [(名, 原文, 方式序号 0 = 不压缩)]；方式名按序号在 names 里取，Zlib 用 zlib、Zstd 用 zstd 命令行压"""
    def comp(m, d):
        if names[m - 1] == 'Zlib': return zlib.compress(d)
        return subprocess.run(['zstd', '-q', '-c', '-'], input=d, capture_output=True, check=True).stdout   # zstd 命令行压（不依赖 Python 的 zstd 模块）
    body = bytearray(); idx = bytearray(fstr('../../../')) + struct.pack('<i', len(files))
    def e8(off, size, usz, m, blocks):
        b = struct.pack('<qqq', off, size, usz) + (struct.pack('<B', m) if u8 else struct.pack('<I', m)) + bytes(20)
        if m: b += struct.pack('<i', len(blocks)) + b''.join(struct.pack('<qq', a, z) for a, z in blocks)
        return b + bytes([0]) + struct.pack('<I', 0x10000)
    for name, data, m in files:
        off = len(body); payload = comp(m, data) if m else data
        blocks = [(len(e8(0, 0, 0, m, [(0, 0)])), len(e8(0, 0, 0, m, [(0, 0)])) + len(payload))] if m else []
        e = e8(off, len(payload), len(data), m, blocks); body += e + payload; idx += fstr(name) + e
    io = len(body); body += idx
    tail = bytes(16) + bytes([0]) + struct.pack('<IiQQ', MAGIC, ver, io, len(idx)) + bytes(20) + (bytes([frozen]) if frozen is not None else b'') \
           + b''.join(n.encode().ljust(32, b'\0') for n in names)
    open(path, 'wb').write(bytes(body) + tail)
C = (b'zstd-entry-' * 3000)[:30000]
p8 = os.path.join(T, 'v8.pak'); build8(8, [('a.bin', A, 0), ('z.uasset', C, 1), ('b.uasset', B, 2)], p8, ['Zstd', 'Zlib', '', '', ''])
pk, got = readall(p8)
ck(ue_pak.is_pak(p8) and pk.ver == 8 and got == {'a.bin': A, 'z.uasset': C, 'b.uasset': B} and [pk.entry(h)['method'] for _, h in pk.files] == ['', 'Zstd', 'Zlib'],
   f'⑪ v8（4.23+，5 个名字、序号 u32；BRAVELY DEFAULT Ⅱ 同款）：不压缩 / Zstd / Zlib 逐字节解出（相符 {got == {"a.bin": A, "z.uasset": C, "b.uasset": B}}）')
p8a = os.path.join(T, 'v8_422.pak'); build8(8, [('a.bin', A, 0), ('b.uasset', B, 1)], p8a, ['Zlib', '', '', ''], u8=True)
pk, got = readall(p8a)
ck(got == {'a.bin': A, 'b.uasset': B}, f'⑪ v8（4.22，4 个名字、序号 u8）：逐字节解出（相符 {got == {"a.bin": A, "b.uasset": B}}）')
p9 = os.path.join(T, 'v9.pak'); build8(9, [('a.bin', A, 0), ('b.uasset', B, 2)], p9, ['Zstd', 'Zlib', '', '', ''], frozen=0)
pk, got = readall(p9)
ck(got == {'a.bin': A, 'b.uasset': B}, f'⑪ v9 不冻结（SHA-1 后 1 字节冻结标志 0）：逐字节解出（相符 {got == {"a.bin": A, "b.uasset": B}}）')
p9f = os.path.join(T, 'v9f.pak'); build8(9, [('a.bin', A, 0)], p9f, ['Zstd', 'Zlib', '', '', ''], frozen=1)
try: ue_pak.Pak(p9f); r9 = '读成了'
except ue_pak.Unsupported as e: r9 = f'Unsupported：{e}'
ck(r9.startswith('Unsupported') and '冻结' in r9, f'⑪ v9 冻结索引 → 大声拒绝（{r9}）')
sys.path.insert(0, os.path.join(os.path.dirname(H), '../../translator')); import uepak   # shader_split 旧版 pak 路（ue_legacy_jobs）收哪些版本
with open(p8, 'rb') as f: v8 = uepak.pak_version(f)
ck(v8 == 8 and 8 in uepak.LEGACY and 9 in uepak.LEGACY, f'⑪ v8 / v9 进 shader_split 旧版 pak 路（读到版本 {v8}，LEGACY = {uepak.LEGACY}）')
# 复用已有 gfx 门禁入口；新测试只有合成数据和系统 OpenSSL，不需要设备。
import unittest, t_ue_pak_encrypted
result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromModule(t_ue_pak_encrypted))
ck(result.wasSuccessful(), f'⑨ 加密 PAK / 共享着色器存档：{result.testsRun} 项，失败 {len(result.failures) + len(result.errors)}')
print(f't_ue_pak_legacy：11 组（含加密 {result.testsRun} 项），失败 {fail}')
sys.exit(1 if fail else 0)
