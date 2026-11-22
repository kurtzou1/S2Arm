#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Cross-host post-build iOS App assembly. See APP_BUNDLE.md for ownership and limits."""
from __future__ import annotations

import argparse
import errno
import io
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import sys
import tempfile
import warnings
import zipfile
import zlib

if __package__ in (None, ''):
    # A normal script launch adds pack/ to sys.path: its pack.py would shadow
    # the repository's namespace package. Isolated (-I) launches omit it.
    if sys.path and Path(sys.path[0]).resolve() == Path(__file__).resolve().parent:
        sys.path.pop(0)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.shell.manifest import validate_download_paths
from pack import widget_ext
from pack.orch.dirrename import rename_dir   # 目录改名带 Windows 杀软 / 索引占用退避重试（#361；D-ZPA3：刚组装完的 S2Arm.app 改名就位报 WinError 5）


class BundleError(ValueError):
    """App input or output does not satisfy the assembly contract."""


def _plain(path):
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400
            or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))):
        raise BundleError(f'拒绝链接、重解析点或特殊文件：{path}')
    return info


def _tree(app, *, unsigned=False):
    app = Path(app)
    if not stat.S_ISDIR(_plain(app).st_mode):
        raise BundleError(f'不是 App 目录：{app}')
    app = app.resolve()
    entries, seen = [], set()

    def walk(folder):
        for path in sorted(folder.iterdir()):
            info = _plain(path)  # Check before recursing; never follow a directory link.
            rel = path.relative_to(app).as_posix()
            validate_download_paths([{'path': rel}])
            if rel.casefold() in seen:
                raise BundleError(f'App 路径大小写冲突：{rel}')
            seen.add(rel.casefold())
            if unsigned and path.name in ('_CodeSignature', 'embedded.mobileprovision'):
                raise BundleError(f'组装模板须未签名，发现签名残留：{rel}')
            directory = stat.S_ISDIR(info.st_mode)
            entries.append((path, rel, directory))
            if directory:
                walk(path)
    walk(app)
    return app, entries


def _plist(path):
    if not stat.S_ISREG(_plain(path).st_mode):
        raise BundleError(f'不是普通 plist 文件：{path}')
    try:
        result = plistlib.loads(path.read_bytes())
    except (ValueError, TypeError, OverflowError) as error:
        raise BundleError(f'plist 读不了：{path.name}：{error}') from error
    if not isinstance(result, dict):
        raise BundleError(f'plist 根必须是字典：{path.name}')
    return result


def _executable(info, folder):
    name = info.get('CFBundleExecutable')
    if (not isinstance(name, str) or not name or '/' in name or '\\' in name
            or name in ('.', '..')):
        raise BundleError('CFBundleExecutable 必须是当前 bundle 内的单个文件名')
    validate_download_paths([{'path': name}])
    path = folder / name
    try:
        regular = stat.S_ISREG(_plain(path).st_mode)
    except FileNotFoundError as error:
        raise BundleError(f'缺主程序文件：{name}') from error
    if not regular:
        raise BundleError(f'主程序不是普通文件：{name}')
    return path


def _info(app):
    info = _plist(app / 'Info.plist')
    _executable(info, app)
    return info


def _executable_paths(app, entries):
    result = {_executable(_info(app), app).relative_to(app).as_posix()}
    for path, rel, directory in entries:
        if not directory and path.suffix == '.dylib':
            result.add(rel)
        if directory and path.parent == app / 'Frameworks' and path.suffix == '.framework':
            result.add(_executable(_plist(path / 'Info.plist'), path).relative_to(app).as_posix())
    result.update(widget_ext.executables(app))   # 主屏小组件扩展的程序（PlugIns/*.appex，11-16）：组装 / 打 IPA 都要保留可执行位
    return result


