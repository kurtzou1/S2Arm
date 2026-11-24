# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""程序包（通用壳，11-16）：每款游戏的程序挪出 App，单独签名、放进手机数据容器，App 更新不用重新打包游戏。

手机上的位置与清单（和 iOS 加载侧的约定，改要两边一起改）：
  Library/Application Support/S2Arm/games/<游戏号>/program/   （与 资源包/ 同级）
    S2AImages-<游戏号>.dylib    团队签名（同一团队才过宿主的库校验 F_CHECK_LV）
    Games/<游戏号>/             随行表 + main.npdm + icon.jpg（同容器里的 Games/<游戏号>/）
    catalogue.json              {schema, title_id, name, display_version, icon, banner, host_abi, chain, rewriter_id, image, image_sha256, team, dir}
  推送顺序：dylib → Games/<游戏号>/ → 最后写 catalogue.json（临时名再改名）；手机上没有 catalogue.json = 这款程序没装好，宿主不拿去加载。
本模块（电脑端第 1 段）：
  build(c, gid)                       常驻程序件（programs.kit_dir）→ 未签名程序包，缓存在 <工具缓存>/cache/programs/<号>/package/
  sign(c, gid, team, bundle, signer)  未签名包 → 按团队签好的包 + catalogue.json，缓存在 …/signed/<团队>/
  need(c, gid, phone, team, cert)     这台手机上这款要不要推、为什么（空集 = 不用动）
签名不自己做：Mac 走 pack/dev_sign.py --dylib（钥匙串开发身份），Windows 走 pack/orch/install_win.py sign_dylibs（官方 plumesign，带 --custom-identifier
  = 这台手机已装 S2Arm 的包名，不新建 App ID）。"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path
import shutil
import sys
import tempfile

from core import Failure
import programs

SCHEMA = 1
# 0.6.0 起通用壳是唯一的装机方式（维护者 11-18 定）：装 App 只装壳，各款程序包推进手机 program/（install.push_programs）
PACKAGE, SIGNED, CATALOGUE, KEY, META = "package", "signed", "catalogue.json", ".key", "meta.json"
REASONS = ("missing", "abi", "rewriter", "sha", "team", "cert", "look")
# Apple TV 也走通用壳（11-19）：同一份程序件，只是镜像包按 tvOS 平台标（ios/embed.py 看 S2A_APPLE_OS）、用 tvOS 壳的随包表；缓存与 iPhone 分开放
PLATFORMS = ("ios", "tvos")


def _dirs(platform):
    """平台 → (未签名包目录名, 签好包目录名)：iPhone 照旧 package / signed，Apple TV 加 -tvos"""
    if platform not in PLATFORMS:
        raise ValueError(platform)
    return (PACKAGE, SIGNED) if platform == "ios" else (PACKAGE + "-tvos", SIGNED + "-tvos")   # need() 可能给的原因；look = 玩家在启动器里改的游戏名 / 封面变了（只重推清单与图标）


def image_name(gid):
    return f"S2AImages-{gid.upper()}.dylib"


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def _kit_stamp(kit):
    """程序件内容戳：每个文件的（相对路径、大小、修改时间 ns），不读内容"""
    rows = []
    for p in sorted(Path(kit).rglob("*")):
        if p.is_file():
            st = p.stat()
            rows.append(f"{p.relative_to(kit).as_posix()}\t{st.st_size}\t{st.st_mtime_ns}")
    return hashlib.sha256("\n".join(rows).encode("utf-8")).hexdigest()


def compat(c):
    """本引擎的约定号与直连链号（host_update.engine_compat）+ 改写器指纹；读不到 → Failure"""
    import host_update
    want = host_update.engine_compat(c)
    if not want:
        raise Failure("读不到本引擎的直连库链号（graphics/nvn/gfx/nvn/dmsh_chain.h），出不了程序包", code="job_failed")  # 非玩家句
    import rewrite_refresh
    return dict(host_abi=want["hostAbi"], chain=want["dmshChain"], rewriter_id=rewrite_refresh.rewriter_id(c))


