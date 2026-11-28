#!/usr/bin/env python3
"""从源码构建 Mac 启动器的一键准备：检查 / 准备全部构建依赖，缺什么当场说清楚、给出装法。

    python3 launchers/macos/prepare_build.py [--venv <目录>] [--check]

查（只读，不替你装系统级东西）：macOS（arm64 出全套；x86_64 只出包壳与出包工具，不在 Intel Mac 上跑游戏）；Xcode（同出包的 tools/toolchain.sh 解析：S2A_DEVELOPER_DIR / tools/machine.local → xcode-select）
  与 iOS SDK、Metal 编译器——编译器版本与 translator/dmsh_chain.lock 不同只出 note（出包时直连库按本机编译器重编，不报错）；
  .NET SDK——在 compat/tree 里跑 dotnet --version，由 dotnet 按 compat/tree/global.json（版本 + rollForward）判定，不另抄版本号；
  Homebrew 公式（运行环境打包 bundle_runtime.py 收的工具 + C 改写器的 CMake + dav1d 的 meson / ninja——本机探测有 AV1 硬件解码时 dav1d 整条不要，meson / ninja 不需要）；Rust（pack/devpush）。
准备（可逆、只写在你给的目录或本树 build/ 下；--check 时跳过）：
  GNU Make 4（本机没装时从钉版源码编到 build/macos/gmake，出预编 iPhone 壳要）；
  构建用 Python 虚拟环境（缺省本树 build/venv，基准解释器跟着 runtime_sources.py 的钉版独立 Python 走；brew 在则用 brew 的 python@3.12）装齐三份钉版清单：tools/rewriter-requirements.txt、
  pack/fonts/requirements.txt（字体生成器 fonttools / skia-pathops）、launchers/macos/requirements-runtime.txt；
  C 改写器钉版源码（runtime/rewriter/prepare_deps.py → 本树 build/rewriter-deps；已有完整的一份就不下载）。
全部就绪退出 0，并打印下一步命令；有缺项退出 1。不读、不写开发机专用路径。"""
from __future__ import annotations
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))   # 按文件加载本脚本时（单测 importlib）同目录也找得到
import runtime_sources   # noqa: E402  同目录：构建 venv 的基准解释器跟着随包 Python 的钉版走
REQS = ["tools/rewriter-requirements.txt", "pack/fonts/requirements.txt", "launchers/macos/requirements-runtime.txt"]
# 公式 → 谁要：出包脚本本身要的 bash 5（随包 Runtime/bin/bash 11-28 起由 runtime_sources.py 钉版源码编，不拷这份）+ C 改写器（runtime/rewriter，CMake 3.18+）+ dav1d 软解兜底（AV1；S2A_DAV1D 缺省 auto 探测本机，
#   有 AV1 硬解时整条不进构建，见 dav1d_wanted；只有它要 meson / ninja）
FORMULAS = {"python@3.12": "构建 venv",
            "bash": "出包脚本（bash 5）", "cmake": "C 改写器"}
DAV1D_FORMULAS = {"meson": "dav1d 静态库（AV1 软解兜底）", "ninja": "dav1d 静态库（AV1 软解兜底）"}
IMPORTS = "import capstone, lz4, numpy, PIL, fontTools, pathops"
GMAKE_VERSION = "4.4.1"
GMAKE_URL = f"https://ftp.gnu.org/gnu/make/make-{GMAKE_VERSION}.tar.gz"
GMAKE_SHA256 = "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"
rows = []


def can_build_on(system, machine):
    """Apple Silicon 出全套；Intel Mac 只做出包启动器（游戏宿主仍是 AArch64 原生执行）。"""
    return system == "Darwin" and machine in ("arm64", "x86_64")


def row(name, ok, detail, fix=""):
    rows.append((name, ok, detail, fix))


def run(args, **kw):
    try:
        return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kw)
    except OSError as e:
        return subprocess.CompletedProcess(args, 127, "", str(e))


