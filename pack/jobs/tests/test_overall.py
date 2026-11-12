# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""整单进度 overall（pack/jobs/overall.py）用两份真实出包事件流回放（脱敏，只留类型 / 时刻 / 里程碑 / 状态 / plan 权重）：
维护者 11-11「91% 又跳回 40%」「91% 到 99% 又跳回来」。期望值按事件手算，写成算式，不调实现"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import overall  # noqa: E402


def replay(name):
    o, seq = overall.Overall(), []
    for line in (HERE / "fixtures" / name).read_text(encoding="utf-8").splitlines():
        e = json.loads(line)
        if e["type"] == "plan":
            o.plan(e["milestones"])
        v = o.feed(e["type"], e["elapsed"], e["milestone"], e["state"])
        seq.append((e, v))
    return seq


class Replay(unittest.TestCase):
    def test_windows_run_never_goes_back_and_failure_stays_below_100(self):
        # joe-win v0.3.0 候选出 iPhone 包：编译着色器库里 5 套计数器先后出现，写单一 IMG 时失败
        seq = replay("progress_win_ipa_failed_img.jsonl")
        values = [v for _, v in seq if v is not None]
        self.assertTrue(values)
        self.assertEqual(values, sorted(values), "整条进度只增不减")
        self.assertLess(values[-1], 1.0, "失败的作业到不了 100%")
        total = 2.5 + 94.8 + 121.7 + 19.6
        first_direct = next(v for e, v in seq if e["milestone"] == "direct")
        self.assertAlmostEqual(first_direct, round((2.5 + 94.8) / total, 4), "进编译着色器库那一刻 = 前两步权重和 ÷ 总和")
        last_direct = [(e, v) for e, v in seq if e["milestone"] == "direct"][-1]
        t0 = next(e["elapsed"] for e, _ in seq if e["milestone"] == "direct")
        inside = min(0.95, (last_direct[0]["elapsed"] - t0) / 121.7)
        self.assertAlmostEqual(last_direct[1], round((2.5 + 94.8 + 121.7 * inside) / total, 4))
        self.assertLessEqual(max(values), 0.99)

    def test_mac_run_without_history_moves_by_steps_and_ends_at_100(self):
        # 全新数据目录：plan 各步都没有历史（expected None）→ 5 步等权、步内不按时间推；成功结果才 100%
        seq = replay("progress_mac_ipa_ok.jsonl")
        values = [v for _, v in seq if v is not None]
        self.assertEqual(values, sorted(values))
        firsts = {}
        for e, v in seq:
            if e["milestone"] and e["milestone"] not in firsts:
                firsts[e["milestone"]] = v
        self.assertEqual(firsts, {"unpack": 0.0, "refresh": 0.2, "analyze": 0.4, "direct": 0.6, "ipa": 0.8})
        self.assertEqual(seq[-1][0]["type"], "result")
        self.assertEqual(seq[-1][1], 1.0)
        self.assertEqual([v for e, v in seq if e["type"] != "result"][-1], 0.8, "收尾几个 1/1 的阶段（清理、写 IMG、组装 ipa）不回退也不提前到 100")

    def test_old_frontend_formula_did_go_back(self):
        # 负对照：原来前端按「本步当前计数器 done/total」填当前一步，同一份 Windows 事件流会回退（证明回放能抓住这个 bug）
        seq = replay("progress_win_ipa_failed_img.jsonl")
        w = {"unpack": 2.5, "refresh": 94.8, "direct": 121.7, "ipa": 19.6}
        order = list(w); total = sum(w.values()); old = []
        for e, _ in seq:
            m = e["milestone"]
            if m not in w:
                continue
            fill = min(1, e["done"] / e["total"]) if e["type"] == "progress" and e["total"] else 0
            old.append((sum(w[x] for x in order[:order.index(m)]) + w[m] * fill) / total)
        self.assertTrue(any(b < a for a, b in zip(old, old[1:])), "旧算法在这份事件流上确有回退")

    def test_jobs_without_plan_move_by_steps(self):
        # 装到手机 / 更新手机上的 S2Arm 等没有 plan 的作业：按「第几步 / 共几步」+ 本步计数推，只增不减，成功才 1。期望手算
        o = overall.Overall()
        self.assertEqual(o.feed("stage", 0.1, None, "running", 1, 6), 0.0)
        self.assertEqual(o.feed("stage", 2.0, None, "running", 2, 6), round(1 / 6, 4))
        self.assertEqual(o.feed("progress", 9.0, None, "running", 5, 6, 50, 100), round((4 + 0.5) / 6, 4))
        self.assertEqual(o.feed("stage", 9.5, None, "running", 1, 1), round((4 + 0.5) / 6, 4), "收尾的 1/1 阶段不让进度回退")
        self.assertEqual(o.feed("result", 10.0, None, "succeeded"), 1.0)
        f = overall.Overall()
        f.feed("stage", 0.1, None, "running", 2, 4)
        self.assertEqual(f.feed("result", 1.0, None, "failed"), 0.25, "失败停在原处")

    def test_no_plan_no_overall(self):
        o = overall.Overall()
        self.assertIsNone(o.feed("progress", 1.0, None))
        self.assertIsNone(o.feed("result", 2.0, None, "succeeded"))


if __name__ == "__main__":
    unittest.main()
