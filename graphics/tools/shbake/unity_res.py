# Unity 资源里的着色器（nxsh_extract.py 用；10-21 pair，空洞骑士：丝之歌）：
#   - UnityFS 资源包（Addressables 的 *.bundle：块信息 + 数据块各自 LZ4 / LZ4HC，解出里面的序列化文件）；
#   - 序列化文件（v17+）：类型表（可带类型树）+ 对象表；Shader 对象（类 48）按类型树通用读出（只靠字段名 / 字节大小 / 数组位 / 对齐位，不用类型名表）；
#     播放器数据（Data/*.assets、Data/Resources/*）不带类型树：借同版本资源包里 Shader 的类型树读（同一次构建，布局相同）。
#   - Shader.compressedBlob 按平台 / 分段 LZ4 解开 = 代码块：u32 条目数 + 条目数 × (偏移, 长度, 段号) + 数据。NVN 平台每个条目 = 一个完整程序（vs + ps 的 GLSLC 产物在同一条目里；
#     pass 的 progVertex.m_PlayerSubPrograms 指条目号、progFragment 为空）。条目里的着色器照常按「控制段 + 机器码相邻」认。
# 来源记 unity:<文件>[//<包内文件>]@<对象 ID>#<平台>.<分段>、变体号 = 条目号：shbake 的「# 变体组」规则把同一条目的 vs + ps 配成程序。
# 读数（10-21）：234 个 Shader 对象（73 个借类型树）、1274 个 vs+ps 条目 → 1186 个程序 / 2373 支着色器；7 局 Mac 真值 43 个图形程序 43/43（旧抽取 0/43：着色器全在 LZ4 里）。
import struct, lz4.block
def _cstr(d, p):
    e = d.find(b'\0', p)   # find：字节串 / 只读映射都有（mmap 没有 index）
    if e < 0: raise ValueError('字符串没有结尾')
    return d[p:e].decode('latin-1'), e + 1
def is_bundle(head): return head[:8] == b'UnityFS\0'
def _bundle_block(raw, method, size, kind):
    """解一块；UnityFS LZMA 是5字节属性+raw流，原长在块表而非流头。"""
    if method == 0: return raw
    if method in (2, 3): return lz4.block.decompress(raw, uncompressed_size=size)
    if method != 1:
        name = 'LZHAM' if method == 4 else '未知'
        raise ValueError(f'{kind}压缩方式 {method}（{name}）')
    import lzma
    if len(raw) < 5: raise ValueError(f'{kind} LZMA 属性截断')
    # 布局参照（仅读，无复制）：UnityPy@417d5952 helpers/CompressionHelper.py；
    # Python标准库lzma的FORMAT_RAW/LZMA1；此处独立加原长限额与错误检查。
    prop = raw[0]
    lc, lp, pb = prop % 9, (prop // 9) % 5, prop // 45
    if prop >= 225 or lc + lp > 4:
        raise ValueError(f'{kind} LZMA 属性不支持')
    dictionary = struct.unpack_from('<I', raw, 1)[0]
    # 一块内距离不可能超过该块原长；避免小块的畸形属性申请数GiB字典。
    dictionary = max(4096, min(dictionary, max(4096, size)))
    try:
        decoder = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[{
            'id': lzma.FILTER_LZMA1, 'dict_size': dictionary,
            'lc': lc, 'lp': lp, 'pb': pb}])
        decoded = decoder.decompress(raw[5:], max_length=size + 1)
    except lzma.LZMAError as error:
        raise ValueError(f'{kind} LZMA 解压失败') from error
    if len(decoded) != size:
        raise ValueError(f'{kind} LZMA 解出长度 {len(decoded)} != 声明原长 {size}')
    # 已知原长的raw流可以没有EOS；有EOS时不接受拼接流/尾随数据。
    if decoder.eof and decoder.unused_data:
        raise ValueError(f'{kind} LZMA 尾随数据')
    return decoded
STREAMS = ('.resS', '.resource')   # 包内的贴图 / 音频流：原始字节、从不是序列化文件，常占包的大头
def read_bundle(d):
    """UnityFS → {包内文件名: 字节}（全部节点；抽取用 iter_bundle，一次只占一个节点）"""
    return dict(iter_bundle(d, skip=()))
