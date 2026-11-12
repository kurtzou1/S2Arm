"""装到 iPhone（10-26 维护者 定：Xcode 做主路、AltStore 备选）：打 iPhone 包出的是自签 IPA，iPhone 不认；
用玩家在 Xcode 里登录的 Apple ID（免费的个人团队就行）重签后，用数据线直接装上，再把资源包拷进去、逐文件核对。

  ① 团队：优先读 Xcode 团队缓存；账号存在但缓存缺失时核本机开发描述文件与可用签名身份。请求给了 teamId 就用它，否则优先付费团队；找不到不当作未登录
  ② 设备：连着线、已信任的那台 iPhone / iPad（恰好一台；请求可给 device 指定）
  ③ 包名：io.s2arm.games.<团队号小写>（所有游戏进同一个容器 App，主页亮点「一个 App 装下整个游戏库」，维护者 11-08）——包名在 Apple 那边按团队注册，别的团队用过的同名包名注册不了
  ④ pack/ensure_profile.sh（xcodebuild -allowProvisioningUpdates，带设备号时顺带登记这台设备）拿开发描述文件 → pack/dev_sign.py 重签（核「提高内存上限」）
  ⑤ devicectl 装 App → tools/push_pack.py 按内容增量推资源包（同 dev_run、Windows 一键装机）→ 起 App 只解包，机上 .applied 对上本包索引才算装好
10-26 本机实测（免费个人团队、测试设备2）：描述文件 27 秒、签名 7 秒、安装 3 秒。免费账号签的 App 7 天过期，到期连上再装一次就行（资源包已在机上的不重拷）。"""
from __future__ import annotations

import argparse
import json
import datetime
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from core import Failure, atomic, contained, read
from errors import recovery
import devcert
import layout


def profile_teams(env=None):
    """从未过期开发描述文件及可用私钥身份发现团队；最终账号权限仍由 Xcode 签名验证。"""
    deadline = time.monotonic() + 8
    try:
        p = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, env=env, timeout=5)
        identities = set(re.findall(r"\b[0-9A-Fa-f]{40}\b", p.stdout.upper())) if p.returncode == 0 else set()
    except (OSError, subprocess.TimeoutExpired):
        return []
    if not identities:
        return []
    home = Path((env or os.environ).get("HOME", str(Path.home())))
    folders = (home / "Library/Developer/Xcode/UserData/Provisioning Profiles", home / "Library/MobileDevice/Provisioning Profiles")
    out, seen = [], set()
    now = datetime.datetime.now(datetime.timezone.utc)
    for folder in folders:
        for path in sorted(folder.glob("*.mobileprovision")):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return out
            try:
                p = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, env=env, timeout=min(2, remaining))
                if p.returncode:
                    continue
                profile = plistlib.loads(p.stdout)
                expiry = profile.get("ExpirationDate")
                if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
                    continue
                ent = profile.get("Entitlements", {})
                teams = profile.get("TeamIdentifier", [])
                if len(teams) != 1 or not isinstance(teams[0], str) or not re.fullmatch(r"[A-Z0-9]{10}", teams[0]):
                    continue
                tid = teams[0]
                if ent.get("get-task-allow") is not True or not profile.get("ProvisionedDevices") or ent.get("com.apple.developer.team-identifier") != tid:
                    continue
                if not any(hashlib.sha1(cert).hexdigest().upper() in identities for cert in profile.get("DeveloperCertificates", [])):
                    continue
                if tid not in seen:
                    seen.add(tid)
                    # 缺少个人团队标记时保守按免费处理，不据缺字段断言付费资格。
                    out.append(dict(id=tid, name=profile.get("TeamName") or "", free=profile.get("LocalProvision") is not False))
            except (OSError, subprocess.TimeoutExpired, ValueError, TypeError, AttributeError):
                continue
    return out


# 玩家话术（环境检查、装机清单、失败提示同一份）。Xcode 里加完 Apple ID，团队要等账户页把团队列表显示出来才写进缓存（11-08 MacBook Air 实走）：
#   判据是团队号真的出现，不是账号存在
ACCOUNT_NONE = ("还没有登录 Apple ID：打开 Xcode，点菜单 Xcode › Settings › Apple Accounts，点 + 添加你的 Apple ID（免费的就行），"
                "选中账号，等团队列表显示出来，再回来重新检查。装了多个 Xcode 也只要登一个，账号是共用的。")
TEAM_PENDING = ("Apple ID 已经登录，但这台 Mac 还没有签名团队：点「解决办法」打开现成的引导项目，在 Xcode 里选 Personal Team，"
                "连上手机点运行一次，回来会自动打勾。也可以先到 Xcode › Settings › Apple Accounts 看团队列表有没有显示。")


def _security_text(args, env):
    try:
        p = subprocess.run(["security", *args], capture_output=True, text=True, env=env, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return p.stdout if p.returncode == 0 else ""


def development_identities(env=None):
    """钥匙串里带私钥、能用的开发证书的 SHA-1。"""
    text = _security_text(["find-identity", "-v", "-p", "codesigning"], env)
    return {h.upper() for h in re.findall(r'\b([0-9A-Fa-f]{40})\s+"(?:Apple Development|iPhone Developer):', text)}


def keychain_teams(env=None):
    """钥匙串开发证书的 OU 就是团队号，不依赖 Xcode 偏好缓存。证书看不出是否付费，按免费处理（只影响到期提示）；最终权限由 Xcode 签名验证。"""
    identities = development_identities(env)
    if not identities:
        return []
    text = _security_text(["find-certificate", "-a", "-Z", "-p"], env)
    out, seen = [], set()
    for sha, pem in re.findall(r"SHA-1 hash: ([0-9A-Fa-f]{40})\s+(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", text, re.S):
        if sha.upper() not in identities:
            continue
        try:
            subject = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject"], input=pem, capture_output=True, text=True, env=env, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        match = re.search(r"\bOU\s*=\s*([A-Z0-9]{10})\b", subject)
        if match and match[1] not in seen:
            seen.add(match[1])
            out.append(dict(id=match[1], name="", free=True))
    return out


PREFS_UNREADABLE = "S2ArmPrefsUnreadable"


def _xcode_prefs(env):
    p = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True, env=env, timeout=20)
    if p.returncode:
        return {}
    # 第三方 Xcode 扩展的快捷键键名可能带控制字符（如 ESC），defaults 原样导出，XML 不允许，解析会失败：先去掉（#144）
    text = re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", p.stdout)
    try:
        return plistlib.loads(text)
    except Exception:
        return {PREFS_UNREADABLE: True}


def signing_summary(env=None):
    """给诊断用的签名现状：只有版本和数量，不含账号和团队名。"""
    if os.name == "nt":
        return ""
    try:
        prefs = _xcode_prefs(env)
        version = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, env=env, timeout=20).stdout.splitlines()[:1]
    except (OSError, subprocess.TimeoutExpired):
        prefs, version = {}, []
    accounts = prefs.get("DVTDeveloperAccountManagerAppleIDLists") or {}
    count = sum(len(xs) for xs in accounts.values() if isinstance(xs, list)) if isinstance(accounts, dict) else 0
    return (f"{version[0] if version else 'Xcode 未知'}；账号 {count} 个；团队缓存键{'读不了偏好' if PREFS_UNREADABLE in prefs else '有' if 'IDEProvisioningTeamByIdentifier' in prefs else '无'}；"
            f"可用团队 {len(xcode_account(env)[1])} 个；开发证书 {len(development_identities(env))} 张")


def xcode_account(env=None):
    """(有没有登录 Apple ID, 团队列表)：依次看 Xcode 团队缓存、本机描述文件、钥匙串开发证书，定位不到才算没有。"""
    if os.name == "nt":   # Windows 没有 Xcode 账号（也没有 defaults 命令）：签名走 Impactor
        return False, []
    prefs = _xcode_prefs(env)
    out, seen = [], set()
    for teams in (prefs.get("IDEProvisioningTeamByIdentifier") or {}).values():
        for t in teams or []:
            tid = t.get("teamID")
            if tid and tid not in seen:
                seen.add(tid)
                out.append(dict(id=tid, name=t.get("teamName") or "", free=bool(t.get("isFreeProvisioningTeam"))))
    accounts = prefs.get("DVTDeveloperAccountManagerAppleIDLists") or {}
    logged_in = isinstance(accounts, dict) and any(isinstance(xs, list) and any(isinstance(a, dict) and a.get("identifier") for a in xs) for xs in accounts.values())
    return logged_in, out or (profile_teams(env) if logged_in else []) or keychain_teams(env)


SIGNING_PBXPROJ = """// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
A1000000000000000000000A = {isa = PBXBuildFile; fileRef = A1000000000000000000000B; };
A1000000000000000000000B = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
A1000000000000000000000C = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = S2ArmSigning.app; sourceTree = BUILT_PRODUCTS_DIR; };
A1000000000000000000000D = {isa = PBXGroup; children = (A1000000000000000000000B, A1000000000000000000000E); sourceTree = "<group>"; };
A1000000000000000000000E = {isa = PBXGroup; children = (A1000000000000000000000C); name = Products; sourceTree = "<group>"; };
A1000000000000000000000F = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1000000000000000000000A); runOnlyForDeploymentPostprocessing = 0; };
A10000000000000000000010 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000013; buildPhases = (A1000000000000000000000F); buildRules = (); dependencies = (); name = S2ArmSigning; productName = S2ArmSigning; productReference = A1000000000000000000000C; productType = "com.apple.product-type.application"; };
A10000000000000000000011 = {isa = PBXProject; buildConfigurationList = A10000000000000000000012; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A1000000000000000000000D; productRefGroup = A1000000000000000000000E; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000010); };
A10000000000000000000012 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000014); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
A10000000000000000000013 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000015); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
A10000000000000000000014 = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 16.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };
A10000000000000000000015 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; PRODUCT_BUNDLE_IDENTIFIER = "@BUNDLE@"; PRODUCT_NAME = "$(TARGET_NAME)"; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Debug; };
}; rootObject = A10000000000000000000011; }
"""
SIGNING_APP = """import SwiftUI

@main struct S2ArmSigningApp: App {
    var body: some Scene { WindowGroup { Text("S2Arm 签名已就绪，可以回到电脑继续") } }
}
"""


def signing_project(c):
    """没有团队的玩家用的引导项目：放在私有目录，玩家在 Xcode 选 Personal Team、连手机运行一次，Xcode 就会生成证书和描述文件。"""
    root = c.private / "signing-helper"
    project = root / "S2ArmSigning.xcodeproj"
    project.mkdir(parents=True, exist_ok=True)
    bundle = "io.s2arm.signing.h" + hashlib.sha256(str(c.private).encode()).hexdigest()[:10]   # 免费账号的包名要全局唯一：按这台机的数据目录算，重开不变
    (project / "project.pbxproj").write_text(SIGNING_PBXPROJ.replace("@BUNDLE@", bundle), encoding="utf-8")
    (root / "App.swift").write_text(SIGNING_APP, encoding="utf-8")
    return dict(path=str(project))


def xcode_teams(env=None):
    return xcode_account(env)[1]


def no_team_failure(env=None):
    """没有可用团队时的失败：还没登录，和登录了但团队没同步，是两件事。"""
    return Failure(TEAM_PENDING, code="xcode_team_pending") if xcode_account(env)[0] else Failure(ACCOUNT_NONE, code="xcode_account_missing")


def pick_team(teams, want=None):
    if want:
        t = next((t for t in teams if t["id"] == want), None)
        if t:
            return t
        if not re.fullmatch(r"[A-Z0-9]{10}", want):
            raise Failure("Team ID 要是 10 位大写字母或数字，可以在 Xcode 的账户页或 Apple 开发者网站查到。", code="xcode_account_missing")
        return dict(id=want, name="", free=True)   # 玩家手填的：本机查不到也试，能不能用由 Xcode 签名给真实结果
    if not teams:
        raise no_team_failure()
    paid = [t for t in teams if not t["free"]]
    return (paid or teams)[0]


# 多款容器（启动器线 11-07，一个 App 装多款游戏；组装见 pack/ship_ext.py container、pack/jobs/ipa.py container）：
#   包名固定 io.s2arm.games.<团队号小写>：本来就按团队分（不会被别的团队占），不用 NX2Apple 那样「缺省包名被占 → 团队变体 → 落盘沿用」；
#     加款 / 换款都是同一个包名覆盖安装（不卸载，Documents 保留），一个团队只占一个 App ID（免费账号 7 天 10 个的额度）。换团队 = 换包名 = 新沙盒，旧存档要迁
#   设备侧每款文档根 Documents/games/<游戏号>（存档 / 直连见过的键 / unpack.log 在它下面），资源包根 Library/Application Support/S2Arm/games/<游戏号>/资源包
#     （11-11 挪出 Documents：几万个文件让「文件」App 与文件选择器「最近项目」一直「正在加载」；旧位置 Documents/games/<游戏号>/资源包 过渡期还认，见 pack_listing），
#   起这一款的启动上下文 @bundle/Games/<游戏号>/launch.ctx——与 ship_ext 容器布局同口径