def _atomic_write(path, data):
    fd, temp = tempfile.mkstemp(prefix='.app-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


def _metadata(info, values):
    if not isinstance(values, dict):
        raise BundleError('元数据必须是键值字典')
    updated = dict(info)
    for key, value in values.items():
        if (not isinstance(key, str) or not key or any(ord(c) < 32 for c in key)
                or not (value is None or isinstance(value, str))):
            raise BundleError('元数据键须非空字符串，值只认字符串或 None')
        if value in (None, ''):
            updated.pop(key, None)
        else:
            updated[key] = value
    # Serialize before touching the old plist, including illegal XML characters.
    try:
        return plistlib.dumps(updated, fmt=plistlib.FMT_XML, sort_keys=False)
    except (ValueError, TypeError, OverflowError) as error:
        raise BundleError(f'元数据不能写成 XML plist：{error}') from error


def update_metadata(app_dir, values):
    """Update string keys (empty/None deletes); caller owns an unsigned new build."""
    app, _ = _tree(app_dir, unsigned=True)
    data = _metadata(_info(app), values)
    _executable(plistlib.loads(data), app)
    _atomic_write(app / 'Info.plist', data)
    if values.get('CFBundleIdentifier'):   # 主包名变了：小组件扩展包名跟着改成 <主包名>.widget（苹果要求扩展包名以主包名开头）
        widget_ext.retarget(app, values['CFBundleIdentifier'])


def write_icons(icon_path, app_dir):
    """Write 120/180 PNGs and CFBundleIcons. Missing/empty icon leaves App unchanged."""
    icon = Path(icon_path)
    if not icon.exists() and not icon.is_symlink():
        print(f'【黄】没有图标 {icon}：不加 AppIcon，沿用系统缺省图标')
        return False
    icon_stat = _plain(icon)
    if not stat.S_ISREG(icon_stat.st_mode):
        raise BundleError(f'图标不是普通文件：{icon}')
    if icon_stat.st_size == 0:
        print(f'【黄】空图标 {icon}：不加 AppIcon，沿用系统缺省图标')
        return False
    app, _ = _tree(app_dir, unsigned=True)
    if (app / 'Assets.car').is_file():   # tvOS 壳：主屏图标已编进 Assets.car（pack/tv_icon.py，tvOS 不认散装 PNG），不写、不覆盖 CFBundleIcons（#1457）
        return False
    info = _info(app)
    try:
        from PIL import Image
    except ImportError as error:
        raise BundleError('缺 Pillow：请在出包环境手动安装 launchers/macos/requirements-runtime.txt；不会自动下载') from error
    try:
        # Turn Pillow's oversized-input warning into a failure, not a silent huge allocation.
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(icon) as image:
                image.load()
                image = image.convert('RGB')
                rendered = []
                for scale, size in ((2, 120), (3, 180)):
                    data = io.BytesIO()
                    image.resize((size, size), Image.Resampling.LANCZOS).save(data, format='PNG')
                    rendered.append((app / f'AppIcon60x60@{scale}x.png', data.getvalue()))
    except (OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
        raise BundleError(f'图标打不开或缩放失败：{icon.name}：{error}') from error
    info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}}
    plist_data = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
    for path, data in rendered:
        _atomic_write(path, data)
    _atomic_write(app / 'Info.plist', plist_data)
    return True


def _destination(path, app):
    path = Path(path)
    if os.path.lexists(path):
        raise BundleError(f'不覆盖已有目标：{path}')
    dest = path.resolve()
    if dest.is_relative_to(app) or app.is_relative_to(dest):
        raise BundleError('输出不能和源 App 重叠')
    dest.parent.mkdir(parents=True, exist_ok=True)
    return dest


def _set_display_name(strings, esc):
    """<语言>.lproj/InfoPlist.strings 只换 / 补 CFBundleDisplayName 这一行：模板壳自带的同表其它键（本地网络 / 蓝牙权限说明的译文，#316）原样保留"""
    line = f'"CFBundleDisplayName" = "{esc}";'
    text = strings.read_text(encoding='utf-8') if strings.exists() else ''
    pat = re.compile(r'^"CFBundleDisplayName"\s*=\s*"(?:[^"\\]|\\.)*";[ \t]*$', re.M)
    if pat.search(text): text = pat.sub(lambda m: line, text)
    else: text = (text if not text or text.endswith('\n') else text + '\n') + line + '\n'
    strings.write_text(text, encoding='utf-8', newline='\n')


