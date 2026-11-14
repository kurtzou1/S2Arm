#!/usr/bin/env python3
# 资源包核对（出包闸门；底本旧库 tools/pack_verify.py）：verify.py <包目录> <前缀>=<源目录>|@<清单文件> …  → 包与源逐项一致退出 0，否则报红退出 1。
# 源清单由本脚本独立列（不复用 pack.py 的过滤）：各源目录下全部普通文件，只认 macOS 自己留的 .DS_Store / ._* 不算游戏文件。
# 核：① 清单 v2、index.tsv 的 SHA-256 = index_sha256 ② 路径集合相同（缺的、多的逐条列）③ 每个文件字节数相同
#     ④ 包里那份与源逐字节相同，且其 SHA-256 = index.tsv 记的（推送按它比，记错就漏推）⑤ 包目录里没有清单外的文件
# ④ 按上次核对通过时的记录增量做（<包目录>.verify.tsv，只在全绿时写）：源（字节数、mtime 纳秒）、包里那份（字节数、mtime 纳秒）、index 的 SHA 全都和上次一样的文件不再逐字节比；
#   其余照旧全量比（10-21：每版九款各重读 10–34 GB，核对 44–74 秒）。包里那份被改（哪怕同长）mtime 就变；源变了 pack.py 重克隆，包里那份带上新源的 mtime——都会重比。
#   不比 inode：新版本产物根整目录克隆自上一版，每个文件 inode 都是新的（10-21 实测带 inode 时一个都没跳过）
#   按全内容进包键的那几类（系统数据、RomFS 索引、npdm / nacp 等，pack/pkg_inputs_key.py content_keyed，合计几十 MB）不走增量、每次逐字节比（审计 #1534 P1-54：
#   源只换内容、保住大小与修改时间时，签名全同，旧核对记录会让包里的上一版照样过）
import hashlib, json, os, stat, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from progress import Ticker
import sha256_fast   # 文件 SHA：Windows 走 CNG（同 pack/pack.py）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pkg_inputs_key import content_keyed   # 哪些源按全内容进包键（同 pack.py）
NJ = int(os.environ.get('J') or os.environ.get('S2A_JOBS') or os.cpu_count() or 1)   # 并行路数（tools/cores.sh S2A_JOBS）
if len(sys.argv) < 3: sys.exit('用法：verify.py <包目录> <前缀>=<源目录> …')
P = sys.argv[1]
SRCS = [l for a in sys.argv[2:] for l in (open(a[1:], encoding='utf-8').read().splitlines() if a.startswith('@') else [a]) if l]   # @<文件>：源清单从文件读（同 pack.py）
def red(msg): print(f'🔴 资源包核对 {P}：{msg}'); sys.exit(1)
try: man = json.load(open(f'{P}/manifest.json'))
except (OSError, ValueError) as e: red(f'读不到 manifest.json（{e}）')
if man.get('version') != 2: red(f'manifest version 是 {man.get("version")}，不是 2')
raw = open(f'{P}/index.tsv', 'rb').read()
if hashlib.sha256(raw).hexdigest() != man.get('index_sha256'): red('index.tsv 的 SHA-256 与 manifest index_sha256 不符')
idx = [l.split('\t') for l in raw.decode().splitlines() if l]
if any(len(x) != 3 for x in idx): red('index.tsv 每行应为「路径<TAB>字节数<TAB>SHA-256」')
packed = {rel: (int(sz), sha) for rel, sz, sha in idx}
if len(packed) != len(idx): red('index.tsv 里有重复路径')
src = {}; full = set()   # full：按全内容进包键、每次逐字节比的
for a in SRCS:
    name, _, root = a.partition('=')
    if os.path.isfile(root):
        src[name] = root
        if content_keyed(name): full.add(name)
        continue
    for d, _, fs in os.walk(root):
        for f in fs:
            if f == '.DS_Store' or f.startswith('._'): continue
            p = os.path.join(d, f); rel = name + '/' + os.path.relpath(p, root).replace(os.sep, '/'); src[rel] = p   # 包内路径一律 /（Windows 上 relpath 出反斜杠）
            if content_keyed(name): full.add(rel)
miss = sorted(set(src) - set(packed)); extra = sorted(set(packed) - set(src))
if miss or extra: red(f'路径不一致：包里缺 {len(miss)} 个（如 {miss[:3]}），多 {len(extra)} 个（如 {extra[:3]}）')
VS = P.rstrip('/') + '.verify.tsv'; prev = {}
try:
    for l in open(VS, encoding='utf-8'): r = l.rstrip('\n').split('\t'); prev[r[0]] = tuple(r[1:])
except (OSError, ValueError): prev = {}
def sig(p, q, sha, a=None, b=None):   # a / b：调用方已取的 os.stat（Windows 上每次 stat 都要开文件，11-06 出包速度线：0100F2C0115B6000 30.5 万个文件核对 236 秒）
    a, b = a or os.stat(p), b or os.stat(q); return (str(a.st_size), str(a.st_mtime_ns), str(b.st_size), str(b.st_mtime_ns), sha)
bad = []; rec = {}; todo = []; UNSTABLE = set()
for rel, p in src.items():
    q = f'{P}/{rel}'; sz, sha = packed[rel]
    if rel not in full and rel in prev and os.path.isfile(q) and prev[rel] == sig(p, q, sha): rec[rel] = prev[rel]; continue   # 没有上次记录（冷）就不取 stat
    todo.append((rel, p, q, sz, sha))
