#!/usr/bin/env python3
"""资源包 v2（底本旧库 tools/pack.py @main，出包线 10-19）：pack.py <输出包目录> <包内前缀>=<源目录>|<包内路径>=<源文件>|@<清单文件> …  [--check]
例：pack.py out/acnh/pack romfs=data/acnh/romfs sysfont=data/sysfont/bin aoc=data/acnh/aoc
产物：<输出包目录>/manifest.json（version 2、文件数、总字节、index_sha256）、index.tsv（路径<TAB>字节数<TAB>SHA-256，按参数顺序、目录内字节序）、
  以及每个文件本身（路径 = index 里的路径）；macOS 用 APFS 克隆（clonefile，不占新空间；跨卷退回普通拷贝），Windows 用 ReFS 块克隆（tools/refs_clone.py；跨卷 / NTFS 退回拷贝、打一行黄），Linux 用独立文件复制。
按文件放（不切卷）：推送按单文件比 SHA-256，换包只推变了的文件（真机执行器 tools/dev_run.sh）。
SHA-256 记在 <输出包目录>.state.tsv（路径、字节数、源 mtime 纳秒、SHA、源 inode、源 ctime 纳秒）：源字节数与 mtime 都没变、包里那份在，
  且源的 inode 与 ctime 也没变就沿用，不重读；inode / ctime 变了（换了一份同大小同 mtime 的文件、或改了内容又把 mtime 改回去——utime / tar / rsync -a / cp -p
  都会动 ctime，用户工具改不回 ctime）就重算源的 SHA，与状态表相同才沿用（审计 #1592 P1-54：romfs / aoc / shaders 原先只比大小与 mtime，内容换了包里仍是上一版）。
  代价：RomFS 在只读内容存储里（pack/roots.sh），新版本根照旧软链过去，inode / ctime 不变、不重读；每出一个新根，克隆来的 aoc / shaders 重读一遍
  （11-06 本机现行根最大一款异度神剑3：aoc 4.5 GB + shaders 0.65 GB；单线程 SHA-256 2.54 GB/s，并行算）。旧格式状态表（4 列）首次全部重算一次。
  Windows 上 os.stat 的 ctime 是创建时间：原地改内容再改回 mtime 抓不到，换成另一个文件（tar / rsync 新建、inode 变）照样抓到。
  按全内容进包键的那几类（系统数据、RomFS 索引、npdm / nacp 等，pack/pkg_inputs_key.py content_keyed）照旧每次比源的 SHA（审计 #1534 P1-54）。
只跳过 macOS 垃圾（.DS_Store、._*）：游戏数据里有点开头的真文件（旧库暗黑2 CASC 的 data/.build.config 漏收 → 真机启动即返回）。
源目录不在、旁边有 <源目录>.std（标准 RomFS 镜像，RomFS 不落散文件）：index.tsv 照旧逐文件记（与目录形态逐字节相同），包里放一份镜像克隆 <包内前缀>.std、不拆散文件。
--check：清单最新则退出 0，否则 1（不改任何文件）。"""
import ctypes, hashlib, json, multiprocessing as mp, os, shutil, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from pool_workers import process_pool_size, env_jobs   # 进程池路数（Windows 至多 61，#1332）
from progress import Ticker   # 出包进度（S2A_PROGRESS，tools/progress.sh）：克隆 + 算 SHA 两段按文件数记
from refs_clone import clone_file as refs_clone   # Windows ReFS / 开发驱动器块克隆（#1100）
import sha256_fast   # 文件 SHA：Windows 走 CNG（hashlib 在玩家 Python 上没用 SHA 指令，Windows 出包机单核 0.37 → 1.46 GB/s）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pkg_inputs_key import content_keyed   # 哪些源按全内容进包键（同一份判法）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'nvn', 'tools'))
import romfs_list   # 源目录遍历一律经它（tools/romfs_walk_lint.py）；目录不在、旁边有 <目录>.std 时从标准 RomFS 镜像列
COPIED = [0]   # Windows 上没克隆成、退回整份拷贝的文件数（收尾打一行黄）
LINKED = [0]   # Windows 上没克隆成、改用同卷硬链接的文件数
NJ = env_jobs('J', 'S2A_JOBS')   # 并行路数（tools/cores.sh S2A_JOBS）
if sys.platform == 'darwin':
    libc = ctypes.CDLL('libc.dylib', use_errno=True); libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