def dav1d_wanted(dev):
    """dav1d 软解兜底（AV1）要不要进本机构建——meson / ninja 只为它：S2A_DAV1D=1 / 0 直说，缺省 1；显式 auto = 探测本机
    （tools/av1hw.sh --want：VideoToolbox 建得出 AV1 解码会话 = 有硬解，AV1 走 VideoToolbox，软解整条不要）。
    回 (要不要, 说明)；探测没答上来时保守按要算（= 原默认行为）。"""
    v = os.environ.get("S2A_DAV1D", "1")   # 缺省链（见 Makefile S2A_DAV1D）；auto 只显式设
    if v in ("0", "1"):
        return v == "1", "S2A_DAV1D=%s" % v
    env = dict(os.environ)
    if dev:
        env["DEVELOPER_DIR"] = dev
    p = run(["bash", ROOT / "tools/av1hw.sh", "--want"], env=env)
    lines = p.stdout.split()
    if lines and lines[-1] == "0":
        return False, "本机有 AV1 硬件解码（tools/av1hw.sh 探测：VideoToolbox 建得出 AV1 会话），AV1 走 VideoToolbox，dav1d 软解兜底与 meson / ninja 都不需要；要给无硬解的机器兜底就 export S2A_DAV1D=1 再跑"
    if lines and lines[-1] == "1":
        return True, "本机没有 AV1 硬件解码（tools/av1hw.sh 探测），dav1d 软解兜底要编（meson / ninja 要装）"
    return True, "本机 AV1 硬解探测没答上来（tools/av1hw.sh），按要 dav1d 算（= 原默认行为）"


def vpx_wanted(dev):
    """真 libvpx（VP8 / VP9 软解）要不要进本机构建：S2A_VPX=1 / 0 直说，缺省 1；显式 auto = 探测本机可走
    系统 VP9（tools/vp9hw.sh --want：注册 supplemental 后建得出 VP9 会话 = VP9 走 VideoToolbox）。
    回 (要不要, 说明)；探测没答上来时保守按要算（= 原默认行为）。"""
    v = os.environ.get("S2A_VPX", "1")   # 同上
    if v in ("0", "1"):
        return v == "1", "S2A_VPX=%s" % v
    env = dict(os.environ)
    if dev:
        env["DEVELOPER_DIR"] = dev
    p = run(["bash", ROOT / "tools/vp9hw.sh", "--want"], env=env)
    lines = p.stdout.split()
    if lines and lines[-1] == "0":
        return False, "本机可走系统 VP9（tools/vp9hw.sh 探测：注册 supplemental 后建得出 VP9 会话），VP9 走 VideoToolbox、libvpx 整条不进构建（VP8 无任何系统替代，这些机器上如实报红）；要兜 VP8 / 不可走系统的机器就 export S2A_VPX=1 再跑"
    if lines and lines[-1] == "1":
        return True, "本机不可走系统 VP9（tools/vp9hw.sh 探测），VP8 / VP9 软解照编 libvpx"
    return True, "本机系统 VP9 探测没答上来（tools/vp9hw.sh），按要 libvpx 算（= 原默认行为）"


def check_xcode():
    p = run(["bash", "-c", 'S2A_TC_QUIET=1 source tools/toolchain.sh > /dev/null && printf "%s\\n%s\\n%s" "$DEVELOPER_DIR" "$S2A_TC_SDK" "$S2A_TC_METAL"'], cwd=ROOT)
    if p.returncode != 0:
        row("Xcode / Metal", False, (p.stderr.strip().splitlines() or ["tools/toolchain.sh 解析失败"])[-1].lstrip("🔴 "),
            "装完整 Xcode 并打开一次装 iOS 平台与 Metal Toolchain；装了多个时 sudo xcode-select -s <Xcode.app>/Contents/Developer 或设 S2A_DEVELOPER_DIR")
        return None
    dev, sdk, metal = (p.stdout.split("\n") + ["", "", ""])[:3]
    row("Xcode / Metal", True, f"{dev}；iOS SDK {sdk}；{metal}")
    lock = ROOT / "translator/dmsh_chain.lock"
    locked = next((l.split("\t", 1)[1].strip() for l in lock.read_text(encoding="utf-8").splitlines() if l.startswith("metal_iphoneos\t")), "") if lock.is_file() else ""
    if locked and locked != metal.strip():
        row("Metal 与锁", True, f"note：本机 {metal.strip()}，锁文件 {locked}。只出 note 不报错：直连库出库前核工具时放行（dmsh_chain.py --build-env），"
            "Metal 编译缓存按编译器身份分键，换 Xcode 只是重编")
    return dev


