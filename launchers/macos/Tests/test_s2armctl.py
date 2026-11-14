"""Offline regressions for wait's task selection (no App, game or network)."""
import contextlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "s2armctl", Path(__file__).resolve().parents[1] / "s2armctl.py")
ctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctl)


def task(identifier, state, started, game="game", operation="build"):
    return {"id": identifier, "state": state, "started": started,
            "gameId": game, "operation": operation}


def state(*tasks, queue=(), error=None):
    # Same task/queue fields serialized by ControlServer.state().
    return {"tasks": list(tasks), "queue": list(queue), "error": error}


class StartFailureTests(unittest.TestCase):
    def run_start(self, why, stale=False):
        now = [0]
        with tempfile.TemporaryDirectory() as root:
            error = Path(root) / "control.error"
            def launch(*_args, **_kwargs):
                error.write_text(why, encoding="utf-8")
                if not stale:
                    os.utime(error, (2000, 2000))
            if stale:
                error.write_text("上一次的错", encoding="utf-8")
                os.utime(error, (1000, 1000))
            def sleep(seconds):
                now[0] += seconds
            with mock.patch.object(ctl, "ROOT", root), mock.patch.object(ctl, "WINDOWS", False), \
                 mock.patch.object(ctl, "info", side_effect=SystemExit("no control")), \
                 mock.patch.object(ctl.subprocess, "run", side_effect=None if stale else launch), \
                 mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), \
                 mock.patch.object(ctl.time, "sleep", side_effect=sleep), \
                 self.assertRaises(SystemExit) as caught:
                ctl.start("/Applications/S2Arm.app")
        return str(caught.exception.code), now[0]

    def test_reason_is_reported_without_waiting(self):
        message, waited = self.run_start("Private job root inherits permissions.")
        self.assertIn("Private job root inherits permissions.", message)
        self.assertIn("还不存在的路径", message)
        self.assertEqual(waited, 0)

    def test_other_reason_gets_no_data_root_advice(self):
        message, _ = self.run_start("地址已被占用")
        self.assertEqual(message, "控制口没起来：地址已被占用")

    def test_failure_from_an_earlier_start_is_ignored(self):
        message, waited = self.run_start("", stale=True)
        self.assertIn("60 秒内控制口没就绪", message)
        self.assertNotIn("上一次的错", message)
        self.assertGreaterEqual(waited, 60)


class LogsRootTests(unittest.TestCase):
    """剃刀 H6：日志 / 任务记录固定 <数据目录>/logs，库建没建好、设置里选了哪个库都不变（同作业层 core.logs_root）"""
    def test_rules(self):
        with tempfile.TemporaryDirectory() as root, mock.patch.object(ctl, "ROOT", root), mock.patch.object(ctl, "WINDOWS", False):
            lib = Path(root) / "lib"; lib.mkdir()
            (Path(root) / "preferences.json").write_text(json.dumps({"library": str(lib)}))
            self.assertEqual(ctl.logs_root(), os.path.join(root, "logs"))
            (lib / ".s2arm-library.json").write_text("{}")
            self.assertEqual(ctl.logs_root(), os.path.join(root, "logs"))


class TaskLogTests(unittest.TestCase):
    def test_build_logs_command_reads_the_nested_stage_log(self):
        with tempfile.TemporaryDirectory() as root:
            stage = Path(root) / "logs" / "build-task" / "refresh.log"
            stage.parent.mkdir(parents=True)
            stage.write_text("第一行\n第二行\n第三行\n", encoding="utf-8")
            record = task("build-task", "running", 1)
            output = io.StringIO()
            with mock.patch.object(ctl, "ROOT", root), \
                    mock.patch.object(ctl, "call", return_value=state(record)), \
                    mock.patch.object(ctl.sys, "argv", ["s2armctl", "logs", "build-task", "--lines", "2"]), \
                    contextlib.redirect_stdout(output):
                ctl.main()
            self.assertIn(str(stage), output.getvalue())
            self.assertIn("第二行\n第三行", output.getvalue())
            self.assertNotIn("第一行", output.getvalue())

    def test_game_reference_reads_the_latest_tasks_nested_log(self):
        with tempfile.TemporaryDirectory() as root:
            logs = Path(root) / "logs"
            logs.mkdir()
            (logs / "old-game.log").write_text("old run", encoding="utf-8")
            stage = logs / "new" / "extract.log"
            stage.parent.mkdir()
            stage.write_text("new build", encoding="utf-8")
            output = io.StringIO()
            with mock.patch.object(ctl, "ROOT", root), \
                    mock.patch.object(ctl, "call", return_value=state(
                        task("old", "completed", 1, operation="launch"),
                        task("new", "running", 2))), \
                    contextlib.redirect_stdout(output):
                ctl.logs("game", 40)
            self.assertIn("new build", output.getvalue())
            self.assertNotIn("old run", output.getvalue())

    def test_newest_log_is_selected_across_flat_and_nested_layouts(self):
        with tempfile.TemporaryDirectory() as root:
            logs = Path(root) / "logs"
            nested = logs / "job" / "refresh.log"
            nested.parent.mkdir(parents=True)
            flat = logs / "job-failure.log"
            nested.write_text("stage", encoding="utf-8")
            flat.write_text("failure", encoding="utf-8")
            with mock.patch.object(ctl, "ROOT", root):
                os.utime(nested, (200, 200))
                os.utime(flat, (100, 100))
                self.assertEqual(ctl.task_log("job"), str(nested))
                os.utime(flat, (300, 300))
                self.assertEqual(ctl.task_log("job"), str(flat))

    def test_flat_game_log_still_works_and_other_tasks_are_ignored(self):
        with tempfile.TemporaryDirectory() as root:
            logs = Path(root) / "logs"
            logs.mkdir()
            game = logs / "launch-game.log"
            game.write_text("game", encoding="utf-8")
            unrelated = logs / "other" / "refresh.log"
            unrelated.parent.mkdir()
            unrelated.write_text("other task", encoding="utf-8")
            with mock.patch.object(ctl, "ROOT", root):
                self.assertEqual(ctl.task_log("launch"), str(game))
                self.assertIsNone(ctl.task_log("missing"))

    def test_log_named_directories_are_not_returned_as_files(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / "logs" / "job-empty.log").mkdir(parents=True)
            with mock.patch.object(ctl, "ROOT", root):
                self.assertIsNone(ctl.task_log("job"))


