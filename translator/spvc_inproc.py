#!/usr/bin/env python3
# spirv-cross 命令行在进程内跑（S2Arm 11-01 出包线）：直连出库的翻译段每支着色器起一次 spirv-cross 进程，异度3 600 支单线程分片 706 次共 6.22 秒、
#   光起进程 3.77 秒（比它干活还多）。这里把同一份命令行（graphics/third_party/spirv_cross/main.cpp，vulkan-sdk-1.4.363.0 标签原样，= 链锁 dmsh_chain.lock 的 spirv-cross 1.4.363.0）
#   与库源码编成一个动态库，按原参数在进程内调用：走命令行同一段代码，输出与命令行逐字节相同（spvc_cli/shim.h：exit 改抛异常、stderr 按线程收集）。
# 库按「源码 + 胶水 + 编译参数 + 编译器版本」的摘要编到 <仓库>/build/spvc_cli/<摘要>/，首次约 10 秒（文件锁，多进程只编一次）；Spare-host 同样从仓库源码编，不依赖 Homebrew。
# run(args) → subprocess.CompletedProcess(args, 返回码, stdout, stderr)：args 不含程序名；没给 --output 时补一个临时文件、读回作 stdout（同命令行打印到 stdout）
import ctypes, hashlib, os, shutil, subprocess, sys, tempfile, threading
WIN = sys.platform == 'win32'   # Windows 出包机（#1100 W6）：LLVM clang++ 编 libspvc_cli.dll，胶水换 spvc_cli/win/shim.cpp（没有 fmemopen / open_memstream），输出身份不变
import xlock   # 同目录：跨平台文件锁
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '..'))
SRC = os.path.join(ROOT, 'graphics', 'third_party', 'spirv_cross'); SHIM = os.path.join(HERE, 'spvc_cli')
UNITS = ['spirv_cross', 'spirv_cfg', 'spirv_parser', 'spirv_cross_parsed_ir', 'spirv_glsl', 'spirv_msl', 'spirv_hlsl', 'spirv_cpp', 'spirv_reflect', 'spirv_cross_util']
FLAGS = ['-O2', '-std=c++14', '-fPIC']   # 进输出身份；Windows 编时去掉 -fPIC（该目标不认），见 _cxx
LIB = 'libspvc_cli.dll' if WIN else 'libspvc_cli.dylib'


def _cxx():   # 编译器命令前缀：Mac 走 xcrun；Windows 走 PATH 上的 clang++（或 S2A_CXX）
    return [os.environ.get('S2A_CXX') or 'clang++'] if WIN else ['xcrun', 'clang++']
_lib, _id, _lk = None, None, threading.Lock()


def identity():
    """输出的身份：源码、胶水、编译参数的摘要（进工具指纹，dmsh_build.py tool_fingerprint）。不含编译器版本：MSL 只由源码与参数定，
    11-01 实测 brew 编的命令行与本机 clang 编的库 26618/26618 逐字节一致；带上编译器版本则本机（clang-2100.1.1.101）与 Spare-host（clang-2100.3.34.2）
    全部着色器键不同、缓存跨机不通（跨机实测 30035/30035 键不同）"""
    global _id
    if _id is None:
        h = hashlib.sha256()
        # 「._」开头的是 macOS 在 exFAT 等盘上给每个文件配的 AppleDouble 附属文件（存扩展属性），不是源码：算进来同一份源码换个盘身份就变
        for d, names in ((SRC, sorted(os.listdir(SRC))), (SHIM, sorted(os.listdir(SHIM)))):
            for n in names:
                p = os.path.join(d, n)
                if os.path.isfile(p) and n.endswith(('.cpp', '.hpp', '.h')) and not n.startswith('._'): h.update(n.encode() + b'\0' + open(p, 'rb').read() + b'\0')
        h.update(' '.join(FLAGS).encode())
        _id = h.hexdigest()[:16]
    return _id