def _package_key(c, gid, kit=None, info=None, banner=None, platform="ios"):
    """未签名程序包的缓存键（build 与 sign 共用）→ (kit, info, banner, 键)。缓存键 = 约定号 + 链号 + 改写器指纹 + 程序件内容戳 + 横版封面（Apple TV 另加平台）"""
    kit = Path(kit) if kit else programs.kit_dir(c, gid)
    if not (kit / "main.npdm").is_file():
        raise Failure(f"{gid} 还没有 iPhone 程序件：先「打 iPhone 包」", code="container_stale")
    info = info or compat(c)
    if banner is None:   # 游戏库横版封面（导入时抓的，library.store_meta）：后来才抓到 / 换了也要重出，进键
        import layout
        banner = layout.path(c, gid, "banner.jpg", create=False)
    banner = Path(banner) if banner and Path(banner).is_file() else None
    bst = [banner.stat().st_size, banner.stat().st_mtime_ns] if banner else None
    key = hashlib.sha256(json.dumps(dict(info, kit=_kit_stamp(kit), banner=bst, **({} if platform == "ios" else {"platform": platform})),
                                    sort_keys=True).encode()).hexdigest()
    return kit, info, banner, key


def build(c, gid, *, kit=None, shell=None, info=None, banner=None, platform="ios"):
    """未签名程序包 → 目录 <cache>/package/（S2AImages-<号>.dylib、Games/<号>/、meta.json）。缓存键 = 约定号 + 链号 + 改写器指纹 + 程序件内容戳，
    键没变不重出。kit / shell / info 单测可给（缺省：programs.kit_dir、本版 iPhone 壳、compat）。
    platform = "tvos"：Apple TV 版（<cache>/package-tvos/），壳缺省取 tvOS 预编壳，出包子进程带 S2A_APPLE_OS=tvos（镜像包标 tvOS 平台，tvOS 的 dyld 不认标 iOS 的库）"""
    gid = gid.upper()
    kit, info, banner, key = _package_key(c, gid, kit, info, banner, platform)
    dest = programs.cache(c, gid) / _dirs(platform)[0]
    if (dest / KEY).is_file() and (dest / KEY).read_text(encoding="utf-8") == key and (dest / image_name(gid)).is_file():
        return dest
    if shell is None and platform == "tvos":
        import tvos
        shell = tvos.tv_shell(c)[0]
    elif shell is None:
        import ipa
        shell = ipa.container_shell(c, ipa.current_shell_id(c))
    dest.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".package-", dir=dest.parent))
    try:
        log = c.logs / (c.task + "-program.log")
        out = work / "program"
        c.run([os.sys.executable, "-X", "utf8", "-B", Path(c.engine) / "pack/ship_ext.py", "program", "--shell", shell, "--root", kit, "--out", out]
              + (["--banner", banner] if banner else []), log, dict(c.env(), S2A_APPLE_OS="tvos") if platform == "tvos" else c.env())
        got = json.loads(log.read_text(encoding="utf-8", errors="replace").strip().splitlines()[-1])
        if got.get("gid") != gid:
            raise Failure(f"程序件 {kit} 的程序号是 {got.get('gid')}，不是 {gid}", code="job_failed")  # 非玩家句
        (out / META).write_text(json.dumps(dict(info, name=got.get("name", ""), display_version=got.get("display_version", ""),
                                                image_sha256=_sha(out / image_name(gid))), ensure_ascii=False), encoding="utf-8")
        (out / KEY).write_text(key, encoding="utf-8")
        if dest.exists():
            import layout
            layout.remove_tree(dest)   # 工具缓存可在 exFAT 盘上：删本体时 ._ 伴随文件跟着没了，裸 rmtree 报找不到（D-6P5D）
        os.replace(out, dest)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return dest


def catalogue(gid, meta, image, team):
    """程序包清单（字段见文件头）：meta = build 写的 meta.json，image = 签好的 dylib，team = 签名团队"""
    gid = gid.upper()
    out = dict(schema=SCHEMA, title_id=gid, name=meta.get("name", ""), display_version=meta.get("display_version", ""),
               host_abi=meta["host_abi"], chain=meta["chain"], rewriter_id=meta.get("rewriter_id", ""),
               image=image_name(gid), image_sha256=_sha(image), team=team)
    if (Path(image).parent / "Games" / gid / "icon.jpg").is_file():
        out["icon"] = f"Games/{gid}/icon.jpg"
    if (Path(image).parent / "Games" / gid / "banner.jpg").is_file():
        out["banner"] = f"Games/{gid}/banner.jpg"
    return out


