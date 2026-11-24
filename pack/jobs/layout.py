"""游戏库布局（11-09 维护者拍板「游戏库结构双端统一」，v3 起支持多个存放位置）：库里每一样东西的路径只在这里算。

  <库>/games/<英文名>/   一款一个文件夹；程序只认里面 game.json 的游戏号，不认文件夹名（玩家改名、挪动不影响）
      game.json  cover.jpg  custom.json  community.json  input.json
      image/mac/          Mac 镜像（不含宿主）          saves/  save-backups/  shader-cache/
      image/ios/          iPhone 镜像：kit/（组容器的文件）+ pack/（资源包）
      build/              出包缓存（原 cache/<号>：两平台共用的解包 + Mac 各产物根；ios/ = iPhone 一键出包工作目录）  seen/  save_backup/（iPhone 存档备份）
  <库>/hosts/mac.noindex/<宿主摘要前 12 位>/S2ArmGame.app   Mac 宿主，多款共用（只换宿主见 host_update.py）；
      目录名带 .noindex：聚焦不收录里面的 .app，菜单 / 启动台不再出一排「S2Arm Game」（#1126 / #2024）
  <默认位置>/S2Arm.ipa  S2Arm.previous.ipa  devices/<设备>.json   iPhone 装机产物与每台手机的记录（只放默认位置）
Windows 与 Mac 同一套（共用后端）。旧布局（按类型分：games/<号>/releases、cache/<号>、saves/<号>…）由 migrate() 一次性同盘改名过来，
.s2arm-layout.json 记已迁完的款，中途被杀下次接着做。
"""
from __future__ import annotations
import contextlib
import json
import os
import re
import socket
import sys
import shutil
import time
from pathlib import Path

from core import Failure, atomic, contained, read, resolve_path
from errors import library_lock_failure

VERSION = 5   # 2：每款进 games/<英文名>/；3：iPhone 产物进每款 image/ios、装机产物与设备记录进默认位置根（_upgrade_3）；4：库外的工具缓存 / 日志搬进默认位置（_upgrade_4）；
              # 5：hosts/mac → hosts/mac.noindex（_upgrade_5）
GAME_JSON = "game.json"
NAME_MAX = 48   # Windows 深路径预算：库根 + games\<名> + 镜像 / 出包缓存的深层目录要留在 260 以内（玩家路径见 pack/jobs/winenv.py 长路径检查）
_WIN_RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}
_GID = re.compile(r"[0-9A-F]{16}")


def folder_name(english, gid, taken=()):
    """游戏文件夹名：原件 NACP 的英文名清洗成安全 ASCII（字母数字、空格、- _ . ( ) &），最长 NAME_MAX；空 / Windows 保留名 → 游戏号；
    与 taken 里的名字重了（同名不同号，如不同地区版）→ 加「 [号后 4 位]」。比较不分大小写（Windows / 默认 APFS 都不分）"""
    gid = gid.upper()
    name = re.sub(r"[^A-Za-z0-9 \-_.()&]", "", english or "")
    name = re.sub(r" +", " ", name).strip(" .")[:NAME_MAX].strip(" .")
    if not name or name.split(".")[0].upper() in _WIN_RESERVED:
        name = gid
    used = {t.lower() for t in taken}
    if name.lower() in used:
        name = (name[:NAME_MAX - 7].strip(" .") + " [" + gid[-4:] + "]")
        if name.lower() in used:
            name = gid
            # #765：游戏号本身也被占时原先就回游戏号，接着 mkdir 撞 File exists；加序号找一个空名（游戏号 + 「 (2)」「 (3)」…）
            n = 2
            while name.lower() in used:
                name = f"{gid} ({n})"; n += 1
    return name


LOCATION_JSON = ".s2arm-location.json"


def games_root(c, root=None):
    return Path(root or c.library) / "games"


HOSTS_MAC = "mac.noindex"   # 聚焦跳过 .noindex 结尾的目录（#1126 / #2024）；引擎副本同理（embedded.engines_root）


def hosts_mac(c):
    return c.library / "hosts" / HOSTS_MAC   # 公共件只在默认位置（游戏库结构 v3）


# ---- 存放位置 + 索引表（游戏库结构 v3：像 Steam 的库文件夹）----
# 默认位置 = 请求里的 library（c.library），公共件（hosts/、catalog.json、iPhone 产物、全局执行锁）都在这里；玩家可以再加别的位置（别的分区、移动硬盘）。
# 索引表 <私有目录>/library-index.json：{schema, locations: [{id, path}], games: {游戏号: {location, folder}}, last}。它只是缓存，
# 真相是每个位置下 games/*/game.json；索引丢了按位置扫描重建。

def _index_path(c):
    return (getattr(c, "private", None) or c.library) / "library-index.json"


def load_index(c):
    idx = getattr(c, "_layout_idx", None)
    fresh = idx is None
    if fresh:
        idx = read(_index_path(c), {}) or {}
        idx.setdefault("schema", 1); idx.setdefault("locations", []); idx.setdefault("games", {})
        c._layout_idx = idx
    want = default_id(c)   # 默认位置总在表里、排第一；它的号以库里的标识文件为准（迁移写标识后，旧的 "default" 引用跟着改）
    old = next((l for l in idx["locations"] if l.get("path") == str(c.library)), None)
    changed = old is None or old.get("id") != want
    if changed:
        if old is not None:
            idx["locations"].remove(old)
            for e in idx["games"].values():
                if e.get("location") == old.get("id"):
                    e["location"] = want
        idx["locations"].insert(0, dict(id=want, path=str(c.library), library=True))
    elif not old.get("library"):
        old["library"] = True
    if fresh or changed:
        _drop_other_libraries(c, idx, want)
    return idx


def _drop_other_libraries(c, idx, want):
    """索引在私有目录、换过游戏库的都共用这一份：别的游戏库的根不是本库的存放位置，从表里去掉（存储总览不再列、找游戏不去那里找）。
    认法（都不含当前库）：① 和本库同号的另一行——整库搬家时位置标识跟着搬，旧路径那行留下来同号；② 记过是游戏库根（library）的行；
    ③ 那里有游戏库标识 .s2arm-library.json（v0.3.6 以前的旧表没记 library）。②③ 的位置号下的游戏记录一并去掉：那是别的库的款，
    留着会让本库导入同一款时认到别的库的文件夹、往那边写（存储总览「存放位置」一直列着换库前的 C 盘路径）。①的游戏记录本来就指向本库，不动"""
    here = str(c.library)
    # #946：上一个库根下还记着游戏（索引里有游戏指向它），就不去掉，改当一个普通存放位置留着。0.2.x 换库时没搬文件的玩家，游戏全在旧库根里，
    #   升到 v0.3.6 后整行连同游戏记录被去掉，库里所有游戏一下变成「未出包」。看不到自己的游戏比总览多列一行严重得多：有游戏的旧库根照留
    used = {e.get("location") for e in idx["games"].values()} - {want}
    stale = [l for l in idx["locations"][1:] if l.get("path") != here and
             (l.get("id") == want or ((l.get("library") or (Path(l.get("path", "")) / ".s2arm-library.json").is_file()) and l.get("id") not in used))]
    for l in idx["locations"][1:]:
        if l.get("id") in used and l.get("library") and l.get("path") != here:
            l.pop("library")   # 留下来的旧库根降成普通存放位置
    if not stale:
        return
    gone = {l.get("id") for l in stale} - {want}
    idx["locations"] = [l for l in idx["locations"] if l not in stale]
    idx["games"] = {g: e for g, e in idx["games"].items() if e.get("location") not in gone}
    if idx.get("last") in gone:
        idx.pop("last")   # 上次用的是别的库根：不再当默认（#922）


def default_id(c):
    return location_id(c.library) or "default"


def save_index(c):
    atomic(_index_path(c), load_index(c))


def location_id(root):
    return read(Path(root) / LOCATION_JSON, {}).get("id")


def register_location(c, root):
    """把一个文件夹登记成存放位置（写 .s2arm-location.json，进索引表）→ 位置号"""
    import uuid
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    lid = location_id(root)
    if not lid:
        lid = uuid.uuid4().hex
        atomic(root / LOCATION_JSON, dict(schema=1, id=lid, version=VERSION))
    idx = load_index(c)
    idx["locations"] = [l for l in idx["locations"] if l.get("path") != str(root) and l.get("id") != lid] + [dict(id=lid, path=str(root))]
    save_index(c)
    return lid


def locations(c):
    """[(位置号, 路径, 在不在)]，默认位置排第一"""
    return [(l["id"], Path(l["path"]), Path(l["path"]).is_dir()) for l in load_index(c)["locations"]]


