# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""整单进度（每条作业事件的 overall，0–1）：作业层唯一一份，前端只显示它、不自己拼。

为什么在这里算（11-11 维护者：「编译着色器这一步百分比反复到 91% 又跳回 40%」「最后一步也是，91% 到 99% 又跳回来」）：
前端原先按「当前计数器的 done / total」填当前一步。一步里几个计数器先后出现（抽取 1..4/4 → 直连库 k/5 → 翻译与收尾 n/3974 → 编批库 0..100），
还有贯穿整单的「刷新各阶段 k/10」夹在中间、「出包 6/5」越界；收尾几个阶段（清理、写单一 IMG、组装 ipa）各报 1/1。
每换一个计数器，百分比就回退。

口径（期望值可以不跑实现、按事件手算）：
- 权重 = plan 事件里各里程碑的本机实测（source=history 且有样本的 expected；source=reuse 的按记录、缺了 0；pack/jobs/milestones.py），
  每步至少 1 秒；有任何一步没有实测 → 各步等权。
  与前端分段条的分段宽度同一口径（ExportSessionView / ExportPages.cs weights）。
- 当前里程碑内部的完成度 = 本步已用时 ÷ 本步 expected，最多 STEP_CAP；没有历史时为 0（只在换步时前进，不编常数）。
  计数器不参与：同一步里几个计数器先后出现、互不嵌套，任何一个都不代表整步。
- overall = (前面各步权重和 + 本步权重 × 本步完成度) ÷ 权重总和，最多 RUN_CAP；只增不减（取历史最大）。
- 成功的结果事件（state succeeded / completed）才到 1。失败、取消停在原处。
- 没有 plan 的作业（装到手机、续签、删除、装回、更新手机上的 S2Arm…）：按「第几步 / 共几步」（core.begin 的 number / count）推，
  本步内按本步计数 done / total 插进去：(第几步 − 1 + 本步完成度) ÷ 共几步；同样只增不减、成功才到 1（11-11 维护者：更新页做完还写「正在更新」）。
  plan 先到、或作业中途才到 plan：从那以后按 plan 算（按步算出的值只用在 plan 到之前，plan 一到从 0 重新按 plan 推）。
- 既没有 plan、也没有「共几步」：不给 overall（None），前端按原来的计数显示。
"""

STEP_CAP = 0.95
RUN_CAP = 0.99


class Overall:
    def __init__(self):
        self.value = None
        self.weights = None      # [(里程碑 id, 权重)]
        self.timed = False       # 有没有历史（决定本步内部按时间推不推）
        self.current = None
        self.started = 0.0

    def plan(self, milestones):
        def measured(m):   # 同前端 Milestone.measured（PackModels.cs / Milestones.swift）：复用的步按记录（缺了 0），有本机历史的取它，其余算没有
            e = m.get("expected")
            if m.get("source") == "reuse":
                return float(e or 0)
            return float(e) if m.get("source") == "history" and (m.get("samples") or 0) > 0 and isinstance(e, (int, float)) else None
        rows = [(m.get("id"), measured(m)) for m in milestones or [] if m.get("id")]
        if not rows:
            return
        self.timed = all(e is not None for _, e in rows) and sum(e for _, e in rows) > 0
        self.weights = [(mid, max(float(e), 1.0) if self.timed else 1.0) for mid, e in rows]   # 每步至少按 1 秒（同前端分段条 weights）
        if self.value is None or getattr(self, "stepped", False):   # plan 到之前按步算的值作废，从 0 按 plan 推（出包的 plan 在第一条 1/1 阶段之后马上到，那时还是 0）
            self.value, self.stepped = 0.0, False

    def feed(self, kind, elapsed, milestone, state=None, step=None, steps=None, done=None, total=None):
        """一条事件 → 这条事件该带的 overall（None = 本作业没有整单进度）"""
        if self.weights is None:
            return self._by_steps(kind, state, step, steps, done, total)
        if kind == "result":
            if state in ("succeeded", "completed"):
                self.value = 1.0
            return round(self.value, 4)
        ids = [mid for mid, _ in self.weights]
        if milestone in ids:
            if milestone != self.current:
                self.current, self.started = milestone, elapsed
            k = ids.index(milestone)
            before = sum(w for _, w in self.weights[:k])
            w = self.weights[k][1]
            inside = min(STEP_CAP, max(0.0, elapsed - self.started) / w) if self.timed and w > 0 else 0.0
            total = sum(w for _, w in self.weights)
            raw = min(RUN_CAP, (before + w * inside) / total) if total > 0 else 0.0
            self.value = max(self.value, raw)
        return round(self.value, 4)

    def _by_steps(self, kind, state, step, steps, done, total):
        if kind == "result":
            if self.value is None:
                return None
            if state in ("succeeded", "completed"):
                self.value = 1.0
            return round(self.value, 4)
        if not steps or not step:
            return None if self.value is None else round(self.value, 4)
        inside = min(1.0, max(0.0, done / total)) if kind == "progress" and isinstance(done, (int, float)) and isinstance(total, (int, float)) and total > 0 else 0.0
        raw = min(RUN_CAP, (min(step, steps) - 1 + inside) / steps)
        self.value = max(self.value or 0.0, raw)
        self.stepped = True
        return round(self.value, 4)
