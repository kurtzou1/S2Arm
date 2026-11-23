"""用玩家自己的开发者证书签名（v0.2.4，#370）：导入一次 .p12 + .mobileprovision，之后出包装机都用它签，不走 Apple ID。

维护者定的规则（11-09）：
  ① 导入时解析并上屏：团队名、证书 / 描述文件到期、连着的手机在不在设备列表（企业「所有设备」描述文件没有列表，照实说）、包名、权限够不够；
     问题只提示、不挡出包和装机。只有根本签不了才停：私钥解不开（密码不对 / 文件坏），证书和描述文件不配套。
     分发描述文件（没有 get-task-allow）照常导入（0.6.3 维护者定；是不是分发按存着的描述文件现算，见 distribution）：通用壳的游戏程序在 App 外映射，iOS 只对带它的 App 放行；
     「独立 App」出法（一 App 一游戏）程序在 App 包里、随安装验签，照样能玩——默认出法据此改成独立 App（install.chosen_layout）。
     缺哪几项权限逐条列「中文名（技术名）——后果」，并给一段可一键复制、直接发给证书发放人的话（requestText）。
  ② 包名取描述文件的；通配（TEAM.*）→ io.s2arm.games.<小写团队号>（同 Apple ID 模式的算法）；权限 = 描述文件允许的 ∩ S2Arm 要的。
     独立 App 按款另起包名（bundle_id(profile, gid)）：通配 → io.s2arm.games.<团队>.<程序号 16 位小写>，前缀通配 com.x.* → com.x.s2arm.<程序号>，显式 → 只有它那一个
  ③ 两端都用 rcodesign（apple-codesign，MPL-2.0，官方发布件、SHA-256 钉在下面）直接读 p12 签名：不进钥匙串、不要 Xcode。
     rcodesign 读不了新式（PBES2 / AES）加密的 p12，导入时规整成老式（3DES）再存：Mac 用系统自带 openssl（LibreSSL），Windows 用 .NET；
     私钥只经管道、不落明文，规整后的 p12 仍用原密码加密。
  ④ 证书只存本机数据目录（<私有目录>/devcert/）；密码 Mac 存钥匙串（通用密码项），Windows 用 DPAPI（当前用户）加密存文件；可删。
  ⑤ 密码从不进请求文件（请求会留在 logs/jobs/ 里）：启动器用环境变量 S2A_DEVCERT_PASSWORD 只交给导入那一次作业，
     main.run_request 一开始就从环境里摘掉（Context.env() 也不往下传 S2A_*）。
S2Arm 的云存档走 iCloud 云盘里玩家选的文件夹（书签授权），不用 iCloud 容器权限：换开发者证书签不影响云存档，不提示「云存档不可用」。
"""
from __future__ import annotations

import base64
import contextlib
import datetime
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import zipfile
from pathlib import Path

from core import Failure, atomic, read, replace_retrying
from errors import device_of, on_device

# S2Arm 要的权限：提高内存上限（大游戏必需，Apple ID 模式也带）+ 扩展寻址（付费账号才有，大地址窗口）；描述文件没开就不带、提示大游戏可能闪退
WANT = ("com.apple.developer.kernel.increased-memory-limit", "com.apple.developer.kernel.extended-virtual-addressing")
# S2Arm 要的全部权限（逐项体检用）：get-task-allow——通用壳的游戏程序在 App 外映射执行，iOS 只对带它的 App 放行（image_exec_cert）；
#   分发（App Store / Ad Hoc / 企业）描述文件不给它：通用壳里游戏打不开，「独立 App」照常（程序在 App 包里）→ 照常导入、warning 说清；只缺后两项同样只提示
REQUIRED = ("get-task-allow",) + WANT
# 缺项每条一句「中文名（技术名）——后果」：整句进翻译表，界面按行翻
MISSING_LINES = {
    "get-task-allow": "调试权限（get-task-allow）——没有它，通用 S2Arm 里的游戏打不开（「独立 App」不受影响）",
    WANT[0]: "提高内存上限（com.apple.developer.kernel.increased-memory-limit）——没有它大游戏可能内存不够、起不来",
    WANT[1]: "扩展寻址（com.apple.developer.kernel.extended-virtual-addressing）——没有它大游戏可能地址不够、起不来",
}
DISTRIBUTION_HEAD = "这是分发（发布）证书的描述文件，缺下面的权限：可以照常用它装「独立 App」（一个 App 一款游戏），通用 S2Arm 里的游戏用它签了打不开。"
DISTRIBUTION_TAIL = "要用通用 S2Arm：改用 Apple ID 登录签名，或复制下面这段话发给证书发放人，换成开发证书和开发描述文件后再导入。"
ENTITLEMENTS_HEAD = "描述文件缺下面的权限，小游戏照常，大游戏可能起不来："
ENTITLEMENTS_TAIL = "可以复制下面这段话发给证书发放人，补开后重新下载描述文件再导入。"
# 交身份时读不出 p12 私钥（_read_p12 / identity）：「{0}」填这次认出的设备类型（#1962，errors.on_device）
PRIVATE_KEY_UNREADABLE = "证书里的私钥读不出来，没能交给 {0} 上的 S2Arm：在设置里重新导入一次证书。"
NO_UDID_HINT = "没连着 iPhone：复制后把「<你的设备 UDID>」换成你手机的 UDID。"
# 给证书发放人的话：权限清单写全部三项（不只写缺的，照单开最省事）；按能力开的权限只能开在显式 App ID 上（苹果 QA1713），通配描述文件不带后两项
REQUEST_TEXT = ("请提供 Apple Development 开发证书（.p12，附密码）和对应的 iOS App Development 开发描述文件。描述文件要求：用显式 App ID（不要通配 *），"
                "包含我的设备 UDID：{0}，并开启以下权限：调试权限（get-task-allow）、提高内存上限（com.apple.developer.kernel.increased-memory-limit）、"
                "扩展寻址（com.apple.developer.kernel.extended-virtual-addressing）。")
REQUEST_TEXT_NO_UDID = ("请提供 Apple Development 开发证书（.p12，附密码）和对应的 iOS App Development 开发描述文件。描述文件要求：用显式 App ID（不要通配 *），"
                        "包含我的设备 UDID：<你的设备 UDID>，并开启以下权限：调试权限（get-task-allow）、提高内存上限（com.apple.developer.kernel.increased-memory-limit）、"
                        "扩展寻址（com.apple.developer.kernel.extended-virtual-addressing）。")
EXPIRY_WARN_DAYS = 30
KEYCHAIN_SERVICE = "io.s2arm.devcert"
PASSWORD_ENV = "S2A_DEVCERT_PASSWORD"

# rcodesign 官方发布件（github.com/indygreg/apple-platform-rs，标签 apple-codesign/0.29.0）：SHA-256 与发布页 .sha256 一致（11-09 核）。
#   发版打包（launchers/macos/bundle_engine.py、launchers/windows/bundle_prepare_win.py）按这里下载、核哈希、不符拒打，放进引擎 Binaries/Prepare/rcodesign/
RCODESIGN_VERSION = "0.29.0"
RCODESIGN_DOWNLOAD = f"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/{RCODESIGN_VERSION}/"
RCODESIGN_RELEASE = {
    "mac": (f"apple-codesign-{RCODESIGN_VERSION}-macos-universal.tar.gz", "d98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d", "rcodesign"),
    "win": (f"apple-codesign-{RCODESIGN_VERSION}-x86_64-pc-windows-msvc.zip", "54bb500e2da7a8de02fcae0f331d1cac6e6d7173b4281042ff9c528ba3159aaa", "rcodesign.exe"),
}
RCODESIGN_SOURCE = f"https://github.com/indygreg/apple-platform-rs/tree/apple-codesign/{RCODESIGN_VERSION}/apple-codesign"


