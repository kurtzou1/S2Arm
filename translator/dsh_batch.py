#!/usr/bin/env python3
# 出包每键改写的 C# 常驻批量进程（graphics/tools/direct/dsh/batch，S2A.Dsh；11-01 dsh 收敛到 C#）：从仓库源码按需编到 <仓库>/build/dsh_batch（dotnet 增量编，文件锁），
#   给出调用命令与工具指纹（翻译器指纹 xfp = S2A.Dsh 全部源码 + Ryujinx 着色器翻译器逐文件摘要，加批量进程自己的源码摘要；进 dmsh_build.py 每支着色器的缓存键）。
#   get() 先看环境变量 DSH_BATCH_CMD / DSH_BATCH_FP：dmsh_par.py 在父进程编一次、交给各分片，分片不再各自 dotnet build（18 片排队增量编要一两分钟）
import hashlib, json, os, re, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import xlock   # 跨平台文件锁（Windows 出包机，#1100 W6）
DSH = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '../graphics/tools/direct/dsh'))
OUT = os.path.normpath(os.path.join(DSH, '../../../../build/dsh_batch'))


REPO = os.path.normpath(os.path.join(DSH, '../../../..'))
PROPS = {'Nx': os.path.join(REPO, 'graphics/nvn') + '/', 'Ryu': os.path.join(REPO, 'compat/tree/src') + '/'}   # S2A.Dsh.csproj 里路径用到的两个属性（同值）


def src_digest(proj):   # 工程按内容的摘要：ProjectReference 闭包里每个工程目录的全部文件（除 bin / obj / 点文件）+ 工程目录外单列的 Compile / DshXfpInput 文件 + 上层 Directory.Build.props
    #   重编按它判、不信时间戳（11-02 gate-host 时钟被手设慢 16 小时：旧 obj 时间戳落在将来，dotnet 增量把新源码当成旧的不重编，nxgal_fp_test 跑到旧 dll）
    seen, files, todo = set(), set(), [os.path.normpath(proj)]
    while todo:
        p = todo.pop(); d = os.path.dirname(p)
        if p in seen: continue
        seen.add(p)
        for top, dirs, names in os.walk(d):
            dirs[:] = [x for x in dirs if x not in ('bin', 'obj') and not x.startswith('.')]
            files.update(os.path.join(top, n) for n in names if not n.startswith('.'))
        up = d
        while up.startswith(REPO) and up != REPO:
            up = os.path.dirname(up); b = os.path.join(up, 'Directory.Build.props')
            if os.path.isfile(b): files.add(b)
        text = open(p, encoding='utf-8').read()
        for v in re.findall(r'>(\$\((?:Nx|Ryu)\)[^<;*]+)</', text):   # 属性值里单列的文件（如 DshChainHeader = dmsh_chain.h，生成 DshChain.g.cs 时读）
            f = os.path.normpath(re.sub(r'\$\((\w+)\)', lambda m: PROPS[m.group(1)], v))
            if os.path.isfile(f): files.add(f)
        for kind, inc in re.findall(r'<(ProjectReference|Compile|DshXfpInput)\s+Include="([^"]+)"', text):
            for one in inc.split(';'):
                one = re.sub(r'\$\((\w+)\)', lambda m: PROPS.get(m.group(1), m.group(0)), one).replace('\\', '/')
                if '*' in one or '$(' in one or '@(' in one: continue   # 通配的都在已整目录收的工程目录里
                f = os.path.normpath(os.path.join(d, one))
                if kind == 'ProjectReference': todo.append(f)
                elif os.path.isfile(f): files.add(f)
    h = hashlib.sha256()
    for f in sorted(files):
        h.update(os.path.relpath(f, REPO).encode() + b'\0' + hashlib.sha256(open(f, 'rb').read()).digest())
    return h.hexdigest()


