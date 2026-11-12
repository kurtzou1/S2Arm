#!/usr/bin/env python3
"""Switch 2 导出目录 → 一键出包的解包目录（pack/ns2_dump.py）。

Switch 2 游戏现在拿到手的形态是主机上导出的松散目录（11-04 维护者 给的金刚 / raiders 都是），不是 NSP / XCI：
    <导出目录>/base/exefs/{main,main.npdm,rtld,sdk,subsdk*}   本体
    <导出目录>/base/romfs/...
    <导出目录>/updates/<版本号>/exefs|romfs/...                更新（导出工具挂的是打过补丁的文件系统 = 叠加后的全量）
    <导出目录>/dlc/<DLC 标题号>/<n>/romfs/...                   追加内容（也认 dlc/<标题号>/romfs/）
    （.listing 是 FTP 镜像留下的目录清单，忽略）
没有控制分区（control.nacp），nx_unpack 也读不了（它只认 NCA 容器）。本脚本把它整理成 nx_unpack 解包产物同一形态：
    exefs/   取最新更新的（没有更新取本体）；NSO 原样（LZ4 / 不压缩下游都认；0x40 位透传）；ZBIC（0x80）交 nx_unpack --nso-normalize
             解成段不压缩的 NSO（S2A_NX_UNPACK = nx_unpack 程序，一键出包会给；没给就报红）
    romfs/   最新更新的 romfs 里有与本体逐字节相同的文件 = 全量（导出工具挂的是打过补丁的文件系统），只用它；
             没有 = 差量，本体叠更新（更新覆盖），打黄字说明
    aoc/<序号>/ + aoc.tsv   序号 = DLC 标题号 − 程序号 − 0x1000（同 nx_unpack）
    ctl/control.nacp       导出带了控制分区（版本目录里 romfs 之外的 control.nacp）就用原件 + icon.jpg；没带才合成（README.synth 标明非原件，
                           标题取目录名、不是游戏自带信息）：16 语言标题、启动要账号、存档属主 = 程序号、账号存档 128 MB / 日志 64 MB；游戏代码挂临时存储 / 本机存档 / 缓存存储的（按 nn::fs 导入名判）另声明对应大小（save_kinds）
                           （字段与取值同 11-03 火纹合成件，那份在 Mac / 测试设备2 实玩过）
    unpack.tsv             title_id / name / name_zh / display_version / update / base / builds / aoc
程序号从 base/exefs/main.npdm 的 ACI0 读，不看目录名。文件一律 APFS 克隆（不占新空间），跨卷才真拷。
同一形态的 MIT 做法见 the reference port scripts/pack_dump.py（seedds/the reference port 777a5f6c，源自 d2r-mobile）：更新 romfs 是打过补丁的全量、单独用。
先写 <out>.tmp，成功才改名；<out>/.ns2_dump_key = 源清单（路径 字节 修改时间）+ 本脚本内容的哈希，相同就复用不重做。

用法：
    ns2_dump.py --detect <目录>                 是导出目录就打印程序号、退出 0；不是退出 1
    ns2_dump.py <导出目录> <输出解包目录> [--name <款名>]
"""
import ctypes
import hashlib
import os
import shutil
import struct
import subprocess
import sys

NACP_SIZE = 0x4000
SKIP = {'.listing'}


def red(msg):
    print(f'🔴 {msg}', file=sys.stderr)
    sys.exit(1)


def read_tid(npdm):
    b = open(npdm, 'rb').read()
    if b[:4] != b'META' or len(b) < 0x80:
        raise ValueError(f'{npdm} 不是 META 头')
    aci, size = struct.unpack_from('<II', b, 0x70)
    if b[aci:aci + 4] != b'ACI0':
        raise ValueError(f'{npdm} 的 ACI0 不在 0x{aci:x}')
    return struct.unpack_from('<Q', b, aci + 0x10)[0]


