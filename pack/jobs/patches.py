"""社区补丁与金手指（帧率 / 画幅 / 画面 / 金手指，11-12 维护者：「库里的金手指、帧率、画幅都是经过验证的，玩家想用就给他打开，崩了再恢复不打开不就行」）：
出包时（解包之后、改写之前，各模块真构建号已知）向我们的下载站要这一款的统一包，条目写进私有缓存，生成 pack/cpatch.py 认的 INDEX.tsv，
交改写阶段 S2A_CPATCH_DIRS 编成「双路 + 槽」进包；金手指交 pack/jobs/cheats.py 写进金手指一栏。全部列出、全部默认关，玩家在「启动设置」里开。
  · 统一包（11-13 维护者：由我们的下载站分发、长期跟踪上游，上线后 README 致谢与来源说明）：我方 tools/patch_pack.py 从各上游整理，
    dl.s2arm.com/patches/v2/index.json（在册的包与 sha256）+ g/<程序号>.json.gz（这款的）+ b/<主程序构建号前 16 位>.json.gz（只认构建号的）。
    条目字节与上游原文件一致（编号按内容算），带来源库 / 提交号 / 原路径 / 作者 / 许可。
  · 本地优先、云端兜底（11-13 维护者）：启动器自带完整快照（<资源>/CommunityPatches/patches-v2.tar）；每次出包现取云端清单，
    只比这一款的包，本地没有 / 旧了就增量下这一个；云端取不到就用本地。来源可换：S2A_PATCH_BASE（目录或网址）、S2A_PATCH_SNAPSHOT（快照文件）。
  · 管线种子（kind = cat = pso，11-13 维护者定：我方真跑记下的管线、放补丁包、按程序号取）：不进改写阶段，
    落到私有缓存 games/<程序号>/pso/，交 S2A_PSO_SOURCES_EXTRA 给管线种子阶段（graphics/tools/direct/run_knowledge.py 排在本机来源之后），
    出成随包 pso_manifest.tsv，首局加载页后台预建；别的版本的行按本包直连库的键滤掉（pso_seed.py）。
  · 任何一步失败都静默跳过（记 stderr），不挡出包。仓库与安装包不放补丁字节。"""
from __future__ import annotations

import base64
import gzip
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

BASE = "https://dl.s2arm.com/patches/v2"
TIMEOUT = 10
MAX_BYTES = 4 << 20
UA = "S2Arm-patches"
FIELDS = {"fps": "target_fps", "widescreen": "aspect", "gfx": None}


def module_bids(exefs):
    """解包目录 exefs 里各模块（main / sdk / subsdk*）的构建号（大写全长十六进制，NSO 头 0x40 起 32 字节）"""
    out = {}
    for f in sorted(os.listdir(exefs)) if os.path.isdir(exefs) else []:
        p = os.path.join(exefs, f)
        if f.endswith(".npdm") or f == "rtld" or not os.path.isfile(p):
            continue
        with open(p, "rb") as h:
            if h.read(4) != b"NSO0":
                continue
            h.seek(0x40)
            out[f] = h.read(32).hex().upper()
    return out


def _get(url):
    if url.startswith("/") or url.startswith("file:"):
        return Path(url[5:] if url.startswith("file:") else url).read_bytes()
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = r.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("太大")
    return data


def _base():
    return (os.environ.get("S2A_PATCH_BASE") or BASE).rstrip("/")


def _snapshot_path(c):
    """随启动器安装的完整快照（11-13 维护者：补丁库随启动器装在本地、云端兜底）：<启动器资源>/CommunityPatches/patches-v2.tar
    （launchers/macos/build_app.py、launchers/windows/bundle_win.py 经 tools/patch_pack.py stage_snapshot 放进去）；S2A_PATCH_SNAPSHOT 可指别处（单测）"""
    e = os.environ.get("S2A_PATCH_SNAPSHOT")
    if e:
        return Path(e)
    r = getattr(c, "r", None) or {}
    return Path(r.get("resources") or c.private) / "CommunityPatches" / "patches-v2.tar"


