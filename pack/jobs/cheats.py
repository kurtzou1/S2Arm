"""金手指（11-12 维护者：出包时自动对接公开库，「咱们只是提供了便利的对接服务」）：一款游戏文件夹的 cheats/ 是唯一的家。
  · 来源只是一个字段：玩家导入的（from = player）与出包时从公开库取来的（from = library）同放 cheats/*.txt（Atmosphere 格式），
    来源记在 cheats/sources.json {文件名: {from, repo, path, author, license, fetched}}；没登记的文件按玩家导入算。
  · 开关 cheats/enabled.txt（每行「文件名/条目名」，缺省全关），运行时服务层 services/S2A.Services/Cheats.cs 每秒重载、局内即时生效；
    改游戏代码的条目在出包时编进包（pack/cpatch.py scan_cheats，作业层 core.env 交 S2A_CHEATS_DIRS），状态 status.txt 由 Cheats.cs 写。
  · 查库：按程序号 + 主程序构建号前 16 位取，每库 10 秒，离线 / 没查到 / 格式不认都静默跳过、不挡出包；只解析文本，大小有上限。
    仓库与安装包不放这些文件（只在玩家本机按需下载，同 EdiZon / Breeze 这类金手指管理器的做法）。"""
from __future__ import annotations

import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from core import Failure, atomic, read

TIMEOUT = 10
MAX_BYTES = 4 << 20
SKIP = ("enabled.txt", "status.txt")
# Cheats.cs 状态串（与 iOS ios/vpad_cheats.m 同一约定）在电脑上的说法：改代码的条目没编进这次的包 = 重新准备这款就能编进去
STATUS = {"改代码，不支持": "这条要改游戏代码：重新准备这款就能用。"}
UA = "S2Arm-cheats"   # 公开接口要求带 User-Agent；不带任何本机 / 用户信息


def cheats_dir(c, gid, create=True):
    import layout
    return layout.path(c, gid, "cheats", create=create)


def main_build(c, game):
    """这款实际运行的主程序构建号前 16 位（大写）：读共用解包目录里的主程序（NSO 头 0x40）。没解过包 = ''（目录里只记了本体的构建号，
    装了更新的款跑的是更新里的主程序，按目录取会错——11-12 暗黑 3：本体 EAFC2CEF，更新后 2607A74F）"""
    try:
        from build import shared_dir
        with open(shared_dir(c, game) / "extract/exefs/main", "rb") as f:
            f.seek(0x40)
            return f.read(8).hex().upper()
    except (OSError, ImportError, Failure):
        return ""


# 写死地址：指令按「堆 / 别名 / 随机区起点 + 固定偏移」直接寻址（Atmosphere 0 存值、1 条件、5 取值且不以寄存器为基址，第 3 位区号非 0 = 不是主程序区）。
#   这类地址赌的是游戏堆内的分配排布与作者当年环境一致；11-12 实测：同一存档在 Ryujinx 与我们这边目标数值都比金手指写的偏 0x10000，
#   即作者环境与现行环境不同、不是我们偏离参照。界面标「地址写死，可能不生效」、缺省关（开关缺省本就全关），玩家自己决定。
#   改代码（区号 0）、按主程序里的指针一路找（5 区号 0 起链）不受影响。规则两处一致：这里与 ios/cheats_parse.m fixed_address
def fixed_address(line):
    t = line.strip().split()
    if not t or len(t[0]) != 8 or not re.fullmatch(r"[0-9A-Fa-f]{8}", t[0]):
        return False
    w = t[0]
    if w[0] in "01":
        return w[2] != "0"
    if w[0] == "5":
        return w[4] == "0" and w[2] != "0"
    return False


def parse(text):
    """→ (文件头 BID 或 '', [(条目名, 是主代码, 行数, 写死地址)])，同 Cheats.cs Parse / pack/cpatch.py parse_cheats 的切段口径"""
    m = re.search(r"BID\s*=\s*([0-9A-Fa-f]{16,64})", text.split("\n", 1)[0])
    out, cur = [], None
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        h = re.fullmatch(r"([\[{])(.*)[\]}]", s)
        if h:
            cur = [h.group(2).strip(), h.group(1) == "{", 0, False]
            out.append(cur)
        elif cur is not None and not re.fullmatch(r"20[0-9A-Fa-f]{6}", s):   # 只有「条件块结束」的段是分类标题，不算条目
            cur[2] += 1
            cur[3] = cur[3] or fixed_address(s)
    return (m.group(1)[:16].upper() if m else ""), [(n, mst, k, fx) for n, mst, k, fx in out if k]


