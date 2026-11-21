#!/usr/bin/env python3
# IoStore 容器接入出包链单测（#247：pack/ue_pak.py + graphics/tools/direct/extract.py 的 Unreal 包门禁）：合成容器，约 3 秒，退出 0 = 全过。**完全不含游戏数据**。
# 构造（按 FIoStoreTocHeader 144 字节与压缩块表手写，不跑被测实现推期望）：header（魔数、版本、头长、chunk 条数、块条数、块条目 12、方法数、
#   方法名长 32、块大小、目录索引、分区数、容器 ID、标志）+ chunk ID 表（12 字节 × n）+ 偏移长度表（各 5 字节大端）+
#   压缩块表（5 字节偏移 + 3 字节存储长 + 3 字节原长 + u8 方法）+ 方法名表；容器未压缩流写进同名 .ucas。
# 覆盖：
#   ① CityHash64 自检（空串 = 0x9ae16a3b2f90404f）+ 与仓内 cityhash.py 对拍 + 库名散列口径（'<库>-<格式>' 小写 UTF-16LE，与 UTF-8 不同）
#   ② 正例：纯 .utoc/.ucas 合成根（一个 .pak 都没有）→ 新 pack/ue_pak.py 退出 0、写出存档、每支存储长 = 原长、记录字节逐条等于合成本数
#   ③ 命名：Manifest 里列了 ShaderArchive-<库>-<格式> 就按它命名，没列 → ShaderArchive-IoStore-<哈希>
#   ④ Oodle 块、没有宿主（不设 DM_OODLE_HOST / DM_OODLE_MODULES，RomFS 旁也没有改写模块）→ 退出非 0、日志点名容器与 Oodle、说明缺的是游戏自带解码器的宿主
#      （与 pak 的 Oodle 口径一致；有宿主时解出，见 tests/ue_pak_test.sh ④ / tests/oodle_proto_test.sh）
#   ⑤ 反证：改前抽取门禁谓词 / 改前 ue_pak.py 对同一个纯 .utoc 根抽 0 支；新代码抽全部
#   ⑥ 出包链：真的 graphics/tools/direct/extract.py（临时树 + 记账的假 split / s2x）—— 旧门禁行消费方一个存档都看不到，新门禁行看到全部
#   ⑦ TOC 版本 3（UE 4.27）没有着色器代码库这套 chunk 编号 → 不猜、不写、退出 0、日志点明版本
#   ⑧ 加密容器（标志位 2，块按 16 字节补齐后 AES-256-ECB，openssl 加密，不跑被测实现）+ 同包一个加密 pak、main 里嵌着密钥（t_ue_pak_encrypted 的合成件）
#      → 用 pak 找到的密钥解出、记录逐条等于合成本；改前 ue_pak.py 当「不是 IoStore」跳过、写出 0 个（11-02 普查七龙珠 电光炸裂 ZERO）；
#      没有 pak 可借密钥 → 退出非 0、日志点名「IoStore 容器加密」（不静默跳过）
#   ⑨ UE5 不开共享着色器代码库（电光炸裂）：容器里没有库 chunk，着色器内嵌在导出数据（类型 1）里，条目 [i32 n][LZ4 块][i32 原长][u8 阶段]（lz4 库压，不跑被测实现）
#      → 写出 ShaderArchive-IoStoreInline-<容器>（与同名 pak 的内嵌存档分开），3 支逐条等于合成本；改前 ue_pak.py 只记「没有着色器代码库」、写出 0 个
#   ⑩ inline_entries 的 Oodle 条目（游戏解码器换成查表替身）：三支首尾相接；第 2 支流里埋一个假长度，正好吞到第 3 支末尾（电光炸裂全局缓存里的 cc30 那种）
#      → 3 支全出、替身只被喂过 3 条真流（假候选的帧结构对不上，不喂给解码器）
#   ⑬ UE 4.26 的 TOC 版本 2：导出数据块是类型 2（不是 UE5 的 1）→ 内嵌着色器照样抽出（鬼灭之刃 火之神血风谭）
#   ⑭ pak 里已经写出着色器存档时不扫 IoStore 导出：同根放一个 Oodle 块的导出（没宿主，扫了就红）→ 退出 0、只有 pak 那份（轩辕剑柒：存档在 pak）
#   ⑪ 补丁容器（g_0_P.utoc）带同号的新着色器库：组 0 只在本体容器（g.utoc），组 1 在补丁里（LEGO 地平线大冒险 1.4.0「shader group 0 has no chunk」）
#      → 退出 0、只写一份（补丁那份为准）、3 支 = 本体组 0 的两支 + 补丁组 1 的新一支；改前（611abc308 的 ue_pak.py + uepak.py）退出非 0、日志点名「has no chunk」
#   ⑫ 补丁不带库、只带本体库组 0 的新版（同号组 chunk，同长新内容）→ 组 0 取补丁那份（UE 按挂载优先级全局取 chunk；先查库自己容器的写法会取到本体旧组）
import importlib.util, os, shutil, struct, subprocess, sys, tempfile, zlib

T = tempfile.mkdtemp()
H = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..'))
PY = sys.executable
fail = 0
n = 0
def ck(ok, what):
    global fail, n
    n += 1
    print(('✓ ' if ok else '✗ ') + what)
    fail += 0 if ok else 1

sys.path.insert(0, os.path.join(H, 'graphics', 'tools', 'shbake'))
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
try:
    import cityhash
    U = load(os.path.join(H, 'translator', 'uepak.py'), 'uepak_ref')
    E = load(os.path.join(H, 'graphics', 'tools', 'shbake', 'tests', 't_ue_pak_encrypted.py'), 't_ue_pak_encrypted')   # 加密 pak + 嵌密钥 main 的合成件（openssl 加密）
