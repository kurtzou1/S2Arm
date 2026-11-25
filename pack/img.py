#!/usr/bin/env python3
"""单一 IMG v1（v0.3.0）：一款游戏的原始资源交成一个文件——出包产出它、游戏库存它、推送 / 导出传它、iPhone 上放它。
只装游戏原始资源（RomFS、exefs、ctl、系统数据…），字节永远不变；直连着色器库（派生产物）与界面覆盖层不进，放在 IMG 旁边。

布局（小端，PAGE = 16 KB）：
  [0, PAGE)        头：0 "S2AIMG01" | 8 u32 格式号 | 12 u32 0 | 16 16 字节游戏号（ASCII 十六进制）| 32 64 字节资源包号（ASCII，可空）
                       | 96 u64 RomFS 段偏移 | 104 u64 RomFS 段长 | 112 u64 目录表偏移 | 120 u64 目录表长 | 128 u64 整个文件长 | 其余 0
  RomFS 段         Switch 标准 RomFS（services/romfs_index --std，LibHac RomFsBuilder；与 hactool / nxdumptool 的 romfs.bin 同一种），起点页对齐
  其余文件段       每个文件起点页对齐（读时一次 pread / mmap 零拷贝）
  目录表           u32 槽数（2 的幂）| u32 条目数 | 槽数 × {u64 路径 FNV-1a 64（0 = 空槽）, u64 偏移, u64 长度, u32 路径偏移, u32 路径长} | 路径区（UTF-8）
                   开放寻址线性探测，按路径 O(1) 查；路径用 / 分隔、相对资源包根（如 exefs/main.npdm）
                   有 RomFS 段时目录表另有一条 romfs.list：RomFS 里全部文件的相对路径（UTF-8，按字节序，一行一个）——服务层叠界面覆盖层时
                   按它重建虚拟 RomFS（services RomFsIndex.OpenImg），不依赖 LibHac 的目录遍历
格式号只在字节布局真变时加一；新壳必须保留读旧号的代码（坑记录与发版步骤）。

用法：img.py build <RomFS 目录 | 标准 RomFS 镜像文件> <其余文件清单 tsv：相对路径\\t源文件> <输出 .img> --gid <游戏号> [--pack-id <资源包号>] [--romfs-index <romfs_index 命令>]
      img.py convert <产物根> <资源包目录> [--gid <游戏号>]   出包交付：资源包目录就地转 IMG 形态
      img.py ls <img>   列目录表（单测 / 诊断）"""
import argparse, os, re, shlex, struct, subprocess, sys
# RomFS 目录遍历一律经 graphics/nvn/tools/romfs_list.py（tools/romfs_walk_lint.py 守卫）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'nvn', 'tools'))
import romfs_list  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from progress import Ticker  # noqa: E402
import fullnote  # noqa: E402   # 写满当场量一次（#2164）

MAGIC, FORMAT, PAGE = b'S2AIMG01', 1, 16384
HDR = struct.Struct('<8sII16s64s5Q')
SLOT = struct.Struct('<QQQII')


class Red(Exception):
    pass


def fnv(path):
    h = 1469598103934665603
    for b in path.encode('utf-8'):
        h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h or 1


def up(n):
    return (n + PAGE - 1) // PAGE * PAGE


def toc_bytes(entries):
    """entries：[(路径, 偏移, 长度)] → 目录表字节"""
    slots = 1
    while slots < max(1, len(entries)) * 2: slots <<= 1
    table = [None] * slots; paths = bytearray()
    for path, off, size in entries:
        # 目录表只放文件（11-16 D-4VAX：手机上按目录表逐项建父目录再改名，一条「/」结尾的项会把目标建成目录、改名 errno 21，整款装不上）
        if not path or path.endswith('/') or path.startswith('/'): raise Red(f'目录表只放文件，不收这种路径：{path!r}')
        h = fnv(path); k = h & (slots - 1)
        while table[k] is not None:
            if table[k][0] == h and table[k][5] == path: raise Red(f'目录表路径重复：{path}')
            k = (k + 1) & (slots - 1)
        p = path.encode('utf-8'); table[k] = (h, off, size, len(paths), len(p), path); paths += p
    out = bytearray(struct.pack('<II', slots, len(entries)))
    for t in table: out += SLOT.pack(*t[:5]) if t else bytes(SLOT.size)
    return bytes(out + paths)


def written(path):
    """.part 已写的字节（进度用）：POSIX 取实际分配的块（st_blocks，与写入顺序无关）；Windows 没有 st_blocks（#711：大游戏 RomFS 写满 1 秒就
    AttributeError，img.py 半路退出、game.img 写失败），取文件长度（romfs_index 顺序写，长度就是写到哪）"""
    st = os.stat(path)
    blocks = getattr(st, 'st_blocks', None)
    return blocks * 512 if blocks is not None else st.st_size


