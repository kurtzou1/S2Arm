#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""翻译器修复清单的发版行（translator/xlate_affected.tsv 的 release <版本> <翻译器指纹>）：发版脚本自动做，不靠人记。
  python3 translator/xlate_affected_release.py --write vX.Y.Z   切版时：清单末尾追加本版 release 行（已有就不动），本树指纹现算（dmsh_chain.py --xfp）
  python3 translator/xlate_affected_release.py --check vX.Y.Z   出候选前：清单最后一行 = release <本版> <本树指纹>，否则退出 1（发版红）
为什么要这一行：启动器按「包出自清单哪一行之前」算受影响键（pack/jobs/xlate_affected.py），没登记的发版出的包在之后的修复里认不出位置，只会漏标"""
import os
import subprocess
import sys

H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(H, "pack/jobs"))
import xlate_affected as xa  # noqa: E402


def tree_xfp():
    out = subprocess.run([sys.executable, os.path.join(H, "translator/dmsh_chain.py"), "--xfp"], capture_output=True, text=True).stdout.strip().splitlines()
    if not out:
        sys.exit("🔴 算不出本树翻译器指纹（dmsh_chain.py --xfp；要 .NET SDK）")
    return out[-1]


def main(argv):
    if len(argv) != 2 or argv[0] not in ("--write", "--check"):
        sys.exit(__doc__)
    path, xfp = os.path.join(H, xa.LIST), tree_xfp()
    text = open(path, encoding="utf-8").read()
    v = argv[1].lstrip("v")
    if argv[0] == "--check":
        rows, _ = xa.parse(text)
        if xa.release_ok(rows, v, xfp):
            print(f"✓ 翻译器修复清单：末尾是 release {v} {xfp}（= 本树）"); return 0
        print(f"🔴 翻译器修复清单末尾不是 release {v} {xfp}（现在是 {rows[-1] if rows else '空'}）：切版没跑 --write，或切版后翻译器又改了")
        return 1
    try:
        new = xa.with_release(text, v, xfp)
    except ValueError as e:
        print(f"🔴 {e}"); return 1
    if new == text:
        print(f"✓ 翻译器修复清单已有 release {v} {xfp}，不动"); return 0
    open(path, "w", encoding="utf-8").write(new)
    print(f"✓ 翻译器修复清单追加 release {v} {xfp}"); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
