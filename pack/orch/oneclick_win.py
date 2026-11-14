#!/usr/bin/env python3
"""Windows 一键出包（Windows 出包机道，11-05 维护者「大游戏在 windows 上编，不用在 Mac 上挤」）：原件 → 解包 → 八个轻阶段 → 抽取 + 直连库 → 产物，全在本机。

  python -X utf8 -m pack.orch.oneclick_win <原件目录 | Switch 2 导出目录 | .nup> --out <工作目录> [--target ios|mac]
         [--title-id <程序号>] [--bundle-id <包名>] [--shell <预编壳目录>] [--jobs N] [--install <手机 UDID> [--name <桌面显示名>]]
  python -X utf8 -m pack.orch.oneclick_win --check [--target ios|mac] [--shell <壳目录>]    只做环境自检（一行一项，缺件退 75）
    启动器客户端不读这里：读 pack/jobs/winenv.py --json（统一开始前检查，出包件这几项就取本文件 env_items）
  --from-extract <解包目录>（代替原件，同 Mac pack/oneclick/oneclick.sh）：跳过认包 / 解包，用已解好的目录（exefs/main、unpack.tsv、romfs、ctl、aoc），
    认游戏读 unpack.tsv、不要 prod.keys / 原件；原件目录指向不存在的路径（追加内容阶段按「本机没原件」跳过，DLC 已在解包目录里）
  --events <文件>（机器读事件流，契约同 Mac 一键出包，启动器 pack/jobs/ipa.py oneclick_result() 直接读）：每行一个 JSON，都带 ev 与 t（秒）——
    stage（k / n / name）、stage_end（name / ok / elapsed）、say（msg）、result（ok；iOS 成功带 ipa / pack / files / size / build_id / graphics_mode，
    Mac 目标带 root；都带 aoc_missing、elapsed；失败带 msg）。人读输出不变；没给就一行不写

产物（<工作目录>/）：
  extract/            解包目录（nx_unpack / ns2_dump 产物，同 Mac 一键出包）
  roots/<款>@…        产物根（pack/orch 事务布局，现行 = <款>@现行）
  direct/             直连库（iOS 或 Mac 目标，graphics/tools/direct/direct_lib.sh，Git Bash 下跑）
  pkg/                --target ios：<款>.ipa（不签名，交侧载工具签）+ pack/ 资源包 v2；--target mac：product/ = 现行版本各项联接 + shaders/direct（普查回传整棵）
  timing.tsv          每步一行「步<TAB>秒<TAB>退出码」
--install <UDID>（只 iOS 目标）：出好后接 pack/orch/install_win.py——Impactor 官方命令行 plumesign 签名 + 装机（复用玩家在 Impactor 里登过的账号），再推资源包；
  原件到手机上一条命令、不用点。桌面显示名缺省带后缀「Win」（「<游戏名> S2Arm Win」，同实验包「实验」后缀一处出；11-06 维护者：
  测试设备上和 Mac 签的同款并存时 维护者 分不清），--suffix 另给（空串 = 不带）；不带 --install（Windows 出包机替 Mac 出包）不加后缀。事件流多一行 install（ok / bundle_id / elapsed，失败带 msg / code）。
退出码：0 成功；1 失败（标准输出最后一行【红】说明停在哪一步）；3 内容缺口（直连库出不了）；75 环境缺件（--check 同口径）。
今晚实测（11-05 Windows 出包机 20 核）：旷野之息 解包 39 秒 / 轻阶段 ~260 秒 / 直连库 267 秒 / ipa 136 秒；金刚 导出整理 91 秒 / 轻阶段 ~300 秒 / 直连库 493 秒 / ipa 196 秒。
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from pack.orch import shortroot   # noqa: E402

R = Path(__file__).resolve().parents[2]
PY = sys.executable
WIN = os.name == 'nt'
SRC_EXT = ('.nsp', '.xci', '.nsz', '.xcz')


RT_NAME = re.compile(r'\A[0-9a-f]{16}\.(ctl|code)\Z')
def put_rt(x, rt):
    """--rt-shaders：真机转储的着色器（DM_NVN_SHDUMP 存的 <键>.ctl / .code，游戏文件里抽不到、真机首遇只能现编的）拷进本单解包目录 x/rt_shaders/，
    播种（refresh.seed）带进产物根、直连阶段（direct_lib.sh rt_dump_merge.py）并进库。只用于内部验证包：转储是游戏内容、只在本机解包目录、不分发，玩家包没有它。
    只收「<16 位小写十六进制键>.ctl / .code」且两样成对的文件，别的一律报红不收；返回支数"""
    rt = Path(rt); fs = sorted(p for p in rt.iterdir() if p.is_file()) if rt.is_dir() else None
    if fs is None: raise Fail(f'--rt-shaders {rt} 不是目录')
    bad = [p.name for p in fs if not RT_NAME.match(p.name)]
    if bad: raise Fail(f'--rt-shaders {rt} 里有不认的文件（只收 <16 位键>.ctl / .code）：{bad[:5]}')
    keys = {}
    for p in fs: keys.setdefault(p.stem, set()).add(p.suffix)
    lone = sorted(k for k, s in keys.items() if s != {'.ctl', '.code'})
    if lone: raise Fail(f'--rt-shaders {rt} 里 .ctl / .code 不成对：{lone[:5]}')
    if not keys: raise Fail(f'--rt-shaders {rt} 是空目录')
    d = Path(x) / 'rt_shaders'; d.mkdir(exist_ok=True)
    for p in fs: shutil.copyfile(p, d / p.name)
    return len(keys)


class Fail(Exception):
    def __init__(self, msg, code=1): super().__init__(msg); self.code = code


def bash_exe():
    from .bash import find_bash
    return find_bash(nt=True)


def mixed(p):   # Windows 原生 Python 与 Git Bash 都认的写法（R:/a/b）
    return str(p).replace('\\', '/')


METAL_LAYOUTS = (('bin',), ('ios', 'bin'))   # 官方安装器（NSIS）现行：<安装目录>\bin\metal.exe（转发到 metal\<版本>\bin）；早期版本：ios\bin\metal.exe
METAL_UNINSTALL = (r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')


def _reg_values():
    r"""Windows 注册表里和 Metal 有关的两类登记（非 Windows → 空）：
    paths = 现在的 PATH（HKCU\Environment + HKLM 系统环境，展开 %变量%）——启动器开着时才装的工具，进程里继承的 PATH 是旧的，要现读；
    homes = 官方安装器的卸载登记（DisplayName 以 Metal Developer Tools 开头）的安装目录：安装器不写 PATH，玩家在安装界面改了目录（装到 D 盘）时只有这里记着"""
    if not WIN:
        return [], []
    try:
        import winreg
    except ImportError:   # 单测在 Mac / Linux 上把 WIN 设成真（as_windows）时没有 winreg：当作注册表里什么都没登记
        return [], []
    paths, homes = [], []
    for hive, key in ((winreg.HKEY_CURRENT_USER, 'Environment'),
                      (winreg.HKEY_LOCAL_MACHINE, r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment')):
        try:
            with winreg.OpenKey(hive, key) as k:
                paths.append(winreg.ExpandEnvironmentStrings(winreg.QueryValueEx(k, 'Path')[0]))
        except OSError:
            pass
    for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for root in METAL_UNINSTALL:
            try:
                top = winreg.OpenKey(hive, root)
            except OSError:
                continue
            with top:
                for i in range(winreg.QueryInfoKey(top)[0]):
                    try:
                        with winreg.OpenKey(top, winreg.EnumKey(top, i)) as k:
                            def val(name):
                                try: return str(winreg.QueryValueEx(k, name)[0] or '')
                                except OSError: return ''
                            if not val('DisplayName').startswith('Metal Developer Tools'):
                                continue
                            home = val('InstallLocation') or str(Path(val('UninstallString').strip().strip('"')).parent)
                            if home and home not in homes:
                                homes.append(home)
                    except OSError:
                        continue
    return paths, homes


def metal_search(environ=None, reg=None):
    """按优先级列出找 metal.exe 的每一处：[(来源, metal.exe 路径或 None, 找到?)]。显式 S2A_METAL_BIN 只列它一处（显式配置无效时不另选一份）。
    其余依次：玩家手动指定的文件夹（S2A_METAL_PICKED）→ 启动器启动时的 PATH（随包 s2arm_env.cmd 换 PATH 前存进 S2A_USER_PATH）→ 注册表里现在的 PATH（装完没重启启动器）→
    官方安装器卸载登记的安装目录（改过安装目录）→ 官方默认目录（%ProgramW6432% / %ProgramFiles%，系统不在 C 盘也认）。
    「复制错误摘要」带上这张表，玩家一贴就知道哪一处没找到。reg：单测注入 (paths, homes)"""
    e = os.environ if environ is None else environ
    configured = e.get('S2A_METAL_BIN')
    if configured:
        p = Path(configured) / 'metal.exe'
        return [('S2A_METAL_BIN', str(p), p.is_file())]
    rows = []
    picked = e.get('S2A_METAL_PICKED')   # 玩家在「准备这台电脑」里手动指定的文件夹（启动器 MetalFolder，已解析到 metal.exe 所在目录）
    if picked:
        p = Path(picked) / 'metal.exe'
        rows.append(('手动指定的文件夹', str(p), p.is_file()))
    def path_row(label, value):
        found = shutil.which('metal.exe', path=value) if value else None
        # PATH 可以含相对目录；后续编译在仓库目录运行，传给子进程前固定为绝对路径。
        rows.append((label, str(Path(found).absolute()) if found else None, bool(found)))
    path_row('启动器启动时的 PATH', e.get('S2A_USER_PATH') or e.get('PATH'))
    paths, homes = _reg_values() if reg is None else reg
    path_row('注册表里现在的 PATH', os.pathsep.join(paths))
    seen = set()
    def home_rows(label, home):
        for layout in METAL_LAYOUTS:
            p = Path(home, *layout, 'metal.exe')
            if str(p).lower() in seen:
                continue
            seen.add(str(p).lower())
            rows.append((label, str(p), p.is_file()))
    for home in homes:
        home_rows('官方安装器登记的安装目录', home)
    for var in ('ProgramW6432', 'ProgramFiles'):
        if e.get(var):
            home_rows('官方默认目录', str(Path(e[var]) / 'Metal Developer Tools'))
    home_rows('官方默认目录', r'C:\Program Files\Metal Developer Tools')
    return rows


def metal_search_text(rows):
    """给错误摘要用的一行：「来源 路径 → 有 / 没有」，没在 PATH 上的写「PATH 里没有 metal.exe」"""
    return '；'.join(f'{label}：{path} → {"有" if ok else "没有"}' if path else f'{label}：里面没有 metal.exe' for label, path, ok in rows)


def metal_exe(environ=None, reg=None):
    """Windows Metal：metal_search 里第一处找到的；都没找到 → 显式配置那份或官方默认目录（调用方照实报缺）。
    作业层（core.env）在父进程按这里选一次，显式写成子进程的 S2A_METAL_BIN"""
    rows = metal_search(environ, reg)
    for _, path, ok in rows:
        if ok:
            return Path(path)
    return Path(rows[0][1]) if rows[0][0] == 'S2A_METAL_BIN' else Path(r'C:\Program Files\Metal Developer Tools\bin') / 'metal.exe'


def metal_bin():
    return metal_exe().parent


def prebuilt(rel, ident=None):
    """启动器随发版预编的件（S2A_PREBUILT_TOOLS = Binaries/Prepare，launchers/windows/bundle_prepare_win.py 编；同 dsh_batch.py prebuilt 的口径）：
    文件在、且给了身份时与同目录 .src_digest 相同 → 路径；没设 / 不在 / 身份不符（引擎源码比预编件新）→ None，调用方照旧现编"""
    d = os.environ.get('S2A_PREBUILT_TOOLS')
    if not d: return None
    p = Path(d, rel)
    if ident is not None:
        try:
            if (p.parent / '.src_digest').read_text(encoding='utf-8').strip() != ident: return None
        except OSError: return None
    return p if p.is_file() else None


def dotnet_runtime_ok():   # 预编件只要 .NET 10 运行时（framework-dependent）：dotnet --list-runtimes 里有 Microsoft.NETCore.App 10.x
    dn = os.environ.get('DOTNET') or shutil.which('dotnet')
    if not dn: return False
    try: out = subprocess.run([dn, '--list-runtimes'], capture_output=True, text=True).stdout
    except OSError: return False
    return bool(re.search(r'^Microsoft\.NETCore\.App 10\.', out, re.M))


def env_items(target, shell):
    """环境自检：(项, 好?, 说明, 状态, 官方下载页)。只读不改、不下载；缺件写清去哪拿。
    状态：ok / missing / mismatch（有、但版本或身份不符，给了 found 为真的）；官方下载页（第 5 项）只给玩家要自己装、不能随包带的件（许可不许再分发），现无（Metal 由 winenv 核，下载页在 winenv.OFFICIAL）"""
    out = []
    def add(name, ok, why, found=False, url=None): out.append((name, bool(ok), why, 'ok' if ok else 'mismatch' if found else 'missing', url))
    pre = os.environ.get('S2A_PREBUILT_TOOLS')   # 启动器随发版预编（launchers/windows/bundle_prepare_win.py）：编译器 / 构建工具 / .NET SDK 各项改核对应预编件在不在
    add('python', sys.version_info >= (3, 12), f'{sys.version.split()[0]}（要 ≥ 3.12）', found=True)
    if pre:
        add('dotnet', dotnet_runtime_ok(), '预编的 C# 件要 .NET 10 运行时（dotnet --list-runtimes 有 Microsoft.NETCore.App 10.x）')
        sys.path.insert(0, str(R / 'translator')); import dsh_batch
        try: gd = prebuilt('gamedec/' + ('gamedec.exe' if WIN else 'gamedec'), gamedec_id())
        except Fail: gd = None
        miss = [n for n, ok in (('nx_unpack', prebuilt('nx_unpack/' + ('nx_unpack.exe' if WIN else 'nx_unpack'), nx_unpack_id())), ('gamedec', gd),
                                ('romfs', prebuilt('romfs/romfs_index.dll')),
                                ('dsh_batch', dsh_batch.prebuilt(dsh_batch.src_digest(os.path.join(dsh_batch.DSH, 'batch', 'dsh_batch.csproj'))) and dsh_batch.prebuilt_xfp())) if not ok]
        add('prebuilt-dotnet', not miss, f'预编 C# 件（{pre}，源码身份与本引擎相同才用）' + (f'缺或身份不符：{"、".join(miss)}' if miss else '齐'))
    else:
        add('dotnet', shutil.which('dotnet'), 'nx_unpack / RomFS 索引 / 直连出库（.NET 10 SDK）')
    add('git-bash', bash_exe(), '直连库脚本 direct_lib.sh 在 Git Bash 下跑（S2A_BASH 可指定）')
    if pre:
        sys.path.insert(0, str(R / 'graphics/widen/scan')); sys.path.insert(0, str(R / 'graphics/tools')); sys.path.insert(0, str(R / 'graphics/tools/shbake')); import ui_lyt, nxfmt, nxsh_extract
        miss = [n for n, ok in (('dsx/dsx.dll', prebuilt('dsx/dsx.dll')), ('codecs/' + ui_lyt.yaz0enc_name(), ui_lyt.yaz0enc_prebuilt()),
                                ('codecs/libyaz0dec', nxfmt.prebuilt_lib()), ('codecs/libcrilayla', nxsh_extract.cri_prebuilt())) if not ok]
        add('clang', not miss, f'预编直连翻译库 dsx / Yaz0 / CRI 小库（{pre}）' + (f'缺 {"、".join(miss)}' if miss else '齐'))
    else:
        add('clang', os.environ.get('S2A_CLANG') or shutil.which('clang'), '直连翻译库 dsx / Yaz0 小库现编')
    metal = metal_exe()
    add('metal', metal.is_file() if WIN else True, f'Metal Developer Tools（{metal.parent}；S2A_METAL_BIN 可指定，否则查 PATH / 官方安装目录）')
    sys.path.insert(0, str(R / 'graphics/tools/shbake')); import zstd_lib
    try: zstd_lib._lib(); zok, zwhy = True, 'libzstd 已装上'
    except zstd_lib.ZstdError as e: zok, zwhy = False, f'{e}（zstd 官方发行包加进 PATH）'
    add('zstd', zok, zwhy)
    tz = os.environ.get('S2A_TZDATA_CACHE')
    add('tzdata', (R / 'Binaries/Prepare/Tzdata/output').is_dir() or (tz and Path(tz, 'output').is_dir()),
        '钉版时区离线产物（S2A_TZDATA_CACHE/output，Mac 上 services/systemdata/make_tzdata.sh 生成后带来）')
    fonts = os.environ.get('S2A_FONTS')
    add('fonts', fonts and len(glob.glob(os.path.join(fonts, '*.bfttf'))) == 7, '开源共享字体 7 份（S2A_FONTS，Mac 上 pack/fonts/make_open_fonts.py 生成后带来）')
    if pre:
        from pack import rewriter
        rw = rewriter.bundled()
        add('rewriter', rw, f'预编改写器（{pre}\\rewriter，源码指纹与本引擎相同才用）' + ('' if rw else '：缺或指纹不符'))
    else:
        add('rewriter-deps', os.environ.get('S2A_REWRITER_DEPS') and os.path.isdir(os.environ['S2A_REWRITER_DEPS']), '改写器固定依赖（Capstone / LZ4，S2A_REWRITER_DEPS）')
        add('cmake', shutil.which('cmake') and shutil.which('ninja'), '改写器现编（cmake + ninja）')
    # 按接口才用的工具也在起单前核（11-05 维护者：缺就报红停单，不到直连库那步才发现）：OpenGL 款要 glslangValidator，版本与 Mac（Homebrew）同、钉在 glslang/build.sh；
    #   spirv-cross 由直连库按仓库源码现编（translator/spvc_inproc.py cli，要 clang++），不另装
    gv_want = re.search(r'^VER=([^;\s]+)', (R / 'graphics/third_party/glslang/build.sh').read_text(encoding='utf-8'), re.M).group(1)
    gv = prebuilt('glslang/glslangValidator.exe') or shutil.which('glslangValidator')
    gv_have = subprocess.run([gv, '--version'], capture_output=True, text=True).stdout.splitlines()[:1] if gv else []
    add('glslang', gv_have and re.fullmatch(rf'Glslang Version: \d+:{re.escape(gv_want)}', gv_have[0].strip()),
        f'OpenGL 款直连库要 glslangValidator {gv_want}（现有：{gv_have[0].strip() if gv_have else "PATH 上没有"}；Windows 上 bash graphics/third_party/glslang/build_cli_win.sh 编，放进机器环境 PATH）', found=bool(gv_have))
    if pre:
        sys.path.insert(0, str(R / 'translator')); import spvc_inproc
        add('spirv-cross', spvc_inproc.prebuilt(spvc_inproc.LIB) and spvc_inproc.prebuilt('cli', 'bin', spvc_inproc.CLI),
            f'预编 spirv-cross 进程内库 + 命令行（{pre}\\spvc，源码身份与本引擎相同才用）')
    else:
        add('clang++', shutil.which('clang++'), '直连库现编 spirv-cross 命令行（spvc_inproc.py cli）')
    from pack.orch.stages import LAYOUT_ZSTD   # 布局阶段钉的 zstd 命令行版本（11-05 一次成功线 ty4 01009B500007C000：Windows 出包机 1.5.6，轻阶段才报「布局需要钉版zstd 1.5.7」）
    zc = shutil.which('zstd'); zv = subprocess.run([zc, '--version'], capture_output=True, text=True).stdout.strip() if zc else ''
    add('zstd-cli', re.search(rf'\bv{re.escape(LAYOUT_ZSTD)}\b', zv), f'布局阶段要 zstd 命令行 {LAYOUT_ZSTD}（现有：{zv or "PATH 上没有"}；官方发行包 zstd-v{LAYOUT_ZSTD}-win64 放进机器环境 PATH）', found=bool(zv))
    if target == 'ios':
        sys.path.insert(0, str(R / 'pack/shell')); import manifest
        want = manifest.current_id()
        found = bool(shell) and Path(shell, 'manifest.json').is_file()
        have = found and json.load(open(Path(shell, 'manifest.json'), encoding='utf-8'))['details']['shellId'] == want
        add('shell', have, f'预编壳 {want}（--shell 指向 <壳目录>，含 manifest.json 与 root/；Mac 上 pack/shell_build.sh 出）', found=found)
    return out


class Run:
    def __init__(self, out, events=None):
        self.out = Path(out); self.out.mkdir(parents=True, exist_ok=True)
        self.timing = open(self.out / 'timing.tsv', 'a', encoding='utf-8', newline='\n')
        self.evf = open(events, 'w', encoding='utf-8', newline='\n') if events else None; self.k = 0

    def ev(self, kind, **kw):   # 事件流一行（--events，见文件头）；没给就不写
        kw = {k: shortroot.show(v) if isinstance(v, str) else v for k, v in kw.items()}   # 事件给界面：玩家只看到自己选的路径
        if self.evf: self.evf.write(json.dumps({'ev': kind, 't': int(time.time()), **kw}, ensure_ascii=False) + '\n'); self.evf.flush()

    def say(self, msg):
        msg = shortroot.show(msg); print(msg, flush=True); self.ev('say', msg=msg)

    def step(self, name, fn):
        t = time.time(); rc = 0; self.k += 1; self.ev('stage', k=self.k, n=None, name=name)
        print(f'[{time.strftime("%H:%M:%S")}] 开始：{name}', flush=True)   # 装机作业按开头行就进这一段（pack/jobs/ipa.py win_milestone），不再等上一步收尾才切
        try: return fn()
        except Fail as e: rc = e.code; raise
        except Exception: rc = 1; raise
        finally:
            dt = time.time() - t; self.timing.write(f'{name}\t{dt:.1f}\t{rc}\n'); self.timing.flush()
            print(f'[{time.strftime("%H:%M:%S")}] {name}：{dt:.1f} 秒' + ('' if rc == 0 else f'（rc={rc}）'), flush=True)
            self.ev('stage_end', name=name, ok=rc == 0, elapsed=int(dt))

    def sh(self, args, log, env=None, ok=(0,), cwd=None):
        with open(self.out / log, 'w', encoding='utf-8', newline='\n') as f:
            p = subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, env=env, cwd=cwd or R)
        if p.returncode not in ok:
            raise Fail(f'{log}：rc={p.returncode}；' + log_reason((self.out / log).read_text(encoding='utf-8', errors='replace')), p.returncode if p.returncode in (3, 75) else 1)   # 3 内容缺口 / 75 环境缺件（如缺 Git Bash、gamedec 编不出）原样上交，Windows 出包机道按 75 落回 Mac
        return p.returncode


def log_reason(text, limit=600):
    """工具日志 → 一句原因：有 Python 异常就以异常那一行（「XxxError: …」）开头、保住它，后面的附注（清理也失败之类，PEP 678 打在异常行之后）
    能放多少放多少；没有异常行照旧取末 3 行。原先一律取末 3 行的末 300 字，附注把原异常挤掉（#754：玩家报告里只剩「改名回去也失败」）"""
    lines = text.strip().splitlines()
    exc = max((i for i, l in enumerate(lines) if re.match(r'^[A-Za-z_][\w.]*(Error|Exception|Exit|Interrupt|Fail|Conflict|UnsafeRoot)\b.*', l)), default=None)
    if exc is None:
        return ' / '.join(lines[-3:])[-300:]
    head = ' / '.join(lines[exc:])
    return head if len(head) <= limit else head[:limit] + '…'


