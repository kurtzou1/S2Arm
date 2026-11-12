"""里程碑进度单测：预计秒数只来自本机同种任务历史（没有就不给）、直连库阶段观察（期望值手算，不跑被测逻辑推）。"""
import json
from pathlib import Path
import sys
import tempfile
import types
import threading
from unittest import mock
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import milestones as ms  # noqa: E402


class Estimates(unittest.TestCase):
    def ctx(self, rows=()):
        d = Path(tempfile.mkdtemp())
        if rows:
            (d / "stats").mkdir()
            (d / "stats" / "prepare.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        return types.SimpleNamespace(private=d)

    def test_no_history_means_no_estimate(self):
        # 本机没有记录：每一步都是 None / none，不拿别的游戏的旧实测顶（维护者 10-25）
        d = ms.estimate_details(self.ctx(), 6.2, "ipa_dual")
        self.assertEqual(len(d), 7)
        for row in d.values():
            self.assertIsNone(row["seconds"]); self.assertEqual((row["source"], row["samples"]), ("none", 0))

    def test_plans_per_kind(self):
        # 只有直连（11-07 拆兼容模式 build / ipa 两种只出通用的计划）：打 iPhone 包 / Mac 打包各一种
        self.assertEqual(set(ms.PLANS), {"ipa_dual", "build_dual", "ipa_downstream"})
        self.assertEqual(ms.PLANS["ipa_downstream"], ["unpack", "ipa"])   # 下游深度方案：共用解包 → 下游做包工具（pack/jobs/downstream.py）
        # 出包不再整份重算原件校验（11-07 维护者：玩家导入之后不会换原件，导入时算过一次 sha256）：任何计划里都没有 verify 段
        for kind, plan in ms.PLANS.items(): self.assertNotIn("verify", plan, kind)

    def test_dual_plan_matches_refresh(self):
        # 直连包（iPhone / Mac 同一条 refresh.sh）：解包 → 改写与准备 → 直连库 →（编 App / 准备主程序与安装）
        self.assertEqual(ms.PLANS["ipa_dual"], ["unpack", "refresh", "analyze", "direct", "ipa"])
        self.assertEqual(ms.PLANS["build_dual"], ["unpack", "refresh", "analyze", "direct", "host", "install"])
        ids = {m for m, *_ in ms.MILESTONES}
        for plan in ms.PLANS.values():
            self.assertLessEqual(set(plan), ids)

    def test_history_median_per_gb(self):
        rows = [dict(kind="build_dual", size_gb=2, seconds={"direct": 100}), dict(kind="build_dual", size_gb=1, seconds={"direct": 30}),
                dict(kind="build_dual", size_gb=4, seconds={"direct": 240})]
        e = ms.estimates(self.ctx(rows), 4)   # 每 GB 50 / 30 / 60 → 中位 50 → ×4 = 200
        self.assertAlmostEqual(e["direct"], 200)
        self.assertIsNone(e["unpack"])   # 没历史的不给

    def test_history_is_per_kind(self):
        # 老记录没有 kind（= 旧的 Mac 通用打包 build）不给现行两种计划用；iPhone 包的记录不给 Mac 打包用；缺体积的记录不参与按体积换算
        rows = [dict(size_gb=2, seconds={"direct": 100}), dict(kind="ipa_dual", size_gb=5, seconds={"direct": 50, "ipa": 90}),
                dict(kind="ipa_dual", seconds={"direct": 999, "ipa": 110})]
        e = ms.estimates(self.ctx(rows), 10, "ipa_dual")
        self.assertAlmostEqual(e["direct"], 100)   # 只用 5 GB 那条：50 / 5 × 10
        self.assertAlmostEqual(e["ipa"], 100)          # 不随体积：90、110 中位
        self.assertIsNone(ms.estimates(self.ctx(rows), 10)["direct"])   # Mac 打包（build_dual）没有自己的记录：不拿老记录、不拿 iPhone 包的顶


class PlanSource(unittest.TestCase):
    def test_plan_milestones_carry_source(self):
        # plan 事件每个里程碑带来源：有本种任务历史的 history + 样本数，没有的 none + expected None
        d = Path(tempfile.mkdtemp()); (d / "stats").mkdir()
        rows = [dict(kind="ipa_dual", size_gb=2, seconds={"direct": 100}), dict(kind="ipa_dual", size_gb=1, seconds={"direct": 30, "refresh": 50})]
        (d / "stats" / "prepare.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        events = []
        c = types.SimpleNamespace(private=d, emit=lambda kind, message="", **kw: events.append((kind, kw)))
        ms.plan(c, 4, "ipa_dual")
        kind, kw = events[-1]
        self.assertEqual(kind, "plan")
        rows = {m["id"]: m for m in kw["milestones"]}
        self.assertEqual(list(rows), ms.PLANS["ipa_dual"])
        self.assertEqual((rows["direct"]["source"], rows["direct"]["samples"]), ("history", 2))
        self.assertAlmostEqual(rows["direct"]["expected"], 160)   # 每 GB 50 / 30 → 中位 40 → ×4
        self.assertIn("体积换算", rows["direct"]["basis"])
        self.assertEqual((rows["refresh"]["source"], rows["refresh"]["samples"], rows["refresh"]["expected"]), ("history", 1, 50))
        self.assertEqual((rows["unpack"]["source"], rows["unpack"]["samples"], rows["unpack"]["expected"]), ("none", 0, None))
        for m in kw["milestones"]:
            self.assertTrue({"id", "label", "purpose", "expected"} <= set(m))   # 老字段照旧

    def test_record_tags_kind(self):
        d = Path(tempfile.mkdtemp())
        c = types.SimpleNamespace(private=d, emit=lambda *a, **k: None)
        ms.plan(c, 3, "ipa_dual")
        c.milestone_t = {"unpack": (0.0, 10.0)}
        ms.record(c, 3)
        row = json.loads((d / "stats" / "prepare.jsonl").read_text())
        self.assertEqual((row["kind"], row["size_gb"], row["seconds"]), ("ipa_dual", 3, {"unpack": 10.0}))


class Reuse(unittest.TestCase):
    """复用缓存的步（11-07：Hades 热出包预计 11 分钟、实际 49 秒）：复用步只按复用时的记录估、没有按 0 秒计；冷步不拿复用记录"""
    rows = [dict(kind="build_dual", size_gb=2, seconds={"direct": 1200, "refresh": 400}),                          # 冷：每 GB 600 / 200
            dict(kind="build_dual", size_gb=4, seconds={"direct": 2000, "refresh": 600}),                          # 冷：每 GB 500 / 150
            dict(kind="build_dual", size_gb=2, seconds={"direct": 20, "refresh": 6}, reused=["direct", "refresh"]),  # 复用：每 GB 10 / 3
            dict(kind="build_dual", size_gb=4, seconds={"direct": 60, "refresh": 4}, reused=["direct", "refresh"])]  # 复用：每 GB 15 / 1

    def ctx(self, rows):
        d = Path(tempfile.mkdtemp()); (d / "stats").mkdir()
        (d / "stats" / "prepare.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        events = []
        return types.SimpleNamespace(private=d, emit=lambda kind, message="", **kw: events.append((kind, kw)), events=events)

    def test_reused_step_with_reuse_history(self):
        d = ms.estimate_details(self.ctx(self.rows), 6, "build_dual", reused={"direct", "refresh"})
        # 直连库随体积换算：复用记录每 GB 10、15 → 中位 12.5 → ×6 = 75；改写不随体积：6、4 → 中位 5
        self.assertAlmostEqual(d["direct"]["seconds"], 75); self.assertEqual((d["direct"]["source"], d["direct"]["samples"]), ("history", 2))
        self.assertAlmostEqual(d["refresh"]["seconds"], 5)
        self.assertIn("复用", d["direct"]["basis"])

    def test_cold_step_ignores_reuse_history(self):
        d = ms.estimate_details(self.ctx(self.rows), 6, "build_dual")
        # 冷记录每 GB 600、500 → 中位 550 → ×6 = 3300；改写 400、600 → 中位 500
        self.assertAlmostEqual(d["direct"]["seconds"], 3300); self.assertAlmostEqual(d["refresh"]["seconds"], 500)

    def test_reused_step_without_reuse_history_is_zero(self):
        # 只有冷记录：复用步按 0 秒计（source = reuse），不拿冷记录的 3300 秒顶
        d = ms.estimate_details(self.ctx(self.rows[:2]), 6, "build_dual", reused={"direct"})
        self.assertEqual((d["direct"]["seconds"], d["direct"]["source"], d["direct"]["samples"]), (0.0, "reuse", 0))
        self.assertAlmostEqual(d["refresh"]["seconds"], 500)   # 没标复用的照冷记录

    def test_plan_marks_and_reemits_on_change(self):
        c = self.ctx(self.rows[:2])
        ms.plan(c, 6, "build_dual", reused=["unpack", "direct", "ipa"])   # ipa 不在 Mac 计划里：不认
        kind, kw = c.events[-1]
        rows = {m["id"]: m for m in kw["milestones"]}
        self.assertEqual({m for m, r in rows.items() if r["reuse"]}, {"unpack", "direct"})
        self.assertEqual((rows["direct"]["expected"], rows["direct"]["source"]), (0.0, "reuse"))
        n = len(c.events)
        ms.reuse(c, "direct")          # 已是复用：不重发
        self.assertEqual(len(c.events), n)
        ms.reuse(c, "direct", False)   # 其实要重出：改回冷步、重发同一组步
        rows = {m["id"]: m for m in c.events[-1][1]["milestones"]}
        self.assertEqual(len(c.events), n + 1)
        self.assertEqual(list(rows), ms.PLANS["build_dual"])
        self.assertFalse(rows["direct"]["reuse"]); self.assertAlmostEqual(rows["direct"]["expected"], 3300)

    def test_record_writes_reused_steps(self):
        c = self.ctx([])
        ms.plan(c, 6, "build_dual", reused=["unpack"])
        ms.reuse(c, "refresh")
        c.milestone_t = {"unpack": (0.0, 1.0)}
        ms.record(c, 6)
        row = json.loads((c.private / "stats" / "prepare.jsonl").read_text().splitlines()[-1])
        self.assertEqual(row["reused"], ["refresh", "unpack"])

    def test_reuse_without_plan_is_noop(self):
        ms.reuse(types.SimpleNamespace(emit=lambda *a, **k: self.fail("不该发计划")), "unpack")


class WatcherLifecycle(unittest.TestCase):
    def context(self):
        c = types.SimpleNamespace(guard=threading.RLock(), milestone_t={},
                                  milestone=None, milestone_ids=ms.PLANS["build_dual"])
        c.begin = lambda *args: None
        c.emit = lambda **kwargs: None
        return c

    def test_enter_holds_context_guard_for_all_mutations(self):
        c = self.context()
        acquired = []
        class Guard:
            def __enter__(self):
                acquired.append(True)
            def __exit__(self, *args):
                acquired.pop()
        class Times(dict):
            def __setitem__(self, key, value):
                self_test.assertTrue(acquired, "milestone timestamps must share emit's guard")
                super().__setitem__(key, value)
        self_test = self
        c.guard = Guard()
        c.milestone_t = Times()
        def begin(*args):
            self.assertTrue(acquired, "begin must remain in the same critical section")
            self.assertEqual(c.milestone, "refresh")
        c.begin = begin
        ms.enter(c, "refresh")
        self.assertFalse(acquired)

    def test_exit_is_bounded_and_released_observer_cannot_write(self):
        # 观察者卡在看产物根（文件系统慢）时退出：__exit__ 有界返回，放开之后不再晚写阶段
        with tempfile.TemporaryDirectory() as d:
            c = self.context()
            writes = []
            c.begin = lambda *args: writes.append(("stage", c.milestone))
            entered, release, exited = (threading.Event() for _ in range(3))
            roots = mock.Mock()
            def glob(pattern):
                entered.set()
                if not release.wait(15):
                    raise RuntimeError("fixture release missing")
                return [Path(d) / "合成款@dl-1.tmp"]
            roots.glob.side_effect = glob
            w = ms.DirectWatcher(c, roots, "合成款")
            errors = []
            def close():
                try:
                    w.__exit__(None, None, None)
                except Exception as error:
                    errors.append(error)
                finally:
                    exited.set()
            closer = threading.Thread(target=close)
            try:
                w.__enter__()
                self.assertTrue(entered.wait(5), "observer did not reach blocking point")
                closer.start()
                self.assertTrue(exited.wait(6), "exit must return with the observer still blocked")
                self.assertEqual(errors, [])
                self.assertTrue(w.t.is_alive(), "fixture must still hold the filesystem observation")
                ms.enter(c, "host")
                before = list(writes)
                release.set()
                w.t.join(5)
                self.assertFalse(w.t.is_alive())
                self.assertEqual(c.milestone, "host")
                self.assertEqual(writes, before, "no late stage write after exit")
            finally:
                release.set()
                w.stop.set()
                w.t.join(5)
                if closer.ident is not None:
                    closer.join(5)
                self.assertFalse(w.t.is_alive())
                self.assertFalse(closer.is_alive())

    def test_exit_orders_stop_write_barrier_then_bounded_join(self):
        c = self.context()
        w = ms.DirectWatcher(c, Path("synthetic"), "合成款")
        order = []
        self_test = self
        class Guard:
            def __enter__(self):
                self_test.assertTrue(w.stop.is_set())
                order.append("barrier")
            def __exit__(self, *args):
                order.append("barrier_done")
        c.guard = Guard()
        with mock.patch.object(w.t, "join", side_effect=lambda timeout=None: order.append(("join", timeout))):
            w.__exit__(None, None, None)
        self.assertEqual(order, ["barrier", "barrier_done", ("join", 3)])

    def test_glob_error_does_not_end_observation(self):
        # 产物根正被替换（临时版本消失）时 glob 抛 OSError：不结束观察，下一轮看到直连临时版本就进「直连着色器库」
        c = self.context()
        roots = mock.Mock()
        roots.glob.side_effect = [FileNotFoundError("synthetic vanished directory"), [], [Path("synthetic/合成款@dl-1.tmp")]]
        w = ms.DirectWatcher(c, roots, "sample")
        w.stop = mock.Mock()
        w.stop.is_set.return_value = False
        w.stop.wait.side_effect = [False, False, False, True]
        errors = []
        def observe():
            try:
                w.loop()
            except Exception as error:
                errors.append(error)
        w.t = threading.Thread(target=observe)
        w.t.start()
        w.t.join(5)
        self.assertFalse(w.t.is_alive())
        self.assertEqual(errors, [], "a disappearing version must not kill the observer")
        self.assertEqual(roots.glob.call_count, 3)
        self.assertEqual(c.milestone, "direct")

if __name__ == "__main__":
    unittest.main()