def iter_bundle(d, skip=STREAMS):
    """UnityFS → 逐个 (包内文件名, 字节)，名字以 skip 结尾的跳过。只解这个节点覆盖到的块（上一块留着给下一个节点），内存里只有一个节点，
    不是整包解开再每个节点复制一份（v0.3.0 Windows 8 GB 机：3.45 GB 的 Unity 游戏 data.unity3d 第一个文件就 MemoryError）。d 可以是字节或只读映射"""
    if d[:8] != b'UnityFS\0': raise ValueError('不是 UnityFS')
    ver = struct.unpack_from('>I', d, 8)[0]; p = 12
    _, p = _cstr(d, p); _, p = _cstr(d, p)
    size, csz, usz, flags = struct.unpack_from('>QIII', d, p); p += 20
    if ver >= 7: p = (p + 15) & ~15
    bi = d[len(d) - csz:] if flags & 0x80 else d[p:p + csz]
    if not flags & 0x80: p += csz
    c = flags & 0x3f
    bi = _bundle_block(bi, c, usz, '块信息')
    q = 16; nb = struct.unpack_from('>I', bi, q)[0]; q += 4; blocks = []
    for _ in range(nb): u, cc, fl = struct.unpack_from('>IIH', bi, q); q += 10; blocks.append((u, cc, fl))
    nn = struct.unpack_from('>I', bi, q)[0]; q += 4; nodes = []
    for _ in range(nn):
        off, sz, fl = struct.unpack_from('>QQI', bi, q); q += 20; name, q = _cstr(bi, q); nodes.append((off, sz, name))
    if flags & 0x200: p = (p + 15) & ~15
    import bisect
    starts, at, u0 = [], [], 0
    for u, cc, fl in blocks: starts.append(u0); at.append(p); u0 += u; p += cc
    last = [None, b'']
    def block(i):
        if last[0] != i:
            last[1] = b''   # 先放掉上一块再解下一块
            u, cc, fl = blocks[i]; last[0], last[1] = i, _bundle_block(d[at[i]:at[i] + cc], fl & 0x3f, u, '数据块')
        return last[1]
    for off, sz, name in nodes:
        if skip and name.endswith(skip): continue
        parts, pos, end, i = [], off, off + sz, max(0, bisect.bisect_right(starts, off) - 1)
        while pos < end and i < len(blocks):
            b = block(i); take = b[pos - starts[i]:min(end, starts[i] + len(b)) - starts[i]]
            parts.append(take); pos += len(take); i += 1
        yield name, b''.join(parts)
class _Node:
    __slots__ = ('level', 'flags', 'name', 'size', 'meta', 'kids')
def parse_serialized(b):
    """序列化文件（v17–40）→ ([(对象 ID, 类 ID, 类型树根或 None, 起, 长)], 字节序)。不认识的格式抛异常"""
    ms, fs, ver, do = struct.unpack_from('>IIII', b, 0)
    if ver < 17 or ver > 40: raise ValueError(f'序列化文件版本 {ver}')
    # 布局来源：AssetStudio SerializedFile/SerializedFileFormatVersion（MIT，仅读格式）。
    # 17–21 沿用20字节头；22起扩展头中的文件长/数据偏移才是64位。
    p = 20
    if ver >= 22: ms, fs, do, _ = struct.unpack_from('>IQQQ', b, 20); p = 48
    if not p <= do <= len(b): raise ValueError('数据偏移越界')
    E = '>' if b[16] else '<'
    p = b.index(b'\0', p) + 1 + 4; tt = b[p]; p += 1
    nt = struct.unpack_from(E + 'i', b, p)[0]; p += 4; types = []
    if nt < 0 or nt > (do - p) // 23: raise ValueError('类型表长度不合理')
    for _ in range(nt):
        cid, strip, sti = struct.unpack_from(E + 'iBh', b, p); p += 7
        if cid == 114: p += 16   # 这里是普通类型表，非引用类型表；script ID 只随 MonoBehaviour
        p += 16; root = None
        if tt:
            nn, sb = struct.unpack_from(E + 'ii', b, p); p += 8; rec = 32 if ver >= 19 else 24
            if nn < 0 or sb < 0 or nn * rec + sb > do - p: raise ValueError('类型树长度不合理')
            raw = [struct.unpack_from(E + 'HBBIIiii', b, p + i * rec) for i in range(nn)]; p += nn * rec
            sbuf = b[p:p + sb]; p += sb; stack = []
            for v, lvl, fl, to, no, sz, idx, meta in raw:
                n = _Node(); n.level, n.flags, n.size, n.meta, n.kids = lvl, fl, sz, meta, []
                n.name = '#%x' % (no & 0x7fffffff) if no & 0x80000000 else sbuf[no:sbuf.index(b'\0', no)].decode('latin-1')
                while stack and stack[-1].level >= lvl: stack.pop()
                if stack: stack[-1].kids.append(n)
                else: root = n
                stack.append(n)
            if ver >= 21:
                n2 = struct.unpack_from(E + 'i', b, p)[0]; p += 4
                if n2 < 0 or n2 > (do - p) // 4: raise ValueError('类型依赖长度不合理')
                p += 4 * n2
        types.append((cid, root))
    no = struct.unpack_from(E + 'i', b, p)[0]; p += 4; objs = []
    rec = 24 if ver >= 22 else 20
    if no < 0 or no > (do - p) // rec: raise ValueError('对象表长度不合理')
    for _ in range(no):
        p = (p + 3) & ~3
        pid, st, sz, ti = struct.unpack_from(E + ('qqIi' if ver >= 22 else 'qIIi'), b, p); p += rec
        if not 0 <= ti < len(types): raise ValueError('对象类型索引越界')
        if st < 0 or st + sz > len(b) - do: raise ValueError('对象数据越界')
        objs.append((pid, types[ti][0], types[ti][1], do + st, sz))
    return objs, E