def rcodesign_cache():
    return Path(os.environ.get("S2A_RCODESIGN_CACHE") or Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run") / "s2arm/cache/rcodesign" / ("v" + RCODESIGN_VERSION))


def fetch_rcodesign(dest, side, cache=None):
    """发版打包用：取 side（mac / win）的官方发布包（cache 里有就用，没有下载），核 SHA-256，解出 rcodesign 与许可原文 COPYING 到 dest"""
    import hashlib as _h, tarfile, urllib.request
    name, want, member = RCODESIGN_RELEASE[side]
    cache, dest = Path(cache or rcodesign_cache()), Path(dest)
    cache.mkdir(parents=True, exist_ok=True)
    src = cache / name
    if not src.is_file():
        tmp = src.with_suffix(".part")
        try:
            urllib.request.urlretrieve(RCODESIGN_DOWNLOAD + name, tmp)
        except OSError as e:
            raise SystemExit(f"【红】取不到 {RCODESIGN_DOWNLOAD + name}（{e}）：在能连 GitHub 的机器上下好放进 {cache}（或用 S2A_RCODESIGN_CACHE 指过去）再打")  # 非玩家句
        os.replace(tmp, src)
    got = _h.sha256(src.read_bytes()).hexdigest()
    if got != want:
        raise SystemExit(f"【红】{src} 的 SHA-256 是 {got}，钉的是 {want}：不是 apple-codesign {RCODESIGN_VERSION} 官方发布件，拒打")  # 非玩家句
    dest.mkdir(parents=True, exist_ok=True)
    top = name.rsplit(".tar.gz", 1)[0].rsplit(".zip", 1)[0]
    for inner, out in ((member, member), ("COPYING", "LICENSE-apple-codesign-MPL-2.0.txt")):
        if name.endswith(".zip"):
            with zipfile.ZipFile(src) as z:
                data = z.read(f"{top}/{inner}")
        else:
            with tarfile.open(src) as t:
                data = t.extractfile(f"{top}/{inner}").read()
        (dest / out).write_bytes(data)
    os.chmod(dest / member, 0o755)
    (dest / "来源.txt").write_text(f"rcodesign（apple-codesign {RCODESIGN_VERSION}，Gregory Szorc，MPL-2.0：LICENSE-apple-codesign-MPL-2.0.txt），官方发布件原样附带。\n"  # 非玩家句
                                  f"来源：{RCODESIGN_DOWNLOAD}{name}\n源码：{RCODESIGN_SOURCE}\n", encoding="utf-8")
    return dest / member


def rcodesign_path(c):
    """签名工具：S2A_RCODESIGN（开发用）> 引擎随包 Binaries/Prepare/rcodesign/ > PATH"""
    exe = "rcodesign.exe" if os.name == "nt" else "rcodesign"
    for p in (os.environ.get("S2A_RCODESIGN"), c.engine / "Binaries/Prepare/rcodesign" / exe, shutil.which("rcodesign")):
        if p and Path(p).is_file():
            return str(p)
    raise Failure("找不到签名工具 rcodesign：请重新安装完整的 S2Arm。", code="tool_missing")


def rcodesign_ents(ents):
    """rcodesign 的 -e / --entitlements-xml-path 是「作用范围:路径」格式、按第一个冒号拆：Windows 绝对路径带盘符（C:\\…）
    会把权限挂到不存在的路径「C」上（os error 3），目录名带冒号也拆错。所有给 rcodesign 传权限文件的地方都经这里：
    返回 (参数, 运行目录)——在权限文件所在目录里跑、只传不含冒号的文件名"""
    p = Path(ents)   # 文件名都是我们自己起的（ents.plist / downstream.entitlements / 出包时写的权限文件），不含冒号
    return ["-e", p.name], p.parent


# ---------- 解析 ----------

def parse_profile(data):
    """描述文件 = CMS 签名包着的 plist：Apple 发的内容是整段 OCTET STRING（不分块），直接截 <?xml … </plist>。
    不核 CMS 签名：真假由手机装机时判，这里只为读字段上屏、算包名和权限"""
    a, b = data.find(b"<?xml"), data.rfind(b"</plist>")
    if a < 0 or b < a:
        raise Failure("描述文件读不出来：选的不是 .mobileprovision，或文件坏了。", code="devcert_invalid")
    try:
        p = plistlib.loads(data[a:b + len(b"</plist>")])
    except Exception as e:
        raise Failure("描述文件读不出来：选的不是 .mobileprovision，或文件坏了。", code="devcert_invalid", internal=str(e)) from e
    if not isinstance(p, dict) or "Entitlements" not in p:
        raise Failure("描述文件里没有权限表：选的不是 iOS 描述文件。", code="devcert_invalid")
    return p


class pwfile:
    """交给 rcodesign 的密码文件（不上命令行）：0600、用完即删，放在 devcert 目录的临时子目录里"""

    def __init__(self, where, password):
        self.dir = tempfile.TemporaryDirectory(dir=where)
        self.path = Path(self.dir.name) / "pw"
        with os.fdopen(os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as f:
            f.write(password)

    def __enter__(self):
        return self.path

    def __exit__(self, *_):
        self.dir.cleanup()


def cert_info(rcs, p12, password):
    """rcodesign analyze-certificate 读 p12：解不开 = 密码不对或文件坏（根本签不了，停）。返回第一张（签名用）证书的字段"""
    with pwfile(Path(p12).parent, password) as pf:
        r = subprocess.run([rcs, "analyze-certificate", "--p12-file", str(p12), "--p12-password-file", str(pf)],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode:
        raise Failure("证书打不开：密码不对，或 .p12 文件坏了。", code="devcert_password", internal=r.stderr.strip()[-400:])
    info = {}
    for line in r.stdout.split("# Certificate 1")[0].splitlines():
        k, sep, v = line.partition(":")
        if sep and k.strip() in ("Subject CN", "Team ID", "SHA-1 fingerprint", "Not Valid After", "Not Valid Before"):
            info[k.strip()] = v.strip()
    if not info.get("SHA-1 fingerprint"):
        raise Failure("证书打不开：.p12 里没有证书。", code="devcert_invalid", internal=r.stdout[-400:])
    return info


def iso_date(s):
    try:
        d = datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


def bundle_id(profile, gid=None):
    """包名 → (包名, 能不能自己定)：描述文件的 application-identifier 去掉前缀；通配 * → io.s2arm.games.<小写团队号>（同 Apple ID 模式）；前缀通配 com.x.* → com.x.s2arm。
    gid（独立 App，一 App 一游戏）：通配 → io.s2arm.games.<小写团队号>.<程序号 16 位小写>（install.app_bundle_id，不用前 8 位：前 8 位会撞）；
    前缀通配 → com.x.s2arm.<程序号小写>；显式描述文件只有它那一个包名（第二个 False：通用壳与各款独立 App 都只能用它，装一个顶掉另一个）"""
    from install import app_bundle_id, container_bundle_id
    prefix = (profile.get("ApplicationIdentifierPrefix") or [""])[0]
    team = (profile.get("TeamIdentifier") or [prefix])[0]
    appid = profile["Entitlements"].get("application-identifier", "")
    rest = appid[len(prefix) + 1:] if prefix and appid.startswith(prefix + ".") else appid.partition(".")[2]
    if rest == "*":
        return (app_bundle_id(team, gid) if gid else container_bundle_id(team)), True
    if rest.endswith(".*"):
        return rest[:-1] + "s2arm" + (f".{gid.lower()}" if gid else ""), True
    return rest, False


def entitlements(profile, bid):
    """签进 App 的权限 = 必带的身份三项（按描述文件）+ WANT ∩ 描述文件允许的；描述文件没有的一项都不带（带了装不上）"""
    allow = profile["Entitlements"]
    prefix = (profile.get("ApplicationIdentifierPrefix") or [""])[0]
    team = (profile.get("TeamIdentifier") or [prefix])[0]
    ents = {"application-identifier": f"{prefix}.{bid}", "com.apple.developer.team-identifier": team}
    if "get-task-allow" in allow:
        ents["get-task-allow"] = bool(allow["get-task-allow"])
    for k in WANT:
        if allow.get(k) is True:
            ents[k] = True
    return ents


def inspect(rcs, p12, password, profile_bytes, udid=None, now=None):
    """导入 / 状态共用的体检：{blocking:[…], warnings:[…], 上屏字段…}。blocking 非空 = 根本签不了"""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    prof = parse_profile(profile_bytes)
    cert = cert_info(rcs, p12, password)
    blocking, warnings = [], []
    sha1 = cert["SHA-1 fingerprint"].replace(":", "").lower()
    in_profile = {hashlib.sha1(d).hexdigest() for d in prof.get("DeveloperCertificates") or []}
    if sha1 not in in_profile:
        blocking.append(dict(id="devcert_mismatch", text="证书和描述文件不配套：这份描述文件里没有这张证书，签出来装不上。请在开发者网站重新生成包含这张证书的描述文件。"))
    bid, wildcard = bundle_id(prof)
    ents = entitlements(prof, bid)
    allow = prof["Entitlements"]
    missing = [k for k in REQUIRED if allow.get(k) is not True]
    distribution = "get-task-allow" in missing
    request = None
    if missing:
        hint = [] if udid else [NO_UDID_HINT]
        lines = [MISSING_LINES[k] for k in missing]
        if distribution:   # 分发描述文件：照常导入（独立 App 能用），说清通用壳里游戏打不开、给发放人的话照旧
            warnings.append(dict(id="devcert_distribution", text="\n".join([DISTRIBUTION_HEAD, *lines, DISTRIBUTION_TAIL, *hint])))
        else:
            warnings.append(dict(id="devcert_entitlements", text="\n".join([ENTITLEMENTS_HEAD, *lines, ENTITLEMENTS_TAIL, *hint])))
        request = REQUEST_TEXT.format(udid) if udid else REQUEST_TEXT_NO_UDID
    cert_end, prof_end = iso_date(cert.get("Not Valid After")), prof.get("ExpirationDate")
    if isinstance(prof_end, datetime.datetime) and not prof_end.tzinfo:
        prof_end = prof_end.replace(tzinfo=datetime.timezone.utc)
    # 句子按证书 / 描述文件各写一句（只留日期、天数占位）：启动器按整句句式翻译，不拼名词
    for end, expired, expiring in ((cert_end, "证书已于 {0} 过期：签出来的 App 装不上或打不开，请换新的证书。", "证书将于 {0} 到期（还剩 {1} 天）：到期后 App 打不开，记得提前换新。"),
                                   (prof_end, "描述文件已于 {0} 过期：签出来的 App 装不上或打不开，请换新的描述文件。", "描述文件将于 {0} 到期（还剩 {1} 天）：到期后 App 打不开，记得提前换新。")):
        if not end:
            continue
        days = (end - now).total_seconds() / 86400
        if days < 0:
            warnings.append(dict(id="devcert_expired", text=expired.format(f"{end:%Y-%m-%d}")))
        elif days < EXPIRY_WARN_DAYS:
            warnings.append(dict(id="devcert_expiring", text=expiring.format(f"{end:%Y-%m-%d}", int(days))))
    all_devices = bool(prof.get("ProvisionsAllDevices"))
    listed = None
    if all_devices:
        listed = True
    elif udid:
        listed = udid.upper() in {u.upper() for u in prof.get("ProvisionedDevices") or []}
        if not listed:
            warnings.append(dict(id="devcert_device", text="连着的这台 iPhone 不在描述文件的设备列表里：签出来装不上这台。请在开发者网站登记这台设备并重新生成描述文件。"))
    return dict(blocking=blocking, warnings=warnings, teamName=prof.get("TeamName") or "", teamId=(prof.get("TeamIdentifier") or [""])[0],
                certName=cert.get("Subject CN", ""), certSha1=sha1, certExpires=cert_end.strftime("%Y-%m-%d") if cert_end else "",
                profileName=prof.get("Name") or "", profileExpires=prof_end.strftime("%Y-%m-%d") if isinstance(prof_end, datetime.datetime) else "",
                bundleId=bid, wildcard=wildcard, allDevices=all_devices, deviceCount=len(prof.get("ProvisionedDevices") or []),
                deviceListed=listed, entitlements=sorted(k for k in ents if k in WANT), missingEntitlements=missing, distribution=distribution,
                **({"requestText": request} if request else {}))


def blocked(got):
    """体检有根本签不了的问题 → 第一条的失败；缺项和给发放人的话作为机读事实带给前端（导入失败页直接给「复制」）"""
    facts = {k: got[k] for k in ("missingEntitlements", "requestText") if got.get(k)}
    return Failure(got["blocking"][0]["text"], code=got["blocking"][0]["id"], facts=facts or None)


# ---------- p12 规整 ----------

def normalize_p12(src, dest, password):
    """新式加密（PBES2 / AES，openssl 3 与新版钥匙串导出的默认）rcodesign 读不了：读出来按老式 3DES 原密码重新导出。私钥只走管道 / 内存"""
    env = dict(os.environ, S2A_P12_PW=password, S2A_P12_IN=str(src), S2A_P12_OUT=str(dest))
    if os.name == "nt":
        ps = ("$ErrorActionPreference='Stop';$f=[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable;"
              "$c=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection;$c.Import($env:S2A_P12_IN,$env:S2A_P12_PW,$f);"
              "[IO.File]::WriteAllBytes($env:S2A_P12_OUT,$c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,$env:S2A_P12_PW))")
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], env=env, capture_output=True, text=True, errors="replace")
        ok, why = r.returncode == 0, r.stderr
    else:
        # 系统自带 LibreSSL：读得了 PBES2，导出缺省就是老式 3DES。导出时私钥和证书要分两路读（同一路标准输入它会读两遍、第二遍空），
        #   解出的 PEM 只在内存里拆成私钥 / 证书两段，各走一根管道（/dev/fd/3、/dev/fd/4），不落盘
        osl = "/usr/bin/openssl"
        a = subprocess.run([osl, "pkcs12", "-in", str(src), "-passin", "env:S2A_P12_PW", "-nodes"], env=env, capture_output=True)
        pem = a.stdout.decode("ascii", errors="replace")
        blocks = re.findall(r"-----BEGIN ([A-Z ]+)-----.*?-----END \1-----\n?", pem, re.S)
        keys = "".join(m.group(0) for m in re.finditer(r"-----BEGIN ([A-Z ]*PRIVATE KEY)-----.*?-----END \1-----\n?", pem, re.S))
        certs = "".join(m.group(0) for m in re.finditer(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?", pem, re.S))
        ok, why = False, a.stderr.decode(errors="replace")
        if a.returncode == 0 and blocks and keys and certs:
            kr, kw = os.pipe()
            cr, cw = os.pipe()
            for w, text in ((kw, keys), (cw, certs)):   # 几 KB，管道缓冲装得下：先写完再起读方
                os.write(w, text.encode("ascii"))
                os.close(w)
            try:
                b = subprocess.run([osl, "pkcs12", "-export", "-inkey", f"/dev/fd/{kr}", "-in", f"/dev/fd/{cr}", "-passout", "env:S2A_P12_PW", "-out", str(dest)],
                                   env=env, capture_output=True, pass_fds=(kr, cr))
            finally:
                os.close(kr)
                os.close(cr)
            ok, why = b.returncode == 0, why + b.stderr.decode(errors="replace")
        elif a.returncode == 0:
            why += "；p12 里缺私钥或证书"  # 非玩家句
    if not ok or not Path(dest).is_file():
        Path(dest).unlink(missing_ok=True)
        raise Failure("证书打不开：密码不对，或 .p12 文件坏了。", code="devcert_password", internal=why.strip()[-400:])
    os.chmod(dest, 0o600)


# ---------- 密码保管 ----------

def _dpapi(data, protect):
    import ctypes
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]
    buf = ctypes.create_string_buffer(data, len(data))
    src, out = Blob(len(data), ctypes.cast(ctypes.addressof(buf), ctypes.POINTER(ctypes.c_char))), Blob()
    fn = ctypes.windll.crypt32.CryptProtectData if protect else ctypes.windll.crypt32.CryptUnprotectData
    if not fn(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError(ctypes.GetLastError(), "DPAPI 失败")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


class Secrets:
    """密码保管：Mac 钥匙串通用密码项（服务 io.s2arm.devcert，账户 = 证书 SHA-1；security -i 从标准输入读命令，密码不上命令行；
    存的是密码 UTF-8 的 base64：security find-generic-password -w 遇到非 ASCII 会改吐十六进制，和本来就像十六进制的密码分不开），
    Windows DPAPI 当前用户加密存 <devcert>/password.dpapi。单测换成内存里的"""

    def __init__(self, folder):
        self.folder = Path(folder)

    def save(self, account, password):
        if os.name == "nt":
            (self.folder / "password.dpapi").write_bytes(_dpapi(password.encode("utf-8"), True))
            return
        encoded = base64.b64encode(password.encode("utf-8")).decode("ascii")
        r = subprocess.run(["/usr/bin/security", "-i"], input=f'add-generic-password -U -s {KEYCHAIN_SERVICE} -a {account} -l "S2Arm developer certificate" -w {encoded}\n',
                           capture_output=True, text=True)
        if r.returncode or "error" in (r.stdout + r.stderr).lower():
            raise Failure("证书密码没存进钥匙串：" + (r.stderr or r.stdout).strip()[-200:], code="devcert_keychain")  # 非玩家句

    def load(self, account):
        if os.name == "nt":
            f = self.folder / "password.dpapi"
            return _dpapi(f.read_bytes(), False).decode("utf-8") if f.is_file() else None
        r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"], capture_output=True, text=True)
        if r.returncode:
            return None
        try:
            return base64.b64decode(r.stdout.strip(), validate=True).decode("utf-8")
        except ValueError:
            return None

    def delete(self, account):
        if os.name == "nt":
            (self.folder / "password.dpapi").unlink(missing_ok=True)
        else:
            subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account], capture_output=True)


# ---------- 存储与作业 ----------
# 多张证书（#487，11-17）：按设备买的证书描述文件只登记一台的 UDID，一台一张。
#   <私有目录>/devcert/entries.json  {schema: 2, entries: {条目号: {certSha1, profileUuid, appId, bundleId, teamId, teamName, profileName, imported}}, devices: {UDID: 条目号}}
#   <私有目录>/devcert/entries/<条目号>/cert.p12、profile.mobileprovision（Windows 另有 password.dpapi）
#   <私有目录>/devcert/state.json + cert.p12 / profile.mobileprovision / password.dpapi：旧版格式，照抄缺省条目（最早导入的那张）+ 签名方式开关 active。
#     旧版启动器只认这一份：降级回去照样能签；旧版在这里导入 / 换了证书 → 下次读时它不在条目里，就加成一个新条目（不重建、不丢别的条目）。
#   条目号 = 第一次导入时描述文件的 UUID：同一张 .p12 配每台各自的描述文件 = 几个条目。同证书、同名、同 App ID、设备只多不少 = 续期，就地换、条目号和各台的选择不变。
#   密码按证书 SHA-1 存（旧版同）：同一张证书再导入时，把新规整的 p12 写进用这张证书的每个条目（各条目都用最新的密码打得开）；没有条目再用这张证书时才删。
#   devices = 玩家给每台选定的条目（Mac 启动器在这台第一次连上时问）。没选过的按 resolve：这台现装 App 的包名对得上的 > 描述文件管这台的（新导入的优先）>
#   只有一张；都不是 → devcert_choose。作业一认出目标设备就 bind(c, udid)，之后 active / state / team / stored / sign_app 读的都是这台那张。
#   改写一律在 devcert/.state.lock 里做（同一作业里可重入）

LOCK_WAIT_S = 30
ROOT_FILES = ("cert.p12", "profile.mobileprovision", "password.dpapi")


def folder(c):
    d = c.private / "devcert"
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def entry_dir(c, eid):
    return folder(c) / "entries" / eid


def secrets(c, eid=None):
    return getattr(c, "devcert_secrets", None) or Secrets(entry_dir(c, eid) if eid else folder(c))


def _put(dst, src=None, data=None):
    """整份换文件（临时文件 + 改名）：签名读这些文件时不拿锁，不能让它读到半份"""
    dst = Path(dst)
    tmp = dst.with_name(dst.name + ".tmp")
    try:
        if src is not None:
            shutil.copy2(src, tmp)
        else:
            tmp.write_bytes(data)
        replace_retrying(tmp, dst)
    finally:
        tmp.unlink(missing_ok=True)


def _udid(u):
    return str(u or "").strip().upper()


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def _profile_at(path):
    try:
        return parse_profile(Path(path).read_bytes())
    except (OSError, Failure):
        return None


def _appid(prof):
    return (prof or {}).get("Entitlements", {}).get("application-identifier", "")


def _udids(prof):
    return {_udid(u) for u in (prof or {}).get("ProvisionedDevices") or []}


@contextlib.contextmanager
def _locked(c):
    """devcert 读改写锁；同一作业、同一线程里嵌套调用不再拿（可重入）。计数按线程分：EarlyInstall 在子线程里拿锁时照常排队"""
    held = c.__dict__.setdefault("_devcert_lock_held", set())
    me = threading.get_ident()
    if me in held:
        yield
        return
    import filelock
    try:
        with filelock.held(folder(c) / ".state.lock", wait_s=LOCK_WAIT_S):
            held.add(me)
            try:
                yield
            finally:
                held.discard(me)
    except filelock.Busy as e:
        raise Failure("开发者证书正被另一个任务读写，稍后再试。") from e  # 非玩家句


UNREADABLE = "这次没能读到开发者证书设置（这台电脑拒绝 S2Arm 读它自己的证书设置文件夹），按 Apple ID 签名。如果你启用过自己的开发者证书，这次没有用它。"


def _raw(c):
    """证书库原样（entries.json + 根下 state.json）。读不了（Windows 拒绝访问，D-BW75 / #3c209a：整个 devcert 目录进不去、连属性都取不到）
    = 当作没导入、没启用证书：只是「用不用开发者证书」这个开关，Apple ID 那条路照样走得通，不为它挡装机（原先抛到 update_phone，
    「S2Arm 自己的文件读写不了」×14）。原因每个作业记一次进作业日志"""
    try:
        d = folder(c)
        e, root = read(d / "entries.json") or {}, read(d / "state.json") or {}
        e, root = (e if isinstance(e, dict) else {}), (root if isinstance(root, dict) else {})
        entries = {k: v for k, v in (e.get("entries") or {}).items() if isinstance(v, dict) and (entry_dir(c, k) / "cert.p12").is_file()}   # 文件没了的不算
    except PermissionError as error:
        if not getattr(c, "_devcert_state_denied", False):
            try:
                c._devcert_state_denied = True
            except AttributeError:
                pass
            print(f"[s2a] 【黄】开发者证书设置读不了（{error}），这次当作没启用证书、按 Apple ID 签名", file=sys.stderr, flush=True)  # 非玩家句
            # 不悄悄换签法：结果页黄字说清这次没读到证书设置、改用 Apple ID（读不到就不知道玩家启没启用过，按「如果启用过」说）
            if callable(getattr(c, "diagnostic", None)):
                c.diagnostic(UNREADABLE, code="devcert_unreadable", severity="warning", internal=str(error))
        return dict(active=False, entries={}, devices={}), {}
    return dict(active=bool(root.get("active")), entries=entries, devices=dict(e.get("devices") or {})), root


def _stray_root(c, s, root):
    """根下（旧版格式）那张不在条目里：首次升级、或降级时旧版导入 / 换过证书 → 返回它的 (证书 SHA-1, 描述文件)；在 → None"""
    d = folder(c)
    sha = root.get("certSha1")
    if not sha or not (d / "cert.p12").is_file():
        return None
    prof = _profile_at(d / "profile.mobileprovision") or {}
    uuid = str(prof.get("UUID") or "").lower()
    if any(v.get("certSha1") == sha and (v.get("profileUuid") or "") == uuid for v in s["entries"].values()):
        return None
    return sha, prof


def store(c):
    """证书库 {active, entries, devices}；根下有不在条目里的那张（旧版留下的）就在锁里加成条目"""
    s, root = _raw(c)
    if _stray_root(c, s, root):
        with _locked(c):
            s, root = _raw(c)
            stray = _stray_root(c, s, root)
            if stray:
                sha, prof = stray
                eid = _fresh_id(s, str(prof.get("UUID") or sha).lower())
                to = entry_dir(c, eid)
                to.mkdir(parents=True, exist_ok=True)
                for n in ROOT_FILES:
                    if (folder(c) / n).is_file():
                        _put(to / n, folder(c) / n)
                s["entries"][eid] = dict(certSha1=sha, profileUuid=str(prof.get("UUID") or "").lower(), appId=_appid(prof),
                                         bundleId=root.get("bundleId", ""), teamId=root.get("teamId", ""), teamName=root.get("teamName", ""),
                                         profileName=prof.get("Name") or "", imported=root.get("imported") or _now())
                _write(c, s)
    return s


def _fresh_id(s, base):
    eid, n = base, 2
    while eid in s["entries"]:
        eid, n = f"{base}-{n}", n + 1
    return eid


def _write(c, s):
    """写条目表 + 根下旧版那份（缺省条目 = 最早导入的 + active）。只在 _locked 里调"""
    d = folder(c)
    first = next(iter(s["entries"]), None)
    if not first:
        for n in ("entries.json", "state.json") + ROOT_FILES:
            (d / n).unlink(missing_ok=True)
        shutil.rmtree(d / "entries", ignore_errors=True)
        return
    for n in ROOT_FILES:   # 给旧版的那份先写、条目表最后写：中途断了不会让删掉 / 换掉的那张复活
        src = entry_dir(c, first) / n
        if src.is_file():
            _put(d / n, src)
        else:
            (d / n).unlink(missing_ok=True)
    m = s["entries"][first]
    atomic(d / "state.json", dict(active=bool(s["active"]), certSha1=m.get("certSha1", ""), bundleId=m.get("bundleId", ""), teamId=m.get("teamId", ""),
                                  teamName=m.get("teamName", ""), imported=m.get("imported", "")))
    atomic(d / "entries.json", dict(schema=2, entries=s["entries"], devices=s["devices"]))


def covers(c, eid, udid):
    """这个条目的描述文件管不管这台：True / False；描述文件读不出 → None"""
    prof = _profile_at(entry_dir(c, eid) / "profile.mobileprovision")
    if prof is None:
        return None
    return bool(prof.get("ProvisionsAllDevices")) or _udid(udid) in _udids(prof)


def _installed_bid(c, udid):
    """这台的设备记录里现装 App 的包名。直接读文件：layout.load_device 会认领旧容器记录（改名），这里只读不改"""
    lib = getattr(c, "library", None)
    if not udid or not lib:
        return ""
    import layout
    for key in dict.fromkeys((str(udid).strip(), _udid(udid), str(udid).strip().lower())):
        rec = read(layout.device_path(c, key), {})
        if isinstance(rec, dict) and rec.get("bundleId"):
            return rec["bundleId"]
    return ""


def _newest(s, ids):
    return max(ids, key=lambda k: s["entries"][k].get("imported") or "") if ids else None


def _by_installed(c, s, udid):
    """包名对得上这台现装 App、描述文件又不排除这台的那几条（同团队两份通配描述文件算出的包名一样：管不管这台先筛掉）"""
    bid = _installed_bid(c, udid)
    return [k for k, v in s["entries"].items() if bid and v.get("bundleId") == bid and covers(c, k, udid) is not False]


def resolve(c, udid, s=None):
    """这台用哪个条目：玩家选过的（还在）> 这台现装 App 包名对得上的 > 描述文件管这台的 > 只有一张 > None（要玩家选）；同档几张取最新导入的"""
    s = s or store(c)
    if not s["entries"]:
        return None
    if udid:
        chosen = s["devices"].get(_udid(udid))
        if chosen in s["entries"]:
            return chosen
        hit = _newest(s, _by_installed(c, s, udid))
        hit = hit or _newest(s, [k for k in s["entries"] if covers(c, k, udid)])
        if hit:
            return hit
    return next(iter(s["entries"])) if len(s["entries"]) == 1 else None


def needs_choice(c, udid, s=None):
    """启动器要不要问这台：证书模式、不止一张证书、这台没选过、也没有包名对得上它现装 App 的（老玩家已在用的那台不问）。
    只有一张不问：同旧版，就用它"""
    s = s or store(c)
    if not (udid and s["active"] and len(s["entries"]) > 1):
        return False
    if s["devices"].get(_udid(udid)) in s["entries"]:
        return False
    return not _by_installed(c, s, udid)


def bind(c, udid):
    """作业认出目标设备后调（每次都覆盖，空串 = 不绑）：本作业之后的证书读取都按这台。换了设备才清掉本作业定下的那张"""
    u = _udid(udid)
    if getattr(c, "devcert_udid", None) != u:
        c.devcert_entry = None
    c.devcert_udid = u


CHOOSE = "有几张开发者证书，这台设备还没选用哪一张：在启动器里给这台选一张证书再装。"


def _need(c, s):
    """本作业用的那张：第一次挑定后记在作业对象上（包名、团队、签名、remember 都是这一张；中途有人导入新证书也不换）"""
    if not s["entries"]:
        raise Failure("还没导入开发者证书。", code="devcert_missing")
    eid = getattr(c, "devcert_entry", None)
    if eid in s["entries"]:
        return eid
    eid = resolve(c, getattr(c, "devcert_udid", "") or "", s)
    if eid is None:
        raise Failure(CHOOSE, code="devcert_choose")
    c.devcert_entry = eid
    return eid


def _shown(c, s):
    """只为显示（出包页 / 没选设备的清单）：按绑定的设备挑得出就用它，挑不出用缺省条目；不报错"""
    return resolve(c, getattr(c, "devcert_udid", "") or "", s) or next(iter(s["entries"]), None)


def active(c):
    """出包装机用不用开发者证书：玩家在出包页选了「我的开发者证书」且至少有一张"""
    s = store(c)
    return bool(s["active"] and s["entries"])


def state(c):
    """本作业（按绑定的设备）那张的 {active, certSha1, bundleId, teamId, teamName, entry}；没导入 → {}；几张里挑不出 → devcert_choose"""
    s = store(c)
    if not s["entries"]:
        return {}
    eid = _need(c, s)
    return dict(s["entries"][eid], active=s["active"], entry=eid)


def ready(c):
    """设置里选「自己的证书」前查：至少导入了一张、（按绑定的设备，没绑用缺省那张）不缺件；不报 devcert_choose。没有 / 缺件 → devcert_missing"""
    s = store(c)
    if not s["entries"]:
        raise Failure("还没导入开发者证书。", code="devcert_missing")
    stored(c, _shown(c, s))


def set_active(c, on):
    """切「在用」开关（同 operation use，但没导入时不报错、什么也不做）"""
    with _locked(c):
        s = store(c)
        if s["entries"] and s["active"] != bool(on):
            s["active"] = bool(on)
            _write(c, s)


def team(c):
    """开发者证书模式下的签名账号（同 install.pick_team 的形状）；没在用 → None"""
    if not active(c):
        return None
    s = state(c)
    return dict(id=s["teamId"], name=s.get("teamName") or s["teamId"], free=False)


def stored(c, eid=None):
    """签名要的三样：规整后的 p12、描述文件字节、密码；缺一样 = 要重新导入"""
    s = store(c)
    eid = eid or _need(c, s)
    d = entry_dir(c, eid)
    sha = (s["entries"].get(eid) or {}).get("certSha1", "")
    pw = secrets(c, eid).load(sha) if sha else None
    if not (d / "cert.p12").is_file() or not (d / "profile.mobileprovision").is_file() or pw is None:
        raise Failure("开发者证书不完整（证书、描述文件或密码缺了）：在出包页重新导入一次。", code="devcert_missing")
    return d / "cert.p12", (d / "profile.mobileprovision").read_bytes(), pw


def remember(c):
    """App 装好了：这台还没记过选哪张 → 记下这次签名实际用的那张（_need 定在作业对象上的，不重挑）。尽力而为：记不下不影响已装好的结果"""
    udid, eid = getattr(c, "devcert_udid", ""), getattr(c, "devcert_entry", None)
    try:
        if not udid or not eid or not active(c):
            return
        with _locked(c):
            s = store(c)
            if eid in s["entries"] and s["devices"].get(udid) not in s["entries"]:
                s["devices"][udid] = eid
                _write(c, s)
    except (Failure, OSError) as e:
        print(f"[证书] 没记下这台用的证书：{e}", file=sys.stderr, flush=True)  # 非玩家句


def _profile_bytes(c):
    """本作业那张的描述文件字节（只看描述文件、不要密码和 p12）：有条目 → 绑定设备那张（_need，几张里挑不出报 devcert_choose）；
    没有条目（旧版根下只有描述文件、没 p12 不迁移）→ 根下那份。读不到抛 OSError / Failure"""
    s = store(c)
    d = entry_dir(c, _need(c, s)) if s["entries"] else folder(c)
    return (d / "profile.mobileprovision").read_bytes()


def distribution(c):
    """存着的描述文件缺 get-task-allow（分发 / ad hoc / 企业）：通用壳的游戏程序在 App 外映射会被系统拒（image_exec_cert）。
    按描述文件现算、不记在 state.json：导入时才记的话，这项判断上线前导入的证书永远认不出来；描述文件没了或读不出 → 不算"""
    try:   # 多张证书（#487）：按本作业绑定的设备那张；根目录那份只是缺省条目的旧版副本
        allow = parse_profile(_profile_bytes(c))["Entitlements"]
    except (OSError, Failure):
        return False
    return allow.get("get-task-allow") is not True


def _orch(c):
    """pack/orch/install_win.py 里的 DER 小工具（pkcs1_der / cert_modulus_and_start，两端通用的纯 Python）：按请求给的引擎树（c.engine）导入，
    同 install.win_install_mod（App 里作业层和引擎分两处，按本文件位置找不到 pack/orch）；引擎树里没有时（单测的空引擎）才退回本文件所在的源码树"""
    import sys
    d = Path(c.engine) / "pack/orch"
    d = str(d if (d / "install_win.py").is_file() else Path(__file__).resolve().parents[1] / "orch")
    if d not in sys.path:
        sys.path.insert(0, d)
    import install_win
    return install_win


def _der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def _der_int(raw):
    """大端无符号字节 → DER INTEGER（去前导零，最高位是 1 就补一个 0）"""
    raw = raw.lstrip(b"\0") or b"\0"
    if raw[0] & 0x80:
        raw = b"\0" + raw
    return b"\x02" + _der_len(len(raw)) + raw


def _pkcs1_from_params(p):
    """.NET RSAParameters（各字段 base64、大端）→ RSAPrivateKey（PKCS#1）DER"""
    body = _der_int(b"\0") + b"".join(_der_int(base64.b64decode(p[k])) for k in ("Modulus", "Exponent", "D", "P", "Q", "DP", "DQ", "InverseQ"))
    return b"\x30" + _der_len(len(body)) + body


def _key_modulus(c, der):
    w = _orch(c)
    _, s, e = w._tlv(der, 0)
    _, ms, me = w._children(der, s, e)[1]
    return int.from_bytes(der[ms:me], "big")


def _read_p12(c, p12, password):
    """规整后的 p12 → (PKCS#1 私钥 DER, 签名用的那张证书 DER)。私钥只在内存里（管道 / 标准输出），不落盘"""
    env = dict(os.environ, S2A_P12_PW=password, S2A_P12_IN=str(p12))
    if os.name == "nt":
        ps = ("$ErrorActionPreference='Stop';$f=[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable;"
              "$c=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection;$c.Import($env:S2A_P12_IN,$env:S2A_P12_PW,$f);"
              "$x=$c|Where-Object{$_.HasPrivateKey}|Select-Object -First 1;"
              "$k=[System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($x).ExportParameters($true);"
              "$o=@{cert=[Convert]::ToBase64String($x.RawData)};foreach($n in 'Modulus','Exponent','D','P','Q','DP','DQ','InverseQ'){$o[$n]=[Convert]::ToBase64String($k.$n)};"
              "$o|ConvertTo-Json -Compress")
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], env=env, capture_output=True, text=True, errors="replace")
        if r.returncode:
            raise Failure(on_device(PRIVATE_KEY_UNREADABLE, device_of(c)), code="devcert_invalid", internal=r.stderr.strip()[-400:])
        import json
        got = json.loads(r.stdout)
        return _pkcs1_from_params(got), base64.b64decode(got["cert"])
    r = subprocess.run(["/usr/bin/openssl", "pkcs12", "-in", str(p12), "-passin", "env:S2A_P12_PW", "-nodes", "-clcerts"], env=env, capture_output=True)
    pem = r.stdout.decode("ascii", errors="replace")
    keys = re.findall(r"-----BEGIN ([A-Z ]*PRIVATE KEY)-----.*?-----END \1-----", pem, re.S)
    key = re.search(r"-----BEGIN ([A-Z ]*PRIVATE KEY)-----.*?-----END \1-----", pem, re.S)
    cert = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)
    der = _orch(c).pkcs1_der(key.group(0)) if key else None
    if r.returncode or len(keys) != 1 or not cert or der is None:
        raise Failure(on_device(PRIVATE_KEY_UNREADABLE, device_of(c)), code="devcert_invalid",
                      internal=r.stderr.decode(errors="replace").strip()[-400:])
    return der, base64.b64decode("".join(cert.group(1).split()))