def build(romfs_dir, others, out, gid, pack_id='', romfs_index=None, say=print, consume=False):
    """romfs_dir：RomFS 目录，或已建好的标准 RomFS 镜像文件（RomFS 不落散文件：这段原样拷进来，不再从目录现建；None = 没有 RomFS）；
    others：[(相对路径, 源文件)]；→ 输出路径。
    consume：RomFS 段边写边删原件（目录：romfs_index --consume；镜像：从尾往前搬、搬一块截一块，#746），调用方先 free_clones 只留这一份"""
    if len(gid) != 16 or any(c not in '0123456789ABCDEFabcdef' for c in gid): raise Red(f'游戏号不对：{gid!r}')
    part = out + '.part'
    std = romfs_dir if romfs_dir and os.path.isfile(romfs_dir) else None
    try:
        with open(part, 'wb') as f: f.truncate(PAGE)
        romfs_off = romfs_len = 0
        names = []
        if std:   # 镜像：romfs.list = 镜像文件表里的全部文件（同一字节序；镜像由 romfs_index 建，本来就不收 macOS 垃圾）
            im = _romfs_img().RomfsImage(std)
            names = [rel for rel, _, _ in im.entries()]
            rom_bytes = sum(n for _, _, n in im.entries())
        elif romfs_dir:   # romfs.list：同 romfs_index 的文件集合（跳过 macOS 垃圾 .DS_Store / ._*，同 RomFsIndex.IsHostJunk），按字节序
            names = sorted((os.path.relpath(os.path.join(d, n), romfs_dir).replace(os.sep, '/') for d, _, ns in romfs_list.walk(romfs_dir) for n in ns
                            if n != '.DS_Store' and not n.startswith('._')), key=lambda x: x.encode('utf-8'))
        # 字节进度（S2A_PROGRESS，tools/progress.py）：总数 = RomFS 各文件 + 其余文件的字节（RomFS 目录表几 MB 不计，报满前封顶）
        if not std: rom_bytes = sum(os.path.getsize(os.path.join(romfs_dir, n)) for n in names)
        tk = Ticker('写单一 IMG', rom_bytes + sum(os.path.getsize(src) for _, src in others))
        if std:
            romfs_off = PAGE
            romfs_len = copy_std(std, part, romfs_off, lambda done: tk.step(max(0, min(done, rom_bytes - 1) - tk.done)), consume)
            lst = out + '.romfs.list'; open(lst, 'w', encoding='utf-8', newline='\n').write(''.join(n + '\n' for n in names)); others = [*others, ('romfs.list', lst)]
            tk.step(max(0, rom_bytes - tk.done))
        elif romfs_dir:
            if not romfs_index: raise Red('写 RomFS 段要 romfs_index 命令（services/romfs_index）')
            romfs_off = PAGE
            # romfs_index 是另一个进程：每秒看 .part 实际分配的字节（st_blocks，与写入顺序无关）当已写量
            if consume: writable(romfs_dir)   # 产物根的 RomFS 共享存储整棵只读（pack/roots.sh）：删文件要目录可写
            p = subprocess.Popen([*shlex.split(romfs_index), '--std', romfs_dir, '-', part, str(romfs_off), *(['--consume'] if consume else [])],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                while True:
                    try: p.wait(timeout=1); break
                    except subprocess.TimeoutExpired: pass
                    tk.step(max(0, min(written(part) - PAGE, rom_bytes - 1) - tk.done))
            finally:   # 等它的时候本进程出了任何错：先把它收掉再往上抛，不留在后台接着写（#711：原先 Windows 上留下 dotnet.exe）
                if p.poll() is None: p.kill(); p.wait()
            so, se = p.communicate()
            if p.returncode: raise Red(f'写标准 RomFS 段失败：{tool_error(se or so)}')
            for l in (se or '').splitlines():   # 删不掉的解包文件（#793 / #796）等黄字：进 img.log，不算失败
                if l.startswith('🟡'): print(l, flush=True)   # 直接打：命令行 convert 不传 progress，say 是空函数，黄字会丢
            romfs_len = int(so.strip().splitlines()[-1])
            lst = out + '.romfs.list'; open(lst, 'w', encoding='utf-8', newline='\n').write(''.join(n + '\n' for n in names)); others = [*others, ('romfs.list', lst)]
            tk.step(max(0, rom_bytes - tk.done))
        pos = up(romfs_off + romfs_len) if romfs_dir else PAGE
        entries = []
        with open(part, 'r+b') as f:
            for rel, src in sorted(others):
                size = os.path.getsize(src); f.seek(pos)
                with open(src, 'rb') as s:
                    while b := s.read(1 << 22): f.write(b); tk.step(len(b))
                entries.append((rel, pos, size)); pos = up(pos + size)
            toc = toc_bytes(entries); toc_off = pos; f.seek(toc_off); f.write(toc)
            total = toc_off + len(toc)
            f.seek(0); f.write(HDR.pack(MAGIC, FORMAT, 0, gid.upper().encode('ascii'), pack_id.encode('ascii')[:64], romfs_off, romfs_len, toc_off, len(toc), total))
        os.replace(part, out)
        if romfs_dir: os.unlink(out + '.romfs.list')
    except BaseException:
        try: os.unlink(part)
        except OSError: pass
        raise
    say(f'IMG v1：{out}（{total / 1e9:.2f} GB；RomFS {romfs_len / 1e9:.2f} GB，其余 {len(entries)} 个文件）')
    return out


def copy_std(std, part, at, progress, consume):
    """标准 RomFS 镜像 std 整份写进 part 的 at 处（IMG 的 RomFS 段就是这段字节：RomFS 内部偏移相对段起点，搬到哪都不用改）→ 段长。
    progress(已写字节)。consume（#746 边写边腾）：从尾往前一块块搬、每搬完一块就把镜像截短到那里，峰值只多一块；
    镜像还有别的硬链接（截短会连带改掉别处那份）时照常从头拷，拷完只删这个名字。写到一半失败 = 镜像已残缺，调用方清掉整个出包工作目录重解"""
    import errno
    real = os.path.realpath(std); size = os.path.getsize(real); wrote = [0]
    def step(n):
        wrote[0] = n; progress(n)
    try:
        return _copy_std(real, std, part, at, step, consume, size)
    except OSError as e:
        # 写满当场量一次、打「【写满】」事实（tools/fullnote.py）：失败后出包工作目录一清空间就回来，事后再量说不清差多少（#2164：
        #   出包写 game.img 时盘满，玩家只看到「准备这个游戏需要更多空余空间」，不知道要留多少）。这一步还要写的量 = 镜像剩下没拷的部分
        if e.errno in (errno.ENOSPC, errno.EDQUOT):
            left = os.path.getsize(real) if consume and os.path.exists(real) else size - wrote[0]   # 边写边腾时镜像已截到只剩没拷的
            fullnote.note(os.path.dirname(os.path.abspath(part)), 'game.img', left)
        raise


def _copy_std(real, std, part, at, progress, consume, size):
    import stat
    done = 0
    with open(part, 'r+b') as w:
        if consume and os.stat(real).st_nlink == 1:
            os.chmod(real, os.stat(real).st_mode | stat.S_IWUSR)
            with open(real, 'r+b') as r:
                end = size; shrink = True
                while end:
                    start = max(0, end - (1 << 22)); r.seek(start); b = r.read(end - start)
                    if len(b) != end - start: raise Red(f'RomFS 镜像 {std} 读不满（偏移 {start}）')
                    w.seek(at + start); w.write(b); w.flush()
                    if shrink:
                        # 截短被系统拒（D-X5JB：Windows 上别的程序——杀毒软件、索引——正拿着镜像时报 [Errno 13]，原先整单失败）：
                        #   边写边腾只为省峰值，不是必需；后面照常拷完，镜像收尾照删，只是这一段时间多占一份
                        try: r.truncate(start)
                        except PermissionError as e:
                            shrink = False
                            print(f'🟡 截短 RomFS 镜像被系统拒（{e}，多半是杀毒软件或索引正拿着它）：剩下的 {start / 1e9:.1f} GB 不再边写边腾，照常拷完', flush=True)
                    end = start; done += len(b); progress(done)
        else:
            with open(real, 'rb') as r:
                w.seek(at)
                while b := r.read(1 << 22): w.write(b); done += len(b); progress(done)
            if done != size: raise Red(f'RomFS 镜像 {std} 读不满（{done} / {size}）')
    if consume:
        d = os.path.dirname(real); os.chmod(d, os.stat(d).st_mode | stat.S_IWUSR | stat.S_IXUSR)   # RomFS 共享存储整棵只读（pack/roots.sh）：删要目录可写
        os.unlink(real)
        if std != real and os.path.islink(std): os.unlink(std)
    return size


SKIP = ('romfs/', 'romfs.', 'romfs_overlay/', 'shaders/')   # 资源包里不进 IMG 的：RomFS（另建标准段）、旧镜像件、界面覆盖层、直连库（派生产物）


KEEP = ('romfs_overlay/', 'shaders/', 'romfs.s2aidx')   # 转 IMG 后照旧按文件留在资源包里的派生件（App 管的缓存，可更新；IMG 不动）；romfs.s2aidx 配 game.imgmap 走预建路径
MAP = 'game.imgmap'   # IMG 旁的派生偏移表（services RomFsIndex.OpenImg）：格式同 romfs.imgmap，偏移是 game.img 里的绝对位置，-1 = 界面覆盖层


def title_of(d):
    """目录里 unpack.tsv 记的程序号（大写）；读不出 → ''"""
    try:
        return next((l.split('\t', 1)[1].strip().upper() for l in open(os.path.join(d, 'unpack.tsv'), encoding='utf-8') if l.startswith('title_id\t')), '')
    except OSError:
        return ''


def orig_romfs(root, work):
    """原始 RomFS（IMG 只装原始资源）→ (目录, 用完要删的临时目录或 None)。旧形态（11-16 前 Mac 宽屏界面布局阶段 pack/stage_uilayout.sh）把 ui_overlay.tsv 列的文件就地换进产物根 romfs、
    原版取自 seed.txt 记的游戏数据目录 /romfs；所以原件 = 产物根 romfs，但这几个文件换回数据目录里的原版。其余文件一律取产物根（与 romfs.s2aidx 天然一致；
    11-11 实测数据目录在播种后变过：别的文件长度与产物根差 1 字节，整棵取数据目录会和索引对不上）。临时目录建在 work 下：产物根 romfs 逐文件硬链（APFS / NTFS 都行、不占盘），
    覆盖文件换成原版。没有覆盖 → 直接用产物根 romfs；有覆盖但 seed.txt 缺或原版缺 → 报红"""
    romfs = os.path.join(root, 'romfs')
    std = None if os.path.isdir(romfs) else romfs_list.image_of(romfs)   # RomFS 不落散文件：产物根只有 romfs.std（标准 RomFS 镜像）→ 这段原样进 IMG
    if not os.path.isdir(romfs) and not std: return None, None
    try: ov = [l.strip() for l in open(os.path.join(root, 'ui_overlay.tsv'), encoding='utf-8') if l.strip()]
    except FileNotFoundError: ov = []
    if std:   # 镜像只能是原版：界面覆盖要在 ui_overlay/ 层（Windows 形态）；就地改 RomFS 的形态（Mac pack/stage_uilayout.sh）没有镜像可改
        if ov and not os.path.isdir(os.path.join(root, 'ui_overlay')):
            raise Red(f'产物根只有 RomFS 镜像 {std}，界面覆盖却是就地改 RomFS 的形态（没有 ui_overlay/），分不出原版：要重新出包')
        return std, None
    if not ov: return romfs, None
    # 覆盖层形态（Windows pack/orch/stages.py _uilayout 11-06 起，Mac pack/stage_uilayout.sh 11-16 起）：产物根 romfs 本身一直是原版（仍联到共享存储那份不可变的身份），改动只写在 <版本>/ui_overlay/ 层，
    #   原件就是产物根 romfs，不看 seed.txt。seed.txt 记的解包目录不可靠：Windows 播种从原件解时把它的 romfs 挪进共享存储、原处链接在播种那一版被修剪后悬空；
    #   玩家实报它还指到过别的款的解包目录（v0.3.0 Windows：有界面覆盖的款写 IMG 报「找不到原版」）
    if os.path.isdir(os.path.join(root, 'ui_overlay')): return romfs, None
    sf = os.path.join(root, 'seed.txt')
    src = next((l[4:].strip() for l in open(sf, encoding='utf-8') if l.startswith('src=')), '') if os.path.isfile(sf) else ''
    ts, tr = (title_of(src), title_of(root)) if src else ('', '')
    if ts and tr and ts != tr:   # 就地改过的旧形态（11-16 前 Mac pack/stage_uilayout.sh；之后两端都只写覆盖层）才要原版：解包目录必须是这一款的，别的款的文件绝不进 IMG
        raise Red(f'seed.txt 记的解包目录 {src} 是游戏 {ts} 的，不是这一款（{tr}）：要重新出包')
    lost = [r for r in ov if not os.path.isfile(os.path.join(src, 'romfs', r))] if src else ov
    if lost: raise Red(f'产物根 romfs 叠过 {len(ov)} 个界面覆盖文件，找不到其中 {len(lost)} 个的原版（seed.txt 的 src={src or "无"}，如 {lost[:2]}），不能当原件进 IMG')
    import shutil
    tmp = os.path.join(work, 'romfs.orig.tmp'); shutil.rmtree(tmp, ignore_errors=True)
    def place(s, d):
        os.makedirs(os.path.dirname(d), exist_ok=True)
        try: os.link(os.path.realpath(s), d)
        except OSError: shutil.copyfile(s, d)
    real = os.path.realpath(romfs)
    for d, _, ns in romfs_list.walk(real):
        for n in ns: place(os.path.join(d, n), os.path.join(tmp, os.path.relpath(os.path.join(d, n), real)))
    for r in ov:
        q = os.path.join(tmp, r)
        if os.path.lexists(q): os.unlink(q)
        place(os.path.join(src, 'romfs', r), q)
    return tmp, tmp


def _romfs_img():
    """同目录的 pack/romfs_img.py，按文件路径加载：本文件常被作业层按文件路径加载（pack/jobs/sgrade_bf.py _img，spec_from_file_location），
    那时 pack/ 不在模块搜索路径里，裸 import romfs_img 找不到（11-16 资源包是 game.img、要补片上读取着色器的款装机「放进手机」一步 job_failed）"""
    import importlib.util
    mod = sys.modules.get('s2a_pack_romfs_img')
    if mod is None:
        spec = importlib.util.spec_from_file_location('s2a_pack_romfs_img', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'romfs_img.py'))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules['s2a_pack_romfs_img'] = mod
    return mod