def _build_id():   # 编好的库放哪：输出身份 + 编译器版本 + Windows 胶水（换了工具链 / 胶水就重编库，但不改缓存键）
    win = open(os.path.join(SHIM, 'win', 'shim.cpp'), 'rb').read() if WIN else b''   # 11-05：win/shim.cpp 不进输出身份，原先改了它旧库照用
    return hashlib.sha256((identity() + '\0' + subprocess.run([*_cxx(), '--version'], capture_output=True, text=True).stdout).encode() + b'\0' + win).hexdigest()[:16]


def _own_objects(tmp, units):
    """tmp 里本次编出的 <单元>.o，按目录列出的顺序；目录里别的文件（如 exFAT 上的 AppleDouble「._<名>.o」）不收"""
    own = {u + '.o' for u in units}
    return [os.path.join(tmp, f) for f in os.listdir(tmp) if f in own]


def _build(out):
    tmp = tempfile.mkdtemp(prefix='spvc_', dir=os.path.dirname(out))
    try:
        # Windows 另带 -fmacro-prefix-map：MSVC 运行库的 assert 把 __FILE__ 编进库，检出路径不同字节就不同（见下 /Brepro 注）；不进 FLAGS（FLAGS 进输出身份，Mac 键不动）
        cc = [*_cxx(), *[f for f in FLAGS if not (WIN and f == '-fPIC')], *(['-fmacro-prefix-map=' + ROOT + '=.'] if WIN else []), '-I' + SRC]
        procs = [subprocess.Popen([*cc, '-c', os.path.join(SRC, u + '.cpp'), '-o', os.path.join(tmp, u + '.o')]) for u in UNITS]
        procs.append(subprocess.Popen([*cc, '-I' + SHIM, '-include', os.path.join(SHIM, 'shim.h'), '-c', os.path.join(SRC, 'main.cpp'), '-o', os.path.join(tmp, 'main.o')]))
        procs.append(subprocess.Popen([*cc, '-c', os.path.join(SHIM, 'win' if WIN else '', 'shim.cpp'), '-o', os.path.join(tmp, 'shim.o')]))
        if any(p.wait() for p in procs): raise RuntimeError('spirv-cross 进程内库编译失败（见上方编译器输出）')
        lib = os.path.join(tmp, LIB)
        # Windows 链接带 /Brepro：库整文件哈希进翻译键（dsh/batch/Store.cs ToolLib.Fp，PE 不拆节），lld-link 缺省写链接时刻，同源每编一次字节不同、
        #   Windows 出包机每份新检出全部着色器翻译缓存作废；/Brepro 时间戳取内容哈希。Mac 照旧（ToolLib.Fp 按 Mach-O 节内容算，不看文件头）
        # 只链接上面自己编出的目标文件。原先按「目录里所有 .o」收：引擎在 exFAT 盘上时 macOS 给每个 .o 另写一个 AppleDouble「._<名>.o」，
        #   一并交给 ld 报 unknown file type，直连库每次都出不来（#1529）。仍按目录列出的顺序链接：APFS 上这个顺序固定，库各节内容与原先相同
        subprocess.run([*_cxx(), *(['-shared', '-Wl,/Brepro'] if WIN else ['-dynamiclib']), '-o', lib, *_own_objects(tmp, [*UNITS, 'main', 'shim'])], check=True)
        os.replace(lib, out)
    finally: shutil.rmtree(tmp, ignore_errors=True)


def prebuilt_id():   # 预编件身份：输出身份 + Windows 胶水（同 _build_id，但不含编译器版本：玩家机上没有编译器可问）
    win = open(os.path.join(SHIM, 'win', 'shim.cpp'), 'rb').read() if WIN else b''
    return hashlib.sha256(identity().encode() + b'\0' + win).hexdigest()[:16]


def prebuilt(*rel):
    """启动器随发版预编的一份（S2A_PREBUILT_TOOLS/spvc/，launchers/windows/bundle_prepare_win.py 编，.src_digest 记 prebuilt_id）：身份相同且文件在 → 路径；否则 None（照旧现编）"""
    d = os.environ.get('S2A_PREBUILT_TOOLS')
    if not d: return None
    p = os.path.join(d, 'spvc')
    try: same = open(os.path.join(p, '.src_digest')).read().strip() == prebuilt_id()
    except OSError: return None
    q = os.path.join(p, *rel)
    return q if same and os.path.isfile(q) else None