def identity(c):
    """0.6.0 通用壳（install.deliver_identity）：证书签名用户交给 App 的身份——导入时存的 p12 里的私钥（PKCS#1）+ 签名用的那张证书（DER）。
    → {key, cert, created, key_fp, team}；key_fp = 存着的 p12 文件 SHA-256 前 16 位（换证书 / 重新导入就变，调用方据此判「交过了」）。
    没在用自己的证书 → None；证书缺件 / 读不出私钥 / 私钥和证书对不上 → Failure"""
    if not active(c):
        return None
    p12, _, pw = stored(c)
    key, cert = _read_p12(c, p12, pw)
    mod, created = _orch(c).cert_modulus_and_start(cert)
    if mod is None or mod != _key_modulus(c, key):
        raise Failure(on_device(PRIVATE_KEY_UNREADABLE, device_of(c)), code="devcert_invalid", internal="私钥与证书公钥对不上")  # 非玩家句（internal 只进日志）
    return dict(key=key, cert=cert, created=created, key_fp=hashlib.sha256(Path(p12).read_bytes()).hexdigest()[:16], team=team(c)["id"])


def summary(c, udid=None, eid=None):
    """一个条目的体检结果（启动器出包页 / 装机前清单用）：缺省 = 这台的那张，挑不出用缺省条目；没导入 → None。不报 devcert_choose"""
    s = store(c)
    if not s["entries"]:
        return None
    if udid:
        bind(c, udid)
    eid = eid or _shown(c, s)
    p12, prof, pw = stored(c, eid)
    return dict(inspect(rcodesign_path(c), p12, pw, prof, udid=udid), active=active(c), entry=eid)


