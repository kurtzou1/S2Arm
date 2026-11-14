"""Windows 短入口：出包工作区经短路径访问，避开 MAX_PATH。
%LOCALAPPDATA%\\S2A\\j\\<4 位短号> 是一个 0 字节目录联接，指向玩家选的目录；临时文件、产物、缓存都实际落在玩家的目录里，盘根不留东西。
每个任务开始建、结束拆（成功 / 失败都拆）；被强杀的残留靠旁边的 .pid 记录识别，下次 enter 或启动器空闲时 sweep。拆除只删联接本身，绝不进目标。
短号由目标路径算出，同一目录每次相同（阶段键里的路径稳定）；已被另一个活着的任务占用就顺延，任务之间不串。
环境变量 S2A_SHORT_ROOTS（长路径<TAB>短路径，一行一对）给 winlong 和子进程：realpath 展开联接后映射回短路径；给玩家看的路径用 to_long 换回。
建不了联接（入口所在卷不是 NTFS 等）时返回 None，调用方照旧用长路径，并打一行说明原因。"""
from __future__ import annotations

import atexit
import hashlib
import ntpath
import os
import sys

from .winlong import parse_table, to_short   # noqa: F401  映射规则放 winlong：子进程的 sitecustomize 按文件路径加载它，不依赖 pack 包

ENV = "S2A_SHORT_ROOTS"
ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"


def entry_dir(env=None):
    base = (env if env is not None else os.environ).get("LOCALAPPDATA")
    return ntpath.join(base, "S2A", "j") if base else None


def codes(target):
    """目标路径 → 候选短号序列：第一个由路径决定，被占用时顺延"""
    n = int(hashlib.sha256(ntpath.normcase(target).encode("utf-8", "surrogatepass")).hexdigest()[:12], 16)
    size = len(ALPHABET) ** 4
    for i in range(64):
        v, s = (n + i) % size, ""
        for _ in range(4):
            v, d = divmod(v, len(ALPHABET))
            s = ALPHABET[d] + s
        yield s


def group_targets(paths):
    """要访问的工作区 → 联接目标：同盘的取公共上级（通常是游戏库目录），一个入口够用"""
    by_drive = {}
    for p in paths:
        by_drive.setdefault(ntpath.normcase(ntpath.splitdrive(p)[0]), []).append(p)
    return [ntpath.commonpath(g) if len(g) > 1 else g[0] for g in by_drive.values()]


def is_unc_path(path):
    """Windows directory junctions cannot target UNC shares; callers must keep or copy the real path."""
    try:
        drive, _ = ntpath.splitdrive(os.fspath(path))
    except TypeError:
        return False
    return drive.startswith("\\\\")


def junction_targets(paths):
    """目录联接只支持本地卷；UNC 网络共享保留原路径，不能映射到坏掉的联接。"""
    return [target for target in group_targets(paths) if not is_unc_path(target)]


def to_long(path, table):
    """短路径 → 玩家路径（界面、日志、产物里的联接目标都用它）"""
    text = str(path)
    low = ntpath.normcase(text)
    for _, long, short in table:
        key = ntpath.normcase(short)
        if low == key or low.startswith(key + "\\"):
            return long + text[len(short):]
    return text


def table_now():
    return parse_table(os.environ.get(ENV, ""))


def show(text):
    """给玩家看的文字里，短入口一律换回玩家路径"""
    out = str(text)
    for _, long, short in table_now():
        out = out.replace(short, long)
    return out


def _is_ntfs(path):
    import ctypes as C
    k = C.WinDLL("kernel32", use_last_error=True)
    fs = C.create_unicode_buffer(64)
    return bool(k.GetVolumeInformationW(ntpath.splitdrive(path)[0] + "\\", None, 0, None, None, None, fs, 64)) and fs.value.upper() == "NTFS"


def _alive(pid):
    import ctypes as C
    k = C.WinDLL("kernel32", use_last_error=True)
    k.OpenProcess.restype = C.c_void_p
    k.CloseHandle.argtypes = [C.c_void_p]
    k.GetExitCodeProcess.argtypes = [C.c_void_p, C.c_void_p]
    h = k.OpenProcess(0x1000, False, pid)
    if not h:   # 打不开不等于不在：拒绝访问（5）= 进程在、只是查不了，入口照留；只有「没有这个进程」（87）才算死（审计 P2-217）
        return C.get_last_error() == 5
    code = C.c_ulong()
    ok = k.GetExitCodeProcess(h, C.byref(code))
    k.CloseHandle(h)
    return bool(ok) and code.value == 259   # STILL_ACTIVE