def _snapshot(c):
    """→ (清单 bundles, 取包函数) ；没有快照 / 读不了 = ({}, None)"""
    import tarfile
    p = _snapshot_path(c)
    if not p.is_file():
        return {}, None
    def fetch(key):   # 每次取包开一次、用完即关（不让快照句柄挂到进程结束）
        with tarfile.open(p) as t:
            return t.extractfile(key + ".json.gz").read()
    try:
        with tarfile.open(p) as t:
            index = json.load(t.extractfile("index.json"))
        return index.get("bundles", {}), fetch
    except (OSError, KeyError, ValueError, tarfile.TarError) as e:
        print(f"补丁：本地快照读不了（{type(e).__name__}），只用云端", file=sys.stderr)
        return {}, None


def cloud_manifest():
    """云端清单（每次出包现取，同下载站 index.json）→ bundles；取不到 = None（离线 / 下载站不通：只用本地）"""
    try:
        d = json.loads(_get(_base() + "/index.json"))
        return d.get("bundles", {}) if d.get("schema") == 2 else None
    except Exception as e:
        print(f"补丁清单：云端没取到（{type(e).__name__}），用本地", file=sys.stderr)
        return None


def bundle(c, key, cloud, snap, snap_get):
    """这一款的一个包 → 条目列表。本地优先、云端兜底（11-13 维护者）：
      云端取得到：以云端清单为准——本地（之前增量下过的 / 随启动器装的快照）有同 sha256 的直接用，没有才下这一个包（增量），下好存进私有缓存；
                  云端清单里已经没有这个包（上游删了）= 不用；
      云端取不到：用本地已有的（增量下过的优先，其次快照）。核不过 sha256 的一律不用"""
    cache = Path(c.private) / "community-cache" / "v2"
    p = cache / (key + ".json.gz")
    have = p.read_bytes() if p.is_file() else None
    if cloud is not None:
        want = (cloud.get(key) or {}).get("sha256")
        if not want:
            return []
        data = None
        if have is not None and hashlib.sha256(have).hexdigest() == want:
            data = have
        elif snap_get and (snap.get(key) or {}).get("sha256") == want:
            data = snap_get(key)
        else:
            try:
                got = _get(f"{_base()}/{key}.json.gz")
            except Exception as e:
                print(f"补丁：{key} 没取到（{type(e).__name__}）", file=sys.stderr)
                got = None
            if got is not None and hashlib.sha256(got).hexdigest() == want:
                p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(got); data = got
                print(f"补丁：{key} 云端有更新，已增量下载（{len(got)} 字节）", file=sys.stderr)
            elif got is not None:
                print(f"补丁：{key} 内容与云端清单不符，不收", file=sys.stderr)
        if data is None:
            return []
    else:
        sw = (snap.get(key) or {}).get("sha256")
        data = have if have is not None else (snap_get(key) if snap_get and sw else None)
        if data is None or (data is not have and hashlib.sha256(data).hexdigest() != sw):
            return []
    try:
        return json.loads(gzip.decompress(data)).get("items", [])
    except (OSError, ValueError):
        return []


_MANIFEST = {}


def version_key(c, gid, main_bid=""):
    """这款在补丁库里的包版本（老游戏补 S 级优化的记号用，pack/jobs/rewrite_refresh.py sgrade_key）：按程序号的包 + 按主程序构建号的包各自的 sha256
    （云端清单优先，取不到用随启动器装的快照）。云端清单一个进程只取一次（一次更新核几十款不重复请求）"""
    if "cloud" not in _MANIFEST:
        _MANIFEST["cloud"] = cloud_manifest()
    cloud = _MANIFEST["cloud"]
    snap, _ = _snapshot(c)
    keys = [f"g/{gid.upper()}"] + ([f"b/{main_bid[:16].upper()}"] if len(main_bid) >= 16 else [])
    src = cloud if cloud is not None else snap
    return hashlib.sha256("|".join(f"{k}={(src.get(k) or {}).get('sha256', '')}" for k in keys).encode()).hexdigest()[:12]