def listing(c, udid=None, s=None):
    """所有条目（启动器选证书用；只解析描述文件，不读密码、不跑 rcodesign）"""
    s = s or store(c)
    installed = _installed_bid(c, udid)
    out = []
    for eid, meta in s["entries"].items():
        prof = _profile_at(entry_dir(c, eid) / "profile.mobileprovision") or {}
        end = prof.get("ExpirationDate")
        out.append(dict(entry=eid, certSha1=meta.get("certSha1", ""), bundleId=meta.get("bundleId", ""), teamId=meta.get("teamId", ""),
                        teamName=meta.get("teamName", ""), profileName=prof.get("Name") or meta.get("profileName", ""),
                        profileExpires=end.strftime("%Y-%m-%d") if isinstance(end, datetime.datetime) else "",
                        allDevices=bool(prof.get("ProvisionsAllDevices")), deviceCount=len(prof.get("ProvisionedDevices") or []),
                        deviceListed=covers(c, eid, udid) if udid else None,
                        installedHere=bool(installed) and installed == meta.get("bundleId")))
    return out


def _drop_secret(c, s, sha, eid):
    """这张证书的密码：没有别的条目再用它才删（Windows 删的是这个条目目录里那份）"""
    if sha and not any(v.get("certSha1") == sha for k, v in s["entries"].items() if k != eid):
        secrets(c, eid).delete(sha)


