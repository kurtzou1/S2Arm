#!/usr/bin/env python3
# 管线种子表零配置生成单测（graphics/tools/direct/pso_seed.py，手造库键表 / 着色器表 / 两份真跑来源，约 1 秒）：期望行序按规则手写
#   库键 a b c d f；着色器表里计算着色器 c、f 在库里，e 不在库里；R 行字节数按 64 造（真的是 pso_skey 的字节数，这里只核长度规则）
#   来源一（文件）：S a、R(a, b)、R(a, x：x 不在库里)、R(长度不对)、C c、S a（重复）、一行认不出
#   来源二（目录，两个 .tsv + 一个别的文件）：R(a, b)（与来源一重复）、R(d, 无片元)、S z（不在库里）；另一份只有表头
#   期望：S a / R(a, b) / C c / R(d)——来源先后、各自行序、去重；库里其余计算着色器（f）不补（11-02 怪猎 6232 个只用 33–52）
#   反证：没有任何来源、或来源里一行可用的都没有 → 种子表空（玩家冷包里没跑过的款：首帧不等、用到再编）
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); PS = os.path.join(H, '..', 'pso_seed.py')
A, B, C, D, E, F, X, Z = (f'{i:016x}' for i in (0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 0x99, 0x77))
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
def rkey(vs, fs, nbytes=64, tag=0):   # pso_skey：vs[24] fs[24] 键名（以 0 结尾）+ 其余状态字节
    b = (vs + '_b').encode().ljust(24, b'\0') + ((fs + '_b').encode() if fs else b'').ljust(24, b'\0')
    return (b + bytes([tag]) * (nbytes - len(b))).hex()
