#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""批量出包的「批次」（Mac / Windows 启动器共用，只用标准库）：一批放进来的游戏、每款要出的平台、一批共用的存放位置，
以及每款每个平台出到哪了。存在数据目录下 batch.json，启动器关掉再打开还能接着出。

界面只负责按 next 给的顺序一款接一款地发起出包作业（Mac = build、iPhone = ipa，同一款的两个平台连着出，
解包等平台无关阶段作业层本来就共用），每个平台出完 mark 一次；出没出完、下一个出谁、停不停都按这里的规则：
  - 一款失败不挡后面；磁盘满（disk_full）就暂停整批：接着出只会一款接一款都因为没空间失败。暂停只由 retry 解除（磁盘满那款就是要重试的），
    暂停期间 mark running 拒收（同一款的下一个平台也不开，审计 P1-164）
  - cancel：正在出的和没开始的都记「已取消」，已出好的保留；resume 把取消的接回来接着出（不解除暂停）
  - retry：失败的重新排队（给游戏号只重试这一款）
  - 启动器刚打开时调一次 recover：还记着「正在出」的（上次关掉启动器时没出完）→ 记成「被打断」并重新排队，从头出这款（缓存照常复用）。
    只在打开时调：出包过程中界面随时 show / mark，不能把正在出的那款当成没出

命令（每条打印一行 JSON = 改完后的批次，或 show 的结果）：
  show   [--private-root]                                 → {batch, next, summary}；没有批次 → {}
  create --private-root R --json <批次>                   → 新建（上一批出完了才覆盖；还没出完 / 暂停着拒收，走 retry / resume 或先 clear，审计 P2-270）
  mark   --private-root R --game G --platform P --state S [--message M] [--code C] [--output O]
  recover / cancel / resume / clear --private-root R
  retry  --private-root R [--game G]
