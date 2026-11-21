#!/usr/bin/env python3
"""抽 Switch 着色器（10-25 维护者「抽着色器只做一次」）：python3 graphics/tools/direct/extract.py <产物根（含 romfs/ exefs/main，可有 aoc/）> <输出目录>
出包里的抽取都走这一份：共享抽取阶段 pack/stage_extract.sh 出到 <产物根>/extract/（按游戏输入 + 抽取代码的键，键不变就不重抽）；
  直连库 direct_lib.py 有 <产物根>/extract/ok 就克隆来用，没有（单独调用 / Windows 出包 / 单测）就当场调本文件，两边结果同一份代码出。
  不经 shell（11-20：Windows 上 Git Bash 的 fork 模拟在部分机器起不来子进程，整单失败），各抽取器都是本文件直接起的原生进程。
输出：ue_shaders/（RomFS 有 .pak 时 pack/ue_pak.py 解出的 Unreal 着色器代码存档，shader_split 读）、
  glslc_capture/（游戏运行时才用自带 glslcCompile 编着色器的款：translator/glslc_offline.py 出包期调游戏的编译器离线编，shader_split 按 DM_GLSLC_CAPTURE 读）、
  pkg/ + split/{shader_map,shader_facts,shader_pairs}.tsv（直连抽取 shader_split.py）、s2x/（S2Arm nxsh_extract.py，rows.tsv + src/）、各自的 .log、ok（全部成功才写）。
  追加内容（aoc/<序号>/）两边都并进来。
配置档：shader_split 读 DM_GAME / DM_GAMES_DIR 选的档，调用方设好（stage_extract.sh、direct_lib.py 都设）。
并行：J 路（J / S2A_CPU_BAKE = 本阶段分到的路数，tools/cores.sh；都没给才用 S2A_JOBS / 本机核数），两个抽取器内部都按 J 开进程池。
进度：出包进度协议（tools/progress.py Ticker）阶段「抽取」= 第几步 / 4 步，两个抽取器内部各有 Ticker
退出码：0 = 三份都出成；3 = 只给直连用的几份（Unreal 存档、GLSLC 离线编、直连抽取）出不来，或两边抽取合起来 0 支着色器（直连库一个键都出不了），
  打「🔴 直连库失败：<原因>」，调用方只出通用包；1 = 其余（缺文件、S2Arm 抽取失败——通用也要用它）
"""
import glob, os, re, signal, subprocess, sys, time

WIN = os.name == 'nt'
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', '..', 'tools'))
from progress import Ticker  # noqa: E402
import pool_workers  # noqa: E402

T_START = time.monotonic()


def secs(): return int(time.monotonic() - T_START)


def fwd(p): return p.replace('\\', '/') if WIN else p


def say(msg): print(f'[抽取] {msg}', flush=True)


class Exit(Exception):
    def __init__(self, code): super().__init__(code); self.code = code


def lines_of(p):
    try:
        with open(p, 'rb') as f: t = f.read().decode('utf-8', errors='replace')
    except OSError: return None
    if t.endswith('\n'): t = t[:-1]
    return t.split('\n') if t else []


def last_line(p):
    ls = lines_of(p)
    return ls[-1] if ls else ''


def tail(p, n):
    for l in (lines_of(p) or [])[-n:]: print(l)
    sys.stdout.flush()


def why(p):   # 失败原因：红行优先，没有取末行（非空）
    ls = lines_of(p) or []
    red = [l for l in ls if '[RED]' in l or '【红】' in l]
    w = red[-1] if red else next((l for l in reversed(ls) if l), '')
    return re.sub(r'^\[RED\] *', '', w)[:200]


def rmtree(p):
    import shutil, stat
    def unlock(fn, q, _):
        try: os.chmod(q, stat.S_IWRITE | stat.S_IREAD | (stat.S_IEXEC if os.path.isdir(q) else 0)); fn(q)
        except OSError: pass
    if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p, onerror=unlock)
    elif os.path.lexists(p): os.unlink(p)


def run(cmd, log, env=None):
    sys.stdout.flush()
    try:
        with open(log, 'wb') as f: return subprocess.run([str(c) for c in cmd], stdout=f, stderr=subprocess.STDOUT, env=env).returncode
    except OSError as e:
        print(f'{cmd[0]}: {e}', file=sys.stderr, flush=True); return 127


