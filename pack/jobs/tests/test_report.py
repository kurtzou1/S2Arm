import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools"))
import report  # noqa: E402
from core import Failure  # noqa: E402


class ReportTests(unittest.TestCase):
    """期望值按摘要的约定手写：每类失败都要带上定位问题所需的事实，且不泄露路径和密钥。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.private = Path(self.tmp.name)
        (self.private / "jobs").mkdir(); (self.private / "logs").mkdir(); (self.private / "keys").mkdir()
        self.library = self.private / "lib"; self.library.mkdir()
        (self.library / "catalog.json").write_text(json.dumps({"games": [{"id": "0100", "name": "Game", "display": "1.2", "packages": [
            {"type": "base", "version": 0, "format": "", "size": 2048}, {"type": "update", "version": 65536, "format": "", "size": 1024}]}]}))

    def job(self, task, **fields):
        record = {"id": task, "operation": "ipa", "state": "failed", "stage": "解包", "message": "坏了", "started": 100.0, "ended": 160.0} | fields
        (self.private / "jobs" / (task + ".json")).write_text(json.dumps(record))
        (self.private / "jobs" / (task + ".request.json")).write_text(json.dumps({"library": str(self.library), "operation": record["operation"]}))
        return record

    def test_failed_export_carries_cause_game_and_real_log(self):
        log = self.private / "logs" / "t1.log"; log.write_text("first line\nfatal: bad nca\n")
        self.job("t1", gameId="0100", milestone="unpack", milestones=[{"id": "unpack"}, {"id": "ipa"}], milestoneStarted={"unpack": 100.0, "ipa": 130.0},
                 diagnostics=[{"code": "content_invalid", "component": "S2Arm", "stage": "解包", "summary": "文件结构校验没通过", "suggestion": "重新导入", "logPath": str(log), "exitCode": 3}])
        text = report.build(self.private, "t1", {"platform": "iPhone / iPad", "app": "0.1.0", "build": "abc", "device": "iPhone17,1", "checks": [{"name": "Metal", "message": "缺"}]})
        for expected in ("平台：iPhone / iPad", "任务号：t1", "出错阶段：unpack", "错误码：content_invalid（S2Arm，阶段 解包，退出码 3）", "文件结构校验没通过", "建议：重新导入",
                         "unpack 30 秒；ipa 30 秒", "名称：Game", "程序号：0100", "包：update v65536 NSP/XCI 1.00 KB", "原包合计：3.00 KB", "S2Arm：0.1.0（abc）", "目标设备：iPhone17,1",
                         "Metal：缺", "fatal: bad nca", "密钥：没有", "反馈："):
            self.assertIn(expected, text)

    def test_killed_job_says_there_was_no_diagnosis(self):
        self.job("t2", state="interrupted")
        text = report.build(self.private, "t2")
        self.assertIn("结果：interrupted", text)
        self.assertIn("错误码：无（作业没有写出诊断", text)
        self.assertIn("没有留下日志文件", text)

    def test_shared_source_total_keeps_each_package_detail(self):
        packages = [
            {"type": "base", "version": 0, "sha256": "a" * 64, "path": "sources/game.nup", "size": 4096},
            {"type": "update", "version": 65536, "sha256": "a" * 64, "path": "sources/game.nup", "size": 4096},
        ]
        (self.library / "catalog.json").write_text(json.dumps({"games": [{"id": "0100", "packages": packages}]}))
        self.job("shared", gameId="0100")
        text = report.build(self.private, "shared")
        self.assertIn("包：base v0 NSP/XCI 4.00 KB", text)
        self.assertIn("包：update v65536 NSP/XCI 4.00 KB", text)
        self.assertIn("原包合计：4.00 KB", text)
        self.assertFalse((self.library / "sources/game.nup").exists())

    def test_bundle_rows_show_each_package_own_bytes(self):
        # #141：本体 + 2 个 DLC 装在同一个 XCI 里，size 是整个原件；每行要显示本项内容字节，合计仍按原件算一次
        packages = [{"type": "base", "version": 0, "sha256": "c" * 64, "size": 14 << 30, "contentBytes": (14 << 30) - (200 << 10)},
                    {"type": "dlc", "version": 0, "sha256": "c" * 64, "size": 14 << 30, "contentBytes": 100 << 10},
                    {"type": "dlc", "version": 0, "sha256": "c" * 64, "size": 14 << 30, "contentBytes": 100 << 10},
                    {"type": "dlc", "version": 0, "sha256": "d" * 64, "size": 3 << 20, "contentBytes": 5 << 20}]   # 单项原件（NSZ）照旧显示原件大小
        (self.library / "catalog.json").write_text(json.dumps({"games": [{"id": "0100", "packages": packages}]}))
        self.job("bundle", gameId="0100")
        text = report.build(self.private, "bundle")
        self.assertEqual(text.count("包：dlc v0 NSP/XCI 100.00 KB"), 2)
        self.assertIn("包：dlc v0 NSP/XCI 3.00 MB", text)
        self.assertNotIn("包：dlc v0 NSP/XCI 14.00 GB", text)
        self.assertIn("原包合计：14.00 GB", text)

    def test_source_total_uses_identity_not_path(self):
        cases = [
            ("same_sha_different_paths", [
                {"sha256": "a" * 64, "path": "first.nup", "size": 2048},
                {"sha256": "a" * 64, "path": "second.nup", "size": 2048}], "原包合计：2.00 KB"),
            ("different_sha_same_path", [
                {"sha256": "a" * 64, "path": "game.nup", "size": 2048},
                {"sha256": "b" * 64, "path": "game.nup", "size": 1024}], "原包合计：3.00 KB"),
            ("missing_identity_same_path", [
                {"path": "game.nup", "size": 2048},
                {"sha256": "", "path": "game.nup", "size": 1024},
                {"sha256": None, "path": "game.nup", "size": 1024}], "原包合计：4.00 KB"),
            ("same_sha_without_path", [
                {"sha256": "a" * 64, "size": 2048},
                {"sha256": "a" * 64, "size": 2048}], "原包合计：2.00 KB"),
            ("same_sha_latest_size", [
                {"sha256": "a" * 64, "size": 2048},
                {"sha256": "a" * 64, "size": 1024}], "原包合计：1.00 KB"),
        ]
        for name, packages, expected in cases:
            with self.subTest(name=name):
                (self.library / "catalog.json").write_text(json.dumps({"games": [{"id": "0100", "packages": packages}]}))
                lines = report.game_lines({"library": str(self.library)}, "0100")
                self.assertEqual(lines[-1], expected)
                self.assertEqual(sum(line.startswith("包：") for line in lines), len(packages))

    def test_python_crash_log_is_included(self):
        (self.private / "logs" / "t3-exception.log").write_text("Traceback\nKeyError: 'x'\n")
        self.job("t3", operation="import")
        self.assertIn("KeyError: 'x'", report.build(self.private, "t3"))

    def test_detail_used_when_log_file_is_gone(self):
        self.job("t4", diagnostics=[{"code": "stage_timeout", "summary": "超时", "detail": "internal rc=9", "logPath": str(self.private / "gone.log")}])
        self.assertIn("internal rc=9", report.build(self.private, "t4"))

    def test_home_and_key_values_are_removed(self):
        secret = "ab" * 16
        (self.private / "keys/prod.keys").write_text(f"header_key = {secret}\n")
        (self.private / "logs" / "t5.log").write_text(f"path {Path.home()}/x key {secret}\n")
        self.job("t5")
        text = report.build(self.private, "t5")
        self.assertNotIn(str(Path.home()) + "/x", text)
        self.assertNotIn(secret, text)
        self.assertIn("密钥：已放入", text)

    def test_uuid_task_id_survives_redaction(self):
        task = "d0b6f440-9fc5-43d6-acdb-983d53f0ff38"
        (self.private / "logs" / (task + ".log")).write_text("boom\n")
        self.job(task)
        text = report.build(self.private, task)
        self.assertIn("任务号：" + task, text)
        self.assertIn(task + ".log", text)

    def test_long_log_keeps_the_end(self):
        (self.private / "logs" / "t6.log").write_text("start\n" + "x" * 50000 + "\nthe end\n")
        self.job("t6")
        text = report.build(self.private, "t6")
        self.assertIn("the end", text)
        self.assertNotIn("start\nxxx", text)
        self.assertLess(len(text), 20000)

    def test_crash_scene_survives_long_thread_table(self):
        """宿主崩溃：现场那行与回溯在前、全线程等待栈几百 KB 在后（#806 / #786 摘要只剩别的线程）。期望按规则手写：
        【崩溃现场】节带最后一次【红】CRASH 行、其缩进回溯与之前的【红】行，不带线程表；日志末尾照旧"""
        threads = "".join(f"[s2a] [现场] 线程 {i}/114 等待\n[s2a] [现场]     #0 __psynch_cvwait+0x8\n" for i in range(4000))
        (self.private / "logs" / "t7-game.log").write_text("[s2a] 【红】音频队列起不来\n[s2a] 普通行\n"
            "[s2a] 【红】CRASH 信号 11 地址 0x0 pc main+0x1234 lr sdk+0x99 sp 0x16f000000\n[s2a]   x0  0000000000000000\n[s2a]   #0 main+0x1234\n[s2a]   #1 sdk+0x99\n"
            + threads + "[s2a] ===== 现场完 =====\n")
        self.job("t7", operation="launch")
        text = report.build(self.private, "t7")
        scene = text.split("【崩溃现场】", 1)[1].split("【日志末尾】", 1)[0]
        for expected in ("【红】音频队列起不来", "【红】CRASH 信号 11", "#0 main+0x1234", "#1 sdk+0x99"):
            self.assertIn(expected, scene)
        self.assertNotIn("[现场] 线程", scene)
        self.assertIn("===== 现场完 =====", text)

    def test_no_crash_no_scene_section(self):
        (self.private / "logs" / "t8.log").write_text("plain failure\n")
        self.job("t8")
        self.assertNotIn("【崩溃现场】", report.build(self.private, "t8"))

    def test_newest_failed_task_is_picked_within_filters(self):
        self.job("old", gameId="0100", started=1.0); self.job("new", gameId="0100", started=2.0); self.job("mac", gameId="0100", operation="build", started=3.0)
        self.job("ok", gameId="0100", state="completed", started=4.0)
        self.assertEqual(report.find_task(self.private, "0100", ["ipa"]), "new")
        self.assertEqual(report.find_task(self.private, "0100"), "mac")
        with self.assertRaises(Failure):
            report.find_task(self.private, "9999")


if __name__ == "__main__":
    unittest.main()
