# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""产物根的「现行」：<产物根>/<款>@现行 是一个普通文件（指针文件），内容是当前版本目录名（只是名字，UTF-8，单行）。

三个平台同一形式（pack/roots.sh、pack/orch/roots.py、pack/jobs 都按这里）：现行要的只是「当前用哪个版本目录」这一个值，
不再用目录软链 / junction（玩家诊断 #0fd185：Windows NTFS 上软链和 junction 都报 WinError 5，出包中止）。
- 读：校验名字（以 <款>@ 开头、不含路径分隔符、不是「现行」本身、不是在途事务 .tmp / .tmp.rb）且 <产物根>/<名字> 是真目录；不过 = 没有现行。
- 切换：同目录临时文件 .<款>@现行.new-<随机> 写好 fsync，再原子改名覆盖（POSIX rename / Windows os.replace），读方任何时刻只看到旧值或新值。
- 老库迁移（normalize，调用方持该款提交锁）：软链 / junction、实目录模式的真目录改成版本目录 + 指针文件；断在中途的下次接着做完。
只依赖标准库：pack/jobs 按文件路径载入；bash（pack/roots.sh）以脚本调 write / normalize。
"""
import os
from pathlib import Path
import stat
import sys
import time
import uuid

NAME = '现行'
TAG_FILE = '.root_tag'   # 实目录模式（已撤）记版本名的文件：只在迁移时读
# Windows：读方开着指针文件的一瞬间覆盖改名报 WinError 5 / 32（反之亦然），短退避重试；其它系统不重试
RETRIES = (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2)


def pointer(root, game):
    return Path(root) / f'{game}@{NAME}'


def _temp_prefix(game):
    return f'.{game}@{NAME}.new-'


def _aside_prefix(game):
    return f'{game}@{NAME}.migr-'


def _kind(path):
    """file / link（软链或 Windows 重解析点）/ dir / other；不在 → None。不跟随链接"""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(st.st_mode) or getattr(st, 'st_file_attributes', 0) & 0x400:   # FILE_ATTRIBUTE_REPARSE_POINT
        return 'link'
    if stat.S_ISDIR(st.st_mode):
        return 'dir'
    return 'file' if stat.S_ISREG(st.st_mode) else 'other'


def valid(root, game, name):
    """指针内容 name → 版本目录 Path；不合规 → None"""
    if not name or not name.startswith(game + '@') or any(c in name for c in '/\\\r\n\0'):
        return None
    tag = name[len(game) + 1:]
    if not tag or tag == NAME or tag.startswith(NAME + '.') or name.endswith(('.tmp', '.tmp.rb')):
        return None
    version = Path(root) / name
    return version if _kind(version) == 'dir' else None


def _retry(fn, *args):
    for delay in (*RETRIES, None):
        try:
            return fn(*args)
        except PermissionError as e:
            if os.name != 'nt' or delay is None or getattr(e, 'winerror', 5) not in (5, 32):
                raise
            time.sleep(delay)


def _parse(raw):
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        return None
    text = text.rstrip('\r\n')
    return None if '\n' in text or '\r' in text else text


def read(root, game):
    """现行版本目录 → Path；没有指针文件 / 内容不合规 → None。只认指针文件（老形式由 normalize 迁移）"""
    p = pointer(root, game)
    if _kind(p) != 'file':
        return None
    try:
        raw = _retry(p.read_bytes)
    except FileNotFoundError:
        return None
    return valid(root, game, _parse(raw))


def _put(root, game, name, dest):
    """写临时指针文件（fsync）后原子改名到 dest；→ None。失败删临时文件再抛"""
    tmp = Path(root) / f'{_temp_prefix(game)}{uuid.uuid4().hex}'
    try:
        with open(tmp, 'xb') as f:
            f.write((name + '\n').encode('utf-8'))
            f.flush()
            os.fsync(f.fileno())
        if dest is None:
            return tmp
        _retry(os.replace, tmp, dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _sync_dir(root)


def _sync_dir(root):
    if os.name == 'nt':
        return
    try:
        fd = os.open(root, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write(root, game, name):
    """切现行到版本目录 name（同目录的名字）。name 不合规（含目录不在）→ ValueError"""
    if valid(root, game, name) is None:
        raise ValueError(f'现行指针不合规：{game} → {name!r}（要 <款>@<标签>、不含路径、且 {Path(root) / str(name)} 是真目录）')
    _put(root, game, name, pointer(root, game))


def _link_name(path):
    """老现行链接指向的目录名（只取最后一级：版本目录都在产物根里）"""
    raw = os.readlink(path)
    for prefix in ('\\\\?\\', '\\??\\'):
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
    return raw.replace('\\', '/').rstrip('/').rsplit('/', 1)[-1]


def _remove_link(path):
    try:
        os.rmdir(path) if os.name == 'nt' and os.path.isdir(path) else os.unlink(path)
    except FileNotFoundError:
        pass


def _entries(root, prefix):
    try:
        with os.scandir(root) as it:
            return [Path(e.path) for e in it if e.name.startswith(prefix)]
    except FileNotFoundError:
        return []


def _mtime(path):
    try:
        return os.lstat(path).st_mtime_ns
    except OSError:
        return 0


def _free_name(root, game, want):
    """want（<款>@<标签>）没被占就用它，占了（或不合规）换一个没用过的"""
    tag = want[len(game) + 1:] if want and want.startswith(game + '@') else ''
    if not tag or tag == NAME or tag.startswith(NAME + '.') or any(c in want for c in '/\\\r\n\0') or want.endswith(('.tmp', '.tmp.rb')):
        tag = f'recovered-{time.time_ns()}'
    name, n = f'{game}@{tag}', 1
    while any(_kind(Path(root) / f'{name}{s}') is not None for s in ('', '.tmp', '.tmp.rb')):
        n += 1
        name = f'{game}@{tag}-{n}'
    return name


def normalize(root, game, log=None):
    """把这一款的现行规整成指针文件（调用方持该款提交锁）：
    ① 老软链 / junction：写临时指针 → 链接改名到旁边 <款>@现行.migr-<随机> → 临时指针改名成 <款>@现行 → 删旧链接；
    ② 实目录模式的真目录：写临时指针（内容 = .root_tag 记的版本名，被占 / 没记就起新名）→ 目录改名成该版本名 → 临时指针改名成 <款>@现行；
    ③ 断在中途（<款>@现行 不在）：有内容合规的临时指针就用最新那份，没有就从旁边的旧链接恢复；
    最后清掉残留的临时指针与旧链接。指针仍不合规 / 什么都没有时不动（调用方按「没有现行」处理）。→ 是否得到合规指针"""
    root = Path(root)
    say = log or (lambda m: print(m, file=sys.stderr))
    p = pointer(root, game)
    kind = _kind(p)
    if kind == 'link':
        name = _link_name(p)
        if valid(root, game, name) is None:   # 指向的版本已经不在：链接没用了，删掉、按没有现行处理
            say(f'【黄】{game} 的旧现行链接指向 {name}（不在 / 不合规），删掉')
            _remove_link(p)
        else:
            tmp = _put(root, game, name, None)
            aside = root / f'{_aside_prefix(game)}{uuid.uuid4().hex}'
            _retry(os.rename, p, aside)
            _retry(os.replace, tmp, p)
            _sync_dir(root)
            _remove_link(aside)
            say(f'{game} 现行从目录链接改成指针文件（→ {name}）')
    elif kind == 'dir':
        recorded = None
        try:
            recorded = _parse((p / TAG_FILE).read_bytes())
        except OSError:
            pass
        name = _free_name(root, game, recorded)
        tmp = _put(root, game, name, None)
        try:
            _retry(os.rename, p, root / name)
        except BaseException:
            os.unlink(tmp)
            raise
        _retry(os.replace, tmp, p)
        _sync_dir(root)
        try:
            os.unlink(root / name / TAG_FILE)
        except OSError:
            pass
        say(f'{game} 现行从实目录改成版本目录 {name} + 指针文件')
    elif kind is None:
        temps = sorted(_entries(root, _temp_prefix(game)), key=_mtime, reverse=True)
        pick = next((t for t in temps if _kind(t) == 'file' and valid(root, game, _parse(t.read_bytes())) is not None), None)
        if pick is not None:
            _retry(os.replace, pick, p)
            _sync_dir(root)
            say(f'{game} 现行按中断前写好的临时指针 {pick.name} 接上')
        else:
            for aside in sorted(_entries(root, _aside_prefix(game)), key=_mtime, reverse=True):
                name = _link_name(aside) if _kind(aside) == 'link' else None
                if name and valid(root, game, name) is not None:
                    write(root, game, name)
                    say(f'{game} 现行按迁移中途留下的旧链接接上（→ {name}）')
                    break
    ok = read(root, game) is not None
    if ok:
        for t in _entries(root, _temp_prefix(game)):
            try:
                os.unlink(t)
            except OSError:
                pass
        for aside in _entries(root, _aside_prefix(game)):
            if _kind(aside) == 'link':
                _remove_link(aside)
    return ok


def leftover(root, game):
    """有没有要 normalize 的东西：<款>@现行 是老形式（链接 / 目录），或有临时指针 / 迁移旁边的旧链接。
    指针是普通文件但内容不合规不算（normalize 也修不了，调用方按没有现行处理），免得每次取现行都去等提交锁"""
    if _kind(pointer(root, game)) in ('link', 'dir'):
        return True
    return bool(_entries(root, _temp_prefix(game)) or _entries(root, _aside_prefix(game)))


def resolve(root, game, lock=None):
    """现行版本目录 → Path | None。指针合规直接读；否则有老形式 / 中途残留时持锁（lock：() → 上下文管理器，该款提交锁）迁移后再读"""
    found = read(root, game)
    if found is not None or not leftover(root, game):
        return found
    if lock is None:
        normalize(root, game)
    else:
        with lock():
            normalize(root, game)
    return read(root, game)


if __name__ == '__main__':
    # bash 侧（pack/roots.sh）：current.py write <产物根> <款> <版本目录名> | normalize <产物根> <款>（调用方持提交锁）
    cmd, args = sys.argv[1], sys.argv[2:]
    try:
        if cmd == 'write':
            write(*args)
        elif cmd == 'normalize':
            sys.exit(0 if normalize(*args) else 1)
        else:
            sys.exit(f'【红】current.py 不认识的子命令 {cmd}')
    except (OSError, ValueError) as e:
        sys.exit(f'【红】现行指针 {cmd} 失败：{e}')
