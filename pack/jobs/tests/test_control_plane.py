"""Fault injection for the job control plane (J10 / #186).

Every case runs the real entry point (`pack/jobs/main.py`) against a real journal in a temporary private root: a worker killed with
SIGKILL, a frontend that walks away, a task cancelled with SIGTERM, a restart of a task whose last attempt never wrote a terminal
state. No game files, no packaging, no device.
"""
import contextlib
import io
import json
import os
os.environ.setdefault("S2A_BANNER_FETCH", "0")   # 同 jobcase.py：作业开始时 layout.ensure 会起脱离作业的商店查询子进程，往 library/ 写；测试收尾删临时目录时它还在写 → Directory not empty（11-10 负载下偶发）
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

JOBS = Path(__file__).resolve().parents[1]
ROOT = JOBS.parents[1]
MAIN = JOBS / "main.py"
sys.path.insert(0, str(JOBS))   # core / main are imported as top-level modules by the job entry point itself

HARNESS = '''import json, os, signal, sys, time
sys.path.insert(0, sys.argv[1])
from core import Context
c = Context(json.loads(sys.argv[2]))
signal.signal(signal.SIGTERM, lambda *_: c.stop())
signal.signal(signal.SIGINT, lambda *_: c.stop())
c.begin("导出 1/3")
if os.environ.get("S2A_TEST_TWO_STAGES"):
    c.begin("导出 2/3")
try:
    while True:
        c.check()
        time.sleep(0.02)
except BaseException:
    c.finish("cancelled", "任务已取消；上次成功的运行版本和存档已保留。")
    sys.exit(130)
'''


GROUP = """import subprocess, sys, time
gc = subprocess.Popen(["sleep", "60"])
open(sys.argv[1], "w").write(str(gc.pid))
time.sleep(60)
"""


NO_FLOOR = ("--per-operation", 0, "--failed-per-operation", 0)   # 只测总量 / 时间上限（每类操作保底另见 test_layout_p3.PruneJobsTests）


class ControlPlaneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm job ctl ")
        self.root = Path(self.tmp.name)
        self.private = self.root / "private"
        self.private.mkdir(parents=True)
        self.library = self.root / "library"
        self.task = str(uuid.uuid4())
        self.harness = self.root / "harness.py"
        self.harness.write_text(HARNESS)
        self.group = self.root / "group.py"
        self.group.write_text(GROUP)
        self.pidfile = self.root / "grandchild.pid"
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
        self.tmp.cleanup()

    # ---- helpers ----
    def jobs_dir(self, task=None):
        """任务记录目录：固定 <私有目录>/logs/jobs（剃刀 H6；库建没建好都一样）"""
        return self.private / "logs" / "jobs"

    def request(self, task=None, **extra):
        body = dict(schema=1, taskId=task or self.task, operation="setup", engineDir=str(ROOT),
                    privateRoot=str(self.private), library=str(self.library), libraryId="")   # 不传 developerDir：走缺省（装着的最新 Xcode）
        body.update(extra)
        path = self.root / ("request-" + body["taskId"] + ".json")
        path.write_text(json.dumps(body))
        os.chmod(path, 0o600)
        return path

    def cli(self, *args, timeout=60):
        result = subprocess.run([sys.executable, str(MAIN), *map(str, args)], capture_output=True, text=True, timeout=timeout)
        return result

    def journal(self, task=None):
        return json.loads((self.jobs_dir(task) / ((task or self.task) + ".json")).read_text())

    def wait_state(self, state, task=None, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            path = self.jobs_dir(task) / ((task or self.task) + ".json")
            if path.exists():
                record = json.loads(path.read_text())
                if record.get("state") == state:
                    return record
            time.sleep(0.05)
        self.fail(f"任务没有在 {timeout} 秒内进入 {state}：{self.journal(task) if (self.jobs_dir(task) / ((task or self.task) + '.json')).exists() else '无记录'}")

    def wait_attempt(self, attempt, task=None, timeout=10):
        """同一个 task 再被拉起来时，journal 里的 attemptNo 要变成第 N 次——不能只看 state=running（上一条被杀记录本来就是 running）。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            path = self.jobs_dir(task) / ((task or self.task) + ".json")
            if path.exists() and json.loads(path.read_text()).get("attemptNo") == attempt:
                return
            time.sleep(0.05)
        self.fail(f"任务没有进入第 {attempt} 次尝试：{self.journal(task)}")

    def start_worker(self, task=None, operation="build"):
        """A live worker that has begun a stage and then waits: the same Context/journal path as a real job."""
        task = task or self.task
        body = json.dumps(dict(schema=1, taskId=task, operation=operation, engineDir=str(ROOT),
                               privateRoot=str(self.private), library=str(self.library)))
        child = subprocess.Popen([sys.executable, str(self.harness), str(JOBS), body], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(child)
        self.wait_state("running", task)
        # 等工人真进了阶段再返回（10-25 gate-host 慢时 running 已写、还没进「导出 1/3」用例就 kill，journal 里 stage 为空，偶发红、把 vk/crop 退回）
        self.wait_stage("导出 2/3" if os.environ.get("S2A_TEST_TWO_STAGES") else "导出 1/3", task)
        return child

    def wait_stage(self, stage, task=None, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            path = self.jobs_dir(task) / ((task or self.task) + ".json")
            if path.exists() and json.loads(path.read_text()).get("stage") == stage:
                return
            time.sleep(0.05)
        self.fail(f"任务没有在 {timeout} 秒内进入阶段 {stage}：{self.journal(task)}")

    # ---- cases ----
    def test_legacy_request_only_call_still_runs(self):
        # The Mac launcher passes only --request; a subcommand parser must not break that call
        result = self.cli("--request", self.request())
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        self.assertEqual(self.journal()["state"], "completed")

    def test_get_reports_state_stage_attempts_and_pid(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        result = self.cli("get", "--private-root", self.private, "--task", self.task)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        record = json.loads(result.stdout)
        self.assertEqual(record["state"], "completed")
        self.assertTrue(record["terminal"])
        self.assertFalse(record["running"])
        self.assertFalse(record["canResume"])
        self.assertEqual(record["attemptNo"], 1)
        self.assertGreater(record["events"], 0)
        self.assertIsInstance(record["job"]["pid"], int)
        self.assertTrue(record["job"].get("pidStart"))

    def test_events_since_is_incremental(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        everything = self.cli("events", "--private-root", self.private, "--task", self.task)
        lines = [json.loads(line) for line in everything.stdout.splitlines() if line.strip()]
        self.assertGreaterEqual(len(lines), 2)
        tail = self.cli("events", "--private-root", self.private, "--task", self.task, "--since", len(lines) - 2)
        self.assertEqual([json.loads(x) for x in tail.stdout.splitlines() if x.strip()], lines[-2:])
        one = self.cli("events", "--private-root", self.private, "--task", self.task, "--limit", 1)
        self.assertEqual(len([x for x in one.stdout.splitlines() if x.strip()]), 1)

    def test_sigterm_cancel_writes_cancelled_through_the_cli(self):
        child = self.start_worker()
        result = self.cli("cancel", "--private-root", self.private, "--task", self.task)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr[-2000:])
        self.assertTrue(json.loads(result.stdout)["cancelled"])
        self.assertEqual(child.wait(timeout=15), 130)
        record = self.wait_state("cancelled")
        self.assertTrue(record.get("ended"))
        events = self.cli("events", "--private-root", self.private, "--task", self.task).stdout.splitlines()
        self.assertEqual(json.loads(events[-1])["state"], "cancelled")

    def test_sigkill_leaves_an_interrupted_journal_not_a_finished_one(self):
        child = self.start_worker()
        child.send_signal(signal.SIGKILL)
        child.wait(timeout=15)
        record = self.journal()
        self.assertEqual(record["state"], "running")          # no terminal event was invented for it
        self.assertNotIn("ended", record)
        result = self.cli("get", "--private-root", self.private, "--task", self.task)
        described = json.loads(result.stdout)
        self.assertFalse(described["terminal"])
        self.assertTrue(described["interrupted"])
        self.assertTrue(described["canResume"])
        self.assertEqual(described["stage"], "导出 1/3")
        self.assertEqual(described["attempts"], {"导出 1/3": 1})

    def test_restart_of_an_interrupted_task_counts_the_attempt_and_keeps_what_it_reached(self):
        child = self.start_worker()
        child.send_signal(signal.SIGKILL)
        child.wait(timeout=15)
        # the restart runs on the same task id, as a resume would
        result = self.cli("--request", self.request())
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        record = self.journal()
        self.assertEqual(record["state"], "completed")
        self.assertEqual(record["attemptNo"], 2)
        self.assertEqual(record["previousState"], "running")
        self.assertEqual(record["previousStage"], "导出 1/3")

    def test_cancel_refuses_a_pid_that_is_no_longer_that_worker(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        path = self.jobs_dir() / (self.task + ".json")
        record = json.loads(path.read_text())
        record.update(state="running", pid=os.getpid(), pidStart="Thu Jan  1 00:00:00 1970")
        record.pop("ended", None)
        path.write_text(json.dumps(record))
        result = self.cli("cancel", "--private-root", self.private, "--task", self.task)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["code"], "job_pid_reused")
        os.kill(os.getpid(), 0)   # this test process is still alive: the refusal did not signal it

    def test_cancel_on_a_finished_task_changes_nothing(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        before = (self.jobs_dir() / (self.task + ".json")).read_text()
        result = self.cli("cancel", "--private-root", self.private, "--task", self.task)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout)["cancelled"])
        self.assertEqual((self.jobs_dir() / (self.task + ".json")).read_text(), before)

    def test_resume_reruns_a_killed_task_and_counts_the_attempt(self):
        child = self.start_worker(operation="setup")
        child.send_signal(signal.SIGKILL)
        child.wait(timeout=15)
        result = self.cli("resume", "--private-root", self.private, "--task", self.task, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-2000:])
        record = self.journal()
        self.assertEqual(record["attemptNo"], 2)
        self.assertEqual(record["previousStage"], "导出 1/3")
        self.assertEqual(record["previousState"], "running")
        self.assertEqual(record["state"], "completed")

    def test_resume_refuses_a_finished_task_without_force(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        before = (self.jobs_dir() / (self.task + ".json")).read_text()
        result = self.cli("resume", "--private-root", self.private, "--task", self.task)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout)["resumed"])
        self.assertEqual((self.jobs_dir() / (self.task + ".json")).read_text(), before)

    def test_resume_force_reruns_a_finished_task(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        result = self.cli("resume", "--private-root", self.private, "--task", self.task, "--force", timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        self.assertEqual(self.journal()["attemptNo"], 2)

    def test_the_request_is_kept_private_beside_the_journal(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        stored = self.jobs_dir() / (self.task + ".request.json")
        self.assertTrue(stored.is_file())
        self.assertEqual(stored.stat().st_mode & 0o077, 0)
        self.assertEqual(json.loads(stored.read_text())["taskId"], self.task)

    # ---- job store pruning ----
    def finish_task(self, name, state="completed", age=0):
        """A finished job record as the worker leaves it, aged on disk."""
        jobs = self.jobs_dir()
        jobs.mkdir(parents=True, exist_ok=True)
        for suffix, body in ((".json", json.dumps(dict(schema=1, id=name, state=state, ended=1.0))),
                             (".request.json", "{}"),
                             (".events.jsonl", "\n")):
            path = jobs / (name + suffix)
            path.write_text(body)
            if age:
                stamp = time.time() - age
                os.utime(path, (stamp, stamp))
        return jobs / (name + ".json")

    def test_prune_drops_old_finished_jobs_and_keeps_the_newest(self):
        for index in range(5):
            self.finish_task(f"task-{index}", age=3600 - index)   # all inside 14 days: only the count cap applies
        result = self.cli("prune", "--private-root", self.private, "--keep-count", 2, "--keep-days", 14, *NO_FLOOR)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        report = json.loads(result.stdout)
        self.assertEqual(sorted(report["removed"]), ["task-0", "task-1", "task-2"])
        self.assertEqual(report["kept"], 2)
        self.assertGreater(report["bytes"], 0)
        left = sorted(p.name[:-len(".events.jsonl")] for p in (self.jobs_dir()).glob("*.events.jsonl"))
        self.assertEqual(left, ["task-3", "task-4"])
        self.assertFalse((self.jobs_dir() / "task-0.request.json").exists())

    def test_prune_never_touches_a_running_job(self):
        self.finish_task("ancient", age=400 * 86400)
        child = self.start_worker(task="running-one")
        try:
            result = self.cli("prune", "--private-root", self.private, "--keep-count", 0, "--keep-days", 1, *NO_FLOOR)
            report = json.loads(result.stdout)
            self.assertEqual(report["removed"], ["ancient"])
            self.assertEqual(report["skippedRunning"], 1)
            self.assertTrue((self.jobs_dir() / "running-one.json").exists())
            self.assertTrue((self.jobs_dir() / "running-one.events.jsonl").exists())
        finally:
            child.kill()
            child.wait(timeout=10)

    def test_prune_keeps_request_only_task_as_running(self):
        jobs = self.jobs_dir("queued")
        jobs.mkdir(parents=True)
        request = jobs / "queued.request.json"
        request.write_text('{"schema":1,"operation":"setup"}')
        before = request.read_bytes()
        for dry_run in (True, False):
            with self.subTest(dry_run=dry_run):
                options = ["--dry-run"] if dry_run else []
                result = self.cli("prune", "--private-root", self.private,
                                  "--keep-count", 0, "--keep-days", 0, *options)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["skippedRunning"], 1)
                self.assertEqual(report["invalidRecords"], [])
                self.assertEqual(report["kept"], 1)
                self.assertEqual(report["removed"], [])
                self.assertEqual(request.read_bytes(), before)

    def test_status_ignores_a_record_removed_during_the_scan(self):
        from unittest.mock import patch
        import core
        self.finish_task("healthy")
        vanished = self.finish_task("vanished").resolve()
        original_read = core.read

        def remove_before_read(path, default=None):
            if path == vanished:
                vanished.unlink(missing_ok=True)
            return original_read(path, default)

        with patch.object(core, "read", side_effect=remove_before_read):
            report = core.status(self.private)
        self.assertEqual(report["finished"], 1)
        self.assertEqual(report["interrupted"], 0)
        self.assertEqual(report["invalidRecords"], [])

    def test_prune_leaves_a_job_that_is_finishing_right_now_alone(self):
        """一个刚写完终态、worker 还没退出的任务不能被清掉：它在 journal 里已经是终态，但文件还在被追加。"""
        import main as worker
        jobs = self.jobs_dir()
        path = jobs / (self.task + ".json")
        # 模拟「终态已写、进程还在」：先正常跑完一个任务，再把它的记录年龄改成很老
        self.assertEqual(worker.run_request(self.stub_request(), operation_overrides={"stub": lambda c: {"ok": True}}), 0)
        old = time.time() - 400 * 86400
        for p in jobs.iterdir():
            os.utime(p, (old, old))
        # 另一个仍在跑的任务：prune 必须只清前者，不能因为「都是老的」就一起清
        child = self.start_worker(task="still-running")
        try:
            report = json.loads(self.cli("prune", "--private-root", self.private, "--keep-count", 0, "--keep-days", 1, *NO_FLOOR).stdout)
            self.assertEqual(report["removed"], [self.task])
            self.assertEqual(report["skippedRunning"], 1)
            self.assertTrue((jobs / "still-running.json").exists())
        finally:
            child.kill()
            child.wait(timeout=10)

    def test_prune_keeps_a_recent_finished_job_inside_the_window(self):
        self.finish_task("fresh", age=3600)
        self.finish_task("stale", age=30 * 86400)
        report = json.loads(self.cli("prune", "--private-root", self.private, "--keep-count", 100, "--keep-days", 14, *NO_FLOOR).stdout)
        self.assertEqual(report["removed"], ["stale"])
        self.assertTrue((self.jobs_dir() / "fresh.json").exists())

    def test_prune_dry_run_reports_without_deleting(self):
        self.finish_task("stale", age=30 * 86400)
        report = json.loads(self.cli("prune", "--private-root", self.private, "--keep-count", 0, "--keep-days", 1, *NO_FLOOR, "--dry-run").stdout)
        self.assertEqual(report["removed"], ["stale"])
        self.assertTrue((self.jobs_dir() / "stale.json").exists())

    def test_prune_leaves_foreign_files_and_links_alone(self):
        self.finish_task("stale", age=30 * 86400)
        jobs = self.jobs_dir()
        (jobs / "notes.txt").write_text("keep me")
        outside = self.root / "outside.json"
        outside.write_text("{}")
        (jobs / "linked.json").symlink_to(outside)
        self.cli("prune", "--private-root", self.private, "--keep-count", 0, "--keep-days", 1, *NO_FLOOR)
        self.assertTrue((jobs / "notes.txt").is_file())
        self.assertTrue((jobs / "linked.json").is_symlink())
        self.assertTrue(outside.is_file())

    def test_status_reports_bad_journals_and_still_counts_healthy_jobs(self):
        self.finish_task("healthy")
        jobs = self.jobs_dir("healthy")
        broken = {"truncated": b"{", "encoding": b"\xff", "array": b"[]", "null": b"null",
                  "foreign": b'{"id":"another-task","state":"completed"}'}
        for name, content in broken.items():
            (jobs / (name + ".json")).write_bytes(content)
        result = self.cli("status", "--private-root", self.private)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["finished"], 1)
        self.assertEqual({row["taskId"] for row in report["invalidRecords"]}, set(broken))
        self.assertTrue(all(row["reason"] for row in report["invalidRecords"]))

    def test_prune_preserves_bad_journals_and_their_companions(self):
        self.finish_task("healthy", age=30 * 86400)
        broken = {"truncated": b"{", "encoding": b"\xff", "array": b"[]", "null": b"null",
                  "foreign": b'{"id":"another-task","state":"completed"}'}
        snapshots = {}
        for name, content in broken.items():
            path = self.finish_task(name, age=30 * 86400)
            path.write_bytes(content)
            for file in path.parent.glob(name + ".*"):
                snapshots[file] = file.read_bytes()
        result = self.cli("prune", "--private-root", self.private, "--keep-count", 0, "--keep-days", 0, *NO_FLOOR)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["removed"], ["healthy"])
        self.assertEqual(report["kept"], len(broken))
        self.assertEqual({row["taskId"] for row in report["invalidRecords"]}, set(broken))
        for path, content in snapshots.items():
            self.assertEqual(path.read_bytes(), content)

    def test_generic_json_read_still_rejects_corruption(self):
        from core import read
        path = self.root / "essential.json"
        path.write_text("{")
        with self.assertRaises(json.JSONDecodeError):
            read(path, {})

    # ---- 记录写不进磁盘时不能假装成功 ----
    def stub_request(self, task=None):
        body = dict(schema=1, taskId=task or self.task, operation="stub", engineDir=str(ROOT),
                    privateRoot=str(self.private), library=str(self.library))
        path = self.root / ("stub-" + body["taskId"] + ".json")
        path.write_text(json.dumps(body))
        os.chmod(path, 0o600)
        return path

    def test_a_job_whose_record_cannot_be_written_does_not_report_success(self):
        import errno
        from unittest.mock import patch
        import main as worker
        request = self.stub_request()
        with patch("os.fsync", side_effect=OSError(errno.ENOSPC, "No space left on device")):
            code = worker.run_request(request, operation_overrides={"stub": lambda c: {"ok": True}})
        self.assertEqual(code, 1, "记录写不进磁盘时仍然报了成功")
        record = self.jobs_dir() / (self.task + ".json")
        if record.exists():   # 连首条记录都没写进去时文件就该不存在；写进去了就绝不许是 completed
            self.assertNotEqual(json.loads(record.read_text()).get("state"), "completed", "磁盘没写进去，记录却写着完成")

    def test_a_normal_job_still_reports_success(self):
        import main as worker
        code = worker.run_request(self.stub_request(), operation_overrides={"stub": lambda c: {"ok": True}})
        self.assertEqual(code, 0)
        self.assertEqual(json.loads((self.jobs_dir() / (self.task + ".json")).read_text())["state"], "completed")

    def test_a_stage_that_cannot_write_its_events_fails_with_a_named_code(self):
        import errno
        from unittest.mock import patch
        from core import Context, Failure
        c = self.context()
        with patch("os.fsync", side_effect=OSError(errno.ENOSPC, "No space left on device")):
            with self.assertRaises(Failure) as caught:
                c.begin("导出 1/3")
        self.assertEqual(caught.exception.code, "journal_write_failed")
        self.assertTrue(c.journal_broken)

    # ---- 阶段完成记录：按维护方口径，job 层不记这份（只有一个判据 = 产物根的阶段键） ----
    def test_job_layer_keeps_no_completed_stage_list(self):
        import main as worker
        code = worker.run_request(self.stub_request(), operation_overrides={"stub": lambda c: (c.begin("导出 1/3"), c.begin("导出 2/3"), {})[-1]})
        self.assertEqual(code, 0)
        record = json.loads((self.jobs_dir() / (self.task + ".json")).read_text())
        self.assertNotIn("completedStages", record, "job 层又记了一份阶段完成状态，会和产物键对不上")
        self.assertEqual(record["attempts"], {"导出 1/3": 1, "导出 2/3": 1})   # 只留展示用的次数
        described = json.loads(self.cli("get", "--private-root", self.private, "--task", self.task).stdout)
        self.assertNotIn("completedStages", described)

    def test_stage_key_and_keychain_flag_ride_every_event_of_the_stage(self):
        """前端认 stageKey / keychainPrompt（M9 / M10），不按中文阶段名、写死的步骤号猜；标记只在本阶段，下一次 begin 重置"""
        import main as worker
        def stub(c):
            c.begin("用你的 Apple ID 签名", 4, 6, keychain=True); c.emit("progress", "签名中", done=1, total=2)
            c.begin("游戏运行中", key="game_running")
            c.begin("装到 iPhone", 5, 6)
            return {}
        self.assertEqual(worker.run_request(self.stub_request(), operation_overrides={"stub": stub}), 0)
        events = [json.loads(x) for x in self.cli("events", "--private-root", self.private, "--task", self.task).stdout.splitlines() if x.strip()]
        seen = [(e["stage"], e["stageKey"], e["keychainPrompt"]) for e in events if e["type"] in ("stage", "progress")]
        self.assertIn(("用你的 Apple ID 签名", None, True), seen)
        self.assertEqual([x for x in seen if x[0] == "用你的 Apple ID 签名"], [("用你的 Apple ID 签名", None, True)] * 2)   # 阶段事件 + 进度事件都带
        self.assertIn(("游戏运行中", "game_running", False), seen)
        self.assertIn(("装到 iPhone", None, False), seen)

    def test_a_killed_task_reports_only_the_stages_it_left_behind(self):
        child = self.start_worker(operation="build")
        child.send_signal(signal.SIGKILL)
        child.wait(timeout=15)
        described = json.loads(self.cli("get", "--private-root", self.private, "--task", self.task).stdout)
        self.assertNotIn("completedStages", described)              # 口径：job 层不记完成阶段
        self.assertEqual(described["stage"], "导出 1/3")
        self.assertTrue(described["canResume"])

    def test_two_kills_in_a_row_keep_the_stage_record_and_the_attempt_count(self):
        first = self.start_worker()
        self.wait_state("running")
        record = self.journal()
        self.assertEqual(record["attemptNo"], 1)
        first.send_signal(signal.SIGKILL)
        first.wait(timeout=15)
        second = self.start_worker()                  # 同一个 task 再被拉起一次，随后再被杀
        self.wait_attempt(2)
        second.send_signal(signal.SIGKILL)
        second.wait(timeout=15)
        record = self.journal()
        self.assertEqual(record["state"], "running")  # 两次都没写过终态
        self.assertEqual(record["attemptNo"], 2)
        described = json.loads(self.cli("get", "--private-root", self.private, "--task", self.task).stdout)
        self.assertTrue(described["interrupted"])
        self.assertTrue(described["canResume"])
        self.assertNotIn("completedStages", described)

    def test_resume_after_two_kills_counts_from_the_last_attempt(self):
        for attempt in (1, 2):
            child = self.start_worker(operation="setup")
            self.wait_attempt(attempt)
            child.send_signal(signal.SIGKILL)
            child.wait(timeout=15)
        result = self.cli("resume", "--private-root", self.private, "--task", self.task, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        record = self.journal()
        self.assertEqual(record["attemptNo"], 3)
        self.assertEqual(record["state"], "completed")
        self.assertEqual(record["previousState"], "running")     # 上一次（第二次）是被杀的
        self.assertNotIn("completedStages", record)

    # ---- 只读：resume --dry-run / status ----
    def test_resume_dry_run_reports_without_touching_anything(self):
        child = self.start_worker()
        child.send_signal(signal.SIGKILL)
        child.wait(timeout=15)
        before = (self.jobs_dir() / (self.task + ".json")).read_text()
        result = self.cli("resume", "--private-root", self.private, "--task", self.task, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        plan = json.loads(result.stdout)
        self.assertTrue(plan["dryRun"])
        self.assertTrue(plan["wouldResume"])
        self.assertEqual(plan["operation"], "build")
        self.assertEqual(plan["stage"], "导出 1/3")
        self.assertEqual(plan["attemptNo"], 2)
        self.assertEqual((self.jobs_dir() / (self.task + ".json")).read_text(), before, "dry-run 改了 journal")

    def test_resume_dry_run_on_a_finished_task_says_it_would_not_resume(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)
        plan = json.loads(self.cli("resume", "--private-root", self.private, "--task", self.task, "--dry-run").stdout)
        self.assertFalse(plan["wouldResume"])
        self.assertEqual(plan["attemptNo"], 1)          # 不会加一：没有 --force 就不会重跑

    def test_status_counts_running_finished_and_interrupted(self):
        self.assertEqual(self.cli("--request", self.request()).returncode, 0)          # 一个完成
        victim = self.start_worker(task="killed-one")                                   # 一个被杀
        victim.send_signal(signal.SIGKILL)
        victim.wait(timeout=15)
        running = self.start_worker(task="alive-one")                                   # 一个在跑
        try:
            result = self.cli("status", "--private-root", self.private)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            report = json.loads(result.stdout)
            self.assertEqual((report["running"], report["finished"], report["interrupted"]), (1, 1, 1))
            self.assertGreater(report["bytes"], 0)
            self.assertIsNotNone(report["newest"])
        finally:
            running.kill()
            running.wait(timeout=10)

    def test_unknown_task_is_an_error_not_a_crash(self):
        result = self.cli("get", "--private-root", self.private, "--task", "nosuchtask")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["code"], "job_unknown")


    # ---- stage timeout and process-group reaping ----
    def context(self):
        from core import Context
        self.output = contextlib.redirect_stdout(io.StringIO())   # the worker prints its events; keep the test output readable
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)
        return Context(dict(schema=1, taskId=self.task, operation="build", engineDir=str(ROOT),
                            privateRoot=str(self.private), library=str(self.library)))

    def grandchild(self, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.pidfile.exists() and self.pidfile.read_text().strip():
                return int(self.pidfile.read_text().strip())
            time.sleep(0.05)
        self.fail("阶段工具没有拉起孙进程")

    def assert_dead(self, pid, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        self.fail(f"孙进程 {pid} 还活着：阶段结束时进程组没被回收")

    def test_stage_timeout_stops_the_whole_process_group(self):
        from core import Failure
        c = self.context()
        c.stage = "导出 2/3"
        started = time.monotonic()
        with self.assertRaises(Failure) as caught:
            c.run([sys.executable, str(self.group), str(self.pidfile)], timeout=1)
        elapsed = time.monotonic() - started
        self.assertEqual(caught.exception.code, "stage_timeout")
        self.assertLess(elapsed, 20, "超时没有在合理时间内停下来")
        self.assert_dead(self.grandchild())          # the `sleep 60` inside the stage's group, not just the stage's own process
        record = self.journal()
        self.assertEqual(record["diagnostics"][-1]["code"], "stage_timeout")
        self.assertIn("导出 2/3", record["diagnostics"][-1]["summary"])

    def test_unkillable_stage_keeps_original_failure_and_records_why(self):
        # #837：进程卡在系统内核里（换页）时 KILL 也要等它回来才生效；原先第二次等待超时抛 TimeoutExpired，盖掉超时 / 取消本身，也不记诊断
        from core import Failure
        from unittest.mock import patch
        c = self.context()
        c.stage = "运行游戏"
        sent, procs = [], []
        with patch.object(type(c), "signal_child", lambda self, p, sig: (sent.append(sig), procs.append(p))):   # 信号「发了却不生效」
            with self.assertRaises(Failure) as caught:
                c.run([sys.executable, str(self.group), str(self.pidfile)], timeout=1)
        self.assertEqual(caught.exception.code, "stage_timeout")
        self.assertEqual(sent, ["TERM", "KILL"])
        codes = [d["code"] for d in self.journal()["diagnostics"]]
        self.assertEqual(codes, ["stage_timeout", "child_unkillable"])
        procs[0].kill(); procs[0].wait(timeout=10)   # 收尾：测试自己结束这个「收不掉」的阶段工具
        self.assert_dead(self.grandchild())

    def test_cancel_stops_the_whole_process_group(self):
        from core import Cancelled, Failure
        c = self.context()
        c.stage = "导出 2/3"
        raised = []

        def worker():
            try:
                c.run([sys.executable, str(self.group), str(self.pidfile)])
            except BaseException as error:      # Cancelled or Failure: either way the stage must not outlive the job
                raised.append(error)

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        pid = self.grandchild()
        c.stop()
        thread.join(timeout=20)
        self.assertFalse(thread.is_alive(), "取消后阶段没有退出")
        self.assertTrue(raised and isinstance(raised[0], (Cancelled, Failure)), raised)
        self.assert_dead(pid)

    def test_stage_timeout_absent_by_default(self):
        c = self.context()
        c.run([sys.executable, "-c", "pass"])       # no timer in the request: a normal stage still returns
        self.assertTrue(self.journal()["state"] == "running")


if __name__ == "__main__":
    unittest.main()