def _renewal(c, s, sha, prof):
    """续期：同证书、同名、同 App ID，设备只多不少（或两份都是所有设备）→ 那个条目号；不是 → None"""
    for k, v in s["entries"].items():
        if v.get("certSha1") != sha or v.get("profileName") != (prof.get("Name") or "") or v.get("appId") != _appid(prof):
            continue
        old = _profile_at(entry_dir(c, k) / "profile.mobileprovision") or {}
        if (bool(old.get("ProvisionsAllDevices")) and bool(prof.get("ProvisionsAllDevices"))) or _udids(old) <= _udids(prof):
            return k
    return None


# 只选了 .p12（#2015：免费 Apple ID 拿不到描述文件，例如从 SideStore 导出的证书）：交给 Apple ID 签名当这个团队的证书，描述文件由 plumesign 用账号自己申请
ADOPT_NO_LOGIN = ("只选了 .p12 证书时，S2Arm 用你登录的 Apple ID 自己申请描述文件：先用 Apple ID 登录再导入；"
                  "不用 Apple ID 的话，请再选上这张证书配套的描述文件（.mobileprovision）。")
ADOPT_OLD_TOOL = "这个版本的签名工具还不能沿用导入的证书：更新 S2Arm 后再导入，或者再选上这张证书配套的描述文件（.mobileprovision）。"
ADOPT_ABSENT = ("这张证书不在当前登录的 Apple ID（团队 {0}）的证书列表里：它可能属于别的 Apple ID，或已被撤销。"
                "改用这张证书所属的 Apple ID 登录后再导入，或者再选上这张证书配套的描述文件（.mobileprovision）。")
