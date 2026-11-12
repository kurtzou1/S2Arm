import hashlib
import io
import http.server
import json
import os
import sys
import tempfile
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


class ApplyTests(Base):
    def run_apply(self, launch, **options):
        return updater.apply(self.staged, self.install, 2147483646, self.private, launch=launch, health_seconds=options.pop("health", 1), **options)

    def healthy(self, install, args):
        (self.private / "updates/health.ok").write_text("ok")

    def test_success_replaces_install_and_keeps_every_user_file(self):
        before = self.data()
        self.assertEqual(self.run_apply(self.healthy), 0)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "new")
        self.assertFalse(self.install.with_name("S2Arm.s2arm-old").exists())
        self.assertEqual(self.data(), before)

    def leftovers(self):
        """各版本的工作目录（新版解在 unpack/、上一次更新留下的）+ 不该动的 runner/ 和标记文件"""
        u = self.private / "updates"
        for rel in ("0.3.0/unpack/S2Arm/S2Arm.exe", "0.3.0/S2Arm-windows-x64.zip.part", "0.2.8/unpack/S2Arm/S2Arm.exe", "0.2.9/delta/x", "runner/updater.py", "notes/keep.txt"):
            (u / rel).parent.mkdir(parents=True, exist_ok=True); (u / rel).write_text("x")
        return u

    def test_success_removes_unpacked_copies_but_keeps_runner(self):
        """#660：换版是从 updates/<版本号>/unpack 拷进安装目录的，确认新版起来以后这份（和以前各版留下的）都删掉，不再一直占系统盘"""
        u = self.leftovers()
        self.assertEqual(self.run_apply(self.healthy), 0)
        self.assertEqual(sorted(p.name for p in u.iterdir() if p.is_dir()), ["notes", "runner"])   # 版本号目录全删；runner（正在跑的更新器）和别的目录不动
        self.assertTrue((u / "runner/updater.py").is_file())

    def test_rollback_keeps_unpacked_copy(self):
        """新版没起来、回到旧版：不删（下次同版本重试时 prepare 自己清，失败现场留着便于诊断）"""
        u = self.leftovers()
        self.assertEqual(self.run_apply(lambda i, a: None), 1)
        self.assertTrue((u / "0.3.0/unpack/S2Arm/S2Arm.exe").is_file())

    def test_read_only_files_do_not_leave_the_old_copy_behind(self):
        locked = self.install / "Engine/pack"; locked.write_text("x"); locked.chmod(0o444)
        self.assertEqual(self.run_apply(self.healthy), 0)
        self.assertFalse(self.install.with_name("S2Arm.s2arm-old").exists())

    def test_new_version_that_never_starts_is_rolled_back(self):
        before = self.data(); launches = []
        self.assertEqual(self.run_apply(lambda i, a: launches.append((i / "S2Arm.exe").read_text())), 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")
        self.assertEqual(launches, ["new", "old"])
        self.assertEqual(json.loads((self.private / "updates/last_failure.json").read_text(encoding="utf-8"))["code"], "update_rolled_back")
        self.assertEqual(self.data(), before)

    def test_swap_failure_keeps_old_version(self):
        real, calls = os.rename, []

        def flaky(source, target):   # 新版的东西放不进安装位置：整目录改名、逐项改名（move_dir 的退路）都被拒
            calls.append(target)
            if ".s2arm-new" in str(source) and (Path(target) == self.install or Path(target).parent == self.install):
                raise PermissionError(13, "locked")
            real(source, target)
        launches = []
        with patch.object(updater.os, "rename", flaky), patch.object(updater.time, "sleep", lambda s: None), patch.object(updater.time, "monotonic", side_effect=iter(range(0, 10**6, 100)).__next__):
            self.assertEqual(self.run_apply(lambda i, a: launches.append((i / "S2Arm.exe").read_text())), 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")
        self.assertEqual(launches, ["old"])

    def test_install_folder_held_open_swaps_its_contents(self):
        # #379：下载工具持有安装目录本身的句柄，整目录改名一直被拒、里面的文件能改名 → 逐项换上新版，确认起来后旧副本删掉
        real = os.rename
        def held(source, target):
            if Path(source) == self.install:
                raise PermissionError(32, "being used by another process")
            real(source, target)
        with patch.object(updater.os, "rename", held), patch.object(updater.time, "sleep", lambda s: None), \
             patch.object(updater.time, "monotonic", side_effect=iter(range(0, 10**6, 100)).__next__):
            self.assertEqual(self.run_apply(self.healthy), 0)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "new")
        self.assertTrue((self.install / "Engine").is_dir())
        self.assertFalse(self.install.with_name("S2Arm.s2arm-old").exists())

    def test_held_folder_and_a_locked_file_rolls_every_entry_back(self):
        # 逐项换到一半有文件也被占（残留的作业进程开着它）：已搬走的全部搬回，旧版原样，失败原因记进 update.log
        real = os.rename
        def held(source, target):
            if Path(source) == self.install or Path(source) == self.install / "S2Arm.exe":
                raise PermissionError(32, "being used by another process")
            real(source, target)
        with patch.object(updater.os, "rename", held), patch.object(updater.time, "sleep", lambda s: None), \
             patch.object(updater.time, "monotonic", side_effect=iter(range(0, 10**6, 100)).__next__):
            self.assertEqual(self.run_apply(self.healthy), 1)
        self.assertEqual(((self.install / "S2Arm.exe").read_text(), sorted(p.name for p in self.install.iterdir())), ("old", ["Engine", "S2Arm.exe"]))
        self.assertIn("update_swap_failed", (self.private / "logs/update.log").read_text(encoding="utf-8"))

    def test_rollback_reason_is_kept_in_update_log(self):   # #379：last_failure.json 启动器读完就删，原因还要留在诊断包会收的日志里
        self.assertEqual(self.run_apply(lambda i, a: None), 1)
        self.assertIn("update_rolled_back", (self.private / "logs/update.log").read_text(encoding="utf-8"))

    def test_app_that_does_not_exit_is_left_alone(self):
        result = updater.apply(self.staged, self.install, os.getpid(), self.private, launch=self.fail, exit_seconds=0)
        self.assertEqual(result, 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")

    def test_retry_after_interrupted_first_rename_installs_new_version(self):
        before = self.data()
        backup = self.install.with_name("S2Arm.s2arm-old")
        # swap() interrupted after install -> backup, before new -> install.
        os.rename(self.install, backup)
        self.assertEqual(self.run_apply(self.healthy), 0)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "new")
        self.assertFalse(backup.exists())
        self.assertEqual(self.data(), before)

    def test_retry_when_restore_leaves_an_empty_backup_keeps_the_old_copy(self):
        # 审计 P1-157：上次中断在「安装目录已改名为 .s2arm-old、新版还没换上」。这次先把副本搬回：整段改名被拒（目录被占用）→ 逐项搬，
        #   搬空的 .s2arm-old 删不掉留成空目录。期望（手写）：空目录不当成「还有一份旧版」，旧版留在安装目录；新版起不来就回到它，
        #   失败句「已回到旧版」与盘上一致（原先把刚搬回的旧版当坏的删掉，安装目录没有 S2Arm.exe，失败句仍写「已回到旧版」）
        backup = self.install.with_name("S2Arm.s2arm-old")
        os.rename(self.install, backup)
        real_rename, real_rmdir = updater.retry_rename, Path.rmdir
        def rename(src, dst, *a, **kw):
            if Path(src) == backup and Path(dst) == self.install:
                raise PermissionError(13, "held open")
            return real_rename(src, dst, *a, **kw)
        def rmdir(path, *a, **kw):
            if Path(path) == backup:
                raise OSError(16, "busy")
            return real_rmdir(path, *a, **kw)
        with patch.object(updater, "retry_rename", rename), patch.object(Path, "rmdir", rmdir):
            self.assertEqual(self.run_apply(lambda install, args: None, health=0, exit_seconds=0), 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")
        failure = json.loads((self.private / "updates/last_failure.json").read_text(encoding="utf-8"))
        self.assertEqual((failure["code"], failure["message"]), ("update_rolled_back", "新版没能启动，已回到旧版。"))

    def test_holds_copy_ignores_empty_leftovers(self):
        empty = self.root / "empty"; empty.mkdir()
        self.assertTrue(updater.holds_copy(self.install))
        self.assertFalse(updater.holds_copy(empty))
        self.assertFalse(updater.holds_copy(self.root / "missing"))

    def test_retry_with_missing_staged_files_restores_the_old_install(self):
        before = self.data()
        backup = self.install.with_name("S2Arm.s2arm-old")
        os.rename(self.install, backup)
        launches = []
        self.staged = self.root / "missing-staged"
        self.assertEqual(self.run_apply(lambda i, a: launches.append((i / "S2Arm.exe").read_text())), 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")
        self.assertEqual(launches, ["old"])
        self.assertEqual(self.data(), before)

    def test_failed_interrupted_install_recovery_preserves_the_backup(self):
        backup = self.install.with_name("S2Arm.s2arm-old")
        os.rename(self.install, backup)
        with patch.object(updater, "retry_rename", side_effect=PermissionError(13, "locked")):
            self.assertEqual(self.run_apply(lambda *_: None), 1)
        self.assertEqual((backup / "S2Arm.exe").read_text(), "old")

    def test_retry_after_partial_new_copy_cleans_it_and_installs_normally(self):
        backup = self.install.with_name("S2Arm.s2arm-old")
        os.rename(self.install, backup)
        partial = self.install.with_name("S2Arm.s2arm-new")
        partial.mkdir()
        (partial / "incomplete").write_text("synthetic interrupted copy")
        self.assertEqual(self.run_apply(self.healthy), 0)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "new")
        self.assertFalse((self.install / "incomplete").exists())
        self.assertFalse(partial.exists())

    def unconfirmed_previous_update(self):
        """上一次 apply 已把安装目录换成新版、旧版留在副本，没等到 health.ok 就中断（审计 P1-147）"""
        backup = self.install.with_name("S2Arm.s2arm-old")
        os.rename(self.install, backup)
        (self.install / "Engine").mkdir(parents=True)
        (self.install / "S2Arm.exe").write_text("unconfirmed")
        return backup

    def test_failed_retry_after_unconfirmed_update_keeps_the_known_good_install(self):
        self.unconfirmed_previous_update()
        self.staged = self.root / "missing-staged"   # 这次替换必然失败
        launches = []
        self.assertEqual(self.run_apply(lambda i, a: launches.append((i / "S2Arm.exe").read_text())), 1)
        failure = json.loads((self.private / "updates/last_failure.json").read_text(encoding="utf-8"))
        self.assertEqual(failure["code"], "update_swap_failed")
        # 失败句说「已保留旧版」：盘上必须真有确认过能用的那一版
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")
        self.assertEqual(launches, ["old"])

    def test_new_version_failing_after_unconfirmed_update_rolls_back_to_the_known_good_install(self):
        backup = self.unconfirmed_previous_update()
        launches = []
        self.assertEqual(self.run_apply(lambda i, a: launches.append((i / "S2Arm.exe").read_text())), 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "old")
        self.assertEqual(launches, ["new", "old"])
        self.assertFalse(backup.exists())

    def test_confirmed_previous_update_becomes_the_rollback_target(self):
        self.unconfirmed_previous_update()
        (self.private / "updates/health.ok").write_text("ok")   # 上次换上的版本后来起来过
        launches = []
        self.assertEqual(self.run_apply(lambda i, a: launches.append((i / "S2Arm.exe").read_text())), 1)
        self.assertEqual((self.install / "S2Arm.exe").read_text(), "unconfirmed")
        self.assertEqual(launches, ["new", "unconfirmed"])


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


class FlakyHandler(http.server.BaseHTTPRequestHandler):
    """按脚本回应：每项是一次请求给多少字节（None = 全给）、支不支持续传"""
    body = b""
    plan = []
    ranges = []

    def do_GET(self):
        header = self.headers.get("Range")
        start = int(header[6:-1]) if header else 0
        type(self).ranges.append(start)
        limit, resume = type(self).plan.pop(0) if type(self).plan else (None, True)
        if not resume:
            start = 0
        data = self.body[start:]
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data if limit is None else data[:limit])
        self.wfile.flush()
        self.connection.close()

    def log_message(self, *a):
        pass


class DownloadTests(Base):
    def setUp(self):
        super().setUp()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FlakyHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        FlakyHandler.body = bytes(range(256)) * 4096
        FlakyHandler.ranges = []
        self.target = self.root / "package"
        for name, value in (("trusted", lambda url: True), ("emit", lambda **k: None)):
            p = patch.object(updater, name, value); p.start(); self.addCleanup(p.stop)
        p = patch.object(updater, "RETRY_SECONDS", 0); p.start(); self.addCleanup(p.stop)

    def get(self):
        updater.download(f"http://127.0.0.1:{self.server.server_port}/p", self.target, len(FlakyHandler.body))

    def test_dropped_connection_resumes_where_it_stopped(self):
        FlakyHandler.plan = [(1 << 18, True), (1 << 18, True), (None, True)]
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)
        self.assertEqual(FlakyHandler.ranges, [0, 1 << 18, 1 << 19])

    def test_server_without_resume_starts_over(self):
        FlakyHandler.plan = [(1 << 18, True), (None, False)]
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)

    def test_gives_up_when_nothing_arrives(self):
        FlakyHandler.plan = [(0, True)] * updater.DOWNLOAD_ATTEMPTS
        with self.assertRaises(updater.UpdateError) as caught:
            self.get()
        self.assertEqual(caught.exception.code, "update_download_failed")
        self.assertFalse(self.target.exists())

    def test_retry_in_a_new_process_resumes_from_the_saved_part(self):
        """跨进程重试（审计 P2-220）：上次进程留下的 .part 接着下，不从头来"""
        Path(str(self.target) + ".part").write_bytes(FlakyHandler.body[:1 << 18])
        FlakyHandler.plan = [(None, True)]
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)
        self.assertEqual(FlakyHandler.ranges, [1 << 18])

    def test_part_longer_than_the_manifest_is_discarded(self):
        Path(str(self.target) + ".part").write_bytes(b"x" * (len(FlakyHandler.body) + 1))
        FlakyHandler.plan = [(None, True)]
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)
        self.assertEqual(FlakyHandler.ranges, [0])

    def test_slow_progress_keeps_going_past_the_attempt_limit(self):
        FlakyHandler.plan = [(1 << 16, True)] * (updater.DOWNLOAD_ATTEMPTS + 3) + [(None, True)]
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)

    def test_completed_download_retries_promotion_without_another_request(self):
        real, attempts = os.replace, []

        def locked(source, target):
            attempts.append((source, target))
            if len(attempts) < 3:
                raise PermissionError(13, "synthetic sharing violation")
            return real(source, target)

        FlakyHandler.plan = [(None, True)]
        with patch.object(updater.os, "replace", locked), patch.object(updater.time, "sleep"):
            self.get()
        self.assertEqual(len(attempts), 3)
        self.assertEqual(FlakyHandler.ranges, [0])
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)
        self.assertFalse(Path(str(self.target) + ".part").exists())

    def test_promotion_timeout_keeps_complete_part_for_the_next_attempt(self):
        FlakyHandler.plan = [(None, True)]
        with patch.object(updater.os, "replace", side_effect=PermissionError(13, "synthetic sharing violation")) as replace, \
                patch.object(updater.time, "monotonic", side_effect=[0, 1, 31]), patch.object(updater.time, "sleep"), \
                self.assertRaises(PermissionError):
            self.get()
        self.assertEqual(replace.call_count, 2)
        self.assertFalse(self.target.exists())
        self.assertEqual(Path(str(self.target) + ".part").read_bytes(), FlakyHandler.body)
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)
        self.assertEqual(FlakyHandler.ranges, [0])

    def test_completed_part_can_replace_an_existing_target(self):
        self.target.write_bytes(b"stale package")
        Path(str(self.target) + ".part").write_bytes(FlakyHandler.body)
        self.get()
        self.assertEqual(self.target.read_bytes(), FlakyHandler.body)
        self.assertEqual(FlakyHandler.ranges, [])