def std_files(path, base):
    """IMG 里标准 RomFS 段（起点 base）的文件表 → {相对路径: (game.img 里的绝对偏移, 长度)}；按公开格式只读元数据，不读文件数据（解析只此一份：pack/romfs_img.py）"""
    return _romfs_img().RomfsImage(path, base).files()


def write_map(pack_dir, img_path):
    """按资源包 romfs.s2aidx 的文件顺序写 game.imgmap：被覆盖的文件（资源包 romfs_overlay/ 下有）记 -1，其余是它在 game.img 标准 RomFS 段里的绝对偏移，
    长度必须与索引一致（原件与覆盖后只差被覆盖的那几个文件），对不上报红。→ 写好的路径；资源包没有 romfs.s2aidx → None"""
    idx = os.path.join(pack_dir, 'romfs.s2aidx')
    if not os.path.isfile(idx): return None
    import romfs_image
    _, files = romfs_image.parse_index(idx)
    over = {r[len('romfs_overlay/'):] for r, _ in pack_rows(pack_dir) if r.startswith('romfs_overlay/')}
    h = header(img_path); seg = std_files(img_path, h['romfs'][0]) if h['romfs'][1] else {}
    offs = []
    for _, n, rel in files:
        if rel in over: offs.append(-1); continue
        if rel not in seg: raise Red(f'romfs.s2aidx 里的 {rel} 不在 game.img 的 RomFS 段，也不在覆盖层')
        if seg[rel][1] != n: raise Red(f'{rel} 长度对不上：索引 {n}，IMG 里原件 {seg[rel][1]}（又不在覆盖层）')
        offs.append(seg[rel][0])
    out = os.path.join(pack_dir, MAP)
    with open(out + '.tmp', 'wb') as f: f.write(romfs_image.MAGIC + struct.pack('<qi', h['total'], len(offs)) + struct.pack(f'<{len(offs)}q', *offs))
    os.replace(out + '.tmp', out)
    return out


