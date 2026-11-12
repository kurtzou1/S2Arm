# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包 / 推送期间电脑不空闲休眠（awake.py）。期望按规则手写，不起真 caffeinate、不调真 Windows 接口：
① Mac：作业跑的时候有一个 caffeinate -i -w <本进程号>，作业完成 / 失败 / 取消后都停掉；② Windows：开头 ES_CONTINUOUS|ES_SYSTEM_REQUIRED、结束改回 ES_CONTINUOUS；
③ 只有出包 / 推送类作业挂（main.KEEP_AWAKE），游戏库刷新这类不挂；④ caffeinate 起不来照常跑作业"""
import os
import sys
import types
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import atomic, Failure, Cancelled
import awake
import main


class FakeProc:
    started = []

    def __init__(self, argv):
        self.argv, self.alive = argv, True
        FakeProc.started.append(self)

    def poll(self):
        return None if self.alive else 0

    def terminate(self):
        self.alive = False

    def wait(self, timeout=None):
        return 0

    def kill(self):
        self.alive = False


class KeepAwakeTests(unittest.TestCase):
    def setUp(self):
        FakeProc.started = []

    def test_mac_holds_caffeinate_for_this_process_and_stops_it(self):
        with patch.object(awake.sys, "platform", "darwin"), patch.object(awake, "_spawn", FakeProc):
            with awake.keep_awake():
                self.assertEqual(len(FakeProc.started), 1)
                self.assertEqual(FakeProc.started[0].argv, ["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())])
                self.assertTrue(FakeProc.started[0].alive)
        self.assertFalse(FakeProc.started[0].alive)

    def test_mac_released_when_the_job_raises(self):
        with patch.object(awake.sys, "platform", "darwin"), patch.object(awake, "_spawn", FakeProc):
            with self.assertRaises(Cancelled):
                with awake.keep_awake():
                    raise Cancelled()
        self.assertFalse(FakeProc.started[0].alive)

    def test_mac_without_caffeinate_still_runs(self):
        def missing(*a, **k):
            raise FileNotFoundError("caffeinate")
        ran = []
        with patch.object(awake.sys, "platform", "darwin"), patch.object(awake, "_spawn", missing):
            with awake.keep_awake():
                ran.append(1)
        self.assertEqual(ran, [1])

    def test_windows_sets_then_restores_execution_state(self):
        calls = []
        kernel = types.SimpleNamespace(SetThreadExecutionState=lambda v: calls.append(v) or 1)
        fake_ctypes = types.SimpleNamespace(windll=types.SimpleNamespace(kernel32=kernel))
        with patch.object(awake.sys, "platform", "win32"), patch.object(awake.os, "name", "nt"), patch.dict(sys.modules, {"ctypes": fake_ctypes}):
            with awake.keep_awake():
                self.assertEqual(calls, [0x80000001])
        self.assertEqual(calls, [0x80000001, 0x80000000])


class JobKeepAwakeTests(JobCase):
    """真 main.run_request + 打桩的作业函数：出包 / 推送类作业期间拿着，别的作业不拿；作业失败也放开"""
    def run_op(self, op, fn):
        path = self.root / ("req-" + op + ".json")
        atomic(path, self.request | dict(taskId="awake-" + op, operation=op))
        with patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"):
            return main.run_request(path, operation_overrides={op: fn})

    def test_build_and_push_hold_while_running_others_do_not(self):
        held = []
        def probe(c):
            held.append((c.operation, len(FakeProc.started) == 1 and FakeProc.started[0].alive))
            return {}
        for op in ("build", "ipa", "install", "installUpdate", "installRestore", "catalog"):
            FakeProc.started = []
            with patch.object(awake.sys, "platform", "darwin"), patch.object(awake, "_spawn", FakeProc):
                self.run_op(op, probe)
            if FakeProc.started:
                self.assertFalse(FakeProc.started[0].alive, f"{op} 结束后 caffeinate 还在")
        self.assertEqual(held, [("build", True), ("ipa", True), ("install", True), ("installUpdate", True), ("installRestore", True), ("catalog", False)])

    def test_failed_push_releases(self):
        FakeProc.started = []
        def boom(c):
            raise Failure("推送断了")
        with patch.object(awake.sys, "platform", "darwin"), patch.object(awake, "_spawn", FakeProc):
            self.assertEqual(self.run_op("install", boom), 1)
        self.assertEqual(len(FakeProc.started), 1)
        self.assertFalse(FakeProc.started[0].alive)


if __name__ == "__main__":
    unittest.main()
