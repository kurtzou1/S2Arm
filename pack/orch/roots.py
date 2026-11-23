# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Versioned artifact transactions; layout and CAS rules mirror pack/roots.sh.

Callers own the root directory. The current version is a pointer file
(<game>@现行, pack/orch/current.py); only the one approved RomFS-store link may
be a reparse point. No bash, downloads or global settings.
"""
from __future__ import annotations

from contextlib import contextmanager, nullcontext
import ctypes as C
from .shortroot import is_network_path, table_now, to_long
from .winlong import long_path   # Win32 路径入口（CreateFileW / CopyFile2 / SetFileSecurityW / GetVolumePathNameW）不吃 Python 层的前缀补丁：>240 字符必须自己过 long_path
from .dirrename import DIR_RENAME_RETRIES, rename_dir   # noqa: F401（roots 内各处改名与外部调用方沿用 roots.rename_dir）
from . import current as curptr   # 现行指针文件（三个平台同一形式）
from ctypes import wintypes as W
import errno
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import time

from pack.jobs import filelock
from graphics.nvn.tools import romfs_list

REPO = Path(__file__).resolve().parents[2]
# 产物根里的 RomFS 镜像（标准 RomFS，与 romfs/ 同级；graphics/nvn/tools/romfs_list.py image_of）：单个不可变文件，没有阶段原地改它（界面布局只写覆盖层），
#   版本之间按 copy_file(link_ok=True) 共用同一份数据——克隆（APFS / ReFS / Linux 块克隆）或 Windows NTFS 同卷硬链接，不实拷十几 GB
ROMFS_IMAGE = 'romfs.std'


class UnsafeRoot(ValueError):
    pass


class Conflict(RuntimeError):
    pass


def text(path, value):
    Path(path).write_text(value, encoding='utf-8', newline='\n')


def read(path, default=''):
    try:
        return Path(path).read_text(encoding='utf-8').rstrip('\n')
    except FileNotFoundError:
        return default


def component(value):
    if (not value or value in ('.', '..', '现行') or value.startswith('.')
            or any(c in value for c in '/\\@<>:"|?*[]\r\n\t')
            or value.endswith((' ', '.'))):
        raise UnsafeRoot(f'非法目录名：{value!r}')
    return value


def is_link(path):
    try:
        return bool(Path(path).lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT) if os.name == 'nt' else Path(path).is_symlink()
    except FileNotFoundError:
        return False


def _api(dll, name, result, *args):
    f = getattr(C.WinDLL(dll, use_last_error=True), name)
    f.argtypes, f.restype = args, result
    return f


@contextmanager
def _handle(path, access):
    f = _api('kernel32', 'CreateFileW', W.HANDLE, W.LPCWSTR, W.DWORD,
             W.DWORD, C.c_void_p, W.DWORD, W.DWORD, W.HANDLE)
    h = f(long_path(str(Path(path).absolute())), access, 7, None, 3, 0x02200000, None)
    if h == C.c_void_p(-1).value:
        raise C.WinError(C.get_last_error())
    try:
        yield h
    finally:
        _api('kernel32', 'CloseHandle', W.BOOL, W.HANDLE)(h)


def _junction(target, link):
    """Create a mount-point reparse record without cmd.exe interpolation."""
    raw = str(Path(target).absolute())
    if raw.startswith('\\\\'):
        raise UnsafeRoot('junction 不接受 UNC/设备路径')
    sub = ('\\??\\' + raw).encode('utf-16-le')
    display = raw.encode('utf-16-le')
    names = sub + b'\0\0' + display + b'\0\0'
    data = struct.pack('<IHHHHHH', 0xA0000003, len(names) + 8, 0,
                       0, len(sub), len(sub) + 2, len(display)) + names
    link.mkdir()
    try:
        with _handle(link, 0x40000000) as h:
            buf = C.create_string_buffer(data)
            done = W.DWORD()
            f = _api('kernel32', 'DeviceIoControl', W.BOOL, W.HANDLE,
                     W.DWORD, C.c_void_p, W.DWORD, C.c_void_p, W.DWORD,
                     C.POINTER(W.DWORD), C.c_void_p)
            if not f(h, 0x900A4, buf, len(data), None, 0, C.byref(done), None):
                raise C.WinError(C.get_last_error())
    except BaseException as e:
        # 失败处写进异常附注（D-QNJQ）：编排中止那一行（refresh.py 拼 __notes__）自带「在 _junction」，作业主日志里只留这一行时
        #   失败归因也认得出（errors.LOG_CAUSES，同回溯里的 in _junction），不靠回溯落在读到的那段日志里
        if isinstance(e, OSError) and hasattr(e, 'add_note'):
            e.add_note(f'（在 _junction 建目录联接被拒：{link.name}）')
        cleanup_after(e, link.rmdir)
        raise


def cleanup_after(error, fn, *args):
    """出错后的收拾（删半成品 / 改名回去）自己又出错时，不许盖住起因（#669：播种真正失败的那一步被随后删 .romfs.intern 时的
    WinError 145 盖住，玩家报告里只剩 145）。收拾的错误记成起因上的附注，调用方随后 raise 原错误"""
    try:
        fn(*args)
    except Exception as e:
        error.add_note(f'（随后的清理 {getattr(fn, "__name__", fn)}({", ".join(map(str, args))}) 也失败：{e!r}；以上面的原错误为准）')


def _entry(path):
    """这个名字在父目录里有没有一项 → 该项的说明（属性 / 重解析标记），没有 → None。按名列父目录（Windows 上 scandir 底层是 FindFirstFileW），
    不经 lstat。#0fd185：os.path.lexists 遇到任何 OSError（不只是「不存在」）都答「不在」；0.5.8 上软链报 WinError 2 之后 #1431 的
    「失败后多出来的先删」没删成，junction 退路 mkdir 照样撞 WinError 183 = 那一项占着名字、lexists 却没认出它"""
    path = Path(path)
    want = path.name.casefold() if os.name == 'nt' else path.name
    try:
        with os.scandir(path.parent) as it:
            for e in it:
                if (e.name.casefold() if os.name == 'nt' else e.name) != want:
                    continue
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError as x:
                    return f'在（读属性失败：{x!r}）'
                return f'属性 {getattr(st, "st_file_attributes", 0):#x}、重解析标记 {getattr(st, "st_reparse_tag", 0):#x}'
    except (FileNotFoundError, NotADirectoryError):
        return None
    return None


def directory_link(target, link, *, relative=None):
    """目录链接（只给版本里的 romfs → RomFS 存储用；现行是指针文件，pack/orch/current.py）：软链，Windows 上建不了退 junction"""
    target, link = Path(target), Path(link)
    if os.name == 'nt':
        # #461：Windows 上一律写绝对目标、且是玩家路径（短根联接换回长路径）。相对目标的目录软链经短根联接（%LOCALAPPDATA%\S2A\j\…）访问时，
        #   有的 Windows（玩家实测 26320）stat / listdir / realpath 一律 WinError 3，同一链接走长路径或改写绝对目标都正常；没开开发者模式时走的
        #   junction 退路本来就只能写绝对目标。写长路径不写短路径：短根入口任务结束就拆，链接不能指向它
        target, relative = Path(to_long(str(target.absolute()), table_now())), None
    existed = _entry(link) is not None
    try:
        # Windows stores the substitute name verbatim; '/' in a relative
        # reparse target can be created successfully but fails kernel traversal.
        value = relative if relative is not None else str(target)
        os.symlink(os.path.normpath(value), link, target_is_directory=True)
    except OSError as error:
        if os.name != 'nt':
            raise
        # #1431：有的 Windows（玩家 26300、库在 ReFS 开发驱动器、没开开发者模式）软链报失败时 link 处已经留下了东西，紧跟着的 junction 退路
        #   mkdir 撞 WinError 183，播种 / 提交每次都在这里红，撤回再被它卡住。软链之前没有、失败之后有的，只能是这次失败留下的：删掉再走退路。
        #   #0fd185（0.5.8 照中：库在 NTFS、目标在 D: 链接在 C:，软链报 WinError 2）：在不在按名列父目录判（_entry），不再用 os.path.lexists
        #   （它遇到任何 OSError 都答「不在」，这一项没认出、没删）。留下的是什么（属性 / 重解析标记）打进日志，下一份诊断包里看得到
        left = None if existed else _entry(link)
        if left is not None:
            print(f'【黄】目录软链失败（{error!r}）后 {link.name} 处留下了一项（{left}），先删再走 junction 退路', file=sys.stderr)
            try:
                os.rmdir(link)
            except OSError:
                try:
                    os.unlink(link)
                except OSError as stuck:
                    error.add_note(f'（软链失败后 {link.name} 处留下的残留删不掉：{stuck!r}）')
                    raise error
        print(f'【黄】目录软链不可用（{_err_code(error)}；{volume_note(link.parent)}），显式 junction 退路：{link.name}', file=sys.stderr)
        _junction(target, link)


def link_target(path):
    """目录链接（版本里的 romfs → RomFS 存储）→ 它指向的真实目录（strict）。Windows 上先读链接内容自己拼成绝对路径再解析，不让系统去解析相对目标：
    #461 之前建的相对软链（v0.1.x / v0.2.x 开着开发者模式时）经短根联接访问会 WinError 3，读得出来才能克隆、换成绝对链接"""
    path = Path(path)
    if os.name != 'nt':
        return path.resolve(strict=True)
    raw = os.readlink(path)
    for prefix in ('\\\\?\\', '\\??\\'):
        if raw.startswith(prefix) and not raw.startswith('\\\\?\\UNC\\'):
            raw = raw[len(prefix):]
    target = Path(raw)
    return (target if target.is_absolute() else path.parent / target).resolve(strict=True)