def _dotnet():  # 本机的 dotnet 命令（源码树现编用；发版件是原生单文件、不经它）
    return os.environ.get("DOTNET") or (
        os.path.expanduser("~/.dotnet/dotnet")
        if os.path.exists(os.path.expanduser("~/.dotnet/dotnet"))
        else shutil.which("dotnet")
    )


def prebuilt(
    dg,
):  # 启动器内置的一份（launchers/macos/bundle_engine.py 发版时编进 <App>/…/Binaries/Prepare/dsh_batch，并写下按 App 内源码算的摘要）：摘要相同才用，不同（源码被改过）不用。
    #   → 内置件程序的路径：Mac / Windows 发版都是 NativeAOT 单文件（直接执行、不要 .NET 运行时；Windows 是 dsh_batch.exe，launchers/windows/bundle_prepare_win.py）
    d = os.environ.get('S2A_PREBUILT_TOOLS')
    if not d: return None
    p = os.path.join(d, 'dsh_batch')
    try: same = open(os.path.join(p, '.src_digest')).read().strip() == dg
    except OSError: return None
    if not same:
        return None
    for name in ("dsh_batch.exe", "dsh_batch"):
        f = os.path.join(p, name)
        if os.path.isfile(f):
            return f
    return None


def prebuilt_xfp():  # 启动器内置的 dsh_batch 在用（与 prebuilt() 同一判据：App 内源码摘要相同）时，发版按 App 内源码算好的翻译器指纹（bundle_engine.py 写的 .xfp，
    #   dmsh_chain.py --xfp 现算，非内置程序自报）；不在用 / 没记 → None。dmsh_chain.tree_xfp 用它：玩家机不带 .NET（预编件全为原生单文件）、没有 SDK，
    #   dotnet msbuild 展不开 DshXfpInput 清单（11-06 直连库印章核对）；源码树里内置件不在用时 build() 本就要 SDK 现编，照常现算
    if not os.environ.get("S2A_PREBUILT_TOOLS"):
        return None
    f = prebuilt(src_digest(os.path.join(DSH, "batch", "dsh_batch.csproj")))
    if not f:
        return None
    try:
        x = open(os.path.join(os.path.dirname(f), ".xfp")).read().strip()
    except OSError:
        return None
    return x if re.fullmatch(r"[0-9a-f]{16}", x) else None