def _location_path(c, lid):
    return next((Path(l["path"]) for l in load_index(c)["locations"] if l.get("id") == lid), None)


def _scan(root):
    out = {}
    g = games_root(None, root)
    for d in (sorted(g.iterdir()) if g.is_dir() else []):
        if d.is_symlink() or not d.is_dir():
            continue
        gid = str(read(d / GAME_JSON, {}).get("id", "")).upper()
        if _GID.fullmatch(gid) and gid not in out:
            out[gid] = d
    return out


def _remember(c, gid, d):
    idx = load_index(c)
    root = d.parent.parent
    lid = default_id(c) if root == c.library else (location_id(root) or register_location(c, root))
    if idx["games"].get(gid) != dict(location=lid, folder=d.name):
        idx["games"][gid] = dict(location=lid, folder=d.name)
        save_index(c)


def state(c, gid):
    """这款在哪 → ("ok", 文件夹) | ("offline", 位置路径)（位置没连上，如移动硬盘没插）| ("missing", 位置路径)（位置在、文件夹没了）| ("none", None)（还没建）。
    索引对不上时（玩家改了文件夹名）扫一遍这个位置再认"""
    gid = gid.upper()
    entry = load_index(c)["games"].get(gid)
    if entry:
        root = _location_path(c, entry.get("location"))
        if root is None:
            return "none", None
        if not root.is_dir():
            # 只有这个库清单里的款才算「位置没连上」：索引在私有目录、换过游戏库后还留着上一个库的记录（#432：0.2.1 建的库在 ~\S2Arm，
            #   后来换到别的盘），那个库不在了，不能拿它挡住在新库里导入同一款
            listed = {str(g.get("id", "")).upper() for g in read(c.library / "catalog.json", {}).get("games", [])}
            return ("offline", root) if gid in listed else ("none", None)
        d = games_root(c, root) / entry.get("folder", "")
        if entry.get("folder") and str(read(d / GAME_JSON, {}).get("id", "")).upper() == gid:
            return "ok", d
        found = _scan(root).get(gid)
        if found:
            _remember(c, gid, found)
            return "ok", found
        return "missing", root
    for _, root, ok in locations(c):   # 索引里没有：各位置扫一遍（旧库刚迁完 / 索引丢了）
        found = _scan(root).get(gid) if ok else None
        if found:
            _remember(c, gid, found)
            return "ok", found
    return "none", None


def find_game(c, gid):
    """这款的文件夹；还没有、位置没连上或找不到 → None"""
    st, d = state(c, gid)
    return d if st == "ok" else None


def indexed_dir(c, gid):
    """索引里记的这款文件夹，不管里面还有没有 game.json；位置没连上、没记、文件夹不在 → None。
    删游戏删到一半（某个文件删不掉）时 game.json 可能已经没了，find_game 认不出它；重试删除靠这里找回同一个文件夹（#433）"""
    entry = load_index(c)["games"].get(gid.upper())
    root = _location_path(c, entry.get("location")) if entry else None
    if not entry or not entry.get("folder") or root is None or not root.is_dir():
        return None
    d = games_root(c, root) / entry["folder"]
    other = str(read(d / GAME_JSON, {}).get("id", "") or gid).upper()   # game.json 删没了（删到一半）照认；写着别款的号就不是这款的
    if other != gid.upper():
        print(f"[s2a] {gid.upper()}：索引记的文件夹 {d.name} 是另一款 {other} 的，不当这款的删", file=sys.stderr)
        return None
    return d if d.is_dir() else None


def require_in_location(c, p):
    """路径必须在某个已登记存放位置的 games/ 下（运行镜像校验用，挡住指到库外的路径）"""
    p = resolve_path(p)
    for _, root, ok in locations(c):
        if ok and p.is_relative_to(resolve_path(games_root(c, root))):
            return p
    raise Failure("运行文件不在任何存放位置里。", code="runtime_invalid")


def root_of(c, gid):
    """这款所在存放位置的根（托管路径校验、同盘临时目录用）；还没有就是默认位置"""
    d = find_game(c, gid)
    return d.parent.parent if d else c.library


def game_dir(c, gid, english=None, location=None):
    """这款的文件夹，没有就新建（写 game.json）：建在 location（路径），缺省上次用的位置，再缺省默认位置。english 缺省取 catalog 里这款的名字"""
    gid = gid.upper()
    if not _GID.fullmatch(gid):
        raise Failure("游戏标识无效。", code="job_failed")
    st, d = state(c, gid)
    if st == "ok":
        return d
    if st == "offline":
        raise Failure(f"这款游戏所在的存放位置没连上（{d}）：插上那块盘再试。", code="job_failed")
    if english is None:
        english = next((g.get("englishName") or g.get("name") for g in read(c.library / "catalog.json", {}).get("games", []) if g.get("id", "").upper() == gid), "")
    idx = load_index(c)
    if location:   # 玩家指定的位置：没有就建
        root = Path(location)
    else:          # 上次用的位置；没连上就退回默认位置
        root = _location_path(c, idx.get("last")) or c.library
        if not root.is_dir():
            root = c.library
    if root != c.library:
        register_location(c, root)
    g = games_root(c, root)
    g.mkdir(parents=True, exist_ok=True)
    # #765（[Errno 17] File exists: games/<游戏号>，每次添加都失败）：首选名那里已有东西时，反防御处理——
    #   是这款的空壳文件夹（没有 game.json，或 game.json 就是这款：上次添加到一半留下的）→ 沿用；是文件 / 断链 → 挪开（改名 .s2a-moved-<时刻>，不删）再建；
    #   是别款的文件夹 → 按已占用的名字另取（folder_name 加号后 4 位 / 序号）
    want = g / folder_name(english, gid)
    if want.is_symlink() or (want.exists() and not want.is_dir()):   # 先挪开：断链可能指到库外，contained 会按解析后的路径判越界
        os.replace(want, want.with_name(want.name + f".s2a-moved-{time.strftime('%Y%m%d-%H%M%S')}"))
    contained(root, want)
    if want.is_dir() and str(read(want / GAME_JSON, {}).get("id", "") or gid).upper() == gid:
        d = want
    else:
        d = g / folder_name(english, gid, [p.name for p in g.iterdir()])   # 返回原样路径（不解析软链）：调用方按位置根前缀比对（library._rm）
        contained(root, d)
        try:
            d.mkdir()
        except FileExistsError:   # 列目录到建之间这个名字被占了：是这款（或没有 game.json 的空壳）就沿用，否则重新列一遍另取
            if not (d.is_dir() and not d.is_symlink() and str(read(d / GAME_JSON, {}).get("id", "") or gid).upper() == gid):
                d = g / folder_name(english, gid, [p.name for p in g.iterdir()])
                contained(root, d)
                d.mkdir()
    atomic(d / GAME_JSON, dict(schema=1, id=gid))
    _remember(c, gid, d)
    return d


def use_location(c, root):
    """记下「上次用的位置」（出包页新游戏缺省选它）"""
    lid = default_id(c) if Path(root) == c.library else (location_id(root) or register_location(c, root))
    idx = load_index(c)
    idx["last"] = lid
    save_index(c)


def move_game(c, gid, dest_root, progress=None):
    """把这款整个文件夹挪到另一个存放位置：同一卷直接改名；跨卷先拷到 <目标>/games/<名>.partial，逐文件核对大小与摘要，再换名、删旧的。存档跟着走"""
    from core import digest
    src = find_game(c, gid)
    if src is None:
        raise Failure("找不到这款游戏的文件夹，没法移动。", code="job_failed")
    dest_root = Path(dest_root)
    if src.parent.parent == dest_root:
        return src
    dest = _move_folder(c, gid, src, dest_root)
    _remember(c, gid, dest)
    return dest


def _move_folder(c, gid, src, dest_root):
    """把一个游戏文件夹搬进 <dest_root>/games/：同一卷改名；跨卷拷到 .partial（链接拷链接本身，library.copy_tree_links）、
    核对（存档逐字节、其余文件数与大小，同整库搬家 library._verify_copy）再换名、删旧的，最后把指向旧位置的链接改指新位置"""
    from library import _retarget_links, _verify_copy, copy_tree_links
    if dest_root != c.library:
        register_location(c, dest_root)
    g = games_root(c, dest_root); g.mkdir(parents=True, exist_ok=True)
    dest = g / folder_name(read(src / GAME_JSON, {}).get("name") or src.name, gid, [p.name for p in g.iterdir()]) if (g / src.name).exists() else g / src.name
    if _same_volume(src, g):
        os.replace(src, dest)
    else:
        temporary = dest.with_name(dest.name + ".partial")
        shutil.rmtree(temporary, ignore_errors=True)
        try:
            copy_tree_links(src, temporary)
            _verify_copy(src, temporary, strict=False)
            for sub in save_entries(src):   # 存档类逐字节核（唯一来源 save_entries）
                if sub.is_dir():
                    _verify_copy(sub, temporary / sub.name, strict=True)
        except Failure:
            shutil.rmtree(temporary, ignore_errors=True)
            raise Failure("拷到新位置后核对不一致，没有移动（原位置的文件都还在）。", code="job_failed")
        os.replace(temporary, dest)
        remove_tree(src)
    _retarget_links(dest, src, dest)
    return dest