def refs_same_volume(source, dest):
    if os.name != 'nt':
        return False
    getpath = _api('kernel32', 'GetVolumePathNameW', W.BOOL, W.LPCWSTR, W.LPWSTR, W.DWORD)
    roots = []
    for p in (source, Path(dest).parent):
        root = C.create_unicode_buffer(1024)
        if not getpath(long_path(getattr(os.path.realpath, 'long', os.path.realpath)(p)), root, len(root)):   # 先解开目录联接（入口在系统盘，目标可能在别的盘；作业目录是指到别的卷的联接时，按字面路径判错卷）
            raise C.WinError(C.get_last_error())
        roots.append(root.value)
    if os.path.normcase(roots[0]) != os.path.normcase(roots[1]):
        return False
    fs = C.create_unicode_buffer(64)
    getinfo = _api('kernel32', 'GetVolumeInformationW', W.BOOL, W.LPCWSTR,
                  W.LPWSTR, W.DWORD, C.c_void_p, C.c_void_p, C.c_void_p, W.LPWSTR, W.DWORD)
    if not getinfo(roots[0], None, 0, None, None, None, fs, len(fs)):
        raise C.WinError(C.get_last_error())
    return fs.value.upper() == 'REFS'


def links_supported(path):
    """这个卷能不能建目录链接（软链 / junction）：Windows 上只有 NTFS / ReFS 能（exFAT / FAT32 没有重解析点，11-12 exFAT 虚拟盘实测
    软链、junction、硬链接三样都报 WinError 1；改名、覆盖替换照常）。读不到卷格式按能（不凭空降级）。S2A_ROOTS_PLAIN=1 强制按不能（单测在 Mac 上走这条）"""
    if os.environ.get('S2A_ROOTS_PLAIN') == '1':
        return False
    if os.name != 'nt':
        return True
    if is_network_path(str(Path(path).absolute())):
        return False
    getpath = _api('kernel32', 'GetVolumePathNameW', W.BOOL, W.LPCWSTR, W.LPWSTR, W.DWORD)
    root = C.create_unicode_buffer(1024)
    if not getpath(long_path(str(Path(path).absolute())), root, len(root)):
        return True
    fs = C.create_unicode_buffer(64)
    getinfo = _api('kernel32', 'GetVolumeInformationW', W.BOOL, W.LPCWSTR,
                   W.LPWSTR, W.DWORD, C.c_void_p, C.c_void_p, C.c_void_p, W.LPWSTR, W.DWORD)
    if not getinfo(root.value, None, 0, None, None, None, fs, len(fs)):
        return True
    return fs.value.upper() in ('NTFS', 'REFS')


_DRIVE_TYPES = {0: '未知', 1: '根路径无效', 2: '可移动盘', 3: '本地硬盘', 4: '网络盘', 5: '光驱', 6: '内存盘'}


def _err_code(error):
    return f'WinError {error.winerror}' if getattr(error, 'winerror', None) is not None else f'errno {getattr(error, "errno", None)}'