class WaitTests(unittest.TestCase):
    def run_wait(self, states, operation="build", limit=10):
        now = [0]

        def sleep(seconds):
            now[0] += seconds

        output = io.StringIO()
        with mock.patch.object(ctl, "call", side_effect=states) as call, \
                mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), \
                mock.patch.object(ctl.time, "sleep", side_effect=sleep), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
            ctl.wait("game", operation, limit)
        return result.exception.code, call.call_count, output.getvalue()

    def test_space_override_flag_reaches_the_app(self):
        for argv, path, body in [
                (["build", "G", "mac", "--space-override"], "/build", {"gameId": "G", "target": "mac", "spaceOverride": True}),
                (["build", "G", "--space-override"], "/build", {"gameId": "G", "target": "ios", "spaceOverride": True}),
                (["build", "G", "ios"], "/build", {"gameId": "G", "target": "ios"}),
                (["ipa", "G", "--space-override"], "/ipa", {"gameId": "G", "spaceOverride": True}),
                (["ipa", "G"], "/ipa", {"gameId": "G"})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), \
                    mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", path, body)

    def test_install_passes_team_and_device_only_when_given(self):
        for argv, body in [(["install", "G", "--no-wait"], {"gameId": "G"}),
                           (["install", "G", "--team", "ABCDE12345", "--no-wait"], {"gameId": "G", "teamId": "ABCDE12345"}),
                           (["install", "G", "--device", "测试 iPhone", "--team", "ABCDE12345", "--no-wait"],
                            {"gameId": "G", "teamId": "ABCDE12345", "device": "测试 iPhone"}),
                           # 三个确认开关各自进请求体（--accept-stale 原先只在帮助里有、请求体漏了）
                           (["install", "G", "--accept-dropped", "--accept-no-backup", "--accept-stale", "--no-wait"],
                            {"gameId": "G", "acceptDropped": True, "acceptNoBackup": True, "acceptStale": True})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", "/install", body)

    def test_update_phone_passes_accept_dropped_only_when_given(self):
        # 同 install --accept-dropped：玩家同意让别的电脑装的款这次带不上（v0.3.0 只换壳验收：原先 update-phone 没有这个入口，永远过不去）
        for argv, body in [(["update-phone", "--accept-stale", "--ask"], {"acceptStale": True, "ask": True}),
                           (["update-phone", "--accept-stale", "--device", "测试 iPhone", "--accept-dropped", "--ask"],
                            {"acceptStale": True, "ask": True, "device": "测试 iPhone", "acceptDropped": True})]:
            with mock.patch.object(ctl, "call", side_effect=[{"tasks": []}, {"ok": True, "asked": True}]) as call, \
                    mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_with("POST", "/update-phone", body)

    def run_install(self, after):
        """install 默认等这次作业结束：发命令前已有一个上次成功的装机任务 old，之后出现的才是这次的"""
        old = {"id": "old", "gameId": "G", "operation": "install", "state": "completed", "started": 1, "ended": 2}
        states = [{"tasks": [old]}, {"ok": True}, {"tasks": [old], "error": "", "cachedAt": 0}] + [{"tasks": [old] + after, "error": "", "cachedAt": 0}] * 3
        output = io.StringIO(); now = [0]
        with mock.patch.object(ctl, "call", side_effect=lambda *a, **k: states.pop(0) if states else {"tasks": [old] + after, "error": "", "cachedAt": 0}), \
                mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), mock.patch.object(ctl.time, "sleep", side_effect=lambda x: now.__setitem__(0, now[0] + x)), \
                mock.patch.object(ctl, "errors") as errors, mock.patch.object(ctl.sys, "argv", ["s2armctl", "install", "G", "--timeout", "30"]), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
            ctl.main()
        return result.exception.code, errors.call_count, output.getvalue()

    def test_install_failure_exits_1_with_error_details(self):
        code, errors, out = self.run_install([{"id": "new", "gameId": "G", "operation": "install", "state": "failed", "started": 5, "ended": 6, "message": "手机上有几款是在别的电脑上装的"}])
        self.assertEqual((code, errors), (1, 1))   # 11-10：原先打 {"ok": true} 就退 0
        self.assertIn("failed", out)

    def test_install_success_exits_0(self):
        code, errors, _ = self.run_install([{"id": "new", "gameId": "G", "operation": "install", "state": "completed", "started": 5, "ended": 6}])
        self.assertEqual((code, errors), (0, 0))

    def test_install_does_not_take_last_runs_result(self):
        # 这次的任务还没出现：只有上一次成功的 old，不能据此退 0，要等到超时
        code, _, _ = self.run_install([])
        self.assertIsInstance(code, str); self.assertIn("没结束", code)

    def test_cloud_commands_reach_the_app(self):
        # iCloud 存档：cloud-folder 给绝对路径、不给 = 关闭（空串）；cloud-sync 带游戏号
        for argv, path, body in [(["cloud-folder", "/tmp/云盘"], "/cloudFolder", {"path": "/tmp/云盘"}),
                                 (["cloud-folder"], "/cloudFolder", {"path": ""}),
                                 (["cloud-sync", "G"], "/cloudSync", {"gameId": "G"})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", path, body)

    def test_customize_sends_only_what_was_given(self):
        for argv, body in [(["customize", "G", "--name", "新名"], {"gameId": "G", "name": "新名"}),
                           (["customize", "G", "--reset-cover"], {"gameId": "G", "coverPath": ""}),
                           (["customize", "G", "--reset-name"], {"gameId": "G", "name": ""})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", "/customize", body)
        with mock.patch.object(ctl, "call") as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", "customize", "G"]):
            with self.assertRaises(SystemExit):
                ctl.main()
        call.assert_not_called()

    def test_queued_then_running_then_completed(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old, task("new", "running", 3)),
                  state(old, task("new", "completed", 3))]
        code, calls, output = self.run_wait(states)
        self.assertEqual((code, calls), (0, 3))
        self.assertIn("queued", output)
        self.assertIn("running", output)

    def test_new_failure_overrides_old_success(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old, task("new", "failed", 3))]
        self.assertEqual(self.run_wait(states)[:2], (1, 2))

    def test_queue_before_task_refresh_does_not_report_history_or_stale_error(self):
        old = task("old", "completed", 1)
        states = [state(old, queue=["game"], error="another task failed"),
                  state(old, task("new", "running", 3)),
                  state(old, task("new", "failed", 3))]
        self.assertEqual(self.run_wait(states)[:2], (1, 3))

    def test_cancelled_queue_is_failure(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old)]
        code, calls, output = self.run_wait(states)
        self.assertEqual((code, calls), (1, 2))
        self.assertIn("排队已取消", output)

    def test_cancelled_queue_before_task_refresh_is_failure(self):
        old = task("old", "completed", 1)
        self.assertEqual(self.run_wait([state(old, queue=["game"]), state(old)])[:2], (1, 2))

    def test_late_history_before_queue_does_not_count_as_new_work(self):
        states = [state(task("queued-game", "queued", 2), queue=["game"]),
                  state(task("old", "completed", 1))]
        self.assertEqual(self.run_wait(states)[:2], (1, 2))

    def test_cancelled_queue_record_after_refresh_is_failure(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old, task("queued-game", "cancelled", 2))]
        self.assertEqual(self.run_wait(states)[:2], (1, 2))

    def test_other_game_does_not_block_or_override_result(self):
        states = [state(task("old", "completed", 1),
                        task("queued-other", "queued", 4, game="other"), queue=["other"])]
        self.assertEqual(self.run_wait(states)[:2], (0, 1))

    def test_build_queue_does_not_block_ipa_wait(self):
        states = [state(task("ipa", "completed", 1, operation="ipa"),
                        task("queued-game", "queued", 4), queue=["game"])]
        self.assertEqual(self.run_wait(states, operation="ipa")[:2], (0, 1))

    def test_history_without_queue_keeps_failure(self):
        self.assertEqual(self.run_wait([state(task("old", "failed", 1))])[:2], (1, 1))

    def test_queue_without_task_times_out(self):
        states = [state(task("old", "completed", 1), queue=["game"])] * 2
        code, calls, _ = self.run_wait(states, limit=3)
        self.assertEqual(calls, 2)
        self.assertIsInstance(code, str)
        self.assertIn("3 秒内没结束", code)





