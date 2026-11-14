#!/usr/bin/env python3
# merge_extract.py 单测：期望键在本文件里按直连口径直接用 hashlib 算（不调被测实现）。
# 夹具：直连抽取侧 2 个着色器（各自一条记录 + 表行），S2Arm 侧 3 个（1 个与直连抽取相同、2 个独有：控制段 0x848 的顶点、控制段 0x88c 的计算）。
import atexit, hashlib, json, os, shutil, struct, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "shbake")); import srcpack   # S2Arm 抽取的着色器字节存放（src/*.pk）

HERE = os.path.dirname(os.path.abspath(__file__)); TOOL = os.path.join(HERE, '..', 'merge_extract.py')
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

def ctl_of(n, fill, code_len):
    c = bytearray([fill]) * n; struct.pack_into('<I', c, 0, 0x98761234); struct.pack_into('<I', c, 0x20, n); struct.pack_into('<I', c, 0x704, code_len)
    return bytes(c)
def code_of(fill, n=0x200): return bytes([fill]) * n
def rec(code, ctl):
    r = bytearray(b'BTCDBTCD' + bytes(0x30)); struct.pack_into('<2I', r, 0x28, len(ctl), len(code)); return bytes(r) + code + ctl

def cs_ctl(n, fill, code_len, tg, shared):   # 计算着色器控制段：+0x748 起 3 个 u32 线程组、+0x754 共享字节数
    c = bytearray(ctl_of(n, fill, code_len)); struct.pack_into('<4I', c, 0x748, *tg, shared); return bytes(c)

def run(case, tamper=False, tg=(8, 4, 1), missing=False):
    t = tempfile.mkdtemp(prefix='t_merge_'); atexit.register(shutil.rmtree, t, True)
    nxp = os.path.join(t, 'nxpkg'); s2 = os.path.join(t, 's2'); os.makedirs(nxp); os.makedirs(os.path.join(s2, 'src'))
    # 直连抽取：A（顶点，0x880）、B（像素，0x880）
    cA, kA_ctl = code_of(1), ctl_of(0x880, 0x11, 0x200); cB, kB_ctl = code_of(2), ctl_of(0x880, 0x22, 0x200)
    kA = hashlib.sha256(kA_ctl + cA).hexdigest()[:16]; kB = hashlib.sha256(kB_ctl + cB).hexdigest()[:16]
    open(os.path.join(nxp, 'vs_t.bin'), 'wb').write(rec(cA, kA_ctl)); open(os.path.join(nxp, 'ps_t.bin'), 'wb').write(rec(cB, kB_ctl))
    mp = os.path.join(t, 'map.tsv')
    open(mp, 'w').write('# 测试表\npackage\tindex\tstage\tdm_ctl_sha16\tsource\n'
                        f'vs_t.bin\t0\tvertex\t{"0" * 16 if tamper else kA}\tx#a\nps_t.bin\t0\tpixel\t{kB}\tx#b\n')
    # S2Arm：A 同一份；C 顶点控制段 0x848（取自报长度 0x848）；D 计算控制段 0x88c（直连口径截到 0x880，S2Arm 原键按整段 0x88c）
    cC, ctlC = code_of(3), ctl_of(0x848, 0x33, 0x200); cD, ctlD = code_of(4), cs_ctl(0x88c, 0x44, 0x200, tg, 100)
    kC = hashlib.sha256(ctlC + cC).hexdigest()[:16]
    kD = hashlib.sha256(ctlD[:0x880] + cD).hexdigest()[:16]; kD_s2 = hashlib.sha256(ctlD + cD).hexdigest()[:16]
    idx = ['# 键\t阶段\t首个来源\t变体号']; sw = srcpack.Writer(s2)   # S2Arm 抽取的着色器字节写成 src/*.pk（同生产写端）
    for k, st, c, l in ((kA, 'vs', cA, kA_ctl), (kC, 'vs', cC, ctlC), (kD_s2, 'cs', cD, ctlD)):
        sw.put(k, c, l); idx.append(f'{k}\t{st}\tsrc/{k}\t0')
    sw.flush()
    if missing: idx.append('000084a91b9e57a2\tvs\tsrc/000084a91b9e57a2\t0')   # #1009：表里有、字节没写进 .pk
    open(os.path.join(s2, 'index.tsv'), 'w').write('\n'.join(idx) + '\n')
    # 配置档答案表（与 map.tsv 同目录）：B 一行（原样照抄）、D 一行只有 tex（补线程组后 tex 保留）
    open(os.path.join(t, 'shader_facts.tsv'), 'w').write(f'# 测试答案表\n{kB}\t{{"x":1}}\n{kD}\t{{"tex":{{"0":"float"}}}}\n')
    out = os.path.join(t, 'out')
    p = subprocess.run([sys.executable, TOOL, s2, nxp, mp, out], capture_output=True, text=True)
    return p, out, dict(kA=kA, kB=kB, kC=kC, kD=kD, kD_s2=kD_s2, cC=cC, ctlC=ctlC, cD=cD, ctlD=ctlD, cA=cA)

