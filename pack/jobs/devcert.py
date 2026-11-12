"""用玩家自己的开发者证书签名（v0.2.4，#370）：导入一次 .p12 + .mobileprovision，之后出包装机都用它签，不走 Apple ID。

维护者定的规则（11-09）：
  ① 导入时解析并上屏：团队名、证书 / 描述文件到期、连着的手机在不在设备列表（企业「所有设备」描述文件没有列表，照实说）、包名、权限够不够；
     问题只提示、不挡出包和装机。只有根本签不了才停：私钥解不开（密码不对 / 文件坏），证书和描述文件不配套。
  ② 包名取描述文件的；通配（TEAM.*）→ io.s2arm.games.<小写团队号>（同 Apple ID 模式的算法）；权限 = 描述文件允许的 ∩ S2Arm 要的。
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
import datetime
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from core import Failure, atomic, read

# S2Arm 要的权限：提高内存上限（大游戏必需，Apple ID 模式也带）+ 扩展寻址（付费账号才有，大地址窗口）；描述文件没开就不带、提示大游戏可能闪退
WANT = ("com.apple.developer.kernel.increased-memory-limit", "com.apple.developer.kernel.extended-virtual-addressing")
WANT_NAMES = {WANT[0]: "提高内存上限", WANT[1]: "扩展寻址"}
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
            raise SystemExit(f"【红】取不到 {RCODESIGN_DOWNLOAD + name}（{e}）：在能连 GitHub 的机器上下好放进 {cache}（或用 S2A_RCODESIGN_CACHE 指过去）再打")
        os.replace(tmp, src)
    got = _h.sha256(src.read_bytes()).hexdigest()
    if got != want:
        raise SystemExit(f"【红】{src} 的 SHA-256 是 {got}，钉的是 {want}：不是 apple-codesign {RCODESIGN_VERSION} 官方发布件，拒打")
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
    (dest / "来源.txt").write_text(f"rcodesign（apple-codesign {RCODESIGN_VERSION}，Gregory Szorc，MPL-2.0：LICENSE-apple-codesign-MPL-2.0.txt），官方发布件原样附带。\n"
                                  f"来源：{RCODESIGN_DOWNLOAD}{name}\n源码：{RCODESIGN_SOURCE}\n", encoding="utf-8")
    return dest / member


def rcodesign_path(c):
    """签名工具：S2A_RCODESIGN（开发用）> 引擎随包 Binaries/Prepare/rcodesign/ > PATH"""
    exe = "rcodesign.exe" if os.name == "nt" else "rcodesign"
    for p in (os.environ.get("S2A_RCODESIGN"), c.engine / "Binaries/Prepare/rcodesign" / exe, shutil.which("rcodesign")):
        if p and Path(p).is_file():
            return str(p)
    raise Failure("找不到签名工具 rcodesign：请重新安装完整的 S2Arm。", code="tool_missing")


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


def bundle_id(profile):
    """包名：描述文件的 application-identifier 去掉前缀；通配 * → io.s2arm.games.<小写团队号>（同 Apple ID 模式）；前缀通配 com.x.* → com.x.s2arm"""
    from install import container_bundle_id
    prefix = (profile.get("ApplicationIdentifierPrefix") or [""])[0]
    team = (profile.get("TeamIdentifier") or [prefix])[0]
    appid = profile["Entitlements"].get("application-identifier", "")
    rest = appid[len(prefix) + 1:] if prefix and appid.startswith(prefix + ".") else appid.partition(".")[2]
    if rest == "*":
        return container_bundle_id(team), True
    if rest.endswith(".*"):
        return rest[:-1] + "s2arm", True
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
    missing = [k for k in WANT if k not in ents]
    if missing:
        names = "、".join(WANT_NAMES[k] for k in missing)
        warnings.append(dict(id="devcert_entitlements", text=f"描述文件没开「{names}」权限：小游戏照常，大游戏可能内存不够闪退。可在开发者网站给这个 App ID 打开后重新下载描述文件。"))
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
                deviceListed=listed, entitlements=sorted(k for k in ents if k in WANT), missingEntitlements=missing)


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
            why += "；p12 里缺私钥或证书"
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
    src, out = Blob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), Blob()
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
            raise Failure("证书密码没存进钥匙串：" + (r.stderr or r.stdout).strip()[-200:], code="devcert_keychain")

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

def folder(c):
    d = c.private / "devcert"
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def secrets(c):
    return getattr(c, "devcert_secrets", None) or Secrets(folder(c))


def state(c):
    return read(folder(c) / "state.json") or {}


def active(c):
    """出包装机用不用开发者证书：玩家在出包页选了「我的开发者证书」且证书在"""
    s = state(c)
    return bool(s.get("active") and s.get("certSha1") and (folder(c) / "cert.p12").is_file())


def team(c):
    """开发者证书模式下的签名账号（同 install.pick_team 的形状）；没在用 → None"""
    if not active(c):
        return None
    s = state(c)
    return dict(id=s["teamId"], name=s.get("teamName") or s["teamId"], free=False)


def stored(c):
    """签名要的三样：规整后的 p12、描述文件字节、密码；缺一样 = 要重新导入"""
    s, d = state(c), folder(c)
    pw = secrets(c).load(s.get("certSha1", "")) if s.get("certSha1") else None
    if not (d / "cert.p12").is_file() or not (d / "profile.mobileprovision").is_file() or pw is None:
        raise Failure("开发者证书不完整（证书、描述文件或密码缺了）：在出包页重新导入一次。", code="devcert_missing")
    return d / "cert.p12", (d / "profile.mobileprovision").read_bytes(), pw


def summary(c, udid=None):
    """当前证书的体检结果（启动器出包页 / 装机前清单用）；没导入 → None"""
    if not state(c).get("certSha1"):
        return None
    p12, prof, pw = stored(c)
    return dict(inspect(rcodesign_path(c), p12, pw, prof, udid=udid), active=active(c))


def operation(c):
    """作业 devCert：action = import（p12Path + profilePath，密码走环境变量）/ status / use（active 布尔）/ delete"""
    action = c.r.get("action") or "status"
    d = folder(c)
    if action == "import":
        password = getattr(c, "devcert_password", None)
        if password is None:
            raise Failure("没收到证书密码。", code="devcert_password")
        src, prof_src = Path(c.r.get("p12Path") or ""), Path(c.r.get("profilePath") or "")
        for p, text in ((src, "找不到 .p12 证书：{0}"), (prof_src, "找不到 .mobileprovision 描述文件：{0}")):
            if not p.is_file():
                raise Failure(text.format(p), code="devcert_invalid")
        c.begin("读取证书与描述文件", 1, 2)
        prof = prof_src.read_bytes()
        parse_profile(prof)   # 先认描述文件，选错文件不用等规整
        with tempfile.TemporaryDirectory(dir=d) as t:
            norm = Path(t) / "cert.p12"
            normalize_p12(src, norm, password)
            got = inspect(rcodesign_path(c), norm, password, prof, udid=c.r.get("device"))
            if got["blocking"]:
                raise Failure(got["blocking"][0]["text"], code=got["blocking"][0]["id"])
            c.begin("保存证书", 2, 2)
            old = state(c).get("certSha1")
            if old and old != got["certSha1"]:
                secrets(c).delete(old)
            secrets(c).save(got["certSha1"], password)
            os.replace(norm, d / "cert.p12")
        (d / "profile.mobileprovision").write_bytes(prof)
        os.chmod(d / "profile.mobileprovision", 0o600)
        atomic(d / "state.json", dict(active=True, certSha1=got["certSha1"], bundleId=got["bundleId"], teamId=got["teamId"], teamName=got["teamName"],
                                      imported=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")))
        return dict(got, active=True)
    if action == "use":
        s = state(c)
        want = c.r.get("active") is True
        if want and not s.get("certSha1"):
            raise Failure("还没导入开发者证书。", code="devcert_missing")
        atomic(d / "state.json", dict(s, active=want))
        return dict(active=want and active(c))
    if action == "delete":
        s = state(c)
        if s.get("certSha1"):
            secrets(c).delete(s["certSha1"])
        for n in ("cert.p12", "profile.mobileprovision", "state.json", "password.dpapi"):
            (d / n).unlink(missing_ok=True)
        return dict(deleted=True, active=False)
    if action == "status":
        return dict(imported=bool(state(c).get("certSha1")), active=active(c), cert=summary(c, udid=c.r.get("device")))
    raise Failure("不支持的证书操作。")


# ---------- 签名 ----------

def export_ipa(c, payload):
    """签好的 App 另存一份 IPA 到游戏库根 S2Arm.signed.ipa（玩家要自己留存 / 换别的工具装时用；装机照常走数据线直装）。不压缩：几十 MB，存一份一两秒"""
    out = c.library / "S2Arm.signed.ipa"
    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as z:
        for p in sorted(Path(payload).rglob("*")):
            if p.is_file() and not p.is_symlink():
                z.write(p, Path("Payload") / p.relative_to(payload))
    os.replace(tmp, out)
    return out


def sign_app(c, app, log):
    """把解开的 Payload/*.app 用开发者证书签好（原地）：包名改成描述文件的 → 嵌入 embedded.mobileprovision → rcodesign 递归签
    （内嵌 framework / dylib 先签、App 主程序带权限）。返回 (包名, 体检结果)；根本签不了的问题在这里停"""
    p12, prof, pw = stored(c)
    rcs = rcodesign_path(c)
    got = inspect(rcs, p12, pw, prof)
    if got["blocking"]:
        raise Failure(got["blocking"][0]["text"], code=got["blocking"][0]["id"])
    app = Path(app)
    info = app / "Info.plist"
    pl = plistlib.loads(info.read_bytes())
    pl["CFBundleIdentifier"] = got["bundleId"]
    info.write_bytes(plistlib.dumps(pl))
    (app / "embedded.mobileprovision").write_bytes(prof)
    for old in app.rglob("_CodeSignature"):   # 壳是未签名模板，这里只防重签时残留
        shutil.rmtree(old, ignore_errors=True)
    ents = entitlements(parse_profile(prof), got["bundleId"])
    with pwfile(folder(c), pw) as pf:
        ef = pf.with_name("ents.plist")
        ef.write_bytes(plistlib.dumps(ents))
        # --team-name：团队号写进签名（苹果发的证书 rcodesign 会自己从证书读，这里显式给，免得认不出的证书签出「没有团队号」的签名）。
        # -e 是「作用范围:值」格式、按第一个冒号拆：绝对路径带盘符（R:\…，Windows 实机 11-10 实测权限挂到了不存在的路径「R」上、主程序没权限）
        #   或目录名带冒号都会拆错，所以在权限文件所在目录里跑、只传不含冒号的文件名
        # --timestamp-url none（#794）：rcodesign 缺省向苹果时间戳服务器（timestamp.apple.com/ts01）要安全时间戳，连不上就整次签名失败、装不了也更新不了。
        #   开发签名装自己的设备不需要安全时间戳（苹果自己的 codesign 对开发签名也不打，pack/dev_sign.py 同样 --timestamp=none）
        c.run([rcs, "sign", "--p12-file", p12, "--p12-password-file", pf, "--team-name", got["teamId"], "--timestamp-url", "none", "-e", ef.name, app], log, cwd=ef.parent)
    return got["bundleId"], got