def container_bundle_id(team, c=None):
    """S2A_CONTAINER_SUFFIX（开发用：同一台手机上同时装几份测试包）：包名加后缀 io.s2arm.games.<团队>.<后缀>，几份并存互不覆盖；
    只收小写字母 / 数字 / 连字符，不设时与玩家完全一样。付费团队没有免费账号每周 10 个包名的限制。
    给了 c 且这个团队的包名曾被别处占用、自动换过（bundle_switched）→ 用换过的那个，之后每次装机、推资源包都对同一个 App"""
    suffix = re.sub(r"[^a-z0-9-]", "", os.environ.get("S2A_CONTAINER_SUFFIX", "").lower())[:40]
    base = f"io.s2arm.games.{team.lower()}" + (f".{suffix}" if suffix else "")
    return (read(_bundle_switch_file(c), {}).get(team.lower()) or base) if c is not None else base


# 包名被别处占用（Apple 9401：玩家先用自己的签名工具签 S2Arm 时沿用了 io.s2arm.games.<团队> 这个包名，它就注册到了别的 Apple ID 下；
#   之后 Mac 一键装按同一个包名向 Xcode 账号注册被拒——玩家改了签名里的包名才装上，11-11 反馈）：自动换成 <包名>.s2 再签一次，记在私有目录
ALT_BUNDLE_SUFFIX = ".s2"


def _bundle_switch_file(c):
    return c.private / "bundle-switch.json"


def bundle_switched(c, team, bid):
    m = read(_bundle_switch_file(c), {})
    atomic(_bundle_switch_file(c), dict(m if isinstance(m, dict) else {}, **{team.lower(): bid}))


def container_display_name(app):
    """S2A_CONTAINER_NAME（开发用，与 S2A_CONTAINER_SUFFIX 配套）：主屏显示名，连各语言 InfoPlist.strings 里的一起换；不设时不动"""
    name = os.environ.get("S2A_CONTAINER_NAME", "").strip()
    if not name:
        return None
    for strings in Path(app).glob("*.lproj/InfoPlist.strings"):
        text = strings.read_text(encoding="utf-8", errors="replace")
        strings.write_text(re.sub(r'"CFBundleDisplayName"\s*=\s*".*?";', '"CFBundleDisplayName" = "%s";' % name.replace('"', ''), text), encoding="utf-8")
    return name


def game_docs(gid):
    return f"Documents/games/{gid.upper()}"


DOCS_GAMES = "Documents/games"
PACK_GAMES = "Library/Application Support/S2Arm/games"   # 每款资源包放 <PACK_GAMES>/<游戏号>/资源包（设备侧宿主同口径）


def game_pack(gid):
    """本款设备侧资源包根（新位置，不在 Documents 里）"""
    return f"{PACK_GAMES}/{gid.upper()}/资源包"


def game_pack_old(gid):
    """本款资源包旧位置（11-11 之前的宿主放在文档根下）：过渡期只读、只在新位置不在时推它（App 下次启动整个挪到新位置）"""
    return f"{game_docs(gid)}/资源包"


def game_ctx(gid):
    return f"@bundle/Games/{gid.upper()}/launch.ctx"


S_NO_USB = "这台 Mac 的 USB 上没看到 iPhone / iPad：换一根能传数据的线（充电线不行）、换个接口直连 Mac，并解锁手机。"
S_NOT_LISTED = "这台 Mac 看到手机插着，但设备服务还没列出它：解锁手机，在弹出的框里点「信任」；还不行就拔掉重插一次。"
S_MANY_WIRED = "连着不止一台 iPhone / iPad：只留要装的那一台。"
S_NETWORK = "能装，但网络传资源包慢、容易断：插上数据线再装更稳。"
S_MANY_NETWORK = "同一网络上有多台配对过的 iPhone / iPad：用数据线连上要装的那一台。"
# 装到哪台由玩家选、作业照办，不替玩家换一台（维护者 11-11：续签时玩家选的 iPhone 拔了线，旁边同网的 iPad 被装上了）
S_DEVICE_REQUIRED = "没说要装到哪台设备：在装机页选好 iPhone / iPad 再装。"
S_OFFLINE = "{0}「{1}」现在不在线：插上数据线，或让它和这台电脑连同一个 Wi-Fi 并解锁，再试一次。"
S_NOT_PAIRED = "没找到要装的那台设备（{0}）：它还没和这台电脑配对过——插上数据线并解锁，在设备上点「信任」（配对过以后也可以连同一个 Wi-Fi 装）。"
S_TRUST = "在 iPhone 上点「信任」，再输入手机的锁屏密码。"
S_DEV_MODE = "在 iPhone 上打开「设置 → 隐私与安全性 → 开发者模式」，按提示重启手机；重启后解锁，这里会自动打勾。"
S_TUNNEL = "和手机建立开发连接失败：解锁手机后再试；走无线的话换成数据线。"
S_DDI = "手机的开发者服务没准备好：解锁手机后再试；还不行就重启手机。"
PREPARE_COOLDOWN = 30   # 清单几秒问一次：配对框、更新映像这类有动静的步骤隔一会儿才重试


def _link(d):
    return d.get("connectionProperties", {})


def _mask(value):
    return f"{value[:4]}…{value[-2:]}" if len(value or "") > 8 else "…"


def _clean(text):
    """诊断里的 devicectl 原文：设备序列号、UUID 不进诊断包"""
    return re.sub(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4,16}(?:-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})?\b", "…", str(text or ""))


def _with_raw(sentence, raw):
    """定句走翻译，原文另起一行照原样显示"""
    tail = _clean(raw).strip().splitlines()
    return sentence + ("\n" + tail[-1] if tail else "")


def device_hint(want):
    """上屏时怎么称呼玩家指定的那台：设备名照写；设备号只写末尾 6 位——整串会被诊断脱敏换成 [DEVICE_ID] 占位、玩家看不懂（11-11 真机验收测出）"""
    return f"编号末尾 {want[-6:]}" if re.fullmatch(r"[0-9A-Fa-f-]{20,}", want) else f"「{want}」"


def device_kind(d):
    """devicectl 设备 → 「iPad」或「iPhone」（文案里写实际的设备类型，不写死 iPhone）"""
    h = d.get("hardwareProperties", {})
    return "iPad" if h.get("platform") == "iPadOS" or (h.get("productType") or "").startswith("iPad") else "iPhone"


def _pick_device(devices, want):
    """要装的那台：返回 (设备, 连接环节的问题)。
    给了 want（玩家选的那台）：只认它——在线（有线或同网）就用它；配对过但不在线 → 如实说「iPhone「名字」不在线」；没见过 → 没找到。
    不替玩家换一台（原先 want 对不上时「只有一台就用它」：续签时 iPhone 拔了线，同网的 iPad 被装上，完成页还写「已装到 iPhone」）。
    没给 want：只给装机前清单看（polling），有线优先挑出连着的那台供界面显示；真装机不走这里（phone() 先要求 want）"""
    phones = [d for d in devices if d.get("hardwareProperties", {}).get("reality") == "physical" and d.get("hardwareProperties", {}).get("platform") in ("iOS", "iPadOS")]
    live = [d for d in phones if _link(d).get("transportType") in ("wired", "localNetwork") or _link(d).get("tunnelState") == "connected"]
    if want:
        def named(d):
            return want in (d.get("identifier"), d.get("hardwareProperties", {}).get("udid"), (d.get("deviceProperties", {}).get("name") or "").strip())
        chosen = [d for d in live if named(d)]
        if chosen:
            return chosen[0], ""
        known = [d for d in phones if named(d)]
        if known:
            return None, S_OFFLINE.replace("{0}", device_kind(known[0])).replace("{1}", (known[0].get("deviceProperties", {}).get("name") or "").strip())
        return None, S_NOT_PAIRED.replace("{0}", device_hint(want))
    wired = [d for d in live if _link(d).get("transportType") == "wired"]
    if len(wired) > 1:
        return None, S_MANY_WIRED
    if not wired and len(live) > 1:
        return None, S_MANY_NETWORK
    if wired or live:
        return (wired or live)[0], ""
    return None, ""


def _cooled(c, device, step, polling):
    """清单轮询时同一步隔 PREPARE_COOLDOWN 秒才再做一次；真正装机时总是做"""
    if not polling:
        return True
    path = c.private / "device-prepare.json"
    try:
        marks = json.loads(path.read_text())
    except (OSError, ValueError):
        marks = {}
    key = f"{device.get('identifier')}:{step}"
    if time.time() - marks.get(key, 0) < PREPARE_COOLDOWN:
        return False
    marks[key] = time.time()
    atomic(path, marks)
    return True


def device_link(c, want="", polling=False):
    """读设备并把它准备到能装（玩家不用打开 Xcode）：配对 → 开发者模式 → 拉起隧道和开发者服务 → 必要时更新开发者磁盘映像。
    返回 {device, stage, problem, trace}：stage 是没过的环节（connected / trusted / developerMode / prepare，全过为空）；polling = 装机前清单轮询。"""
    import target
    from diag import devicectl
    trace, limits = [], (30, 20, 120) if polling else (120, 60, 240)
    def note(step, rc, raw): trace.append(dict(step=step, rc=rc, raw=_clean(raw)[-1500:]))
    def say(text):
        if not polling: c.emit("progress", text)
    def read():
        devices, why, rc, raw = target.device_list(c, timeout=30 if polling else 60)
        note("list devices", rc, raw)
        return devices, why
    def step(name, *args, timeout):
        data = {}
        try:
            rc, data, raw = devicectl(c, *args, timeout=timeout)
        except subprocess.TimeoutExpired:
            rc, raw = "timeout", f"超过 {timeout} 秒"
        except OSError as e:
            rc, raw = "oserror", str(e)
        note(name, rc, raw)
        return rc, data, raw
    def out(device, stage, problem, devices=()):
        return dict(device=device, stage=stage, problem=problem, trace=trace, devices=list(devices))
    def again(dev):
        devices, why = read()
        fresh = next((d for d in devices if d.get("identifier") == dev.get("identifier")), None)
        return devices, why, fresh
    devices, why = read()
    if why:
        return out(None, "connected", why)
    dev, problem = _pick_device(devices, want)
    if problem:
        return out(None, "connected", problem, devices)
    if dev is None:
        usb = target.usb_idevices()
        note("usb", 0, "、".join(usb) or "没有 iPhone / iPad")
        return out(None, "connected", S_NOT_LISTED if usb else S_NO_USB, devices)
    if _link(dev).get("pairingState") != "paired":
        raw = ""
        if _cooled(c, dev, "pair", polling):
            say("正在请手机信任这台 Mac")
            _, _, raw = step("manage pair", "manage", "pair", "--device", dev["identifier"], timeout=limits[0])
            devices, why, fresh = again(dev)
            dev = fresh or dev
        if _link(dev).get("pairingState") != "paired":
            return out(dev, "trusted", _with_raw(S_TRUST, raw), devices)
    def services_ready(d):
        return d.get("deviceProperties", {}).get("ddiServicesAvailable") is not False
    def refresh_details():
        nonlocal dev, devices
        rc, data, raw = step("device info details", "device", "info", "details", "--device", dev["identifier"], timeout=limits[1])
        fresh = data.get("result") if isinstance(data, dict) else None
        props = fresh.get("deviceProperties") if isinstance(fresh, dict) else None
        if rc != 0 or not isinstance(props, dict) or fresh.get("identifier") != dev["identifier"] or props.get("developerModeStatus") not in ("enabled", "disabled"):
            if _link(dev).get("transportType") != "wired":   # 走 Wi-Fi 的那台现查不通 = 它现在不在线（人走开 / 锁屏睡眠），如实说是哪台，原文进诊断
                return S_OFFLINE.replace("{0}", device_kind(dev)).replace("{1}", (dev.get("deviceProperties", {}).get("name") or "").strip())
            return _with_raw(S_TUNNEL, raw)
        # list devices 可能仍留着旧值；以指定设备的详情为准，同时更新诊断快照。
        dev = fresh
        devices = [fresh if d.get("identifier") == dev["identifier"] else d for d in devices]
        return ""
    # 真装机（非清单轮询）对选中的那台一律现查一次详情：设备列表里「同网」只说明配对过，不说明此刻连得上（11-11 玩家实报：
    #   没插线点续签，列表里那台标着同网，走到「读已装游戏」才报「找不到设备」）；现查不通就在开工前拦下
    if not polling or dev.get("deviceProperties", {}).get("developerModeStatus") not in ("enabled", None) or _link(dev).get("tunnelState") != "connected" or not services_ready(dev):
        say("正在和设备建立开发连接")
        problem = refresh_details()
        if problem:
            return out(dev, "prepare", problem, devices)
    if dev.get("deviceProperties", {}).get("developerModeStatus") == "disabled":
        return out(dev, "developerMode", S_DEV_MODE, devices)
    if not services_ready(dev):
        raw = ""
        if _cooled(c, dev, "ddi", polling):
            say("正在准备手机的开发者服务")
            _, _, raw = step("manage ddis update", "manage", "ddis", "update", timeout=limits[2])
            problem = refresh_details()
            if problem:
                return out(dev, "prepare", problem, devices)
            if dev.get("deviceProperties", {}).get("developerModeStatus") == "disabled":
                return out(dev, "developerMode", S_DEV_MODE, devices)
        if not services_ready(dev):
            return out(dev, "prepare", _with_raw(S_DDI, raw), devices)
    return out(dev, "", "", devices)