def volume_note(path):
    """建链接失败时打进日志的卷信息（玩家诊断 #0fd185：NTFS 上软链、junction 都报 WinError 5）：卷文件系统名、支不支持重解析点
    （GetVolumeInformationW 的 FILE_SUPPORTS_REPARSE_POINTS）、盘类型（GetDriveTypeW）。非 Windows → 空说明；读不到写读不到和错误码，不抛"""
    if os.name != 'nt':
        return '非 Windows，不读卷信息'
    try:
        getpath = _api('kernel32', 'GetVolumePathNameW', W.BOOL, W.LPCWSTR, W.LPWSTR, W.DWORD)
        root = C.create_unicode_buffer(1024)
        if not getpath(long_path(str(Path(path).absolute())), root, len(root)):
            return f'卷路径读不到（WinError {C.get_last_error()}）'
        fs, flags = C.create_unicode_buffer(64), W.DWORD()
        getinfo = _api('kernel32', 'GetVolumeInformationW', W.BOOL, W.LPCWSTR,
                       W.LPWSTR, W.DWORD, C.c_void_p, C.c_void_p, C.c_void_p, W.LPWSTR, W.DWORD)
        info = (f'文件系统 {fs.value}，支持重解析点={"是" if flags.value & 0x80 else "否"}'
                if getinfo(root.value, None, 0, None, None, C.byref(flags), fs, len(fs)) else f'卷信息读不到（WinError {C.get_last_error()}）')
        kind = _api('kernel32', 'GetDriveTypeW', W.UINT, W.LPCWSTR)(root.value)
        return f'卷 {root.value}：{info}，盘类型 {kind}（{_DRIVE_TYPES.get(kind, "未知")}）'
    except Exception as e:   # 只是诊断附注：读卷信息本身出错不能盖住原错误
        return f'卷信息读不到（{e!r}）'


def copy_file(source, dest, link_ok=False, refs=None):
    """克隆优先（Mac clonefile / Linux FICLONE / Windows ReFS 块克隆，写时复制）；都没有时实拷。
    link_ok（#291，只给 RomFS 用：播种的 romfs/ 与各版本的镜像 romfs.std）：Windows 上同卷非 ReFS（NTFS）先建硬链接，不逐文件实拷——RomFS 按设计不可变（没有阶段原地改它，
    门禁机上还封成拒写），写单一 IMG 时边写边腾删的是产物根里的这个名字，共用解包目录里的那份数据不受影响。
    11-13 Windows NTFS 读数：18 万个文件的 RomFS 逐个实拷播种 1042 秒，8 万个的 433 秒。建不了（跨卷、FAT 类卷）照旧实拷"""
    source, dest = Path(source), Path(dest)
    if is_link(source) or not source.is_file():
        raise UnsafeRoot(f'不复制链接/特殊文件：{source}')
    dest.parent.mkdir(parents=True, exist_ok=True)
    cloned = False
    if sys.platform == 'darwin':
        libc = C.CDLL(None, use_errno=True)
        clone = libc.clonefile
        clone.argtypes, clone.restype = (C.c_char_p, C.c_char_p, C.c_int), C.c_int
        if clone(os.fsencode(source), os.fsencode(dest), 0) == 0:
            cloned = True
        elif C.get_errno() not in (errno.EXDEV, errno.ENOTSUP):
            raise OSError(C.get_errno(), 'clonefile 失败')
    elif sys.platform.startswith('linux'):
        import fcntl
        with source.open('rb') as src, dest.open('xb') as dst:
            try:
                fcntl.ioctl(dst.fileno(), 0x40049409, src.fileno())
                cloned = True
            except OSError as error:
                if error.errno not in (errno.EXDEV, errno.EOPNOTSUPP, errno.EINVAL, errno.ENOTTY):
                    raise
                print(f'【黄】块克隆不可用：实拷 {source.name}', file=sys.stderr)
                shutil.copyfileobj(src, dst, 1024 * 1024)
                cloned = True
    # refs：调用方已按整棵树判过「同一 ReFS 卷」就直接给（_copy_tree）；None = 这一个文件现判（每个文件两次 realpath + 两次查卷，11-16 出包轻阶段定因）
    if not cloned and (refs_same_volume(source, dest) if refs is None else refs):
        class Params(C.Structure):
            _fields_ = [('size', W.DWORD), ('flags', W.DWORD),
                        ('cancel', C.c_void_p), ('progress', C.c_void_p), ('context', C.c_void_p)]
        params = Params(C.sizeof(Params), 1, None, None, None)
        f = _api('kernel32', 'CopyFile2', C.c_long, W.LPCWSTR, W.LPCWSTR, C.POINTER(Params))
        rc = f(long_path(str(source)), long_path(str(dest)), C.byref(params))
        if rc < 0:
            raise OSError(rc, 'ReFS CopyFile2 失败；不悄悄转实拷')
        _win_acl(dest, False)
    elif not cloned:
        if link_ok and sys.platform == 'win32':
            try:
                os.link(long_path(str(source)), long_path(str(dest)))
                return   # 同一份数据：不改属性（copystat / 可写位会连带改到解包目录里那份）
            except OSError as error:
                print(f'【黄】硬链接不可用（{error.strerror or error}）：实拷 {source.name}', file=sys.stderr)
        else:
            print(f'【黄】非 ReFS 同卷克隆：实拷 {source.name}', file=sys.stderr)
        with source.open('rb') as src, dest.open('xb') as dst:
            shutil.copyfileobj(src, dst, 1024 * 1024)
    shutil.copystat(source, dest, follow_symlinks=False)
    # Version outputs must remain writable; RomFS is sealed separately.
    dest.chmod(stat.S_IMODE(dest.stat().st_mode) | stat.S_IWUSR)


_ACL_SD = {}   # 本进程的当前用户：封存 / 解封两个安全描述符只建一次（逐文件只调 SetFileSecurityW）