def full_state(**over):
    # ControlServer.state() 里 next_step 读到的字段：环境、密钥、游戏（含 baseBytes）、任务、目标设备、系统授权
    s = {"waitingForAccess": None, "checkingEnvironment": False, "environmentReady": True, "checks": [],
         "hasImportedKeys": True, "games": [], "tasks": [], "iphoneTarget": {"productType": "iPhone18,2", "os": 27}}
    s.update(over)
    return s


def game(identifier, name, base_bytes, buildable=True, ready=False, missing=()):
    return {"id": identifier, "name": name, "baseBytes": base_bytes, "buildable": buildable, "ready": ready, "missing": list(missing)}


class NextStepTests(unittest.TestCase):
    """AI 代操作入口 next（10-26）：期望按规则手写——每种状态推出的 step / who / 命令"""

    def test_windows_iphone_ready_without_task_ipa_path_goes_to_install(self):
        # 共享 S2Arm.ipa 不会记录为这款任务的 ipaPath；iphoneReady 才是已出包信号。
        ready = dict(game("g", "G", 1e9), iphoneReady=True)
        completed = {"id": "done-ipa", "gameId": "g", "operation": "ipa", "state": "completed", "started": 1, "ended": 2}
        n = ctl.next_step(full_state(platform="windows", games=[ready], tasks=[completed]))
        self.assertEqual((n["step"], n["who"]), ("装机", "ai"))
        self.assertNotIn("出包", n["why"])

    def test_windows_not_iphone_ready_without_ipa_path_still_builds(self):
        # 反例：没有 ipaPath 且从未出好包，Windows 仍应建议出包。
        not_ready = dict(game("g", "G", 1e9), iphoneReady=False)
        n = ctl.next_step(full_state(platform="windows", games=[not_ready]))
        self.assertEqual((n["step"], n["who"]), ("出包", "ai"))

    def test_failed_ipa_does_not_override_previous_iphone_ready_package(self):
        # 最近一次失败不抹掉早先已成功的 iPhone 包。
        ready = dict(game("g", "G", 1e9), iphoneReady=True)
        failed = {"id": "failed-ipa", "gameId": "g", "operation": "ipa", "state": "failed", "started": 1,
                  "diagnostics": [{"code": "job_failed", "summary": "本次出包失败"}]}
        n = ctl.next_step(full_state(platform="windows", games=[ready], tasks=[failed]))
        self.assertEqual((n["step"], n["who"]), ("装机", "ai"))
        self.assertNotIn("code", n)

    def test_no_check_result_yet_means_checking(self):
        # 刚拉起：环境检查还没开始（没有结果、也不在查）→ 让 AI 等，不能报「玩家去处理」却列不出缺什么
        n = ctl.next_step(full_state(environmentReady=False, checks=[], checkingEnvironment=False))
        self.assertEqual((n["step"], n["who"]), ("环境检查", "ai"))
        n = ctl.next_step(full_state(environmentReady=False, checks=[{"name": "Xcode", "ok": False, "message": "没装 Xcode"}]))
        self.assertEqual((n["step"], n["who"]), ("环境", "human")); self.assertIn("没装 Xcode", n["do"])

    def test_keys_then_import_then_pack(self):
        # 空库先问游戏（解包好的游戏不要密钥），NSP / XCI 要密钥时才问
        n = ctl.next_step(full_state(hasImportedKeys=False))
        self.assertEqual((n["step"], n["who"]), ("导入", "ask"))
        n = ctl.next_step(full_state(hasImportedKeys=False, games=[game("g", "G", 1)]))
        self.assertEqual((n["step"], n["who"]), ("密钥", "ask"))
        self.assertIn("s2armctl keys", n["do"])
        n = ctl.next_step(full_state())
        self.assertEqual((n["step"], n["who"]), ("导入", "ask"))
        # 一包通用：没选目标设备也直接出包，不多问一步（11-02 beta.3 走查）
        for tgt in (None, {"model": "iPhone 17 Pro", "gpuArch": "applegpu_g18p", "os": 26}):
            n = ctl.next_step(full_state(games=[game("0100535012974000", "Hades", 6e9)], iphoneTarget=tgt))
            self.assertEqual((n["step"], n["who"], n["game"]), ("出包", "ai", "0100535012974000"))
            self.assertIn("s2armctl build 0100535012974000 ios", n["do"])

    def test_multi_base_picks_largest_and_lists_tools(self):
        # 同一文件夹里的游戏 + 同系列小工具导入后是两款：认本体大的那款，另一款列在 others
        s = full_state(games=[game("0100F9C00EB8C000", "小岛转移工具", 2e6), game("01006F8002326000", "动森", 8e9)])
        n = ctl.next_step(s)
        self.assertEqual(n["game"], "01006F8002326000")
        self.assertEqual(len(n["others"]), 1)
        self.assertIn("0100F9C00EB8C000", n["others"][0])
        self.assertEqual(ctl.next_step(s, "0100F9C00EB8C000")["game"], "0100F9C00EB8C000")

    def test_failed_pack_maps_code_to_action(self):
        failed = {"id": "t1", "gameId": "g", "operation": "ipa", "state": "failed", "started": 1,
                  "diagnostics": [{"code": "disk_full", "summary": "磁盘空间不足", "suggestion": "释放空间", "logPath": "/x.log"}]}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[failed]))
        self.assertEqual((n["step"], n["who"], n["code"]), ("出包失败", "confirm", "disk_full"))
        self.assertIn("s2armctl retry t1", n["do"])   # 任务号代进命令
        failed["diagnostics"] = [{"code": "something_new"}]
        self.assertEqual(ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[failed]))["who"], "ai")   # 没登记的码按缺省：看日志、重试一次

    def test_running_waits_then_install_then_open(self):
        running = {"id": "t2", "gameId": "g", "operation": "ipa", "state": "running", "started": 2, "milestone": "direct"}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[running]))
        self.assertEqual((n["step"], n["who"]), ("等待", "ai"))
        done = {"id": "t3", "gameId": "g", "operation": "ipa", "state": "completed", "started": 3, "ended": 4, "ipaPath": "/lib/iPhone/g/tg.ipa"}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done]))
        # 10-26 装机主路改 Xcode 直签：出完包 AI 自己 install（Xcode 没登录 / 没连设备由 install 报错码再交给玩家）
        self.assertEqual((n["step"], n["who"], n["ipa"]), ("装机", "ai", "/lib/iPhone/g/tg.ipa"))
        self.assertIn("s2armctl install g", n["do"])
        # 装机失败按错误码：Xcode 没登录 → 玩家本人登录；没连设备 → 问玩家连上
        for code, who in (("xcode_account_missing", "human"), ("device_not_connected", "ask"), ("free_app_limit", "human"), ("free_appid_limit", "human"), ("signing_failed", "ai")):
            inst = {"id": "t4", "gameId": "g", "operation": "install", "state": "failed", "started": 5, "diagnostics": [{"code": code, "summary": "x"}]}
            n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done, inst]))
            self.assertEqual((n["step"], n["who"], n["code"]), ("装机失败", who, code))
        # 装好（在这次出包之后）→ 只剩玩家打开游戏
        ok = {"id": "t5", "gameId": "g", "operation": "install", "state": "completed", "started": 6, "ended": 7, "device": "测试设备2"}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done, ok]))
        self.assertEqual((n["step"], n["who"]), ("打开游戏", "human"))
        self.assertIn("测试设备2", n["do"])
        # 之后又出了新包 → 旧的装机不算，重新装
        newer = dict(done, id="t6", started=8, ended=9)
        self.assertEqual(ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done, ok, newer]))["step"], "装机")

    def test_system_permission_and_environment_are_human(self):
        self.assertEqual(ctl.next_step(full_state(waitingForAccess="下载"))["who"], "human")
        n = ctl.next_step(full_state(environmentReady=False, checks=[{"name": "Xcode", "ok": False, "message": "没装"}]))
        self.assertEqual((n["step"], n["who"]), ("环境", "human"))



