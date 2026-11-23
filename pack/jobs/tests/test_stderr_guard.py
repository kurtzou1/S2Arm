# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""作业进程标准错误写不进（D-FPQ8 等 34 份，Windows 上启动器读端没了再写 → OSError [Errno 22]）：只丢日志、不让任务失败。期望按构造手写：
① 包装：原流写入抛 Errno 22 → 不抛，第一次起改写兜底文件（头一行写明原因），之后的内容都在文件里；fileno 给兜底文件的；流已关（ValueError）同样处理
② 真 main.run_request：作业期间 stderr 是断的、作业函数照样 print 到 stderr → 任务成功，作业打的那行落进 <任务>-stderr.log；跑完 sys.stderr 换回原来的"""
import io
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from core import atomic, read
import main


class Broken(io.TextIOBase):
    def __init__(self, error): self.error, self.calls = error, 0
    def write(self, s): self.calls += 1; raise self.error
    def flush(self): raise self.error
    def fileno(self): return 2


class Guard(JobCase):
    def test_broken_pipe_spills_to_file(self):
        for error in (OSError(22, "Invalid argument"), ValueError("I/O operation on closed file.")):
            with self.subTest(error=type(error).__name__):
                f = self.root / f"spill-{type(error).__name__}.log"
                raw = Broken(error); g = main.StderrGuard(raw, f)
                print("[装机] 第一行", file=g, flush=True)
                print("[s2a] 第二行", file=g, flush=True)
                self.assertEqual(raw.calls, 1)   # 断了以后不再碰原句柄
                text = f.read_text(encoding="utf-8")
                self.assertIn("标准错误写不进了", text); self.assertIn("[装机] 第一行", text); self.assertIn("[s2a] 第二行", text)
                self.assertNotEqual(g.fileno(), 2)

    def test_healthy_stream_untouched(self):
        buf = io.StringIO(); f = self.root / "never.log"
        g = main.StderrGuard(buf, f)
        print("照常", file=g, flush=True)
        self.assertEqual(buf.getvalue(), "照常\n"); self.assertFalse(f.exists())

    def test_job_survives_broken_stderr(self):
        def op(c):
            print("[装机] 往断掉的 stderr 打一行", file=sys.stderr, flush=True)
            return {"ok": True}
        path = self.root / "req-broken.json"
        atomic(path, self.request | dict(taskId="broken-stderr", operation="status"))
        before = Broken(OSError(22, "Invalid argument"))
        with patch.object(sys, "stderr", before), patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"):
            rc = main.run_request(path, operation_overrides={"status": op})
            self.assertIs(sys.stderr, before)   # 跑完换回
        self.assertEqual(rc, 0)
        logs = [p for p in Path(self.request["privateRoot"]).rglob("broken-stderr-stderr.log")]
        self.assertEqual(len(logs), 1, list(Path(self.request["privateRoot"]).rglob("*stderr*")))
        self.assertIn("往断掉的 stderr 打一行", logs[0].read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
