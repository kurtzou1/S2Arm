"""Windows 长路径（玩家反馈 Hades II：[WinError 206] 文件名或扩展名太长）。

系统要开 LongPathsEnabled 才认 260 字符以上的普通路径，玩家机上多半没开、改它又要管理员权限。
这里把文件操作的路径参数在够长时加上 \\\\?\\ 前缀（Windows 官方的长路径写法，不需要系统设置）；短路径原样不动。
只在 Windows 生效。入口：pack.orch 包导入时、作业主程序、子 Python 进程的 sitecustomize（pack/orch/site）。
"""
from __future__ import annotations

import builtins
import io
import ntpath
import os
import stat
import struct

LIMIT = 240   # 留出目录内再拼文件名的余量；系统上限 260
_done = False


def long_path(path):
    """够长的绝对或相对路径 → \\\\?\\ 形式（UNC 用 \\\\?\\UNC\\）；其余原样返回。非路径参数（文件描述符、None、bytes）不动"""
    try:
        s = os.fspath(path)
    except TypeError:
        return path
    if not isinstance(s, str) or len(s) < LIMIT or s.startswith(("\\\\?\\", "\\\\.\\")):
        return path
    full = ntpath.abspath(s)
    return "\\\\?\\UNC\\" + full[2:] if full.startswith("\\\\") else "\\\\?\\" + full


class _Entry:
    """目录项：路径按调用方给的写法，其余照原 DirEntry（前缀只在系统调用里用，调用方拿到带前缀的路径后 relative_to 比不上，#138）"""
    __slots__ = ("_entry", "path", "name")

    def __init__(self, entry, path):
        self._entry, self.path, self.name = entry, path, entry.name

    def __getattr__(self, name):
        return getattr(self._entry, name)

    def __fspath__(self):
        return self.path


class _Scan:
    def __init__(self, entries, parent):
        self._entries, self._parent = entries, parent

    def __iter__(self):
        return self

    def __next__(self):
        entry = next(self._entries)
        return _Entry(entry, ntpath.join(self._parent, entry.name))

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self._entries.close()


def _wrap_scandir(module):
    original = module.scandir

    def scandir(path="."):
        converted = long_path(path)
        return original(path) if converted is path else _Scan(original(converted), os.fspath(path))

    scandir.__doc__ = original.__doc__
    module.scandir = scandir


def _name_paths(error, paths):
    """系统调用报错没带路径时，补上这次调用的路径参数（调用方给的写法，不是补了长路径前缀的那份）。
    #df9fd6：_winapi.CopyFile2（shutil.copy2 的 Windows 路径）报 WinError 112「磁盘空间不足」不带文件名，失败归因只能去量日志所在的盘
    （库盘还剩 226.7 GB）、不采信盘满，玩家看到「未归类」；补上源 / 目标之后，归因按点名的路径量到真正写满的那块盘"""
    if error.filename is not None:
        return
    names = [os.fspath(p) for p in paths if isinstance(p, (str, bytes, os.PathLike))]
    if names:
        error.filename = names[0]
        if len(names) > 1:
            error.filename2 = names[1]


def _wrap(module, name, count):
    original = getattr(module, name, None)
    if original is None:
        return
    def wrapper(*args, **kwargs):
        converted = [long_path(a) if i < count else a for i, a in enumerate(args)]
        try:
            return original(*converted, **kwargs)
        except OSError as e:
            _name_paths(e, args[:count])
            raise
    wrapper.__name__ = name
    wrapper.__doc__ = original.__doc__
    setattr(module, name, wrapper)


def parse_table(text):
    rows = []
    for line in (text or "").splitlines():
        long, sep, short = line.partition("\t")
        if sep and long and short:
            rows.append((ntpath.normcase(long).rstrip("\\"), long.rstrip("\\"), short.rstrip("\\")))
    return sorted(rows, key=lambda r: -len(r[0]))


def to_short(path, table):
    """长路径（含 \\\\?\\ 前缀写法）落在某个工作区下 → 换成短路径；否则原样"""
    if not isinstance(path, str) or not table:
        return path
    bare = path[4:] if path.startswith("\\\\?\\") and not path.startswith("\\\\?\\UNC\\") else path
    low = ntpath.normcase(bare)
    for key, _, short in table:
        if low == key or low.startswith(key + "\\"):
            return short + bare[len(key):]
    return path


def _strict_short_root_fallback(path, table):
    """Return an existing path through an app-owned short-root junction, else None.

    Strict ``realpath`` normally requires a final path from the volume driver. Some mounted
    volumes reject that query with ERROR_UNRECOGNIZED_VOLUME even though stat/listing work. Only
    trust the lexical short path when it is rooted at one of our recorded junctions, that root is
    still a reparse point, every remaining component exists and is not another reparse point,
    and the final target can be stat'ed. This retains strict existence and containment semantics.
    """
    try:
        path = os.fspath(path)
    except TypeError:
        return None
    if not isinstance(path, str):
        return None
    bare = path[4:] if path.startswith("\\\\?\\") and not path.startswith("\\\\?\\UNC\\") else path
    absolute = ntpath.abspath(bare)
    folded = ntpath.normcase(absolute)
    for _, _, short in table:
        alias = ntpath.abspath(short).rstrip("\\")
        key = ntpath.normcase(alias)
        if folded != key and not folded.startswith(key + "\\"):
            continue
        try:
            info = os.lstat(alias)
        except OSError:
            return None
        reparse = getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        if not reparse:
            return None
        isjunction = getattr(os.path, "isjunction", None)
        try:
            if isjunction is None or not isjunction(alias):
                return None
        except OSError:
            return None
        current = alias
        suffix = absolute[len(alias):].lstrip("\\")
        for part in suffix.split("\\") if suffix else ():
            current = ntpath.join(current, part)
            try:
                info = os.lstat(current)
            except FileNotFoundError:
                raise
            except OSError:
                return None
            reparse = getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
            if reparse:
                return None
        os.stat(absolute)  # strict resolve must still reject a missing / unreadable final target
        return absolute
    return None