def _write_link_report(c, link):
    """失败时写进诊断包（日志目录 core.logs_root）：每步退出码和原文、每台设备的连接状态；序列号打码，不写设备名"""
    lines = ["# 设备连接诊断"]
    lines += [f"{t['step']}: rc={t['rc']} {t['raw']}" for t in link["trace"]]
    for d in link["devices"]:
        h, p, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), _link(d)
        lines.append(f"device {_mask(h.get('udid') or d.get('identifier') or '')} {h.get('productType')} reality={h.get('reality')} transport={cp.get('transportType')} pairing={cp.get('pairingState')} "
                     f"tunnel={cp.get('tunnelState')} boot={p.get('bootState')} developerMode={p.get('developerModeStatus')} ddi={p.get('ddiServicesAvailable')}")
    lines.append(f"结论: stage={link['stage']} {link['problem']}")
    target = c.logs / f"{c.task}-device.log"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def phone(c):
    import target
    want = (c.r.get("device") or "").strip()
    if not want:   # 装机一律要玩家选的那台（前端 / s2armctl 都要带 device），作业层不自己挑
        raise Failure(S_DEVICE_REQUIRED, code="device_required")
    link = device_link(c, want)
    if link["problem"]:
        _write_link_report(c, link)
        raise Failure(link["problem"], code="device_not_connected" if link["stage"] == "connected" else "device_not_ready")
    return target._row(link["device"], c.env()["DEVELOPER_DIR"], with_link=True)


def udid_of(c, ident):
    from diag import devicectl
    rc, data, _ = devicectl(c, "list", "devices", timeout=60)
    for d in data.get("result", {}).get("devices", []) if rc == 0 else []:
        if d.get("identifier") == ident:
            return d.get("hardwareProperties", {}).get("udid") or ""
    return ""


def usb_mbps(udid, env=None):
    """这台 iPhone 现在的 USB 连接速率（Mb/s）：system_profiler 里设备序列号 = 去掉横杠的硬件 UDID；没插线 / 走无线 / 读不到 = 0"""
    if not udid:
        return 0
    try:
        p = subprocess.run(["system_profiler", "SPUSBHostDataType", "-json"], capture_output=True, text=True, env=env, timeout=60)
        data = json.loads(p.stdout or "{}")
    except Exception:
        return 0
    want = udid.replace("-", "").upper()
    def walk(o):
        if isinstance(o, dict):
            if str(o.get("USBDeviceKeySerialNumber", "")).replace("-", "").upper() == want:
                m = re.match(r"([\d.]+)\s*([MG])b/s", str(o.get("USBDeviceKeyLinkSpeed", "")))
                return int(float(m.group(1)) * (1000 if m.group(2) == "G" else 1)) if m else 0
            o = list(o.values())
        for v in o if isinstance(o, list) else ():
            r = walk(v)
            if r:
                return r
        return 0
    return walk(data)


# 申请描述文件 / 签名失败时 xcodebuild 的报错 → 玩家能照做的错误码
SIGN_ERRORS = (
    (r"等钥匙串授权超时", "keychain_prompt"),   # pack/ensure_profile.sh：第一次签名的钥匙串框没人点（11-08 Spare-host 实测）
    (r"needs to be unlocked|device is locked|Unlock the device", "device_locked"),   # 10-26 测试设备2 锁屏：xcodebuild 等不到目的设备超时
    # 免费 Apple ID 有两个不同的上限，原文措辞能分开，办法也不同：
    #   ① 包名（App ID）额度：签名前向 Apple 注册包名时被拒，Apple 错误 9120，Xcode 原文
    #      「Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.」——
    #      说的是「App ID」，按 7 天窗口计，删 App 不退额度 → free_appid_limit；
    #   ② 设备同时装 3 个自签 App：签名已过、装机（devicectl / 系统安装服务）时设备拒收，原文
    #      「This device has reached the maximum number of installed apps using a free developer profile」（iOS 27）、
    #      「The maximum number of apps for free development profiles has been reached」（较早 iOS / Xcode）——
    #      说的是「apps」装在这台设备上，删一个就能装 → free_app_limit。
    # 两条正则互不相交：①只认「App ID(s)」字样或带 error / code 前缀的 9120，②的「apps」后面不跟「ID」；
    # ①仍排在前面，万一一行里两种字样都有，按删 App 无效的那件事报，免得玩家白删。
    (r"App ID limit|\b10 App IDs\b|maximum number of App IDs|(?:error|code)\D{0,20}\b9120\b", "free_appid_limit"),
    (r"maximum number of (?:installed )?apps\b|(?:maximum|limit)[^\n]{0,100}free development profiles", "free_app_limit"),
    (r"(?:error|code)\D{0,20}\b9401\b|App ID with Identifier[^\n]{0,120}is not available", "app_id_taken"),   # 包名已被占用（Apple 9401）
    # 手机上已有同包名、别的签名装的 App（玩家自签装过 S2Arm）：系统安装服务拒绝覆盖（installation_proxy MismatchedApplicationIdentifierEntitlement）
    (r"MismatchedApplicationIdentifierEntitlement|application-identifier entitlement string[^\n]{0,240}does not match", "app_other_signer"),
    (r"Developer\s*Mode\s*(?:is\s*)?(?:disabled|not enabled|required)|DeveloperModeDisabled", "developer_mode_required"),
    (r"pairing (?:record|relationship)[^\n]{0,80}(?:invalid|missing|expired)|not paired|pair (?:the )?device again|InvalidHostID", "device_pairing_required"),
    (r"provisioning profile[^\n]{0,100}(?:has expired|is expired|expired on)|expired provisioning profile", "provisioning_expired"),
    (r"No Account for Team|No accounts|not logged in|Your session has expired", "xcode_account_missing"),
    (r"No signing certificate|No certificate for team|Signing certificate is invalid|doesn't include signing certificate", "signing_certificate_missing"),
)


def classify(text, default="signing_failed"):
    for pat, code in SIGN_ERRORS:
        if re.search(pat, text, re.I):
            return code
    return default


def ios_pack(c, gid):
    """这款的资源包（image/ios/pack）；还没出 iPhone 版 / 没有资源包就不装、不报成功（审计 18:00 P1-58：原先照装、启动器写死「资源包也拷好了」，打开游戏才进缺资源页）"""
    if not (layout.ios_kit(c, gid) / "main.npdm").is_file():
        raise Failure("这款游戏还没出 iPhone 包：先点「打 iPhone 包」。", code="job_failed")
    pack = layout.ios_pack(c, gid)
    if not (pack / "manifest.json").is_file():
        raise Failure(f"没找到这款的资源包（{pack}），没有装。请重新「打 iPhone 包」后再装。", code="pack_missing")
    if not pack_id(pack):   # 清单没有 index_sha256（只在这里核一次，push_pack 不再重读，v0.2.3 清理）
        raise Failure(f"资源包缺清单或清单没有 index_sha256（{pack}）：请重新打 iPhone 包。", code="job_failed")
    return pack


def pack_id(pack):
    return read(Path(pack) / "manifest.json", {}).get("index_sha256") or ""


PUSHING = "正在传输资源"   # 推送阶段的进度消息（定文案，两端前端按它本地化；数字走 done / total / unit）


def push_progress(c, done, total, step, steps):
    """推资源包的作业计数（Mac 解析 push_pack 的机器读行、Windows 直接回调，同一出口）：done / total 字节，unit = B；前端据此画百分比、速度、剩余时间。
    没有要推的（total = 0）不发计数，免得画出 0/0；传完（done = total）也只是「传完」，之后的机上解包另有「机上解包 k/n」计数，最终成功仍以解包确认为准"""
    if total > 0:
        c.emit(message=PUSHING, done=done, total=total, unit="B")


def push_stage(c, name, done=None, total=None):
    """推资源包之前的准备子阶段（Mac 解析 push_pack 的 S2A_PUSH_STAGE 行、Windows 直接回调，同一出口）：名字原样上屏，有字节就带计数"""
    if total:
        c.emit(message=name, done=done or 0, total=total, unit="B")
    else:
        c.emit("message", name)


def img_pack(pack):
    """单一 IMG 形态的资源包（manifest v3 format=img，pack/img.py convert）：传完并核过 game.img 长度即装好，不再起 App 等机上解包——
    机上要从 game.img 解出的几个小件由玩家打开 S2Arm 时自己完成（11-11 维护者：启动器到「完整传到手机并校验通过」就结束）"""
    try:
        return json.loads((Path(pack) / "manifest.json").read_text(encoding="utf-8")).get("format") == "img"
    except (OSError, ValueError, AttributeError):
        return False


def push_pack(c, ident, bid, pack, udid=None, docs=None, ctx=None, pack_root=None):
    """资源包推进 App 并在机上解开：调 Mac / Windows 共用的 tools/push_pack.py run --apply（同 dev_run、Windows 一键装机、s2armctl push-pack，
    #206 / PR #470、11-06 两端合一）——按 sha256 只推机上没有 / 变了的文件（免费账号 7 天到期重装、改一点重出一版时只推几个文件），
    残留推送包按完整性处理、推前抽查机上实况，一批 ≤1 GB 流式写进 <资源包根>/.incoming/；推完起一次 App 解开（单款只解包模式；多款容器拉起到游戏库、由库解开并画进度），
    等机上 .applied 对上本包 index_sha256、且解包日志本次新增完成行才算装好（没推东西且 .applied 已是本包就不起 App），玩家打开就能进游戏。
    多款容器：docs = 本款设备侧文档根 Documents/games/<游戏号>、pack_root = 本款设备侧资源包根（pick_pack_root 选的那处）、
    ctx = 本款启动上下文（有它即按多款容器拉起到游戏库）。
    返回（推的文件数, 字节数）"""
    import diag
    got = {}
    def line(text):
        m = re.match(r"S2A_PUSH_PROGRESS (\d+) (\d+) (\d+) (\d+)$", text.strip())   # tools/push_pack.py --progress-lines：每推完一批的已传 / 本次待传总字节（#266）
        if m:
            push_progress(c, *map(int, m.groups()))
            return
        m = re.match(r"S2A_PUSH_STAGE (.+?)\t(\d*)\t(\d*)$", text.strip("\r\n"))   # 推之前的准备子阶段（核对手机上的文件 / 检查手机空间 / 准备资源（拼镜像）按字节）
        if m:
            push_stage(c, m.group(1), int(m.group(2)) if m.group(2) else None, int(m.group(3)) if m.group(3) else None)
            return
        m = re.search(r"推 (\d+) 个文件 (\d+) MB", text)
        if m: got.update(files=int(m.group(1)), mb=int(m.group(2)))
        m = re.search(r"机上解包 (\d+)/(\d+)", text)   # tools/push_pack.py apply 每解完一包打一行：启动器显示「机上解包 13/17」
        if m: c.emit(message=f"机上解包 {m.group(1)}/{m.group(2)}", done=int(m.group(1)), total=int(m.group(2)), unit="包")
    env = dict(c.env(), S2A_DEVICECTL=str(diag.COREDEVICE / "Resources/bin/devicectl"))
    if udid: env["S2A_PUSH_UDID"] = udid   # 有 UDID + App 内置 s2a-devpush（S2A_PREBUILT_TOOLS/devpush）→ 每批流式写手机，否则退回 devicectl（11-06）
    log = c.logs / (c.task + "-push" + (f"-{docs.rsplit('/', 1)[-1]}" if docs else "") + ".log")
    extra = (["--docs", docs] if docs else []) + (["--pack-root", pack_root] if pack_root else []) + (["--launch-ctx", ctx] if ctx else [])
    try:
        apply = [] if img_pack(pack) else ["--apply"]   # 旧形态（多程序合集等）照旧推完起 App 等解完
        c.run([sys.executable, "-B", c.engine / "tools/push_pack.py", "run", ident, bid, pack, "--via", "devicectl", *apply, "--progress-lines", *extra], log, env=env, on_line=line)
    except Failure as e:
        if e.code != "tool_exit":
            raise
        text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
        m = APPLY_FAILED.search(text)   # tools/push_pack.py apply：App 自己写的解开失败原因（如 #569 目录写不进），原样上屏，不说「推不进」「没有开始」
        if m:
            raise Failure(f"资源包已传到 iPhone，但手机上解开失败：{m.group(1)}", code="job_failed") from e
        m = re.search(r"资源包推进去了，但(机上解包 \d+ 秒没有新进展[^：\n]*|起 App 后 \d+ 秒机上解包没有开始)", text)   # tools/push_pack.py apply：按进度判停住（11-07）
        if m:   # 旧口径的「停住」（推包工具现在报成下面的「还差最后一步」）：同样按传输成功 + 提醒（装机原则 11-11）
            c.diagnostic(f"资源包已传完，但{m.group(1)}：请打开这款游戏，保持在前台等它导入完，会自动进入游戏。", code="manual_unpack_required", severity="warning")
            return got.get("files", 0), got.get("mb", 0) << 20
        m = re.search(r"资源包已传完，还差最后一步：[^\n]*", text)   # tools/push_pack.py NeedsPlayer：电脑拉不起 App，传输本身成功（#192）
        if m:
            c.diagnostic(m.group(0), code="manual_unpack_required", severity="warning")
            return got.get("files", 0), got.get("mb", 0) << 20
        m = re.search(r"iPhone 写不进资源包：[^\n]*", text)   # tools/push_pack.py probe：推之前写探针就失败 = 锁屏 / 断开（#333）
        if m:
            raise Failure(m.group(0), code="device_locked") from e
        from errors import tool_reason
        raise Failure("资源包推不进 iPhone：" + tool_reason(log), code="resource_transfer_failed") from e
    return got.get("files", 0), got.get("mb", 0) << 20