def find_dotnet():
    d = shutil.which("dotnet")
    if d:
        return d
    home = Path.home() / ".dotnet/dotnet"   # 微软 dotnet-install 的缺省位置（不是我方开发机路径）
    return str(home) if home.is_file() else None


def check_dotnet():
    want = (ROOT / "compat/tree/global.json").read_text(encoding="utf-8")
    fix = ("按 compat/tree/global.json 装官方 SDK：python3 pack/jobs/applenv.py --install dotnet，"
           "再把 ~/.dotnet 放进 PATH（或 python3 pack/jobs/applenv.py --install dotnet）")
    d = find_dotnet()
    if not d:
        row(".NET SDK", False, "没有 dotnet", fix)
        return
    p = run([d, "--version"], cwd=ROOT / "compat/tree")   # 在 global.json 所在目录跑：dotnet 自己按 version + rollForward 选 SDK，选不到就报错
    if p.returncode != 0:
        out = [l.strip() for l in (p.stderr + p.stdout).splitlines() if l.strip()]
        why = next((l for l in out if l.startswith(("A compatible .NET SDK", "Requested SDK"))), out[0] if out else f"退出码 {p.returncode}")
        have = run([d, "--list-sdks"]).stdout.split()[::2]   # 「10.0.100 [路径]」→ 版本号
        row(".NET SDK", False, f"{d} 没有满足 global.json（{' '.join(want.split())}）的 SDK：{why}；本机已装 {'、'.join(have) or '无'}", fix)
        return
    real = os.path.realpath(d)
    if "/Cellar/" in real or "/homebrew/" in real:   # 同 docs/贡献者开发测试套件.md：源码构建版缺 Brotli 静态库，编 Mac 版 C# 库报 _Brotli* 未定义
        row(".NET SDK", False, f"{p.stdout.strip()}（{real}）是 Homebrew 源码构建版，缺 Brotli 静态库，编 Mac 版 C# 库会报 _Brotli* 未定义", fix)
        return
    row(".NET SDK", True, f"{p.stdout.strip()}（{d}，按 compat/tree/global.json 选中）")


def check_brew(dav1d):
    """有 brew 就按公式核（dav1d 要时加 meson / ninja）；没有 brew 时逐项核 PATH 上等价工具，Intel Mac 不强装 Homebrew。"""
    brew = shutil.which("brew")
    formulas = dict(FORMULAS)
    if dav1d:
        formulas.update(DAV1D_FORMULAS)
    if brew:
        missing = [f for f in formulas if run([brew, "list", "--versions", f]).returncode != 0]
        if missing:
            row("Homebrew 公式", False, "缺 " + "、".join(f"{f}（{formulas[f]}）" for f in missing), "brew install " + " ".join(missing))
        else:
            row("Homebrew 公式", True, " ".join(formulas))
        return brew
    needs = ["python3", "cmake", "cargo"] + (["meson", "ninja"] if dav1d else [])
    missing = [n for n in needs if not shutil.which(n)]
    bash = shutil.which("bash")
    major = int(run([bash, "-c", "echo ${BASH_VERSINFO[0]}"]).stdout.strip() or 0) if bash else 0
    if major < 5:
        missing.append("bash 5")
    row("本机构建工具", not missing,
        f"没有 Homebrew；用 PATH 上的等价工具（bash {major}，{', '.join(n for n in needs if n not in missing)}）" if not missing
        else "没有 Homebrew，PATH 上还缺 " + "、".join(missing),
        "" if not missing else "装上缺的项（或安装 Homebrew 后 brew install " + " ".join(formulas) + "）")
    return None