def pack_rows(pack_dir):
    """资源包 index.tsv 的行 → [(路径, 整行)]（跳过空行与清单自身）"""
    out = []
    for line in open(os.path.join(pack_dir, 'index.tsv'), encoding='utf-8'):
        rel = line.split('\t', 1)[0]
        if rel and rel not in ('index.tsv', 'manifest.json'): out.append((rel, line if line.endswith('\n') else line + '\n'))
    return out


def image_id(pack_dir):
    """IMG 的资源包号：清单里进 IMG 那部分行（除着色器库 / 覆盖层之外，各行带每个文件的 SHA-256）的 SHA-256。
    只随游戏原始资源变：着色器库重编、覆盖层更新都不改它，IMG 字节不变、启动器续传认得出是同一份"""
    import hashlib
    return hashlib.sha256(''.join(l for r, l in pack_rows(pack_dir) if not r.startswith(KEEP)).encode('utf-8')).hexdigest()


def tool_error(text):
    """工具失败的原文 → 报红用的一段：.NET 未处理异常先一行「类型: 消息」、再一长串调用栈；原先只取末尾 300 字，正好把第一行截掉，
    玩家日志里只剩「FileStorage.Read(...)」看不出是删不掉、找不到还是读短了（#796）。有异常行就放前面，再接末尾"""
    text = (text or '').strip()
    head = next((l.strip() for l in text.splitlines() if l.startswith('Unhandled exception.') or re.match(r'\s*[\w.]+(Exception|Error): ', l)), '')
    tail = text[-300:]
    return f'{head[:300]} …… {tail}' if head and head[:300] not in tail else tail