APPLY_FAILED = re.compile(r"资源包推进去了，但手机上解开失败：([^\n]+)")   # tools/push_pack.py apply 读到解包日志「解包失败：…」时报的那句


def pull_seen(c, ident, bid, gid, tag, docs="Documents"):
    """装之前把这台设备记下的见过的键（直连线 Documents/wire/<程序号大写>/pso_user.tsv）拉回游戏库 games/<程序号>/seen/<设备>.tsv，
    下次打包按它重算两段式热键（hotset.py）；第一次装 / 没开过直连 / 拉不到都不算错。设备上是追加写：拉回的是已有那份的续写就覆盖，
    否则（换包后机上重新记了）另存一份，多份由 hotset.rank 合并去重"""
    from diag import devicectl
    dest = layout.path(c, gid, "seen", re.sub(r"[^0-9A-Za-z-]", "", tag) + ".tsv")
    with tempfile.TemporaryDirectory(dir=c.private) as d:
        rc, _, _ = devicectl(c, "device", "copy", "from", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                             "--source", f"{docs}/wire/{gid.upper()}/pso_user.tsv", "--destination", f"{d}/s", timeout=120)
        got = Path(d, "s")
        if rc or not got.is_file():
            return False
        new = got.read_bytes()
        if dest.is_file():
            old = dest.read_bytes()
            if old.startswith(new):
                return False
            if not new.startswith(old):
                dest = dest.with_name(f"{dest.stem}-{time.strftime('%Y%m%d%H%M%S')}.tsv")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(got, dest)
        return True


SAVE_REL = "S2A/ryujinx/bis/user/save"   # 文档根下的存档目录（Ryujinx 数据根 = <文档根>/S2A/ryujinx）
SAVE_DIR = "Documents/" + SAVE_REL


def save_dir_absent(c, ident, bid, save_dir):
    """存档目录列不出时，判它是不是根本不在：从它的父目录往上逐级列到 Documents，第一个列得出的父目录里没有它（也没有它下面的东西）→ True；
    父目录里看得到它、或一个父目录都列不出（锁屏 / 隧道断）→ False（调用方停装，宁可不装也不冒丢档的险）"""
    from diag import devicectl
    parts = save_dir.split("/")
    for i in range(len(parts) - 1, 0, -1):
        parent, rest = "/".join(parts[:i]), "/".join(parts[i:])
        rc, data, _ = devicectl(c, "device", "info", "files", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                                "--subdirectory", parent, timeout=120)
        if rc:
            continue
        seen = [f.get("relativePath", "") for f in ((data.get("result") or {}).get("files") or [])]
        return not any(r == rest or r.startswith(rest + "/") or rest.startswith(r + "/") and r == rest.split("/")[0] for r in seen)
    return False

