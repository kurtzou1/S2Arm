#!/usr/bin/env python3
"""S2Arm 启动器打开时要给玩家看什么（Mac / Windows 共用，只用标准库）。

v0.3.10 起，下载、验签、替换、回滚、重启都交给业界标准组件：Mac 用 Sparkle 2，Windows 用 NetSparkle（appcast 在 dl.s2arm.com/appcast/，
发版用 Ed25519 私钥签）。这里不再有任何换版代码，只剩：

check       查最新版本（官网签名清单，取不到回退 GitHub Release），打印一行 JSON。
inbox       启动器打开时要给玩家看什么：查版本 + 取公告（notice.json，取不到用随包那份），按「永远只给最新一期」算出
            最多一个弹窗（这版更新了什么 / 有新版）、横幅（最新一条重要公告）、消息列表与未读数；打印一行 JSON。只读。
            顺带清掉旧自写换版在 updates/ 下留的残留（clear_stale_pending）。
inbox-seen  玩家关掉了：记进数据目录 updates/seen.json（--update 版本 / --after 版本 / --notice 最新看过的公告号）。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


API = "https://api.github.com/repos/jhaizhou-ops/S2Arm/releases/latest"
# 官网静态文件：发版时和 Release 里的 update-manifest.json / .sig 同一份字节（发版流程写入）。走 CDN、不占 GitHub 匿名查询次数（每 IP 每小时 60 次，
#   国内共享出口很容易被限流）。安全靠清单的 Ed25519 签名，不靠来源：官网那份验签不过就当没有，回退 GitHub。
MIRROR = "https://s2arm.com/update/latest.json"
MIRROR_TIMEOUT = 8   # 官网是首选，连不上要尽快回退 GitHub：只试一次、不重试
# 安装包仍从 GitHub Release 下载（下载链接不是 API，没有 60 次限制）；版本号取自签过名的清单
RELEASE_DOWNLOAD = "https://github.com/jhaizhou-ops/S2Arm/releases/download/v{version}/{name}"
R2_DOWNLOAD = "https://dl.s2arm.com/v{version}/{name}"   # 官网清单命中时安装包先从这里下（发版先传 R2、核过 sha256 才发官网清单），不通再退回 GitHub
ASSETS = {"mac": "S2Arm-mac-arm64.dmg", "windows": "S2Arm-windows-x64.zip"}
DELTAS = {"mac": "S2Arm-mac-arm64-delta-{}.zip", "windows": "S2Arm-windows-x64-delta-{}.zip"}
MANIFEST = "update-manifest.json"
SIGNATURE = "update-manifest.json.sig"
# 发版清单的 Ed25519 公钥。私钥只在发版机上（tools/sign_update_manifest.py）：Release 或发布账号被改，也改不了这份清单。
PUBLIC_KEY = "d553da82bad575ce87bf521a080c9d0997f97d189f0d517e97f80808bafc5225"
TRUSTED_HOSTS = ("github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "s2arm.com", "dl.s2arm.com")
# 旧版启动器交出替换进程后自己退出（Mac NSApp.terminate / Windows 退出）；#931：点了「现在更新并重启」旧版却一直没退，替换进程只被动等满两分钟报
#   update_app_busy。等 EXIT_GRACE 秒还在 → 由替换进程主动结束它（先 TERM，再等 EXIT_TERM_SECONDS 秒还在就 KILL）；只结束确认是这个安装目录里的程序的进程
EXIT_GRACE, EXIT_TERM_SECONDS = 15, 10
CHUNK = 1 << 20


class UpdateError(Exception):
    def __init__(self, code, message, detail=""):
        super().__init__(message)
        self.code = code
        self.detail = detail


def version_tuple(text):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", (text or "").strip())
    return tuple(int(n) for n in match.groups()) if match else None


def trusted(url):
    """正式版只从 GitHub 下载；S2A_UPDATE_API 是验收用的本机假 Release，设了才放开。"""
    import urllib.parse
    parts = urllib.parse.urlsplit(url)
    return bool(os.environ.get("S2A_UPDATE_API")) or (parts.scheme == "https" and parts.hostname in TRUSTED_HOSTS)


def tls_context():
    """随包 Python 在 Mac 上没有证书库：用系统根证书。Windows 的缺省上下文本来就读系统证书库。"""
    import ssl
    context = ssl.create_default_context()
    if sys.platform == "darwin":
        roots = subprocess.run(["/usr/bin/security", "find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"],
                               capture_output=True, text=True, timeout=30).stdout
        if roots:
            context.load_verify_locations(cadata=roots)
    return context


def open_url(url, timeout, start=0):
    import urllib.request
    if not trusted(url):
        raise UpdateError("update_bad_source", "更新地址不是官方来源，已停止。")
    headers = {"User-Agent": "S2Arm-Updater", "Accept": "application/octet-stream, application/json"}
    if start:
        headers["Range"] = f"bytes={start}-"
    request = urllib.request.Request(url, headers=headers)
    return urllib.request.urlopen(request, timeout=timeout, context=tls_context())


FETCH_ATTEMPTS = 3        # 查版本、取签名清单这几个小请求：断了 / 超时再试两次（国内连 GitHub 常有一次性断开）
FETCH_RETRY_SECONDS = 2


def network_error(error, what="连接 GitHub"):
    """网络异常 → 带错误码、玩家看得懂的 UpdateError（界面按码显示原因并给「打开下载页」）：
    限流（403 / 429 且带 X-RateLimit-Remaining: 0 或 Retry-After）→ update_rate_limited，附约几分钟后恢复；
    其它 HTTP 错误 → update_server；断网、DNS、超时、连接被掐、TLS → update_network（原因写进日志 detail）"""
    import urllib.error
    if isinstance(error, UpdateError):
        return error
    if isinstance(error, urllib.error.HTTPError):
        headers = error.headers or {}
        if error.code == 429 or (error.code == 403 and (headers.get("X-RateLimit-Remaining") == "0" or headers.get("Retry-After"))):
            wait = None
            try:
                if headers.get("Retry-After"):
                    wait = int(headers["Retry-After"])
                elif headers.get("X-RateLimit-Reset"):
                    wait = int(headers["X-RateLimit-Reset"]) - int(time.time())
            except ValueError:
                wait = None
            minutes = max(1, (wait + 59) // 60) if wait and wait > 0 else None
            return UpdateError("update_rate_limited", "GitHub 暂时限制了这个网络的查询次数" + (f"，约 {minutes} 分钟后恢复" if minutes else "，过一会儿会恢复")
                               + "。当前版本没有变化，稍后再试，或打开下载页手动下载。", f"HTTP {error.code} {dict(headers)}")
        return UpdateError("update_server", f"GitHub 返回错误（HTTP {error.code}），当前版本没有变化。稍后再试，或打开下载页手动下载。", f"HTTP {error.code} {error.reason}")
    reason = getattr(error, "reason", None) or error
    kind = "超时" if isinstance(reason, TimeoutError) or "timed out" in str(reason) else type(reason).__name__
    return UpdateError("update_network", f"{what}失败（{kind}），当前版本没有变化。请检查网络后重试，或打开下载页手动下载。", f"{type(error).__name__}: {error}")


def fetch(url, timeout, limit):
    """小请求（Release 信息、签名清单）：断了 / 超时再试，限流不再试（只会更久）；还不行按 network_error 报码"""
    import http.client
    import urllib.error
    for attempt in range(FETCH_ATTEMPTS):
        try:
            with open_url(url, timeout) as response:
                return response.read(limit)
        except UpdateError:
            raise
        except (OSError, http.client.HTTPException) as error:
            failure = network_error(error)
            if failure.code == "update_rate_limited" or (isinstance(error, urllib.error.HTTPError) and error.code < 500) or attempt == FETCH_ATTEMPTS - 1:
                raise failure from error
            time.sleep(FETCH_RETRY_SECONDS * (attempt + 1))


def public_key():
    """S2A_UPDATE_PUBKEY 只给验收用的本机假 Release，和 S2A_UPDATE_API 一起设才生效。"""
    return bytes.fromhex(os.environ.get("S2A_UPDATE_API") and os.environ.get("S2A_UPDATE_PUBKEY") or PUBLIC_KEY)


def signed_manifest(assets, tag_version):
    """下载并验清单：签名不对、版本和 Release 对不上一律抛错，后面什么都不下。"""
    sys.path.insert(0, str(Path(__file__).resolve().parent))   # 启动器用 python -I 跑本文件，脚本目录不在搜索路径里
    import ed25519
    raw = fetch(assets[MANIFEST]["browser_download_url"], 30, 1 << 20)
    signature = fetch(assets[SIGNATURE]["browser_download_url"], 30, 1024)
    if not ed25519.verify(public_key(), raw, signature):
        raise UpdateError("update_bad_signature", "新版的签名校验没通过，已停止，当前版本没有变化。")
    manifest = json.loads(raw)
    if version_tuple(manifest.get("version")) != tag_version or not isinstance(manifest.get("files"), dict):
        raise UpdateError("update_bad_signature", "新版的清单和发布版本对不上，已停止，当前版本没有变化。")
    return manifest


LATEST_TTL = 15 * 60   # 查版本结果在本机留 15 分钟：启动时查一次、接着下载、失败后重试都用这一份，不重复调 api.github.com（匿名每 IP 每小时 60 次）


def latest_cache(platform, current):
    """查版本结果的本机缓存（系统给本用户的临时目录）：按平台、当前版本、查询地址分开"""
    import hashlib
    key = hashlib.sha256(f"{platform}|{current}|{os.environ.get('S2A_UPDATE_API') or API}|{mirror_url()}".encode()).hexdigest()[:16]
    return Path(tempfile.gettempdir()) / f"s2arm-update-latest-{key}.json"


def latest(platform, current, fresh=False):
    """→ {available, version, ...}，15 分钟内查过就用上次的结果（latest_cache）。fresh=True（真要下载时，prepare）不读缓存、现查，结果写回缓存：
    启动时的「有没有新版」可以用缓存省限流额度，真下载必须是此刻的发布（剃刀 H18：热修发出后 15 分钟内查不到、查完到下载之间撤版会报 update_none）"""
    cache = latest_cache(platform, current)
    try:
        if not fresh and time.time() - cache.stat().st_mtime < LATEST_TTL:
            info = json.loads(cache.read_text(encoding="utf-8"))
            if isinstance(info, dict) and isinstance(info.get("available"), bool):
                return info
    except (OSError, ValueError):
        pass
    info = query_latest(platform, current)
    try:
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps(info), encoding="utf-8")
        tmp.replace(cache)
    except OSError:
        pass
    return info


def mirror_url():
    """验收用的本机假 Release（S2A_UPDATE_API）只认 S2A_UPDATE_MIRROR，没设就不查官网：单测不连真网"""
    return os.environ.get("S2A_UPDATE_MIRROR", "") if os.environ.get("S2A_UPDATE_API") else MIRROR


def mirror_manifest():
    """官网那份签名清单 → dict；连不上、非 200、验签不过、格式不对一律 None（调用方回退 GitHub）。"""
    url = mirror_url()
    if not url:
        return None
    import http.client
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import ed25519
    try:
        with open_url(url, MIRROR_TIMEOUT) as response:
            raw = response.read(1 << 20)
        with open_url(url + ".sig", MIRROR_TIMEOUT) as response:
            signature = response.read(1024)
        if not ed25519.verify(public_key(), raw, signature):
            return None
        manifest = json.loads(raw)
    except (UpdateError, OSError, http.client.HTTPException, ValueError):
        return None
    return manifest if isinstance(manifest, dict) and version_tuple(manifest.get("version")) and isinstance(manifest.get("files"), dict) else None


def offer(platform, version, mine, files, url_of, notes=None):
    """签过名的清单 files + 每个文件的下载地址（url_of(名字)，没有为 None）→ 给启动器的结果。
    清单里没有本平台的安装包 = 这一版没给本平台出包（如只发了 Mac），按「没有新版」安静返回、标准错误记一行，不报错
    （11-11 维护者：原先按签名不对报 update_bad_signature，只发一个平台时另一平台的老用户每次启动都看到错误）。
    清单本身验签不过、清单与发布版本对不上、下载下来的包与清单校验值不符，仍各自报错（signed_manifest / prepare）"""
    name = ASSETS[platform]
    wanted = files.get(name)
    if not isinstance(wanted, dict):
        print(f"更新：{'.'.join(map(str, version))} 的签名清单里没有 {name}（这一版没给本平台出包），按没有新版处理", file=sys.stderr)
        return {"available": False}
    info = {"available": True, "version": ".".join(map(str, version)), "size": wanted["size"], "sha256": wanted["sha256"],
            "asset": url_of(name), "assetName": name}
    if notes_valid(notes):   # 这版给玩家看的更新说明（签过名的清单里带的，见 notes_from_markdown）
        info["notes"] = notes_valid(notes)
    delta = DELTAS[platform].format(".".join(map(str, mine)))
    entry = files.get(delta)
    if isinstance(entry, dict) and url_of(delta):   # 差分包同样要在清单里，不在就只走整包
        info.update(delta=url_of(delta), deltaName=delta, deltaSize=entry["size"], deltaSha256=entry["sha256"])
    return info


def query_latest(platform, current):
    """→ {available, version, ...}。只提供严格更高的版本（防降级）；校验值和大小都取自签过名的清单，不信 Release 页面。
    先查官网（mirror_manifest）：验签通过就以它为准——不比当前新就是没有新版，不再去问 GitHub（省下的正是限流的那 60 次）；
    官网拿不到 / 验签不过才查 GitHub Release。"""
    mine = version_tuple(current)
    manifest = mirror_manifest()
    if manifest is not None:
        version = version_tuple(manifest["version"])
        if not mine or version <= mine:
            return {"available": False}
        template = os.environ.get("S2A_UPDATE_API") and os.environ.get("S2A_UPDATE_DOWNLOAD") or RELEASE_DOWNLOAD   # 假 Release 验收时下载也指到本机
        v = ".".join(map(str, version))
        info = offer(platform, version, mine, manifest["files"], lambda name: template.format(version=v, name=name), manifest.get("notes"))
        # 安装包先走官方域名（R2）、GitHub 当退路；假 Release 验收只认 S2A_UPDATE_R2，没设就不走（单测不连真网）
        r2 = os.environ.get("S2A_UPDATE_R2", "") if os.environ.get("S2A_UPDATE_API") else R2_DOWNLOAD
        if info.get("available") and r2:
            info.update(asset=r2.format(version=v, name=info["assetName"]), assetFallback=info["asset"])
        return info
    release = json.loads(fetch(os.environ.get("S2A_UPDATE_API") or API, 15, 8 << 20))
    version = version_tuple(release.get("tag_name"))
    assets = {a.get("name"): a for a in release.get("assets") or [] if isinstance(a, dict)}
    package = assets.get(ASSETS[platform])
    if not version or not mine or version <= mine or not package or MANIFEST not in assets or SIGNATURE not in assets:
        return {"available": False}
    manifest = signed_manifest(assets, version)
    return offer(platform, version, mine, manifest["files"], lambda name: assets[name]["browser_download_url"] if name in assets else None, manifest.get("notes"))


NOTICE_URL = "https://jhaizhou-ops.github.io/S2Arm/notice.json"   # docs/site/notice.json，Pages 发布（docs/site/README.md）
NOTICE_LINK_HOSTS = ("github.com", "jhaizhou-ops.github.io", "s2arm.com")   # 11-10 起 s2arm.com 是官方网站


def notice_file():
    """随包那份：引擎快照里的 docs/site/notice.json（launchers/macos/bundle_engine.py INPUTS）"""
    return Path(__file__).resolve().parents[2] / "docs" / "site" / "notice.json"


def notice_valid(data):
    """→ 要显示的公告 {id, text: {zh-Hans, en}, url?}；没有 id 或中英文缺一 → None（= 不显示，撤公告就这么写）。只认纯文本，链接只认官方 https 地址"""
    import urllib.parse
    if not isinstance(data, dict) or data.get("schema") != 1:
        return None
    ident, text = data.get("id"), data.get("text")
    if not (isinstance(ident, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,80}", ident) and isinstance(text, dict)):
        return None
    zh, en = text.get("zh-Hans"), text.get("en")
    if not (isinstance(zh, str) and isinstance(en, str) and zh.strip() and en.strip() and len(zh) <= 600 and len(en) <= 1200):
        return None
    out = {"id": ident, "text": {"zh-Hans": zh.strip(), "en": en.strip()}}
    url = data.get("url")
    if isinstance(url, str):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme == "https" and parts.hostname in NOTICE_LINK_HOSTS:
            out["url"] = url
    return out


def notice_remote(timeout=5):
    """官方下载页上的 notice.json → (取到了没有, 原文)。取到但内容无效 / 已撤照撤（notice_messages 给空列表），不退回随包那份"""
    import urllib.request
    url = os.environ.get("S2A_NOTICE_URL") or NOTICE_URL
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "S2Arm-Launcher", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=timeout, context=tls_context() if url.startswith("https:") else None) as response:
            body = response.read(64 << 10)
    except (OSError, ValueError, __import__("http.client").client.HTTPException, subprocess.SubprocessError):
        return False, None
    try:
        return True, json.loads(body)
    except ValueError:
        return False, None   # 拿到的不是 JSON（门户页、被劫持的网络）：当没取到


NOTE_ITEMS, NOTE_TEXT = 40, 600


def _note_item(item):
    if not isinstance(item, dict):
        return None
    zh, en = item.get("zh-Hans"), item.get("en")
    if not (isinstance(zh, str) and zh.strip() and len(zh) <= NOTE_TEXT):
        return None
    out = {"zh-Hans": zh.strip()}
    if isinstance(en, str) and en.strip() and len(en) <= NOTE_TEXT * 2:
        out["en"] = en.strip()
    return out


def notes_valid(notes):
    """清单里的 notes → {highlights: [项], sections: [{title, items: [项]}]}（项 = {zh-Hans, en?}，纯文本）；不对就 None（= 只显示版本号，不挡更新）"""
    if not isinstance(notes, dict):
        return None
    highlights = [x for x in map(_note_item, notes.get("highlights") or [])][:NOTE_ITEMS] if isinstance(notes.get("highlights"), list) else []
    sections = []
    for sec in notes.get("sections") or [] if isinstance(notes.get("sections"), list) else []:
        if isinstance(sec, dict) and isinstance(sec.get("title"), str) and sec["title"].strip() and isinstance(sec.get("items"), list):
            items = [x for x in map(_note_item, sec["items"]) if x][:NOTE_ITEMS]
            if items:
                sections.append({"title": sec["title"].strip()[:80], "items": items})
    highlights = [x for x in highlights if x]
    return {"highlights": highlights, "sections": sections} if highlights or sections else None


def notes_from_markdown(text):
    """发版说明 notes/vX.Y.Z.md → 清单里的 notes（tools/sign_update_manifest.py --notes 调）。
    「## 小节」→ sections；每条「- 」开头的中文行取加粗那句（没有加粗取整行，去掉 Markdown 记号），紧跟的缩进斜体行当英文；
    「## 亮点」一节只进 highlights（更新后第一次打开弹「这版更新了什么」只认它，程序不替人挑）"""
    def plain(line):
        line = re.sub(r"\*\*(.+?)\*\*", r"\1", line)
        line = re.sub(r"(?<!\w)[*_](.+?)[*_](?!\w)", r"\1", line)
        return re.sub(r"`([^`]*)`", r"\1", line).strip()
    sections, current = [], None
    for raw in text.splitlines():
        line = raw.rstrip()
        m = re.match(r"##\s+(.+)", line)
        if m:
            current = {"title": plain(m.group(1)), "items": []}
            sections.append(current)
            continue
        if current is None:
            continue
        m = re.match(r"\s*[-*]\s+(.+)", line)
        if m and not raw.startswith((" ", "\t")):
            bold = re.match(r"\*\*(.+?)\*\*", m.group(1).strip())
            current["items"].append({"zh-Hans": plain(bold.group(1) if bold else m.group(1))})
            continue
        m = re.match(r"\s+\*(.+)\*\s*$", line)
        if m and current["items"] and "en" not in current["items"][-1]:
            current["items"][-1]["en"] = plain(m.group(1))
    highlights = [i for s in sections if s["title"] == "亮点" for i in s["items"]]
    return notes_valid({"highlights": highlights, "sections": [s for s in sections if s["title"] != "亮点"]})


