#!/usr/bin/env python3
"""单一 IMG v1（pack/img.py + services/romfs_index --std）单测：python3 tests/img_test.py。期望值来自夹具本身，不跑被测实现推：
  ① 头：魔数 / 格式号 1 / 游戏号大写 / 资源包号 / 文件长 = 实际长度
  ② 其余文件：按路径 O(1) 查得到、起点页对齐、字节与源文件相同；查不在的路径 → None；路径重复 → 报红
  ③ RomFS 段：按 Switch 标准 RomFS 公开格式独立解析（本文件 std_romfs，不用 LibHac）——文件集合与夹具目录相同、逐文件字节相同
  ④ write：游戏号取产物根 unpack.tsv；资源包号 = 清单里除着色器库 / 覆盖层以外各行的 SHA-256（测试里按定义独立算）；exefs / ctl / aoc 进其余文件段，
     romfs*、覆盖层、直连库、清单不进；RomFS 段来自产物根完整 romfs/（含被覆盖层替换的原文件）；有 programs/ → 报红；is_img 认魔数
  ⑤ convert（出包交付）：资源包目录只剩 game.img + 着色器库 / 覆盖层 + 新清单；index.tsv 首行 game.img<TAB>文件长<TAB>资源包号、其余是原着色器库 / 覆盖层行；
     manifest v3（format img、imgFile、index_sha256 = 新 index.tsv 的 SHA-256）；着色器库那行变了资源包号不变；多程序合集 → None、目录不动
  ⑦ 写 IMG 报字节进度（S2A_PROGRESS）：末行已写 = 总数 = 夹具 RomFS 文件 + 其余原始资源字节和
  ⑥ 原件 + 预建偏移表（11-11 真机对比：产物根 romfs 是界面覆盖后版本、有覆盖层时起局重建目录表 138.6 ms）：RomFS 段 = 产物根 romfs，覆盖清单里的文件换回 seed.txt 数据目录的原版
     （数据目录里别的文件变过也不取它）；
     game.imgmap 按 romfs.s2aidx 顺序，被覆盖的记 -1、其余从 game.img 读回的字节等于文件本身；index.tsv 登记 romfs.s2aidx 与 game.imgmap；残留的 romfs.files/ 删掉；
     没有 seed.txt 但产物根叠过覆盖 → 报红
     （要 dotnet 编 services/romfs_index；没有 dotnet 时 ③ 跳过并打印原因，①② 照测）"""
import hashlib, json, os, shlex, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'pack'))
import img

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def std_romfs(path, base):
    """按公开格式读标准 RomFS → {相对路径: 字节}"""
    f = open(path, 'rb')
    def rd(off, n): f.seek(base + off); return f.read(n)
    hs, dho, dhs, dmo, dms, fho, fhs, fmo, fms, data = struct.unpack('<10Q', rd(0, 0x50))
    dmeta, fmeta, out = rd(dmo, dms), rd(fmo, fms), {}
    def walk(off, path):
        _, _, child, first, _, nl = struct.unpack_from('<6I', dmeta, off)
        name = dmeta[off + 24: off + 24 + nl].decode(); p = path + ('/' + name if name else '')
        fo = first
        while fo != 0xFFFFFFFF:
            _, sib, foff, size, _, fnl = struct.unpack_from('<IIQQII', fmeta, fo)
            out[(p + '/' + fmeta[fo + 32: fo + 32 + fnl].decode()).lstrip('/')] = rd(data + foff, size); fo = sib
        c = child
        while c != 0xFFFFFFFF: walk(c, p); c = struct.unpack_from('<6I', dmeta, c)[1]
    walk(0, ''); return out


def romfs_index_cmd(t):
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