print('· 正常合并')
p, out, k = run('ok')
check(p.returncode == 0, f'退出码 0（实得 {p.returncode}；{p.stdout.strip()[-120:]}）')
st = json.load(open(os.path.join(out, 'merge.json')))
check((st['direct'], st['s2arm'], st['交集'], st['s2arm独有'], st['direct独有'], st['并集']) == (2, 3, 1, 2, 1, 4), f'计数 nx2 / s2 3 / 交 1 / s2 独有 2 / nx 独有 1 / 并 4（实得 {st}）')
check(k['kD'] != k['kD_s2'], '夹具自检：控制段 0x88c 时两种口径的键确实不同（否则这条用例测不出口径）')
rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(out, 'shader_map.tsv')) if not l.startswith(('#', 'package'))]
added = {r[3]: r for r in rows if r[4].startswith('s2a:')}
check(set(added) == {k['kC'], k['kD']}, f'新增行键 = 按直连口径重算的 C、D（实得 {sorted(added)}）')
check(k['kA'] not in added and sum(r[3] == k['kA'] for r in rows) == 1, '交集键 A 不重复加行')
check(added.get(k['kD'], [''] * 5)[0] == 'cs_s2a.bin' and added[k['kD']][2] == 'compute' and added[k['kC']][0] == 'vs_s2a.bin' and added[k['kC']][2] == 'vertex', '阶段 → 包名与阶段词（cs_s2a.bin / compute，vs_s2a.bin / vertex）')
check(added.get(k['kD'], [''] * 5)[4].startswith('s2a:' + k['kD_s2']), '来源列带 S2Arm 原键')
# 记录能被直连离线链的切法读回原字节
d = open(os.path.join(out, 'pkg', 'cs_s2a.bin'), 'rb').read(); r = d[d.find(b'BTCDBTCD'):]
nctl, ncode = struct.unpack_from('<2I', r, 0x28)
check(r[0x38:0x38 + ncode] == k['cD'] and r[0x38 + ncode:0x38 + ncode + nctl] == k['ctlD'], '包记录读回 = 原机器码 + 原控制段')
check(os.path.exists(os.path.join(out, 'pkg', 'vs_t.bin')) and open(os.path.join(out, 'pkg', 'vs_t.bin'), 'rb').read() == rec(k['cA'], ctl_of(0x880, 0x11, 0x200)), '直连抽取原包文件原样带进输出包目录')
check(not os.path.exists(os.path.join(out, 'code_key.tsv')), '不出 code_key.tsv（整段机器码哈希对不上运行时客体代码；seen 用的表改由烘焙出 guest_keys.tsv）')
check(open(os.path.join(out, 'union_keys.tsv')).read().split() == sorted([k['kA'], k['kB'], k['kC'], k['kD']]), 'union_keys 为 4 个键升序')
# 反向：直连抽取独有的 B 按 S2Arm 口径（整段控制段 0x880）补进 s2a_src；键对照表含 4 行
kB_s2 = hashlib.sha256(ctl_of(0x880, 0x22, 0x200) + code_of(2)).hexdigest()[:16]
sb = srcpack.Src(os.path.join(out, 's2a_src'))
check(kB_s2 in sb and sb.get(kB_s2) == (code_of(2), ctl_of(0x880, 0x22, 0x200)), '直连抽取独有 B 按 S2Arm 格式补进 s2a_src/src/*.pk')
ix = [l.split('\t') for l in open(os.path.join(out, 's2a_src', 'index.tsv')) if not l.startswith('#')]
check(len(ix) == 1 and ix[0][0] == kB_s2 and ix[0][1] == 'ps', f's2a_src/index.tsv 一行、阶段 ps（实得 {ix}）')
km = dict(l.split() for l in open(os.path.join(out, 'key_map.tsv')) if not l.startswith('#'))
check(km == {k['kA']: k['kA'], kB_s2: k['kB'], k['kC']: k['kC'], k['kD_s2']: k['kD']}, f'key_map：S2Arm 键 → 直连键 4 行，D 的两种口径对上（实得 {km}）')
# 答案表：期望按夹具手写（D 线程组 8×4×1、共享 100 字节 → 按 16 对齐 112；配置档的 tex 保留；B 原样）
ft = open(os.path.join(out, 'shader_facts.tsv')).read().splitlines()
check(ft[0] == '# 测试答案表', f'答案表表头照抄（实得 {ft[:1]}）')
fd = dict(l.split('\t', 1) for l in ft[1:])
check(fd.get(k['kD']) == '{"local":[8,4,1],"shared":112,"tex":{"0":"float"}}', f'S2Arm 独有计算着色器 D 按控制段补 local [8,4,1] / shared 112，配置档 tex 保留（实得 {fd.get(k["kD"])}）')
check(fd.get(k['kB']) == '{"x":1}' and len(fd) == 2, f'非计算着色器 B 原样、不多不少 2 行（实得 {fd}）')
print('· 计算着色器控制段线程组为 0（10-25 异度3：这一代线程组不在控制段）')
p, out, k = run('tg0', tg=(0, 1, 1))
fd0 = dict(l.split('\t', 1) for l in open(os.path.join(out, 'shader_facts.tsv')).read().splitlines()[1:])
check(p.returncode == 0 and '1 个控制段读不出线程组' in p.stdout, f'不挡出库：退出 0、读数写明 1 个读不出（实得 {p.returncode}；{p.stdout.strip()[-120:]}）')
check(fd0.get(k['kD']) == '{"tex":{"0":"float"}}', f'读不出的不补 local / shared，配置档原有字段照留（实得 {fd0.get(k["kD"])}）')
check(json.load(open(os.path.join(out, 'merge.json')))['控制段读不出线程组'] == [k['kD']], 'merge.json 列出读不出的键')
print('· 直连抽取表里的键与记录重算不符')
p, out, k = run('bad', tamper=True)
check(p.returncode != 0 and '【红】' in p.stdout, f'报红、退出码非 0（实得 {p.returncode}）')
print('· 表里有、.pk 里没有字节的键（#1009）')
p, out, k = run('missing', missing=True)
check(p.returncode == 0, f'不整次失败：退出码 0（实得 {p.returncode}；{p.stdout.strip()[-160:]}）')
check(sum('【黄】' in l and '000084a91b9e57a2' in l for l in p.stdout.splitlines()) == 1, '记一行【黄】点名这支键')
st = json.load(open(os.path.join(out, 'merge.json')))
check((st['direct'], st['s2arm'], st['交集'], st['s2arm独有'], st['并集']) == (2, 3, 1, 2, 4), f'其余计数与正常合并相同（实得 {st}）')
print(f'{"失败" if fails else "通过"}：{23 - len(fails)} / 23 项')
sys.exit(1 if fails else 0)
