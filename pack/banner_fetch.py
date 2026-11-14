"""出包期横版封面抓取（照 GC 落地版 LCFetchedCover.swift 的已验链搬运；Tiao 定出包期抓、不走设备端懒抓）。

按程序号直达 ec.nintendo.com/apps/<程序号>/US → 跳转后的商品页 __NEXT_DATA__ 里
schema.org linkedData 的 image（图床 assets.nintendo.com）为首选、整页正则兜底 →
下载 → 门槛校验：host = assets.nintendo.com、宽 ≥ 1280、宽 > 高（三款实测均为 1920×1080 JPEG）。

纪律（红线）：抓图是锦上添花——任何失败只回 (False, 原因)，绝不抛、绝不让出包失败；
调用方（pack/ship_ext.py container 组装）记一行黄字、该款退回只有 icon 的现状。
只用标准库；图不是 JPEG 时仅当 Pillow 在场才转码（出包 Python 按 applenv 清单带 Pillow），不在场就放弃。
按程序号通用，不写死任何游戏名单 / 图 URL。

慢网络纪律（#101 评审）：单请求超时 8 秒（页/图各一跳）；同款在本轮组装内只试一次——
成败都记进进程内缓存，重试直接回缓存结论（负缓存；成功换落点时拷已抓到的文件）；
失败耗时累计达预算（缺省 25 秒，S2A_BANNER_FAIL_BUDGET 可调）后，后续款直接跳过不再联网，
保证国内连不上任天堂时整轮组装只多花有界的时间、款数越多也不会线性变慢。
响应读取有大小上限（页 8 MiB / 图 16 MiB，读超即弃）；重定向后的最终地址也要过域名校验
（商品页只许 nintendo.com 系、图只许 assets.nintendo.com），不只看第一跳。
"""
from __future__ import annotations

import json
import os
import re
import struct
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
MIN_WIDTH = 1280
_PAGE_TIMEOUT = 8
_IMG_TIMEOUT = 8
_PAGE_MAX = 8 << 20
_IMG_MAX = 16 << 20