def lib_path():   # 库在哪（首次按需编）：本进程 ctypes 载入，出包 C# 批量进程（dsh/batch）也载这一份
    pre = prebuilt(LIB)
    if pre: return pre
    d = os.path.join(ROOT, 'build', 'spvc_cli', _build_id()); os.makedirs(d, exist_ok=True); p = os.path.join(d, LIB)
    if not os.path.exists(p):
        with xlock.held(os.path.join(d, '.lock')):
            if not os.path.exists(p): _build(p)
    return p


CLI = 'spirv-cross.exe' if WIN else 'spirv-cross'


def upstream_msl():
    """仓库 spirv_msl.cpp 换回上游原文的那一段（「// "fadd" intrinsic support」起到 FMul 一族结束）→ 上游原样的源码文本。
    本仓改动段找不到（升级了上游 / 改动挪了位置）就报错，不悄悄编出带改动的命令行"""
    import re
    s = open(os.path.join(SRC, 'spirv_msl.cpp'), encoding='utf-8', newline='').read()
    a = s.find('\t\t// "fadd" intrinsic support')
    m = s.find('case SPVFuncImplFMul:', a)
    nxt = re.search(r'\n\t\t(// [^\n]*\n\t\t)*case SPVFuncImpl', s[m + 10:]) if a >= 0 and m >= 0 else None
    if not nxt or 'S2A:' not in s[a:m]:
        raise RuntimeError('spirv_msl.cpp 里找不到本仓改动段（S2A: NoContraction），命令行版换不回上游原文：核 spvc_cli/msl_upstream_helpers.txt')
    up = open(os.path.join(SHIM, 'msl_upstream_helpers.txt'), encoding='utf-8', newline='').read()
    return s[:a] + up + s[m + 10 + nxt.start() + 1:]


