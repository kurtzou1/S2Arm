#!/usr/bin/env python3
"""Directory snapshot with no-clobber staging on Linux and macOS EXDEV.

The destination parent must be controlled by the caller. Temporary staging is
mode 0700; a concurrently hostile process with the same UID is outside this
boundary. Inside staging, directory/file creation remains exclusive and uses
no-follow descriptors. Linux publishes the complete absent destination with
renameat2(RENAME_NOREPLACE); macOS keeps normal clonefile behavior and publishes
each EXDEV / ENOTSUP fallback item with renamex_np(RENAME_EXCL). When the volume
does not support exclusive rename (exFAT on macOS), publication falls back to
"rename only if the target is absent"—the private staging directory keeps the
same-UID race outside this boundary. Traversal holds a constant number of
descriptors. Stale staging cleanup assumes users of a parent share the same PID
namespace; the parent must not be shared between containers with separate PID
namespaces. The published Linux snapshot root retains mode 0700, like the staging
root. Regular-file and directory mode and timestamps are copied; directory owner
write is added for disposable snapshots. Symlink timestamps are copied when the
host supports it. File/directory extended attributes are best effort where Python
and the filesystem expose them; ACLs are not guaranteed by this fallback.

macOS exFAT stores Finder metadata as AppleDouble ``._*`` sidecars next to every
file. Those names are skipped as content, and ENOENT while removing a staging
tree (the sidecar vanishing with its data file) is treated as already gone.
"""
import ctypes, errno, os, re, shutil, stat, sys, tempfile, time

REPORT = len(sys.argv) > 1 and sys.argv[1] == '--report'   # --report：最后一行打出克隆走了哪条路（同卷 APFS clonefile / 跨卷或卷不支持克隆的普通拷贝），调用方记进日志
if REPORT: del sys.argv[1]
ROUTE = {'clone': 0, 'copy': 0}
src, dst, skip = sys.argv[1], sys.argv[2], set(sys.argv[3:])
src = os.path.realpath(src)
dst = os.path.abspath(dst)
dst_real = os.path.realpath(dst)
def overlap(a, b):
    try:
        c = os.path.commonpath((a, b))
        return c in (a, b)
    except ValueError:
        return False
if not os.path.isdir(src) or overlap(src, dst_real):
    print('克隆失败：源目录不存在或源与目标重叠', file=sys.stderr); sys.exit(1)
platform = sys.platform
if platform != 'darwin' and not platform.startswith('linux') and platform != 'win32':
    print('克隆失败：不支持的宿主', file=sys.stderr); sys.exit(1)
libc = ctypes.CDLL('libc.dylib' if platform == 'darwin' else None, use_errno=True) if platform != 'win32' else None


def appledouble(name):
    """macOS 在 exFAT / 部分外接盘上为每个文件生成的 AppleDouble 附属名（._main 配 main）。不是游戏内容。"""
    return isinstance(name, str) and name.startswith('._')


def publish_noreplace(source, target):
    try:
        if platform == 'darwin':
            result = libc.renamex_np(os.fsencode(source), os.fsencode(target), 4)  # RENAME_EXCL
        else:
            result = libc.renameat2(-100, os.fsencode(source), -100, os.fsencode(target), 1)  # RENAME_NOREPLACE
    except AttributeError as exc:
        raise OSError(errno.ENOSYS, '宿主缺少原子不覆盖重命名') from exc
    if result != 0:
        e = ctypes.get_errno()
        if platform == 'darwin' and e in (errno.ENOTSUP, errno.EOPNOTSUPP):
            # exFAT 等外接盘不支持 RENAME_EXCL（实测回 errno 45）：先确认目标不存在再普通改名。
            #   同 UID 的并发恶意进程本就不在防护边界内（见文件头），这条退路不越出原边界
            if os.path.lexists(target):
                raise OSError(errno.EEXIST, os.strerror(errno.EEXIST), target)
            os.rename(source, target)
            return
        raise OSError(e, os.strerror(e), target)