def remove_tree(path):
    """删掉搬走后的旧文件夹（同 shutil.rmtree），只容忍「文件已经不在」：exFAT 等非 APFS 盘上每个文件旁有 AppleDouble 伴随文件 ._<名>，
    删本体时系统会把它一起删掉，rmtree 先列出的 ._<名> 再去删就找不到（#1720 / 诊断#5d659a：游戏已搬好、旧夹删了一半，整个任务却报失败）。
    别的错误照抛；删完旧文件夹还在也照抛"""
    path = Path(path)
    def gone(func, p, exc):
        if not isinstance(exc if isinstance(exc, BaseException) else exc[1], FileNotFoundError):
            raise exc if isinstance(exc, BaseException) else exc[1]
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=gone)
    else:
        shutil.rmtree(path, onerror=gone)
    if os.path.lexists(path):
        raise OSError(f"旧文件夹删完还在：{path}")  # 非玩家句


def _same_volume(a, b):
    return os.stat(a).st_dev == os.stat(b).st_dev


def relink(c, gid, folder):
    """「重新指定文件夹」：选到的文件夹 game.json 游戏号对得上才接受。它在某个存放位置的 games/ 里就原地认；
    在别处（玩家挪到了桌面等）就搬回这款原来的存放位置（没连上就搬到默认位置），玩家不用懂目录结构"""
    folder, gid = Path(folder), gid.upper()
    if str(read(folder / GAME_JSON, {}).get("id", "")).upper() != gid:
        raise Failure("选的文件夹不是这款游戏（里面的 game.json 游戏号对不上）。", code="job_failed")
    if folder.parent.name != "games":
        entry = load_index(c)["games"].get(gid) or {}
        home = _location_path(c, entry.get("location"))
        folder = _move_folder(c, gid, folder, home if home and home.is_dir() else c.library)
    _remember(c, gid, folder)
    return folder


def forget(c, gid):
    """「从游戏库移除」：只从索引去掉（文件不动）"""
    idx = load_index(c)
    if idx["games"].pop(gid.upper(), None) is not None:
        save_index(c)


def game_info(c, gid):
    d = find_game(c, gid)
    return read(d / GAME_JSON, {}) if d else {}


def update_info(c, gid, **fields):
    d = game_dir(c, gid)
    atomic(d / GAME_JSON, dict(read(d / GAME_JSON, {}), **fields))
    if "ios" in fields:   # 程序件的兼容记录（壳号 / 宿主约定号 / 直连链号…）同存一份到专用文件夹：游戏文件夹被删了，更新手机照样判得出能不能带这款
        atomic(program_store(c, gid, create=True) / PROGRAM_INFO, fields["ios"])


def read_sizes(c, gid):
    """game.json 里记的各部分大小（sizes.py 量、写）；没量过 / 没有文件夹 → None"""
    s = game_info(c, gid).get("sizes")
    return s if isinstance(s, dict) else None


def write_sizes(c, gid, sizes):
    """把量好的大小写回这款的 game.json；没有文件夹（删光了 / 位置没连上）不建、返回 False"""
    d = find_game(c, gid)
    if d is None:
        return False
    atomic(d / GAME_JSON, dict(read(d / GAME_JSON, {}), sizes=sizes))
    return True


def launch_json(c, gid, create=True):
    """启动设置（新功能线）：每款文件夹里的 launch.json"""
    return path(c, gid, "launch.json", create=create)


def job_tmp(c, gid, task):
    """作业临时目录 <这款所在位置>/temp/<任务号>（与游戏数据同卷，改名快；出包修复线约定的 S2A_JOB_TMP）"""
    return root_of(c, gid) / "temp" / task


def path(c, gid, *parts, create=True):
    """单款文件夹下的路径；create=False 且这款还没有文件夹时给出一个不存在的路径（读的一方按「没有」处理）"""
    d = game_dir(c, gid) if create else (find_game(c, gid) or games_root(c) / (".none-" + gid.upper()))
    return d.joinpath(*parts)


def nro_kept(c, gid, create=False):
    """运行时留下的 NRO（#8be819：游戏自有加密归档里的 NRO，出包时认不出；宿主 LoadNro 缺表时把游戏解开的那份存成 <SHA-256>.nro，
    Mac 局收局后 / 装 iPhone 前收回这里），出包改写阶段经 S2A_NRO_KEPT_DIR 读（runtime/rewriter/nro_to_nso.py 第三来源）"""
    return path(c, gid, "nro_kept", create=create)


def image_mac(c, gid, create=True):
    return path(c, gid, "image", "mac", create=create)


def build_dir(c, gid, create=True):
    return path(c, gid, "build", create=create)


# ---- iPhone 一侧（游戏库结构 v3 P2）----
# 每款 image/ios/：kit/（组容器要读的文件：随行表、main.npdm、模块镜像、随包表，ship_ext.place_game 的输入）+ pack/（资源包，推进手机 Documents）。
#   game.json 的 ios 记 {shellId 出它的壳, hostAbi, dmshChain（host_update 判兼容）, pack 资源包 index_sha256}。不再保留单款 ipa。
# 出包工作目录 build/ios（一键出包 --out）；默认位置根：S2Arm.ipa（最近一次装的）、S2Arm.previous.ipa（换壳前那一版，回滚用）；
# devices/<设备>.json：这台手机装了哪些款（各款资源包号）、壳号、包名（Windows 由 plumesign 定）、装回过上一版的壳号 failedShells。
# 资源包目录叫 .pack 且隐藏（D-9ZF9，v0.3.10 后）：里面的 game.img 不带着色器库、不能单独导入手机，玩家翻游戏库时不该看见一个「看起来能导」的 .img；
#   自签玩家要的是「S2Arm 自签导出」文件夹里以游戏名命名的 .img。旧库的 pack/ 第一次用到时改名过来（ios_pack）
IOS_KIT, IOS_PACK, LEGACY_IOS_PACK = "kit", ".pack", "pack"
PHONE_IPA, PHONE_PREVIOUS = "S2Arm.ipa", "S2Arm.previous.ipa"
DEVICES = "devices"
LEGACY_DEVICE = "legacy"   # 迁移来的旧容器记录：还不知道是哪台手机，第一台装机的设备认领它


def image_ios(c, gid, create=True):
    return path(c, gid, "image", "ios", create=create)


# ---- 游戏程序常驻（11-16 维护者：玩家打完包常删输出目录、之后不碰电脑，更新 S2Arm 时组容器要的游戏程序跟着丢了；又定「极致压缩」）----
# 默认位置根 .programs/<程序号>/：exefs.tar.zst（原始程序）、recipe.tar.zst（配方）、ios.json（程序件的兼容记录，同 game.json 的 ios）。
#   按程序号分、不在游戏文件夹里：删游戏文件夹、换存放位置删旧位置、「释放空间」都不碰它；只有「删除游戏」（library.delete）才删。
#   kit 与解开的原始程序是缓存（工具缓存 cache/programs/<程序号>），缺了按配方现建：见 pack/jobs/programs.py
PROGRAMS, PROGRAM_INFO, PROGRAM_EXEFS = ".programs", "ios.json", "original-exefs"


def program_store(c, gid, create=False):
    d = c.library / PROGRAMS / gid.upper()
    if create:
        d.mkdir(parents=True, exist_ok=True)
        hide(c.library / PROGRAMS)
    return d


def ios_kit(c, gid):
    """iPhone 程序件（组容器读）：缓存在就用、缺了按常驻配方现建（programs.kit_dir）；只问「有没有」用 has_ios_kit（不现建）"""
    import programs
    return programs.kit_dir(c, gid)