def nx_unpack_id():   # 源码身份（现编目录名与预编件 .src_digest 共用）
    import hashlib
    src = b''.join(Path(f).read_bytes() for f in sorted(glob.glob(str(R / 'pack/nx_unpack/*.cs')) + glob.glob(str(R / 'pack/nx_unpack/*.csproj'))))
    return hashlib.sha256(src).hexdigest()[:12]


def nx_unpack(run):
    ident = nx_unpack_id()
    pre = prebuilt('nx_unpack/' + ('nx_unpack.exe' if WIN else 'nx_unpack'), ident)
    if pre: return pre
    b = Path(os.environ.get('S2A_BIN') or run.out / 'bin') / ('nx_unpack_' + ident)
    exe = b / ('nx_unpack.exe' if WIN else 'nx_unpack')
    if not exe.is_file():
        run.sh(['dotnet', 'build', '-c', 'Release', str(R / 'pack/nx_unpack'), '-o', str(b), '-nologo', '-v', 'q'], 'nx_unpack_build.log')
    return exe


def from_extract(run, d):   # --from-extract：已解好的目录 → (x, 程序号, 原件目录)；原件目录指向不存在的路径（同 Mac：追加内容阶段按「本机没原件」跳过）
    x = Path(d).resolve()
    if not ((x / 'exefs' / 'main').is_file() and (x / 'unpack.tsv').is_file()): raise Fail(f'解包目录 {x} 要有 exefs/main 与 unpack.tsv（--from-extract）')
    tid = next((l.split('\t', 1)[1] for l in (x / 'unpack.tsv').read_text(encoding='utf-8').splitlines() if l.startswith('title_id\t')), '').strip().upper()
    if not re.fullmatch(r'[0-9A-F]{16}', tid): raise Fail(f'{x}/unpack.tsv 里读不出 title_id')
    return x, tid, x.parent / '.s2a-no-source'