def copy_xattrs(source_fd, target_fd):
    if not all(hasattr(os, name) for name in ('listxattr', 'getxattr', 'setxattr')):
        return
    ignored = (errno.ENOTSUP, errno.EOPNOTSUPP, errno.EPERM, errno.EACCES, errno.ENODATA, errno.EINVAL)
    try:
        names = os.listxattr(source_fd)
    except OSError as exc:
        if exc.errno in ignored: return
        raise
    for name in names:
        try: os.setxattr(target_fd, name, os.getxattr(source_fd, name))
        except OSError as exc:
            if exc.errno not in ignored: raise


def open_parent(root_fd, components, follow_first=False):
    """Open a directory chain without retaining one descriptor per level."""
    fd = os.dup(root_fd)
    try:
        for i, name in enumerate(components):
            flags = os.O_RDONLY | os.O_DIRECTORY
            if not (follow_first and i == 0): flags |= os.O_NOFOLLOW
            new = os.open(name, flags, dir_fd=fd)
            os.close(fd); fd = new
        return fd
    except BaseException:
        os.close(fd)
        raise


def path_max(p):
    # exFAT 等卷不答 PC_PATH_MAX（EINVAL，11-02 出包线：玩家游戏库在外接 exFAT 盘上整份克隆失败）：按宿主 PATH_MAX（macOS / Linux 都 ≥ 1024）
    try: return os.pathconf(p, 'PC_PATH_MAX')
    except OSError: return 1024


def copy_one(source_root_fd, source_name, target_root_fd, target_name, _depth, follow_top):
    # Tasks carry names, not open fds. The caller controls the parent and keeps
    # source input stable for the duration of the copy.
    stack = [('copy', (source_name,), (target_name,), None)]
    source_limit = path_max(src)
    target_limit = path_max(dst if platform == 'darwin' else os.path.dirname(dst))
    while stack:
        operation, source_parts, target_parts, remembered = stack.pop()
        # Bound the complete paths even though openat walks each component.
        if (len(os.fsencode(src)) + sum(len(os.fsencode(x)) + 1 for x in source_parts) >= source_limit or
            len(os.fsencode(dst)) + sum(len(os.fsencode(x)) + 1 for x in target_parts) >= target_limit):
            raise OSError(errno.ENAMETOOLONG, '路径超过宿主 PATH_MAX')
        source_parent = open_parent(source_root_fd, source_parts[:-1], follow_top)
        try:
            target_parent = open_parent(target_root_fd, target_parts[:-1])
            try:
                name, dest = source_parts[-1], target_parts[-1]
                follow = follow_top and len(source_parts) == 1
                before = os.stat(name, dir_fd=source_parent, follow_symlinks=follow)
                if operation == 'finish':
                    inp = os.open(name, os.O_RDONLY | os.O_DIRECTORY | (0 if follow else os.O_NOFOLLOW), dir_fd=source_parent)
                    try:
                        actual = os.fstat(inp)
                        if (actual.st_dev, actual.st_ino) != remembered:
                            raise OSError(errno.ESTALE, '源目录已变化', name)
                        out = os.open(dest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=target_parent)
                        try:
                            copy_xattrs(inp, out)
                            os.fchmod(out, stat.S_IMODE(actual.st_mode) | stat.S_IWUSR)
                            os.utime(out, ns=(actual.st_atime_ns, actual.st_mtime_ns))
                        finally: os.close(out)
                    finally: os.close(inp)
                    continue
                if stat.S_ISLNK(before.st_mode):
                    os.symlink(os.readlink(name, dir_fd=source_parent), dest, dir_fd=target_parent)
                    if os.utime in os.supports_dir_fd and os.utime in os.supports_follow_symlinks:
                        try: os.utime(dest, ns=(before.st_atime_ns, before.st_mtime_ns), dir_fd=target_parent, follow_symlinks=False)
                        except (NotImplementedError, OSError) as exc:
                            if isinstance(exc, OSError) and exc.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.EPERM, errno.EINVAL): raise
                    continue
                if not (stat.S_ISDIR(before.st_mode) or stat.S_ISREG(before.st_mode)):
                    raise OSError(errno.EINVAL, '不支持的文件类型', name)
                flags = os.O_RDONLY | (0 if follow else os.O_NOFOLLOW)
                if stat.S_ISDIR(before.st_mode): flags |= os.O_DIRECTORY
                inp = os.open(name, flags, dir_fd=source_parent)
                try:
                    actual = os.fstat(inp)
                    if (actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino):
                        raise OSError(errno.ESTALE, '源文件已变化', name)
                    if stat.S_ISDIR(actual.st_mode):
                        os.mkdir(dest, 0o700, dir_fd=target_parent)
                        stack.append(('finish', source_parts, target_parts, (actual.st_dev, actual.st_ino)))
                        for entry in reversed(sorted(os.listdir(inp))):
                            if appledouble(entry) or entry in skip: continue
                            stack.append(('copy', source_parts + (entry,), target_parts + (entry,), None))
                    else:
                        out = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=target_parent)
                        try:
                            with os.fdopen(os.dup(inp), 'rb') as f, os.fdopen(os.dup(out), 'wb') as g:
                                shutil.copyfileobj(f, g, length=1024 * 1024)
                            copy_xattrs(inp, out)
                            os.fchmod(out, stat.S_IMODE(actual.st_mode))
                            os.utime(out, ns=(actual.st_atime_ns, actual.st_mtime_ns))
                        finally: os.close(out)
                finally: os.close(inp)
            finally: os.close(target_parent)
        finally: os.close(source_parent)


