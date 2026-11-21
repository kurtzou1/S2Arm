"""G01: real worker protocol plus synthetic failure/recovery fixtures; no games.

夹具在 jobcase.JobCase（10-26 起）。新用例按功能放 tests/test_<功能>.py（test_target / test_import / test_build / test_devicectl …），
不再往本文件追加：本文件曾是全仓库最常冲突的文件之一，几支同时在同一处加用例，列车里接连互撞（10-26 一晚退回 4 支）。"""
import contextlib
import errno
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
import zipfile
from unittest.mock import Mock, patch

from jobcase import JOBS, ROOT, JobCase
from core import Context, Failure, atomic
from errors import RECOVERY, explain
import library
import toolchain
import ipa
import target


class ErrorRecoveryTests(JobCase):

    def test_invalid_keys_preserve_previous_then_corrected_request_succeeds(self):
        self.import_keys()
        before = self.c.keys.read_bytes()
        invalid = self.root / "invalid.keys"
        invalid.write_text("header_key = invalid")
        result, failed = self.worker("keys", path=str(invalid))
        self.assertEqual(result.returncode, 1)
        self.assert_failure(failed, "keys_invalid")
        self.assertEqual(self.c.keys.read_bytes(), before)
        invalid.write_bytes(before)
        result, fixed = self.worker("keys", path=str(invalid))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixed["state"], "succeeded")
        self.assertEqual(fixed["diagnostics"], [])

    def test_missing_keys_then_import_succeeds_without_replacing_saves(self):
        self.install_reader_fixture()
        source = self.root / "source.nsp"
        source.write_bytes(b"synthetic game fixture")
        _, failed = self.worker("import", paths=[str(source)])
        self.assert_failure(failed, "keys_missing")
        save = self.c.library / "saves/keep"
        save.parent.mkdir(); save.write_bytes(b"player progress fixture")
        self.import_keys()
        result, fixed = self.worker("import", paths=[str(source)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixed["state"], "succeeded")
        self.assertEqual(save.read_bytes(), b"player progress fixture")
        self.assertEqual(source.read_bytes(), b"synthetic game fixture")

    def test_binary_keys_are_invalid_and_do_not_replace_previous_keys(self):
        self.import_keys()
        before = self.c.keys.read_bytes()
        invalid = self.root / "invalid.keys"; invalid.write_bytes(b"\xff\xfe\x00")
        _, failed = self.worker("keys", path=str(invalid))
        self.assert_failure(failed, "keys_invalid")
        self.assertEqual(self.c.keys.read_bytes(), before)

    def test_missing_keys_file_is_keys_invalid_not_our_file_missing(self):
        # 诊断#c719ce：选的 prod.keys 已经不在（被移动 / 删除 / iCloud 没下载），原先 stat 抛 FileNotFoundError 落到 job_failed，
        #   报成「S2Arm 自己的文件找不到了」。期望手写：报 keys_invalid、说是选的密钥文件找不到、让玩家重新选；原有密钥不变
        self.import_keys()
        before = self.c.keys.read_bytes()
        _, failed = self.worker("keys", path=str(self.root / "gone" / "prod.keys"))
        diagnostic = self.assert_failure(failed, "keys_invalid")
        self.assertIn("找不到", json.dumps(diagnostic, ensure_ascii=False)); self.assertIn("重新选择", json.dumps(diagnostic, ensure_ascii=False))
        self.assertEqual(self.c.keys.read_bytes(), before)

    def test_specific_reader_error_replaces_tool_exit_and_preserves_evidence(self):
        self.import_keys(); self.install_reader_fixture()
        source = self.root / "source.nsp"
        source.write_bytes(b"unreadable fixture")
        result, failed = self.worker("import", paths=[str(source)])
        self.assertEqual(result.returncode, 1)
        diagnostic = self.assert_failure(failed, "content_unreadable")
        self.assertEqual(diagnostic["exitCode"], 3)
        self.assertEqual([d["code"] for d in failed["diagnostics"]], ["content_unreadable"])
        self.assertNotIn("synthetic-bearer", json.dumps(failed))
        self.assertIn("可能", diagnostic["summary"])
        source.write_bytes(b"corrected fixture")
        result, fixed = self.worker("import", paths=[str(source)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixed["diagnostics"], [])

    def test_missing_unsupported_and_empty_inputs_have_distinct_codes(self):
        self.import_keys()
        unsupported = self.root / "note.txt"; unsupported.write_text("not a game")
        empty = self.root / "empty"; empty.mkdir()
        for source, code in ((self.root / "missing.nsp", "input_missing"),
                             (unsupported, "input_type_unsupported"), (empty, "input_empty")):
            with self.subTest(code=code):
                _, failed = self.worker("import", paths=[str(source)])
                self.assert_failure(failed, code)

    def test_unknown_tool_exit_keeps_real_exit_code_in_final_diagnostic(self):
        self.import_keys(); self.install_reader_fixture()
        source = self.root / "unknown.nsp"; source.write_bytes(b"unknown exit fixture")
        _, failed = self.worker("import", paths=[str(source)])
        diagnostic = self.assert_failure(failed, "tool_exit")
        self.assertEqual(diagnostic["exitCode"], 17)
        self.assertEqual(len(failed["diagnostics"]), 1)

    def test_post_tool_exception_links_exception_log_not_old_tool_output(self):
        self.import_keys(); self.install_reader_fixture()
        source = self.root / "disappear.nsp"; source.write_bytes(b"disappear fixture")
        _, failed = self.worker("import", paths=[str(source)])
        diagnostic = self.assert_failure(failed, "input_missing")
        self.assertTrue(diagnostic["logPath"].endswith("-exception.log"))
        self.assertIn("FileNotFoundError", diagnostic["detail"])

    def test_output_callback_failure_propagates_after_fast_successful_child(self):
        def broken(line):
            raise ValueError("synthetic callback failure")
        with patch("threading.excepthook"), self.assertRaisesRegex(ValueError, "synthetic callback failure"):
            self.c.run([sys.executable, "-c", "print('fixture', flush=True)"], on_line=broken)
        self.assertFalse(self.c.children)

    def test_reader_io_failure_propagates_after_child_exit(self):
        import winproc
        spawn = winproc.popen if os.name == 'nt' else subprocess.Popen
        fixture = [sys.executable, "-c", "print('fixture')"]
        def unreadable_pipe(*args, **kwargs):
            child = spawn(*args, **kwargs)
            # 只给被测的那个子进程装坏管道：Popen 是整个 subprocess 模块打的桩，收尾 reap_session 里的 /bin/ps 也走这里，
            #   原先它也被等 5 秒、输出过管道缓冲（本机进程多时 ps -A 超 64 KB）就超时，两次收尾每例白等 10 秒、残留进程也没真收（11-14 门禁提速）
            if list(args[0]) != fixture:
                return child
            child.wait(timeout=5)
            child.stdout = Mock(wraps=child.stdout)
            child.stdout.readline.side_effect = OSError(errno.EIO, "synthetic pipe read failure")
            child.stdout.read1.side_effect = OSError(errno.EIO, "synthetic pipe read failure")   # 现在按 CR/LF 切块读（core.output_lines）
            return child
        injection = "core.winproc.popen" if os.name == 'nt' else "core.subprocess.Popen"
        with patch(injection, side_effect=unreadable_pipe), \
             self.assertRaisesRegex(OSError, "synthetic pipe read failure"):
            self.c.run([sys.executable, "-c", "print('fixture')"])
        self.assertFalse(self.c.children)

    def test_callback_failure_stops_running_child_and_removes_tracking(self):
        children = []
        def broken(line):
            children.extend(self.c.children)
            raise ValueError("synthetic callback failure")
        # Bound the pre-fix failure as well: a swallowed callback exception must
        # not leave the test sleeping indefinitely or leave its child running.
        # The judgment is our own output, not wall-clock time (a loaded host stretches any time
        # bound): the run must end through the callback-failure path, never through this backstop.
        backstop = threading.Event()
        def stop_by_backstop():
            backstop.set()
            self.c.stop()
        timer = threading.Timer(20, stop_by_backstop)
        timer.start()
        try:
            with patch("threading.excepthook"), self.assertRaisesRegex(ValueError, "synthetic callback failure"):
                self.c.run([sys.executable, "-c", "import time; print('fixture', flush=True); time.sleep(30)"], on_line=broken)
        finally:
            timer.cancel()
        self.assertFalse(backstop.is_set(), "the child was stopped by the backstop timer, not by the callback-failure path")
        self.assertTrue(children)
        self.assertTrue(all(child.poll() is not None for child in children))
        self.assertFalse(self.c.children)

    def test_callback_failure_is_failed_in_real_worker_and_persisted_record(self):
        # Inject only a synthetic operation, retaining the real main/Context,
        # process runner, terminal events, exception log and persistent record.
        entry = self.root / "callback-worker.py"
        entry.write_text(f'''import sys
sys.path.insert(0, {str(JOBS)!r})
import main
def operation(c):
    c.begin("Synthetic callback fixture")
    def broken(line):
        raise ValueError("synthetic callback failure")
    c.run([sys.executable, "-c", "print('fixture', flush=True)"], on_line=broken)
    return {{}}
main.toolchain.download_metal = operation
raise SystemExit(main.main())
''')
        result, terminal = self.worker("downloadMetal", entrypoint=entry)
        self.assertEqual(result.returncode, 1)
        diagnostic = self.assert_failure(terminal, "job_failed")
        self.assertIn("ValueError", diagnostic["detail"])
        self.assertIn("synthetic callback failure", diagnostic["detail"])

    def test_requirement_diagnostics_keep_all_causes_and_legacy_messages(self):
        game = dict(id="0100000000000000", name="fixture", packages=[dict(type="update", titleId="0100000000000800",
                    version=1, path="sources/missing.nsp", sha256="0" * 64)])
        errors = library.requirement_errors(self.c, game)
        self.assertEqual([e.code for e in errors], ["input_base_missing", "input_missing"])
        self.assertEqual(library.requirements(self.c, game), [str(e) for e in errors])
        atomic(self.c.library / "catalog.json", dict(schema=1, games=[game]))
        _, failed = self.worker("build", gameId=game["id"])
        self.assertEqual([d["code"] for d in failed["diagnostics"]], ["input_base_missing", "input_missing"])
        self.assert_failure(failed, "input_missing")
        game["packages"][0].update(type="base", guestIsa="aarch32")
        self.assertEqual(library.requirement_errors(self.c, game)[0].code, "guest_isa_unsupported")

    def test_os_failures_use_errno_not_message_guessing(self):
        for number, code in ((errno.ENOSPC, "disk_full"), (errno.EDQUOT, "disk_full")):
            with self.subTest(errno=number):
                self.assertEqual(explain(OSError(number, "unrelated localized text")).code, code)
        # 启动器剃刀 H8（11-11）：「原件不见了」「去系统设置授权」只给玩家侧路径。期望按路径手写：
        #   原件下 ENOENT / EACCES → input_missing / permission_denied；游戏库下 EROFS → permission_denied；游戏库根整个不在 → input_missing；
        #   私有目录（任务记录 / 日志）下 ENOENT / EACCES、不带路径的 → job_failed，原文与路径进 internal（旧代码一律归 input_missing / permission_denied）
        src, lib, private = self.root / "h8-originals", self.root / "h8-lib", self.root / "h8-private"
        src.mkdir(); lib.mkdir(); private.mkdir()
        cases = ((errno.ENOENT, src / "game.nsp", "input_missing"), (errno.EACCES, src / "game.nsp", "permission_denied"),
                 (errno.EROFS, lib / "games/x/build", "permission_denied"),
                 (errno.ENOENT, private / "logs/t1-import.log", "job_failed"), (errno.EACCES, private / "jobs/t1.json", "job_failed"),
                 (errno.ENOENT, None, "job_failed"))
        for number, path, code in cases:
            with self.subTest(errno=number, path=path):
                error = OSError(number, "unrelated localized text", str(path)) if path else OSError(number, "unrelated localized text")
                got = explain(error, sources=[src], library=lib)
                self.assertEqual(got.code, code)
                if code == "job_failed" and path:
                    self.assertIn(str(path), got.internal)
        self.assertEqual(explain(FileNotFoundError(errno.ENOENT, "x", str(lib / "catalog.json")), sources=[src], library=self.root / "unplugged").code,
                         "input_missing")   # 游戏库根整个不在 = 外接盘没插
        self.assertEqual(explain(Failure("No space left on device")).code, "job_failed")
        self.assertEqual(explain(ValueError("Check keys")).code, "job_failed")

    def test_windows_app_control_block_named(self):
        # #0745b9：Windows 应用控制（4551 智能应用控制 / WDAC、1260 组策略、225 / 226 杀毒软件）拦下我们自带的工具 → app_control_blocked，
        #   上屏点名被拦的工具（winproc.popen 补的文件名）；原先落到「本地任务失败，请检查日志和输入」。errno 写成 EACCES 也先认应用控制
        for code_w in (4551, 1260, 225, 226):
            with self.subTest(winerror=code_w):
                e = OSError(errno.EACCES, "应用程序控制策略已阻止此文件。", r"C:\S2Arm\Engine\tools\nx_reader.exe")
                e.winerror = code_w
                got = explain(e)
                self.assertEqual(got.code, "app_control_blocked")
                self.assertIn("「nx_reader.exe」", str(got))
                self.assertIn({4551: "智能应用控制", 1260: "组策略"}.get(code_w, "杀毒软件"), str(got))
                self.assertIn(f"WinError {code_w}", got.internal)
        e = OSError(errno.EINVAL, "x"); e.winerror = 4551
        self.assertIn("「S2Arm 自带的工具」", str(explain(e)), "不带文件名照样认")
        self.assertIn("app_control_blocked", RECOVERY)

    def test_orch_spawn_or_link_denied_is_app_control(self):
        # D-GVDA / #1912（Windows 0.6.3）：出包「准备资源」起随包预编的 Yaz0 编码器被拒（编排层子进程里，错误只剩回溯文字），
        #   同机建 RomFS 目录链接（junction）也被拒：都归 app_control_blocked，不再落笼统的 package_failed。原文取自诊断（路径已脱敏）
        import errors
        spawn = ('一键出包失败（八个轻阶段）：light.log：rc=1；    File "subprocess.py", line 1538, in _execute_child /   '
                 'PermissionError: [WinError 5] 拒绝访问。 / 【红】编排中止：[WinError 5] 拒绝访问。')
        junction = ('    File "[SOURCE]\\pack\\orch\\roots.py", line 109, in _junction\n    raise C.WinError(C.get_last_error())\n'
                    '  PermissionError: [WinError 5] 拒绝访问。\n【红】编排中止：[WinError 5] 拒绝访问。')
        for label, text in (("起编码器被拒", spawn), ("建 junction 被拒", junction)):
            with self.subTest(label):
                code, why = errors.classify_failure("ipa", None, [text])
                self.assertEqual(code, "app_control_blocked", why)
                self.assertEqual(errors.player_reason(code), "被 Windows 拦下：Windows 的应用控制或杀毒软件没让 S2Arm 自带的工具运行。")
        for w in (4551, 225):   # 编排层里应用控制原号同样认
            self.assertEqual(errors.classify_failure("ipa", None, [f'line 1538, in _execute_child / PermissionError: [WinError {w}] x'])[0], "app_control_blocked")
        # 反证：别处的拒绝访问（改名 / 删文件）不算拦工具，照旧不归 app_control_blocked
        other = '  File "x.py", line 3, in replace\n  PermissionError: [WinError 5] 拒绝访问。: \'D:\\a\' -> \'D:\\b\''
        self.assertNotEqual(errors.classify_failure("ipa", None, [other])[0], "app_control_blocked")

    def test_missing_prebuilt_tool_is_app_control(self):
        # D-VPXS / #1912（Windows 0.6.3）：随包 rewriter\\s2a-rewrite.exe 不在了（旁边的 .source 还在），改写阶段退回现编、报「CMake 未就绪」；
        #   失败归因时对随包清单 prepare.json：缺的、被清空的列出来，归 app_control_blocked。期望按构造手写：清单 3 个文件，删 1 个、清空 1 个
        import errors
        tools = self.root / "Prepare"; (tools / "rewriter").mkdir(parents=True); (tools / "codecs").mkdir()
        (tools / "rewriter" / "s2a-rewrite.exe.source").write_text("x" * 65)
        (tools / "codecs" / "yaz0enc-1.exe").write_bytes(b"")          # 清单记 4 字节，盘上被清空
        (tools / "codecs" / "libyaz0dec.dll").write_bytes(b"abcd")
        (tools / "prepare.json").write_text(json.dumps({"schema": 1, "source": "x", "files": {
            "rewriter\\s2a-rewrite.exe": [1547776, "0" * 64], "rewriter\\s2a-rewrite.exe.source": [65, "0" * 64],
            "codecs/yaz0enc-1.exe": [4, "0" * 64], "codecs/libyaz0dec.dll": [4, "0" * 64]}}))
        env = {"S2A_PREBUILT_TOOLS": str(tools)}
        self.assertEqual(sorted(errors.missing_prebuilt(env)), ["codecs/yaz0enc-1.exe", "rewriter\\s2a-rewrite.exe"])
        with patch.dict(os.environ, env):
            code, why = errors.classify_failure("ipa", None, ["light.log：rc=75；【黄】winenv：自动源码改写器固定依赖/CMake 未就绪；不下载"])
        self.assertEqual(code, "app_control_blocked", why)
        self.assertIn("s2a-rewrite.exe", why); self.assertIn("2 个", why)
        # 反证：清单里的都在、大小对 → 不归它（照旧按阶段）；没给 S2A_PREBUILT_TOOLS（Mac / 源码树）→ 不查
        (tools / "codecs" / "yaz0enc-1.exe").write_bytes(b"abcd"); (tools / "rewriter" / "s2a-rewrite.exe").write_bytes(b"\0" * 1547776)
        self.assertEqual(errors.missing_prebuilt(env), [])
        with patch.dict(os.environ, env):
            self.assertNotEqual(errors.classify_failure("ipa", None, ["light.log：rc=75；【黄】winenv：自动源码改写器固定依赖/CMake 未就绪；不下载"])[0], "app_control_blocked")
        self.assertEqual(errors.missing_prebuilt({}), [])

    def test_windows_metal_version_unreadable(self):
        # D-TYCN（Windows 0.6.3）：编着色器库前核工具读不到 metal.exe 版本，原先落笼统的 package_failed + 开发者口吻的 --update-lock 提示。
        #   起进程被拒 → app_control_blocked；文件不在 / 起来没打版本 → win_metal_missing（原文取自诊断与 dmsh_chain.tools_now 的写法）
        import errors
        head = "[直连库] 🔴 出库前核工具 / 链号失败：dmsh_chain.py 退出码 1：[RED] translation chain tools do not match the lock file: "
        lock = "metal_macosx: lock Apple metal version 32023.883 (metalfe-32023.883) / actual "
        for tail, want in (("missing", "win_metal_missing"),
                           ("missing (no version output: exit code 0xc0000135)", "win_metal_missing"),
                           ("missing (start blocked: [WinError 5] 拒绝访问。)", "app_control_blocked")):
            with self.subTest(tail):
                code, why = errors.classify_failure("ipa", None, [head + lock + tail])
                self.assertEqual(code, want, why)
        self.assertEqual(errors.player_reason("win_metal_missing"), "缺少Windows版Metal工具：未找到能报告有效版本的官方Windows版Metal编译器。")
        # 反证：版本不同（不是 missing）不归这两个码
        self.assertNotIn(errors.classify_failure("ipa", None, [head + lock + "Apple metal version 32100.1 (metalfe-32100.1)"])[0], ("win_metal_missing", "app_control_blocked"))

    def test_unrecognized_volume_during_classification_does_not_mask_original_error(self):
        lib = self.root / "classify-volume-lib"
        src = self.root / "classify-volume-src"
        lib.mkdir(); src.mkdir()
        missing_cache = lib / "games" / "Absolum" / "build" / "extract"
        original = FileNotFoundError(errno.ENOENT, "synthetic missing cache", str(missing_cache))

        def unrecognized_volume(*args, **kwargs):
            error = OSError(errno.EIO, "synthetic unrecognized volume")
            error.winerror = 1005
            raise error

        with patch("errors.os.path.realpath", side_effect=unrecognized_volume):
            got = explain(original, sources=[src], library=lib)
        self.assertEqual(got.code, "job_failed")
        self.assertIn(str(missing_cache), got.internal)

    def test_unrecognized_volume_check_does_not_mark_library_as_missing(self):
        lib = self.root / "classify-stat-lib"
        src = self.root / "classify-stat-src"
        lib.mkdir(); src.mkdir()
        original_stat = os.stat

        def stat_with_unrecognized_volume(path, *args, **kwargs):
            if os.fspath(path) == str(lib):
                error = OSError(errno.EIO, "synthetic unrecognized volume", str(lib))
                error.winerror = 1005
                raise error
            return original_stat(path, *args, **kwargs)

        missing_cache = lib / "games" / "fixture" / "build" / "extract"
        original = FileNotFoundError(errno.ENOENT, "synthetic missing cache", str(missing_cache))
        with patch("errors.os.stat", side_effect=stat_with_unrecognized_volume):
            got = explain(original, sources=[src], library=lib)
        self.assertEqual(got.code, "job_failed")

    def test_non_os_error_keeps_type_message_and_location(self):
        # #372 / #854（Windows 0.3.9 报修打包 AttributeError）：不是 OSError 的异常原先连原文一起丢，玩家复制的摘要里只剩「本地任务失败」。
        #   期望手写：上屏原句不变、码 job_failed；internal 带「AttributeError: <原文>」和抛出处（本测试文件:那一行 in 函数名）
        def boom():
            return SimpleNamespace().st_mtime
        try:
            boom()
        except AttributeError as e:
            got = explain(e)
        line = boom.__code__.co_firstlineno + 1
        self.assertEqual((str(got), got.code), ("本地任务失败，请检查日志和输入。", "job_failed"))
        self.assertIn("AttributeError: 'types.SimpleNamespace' object has no attribute 'st_mtime'", got.internal)
        self.assertIn(f"（test_error_recovery.py:{line} in boom）", got.internal)

    def test_pack_space_shortfall_warns_and_preserves_old_runtime(self):
        # 11-14 不许堵门：预估不够只记一条 disk_full 警告、不拦；现有运行版本不动
        game = dict(packages=[])
        old = self.c.library / "games/working/keep"; old.parent.mkdir(parents=True); old.write_text("working")
        with patch("shutil.disk_usage") as usage:
            usage.return_value.free = 1
            library.check_pack_space(self.c, game)
            self.assertEqual([(d["code"], d["severity"]) for d in self.c.job["diagnostics"]], [("disk_full", "warning")])
            usage.return_value.free = 100 << 30
            library.check_pack_space(self.c, game)
        self.assertEqual(old.read_text(), "working")

    def test_tool_missing_and_missing_working_directory_are_not_confused(self):
        with self.assertRaises(Failure) as raised:
            self.c.run([self.root / "missing-tool"])
        self.assertEqual(raised.exception.code, "tool_missing")
        with self.assertRaises(FileNotFoundError) as raised:
            self.c.run([sys.executable, "-c", "pass"], cwd=self.root / "missing-cwd")
        # 启动器剃刀 H8：工作目录是 S2Arm 自己的，不是原件 → 本地任务失败（旧代码说「原件不见了、去接磁盘」）
        self.assertEqual(explain(raised.exception, **self.c.failure_roots()).code, "job_failed")
        self.c.run([sys.executable, "-c", "print('fixed')"])
        self.assertIn("fixed", self.c.last_log.read_text())

    def test_permission_failure_then_recovery_uses_same_tool(self):
        binary = self.root / ("tool.py" if os.name == "nt" else "tool")
        binary.write_text("raise SystemExit(0)\n" if os.name == "nt" else "#!/bin/sh\nexit 0\n")
        binary.chmod(0o600)
        with self.subTest(step="execute permission"):
            if os.name == "nt":
                self.skipTest("Windows 无执行权限位")
            with self.assertRaises(PermissionError) as raised:
                self.c.run([binary])
            # 启动器剃刀 H8：S2Arm 自己的工具没执行权限 → 本地任务失败，不指玩家去系统设置授权
            self.assertEqual(explain(raised.exception, **self.c.failure_roots()).code, "job_failed")
        binary.chmod(0o700)
        self.c.run([sys.executable, binary] if os.name == "nt" else [binary])

    def test_unknown_failure_and_warning_do_not_hide_root_error(self):
        self.c.diagnostic("warning fixture", severity="warning")
        diagnostic = self.c.report_failure(Failure("warning fixture"))
        self.assertEqual(diagnostic["code"], "job_failed")
        self.assertEqual(self.c.job["diagnostics"][-1]["severity"], "error")

    def test_redaction_covers_headers_urls_json_and_terminal_messages(self):
        raw = 'Authorization: Bearer synthetic-token\nhttps://name:synthetic-pass@example.invalid\n{"token":"json-secret"}\n' + str(self.root)
        diagnostic = self.c.report_failure(Failure(raw))
        self.c.finish("failed", diagnostic["summary"])
        events = self.output.getvalue()
        for secret in ("synthetic-token", "synthetic-pass", "json-secret"):
            self.assertNotIn(secret, events)

    def test_redaction_covers_quoted_spaces_internal_quotes_and_json_escapes(self):
        fixtures = ['password=synthetic\'credential', 'password=synthetic"credential',
                    'password="synthetic credential"', "password='synthetic credential'",
                    'password="synthetic"credential', "password='synthetic'credential",
                    r'{"token":"synthetic\"credential"}']
        for raw in fixtures:
            with self.subTest(raw=raw):
                redacted = self.c.redact(raw)
                self.assertNotIn("synthetic", redacted)
                self.assertNotIn("credential", redacted)

    def test_switch_key_assignments_are_redacted_but_nca_ids_are_preserved(self):
        value = "89abcdef" * 4
        rights_id = "01234567" * 4
        names = ["master_kek_00", "titlekek_05", "eticket_rsa_kek", "mariko_kek",
                 "tsec_root_kek_02", "master_seed_00", "key_area_key_application_00", "header_key"]
        for name in names:
            with self.subTest(name=name):
                result = self.c.redact(f"{name} = {value}")
                self.assertNotIn(value, result)
                self.assertIn("[REDACTED]", result)
        for line in (f"{rights_id} = {value}", f"  {rights_id.upper()} = {value.upper()} # title.keys\r\n"):
            result = self.c.redact(line)
            self.assertNotIn(value.lower(), result.lower())
            self.assertIn("[REDACTED]", result)
        nca = f"Missing NCA {value}.nca"
        self.assertEqual(self.c.redact(nca), nca)

    def test_switch_keys_are_redacted_from_final_events_and_exported_logs(self):
        value = "89abcdef" * 4
        rights_id = "01234567" * 4
        nca_id = "fedcba98" * 4
        log = self.c.logs / "switch-key-fixture.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(f"master_kek_00 = {value}\nmaster_seed_00 = {value}\n{rights_id} = {value}\nMissing NCA {nca_id}.nca\n")
        self.c.last_log = log
        diagnostic = self.c.report_failure(Failure("synthetic failure"))
        self.c.finish("failed", diagnostic["summary"])
        self.assertNotIn(value, self.output.getvalue())
        destination = self.root / "diagnostics.zip"
        self.c.r["path"] = str(destination)
        library.diagnostics(self.c)
        with zipfile.ZipFile(destination) as archive:
            text = "\n".join(archive.read(name).decode() for name in archive.namelist())
        self.assertNotIn(value, text)
        self.assertIn(nca_id, text)

    def test_rewrite_failure_saves_gap_digest_into_diagnostics(self):   # #108：明细在产物根 .failed/，诊断包要带上摘要
        import zipfile
        log = self.root / "failed_main.log"
        log.write_text("main 自旋区 105 个\n" + "GAP\tmain\t0x100\tsys: 异常类指令 d46f9025（hvc / smc / dcps）苹果用户态不可用\n" * 3
                       + "GAP\tmain\t0x200\tsys: mrs 系统寄存器 S3_6_C9_C13_6：不在白名单\n", encoding="utf-8")
        self.c.report_failure(Failure(f"【红】t0100 改写 main 失败（rc=3：PFRW mod=main need=9 gaps=4 fatal=0；日志 {log}）", code="rewrite_gap"))
        destination = self.root / "diag.zip"
        self.c.finish("failed", "x"); self.c.r["path"] = str(destination); library.diagnostics(self.c)
        with zipfile.ZipFile(destination) as archive:
            member = next(n for n in archive.namelist() if n.endswith("-rewrite-gaps.log"))
            text = archive.read(member).decode()
        self.assertIn("改写缺口共 4 条", text); self.assertIn("3\tsys: 异常类指令", text); self.assertIn("main 自旋区 105 个", text)

    def test_target_failures_keep_specific_codes_through_ipa_adapter(self):
        for arch, osv, sdk, code in (("applegpu_g12p", 26, 27, "target_unsupported"),
                                    ("applegpu_g17p", 17, 27, "target_unsupported")):   # 系统下限 iOS 18（10-26）：17 拒
            with self.subTest(code=code, arch=arch, os=osv):
                self.c.r["target"] = dict(model="fixture", gpuArch=arch, os=osv)
                # 预检清单 #40 #41（11-13）：目标那台跑不了也照出包（一包通用），只记一条带码的提醒；码的处理建议照旧有
                with patch.object(target, "os_choices", return_value=[sdk]), patch.object(self.c, "diagnostic") as warn:
                    self.assertEqual(ipa.resolve_target(self.c)["gpuArch"], arch)
                self.assertEqual((warn.call_args.kwargs["code"], warn.call_args.kwargs["severity"]), (code, "warning"))
                self.assertTrue(self.c.describe_failure(Failure(warn.call_args.args[0], code=code))["suggestion"])
        self.c.r["target"]["os"] = 26
        with patch.object(target, "os_choices", return_value=[26]):
            self.assertEqual(ipa.resolve_target(self.c)["os"], 26)

    def test_recovery_guidance_matches_packaged_or_development_request(self):
        for code in ("dotnet_unavailable", "reader_unavailable", "engine_incomplete", "tool_missing"):
            with self.subTest(code=code):
                self.c.r["engineBundle"] = "synthetic-bundle"
                packaged = self.c.describe_failure(Failure("fixture", code=code))["suggestion"]
                self.assertNotIn("开发", packaged)
                self.assertNotIn("源码", packaged)
                self.assertIn("重新安装", packaged)
                self.c.r.pop("engineBundle")
                development = self.c.describe_failure(Failure("fixture", code=code))["suggestion"]
                self.assertNotEqual(packaged, development)
                self.assertNotIn("完整应用", development)

    def test_content_recovery_keeps_player_steps_and_both_possible_causes(self):
        for text in (library.KEYS_CANNOT_DECRYPT, RECOVERY["content_unreadable"]):
            for step in ("Switch", "重新导出", "设置 → 玩家密钥", "重新导入", "文件"):
                self.assertIn(step, text)

    def test_preflight_codes_actions_logs_and_recovery(self):
        developer = self.root / "Xcode.app/Contents/Developer"
        (developer / "usr/bin").mkdir(parents=True)
        (developer / "usr/bin/xcodebuild").touch()
        self.c.r["developerDir"] = str(developer)
        def probe(c, args, timeout=15):
            if "metal" in args:
                return self.metal_ok, "Apple metal version fixture" if self.metal_ok else self.metal_error
            return True, "10.0.403"
        self.metal_ok = False; self.metal_error = "license agreement not accepted"
        with patch.object(toolchain, "probe", probe), patch.object(toolchain, "reader", return_value=Path("fixture.dll")), \
             patch("platform.mac_ver", return_value=("26.0", (), "")):
            failed = {r["name"]: r for r in toolchain.preflight(self.c)["checks"]}
            self.assertEqual(failed["Metal 编译组件"]["diagnostic"]["code"], "xcode_setup_required")
            self.assertEqual(failed["Metal 编译组件"]["action"], "openXcode")
            self.assertTrue(Path(failed["Metal 编译组件"]["diagnostic"]["logPath"]).is_file())
            self.metal_error = "compiler component unavailable"
            missing = {r["name"]: r for r in toolchain.preflight(self.c)["checks"]}
            self.assertEqual(missing["Metal 编译组件"]["diagnostic"]["code"], "metal_unavailable")
            self.metal_ok = True
            fixed = {r["name"]: r for r in toolchain.preflight(self.c)["checks"]}
            self.assertTrue(fixed["Metal 编译组件"]["ok"])
            self.assertNotIn("diagnostic", fixed["Metal 编译组件"])
            self.c.r["developerDir"] = str(self.root / "missing-xcode")
            missing = {r["name"]: r for r in toolchain.preflight(self.c)["checks"]}
            self.assertEqual(missing["Xcode"]["diagnostic"]["code"], "xcode_unavailable")
            self.assertEqual(missing["Xcode"]["action"], "appStoreXcode")

    # T75 (#739): test real failure sites and specific recovery semantics.
    # A nonempty fallback is insufficient: removing a RECOVERY entry must fail.
    def assert_t75_recovery(self, diagnostic, code, *steps):
        self.assertEqual(diagnostic["code"], code)
        self.assertTrue(diagnostic["suggestion"])
        self.assertNotEqual(diagnostic["suggestion"], RECOVERY["job_failed"])
        for step in steps:
            self.assertIn(step, diagnostic["suggestion"])

    def t75_preflight(self, *, machine="arm64", version="26.0", sdk=True):
        # Mock external probes only; preflight's checks, code mapping and
        # Context.describe_failure remain production code. No Apple tools run.
        developer = self.root / "synthetic-Xcode/Contents/Developer"
        (developer / "usr/bin").mkdir(parents=True)
        (developer / "usr/bin/xcodebuild").touch()
        self.c.r["developerDir"] = str(developer)
        def probe(c, args, timeout=15):
            return True, "Apple metal version fixture" if "metal" in args else "10.0.403"
        with patch("platform.system", return_value="Darwin"), \
             patch("platform.machine", return_value=machine), \
             patch("platform.mac_ver", return_value=(version, (), "")), \
             patch.object(toolchain, "probe", side_effect=probe), \
             patch.object(toolchain, "reader", return_value=Path("synthetic-reader.dll")), \
             patch.object(toolchain, "input_interface", return_value=(True, "fixture")), \
             patch.object(self.c, "require_source"), \
             patch.object(ipa, "dotnet_sdk", return_value=(developer, developer / "dotnet") if sdk else (None, None)):
            return {row["name"]: row for row in toolchain.preflight(self.c)["checks"]}

    def test_t75_content_invalid_recovery(self):
        # Invalid metadata, not invalid real game/key material.
        def reader_output(*args, **kwargs):
            kwargs["on_line"]('{"schema":1,"packages":[]}')
        with patch.object(library, "validate_keys"), \
             patch.object(toolchain, "reader", return_value=Path("synthetic-reader.dll")), \
             patch.object(self.c, "run", side_effect=reader_output), \
             self.assertRaises(Failure) as raised:
            library.inspect(self.c, self.root / "synthetic-input", self.root / "icons")
        self.assert_t75_recovery(self.c.describe_failure(raised.exception), "content_invalid",
                                 "文件是否完整", "重新导入", "保留对应日志")

    def test_t75_intel_mac_can_package_iphone(self):
        row = self.t75_preflight(machine="x86_64")["Apple Silicon"]
        self.assertTrue(row["ok"])
        self.assertIn("Intel Mac", row["message"])
        self.assertIn("iPhone", row["message"])

    def test_t75_os_unsupported_recovery(self):
        row = self.t75_preflight(version="14.7")["macOS"]
        self.assertFalse(row["ok"])
        self.assert_t75_recovery(row["diagnostic"], "os_unsupported",
                                 "macOS 15", "支持的系统", "重新检查环境")

    def test_t75_dotnet_sdk_missing_recovery(self):
        row = self.t75_preflight(sdk=False)[".NET SDK（打 iPhone 包）"]
        self.assertFalse(row["ok"])
        self.assertEqual(row["action"], "installDotnet")
        self.assertEqual(row["requiredFor"], ["ipa"])
        self.assert_t75_recovery(row["diagnostic"], "dotnet_sdk_missing",
                                 ".NET 10 SDK", "重新检查", "iPhone 包")

    def test_t75_runtime_invalid_recovery(self):
        import build
        with self.assertRaises(Failure) as raised:
            build.validate_files(self.c, self.root / "synthetic-runtime", {})
        self.assert_t75_recovery(self.c.describe_failure(raised.exception), "runtime_invalid",
                                 "重新打包", "保留原有存档", "打包成功后再启动")

    def test_unknown_future_code_has_fallback_guidance(self):
        # Check the handoff contract too: unknown future codes retain fallback
        # guidance, rather than crashing a legacy consumer.
        self.assertTrue(self.c.describe_failure(Failure("future", code="future_code"))["suggestion"])



class SourceMissingCause(unittest.TestCase):
    def test_unpack_source_missing_is_input_missing(self):
        # 诊断#24fb13：解包读原件时路径不在（外置盘没连上 / 原件挪走），原先按阶段 unpack 落成 content_invalid「文件没下完整」。
        #   期望：解包工具的分类行「【原因 source_missing】」→ input_missing，上屏句说原件找不到、下一步是接盘或重新放进来
        import errors
        text = "🔴 找不到源文件（Could not find a part of the path 'E:\\x\\game.nsp'.）：原件被挪走或删掉了……\n【原因 source_missing】\n"
        code, why = errors.classify_failure("unpack", None, [text])
        self.assertEqual(code, "input_missing", why)
        self.assertIn("找不到游戏文件", errors.player_reason(code))
        self.assertEqual(errors.classify_failure("unpack", None, ["🔴 读源文件失败（x）\n【原因 io】\n"])[0], "content_invalid", "别的读盘错照旧按阶段")

if __name__ == "__main__":
    unittest.main()
