#!/usr/bin/env python3
"""Collect a relocatable runtime on an Apple Silicon release builder.

Adapted from LumaDock (MIT; README.md).
Python, the SPIRV tools, zstd and bash come from runtime_sources.py (pinned sources, built for the app's minimum macOS); the builder's Homebrew is not copied.
bash 5 ships in Runtime/bin and comes first on the jobs' PATH: engine scripts are written and gated on bash 5; macOS /bin/bash 3.2 lacks BASHPID etc.
(10-25 launcher Hades run: EXIT traps failed with 'BASHPID: unbound variable').
bash is an aggregated GPL-3.0 program (separate process, not linked). Its COPYING (from the pinned source) and the source offer are copied into Runtime/licenses.
timeout is the repository's own perl tools/bin/timeout (Apache-2.0; macOS ships perl), not GNU coreutils — the same one tools/toolchain.sh puts first on PATH.
spirv-cross / glslangValidator build the direct shader library of Vulkan / OpenGL games (graphics/tools/direct/direct_lib.py; Hades is Vulkan).
The bundled C rewriter (Runtime/bin/s2a-rewrite) also needs CMake 3.18+, a C compiler and
the pinned sources from `python3 runtime/rewriter/prepare_deps.py build/rewriter-deps`
(or S2A_REWRITER_DEPS pointing at a prepared directory); the build never downloads.
Players do not install these dependencies. Paths are discovered automatically.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
from runtime_audit import SYSTEM_PATHS, rpaths, verify_portable_runtime
import runtime_sources
import sys
sys.path.insert(0, str(ROOT/'launchers/shared'))
import runtime_cache
sys.path.insert(0, str(ROOT))   # 按包导入：不把 pack/ 放进模块路径（pack/pack.py 会顶替 pack 包，build_app → bundle_engine 取壳编号 from pack.shell 即红）
from pack import rewriter
# Runtime/bin 自带的命令行工具（Homebrew 包名, 命令名）：作业 PATH 只有 Runtime + 系统目录；build_app.py 缺哪个就重打运行环境，tests/userenv_test.sh 按这张表核出包链要的命令
TOOLS = [('spirv-tools','spirv-as'),('spirv-tools','spirv-val'),('s2a-timeout','timeout'),('zstd','zstd'),('bash','bash'),('spirv-cross','spirv-cross'),('glslang','glslangValidator')]


def toolchain_identity():
    """编随包程序的工具链：SDK 版本与 clang 版本。SDK 决定哪些系统函数被弱引用（11-28 bash 的 strchrnul），换 Xcode 要重编。"""
    sdk = output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
    clang = output(['xcrun', 'clang', '--version']).splitlines()[0]
    return f'sdk {sdk}; {clang}'


def runtime_deps_fingerprint():
    """What this tree puts in Runtime. build_app refuses to reuse a directory whose copy differs.

    Every input counts (11-28: Homebrew-copied bash was not in here, so a years-old copy kept being reused and a cold cache picked up
    a macOS 26 bottle): this file itself (what is copied and how), every pinned download (sha256 from runtime_sources.downloads()),
    the deployment target, the toolchain (SDK / clang), requirements-runtime.txt (no oead), the TOOLS providers
    (timeout is tools/bin/timeout, not coreutils), the timeout source, and the bash source-offer text.
    Nothing is copied from the builder outside these: a Mach-O linking Homebrew / MacPorts / /usr/local is refused in build().
    """
    h = hashlib.sha256()
    h.update(b'runtime-deps-v2\n')
    h.update((ROOT / 'launchers/macos/runtime_sources.py').read_bytes())
    for url, sha, path in runtime_sources.downloads():
        h.update(f'{path.name} {sha}\n'.encode())
    h.update(runtime_sources.deployment_target().encode())
    h.update(toolchain_identity().encode())
    h.update((ROOT / 'launchers/macos/bundle_runtime.py').read_bytes())   # 收什么、怎么收也算：11-02 只改拷贝规则补 Pillow，旧 Runtime 指纹不变照旧复用、玩家仍缺
    h.update((ROOT / 'launchers/shared/pil_prune.py').read_bytes())   # 瘦身规则也算（#1570：只改它不换指纹，旧 Runtime 照旧缺画字）
    h.update((ROOT / 'launchers/macos/requirements-runtime.txt').read_bytes())
    h.update(b'\n')
    for formula, name in TOOLS:
        h.update(f'{formula}/{name}\n'.encode())
    h.update((ROOT / 'tools/bin/timeout').read_bytes())
    h.update(b'\n')
    h.update((ROOT / 'launchers/macos/runtime_source_offer.txt').read_bytes())
    return h.hexdigest()


def run(args, **kw):
    return subprocess.run([str(a) for a in args], check=True, **kw)


def output(args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def installed_versions_probe(names):
    """随包 Python 里跑的一段只读代码：把钉版清单的每一行都记进 versions.json。"""
    return ("import json,sys,importlib.metadata as m; names=" + json.dumps(list(names)) +
            "; print(json.dumps(dict(python=sys.version.split()[0], **{p:m.version(p) for p in names})))")


def cp(src, dst):
    src, dst = pathlib.Path(src), pathlib.Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=True, ignore=shutil.ignore_patterns(
            '__pycache__', 'test', 'tests', 'idlelib', 'tkinter', 'ensurepip', 'site-packages'))
    else:
        shutil.copy2(src, dst)


def build_timeout(dest):
    """Ship the repository's perl timeout (tools/bin/timeout). coreutils is GPL-3.0 and is not bundled; one implementation repo-wide."""
    shutil.copy2(ROOT / 'tools/bin/timeout', dest)
    os.chmod(dest, 0o755)


