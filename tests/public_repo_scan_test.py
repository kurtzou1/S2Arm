"""Original synthetic fixtures: no production identifiers, assets or user files."""
import importlib.util
import hashlib
import io
import zipfile
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools/public_repo_scan.py'
RULES = ROOT / 'tools/public_repo_scan_rules.json'


def module():
    spec = importlib.util.spec_from_file_location('public_repo_scan', TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.mod = module()

    def git(self, *args):
        # stdin 接空（11-09：hash-object --stdin 原先读继承来的标准输入，调用方给的是不关的管道时整份单测挂到超时 124）
        return subprocess.run(['git', '-C', str(self.root), *args], check=True, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, files):
        for name, content in files.items():
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(content if isinstance(content, bytes) else content.encode())
        self.git('add', '.')
        self.git('commit', '-qm', 'synthetic fixture')
        return self.git('rev-parse', 'HEAD')

    def scan(self, *args):
        p = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.root),
                            '--path', '.', *args], capture_output=True, text=True)
        return p, json.loads(p.stdout) if p.stdout else None

    def test_full_scan_unknown_only_is_red_and_deletion_clears(self):
        self.commit({'unknown.xyz': b'original unknown-type fixture'})
        proc, report = self.scan()
        self.assertEqual(report['findings'], [])
        self.assertEqual(report['coverage'], {'unreviewed_type': 1})
        self.assertEqual(proc.returncode, 1, 'unread full scan must not be clean')
        self.assertEqual(report['uncovered_blocking'], report['uncovered'])
        gate = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.root),
                               '--path', '.', '--format', 'gate'], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 1)
        self.assertIn('unknown.xyz', gate.stdout)
        self.git('rm', 'unknown.xyz')
        self.commit({'safe.md': 'original safe text\n'})
        clean, report = self.scan()
        self.assertEqual(clean.returncode, 0)
        self.assertEqual(report['uncovered_blocking'], [])

    def archive_rules(self, path='Vendor/dependency.zip', data=None):
        if data is None:
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as archive:
                archive.writestr('LICENSE.txt', 'Original synthetic archive fixture')
            data = stream.getvalue()
        rules = self.mod.load_rules()
        rules['reviewed_archives'] = [{'id': 'synthetic_archive', 'path': path,
            'sha256': hashlib.sha256(data).hexdigest(), 'reason': 'Original test ZIP only'}]
        return rules, data

    def test_reviewed_archive_hash_only_keeps_unscanned_boundary_visible(self):
        rules, data = self.archive_rules()
        self.commit({'Vendor/dependency.zip': data})
        with patch.object(self.mod, 'load_rules', return_value=rules):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(report['coverage'], {'excluded_payload': 1})
        self.assertEqual(report['uncovered_blocking'], [])
        self.assertEqual(report['uncovered_allowed'][0]['reason'], 'excluded_payload')
        self.assertEqual(report['uncovered_allowed'][0]['reviewed_archive'], 'synthetic_archive')
        self.assertEqual(report['uncovered'], report['uncovered_allowed'])
        output = io.StringIO()
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                sys, 'argv', ['public_repo_scan', '--repo', str(self.root), '--path', '.',
                              '--format', 'gate']), redirect_stdout(output):
            self.assertEqual(self.mod.main(), 0)
        self.assertIn('SHA-256 已核对（仍未扫描正文）', output.getvalue())

    def test_reviewed_archive_tamper_blocks_full_and_changed_scan(self):
        rules, data = self.archive_rules()
        base = self.commit({'Vendor/dependency.zip': data})
        self.commit({'Vendor/dependency.zip': data + b'original tamper fixture'})
        with patch.object(self.mod, 'load_rules', return_value=rules):
            for baseline in (None, base):
                report = self.mod.scan(self.root, 'HEAD', ['.'], base=baseline)
                self.assertEqual(len(report['uncovered_blocking']), 1)
                self.assertEqual(report['uncovered_allowed'], [])

    def test_reviewed_archive_does_not_allow_another_zip_or_read_it(self):
        rules, data = self.archive_rules()
        self.commit({'Vendor/another.zip': data})
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('unreviewed ZIP read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(len(report['uncovered_blocking']), 1)
        self.assertEqual(report['uncovered_allowed'], [])

    def test_reviewed_archive_cannot_read_sensitive_paths_or_git_links(self):
        paths = ['prod.keys', 'secrets/dependency.zip', 'games/dependency.zip',
                 'assets/dependency.zip', 'firmware/dependency.zip', 'romfs/dependency.zip']
        rules, data = self.archive_rules()
        self.commit({p: data for p in paths})
        oid = self.git('hash-object', '-w', '--stdin')
        self.git('update-index', '--add', '--cacheinfo', '120000,' + oid + ',Vendor/link.zip')
        self.git('commit', '-qm', 'synthetic archive link')
        paths.append('Vendor/link.zip')
        template = rules['reviewed_archives'][0]
        rules['reviewed_archives'] = [{**template, 'path': p} for p in paths]
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('sensitive or link read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(len(report['uncovered_blocking']), len(paths))
        self.assertEqual(report['uncovered_allowed'], [])

    def test_reviewed_archive_list_only_and_oversized_never_read(self):
        rules, data = self.archive_rules()
        self.commit({'Vendor/dependency.zip': data})
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('list-only read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'], list_only=True)
        self.assertEqual(report['manifest'][0]['decision'], 'excluded_payload')
        self.assertEqual(report['uncovered_allowed'], [])
        self.commit({'Vendor/dependency.zip': b'Z' * (self.mod.MAX_BYTES + 1)})
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('oversized read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(len(report['uncovered_blocking']), 1)

    def test_reviewed_archive_rules_require_exact_paths_sha_and_reason(self):
        raw = json.loads(RULES.read_text())
        valid = {'id': 'synthetic_archive', 'path': 'Vendor/dependency.zip',
                 'sha256': 'a' * 64, 'reason': 'Original synthetic fixture'}
        for changes in ({'path': 'Vendor/*.zip'}, {'path': '../dependency.zip'},
                        {'path': '/dependency.zip'}, {'path': 42}, {'sha256': 'bad'}, {'reason': ''}):
            with self.subTest(changes=changes):
                raw['reviewed_archives'] = [{**valid, **changes}]
                table = Path(self.tmp.name) / 'rules.json'
                table.write_text(json.dumps(raw))
                with patch.object(self.mod, 'RULES_PATH', table), self.assertRaises(self.mod.ScanError):
                    self.mod.load_rules()

    def test_full_scan_reasoned_existing_allowlist_keeps_boundary_visible(self):
        self.commit({'unknown.xyz': b'original unknown-type fixture'})
        rules = self.mod.load_rules()
        rules['allowlist'].append({'id': 'original_unread_fixture',
                                  'categories': ['uncovered_unreviewed_type'],
                                  'paths': ['unknown.xyz'], 'reason': 'original synthetic fixture only'})
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('unknown read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(report['coverage'], {'unreviewed_type': 1})
        self.assertEqual(len(report['uncovered']), 1)
        self.assertEqual(report['uncovered_blocking'], [])
        self.assertEqual(report['uncovered_allowed'], report['uncovered'])
        # The same rule must not cover a different unknown path.
        self.commit({'other.xyz': b'other original unknown fixture'})
        with patch.object(self.mod, 'load_rules', return_value=rules):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual([f['path'] for f in report['uncovered_blocking']], ['other.xyz'])

    def test_full_scan_credential_payload_and_git_link_cannot_be_allowed(self):
        # Stage a link blob directly: no OS link permissions or target reads.
        self.commit({'prod.keys': b'original sentinel', 'assets/data.bin': b'original sentinel'})
        oid = self.git('hash-object', '-w', '--stdin')  # empty, synthetic link target blob
        self.git('update-index', '--add', '--cacheinfo', '120000,' + oid + ',link')
        self.git('commit', '-qm', 'synthetic git link metadata')
        rules = self.mod.load_rules()
        for reason in ('excluded_credentials', 'excluded_payload', 'non_regular'):
            rules['allowlist'].append({'id': 'attempt_' + reason,
                                      'categories': ['uncovered_' + reason],
                                      'paths': ['*'], 'reason': 'must never override protected boundary'})
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('protected read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(len(report['uncovered_blocking']), 3)
        self.assertEqual(report['uncovered_allowed'], [])
        self.assertEqual({f['reason'] for f in report['uncovered_blocking']},
                         {'excluded_credentials', 'excluded_payload', 'non_regular'})

    def test_extensionless_text_is_scanned_without_values(self):
        mail = 'synthetic' + '@private.test'
        names = ['THIRD_PARTY_NOTICES', 'custom/runner', 'custom/EMPTY']
        self.commit({names[0]: mail + '\n', names[1]: '#!/bin/sh\n' + mail + '\n',
                     names[2]: ''})
        proc, report = self.scan()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(report['coverage'], {'text': 3})
        self.assertEqual([(f['path'], f['line'], f['category']) for f in report['findings']],
                         [(names[0], 1, 'email'), (names[1], 2, 'email')])
        self.assertNotIn(mail, proc.stdout + proc.stderr)

    def test_extensionless_binary_and_invalid_encoding_remain_unreviewed(self):
        mail = ('synthetic' + '@private.test').encode()
        self.commit({'binary': b'\0' + mail, 'invalid': b'\xff' + mail})
        proc, report = self.scan()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(report['findings'], [])
        self.assertEqual(report['coverage'], {'unreviewed_type': 2})
        self.assertEqual(len(report['uncovered_blocking']), 2)

    def test_extensionless_utf8_probe_boundary_and_late_binary(self):
        mail = 'synthetic' + '@private.test'
        # The three-byte character straddles the 8192-byte sample boundary.
        self.commit({'utf8': 'x' * 8191 + '中\n' + mail + '\n',
                     'late_binary': b'x' * 8192 + b'\0' + mail.encode()})
        proc, report = self.scan()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual([(f['path'], f['line']) for f in report['findings']], [('utf8', 2)])
        self.assertEqual(report['coverage'], {'text': 1, 'unreviewed_binary_or_encoding': 1})

    def test_extensionless_list_only_never_reads(self):
        self.commit({'NOTICE_CUSTOM': 'synthetic' + '@private.test\n'})
        with patch.object(self.mod.Blobs, 'read', side_effect=AssertionError('list-only read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'], list_only=True)
        self.assertEqual(report['findings'], [])
        self.assertEqual(report['manifest'][0]['decision'], 'unreviewed_type')

    def test_extensionless_exclusions_and_oversize_precede_probe(self):
        rules = self.mod.load_rules()
        def forbidden():
            raise AssertionError('excluded blob read')
        for name, mode, kind, size, expected in [
                ('.aws/config', '100644', 'blob', 1, 'excluded_credentials'),
                ('assets/custom', '100644', 'blob', 1, 'excluded_payload'),
                ('link', '120000', 'blob', 1, 'non_regular'),
                ('submodule', '160000', 'commit', 1, 'non_regular'),
                ('HUGE', '100644', 'blob', self.mod.MAX_BYTES + 1, 'oversized')]:
            with self.subTest(name=name):
                self.assertEqual(self.mod.classify(name, mode, kind, size, rules,
                                                   read_blob=forbidden)[0], expected)

    def test_extensionless_incremental_and_rename_preserve_old_findings(self):
        old = 'oldsynthetic' + '@private.test\n'
        new = 'newsynthetic' + '@private.test\n'
        base = self.commit({'NOTICE_CUSTOM': old + 'clean\n'})
        self.commit({'NOTICE_CUSTOM': old + 'different clean\n'})
        proc, report = self.scan('--base', base)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(report['blocking_count'], 0)
        self.assertEqual(len(report['findings']), 1)
        self.assertEqual(report['findings'][0]['status'], 'existing')
        # Existing scanner deliberately detects only exact renames (no payload similarity reads).
        base = self.git('rev-parse', 'HEAD')
        self.git('mv', 'NOTICE_CUSTOM', 'RENAMED_NOTICE')
        self.git('commit', '-qm', 'synthetic rename')
        proc, report = self.scan('--base', base)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(report['blocking_count'], 0)
        base = self.git('rev-parse', 'HEAD')
        self.commit({'RENAMED_NOTICE': old + 'different clean\n' + new})
        proc, report = self.scan('--base', base)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(report['blocking_count'], 1)
        self.assertEqual([(f['line'], f['status']) for f in report['findings']],
                         [(1, 'existing'), (3, 'changed')])

    def test_extensionless_read_failure_is_not_clean(self):
        self.commit({'NOTICE_CUSTOM': 'safe\n'})
        with patch.object(self.mod.Blobs, 'read', side_effect=self.mod.ScanError('git_blob_read_failed')):
            with self.assertRaisesRegex(self.mod.ScanError, 'git_blob_read_failed'):
                self.mod.scan(self.root, 'HEAD', ['.'])

    def test_gate_summary_counts_unreviewed_types_without_blocking(self):
        base = self.commit({'safe.md': 'safe\n'})
        self.commit({'binary': b'\0synthetic', 'unknown.xyz': b'synthetic'})
        proc = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.root),
                               '--path', '.', '--base', base, '--format', 'gate'],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)
        self.assertIn('增量未审类型 2', proc.stdout)
        self.assertIn('"binary":uncovered: unreviewed_type', proc.stdout)
        self.assertIn('"unknown.xyz":uncovered: unreviewed_type', proc.stdout)

    def test_all_categories_no_values(self):
        values = ['fixtureperson', '11223344-5566778899AABBCC', 'F1X2T3U4R5', 'human@private.test']
        self.commit({'src/a.md': '/Users/' + values[0] + '/project\n' + values[1] +
                     '\nteamID: "' + values[2] + '"\n' + values[3] + '\n',
                     'corpus/a.mme': b'synthetic, not a game macro',
                     '中文目录/截图.png': b'synthetic, not an image'})
        p, r = self.scan()
        self.assertEqual(p.returncode, 1)
        self.assertEqual({f['category'] for f in r['findings']},
                         {'home_path', 'device_id', 'team_id', 'email', 'game_macro', 'game_screenshot'})
        for value in values:
            self.assertNotIn(value, p.stdout + p.stderr)

    def test_internal_names_block_and_device_models_do_not(self):
        for line in ['作者 jhz 定', 'jhz: fix', '总指挥 定的分发', '天眼（Windows 出包机）车道',
                     '测试机2 归质量线', 'GATE_HOST=mini', '--host mini', '派 mini 上跑', 'mac-mini',
                     'mac_mini.tsv', 'mini_sync.sh', 'mini_main.sh', '（mini / Air）', 'GATE_HOST=Air',
                     'Air 8 核只开 1 个槽', 'mac-air', 'mac_air']:
            with self.subTest(line=line):
                self.assertIn('internal_name', self.mod.categories(line))
        for line in ['iPad mini 6、Mac mini M4', 'MacBook Air M3、iPad Air', 'Kirby Air Riders',
                     'jhaizhou-ops', 'MINI_LINE / MINIMAL_LAYOUT']:
            with self.subTest(line=line):
                self.assertNotIn('internal_name', self.mod.categories(line))
        for line in ['minimal / Minimum / minidump / miniaturize', 'AirPlay / AirDrop / gpt-4o-mini',
                     'out.air / air-tt / air-config / AIR-TT / GAL_AIR_CACHE',
                     'air = os.path.join(work, "out.air")']:
            with self.subTest(line=line):
                self.assertNotIn('internal_name', self.mod.categories(line))

    def test_internal_name_full_and_incremental_block(self):
        base = self.commit({'docs/a.md': 'safe\n'})
        self.commit({'docs/b.md': '派 gate-host 上跑；作者 jhz\n'})
        proc, report = self.scan()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual({f['category'] for f in report['findings']}, {'internal_name'})
        self.assertEqual([f['path'] for f in report['findings']], ['docs/b.md'])
        self.assertEqual(report['blocking_count'], 1)
        proc, report = self.scan('--base', base)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(report['blocking_count'], 1)
        self.commit({'docs/b.md': 'iPad mini 6、MacBook Air、out.air、air-tt\n'})
        proc, report = self.scan()
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(report['findings'], [])

    def test_team_forms(self):
        for line in ['"F1X2T3U4R5"', 'teamID": "F1X2T3U4R5"',
                     's2arm.f1x2t3u4r5.012345', 'TEAM_ID=F1X2T3U4R5',
                     'S2A_TEAM_DEFAULT="F1X2T3U4R5"', 'DevelopmentTeam=F1X2T3U4R5']:
            with self.subTest(line=line):
                self.assertIn('team_id', self.mod.categories(line))
        for line in ['"1234567890"', 'teamID=SHORT', 'teamID=F1X2T3U4R56', '${TEAM}',
                     'DEVELOPMENT_TEAM = $(TEAM_ID)', '"SOME_WORDS"']:
            self.assertNotIn('team_id', self.mod.categories(line))

    def test_users_volumes_windows_chinese_and_placeholders(self):
        for line in ['/Users/fixtureperson/project', '/home/fixtureperson/project',
                     '/Volumes/fixtureperson/project', '/Users/合成用户/project',
                     r'C:\Users\fixtureperson\project']:
            self.assertIn('home_path', self.mod.categories(line))
        for line in ['/Users/<你>/project', '/Users/player/project', '/home/s2arm/project',
                     '/Users/USERNAME/project', r'(?:/Users/|/home/|/Volumes/)',
                     '/Users/${NAME}/project']:
            self.assertNotIn('home_path', self.mod.categories(line))

    def test_udid_zero_prefix_and_context(self):
        self.assertNotIn('device_id', self.mod.categories('00000000-1234567890ABCDEF'))
        self.assertNotIn('device_id', self.mod.categories('sha ' + 'b' * 40))
        self.assertIn('device_id', self.mod.categories('UDID ' + 'b' * 40))
        self.assertIn('device_id', self.mod.categories('CoreDevice 12345678-1234-5678-1234-123456789abc'))

    def test_usb_serial_and_quoted_prefix_positive_shapes(self):
        serial = '112233445566778899AABBCC'
        prefix = '11223344-5566'
        for line in ['"USBDeviceKeySerialNumber": "' + serial + '"',
                     'SerialNumber=' + serial.lower(), 'UDID ' + serial]:
            with self.subTest(shape='contextual serial'):
                self.assertIn('device_id', self.mod.categories(line))
        for line in ['"' + prefix + '"', "'" + prefix.lower() + "'"]:
            with self.subTest(shape='quoted prefix'):
                self.assertIn('device_id', self.mod.categories(line))
        self.commit({'docs/serial.tsv': 'USBDeviceKeySerialNumber\t' + serial + '\n',
                     'src/prefix.py': 'PREFIX = "' + prefix + '"\n',
                     'runtime/tests/t_fps_default': b'\0SerialNumber=' + serial.encode() + b'\0'})
        proc, report = self.scan()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual({f['path'] for f in report['findings']},
                         {'docs/serial.tsv', 'src/prefix.py', 'runtime/tests/t_fps_default'})
        self.assertTrue(all(f['category'] == 'device_id' for f in report['findings']))
        for value in [serial, prefix]:
            self.assertNotIn(value, proc.stdout + proc.stderr)

    def test_usb_serial_zero_chip_placeholders_and_nondevices(self):
        for index in (1, 2):
            suffix = format(index, '016X')
            for value in ['00000000-' + suffix, '00000000' + suffix,
                          '00000000-' + suffix[:4]]:
                with self.subTest(shape='zero chip placeholder', index=index):
                    self.assertNotIn('device_id', self.mod.categories('SerialNumber="' + value + '"'))
        for line in ['sha 112233445566778899AABBCC',
                     'SerialNumber=0112233445566778899AABBCC0',
                     '"11223344-55667"', '"011223344-5566"',
                     '"11223344-5566-7788-99AA-BBCCDDEEFF00"']:
            with self.subTest(shape='not a complete supported device shape'):
                self.assertNotIn('device_id', self.mod.categories(line))

    def test_license_mail_preserved_and_scope_narrow(self):
        text = 'Copyright Author <author@project.test>\n'
        names = ['graphics/metal/shaders/AA-LICENSE.txt',
                 'compat/tree/src/Shaders/SmaaFx.glsl', 'runtime/rewriter/LICENSES/capstone.txt']
        self.commit({**{n: text for n in names}, 'src/a.py': text})
        p, r = self.scan()
        self.assertEqual([(f['path'], f['category']) for f in r['findings']], [('src/a.py', 'email')])
        for n in names:
            self.assertEqual((self.root / n).read_text(), text)
        self.assertEqual(p.returncode, 1)
        self.assertIn('home_path', self.mod.categories('/Users/fixtureperson/a', names[0]))

    def test_email_filename_and_example_exceptions(self):
        for line, path in [('icon@2x.png', 'tests/test_app_bundle.py'),
                           ('asset@synthetic.tmp', 'tests/gc_test.sh'),
                           ('user@example.com', 'src/a.md'),
                           ('user@example.invalid', 'src/a.md')]:
            self.assertNotIn('email', self.mod.categories(line, path))
        self.assertIn('email', self.mod.categories('person@private.test', 'tests/gc_test.sh'))

    def test_regexp_allowlist_not_entire_redactor(self):
        self.assertNotIn('home_path', self.mod.categories('re.compile(r"/Users/fixtureperson/")', 'tools/redact.py'))
        self.assertIn('home_path', self.mod.categories('literal = "/Users/fixtureperson/"', 'tools/redact.py'))

    def test_text_scope_includes_tables_imports_widen_sources(self):
        names = ['docs/名单_满屏比例.tsv', 'graphics/widen/tables/synthetic/来源.txt',
                 'import/lib/source.cs', 'data/config.py', 'third_party/lib/source.c',
                 'compat/tree/src/Foo.cs', 'custom/measurements.tsv', 'graphics/widen/tables/synthetic/patch.tsv']
        self.commit({n: '/home/fixtureperson/project\n' for n in names})
        _, r = self.scan()
        self.assertEqual({f['path'] for f in r['findings']}, set(names))
        self.assertEqual(r['coverage']['text'], len(names))

    def test_sensitive_payload_metadata_never_reaches_read(self):
        excluded = ['prod.keys', '.env.local', '.aws/config', 'secrets/hidden.json',
                    'auth.json', 'credentials.json', 'private.pem', 'game.nsp',
                    'original.orig', 'graphics/widen/tables/synthetic/patch.dat', 'assets/raw.json']
        meta = ['corpus/one.mme', 'graphics/tools/macrogen/corpus/new/data.dat',
                'compat/tree/src/S2AMacroTable.g.cs', 'docs/中文/图.png']
        self.commit({n: 'synthetic sentinel: must not read\n' for n in excluded + meta})
        with patch.object(self.mod.Blobs, 'read', side_effect=AssertionError('forbidden read')):
            r = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(len(r['uncovered']), len(excluded))
        self.assertEqual(len(r['findings']), len(meta))

    def test_metadata_allowlist_never_turns_into_content_read(self):
        self.commit({'docs/original.png': 'synthetic, not a picture'})
        rules = self.mod.load_rules()
        rules['allowlist'].append({'id': 'authored_image', 'categories': ['game_screenshot'],
                                  'paths': ['docs/original.png'], 'reason': 'synthetic unit fixture'})
        with patch.object(self.mod, 'load_rules', return_value=rules), patch.object(
                self.mod.Blobs, 'read', side_effect=AssertionError('image read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(report['findings'], [])
        self.assertEqual(report['uncovered'], [])
        self.assertEqual(report['coverage'], {'metadata_only': 1})

    def test_macro_table_at_root_and_game_code_never_read(self):
        self.commit({'S2AMacroTable.g.cs': 'synthetic sentinel',
                     'games/private/code.cs': 'synthetic sentinel'})
        with patch.object(self.mod.Blobs, 'read', side_effect=AssertionError('payload read')):
            report = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(report['findings'][0]['category'], 'game_macro')
        self.assertEqual(report['uncovered'][0]['reason'], 'excluded_payload')

    def test_list_only_never_reads_blobs(self):
        self.commit({'a.py': '/Users/fixtureperson/path\n'})
        with patch.object(self.mod.Blobs, 'read', side_effect=AssertionError('metadata only')):
            r = self.mod.scan(self.root, 'HEAD', ['.'], list_only=True)
        self.assertEqual(r['findings'], [])
        self.assertEqual(r['manifest'][0]['decision'], 'text')

    def test_approved_binary_ascii_offsets_not_other_binary(self):
        data = b'\0\x01hello\0/Users/fixtureperson/source.cc\0teamID=F1X2T3U4R5\0'
        names = ['translator/dmsh_xlate_bin/demo.dll',
                 'translator/dmsh_xlate_bin/demo.pdb', 'runtime/tests/t_fps_default']
        self.commit({**{n: data for n in names}, 'other.bin': data, 'binary.md': data})
        p, r = self.scan()
        self.assertEqual({f['path'] for f in r['findings']}, set(names))
        for n in names:
            self.assertEqual({f['category'] for f in r['findings'] if f['path'] == n}, {'home_path', 'team_id'})
            self.assertEqual(next(f['offset'] for f in r['findings'] if f['path'] == n and f['category'] == 'home_path'), data.index(b'fixtureperson'))
        self.assertNotIn('fixtureperson', p.stdout + p.stderr)
        self.assertEqual(r['coverage']['unreviewed_binary_or_encoding'], 1)

    def test_git_paths_nul_preserved_and_output_json_escaped(self):
        names = ['文档/截图.PNG', 'docs/a b.md', 'docs/a\nb.md', 'docs/a\tb.md',
                 'docs/a"b.md', 'docs/a\\b.md', '-leading.md']
        self.commit({n: '/Users/fixtureperson/project\n' for n in names})
        p, r = self.scan()
        self.assertEqual({f['path'] for f in r['findings']}, set(names))
        self.assertIn(r'a\nb.md', p.stdout)
        self.assertNotIn('fixtureperson', p.stdout)
        _, selected = self.scan('--path', 'docs/a\\b.md')
        # . remains explicit selection; \n \t " \\ names are also windows_path metadata findings
        self.assertEqual(sum(f['category'] != 'windows_path' for f in selected['findings']), len(names))
        self.assertEqual(selected['blocking_count'], len(names) + 4)

    def test_sensitive_filename_masked_in_every_report_section(self):
        uid = '11223344-5566778899AABBCC'
        self.commit({'docs/' + uid + '.png': 'synthetic', 'private@private.test.json': '{}'})
        for args in [[], ['--list-only']]:
            p, _ = self.scan(*args)
            self.assertNotIn(uid, p.stdout + p.stderr)
            self.assertNotIn('private@private.test', p.stdout + p.stderr)

    def test_short_prefix_filename_redacted_in_metadata_and_reports(self):
        prefix = 'ABCDEF12-3456'
        name = 'docs/' + prefix + '.png'
        base = self.commit({'safe.md': 'safe\n'})
        self.commit({name: 'synthetic, not a picture'})
        report_path = Path(self.tmp.name) / 'report.json'
        for args in [[], ['--list-only'], ['--path', name],
                     ['--base', base, '--report', str(report_path)]]:
            result, report = self.scan(*args)
            self.assertNotIn(prefix, result.stdout + result.stderr)
            self.assertIn('<device_id>', result.stdout)
        self.assertNotIn(prefix, report_path.read_text())
        result = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.root),
                                 '--path', name, '--base', base, '--format', 'gate'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(prefix, result.stdout + result.stderr)
        self.assertNotIn('device_id', self.mod.categories(prefix))  # filename mask only

    def test_windows_illegal_path_blocks_new_files_only(self):
        # 11-05 天眼：误提交的 'R:\\s2a\\work\\lane/me.need' 让 Windows 端整仓检出报 invalid path。
        # 期望（按 Windows 命名规则手写）：每段含 < > : " | ? * \\ 或控制字符、是设备保留名（不论扩展名）、以空格或点结尾即非法
        bad = ['R:\\s2a\\work\\lane/me.need', 'docs/a?b.md', 'docs/a*b.md', 'docs/a<b.md', 'docs/a>b.md',
               'docs/a|b.md', 'docs/a"b.md', 'docs/a:b.md', 'docs/a\x01b.md', 'aux/x.md', 'docs/CON',
               'docs/nul.txt', 'docs/Com1.md', 'docs/lpt9.md', 'docs/dot.', 'docs/sp ', 'trail. /x.md']
        good = ['docs/坑记录.md', 'docs/console.md', 'docs/com0.md', 'docs/conx.md', 'docs/.hidden.md',
                'docs/a b.md', 'docs/a.b.c.md']
        base = self.commit({'docs/base.md': 'clean\n'})
        self.commit({n: 'clean\n' for n in bad + good})
        p, r = self.scan('--base', base)
        hit = {f['path'] for f in r['findings'] if f['category'] == 'windows_path'}
        self.assertEqual(hit, set(bad))
        self.assertTrue(all(f['status'] == 'changed' and f['location'] == 'git_metadata'
                            for f in r['findings'] if f['category'] == 'windows_path'))
        self.assertEqual(p.returncode, 1, '新增 Windows 非法路径必须红')
        gate = subprocess.run([sys.executable, str(TOOL), '--repo', str(self.root), '--path', '.',
                               '--base', base, '--format', 'gate'], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 1)
        self.assertEqual(gate.stdout.count('windows_path'), len(bad))
        # 负对照：只留合法名 → 绿
        self.git('rm', '-q', *bad)
        self.git('commit', '-qm', 'drop illegal')
        clean, r = self.scan('--base', base)
        self.assertEqual(clean.returncode, 0)
        self.assertEqual([f for f in r['findings'] if f['category'] == 'windows_path'], [])

    def test_inventory_and_gate_only_added_lines(self):
        base = self.commit({'docs/old.md': '/Users/fixtureperson/old\n', 'docs/clean.md': 'clean\n'})
        self.commit({'docs/clean.md': 'still clean\n'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(len(r['findings']), 1)
        self.assertEqual(r['findings'][0]['status'], 'existing')
        self.commit({'docs/old.md': '/Users/fixtureperson/old\nunrelated edit\n'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(r['blocking_count'], 0)
        self.commit({'docs/old.md': '/Users/fixtureperson/old\n/Users/newfixture/new\n'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r['blocking_count'], 1)

    def test_renamed_unchanged_text_is_existing(self):
        base = self.commit({'old.md': '/Users/fixtureperson/project\n'})
        self.git('mv', 'old.md', '新 名.md')
        self.git('commit', '-qm', 'rename')
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(r['findings'][0]['status'], 'existing')

    def test_deleted_file_not_read_or_blocking(self):
        base = self.commit({'old.md': '/Users/fixtureperson/project\n', 'clean.md': 'clean\n'})
        self.git('rm', 'old.md')
        self.git('commit', '-qm', 'delete')
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(r['findings'], [])

    def test_special_path_incremental_uses_git_not_gate_changed(self):
        base = self.commit({'safe.md': 'safe\n'})
        self.commit({'docs/a\n b.md': '/Users/fixtureperson/project\n'})
        with patch.dict(os.environ, {'GATE_CHANGED': 'totally-unrelated.md'}):
            p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 1)
        # 换行符也是 Windows 非法路径：内容一条 home_path + 路径一条 windows_path
        self.assertEqual(sorted(f['category'] for f in r['findings']), ['home_path', 'windows_path'])

    def test_unread_changed_file_is_incomplete_not_clean(self):
        base = self.commit({'safe.md': 'safe\n'})
        self.commit({'prod.keys': 'synthetic sentinel'})
        with patch.object(self.mod.Blobs, 'read', wraps=self.mod.Blobs.read):
            p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(r['incomplete_changed'][0]['reason'], 'excluded_credentials')

    def test_source_patches_series_and_fixture_text_are_read(self):
        base = self.commit({'safe.md': 'safe\n'})
        names = ['compat/patches/a.patch', 'src/a.diff', 'compat/patches/series',
                 'tests/fixtures/a.txt', 'tests/fixtures/a.json']
        self.commit({name: '/home/fixtureperson/project\n' for name in names})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r['blocking_count'], len(names))
        self.assertEqual(r['uncovered'], [])

    def test_unread_payload_and_unknown_are_warning_only(self):
        base = self.commit({'safe.md': 'safe\n'})
        self.commit({'game.nsp': b'synthetic', 'unknown.xyz': b'synthetic',
                     'binary.txt': b'\0synthetic'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(r['incomplete_changed'], [])
        self.assertEqual(len(r['warnings_changed']), 3)

    def test_metadata_new_and_renamed_only(self):
        base = self.commit({'old.png': b'synthetic', 'old.mme': b'synthetic'})
        self.commit({'old.png': b'changed synthetic'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.git('mv', 'old.mme', 'new.mme')
        self.git('commit', '-qm', 'rename metadata')
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r['blocking_count'], 1)
        self.commit({'new.png': b'synthetic'})
        p, r = self.scan('--base', base)
        self.assertEqual(r['blocking_count'], 2)

    def test_team_bundle_and_home_boundary_negative(self):
        for line in ['s2arm.controller.demo', 'S2Arm.InputGuide.demo',
                     '$T/home/fixtureperson/a', '${ROOT}/home/fixtureperson/a',
                     '$(pwd)/home/fixtureperson/a', 'prefix/home/fixtureperson/a']:
            self.assertEqual(self.mod.categories(line), [], line)
        self.assertIn('home_path', self.mod.categories('"/home/fixtureperson/a"'))
        self.assertIn('team_id', self.mod.categories('s2arm.f1x2t3u4r5.demo'))

    def test_binary_old_lines_and_git_lf_line_numbers(self):
        name = 'runtime/tests/t_fps_default'
        base = self.commit({name: b'/home/fixtureperson/old\nclean\n',
                            'a.txt': 'one\v/home/fixtureperson/old\nclean\n'})
        self.commit({name: b'/home/fixtureperson/old\nnew clean\n',
                     'a.txt': 'one\v/home/fixtureperson/old\nnew clean\n'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(r['blocking_count'], 0)
        self.commit({name: b'/home/fixtureperson/old\n/home/otherfixture/new\n'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r['blocking_count'], 1)

    def test_fixture_credentials_and_protected_payload_stay_unread(self):
        names = ['tests/fixtures/auth.json', 'tests/fixtures/games/a.txt',
                 'tests/fixtures/raw.bin', 'tests/fixtures/secrets/a.txt']
        self.commit({name: b'synthetic sentinel' for name in names})
        with patch.object(self.mod.Blobs, 'read', side_effect=AssertionError('protected read')):
            r = self.mod.scan(self.root, 'HEAD', ['.'])
        self.assertEqual(len(r['uncovered']), len(names))

    def test_zero_step_gate_avoids_bsd_seq(self):
        self.commit({'tools/gate.sh': (ROOT / 'tools/gate.sh').read_text(),
                     'tools/gate_plan.sh': (ROOT / 'tools/gate_plan.sh').read_text(),
                     'docs/a.md': 'safe\n'})
        bindir = Path(self.tmp.name) / 'bin'
        bindir.mkdir()
        seq = bindir / 'seq'
        seq.write_text('#!/bin/sh\nprintf "1\\n0\\n"\n')
        seq.chmod(0o755)
        with patch.dict(os.environ, {'PATH': str(bindir) + os.pathsep + os.environ['PATH']}):
            result = self.gate('HEAD')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('跑了 0 步 / 应跑 0 步', result.stdout)
        self.assertNotIn('unbound variable', result.stderr)

    def test_doc_scanner_mini_assignment_stays_local(self):
        base = self.install_gate_fixture()
        self.commit({'docs/change.md': 'safe\n',
                     'tools/remote.sh': 'echo REMOTE_MUST_NOT_RUN >&2; exit 99\n'})
        env = {k: v for k, v in os.environ.items() if not k.startswith('GATE_')}
        env.update({'GATE_HOST': 'gate-host', 'GATE_TIER': 'doc', 'GATE_SCAN_BASE': base,
                    'GATE_CHANGED': 'docs/change.md', 'GATE_NO_LOADQ': '1'})
        listed = subprocess.run(['bash', 'tools/gate.sh'], cwd=self.root,
                                env={**env, 'GATE_LIST': '1'}, capture_output=True, text=True, timeout=20)
        self.assertEqual(listed.returncode, 0)
        self.assertEqual(listed.stdout.strip(), '公开仓扫描')
        self.assertIn('路由：公开仓扫描［本机］', listed.stderr)
        result = subprocess.run(['bash', 'tools/gate.sh'], cwd=self.root,
                                env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('REMOTE_MUST_NOT_RUN', result.stdout + result.stderr)
        self.assertIn('跑了 1 步 / 应跑 1 步', result.stdout)

    def test_git_interhunk_configuration_cannot_reclassify_old_lines(self):
        base = self.commit({'a.txt': 'first\n/home/fixtureperson/old\nlast\n'})
        self.git('config', 'diff.interHunkContext', '20')
        self.commit({'a.txt': 'new first\n/home/fixtureperson/old\nnew last\n'})
        p, r = self.scan('--base', base)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(r['blocking_count'], 0)

    def test_changed_credential_symlink_is_incomplete_without_read(self):
        base = self.commit({'safe.md': 'safe\n'})
        (self.root / 'private.keys').symlink_to('/never/read')
        self.git('add', 'private.keys')
        self.git('commit', '-qm', 'synthetic credential symlink')
        with patch.object(self.mod.Blobs, 'read', return_value=b'safe\n'):
            r = self.mod.scan(self.root, 'HEAD', ['.'], base=base)
        self.assertEqual(len(r['incomplete_changed']), 1)
        self.assertEqual(r['incomplete_changed'][0]['reason'], 'excluded_credentials')

    def test_missing_ref_baseline_path_and_wrong_root_fail_closed(self):
        self.commit({'sub/a.md': 'safe\n'})
        for args in [['--ref', 'not-a-ref'], ['--base', 'not-a-base']]:
            p, r = self.scan(*args)
            self.assertEqual(p.returncode, 2)
            self.assertEqual(r['error'], 'cannot_resolve_revision')
        for paths in [[], ['../outside'], ['/etc'], ['missing.md'], ['sub', 'missing']]:
            with self.assertRaises(self.mod.ScanError):
                self.mod.scan(self.root, 'HEAD', paths)
        with self.assertRaisesRegex(self.mod.ScanError, 'repo_must_be_root'):
            self.mod.scan(self.root / 'sub', 'HEAD', ['.'])

    def test_dirty_fifo_symlink_and_untracked_not_read(self):
        self.commit({'clean.md': 'safe\n'})
        (self.root / 'clean.md').unlink()
        os.mkfifo(self.root / 'clean.md')
        (self.root / 'untracked.md').write_text('/Users/fixtureperson/project\n')
        (self.root / 'link.md').symlink_to('/not/read/by/scan')
        self.git('add', 'link.md')
        self.git('commit', '-qm', 'synthetic symlink')
        p, r = self.scan()
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r['findings'], [])
        self.assertEqual(r['coverage']['non_regular'], 1)
        self.assertEqual(r['uncovered_blocking'],
                         [{'path': 'link.md', 'status': 'existing', 'reason': 'non_regular'}])

    def test_read_error_and_oversize_are_not_clean(self):
        self.commit({'a.md': 'safe\n'})
        with patch.object(self.mod.Blobs, 'read', side_effect=self.mod.ScanError('git_blob_read_failed')):
            with self.assertRaisesRegex(self.mod.ScanError, 'git_blob_read_failed'):
                self.mod.scan(self.root, 'HEAD', ['.'])
        rules = self.mod.load_rules()
        self.assertEqual(self.mod.classify('a.md', '100644', 'blob', self.mod.MAX_BYTES + 1, rules)[0], 'oversized')

    def test_invalid_rules_are_not_silent(self):
        bad = Path(self.tmp.name) / 'bad.json'
        bad.write_text('{"version": 2}')
        with patch.object(self.mod, 'RULES_PATH', bad):
            with self.assertRaisesRegex(self.mod.ScanError, 'invalid_rules_table'):
                self.mod.load_rules()

    def test_report_deterministic(self):
        self.commit({'z.md': '/home/fixtureperson/project\n', '文档/a.md': '/Volumes/fixtureperson/project\n'})
        a, _ = self.scan()
        b, _ = self.scan()
        self.assertEqual(a.stdout, b.stdout)

    @unittest.skipUnless((ROOT / 'pack/our_devices.tsv').is_file(), '我方真机表是维护方私有表，不在公开仓')
    def test_device_table_architecture_contract(self):
        table = (ROOT / 'pack/our_devices.tsv').read_text()
        rows = [line.split('\t') for line in table.splitlines() if line and not line.startswith('#')]
        self.assertEqual([(r[0], r[2], r[3]) for r in rows], [('iPhone18,2', 'applegpu_g18p', 'ios'), ('iPhone19,4', 'applegpu_g19p', 'ios'),
                                                         ('Mac17,6', 'applegpu_g17s', 'macos'), ('mac-gate-host', 'applegpu_g16s', 'macos'), ('mac-spare-host', 'applegpu_g15g', 'macos')])
        self.assertFalse(any('device_id' in self.mod.categories(line) for line in table.splitlines()))

    def install_gate_fixture(self):
        for name in ['tools/gate.sh', 'tools/gate_plan.sh', 'tools/contrib_check.sh',
                     'tools/public_repo_scan.py', 'tools/public_repo_scan_rules.json', 'tools/gate_decl.py']:
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, p)
        # These are authored stubs, not Apple binaries or tools.
        return self.commit({'tools/toolchain.env': '# synthetic fixture\n',
                            'tools/toolchain.sh': 'echo APPLE_TOOLCHAIN_MUST_NOT_RUN >&2; return 77\n',
                            'tools/doctor.sh': '#!/bin/bash\nprintf "缺：Xcode\\n"\n',
                            'tools/contrib_layer2.tsv': '', 'tools/contrib_tools.tsv': '',
                            '.gitignore': 'build/\n', 'docs/old.md': '/home/fixtureperson/source\n'})

    def gate(self, base, list_only=False, contrib=False):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('GATE_', 'CONTRIB_', 'S2A_TRAIN_'))}
        env.update({'GATE_SCAN_BASE': base, 'GATE_TIER': 'doc', 'GATE_CHANGED': 'docs/change.md',
                    'GATE_NO_LOADQ': '1', 'PYTHONDONTWRITEBYTECODE': '1', 'HOME': self.tmp.name,
                    'S2A_TRAIN_DIR': str(Path(self.tmp.name) / 'not-a-train')})
        if list_only:
            env['CONTRIB_LIST_ONLY' if contrib else 'GATE_LIST'] = '1'
        cmd = ['bash', 'tools/contrib_check.sh', '--base', base] if contrib else ['bash', 'tools/gate.sh']
        return subprocess.run(cmd, cwd=self.root, env=env, capture_output=True, text=True)

    def test_doc_gate_lists_one_real_step_before_apple_toolchain(self):
        base = self.install_gate_fixture()
        self.commit({'docs/change.md': 'safe\n'})
        result = self.gate(base, list_only=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '公开仓扫描')
        self.assertIn('路由：公开仓扫描［本机］', result.stderr)
        self.assertNotIn('APPLE_TOOLCHAIN', result.stdout + result.stderr)
        contrib = self.gate(base, list_only=True, contrib=True)
        self.assertEqual(contrib.returncode, 0, contrib.stdout + contrib.stderr)
        self.assertEqual(contrib.stdout.strip(), result.stdout.strip())

    def test_doc_gate_stock_nonblocking_new_sensitive_red(self):
        base = self.install_gate_fixture()
        self.commit({'docs/change.md': 'safe\n'})
        clean = self.gate(base)
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        self.assertIn('跑了 1 步 / 应跑 1 步', clean.stdout)
        self.commit({'docs/change.md': '/Volumes/fixtureperson/new\n'})
        red = self.gate(base)
        self.assertEqual(red.returncode, 1, red.stdout + red.stderr)
        self.assertIn('home_path', red.stdout)
        self.assertNotIn('fixtureperson', red.stdout + red.stderr)
        report = json.loads((self.root / 'build/public_repo_scan.json').read_text())
        self.assertGreater(report['blocking_count'], 0)
        self.assertTrue(any(f['status'] == 'existing' for f in report['findings']))

    def test_contrib_doc_executes_scan_and_red_takes_priority(self):
        base = self.install_gate_fixture()
        self.commit({'docs/change.md': '/home/fixtureperson/source\n'})
        result = self.gate(base, contrib=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('应跑 1 步', result.stdout)
        self.assertIn('**红**', result.stdout)

    def test_deleted_scanner_cannot_bypass_gate(self):
        base = self.install_gate_fixture()
        self.git('update-ref', 'refs/remotes/origin/main', base)
        self.git('rm', 'tools/public_repo_scan.py')
        self.git('commit', '-qm', 'delete scanner')
        result = self.gate(base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('公开仓扫描', result.stdout)

    def test_scan_ref_survives_gate_control_environment_cleanup(self):
        base = self.install_gate_fixture()
        bad = self.commit({'docs/change.md': '/home/fixtureperson/source\n'})
        self.commit({'docs/change.md': 'safe\n'})
        env = os.environ.copy()
        env.update(GATE_TIER='doc', GATE_CHANGED='docs/change.md', GATE_SCAN_BASE=base,
                   GATE_REV=bad, GATE_NO_LOADQ='1')
        result = subprocess.run(['bash', 'tools/gate.sh'], cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