def read_obj(b, p, n, E):
    """按类型树读：数组 → 列表（单字节元素 → bytes），无子节点 → 原子（4 字节读成整数），其余 → dict"""
    if n.flags & 1:
        cnt = struct.unpack_from(E + 'i', b, p)[0]; p += 4; el = n.kids[1]
        if cnt < 0 or cnt > len(b): raise ValueError('数组长度不合理')
        if el.size == 1 and not el.kids: v = b[p:p + cnt]; p += cnt
        elif el.size == 4 and not el.kids: v = list(struct.unpack_from(E + f'{cnt}I', b, p)); p += 4 * cnt
        else:
            v = []
            for _ in range(cnt): x, p = read_obj(b, p, el, E); v.append(x)
    elif not n.kids:
        v = b[p:p + n.size]; p += n.size
        if n.size == 4: v = struct.unpack(E + 'I', v)[0]
    elif len(n.kids) == 1 and n.kids[0].flags & 1:
        v, p = read_obj(b, p, n.kids[0], E)
        if n.kids[0].meta & 0x4000: p = (p + 3) & ~3
    else:
        v = {}
        for k in n.kids: v[k.name], p = read_obj(b, p, k, E)
    if n.meta & 0x4000: p = (p + 3) & ~3
    return v, p
def shader_entries(b, tt_cache, stat):
    """序列化文件里每个 Shader 的代码块条目：yield (对象 ID, 平台号, 分段号, 条目号, 条目字节)。tt_cache = [Shader 类型树]（先读资源包，借给不带类型树的文件）"""
    try: objs, E = parse_serialized(b)
    except ValueError as error:
        # scan_unity 保留原失败计数；具体版本在同一 Counter 里可见，不吞错当空成功。
        if str(error).startswith('序列化文件版本 '): stat[str(error)] += 1
        raise
    for pid, cid, rt, st, sz in objs:
        if cid != 48: continue
        if rt is None: rt = tt_cache[0]; stat['Unity Shader 借类型树'] += 1
        elif tt_cache[0] is None: tt_cache[0] = rt
        if rt is None: stat['Unity Shader 没有类型树可用（跳过）'] += 1; continue
        try:
            v, p = read_obj(b, st, rt, E)
            if p != st + sz: raise ValueError('按类型树没读到对象尾')
        except Exception: stat['Unity Shader 读失败'] += 1; continue
        stat['Unity Shader'] += 1
        # 2019.3前：类型树给出一维数组，每平台一个段，条目表是(offset,length)。
        # 不由文件格式号猜引擎版本；只把实际读到的一维字段包成单元素段。
        flat = bool(v.get('offsets')) and isinstance(v['offsets'][0], int)
        if flat:
            for key in ('offsets', 'compressedLengths', 'decompressedLengths'):
                v[key] = [[x] for x in v[key]]
        for pi in range(len(v.get('platforms', []))):
            for si, off in enumerate(v['offsets'][pi]):
                try: blob = lz4.block.decompress(v['compressedBlob'][off:off + v['compressedLengths'][pi][si]], uncompressed_size=v['decompressedLengths'][pi][si])
                except Exception: stat['Unity 代码块解压失败'] += 1; continue
                n = struct.unpack_from('<I', blob, 0)[0]
                rec = 8 if flat else 12
                if 4 + rec * n > len(blob): stat['Unity 代码块条目表不认识'] += 1; continue
                for i in range(n):
                    o, l = struct.unpack_from('<II', blob, 4 + rec * i)
                    if o + l <= len(blob): yield pid, v['platforms'][pi], si, i, blob[o:o + l]
