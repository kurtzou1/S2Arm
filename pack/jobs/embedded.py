"""Install the app's immutable engine snapshot into a writable cache (the default location's hosts/engine.noindex, see engines_root).

The snapshot carries no Git repository: the HEAD-based stage keys were computed when
the app was packaged and are stored in engine.json (launchers/macos/bundle_engine.py).
"""
import contextlib
from pathlib import Path
import os
import shutil
import uuid
from core import Failure, atomic, contained, read


def install(c):
    bundle = c.r.get("engineBundle")
    if not bundle:
        return  # Source-checkout CLI/development tests.
    source = Path(bundle).resolve()
    manifest = read(source / "engine.json", {})
    identity = manifest.get("id", "")
    if manifest.get("schema") != 1 or len(identity) != 64 or any(x not in "0123456789abcdef" for x in identity):
        raise Failure("应用内置引擎不完整，请重新安装完整应用。")
    root = engines_root(c)
    destination = contained(root, root / identity)
    _drop_old_copies(c, root)
    # 装好的副本直接用，不在每个作业开头逐文件复核（11-19 维护者：「每次启动都很慢……这种校验是不是自己给自己挖的坑」：原先每个作业——
    #   包括每次点开始——都对约 7600 个文件逐个 lstat，玩家机上冷缓存 / Windows 杀毒逐个扫要几秒）。只在没装过 / 没装完（无安装标记）时
    #   持锁从 App 包解一次；引擎号随每版变，更新 S2Arm 自然解新的一份。副本里个别文件被外部改了（#304 宿主 Info.plist）：
    #   真用到那件产物时 artifact 只核它自己的文件、当场重解；别的文件坏了由用到它的那一步照实报
    if not _ready(destination):
        with _install_lock(root):
            if not _ready(destination):
                _reinstall(c, source, manifest, root, destination, identity)
    c.engine = destination
    _retain(c, root, identity)
    c.require_source()


def _ready(destination):
    """副本装好了：看安装标记，不逐文件复核"""
    return read(destination / ".installed.json", {}).get("schema") == 2


def _skip(files, mark):
    """清单去掉安装标记里 bundleMismatch 记的文件（App 包里本来就对不上、装时已提示照常继续的）；没记就原样"""
    accepted = set(mark.get("bundleMismatch") or [])
    return {k: v for k, v in (files or {}).items() if k not in accepted} if accepted and isinstance(files, dict) else files


def _bundle_mismatch(c, source, files):
    """App 包里和清单对不上（缺失 / 不是普通文件 / 大小不同）的文件名，逐个核（只在整份校验没过时走这里）"""
    from build import validate_files
    bad = []
    for name, expected in (files or {}).items():
        try:
            validate_files(c, source, {name: expected})
        except Failure as e:
            if e.code != "runtime_invalid":
                raise
            bad.append(name)
    return bad


@contextlib.contextmanager
def _install_lock(root, timeout=1800):
    """同一引擎目录的挪开 / 重解只许一个作业做（跨进程：filelock.held，与库锁同一实现）。等别的作业解完最多 timeout 秒（解一份几秒到一两分钟）"""
    import os
    import time
    import filelock
    root.mkdir(parents=True, exist_ok=True)
    try:
        with filelock.held(root / ".install.lock", wait_s=timeout, holder=dict(operation="prepareEngine", pid=os.getpid(), startedAt=round(time.time(), 3))):
            yield
    except filelock.Busy as busy:
        raise Failure("另一个任务正在初始化内置 S2Arm 引擎，等了太久，请稍后重试。", internal=f"引擎安装锁占锁者：{busy.holder}") from None  # 非玩家句