def sign(c, gid, team, bundle, signer, *, pkg=None, platform="ios", kit=None):
    """未签名包 → <cache>/signed/<团队>/（同结构 + catalogue.json）。signer(dylib 路径, 团队, 包名) 原地签那个 dylib（Mac：mac_signer；
    Windows：win_signer）。缓存键 = 未签名包的键 + 团队 + 包名，没变不重签。pkg 缺省 build(c, gid)。
    platform = "tvos"：Apple TV 版（<cache>/signed-tvos/<团队>/，未签名包按 build(platform="tvos", kit=kit) 出）"""
    gid = gid.upper()
    dest = programs.cache(c, gid) / _dirs(platform)[1] / team
    own = pkg is None   # 自己出的未签名包：签好后删掉它的 dylib（0.6.0 程序缓存瘦身：推送只用签好的那份；换团队时按键重出，build 自己会出）
    if own:   # 签好的那份键对得上就直接用，不必先把未签名包重出一遍
        hit = _package_key(c, gid, kit, platform=platform)[3] + f"\t{team}\t{bundle}" + _signer_tag(signer)
        if (dest / KEY).is_file() and (dest / KEY).read_text(encoding="utf-8") == hit and (dest / CATALOGUE).is_file():
            return dest
    pkg = Path(pkg) if pkg else build(c, gid, kit=kit, platform=platform)
    meta = json.loads((pkg / META).read_text(encoding="utf-8"))
    key = (pkg / KEY).read_text(encoding="utf-8") + f"\t{team}\t{bundle}" + _signer_tag(signer)
    if (dest / KEY).is_file() and (dest / KEY).read_text(encoding="utf-8") == key and (dest / CATALOGUE).is_file():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".signed-", dir=dest.parent))
    try:
        out = work / "program"
        shutil.copytree(pkg, out, ignore=shutil.ignore_patterns(KEY, META))
        signer(out / image_name(gid), team, bundle)
        cat = catalogue(gid, meta, out / image_name(gid), team)
        tmp = out / (CATALOGUE + ".tmp")
        tmp.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, out / CATALOGUE)
        (out / KEY).write_text(key, encoding="utf-8")
        if dest.exists():
            import layout
            layout.remove_tree(dest)   # 工具缓存可在 exFAT 盘上：删本体时 ._ 伴随文件跟着没了，裸 rmtree 报找不到（D-6P5D）
        os.replace(out, dest)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if own:   # 签名整份重写 dylib（codesign 实测：克隆后签名独占全部字节），未签名那份留着就是每款多一份程序；只留键与元数据，下次要时 build 按键重出
        (pkg / image_name(gid)).unlink(missing_ok=True)
    return dest


def _signer_tag(signer):
    """签名器身份进签好那份的缓存键：同一团队换了签法（Mac 从 Xcode 钥匙串换到 plumesign + s2a-selfsign、换了证书）不能命中旧签法的缓存——
    系统 codesign 签的程序库免费团队手机不认，换签法后还推旧的就一直起不了局。签名器没标身份（单测替身等）→ 空串，键同旧版"""
    tag = getattr(signer, "kind", "")
    return f"\t{tag}" if tag else ""


def need(c, gid, phone, team, cert=None, *, want=None):
    """这台手机上这款的程序包要不要推 → 原因集合（REASONS 的子集；空 = 不用动）。
    phone = 设备记录里这款的 program 记录 {sha, team, cert, host_abi, rewriter_id, look}（没推过 = None）；want = 本次要推的包的 catalogue（缺省按缓存现算），
    可带 look（启动器里改的名字 / 封面的指纹，install.push_programs 算）"""
    if not phone:
        return {"missing"}
    want = want or {}
    got = set()
    if want.get("host_abi") is not None and phone.get("host_abi") != want.get("host_abi"):
        got.add("abi")
    if want.get("rewriter_id") and phone.get("rewriter_id") != want.get("rewriter_id"):
        got.add("rewriter")
    if want.get("image_sha256") and phone.get("sha") != want.get("image_sha256") and not got:
        got.add("sha")
    if phone.get("team") != team:
        got.add("team")
    if cert and phone.get("cert") and phone.get("cert") != cert:
        got.add("cert")
    if want.get("look") is not None and phone.get("look") != want.get("look"):
        got.add("look")
    return got