def assemble(template_app, output_app, *, bundle_id, display_name, icon, metadata=None, localized_names=None):
    """Copy a read-only, previously verified unsigned template; atomically publish a new App."""
    if (not isinstance(bundle_id, str)
            or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id)):
        raise BundleError('包名须为显式的反向域名形式')
    if not isinstance(display_name, str) or not display_name.strip():
        raise BundleError('显示名须为非空字符串')
    if not display_name.isascii():   # 侧载工具（AltServer 等）拿 CFBundleDisplayName 建 App ID，苹果只收 ASCII；本地化名走 localized_names
        raise BundleError(f'Info.plist 的显示名须为 ASCII（中文名放 localized_names）：{display_name}')
    if Path(output_app).name != 'S2Arm.app':
        raise BundleError('输出目录名必须是 S2Arm.app，显示名由 plist 决定')
    source, entries = _tree(template_app, unsigned=True)
    _info(source)
    values = dict(metadata or {})
    values.update(CFBundleIdentifier=bundle_id, CFBundleDisplayName=display_name)
    _metadata(_info(source), values)  # Validate before copying or publishing.
    dest = _destination(output_app, source)
    temp = Path(tempfile.mkdtemp(prefix='.assemble-', dir=dest.parent))
    try:
        for path, rel, directory in entries:
            target = temp / rel
            if directory:
                target.mkdir()
            else:
                before = _plain(path)
                shutil.copyfile(path, target)
                after = _plain(path)
                if ((before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns)
                        or target.stat().st_size != before.st_size):
                    raise BundleError(f'复制期间模板文件变了：{rel}')
        update_metadata(temp, values)
        for lang, name in sorted((localized_names or {}).items()):   # 本地化显示名：<语言>.lproj/InfoPlist.strings（手机按系统语言显示，Info.plist 本体保持 ASCII）
            if not re.fullmatch(r'[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*', lang) or not isinstance(name, str) or not name.strip():
                raise BundleError(f'本地化显示名不合法：{lang}={name!r}')
            esc = name.replace('\\', '\\\\').replace('"', '\\"')
            d = temp / f'{lang}.lproj'; d.mkdir(exist_ok=True)   # 模板壳自带同语言 .lproj（宿主界面字符串表 S2ArmHost.strings，#316）：并进去，不覆盖原表
            _set_display_name(d / 'InfoPlist.strings', esc)
        write_icons(icon, temp)
        _, copied = _tree(temp, unsigned=True)
        executable = _executable_paths(temp, copied)
        for path, rel, directory in copied:
            path.chmod(0o755 if directory or rel in executable else 0o644)
        temp.chmod(0o755)
        if os.path.lexists(dest):
            raise BundleError(f'不覆盖已有目标：{dest}')
        rename_dir(temp, dest)   # 刚写完整个 App 目录，Windows 上杀软 / 索引还开着里面文件的句柄时直接改名报 WinError 5（D-ZPA3），按 #361 同一套退避
        return dest
    finally:
        if temp.exists():
            shutil.rmtree(temp)


# zip32 的三道物理闸，按侧载工具真实读法分开（不写 zip64：AltServer for Windows 1.8.1 自带 minizip 1.01e 不认 zip64，
#   强制 zip64 时本地头写占位大小、与中央目录不一致，打开条目即 UNZ_BADZIPFILE，11-04 S0-5）：
#   ① 条目数：中央目录计数是 16 位。
#   ② 单条目字节：大小字段是无符号 32 位，minizip 也按无符号 uLong 读、按 uLong 计解压进度 → 4 GiB − 1。
#   ③ 整份 IPA 的字节（= 任何本地头 / 中央目录的偏移上限）：minizip 1.01e 的 ioapi 用 C 的 fseek(long) / ftell 定位，
#      Windows 上 long 是 32 位有符号 → 2 GiB − 1。
#   Python zipfile 把 ②③ 合成一条 ZIP64_LIMIT（2 GiB − 1）：2.40 GiB 的 S2AImages.dylib 压缩后整份不到 2 GiB，
#   照样被拒「单个文件超过 zip 32 位上限」（#636）。所以这里自己写 zip32 条目，两道闸各管各的。
#   超了给一条带体积账的红行，不落裸 traceback（#11：父进程只拿得到退出码）。
ZIP32_ENTRIES = 0xFFFF            # 条目数上限（65535）
ZIP32_ENTRY_MAX = 0xFFFFFFFF      # 单条目原大小 / 压缩后大小上限（4 GiB − 1）
ZIP32_ARCHIVE_MAX = 0x7FFFFFFF    # 整份 IPA 字节上限（2 GiB − 1）
_DOS_EPOCH = (0, 0x21)            # 1980-01-01 00:00:00（与 zipfile.ZipInfo 默认时间相同：签后 IPA 不带构建时间）