"""
import argparse
import contextlib
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))   # 两端用 python -I 跑本脚本（脚本目录不在搜索路径）：同目录的 filelock 要自己加（同 main.py）
import filelock  # noqa: E402

# 同一款先出 Mac、再出 iPhone：解包只做一次靠这个顺序——iPhone 出包收尾（成功或失败）会清掉这款的解包和中间产物（library.prune_build），
#   Mac 打包成功不清；iPhone 在前时第二个平台只能重新解包（端到端实测：20675 个解包文件全部重写）。iPhone 还能从 Mac 的产物根接着做（build.seed_from_sibling）
PLATFORMS = ("mac", "iphone")
STATES = ("pending", "running", "completed", "failed", "cancelled")
PAUSE_CODES = ("disk_full",)   # 失败了就暂停整批的错误码（pack/jobs/errors.py）


def path(private_root):
    return Path(private_root) / "batch.json"


def valid(batch):
    """形状对不对：各款都有 gameId、平台、每个平台一条带合法状态的结果（缺字段的坏文件当没有批次，不抛异常，审计 P2-280）"""
    if not isinstance(batch, dict) or batch.get("schema") != 1 or not isinstance(batch.get("items"), list):
        return False
    for item in batch["items"]:
        if not isinstance(item, dict) or not isinstance(item.get("gameId"), str) or not isinstance(item.get("platforms"), list):
            return False
        results = item.get("results")
        if not isinstance(results, dict) or any(not isinstance(results.get(p), dict) or results[p].get("state") not in STATES for p in item["platforms"]):
            return False
    return True


def load(private_root):
    """→ 批次或 None（读不出、格式不对都当没有）"""
    try:
        batch = json.loads(path(private_root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return batch if valid(batch) else None


@contextlib.contextmanager
def locked(private_root):
    """一条命令读 → 改 → 写期间独占 batch.json（作业层已有的 filelock，Mac / Windows 同一套）：两个进程同时 mark 时不互相盖掉（审计 P2-270）。
    锁被占着就短等（每条命令都是毫秒级），等不到报错，不静默写"""
    root = Path(private_root); root.mkdir(parents=True, exist_ok=True)
    try:
        with filelock.held(root / "batch.json.lock", wait_s=5, poll=0.05):
            yield
    except filelock.Busy:
        raise OSError("批次正被另一个进程改着，稍后再试") from None


def recover(batch):
    """启动器刚打开：上次没出完、还记着「正在出」的 → 被打断、重新排队"""
    for item in batch["items"]:
        for result in item["results"].values():
            if result["state"] == "running":
                result.clear(); result.update(state="pending", interrupted=True)
    return batch


def save(private_root, batch):
    root = Path(private_root); root.mkdir(parents=True, exist_ok=True)
    tmp = root / "batch.json.tmp"
    tmp.write_text(json.dumps(batch, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path(private_root))


def create(items, location=None):
    """items: [{gameId, name, platforms, sgrade?}]（界面识别完、玩家勾好的；没勾平台的款不进批次）。
    sgrade = false：这款在出包页取消了「S 级优化（Beta）· 出包时打入」（按款记住），批量出也不带社区补丁与金手指（export_plan 转给子作业）"""
    out = []
    seen = set()
    for raw in items:
        gid, platforms = raw.get("gameId"), [p for p in PLATFORMS if p in (raw.get("platforms") or [])]   # 同一款先出 Mac 再出 iPhone（PLATFORMS 的说明）
        if not isinstance(gid, str) or not gid or gid in seen or not platforms:
            continue
        seen.add(gid)
        out.append({"gameId": gid, "name": str(raw.get("name") or gid), "platforms": platforms,
                    "results": {p: {"state": "pending"} for p in platforms}, **({"sgrade": False} if raw.get("sgrade") is False else {})})
    if not out:
        raise ValueError("这一批里没有勾了平台的游戏")
    return {"schema": 1, "created": int(time.time()), "location": location or None, "paused": None, "items": out}


def find(batch, gid):
    item = next((i for i in batch["items"] if i["gameId"] == gid), None)
    if item is None:
        raise ValueError(f"这一批里没有 {gid}")
    return item


def next_step(batch):
    """→ {gameId, platform} 或 None（出完了 / 暂停了 / 正在出别的）。按页面顺序：一款的平台出完才到下一款"""
    if batch.get("paused"):
        return None
    for item in batch["items"]:
        for p in item["platforms"]:
            state = item["results"][p]["state"]
            if state == "running":
                return None
            if state == "pending":
                return {"gameId": item["gameId"], "platform": p}
    return None


def mark(batch, gid, platform, state, message="", code=None, output=None):
    if state not in STATES:
        raise ValueError(f"状态不对：{state}")
    item = find(batch, gid)
    if platform not in item["results"]:
        raise ValueError(f"{gid} 这一批没有 {platform}")
    result = {"state": state}
    if message: result["message"] = message
    if code: result["code"] = code
    if output: result["output"] = output
    if state == "running" and batch.get("paused"):
        raise ValueError("这一批因为磁盘空间不足暂停着：释放空间后点「重试」")
    item["results"][platform] = result
    if state == "failed" and code in PAUSE_CODES:
        batch["paused"] = code
    return batch


def cancel(batch):
    for item in batch["items"]:
        for result in item["results"].values():
            if result["state"] in ("pending", "running"):
                result.clear(); result["state"] = "cancelled"
    return batch


def resume(batch):
    """接着出：取消的接回来（失败的不动、暂停也不解除，都走 retry）"""
    for item in batch["items"]:
        for result in item["results"].values():
            if result["state"] == "cancelled":
                result.clear(); result["state"] = "pending"
    return batch


def retry(batch, gid=None):
    """失败的重新排队；给游戏号只重试这一款。也解除暂停（磁盘满那款就是要重试的）"""
    items = [find(batch, gid)] if gid else batch["items"]
    for item in items:
        for result in item["results"].values():
            if result["state"] == "failed":
                result.clear(); result["state"] = "pending"
    batch["paused"] = None
    return batch


def summary(batch):
    """按款数：还有平台没出 / 正在出 = 还没出完（哪怕别的平台已失败，审计 P1-168）；其余所有平台都出好 = 已出好；有平台失败 = 失败；
    有平台取消（且没失败）= 已取消。done = 没有还没出完的、也没暂停"""
    counts = {"total": len(batch["items"]), "completed": 0, "failed": 0, "cancelled": 0, "pending": 0}
    for item in batch["items"]:
        states = [item["results"][p]["state"] for p in item["platforms"]]
        if any(s in ("pending", "running") for s in states): counts["pending"] += 1
        elif all(s == "completed" for s in states): counts["completed"] += 1
        elif "failed" in states: counts["failed"] += 1
        else: counts["cancelled"] += 1
    counts["done"] = counts["pending"] == 0 and not batch.get("paused")
    return counts


def show(batch):
    return {"batch": batch, "next": next_step(batch), "summary": summary(batch)} if batch else {}


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="批量出包的批次（Mac / Windows 共用）")
    ap.add_argument("command", choices=("show", "create", "mark", "recover", "cancel", "resume", "retry", "clear"))
    ap.add_argument("--private-root", required=True)
    ap.add_argument("--json"); ap.add_argument("--game"); ap.add_argument("--platform", choices=PLATFORMS)
    ap.add_argument("--state", choices=STATES); ap.add_argument("--message", default=""); ap.add_argument("--code"); ap.add_argument("--output")
    a = ap.parse_args(argv)
    try:
        if a.command == "show":
            print(json.dumps(show(load(a.private_root)), ensure_ascii=False)); return 0
        with locked(a.private_root):
            return run(a)
    except (OSError, ValueError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1


def run(a):
    """main 里持锁后跑一条改批次的命令（show 不改，不进这里）"""
    if a.command == "clear":
        path(a.private_root).unlink(missing_ok=True)
        print("{}"); return 0
    if a.command == "create":
        data = json.loads(a.json or sys.stdin.read())
        old = load(a.private_root)
        if old and not summary(old)["done"]:
            raise ValueError("上一批还没出完：在 S2Arm 的批量出包页「重试」/「继续」，或点「完成」清掉再建")
        batch = create(data.get("items") or [], data.get("location"))
    else:
        batch = load(a.private_root)
        if batch is None:
            raise ValueError("没有进行中的批次")
        if a.command == "mark":
            if not (a.game and a.platform and a.state):
                raise ValueError("mark 要 --game --platform --state")
            mark(batch, a.game, a.platform, a.state, a.message, a.code, a.output)
        elif a.command == "recover": recover(batch)
        elif a.command == "cancel": cancel(batch)
        elif a.command == "resume": resume(batch)
        elif a.command == "retry": retry(batch, a.game)
    save(a.private_root, batch)
    print(json.dumps(show(batch), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