def ios_kit_present(c, gid):
    """已有的 iPhone 程序件目录（缓存 kit，或还没迁移的旧布局）→ 路径 | None。只看文件，不迁移、不现建：给游戏库清单这类只读的地方用
    （11-16：清单画金色 S 调 ios_kit，升级首启在读库里做旧布局迁移，与后台作业撞上 WinError 32，整个清单读失败）"""
    import programs
    for kit in (programs.cache(c, gid) / "kit", program_store(c, gid) / IOS_KIT, image_ios(c, gid, create=False) / IOS_KIT):
        if (kit / "main.npdm").is_file():
            return kit
    return None


def has_ios_kit(c, gid):
    """有没有 iPhone 程序件（游戏库清单每款都问：只看文件，不迁移、不现建——旧布局的迁移要压缩 + 现建对拍，留到真用程序件时做）"""
    import programs
    if programs.has_kit(c, gid):
        return True
    for kit in (program_store(c, gid) / IOS_KIT, image_ios(c, gid, create=False) / IOS_KIT):   # 还没迁移的旧布局
        try:
            if (kit / "main.npdm").stat().st_size > 0 and any(kit.glob("*.fixups.tsv")):
                return True
        except OSError:
            pass
    return False


def program_exefs(c, gid):
    """解开的原始程序目录（缓存，缺了从常驻归档解）；没有 → 不存在的路径"""
    import programs
    programs.adopt(c, gid)
    return programs.exefs_dir(c, gid) or programs.cache(c, gid) / "exefs"


def program_info(c, gid):
    """程序件的兼容记录：游戏文件夹 game.json 的 ios 优先，没有（游戏文件夹被删了）读专用文件夹的那份"""
    return game_info(c, gid).get("ios") or read(program_store(c, gid) / PROGRAM_INFO, {}) or {}


def ios_pack(c, gid):
    image = image_ios(c, gid, create=False)
    legacy, pack = image / LEGACY_IOS_PACK, image / IOS_PACK
    if legacy.is_dir() and not pack.exists():
        try:
            os.rename(legacy, pack)
            hide(pack)
        except OSError:
            # 审计 P1-183：改名失败可能是另一路（装机页轮询 / 出包）刚改完：.pack 已在就用它，不退回已经不存在的 pack/；
            #   真被占着（老位置还在）才照旧用老位置，下次再改。不加锁、不要求重新出包
            if pack.is_dir():
                return pack
            return legacy
    return pack


def hide(path):
    """Windows 上给文件夹加隐藏属性（名字带点在资源管理器里照样看得见）；Mac / Linux 名字带点已隐藏。失败不碍事"""
    if os.name != "nt":
        return
    try:
        import ctypes
        import winproc
        attrs = ctypes.windll.kernel32.GetFileAttributesW(winproc.win_path(str(path)))   # 游戏库在深目录时裸长路径会 WinError 3 / 123
        if attrs != -1 and attrs != 0xFFFFFFFF:
            ctypes.windll.kernel32.SetFileAttributesW(winproc.win_path(str(path)), attrs | 0x2)   # FILE_ATTRIBUTE_HIDDEN
    except (OSError, AttributeError):
        pass


def ios_work(c, gid, create=True):
    """一键出包的输出目录（产物根 roots/、Windows 的 work/、交付的 ipa 与资源包先落这里，收尾时搬进 image/ios）"""
    return build_dir(c, gid, create=create) / "ios"


CURRENT = "@现行"   # 产物根里的现行指针文件名后缀：<款>@现行 是普通文件，内容 = 现行版本目录名（pack/orch/current.py）  # 非玩家句
_CURRENT_MOD = {}


def _current_mod(c):
    """现行指针的读写与老库迁移（pack/orch/current.py，只依赖标准库）：按文件路径载入作业的引擎根里那份（同 programs._dirrename，#1424：
    不走 import pack.orch）；引擎根里没有（单测的假引擎根）用本仓库那份"""
    path = Path(c.engine) / "pack/orch/current.py"
    if not path.is_file():
        path = Path(__file__).resolve().parents[2] / "pack/orch/current.py"
    key = str(path.resolve())
    if key not in _CURRENT_MOD:
        import importlib.util
        spec = importlib.util.spec_from_file_location("s2a_engine_current", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _CURRENT_MOD[key] = mod
    return _CURRENT_MOD[key]


def current_root(c, pointer):
    """产物根里的「<款>@现行」→ 现行版本目录 Path | None（没有 / 指针不合规）。老库的软链 / junction / 实目录当场迁移成指针文件
    （持该款提交锁 <产物根>/.<款>.commit.lock，与 pack/roots.sh、pack/orch/roots.py 同一把，最多等 10 分钟）"""
    import filelock
    pointer = Path(pointer)
    roots, game = pointer.parent, pointer.name[:-len(CURRENT)]
    return _current_mod(c).resolve(roots, game, lock=lambda: filelock.held(roots / f".{game}.commit.lock", wait_s=600, poll=0.05))


def set_current(c, roots, game, name):
    """切 roots 里 game 的现行到同目录的版本目录 name（临时指针 fsync 后原子改名）"""
    _current_mod(c).write(roots, game, name)


def phone_ipa(c, previous=False):
    return c.library / (PHONE_PREVIOUS if previous else PHONE_IPA)


def device_key(ident):
    key = re.sub(r"[^0-9A-Za-z-]", "", str(ident or ""))[:64]
    return key or "unknown"


def device_path(c, ident):
    return c.library / DEVICES / (device_key(ident) + ".json")


def load_device(c, ident):
    """这台手机的记录；还没有、而迁移留下了旧容器记录 → 认领它（改名成这台的），旧版装过的各款这次照常带上"""
    p = device_path(c, ident)
    if not p.is_file():
        legacy = device_path(c, LEGACY_DEVICE)
        if legacy.is_file() and device_key(ident) != LEGACY_DEVICE:
            p.parent.mkdir(parents=True, exist_ok=True)
            os.replace(legacy, p)
    rec = read(p, {})
    return dict(dict(schema=1, games={}, shellId="", bundleId="", failedShells=[]), **rec) if isinstance(rec, dict) else dict(schema=1, games={}, shellId="", bundleId="", failedShells=[])


def save_device(c, ident, rec):
    p = device_path(c, ident)
    p.parent.mkdir(parents=True, exist_ok=True)
    atomic(p, dict(rec, schema=1))


FREE_SIGN_LIFETIME = 7 * 86400   # 免费 Apple ID 签的描述文件 7 天（读不到签好的包里的真实到期时按它估，同 host_update.SIGN_LIFETIME）


def launcher_free_in_use(rec):
    """这台手机现在用的 S2Arm 是不是「这台电脑的启动器用免费 Apple ID 签的那份」（游戏库「免费签名快到期」提醒只给这种）。
    只看设备记录里已有的事实，不连手机（列游戏库要快）：
      · 启动器装过（有壳号 shellId + 包名 bundleId），且那次是免费签（signed.free）；
      · 玩家在总控台选用的不是启动器那份（chosenBundleId 与 bundleId 不同）→ 不是；
      · 启动器装之后又往别的工具（AltStore / SideStore …）装的 S2Arm 推过游戏（externalBundleId，推送时刻 externalAt 晚于签名时刻；
        旧记录没有 externalAt 时按别的工具算）→ 不是；
    不看电脑这边的签名方式设置：设置只管下一次怎么签，手机上那份免费签的 App 没重装前照样 7 天到期，照旧提醒；
    玩家真用证书 / 付费账号重装后 signed.free 为假，提醒自然消失"""
    signed = rec.get("signed") if isinstance(rec.get("signed"), dict) else {}
    own = str(rec.get("bundleId") or "").lower()
    if not signed.get("free") or not rec.get("shellId") or not own:
        return False
    chosen = str(rec.get("chosenBundleId") or "").lower()
    if chosen and chosen != own:
        return False
    ext = str(rec.get("externalBundleId") or "").lower()
    if ext and ext != own:
        at, ext_at = signed.get("at"), rec.get("externalAt")
        if not isinstance(ext_at, (int, float)) or not isinstance(at, (int, float)) or ext_at >= at:
            return False
    return True


def install_record(c, gid):
    """这款最近一次装机签名的记录 {at, free, device, deviceKey, [deviceKind], [expires, expiresKnown]}（游戏库页「还有几天到期 / 续签」）：各台手机记录里带这款的取最新一次；没装过 → None。
    free 只在那台手机现在用的就是启动器免费签的那份时为 True（launcher_free_in_use）：玩家换成别的工具装、换签名方式后不再给，提醒自动消失。
    free 时带到期时刻 expires：签好的包里读到的真值（signed.expires，expiresKnown=True）；没有才按 7 天估（expiresKnown=False）。前端直接用，不再自己加天数"""
    gid = gid.upper()
    # deviceKind：装的是 iPad 还是 iPhone（#1962，游戏库「已推到 {0}」；0.6.9 前的记录没有，前端填「iPhone / iPad」）。
    # deviceKey：那台设备的记录键（UDID）。续签 / 重装装回当初那台，不替玩家换一台（维护者 11-11：续签时 iPad 被装上）
    recs = [(dict(r["signed"], deviceKey=k), r) for k, r in devices(c) if gid in (r.get("games") or {}) and isinstance(r.get("signed"), dict)]
    if not recs:
        return None
    out, rec = max(recs, key=lambda x: x[0].get("at") or 0)
    out["free"] = launcher_free_in_use(rec)
    out.pop("expires", None)
    if out["free"]:
        real = rec["signed"].get("expires")
        known = isinstance(real, (int, float))
        at = out.get("at")
        if known or isinstance(at, (int, float)):
            out.update(expires=real if known else at + FREE_SIGN_LIFETIME, expiresKnown=known)
    return out


def devices(c):
    """[(设备键, 记录)…]。访达往 exFAT 等非 APFS 盘搬库会给每个记录配一份 ._<名>.json 附属文件（4 KB 非 UTF-8 元数据），
    按 os_junk 跳过（#911：读它抛 UnicodeDecodeError，整次刷新游戏库失败）；单个记录读不出只记一行、跳过这一台，不拖垮整个请求"""
    d = c.library / DEVICES
    out = []
    for p in (sorted(d.glob("*.json")) if d.is_dir() else []):
        if os_junk(p.name):
            continue
        try:
            out.append((p.stem, read(p, {})))
        except (OSError, ValueError) as e:   # UnicodeDecodeError / JSONDecodeError 都是 ValueError
            print(f"[s2a] 设备记录 {p.name} 读不出，跳过：{type(e).__name__}: {e}", file=sys.stderr)
    return out


# ---- 迁移（旧布局 → VERSION 2）----
# 每款：先把 games/<号>/ 整个改名成 games/<英文名>/ 并写 game.json（之后任何时候中断，都能凭 game.json 认出来），再把散在别处的搬进去。
# 只做同盘改名；只删能重建的：Mac 旧的上一版运行版本（releases 里不是现行的那几份）。
MOVES = (("cache/{gid}", "build"), ("saves/{gid}", "saves"), ("save-backups/{gid}", "save-backups"),
         ("runtime-cache/{gid}", "shader-cache"), ("mappings/{gid}.json", "input.json"))


def _move(src, dst):
    if os.path.lexists(src) and not os.path.lexists(dst):
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)


