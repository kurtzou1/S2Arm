# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""翻译器修复的「受影响着色器键」清单（translator/xlate_affected.tsv）：哪款的着色器库要因翻译器修复重编。

翻译器改动不改着色器库链号（只随宿主 ↔ 库接口 ABI 变，translator/dmsh_chain.py），所以已出的包不会因链号被提示更新，
只有重出包才带上修复。维护者在手上有着色器输入的款上，拿新旧翻译器各翻一遍、比产物，把产物变了的键记进清单随版本发出
（translator/xlate_affected_gen.py）；启动器拿每款包的键（资源包 shaders/direct/keys.tsv，按客体输入算的键，与翻译器无关）
和清单比，有交集才标「建议更新」（host_update.ios_lib_reasons 原因 xlateFix），「更新这款」随之重编这款的着色器库。

清单一行一条、按时间顺序（# 开头是注释）：
  release <发版号> <翻译器指纹>     这一版启动器出包用的翻译器
  step    <改前指纹> <改后指纹> <扫了几款> <说明>   一次翻译器改动
  key     <改后指纹> <着色器键>      这一步改动让产物变了的键（16 位十六进制）
包的位置：兼容记录里出库时的翻译器指纹（ios.xlateFp，本模块之后出的包才有）出现在哪一行，就在哪一行之后；
没有指纹的旧包按出它的启动器发版号（ios.builtBy.version）对 release 行。认不出（开发版、清单开始之前）→ 不标：宁可漏标，不误报。
包在某一步之前，就把这一步和之后每一步的受影响键算到它头上（修的缺陷在更早的翻译器里同样有）。
"""
from pathlib import Path

LIST = "translator/xlate_affected.tsv"


def parse(text):
    """清单文本 → (rows, keys)：rows = 按序的 (种类, a, b)（release：发版号、指纹；step：改前、改后），keys = 改后指纹 → 键集合"""
    rows, keys = [], {}
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        f = line.split("\t")
        if f[0] == "release" and len(f) >= 3:
            rows.append(("release", f[1], f[2]))
        elif f[0] == "step" and len(f) >= 3:
            rows.append(("step", f[1], f[2]))
        elif f[0] == "key" and len(f) >= 3:
            keys.setdefault(f[1], set()).add(f[2].strip().lower())
        else:
            raise ValueError(f"xlate_affected: 认不出的行：{line[:80]}")  # 非玩家句
    return rows, keys


def load(engine):
    """本引擎带的清单；没有引擎目录（单测替身）/ 没有这份文件（之前的引擎）/ 读不了 → ([], {})：不标、不挡别的原因"""
    if not engine:
        return [], {}
    try:
        return parse((Path(engine) / LIST).read_text(encoding="utf-8"))
    except OSError:
        return [], {}


def keys_after(rows, keys, xfp=None, version=None):
    """出包时在这个位置（翻译器指纹 xfp 优先，否则启动器发版号 version）的包，之后每一步修复的受影响键并集；位置认不出 → None"""
    seen, out = False, set()
    for kind, a, b in rows:
        if kind == "release":
            if (xfp and b == xfp) or (not xfp and version and a == version):
                seen, out = True, set()   # 在这一版之后：之前各步的键不算
            continue
        if xfp and a == xfp:
            seen = True
        if seen:
            out |= keys.get(b, set())
        if xfp and b == xfp:
            seen, out = True, set()   # 出包的翻译器已含这一步：这一步和之前的都不算
    return out if seen else None


def pack_keys(direct):
    """资源包 shaders/direct/keys.tsv 里的键（小写）；没有 → 空集"""
    try:
        return {l.strip().lower() for l in (Path(direct) / "keys.tsv").read_text(encoding="utf-8").splitlines() if l.strip()}
    except OSError:
        return set()


def lib_xfp(direct):
    """资源包 shaders/direct/b-<链>/inputs.tsv 印章里的翻译器指纹（出这份库的翻译器）；没有 → None"""
    for lib in sorted(Path(direct).glob("b-*")):
        if lib.name.endswith("-vk"):
            continue
        try:
            for line in (lib / "inputs.tsv").read_text(encoding="utf-8").splitlines():
                if line.startswith("xfp\t"):
                    return line.split("\t", 1)[1].strip() or None
        except OSError:
            continue
    return None


def affected(engine, ios, direct):
    """这款 iPhone 包里被翻译器修复影响的键数（0 = 不受影响 / 判不了）。
    先只看兼容记录（几 KB）定位置：位置认不出、或之后没有带键的修复步 → 0，不打开资源包；有才读这款的 keys.tsv（一行一个键的文本）"""
    rows, keys = load(engine)
    if not rows:
        return 0
    built = (ios or {}).get("builtBy") or {}
    version = built.get("version") if isinstance(built, dict) else None
    after = keys_after(rows, keys, xfp=(ios or {}).get("xlateFp"))
    if after is None:   # 没记指纹（之前出的包），或指纹清单里没有（开发版出的）：按出包的启动器发版号
        after = keys_after(rows, keys, version=version)
    if not after:
        return 0
    return len(after & pack_keys(direct))


def release_ok(rows, version, xfp):
    """发版核对：清单最后一行是本版的 release 行、指纹 = 本树翻译器指纹（发版脚本出候选前核，缺了发版红）"""
    return bool(rows) and rows[-1] == ("release", version.lstrip("v"), xfp)


def with_release(text, version, xfp):
    """清单文本追加本版 release 行（发版脚本切版时自动做）；已经是本版且指纹相同 → 原样（重跑不重复加）。
    最后一行是本版但指纹不同（切版后翻译器又改了）→ ValueError：要先登记那一步翻译器改动（step 行），不能拿 release 行盖过去"""
    rows, _ = parse(text)
    v = version.lstrip("v")
    if release_ok(rows, v, xfp):
        return text
    if rows and rows[-1][0] == "release" and rows[-1][1] == v:
        raise ValueError(f"清单最后一行已是 release {v}，指纹 {rows[-1][2]} ≠ 本树 {xfp}：切版后翻译器又改了，先追加 step 行")  # 非玩家句
    if rows and rows[-1][2] != xfp:
        raise ValueError(f"清单最后一行的指纹 {rows[-1][2]} ≠ 本树 {xfp}：翻译器改了没登记 step 行，先补上再切版")  # 非玩家句
    return text.rstrip("\n") + f"\nrelease\t{v}\t{xfp}\n"