def cli_path(upstream=True):
    """命令行 spirv-cross（Windows 出包机，#1100 W6）：没有 Homebrew，用同一份仓库源码（vulkan-sdk 标签原样，= 链锁版本）编成
    <仓库>/build/spvc_cli/<编库摘要>/cli/bin/spirv-cross.exe，旁边写 versions.json（spirvCross = 「spirv-cross <版本>」，版本取 spvc_cli/gitversion.h 的标签），
    dmsh_chain.spirv_cross_identity 按它认版本（同 S2Arm.app 运行时目录的规矩）。Windows 上预包含 spvc_cli/win/cli.h，输出按二进制写、与 Mac 逐字节同。
    Mac / Linux 照旧用系统装的 spirv-cross，不走这里。
    命令行版输出必须是上游原样（链锁 spirv-cross 一行两端同为上游版本号、Mac 用 Homebrew 原版）：仓库源码里 spirv_msl.cpp 有一处本仓改动
    （7cfd7be8f NoContraction 辅助函数内联，只给进程内库用、按 identity() 另有身份），编命令行时在临时副本里把那一段换回上游原文
    （spvc_cli/msl_upstream_helpers.txt），versions.json 写的上游版本号才是实话（11-16：此前 Windows 命令行带着改动却写上游号，下游据此当原版，6927 支里 2984 支不同）
    upstream=False 只给对拍单测（graphics/tools/direct/tests/t_dsh.sh）：用与进程内库逐字相同的仓库源码编，两边比的才是翻译器而不是那处改动；
    不取预编件（预编的是上游版），另起构建目录（-inproc 后缀），不进随包"""
    import json, re
    pre = prebuilt('cli', 'bin', CLI) if upstream else None   # 预编的同布局（cli/bin/spirv-cross.exe + cli/versions.json）
    if pre: return pre
    d = os.path.join(ROOT, 'build', 'spvc_cli', _build_id() + ('-upstream' if upstream else '-inproc'), 'cli'); b = os.path.join(d, 'bin'); p = os.path.join(b, CLI)
    if os.path.exists(p): return p
    os.makedirs(b, exist_ok=True)
    with xlock.held(os.path.join(d, '.lock')):
        if os.path.exists(p): return p
        m = re.search(r'vulkan-sdk-(\S+?)[ "]', open(os.path.join(SHIM, 'gitversion.h'), encoding='utf-8').read())
        if not m: raise RuntimeError('spvc_cli/gitversion.h 里读不出 vulkan-sdk 版本标签')
        tmp = tempfile.mkdtemp(prefix='spvcli_', dir=d)
        try:
            cc = [*_cxx(), *[f for f in FLAGS if f != '-fPIC'], '-I' + SRC, '-I' + SHIM]
            pre = ['-include', os.path.join(SHIM, 'win', 'cli.h')] if WIN else []
            msl = os.path.join(tmp, 'spirv_msl.cpp')
            with open(msl, 'w', encoding='utf-8', newline='') as f: f.write(upstream_msl() if upstream else open(os.path.join(SRC, 'spirv_msl.cpp'), encoding='utf-8', newline='').read())
            procs = [subprocess.Popen([*cc, '-c', msl if u == 'spirv_msl' else os.path.join(SRC, u + '.cpp'), '-o', os.path.join(tmp, u + '.o')]) for u in UNITS]
            procs.append(subprocess.Popen([*cc, *pre, '-c', os.path.join(SRC, 'main.cpp'), '-o', os.path.join(tmp, 'main.o')]))
            if any(x.wait() for x in procs): raise RuntimeError('spirv-cross 命令行编译失败（见上方编译器输出）')
            exe = os.path.join(tmp, CLI)
            subprocess.run([*_cxx(), '-o', exe, *_own_objects(tmp, [*UNITS, 'main'])], check=True)
            with open(os.path.join(d, 'versions.json'), 'w', encoding='utf-8', newline='\n') as f: json.dump({'spirvCross': 'spirv-cross ' + m.group(1)}, f)
            os.replace(exe, p)
        finally: shutil.rmtree(tmp, ignore_errors=True)
    return p


def _load():
    global _lib
    with _lk:
        if _lib is None:
            lib = ctypes.CDLL(lib_path())
            lib.spvc_cli_run.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
            lib.spvc_cli_run.restype = ctypes.c_int
            lib.spvc_cli_free.argtypes = [ctypes.c_void_p]
            _lib = lib
    return _lib


def run(args):
    lib = _load(); args = [str(a) for a in args]; tmp = None
    if '--output' not in args:
        fd, tmp = tempfile.mkstemp(suffix='.out'); os.close(fd); args_ = args + ['--output', tmp]
    else: args_ = args
    a = [b'spirv-cross'] + [x.encode() for x in args_]; arr = (ctypes.c_char_p * len(a))(*a)
    err, n = ctypes.c_void_p(), ctypes.c_size_t()
    try:
        rc = lib.spvc_cli_run(len(a), arr, ctypes.byref(err), ctypes.byref(n))   # ctypes 调用期间放开 GIL，分片里的线程可并行
        e = ctypes.string_at(err.value, n.value).decode('utf-8', 'replace') if err.value else ''
        if err.value: lib.spvc_cli_free(err)
        out = ''
        if tmp:
            with open(tmp, encoding='utf-8', errors='replace') as f: out = f.read() if rc == 0 else ''
    finally:
        if tmp: os.unlink(tmp)
    return subprocess.CompletedProcess(['spirv-cross', *args], rc, out, e)


if __name__ == '__main__':   # spvc_inproc.py lib | cli：打印库 / 命令行路径（首次按需编；direct_lib.py 在 Windows 上把命令行目录放进 PATH）
    import sys as _s
    if _s.argv[1:] not in (['lib'], ['cli']): _s.exit('用法：spvc_inproc.py lib | cli')
    print(lib_path() if _s.argv[1] == 'lib' else cli_path())