class MacUnpackTests(Base):
    def test_failed_attach_reports_why_and_mounts_outside_the_data_folder(self):
        calls = []
        def run(cmd, **k):
            calls.append(cmd)
            return type("R", (), {"returncode": 1, "stderr": b"hdiutil: attach failed - Permission denied"})
        dest = self.root / "unpack"; dest.mkdir()
        with patch.object(updater.subprocess, "run", run), self.assertRaises(updater.UpdateError) as caught:
            updater.extract_mac(self.root / "x.dmg", dest)
        self.assertEqual(caught.exception.code, "update_unpack_failed")
        self.assertIn("Permission denied", caught.exception.detail)
        mount = Path(calls[0][calls[0].index("-mountpoint") + 1])
        self.assertFalse(mount.is_relative_to(self.root)); self.assertFalse(mount.exists())

    def test_failure_reason_reaches_the_log(self):
        args = type("A", (), {"private_root": str(self.root / "p")})
        updater.record_failure(args, "update_unpack_failed", "打不开", "hdiutil: attach failed")
        text = (self.root / "p/logs/update.log").read_text(encoding="utf-8")
        self.assertIn("update_unpack_failed", text); self.assertIn("hdiutil: attach failed", text)


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
        for name, value in (("trusted", lambda url: True), ("emit", lambda **k: None), ("FETCH_RETRY_SECONDS", 0), ("RETRY_SECONDS", 0)):
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

    def test_missing_package_fails_fast_with_server_code(self):
        ScriptedHandler.scripts["/pkg"] = [(404, {}, b"")]
        with self.assertRaises(updater.UpdateError) as caught:
            updater.download(self.base + "/pkg", self.root / "p", 1000)
        self.assertEqual(caught.exception.code, "update_server")
        self.assertEqual(ScriptedHandler.hits, ["/pkg"])   # 地址本身出错：不空耗重试