PLATFORMS = ("mac", "windows")


def notice_messages(data, platform):
    """notice.json → 本平台的公告列表，最新的在前：[{id, level, text, url?}]。
    新版读 messages 数组（每条 id / level important|info / platforms / text / url，数组按最新在前排）；没有 messages 时把顶层那条（旧版也认）当一条全平台「重要」。
    platforms 不写 = 全平台；写了只给列着的平台（11-12：Mac 上不再看到 Windows 的公告）"""
    if not isinstance(data, dict) or data.get("schema") != 1:
        return []
    rows = data.get("messages") if isinstance(data.get("messages"), list) else None
    if rows is None:
        top = notice_valid(data)
        return [dict(top, level="important")] if top else []
    out = []
    for row in rows[:50]:
        item = notice_valid(dict(row, schema=1)) if isinstance(row, dict) else None
        platforms = row.get("platforms") if isinstance(row, dict) else None
        if item is None or (platforms is not None and (not isinstance(platforms, list) or platform not in platforms)):
            continue
        item["level"] = "important" if row.get("level") == "important" else "info"
        out.append(item)
    return out


def notice_data(remote=None, bundled=None):
    """先官方下载页，取不到用随包那份 → notice.json 原文 dict（没有就 {}）"""
    got, raw = (remote or notice_remote)()
    if got:
        return raw if isinstance(raw, dict) else {}
    try:
        return json.loads((bundled or notice_file()).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_json(path, data):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def seen_path(private_root):
    return Path(private_root) / "updates" / "seen.json"


def seen_state(private_root):
    try:
        data = json.loads(seen_path(private_root).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def installed_notes(private_root, version):
    try:
        return notes_valid(json.loads((Path(private_root) / "updates" / "notes" / f"{version}.json").read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return None


def inbox(platform, current, private_root, check=None, notices=None):
    """启动器打开时要给玩家看什么（两端共用，11-13 维护者定：永远只给最新一期，不叠加、不补弹）→
      popup：最多一个。「这版更新了什么」（刚换上新版、这版说明里有「亮点」、没关过）优先，其次「有新版」（这一版没提示过）；
             跳过的版本不补弹——只看当前版本和最新那一版。
      banner：本平台最新一条「重要」公告，玩家没看过才给；更旧的重要公告不再出横幅。
      messages：公告（最新在前）+ 更新说明（最新版 / 当前版），只在「消息」里列着；unread 只算最新那条公告没看过。
    「看过」按最新一条公告的号记（seen.json noticeSeen）：列表里排在它后面（更旧）的都算看过，跳过的几期自然不补。
    check：本次查版本的结果（latest()）；notices：本平台公告列表（notice_messages）。只读，不改 seen.json（玩家关掉时 inbox_seen 才记）"""
    seen = seen_state(private_root)
    check = check if isinstance(check, dict) else {"available": False}
    notices = notices or []
    seen_at = next((i for i, n in enumerate(notices) if n["id"] == seen.get("noticeSeen")), None)
    def is_seen(i):
        return seen_at is not None and i >= seen_at
    for i, n in enumerate(notices):
        n["unread"] = not is_seen(i) and i == 0
    popup = None
    # 这版的说明只在「从旧版里点更新、换上这一版」时记在本机（启动器开始下载新版时写 updates/notes/<版本>.json），有它就说明是刚更新上来的；手动装的新版没有，不弹
    mine = installed_notes(private_root, current)
    if mine and mine.get("highlights") and seen.get("afterShown") != current:
        popup = {"kind": "afterUpdate", "version": current, "notes": mine}
    elif check.get("available") and check.get("version") and seen.get("updatePrompted") != check["version"]:
        popup = {"kind": "update", "version": check["version"], "notes": check.get("notes")}
    important = next(((i, n) for i, n in enumerate(notices) if n.get("level") == "important"), None)
    banner = important[1] if important and not is_seen(important[0]) else None
    messages = [dict(n, kind="notice") for n in notices]
    if check.get("available") and check.get("version"):
        messages.append({"kind": "update", "version": check["version"], "notes": check.get("notes"), "installed": False})
    if mine:
        messages.append({"kind": "update", "version": current, "notes": mine, "installed": True})
    return {"popup": popup, "banner": banner, "messages": messages, "unread": sum(1 for n in notices if n["unread"]), "update": check}


def inbox_seen(private_root, update=None, after=None, notice=None):
    """玩家关掉了：update = 「有新版」那一版（以后再说）；after = 「这版更新了什么」那一版；notice = 看过的最新一条公告号（关横幅 / 打开消息）"""
    seen = seen_state(private_root)
    for key, value, pattern in (("updatePrompted", update, r"\d+\.\d+\.\d+"), ("afterShown", after, r"\d+\.\d+\.\d+"),
                                ("noticeSeen", notice, r"[A-Za-z0-9._-]{1,80}")):
        if value is not None:
            if not re.fullmatch(pattern, value):
                raise ValueError(f"{key} 不对")
            seen[key] = value
    save_json(seen_path(private_root), seen)
    return seen


def emit(**fields):
    print(json.dumps(fields, ensure_ascii=False), flush=True)


VERSION_DIR = re.compile(r"\d+(?:\.\d+)+")
# 旧自写换版（v0.3.9 及以前的 prepare / apply）在 updates/ 下留的东西：v0.3.10 起换版交给 Sparkle / NetSparkle，没人再读，启动时清掉
LEGACY = ("pending.json", "health.ok", "last_failure.json", "apply.log", ".update.lock", "runner")


def clear_stale_pending(private_root, current):
    """启动时清掉旧自写换版的残留（pending.json、health.ok、runner/、按版本号命名的整份新版……，可达几百 MB）；
    updates/notes/（换上新版后弹「这版更新了什么」用，启动器开始下载时写）和 seen.json 不动。返回是否清了东西"""
    updates = Path(private_root) / "updates"
    if not updates.is_dir():
        return False
    gone = False
    for item in list(updates.iterdir()):
        if item.name in LEGACY or (item.is_dir() and VERSION_DIR.fullmatch(item.name)):
            try:
                shutil.rmtree(item) if item.is_dir() and not item.is_symlink() else item.unlink()
                gone = True
            except OSError:
                pass
    return gone


def record_failure(args, code, message, detail=""):
    """失败原因写进诊断包会收的日志（core.logs_root：默认位置的 logs/，库没建好时私有目录/logs）：界面只有一句话，玩家反馈时靠这里定位"""
    root = getattr(args, "private_root", None)
    if not root:
        return
    try:
        # 与 core.logs_root 同一条规则（<私有目录>/logs）。不 import core：替换进程跑在 updates/runner/，那里只有 updater.py，
        #   原先 from core import logs_root 在换版时必然 ImportError、被下面吞掉——换版失败从没写进过 update.log（#828）
        log = Path(root).expanduser().resolve() / "logs" / "update.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a", encoding="utf-8") as out:
            out.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {code} {message}\n{str(detail or '').strip()[-2000:]}\n")
    except (OSError, ImportError):
        pass


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check")
    p.add_argument("--platform", required=True, choices=sorted(ASSETS))
    p.add_argument("--current", required=True)
    p = sub.add_parser("inbox"); p.add_argument("--private-root", required=True); p.add_argument("--platform", required=True, choices=sorted(ASSETS))
    p.add_argument("--current", required=True)
    p = sub.add_parser("inbox-seen"); p.add_argument("--private-root", required=True)
    p.add_argument("--update"); p.add_argument("--after"); p.add_argument("--notice")
    a = ap.parse_args(argv)
    # 打开时要看什么（inbox）：查版本、取公告都可能失败，失败不走下面的更新失败记录（不写 update.log），查不到就当没有新版、没有公告，界面照常
    if a.command == "inbox":
        try:
            clear_stale_pending(a.private_root, a.current)
        except OSError:
            pass
        try:
            check = latest(a.platform, a.current)
        except (UpdateError, OSError, ValueError, KeyError, __import__("http.client").client.HTTPException) as error:
            check = {"available": False, "error": getattr(error, "code", type(error).__name__)}
        print(json.dumps(inbox(a.platform, a.current, a.private_root, check, notice_messages(notice_data(), a.platform)), ensure_ascii=False))
        return 0
    if a.command == "inbox-seen":
        try:
            inbox_seen(a.private_root, a.update, a.after, a.notice)
        except (OSError, ValueError) as error:
            print(json.dumps({"error": str(error)}, ensure_ascii=False))
            return 1
        print(json.dumps({"ok": True}))
        return 0
    try:
        print(json.dumps(latest(a.platform, a.current), ensure_ascii=False))   # check
        return 0
    except UpdateError as error:
        record_failure(a, error.code, str(error), error.detail)
        emit(state="failed", code=error.code, message=str(error))
    except (OSError, ValueError, KeyError, ImportError, subprocess.SubprocessError, __import__("zipfile").BadZipFile, __import__("http.client").client.HTTPException) as error:
        record_failure(a, "update_failed", type(error).__name__, f"{error}\n{getattr(error, 'stderr', '') or ''}")
        emit(state="failed", code="update_failed", message=f"更新没有完成，旧版没有变化（{type(error).__name__}）。请检查网络后重试。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
