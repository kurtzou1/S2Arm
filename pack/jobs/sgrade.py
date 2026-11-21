# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级优化升级（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包就能用上 S 级优化）。

原始程序（exefs：main / sdk / subsdk* / main.npdm，几十 MB）是给老游戏补 S 级优化的唯一原料：
  出 iPhone 包时存一份到这款游戏文件夹 original-exefs/（save_program，pack/jobs/ipa.py 调）；老游戏没存过的，「升级前查找」从原件只解 exefs 补存。
  pack/jobs/rewrite_refresh.py original_exefs 优先读它。

作业：
  sgradeScan  「S 级优化升级」页打开时：逐款找原始程序（存下的 → 解包缓存 → Mac 运行版本 → 原件只解 exefs 并存下），
              按补丁库（本地：随启动器的快照与增量缓存，不联网）看这个版本有哪几类补丁 → 每款 {program, patches, iphone, mac, off}
  sgradeUpgradeGame 玩家对一款点「S 级优化」才升级（11-17 起不自动）；sgradeMac 旧名，不带 gameId 不做事。原先：启动器打开时后台跑：游戏库里有 Mac 运行版本的款逐款补上 S 级优化（rewrite_refresh.refresh_mac，按补丁记号，补过的不重做）"""
from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

import layout
from core import Failure

PROGRAM_DIR = layout.PROGRAM_EXEFS
MODULES = ("main", "main.npdm", "sdk") + tuple(f"subsdk{i}" for i in range(10))


def saved_program(c, gid):
    d = layout.program_exefs(c, gid)
    return d if (d / "main").is_file() and (d / "main.npdm").is_file() else None


def save_program(c, gid, exefs):
    """原始程序存进游戏程序常驻（.programs/<号>/exefs.tar.zst，pack/jobs/programs.py；已存且主程序相同就不动）→ 解开的那份（缓存）；源目录不完整 → None"""
    exefs = Path(exefs)
    if not ((exefs / "main").is_file() and (exefs / "main.npdm").is_file()):
        return None
    dest = layout.program_exefs(c, gid)
    if (dest / "main").is_file() and (dest / "main").read_bytes()[0x40:0x60] == (exefs / "main").read_bytes()[0x40:0x60]:
        return dest
    tmp = Path(tempfile.mkdtemp(prefix=".exefs-"))
    try:
        for m in MODULES:
            if (exefs / m).is_file():
                shutil.copyfile(exefs / m, tmp / m)
        import programs
        return programs.save_exefs(c, gid, tmp)   # 常驻 exefs.tar.zst + 缓存解开的一份
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def find_program(c, game, extract=True):
    """→ (来处, exefs 目录 | None)。来处：saved / cache / mac / source（从原件只解 exefs、已存下）/ none"""
    from build import extract_valid, shared_dir
    gid = game["id"].upper()
    d = saved_program(c, gid)
    if d:
        return "saved", d
    try:
        if extract_valid(c, game):
            return "cache", shared_dir(c, game) / "extract/exefs"
    except (OSError, Failure, ValueError):
        pass
    mac = layout.image_mac(c, gid, create=False) / "exefs"
    if (mac / "main").is_file() and (mac / "main.npdm").is_file():
        return "mac", mac
    if extract:
        from rewrite_refresh import original_exefs
        with tempfile.TemporaryDirectory(dir=c.private) as tmp:
            try:
                x = original_exefs(c, game, Path(tmp))
            except (OSError, Failure, ValueError) as e:
                c.emit("message", f"【黄】{game.get('name') or gid} 从原件取原始程序没成：{str(e)[:160]}")
                x = None
            if x is not None and (saved := save_program(c, gid, x)):
                return "source", saved
    return "none", None


def local_patches(c, gid, bid, others=None):
    """这个版本在本地补丁库（快照 + 增量缓存，不联网）里各类条数（同 patches.match 的口径：按构建号精确对）。
    others 给一个 dict：顺带收「只有别的版本」的各类版本号 {类: [版本号…]}（升级页拆「没有 / 是别的版本的」，同 patches.match 的 others）"""
    import patches
    snap, snap_get = patches._snapshot(c)
    keys = [f"g/{gid}"] + ([f"b/{bid[:16]}"] if len(bid) >= 16 else [])
    out = {k: 0 for k in patches.CATS}
    for k in keys:
        for it in patches.bundle(c, k, None, snap, snap_get):
            if it.get("kind") == "pso":
                continue
            cat = it.get("cat") if it.get("cat") in patches.CATS else "gfx"
            if bid and any(patches.bid_hit(bid, b) for b in it.get("bids") or []):
                out[cat] += 1
            elif others is not None:
                v = patches._version_label(it)
                if v and v not in others.setdefault(cat, []):
                    others[cat].append(v)
    return out


def scan(c):
    c.begin("查找原始程序与补丁", 1, 1)
    games = []
    for g in c.catalog()["games"]:
        gid = g["id"].upper()
        info = layout.game_info(c, gid)
        iphone = layout.has_ios_kit(c, gid)
        mac = (layout.image_mac(c, gid, create=False) / "exefs/main").is_file()
        if not (iphone or mac):
            continue   # 没出过包：没有可升级的东西（出包时就会带上 S 级优化）
        where, exefs = find_program(c, g)
        bid = (exefs / "main").read_bytes()[0x40:0x48].hex().upper() if exefs else ""
        oth = {}
        pats = local_patches(c, gid, bid, oth) if bid else {}
        import patches as _p   # 维护者 11-15「两者合成一套」：没社区满屏补丁、这一版在宽屏已验证名单 → 满屏算我方通用满屏
        own = not pats.get("widescreen") and _p.own_widen(c, gid, bid)
        import sgrade_bf   # 直连库缺可读瓦片版着色器（_bf）：iPhone 看 game.json ios.bfGen，Mac 看运行版本清单 bfGen
        from core import read
        bf = dict(iphone=iphone and sgrade_bf.due(c, gid),
                  mac=mac and sgrade_bf.stale(read(layout.image_mac(c, gid, create=False) / "manifest.json", {}).get("bfGen"))
                      and (layout.image_mac(c, gid, create=False) / "shaders/direct/keys.tsv").is_file())
        games.append(dict(id=gid, name=g.get("name") or gid, bfPending=bf, program=where, build=bid, patches=pats, total=sum(pats.values()) + (1 if own else 0),
                          ownWiden=bool(own), iphone=iphone, mac=mac, off=info.get("sgradeOff") is True,
                          versions={"mine": _p.display_version(c, g) or "",
                                    "available": {k: sorted(v) for k, v in oth.items() if not pats.get(k)}}))
    found = [x for x in games if x["program"] != "none"]
    return dict(games=games, found=len(found), upgradable=sum(1 for x in found if (x["total"] and not x["off"]) or any(x["bfPending"].values())),
                noPatch=sum(1 for x in found if not x["total"]), missing=len(games) - len(found))


UPGRADING = ".sgrade_upgrading.json"   # 这款的游戏文件夹里：单款升级开始写（作业号 / 进程号）、做完删；在且进程不在 = 升级没做完（catalog sgradeIncomplete）


def game_lock(gid):
    """这款的 S 级升级锁名（c.idle）：单款升级拿着它做完；开始游戏也拿它（build.launch），拿不到就说这款正在升级——两边只挡同一款，别的游戏照常"""
    return "sgrade-" + gid.upper()


def upgrade_state(c, gid):
    """这款的 S 级升级状态（catalog 给界面）：'upgrading'（单款升级作业在跑）| 'incomplete'（标记在、作业已不在：上次中途退出了）| None"""
    from core import read, pid_alive
    m = read(layout.game_dir(c, gid) / UPGRADING, None)
    if not isinstance(m, dict):
        return None
    return "upgrading" if m.get("pid") and pid_alive(m["pid"]) else "incomplete"


def mac_all(c):
    """作业 sgradeMac（旧启动器打开时自动起）：11-17 维护者定 S 级优化不再自动运行（「改成不自动运行，玩家手动点击 S 级优化再升级」）——
    不带 gameId 什么都不做；带了等同单款升级（upgrade_game）"""
    if c.r.get("gameId"):
        return upgrade_batch(c)
    return dict(updated=[], checked=0, manual=True)


class _GameProgress:
    """这一款 S 级升级的整款进度（0–1）：作业层唯一一份，事件字段 sgradeProgress 与队列文件 progress 都是它，两端界面只认它。
    为什么（玩家报修 D-QNA9，Mac 实机；Windows 同写法）：按段的粗进度（done / total = 第几段 / 共几段）和段内各模块自己的计数器
    （直连抽取 20673/252686、某计数 5/6…）原先都用 done / total 发，界面拿到哪条就用哪条盖，加上轮询队列文件的粗进度，进度条在 50%、0%、80% 间来回跳。
    口径同整单进度的按步算法（overall.py 的 _by_steps，期望可按事件手算）：(第几段 − 1 + 段内完成度) ÷ 段数，段内完成度 = 本段 progress 事件的 done / total；
    只增不减（段内计数器换一个、从 0 重数都不回退）；段做完 = 第几段 ÷ 段数（最后一段做完前封顶 0.99），整款做完 = 1。
    做法：升级期间包住 c.emit——段内各模块不用改，它们发的每条事件都顺带 sgradeProgress；队列文件（别的窗口 / 轮询读）节流写：涨够 1% 或隔 1 秒，段边界必写"""

    def __init__(self, c, steps, on_progress):
        import threading
        import overall
        self.c, self.steps, self.on_progress = c, steps, on_progress
        self.meter, self.step, self.value = overall.Overall(), 1, 0.0
        self.written, self.at, self.mutex = None, 0.0, threading.Lock()
        self.own = "emit" in vars(c)   # 测试替身等把 emit 放在实例上：收尾还原它，不是删掉
        self.emit = c.emit
        c.emit = self.relay

    def feed(self, kind, done=None, total=None, state=None):
        with self.mutex:
            v = self.meter.feed(kind, 0, None, state, self.step, max(1, self.steps), done, total)
            self.value = max(self.value, v or 0.0)
            return self.value

    def save(self, force=False):
        import time
        if not self.on_progress:
            return
        with self.mutex:
            now, v = time.monotonic(), self.value
            if v == self.written or not (force or self.written is None or v - self.written >= 0.01 or now - self.at >= 1):
                return
            self.written, self.at = v, now
        self.on_progress(v)

    def relay(self, kind="progress", message="", done=None, total=None, **extra):
        """段内模块发的事件：progress 的 done / total 喂进段内完成度；每条事件都带上整款进度"""
        if kind == "progress":
            self.feed(kind, done, total)
        self.emit(kind, message, done=done, total=total, sgradeProgress=self.value, **extra)
        if kind == "progress":
            self.save()

    def boundary(self, n):
        """开始（n = 0）/ 第 n 段做完：照发按段的 done / total，整款进度落到 n ÷ 段数（全做完 = 1），队列文件必写"""
        self.feed("progress", 1 if n else 0, 1)
        if n and n >= self.steps:
            self.feed("result", state="succeeded")
        self.emit("progress", done=n, total=self.steps, sgradeProgress=self.value)
        self.save(force=True)

    def close(self):
        if self.own:
            self.c.emit = self.emit
        else:
            del self.c.emit


def upgrade_game(c, on_progress=None):
    """作业 sgradeUpgradeGame：玩家对这一款点「S 级优化」才升级（11-17 维护者定，不自动）。Mac 运行版本补 S 级补丁（rewrite_refresh.refresh_mac）
    与可读瓦片版着色器（sgrade_bf.upgrade_mac）；有 iPhone 程序件的一并补（rewrite_refresh.refresh_ios，Windows 只有这一段）。
    进度：这期间每条事件带 sgradeProgress（整款 0–1、只增不减，_GameProgress），on_progress(0–1) 节流写进队列；另照发按段的 done / total（每做完一段进一格），
    阶段事件 stageKey sgrade.mac / sgrade.bf / sgrade.ios；升级中这款开始游戏被拒（game_lock），别的游戏照常；
    开始时写未完成标记、做完删——中途退出启动器，下次打开不续跑，catalog 标 sgradeIncomplete，玩家再点就是同一个单款升级（已做完的部分各步按记号跳过）"""
    import json, os, sys
    from rewrite_refresh import refresh_mac, refresh_ios
    import sgrade_bf
    import ipa as packer
    from core import atomic
    gid = str(c.r.get("gameId") or "").upper()
    if not gid:
        raise Failure("没有指定要升级的游戏。", code="job_failed")  # 非玩家句（只有启动器传错参数才会到）
    runtime = layout.image_mac(c, gid, create=False)
    mac = sys.platform == "darwin" and (runtime / "exefs/main").is_file()
    iphone = layout.has_ios_kit(c, gid)
    with c.idle(game_lock(gid)) as free:
        if not free:
            raise Failure("这款游戏正在运行或正在升级，等它结束后再点「S 级优化」。", code="library_busy")
        marker = layout.game_dir(c, gid) / UPGRADING
        atomic(marker, dict(task=c.task, pid=os.getpid()))
        steps = [k for k, on in (("mac", mac), ("bf", mac), ("ios", iphone)) if on]
        done = {}
        meter = _GameProgress(c, len(steps), on_progress)
        meter.boundary(0)   # 段名看阶段事件 stageKey
        try:
            for n, k in enumerate(steps, 1):
                meter.step = n
                if k == "mac":
                    c.begin("补上 S 级优化（满屏 / 帧率 / 金手指）", n, len(steps), key="sgrade.mac")
                    done[k] = bool(refresh_mac(c, gid, runtime))   # 拿着这款的锁：起局拿不到，不用 hold
                elif k == "bf":
                    c.begin("补上片上读取用的着色器（首次要几分钟）", n, len(steps), key="sgrade.bf")
                    done[k] = bool(sgrade_bf.upgrade_mac(c, gid, runtime))
                else:
                    c.begin("补上 iPhone 版的 S 级优化", n, len(steps), key="sgrade.ios")
                    with packer.program_locks(c, [gid]):
                        done[k] = bool(refresh_ios(c, [gid]))
                meter.boundary(n)
        finally:
            meter.close()
        marker.unlink(missing_ok=True)
    return dict(gameId=gid, updated=[gid] if any(done.values()) else [], steps=done, mac=mac, iphone=iphone)



# ---- 升级队列（11-17 维护者「可以做批量升级……有全选功能没问题」；排队只在作业层一套，两端界面只提交 / 停止 / 读状态）----
# 游戏库里一份队列文件：作业 sgradeUpgradeBatch {gameIds} 提交——没有在跑的队列就自己当跑队列的作业，逐款串行升（同一时刻只一款，每款 = upgrade_game）；
#   已有在跑的就把没在队里的款追加到队尾，立刻返回（joined = 跑队列的任务号）。单款「升级」= 只有一款的批量（sgradeUpgradeGame 走同一入口）。
#   每款状态 queued 排队中 / running 正在升（progress 0–1）/ done 做完 / skipped 这款正在运行没升（reason）/ incomplete 没做完（出错或被停：未完成标记留着）。
#   关掉升级页 / 窗口队列照跑（作业进程不归页面）；跑队列的作业被停（sgradeUpgradeStop → 取消它）或启动器退出：排着的不做（从队列去掉），
#   正做的那款标记留着 = 未完成；下次打开不自动续跑。读状态：catalog 每款 sgradeState / sgradeProgress、顶层 sgradeBatch，或作业 sgradeUpgradeStatus
QUEUE = ".sgrade-queue.json"
QUEUE_STATES = ("queued", "running", "done", "skipped", "incomplete")


def _queue_lock(c):
    import filelock
    return filelock.held(c.library / ".sgrade-queue.lock", wait_s=30)   # 不经 c.lock：被取消的作业收尾也要写队列（c.lock 先查取消）


def _queue_live(q):
    from core import pid_alive, pid_start
    if not isinstance(q, dict) or not q.get("pid") or q.get("finished"):
        return False
    return pid_alive(q["pid"]) and (not q.get("pidStart") or pid_start(q["pid"]) == q["pidStart"])


def _queue_write(c, q):
    from core import atomic
    atomic(c.library / QUEUE, q)


def queue_status(c):
    """队列现状（界面直接用）→ {running, task, index, count, games: [{gameId, state, progress, reason}]}。跑队列的作业已不在（被停 / 启动器退出 / 崩溃）：
    running 的那款记 incomplete、排着的去掉。index = 正在升的是第几款（没在升 = 已结束的款数），count = 这一批共几款（含去掉前已结束的）"""
    from core import read
    q = read(c.library / QUEUE, None)
    if not isinstance(q, dict):
        return dict(running=False, task=None, index=0, count=0, games=[])
    live = _queue_live(q)
    games = []
    for it in q.get("items") or []:
        st = it.get("state")
        if not live and st == "queued":
            continue
        if not live and st == "running":
            st = "incomplete"
        games.append(dict(gameId=it["gameId"], state=st, progress=1.0 if st == "done" else float(it.get("progress") or 0), reason=it.get("reason") or ""))
    ended = sum(1 for g in games if g["state"] in ("done", "skipped", "incomplete"))
    run = next((n for n, g in enumerate(games, 1) if g["state"] == "running"), None)
    return dict(running=live, task=q.get("task"), index=run or ended, count=len(games), games=games)


def upgrade_batch(c):
    """作业 sgradeUpgradeBatch {gameIds}（也收单个 gameId）：见上方队列说明。跑队列时每款发 type=batch 事件 phase start / end（index / count，
    end 带 status），每款内部的事件带 gameId 与整款进度 sgradeProgress（界面只认它；done / total 是段内计数，不当整款进度）"""
    import os, time
    from core import Cancelled, pid_start, read, trace
    ids = []
    for g in list(c.r.get("gameIds") or []) + ([c.r["gameId"]] if c.r.get("gameId") else []):
        g = str(g or "").upper()
        if g and g not in ids:
            ids.append(g)
    if not ids:
        raise Failure("没有选要升级的游戏。", code="job_failed")  # 非玩家句（只有启动器传错参数才会到）
    with _queue_lock(c):
        q = read(c.library / QUEUE, None)
        if _queue_live(q):
            have = {it["gameId"] for it in q["items"] if it.get("state") in ("queued", "running")}
            add = [g for g in ids if g not in have]
            q["items"] += [dict(gameId=g, state="queued") for g in add]
            _queue_write(c, q)
            trace(c, f"S 级升级队列在跑（{q['task']}）：追加 {len(add)} 款 {' '.join(add)}")  # 非玩家句
            return dict(joined=q["task"], added=add, status=queue_status(c))
        q = dict(task=c.task, pid=os.getpid(), pidStart=pid_start(os.getpid()), started=time.time(), items=[dict(gameId=g, state="queued") for g in ids])
        _queue_write(c, q)
    keep, cur = c.r, None

    def update(gid, **kw):
        with _queue_lock(c):
            q = read(c.library / QUEUE, {}) or {}
            for it in q.get("items") or []:
                if it["gameId"] == gid and it.get("state") in ("queued", "running"):
                    it.update(kw)
                    break
            _queue_write(c, q)
            return q

    try:
        while True:
            with _queue_lock(c):
                q = read(c.library / QUEUE, {}) or {}
                items = q.get("items") or []
                nxt = next((it for it in items if it.get("state") == "queued"), None)
                if nxt is None:
                    q["finished"] = time.time()
                    _queue_write(c, q)
                    break
                nxt.update(state="running", progress=0)
                _queue_write(c, q)
                cur, index, count = nxt["gameId"], items.index(nxt) + 1, len(items)
            c.r = dict(keep, gameId=cur)
            c.emit("batch", "", phase="start", index=index, count=count)
            try:
                upgrade_game(c, on_progress=lambda p, g=cur: update(g, progress=round(p, 4)))
                state, reason = "done", ""
            except Cancelled:
                raise
            except Failure as e:
                state, reason = ("skipped" if e.code == "library_busy" else "incomplete"), str(e)
            except Exception as e:   # noqa: BLE001 —— 一款出错不停整批：这款记未完成（标记留着，玩家可再点），接着做下一款
                state, reason = "incomplete", f"{type(e).__name__}: {e}"[:300]
            update(cur, state=state, reason=reason, progress=1.0 if state == "done" else None)
            trace(c, f"S 级升级 {index}/{count} {cur}：{state}" + (f"（{reason}）" if reason else ""))  # 非玩家句
            c.emit("batch", "", phase="end", index=index, count=count, status=state, reason=reason)
            cur = None
            c.r = keep
    except Cancelled:
        # 停止：正做的那款记未完成（未完成标记由 upgrade_game 留着），排着的去掉，队列结束
        with _queue_lock(c):
            q = read(c.library / QUEUE, {}) or {}
            q["items"] = [dict(it, state="incomplete") if it.get("state") == "running" else it
                          for it in q.get("items") or [] if it.get("state") != "queued"]
            q["finished"] = time.time()
            _queue_write(c, q)
        raise
    finally:
        c.r = keep
    st = queue_status(c)
    return dict(st, updated=[g["gameId"] for g in st["games"] if g["state"] == "done"])


def upgrade_one(c):
    """作业 sgradeUpgradeGame {gameId}：单款升级 = 只有一款的批量（同一个队列入口）"""
    return upgrade_batch(c)


def upgrade_stop(c):
    """作业 sgradeUpgradeStop：停整批——取消跑队列的作业（同界面点取消：SIGTERM → 正做的那款按记号保留已做完的段、标记留着；排着的不做）"""
    import core
    from core import read
    q = read(c.library / QUEUE, None)
    if not _queue_live(q):
        return dict(stopped=False, status=queue_status(c))
    r = core.cancel(c.private, q["task"])
    return dict(stopped=bool(r.get("cancelled")), task=q["task"], status=queue_status(c))


def upgrade_status(c):
    """作业 sgradeUpgradeStatus：只读队列现状（不靠起批量的那个窗口）"""
    return queue_status(c)

# S 级优化按类状态（11-15 维护者「优化 S 级优化，让满屏更好用」；口径与体验梳理线 cmdr/S级状态与文案_三端对照 第二节一致，界面按它显示）：
#   每款四类 widescreen / fps / gfx / cheats，各一段 {state, source（满屏才有）, active, lastRun, autoOff, versions}。state 取值：
#   on 在用 · ineffective 开着但上一局没生效 · off_user 玩家关的 · off_auto 自动关的（崩溃 / 画面停住）· version 补丁库有、版本不同 ·
#   none 补丁库没有这一类 · opted_out 出包时选了不打入 · pending 能用、还没打进这个包 · mac_only 画面类在 iPhone · unknown 还不知道版本
#   满屏 source：patch 社区补丁（含移植成的）· own 我方通用满屏（维护者 11-15「两者合成一套」：没补丁、在宽屏已验证名单）· none
STATES = ("on", "ineffective", "off_user", "off_auto", "version", "none", "opted_out", "pending", "mac_only", "unknown")


def _auto_off(c, gid):
    import cheats
    from core import read
    ao = read(cheats.cheats_dir(c, gid, create=False) / "auto_off.json", None)
    if not isinstance(ao, dict):
        return set(), {}
    return {tuple(x) for x in ao.get("off", [])}, ao.get("meta") or {}


def _match(c, gid):
    """补丁库按版本的对照（patches.match）：要 c.r 里是这款；取不到（没解过包 / 单测没补丁库）给空"""
    import patches
    keep = getattr(c, "r", None)
    try:
        c.r = dict(keep or {}, gameId=gid)
        return patches.match(c)
    except Exception:   # noqa: BLE001 —— 状态只读展示，查不到版本对照不挡别的类
        return {}
    finally:
        c.r = keep


def fi_supported():
    """这台 Mac 能不能补帧：出图补帧只走 Metal 4（macOS 26 起，graphics/nvn/gfx/nvn/nvn_present_fi.inc）"""
    import platform
    v = platform.mac_ver()[0]
    return bool(v) and int(v.split(".")[0]) >= 26


def fps_failed(c, gid, platform):
    """这款这一端出包时没打进去的帧率补丁（patches.record 记的 sgradeResult.<端>.failed 里 cat = fps）→ [{name, why}]（why = 文案键 result.why.*）。
    11-15 #934：补丁库有这一版的帧率补丁、一份都没打进去时，开关不能显示成开着生效，要如实写「没能打入（原因）」"""
    res = ((layout.game_info(c, gid) or {}).get("sgradeResult") or {}).get(platform) or {}
    return [dict(name=f.get("name") or "", why=f.get("why") or "") for f in res.get("failed") or [] if isinstance(f, dict) and f.get("cat") == "fps"][:3]