def main(argv):
    if len(argv) != 2: print(__doc__, file=sys.stderr); raise Exit(1)
    if not os.path.isdir(argv[0]): say(f'🔴 {argv[0]}：产物根不是目录'); raise Exit(1)
    ROOT = fwd(os.path.abspath(argv[0]) if WIN else os.path.realpath(argv[0]))   # Windows 工作区走短根联接：不展开
    X = fwd(os.path.abspath(argv[1])) if WIN else argv[1]
    R = fwd(os.path.normpath(os.path.join(HERE, '..', '..', '..'))); NX = R + '/graphics/nvn'
    PY = os.environ.get('S2A_PYTHON') or os.environ.get('S2A_PY') or sys.executable
    J = str(pool_workers.env_jobs('J', 'S2A_CPU_BAKE', 'S2A_JOBS'))   # 都没给 → 本机核数（tools/pool_workers.cores）
    # 抽取每路吃内存（#711：Windows 16 GB 抽取 MemoryError）：给了 S2A_CPU_BAKE（按内存封顶的重活路数）就不超过它——调用方常把 J 设成直连库编译的路数
    cap = os.environ.get('S2A_CPU_BAKE', '')
    if cap.isdigit() and int(cap) >= 1 and J.isdigit() and int(J) > int(cap): J = cap
    os.environ['J'] = J
    tk = [None]; ps = [0]
    def prog(msg):
        ps[0] += 1; say(f'第 {ps[0]}/4 步 {msg}')
        if tk[0] is None: tk[0] = Ticker('抽取', 4, every=0)
        else: tk[0].step()
    if not ((os.path.isdir(ROOT + '/romfs') or os.path.isfile(ROOT + '/romfs.std')) and os.path.isfile(ROOT + '/exefs/main')):
        say(f'🔴 {ROOT} 缺 romfs/（或镜像 romfs.std）或 exefs/main'); raise Exit(1)   # RomFS 目录或镜像都行（romfs_list.py image_of）
    try:
        rmtree(X); os.makedirs(X + '/split'); os.makedirs(X + '/pkg')
    except OSError as e:
        print(e, file=sys.stderr); raise Exit(1)
    # 资源目录列表走列表文件（一行一个，参数写 @<文件>），不拼进命令行：11-05 Windows 出包机怪猎崛起 273 个追加内容超过 Windows 命令行 32767 字符上限
    AOCS = [a[:-1] for a in sorted(glob.glob(glob.escape(ROOT) + '/aoc/*/')) if os.path.isdir(a)]
    dirs = [ROOT + '/romfs'] + AOCS
    with open(X + '/roms.lst', 'w', encoding='utf-8', newline='\n') as f: f.write(''.join(d + '\n' for d in dirs))
    with open(X + '/mains.lst', 'w', encoding='utf-8', newline='\n') as f: f.write(''.join(ROOT + '/exefs/main\n' for _ in dirs))
    # S2Arm 抽取（nxsh_extract）只读 romfs / exefs / aoc，不依赖下面三步的产出：开头就在后台起，与三步并行，末尾等它（11-03 火纹 S2Arm 293 秒 + 直连抽取 132 秒原先串行）。
    #   各步经无进展看门狗起（tools/nostall.py：S2A_NOSTALL_S，缺省 600 秒没有任何进展才判挂死、退 124）。前面三步出错提前退出时，退出前停掉这一路
    # 两路并行时合计不超过本阶段分到的 J（11-04）：S2Arm 抽取分 JX = ⌈J/2⌉ 路，三步分其余 JR = J − JX 路（下限 1）；ok 里 jobs 仍记本阶段总路数 JT
    JT = int(J); JX = (JT + 1) // 2; JR = max(1, JT - JX)
    NS = os.environ.get('S2A_NOSTALL_S') or '600'
    sx = secs()
    sys.stdout.flush()
    with open(X + '/s2x.log', 'wb') as f:
        sxp = subprocess.Popen([PY, R + '/tools/nostall.py', '--watch', X, NS, '--', PY, R + '/graphics/tools/shbake/nxsh_extract.py', X + '/s2x', '@' + X + '/roms.lst', '--nso', ROOT + '/exefs/main'],
                               stdout=f, stderr=subprocess.STDOUT, env=dict(os.environ, J=str(JX)))
    try:
        os.environ['J'] = str(JR)
        s = secs()
        # Unreal 着色器（10-25 维护者：上游靠它的 NSP 脚本出 ue_shaders、我方原来没有这一步，八方2 直连库出不来）：RomFS 里有 .pak 就由 pack/ue_pak.py 取出 / 合成解好的着色器代码存档
        prog('Unreal 着色器存档')
        sys.stdout.flush()
        if subprocess.run([PY, NX + '/tools/romfs_list.py', 'has-ext', ROOT + '/romfs', '.pak', '.utoc'], stderr=subprocess.DEVNULL).returncode == 0:
            if run([PY, R + '/pack/ue_pak.py', ROOT + '/romfs', X + '/ue_shaders'], X + '/ue_pak.log') != 0:
                say(f'🔴 直连库失败：Unreal 着色器存档抽不出（{why(X + "/ue_pak.log")}；{X}/ue_pak.log）'); raise Exit(3)
            say(last_line(X + '/ue_pak.log'))
        tu = secs() - s; s = secs()
        # 运行时 GLSLC 款：出包期用游戏自带的编译器离线编（要不要编由 glslc_offline.py 自己判）。
        #   Windows 还不能在出包期跑游戏自带的 GLSLC（pack/orch/oneclick_win.py glslc_gate 设 S2A_GLSLC_RUNTIME_ONLY=1）：不编，运行时由游戏自带编译器编、直连首遇现编接住
        if os.environ.get('S2A_GLSLC_RUNTIME_ONLY') == '1':
            prog('GLSLC 离线编（本平台跳过）'); say('GLSLC 离线编：本平台跳过，运行时现编'); os.makedirs(X + '/glslc_capture', exist_ok=True)
        else:
            prog(f'GLSLC 离线编（{JR} 路）')
            if run([PY, R + '/tools/nostall.py', '--watch', X, NS, '--', PY, NX + '/../../translator/glslc_offline.py', ROOT, X + '/glslc_capture'], X + '/glslc.log') != 0:
                say(f'🔴 直连库失败：GLSLC 离线编失败（{why(X + "/glslc.log")}；{X}/glslc.log）'); raise Exit(3)
            say(last_line(X + '/glslc.log'))
        env = dict(os.environ, DM_UE_SHADERS=X + '/ue_shaders', DM_OODLE_LOG_DIR=X)
        if glob.glob(glob.escape(X + '/glslc_capture') + '/*.glslc'): env['DM_GLSLC_CAPTURE'] = X + '/glslc_capture'   # 编出了才指给 shader_split
        tg = secs() - s; s = secs()
        prog(f'抽取着色器（直连抽取，{JR} 路）')
        if run([PY, R + '/tools/nostall.py', '--watch', X, NS, '--', PY, NX + '/../../translator/shader_split.py', '@' + X + '/roms.lst', '@' + X + '/mains.lst', X + '/pkg',
                X + '/split/shader_map.tsv', X + '/split/shader_facts.tsv', X + '/split/shader_pairs.tsv'], X + '/split.log', env=env) != 0:
            say(f'🔴 直连库失败：直连抽取失败（{why(X + "/split.log")}；{X}/split.log）'); tail(X + '/split.log', 3); raise Exit(3)
        ts = secs() - s; s = secs()
        prog(f'抽取着色器（S2Arm，{JX} 路，开头已在后台起）')
        sxrc = sxp.wait(); sxp = None
    finally:
        if sxp is not None and sxp.poll() is None: sxp.terminate()
    # S2Arm 抽取没跑成（v0.3.1 拿不准不停；#711 Windows MemoryError 原先就停在这里）：只用直连抽取的结果往下走，S2Arm 那份置空、记一笔
    if sxrc != 0:
        ls = lines_of(X + '/s2x.log') or []
        red = [l for l in ls if '[RED]' in l or '【红】' in l or 'Error' in l]
        sw = red[-1][:200] if red else next((l for l in reversed(ls) if l), '')[:200] or f'退出码 {sxrc}'
        say(f'🟡 S2Arm 抽取没跑成（{sw}；{X}/s2x.log），只用直连抽取的结果'); tail(X + '/s2x.log', 3)
        try:
            os.makedirs(X + '/s2x/src', exist_ok=True)
            for n, t in (('rows.tsv', '# 键\t阶段\t来源\t变体号\n'), ('index.tsv', '# 键\t阶段\t首个来源\t变体号\n'),
                         ('degrade.tsv', f'extract\ts2x_failed\t1\t\tS2Arm 抽取没跑成（{sw}），只用直连抽取的结果\n')):
                with open(f'{X}/s2x/{n}', 'w', encoding='utf-8', newline='\n') as f: f.write(t)
        except OSError as e:
            print(e, file=sys.stderr); raise Exit(1)
    tx = secs() - sx
    # 两边合起来 0 支（直连库并集为空）：本款这次出不了直连库，按内容缺口退 3、红行写清缺口类别，通用包照出
    nsp = sum(1 for l in lines_of(X + '/split/shader_map.tsv') or [] if not (l.startswith('#') or l.startswith('package\t')))
    nsx = sum(1 for l in lines_of(X + '/s2x/rows.tsv') or [] if not l.startswith('#'))
    if nsp == 0 and nsx == 0:
        red = [l for l in lines_of(X + '/split.log') or [] if l.startswith('[RED]')]
        w = re.sub(r'^\[RED\] *', '', red[-1])[:200] if red else ''
        say(f'🔴 直连库失败：直连抽取 0 支着色器（缺口：{w or "游戏文件里没有认得出的着色器容器"}；{X}/split.log）'); raise Exit(3)
    if tk[0] is None: tk[0] = Ticker('抽取', 4, every=0)
    tk[0].step(4)
    with open(X + '/ok', 'w', encoding='utf-8', newline='\n') as f: f.write(f'ue\t{tu}\nglslc\t{tg}\nsplit\t{ts}\ns2a_extract\t{tx}\njobs\t{JT}\n')
    say(f'🟢 {JT} 路（S2Arm {JX} + 其余 {JR}）：Unreal 存档 {tu} 秒、GLSLC 离线编 {tg} 秒、直连抽取 {ts} 秒、S2Arm {tx} 秒；追加内容 {len(AOCS)} 份')


if __name__ == '__main__':
    if WIN:
        for s in (sys.stdout, sys.stderr): s.reconfigure(encoding='utf-8')
    def term(sig, _): raise Exit(128 + sig)
    signal.signal(signal.SIGTERM, term)
    try:
        main(sys.argv[1:]); rc = 0
    except Exit as e: rc = e.code
    sys.stdout.flush()
    sys.exit(rc)
