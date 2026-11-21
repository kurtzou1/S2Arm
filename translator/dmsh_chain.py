#!/usr/bin/env python3
# Library version V of the B shader library: one version for every game, which the host is compiled with (dm/gfx/nvn/dmsh_chain.h).
# S2Arm (10-30, 维护者: "d2r's exported package never had to be redone, only the host was rebuilt"): V names only the host <-> library interface, ABI below, and changes only
#   when the way the host reads a library changes (reflection json fields and their meaning, binding kinds, entry names, argument buffer conventions, the container format).
#   It used to be a digest of the translation tools themselves: any translator edit renamed every library directory, the host refused every packed library and every game
#   was rebuilt and repacked (a train window every 24 h to batch them). Translator changes are now carried per shader: the translation fingerprint xlate_fp() (the files below)
#   is part of every shader's cache key (dmsh_build.py shader_key), so an edit re-translates every shader, and the batch libraries are named and cut by MSL content
#   (dmsh_build.py unity_flush), so a shader whose MSL did not change hits the Metal cache: only shaders whose output really changed are compiled again.
#   ABI discipline: tests/dmsh_abi_test.sh checks that every reflection kind the build can emit is one the host reads (nvn_refl.m); a change of the reading convention bumps ABI.
# Translation fingerprint = sha256 of the contents of the following in-repo files + the translation options: this script, dmsh_build.py (the build orchestration),
# dmsh_ushare.py, dmsh_facts.py, the dmsh_xlate sources (Program.cs, csproj), the S2A.Dsh sources and its batch process (graphics/tools/direct/dsh), the iOS compile convention ios_metal.py, and the tool lock dmsh_chain.lock (measured fingerprints of the Ryujinx shader dll / spirv-cross / metal compiler).
# A game's own inputs are not part of V: its profile's shader tables and nvn_* / shader_* keys are in each shader's cache key (dmsh_build.py shader_key), so a change rebuilds the shaders it affects,
# and their digest (inputs below) stamps the library: <cache dir>/b-<V>/inputs.tsv says which game and which inputs it was built from. c1_full.tsv / cb_extent.tsv name V and that digest in their
# header (table_head), and the host takes them only when both match its library; build_ipa.sh packs a library only when its digest is the profile's.
# The build (dmsh_build.py) writes into <cache dir>/b-<V>/ and the reflection json records chain = V; at compile time the host takes V from dm/gfx/nvn/dmsh_chain.h, loads only from b-<V>/ and verifies each json.
# Usage: dmsh_chain.py                 print V (default options)
#       dmsh_chain.py --header        rewrite dm/gfx/nvn/dmsh_chain.h (run after changing any file listed above, and commit it with the change)
#       dmsh_chain.py --inputs        print the digest of the current game profile's inputs (DM_GAME), as b-<V>/inputs.tsv records it
#       dmsh_chain.py --check-tools   verify that the actual tools match the lock file; on mismatch print [RED] lines and exit 1
#       dmsh_chain.py --xfp           print the translation fingerprint xlate_fp() computed from this tree's sources
#       dmsh_chain.py --check-stamp D verify that library D's stamp names this tree's translator (tree_xfp) and tool lock; on mismatch print [RED] and exit 1
#       dmsh_chain.py --update-lock   rewrite the lock file from the actual tools (run after changing Ryujinx / spirv-cross / Xcode; committed to the repo)
# Environment: XLATE_DEBUG / XLATE_REDUCED (same meaning as in dmsh_build.py, default gs,cs / 1 since 11-07 (DebugMode on for geometry and compute only; debug was 1 before); non-default options yield a different V, which the host will not load)
import shutil, os, re, sys, json, hashlib, subprocess
DM_ROOT = os.environ.get('DM_ROOT') or os.path.expanduser('~/dm-work')   # Workspace root (game files, build outputs and run artifacts are all under it)
HERE = os.path.dirname(os.path.abspath(__file__)); GFX = os.path.join(os.path.dirname(HERE), 'graphics', 'nvn', 'gfx'); HOME = os.path.expanduser('~')
ROOT = os.path.normpath(os.path.join(GFX, '../../..'))   # repository root (graphics/nvn/gfx → .)
DSH_PROJ = os.path.join(ROOT, 'graphics/tools/direct/dsh/S2A.Dsh.csproj')
# 翻译器指纹输入只有一份：S2A.Dsh.csproj 的 DshXfpInput（11-02 维护者 / 出包线）。生产的翻译缓存键（dsh_batch ToolFingerprint 里的 DshChain.Xfp）由它在编译期算；
#   这里用 dotnet msbuild -getItem 取 MSBuild 自己展开的同一份清单、按同一算法（「仓库相对路径 \t sha256 \n」按路径排序拼起来再 sha256 取前 16 位）算，两边相等
#   （tests/xfp_single_source_test.sh）。改清单外的文件（dsh/batch/Build.cs 等编排、本文件、libnxgal / spirv-cross 源码）不改这个指纹：
#   库的内容另由 ToolFingerprint 的 LibFp（--dsx / --spvc 动态库各节内容）进键。11-02 前这里是一份手写的 FILES，收了 batch/*.cs 等，却不进任何生产键，
#   冷改动核查据它报「翻译指纹变」是虚报（docs/坑记录.md）
_XFP_FILES = None
def xfp_files():   # → 翻译器指纹输入的仓库相对路径（排好序）
    global _XFP_FILES
    if _XFP_FILES is None:
        dn = os.environ.get('DOTNET') or os.path.expanduser('~/.dotnet/dotnet')
        if not os.access(dn, os.X_OK): dn = shutil.which('dotnet') or 'dotnet'
        r = subprocess.run([dn, 'msbuild', DSH_PROJ, '-getItem:DshXfpInput'], capture_output=True, text=True, cwd=os.path.dirname(DSH_PROJ))
        if r.returncode != 0: sys.exit(f'[RED] dotnet msbuild -getItem:DshXfpInput failed: {(r.stdout + r.stderr).strip()[-300:]}')
        full = sorted({os.path.normpath(i['FullPath']) for i in json.loads(r.stdout)['Items']['DshXfpInput']})
        bad = [f for f in full if os.path.relpath(f, ROOT).startswith('..')]
        if bad: sys.exit(f'[RED] translation fingerprint inputs outside the repository: {bad[:3]}')
        _XFP_FILES = sorted(os.path.relpath(f, ROOT).replace(os.sep, '/') for f in full)
    return _XFP_FILES
