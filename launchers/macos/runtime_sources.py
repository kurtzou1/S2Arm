#!/usr/bin/env python3
"""Mac 随包 Python、SPIRV 工具、zstd 与 bash 的钉版来源。

Homebrew 瓶子跟着出包机的系统走，在 macOS 26 上取到的程序最低系统也是 26，而 App 声明支持 15。
这里改用 python-build-standalone（官方构建，最低 macOS 11）和按 tools/toolchain.env 的部署目标从源码编的 SPIRV 工具、zstd、bash。
bash（11-28）：原先拷出包机 Homebrew 的 bash，热缓存里一直留着早年 macOS 15 上编的 5.2.37，冷缓存出包时拷到的是
macOS 26 瓶子（bash 5.3 + Homebrew readline / ncurses，最低系统 26），最低系统检查红。现按 GNU 源码 5.2 + 官方补丁 001–037
编（即已发版本随包的 5.2.37），用 bash 自带的 readline、链系统 libncurses，不再依赖 Homebrew。
下载校验 sha256，产物按版本和部署目标缓存在 build/macos/runtime-sources。全部要下的文件见 downloads()（出包机预取按它取）。
"""
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
from hashlib import sha256

ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = ROOT / "build/macos/runtime-sources"
SPIRV_TOOLS_VERSION, SPIRV_CROSS_VERSION, GLSLANG_VERSION, ZSTD_VERSION = "1.4.357.0", "1.4.363.0", "16.6.0", "1.5.7"
BASH_VERSION, BASH_PATCHLEVEL = "5.2", 37
PYTHONS = {
    "arm64": dict(url="https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only_stripped.tar.gz",
                  sha256="353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e"),
    "x86_64": dict(url="https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-x86_64-apple-darwin-install_only_stripped.tar.gz",
                   sha256="37c38fda76fec1fbf310adcbafb7f0d96af13b5511bf8ea954c3aa8eec185734"),
}
# 兼容旧调用方：默认仍是 Apple Silicon 的那一份，实际构建一律走 python_spec()
PYTHON = PYTHONS["arm64"]


def host_arch():
    """本机架构；x86_64 只用于出包启动器，不用于跑游戏宿主。"""
    arch = platform.machine()
    if arch not in PYTHONS:
        raise RuntimeError(f"Mac 启动器运行环境只支持 arm64 / x86_64，本机是 {arch}")
    return arch


def python_spec():
    return PYTHONS[host_arch()]


def wheel_platform():
    return "macos_arm64" if host_arch() == "arm64" else "macos_x64"