except Exception as e:
    print(f'✗ 导入 cityhash / uepak 失败：{e}')
    print('期望 IoStore 容器接入出包链 全过 → 真结果 失败 1 / 1')
    sys.exit(1)

UE_PAK = os.path.join(H, 'pack', 'ue_pak.py')
EXTRACT = os.path.join(H, 'graphics', 'tools', 'direct', 'extract.py')

# ── 合成容器 ────────────────────────────────────────────────────────────────
TOC_MAGIC = b'-==--==--==--==-'
MLEN = 32
LIB, CODE = 8, 9          # EIoChunkType（TOC 版本 4 起：8 = 着色器代码库、9 = 着色器代码）；独立写一份，不抄 uepak 的常数

def cid(h8, index, typ):
    """12 字节 chunk ID：u64 哈希 + u16 序号 + u8 保留 + u8 类型"""
    return bytes(h8) + struct.pack('<H', index) + b'\x00' + bytes([typ])

def lib_hash(library, fmt):
    """库名散列：'<库>-<格式>' 小写、UTF-16LE、CityHash64 的 8 字节（机内序）—— 用仓内 cityhash.py 算，再与 uepak.city64 对拍"""
    return cityhash.city64(f'{library}-{fmt}'.lower().encode('utf-16-le')).to_bytes(8, 'little')

def blob(map_hashes, shader_hashes, group_ids, maps, packed, groups, indices):
    """FIoStoreShaderCodeArchive 的字节（每张表 u32 条数在前）"""
    b = struct.pack('<I', 1)
    b += struct.pack('<I', len(map_hashes)) + b''.join(map_hashes)
    b += struct.pack('<I', len(shader_hashes)) + b''.join(shader_hashes)
    b += struct.pack('<I', len(group_ids)) + b''.join(group_ids)
    b += struct.pack('<I', len(maps)) + b''.join(struct.pack('<II', a, c) for a, c in maps)
    b += struct.pack('<I', len(packed)) + b''.join(struct.pack('<Q', p) for p in packed)
    b += struct.pack('<I', len(groups)) + b''.join(struct.pack('<IIII', *g) for g in groups)
    b += struct.pack('<I', len(indices)) + b''.join(struct.pack('<I', i) for i in indices)
    return b

def ent(freq, group, offset):
    """着色器条目 u64：频段 0-3 位、组号 4-33 位、组内偏移 34 位起"""
    return (freq & 0xF) | ((group & 0x3FFFFFFF) << 4) | (offset << 34)