INPUT_TABLES = ['shader_facts.tsv', 'shader_map.tsv', 'shader_map.tsv.conflicts.tsv', 'shader_pairs.tsv', 'bf_want.tsv', 'fout_want.tsv', 'se_want.tsv']   # in the game profile folder
LOCK = os.path.join(HERE, 'dmsh_chain.lock'); HEADER = os.path.join(GFX, 'nvn/dmsh_chain.h')
STAMP = 'inputs.tsv'   # in the library directory b-<V>/
# the translator defaults to the in-repo build that matches the lock file (a rebuilt dll has different fingerprints)
XLATE_DIR = os.path.dirname(os.environ.get('XLATE', os.path.join(HERE, 'dmsh_xlate_bin/dmsh_xlate')))

def options():
    d = os.environ.get('XLATE_DEBUG', 'gs,cs')   # 11-07 起缺省只几何、计算开 DebugMode（S2A.Dsh JobFor 同改）；'1' 全开、'0' 全关是另外的链版本
    return 'debug=%s reduced=%s' % (d if d in ('gs', 'gs,cs') else d != '0', os.environ.get('XLATE_REDUCED', '1') == '1')

ABI = 1   # host <-> library interface version (see the file head): bump it, and only it, when the host's way of reading a library changes

def xlate_fp(read=None):   # 翻译器指纹 = 生产翻译缓存键里的 DshChain.Xfp（同一份清单、同一算法）；read(仓库相对路径) → 字节，缺省读工作树
    read = read or (lambda f: open(os.path.join(ROOT, f), 'rb').read())
    rows = sorted(f + '\t' + hashlib.sha256(read(f)).hexdigest() + '\n' for f in xfp_files())
    return hashlib.sha256(''.join(rows).encode()).hexdigest()[:16]