def _reinstall(c, source, manifest, root, destination, identity):
    """持 _install_lock 调：坏副本（或没装完的）挪开，从 App 包解一份新的。
    App 包本身的文件和清单对不上（11-17 维护者：校验不过不整个拒绝，提示后照常继续）：黄字提示是哪几个、建议重装 S2Arm，照样解出来用；
    对不上的文件名记进安装标记 bundleMismatch，之后复核跳过它们（不然每次用都判「被改过」、反复重解）。真用到时缺东西由那一步照实报"""
    from build import clone_tree, validate_files
    if destination.exists():
        _set_aside(c, root, destination, "已装的内置引擎文件被改过" if read(destination / ".installed.json", {}).get("schema") == 2 else "上次没装完的内置引擎")  # 非玩家句
    c.begin("初始化内置 S2Arm 引擎")
    mismatch = []
    try:
        validate_files(c, source, manifest.get("files"))
    except Failure as e:
        if e.code != "runtime_invalid":
            raise
        mismatch = _bundle_mismatch(c, source, manifest.get("files"))
        note = f"S2Arm 应用里的内置引擎有 {len(mismatch)} 个文件和清单对不上（如 {'、'.join(mismatch[:3])}），照常继续；后面出包或开游戏要是出错，重新安装完整的 S2Arm 一般就好。"  # 非玩家句
        c.diagnostic(note, "engine_incomplete", severity="warning", internal="；".join(mismatch[:50]))
    temporary = destination.with_name(identity + "." + uuid.uuid4().hex + ".partial")
    temporary.mkdir(parents=True)
    try:
        clone_tree(c, source, temporary)   # v0.2.3 清理：不再对刚拷出的副本再核一遍——源刚核过，clone_tree 拷错会自己报
        atomic(temporary / ".installed.json", dict(schema=2, id=identity, **({"bundleMismatch": mismatch} if mismatch else {})))
        c.check()
        os.rename(temporary, destination)
    finally:
        if temporary.exists():
            import layout
            layout.remove_tree(temporary)


# ---- 引擎副本放哪、留几份（游戏库结构 P3）----
# 原来每版一份放 <私有目录>/engines/<引擎号>/、从不清（约 4 GB / 版）。现在放默认位置的 hosts/engine.noindex/<引擎号>/，只留在用的一份和上一份
# （上一份给升级当口还在跑的旧版作业、以及回退旧版 App 时直接用，不用重解）。库还没建好（setup 之前）退回私有目录 engines.noindex/；
# 建库后由 install 从 App 包解进新位置，旧位置的副本没人用了就删（_drop_old_copies）。
# 目录名带 .noindex：副本里的 Binaries/S2ArmGame.app 不被聚焦收录，菜单 / 启动台不再出一排「S2Arm Game」（#1126 / #2024，宿主同理 layout.HOSTS_MAC）

def engines_root(c):
    from core import default_home
    home = default_home(c.private, c.library)
    return home / "engines.noindex" if home == c.private else home / "hosts" / "engine.noindex"


def _old_roots(c, root):
    """以前放过引擎副本、现在不再用的位置：私有目录 engines/（P3 之前）、engines.noindex/（建库前解的），默认位置 hosts/engine/（#1126 之前）"""
    from core import default_home
    home = default_home(c.private, c.library)
    return [p for p in (c.private / "engines", c.private / "engines.noindex", home / "hosts" / "engine") if p != root]


STALE_SECONDS = 24 * 3600   # 旧位置里的副本多久没用才删：长出包也在这之内结束（出包 ≤30 分钟硬线）


def _drop_old_copies(c, root):
    """旧位置（_old_roots）里的副本在没人用之后清掉；新位置没有这一版就由 install 从 App 包重解（APFS 克隆几秒）。
    不改名搬、不当场删：同一时刻别的作业可能正用着那份副本，或者正把一份解到 <号>.<随机>.partial（v0.2.0 前回归：启动时 preflight 在库建好前开始解，
    紧接着建库后的 keys / catalog 作业把私有 engines/ 整个删了，preflight 核自己解到一半的副本报「缺失或大小不符：.git/COMMIT_EDITMSG」）。
    只删最后一次用过（.installed.json / .last-used 的修改时刻）超过 STALE_SECONDS 的完整副本；.partial / .broken 由解它的作业自己收拾，
    崩溃留下的超过同样时长也删"""
    import time
    now = time.time()
    for old in _old_roots(c, root):
        if old.is_symlink() or not old.is_dir():
            continue
        for d in old.iterdir():
            if d.is_symlink() or not d.is_dir():
                continue
            try:
                used = max((p.stat().st_mtime for p in (d / ".installed.json", d / ".last-used", d) if p.exists()), default=0)
            except OSError:
                continue
            if now - used > STALE_SECONDS:
                shutil.rmtree(d, ignore_errors=True)
        try:
            old.rmdir()   # 空了才删
        except OSError:
            pass


