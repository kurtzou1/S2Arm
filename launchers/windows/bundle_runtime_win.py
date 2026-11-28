#!/usr/bin/env python3
"""Windows 启动器随包运行时（启动器第 2 步，11-06 维护者：玩家「几乎不用额外装依赖」；同 Mac launchers/macos/bundle_runtime.py 的口径）。
在 Windows 出包机上：python -X utf8 launchers/windows/bundle_runtime_win.py <目标>   → <目标>/Runtime/（不许已存在：不混旧件）
  python/        官方 Python 3.12 嵌入版（专为随应用分发）+ 钉版 capstone / lz4 / numpy / Pillow / zstandard（同 launchers/macos/requirements-runtime.txt）
  （不带 .NET：启动器与出包 C# 件都是 NativeAOT 原生可执行文件，v0.5.0 起，见 bundle_prepare_win.py；同 Mac #1135）
  git/usr/bin/   Git for Windows 的 usr/bin（bash 与 awk / sed / cut / join 等，直连库等出包脚本在 bash 下跑）；独立进程调用，不与我们的代码链接
  zstd/          官方 zstd-v1.5.7-win64（布局阶段钉版命令行 + libzstd）
  licenses/      各件许可原文 + 源码获取说明（GPL 件）
  s2arm_env.cmd  出包作业的环境（PATH / S2A_BASH）：启动器起作业前 call 它，并设 S2A_ENGINE=<引擎目录>（随包 Python 按它找 pack.*）
  versions.json  各件版本与来源
来源：Python 嵌入版、轮子从官方地址下载并缓存（launchers/shared/runtime_cache.py：命中不联网，每个文件核钉死的 SHA-256）；Git、zstd 从本机已装的官方发行版拷（路径见下面常量，可用环境变量改）。
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launchers/shared"))
import runtime_cache   # noqa: E402
PY_VER = "3.12.10"
PY_URL = f"https://www.python.org/ftp/python/{PY_VER}/python-{PY_VER}-embed-amd64.zip"
GIT = Path(os.environ.get("S2A_RT_GIT", r"C:\Program Files\Git"))
ZSTD_DIR = "zstd-v1.5.7-win64"   # 钉版官方命令行 + libzstd 的目录名


def zstd_dir():
    """钉版 zstd 目录：S2A_RT_ZSTD 给了就用它；否则在 PATH 上找 zstd.exe、取所在目录，目录名须是钉版 ZSTD_DIR。
    原先缺省写死某一台出包机的盘符路径，换机后整段红（FileNotFoundError），这里不再写死任何机器路径"""
    given = os.environ.get("S2A_RT_ZSTD")
    if given:
        return Path(given)
    exe = shutil.which("zstd")
    if exe and Path(exe).parent.name == ZSTD_DIR:
        return Path(exe).parent
    raise SystemExit(f"【红】找不到钉版 {ZSTD_DIR}：设 S2A_RT_ZSTD=<目录>，或把该目录放进 PATH（PATH 上的 zstd：{exe or '没有'}）")
GPL_OFFER = """S2Arm 的 Windows 运行时把 Git for Windows 的 usr/bin（GNU bash、coreutils、gawk、sed、grep 等 MSYS2 程序与 msys-2.0.dll 运行库）
作为独立程序放在 Runtime/git/usr/bin。它们由出包作业经 PATH 单独拉起，不与 S2Arm 的代码静态链接，也不作为 S2Arm 的动态库加载。

许可：git GPL-2.0；bash、coreutils、gawk、sed、grep 等 GPL-3.0-or-later；MSYS2 运行库 GPL-3.0（带链接例外）。许可全文见同目录 git-*.txt。
对应版本：Runtime/versions.json 里的 git 字段（Git for Windows 版本）。
对应源码：https://github.com/git-for-windows/git/releases 下与该版本一致的发行说明列出的各组件源码包；
  MSYS2 程序源码：https://github.com/msys2/MSYS2-packages （按 git-for-windows/build-extra 记录的版本）。