with tempfile.TemporaryDirectory(prefix='img test ') as t:
    T = Path(t); (T / 'romfs/a/b c').mkdir(parents=True); (T / 'o').mkdir()
    files = {'a/b c/big.bin': os.urandom(100000), 'a/小.txt': b'hi', 'empty': b''}
    for k, v in files.items(): (T / 'romfs' / k).write_bytes(v)
    others = {'exefs/main.npdm': os.urandom(5000), 'ctl/control.nacp': b'NACP'}
    src = []
    for k, v in others.items(): p = T / 'o' / k.replace('/', '_'); p.write_bytes(v); src.append((k, str(p)))
    cmd, why = romfs_index_cmd(t)
    out = str(T / 'g.img')
    img.build(str(T / 'romfs') if cmd else None, src, out, '0100abcd00000000', 'abc123', cmd, say=lambda *_: None)
    h = img.header(out)
    ck((h['format'], h['gid'], h['pack_id'], h['total']) == (1, '0100ABCD00000000', 'abc123', os.path.getsize(out)), f'① 头 {h}')
    for k, v in others.items():
        off, size = img.find(out, k); b = open(out, 'rb'); b.seek(off)
        ck(off % img.PAGE == 0 and b.read(size) == v, f'② {k} 页对齐、字节相同（偏移 {off}）')
    ck(img.find(out, 'nope') is None, '② 查不在的路径 → None')
    try: img.toc_bytes([('x', 0, 1), ('x', 1, 1)]); ck(False, '② 路径重复应报红')
    except img.Red: ck(True, '② 路径重复报红')
    if cmd:
        got = std_romfs(out, h['romfs'][0])
        ck(got == files, f'③ 标准 RomFS 段：独立解析 {len(got)} 个文件，集合与字节同夹具')
    else:
        print(f'跳过 ③：{why}')
    if cmd:
        root, pk = T / 'root', T / 'pack'
        (root / 'romfs/ui').mkdir(parents=True); (root / 'romfs/ui/layout.bin').write_bytes(b'ORIG'); (root / 'romfs/data.bin').write_bytes(b'DATA')
        (root / 'unpack.tsv').write_text('title_id\t0100ABCD00000001\n')
        rows = {'exefs/main.npdm': b'NPDM', 'ctl/control.nacp': b'NACP', 'aoc/1/x.bin': b'AOC', 'romfs_overlay/ui/layout.bin': b'OVER',
                'shaders/direct/keys.tsv': b'k', 'romfs.files/data.bin': b'DATA', 'romfs.imgmap': b'm'}
        for k, v in rows.items(): (pk / k).parent.mkdir(parents=True, exist_ok=True); (pk / k).write_bytes(v)
        (pk / 'index.tsv').write_text(''.join(f'{k}\t{len(v)}\tx\n' for k, v in rows.items()))
        (pk / 'manifest.json').write_text('{"version": 2, "index_sha256": "feedbeef"}')
        want_id = hashlib.sha256(''.join(f'{k}\t{len(v)}\tx\n' for k, v in rows.items() if not k.startswith(('shaders/', 'romfs_overlay/'))).encode()).hexdigest()
        pf = T / 'progress.tsv'; os.environ['S2A_PROGRESS'] = str(pf)   # ⑦ 字节进度：末行 = 写单一 IMG、已写 = 总数 = RomFS 两个文件 8 字节 + 其余三个原始资源的字节
        w = str(T / 'w.img'); img.write(str(root), str(pk), w, romfs_index=cmd)
        del os.environ['S2A_PROGRESS']
        want7 = 8 + sum(len(rows[k]) for k in ('aoc/1/x.bin', 'ctl/control.nacp', 'exefs/main.npdm'))
        last7 = pf.read_text(encoding='utf-8').splitlines()[-1].split('\t')[1:] if pf.is_file() else []
        ck(last7 == ['写单一 IMG', str(want7), str(want7)], f'⑦ 进度末行（阶段 / 已写 / 总数）：期望 写单一 IMG / {want7} / {want7} → {last7}')
        hw = img.header(w); names = [e[0] for e in img.entries(w)]
        ck((hw['gid'], hw['pack_id'], img.is_img(w), img.is_img(str(pk / 'index.tsv'))) == ('0100ABCD00000001', want_id, True, False), f'④ 头 {hw["gid"]} / {hw["pack_id"]}、is_img')
        ck(names == ['aoc/1/x.bin', 'ctl/control.nacp', 'exefs/main.npdm', 'romfs.list'], f'④ 其余文件段只收原始资源：{names}')
        ck(std_romfs(w, hw['romfs'][0]) == {'ui/layout.bin': b'ORIG', 'data.bin': b'DATA'}, '④ RomFS 段来自产物根完整 romfs/（含被覆盖层替换的原文件 ORIG）')
        ix0 = (pk / 'index.tsv').read_text()
        (pk / 'index.tsv').write_text(ix0.replace('shaders/direct/keys.tsv\t1\tx', 'shaders/direct/keys.tsv\t1\ty'))
        ck(img.image_id(str(pk)) == want_id, '⑤ 着色器库那行变了，资源包号不变')
        (pk / 'index.tsv').write_text(ix0)
        cv = T / 'cv'; shutil.copytree(pk, cv)
        g = img.convert(str(root), str(cv), romfs_index=cmd)
        left = sorted(str(p.relative_to(cv)) for p in cv.rglob('*') if p.is_file())
        ck(left == ['game.img', 'index.tsv', 'manifest.json', 'romfs_overlay/ui/layout.bin', 'shaders/direct/keys.tsv'], f'⑤ 资源包只剩 IMG + 着色器库 / 覆盖层 + 清单：{left}')
        ix = (cv / 'index.tsv').read_text(); m = json.loads((cv / 'manifest.json').read_text())
        ck(ix == f'game.img\t{os.path.getsize(g)}\t{want_id}\nromfs_overlay/ui/layout.bin\t4\tx\nshaders/direct/keys.tsv\t1\tx\n', f'⑤ 新 index.tsv：{ix!r}')
        ck((m['version'], m['format'], m['imgFile'], m['index_sha256']) == (3, 'img', 'game.img', hashlib.sha256(ix.encode()).hexdigest()), f'⑤ manifest v3：{m}')
        ck(std_romfs(g, img.header(g)['romfs'][0]) == {'ui/layout.bin': b'ORIG', 'data.bin': b'DATA'} and img.find(g, 'exefs/main.npdm') is not None, '⑤ game.img 内容同 write')
        # ⑥ 原件 + 预建偏移表
        orig = T / 'orig'; (orig / 'romfs/ui').mkdir(parents=True); (orig / 'romfs/ui/layout.bin').write_bytes(b'ORIGINAL'); (orig / 'romfs/data.bin').write_bytes(b'STALE')   # 数据目录播种后变过（非覆盖文件）：应取产物根那份
        r6 = T / 'root6'; (r6 / 'romfs/ui').mkdir(parents=True); (r6 / 'romfs/ui/layout.bin').write_bytes(b'OVER'); (r6 / 'romfs/data.bin').write_bytes(b'DATA')
        (r6 / 'seed.txt').write_text(f'src={orig}\ntag=t\n'); (r6 / 'ui_overlay.tsv').write_text('ui/layout.bin\n'); (r6 / 'unpack.tsv').write_text('title_id\t0100ABCD00000006\n')
        r = subprocess.run([*shlex.split(cmd), str(r6)], capture_output=True, text=True); ck(r.returncode == 0, f'⑥ 造预建索引（romfs_index）rc={r.returncode} {r.stderr[-200:]}')
        p6 = T / 'pack6'; (p6 / 'exefs').mkdir(parents=True); (p6 / 'romfs_overlay/ui').mkdir(parents=True); (p6 / 'romfs.files').mkdir()
        (p6 / 'exefs/main.npdm').write_bytes(b'NPDM'); (p6 / 'romfs_overlay/ui/layout.bin').write_bytes(b'OVER'); (p6 / 'romfs.files/data.bin').write_bytes(b'DATA')
        shutil.copyfile(r6 / 'romfs.s2aidx', p6 / 'romfs.s2aidx')
        r6rows = {'exefs/main.npdm': b'NPDM', 'romfs_overlay/ui/layout.bin': b'OVER', 'romfs.s2aidx': (p6 / 'romfs.s2aidx').read_bytes()}
        (p6 / 'index.tsv').write_text(''.join(f'{k}\t{len(v)}\t{hashlib.sha256(v).hexdigest()}\n' for k, v in r6rows.items()))
        (p6 / 'manifest.json').write_text('{"version": 2}')
        g6 = img.convert(str(r6), str(p6), romfs_index=cmd)
        ck(std_romfs(g6, img.header(g6)['romfs'][0]) == {'ui/layout.bin': b'ORIGINAL', 'data.bin': b'DATA'}, '⑥ RomFS 段是原件（被覆盖的 ui/layout.bin 是原版字节）')
        sys.path.insert(0, str(R / 'pack')); import romfs_image
        _, idx6 = romfs_image.parse_index(str(p6 / 'romfs.s2aidx'))
        mb = (p6 / 'game.imgmap').read_bytes(); n6 = struct.unpack_from('<i', mb, 16)[0]; offs = struct.unpack_from(f'<{n6}q', mb, 20)
        def at(o, n): f = open(g6, 'rb'); f.seek(o); return f.read(n)
        got6 = {rel: (-1 if o < 0 else at(o, n)) for (_, n, rel), o in zip(idx6, offs)}
        ck(mb[:8] == b'S2ARIM01' and struct.unpack_from('<q', mb, 8)[0] == os.path.getsize(g6) and got6 == {'ui/layout.bin': -1, 'data.bin': b'DATA'},
           f'⑥ game.imgmap：镜像长 = game.img、被覆盖的 -1、其余读回原字节 {got6}')
        ix6 = (p6 / 'index.tsv').read_text()
        ck('romfs.s2aidx\t' in ix6 and 'game.imgmap\t' in ix6 and not (p6 / 'romfs.files').exists(), '⑥ index.tsv 登记 romfs.s2aidx / game.imgmap，romfs.files/ 已删')
        (r6 / 'seed.txt').unlink()
        try: img.orig_romfs(str(r6), str(T)); ck(False, '⑥ 没有 seed.txt 但叠过覆盖应报红')
        except img.Red: ck(True, '⑥ 没有 seed.txt 但产物根叠过覆盖 → 报红')
        (pk / 'programs/1').mkdir(parents=True); (pk / 'programs/1/a').write_bytes(b'p')
        (pk / 'index.tsv').write_text((pk / 'index.tsv').read_text() + 'programs/1/a\t1\tx\n')
        try: img.write(str(root), str(pk), w, romfs_index=cmd); ck(False, '④ 多程序合集应报红')
        except img.Red: ck(True, '④ 有 programs/ → 报红（这一版不出 IMG）')
        before = sorted(p.name for p in pk.rglob('*'))
        ck(img.convert(str(root), str(pk), romfs_index=cmd) is None and sorted(p.name for p in pk.rglob('*')) == before, '⑤ 多程序合集 → None、目录不动')
