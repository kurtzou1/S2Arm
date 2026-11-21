# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳「更新所选」（pack/jobs/install.py push_selected）：所选几款按顺序 push_game，一款失败不挡下一款、换哪款都做不下去才整轮停、
可停（取消）、可续推。push_game 用替身按剧本给结果，期望按剧本手写。"""
import contextlib
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import program_pack  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from core import Cancelled, Failure  # noqa: E402

A, B, C = "0100000000010000", "0100000000020000", "0100000000030000"


class PushSelected(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def run_job(self, script, device="PHONE-1", on=True, **req):
        """script：{游戏号: 抛的异常 | None（推成）}；→ (结果, 实际推过的游戏号)"""
        pushed = []
        def fake_push(c, g, ph, steps=True):
            pushed.append(g)
            assert steps is False, "多款时不另起每款内部的阶段"
            e = script.get(g)
            if e is not None:
                raise e
        self.c.r.clear(); self.c.r.update(req)
        ph = types.SimpleNamespace(key=device)
        with patch.object(install, "push_game", fake_push), \
                patch.object(install, "push_phone", lambda c: ph), patch.object(install, "packer_phone_lock", lambda c: contextlib.nullcontext()), \
                patch.object(install, "trace", lambda *a, **k: None):
            try:
                return install.push_selected(self.c), pushed
            except BaseException as e:
                return e, pushed

    def progress(self):
        return install.read(self.c.private / install.PUSH_SELECTED, {})

    def test_one_failure_does_not_block_next(self):
        r, pushed = self.run_job({B: Failure("这款资源包缺件", code="pack_missing")}, gameIds=[A, B.lower(), C, A])
        self.assertEqual(pushed, [A, B, C], "按所选顺序、去重、大写")
        st = self.progress()
        self.assertEqual((st["done"], list(st["failed"])), ([A, C], [B]))

    def test_unexpected_error_recorded_and_continues(self):
        r, pushed = self.run_job({A: RuntimeError("意外")}, gameIds=[A, B])
        self.assertEqual(pushed, [A, B])
        self.assertEqual((self.progress()["failed"][A]["code"], self.progress()["done"]), ("job_failed", [B]))

    def test_any_failure_fails_the_job_with_first_reason(self):
        # #1756：0.5 升 0.6.0 的玩家点「更新所选」，每款都在推 .s2arm 时「找不到设备」，作业却报完成——界面进度条跑完、总控台还是「更新」、手机上还是「需要导入」。
        #   期望（手写）：推完一轮后整单失败，原因与码 = 第一款失败的原话；推成的照记
        boom = Failure("资源包写进 iPhone 时中断（找不到设备 X：device not found）", code="resource_transfer_failed")
        r, pushed = self.run_job({A: boom, B: boom}, gameIds=[A, B, C])
        self.assertEqual(pushed, [A, B, C], "一款失败不挡后面的")
        self.assertIsInstance(r, Failure)
        self.assertEqual((r.code, str(r)), ("resource_transfer_failed", str(boom)))
        self.assertEqual(self.progress()["done"], [C])
        self.assertEqual([(g["gameId"], g["ok"], g.get("code")) for g in r.facts["games"]],
                         [(A, False, "resource_transfer_failed"), (B, False, "resource_transfer_failed"), (C, True, None)], "逐款结果进机读事实：失败页逐款写原因、重试只推没成的")
        r, pushed = self.run_job({}, gameIds=[A, B])
        self.assertIsInstance(r, dict, "全推成：照常报完成")
        self.assertEqual((r["done"], r["failed"]), (2, 0))

    def test_stop_codes_end_the_round(self):
        for code in install.PUSH_SELECTED_STOP:
            r, pushed = self.run_job({B: Failure("做不下去", code=code)}, gameIds=[A, B, C])
            self.assertIsInstance(r, Failure); self.assertEqual(r.code, code)
            self.assertEqual(pushed, [A, B], f"{code}：换哪款都做不下去，不再推 C")

    def test_cancel_then_resume(self):
        r, pushed = self.run_job({B: Cancelled()}, gameIds=[A, B, C])
        self.assertIsInstance(r, Cancelled)
        self.assertEqual(pushed, [A, B])
        r, pushed = self.run_job({}, resume=True)
        self.assertEqual(pushed, [B, C], "续推：从没推成的接着来，推完的 A 不再推")
        self.assertEqual((r["done"], r["remaining"]), (2, 0))
        r, pushed = self.run_job({}, resume=True)
        self.assertEqual((pushed, r["remaining"]), ([], 0), "这一轮都推完了：续推没有要推的")

    def test_resume_retries_failed_and_only_same_phone(self):
        self.run_job({B: Failure("缺件", code="pack_missing")}, gameIds=[A, B])
        r, pushed = self.run_job({}, device="PHONE-2", resume=True)
        self.assertEqual(pushed, [], "换了一台手机：上一轮的进度不算这台的")
        self.run_job({B: Failure("缺件", code="pack_missing")}, gameIds=[A, B])
        r, pushed = self.run_job({}, resume=True)
        self.assertEqual(pushed, [B], "失败的那款续推时再试")

if __name__ == "__main__":
    unittest.main()