with tempfile.TemporaryDirectory() as t:
    p = lambda *a: os.path.join(t, *a)
    open(p('keys.tsv'), 'w').write(''.join(k + '\n' for k in (A, B, C, D, F)))
    open(p('shader_map.tsv'), 'w').write('# map\n' + ''.join(f'x.bin\t{i}\t{st}\t{k}\t/p\n' for i, (st, k) in enumerate([('vertex', A), ('pixel', B), ('compute', C), ('compute', E), ('compute', F)])))
    RAB, RAX, RD = rkey(A, B), rkey(A, X), rkey(D, '', tag=7)
    open(p('src1.tsv'), 'w').write(f'# user list\nS\t{A}_b\t0\nR\t{RAB}\nR\t{RAX}\nR\t{RAB}00\nC\t{C}_b\nS\t{A}_b\t0\nQ\tjunk\n')
    os.makedirs(p('dev')); open(p('dev', 'phone1.tsv'), 'w').write(f'R\t{RAB}\nR\t{RD}\nS\t{Z}_b\t4\n'); open(p('dev', 'phone2.tsv'), 'w').write('# empty\n'); open(p('dev', 'notes.txt'), 'w').write(f'S\t{B}_b\t4\n')
    run = lambda *src: subprocess.run([sys.executable, PS, p('out.tsv'), p('keys.tsv'), p('shader_map.tsv'), '64', *src], capture_output=True, text=True)
    rows = lambda: [l.rstrip('\n') for l in open(p('out.tsv')) if not l.startswith('#')]
    r = run(p('src1.tsv'), p('dev'), p('missing.tsv'))
    want = [f'S\t{A}_b\t0', f'R\t{RAB}', f'C\t{C}_b', f'R\t{RD}']
    ck(f'合并行序 = S a / R(a,b) / C c / R(d)，库里其余计算着色器 f 不补（退出 {r.returncode}，得 {len(rows())} 行）', r.returncode == 0 and rows() == want)
    ck('R 行里片元不在库里、长度不对的不进；不在库里的 S 不进；目录里非 .tsv 不读', RAX not in ''.join(rows()) and f'{Z}_b' not in ''.join(rows()) and f'S\t{B}_b\t4' not in rows())
    ck(f'汇总行报来源与可用行数（{r.stdout.strip()[:160]}）', 'S 1 / R 2 / C 1' in r.stdout and '只收真跑见过的' in r.stdout and 'src1.tsv 3/7 行可用' in r.stdout and 'phone1.tsv 1/3 行可用' in r.stdout)
    ck('表头两行（注明生成器与「行序 = 首用序」）', open(p('out.tsv')).read().count('\n#') == 1 and 'pso_seed.py' in open(p('out.tsv')).read())
    r = run()
    ck(f'反证：没有来源 → 种子表空（{rows()}）', r.returncode == 0 and rows() == [] and '没有真跑来源' in r.stdout)
    r = run(p('dev', 'phone2.tsv'))
    ck(f'反证：来源只有表头（一行可用的都没有）→ 同没有来源，种子表空（{rows()}）', r.returncode == 0 and rows() == [] and '没有真跑来源' in r.stdout)
    # 几何着色器模拟的库名（11-05 Switch Sports 菜单转场）：<键>_bgv（顶点）、<键>_bg<数字>（第 i 段几何）与 <键>_b 同一个键 → 收；键不在库里的照旧不收（后缀合不合法只由宿主 lp_kind_of 判，这里不判：a_bx 进表、宿主预热当过期跳过，见 t_nvn_warm_geo ②）
    rg = lambda vs, fs: (vs.encode().ljust(24, b'\0') + fs.encode().ljust(24, b'\0') + bytes(16)).hex()
    RG = rg(f'{A}_bgv', f'{B}_b')
    open(p('geo.tsv'), 'w').write(f'R\t{RG}\nS\t{A}_bgv\t0\nS\t{D}_bg3\t2\nS\t{X}_bgv\t0\nS\t{A}_bx\t0\nS\t{A}_\t2\nR\t{rg(f"{X}_bgv", f"{B}_b")}\n')
    r = run(p('geo.tsv'))
    ck(f'几何变体：R(a_bgv, b) / S a_bgv / S d_bg3 / S a_bx 收；x_bgv（不在库里）、R(x_bgv, b)、短名 a_ 不收（得 {rows()}）', r.returncode == 0 and rows() == [f'R\t{RG}', f'S\t{A}_bgv\t0', f'S\t{D}_bg3\t2', f'S\t{A}_bx\t0'])
    # 只装库的 S 行挪末尾（11-07 卡顿线）：S d（顶点，键不在任何 R 行里）排在 R(a,b) 前 → 挪到最后；S a（R 里用到）、S d_bg3（几何阶段）、C c 原位
    open(p('lib.tsv'), 'w').write(f'S\t{D}_b\t0\nS\t{A}_b\t0\nS\t{D}_bg3\t2\nR\t{RAB}\nC\t{C}_b\nS\t{F}_b\t1\n')
    r = run(p('lib.tsv'))
    ck(f'只装库的 S d / S f 挪到末尾、保持原相对顺序；S a、几何 S d_bg3、R、C 原序（得 {rows()}；{r.stdout.strip()[:80]}）',
       r.returncode == 0 and rows() == [f'S\t{A}_b\t0', f'S\t{D}_bg3\t2', f'R\t{RAB}', f'C\t{C}_b', f'S\t{D}_b\t0', f'S\t{F}_b\t1'] and '只装库的 S 行 2 挪到末尾' in r.stdout)
    # 网格管线 M 行（11-13 开局发白根修②）：顶点位置是网格键，第 2 列任务键（「-」= 无），第 3 列补齐掩码。期望（按规则手写）：M(a 网格, b 片元, 无任务) 与 M(d, b, 任务 f) 收；
    #   任务键 x 不在库里的、网格键 x 不在库里的、长度不对的不收；收下的 M 行用到的键 a、d、b 算「建管线用到」，S a 不挪到末尾；统计行带 M 2
    MAB, MDB = rkey(A, B), rkey(D, B, tag=3)
    open(p('mesh.tsv'), 'w').write(f'S\t{A}_b\t0\nM\t{MAB}\t-\t0\nM\t{MDB}\t{F}_b\t0\nM\t{MAB}\t{X}_b\t0\nM\t{rkey(X, B)}\t-\t0\nM\t{MAB}00\t-\t0\n')
    r = run(p('mesh.tsv'))
    ck(f'M 行：键都在库里的两行收、S a 不挪到末尾；任务键 / 网格键不在库里、长度不对的不收（得 {rows()}；{r.stdout.strip()[:80]}）',
       r.returncode == 0 and rows() == [f'S\t{A}_b\t0', f'M\t{MAB}\t-\t0', f'M\t{MDB}\t{F}_b\t0'] and '/ M 2' in r.stdout)
print(f't_pso_seed：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