class _ArchiveFull(BundleError):
    """压缩后整份 IPA 过了 ZIP32_ARCHIVE_MAX；write_ipa 补上体积账再报。"""


class _Zip32Writer:
    """只写 zip32 的流式归档：本地头先写占位，数据写完回填 CRC / 两个大小（不用数据描述符，minizip 要本地头与中央目录逐项一致）。"""

    def __init__(self, stream):
        self.stream, self.central = stream, []

    def _room(self, extra):
        if self.stream.tell() + extra > ZIP32_ARCHIVE_MAX:
            raise _ArchiveFull(f'整份超过 {ZIP32_ARCHIVE_MAX} 字节')

    def _header(self, name, directory, executable):
        raw = name.encode('utf-8')
        flags = 0x800 if any(ord(c) > 127 for c in name) else 0
        method, need = (0, 20) if directory else (8, 20)   # 2.0 = deflate、无 zip64（与原 zipfile 写法相同）
        mode = 0o755 if directory or executable else 0o644
        kind = stat.S_IFDIR if directory else stat.S_IFREG
        attr = ((kind | mode) << 16) | (0x10 if directory else 0)
        self._room(30 + len(raw))
        offset = self.stream.tell()
        self.stream.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, need, flags, method, *_DOS_EPOCH, 0, 0, 0, len(raw), 0) + raw)
        return dict(raw=raw, flags=flags, method=method, need=need, attr=attr, offset=offset, crc=0, csize=0, usize=0)

    def add_dir(self, name):
        self.central.append(self._header(name, True, False))

    def add_file(self, name, source, executable):
        entry = self._header(name, False, executable)
        squeeze = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15)
        crc = usize = 0
        start = self.stream.tell()

        def put(data):
            self._room(len(data))
            self.stream.write(data)

        while chunk := source.read(1024 * 1024):
            crc, usize = zlib.crc32(chunk, crc), usize + len(chunk)
            if usize > ZIP32_ENTRY_MAX:
                raise BundleError(f'单个文件超过 zip 32 位上限（{ZIP32_ENTRY_MAX} 字节）、侧载工具读不了：{name}')
            put(squeeze.compress(chunk))
        put(squeeze.flush())
        end = self.stream.tell()
        csize = end - start
        if csize > ZIP32_ENTRY_MAX:
            raise BundleError(f'单个文件压缩后超过 zip 32 位上限（{ZIP32_ENTRY_MAX} 字节）：{name}')
        self.stream.seek(entry['offset'] + 14)
        self.stream.write(struct.pack('<III', crc, csize, usize))
        self.stream.seek(end)
        entry.update(crc=crc, csize=csize, usize=usize)
        self.central.append(entry)

    def close(self):
        directory = b''.join(
            struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, (3 << 8) | 20, e['need'], e['flags'], e['method'], *_DOS_EPOCH,
                        e['crc'], e['csize'], e['usize'], len(e['raw']), 0, 0, 0, 0, e['attr'], e['offset']) + e['raw']
            for e in self.central)
        self._room(len(directory) + 22)
        start = self.stream.tell()
        self.stream.write(directory)
        self.stream.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(self.central), len(self.central),
                                      len(directory), start, 0))
        self.stream.flush()


def _zip32_budget(entries):
    """归档前的体积账（只 lstat，不读内容）：→ (条目数, 文件总字节, 最大的那个文件 (相对路径, 字节))。
    条目数与单条目上限能提前判死；整份的字节上限取决于压缩后大小，写的时候才知道（见 write_ipa 的 _ArchiveFull 分支）。"""
    count, total, biggest = 0, 0, ('', 0)
    for path, rel, directory in entries:
        count += 1
        if directory:
            continue
        size = _plain(path).st_size
        total += size
        if size > biggest[1]:
            biggest = (rel, size)
    return count, total, biggest