def state(c, game, match=None):
    """→ {platform: mac, widescreen: {…}, fps: {…}, gfx: {…}, cheats: {…}}（Mac 启动器读；iPhone 读出包写进 kit 的 sgrade_state.json + 本机开关）"""
    import community, cheats
    gid = game["id"].upper()
    img = layout.image_mac(c, gid, create=False)
    exported = (img / "exefs" / "main").is_file()
    rows = community._rows(img / "cpatch.tsv")
    data = community.load_launch(c, gid)
    sset, pset = data["settings"], data["patches"]
    st = community.patch_status(c, gid)
    off, meta = _auto_off(c, gid)
    opted = (layout.game_info(c, gid) or {}).get("sgradeOff") is True
    m = match if match is not None else (_match(c, gid) if exported else {})
    exact, others = m.get("exact") or {}, m.get("others") or []
    mine = m.get("version") or ""

    def versions(cat):
        return {"mine": mine, "available": [o["version"] for o in others if cat in o.get("cats", [])],
                "port": ("failed" if not exact.get("widescreen") else "ok") if cat == "widescreen" and m.get("port") else "none"}

    def auto(keys):
        for k in keys:
            if k in off:
                info = meta.get(f"{k[0]}\t{k[1]}") or {}
                return {"cause": info.get("cause", "crash"), "at": info.get("at")}
        return None

    def bad(s):   # 上一局没生效：数据对不上 / 表不认 / 没铺满
        return bool(s) and (s[0] in ("不配套", "表不认") or s[1] == "unfilled")   # 非玩家句（表列名 / 运行时状态值）

    def missing(cat):   # 包里没有这一类时：补丁库有别的版本 = version，否则 none；没出包 / 不知道版本 = unknown / pending
        if not exported or not m.get("build"):
            return "unknown"
        if exact.get(cat):
            return "pending"   # 这份版本补丁库有、包里没有：老包，升级页能补
        return "version" if any(cat in o.get("cats", []) for o in others) else "none"

    out = {"platform": "mac"}
    # 满屏：社区补丁（自适应一族 wsauto: 跟满屏开关；定画幅变体 widescreen:auto；其余 widescreen: 单列）→ 我方通用满屏 → 没有
    fams, _ = community.adaptive_patches(c, gid)
    ws_ids = sorted({(r.get("编号") or "") for r in rows if (r.get("编号") or "").startswith("widescreen:")})   # 非玩家句（表列名 / 运行时状态值）
    fixed = any(float(r.get("画幅") or 0) > 0 for r in rows if (r.get("编号") or "").startswith("widescreen:") and (r.get("画幅") or "").replace(".", "", 1).isdigit())   # 非玩家句（表列名 / 运行时状态值）
    # 11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」：没有社区满屏补丁的款一律可开我方通用满屏（第三层整套放宽，不看已验证名单），缺省关
    src = "patch" if fams or ws_ids else "own" if exported else "none"
    switch = sset.get("widescreen", True) is not False if src == "patch" else sset.get("widescreen") is True
    keys = [("fs", "fullscreen")] + [("patch", k) for k in ws_ids] + ([("patch", "widescreen:auto")] if fixed else [])
    ws_st = next((st[k] for k in [*(fams or []), "widescreen:auto", *ws_ids] if k in st), None)
    if opted: s = "opted_out"
    elif src == "none": s = missing("widescreen")
    elif auto(keys) and not switch: s = "off_auto"
    elif not switch: s = "off_user"
    elif bad(ws_st): s = "ineffective"
    else: s = "on"
    out["widescreen"] = {"state": s, "source": src, "active": "adaptive" if fams else "fixed" if fixed else "own" if src == "own" else "",
                         "lastRun": community.patch_result(ws_st), "autoOff": auto(keys), "versions": versions("widescreen")}
    # 帧率解锁（11-15 维护者「补帧稳定了就直接用补帧」）：有社区帧率补丁用补丁（按档），没有用补帧（MetalFX 30→60，Metal 4 才有）；二选一。
    #   Mac 今天缺省不补帧：没补丁的款玩家明确开才补（pack/jobs/community.py launch_env 写 DM_PRESENT_FI），不退化
    levels = community.fps_levels(c, gid)
    fi_ok = fi_supported()
    on = sset.get("fps60", True) is not False if levels else sset.get("fps60") is True
    pick = str(sset.get("fpsPick") or "0")
    fst = next((v for k, v in st.items() if k.startswith("fps:") and v[0] == "开"), None)   # 非玩家句（表列名 / 运行时状态值）
    target = int(pick) if pick.isdigit() and int(pick) else (max(levels) if levels else 0)
    weak = bool(fst) and fst[1].startswith("fps=") and fst[1][4:].isdigit() and int(fst[1][4:]) < (min(target, 60) if pick == "0" else target) - 5
    ffail = [] if levels else fps_failed(c, gid, "mac")
    if opted: s = "opted_out"
    elif ffail: s = "failed"   # 补丁库有、一份没打进去（转换器不支持 / 对不上 …）：不说成开着生效，也不说成「不支持补帧」
    elif not levels and not exported: s = "unknown"
    elif not levels and not fi_ok: s = "unsupported"
    elif auto([("fps", "fps60")]) and not on: s = "off_auto"
    elif not on: s = "off_user"
    elif weak: s = "ineffective"
    else: s = "on"
    out["fps"] = {"state": s, "source": "patch" if levels else "fi", "fiSupported": fi_ok, "active": {"levels": levels, "pick": pick}, "lastRun": community.patch_result(fst),
                  **({"failed": ffail} if ffail else {}),
                  "autoOff": auto([("fps", "fps60")]), "versions": versions("fps")}
    # 画面：Mac 才打（iPhone 一律 mac_only）
    gfx = [it for it in community.packed_patches(c, gid) if it["kind"] == "gfx"]
    gon = [it for it in gfx if community.patch_on(pset, it)]   # 没选过：降负载的缺省关（11-16）
    gkeys = [("patch", it["id"]) for it in gfx]
    if opted: s = "opted_out"
    elif not gfx: s = missing("gfx")
    elif gon: s = "ineffective" if all(bad(st.get(it["id"])) for it in gon) else "on"
    else: s = "off_auto" if auto(gkeys) else "off_user"
    out["gfx"] = {"state": s, "active": [it["id"] for it in gon], "lastRun": "", "autoOff": auto(gkeys), "versions": versions("gfx")}
    # 金手指：打进包、缺省关，玩家逐条开
    items = [it for it in cheats.listing(c, game)["items"] if it.get("ok")] if exported else []
    con = [it["key"] for it in items if it["enabled"]]
    ckeys = [("cheat", it["key"]) for it in items]
    if opted: s = "opted_out"
    elif not items: s = missing("cheat")
    elif con: s = "on"
    else: s = "off_auto" if auto(ckeys) else "off_user"
    out["cheats"] = {"state": s, "active": con, "lastRun": "", "autoOff": auto(ckeys), "versions": versions("cheat")}
    return out