def reject_followed_overlap(source_fd, name, target, staging):
    st = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
    if not stat.S_ISLNK(st.st_mode): return
    resolved = os.path.realpath(os.path.join(src, name))
    if overlap(resolved, os.path.realpath(target)) or overlap(resolved, os.path.realpath(staging)):
        raise OSError(errno.EINVAL, '源软链与目标或暂存目录重叠', name)


def remove_stage(path):
    """Remove a private tree without retaining an fd per level.

    On exFAT, creating ``payload`` also creates ``._payload``. Renaming or
    unlinking the data file can make the sidecar vanish before we reach it in
    the directory listing; treat that ENOENT as already removed.
    """
    root = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        stack = [((), False)]
        while stack:
            parts, finish = stack.pop()
            if finish:
                parent = open_parent(root, parts[:-1])
                try:
                    try: os.rmdir(parts[-1], dir_fd=parent)
                    except FileNotFoundError: pass
                finally: os.close(parent)
                continue
            fd = open_parent(root, parts)
            try:
                os.fchmod(fd, stat.S_IMODE(os.fstat(fd).st_mode) | 0o700)
                if parts: stack.append((parts, True))
                for name in os.listdir(fd):
                    try:
                        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    if stat.S_ISDIR(st.st_mode):
                        stack.append((parts + (name,), False))
                    else:
                        try: os.unlink(name, dir_fd=fd)
                        except FileNotFoundError: pass
            finally: os.close(fd)
    finally: os.close(root)
    try: os.rmdir(path)
    except FileNotFoundError: pass


def sweep_stale(parent):
    """Remove only our UID's named stages whose pid is absent in this namespace."""
    for name in os.listdir(parent):
        match = re.fullmatch(r'\.s2a-clonedir-([1-9][0-9]*)-([0-9]+)-[A-Za-z0-9_-]+', name)
        if not match: continue
        path = os.path.join(parent, name)
        try: st = os.lstat(path)
        except FileNotFoundError: continue
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid(): continue
        pid = int(match.group(1))
        try: os.kill(pid, 0)
        except ProcessLookupError:
            print(f'清理失主暂存：{name}', file=sys.stderr)
            remove_stage(path)
        except PermissionError: pass


def private_stage(parent):
    # Parent ownership/access is the caller's responsibility; 0700 is other-UID isolation.
    return tempfile.mkdtemp(prefix=f'.s2a-clonedir-{os.getpid()}-{time.time_ns()}-', dir=parent)