ADOPT_UNLISTED = "没能列出这个 Apple ID 的证书（网络不通或登录已过期），这次什么都没改：检查网络、必要时重新登录 Apple ID，再导入一次。"
ADOPT_DONE = ("已改用这张证书：之后用 Apple ID 签名时，S2Arm 用它签名、用你的 Apple ID 自己申请描述文件，不新建证书，"
              "也不会撤销 SideStore / AltStore 正在用的证书。回到装机页再装一次即可。")


def adopt(c, src, password):
    """只给了 .p12：私钥交给 Apple ID 签名用的 plumesign（keys/<团队>/key.pem，install_win.adopt_key），之后签名复用这张证书、描述文件用账号现申请。
    不动开发者证书签名的存档、不切签名方式。没登录 / 工具不认 / 证书不在这个账号里 / 列不出 → Failure（说清下一步，什么都没改）"""
    import install
    if os.name != "nt":
        install.plume_home(c)
    W = install.win_install_mod(c)
    team = W.impactor.selected_team()
    if not team:
        raise Failure(ADOPT_NO_LOGIN, code="apple_not_signed_in")
    exe = install.plumesign_exe(c, W)
    if not exe or not W.keycert(exe):
        raise Failure(ADOPT_OLD_TOOL, code="devcert_invalid")
    c.begin("读取证书", 1, 2)
    with tempfile.TemporaryDirectory(dir=folder(c)) as t:
        norm = Path(t) / "cert.p12"
        normalize_p12(src, norm, password)   # 密码不对 / 文件坏 → devcert_password
        key, _ = _read_p12(c, norm, password)
    c.begin("核对 Apple ID 里的证书", 2, 2)
    got = W.adopt_key(exe, team, key, log=c.logs / (c.task + "-adopt.log"))
    if got is None:
        raise Failure(ADOPT_UNLISTED)
    if got == "absent":
        raise Failure(ADOPT_ABSENT.format(team), code="devcert_invalid")
    return dict(adopted=True, team=team, certName=got["name"], machine=got["machine"], created=got["created"], message=ADOPT_DONE)