SOURCES = {
    "zstd": dict(url=f"https://github.com/facebook/zstd/releases/download/v{ZSTD_VERSION}/zstd-{ZSTD_VERSION}.tar.gz",
                 sha256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"),
    "spirv-headers": dict(url=f"https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-{SPIRV_TOOLS_VERSION}.tar.gz",
                          sha256="4d703067a7e06331ccb37bdfed3f9b7879cc61969a2689ae95c95db34a47ff07"),
    "spirv-tools": dict(url=f"https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/vulkan-sdk-{SPIRV_TOOLS_VERSION}.tar.gz",
                        sha256="d31e7109b6ef3559067e53e520870eafed7c9534d00db9728814b6df03fa4a5e"),
    "glslang": dict(url=f"https://github.com/KhronosGroup/glslang/archive/refs/tags/{GLSLANG_VERSION}.tar.gz",
                    sha256="9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2"),
    "spirv-cross": dict(url=f"https://github.com/KhronosGroup/SPIRV-Cross/archive/refs/tags/vulkan-sdk-{SPIRV_CROSS_VERSION}.tar.gz",
                        sha256="f708982e88b763ef5b0394ed468fc2c3628f68cdab89f2e7a946cd628c04e721"),
    "bash": dict(url=f"https://ftp.gnu.org/gnu/bash/bash-{BASH_VERSION}.tar.gz",
                 sha256="a139c166df7ff4471c5e0733051642ee5556c1cc8a4a78f145583c5c81ab32fb"),
}
# GNU 官方补丁（bash52-001 … 037，-p0 依次打）；sha256 与 Homebrew 配方 bash 5.2.37 版（homebrew-core d21387ca5）逐个一致
BASH_PATCH_SHA256 = {
    "001": "f42f2fee923bc2209f406a1892772121c467f44533bedfe00a176139da5d310a",
    "002": "45cc5e1b876550eee96f95bffb36c41b6cb7c07d33f671db5634405cd00fd7b8",
    "003": "6a090cdbd334306fceacd0e4a1b9e0b0678efdbbdedbd1f5842035990c8abaff",
    "004": "38827724bba908cf5721bd8d4e595d80f02c05c35f3dd7dbc4cd3c5678a42512",
    "005": "ece0eb544368b3b4359fb8464caa9d89c7a6743c8ed070be1c7d599c3675d357",
    "006": "d1e0566a257d149a0d99d450ce2885123f9995e9c01d0a5ef6df7044a72a468c",
    "007": "2500a3fc21cb08133f06648a017cebfa27f30ea19c8cbe8dfefdf16227cfd490",
    "008": "6b4bd92fd0099d1bab436b941875e99e0cb3c320997587182d6267af1844b1e8",
    "009": "f95a817882eaeb0cb78bce82859a86bbb297a308ced730ebe449cd504211d3cd",
    "010": "c7705e029f752507310ecd7270aef437e8043a9959e4d0c6065a82517996c1cd",
    "011": "831b5f25bf3e88625f3ab315043be7498907c551f86041fa3b914123d79eb6f4",
    "012": "2fb107ce1fb8e93f36997c8b0b2743fc1ca98a454c7cc5a3fcabec533f67d42c",
    "013": "094b4fd81bc488a26febba5d799689b64d52a5505b63e8ee854f48d356bc7ce6",
    "014": "3ef9246f2906ef1e487a0a3f4c647ae1c289cbd8459caa7db5ce118ef136e624",
    "015": "ef73905169db67399a728e238a9413e0d689462cb9b72ab17a05dba51221358a",
    "016": "155853bc5bd10e40a9bea369fb6f50a203a7d0358e9e32321be0d9fa21585915",
    "017": "1c48cecbc9b7b4217990580203b7e1de19c4979d0bd2c0e310167df748df2c89",
    "018": "4641dd49dd923b454dd0a346277907090410f5d60a29a2de3b82c98e49aaaa80",
    "019": "325c26860ad4bba8558356c4ab914ac57e7b415dac6f5aae86b9b05ccb7ed282",
    "020": "b6fc252aeb95ce67c9b017d29d81e8a5e285db4bf20d4ec8cdca35892be5c01d",
    "021": "8334b88117ad047598f23581aeb0c66c0248cdd77abc3b4e259133aa307650cd",
    "022": "78b5230a49594ec30811e72dcd0f56d1089710ec7828621022d08507aa57e470",
    "023": "af905502e2106c8510ba2085aa2b56e64830fc0fdf6ee67ebb459ac11696dcd3",
    "024": "971534490117eb05d97d7fd81f5f9d8daf927b4d581231844ffae485651b02c3",
    "025": "5138f487e7cf71a6323dc81d22419906f1535b89835cc2ff68847e1a35613075",
    "026": "96ee1f549aa0b530521e36bdc0ba7661602cfaee409f7023cac744dd42852eac",
    "027": "e12a890a2e4f0d9c6ec1ce65b73da4fe116c8e4209bac8ac9dc4cd96f486ab39",
    "028": "6042780ba2893daca4a3f0f9b65728592cd7bb6d4cebe073855a6aad4d63aac1",
    "029": "125cacb37e625471924b3ee06c54cb1bf21b3b7fe0e569d24a681b0ec4a29987",
    "030": "c3ff73230e123acdb5ac216921a386df8f74340459533d776d02811a1f76698f",
    "031": "c2d1b7be2df771126105020af7fafa00fffd4deff4a4e45d60fc6a235bcba795",
    "032": "7b9c77daeca93ff711781d7537234166e83ed9835ce1ee7dcd5742319c372a16",
    "033": "013ec6cc10ad98060a7c34ed5c11187bcc5bf4510f32de0d545db89a9a52a2e2",
    "034": "899fbb3b338048fe52a9c8252bf65ef1194cdff4f7a3fb3316f5f2396143232e",
    "035": "821a0a47fa692bb0a39482728b1b396bf951e2912768fea6f3026c813c1913e5",
    "036": "15c93f4936a5e5b88301f3ede767a23d3dd19635af2f3a91fb4cc0e560ca9057",
    "037": "8a2c1c3b5125d9ae5b47882f7d2ddf9648805f8c67c13aa5ea7efeac475cda94",
}
BASH_PATCHES = {f"bash52-{n}": dict(url=f"https://ftp.gnu.org/gnu/bash/bash-{BASH_VERSION}-patches/bash52-{n}", sha256=h)
                for n, h in sorted(BASH_PATCH_SHA256.items())}


def deployment_target():
    """App 声明的最低 macOS，唯一来源是 tools/toolchain.env。"""
    match = re.search(r"^MACOSX_DEPLOYMENT_TARGET=(\d+(?:\.\d+)*)\s*$", (ROOT / "tools/toolchain.env").read_text(), re.M)
    if not match:
        raise RuntimeError("tools/toolchain.env has no MACOSX_DEPLOYMENT_TARGET")
    return match[1]


def downloads():
    """本机出 Mac 运行时要下的全部文件：[(url, sha256, 缓存路径)]。出包机预取（离线 / 冷缓存）按这张表取，不另抄文件名规则。"""
    return ([(python_spec()["url"], python_spec()["sha256"], _target("python"))] +
            [(s["url"], s["sha256"], _target(n)) for n, s in SOURCES.items()] +
            [(s["url"], s["sha256"], _target(n, "")) for n, s in BASH_PATCHES.items()])


def _target(name, ext=".tar.gz"):
    return CACHE / "downloads" / (name + ext)


def _download(name, spec, ext=".tar.gz"):
    target = _target(name, ext)
    target.parent.mkdir(parents=True, exist_ok=True)
    def good():
        return target.is_file() and sha256(target.read_bytes()).hexdigest() == spec["sha256"]
    if not good():
        target.unlink(missing_ok=True)
        subprocess.run(["curl", "-fsSL", "--retry", "5", "--retry-all-errors", "-o", str(target), spec["url"]], check=True)
    if not good():
        raise RuntimeError(f"{name}: sha256 does not match the pinned value")
    return target


def _unpack(name, spec, dest):
    archive = _download(name, spec)
    # 先用系统 tar 验证包能读，再删旧目录：精简版随包 Python 可能没有 gzip 模块，
    # 用 Python tarfile 读会在删掉缓存之后才报 ReadError，把 venv 的基准解释器一起毁掉。
    subprocess.run(["tar", "-tzf", str(archive)], check=True, stdout=subprocess.DEVNULL)
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    subprocess.run(["tar", "-xzf", str(archive), "-C", str(dest)], check=True)
    return next(p for p in dest.iterdir() if p.is_dir())


def python():
    """解开的独立 Python 目录（bin/python3.12、lib/python3.12）。"""
    arch, spec = host_arch(), python_spec()
    # 文件名不加架构：切架构时 SHA 不同，stamp 与解压目录一起重做；本机已有的 x86_64 缓存可直接命中
    stamp, dest = CACHE / "python.stamp", CACHE / "python"
    wanted = f"{arch}:{spec['sha256']}"
    if stamp.is_file() and stamp.read_text() == wanted and (dest / "python/bin/python3.12").is_file():
        return dest / "python"
    root = _unpack("python", spec, dest)
    stamp.write_text(wanted)
    return root


def _cmake(source, build, prefix, target, *options):
    os.environ["GIT_CEILING_DIRECTORIES"] = str(CACHE.parent)   # 源码包解在本仓库 build/ 下：别让 SPIRV 工具把本仓库的 git 版本号写进程序
    subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={prefix}",
                    f"-DCMAKE_OSX_DEPLOYMENT_TARGET={target}", f"-DCMAKE_OSX_ARCHITECTURES={host_arch()}", f"-DCMAKE_PREFIX_PATH={prefix}",
                    "-DBUILD_SHARED_LIBS=OFF", *options], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["cmake", "--build", str(build), "--parallel", "6"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["cmake", "--install", str(build)], check=True, stdout=subprocess.DEVNULL)