def copy_sha(src, dst):   # 整份拷贝、边拷边算 SHA-256（11-06 出包速度线：拷完再回头读一遍源算 SHA，0100F2C0115B6000 16 GB 多读一遍）→ SHA
    h = sha256_fast.new()
    with open(src, 'rb') as f, open(dst, 'xb') as g:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b); g.write(b)
    shutil.copystat(src, dst)
    return h.hexdigest()
MADE = set()   # 已建的包内目录（每个只 makedirs 一次）
OUT_REFS = [None]   # 资源包目录所在卷是不是 ReFS（Windows，第一次克隆时判）
def clone(src, dst):   # → 拷贝时顺手算出的 SHA；块克隆（不读数据）→ None，由调用方另算
    d = os.path.dirname(dst)
    if d not in MADE: os.makedirs(d, exist_ok=True); MADE.add(d)
    if os.path.lexists(dst): os.remove(dst)
    if sys.platform == 'win32':   # ReFS 同卷块克隆（不占新空间）；跨卷 / NTFS 退回拷贝并计数
        if OUT_REFS[0] is None:   # 资源包目录所在卷（解开联接）是不是 ReFS / 开发驱动器：整次出包只问一次，不是就不再逐个试块克隆
            import refs_clone as rc
            OUT_REFS[0] = rc._volume_fs(os.path.splitdrive(os.path.realpath(os.path.dirname(dst)))[0].upper()).upper() == 'REFS'
        if OUT_REFS[0] and refs_clone(src, dst): return None
        # 不是 ReFS / 开发驱动器（玩家 NTFS）：同卷硬链接，不写数据（11-06 出包速度线：Windows 出包机 C 盘 NTFS 0100F2C0115B6000 30.5 万个文件
        #   整份拷贝 2547 秒；封存存储文件实测可建硬链接、每个 0.17 毫秒，删链接只靠父目录「删除子项」权限、原件封存不变）。
        #   资源包的源是不可变的产物根版本与封存存储，流程里不原地改，所以共用文件对象不会让包里内容跟着变；核对 verify.py 见同一文件只算一遍 SHA
        try:
            os.link(src, dst); LINKED[0] += 1; return None
        except OSError:
            pass
        COPIED[0] += 1
        return copy_sha(src, dst)
    if sys.platform != 'darwin':
        shutil.copy2(src, dst)
        return
    if libc.clonefile(os.fsencode(src), os.fsencode(dst), 0) != 0:
        e = ctypes.get_errno()
        if e not in (18, 45, 1): raise OSError(e, os.strerror(e), dst)   # EXDEV / ENOTSUP / EPERM 才退回普通拷贝
        shutil.copy2(src, dst)
def sha_file(p):   # p：文件路径，或镜像里的一个文件 (镜像路径, 偏移, 长度, 包里那份镜像的包内路径)
    h = sha256_fast.new()
    if isinstance(p, tuple):
        img, off, left, _ = p
        with open(img, 'rb') as f:
            f.seek(off)
            while left:
                b = f.read(min(1 << 22, left))
                if not b: raise OSError(f'{img} 里偏移 {off} 起读不满')
                h.update(b); left -= len(b)
        return h.hexdigest()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return h.hexdigest()
def sha_block(ps):
    return [sha_file(p) for p in ps]