SHORT = {"bad1dea/NXCheats": "nxcheats", "HamletDuFromage/switch-cheats-db": "cheatsdb", "ChanseyIsTheBest/NX-60FPS-RES-GFX-Cheats": "gfx"}   # 文件名里的库简名（同 11-12 起的文件名，玩家已开的开关键不变）


def _unified(c):
    """金手指来源（11-13 维护者：由我们的下载站分发，统一包 pack/jobs/patches.py；各金手指库与补丁库附带的都在里面，按来源库分文件）"""
    import patches
    def get(gid, bids):
        by = {}
        for bid, text, repo, author, lic, path in patches.cheat_rows(c, gid, bids):
            t = by.setdefault((repo, bid), dict(text="", path=path, author=author, license=lic, repo=repo, short=SHORT.get(repo, "patchlibs")))
            if text.strip() not in t["text"]:
                t["text"] += text.rstrip("\n") + "\n\n"
        return [(bid, t) for (repo, bid), t in sorted(by.items())]
    return [("下载站统一包", "", get)]


def fetch(c, game, libraries=None):
    """出包第一步：按程序号（+ 已知的主程序构建号）查各公开库，取到的写进 cheats/<构建号>.<库简名>.txt（文件头补上 BID，运行时与出包都按它核版本）。
    任何一库失败都静默跳过（记 stderr），不挡出包；返回取到的库名"""
    libraries = libraries if libraries is not None else _unified(c)
    gid, bid = game["id"].upper(), main_build(c, game)
    bids = {bid} if bid else set()
    d = cheats_dir(c, gid)
    d.mkdir(parents=True, exist_ok=True)
    src = read(d / "sources.json", {}) or {}
    got = []
    for repo, short, get in libraries:
        try:
            found = get(gid, bids)
        except Exception as e:   # 离线 / 超时 / 库里没有（404）/ 结构变了：静默跳过
            print(f"金手指：{repo} 没取到（{type(e).__name__}）", file=sys.stderr)
            continue
        for fbid, r in found or []:
            rrepo, rshort = r.get("repo", repo), r.get("short", short)   # 统一包一条带自己的来源库
            text = r["text"].replace("\r\n", "\n")
            head = parse(text)[0]
            if not parse(text)[1] or (head and head != fbid) or (bids and fbid not in bids):
                continue
            if not head:
                text = f"[{rrepo} BID={fbid}]\n" + text
            name = f"{fbid}.{rshort}.txt"
            p = d / name
            if not p.is_file() or p.read_text(encoding="utf-8", errors="replace") != text:
                atomic_text(p, text)
            src[name] = {"from": "library", "repo": rrepo, "path": r["path"], "author": r["author"], "license": r["license"], "fetched": int(time.time())}
            if rrepo not in got:
                got.append(rrepo)
    atomic(d / "sources.json", src)
    return got


def atomic_text(p, text):
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(p)


def import_files(c, game, paths):
    """玩家导入：Atmosphere txt 拷进 cheats/（同名覆盖），登记 from = player；解析不出条目的不收"""
    d = cheats_dir(c, game["id"].upper())
    d.mkdir(parents=True, exist_ok=True)
    src = read(d / "sources.json", {}) or {}
    done = []
    for raw in paths:
        p = Path(raw)
        if not p.is_file() or p.stat().st_size > MAX_BYTES:
            raise Failure("金手指文件读不了或太大（上限 4 MB）：%s" % p.name, code="job_failed")
        text = p.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
        if not parse(text)[1]:
            raise Failure("这不是金手指文件（Atmosphere 格式的 txt）：%s" % p.name, code="job_failed")
        name = p.name if p.suffix.lower() == ".txt" else p.stem + ".txt"
        if name in SKIP or name == "sources.json":
            name = "imported-" + name
        atomic_text(d / name, text)
        src[name] = {"from": "player", "repo": "", "path": p.name, "author": "", "license": ""}
        done.append(name)
    atomic(d / "sources.json", src)
    return done