def default_romfs_index():
    """发版应用 Windows：预编工具 S2A_PREBUILT_TOOLS/romfs/romfs_index.exe（NativeAOT 单文件，Windows 没有 bash、不带 .NET）直接执行；
    Mac 发版件经 services/romfs_index.sh 执行同一份预编件；开发树：services/romfs_index.sh 现编"""
    pre = os.environ.get('S2A_PREBUILT_TOOLS')
    if pre and os.path.isfile(os.path.join(pre, 'romfs', 'romfs_index.exe')):
        return shlex.quote(os.path.join(pre, "romfs", "romfs_index.exe"))
    return f'bash {shlex.quote(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "services", "romfs_index.sh"))}'


def writable(path):
    """整棵目录加回写权限（只改目录：删文件看的是目录权限；Windows 的只读文件由删的那一方去掉只读属性）"""
    import stat
    for d, _, _ in romfs_list.walk(path):   # RomFS 遍历只走 romfs_list（romfs_walk_lint）
        try: os.chmod(d, os.stat(d).st_mode | stat.S_IWUSR)
        except OSError: pass


def drop_tree(path):
    """删一棵可能只读的目录（RomFS 共享存储）；是链接只删链接本身"""
    import shutil, stat
    if os.path.islink(path) or _is_junction(path):   # 链接 / Windows 目录联接：只删它自己（Windows 上指向目录的要 rmdir）
        (os.rmdir if os.name == 'nt' and os.path.isdir(path) else os.unlink)(path); return
    if not os.path.isdir(path): return
    writable(path)
    def unlock(fn, p, _):   # 删不动：它自己和上一级都加回读写（目录还要能进）再删一次（同 library._rm；Windows 只读文件去掉只读属性）
        for q in (os.path.dirname(p), p):
            try: os.chmod(q, os.stat(q).st_mode | stat.S_IRWXU)
            except OSError: pass
        fn(p)
    os.chmod(os.path.dirname(os.path.abspath(path)), os.stat(os.path.dirname(os.path.abspath(path))).st_mode | stat.S_IRWXU)
    shutil.rmtree(path, onexc=lambda fn, p, e: unlock(fn, p, e)) if sys.version_info >= (3, 12) else shutil.rmtree(path, onerror=unlock)


def _is_junction(path):
    try: return bool(getattr(os.path, 'isjunction', lambda _: False)(path))
    except OSError: return False


def free_clones(root, keep, pack_dir, work=None):
    """边写边删之前（#746）：和这次读的 RomFS（keep）共享数据块的其余各份都删掉，只留 keep 这一份——APFS 克隆 / 硬链要所有份都删了才真腾出空间。
    各份都在这款的出包工作目录里，从产物根自己的记录找，不按路径猜：
      产物根各版本里是真目录的 romfs（链接不占空间，留着）、RomFS 共享存储（roots/.romfs_store/<款>/）里别的身份、seed.txt 记的解包目录 src/romfs、各版本与解包目录里的 RomFS 镜像 romfs.std（单个文件，keep 本身也可以是它）、
      资源包清单里的 RomFS 行（Mac 是克隆、Windows 是另一份拷贝；本来写完 IMG 就删）和旧形态库内镜像 romfs.files。
    出包收尾本来就清掉整个出包工作目录（pack/jobs/library.py prune_build），这里只是提前；写到一半失败由调用方清掉整个工作目录、下次重新解包。
    work：这款的出包工作目录（作业层传 build/ios）。删的每一份都必须在它里面——玩家导入的原件（NSP / XCI，包括外接盘上只读引用的）、
    工作目录外的解包目录（命令行 --from-extract 给的）任何时候都不删；没给按产物根的上两级（roots/ 的上一级）"""
    keep = os.path.realpath(keep)
    roots_dir = os.path.dirname(os.path.abspath(root))
    work = os.path.realpath(work or os.path.dirname(roots_dir))
    def inside(p): return os.path.realpath(p).startswith(work + os.sep)
    def other(p): r = os.path.realpath(p); return r != keep and not keep.startswith(r + os.sep) and inside(p)
    def drop_image(p):   # RomFS 镜像 romfs.std（单个文件，各版本间是克隆 / 硬链接，同一族）：别的名字都删了，这一份的块才真腾出来
        if os.path.isfile(p) and not os.path.islink(p) and other(p): os.unlink(p)
    for v in romfs_list.listdir(roots_dir):
        rf = os.path.join(roots_dir, v, 'romfs')
        if not v.startswith('.'): drop_image(rf + '.std')   # 镜像形态（RomFS 不落散文件）：各版本里是真文件的 romfs.std 同理
        if v.startswith('.') or os.path.islink(rf) or _is_junction(rf) or not os.path.isdir(rf): continue
        if other(rf): drop_tree(rf)
    store = os.path.join(roots_dir, '.romfs_store')
    if os.path.isdir(store):
        for g in romfs_list.listdir(store):
            for ident in romfs_list.listdir(os.path.join(store, g)):
                d = os.path.join(store, g, ident)
                if os.path.isdir(d) and other(d): drop_tree(d)
    sf = os.path.join(root, 'seed.txt')
    src = next((l[4:].strip() for l in open(sf, encoding='utf-8') if l.startswith('src=')), '') if os.path.isfile(sf) else ''
    if src:
        s = os.path.join(src, 'romfs')
        if os.path.lexists(s) and not os.path.islink(s) and not _is_junction(s) and other(s): drop_tree(s)
        drop_image(s + '.std')
    if not inside(pack_dir): return   # 资源包不在工作目录里（只可能是手工调用）：不碰
    for rel, _ in pack_rows(pack_dir):
        if rel.startswith(SKIP) and not rel.startswith(KEEP):
            try: os.unlink(os.path.join(pack_dir, rel))
            except FileNotFoundError: pass
    drop_tree(os.path.join(pack_dir, 'romfs.files'))
    try: os.unlink(os.path.join(pack_dir, 'romfs.std'))   # 镜像形态的库内镜像（pack/romfs_image.py 硬链的，不在清单里）
    except FileNotFoundError: pass