def win_signer(c, exe, shell_app):
    """Windows：pack/orch/install_win.py sign_dylibs（官方 plumesign 只签不装一个只含壳与这个 dylib 的小 IPA，取回签好的 dylib）"""
    root = str(c.engine)
    if root not in sys.path:
        sys.path.insert(0, root)
    from pack.orch import install_win
    def run(dylib, team, bundle):
        try:
            install_win.sign_dylibs(exe, shell_app, [Path(dylib)], bundle, c.logs / (c.task + "-program-sign.log"))
        except install_win.Fail as e:
            # 同装机那条路（install.win_install_failure）：plumesign 认出的码（e.err，如 Apple 1100 登录过期 apple_session_expired）带进作业失败、
            #   上屏说人话的办法。原先原样抛 install_win.Fail，作业层不认这个类、按意外记成 job_failed「本地任务失败」（D-39W8：导出 / 推送前按需更新程序时登录过期）
            from install import win_install_failure
            raise win_install_failure(e, c) from e
    run.kind = "plumesign"
    return run


def selfsign_path(c):
    """电脑侧签程序库的 s2a-selfsign（pack/selfsign，0.6.0）：S2A_SELFSIGN（开发用）> 引擎随包 Binaries/Prepare/selfsign/ > 源码树编出的 build/selfsign/release/；
    都没有 → None（源码树没编，调用方照旧用别的签法）"""
    exe = "s2a-selfsign.exe" if os.name == "nt" else "s2a-selfsign"
    for p in (os.environ.get("S2A_SELFSIGN"), Path(c.engine) / "Binaries/Prepare/selfsign" / exe, Path(c.engine) / "build/selfsign/release" / exe):
        if p and Path(p).is_file():
            return str(p)
    return None


def selfsign_signer(c, tool, key_pem, cert_der):
    """用私钥文件签程序库（免费团队也认的签法：签名标识 = App 包名、XML + DER 两份权限，同手机端 selfsign.c，cmdr 免费团队手机自签定稿）：
    key_pem = 私钥 PEM 文件，cert_der = 这把私钥对应的开发证书 DER（字节）。系统 codesign 不给 dylib 带权限，所以不用它"""
    def run(dylib, team, bundle):
        with tempfile.TemporaryDirectory(dir=c.private) as w:
            cert = Path(w) / "cert.der"
            cert.write_bytes(cert_der)
            r = subprocess.run([tool, "--key", str(key_pem), "--cert", str(cert), "--bundle-id", bundle, "--team", team, str(dylib)],
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode:
            raise Failure("给这款的程序签名失败：" + ((r.stderr or r.stdout or "").strip().splitlines() or ["?"])[-1], code="job_failed")  # 非玩家句（工具原句只进日志 / 诊断）
    run.kind = "selfsign:" + hashlib.sha256(cert_der).hexdigest()[:16]   # 换了证书（续期 / 换私钥）也重签
    return run


def devcert_signer(c):
    """开发者证书模式（玩家导入的 .p12，devcert.active）：rcodesign 读 p12 只签这一个 dylib——不嵌描述文件、不带权限，两端同一份
    （同 devcert.sign_app 的参数：--team-name 显式给团队号、--timestamp-url none 不向苹果时间戳服务器要时间戳）"""
    import devcert
    def run(dylib, team, bundle):
        p12, _, pw = devcert.stored(c)
        with devcert.pwfile(devcert.folder(c), pw) as pf:
            c.run([devcert.rcodesign_path(c), "sign", "--p12-file", p12, "--p12-password-file", pf, "--team-name", team,
                   "--timestamp-url", "none", Path(dylib)], c.logs / (c.task + "-program-sign.log"))
    run.kind = "devcert"
    return run

