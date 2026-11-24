"""每款各部分大小 + 存储总览（游戏库结构 v3 P4「查」）。

每款大小记在这款的 game.json 里：sizes = {imageMac, imageIos, saves, cache, sources}（字节）。只在出包 / 打 iPhone 包 / 删除 / 清缓存 /
释放空间 / 移动之后量这一款并写回（refresh），catalog 只读不量；没量过的款由 storageOverview（玩家打开总览时）补量一次。
  imageMac  games/<名>/image/mac
  imageIos  games/<名>/image/ios（容器件 + 资源包）
  saves     games/<名>/saves + save-backups
  cache     games/<名>/build（含 iPhone 出包工作目录 build/ios）+ shader-cache
  sources   这款引用的原件：同一份原件（按 sha256）只算一次；被 n 款引用的原件每款记 大小 // n（各款加起来等于原件大小，不重复算）。
            大小用导入时记的（catalog packages[].size：原件只读、按 sha256 认），不量盘、catalog 每次现算（for_catalog），删了一款，和它共用原件的别款跟着变
量法同 library.disk_bytes：按 (卷, inode) 去重、不跟软链；一款的各部分共用一份去重状态（#329），硬链接与 APFS 克隆族的共享块跨部分只算一次，
记在先量的部分（cache → imageMac → imageIos → saves），四项相加就是这款真占的盘。Windows（NTFS 无克隆，硬链接照样去重）照实算。
"""
from __future__ import annotations
import os
import shutil
from pathlib import Path

import layout
from core import read

PARTS = ("imageMac", "imageIos", "saves", "cache", "sources")


def _bytes(paths, skip_under=(), state=None):
    """这些路径的实占字节（按所在卷分组交 disk_bytes；skip_under 下的克隆目录不算）"""
    from library import CLONED_DIRS, disk_bytes
    by_dev = {}
    for p in paths:
        try:
            by_dev.setdefault(Path(p).lstat().st_dev, []).append(p)
        except OSError:
            pass
    skip = [os.fspath(u) for u in skip_under]
    return sum(disk_bytes(v, dev, skip_names=CLONED_DIRS if skip else (), skip_under=skip, state=state) for dev, v in by_dev.items())


def _source_share(gid, games):
    """这款引用的原件（sha256 去重）按引用款数均摊后的字节。用导入时记的大小：原件只读、按 sha256 认，记的就是它的大小，不用量（外接盘没插也算得出）"""
    refs = {}
    for g in games:
        for sha in {p.get("sha256") for p in g.get("packages", []) if p.get("sha256")}:
            refs[sha] = refs.get(sha, 0) + 1
    mine = next((g for g in games if g.get("id", "").upper() == gid), None)
    return sum(int(p.get("size") or 0) // max(1, refs.get(sha, 1))
               for sha, p in {p["sha256"]: p for p in (mine or {}).get("packages", []) if p.get("sha256")}.items())


def measure(c, gid, games=None, with_categories=True):
    """量这一款的各部分（字节）；没有文件夹的部分为 0。with_categories=False：不量 0.6.0 四类（总览自己按全库同一份去重状态量）"""
    gid = gid.upper()
    if games is None:
        games = read(c.library / "catalog.json", {}).get("games", [])
    d = layout.find_game(c, gid)
    sizes = dict.fromkeys(PARTS, 0)
    if d is not None:
        # 各部分共用一份去重状态（#329）：硬链接、APFS 克隆族跨部分只算一次，记在先量的部分——cache（解包、产物根）先量，镜像里和它同族的块
        #   只记镜像独占的；解包删了，镜像先碰到就记在镜像。四项相加 = 这款真占的盘（原先按目录名跳过 romfs 的近似口径去掉）
        state = {}
        from library import _build_entries
        sizes["cache"] = _bytes([*_build_entries(c, gid), d / "shader-cache"], state=state)   # iPhone 出包日志 build/ios/logs 不算（释放空间的保留项）
        sizes["imageMac"] = _bytes([d / "image" / "mac"], state=state)
        sizes["imageIos"] = _bytes([d / "image" / "ios"], state=state)
        sizes["saves"] = _bytes(layout.save_entries(d), state=state)   # 存档类唯一来源（含 save_backup/、SaveData*）
    sizes["sources"] = _source_share(gid, games)
    if with_categories:   # 0.6.0 四类
        sizes["categories"] = categories(c, gid, d)
    return sizes