def program_romfs(pack_dir, rel):
    """多程序合集序号 n 的 RomFS 行（#1782）：清单里叫 programs/<n>/romfs.img，库内实际是标准 RomFS 镜像 programs/<n>/romfs.std
    （0.6.0 起 RomFS 不落散文件，pack/oneclick/deliver_pack.py 交付的就是它）→ 改成按 programs/<n>/romfs.std 进 IMG，手机解回来
    宿主照它读（services Application.cs：romfs/ 不在就找同目录 romfs.std，序号 n 的 programs/<n>/ 同一套）。
    旧形态 romfs.files/（镜像各文件的硬链接）进不了 IMG：报红说清楚要重新出包。其余行原样 → (进 IMG 的相对路径, 源文件)"""
    src = os.path.join(pack_dir, rel)
    if not (rel.startswith('programs/') and rel.endswith('/romfs.img')) or os.path.isfile(src): return rel, src
    std = src[:-len('romfs.img')] + 'romfs.std'
    if os.path.isfile(std): return rel[:-len('romfs.img')] + 'romfs.std', std
    if os.path.isdir(src[:-len('romfs.img')] + 'romfs.files'):
        raise Red(f'资源包里 {rel[:-len("romfs.img")]} 的 RomFS 还是旧形态（romfs.files），进不了单一 IMG：对这款重新出包')
    return rel, src


def write(root, pack_dir, out_path, progress=None, romfs_index=None, gid=None, consume=False, work=None):
    """产物根 root 的完整原始 romfs/ 建标准 RomFS 段（库里的 romfs.files 缺被覆盖层替换的原文件，不能用它建；产物根只有 romfs.std 时原样拷这段），
    资源包 pack_dir 清单（index.tsv）里的其余原始资源进其余文件段；游戏号 gid（没给取 root/unpack.tsv），资源包号 = image_id。
    多程序合集序号 1.. 的 programs/<n>/…（#1545）同其余资源一样进其余文件段：手机解包（pack_apply.c img_extract）按原路径解回 资源包/programs/<n>/，
    宿主照旧按文件读。原先报红不出 IMG，资源包永远是旧形态，「导出自签包」永远判旧格式、重出包也一样。原子写（先 .part 再改名）"""
    say = progress or (lambda *_: None)
    gid = gid or next((l.rstrip('\n').split('\t', 1)[1] for l in open(os.path.join(root, 'unpack.tsv'), encoding='utf-8') if l.startswith('title_id\t')), '')
    others = []
    for rel, _ in pack_rows(pack_dir):
        if rel.startswith(SKIP): continue
        rel, src = program_romfs(pack_dir, rel)
        if not os.path.isfile(src): raise Red(f'资源包清单里的 {rel} 不在 {pack_dir}')
        others.append((rel, src))
    rom, tmp = orig_romfs(root, os.path.dirname(os.path.abspath(out_path)))
    try:
        if consume and rom: free_clones(root, rom, pack_dir, work)
        return build(rom, others, out_path, gid, image_id(pack_dir), romfs_index or default_romfs_index(), say=say, consume=consume and bool(rom))
    finally:
        if tmp:
            import shutil; shutil.rmtree(tmp, ignore_errors=True)


def convert(root, pack_dir, progress=None, romfs_index=None, gid=None, consume=False, work=None):
    """出包交付（pack/jobs/ipa.py deliver）：资源包目录就地转成 IMG 形态——game.img（游戏原始资源）+ 照旧按文件的着色器库 / 覆盖层 +
    新 index.tsv（game.img 一行，第三列 = 资源包号；其余行原样）+ manifest.json v3（format img、imgFile、index_sha256 = 新 index.tsv 的 SHA-256）。
    进了 IMG 的旧形态文件删掉（多程序合集的 programs/ 同样进 IMG，见 write）。→ game.img 路径"""
    import hashlib, json
    rows = pack_rows(pack_dir)
    out = os.path.join(pack_dir, 'game.img')
    write(root, pack_dir, out, progress, romfs_index, gid, consume, work)
    h = header(out)
    mp = write_map(pack_dir, out)
    ix = f"game.img\t{h['total']}\t{h['pack_id']}\n" + ''.join(l for r, l in rows if r.startswith(KEEP))
    if mp: ix += f"{MAP}\t{os.path.getsize(mp)}\t{hashlib.sha256(open(mp, 'rb').read()).hexdigest()}\n"
    def put(name, text):
        tmp = os.path.join(pack_dir, name + '.tmp')
        with open(tmp, 'w', encoding='utf-8', newline='\n') as f: f.write(text)
        os.replace(tmp, os.path.join(pack_dir, name))
    # 先换清单、最后删旧形态文件（审计 P1-171：原先先删再换清单，中间断了清单指着已删的文件，再跑 convert 报文件不在）。
    #   清单换上后再断：旧文件只是多占空间，清单已经是 IMG 形态、照常能用
    put('index.tsv', ix)
    total = sum(int(l.split('\t')[1]) for l in ix.splitlines())
    put('manifest.json', json.dumps({'version': 3, 'format': 'img', 'imgFile': 'game.img', 'files': len(ix.splitlines()), 'total': total,
                                     'index_sha256': hashlib.sha256(ix.encode('utf-8')).hexdigest()}, indent=1) + '\n')
    for rel, _ in rows:
        if not rel.startswith(KEEP):
            try: os.unlink(program_romfs(pack_dir, rel)[1])   # 多程序合集的 RomFS 行库内是 romfs.std（#1782）：删的是实际那份
            except FileNotFoundError: pass
    import shutil
    shutil.rmtree(os.path.join(pack_dir, 'romfs.files'), ignore_errors=True)   # 旧形态库内镜像的硬链接目录（#329，不在清单里）：IMG 已有原件
    try: os.unlink(os.path.join(pack_dir, 'romfs.std'))   # 镜像形态的库内镜像（pack/romfs_image.py 硬链的，不在清单里）：IMG 已有这段
    except FileNotFoundError: pass
    for d, subs, files in os.walk(pack_dir, topdown=False):   # 删空了的目录
        if d != pack_dir and not os.listdir(d): os.rmdir(d)
    return out