# ⑧ #711（Windows 大游戏写 game.img 失败）：Windows 的 os.stat 没有 st_blocks，RomFS 段写满 1 秒时进度轮询原先抛 AttributeError、img.py 半路退出、
#   留下还在写的 romfs_index 进程。用不依赖 dotnet 的假 romfs_index（睡 2.5 秒再写段、打长度）+ 没有 st_blocks 的 stat 模拟：期望照常写成、RomFS 长度等于假工具报的；
#   等的时候本进程出错 → 假工具进程被收掉（不留在后台）
import types, time
T = Path(tempfile.mkdtemp(prefix='img test 8 '))
fake = T / 'fake_romfs_index.py'
fake.write_text("import sys,time\nromfs,_,part,off=sys.argv[2],sys.argv[3],sys.argv[4],int(sys.argv[5])\n"
                "open(sys.argv[0]+'.pid','w').write(str(__import__('os').getpid()))\ntime.sleep(2.5)\n"
                "f=open(part,'r+b'); f.seek(off); f.write(b'R'*4096); f.close(); print(4096)\n", encoding='utf-8')
fcmd = f'{shlex.quote(sys.executable)} {shlex.quote(str(fake))}'
class NoBlocks:   # 只给 img 模块看的 os：stat 结果去掉 st_blocks（同 Windows），其余转给真 os
    def __getattr__(self, k): return getattr(os, k)
    def stat(self, p, *a, **kw):
        st = os.stat(p, *a, **kw); return types.SimpleNamespace(st_size=st.st_size, st_mode=st.st_mode, st_mtime=st.st_mtime)
