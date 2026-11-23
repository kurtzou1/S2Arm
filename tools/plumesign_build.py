#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""自编随包的 Impactor / plumesign：上游 claration/Impactor v2.7.3 + launchers/windows/third_party/impactor/patches/*.patch。

为什么自编：上游写死的 anisette v3 服务器向 Apple 报「Mac OS X 10.12.6」，Apple 对部分账号拒绝登录
（SRP -23782「A Mac with macOS 10.13 or later is required」，#1011 / #1572）；补丁只换服务器，其余照上游。

用法（在要出产物的那台机器上跑；Windows 在 Windows 实机、Mac 在 Mac 上）：
    python3 tools/plumesign_build.py <工作目录> [--src <已有的上游 v2.7.3 源码目录>] [--vendor <cargo vendor 目录>]
不给 --src 就从 GitHub 浅取 v2.7.3 标签。连不上 crates.io 的机器（如只经本机中转的 Windows 实机）给 --vendor：
在能联网的机器上先跑 `--make-vendor <目录>` 打依赖包（cargo vendor --locked，配置一并存下），拷过去按 Cargo.lock 的校验值离线编。取到的源码先核树哈希 = UPSTREAM_TREE（与上游标签逐字节一致）再打补丁。
产物与文件名同上游发布页（Windows：plumesign-windows-x86_64.exe、Impactor-windows-x86_64-portable.exe；
Mac：plumesign-macos-universal），写到 <工作目录>/dist/，旁边 manifest.json 记来源、补丁、工具链与 SHA-256。
可重复：Rust 版本按平台钉（RUSTC 不符就停）、--locked 按 Cargo.lock、源码路径前缀统一改写、时间戳固定。"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / "launchers/windows/third_party/impactor/patches"
UPSTREAM = "https://github.com/claration/Impactor"
TAG = "v2.7.3"
UPSTREAM_TREE = "7e4416b8e8ca942c305c8172b3f887a0c12fad10"   # 上游 v2.7.3 提交 2ba32ea4 的源码树
RUSTC = {"win32": "1.99.1", "darwin": "1.94.0"}   # 各平台钉的 Rust 版本（换版本要重核产物、改这里和 impactor.BUNDLED）
EPOCH = "1794960000"   # SOURCE_DATE_EPOCH
# 编译目录固定成同一个绝对路径（macOS）：苹果链接器算 LC_UUID 时把各目标文件的绝对路径算进去，--remap-path-prefix 管不到
#   （11-18 实测：两个工作目录各编一次只差 48 字节——UUID 与随之变的签名哈希）。Windows 用工作目录下的 target（加 /Brepro 后已逐字节相同）
FIXED_TARGET = {"darwin": "/private/tmp/s2a-plumesign-target"}


def run(cmd, cwd=None, env=None):
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run([str(c) for c in cmd], cwd=cwd, env=env, check=True)