def find_dump(root):
    """root 本身或下一层是导出目录（有 base/exefs/main.npdm）就返回它，否则 None。"""
    for d in [root] + sorted(os.path.join(root, n) for n in os.listdir(root) if os.path.isdir(os.path.join(root, n))):
        if os.path.isfile(os.path.join(d, 'base', 'exefs', 'main.npdm')):
            return d
    return None


def numdirs(d):
    """d 下名字是十进制数的子目录，按数值升序。"""
    if not os.path.isdir(d):
        return []
    return sorted((n for n in os.listdir(d) if n.isdigit() and os.path.isdir(os.path.join(d, n))), key=int)


def walk(root):
    """相对路径 → 绝对路径（只文件，跳过 .listing）。"""
    out = {}
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for f in sorted(fns):
            if f in SKIP:
                continue
            a = os.path.join(dp, f)
            out[os.path.relpath(a, root)] = a
    return out


_libc = ctypes.CDLL(None, use_errno=True) if sys.platform == 'darwin' else None


def clone(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if _libc is not None and _libc.clonefile(src.encode(), dst.encode(), 0) == 0:
        return
    shutil.copy2(src, dst)   # 跨卷 / 非 APFS：真拷


# 合成控制分区里各类存档按游戏代码实际挂的建（11-05 0400486024DEC000：游戏挂临时存储 MountTemporaryStorage，合成件 TemporaryStorageSize = 0，
#   启动时 EnsureApplicationSaveData 不建它，OpenSaveDataFileSystem（fs 命令 51）回 2002-1002、游戏 Break）。
#   判法：游戏代码模块（main、subsdk*；sdk 定义全部 nn::fs 函数，不算）的动态符号名里有没有 nn::fs 对应挂载函数（导入名在 .dynstr，按段解开后找修饰名）；有就按下面的大小声明（与账号存档同量级），
#   没有就保持 0（不凭空多建）。字段位置同 Ryujinx.Horizon/Sdk/Ns/ApplicationControlProperty.cs。
SAVE_KINDS = (   # （nn::fs 修饰名片段，[(nacp 偏移, 值)…]，说明）
    (b'_ZN2nn2fs21MountTemporaryStorageE', [(0x3168, 0x08000000)], '临时存储 128 MB'),
    (b'_ZN2nn2fs19MountDeviceSaveDataE', [(0x3090, 0x08000000), (0x3098, 0x04000000)], '本机存档 128 / 64 MB'),
    (b'_ZN2nn2fs17MountCacheStorageE', [(0x3170, 0x08000000), (0x3178, 0x04000000), (0x3180, 0x0C000000)], '缓存存储 128 / 64 MB'),
)


def nso_image(path):
    """NSO 三段解开后拼起来（只为找符号名，不按内存布局摆）。段压缩（标志 0–2 位）是 LZ4 块；ZBIC 已在上面交 nx_unpack 解成不压缩"""
    d = open(path, 'rb').read()
    if d[:4] != b'NSO0' or len(d) < 0x100:
        return d
    fl = struct.unpack_from('<I', d, 0x0C)[0]
    out = []
    for i in range(3):
        fo, _, size = struct.unpack_from('<III', d, 0x10 + i * 16)
        csz = struct.unpack_from('<I', d, 0x60 + i * 4)[0]
        raw = d[fo:fo + (csz if fl & (1 << i) else size)]
        if fl & (1 << i) and raw:
            import lz4.block   # 出包 Python 依赖（launchers/macos/requirements-runtime.txt）
            raw = lz4.block.decompress(raw, uncompressed_size=size)
        out.append(raw)
    return b''.join(out)


def save_kinds(exefs):
    """exefs 里游戏代码（main、subsdk*）用到的存档类别 → [(偏移, 值)…] 与说明列表。sdk / rtld 是系统库，自己定义全部 nn::fs 函数（名字都在它的导出表里），不算"""
    imgs = [nso_image(os.path.join(exefs, f)) for f in sorted(os.listdir(exefs)) if f == 'main' or f.startswith('subsdk')]
    fields, notes = [], []
    for sym, fs, note in SAVE_KINDS:
        if any(sym in b for b in imgs):
            fields += fs; notes.append(note)
    return fields, notes


def synth_nacp(tid, name, saves=()):
    n = bytearray(NACP_SIZE)
    t = name.encode('utf-8')[:0x1ff]
    for i in range(16):   # ApplicationTitle[16]：名字 0x200 + 发行商 0x100
        n[i * 0x300:i * 0x300 + len(t)] = t
    n[0x3025] = 1                                   # StartupUserAccount = Required
    # SupportedLanguageFlag：不知道游戏支持哪些语言时只声明美式英语（位 0）。留 0 = 「一种都不支持」，服务层把系统语言原样交给游戏，
    #   游戏不认（#401：系统简体中文 → 游戏判无效语言、去读不存在的语言库、一直黑屏）；声明了英语，系统语言不在表里时就退到英语。
    #   不按资源目录猜语言：各款语言资源的组织方式不同，没有通用判据
    struct.pack_into('<I', n, 0x302C, 1)
    n[0x3060:0x3061] = b'?'                         # DisplayVersion 未知
    struct.pack_into('<Q', n, 0x3078, tid)          # SaveDataOwnerId = 程序号（错了开存档 2002-6400，11-03 火纹）
    struct.pack_into('<q', n, 0x3080, 0x08000000)   # UserAccountSaveDataSize 128 MB
    struct.pack_into('<q', n, 0x3088, 0x04000000)   # UserAccountSaveDataJournalSize 64 MB
    for off, v in saves:                            # 游戏代码挂的其余存档类别（save_kinds）
        struct.pack_into('<q', n, off, v)
    return bytes(n)


def fill_fixed(nacp, tid, saves=()):
    """原件的固定段（0x3000 起：启动账号、语言位、存档归属号与各存档尺寸）全零时补上存档字段 → (新内容, 是否补了)。
    某款 Switch 2 游戏的更新包元数据里带的控制数据只有标题和发行商、0x3000 往后全 0：原样用时宿主不建账号存档，游戏开存档 2002-1002 自己中止、起局黑屏。
    补法同 synth_nacp 的存档部分（启动账号 Required、归属号 = 程序号、账号存档 128 / 64 MB、游戏代码挂的其余存档类别）；
    语言位保持 0：Switch 2 游戏支持表未知时服务层按宿主语言（#465），不写死英语。固定段不是全零（真原件）一字不动"""
    if len(nacp) < NACP_SIZE or any(nacp[0x3000:NACP_SIZE]):
        return nacp, False
    n = bytearray(nacp)
    n[0x3025] = 1
    struct.pack_into('<Q', n, 0x3078, tid)
    struct.pack_into('<q', n, 0x3080, 0x08000000)
    struct.pack_into('<q', n, 0x3088, 0x04000000)
    for off, v in saves:
        struct.pack_into('<q', n, off, v)
    return bytes(n), True


def same_file(rb, ru, limit=64):
    """全量 / 差量判法：导出工具挂的是打过补丁的文件系统 = 全量，里面一定有没改过、与本体逐字节相同的文件；
    差量包只装改过 / 新增的，没有这种文件。只看同路径同大小的前 limit 个，找到一个就返回它的路径，找不到返回 None。
    （不能按「本体路径全在更新里」判：补丁会删掉旧版本文件，11-04 金刚 41 个、raiders 86 个 Product.100 旧文件只在本体里。）"""
    n = 0
    for rel in sorted(set(rb) & set(ru)):
        if os.path.getsize(rb[rel]) != os.path.getsize(ru[rel]):
            continue
        with open(rb[rel], 'rb') as a, open(ru[rel], 'rb') as b:
            while True:
                x, y = a.read(1 << 20), b.read(1 << 20)
                if x != y:
                    break
                if not x:
                    return rel
        n += 1
        if n >= limit:
            break
    return None


CONTENT_DIRS = ('romfs', 'exefs')   # 版本目录里的游戏内容分区：找控制分区时不进


def find_control(dirs):
    """版本目录（先最新更新、后本体）里 romfs 之外、两层以内名为 control.nacp 的文件（0x4000 字节）→ (内容, [icon_*.dat…])；都没有 → None。
    导出工具若带了控制分区，这里就是游戏自带的标题 / 显示版本 / 图标；11-04 金刚、raiders 的导出都没带。"""
    for d in dirs:   # 只看版本目录本层与下一层（不进 romfs / exefs），不递归：RomFS 遍历只走 romfs_list.py
        for dp in [d] + [os.path.join(d, n) for n in sorted(os.listdir(d)) if n not in CONTENT_DIRS and os.path.isdir(os.path.join(d, n))]:
            c = os.path.join(dp, 'control.nacp')
            if os.path.isfile(c) and os.path.getsize(c) == NACP_SIZE:
                return open(c, 'rb').read(), sorted(os.path.join(dp, f) for f in os.listdir(dp) if f.startswith('icon_') and f.endswith('.dat'))
    return None


def nacp_title(n, lang):   # ApplicationTitle[lang] 的名字（0x200 字节 UTF-8），空返回 None；语言序号同 nx_unpack（0 美式英语，13 繁中，14 简中）
    t = n[lang * 0x300:lang * 0x300 + 0x200].split(b'\0')[0].decode('utf-8', 'replace')
    return t or None


def src_key(dump):
    h = hashlib.sha256()
    for rel, a in sorted(walk(dump).items()):
        st = os.stat(a)
        h.update(f'{rel}\t{st.st_size}\t{st.st_mtime_ns}\n'.encode())   # 纳秒（审计 P1-54：秒级键同一秒内换同大小的文件认不出）
    h.update(hashlib.sha256(open(os.path.abspath(__file__), 'rb').read()).digest())
    nxu = os.environ.get('S2A_NX_UNPACK')   # ZBIC 由它解：换了解码器（自写替换 ZstdSharp.Zbic）就重做
    if nxu and os.path.isfile(nxu):
        h.update(hashlib.sha256(open(nxu, 'rb').read()).digest())
    return h.hexdigest()[:16]


def convert(dump, out, name=None):
    base = os.path.join(dump, 'base')
    try:
        tid = read_tid(os.path.join(base, 'exefs', 'main.npdm'))
    except (OSError, ValueError, struct.error) as e:
        red(f'读不出程序号：{e}')
    ups = numdirs(os.path.join(dump, 'updates'))
    upd = os.path.join(dump, 'updates', ups[-1]) if ups else None
    if len(ups) > 1:
        print(f'🟡 有 {len(ups)} 个更新（{", ".join(ups)}），取最新 {ups[-1]}')
    key = src_key(dump)
    kf = os.path.join(out, '.ns2_dump_key')
    if os.path.isfile(kf) and open(kf).read().strip() == key:
        print(f'🟢 导出目录没变（键 {key}），复用 {out}')
        return 0
    tmp = out + '.tmp'
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)

    # exefs
    exsrc = os.path.join(upd, 'exefs') if upd and os.path.isfile(os.path.join(upd, 'exefs', 'main')) else os.path.join(base, 'exefs')
    builds = []
    for rel, a in walk(exsrc).items():
        if os.sep in rel:
            continue
        hdr = open(a, 'rb').read(0x50)
        if hdr[:4] == b'NSO0':
            fl = struct.unpack_from('<I', hdr, 0x0C)[0]
            # 0–2 段压缩（LZ4）、3–5 段哈希；0x40 原样透传：raiders 0400380020056000 的 main 是 0x7f，the reference port nso.py 与 Eden-NS2 nso.cpp
            #   都只按段看 0–2 / 3–5 位、不管这一位，两家都跑通了这款（11-04 核过）。0x80 = ZBIC 压缩要 nx_unpack 解；更高的位不认识 → 报红
            if fl & ~0xFF:
                red(f'{a}：NSO 标志 0x{fl:x} 有不认识的位 0x{fl & ~0xFF:x}，压缩方式不明不收')
            builds.append(f'{rel}:{hdr[0x40:0x50].hex()}')
            if fl & 0x80:   # ZBIC：交 nx_unpack 解成段不压缩（逐段核 SHA-256；标志去掉 0–2 位与 0x80，其余保留）
                nxu = os.environ.get('S2A_NX_UNPACK')
                if not nxu or not os.path.isfile(nxu):
                    red(f'{a}：NSO 标志 0x{fl:x} 带 ZBIC（0x80）压缩，要 nx_unpack 解：设 S2A_NX_UNPACK=<nx_unpack 程序>（一键出包会给）')
                dst = os.path.join(tmp, 'exefs', rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                r = subprocess.run([nxu, '--nso-normalize', a, dst], capture_output=True, text=True)
                if r.returncode != 0:
                    red(f'{a}：ZBIC 解不开（nx_unpack 退出 {r.returncode}）：{(r.stderr or r.stdout).strip()[-300:]}')
                print(f'   {rel}：ZBIC 压缩，已用 nx_unpack 解成段不压缩')
                continue
        clone(a, os.path.join(tmp, 'exefs', rel))
    if not os.path.isfile(os.path.join(tmp, 'exefs', 'main')):
        red(f'{exsrc} 里没有 main')
    if read_tid(os.path.join(tmp, 'exefs', 'main.npdm')) != tid:
        red('更新的 main.npdm 程序号与本体不一致')

    # romfs
    rb = walk(os.path.join(base, 'romfs'))
    ru = walk(os.path.join(upd, 'romfs')) if upd else {}
    same = same_file(rb, ru)
    if ru and not rb:
        rom, how = ru, f'更新 {ups[-1]}（本体没带 romfs）'
    elif ru and same:
        rom, how = ru, f'更新 {ups[-1]} 的全量（与本体逐字节相同的文件如 {same}；本体独有 {len(set(rb) - set(ru))} 个旧版本文件不收）'
    elif ru:
        rom = dict(rb)
        rom.update(ru)
        how = f'本体 {len(rb)} + 更新 {len(ru)} 叠加（更新里没有与本体逐字节相同的文件，按差量处理）'
        print(f'🟡 romfs：{how}')
    else:
        rom, how = rb, f'本体（无更新）'
    if not rom:
        red(f'{dump} 没有 romfs 文件')
    low = {}
    for rel in rom:
        k = rel.lower()
        if k in low:
            red(f'romfs 里有只差大小写的路径：{low[k]} / {rel}（文件系统不分大小写）')
        low[k] = rel
    nb = 0
    for rel, a in rom.items():
        clone(a, os.path.join(tmp, 'romfs', rel))
        nb += os.path.getsize(a)

    # DLC
    aoc_rows, aoc_idx = [], []
    dlc = os.path.join(dump, 'dlc')
    for d in sorted(os.listdir(dlc)) if os.path.isdir(dlc) else []:
        try:
            atid = int(d, 16)
        except ValueError:
            continue
        idx = atid - tid - 0x1000
        if not 0 < idx < 0x1000:
            print(f'🟡 DLC {d} 不属于程序号 {tid:016x}，跳过')
            continue
        vs = [v for v in numdirs(os.path.join(dlc, d)) if os.path.isdir(os.path.join(dlc, d, v, 'romfs'))]
        rd = os.path.join(dlc, d, vs[-1], 'romfs') if vs else os.path.join(dlc, d, 'romfs')   # 也认 dlc/<标题号>/romfs（中间没有 <n>）
        if not os.path.isdir(rd):
            print(f'🟡 DLC {d} 没有 romfs（只有授权？），记仅授权')
            aoc_rows.append(f'{idx}\t{atid:016x}\t0\t-1\t0')
            continue
        fs = walk(rd)
        for rel, a in fs.items():
            clone(a, os.path.join(tmp, 'aoc', str(idx), rel))
        aoc_idx.append(idx)
        aoc_rows.append(f'{idx}\t{atid:016x}\t{vs[-1] if vs else 0}\t{len(fs)}\t{sum(os.path.getsize(a) for a in fs.values())}')
    with open(os.path.join(tmp, 'aoc.tsv'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('idx\ttitle_id\tversion\tfiles\tbytes\n' + ''.join(r + '\n' for r in aoc_rows))

    os.makedirs(os.path.join(tmp, 'ctl'))
    real = find_control([upd, base] if upd else [base])
    if real:   # 导出带了控制分区：用原件，标题 / 显示版本 / 图标都是游戏自带的
        nacp, icons = real
        nacp, filled = fill_fixed(nacp, tid, save_kinds(os.path.join(tmp, 'exefs'))[0])
        with open(os.path.join(tmp, 'ctl', 'control.nacp'), 'wb') as f:
            f.write(nacp)
        if icons:
            clone(icons[0], os.path.join(tmp, 'icon.jpg'))
        nm, nzh, dver = nacp_title(nacp, 0) or '', nacp_title(nacp, 14) or nacp_title(nacp, 13) or '', nacp[0x3060:0x3070].split(b'\0')[0].decode('ascii', 'replace')
        nm = nm or nzh or name or os.path.basename(os.path.normpath(dump))
        ctl_note = '控制分区用原件' + ('（原件固定段全零，补了存档字段）' if filled else '')
    else:   # 没带：合成。README.synth 只标明来源（标题取导出目录名；维护者 11-04：导不出控制分区就用文件夹名，取名函数照读）
        nm, nzh, dver = name or os.path.basename(os.path.normpath(dump)), '', ''
        saves, snotes = save_kinds(os.path.join(tmp, 'exefs'))
        with open(os.path.join(tmp, 'ctl', 'control.nacp'), 'wb') as f:
            f.write(synth_nacp(tid, nm, saves))
        with open(os.path.join(tmp, 'ctl', 'README.synth'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(f'# pack/ns2_dump.py 合成（Switch 2 导出目录没有控制分区）：非游戏原件。程序号 {tid:016x}，标题「{nm}」取自导出目录名，不是游戏自带信息\n')
        ctl_note = 'control.nacp 合成（导出没带控制分区；另建 ' + ('、'.join(snotes) or '无') + '）'
    with open(os.path.join(tmp, 'unpack.tsv'), 'w', encoding='utf-8', newline='\n') as f:   # Windows 上缺省写 CRLF：Mac 读回程序号带 \r（11-05 金刚Windows 出包机产物根拉回 Mac，direct_lib 找不到配置档）
        f.write(f'title_id\t{tid:016x}\nname\t{nm}\nname_zh\t{nzh}\ndisplay_version\t{dver}\n'
                f'update\t{ups[-1] if ups else ""}\nbase\t0\nbuilds\t{" ".join(builds)}\naoc\t{",".join(map(str, aoc_idx))}\n')
    with open(os.path.join(tmp, '.ns2_dump_key'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(key + '\n')
    shutil.rmtree(out, ignore_errors=True)
    os.rename(tmp, out)
    print(f'🟢 Switch 2 导出目录 → {out}：程序号 {tid:016x}；exefs {" ".join(b.split(":")[0] for b in builds)}；'
          f'romfs {len(rom)} 个文件 {nb >> 20} MB（{how}）；DLC {len(aoc_idx)} 个；{ctl_note}；标题「{nm}」')
    return 0


def main(a):
    if len(a) == 2 and a[0] == '--detect':
        d = find_dump(a[1]) if os.path.isdir(a[1]) else None
        if not d:
            return 1
        print(f'{read_tid(os.path.join(d, "base", "exefs", "main.npdm")):016X}\t{d}')
        return 0
    name = None
    if '--name' in a:
        i = a.index('--name')
        name = a[i + 1]
        a = a[:i] + a[i + 2:]
    if len(a) != 2:
        print(__doc__.split('用法：')[1], file=sys.stderr)
        return 2
    d = find_dump(a[0]) if os.path.isdir(a[0]) else None
    if not d:
        red(f'{a[0]} 不是 Switch 2 导出目录（要有 base/exefs/main.npdm）')
    return convert(d, os.path.abspath(a[1]), name)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