def _retain(c, root, identity):
    """hosts/engine.noindex 下只留在用的这份 + 上一份（按 .last-used 时刻取最近用过的另一份）；在用的这份每次装引擎时记一次时刻"""
    stamp = root / identity / ".last-used"
    try:
        stamp.touch()   # 私有目录里的副本也记：_drop_old_copies 按它判断有没有人还在用
    except OSError:
        return
    if root.name != "engine.noindex":
        return
    others = []
    for d in root.iterdir():
        if d.name == identity or d.is_symlink() or not d.is_dir():
            continue
        if d.name.endswith(".partial"):
            continue   # 别的作业正在解的
        try:
            used = (d / ".last-used").stat().st_mtime
        except OSError:
            used = 0
        others.append((used, d.name, d))
    for _, _, d in sorted(others, reverse=True)[1:]:
        shutil.rmtree(d, ignore_errors=True)


def _intact(c, root, manifest, files=None, full=False):
    """副本里这些文件（缺省清单全部）在、是普通文件、大小对（full 再核摘要）"""
    from build import validate_files
    try:
        validate_files(c, root, files if files is not None else manifest.get("files"), full)
        return True
    except Failure as e:
        if e.code != "runtime_invalid":
            raise
        c.emit("message", "内置引擎副本校验没过：" + str(e).rsplit("：", 1)[-1])  # 非玩家句
        return False


def _set_aside(c, root, destination, why):
    """坏副本改名挪开（同卷改名；正在用它的别的作业照常读完），随后删掉；install 接着从 App 包重解"""
    c.emit("message", why + "，从 S2Arm 应用里重新解出一份")  # 非玩家句
    broken = destination.with_name(destination.name + "." + uuid.uuid4().hex + ".broken")
    try:
        os.rename(destination, broken)
    except OSError:
        return   # 别的作业刚挪走 / 正在重解
    shutil.rmtree(broken, ignore_errors=True)


def artifact(c, name, optional=False):
    """取内置产物目录。optional=True：清单压根没列这项（如 Intel 出包 App 没有 Mac 宿主）返回 None；列了但文件缺失/被改仍报错。"""
    if c.r.get("engineBundle") and not (c.engine / "engine.json").is_file():
        # 发版应用里本作业在用的引擎副本不在了（被别的作业收走 / 重解中）：重新定位一次（install 持锁装好或找到现成的），不当成「没有内置产物」
        c.emit("message", "内置引擎副本不在原处，重新定位")
        install(c)
    manifest = read(c.engine / "engine.json", {})
    if not manifest:
        return None
    prefix = "Binaries/" + name
    files = {p: v for p, v in manifest.get("files", {}).items() if p.startswith(prefix + "/")}
    if not files:
        if optional and c.r.get("engineBundle"):
            return None
        raise Failure("应用内置引擎产物缺失，请重新安装完整应用。")
    files = _skip(files, read(c.engine / ".installed.json", {}))   # App 包里本来就对不上、装时已提示过的不再核（_reinstall）
    if files and not _intact(c, c.engine, manifest, files):
        if not c.r.get("engineBundle"):   # 源码树开发：没有 App 包可重解，照原样报
            from build import validate_files
            validate_files(c, c.engine, files)
        # 已装副本里这件产物被改过（#304）：持锁再核一次（别的作业可能正在重解、刚换上新的），还不对就从 App 包重解整份引擎再核；
        #   App 包本身坏了由 _reinstall 报「重新安装 S2Arm」
        source = Path(c.r["engineBundle"]).resolve()
        bundle = read(source / "engine.json", {})
        with _install_lock(c.engine.parent):
            if not _intact(c, c.engine, manifest, files):
                c.emit("message", "内置引擎里的 " + name + " 被改过")  # 非玩家句
                _reinstall(c, source, bundle, c.engine.parent, c.engine, bundle.get("id", c.engine.name))
        from build import validate_files
        left = _skip(files, read(c.engine / ".installed.json", {}))
        if left:
            validate_files(c, c.engine, left)
    return c.engine / prefix