def _host_digest(app):
    from core import digest
    exe = app / "Contents/MacOS/s2arm-host"
    return digest(exe)[:12] if exe.is_file() else None


def _split_release(c, gid, d):
    """旧 Mac 运行版本（games/<号>/current → releases/<键>-…，含宿主）拆成 image/mac + hosts/mac/<摘要>；其余旧版本删掉（可重出）"""
    from library import _rm
    link, releases = d / "current", d / "releases"
    image = d / "image" / "mac"
    if os.path.lexists(link) and not image.exists():
        if link.is_symlink() or getattr(os.path, "isjunction", lambda _: False)(link):
            target = Path(os.readlink(link))
            cur = resolve_path(target if target.is_absolute() else link.parent / target)
        else:
            cur = resolve_path(link)
        if cur.parent == resolve_path(releases) and cur.is_dir():
            app = cur / "S2ArmGame.app"
            if app.is_dir():
                sha = _host_digest(app)
                if sha:
                    dest = hosts_mac(c) / sha / "S2ArmGame.app"
                    if dest.exists():
                        _rm(c, c.library, app)
                    else:
                        _move(app, dest)
                    info = read(d / GAME_JSON, {})
                    atomic(d / GAME_JSON, dict(info, hostMac=sha))
            m = read(cur / "manifest.json", {})
            if m.get("files"):
                m["files"] = {k: v for k, v in m["files"].items() if not k.startswith("S2ArmGame.app/")}
                atomic(cur / "manifest.json", m)
            _move(cur, image)
    if os.path.lexists(link):
        link.unlink()
    if releases.is_dir():
        _rm(c, c.library, releases)


_NACP_GLOBS = ("games/{gid}/current/ctl/control.nacp", "games/{gid}/current/exefs/control.nacp", "iPhone/{gid}/*资源包/ctl/control.nacp",  # 非玩家句
               "iPhone/{gid}/roots/*/ctl/control.nacp", "iPhone/{gid}/container-kit/ctl/control.nacp", "cache/{gid}/*/roots/*/ctl/control.nacp",
               # 新布局里还叫游戏号的文件夹（heal_folder_names）：Mac / iPhone 产物、出包解包目录
               "games/{gid}/image/mac/ctl/control.nacp", "games/{gid}/image/ios/*/ctl/control.nacp", "games/{gid}/build/*/extract/ctl/control.nacp")


def _english_from_disk(c, gid):
    """旧清单只有中文名时，到这款已有的产物里找 control.nacp 读英文名（美式 → 英式英语），玩家在文件夹里认得出；找不到返回空串"""
    try:
        from library import engine_tool
        dump = engine_tool(c, "ns2_dump")
    except Exception:   # noqa: BLE001 —— 引擎工具载不进来就退回游戏号命名
        return ""
    for pattern in _NACP_GLOBS:
        for p in sorted(c.library.glob(pattern.format(gid=gid))):
            try:
                n = p.read_bytes()
            except OSError:
                continue
            if len(n) == 0x4000:
                name = dump.nacp_title(n, 0) or dump.nacp_title(n, 1)
                if name and re.sub(r"[^A-Za-z0-9]", "", name):
                    return name
    return ""


def _ascii_name(name):
    return bool(re.sub(r"[^A-Za-z0-9]", "", name or ""))


def heal_folder_names(c):
    """还叫游戏号的文件夹（导入时没拿到英文名：读取器早先不给英文名、拷封面时这款还没进 catalog）按英文名改名，英文名记进 catalog。
    只在英文名可能刚拿到的那一刻调（启动器剃刀 H3：原先每个作业开头都抢一次执行锁，中文名、没出过包的款永远在待改名单里，正撞上起局 / 出包就报忙）：
    导入、出包（Mac / iPhone）作业结束时（main.HEAL_AFTER，锁都已放），后台商店查询拿到英文名后（store_meta_bg）。
    执行锁、目录锁（改名动执行区，写 catalog 要目录锁）有一把被占就这次不改：文件夹叫游戏号只是不好看，下次这三处任一再试。
    英文名按 catalog 的 englishName → catalog 名字（有 ASCII 时）→ 这款已有产物里的 control.nacp；都没有（还没出过包的中文名游戏）就留着，出过包后再改"""
    roots = [r for _, r, online in locations(c) if online]
    stuck = [d for r in roots if (games_root(c, r)).is_dir() for d in games_root(c, r).iterdir()
             if _GID.fullmatch(d.name.upper()) and (d / GAME_JSON).is_file()]
    if not stuck:
        return 0
    renamed = 0
    with c.idle("execution") as idle, c.idle("catalog") as idle_catalog:
        if not (idle and idle_catalog):
            return 0
        cat_path = c.library / "catalog.json"
        cat = read(cat_path, {}) or {}
        games = {g.get("id", "").upper(): g for g in cat.get("games", []) if isinstance(g, dict)}
        changed = False
        for d in stuck:
            gid = d.name.upper()
            g = games.get(gid, {})
            english = g.get("englishName") or (g.get("name") if _ascii_name(g.get("name")) else "") or _english_from_disk(c, gid)
            if not _ascii_name(english):
                continue
            name = folder_name(english, gid, [p.name for p in d.parent.iterdir() if p != d])
            dest = d.parent / name
            if name.upper() == gid or os.path.lexists(dest):
                continue
            try:
                os.replace(d, dest)
            except OSError:   # Windows 上文件夹里有打开的文件：整款不动（文件夹、索引、catalog 都留原样），下次再试
                continue
            from library import _retarget_links
            _retarget_links(dest, d, dest)
            _remember(c, gid, dest)
            if g and not g.get("englishName"):   # 改名成了才记英文名：与文件夹、索引一起变
                g["englishName"] = english; changed = True
            renamed += 1
        if changed:
            atomic(cat_path, cat)
    return renamed