def listing(c, game):
    """启动器「游戏设置 → 金手指」：每条 {key, file, name, enabled, status, from, repo, author, ok, reason}（主代码不列：同文件任一条开着就随之执行）"""
    gid, bid = game["id"].upper(), main_build(c, game)
    d = cheats_dir(c, gid, create=False)
    if not d.is_dir():
        return dict(items=[], reason="这个版本没有现成的金手指。")
    src = read(d / "sources.json", {}) or {}
    enabled = set((d / "enabled.txt").read_text(encoding="utf-8").splitlines()) if (d / "enabled.txt").is_file() else set()
    status = {}
    if (d / "status.txt").is_file():
        for line in (d / "status.txt").read_text(encoding="utf-8", errors="replace").splitlines():
            k, _, v = line.partition("\t")
            status[k] = v
    items = []
    for f in sorted(d.glob("*.txt")):
        if f.name in SKIP:
            continue
        fbid, entries = parse(f.read_text(encoding="utf-8", errors="replace"))
        stem_bid = f.name.split(".")[0].upper()
        want = fbid or (stem_bid if re.fullmatch(r"[0-9A-F]{16}", stem_bid) else "")
        ok = not want or not bid or want == bid
        s = src.get(f.name) or {"from": "player"}
        if not ok and s.get("from") == "library":
            continue   # 公开库里别的版本（没解过包时各版本都取了）：不列；玩家导入的版本不对照列、写原因
        for name, master, _, fixed in entries:
            if master:
                continue
            key = f"{f.name}/{name}"
            items.append(dict(key=key, file=f.name, name=name, enabled=key in enabled, status=STATUS.get(status.get(key, ""), status.get(key, "")),
                              **{"from": s.get("from", "player")}, repo=s.get("repo", ""), author=s.get("author", ""), license=s.get("license", ""),
                              ok=ok, fixed=fixed, reason="" if ok else f"版本不对：金手指是 {want}，这份游戏是 {bid}。"))
    return dict(items=items, reason="" if items else "这个版本没有现成的金手指。")


def save(c, game, want):
    """开关 {键「文件名/条目名」: 真 / 假} → cheats/enabled.txt（Cheats.cs 每秒看改动时间重载，游戏运行中也即时生效）"""
    if not isinstance(want, dict) or not all(isinstance(v, bool) for v in want.values()):
        raise Failure("金手指开关格式不对。", code="job_failed")
    d = cheats_dir(c, game["id"].upper())
    known = {it["key"] for it in listing(c, game)["items"]}
    p = d / "enabled.txt"
    on = set(p.read_text(encoding="utf-8").splitlines()) - {""} if p.is_file() else set()
    for k, v in want.items():
        if k not in known:
            raise Failure("没有这条金手指：%s。" % k, code="job_failed")
        (on.add if v else on.discard)(k)
    atomic_text(p, "".join(k + "\n" for k in sorted(on)))


# 崩了能恢复（11-13 维护者改定：金手指 / 补丁是玩家主动开的，开局前不再问；崩了就关掉、下次进来告诉玩家关了什么，想用去设置里再开）：
#   开着金手指 / 画面补丁时游戏异常退出（build.py launch 调）→ 当场把开着的这几条关掉，记在 cheats/crashed.json；
#   下次开始这款时启动器读记录弹一条通知（不拦开局），读完清掉（answer_crash ack）
def note_crash(c, game):
    gid = game["id"].upper()
    d = cheats_dir(c, gid, create=False)
    keys = sorted(set((d / "enabled.txt").read_text(encoding="utf-8").splitlines()) - {""}) if (d / "enabled.txt").is_file() else []
    import community
    data = community.load_launch(c, gid)
    # 开着的补丁：11-13 起没选过 = 默认开，所以按包里编进去的、玩家没关过的算（不只是 launch.json 里写了 True 的）
    patches = sorted(it["id"] for it in community.packed_patches(c, gid) if data["patches"].get(it["id"]) is not False)
    if not (keys or patches):
        return
    known = {it["key"] for it in listing(c, game)["items"]}
    if keys:
        save(c, game, {k: False for k in keys if k in known})
    if patches:
        for k in patches:
            data["patches"][k] = False
        atomic(community.launch_path(c, gid), data)
    d.mkdir(parents=True, exist_ok=True)
    atomic(d / "crashed.json", {"cheats": keys, "patches": patches, "at": int(time.time()), "off": True})


def crashed(c, game):
    """→ [{kind: cheat | patch, key, name}]：上次异常退出时开着、已经关掉的几条；没记录 = []"""
    r = read(cheats_dir(c, game["id"].upper(), create=False) / "crashed.json", {}) or {}
    labels = {it["id"]: it["label"] for it in __import__("community").packed_patches(c, game["id"].upper())} if r.get("patches") else {}
    return [dict(kind="cheat", key=k, name=k.split("/", 1)[-1]) for k in r.get("cheats", [])] + \
           [dict(kind="patch", key=k, name=labels.get(k, k)) for k in r.get("patches", [])]


def answer_crash(c, game, choice):
    """玩家看过通知（ack）：清掉记录。开关已在 note_crash 当场关了，这里不再动"""
    if choice != "ack":
        raise Failure("回答不对。", code="job_failed")
    (cheats_dir(c, game["id"].upper(), create=False) / "crashed.json").unlink(missing_ok=True)