def _win_acl(path, sealed):
    """Private owned artifacts only; Windows directory readonly bits do not seal.
    11-06 出包速度线：原先每个文件都重转 SID、重建描述符（Windows 出包机微基准每文件 0.14 毫秒，缓存后 0.01）；王国之泪 30.5 万个文件逐个封存"""
    sd = _ACL_SD.get(sealed)
    if sd is None:
        from pack.jobs import winproc
        sid = winproc._current_sid()
        ptr = C.c_void_p()
        convert_sid = _api('advapi32', 'ConvertSidToStringSidW', W.BOOL, C.c_void_p, C.POINTER(C.c_void_p))
        if not convert_sid(sid, C.byref(ptr)):
            raise C.WinError(C.get_last_error())
        free = _api('kernel32', 'LocalFree', C.c_void_p, C.c_void_p)
        try:
            owner = C.wstring_at(ptr)
        finally:
            free(ptr)
        # Deny writes only, not GENERIC_WRITE (which also includes SYNCHRONIZE and
        # would reject ordinary read handles). Delete stays allowed so players can
        # always remove leftovers from Explorer; owner WRITE_DAC is kept for GC.
        deny = f'(D;OICI;0x00000116;;;{owner})' if sealed else ''
        sddl = f'D:P{deny}(A;OICI;GA;;;{owner})(A;OICI;GA;;;SY)(A;OICI;GA;;;BA)'
        sd = C.c_void_p()
        convert = _api('advapi32', 'ConvertStringSecurityDescriptorToSecurityDescriptorW', W.BOOL,
                       W.LPCWSTR, W.DWORD, C.POINTER(C.c_void_p), C.c_void_p)
        if not convert(sddl, 1, C.byref(sd), None):
            raise C.WinError(C.get_last_error())
        _ACL_SD[sealed] = sd   # 进程内常驻（两个，几百字节），不 LocalFree
    setsecurity = _ACL_SD.get('set') or _ACL_SD.setdefault('set', _api('advapi32', 'SetFileSecurityW', W.BOOL, W.LPCWSTR, W.DWORD, C.c_void_p))
    if not setsecurity(long_path(str(path)), 0x80000004, sd):
        raise C.WinError(C.get_last_error())


def sealing():
    """RomFS 共享存储设不设只读：只在开发 / 门禁机（S2A_ROMFS_SEAL=1，tools/gate.sh 设）。玩家机上存储在玩家看得见的游戏库里，
    只读（Windows 是拒写的访问控制项）会让玩家在资源管理器里删不掉旧产物——玩家可见目录不能用权限做保护（同 pack/roots.sh）"""
    return os.environ.get('S2A_ROMFS_SEAL') == '1'


def seal(path, readonly=True):
    path = Path(path)
    if is_link(path):
        raise UnsafeRoot('不能沿链接更改只读权限')
    paths = [path]
    if path.is_dir():
        paths.extend(plain_entries(path))
    for p in paths:
        if os.name == 'nt':
            _win_acl(p, readonly)
        else:
            before = stat.S_IMODE(p.stat().st_mode)
            after = before & ~0o222 if readonly else before | 0o200
            if after != before:
                p.chmod(after)


def remove_owned(path):
    """Caller passes an exact owned path; unlink reparse objects without walking."""
    path = Path(path)
    try:
        link = is_link(path)
    except OSError:   # #0fd185：lstat 读不了的残留（is_link 只接「不存在」），按下面最后一支按名删
        link = False
    if link:
        path.rmdir() if os.name == 'nt' and path.is_dir() else path.unlink()
    elif path.is_dir():
        if os.name == 'nt':
            _win_acl(path, False)
        else:
            path.chmod(stat.S_IMODE(path.stat().st_mode) | 0o700)
        for attempt in range(5):   # 删的同时目录里又被写进文件（外置盘访达 .DS_Store / ._ 等，#369）：重列再删
            for p in path.iterdir():
                remove_owned(p)
            try:
                path.rmdir()
                break
            except OSError as e:
                if e.errno != errno.ENOTEMPTY or attempt == 4:
                    raise
                time.sleep(0.2 * (attempt + 1))
    elif path.exists():
        if os.name == 'nt':
            # 封存（拒写项，seal）不拒删：先直接删。共用数据树的文件是各版本共用的硬链接，解封会连带解掉别的版本（访问控制项挂在文件本身上）
            try:
                path.unlink()
                return
            except PermissionError:
                pass
            _win_acl(path, False)
        path.chmod(stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR)
        path.unlink()
    elif _entry(path) is not None:   # 在、但既不是链接也读不出是文件 / 目录（#1431：软链失败留下的残留）：原先一支都不认、什么都不删，上一级 rmdir 报「目录不是空的」。
        #   按名列父目录判在不在（#0fd185：os.path.lexists 遇到任何 OSError 都答「不在」）
        try:
            os.rmdir(path)
        except OSError:
            os.unlink(path)


def remove_patterns(directory, patterns):
    """Top-level stage-output selection, never a game-data directory walk."""
    for pattern in patterns:
        if Path(pattern).is_absolute() or '..' in Path(pattern).parts:
            raise UnsafeRoot('删除模式离开版本根')
        for p in Path(directory).glob(pattern):
            remove_owned(p)


def plain_entries(path):
    """Repository's sole directory inventory; validate before any mutation."""
    listing = romfs_list.scan(path)
    if listing.errors:
        raise next(iter(listing.errors.values()))
    paths = []
    for entry in listing.entries:
        if entry.lstat_error:
            raise entry.lstat_error
        p = Path(entry.path)
        if is_link(p) or not (p.is_file() or p.is_dir()):
            raise UnsafeRoot(f'不接受链接/特殊文件：{p}')
        paths.append(p)
    return paths


def repair_git_skeleton(git_dir):
    """Git 认一个目录是仓库要 HEAD、objects/、refs/ 都在。发出去的引擎快照里 refs/ 下只有空目录（引用都在 packed-refs），
    安装 / 拷贝时空目录可能丢（11-11 维护者 Windows 覆盖安装后 Engine\\.git 只剩 info / logs / objects）→ Git 不认这个仓库。
    HEAD 与 objects/ 都在、只缺这几个空目录时补上（不改任何内容）；→ 补了哪些"""
    git_dir = Path(git_dir)
    if not (git_dir / 'HEAD').is_file() or not (git_dir / 'objects').is_dir():
        return []
    made = []
    for d in ('refs', 'refs/heads', 'refs/tags'):
        if not (git_dir / d).is_dir():
            (git_dir / d).mkdir(parents=True, exist_ok=True)
            made.append(d)
    return made


def git(*args, repo=REPO, check=True):
    # 钉死仓库：有自己的 .git 目录（发出去的引擎快照、普通检出）就显式 --git-dir / --work-tree，并设 GIT_CEILING_DIRECTORIES，
    #   绝不往上认到玩家自己的仓库（11-11：Engine\\.git 缺 refs 时 git 一路往上，认到玩家主目录下的空仓库，报 HEAD 不存在）。
    #   .git 是文件（工作树）照旧 -C
    repo = Path(repo)
    pin = []
    if (repo / '.git').is_dir():
        repair_git_skeleton(repo / '.git')
        pin = ['--git-dir', str((repo / '.git').resolve()), '--work-tree', str(repo.resolve())]
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(repo.resolve().parent))
    result = subprocess.run(['git', '-C', str(repo), *pin, *args], capture_output=True, check=check, env=env)
    return result.stdout.decode('utf-8').strip() if check else result.returncode == 0


