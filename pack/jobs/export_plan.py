# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包编排（剃刀 H13，cmdr 设计文档《H13 出包编排后端化》）：一个 export 作业按计划一步步出包，前端只发起、显示、取消。

计划（请求里的 plan）：
  {"source": "inline", "items": [{"gameId", "name", "platforms": ["mac", "iphone"]}], "location", "deviceTarget", "spaceOverride"}
      单款 / 几款就地出，计划只在本作业内存里，不写 batch.json（单款出包不能盖掉一个还没出完的批次）
  {"source": "batch"}
      按数据目录下的 batch.json 出，规则全部沿用 batch.py：下一个出谁（next_step）、记结局（mark）、磁盘满暂停、取消

每一步是一个普通子作业（Mac = build、iPhone = ipa），各有自己的任务号、任务记录、日志与错误摘要；本作业不解包不编译，只起子作业、等它结束、记账、再起下一个：
  - 子作业的请求 = 本作业的请求去掉 plan，换 operation / taskId / gameId，parentPid 指本进程（本作业没了子作业跟着停）
  - 这台电脑出不了的平台（Windows 上的 Mac 版）不起子作业，直接记失败「这台电脑出不了这个平台的包」（原先两端前端各判一遍）
  - 同一款 iPhone 后面还有平台时带 followUp（作业层先不清解包，剃刀 M21）；batch.py 把同一款排成先 Mac 后 iPhone，正常不会出现
  - 子作业的事件原样转发到标准输出（type child，step = {gameId, platform, task}，event = 子作业那条原样），不进本作业的事件记录（子作业自己有）；
    每步开始 / 结束各一条 step / stepEnded 事件（step = {gameId, platform, task, index, count}，stepEnded 另带 outcome），进记录
  - 取消：本作业收到 TERM → Context.run 把 TERM 转给子作业的进程组、等它收尾 → 正在出的和没开始的都记「已取消」，已出好的保留 → 本作业以 cancelled 结束
  - 磁盘满（batch.PAUSE_CODES）：记账后批次暂停 → 不起下一步，本作业以独立终态 paused 结束（不并进 completed，前端只认机读字段）
  - 启动器退出（请求带 parentPid，main.py supervise 见它没了）：同样以 paused 结束，pausedReason = launcher_exit；正在出的那步重新排队（batch.recover），
    没开始的不动、已出好的保留，重开启动器起 source=batch 的编排就只出剩下的（退出即停，不在后台悄悄跑）
