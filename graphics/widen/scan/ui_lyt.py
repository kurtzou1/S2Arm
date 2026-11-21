#!/usr/bin/env python3
"""通用宽屏 · 出包时改界面布局（任天堂 SDK 界面库 nn::ui2d 的 .bflyt，只认格式通用特征、不按游戏）：
铺满整张画布的背景底，只在加宽后不会横向拉伸任何贴图内容时才把宽从画布宽改成屏幕宽（10-21 口径「原生满屏不拉伸，没得补就留黑边」）——只有两类：
  · 纯色底（没有贴图）：加宽只是多涂同一种颜色；
  · 所有贴图层真平铺（每层贴图 SRT 横向缩放 > 1，一张画布里贴图真的重复多遍）：缩放同比放大 k 倍——纹理周期不变、接着平铺。
只要有一层 SRT 横向缩放 ≤ 1（贴图只铺一遍；部分平铺也算）就不加宽：加宽而 SRT 不动 = 那层贴图横向拉伸 k 倍；这类页面中间原样，两侧是下层内容或黑边。
包装层把界面 16:9 投影改回原尺寸后，加宽的底正好落到屏幕两边。

认哪些控件（全部满足才改）：
  · 图片控件 pic1，尺寸 = 画布尺寸（lyt1），平移 ≤ 2 个画布单位（动森捏脸页纸纹底在 (−1, 0)）；祖先控件全是单位变换（平移 0、旋转 0、缩放 1）——真的贴满四边
  · 材质每个贴图槽横向寻址都是平铺（repeat / mirror），且有贴图 SRT（才有地方同比放大）；没有贴图的纯色底直接加宽
  · 材质只被这类控件用（共用材质的别的控件会被一起放大，跳过并报出来）
  · 同一个包里没有动画（.bflan）按名字驱动它的控件变换 / 尺寸（FLPA）或贴图 SRT（FLTS）——动画会在运行时把改过的值盖回去
k = (屏幕宽 ÷ 1080) ÷ (画布宽 ÷ 画布高)；新宽 = 画布宽 × k；SRT 横向缩放 × k。文件长度不变（原位改浮点）。

用法：ui_lyt.py <romfs 目录> <输出覆盖层目录> <屏幕宽 W（1080 高对应）> [子目录，逗号分隔，缺省 Layout,UI,Pack 里存在的]
递归处理 romfs/<子目录> 下的包，按魔数认 zstd / Yaz0（.szs / .sblarc）/ 裸 SARC，含套娃包；只写有改动的包（Yaz0 写回只用字面量，合法、略大）；最后打印改了哪些控件与分类计数。"""
import concurrent.futures as cf, os, shutil, struct, subprocess, sys, tempfile
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk，listdir 同 os.listdir）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'nvn', 'tools')); import romfs_list

PANES = {b'pan1', b'pic1', b'txt1', b'wnd1', b'bnd1', b'prt1', b'ali1', b'scr1'}
TILING = (1, 2)   # 贴图槽寻址低 2 位：0 clamp、1 repeat、2 mirror

def mat_layout(d, m, ntxl):
    """材质：名字 28 字节后是标志字（低 2 位贴图槽数、再 2 位 SRT 数）。v8/v9 两种头长（40 / 44），按贴图槽是否自洽认。返回 (贴图槽起点, 槽数, SRT 数) 或 None。"""
    for flags_at, tm_at in ((28, 44), (36, 40)):
        flags, = struct.unpack_from('<I', d, m + flags_at); nt, ns = flags & 3, (flags >> 2) & 3
        if all(struct.unpack_from('<H', d, m + tm_at + 4 * i)[0] < ntxl and d[m + tm_at + 4 * i + 2] < 16 for i in range(nt)):
            return m + tm_at, nt, ns
    return None