class NextTargetTests(unittest.TestCase):
    def run_next(self, snapshot, *args):
        out = io.StringIO()
        with mock.patch.object(ctl, "WINDOWS", False), \
             mock.patch.object(sys, "argv", ["s2armctl", "next", *args, "--json"]), \
             mock.patch.object(ctl, "call", return_value=snapshot) as call, \
             contextlib.redirect_stdout(out):
            ctl.main()
        call.assert_called_once_with("GET", "/state")
        return json.loads(out.getvalue())

    def test_ready_mac_game_launches_without_ipa(self):
        s = full_state(games=[game("g", "G", 1, ready=True)],
                       tasks=[task("mac", "completed", 1, game="g")])
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual(n["do"], "s2armctl launch g")

    def test_ready_mac_uses_runtime_environment(self):
        s = full_state(games=[game("g", "G", 1, ready=True)],
                       environmentReady=False, runtimeReady=True, hasImportedKeys=False)
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual(n["do"], "s2armctl launch g")

    def test_ready_mac_reports_own_running_launch(self):
        launch = task("launch-g", "running", 1, game="g", operation="launch")
        s = full_state(games=[game("g", "G", 1, ready=True)],
                       tasks=[launch], executionTask=launch["id"])
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual((n["step"], n["who"]), ("运行中", "human"))
        self.assertEqual(n["task"], "launch-g")
        self.assertEqual(n["do"], "请玩家查看 Mac 上的游戏窗口")

    def test_ready_mac_waits_for_other_execution_tasks(self):
        own_launch = task("launch-g", "running", 1, game="g", operation="launch")
        busy_tasks = (
            task("launch-other", "running", 2, game="other", operation="launch"),
            task("ipa-g", "running", 2, game="g", operation="ipa"),
            dict(own_launch, state="cancelling"),
        )
        for busy in busy_tasks:
            with self.subTest(operation=busy["operation"], game=busy["gameId"], state=busy["state"]):
                tasks = [busy] if busy["id"] == own_launch["id"] else [own_launch, busy]
                s = full_state(games=[game("g", "G", 1, ready=True)],
                               tasks=tasks, executionTask=busy["id"])
                n = self.run_next(s, "g", "--target", "mac")
                self.assertEqual((n["step"], n["who"]), ("等待", "ai"))
                self.assertEqual(n["why"], "构建与游戏运行互斥")

    def test_ready_mac_waits_if_launcher_is_busy(self):
        for busy in ({"executionTask": "other-task"}, {"queue": ["other-game"]}):
            with self.subTest(busy=busy):
                s = full_state(games=[game("g", "G", 1, ready=True)], **busy)
                n = self.run_next(s, "g", "--target", "mac")
                self.assertEqual(n["step"], "等待")
                self.assertIn("s2armctl next g --target mac", n["do"])

    def test_mac_reprepares_stale_artifact(self):
        stale = dict(game("g", "G", 1, ready=True), needsPreparation=True)
        n = self.run_next(full_state(games=[stale]), "g", "--target", "mac")
        self.assertIn("s2armctl build g mac", n["do"])

    def test_mac_game_needs_preparation_even_with_ipa(self):
        ipa = dict(task("ipa", "completed", 1, game="g", operation="ipa"),
                   ipaPath="/lib/iPhone/g/g.ipa")
        s = full_state(games=[game("g", "G", 1)], tasks=[ipa])
        n = self.run_next(s, "--target", "mac", "g")
        self.assertIn("s2armctl build g mac", n["do"])
        self.assertIn("s2armctl wait g --op build", n["do"])

    def test_mac_waits_for_its_build_or_queue_entry(self):
        ipa = task("ipa", "running", 2, game="g", operation="ipa")
        for tasks, queue in (([task("mac", "running", 1, game="g"), ipa], []),
                             ([ipa], ["g"])):
            with self.subTest(queue=queue):
                s = full_state(games=[game("g", "G", 1)], tasks=tasks, queue=queue)
                n = self.run_next(s, "g", "--target", "mac")
                self.assertEqual(n["step"], "等待")
                self.assertIn("s2armctl wait g --op build", n["do"])
                self.assertIn("s2armctl next g --target mac", n["do"])

    def test_mac_reports_build_failure_with_diagnostics(self):
        failed = dict(task("mac", "failed", 1, game="g"),
                      diagnostics=[{"code": "disk_full", "summary": "磁盘空间不足"}])
        s = full_state(games=[game("g", "G", 1)], tasks=[failed])
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual((n["step"], n["who"], n["code"]), ("准备失败", "confirm", "disk_full"))
        self.assertIn("s2armctl retry mac", n["do"])

    def test_explicit_ios_matches_omitted_target(self):
        s = full_state(games=[game("g", "G", 1, ready=True)])
        default = self.run_next(s, "g")
        self.assertIn("s2armctl build g ios", default["do"])
        self.assertEqual(self.run_next(s, "g", "--target", "ios"), default)

    def test_windows_rejects_mac_before_contacting_launcher(self):
        err = io.StringIO()
        with mock.patch.object(ctl, "WINDOWS", True), \
             mock.patch.object(sys, "argv", ["s2armctl", "next", "g", "--target", "mac"]), \
             mock.patch.object(ctl, "call") as call, contextlib.redirect_stderr(err), \
             self.assertRaises(SystemExit) as caught:
            ctl.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("Windows", err.getvalue())
        self.assertIn("--target mac", err.getvalue())
        call.assert_not_called()

    def test_invalid_next_arguments_fail_before_contacting_launcher(self):
        for args in (["--target"], ["--target", "android"], ["g", "extra"], ["--unknown"]):
            with self.subTest(args=args), \
                 mock.patch.object(sys, "argv", ["s2armctl", "next", *args]), \
                 mock.patch.object(ctl, "call") as call, contextlib.redirect_stderr(io.StringIO()), \
                 self.assertRaises(SystemExit) as caught:
                ctl.main()
            self.assertEqual(caught.exception.code, 2)
            call.assert_not_called()