同一时刻只许一个编排在跑（数据目录下 export.lock，filelock 与库锁同一实现）：第二个直接报 library_busy 并说清占着的是谁。
"""
from __future__ import annotations
import contextlib
import json
import os
from pathlib import Path
import sys

import batch as plans
from core import Cancelled, Paused, atomic, journal
from errors import Failure
import filelock

OPERATION = {"mac": "build", "iphone": "ipa"}
SUPPORTED = ("mac", "iphone") if sys.platform == "darwin" else ("iphone",)   # 这台电脑能出的平台：Mac 版只能在 Mac 上出
UNSUPPORTED_MESSAGE = "这台电脑出不了这个平台的包"
CHILD_ENTRY = Path(__file__).resolve().with_name("main.py")
CHILD_KEYS_DROPPED = ("plan", "taskId", "jobId", "operation", "gameId", "target", "followUp", "location", "spaceOverride", "parentPid")


def child_command(request_file):
    """起一步子作业的命令（测试换成桩脚本）：参数同各端前端起作业（Mac JobClient.swift「-B -I」、Windows PackJobClient.cs「-X utf8」，
    Windows 随包 Python 的搜索路径由 ._pth 定，不加 -I）"""
    py = [sys.executable] + (["-X", "utf8"] if os.name == "nt" else ["-B", "-I"])
    return py + [str(CHILD_ENTRY), "run", "--request", str(request_file)]


def export(c):
    plan = c.r.get("plan")
    if not isinstance(plan, dict) or plan.get("source") not in ("inline", "batch"):
        raise Failure("出包计划不完整：plan.source 只认 inline / batch。")
    c.begin("出包")
    try:
        with filelock.held(c.private / "export.lock", holder=c.lock_holder()):
            return _run(c, plan)
    except filelock.Busy as busy:
        raise Failure("已经有一个出包在进行：等它出完或取消后再出。", code="library_busy", holder=busy.holder) from None


class _Book:
    """计划的账本：inline 在内存里，batch 每次读改写 batch.json（持 batch.locked，别的进程同时改不会互相盖掉）"""
    def __init__(self, c, plan):
        self.private, self.inline = c.private, plan["source"] == "inline"
        if self.inline:
            try:
                self.memory = plans.create(plan.get("items") or [], plan.get("location"))
            except ValueError as error:
                raise Failure(str(error)) from None
        elif plans.load(self.private) is None:
            raise Failure("没有进行中的批次：先在批量出包页建好这一批。")

    @contextlib.contextmanager
    def edit(self):
        if self.inline:
            yield self.memory
            return
        try:
            with plans.locked(self.private):
                current = plans.load(self.private)
                if current is None:
                    raise Failure("批次文件不见了或读不出（batch.json）：这一批停在这里，已出好的不受影响。", code="batch_record_failed")
                yield current
                plans.save(self.private, current)
        except OSError as error:   # 锁等不到 / 写不进
            raise Failure(f"批次记录没写成（batch.json：{error}）：这一批停在这里，已出好的不受影响。", code="batch_record_failed") from None

    def peek(self):
        with self.edit() as b:
            return json.loads(json.dumps(b))


def _run(c, plan):
    book = _Book(c, plan)
    location = plan.get("location") if book.inline else book.peek().get("location")
    index, paused_at = 0, None
    while True:
        with book.edit() as b:
            step = plans.next_step(b)
            if step is None:
                break
            plans.mark(b, step["gameId"], step["platform"], "running")
            item = plans.find(b, step["gameId"])
            rest = item["platforms"][item["platforms"].index(step["platform"]) + 1:]
            total = sum(len(i["platforms"]) for i in b["items"])
        index += 1
        gid, platform = step["gameId"], step["platform"]
        child = f"{c.task}-{index}"[:80]
        try:
            where = dict(gameId=gid, platform=platform, task=child, index=index, count=total)
            c.emit("step", f"出 {item['name']}（{platform}）", step=where)
            outcome = dict(state="failed", message=UNSUPPORTED_MESSAGE) if platform not in SUPPORTED else \
                _run_step(c, child, gid, platform, plan, location, followUp=platform == "iphone" and bool(rest))
        except Cancelled:
            if not getattr(c, "parent_gone", False):
                with book.edit() as b:   # 玩家取消：正在出的和没开始的记「已取消」，已出好的保留
                    plans.cancel(b)
                raise
            with book.edit() as b:   # 启动器退出（main.py supervise 见 parentPid 没了）：正在出的那步重新排队，没开始的不动，已出好的保留
                plans.recover(b)
                stopped = _position(b, gid)
            raise Paused(f"启动器退出了，这一批停在第 {stopped} 款：重开启动器后点「继续剩下的」，只出还没出的。",
                         _result(book.peek(), "launcher_exit", stopped)) from None
        except BaseException:
            with book.edit() as b:   # 本作业出错：正在出的和没开始的记「已取消」，已出好的保留
                plans.cancel(b)
            raise
        with book.edit() as b:
            plans.mark(b, gid, platform, outcome["state"], outcome.get("message", ""), outcome.get("code"), outcome.get("output"))
            if b.get("paused"):
                paused_at = _position(b, gid)   # 磁盘满停在这一款
        c.emit("stepEnded", outcome.get("message", ""), step=where, outcome=outcome)
    final = book.peek()
    if final.get("paused"):
        raise Paused("磁盘空间不足，这一批暂停了：释放空间后点「重试」接着出，已出好的不受影响。", _result(final, final["paused"], paused_at))
    return _result(final)


def _position(b, gid):
    """这一款在批次里是第几款（从 1 数）：停在哪一款就报哪一款（启动器退出时正在出的、磁盘满的那款），不按状态去猜"""
    return next(n for n, item in enumerate(b["items"], 1) if item["gameId"] == gid)


def _result(b, paused_reason=None, stopped_at=None):
    """终态带回的机读结果：pausedReason = disk_full / launcher_exit（只有 paused 终态才有），stoppedAt = 停在第几款"""
    out = dict(summary=plans.summary(b), items=b["items"], pausedReason=paused_reason)
    if stopped_at:
        out["stoppedAt"] = stopped_at
    return out


def _run_step(c, child, gid, platform, plan, location, followUp):
    request = {k: v for k, v in c.r.items() if k not in CHILD_KEYS_DROPPED}
    request.update(schema=1, taskId=child, operation=OPERATION[platform], gameId=gid, parentPid=os.getpid())
    if location:
        request["location"] = location
    if plan.get("spaceOverride"):
        request["spaceOverride"] = True
    if platform == "iphone" and plan.get("deviceTarget"):
        request["target"] = plan["deviceTarget"]
    if followUp:
        request["followUp"] = True
    path = c.logs / "jobs" / (child + ".request.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic(path, request)
    os.chmod(path, 0o600)
    seen = {}
    def relay(line):
        try:
            event = json.loads(line)
        except ValueError:
            return
        if not isinstance(event, dict):
            return
        if event.get("type") == "result" or "error" in event and "type" not in event:
            seen["last"] = event
        if event.get("type") != "heartbeat":
            c.emit("child", "", transient=True, step=dict(gameId=gid, platform=platform, task=child), event=event)
    c.run(child_command(path), log=c.logs / (child + ".export.log"), on_line=relay, timeout=0, ok_codes=(0, 1, 2, 130))
    return _outcome(c, child, seen.get("last"))


def _outcome(c, child, last):
    """子作业的结局：优先它打的 result 事件；没打（起不来 / 被杀）就读它的任务记录；都没有就记失败并说清"""
    if last and last.get("type") == "result":
        state = {"succeeded": "completed"}.get(last.get("state"), last.get("state"))
        result = last.get("result") or {}
        error = next((d for d in reversed(last.get("diagnostics") or []) if d.get("severity") == "error"), None) or \
            next(iter(reversed(last.get("diagnostics") or [])), None) or {}
        out = dict(state=state if state in ("completed", "failed", "cancelled") else "failed", message=last.get("message") or "")
        if out["state"] == "failed" and error.get("code"):
            out["code"] = error["code"]
        for key in ("outputPath", "ipa", "ipaBytes", "packBytes", "outputBytes", "notes"):   # notes：降级继续的玩家提示（完成卡逐条显示）
            if result.get(key) not in (None, ""):
                out[key] = result[key]
        if result.get("outputPath") or result.get("ipa"):
            out["output"] = result.get("outputPath") or result.get("ipa")
        return out
    if last and "error" in last:   # 请求被拒（main.py 退出码 2）
        return dict(state="failed", message=str(last["error"]), code=last.get("code") or "job_failed")
    try:
        record = journal(c.private, child)
        if record.get("state") in ("completed", "failed", "cancelled"):
            return dict(state=record["state"], message=record.get("message") or "")
    except Failure:
        pass
    return dict(state="failed", message="这一步的出包作业没有给出结局就退出了（详见这一步的日志）。", code="job_failed")