def write_ipa(signed_app, output_ipa):
    """Archive only: never mutate signed bytes. Permissions derive from bundle metadata."""
    app, entries = _tree(signed_app)
    executable = _executable_paths(app, entries)
    count, total, (biggest, biggest_size) = _zip32_budget(entries)
    if count + 2 > ZIP32_ENTRIES:   # 另有 Payload/ 与 Payload/S2Arm.app/ 两个目录条目
        raise BundleError(f'App 有 {count} 个条目，超过非 zip64 归档的 {ZIP32_ENTRIES} 个上限（侧载工具读不了 zip64）')
    if biggest_size > ZIP32_ENTRY_MAX:
        raise BundleError(f'单个文件超过 zip 32 位上限（{ZIP32_ENTRY_MAX} 字节）、侧载工具读不了：{biggest}（{biggest_size} 字节）')
    dest = _destination(output_ipa, app)
    fd, name = tempfile.mkstemp(prefix='.ipa-', dir=dest.parent)
    temp = Path(name)
    try:
        try:
            with os.fdopen(fd, 'w+b') as stream:
                archive = _Zip32Writer(stream)
                prefix = 'Payload/S2Arm.app/'
                archive.add_dir('Payload/')
                archive.add_dir(prefix)
                for path, rel, directory in entries:
                    if directory:
                        archive.add_dir(prefix + rel + '/')
                        continue
                    before = _plain(path)
                    with path.open('rb') as source:
                        archive.add_file(prefix + rel, source, rel in executable)
                    after = _plain(path)
                    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                        raise BundleError(f'归档期间文件变了：{rel}')
                archive.close()
        except _ArchiveFull as error:   # 压缩后装不下：给一条带体积账的红行
            raise BundleError(f'非 zip64 的 IPA 装不下这份 App：{count} 个条目、文件合计 {total} 字节、最大 {biggest} {biggest_size} 字节；'
                              f'{error}（侧载工具按 32 位有符号偏移读 IPA）') from error
        # Atomic no-replace publication on both hosts; no fallback that overwrites an existing IPA.
        try:
            os.link(temp, dest)
        except FileExistsError:
            raise
        except OSError as error:   # 盘上建不了硬链接（exFAT / FAT32，v0.3.1）：先核没有同名再改名放到位，仍不覆盖已有的 IPA
            if error.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.EPERM, errno.EXDEV, errno.EINVAL) and getattr(error, "winerror", None) != 1:
                raise
            if os.path.lexists(dest):
                raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), str(dest)) from error
            os.replace(temp, dest)
        return dest
    finally:
        temp.unlink(missing_ok=True)


def _values(arguments):
    values = {}
    for item in arguments:
        key, separator, value = item.partition('=')
        if not separator or key in values:
            raise BundleError('--set 须为不重复的 KEY=VALUE，空值删键')
        values[key] = value
    return values


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    icons = commands.add_parser('write_icons')
    icons.add_argument('icon')
    icons.add_argument('app')
    metadata = commands.add_parser('update_metadata')
    metadata.add_argument('app')
    metadata.add_argument('--set', action='append', default=[])
    build = commands.add_parser('assemble')
    build.add_argument('template')
    build.add_argument('output')
    build.add_argument('--bundle-id', required=True)
    build.add_argument('--display-name', required=True)
    build.add_argument('--icon', required=True)
    build.add_argument('--set', action='append', default=[])
    ipa = commands.add_parser('write_ipa')
    ipa.add_argument('app')
    ipa.add_argument('output')
    args = parser.parse_args(argv)
    try:
        if args.command == 'write_icons':
            write_icons(args.icon, args.app)
        elif args.command == 'update_metadata':
            update_metadata(args.app, _values(args.set))
        elif args.command == 'assemble':
            print(assemble(args.template, args.output, bundle_id=args.bundle_id,
                           display_name=args.display_name, icon=args.icon, metadata=_values(args.set)))
        else:
            print(write_ipa(args.app, args.output))
    except (OSError, ValueError, RuntimeError, zipfile.LargeZipFile) as error:
        # LargeZipFile 不是 OSError（zipfile 自己的异常类型）：write_ipa 里已转成带体积账的 BundleError，
        #   这里再兜一层，任何一条路都不许落成裸 traceback——父进程只拿得到退出码，原因就断了。
        print(f'【红】App 组装：{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    raise SystemExit(main())
