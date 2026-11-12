"""出包编排作业 export（剃刀 H13）：每一步换成桩子作业，期望值按 batch.py 文件头的规则手写（顺序同一款先 Mac 后 iPhone、一款失败不挡后面、
磁盘满暂停、取消后已出好的保留），不跑被测实现推导。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import textwrap
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobcase import JobCase   # noqa: E402
import batch   # noqa: E402
from core import atomic, journal, read_events   # noqa: E402
import export_plan   # noqa: E402
import filelock   # noqa: E402
import main   # noqa: E402

JOBS = Path(__file__).resolve().parents[1]
A, B = "0100000000000A00", "0100000000000B00"

# 桩子作业：按 scenario.json 里给这一款这一平台的结局打事件；把收到的请求存一份（核 followUp / parentPid / location / target）
STUB = textwrap.dedent('''
    import json, os, signal, sys, time
    from pathlib import Path
    here = Path(__file__).parent
    req_path = Path(sys.argv[sys.argv.index("--request") + 1])
    r = json.loads(req_path.read_text())
    (here / "seen").mkdir(exist_ok=True)
    (here / "seen" / (r["taskId"] + ".json")).write_text(json.dumps(r))
    platform = {"build": "mac", "ipa": "iphone"}[r["operation"]]
    what = json.loads((here / "scenario.json").read_text()).get(r["gameId"] + "/" + platform, "ok")
    def out(**e):
        print(json.dumps(dict(schema=1, taskId=r["taskId"], operation=r["operation"], gameId=r["gameId"], **e)), flush=True)
    out(type="progress", message="桩：出到一半", done=1, total=2)
    out(type="heartbeat", message="")
    if what == "slow":
        stop = []
        signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
        (here / "slow.pid").write_text(str(os.getpid()))
        for _ in range(600):
            if stop: break
            time.sleep(0.05)
        out(type="result", state="cancelled", message="任务已取消", result={}, diagnostics=[])
        sys.exit(130)
    if what in ("disk_full", "fail"):
        code = "disk_full" if what == "disk_full" else "tool_exit"
        out(type="result", state="failed", message="磁盘空间不足" if what == "disk_full" else "这一步失败", result={},
            diagnostics=[{"severity": "error", "code": code, "summary": "失败"}])
        sys.exit(1)
    out(type="result", state="succeeded", message="操作完成",
        result={"outputPath": "/out/" + r["gameId"] + "-" + platform, "ipa": "/out/" + r["gameId"] + ".ipa" if platform == "iphone" else None}, diagnostics=[])
''')

HARNESS = textwrap.dedent('''
    import sys
    sys.path.insert(0, sys.argv[1])
    import export_plan, main
    export_plan.child_command = lambda p: [sys.executable, sys.argv[2], "run", "--request", str(p)]
    sys.exit(main.run_request(sys.argv[3]))
''')


class ExportPlanTests(JobCase):
    def setUp(self):
        super().setUp()
        self.stubdir = self.root / "stub"; self.stubdir.mkdir()
        (self.stubdir / "stub.py").write_text(STUB)
        self.scenario({})
        self.n = 0

    def scenario(self, outcomes):
        (self.stubdir / "scenario.json").write_text(json.dumps(outcomes))

    def new_request(self, plan, **extra):
        self.n += 1
        task = f"exp-{self.n}"
        path = self.root / f"{task}.request.json"
        atomic(path, self.request_body(task, plan, **extra))
        os.chmod(path, 0o600)
        return task, path

    def request_body(self, task, plan, **extra):
        body = dict(self.request, taskId=task, operation="export", plan=plan)
        body.update(extra)
        return body

    def run_inline(self, path):
        stub = [sys.executable, str(self.stubdir / "stub.py")]
        with mock.patch.object(export_plan, "child_command", lambda p: stub + ["run", "--request", str(p)]):
            return main.run_request(path)

    def steps(self, task):
        return [(e["step"]["gameId"], e["step"]["platform"]) for e in read_events(self.c.private, task) if e["type"] == "step"]

    def seen(self, child):
        return json.loads((self.stubdir / "seen" / (child + ".json")).read_text())

    def two(self, location=None):
        return [{"gameId": A, "name": "甲", "platforms": ["iphone", "mac"]}, {"gameId": B, "name": "乙", "platforms": ["mac", "iphone"]}]

    # ① 单款就地出、全成功
    def test_inline_runs_mac_then_iphone_per_game_and_passes_request_fields(self):
        task, path = self.new_request({"source": "inline", "items": self.two(), "location": str(self.root / "loc"),
                                   "deviceTarget": {"productType": "iPhone18,2"}})
        self.assertEqual(self.run_inline(path), 0)
        self.assertEqual(self.steps(task), [(A, "mac"), (A, "iphone"), (B, "mac"), (B, "iphone")])   # 页面上 iPhone 在前也照 Mac 先（batch.PLATFORMS）
        record = journal(self.c.private, task)
        self.assertEqual(record["state"], "completed")
        mac, iphone = self.seen(f"{task}-1"), self.seen(f"{task}-2")
        self.assertEqual((mac["operation"], iphone["operation"]), ("build", "ipa"))
        self.assertEqual((mac["parentPid"], iphone["parentPid"]), (os.getpid(), os.getpid()))   # 本作业没了子作业跟着停
        self.assertEqual((mac["location"], iphone["location"]), (str(self.root / "loc"),) * 2)
        self.assertNotIn("target", mac); self.assertEqual(iphone["target"], {"productType": "iPhone18,2"})
        self.assertNotIn("followUp", iphone)   # iPhone 是这一款最后一个平台
        self.assertNotIn("plan", mac)
        ended = [e for e in read_events(self.c.private, task) if e["type"] == "stepEnded"]
        self.assertEqual([e["outcome"]["state"] for e in ended], ["completed"] * 4)
        self.assertEqual(ended[1]["outcome"]["ipa"], f"/out/{A}.ipa")
        self.assertFalse((self.c.private / "batch.json").exists())   # 就地出不写批次
        result = [e for e in read_events(self.c.private, task) if e["type"] == "result"][-1]
        self.assertEqual(result["result"]["summary"]["completed"], 2)

    # ② 按批次出、第 2 步磁盘满 → 暂停，独立终态 paused
    def test_batch_disk_full_pauses_with_terminal_state_paused(self):
        batch.save(self.c.private, batch.create(self.two()))
        self.scenario({f"{A}/iphone": "disk_full"})
        task, path = self.new_request({"source": "batch"})
        self.assertEqual(self.run_inline(path), 0)
        self.assertEqual(self.steps(task), [(A, "mac"), (A, "iphone")])   # B 一步没起
        saved = batch.load(self.c.private)
        self.assertEqual(saved["paused"], "disk_full")
        self.assertEqual(saved["items"][0]["results"]["iphone"], {"state": "failed", "message": "磁盘空间不足", "code": "disk_full"})
        self.assertEqual([saved["items"][1]["results"][p]["state"] for p in ("mac", "iphone")], ["pending", "pending"])
        self.assertEqual(journal(self.c.private, task)["state"], "paused")   # 不是 completed
        result = [e for e in read_events(self.c.private, task) if e["type"] == "result"][-1]
        self.assertEqual((result["state"], result["result"]["pausedReason"], result["result"]["stoppedAt"]), ("paused", "disk_full", 1))

    # 一款失败（非磁盘满）不挡后面
    def test_batch_other_failure_does_not_stop_the_rest(self):
        batch.save(self.c.private, batch.create(self.two()))
        self.scenario({f"{A}/mac": "fail"})
        task, path = self.new_request({"source": "batch"})
        self.assertEqual(self.run_inline(path), 0)
        self.assertEqual(len(self.steps(task)), 4)
        self.assertEqual(journal(self.c.private, task)["state"], "completed")
        self.assertEqual(batch.load(self.c.private)["items"][0]["results"]["mac"]["code"], "tool_exit")

    # ③ 出到第 3 步时取消：子作业收到 TERM；已出好的保留，正在出的和没开始的记已取消
    def test_cancel_forwards_to_child_and_keeps_finished(self):
        batch.save(self.c.private, batch.create(self.two()))
        self.scenario({f"{B}/mac": "slow"})
        task, path = self.new_request({"source": "batch"})
        p = subprocess.Popen([sys.executable, "-I", "-B", "-c", HARNESS, str(JOBS), str(self.stubdir / "stub.py"), str(path)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        pid_file = self.stubdir / "slow.pid"
        for _ in range(200):
            if pid_file.exists(): break
            time.sleep(0.05)
        self.assertTrue(pid_file.exists(), p.stderr.read() if p.poll() is not None else "桩没起来")
        child = int(pid_file.read_text())
        p.send_signal(signal.SIGTERM)
        self.assertEqual(p.wait(timeout=30), 130); p.stderr.close()
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)
        saved = batch.load(self.c.private)
        states = [[i["results"][pl]["state"] for pl in ("mac", "iphone")] for i in saved["items"]]
        self.assertEqual(states, [["completed", "completed"], ["cancelled", "cancelled"]])
        self.assertEqual(journal(self.c.private, task)["state"], "cancelled")

    # ⑦ 启动器退出（parentPid 没了）→ 停下记 paused、原因 launcher_exit；出好的保留，正在出的重新排队；「继续剩下的」只出没出的
    def test_launcher_exit_pauses_then_continue_runs_only_the_rest(self):
        batch.save(self.c.private, batch.create(self.two()))
        self.scenario({f"{A}/iphone": "fail", f"{B}/mac": "slow"})   # 前面那款失败过：停在哪款仍按正在出的那款报
        launcher = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])   # 假启动器
        self.addCleanup(lambda: launcher.poll() is None and launcher.kill())
        task, path = self.new_request({"source": "batch"}, parentPid=launcher.pid)
        p = subprocess.Popen([sys.executable, "-I", "-B", "-c", HARNESS, str(JOBS), str(self.stubdir / "stub.py"), str(path)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pid_file = self.stubdir / "slow.pid"
        for _ in range(200):
            if pid_file.exists(): break
            time.sleep(0.05)
        self.assertTrue(pid_file.exists())
        launcher.kill(); launcher.wait()   # 玩家退出启动器
        self.assertEqual(p.wait(timeout=30), 0)
        record = journal(self.c.private, task)
        self.assertEqual(record["state"], "paused")
        self.assertIn("第 2 款", record["message"])
        result = [e for e in read_events(self.c.private, task) if e["type"] == "result"][-1]["result"]
        self.assertEqual((result["pausedReason"], result["stoppedAt"]), ("launcher_exit", 2))
        saved = batch.load(self.c.private)
        self.assertEqual([saved["items"][0]["results"][pl]["state"] for pl in ("mac", "iphone")], ["completed", "failed"])
        self.assertEqual(saved["items"][1]["results"]["mac"], {"state": "pending", "interrupted": True})
        self.assertEqual(saved["items"][1]["results"]["iphone"], {"state": "pending"})
        self.assertIsNone(saved["paused"])   # 不是磁盘满：「继续」不用先「重试」
        # 重开启动器点「继续剩下的」：只出 B 的两个平台
        self.scenario({})
        again, path2 = self.new_request({"source": "batch"})
        self.assertEqual(self.run_inline(path2), 0)
        self.assertEqual(self.steps(again), [(B, "mac"), (B, "iphone")])
        self.assertEqual(batch.summary(batch.load(self.c.private))["completed"], 1)   # A 的 iPhone 失败过，「继续」不重出它（走「重试」）

    # 这台电脑出不了的平台：不起子作业、直接记失败，不挡同一款别的平台
    def test_unsupported_platform_marked_failed_without_child(self):
        with mock.patch.object(export_plan, "SUPPORTED", ("iphone",)):
            task, path = self.new_request({"source": "inline", "items": [{"gameId": A, "name": "甲", "platforms": ["mac", "iphone"]}]})
            self.assertEqual(self.run_inline(path), 0)
        ended = [e for e in read_events(self.c.private, task) if e["type"] == "stepEnded"]
        self.assertEqual([(e["step"]["platform"], e["outcome"]["state"]) for e in ended], [("mac", "failed"), ("iphone", "completed")])
        self.assertEqual(ended[0]["outcome"]["message"], "这台电脑出不了这个平台的包")
        self.assertFalse((self.stubdir / "seen" / f"{task}-1.json").exists())   # Mac 那步没起子作业
        self.assertTrue((self.stubdir / "seen" / f"{task}-2.json").exists())

    # ④ 批次记录写不进 → 本作业失败、说清是批次记录，一步都不起
    def test_batch_record_unwritable_fails_loudly(self):
        batch.save(self.c.private, batch.create(self.two()))
        (self.c.private / "batch.json.tmp").mkdir()   # 写临时文件那一下就失败
        task, path = self.new_request({"source": "batch"})
        self.assertEqual(self.run_inline(path), 1)
        record = journal(self.c.private, task)
        self.assertEqual((record["state"], record["diagnostics"][-1]["code"]), ("failed", "batch_record_failed"))
        self.assertIn("batch.json", record["message"])
        self.assertEqual(self.steps(task), [])

    # ⑤ 已有一个编排在跑 → library_busy、点名占着的
    def test_second_export_is_busy_and_names_holder(self):
        holder = {"taskId": "exp-other", "operation": "export", "pid": 1, "startedAt": 1.0}
        with filelock.held(self.c.private / "export.lock", holder=holder):
            task, path = self.new_request({"source": "inline", "items": self.two()})
            self.assertEqual(self.run_inline(path), 1)
        record = journal(self.c.private, task)
        self.assertEqual(record["diagnostics"][-1]["code"], "library_busy")
        self.assertEqual(record["diagnostics"][-1]["holder"]["taskId"], "exp-other")

    # ⑥ 启动器那端读管道断了 → 照跑完，事件全在记录里；子作业的转发事件不进本作业记录（子作业自己有）
    def test_broken_pipe_keeps_running_and_records(self):
        task, path = self.new_request({"source": "inline", "items": self.two()})
        p = subprocess.Popen([sys.executable, "-I", "-B", "-c", HARNESS, str(JOBS), str(self.stubdir / "stub.py"), str(path)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p.stdout.readline(); p.stdout.close()   # 读到第一行就走
        self.assertEqual(p.wait(timeout=60), 0)
        self.assertEqual(journal(self.c.private, task)["state"], "completed")
        events = read_events(self.c.private, task)
        self.assertEqual([e["type"] for e in events].count("stepEnded"), 4)
        self.assertNotIn("child", [e["type"] for e in events])
        self.assertTrue(read_events(self.c.private, f"{task}-1") or (self.stubdir / "seen" / f"{task}-1.json").exists())

    def test_outcome_carries_degrade_notes(self):
        # v0.3.1：子作业结果里的 notes（降级继续的玩家提示）原样进 stepEnded 的 outcome，完成卡读它；没有就不带
        last = dict(type="result", state="succeeded", message="", result=dict(ipa="/out/a.ipa", notes=["提示一", "提示二"]))
        self.assertEqual(export_plan._outcome(self.c, None, last)["notes"], ["提示一", "提示二"])
        last["result"].pop("notes")
        self.assertNotIn("notes", export_plan._outcome(self.c, None, last))

    def test_bad_plan_rejected(self):
        task, path = self.new_request({"source": "nope"})
        self.assertEqual(self.run_inline(path), 1)
        self.assertIn("plan.source", journal(self.c.private, task)["message"])


if __name__ == "__main__":
    unittest.main()