def macho(p):
    try:
        with p.open('rb') as f:
            return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
    except OSError:
        return False


def build(out):
    python = runtime_sources.python()
    python_bin = python/'bin/python3.12'
    tool_prefix, tool_sources = runtime_sources.tools()
    # 随包命令行工具全部来自钉版源码的同一个安装前缀（11-28 起 bash 也是：原先拷出包机 Homebrew 的 bash，冷缓存时拿到 macOS 26 瓶子）
    prefixes = {name: tool_prefix for name in ('spirv-tools', 'spirv-cross', 'glslang', 'zstd', 'bash')}
    bash_bin = tool_prefix/'bin/bash'
    venv = ROOT/'build/macos/python'
    if (venv/'pyvenv.cfg').is_file() and str(python) not in (venv/'pyvenv.cfg').read_text():
        shutil.rmtree(venv)   # 旧的 venv 是 Homebrew Python 建的，原生扩展要按新解释器重装
    if not (venv/'bin/python').is_file():
        run([python_bin, '-m', 'venv', venv])
    # 轮子先进缓存核哈希，再离线装（launchers/shared/runtime_cache.py）
    pins = [l.strip() for l in (ROOT/'launchers/macos/requirements-runtime.txt').read_text().splitlines() if '==' in l and not l.startswith('#')]
    wheels = runtime_cache.wheelhouse(pins, runtime_sources.wheel_platform(), lambda folder, missing: run(
        [venv/'bin/python', '-m', 'pip', 'download', '--disable-pip-version-check', '--no-deps', '--only-binary=:all:', '-d', folder, *missing]))
    run([venv/'bin/python', '-m', 'pip', 'install', '--disable-pip-version-check', '--no-index', '--find-links', wheels, '--no-deps', *pins])
    installed = venv/'lib/python3.12/site-packages'
    if not installed.is_dir():
        raise RuntimeError('Expected build/macos/python site-packages; see README.')
    cp(python, out/'python')
    for extra in ('lib/libpython3.12.dylib', 'lib/libtcl9.0.dylib', 'lib/libtcl9tk9.0.dylib', 'lib/pkgconfig', 'share'):
        victim = out/'python'/extra
        shutil.rmtree(victim) if victim.is_dir() else victim.unlink(missing_ok=True)
    for extra in (out/'python/lib').glob('t[ck]*'):
        if extra.is_dir(): shutil.rmtree(extra)
    site = out/'python/lib/python3.12/site-packages'
    site.mkdir(parents=True, exist_ok=True)
    # 拷贝名单从钉版清单推（11-07：手写名单漏过 Pillow（11-02）、又差点漏 zstandard（.nup 导入要）；清单加一行即随包）。
    #   包名小写当前缀，导入名与包名不同的补上：Pillow → PIL/
    names = [l.split('==')[0].strip().lower() for l in (ROOT/'launchers/macos/requirements-runtime.txt').read_text().splitlines() if '==' in l and not l.startswith('#')]
    keep = tuple(names) + (('pil',) if 'pillow' in names else ())
    for p in installed.iterdir():
        if p.name.lower().startswith(keep):
            cp(p, site/p.name)
    import pil_prune   # Pillow 只留出包用得到的（去 AVIF / Tk 与只被它们引用的库；画字留着，下游做包工具要用，#1570）
    pil_prune.prune(site, lambda f: [l.strip().split(' ')[0].rsplit('/', 1)[-1] for l in output(['otool', '-L', f]).splitlines()[1:]])
    (out/'python/bin/python3').unlink(missing_ok=True)
    (out/'python/bin/python3').symlink_to('python3.12')
    (out/'bin').mkdir()
    for formula, name in TOOLS:
        if formula == 's2a-timeout':
            continue
        cp(prefixes[formula]/'bin'/name, out/'bin'/name)
    build_timeout(out/'bin'/'timeout')
    # C 改写器（runtime/rewriter）在出包机编好随 App 带：玩家机器不装 CMake / 依赖；下面的 Mach-O 循环照常瘦身、去 rpath、签名
    for name in ('S2A_REWRITER', 'S2A_REWRITER_C', 'S2A_REWRITER_BUNDLED'):
        os.environ.pop(name, None)   # 一律按本树源码编，不拿外部指定的二进制
    cp(rewriter.c_path(), out/'bin/s2a-rewrite')
    (out/'bin/s2a-rewrite.source').write_text(rewriter.source_digest()+'\n')
    # .NET 运行时不再随包：出包用的 C# 工具（读取器 / romfs 索引 / 烘焙器 / 直连批量进程）全为引擎 Binaries/ 里的 NativeAOT 单文件（bundle_engine.py），玩家机零 .NET
    libs = out/'lib'
    libs.mkdir()
    todo = [p for p in out.rglob('*')
            if p.is_file() and not p.is_symlink() and macho(p)]
    seen = set()
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        # Keep only the architecture of the build machine: Apple Silicon keeps arm64,
        # an Intel release builder keeps x86_64. Both ship as single-slice tools.
        with p.open('rb') as header:
            fat = header.read(4) in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
        if fat:
            archs = output(['lipo','-archs',p]).split()
            want = runtime_sources.host_arch()
            selected = want if want in archs else ('arm64e' if want == 'arm64' and 'arm64e' in archs else None)
            if selected and len(archs) > 1:
                temporary = p.with_name(p.name+'.thin')
                run(['lipo',p,'-thin',selected,'-output',temporary],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                temporary.replace(p)
        for line in output(['otool', '-L', p]).splitlines()[1:]:
            dep = line.strip().split(' (')[0]
            target = None
            if dep.startswith(('/opt/homebrew/', '/usr/local/', '/opt/local/')):
                # 11-28 起不再把出包机包管理器里的库拷进包：那些件不在指纹里（版本 / 最低系统随出包机漂），原先 bash 就是这样带进 macOS 26 的 readline / ncurses
                raise RuntimeError(f'【红】{p.relative_to(out)} 链到出包机的 {dep}：随包程序只许链系统库和 runtime_sources.py 的钉版件')
            if dep.startswith('@rpath/'):
                source = next((prefix/'lib'/pathlib.Path(dep).name for prefix in prefixes.values()
                               if (prefix/'lib'/pathlib.Path(dep).name).is_file()), None)
                if source:
                    target = libs/source.name
                    if not target.exists():
                        shutil.copy2(source.resolve(), target)
                        todo.append(target)
            if target:
                run(['install_name_tool', '-change', dep, '@loader_path/'+os.path.relpath(target, p.parent), p],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if p.suffix == '.dylib' or p.name == 'Python':
            run(['install_name_tool', '-id', '@loader_path/'+p.name, p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for search in dict.fromkeys(rpaths(output(['otool','-l',p]))):
            if search.startswith('/') and not search.startswith(SYSTEM_PATHS):
                run(['install_name_tool','-delete_rpath',search,p],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        run(['codesign', '--force', '--sign', '-', p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for app in sorted([*out.rglob('*.framework'), *out.rglob('*.app')], key=lambda p:len(p.parts), reverse=True):
        run(['codesign', '--force', '--sign', '-', app], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(out/'python/include', ignore_errors=True)
    (out/'python/Headers').unlink(missing_ok=True)
    for p in (out/'python/bin').iterdir():
        if p.name not in ('python3', 'python3.12'):
            p.unlink()
    env = dict(os.environ, PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1')
    run([out/'python/bin/python3', '-B', '-I', '-c', 'import capstone,lz4.block,numpy,PIL.Image,PIL.ImageFont,PIL._imagingft,zstandard,ctypes,zlib,hashlib; print("Portable Python dependencies OK")'], env=env)
    # zstd 解压要用 Runtime/bin/zstd 旁边的 ../lib/libzstd.1.dylib（App 的 Python 3.12 没有 compression.zstd；Python 侧入口 graphics/tools/shbake/zstd_lib.py 随 pack/uepak-v8 入）
    run([out/'python/bin/python3', '-B', '-I', '-c', f'import ctypes; ctypes.CDLL({str(out / "lib/libzstd.1.dylib")!r}).ZSTD_versionNumber; print("Runtime libzstd OK")'], env=env)
    licenses = out/'licenses'
    licenses.mkdir()
    copies = [
        (python / "lib/python3.12/LICENSE.txt", "Python-LICENSE.txt"),
        (tool_sources["spirv-tools"] / "LICENSE", "SPIRV-Tools-LICENSE.txt"),
        (tool_sources["zstd"] / "LICENSE", "Zstandard-LICENSE.txt"),
        (tool_sources["bash"] / "COPYING", "bash-COPYING.txt"),
        (ROOT / "launchers/macos/runtime_source_offer.txt", "S2Arm-runtime-source-offer.txt"),
        (tool_sources["spirv-cross"] / "LICENSE", "SPIRV-Cross-LICENSE.txt"),
        (tool_sources["glslang"] / "LICENSE.txt", "glslang-LICENSE.txt"),
        (ROOT / "runtime/rewriter/LICENSES/capstone.txt", "capstone-LICENSE.txt"),
        (ROOT / "runtime/rewriter/LICENSES/lz4.txt", "lz4-LICENSE.txt"),
    ]
    for src, name in copies:
        shutil.copy2(src, licenses / name)
    # 版本记录要覆盖 requirements-runtime.txt 的每一行：漏记 Pillow / zstandard 会让 build_app 每次都判 Runtime 过期重收。
    names = [pin.split('==')[0] for pin in pins]
    probe = installed_versions_probe(names)
    versions = json.loads(
        output(
            [
                out / "python/bin/python3",
                "-B",
                "-I",
                "-c",
                probe,
            ]
        )
    )
    versions.update(
        runtimeSchema=5,
        runtimeDeps=runtime_deps_fingerprint(),
        timeout="tools/bin/timeout",
        spirvTools="spirv-tools " + runtime_sources.SPIRV_TOOLS_VERSION,
        zstd="zstd " + runtime_sources.ZSTD_VERSION,
        bash=output([bash_bin, "-c", 'echo "bash ${BASH_VERSION}"']),
        spirvCross="spirv-cross " + runtime_sources.SPIRV_CROSS_VERSION,
        glslang="glslang " + runtime_sources.GLSLANG_VERSION,
        rewriter=rewriter.source_digest(),
    )
    (out / "versions.json").write_text(json.dumps(versions, indent=2))
    for tool, arguments in [
        ("spirv-as", ["--version"]),
        ("spirv-val", ["--version"]),
        ("zstd", ["--version"]),
        ("timeout", ["5", "true"]),
        ("bash", ["-c", '[ "${BASH_VERSINFO[0]}" -ge 5 ]']),
        ("spirv-cross", ["--help"]),
        ("glslangValidator", ["--version"]),
        ("s2a-rewrite", ["--version"]),
    ]:
        run([out / "bin" / tool, *arguments], stdout=subprocess.DEVNULL, env=env)
    print("Portable native runtime files:", verify_portable_runtime(out))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, default=ROOT/'build/macos/Runtime')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise RuntimeError('A macOS release builder (arm64 or x86_64) is required for the packaging runtime.')
    destination = args.output.resolve()
    if not destination.is_relative_to(ROOT/'build/macos'):
        raise RuntimeError('Runtime output must be inside the ignored build/macos directory.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(tempfile.mkdtemp(prefix='runtime-', dir=destination.parent))
    try:
        build(staging)
        backup = destination.with_name(destination.name+'.previous')
        if backup.exists():
            shutil.rmtree(backup)
        if destination.exists():
            destination.rename(backup)
        staging.rename(destination)
        shutil.rmtree(backup, ignore_errors=True)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print('Runtime ready:', destination)


if __name__ == '__main__':
    main()
