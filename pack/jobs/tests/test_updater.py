import hashlib
import io
import http.server
import json
import os
import shutil
import sys
import subprocess
import tempfile
import unittest.mock
import types
import threading
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ed25519  # noqa: E402
import updater  # noqa: E402

TEST_SECRET = bytes(range(32))


def signed(version, files, secret=TEST_SECRET):
    raw = json.dumps({"schema": 1, "version": version, "files": files}).encode()
    return raw, ed25519.sign(secret, raw)


def tree(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.install = self.root / "apps/S2Arm"
        (self.install / "Engine").mkdir(parents=True)
        (self.install / "S2Arm.exe").write_text("old")
        self.private = self.root / "data"
        for name, body in (("DefaultLibrary/games/a/cover.jpg", "game"), ("keys/prod.keys", "k"), ("saves/backup.zip", "save"), ("jobs/t.json", "{}"), ("cache/x", "c")):
            path = self.private / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        (self.private / "updates").mkdir()
        self.staged = self.root / "staged"
        (self.staged / "Engine").mkdir(parents=True)
        (self.staged / "S2Arm.exe").write_text("new")
        # 查版本缓存放进本用例的临时目录、缺省不用（各用例会改发布内容）；测缓存的用例自己打开
        for name, value in (("latest_cache", lambda platform, current: self.root / "latest-cache.json"), ("LATEST_TTL", 0)):
            p = patch.object(updater, name, value); p.start(); self.addCleanup(p.stop)

    def data(self):   # 玩家数据：更新自己的记录（updates/、换版失败记进的 logs/update.log）不算
        return {k: v for k, v in tree(self.private).items() if not k.startswith(("updates", "logs"))}




class Handler(http.server.BaseHTTPRequestHandler):
    routes = {}
    hits = []

    def do_GET(self):
        self.hits.append(self.path)
        body = self.routes.get(self.path)
        self.send_response(200 if body is not None else 404); self.end_headers()
        self.wfile.write(body or b"")

    def log_message(self, *a):
        pass








class ScriptedHandler(http.server.BaseHTTPRequestHandler):
    """每个路径按脚本逐次回应：(状态码, 头, 正文) 或 "sleep"（不回，等客户端超时）"""
    scripts = {}
    hits = []

    def do_GET(self):
        type(self).hits.append(self.path)
        queue = type(self).scripts.get(self.path) or []
        step = queue.pop(0) if len(queue) > 1 else (queue[0] if queue else (404, {}, b""))
        if step == "sleep":
            time.sleep(3)
            return
        status, headers, body = step
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class NetworkErrorTests(Base):
    """查版本 / 取清单 / 下安装包遇到国内常见的网络情况时报什么码（界面按码显示原因 + 打开下载页）。期望码按 network_error 的规则手写"""
    def setUp(self):
        super().setUp()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ScriptedHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        ScriptedHandler.scripts, ScriptedHandler.hits = {}, []
        for name, value in (("trusted", lambda url: True), ("emit", lambda **k: None), ("FETCH_RETRY_SECONDS", 0)):
            p = patch.object(updater, name, value); p.start(); self.addCleanup(p.stop)

    def check(self, api):
        emitted = []
        with patch.dict(os.environ, {"S2A_UPDATE_API": api}), patch("builtins.print") as out, patch.object(updater, "emit", lambda **k: emitted.append(k)):
            code = updater.main(["check", "--platform", "windows", "--current", "0.1.1"])
        return code, (emitted[-1] if emitted else json.loads(out.call_args.args[0]))

    def test_rate_limit_has_its_own_code_and_is_not_retried(self):
        reset = str(int(time.time()) + 600)
        ScriptedHandler.scripts["/latest"] = [(403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset}, b'{"message":"API rate limit exceeded"}')]
        code, out = self.check(self.base + "/latest")
        self.assertEqual((code, out["state"], out["code"]), (1, "failed", "update_rate_limited"))
        self.assertIn("约 10 分钟", out["message"])
        self.assertEqual(ScriptedHandler.hits, ["/latest"])   # 限流不重试

    def test_transient_server_error_is_retried(self):
        ScriptedHandler.scripts["/latest"] = [(503, {}, b""), (200, {}, json.dumps({"tag_name": "v0.0.1", "assets": []}).encode())]
        code, out = self.check(self.base + "/latest")
        self.assertEqual((code, out), (0, {"available": False}))
        self.assertEqual(ScriptedHandler.hits, ["/latest", "/latest"])

    def test_offline_reports_network_after_retries(self):
        import socket
        with socket.socket() as s:   # 拿一个没人听的端口：连接被拒 = 断网 / 被墙
            s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
        calls = []
        real = updater.open_url
        with patch.object(updater, "open_url", lambda *a, **k: (calls.append(1), real(*a, **k))[1]):
            code, out = self.check(f"http://127.0.0.1:{port}/latest")
        self.assertEqual((code, out["code"]), (1, "update_network"))
        self.assertEqual(len(calls), updater.FETCH_ATTEMPTS)

    def test_timeout_reports_network(self):
        ScriptedHandler.scripts["/slow"] = ["sleep"]
        with self.assertRaises(updater.UpdateError) as caught:
            updater.fetch(self.base + "/slow", 0.5, 1024)
        self.assertEqual(caught.exception.code, "update_network")
        self.assertIn("超时", str(caught.exception))













class Ed25519Tests(unittest.TestCase):
    """RFC 8032 第 7.1 节的测试向量，期望值来自 RFC，不依赖被测实现。"""
    def test_rfc_vectors(self):
        for secret, public, message, signature in (
            ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
             "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
            ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
             "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")):
            sk, pk, msg, sig = map(bytes.fromhex, (secret, public, message, signature))
            self.assertEqual(ed25519.public_key(sk), pk)
            self.assertEqual(ed25519.sign(sk, msg), sig)
            self.assertTrue(ed25519.verify(pk, msg, sig))

    def test_tampering_is_rejected(self):
        pk = ed25519.public_key(TEST_SECRET); sig = ed25519.sign(TEST_SECRET, b"manifest")
        self.assertFalse(ed25519.verify(pk, b"manifesT", sig))
        self.assertFalse(ed25519.verify(pk, b"manifest", sig[:-1] + bytes([sig[-1] ^ 1])))
        self.assertFalse(ed25519.verify(pk, b"manifest", sig[:32] + (int.from_bytes(sig[32:], "little") + ed25519.L).to_bytes(32, "little")))   # 不规范的 S
        self.assertFalse(ed25519.verify(pk, b"manifest", sig[:10]))