class ThrottledDropHandler(http.server.BaseHTTPRequestHandler):
    """限速 + 中途掐连接：每次最多给 cut 字节、每 16 KB 停 2 毫秒，然后断开（国内连 GitHub 下大文件的常见样子）"""
    body, cut, ranges = b"", 1 << 17, []

    def do_GET(self):
        header = self.headers.get("Range")
        start = int(header[6:-1]) if header else 0
        type(self).ranges.append(start)
        data = self.body[start:]
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        sent, limit = 0, min(len(data), type(self).cut)
        while sent < limit:
            n = min(16384, limit - sent)
            self.wfile.write(data[sent:sent + n]); self.wfile.flush(); sent += n
            time.sleep(0.002)
        self.connection.close()

    def log_message(self, *a):
        pass


class ThrottledDownloadTests(Base):
    def test_throttled_and_repeatedly_cut_download_resumes_to_completion(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ThrottledDropHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        ThrottledDropHandler.body, ThrottledDropHandler.cut, ThrottledDropHandler.ranges = bytes(range(256)) * 4096, 1 << 17, []   # 1 MiB，每次断在 128 KiB：要 8 次
        for name, value in (("trusted", lambda url: True), ("emit", lambda **k: None), ("RETRY_SECONDS", 0)):
            p = patch.object(updater, name, value); p.start(); self.addCleanup(p.stop)
        target = self.root / "pkg"
        updater.download(f"http://127.0.0.1:{server.server_port}/p", target, len(ThrottledDropHandler.body))
        self.assertEqual(target.read_bytes(), ThrottledDropHandler.body)
        self.assertEqual(ThrottledDropHandler.ranges, [i << 17 for i in range(8)])   # 每次从断开处接着下


class PrepareTests(Base):
    def setUp(self):
        super().setUp()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        patcher = patch.dict(os.environ, {"S2A_UPDATE_API": self.base + "/latest", "S2A_UPDATE_PUBKEY": ed25519.public_key(TEST_SECRET).hex()})
        patcher.start(); self.addCleanup(patcher.stop)
        package = self.root / "p.zip"
        with zipfile.ZipFile(package, "w") as z:
            z.writestr("S2Arm/S2Arm.exe", "new"); z.writestr("S2Arm/Engine/e", "e"); z.writestr("S2Arm/Runtime/python/python.exe", "py")
            z.writestr("S2Arm/Runtime/python/Lib/site-packages/big", "x"); z.writestr("S2Arm/Runtime/python/Lib/os.py", "os")
        self.zip = package.read_bytes()
        self.publish(hashlib.sha256(self.zip).hexdigest())

    def publish(self, digest, tag="v9.9.9", secret=TEST_SECRET, version="9.9.9"):
        name = "S2Arm-windows-x64.zip"
        raw, signature = signed(version, {name: {"sha256": digest, "size": len(self.zip)}}, secret)
        Handler.routes = {"/latest": json.dumps({"tag_name": tag, "assets": [
            {"name": name, "size": len(self.zip), "browser_download_url": self.base + "/pkg"},
            {"name": updater.MANIFEST, "size": 80, "browser_download_url": self.base + "/m"},
            {"name": updater.SIGNATURE, "size": 64, "browser_download_url": self.base + "/s"}]}).encode(),
            "/pkg": self.zip, "/m": raw, "/s": signature}

    def prepare(self, protect=()):
        with patch("builtins.print") as out, patch.object(updater.subprocess, "run", return_value=type("R", (), {"returncode": 0, "stdout": ""})()):
            updater.prepare("windows", "0.1.1", self.private, self.install, list(protect) + [self.private])
        return json.loads(out.call_args.args[0])

    def test_ready_leaves_install_untouched_and_runner_has_no_site_packages(self):
        before = tree(self.install)
        ready = self.prepare()
        self.assertEqual(ready["state"], "ready")
        self.assertEqual(tree(self.install), before)
        self.assertEqual((Path(ready["staged"]) / "S2Arm.exe").read_text(), "new")
        self.assertTrue(Path(ready["python"]).is_file())
        self.assertFalse(list(Path(ready["python"]).parent.rglob("site-packages")))

    def test_retry_keeps_the_partial_download_of_the_same_version(self):
        work = self.private / "updates/9.9.9"
        (work / "unpack").mkdir(parents=True)
        (work / "unpack/stale").write_text("x")
        part = work / "S2Arm-windows-x64.zip.part"
        part.write_bytes(self.zip[:100])
        seen = []
        with patch.object(updater, "download", side_effect=lambda url, target, size, **_: seen.append(Path(str(target) + ".part").read_bytes()) or Path(target).write_bytes(self.zip)):
            ready = self.prepare()
        self.assertEqual(ready["state"], "ready")
        self.assertEqual(seen, [self.zip[:100]])   # prepare 没删已下的字节，交给 download 续传
        self.assertFalse((work / "unpack/stale").exists())

    def test_checksum_mismatch_deletes_download_and_keeps_old(self):
        self.publish("0" * 64); before = tree(self.install)
        with self.assertRaises(updater.UpdateError) as caught:
            self.prepare()
        self.assertEqual(caught.exception.code, "update_checksum_mismatch")
        self.assertEqual(tree(self.install), before)
        self.assertFalse(list((self.private / "updates").rglob("S2Arm-windows-x64.zip")))

    def test_promotion_retry_still_verifies_the_signed_checksum(self):
        real = os.replace
        for valid in (True, False):
            with self.subTest(valid=valid):
                self.publish(hashlib.sha256(self.zip).hexdigest() if valid else "0" * 64)
                before, attempts = tree(self.install), []

                def locked(source, target):
                    if str(source).endswith(".zip.part"):
                        attempts.append(source)
                        if len(attempts) == 1:
                            raise PermissionError(13, "synthetic sharing violation")
                    return real(source, target)

                with patch.object(updater.os, "replace", locked), patch.object(updater.time, "sleep"):
                    if valid:
                        self.assertEqual(self.prepare()["state"], "ready")
                    else:
                        with self.assertRaises(updater.UpdateError) as caught:
                            self.prepare()
                        self.assertEqual(caught.exception.code, "update_checksum_mismatch")
                self.assertEqual(len(attempts), 2)
                self.assertEqual(tree(self.install), before)

    def test_runs_the_way_the_launcher_starts_it(self):
        """两端都用 python -I 直接跑 updater.py：同目录的模块要自己能找到。"""
        self.publish(hashlib.sha256(self.zip).hexdigest())
        run = __import__("subprocess").run([sys.executable, "-B", "-I", updater.__file__, "check", "--platform", "windows", "--current", "0.1.0"], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(json.loads(run.stdout)["available"])

    def test_bad_signature_downloads_nothing(self):
        self.publish(hashlib.sha256(self.zip).hexdigest(), secret=bytes([7]) * 32)
        Handler.hits = []
        with self.assertRaises(updater.UpdateError) as caught:
            self.prepare()
        self.assertEqual(caught.exception.code, "update_bad_signature")
        self.assertNotIn("/pkg", Handler.hits)

    def test_manifest_for_another_version_is_refused(self):
        self.publish(hashlib.sha256(self.zip).hexdigest(), version="9.9.8")
        with self.assertRaises(updater.UpdateError) as caught:
            self.prepare()
        self.assertEqual(caught.exception.code, "update_bad_signature")

    def test_oversized_download_is_stopped(self):
        name = "S2Arm-windows-x64.zip"
        raw, signature = signed("9.9.9", {name: {"sha256": hashlib.sha256(self.zip).hexdigest(), "size": 10}})
        self.publish(hashlib.sha256(self.zip).hexdigest())
        Handler.routes["/m"], Handler.routes["/s"] = raw, signature
        with self.assertRaises(updater.UpdateError) as caught:
            self.prepare()
        self.assertEqual(caught.exception.code, "update_checksum_mismatch")

    def test_disk_full_stops_before_download(self):
        with patch.object(updater.shutil, "disk_usage", return_value=type("U", (), {"free": 1})()), patch.object(updater, "download", side_effect=AssertionError):
            with self.assertRaises(updater.UpdateError) as caught:
                self.prepare()
        self.assertEqual(caught.exception.code, "update_disk_full")

    def test_unpack_space_uses_exact_unpacked_size_not_multiples(self):
        # 剃刀 H17：解开前按解开后的确切大小要空间。手算：同一块盘上包 100、解开 150 → 要 max(150, 2×150−100)=200；
        #   盘剩 210 → 过（旧规则下载前就要 4×100=400，被拒）；剩 190 → update_disk_full。不同盘：各要 150
        free = {}
        usage = lambda path: type("U", (), {"free": free[str(path)]})()
        same = self.private / "updates"; same.mkdir(parents=True, exist_ok=True)
        with patch.object(updater.shutil, "disk_usage", side_effect=usage):
            free[str(same)] = 210
            updater.require_unpack_space(same, same / "S2Arm", 150, 100)
            free[str(same)] = 190
            with self.assertRaises(updater.UpdateError) as caught:
                updater.require_unpack_space(same, same / "S2Arm", 150, 100)
            self.assertEqual(caught.exception.code, "update_disk_full")
            other = self.install.resolve().parent
            with patch.object(updater.os, "stat", side_effect=lambda p, *a, **k: type("S", (), {"st_dev": 1 if Path(p) == same else 2})()):
                free[str(same)], free[str(other)] = 150, 150
                updater.require_unpack_space(same, self.install, 150, 100)
                free[str(other)] = 149
                with self.assertRaises(updater.UpdateError):
                    updater.require_unpack_space(same, self.install, 150, 100)

    def test_download_needs_only_the_package_up_front(self):
        # 剃刀 H17：下载前只要放得下安装包本身（旧规则 4 倍）：盘剩 = 包大小 → 照样下载、解开、就绪
        size = len(self.zip)
        real = updater.shutil.disk_usage
        with patch.object(updater.shutil, "disk_usage", side_effect=lambda p: type("U", (), {"free": size if Path(p) == self.private / "updates" else real(p).free})()), \
                patch.object(updater, "require_unpack_space"):
            self.assertEqual(self.prepare()["state"], "ready")

    def test_already_latest_failure_carries_message(self):
        # 剃刀 W11：每个失败都带后端的 message（前端优先显示它；原先 Windows 前端查表，update_none 没有文案键，显示原样键名）。
        #   当前版本 = 发布的版本 → prepare 失败事件 code=update_none、message「已经是最新版本。」
        with patch("builtins.print") as out:
            self.assertEqual(updater.main(["prepare", "--platform", "windows", "--current", "9.9.9", "--private-root", str(self.private), "--install", str(self.install)]), 1)
        last = json.loads(out.call_args.args[0])
        self.assertEqual((last["state"], last["code"], last["message"]), ("failed", "update_none", "已经是最新版本。"))

    def test_network_failure_is_reported_by_main_and_keeps_old(self):
        before = tree(self.install)
        Handler.routes["/pkg"] = None
        with patch("builtins.print") as out:
            code = updater.main(["prepare", "--platform", "windows", "--current", "0.1.1", "--private-root", str(self.private), "--install", str(self.install)])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out.call_args.args[0])["state"], "failed")
        self.assertEqual(tree(self.install), before)

    def test_checks_share_cache_but_each_prepare_queries_now(self):
        """「有没有新版」15 分钟内只调一次查版本接口（匿名每 IP 每小时 60 次，共享出口容易被限流）；真下载（prepare，玩家点了更新 / 重试）每次现查，
        不拿缓存（剃刀 H18：热修发出后 15 分钟内查不到、查完到下载之间撤版报 update_none）。期望：check 两次 1 次 + prepare 两次各 1 次 = 3 次"""
        Handler.hits = []
        with patch.object(updater, "LATEST_TTL", 900):
            with patch("builtins.print"):
                updater.main(["check", "--platform", "windows", "--current", "0.1.1"])
                updater.main(["check", "--platform", "windows", "--current", "0.1.1"])
            Handler.routes["/pkg"] = None   # 第一次下载失败
            with patch("builtins.print"):
                self.assertEqual(updater.main(["prepare", "--platform", "windows", "--current", "0.1.1", "--private-root", str(self.private), "--install", str(self.install)]), 1)
            self.publish(hashlib.sha256(self.zip).hexdigest())   # 恢复，玩家点重试
            self.assertEqual(self.prepare()["state"], "ready")
        self.assertEqual(Handler.hits.count("/latest"), 3)

    def test_prepare_survives_throttled_and_cut_download_then_verifies_and_unpacks(self):
        """限速 + 每次只给五分之一就掐断连接下安装包：续传接上，校验（签名清单的 SHA-256）、解包都过，进入可重启更新"""
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ThrottledDropHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        cut = len(self.zip) // 5 + 1
        ThrottledDropHandler.body, ThrottledDropHandler.cut, ThrottledDropHandler.ranges = self.zip, cut, []
        p = patch.object(updater, "RETRY_SECONDS", 0); p.start(); self.addCleanup(p.stop)
        latest = json.loads(Handler.routes["/latest"])
        latest["assets"][0]["browser_download_url"] = f"http://127.0.0.1:{server.server_port}/pkg"
        Handler.routes["/latest"] = json.dumps(latest).encode()
        result = self.prepare()
        self.assertEqual(result["state"], "ready")
        self.assertEqual(ThrottledDropHandler.ranges, [i * cut for i in range(5)])   # 断了 4 次，每次从断开处接着下
        self.assertEqual((Path(result["staged"]) / "S2Arm.exe").read_text(), "new")   # 解包出的新版

    def test_data_inside_install_is_refused(self):
        inside = self.install / "MyLibrary"; inside.mkdir()
        with self.assertRaises(updater.UpdateError) as caught:
            self.prepare([inside])
        self.assertEqual(caught.exception.code, "update_data_inside_install")

    def test_zip_slip_is_refused(self):
        evil = self.root / "evil.zip"
        with zipfile.ZipFile(evil, "w") as z:
            z.writestr("../../escape", "x")
        target = self.root / "out"; target.mkdir()
        with self.assertRaises(updater.UpdateError):
            updater.extract_windows(evil, target)
        self.assertFalse((self.root / "escape").exists())