class LaunchArgsTests(unittest.TestCase):
    # 11-02 beta.3 走查：`--control --data-root <目录>` 让 <目录> 落单被 macOS 当成要打开的文件，App 不建窗口。期望：数据目录是一个整体参数，没有落单的路径
    def test_data_root_is_one_token(self):
        args = ctl.launch_args("/A/S2Arm.app", root="/d/数据 目录", custom=True)
        self.assertEqual(args, ["open", "/A/S2Arm.app", "--args", "--control", "--data-root=/d/数据 目录"])
        self.assertTrue(all(a.startswith("-") for a in args[3:]))
        self.assertEqual(ctl.launch_args("/A/S2Arm.app", root="/d", custom=False), ["open", "/A/S2Arm.app", "--args", "--control"])

    def test_uninstall_posts_to_uninstall_endpoint(self):
        """uninstall <游戏号> 走 POST /uninstall {gameId}（与 install 对称）"""
        posted = {}
        def fake_call(method, path, body=None, **kw):
            posted['method'] = method; posted['path'] = path; posted['body'] = body
            return {"ok": True}
        with mock.patch.object(ctl, "call", side_effect=fake_call), \
             mock.patch.object(sys, "argv", ["s2armctl", "uninstall", "0100535012974000"]):
            ctl.main()
        self.assertEqual(posted, {"method": "POST", "path": "/uninstall", "body": {"gameId": "0100535012974000"}})

    def test_accept_dropped_only_when_given(self):
        """--accept-dropped 才带 acceptDropped（玩家同意别的电脑装的款这次带不上）；不给就不带，作业层停下报 container_would_drop"""
        posted = []
        with mock.patch.object(ctl, "call", side_effect=lambda m, p, b=None, **kw: posted.append((p, b)) or {"ok": True}):
            for argv in (["install", "0100535012974000", "--no-wait"], ["install", "0100535012974000", "--accept-dropped", "--no-wait"], ["uninstall", "0100535012974000", "--accept-dropped"]):
                with mock.patch.object(sys, "argv", ["s2armctl", *argv]):
                    ctl.main()
        self.assertEqual(posted, [("/install", {"gameId": "0100535012974000"}), ("/install", {"gameId": "0100535012974000", "acceptDropped": True}),
                                  ("/uninstall", {"gameId": "0100535012974000", "acceptDropped": True})])

class DeviceBundleTests(unittest.TestCase):
    """#642：包里是占位名 io.s2arm.games，手机上装的是 io.s2arm.games.<团队>[.后缀]，device 要按前缀认"""
    def test_container_match(self):
        bid = "io.s2arm.games"
        for installed in ("io.s2arm.games", "io.s2arm.games.7r5l7ty4r7", "io.s2arm.games.abc.dev2"):
            self.assertTrue(ctl.container_match(installed, bid), installed)
        for other in ("io.s2arm.gamesx", "io.s2arm", "com.example.app", ""):
            self.assertFalse(ctl.container_match(other, bid), other)

    def test_device_reports_installed_team_bundle(self):
        dev = {"hardwareProperties": {"udid": "U1"}, "deviceProperties": {"name": "玩家的手机"}}
        apps = {"result": {"apps": [{"bundleIdentifier": "com.example.app"}, {"bundleIdentifier": "io.s2arm.games.7r5l7ty4r7"}]}}
        def fake_dctl(args):
            out = args[args.index("--json-output") + 1]
            Path(out).write_text(json.dumps(apps))
            return subprocess.CompletedProcess(args, 0, "", "")
        buf = io.StringIO()
        with mock.patch.object(ctl, "game_bundle", return_value=("x.ipa", "io.s2arm.games")), \
             mock.patch.object(ctl, "iphone", return_value=[dev]), mock.patch.object(ctl, "dctl", side_effect=fake_dctl), \
             contextlib.redirect_stdout(buf), self.assertRaises(SystemExit):
            ctl.device("0100000000000000")
        self.assertIn("已装 io.s2arm.games.7r5l7ty4r7", buf.getvalue())
        self.assertNotIn("没装", buf.getvalue())


    def test_device_recognises_downstream_app_renamed_at_install(self):
        """下游深度方案的独立 App：包里是下游自己的包名，装机时改成 io.s2arm.ds.<方案>.<团队>。原先按包里的包名查，免费团队装好了也报「没装」"""
        dev = {"hardwareProperties": {"udid": "U1"}, "deviceProperties": {"name": "玩家的手机"}}
        apps = {"result": {"apps": [{"bundleIdentifier": "io.s2arm.ds.d2r-mobile.z6563uvhkk"}, {"bundleIdentifier": "io.s2arm.ds.other.z6563uvhkk"}]}}
        def fake_dctl(args):
            Path(args[args.index("--json-output") + 1]).write_text(json.dumps(apps))
            return subprocess.CompletedProcess(args, 0, "", "")
        ipa = os.path.join("lib", "games", "a", "downstream", "d2r-mobile", "D2RMobile.ipa")
        buf = io.StringIO()
        with mock.patch.object(ctl, "game_bundle", return_value=(ipa, "org.example.downstream")), \
             mock.patch.object(ctl, "iphone", return_value=[dev]), mock.patch.object(ctl, "dctl", side_effect=fake_dctl), \
             contextlib.redirect_stdout(buf), self.assertRaises(SystemExit):
            ctl.device("0100000000000000")
        self.assertIn("已装 io.s2arm.ds.d2r-mobile.z6563uvhkk", buf.getvalue())
        self.assertNotIn("other", buf.getvalue()); self.assertNotIn("没装", buf.getvalue())