def _bash(source, prefix, target):
    """bash 按钉版补丁打好、按部署目标编进 prefix/bin/bash。readline 用源码自带那份，终端库链系统 libncurses，不碰 Homebrew。"""
    for name in BASH_PATCHES:
        with _download(name, BASH_PATCHES[name], "").open("rb") as patch:
            subprocess.run(["patch", "-p0", "-s"], cwd=source, stdin=patch, check=True)
    arch = host_arch()
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", MACOSX_DEPLOYMENT_TARGET=target,   # PATH 只留系统：configure 不许摸到 Homebrew 的工具和库
               CC="cc", CFLAGS=f"-O2 -arch {arch} -mmacosx-version-min={target}", LDFLAGS=f"-arch {arch} -mmacosx-version-min={target}")
    for k in ("CPPFLAGS", "LIBRARY_PATH", "CPATH", "PKG_CONFIG_PATH"):
        env.pop(k, None)
    # strchrnul：新 SDK 里有、macOS 15.4 前的系统没有。configure（AC_REPLACE_FUNCS）按 SDK 判「有」就弱引用系统那份，
    #   15.0–15.3 上解析成空、一调就崩；最低系统检查只看 minos 抓不到。一律用源码自带的 lib/sh/strchrnul.c
    env["ac_cv_func_strchrnul"] = "no"
    subprocess.run(["./configure", f"--prefix={prefix}", "--with-curses", "--disable-nls", "--without-installed-readline"],
                   cwd=source, env=env, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["make", "-j6", "bash"], cwd=source, env=env, check=True, stdout=subprocess.DEVNULL)
    weak = [l.split()[-3] for l in subprocess.run(["nm", "-m", str(source / "bash")], capture_output=True, text=True, check=True).stdout.splitlines()
            if "weak external" in l and "(undefined)" in l]
    if weak:   # 弱引用 = 用到比部署目标新的系统函数：老系统上是空指针。configure 新判出一个就要像 strchrnul 一样关掉
        raise RuntimeError(f"【红】bash 弱引用了比 macOS {target} 新的系统函数：{', '.join(weak)}（在 _bash 里按 ac_cv_func_<名>=no 关掉）")
    (prefix / "bin").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "bash", prefix / "bin/bash")