class VersionTests(Base):
    def release(self, tag):
        names = (updater.ASSETS["mac"], updater.MANIFEST, updater.SIGNATURE)
        version = tag[1:] if tag.count(".") == 2 and "-" not in tag else "0.0.0"
        raw, signature = signed(version, {updater.ASSETS["mac"]: {"sha256": "0" * 64, "size": 1}})
        release = {"tag_name": tag, "assets": [{"name": n, "size": 1, "browser_download_url": "https://github.com/" + n} for n in names]}
        answers = {updater.API: json.dumps(release).encode(), "https://github.com/" + updater.MANIFEST: raw, "https://github.com/" + updater.SIGNATURE: signature}

        class Response(__import__("io").BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                pass
        def answer(url, timeout):
            if url not in answers:
                raise OSError("offline")   # 官网（updater.MIRROR）连不上：这组测的是回退到 GitHub 后的版本比较
            return Response(answers[url])
        return patch.object(updater, "open_url", side_effect=answer)

    def test_only_a_strictly_higher_numeric_version_is_offered(self):
        key = ed25519.public_key(TEST_SECRET).hex()
        for tag, current, available in (("v0.1.2", "0.1.1", True), ("v0.10.0", "0.9.9", True), ("v0.1.1", "0.1.1", False), ("v0.1.0", "0.1.1", False), ("v0.2.0-beta", "0.1.1", False), ("v0.2.0", "", False)):
            with self.subTest(tag=tag, current=current), self.release(tag), patch.object(updater, "PUBLIC_KEY", key), patch.dict(os.environ, {"S2A_UPDATE_API": ""}):
                self.assertEqual(updater.latest("mac", current)["available"], available)

    def test_official_build_ignores_the_test_key(self):
        with patch.dict(os.environ, {"S2A_UPDATE_API": "", "S2A_UPDATE_PUBKEY": "00" * 32}):
            self.assertEqual(updater.public_key().hex(), updater.PUBLIC_KEY)

    def test_official_build_refuses_other_hosts(self):
        with patch.dict(os.environ, {"S2A_UPDATE_API": ""}):
            self.assertFalse(updater.trusted("https://evil.example/x"))
            self.assertFalse(updater.trusted("http://github.com/x"))
            self.assertTrue(updater.trusted("https://github.com/x"))


class NoticeTests(unittest.TestCase):
    """公告条（v0.2.3 起；11-13 加 messages / platforms）：官方下载页优先、取不到用随包那份、已撤不显示、链接只认官方 https。期望手写"""
    ITEM = {"schema": 1, "id": "n1", "text": {"zh-Hans": "中文公告", "en": "English notice"}, "url": "https://github.com/jhaizhou-ops/S2Arm#readme"}

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.bundled = self.root / "notice.json"; self.bundled.write_text(json.dumps(dict(self.ITEM, id="bundled")), encoding="utf-8")

    def ids(self, remote, platform="mac"):
        return [n["id"] for n in updater.notice_messages(updater.notice_data(remote=lambda: remote, bundled=self.bundled), platform)]

    def test_remote_first_then_bundled(self):
        self.assertEqual(self.ids((True, self.ITEM)), ["n1"])
        self.assertEqual(self.ids((False, None)), ["bundled"])   # 没网 / 页面不通

    def test_retracted_remote_wins_over_bundled(self):   # 页面取到了、但已撤（只剩 schema）：不显示，不退回随包那份
        self.assertEqual(self.ids((True, {"schema": 1})), [])

    def test_legacy_top_level_is_one_important_message(self):
        [n] = updater.notice_messages(self.ITEM, "windows")
        self.assertEqual((n["id"], n["level"], n["url"]), ("n1", "important", self.ITEM["url"]))

    def test_messages_filtered_by_platform_newest_first(self):
        data = {"schema": 1, "id": "old", "text": self.ITEM["text"], "messages": [
            {"id": "w2", "level": "important", "platforms": ["windows"], "text": self.ITEM["text"]},
            {"id": "a1", "level": "info", "text": self.ITEM["text"]},
            {"id": "m0", "platforms": ["mac"], "text": self.ITEM["text"]},
            {"id": "bad", "platforms": "mac", "text": self.ITEM["text"]}]}
        self.assertEqual([(n["id"], n["level"]) for n in updater.notice_messages(data, "mac")], [("a1", "info"), ("m0", "info")])
        self.assertEqual([n["id"] for n in updater.notice_messages(data, "windows")], ["w2", "a1"])   # 有 messages 就不再看顶层那条（给旧版看的）

    def test_invalid_shapes_are_not_shown(self):
        for bad in ({"schema": 2, "id": "a", "text": self.ITEM["text"]}, {"schema": 1, "text": self.ITEM["text"]},
                    {"schema": 1, "id": "a b", "text": self.ITEM["text"]}, {"schema": 1, "id": "a", "text": {"zh-Hans": "只有中文"}},
                    {"schema": 1, "id": "a", "text": {"zh-Hans": " ", "en": "x"}}, [], "x"):
            with self.subTest(bad=bad):
                self.assertIsNone(updater.notice_valid(bad))
                self.assertEqual(updater.notice_messages(bad, "mac"), [])

    def test_link_only_official_https(self):
        for url, kept in (("https://github.com/jhaizhou-ops/S2Arm", True), ("https://jhaizhou-ops.github.io/S2Arm/", True),
                          ("http://github.com/x", False), ("https://s2arm.com/", True), ("https://evil.s2arm.com.example/", False), ("http://s2arm.com/", False), ("javascript:alert(1)", False)):
            with self.subTest(url=url):
                self.assertEqual("url" in updater.notice_valid(dict(self.ITEM, url=url)), kept)

    def test_shipped_notice_is_valid(self):   # 仓库里那份（Pages 发布 + 随包兜底）：有公告就要能显示、带官方链接；撤了就必须是说明里写的撤法
        data = json.loads(updater.notice_file().read_text(encoding="utf-8"))
        self.assertEqual(data.get("schema"), 1)
        if "id" not in data and "messages" not in data:   # 11-12 撤公告后改成 {"schema": 1}（docs/site/README.md「撤掉公告」）：没有公告是合法状态
            self.assertEqual(data, {"schema": 1})
            return
        for platform in updater.PLATFORMS:
            for n in updater.notice_messages(data, platform):
                self.assertIn("url", n)


class NotesTests(unittest.TestCase):
    """发版说明 → 清单 notes（tools/sign_update_manifest.py --notes）。期望按发版说明的写法手写"""
    MD = """# S2Arm v9.9.9

开头一段不进清单。

## 亮点
- **第一条亮点。**（#1）
  *First highlight. (#1)*
- 没加粗的亮点

## 修了哪些问题
- **修复：A 不再失败。** 后面是细节，`代码`也去掉。
  *Fixed: A no longer fails.*
- **B 修了。**
"""

    def test_sections_highlights_and_english(self):
        notes = updater.notes_from_markdown(self.MD)
        self.assertEqual(notes["highlights"], [{"zh-Hans": "第一条亮点。", "en": "First highlight. (#1)"}, {"zh-Hans": "没加粗的亮点"}])
        self.assertEqual(notes["sections"], [{"title": "修了哪些问题", "items": [{"zh-Hans": "修复：A 不再失败。", "en": "Fixed: A no longer fails."}, {"zh-Hans": "B 修了。"}]}])

    def test_no_highlight_section_means_no_highlights(self):   # 程序不替人挑亮点：没写「## 亮点」就没有（更新后不弹「这版更新了什么」）
        notes = updater.notes_from_markdown("## 其它改进\n- **C。**\n")
        self.assertEqual((notes["highlights"], len(notes["sections"])), ([], 1))
        self.assertIsNone(updater.notes_from_markdown("# 只有标题\n"))

    def test_offer_passes_signed_notes_through(self):   # 清单里的 notes 随「有新版」一起给启动器；坏的丢掉、照常给新版
        files = {updater.ASSETS["mac"]: {"sha256": "0" * 64, "size": 1}}
        notes = {"highlights": [{"zh-Hans": "亮点"}], "sections": []}
        self.assertEqual(updater.offer("mac", (0, 3, 5), (0, 3, 3), files, lambda n: "https://x/" + n, notes)["notes"], notes)
        info = updater.offer("mac", (0, 3, 5), (0, 3, 3), files, lambda n: "https://x/" + n, {"sections": 1})
        self.assertEqual((info["available"], "notes" in info), (True, False))

    def test_invalid_notes_dropped(self):
        for bad in (None, [], {"sections": "x"}, {"highlights": [{"en": "only en"}]}, {"sections": [{"title": "", "items": [{"zh-Hans": "a"}]}]}):
            with self.subTest(bad=bad):
                self.assertIsNone(updater.notes_valid(bad))


class InboxTests(unittest.TestCase):
    """打开启动器时给玩家看什么（11-13 维护者定：永远只给最新一期，不叠加、不补弹；看过关掉的不再弹）。期望按规则手写，不跑被测实现推"""
    TEXT = {"zh-Hans": "公告", "en": "Notice"}
    NOTES = {"highlights": [{"zh-Hans": "亮点"}], "sections": [{"title": "修好了", "items": [{"zh-Hans": "一条"}]}]}

    def setUp(self):
        self.private = Path(tempfile.mkdtemp())

    def notices(self, *ids, level="important"):   # 最新在前
        return updater.notice_messages({"schema": 1, "messages": [{"id": i, "level": level, "text": self.TEXT} for i in ids]}, "mac")

    def open(self, current, check=None, notices=()):
        return updater.inbox("mac", current, self.private, check or {"available": False}, list(notices))

    def test_three_notices_and_skipped_versions_show_only_latest_once(self):
        # 玩家停在 0.3.3，其间发了 0.3.4、0.3.5 两版和 n1、n2、n3 三期重要公告：一进来只弹最新版 0.3.5、横幅只有 n3、未读 1
        check = {"available": True, "version": "0.3.5", "notes": self.NOTES}
        first = self.open("0.3.3", check, self.notices("n3", "n2", "n1"))
        self.assertEqual((first["popup"]["kind"], first["popup"]["version"]), ("update", "0.3.5"))
        self.assertEqual(first["banner"]["id"], "n3")
        self.assertEqual(first["unread"], 1)
        self.assertEqual([m.get("id") or m.get("version") for m in first["messages"]], ["n3", "n2", "n1", "0.3.5"])   # 旧的都在消息里，不弹
        self.assertEqual([m["unread"] for m in first["messages"] if m["kind"] == "notice"], [True, False, False])
        # 关掉弹窗（以后再说）、关掉横幅：再进来什么都不弹，n2 / n1 不补
        updater.inbox_seen(self.private, update="0.3.5", notice="n3")
        again = self.open("0.3.3", check, self.notices("n3", "n2", "n1"))
        self.assertEqual((again["popup"], again["banner"], again["unread"]), (None, None, 0))

    def test_after_update_popup_once_then_newer_update_next_open(self):
        # 从 0.3.3 点更新换上 0.3.5（prepare 记了 0.3.5 的说明），此时已有 0.3.6：先只弹「这版更新了什么」，关掉后下次才弹 0.3.6，再关掉就都不弹
        updater.save_json(self.private / "updates/notes/0.3.4.json", self.NOTES)   # 跳过的那版：不补弹
        updater.save_json(self.private / "updates/notes/0.3.5.json", self.NOTES)
        check = {"available": True, "version": "0.3.6"}
        r = self.open("0.3.5", check)
        self.assertEqual((r["popup"]["kind"], r["popup"]["version"]), ("afterUpdate", "0.3.5"))
        self.assertEqual(self.open("0.3.5", check)["popup"]["kind"], "afterUpdate")   # 没关（直接退出）下次还在
        updater.inbox_seen(self.private, after="0.3.5")
        r = self.open("0.3.5", check)
        self.assertEqual((r["popup"]["kind"], r["popup"]["version"]), ("update", "0.3.6"))
        updater.inbox_seen(self.private, update="0.3.6")
        self.assertIsNone(self.open("0.3.5", check)["popup"])

    def test_after_update_needs_highlights_and_our_own_update(self):
        self.assertIsNone(self.open("0.3.5")["popup"])   # 手动装的新版：本机没有这版说明，不弹
        updater.save_json(self.private / "updates/notes/0.3.5.json", {"sections": self.NOTES["sections"]})
        r = self.open("0.3.5")
        self.assertIsNone(r["popup"])   # 说明里没写亮点：不弹，说明只在消息里
        self.assertEqual([m["version"] for m in r["messages"] if m["kind"] == "update"], ["0.3.5"])

    def test_new_notice_after_seen_and_info_level_never_banners(self):
        updater.inbox_seen(self.private, notice="n3")
        r = self.open("0.3.3", notices=self.notices("n4", "n3", "n2"))
        self.assertEqual((r["banner"]["id"], r["unread"]), ("n4", 1))
        r = self.open("0.3.3", notices=self.notices("i5", level="info") + self.notices("n4", "n3"))
        self.assertEqual((r["banner"]["id"], r["unread"]), ("n4", 1))   # 最新是普通公告：只算未读、不出横幅；横幅仍是没看过的最新重要那条
        updater.inbox_seen(self.private, notice="i5")   # 打开消息 = 看过最新那条，更旧的都算看过
        r = self.open("0.3.3", notices=self.notices("i5", level="info") + self.notices("n4", "n3"))
        self.assertEqual((r["banner"], r["unread"]), (None, 0))

    def test_seen_rejects_bad_values_and_inbox_does_not_write(self):
        for kw in ({"update": "x"}, {"after": "../1.0.0"}, {"notice": "a b"}):
            with self.subTest(kw=kw), self.assertRaises(ValueError):
                updater.inbox_seen(self.private, **kw)
        self.open("0.3.3", {"available": True, "version": "0.3.5"}, self.notices("n1"))
        self.assertFalse((self.private / "updates/seen.json").exists())   # 只读：关掉时才记

    def test_cli_offline_prints_nothing_to_show(self):
        import io, contextlib
        with patch.object(updater, "latest", side_effect=OSError("offline")), patch.object(updater, "notice_remote", return_value=(False, None)), \
                patch.object(updater, "notice_file", return_value=self.private / "none.json"):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(updater.main(["inbox", "--private-root", str(self.private), "--platform", "mac", "--current", "0.3.3"]), 0)
        r = json.loads(out.getvalue())
        self.assertEqual((r["popup"], r["banner"], r["messages"], r["update"]["available"]), (None, None, [], False))
        self.assertFalse((self.private / "logs").exists())   # 查不到不写 update.log
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(updater.main(["inbox-seen", "--private-root", str(self.private), "--notice", "n1"]), 0)
        self.assertEqual(updater.seen_state(self.private), {"noticeSeen": "n1"})


class FeatureTests(unittest.TestCase):
    """新功能大窗（docs/site/feature.json）：本机没看过这一期就弹一次（新装、更新上来都算），排在更新弹窗前面；版本不够 / 撤回 / 不给本平台不弹。期望按规则手写"""
    T = {"zh-Hans": "中", "en": "En"}

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.private = self.root / "private"
        (self.root / "site/feature").mkdir(parents=True)
        (self.root / "site/feature/a.jpg").write_bytes(b"jpg")
        self.write()

    def write(self, **over):
        page = {"image": "feature/a.jpg", **{k: self.T for k in updater.FEATURE_TEXTS}}
        data = {"schema": 1, "id": "v0.4.0-x", "minVersion": "0.4.0", "platforms": ["mac", "windows"], "pages": [page, dict(page, image="feature/none.jpg")]}
        data.update(over)
        (self.root / "site/feature.json").write_text(json.dumps(data), encoding="utf-8")

    def spot(self, current="0.4.0", platform="mac", withdrawn=()):
        return updater.feature_spotlight(platform, current, self.root / "site/feature.json", withdrawn)

    def test_pages_need_both_languages_and_an_existing_image(self):
        f = self.spot()
        self.assertEqual((f["kind"], f["id"], len(f["pages"])), ("feature", "v0.4.0-x", 1))   # 第二页图不在：丢掉
        a = str((self.root / "site/feature/a.jpg").resolve())
        self.assertEqual(f["pages"][0]["image"], {"zh-Hans": a, "en": a})   # 只写一个路径：两种语言同图
        self.assertEqual(f["pages"][0]["layout"], "detail")
        self.write(pages=[{"image": "feature/a.jpg", **{k: {"zh-Hans": "中"} for k in updater.FEATURE_TEXTS}}])
        self.assertIsNone(self.spot())   # 缺英文：这页不要，一页不剩不弹
        self.write(pages=[{"image": "feature/a.jpg", "title": self.T}])
        self.assertIsNone(self.spot())   # 说明页只写了一部分文字：不要（不当海报页）
        self.write(pages=[{"image": "feature/a.jpg"}, {"image": "feature/a.jpg", **{k: self.T for k in updater.FEATURE_TEXTS}}])
        self.assertEqual([p["layout"] for p in self.spot()["pages"]], ["poster", "detail"])   # 只有图 = 海报页
        self.write(pages=[{"image": "../private/x.jpg", **{k: self.T for k in updater.FEATURE_TEXTS}}])
        self.assertIsNone(self.spot())   # 图只认 docs/site 里面的

    def test_image_follows_ui_language(self):
        (self.root / "site/feature/a_en.jpg").write_bytes(b"jpg")
        page = {**{k: self.T for k in updater.FEATURE_TEXTS}}
        self.write(pages=[dict(page, image={"zh-Hans": "feature/a.jpg", "en": "feature/a_en.jpg"}),
                          dict(page, image={"zh-Hans": "feature/a.jpg", "en": "feature/none.jpg"}),
                          dict(page, image={"en": "feature/a_en.jpg"})])
        site = (self.root / "site/feature").resolve()
        imgs = [p["image"] for p in self.spot()["pages"]]
        self.assertEqual(imgs, [{"zh-Hans": str(site / "a.jpg"), "en": str(site / "a_en.jpg")},
                                {"zh-Hans": str(site / "a.jpg"), "en": str(site / "a.jpg")}])   # 英文图不在：用中文；没有中文图：这页不要

    def test_version_platform_and_withdraw(self):
        self.assertIsNone(self.spot("0.3.10"))                     # 功能还没进这一版：热修不带大窗
        self.assertIsNotNone(self.spot("0.4.0-dev+abc1234"))        # 开发版按前三段比
        self.assertIsNotNone(self.spot("0.10.0"))                   # 按数字比，不按字面
        self.assertIsNone(self.spot(platform="iphone"))
        self.assertIsNone(self.spot(withdrawn=["v0.4.0-x"]))

    def test_shows_once_before_update_popups(self):
        f = self.spot()
        updater.save_json(self.private / "updates/notes/0.4.0.json", {"highlights": [{"zh-Hans": "亮点"}], "sections": []})
        check = {"available": True, "version": "0.4.1"}
        r = updater.inbox("mac", "0.4.0", self.private, check, [], f)
        self.assertEqual((r["popup"]["kind"], r["popup"]["id"]), ("feature", "v0.4.0-x"))   # 新功能先弹，这版说明下次
        updater.inbox_seen(self.private, feature="v0.4.0-x")
        self.assertEqual(updater.inbox("mac", "0.4.0", self.private, check, [], f)["popup"]["kind"], "afterUpdate")
        with self.assertRaises(ValueError):
            updater.inbox_seen(self.private, feature="../x")

    def test_site_dir_finds_mac_app_engine_snapshot(self):
        # Mac App：作业在 Contents/Resources/Jobs，随包 docs/site 在旁边的 Resources/Engine 里；Windows：Engine/pack/jobs 往上两级
        mac = self.root / "S2Arm.app/Contents/Resources"
        (mac / "Jobs").mkdir(parents=True); (mac / "Engine/docs/site").mkdir(parents=True)
        self.assertEqual(updater.site_dir(mac / "Jobs"), mac / "Engine/docs/site")
        win = self.root / "win/Engine"
        (win / "pack/jobs").mkdir(parents=True); (win / "docs/site").mkdir(parents=True)
        self.assertEqual(updater.site_dir(win / "pack/jobs"), win / "docs/site")

    def test_fresh_install_without_seen_file_shows_it(self):
        self.assertFalse((self.private / "updates/seen.json").exists())
        self.assertEqual(updater.inbox("windows", "0.4.0", self.private, None, [], self.spot(platform="windows"))["popup"]["kind"], "feature")


class MirrorTests(Base):
    """查版本先走官网静态清单（updater.MIRROR）、失败回退 GitHub API。期望按规则手写：
    官网验签通过 → 以它为准（新就给、不新就没有），一次都不问 GitHub；官网超时 / 404 / 验签不过 → 问 GitHub；两边都不行 → 报 GitHub 那边的错误码"""
    def setUp(self):
        super().setUp()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ScriptedHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        ScriptedHandler.scripts, ScriptedHandler.hits = {}, []
        for name, value in (("trusted", lambda url: True), ("FETCH_RETRY_SECONDS", 0), ("MIRROR_TIMEOUT", 1)):
            p = patch.object(updater, name, value); p.start(); self.addCleanup(p.stop)
        p = patch.dict(os.environ, {"S2A_UPDATE_API": self.base + "/latest", "S2A_UPDATE_MIRROR": self.base + "/update/latest.json",
                                    "S2A_UPDATE_DOWNLOAD": self.base + "/dl/{version}/{name}", "S2A_UPDATE_PUBKEY": ed25519.public_key(TEST_SECRET).hex()})
        p.start(); self.addCleanup(p.stop)
        self.pkg = updater.ASSETS["windows"]

    def site(self, version, secret=TEST_SECRET):
        raw, sig = signed(version, {self.pkg: {"sha256": "a" * 64, "size": 7}, "S2Arm-windows-x64-delta-0.1.1.zip": {"sha256": "b" * 64, "size": 3}}, secret)
        ScriptedHandler.scripts["/update/latest.json"] = [(200, {}, raw)]
        ScriptedHandler.scripts["/update/latest.json.sig"] = [(200, {}, sig)]

    def github(self, version="0.3.1"):
        raw, sig = signed(version, {self.pkg: {"sha256": "c" * 64, "size": 9}})
        release = {"tag_name": "v" + version, "assets": [{"name": self.pkg, "browser_download_url": self.base + "/gh/pkg"},
                   {"name": updater.MANIFEST, "browser_download_url": self.base + "/gh/m"}, {"name": updater.SIGNATURE, "browser_download_url": self.base + "/gh/s"}]}
        ScriptedHandler.scripts.update({"/latest": [(200, {}, json.dumps(release).encode())], "/gh/m": [(200, {}, raw)], "/gh/s": [(200, {}, sig)]})

    def test_site_newer_version_is_used_without_asking_github(self):
        self.site("0.3.0"); self.github()
        info = updater.query_latest("windows", "0.1.1")
        self.assertEqual((info["available"], info["version"], info["sha256"], info["size"]), (True, "0.3.0", "a" * 64, 7))
        self.assertEqual(info["asset"], self.base + "/dl/0.3.0/" + self.pkg)   # 安装包仍从 Release 下载地址取
        self.assertEqual((info["deltaName"], info["deltaSha256"]), ("S2Arm-windows-x64-delta-0.1.1.zip", "b" * 64))
        self.assertNotIn("/latest", ScriptedHandler.hits)

    def test_site_not_newer_means_no_update_and_github_is_not_asked(self):
        for version in ("0.1.1", "0.1.0"):
            with self.subTest(version=version):
                ScriptedHandler.hits = []
                self.site(version); self.github()
                self.assertEqual(updater.query_latest("windows", "0.1.1"), {"available": False})
                self.assertNotIn("/latest", ScriptedHandler.hits)

    def test_site_timeout_falls_back_to_github(self):
        ScriptedHandler.scripts["/update/latest.json"] = ["sleep"]; self.github()
        info = updater.query_latest("windows", "0.1.1")
        self.assertEqual((info["version"], info["sha256"], info["asset"]), ("0.3.1", "c" * 64, self.base + "/gh/pkg"))
        self.assertEqual(ScriptedHandler.hits.count("/update/latest.json"), 1)   # 官网只试一次就回退

    def test_site_manifest_without_this_platform_means_no_update(self):
        """官网清单只有 Mac 包（只发了 Mac）：Windows 老用户 → 没有新版、不报错、不去问 GitHub，标准错误记一行；Mac 照常有新版"""
        mac = updater.ASSETS["mac"]
        raw, sig = signed("0.3.0", {mac: {"sha256": "d" * 64, "size": 5}})
        ScriptedHandler.scripts["/update/latest.json"] = [(200, {}, raw)]; ScriptedHandler.scripts["/update/latest.json.sig"] = [(200, {}, sig)]
        self.github()
        err = io.StringIO()
        with patch.object(sys, "stderr", err):
            self.assertEqual(updater.query_latest("windows", "0.2.9"), {"available": False})
        self.assertIn("签名清单里没有 S2Arm-windows-x64.zip", err.getvalue())
        self.assertNotIn("/latest", ScriptedHandler.hits)
        ScriptedHandler.scripts["/update/latest.json"] = [(200, {}, raw)]; ScriptedHandler.scripts["/update/latest.json.sig"] = [(200, {}, sig)]
        self.assertEqual(updater.query_latest("mac", "0.2.9")["version"], "0.3.0")

    def test_github_manifest_without_this_platform_means_no_update(self):
        """GitHub 这一版的签名清单里没有本平台的包（资产里却有同名文件也不认）→ 没有新版、不报错"""
        mac = updater.ASSETS["mac"]
        raw, sig = signed("0.3.1", {mac: {"sha256": "e" * 64, "size": 5}})
        release = {"tag_name": "v0.3.1", "assets": [{"name": self.pkg, "browser_download_url": self.base + "/gh/pkg"},
                   {"name": updater.MANIFEST, "browser_download_url": self.base + "/gh/m"}, {"name": updater.SIGNATURE, "browser_download_url": self.base + "/gh/s"}]}
        ScriptedHandler.scripts.update({"/latest": [(200, {}, json.dumps(release).encode())], "/gh/m": [(200, {}, raw)], "/gh/s": [(200, {}, sig)]})
        with patch.object(sys, "stderr", io.StringIO()):
            self.assertEqual(updater.query_latest("windows", "0.2.9"), {"available": False})

    def test_site_missing_falls_back_to_github(self):
        self.github()   # 官网 404（发版流程还没写入）
        self.assertEqual(updater.query_latest("windows", "0.1.1")["version"], "0.3.1")
        self.assertEqual(ScriptedHandler.hits[:1], ["/update/latest.json"])

    def test_site_bad_signature_falls_back_to_github(self):
        self.site("9.9.9", secret=bytes(range(1, 33))); self.github()   # 别的私钥签的「9.9.9」：不认，按 GitHub 的 0.3.1
        self.assertEqual(updater.query_latest("windows", "0.1.1")["version"], "0.3.1")
        self.assertIn("/latest", ScriptedHandler.hits)

    def test_both_failing_reports_the_github_error(self):
        reset = str(int(time.time()) + 600)
        ScriptedHandler.scripts["/latest"] = [(403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset}, b"{}")]
        with self.assertRaises(updater.UpdateError) as caught:
            updater.query_latest("windows", "0.1.1")
        self.assertEqual(caught.exception.code, "update_rate_limited")

    def test_site_hit_downloads_from_r2_first_with_github_as_fallback(self):
        """官网清单命中 → 安装包先走 R2（S2A_UPDATE_R2，正式构建 = dl.s2arm.com），GitHub 那个地址留作退路；没给 R2 就照旧只有 GitHub"""
        self.site("0.3.0")
        with patch.dict(os.environ, {"S2A_UPDATE_R2": self.base + "/r2/v{version}/{name}"}):
            info = updater.query_latest("windows", "0.1.1")
        self.assertEqual((info["asset"], info["assetFallback"]), (self.base + "/r2/v0.3.0/" + self.pkg, self.base + "/dl/0.3.0/" + self.pkg))
        self.site("0.3.0")
        self.assertNotIn("assetFallback", updater.query_latest("windows", "0.1.1"))






    def test_official_build_downloads_from_the_official_domain(self):
        with patch.dict(os.environ, {"S2A_UPDATE_API": ""}):
            self.assertTrue(updater.trusted(updater.R2_DOWNLOAD.format(version="0.3.1", name=self.pkg)))
            self.assertTrue(updater.R2_DOWNLOAD.startswith("https://dl.s2arm.com/"))

    def test_official_build_trusts_the_site_but_tests_never_reach_it(self):
        with patch.dict(os.environ, {"S2A_UPDATE_API": ""}):
            self.assertEqual(updater.mirror_url(), "https://s2arm.com/update/latest.json")
            self.assertTrue(updater.trusted(updater.MIRROR))
        with patch.dict(os.environ, {"S2A_UPDATE_MIRROR": ""}):
            self.assertEqual(updater.mirror_url(), "")   # 假 Release 验收没给官网地址：不连真网