rd = T / 'r8'; (rd / 'a').mkdir(parents=True); (rd / 'a' / 'x.bin').write_bytes(b'x' * 100)
real_os = img.os; img.os = NoBlocks()
try:
    out8 = str(T / 'w8.img')
    try:
        img.build(str(rd), [], out8, '0100F43008C44000', 'pk', fcmd, say=lambda *_: None)
        h8 = img.header(out8); ck(h8['romfs'][1] == 4096, f'⑧ 没有 st_blocks（Windows）、写段超过 1 秒：照常写成，RomFS 长度 {h8["romfs"][1]}（期望 4096）')
    except Exception as e:
        ck(False, f'⑧ 没有 st_blocks 时写 IMG 不该失败：{type(e).__name__}: {e}')
    def boom(_): raise RuntimeError('等的时候出错')
    real_written = img.written; img.written = boom
    try:
        img.build(str(rd), [], str(T / 'w9.img'), '0100F43008C44000', 'pk', fcmd, say=lambda *_: None); ck(False, '⑧b 等的时候出错应往上抛')
    except RuntimeError:
        pid = int(open(str(fake) + '.pid').read()); time.sleep(0.2)
        try: os.kill(pid, 0); alive = True
        except OSError: alive = False
        ck(not alive, f'⑧b 等的时候本进程出错：假 romfs_index（pid {pid}）已收掉、不留在后台')
    finally:
        img.written = real_written