# 0.6.0 空间页四类（体系文档 K 项，挂通用壳开关：开着才随 sizes 带 categories，两端启动器见到它就按四类显示，关着照旧五项）。按「删了会怎样」分：
#   resources   资源：image/（Mac 运行版本、iPhone 资源包、Apple TV 派生件）+ 自签导出文件夹里这款的 .img（完整包与着色器更新包，按头里的游戏号认）——删了要重新准备 / 重新导出
#   programs    程序：程序常驻 .programs/<号>（原始程序与配方）+ 工具缓存里这款的程序缓存 cache/programs/<号>——缓存删了按配方现建，常驻删了要重出 iPhone 包
#   playerData  玩家数据：存档类（layout.save_entries）+ 金手指 / mod / 设置等这款文件夹里其余没归类的（宁可多算进玩家数据，不让玩家误以为能随便删）
#   cache       缓存：出包工作目录、运行时着色器缓存、这款的直连 / 编译缓存（不含各款共用的）、诊断与收回的程序——删了下次用到时现建
#   四类共用一份去重状态，量的顺序 resources → programs → playerData → cache：克隆 / 硬链接共享的块记在资源上（玩家看到资源是真大小，缓存只记它独占的）
CATEGORIES = ("resources", "programs", "playerData", "cache")
CACHE_NAMES = ("build", "shader-cache", "direct-cache", "aoc-cache", ".work-tmp", "seen", "nro_kept", "diagrun", "downstream")   # 这款文件夹里归缓存的各项（出包工作目录不在这款文件夹的由 _build_entries 给出）


def export_files(c, gid):
    """自签导出文件夹（两种界面语言的名字都看）里属于这一款的 .img：完整包与着色器更新包"""
    import install
    out = []
    for name in install.EXPORT_DIRS.values():
        folder = c.library / name
        if folder.is_dir():
            out += [p for p in layout.entries(folder, "*.img") if p.is_file() and install._img_head(p)[0] == gid.upper()]
    return out


def categories(c, gid, d=None, state=None):
    """这一款的四类（字节）；没有文件夹 → 四类 0。state：总览一次量全库时传同一份去重状态（各款与公共件之间也只算一次）"""
    import programs
    from library import _build_entries, game_caches
    gid = gid.upper()
    d = d if d is not None else layout.find_game(c, gid)
    out = dict.fromkeys(CATEGORIES, 0)
    if d is None:
        return out
    shared = {c.work_root / "cache" / "air", c.work_root / "cache" / "pso", c.work_root / "run" / "gal_dl_cache"}   # 各款共用的编库缓存：不归任何一款
    res = [d / "image", *export_files(c, gid)]
    prog = [layout.program_store(c, gid), programs.cache(c, gid)]
    cache = [*_build_entries(c, gid), *(d / n for n in CACHE_NAMES), *(p for p in game_caches(c, gid) if p not in shared)]   # 整个 build（含出包日志）也在：与 _build_entries 重叠的去重只算一次
    named = {d / "image", *(d / n for n in CACHE_NAMES)}
    try:
        rest = [p for p in d.iterdir() if p not in named]
    except OSError:
        rest = []
    # 玩家自己导入的客体着色器缓存（启动器「导入着色器缓存」→ <私有目录>/着色器缓存/<程序号>，出包时并入；docs/客体着色器缓存导入.md）：
    #   玩家带来的、删了现建不回来，不是运行时缓存（游戏文件夹 shader-cache/ 才是，玩的时候自己长）→ 归这款的「玩家数据」
    rest.append(c.private / "着色器缓存" / gid)
    state = {} if state is None else state
    for k, paths in (("resources", res), ("programs", prog), ("playerData", rest), ("cache", cache)):
        out[k] = _bytes([p for p in paths if os.path.lexists(p)], state=state)
    return out


def refresh(c, gid):
    """量这一款并写回 game.json（作业收尾调）。量不出来不影响作业结果，返回 None"""
    try:
        sizes = measure(c, gid)
        return sizes if layout.write_sizes(c, gid, sizes) else None
    except (OSError, ValueError, TypeError, KeyError):
        return None


def for_catalog(c, gid, games):
    """catalog 每款回的 sizes：目录类四项读 game.json 记的（不量盘；没量过 measured=False、四项为 0），原件按清单现算（不量盘，删 / 导入别款后均摊跟着对）"""
    saved = layout.read_sizes(c, gid) or {}
    out = {k: int(saved.get(k) or 0) for k in PARTS}
    out["sources"] = _source_share(gid.upper(), games)
    out["measured"] = bool(saved)
    if isinstance(saved.get("categories"), dict):
        out["categories"] = {k: int(saved["categories"].get(k) or 0) for k in CATEGORIES}
    return out


# ---- 存储总览（storageOverview 作业）----
# 公共件的位置（P3 把引擎副本、日志、工具缓存挪进默认位置之前的旧位置照样算进来；挪完旧位置不存在，不会重复算）：
#   hosts     <默认位置>/hosts（Mac 宿主、iPhone 壳、引擎副本）+ <私有目录>/engines（引擎副本旧位置）
#   ipa       <默认位置>/S2Arm.ipa、S2Arm.previous.ipa
#   toolCache <默认位置>/tool-cache + 工作目录 cache/、run/（跨游戏工具缓存、按程序号的翻译 / 直连缓存）
#   temp      各存放位置的 temp/
#   logs      <默认位置>/logs + <私有目录>/logs、jobs（任务日志与记录）
SHARED = ("hosts", "ipa", "toolCache", "temp", "logs")
# 0.6.0（通用壳开关开着）再加两项，让「各款四类 + 公共件」加起来等于存放位置里 S2Arm 真占的（体系文档 K：差 < 1%）：
#   exports   两个导出文件夹里不归任何一款的（S2Arm.ipa、Apple TV 安装包、说明）——归某款的 .img 已算进那款的资源
#   other     默认位置根下其余（游戏库清单、迁移记录、锁、回收站中转、存档事务……）
SHARED_060 = ("exports", "other")