class DeviceChoiceTests(unittest.TestCase):
    """设备号贯穿（11-11 真机验收测出）：install-check 能带 --device；targets 列出设备名、设备号与连接方式（两台同型号时只看机型分不出）"""
    def test_install_check_sends_device(self):
        sent = []
        def call(method, path, body=None, **kw):
            if method == "POST": sent.append((path, body)); return {"ok": True}
            return {"installReadiness": {"gameId": "G", "checkedDevice": "U-1", "ready": True, "items": []}}
        with mock.patch.object(ctl, "call", side_effect=call), contextlib.redirect_stdout(io.StringIO()):
            for kw in (dict(device="U-1"), {}):
                with self.assertRaises(SystemExit): ctl.install_check("G", False, **kw)   # 查完按 ready 退出
        self.assertEqual(sent, [("/installCheck", {"gameId": "G", "device": "U-1"}), ("/installCheck", {"gameId": "G"})])

    def test_install_check_waits_for_the_requested_device(self):
        """同一款上一台的清单还挂在 state 里：带 --device 时等到给这台查的那份才读，不拿上一台的（11-11 真机验收：连查两台，第二台读到第一台的结果）"""
        states = iter([{"gameId": "G", "checkedDevice": "U-OLD", "ready": False, "items": [{"ok": False, "waiting": False, "title": "旧", "detail": "旧那台没找到", "who": "human"}]},
                       {"gameId": "G", "checkedDevice": "U-NEW", "ready": True, "items": [{"ok": True, "waiting": False, "title": "新那台已连上", "detail": "", "who": "human"}]}])
        def call(method, path, body=None, **kw):
            return {"ok": True} if method == "POST" else {"installReadiness": next(states)}
        buf = io.StringIO()
        with mock.patch.object(ctl, "call", side_effect=call), mock.patch.object(ctl.time, "sleep"), contextlib.redirect_stdout(buf), \
             self.assertRaises(SystemExit) as done:
            ctl.install_check("G", False, device="U-NEW")
        self.assertEqual(done.exception.code, 0)
        self.assertIn("新那台已连上", buf.getvalue()); self.assertNotIn("旧那台没找到", buf.getvalue())

    def test_targets_lists_name_udid_and_link(self):
        t = {"current": None, "osChoices": [27], "models": [], "connected": [
            {"model": "iPhone 17 Pro Max", "productType": "iPhone18,2", "gpuArch": "g18p", "os": 27, "name": "甲", "udid": "U-1", "wired": True},
            {"model": "iPhone 17 Pro Max", "productType": "iPhone18,2", "gpuArch": "g18p", "os": 27, "name": "乙", "udid": "U-2", "wired": False}]}
        buf = io.StringIO()
        with mock.patch.object(ctl, "call", return_value=t), mock.patch.object(sys, "argv", ["s2armctl", "targets"]), contextlib.redirect_stdout(buf):
            ctl.main()
        out = buf.getvalue()
        self.assertIn("设备名「甲」，设备号 U-1，数据线", out)
        self.assertIn("设备名「乙」，设备号 U-2，同一 Wi-Fi", out)


class DiagCommandTests(unittest.TestCase):
    """#94：只敲 s2armctl diag 原先 IndexError；现在不给路径 = 导出到桌面，认不出的写法打用法退出 2"""

    def _main(self, *argv, state="completed", write=True):
        """假控制口：POST /diagnostics 之后 /state 出一个新任务（state），导出时按 write 决定作业是否真写出文件"""
        posted, tasks = [], []
        err, out = io.StringIO(), io.StringIO()
        def call(m, p, b=None, **kw):
            if m == "POST":
                posted.append((m, p, b))
                op = "diagnostics" if b["action"] == "export" else "pullDiagnostics"
                tasks.append({"id": "t1", "operation": op, "state": state, "message": "导出失败：磁盘写不进" if state == "failed" else "", "started": 1})
                if write and b["action"] == "export" and state == "completed":
                    Path(b["path"]).write_bytes(b"PK" + b"x" * 2048)
                return {"ok": True}
            return {"tasks": list(tasks), "games": [], "busy": False}
        with mock.patch.object(ctl, "call", side_effect=call), mock.patch.object(ctl.time, "sleep", lambda s: None), \
             mock.patch.object(ctl, "brief", lambda s: ""), mock.patch.object(ctl, "errors", lambda *a, **k: print("错误：导出失败：磁盘写不进")), \
             mock.patch.object(sys, "argv", ["s2armctl", "diag", *argv]), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                ctl.main(); code = 0
            except SystemExit as e:
                code = e.code
        return code, posted, err.getvalue() + out.getvalue()

    def test_export_waits_for_the_job_and_prints_path_and_size(self):
        # #917：原先 POST 回 ok 就退 0、作业失败 / 没写出文件调用方看不到。期望按假任务手写：完成 + 文件在 → 退 0、打绝对路径与大小
        with tempfile.TemporaryDirectory() as d:
            target = os.path.join(d, "包.zip")
            code, _, text = self._main("export", target)
            self.assertEqual(code, 0, text); self.assertIn(f"诊断包：{target}（0.0 MB）", text)

    def test_export_job_failed_or_file_missing_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as d:
            code, _, text = self._main("export", os.path.join(d, "a.zip"), state="failed")
            self.assertEqual(code, 1); self.assertIn("磁盘写不进", text)
            code, _, text = self._main("export", os.path.join(d, "b.zip"), write=False)
            self.assertNotIn(code, (0, None)); self.assertIn("诊断包不在", str(code) + text)

    def test_bare_diag_exports_with_a_default_path(self):
        with tempfile.TemporaryDirectory() as home:   # 假家目录带桌面：缺省路径落在这里，不写进仓库或真桌面
            os.mkdir(os.path.join(home, "Desktop"))
            with mock.patch.dict(os.environ, {"HOME": home}):
                code, posted, _ = self._main()
            self.assertTrue(posted[0][2]["path"].startswith(os.path.join(home, "Desktop")), posted)
        self.assertEqual(code, 0)
        self.assertEqual(len(posted), 1)
        method, path, body = posted[0]
        self.assertEqual((method, path, body["action"]), ("POST", "/diagnostics", "export"))
        self.assertTrue(os.path.isabs(body["path"]) and body["path"].endswith(".zip"), body["path"])

    def test_export_without_path_uses_the_same_default(self):
        self.assertEqual(ctl.diag_body(["export"], now=0), ctl.diag_body([], now=0))

    def test_explicit_forms_unchanged(self):
        self.assertEqual(ctl.diag_body(["pull"]), {"action": "pull"})
        self.assertEqual(ctl.diag_body(["export", "/tmp/x.zip"]), {"action": "export", "path": "/tmp/x.zip"})

    def test_unknown_form_prints_usage_and_exits_2(self):
        code, posted, err = self._main("bogus")
        self.assertEqual((code, posted), (2, []))
        self.assertIn("用法", err)