finally:
    img.os = real_os
    shutil.rmtree(T, ignore_errors=True)

# ⑨ #746 边写边腾解包（convert consume）：夹具按出包现场搭——产物根 romfs 是指向 RomFS 共享存储身份的软链（身份整棵只读）、存储里还有一个旧身份、
#   seed.txt 记的解包目录 src/romfs、资源包清单里的 RomFS 行与 romfs.files。期望：RomFS 段按公开格式读出的文件 = 原件（字节相同）；
#   写完之后这些各份一个文件都不剩（只留目录也算腾空）；不带 consume 时原样都在
def files_under(d):
    return sorted(str(p.relative_to(d)) for p in Path(d).rglob('*') if p.is_file()) if os.path.isdir(d) else []
def scene(base):
    import stat
    roots = base / 'roots'; store = roots / '.romfs_store' / 'kuan'
    data = {'a/x.bin': b'x' * 3000, 'b/y.txt': b'hello' * 99, 'z.dat': os.urandom(70000)}
    for ident in ('id0', 'id1'):
        for r, b in data.items(): (store / ident / r).parent.mkdir(parents=True, exist_ok=True); (store / ident / r).write_bytes(b)
    for d, _, _ in os.walk(store): os.chmod(d, stat.S_IRUSR | stat.S_IXUSR)   # 同 pack/roots.sh：身份整棵只读
    root = roots / 'kuan@v1'; root.mkdir(parents=True); os.symlink('../.romfs_store/kuan/id1', root / 'romfs')
    src = base / 'extract'
    for r, b in data.items(): (src / 'romfs' / r).parent.mkdir(parents=True, exist_ok=True); (src / 'romfs' / r).write_bytes(b)
    (root / 'seed.txt').write_text(f'src={src}\n', encoding='utf-8')
    (root / 'unpack.tsv').write_text('title_id\t0100F43008C44000\n', encoding='utf-8')
    pk = base / 'pack'; (pk / 'exefs').mkdir(parents=True); (pk / 'exefs' / 'main').write_bytes(b'M' * 500)
    rows = [('exefs/main', 500)] + [('romfs/' + r, len(b)) for r, b in data.items()]
    for r, b in data.items(): (pk / 'romfs' / r).parent.mkdir(parents=True, exist_ok=True); (pk / 'romfs' / r).write_bytes(b)
    (pk / 'romfs.files' / 'a').mkdir(parents=True); (pk / 'romfs.files' / 'a' / 'x.bin').write_bytes(data['a/x.bin'])
    (pk / 'index.tsv').write_text(''.join(f'{r}\t{n}\th\n' for r, n in rows), encoding='utf-8')
    return root, pk, store, src, data