def gmake_path():
    return ROOT / "build/macos/gmake/bin/make"


def prepare_gmake(check_only):
    """出 iPhone 壳要 GNU Make ≥ 4（系统 3.81 的 -j 会卡死）；本机没装就从钉版源码编到 build/。"""
    target = gmake_path()
    if target.is_file() and "GNU Make 4" in run([target, "--version"]).stdout:
        row("GNU Make 4", True, str(target))
        return str(target)
    if check_only:
        row("GNU Make 4", False, "本机没有 gmake 4，也没有构建好的 " + str(target), f"python3 {Path(__file__).relative_to(ROOT)}")
        return None
    cache = ROOT / "build/macos/runtime-sources/downloads" / f"make-{GMAKE_VERSION}.tar.gz"
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.is_file() or hashlib.sha256(cache.read_bytes()).hexdigest() != GMAKE_SHA256:
        cache.unlink(missing_ok=True)
        p = run(["curl", "-fsSL", "--retry", "5", "--retry-all-errors", "-o", cache, GMAKE_URL])
        if p.returncode != 0 or not cache.is_file() or hashlib.sha256(cache.read_bytes()).hexdigest() != GMAKE_SHA256:
            row("GNU Make 4", False, f"钉版源码下载 / 校验失败：{(p.stderr or p.stdout).strip()[-200:]}")
            return None
    staging = Path(tempfile.mkdtemp(prefix="gmake-", dir=ROOT / "build/macos"))
    try:
        import tarfile
        with tarfile.open(cache) as archive:
            archive.extractall(staging, filter="data")
        source = staging / f"make-{GMAKE_VERSION}"
        prefix = target.parent.parent
        for args in (["bash", "./configure", f"--prefix={prefix}"], ["make", "-s"], ["make", "-s", "install"]):
            p = run(args, cwd=source)
            if p.returncode != 0:
                raise RuntimeError((p.stderr or p.stdout).strip()[-300:])
        row("GNU Make 4", target.is_file(), str(target) if target.is_file() else "编完没找到产物")
        return str(target) if target.is_file() else None
    except (OSError, RuntimeError, tarfile.TarError) as e:
        row("GNU Make 4", False, f"从钉版源码编 GNU Make 失败：{e}")
        return None
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def check_cargo():
    c = shutil.which("cargo") or (str(Path.home() / ".cargo/bin/cargo") if (Path.home() / ".cargo/bin/cargo").is_file() else None)   # rustup 的缺省位置，同 bundle_engine.py
    row("Rust（cargo）", bool(c), c or "没有 cargo（pack/devpush 推资源包工具要编）", "" if c else "按 https://rustup.rs 安装 Rust")


def prepare_venv(venv, brew, check_only):
    py = venv / "bin/python3"
    base = (Path(run([brew, "--prefix", "python@3.12"]).stdout.strip() or "/nonexistent") / "bin/python3.12") if brew else (runtime_sources.python() / "bin/python3.12")
    if not py.is_file():
        if check_only:
            row("构建 venv", False, f"{venv} 还没建", f"python3 {Path(__file__).relative_to(ROOT)} --venv {venv}")
            return None
        if not base or not base.is_file():
            row("构建 venv", False, f"没有可用的 Python 3.12+（{base}），建不了构建 venv", "装 Python 3.12+ 并让它出现在 PATH")
            return None
        p = run([base, "-m", "venv", venv])
        if p.returncode != 0:
            row("构建 venv", False, f"建 {venv} 失败：{p.stderr.strip()[-200:]}")
            return None
    if not check_only:
        args = [py, "-m", "pip", "install", "--disable-pip-version-check", "-q"]
        for r in REQS:
            args += ["-r", ROOT / r]
        p = run(args)
        if p.returncode != 0:
            row("构建 venv", False, f"装钉版依赖失败：{(p.stderr or p.stdout).strip()[-300:]}", f"{py} -m pip install " + " ".join(f"-r {r}" for r in REQS))
            return None
    p = run([py, "-c", IMPORTS + "; import sys; print(sys.version.split()[0])"])
    if p.returncode != 0:
        row("构建 venv", False, f"{py} 缺包：{p.stderr.strip().splitlines()[-1] if p.stderr.strip() else ''}", f"{py} -m pip install " + " ".join(f"-r {r}" for r in REQS))
        return None
    row("构建 venv", True, f"{py}（Python {p.stdout.strip()}；{'、'.join(REQS)} 已装齐）")
    return py