def patch_flyt(b, o, n, W, log, where, animated=frozenset()):
    if b[o:o + 4] != b'FLYT' or b[o + 4:o + 6] != b'\xff\xfe': return 0
    hs, = struct.unpack_from('<H', b, o + 6); ns, = struct.unpack_from('<H', b, o + 0x10)
    LW = LH = None; ntxl = 0; mats = []; panes = []; depth = 0; ident = [True] * 64; last_ident = True
    p = o + hs
    for _ in range(ns):
        if p + 8 > o + n: break
        mg = bytes(b[p:p + 4]); sz, = struct.unpack_from('<I', b, p + 4)
        if mg == b'lyt1': LW, LH = struct.unpack_from('<ff', b, p + 0xC)
        elif mg == b'txl1': ntxl, = struct.unpack_from('<H', b, p + 8)
        elif mg == b'mat1':
            cnt, = struct.unpack_from('<H', b, p + 8)
            for off in struct.unpack_from('<%dI' % cnt, b, p + 0xC): mats.append(p + off)
        elif mg == b'pas1':
            depth += 1
            if depth < 64: ident[depth] = ident[depth - 1] and last_ident
        elif mg == b'pae1': depth -= 1
        elif mg in PANES and sz >= 0x54:
            tx, ty = struct.unpack_from('<ff', b, p + 0x2C); rot = struct.unpack_from('<3f', b, p + 0x38); sx, sy = struct.unpack_from('<ff', b, p + 0x44)
            w, h = struct.unpack_from('<ff', b, p + 0x4C); name = bytes(b[p + 0xC:p + 0xC + 24]).split(b'\0')[0].decode('ascii', 'replace')
            here = abs(tx) <= 2 and abs(ty) <= 2 and not any(rot) and sx == 1 and sy == 1
            last_ident = here
            if mg == b'pic1':
                mi, = struct.unpack_from('<H', b, p + 0x54 + 16)
                full = LW is not None and w == LW and h == LH and here and (depth < 1 or ident[min(depth, 63)])
                panes.append((p, name, mi, full))
        if sz == 0: break
        p += sz
    if LW is None or not panes: return 0
    k = (W / 1080.0) / (LW / LH)
    if k <= 1.0001: return 0
    users = {}
    for _, _, mi, full in panes: users.setdefault(mi, []).append(full)
    ch = 0
    for pp, name, mi, full in panes:
        if not full or mi >= len(mats): continue
        lay = mat_layout(b, mats[mi], ntxl)
        if lay is None: log.append(f'  跳过 {where} {name}：材质格式认不出'); continue
        tm, nt, nsrt = lay
        if nt == 0:   # 纯色底：也在数据层加宽（显卡层按画布边 ±ε 推，偏了 1 个单位的底推不到——动森捏脸页奶油底在 (−1, 0)，右缘 959 没被推，上面半透明纸纹就压在黑底上成了暗橄榄）
            if not all(users[mi]): log.append(f'  跳过 {where} {name}：材质与不铺满画布的控件共用'); continue
            struct.pack_into('<f', b, pp + 0x4C, LW * k); log.append(f'  改 {where} {name}：宽 {LW:g} → {LW * k:.1f}，纯色底'); ch += 1; continue
        if nsrt == 0: continue
        if not all((b[tm + 4 * i + 2] & 3) in TILING for i in range(nt)): log.append(f'  不改 {where} {name}：整画布但贴图不平铺（夹边），留显卡层'); continue   # 加宽会拖出边缘像素
        if not all(users[mi]): log.append(f'  跳过 {where} {name}：材质与不铺满画布的控件共用'); continue
        mname = bytes(b[mats[mi]:mats[mi] + 28]).split(b'\0')[0].decode('ascii', 'replace')
        if name in animated or mname in animated: log.append(f'  跳过 {where} {name}：同包动画驱动它的变换或贴图 SRT'); continue
        srt = tm + 4 * nt
        sxs = [struct.unpack_from('<f', b, srt + 20 * i + 12)[0] for i in range(nsrt)]
        rep = [abs(v) > 1.0001 for v in sxs]   # 逐层判：横向缩放 > 1 的贴图层在一张画布里真重复多遍，同比放大缩放 → 接着平铺、不拉伸；≤ 1 的层只铺一遍，加宽就是横向拉伸
        sv = ",".join("%g" % v for v in sxs)
        if not all(rep):
            # 只铺一遍 / 部分平铺：有一层加宽就被横向拉伸 k 倍，整个控件不加宽（两侧露下层内容或黑边）
            kind = '部分平铺' if any(rep) else '只铺一遍'
            log.append(f'  不加宽 {where} {name}：{kind}（SRT 横向缩放 {sv}，≤1 的层加宽会被横向拉伸 {k:.4f} 倍），两侧留给下层内容或黑边'); continue
        for i in range(nsrt): struct.pack_into('<f', b, srt + 20 * i + 12, sxs[i] * k)
        struct.pack_into('<f', b, pp + 0x4C, LW * k)
        log.append(f'  改 {where} {name}：宽 {LW:g} → {LW * k:.1f}，贴图 SRT 横向缩放 × {k:.4f}（{nsrt} 组，原 {sv}，真平铺、不拉伸）'); ch += 1
    return ch