def build():
    proj = os.path.join(DSH, "batch", "dsh_batch.csproj")
    dg = src_digest(proj)
    out = prebuilt(
        dg
    )  # 11-06 维护者「玩家体验至上」：玩家首次出包不再现编（Spare-host 约 25 秒 CPU）
    if out is None:
        if os.environ.get("S2A_PREBUILT_TOOLS"):
            # App 里摘要不符 / 预编件缺 = App 装坏了（engine.json 逐文件封存的快照与预编件本是一对）：玩家机不现编、也没有 SDK（同 services/prebuilt_lib.sh 的口径），报重新安装
            sys.exit(
                "[RED] App 内置的直连批量进程（Prepare/dsh_batch）缺失或与引擎源码不符：请重新安装完整的 S2Arm（开发机要用本树源码现编就 unset S2A_PREBUILT_TOOLS）"
            )
        dn = _dotnet()
        if not dn:
            sys.exit(
                "[RED] no dotnet (DOTNET=…): the per-key rewrite is the C# S2A.Dsh batch process"
            )
        out = OUT; os.makedirs(OUT, exist_ok=True); stamp = os.path.join(OUT, '.src_digest')
        with xlock.held(os.path.join(OUT, '.lock')):   # 单测编 dsh_cmp（graphics/tools/direct/tests/dshfn.py）拿同一把锁：两边都编 S2A.Dsh 工程、共用它的 obj/（xlock：Mac flock / Windows msvcrt，同 #1100 W6）
            last = open(stamp).read().strip() if os.path.exists(stamp) else ''
            # 源码摘要与上次编成时相同、产物在 → 不再调 dotnet build（无改动的增量编也要起 MSBuild 几秒；11-06 出包速度线：refresh 快路预热之后直连库那次直接用）
            r = subprocess.CompletedProcess([], 0) if dg == last and os.path.isfile(os.path.join(OUT, 'dsh_batch.dll')) else subprocess.run([dn, 'build', proj, '-c', 'Release', '-o', OUT, '-nodeReuse:false', '-v', 'q', '-p:UseSharedCompilation=false', *([] if dg == last else ['--no-incremental'])],
                               capture_output=True, text=True)   # 源内容和上次编出这份产物时不同 → 全量重编（含引用工程）
            if not r.returncode: open(stamp, 'w').write(dg + '\n')
        if r.returncode:
            sys.exit("[RED] dsh_batch does not build: " + (r.stdout + r.stderr).strip()[-800:])
        cmd = [dn, os.path.join(out, "dsh_batch.dll")]
    else:   # 发版件（Mac / Windows）都是 NativeAOT 单文件，直接执行
        cmd = [out]
    x = subprocess.run([*cmd, "--xfp"], capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{16}", x):
        sys.exit("[RED] dsh_batch --xfp gave " + repr(x))
    return cmd, x + " " + hashlib.sha256(
        open(os.path.join(DSH, "batch", "Program.cs"), "rb").read()
    ).hexdigest()[:16]


def get():   # → (command, tool fingerprint)
    if os.environ.get('DSH_BATCH_CMD') and os.environ.get('DSH_BATCH_FP'): return json.loads(os.environ['DSH_BATCH_CMD']), os.environ['DSH_BATCH_FP']
    return build()


def export(env):   # 编一次，写进给子进程的环境
    cmd, fp = get(); env['DSH_BATCH_CMD'] = json.dumps(cmd); env['DSH_BATCH_FP'] = fp
    return env


def admitted(cmd, argv):   # 整份出库（build）经内存 + 核数准入（tools/mem_admit.sh dsh <键> --cores <-j>）：谁起的都过同一本账；其余子命令（单测的 --unity / --libpack 等小活）照原样
    if not argv or argv[0] != 'build' or os.environ.get('S2A_MEM_ADMIT') == '0' or sys.platform == 'win32': return cmd + argv   # Windows（Windows 出包机道）：mem_admit.sh 靠 flock / ps，不在 Windows 上，按调用方给的 -j 跑
    a = dict(zip(argv[1:], argv[2:]))   # 每个参数 → 它后面那个（取 --game / -j 的值）
    key = os.environ.get('S2A_MEM_KEY') or a.get('--game') or 'dsh_batch'   # S2A_MEM_KEY：pack/refresh.sh 给款名，与运行区实测表历来的键一致
    admit = os.path.normpath(os.path.join(DSH, '../../../../tools/mem_admit.sh'))
    # 排队期间 mem_admit 至少每 S2A_MEM_SAY_S（缺省 300）秒往 stderr 写一行【排队】：direct_lib.py 把它重定向进 build.log，外层 nostall.py（600 秒无进展）按日志在长算进展，不会把排队当挂死
    return ['bash', admit, 'dsh', key, '--cores', a.get('-j', '1'), '--', *cmd, *argv]


if __name__ == '__main__':   # 入口：python3 dsh_batch.py <dsh_batch 参数…>（按需编，再以这些参数执行；如 build（direct_lib.py）/ --unity share / --libpack pack，见 Build.cs / Unity.cs / LibPack.cs 文件头）
    if sys.argv[1:] == ['--src-digest']: print(src_digest(os.path.join(DSH, 'batch', 'dsh_batch.csproj'))); sys.exit(0)   # 发版打包按 App 内这份源码写内置件的摘要（bundle_engine.py）
    cmd, _ = get()
    run = admitted(cmd, sys.argv[1:])
    if sys.platform == 'win32': sys.exit(subprocess.run(run).returncode)   # Windows 的 execv 是新起进程、本进程先退，调用方拿不到退出码
    os.execvp(run[0], run)