def tools():
    """静态编译 SPIRV 工具、zstd，并编 bash，返回 (安装前缀, {名字: 源码目录})。"""
    target = deployment_target()
    key = json.dumps(dict(arch=host_arch(), target=target, sources={k: v["sha256"] for k, v in SOURCES.items()},
                          patches={k: v["sha256"] for k, v in BASH_PATCHES.items()}), sort_keys=True)
    stamp, source_root, prefix, build = CACHE / "tools.stamp", CACHE / "src", CACHE / "tools", CACHE / "build"
    folders = {name: next((p for p in (source_root / name).iterdir() if p.is_dir()), None) for name in SOURCES} if stamp.is_file() and stamp.read_text() == key else None
    if folders and all(folders.values()) and all((prefix / "bin" / n).is_file() for n in ("spirv-as", "spirv-val", "glslangValidator", "spirv-cross", "zstd", "bash")):
        return prefix, folders
    for path in (stamp, ):
        path.unlink(missing_ok=True)
    shutil.rmtree(prefix, ignore_errors=True); shutil.rmtree(build, ignore_errors=True)
    folders = {name: _unpack(name, spec, source_root / name) for name, spec in SOURCES.items()}
    _cmake(folders["spirv-headers"], build / "headers", prefix, target)
    _cmake(folders["spirv-tools"], build / "tools", prefix, target, f"-DSPIRV-Headers_SOURCE_DIR={folders['spirv-headers']}", "-DSPIRV_SKIP_TESTS=ON", "-DSPIRV_WERROR=OFF")
    # Apple Clang places /usr/local/include ahead of imported -isystem paths.
    # A stale Homebrew SPIRV-Tools header there otherwise shadows the pinned
    # headers used by this release runtime.
    _cmake(folders["glslang"], build / "glslang", prefix, target, "-DENABLE_OPT=ON", "-DALLOW_EXTERNAL_SPIRV_TOOLS=ON", "-DGLSLANG_TESTS=OFF",
           f'-DCMAKE_CXX_FLAGS=-iquote"{prefix}/include"')
    _cmake(folders["spirv-cross"], build / "cross", prefix, target, "-DSPIRV_CROSS_SHARED=OFF", "-DSPIRV_CROSS_CLI=ON", "-DSPIRV_CROSS_ENABLE_TESTS=OFF")
    # libzstd.1.dylib 要随包（graphics/tools/shbake/zstd_lib.py 用 ctypes 加载），其余压缩库不链，Homebrew 版会带上 macOS 26 的 liblzma
    _cmake(folders["zstd"] / "build/cmake", build / "zstd", prefix, target, "-DZSTD_BUILD_SHARED=ON", "-DZSTD_BUILD_STATIC=OFF", "-DZSTD_PROGRAMS_LINK_SHARED=ON",
           "-DZSTD_BUILD_TESTS=OFF", "-DZSTD_LZMA_SUPPORT=OFF", "-DZSTD_LZ4_SUPPORT=OFF", "-DZSTD_ZLIB_SUPPORT=OFF")
    _bash(folders["bash"], prefix, target)
    stamp.write_text(key)
    return prefix, folders