def prepare_rewriter_deps(check_only):
    sys.path.insert(0, str(ROOT))
    from pack import rewriter
    try:
        row("C 改写器固定依赖", True, str(rewriter.dependency_dir()))
        return
    except ValueError as e:
        message = str(e)
    target = ROOT / "build/rewriter-deps"
    if check_only:
        row("C 改写器固定依赖", False, message, f"python3 runtime/rewriter/prepare_deps.py {target.relative_to(ROOT)}")
        return
    if any(target.glob("*-*/")):   # prepare_deps.py 不覆盖已解开的目录：半截的要先挪走
        row("C 改写器固定依赖", False, f"{target} 里有不完整的旧内容", f"删掉 {target.relative_to(ROOT)} 后重跑本命令")
        return
    p = run([sys.executable, ROOT / "runtime/rewriter/prepare_deps.py", target])
    try:
        row("C 改写器固定依赖", p.returncode == 0, str(rewriter.dependency_dir()) if p.returncode == 0 else (p.stderr or p.stdout).strip()[-300:])
    except ValueError as e:
        row("C 改写器固定依赖", False, str(e))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--venv", type=Path, default=ROOT / "build/venv", help="构建用 Python 虚拟环境目录（缺省本树 build/venv）")
    ap.add_argument("--check", action="store_true", help="只检查，不建 venv、不下载")
    a = ap.parse_args()
    if not can_build_on(platform.system(), platform.machine()):
        print(f"🔴 Mac 启动器出包壳只支持 arm64 / x86_64 的 macOS，本机是 {platform.system()} {platform.machine()}")
        return 1
    if platform.machine() == "x86_64":
        print("ℹ️ Intel Mac：构建只出包壳与出包工具；s2arm-host 是 AArch64 原生执行体，不在本机起游戏。")
    dev = check_xcode()
    dav1d, why = dav1d_wanted(dev)
    row("AV1 解码路线", True, why)
    vpx, whyv = vpx_wanted(dev)
    row("VP9 解码路线", True, whyv)
    check_dotnet()
    brew = check_brew(dav1d)
    check_cargo()
    prepare_gmake(a.check)
    venv = a.venv.expanduser().resolve()
    py = prepare_venv(venv, brew, a.check)
    prepare_rewriter_deps(a.check)
    print()
    for name, ok, detail, fix in rows:
        print(f"{'✓' if ok else '✗'} {name}：{detail}")
        if fix and not ok:
            print("    → " + fix)
    bad = [r for r in rows if not r[1]]
    if bad:
        print(f"\n🔴 {len(bad)} 项没就绪：按上面「→」那行处理后重跑本命令")
        return 1
    print("\n✓ 构建依赖齐了。下一步：")
    print(f"  {py} launchers/macos/build_app.py        # 产物 build/macos/S2Arm.app（字体生成器与运行环境打包都用这个解释器）")
    print(f"  命令行出包 / 跑测试前：export S2A_PY={py}   （或写进 tools/machine.local：S2A_PY={py}）")
    if not (shutil.which("gmake") or os.environ.get("S2A_GMAKE")):
        print(f"  本机没有 gmake 时：export S2A_GMAKE={gmake_path()}   （出预编 iPhone 壳要 GNU Make 4）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
