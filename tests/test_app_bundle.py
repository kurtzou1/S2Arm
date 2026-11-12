# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original App/plist/PNG fixtures; expected values do not use the assembler."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
if (ROOT / 'pack/app_bundle.py').exists():
    from pack import app_bundle as bundle
else:
    bundle = None


def png(rgb=(255, 0, 0)):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress((b'\0' + bytes(rgb) * 2) * 2)) + chunk(b'IEND', b''))


def inventory(root):
    return {p.relative_to(root).as_posix(): None if p.is_dir() else p.read_bytes()
            for p in sorted(root.rglob('*'))}


class FixtureTests(unittest.TestCase):
    def test_original_png_specification(self):
        raw = png()
        self.assertEqual(struct.unpack('>II', raw[16:24]), (2, 2))
        self.assertEqual(zlib.decompress(raw[41:-16]), b'\0\xff\0\0\xff\0\0' * 2)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(bundle, 'pure-Python assembly entry missing; internal assertions not executed')
        self.temp = tempfile.TemporaryDirectory(prefix='s2arm-app-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'template'
        self.app.mkdir()
        self.info = {'CFBundleExecutable': 'S2Arm', 'CFBundleIdentifier': 'local.s2arm.app',
                     'CFBundleDisplayName': 'S2Arm', 'UIDeviceFamily': [1, 2],
                     'UIFileSharingEnabled': True, 'Unknown': {'data': b'original', 'number': 7}}
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.app / 'S2Arm').write_bytes(b'original non-executable synthetic host')
        (self.app / 'main.npdm').write_bytes(b'original synthetic metadata')
        (self.app / 'main.npdm').chmod(0o640)
        (self.app / '空 目录').mkdir()
        fw = self.app / 'Frameworks/Probe.framework'
        fw.mkdir(parents=True)
        (fw / 'Probe').write_bytes(b'original synthetic framework')
        (fw / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Probe'}))
        (self.app / 'Frameworks/extra.dylib').write_bytes(b'original synthetic dynamic library')
        (self.app / 'gal_helpers/m3').mkdir(parents=True)
        (self.app / 'gal_helpers/m3/original.metallib').write_bytes(b'original synthetic resource')
        self.icon = self.root / '原创 图标.png'
        self.icon.write_bytes(png())
        self.out = self.root / 'output/S2Arm.app'

    def assemble(self, **overrides):
        args = dict(bundle_id='org.s2arm.original', display_name='Original <Game> & Test',
                    icon=self.icon, metadata={'S2ABuildID': 'original-build'})
        args.update(overrides)
        return bundle.assemble(self.app, self.out, **args)

    def read_info(self, app=None):
        return plistlib.loads(((app or self.app) / 'Info.plist').read_bytes())

    def test_metadata_preserves_types_and_unknown_keys(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info, fmt=fmt))
                bundle.update_metadata(self.app, {'S2AGraphicsMode': 'direct'})
                self.assertEqual(self.read_info(), dict(self.info, S2AGraphicsMode='direct'))
                self.assertTrue((self.app / 'Info.plist').read_bytes().startswith(b'<?xml'))

    def test_empty_metadata_deletes_optional_keys(self):
        bundle.update_metadata(self.app, {'S2APsoTarget': 'old', 'S2AGraphicsModeReason': 'old'})
        bundle.update_metadata(self.app, {'S2APsoTarget': None, 'S2AGraphicsModeReason': ''})
        self.assertEqual(self.read_info(), self.info)

    def test_invalid_metadata_does_not_write(self):
        before = inventory(self.app)
        for values in ({'key': 1}, {'key': True}, {1: 'x'}, {'': 'x'}, {'bad\0key': 'x'}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                bundle.update_metadata(self.app, values)
        self.assertEqual(inventory(self.app), before)

    def test_malformed_plist_is_rejected(self):
        for data in (b'not plist', plistlib.dumps(['wrong root'])):
            with self.subTest(data=data):
                (self.app / 'Info.plist').write_bytes(data)
                with self.assertRaises(ValueError):
                    bundle.update_metadata(self.app, {'S2ABuildID': 'x'})

    def test_icons_dimensions_color_and_plist(self):
        from PIL import Image
        self.assertTrue(bundle.write_icons(self.icon, self.app))
        for scale, size in ((2, 120), (3, 180)):
            with Image.open(self.app / f'AppIcon60x60@{scale}x.png') as image:
                self.assertEqual(image.size, (size, size))
                self.assertEqual(image.format, 'PNG')
                self.assertEqual(image.convert('RGB').getextrema(), ((255, 255), (0, 0), (0, 0)))
        self.assertEqual(self.read_info()['CFBundleIcons'],
                         {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}})

    def test_missing_and_empty_icon_leave_app_unchanged(self):
        before = inventory(self.app)
        missing = self.root / 'missing.png'
        empty = self.root / 'empty.png'
        empty.touch()
        for path in (missing, empty):
            with self.subTest(path=path), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertFalse(bundle.write_icons(path, self.app))
                self.assertIn('黄', output.getvalue())
                self.assertEqual(inventory(self.app), before)

    def test_corrupt_icon_is_red_before_writes(self):
        self.icon.write_bytes(b'broken image')
        before = inventory(self.app)
        with self.assertRaises(ValueError):
            bundle.write_icons(self.icon, self.app)
        self.assertEqual(inventory(self.app), before)

    def test_no_pillow_is_diagnostic_not_an_install(self):
        result = subprocess.run([sys.executable, '-I', '-S', '-B', str(ROOT / 'pack/app_bundle.py'),
                                 'write_icons', str(self.icon), str(self.app)],
                                capture_output=True, encoding='utf-8')
        self.assertEqual(result.returncode, 1)
        self.assertIn('缺 Pillow', result.stderr)
        self.assertIn('不会自动下载', result.stderr)
        result = subprocess.run([sys.executable, '-I', '-S', '-B', str(ROOT / 'pack/app_bundle.py'),
                                 'update_metadata', str(self.app), '--set', 'S2ABuildID=original'],
                                capture_output=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_info()['S2ABuildID'], 'original')

    def test_import_preserves_callers_output_streams(self):
        import importlib.util
        out, err = io.StringIO(), io.StringIO()
        spec = importlib.util.spec_from_file_location('original_app_import', ROOT / 'pack/app_bundle.py')
        module = importlib.util.module_from_spec(spec)
        with patch.object(sys, 'stdout', out), patch.object(sys, 'stderr', err):
            spec.loader.exec_module(module)
            self.assertIs(sys.stdout, out)
            self.assertIs(sys.stderr, err)
        self.assertEqual(out.getvalue() + err.getvalue(), '')

    def test_two_caller_selected_identities_use_one_assembler(self):
        from PIL import Image
        before = inventory(self.app)
        for name, bid, color in [('Original <Game> & Test', 'org.s2arm.original', (255, 0, 0)),
                                 ('S2Arm', 'org.s2arm.library', (0, 0, 255))]:
            with self.subTest(name=name):
                self.out = self.root / bid / 'S2Arm.app'
                self.icon.write_bytes(png(color))
                result = self.assemble(display_name=name, bundle_id=bid)
                self.assertEqual(result, self.out.resolve())
                expected = dict(self.info, CFBundleIdentifier=bid, CFBundleDisplayName=name,
                                S2ABuildID='original-build',
                                CFBundleIcons={'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}})
                self.assertEqual(self.read_info(self.out), expected)
                with Image.open(self.out / 'AppIcon60x60@2x.png') as image:
                    self.assertEqual(image.convert('RGB').getpixel((60, 60)), color)
                self.assertEqual((self.out / 'Frameworks/Probe.framework/Probe').read_bytes(),
                                 before['Frameworks/Probe.framework/Probe'])
                self.assertTrue((self.out / '空 目录').is_dir())
        self.assertEqual(inventory(self.app), before)

    def test_identity_cannot_be_overridden_by_optional_metadata(self):
        self.assemble(metadata={'CFBundleIdentifier': 'org.wrong.id', 'CFBundleDisplayName': 'wrong'})
        self.assertEqual(self.read_info(self.out)['CFBundleIdentifier'], 'org.s2arm.original')
        self.assertEqual(self.read_info(self.out)['CFBundleDisplayName'], 'Original <Game> & Test')

    def test_display_name_ascii_and_localized(self):
        """11-04 S0-5：侧载工具拿 Info.plist 的 CFBundleDisplayName 建 App ID（苹果只收 ASCII，中文报「The name for this app is invalid」）：
        Info.plist 里只许 ASCII，中文名进 <语言>.lproj/InfoPlist.strings（含引号 / 反斜杠的转义），非 ASCII 显示名直接拒"""
        with self.assertRaises(ValueError):
            self.assemble(display_name='泰拉瑞亚 S2Arm')
        self.assertFalse(self.out.exists())
        self.assemble(display_name='Terraria S2Arm', localized_names={'zh-Hans': '泰拉瑞亚 S2Arm', 'zh-Hant': '名"字\\ S2Arm'})
        self.assertEqual(self.read_info(self.out)['CFBundleDisplayName'], 'Terraria S2Arm')
        self.assertEqual((self.out / 'zh-Hans.lproj/InfoPlist.strings').read_text(encoding='utf-8'), '"CFBundleDisplayName" = "泰拉瑞亚 S2Arm";\n')
        self.assertEqual((self.out / 'zh-Hant.lproj/InfoPlist.strings').read_text(encoding='utf-8'), '"CFBundleDisplayName" = "名\\"字\\\\ S2Arm";\n')
        out = subprocess.run(['plutil', '-p', str(self.out / 'zh-Hans.lproj/InfoPlist.strings')], capture_output=True, text=True) if sys.platform == 'darwin' else None
        if out is not None:   # 苹果自己的解析器读得出同一个值
            self.assertIn('泰拉瑞亚 S2Arm', out.stdout)

    def test_localized_names_merge_into_template_lproj(self):
        """#316：模板壳自带宿主界面字符串表 <语言>.lproj/S2ArmHost.strings（runtime/build.mk ios），本地化显示名要并进同一个 .lproj，不因目录已在而失败、也不丢原表"""
        (self.app / 'zh-Hans.lproj').mkdir(); (self.app / 'zh-Hans.lproj/S2ArmHost.strings').write_text('"common.ok" = "好";\n', encoding='utf-8')
        self.assemble(display_name='Terraria S2Arm', localized_names={'zh-Hans': '泰拉瑞亚 S2Arm'})
        self.assertEqual((self.out / 'zh-Hans.lproj/S2ArmHost.strings').read_text(encoding='utf-8'), '"common.ok" = "好";\n')
        self.assertEqual((self.out / 'zh-Hans.lproj/InfoPlist.strings').read_text(encoding='utf-8'), '"CFBundleDisplayName" = "泰拉瑞亚 S2Arm";\n')

    def test_localized_name_keeps_template_infoplist_keys(self):
        """#316：模板壳的 <语言>.lproj/InfoPlist.strings 带权限说明译文（本地网络 / 蓝牙）。出包写本地化显示名只换 / 补 CFBundleDisplayName 一行：
        其它键逐字保留；模板里已有的旧显示名被替换而不是追加第二条；模板没有显示名的语言追加一行"""
        perm = '/* 权限说明 */\n"NSLocalNetworkUsageDescription" = "本地联机：互相发现";\n"NSBluetoothAlwaysUsageDescription" = "连 \\"Pro\\" 手柄";\n'
        (self.app / 'zh-Hans.lproj').mkdir(); (self.app / 'zh-Hans.lproj/InfoPlist.strings').write_text(perm, encoding='utf-8')
        (self.app / 'en.lproj').mkdir(); (self.app / 'en.lproj/InfoPlist.strings').write_text('"CFBundleDisplayName" = "Old";\n"NSLocalNetworkUsageDescription" = "Local play";', encoding='utf-8')
        self.assemble(display_name='Terraria S2Arm', localized_names={'zh-Hans': '泰拉瑞亚 S2Arm', 'en': 'Terraria S2Arm', 'ja': 'テラリア S2Arm'})
        self.assertEqual((self.out / 'zh-Hans.lproj/InfoPlist.strings').read_text(encoding='utf-8'), perm + '"CFBundleDisplayName" = "泰拉瑞亚 S2Arm";\n')
        self.assertEqual((self.out / 'en.lproj/InfoPlist.strings').read_text(encoding='utf-8'), '"CFBundleDisplayName" = "Terraria S2Arm";\n"NSLocalNetworkUsageDescription" = "Local play";')
        self.assertEqual((self.out / 'ja.lproj/InfoPlist.strings').read_text(encoding='utf-8'), '"CFBundleDisplayName" = "テラリア S2Arm";\n')
        if sys.platform == 'darwin':   # 苹果自己的解析器读得出两种键
            out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(self.out / 'zh-Hans.lproj/InfoPlist.strings')], capture_output=True, text=True)
            self.assertEqual(json.loads(out.stdout), {'NSLocalNetworkUsageDescription': '本地联机：互相发现', 'NSBluetoothAlwaysUsageDescription': '连 "Pro" 手柄', 'CFBundleDisplayName': '泰拉瑞亚 S2Arm'})

    def test_existing_destination_is_not_overwritten(self):
        self.out.mkdir(parents=True)
        with self.assertRaises(ValueError):
            self.assemble()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_bad_identity_and_output_name_leave_no_result(self):
        for change in ({'bundle_id': ''}, {'bundle_id': '../escape'}, {'display_name': ''}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.assemble(**change)
        self.assertFalse(self.out.exists())
        self.out = self.root / 'Other.app'
        with self.assertRaises(ValueError):
            self.assemble()

    def test_output_inside_input_is_rejected(self):
        self.out = self.app / 'nested/S2Arm.app'
        before = inventory(self.app)
        with self.assertRaises(ValueError):
            self.assemble()
        self.assertEqual(inventory(self.app), before)

    def test_failed_copy_does_not_publish(self):
        before = inventory(self.app)
        with patch.object(bundle.shutil, 'copyfile', side_effect=OSError('synthetic failure')):
            with self.assertRaises(OSError):
                self.assemble()
        self.assertFalse(self.out.exists())
        self.assertEqual(inventory(self.app), before)
        self.assertEqual(list(self.out.parent.iterdir()), [])

    def test_signature_residue_rejected_for_assembly_and_mutation(self):
        for name in ('_CodeSignature', 'embedded.mobileprovision'):
            with self.subTest(name=name):
                residue = self.app / name
                residue.write_bytes(b'original fake signature residue')
                for call in (lambda: self.assemble(), lambda: bundle.update_metadata(self.app, {'k': 'v'}),
                             lambda: bundle.write_icons(self.icon, self.app)):
                    with self.assertRaises(ValueError):
                        call()
                residue.unlink()

    def test_symlinks_are_rejected_by_assembly_and_archive(self):
        link = self.app / 'alias'
        try:
            link.symlink_to(self.app / 'S2Arm')
        except OSError as error:
            self.skipTest(f'symlink creation unavailable: {error}')
        with self.assertRaises(ValueError):
            self.assemble()
        with self.assertRaises(ValueError):
            bundle.write_ipa(self.app, self.root / 'bad.ipa')

    @unittest.skipUnless(os.name == 'nt', 'Windows junction only')
    def test_windows_junction_is_rejected(self):
        link = self.app / 'junction'
        target = self.root / 'outside'
        target.mkdir()
        result = subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(target)],
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.addCleanup(lambda: os.rmdir(link) if link.exists() else None)
        with self.assertRaises(ValueError):
            self.assemble()
        with self.assertRaises(ValueError):
            bundle.write_ipa(self.app, self.root / 'bad.ipa')

    def test_real_parent_alias_is_not_confused_with_source_link(self):
        parent = self.root / 'actual'
        parent.mkdir()
        alias = self.root / 'alias'
        try:
            alias.symlink_to(parent, target_is_directory=True)
        except OSError as error:
            self.skipTest(f'symlink creation unavailable: {error}')
        self.out = alias / 'S2Arm.app'
        self.assertEqual(self.assemble(), (parent / 'S2Arm.app').resolve())

    @unittest.skipIf(os.name == 'nt', 'POSIX-only unsafe names; Windows normalizes names or creates ADS')
    def test_unsafe_or_colliding_paths_rejected(self):
        for name in ('bad:name', 'trailing.', 'NUL.txt'):
            with self.subTest(name=name):
                path = self.app / name
                try:
                    path.write_bytes(b'original')
                except OSError:
                    continue  # Windows rejects it before our API; Linux exercises these cases.
                try:
                    with self.assertRaises(ValueError):
                        self.assemble()
                finally:
                    path.unlink()

    @unittest.skipIf(os.name == 'nt', 'case-sensitive filesystem collision case')
    def test_case_collision_rejected(self):
        (self.app / 'Foo').mkdir()
        if (self.app / 'foo').exists():
            self.skipTest('case-insensitive filesystem cannot represent two case-colliding entries; controlled enumeration tested separately')
        (self.app / 'foo').mkdir()
        with self.assertRaises(ValueError):
            self.assemble()

    def test_case_collision_in_directory_enumeration_rejected(self):
        # A case-insensitive filesystem cannot materialize Foo and foo as two
        # directories. Exercise the production validator on that enumeration
        # on every host; the separate physical-tree test states its limitation.
        (self.app / 'Foo').mkdir()
        (self.app / 'foo').mkdir(exist_ok=True)
        real_iterdir = Path.iterdir
        root = self.app.resolve()

        def entries(folder):
            paths = list(real_iterdir(folder))
            if folder == root:
                paths = [p for p in paths if p.name not in ('Foo', 'foo')]
                paths += [folder / 'Foo', folder / 'foo']
            return iter(paths)

        with patch.object(Path, 'iterdir', entries):
            with self.assertRaisesRegex(ValueError, '大小写冲突'):
                bundle._tree(self.app, unsigned=True)

    def test_framework_executable_requires_valid_existing_file(self):
        info = self.app / 'Frameworks/Probe.framework/Info.plist'
        for value in ('../S2Arm', 'Missing', ''):
            with self.subTest(value=value):
                info.write_bytes(plistlib.dumps({'CFBundleExecutable': value}))
                with self.assertRaises(ValueError):
                    bundle.write_ipa(self.app, self.root / 'bad.ipa')

    def test_ipa_contents_modes_unicode_and_signed_bytes_unchanged(self):
        (self.app / '_CodeSignature').mkdir()
        (self.app / '_CodeSignature/CodeResources').write_bytes(b'original synthetic signature')
        (self.app / 'embedded.mobileprovision').write_bytes(b'original synthetic profile')
        (self.app / '中文 空格.bin').write_bytes(b'original unicode path')
        before = inventory(self.app)
        modes_before = {p.relative_to(self.app).as_posix(): p.stat().st_mode for p in self.app.rglob('*')}
        output = self.root / '原创 包.ipa'
        bundle.write_ipa(self.app, output)
        expected_exec = {'S2Arm', 'Frameworks/Probe.framework/Probe', 'Frameworks/extra.dylib'}
        prefix = 'Payload/S2Arm.app/'
        with zipfile.ZipFile(output) as archive:
            names = set(archive.namelist())
            self.assertEqual(names, {'Payload/', prefix} |
                             {prefix + p + ('/' if data is None else '') for p, data in before.items()})
            for entry in archive.infolist():
                self.assertEqual(entry.create_system, 3)
                rel = entry.filename[len(prefix):]
                mode = entry.external_attr >> 16
                self.assertEqual(stat.S_IMODE(mode),
                                 0o755 if entry.is_dir() or rel in expected_exec else 0o644)
                self.assertEqual(stat.S_IFMT(mode), stat.S_IFDIR if entry.is_dir() else stat.S_IFREG)
                if not entry.is_dir():
                    self.assertEqual(archive.read(entry), before[rel])
                    self.assertEqual(entry.compress_type, zipfile.ZIP_DEFLATED)
                if any(ord(c) > 127 for c in entry.filename):
                    self.assertTrue(entry.flag_bits & 0x800)
        self.assertEqual(inventory(self.app), before)
        self.assertEqual({p.relative_to(self.app).as_posix(): p.stat().st_mode for p in self.app.rglob('*')},
                         modes_before)

    def test_ipa_publish_on_drive_without_hard_links(self):
        # v0.3.1 exFAT：盘上建不了硬链接（macOS exFAT 实测 ENOTSUP、Windows WinError 1）→ 先核没有同名再改名放到位，内容完整；
        #   同名 IPA 已在照旧不覆盖（报错、原文件不变）；别的硬链接错误（如权限之外的 IO 错）照旧原样报
        import errno
        from unittest import mock
        output = self.root / 'exfat.ipa'
        with mock.patch.object(bundle.os, 'link', side_effect=OSError(errno.ENOTSUP, 'Operation not supported')):
            bundle.write_ipa(self.app, output)
            with zipfile.ZipFile(output) as archive:
                self.assertIn('Payload/S2Arm.app/', archive.namelist())
            before = output.read_bytes()
            with self.assertRaises((bundle.BundleError, FileExistsError)):   # 已有同名：先在 _destination 就拦（不覆盖）
                bundle.write_ipa(self.app, output)
            self.assertEqual(output.read_bytes(), before)
        with mock.patch.object(bundle.os, 'link', side_effect=OSError(errno.EIO, 'I/O error')), self.assertRaises(OSError):
            bundle.write_ipa(self.app, self.root / 'io.ipa')
        self.assertFalse((self.root / 'io.ipa').exists())

    def test_ipa_local_headers_match_central_directory(self):
        """11-04 S0-5：AltServer for Windows 1.8.1 自带 minizip 1.01e（不认 zip64），打开条目时核本地文件头与中央目录的 CRC / 两个大小一致；
        原先每个文件都强制 zip64，本地头写占位 0xFFFFFFFF + zip64 额外字段，侧载报「An unknown error occured while reading the file」。
        这里按 zip 规范自己解析每个本地文件头（不经 zipfile），小文件不许有 zip64 额外字段，且 CRC / 压缩后大小 / 原大小与中央目录逐项相同"""
        output = self.root / 'headers.ipa'
        bundle.write_ipa(self.app, output)
        raw = output.read_bytes()
        with zipfile.ZipFile(output) as archive:
            for e in archive.infolist():
                sig, _, flags, method, _, _, crc, csize, usize, nlen, xlen = struct.unpack_from('<IHHHHHIIIHH', raw, e.header_offset)
                self.assertEqual(sig, 0x04034b50, e.filename)
                self.assertFalse(flags & 0x8, f'{e.filename}：不该用数据描述符')
                extra = raw[e.header_offset + 30 + nlen:e.header_offset + 30 + nlen + xlen]
                self.assertNotIn(b'\x01\x00', [extra[i:i + 2] for i in range(0, len(extra), 2)][:1], f'{e.filename}：小文件不该带 zip64 额外字段')
                self.assertEqual((crc, csize, usize), (e.CRC, e.compress_size, e.file_size), e.filename)
                need = struct.unpack_from('<H', raw, e.header_offset + 4)[0]
                self.assertLessEqual(need, 20, f'{e.filename}：本地头「解压所需版本」{need / 10} > 2.0（2.0 = deflate、无 zip64）')
        # 中央目录也按原始字节读：每条的「解压所需版本」≤ 2.0
        end = raw.rfind(b'PK\x05\x06'); count, _, cd_off = struct.unpack_from('<HII', raw, end + 10)
        off = cd_off
        for _ in range(count):
            self.assertEqual(raw[off:off + 4], b'PK\x01\x02')
            made, need = struct.unpack_from('<HH', raw, off + 4)
            nlen, xlen, clen = struct.unpack_from('<HHH', raw, off + 28)
            self.assertLessEqual(need, 20, f'中央目录 {raw[off + 46:off + 46 + nlen].decode()}：解压所需版本 {need / 10}')
            off += 46 + nlen + xlen + clen

    def test_ipa_does_not_overwrite_and_cannot_be_inside_app(self):
        output = self.root / 'existing.ipa'
        output.write_bytes(b'previous')
        with self.assertRaises(ValueError):
            bundle.write_ipa(self.app, output)
        self.assertEqual(output.read_bytes(), b'previous')
        with self.assertRaises(ValueError):
            bundle.write_ipa(self.app, self.app / 'inside.ipa')

    def test_ipa_over_zip32_budget_is_a_readable_red_line(self):
        """11-08 反馈：9.78 GB 的 PERSONA4 The GOLDEN 出包停在「出包 2/5」、错误码 package_failed「原因没认出来」。
        不写 zip64（侧载工具读不了）时超过 32 位上限，zipfile 收尾才抛 LargeZipFile——它不是 OSError，父进程只看到「打 ipa 失败」。
        这里三层都按规则手写预期：条目数预先判死、单文件预先判死、收尾的 LargeZipFile 转成带体积账的 BundleError；三种都不留临时件"""
        entries = sum(1 for _ in bundle._tree(self.app)[1])
        with patch.object(bundle, 'ZIP32_ENTRIES', entries - 1):
            with self.assertRaises(ValueError) as got:
                bundle.write_ipa(self.app, self.root / 'entries.ipa')
        self.assertIn(f'{entries} 个条目', str(got.exception))
        self.assertFalse((self.root / 'entries.ipa').exists())
        with patch.object(bundle, 'ZIP32_MAX', 8):
            with self.assertRaises(ValueError) as got:
                bundle.write_ipa(self.app, self.root / 'single.ipa')
        self.assertIn('单个文件超过 zip 32 位上限', str(got.exception))
        self.assertFalse((self.root / 'single.ipa').exists())

        class _FullZip(bundle.zipfile.ZipFile):   # 压缩后装不下：zipfile 在收尾时抛 LargeZipFile（真实行为，见 zipfile._write_end_record）
            def close(self):
                raise zipfile.LargeZipFile('Filesize would require ZIP64 extensions')
            def __del__(self):   # 桩：不让 GC 里再抛一次、把噪音写进被测进程的标准错误
                pass

        with patch.object(bundle.zipfile, 'ZipFile', _FullZip):
            with self.assertRaises(ValueError) as got:
                bundle.write_ipa(self.app, self.root / 'full.ipa')
        message = str(got.exception)
        self.assertIn('非 zip64 的 IPA 装不下这份 App', message)
        self.assertIn(f'{entries} 个条目', message)
        self.assertIn('文件合计', message)
        self.assertIn('Filesize would require ZIP64 extensions', message)
        self.assertFalse((self.root / 'full.ipa').exists())
        self.assertFalse(list(self.root.glob('.ipa-*')))

    def test_main_turns_large_zipfile_into_one_red_line(self):
        """write_ipa 之外的口子也要兜住：LargeZipFile 不是 OSError，落成裸 traceback 时调用方只拿到退出码，原因就断了"""
        with patch.object(bundle, 'write_ipa', side_effect=zipfile.LargeZipFile('Filesize would require ZIP64 extensions')):
            with contextlib.redirect_stderr(io.StringIO()) as err, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(bundle.main(['write_ipa', str(self.app), str(self.root / 'cli.ipa')]), 1)
        self.assertIn('【红】App 组装：Filesize would require ZIP64 extensions', err.getvalue())
        self.assertNotIn('Traceback', err.getvalue())

    def test_archive_failure_cleans_temporary_output(self):
        output = self.root / 'failed.ipa'
        with patch.object(bundle.zipfile.ZipFile, 'open', side_effect=OSError('synthetic failure')):
            with self.assertRaises(OSError):
                bundle.write_ipa(self.app, output)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob('.ipa-*')))

    def test_app_only_never_creates_zip(self):
        with patch.object(bundle.zipfile, 'ZipFile', side_effect=AssertionError('must not zip')):
            self.assemble()
        self.assertTrue(self.out.is_dir())
        self.assertFalse(list(self.root.rglob('*.ipa')))

    def test_cli_without_isolation_does_not_import_pack_py(self):
        result = subprocess.run([sys.executable, '-X', 'utf8=0', '-B',
                                 str(ROOT / 'pack/app_bundle.py'), 'update_metadata',
                                 str(self.app), '--set', 'S2ABuildID=生产入口'],
                                capture_output=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_info()['S2ABuildID'], '生产入口')

    def test_cli_utf8_and_all_four_entries(self):
        def run(*args):
            return subprocess.run([sys.executable, '-X', 'utf8=0', '-I', '-B',
                                   str(ROOT / 'pack/app_bundle.py'), *map(str, args)],
                                  capture_output=True, encoding='utf-8')
        result = run('assemble', self.app, self.out, '--bundle-id', 'org.s2arm.cli',
                     '--display-name', 'Original <Game>', '--icon', self.icon)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('S2Arm.app', result.stdout)
        self.assertEqual(run('write_icons', self.icon, self.out).returncode, 0)
        self.assertEqual(run('update_metadata', self.out, '--set', 'S2ABuildID=原创包').returncode, 0)
        self.assertEqual(self.read_info(self.out)['S2ABuildID'], '原创包')
        result = run('write_ipa', self.out, self.root / 'CLI.ipa')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(run('assemble', self.app, self.out, '--bundle-id', 'org.s2arm.cli',
                             '--display-name', 'Dup', '--icon', self.icon).returncode, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