def main():
    if sys.platform == 'win32':
        # 管道默认使用本地代码页；进度与错误文本统一为 UTF-8。
        for stream in (sys.stdout, sys.stderr):
            if hasattr(stream, 'reconfigure'): stream.reconfigure(encoding='utf-8')
    CHECK = '--check' in sys.argv; args = [a for a in sys.argv[1:] if a != '--check']
    # @<文件>：源清单从文件读（每行一项）。巫师3 着色器 8687 个文件逐个列成参数约 1 MB，超 ARG_MAX（10-24 出包「Argument list too long」）
    args = [l for a in args for l in (open(a[1:], encoding='utf-8').read().splitlines() if a.startswith('@') else [a]) if l]
    if len(args) < 2: sys.exit(__doc__)
    out = os.path.abspath(args[0]); roots = []
    for a in args[1:]:
        name, _, src = a.partition('=')
        bad = not name or not src or name in ('manifest.json', 'index.tsv') or name.startswith('/') or '..' in name.split('/')
        if bad: sys.exit(f'参数应为 <包内前缀>=<源目录> 或 <包内路径>=<源文件>（不许绝对路径和 ..）：{a}')
        if not os.path.exists(src) and not romfs_list.image_of(src): sys.exit(f'源不存在：{src}')
        roots.append((name, os.path.abspath(src)))
    STATE = out.rstrip('/') + '.state.tsv'
    files = []   # (包内路径, 源路径, 字节数, 源 mtime 纳秒, 源 inode, 源 ctime 纳秒)
    ck = {}   # 按全内容进包键的文件：包内路径 → 源路径（沿用要比内容，见文件头）
    for name, root in roots:
        if os.path.isfile(root):   # 单个文件：包内路径就是参数里的名字（如 exefs/main.npdm）
            st = os.stat(root); files.append((name, root, st.st_size, st.st_mtime_ns, st.st_ino, st.st_ctime_ns))
            if content_keyed(name): ck[name] = root
            continue
        # 源目录不在、旁边有 <源目录>.std（标准 RomFS 镜像，RomFS 不落散文件）：条目与顺序同目录形态，字节数取镜像记的长度，
        #   修改时间 / inode / ctime 取镜像文件的（镜像换了全部重算）；包里放一份镜像克隆 <前缀>.std，不拆成散文件，index.tsv 照旧逐文件记
        tree = romfs_list.scan(root, stat_entries=False); im = tree.image
        spans, ist = (im.files(), os.stat(im.path)) if im is not None else (None, None)
        for d, ds, fs in tree.walk():
            ds.sort()
            for f in sorted(fs):
                if f == '.DS_Store' or f.startswith('._'): continue
                p = os.path.join(d, f); r = os.path.relpath(p, root).replace(os.sep, '/'); rel = name + '/' + r
                if '\t' in rel or '\n' in rel: sys.exit(f'路径带制表符 / 换行，index.tsv 记不了：{rel!r}')
                if im is not None:
                    p = (im.path, *spans[r], name + '.std'); files.append((rel, p, spans[r][1], ist.st_mtime_ns, ist.st_ino, ist.st_ctime_ns))
                else:
                    st = os.stat(p); files.append((rel, p, st.st_size, st.st_mtime_ns, st.st_ino, st.st_ctime_ns))
                if content_keyed(name): ck[rel] = p
    # 同一包内路径出现多次（界面布局覆盖层叠在 romfs/ 上，pack/pkg_srcs.py）：后给的源优先，位置留在第一次出现处
    pos, merged = {}, []
    for f in files:
        if f[0] in pos: merged[pos[f[0]]] = f
        else: pos[f[0]] = len(merged); merged.append(f)
    files = merged; ck = {rel: merged[pos[rel]][1] for rel in ck}
    held = {rel: p[3] for rel, p, *_ in files if isinstance(p, tuple)}   # 从镜像来的文件 → 包里那份镜像（<前缀>.std）的包内路径
    stds = {p[3]: p[0] for _, p, *_ in files if isinstance(p, tuple)}   # 包里那份镜像 → 源镜像
    state = {}
    try:
        for l in open(STATE, encoding='utf-8'):
            c = l.rstrip('\n').split('\t'); rel, sz, mt, sha = c[:4]
            state[rel] = (int(sz), int(mt), sha, int(c[4]) if len(c) > 5 else None, int(c[5]) if len(c) > 5 else None)   # 旧格式（4 列）没有 inode / ctime：按身份变了处理
    except (OSError, ValueError): state = {}
    csha = {}   # 要比内容的源（按全内容进包键的、身份变了的）：算过的 SHA
    def same_size_mtime(rel, sz, mt):   # 从镜像来的：包里那份是整个镜像，比它与源镜像同长
        s = state.get(rel); q = os.path.join(out, held.get(rel, rel)); qsz = os.path.getsize(stds[held[rel]]) if rel in held else sz
        return bool(s and s[0] == sz and s[1] == mt and os.path.isfile(q) and os.path.getsize(q) == qsz)
    # 大小 + mtime 都对上、包里那份在，但要比内容的：全内容进包键的，或源 inode / ctime 与状态表不同的 → 并行算一遍源 SHA（判沿用与写 index 共用）
    need = [(rel, p) for rel, p, sz, mt, ino, ct in files if same_size_mtime(rel, sz, mt) and (rel in ck or state[rel][3:] != (ino, ct))]
    if need:
        method = 'fork' if 'fork' in mp.get_all_start_methods() else 'spawn'
        ps = [p for _, p in need]
        with mp.get_context(method).Pool(process_pool_size(NJ)) as pool: hs = [h for part in pool.imap(sha_block, [ps[i:i + 64] for i in range(0, len(ps), 64)]) for h in part]
        for (rel, _), h in zip(need, hs): csha[rel] = h
    def fresh(rel, sz, mt):
        if not same_size_mtime(rel, sz, mt): return False
        return csha[rel] == state[rel][2] if rel in csha else True
    def index_text(shas): return ''.join(f'{rel}\t{sz}\t{shas[rel]}\n' for rel, _, sz, *_ in files)
    if CHECK:
        try:
            m = json.load(open(os.path.join(out, 'manifest.json'), encoding='utf-8'))
            ok = m.get('version') == 2 and all(fresh(r, s, t) for r, _, s, t, *_ in files) and \
                 m.get('index_sha256') == hashlib.sha256(index_text({r: state[r][2] for r, *_ in files}).encode()).hexdigest()
        except (OSError, ValueError, KeyError): ok = False
        print('资源包已是最新' if ok else '资源包缺或过期'); sys.exit(0 if ok else 1)
    os.makedirs(out, exist_ok=True)
    todo = [(rel, p) for rel, p, sz, mt, *_ in files if not fresh(rel, sz, mt)]
    tk = Ticker('资源包', 2 * len(todo))
    copied = {}   # 拷贝时已算出 SHA 的（Windows 克隆不了的那些）：不再回头读源
    recloned = set()   # 从镜像来的：整个镜像克隆一次（Windows 退回拷贝时算出的是整个镜像的 SHA，不当逐文件的用）
    for rel, p in todo:
        if isinstance(p, tuple):
            if p[3] not in recloned: clone(p[0], os.path.join(out, p[3])); recloned.add(p[3])
        else:
            h = clone(p, os.path.join(out, rel))
            if h: copied[rel] = h
        tk.step()
    tset = {rel for rel, _ in todo}; shas = {rel: state[rel][2] for rel, *_ in files if rel not in tset}
    csha.update((rel, h) for rel, h in copied.items() if rel not in csha)
    if todo:
        method = 'fork' if 'fork' in mp.get_all_start_methods() else 'spawn'
        with mp.get_context(method).Pool(process_pool_size(NJ)) as pool:   # 只算新克隆 / 变了的文件
            need = [(rel, p) for rel, p in todo if rel not in csha]; ps = [p for _, p in need]   # 判沿用时已经算过 SHA 的不再算
            hs = []
            for part in pool.imap(sha_block, [ps[i:i + 64] for i in range(0, len(ps), 64)]):   # 每块 64 个算完就计（11-20 010015100B514000：原先整份算完才计一次，进度停 53 秒）
                hs += part; tk.step(len(part))
            for (rel, _), h in zip(need, hs): shas[rel] = h
            for rel, _ in todo:
                if rel in csha: shas[rel] = csha[rel]
            tk.step(len(todo) - len(need))
    keep = {rel for rel, *_ in files if rel not in held} | set(stds) | {'manifest.json', 'index.tsv'}   # 上一版有、这一版没有的文件删掉（镜像形态：散文件删掉、留 <前缀>.std）
    for d, ds, fs in os.walk(out, topdown=False):
        for f in fs:
            q = os.path.join(d, f)
            if os.path.relpath(q, out).replace(os.sep, '/') not in keep: os.remove(q)
        if d != out and not os.listdir(d): os.rmdir(d)
    ix = index_text(shas)
    with open(STATE + '.tmp', 'w', encoding='utf-8', newline='\n') as f: f.writelines(f'{rel}\t{sz}\t{mt}\t{shas[rel]}\t{ino}\t{ct}\n' for rel, _, sz, mt, ino, ct in files)
    os.replace(STATE + '.tmp', STATE)
    with open(os.path.join(out, 'index.tsv'), 'w', encoding='utf-8', newline='\n') as f: f.write(ix)
    total = sum(sz for _, _, sz, *_ in files)
    with open(os.path.join(out, 'manifest.json.tmp'), 'w', encoding='utf-8', newline='\n') as f:   # 清单最后写：有清单 = 包完整
        json.dump({'version': 2, 'files': len(files), 'total': total, 'index_sha256': hashlib.sha256(ix.encode()).hexdigest()}, f, indent=1)
    os.replace(os.path.join(out, 'manifest.json.tmp'), os.path.join(out, 'manifest.json'))
    if LINKED[0]: print(f'{LINKED[0]} 个文件不在 ReFS / 开发驱动器卷上、用同卷硬链接（不占新空间、包里文件与产物根共用）', file=sys.stderr)
    if COPIED[0]: print(f'【黄】{COPIED[0]} 个文件既没能块克隆、也没能建硬链接（资源包与产物根不在同一个卷上），整份拷贝了（多占同样大小的盘、慢）', file=sys.stderr)
    print(f'{len(files)} 个文件 {total / 2**30:.2f} GB（克隆 / 重算 {len(todo)} 个），{out}')


if __name__ == '__main__':
    main()
