# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Build the D2R-Mobile backend from a pinned upstream source checkout."""

import concurrent.futures
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from pool_workers import env_jobs  # noqa: E402

BRIDGE = ROOT / "ios/d2r"
UPSTREAM_COMMIT = "66635dac08a68b074779dc59d3825ee8c262afd8"  # d2r-mobile v2.3.5
FRAMEWORK = "S2AD2R.framework"
SOURCE_PATCH = HERE / "embedded.patch"

# Objective-C class names are global even with hidden symbol visibility. Prefix
# all classes declared by the downstream backend so the two hosts can coexist.
OBJC_CLASS = re.compile(r"^[ \t]*@implementation[ \t]+([A-Za-z_]\w*)", re.MULTILINE)


def run(args, cwd=None, capture=False):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=capture).stdout


def source_tree(checkout, scratch):
    commit = run(["git", "rev-parse", "HEAD"], checkout, capture=True).strip()
    if commit != UPSTREAM_COMMIT:
        raise ValueError(f"Use D2R-Mobile v2.3.5 ({UPSTREAM_COMMIT}), found {commit}")
    dest = scratch / "source"
    dest.mkdir()
    archive = scratch / "source.tar"
    # Only the pinned commit supplies sources. Keep generated inputs and other
    # untracked files in the user's checkout out of the framework build.
    run(["git", "archive", "--output", str(archive), commit], checkout)
    shutil.unpack_archive(archive, dest)
    run(["git", "apply", "--check", str(SOURCE_PATCH)], dest)
    run(["git", "apply", str(SOURCE_PATCH)], dest)
    return dest / "dm"


def shader_chain(ipa):
    with zipfile.ZipFile(ipa) as archive:
        info = archive.read("Payload/DmIOS.app/dm/shell_info.txt").decode()
    fields = dict(line.split("=", 1) for line in info.splitlines() if "=" in line)
    chain = fields.get("CHAIN", "")
    if fields.get("KIND") != "ios" or not re.fullmatch(r"[0-9a-f]{12}", chain):
        raise ValueError("D2R-Mobile IPA lacks the iOS shader-chain stamp")
    return chain


def build(dm, romfs, scratch, chain, simulator=False):
    platform = "iphonesimulator" if simulator else "iphoneos"
    target = "arm64-apple-ios26.0" + ("-simulator" if simulator else "")
    host = dm / "host"
    ios = dm / "ios/Sources"
    sdk = run(["xcrun", "--sdk", platform, "--show-sdk-path"], capture=True).strip()
    make = ["make", f"ROMFS={romfs}"]
    run([*make, "dm_vault_tab.h", "dm_hud_exp.h", "dm_bright_levels.inc"], host)
    run([sys.executable, str(dm / "ios/tools/native_art/generate.py"), str(romfs)], host)
    dry_run = run([*make, "-n", "dmhost"], host, capture=True)
    link = shlex.split(next(line for line in dry_run.splitlines() if line.startswith("clang ")))
    host_sources = {
        (host / name).resolve() for name in link
        if name.endswith((".c", ".m", ".S")) and not Path(name).stem.endswith("_mac")
    }
    sources = sorted((host_sources | set(ios.glob("*.[cm]"))) - {ios / "main.m"})
    sources.extend(BRIDGE / name for name in ("embedded_d2r.m", "d2r_saves.m", "d2r_save_manager.m"))

    # The wrapper also compiles the standalone frontend's types in this image.
    class_names = set()
    for unit in [*sources, ios / "main.m"]:
        if unit.suffix == ".m":
            class_names.update(OBJC_CLASS.findall(unit.read_text()))
    prefix = scratch / "prefix_classes.h"
    prefix.write_text("".join(f"#define {name} S2AD2R{name}\n" for name in sorted(class_names)))

    clang = ["xcrun", "--sdk", platform, "clang", "-target", target, "-isysroot", sdk]
    flags = [
        "-O1", "-fvisibility=hidden", "-DDM_SHELL", "-DDM_S2ARM_EMBEDDED",
        '-DDM_S2ARM_SHADER_CHAIN="' + chain + '"', "-include", str(prefix),
        "-I", str(host), "-I", str(ios), "-I", str(dm / "gfx/nvn/include"),
        "-I", str(ROOT / "ios"),
    ]
    if simulator:
        flags.append("-DDM_NVN_M3=1")

    def compile_unit(item):
        index, source = item
        obj = scratch / f"{index:03}-{source.stem}.o"
        options = ["-Dmain=dm_main"] if source == host / "main.c" else []
        if source.suffix == ".m":
            options.append("-fobjc-arc")
        run([*clang, *flags, *options, "-c", str(source), "-o", str(obj)], scratch)
        return str(obj)

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(env_jobs("S2A_JOBS"), 8)) as workers:
        objects = list(workers.map(compile_unit, enumerate(sources)))

    framework = scratch / FRAMEWORK
    framework.mkdir()
    apple_frameworks = {link[i + 1] for i, arg in enumerate(link) if arg == "-framework"} - {"Cocoa"}
    apple_frameworks.update({
        "UIKit", "Foundation", "BackgroundAssets", "CoreHaptics", "AVFoundation",
        "CoreMotion", "MetalKit", "StoreKit", "CoreGraphics", "UniformTypeIdentifiers",
    })
    libraries = [arg for name in sorted(apple_frameworks) for arg in ("-framework", name)]
    run([
        *clang, "-dynamiclib", "-Wl,-dead_strip", "-Wl,-exported_symbol,_s2a_d2r_backend",
        "-install_name", f"@rpath/{FRAMEWORK}/S2AD2R", "-o", str(framework / "S2AD2R"),
        *objects, *libraries,
    ], scratch)
    info = {
        "CFBundleIdentifier": "org.s2arm.backend.d2r",
        "CFBundleExecutable": "S2AD2R",
        "CFBundleName": "S2AD2R",
        "CFBundlePackageType": "FMWK",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "26.0",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"],
        "S2AD2RShaderChain": chain,
    }
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(dm.parent / "LICENSE", framework / "LICENSE.D2R-Mobile.txt")
    shutil.copy2(dm / "third_party/libdeflate/COPYING", framework / "LICENSE.libdeflate.txt")
    shutil.copy2(dm / "third_party/bcdec/LICENSE", framework / "LICENSE.bcdec.txt")
    return framework