def migrate(c):
    """旧布局一次性按版本逐步迁到 VERSION（调用方持执行锁）；已迁完直接返回。每步可中断续做"""
    marker = c.library / ".s2arm-layout.json"
    state = read(marker, {})
    if state.get("version", 0) >= VERSION:
        return False
    if state.get("version", 0) < 2:
        _upgrade_2(c, marker, state)
    if read(marker, {}).get("version", 0) < 3:
        _upgrade_3(c, marker)
    if read(marker, {}).get("version", 0) < 4:
        _upgrade_4(c)   # 3→4，可重入
        atomic(marker, dict(read(marker, {}), version=4))
    if read(marker, {}).get("version", 0) < 5:
        _upgrade_5(c)   # 4→5，可重入
        atomic(marker, dict(read(marker, {}), version=5))
    return True


def _upgrade_2(c, marker, state):
    """旧布局 → 2：每款进 games/<英文名>/"""
    c.begin("整理游戏库结构（一次性，只改名不复制）")
    done = set(state.get("games", []))
    names = {g.get("id", "").upper(): (g.get("englishName") or g.get("name") or "") for g in read(c.library / "catalog.json", {}).get("games", [])}
    old_root = games_root(c)
    legacy = sorted(p.name for p in old_root.iterdir() if _GID.fullmatch(p.name.upper()) and p.is_dir() and not (p / GAME_JSON).is_file()) if old_root.is_dir() else []
    ids = sorted((set(names) | set(legacy) | {g for spec, _ in MOVES for g in _legacy_ids(c, spec)}) - done)
    for gid in ids:
        if not _GID.fullmatch(gid):
            continue
        d = find_game(c, gid)
        if d is None:
            src = old_root / gid
            taken = [p.name for p in old_root.iterdir()] if old_root.is_dir() else []
            english = names.get(gid, "")
            if not _ascii_name(english):
                english = _english_from_disk(c, gid) or english
            name = folder_name(english, gid, [t for t in taken if t != gid])
            dest = old_root / name
            contained(c.library, dest)
            if src.is_dir() and not dest.exists():
                os.replace(src, dest)
            dest.mkdir(parents=True, exist_ok=True)
            atomic(dest / GAME_JSON, dict(read(dest / GAME_JSON, {}), schema=1, id=gid))
            _remember(c, gid, dest); d = dest
        for spec, rel in MOVES:
            _move(c.library / spec.format(gid=gid), d / rel)
        _split_release(c, gid, d)
        done.add(gid)
        atomic(marker, dict(version=1, games=sorted(done)))
    for spec, _ in MOVES:   # 搬空的旧类型目录
        top = c.library / spec.split("/")[0]
        if top.is_dir() and not has_content(top):
            for junk in OS_JUNK:   # 只剩系统自动生成的文件也算搬空了
                (top / junk).unlink(missing_ok=True)
            top.rmdir()
    if not location_id(c.library):   # 旧库原地变成第一个存放位置（游戏库结构 v3）
        import uuid
        atomic(c.library / LOCATION_JSON, dict(schema=1, id=uuid.uuid4().hex, version=VERSION))
    atomic(marker, dict(version=2, games=sorted(done)))


def _move_any(src, dst):
    """同卷改名；跨卷（这款在别的存放位置）退回拷贝后删源"""
    if not os.path.lexists(src) or os.path.lexists(dst):
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.replace(src, dst)
    except OSError:
        shutil.move(str(src), str(dst))


def _upgrade_3(c, marker):
    """2 → 3：旧的 iPhone/<号>/（产物根 / ipa / 资源包 / 容器件 / shell.id）与 iPhone/container/（底包 S2Arm.app、S2Arm.ipa、bundle.txt）
    → 每款 image/ios/{kit,pack} + game.json 的 ios、默认位置根 S2Arm.ipa、devices/legacy.json。
    老玩家有 ipa 没容器件的：先从现行产物根存一份容器件再删产物根（否则装机只能重新出包）。单款 ipa、产物根、底包都能重建，删掉。
    每款做完记进标记的 iphone 列表，中途被杀下次接着做；容器最后做"""
    from library import save_container_kit, _rm
    state = read(marker, {})
    done = set(state.get("iphone", []))
    phones = c.library / "iPhone"
    for d in (sorted(phones.iterdir()) if phones.is_dir() else []):
        gid = d.name.upper()
        if not d.is_dir() or not _GID.fullmatch(gid) or gid in done:
            continue
        if find_game(c, gid) is None and not any(g.get("id", "").upper() == gid for g in read(c.library / "catalog.json", {}).get("games", [])):
            done.add(gid); atomic(marker, dict(state, iphone=sorted(done))); continue   # 游戏库里已经没有这款：留着的旧产物下面随 iPhone/ 一起删
        kit = d / "container-kit"
        if not (kit / "main.npdm").is_file():
            root = next((r for r in [*(current_root(c, p) for p in sorted(d.glob("roots/*" + CURRENT))), d / "work/pkg/product"] if r is not None and (r / "main.npdm").is_file()), None)
            if root is not None and any(p.suffix == ".ipa" for p in d.iterdir()):
                save_container_kit(c, gid, root, dest=d)
        image = image_ios(c, gid)
        _move_any(kit, image / IOS_KIT)
        pack = next((p for p in sorted(d.iterdir()) if p.is_dir() and p.name.endswith("资源包")), None)
        if pack is not None:
            _move_any(pack, image / IOS_PACK)
        if (d / "logs").is_dir():   # 出包日志是释放空间的保留项（library._build_entries）：搬到新的出包工作目录，不随 iPhone/ 一起删
            _move_any(d / "logs", ios_work(c, gid) / "logs")
        ios = {}
        try:
            ios["shellId"] = (d / "shell.id").read_text(encoding="utf-8").strip()
        except OSError:
            pass
        want = read(image / IOS_PACK / "manifest.json", {}).get("index_sha256") if (image / IOS_PACK).is_dir() else None
        if want:
            ios["pack"] = want
        if ios:
            update_info(c, gid, ios=dict(game_info(c, gid).get("ios") or {}, **ios))
        done.add(gid)
        atomic(marker, dict(state, iphone=sorted(done)))
    box = phones / "container"
    if box.is_dir():
        if (box / PHONE_IPA).is_file():
            _move_any(box / PHONE_IPA, phone_ipa(c))
        cat = read(box / "S2Arm.app" / "s2a_catalogue.json", {})
        if cat.get("games") and not device_path(c, LEGACY_DEVICE).is_file():
            bid = (box / "bundle.txt").read_text(encoding="utf-8").strip() if (box / "bundle.txt").is_file() else ""
            signed = [r for r in (read(path(c, e["title_id"], "ios-install.json", create=False), None) for e in cat["games"] if e.get("title_id")) if isinstance(r, dict)]
            save_device(c, LEGACY_DEVICE, dict(games={e["title_id"].upper(): {} for e in cat["games"] if e.get("title_id")},
                                               shellId=cat.get("shell_id") or "", bundleId=bid, failedShells=[],
                                               **({"signed": max(signed, key=lambda r: r.get("at") or 0)} if signed else {})))
    for gid in sorted(done | {g.get("id", "").upper() for g in read(c.library / "catalog.json", {}).get("games", []) if _GID.fullmatch(g.get("id", "").upper())}):   # 每款的已装记录 ios-install.json 已并进 devices/（上面）：删掉
        old = path(c, gid, "ios-install.json", create=False)
        if old.is_file():
            old.unlink()
    if phones.is_dir():
        _rm(c, c.library, phones)
    atomic(marker, dict(state, version=3, iphone=sorted(done)))


def _legacy_ids(c, spec):
    top = c.library / spec.split("/")[0]
    if not top.is_dir():
        return []
    return [p.name.removesuffix(".json").upper() for p in top.iterdir() if _GID.fullmatch(p.name.removesuffix(".json").upper())]


def ensure(c):
    """作业开始前：库还是旧布局就拿执行锁迁移；之后（非探测作业）起后台商店查询。日志 / 任务记录的迁回在建任务时（follow_task）"""
    _ensure_layout(c)
    if (c.library / ".s2arm-library.json").is_file() and c.operation not in ("installCheck", "targetDevice", "locations", "launch"):   # 每几秒一次的只读探测不起；起局时玩家在等，连后台也不起
        from library import store_meta_background
        store_meta_background(c)     # 缺横图 / 英文名、7 天内没查过的款：后台查，查到英文名在那里接着改名


def _ensure_layout(c):
    """库还是旧布局就拿执行锁迁移：按库锁同一语义排队（剃刀 H2：原先另写一套每 2 秒再试、120 秒后报另一句话）；
    拿到锁先看标记（排队期间别的作业可能已迁完，migrate 已迁完直接返回）"""
    if read(c.library / ".s2arm-layout.json", {}).get("version") == VERSION or not (c.library / ".s2arm-library.json").is_file():
        return
    with c.lock("execution"):
        migrate(c)


