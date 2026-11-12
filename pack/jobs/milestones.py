"""准备任务的里程碑进度（维护者 10-23：一个进度条标出各里程碑、当前阶段在做什么、已用时间、预计还需多久）。

- 计划：开始时发一个 plan 事件，列出全部里程碑（名称、作用、预计秒数）；之后每个事件带当前里程碑 id。
- 预计秒数只来自本机实测（维护者 10-25「不是即时计算或者假设写死的数字都改」）：每次成功按里程碑记一行到 <私有目录>/stats/prepare.jsonl
  （带任务种类：Mac 打包 build_dual / 打 iPhone 包 ipa_dual，各算各的），按游戏体积换算取中位数；本机没有这一种任务的记录就不给预计
  （expected = None、source = none）。原先的缺省值是别的游戏、别的流程的旧实测（10-23 奥德赛 / 10-24 动森），Hades 6.2 GB 按它算出 70 分钟、
  实际 100 秒就到最后一步，不再用。
- 复用与冷做分开记、分开估（11-07：Hades 热出包 macOS 显示预计 11 分钟、实际 49 秒——命中缓存的步按冷出包的历史算）：后端知道某一步会复用缓存
  （共用解包快照对得上、这一份产物根以同样的代码与输入出成过）就标「复用」（reuse(c, 步)），能在开工前判就在发计划前判，判不了的在这一步开始、
  知道的那一刻改标并重发计划（同一组步、界面不清已用时间）；复用步只按本机复用时的记录估，没有就按 0 秒计，不拿冷记录顶。
  成功时历史这一行带 reused（复用了哪几步），冷步、复用步各自只用各自的记录。老记录没有 reused，一律当冷记录。
- 直连库阶段：refresh.sh 的直连临时版本（<款>@dl-*.tmp）出现即进「直连着色器库」（DirectWatcher）。
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import statistics
import threading
import time

MILESTONES = [
    # id, 名称, 作用说明, 是否随体积缩放（本机历史按游戏体积换算）。步骤与现行 pack/refresh.sh 的关键链对齐（11-08 维护者）：
    #   解包 → 追加内容 ‖ 界面布局 → 配置推导 · 抽取 → 直连库 → 出包；改写 / 系统数据 / 能力表 / RomFS 索引是旁路，和关键链并行，算在「准备资源」里说明
    ("unpack", "解包", "读出游戏程序和资源，合并更新与 DLC。", True),
    ("refresh", "准备资源", "整理 DLC 和宽屏界面布局，同时在后台把游戏代码改写成苹果设备能直接运行的形式。", False),
    ("analyze", "分析画面", "读懂这款游戏的图形用法，抽出它用到的全部着色器。", True),
    ("direct", "编译着色器库", "把着色器编译成苹果显卡的格式，进游戏时不用现编，减少卡顿。", True),
    ("host", "准备游戏程序", "准备在 Mac 上运行这款游戏的主程序。", False),
    ("install", "安装并校验", "把准备好的文件装进游戏库，并逐个校验。", True),
    ("ipa", "编 App 与签名", "编出 iPhone / iPad 版程序、签名，并打好要拷进手机的资源包。", False),
]
# 各种任务的里程碑（与现行流程逐段对上）：
# - build_dual：Mac 打包（pack/refresh.sh S2A_PACK_PLAT=macos，同一键出包 --target mac）
# - ipa_dual：打 iPhone 包（pack/oneclick/oneclick.sh）
PLANS = {"ipa_dual": ["unpack", "refresh", "analyze", "direct", "ipa"],
         "ipa_downstream": ["unpack", "ipa"],   # 下游深度方案出 iPhone 包：共用解包 → 下游做包工具（pack/jobs/downstream.py）
         "build_dual": ["unpack", "refresh", "analyze", "direct", "host", "install"]}


def history_path(c):
    return c.private / "stats" / "prepare.jsonl"


def estimate_details(c, size_gb, kind="build_dual", reused=()):
    """每个里程碑的预计秒数及来源：本机这一种任务（kind）的历史中位数（source=history，samples 条）；没有记录就是 None（source=none），不拿缺省值顶。
    reused 里的步（这次会复用缓存）只用复用时的记录（历史行的 reused 含这一步）；没有复用记录按 0 秒计（source=reuse）。其余步只用冷记录"""
    per = {}
    try:
        for line in history_path(c).read_text().splitlines()[-50:]:
            row = json.loads(line)
            if row.get("kind", "build") != kind:   # 老记录没有 kind，都是 Mac 打包记的
                continue
            gb = float(row.get("size_gb") or 0)
            warm = set(row.get("reused") or ())   # 老记录没有 reused：当冷记录
            for mid, sec in (row.get("seconds") or {}).items():
                per.setdefault((mid, mid in warm), []).append((float(sec), gb))
    except (OSError, ValueError):
        pass
    out = {}
    for mid, _, _, scaled in MILESTONES:
        reuse = mid in reused
        samples = [(s, g) for s, g in per.get((mid, reuse), []) if g > 0 or not scaled]   # 要按体积换算的，缺体积的记录不用
        if samples and size_gb > 0:
            out[mid] = dict(seconds=statistics.median(s / g * size_gb if scaled else s for s, g in samples), source="history",
                            samples=len(samples), basis="本机最近" + ("复用缓存时" if reuse else "") + "记录的中位数" + ("，按游戏体积换算" if scaled else ""))
        elif reuse:
            out[mid] = dict(seconds=0.0, source="reuse", samples=0, basis="复用缓存；本机还没有这一步复用时的记录，按 0 秒计")
        else:
            out[mid] = dict(seconds=None, source="none", samples=0, basis="本机还没有这一步的记录")
    return out


def estimates(c, size_gb, kind="build_dual", reused=()):
    """每个里程碑的预计秒数：本机历史按体积换算后的中位数，没有记录的是 None"""
    return {m: d["seconds"] for m, d in estimate_details(c, size_gb, kind, reused).items()}


def plan(c, size_gb, kind="build_dual", reused=()):
    """发计划。reused：开工前就知道会复用缓存的步（只认本计划里有的）"""
    c.milestone_t = {}
    c.milestone_kind = kind
    c.milestone_ids = [m for m in PLANS[kind] if not (m == "analyze" and os.name == "nt")]   # Windows 一键出包没有这条分界信号，分析画面并在下一步里
    c.milestone_size = size_gb
    c.milestone_reused = {m for m in reused if m in c.milestone_ids}
    _emit_plan(c)


def _emit_plan(c):
    est = estimate_details(c, c.milestone_size, c.milestone_kind, c.milestone_reused)
    rows = {m: (l, p) for m, l, p, _ in MILESTONES}
    c.emit("plan", "准备计划", milestones=[dict(id=m, label=rows[m][0], purpose=rows[m][1],
                                            expected=None if est[m]["seconds"] is None else round(est[m]["seconds"], 1),
                                            source=est[m]["source"], samples=est[m]["samples"], basis=est[m]["basis"],
                                            reuse=m in c.milestone_reused)
                                       for m in c.milestone_ids],
           sizeGb=round(c.milestone_size, 2))


def reuse(c, mid, on=True):
    """开工后才知道某一步复用（或原以为复用、其实要重做）：改标并重发计划（同一组步，前端接着走表、只换预计）。
    没发过计划（如别的作业调到）或不在本计划里的步不动"""
    ids, marked = getattr(c, "milestone_ids", None), getattr(c, "milestone_reused", None)
    if not ids or marked is None or mid not in ids or (mid in marked) == on:
        return
    (c.milestone_reused.add if on else c.milestone_reused.discard)(mid)
    _emit_plan(c)


def enter(c, mid):
    """进入一个里程碑：发 stage 事件（带里程碑 id），并记开始时间（结束时间 = 下一个里程碑开始）"""
    label = next(l for m, l, _, _ in MILESTONES if m == mid)
    with c.guard:
        now = time.monotonic()
        for m, t in list(c.milestone_t.items()):
            if isinstance(t, float):
                c.milestone_t[m] = (t, now)
        c.milestone_t[mid] = now
        c.milestone = mid
        ids = getattr(c, "milestone_ids", None) or [m for m, *_ in MILESTONES]
        c.begin(label, ids.index(mid) + 1, len(ids))


def record(c, size_gb, **extra):
    """准备成功：把各里程碑实测秒数记进历史（下次同一种任务的预计用）；extra 照原样并进这一行（打 iPhone 包记 gameId）"""
    now = time.monotonic()
    sec = {m: (t[1] - t[0]) if isinstance(t, tuple) else now - t for m, t in getattr(c, "milestone_t", {}).items()}
    p = history_path(c)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a") as f:
        f.write(json.dumps(dict(at=time.time(), kind=getattr(c, "milestone_kind", "build"), size_gb=round(size_gb, 2), seconds={m: round(s, 1) for m, s in sec.items()},
                                reused=sorted(getattr(c, "milestone_reused", ()) or ()), **extra)) + "\n")


class DirectWatcher:
    """刷新阶段的观察者：每秒看一次产物根，界面布局和追加内容收尾就进「分析画面」，直连临时版本（<款>@dl-*.tmp）出现就进「编译着色器库」"""
    def __init__(self, c, roots: Path, game_id: str):
        self.c, self.roots, self.game_id = c, roots, game_id
        self.stop = threading.Event()
        self.t = threading.Thread(target=self.loop, daemon=True)

    def __enter__(self):
        self.t.start()
        return self

    def __exit__(self, *a):
        self.stop.set()
        with self.c.guard:
            pass  # Finish any in-flight publication; later writers must observe stop.
        self.t.join(timeout=3)

    def assets_done(self):
        """追加内容 ‖ 界面布局 都收尾了（pack/refresh.sh 的 <产物根目录>/.refresh/<款>.<进程号>/*.rc）= 关键链进入配置推导 · 抽取"""
        try:
            return any((d / "aoc.rc").is_file() and (d / "uilayout.rc").is_file() for d in self.roots.glob(".refresh/" + self.game_id + ".*"))
        except OSError:
            return False

    def loop(self):
        while not self.stop.wait(1):
            ids = getattr(self.c, "milestone_ids", None) or [m for m, *_ in MILESTONES]
            if "direct" not in ids:
                return
            if "analyze" in ids and getattr(self.c, "milestone", None) == "refresh" and self.assets_done():
                with self.c.guard:
                    if self.stop.is_set():
                        return
                    reuse(self.c, "analyze", False)
                    enter(self.c, "analyze")
            try:
                seen = any(self.roots.glob(self.game_id + "@dl-*.tmp"))
            except OSError:
                continue   # A temporary version can disappear while the producer replaces it.
            if not seen:
                continue
            with self.c.guard:
                if self.stop.is_set():
                    return
                reuse(self.c, "direct", False)   # 直连临时版本出现 = 这一步真在重出（键变了），不是复用：当场改回冷步、重发计划
                enter(self.c, "direct")
            return