def _is_junction(path):
    try:
        return os.path.isjunction(path)
    except (AttributeError, OSError):
        return False


def remove_entry(link):
    """拆入口：只删联接本身（os.rmdir 对联接只删联接），绝不进目标；不是联接就不动"""
    if _is_junction(link):
        os.rmdir(link)
    try:
        os.remove(link + ".pid")
    except OSError:
        pass


def _owner(link):
    try:
        with open(link + ".pid", encoding="ascii") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def sweep(root=None, alive=_alive):
    """拆掉崩溃残留：记录的进程已不在的入口；没有 .pid 的联接也算残留；写了 .pid、联接还没建成就被杀的，进程不在就删 .pid（审计 P2-217）。→ 拆了几个"""
    root = root or entry_dir()
    n = 0
    try:
        names = os.listdir(root)
    except (OSError, TypeError):
        return 0
    for name in names:
        if name.endswith(".pid"):
            link = os.path.join(root, name[:-4])
            pid = _owner(link)
            if os.path.exists(link + ".pid") and not os.path.lexists(link) and (pid is None or not alive(pid)):   # 联接那一支已连 .pid 一起拆的不重复算
                remove_entry(link)
                n += 1
            continue
        link = os.path.join(root, name)
        pid = _owner(link)
        if _is_junction(link) and (pid is None or not alive(pid)):
            remove_entry(link)
            n += 1
    return n


def remap_env(environ, long_root, short_root):
    """环境变量里指向 long_root（或它下面）的路径改成经 short_root 访问；→ 改了的变量名。
    作业层把工具缓存（<库>/tool-cache：直连 / 翻译缓存 S2A_RUN_ROOT、nxaot / vpx … 等 cache/*）用环境变量传给出包链，
    游戏库搬进深目录后这些路径过 MAX_PATH（v0.3.0 win_cases deep：直连库抽取在 <库>/tool-cache/run/s2arm/cache/direct/… 下失败）"""
    root = ntpath.normcase(ntpath.abspath(long_root)).rstrip("\\")
    changed = []
    for key, value in list(environ.items()):
        if not value or not ntpath.isabs(value):
            continue
        norm = ntpath.normcase(ntpath.abspath(value))
        if norm == root or norm.startswith(root + "\\"):
            environ[key] = short_root + ntpath.abspath(value)[len(root):]
            changed.append(key)
    return changed


def enter(*paths):
    """给这些工作区建短入口；→ {原路径: 短路径}，建不了 → None（已打印原因）。设 S2A_SHORT_ROOTS，进程退出时拆"""
    import _winapi
    full = [ntpath.abspath(str(p)) for p in paths if p]
    root = entry_dir()
    if not root:
        print("【黄】没有 LOCALAPPDATA，建不了短路径入口，仍用长路径", file=sys.stderr)
        return None
    made = []
    try:
        if not _is_ntfs(root):
            print("【黄】应用数据所在卷不是 NTFS，建不了目录联接，仍用长路径", file=sys.stderr)
            return None
        os.makedirs(root, exist_ok=True)
        sweep(root)
        rows, mapping = [], {}
        for p in full:
            os.makedirs(p, exist_ok=True)
        for target in junction_targets(full):
            for code in codes(target):
                link = ntpath.join(root, code)
                if os.path.lexists(link):
                    continue   # 被另一个任务占用，顺延
                try:
                    with open(link + ".pid", "x", encoding="ascii") as f:
                        f.write(str(os.getpid()))
                except FileExistsError:
                    continue   # 另一个任务刚占了这个短号（或残留还活着），顺延；不让整次退回长路径（审计 P2-217）
                made.append(link)
                _winapi.CreateJunction(target, link)
                rows.append(f"{target}\t{link}")
                break
            else:
                raise OSError("短号用尽")
        table = parse_table("\n".join(rows))
        for p in full:
            mapping[p] = to_short(p, table)
    except OSError as error:
        for link in made:
            remove_entry(link)
        print(f"【黄】建不了短路径入口（{error}），仍用长路径", file=sys.stderr)
        return None
    os.environ[ENV] = "\n".join(rows)
    atexit.register(leave, made)
    return mapping


def leave(links):
    os.environ.pop(ENV, None)
    for link in links:
        try:
            remove_entry(link)
        except OSError:
            pass


if __name__ == "__main__":   # 启动器空闲时扫崩溃残留：python -m pack.orch.shortroot sweep
    if sys.argv[1:] == ["sweep"]:
        print(f"拆掉残留入口 {sweep()} 个")
    else:
        sys.exit("用法：python -m pack.orch.shortroot sweep")