def operation(c):
    """作业 devCert：
    import（p12Path + profilePath，密码走环境变量；只给 p12Path = 交给 Apple ID 签名沿用这张证书，见 adopt）：add = true 加一张（新 Mac 选证书窗 / 再导入一张；带 device = 顺手给这台选它）；
           不带 add = 旧义「换一个」：顶掉这台（没设备 = 缺省）那张，选过它的设备跟着换；这台还没有能用的（要玩家选）就加一张给它，不顶别的台的；
    status（带 device：这台用哪张、要不要问）；choose（device + cert = 条目号）；use（active 布尔）；delete（cert = 删这一条；不带 = 全删）"""
    action = c.r.get("action") or "status"
    d = folder(c)
    device = _udid(c.r.get("device"))
    if action == "import":
        password = getattr(c, "devcert_password", None)
        if password is None:
            raise Failure("没收到证书密码。", code="devcert_password")
        src, prof_src = Path(c.r.get("p12Path") or ""), Path(c.r.get("profilePath") or "")
        if src.is_file() and not c.r.get("profilePath"):
            return adopt(c, src, password)
        for p, text in ((src, "找不到 .p12 证书：{0}"), (prof_src, "找不到 .mobileprovision 描述文件：{0}")):
            if not p.is_file():
                raise Failure(text.format(p), code="devcert_invalid")
        c.begin("读取证书与描述文件", 1, 2)
        prof = prof_src.read_bytes()
        parsed = parse_profile(prof)   # 先认描述文件，选错文件不用等规整
        add = c.r.get("add") is True
        with tempfile.TemporaryDirectory(dir=d) as t:
            norm = Path(t) / "cert.p12"
            normalize_p12(src, norm, password)
            got = inspect(rcodesign_path(c), norm, password, prof, udid=device or None)
            if got["blocking"]:
                raise blocked(got)
            c.begin("保存证书", 2, 2)
            sha = got["certSha1"]
            with _locked(c):
                s = store(c)
                eid = _renewal(c, s, sha, parsed)
                assign = add and bool(device)
                if not eid and not add and s["entries"]:   # 旧义「换一个证书」（Windows 证书页 / 旧前端）
                    if device and resolve(c, device, s) is None:
                        assign = True   # 这台还没有能用的：加一张给它，不顶掉别的台在用的
                    else:
                        bind(c, device)
                        eid = _shown(c, s)
                if not eid:   # 新条目：条目号用描述文件 UUID；被占了（旧义「换一个」留着原号）就加后缀
                    eid = _fresh_id(s, str(parsed.get("UUID") or sha).lower())
                old = (s["entries"].get(eid) or {}).get("certSha1")
                if old and old != sha:   # 先删旧密码再存新的：Windows 两份都在这个条目目录里，后删会把刚存的删掉
                    _drop_secret(c, s, old, eid)
                to = entry_dir(c, eid)
                to.mkdir(parents=True, exist_ok=True)
                secrets(c, eid).save(sha, password)
                for k, v in s["entries"].items():   # 同一张证书的别的条目：换成这次规整的 p12（都用最新的密码打得开）
                    if k != eid and v.get("certSha1") == sha:
                        _put(entry_dir(c, k) / "cert.p12", norm)
                        if os.name == "nt":
                            secrets(c, k).save(sha, password)
                os.replace(norm, to / "cert.p12")
                _put(to / "profile.mobileprovision", data=prof)
                os.chmod(to / "profile.mobileprovision", 0o600)
                s["entries"][eid] = dict(certSha1=sha, profileUuid=str(parsed.get("UUID") or "").lower(), appId=_appid(parsed), bundleId=got["bundleId"],
                                         teamId=got["teamId"], teamName=got["teamName"], profileName=parsed.get("Name") or "", imported=_now())
                s["active"] = True
                if assign:
                    s["devices"][device] = eid
                _write(c, s)
        return dict(got, active=True, entry=eid)
    if action == "choose":
        eid = c.r.get("cert") or ""
        with _locked(c):
            s = store(c)
            if not device or eid not in s["entries"]:
                raise Failure("没有这张证书。", code="devcert_missing")
            s["devices"][device] = eid
            _write(c, s)
        return dict(device=device, chosen=eid)
    if action == "use":
        with _locked(c):
            s = store(c)
            want = c.r.get("active") is True
            if want and not s["entries"]:
                raise Failure("还没导入开发者证书。", code="devcert_missing")
            s["active"] = want
            _write(c, s)
        return dict(active=want and active(c))
    if action == "delete":
        with _locked(c):
            s = store(c)
            drop = [c.r["cert"]] if c.r.get("cert") else list(s["entries"])
            for eid in drop:
                meta = s["entries"].get(eid)
                if meta:
                    _drop_secret(c, s, meta.get("certSha1", ""), eid)
                    del s["entries"][eid]
                shutil.rmtree(entry_dir(c, eid), ignore_errors=True)
                s["devices"] = {k: v for k, v in s["devices"].items() if v != eid}
            _write(c, s)
        return dict(deleted=True, active=active(c))
    if action == "status":
        s = store(c)
        if device:
            bind(c, device)
        chosen = s["devices"].get(device) if device else None
        pick = resolve(c, device, s) if device else None
        try:
            cert = summary(c, udid=device or None) if s["entries"] else None
        except Failure as e:   # 这张坏了（密码 / 文件缺了）：照样列出几张，让玩家在选证书窗里换一张或重新导入
            cert = dict(blocking=[dict(id=e.code or "devcert_missing", text=str(e))], warnings=[], entry=_shown(c, s))
        return dict(imported=bool(s["entries"]), active=active(c), cert=cert,
                    certs=listing(c, device or None, s), chosen=chosen if chosen in s["entries"] else None, current=pick,
                    needsChoice=needs_choice(c, device, s))
    raise Failure("不支持的证书操作。")