def export(pack_dir, out_path):
    """自签导出用的「一款一个文件」（install.export_phone）：IMG 形态资源包的 game.img + 照旧按文件放的派生件（着色器库 shaders/、界面覆盖层 romfs_overlay/、
    romfs.s2aidx、game.imgmap）写成一个 IMG：派生件进其余文件段的目录表，手机认领后照常从 game.img 解出来（pack_apply.c img_extract 解目录表里的每一项）。
    原 game.img 不动：先复制（APFS 克隆不占新空间，别的盘实拷、报字节进度），截掉旧目录表，尾部页对齐追加派生件与 game.imgmap（总长度改成新文件的，
    RomFS 段偏移不变），再写新目录表、改头里的目录表偏移 / 长度 / 文件长。原子写（先 .part 再改名）。→ 输出路径"""
    import shutil
    src = os.path.join(pack_dir, 'game.img'); h = header(src)
    old = entries(src); have = {p for p, _, _ in old}
    extras = sorted((rel, os.path.join(pack_dir, rel)) for rel, _ in pack_rows(pack_dir) if rel.startswith(KEEP))
    for rel, p in extras:
        if rel in have: raise Red(f'{rel} 已在 game.img 目录表里')
        if not os.path.isfile(p): raise Red(f'资源包清单里的 {rel} 不在 {pack_dir}')
    mp = os.path.join(pack_dir, MAP); mapb = bytearray(open(mp, 'rb').read()) if os.path.isfile(mp) else None
    part = out_path + '.part'
    try:
        cloned = False
        if sys.platform == 'darwin':
            cloned = subprocess.run(['cp', '-c', src, part], capture_output=True).returncode == 0
        if not cloned:   # 不能克隆（Windows NTFS / 跨盘）：实拷，报字节进度（几十 GB 要一两分钟）
            tk = Ticker('导出单文件 IMG', os.path.getsize(src))
            with open(src, 'rb') as a, open(part, 'wb') as b:
                while chunk := a.read(1 << 22): b.write(chunk); tk.step(len(chunk))
        pos, new = h['toc'][0], list(old)
        with open(part, 'r+b') as f:
            f.truncate(pos)
            for rel, p in extras:
                pos = up(pos); f.seek(pos); size = 0
                with open(p, 'rb') as s:
                    while chunk := s.read(1 << 22): f.write(chunk); size += len(chunk)
                new.append((rel, pos, size)); pos += size
            if mapb is not None:
                pos = up(pos); map_off = pos; new.append((MAP, pos, len(mapb))); pos += len(mapb)
            pos = up(pos); toc = toc_bytes(new); total = pos + len(toc)
            if mapb is not None:   # 偏移表头里记的是整个 game.img 的长度（RomFsIndex.OpenImg 核它）：换成这个文件的
                struct.pack_into("<q", mapb, 8, total); f.seek(map_off); f.write(mapb)
            f.seek(pos); f.write(toc); f.truncate(total)
            m, fmt, x, gid, pid, ro, rl, _, _, _ = HDR.unpack(open(src, 'rb').read(HDR.size))
            f.seek(0); f.write(HDR.pack(m, fmt, x, gid, pid, ro, rl, pos, len(toc), total))
        os.replace(part, out_path)
    finally:
        if os.path.exists(part): os.unlink(part)
    return out_path


UPDATE_FORMAT = 2   # 着色器更新包（只含派生件）：手机按格式号 2 走「套到本机已有本体」（runtime/src/pack_apply.c img_update）；只认 1 的旧版 S2Arm 会说「请更新 S2Arm」


def update_worth(pack_dir):
    """这款值不值得出着色器更新包：资源包里有着色器库（shaders/）或界面覆盖层（romfs_overlay/）才出。只剩索引 / 偏移表的包
    （没有直连着色器库的款）一百多 KB、什么都不换，导出了玩家以为坏了（诊断 #0c0f75）"""
    return any(rel.startswith(('shaders/', 'romfs_overlay/')) for rel, _ in pack_rows(pack_dir))