书面提供：自收到书面请求起，按 GPL 第 6 节提供上述对应版本的源码。请求请发到 https://github.com/jhaizhou-ops/S2Arm/issues （面向维护者）。

本说明只覆盖上述独立程序，不把 S2Arm 其余代码改为 GPL。
"""


def say(m): print(m, flush=True)


def pins():
    req = (ROOT / "launchers/macos/requirements-runtime.txt").read_text(encoding="utf-8").splitlines()
    return [l.strip() for l in req if "==" in l and not l.startswith("#")]


def python(rt, versions):
    d = rt / "python"; d.mkdir()
    zipfile.ZipFile(runtime_cache.fetch_file(f"python-{PY_VER}-embed-amd64.zip")).extractall(d)
    # 去掉嵌入版的 ._pth：它固定模块路径、连「被运行脚本所在目录」都不加（仓库里大量 python <目录>/x.py 导入同目录兄弟模块，11-06 验收
    #   spvc_inproc.py 找不到 xlock）。改由 s2arm_env.cmd 设 PYTHONHOME=<本目录>（不读注册表里机器另装的 Python）+ PYTHONNOUSERSITE=1（不读用户 site-packages）
    for pth in d.glob("python3*._pth"): pth.unlink()
    site = d / "Lib/site-packages"; site.mkdir(parents=True)
    # 按环境变量 S2A_ENGINE（启动器设成引擎目录）把引擎根插到模块路径最前：python -m pack.… 不依赖当前目录
    (site / "s2arm_engine.pth").write_text("import os, sys; p = os.environ.get('S2A_ENGINE'); p and sys.path.insert(0, p)\n", encoding="utf-8")
    # 本机 pip 按目标平台取官方二进制轮子：先进缓存核哈希，再从缓存离线装进 site-packages（不编译）
    target = ["--only-binary=:all:", "--platform", "win_amd64", "--python-version", "3.12", "--implementation", "cp", "--no-deps"]
    wheels = runtime_cache.wheelhouse(pins(), "win_amd64", lambda folder, missing: subprocess.run(
        [sys.executable, "-m", "pip", "download", "--disable-pip-version-check", *target, "-d", str(folder), *missing], check=True))
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--no-compile", "--no-index", "--find-links", str(wheels),
                    *target, "--target", str(site), *pins()], check=True, env=dict(os.environ, SOURCE_DATE_EPOCH="1262304000"))   # pip 生成的 .exe 启动器内含打包时刻，钉住才可复现
    import pil_prune   # Pillow 只留出包用得到的（去 AVIF / Tk 扩展；画字留着，下游做包工具要用，#1570；Windows 轮子依赖静态链在 .pyd 里）
    pil_prune.prune(site)
    versions["python"] = PY_VER; versions["python_url"] = PY_URL; versions["python_packages"] = pins()


# Git for Windows 的 usr/bin 只带出包用得到的（11-16 安装包瘦身：整份 95 MB，原先只去掉 vim 一族）：
#   引擎快照里脚本 / Python / mk 文本中以独立词出现过的程序名（保守超集：叫得出名字的都留），加上它们 PE 导入表里的 msys DLL 闭包。
#   发版时按这一版快照现算，以后脚本新用到的程序自动收进来；动态拼出来的命令名收不到，所以别在脚本里拼程序名。
#   vim 一族照旧不带（交互编辑器，文本里「vim」只出现在这条注释类的说明里）
GIT_SKIP = {"vim.exe", "vimdiff.exe", "view.exe", "rview.exe", "rvim.exe", "ex.exe", "vimtutor", "vi"}
GIT_ALWAYS = {"bash.exe", "sh.exe", "env.exe", "cygpath.exe", "msys-2.0.dll"}   # 作业直接拉起 bash（S2A_BASH）、路径换算；不一定在脚本文本里以词出现
SCRIPT_SUFFIXES = (".sh", ".bash", ".py", ".mk", ".awk", ".cmd", ".ps1")


def pe_imports(path):
    """PE 导入表里的 DLL 名（只读文件头，不加载）；不是 PE / 读坏 → []"""
    import struct
    d = Path(path).read_bytes()
    try:
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        if d[pe:pe + 4] != b"PE\0\0": return []
        nsec, opt = struct.unpack_from("<H", d, pe + 6)[0], struct.unpack_from("<H", d, pe + 20)[0]
        dd = pe + 24 + (112 if struct.unpack_from("<H", d, pe + 24)[0] == 0x20B else 96)
        secs = [struct.unpack_from("<8sIIII", d, pe + 24 + opt + i * 40) for i in range(nsec)]
        def off(r):
            return next((r - va + ro for _, vs, va, rs, ro in secs if va <= r < va + max(vs, rs)), None)
        o, out = off(struct.unpack_from("<I", d, dd + 8)[0]), []
        while o is not None and struct.unpack_from("<I", d, o + 12)[0]:
            n = off(struct.unpack_from("<I", d, o + 12)[0]); out.append(d[n:d.index(b"\0", n)].decode("ascii", "replace")); o += 20
        return out
    except (struct.error, ValueError):
        return []


def git_keep(usr_bin, texts):
    """usr/bin 里要带的文件名：文本中出现过的程序（去 .exe 比）+ GIT_ALWAYS，再按导入表补 DLL 闭包；GIT_SKIP 一律不带"""
    import re
    names = {p.name for p in Path(usr_bin).iterdir() if p.is_file()}
    low = {n.lower(): n for n in names}
    words = set(re.findall(r"(?<![\w.\-/])([a-z][a-z0-9_+.\-]*[a-z0-9+])(?![\w\-])", "\n".join(texts).lower()))
    keep = {n for n in names if (n.lower()[:-4] if n.lower().endswith(".exe") else n.lower()) in words} | {low[a] for a in GIT_ALWAYS if a in low}
    keep = {n for n in keep if n.lower() not in GIT_SKIP}
    todo = list(keep)
    while todo:
        for dll in pe_imports(Path(usr_bin) / todo.pop()):
            n = low.get(dll.lower())
            if n and n not in keep: keep.add(n); todo.append(n)
    return keep


def engine_texts():
    sys.path.insert(0, str(ROOT / "launchers/macos")); sys.path.insert(0, str(ROOT / "pack/jobs"))
    import bundle_engine   # noqa: E402  与发版引擎快照同一份文件清单
    return [(ROOT / f).read_text(encoding="utf-8", errors="ignore") for f in bundle_engine.snapshot_files(ROOT)
            if f.suffix in SCRIPT_SUFFIXES or f.name == "Makefile"]


def git(rt, versions):
    keep = git_keep(GIT / "usr/bin", engine_texts())
    shutil.copytree(GIT / "usr/bin", rt / "git/usr/bin", ignore=lambda d, names: [n for n in names if n not in keep])
    if (GIT / "etc").is_dir(): shutil.copytree(GIT / "etc", rt / "git/etc")   # bash 读 /etc 下的 profile / passwd 等（缺了照跑，带上少告警）
    out = subprocess.run([str(GIT / "cmd/git.exe"), "--version"], capture_output=True, text=True).stdout.strip()
    versions["git"] = out.replace("git version ", "")


VC_RUNTIME_VERSION = "14.44.35112"
VC_RUNTIME = {   # metal.exe 及其同目录 DLL 的 PE 导入表里，系统不自带的就这三个（苹果 Metal Developer Tools，要求 VC++ 2015-2022 运行库）
    "msvcp140.dll": "0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9",
    "vcruntime140.dll": "d5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066",
    "vcruntime140_1.dll": "1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f",
}


def vc_runtime(rt, versions):
    """微软可再发行的 VC++ 运行库：玩家机器没装时 metal.exe 也能跑（Windows 上由 winproc.prepare_child_environment 放进 PATH）。"""
    found = sorted(Path(r"C:/").glob(f"Program Files*/Microsoft Visual Studio/*/*/VC/Redist/MSVC/{VC_RUNTIME_VERSION}/x64/Microsoft.VC143.CRT"))
    if not found: raise SystemExit(f"【红】出包机缺 VC 运行库 {VC_RUNTIME_VERSION}（Visual Studio 的 Redist 目录）")
    target = rt / "vcrt"; target.mkdir()
    for name, want in VC_RUNTIME.items():
        data = (found[0] / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != want: raise SystemExit(f"【红】{name} 的 SHA-256 与钉版不符")
        (target / name).write_bytes(data)
    versions["vcRuntime"] = VC_RUNTIME_VERSION


def zstd(rt, versions):
    shutil.copytree(zstd_dir(), rt / "zstd")
    if not (rt / "zstd/LICENSE").is_file(): runtime_cache.copy_file("zstd-v1.5.7-LICENSE", rt / "zstd/LICENSE")
    versions["zstd"] = subprocess.run([str(rt / "zstd/zstd.exe"), "--version"], capture_output=True, text=True).stdout.strip()


def licenses(rt):
    L = rt / "licenses"; L.mkdir()
    pairs = [(rt / "python/LICENSE.txt", "Python-LICENSE.txt"), (GIT / "LICENSE.txt", "git-LICENSE.txt"),
             (rt / "zstd/LICENSE", "Zstandard-LICENSE.txt"),
             (ROOT / "runtime/rewriter/LICENSES/capstone.txt", "capstone-LICENSE.txt"), (ROOT / "runtime/rewriter/LICENSES/lz4.txt", "lz4-LICENSE.txt")]
    for src, name in pairs:
        if not src.is_file(): raise SystemExit(f"【红】缺许可原文：{src}")
        shutil.copy2(src, L / name)
    for name in ("COPYING", "COPYING.LIB"):   # MSYS2 / GNU 程序的 GPL 原文（Git for Windows 放在 usr/share/licenses 或根下，有就带）
        for p in list((GIT / "usr/share/licenses").glob(f"*/{name}"))[:1] if (GIT / "usr/share/licenses").is_dir() else []:
            shutil.copy2(p, L / f"git-{name}.txt")
    (L / "S2Arm-runtime-source-offer.txt").write_text(GPL_OFFER, encoding="utf-8")   # numpy / Pillow 等轮子的许可在各自 *.dist-info 里，随包保留


def env_cmd(rt):
    # S2Arm 出包作业环境：只用随包运行时，不依赖玩家机上另装的 Python / Git（.NET 不需要：C# 件都是原生单文件）。
    # 文件必须是纯 ASCII（encode("ascii") 写，混进非 ASCII 就打包失败）：cmd 按玩家机代码页（中文系统 936）逐字节读 .cmd，
    #   不带 BOM 的 UTF-8 中文注释按 GBK 拆字，奇数字节会把行尾吞掉、下一行 set 跟着失效（11-18 一份双击脚本就这样白跑；
    #   这份原先也有两行中文 rem，936 下实测碰巧没错位，改一个字就可能坏）。说明一律写在这里，不进 .cmd。
    # S2A_USER_PATH：玩家原来的 PATH 先存下（Metal 工具装在自定义目录、只加进 PATH 时，pack/orch/oneclick_win.metal_exe 按它找）；嵌套调用保留最外层那份
    (rt / "s2arm_env.cmd").write_bytes(("\r\n".join([
        "@echo off",
        "rem S2Arm job environment (generated by bundle_runtime_win.py)",
        'set "S2A_RT=%~dp0"',
        'if not defined S2A_USER_PATH set "S2A_USER_PATH=%PATH%"',
        'set "PATH=%S2A_RT%python;%S2A_RT%python\\Scripts;%S2A_RT%git\\usr\\bin;%S2A_RT%zstd;%SystemRoot%\\system32;%SystemRoot%;%SystemRoot%\\System32\\WindowsPowerShell\\v1.0"',
        'set "S2A_BASH=%S2A_RT%git\\usr\\bin\\bash.exe"', 'set "PYTHONUTF8=1"', 'set "LC_ALL=C.UTF-8"', 'set "PYTHONDONTWRITEBYTECODE=1"',
        'set "PYTHONHOME=%S2A_RT%python"', 'set "PYTHONNOUSERSITE=1"', 'set "PYTHONPATH="', ""]) ).encode("ascii"))


def smoke(rt):   # 每件跑一下：Python 带四个库、bash 跑管道、zstd 版本
    env = dict(os.environ, PATH=os.pathsep.join([str(rt / "python"), str(rt / "git/usr/bin"), str(rt / "zstd"), os.environ.get("SystemRoot", r"C:\Windows") + r"\system32"]))
    checks = [([str(rt / "python/python.exe"), "-B", "-c", "import capstone, lz4.block, numpy, PIL.Image, PIL.ImageFont, PIL._imagingft, zstandard, ctypes, zlib, hashlib, multiprocessing; print('python ok', numpy.__version__)"], "python ok"),
              ([str(rt / "git/usr/bin/bash.exe"), "-c", "printf 'b\\na\\n' | sort | head -1 | awk '{print \"bash \" $1}'"], "bash a"),
              ([str(rt / "zstd/zstd.exe"), "--version"], "v1.5.7"),
              ([str(rt / "python/python.exe"), "-B", "-c", "import ctypes, os, sys; [ctypes.WinDLL(os.path.join(sys.argv[1], n)) for n in sys.argv[2:]]; print('vcrt ok')", str(rt / "vcrt"), *sorted(VC_RUNTIME)], "vcrt ok")]
    env.update(PYTHONHOME=str(rt / "python"), PYTHONNOUSERSITE="1"); env.pop("PYTHONPATH", None)
    with tempfile.TemporaryDirectory() as t:   # 脚本能导入同目录兄弟模块；模块路径只含随包 python 目录（不混机器上另装的 Python / 用户 site-packages）
        Path(t, "sib.py").write_text("X = 1\n", encoding="utf-8")
        Path(t, "main.py").write_text("import sys, sib\nbad = [p for p in sys.path[1:] if p and not p.lower().startswith(sys.argv[1].lower())]\nprint('pathok' if not bad else 'bad ' + repr(bad))\n", encoding="utf-8")
        checks.append(([str(rt / "python/python.exe"), str(Path(t, "main.py")), str(rt / "python")], "pathok"))
        for cmd, want in checks:
            p = subprocess.run(cmd, capture_output=True, text=True, env=env)
            if want not in p.stdout: raise SystemExit(f"【红】自检不过：{' '.join(cmd)[:120]} → {(p.stdout + p.stderr).strip()[-300:]}")
            say(f"  自检 {Path(cmd[-1] if cmd[-1].endswith('python') else cmd[0]).name}：{p.stdout.strip().splitlines()[0][:80]}")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0].startswith("-"): raise SystemExit("用法：bundle_runtime_win.py <目标目录>")
    rt = Path(argv[0]) / "Runtime"
    if rt.exists(): raise SystemExit(f"【红】{rt} 已存在，不混旧件")
    rt.mkdir(parents=True); versions = {}
    for step in (python, git, zstd, vc_runtime):
        say(f"[运行时] {step.__name__}"); step(rt, versions)
    licenses(rt); env_cmd(rt)
    (rt / "versions.json").write_text(json.dumps(versions, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    smoke(rt)
    size = sum(p.stat().st_size for p in rt.rglob("*") if p.is_file())
    say(f"🟢 运行时 → {rt}（{size / 2**20:.0f} MB）：{json.dumps(versions, ensure_ascii=False)}")


if __name__ == "__main__":
    main()