def reenable(c):
    """一键重开（sgradeReenable {gameId, key}）：key = fps / fullscreen / 补丁编号 / 金手指「文件名/条目名」。打开它、从自动关记录去掉 → 新状态"""
    import community, cheats
    from core import atomic
    gid = (c.r.get("gameId") or "").upper(); key = c.r.get("key") or ""
    game = community.game_of(c, gid)
    data = community.load_launch(c, gid)
    if key == "fps":
        data["settings"].pop("fps60", None); t = ("fps", "fps60")
    elif key == "fullscreen":
        data["settings"].pop("widescreen", None); t = ("fs", "fullscreen")
    elif ":" in key and "/" not in key:
        data["patches"].pop(key, None); t = ("patch", key)
    elif "/" in key:
        cheats.save(c, game, {key: True}); t = ("cheat", key)
    else:
        raise Failure("重开哪一项没说清楚。", code="job_failed")
    if t[0] != "cheat":
        atomic(community.launch_path(c, gid), data)
    cheats.forget_auto_off(c, gid, [t])
    return state(c, game)


def write_kit_state(c, gid, kit):
    """出 iPhone 包后写 <iOS kit>/sgrade_state.json：手机上没有补丁库，版本对照 / 满屏来源 / 出包时选不打入由这里给，
    开关、上一局是否生效、自动关由手机本机算（ios/game_options.m s2a_ios_sgrade_state 读它，按 state() 同一套状态码）。写不出不挡出包"""
    import json, community
    from core import atomic
    try:
        kit = Path(kit)
        rows = community._rows(kit / "cpatch.tsv")
        ids = [r.get("编号") or "" for r in rows]   # 非玩家句（表列名）
        m = _match(c, gid)
        vers = lambda cat: {"mine": m.get("version") or "", "available": [o["version"] for o in m.get("others") or [] if cat in o.get("cats", [])],
                            "exact": int((m.get("exact") or {}).get(cat) or 0)}
        ws = "patch" if any(i.startswith(("widescreen:", "wsauto:")) for i in ids) else "own"   # 11-15：没补丁一律可开我方通用满屏（不看已验证名单）
        out = {"schema": 1, "build": m.get("build") or "", "optedOut": (layout.game_info(c, gid) or {}).get("sgradeOff") is True,
               "widescreen": dict(source=ws, port="failed" if m.get("port") and not (m.get("exact") or {}).get("widescreen") else "none", versions=vers("widescreen")),
               "fps": dict(versions=vers("fps"), **({} if any(i.startswith("fps:") for i in ids) or not fps_failed(c, gid, "ios") else
                                                    dict(state="failed", failed=fps_failed(c, gid, "ios")))),
               "gfx": dict(state="mac_only"), "cheats": dict(versions=vers("cheat"))}
        atomic(kit / "sgrade_state.json", out)
    except (OSError, ValueError, TypeError) as e:
        c.emit("message", f"【黄】S 级状态底料没写出（不影响出包）：{str(e)[:120]}")   # 非玩家句