def snapshot(key, repo=REPO):
    """发布快照（App 内置引擎）不带 .git：出包要的 git 值在打包时算好写进 engine.json（launchers/macos/bundle_engine.py snapshot_fields，
    打包自检核过与 git 算法逐项相等）。→ 该字段；开发树 / 旧快照没有 → None，调用方走 git（同 pack/stage_keyfiles.sh engine_snap）"""
    try:
        with open(Path(repo) / 'engine.json', encoding='utf-8') as f:
            return json.load(f).get(key) or None
    except FileNotFoundError:
        return None


def head(repo=REPO):
    """本树提交号（.root_src）"""
    return snapshot('commit', repo) or git('rev-parse', 'HEAD', repo=repo)


def is_ancestor(a, b, repo=REPO):
    """a 是 b 的祖先。快照只有打包时那一个提交：只在两者都是它时成立（与原先在快照库里跑 merge-base 结果相同）"""
    h = snapshot('commit', repo)
    if h:
        return a == b == h
    return git('merge-base', '--is-ancestor', a, b, repo=repo, check=False)


def process_start(pid):
    if os.name == 'nt':
        from pack.jobs import winproc
        try:
            # A terminated process object can remain queryable while Popen
            # still owns its handle. Creation time alone is not liveness.
            with winproc._process(pid) as handle:
                code = W.DWORD()
                query = _api('kernel32', 'GetExitCodeProcess', W.BOOL, W.HANDLE, C.POINTER(W.DWORD))
                if not query(handle, C.byref(code)):
                    raise C.WinError(C.get_last_error())
                return winproc._creation_time(handle) if code.value == 259 else ''
        except OSError:
            return ''
    r = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True)
    return ' '.join(r.stdout.split())


# 各版本共用、没有阶段原地改的数据目录（追加内容：只由 aoc 阶段整目录换掉）：阶段事务克隆现行时 Windows 上建硬链接，不逐个克隆
#   （11-16 出包轻阶段定因：带 DLC 的款每个阶段事务都把几千个 DLC 文件逐个块克隆 + 设权限一遍，一款 7095 个文件每个阶段 6–30 秒）
SHARED_TREES = ('aoc',)


def shared_print(root):
    """SHARED_TREES 各棵的指纹：{树名: (树目录 inode, {相对路径: (大小, 修改时间 ns)})}；没有这棵 = 不记。
    守护「只许整目录替换、不许原地改」（硬链接的前提，11-16 维护者）：Transaction 开始时记一份，提交时树目录没换（inode 相同）就要逐项相同，
    不同 = 有阶段原地写了共用数据（硬链接下会连带改坏别的版本与缓存），当场报冲突、不提交。逐层 scandir，7000 来个文件约 0.1 秒"""
    out = {}
    for name in SHARED_TREES:
        top = Path(root) / name
        if not top.is_dir() or is_link(top):
            continue
        files, stack = {}, [top]
        while stack:
            d = stack.pop()
            with os.scandir(d) as it:
                for e in it:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(Path(e.path))
                    else:
                        st = e.stat(follow_symlinks=False)
                        files[os.path.relpath(e.path, top)] = (st.st_size, st.st_mtime_ns)
        out[name] = (top.stat().st_ino, files)
    return out


