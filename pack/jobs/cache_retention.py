"""Keep recent complete titles; evict cold reusable entries only under disk pressure.

Logical file sizes are diagnostic only, never a trigger or a freed-space estimate.
The caller holds the library produce lock (build.produce_locks) or the exclusive execution lock: no other trim or build overlaps.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import shutil
import time

KEEP_TITLES = 3
# Same fixed headroom used by library.check_pack_space for a user's single build.
# Do not inherit the maintenance fleet's 130 GiB auto-build gate.
MIN_FREE_BYTES = 10 * 1024**3
HOT_SECONDS = 3600


def retention_policy():
    def integer(name, default, minimum):
        value = os.environ.get(name)
        if value is None:
            return default
        if not re.fullmatch(r'[0-9]+', value) or int(value) < minimum:
            raise ValueError(name + ' 必须是至少 ' + str(minimum) + ' 的整数')  # 非玩家句
        return int(value)
    return dict(keep_titles=integer('S2A_COMPILER_CACHE_KEEP_TITLES', KEEP_TITLES, 1),
                min_free_bytes=integer('S2A_COMPILER_CACHE_MIN_FREE_BYTES', MIN_FREE_BYTES, 0))


def roots(private):
    private = Path(private)
    return ((private / 'cache' / 'air', '.air'),
            (private / 'cache' / 'pso', '.bin'),
            (private / 'run' / 'gal_dl_cache', '.metallib'),
            (private / 'run/s2arm/cache/direct', 'direct'))


def _safe_root(private, path):
    """Do not traverse links, including an intermediate cache/run directory."""
    here = Path(private)
    for part in path.relative_to(here).parts:
        here /= part
        try:
            mode = here.lstat().st_mode
        except FileNotFoundError:
            return 'missing'
        if not stat.S_ISDIR(mode):
            return 'unsafe'
    return 'safe'


def _completed(root, path, suffix):
    """Recognize only existing producer layouts, not arbitrary hash-named files."""
    parts = path.relative_to(root).parts
    name = parts[-1]
    if suffix == 'direct':
        # Direct store (C# dsh_batch build Store, graphics/tools/direct/dsh/batch/Build.cs, S2Arm 11-01; direct_lib.py gives it --cas <title>/store):
        # <title>/store/dshb/<two hex>/<64 hex>.e, one entry per file (a translation or a Metal library), named by the sha256 of its key and filed under
        # its first two hex digits; <title>/store/cpso/ the same layout for the compute pipeline archives (graphics/tools/direct/cs_pipelines.py). Removing one only makes it miss on the next build; <64 hex>.e.tmp<pid>.<thread> is an entry being written, not an entry.
        # <title>/store/<two hex>.pack(.bad) are shards of the former Python store (dmsh_store.py, 10-31 to 11-01): no reader is left, reclaimable the same way
        if len(parts) < 3 or not re.fullmatch(r'[0-9A-F]{16}', parts[0]) or parts[1] != 'store':
            return False
        if len(parts) == 5:
            return parts[2] in ('dshb', 'cpso') and bool(re.fullmatch(r'[0-9a-f]{64}\.e', name)) and parts[3] == name[:2]
        return len(parts) == 3 and bool(re.fullmatch(r'[0-9a-f]{2}\.pack(?:\.bad)?', name))
    if not re.fullmatch(r'[0-9a-f]{64}' + re.escape(suffix), name):
        return False
    key = name[:64]
    if suffix == '.bin':
        return len(parts) == 2 and parts[0] == key[:2]
    prefixes = (key[:2], ('u' if suffix == '.air' else 'b') + key[:2])
    return len(parts) == 3 and parts[0] in ('ios', 'macos') and parts[1] in prefixes


def _signature(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def _touch_title(private, gid, now, cache_roots=None):
    """本款直连缓存仓「最近用过」（同 trim 扫描里对 current_gid 的那一步：dmsh 命中不改修改时间，按整款记）；路径上有链接就不动"""
    for root, suffix in (roots(private) if cache_roots is None else tuple((Path(r), x) for r, x in cache_roots)):
        if suffix != 'direct':
            continue
        base = root / gid / 'store'
        try:
            if _safe_root(private, base) != 'safe':
                continue
            if os.utime in os.supports_follow_symlinks:
                os.utime(base, (now, now), follow_symlinks=False)
            else:
                os.utime(base, (now, now))
        except OSError:
            continue


def trim(private, *, keep_titles=KEEP_TITLES, min_free_bytes=MIN_FREE_BYTES,
         now=None, current_gid=None, free_bytes=None, skip_scan_when_free=False, cache_roots=None):
    """Trim completed cold entries, oldest first; report observed regular-file bytes.

    skip_scan_when_free（出包收尾用，11-16 极速出包定因）：盘余量已不低于底线时一条都不会删，原先照样全量扫一遍
    （Windows 上逐文件 lstat，缓存大时几十秒）——这时只刷新本款「最近用过」、不扫，返回 scanned=False、字节统计为 None。
    要统计数字的调用方（释放空间页）不传它。
    cache_roots（维护方清理用）：直接给 ((缓存根, 后缀), …)，代替按 private 推出的固定布局——缓存根经软链放在另一块盘上时，
    按 private 推的路径带链接、整根不扫；传真实路径（都在 private 之下）才扫得到。余量按 private 所在的盘算

    Only content-addressed compiler outputs are eligible. No directory, link,
    temporary file, unknown payload or recently used entry is removed. Concurrent
    replacement/refresh noticed before unlink is protected. Do not infer Metal
    cache validity or a compilation speedup from this filesystem-only operation.
    """
    for value, minimum in ((keep_titles, 1), (min_free_bytes, 0)):
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
            raise ValueError('invalid compiler cache retention policy')
    if current_gid is not None and not re.fullmatch(r'[0-9A-F]{16}', current_gid):
        raise ValueError('current_gid must be an uppercase 16-digit title ID')
    private = Path(private)
    now = time.time() if now is None else now
    candidates = []
    protected_titles = set()
    free_bytes = free_bytes or (lambda: shutil.disk_usage(private).free)
    if skip_scan_when_free:
        try:
            free_now = free_bytes()
        except OSError:
            free_now = None
        if isinstance(free_now, int) and not isinstance(free_now, bool) and free_now >= min_free_bytes:
            if current_gid is not None:
                _touch_title(private, current_gid, now, cache_roots)
            return dict(keepTitles=keep_titles, protectedTitles=[], minFreeBytes=min_free_bytes, freeBytes=free_now,
                        pressureRemaining=False, diskErrors=0, observedBytes=None, retainedBytes=None,
                        removedBytes=0, removedEntries=0, changedEntries=0, unscannedRoots=0, protectedLinks=0,
                        accountingComplete=True, scanErrors=0, evictionErrors=0, errors=[], scanned=False)
    total = removed = count = skipped = unscanned = links = 0
    errors = []
    scan_errors = eviction_errors = 0
    def record(operation, error, path):
        if len(errors) < 16:
            errors.append(dict(operation=operation, errno=error.errno,
                               path=os.path.relpath(path, private)))
    for root, suffix in (roots(private) if cache_roots is None else tuple((Path(r), x) for r, x in cache_roots)):
        root_incomplete = False
        def scan_error(error):
            nonlocal root_incomplete, scan_errors
            root_incomplete = True
            scan_errors += 1
            record('scan', error, error.filename or root)
        try:
            state = _safe_root(private, root)
        except OSError as error:
            scan_error(error)
            unscanned += 1
            continue
        if state != 'safe':
            unscanned += state == 'unsafe'
            continue
        direct_used = {}
        if suffix == 'direct':
            try:
                for game in root.iterdir():
                    if not re.fullmatch(r'[0-9A-F]{16}', game.name):
                        continue
                    for platform in ('store',):
                        base = game / platform
                        if _safe_root(private, base) != 'safe':
                            continue
                        if game.name == current_gid:
                            # dmsh hits do not touch mtime. Jobs records conservative
                            # whole-title use, never claiming per-entry hit recency.
                            # Windows 的 Python 不支持 os.utime 不跟随链接（NotImplementedError，v0.3.0 Windows 出 iPhone 包必红）：
                            #   上面 _safe_root 已逐级 lstat 核过 base 及其上级都是真目录，不是链接，直接改
                            if os.utime in os.supports_follow_symlinks:
                                os.utime(base, (now, now), follow_symlinks=False)
                            else:
                                os.utime(base, (now, now))
                        direct_used[(game.name, platform)] = base.lstat().st_mtime
            except OSError as error:
                scan_error(error)
        if suffix == 'direct':
            recency = {}
            for (gid, platform), used in direct_used.items():
                recency[gid] = max(recency.get(gid, used), used)
            ordered = sorted(recency, key=lambda gid: (gid != current_gid, -recency[gid], gid))
            protected_titles.update(ordered if root_incomplete else ordered[:keep_titles])
        for directory, dirs, names in os.walk(root, followlinks=False, onerror=scan_error):
            if suffix == 'direct':
                depth = len(Path(directory).relative_to(root).parts)
                if depth == 0:
                    dirs[:] = [d for d in dirs if re.fullmatch(r'[0-9A-F]{16}', d)]
                elif depth == 1:
                    dirs[:] = [d for d in dirs if d == 'store']
            safe_dirs = []
            for name in sorted(dirs):
                path = Path(directory) / name
                try:
                    if stat.S_ISLNK(path.lstat().st_mode):
                        links += 1
                    else:
                        safe_dirs.append(name)
                except OSError as error:
                    scan_error(error)
            dirs[:] = safe_dirs
            for name in sorted(names):
                if suffix == 'direct' and depth < 2:
                    continue  # only the store belongs to this budget
                path = Path(directory) / name
                try:
                    st = path.lstat()
                except OSError as error:
                    scan_error(error)
                    continue
                if not stat.S_ISREG(st.st_mode):
                    links += stat.S_ISLNK(st.st_mode)
                    continue
                total += st.st_size
                # Hash filenames are the existing AIR/PSO/DL producer contract;
                # .tmp suffixes, logs and future formats are deliberately not GC'd.
                used = st.st_mtime
                if suffix == 'direct':
                    relative = path.relative_to(root).parts
                    if len(relative) >= 2:
                        used = max(used, direct_used.get(tuple(relative[:2]), now))
                protected = suffix == 'direct' and relative[0] in protected_titles
                if not protected and _completed(root, path, suffix) and now - used >= HOT_SECONDS:
                    candidates.append((int(used * 1e9), str(path), path, st))
        unscanned += root_incomplete
    before = total
    disk_errors = 0
    def available():
        nonlocal disk_errors
        try:
            value = free_bytes()
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise OSError('invalid disk-free reading')
            return value
        except OSError as error:
            disk_errors += 1
            record('disk-free', error, private)
            return None
    free = available()
    for _, _, path, observed in sorted(candidates):
        if free is None or free >= min_free_bytes:
            break
        try:
            current = path.lstat()
            if _signature(current) != _signature(observed):
                skipped += 1
                continue
            path.unlink()
        except FileNotFoundError:
            skipped += 1
            continue
        except OSError as error:
            eviction_errors += 1
            record('evict', error, path)
            continue
        removed += observed.st_size
        total -= observed.st_size
        count += 1
        free = available()  # APFS clones/sparse files: never add logical removed bytes.
    return dict(scanned=True, keepTitles=keep_titles, protectedTitles=sorted(protected_titles),
                minFreeBytes=min_free_bytes, freeBytes=free,
                pressureRemaining=None if free is None else free < min_free_bytes,
                diskErrors=disk_errors, observedBytes=before, retainedBytes=total,
                removedBytes=removed, removedEntries=count, changedEntries=skipped,
                unscannedRoots=unscanned, protectedLinks=links,
                accountingComplete=not (unscanned or links or skipped or eviction_errors or disk_errors),
                scanErrors=scan_errors, evictionErrors=eviction_errors, errors=errors)


# ---- 工具缓存的旧键（游戏库结构 P3）----
# tool-cache 下 NativeAOT（services/nxaot.sh）、libvpx / libopus / dav1d（services/<库>/build.sh）的整机缓存：每份一个目录
# <平台>-<键…>（如 osx-arm64-1.14.1-ab12cd34ef56-0f1e2d3c），键由引擎源码 / 构建脚本内容算出，引擎一升级旧键就再也命中不了，原来从不清。
# 这些脚本取用即 touch 目录（命中也续时刻），所以「当前引擎用到的键」= 当前引擎装好之后被动过的目录：
#   - 同一缓存同一平台，有当前引擎用过的 → 其余全删（旧引擎的键）；
#   - 当前引擎还没用过这个平台 → 只留最新的一份（引擎升级没改到这个库时键不变，下次照样命中），其余删；
#   - 30 分钟内动过的一律不删（别的作业可能正拿着路径链接，同 tools 里整机 gc 的规矩）；锁目录、.tmp 半成品、链接都不碰。
TOOL_CACHES = ('cache/nxaot', 'cache/vpx', 'cache/opus', 'cache/dav1d',
               'run/s2arm/cache/nxaot', 'run/s2arm/cache/vpx', 'run/s2arm/cache/opus', 'run/s2arm/cache/dav1d')
TOOL_HOT_SECONDS = 1800
_TOOL_ENTRY = re.compile(r'((?:osx|ios|linux|win|android)-[A-Za-z0-9_]+)-[A-Za-z0-9_.-]+')


def prune_tool_keys(work_root, engine_since, *, now=None):
    """按上面的规则删 work_root（core.Context.work_root）下各工具缓存的旧键；engine_since = 当前引擎装好的时刻（None = 源码树开发构建，不清）。
    返回 {removedEntries, removed: [相对路径]}"""
    removed = []
    if engine_since is None:
        return dict(removedEntries=0, removed=removed)
    now = time.time() if now is None else now
    work_root = Path(work_root)
    for rel in TOOL_CACHES:
        root = work_root / rel
        if _safe_root(work_root, root) != 'safe':
            continue
        groups = {}
        try:
            children = list(root.iterdir())
        except OSError:
            continue
        for d in children:
            m = _TOOL_ENTRY.fullmatch(d.name)
            if not m or d.name.endswith('.tmp'):
                continue
            try:
                st = d.lstat()
            except OSError:
                continue
            if not stat.S_ISDIR(st.st_mode):
                continue
            groups.setdefault(m.group(1), []).append((st.st_mtime, d.name, d))
        for entries in groups.values():
            entries.sort(reverse=True)
            used = [e for e in entries if e[0] >= engine_since]
            keep = {e[1] for e in used} if used else {entries[0][1]}
            for mtime, name, d in entries:
                if name in keep or now - mtime < TOOL_HOT_SECONDS:
                    continue
                shutil.rmtree(d, ignore_errors=True)
                if not os.path.lexists(d):
                    removed.append(str(d.relative_to(work_root)))
    return dict(removedEntries=len(removed), removed=removed)


def engine_installed_at(engine):
    """当前引擎副本装好的时刻（embedded.install 写的 .installed.json）；不是装出来的引擎（源码树）→ None"""
    try:
        return (Path(engine) / '.installed.json').stat().st_mtime
    except OSError:
        return None


# 出包用的可重建缓存（DLC 解包 aoc、整包解包 unpack、烘焙 bake、原件版本 srcver）：每个条目是 <款>-<键> 一整个目录，丢了只是下次重解 / 重算。
#   原先各自只按「同款留最新一份」清，全机不设总量：一台出包机的一个运行根里 aoc 就到 82 GB（11-15，玩家机器一样会被吃满）。
#   总量上限按盘算比例、不写死：上限 = BUILD_CACHE_SHARE ×（盘剩余 + 这些缓存现有总量），也就是这些缓存最多占「这块盘上能给它们用的空间」的这一份；
#   超了按最久没用（条目目录的修改时刻，命中时 touch）先删。正在用的不删：1 小时内动过的、这次出包这款的。
# 11-16 起连同 NativeAOT 整机缓存（services/nxaot.sh，键随引擎源码变，每次改服务层多一份）与出壳按树镜像（pack/shell_build.sh shell_src/<树号>，
#   工作树越开越多）一起算总量：两处原来都没有上限（11-16 一台开发机上一次清出 122 份 49.6 GB）。取用时两个脚本都 touch 条目目录，最久没用的先删
BUILD_CACHES = ('cache/aoc', 'cache/unpack', 'cache/bake', 'cache/srcver', 'cache/nxaot', 'shell_src')
BUILD_CACHE_SHARE = 0.25


def _tree_bytes(path):
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):   # 不跟随链接（os.walk 缺省不进链接目录）
        for name in filenames:
            try:
                st = os.lstat(os.path.join(dirpath, name))
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                total += st.st_blocks * 512 if hasattr(st, 'st_blocks') else st.st_size
    return total


def trim_build_caches(run_s2arm, *, current_gid=None, share=None, now=None, free_bytes=None, roots=None):
    """run_s2arm = <运行根>/s2arm。→ 结果字典（上限、清前 / 清后总量、删了几份、释放字节）。只删完整条目（不带 .tmp、不以 . 开头的目录：.lock-* 是取用锁），不跟随链接。
    roots = 要算的缓存目录（缺省 run_s2arm 下 BUILD_CACHES 各项；起局方另指的缓存，如门禁共用的 S2A_CS_CACHE，传它自己）"""
    run_s2arm = Path(run_s2arm)
    share = BUILD_CACHE_SHARE if share is None else share
    env = os.environ.get('S2A_BUILD_CACHE_SHARE')
    if env:
        share = float(env)
    now = time.time() if now is None else now
    entries = []
    for root in ([Path(r) for r in roots] if roots is not None else [run_s2arm / rel for rel in BUILD_CACHES]):
        try:
            if not stat.S_ISDIR(root.lstat().st_mode):
                continue
            names = list(root.iterdir())
        except OSError:
            continue
        for d in names:
            try:
                st = d.lstat()
            except OSError:
                continue
            if not stat.S_ISDIR(st.st_mode) or '.tmp' in d.name or d.name.startswith('.'):
                continue
            entries.append([st.st_mtime, d, _tree_bytes(d)])
    total = sum(e[2] for e in entries)
    try:
        free = free_bytes() if free_bytes else shutil.disk_usage(run_s2arm).free
    except OSError:
        return dict(capBytes=None, totalBytes=total, removedEntries=0, freedBytes=0, error='disk_usage')
    cap = int(share * (free + total))
    removed = freed = 0
    cur = (current_gid or '').lower()
    for mtime, d, size in sorted(entries, key=lambda e: e[0]):
        if total <= cap:
            break
        if now - mtime < HOT_SECONDS or (cur and cur in d.name.lower()):
            continue
        shutil.rmtree(d, ignore_errors=True)
        if not d.exists():
            total -= size; freed += size; removed += 1
    return dict(capBytes=cap, totalBytes=total, removedEntries=removed, freedBytes=freed)


if __name__ == '__main__':   # 出壳 / NativeAOT 脚本写完缓存调：cache_retention.py trim <运行根/s2arm> [<另指的缓存目录>]（给了目录就只算它）
    import json, sys
    if len(sys.argv) not in (3, 4) or sys.argv[1] != 'trim':
        sys.exit('用法：cache_retention.py trim <运行根/s2arm> [<缓存目录>]')  # 非玩家句（开发脚本用法）
    print(json.dumps(trim_build_caches(sys.argv[2], roots=sys.argv[3:] or None), ensure_ascii=False))
