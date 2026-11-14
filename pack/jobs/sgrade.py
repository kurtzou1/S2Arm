# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级优化升级（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包就能用上 S 级优化）。

原始程序（exefs：main / sdk / subsdk* / main.npdm，几十 MB）是给老游戏补 S 级优化的唯一原料：
  出 iPhone 包时存一份到这款游戏文件夹 original-exefs/（save_program，pack/jobs/ipa.py 调）；老游戏没存过的，「升级前查找」从原件只解 exefs 补存。
  pack/jobs/rewrite_refresh.py original_exefs 优先读它。

作业：
  sgradeScan  「S 级优化升级」页打开时：逐款找原始程序（存下的 → 解包缓存 → Mac 运行版本 → 原件只解 exefs 并存下），
              按补丁库（本地：随启动器的快照与增量缓存，不联网）看这个版本有哪几类补丁 → 每款 {program, patches, iphone, mac, off}
  sgradeMac   启动器打开时后台跑：游戏库里有 Mac 运行版本的款逐款补上 S 级优化（rewrite_refresh.refresh_mac，按补丁记号，补过的不重做）"""
from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

import layout
from core import Failure

PROGRAM_DIR = "original-exefs"
MODULES = ("main", "main.npdm", "sdk") + tuple(f"subsdk{i}" for i in range(10))


def saved_program(c, gid):
    d = layout.path(c, gid, PROGRAM_DIR, create=False)
    return d if (d / "main").is_file() and (d / "main.npdm").is_file() else None


def save_program(c, gid, exefs):
    """原始程序存一份到这款游戏文件夹（已存且主程序相同就不动）→ 存下的目录；源目录不完整 → None"""
    exefs = Path(exefs)
    if not ((exefs / "main").is_file() and (exefs / "main.npdm").is_file()):
        return None
    dest = layout.path(c, gid, PROGRAM_DIR)
    if (dest / "main").is_file() and (dest / "main").read_bytes()[0x40:0x60] == (exefs / "main").read_bytes()[0x40:0x60]:
        return dest
    tmp = dest.with_name(PROGRAM_DIR + ".partial")
    shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(parents=True)
    for m in MODULES:
        if (exefs / m).is_file():
            shutil.copyfile(exefs / m, tmp / m)
    shutil.rmtree(dest, ignore_errors=True)
    tmp.rename(dest)
    return dest


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


def local_patches(c, gid, bid):
    """这个版本在本地补丁库（快照 + 增量缓存，不联网）里各类条数（同 patches.match 的口径：按构建号精确对）"""
    import patches
    snap, snap_get = patches._snapshot(c)
    keys = [f"g/{gid}"] + ([f"b/{bid[:16]}"] if len(bid) >= 16 else [])
    out = {k: 0 for k in patches.CATS}
    for k in keys:
        for it in patches.bundle(c, k, None, snap, snap_get):
            if it.get("kind") == "pso":
                continue
            if bid and any(patches.bid_hit(bid, b) for b in it.get("bids") or []):
                out[it.get("cat") if it.get("cat") in patches.CATS else "gfx"] += 1
    return out


def scan(c):
    c.begin("查找原始程序与补丁", 1, 1)
    games = []
    for g in c.catalog()["games"]:
        gid = g["id"].upper()
        info = layout.game_info(c, gid)
        iphone = (layout.ios_kit(c, gid) / "main.npdm").is_file()
        mac = (layout.image_mac(c, gid, create=False) / "exefs/main").is_file()
        if not (iphone or mac):
            continue   # 没出过包：没有可升级的东西（出包时就会带上 S 级优化）
        where, exefs = find_program(c, g)
        bid = (exefs / "main").read_bytes()[0x40:0x48].hex().upper() if exefs else ""
        pats = local_patches(c, gid, bid) if bid else {}
        games.append(dict(id=gid, name=g.get("name") or gid, program=where, build=bid, patches=pats, total=sum(pats.values()),
                          iphone=iphone, mac=mac, off=info.get("sgradeOff") is True))
    found = [x for x in games if x["program"] != "none"]
    return dict(games=games, found=len(found), upgradable=sum(1 for x in found if x["total"] and not x["off"]),
                noPatch=sum(1 for x in found if not x["total"]), missing=len(games) - len(found))


def mac_all(c):
    """启动器打开时后台跑（v0.4.0）：有 Mac 运行版本的款逐款补上 S 级优化；补丁记号没变的 refresh_mac 自己跳过。一款出错不挡别的"""
    from rewrite_refresh import refresh_mac
    games = [g for g in c.catalog()["games"] if (layout.image_mac(c, g["id"], create=False) / "exefs/main").is_file()]
    c.begin("给 Mac 游戏补上 S 级优化", 1, 1)
    done = []
    for g in games:
        try:
            with c.lock("execution"):   # 与开始游戏同一把锁：正在玩的那款不在运行中改
                if refresh_mac(c, g["id"], layout.image_mac(c, g["id"], create=False)):
                    done.append(g["id"].upper())
        except (Failure, OSError) as e:
            c.emit("message", f"【黄】{g.get('name') or g['id']} 这次没补上：{str(e)[:160]}")
    if done:
        c.emit("message", f"已给 {len(done)} 款 Mac 游戏补上 S 级优化")
    return dict(updated=done, checked=len(games))