def sarc_rebuild(b, repl):
    """按 repl {节点序号: 新内容} 重排 SARC 数据区：节点顺序、名字表不动，各文件按原绝对偏移的对齐（2 的幂，≤ 0x2000）重新放，改起止与总长。"""
    doff, = struct.unpack_from('<I', b, 0xC); hs, = struct.unpack_from('<H', b, 4); nn, = struct.unpack_from('<H', b, hs + 6)
    nodes = [list(struct.unpack_from('<IIII', b, hs + 0xC + 16 * i)) for i in range(nn)]
    out = bytearray(b[:doff]); pos = doff
    for i in sorted(range(nn), key=lambda i: nodes[i][2]):
        s, e = nodes[i][2], nodes[i][3]; data = repl.get(i, bytes(b[doff + s:doff + e]))
        a = 0x2000
        while a > 4 and (doff + s) % a: a >>= 1
        while pos % a: out.append(0); pos += 1
        nodes[i][2], nodes[i][3] = pos - doff, pos - doff + len(data); out += data; pos += len(data)
    for i, n in enumerate(nodes): struct.pack_into('<IIII', out, hs + 0xC + 16 * i, *n)
    struct.pack_into('<I', out, 8, len(out))
    return out

def patch_sarc(b, W, log, where):
    """原位改 SARC（含套娃）；里面套的 Yaz0 包有改动时要变长，整包重排。返回 (改动数, 重排后的新包或 None)。"""
    if b[:4] != b'SARC': return 0, None
    doff, = struct.unpack_from('<I', b, 0xC); hs, = struct.unpack_from('<H', b, 4)
    nn, = struct.unpack_from('<H', b, hs + 6); ch = 0; repl = {}
    sfnt = hs + 0xC + 16 * nn; names = bytes(b[sfnt + 8:doff])
    animated = set()   # 同包动画里带 FLPA / FLTS 曲线时引用到的名字（保守：整份动画里出现的控件 / 材质名都算）
    for i in range(nn):
        _, _, s, e = struct.unpack_from('<IIII', b, hs + 0xC + 16 * i); d = bytes(b[doff + s:doff + e])
        if d[:4] == b'FLAN' and (b'FLPA' in d or b'FLTS' in d):
            for tok in d.split(b'\0'):
                t = tok[-24:]
                if 3 <= len(t) and all(32 < c < 127 for c in t): animated.add(t.decode('ascii'))
    for i in range(nn):
        _, attr, s, e = struct.unpack_from('<IIII', b, hs + 0xC + 16 * i)
        nm = names[(attr & 0xffffff) * 4:].split(b'\0')[0].decode('utf-8', 'replace') if attr >> 24 else str(i)
        head = bytes(b[doff + s:doff + s + 4])
        if head == b'FLYT': ch += patch_flyt(b, doff + s, e - s, W, log, f'{where}/{nm}', animated)
        elif head == b'SARC':
            inner = bytearray(b[doff + s:doff + e]); c, rb = patch_sarc(inner, W, log, f'{where}/{nm}')
            if rb is not None: repl[i] = bytes(rb); ch += c
            elif c: b[doff + s:doff + e] = inner; ch += c
        elif head == b'Yaz0':   # 包里套 Yaz0 压缩包（塞尔达 Bootup.pack → Layout/Common.sblarc）：改了就重压；不比原来长就补零原位写回，外层包长度不变
            src = bytes(b[doff + s:doff + e]); inner = bytearray(yaz0_dec(src)); c, rb = patch_sarc(inner, W, log, f'{where}/{nm}')
            if c:
                z = yaz0_pack(bytes(rb if rb is not None else inner), src[:16]); ch += c
                starts = [struct.unpack_from('<I', b, hs + 0xC + 16 * j + 8)[0] for j in range(nn)]
                room = min([x for x in starts if x > s] + [len(b) - doff]) - s   # 到下一个文件起点的空间（含对齐留空）
                if len(z) <= len(src): b[doff + s:doff + e] = z + bytes(len(src) - len(z))
                elif len(z) <= room: b[doff + s:doff + s + len(z)] = z; struct.pack_into('<I', b, hs + 0xC + 16 * i + 12, s + len(z))   # 借对齐留空，外层长度不变
                else: repl[i] = z; log.append(f'  【红】{where}/{nm}：重压后比原包长 {len(z) - len(src)} 字节，外层包重排变长（按资源尺寸表分配缓冲的游戏可能加载失败）')
    return ch, (sarc_rebuild(b, repl) if repl else None)