class DeltaTests(Base):
    def setUp(self):
        super().setUp()
        self.old = self.root / "old"; self.new = self.root / "new"
        for root, body in ((self.old, "v1"), (self.new, "v2")):
            (root / "Engine").mkdir(parents=True); (root / "same").write_text("same")
            (root / "tool").write_text(body); (root / "Engine/data").write_text(body * 1000)
        (self.old / "gone").write_text("x")
        (self.new / "added").write_text("new file")
        if os.name != "nt":
            (self.new / "tool").chmod(0o755); (self.old / "tool").chmod(0o644)
            os.symlink("tool", self.new / "alias")
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close); self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        patcher = patch.dict(os.environ, {"S2A_UPDATE_API": self.base + "/latest", "S2A_UPDATE_PUBKEY": ed25519.public_key(TEST_SECRET).hex()}); patcher.start(); self.addCleanup(patcher.stop)
        self.delta = updater.build_delta(self.old, self.new, "windows", "0.1.1", "9.9.9", self.root)
        full = self.root / "full.zip"
        with zipfile.ZipFile(full, "w") as z:
            z.writestr("S2Arm/S2Arm.exe", "full"); z.writestr("S2Arm/Engine/e", "e"); z.writestr("S2Arm/Runtime/python/python.exe", "py")
        self.full = full.read_bytes()
        self.hits = Handler.hits = []

    def publish(self, delta, in_manifest=True):
        names = {"full": "S2Arm-windows-x64.zip", "delta": self.delta.name}
        files = {names["full"]: {"sha256": hashlib.sha256(self.full).hexdigest(), "size": len(self.full)}}
        if in_manifest:
            files[names["delta"]] = {"sha256": hashlib.sha256(delta).hexdigest(), "size": len(delta)}
        raw, signature = signed("9.9.9", files)
        Handler.routes = {"/latest": json.dumps({"tag_name": "v9.9.9", "assets": [
            {"name": names["full"], "size": 1, "browser_download_url": self.base + "/full"},
            {"name": names["delta"], "size": 1, "browser_download_url": self.base + "/delta"},
            {"name": updater.MANIFEST, "size": 9, "browser_download_url": self.base + "/m"},
            {"name": updater.SIGNATURE, "size": 9, "browser_download_url": self.base + "/s"}]}).encode(),
            "/full": self.full, "/delta": delta, "/m": raw, "/s": signature}

    def prepare(self):
        shutil_rmtree = __import__("shutil").rmtree
        shutil_rmtree(self.install); __import__("shutil").copytree(self.old, self.install, symlinks=True)
        # 差分打完的目录里要有 Runtime/python 才能备 runner：清单里没有，打桩跳过
        with patch("builtins.print") as out, patch.object(updater, "runner_python", return_value=self.root / "py"), patch.object(updater.subprocess, "run", return_value=type("R", (), {"returncode": 0, "stdout": ""})()):
            updater.prepare("windows", "0.1.1", self.private, self.install, [self.private])
        return [json.loads(c.args[0]) for c in out.call_args_list]

    def test_delta_applies_to_a_copy_and_matches_the_new_tree_exactly(self):
        out = self.root / "out"; out.mkdir()
        staged = updater.apply_delta(self.delta, "windows", "0.1.1", "9.9.9", self.old, out)
        self.assertEqual(updater.file_manifest(staged), updater.file_manifest(self.new))
        self.assertTrue((self.old / "gone").exists())   # 原目录不动

    def test_only_changed_files_are_packed(self):
        with zipfile.ZipFile(self.delta) as z:
            self.assertNotIn("files/same", z.namelist())
            self.assertIn("files/tool", z.namelist())

    def test_prepare_uses_delta_and_skips_the_full_package(self):
        self.publish(self.delta.read_bytes()); before = self.data()
        events = self.prepare()
        self.assertEqual(events[-1]["via"], "delta")
        self.assertNotIn("/full", Handler.hits)
        self.assertEqual(updater.file_manifest(events[-1]["staged"]), updater.file_manifest(self.new))
        self.assertEqual(self.data(), before)

    def test_corrupt_delta_falls_back_to_full(self):
        self.publish(b"not a zip")
        events = self.prepare()
        self.assertIn("deltaFailed", [e["state"] for e in events])
        self.assertEqual(events[-1]["via"], "full")
        self.assertEqual((Path(events[-1]["staged"]) / "S2Arm.exe").read_text(), "full")

    def test_delta_outside_the_signed_manifest_is_ignored(self):
        self.publish(self.delta.read_bytes(), in_manifest=False)
        events = self.prepare()
        self.assertEqual(events[-1]["via"], "full")
        self.assertNotIn("/delta", Handler.hits)

    def test_changed_install_falls_back_to_full(self):
        out = self.root / "out"; out.mkdir()
        (self.old / "same").write_text("edited by something")
        with self.assertRaises(updater.UpdateError):
            updater.apply_delta(self.delta, "windows", "0.1.1", "9.9.9", self.old, out)

    def test_paths_and_links_cannot_leave_the_app(self):
        for target in ({"../evil": {"sha256": "0"}}, {"a/../../evil": {"sha256": "0"}}, {"/etc/x": {"sha256": "0"}}, {"a\\b": {"sha256": "0"}}, {"C:/x": {"sha256": "0"}},
                       {"l": {"link": "/etc/passwd"}}, {"l": {"link": "../../x"}}, {"a/l": {"link": "../../x"}}):
            with self.subTest(target=target), self.assertRaises(updater.UpdateError):
                updater.check_target(target)
        updater.check_target({"Contents/Frameworks/P.framework/Python": {"link": "Versions/Current/Python"}, "a/b": {"link": "../c"}, "a/f": {"sha256": "0"}})

    def test_release_tools_import_and_reference_real_names(self):
        sys.path.insert(0, str(Path(updater.__file__).resolve().parents[2] / "tools"))
        import make_update_delta, sign_update_manifest
        self.assertEqual(make_update_delta.SUMS, "SHA256SUMS.txt")
        (self.old / "S2Arm-windows-x64.zip").write_text("pkg"); (self.old / "S2Arm-mac-arm64-delta-0.1.1.zip").write_text("d"); (self.old / "other.txt").write_text("no")
        files = json.loads(sign_update_manifest.build(self.old, "9.9.9"))["files"]
        self.assertEqual(sorted(files), ["S2Arm-mac-arm64-delta-0.1.1.zip", "S2Arm-windows-x64.zip"])

    def test_delta_for_another_version_is_refused(self):
        out = self.root / "out"; out.mkdir()
        with self.assertRaises(updater.UpdateError):
            updater.apply_delta(self.delta, "windows", "0.1.0", "9.9.9", self.old, out)