def has_match(c, gid, main_bid=""):
    """游戏库列表的金色 S（v0.4.0）：随启动器装的补丁库快照里有这款的包（按程序号 / 主程序构建号）且条目数 > 0。只看本地、不联网（列表不等网络）"""
    if "snap" not in _MANIFEST:   # 快照清单一个进程只读一次（游戏库列表每款都问）
        _MANIFEST["snap"] = _snapshot(c)[0]
    snap = _MANIFEST["snap"]
    keys = [f"g/{gid.upper()}"] + ([f"b/{main_bid[:16].upper()}"] if len(main_bid) >= 16 else [])
    return any((snap.get(k) or {}).get("items", 0) > 0 for k in keys)


def items_for(c, gid, main_bid):
    """这款的条目：按程序号的包 + 按主程序构建号的包（没写程序号、只认构建号的；sdk 等公共模块不按它认：各游戏同一份二进制，
    按它认会串款，11-12 实测暗黑 3 的 sdk 认上古惑狼赛车的帧率补丁）。每条核内容 sha256，对不上的不收"""
    keys = [f"g/{gid.upper()}"] + ([f"b/{main_bid[:16].upper()}"] if len(main_bid) >= 16 else [])
    cloud = cloud_manifest()
    snap, snap_get = _snapshot(c)
    out = []
    for k in keys:
        for it in bundle(c, k, cloud, snap, snap_get):
            try:
                data = base64.b64decode(it.get("data", ""), validate=True)
            except ValueError:
                continue
            if hashlib.sha256(data).hexdigest() == it.get("sha256"):
                out.append((it, data))
    return out


def cheat_rows(c, gid, bids):
    """这款的金手指（各金手指库与补丁库附带的 cheats/<构建号>.txt）：→ [(构建号前 16 位, 文本, 来源库, 作者, 许可, 原路径)]；bids 空 = 各版本都取"""
    main = next(iter(bids), "") if bids else ""
    out = []
    for it, data in items_for(c, gid, main):
        if it.get("kind") != "cheat" or not it.get("bids"):
            continue
        bid = it["bids"][0][:16].upper()
        if bids and bid not in bids:
            continue
        src = it.get("source") or {}
        out.append((bid, data.decode("utf-8", "replace"), src.get("repo", ""), it.get("author", ""), it.get("license", ""), src.get("path", "")))
    return out


