#!/usr/bin/env python3
"""把 Sparkle 官方 SwiftPM 二进制包放到 frontend/Vendor/（Package.swift 的 binaryTarget 用本地 path 引它）。

11-14：这个 zip 原先直接提交进公开仓（v0.3.10 为了构建不连网），可公开仓全量扫描按规矩不收二进制包，
main 的 linux CI 和所有外部 PR 的 CI 跟着红。现在仓库里不放 zip，构建前由本脚本备好：
  已在 Vendor/ 且校验值对 → 不动；本机共用缓存（~/Library/Caches/S2Arm/）有 → 拷过来；
  都没有 → 从上游 GitHub 发布页下载一次（限时、重试），校验值对上才落缓存与 Vendor/。
同一台机器只下一次，之后每个新的出包工作目录都从缓存拷，不再每次连网（v0.3.10 候选卡下载 14 分钟的原因）。
S2A_SPARKLE_ZIP=<本地文件> 可直接指定来源（离线机器）。用法：python3 launchers/macos/sparkle_vendor.py
"""
import hashlib
import os
import shutil
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

VERSION = "2.10.1"
SHA256 = "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-for-Swift-Package-Manager.zip"
NAME = f"Sparkle-{VERSION}.zip"
DEST = Path(__file__).resolve().parent / "frontend" / "Vendor" / NAME


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def good(path):
    return path.is_file() and digest(path) == SHA256


def place(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dst.parent, prefix=".sparkle-")
    os.close(fd)
    shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def download(dst, tries=3, timeout=120):
    last = None
    for i in range(tries):
        fd, tmp = tempfile.mkstemp(dir=dst.parent, prefix=".sparkle-dl-")
        os.close(fd)
        try:
            with urllib.request.urlopen(urllib.request.Request(URL, headers={"User-Agent": "S2Arm-build"}), timeout=timeout) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f)
            if digest(tmp) != SHA256:
                raise RuntimeError(f"下回来的校验值不对（{digest(tmp)}）")
            os.replace(tmp, dst)
            return
        except Exception as e:   # 网络抖动 / 校验不符都重试
            last = e
            Path(tmp).unlink(missing_ok=True)
            time.sleep(2 * (i + 1))
    raise SystemExit(f"🔴 下不了 Sparkle {VERSION}（{URL}）：{last}。离线机器可设 S2A_SPARKLE_ZIP=<本地 zip> 再跑")


def cache_dir():
    base = os.environ.get("S2A_SPARKLE_CACHE")
    if base:
        return Path(base)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "S2Arm"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "s2arm"


def ensure(dest=DEST):
    if good(dest):
        return dest
    given = os.environ.get("S2A_SPARKLE_ZIP")
    if given:
        if not good(Path(given)):
            raise SystemExit(f"🔴 S2A_SPARKLE_ZIP={given} 不是 Sparkle {VERSION} 官方包（校验值不对）")
        place(given, dest)
        return dest
    cached = cache_dir() / NAME
    if not good(cached):
        cached.parent.mkdir(parents=True, exist_ok=True)
        download(cached)
    place(cached, dest)
    return dest


if __name__ == "__main__":
    print(ensure())
