#!/usr/bin/env python3
"""pack/banner_fetch.py 单测：全程打桩 urlopen，绝不真联网（#101 评审 1/2 项）。

覆盖：JPEG/PNG/WebP 三种手写头解析（期望值按格式手算）；商品页主图提取（linkedData 首选/正则兜底/外域拒绝）；
取数纪律——重定向最终地址域名校验、响应大小上限、短超时、同款负缓存（失败本轮不重试）、
失败耗时预算（用尽后未试款直接跳过）；落盘只在全部门槛过后发生、失败不留文件。
"""
import json
import os
import struct
import sys
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from pack import banner_fetch  # noqa: E402

TID = "0100000000010000"
IMG_URL = "https://assets.nintendo.com/image/upload/v1/store/software/switch/70010000000001/keyart.jpg"
PAGE_URL = f"https://ec.nintendo.com/apps/{TID}/US"


def jpeg(w, h):
    """最小 JPEG：SOI + APP0 + SOF0（尺寸按 SOF 段偏移手算：高在段数据 +5、宽 +7）。"""
    return (b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 16) + bytes(14)
            + b"\xff\xc0" + struct.pack(">H", 17) + b"\x08" + struct.pack(">HH", h, w) + b"\x03" + bytes(9))


def png(w, h):
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", w, h) + bytes(9)


def webp_x(w, h):
    return b"RIFF" + struct.pack("<I", 22) + b"WEBP" + b"VP8X" + struct.pack("<I", 10) + bytes(4) \
        + (w - 1).to_bytes(3, "little") + (h - 1).to_bytes(3, "little")


def webp_l(w, h):
    bits = (w - 1) | ((h - 1) << 14)
    return b"RIFF" + struct.pack("<I", 26) + b"WEBP" + b"VP8L" + struct.pack("<I", 18) + b"\x2f" + bits.to_bytes(4, "little") + bytes(9)


def webp_lossy(w, h):
    return b"RIFF" + struct.pack("<I", 22) + b"WEBP" + b"VP8 " + struct.pack("<I", 14) + bytes(3) \
        + b"\x9d\x01\x2a" + struct.pack("<HH", w, h)


def page_html(img):
    linked = {"props": {"pageProps": {"linkedData": {"@type": "Product", "image": img}}}}
    return ('<html><head></head><body><script id="__NEXT_DATA__" type="application/json">'
            + json.dumps(linked) + "</script></body></html>").encode()


class Resp:
    """urlopen 的打桩响应：status / geturl（重定向后的最终地址）/ read（带长度参数）。"""
    def __init__(self, body=b"", url="", status=200):
        self._body, self._url, self.status = body, url, status

    def geturl(self):
        return self._url

    def read(self, n=-1):
        return self._body if n is None or n < 0 else self._body[:n]

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class SizeParseTest(unittest.TestCase):
    def test_jpeg(self):
        self.assertEqual(banner_fetch._image_size(jpeg(1920, 1080)), (1920, 1080))
        self.assertEqual(banner_fetch._jpeg_size(jpeg(640, 480)), (640, 480))

    def test_png(self):
        self.assertEqual(banner_fetch._image_size(png(1280, 720)), (1280, 720))

    def test_webp_variants(self):
        self.assertEqual(banner_fetch._image_size(webp_x(1920, 1080)), (1920, 1080))
        self.assertEqual(banner_fetch._image_size(webp_l(1600, 900)), (1600, 900))
        self.assertEqual(banner_fetch._image_size(webp_lossy(1332, 750)), (1332, 750))

    def test_garbage_and_truncated(self):
        self.assertIsNone(banner_fetch._image_size(b""))
        self.assertIsNone(banner_fetch._image_size(b"\xff\xd8"))          # 只有 SOI
        self.assertIsNone(banner_fetch._image_size(b"RIFF\x00\x00\x00\x00WEBP"))  # 头不全
        self.assertIsNone(banner_fetch._image_size(bytes(range(256))))


class ExtractUrlTest(unittest.TestCase):
    def test_linked_data_dict_and_list(self):
        self.assertEqual(banner_fetch._extract_image_url(page_html(IMG_URL).decode()), IMG_URL)
        linked = {"props": {"pageProps": {"linkedData": [{"@type": "WebPage"}, {"image": IMG_URL}]}}}
        html = '<script id="__NEXT_DATA__" type="application/json">' + json.dumps(linked) + "</script>"
        self.assertEqual(banner_fetch._extract_image_url(html), IMG_URL)

    def test_foreign_host_falls_back_to_regex(self):
        html = page_html("https://evil.example.com/x.jpg").decode() + f'<script>{{"image": "{IMG_URL}"}}</script>'
        self.assertEqual(banner_fetch._extract_image_url(html), IMG_URL)

    def test_no_image(self):
        self.assertIsNone(banner_fetch._extract_image_url("<html>什么都没有</html>"))
        self.assertIsNone(banner_fetch._extract_image_url(page_html("https://evil.example.com/x.jpg").decode()))