def linux_snapshot():
    parent = os.path.dirname(dst)
    sweep_stale(parent)
    stage = private_stage(parent)
    try:
        source_fd = os.open(src, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            stage_fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                for name in sorted(os.listdir(source_fd)):
                    if name in skip or appledouble(name): continue
                    reject_followed_overlap(source_fd, name, dst, stage)
                    copy_one(source_fd, name, stage_fd, name, 1, True)
                # Keep the unpublished tree private throughout construction.
                publish_noreplace(stage, dst)
            finally: os.close(stage_fd)
        finally: os.close(source_fd)
    finally:
        if os.path.isdir(stage): remove_stage(stage)


def mac_fallback(source_fd, name, target):
    stage = private_stage(dst)
    try:
        reject_followed_overlap(source_fd, name, target, stage)
        stage_fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: copy_one(source_fd, name, stage_fd, 'payload', 1, True)
        finally: os.close(stage_fd)
        publish_noreplace(os.path.join(stage, 'payload'), target)
    finally:
        if os.path.isdir(stage): remove_stage(stage)


def mac_snapshot():
    os.makedirs(dst, exist_ok=True)
    sweep_stale(dst)
    source_fd = os.open(src, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    made = []; bad = 0
    try:
        for name in sorted(os.listdir(source_fd)):
            if name in skip or appledouble(name): continue
            target = os.path.join(dst, name)
            try:
                reject_followed_overlap(source_fd, name, target, dst)
                if libc.clonefile(os.fsencode(os.path.join(src, name)), os.fsencode(target), 0) != 0:
                    e = ctypes.get_errno()
                    if e not in (errno.EXDEV, errno.ENOTSUP): raise OSError(e, os.strerror(e), target)
                    mac_fallback(source_fd, name, target); ROUTE['copy'] += 1
                else: ROUTE['clone'] += 1
                made.append(target)
            except OSError as exc:
                print(f'克隆失败：{name}：{exc}', file=sys.stderr); bad += 1
    finally: os.close(source_fd)
    for root in made:
        if os.path.islink(root) or not os.path.isdir(root): continue
        if not os.stat(root).st_mode & stat.S_IWUSR: os.chmod(root, os.stat(root).st_mode | stat.S_IWUSR)
        for d, ds, _ in os.walk(root):
            for n in ds:
                p = os.path.join(d, n)
                if not os.path.islink(p) and not os.stat(p).st_mode & stat.S_IWUSR: os.chmod(p, os.stat(p).st_mode | stat.S_IWUSR)
    return bad

def win_snapshot():
    """Windows 出包机（#1100 W6，11-04 Windows 出包线）：整棵拷进目标旁的暂存目录，再 os.rename 发布。Windows 的重命名（MoveFileEx 不带
    REPLACE_EXISTING）目标已存在就失败，即原子不覆盖发布，同 Linux renameat2(RENAME_NOREPLACE)。软链原样拷（不跟随）；暂存目录名带进程号，失主的下次清掉"""
    parent = os.path.dirname(dst)
    for name in os.listdir(parent):
        m = re.fullmatch(r'\.s2a-clonedir-([1-9][0-9]*)-[0-9]+-[A-Za-z0-9_-]+', name)
        if m and not pid_alive(int(m.group(1))): shutil.rmtree(os.path.join(parent, name), ignore_errors=True)
    stage = private_stage(parent)
    try:
        shutil.copytree(src, os.path.join(stage, 'payload'), symlinks=True, ignore=lambda d, names: [n for n in names if (os.path.samefile(d, src) and n in skip) or appledouble(n)])
        os.rename(os.path.join(stage, 'payload'), dst)
    finally: shutil.rmtree(stage, ignore_errors=True)


def pid_alive(pid):   # Windows：OpenProcess 能开且还没退出
    k = ctypes.windll.kernel32; h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
    if not h: return False
    code = ctypes.c_ulong(); ok = k.GetExitCodeProcess(h, ctypes.byref(code)); k.CloseHandle(h)
    return bool(ok) and code.value == 259   # STILL_ACTIVE


def report():
    if not REPORT: return
    c, k = ROUTE['clone'], ROUTE['copy']
    print(f'克隆路线：APFS 克隆 {c} 项' if not k else f'克隆路线：普通拷贝 {k} 项（跨卷 / 卷不支持克隆，如 exFAT）' + (f'、APFS 克隆 {c} 项' if c else ''))

try:
    if platform == 'darwin':
        bad = mac_snapshot(); report(); sys.exit(1 if bad else 0)
    if platform == 'win32':
        win_snapshot()
        if REPORT: print('克隆路线：普通拷贝（Windows）')
        sys.exit(0)
    linux_snapshot()
    if REPORT: print('克隆路线：普通拷贝（Linux）')
except (OSError, ValueError) as exc:
    print(f'克隆失败：{exc}', file=sys.stderr); sys.exit(1)