class Roots:
    def __init__(self, path=None, *, shared=None, repo=REPO):
        run = Path(os.environ.get('S2A_RUN_ROOT', Path.home() / '.s2arm/run')) / 's2arm'
        self.shared_path = Path(os.environ.get('S2A_ROOTS_SHARED', run / 'roots')).resolve()
        self.private_path = Path(os.environ.get('S2A_ROOTS_PRIV', run / 'roots_priv')).resolve()
        configured = Path(path or os.environ.get('S2A_ROOTS', self.shared_path)).absolute()
        if is_link(configured):
            raise UnsafeRoot('产物根本身不能是重解析点')
        self.path = configured.resolve()
        self.repo = Path(repo)
        self.shared = self.path == self.shared_path if shared is None else shared
        self.path.mkdir(parents=True, exist_ok=True)
        # 实目录模式（游戏库在 exFAT / FAT32 上，v0.3.1 玩家确认后照用）：卷上建不了目录链接——RomFS 留在各版本里、不进 .romfs_store，
        #   每个版本各占一份 RomFS，空间预算按多一份算（space_rule）。现行与别的卷一样是指针文件（pack/orch/current.py），不再改名换目录
        self.plain = not links_supported(self.path)
        self._held = set()   # 本对象正持着提交锁的款（锁是按打开的文件算的 flock：同一进程再开一次会等自己）

    def _guard(self, game):
        if not self.shared:
            return
        if not git('merge-base', '--is-ancestor', 'HEAD', 'origin/main', repo=self.repo, check=False):
            raise Conflict('共享根只代表 main；分支使用 roots_priv')
        if git('status', '--porcelain', '--', 'runtime', 'ios', 'graphics', 'translator', 'services', 'compat', 'pack', repo=self.repo):
            raise Conflict('共享根拒绝未提交的阶段源码')
        cur = self.cur(game, pin=False)
        if cur and read(cur / '.root_src') and not git('merge-base', '--is-ancestor', read(cur / '.root_src'), 'HEAD', repo=self.repo, check=False):
            raise Conflict('共享现行来源更晚，只许往前')

    def _romfs(self, version, game):
        p = version / 'romfs'
        if not is_link(p):
            return None
        target = link_target(p)
        store = self.path / '.romfs_store' / game
        if target.parent != store or not target.is_dir() or is_link(target) or target.name.startswith('.'):
            raise UnsafeRoot('RomFS 只能指向本款存储中的单个真实身份目录')
        for ancestor in (store, store.parent):
            if is_link(ancestor):
                raise UnsafeRoot('RomFS 存储父目录不能是链接')
        if p.is_symlink() and os.name != 'nt':   # Windows 写绝对目标（#461），上面已核它落在本款存储里
            expected = f'../.romfs_store/{game}/{target.name}'
            if os.readlink(p).replace('\\', '/') != expected:
                raise UnsafeRoot('RomFS 必须使用约定相对链接')
        return target

    def _validate(self, version, game):
        if is_link(version) or version.parent != self.path:
            raise UnsafeRoot('版本必须是根下真实目录')
        target = self._romfs(version, game)
        for name in romfs_list.listdir(version):
            p = version / name
            if p == version / 'romfs' and target:
                continue  # The immutable store was validated and sealed on intern.
            if is_link(p):
                raise UnsafeRoot(f'版本中有非法链接：{p}')
            # v0.2.3 清理：不再递归扫每个子目录查链接 / 特殊文件——版本根全是本流水线自己生成的，每个阶段都整棵扫一遍防的是不现实的情况

    def cur(self, game, *, pin=True):
        component(game)
        override = os.environ.get('S2A_ROOT_CUR')
        if override:
            return Path(override).resolve(strict=True)
        current = curptr.resolve(self.path, game, lock=lambda: self._lock_once(game))   # 老库的链接 / 实目录在这里迁移成指针文件
        if current is None and self._heal(game):
            return self.cur(game, pin=pin)
        if current is None:
            if not os.environ.get('S2A_ROOTS_NO_BOOT') and self.private_path in self.path.parents:
                shared = Roots(self.shared_path, shared=True, repo=self.repo)
                source = shared.cur(game)
                if source:
                    # Store links are local to a roots directory. A private
                    # bootstrap therefore clones the resolved RomFS once.
                    shared._validate(source, game)
                    tx = self.begin(game, self.tag(game, 'bootstrap'), _no_boot=True)
                    try:
                        for name in romfs_list.listdir(source):
                            p = source / name
                            if p.name in ('.root_base', '.root_src', '.root_pid', '.root_base_stages'):
                                continue
                            if p.is_dir():
                                self._copy_tree(p.resolve(), tx.path / p.name)
                            else:
                                copy_file(p, tx.path / p.name, link_ok=p.name == ROMFS_IMAGE)
                        tx.commit()
                    except BaseException as e:
                        cleanup_after(e, tx.abort)
                        raise
                    return self.cur(game, pin=pin)
            return None
        if pin:
            text(self.path / f'.pin.{current.name}.{os.getpid()}', f'{os.getpid()} {process_start(os.getpid())}\n')
        return current

    def _lock_once(self, game):
        """该款提交锁；本对象已持着（提交里取现行）就不再拿"""
        return nullcontext() if game in self._held else self.locked(game)

    def _heal(self, game):
        """没有合规的现行（指针文件被删 / 指向的版本没了）而本款还有提交过的版本：自愈，不让下次出包从头来——取最新的已提交版本写指针。
        老实目录模式换到一半的事务（<款>@<标签>.tmp 里 .root_tag 记的正是 <款>@<标签>，旧码已校验、正在换上）先改名成版本目录、算它。
        没有可用版本返回 False（照旧：从共享根引导或从头出）"""
        with self._lock_once(game):
            if curptr.read(self.path, game) is not None:   # 等锁期间别人已接上
                return True
            for p in self.path.glob(f'{game}@*.tmp'):
                final = self.path / p.name[:-len('.tmp')]
                if p.is_dir() and not is_link(p) and read(p / curptr.TAG_FILE) == final.name and not os.path.lexists(final):
                    rename_dir(p, final)
                    (final / curptr.TAG_FILE).unlink()
            versions = [p for p in self.path.glob(f'{game}@*') if curptr.valid(self.path, game, p.name) is not None]
            pick = max(versions, key=lambda p: p.stat().st_mtime_ns, default=None)
            if pick is None:
                return False
            print(f'【黄】{game} 没有现行（上次换版本中途中断？），按 {pick.name} 自愈', file=sys.stderr)
            curptr.write(self.path, game, pick.name)
            return True

    def tag(self, game, value):
        component(game); component(value)
        result, number = value, 1
        while any(os.path.lexists(self.path / f'{game}@{result}{suffix}') for suffix in ('', '.tmp', '.tmp.rb')):
            number += 1
            result = f'{value}-{number}'
        return result

    @contextmanager
    def locked(self, game, timeout=86400):
        component(game)
        if game in self._held:
            raise Conflict(f'{game} 的提交锁本对象已持着，不能重入')
        lock = self.path / f'.{game}.commit.lock'
        with lock.open('a+b') as stream:
            if stream.seek(0, 2) == 0:
                stream.write(b'\0'); stream.flush()
            deadline = time.monotonic() + timeout
            while True:
                try:
                    filelock.try_lock(stream)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('产物根提交锁超时')
                    time.sleep(0.05)
            self._held.add(game)
            try:
                yield
            finally:
                self._held.discard(game)
                filelock.unlock(stream)

    def _clone(self, source, dest, game, *, own_romfs=False, env=None):
        self._validate(source, game)
        target = self._romfs(source, game)
        dest.mkdir()
        for name in romfs_list.listdir(source):
            p = source / name
            if p.name == 'romfs' and target:
                if own_romfs:
                    self._copy_tree(target, dest / 'romfs')
                else:
                    directory_link(target, dest / 'romfs', relative=f'../.romfs_store/{game}/{target.name}')
            elif p.is_dir():
                self._copy_tree(p, dest / p.name, hardlink=p.name in SHARED_TREES)
            else:
                copy_file(p, dest / p.name, link_ok=p.name == ROMFS_IMAGE)
        if not own_romfs and (dest / 'romfs').is_dir() and not target and sealing():
            seal(dest / 'romfs')
        self._resource('--root-clone', source, dest, env=env)
        self._shards(dest, '克隆现行(root_begin)', env=env)

    def _copy_tree(self, source, dest, tick=None, link_ok=False, hardlink=False):
        """hardlink（只给 SHARED_TREES 里各版本共用、不原地改的数据）：Windows 上逐个文件先建硬链接（同一份数据，不克隆、不改属性），建不了（跨卷、FAT 类卷）
        这一棵余下的照常 copy_file。Mac / Linux 照旧克隆"""
        if is_link(source):
            raise UnsafeRoot('克隆拒绝未批准的链接')
        dest.mkdir(parents=True)
        # 卷只判一次（11-16 出包轻阶段定因：每个阶段事务克隆现行，追加内容 7095 个文件逐个判卷，每个文件两次 realpath + 两次查卷）：
        #   plain_entries 已拒绝树里的一切重解析点（链接 / 联接 / 挂载点），整棵源树与源根同卷；目标树是这里新建的子目录，与目标根同卷
        refs = None
        for p in plain_entries(source):
            output = dest / p.relative_to(source)
            if p.is_dir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                if hardlink and os.name == 'nt':
                    try:
                        os.link(long_path(str(p)), long_path(str(output)))
                        if tick:
                            tick()
                        continue
                    except OSError as error:
                        print(f'【黄】硬链接不可用（{error.strerror or error}）：{source.name} 照常克隆', file=sys.stderr)
                        hardlink = False
                if refs is None:
                    refs = refs_same_volume(source, dest / p.name)   # 判的是 source 与 dest 两个目录所在的卷（refs_same_volume 取目标的上一级）
                copy_file(p, output, link_ok=link_ok, refs=refs)
                if tick:
                    tick()

    def _resource(self, mode, *paths, env=None):
        helper = self.repo / 'pack/resource_input_key.py'
        if helper.is_file():
            py = (env or {}).get('S2A_PYTHON') or (env or {}).get('S2A_PY') or sys.executable
            subprocess.run([py, '-X', 'utf8', str(helper), mode, *map(str, paths)], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    def _shards(self, path, label, *, env=None):
        helper = self.repo / 'tools/direct_shards.py'
        if helper.is_file():
            py = (env or {}).get('S2A_PYTHON') or (env or {}).get('S2A_PY') or sys.executable
            log = (env or os.environ).get('S2A_SHARD_LOG', str(self.path / '.shard_inventory.log'))
            subprocess.run([py, '-X', 'utf8', str(helper), 'inventory', str(path), '--label', label, '--log', log],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    def begin(self, game, tag, *, own_romfs=False, _no_boot=False, env=None):
        component(game); component(tag)
        self._guard(game)
        dest = self.path / f'{game}@{tag}.tmp'
        if os.path.lexists(dest) or os.path.lexists(self.path / f'{game}@{tag}'):
            raise Conflict('版本名已存在，不覆写其它事务')
        current = None if _no_boot else self.cur(game)
        try:
            if current:
                self._clone(current, dest, game, own_romfs=own_romfs, env=env)
            else:
                dest.mkdir()
            text(dest / '.root_base', (current.name if current else '无') + '\n')
            text(dest / '.root_src', head(self.repo) + '\n')
            text(dest / '.root_pid', f'{os.getpid()} {process_start(os.getpid())}\n')
            stages = sorted(current.glob('.stage_*')) if current else ()
            text(dest / '.root_base_stages', ''.join(f'{p.name}\t{read(p)}\n' for p in stages if p.is_file()))
            tx = Transaction(self, game, tag, dest, env=env)
            tx.shared = shared_print(dest)
            return tx
        except BaseException as e:
            cleanup_after(e, remove_owned, dest)
            raise

    def _intern(self, version, game):
        p = version / 'romfs'
        if self.plain or not p.is_dir() or is_link(p):   # 实目录模式：RomFS 留在版本里（建不了指向存储的链接）
            return
        store = self.path / '.romfs_store' / game
        for directory in (store.parent, store):
            if is_link(directory):
                raise UnsafeRoot('RomFS 存储路径非法')
            directory.mkdir(exist_ok=True)
        identity = f'{version.name.split("@", 1)[1].split(".tmp", 1)[0]}-{time.time_ns()}'
        temp = version / '.romfs.intern'
        # 收进共享存储只是省时间 / 空间的优化（不用每个阶段整棵克隆）：做不成就撤回原样、RomFS 留在本版本里照常出包，记一行黄（#754：
        #   玩家 Windows 11 上任何游戏出包都停在这一步，三版启动器 3/3 必现，我方机器复现不出；原先这里一失败整次出包失败，
        #   回滚又只认「链接」不认 junction 退路留下的空目录，改名回去撞「文件已存在」把原错误盖住）。撤不回来才报原错误
        try:
            if os.name == 'nt':
                _win_acl(p, False)
            else:
                p.chmod(stat.S_IMODE(p.stat().st_mode) | 0o200)
            rename_dir(p, temp)
        except OSError as e:
            print(f'【黄】RomFS 没收进共享存储（{e!r}），留在本版本里照常出包', file=sys.stderr)
            return
        try:
            directory_link(store / identity, p, relative=f'../.romfs_store/{game}/{identity}')
            rename_dir(temp, store / identity)
        except OSError as e:
            try:
                if os.path.lexists(p):   # 链接，或 junction 退路建了一半留下的空目录
                    p.rmdir() if not is_link(p) or (os.name == 'nt' and p.is_dir()) else p.unlink()
                if (store / identity).is_dir() and not temp.exists():   # 已经挪进存储：挪回来
                    rename_dir(store / identity, temp)
                rename_dir(temp, p)
            except OSError as undo:
                e.add_note(f'（撤回也失败：{undo!r}；以上面的原错误为准）')
                raise e
            print(f'【黄】RomFS 没收进共享存储（{e!r}；{_err_code(e)}；{volume_note(store)}），已撤回、留在本版本里照常出包', file=sys.stderr)
            return
        if not sealing():   # 玩家机：存储在玩家看得见的游戏库里，不设只读（同 pack/roots.sh _root_romfs_lock）
            return
        try:
            seal(store / identity)
        except OSError as e:   # 已经在存储里、链接也指好了：只是没封成只读，照用
            print(f'【黄】RomFS 共享存储没能设成只读（{e!r}），照用', file=sys.stderr)

    def _pinned(self, version):
        for pin in self.path.glob(f'.pin.{version.name}.*'):
            pid, _, stamp = read(pin).partition(' ')
            if pid.isdecimal() and int(pid) == os.getpid():
                continue
            if pid.isdecimal() and stamp and process_start(int(pid)) == stamp:
                return True
            pin.unlink()
        return False

    def prune(self, game):
        """只留现行 + 上一版，清没人指向的 RomFS 身份与现行指针的残留（崩溃留下的临时指针、迁移旁边的旧链接）。调用方持该款提交锁"""
        current = self.cur(game, pin=False)
        if curptr.leftover(self.path, game):
            curptr.normalize(self.path, game)
        others = sorted((p for p in self.path.glob(f'{game}@*') if p.is_dir()
                         and not is_link(p) and not p.name.endswith(('.tmp', '.tmp.rb'))
                         and p != current), key=lambda p: p.stat().st_mtime_ns, reverse=True)
        for p in others[1:]:
            if not self._pinned(p):
                _prune_one(p)
        store = self.path / '.romfs_store' / game
        if store.is_dir() and not is_link(store):
            used = {self._romfs(p, game) for p in self.path.glob(f'{game}@*')
                    if p.is_dir() and not is_link(p)}
            for name in romfs_list.listdir(store):
                p = store / name
                if p not in used and not is_link(p):
                    _prune_one(p)


def _prune_one(p):
    """prune 删一份旧版本 / 没人用的 RomFS 身份：是打扫，不是本次结果的一部分（prune 在新版本已提交、指针已写之后才跑）。
    删不掉（诊断#8735d6 D-GGG5：Windows 杀毒 / 索引开着句柄，删除挂起，remove_owned 重试 2 秒后仍 WinError 145「目录不是空的」）
    只说一句黄、接着删下一份，不把已成功的提交报成出包失败；残留下次 prune 再删（同 stages.Dependencies.close，D-CFH5）"""
    try:
        remove_owned(p)
    except OSError as e:
        print(f'【黄】旧版本没删干净（下次出包再清）{p}：{e}', file=sys.stderr)


class Transaction:
    def __init__(self, roots, game, tag, path, *, env=None):
        self.roots, self.game, self.tag, self.path = roots, game, tag, path
        self.closed = False
        self.env = env
        self.shared = {}   # begin 记的 SHARED_TREES 指纹（shared_print）；提交时核

    def abort(self):
        if not self.closed:
            remove_owned(self.path)
            self.closed = True

    def _replay(self, current, patterns):
        r = self.path.with_name(self.path.name + '.rb')
        own_romfs = any(p.lstrip('!') == 'romfs' or p.lstrip('!').startswith('romfs/') for p in patterns)
        self.roots._clone(current, r, self.game, own_romfs=own_romfs, env=self.env)
        text(r / '.root_pid', f'{os.getpid()} {process_start(os.getpid())}\n')   # 重放也记持有者：外部清扫只按记录判死，没有记录的一律不碰
        try:
            for exclude in (False, True):
                source = current if exclude else self.path
                for raw in patterns:
                    if raw.startswith('!') != exclude:
                        continue
                    pattern = raw.lstrip('!')
                    if Path(pattern).is_absolute() or '..' in Path(pattern).parts:
                        raise UnsafeRoot('重放路径离开版本目录')
                    for p in r.glob(pattern):
                        remove_owned(p)
                    for p in source.glob(pattern):
                        dst = r / p.relative_to(source)
                        if p.is_dir():
                            self.roots._copy_tree(p, dst)
                        else:
                            copy_file(p, dst)
            ms, ns = read(self.path / '.root_src'), read(current / '.root_src')
            if not ns or (ms and is_ancestor(ns, ms, self.roots.repo)):
                text(r / '.root_src', ms + '\n')
            text(r / '.root_base', current.name + '\n')
            self.roots._shards(r, 'replay·换完路径后', env=self.env)
            remove_owned(self.path)
            rename_dir(r, self.path)
        except BaseException as e:
            cleanup_after(e, remove_owned, r)
            raise

    def replaced(self, name):
        """本阶段把共用数据树 name 整目录换掉了（只有 aoc 阶段这么做）：提交时不再核它（见 commit 开头的守护）"""
        self.shared.pop(name, None)

    def _seal_shared(self):
        """开发 / 门禁机（sealing()）上把共用数据树封成只读：之后任何阶段原地写它，在写的第一下就失败，不等提交守护（_check_shared）。
        Windows 上它们是各版本共用的硬链接，原地写会连带改坏别的版本；玩家机不封（玩家看得见的游戏库不用权限做保护，同 sealing），靠提交守护兜底。
        Windows 的封存是拒写的访问控制项：不挡建硬链接、不挡删（remove_owned 删它不用先解封）"""
        if not sealing():
            return
        for name in SHARED_TREES:
            tree = self.path / name
            if tree.is_dir() and not is_link(tree):
                for p in plain_entries(tree):
                    if not p.is_dir():
                        seal(p)

    def _check_shared(self):
        """守护「共用数据树只许整目录替换、不许原地改」（硬链接的前提，11-16）：begin 记的指纹（shared_print）与现在比，没声明换掉（replaced）却变了 = 原地改了，报冲突不提交。
        在提交一开始、重放之前核：只核本阶段自己做的事（重放会合法地换成新现行的那份）。
        不按树目录 inode 判「换没换」：ext4 上删掉的目录 inode 会马上被新目录复用（11-16 Linux 门禁误报），换掉要由换的一方显式声明"""
        now = shared_print(self.path)
        for name, (ino, files) in self.shared.items():
            got = now.get(name, (None, {}))[1]
            if got != files:
                diff = sorted(set(files.items()) ^ set(got.items()))
                raise Conflict(f'原地改了共用数据 {name}/{diff[0][0] if diff else ""}（{name}/ 只许由 aoc 阶段整目录替换，roots.SHARED_TREES；硬链接下会连带改坏别的版本）')

    def commit(self, *, replay=()):
        if self.closed or not self.path.is_dir():
            raise Conflict('事务已结束或缺失')
        roots = self.roots
        final = roots.path / f'{self.game}@{self.tag}'
        try:
            self._check_shared()   # 先核本阶段有没有原地改共用数据（重放之前）
            with roots.locked(self.game):
                current = roots.cur(self.game, pin=False)
                base = read(self.path / '.root_base')
                now = current.name if current else '无'
                if base != now:
                    if not replay or not current:
                        raise Conflict('现行已前进；未声明重放路径，中止')
                    ns, ms = read(current / '.root_src'), read(self.path / '.root_src')
                    stages = read(self.path / '.root_base_stages').splitlines()
                    old = dict(line.split('\t', 1) for line in stages if '\t' in line)
                    touched = any(p.startswith('.stage_') and read(current / p) != old.get(p, '') for p in replay)
                    if roots.shared and touched and ns and ms and not git('merge-base', '--is-ancestor', ns, ms, repo=roots.repo, check=False):
                        raise Conflict('更新 main 已改过本阶段；共享现行不回退')
                    self._replay(current, tuple(replay))
                roots._validate(self.path, self.game)
                roots._intern(self.path, self.game)
                self._seal_shared()
                rename_dir(self.path, final)
                curptr.write(roots.path, self.game, final.name)   # 临时指针 fsync 后原子改名：读方只看到旧值或新值
                self.closed = True
                if os.environ.get('S2A_RESOURCE_KEY_ONCE_FILE'):
                    roots._resource('--root-publish', final, env=self.env)
                roots.prune(self.game)
                return final
        except BaseException as e:
            cleanup_after(e, self.abort)
            raise
