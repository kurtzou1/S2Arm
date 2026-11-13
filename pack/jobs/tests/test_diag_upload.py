"""上传诊断给开发者（diag_upload.upload，11-13 诊断一键上传）：本机回环上的假上传服务，不联外网。
期望（手算，不复述实现）：
  ① 没配上传地址 → 失败码 diag_upload_failed（界面据此退回导出），临时包不留在机器上
  ② 服务回 {"code": "D-7K3Q"} → 结果 code = D-7K3Q；服务收到的是一份 zip，里面有 manifest.json，带了 operations 时还有 logs/error-summary.log（错误摘要正文）
  ③ 照服务端协议：400 / 413 用服务端给玩家的 message；429 说稍后再试；回的不是 D-xxxx 短码 / 连不上 → 都是 diag_upload_failed；
     5xx 重试一次（第二次成功就拿到码）；请求头带 X-S2Arm-Client: mac|windows/<版本>、User-Agent 是 S2Arm 自己的（Python 缺省的被 Cloudflare 拦，403 / 1010）
  ⑥ 诊断包 manifest.json 带 "schema": 1（服务端收件规则，没有判 not_diag）
  ⑦ 成功结果带预填新帖链接：模板 问题回报.yml、logs = 短码、platform 是模板下拉里逐字存在的选项、标题前缀「[问题] 」
  ④ 包超过 30 MB 上限 → 不传，diag_upload_failed
  ⑤ 没有作业记录的失败（环境检查）：界面交来的 summary 正文脱敏后放进 logs/error-summary.log（家目录换成 ~）
  ⑧ 顶栏全局「故障报修」（不带 gameId / operations / summary）：有失败的作业 → 自动附最近一次失败的错误摘要；没有就不附、照传
  ⑨ 没选游戏库（库路径是还没建的目录、不带 libraryId）、库里一款游戏都没有：走真 worker 照样传成、拿到短码"""
import http.server
import io
import json
import os
from pathlib import Path
import tempfile
import threading
from unittest import mock
import zipfile

from jobcase import JobCase
from core import Failure
import diag_upload


class FakeService:
    def __init__(self, status=200, body=b'{"code": "D-7K3Q", "expiresAt": "2026-11-20T07:16:36Z"}', script=None):
        self.status, self.body, self.got, self.script, self.headers, self.agents = status, body, [], list(script or []), [], []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                outer.got.append((self.headers.get("Content-Type"), self.rfile.read(int(self.headers["Content-Length"]))))
                outer.headers.append(self.headers.get("X-S2Arm-Client")); outer.agents.append(self.headers.get("User-Agent"))
                status, body = outer.script.pop(0) if outer.script else (outer.status, outer.body)
                self.send_response(status); self.end_headers(); self.wfile.write(body)

            def log_message(self, *a):
                pass
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_port}/diag"

    def close(self):
        self.srv.shutdown(); self.srv.server_close()


