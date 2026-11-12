#!/usr/bin/env python3
"""S2Arm 启动器的覆盖更新（Mac / Windows 共用，只用标准库）。

check    查 GitHub 最新 Release，打印一行 JSON。
prepare  验清单签名后后台下载官方包、核对清单里的校验值、解开并校验到数据目录下的 updates/，逐行打印进度。不碰正在用的安装目录。
         有 from 当前版本的差分包就先试差分（按文件替换，整棵目录核对清单），任何一步失败退回整包。
notice   启动器顶部公告条：取官方下载页上的 notice.json（取不到用随包那份），玩家关掉过的同一条不再给；打印一行 JSON（没有要显示的打 {}）。
notice-dismiss  记下玩家关掉的公告号（数据目录下 notice_dismissed.txt）。
apply    启动器退出后，由 prepare 备好的独立 Python 运行：原地替换安装目录、重启；新版起不来就回滚到旧版。

玩家的数据（游戏库、密钥、存档备份、任务记录、缓存）都在安装目录之外；prepare 先核实这一点，
被保护的目录落在安装目录里就拒绝更新。任何一步失败，旧版都原样不动。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
import types
import time
from pathlib import Path

# apply 跑在 updates/runner 那份只含标准库的 Python 上，Mac 上它没有 ssl 依赖的动态库：
# 只有 check / prepare 才用到的模块在这里按需导入，apply 走不到。

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
HEALTH_SECONDS = 90
EXIT_SECONDS = 120
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


def offer(platform, version, mine, files, url_of):
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
        info = offer(platform, version, mine, manifest["files"], lambda name: template.format(version=v, name=name))
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
    files = signed_manifest(assets, version)["files"]
    return offer(platform, version, mine, files, lambda name: assets[name]["browser_download_url"] if name in assets else None)


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
    """官方下载页上的 notice.json → (取到了没有, 内容)。取到但内容无效 / 已撤 = (True, None)：照撤，不退回随包那份"""
    import urllib.request
    url = os.environ.get("S2A_NOTICE_URL") or NOTICE_URL
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "S2Arm-Launcher", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=timeout, context=tls_context() if url.startswith("https:") else None) as response:
            body = response.read(64 << 10)
    except (OSError, ValueError, __import__("http.client").client.HTTPException, subprocess.SubprocessError):
        return False, None
    try:
        return True, notice_valid(json.loads(body))
    except ValueError:
        return False, None   # 拿到的不是 JSON（门户页、被劫持的网络）：当没取到


def notice(private_root, remote=None, bundled=None):
    """→ 要显示的公告或 None：先官方下载页，取不到用随包那份；玩家关掉过的同一条（id 一样）不给"""
    # 调用时才取 notice_remote（不写成默认参数）：默认参数在定义时就绑死，测试 patch updater.notice_remote 换不掉，单测会真联网取官方页
    got, item = (remote or notice_remote)()
    if not got:
        try:
            item = notice_valid(json.loads((bundled or notice_file()).read_text(encoding="utf-8")))
        except (OSError, ValueError):
            item = None
    if item is None:
        return None
    try:
        if (Path(private_root) / "notice_dismissed.txt").read_text(encoding="utf-8").strip() == item["id"]:
            return None
    except OSError:
        pass
    return item


def notice_dismiss(private_root, ident):
    """玩家点了 ×：记下这条的号（只记最近一条；换了新号的公告照常出现）"""
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", ident or ""):
        raise ValueError("公告号不对")
    root = Path(private_root); root.mkdir(parents=True, exist_ok=True)
    tmp = root / "notice_dismissed.txt.tmp"
    tmp.write_text(ident + "\n", encoding="utf-8")
    tmp.replace(root / "notice_dismissed.txt")


def inside(child, parent):
    child, parent = Path(child).resolve(), Path(parent).resolve()
    return child == parent or parent in child.parents


def emit(**fields):
    print(json.dumps(fields, ensure_ascii=False), flush=True)


def check_paths(install, protect):
    for path in protect:
        if path and inside(path, install):
            raise UpdateError("update_data_inside_install", "游戏库或数据目录放在了 S2Arm 安装目录里，更新会影响它们，已停止。请先把它们移出安装目录。")
    parent = Path(install).resolve().parent
    try:
        with tempfile.TemporaryDirectory(prefix=".s2arm-update-", dir=parent):
            pass
    except OSError:
        raise UpdateError("update_no_permission", "没有权限替换 S2Arm 所在的文件夹。请把 S2Arm 放到可写的位置，或手动下载新版。") from None


def require_free(path, need):
    if shutil.disk_usage(path).free < need:
        raise UpdateError("update_disk_full", "磁盘空间不够下载和解开新版，已停止，旧版没有变化。")


def require_unpack_space(updates, install, unpacked, package_size):
    """解开前按解开后的确切大小要空间（剃刀 H17：原先下载前就要「更新目录 4 倍包大小、安装盘 3 倍」，盘紧的玩家被拒）。
    解开要 unpacked（包还在、已占着）；替换时 swap 把解开的那份拷到安装目录旁（再 unpacked），这时包已删。
    两处在同一块盘上：峰值 = max(unpacked, 2 × unpacked − 包大小)；不同盘：各要 unpacked"""
    parent = Path(install).resolve().parent
    if os.stat(updates).st_dev == os.stat(parent).st_dev:
        require_free(updates, max(unpacked, 2 * unpacked - package_size))
    else:
        require_free(updates, unpacked)
        require_free(parent, unpacked)


def sha256(path):
    import hashlib
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while block := handle.read(CHUNK):
            digest.update(block)
    return digest.hexdigest()


DOWNLOAD_ATTEMPTS = 6   # 连续这么多次一点进展都没有才放弃；有进展就重新计数
RETRY_SECONDS = 2
PRIMARY_ATTEMPTS = 2   # 有退路时首选来源只试这么多次没进展就换退路（R2 整个不通时不让玩家干等几分钟）


def download(url, target, size, attempts=None):
    """断了接着下（Range），服务器不支持续传就从头来；下够清单写的长度才算完"""
    import http.client
    part = Path(str(target) + ".part")
    # 上次（含上一个进程）没下完的 .part 接着下：长度超过清单的不是这份文件，扔掉重下；内容不对由下完后的 SHA-256 兜住
    done, stalled = (part.stat().st_size if part.is_file() else 0), 0
    if done > size:
        part.unlink()
        done = 0
    while done < size:
        before, failure = done, None
        try:
            with open_url(url, 30, start=done) as response:
                if done and response.status != 206:
                    done = 0
                with open(part, "ab" if done else "wb") as out:
                    while block := response.read(CHUNK):
                        done += len(block)
                        if done > size:   # 比签名清单写的大：不是官方文件，也防把磁盘写满
                            raise UpdateError("update_checksum_mismatch", "下载的文件比官方清单大，已停止，旧版没有变化。")
                        out.write(block)
                        emit(state="downloading", done=done, total=size)
        except (OSError, http.client.HTTPException) as error:
            failure = error
            done = part.stat().st_size if part.exists() else 0
        if done >= size:
            break
        import urllib.error
        if isinstance(failure, urllib.error.HTTPError) and failure.code != 416:   # 安装包地址本身出错（404 / 5xx / 限流）：重试也没用
            raise network_error(failure, "下载新版") from failure
        stalled = 0 if done > before else stalled + 1
        if stalled >= (attempts or DOWNLOAD_ATTEMPTS):
            why = network_error(failure, "下载新版").detail if failure else "连接提前结束"
            raise UpdateError("update_download_failed", "下载一直断开，已停止，当前版本没有变化。请检查网络后重试，或打开下载页手动下载。", why)
        time.sleep(RETRY_SECONDS * stalled)
    # 已下完且文件句柄已关闭；Windows 扫描器可能仍短暂占用它，只重试落盘，不重新下载。
    retry_rename(part, target, replace=True)


def fetch_package(info, package, size):
    """下整包并按签名清单核 sha256。先下 info["asset"]；下不下来（连不上、非 200、比清单大、一直断开）且有 assetFallback（官网清单命中时 = GitHub）
    就扔掉半截、从退路重下。下够了 sha256 不对 = 内容被改：直接报错，不退回（换个来源不该让被改的文件变成能用）"""
    try:
        download(info["asset"], package, size, attempts=PRIMARY_ATTEMPTS if info.get("assetFallback") else None)
    except UpdateError as error:
        if not info.get("assetFallback"):
            raise
        emit(state="downloadFallback", reason=error.code)
        Path(str(package) + ".part").unlink(missing_ok=True)
        download(info["assetFallback"], package, size)
    emit(state="verifying")
    if sha256(package) != info["sha256"]:
        package.unlink()
        raise UpdateError("update_checksum_mismatch", "下载的安装包校验不符，已删除，旧版没有变化。请稍后重试。")


def extract_windows(package, dest, before_unpack=None):
    import zipfile
    with zipfile.ZipFile(package) as archive:
        root = dest.resolve()
        for name in archive.namelist():
            if not inside(root / name, root):
                raise UpdateError("update_bad_package", "安装包内容不正常，已停止，旧版没有变化。")
        if before_unpack:
            before_unpack(sum(i.file_size for i in archive.infolist()))   # 解开后的确切大小：ZIP 目录里记着
        archive.extractall(dest)
    found = next((p.parent for p in sorted(dest.rglob("S2Arm.exe"), key=lambda p: len(p.parts))), None)
    if not found or not (found / "Engine").is_dir() or not (found / "Runtime/python/python.exe").is_file():
        raise UpdateError("update_bad_package", "安装包不完整，已停止，旧版没有变化。")
    return found


def extract_mac(package, dest, before_unpack=None):
    # 挂载点放系统临时目录：放在数据目录下时，数据目录在外置盘上 hdiutil 会报 Permission denied
    mount = Path(tempfile.mkdtemp(prefix="s2arm-update-mount-"))
    attached = subprocess.run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(package)], capture_output=True, timeout=300)
    if attached.returncode:
        os.rmdir(mount)
        raise UpdateError("update_unpack_failed", "打不开下载好的安装包，旧版没有变化。可以手动下载新版。", detail=attached.stderr.decode("utf-8", "replace"))
    try:
        app = mount / "S2Arm.app"
        if not app.is_dir():
            raise UpdateError("update_bad_package", "安装包不完整，已停止，旧版没有变化。")
        target = dest / "S2Arm.app"
        if before_unpack:
            before_unpack(tree_size(app))   # 解开后的确切大小：挂载后量 App 本身
        subprocess.run(["/usr/bin/ditto", str(app), str(target)], check=True, capture_output=True, timeout=1800)
    finally:
        subprocess.run(["/usr/bin/hdiutil", "detach", "-force", str(mount)], capture_output=True, timeout=120)
        with __import__("contextlib").suppress(OSError):
            os.rmdir(mount)
    check = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)], capture_output=True, timeout=600)
    if check.returncode:
        raise UpdateError("update_bad_package", "安装包的签名校验没通过，已停止，旧版没有变化。", detail=check.stderr.decode("utf-8", "replace"))
    return target


def file_manifest(root):
    """整棵目录的清单：相对路径 → {sha256, x} 或 {link}。Mac 的 App 里有符号链接，只记不跟。"""
    root, out = Path(root), {}
    for folder, dirs, files in os.walk(root):
        for name in sorted(files) + [d for d in dirs if (Path(folder) / d).is_symlink()]:
            path = Path(folder) / name
            if name == ".DS_Store":
                continue
            rel = path.relative_to(root).as_posix()
            out[rel] = {"link": os.readlink(path)} if path.is_symlink() else {"sha256": sha256(path), "x": os.name != "nt" and os.access(path, os.X_OK)}
    return out


def build_delta(old, new, platform, source, target, out):
    """发版工具用：old → new 只打包变了的文件，附完整目标清单。返回差分包路径。"""
    import zipfile
    base, wanted = file_manifest(old), file_manifest(new)
    delta = Path(out) / DELTAS[platform].format(source)
    with zipfile.ZipFile(delta, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr("delta.json", json.dumps({"schema": 1, "platform": platform, "from": source, "to": target, "target": wanted}))
        for rel, entry in wanted.items():
            if "sha256" in entry and base.get(rel) != entry:
                archive.write(Path(new) / rel, "files/" + rel)
    return delta


def check_target(target):
    """差分清单里的路径和符号链接都不能走出 App 目录。"""
    root = "/app"
    for rel, entry in target.items():
        parts = rel.split("/")
        escaped = rel.startswith("/") or "\\" in rel or ":" in rel or ".." in parts
        if "link" in entry:
            link = entry["link"]
            parent = os.path.dirname(os.path.join(root, rel))
            escaped = escaped or link.startswith("/") or "\\" in link or not os.path.normpath(os.path.join(parent, link)).startswith(root + "/")
        if escaped:
            raise UpdateError("update_bad_package", "差分包内容不正常。")


def apply_delta(package, platform, current, version, install, dest):
    """在 install 的副本上打差分，整棵核对目标清单；Mac 再核签名。不碰 install。任何不符都抛错，由调用方退回整包。"""
    import zipfile
    with zipfile.ZipFile(package) as archive:
        manifest = json.loads(archive.read("delta.json"))
        if manifest.get("schema") != 1 or manifest.get("platform") != platform or manifest.get("from") != current or manifest.get("to") != version:
            raise UpdateError("update_bad_package", "差分包和当前版本对不上。")
        target = manifest["target"]
        check_target(target)
        staged = dest / Path(install).name
        shutil.copytree(install, staged, symlinks=True)
        root = staged.resolve()
        for member in archive.namelist():
            if not member.startswith("files/") or member.endswith("/"):
                continue
            rel = member[len("files/"):]
            path = root / rel
            if rel not in target or not inside(path, root):
                raise UpdateError("update_bad_package", "差分包内容不正常。")
            if path.is_symlink() or path.is_file():
                path.unlink()
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, open(path, "wb") as out:
                shutil.copyfileobj(source, out)
    have = file_manifest(staged)
    for rel in set(have) - set(target):
        (staged / rel).unlink()
    for rel, entry in target.items():
        path = staged / rel
        if "link" in entry and have.get(rel) != entry:
            if path.is_symlink() or path.exists():
                path.unlink()
            path.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(entry["link"], path)
        elif entry.get("x") and os.name != "nt":
            path.chmod(path.stat().st_mode | 0o111)
    if file_manifest(staged) != target:
        raise UpdateError("update_bad_package", "打完差分后文件和清单对不上。")
    if platform == "mac":
        check = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)], capture_output=True, timeout=600)
        if check.returncode:
            raise UpdateError("update_bad_package", "打完差分后签名校验没通过。")
    return staged


def stage_delta(info, platform, current, install, work):
    emit(state="downloading", done=0, total=info["deltaSize"])
    package = work / info["deltaName"]
    require_free(work, tree_size(install) + info["deltaSize"] * 2)
    download(info["delta"], package, info["deltaSize"])
    emit(state="verifying")
    if sha256(package) != info["deltaSha256"]:
        raise UpdateError("update_checksum_mismatch", "差分包校验不符。")
    emit(state="unpacking")
    unpack = work / "delta"
    unpack.mkdir()
    staged = apply_delta(package, platform, current, info["version"], install, unpack)
    package.unlink()
    return staged


def tree_size(root):
    return sum(p.stat().st_size for p in Path(root).rglob("*") if p.is_file() and not p.is_symlink())


def runner_python(platform, staged, runner):
    """apply 要在替换安装目录时运行，不能用目录里的 Python：拷一份只含标准库的到 updates/runner。"""
    if runner.exists():
        shutil.rmtree(runner)
    source = staged / ("Contents/Resources/Runtime/python" if platform == "mac" else "Runtime/python")
    shutil.copytree(source, runner / "python", symlinks=True, ignore=shutil.ignore_patterns("site-packages", "__pycache__", "*.pyc"))
    shutil.copy2(__file__, runner / "updater.py")
    return runner / "python" / ("bin/python3" if platform == "mac" else "python.exe")


def prepare(platform, current, private, install, protect):
    updates = Path(private) / "updates"
    updates.mkdir(parents=True, exist_ok=True)
    check_paths(install, protect)
    info = latest(platform, current, fresh=True)
    if not info["available"]:
        raise UpdateError("update_none", "已经是最新版本。")
    work = updates / info["version"]
    if work.exists():
        # 同一版本重试：只留整包没下完的 .part 接着下（download 续传），其余（解包、增量）清掉重来
        keep = work / (info["assetName"] + ".part")
        for item in list(work.iterdir()):
            if item != keep:
                remove_tree(item) if item.is_dir() and not item.is_symlink() else item.unlink()
    work.mkdir(exist_ok=True)
    staged = None
    if info.get("delta"):
        try:
            staged = stage_delta(info, platform, current, install, work)
            via = "delta"
        except (UpdateError, OSError, ValueError, KeyError, shutil.Error, subprocess.SubprocessError, __import__("zipfile").BadZipFile) as error:
            emit(state="deltaFailed", reason=type(error).__name__)
            shutil.rmtree(work / "delta", ignore_errors=True)
            (work / info["deltaName"]).unlink(missing_ok=True)
    if staged is None:
        via = "full"
        size = info["size"]
        require_free(updates, size)   # 先只要下载这一份；解开要多少在解开前按确切大小核（require_unpack_space）
        package = work / info["assetName"]
        emit(state="downloading", done=0, total=size)
        fetch_package(info, package, size)
        emit(state="unpacking")
        unpack = work / "unpack"
        unpack.mkdir()
        room = lambda unpacked: require_unpack_space(updates, install, unpacked, size)
        staged = extract_mac(package, unpack, room) if platform == "mac" else extract_windows(package, unpack, room)
        package.unlink()
    runner = updates / "runner"
    python = runner_python(platform, staged, runner)
    # 替换进程起不来的话，App 退出后什么都不会发生：先确认它能跑，不能跑就停在这里
    check = subprocess.run([str(python), "-B", "-I", str(runner / "updater.py"), "selfcheck"], capture_output=True, timeout=120)
    if check.returncode:
        raise UpdateError("update_bad_package", "更新程序在这台电脑上起不来，已停止，旧版没有变化。")
    (updates / "pending.json").write_text(json.dumps({"version": info["version"], "time": time.time()}))
    emit(state="ready", via=via, version=info["version"], staged=str(staged), python=str(python), updater=str(runner / "updater.py"))


def pid_alive(pid):
    if os.name == "nt":
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x00100000, False, int(pid))   # SYNCHRONIZE
        if not handle:
            return False
        try:
            kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
            return kernel.WaitForSingleObject(handle, 0) == 0x102   # WAIT_TIMEOUT：还在跑
        finally:
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            kernel.CloseHandle(handle)
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def remove_tree(path):
    """Windows 上只读文件（Engine 的 .git 对象）会让 rmtree 半途而废，每次更新留下一整份旧版。"""
    def writable(function, target, _):
        try:
            os.chmod(target, 0o700)
            function(target)
        except OSError:
            pass
    shutil.rmtree(path, onerror=writable)


def retry_rename(source, target, seconds=30, *, replace=False):
    """Windows 上杀毒软件和索引服务会短暂占住文件 / 目录：重试几十秒再放弃。"""
    deadline = time.monotonic() + seconds
    while True:
        try:
            (os.replace if replace else os.rename)(source, target)
            return
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)


def move_dir(source, target):
    """整目录 source → target。先限时重试整目录改名；仍被拒（#379：下载工具 / 资源管理器持有安装目录本身的句柄，目录里的文件却能改名）
    且 target 不存在或是空目录 → 逐项把 source 里的东西搬进 target（玩家现场用 robocopy 覆盖验证过同一做法）。逐项中途失败就把已搬的搬回去再抛，
    不留下一半在新、一半在旧。source 搬空后删不掉（句柄还在）就留着空目录"""
    try:
        retry_rename(source, target)
        return
    except OSError:
        if target.exists() and (not target.is_dir() or any(target.iterdir())):
            raise
    target.mkdir(exist_ok=True)
    moved = []
    try:
        for p in sorted(source.iterdir()):
            retry_rename(p, target / p.name)
            moved.append(p.name)
    except OSError:
        for name in reversed(moved):
            retry_rename(target / name, source / name)
        raise
    try:
        source.rmdir()
    except OSError:
        pass


def holds_copy(path):
    """这里真有一份安装：目录在且不空。move_dir 逐项搬空后删不掉的空目录（句柄还在）不算——把它当成「还有一份旧版」，
    恢复时会把刚搬回安装目录的那份当坏的换掉删掉（审计 P1-157）"""
    try:
        return path.is_dir() and any(path.iterdir())
    except OSError:
        return False


VERSION_DIR = re.compile(r"\d+(?:\.\d+)+")


def drop_version_dirs(updates):
    """新版确认起来以后：删掉 updates/ 下各版本的工作目录（解开的新版 unpack/、增量 delta/、下载的包）。
    swap 是从 unpack 拷进安装目录的（copytree），拷完源一直留着，每次更新在系统盘多占一整份（#660）；早先版本留下的也一起清。
    只删按版本号命名的目录：runner/（正在跑的就是它）、pending.json / health.ok / last_failure.json 不动。删不掉（被占用）就留到下次"""
    for d in updates.iterdir():
        if d.is_dir() and not d.is_symlink() and VERSION_DIR.fullmatch(d.name):
            try:
                remove_tree(d)
            except OSError:
                pass


def swap(staged, install, backup, new):
    """staged → install；失败时安装目录保持或恢复旧版，异常往外抛。"""
    if new.exists():
        shutil.rmtree(new)
    shutil.copytree(staged, new, symlinks=True)
    move_dir(install, backup)
    try:
        move_dir(new, install)
    except OSError:
        move_dir(backup, install)
        raise


def default_launch(install, args):
    if sys.platform == "darwin":
        subprocess.run(["/usr/bin/open", "-n", str(install), "--args", *args], check=True, timeout=60)
    else:
        subprocess.Popen([str(install / "S2Arm.exe"), *args], cwd=install, creationflags=0x00000008 | 0x00000200, close_fds=True)


def apply(staged, install, pid, private, args=(), launch=default_launch, health_seconds=HEALTH_SECONDS, exit_seconds=EXIT_SECONDS):
    """返回 0 = 换上新版并确认起来了；1 = 已留在 / 回到旧版，原因写进 updates/last_failure.json。"""
    install, staged = Path(install), Path(staged)
    updates = Path(private) / "updates"
    backup, new = install.with_name(install.name + ".s2arm-old"), install.with_name(install.name + ".s2arm-new")

    def fail(code, message, restart=True):
        (updates / "last_failure.json").write_text(json.dumps({"code": code, "message": message, "time": time.time()}, ensure_ascii=False), encoding="utf-8")   # 不写 encoding 时 Windows 按系统代码页（中文机 GBK）写，两端启动器按 UTF-8 读
        # 同时记进 update.log（诊断包会收）：last_failure.json 启动器下次启动读完就删，原先换版失败事后什么记录都没有（#379）
        record_failure(types.SimpleNamespace(private_root=str(private)), code, message, traceback.format_exc() if sys.exc_info()[0] else "")
        (updates / "pending.json").unlink(missing_ok=True)
        if restart:
            try:
                launch(install, list(args))
            except (OSError, subprocess.SubprocessError):
                pass
        return 1

    deadline = time.monotonic() + exit_seconds
    while pid_alive(pid):
        if time.monotonic() >= deadline:
            return fail("update_app_busy", "S2Arm 没有退出，这次没有更新。", restart=False)
        time.sleep(0.5)
    health = updates / "health.ok"
    try:
        # A previous apply may have stopped between swap()'s two renames.
        # Restore the only old copy before treating any backup as disposable.
        if holds_copy(backup) and not holds_copy(install):
            move_dir(backup, install)
        if holds_copy(backup):
            if health.exists():
                # 上次换上的版本后来起来过（写了 health.ok）：它已被确认，副本可以删
                remove_tree(backup)
            else:
                # 上次换上的版本没被确认就中断了：副本才是最后一份确认能用的，先装回去再换，回滚目标始终是它
                bad = install.with_name(install.name + ".s2arm-bad")
                remove_tree(bad) if bad.exists() else None
                move_dir(install, bad)
                move_dir(backup, install)
                remove_tree(bad)
        # 换目录之前清掉确认标记：此后出现的 health.ok 只能来自换上去的这一版
        health.unlink(missing_ok=True)
        swap(staged, install, backup, new)
    except (OSError, shutil.Error):
        remove_tree(new) if new.exists() else None
        if not holds_copy(install):   # 失败句和盘上一致：安装目录里读不到旧版就不说「已保留」（审计 P1-157）
            return fail("update_rollback_failed", "替换安装目录失败，旧版也没能恢复。请重新下载 S2Arm。", restart=False)
        return fail("update_swap_failed", "替换安装目录失败，已保留旧版。")
    try:
        launch(install, list(args))
        deadline = time.monotonic() + health_seconds
        while not health.exists() and time.monotonic() < deadline:
            time.sleep(0.5)
    except (OSError, subprocess.SubprocessError):
        pass
    if health.exists():
        remove_tree(backup)
        (updates / "pending.json").unlink(missing_ok=True)
        drop_version_dirs(updates)
        return 0
    # 新版没能启动：装回旧版
    try:
        if install.exists():
            move_dir(install, install.with_name(install.name + ".s2arm-bad"))
        move_dir(backup, install)
        remove_tree(install.with_name(install.name + ".s2arm-bad"))
    except OSError:
        return fail("update_rollback_failed", "新版没能启动，旧版也没能恢复。请重新下载 S2Arm。", restart=False)
    if not holds_copy(install):
        return fail("update_rollback_failed", "新版没能启动，旧版也没能恢复。请重新下载 S2Arm。", restart=False)
    return fail("update_rolled_back", "新版没能启动，已回到旧版。")


def record_failure(args, code, message, detail=""):
    """失败原因写进诊断包会收的日志（core.logs_root：默认位置的 logs/，库没建好时私有目录/logs）：界面只有一句话，玩家反馈时靠这里定位"""
    root = getattr(args, "private_root", None)
    if not root:
        return
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from core import logs_root
        log = logs_root(root) / "update.log"
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
    for name in ("check", "prepare"):
        p = sub.add_parser(name)
        p.add_argument("--platform", required=True, choices=sorted(ASSETS))
        p.add_argument("--current", required=True)
        if name == "prepare":
            p.add_argument("--private-root", required=True)
            p.add_argument("--install", required=True)
            p.add_argument("--protect", action="append", default=[])
    sub.add_parser("selfcheck")
    p = sub.add_parser("notice"); p.add_argument("--private-root", required=True)
    p = sub.add_parser("notice-dismiss"); p.add_argument("--private-root", required=True); p.add_argument("--id", required=True)
    p = sub.add_parser("apply")
    p.add_argument("--staged", required=True); p.add_argument("--install", required=True); p.add_argument("--pid", required=True, type=int)
    p.add_argument("--private-root", required=True); p.add_argument("--arg", action="append", default=[])
    a = ap.parse_args(argv)
    # 公告与更新无关：失败不走下面的更新失败记录（不写 update.log、不报「更新没有完成」）。取不到、读不了都不报错，打 {}，界面什么都不显示
    if a.command == "notice":
        print(json.dumps(notice(a.private_root) or {}, ensure_ascii=False))
        return 0
    if a.command == "notice-dismiss":
        try:
            notice_dismiss(a.private_root, a.id)
        except (OSError, ValueError) as error:
            print(json.dumps({"error": str(error)}, ensure_ascii=False))
            return 1
        print(json.dumps({"dismissed": a.id}))
        return 0
    try:
        if a.command == "selfcheck":
            return 0
        if a.command == "check":
            print(json.dumps(latest(a.platform, a.current), ensure_ascii=False))
        elif a.command == "prepare":
            prepare(a.platform, a.current, a.private_root, a.install, a.protect + [a.private_root])
        else:
            return apply(a.staged, a.install, a.pid, a.private_root, a.arg)
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
