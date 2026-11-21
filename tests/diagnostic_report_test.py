#!/usr/bin/env python3
"""Synthetic offline tests; never requires games, devices or user data."""
import contextlib
import hashlib
import io
import json
import os
import plistlib
import secrets
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import diagnostic_report as dr
import redact
import beta_intake
import score_cells

HOST = ('帧节拍：交换间隔 1，每帧 16.67 ms（60 帧/秒）\nS2A 标记 MARK：帧 1\n'
        '[声] 稳态窗口：输出峰值 0.5\n优雅退出完成\n')


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        home = mock.patch.object(Path, 'home', return_value=self.root / 'synthetic-home')
        home.start()
        self.addCleanup(home.stop)
        self.source = self.root / 'input'
        (self.source / 'logs').mkdir(parents=True)
        self.output = self.root / 'output'

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, text):
        p = self.source / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p

    def run_cli(self, command, **kwargs):
        # Patch the child's default path without changing HOME or product configuration.
        launcher = """import runpy, sys
from pathlib import Path
from unittest.mock import patch
home, script = sys.argv[1:3]
sys.argv = sys.argv[2:]
sys.path.insert(0, str(Path(script).parent))
with patch.object(Path, 'home', return_value=Path(home)):
    runpy.run_path(script, run_name='__main__')
"""
        return subprocess.run([command[0], command[1], '-c', launcher,
                               str(self.root / 'synthetic-home'), *command[2:]], **kwargs)

    def run_report(self, metadata=None):
        return dr.generate(self.source, self.output, metadata)

    def test_full_model_and_markdown(self):
        meta = {
            'task': {'id': 'R01', 'platform': 'macOS'},
            'code': {'commit': 'a' * 40},
            'package': {'id': 'org.s2arm.synthetic', 'version': '1.2.3', 'commit': 'a' * 40,
                        'sha256': 'b' * 64, 'switches': {}, 'signing': 'ad-hoc', 'build_id': 'synthetic-build', 'target_arch': 'applegpu_g18p.ios27'},
            'game': {'name': 'Synthetic title', 'id': '0100000000000000', 'version': '1.0', 'updates': [], 'dlc': []},
            'device': {'model': 'Synthetic Mac', 'soc': 'Synthetic SoC', 'memory': '16 GiB', 'os': 'Synthetic OS', 'gpu_family': 'Synthetic GPU'},
            'test': {'steps': ['launch synthetic'], 'scene': 'synthetic scene', 'route': 'synthetic route', 'save_id': 'synthetic-save'},
            'reproduction': {'shortest_steps': ['repeat synthetic'], 'first_failure': 'synthetic failure'},
            'untested': {'items': ['energy'], 'reason': 'synthetic fixture has no device'},
        }
        meta['code']['commit'] = 'a' * 40
        meta['package']['sha256'] = 'b' * 64
        meta['package']['switches'] = {'master_key': 'd' * 64, 'titlekek': 'KEY_SENTINEL'}
        meta['game']['id'] = '0100000000000000'
        p = self.root / 'metadata.json'; p.write_text(json.dumps(meta))
        self.put('logs/host.log', HOST)
        self.put('shots/picture.png', 'synthetic image placeholder')
        before = {str(p): p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        result = self.run_report(p)
        self.assertFalse(any(not f.startswith(('sessions[', 'evidence.')) for f in result['missing_fields']))
        self.assertEqual(result['code']['commit'], 'a' * 40)
        self.assertEqual(result['package']['sha256'], 'b' * 64)
        self.assertEqual(result['game']['id'], '0100000000000000')
        self.assertEqual(result['package']['switches']['master_key'], '[REDACTED]')
        self.assertEqual(result['package']['switches']['titlekek'], '[REDACTED]')
        self.assertEqual(json.loads((self.output / 'report.json').read_text()), result)
        md = (self.output / 'report.md').read_text()
        for value in ('Synthetic title', 'Synthetic Mac', 'Synthetic SoC', '16 GiB', 'Synthetic OS', 'synthetic scene', 'synthetic route', 'synthetic failure', 'metadata:code', '1&#46;2&#46;3'):
            self.assertIn(value, md)
        for section, fields in meta.items():
            for field in fields:
                self.assertIn(section + '.' + field, result['field_sources'])
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.source.rglob('*') if p.is_file()})
        media = next(e for e in result['evidence'] if e['type'] == 'media')
        self.assertEqual(media['availability'], 'indexed_only')
        self.assertIsNone(media['sanitized_path'])
        self.assertEqual(media['sha256'], hashlib.sha256(b'synthetic image placeholder').hexdigest())
        self.assertFalse(list(self.output.rglob('*.png')))
        self.assertEqual(result['field_sources']['code.commit'], 'metadata:code.commit')

    def test_double_encoded_chinese_log_restored(self):
        # iOS 0.6.3 及更早：往局日志一处坏字节让客户端整份按 Latin-1 解再存 UTF-8，中文全成二次编码（264 份诊断）。期望（手写）：
        #   收件还原成原中文，坏的那截成一个 U+FFFD；正常中文日志、真西文（café）、纯 ASCII 原样不动
        lines = ["[s2a] 开发设施：关（玩家口径）\n", "[s2a] 地址窗口：多款容器 要 70124 MB\n"]
        raw = lines[0].encode() + b"[dm] \xe5\x86\x99\xe5\x9b\x9e\xe5\x8e\x9f\xe5\x80\n" + lines[1].encode()
        moji = raw.decode('latin-1')            # 旧客户端整份按 Latin-1 解
        (self.source / 'logs').mkdir(parents=True, exist_ok=True)
        (self.source / 'logs' / 'host-20261121-182325.log').write_bytes(moji.encode('utf-8'))   # 再存成 UTF-8
        (self.source / 'logs' / 'host-20261121-190000.log').write_bytes("".join(lines).encode())
        (self.source / 'logs' / 'note.log').write_bytes("café ok\n".encode())
        report = self.run_report()
        got = {e['path']: (self.output / e['sanitized_path']).read_text(encoding='utf-8') for e in report['evidence'] if e.get('sanitized_path')}
        self.assertEqual(got['logs/host-20261121-182325.log'], lines[0] + "[dm] 写回原\ufffd\n" + lines[1])
        self.assertEqual(got['logs/host-20261121-190000.log'], "".join(lines))
        self.assertEqual(got['logs/note.log'], "café ok\n")
        self.assertEqual(dr.undo_double_utf8("plain ascii\n"), "plain ascii\n")

    def test_missing_and_invalid_manifest(self):
        self.put('manifest.json', '{broken')
        result = self.run_report()
        self.assertIsNone(result['code']['commit'])
        self.assertIn('code.commit', result['missing_fields'])
        self.assertTrue(result['warnings'])
        self.assertEqual(result['sessions'], [])
        for key in ('package.build_id', 'package.target_arch', 'device.gpu_family'):
            self.assertIn(key, result['missing_fields'])

    def test_sessions_score_consistency_and_isolation(self):
        self.put('logs/host.log', HOST)
        self.put('logs/host.prev.log', '帧节拍：交换间隔 1，每帧 16.67 ms（60 帧/秒）\n【红】CRASH 信号 6 pc crash\n')
        self.put('logs/frames.tsv', 'frame\twall_us\n2\t16667\n')
        (self.root / 'r.txt').write_text('RESULT=push\n')
        with tempfile.TemporaryDirectory() as ref:
            out = Path(ref) / 'isolated' / 'out'; out.mkdir(parents=True)
            (out / 'host.log').write_text(HOST)
            (out / 'frames.tsv').write_text('frame\twall_us\n2\t16667\n')
            expected, reading, reasons = score_cells.cells(str(out), '')
            expected_bad = score_cells.infra(str(out)) or score_cells.test_unready(str(out)) or score_cells.fps_basis(str(out))
        with mock.patch.object(score_cells, 'BOARD', str(self.root / 'never-board.tsv')):
            result = self.run_report()
        self.assertFalse((self.root / 'never-board.tsv').exists())
        current, prev = result['sessions']
        self.assertEqual(current['reading'], reading)
        self.assertEqual(current['invalid_reason'], expected_bad or None)
        for k, value in expected.items():
            self.assertEqual(current['scores'][k]['legacy'], '—' if expected_bad else value)
        self.assertEqual(current['termination']['status'], 'unknown')
        self.assertEqual(current['observations']['结局'], 'exit')
        self.assertEqual(prev['termination']['status'], 'fail')
        self.assertIsNone(prev['frame_source'])
        self.assertEqual(prev['scores']['帧率']['status'], 'not_tested')

    def test_crash_report_preserves_termination_and_redacts_exported_evidence(self):
        private_path = '/Users/player/CRASH_PATH_SENTINEL/host.m'
        password = 'CRASH_PASSWORD_SENTINEL'
        lines = ['【红】CRASH 信号 6 pc synthetic_crash',
                 '  #0 synthetic_frame ' + private_path,
                 'password=' + password]
        for index, newline in enumerate(('\n', '\r\n')):
            with self.subTest(newline=repr(newline)):
                raw = (newline.join(lines) + newline).encode()
                source = self.put('logs/host.log', '')
                source.write_bytes(raw)
                output = self.root / ('crash-report-' + str(index))
                report = dr.generate(self.source, output)
                self.assertEqual(len(report['sessions']), 1)
                session = report['sessions'][0]
                # The production schema exposes observations/termination, not "end".
                self.assertEqual(session['observations']['结局'], 'crash')
                self.assertEqual(session['observations']['崩溃签名'], '信号6 synthetic_crash')
                self.assertEqual(session['termination'], {'status': 'fail', 'kind': 'crash'})
                self.assertEqual(json.loads((output / 'report.json').read_text()), report)
                evidence = next(e for e in report['evidence'] if e['path'] == 'logs/host.log')
                self.assertEqual(evidence['availability'], 'sanitized_copy')
                sanitized = (output / evidence['sanitized_path']).read_text()
                self.assertIn(lines[0], sanitized)
                self.assertEqual(sanitized.count('[PRIVATE_PATH]'), 1)
                self.assertEqual(sanitized.count('[REDACTED]'), 1)
                exported = '\n'.join(p.read_text() for p in output.rglob('*') if p.is_file())
                for sentinel in (private_path, 'CRASH_PATH_SENTINEL', password):
                    self.assertNotIn(sentinel, exported)
                self.assertIn('crash', (output / 'report.md').read_text())
                self.assertTrue((output / '.complete').is_file())
                self.assertEqual(source.read_bytes(), raw)

    def test_crash_report_cli_keeps_previous_crash_separate_and_redacted(self):
        self.put('logs/host.log', HOST)
        previous = self.put('logs/host.prev.log',
                            '【红】CRASH 信号 11 pc synthetic_previous_crash\n'
                            '  #0 synthetic_frame /Users/player/PREV_CRASH_PATH_SENTINEL/host.m\n'
                            'password=PREV_CRASH_PASSWORD_SENTINEL\n')
        original = previous.read_bytes()
        proc = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / 'diagnostic_report.py'),
                             str(self.source), '--output', str(self.output)],
                            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        report = json.loads((self.output / 'report.json').read_text())
        sessions = {s['source']: s for s in report['sessions']}
        self.assertEqual(set(sessions), {'logs/host.log', 'logs/host.prev.log'})
        self.assertEqual(sessions['logs/host.log']['observations']['结局'], 'exit')
        self.assertEqual(sessions['logs/host.log']['termination'], {'status': 'unknown', 'kind': 'exit'})
        self.assertEqual(sessions['logs/host.prev.log']['observations']['结局'], 'crash')
        self.assertEqual(sessions['logs/host.prev.log']['termination'], {'status': 'fail', 'kind': 'crash'})
        evidence = next(e for e in report['evidence'] if e['path'] == 'logs/host.prev.log')
        sanitized = (self.output / evidence['sanitized_path']).read_text()
        self.assertIn('【红】CRASH 信号 11 pc synthetic_previous_crash', sanitized)
        self.assertEqual(sanitized.count('[PRIVATE_PATH]'), 1)
        self.assertEqual(sanitized.count('[REDACTED]'), 1)
        exported = proc.stdout + proc.stderr + '\n'.join(
            p.read_text() for p in self.output.rglob('*') if p.is_file())
        for sentinel in ('/Users/player/', 'PREV_CRASH_PATH_SENTINEL', 'PREV_CRASH_PASSWORD_SENTINEL'):
            self.assertNotIn(sentinel, exported)
        self.assertEqual(previous.read_bytes(), original)
        self.assertEqual((self.source / 'logs/host.log').read_text(), HOST)

    def test_invalid_frames_and_firstuse_failure(self):
        self.put('logs/host.log', HOST)
        self.put('logs/frames.tsv', 'nonsense\nxxx\n')
        with mock.patch.object(beta_intake.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'secret error')):
            result = self.run_report()
        session = result['sessions'][0]
        self.assertEqual(session['status'], 'invalid')
        self.assertIsNone(session['observations']['首遇现编'])
        self.assertEqual(session['firstuse_status'], 'unknown')
        self.assertNotIn('secret error', json.dumps(result))

    def test_no_mark_and_infra_invalid(self):
        self.put('logs/host.log', '优雅退出完成\n')
        self.put('logs/run.log', '设备通道挂死\n')
        result = self.run_report()
        self.assertEqual(result['sessions'][0]['status'], 'invalid')
        self.assertEqual(result['sessions'][0]['observations']['MARK'], '否')
        self.assertEqual(result['sessions'][0]['operability']['status'], 'invalid')

    def test_redaction_and_markdown_injection(self):
        manifest = {'game': {'name': '<script>alert(1)</script> [bad](https://evil.invalid) | \x01'},
                    'app': {'commit': 'c' * 40, 'token': 'STRUCTURED_SENTINEL'},
                    'device': {'serial': 'SERIAL_SENTINEL'},
                    'password': 'PASSWORD_SENTINEL', 'header_key': 'd' * 64}
        self.put('manifest.json', json.dumps(manifest))
        self.put('logs/token=FILENAME_SENTINEL.log', 'Authorization: Bearer AUTH_SENTINEL\nhttps://USER_SENTINEL:PASS_SENTINEL@example.invalid/?token=QUERY_SENTINEL\n/Users/PATH_SENTINEL/private\nserial=DEVICE_SENTINEL\nheader_key = ' + 'e' * 64 + '\n' + 'f' * 64 + '\n')
        result = self.run_report()
        text = '\n'.join(p.read_text() for p in self.output.rglob('*') if p.is_file())
        for s in ('STRUCTURED_SENTINEL', 'SERIAL_SENTINEL', 'PASSWORD_SENTINEL', 'AUTH_SENTINEL', 'USER_SENTINEL', 'PASS_SENTINEL', 'QUERY_SENTINEL', 'PATH_SENTINEL', 'DEVICE_SENTINEL', 'FILENAME_SENTINEL', 'd' * 64, 'e' * 64, 'f' * 64):
            self.assertNotIn(s, text)
        self.assertIn('c' * 40, text)
        md = (self.output / 'report.md').read_text()
        self.assertNotIn('<script>', md)
        self.assertNotIn('[bad](', md)
        self.assertNotIn('\x01', md)

    def test_zip_rejections(self):
        for label, names in [('parent', ['../evil']), ('absolute', ['/evil']), ('backslash', ['logs\\evil.log']), ('duplicate', ['logs/a.log', 'logs/./a.log']), ('drive', ['C:/evil']), ('dot', ['.'])]:
            zpath = self.root / (label + '.zip')
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                with zipfile.ZipFile(zpath, 'w') as z:
                    for name in names:
                        z.writestr(name, 'x')
            with self.subTest(label=label), self.assertRaises(ValueError):
                dr.generate(zpath, self.output)
            self.assertFalse(self.output.exists())
        zpath = self.root / 'link.zip'
        with zipfile.ZipFile(zpath, 'w') as z:
            item = zipfile.ZipInfo('logs/link.log'); item.create_system = 3; item.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(item, '/outside')
        with self.assertRaises(ValueError):
            dr.generate(zpath, self.output)

    def test_zip_limits(self):
        zpath = self.root / 'limit.zip'
        with zipfile.ZipFile(zpath, 'w') as z:
            z.writestr('logs/a.log', '1234'); z.writestr('logs/b.log', '5678')
        for setting in ({'MAX_FILES': 1}, {'MAX_FILE': 3}, {'MAX_TOTAL': 7}):
            with mock.patch.multiple(dr, **setting), self.assertRaises(ValueError):
                dr.generate(zpath, self.output)
        self.assertFalse(self.output.exists())

    def test_directory_symlinks_player_content_and_output(self):
        secret = self.root / 'outside.log'; secret.write_text('NEVER_READ_SENTINEL')
        (self.source / 'logs' / 'host.log').symlink_to(secret)
        (self.source / 'linked').symlink_to(self.root, target_is_directory=True)
        self.put('saves/host.log', 'SAVE_SENTINEL')
        self.put('keys/host.log', 'KEY_SENTINEL')
        self.put('unrelated/host.log', 'UNRELATED_SENTINEL')
        result = self.run_report()
        self.assertEqual(result['evidence'], [])
        for output in (self.output, self.source, self.source / 'nested', self.root):
            with self.subTest(output=output), self.assertRaises(ValueError):
                dr.generate(self.source, output)
        self.assertEqual(secret.read_text(), 'NEVER_READ_SENTINEL')

    def test_bad_metadata_and_failed_publish_cleanup(self):
        p = self.root / 'meta.json'; p.write_text('{token=ERROR_SENTINEL')
        with self.assertRaises(ValueError):
            self.run_report(p)
        self.assertFalse(self.output.exists())
        with mock.patch.object(dr.os, 'link', side_effect=OSError('error')):
            with self.assertRaises(OSError):
                self.run_report()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob('.s2arm-report-*')))

    def test_empty_fields_evidence_and_nonfinite_json(self):
        self.put('manifest.json', json.dumps({'code': {'commit': '  '}, 'game': {'version': ''}, 'test': {'steps': []}, 'device': {'ios': ' '}}))
        result = self.run_report()
        for field in ('code.commit', 'game.version', 'test.steps', 'device.os', 'evidence.host_logs', 'evidence.frames', 'evidence.media'):
            self.assertIn(field, result['missing_fields'])
        self.assertTrue(result['warnings'])
        p = self.root / 'nonfinite.json'; p.write_text('{"device": {"memory": NaN}}')
        with self.assertRaises(ValueError):
            dr.generate(self.source, self.root / 'nonfinite-output', p)
        self.put('manifest.json', '{"device": {"memory": Infinity}}')
        result = dr.generate(self.source, self.root / 'invalid-manifest')
        self.assertIsNone(result['device']['memory'])
        self.assertTrue(any(w['message'] == 'invalid JSON object' for w in result['warnings']))

    def test_output_reservation_race(self):
        original = Path.mkdir
        def racing(path, *args, **kwargs):
            if path == self.output.resolve():
                original(path)
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, 'mkdir', racing), self.assertRaises(FileExistsError):
            self.run_report()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_additional_private_paths_and_identity_scope(self):
        self.put('logs/host.log', HOST + '\nmaster_key_00 = ' + 'a' * 32 + '\nkey_area_key_application_00=' + 'b' * 32 + '\n')
        self.put('logs/extra.log', '"/Volumes/Synthetic Backup/PRIVATE_SENTINEL/file"\n"/Users/Synthetic Space/PRIVATE_SENTINEL/file"\n/data/user/0/PRIVATE_SENTINEL/files\n\\\\server\\PRIVATE_SENTINEL\\file\n' + json.dumps({'debug': {'commit': 'd' * 64}, 'master_key_00': 'e' * 32, 'key_area_key_application_00': 'f' * 32}))
        result = self.run_report()
        text = '\n'.join(p.read_text() for p in self.output.rglob('*') if p.is_file())
        for sentinel in ('PRIVATE_SENTINEL', 'a' * 32, 'b' * 32, 'd' * 64, 'e' * 32, 'f' * 32):
            self.assertNotIn(sentinel, text)
        self.assertIsNone(result['sessions'][0]['observations']['帧数'])
        self.assertEqual(result['sessions'][0]['heartbeat_status'], 'unknown')

    def test_real_mac_export_keeps_complete_large_job(self):
        sys.path.insert(0, str(ROOT / 'pack' / 'jobs'))
        from core import Context, atomic
        import library
        destination = self.root / 'mac.zip'
        private = self.root / 'private'
        request = dict(schema=1, taskId='synthetic', operation='diagnostics', privateRoot=str(private), library=str(self.root / 'library'), path=str(destination))
        with contextlib.redirect_stdout(io.StringIO()):
            c = Context(request)
            atomic(c.logs / 'jobs' / 'complete.json', dict(state='completed', diagnostics=[dict(code='TEST', severity='error', summary='failure', suggestion='retry', detail={'header_key': 'd' * 64}, stage='run', logPath='logs/tool.log', component='host', exitCode=0)]))
            atomic(c.logs / 'jobs' / 'large.json', {'detail': 'x' * 5000})   # 任务记录在 core.logs_root 的 jobs/（还没建库：私有目录 logs/jobs）
            (c.logs / 'tool.log').write_text('synthetic tool log')
            library.diagnostics(c)
        result = dr.generate(destination, self.output)
        jobs = {j['source']: j for j in result['jobs']}
        self.assertEqual(jobs['jobs/complete.txt']['diagnostics'][0]['code'], 'TEST')
        self.assertEqual(jobs['jobs/complete.txt']['game_result'], 'unknown')
        self.assertEqual(jobs['jobs/large.txt']['parse_status'], 'available')
        self.assertIsNone(jobs['jobs/large.txt']['diagnostics'])
        self.assertEqual(result['sessions'], [])
        self.assertNotIn('d' * 64, '\n'.join(p.read_text() for p in self.output.rglob('*') if p.is_file()))
        self.assertIn('code.commit', result['missing_fields'])
        cli_output = self.root / 'mac-cli'
        proc = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / 'diagnostic_report.py'), str(destination), '--output', str(cli_output)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue((cli_output / '.complete').is_file())
        self.assertEqual(json.loads((cli_output / 'report.json').read_text()), result)

    def test_legacy_metadata_sources_and_separate_firstuse(self):
        self.put('manifest.json', json.dumps({'app': {'commit': '123456789abcdef'}, 'device': {'ios': '27.0'}, 'game': {'version': '1.0'}}))
        self.put('logs/host.log', HOST + '管线现建：one\n管线现建：two\n')
        self.put('logs/host.prev.log', HOST + '管线现建：previous\n')
        p = self.root / 'meta.json'; p.write_text(json.dumps({'game': {'version': '2.0'}}))
        result = self.run_report(p)
        self.assertEqual(result['package']['commit'], '123456789abcdef')
        self.assertIsNone(result['code']['commit'])
        self.assertEqual(result['device']['os'], '27.0')
        self.assertEqual(result['game']['version'], '2.0')
        self.assertEqual(result['field_sources']['package.commit'], 'manifest.json:app.commit')
        self.assertEqual(result['field_sources']['device.os'], 'manifest.json:device.ios')
        self.assertEqual(result['field_sources']['game.version'], 'metadata:game.version')
        self.assertEqual([s['observations']['首遇现编'] for s in result['sessions']], ['2', '1'])

    def test_complete_scoring_windows_pass_and_fail(self):
        for fail in (False, True):
            self.put('logs/host.log', HOST)
            self.put('logs/cold_start.txt', 'synthetic cold start')
            rows = ['frame\twall_us\tmacro_us\txlate_n\tpso_n\tshader_miss']
            rows += [f'{i}\t{50000 if fail else 16667}\t0\t0\t0\t{1 if fail and i == 2 else 0}' for i in range(2, 3303)]
            self.put('logs/frames.tsv', '\n'.join(rows) + '\n')
            for name, count, load in [('pwh.plist', 1, 0), ('pw1.plist', 2, 2000)]:
                (self.source / 'logs' / name).write_bytes(plistlib.dumps({'IORegistry': {'PowerTelemetryData': {'SystemLoadAccumulatorCount': count, 'AccumulatedSystemLoad': load}}}))
            # Same selected files, no input parents or siblings, identical pure-function result.
            expected, reading, reasons = score_cells.cells(str(self.source / 'logs'), '')
            result = dr.generate(self.source, self.root / ('fail-output' if fail else 'pass-output'))
            actual = result['sessions'][0]
            self.assertEqual(actual['reading'], reading)
            for cell, value in expected.items():
                self.assertEqual(actual['scores'][cell]['legacy'], value)
                self.assertEqual(actual['scores'][cell]['reason'], reasons[cell])
            for cell in ('帧率', '能耗'):
                self.assertEqual(actual['scores'][cell]['status'], 'fail' if fail else 'pass')
            # 首局格（10-24 起任一局按我方归因判，不要冷热成对）：报告侧照记分板的值映射
            self.assertEqual(actual['scores']['首局']['status'], {'绿': 'pass', '红': 'fail', '未测': 'not_tested'}[expected['首局']])

    def test_complete_quoted_secrets_across_outputs(self):
        self.assertEqual(redact.redact_text('master_seed_00="synthetic"credential', key_values=[]), 'master_seed_00="[REDACTED]"')
        self.assertEqual(redact.redact_text('master_kek_00="synthetic"credential', key_values=[]), 'master_kek_00="[REDACTED]"')
        self.assertEqual(redact.redact_text('master_seed_00="synthetic""credential with space"', key_values=[]), 'master_seed_00="[REDACTED]"')
        combined = redact.redact_text('seed=\'synthetic\'credential, note=KEEP; kek="other"suffix]\nNORMAL_NEXT_LINE', key_values=[])
        self.assertEqual(combined, 'seed=\'[REDACTED]\', note=KEEP; kek="[REDACTED]"]\nNORMAL_NEXT_LINE')
        self.assertEqual(redact.redact_text('master_seed_00="synthetic"credential, ordinary="visible"', key_values=[]), 'master_seed_00="[REDACTED]", ordinary="visible"')
        payload = {'password': 'synthetic credential', 'nested': {'master_kek_00': 'synthetic', 'note': 'KEEP'}}
        parsed = json.loads(redact.redact_text(json.dumps(payload), key_values=[]))
        self.assertEqual(parsed, {'password': '[REDACTED]', 'nested': {'master_kek_00': '[REDACTED]', 'note': 'KEEP'}})
        lines = [
            '[request] ' + json.dumps({'Authorization': 'Bearer AUTH_QUOTED_SENTINEL'}),
            'password="prefix SECRET_WITH_SPACE"',
            "password='prefix SINGLE_SECRET_SENTINEL'",
            '[request] ' + json.dumps({'password': 'prefix "escaped" ESCAPED_SECRET_SENTINEL'}),
            r"password='prefix \' quoted SINGLE_ESCAPED_SENTINEL'",
        ]
        text = '\n'.join(lines)
        self.put('logs/host.log', HOST + text)
        self.put('logs/password="prefix FILENAME_QUOTED_SENTINEL".log', text)
        self.put('jobs/example.txt', text)
        metadata = self.root / 'quoted.json'
        metadata.write_text(json.dumps({'test': {'steps': [text]}}))
        self.run_report(metadata)
        output = '\n'.join(p.read_text() for p in self.output.rglob('*') if p.is_file())
        for sentinel in ('AUTH_QUOTED_SENTINEL', 'SECRET_WITH_SPACE', 'SINGLE_SECRET_SENTINEL', 'ESCAPED_SECRET_SENTINEL', 'SINGLE_ESCAPED_SENTINEL', 'FILENAME_QUOTED_SENTINEL'):
            self.assertNotIn(sentinel, output)

    def test_ancestor_replacement_uses_trusted_directory_fd(self):
        original = 'INSIDE_ORIGINAL_LOG'
        outside = 'OUTSIDE_SECRET_LOG!'
        self.assertEqual(len(original), len(outside))
        self.put('logs/host.log', original)
        external = self.root / 'external'; external.mkdir()
        (external / 'host.log').write_text(outside)
        real_stat = os.stat
        replaced = False
        def replace_ancestor(path, *args, **kwargs):
            nonlocal replaced
            result = real_stat(path, *args, **kwargs)
            if Path(path).name == 'host.log' and not replaced:
                replaced = True
                (self.source / 'logs').rename(self.source / '.moved-logs')
                (self.source / 'logs').symlink_to(external, target_is_directory=True)
            return result
        # Actual rename+symlink occurs after enumeration/stat, before file open.
        with mock.patch.object(os, 'stat', side_effect=replace_ancestor) as patched:
            with mock.patch.object(os, 'supports_dir_fd', os.supports_dir_fd | {patched}):
                files = dr.collect(self.source)
        self.assertTrue(replaced)
        self.assertEqual(files['logs/host.log'][1], original.encode())
        self.assertNotIn(outside.encode(), [data for _, data in files.values()])
        self.assertTrue((self.source / 'logs').is_symlink())

    def test_empty_host_logs_are_missing_evidence(self):
        for index, text in enumerate(('', ' \n\t ')):
            self.put('logs/host.log', text)
            result = dr.generate(self.source, self.root / ('empty-' + str(index)))
            session = result['sessions'][0]
            self.assertEqual(session['status'], 'not_tested')
            self.assertEqual(session['operability']['status'], 'not_tested')
            self.assertTrue(all(s['status'] == 'not_tested' for s in session['scores'].values()))
            self.assertIn('evidence.host_logs', result['missing_fields'])
            self.assertTrue(any('empty' in w['message'] for w in result['warnings']))
        self.put('logs/host.log', '帧节拍：交换间隔 1，每帧 16.67 ms（60 帧/秒）\n【红】CRASH 信号 6 pc crash\n')
        result = self.run_report()
        self.assertEqual(result['sessions'][0]['operability']['status'], 'fail')
        self.assertEqual(result['sessions'][0]['termination']['status'], 'fail')
        self.assertNotIn('evidence.host_logs', result['missing_fields'])

    def test_wrapper_rejects_missing_mode_and_explicit_empty_metadata(self):
        self.put('logs/host.log', HOST)
        wrapper = str(ROOT / 'tools' / 'beta_intake.py')
        for flags in (['--output', str(self.output)], ['--metadata', ''], ['--metadata', 'missing.json']):
            inbox = self.root / 'never-created-inbox'
            proc = self.run_cli([sys.executable, '-B', wrapper, '--inbox', str(inbox), *flags], capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(inbox.exists())
        for script, prefix in ((wrapper, ['--diagnostic-report', str(self.source)]), (str(ROOT / 'tools' / 'diagnostic_report.py'), [str(self.source)])):
            proc = self.run_cli([sys.executable, '-B', script, *prefix, '--output', str(self.output), '--metadata', ''], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse(self.output.exists())

    def test_directory_without_fd_support_fails_closed(self):
        self.put('logs/host.log', HOST)
        with mock.patch.object(os, 'supports_dir_fd', set()), self.assertRaises(ValueError):
            self.run_report()
        self.assertFalse(self.output.exists())

    def producer_fixture(self, truncated=False, slim=False):
        # Independent schema-1 fixture from ios/diag.m build_zip, no actual device data.
        manifest = {
            'schema': 1,
            'app': {'bundle': 'org.s2arm.synthetic', 'version': '2.3.4', 'commit': '1234567890abcdef1234567890abcdef12345678', 'build_id': 'app-build-synthetic', 'pso_target': 'applegpu_g18p.ios27', 'target_arch': 'WRONG_SOURCE'},
            'game': {'name': '合成游戏', 'title_id': '0100000000000000', 'build_id': 'game-build-synthetic', 'pack_fp': '1234567890abcdef'},
            'device': {'model': 'Synthetic iPhone', 'ios': '27.0', 'ram_mb': 8192, 'gpu_family': 'AppleSynthetic', 'low_power': False},
            'settings': {'language': 'zh-Hans', 'token': 'SETTINGS_SECRET_SENTINEL'},
            'sessions': [{'file': 'host.log', 'end': 'exit'}],
            'metrickit': {'crash': 1, 'hang': 0},
            'files': [{'path': 'logs/host.log', 'bytes': 0, 'truncated': truncated}],
        }
        data = {'logs/host.log': HOST, 'logs/unpack.log': 'synthetic unpack'}
        if not slim:
            data.update({'logs/threads.txt': 'Authorization: Bearer THREAD_SECRET_SENTINEL',
                         'logs/frames.tsv': 'frame\twall_us\n' + ''.join(f'{i}\t16667\n' for i in range(2, 3303)),
                         'metrickit/crash.json': json.dumps({'crash': 'synthetic', 'password': 'METRICKIT_SECRET_SENTINEL'})})
            manifest['files'].extend([{'path': name, 'bytes': len(text.encode()), 'truncated': False} for name, text in data.items() if name != 'logs/host.log'])
        manifest['files'][0]['bytes'] = len(HOST.encode())
        return {'manifest.json': json.dumps(manifest, ensure_ascii=False), **data}

    def test_current_ios_producer_flat_wrapped_and_unflagged_utf8(self):
        class UnflaggedUTF8(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode('utf-8'), self.flag_bits & ~0x800
        fixture = self.producer_fixture()
        reports = []
        for index, wrapper in enumerate(('', 's2a_diag_合成游戏/')):
            path = self.root / ('producer-' + str(index) + '.zip')
            with zipfile.ZipFile(path, 'w') as archive:
                for name, text in fixture.items():
                    archive.writestr(UnflaggedUTF8(wrapper + name), text.encode())
            with zipfile.ZipFile(path) as archive:
                self.assertTrue(all(item.flag_bits & 0x800 == 0 for item in archive.infolist()))
                if wrapper:
                    self.assertNotIn('合成游戏', archive.infolist()[0].filename)
            reports.append(dr.generate(path, self.root / ('producer-out-' + str(index))))
        # A decoded directory wrapper follows the same safe-fd traversal and schema mapping.
        (self.source / 'logs').rmdir()  # This input contains only the producer's unique top-level wrapper.
        wrapped = self.source / 's2a_diag_合成游戏'
        for name, text in fixture.items():
            self.put('s2a_diag_合成游戏/' + name, text)
        reports.append(self.run_report())
        self.assertEqual(reports[0], reports[1])
        self.assertEqual(reports[0], reports[2])
        report = reports[0]
        self.assertEqual(report['code']['commit'], '1234567890abcdef1234567890abcdef12345678')
        self.assertEqual(report['package']['commit'], report['code']['commit'])
        self.assertEqual(report['package']['id'], 'org.s2arm.synthetic')
        self.assertEqual(report['package']['version'], '2.3.4')
        self.assertEqual(report['package']['build_id'], 'app-build-synthetic')
        self.assertEqual(report['package']['target_arch'], 'applegpu_g18p.ios27')
        self.assertEqual(report['device']['gpu_family'], 'AppleSynthetic')
        self.assertEqual(report['field_sources']['package.build_id'], 'manifest.json:app.build_id')
        self.assertEqual(report['field_sources']['package.target_arch'], 'manifest.json:app.pso_target')
        self.assertEqual(report['field_sources']['device.gpu_family'], 'manifest.json:device.gpu_family')
        self.assertEqual(report['game']['id'], '0100000000000000')
        self.assertEqual(report['device']['memory'], '8192 MiB')
        self.assertEqual(report['device']['os'], '27.0')
        self.assertEqual(report['field_sources']['code.commit'], 'manifest.json:app.commit')
        self.assertEqual(report['field_sources']['package.commit'], 'manifest.json:app.commit')
        self.assertEqual(report['field_sources']['game.id'], 'manifest.json:game.title_id')
        self.assertEqual(report['field_sources']['device.memory'], 'manifest.json:device.ram_mb')
        self.assertIsNone(report['game']['version'])
        self.assertIsNone(report['device']['soc'])
        self.assertIsNone(report['package']['sha256'])
        self.assertEqual(report['producer']['app']['build_id'], 'app-build-synthetic')
        self.assertEqual(report['producer']['game']['build_id'], 'game-build-synthetic')
        self.assertEqual(report['producer']['game']['pack_fp'], '1234567890abcdef')
        self.assertEqual(report['producer']['device']['gpu_family'], 'AppleSynthetic')
        self.assertEqual(report['field_sources']['producer.game.pack_fp'], 'manifest.json:game.pack_fp')
        self.assertNotIn('producer.game.version', report['missing_fields'])
        types = {e['path']: e['type'] for e in report['evidence']}
        self.assertEqual(types['logs/threads.txt'], 'diagnostic')
        self.assertEqual(types['metrickit/crash.json'], 'metrickit')
        text = '\n'.join(p.read_text() for p in self.output.rglob('*') if p.is_file())
        for sentinel in ('SETTINGS_SECRET_SENTINEL', 'THREAD_SECRET_SENTINEL', 'METRICKIT_SECRET_SENTINEL'):
            self.assertNotIn(sentinel, text)
        metadata = self.root / 'override.json'
        metadata.write_text(json.dumps({'code': {'commit': 'f' * 40}, 'package': {'id': 'override'}, 'game': {'id': '0100000000000001'}, 'device': {'ios': '28.0', 'memory': '16 GiB'}}))
        overridden = dr.generate(wrapped, self.root / 'overridden', metadata)
        self.assertEqual(overridden['code']['commit'], 'f' * 40)
        self.assertEqual(overridden['package']['id'], 'override')
        self.assertEqual(overridden['game']['id'], '0100000000000001')
        self.assertEqual(overridden['device']['memory'], '16 GiB')
        self.assertEqual(overridden['device']['os'], '28.0')

    def test_zip_decoding_collision_and_wrapper_safety(self):
        class UnflaggedUTF8(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode('utf-8'), self.flag_bits & ~0x800
        path = self.root / 'collision.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(UnflaggedUTF8('metrickit/合成.json'), '{}')
            archive.writestr('metrickit/合成.json', '{}')
        with self.assertRaises(ValueError):
            dr.generate(path, self.output)
        for name in ('../evil', 'wrapper/../evil', 'wrapper\\evil', '/evil'):
            path = self.root / 'unsafe-wrapper.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('wrapper/manifest.json', '{}')
                archive.writestr(name, 'unknown member')
            with self.subTest(name=name), self.assertRaises(ValueError):
                dr.generate(path, self.output)

    def test_producer_truncation_and_slim_evidence(self):
        for truncated in (False, True):
            for name, text in self.producer_fixture(truncated=truncated).items():
                self.put(name, text)
            report = dr.generate(self.source, self.root / ('truncated' if truncated else 'complete'))
            session = report['sessions'][0]
            if truncated:
                self.assertEqual(session['status'], 'invalid')
                self.assertEqual(session['evidence_completeness'], 'partial')
                self.assertTrue(all(s['status'] == 'invalid' for s in session['scores'].values()))
                self.assertIn('logs/host.log', session['truncated_files'])
                self.assertTrue(any('truncated' in warning['message'] for warning in report['warnings']))
            else:
                self.assertEqual(session['scores']['帧率']['status'], 'pass')
            self.assertEqual(report['producer']['files'][0]['truncated'], truncated)
            self.assertEqual(next(e['truncated'] for e in report['evidence'] if e['path'] == 'logs/host.log'), truncated)
        # A truncated frames table alone also invalidates a would-be 55-second green.
        fixture = self.producer_fixture()
        manifest = json.loads(fixture['manifest.json'])
        next(e for e in manifest['files'] if e['path'] == 'logs/frames.tsv')['truncated'] = True
        self.put('manifest.json', json.dumps(manifest))
        report = dr.generate(self.source, self.root / 'partial-frames')
        self.assertEqual(report['sessions'][0]['scores']['帧率']['status'], 'invalid')
        # An explicit crash remains an observation even when whole-session scoring is invalid.
        self.put('logs/host.log', HOST + '【红】CRASH 信号 6 pc synthetic_crash\n')
        report = dr.generate(self.source, self.root / 'partial-crash')
        self.assertEqual(report['sessions'][0]['status'], 'invalid')
        self.assertEqual(report['sessions'][0]['termination']['status'], 'fail')
        self.assertEqual(report['sessions'][0]['observations']['结局'], 'crash')
        # A slim fixture has no frames/threads; exit in producer summary cannot fill missing tests.
        slim = self.root / 'slim'; slim.mkdir()
        for name, text in self.producer_fixture(slim=True).items():
            p = slim / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text)
        report = dr.generate(slim, self.root / 'slim-report')
        self.assertIn('evidence.frames', report['missing_fields'])
        self.assertEqual(report['sessions'][0]['scores']['帧率']['status'], 'not_tested')
        self.assertIsNone(report['game']['version'])
        self.assertIsNone(report['device']['soc'])

    def test_reserved_player_directories_cannot_become_wrappers(self):
        for name in ('keys', 'games', 'saves', 'resources'):
            path = self.root / (name + '.zip')
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr(name + '/manifest.json', '{}')
                archive.writestr(name + '/host.log', 'PLAYER_CONTENT_SENTINEL')
            self.assertEqual(dr.collect(path), {})
            directory = self.root / (name + '-directory')
            (directory / name).mkdir(parents=True)
            (directory / name / 'manifest.json').write_text('{}')
            (directory / name / 'host.log').write_text('PLAYER_CONTENT_SENTINEL')
            self.assertEqual(dr.collect(directory), {})

    def test_producer_budget_is_bounded_and_covers_exporter(self):
        self.assertEqual(dr.MAX_TOTAL, 256 * 1024 * 1024)
        self.assertEqual(dr.MAX_FILE, 16 * 1024 * 1024)
        self.assertEqual(dr.MAX_FILES, 1000)
        self.assertGreater(dr.MAX_TOTAL, 6 * (8 << 20) + 20 * (4 << 20) + (1 << 20))

    def test_unterminated_quoted_secret_values_stop_at_line_end(self):
        cases = [
            ('[request] {"password": "prefix UNTERMINATED_SECRET_SENTINEL', 'UNTERMINATED_SECRET_SENTINEL'),
            ('[request] {"Authorization": "Bearer UNTERMINATED_AUTH_SENTINEL', 'UNTERMINATED_AUTH_SENTINEL'),
            ("password='prefix SINGLE_UNTERMINATED_SENTINEL", 'SINGLE_UNTERMINATED_SENTINEL'),
            (r'password="prefix \" escaped DOUBLE_ESCAPE_UNTERMINATED_SENTINEL', 'DOUBLE_ESCAPE_UNTERMINATED_SENTINEL'),
            (r"password='prefix \' escaped SINGLE_ESCAPE_UNTERMINATED_SENTINEL", 'SINGLE_ESCAPE_UNTERMINATED_SENTINEL'),
            ('password="prefix TRAILING_BACKSLASH_SENTINEL' + chr(92), 'TRAILING_BACKSLASH_SENTINEL'),
        ]
        normal = 'NORMAL_NEXT_LINE: "quoted content stays"'
        for text, sentinel in cases:
            for suffix in ('', '\n' + normal, '\r\n' + normal):
                with self.subTest(secret=sentinel, ending=repr(suffix)):
                    sanitized = dr.redact_text(text + suffix)
                    self.assertNotIn(sentinel, sanitized)
                    if suffix:
                        self.assertIn(normal, sanitized)
        combined = '\n'.join(text + '\n' + normal for text, _ in cases)
        self.put('logs/host.log', HOST + combined)
        self.put('logs/password="prefix FILENAME_UNTERMINATED_SENTINEL.log', combined)
        self.put('jobs/truncated.txt', combined)
        metadata = self.root / 'unterminated-metadata.json'
        metadata.write_text(json.dumps({'test': {'steps': [combined]}}))
        report = self.run_report(metadata)
        outputs = [self.output]
        # The CLI uses the same collector; probe actual artifacts and both output streams.
        cli_output = self.root / 'unterminated-cli'
        proc = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / 'diagnostic_report.py'), str(self.source), '--output', str(cli_output), '--metadata', str(metadata)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        outputs.append(cli_output)
        text = proc.stdout + proc.stderr + '\n'.join(p.read_text() for output in outputs for p in output.rglob('*') if p.is_file())
        for sentinel in [sentinel for _, sentinel in cases] + ['FILENAME_UNTERMINATED_SENTINEL']:
            self.assertNotIn(sentinel, text)
        self.assertIn(normal, text)
        self.assertEqual(json.loads((cli_output / 'report.json').read_text()), report)
        for entry in report['evidence']:
            self.assertNotIn('UNTERMINATED_SENTINEL', entry['path'])

    def test_shared_redaction_real_key_formats_and_identity_values(self):
        # Real file shapes, random fake values only; no real key file is accessed.
        names = ('aes_kek_generation_source aes_key_generation_source bis_kek_source eticket_rsa_kek '
                 'eticket_rsa_kek_source header_kek_source encrypted_keyblob_00 mariko_kek mariko_bek '
                 'master_kek_00 master_kek_source_06 save_mac_kek_source sd_card_kek_source sd_seed ssl_rsa_kek '
                 'header_key key_area_key_application_source key_area_key_ocean_source key_area_key_system_source '
                 'key_area_key_application_00 key_area_key_ocean_00 key_area_key_system_00 master_key_00 '
                 'package1_key_00 package2_key_00 titlekek_00 keyblob_key_source_00 keyblob_mac_key_source '
                 'keyblob_key_00 keyblob_mac_key_00 save_mac_key application_key_area_key_source '
                 'device_key bis_key_00 bis_key_01 bis_key_02 bis_key_03 arbitrary_unknown_identifier').split()
        values = [secrets.token_hex(144 if name == 'encrypted_keyblob_00' else 32 if name == 'header_key' or name.startswith('bis_key_') else 16) for name in names]
        prod = self.root / 'prod.keys'; prod.write_text('\n'.join(f'{name} = {value}' for name, value in zip(names, values)))
        title_values = [secrets.token_hex(16) for _ in range(5)]
        titles = self.root / 'title.keys'; titles.write_text('\n'.join(f'{i:032x} = {value}' for i, value in enumerate(title_values)))
        for newline in ('\n', '\r\n'):
            title_text = newline.join(f'{i:032x} = {value}' for i, value in enumerate(title_values)) + newline
            output = redact.redact_text(title_text, key_values=[])
            self.assertEqual(sum(value in output for value in title_values), 0)
            # The API retains its existing control-character normalization of CR.
            self.assertEqual(output.count('\n'), 5)
        fake_keys = redact.load_key_values([prod, titles])
        self.assertEqual(fake_keys, frozenset(values + title_values))
        self.assertEqual(redact.load_key_values([]), frozenset())
        self.assertEqual(redact.load_key_values([self.root / 'missing.keys']), frozenset())
        with mock.patch.object(Path, 'open', side_effect=PermissionError('synthetic denied')):
            with self.assertRaises(PermissionError):
                redact.load_key_values([prod])
        self.assertEqual(dr.sanitize({'sd_seed': secrets.token_hex(16)}, key_values=frozenset()), {'sd_seed': '[REDACTED]'})
        shaped = prod.read_text() + '\n' + titles.read_text()
        shaped_output = redact.redact_text(shaped, key_values=[])
        context = 'unlabelled ' + ' / '.join(value.upper() for value in values + title_values)
        known_output = redact.redact_text(context, key_values=fake_keys, preserve_identity=True)
        for value in values + title_values:
            self.assertNotIn(value.lower(), shaped_output.lower())
            self.assertNotIn(value.lower(), known_output.lower())
        ordinary_sha = secrets.token_hex(32)
        self.assertEqual(redact.redact_text(ordinary_sha, key_values=fake_keys, preserve_identity=True), ordinary_sha)
        known_sha = next(value for value in values if len(value) == 64)
        self.assertNotIn(known_sha, redact.redact_text(known_sha, key_values=fake_keys, preserve_identity=True))
        self.assertEqual(redact.redact_text('plain text'), 'plain text')
        self.assertEqual(dr.redact_text, redact.redact_text)
        # Known values also win over formal package SHA identity when generating actual artifacts.
        self.put('manifest.json', json.dumps({'package': {'sha256': known_sha}}))
        self.put('logs/host.log', HOST + context)
        report = dr.generate(self.source, self.output, key_paths=[prod, titles])
        self.assertEqual(report['package']['sha256'], '[REDACTED]')
        text = '\n'.join(p.read_text() for p in self.output.rglob('*') if p.is_file()).lower()
        self.assertTrue(all(value not in text for value in values + title_values))
        # Default loading is lazy and resolves only the mocked temporary home path.
        default = Path.home() / '.switch'; default.mkdir(parents=True)
        (default / 'prod.keys').write_text(prod.read_text())
        (default / 'title.keys').write_text(titles.read_text())
        self.assertEqual(redact.load_key_values(), fake_keys)
        cli_output = self.root / 'keys-cli'
        proc = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / 'diagnostic_report.py'), str(self.source), '--output', str(cli_output), '--keys', str(prod), '--keys', str(titles)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cli_text = (proc.stdout + proc.stderr + '\n'.join(p.read_text() for p in cli_output.rglob('*') if p.is_file())).lower()
        self.assertTrue(all(value not in cli_text for value in values + title_values))

    def test_cli_and_intake_safe_mode(self):
        self.put('logs/host.log', HOST)
        for script, args in [('diagnostic_report.py', [str(self.source)]), ('beta_intake.py', ['--diagnostic-report', str(self.source)])]:
            output = self.root / script
            proc = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / script), *args, '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue((output / 'report.json').is_file())
            again = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / script), *args, '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(again.returncode, 1)
            self.assertNotIn(str(self.source), again.stderr)
        self.assertFalse((self.source / 'summary.tsv').exists())
        self.assertFalse((self.source / 'x').exists())
        metadata = self.root / 'bad-metadata.json'; metadata.write_text('{"token": NaN}')
        proc = self.run_cli([sys.executable, '-B', str(ROOT / 'tools' / 'diagnostic_report.py'), str(self.source), '--output', str(self.root / 'bad-output'), '--metadata', str(metadata)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertNotIn(str(metadata), proc.stderr)
        self.assertFalse((self.root / 'bad-output').exists())


if __name__ == '__main__':
    unittest.main()