def _wrap_realpath():
    """工作区走短根（pack/orch/shortroot.py）时，realpath / Path.resolve 把目录联接展开成长路径后再换回短路径，否则和短路径比 relative_to 会失败（同 #138）"""
    original = ntpath.realpath

    def realpath(path, **kwargs):
        try:
            result = original(path, **kwargs)
        except OSError as error:
            # 不严格模式（缺省）下 Python 只吞几种「解析不了」的错误码（ntpath._getfinalpathname_nonstrict 的 allowed_winerror），
            #   有的盘的驱动（内存盘 / 虚拟盘 / 网盘挂载）取最终路径回 WinError 6「控制代码无效」，整个出包停在轻阶段（#1582 D-AHTT，4 次）。
            #   非严格按文档语义退回规整后的绝对路径；严格模式仅对已登记且仍有效的任务短 junction 处理 WinError 1005
            if kwargs.get("strict"):
                if getattr(error, "winerror", None) == 1005:
                    fallback = _strict_short_root_fallback(path, parse_table(os.environ.get("S2A_SHORT_ROOTS")))
                    if fallback is not None:
                        return fallback
                raise
            result = ntpath.abspath(path)
        text = os.environ.get("S2A_SHORT_ROOTS")
        if not text or not isinstance(result, str):
            return result
        return to_short(result, parse_table(text))

    realpath.__doc__ = original.__doc__
    realpath.long = original   # 判卷（ReFS 克隆）要真实路径：入口在系统盘，目标可能在别的盘
    ntpath.realpath = realpath


def reparse_buffer(target):
    """目录联接的重解析数据（Windows REPARSE_DATA_BUFFER 挂载点版）：替换名 \\\\??\\<目标> 和显示名 <目标> 各带一个宽字符结尾"""
    sub, shown = ("\\??\\" + target).encode("utf-16-le", "surrogatepass"), target.encode("utf-16-le", "surrogatepass")
    data = struct.pack("<HHHH", 0, len(sub), len(sub) + 2, len(shown)) + sub + b"\0\0" + shown + b"\0\0"
    return struct.pack("<IHH", 0xA0000003, len(data), 0) + data


def create_junction(target, link):
    """建目录联接，顶替 _winapi.CreateJunction：系统没开 LongPathsEnabled 时它对 260 字符以上的目标报 WinError 3，给目标加 \\\\?\\ 又写出访问时报 WinError 123 的非法联接"""
    import ctypes as C
    from ctypes import wintypes as W
    bare = ntpath.abspath(target[4:] if target.startswith("\\\\?\\") else target)
    if not os.path.isdir(long_path(bare)):
        raise FileNotFoundError(3, "联接目标不存在", bare)
    k = C.WinDLL("kernel32", use_last_error=True)
    k.CreateFileW.restype = W.HANDLE
    k.CreateFileW.argtypes = (W.LPCWSTR, W.DWORD, W.DWORD, C.c_void_p, W.DWORD, W.DWORD, W.HANDLE)
    k.DeviceIoControl.argtypes = (W.HANDLE, W.DWORD, C.c_char_p, W.DWORD, C.c_void_p, W.DWORD, C.POINTER(W.DWORD), C.c_void_p)
    k.CloseHandle.argtypes = (W.HANDLE,)
    path = long_path(ntpath.abspath(link))
    os.mkdir(path)
    h = k.CreateFileW(path, 0x40000000, 0, None, 3, 0x02000000 | 0x00200000, None)   # GENERIC_WRITE, OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT
    ok = h != W.HANDLE(-1).value
    err = 0 if ok else C.get_last_error()
    if ok:
        data = reparse_buffer(bare); done = W.DWORD()
        ok = bool(k.DeviceIoControl(h, 0x000900A4, data, len(data), None, 0, C.byref(done), None))   # FSCTL_SET_REPARSE_POINT
        err = 0 if ok else C.get_last_error()
        k.CloseHandle(h)
    if not ok:
        os.rmdir(path)
        raise C.WinError(err)


def install():
    global _done
    if _done or os.name != "nt":
        return
    _done = True
    for name in ("stat", "lstat", "open", "mkdir", "rmdir", "unlink", "remove", "listdir", "chmod", "utime", "readlink", "truncate", "access"):
        _wrap(os, name, 1)
    _wrap_scandir(os)
    for name in ("rename", "replace", "link", "symlink"):
        _wrap(os, name, 2)
    for name in ("exists", "lexists", "isfile", "isdir", "islink", "getsize", "getmtime", "getatime", "getctime", "isjunction"):
        _wrap(os.path, name, 1)
    _wrap(builtins, "open", 1)
    io.open = builtins.open
    import _winapi
    _wrap(_winapi, "CopyFile2", 2)
    _winapi.CreateJunction = create_junction
    _wrap_realpath()