def out(cmd, cwd=None):
    return subprocess.run([str(c) for c in cmd], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def source(work, given):
    src = Path(given) if given else work / "src"
    if not given:
        if src.exists():
            shutil.rmtree(src)
        run(["git", "clone", "-q", "--depth", "1", "--branch", TAG, UPSTREAM, src])
    run(["git", "-c", "core.autocrlf=false", "checkout", "-q", "--", "."], cwd=src)
    tree = out(["git", "write-tree"], cwd=src) if out(["git", "status", "--porcelain"], cwd=src) == "" else None
    if tree != UPSTREAM_TREE:
        sys.exit(f"【红】{src} 不是干净的上游 {TAG}（树 {tree}，要 {UPSTREAM_TREE}）")
    for p in sorted(PATCHES.glob("*.patch")):
        run(["git", "apply", "--whitespace=nowarn", p], cwd=src)
    return src


def use_vendor(src, vendor):
    """依赖改从 cargo vendor 目录取（离线）：vendor 目录里的 cargo-config.toml 是打包时 `cargo vendor` 自己打印的源替换配置
    （crates.io 与各 git 依赖都换成 vendored-sources），照抄进 <源码>/.cargo/config.toml，只把 directory 换成本机实际路径"""
    vendor = Path(vendor).resolve()
    conf = (vendor / "cargo-config.toml").read_text(encoding="utf-8")
    conf = re.sub(r'(?m)^directory = ".*"$', f'directory = "{vendor.as_posix()}"', conf)
    (src / ".cargo").mkdir(exist_ok=True)
    (src / ".cargo/config.toml").write_text(conf, encoding="utf-8")


def vendor_deps(src, vendor):
    """在能联网的机器上打依赖包：cargo vendor --locked，配置存进 <vendor>/cargo-config.toml（给 use_vendor 用）"""
    conf = out(["cargo", "vendor", "--locked", vendor], cwd=src)
    Path(vendor, "cargo-config.toml").write_text(conf + "\n", encoding="utf-8")


CHECKS = PATCHES / "check"   # 每个 .rs 是一个检查程序，编之前逐个跑


def check(src, work, offline=False):
    """编之前跑补丁的控制流检查（patches/check/）：临时加进上游工作区当成员（plume_core 的 apple-codesign 是工作区内路径依赖），跑完撤掉"""
    member = src / "apps/s2acheck"
    ws, lock = (src / "Cargo.toml").read_text(encoding="utf-8"), (src / "Cargo.lock").read_text(encoding="utf-8")
    try:
        (member / "src/bin").mkdir(parents=True, exist_ok=True)
        checks = sorted(CHECKS.glob("*.rs"))
        for c in checks:
            shutil.copy2(c, member / "src/bin" / c.name)
        (member / "Cargo.toml").write_text('[package]\nname = "s2a-patch-check"\nversion = "0.1.0"\nedition = "2024"\n[dependencies]\n'
                                          'plume_core = { path = "../../crates/plume_core", features = ["tweaks"] }\n'
                                          'omnisette = { path = "../../3rdparty/omnisette", features = ["remote-anisette-v3"] }\n'
                                          'tokio = { workspace = true }\n'
                                          'rsa = "0.9"\nrcgen = "0.12"\nrand = { workspace = true }\nplist = { workspace = true }\n', encoding="utf-8")   # keycert_check 造证书用（版本同 plume_core）
        (src / "Cargo.toml").write_text(ws.replace('    "crates/plume_utils",\n]', '    "crates/plume_utils",\n    "apps/s2acheck",\n]', 1), encoding="utf-8")
        env = dict(os.environ, CARGO_TARGET_DIR=str(work / "target-check"))
        for c in checks:
            run(["cargo", "run", "-q", "-p", "s2a-patch-check", "--bin", c.stem] + (["--offline"] if offline else []), cwd=src, env=env)
    finally:
        shutil.rmtree(member, ignore_errors=True)
        (src / "Cargo.toml").write_text(ws, encoding="utf-8"); (src / "Cargo.lock").write_text(lock, encoding="utf-8")


def target_dir(work):
    fixed = FIXED_TARGET.get(sys.platform)
    return Path(fixed) if fixed else work / "target"


def build(src, work, targets, packages, offline=False, vendor=None):
    # 可重复：源码与工作目录的绝对路径都改写成固定前缀；Windows 链接器另要 /Brepro（不写时间戳）与 /PDBALTPATH:%_PDB%（PDB 只记文件名，
    #   否则 exe 里带工作目录的绝对路径）——11-18 实测：换工作目录重编，两个 exe 的 SHA-256 都变，加上这几项后相同
    flags = [f"--remap-path-prefix={src}=/s2a/impactor", f"--remap-path-prefix={work}=/s2a/work",
             f"--remap-path-prefix={Path.home()}=/s2a/home"] + ([f"--remap-path-prefix={Path(vendor).resolve()}=/s2a/vendor"] if vendor else [])
    if os.name == "nt":
        flags += ["-C", "link-arg=/Brepro", "-C", "link-arg=/PDBALTPATH:%_PDB%"]
    env = dict(os.environ, CARGO_TARGET_DIR=str(target_dir(work)), SOURCE_DATE_EPOCH=EPOCH, CARGO_INCREMENTAL="0",
               RUSTFLAGS=" ".join(flags + ([os.environ["RUSTFLAGS"]] if os.environ.get("RUSTFLAGS") else [])))
    for t in targets:
        run(["cargo", "build", "--release", "--locked"] + (["--offline"] if offline else []) + ["--target", t] + [a for p in packages for a in ("-p", p)], cwd=src, env=env)
    return target_dir(work)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("work"); ap.add_argument("--src"); ap.add_argument("--vendor"); ap.add_argument("--clean", action="store_true", help="先清空编译目录（核可重复时用）"); ap.add_argument("--make-vendor", help="只打依赖包到这个目录，不编")
    a = ap.parse_args()
    plat = "win32" if os.name == "nt" else sys.platform
    want = RUSTC.get(plat)
    have = out(["rustc", "--version"]).split()[1]
    if have != want:
        sys.exit(f"【红】Rust 版本 {have}，这个平台钉的是 {want}（tools/plumesign_build.py RUSTC）")
    work = Path(a.work).resolve(); work.mkdir(parents=True, exist_ok=True)
    src = source(work, a.src)
    if a.make_vendor:
        vendor_deps(src, a.make_vendor)
        return
    if a.vendor:
        use_vendor(src, a.vendor)
    if a.clean and target_dir(work).exists():
        shutil.rmtree(target_dir(work))
    check(src, work, offline=bool(a.vendor))
    dist = work / "dist"; dist.mkdir(exist_ok=True)
    if plat == "win32":
        t = "x86_64-pc-windows-msvc"
        tgt = build(src, work, [t], ["plumesign", "plumeimpactor"], offline=bool(a.vendor), vendor=a.vendor)
        made = {"plumesign-windows-x86_64.exe": tgt / t / "release/plumesign.exe",
                "Impactor-windows-x86_64-portable.exe": tgt / t / "release/plumeimpactor.exe"}
        for name, p in made.items():
            shutil.copy2(p, dist / name)
    elif plat == "darwin":
        ts = ["aarch64-apple-darwin", "x86_64-apple-darwin"]
        tgt = build(src, work, ts, ["plumesign"], offline=bool(a.vendor), vendor=a.vendor)
        run(["lipo", "-create", "-output", dist / "plumesign-macos-universal"] + [tgt / t / "release/plumesign" for t in ts])
    else:
        sys.exit(f"【红】不支持的平台 {plat}")
    files = {p.name: dict(sha256=sha256(p), bytes=p.stat().st_size) for p in sorted(dist.iterdir()) if p.name != "manifest.json"}
    man = dict(upstream=UPSTREAM, tag=TAG, tree=UPSTREAM_TREE, patches=[p.name for p in sorted(PATCHES.glob("*.patch"))],
               rustc=have, host=platform.platform(), files=files)
    (dist / "manifest.json").write_text(json.dumps(man, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for n, f in files.items():
        print(f"{n}\t{f['bytes']}\t{f['sha256']}")


if __name__ == "__main__":
    main()