def version(abi=None):   # V: the library version the host loads, from ABI alone (12 hex digits: the library directory b-<V>, the container head, each json's chain)
    return hashlib.sha256(f'dmsh-abi-{ABI if abi is None else abi} {options()}'.encode()).hexdigest()[:12]

def load_game():   # the current game profile (DM_GAME), only for what needs one: the version itself does not
    sys.path.insert(0, os.path.join(GFX, '../games')); import game
    return game.load()

def profile_rows(g):   # the profile keys that change how a shader is built (nvn_*, shader_*)
    return ''.join(f'{k}\t{chr(9).join(v)}\n' for k, v in g.rows if k.startswith(('nvn_', 'shader_'))).encode()

def inputs(g):
    """Digest of a game profile's inputs to its shader library: the shader tables (a missing one counts as such) and the nvn_* / shader_* keys"""
    h = hashlib.sha256()
    for f in INPUT_TABLES:
        p = g.table(f)
        h.update(f'game/{f}'.encode() + b'\0' + (p.read_bytes() if p.exists() else b'missing') + b'\0')
    h.update(profile_rows(g))
    return h.hexdigest()[:12]

def read_stamp(lib):   # {'game': title ID, 'inputs': digest} of a library directory; {} when it has none
    try: return dict(l.rstrip('\n').split('\t', 1) for l in open(os.path.join(lib, STAMP)) if '\t' in l and not l.startswith('#'))
    except OSError: return {}

def write_stamp(lib, game_id, digest):
    tmp = os.path.join(lib, STAMP + '.tmp')
    with open(tmp, 'w', newline='\n') as f: f.write(f'# the game and the profile inputs this library was built from (dm/gfx/tools/dmsh_chain.py inputs)\ngame\t{game_id}\ninputs\t{digest}\n')
    os.replace(tmp, os.path.join(lib, STAMP))

def lock_fp(): return hashlib.sha256(open(LOCK, 'rb').read()).hexdigest()[:16]   # 锁文件字节摘要，同 Build.cs WriteStamp 的 lock 行

def tree_xfp():   # 本树的翻译器指纹：启动器内置 dsh_batch 在用时取发版按同一份 App 内源码算好的记录（dsh_batch.prebuilt_xfp；玩家机没有 .NET SDK，xlate_fp 的
    #   dotnet msbuild 展不开清单），否则现算 xlate_fp()。两条路都是「本树源码的指纹」，不取出库程序自报的
    sys.path.insert(0, HERE); import dsh_batch
    return dsh_batch.prebuilt_xfp() or xlate_fp()

def stamp_mismatch(lib, tree=None):   # 库印章里的翻译器指纹 / 锁摘要与本树（tree = (xfp, lock)，缺省 tree_xfp() / lock_fp()）不同 → 说明文字；相同 → ''
    #   11-06 时之笛第 49 版：出库命令经 DSH_BATCH_CMD 换成Windows 出包机上按旧树编的程序，键里的翻译器指纹是旧的，全命中旧缓存，翻译器改动没进包而出库报绿；只核产物才不靠调用链每层守规矩
    s = read_stamp(lib); t = tree or (tree_xfp(), lock_fp()); g = (s.get('xfp', 'none'), s.get('lock', 'none'))
    if g == t: return ''
    return (f'the library in {lib} was built by translator {g[0]} / tool lock {g[1]}, this tree is {t[0]} / {t[1]}'
            + (' (its stamp has no xfp / lock lines: an old dsh_batch built it)' if 'xfp' not in s else '') + ': rebuild the dsh_batch that DSH_BATCH_CMD points to from this tree')