def build(path, entries, stream, method_of, block_size=256, version=4, methods=('Zlib',), flags=0, key=None):
    """entries: [(chunk ID, 偏移, 长度)]；stream: 容器未压缩流；method_of: 块序号 → 方法序号（0 原样落盘，1 起按方法表压缩）；
    key：加密容器（标志位 2），每块补齐到 16 字节后整块加密，块表记未补齐的存储长、下一块从补齐后接着放"""
    nblk = -(-len(stream) // block_size) if stream else 0
    bodies, blocks, at = [], [], 0
    for k in range(nblk):
        raw = stream[k * block_size:(k + 1) * block_size]
        m = method_of(k) if callable(method_of) else method_of
        payload = raw if m == 0 else zlib.compress(raw)
        blocks.append((at, len(payload), len(raw), m))
        if key: payload = E.encrypt(payload, key)
        bodies.append(payload)
        at += len(payload)
    hdr = bytearray(144)
    hdr[:16] = TOC_MAGIC
    hdr[16] = version
    struct.pack_into('<9I', hdr, 20, 144, len(entries), nblk, 12, len(methods), MLEN, block_size, 0, 1)
    struct.pack_into('<Q', hdr, 56, 0x1000)
    hdr[80] = flags | (2 if key else 0)
    t = bytearray()
    for c, _, _ in entries:
        t += c
    for _, off, ln in entries:
        t += off.to_bytes(5, 'big') + ln.to_bytes(5, 'big')
    for off, stored, raw, m in blocks:
        t += off.to_bytes(5, 'little') + stored.to_bytes(3, 'little') + raw.to_bytes(3, 'little') + bytes([m])
    for name in methods:
        t += name.encode('latin1').ljust(MLEN, b'\x00')[:MLEN]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(bytes(hdr) + bytes(t))
    open(path[:-5] + '.ucas', 'wb').write(b''.join(bodies))

def shader(tag, size):
    """一支合成着色器记录（ue_pak 只写字节不解析内部；LSLG 开头与真实记录一致）"""
    return b'LSLG' + tag + bytes([0x40 + size % 0x40]) * (size - 6)

def one_lib(utoc, library, fmt, shaders, method_of=0, version=4, methods=('Zlib',), key=None, gseed=0x10):
    """一个库的容器：组 0 放前两支承（跨块），组 1 放第三支，库表 chunk 夹在中间。→ [(频段, 字节)]（手算期望）
    gseed：组 chunk 号的种子——真包里 chunk 号全局唯一（读取器按挂载优先级全局取），同一 RomFS 里两个库要给不同的种子"""
    g0 = shaders[0] + shaders[1]
    g1 = shaders[2]
    gid0 = cid(bytes(range(gseed, gseed + 8)), 0, CODE)
    gid1 = cid(bytes(range(gseed + 0x10, gseed + 0x18)), 1, CODE)
    b = blob([bytes(range(20))], [bytes([i]) * 20 for i in range(3)], [gid0, gid1], [(0, 3)],
             [ent(0, 0, 0), ent(3, 0, len(shaders[0])), ent(5, 1, 0)],
             [(0, 2, len(g0), len(g0)), (2, 1, len(g1), len(g1))], [0, 1, 2])
    lid = cid(lib_hash(library, fmt), 0, LIB)
    build(utoc, [(gid0, 0, len(g0)), (lid, len(g0), len(b)), (gid1, len(g0) + len(b), len(g1))],
          g0 + b + g1, method_of, version=version, methods=methods, key=key)
    return [(0, shaders[0]), (3, shaders[1]), (5, shaders[2])]

def records(path):
    """产出的存档 → [(频段, 字节, 存储长, 原长)]"""
    d = open(path, 'rb').read()
    a = U.archive(d)
    c = a['code']
    return [(fr, d[c + off:c + off + size], size, raw) for off, size, raw, fr in a['shaders']]

def run_ue_pak(romfs, out, script=UE_PAK):
    r = subprocess.run([PY, script, romfs, out], capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr)

def listing(d):
    return sorted(os.listdir(d)) if os.path.isdir(d) else []

# ── ① CityHash64 与库名散列口径 ─────────────────────────────────────────────
ck(U.city64(b'') == 0x9ae16a3b2f90404f, '① CityHash64 自检：空串 = %#018x（期望 0x9ae16a3b2f90404f）' % U.city64(b''))
vec = (b'', b'a', b'hello', b'x' * 72, bytes(range(200)))
ck(all(U.city64(s) == cityhash.city64(s) for s in vec), '① 与仓内 cityhash.py 对拍 5 个长度（0/1/5/72/200 字节）一致')
ck(lib_hash('Global', 'SF_GLSL_SWITCH') == U.city64('global-sf_glsl_switch'.encode('utf-16-le')).to_bytes(8, 'little')
   and lib_hash('Global', 'SF_GLSL_SWITCH') != cityhash.city64(b'global-sf_glsl_switch').to_bytes(8, 'little'),
   '① 库名散列：大写格式名按小写 UTF-16LE 散列（与同串 UTF-8 的散列不同，口径不会混）')

# ── ② 正例：纯 .utoc/.ucas 的 RomFS ─────────────────────────────────────────
S0, S1, S2 = shader(b'SV', 128), shader(b'SP', 128), shader(b'SC', 64)
r2 = os.path.join(T, 'r2')
want2 = one_lib(os.path.join(r2, 'romfs', 'Paks', 'lab.utoc'), 'Lab', 'SF_GLSL_SWITCH', [S0, S1, S2],
                method_of=lambda k: 1 if k % 2 == 0 else 0)
ck(not any(f.endswith('.pak') for _, _, fs in os.walk(os.path.join(r2, 'romfs')) for f in fs),
   '② 合成根里没有一个 .pak（改前那版 ue_pak.py 与抽取门禁都看不见它）')
rc, log = run_ue_pak(os.path.join(r2, 'romfs'), os.path.join(r2, 'out'))
got = os.path.join(r2, 'out', 'ShaderArchive-IoStore-' + lib_hash('Lab', 'SF_GLSL_SWITCH').hex() + '.ushaderbytecode')
ck(rc == 0 and os.path.isfile(got), f'② 新 pack/ue_pak.py 退出 0（rc={rc}）并写出存档 {os.path.basename(got)}')
lid_hex = U.Toc(os.path.join(r2, 'romfs', 'Paks', 'lab.utoc')).ids[1].hex()
ck(f'iostore:lab.utoc@{lid_hex}' in log, f'② 日志来源串 iostore:lab.utoc@{lid_hex[:8]}…（与 pak: / kpka: 并列）')
recs = records(got) if os.path.isfile(got) else []
ck([(f, b) for f, b, _, _ in recs] == want2, f'② 拆出 {len(recs)} 支、频段与字节逐条等于合成本数（{[(f, len(b)) for f, b, _, _ in recs]}）')
ck(recs and all(s == r for _, _, s, r in recs), '② 每支存储长 = 原长（下游 shader_split.ue_shaders() 不用改）')
ck(open(got, 'rb').read()[:4] == struct.pack('<I', 2) if os.path.isfile(got) else False,
   '② 产物是版本 2 着色器代码存档（与 pak 那条同一格式）')

# ── ③ 命名：Manifest 命中 / 未命中 ─────────────────────────────────────────
r3 = os.path.join(T, 'r3')
one_lib(os.path.join(r3, 'romfs', 'a.utoc'), 'Global', 'SF_GLSL_SWITCH', [S0, S1, S2])
one_lib(os.path.join(r3, 'romfs', 'b.utoc'), 'Chunk0', 'SF_METAL', [S2, S1, S0], gseed=0x80)
open(os.path.join(r3, 'romfs', 'Manifest_UFSFiles_Switch.txt'), 'w').write(
    'Game/Content/Majesty/ShaderArchive-Global-SF_GLSL_SWITCH.ushaderbytecode\n')
rc3, log3 = run_ue_pak(os.path.join(r3, 'romfs'), os.path.join(r3, 'out'))
names3 = listing(os.path.join(r3, 'out'))
ck(rc3 == 0 and 'ShaderArchive-Global-SF_GLSL_SWITCH.ushaderbytecode' in names3,
   f'③ Manifest 列了名字 → 按名字出（{names3}）')
ck('ShaderArchive-IoStore-' + lib_hash('Chunk0', 'SF_METAL').hex() + '.ushaderbytecode' in names3,
   '③ Manifest 没列 → ShaderArchive-IoStore-<哈希>（不猜库名）')
counts = {x: len(records(os.path.join(r3, 'out', x))) for x in names3}
ck(len(names3) == 2 and all(v == 3 for v in counts.values()), f'③ 两份存档各 3 支（{counts}）')

# ── ④ Oodle 块 → 判失败 ────────────────────────────────────────────────────
r4 = os.path.join(T, 'r4')
one_lib(os.path.join(r4, 'romfs', 'oodle.utoc'), 'Oodle', 'SF_GLSL_SWITCH', [S0, S1, S2], method_of=1, methods=('Oodle',))
rc4, log4 = run_ue_pak(os.path.join(r4, 'romfs'), os.path.join(r4, 'out'))
ck(rc4 != 0, f'④ Oodle 块 → 退出非 0（rc={rc4}）')
ck('iostore:oodle.utoc' in log4 and 'Oodle' in log4 and '游戏自带解码器' in log4 and 'DM_OODLE' in log4,
   f'④ 日志点名容器、Oodle、游戏自带解码器并说明缺什么（DM_OODLE_*）：{log4.strip().splitlines()[-1][:110] if log4.strip() else "（无输出）"}')
ck(listing(os.path.join(r4, 'out')) == [], '④ 一支也没写出来（不当成功兜底）')

# ── ⑤ 反证：改前的两个入口对同一个纯 .utoc 根 ───────────────────────────────
# 11-03 起门禁经 RomFS 清单模块（graphics/nvn/tools/romfs_list.py has-ext，同 find -iname … -print -quit）；改前只认 .pak（反证用同一行去掉 .utoc 的形态）
new_gate = "[PY, NX + '/tools/romfs_list.py', 'has-ext', ROOT + '/romfs', '.pak', '.utoc']"
old_gate = "[PY, NX + '/tools/romfs_list.py', 'has-ext', ROOT + '/romfs', '.pak']"
ex_text = open(EXTRACT, encoding='utf-8').read()
ck(ex_text.count(new_gate) == 1 and old_gate not in ex_text, '⑤ extract.py 的 Unreal 包门禁是新的（.pak 或 .utoc）')
ck(subprocess.run(['find', os.path.join(r2, 'romfs'), '-iname', '*.pak', '-print', '-quit'],
                  capture_output=True, text=True).stdout == '',
   '⑤ 旧门禁谓词（只 -iname *.pak）在纯 .utoc 根上一个文件都选不出 → 旧抽取根本不跑 ue_pak.py')
ck(subprocess.run(['find', os.path.join(r2, 'romfs'), '(', '-iname', '*.pak', '-o', '-iname', '*.utoc', ')', '-print', '-quit'],
                  capture_output=True, text=True).stdout.strip().endswith('lab.utoc'),
   '⑤ 新门禁谓词选出 .utoc → 新抽取会跑 ue_pak.py')
ck(subprocess.run([sys.executable, os.path.join(H, 'graphics', 'nvn', 'tools', 'romfs_list.py'), 'has-ext', os.path.join(r2, 'romfs'), '.pak', '.utoc']).returncode == 0,
   '⑤ 新门禁（romfs_list.py has-ext .pak .utoc）认出 .utoc，与上一条 find 谓词同真假')
# 改前的 ue_pak.py：优先取 git 里的真改前文件；取不到（或已经是新版）就用「去掉新增那一步」的形态，其余逐字相同
MARK = '    ntoc, notes, iogot = iostore_archives(romfs, out, oodle, key, scan_inline=got == 0)\n'   # oodle = 游戏自带解码器（OodleDecoder，10-28 接入；没宿主时碰到 Oodle 块才报）
src = open(UE_PAK).read()
old_src, how = None, ''
try:
    b_old = subprocess.run(['git', '-C', H, 'show', 'origin/main:pack/ue_pak.py'], capture_output=True, text=True)
    if b_old.returncode == 0 and 'iostore_archives' not in b_old.stdout:
        old_src, how = b_old.stdout, 'git origin/main 的改前文件'
except Exception:
    pass
if old_src is None and MARK in src:
    old_src, how = src.replace(MARK, '    ntoc, notes, iogot = 0, [], 0\n'), '去掉新增那一步的改前形态'
ck(old_src is not None and MARK in src, f'⑤ 拿到改前的 ue_pak.py（{how}）')
old_list = []
if old_src is not None:
    # 改前文件就地跑：它按 __file__ 找 graphics/tools/shbake/pak_crypto.py，所以摆成同样的目录形状
    old_py = os.path.join(T, 'oldtree', 'pack', 'ue_pak_old.py')
    os.makedirs(os.path.dirname(old_py), exist_ok=True)
    os.makedirs(os.path.join(T, 'oldtree', 'graphics', 'tools', 'shbake'), exist_ok=True)
    shutil.copy(os.path.join(H, 'graphics', 'tools', 'shbake', 'pak_crypto.py'), os.path.join(T, 'oldtree', 'graphics', 'tools', 'shbake', 'pak_crypto.py'))
    shutil.copy(os.path.join(H, 'graphics', 'tools', 'shbake', 'unreal_pak.py'), os.path.join(T, 'oldtree', 'graphics', 'tools', 'shbake', 'unreal_pak.py'))
    shutil.copy(os.path.join(H, 'graphics', 'tools', 'shbake', 'zstd_lib.py'), os.path.join(T, 'oldtree', 'graphics', 'tools', 'shbake', 'zstd_lib.py'))   # unreal_pak 导入的 zstd 解压入口
    # ue_pak / uepak 的 RomFS 遍历经它（仓库里唯一的 RomFS 遍历）
    os.makedirs(os.path.join(T, 'oldtree', 'graphics', 'nvn', 'tools'), exist_ok=True)
    shutil.copy(os.path.join(H, 'graphics', 'nvn', 'tools', 'romfs_list.py'), os.path.join(T, 'oldtree', 'graphics', 'nvn', 'tools', 'romfs_list.py'))
    os.makedirs(os.path.join(T, 'oldtree', 'tools'), exist_ok=True); shutil.copy(os.path.join(H, 'tools', 'pool_workers.py'), os.path.join(T, 'oldtree', 'tools', 'pool_workers.py'))   # romfs_list / pak_crypto 经它取核数（#1332）
    open(old_py, 'w').write(old_src)
    rc5, log5 = run_ue_pak(os.path.join(r2, 'romfs'), os.path.join(r2, 'out_old'), old_py)
    old_list = listing(os.path.join(r2, 'out_old'))
    ck(rc5 == 0 and old_list == [], f'⑤ 改前 ue_pak.py 对纯 .utoc 根抽 0 支（rc={rc5}，写出 {len(old_list)} 个）')
    ck('写出着色器代码存档 0 个' in log5, f'⑤ 改前日志：{log5.strip().splitlines()[-1][:110] if log5.strip() else "（无输出）"}')
ck(len(recs) == 3, '⑤ 新代码对同一个根抽全部 3 支')

# ── ⑥ 出包链：真的 extract.py ──────────────────────────────────────────────
R6 = os.path.join(T, 'repo6')
for d in ('pack', 'graphics/tools/direct', 'graphics/tools/shbake', 'translator', 'graphics/nvn/tools', 'tools'):
    os.makedirs(os.path.join(R6, d), exist_ok=True)
# extract.py 判有无 Unreal 包、ue_pak / uepak 列文件都经它（仓库里唯一的 RomFS 遍历）
shutil.copy(os.path.join(H, 'graphics', 'nvn', 'tools', 'romfs_list.py'), os.path.join(R6, 'graphics', 'nvn', 'tools', 'romfs_list.py'))
os.makedirs(os.path.join(R6, 'tools'), exist_ok=True); shutil.copy(os.path.join(H, 'tools', 'pool_workers.py'), os.path.join(R6, 'tools', 'pool_workers.py'))   # 同上
shutil.copy(UE_PAK, os.path.join(R6, 'pack', 'ue_pak.py'))
shutil.copy(EXTRACT, os.path.join(R6, 'graphics', 'tools', 'direct', 'extract.py'))
shutil.copy(os.path.join(H, 'tools', 'nostall.py'), os.path.join(R6, 'tools', 'nostall.py'))   # extract.py 各步经无进展看门狗起（10-30 去固定超时）
shutil.copy(os.path.join(H, 'tools', 'progress.py'), os.path.join(R6, 'tools', 'progress.py'))   # 出包进度协议
shutil.copy(os.path.join(H, 'graphics', 'tools', 'shbake', 'pak_crypto.py'), os.path.join(R6, 'graphics', 'tools', 'shbake', 'pak_crypto.py'))
shutil.copy(os.path.join(H, 'graphics', 'tools', 'shbake', 'unreal_pak.py'), os.path.join(R6, 'graphics', 'tools', 'shbake', 'unreal_pak.py'))   # 唯一的 pak 读取实现（pack/ue_pak.py、uepak.py 都调它）
shutil.copy(os.path.join(H, 'graphics', 'tools', 'shbake', 'zstd_lib.py'), os.path.join(R6, 'graphics', 'tools', 'shbake', 'zstd_lib.py'))   # unreal_pak / shader_split 的 zstd 解压入口
shutil.copy(os.path.join(H, 'translator', 'uepak.py'), os.path.join(R6, 'translator', 'uepak.py'))
old_ex = os.path.join(R6, 'graphics', 'tools', 'direct', 'extract_old.py')
open(old_ex, 'w', encoding='utf-8').write(ex_text.replace(new_gate, old_gate))
open(os.path.join(R6, 'translator', 'shader_split.py'), 'w').write(
    "import os, sys\n"
    "d = os.environ.get('DM_UE_SHADERS', '')\n"
    "names = sorted(f for f in os.listdir(d) if f.endswith('.ushaderbytecode')) if os.path.isdir(d) else []\n"
    "open(os.environ['FAKE_CALLS'], 'a').write('split %s\\n' % ','.join(names))\n"
    "os.makedirs(sys.argv[3], exist_ok=True); open(os.path.join(sys.argv[3], 'vs.pkg'), 'w').write('p')\n"
    "for p in sys.argv[4:7]: open(p, 'w').write('# t\\n')\n")
# extract.py（10-29 起）先问运行时 GLSLC 款要不要离线编（translator/glslc_offline.py）：本例是 Unreal 款，桩答「不需要」、不出文件（同 tests/direct_profile_test.py 的合成桩）
open(os.path.join(R6, 'translator', 'glslc_offline.py'), 'w').write("print('GLSLC 离线编：不需要（合成桩）')\n")
open(os.path.join(R6, 'graphics', 'tools', 'shbake', 'nxsh_extract.py'), 'w').write(
    "import os, sys\n"
    "os.makedirs(os.path.join(sys.argv[1], 'src'), exist_ok=True); open(os.path.join(sys.argv[1], 'rows.tsv'), 'w').write('r\\n')\n")
root6 = os.path.join(T, 'root6')
os.makedirs(os.path.join(root6, 'exefs'))
one_lib(os.path.join(root6, 'romfs', 'Paks', 'chain.utoc'), 'Chain', 'SF_GLSL_SWITCH', [S0, S1, S2])
open(os.path.join(root6, 'exefs', 'main'), 'wb').write(b'\x00' * 64)
env6 = dict(os.environ, S2A_PYTHON=PY, S2A_JOBS='2', FAKE_CALLS=os.path.join(T, 'calls'))
def chain(script):
    e = os.path.join(T, 'calls')
    if os.path.exists(e):
        os.remove(e)
    r = subprocess.run([PY, script, root6, os.path.join(T, 'x6')], capture_output=True, text=True, env=env6)
    calls = open(e).read().splitlines() if os.path.exists(e) else []
    return r, [c for c in calls if c.startswith('split')], os.path.join(T, 'x6')
r_old, sp_old, x6 = chain(old_ex)
ck(r_old.returncode == 0 and not os.path.isdir(os.path.join(x6, 'ue_shaders')) and (not sp_old or sp_old[-1] == 'split '),
   f'⑥ 旧抽取门禁（只认 .pak）→ 消费方一个存档都看不到：{sp_old[-1] if sp_old else "（没跑 split）"}（rc={r_old.returncode}）')
r_new, sp_new, x6 = chain(os.path.join(R6, 'graphics', 'tools', 'direct', 'extract.py'))
ck(r_new.returncode == 0 and sp_new and sp_new[-1] != 'split ',
   f'⑥ 新抽取门禁（.pak 或 .utoc）→ 消费方拿到存档：{sp_new[-1] if sp_new else "（没跑 split）"}（rc={r_new.returncode}）')
out6 = os.path.join(x6, 'ue_shaders')
u6 = listing(out6)
ck(u6 == ['ShaderArchive-IoStore-' + lib_hash('Chain', 'SF_GLSL_SWITCH').hex() + '.ushaderbytecode']
   and [len(records(os.path.join(out6, x))) for x in u6] == [3],
   f'⑥ 出包链产物 ue_shaders/ {u6}，各 {[len(records(os.path.join(out6, x))) for x in u6] if u6 else "（）"} 支')

# ── ⑦ TOC 版本 3（UE 4.27）：没有这套 chunk 编号，不猜 ─────────────────────
r7 = os.path.join(T, 'r7')
build(os.path.join(r7, 'romfs', 'v3.utoc'), [], b'', 0, version=3, methods=())
rc7, log7 = run_ue_pak(os.path.join(r7, 'romfs'), os.path.join(r7, 'out'))
ck(rc7 == 0 and '版本 3' in log7 and 'UE 4.27' in log7 and listing(os.path.join(r7, 'out')) == [],
   '⑦ 版本 3 容器：退出 0、不写存档、日志点明版本与「着色器存档在 pak 里」')

# ── ⑧ 加密容器：密钥借同包加密 pak 从 main 里找到的那把 ─────────────────────
from pathlib import Path
r8 = os.path.join(T, 'r8'); os.makedirs(os.path.join(r8, 'exefs')); open(os.path.join(r8, 'exefs', 'main'), 'wb').write(E.nso())
os.makedirs(os.path.join(r8, 'romfs', 'Paks'))
E.make_pak(Path(r8, 'romfs', 'Paks', 'pakchunk0.pak'), [('Config/x.ini', b'synthetic')])
s8 = [shader(b'SV', 200), shader(b'SP', 300), shader(b'SC', 120)]
want8 = one_lib(os.path.join(r8, 'romfs', 'Paks', 'pakchunk1.utoc'), 'Global', 'GLSL_SWITCH', s8, method_of=lambda k: k % 2, key=E.KEY)
rc8, log8 = run_ue_pak(os.path.join(r8, 'romfs'), os.path.join(r8, 'out'))
got8 = [os.path.join(r8, 'out', x) for x in listing(os.path.join(r8, 'out'))]
ck(rc8 == 0 and len(got8) == 1 and [(fr, b) for fr, b, _, _ in records(got8[0])] == want8,
   f'⑧ 加密容器用 pak 找到的密钥解出：退出 0（rc={rc8}）、1 个存档、3 支记录逐条等于合成本')
# 改前形态：容器不带密钥打开、加密容器落进「不是 IoStore」那条跳过（其余逐字相同）；摆进 ⑤ 的改前目录形状，另带它要按路径载入的 uepak.py
KEYED = ('U.Toc(p, key)', 'if key is None and \'encrypted and no key\' in str(e): red(')
old8 = src.replace(KEYED[0], 'U.Toc(p)').replace(KEYED[1], 'if False: red(')
ck(all(k in src for k in KEYED) and old8 != src, '⑧ 拿到改前形态（Toc 不带密钥、加密容器不判红）')
if old_src is not None:
    os.makedirs(os.path.join(T, 'oldtree', 'translator'), exist_ok=True)
    shutil.copy(os.path.join(H, 'translator', 'uepak.py'), os.path.join(T, 'oldtree', 'translator', 'uepak.py'))
    old8_py = os.path.join(T, 'oldtree', 'pack', 'ue_pak_old8.py'); open(old8_py, 'w').write(old8)
    rc8o, log8o = run_ue_pak(os.path.join(r8, 'romfs'), os.path.join(r8, 'out_old'), old8_py)
    ck(rc8o == 0 and listing(os.path.join(r8, 'out_old')) == [] and 'encrypted and no key' in log8o,
       f'⑧ 反证：改前 ue_pak.py 把加密容器当「不是 IoStore」跳过、写出 0 个（rc={rc8o}）')
os.remove(os.path.join(r8, 'romfs', 'Paks', 'pakchunk0.pak'))
rc8n, log8n = run_ue_pak(os.path.join(r8, 'romfs'), os.path.join(r8, 'out_nokey'))
ck(rc8n != 0 and 'IoStore 容器加密' in log8n and listing(os.path.join(r8, 'out_nokey')) == [],
   f'⑧ 没有 pak 可借密钥：退出非 0（rc={rc8n}）、日志点名「IoStore 容器加密」、不写存档')

# ── ⑨ 导出数据里的内嵌着色器（UE5 不开共享库）──────────────────────────────
import lz4.block
P = load(UE_PAK, 'ue_pak_new')
def lslg(tag, size): return b'LSLG' + tag + bytes([0x11 * (size % 7 + 1)]) * (size - 6)
def entry(rec, fr, stream=None):
    st = stream if stream is not None else lz4.block.compress(rec, store_size=False)
    return struct.pack('<i', len(st)) + st + struct.pack('<iB', len(rec), fr)
s9 = [(0, lslg(b'SV', 700)), (3, lslg(b'SP', 900)), (5, lslg(b'SC', 500))]
exp9 = b'\x00' * 40 + entry(s9[0][1], 0) + entry(s9[1][1], 3) + b'\x07' * 33 + entry(s9[2][1], 5) + b'\x00' * 20   # 导出数据：条目前后夹别的序列化字节
r9 = os.path.join(T, 'r9'); u9 = os.path.join(r9, 'romfs', 'Paks', 'pakchunk0.utoc')
build(u9, [(cid(bytes(range(0x30, 0x38)), 0, 1), 0, len(exp9))], exp9, 1)
rc9, log9 = run_ue_pak(os.path.join(r9, 'romfs'), os.path.join(r9, 'out'))
got9 = listing(os.path.join(r9, 'out'))
ck(rc9 == 0 and got9 == ['ShaderArchive-IoStoreInline-pakchunk0.ushaderbytecode']
   and sorted((fr, b) for fr, b, _, _ in records(os.path.join(r9, 'out', got9[0]))) == sorted(s9),
   f'⑨ 导出数据内嵌：退出 0（rc={rc9}）、写出 {got9}、3 支逐条等于合成本')
if old_src is not None:
    INL = '        if not libs and scan_inline:\n'   # 改前形态：没有导出数据内嵌这一步（其余逐字相同）
    ck(INL in src, '⑨ 拿到改前形态（去掉导出数据内嵌那一步）')
    old9_py = os.path.join(T, 'oldtree', 'pack', 'ue_pak_old9.py'); open(old9_py, 'w').write(src.replace(INL, '        if False:\n'))
    rc9o, log9o = run_ue_pak(os.path.join(r9, 'romfs'), os.path.join(r9, 'out_old'), old9_py)
    ck(rc9o == 0 and listing(os.path.join(r9, 'out_old')) == [] and '没有着色器代码库' in log9o,
       f'⑨ 反证：改前 ue_pak.py 只记「没有着色器代码库」、写出 0 个（rc={rc9o}）')

# ── ⑩ Oodle 条目 + 吞后一支的假长度 ──────────────────────────────────────────
def ostream(payload): return b'\x8c\x0a' + (len(payload) - 1).to_bytes(3, 'big') + payload   # 一块非存储块：块头 + 量子头（低 18 位 = 压缩长 - 1）
r10 = [lslg(b'SV', 3000), lslg(b'SP', 2600), lslg(b'SC', 1800)]
pay = [r10[0][:400], None, r10[2][:300]]
e1 = entry(r10[0], 0, ostream(pay[0])); e3 = entry(r10[2], 5, ostream(pay[2]))
# 第 2 支的流：6 字节杂项 + 记录头；杂项前 4 字节当长度读 = 从它后面一直到第 3 支原长字段前（假候选的「原长 / 阶段」恰好是第 3 支的），后 2 字节像 Oodle 块头
head2 = r10[1][:350]; s2_len = 5 + 6 + len(head2)
fake_n = (4 + s2_len + 5) - (4 + 5 + 4) + 4 + len(ostream(pay[2]))   # 假条目起点 = 第 2 支流内 +5 → 终点 = 第 3 支原长字段
pay[1] = struct.pack('<i', fake_n) + b'\x8c\x0a' + head2
e2 = entry(r10[1], 3, ostream(pay[1]))
d10 = e1 + e2 + e3
fi = len(e1) + 4 + 5; ck(struct.unpack_from('<i', d10, fi)[0] == fake_n and d10[fi + 4 + fake_n:fi + 4 + fake_n + 5] == struct.pack('<iB', len(r10[2]), 5),
                         '⑩ 夹具自检：假长度从第 2 支流内起、正好落到第 3 支的原长 / 阶段字段')
table = {ostream(pay[k]): r10[k] for k in range(3)}; fed = []
def fake_oodle(b, n):
    fed.append(bytes(b))
    if bytes(b) not in table: raise P.Unsupported('替身：不是夹具里的真流')   # 同 OodleDecoder：解不出 / 长度不符就抛
    return table[bytes(b)]
got10 = P.inline_entries(d10, fake_oodle)
ck([b for _, b in got10] == r10 and [fr for fr, _ in got10] == [0, 3, 5] and sorted(fed) == sorted(table),
   f'⑩ Oodle 条目：3 支全出（实得 {len(got10)}）、解码器只收到 3 条真流（实收 {len(fed)} 条，其中假候选 {sum(b not in table for b in fed)} 条）')

# ── ⑪ 补丁容器的着色器库：组跨容器取、同号库以补丁为准 ───────────────────────
r11 = os.path.join(T, 'r11'); d11 = os.path.join(r11, 'romfs', 'Paks')
sA, sB, sC, sD = shader(b'SV', 200), shader(b'SP', 300), shader(b'SC', 120), shader(b'SP', 260)
one_lib(os.path.join(d11, 'g.utoc'), 'Global', 'GLSL_SWITCH', [sA, sB, sC])   # 本体：组 0 = A+B、组 1 = C
gid0 = cid(bytes(range(0x10, 0x18)), 0, CODE); gidp = cid(bytes(range(0x40, 0x48)), 2, CODE); g0 = sA + sB
b11 = blob([bytes(range(20))], [bytes([i]) * 20 for i in range(3)], [gid0, gidp], [(0, 3)],
           [ent(0, 0, 0), ent(3, 0, len(sA)), ent(5, 1, 0)], [(0, 2, len(g0), len(g0)), (2, 1, len(sD), len(sD))], [0, 1, 2])
lid = cid(lib_hash('Global', 'GLSL_SWITCH'), 0, LIB)
build(os.path.join(d11, 'g_0_P.utoc'), [(lid, 0, len(b11)), (gidp, len(b11), len(sD))], b11 + sD, 0)   # 补丁：同号库，组 0 不带
rc11, log11 = run_ue_pak(os.path.join(r11, 'romfs'), os.path.join(r11, 'out'))
got11 = listing(os.path.join(r11, 'out'))
ck(rc11 == 0 and len(got11) == 1 and [(fr, b) for fr, b, _, _ in records(os.path.join(r11, 'out', got11[0]))] == [(0, sA), (3, sB), (5, sD)],
   f'⑪ 补丁里的库：退出 0（rc={rc11}）、写出 {got11}、3 支 = 本体组 0 两支 + 补丁新一支')
o11 = os.path.join(T, 'oldtree11'); okold = True
for f in ('pack/ue_pak.py', 'translator/uepak.py', 'graphics/tools/shbake/unreal_pak.py', 'graphics/tools/shbake/pak_crypto.py', 'graphics/tools/shbake/zstd_lib.py'):
    r = subprocess.run(['git', '-C', H, 'show', f'611abc308:{f}'], capture_output=True)   # 改前 = 本笔之前那一提交（取不到就不做这一项反证）
    okold = okold and r.returncode == 0 and b'io_priority' not in r.stdout
    os.makedirs(os.path.dirname(os.path.join(o11, f)), exist_ok=True); open(os.path.join(o11, f), 'wb').write(r.stdout)
if okold:
    rc11o, log11o = run_ue_pak(os.path.join(r11, 'romfs'), os.path.join(r11, 'out_old'), os.path.join(o11, 'pack', 'ue_pak.py'))
    ck(rc11o != 0 and 'has no chunk' in log11o, f'⑪ 反证：改前 ue_pak.py 退出非 0（rc={rc11o}）、日志点名「has no chunk」')

# ── ⑬ TOC 版本 2：导出块类型 2 ───────────────────────────────────────────
r13 = os.path.join(T, 'r13'); u13 = os.path.join(r13, 'romfs', 'Paks', 'pakchunk0-Switch.utoc')
build(u13, [(cid(bytes(range(0x50, 0x58)), 0, 2), 0, len(exp9))], exp9, 1, version=2)
rc13, log13 = run_ue_pak(os.path.join(r13, 'romfs'), os.path.join(r13, 'out'))
got13 = listing(os.path.join(r13, 'out'))
ck(rc13 == 0 and got13 == ['ShaderArchive-IoStoreInline-pakchunk0-Switch.ushaderbytecode']
   and sorted((fr, b) for fr, b, _, _ in records(os.path.join(r13, 'out', got13[0]))) == sorted(s9),
   f'⑬ TOC 版本 2、导出块类型 2：退出 0（rc={rc13}）、写出 {got13}、3 支逐条等于合成本')

# ── ⑭ pak 已出存档就不扫 IoStore 导出 ───────────────────────────────────────
r14 = os.path.join(T, 'r14'); os.makedirs(os.path.join(r14, 'romfs', 'Paks'))
E.make_pak(Path(r14, 'romfs', 'Paks', 'a.pak'), [('ShaderArchive-Test.ushaderbytecode', E.shader_archive(lslg(b'SV', 400), compressed=False))], encrypted=False)
build(os.path.join(r14, 'romfs', 'Paks', 'a.utoc'), [(cid(bytes(range(0x60, 0x68)), 0, 1), 0, len(exp9))], exp9, 1, methods=('Oodle',))   # 块方法 1 = Oodle：没宿主，真去解就红
rc14, log14 = run_ue_pak(os.path.join(r14, 'romfs'), os.path.join(r14, 'out'))
ck(rc14 == 0 and listing(os.path.join(r14, 'out')) == ['ShaderArchive-Test.ushaderbytecode'],
   f'⑭ pak 已出存档：不扫 IoStore 导出（rc={rc14}，写出 {listing(os.path.join(r14, "out"))}）')

# ── ⑫ 补丁只换本体库的一个组 ─────────────────────────────────────────────────
r12 = os.path.join(T, 'r12'); d12 = os.path.join(r12, 'romfs', 'Paks')
one_lib(os.path.join(d12, 'g.utoc'), 'Global', 'GLSL_SWITCH', [sA, sB, sC])   # 本体：库 + 组 0（A+B）+ 组 1（C）
sA2, sB2 = shader(b'SV', 200).replace(b'\x48', b'\x49'), shader(b'SP', 300).replace(b'\x6c', b'\x6d')   # 同长、内容不同的新版
ck(len(sA2) == len(sA) and len(sB2) == len(sB) and (sA2, sB2) != (sA, sB), '⑫ 夹具自检：新版组 0 与旧版同长、内容不同')
build(os.path.join(d12, 'g_0_P.utoc'), [(gid0, 0, len(sA2 + sB2))], sA2 + sB2, 0)   # 补丁：只有组 0 的新版
rc12, log12 = run_ue_pak(os.path.join(r12, 'romfs'), os.path.join(r12, 'out'))
got12 = listing(os.path.join(r12, 'out'))
ck(rc12 == 0 and len(got12) == 1 and [(fr, b) for fr, b, _, _ in records(os.path.join(r12, 'out', got12[0]))] == [(0, sA2), (3, sB2), (5, sC)],
   f'⑫ 补丁只换组 0：退出 0（rc={rc12}）、组 0 两支取补丁新版、组 1 照旧')

shutil.rmtree(T, ignore_errors=True)
print(f'期望 IoStore 容器接入出包链 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
