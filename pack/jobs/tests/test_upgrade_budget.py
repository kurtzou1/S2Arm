# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级升级队列（sgrade.upgrade_batch，排队只在作业层一套）与资源上限（upgrade_budget）。期望按规则手写，不跑被测实现推：
① 逐款串行、去重、按提交顺序；别的窗口读得到在跑那款与进度；这款正在运行 → skipped、出错 → incomplete，都接着做下一款
② 在跑时再提交：追加到队尾、立刻返回 joined；在跑 / 已排的号不重复
③ 停止 / 取消：排着的不做，正做的那款 incomplete（未完成标记留着）；跑队列的作业已不在 → 不续跑
④ 并行度：核数上限 = 物理核一半；内存预算 = 可用内存一半，重活每路 1.5 GB、文件级每路 0.5 GB；可用内存降 → 路数降；有游戏在运行 → 1 路
⑤ 作业环境：升级作业起子进程带上算好的 S2A_JOBS / S2A_CPU_BAKE；execution 锁有人拿着（玩家在玩）→ 1；别的作业不带
⑥ 优先级：升级作业（队列 / 单款）降到后台档，且不拿自动任务锁"""
import contextlib
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase
from jobcase import JobCase
import filelock
import layout
import sgrade
import upgrade_budget
from core import Cancelled, Failure


class QueueTests(unittest.TestCase):
    """升级队列（sgrade.upgrade_batch）：游戏库换临时目录，单款升级换替身（记并发 / 顺序），队列文件真读写"""
    def setUp(self):
        import tempfile
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(__import__("shutil").rmtree, self.t, True)
        self.events, self.seen, self.active = [], [], [0]

    def ctx(self, task, ids):
        c = types.SimpleNamespace(r={"gameIds": ids, "other": 1}, task=task, logs=self.t, library=self.t, private=self.t)
        c.emit = lambda kind, text="", **kw: self.events.append((kind, dict(kw, gameId=c.r.get("gameId"))))
        return c

    def run_batch(self, c, fake):
        with patch.object(sgrade, "upgrade_game", side_effect=fake):
            return sgrade.upgrade_batch(c)

    def fake(self, extra=None):
        def f(c, on_progress=None):
            self.active[0] += 1
            self.assertEqual(self.active[0], 1, "同一时刻只升一款")
            gid = c.r["gameId"]; self.seen.append(gid)
            self.assertEqual(c.r["other"], 1)
            try:
                on_progress(0); on_progress(0.5)
                st = {x["gameId"]: x for x in sgrade.queue_status(self.ctx("reader", []))["games"]}
                self.assertEqual((st[gid]["state"], st[gid]["progress"]), ("running", 0.5), "别的窗口读得到在跑那款与进度")
                if extra:
                    extra(gid)
                on_progress(1.0)
                return dict(gameId=gid, updated=[gid], steps={})
            finally:
                self.active[0] -= 1
        return f

    def test_serial_statuses_events(self):
        def extra(gid):
            if gid == "0100B":
                raise Failure("这款游戏正在运行或正在升级", code="library_busy")
            if gid == "0100C":
                raise RuntimeError("坏了")
        r = self.run_batch(self.ctx("q1", ["0100a", "0100B", "0100A", "0100C", "0100D"]), self.fake(extra))
        self.assertEqual(self.seen, ["0100A", "0100B", "0100C", "0100D"], "去重、按提交顺序、串行")
        self.assertEqual([(g["gameId"], g["state"]) for g in r["games"]],
                         [("0100A", "done"), ("0100B", "skipped"), ("0100C", "incomplete"), ("0100D", "done")])
        self.assertEqual((r["running"], r["index"], r["count"], r["updated"]), (False, 4, 4, ["0100A", "0100D"]))
        batch = [(e["phase"], e["index"], e["count"], e["gameId"], e.get("status")) for k, e in self.events if k == "batch"]
        self.assertEqual(batch[:4], [("start", 1, 4, "0100A", None), ("end", 1, 4, "0100A", "done"), ("start", 2, 4, "0100B", None), ("end", 2, 4, "0100B", "skipped")])
        self.assertEqual(len(batch), 8)

    def test_submit_while_running_appends(self):
        # 第一款升着时另一个窗口 / 单点又提交（含已在队里的号）：追加到队尾、立刻返回 joined，由跑队列的作业接着做
        joined = []
        def extra(gid):
            if gid == "0100A":
                joined.append(sgrade.upgrade_batch(self.ctx("q2b", ["0100B", "0100A", "0100C"])))
        r = self.run_batch(self.ctx("q2", ["0100A", "0100B"]), self.fake(extra))
        self.assertEqual((joined[0]["joined"], joined[0]["added"]), ("q2", ["0100C"]), "在跑 / 已排的号不重复")
        self.assertEqual(self.seen, ["0100A", "0100B", "0100C"])
        self.assertEqual([g["state"] for g in r["games"]], ["done", "done", "done"])

    def test_cancel_drops_queued_marks_current(self):
        def extra(gid):
            if gid == "0100B":
                raise Cancelled()
        with self.assertRaises(Cancelled):
            self.run_batch(self.ctx("q3", ["0100A", "0100B", "0100C"]), self.fake(extra))
        st = sgrade.queue_status(self.ctx("reader", []))
        self.assertEqual(self.seen, ["0100A", "0100B"], "排着的不做")
        self.assertEqual([(g["gameId"], g["state"]) for g in st["games"]], [("0100A", "done"), ("0100B", "incomplete")])
        self.assertFalse(st["running"])

    def test_dead_runner_not_resumed(self):
        # 跑队列的作业已不在（启动器退出）：在跑那款读成 incomplete、排着的去掉；再提交就是新的一批（不续跑旧的）
        (self.t / sgrade.QUEUE).write_text(json.dumps(dict(task="old", pid=2 ** 22 + 12345, items=[
            dict(gameId="0100A", state="done"), dict(gameId="0100B", state="running", progress=0.5), dict(gameId="0100C", state="queued")])))
        st = sgrade.queue_status(self.ctx("reader", []))
        self.assertEqual(([(g["gameId"], g["state"]) for g in st["games"]], st["running"]), ([("0100A", "done"), ("0100B", "incomplete")], False))
        r = self.run_batch(self.ctx("q4", ["0100D"]), self.fake())
        self.assertEqual((self.seen, r["count"]), (["0100D"], 1))

    def test_stop_cancels_runner(self):
        from core import pid_start
        (self.t / sgrade.QUEUE).write_text(json.dumps(dict(task="run1", pid=os.getpid(), pidStart=pid_start(os.getpid()), items=[dict(gameId="0100A", state="running")])))
        import core
        with patch.object(core, "cancel", side_effect=lambda private, task, sig="TERM": dict(cancelled=True, task=task)) as m:
            r = sgrade.upgrade_stop(self.ctx("stop", []))
        self.assertEqual((r["stopped"], r["task"]), (True, "run1"))
        m.assert_called_once()
        self.assertEqual(m.call_args[0][1], "run1")

    def test_cancel_keeps_marker(self):
        # 单款升级做到 iPhone 段时被取消（适配层 SIGTERM → core 置取消，下一次 emit / run 抛 Cancelled）：标记留着 = 未完成，取消照常往外抛
        t = self.t
        (t / "0100A").mkdir()
        c = types.SimpleNamespace(r={"gameId": "0100A"}, task="s1", logs=t, emit=lambda *a, **k: None, begin=lambda *a, **k: None,
                                  idle=lambda name: contextlib.nullcontext(True))
        def ios(c, games):
            raise Cancelled()
        import ipa, rewrite_refresh
        with patch.object(layout, "game_dir", lambda c, g: t / g.upper()), patch.object(layout, "image_mac", lambda c, g, create=True: t / "none"), \
             patch.object(layout, "has_ios_kit", lambda c, g: True), patch.object(ipa, "program_locks", lambda c, games: contextlib.nullcontext()), \
             patch.object(rewrite_refresh, "refresh_ios", ios):
            with self.assertRaises(Cancelled):
                sgrade.upgrade_game(c)
        m = json.loads((t / "0100A" / sgrade.UPGRADING).read_text())
        self.assertEqual((m["task"], m["pid"]), ("s1", os.getpid()), "进程退出后 pid 不在 → upgrade_state = incomplete（test_sgrade.test_upgrade_state）")


class BudgetPlanTests(unittest.TestCase):
    def test_plan(self):
        P = lambda cores, mb, busy=False: (lambda p: (p["cap"], p["budgetMb"], p["jobs"], p["bake"]))(upgrade_budget.plan(cores, mb, busy))
        self.assertEqual(P(8, 16384), (4, 8192, 4, 4))     # 16 GB 机器空着：8192 ÷ 1536 = 5 → 封在核数上限 4
        self.assertEqual(P(8, 8192), (4, 4096, 4, 2))      # 4096 ÷ 1536 = 2
        self.assertEqual(P(8, 4096), (4, 2048, 4, 1))      # 8 GB 机器常见可用：重活 1 路
        self.assertEqual(P(8, 2048), (4, 1024, 2, 1))      # 再紧：文件级 1024 ÷ 512 = 2
        self.assertEqual(P(8, 600), (4, 300, 1, 1))        # 下限 1
        self.assertEqual(P(16, 65536), (8, 32768, 8, 8))
        self.assertEqual(P(1, 65536), (1, 32768, 1, 1))
        self.assertEqual(P(8, 16384, True)[2:], (1, 1), "有游戏在运行：都降到 1")
        p = upgrade_budget.plan(8, None)
        self.assertEqual((p["jobs"], p["bake"]), (2, 1), "读不到内存：核数上限再减半、重活 1 路")

    def test_available_override(self):
        with patch.dict(os.environ, {"S2A_MEM_AVAIL_MB": "4096"}):
            self.assertEqual(upgrade_budget.available_mb(), 4096)

    def test_available_real_machine(self):
        mb = upgrade_budget.available_mb()
        if sys.platform in ("darwin", "win32", "linux"):
            self.assertIsNotNone(mb, "本机读得到可用内存")
            self.assertGreater(mb, 0)
        self.assertGreaterEqual(upgrade_budget.physical_cores(), 1)


class BudgetEnvTests(JobCase):
    def env(self, op):
        self.c.operation = op
        return self.c.env()

    def test_upgrade_env_follows_memory_and_play(self):
        with patch.object(upgrade_budget, "physical_cores", return_value=8):
            with patch.dict(os.environ, {"S2A_MEM_AVAIL_MB": "4096"}):
                e = self.env("sgradeUpgradeGame")
                self.assertEqual((e["S2A_JOBS"], e["S2A_CPU_BAKE"]), ("4", "1"))
            with patch.dict(os.environ, {"S2A_MEM_AVAIL_MB": "16384"}):
                e = self.env("sgradeUpgradeGame")
                self.assertEqual((e["S2A_JOBS"], e["S2A_CPU_BAKE"]), ("4", "4"), "可用内存回来了，下一个阶段路数跟着回来")
                with filelock.held(Path(self.c.library) / ".execution.lock", holder={"taskId": "play", "operation": "launch"}):
                    e = self.env("sgradeUpgradeGame")
                self.assertEqual((e["S2A_JOBS"], e["S2A_CPU_BAKE"]), ("1", "1"), "玩家在玩：降到 1 路")
                e = self.env("ipa")
                self.assertNotIn("S2A_CPU_BAKE", e, "别的作业不带（出包仍按 tools/cores.sh / 阶段脚本自己定）")
        log = (self.c.logs / f"{self.c.task}-decisions.log").read_text(encoding="utf-8")
        self.assertIn("有游戏在运行", log)


class PriorityTests(JobCase):
    def test_upgrade_ops_lower_priority_without_auto_lock(self):
        import main
        from core import atomic
        calls, held = [], []
        def probe(c):
            try:
                with filelock.held(Path(self.request["library"]) / ".auto-heavy.lock", wait_s=0):
                    held.append(False)
            except filelock.Busy:
                held.append(True)
            return {}
        for op in ("sgradeUpgradeGame", "sgradeUpgradeBatch", "catalog"):
            path = self.root / ("req-" + op + ".json")
            atomic(path, self.request | dict(taskId="p-" + op, operation=op))
            with patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"), \
                    patch.object(main, "background_priority", lambda op=op: calls.append(op)):
                main.run_request(path, operation_overrides={op: probe})
        self.assertEqual(calls, ["sgradeUpgradeGame", "sgradeUpgradeBatch"])
        self.assertEqual(held, [False, False, False], "玩家点的升级不排在自动任务锁后面")


if __name__ == "__main__":
    unittest.main()