def _outermost(paths):
    """去重并去掉被列表里别的路径包含的（按绝对路径比，不跟链接）"""
    out = []
    for p in dict.fromkeys(Path(os.path.abspath(x)) for x in paths):
        if not any(p.is_relative_to(q) for q in out):
            out = [q for q in out if not q.is_relative_to(p)] + [p]
    return out


def _shared_paths(c):
    L, P, W = c.library, c.private, c.work_root
    temps = [root / "temp" for _, root, ok in layout.locations(c) if ok]
    return {
        "hosts": [L / "hosts", P / "engines.noindex", P / "engines"],   # 私有目录：建库前的引擎副本 + 没清完的旧位置
        "ipa": [layout.phone_ipa(c), layout.phone_ipa(c, previous=True)],
        # tool-cache 就是现在的工作目录（core.Context.work_root），旧位置（私有目录 / 库内 .s2arm-work 的 cache、run）没迁完时也算；
        #   去掉落在别项里面的，免得同一份量两遍（Windows 实跑：W = L/tool-cache 时总览报成两倍）
        #   <私有目录>/tools 是「准备引擎工具」按源码身份编出的读取工具（toolchain.reader），同属跨游戏工具缓存；漏算时外接盘 3 款实测总览少 7.9%
        "toolCache": _outermost([L / "tool-cache", W / "cache", W / "run", P / "cache", P / "run", P / "tools", L / ".s2arm-work" / "cache", L / ".s2arm-work" / "run"]),
        "temp": temps,
        "logs": [L / "logs", P / "logs", P / "jobs"],
    }


def _shared_paths_060(c, games, base):
    """0.6.0 多出的两项公共件（见 SHARED_060）；base = 已有公共件的路径（other 不重复算它们）"""
    import install
    import tvos
    L = c.library
    mine = {p for g in games for p in export_files(c, g["id"])}
    folders = [L / n for n in (*install.EXPORT_DIRS.values(), *tvos.TV_EXPORT_DIRS.values())]
    exports = [p for f in folders if f.is_dir() for p in f.iterdir() if p not in mine]
    known = {Path(os.path.abspath(p)) for v in base.values() for p in v} | {Path(os.path.abspath(f)) for f in folders} | {L / "games", L / "sources"}
    try:
        other = [p for p in L.iterdir() if Path(os.path.abspath(p)) not in known]
    except OSError:
        other = []
    return {"exports": exports, "other": other}


def overview(c):
    """各存放位置的卷总量 / 剩余与 S2Arm 在那里占的（各款四项 + temp/ + sources/），公共件各占多少，每款 sizes。
    没量过的款这里补量一次并写回（玩家打开总览才量，catalog 不量）"""
    from library import _volume, game_custom
    c.require_library()
    c.begin("统计游戏库占用的空间")
    games = [g for g in c.catalog()["games"] if not g.get("hidden")]
    state = {}   # 各款四类与公共件同一份去重状态现量一遍，加起来就是盘上真占的（体系文档 K）
    rows, used = [], {}
    for g in games:
        c.check()
        gid = g["id"].upper()
        where, place = layout.state(c, gid)
        if where == "ok":
            sizes = measure(c, gid, games, with_categories=False)
            sizes["categories"] = categories(c, gid, layout.find_game(c, gid), state=state)
            layout.write_sizes(c, gid, sizes)
        s = for_catalog(c, gid, games)
        root = place.parent.parent if where == "ok" else place
        if where == "ok":
            used[str(root)] = used.get(str(root), 0) + (sum(s["categories"].values()) if "categories" in s
                                                        else sum(s[k] for k in ("imageMac", "imageIos", "saves", "cache")))
        rows.append(dict(gameId=gid, name=game_custom(c, gid)["name"] or g.get("name") or gid, state=where,
                         location=str(root) if root else "", sizes=s))
    shared, under = [], {}
    paths = _shared_paths(c)
    paths.update(_shared_paths_060(c, games, paths))
    for k, v in paths.items():
        n = 0
        for p in (p for p in v if os.path.lexists(p)):
            b = _bytes([p], state=state); n += b
            for _, root, ok in layout.locations(c):
                if ok and p.is_relative_to(root):
                    under[str(root)] = under.get(str(root), 0) + b
        shared.append(dict(id=k, bytes=n))
    locations = []
    for lid, root, ok in layout.locations(c):
        row = dict(id=lid, path=str(root), volume=_volume(root), connected=ok, default=root == c.library)
        if ok:   # usedBytes = S2Arm 在这个位置里占的：各款四项 + 原件副本 sources/ + 放在这里的公共件（默认位置的 hosts/、S2Arm.ipa、temp/…）
            disk = shutil.disk_usage(root)
            row.update(totalBytes=disk.total, freeBytes=disk.free,
                       usedBytes=used.get(str(root), 0) + _bytes([root / "sources"], state=state) + under.get(str(root), 0))
        locations.append(row)
    return dict(locations=locations, shared=shared, games=rows)