_NEXT_DATA = re.compile(r'id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.S)
_FALLBACK = re.compile(r'"image"\s*:\s*"(https://assets\.nintendo\.com/image/upload/[^"]*/store/software/switch/[0-9]+/[^"]+)"')

# 本轮组装内的抓取账：程序号 → (成败, 说明, 成功时落盘路径, 定论)。失败条目即负缓存，同款不再联网重试。
#   定论 = 商店那边的事实（抓到了 / 商品页不存在 / 页上没有主图 / 图不合格），换个时候再查结果也一样；
#   断网、超时、服务器出错、落盘失败、本轮预算用尽都不是定论（settled 回假），调用方下次还要再查
_run_cache: dict = {}
_names: dict = {}   # 程序号 → 商品页英文标题（本进程抓到过的）
_fail_spent = 0.0   # 本轮累计花在失败抓取上的秒数（成功不计，见 _fail_budget）


def _fail_budget() -> float:
    try:
        return float(os.environ.get("S2A_BANNER_FAIL_BUDGET", "25"))
    except ValueError:
        return 25.0


def _host_ok(host, img: bool) -> bool:
    if not host:
        return False
    if img:
        return host == "assets.nintendo.com"
    return host == "nintendo.com" or host.endswith(".nintendo.com")


def _get(url: str, timeout: int, max_bytes: int, img: bool) -> bytes:
    """一跳 GET：重定向后的最终地址先过域名校验再读正文；正文读取带上限，超限即弃。"""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if r.status != 200:
            raise OSError(f"HTTP {r.status}")
        final = urlparse(r.geturl()).hostname
        if not _host_ok(final, img):
            raise OSError(f"重定向最终地址域名不对：{final}")
        data = r.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise OSError(f"响应超过 {max_bytes} 字节上限")
        return data


def _extract_image_url(html: str):
    """商品页主图 URL：linkedData 首选（与 GC 同判：条目 image 且 host 为 assets.nintendo.com），整页正则兜底。"""
    m = _NEXT_DATA.search(html)
    if m:
        try:
            root = json.loads(m.group(1))
            linked = root["props"]["pageProps"]["linkedData"]
            if isinstance(linked, dict):
                linked = [linked]
            for entry in linked:
                if isinstance(entry, dict):
                    img = entry.get("image")
                    if isinstance(img, str) and urlparse(img).hostname == "assets.nintendo.com":
                        return img
        except (ValueError, KeyError, TypeError):
            pass
    m = _FALLBACK.search(html)
    return m.group(1) if m else None


def _extract_title(html: str):
    """商品页的英文标题（美区页 linkedData 里 VideoGame 条目的 name）；没有 → 空串。顺带取，不另发请求（取名第二来源，见 store_name）"""
    m = _NEXT_DATA.search(html)
    if not m:
        return ""
    try:
        linked = json.loads(m.group(1))["props"]["pageProps"]["linkedData"]
    except (ValueError, KeyError, TypeError):
        return ""
    for entry in [linked] if isinstance(linked, dict) else (linked if isinstance(linked, list) else []):
        kind = entry.get("@type") if isinstance(entry, dict) else None
        if "VideoGame" in (kind if isinstance(kind, list) else [kind]) and isinstance(entry.get("name"), str):
            return entry["name"].strip()
    return ""


def store_name(title_id: str):
    """本轮抓横图时商品页上的英文标题（没抓过 / 页面没有 → 空串）。游戏库文件夹在 NACP 没有英文标题时用它取名（pack/jobs/library.note_store_names）"""
    return _names.get(title_id.strip().upper(), "")


def _jpeg_size(data: bytes):
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None
    sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    i = 2
    while i + 9 <= len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0xD9, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        seglen = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in sof:
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + seglen
    return None


def _webp_size(data: bytes):
    if len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return None
    chunk = data[12:16]
    if chunk == b"VP8X":
        w = int.from_bytes(data[24:27], "little") + 1
        h = int.from_bytes(data[27:30], "little") + 1
        return w, h
    if chunk == b"VP8 " and len(data) >= 30 and data[23:26] == b"\x9d\x01\x2a":
        w = struct.unpack("<H", data[26:28])[0] & 0x3FFF
        h = struct.unpack("<H", data[28:30])[0] & 0x3FFF
        return w, h
    if chunk == b"VP8L" and len(data) >= 25 and data[20] == 0x2F:
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return None


def _png_size(data: bytes):
    if len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        return struct.unpack(">II", data[16:24])
    return None


def _image_size(data: bytes):
    return _jpeg_size(data) or _webp_size(data) or _png_size(data)


def _fetch_banner_once(tid: str, dest: Path):
    """真正联网抓一次（缓存/预算在 fetch_banner 里管）：→ (True, "1920x1080 jpeg", True) / (False, 原因, 是否定论)。"""
    try:
        html = _get(f"https://ec.nintendo.com/apps/{tid}/US", _PAGE_TIMEOUT, _PAGE_MAX, img=False).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return False, f"商品页拉取失败：{e}", e.code in (404, 410)   # 商店没有这一款：定论；5xx / 限流不是
    except Exception as e:
        return False, f"商品页拉取失败：{e}", False
    title = _extract_title(html)
    if title:
        _names[tid] = title
    url = _extract_image_url(html)
    if not url:
        return False, "商品页没找到 assets.nintendo.com 主图", True
    try:
        data = _get(url, _IMG_TIMEOUT, _IMG_MAX, img=True)
    except Exception as e:
        return False, f"封面图下载失败：{e}", False
    size = _image_size(data)
    if not size:
        return False, "封面图格式不认（非 JPEG/WebP/PNG）或已损坏", True
    w, h = size
    if w < MIN_WIDTH or w <= h:
        return False, f"封面图不达门槛：{w}x{h}（要宽 ≥ {MIN_WIDTH} 且横版）", True
    if _jpeg_size(data) is None:
        try:
            import io
            from PIL import Image
            im = Image.open(io.BytesIO(data))
            buf = io.BytesIO()
            im.convert("RGB").save(buf, "JPEG", quality=90)
            data = buf.getvalue()
        except Exception as e:
            return False, f"封面图不是 JPEG 且转码不可用：{e}", False
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(data)
        tmp.replace(dest)
    except OSError as e:
        return False, f"封面图落盘失败：{e}", False
    return True, f"{w}x{h} jpeg {len(data)}B ← {url}", True


def fetch_banner(title_id: str, dest: Path):
    """按程序号抓一张横版封面写到 dest（JPEG）。→ (True, 说明) / (False, 原因)；失败不留半成品。

    本轮组装内同款只真正联网一次：命中缓存直接回上次结论（失败即负缓存，不重试）；
    失败耗时累计达预算后，未试过的款也直接跳过（原因注明预算用尽），不再逐款等超时。"""
    global _fail_spent
    tid = title_id.strip().upper()
    if not re.fullmatch(r"[0-9A-F]{16}", tid):
        return False, f"程序号格式不对：{title_id!r}"
    dest = Path(dest)
    hit = _run_cache.get(tid)
    if hit is not None:
        ok, why, src, _final = hit
        if ok and src is not None and src != dest and src.is_file():
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp = dest.with_suffix(dest.suffix + ".tmp")
                tmp.write_bytes(src.read_bytes())
                tmp.replace(dest)
            except OSError:
                pass   # 拷不过去也无妨：结论仍是抓到过，调用方按没落位处理
        return ok, why
    if _fail_spent >= _fail_budget():
        why = "本轮取图失败耗时已达上限，跳过（负缓存）"
        _run_cache[tid] = (False, why, None, False)
        return False, why
    t0 = time.monotonic()
    ok, why, final = _fetch_banner_once(tid, dest)
    if not ok:
        _fail_spent += time.monotonic() - t0
    _run_cache[tid] = (ok, why, dest if ok else None, final)
    return ok, why


def settled(title_id: str) -> bool:
    """本轮抓过这款、且结论是商店那边的事实（见 _run_cache 注释）：调用方据此记「查过」；断网 / 超时 / 预算用尽回假，下次再查"""
    hit = _run_cache.get(title_id.strip().upper())
    return bool(hit and hit[3])