class DiagUploadTests(JobCase):
    def failed_record(self):
        self.c.report_failure(Failure("synthetic failure"))
        self.c.finish("failed", "x")

    def leftovers(self):
        return sorted(p.name for p in Path(tempfile.gettempdir()).glob("s2a-diag-*"))

    def test_unconfigured_fails_with_fallback_code(self):
        before = self.leftovers()
        with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": ""}), mock.patch.object(diag_upload, "UPLOAD_URL", ""):
            with self.assertRaises(Failure) as e:
                diag_upload.upload(self.c)
        self.assertEqual(e.exception.code, "diag_upload_failed")
        self.assertIn("导出诊断包", str(e.exception))
        self.assertEqual(self.leftovers(), before)

    def test_success_returns_code_and_sends_zip_with_summary(self):
        self.failed_record()
        svc = FakeService()
        try:
            self.c.r["operations"] = []
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}):
                result = diag_upload.upload(self.c)
        finally:
            svc.close()
        self.assertEqual(result["code"], "D-7K3Q")
        self.assertTrue(result["issueUrl"].startswith("https://github.com/jhaizhou-ops/S2Arm/issues/new?"))
        self.assertEqual(len(svc.got), 1)
        kind, data = svc.got[0]
        self.assertEqual(kind, "application/zip")
        names = zipfile.ZipFile(io.BytesIO(data)).namelist()
        self.assertIn("manifest.json", names)
        self.assertEqual(json.loads(zipfile.ZipFile(io.BytesIO(data)).read("manifest.json"))["schema"], 1)
        self.assertRegex(svc.headers[0], r"^(mac|windows)/\S+$")
        self.assertTrue(svc.agents[0].startswith("S2Arm/"), svc.agents[0])   # Python 缺省 UA 被 Cloudflare 拦（403 / 1010）
        self.assertIn("logs/error-summary.log", names)
        text = zipfile.ZipFile(io.BytesIO(data)).read("logs/error-summary.log").decode()
        self.assertIn("S2Arm 错误摘要", text)

    def test_service_errors_are_upload_failures(self):
        cases = ((400, '{"error": "forbidden_file", "message": "包里有不允许上传的文件。"}'.encode(), "包里有不允许上传的文件"),
                 (413, '{"error": "too_large", "message": "诊断包超过 30 MB。"}'.encode(), "超过 30 MB"),
                 (429, b'{"error": "rate_limited", "retryAfter": 60}', "稍等一分钟"),
                 (200, b"<html>", "看不懂"), (200, b'{"code": "D-0O1I"}', "短码"), (200, b'{"code": "a b"}', "短码"))
        for status, body, words in cases:
            svc = FakeService(status, body)
            try:
                with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}), mock.patch.object(diag_upload.time, "sleep"), self.assertRaises(Failure) as e:
                    diag_upload.upload(self.c)
            finally:
                svc.close()
            self.assertEqual(e.exception.code, "diag_upload_failed", (status, body))
            self.assertIn(words, str(e.exception))
            self.assertIn("导出诊断包", str(e.exception))
        with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": "http://127.0.0.1:9/none"}), mock.patch.object(diag_upload.time, "sleep"), self.assertRaises(Failure) as e:
            diag_upload.upload(self.c)
        self.assertEqual(e.exception.code, "diag_upload_failed")
        self.assertIn("连不上", str(e.exception))

    def test_5xx_retries_once(self):
        svc = FakeService(script=[(503, b"busy")])
        try:
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}), mock.patch.object(diag_upload.time, "sleep"):
                result = diag_upload.upload(self.c)
        finally:
            svc.close()
        self.assertEqual((result["code"], len(svc.got)), ("D-7K3Q", 2))
        svc = FakeService(script=[(503, b"busy"), (502, b"busy")])
        try:
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}), mock.patch.object(diag_upload.time, "sleep"), self.assertRaises(Failure) as e:
                diag_upload.upload(self.c)
        finally:
            svc.close()
        self.assertEqual(len(svc.got), 2)
        self.assertIn("出错了", str(e.exception))

    def test_oversize_is_not_sent(self):
        svc = FakeService()
        try:
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}), mock.patch.object(diag_upload, "LIMIT", 10), self.assertRaises(Failure) as e:
                diag_upload.upload(self.c)
        finally:
            svc.close()
        self.assertEqual(e.exception.code, "diag_upload_failed")
        self.assertEqual(svc.got, [])

    def test_summary_text_without_job_record(self):
        svc = FakeService()
        try:
            self.c.r["summary"] = f"环境检查没过：Xcode 在 {Path.home()}/Applications"
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}):
                diag_upload.upload(self.c)
        finally:
            svc.close()
        text = zipfile.ZipFile(io.BytesIO(svc.got[0][1])).read("logs/error-summary.log").decode()
        self.assertIn("环境检查没过", text)
        self.assertNotIn(str(Path.home()), text)

    def test_issue_url_matches_template(self):
        """链接字段 = 模板（.github/ISSUE_TEMPLATE/问题回报.yml）里真有的 id；platform 选项逐字是模板下拉里的一项。只用标准库按行读模板（门禁机不装 yaml）"""
        from urllib.parse import urlparse, parse_qs
        lines = (Path(__file__).resolve().parents[3] / ".github/ISSUE_TEMPLATE/问题回报.yml").read_text(encoding="utf-8").splitlines()
        ids = {l.split("id:", 1)[1].strip() for l in lines if l.strip().startswith("id:")}
        options, inside = [], False
        for l in lines:
            t = l.strip()
            if t.startswith("id:"): inside = t.split("id:", 1)[1].strip() == "platform"
            elif inside and t.startswith("- ") and not t.startswith("- type:"): options.append(t[2:].strip())
            elif inside and t.startswith("validations:"): inside = False
        self.assertTrue({"logs", "version", "platform"} <= ids, ids)
        self.assertIn("iPhone", options)
        for client, plat in (("mac/0.3.5", "mac"), ("windows/0.3.5", "windows")):
            q = parse_qs(urlparse(diag_upload.issue_url("D-7K3Q", client)).query)
            self.assertEqual(q["template"], ["问题回报.yml"])
            self.assertEqual((q["logs"], q["version"], q["title"]), (["D-7K3Q"], ["0.3.5"], ["[问题] "]))
            self.assertIn(q["platform"][0], options, plat)

    def test_global_button_attaches_latest_failure(self):   # ⑧
        svc = FakeService()
        try:
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}):
                diag_upload.upload(self.c)   # 还没有失败的作业：不附
                self.failed_record()
                diag_upload.upload(self.c)   # 有了：附最近一次
        finally:
            svc.close()
        first, second = (zipfile.ZipFile(io.BytesIO(d)).namelist() for _, d in svc.got)
        self.assertNotIn("logs/error-summary.log", first)
        self.assertIn("logs/error-summary.log", second)
        self.assertIn("S2Arm 错误摘要", zipfile.ZipFile(io.BytesIO(svc.got[1][1])).read("logs/error-summary.log").decode())

    def test_upload_without_library(self):   # ⑨
        svc = FakeService()
        try:
            with mock.patch.dict(os.environ, {"S2A_DIAG_UPLOAD_URL": svc.url}):
                _, terminal = self.worker("diagnosticsUpload", library=str(self.root / "never-set-up"), libraryId=None)
        finally:
            svc.close()
        self.assertEqual(terminal["state"], "succeeded", terminal)
        self.assertEqual(terminal["result"]["code"], "D-7K3Q")
        self.assertEqual(len(svc.got), 1)