def table_head(lib):   # the header c1_full.tsv / cb_extent.tsv start with: the library's chain version and its inputs ("none" when it has no stamp, which nothing takes)
    return f'# chain {os.path.basename(os.path.normpath(lib))} inputs {read_stamp(lib).get("inputs", "none")}'

def sha16(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()[:16]

def spirv_cross_identity(path):
    """spirv-cross by its release version, the thing that decides the MSL it writes, not by its bytes (S2Arm 10-31, #1133): the binary carries no version, only its build time,
    and its bytes differ per build of the same release (a Tahoe bottle, a source build on Sequoia) and change when S2Arm.app re-signs its copy (codesign --force --sign -).
    The version comes from, in order: the S2Arm.app runtime's versions.json beside its bin/ (launchers/macos/bundle_runtime.py writes spirvCross = `brew list --versions spirv-cross`
    of the builder), then a Homebrew Cellar path (.../Cellar/spirv-cross/<version>/bin/spirv-cross). Neither: 'unknown: <path>', which no lock holds.
    10-31 check: 1.4.357.0 and 1.4.363.0 wrote byte-identical MSL for 435 Xenoblade 3 / Monster Hunter Rise shaders, so the output alone cannot tell releases apart either"""
    if not path: return 'missing'
    real = os.path.realpath(path); bindir = os.path.dirname(real)
    vj = os.path.join(os.path.dirname(bindir), 'versions.json')
    if os.path.basename(bindir) == 'bin' and os.path.isfile(vj):
        try: v = (json.load(open(vj)).get('spirvCross') or '').split()
        except (OSError, ValueError, AttributeError): v = []
        if len(v) == 2 and v[0] == 'spirv-cross': return v[1]   # one installed version: the one bundled (several: the bundle cannot say which, unknown)
    m = re.search(r'/Cellar/spirv-cross/([^/]+)/bin/spirv-cross$', real)
    return m.group(1) if m else 'unknown: ' + real

def tools_now():
    """Actual tool fingerprints: translator dll (including the Ryujinx shader library), spirv-cross, metal compiler (macOS / iOS)"""
    t = {}
    for dll in (
        "dmsh_xlate.dll",
        "Ryujinx.Graphics.Shader.dll",
        "Ryujinx.Common.dll",
        "S2Arm.Gfx.Widen.Shader.dll",
    ):
        t[dll] = sha16(os.path.join(XLATE_DIR, dll))  # the last: graphics/widen/shader analyses
    if os.environ.get("S2A_PREBUILT_TOOLS"):
        # App 出包作业里没有 .NET 运行时（工具全为预编原生件），执行不了 dll --source-sha：读 publish.sh 随二进制写的 .source_sha（值 = 仓库源码算出的 xlate_source_sha，
        #   发布侧与 tests/dmsh_lock_consistency_test.sh 核；读不出留空 → 对不上照常报红）
        try:
            t["xlate_source"] = open(os.path.join(XLATE_DIR, ".source_sha")).read().strip()
        except OSError:
            t["xlate_source"] = ""
    else:
        # 经 dotnet 跑托管的 dmsh_xlate.dll，不执行同目录只有 arm64 的启动壳 dmsh_xlate（11-01：Intel Mac 命令行出 iPhone 包在 README 支持范围内，启动壳在 Intel 上 Bad CPU type）
        dn = os.environ.get("DOTNET") or (
            os.path.expanduser("~/.dotnet/dotnet")
            if os.path.exists(os.path.expanduser("~/.dotnet/dotnet"))
            else shutil.which("dotnet")
        )
        t["xlate_source"] = subprocess.run(
            [dn or "dotnet", os.path.join(XLATE_DIR, "dmsh_xlate.dll"), "--source-sha"],
            capture_output=True,
            text=True,
        ).stdout.strip()
    sc = shutil.which("spirv-cross") or ""  # 不调 which 命令：Windows 没有（#1100 W6）
    t["spirv-cross"] = spirv_cross_identity(sc)  # its release version (see spirv_cross_identity)
    # Windows（#1100 W6）：没有 xcrun，读苹果官方 Metal Developer Tools for Windows 的 metal.exe（同 Build.cs Metal.WinBin：S2A_METAL_BIN，缺省 Program Files 下）；
    #   版本与锁（Mac 的 Xcode）不同时由 own_compilers 打 note 放行，与换 Xcode 同一口径（维护者 11-03 #788：编译器版本只 note、不进链号）
    win = os.environ.get('S2A_METAL_BIN') or r'C:\Program Files\Metal Developer Tools\bin' if os.name == 'nt' else None
    for sdk in ('macosx', 'iphoneos'):
        cmd = [os.path.join(win, 'metal.exe'), '--version'] if win else ['xcrun', '-sdk', sdk, 'metal', '--version']
        try: out = subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines()[0:1]
        except OSError: out = []
        t['metal_' + sdk] = (out or ['missing'])[0]
    return t

XLATE_SOURCES = ('Program.cs', 'dmsh_xlate.csproj', '../../graphics/widen/SpirvCbufUseText.cs')   # = the csproj's src0..src2

# S2Arm: the translator's library sources, as the csproj's S2ALibSourceManifest lists them (label, root, [(project, patterns)]): the Ryujinx shader translator of compat/tree
#   (the one the generic mode and S2A.Dsh build from source) and graphics/widen/shader. '**/' = any depth, obj / bin folders and '._' files left out
LIB_SOURCES = (('ryu', os.path.join(HERE, '../compat/tree/src'), (('Ryujinx.Graphics.Shader', ('**/*.cs', '**/*.glsl', '*.csproj')), ('Ryujinx.Common', ('**/*.cs', '*.csproj')),
                                                                           ('Spv.Generator', ('**/*.cs', '*.csproj')))),
               ('widen', os.path.join(HERE, '../graphics/widen/shader'), (('', ('**/*.cs', '*.csproj')),)))

def lib_source_rows():   # → sorted 'label/relative path<TAB>SHA-256 in upper-case hex', the same rows --source-sha makes from src3
    rows = []
    for label, root, projects in LIB_SOURCES:
        for proj, pats in projects:
            base = os.path.join(root, proj)
            for d, dirs, files in os.walk(base):
                dirs[:] = [x for x in dirs if x not in ('obj', 'bin')]
                rel_d = os.path.relpath(d, base)
                for f in files:
                    if f.startswith('._'): continue
                    if not any((p.startswith('**/') and f.endswith(p[4:])) or (rel_d == '.' and f.endswith(p[1:])) for p in pats): continue
                    full = os.path.join(d, f); rel = os.path.relpath(full, root).replace(os.sep, '/')
                    rows.append(label + '/' + rel + '\t' + hashlib.sha256(open(full, 'rb').read()).hexdigest().upper())
    return sorted(rows)

def xlate_source_sha():   # same convention as dmsh_xlate --source-sha: the embedded sources concatenated in that order, then the library source rows joined by \n
    return hashlib.sha256(b''.join(open(os.path.join(HERE, 'dmsh_xlate', f), 'rb').read() for f in XLATE_SOURCES) + '\n'.join(lib_source_rows()).encode()).hexdigest()[:16]

def check_tools():
    want = dict(l.rstrip('\n').split('\t', 1) for l in open(LOCK) if '\t' in l and not l.startswith('#'))
    now = tools_now(); bad = [f'{k}: lock {want.get(k)} / actual {v}' for k, v in now.items() if want.get(k) != v]
    if now['xlate_source'] != xlate_source_sha(): bad.append(f'the translator was not built from the in-repo source: embedded source {now["xlate_source"]} / in repo {xlate_source_sha()} (rebuild dmsh_xlate)')
    return bad

def own_compilers(bad):
    """check_tools 的不符项 → (放行的, 照停的)：只有 Metal 编译器（macOS / iOS）版本与锁不同才放行（Metal 编译缓存按编译器身份分键，换 Xcode 只是重编，
    不会复用别的编译器编的库，见 t_unity.py ⑦）；编译器缺失、翻译器 / spirv-cross / 翻译器源码不符照停"""
    own = [b for b in bad if re.match(r'(metal_macosx|metal_iphoneos): lock .* / actual (?!missing$)', b)]
    return own, [b for b in bad if b not in own]

def header_text(v):
    return (f'// Generated file (dm/gfx/tools/dmsh_chain.py --header): the B shader library version this source tree expects (default options), one for every game;\n'
            f'// the host loads only <library dir>/b-<V>/. V follows the host <-> library interface version (dmsh_chain.py ABI), not the translator: run --header after bumping ABI\n'
            f'#define DMSH_CHAIN "{v}"\n#define DMSH_ABI {ABI}\n')

if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['--update-lock']:
        t = tools_now()
        if t['xlate_source'] != xlate_source_sha(): sys.exit(f'[RED] the translator was not built from the in-repo source (embedded {t["xlate_source"]} / in repo {xlate_source_sha()}): rebuild dmsh_xlate first')
        open(LOCK, 'w').write('# Translation chain tool fingerprints (written by dmsh_chain.py --update-lock; regenerate after changing tools and commit it)\n' + ''.join(f'{k}\t{v}\n' for k, v in t.items()))
        print('wrote', LOCK)
    elif a == ['--check-tools']:
        bad = check_tools()
        for b in bad: print('[RED] translation chain tools do not match the lock file: ' + b)
        sys.exit(1 if bad else 0)
    elif a == ['--header']:
        open(HEADER, 'w').write(header_text(version()))
        print(version())
    elif a == ['--inputs']: print(inputs(load_game()))
    elif len(a) == 2 and a[0] == '--build-env':   # 整份直连出库（C# dsh_batch build）要的：先核工具与头文件，再给「链号 \t 程序号 \t 配置档输入摘要」，配置档里改翻译的行写进 a[1]
        # Metal 编译器（macOS / iOS）与锁不同只打一行 note 放行（同迁移前 own_compilers.py）：Metal 编译缓存按编译器身份分键，换 Xcode 只是重编；编译器缺失、翻译器 / spirv-cross 不符照旧停。
        #   11-02 C# 迁移删了 own_compilers.py，这里走了严格核对：Xcode 与锁不同的机器（玩家、Spare-host 升级、beta）每款出库前就退出
        own, bad = own_compilers(check_tools())
        if own and not bad: print("note: built with this Mac's compilers, not the ones the shaders were tested with (dmsh_chain.lock): " + '; '.join(own), file=sys.stderr)
        if bad: sys.exit('\n'.join('[RED] translation chain tools do not match the lock file: ' + b for b in bad) + '\n(if the tools changed, run dmsh_chain.py --update-lock and commit the lock file; if the translator just was not rebuilt, rebuild it)')
        v = version()
        if f'"{v}"' not in open(HEADER).read(): sys.exit(f'[RED] {HEADER} does not hold the current translation chain version {v}: run dmsh_chain.py --header first and commit it (otherwise the host cannot find these libraries)')
        g = load_game()
        if not g.table('shader_facts.tsv').exists(): sys.exit(f'[RED] no answer table {g.table("shader_facts.tsv")} (it comes with the game profile; an empty table = every query answered with defaults)')
        open(a[1], 'wb').write(profile_rows(g)); print(f'{v}\t{g.id}\t{inputs(g)}')
    elif len(a) == 2 and a[0] == '--check-stamp':   # 出库后核库印章（Build.cs WriteStamp 记的 xfp / lock）与本树的翻译器指纹 / 锁文件摘要相同：不同或没记报红退 1（direct_lib.py 出库后调）
        bad = stamp_mismatch(a[1])
        if bad: sys.exit('[RED] ' + bad)
    elif a == ['--xfp']: print(xlate_fp())   # 按本树源码现算的翻译器指纹（发版 bundle_engine.py 写内置件 .xfp 用）
    elif not a: print(version())
    else: sys.exit(__doc__ if __doc__ else 'usage: see the file header')
