#!/usr/bin/env python3
"""Windows 启动器发版组装（同 Mac launchers/macos/bundle_engine.py + build_app 的资源段）：产出解压即用的完整目录，玩家机不装任何开发工具。
在 Windows 出包机上（要 .NET SDK / clang / cmake / cargo 等，见 bundle_prepare_win.py）：
  python -X utf8 launchers/windows/bundle_win.py <目标> --shell <预编壳目录> --tzdata <时区目录> --fonts <字体目录>
产物（<目标> 不许已存在）：
  Engine/           引擎快照（同 Mac：按 bundle_engine.INPUTS 挑仓库文件、全新单提交 Git 库）+ Binaries/Prepare（bundle_prepare_win 预编件 + Tzdata）+ engine.json
                    （逐文件大小 + sha256、源码指纹、壳编号；作业层 embedded.install 校验后克隆进私有目录）
  Runtime/          随包运行时（bundle_runtime_win.py：Python 嵌入版、.NET 运行时、bash、MinGit、zstd、许可）
  Shell/            预编壳（壳编号须等于 engine.json 的 shellId）
  Fonts/            开源共享字体 7 份 .bfttf
  ThirdParty/Impactor/  官方原版 Impactor + plumesign（v2.7.2，不改不重签，SHA-256 钉在 pack/jobs/impactor.py BUNDLED，不符拒打）+ 许可（MIT、内嵌 apple-codesign 的 MPL-2.0）+ 来源说明
启动器作业请求：resources=<目标>、engineBundle=engineDir=<目标>\\Engine（同 Mac Store.swift）。
预编壳、时区、字体三样目前只在 Mac 上产出（pack/shell_build.sh、services/systemdata/make_tzdata.sh --bundle-to、pack/fonts/make_open_fonts.py），作为输入给进来，这里只核对后收入。
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launchers/windows"))
sys.path.insert(0, str(ROOT / "launchers/macos"))
import bundle_engine   # noqa: E402  文件挑选 / 源码指纹 / engine.json 写法只此一份
import bundle_prepare_win   # noqa: E402
import bundle_runtime_win   # noqa: E402
sys.path.insert(0, str(ROOT / "pack/jobs"))
import impactor   # noqa: E402  随包 Impactor 的版本 / 文件名 / 哈希只此一份（作业层按同一份找）

IMPACTOR_LICENSES = ROOT / "launchers/windows/third_party/impactor"   # v2.7.2 标签下的 LICENSE 与 3rdparty/apple-codesign-0.29.0/LICENSE 原文


def say(m): print(m, flush=True)


def snapshot(engine):
    """仓库输入 → 全新单提交 Git 库（同 Mac bundle_engine.bundle 的快照段；出包各阶段按 git 对象号取源码身份）"""
    engine.mkdir(parents=True)
    n = 0
    for rel in bundle_engine.snapshot_files(ROOT):   # 挑文件与 Mac 同一个函数（单测 pack/jobs/tests/test_downstream.py 锁登记表在内）
        src = ROOT / rel
        if src.is_symlink():
            raise SystemExit("【红】引擎源码里有符号链接，要先显式展开：" + str(rel))
        if not src.is_file():
            continue
        (engine / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, engine / rel); n += 1
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="S2Arm", GIT_AUTHOR_EMAIL="bundle@localhost",
               GIT_COMMITTER_NAME="S2Arm", GIT_COMMITTER_EMAIL="bundle@localhost")
    for args in (["init", "-q", "--template="], ["config", "gc.auto", "0"], ["config", "maintenance.auto", "false"], ["config", "core.autocrlf", "false"],
                 ["config", "core.longpaths", "true"], ["add", "--force", "--all"],
                 ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull, "commit", "-qm", "Bundled S2Arm engine inputs"],
                 ["-c", "gc.autoDetach=false", "gc", "--prune=now"]):
        subprocess.run(["git", "-C", str(engine), *args], env=env, check=True)
    return n


def shell_id(shell):
    return json.loads((Path(shell) / "manifest.json").read_text(encoding="utf-8"))["details"]["shellId"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()


def impactor_cache():
    return Path(os.environ.get("S2A_IMPACTOR_CACHE") or Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run") / "s2arm/cache/impactor" / ("v" + impactor.TESTED))


def bundle_impactor(dest, cache=None, fetch=None):
    """官方原版 Impactor + plumesign 随启动器下发（11-07 维护者：玩家不再跳转下载）：缓存里有就用（离线构建），没有从官方发布页下；
    逐个核 SHA-256 = impactor.BUNDLED，不符报红拒打（不改、不重签、不换版本）；附许可原文与来源说明"""
    cache = Path(cache or impactor_cache()); cache.mkdir(parents=True, exist_ok=True); dest = Path(dest); dest.mkdir(parents=True)
    if fetch is None:
        import urllib.request
        fetch = lambda url, to: urllib.request.urlretrieve(url, to)   # noqa: E731
    lines = []
    for name, want in impactor.BUNDLED.items():
        src = cache / name
        if not src.is_file():
            say(f"[组装] 下载 {name}（官方发布页 v{impactor.TESTED}）"); tmp = src.with_suffix(".part")
            try:
                fetch(impactor.DOWNLOAD + name, tmp)
            except OSError as e:   # 11-07 Windows 出包机直连 github.com 被重置：Windows 出包机多半下不了，先在能连 GitHub 的机器（Mac 构建机）下好、核过哈希放进缓存
                raise SystemExit(f"【红】取不到 {impactor.DOWNLOAD + name}（{e}）：在能连 GitHub 的机器上下好放进 {cache}（或用 S2A_IMPACTOR_CACHE 指过去）再打")
            tmp.replace(src)
        got = sha256(src)
        if got != want:
            raise SystemExit(f"【红】{src} 的 SHA-256 是 {got}，钉的是 {want}（{impactor.RELEASE_PAGE}）：不是官方 v{impactor.TESTED} 原版，拒打")
        shutil.copy2(src, dest / name); lines.append(f"{name}\t{src.stat().st_size} 字节\tSHA-256 {want}")
    for f in sorted(IMPACTOR_LICENSES.glob("LICENSE-*.txt")): shutil.copy2(f, dest / f.name)
    (dest / "README-来源与许可.txt").write_text("\r\n".join([
        f"Impactor v{impactor.TESTED}（第三方开源工具，作者 Samara M / claration，MIT 许可：LICENSE-Impactor-MIT.txt）",
        "S2Arm 原样随附官方发布文件，未修改、未重新签名，用于把出好的 iPhone 包签名并装到你的 iPhone；Apple ID 密码只在 Impactor 里输入、只发给 Apple。",
        f"来源：{impactor.RELEASE_PAGE}", *lines,
        "其中内嵌的 apple-codesign 0.29.0 以 MPL-2.0 发布（LICENSE-apple-codesign-MPL-2.0.txt），源码：",
        f"  https://github.com/claration/impactor/tree/v{impactor.TESTED}/3rdparty/apple-codesign-0.29.0",
        f"Impactor 完整源码：https://github.com/claration/impactor/tree/v{impactor.TESTED}", ""]), encoding="utf-8")


def bundle(target, shell, tzdata, fonts):
    target = Path(target).resolve()
    if target.exists():
        raise SystemExit(f"【红】{target} 已存在：换个空目标，不混旧件")
    shell, tzdata, fonts = Path(shell), Path(tzdata), Path(fonts)
    if not (tzdata / "output").is_dir() or not any((tzdata / "output").iterdir()):
        raise SystemExit(f"【红】时区目录 {tzdata} 要有非空 output/（Mac 上 services/systemdata/make_tzdata.sh --bundle-to 出）")
    bft = sorted(fonts.glob("*.bfttf"))
    if len(bft) != 7:
        raise SystemExit(f"【红】字体目录 {fonts} 要有 7 份 .bfttf（现 {len(bft)} 份；Mac 上 pack/fonts/make_open_fonts.py 出）")
    sys.path.insert(0, str(ROOT)); from pack.shell import manifest as shell_manifest
    want = shell_manifest.current_id()
    if not (shell / "manifest.json").is_file() or shell_id(shell) != want:
        raise SystemExit(f"【红】预编壳 {shell} 不是本引擎的壳 {want}（Mac 上 pack/shell_build.sh 按同一提交出）")
    engine = target / "Engine"
    fingerprint = bundle_engine.source_fingerprint(ROOT)
    say(f"[组装] 引擎快照：{snapshot(engine)} 个文件")
    say("[组装] 预编件"); bundle_prepare_win.bundle(engine)
    shutil.copytree(tzdata, engine / "Binaries/Prepare/Tzdata")
    identity = bundle_engine.write_manifest(engine, fingerprint)
    say(f"[组装] engine.json：{identity[:16]}（壳 {want}）")
    say("[组装] 随包运行时"); bundle_runtime_win.main([str(target)])
    shutil.copytree(shell, target / "Shell")
    (target / "Fonts").mkdir()
    for f in bft:
        shutil.copy2(f, target / "Fonts" / f.name)
    say("[组装] 随包 Impactor"); bundle_impactor(target / impactor.BUNDLE_DIR)
    # 覆盖更新读这个版本号：最近的发版 tag（同 Mac build_app 的 CFBundleShortVersionString）
    tag = subprocess.check_output(["git", "-C", str(ROOT), "describe", "--tags", "--abbrev=0"], text=True).strip()
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+)", tag)
    if not match:
        raise SystemExit(f"【红】最近的 tag {tag} 不是 vX.Y.Z，发版前要先打 tag")
    (target / "version.txt").write_text(match[1] + "\n", encoding="ascii")
    # 给玩家的 AI 用：控制客户端、手册（同 Mac build_app）；用随包 Python 跑，玩家不用另装
    shutil.copy2(ROOT / "launchers/macos/s2armctl.py", target / "s2armctl.py")
    (target / "s2armctl.cmd").write_text('@"%~dp0Runtime\\python\\python.exe" -X utf8 -B -I "%~dp0s2armctl.py" %*\r\n', encoding="ascii", newline="")
    (target / "skill/s2arm-operator").mkdir(parents=True)
    shutil.copy2(ROOT / "launchers/macos/skill/s2arm-operator/SKILL.md", target / "skill/s2arm-operator/SKILL.md")
    size = sum(p.stat().st_size for p in target.rglob("*") if p.is_file())
    say(f"🟢 Windows 启动器目录 → {target}（{size / 2**30:.2f} GB）")
    return identity


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("target"); ap.add_argument("--shell", required=True); ap.add_argument("--tzdata", required=True); ap.add_argument("--fonts", required=True)
    a = ap.parse_args(argv)
    bundle(a.target, a.shell, a.tzdata, a.fonts)


if __name__ == "__main__":
    main()