def fetch(c, game, exefs, target="mac"):
    """→ 交 S2A_CPATCH_DIRS 的索引目录列表（每类一个：fps / widescreen / gfx）；什么都没取到 = []。
    target = "ios" 时不带画面类（gfx）：11-13 维护者定「画面补丁 iOS 不进包、Mac 进包」。画面类多是主机模式分辨率（1080p / 4K 底座），
    手机上用不着，还和满屏补丁改同一处（渲染分辨率）——一起进包时改写器只收先排到的一份，满屏补丁整批被挤掉（暗黑三实测 9 份满屏全落选）"""
    gid = game["id"].upper()
    cache = Path(c.private) / "community-cache"
    bids = module_bids(exefs)
    rows = [x for x in items_for(c, gid, bids.get("main", "")) if x[0].get("kind") != "cheat"] if bids else []   # 金手指走 pack/jobs/cheats.py
    seeds = [x for x in rows if x[0].get("kind") == "pso"]; rows = [x for x in rows if x[0].get("kind") != "pso"]
    pso_write(cache / "games" / gid / "pso", seeds)
    if target == "ios":
        rows = [x for x in rows if (x[0].get("cat") if x[0].get("cat") in FIELDS else "gfx") != "gfx"]
    out = {}
    for it, data in rows:
        cat = it.get("cat") if it.get("cat") in FIELDS else "gfx"
        # 在索引目录之内（pack/cpatch.py 拒收逃出索引目录的路径）；按内容哈希分目录、只留原文件名（IPS / FPSLocker 靠文件名认构建号）——
        #   照上游原路径摆会撞 Windows 260 字符路径上限（11-12 Windows 出包机实测：上游路径带游戏名与长目录名）
        name = os.path.basename(it.get("name") or "") or "patch"
        local = cache / "games" / gid / cat / "files" / it["sha256"][:12] / name
        if not (local.is_file() and local.read_bytes() == data):
            local.parent.mkdir(parents=True, exist_ok=True)
            local.write_bytes(data)
        out.setdefault(cat, []).append((it, local))
    dirs = []
    for cat, got in sorted(out.items()):
        d = cache / "games" / gid / cat
        d.mkdir(parents=True, exist_ok=True)
        col = FIELDS[cat]
        # origin：上游原路径（本机缓存按哈希分目录、路径里不再有画幅写法；pack/cpatch.py adapt_families 按它认「同一模板按画幅生成的一族」）
        head = ["game", "title_id", "path", "type", "source", "license", "in_pack", "sha256"] + ([col] if col else []) + ["origin"]
        lines = ["\t".join(head)]
        for it, local in got:
            src = it.get("source") or {}
            vals = ["", gid, os.path.relpath(local, d), it["kind"], src.get("repo", ""), it.get("license", ""), "yes", it["sha256"]] + ([it.get(col, "")] if col else []) \
                + [src.get("repo", "") + "/" + src.get("path", "") + ("/" + src["member"] if src.get("member") else "")]
            lines.append("\t".join(str(v).replace("\t", " ") for v in vals))
        (d / "INDEX.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
        dirs.append(str(d))
    if rows:
        print(f"补丁：{gid} 统一包 {len(rows)} 份（{'、'.join(f'{k} {len(v)}' for k, v in sorted(out.items()))}）", file=sys.stderr)
    return dirs


def pso_write(d, seeds):
    """管线种子条目 → d/<条目编号>.tsv；每次整目录重写（上游撤掉的种子不留旧文件）"""
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    for it, data in seeds:
        d.mkdir(parents=True, exist_ok=True)
        (d / (it["sha256"][:16] + ".tsv")).write_bytes(data)
    if seeds:
        print(f"补丁：管线种子 {len(seeds)} 份", file=sys.stderr)


def pso_dir(c, game):
    """fetch 落下的这款管线种子目录；没有种子 = None"""
    d = Path(c.private) / "community-cache" / "games" / game["id"].upper() / "pso"
    return str(d) if d.is_dir() and any(d.glob("*.tsv")) else None


def prepare(c, game, extraction, env, target="mac"):
    """出包作业在解包之后、改写之前调（build.prepare：Mac / ipa.build：target="ios"）：金手指与补丁都按真构建号查库，结果交改写阶段的环境变量。
    出包页「S 级优化（Beta）」取消勾选（请求 sgrade = false，v0.4.0 维护者：缺省勾上、玩家可取消）= 这次出包不带社区补丁与金手指（原生方案）：
    不查库、改写阶段整体不编（S2A_CPATCH=none，pack/stage_rewrite.sh 也不再从本机补丁库目录兜底）；管线种子不是社区补丁，照带"""
    off = (getattr(c, "r", None) or {}).get("sgrade") is False
    try:   # 记下这款这次出包的选择：老游戏补 S 级优化（pack/jobs/rewrite_refresh.py）按它决定补不补
        import layout
        layout.update_info(c, game["id"].upper(), sgradeOff=off)
    except Exception:
        pass
    if off:
        env["S2A_CPATCH"] = "none"; env.pop("S2A_CPATCH_DIRS", None); env.pop("S2A_CHEATS_DIRS", None)
        seed = pso_dir(c, game)
        if seed:
            env["S2A_PSO_SOURCES_EXTRA"] = seed
        print("补丁：出包页取消了 S 级优化，这次不带社区补丁与金手指", file=sys.stderr)
        return
    import cheats
    try:
        cheats.fetch(c, game)
        d = cheats.cheats_dir(c, game["id"].upper(), create=False)
        if d.is_dir() and any(f.name not in cheats.SKIP for f in d.glob("*.txt")):
            env["S2A_CHEATS_DIRS"] = str(d)
        dirs = fetch(c, game, os.path.join(str(extraction), "exefs"), target)
        seed = pso_dir(c, game)
        if seed:
            env["S2A_PSO_SOURCES_EXTRA"] = seed
    except Exception as e:   # 查库是附加：任何意外都不挡出包
        print(f"【黄】金手指 / 补丁查库出错，这次不带：{type(e).__name__}: {e}", file=sys.stderr)
        return
    if dirs:
        env["S2A_CPATCH_DIRS"] = os.pathsep.join([x for x in env.get("S2A_CPATCH_DIRS", "").split(os.pathsep) if x] + dirs)   # Windows 路径带盘符冒号：按系统分隔符


def boost(c, game, image):
    """出包结果里「这次自动配好了什么」（完成页的 S 级加强动效与清单，11-12 维护者：「补丁自动打入，玩家开不开是玩家的事，咱都给配置好」）：
    → {cheats: 这个版本能开的金手指条数, fps / widescreen / gfx: 编进包的社区补丁份数}；全是 0 = 没配到，不播"""
    import cheats
    out = dict(cheats=sum(1 for it in cheats.listing(c, game)["items"] if it["ok"]), fps=0, widescreen=0, gfx=0)
    tsv = next((p for p in (Path(image) / "cpatch.tsv", Path(image) / "kit" / "cpatch.tsv") if p.is_file()), None)   # Mac 运行版本根 / iPhone kit（ship_ext 拷进去的）
    seen = set()
    for line in (tsv.read_text(encoding="utf-8", errors="replace").splitlines()[1:] if tsv else []):
        uid = line.split("\t", 1)[0]
        kind = uid.split(":", 1)[0]
        if kind == "wsauto":   # 自适应画幅一族的宽 / 窄两份算一份宽屏
            kind, uid = "widescreen", uid.rsplit(":", 1)[0]
        if kind in ("fps", "widescreen", "gfx") and uid not in seen:
            seen.add(uid); out[kind] += 1
    return out


VERSION_RE = re.compile(r"(?<![\d.])v?(\d+\.\d+(?:\.\d+){0,2})(?!\d|\.\d)")   # 后面可跟 .pchtxt（按版本号起的文件名），不能跟 .数字
CATS = ("widescreen", "fps", "gfx", "cheat")


def _version_label(it):
    """条目上游路径里写的游戏版本号（1.3.0 / v1.0.4 这类；补丁库按版本分目录或按版本起文件名）；看不出 = ''"""
    src = it.get("source") or {}
    found = VERSION_RE.findall("/".join(x for x in (src.get("path", ""), src.get("member", ""), it.get("name", "")) if x))
    return found[-1] if found else ""


def match(c):
    """出包页「S 级优化（Beta）」（11-13 维护者）：这款在补丁库里命中了什么 → {build, exact: {类: 条数}, others: [{version, cats}], total}。
    build = 实际运行的主程序构建号前 16 位（解过包才知道；没解过 = ''，exact 为空，出包时再自动匹配，完成页 boost 列实际打进去的）；
    exact = 这个版本命中的各类条数（帧率 / 满屏 / 画面 / 金手指；按构建号精确对，同 pack/cpatch.py）；
    others = 只命中游戏、版本不同的：按上游路径里的版本号归并、各支持哪几类（只告知，不给勾选：版本不对补丁原字节核不上、一个字节都不写）。
    读本地补丁库、云端增量同出包（items_for）"""
    import community
    gid = (c.r.get("gameId") or "").upper()
    game = community.game_of(c, gid)
    import cheats
    build = cheats.main_build(c, game)
    exact, others = {k: 0 for k in CATS}, {}
    for it, _ in items_for(c, gid, build):
        if it.get("kind") == "pso":   # 管线种子不是玩家可选的补丁，不列
            continue
        cat = it.get("cat") if it.get("cat") in CATS else "gfx"
        bids = [b.upper() for b in it.get("bids") or []]
        if build and any(bid_hit(build, b) for b in bids):
            exact[cat] += 1
        else:
            v = _version_label(it)   # 看不出版本号的不列（构建号对玩家没意义）
            if v:
                others.setdefault(v, set()).add(cat)
    return dict(build=build, exact=exact, total=sum(exact.values()),
                others=[dict(version=v, cats=[k for k in CATS if k in cs]) for v, cs in sorted(others.items(), key=lambda kv: [int(x) if x.isdigit() else 0 for x in re.split(r"[.]", kv[0])])])


def bid_hit(build16, theirs):
    """条目构建号与这款主程序构建号前 16 位对得上（补丁写全长或前 16 位，去尾 0 后至少 16 位，同 pack/cpatch.py bid_match 的口径）"""
    t = theirs.upper().rstrip("0")
    t = t if len(t) >= 16 else theirs.upper()[:16]
    return t[:16] == build16.upper()[:16]