def update_pack(pack_dir, out_path):
    """自签导出的「着色器更新包」（维护者 11-13：几百 MB，不用重拷 5 GB 本体）：IMG 形态资源包里照旧按文件放的派生件（KEEP：着色器库、界面覆盖层、
    romfs.s2aidx）+ game.imgmap 写成一个格式号 2 的 IMG，头里的游戏号 / 资源包号照抄本体 game.img（资源包号只随游戏原始资源变，同款同构建才相同），
    没有 RomFS 段。手机认领时核本体资源包号一致才套。→ 输出路径"""
    src = os.path.join(pack_dir, 'game.img'); h = header(src)
    others = [(rel, os.path.join(pack_dir, rel)) for rel, _ in pack_rows(pack_dir) if rel.startswith(KEEP)]
    for rel, p in others:
        if not os.path.isfile(p): raise Red(f'资源包清单里的 {rel} 不在 {pack_dir}')
    mp = os.path.join(pack_dir, MAP)
    if os.path.isfile(mp): others.append((MAP, mp))
    if not others: raise Red('这款资源包没有派生件（着色器库 / 覆盖层），出不了更新包')
    build(None, others, out_path, h['gid'], h['pack_id'], say=lambda *_: None)
    with open(out_path, 'r+b') as f:   # 格式号改成 2（build 写的是完整 IMG 的 1）
        f.seek(8); f.write(struct.pack('<I', UPDATE_FORMAT))
    return out_path


def is_img(path):
    try:
        with open(path, 'rb') as f: return f.read(8) == MAGIC
    except OSError:
        return False


def header(path):
    with open(path, 'rb') as f: b = f.read(HDR.size)
    m, fmt, _, gid, pid, ro, rl, to, tl, total = HDR.unpack(b)
    if m != MAGIC: raise Red('不是 IMG')
    return dict(format=fmt, gid=gid.decode('ascii'), pack_id=pid.rstrip(b'\0').decode('ascii'), romfs=(ro, rl), toc=(to, tl), total=total)


def entries(path):
    h = header(path)
    with open(path, 'rb') as f:
        f.seek(h['toc'][0]); t = f.read(h['toc'][1])
    slots, n = struct.unpack_from('<II', t, 0); base = 8 + slots * SLOT.size; out = []
    for i in range(slots):
        hh, off, size, po, pl = SLOT.unpack_from(t, 8 + i * SLOT.size)
        if hh: out.append((t[base + po: base + po + pl].decode('utf-8'), off, size))
    return sorted(out)


def find(path, rel):
    """按路径 O(1) 查目录表 → (偏移, 长度) 或 None（与运行时读法同一算法）"""
    h = header(path)
    with open(path, 'rb') as f:
        f.seek(h['toc'][0]); t = f.read(h['toc'][1])
    slots, _ = struct.unpack_from('<II', t, 0); base = 8 + slots * SLOT.size; want = fnv(rel); k = want & (slots - 1)
    while True:
        hh, off, size, po, pl = SLOT.unpack_from(t, 8 + k * SLOT.size)
        if not hh: return None
        if hh == want and t[base + po: base + po + pl].decode('utf-8') == rel: return off, size
        k = (k + 1) & (slots - 1)


def main(argv=None):
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest='cmd', required=True)
    b = sp.add_parser('build'); b.add_argument('romfs'); b.add_argument('others'); b.add_argument('out'); b.add_argument('--gid', required=True)
    b.add_argument('--pack-id', default=''); b.add_argument('--romfs-index')
    v = sp.add_parser('convert', help='资源包目录就地转 IMG 形态（出包交付）'); v.add_argument('root'); v.add_argument('pack_dir'); v.add_argument('--gid')
    v.add_argument('--consume', action='store_true', help='边写边删解包出来的 RomFS（#746：出包收尾本来就清，提前到写 IMG 时；写到一半失败要重新解包）')
    v.add_argument('--work', help='这款的出包工作目录：--consume 只删它里面的（玩家原件、外面的解包目录不碰）')
    x = sp.add_parser('export', help='自签导出：game.img + 着色器库等派生件写成一个文件'); x.add_argument('pack_dir'); x.add_argument('out')
    u = sp.add_parser('update', help='自签导出的着色器更新包：只含派生件，配同款同构建的本体'); u.add_argument('pack_dir'); u.add_argument('out')
    l = sp.add_parser('ls'); l.add_argument('img')
    a = ap.parse_args(argv)
    try:
        if a.cmd == 'build':
            others = [tuple(l.rstrip('\n').split('\t', 1)) for l in open(a.others, encoding='utf-8') if '\t' in l]
            build(None if a.romfs == '-' else a.romfs, others, a.out, a.gid, a.pack_id, a.romfs_index)
        elif a.cmd == 'export':
            print(export(a.pack_dir, a.out))
        elif a.cmd == 'update':
            print(update_pack(a.pack_dir, a.out))
        elif a.cmd == 'convert':
            print(convert(a.root, a.pack_dir, gid=a.gid, consume=a.consume, work=a.work))
        else:
            print(header(a.img))
            for e in entries(a.img): print(*e, sep='\t')
    except (Red, OSError) as e:
        if isinstance(e, OSError):   # 系统调用报错不带是哪一步（D-X5JB 只剩「[Errno 13] Permission denied」）：出错的那一行先打出来进 img.log，红行照旧
            import traceback
            f = traceback.extract_tb(e.__traceback__)[-1]
            print(f'出错位置：{os.path.basename(f.filename)}:{f.lineno} {f.name}：{f.line}', flush=True)
        print(f'【红】{e}'); return 1
    except Exception as e:   # 意料之外的错也打一行红（带类型）：作业层摘失败原因只认红行 / 末行（#711：原先只剩调用栈，摘要里成了别的日志行）
        print(f'【红】写 IMG 时出了没料到的错：{type(e).__name__}: {e}', flush=True); raise
    return 0


if __name__ == '__main__':
    sys.exit(main())