class ErrorsCommandTests(unittest.TestCase):
    """errors 命令输出里含 failureSummary（阶段、退出码、原文）。"""

    def _run_errors(self, state):
        out = io.StringIO()
        with mock.patch.object(ctl, "call", return_value=state), \
             contextlib.redirect_stdout(out):
            ctl.errors()
        return out.getvalue()

    def test_errors_shows_failure_summary(self):
        """诊断带 failureSummary 时，errors 命令要把它印出来。"""
        state = {"tasks": [{"id": "t1", "operation": "ipa", "state": "failed", "started": 1,
                             "message": "打包失败",
                             "diagnostics": [{"code": "build_failed", "summary": "编译出错",
                                              "suggestion": "重装 Xcode", "logPath": None,
                                              "failureSummary": "Failed stage: compile\nExit code: 1\nLast output:\n  error: foo"}]}],
                 "error": ""}
        output = self._run_errors(state)
        # 期望：failureSummary 内容出现在输出里
        self.assertIn("Failed stage: compile", output)
        self.assertIn("Exit code: 1", output)
        self.assertIn("error: foo", output)

    def test_errors_no_failure_summary_still_works(self):
        """诊断没有 failureSummary 字段时不出错、不输出多余内容。"""
        state = {"tasks": [{"id": "t2", "operation": "ipa", "state": "failed", "started": 2,
                             "message": "打包失败",
                             "diagnostics": [{"code": "disk_full", "summary": "磁盘不足",
                                              "suggestion": "释放空间", "logPath": None}]}],
                 "error": ""}
        output = self._run_errors(state)
        self.assertIn("disk_full", output)
        self.assertNotIn("Failed stage", output)

class BatchCommandTests(unittest.TestCase):
    """s2armctl batch（批量出包，v0.2.4）：命令行组成 POST /batch 的请求；轮询 GET /state 的 batch，出完打印每款结果，有失败退 1。期望手写"""
    def run_batch(self, argv, final_summary):
        calls = []
        done = {"running": False, "summary": final_summary, "paused": None,
                "items": [{"gameId": "0100A", "name": "甲", "platforms": ["mac", "iphone"], "results": {"mac": {"state": "completed"}, "iphone": {"state": "completed"}}}]}
        def call(method, path, body=None, **kw):
            calls.append((method, path, body))
            return {"ok": True, "skipped": []} if path == "/batch" else {"batch": done}
        out = io.StringIO()
        with mock.patch.object(ctl, "call", call), mock.patch.object(ctl.time, "sleep", lambda s: None), contextlib.redirect_stdout(out), \
             self.assertRaises(SystemExit) as caught:
            ctl.batch(argv)
        return calls, caught.exception.code, out.getvalue()

    def test_request_and_exit_codes(self):
        calls, code, text = self.run_batch(["0100a:mac,iphone", "0100b", "--location", "/tmp/包"], {"total": 2, "completed": 2, "failed": 0})
        self.assertEqual(calls[0], ("POST", "/batch", {"games": [{"gameId": "0100A", "platforms": ["mac", "iphone"]},
                                                                 {"gameId": "0100B", "platforms": ["iphone"]}], "location": "/tmp/包"}))
        self.assertEqual(code, 0)
        self.assertIn("甲：mac completed；iphone completed", text)
        _, code, _ = self.run_batch(["0100a"], {"total": 1, "completed": 0, "failed": 1})
        self.assertEqual(code, 1)

    def test_not_started_exits_without_polling(self):   # 审计 P1-166：控制口说没开始（一款都不能出）→ 立刻退非 0，不轮询、不读上一批
        calls = []
        def call(method, path, body=None, **kw):
            calls.append(path); return {"ok": False, "error": "没有能出的游戏", "skipped": [{"gameId": "0100A", "reason": "keys"}]}
        out = io.StringIO()
        with mock.patch.object(ctl, "call", call), mock.patch.object(ctl.time, "sleep", lambda s: None), contextlib.redirect_stdout(out), \
             self.assertRaises(SystemExit) as caught:
            ctl.batch(["0100a"])
        self.assertEqual(calls, ["/batch"])
        self.assertIn("没有能出的游戏", str(caught.exception.code))
        self.assertIn("跳过 0100A：keys", out.getvalue())


if __name__ == "__main__":
    unittest.main()


class ControlStuckTests(unittest.TestCase):
    """10-26 Spare-host：内存吃紧时启动器控制口不应答，wait 一次超时就判失败、整个出包作业跟着丢。
    控制口卡住时 wait 要按作业记录（库没建好时 <数据目录>/logs/jobs/<任务>.json，pack/jobs/core.py 写）判：作业进程活着就接着等。期望按场景手写。"""
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="s2armctl-stuck-")
        os.makedirs(os.path.join(self.root, "logs", "jobs"))
        # 卡死的控制口：接连接、读请求、永远不回
        self.server = socket.socket(); self.server.bind(("127.0.0.1", 0)); self.server.listen(8)
        self.held = []
        def hold():
            while True:
                try: c, _ = self.server.accept()
                except OSError: return
                self.held.append(c)
        threading.Thread(target=hold, daemon=True).start()
        with open(os.path.join(self.root, "control.json"), "w") as f:
            json.dump({"port": self.server.getsockname()[1], "token": "t", "pid": os.getpid()}, f)
        self.patches = [mock.patch.object(ctl, "ROOT", self.root), mock.patch.dict(os.environ, {"S2ARMCTL_STATE_TIMEOUT": "0.5"})]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in self.patches: p.stop()
        self.server.close()
        for c in self.held: c.close()

    def job(self, finish_after, final="completed"):
        """假作业进程：按 core.py 的格式写作业记录（running + pid / pidStart），finish_after 秒后写终态退出；final=None = 中途被杀、记录停在 running"""
        path = os.path.join(self.root, "logs", "jobs", "job1.json")
        code = f"""
import json, os, subprocess, sys, time
p = {path!r}
st = subprocess.run(['/bin/ps', '-o', 'lstart=', '-p', str(os.getpid())], capture_output=True, text=True).stdout.strip()
rec = dict(schema=1, id='job1', operation='ipa', gameId='game', state='running', started=time.time(), pid=os.getpid(), pidStart=st, stage='直连库', done=1, total=4)
def w(): open(p + '.tmp', 'w').write(json.dumps(rec)); os.replace(p + '.tmp', p)
w()
for i in range(2, 5):
    time.sleep({finish_after} / 4); rec['done'] = i; w()
final = {final!r}
if final is None: os._exit(9)
rec.update(state=final, ended=time.time()); w()
"""
        proc = subprocess.Popen([sys.executable, "-c", code])
        for _ in range(100):
            if os.path.exists(path): break
            time.sleep(0.05)
        return proc

    def run_wait(self, limit=30):
        out = io.StringIO(); t0 = time.time()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as r:
            ctl.wait("game", "ipa", limit)
        return r.exception.code, out.getvalue(), time.time() - t0

    def test_stuck_control_job_completes(self):
        proc = self.job(3)
        code, out, took = self.run_wait()
        proc.wait()
        self.assertEqual(code, 0, out)
        self.assertIn("控制口没应答", out)
        self.assertIn("completed", out)
        self.assertLess(took, 20)

    def test_stuck_control_job_process_gone_fails(self):
        proc = self.job(2, final=None)
        code, out, _ = self.run_wait()
        proc.wait()
        self.assertEqual(code, 1, out)
        self.assertIn("作业进程已不在", out)

    def test_stale_snapshot_falls_back_to_journal(self):
        # 控制口还在回，但快照是 60 秒前的（启动器主线程卡住、缓存没刷新）：同样按作业记录判
        proc = self.job(2)
        stale = {"tasks": [{"id": "job1", "state": "running", "started": 1, "gameId": "game", "operation": "ipa"}],
                 "queue": [], "error": None, "cachedAt": time.time() - 60}
        with mock.patch.object(ctl, "call", return_value=stale):
            code, out, _ = self.run_wait()
        proc.wait()
        self.assertEqual(code, 0, out)
        self.assertIn("状态停住了", out)