# ---- 3→4（游戏库结构 P3）：库外的东西搬进默认位置 ----
# 目标：玩家指定的库是入口，私有目录（Mac ~/Library/Application Support/S2Arm，Windows %LOCALAPPDATA%\S2Arm\WindowsLauncher）只留设置、密钥和控制口文件。
#   工具缓存：原 work_root（库在私有目录里时 = 私有目录，否则 = 库/.s2arm-work）下的 cache/、run/ → <默认位置>/tool-cache/{cache,run}（core.Context.work_root）。
#     都能重建：同一卷改名（逐个子项，目标已有的不盖），跨卷直接删、不拷。
#   日志、任务记录：v0.3.0 起固定在 <私有目录>/logs（剃刀 H6），不再搬进默认位置；旧的在建任务时收回（adopt_library_logs）。
#   引擎副本在 embedded.install 里搬（它在 ensure 之前跑）。
# 每步都是逐项改名 / 删，中途被杀下次接着做；布局标记最后才写 4。

def _upgrade_4(c):
    new = c.library / "tool-cache"
    for old in (c.private, c.library / ".s2arm-work"):
        for name in ("cache", "run"):
            _absorb_rebuildable(c, old / name, new / name)
    with contextlib.suppress(OSError):
        (c.library / ".s2arm-work").rmdir()


def _upgrade_5(c):
    """hosts/mac → hosts/mac.noindex（#1126 / #2024：聚焦收录 hosts/mac 里的 S2ArmGame.app，系统随即登记，局后注销完一扫描又回来）。
    同一父目录逐个子项改名（宿主不一定能重建：不兼容本版的款还用旧宿主，game.json 的 hostMac 按摘要找它）；新位置已有同名的留新位置的，
    旧的那份删掉。中途被杀下次接着做"""
    from library import _discard
    old, new = c.library / "hosts" / "mac", hosts_mac(c)
    if os.path.islink(old) or not old.is_dir():
        return
    new.mkdir(parents=True, exist_ok=True)
    for child in sorted(old.iterdir()):
        if os.path.lexists(new / child.name):
            _discard(child)
        else:
            os.replace(child, new / child.name)
    with contextlib.suppress(OSError):
        old.rmdir()


def _absorb_rebuildable(c, src, dst):
    """能重建的目录 src 并进 dst：同一卷逐个子项改名（dst 已有的同名项留 dst 的），剩下的删；跨卷整个删"""
    from library import _discard
    if not os.path.lexists(src):
        return
    if os.path.islink(src) or not src.is_dir():
        src.unlink()
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if _same_volume(src, dst.parent):
        if not os.path.lexists(dst):
            os.replace(src, dst)
            return
        for child in sorted(src.iterdir()):
            if not os.path.lexists(dst / child.name):
                os.replace(child, dst / child.name)
    try:
        _discard(src)
    except OSError:
        pass   # 删不掉的（Windows 上被占用）留着，不影响新位置


def _moved(src, dst):
    """单个文件 / 目录搬到 dst：同一卷改名；跨卷拷到 dst 旁的临时名再换名、删原件。dst 已有就不动（不丢任何一边）"""
    if os.path.lexists(dst) or not os.path.lexists(src):
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if _same_volume(src, dst.parent):
        os.replace(src, dst)
        return
    import uuid
    temporary = dst.with_name(dst.name + "." + uuid.uuid4().hex + ".partial")
    try:
        if src.is_dir() and not src.is_symlink():
            shutil.copytree(src, temporary, symlinks=True)
        else:
            shutil.copy2(src, temporary, follow_symlinks=False)
        os.replace(temporary, dst)
    finally:
        if os.path.lexists(temporary):
            shutil.rmtree(temporary, ignore_errors=True) if temporary.is_dir() else temporary.unlink()
    remove_tree(src) if src.is_dir() and not src.is_symlink() else src.unlink()


def follow_task(c):
    """Context 建任务时调：索引表第一项核成这个默认位置（core.default_home 只拿私有目录时靠它找工具缓存 / 引擎副本）；
    旧位置还有日志 / 任务记录（v0.3.0 之前库建好后写在 <库>/logs）就迁回私有目录（adopt_library_logs），续跑的同一任务号 attemptNo 接得上"""
    if (c.library / ".s2arm-library.json").is_file():
        try:
            disk = (read(_index_path(c), {}) or {}).get("locations") or []
        except (OSError, ValueError):
            disk = []
        if not disk or not isinstance(disk[0], dict) or disk[0].get("path") != str(c.library):
            save_index(c)
    adopt_library_logs(c)


def adopt_library_logs(c):
    """日志与任务记录固定在 <私有目录>/logs（core.logs_root，剃刀 H6）。旧位置——v0.3.0 之前库建好后写的 <默认位置>/logs，以及 P3 之前的
    <私有目录>/jobs——收回来：先按保留规则清一遍（core.prune_jobs）再搬，跨卷时少拷；还没写终态、进程还在的任务（日志名以任务号开头）不动，
    等它结束后的下一个作业再收（读的一方 core._job_dirs 照样找得到）。没有旧目录时只是两次 is_dir"""
    from core import TERMINAL_STATES, pid_alive, prune_jobs
    target = c.logs
    old = c.library / "logs"
    sources = [(c.private / "jobs", target / "jobs")]
    if (c.library / ".s2arm-library.json").is_file():   # 只收游戏库自己的旧日志：setup 时玩家选的文件夹还不是库，里面的 logs 是玩家自己的东西
        sources += [(old / "jobs", target / "jobs"), (old, target)]
    sources = [(s, d) for s, d in sources if s != d and s != target / "jobs"]
    if not any(s.is_dir() for s, _ in sources):
        return
    running = set()
    for src, _ in sources:
        if src.name != "jobs" or not src.is_dir():
            continue
        prune_jobs(c.private, jobs=src)
        for p in entries(src, "*.json"):
            if p.name.endswith(".request.json"):
                continue
            try:
                r = read(p, {}) or {}
            except (OSError, ValueError):
                continue
            if isinstance(r, dict) and r.get("state") not in TERMINAL_STATES and not r.get("ended") and pid_alive(r.get("pid")):
                running.add(p.stem)
    for src, dst in sources:
        if not src.is_dir() or src.is_symlink():
            continue
        # 每个作业建任务时都收一次：别的作业可能同时在收，判完 is_dir 到列目录之间目录已被它收空删掉——被对方收走的就算收完了
        try:
            children = sorted(src.iterdir())
        except FileNotFoundError:
            continue
        for child in children:
            if src == old and child.name == "jobs":
                continue
            if any(child.name.startswith(t) for t in running):
                continue
            try:
                _moved(child, dst / child.name)
            except OSError:
                continue   # 这一项这次搬不动，留着下次再试；读的一方（core._job_dirs）照样找得到
    for d in (old / "jobs", old, c.private / "jobs"):
        with contextlib.suppress(OSError):
            d.rmdir()


# ---- 默认库位置（游戏库结构 P3）：新装 ~/S2Arm（Windows %USERPROFILE%\S2Arm），访达 / 资源管理器里看得见 ----
# 老玩家的库若还在旧默认位置（私有目录下的「游戏库」= Mac 启动器、「DefaultLibrary」= Windows 启动器）：同一卷改名到新默认位置；
# 目标已存在、跨卷、库里有任务在跑或改名失败就原地不动照常用。动之前在私有目录写 library-relocate.json，改完更新索引表与前端设置文件
# （Mac preferences.json 的 library、Windows library-location.txt），中途被杀下次接着收尾。绝不删数据。玩家自己选过的位置不动。
# 系统自动生成的文件（访达 .DS_Store、Windows 资源管理器 desktop.ini / Thumbs.db、访达往非 APFS 盘拷东西留下的 ._ 开头附属文件）：
#   判「文件夹空不空」「里面有没有东西」时不算数（11-09 #343 同类扫描）。三端共用这一份：Mac 前端 EnvironmentView.swift、Windows 前端 LibraryPage.cs
#   照抄同一组（tests/os_junk_sync_test.sh 核三处一致）
OS_JUNK = frozenset({".DS_Store", "desktop.ini", "Thumbs.db"})
OS_JUNK_PREFIX = "._"


def os_junk(name):
    return name in OS_JUNK or name.startswith(OS_JUNK_PREFIX)


