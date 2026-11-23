#!/usr/bin/env python3
"""Build a development Mac launcher bundle; never bundles games or player data."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from bundle_engine import bundle, seal_runtime
from runtime_audit import declared_minimum_macos, verify_minimum_macos, verify_portable_runtime
import runtime_sources
from bundle_runtime import TOOLS, runtime_deps_fingerprint
import frontend_layout

ROOT = Path(__file__).resolve().parents[2]


def bundle_plumesign(resources, cache=None, fetch=None):
    """Impactor 同版 plumesign 的 macOS 版随启动器（0.6.0 通用壳：Mac 的 Apple ID 用它登录、签名，pack/jobs/install.py mac_plume）：
    放 Resources/<impactor.BUNDLE_DIR>/。用的是我们自编的修改版（上游 v{TESTED} + launchers/windows/third_party/impactor/patches/，
    tools/plumesign_build.py 编，同 Windows 打包 launchers/windows/bundle_win.py impactor_cache 同一个缓存目录）。缓存有就用，没有从固定来源
    impactor.OWN_RELEASE（我们公开仓的 Release）下到缓存；SHA-256 不等于 impactor.BUNDLED_MAC 拒打（impactor.own_artifact）。发版时 sign_release.sh 按文件头认 Mach-O、用我们的 Developer ID 重签外层签名（公证要求），内容不改"""
    sys.path.insert(0, str(ROOT / "pack/jobs")); import impactor
    cache = Path(cache or os.environ.get("S2A_IMPACTOR_CACHE") or Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run")
                 / "s2arm/cache/impactor" / f"v{impactor.TESTED}-{impactor.OWN_BUILD}")
    dest = Path(resources) / impactor.BUNDLE_DIR
    dest.mkdir(parents=True, exist_ok=True)
    for name, want in impactor.BUNDLED_MAC.items():
        try:
            src = Path(impactor.own_artifact(name, want, cache, fetch))
        except impactor.OwnBuildError as e:
            raise SystemExit(f"【红】{e}")
        shutil.copy2(src, dest / name); (dest / name).chmod(0o755)
    lic = ROOT / "launchers/windows/third_party/impactor"
    for f in sorted(lic.glob("LICENSE-*.txt")):
        shutil.copy2(f, dest / f.name)
    patches = sorted((lic / "patches").glob("*.patch"))
    for f in patches:
        shutil.copy2(f, dest / f.name)
    (dest / "README-来源与许可.txt").write_text("\n".join([
        f"plumesign v{impactor.TESTED}（Impactor 的命令行，第三方开源工具，作者 Samara M / claration，MIT 许可：LICENSE-Impactor-MIT.txt）的修改版，"
        "用于以你的 Apple ID 登录苹果开发者服务、签名并把 S2Arm 装到你的 iPhone；密码只交给它向 Apple 登录，S2Arm 不保存。",
        f"S2Arm 基于上游 v{impactor.TESTED} 源码打上以下补丁后自行编译（随附补丁原文）：" + "、".join(f.name for f in patches),
        f"上游源码：{impactor.SOURCE_TREE}",
        "其中内嵌的 apple-codesign 0.29.0（未修改）以 MPL-2.0 发布（LICENSE-apple-codesign-MPL-2.0.txt），源码：",
        f"  {impactor.SOURCE_TREE}/3rdparty/apple-codesign-0.29.0", ""]), encoding="utf-8")


def copy_launcher_resources(bindir, resources):
    """Copy SwiftPM resources and verify the shipped document is the shared original.
    两个前端都要：作业层文字的翻译（Localizable.json + 共享体验规格）在适配层资源包里（BackendText，.app 里只认 Resources 下这份）。"""
    source_bundle = bindir / "S2ArmAppleAdapter_S2ArmAppleAdapter.bundle"
    specifications = list(source_bundle.rglob("experience.v1.json"))
    if len(specifications) != 1 or specifications[0].is_symlink():
        raise SystemExit("SwiftPM 资源包必须包含一份普通文件形式的共享体验规格")
    if len(list(source_bundle.rglob("Localizable.json"))) != 1:
        raise SystemExit("SwiftPM 资源包必须包含一份作业层文字对照表 Localizable.json")
    relative = specifications[0].relative_to(source_bundle)
    for p in bindir.glob("*.bundle"):
        shutil.copytree(p, resources / p.name)
    for name in ("experience.v1.json", "game_settings.v1.json"):   # 游戏设置定义表（启动设置页按它画）同样只认原件
        packaged = resources / source_bundle.name / relative.parent / name
        if packaged.is_symlink() or not packaged.is_file() or packaged.read_bytes() != (ROOT / "launchers/shared" / name).read_bytes():
            raise SystemExit("Mac 应用中的共享规格 %s 缺失或与源码不一致" % name)


def release_identity(engine_json):
    """版号与包号（10-24 维护者：本地 release 只靠签名分不出新旧，内测回报要填准包号）。
    短版本取最近 tag 的语义段（v0.1.0-beta.2 → 0.1.0；CFBundleShortVersionString 只收数字段），
    CFBundleVersion 取提交数（单调递增，装新包时系统认得出是更新），
    S2ABuildID 取 <短提交号>[-dirty]-<引擎源码指纹前 8>——与 pack/build_id.sh 的「提交号-包键」同一形状，
    设置页、诊断包和 AI 控制口 /help 读的都是这一个字段。"""
    def git(*args):
        try:
            return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True,
                                           stderr=subprocess.DEVNULL).strip()
        except (OSError, subprocess.CalledProcessError):
            return ""
    sys.path.insert(0, str(ROOT / "pack/jobs")); from core import release_version
    short_version = release_version(ROOT) or "0.1.0"   # 同 iPhone 容器、Windows 启动器（三端同号，pack/jobs/core.py）
    build = git("rev-list", "--count", "HEAD") or "1"
    commit = git("rev-parse", "--short=8", "HEAD") or "unknown"
    dirty = "-dirty" if git("status", "--porcelain", "--untracked-files=no") else ""
    try:
        source = json.loads(engine_json.read_text()).get("source", "")
    except (OSError, ValueError):
        source = ""
    # 顶栏版本号（11-11 维护者：玩家截图里要看得出是哪一版）：HEAD 正好是发版 tag 且没改动 = 正式版「v0.3.0」；
    #   否则是开发版「v<最近 tag>-dev+<短提交号>」。发版流程先在构建树上打 tag 再构建（release.sh），所以正式包落在 tag 上。同 Windows S2Arm.csproj
    #   测试版（11-19：0.6.0 测试包）：HEAD 落在预发布 tag（v0.6.0-test.1）上 → 顶栏「v0.6.0-test.1」（test 字样即测试版标记，中英文界面共用）；
    #   S2AVersion 记完整版本号（含预发布段）交给更新器比新旧（pack/jobs/updater.py version_key：测试版 < 同号正式版），
    #   CFBundleShortVersionString 只收数字段，测试版也是 0.6.0（系统看的仍是 CFBundleVersion 提交数）
    exact = git("describe", "--tags", "--exact-match", "HEAD")
    pre = re.fullmatch(r"v?" + re.escape(short_version) + r"-([0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)", exact) if not dirty else None
    release = not dirty and re.fullmatch(r"v?" + re.escape(short_version), exact)
    full = f"{short_version}-{pre[1]}" if pre else short_version
    display = f"v{short_version}" if release else f"v{full}" if pre else f"v{short_version}-dev+{commit[:7]}"
    return dict(CFBundleShortVersionString=short_version, CFBundleVersion=build, S2AVersion=full,
                S2ABuildID=f"{commit}{dirty}-{source[:8]}", S2ADisplayVersion=display)


def bundle_shell(engine_json, dest, env, apple_os="ios", sid=None):
    """iOS 预编壳随应用分发（11-07 启动器线：玩家打 iPhone 包不再现出壳 → 不要 .NET SDK；壳里的 NativeAOT C# 库只能用 SDK 编，与游戏无关、按提交编一次）。
    壳编号取引擎清单 shellId；出包机壳缓存（同 pack/ipa.sh：S2A_SHELL_CACHE 或 <运行区>/s2arm/cache/shell/<壳编号>）有就核清单后用，没有就 pack/shell_build.sh 现出进缓存。
    布局同 Windows 发版（launchers/windows/bundle_win.py）：Resources/Shell/{manifest.json, root/}；作业层 ipa.bundled_shell 交给 S2A_SHELL"""
    # Apple TV（0.5.2）：同一套出壳 / 核对，换 tvOS——壳号取 engine.json 的 shellIdTvos，缓存 <运行区>/s2arm/cache/shell-tvos/<壳号>（同 pack/jobs/tvos.py 开发树取法），
    #   SDK 换 appletvos，出壳带 S2A_APPLE_OS=tvos；放 Resources/Shell-tvOS（作业层 tvos.tv_shell 发版时读这里）
    tv = apple_os == "tvos"
    sid = sid or json.loads(Path(engine_json).read_text())["shellIdTvos" if tv else "shellId"]
    run = Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run")
    cache = (run / "s2arm/cache/shell-tvos" if tv else Path(os.environ.get("S2A_SHELL_CACHE") or run / "s2arm/cache/shell")) / sid
    sdk_name, label = ("appletvos", "tvOS") if tv else ("iphoneos", "iOS")
    env = dict(env, S2A_APPLE_OS="tvos") if tv else env
    # 玩家拿到的壳必须用本机装着的最新 iOS SDK 链接（11-07 Duo 定因：26.5 SDK 链接的壳在 iOS 27 新机型 iPhone Duo 上整个 App 按旧 iPhone 尺寸缩小居中）。
    #   壳编号不含编译器（跨平台要算得出），缓存里旧 SDK 出的同号壳当没命中、重出；出完再核一遍，不符报红不出 App
    sys.path.insert(0, str(ROOT / "pack/jobs")); from install import linked_sdk; from toolchain import detect_xcode
    newest = detect_xcode()
    want = subprocess.run(["xcrun", "--sdk", sdk_name, "--show-sdk-version"], env=dict(env, DEVELOPER_DIR=newest or env["DEVELOPER_DIR"]),
                          capture_output=True, text=True).stdout.strip()
    want = tuple(int(x) for x in (want.split(".") + ["0", "0"])[:3]) if want else None
    if not want:
        raise SystemExit(f"【红】读不到最新 Xcode（{newest}）的 {label} SDK 版本，发版壳无从核对")
    if env["DEVELOPER_DIR"] != newest:
        raise SystemExit(f"【红】发版要用装着的最新 Xcode（{newest}）出，这次选的是 {env['DEVELOPER_DIR']}：去掉 --developer-dir / S2A_DEVELOPER_DIR 重来")
    if (cache / "manifest.json").is_file() and linked_sdk(cache / "root/S2Arm") != want:
        print(f"壳缓存 {cache} 是 {label} SDK {linked_sdk(cache / 'root/S2Arm')} 出的，发版要 {want}：挪开重出")
        cache.rename(cache.parent / f".tmp.stale.{sid}.{os.getpid()}")   # 同 pack/ipa.sh：挪开不删（别的出包单可能正读它），.tmp.* 由维护方内部清扫器清
    if not (cache / "manifest.json").is_file():
        cache.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["bash", str(ROOT / "pack/shell_build.sh"), str(cache)], env=env, check=True)
    sys.path.insert(0, str(ROOT)); from pack.shell import manifest
    doc = manifest.verify(cache / "root", cache / "manifest.json")   # 逐文件核壳清单
    if doc["details"]["shellId"] != sid:
        raise SystemExit(f"【红】壳缓存 {cache} 的壳编号 {doc['details']['shellId']} 与引擎 {sid} 不符")
    if linked_sdk(cache / "root/S2Arm") != want:
        raise SystemExit(f"【红】发版壳 {cache} 链接的 {label} SDK 是 {linked_sdk(cache / 'root/S2Arm')}，不是本机最新 Xcode 的 {want}")
    print(f"发版{label}壳：{sid}，{label} SDK {'.'.join(map(str, want))}（{newest}）")
    if dest is None:   # 只备缓存（--shells-only）
        return cache
    shutil.copytree(cache, dest, symlinks=True)
    if os.environ.get("S2A_SYMBOLS_OUT") and (cache.parent / (cache.name + ".symbols")).is_dir():   # 壳的未去符号原件（pack/shell_build.sh 放在壳目录旁）随发版存档
        shutil.copytree(cache.parent / (cache.name + ".symbols"), Path(os.environ["S2A_SYMBOLS_OUT"]) / ("Shell-tvOS" if tv else "Shell"), dirs_exist_ok=True)


SPARKLE_FEED = "https://dl.s2arm.com/appcast/mac.xml"
SPARKLE_PUBLIC_KEY = "WoZkGLOTuLU2zl0gsPX+4sTKRsIN9ahBEfj0ulkqOqc="   # 验签公钥（Ed25519）；对应私钥只在发版机，不进仓库


def build_python():
    """出壳等子脚本用的 Python（S2A_PY）：调用方环境 → tools/machine.local（tools/machine.sh get，同出包链取法）→ 跑本脚本的解释器。
    pack/shell_build.sh 等用 ${S2A_PY:-python3}：不交就退到 PATH 上的 python3，那份不一定装了钉版依赖（11-20：tvOS 壳的 tv_icon.py 缺 PIL）；
    本脚本按 README 用 prepare_build.py 建的 venv 跑，同字体生成器缺省 os.sys.executable"""
    picked = subprocess.run(["bash", str(ROOT / "tools/machine.sh"), "get", "S2A_PY"], capture_output=True, text=True).stdout.strip()
    return picked or sys.executable


def main():
    os.environ["MACOSX_DEPLOYMENT_TARGET"] = runtime_sources.deployment_target()   # clang、cmake、rustc 都读它：包内自己编的程序不能比声明的系统高
    os.environ["S2A_PY"] = build_python()   # 出壳 / make / 工具链解析等子进程都拿同一个解释器（见 build_python）
    parser = argparse.ArgumentParser(description=__doc__)
    # 出前端用与门禁 / 出包同一套 Xcode：tools/toolchain.sh 解析（指定 / 本机配置 > xcode-select，10-25 起不读仓库里写的版本）
    picked = subprocess.run(["bash", "-c", 'S2A_TC_QUIET=1 source tools/toolchain.sh > /dev/null && printf %s "$DEVELOPER_DIR"'], cwd=ROOT, capture_output=True, text=True)
    parser.add_argument("--developer-dir", default=picked.stdout.strip() or None)
    # 只出壳（11-19 发版提速）：壳编号按提交算（pack.shell.manifest.current_id，与引擎清单 shellId 同源），把 iOS / tvOS 壳备进出包机壳缓存就退出，
    #   不建 App。发版脚本开局先单独跑它，Windows 拿到壳就能往下走，不必等整个 build_app；之后 build_app 照常跑、壳缓存命中
    parser.add_argument("--shells-only", action="store_true")
    args = parser.parse_args()
    # 出哪个前端（S2A_APP_FRONTEND，缺省 apple = S2Arm × NX2Apple；launcher = 旧启动器，留作回退）：见 frontend_layout.py
    front = frontend_layout.pick()
    print(f"前端：{front['key']}（{front['product']} → {front['app']}）")
    print(f"子脚本 Python（S2A_PY）：{os.environ['S2A_PY']}")
    if not args.developer_dir:
        raise SystemExit("🔴 没有可用的 Xcode：" + (picked.stderr.strip().splitlines() or ["tools/toolchain.sh 解析失败"])[-1])
    output = ROOT / "build/macos"
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir,
               CLANG_MODULE_CACHE_PATH=str(output / "clang-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / "swift-cache"))
    if args.shells_only:
        sys.path.insert(0, str(ROOT)); from pack.shell.manifest import current_id
        for apple_os in ("ios", "tvos"):
            cache = bundle_shell(None, None, env, apple_os, sid=current_id(apple_os))
            print(f"壳已出：{apple_os} {cache.name}")
        return
    sdk_version = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                                          env=env, text=True).strip()
    # Sparkle 二进制包不在仓库里（公开仓扫描不收二进制包）：构建前按钉死的校验值备到 frontend/Vendor/（本机缓存有就拷，没有下一次）
    subprocess.run([sys.executable, str(ROOT / "launchers/macos/sparkle_vendor.py")], check=True)
    # --disable-keychain：拉 Sparkle 二进制包时 SwiftPM 缺省去钥匙串找 github.com 凭据，钥匙串弹授权框等人点，无人值守的出包机就一直挂着（11-13 v0.3.10 候选卡 14 分钟）
    command = ["swift", "build", "--disable-sandbox", "--disable-keychain", "--cache-path", str(output / "spm-cache"),
               "--package-path", str(ROOT / "launchers/macos"), "--scratch-path", str(output / "spm"), "-c", "release",
               # 不把出包机的源码绝对路径（#filePath / 断言位置）编进发布版：只映射源码目录（整个仓库根会连带改写 build/ 下的模块缓存路径）
               "-Xswiftc", "-file-prefix-map", "-Xswiftc", f"{ROOT / 'launchers/macos/Sources'}=Sources",
               # Swift 驱动经 clang --sysroot 链接时可能把 SDK 版记成部署下限，触发旧式系统 UI。
               # 明确区分运行下限与实际链接 SDK；不提高 Package.swift 的 macOS 15 下限。
               "-Xlinker", "-platform_version", "-Xlinker", "macos",
               "-Xlinker", "15.0", "-Xlinker", sdk_version]
    subprocess.run(command, env=env, check=True)
    bindir = subprocess.check_output(command + ["--show-bin-path"], env=env, text=True).strip()
    linked = subprocess.check_output(["otool", "-l", str(Path(bindir) / front["executable"])],
                                     env=env, text=True)
    sdk_versions = re.findall(r"^\s+sdk (\S+)$", linked, flags=re.MULTILINE)
    normalized = lambda value: tuple((list(map(int, value.split("."))) + [0, 0])[:3])
    if not sdk_versions or any(normalized(value) != normalized(sdk_version) for value in sdk_versions):
        raise SystemExit(f"启动器链接 SDK 与 Xcode 不一致：{sdk_versions}，期望 {sdk_version}")
    app = output / front["app"].replace(".app", "-staging.app")
    if app.exists():
        shutil.rmtree(app)
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(Path(bindir) / front["executable"], macos / front["executable"])
    # 应用内更新（Sparkle 2，v0.3.10 起）：SwiftPM 把二进制包里的 Sparkle.framework 放在产物目录，原样（含符号链接）放进 Contents/Frameworks
    sparkle = Path(bindir) / "Sparkle.framework"
    if front["key"] == "apple":
        if not sparkle.is_dir():
            raise SystemExit(f"🔴 没找到 Sparkle.framework（{sparkle}）：swift build 没拉下 Sparkle 二进制包")
        (app / "Contents/Frameworks").mkdir(parents=True)
        shutil.copytree(sparkle, app / "Contents/Frameworks/Sparkle.framework", symlinks=True)
    # Switch 2 Pro 蓝牙连接由启动器旁的独立进程持有，游戏经本机通道读输入（docs/mac-switch2-pro.md）
    subprocess.run(["make", "-C", str(ROOT), "S2A_MAC_FRONTEND=1", "build/S2ArmNS2Connection"], env=env, check=True)
    shutil.copy2(ROOT / "build/S2ArmNS2Connection", macos / "S2ArmNS2Connection")
    copy_launcher_resources(Path(bindir), resources)
    if front["nx2apple_resources"]:
        print("前端资源：" + " ".join(frontend_layout.stage_apple_resources(ROOT, resources)))
    import jobs_bundle   # 作业层布局只此一份（门禁 tools/app_layout_check.py 用同一个函数搭布局）
    jobs_bundle.stage_jobs(ROOT, resources)
    bundle_plumesign(resources)
    # 补丁库随发版（补丁包部署方案 v2，满屏补丁线 11-04）：S2A_RELEASE_PATCHES 指本机补丁库（不进仓库），只收真机验过的（tools/patch_bundle.py）；
    #   启动器出包时 pack/jobs/core.py 见 Resources/Patches/INDEX.tsv 就把它交给 pack/stage_rewrite.sh。没给就不带、响亮说一行
    lib = os.environ.get("S2A_RELEASE_PATCHES")
    if lib:
        sys.path.insert(0, str(ROOT / "tools")); import patch_bundle
        took, skipped = patch_bundle.bundle(lib, str(resources / "Patches"))
        print(f"补丁库：收 {len(took)} 款（{' '.join(took) or '无'}），跳过 {len(skipped)} 款（没验过）")
    else:
        print("🟡 没设 S2A_RELEASE_PATCHES：本版启动器不带补丁库")
    # 社区补丁与金手指本地库（11-13 维护者：随启动器装在本地、云端兜底）：完整快照放 Resources/CommunityPatches/patches-v3.tar（v2 发版时转成分块 xz，11-16 瘦身），
    #   出包时 pack/jobs/patches.py 本地优先、按云端清单增量。来源 S2A_PATCH_SNAPSHOT（本机文件）> 下载站；取不到不挡打包（出包时照样向云端要）
    sys.path.insert(0, str(ROOT / "tools")); import patch_pack
    why = patch_pack.stage_snapshot(str(resources / "CommunityPatches"))
    print("社区补丁快照：" + ("已放进 Resources/CommunityPatches" if not why else f"🟡 {why}，本版启动器不带本地补丁库"))
    shutil.copytree(ROOT / "launchers/macos/gui_jobs", resources / "GUIJobs", ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "tests"))
    shutil.copy2(ROOT / "launchers/macos/README.md", resources / "README.md")
    # 给玩家的 AI 用（维护者 10-23）：控制客户端 + 说明；s2armctl 用 App 自带 Python 跑，玩家不用另装 Python
    shutil.copy2(ROOT / "launchers/macos/s2armctl.py", resources / "s2armctl.py")
    shutil.copytree(ROOT / "launchers/macos/skill", resources / "skill", dirs_exist_ok=True)   # 玩家自己的 AI 用的 skill（s2arm-operator，10-26）
    (resources / "s2armctl").write_text('#!/bin/sh\nR="$(cd "$(dirname "$0")" && pwd)"\nexec "$R/Runtime/python/bin/python3" -B -I "$R/s2armctl.py" "$@"\n')
    (resources / "s2armctl").chmod(0o755)
    # 内置 Python 一律带 -B：-I 会忽略 PYTHONDONTWRITEBYTECODE，不带 -B 就往 App 包里写 __pycache__，签名封存被破坏（11-02 beta.4 走查：
    #   AI 用 s2armctl 后 codesign 报「a sealed resource is missing or invalid」，系统按新身份看待 App，文件访问授权可能失效）
    shutil.copy2(ROOT / "launchers/macos/Branding/wordmark-transparent.png", resources / "wordmark-transparent.png")   # 没封面时的字标
    shutil.copy2(ROOT / "launchers/macos/Branding/s-gold.png", resources / "s-gold.png")   # 出包页 S 级优化卡片的金色 S（make_s_gold.py 由应用图标生成）
    # App 图标（#882 定稿 D「交错双柄」）
    subprocess.run(["bash", str(ROOT / "launchers/macos/make_icns.sh"), str(resources / "S2Arm.icns")], check=True)
    # 开源替代共享字体随应用分发（维护者 10-23：玩家不用找字体、不作检测项）：pack/fonts/make_open_fonts.py 生成（来源钉版本 + sha256，产物可重现），
    #   生成器依赖 fonttools / skia-pathops，默认使用当前构建 Python，可用 S2A_FONTS_PY 覆盖；生成器没变就复用上次产物
    fonts = output / "OpenFonts"
    gen = ROOT / "pack/fonts/make_open_fonts.py"
    stamp = fonts / ".generator.sha256"
    gen_hash = hashlib.sha256(gen.read_bytes()).hexdigest()
    if not (stamp.is_file() and stamp.read_text() == gen_hash and len(list(fonts.glob("*.bfttf"))) == 7):
        py = os.environ.get("S2A_FONTS_PY", os.sys.executable)
        subprocess.run([py, str(gen), str(fonts)], check=True)
        stamp.write_text(gen_hash)
    (resources / "Fonts").mkdir()
    for f in sorted(fonts.glob("*.bfttf")) + sorted(fonts.glob("OFL-*.txt")):
        shutil.copy2(f, resources / "Fonts" / f.name)
    shutil.copy2(ROOT / "pack/fonts/LICENSES.md", resources / "Fonts/LICENSES.md")
    runtime = output / "Runtime"
    expected = dict(line.split("==") for line in (ROOT / "launchers/macos/requirements-runtime.txt").read_text().splitlines() if "==" in line and not line.startswith("#"))
    versions = json.loads((runtime / "versions.json").read_text()) if (runtime / "versions.json").is_file() else {}
    # Runtime 跨次复用：schema、依赖指纹或 C 改写器源码变了都要重收。
    # schema 3 的目录仍带 oead 和 GNU timeout，schema 4 的仍带 .NET 运行时（5 起出包工具全为引擎 Binaries/ 里的 NativeAOT 单文件，不再带），
    # requirements 版本对得上也不许复用。
    # 按包导入（不把 pack/ 目录放进模块路径：那样 pack/pack.py 会顶替 pack 包，后面 bundle_engine.write_manifest 的 from pack.shell import 报
    #   「'pack' is not a package」，11-07 本机打 App 实测）
    os.sys.path.insert(0, str(ROOT))
    from pack import rewriter

    if (
        versions.get("runtimeSchema") != 5
        or versions.get("runtimeDeps") != runtime_deps_fingerprint()
        or versions.get("rewriter") != rewriter.source_digest()
        or any(versions.get(name) != version for name, version in expected.items())
        or any(not (runtime / "bin" / name).is_file() for _, name in TOOLS)
    ):  # 工具表加了新命令（10-26 bash / spirv-cross / glslangValidator）旧运行环境也要重打
        subprocess.run(
            [os.sys.executable, str(ROOT / "launchers/macos/bundle_runtime.py")],
            env=env,
            check=True,
        )
    verify_portable_runtime(runtime)
    shutil.copytree(runtime, resources / "Runtime", symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    seal_runtime(resources)   # 预编 .pyc 签进包 + 内置 Python 关写字节码：运行时谁调都写不进包（Engine 在 bundle 里写清单前预编）
    bundle(resources / "Engine", args.developer_dir)
    bundle_shell(resources / "Engine/engine.json", resources / "Shell", env)
    bundle_shell(resources / "Engine/engine.json", resources / "Shell-tvOS", env, "tvos")   # Apple TV 预编壳（0.5.2：0.5.0 发版没带，出 Apple TV 包必败）
    # 随包程序（Intel 的 MacPorts bash）要求高于编译下限时照实声明，不谎报最低系统。只在 Intel 出包机上抬：Apple 芯片正式包照旧按部署下限声明、
    #   包内有程序要求更高系统由下面的最低系统检查报红（不悄悄把 macOS 15 的玩家挡在外面）
    import platform
    declared_min = declared_minimum_macos(app, runtime_sources.deployment_target()) if platform.machine() == "x86_64" else runtime_sources.deployment_target()
    info = dict(**frontend_layout.info_identity(front), CFBundlePackageType="APPL",
                CFBundleIconFile="S2Arm", LSMinimumSystemVersion=declared_min,
                NSHighResolutionCapable=True, CFBundleDevelopmentRegion="en", CFBundleLocalizations=["en", "zh-Hans", "zh-Hant", "ja", "es", "fr"],   # 同界面语言（frontend/l10n）；系统语言不在其中时照 CFBundleDevelopmentRegion 用英文
                NSBluetoothAlwaysUsageDescription=json.loads((ROOT / "launchers/macos/frontend/l10n/en.json").read_text())["bluetooth.usage"],
                # 麦克风（#2151）：游戏宿主由启动器拉起，系统把收音授权记在哪个包上没实测；宿主包（pack/jobs/build.py）与启动器两处都写这键，记在哪边都有说明
                NSMicrophoneUsageDescription=json.loads((ROOT / "launchers/macos/frontend/l10n/en.json").read_text())["microphone.usage"],
                **release_identity(resources / "Engine/engine.json"))
    # Sparkle：appcast 地址、验签公钥（Ed25519，私钥只在发版机 ~/.s2arm/.secrets/sparkle_ed25519）；不开定时检查（查新版走启动时的公告 / 消息）
    info.update(SUFeedURL=SPARKLE_FEED, SUPublicEDKey=SPARKLE_PUBLIC_KEY, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
    info["UTExportedTypeDeclarations"] = [dict(UTTypeIdentifier="org.s2arm.save-backup", UTTypeDescription="S2Arm Save Backup",
        UTTypeConformsTo=["public.zip-archive"], UTTypeTagSpecification={"public.filename-extension": ["s2asave"]})]
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    # 蓝牙授权框的说明文字：每种界面语言一份 <lproj>/InfoPlist.strings（文字取 frontend/l10n 的 bluetooth.usage）。
    #   授权框由系统画、整个框跟系统语言走（11-15 实机：App 设中文、系统英文 → 整框英文），App 改不了；说明文字随系统挑同一种语言
    for lproj, l10n in (("en", "en"), ("zh-Hans", "zh"), ("zh-Hant", "zh-Hant"), ("es", "es"), ("fr", "fr"), ("ja", "ja")):
        strings = json.loads((ROOT / f"launchers/macos/frontend/l10n/{l10n}.json").read_text())
        (resources / f"{lproj}.lproj").mkdir(exist_ok=True)
        (resources / f"{lproj}.lproj/InfoPlist.strings").write_text(f"NSBluetoothAlwaysUsageDescription = {json.dumps(strings['bluetooth.usage'], ensure_ascii=False)};\n"
                                                                    f"NSMicrophoneUsageDescription = {json.dumps(strings['microphone.usage'], ensure_ascii=False)};\n", encoding="utf-8")
    # 启动器本体同样去掉调试映射（见 bundle_engine.strip_debug_maps），再签整个 App
    exe = app / "Contents/MacOS" / front["executable"]
    if os.environ.get("S2A_SYMBOLS_OUT"):   # 未去符号原件随发版存档（同 bundle_engine.strip_debug_maps）
        (Path(os.environ["S2A_SYMBOLS_OUT"]) / "MacOS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(exe, Path(os.environ["S2A_SYMBOLS_OUT"]) / "MacOS" / exe.name)
    subprocess.run(["xcrun", "strip", "-S", "-x", str(exe)], env=env, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(macos / "S2ArmNS2Connection")], env=env, check=True)
    # Sparkle 里面的程序由里往外签（发版签名 sign_release.sh 同样由里往外）：XPC 服务 / Updater.app / Autoupdate → 框架本身
    fw = app / "Contents/Frameworks/Sparkle.framework"
    if fw.is_dir():
        inner = sorted(list((fw / "Versions/B/XPCServices").glob("*.xpc")) + [fw / "Versions/B/Updater.app", fw / "Versions/B/Autoupdate"],
                       key=lambda p: -len(p.parts))
        for p in [p for p in inner if p.exists()] + [fw]:
            subprocess.run(["codesign", "--force", "--sign", "-", str(p)], env=env, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], env=env, check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], env=env, check=True)
    print("最低系统检查：", verify_minimum_macos(app, declared_min), "个 Mach-O（声明", declared_min + "）")
    smoke_env = dict(env, PATH="/usr/bin:/bin:/usr/sbin:/sbin", PYTHONNOUSERSITE="1")
    subprocess.run([str(resources / "Runtime/python/bin/python3"), "-B", "-I", "-c",
                    "import capstone,lz4.block,numpy,zstandard; "
                    "assert list(capstone.Cs(capstone.CS_ARCH_ARM64,capstone.CS_MODE_ARM).disasm(bytes.fromhex('c0035fd6'),0))[0].mnemonic == 'ret'; "
                    "assert lz4.block.decompress(lz4.block.compress(b'S2Arm')) == b'S2Arm'; "
                    "assert numpy.arange(4).sum() == 6; "
                    "assert zstandard.ZstdDecompressor().decompress(zstandard.ZstdCompressor().compress(b'S2Arm')) == b'S2Arm'; print('Bundled Python operations OK')"], env=smoke_env, check=True)
    destination = output / front["app"]
    previous = output / front["app"].replace(".app", "-previous.app")
    if previous.exists():
        shutil.rmtree(previous)
    if destination.exists():
        destination.rename(previous)
    try:
        app.rename(destination)
    except OSError:
        # 宿主代理完成重命名却回报失败时（沙箱 shim 双执行），源已不在、目标已是新包：按成功收尾
        if not app.exists() and destination.exists():
            pass
        elif previous.exists():
            previous.rename(destination)
            raise
        else:
            raise
    print(destination)


if __name__ == "__main__":
    main()