class JobIdentityTests(unittest.TestCase):
    """Synthetic journals and ps replies only; never inspect or signal a real PID."""
    start = "Tue Oct 27 08:00:00 2026"

    def probe(self, identity, stdout=None, returncode=0, present=True):
        record = {"pid": 12345, "pidStart": identity}
        reply = subprocess.CompletedProcess([], returncode,
            stdout if stdout is not None else "S    " + self.start + "\n", "")
        with mock.patch.object(ctl, "alive", return_value=present), \
                mock.patch.object(ctl.subprocess, "run", return_value=reply):
            return ctl.job_alive(record)

    def test_matching_identity_is_alive(self):
        self.assertIs(self.probe(self.start), True)

    def test_reused_pid_is_not_this_job(self):
        self.assertIs(self.probe("Mon Oct 26 08:00:00 2026"), False)

    def test_missing_identity_is_unknown_not_alive(self):
        for identity in (None, "", "   "):
            with self.subTest(identity=identity):
                self.assertIsNone(self.probe(identity))

    def test_exited_and_zombie_are_dead_even_without_identity(self):
        self.assertIs(self.probe(None, present=False), False)
        self.assertIs(self.probe(None, stdout="Z    " + self.start), False)

    def test_failed_or_incomplete_query_is_unknown(self):
        for stdout, code in (("", 1), ("S", 0), ("", 0)):
            with self.subTest(stdout=stdout, code=code):
                self.assertIsNone(self.probe(self.start, stdout, code))
        with mock.patch.object(ctl, "alive", return_value=True), \
                mock.patch.object(ctl.subprocess, "run", side_effect=OSError("unavailable")):
            self.assertIsNone(ctl.job_alive({"pid": 12345, "pidStart": self.start}))

    def wait_journal(self, record):
        now = [0]
        def sleep(seconds): now[0] += seconds
        output = io.StringIO()
        with mock.patch.object(ctl, "call", return_value=None), \
                mock.patch.object(ctl, "journal_task", return_value=record), \
                mock.patch.object(ctl, "alive", return_value=True), \
                mock.patch.object(ctl.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, "S    " + self.start, "")), \
                mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), \
                mock.patch.object(ctl.time, "sleep", side_effect=sleep), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
            ctl.wait("game", "build", 4)
        return result.exception.code, output.getvalue()

    def test_wait_reports_unknown_without_false_running_or_dead(self):
        record = dict(task("synthetic", "running", 0), pid=12345, pidStart="")
        code, output = self.wait_journal(record)
        self.assertEqual(code, 1)
        self.assertIn("无法确认作业进程身份", output)
        for misleading in ("照常在跑", "running", "作业进程已不在", "可在 S2Arm 里重试"):
            self.assertNotIn(misleading, output)
        self.assertEqual(record["state"], "running")  # reporting must not rewrite journal

    def test_wait_known_reused_pid_still_reports_dead(self):
        code, output = self.wait_journal(dict(task("synthetic", "running", 0),
            pid=12345, pidStart="Mon Oct 26 08:00:00 2026"))
        self.assertEqual(code, 1)
        self.assertIn("作业进程已不在", output)

    def test_terminal_record_does_not_require_process_identity(self):
        code, output = self.wait_journal(task("synthetic", "completed", 0))
        self.assertEqual(code, 0)
        self.assertIn("completed", output)

    def test_wait_matching_identity_keeps_waiting(self):
        code, output = self.wait_journal(dict(task("synthetic", "running", 0),
            pid=12345, pidStart=self.start))
        self.assertEqual(code, "4 秒内没结束（任务 synthetic）")
        self.assertIn("running", output)
        self.assertNotIn("无法确认", output)

    def test_cancelling_unknown_identity_is_not_reported_dead(self):
        code, output = self.wait_journal(dict(task("synthetic", "cancelling", 0), pid=12345))
        self.assertEqual(code, 1)
        self.assertIn("无法确认作业进程身份", output)
        self.assertNotIn("作业进程已不在", output)


class UsageGuardTests(unittest.TestCase):
    """Subcommand help and missing arguments must not reach the App's control port."""

    def run_main(self, argv):
        output = io.StringIO()
        with mock.patch.object(ctl, "call") as call, \
                mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), \
                contextlib.redirect_stdout(output):
            ctl.main()
        return call, output.getvalue()

    def test_subcommand_help_never_reaches_the_app(self):
        for argv in (["install", "--help"], ["install", "-h"], ["wait", "--help"]):
            with self.subTest(argv=argv):
                call, output = self.run_main(argv)
                call.assert_not_called()
                self.assertIn("s2armctl", output)

    def test_missing_required_argument_exits_2_without_app_call(self):
        for argv in (["install"], ["wait"], ["build"], ["snapshot"], ["keys"],
                     ["install-check", "--json"], ["ipa", "--space-override"],
                     ["cloud-sync"], ["display", "--docked", "on"], ["library", "--move"], ["restore-iphone"], ["show"],
                     ["install", "--team", "ABCDE12345"]):
            with self.subTest(argv=argv):
                with mock.patch.object(ctl, "call") as call, \
                        mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(SystemExit) as caught:
                    ctl.main()
                call.assert_not_called()
                self.assertEqual(caught.exception.code, 2)