def entries(d, pattern="*", recursive=False):
    """d 下按 pattern 列出的业务文件 / 目录（排好序）：路径里任何一级是系统附属文件都不算（d 不存在 / 不是目录 → []）。
    玩家能放到外置盘上的目录（游戏库、数据目录、mod / 金手指 / 导出文件夹）一律经这里列：exFAT / FAT 上 macOS 给每个带扩展属性的文件
    配一份 ._<名>（4 KB AppleDouble，含 NUL、非 UTF-8），pathlib 的 glob("*.json") / rglob 照样匹配它；逐个调用点各自补过滤，
    换个调用点又漏（#812 #816 #911 #1010 #369 #382 都是这一类）"""
    d = Path(d)
    if not d.is_dir():
        return []
    found = d.rglob(pattern) if recursive else d.glob(pattern)
    return sorted(p for p in found if not any(os_junk(part) for part in p.relative_to(d).parts))


# 每款游戏文件夹里「存档类」的东西：唯一来源（维护者 11-17：删除游戏只留了 saves/、save-backups/，把 SaveData*（Mac 原生格式存档位置）
#   和 save_backup/（iPhone / Apple TV 装机前拉回的存档备份，手机存档在电脑上唯一的一份）一起删了）。删除游戏、腾空间、换位置核对、空间统计都读这一份。
#   saves/：Ryujinx 数据根（build.py）；save-backups/：存档管理的备份；save_backup/：装机前 / 电视拉回（install.py、tvos.py）；
#   SaveData、SaveData-<玩家>：原生格式存档位置（build.py、saves.py）。金手指、mod 不算存档
SAVE_DIRS = ("saves", "save-backups", "save_backup")
SAVE_DATA = re.compile(r"SaveData(-.+)?")


def is_save_entry(name):
    """游戏文件夹里这一项（名字）是不是存档类"""
    return name in SAVE_DIRS or bool(SAVE_DATA.fullmatch(name))


def save_entries(gdir):
    """游戏文件夹里现有的存档类各项（不跟软链认不认：按名字认，删除 / 保留由调用方定）；文件夹不在 → []"""
    try:
        return sorted(p for p in Path(gdir).iterdir() if is_save_entry(p.name))
    except (FileNotFoundError, NotADirectoryError):
        return []


def has_content(d):
    """d 里除了系统自动生成的文件还有没有别的东西（d 不存在 / 不是目录 → False）"""
    try:
        return any(not os_junk(p.name) for p in Path(d).iterdir())
    except (FileNotFoundError, NotADirectoryError):
        return False


OLD_DEFAULTS = ("游戏库", "DefaultLibrary")
RELOCATE_JSON = "library-relocate.json"


def new_default_library():
    return Path.home() / "S2Arm"


def standard_private():
    """前端缺省的私有目录（s2armctl root() 同一规则）；用 --data-root 等自定义数据目录时不搬库（测试、多开不会写到玩家主目录）"""
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "S2Arm" / "WindowsLauncher"
    return Path.home() / "Library" / "Application Support" / "S2Arm"


RELOCATE_LOCK = ".relocate.lock"
RELOCATE_LOCK_WAIT = 60   # 等另一个作业搬完的上限（秒）；同卷改名一瞬间，等这么久说明那边卡住了


def relocate_default(private, library):
    """请求里的库是旧默认位置时 → 该用的库路径（已搬 / 这次搬成 → 新位置；否则原样）。Context 建任务时调，别的情况一次比较就返回。
    判断和改名在私有目录的 .relocate.lock 里做（v0.2.5 发版用例 upgrade ① 两次红）：启动器一打开会同时起好几个作业，原先各自判断——
    后到的那个读标记时前一个还没写、等它看「新位置在不在」时前一个已经改完名，就当成「新位置被占」原样返回旧路径；或者两个都去改名，
    后一个改名失败也返回旧路径。拿着旧路径的作业把旧目录（任务记录、日志、锁文件）又建了出来：旧库残留、新库缺这些文件。
    现在后到的等前一个做完，再读标记就直接用新位置"""
    private, library = Path(private), Path(library)
    if library.parent != private or library.name not in OLD_DEFAULTS:
        return library
    with _relocate_lock(private):
        return _relocate_locked(private, library)


@contextlib.contextmanager
def _relocate_lock(private):
    """判断和改名只许一个作业做：排队等前一个做完（最多 RELOCATE_LOCK_WAIT 秒），到上限报 library_busy（剃刀 H2：原先等不到就不拿锁照常判断，等于没锁）。
    私有目录写不了（建不了锁文件）照旧判断：后面写标记也会失败、原样返回"""
    import filelock
    try:
        private.mkdir(parents=True, exist_ok=True)
        (private / RELOCATE_LOCK).open("a").close()
    except OSError:
        yield
        return
    try:
        with filelock.held(private / RELOCATE_LOCK, wait_s=RELOCATE_LOCK_WAIT, poll=0.05,
                           holder=dict(operation="relocate", pid=os.getpid(), host=socket.gethostname(),
                                       startedAt=round(time.time(), 3))):
            yield
    except filelock.Busy as busy:
        detail = f"等了 {RELOCATE_LOCK_WAIT} 秒，旧默认游戏库搬家锁仍被占（{busy.holder}）"  # 非玩家句
        raise library_lock_failure(busy.holder, "另一个任务正在使用游戏库，请稍后重试。", detail) from None  # 非玩家句


def _relocate_locked(private, library):
    marker = private / RELOCATE_JSON
    try:
        note = read(marker, {}) or {}
    except (OSError, ValueError):
        note = {}
    if note.get("from") == str(library) and note.get("to"):
        target = Path(note["to"])
        if (target / ".s2arm-library.json").is_file() and not (library / ".s2arm-library.json").is_file():
            _finish_relocate(private, library, target)   # 搬过了（或改完名被杀）：收尾后照新位置用
            return target
    target = new_default_library()
    if (private.resolve() != standard_private().resolve() or not (library / ".s2arm-library.json").is_file()
            or os.path.lexists(target)):
        return library
    try:
        if not _same_volume(library, target.parent):
            return library
        if not _idle(library):
            return library
        atomic(marker, {"schema": 1, "from": str(library), "to": str(target), "state": "moving"})
        os.replace(library, target)
    except OSError:
        # 改名没成（Windows 上旧库里有文件被别的程序开着时整目录改不了名）：库原样没动，撤掉「正在搬」的标记，照旧用旧位置，下次再试
        if not os.path.lexists(target):
            with contextlib.suppress(OSError):
                if (read(marker, {}) or {}).get("state") == "moving":
                    marker.unlink()
        return library
    _finish_relocate(private, library, target)
    return target


def _idle(library):
    """库里没有任务在跑（同整库搬家：执行锁、目录锁都拿得到）才搬。拿到就放：Windows 上库里有打开的文件时目录改不了名"""
    import filelock
    try:
        with filelock.held(library / ".execution.lock"), filelock.held(library / ".catalog.lock"):
            return True
    except filelock.Busy:
        return False


def _finish_relocate(private, old, new):
    """搬完收尾（可重复做）：库里指向旧位置的绝对链接改指新位置；索引表里旧路径换新；前端设置文件里记的是旧路径就换新；标记记 done"""
    from library import _retarget_links
    marker = private / RELOCATE_JSON
    try:
        note = read(marker, {}) or {}
    except (OSError, ValueError):
        note = {}
    if note.get("state") == "done" and note.get("from") == str(old):
        _update_settings(private, old, new)   # 前端可能把旧路径又写回了设置（内存里还是旧值）：每次都核
        return
    _retarget_links(new, old, new)
    index = private / "library-index.json"
    try:
        idx = read(index, None)
    except (OSError, ValueError):
        idx = None
    if isinstance(idx, dict):
        for loc in idx.get("locations") or []:
            if isinstance(loc, dict) and loc.get("path") == str(old):
                loc["path"] = str(new)
        atomic(index, idx)
    _update_settings(private, old, new)
    atomic(marker, {"schema": 1, "from": str(old), "to": str(new), "state": "done"})


def _same_path(text, path):
    try:
        return resolve_path(Path(str(text)).expanduser()) == resolve_path(path) or str(text) == str(path)
    except (OSError, ValueError):
        return False


def _update_settings(private, old, new):
    prefs = private / "preferences.json"
    try:
        p = read(prefs, None)
    except (OSError, ValueError):
        p = None
    if isinstance(p, dict) and p.get("library") and _same_path(p["library"], old):
        p["library"] = str(new)
        atomic(prefs, p)
    txt = private / "library-location.txt"
    try:
        if txt.is_file() and _same_path(txt.read_text(encoding="utf-8").strip(), old):
            txt.write_text(str(new), encoding="utf-8")
    except OSError:
        pass
