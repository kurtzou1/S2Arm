#!/usr/bin/env python3
"""给发版清单签名（合入运维发版时用）。启动器更新前验这个签名，验不过不下载。

    python3 tools/sign_update_manifest.py --tag v0.1.2 [--notes notes/v0.1.2.md]

下载 Release 里的全部安装包，算 sha256 和大小写进 update-manifest.json，用离线私钥签名，把清单和签名传回 Release。
--notes 给发版说明（Markdown）：解析成 notes 一起签进清单（updater.notes_from_markdown：「## 小节」→ sections，「## 亮点」→ highlights），
启动器打开时弹「有新版」/「这版更新了什么」就读它；不给就只有版本号。
这份清单只给启动器打开时查「有没有新版」和读更新说明用；下载、验签、换版 v0.3.10 起交给 Sparkle / NetSparkle（appcast 另签），差分包已退役。私钥在 ~/.s2a/update-signing/ed25519.key（十六进制，不进仓库）。
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pack/jobs"))
import ed25519  # noqa: E402
import updater  # noqa: E402

REPO = "jhaizhou-ops/S2Arm"
PACKAGE = re.compile(r"S2Arm-(mac-arm64\.dmg|windows-x64\.zip|(mac-arm64|windows-x64)-delta-\d+\.\d+\.\d+\.zip)")


def sha256(path):
    """整份文件的 sha256（11-13 自写换版删掉后 updater 不再带这个函数，签名脚本自己算）。"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def build(folder, version, notes=None):
    """目录里每个安装包 / 差分包 → 清单正文（按文件名排序，字节稳定）。"""
    files = {}
    for path in sorted(Path(folder).iterdir()):
        if PACKAGE.fullmatch(path.name):
            files[path.name] = {"sha256": sha256(path), "size": path.stat().st_size}
    if not any(n in files for n in updater.ASSETS.values()):
        raise SystemExit("目录里没有整包，不能签名")
    body = {"schema": 1, "version": version, "files": files}
    if notes:
        body["notes"] = notes
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sign_folder(folder, version, key_path, out, notes=None):
    secret = bytes.fromhex(Path(key_path).expanduser().read_text().strip())
    if ed25519.public_key(secret).hex() != updater.PUBLIC_KEY:
        raise SystemExit("这把私钥和启动器里的公钥对不上，不能签名")
    manifest = build(folder, version, notes)
    (Path(out) / updater.MANIFEST).write_bytes(manifest)
    (Path(out) / updater.SIGNATURE).write_bytes(ed25519.sign(secret, manifest))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--key", default=os.path.expanduser("~/.s2a/update-signing/ed25519.key"))
    ap.add_argument("--notes", help="发版说明 Markdown（notes/vX.Y.Z.md）：解析成清单里的 notes")
    a = ap.parse_args(argv)
    if not re.fullmatch(r"v\d+\.\d+\.\d+", a.tag):
        raise SystemExit(f"版本要写成 vX.Y.Z：{a.tag}")
    with tempfile.TemporaryDirectory(prefix="s2arm-sign-") as tmp:
        subprocess.run(["gh", "release", "download", a.tag, "--repo", REPO, "--dir", tmp, "--pattern", "S2Arm-*"], check=True)
        notes = updater.notes_from_markdown(Path(a.notes).read_text(encoding="utf-8")) if a.notes else None
        if a.notes and not notes:
            raise SystemExit(f"{a.notes} 里没解析出更新说明（要有「## 小节」和「- 」开头的条目）")
        sign_folder(tmp, a.tag[1:], a.key, tmp, notes)
        subprocess.run(["gh", "release", "upload", a.tag, "--repo", REPO, "--clobber", str(Path(tmp, updater.MANIFEST)), str(Path(tmp, updater.SIGNATURE))], check=True)
    print("已签名并上传 " + a.tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
