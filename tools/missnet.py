#!/usr/bin/env python3
# 没有链接版大网时首遇会漏几条基础管线（离线、不起局）：
#   python3 tools/missnet.py <款> [额外 host.log 或局目录…]
# 来源：调度作业里该款全部局（$S2A_SCHED_DIR/jobs/<款>_*/out_*/host.log，正式 / 实验都收）+ 收集表 $S2A_SHCOLLECT/<款>/spec_pipes.tsv + 额外给的日志。
# 只看 b2 行（颜色留空的基础管线；渲染器只在运行时真要现建 / 特化时记，见 graphics/metal/gal_core.m gal_pso_note_desc）。
# 出包静态枚举每个程序只出一条基础管线：函数名不带后缀、拓扑未指定（0）、采样数 1、a2c / a2one 关、光栅化开（pso_gen.py 文件头）。
# 收集到的 b2 行按它偏离这条的维度归类；全是缺省值的 = 运行时才出现的顶点 / 片元配对。每条按 S2A_MISS_MS（缺省 100 ms，怪猎错架构包 43 条 4315 ms）计首遇卡顿。
import collections, glob, os, re, struct, sys

G = sys.argv[1]
SD = os.environ.get('S2A_SCHED_DIR', os.path.expanduser('~/.s2arm/run/s2arm/sched'))
COL = os.environ.get('S2A_SHCOLLECT', os.path.expanduser('~/.s2arm/run/s2arm/shcollect'))
MS = float(os.environ.get('S2A_MISS_MS', '100'))
ROW = re.compile(rb'b2 (s[0-9a-f]{16}(?:_\w+)?) (s[0-9a-f]{16}(?:_\w+)?|-) (\d+) (\d+) (-?\d+) (-?\d+) ([01])\b')
logs = glob.glob(os.path.join(SD, 'jobs', G + '_*', 'out_*', 'host.log'))
for a in sys.argv[2:]:
    logs += [a] if os.path.isfile(a) else glob.glob(os.path.join(a, '**', 'host.log'), recursive=True)
rows = set(); nopack = 0
for lg in logs:
    try: b = open(lg, 'rb').read()
    except OSError: continue
    # 没带着色器包的局（「无着色器包」：首遇全部现编）记的 b2 是这局用到的全部基础管线，不是包的漏网：整份不计
    if '无着色器包'.encode() in b: nopack += 1; continue
    rows |= {tuple(x.decode() for x in m) for m in ROW.findall(b.replace('特化管线 '.encode(), b'\n'))}
tsv = os.path.join(COL, G, 'spec_pipes.tsv')
if os.path.exists(tsv):
    rows |= {tuple(x.decode() for x in m) for m in ROW.findall(open(tsv, 'rb').read())}
# 现行包归档索引（pso_gen.py 写的 gal_pso.idx：键 = FNV-1a 64(函数名逗号相连)，与运行时查归档同口径）：
#   「运行时配对」行的配对已在索引里、又不是收集表的 b2 行补进去的 = 现在的静态程序表已覆盖（旧局记的，那时程序表还没收全），不算漏网
def fnv64(t):
    x = 0xcbf29ce484222325
    for c in t.encode(): x = ((x ^ c) * 0x100000001b3) & 0xffffffffffffffff
    return x
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'pack', 'orch'))
import current   # noqa: E402  现行指针文件（pack/orch/current.py，只依赖标准库）
RT = os.environ.get('S2A_ROOTS', os.path.expanduser('~/.s2arm/run/s2arm/roots'))
root = os.environ.get('S2A_MISS_ROOT') or str(current.read(RT, G) or os.path.join(RT, G + '@现行'))   # 没有现行：下面的索引都读不到（同原先断链）
ip = os.path.join(root, 'shaders', 'gal_pso.idx'); idx = None
if os.path.exists(ip):
    b = open(ip, 'rb').read(); n = struct.unpack_from('<I', b, 8)[0]; idx = {struct.unpack_from('<Q', b, 16 + 16 * i)[0] for i in range(n)}
# 现行包离线索引 gal.idx 里的函数键：行里的函数在现行包里不存在 = 与现行包不同口径的局记的（翻译器换代、宽屏改写开关不同…），和现行包无关，不算
fp = os.path.join(root, 'shaders', 'gal.idx'); funcs = None
if os.path.exists(fp):
    b = open(fp, 'rb').read(); n = struct.unpack_from('<I', b, 16)[0]; funcs = {f'{struct.unpack_from("<Q", b, 24 + 16 * i)[0]:016x}' for i in range(n)}
spec = set()
if os.path.exists(tsv): spec = {tuple(x.decode() for x in m) for m in ROW.findall(open(tsv, 'rb').read())}
dims = collections.Counter(); covered = stale = 0
for v, f, topo, smp, a2c, a2one, ras in sorted(rows):
    if funcs is not None and any(n != '-' and n[1:17] not in funcs for n in (v, f)): stale += 1; continue
    d = []
    for n in (v, f):
        if '_' in n: d.append(n[n.index('_'):])
    if topo != '0': d.append(f'拓扑{topo}')
    if smp != '1': d.append(f'采样{smp}')
    if a2c != '0': d.append('a2c')
    if a2one != '0': d.append('a2one')
    if ras != '1': d.append('不光栅化')
    if not d and idx is not None and (v, f, topo, smp, a2c, a2one, ras) not in spec and fnv64(v if f == '-' else f'{v},{f}') in idx:
        covered += 1; continue
    dims['+'.join(d) or '运行时配对'] += 1
desc = '，'.join(f'{k}×{n}' for k, n in dims.most_common()) or '—'
miss = sum(dims.values())
print(f'{G}\t局日志 {len(logs)}{f"（无着色器包、不计 {nopack}）" if nopack else ""}\t收到 b2 {len(rows)}（函数键不在现行包里 {stale}、现静态已覆盖 {covered}{"" if idx is not None else "，没有现行包归档索引、没扣"}）\t漏网 {miss}\t{desc}\t预计首遇卡顿 {miss * MS:.0f} ms')