def aoc_missing(cur):   # 没解出的追加内容原始包文件名（产物根 aoc.log 的「追加内容缺」行，同 pack/roots.sh root_aoc_missing）
    try: return [c[1] for c in (l.split('\t') for l in (Path(cur) / 'aoc.log').read_text(encoding='utf-8', errors='replace').splitlines()) if len(c) > 1 and c[0] == '追加内容缺' and c[1]]
    except OSError: return []


def ipa_facts(p):   # 交付 IPA 的包号与画面模式（Info.plist 的 S2ABuildID / S2AGraphicsMode，ipa_tail.py 写、启动器读的同一份）
    import plistlib, zipfile
    with zipfile.ZipFile(p) as z:
        names = [n for n in z.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(names) != 1: raise Fail(f'IPA 里 Payload/<App>.app/Info.plist 应恰好 1 份，实有 {len(names)} 份（{p}）')
        d = plistlib.loads(z.read(names[0]))
    if not d.get('S2AGraphicsMode'): raise Fail(f'交付的 IPA 读不出画面模式（{p}）')
    return d.get('S2ABuildID', ''), d['S2AGraphicsMode']


def drop_seed_link(x):
    """上一单播种把解包目录的 RomFS 整目录搬进了产物根、原处留的是指向存储的联接（pack/orch/refresh.py seed move_romfs）：
    重解前只删这个联接，不进去删（存储封存只读）"""
    from pack.orch.roots import is_link, remove_owned
    if is_link(x / 'romfs'): remove_owned(x / 'romfs')


def unpack(run, sources, title_id, program_index=0):
    """program_index > 0：多程序合集（一个应用里多支程序）解第 n 支到 extract_p<n>（nx_unpack --program-index，按内容自己的序号挑 Program / Control）"""
    x = run.out / ('extract' if not program_index else f'extract_p{program_index}')
    exe = run.step('编 nx_unpack', lambda: nx_unpack(run))
    env = dict(os.environ, PYTHONUTF8='1', S2A_NX_UNPACK=str(exe))
    s = Path(sources[0])
    nup = [p for p in sources if p.lower().endswith('.nup')] or (glob.glob(os.path.join(sources[0], '*.nup')) if s.is_dir() else [])
    export = next((d for d in [s] + ([Path(p) for p in glob.glob(os.path.join(sources[0], '*'))] if s.is_dir() else []) if (d / 'base/exefs/main.npdm').is_file()), None)
    drop_seed_link(x)
    shutil.rmtree(x, ignore_errors=True)
    if export is None and nup:   # Switch 2 NUP 容器：先展开成导出目录
        name = re.sub(r' \[.*$', '', Path(nup[0]).stem)
        export = run.out / 'ns2_dump' / name
        run.step('展开 NUP', lambda: run.sh([PY, '-X', 'utf8', str(R / 'pack/ns2_nup.py'), nup[0], str(export)], 'ns2_nup.log', env=env))
    if export is not None:   # Switch 2 导出目录（目录名即无控制分区时的标题：别改名）
        run.step('整理导出目录', lambda: run.sh([PY, '-X', 'utf8', str(R / 'pack/ns2_dump.py'), str(export), str(x)], 'ns2_dump.log', env=env))
        src_dir = export
    else:   # Switch 1 原件：按内容清单认款（pack/source_pick.py，与 Mac 一键出包同一份规则），本体 + 更新 + DLC 一起解
        keys = os.environ.get('S2A_KEYS') or os.path.expanduser('~/.switch/prod.keys')
        if not os.path.isfile(keys): raise Fail(f'prod.keys 不在：{keys}', 75)
        files = sorted(f for d in sources for f in ([d] if os.path.isfile(d) else glob.glob(os.path.join(d, '**', '*'), recursive=True)) if f.lower().endswith(SRC_EXT))
        if not files: raise Fail(f'{sources} 下没有 {"/".join(SRC_EXT)}')
        def pick():
            with tempfile.TemporaryDirectory() as t:
                with open(os.path.join(t, 'idx'), 'w', encoding='utf-8') as idx:
                    for i, f in enumerate(files, 1):
                        p = subprocess.run([str(exe), keys, '--inspect', f], capture_output=True)
                        if p.returncode == 0: Path(t, f'i{i}.json').write_bytes(p.stdout)
                        idx.write(f'{i}\t{f}\n')
                p = subprocess.run([PY, '-X', 'utf8', str(R / 'pack/source_pick.py'), t], capture_output=True, text=True, encoding='utf-8', env=dict(env, S2A_WANT_TID=title_id or ''))
            if p.returncode: raise Fail('认游戏：' + p.stderr.strip()[-300:])
            for l in p.stderr.splitlines(): print('   ' + l)
            lines = p.stdout.splitlines(); return lines[0], lines[4:]
        tid, sel = run.step('认游戏', pick)
        pi = [f'--program-index={program_index}'] if program_index else []
        run.step('解包' if not program_index else f'解包（序号 {program_index}）',
                 lambda: run.sh([str(exe), keys, str(x) + '.tmp', '--aoc-index', f'--title-id={tid}', *pi, *sel], 'unpack.log' if not program_index else f'unpack_p{program_index}.log'))
        os.replace(str(x) + '.tmp', x)
        src_dir = Path(sel[0]).parent
    run.step('直连版本旁注', lambda: run.sh([PY, '-X', 'utf8', str(R / 'pack/direct_profile_input.py'), str(x)], 'direct_profile_input.log', env=env))
    tid = next(l.split('\t', 1)[1] for l in (x / 'unpack.tsv').read_text(encoding='utf-8').splitlines() if l.startswith('title_id\t')).strip().upper()
    return x, tid, src_dir


GAMEDEC_SRC = ('pack/gamedec', 'compat/tree/src/ARMeilleure', 'compat/tree/src/Ryujinx.Cpu', 'compat/tree/src/Ryujinx.Memory', 'compat/tree/src/Ryujinx.Common')


def gamedec_id():   # 源码身份：gamedec 与它引用的 Ryujinx 工程按文件内容算（相对路径 + 字节，排序后摘要；跳过 bin / obj 编译产物）。
    #   现编目录名与预编件 .src_digest 共用。不用 git 树号：玩家机的引擎快照不是 git 仓库、也没装 git（11-06 启动器第 2 步干净运行时验收报 WinError 2）
    import hashlib
    h = hashlib.sha256()
    for d in GAMEDEC_SRC:
        base = R / d
        if not base.is_dir(): raise Fail(f'游戏解码器源码不全：缺 {d}', 75)
        for p in sorted(q for q in base.rglob('*') if q.is_file() and not {'bin', 'obj'} & set(q.relative_to(base).parts)):
            h.update(p.relative_to(R).as_posix().encode() + b'\0' + p.read_bytes() + b'\0')
    return h.hexdigest()[:12]


def gamedec(run):
    """游戏自带解码器的跨平台工具模式（pack/gamedec：ARMeilleure 在本机执行游戏 main 里的 Oodle / LZ5 解码函数，协议同 Mac 宿主工具模式）。
    按源码身份编一次，放 S2A_BIN（缺省 <输出>/bin）/gamedec_<身份>，同身份复用；启动器随发版预编的同身份一份在就直接用"""
    ident = gamedec_id()
    pre = prebuilt('gamedec/' + ('gamedec.exe' if WIN else 'gamedec'), ident)
    if pre: return pre
    b = Path(os.environ.get('S2A_BIN') or run.out / 'bin') / ('gamedec_' + ident)
    exe = b / ('gamedec.exe' if WIN else 'gamedec')
    if not exe.is_file():
        tmp = b.with_name(b.name + f'.tmp{os.getpid()}'); shutil.rmtree(tmp, ignore_errors=True)
        run.sh(['dotnet', 'build', '-c', 'Release', str(R / 'pack/gamedec/gamedec.csproj'), '-o', str(tmp), '-nologo', '-v', 'q'], 'gamedec_build.log', ok=(0,))
        try: tmp.rename(b)
        except OSError:   # 别的作业同时编好了同一身份：用它的
            if not exe.is_file(): raise
            shutil.rmtree(tmp, ignore_errors=True)
    return exe


def host_decoder_gate(run, x):
    """要游戏自带解码器（Oodle / LZ5）的款（判法在 pack/orch/host_decoder.py，只读 RomFS / 追加内容的文件头与容器头）：解包后、轻阶段前判出，
    编好 gamedec 并设 DM_OODLE_HOST（它）/ DM_OODLE_MODULES（解包目录，游戏原样 main 在 exefs/main），后面各阶段的 OodleHost 都用它
    （11-05 维护者：Oodle / LZ5 包要在 Windows 上自己解，不长期靠 Mac；Windows 出包机对照勇者斗恶龙 XI S LZ5 400 块、一款 UE 游戏 Oodle 91 块与 Mac 宿主逐字节相同）。
    gamedec 编不出才退 75（环境缺件），Windows 出包机道落回 Mac 出包"""
    from pack.orch import host_decoder
    why = run.step('判游戏解码器', lambda: host_decoder.need([str(x / 'romfs'), *sorted(str(d) for d in (x / 'aoc').glob('*') if d.is_dir())]))
    if not why: return
    print(f'[游戏解码器] 要（{why[0]}{f" 等 {len(why)} 处" if len(why) > 1 else ""}）：用 gamedec 在本机执行游戏自带解码器', flush=True)
    try: exe = run.step('编游戏解码器', lambda: gamedec(run))
    except Fail as e: raise Fail(f'要游戏自带解码器，但 gamedec 编不出（{e}），交回 Mac 出包', 75) from None
    os.environ['DM_OODLE_HOST'] = str(exe); os.environ['DM_OODLE_MODULES'] = str(x)


def glslc_need(x, G=None):
    """运行时 GLSLC 款要不要出包期离线编（判据同 translator/glslc_offline.py 主流程：need() 认出定义 glslcCompile 的模块、且 main / RomFS 的 NRO 里认得出整段源码；
    认不出源码的它自己打「不需要（运行时现编）」退 0，这里同样放行）→ 原因串 | None"""
    if G is None:
        sys.path.insert(0, str(R / 'translator')); import glslc_offline as G
    img = G.nso_syms.load(str(x / 'exefs' / 'main')); nros = G.romfs_nros(str(x))
    mod, _ = G.need(str(x / 'exefs'), img, nros)
    if not mod: return None
    srcs = G.all_sources(img, nros)
    return f'{mod} 带 glslcCompile，main / RomFS 的 NRO 里认出 {len(srcs)} 支 GLSL 源码' if srcs else None


def glslc_gate(run, x):
    """出包期离线编 GLSLC 要 Mac 宿主的工具模式（runtime/src/glslc_tool.c：调游戏自带 glslcCompile，要 SDK 初始化与 C# 服务层），Windows 还没有对应工具：
    解包后、轻阶段前判出要编就跳过离线编（S2A_GLSLC_RUNTIME_ONLY，extract.sh 认），运行时现编。设了 DM_GLSLC_HOST（有能用的宿主）就照常离线编"""
    if os.environ.get('DM_GLSLC_HOST'): return
    why = run.step('判运行时 GLSLC', lambda: glslc_need(x))
    if not why: return
    # 11-08 DQB2：Windows 还跑不了游戏自带的 GLSLC（gamedec GLSLC 模式在做），不再退回 Mac：出包跳过离线编，运行时由游戏自带编译器编、直连首遇现编接住；GLSL 多的款首次进局会多等一下
    print(f'[GLSLC] 本平台跳过出包期离线编（{why}）：运行时现编，首次进局可能多等一下', flush=True)
    os.environ['S2A_GLSLC_RUNTIME_ONLY'] = '1'


def stages(run, game, x, src_dir, own=False):
    roots = run.out / 'roots'
    # S2A_SEED_AOC=1：同 Mac 一键出包（pack/oneclick/oneclick.sh 私有产物根）——解包目录里的追加内容播进产物根。Switch 2 导出（ns2_dump）的 DLC 只在解包目录里、
    #   没有原件 NSP 给 aoc 阶段解，不播就整份丢（11-05 Windows 出包机金刚：导出 DLC 1 个 7270 文件 958 MB，产物根 / 资源包里都没有，直连库并集 15150 对 Mac 包 21036）
    # 轻阶段里的追加内容解包（pack/orch/stages.py _nxu）用本单选定的同一份 nx_unpack：原先它自己去 <S2A_RUN_ROOT>/s2arm/bin 找、找不到又只肯 --no-restore 现编，
    #   而本单解包步编在 run.out/bin（11-09 Windows 出包机 GRID 两单：nx_unpack 源码改了、身份变了，解包步现编成功、轻阶段退 75「离线还原资产未就绪」）。
    #   选一次（预编件 → 已编的 → 现编），显式交下去，两处不再各认各的目录
    env = dict(os.environ, PYTHONUTF8='1', S2A_GAME_SRC=str(src_dir), S2A_SEED_AOC='1', S2A_NX_UNPACK=str(nx_unpack(run)))
    run.step('播种', lambda: run.sh([PY, '-X', 'utf8', '-m', 'pack.orch.refresh', game, '--roots', str(roots), '--from-extract', str(x), *(['--move-romfs'] if own else []), '--stages', ''], 'seed.log', env=env))
    # RomFS 索引阶段按合同 --no-restore 编（不在阶段里悄悄下载）：新检出的代码树（Windows 出包机道按提交新建，11-05 海贼无双4 联调退 75）先在这里还原一次；
    #   包都在本机 NuGet 全局缓存里时不联网，缺包才会去源取
    proj = R / 'services/romfs_index'
    if not prebuilt('romfs/romfs_index.dll') and not (proj / 'obj/project.assets.json').is_file():   # 用预编 RomFS 索引（stages.py 同口径）就不编、不用还原
        run.step('还原 RomFS 索引依赖', lambda: run.sh(['dotnet', 'restore', str(proj), '-nologo', '-v', 'q'], 'romfs_index_restore.log'))
    run.step('八个轻阶段', lambda: run.sh([PY, '-X', 'utf8', '-m', 'pack.orch.refresh', game, '--roots', str(roots), '--stages', 'all-light'], 'light.log', env=env))
    cur = roots / f'{game}@现行'
    return Path(os.path.realpath(cur))


def pso_sources(tid, know=None):
    """Windows 出包机道送来的跑局知识（S2A_PSO_KNOW，tools/tianyan_lane.py ensure_know）→ 本款的 S2A_PSO_SOURCES：与 Mac 我方机器 direct_lib.sh PSRC 同顺序
    （wire/<程序号>/pso_user.tsv 在前、pso_seed/<程序号> 在后）。冒号分隔，盘符路径写成 Git Bash 的 /r/… 形（R:/… 里的冒号会被拆开；直连库调原生 Python 时自动转回）"""
    know = know or os.environ.get('S2A_PSO_KNOW')
    if not know or not tid: return None
    def posix(p):
        p = str(p).replace('\\', '/')
        return '/' + p[0].lower() + p[2:] if re.match(r'^[A-Za-z]:/', p) else p
    return ':'.join(posix(f'{know}/{rel}') for rel in (f'wire/{tid.upper()}/pso_user.tsv', f'pso_seed/{tid.upper()}'))


def title_lock(path, wait=True):
    """按款的直连缓存锁（<根>/<程序号>.lock 上的文件字节锁）：进程退出 / 被杀系统即放，不留死锁。拿到 → 打开的文件；wait=False 且被别的进程拿着 → None"""
    f = open(path, 'a+b')
    while True:
        try:
            if WIN:
                import msvcrt; f.seek(0); msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl; fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except OSError:
            if not wait: f.close(); return None
            time.sleep(5)


def dcache_lru(run, root, tid):
    """常驻直连缓存按容量预算淘汰（tools/direct_cache_lru.py，同 Mac tools/gc.sh）：别的单正拿着锁出库的款整款不动（它读过、还没刷修改时间的条目被删就记成翻译失败）"""
    busy = [tid]
    for lk in root.glob('*.lock'):
        if lk.stem == tid: continue
        f = title_lock(lk, wait=False)
        if f: f.close()
        else: busy.append(lk.stem)
    budget = os.environ.get('S2A_DIRECT_CACHE_BUDGET_GB', '60')
    try: run.step('直连缓存淘汰', lambda: run.sh([PY, '-X', 'utf8', str(R / 'tools/direct_cache_lru.py'), str(root), '--budget-gb', budget, '--in-use', ','.join(busy)], 'dcache_lru.log'))
    except Fail as e: run.say(f'【黄】直连缓存淘汰没跑成（{e}），本单产物不受影响；缓存可能超预算')   # 淘汰是收尾附带的，不改本单结论


def mem_gb():
    """本机物理内存（GB，取整）；读不到返回 None。S2A_MEM_TOTAL_GB 可手动指定（同 tools/cores.sh）"""
    v = os.environ.get('S2A_MEM_TOTAL_GB')
    if v and v.isdigit() and int(v) > 0:
        return int(v)
    if sys.platform == 'win32':   # 按真实平台（WIN 在单测里会被打桩成 True）
        import ctypes
        class MS(ctypes.Structure):
            _fields_ = [('dwLength', ctypes.c_ulong), ('dwMemoryLoad', ctypes.c_ulong)] + \
                       [(n, ctypes.c_ulonglong) for n in ('total', 'avail', 'pagefile', 'availpage', 'virt', 'availvirt', 'availext')]
        m = MS(); m.dwLength = ctypes.sizeof(MS)
        return int(m.total >> 30) if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)) and m.total else None
    try: return int(os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') >> 30) or None
    except (ValueError, OSError, AttributeError): return None


def parallel(jobs, gb):
    """(抽取 / 改写这类吃内存的重活路数 S2A_CPU_BAKE, 直连库编译路数 J)：同 Mac tools/cores.sh 的口径，按物理内存封顶。
    #711（11-11）：原先两者都直接取 --jobs（缺省逻辑核数），16 GB / 16 核以上的 Windows 机抽取开满核数路、MemoryError。
    Windows 有提交上限（物理内存 + 页面文件），超了直接 MemoryError，不像 Mac 能靠交换区硬扛。
    - 重活：min(jobs, 物理内存 × 3/4 ÷ 1.5 GB)
    - 直连库：min(jobs, 1 + (物理内存 × 3/4 − dsh 主进程 1740 MB − 1 个 metal 峰值 1065 MB) ÷ metal p90 420 MB)
    都至少 1；环境给了 S2A_CPU_BAKE / S2A_DIRECT_J 就用给的；内存读不到按 jobs（不拦，照旧跑）"""
    bake = direct_j = jobs
    if gb:
        bake = min(jobs, gb * 3 // 4 * 2 // 3)
        direct_j = min(jobs, 1 + (gb * 1024 * 3 // 4 - 1740 - 1065) // 420)
    env = lambda k, d: int(os.environ[k]) if os.environ.get(k, '').isdigit() and int(os.environ[k]) > 0 else d
    return max(1, env('S2A_CPU_BAKE', bake)), max(1, env('S2A_DIRECT_J', direct_j))


def direct(run, cur, target, jobs, tid=None, name='direct'):
    """直连库。缓存：S2A_DIRECT_CACHE（整条路径）> S2A_DIRECT_CACHE_ROOT/<程序号>（常驻，按款共用，11-06 出包速度线：Windows 出包机原先每单私有、成功即删，同款再出从零翻译 + 编 Metal）
    > <工作目录>/dcache（本单私有）。常驻时同款两单按文件锁串行（日志 logs/、跑局知识快照同目录），出完把本次 logs/ 拷回 <工作目录>/dcache/logs
    （tools/tianyan_lane.py 拉 direct_fail.log / 判红日志的路径不变），再按预算淘汰"""
    if WIN and not metal_exe().is_file():   # 物理上做得下去：不带着色器库照出包（product 收 dlib=None），游戏里首次遇到的画面现编、前几分钟会卡
        run.say(f'【黄】没找到 Metal 开发工具（{metal_exe().parent}）：这次不带着色器库，游戏能玩，首次遇到的画面现编、前几分钟会卡；'
                f'在「准备这台电脑」装好 Metal 开发工具后重新出包就不卡')
        run.ev('direct_skipped', reason='metal_missing')
        return None
    out = run.out / name   # 多程序合集序号 n：direct_p<n>（sub_programs）
    dsx = (prebuilt('dsx/dsx.dll') or R / 'build/dsx/win/dsx.dll') if WIN else None   # 直连翻译库：启动器随发版预编的在就用（同 Mac pack/stage_direct.sh 内置 dsx/libdsx.dylib）
    if WIN and not prebuilt('dsx/dsx.dll'): run.step('编 dsx', lambda: run.sh([PY, '-X', 'utf8', str(R / 'graphics/dsx/dsx_win.py'), str(dsx)], 'dsx_build.log'))
    dp = cur / 'direct_profile.json'   # 配置推导阶段写的档（零配置生成的在产物根 direct-profile/<键>/，手写档在仓库 graphics/nvn/games）
    prof = json.loads(dp.read_text(encoding='utf-8')) if dp.is_file() else {}
    games = cur / prof['DM_GAMES_DIR'] if prof.get('DM_GAMES_DIR') else R / 'graphics/nvn/games'
    gb = mem_gb(); bake, dj = parallel(jobs, gb)
    run.say(f'并行度：核数 {jobs}、物理内存 {gb if gb else "读不到"} GB → 抽取 / 改写 {bake} 路、直连库编译 {dj} 路')
    env = dict(os.environ, PYTHONUTF8='1', S2A_DIRECT_TARGETS=target, S2A_DIRECT_PUBLISH=target, J=str(dj), S2A_CPU_BAKE=str(bake),
               DM_GAMES_DIR=mixed(games), DM_GAMES_FIRST='1',
               S2A_PY=sys.executable, S2A_PYTHON=sys.executable)
    # Python / C# 编译器包装都读这个目录，metal 与 metallib 必须来自同一安装。
    if WIN: env['S2A_METAL_BIN'] = mixed(metal_bin())
    if dsx: env['DSX_LIB'] = mixed(dsx)
    gv = prebuilt('glslang/glslangValidator.exe')   # OpenGL 款离线翻译（gl_shaders.py 认 GLSLANG）：预编的在、调用方没另给就用它
    if gv and 'GLSLANG' not in env: env['GLSLANG'] = mixed(gv)
    src = None if os.environ.get('S2A_PSO_SOURCES') else pso_sources(tid)
    if src: env['S2A_PSO_SOURCES'] = src
    bash = bash_exe()
    if not bash: raise Fail('没有 Git Bash（直连库脚本要它）', 75)
    shutil.rmtree(out, ignore_errors=True)
    label = '抽取 + 直连库' if name == 'direct' else f'抽取 + 直连库（{name}）'; dname = 'dcache' if name == 'direct' else f'dcache_{name}'   # 多程序合集各序号的私有缓存 / 日志分开
    croot = os.environ.get('S2A_DIRECT_CACHE_ROOT') if not os.environ.get('S2A_DIRECT_CACHE') and tid else None
    if not croot:
        env['S2A_DIRECT_CACHE'] = mixed(os.environ.get('S2A_DIRECT_CACHE') or run.out / dname)
        run.step(label, lambda: run.sh([bash, mixed(R / 'graphics/tools/direct/direct_lib.sh'), mixed(cur), mixed(out)], 'direct_lib.log', env=env))
        return out
    root = Path(croot); root.mkdir(parents=True, exist_ok=True); c = root / tid.upper(); env['S2A_DIRECT_CACHE'] = mixed(c)
    lk = run.step('等同款直连缓存锁', lambda: title_lock(root / f'{tid.upper()}.lock'))
    try:
        run.say(f'直连缓存（常驻）：{c}')
        try: run.step(label, lambda: run.sh([bash, mixed(R / 'graphics/tools/direct/direct_lib.sh'), mixed(cur), mixed(out)], 'direct_lib.log', env=env))
        finally:
            mine = run.out / dname / 'logs'; shutil.rmtree(mine, ignore_errors=True); mine.mkdir(parents=True)
            for f in (c / 'logs').glob('*.log'): shutil.copy2(f, mine / f.name)
        dcache_lru(run, root, tid.upper())
    finally: lk.close()
    return out


def junction(dst, src):
    """工作根里联到现行各项 / 直连库。游戏库所在盘建不了联接（exFAT / FAT32，v0.3.1 玩家确认过照用，pack/orch/roots.py links_supported）时整份拷过来：
    多占一份空间（空间预算已按这类盘多算），产物一样"""
    target = shortroot.to_long(src, shortroot.table_now())
    if WIN and shortroot.is_unc_path(target):
        shutil.copytree(src, dst)
        return
    try:
        if WIN:   # 目标写真实长路径：短根是工作期的入口，产物里的联接要在它之外也有效；CreateJunction 不受 cmd 的长度限制
            import _winapi
            _winapi.CreateJunction(shortroot.to_long(src, shortroot.table_now()), str(dst))
        else: os.symlink(src, dst)
    except OSError:
        if os.path.lexists(dst):
            raise
        shutil.copytree(src, dst)


def product(run, cur, dlib, w=None):
    """工作根 = 现行版本各项联接（不拷、不改不可变版本）+ shaders/direct → 直连库输出；dlib=None 不联直连库（出包重叠的早期包）。w 缺省 <输出>/pkg/product（多程序合集的序号 n 组在 product/programs/<n>）"""
    w = w or run.out / 'pkg' / 'product'
    if w.exists(): subprocess.run(['cmd', '/c', 'rmdir', '/s', '/q', str(w)], check=True) if WIN else shutil.rmtree(w)
    w.mkdir(parents=True)
    for e in os.listdir(cur):
        s = cur / e
        if e in ('pkg', 'shaders'): continue
        junction(w / e, os.path.realpath(s)) if s.is_dir() else shutil.copy2(s, w / e)
    (w / 'shaders').mkdir()
    if dlib: junction(w / 'shaders' / 'direct', dlib)
    return w


def programs_of(x):
    """解包目录里记的支数（nx_unpack 只给多程序合集写 programs 行；没有 = 1 支）"""
    for l in (x / 'unpack.tsv').read_text(encoding='utf-8').splitlines():
        if l.startswith('programs\t'): return int(l.split('\t', 1)[1])
    return 1


def sub_programs(run, a, x, w, src_dir):
    """多程序合集（11-06 索尼克×夏特 世代重启：主菜单 ExecuteProgram(1) 切到同包第 2 支程序）：序号 1..n-1 各当一款走完整出包
    （解包 → 轻阶段 → 抽取 + 直连库，款名 t<该支程序号>），组到 <工作根>/programs/<序号>/——与运行侧约定同结构（runtime/include/s2a_programs.h、
    services Application.ProgramDir：模块目录与游戏数据目录都在这里，Mac 产物根两者同根）。单程序款不进来"""
    n = programs_of(x)
    if n <= 1: return
    # --from-extract 的共用解包目录只有序号 0；其余序号从原件解（作业层把游戏库里的原件跟在后面一起给，#613）
    if a.from_extract and not a.source: raise Fail(f'多程序合集（{n} 支）：--from-extract 只给了序号 0 的解包目录，其余序号要从原件解，原件没一起给')
    for i in range(1, n):
        xi, tid_i, _ = unpack(run, a.source, a.title_id, i)
        if WIN: host_decoder_gate(run, xi); glslc_gate(run, xi)
        cur_i = stages(run, 't' + tid_i.lower(), xi, src_dir)
        dlib_i = direct(run, cur_i, a.target, a.jobs, tid_i, name=f'direct_p{i}')
        (w / 'programs').mkdir(exist_ok=True)
        run.step(f'组工作根（序号 {i}）', lambda: product(run, cur_i, dlib_i, w / 'programs' / str(i)))
        run.say(f'🟢 多程序合集序号 {i}（{tid_i}）→ {w / "programs" / str(i)}')


def save_identity_args():
    """存档游戏身份（作业层 pack/jobs/ipa.py 按游戏库目录写好、经 S2A_SAVE_IDENTITY 交来）：带进包，iPhone 的存档管理 / iCloud 同步靠它认游戏（#298 同批根修）"""
    si = os.environ.get('S2A_SAVE_IDENTITY')
    return ['--save-identity', si] if si else []


def ipa(run, w, game, shell, bundle_id, suffix=''):
    title = subprocess.run([PY, '-X', 'utf8', str(R / 'pack/display_name.py'), str(w), '--title'], capture_output=True, text=True, encoding='utf-8').stdout.strip()
    env = dict(os.environ, PYTHONUTF8='1')
    run.step('ipa 收尾', lambda: run.sh([PY, '-X', 'utf8', str(R / 'pack/ipa_tail.py'), '--work', str(w), '--game', game, '--shell', str(shell),
                                        '--bundle-id', bundle_id or f'io.github.s2arm.{game}', '--suffix', suffix, '--key', f'tianyan {game}',
                                        '--title', title, '--sign', 'none', *save_identity_args()], 'ipa_tail.log', env=env))
    return w / 'pkg' / f'{game}.ipa', title


def Early(run, a, cur, game):
    """出包与装机重叠（--install；骨架与 Mac 启动器共用 pack/jobs/early.py 的 Overlap，11-06 两端合一。玩家等的是「出包开始 → 能玩」）：
    轻阶段完成、直连库开编时起线程：<输出>/early/product 组不联直连库的工作根 → ipa_tail 出早期包（App + 不含着色器库的资源包）
    → install_win 签名装机 + 推（tools/push_pack.py：推完整的批记 .pushed、留在机上待解）。正式包出完再装一次，推包只补差量（着色器库 + 变了的文件）。
    早装出错不判整单失败（正式安装照常整包兜底）；只写自己的日志 <输出>/early/early.log，不碰主线程的计时与事件流。→ Overlap（.start() / .finish() → (结果, 错误)）"""
    from pack.orch import install_win   # 顺带把 pack/jobs 放上模块搜索路径
    import early
    d = run.out / 'early'; log = d / 'early.log'

    def build():
        shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
        w = product(run, cur, None, d / 'product')
        title = subprocess.run([PY, '-X', 'utf8', str(R / 'pack/display_name.py'), str(w), '--title'], capture_output=True, text=True, encoding='utf-8').stdout.strip()
        suffix = a.suffix if a.suffix is not None else 'Win'
        with open(log, 'w', encoding='utf-8', newline='\n') as f:
            p = subprocess.run([PY, '-X', 'utf8', str(R / 'pack/ipa_tail.py'), '--work', str(w), '--game', game, '--shell', str(a.shell),
                                '--bundle-id', a.bundle_id or f'io.github.s2arm.{game}', '--suffix', suffix, '--key', f'tianyan {game} early',
                                '--title', title, '--sign', 'none', *save_identity_args()], stdout=f, stderr=subprocess.STDOUT, env=dict(os.environ, PYTHONUTF8='1'), cwd=R)
        if p.returncode or not (w / 'pkg' / f'{game}.ipa').is_file(): raise RuntimeError(f'早期包没出成（ipa_tail 退 {p.returncode}，见 {log}）')
        return w

    def install(w):
        pk = w / 'pkg' / 'pack'
        ns = argparse.Namespace(ipa=str(w / 'pkg' / f'{game}.ipa'), pack=str(pk), udid=a.install, name=a.name, plumesign=a.plumesign, devpush=a.devpush,
                                full=False, log=str(d / 'plumesign.log'))
        with open(d / 'early_install.log', 'a', encoding='utf-8', newline='\n') as f:   # 签名装机 + 推包的进度行（每批速率）落盘，事后能拆早装时间线
            def say(m): f.write(f'[{time.strftime("%H:%M:%S")}] {m}\n'); f.flush()
            return dict(bundle_id=install_win.run(ns, say=say), files=sum(1 for x in pk.rglob('*') if x.is_file()))

    return early.Overlap(build, install)


def install(run, a, ipa_path, pk):   # --install：签名装机 + 推资源包（pack/orch/install_win.py）
    from pack.orch import install_win
    ns = argparse.Namespace(ipa=str(ipa_path), pack=str(pk), udid=a.install, name=a.name, plumesign=a.plumesign, devpush=a.devpush, full=False,
                            log=str(run.out / 'plumesign.log'))
    t = time.time()
    try: bid = run.step('签名装机 + 推资源包', lambda: install_win.run(ns, say=run.say))
    except install_win.Fail as e:
        run.ev('install', ok=False, msg=str(e), code=e.err, elapsed=int(time.time() - t)); raise Fail(str(e), e.code)
    run.say(f'🟢 已装到 {a.install}（{bid}），资源包已推；{time.time() - t:.0f} 秒'); run.ev('install', ok=True, bundle_id=bid, elapsed=int(time.time() - t))


def share_walk_dir(out):
    """RomFS 读头清单（graphics/nvn/tools/romfs_list.py，按内容身份命名）本单各步共用一个目录：判解码器读解包目录的头、播种搬进产物根后
    caps / 配置推导按同身份直接取，不再冷读一遍（11-06 出包速度线：王国之泪 30.5 万个文件，caps 132 秒里约 119 秒是冷读头）"""
    os.environ.setdefault('S2A_ROMFS_WALK', str(Path(out).resolve() / '.romfs-walk'))


TEMP_MAX = 200   # TMP / TEMP 的上限：超过 MAX_PATH 时 CreateProcess 的兼容性查询（BasepQueryAppCompat）在 GetTempPath 上无限循环，子进程永远起不来


def work_temp(out):
    """临时文件跟工作目录走（11-06 维护者：Windows 出包机 C 盘被编库临时文件写满，时之笛出库两次失败；玩家机 C 盘常常很小）：
    本进程与全部子进程（C# 编库 Path.GetTempPath、Python tempfile、dotnet、bash）的 TMP / TEMP / TMPDIR 指到 <工作目录>/tmp，
    不再落系统盘的用户 Temp。在 main 起步时设一次，之后起的子进程都继承；S2A_KEEP_SYSTEM_TEMP=1 时保持原样（排查用）"""
    if os.environ.get('S2A_KEEP_SYSTEM_TEMP') == '1': return None
    t = Path(out).resolve() / 'tmp'   # out 已是短入口下的路径：实际落在玩家选的目录
    if WIN and len(str(t)) > TEMP_MAX:   # 只有建不了短入口才会走到这里：TEMP 不能超长，退回系统 Temp
        print('【黄】工作目录路径太长且建不了短路径入口，临时文件用系统 Temp', file=sys.stderr)
        return None
    t.mkdir(parents=True, exist_ok=True)
    for k in ('TMP', 'TEMP', 'TMPDIR'): os.environ[k] = str(t)
    tempfile.tempdir = None   # tempfile 缓存过系统 Temp 的话重新按环境变量取
    return t


def main(argv=None):
    for s in (sys.stdout, sys.stderr):
        if hasattr(s, 'reconfigure'): s.reconfigure(encoding='utf-8')
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('source', nargs='*'); ap.add_argument('--out'); ap.add_argument('--target', choices=('ios', 'mac'), default='ios')
    ap.add_argument('--title-id'); ap.add_argument('--bundle-id'); ap.add_argument('--shell'); ap.add_argument('--jobs', type=int, default=os.cpu_count() or 8)
    ap.add_argument('--check', action='store_true'); ap.add_argument('--from-extract'); ap.add_argument('--events')
    ap.add_argument('--rt-shaders', metavar='DIR')   # 内部验证包：真机转储的着色器并进解包目录（put_rt）；不给 = 不带（缺省行为不变）
    ap.add_argument('--install', metavar='UDID'); ap.add_argument('--name'); ap.add_argument('--suffix'); ap.add_argument('--plumesign'); ap.add_argument('--devpush')
    a = ap.parse_args(argv)
    if a.install and a.target != 'ios': ap.error('--install 只用于 --target ios')
    items = env_items(a.target, a.shell)
    bad = [i for i in items if not i[1]]
    if a.check:
        for n, ok, why, *_ in items: print(f'{"✅" if ok else "❌"} {n}：{why}')
        return 75 if bad else 0
    if not (a.source or a.from_extract) or not a.out: ap.error('要 <原件>（或 --from-extract <解包目录>）与 --out')
    if WIN:   # 工作区走短根：之后的路径（工具参数、bash、dotnet、TEMP）都短；深路径的玩家数据目录不再踩 MAX_PATH
        # 作业层的工具缓存根（<库>/tool-cache，游戏库结构 P3 起在游戏库里）也走短根：直连 / 翻译缓存（S2A_RUN_ROOT）、cache/* 都经环境变量传下去，
        #   库在深目录时原先只有工作区短、缓存仍是长路径（v0.3.0 win_cases deep 直连库抽取失败）
        tool = os.path.dirname(os.path.abspath(os.environ['S2A_RUN_ROOT'])) if os.environ.get('S2A_RUN_ROOT') else None
        mapped = shortroot.enter(a.out, *([a.from_extract] if a.from_extract else []), *([tool] if tool else []))
        if mapped:
            a.out = mapped[os.path.abspath(a.out)]
            if a.from_extract: a.from_extract = mapped[os.path.abspath(a.from_extract)]
            # 作业层经环境变量传下来的缓存路径（S2A_RUN_ROOT、cache/*、跟着存放位置走的 S2A_DIRECT_CACHE…）落在哪个入口下就换成经它访问
            for row in os.environ.get(shortroot.ENV, '').splitlines():
                long_root, _, short_root = row.partition('\t')
                if long_root and short_root: shortroot.remap_env(os.environ, long_root, short_root)
    run = Run(a.out, a.events); t0 = time.time(); cur = None
    work_temp(run.out)
    share_walk_dir(a.out)
    # 自检只当提示、不拦（不许堵门，11-14 诊断#9478d5：一项判缺就整单退 75，什么都不做）：照做，真用到缺的那件的那步才失败、报那步的原话；
    #   Metal 不是必需的：没有就这次不带着色器库（direct 里跳过），游戏里首次遇到的画面现编
    for n, _, why, *_ in bad: run.say(f'【黄】环境自检说缺 {n}：{why}（照做，到要用它的那步再看）')
    try:
        x, tid, src_dir = from_extract(run, a.from_extract) if a.from_extract else unpack(run, a.source, a.title_id)
        if a.rt_shaders:
            if a.from_extract: raise Fail('--rt-shaders 不和 --from-extract 同用（那是别人的解包目录，不往里写）：把转储放进解包目录的 rt_shaders/')
            run.say(f'现编转储 {put_rt(x, a.rt_shaders)} 支并进解包目录 rt_shaders/（内部验证包；转储是游戏内容、不分发）')
        if WIN: host_decoder_gate(run, x); glslc_gate(run, x)
        game = 't' + tid.lower()
        cur = stages(run, game, x, src_dir, own=not a.from_extract)   # 本单自己解的包（下次解包整目录重建）：播种整目录搬 RomFS；--from-extract 是别人的目录，照旧克隆
        early = Early(run, a, cur, game).start() if a.install and a.target == 'ios' else None
        dlib = direct(run, cur, a.target, a.jobs, tid)
        w = run.step('组工作根', lambda: product(run, cur, dlib))
        sub_programs(run, a, x, w, src_dir)
        if a.target == 'ios':
            p, title = ipa(run, w, game, a.shell, a.bundle_id, a.suffix if a.suffix is not None else ('Win' if a.install else ''))
            bid, gm = ipa_facts(p); pk = w / 'pkg' / 'pack'; files = [f for f in pk.rglob('*') if f.is_file()]
            run.say(f'🟢 {title}（{tid}）→ {p}（{p.stat().st_size // 1048576} MB）+ 资源包 {pk}；合计 {time.time() - t0:.0f} 秒')
            run.ev('result', ok=True, ipa=str(p), pack=str(pk), files=len(files), size=f'{(sum(f.stat().st_size for f in files) + p.stat().st_size) / 1048576:.0f}M',
                   build_id=bid, graphics_mode=gm, aoc_missing=aoc_missing(cur), elapsed=int(time.time() - t0))
            if a.install:
                if early:
                    er, ee = early.finish()
                    if ee: run.say(f'【黄】出包期间早装没成（{ee}），正式安装整包推'); run.ev('early', ok=False, msg=f'{type(ee).__name__}: {ee}' if isinstance(ee, Exception) else str(ee))
                    else: run.say(f'出包期间已先装 App、先推 {er["files"]} 个文件（{er.get("seconds", "?")} 秒，与直连库编译并行）'); run.ev('early', ok=True, **er)
                install(run, a, p, pk)
        else:
            run.say(f'🟢 {tid} Mac 目标产物根 → {w}（含 Mac 直连库）；合计 {time.time() - t0:.0f} 秒')
            run.ev('result', ok=True, root=str(w), aoc_missing=aoc_missing(cur), elapsed=int(time.time() - t0))
        return 0
    except Fail as e:
        run.say(f'【红】{e}'); run.ev('result', ok=False, msg=str(e)); return e.code
    except Exception as e:   # 没想到的异常也给一条结果（同 Mac evexit），再照常抛出看栈
        run.ev('result', ok=False, msg=f'一键出包没跑完就退出了（{type(e).__name__}: {e}）'); raise


if __name__ == '__main__':
    sys.exit(main())