if shutil.which('dotnet') or os.path.exists(os.path.expanduser('~/.dotnet/dotnet')):
    for consume in (True, False):
        T = Path(tempfile.mkdtemp(prefix='img test 9 '))
        try:
            root, pk, store, src, data = scene(T)
            out = img.convert(str(root), str(pk), consume=consume)
            h = img.header(out); got = std_romfs(out, h['romfs'][0])
            ck(got == data, f'⑨ consume={consume}：RomFS 段文件 = 原件（{sorted(got)}）')
            left = dict(store=files_under(store), src=files_under(src / 'romfs'), pack=[f for f in files_under(pk) if f.startswith('romfs')])
            if consume:
                ck(all(not v for v in left.values()), f'⑨ consume：写完存储各身份 / 解包目录 / 资源包 RomFS 行与 romfs.files 一个文件都不剩（剩 {left}）')
            else:
                ck(len(left['store']) == 6 and len(left['src']) == 3, f'⑨ 不带 consume：存储两个身份、解包目录原样都在（{len(left["store"])} / {len(left["src"])}）')
        finally:
            for d, _, _ in os.walk(T): os.chmod(d, 0o755)
            shutil.rmtree(T, ignore_errors=True)
    # ⑨b 玩家原件与工作目录外的解包目录任何时候都不删（11-12）：原件（xci）放在工作目录外，seed.txt 指向工作目录外的解包目录（命令行 --from-extract 的用法）；
    #   consume 写完：原件 SHA-256 不变、外面解包目录的文件一个不少；工作目录里共享存储的另一身份照删
    T = Path(tempfile.mkdtemp(prefix='img test 9b ')); X = Path(tempfile.mkdtemp(prefix='img test 9b ext '))
    try:
        root, pk, store, src, data = scene(T / 'work')
        orig = X / 'sources' / 'game.xci'; orig.parent.mkdir(parents=True); orig.write_bytes(os.urandom(200000)); h0 = hashlib.sha256(orig.read_bytes()).hexdigest()
        shutil.copytree(src, X / 'extract'); (root / 'seed.txt').write_text(f'src={X / "extract"}\n', encoding='utf-8')
        img.convert(str(root), str(pk), consume=True, work=str(T / 'work'))
        ck(hashlib.sha256(orig.read_bytes()).hexdigest() == h0, '⑨b consume：工作目录外的玩家原件（xci）字节不变')
        ck(len(files_under(X / 'extract' / 'romfs')) == len(data), f'⑨b consume：工作目录外的解包目录一个不删（剩 {len(files_under(X / "extract" / "romfs"))} / {len(data)}）')
        ck(not files_under(store), f'⑨b consume：工作目录里的共享存储照删（剩 {files_under(store)}）')
    finally:
        for top in (T, X):
            for d, _, _ in os.walk(top): os.chmod(d, 0o755)
            shutil.rmtree(top, ignore_errors=True)
else:
    print('跳过 ⑨：没有 dotnet，编不了 services/romfs_index')

print(f'img 单测：{"全通" if not bad else f"{bad} 项不通"}'); sys.exit(1 if bad else 0)