def yaz0_dec(b):
    """解 Yaz0。解码在 graphics/tools/nxfmt.py（C 共享库，编不出就纯 Python），与原先这里的循环同一格式。"""
    import sys
    tools = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
    if tools not in sys.path: sys.path.insert(0, tools)
    import nxfmt
    return bytearray(nxfmt.yaz0_decompress(b))

def yaz0enc_name():   # 编码器文件名（按 yaz0enc.c 源码哈希）：现编缓存与启动器预编件同名
    import hashlib
    c = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'yaz0enc.c'); h = hashlib.sha1(open(c, 'rb').read()).hexdigest()[:12]
    return f'yaz0enc-{h}' + ('.exe' if sys.platform == 'win32' else '')

def yaz0enc_prebuilt():
    """启动器随发版预编的编码器（S2A_PREBUILT_TOOLS/codecs/<yaz0enc_name>，launchers/windows/bundle_prepare_win.py）：在就用，不现编、不要编译器"""
    tools = os.environ.get('S2A_PREBUILT_TOOLS')
    p = tools and os.path.join(tools, 'codecs', yaz0enc_name())
    return p if p and os.path.isfile(p) else None

_ENC = None
def yaz0_pack(raw, hdr):
    """真压缩（同目录 yaz0enc.c，按源码哈希编一次缓存在 <S2A_RUN_ROOT>/s2arm/cache/widen/；启动器预编的在就用它）；编不了就退回只写字面量。"""
    global _ENC
    if _ENC is None:
        import tempfile
        c = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'yaz0enc.c')
        win = sys.platform == 'win32'   # Windows 出包机（#1100）：没有 cc，用 LLVM clang（或 CC）；产物带 .exe（找不到编译器会退回只写字面量，产物与 Mac 不同）
        _ENC = yaz0enc_prebuilt() or os.path.join(os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run'), 's2arm/cache/widen', yaz0enc_name())
        if not os.path.exists(_ENC):
            os.makedirs(os.path.dirname(_ENC), exist_ok=True)
            tmp = _ENC[:-4] + '.tmp.exe' if win else _ENC + '.tmp'
            cc = os.environ.get('CC') or ('clang' if win else 'cc')
            try: ok = subprocess.run([cc, '-O2', '-o', tmp, c]).returncode == 0
            except OSError: ok = False
            if ok: os.replace(tmp, _ENC)
            else: _ENC = ''
    if not _ENC: return yaz0_enc(raw, hdr)
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        i, o = os.path.join(d, 'in'), os.path.join(d, 'out'); open(i, 'wb').write(raw)
        try: subprocess.run([_ENC, i, o, bytes(hdr[:16]).hex()], check=True, capture_output=True)
        except OSError as e:   # 起编码器失败（D-GVDA：Windows 上被安全软件拦，WinError 5）：CreateProcess 的报错不带文件名，补上是哪个 exe（随包预编件还是现编缓存）
            if not e.filename: e.filename = _ENC
            raise
        return open(o, 'rb').read()

def yaz0_enc(raw, hdr):
    """只写字面量的 Yaz0（每 8 字节一个全 1 标志字节）：合法、长度约 +12.5%；头 16 字节沿用原包（魔数、解压后长度、对齐字段）。"""
    out = bytearray(hdr[:16]); struct.pack_into('>I', out, 4, len(raw))
    for k in range(0, len(raw), 8):
        chunk = raw[k:k + 8]; out.append((0xFF << (8 - len(chunk))) & 0xFF); out += chunk
    return bytes(out)

# 带字典的 zstd（王国之泪：romfs 下 .zs 都按帧头字典号用 Pack/ZsDic.pack.zs 里的字典压；不给字典 zstd 报 Dictionary mismatch，
#   10-28 首次出包 14706 个包全报错、布局文件读到 0 个）：字典号 → 字典文件，main 起头按原版 romfs 装一次
_DICTS = {}
def zs_dicts(src, tmp):
    """原版 romfs 有 Pack/ZsDic.pack.zs（SARC，成员是 zstd 字典：魔数 37 A4 30 EC + 4 字节字典号）→ 写到 tmp，返回 {字典号: 路径}；没有就空。"""
    p = os.path.join(src, 'Pack', 'ZsDic.pack.zs')
    if not romfs_list.is_file(p): return {}
    b = _unzstd(p, [])
    if b[:4] != b'SARC': return {}
    doff, = struct.unpack_from('<I', b, 0xC); hs, = struct.unpack_from('<H', b, 4); nn, = struct.unpack_from('<H', b, hs + 6); out = {}
    for i in range(nn):
        _, _, s, e = struct.unpack_from('<IIII', b, hs + 0xC + 16 * i); d = b[doff + s:doff + e]
        if d[:4] != b'\x37\xa4\x30\xec': continue
        did, = struct.unpack_from('<I', d, 4); q = os.path.join(tmp, f'{did}.zsdic'); open(q, 'wb').write(d); out[did] = q
    return out

def zs_dict_id(head):
    """zstd 帧头里的字典号（没有 = 0）：帧头描述字节低 2 位定字典号字节数 0/1/2/4，单段位（第 5 位）为 0 时前面还有 1 字节窗口描述。"""
    fhd = head[4]; n = (0, 1, 2, 4)[fhd & 3]; o = 5 if fhd & 0x20 else 6
    return int.from_bytes(head[o:o + n], 'little') if n else 0

def _unzstd(p, dz):
    """zstd -dcq 解出 p：盘上有这个文件就按路径交（同原先），RomFS 不落散文件、只在镜像里时从镜像读出经标准输入交"""
    if os.path.isfile(p): return subprocess.run(['zstd', '-dcq', *dz, p], capture_output=True, check=True).stdout
    return subprocess.run(['zstd', '-dcq', *dz], input=romfs_list.read_file(p), capture_output=True, check=True).stdout

def load(p):
    """按魔数认：zstd（带字典的按帧头字典号取字典）/ Yaz0 / 裸 SARC；别的返回 None。"""
    with romfs_list.open_file(p) as f: head = f.read(18)
    if head[:4] == b'\x28\xb5\x2f\xfd':
        did = zs_dict_id(head); dz = ['-D', _DICTS[did]] if did else []   # 字典号不在字典表里 → KeyError，记报错
        return bytearray(_unzstd(p, dz)), 'zstd', did
    head = head[:4]
    if head == b'Yaz0': b = romfs_list.read_file(p); return yaz0_dec(b), 'yaz0', b[:16]
    if head == b'SARC': return bytearray(romfs_list.read_file(p)), 'raw', None
    return None

def save(q, raw, kind, hdr):
    os.makedirs(os.path.dirname(q), exist_ok=True)
    if kind == 'zstd': subprocess.run(['zstd', '-q', '-3', '-f', '--no-check', *(['-D', _DICTS[hdr]] if hdr else []), '--stream-size=%d' % len(raw), '-o', q], input=bytes(raw), check=True)   # 帧头写解压后长度、不带校验（同原包）；原包带字典的用同一字典重压（帧头照写字典号）
    elif kind == 'yaz0': open(q, 'wb').write(yaz0_pack(bytes(raw), hdr))
    else: open(q, 'wb').write(raw)

def _set_dicts(d):
    _DICTS.update(d)

def _one(a):
    """一个包：解压 → 改整画布底 → 写覆盖文件；回（算不算包、布局文件数、改了几个、日志行、报错数）"""
    p, rel, dst, W = a; lines = []; got = nf = 0
    try:
        g = load(p)
        if g is None: return 0, 0, 0, lines, 0
        raw, kind, hdr = g; got = 1; nf = bytes(raw).count(b'FLYT\xff\xfe')
        c, rb = patch_sarc(raw, W, lines, rel)
        if c: save(os.path.join(dst, rel), rb if rb is not None else raw, kind, hdr)
        return got, nf, c, lines, 0
    except Exception as e:
        # 同串行原样：解压成功后才出错的包照样计入包数与布局文件数
        lines.append(f'  【红】{rel}：{type(e).__name__} {e}'); return got, nf, 0, lines, 1

def main():
    if len(sys.argv) < 4: print(__doc__); return 2
    src, dst, W = sys.argv[1], sys.argv[2], float(sys.argv[3]); subs = sys.argv[4].split(',') if len(sys.argv) > 4 else ['Layout', 'UI', 'Pack']   # 缺省三处都看（动森 Layout、马车8 UI、塞尔达 Layout + Pack），不存在的跳过
    log = []; files = changed = errs = 0; flyt = [0]
    tmp = tempfile.mkdtemp(prefix='ui_lyt_zsdic_'); _DICTS.update(zs_dicts(src, tmp))
    todo = []
    for sub in subs:
        root = os.path.join(src, sub)
        if not romfs_list.is_dir(root): continue
        for dp, _, fns in romfs_list.walk(root):
            todo += [(os.path.join(dp, fn), os.path.relpath(os.path.join(dp, fn), src)) for fn in sorted(fns)]
    # 逐包互不相干（各自解压、解析、写各自的覆盖文件）：按包多进程并行，结果按原顺序收（日志行序、计数与串行逐字节相同）。
    #   11-03 Switch 2 出包线：火纹 4,593 个包单线程 Spare-host 174 秒。J = 本阶段分到的路数（缺省本机核数）；字典表经 initializer 交给子进程（spawn 不继承全局）
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'tools')); from pool_workers import process_pool_size, env_jobs
    jobs = process_pool_size(env_jobs('J'))   # Windows 进程池至多 61 路（#1332）
    with cf.ProcessPoolExecutor(jobs, initializer=_set_dicts, initargs=(dict(_DICTS),)) as ex:
        for got, nf, c, lines, err in ex.map(_one, [(p, rel, dst, W) for p, rel in todo], chunksize=16):
            files += got; flyt[0] += nf; changed += c; errs += err; log += lines
    print('\n'.join(log))
    cnt = lambda head, has='': sum(l.startswith(head) and has in l for l in log)
    print(f'界面布局：包 {files} 个（布局文件 {flyt[0]} 个），改了 {changed} 个整画布底（纯色 {cnt("  改 ", "纯色底")}、真平铺 {cnt("  改 ", "真平铺")}），'
          f'不加宽（加宽会拉伸）{cnt("  不加宽 ")} 个（只铺一遍 {cnt("  不加宽 ", "：只铺一遍")}、部分平铺 {cnt("  不加宽 ", "：部分平铺")}），'
          f'跳过 {cnt("  跳过 ")}，整画布不平铺留显卡层 {cnt("  不改 ")}，报错 {errs}（屏幕宽 {W:g}）')
    shutil.rmtree(tmp, ignore_errors=True)
    return 1 if errs else 0

if __name__ == '__main__':
    sys.exit(main())