class RunnerTests(unittest.TestCase):
    def test_apply_needs_no_network_modules(self):
        """updates/runner 的 Python 在 Mac 上没有 ssl：导入 updater 不能带进来。"""
        code = "import sys; sys.path.insert(0, %r); import updater; print([m for m in ('ssl', 'urllib.request', 'zipfile', '_hashlib') if m in sys.modules])" % str(Path(updater.__file__).parent)
        self.assertEqual(__import__("subprocess").run([sys.executable, "-I", "-c", code], capture_output=True, text=True).stdout.strip(), "[]")


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
    """启动器公告条（v0.2.3）：官方下载页优先、取不到用随包那份、关掉的同一条不再给、换号再出现、已撤 / 无效不显示。期望手写"""
    ITEM = {"schema": 1, "id": "n1", "text": {"zh-Hans": "中文公告", "en": "English notice"}, "url": "https://github.com/jhaizhou-ops/S2Arm#readme"}

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.bundled = self.root / "notice.json"; self.bundled.write_text(json.dumps(dict(self.ITEM, id="bundled")), encoding="utf-8")
        self.private = self.root / "private"

    def show(self, remote):
        return updater.notice(self.private, remote=lambda: remote, bundled=self.bundled)

    def test_remote_first_then_bundled(self):
        self.assertEqual(self.show((True, updater.notice_valid(self.ITEM)))["id"], "n1")
        self.assertEqual(self.show((False, None))["id"], "bundled")   # 没网 / 页面不通
        self.assertEqual(self.show((False, None))["text"], {"zh-Hans": "中文公告", "en": "English notice"})

    def test_retracted_remote_wins_over_bundled(self):   # 页面取到了、但已撤（只剩 schema）：不显示，不退回随包那份
        self.assertIsNone(self.show((True, updater.notice_valid({"schema": 1}))))

    def test_dismissed_stays_hidden_until_a_new_id(self):
        updater.notice_dismiss(self.private, "n1")
        self.assertIsNone(self.show((True, updater.notice_valid(self.ITEM))))
        self.assertEqual(self.show((True, updater.notice_valid(dict(self.ITEM, id="n2"))))["id"], "n2")

    def test_invalid_shapes_are_not_shown(self):
        for bad in ({"schema": 2, "id": "a", "text": self.ITEM["text"]}, {"schema": 1, "text": self.ITEM["text"]},
                    {"schema": 1, "id": "a b", "text": self.ITEM["text"]}, {"schema": 1, "id": "a", "text": {"zh-Hans": "只有中文"}},
                    {"schema": 1, "id": "a", "text": {"zh-Hans": " ", "en": "x"}}, [], "x"):
            with self.subTest(bad=bad):
                self.assertIsNone(updater.notice_valid(bad))

    def test_link_only_official_https(self):
        for url, kept in (("https://github.com/jhaizhou-ops/S2Arm", True), ("https://jhaizhou-ops.github.io/S2Arm/", True),
                          ("http://github.com/x", False), ("https://s2arm.com/", True), ("https://evil.s2arm.com.example/", False), ("http://s2arm.com/", False), ("javascript:alert(1)", False)):
            with self.subTest(url=url):
                self.assertEqual("url" in updater.notice_valid(dict(self.ITEM, url=url)), kept)

    def test_cli_prints_empty_object_when_nothing_to_show(self):
        import io, contextlib
        self.bundled.unlink()
        with patch.object(updater, "notice_file", return_value=self.bundled), patch.object(updater, "notice_remote", return_value=(False, None)):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(updater.main(["notice", "--private-root", str(self.private)]), 0)
        self.assertEqual(json.loads(out.getvalue()), {})
        self.assertFalse((self.private / "logs").exists())   # 公告与更新无关：不写 update.log

    def test_shipped_notice_is_valid(self):   # 仓库里那份（Pages 发布 + 随包兜底）要能显示，带官方链接
        item = updater.notice_valid(json.loads(updater.notice_file().read_text(encoding="utf-8")))
        self.assertIsNotNone(item); self.assertIn("url", item)
        self.assertIn("s2arm.com", item["text"]["zh-Hans"]); self.assertIn("s2arm.com", item["text"]["en"])


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

    def fetch(self, r2, gh=(200, {}, b"package")):
        """fetch_package：R2 回 r2、GitHub 回 gh；清单写的是「package」这 7 字节的 sha256"""
        import hashlib
        ScriptedHandler.scripts.update({"/r2/pkg": [r2], "/gh/pkg": [gh]})
        info = {"asset": self.base + "/r2/pkg", "assetFallback": self.base + "/gh/pkg", "sha256": hashlib.sha256(b"package").hexdigest()}
        target = Path(self.tmp.name) / "pkg.zip"
        for name, value in (("emit", lambda **_: None), ("RETRY_SECONDS", 0)):
            p = patch.object(updater, name, value); p.start(); self.addCleanup(p.stop)
        updater.fetch_package(info, target, 7)
        return target

    def test_r2_ok_is_used_and_github_untouched(self):
        self.assertEqual(self.fetch((200, {}, b"package")).read_bytes(), b"package")
        self.assertNotIn("/gh/pkg", ScriptedHandler.hits)

    def test_r2_down_falls_back_to_github(self):
        self.assertEqual(self.fetch((404, {}, b"")).read_bytes(), b"package")
        self.assertEqual([h for h in ScriptedHandler.hits if h.endswith("/pkg")], ["/r2/pkg", "/gh/pkg"])

    def test_r2_oversized_falls_back_to_github(self):
        self.assertEqual(self.fetch((200, {}, b"package-too-long")).read_bytes(), b"package")
        self.assertIn("/gh/pkg", ScriptedHandler.hits)

    def test_r2_tampered_content_is_an_error_without_fallback(self):
        """长度对、内容被改：sha256 不对 → 报错并删掉，不去 GitHub 重下"""
        with self.assertRaises(updater.UpdateError) as caught:
            self.fetch((200, {}, b"PACKAGE"))
        self.assertEqual(caught.exception.code, "update_checksum_mismatch")
        self.assertNotIn("/gh/pkg", ScriptedHandler.hits)
        self.assertFalse((Path(self.tmp.name) / "pkg.zip").exists())

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