if __name__ == "__main__":
    unittest.main()


class LegacyCleanupTests(unittest.TestCase):
    def test_old_updater_leftovers_are_cleared_notes_and_seen_kept(self):
        """v0.3.10 起换版交给 Sparkle / NetSparkle：旧自写换版留在 updates/ 下的 pending.json、health.ok、last_failure.json、apply.log、
        .update.lock、runner/、按版本号命名的整份新版都清掉；notes/（换上新版后弹说明用）与 seen.json 不动。期望手写"""
        with tempfile.TemporaryDirectory() as d:
            u = Path(d) / "updates"
            for name in ("pending.json", "health.ok", "last_failure.json", "apply.log", ".update.lock", "seen.json"):
                (u / name).parent.mkdir(parents=True, exist_ok=True); (u / name).write_text("x")
            for folder in ("runner/python", "0.3.9/unpack/S2Arm.app", "notes"):
                (u / folder).mkdir(parents=True, exist_ok=True)
            (u / "notes" / "0.3.10.json").write_text("{}")
            self.assertTrue(updater.clear_stale_pending(d, "0.3.10"))
            self.assertEqual(sorted(p.name for p in u.iterdir()), ["notes", "seen.json"])
            self.assertFalse(updater.clear_stale_pending(d, "0.3.10"))   # 再来一次没东西可清

    def test_answers_old_updater_handshake_and_leaves_its_files_while_it_runs(self):
        """11-14 本机复现：0.3.9 自写更新器换上 0.3.10、拉起后等 updates/health.ok 90 秒，0.3.10 不写还删它的 runner/ → 回滚删掉正在跑的新版。
        期望手写：替换进程（子进程持 .update.lock 的内核锁）还在时，新版启动清理写 health.ok、一个文件不删（runner/ / pending.json / 版本目录原样）、
        返回 False；替换进程退出后再清，照旧只剩 notes/ 与 seen.json"""
        with tempfile.TemporaryDirectory() as d:
            u = Path(d) / "updates"
            for name in ("pending.json", ".update.lock", "seen.json"):
                (u / name).parent.mkdir(parents=True, exist_ok=True); (u / name).write_text("x")
            for folder in ("runner/python", "0.3.10/unpack/S2Arm.app", "notes"):
                (u / folder).mkdir(parents=True, exist_ok=True)
            holder = subprocess.Popen([sys.executable, "-c", "import fcntl, sys, time; f = open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(60)",
                                       str(u / ".update.lock")], stdout=subprocess.PIPE, text=True)
            self.addCleanup(holder.kill)
            self.assertEqual(holder.stdout.readline().strip(), "locked")
            before = sorted(str(p.relative_to(u)) for p in u.rglob("*"))
            self.assertTrue(updater.legacy_apply_running(u))
            self.assertFalse(updater.clear_stale_pending(d, "0.3.10"))
            self.assertEqual((u / "health.ok").read_text(), "ok")
            self.assertEqual(sorted(str(p.relative_to(u)) for p in u.rglob("*") if p.name != "health.ok"), before)
            holder.kill(); holder.wait()
            self.assertFalse(updater.legacy_apply_running(u))
            self.assertTrue(updater.clear_stale_pending(d, "0.3.10"))
            self.assertEqual(sorted(p.name for p in u.iterdir()), ["notes", "seen.json"])

    def test_install_dir_mac_windows_and_source_tree(self):
        """期望手写：Mac S2Arm.app/Contents/Resources/Jobs/updater.py → S2Arm.app；Windows <装>/Engine/pack/jobs/updater.py → <装>；源码树 → None"""
        with tempfile.TemporaryDirectory() as d:
            mac = Path(d) / "Applications/S2Arm.app"; (mac / "Contents/Resources/Jobs").mkdir(parents=True); (mac / "Contents/Info.plist").write_text("x")
            win = Path(d) / "Programs/S2Arm"; (win / "Engine/pack/jobs").mkdir(parents=True); (win / "S2Arm.exe").write_text("x")
            self.assertEqual(updater.install_dir(mac / "Contents/Resources/Jobs/updater.py"), mac.resolve())
            self.assertEqual(updater.install_dir(win / "Engine/pack/jobs/updater.py"), win.resolve())
            self.assertIsNone(updater.install_dir())   # 本文件在源码树 pack/jobs/ 下

    def _leftovers(self, d):
        inst = Path(d) / "Programs/S2Arm"; (inst / "Engine").mkdir(parents=True); (inst / "S2Arm.exe").write_text("x")
        old = Path(d) / "Programs/S2Arm.s2arm-old"; (old / "Runtime/python").mkdir(parents=True); (old / "Runtime/python/python.exe").write_bytes(b"x" * 2 * 1048576)
        (Path(d) / "Programs/S2Arm.s2arm-bad").mkdir(); (Path(d) / "Programs/S2Arm.s2arm-new/Engine").mkdir(parents=True)
        for keep in ("S2Arm.backup", "Other.s2arm-old", "S2Arm.s2arm-old.txt"):
            (Path(d) / "Programs" / keep).mkdir() if "." not in keep[-4:] else (Path(d) / "Programs" / keep).write_text("x")
        return inst

    def test_sweeps_only_our_three_leftovers_and_logs_each(self):
        """Windows 实测的现场：完整 .s2arm-old（这里 2 MB）+ 空 .s2arm-bad + 半份 .s2arm-new。期望手写：三个都删、返回三个名字、update.log 三行带大小；
        安装目录本身、名字不合规则的（S2Arm.backup、Other.s2arm-old、S2Arm.s2arm-old.txt）都不动"""
        with tempfile.TemporaryDirectory() as d:
            inst = self._leftovers(d)
            gone = updater.sweep_install_leftovers(d, inst, in_use=lambda f: False)
            self.assertEqual(sorted(gone), ["S2Arm.s2arm-bad", "S2Arm.s2arm-new", "S2Arm.s2arm-old"])
            self.assertEqual(sorted(p.name for p in (Path(d) / "Programs").iterdir()), ["Other.s2arm-old", "S2Arm", "S2Arm.backup", "S2Arm.s2arm-old.txt"])
            log = (Path(d) / "logs/update.log").read_text(encoding="utf-8")
            self.assertEqual(log.count("update_leftover_removed"), 3)
            self.assertIn("S2Arm.s2arm-old（2 MB）", log)
            self.assertEqual(updater.sweep_install_leftovers(d, inst, in_use=lambda f: False), [])   # 再来一次没东西

    def test_leftover_in_use_or_locked_by_windows_is_kept(self):
        """期望手写：有进程在用的（in_use）不删；改名失败（Windows 文件被占用）的不删、不记日志；其余照删"""
        with tempfile.TemporaryDirectory() as d:
            inst = self._leftovers(d)
            real = os.rename
            def rename(a, b):
                if Path(a).name == "S2Arm.s2arm-new":
                    raise PermissionError(5, "拒绝访问")
                return real(a, b)
            with unittest.mock.patch.object(updater.os, "rename", rename):
                gone = updater.sweep_install_leftovers(d, inst, in_use=lambda f: f.name == "S2Arm.s2arm-old")
            self.assertEqual(gone, ["S2Arm.s2arm-bad"])
            self.assertTrue((Path(d) / "Programs/S2Arm.s2arm-old/Runtime/python/python.exe").is_file())
            self.assertTrue((Path(d) / "Programs/S2Arm.s2arm-new/Engine").is_dir())
            self.assertEqual((Path(d) / "logs/update.log").read_text(encoding="utf-8").count("update_leftover_removed"), 1)

    def test_leftovers_kept_while_old_updater_is_swapping_and_half_deleted_resumed(self):
        """期望手写：旧替换进程持着 .update.lock（还在换版，它要用 .s2arm-old / -new）→ 一个都不删；锁放开后照删，上次删到一半的 .deleting 也删掉"""
        with tempfile.TemporaryDirectory() as d:
            inst = self._leftovers(d)
            (Path(d) / "Programs/S2Arm.s2arm-old.deleting/x").mkdir(parents=True)
            u = Path(d) / "updates"; u.mkdir(); (u / ".update.lock").write_text("x")
            holder = subprocess.Popen([sys.executable, "-c", "import fcntl, sys, time; f = open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(60)",
                                       str(u / ".update.lock")], stdout=subprocess.PIPE, text=True)
            self.addCleanup(holder.kill)
            self.assertEqual(holder.stdout.readline().strip(), "locked")
            self.assertEqual(updater.sweep_install_leftovers(d, inst, in_use=lambda f: False), [])
            self.assertTrue((Path(d) / "Programs/S2Arm.s2arm-old").is_dir())
            holder.kill(); holder.wait()
            # 三个残骸；上次删到一半的 S2Arm.s2arm-old.deleting 和这次 .s2arm-old 改名的目标同名，改名前先删掉它，不另计
            self.assertEqual(len(updater.sweep_install_leftovers(d, inst, in_use=lambda f: False)), 3)
            self.assertFalse((Path(d) / "Programs/S2Arm.s2arm-old.deleting").exists())

    def test_in_use_reads_process_table(self):
        """期望手写：进程表里有可执行文件在这个目录下的 → 在用；只是名字前缀相同的另一个目录（S2Arm.app.s2arm-old2）不算；进程表拿不到（None）→ 一律算在用"""
        exes = ["/Applications/S2Arm.app.s2arm-old/Contents/MacOS/S2ArmApple --control", "/Applications/S2Arm.app.s2arm-old2/x"]
        check = updater.in_use_by(exes)
        self.assertTrue(check(Path("/Applications/S2Arm.app.s2arm-old")))
        self.assertFalse(check(Path("/Applications/S2Arm.app.s2arm-new")))
        self.assertTrue(updater.in_use_by(None)(Path("/Applications/S2Arm.app.s2arm-new")))

    def test_half_deleted_in_use_kept_and_resumed_one_logged(self):
        """期望手写：上次删到一半的 .deleting 有进程在用 → 不动；没人用 → 删掉并记一行「上次没删完」"""
        with tempfile.TemporaryDirectory() as d:
            inst = Path(d) / "Programs/S2Arm"; (inst / "Engine").mkdir(parents=True); (inst / "S2Arm.exe").write_text("x")
            half = Path(d) / "Programs/S2Arm.s2arm-old.deleting"; (half / "Runtime").mkdir(parents=True)
            self.assertEqual(updater.sweep_install_leftovers(d, inst, in_use=lambda f: True), [])
            self.assertTrue(half.is_dir())
            self.assertEqual(updater.sweep_install_leftovers(d, inst, in_use=lambda f: False), ["S2Arm.s2arm-old.deleting"])
            self.assertIn("上次没删完", (Path(d) / "logs/update.log").read_text(encoding="utf-8"))

    def test_no_leftovers_does_not_read_process_table(self):
        """绝大多数启动没有残骸：期望手写，不起进程表（running_executables 一次都不调）"""
        with tempfile.TemporaryDirectory() as d:
            inst = Path(d) / "Programs/S2Arm"; (inst / "Engine").mkdir(parents=True); (inst / "S2Arm.exe").write_text("x")
            with unittest.mock.patch.object(updater, "running_executables", side_effect=AssertionError("不该读进程表")):
                self.assertEqual(updater.sweep_install_leftovers(d, inst), [])

    def test_pending_without_running_updater_is_cleared(self):
        """准备好了没换（旧版下载完、玩家改用 DMG 装了新版）：没有替换进程，照常全清。期望手写：只剩 notes/ 与 seen.json"""
        with tempfile.TemporaryDirectory() as d:
            u = Path(d) / "updates"; (u / "runner").mkdir(parents=True); (u / "notes").mkdir()
            for name in ("pending.json", ".update.lock", "seen.json"):
                (u / name).write_text("x")
            self.assertTrue(updater.clear_stale_pending(d, "0.3.10"))
            self.assertEqual(sorted(p.name for p in u.iterdir()), ["notes", "seen.json"])