class GetTest(unittest.TestCase):
    def open_with(self, resp):
        return mock.patch.object(urllib.request, "urlopen", return_value=resp)

    def test_ok_and_final_host_checked(self):
        with self.open_with(Resp(b"abc", url="https://www.nintendo.com/us/store/products/x")):
            self.assertEqual(banner_fetch._get(PAGE_URL, 8, 1024, img=False), b"abc")
        with self.open_with(Resp(b"abc", url="https://evil.example.com/x.jpg")):
            with self.assertRaises(OSError):   # 商品页重定向出 nintendo.com 系 → 拒
                banner_fetch._get(PAGE_URL, 8, 1024, img=False)
        with self.open_with(Resp(b"abc", url="https://cdn.example.net/x.jpg")):
            with self.assertRaises(OSError):   # 图只许 assets.nintendo.com 本尊
                banner_fetch._get(IMG_URL, 8, 1024, img=True)

    def test_size_cap(self):
        with self.open_with(Resp(b"x" * 2048, url=IMG_URL)):
            with self.assertRaises(OSError):
                banner_fetch._get(IMG_URL, 8, 1024, img=True)

    def test_status(self):
        with self.open_with(Resp(b"", url=PAGE_URL, status=500)):
            with self.assertRaises(OSError):
                banner_fetch._get(PAGE_URL, 8, 1024, img=False)


