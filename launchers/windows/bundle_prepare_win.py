#!/usr/bin/env python3
"""Windows 启动器发版预编件（11-06 维护者：玩家「几乎不用额外装依赖」，出包时现编的工具全部改成发版时预编、随启动器带）。
在 Windows 出包机（要 clang / clang++ / cmake / ninja / cargo / .NET 10 SDK / Git Bash，改写器另要 S2A_REWRITER_DEPS）上：
  python -X utf8 launchers/windows/bundle_prepare_win.py <目标>     → <目标>/Binaries/Prepare/（不许已存在：不混旧件）
出包作业设 S2A_PREBUILT_TOOLS=<目标>/Binaries/Prepare 后各使用方直接用预编件、不现编（同 Mac launchers/macos/bundle_engine.py 的口径与目录名）：
  romfs/romfs_index.dll                 RomFS 索引（pack/orch/stages.py、services/romfs_index.sh）
  dsh_batch/dsh_batch.dll + .src_digest + .xfp 直连出库 C# 批量进程（translator/dsh_batch.py，摘要同才用；.xfp 供没 SDK 的玩家机核库印章）
  devpush/s2a-devpush.exe               推资源包（tools/push_pack.py）
  rcodesign/rcodesign.exe + 许可        开发者证书签名（pack/jobs/devcert.py；官方发布件，SHA-256 钉死）
  dsx/dsx.dll                           直连翻译库（pack/orch/oneclick_win.py direct，graphics/dsx/dsx_win.py 编）
  nx_unpack/nx_unpack.exe + .src_digest 解包（oneclick_win.nx_unpack，身份 = nx_unpack_id）
  gamedec/gamedec.exe + .src_digest     游戏自带解码器工具模式（oneclick_win.gamedec，身份 = gamedec_id）
  codecs/yaz0enc-<哈希>.exe             Yaz0 编码器（graphics/widen/scan/ui_lyt.py；名字即源码身份，同现编缓存名）
  codecs/libyaz0dec_<摘要>.dll          Yaz0 解码库（graphics/tools/nxfmt.py；同上）
  codecs/glsl_es-<哈希>.exe             GLSL 改写工具（translator/gl_shaders.py es_tool；名字即源码身份，同现编名）
  spvc/libspvc_cli.dll、spvc/cli/bin/spirv-cross.exe + cli/versions.json、spvc/.src_digest
                                        spirv-cross 进程内库与命令行（translator/spvc_inproc.py，身份 = prebuilt_id）
  rewriter/s2a-rewrite.exe + .source    C 改写器（pack/rewriter.py bundled，.source = 源码指纹，同 Mac Runtime/bin 那份的规矩）
  glslang/glslangValidator.exe          OpenGL 款离线翻译（graphics/third_party/glslang/build_cli_win.sh 编；oneclick_win 交 GLSLANG，--check 核版本）
  prepare.json                          逐文件大小 + sha256（同 Mac bundle_engine.write_manifest 的 prepare.json 格式；source = 本提交号）
C# 件是 framework-dependent（dotnet build -o，不自包含）：玩家机要 .NET 10 运行时（随启动器带，DOTNET_ROOT 指过去）。
各件按「与使用方同一个现编函数 / 同一个身份函数」出：现编缓存先清掉 S2A_PREBUILT_TOOLS 等覆盖变量再编，编好拷进来。日志在 <仓库>/build/windows/prepare-logs/。
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "pack/jobs"))
sys.path.insert(0, str(ROOT / "translator"))
from core import atomic, digest   # noqa: E402  与 Mac 清单同一套写法
from pack.orch import oneclick_win   # noqa: E402
from pack import rewriter   # noqa: E402

LOGS = ROOT / "build/windows/prepare-logs"
NOPDB = shutil.ignore_patterns("*.pdb")


def run(args, log, env=None):
    LOGS.mkdir(parents=True, exist_ok=True)
    with open(LOGS / log, "w", encoding="utf-8", newline="\n") as f:
        p = subprocess.run([str(a) for a in args], stdout=f, stderr=subprocess.STDOUT, cwd=ROOT, env=env)
    if p.returncode:
        tail = (LOGS / log).read_text(encoding="utf-8", errors="replace").strip().splitlines()[-5:]
        raise SystemExit(f"【红】{log}：rc={p.returncode}\n" + "\n".join(tail))


def dotnet_build(project, out, log, *extra):
    # -r win-x64（仍是 framework-dependent）：只带 Windows x64 的原生库。不给 RID 时 NuGet 包的 runtimes/ 全平台照抄
    #   （0.2.8 romfs 带了 SkiaSharp 等 17 个平台共 193 MB，玩家只用得到 win-x64 的 11 MB）
    run(["dotnet", "build", ROOT / project, "-c", "Release", "-nologo", "-p:UseSharedCompilation=false", "-r", "win-x64", "--self-contained", "false",
         *extra, "-o", out], log)


def copy_dir(src, dst):
    shutil.copytree(src, dst, ignore=NOPDB)


def stamp(directory, ident):
    (directory / ".src_digest").write_text(ident + "\n", encoding="utf-8", newline="\n")


def bundle(target):
    tools = Path(target).resolve() / "Binaries/Prepare"
    if tools.exists():
        raise SystemExit(f"【红】{tools} 已存在：换个空目标，不混旧件")
    for k in ("S2A_PREBUILT_TOOLS", "S2A_REWRITER_C", "S2A_REWRITER_BUNDLED", "NXFMT_YAZ0LIB", "NXFMT_YAZ0"):
        os.environ.pop(k, None)   # 编的是本仓库源码的现编件，不许被覆盖变量换成别的
    # 发布进包的 .NET 程序集不带出包机路径（同 Mac bundle_engine：PathMap 把仓库根写成 /_/）
    os.environ["PathMap"] = "%s=/_/" % ROOT
    stage = ROOT / "build/windows/prepare"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    tools.mkdir(parents=True)

    dotnet_build("services/romfs_index/romfs_index.csproj", stage / "romfs", "romfs.log")
    copy_dir(stage / "romfs", tools / "romfs")

    dotnet_build("graphics/tools/direct/dsh/batch/dsh_batch.csproj", stage / "dsh_batch", "dsh_batch.log")
    copy_dir(stage / "dsh_batch", tools / "dsh_batch")
    import dsh_batch
    stamp(tools / "dsh_batch", dsh_batch.src_digest(os.path.join(dsh_batch.DSH, "batch", "dsh_batch.csproj")))
    # 同一份源码的翻译器指纹（同 Mac bundle_engine.py）：玩家机只带 .NET 运行时、展不开 DshXfpInput 清单，direct_lib.sh 出库后核库印章取这份当「本树」值
    #   （dmsh_chain.tree_xfp ← dsh_batch.prebuilt_xfp，摘要相同才认）。与预编件自报的编译期 Xfp 不同 = 预编件没按这份源码编，当场停
    import dmsh_chain
    xfp = dmsh_chain.xlate_fp()
    got = subprocess.run(["dotnet", str(tools / "dsh_batch/dsh_batch.dll"), "--xfp"], check=True, capture_output=True, text=True).stdout.strip()
    if got != xfp:
        raise SystemExit(f"【红】预编 dsh_batch 自报翻译器指纹 {got}，本仓库源码算出 {xfp}")
    (tools / "dsh_batch/.xfp").write_text(xfp + "\n", encoding="utf-8")

    dotnet_build("pack/nx_unpack/nx_unpack.csproj", stage / "nx_unpack", "nx_unpack.log")
    copy_dir(stage / "nx_unpack", tools / "nx_unpack")
    stamp(tools / "nx_unpack", oneclick_win.nx_unpack_id())

    dotnet_build("pack/gamedec/gamedec.csproj", stage / "gamedec", "gamedec.log")
    copy_dir(stage / "gamedec", tools / "gamedec")
    stamp(tools / "gamedec", oneclick_win.gamedec_id())

    # --locked：按仓库里的 Cargo.lock 取依赖（同 Mac）
    # 静态 C 运行库（crt-static）：玩家机不用另装 VC++ 运行库（11-06 维护者批 MSVC 运行库优先静态链接）
    run(["cargo", "build", "--release", "--locked", "--manifest-path", ROOT / "pack/devpush/Cargo.toml", "--target-dir", ROOT / "build/devpush-static"], "devpush.log",
        env=dict(os.environ, RUSTFLAGS=(os.environ.get("RUSTFLAGS", "") + " -C target-feature=+crt-static").strip()))
    (tools / "devpush").mkdir()
    shutil.copy2(ROOT / "build/devpush-static/release/s2a-devpush.exe", tools / "devpush/s2a-devpush.exe")

    # 开发者证书签名工具 rcodesign（apple-codesign 官方发布件，版本 / SHA-256 钉在 pack/jobs/devcert.py，不符拒打；v0.2.4）
    import devcert
    devcert.fetch_rcodesign(tools / "rcodesign", "win")

    (tools / "dsx").mkdir()
    run([sys.executable, "-X", "utf8", ROOT / "graphics/dsx/dsx_win.py", stage / "dsx/dsx.dll"], "dsx.log")
    shutil.copy2(stage / "dsx/dsx.dll", tools / "dsx/dsx.dll")

    # Yaz0 编 / 解：调使用方自己的现编函数（同一命令行、同一名字），编不出就红（使用方那边是悄悄退回纯 Python / 只写字面量）
    (tools / "codecs").mkdir()
    sys.path.insert(0, str(ROOT / "graphics/widen/scan")); sys.path.insert(0, str(ROOT / "graphics/tools"))
    import ui_lyt, nxfmt
    ui_lyt.yaz0_pack(b"prepare encoder" * 8, b"Yaz0" + bytes(12))
    if not ui_lyt._ENC or not os.path.isfile(ui_lyt._ENC):
        raise SystemExit("【红】Yaz0 编码器编不出（graphics/widen/scan/yaz0enc.c，要 clang 或 CC）")
    shutil.copy2(ui_lyt._ENC, tools / "codecs" / ui_lyt.yaz0enc_name())
    lib = nxfmt._compile_lib()
    if not lib:
        raise SystemExit("【红】Yaz0 解码库编不出（graphics/tools/yaz0dec.c，要 cc / clang）")
    shutil.copy2(lib, tools / "codecs" / os.path.basename(lib))
    sys.path.insert(0, str(ROOT / "graphics/tools/shbake"))
    import nxsh_extract
    lib = nxsh_extract.cri_compile()   # 编不出 CalledProcessError / FileNotFoundError 当场红（玩家机器没有编译器）
    shutil.copy2(lib, tools / "codecs" / os.path.basename(lib))
    # GLSL 改写工具（graphics/nvn/gfx/gl/gl_glsl_es.c 命令行入口；translator/gl_shaders.py es_tool 现编同一命令行、同一名字）：
    #   #852 玩家机没有 C 编译器时 OpenGL 款离线库只剩表头、全部落到运行时现编；编不出就红
    import gl_shaders
    try:
        shutil.copy2(gl_shaders.es_tool(), tools / "codecs" / gl_shaders.es_name())
    except (ValueError, OSError) as e:
        raise SystemExit(f"【红】GLSL 改写工具编不出（graphics/nvn/gfx/gl/gl_glsl_es.c，要 cc / clang 或 CC）：{e}")

    import spvc_inproc
    (tools / "spvc/cli/bin").mkdir(parents=True)
    shutil.copy2(spvc_inproc.lib_path(), tools / "spvc" / spvc_inproc.LIB)
    cli = Path(spvc_inproc.cli_path())
    shutil.copy2(cli, tools / "spvc/cli/bin" / spvc_inproc.CLI)
    shutil.copy2(cli.parent.parent / "versions.json", tools / "spvc/cli/versions.json")   # dmsh_chain.spirv_cross_identity 按它认版本
    stamp(tools / "spvc", spvc_inproc.prebuilt_id())

    exe = rewriter.c_path()   # 要 S2A_REWRITER_DEPS（Capstone / LZ4 固定依赖）与 cmake
    (tools / "rewriter").mkdir()
    name = "s2a-rewrite.exe" if os.name == "nt" else "s2a-rewrite"
    shutil.copy2(exe, tools / "rewriter" / name)
    (tools / "rewriter" / (name + ".source")).write_text(rewriter.source_digest() + "\n", encoding="utf-8", newline="\n")

    bash = oneclick_win.bash_exe()
    if not bash:
        raise SystemExit("【红】没有 Git Bash（glslang 构建脚本要它）")
    p = subprocess.run([bash, ROOT / "graphics/third_party/glslang/build_cli_win.sh"], capture_output=True, text=True, cwd=ROOT)
    if p.returncode:
        raise SystemExit("【红】glslangValidator 编不出：" + (p.stdout + p.stderr).strip()[-500:])
    (tools / "glslang").mkdir()
    shutil.copy2(p.stdout.strip().splitlines()[-1], tools / "glslang/glslangValidator.exe")

    files = write_manifest(tools)
    shutil.rmtree(stage, ignore_errors=True)
    return tools, files


def write_manifest(tools):
    """prepare.json：逐文件大小 + sha256（同 Mac bundle_engine.write_manifest 的格式），source = 本提交号（工作树有改动加 +dirty）"""
    head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True, check=True).stdout.strip()
    files = {p.relative_to(tools).as_posix(): [p.stat().st_size, digest(p)] for p in sorted(tools.rglob("*")) if p.is_file() and p.name != "prepare.json"}
    atomic(tools / "prepare.json", dict(schema=1, source=head + ("+dirty" if dirty else ""), files=files))
    return files


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0].startswith("-"):
        raise SystemExit(__doc__)
    tools, files = bundle(argv[0])
    for rel, (size, sha) in files.items():
        print(f"{size}\t{sha}\t{rel}")
    print(f"🟢 预编件 {len(files)} 个文件 → {tools}（清单 prepare.json）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