def note(c, text):
    """装机原则（11-11：玩家主动点了装机就别替他拒——认得出的风险让他确认，认不出的直接装）：拿不准、照样继续的判断只记进本任务的日志 <任务号>-decisions.log，界面不拦"""
    line = time.strftime("%H:%M:%S ") + text
    try:
        c.logs.mkdir(parents=True, exist_ok=True)
        with open(c.logs / f"{c.task}-decisions.log", "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except (OSError, AttributeError, TypeError):
        pass
    print("[装机] " + text, file=sys.stderr, flush=True)


def backup_failed(c, why):
    """覆盖装前存档备份不了（装机原则「认得出的风险让用户确认」）：没带 acceptNoBackup → 停下报 save_backup_failed，界面问「仍然继续 / 先不」；
    玩家确认后带 acceptNoBackup 重发 → 记一笔「未备份」照装（返回 None = 没有备份目录）"""
    if c.r.get("acceptNoBackup") is True:
        note(c, "覆盖装前没能备份手机上的存档，玩家已确认继续：" + why)
        return None
    raise Failure("这次装机前没能备份手机上的存档（" + why + "）。存档没备份，万一覆盖出问题可能丢档；确认仍然继续再点一次。",
                  code="save_backup_failed", internal=why)


def backup_saves(c, ident, bid, gid, docs="Documents"):
    """覆盖装前把机上这款的整个存档目录（bis/user/save）逐文件拉回游戏库 games/<程序号>/save_backup/<时刻>/（10-27 运维线：
    斯普拉遁3 体感包覆盖装后进了选形象页，原档没有备份、无从比对）。第一次装 / 机上没有存档 = 不备份；拉失败报红停装，宁可不装也不冒丢档的险"""
    from diag import devicectl
    save_dir = f"{docs}/{SAVE_REL}"
    rc, data, err = devicectl(c, "device", "info", "files", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                              "--subdirectory", save_dir, timeout=120)
    files = [f["relativePath"] for f in ((data.get("result") or {}).get("files") or [])
             if not (f.get("resources") or {}).get("isDirectory") and not f["relativePath"].rsplit("/", 1)[-1].startswith(".")]
    if rc:
        # 列不出：App 不在机上（第一次装）才算没有存档；App 在却列不出要分清两种——devicectl 对「目录不存在」和「锁屏 / 隧道断」报同一个错
        #   （11-07 满屏线 Duo 实测：容器第一次装半途失败 / 从没进过游戏，机上 Documents/games 是空目录，原先每次都拒装、玩家永久卡死）。
        #   往上逐级列父目录，第一个列得出的父目录定：里面看不到存档目录 = 没有存档，照装；看得到却列不出 / 父目录一个都列不出 = 停装
        arc, apps, aerr = devicectl(c, "device", "info", "apps", "--device", ident, "--bundle-id", bid, timeout=60)
        if arc:   # 连「装没装过」都问不出（锁屏 / 超时 / 断开）：不能当成第一次装，否则跳过备份直接覆盖（#333）
            return backup_failed(c, "确认不了 iPhone 上有没有装过这款：" + (aerr.splitlines()[-1] if aerr else f"devicectl 退出 {arc}"))
        if any(a.get("bundleIdentifier") == bid for a in (apps.get("result") or {}).get("apps") or []):
            if not save_dir_absent(c, ident, bid, save_dir):
                return backup_failed(c, "读不到 iPhone 上这款的存档目录：" + (err.splitlines()[-1] if err else f"devicectl 退出 {rc}"))
        return None
    if not files:
        return None
    dest = layout.path(c, gid, "save_backup", time.strftime("%Y%m%d-%H%M%S"))
    for rel in files:
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        rc, _, err = devicectl(c, "device", "copy", "from", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                               "--source", f"{save_dir}/{rel}", "--destination", str(dest / rel), timeout=120)
        if rc or not (dest / rel).is_file():
            return backup_failed(c, f"拉存档失败（{rel}）：" + (err.splitlines()[-1] if err else f"devicectl 退出 {rc}"))
    return dest


def phone_ipa_path(c):
    """「显示 IPA」用：装机时组装的那份 IPA（整个游戏库共用一份，在默认位置根 S2Arm.ipa）；还没装过、没有这个文件 → 空串（界面不给按钮）。
    原先给的是这款的 image/ios 目录，「显示 IPA」打开的是游戏目录"""
    ipa = layout.phone_ipa(c)
    return str(ipa) if ipa.is_file() else ""


def phone_img_path(c, gid):
    """导出给自签玩家（v0.3.0）：这款的单一 IMG（image/ios/pack/game.img），和库根 S2Arm.ipa 一起就是玩家要拷的全部；
    还没出成 IMG 形态（旧版出的包 / 多程序合集）→ 空串（界面不给按钮）"""
    img = layout.ios_pack(c, gid) / "game.img" if gid else None
    return str(img) if img and img.is_file() else ""


def phone_shader_cache(c, gid):
    """导出可选附带的着色器缓存（加速首次进局，不带也能玩）：资源包里的 shaders/ 目录；没有 → 空串"""
    d = layout.ios_pack(c, gid) / "shaders" if gid else None
    return str(d) if d and d.is_dir() else ""


def devcert_items(c, item, udid):
    """开发者证书模式的清单项（v0.2.4）：替掉 Apple ID / Impactor 两项。问题只提示、不挡（blocking 只给「没出包」）；
    到期 / 权限这类提醒随结果 devcert.warnings 给启动器画黄字。返回体检结果（读不出 → None）"""
    try:
        got = devcert.summary(c, udid=udid)
    except Failure as e:
        item("devcert", False, "开发者证书可用", str(e))
        return None
    item("devcert", not got["blocking"], "开发者证书可用", got["blocking"][0]["text"] if got["blocking"] else "")
    if udid and not got["allDevices"]:
        item("devcertDevice", got["deviceListed"], "这台 iPhone 在描述文件的设备列表里",
             "不在列表里：签出来装不上这台。请在开发者网站登记这台设备并重新生成描述文件，再在出包页重新导入。")
    return got


# 装到 iPhone 的方式（11-11 维护者定「怎么签、怎么装收成一套」）：device = 一键装（启动器签名并装；签名身份仍是 devcert 状态 active 与否，不另存）；
#   export = 导出，自己签名安装（未签名 S2Arm.ipa + 各款 game.img 到文件夹）。存私有目录 install.json，Mac / Windows 两端读同一份；完成页临时换一次不改这里
INSTALL_MODES = ("device", "export")


def install_mode(c):
    m = read(c.private / "install.json", {})
    return m.get("mode") if isinstance(m, dict) and m.get("mode") in INSTALL_MODES else "device"


def export_available(c):
    """「导出，自己签名安装」能不能用：导出作业（export_phone，IMG + 未签名壳）合入前为 False，两端把这一项置灰写「下一版提供」"""
    return callable(globals().get("export_phone"))


def install_mode_job(c):
    """作业 installMode：带 mode 就改（只认 device / export；导出还不能用时拒收 export），不带只读 → {mode, exportAvailable, signMode}"""
    mode = c.r.get("mode")
    if mode is not None:
        if mode not in INSTALL_MODES:
            raise Failure(f"不认识的安装方式：{mode}", code="job_failed")
        if mode == "export" and not export_available(c):
            raise Failure("「导出，自己签名安装」下一版提供。", code="job_failed")
        atomic(c.private / "install.json", dict(mode=mode))
    return dict(mode=install_mode(c), exportAvailable=export_available(c), signMode="devcert" if devcert.active(c) else "appleId")


def readiness(c):
    """装机前清单（用户体验线 11-02）：启动器装机页每几秒问一次、AI 代劳也读它，逐项说「好了没有、没好要谁做什么」，只有 iPhone 版没做好才挡（blocking），其余只提示，真失败由 install 给原因。
    只读不改：不申请描述文件、不签名、不碰设备上的 App。每项 {id, ok, title, detail, who}；who = human（只能玩家本人做）/ app（启动器自己能做）。
    文案都是定句（启动器按原句查英文），账号名、设备名另放 account / device。
    设备一项一项判（连上 → 信任 → 开发者模式），前一项没好，后面的标 waiting、不给误导的「没打开」"""
    gid = c.r.get("gameId") or ""
    if os.name == "nt":
        return readiness_windows(c, gid)
    items = []
    ipa_path = ""
    def item(key, ok, title, detail, who="human", waiting=False, note=""):
        wait = waiting and not ok
        # 等前一步的不给说明，免得 AI 拿去催玩家；好了的项也不带说明，只有 note（好了但值得知道的，如只靠网络连着）照带
        items.append(dict(id=key, ok=bool(ok), waiting=wait, blocking=key == "package" and not ok, title=title, detail=note if ok else "" if wait else detail, who=who))
    try:
        ios_pack(c, gid)
        ipa_path = phone_ipa_path(c)
        item("package", True, "这款游戏的 iPhone 版已经做好", "")
    except Failure:
        item("package", False, "这款游戏的 iPhone 版已经做好", "还没做好：先做 iPhone 版，做好后这里自动打勾。", who="app")
    use_cert = devcert.active(c)
    team = None
    if not use_cert:
        teams = xcode_teams(c.env())
        team = (pick_team(teams) if teams else None)
        item("appleId", team, "已登录 Apple ID", "" if team else (TEAM_PENDING if xcode_account(c.env())[0] else ACCOUNT_NONE))
    # 清单只看玩家选的那台、每次现查（11-11 玩家实报：没插线却亮「iPhone 已用数据线连上」——原先没选设备时作业自己挑了同网的 iPad 来打勾）
    want = (c.r.get("device") or "").strip()
    link = device_link(c, want, polling=True) if want else dict(device=None, stage="connected", problem=S_DEVICE_REQUIRED, trace=[], devices=[])
    one, stage = link["device"], link["stage"]
    cert = devcert_items(c, item, (one or {}).get("hardwareProperties", {}).get("udid") or "") if use_cert else None
    name = (one.get("deviceProperties", {}).get("name") or "").strip() if one else ""
    kind = device_kind(one) if one else "iPhone / iPad"
    how = "数据线" if one and _link(one).get("transportType") == "wired" else "同一 Wi-Fi"
    item("connected", one, "{0}「{1}」已连上（{2}）".replace("{0}", kind).replace("{1}", name).replace("{2}", how) if one else "选的设备已连上（数据线或同一 Wi-Fi）",
         link["problem"] if stage == "connected" else "", note=S_NETWORK if one and how != "数据线" else "")   # 只靠网络连着：能装，但提醒插线更稳（玩家反馈 11-11）
    paired = bool(one) and stage != "trusted"
    item("trusted", paired, "{0} 已信任这台 Mac".replace("{0}", kind), link["problem"] if stage == "trusted" else S_TRUST, waiting=not one)
    mode_pending = paired and stage == "prepare" and one.get("deviceProperties", {}).get("developerModeStatus") not in ("enabled", None)
    dev_mode = paired and stage != "developerMode" and not mode_pending
    item("developerMode", dev_mode, "{0} 已打开开发者模式".replace("{0}", kind), S_DEV_MODE, waiting=not paired or mode_pending)
    item("deviceReady", dev_mode and stage == "", "{0} 已准备好安装".replace("{0}", kind), link["problem"] if stage == "prepare" else "", who="app", waiting=not paired or stage == "developerMode")
    account = (cert or {}).get("teamName") or "" if use_cert else (team["name"] or team["id"]) if team else ""
    return dict(gameId=gid, items=items, ready=not any(i["blocking"] for i in items), device=name, deviceKind=kind.lower() if one else "", account=account, ipaPath=ipa_path, imgPath=phone_img_path(c, gid), shaderCachePath=phone_shader_cache(c, gid),
                signing="" if use_cert else signing_summary(c.env()), signMode="devcert" if use_cert else "appleId", devcert=cert, installMode=install_mode(c))


def linked_sdk(exe):
    """主程序链接时的 iOS SDK 版本（Mach-O LC_BUILD_VERSION 的 sdk 字段，xxxx.yy.zz 按半字节编码），读不到返回 None。
    11-07 Duo 实测：iOS 按主程序链接的 SDK 判 App 认不认识本机型——旧 SDK（26.5）出的壳在 iPhone Duo（iOS 27 新机型）上按旧 iPhone 尺寸
    （667×375 点）缩小居中、四周留黑；同一份代码用 27.1 SDK 链接就铺满 2034×1398。启动屏键（UILaunchStoryboardName / UILaunchScreen）有没有都一样"""
    import struct
    try:
        with open(exe, "rb") as f:
            head = f.read(4096 * 8)
    except OSError:
        return None
    if len(head) < 32 or struct.unpack_from("<I", head)[0] != 0xFEEDFACF:   # 只认 64 位单架构（iOS 壳只出 arm64）
        return None
    ncmds, off = struct.unpack_from("<I", head, 16)[0], 32
    for _ in range(ncmds):
        if off + 8 > len(head):
            return None
        cmd, size = struct.unpack_from("<II", head, off)
        if cmd == 0x32 and off + 16 <= len(head):   # LC_BUILD_VERSION：platform, minos, sdk
            v = struct.unpack_from("<I", head, off + 16)[0]
            return (v >> 16, (v >> 8) & 0xFF, v & 0xFF)
        if size < 8:
            return None
        off += size
    return None


def check_shell_sdk(c, app, dev):
    """iPhone 的系统大版本比壳链接的 SDK 新 → 黄字 shell_sdk_old（照常装）：这一代系统新出的机型（如 iPhone Duo）会把 App 按旧尺寸缩小显示"""
    try:
        exe = app / plistlib.loads((app / "Info.plist").read_bytes()).get("CFBundleExecutable", "S2Arm")
    except (OSError, plistlib.InvalidFileException):
        return
    sdk, os_major = linked_sdk(exe), str(dev.get("os") or "").split(".")[0]
    if sdk and os_major.isdigit() and int(os_major) > sdk[0]:
        c.diagnostic(f"这个包是用 iOS {sdk[0]}.{sdk[1]} 的 Xcode 出的，这台 iPhone 是 iOS {dev.get('os')}：iOS {os_major} 新出的机型（如 iPhone Duo）"
                     "上整个 App 会按旧 iPhone 尺寸缩小在屏幕中间", code="shell_sdk_old", severity="warning")


def sign_and_install(c, ipa, team, dev, udid, bid, games, steps=True):
    """steps=False：不报主进度（出包重叠早装在后台线程里调，进度条归出包）。解 ipa → 改包名 → 申请开发描述文件 → 用玩家 Apple ID 签名 →
    按各款文档根 Documents/games/<游戏号> 拉跑局知识与存档备份 → devicectl 覆盖装（不卸载，Documents 保留）"""
    ents = c.engine / "pack/app.entitlements"
    stage = Path(tempfile.mkdtemp(prefix="s2a-install-", dir=c.private))
    log = c.logs / (c.task + "-install.log")
    try:
        # ditto 解：保留可执行位与符号链接（zipfile 会丢，codesign / 安装都要）
        r = subprocess.run(["/usr/bin/ditto", "-x", "-k", str(ipa), str(stage)], capture_output=True, text=True)
        app = next((stage / "Payload").glob("*.app"), None)
        if r.returncode or not app:
            raise Failure("解不开 iPhone 包：" + (r.stderr.strip()[-200:] or str(ipa)), code="job_failed")
        info = app / "Info.plist"
        pl = plistlib.loads(info.read_bytes()); pl["CFBundleIdentifier"] = bid
        shown = container_display_name(app)
        if shown:
            pl["CFBundleDisplayName"] = shown
        info.write_bytes(plistlib.dumps(pl))
        check_shell_sdk(c, app, dev)
        if devcert.active(c):   # 玩家自己的开发者证书（v0.2.4）：rcodesign 直接读 p12 签，不申请描述文件、不要 Xcode 账号
            if steps: c.begin("用你的开发者证书签名", 4, 6)
            devcert.sign_app(c, app, log)
            devcert.export_ipa(c, stage / "Payload")
        else:
            sign_with_apple_id(c, app, team, bid, ents, udid, log, steps)
        if steps: c.begin("装到 iPhone", 5, 6)
        from diag import devicectl
        for g in games:
            pull_seen(c, dev["id"], bid, g, udid or dev["id"], docs=game_docs(g))
            backup_saves(c, dev["id"], bid, g, docs=game_docs(g))
        rc, _, err = devicectl(c, "device", "install", "app", "--device", dev["id"], str(app), timeout=1800)
        if rc:
            # 识别 devicectl 的实际原因，不把额度、配对和开发者模式失败统称签名。
            code = classify(err, default="device_install_failed")
            reason = err.strip()[-2000:] or f"devicectl 退出 {rc}（未提供错误详情）"
            raise Failure("装不上 iPhone：" + reason, code=code)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def sign_with_apple_id(c, app, team, bid, ents, udid, log, steps):
    """Apple ID 模式：按玩家 Xcode 账号申请开发描述文件（ensure_profile.sh）再用钥匙串身份签（dev_sign.py）"""
    if steps: c.begin("申请开发描述文件（第一次要几十秒）", 3, 6, keychain=True)   # 用 Xcode 账号申请：可能弹钥匙串授权
    try:
        c.run(["bash", c.engine / "pack/ensure_profile.sh", bid, team["id"], ents] + ([udid] if udid else []), log)
        if steps: c.begin("用你的 Apple ID 签名", 4, 6, keychain=True)   # codesign 用钥匙串里的签名身份：可能弹授权（开发者证书模式读 p12，不弹）
        c.run([sys.executable, c.engine / "pack/dev_sign.py", app, bid, team["id"], ents], log)
    except Failure as e:
        if e.code != "tool_exit":
            raise
        from errors import recovery, tool_reason
        text = log.read_text(errors="replace")[-8000:] if log.is_file() else ""
        code = classify(text)
        raise Failure("签名没成：" + tool_reason(log) + "；" + recovery(code, packaged=bool(c.r.get("engineBundle"))), code=code) from e


def win_install_mod(c):   # Windows 签名装机 + 推包（pack/orch/install_win.py：玩家自装的 Impactor 同版 plumesign + s2a-devpush）
    sys.path.insert(0, str(c.engine / "pack/orch"))
    import install_win
    return install_win


def win_udids(W):
    """设备服务里的手机：有 USB 连着的只算 USB 的，同网配对的不算（同 target.cable_first）"""
    devs = W.mux_devices()
    return sorted({u for u, how, _ in devs if u and how == "USB"} or {u for u, _, _ in devs if u})


def win_udid(c, W):
    """要装的那台 = 请求给的 device（UDID，玩家选的那台），不自己挑。这台在任何连接方式上（USB 或同网）在就算在线：有线、无线都可以，
    只要是玩家选的那台（原先有 USB 连着的就只认 USB 的，玩家选的那台走 Wi-Fi、旁边插着另一台时会被判成不在）"""
    want = (c.r.get("device") or "").strip()
    if not want:   # 装机一律要玩家选的那台（前端从装机前清单拿到设备号再带上）
        raise Failure(S_DEVICE_REQUIRED, code="device_required")
    try:
        links = W.mux_devices()
    except OSError as e:
        raise Failure(f"连不上本机苹果设备服务（{e}）：从 Microsoft Store 装「Apple Devices」后重试。", code="device_pairing_required") from e
    if want not in {u for u, _, _ in links if u}:
        # Windows 设备服务分不出「不在线」和「没配对过」、也给不出设备名：按设备号末尾指认那台，不换别的
        raise Failure(f"要装的那台设备（编号末尾 {want[-6:]}）现在不在线：插上数据线并解锁，或让它和这台电脑连同一个 Wi-Fi，再试一次。",
                      code="device_not_connected")
    return want


def readiness_windows(c, gid):
    """装机前清单的 Windows 版：做好 iPhone 版 → Impactor（实测版本 + plumesign）→ 手机连着（设备服务里有且只有一台）；同 Mac 版的项格式"""
    W = win_install_mod(c)
    items = []
    ipa_path = ""
    def item(key, ok, title, detail, who="human", waiting=False, url=None, action=None):
        wait = waiting and not ok
        # 只有没出包才真挡；其余只提示，直接去签名，真失败再给原因
        items.append(dict(id=key, ok=bool(ok), waiting=wait, blocking=key == "package" and not ok, title=title, detail="" if ok or wait else detail, who=who,
                          url=None if ok else url,   # 玩家自装件的官方下载页（同环境检查 winenv 的 url 字段）：启动器渲染成「打开官方下载页」，不从说明文字里抠链接
                          action=None if ok else action))   # 启动器本地动作（openImpactor：打开随包的 Impactor）；只认枚举，不传路径
    try:
        ios_pack(c, gid)
        ipa_path = phone_ipa_path(c)
        item("package", True, "这款游戏的 iPhone 版已经做好", "")
    except Failure:
        item("package", False, "这款游戏的 iPhone 版已经做好", "还没做好：先做 iPhone 版，做好后这里自动打勾。", who="app")
    resources = c.r.get("resources")
    use_cert = devcert.active(c)
    st = W.impactor.status(resources=resources)
    if use_cert:
        pass   # 证书模式不用 Impactor 账号（plumesign 只装不签，随包就有）；证书两项排在设备之后（要设备 UDID）
    elif st.get("bundled"):   # 发版启动器随包（11-07）：零跳转；第一次要在 Impactor 里登录 Apple ID（密码只在 Impactor 里输、只发给 Apple，我们不代输）
        item("impactor", st["verdict"] == "ok", "签名工具 Impactor 已就绪（随 S2Arm 附带的第三方开源工具）",
             recovery("impactor_missing", packaged=True))
        item("impactor_login", st["verdict"] != "ok" or W.impactor.logged_in(), "已在 Impactor 里登录 Apple ID（只需一次）",
             "点「打开 Impactor」，在「设置 → 添加账号」登录你的 Apple ID（免费的就行），登录好回来这里自动打勾。",
             action="openImpactor")
    else:
        item("impactor", st["verdict"] == "ok" and bool(W.plumesign_path()), "Impactor 已装好并登录过 Apple ID",
             recovery(st["code"] or "impactor_missing", packaged=False), url=st["download"])
    # 清单只看要装的那台、每次现查：请求带了 device（续签 = 当初那台）就只认它（USB 或同网都算）；没带就是唯一连着的那台（前端拿它的号去装）
    want = (c.r.get("device") or "").strip()
    try:
        links = W.mux_devices()
        udids = ([want] if want in {u for u, _, _ in links if u} else []) if want else win_udids(W)
    except OSError:
        links, udids = [], []
    how = "数据线" if udids and any(u == udids[0] and t == "USB" for u, t, _ in links) else "同一 Wi-Fi"
    item("connected", len(udids) == 1, "{0}已连上（{1}）".replace("{0}", "设备").replace("{1}", how) if len(udids) == 1 else "选的设备已连上（数据线或同一 Wi-Fi）",
         (f"要装的那台设备（编号末尾 {want[-6:]}）现在不在线：插上数据线并解锁，或让它和这台电脑连同一个 Wi-Fi。" if want else
          "连着不止一台 iPhone / iPad：只留要装的那一台。" if len(udids) > 1 else "用数据线把 iPhone / iPad 连到这台电脑，或让它和这台电脑连同一个 Wi-Fi；解锁并点「信任」。"))
    cert = devcert_items(c, item, udids[0] if len(udids) == 1 else "") if use_cert else None
    kind = ""
    if len(udids) == 1 and hasattr(W, "device_kind"):   # #487：连着的是 iPad 时入口写「装到 iPad」
        try:
            kind = W.device_kind(udids[0])
        except (OSError, ValueError):
            kind = ""
    return dict(gameId=gid, items=items, ready=not any(i["blocking"] for i in items), device=udids[0] if len(udids) == 1 else "", deviceKind=kind,
                account=(cert or {}).get("teamName") or "", ipaPath=ipa_path, imgPath=phone_img_path(c, gid), shaderCachePath=phone_shader_cache(c, gid), signMode="devcert" if use_cert else "appleId", devcert=cert,
                installMode=install_mode(c))


def devpush_client(c, udid, bid, work):
    """s2a-devpush（house_arrest + AFC）：两端都随发版带，devicectl 没有的「删容器里的目录」「整目录拉回」走它"""
    sys.path.insert(0, str(c.engine / "tools"))
    import push_pack as P
    prebuilt = c.engine / "Binaries/Prepare/devpush" / P.EXE
    exe = P.devpush_path(str(prebuilt) if prebuilt.is_file() else None, c.env())
    if not exe:
        raise Failure("找不到 s2a-devpush：请重新安装完整的 S2Arm。", code="tool_missing")
    return P.Devpush(exe, udid, bid, work, c.env())


class MacPhone:
    """Mac：Xcode 账号签名 + devicectl 装 + push_pack 推（出包重叠早装传入开工前认好的账号与设备）"""

    def __init__(self, c, team=None, dev=None, udid=None):
        self.c = c
        self.team = team or devcert.team(c) or pick_team(xcode_teams(c.env()), c.r.get("teamId"))
        self.dev = dev or phone(c)
        self.udid = udid if udid is not None else udid_of(c, self.dev["id"])
        self.bid = devcert.state(c)["bundleId"] if devcert.active(c) else container_bundle_id(self.team["id"], c)   # 证书模式：描述文件定的包名（和 Apple ID 模式是两个 App）
        self.key = self.udid or self.dev["id"]   # devices/<设备>.json 的键
        # deviceKind / deviceName：完成页、诊断写「已装到 iPad「名字」」，不写死 iPhone
        self.info = dict(device=self.dev["name"], deviceName=self.dev["name"],
                         deviceKind="iPad" if (self.dev.get("productType") or "").startswith("iPad") else "iPhone",
                         team=self.team["name"], free=self.team["free"])
        self.pending = None   # 资源传完但没拉起 App 解开时的那句（put_game 带进结果 unpackPending）

    def backup(self, g):
        backup_saves(self.c, self.dev["id"], self.bid, g, docs=game_docs(g))

    def app_missing(self, bid, why):
        """s2a-devpush 进不了容器时，这台手机确实没装这个包名吗？Mac 上没装时 s2a-devpush 只回「device socket io failed」（真机实测），
        和真断线分不开，所以问 devicectl 的应用列表（同 backup_saves）；连它也问不出 → 停装"""
        from diag import devicectl
        rc, apps, err = devicectl(self.c, "device", "info", "apps", "--device", self.dev["id"], "--bundle-id", bid, timeout=60)
        if rc:
            note(self.c, "问不出 iPhone 上有没有装过 S2Arm（" + (err.splitlines()[-1] if err else f"devicectl 退出 {rc}") + "），按装着、读不到继续")
            return False
        return not any(a.get("bundleIdentifier") == bid for a in (apps.get("result") or {}).get("apps") or [])

    def install(self, ipa, games, steps=True):
        try:
            sign_and_install(self.c, ipa, self.team, self.dev, self.udid, self.bid, games, steps=steps)
        except Failure as e:
            # 包名被别处占用（玩家先自签装过 S2Arm）：自动换一个包名再签一次、记下，之后都用它；换过的也被占才照报 app_id_taken
            if e.code != "app_id_taken" or devcert.active(self.c) or self.bid.endswith(ALT_BUNDLE_SUFFIX):
                raise
            old, self.bid = self.bid, self.bid + ALT_BUNDLE_SUFFIX
            sign_and_install(self.c, ipa, self.team, self.dev, self.udid, self.bid, games, steps=steps)
            bundle_switched(self.c, self.team["id"], self.bid)
            self.c.diagnostic(f"包名 {old} 已被别的签名占用，这次自动改用 {self.bid} 装好了", code="bundle_id_switched", severity="warning")

    def before_push(self, packs):
        mbps = usb_mbps(self.udid, self.c.env())
        if 0 < mbps < 5000:   # 10-26 实测：两台测试设备经集线器只有 480 Mb/s，资源包约 31 MB/秒；USB 3 直插约 10 倍
            gb = sum(f.stat().st_size for p in packs.values() for f in p.rglob("*") if f.is_file()) / 2**30
            if not packs or gb <= 0:   # 这次一个资源包都不推（只换壳更新、续签）：不说「第一次全拷约 N 分钟」（11-11 维护者截图：0.0 GB 也照报，误导）
                return
            self.c.diagnostic(f"这台 iPhone 现在按 USB 2.0（{mbps} Mb/s）连着：资源包 {gb:.1f} GB 第一次全拷约 {max(1, round(gb * 1024 / 31 / 60))} 分钟，"
                              "换 USB 3 能快约 10 倍（以后重装只推变了的文件）", code="usb_slow", severity="warning")

    def push(self, g, pack):
        n0 = len(self.c.job["diagnostics"])
        r = push_pack(self.c, self.dev["id"], self.bid, pack, udid=self.udid, docs=game_docs(g), ctx=game_ctx(g), pack_root=pick_pack_root(self.c, self, g))
        hit = [d for d in self.c.job["diagnostics"][n0:] if d.get("code") == "manual_unpack_required"]   # push_pack 按「需要玩家操作」收尾时记的那条
        if hit: self.pending = hit[-1].get("summary") or ""
        return r

    def purge(self, g):
        with tempfile.TemporaryDirectory(dir=self.c.private) as w:
            return purge_game(devpush_client(self.c, self.udid, self.bid, w), g)


class WinPhone:
    """Windows：Impactor 同版 plumesign 签名装机（包名由它按账号定、装完才知道，记在这台的设备记录 devices/<设备>.json 的 bundleId，供下次覆盖前备份）+ s2a-devpush 备份 / 推 / 删"""

    def __init__(self, c):
        self.c, self.W = c, win_install_mod(c)
        self.udid = win_udid(c, self.W)
        self.key = self.udid
        self.bid = devcert.state(c)["bundleId"] if devcert.active(c) else layout.load_device(c, self.key).get("bundleId") or None
        self.devpush = c.engine / "Binaries/Prepare/devpush/s2a-devpush.exe"
        # Windows 设备服务给不出设备名，类型按 USB 产品号认（同装机前清单 deviceKind）；认不出写空，前端写「iPhone / iPad」
        kind = ""
        if hasattr(self.W, "device_kind"):
            try:
                kind = {"ipad": "iPad", "iphone": "iPhone"}.get(self.W.device_kind(self.udid), "")
            except Exception:
                kind = ""
        self.info = dict(device=self.udid, deviceName="", deviceKind=kind)
        self.pending = None   # 资源传完但没拉起 App 解开时的那句（put_game 带进结果 unpackPending）

    def client(self, work):
        return devpush_client(self.c, self.udid, self.bid, work)

    def app_missing(self, bid, why):
        """Windows 上没有 devicectl：手机明确答「没有这个 App」时 s2a-devpush 的原文含 ApplicationLookupFailed（Windows 实机核过）；
        进不了容器时 s2a-devpush 再用 installation_proxy 按包名查一次，确实没装就打结构化标记 S2A_APP_MISSING（11-11 实机实测：
        删了 S2Arm 再装，原文只有「device socket io failed」，原先被当成锁屏挡住）。两样都没有 = 判不了，交给调用方按装机原则继续"""
        return "ApplicationLookupFailed" in why or "S2A_APP_MISSING" in why

    def backup(self, g):
        """覆盖装前备份本款存档（同 Mac backup_saves 口径：拉失败就停装）。按这次要装的包名查（这台没记录也可能有 Mac 装的同包名 App 和存档）；
        只有手机明确答「没有这个 App」（ApplicationLookupFailed）才算没装过、不备份。别的取不到（锁屏 / 断开 / 配对问题）一律停装，
        不当成没装过——当成没装会跳过备份直接覆盖（#333）"""
        bid = self.bid or self.bundle_for_signing()
        if not bid:
            # 这台没记过包名、又读不到 Impactor 当前账号的团队号：定不了包名就查不了手机上有没有这款的存档。原先直接放行、交给 plumesign 自己定包名
            #   装上去，等于不备份就覆盖（审计 P2-253）。真实 accounts.json 每个账号都带十位 team_id（Windows 实机核过），读不到 = 存档坏了或没选账号，停装
            return backup_failed(self.c, "读不到 Impactor 当前账号的团队号，定不了要装的包名，查不了手机上这款的存档")
        dest = layout.path(self.c, g, "save_backup", time.strftime("%Y%m%d-%H%M%S"))
        with tempfile.TemporaryDirectory(dir=self.c.private) as w:
            ok, out = devpush_client(self.c, self.udid, bid, w).get_tree(f"{game_docs(g)}/{SAVE_REL}", dest)
        if not ok:
            if "ApplicationLookupFailed" in out or "S2A_APP_MISSING" in out:   # 机上确实没装这个包名（Windows 实机核过的原文 / s2a-devpush 查 installation_proxy 的标记）
                return None
            return backup_failed(self.c, "拉存档失败：" + out[-200:])
        return dest if dest.is_dir() else None

    def install(self, ipa, games, steps=True):
        for g in games:
            self.backup(g)
        if devcert.active(self.c):
            return self.install_devcert(ipa, steps)
        if steps: self.c.begin("签名并装到 iPhone（Impactor 官方命令行 plumesign）", 3, 6)
        b = self.W.impactor.bundled(self.c.r.get("resources")) or {}   # 发版启动器随包的 plumesign（11-07）；源码树没有 → install_win 照旧找
        log = self.c.logs / (self.c.task + "-install.log")
        self.c.last_log = log
        ns = argparse.Namespace(ipa=str(ipa), udid=self.udid, name=None, plumesign=b.get("plumesign"), log=str(log), bundle=self.bundle_for_signing())
        try:
            self.bid = self.W.install_app(ns, say=lambda m: self.c.emit("message", m))
        except self.W.Fail as e:
            # 有对应处理建议的码（free_appid_limit = Apple 9120 等）：上屏说人话的原因与办法，plumesign 英文原文只进诊断（Windows 实机：
            #   原先整句英文「Developer API error 9120 …」直接上屏，玩家只看到签名失败）；没有专门建议的照旧上屏原文
            code = e.err or "device_install_failed"
            from errors import RECOVERY
            if code in RECOVERY and code not in ("device_install_failed", "job_failed"):
                raise Failure("签名装机没成：" + RECOVERY[code], code=code, internal=str(e)) from e
            raise Failure(str(e), code=code) from e
        rec = layout.load_device(self.c, self.key)
        layout.save_device(self.c, self.key, dict(rec, bundleId=self.bid))

    def install_devcert(self, ipa, steps):
        """玩家自己的开发者证书（v0.2.4）：解 ipa → rcodesign 签（同 Mac devcert.sign_app）→ 另存 S2Arm.signed.ipa → plumesign 只装不签（device --install）"""
        c = self.c
        log = c.logs / (c.task + "-install.log")
        c.last_log = log
        stage = Path(tempfile.mkdtemp(prefix="s2a-install-", dir=c.private))
        try:
            import zipfile
            with zipfile.ZipFile(ipa) as z:
                z.extractall(stage)
            app = next((stage / "Payload").glob("*.app"), None)
            if not app:
                raise Failure("解不开 iPhone 包：" + str(ipa), code="job_failed")
            if steps: c.begin("用你的开发者证书签名", 3, 6)
            bid, _ = devcert.sign_app(c, app, log)
            devcert.export_ipa(c, stage / "Payload")
            if steps: c.begin("装到 iPhone", 4, 6)
            b = self.W.impactor.bundled(c.r.get("resources")) or {}
            try:
                self.W.install_signed(self.W.plumesign_path(b.get("plumesign")), app, self.udid, log)
            except self.W.Fail as e:
                raise Failure(str(e), code=e.err or "device_install_failed") from e
        finally:
            shutil.rmtree(stage, ignore_errors=True)
        self.bid = bid
        rec = layout.load_device(c, self.key)
        layout.save_device(c, self.key, dict(rec, bundleId=bid))

    def bundle_for_signing(self):
        """交给 plumesign 的包名：和 Mac 同一个（container_bundle_id(团队号)，团队号取 Impactor 当前账号）。这台记录过只差大小写的包名
        （早先 Windows 让 plumesign 自己定的 io.s2arm.games.<大写团队号>）就沿用它：换成小写会在手机上多出一个 S2Arm、存档留在旧的里。
        读不到团队号 → None（照旧由 plumesign 定）"""
        if devcert.active(self.c):
            return devcert.state(self.c)["bundleId"]
        team = self.W.impactor.selected_team() if hasattr(self.W.impactor, "selected_team") else None
        if not team:
            return None
        want = container_bundle_id(team)
        return self.bid if self.bid and self.bid.lower() == want.lower() else want

    def before_push(self, packs):
        pass

    def push(self, g, pack):
        try:
            return self.W.push_pack(self.udid, self.bid, str(pack), str(self.devpush) if self.devpush.is_file() else None,
                                    say=lambda m: self.c.emit("message", m), docs=game_docs(g), ctx=game_ctx(g), apply_after=not img_pack(pack),
                                    pack_root=pick_pack_root(self.c, self, g),
                                    progress=lambda d, t, k, n: push_progress(self.c, d, t, k, n),
                                    stage=lambda name, d=None, t=None: push_stage(self.c, name, d, t))
        except self.W.Fail as e:
            if e.err == "manual_unpack_required":
                self.c.diagnostic(str(e), code=e.err, severity="warning")
                self.pending = str(e)
                return e.transferred
            raise Failure(str(e), code=e.err or "resource_transfer_failed") from e

    def purge(self, g):
        with tempfile.TemporaryDirectory(dir=self.c.private) as w:
            return purge_game(self.client(w), g)


def phone_for(c):
    return WinPhone(c) if os.name == "nt" else MacPhone(c)


GID_RE = re.compile(r"[0-9A-F]{16}")
# 机上目录不存在：s2a-devpush ls 的结构化错误码 S2A_AFC_ERR 8（AFC ObjectNotFound）；旧工具 / devicectl 只有原文，兜底认
#   「No such file」与「Object not found / ObjectNotFound」（带不带空格、大小写都认）。玩家实机（Windows 0.2.7、iOS 27.0.1）原文是
#   「afc error: Object not found」，原先只认 ObjectNotFound，首次装机（App 在、还没有 Documents/games）被当成读不出设备挡住（v0.2.8 热修）
AFC_NOT_FOUND = 8


def dir_missing(out):
    m = re.search(r"S2A_AFC_ERR (\d+)", out or "")
    if m:
        return int(m.group(1)) == AFC_NOT_FOUND
    return bool(re.search(r"no such file|object\s*not\s*found", out or "", re.I))


def phone_bid(ph):
    """这次要装的包名：这台记录过的；Windows 第一次装还没记录 → 按 Impactor 当前账号算（同 WinPhone.bundle_for_signing）"""
    return ph.bid or (ph.bundle_for_signing() if hasattr(ph, "bundle_for_signing") else None)


def phone_games(c, ph):
    """这台手机上的 S2Arm 里有哪些游戏——真相在手机上，不在某一台电脑的设备记录里（同一台手机 Mac 装几款、Windows 再装一款时，
    各自的记录只有自己装的）。列这个包名的资源包新旧两处游戏目录（PACK_GAMES、Documents/games）：只认目录名是 16 位游戏号、
    pack_listing 选出的那处资源包已解开（.applied）的，别的跳过。
    进不了容器时问平台这个包名装没装（ph.app_missing）：确实没装 → None（和「装着、一款都没有」的空集分开：没装时本机记录的各款也不在手机上了，
    container_others 据此不再带）。装着却列不出、或连装没装都判不了（锁屏 / 断开 / 工具原文认不出）：照装机原则（11-11「认不出的直接装」）
    按「这处没有别的游戏」继续，只记进日志——最坏是这台电脑不知道的别的款这次没带进容器，它们的资源包和存档还在手机上，回原电脑再装就回来"""
    bid = phone_bid(ph)
    if not bid or not ph.udid:
        return set()
    with tempfile.TemporaryDirectory(dir=c.private) as w:
        cl = devpush_client(c, ph.udid, bid, w)
        names = set()
        for root in (DOCS_GAMES, PACK_GAMES):
            rc, out = cl.call("ls", root)
            if rc:
                if dir_missing(out):   # 这处还没建（App 在、还没装过任何一款 / 只有新或旧一处）：这处当 0 款，装机照常（推资源包时自会建目录）
                    continue
                if ph.app_missing(bid, out):
                    return None
                note(c, f"读不出{_who(ph)}上 {root} 里装了哪些游戏，按这处没有别的游戏继续装（s2a-devpush ls：{out[-300:].strip()}）")
                continue
            names |= {n.strip().rstrip("/").upper() for n in out.splitlines()}
        return {g for g in names if GID_RE.fullmatch(g) and ".applied" in (pack_listing(cl, g, ph)[1] or [])}


def _who(ph):
    info = getattr(ph, "info", None) or {}
    return f"{info.get('deviceKind') or 'iPhone / iPad'}「{info.get('deviceName')}」" if info.get("deviceName") else (info.get("deviceKind") or "设备")


def pack_listing(cl, gid, ph=None):
    """本款资源包在手机上的哪一处 → (资源包根, 根下列表或 None)：新位置在 → 新位置；新位置不在、旧位置在 → 旧位置（App 下次启动整个同盘挪到新位置，
    含推进 .incoming 的包；增量仍按旧位置的 index.applied.tsv 算，不因新位置是空的整份重推几 GB）；两处都不在（第一次装这款）→ (新位置, None)。
    列不出（锁屏 / 断开等，不是「目录不在」）：照装机原则按「两处都不在」推到新位置继续，只记进日志（最多整份重推一次）。
    老位置真有一份旧的也不会两份长期并存：App 下次打开游戏库时 s2a_pack_migrate_one 见新旧都在、新的已应用，就删掉老的（runtime/src/pack_apply.c）"""
    for root in (game_pack(gid), game_pack_old(gid)):
        rc, out = cl.call("ls", root)
        if not rc:
            return root, out.splitlines()
        if not dir_missing(out):
            if getattr(ph, "c", None) is not None:
                note(ph.c, f"读不出{_who(ph)}上 {gid} 的资源放在哪（{root}），按第一次装推到新位置（s2a-devpush ls：{out[-300:].strip()}）")
            return game_pack(gid), None
    return game_pack(gid), None


def pick_pack_root(c, ph, gid):
    """推这款资源包推到哪（推送、列机上文件、判已应用都用这一处，push_pack.py --pack-root）：规则见 pack_listing"""
    with tempfile.TemporaryDirectory(dir=c.private) as w:
        return pack_listing(devpush_client(c, ph.udid, phone_bid(ph), w), gid, ph)[0]


def purge_game(cl, gid):
    """删手机上这款的数据：文档根（存档 / 金手指 / 解包日志，连同旧位置的资源包）+ 新位置本款目录（资源包）。→ (都删掉?, 输出)"""
    ok1, out1 = cl.rm(game_docs(gid))
    ok2, out2 = cl.rm(f"{PACK_GAMES}/{gid.upper()}")
    return ok1 and ok2, "\n".join(o for o in (out1, out2) if o)


def phone_game_name(c, ph, gid, names):
    """确认框里的名字：本机游戏库有就用库里的，否则读手机上这款资源包自带的 control.nacp，再不行用游戏号"""
    if names.get(gid):
        return names[gid]
    try:
        import library
        with tempfile.TemporaryDirectory(dir=c.private) as w:
            dst = Path(w) / "control.nacp"
            cl = devpush_client(c, ph.udid, phone_bid(ph), w)
            if any(cl.get(f"{root}/ctl/control.nacp", dst) for root in (game_pack(gid), game_pack_old(gid))):
                dump = library.engine_tool(c, "ns2_dump")
                n = dst.read_bytes()
                return dump.nacp_title(n, 14) or dump.nacp_title(n, 0) or gid
    except Exception:   # noqa: BLE001 —— 名字读不到就用游戏号
        pass
    return gid


def container_others(c, ph, rec, leave=None):
    """现组容器要带的别的款：这台电脑记录的 + 手机上实际有的（phone_games）。手机上有、这台电脑没记录、游戏库里也没有的，带不进去
    （App 里的游戏程序读不回电脑）：没带 acceptDropped 就停下报 container_would_drop，列出这几款，玩家确认后再装；确认了就不带它们——
    它们的存档和资源包还在手机上，在原来那台电脑上再装一次就回来。
    手机上这个 App 已经不在（玩家在手机上删了，phone_games → None）：这台电脑记录的各款也跟着没了，一款都不带——原先照带，
    其中换壳后重出不了的报 container_stale 挡住这次装机，能带的也只进程序、资源包按记录不重推"""
    known = set(rec.get("games", {}))
    on_phone = phone_games(c, ph)
    if on_phone is None:
        known = on_phone = set()
    names = {g["id"].upper(): g.get("name") or "" for g in c.catalog()["games"]}
    candidates = sorted((known | on_phone) - {leave})
    lost = [g for g in candidates if g in on_phone and g not in known and g not in names]
    if lost and c.r.get("acceptDropped") is not True:
        shown = [phone_game_name(c, ph, g, names) for g in lost]
        raise Failure(f"这次会让手机上的 {len(lost)} 款游戏暂时不能玩：" + "、".join(shown)
                      + "。它们不是在这台电脑上装的，存档和资源包都还在手机上，到原来那台电脑上再点一次「装到 iPhone」就能回来。确认继续再点一次。",
                      code="container_would_drop", internal=" ".join(lost))
    return [g for g in candidates if g not in lost]


def put_game(c, gid, ph, steps=True, others=None):
    """把这款放进容器并装到手机：现组容器（这款 + 这台手机上已有的各款，ipa.assemble）→ 覆盖装 → 推资源包：这款照推，
    别的款只推「游戏库里的资源包比手机上记的新」的（重新打过 iPhone 包、还没装到这台的），没变的不推（数据和存档不动）。
    装上后记进 devices/<设备>.json，装机产物放默认位置根 S2Arm.ipa（换了壳的话原来那份留作 S2Arm.previous.ipa）。
    gid 为 None + others：不加新款，只把这几款换进本版壳（update_phone）"""
    import ipa as packer
    gid = gid.upper() if gid else None
    if gid: ios_pack(c, gid)   # 这款没有资源包就不组装、不装
    rec = layout.load_device(c, ph.key)
    if others is None:
        others = container_others(c, ph, rec, leave=gid)   # 手机上实际有的款也带上（另一台电脑装的），带不了的先问玩家
    if steps: c.begin("把这款放进手机上的 S2Arm" if gid else "核对手机上的游戏要不要跟着更新", 2, 6)   # gid 为 None = 更新手机上的 S2Arm（update_phone），不说装机的话
    # 改写器修过的话：容器里各款按本引擎改写器核一遍，受影响的只换改写产物（不重出资源包、不推 game.img），再组进新壳（rewrite_refresh.py）
    from rewrite_refresh import refresh_ios
    refresh_ios(c, [g for g in ([gid] if gid else []) + list(others) if g])
    ipa, games, sid = packer.assemble(c, gid, others, failed=rec.get("failedShells", []))
    packs = {g: ios_pack(c, g) for g in games}   # 每款都要有资源包，缺一款就不装（不装半套）
    ph.install(ipa, games, steps=steps)
    # 装上的包名和记录里的不同（换了签名方式 / 包名被占自动换过）= 手机上是另一个 App，资源包都不在里面：每款都推
    moved = bool(rec.get("bundleId")) and bool(ph.bid) and rec["bundleId"] != ph.bid
    stale = [g for g in games if moved or g == gid or pack_id(packs[g]) != (rec["games"].get(g) or {}).get("pack")]
    ph.before_push({g: packs[g] for g in stale})
    img = bool(stale) and all(img_pack(packs[g]) for g in stale)   # 这次推的全是单一 IMG：传完并核过长度即装好，不等机上解开
    if steps: c.begin("核对手机上游戏的资源（有变化的才推，通常一个都不用推）" if not gid else
                      "把游戏推进 iPhone（只推变了的文件；第一次大游戏要几分钟）" if img else "把资源包推进 iPhone 并解开（只推变了的文件；第一次大游戏要几分钟）", 6, 6)
    files = size = 0
    pushed = dict((g, (rec["games"].get(g) or {}).get("pack", "")) for g in games)
    try:
        for g in stale:
            f, n = ph.push(g, packs[g])
            files += f; size += n
            pushed[g] = pack_id(packs[g])
    finally:   # 推到一半失败：已推好的记下，没推的下次照推
        rec = layout.load_device(c, ph.key)
        # signed：这次签名（游戏库页的「还有几天到期 / 续签」读 layout.install_record）：免费账号的描述文件 7 天到期，容器里每款同一次签名
        signed = dict(signed=dict(at=time.time(), free=bool(ph.info["free"]), device=ph.info["device"])) if "free" in ph.info else {}
        layout.save_device(c, ph.key, dict(rec, games={g: dict(pack=pushed[g]) for g in games}, shellId=sid, bundleId=ph.bid or rec.get("bundleId", ""), at=time.time(), **signed))
    packer.commit_phone_ipa(c, ipa, sid)
    # 资源传完但电脑没拉起 App 解开（manual_unpack_required，11-09 #336）：不算「已装好」，结果带上还差的一步，两端前端据此显示「还差最后一步」而不是「已装到 iPhone」
    extra = dict(unpackPending=ph.pending) if ph.pending else {}
    if img: extra["openToFinish"] = True   # 两端成功页写「已传到 iPhone，打开 S2Arm 会自动完成安装」（机上从 game.img 解出几个小件由 App 打开时完成）
    return dict(outputPath=str(layout.phone_ipa(c)), bundleId=ph.bid, games=games, packFiles=files, packBytes=size, **ph.info, **extra)


def shell_outdated(c, rec, sid, games=None):
    """这台手机（设备记录 rec）上的 S2Arm 壳比本版旧时 → {from, to, games, stale}；不旧 / 没装过 → None。
    stale = 新壳认不得、要按新版重新出包的款（ipa.usable_kit 为 None：HOST_ABI 或直连链号变了）；游戏库里已删的款不列（组装时本来就不带）。
    games 缺省取记录里的各款（游戏库页检测用，不连手机）；update_phone 传手机上实际有的"""
    import ipa as packer
    games = sorted(games if games is not None else (rec.get("games") or {}))
    if not games or not rec.get("shellId") or rec.get("shellId") == sid:
        return None
    names = {g["id"].upper(): g.get("name") or g["id"] for g in c.catalog()["games"]}
    games = [g for g in games if g in names]
    stale = [g for g in games if packer.usable_kit(c, g, sid, rec.get("failedShells", [])) is None]
    return dict(fromShell=rec["shellId"], toShell=sid, games=[dict(gameId=g, name=names[g]) for g in games],
                stale=[dict(gameId=g, name=names[g]) for g in stale]) if games else None


def phone_updates(c):
    """游戏库页右上角「更新 iPhone 上的 S2Arm」：各台手机的设备记录里，壳比本版旧的 → [{device, name, fromShell, toShell, games, stale}]。
    只读本机记录（不连手机、不跑出包），catalog 每次带上；没有装过 iPhone 的玩家不算壳号"""
    recs = [(k, r) for k, r in layout.devices(c) if isinstance(r, dict) and r.get("games") and r.get("shellId")]
    if not recs:
        return []
    import ipa as packer
    sid = packer.current_shell_id(c)
    out = []
    for key, rec in recs:
        st = shell_outdated(c, rec, sid)
        if st:
            out.append(dict(device=key, name=(rec.get("signed") or {}).get("device") or "", **st))
    return out


def update_phone(c):
    """「更新 iPhone 上的 S2Arm」：用本版壳 + 手机上各款已有的程序模块组新容器 → 签名 → 只装 App；资源包（IMG）、直连库只推变了的（通常一个都不推），
    手机上的游戏库、存档不动。新壳认不得的款（要按新版重新出包）：没带 acceptStale 就停下报 container_stale 列出它们，玩家确认后不带它们装
    （它们的资源包和存档还在手机上，重新出包后再装就回来）。壳已是本版 → 不装，结果 updated = False"""
    import ipa as packer
    c.begin("找签名账号与 iPhone", 1, 6)
    ph = phone_for(c)
    rec = layout.load_device(c, ph.key)
    others = container_others(c, ph, rec)
    sid = packer.current_shell_id(c)
    st = shell_outdated(c, rec, sid, others)
    if st is None:
        return dict(updated=False, bundleId=ph.bid, games=others, **ph.info)
    stale = [s["gameId"] for s in st["stale"]]
    if stale and c.r.get("acceptStale") is not True:
        raise Failure("这几款要按新版重新出包，更新后在重新出包之前暂时打不开：" + "、".join(s["name"] for s in st["stale"]) + "。确认更新再点一次。",
                      code="container_stale", internal=" ".join(stale))
    keep = [g for g in others if g not in stale]
    if not keep:   # 每一款都要重出：换壳后容器里一款都没有——宿主 0 款的启动路径没在真机验过（同 remove_from_phone 不装空容器），物理上做不了，照旧停
        raise Failure("手机上的游戏都要按新版重新出包，这次没法只更新 S2Arm（更新后一款都打不开）。可以先给它们各「打 iPhone 包」，再点「装到 iPhone」，"
                      "游戏和 S2Arm 会一起换成新版；存档和资源都留在手机上。「只更新 S2Arm、暂不带游戏」下一版开放。", code="container_stale", internal=" ".join(stale))
    r = put_game(c, None, ph, others=keep)
    return dict(r, updated=True, fromShell=st["fromShell"], toShell=sid, skipped=stale)


def install(c):
    """默认「装到 iPhone」：这款进容器（一个 App 装下整个游戏库，免费账号也只占 1 个 App 额度）。加款 = 同一个包名覆盖安装，Documents 保留"""
    gid = c.r.get("gameId") or ""
    ios_pack(c, gid)
    c.begin("找签名账号与 iPhone", 1, 6)
    return put_game(c, gid, phone_for(c))


def restore_previous(c):
    """装回换壳前的那一版手机 S2Arm（默认位置根 S2Arm.previous.ipa）：新运行层在手机上不好用时的回滚。
    装上后现行与上一版对调（再点一次 = 换回来）；被换下的壳号记进这台的 failedShells，之后给这台装机不再把旧款只换宿主带进它（要按新版重出）。
    手机上的资源包和存档不动；换宿主之后才新装的游戏不在上一版里，App 里暂时看不到（数据还在）"""
    import ipa as packer
    current, previous = layout.phone_ipa(c), layout.phone_ipa(c, previous=True)
    games, old_sid = packer.ipa_games(previous)
    _, dropped = packer.ipa_games(current)
    if not games:
        raise Failure("没有可以装回的上一版手机 S2Arm。", code="job_failed")
    c.begin("找签名账号与 iPhone", 1, 3)
    ph = phone_for(c)
    c.begin("装回上一版 S2Arm", 2, 3)
    ph.install(previous, games, steps=False)
    c.begin("记下手机上现在的版本", 3, 3)
    tmp = current.with_name(current.name + ".swap")
    if current.is_file():
        os.replace(current, tmp)
    os.replace(previous, current)
    if tmp.is_file():
        os.replace(tmp, previous)
    rec = layout.load_device(c, ph.key)
    failed = sorted((set(rec.get("failedShells", [])) | ({dropped} if dropped else set())) - {old_sid})   # 装回的这一版不算「不好用」：连点两次 = 换回来，那一版照常能只换宿主
    layout.save_device(c, ph.key, dict(rec, games={g: rec["games"].get(g) or {} for g in games}, shellId=old_sid, failedShells=failed, bundleId=ph.bid or rec.get("bundleId", "")))
    return dict(games=games, bundleId=ph.bid, restoredShell=old_sid, **ph.info)


def remove_from_phone(c):
    """从手机上的 S2Arm 里删一款：备份本款存档 → 用剩下各款现组容器 → 覆盖装 → 删机上本款文档根。
    剩下的款有新运行层认不得的（升级后还没重出）：退回从 S2Arm.ipa 里摘掉这款（pack/ship_ext.py container-drop，其余各款逐字节不变、不换壳）。
    装上之后才改设备记录（装失败时两边还一致）；机上目录没删掉只报黄字（App 里这款已经没了，占的空间下次再清）"""
    import ipa as packer
    gid = (c.r.get("gameId") or "").upper()
    c.begin("找签名账号与 iPhone", 1, 4)
    ph = phone_for(c)
    rec = layout.load_device(c, ph.key)
    if gid not in rec.get("games", {}):
        raise Failure("手机上的 S2Arm 里没有这款。", code="job_failed")
    if not ph.bid:
        raise Failure("这台电脑没记录手机上的 S2Arm：先装一次再删。", code="job_failed")
    c.begin("备份这款的存档", 2, 4)
    backup = ph.backup(gid)
    c.begin("更新手机上的 S2Arm", 3, 4)
    left = container_others(c, ph, rec, leave=gid)   # 同装机：手机上另一台电脑装的款也带上，带不了的先问
    # 最后一款（#227）：不装空容器（宿主 0 款的启动路径没在真机验过，vawin.c 报红不占窗口），手机上的 App 原样留着，
    #   下一步删掉它的数据后库界面按「数据不在」不再显示 = 空库；下次装新游戏时覆盖装把旧程序一起换掉
    if left:
        try:
            ipa, left, sid = packer.assemble(c, None, left, failed=rec.get("failedShells", []))
        except Failure as e:
            if e.code != "container_stale":
                raise
            ipa, left, sid = packer.drop_from_ipa(c, layout.phone_ipa(c), gid)
        ph.install(ipa, left, steps=False)
        packer.commit_phone_ipa(c, ipa, sid)
    rec = layout.load_device(c, ph.key)
    layout.save_device(c, ph.key, dict(rec, games={g: rec["games"].get(g) or {} for g in left}))
    c.begin("删除手机上这款的数据", 4, 4)
    ok, out = ph.purge(gid)
    if not ok:
        c.diagnostic("App 里这款已经删了，但手机上它的数据没删掉：" + out[-200:], code="container_purge_failed", severity="warning")
    return dict(games=left, bundleId=ph.bid, removed=gid, saveBackup=str(backup) if backup else "", dataRemoved=ok, **ph.info)