class FetchFlowTest(unittest.TestCase):
    def setUp(self):
        banner_fetch._run_cache.clear()
        banner_fetch._fail_spent = 0.0
        import tempfile
        self.td = tempfile.TemporaryDirectory()
        self.dest = Path(self.td.name) / "banner.jpg"

    def tearDown(self):
        self.td.cleanup()
        banner_fetch._run_cache.clear()
        banner_fetch._fail_spent = 0.0

    def dispatcher(self, page_resp=None, img_resp=None, calls=None):
        def fake(req, timeout=None):
            if calls is not None:
                calls.append(req.full_url)
            if req.full_url.startswith("https://ec.nintendo.com/"):
                if isinstance(page_resp, Exception):
                    raise page_resp
                return page_resp
            if isinstance(img_resp, Exception):
                raise img_resp
            return img_resp
        return fake

    def test_store_title_taken_from_same_page(self):
        # 商品页 linkedData 的 VideoGame 条目带 name（美区英文标题）：抓横图那一次顺带记下，store_name 取得到；不另发请求
        linked = {"props": {"pageProps": {"linkedData": [{"@type": ["VideoGame", "Product"], "name": "Hollow Knight: Silksong", "image": IMG_URL},
                                                         {"@type": "BreadcrumbList"}]}}}
        page = Resp(('<script id="__NEXT_DATA__" type="application/json">' + json.dumps(linked) + "</script>").encode(),
                    url="https://www.nintendo.com/us/store/products/x")
        calls = []
        banner_fetch._names.clear()
        with mock.patch.object(urllib.request, "urlopen", self.dispatcher(page, Resp(jpeg(1920, 1080), url=IMG_URL), calls)):
            ok, why = banner_fetch.fetch_banner(TID, self.dest)
        self.assertTrue(ok, why)
        self.assertEqual(banner_fetch.store_name(TID), "Hollow Knight: Silksong")
        self.assertEqual(len(calls), 2)   # 页一次、图一次
        self.assertEqual(banner_fetch.store_name("0100000000099000"), "")   # 没抓过的款
        self.assertEqual(banner_fetch._extract_title(page_html(IMG_URL).decode()), "")   # 只有 Product、没有 VideoGame 名字 → 空

    def test_success_then_cache_hit_copies(self):
        page = Resp(page_html(IMG_URL), url="https://www.nintendo.com/us/store/products/x")
        img = Resp(jpeg(1920, 1080), url=IMG_URL)
        with mock.patch.object(urllib.request, "urlopen", self.dispatcher(page, img)):
            ok, why = banner_fetch.fetch_banner(TID, self.dest)
        self.assertTrue(ok, why)
        self.assertEqual(self.dest.read_bytes(), jpeg(1920, 1080))
        dest2 = Path(self.td.name) / "sub" / "banner.jpg"
        with mock.patch.object(urllib.request, "urlopen", side_effect=AssertionError("不许再联网")):
            ok2, _ = banner_fetch.fetch_banner(TID, dest2)   # 命中缓存：零联网、换落点拷过去
        self.assertTrue(ok2)
        self.assertEqual(dest2.read_bytes(), jpeg(1920, 1080))

    def test_failure_negative_cache(self):
        calls = []
        with mock.patch.object(urllib.request, "urlopen", self.dispatcher(urllib.error.URLError("连不上"), None, calls)):
            ok1, _ = banner_fetch.fetch_banner(TID, self.dest)
            ok2, why2 = banner_fetch.fetch_banner(TID, self.dest)
        self.assertFalse(ok1)
        self.assertFalse(ok2)
        self.assertEqual(len(calls), 1)   # 第二次直接回缓存，不再重试
        self.assertFalse(self.dest.exists())

    def test_settled_only_for_store_facts(self):
        # 定论（换个时候再查也一样）才算查过：抓到、商品页 404、页上没主图、图不合格；断网 / 5xx / 图下载断 / 预算用尽都不是
        def http(code):
            return urllib.error.HTTPError("https://ec.nintendo.com/apps/x/US", code, "x", {}, None)
        page = lambda: Resp(page_html(IMG_URL), url="https://www.nintendo.com/x")
        cases = (("抓到", page(), Resp(jpeg(1920, 1080), url=IMG_URL), True),
                 ("商品页 404", http(404), None, True),
                 ("页上没主图", Resp(b"<html></html>", url="https://www.nintendo.com/x"), None, True),
                 ("图宽不够", page(), Resp(jpeg(800, 600), url=IMG_URL), True),
                 ("断网", urllib.error.URLError("连不上"), None, False),
                 ("商店 503", http(503), None, False),
                 ("图下载断", page(), urllib.error.URLError("断了"), False))
        for note, pr, ir, want in cases:
            banner_fetch._run_cache.clear(); banner_fetch._fail_spent = 0.0
            with mock.patch.object(urllib.request, "urlopen", self.dispatcher(pr, ir)):
                banner_fetch.fetch_banner(TID, self.dest)
            self.assertEqual(banner_fetch.settled(TID), want, note)
        banner_fetch._run_cache.clear(); banner_fetch._fail_spent = 10_000.0
        banner_fetch.fetch_banner(TID, self.dest)
        self.assertFalse(banner_fetch.settled(TID), "预算用尽")
        banner_fetch._run_cache.clear(); banner_fetch._fail_spent = 0.0
        self.assertFalse(banner_fetch.settled(TID), "没抓过")

    def test_fail_budget_skips_without_network(self):
        banner_fetch._fail_spent = 10_000.0   # 预算已用尽
        with mock.patch.object(urllib.request, "urlopen", side_effect=AssertionError("不许联网")):
            ok, why = banner_fetch.fetch_banner(TID, self.dest)
        self.assertFalse(ok)
        self.assertIn("上限", why)

    def test_thresholds(self):
        for data, note in ((jpeg(800, 600), "宽不够"), (jpeg(1080, 1920), "竖版")):
            banner_fetch._run_cache.clear()
            page = Resp(page_html(IMG_URL), url="https://www.nintendo.com/x")
            with mock.patch.object(urllib.request, "urlopen", self.dispatcher(page, Resp(data, url=IMG_URL))):
                ok, why = banner_fetch.fetch_banner(TID, self.dest)
            self.assertFalse(ok, note)
            self.assertIn("门槛", why)
            self.assertFalse(self.dest.exists())

    def test_image_redirect_to_foreign_host_refused(self):
        page = Resp(page_html(IMG_URL), url="https://www.nintendo.com/x")
        img = Resp(jpeg(1920, 1080), url="https://evil.example.com/x.jpg")   # 内容再对，最终域名不对也拒
        with mock.patch.object(urllib.request, "urlopen", self.dispatcher(page, img)):
            ok, why = banner_fetch.fetch_banner(TID, self.dest)
        self.assertFalse(ok)
        self.assertIn("域名", why)
        self.assertFalse(self.dest.exists())

    def test_bad_title_id_no_network(self):
        with mock.patch.object(urllib.request, "urlopen", side_effect=AssertionError("不许联网")):
            ok, _ = banner_fetch.fetch_banner("XYZ", self.dest)
        self.assertFalse(ok)

    def test_non_jpeg_without_pillow_fails_clean(self):
        page = Resp(page_html(IMG_URL), url="https://www.nintendo.com/x")
        img = Resp(png(1920, 1080), url=IMG_URL)
        with mock.patch.dict(sys.modules, {"PIL": None}):   # import PIL 必炸 = 转码不可用
            with mock.patch.object(urllib.request, "urlopen", self.dispatcher(page, img)):
                ok, why = banner_fetch.fetch_banner(TID, self.dest)
        self.assertFalse(ok)
        self.assertIn("转码", why)
        self.assertFalse(self.dest.exists())

    def test_timeouts_are_short(self):
        self.assertLessEqual(banner_fetch._PAGE_TIMEOUT, 10)
        self.assertLessEqual(banner_fetch._IMG_TIMEOUT, 10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