skip = len(rec)
def check(t):   # 一个文件：字节数 → 逐字节比源 → SHA 对 index；返回（路径，错因或签名）
    rel, p, q, sz, sha = t
    try: sq, sp = os.stat(q), os.stat(p)   # 源 / 包各取一次 stat，字节数、同一文件、签名都用它（原先 isfile + getsize×2 + samefile×2 + 签名×2 共 7 次）
    except OSError: return rel, f'{rel}（字节数）'
    if not stat.S_ISREG(sq.st_mode) or sq.st_size != sz or sp.st_size != sz: return rel, f'{rel}（字节数）'
    # 只读包里那份（11-06 维护者「少读一遍文件效果好代价低」）：index 的 SHA 是 pack.py 读源算的（克隆 / 硬链接时另读源，整份拷贝时边拷边算），
    #   这里读包里那份算 SHA 对 index——两次读走不同路径（源 / 包），SHA 相同即包里那份与源逐字节相同，仍是独立闸门；连同上面源 / 包字节数都核。
    #   一个文件从三遍读（pack.py 一遍 + 这里源、包各一遍）降到两遍。按全内容进包键的（full：系统数据、RomFS 索引等，合计几十 MB）照旧逐字节比源：
    #   它们的源可能只换内容、保住大小与修改时间，pack.py 按签名判没变就不重算 SHA，只核 SHA 会放过
    h = sha256_fast.new()
    if rel not in full or os.path.samestat(sp, sq):
        with open(q, 'rb') as f:
            for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    else:
        with open(p, 'rb') as fp, open(q, 'rb') as fq:
            while True:
                a, b = fp.read(1 << 22), fq.read(1 << 22)
                if a != b: return rel, f'{rel}（内容与源不同）'
                if not b: break
                h.update(b)
    if h.hexdigest() != sha:
        # 再读一遍（只在不符时，正常核对不多读）：两次读出的不一样 = 这台电脑读盘不稳定（盘 / 内存 / 有程序在改这个文件）；
        #   一样 = index 记的值不对（pack.py 那次读到的内容和现在不同），重打时重算就好
        h2 = sha256_fast.new()
        with open(q, 'rb') as f:
            for b in iter(lambda: f.read(1 << 22), b''): h2.update(b)
        UNSTABLE.update([rel] if h2.hexdigest() != h.hexdigest() else [])
        return rel, f'{rel}（SHA 与 index 不符）'
    return rel, sig(p, q, sha, sp, sq)
# 逐文件互不依赖：按本机核数并行（S2A_JOBS，tools/cores.sh；10-25 维护者「要适配机器的核心数」——原先串行，01006F8002326000 11 万个文件核对 33 秒只用 0.47 核）；
#   读文件、算哈希期间释放 GIL，线程即可。进度写 S2A_PROGRESS（tools/progress.py）
tk = Ticker('资源包核对', len(todo))
def block(b):
    return [check(t) for t in b]
with ThreadPoolExecutor(max_workers=NJ) as ex:
    for part in ex.map(block, [todo[i:i + 64] for i in range(0, len(todo), 64)]):
        for rel, r in part:
            if isinstance(r, str): bad.append(r)
            else: rec[rel] = r
        tk.step(len(part))
if bad:
    # SHA 与 index 不符的：从资源包状态表（pack.py 的 <包目录>.state.tsv）去掉这几行，重打时重读重算——原先状态表照留，源没变时 pack.py
    #   沿用记下的错 SHA，玩家重试多少次都在这里红（11-13 玩家 Windows 4 核 8 GB：ipa 收尾 4130 秒后一批 romfs 文件 SHA 与 index 不符）
    sha_bad = {b.rsplit('（', 1)[0] for b in bad if b.endswith('（SHA 与 index 不符）')}
    ST = P.rstrip('/') + '.state.tsv'
    if sha_bad and os.path.isfile(ST):
        with open(ST, encoding='utf-8') as f: rows = [l for l in f if l.split('\t', 1)[0] not in sha_bad]
        with open(ST + '.tmp', 'w', encoding='utf-8', newline='\n') as f: f.writelines(rows)
        os.replace(ST + '.tmp', ST)
    why = ''
    if sha_bad:
        why = (f'；其中 {len(UNSTABLE)} 个同一文件两次读出的内容不同（读盘不稳定）' if UNSTABLE else '') + f'；已让这 {len(sha_bad)} 个文件下次出包重读重算'
    red(f'{len(bad)} 个文件不对：{sorted(bad)[:5]}{why}')
# 包目录这边也要跳过 macOS 自己留的垃圾（.DS_Store / ._*）：pack.py 复制时已经跳过它们，
# 但 Finder / Spotlight 会在 pkg/pack 里重新生成，不过滤就会把「清单外文件」误报成出包失败。
stray = [os.path.relpath(os.path.join(d, f), P).replace(os.sep, '/') for d, _, fs in os.walk(P) for f in fs
         if f != '.DS_Store' and not f.startswith('._')]
stray = [s for s in stray if s not in packed and s not in ('manifest.json', 'index.tsv')]
if stray: red(f'包目录里有清单外的文件 {len(stray)} 个：{stray[:5]}')
with open(VS + '.tmp', 'w', encoding='utf-8', newline='\n') as f: f.writelines('\t'.join((rel,) + v) + '\n' for rel, v in rec.items())
os.replace(VS + '.tmp', VS)
print(f'🟢 资源包核对：{len(packed)} 个文件与源一致、SHA 对得上、无多余文件（核 {len(packed) - skip} 个，{skip} 个与上次核对时源 / 包都没变）（{P}）')