# ---------- 签名 ----------

def export_ipa(c, payload, bid=None):
    """签好的 App 另存一份 IPA 到游戏库根 S2Arm.signed.ipa（玩家要自己留存 / 换别的工具装时用；装机照常走数据线直装）。不压缩：几十 MB，存一份一两秒。
    bid（独立 App）：写进私有目录 standalone/<包名>.signed.ipa（signed_app_ipa），由 install.put_app / export_app 挪进这款的游戏文件夹（app_folder.py），游戏库根不留东西"""
    out = signed_app_ipa(c, bid) if bid else c.library / "S2Arm.signed.ipa"
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as z:
        for p in sorted(Path(payload).rglob("*")):
            if p.is_file() and not p.is_symlink():
                z.write(p, Path("Payload") / p.relative_to(payload))
    os.replace(tmp, out)
    return out


def signed_app_ipa(c, bid):
    """独立 App 用证书签好的 ipa 的中转位置（私有目录，挪进游戏文件夹后删）"""
    return c.private / "standalone" / f"{bid}.signed.ipa"


def profile_facts(c):
    """在用的描述文件：{wildcard（通配 *，开不了「提高内存上限」等按能力开的权限）, expires（到期时刻，秒；读不到 None）}；读不了 → {}"""
    try:   # 多张证书（#487）：本作业绑定设备的那张，不读根目录的缺省副本
        prof = parse_profile(_profile_bytes(c))
    except (OSError, Failure):
        return {}
    _, wild = bundle_id(prof)
    end = prof.get("ExpirationDate")
    if isinstance(end, datetime.datetime) and not end.tzinfo:
        end = end.replace(tzinfo=datetime.timezone.utc)
    return dict(wildcard=bool(wild), expires=end.timestamp() if isinstance(end, datetime.datetime) else None)


def sign_app(c, app, log, bid=None):
    """把解开的 Payload/*.app 用开发者证书签好（原地）：包名改成描述文件的（bid：独立 App 按款的包名，调用方按 bundle_id(profile, gid) 算）
    → 嵌入 embedded.mobileprovision → rcodesign 递归签（内嵌 framework / dylib 先签、App 主程序带权限）。返回 (包名, 体检结果)；根本签不了的问题在这里停"""
    p12, prof, pw = stored(c)
    rcs = rcodesign_path(c)
    got = inspect(rcs, p12, pw, prof)
    if got["blocking"]:
        raise blocked(got)
    bid = bid or got["bundleId"]
    app = Path(app)
    info = app / "Info.plist"
    pl = plistlib.loads(info.read_bytes())
    pl["CFBundleIdentifier"] = bid
    info.write_bytes(plistlib.dumps(pl))
    (app / "embedded.mobileprovision").write_bytes(prof)
    for old in app.rglob("_CodeSignature"):   # 壳是未签名模板，这里只防重签时残留
        shutil.rmtree(old, ignore_errors=True)
    ents = entitlements(parse_profile(prof), bid)
    with pwfile(folder(c), pw) as pf:
        ef = pf.with_name("ents.plist")
        ef.write_bytes(plistlib.dumps(ents))
        # --team-name：团队号写进签名（苹果发的证书 rcodesign 会自己从证书读，这里显式给，免得认不出的证书签出「没有团队号」的签名）。
        # -e 是「作用范围:值」格式、按第一个冒号拆：绝对路径带盘符（R:\…，Windows 实机 11-10 实测权限挂到了不存在的路径「R」上、主程序没权限）
        #   或目录名带冒号都会拆错，所以在权限文件所在目录里跑、只传不含冒号的文件名
        # --timestamp-url none（#794）：rcodesign 缺省向苹果时间戳服务器（timestamp.apple.com/ts01）要安全时间戳，连不上就整次签名失败、装不了也更新不了。
        #   开发签名装自己的设备不需要安全时间戳（苹果自己的 codesign 对开发签名也不打，pack/dev_sign.py 同样 --timestamp=none）
        eargs, ecwd = rcodesign_ents(ef)
        c.run([rcs, "sign", "--p12-file", p12, "--p12-password-file", pf, "--team-name", got["teamId"], "--timestamp-url", "none", *eargs, app], log, cwd=ecwd)
    return bid, got
