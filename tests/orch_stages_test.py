# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁：由 tests/orch_stages_test.sh 调（覆盖面写在那里；11-06 前是「门禁手动」，手动期间镜像依赖变了没人发现、main 上 8 例红）
"""Byte formulas, actual-read invalidation, real CLI seeding; no game inputs."""
import hashlib
import json
import os
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.orch import roots, stages, refresh


class RunFailTail(unittest.TestCase):
    def test_fail_carries_log_tail(self):   # 11-06：阶段事务失败即丢弃，日志跟着没；报红要自带原因（手写期望：工具最后一行原文在消息里，日志照写）
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, 'x.log')
            with self.assertRaises(stages.StageError) as c:
                stages.run([sys.executable, '-c', "import sys; print('第一行'); sys.exit('AttributeError: no pread')"], log=log)
            self.assertIn('AttributeError: no pread', str(c.exception)); self.assertIn('x.log 末尾', str(c.exception))
            self.assertEqual(c.exception.code, 1); self.assertIn('第一行', log.read_text(encoding='utf-8'))


class StageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-orch-stage-')
        self.home = Path(self.temp.name)
        self.store = roots.Roots(self.home / 'roots', shared=False)
        self.source = self.home / 'input'
        (self.source / 'exefs').mkdir(parents=True)
        (self.source / 'romfs/sub').mkdir(parents=True)
        (self.source / 'exefs/main').write_bytes(b'NSO0' + bytes(range(128)))
        (self.source / 'romfs/sub/resource').write_bytes(b'RESOURCE')

    def tearDown(self):
        roots.remove_owned(self.home)
        self.temp.cleanup()

    def test_real_cli_seed_has_same_bytes_and_utf8_lf(self):
        result = subprocess.run([sys.executable, '-X', 'utf8', '-m', 'pack.orch.refresh', '原创',
                                 '--roots', str(self.store.path), '--from-extract', str(self.source),
                                 '--stages', ''], cwd=stages.REPO, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8'))
        current = self.store.cur('原创')
        self.assertEqual((current / 'exefs/main').read_bytes(), b'NSO0' + bytes(range(128)))
        self.assertEqual((current / 'romfs/sub/resource').read_bytes(), b'RESOURCE')
        self.assertNotIn(b'\r', (current / 'seed.txt').read_bytes())

    def test_rewrite_input_digest_uses_entire_content_and_posix_names(self):
        (self.source / 'romfs/sub/a.NRR').write_bytes(b'A')
        expected = hashlib.sha256(b'rewrite-inputs-v1\0')
        for name, content in [('exefs/main', b'NSO0' + bytes(range(128))), ('romfs/sub/a.NRR', b'A')]:
            path = name.encode()
            expected.update(len(path).to_bytes(8, 'little') + path + hashlib.sha256(content).digest())
        first = stages.rewrite_inputs(self.source)
        self.assertEqual(first, expected.hexdigest())
        (self.source / 'romfs/sub/resource').write_bytes(b'not a module, excluded')
        self.assertEqual(stages.rewrite_inputs(self.source), first)
        (self.source / 'romfs/sub/a.NRR').write_bytes(b'B')
        self.assertNotEqual(stages.rewrite_inputs(self.source), first)

    def test_widen_selection_repository_precedes_latest_auto_verdict(self):
        tb, auto = self.home / 'tables', self.home / 'auto'
        for p in (tb / '原创_bid', auto / '原创_bid'):
            p.mkdir(parents=True)
        a = tb / '原创_bid/widen_enable.handheld.tsv'
        a.write_bytes(b'REPO')
        (auto / '原创_bid/widen_enable.handheld.tsv').write_bytes(b'AUTO')
        (auto / '原创_bid/handheld.status').write_text('不过\tnew\n过\told\n', encoding='utf-8')
        dock = auto / '原创_bid/widen_enable.docked.tsv'
        dock.write_bytes(b'DOCK')
        verdict = auto / '原创_bid/docked.status'
        verdict.write_text('未判\tnew\n过\told\n', encoding='utf-8')
        env = dict(S2A_WIDEN_DIR=str(tb), S2A_WIDEN_AUTO=str(auto))
        self.assertEqual(stages.selected_tables('原创', 'bid', env), [a, dock])
        verdict.write_text('不过\tnew\n过\told\n', encoding='utf-8')
        self.assertEqual(stages.selected_tables('原创', 'bid', env), [a])

    def test_widen_repo_table_found_by_build_id_not_pack_name(self):
        # 11-05 旷野之息：仓库表按款名起（botw_<构建号>），Windows / 一键出包包名是 t<程序号> → 旧实现按「包名_构建号」找不到 → 启用 0 点退整套放宽
        #   期望（手写）：① 包名对不上、构建号唯一 → 选到 botw_bid2 那张；② 同一构建号两个目录 → 不猜、一张不选；③ 构建号不同 → 不选
        tb, auto = self.home / 'tables2', self.home / 'auto2'
        (tb / 'botw_bid2').mkdir(parents=True); auto.mkdir(parents=True)
        h = tb / 'botw_bid2/widen_enable.handheld.tsv'; h.write_bytes(b'BOTW')
        env = dict(S2A_WIDEN_DIR=str(tb), S2A_WIDEN_AUTO=str(auto))
        self.assertEqual(stages.selected_tables('t01007ef00011e000', 'bid2', env), [h])
        (tb / 'other_bid2').mkdir(); (tb / 'other_bid2/widen_enable.handheld.tsv').write_bytes(b'X')
        self.assertEqual(stages.selected_tables('t01007ef00011e000', 'bid2', env), [])
        self.assertEqual(stages.selected_tables('t01007ef00011e000', 'bid9', env), [])

    def test_dependencies_rehash_exact_and_missing_orch_cannot_hit(self):
        current = refresh.seed(self.store, '原创', self.source)
        deps = stages.Dependencies('romfsidx', current)
        try:
            # Invoke the real helper under the real dependency hook.
            deps.python('pack/rewriter.py', 'source')
            tx = self.store.begin('原创', 'deps')
            deps.save(tx.path, 'known')
            full = (tx.path / '.stage_romfsidx.deps').read_bytes()
            self.assertNotIn(b'\r\n', full)
            self.assertIn(b'f\tR:pack/stages/romfsidx.sh\t', full)
            self.assertIn(b'f\tR:pack/orch/stages.py\t', full)
            self.assertIn(b'f\tR:pack/rewriter.py\t', full)
            deps.root = tx.path
            self.assertEqual(deps.key('known'), 'known')
            bare = b''.join(line for line in full.splitlines(keepends=True) if b'R:pack/orch/' not in line)
            (tx.path / '.stage_romfsidx.deps').write_bytes(bare)
            self.assertEqual(deps.key('known'), 'known~d')
            tx.abort()
        finally:
            deps.close()

    def test_content_gap_aborts_transaction_and_preserves_current(self):
        current = refresh.seed(self.store, '原创', self.source)
        engine = stages.Stages(self.store)
        # Inject only the core operation boundary; root transaction is real.
        with patch.object(stages, 'romfsidx_key', return_value='key'), patch.object(
                engine, '_romfsidx', side_effect=stages.StageError('original gap', 3)):
            with self.assertRaises(stages.StageError) as error:
                engine.execute('原创', 'romfsidx')
        self.assertEqual(error.exception.code, 3)
        self.assertEqual(self.store.cur('原创'), current)
        self.assertFalse(list(self.store.path.glob('*.tmp')))

    def test_cli_unknown_or_reversed_stages_does_not_create_roots(self):
        target = self.home / 'not-created'
        for value in ('unknown', 'direct_profile,rewrite', 'rewrite,rewrite'):
            p = subprocess.run([sys.executable, '-m', 'pack.orch.refresh', '原创',
                                '--roots', str(target), '--stages', value], cwd=stages.REPO, capture_output=True)
            self.assertEqual(p.returncode, 2)
            self.assertFalse(target.exists())

    def test_missing_prebuilt_index_is_75_without_running_old_dll(self):
        current = refresh.seed(self.store, '原创', self.source)
        tx = self.store.begin('原创', 'index')
        deps = stages.Dependencies('romfsidx', current)
        try:
            with patch.dict(os.environ, {'S2A_PREBUILT_TOOLS': str(self.home / 'missing'), 'DOTNET': sys.executable}):
                with self.assertRaises(stages.StageError) as error:
                    stages.Stages(self.store)._romfsidx(tx, deps)
            self.assertEqual(error.exception.code, 75)
            self.assertFalse((tx.path / 'romfs.s2aidx').exists())
        finally:
            tx.abort(); deps.close()

    def test_index_list_takes_layout_overlay_sizes_and_rejects_additions(self):   # 11-06 覆盖层：索引清单里覆盖文件用覆盖层那份的大小
        (self.source / 'romfs/Layout').mkdir(parents=True, exist_ok=True)
        (self.source / 'romfs/Layout/x.zs').write_bytes(b'orig')
        refresh.seed(self.store, '原创', self.source)
        current = self.store.cur('原创')
        tx = self.store.begin('原创', 'index-ov')
        deps = stages.Dependencies('romfsidx', current)
        seen = {}; real_run = stages.run
        def fake_run(args, **kw):
            if '--list' not in args: return real_run(args, **kw)
            seen['list'] = Path(args[args.index('--list') + 1]).read_text(encoding='utf-8')
            (tx.path / 'romfs.s2aidx').write_bytes(b'idx')
            return '', 0
        try:
            (tx.path / 'ui_overlay/romfs/Layout').mkdir(parents=True)
            (tx.path / 'ui_overlay/romfs/Layout/x.zs').write_bytes(b'widened layout bytes')
            pre = self.home / 'pre'; (pre / 'romfs').mkdir(parents=True); (pre / 'romfs/romfs_index.dll').write_bytes(b'')
            with patch.dict(os.environ, {'S2A_PREBUILT_TOOLS': str(pre), 'DOTNET': sys.executable}), patch.object(stages, 'run', side_effect=fake_run):
                stages.Stages(self.store)._romfsidx(tx, deps)
            rows = dict(r.split('\t', 1)[::-1] for r in seen['list'].splitlines())
            self.assertEqual(rows['Layout/x.zs'], '20')
            self.assertNotEqual(stages.romfsidx_key(tx.path), stages.romfsidx_key(current))
            (tx.path / 'ui_overlay/romfs/Layout/new.zs').write_bytes(b'x')
            with patch.dict(os.environ, {'S2A_PREBUILT_TOOLS': str(pre), 'DOTNET': sys.executable}), patch.object(stages, 'run', side_effect=fake_run):
                with self.assertRaises(stages.StageError):
                    stages.Stages(self.store)._romfsidx(tx, deps)
        finally:
            tx.abort(); deps.close()

    def test_real_direct_profile_core_generates_then_replays_cache(self):
        # Reuse the repository's original NSO/NPDM generator, not game bytes.
        fixture = stages.module('tests/direct_profile_test.py', '_orch_original_nso')
        source = self.home / 'original-nso'
        fixture.extraction(source)
        refresh.seed(self.store, '原创', source)
        engine = stages.Stages(self.store)
        result = engine.execute('原创', 'direct_profile')
        current = self.store.cur('原创')
        self.assertFalse(result['skipped'])
        metadata = json.loads((current / 'direct_profile.json').read_text(encoding='utf-8'))
        self.assertEqual(metadata['source'], 'generated')
        self.assertFalse(metadata['runtime_verified'])
        self.assertFalse(Path(metadata['profile']).is_absolute())
        self.assertNotIn('\\', metadata['profile'])
        self.assertEqual((current / '.stage_direct_profile').read_bytes(), (result['key'] + '\n').encode())
        before = {p.relative_to(current).as_posix(): p.read_bytes()
                  for p in (current / 'direct-profile').rglob('*') if p.is_file()}
        for name, data in before.items():
            if name.endswith(('.tsv', '.json', '.md')):
                self.assertNotIn(b'\r\n', data, name)
        second = engine.execute('原创', 'direct_profile')
        self.assertTrue(second['skipped'])
        self.assertEqual(self.store.cur('原创'), current)
        self.assertEqual(before, {p.relative_to(current).as_posix(): p.read_bytes()
                                 for p in (current / 'direct-profile').rglob('*') if p.is_file()})
        last = json.loads((current / '.orch_last.json').read_text(encoding='utf-8'))
        self.assertEqual(last['version'], current.name)
        self.assertEqual(last['stage'], 'direct_profile')

    def test_rewrite_plan_matches_existing_bash_key(self):
        bash = shutil.which('bash')
        if os.name == 'nt':
            bash = 'C:/Program Files/Git/bin/bash.exe' if Path('C:/Program Files/Git/bin/bash.exe').is_file() else None
        if not bash:
            self.skipTest('bash oracle unavailable; production entry never uses bash')
        fixture = stages.module('tests/direct_profile_test.py', '_orch_key_original_nso')
        source = self.home / 'original-key-nso'
        fixture.extraction(source)
        keyfile = self.home / 'keys.tsv'
        env = dict(os.environ, S2A_ROOT_CUR=source.as_posix(), S2A_STAGE_KEYS=keyfile.as_posix(),
                   S2A_ROOTS=self.store.path.as_posix(), S2A_PYTHON=Path(sys.executable).as_posix(),
                   PYTHONUTF8='1', PYTHONIOENCODING='utf-8', TMPDIR=self.home.as_posix())
        env.pop('S2A_REWRITE_SPIN', None)
        if os.name == 'nt':
            perl_tools = Path(bash).parent.parent / 'usr/bin/core_perl'
            if perl_tools.is_dir():
                env['PATH'] = str(perl_tools) + os.pathsep + env['PATH']
        # key-only mode exercises the unchanged baseline, never builds/runs it.
        p = subprocess.run([bash, '--noprofile', '--norc', 'pack/stage_rewrite.sh', '原创'],
                           cwd=stages.REPO, env=env, capture_output=True, timeout=45)
        self.assertEqual(p.returncode, 0, p.stderr.decode('utf-8', errors='replace'))
        self.assertTrue(keyfile.is_file(), p.stdout.decode('utf-8', errors='replace'))
        deps = stages.Dependencies('rewrite', source)
        deps.env.pop('S2A_REWRITE_SPIN', None)
        try:
            plan = stages.rewrite_plan('原创', source, deps)
            self.assertEqual(deps.env['S2A_REWRITE_SPIN'], '1')
            # Both inputs deliberately lack a previous dependency manifest.
            expected = 'rewrite\t' + plan['key'] + '~d\n'
            self.assertEqual(keyfile.read_bytes(), expected.encode())
        finally:
            deps.close()

    def test_rewrite_plan_keeps_only_record_files_in_dependency_inbox(self):
        fixture = stages.module('tests/direct_profile_test.py', '_orch_inbox_nso')
        source = self.home / 'inbox-nso'
        fixture.extraction(source)
        current = refresh.seed(self.store, '原创', source)
        deps = stages.Dependencies('rewrite', current)
        output = self.home / 'inbox-output'
        output.mkdir()
        try:
            plan = stages.rewrite_plan('原创', current, deps)
            # collect opens each inbox entry as a UTF-8 record file. Tool
            # scratch directories/logs belong outside this protocol directory.
            foreign = sorted(p.name for p in deps.raw.iterdir() if not p.is_file())
            self.assertEqual(foreign, [], 'dependency inbox contains a tool directory')
            self.assertNotIn(deps.raw, plan['addr'].parents)
            self.assertTrue(plan['addr'].is_file())
            deps.save(output, plan['key'])
            self.assertEqual((output / '.stage_rewrite').read_bytes(), (plan['key'] + '\n').encode())
            self.assertIn(b'f\tR:tools/addr_need.py\t', (output / '.stage_rewrite.deps').read_bytes())
            self.assertEqual(Path(deps.temp.name).parent, current.parent)
        finally:
            deps.close()

    def _optional_input_pair(self, kind, verified_platform="apple"):
        """Unmodified bash is the key oracle; C execution stays a separate gate.

        Only a private source mirror receives synthetic repository tables.
        No table or existing source in the checkout is edited by this test.
        """
        bash = shutil.which('bash')
        if os.name == 'nt':
            candidate = Path('C:/Program Files/Git/bin/bash.exe')
            bash = str(candidate) if candidate.is_file() else None
        if not bash:
            self.skipTest('bash key oracle unavailable')
        original = stages.REPO
        mirror = self.home / 'key-repo'
        listed = subprocess.check_output(['git', '-C', str(original), 'ls-files', '-z', '--',
            'pack/roots.sh', 'pack/stage_rewrite.sh', 'pack/stage_keyfiles.sh', 'pack/rewriter.py',
            'pack/cpatch.py', 'runtime/rewriter', 'graphics/widen/scan', 'tools/addr_need.py',
            'tools/stage_deps.py', 'tools/stage_deps_hook', 'graphics/nvn/tools/romfs_list.py',
            'tools/nso_plain.py', 'pack/pkg_srcs.py'])   # 11-06：10b9156f3 起 addr_need.py 顶层 import nso_plain、stages.selected_tables 加载 pack/pkg_srcs.py，镜像少这两个 8 例红
        for name in listed.decode('utf-8').split('\0'):
            if name and (original / name).is_file():
                dest = mirror / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes((original / name).read_bytes())
        subprocess.run(['git', 'init', '-q', str(mirror)], check=True)
        g = ['git', '-C', str(mirror), '-c', 'core.autocrlf=false',
             '-c', 'user.name=Original test', '-c', 'user.email=test@example.invalid']
        subprocess.run(g + ['add', '.'], check=True)
        subprocess.run(g + ['commit', '-qm', 'original key fixture'], check=True)
        fixture = stages.module('tests/direct_profile_test.py', '_orch_optional_nso')
        source = self.home / 'optional-nso'
        fixture.extraction(source)
        bid = (source / 'exefs/main').read_bytes()[0x40:0x50].hex()
        pid = fixture.TID
        patchfile = self.home / 'patches' / pid / 'patch.tsv'
        fps = mirror / 'runtime/fps' / (bid[:16] + '.tsv')
        table = self.home / 'widen' / ('probe_' + bid) / 'widen_enable.handheld.tsv'
        verified = table.parent.parent / 'verified.tsv'
        index = self.home / 'community/pack/gfx/INDEX.tsv'
        cv = mirror / 'graphics/cpatch/verified.tsv'
        code_bytes = ('build\t' + bid + '\n[code]\nmain 0 orig=00000000 new=1f2003d5\n'
                      '[runtime]\nunchanged-key\n').encode()
        fps_bytes = b'# original frame table\npresent\tdisplay\n'
        table_bytes = b'# original widen table\nmain\t0x100\n'
        verified_bytes = (pid + '\t' + bid + '\toriginal-verdict\t' + verified_platform + '\n').encode()
        index_bytes = b'path\tsha256\noriginal.pchtxt\t0123456789abcdef\n'
        env = dict(os.environ, S2A_ROOT_CUR=source.as_posix(), S2A_ROOTS=self.store.path.as_posix(),
                   S2A_PYTHON=Path(sys.executable).as_posix(), PYTHONIOENCODING='utf-8',
                   S2A_WIDEN_DIR=table.parent.parent.as_posix(), S2A_WIDEN_AUTO=(self.home / 'no-auto').as_posix(),
                   S2A_COMMUNITY_DIR=(self.home / 'no-community').as_posix(), S2A_CPATCH_DIRS='',
                   S2A_PATCH_DIR=patchfile.parent.parent.as_posix(), S2A_CPATCH='gfx:explicit',
                   S2A_COMMUNITY_PATCHES='0', S2A_REWRITE_SPIN='1', TMPDIR=self.home.as_posix())
        for name in ('S2A_REWRITER_C', 'S2A_REWRITER_BUNDLED', 'S2A_COMMUNITY_SELECT',
                     'S2A_STAGE_KEYS', 'S2A_DEPS_OUT', 'S2A_CODE_PATCH', 'S2A_CODE_BUILD',
                     'S2A_FPS_TSV', 'S2A_CPATCH_TSV'):
            env.pop(name, None)
        if os.name == 'nt':
            env['PATH'] = str(Path(bash).parent.parent / 'usr/bin/core_perl') + os.pathsep + env['PATH']
        keys = []
        for present in (False, True):
            with self.subTest(kind=kind, present=present):
                if present:
                    rows = {'code': [(patchfile, code_bytes)], 'fps': [(fps, fps_bytes)],
                            'widen': [(table, table_bytes), (verified, verified_bytes)],
                            'community': [(index, index_bytes),
                                (cv, (pid + '\t' + bid + '\tgfx:verified\n').encode())]}[kind]
                    for p, data in rows:
                        p.parent.mkdir(parents=True, exist_ok=True)
                        p.write_bytes(data)
                    if kind == 'community':
                        env.update(S2A_COMMUNITY_PATCHES='1', S2A_CPATCH_DIRS=str(index.parent))
                keyfile = self.home / ('oracle-' + str(present))
                oracle = dict(env, S2A_STAGE_KEYS=keyfile.as_posix())
                if os.name == 'nt' and oracle['S2A_CPATCH_DIRS']:
                    # bash uses POSIX colon-separated paths, Python uses os.pathsep.
                    p = index.parent.as_posix()
                    oracle['S2A_CPATCH_DIRS'] = '/' + p[0].lower() + p[2:]
                result = subprocess.run([bash, '--noprofile', '--norc', 'pack/stage_rewrite.sh', 'probe'],
                                        cwd=mirror, env=oracle, capture_output=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
                with patch.object(stages, 'REPO', mirror), patch.object(stages, 'git',
                        lambda *args: roots.git(*args, repo=mirror)), patch.dict(os.environ, env, clear=True):
                    deps = stages.Dependencies('rewrite', source)
                    try:
                        plan = stages.rewrite_plan('probe', source, deps)
                        self.assertEqual(keyfile.read_bytes(), ('rewrite\t' + plan['key'] + '~d\n').encode())
                        keys.append(plan['key'])
                        self.assertEqual(bool(plan['patch']), present and kind == 'code')
                        self.assertEqual(bool(plan['fps']), present and kind == 'fps')
                        self.assertEqual(bool(plan['tables']), present and kind == 'widen')
                        self.assertEqual(bool(plan['community']), present and kind == 'community')
                        if present and kind == 'community':
                            self.assertEqual(plan['selection'], 'gfx:verified,gfx:explicit')
                        self._check_rewrite_forwarding(deps, plan, kind, present, table_bytes,
                                                       verified_bytes, fps_bytes, verified_platform)
                        if present:
                            self.assertNotEqual(keys[0], keys[1], kind + ' must invalidate the stage key')
                    finally:
                        deps.close()

    def _check_rewrite_forwarding(self, deps, plan, kind, present, table_bytes, verified_bytes, fps_bytes, verified_platform):
        # Protocol-only C boundary: assertions inspect the environment and the
        # copied inputs. It does not prove patched machine-code output bytes.
        output = self.home / ('forward-' + kind + '-' + str(present))
        (output / 'exefs').mkdir(parents=True)
        (output / 'romfs').mkdir()
        (output / 'exefs/main').write_bytes(b'original boundary')
        (output / 'exefs/main.npdm').write_bytes(b'original npdm')
        calls, rounds = [], []
        def python(relative, *args, **kwargs):
            if relative.endswith('wide_scan.py'):
                (output / 'widen_sites.tsv').write_bytes(b'')
            elif relative == 'pack/cpatch.py':
                rounds.append(args[0])
                if args[0] == 'plan':
                    (output / 'cpatch_rows.tsv').write_bytes(b'original rows\n')
            return '', 0
        def binary(args, **kwargs):
            calls.append(dict(kwargs['env']))
            return '', 0
        with patch.object(deps, 'python', python), patch.object(stages, 'run', binary):
            stages.Stages(self.store)._rewrite(type('Tx', (), {'path': output})(), deps, plan, 'boundary', 'probe')
        self.assertEqual(len(calls), 2 if present and kind == 'community' else 1)
        for call in calls:
            if present and kind == 'code':
                self.assertEqual(call['S2A_CODE_PATCH'], str(plan['patch']))
                self.assertEqual(call['S2A_CODE_BUILD'], plan['bid'])
            else:
                self.assertNotIn('S2A_CODE_PATCH', call)
                self.assertNotIn('S2A_CODE_BUILD', call)
            if present and kind == 'fps':
                self.assertEqual(Path(call['S2A_FPS_TSV']).read_bytes(), fps_bytes)
            else:
                self.assertNotIn('S2A_FPS_TSV', call)
        if present and kind == 'widen':
            self.assertEqual((output / 'widen_enable.handheld.tsv').read_bytes(), table_bytes)
            if verified_platform == 'apple':
                self.assertEqual((output / 'widen_verified.tsv').read_bytes(), verified_bytes)
            else:
                self.assertFalse((output / 'widen_verified.tsv').exists(), 'android 验证行不能进 Apple 根')
        else:
            self.assertFalse((output / 'widen_verified.tsv').exists())
        if present and kind == 'community':
            self.assertEqual(rounds, ['plan', 'prune'])
            self.assertNotIn('S2A_CPATCH_TSV', calls[0])
            self.assertEqual(Path(calls[1]['S2A_CPATCH_TSV']).read_bytes(), b'original rows\n')
        else:
            self.assertEqual(rounds, [])

    def test_rewrite_gap_degrades_like_shell(self):
        """#893：改写器退出码 3（有缺口、产物照出）→ 降级继续、写 degrade.rewrite.tsv，与 pack/stage_rewrite.sh 同口径；
        退出码 3 却没出 patched.bin（改写空间超上限）→ 停。期望按规则手写：main 2 处 ldr、1 处 svc 缺口 → gap 3、gap:ldr 2、gap:svc 1"""
        import importlib
        degrade = importlib.import_module('pack.rewrite_degrade')
        for produced in (True, False):
            output = self.home / ('gap-' + str(produced))
            (output / 'exefs').mkdir(parents=True); (output / 'romfs').mkdir()
            (output / 'exefs/main').write_bytes(b'x'); (output / 'exefs/main.npdm').write_bytes(b'n')
            (output / 'addr.tsv').write_bytes(b''); (output / 'addr.log').write_bytes(b'')
            plan = dict(tables=[], verified='', fps=None, patch=None, community=False, bid='B',
                        addr=output / 'addr.tsv', addr_log=output / 'addr.log')
            def python(relative, *args, **kwargs):
                if relative == 'pack/rewrite_degrade.py':
                    return (degrade.summarize(str(args[0]), args[1]) or '') + '\n', 0
                if relative.endswith('wide_scan.py'):
                    (output / 'widen_sites.tsv').write_bytes(b'')
                return '', 0
            def binary(args, **kwargs):   # 仿 stages.run：退出码不在 allowed 里就报 StageError
                Path(kwargs['log']).write_bytes(b'PFRW mod=main need=9 gaps=3 fatal=0\n')   # stages.run 照写日志
                if produced:
                    (output / 'main.patched.bin').write_bytes(b'p')
                    (output / 'main.gaps.tsv').write_text('# BUILD_ID\tB\n0x10\tldr\tno slot\n0x20\tldr\tno slot\n0x30\tsvc\tno slot\n', encoding='utf-8')   # 同 rewriter.c：地址 / 类别 / 原因
                if 3 not in kwargs.get('allowed', (0,)):
                    raise stages.StageError('rewriter 退出 3', 3)
                return '', 3
            with patch.object(stages, 'run', binary):
                deps = type('Deps', (), {'env': {}, 'python': staticmethod(python)})()
                if produced:
                    stages.Stages(self.store)._rewrite(type('Tx', (), {'path': output})(), deps, plan, 'boundary', 'probe')
                    rows = [l.split('\t')[:3] for l in (output / 'degrade.rewrite.tsv').read_text(encoding='utf-8').splitlines()[1:]]
                    self.assertEqual(rows, [['rewrite', 'gap', '3'], ['rewrite', 'gap:ldr', '2'], ['rewrite', 'gap:svc', '1']])
                else:
                    with self.assertRaises(stages.StageError) as raised:
                        stages.Stages(self.store)._rewrite(type('Tx', (), {'path': output})(), deps, plan, 'boundary', 'probe')
                    self.assertIn('改写空间超过了能放下的上限', str(raised.exception))
        self.assertIn('degrade.rewrite.tsv', stages.REWRITE_OUTPUTS)   # 降级表随改写产物进产物根（出包作业收尾读它给玩家提示）

    def test_code_patch_present_absent_key_and_forwarding(self):
        self._optional_input_pair('code')

    def test_fps_table_present_absent_key_and_forwarding(self):
        self._optional_input_pair('fps')

    def test_widen_tables_present_absent_key_and_forwarding(self):
        self._optional_input_pair('widen')

    def test_android_verification_not_forwarded_to_apple_root(self):
        self._optional_input_pair('widen', verified_platform='android')

    def test_community_present_absent_key_and_forwarding(self):
        self._optional_input_pair('community')

    def test_romfs_index_key_matches_declared_posix_byte_formula(self):
        # File bytes are not part of this index key; only POSIX name and size.
        objects = stages.git('rev-parse', 'HEAD:services/S2A.Services/RomFsIndex.cs',
                             'HEAD:services/romfs_index', 'HEAD:services/romfs_index.sh',
                             'HEAD:compat/tree/Directory.Packages.props')
        kt = hashlib.sha256((objects + '\n').encode()).hexdigest()[:16]
        kr = hashlib.sha256(b'sub/resource\t8\n').hexdigest()[:16]
        expected = hashlib.sha256((kr + ' ' + kt).encode()).hexdigest()[:16]
        self.assertEqual(stages.romfsidx_key(self.source), expected)
        (self.source / 'romfs/sub/resource').write_bytes(b'12345678')
        self.assertEqual(stages.romfsidx_key(self.source), expected)
        (self.source / 'romfs/sub/resource').write_bytes(b'123456789')
        self.assertNotEqual(stages.romfsidx_key(self.source), expected)

    @unittest.skipUnless(os.name == 'nt', 'Windows Job timeout boundary')
    def test_tool_timeout_terminates_only_the_owned_process(self):
        with self.assertRaises(stages.StageError) as error:
            stages.run([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=.1)
        self.assertEqual(error.exception.code, 1)
        self.assertIn('超时', str(error.exception))

    def test_external_dependency_change_cannot_reuse_stage(self):
        current = refresh.seed(self.store, '原创', self.source)
        external = self.home / 'declared-external/table.tsv'
        external.parent.mkdir()
        external.write_bytes(b'old\n')
        deps = stages.Dependencies('romfsidx', current)
        deps.env['S2A_DEPS_EXTERNAL'] = str(external.parent)
        deps.record(external)
        tx = self.store.begin('原创', 'dep-change')
        try:
            deps.save(tx.path, 'key')
            deps.root = tx.path
            self.assertEqual(deps.key('key'), 'key')
            external.write_bytes(b'new\n')
            self.assertEqual(deps.key('key'), 'key~d')
        finally:
            tx.abort(); deps.close()

    def test_index_manifest_preserves_eight_baseline_repository_rows(self):
        refresh.seed(self.store, '原创', self.source)
        engine = stages.Stages(self.store)
        def original_core_boundary(tx, deps):
            (tx.path / 'romfs.s2aidx').write_bytes(b'original test boundary')
        # Only the unavailable .NET boundary is substituted; root helpers and
        # their actual-read hook run. This does not validate index file bytes.
        with patch.object(engine, '_romfsidx', original_core_boundary):
            engine.execute('原创', 'romfsidx')
        current = self.store.cur('原创')
        rows = (current / '.stage_romfsidx.deps').read_text(encoding='utf-8').splitlines()
        names = [line.split('\t')[1] for line in rows if not line.split('\t')[1].startswith('R:pack/orch/')]
        self.assertEqual(names, [
            'R:graphics/nvn/tools/romfs_list.py', 'R:pack/resource_input_key.py',
            'R:pack/stage_keyfiles.sh', 'R:pack/stages/romfsidx.sh',
            'R:tools/clonedir.py', 'R:tools/direct_shards.py', 'R:tools/stage_deps.py',
            'R:tools/stage_deps_hook/sitecustomize.py'])

    @unittest.skipUnless(os.environ.get('S2A_ORCH_TEST_DOTNET') or shutil.which('dotnet'), 'existing .NET tool required; never downloaded')
    def test_unrestored_index_build_is75_without_running_old_dll(self):
        current = refresh.seed(self.store, '原创', self.source)
        tx = self.store.begin('原创', 'no-restored-assets')
        deps = stages.Dependencies('romfsidx', current)
        tool = os.environ.get('S2A_ORCH_TEST_DOTNET') or shutil.which('dotnet')
        run = stages.run
        calls = []
        def isolated_assets(args, **kwargs):
            command = [str(a) for a in args]
            if command[0] == str(tool):
                calls.append(command)
                if command[1] == 'build':
                    # Redirect only MSBuild's asset lookup to a fresh private
                    # directory; keep the real SDK, source and --no-restore.
                    command.append('-p:MSBuildProjectExtensionsPath=' + str(self.home / 'fresh-obj') + os.sep)
            return run(command, **kwargs)
        try:
            with patch.dict(os.environ, {'DOTNET': str(tool), 'S2A_PREBUILT_TOOLS': ''}), patch.object(stages, 'run', isolated_assets):
                with self.assertRaises(stages.StageError) as error:
                    stages.Stages(self.store)._romfsidx(tx, deps)
            self.assertEqual(error.exception.code, 75)
            self.assertIn('project.assets.json', (tx.path / 'romfs_index_build.log').read_text(encoding='utf-8-sig'))
            self.assertFalse((self.home / 'fresh-obj/project.assets.json').is_file())
            self.assertEqual(len(calls), 1, 'failed build must not execute an old DLL')
            self.assertIn('--no-restore', calls[0])
            self.assertFalse((tx.path / 'romfs.s2aidx').exists())
            self.assertEqual(self.store.cur('原创'), current)
        finally:
            tx.abort()
            deps.close()

    @unittest.skipUnless(os.environ.get('S2A_ORCH_TEST_DOTNET') or shutil.which('dotnet'), 'existing .NET tool and offline restored inputs required')
    def test_real_index_core_structure_and_repeat_cache(self):
        initial = refresh.seed(self.store, '原创', self.source)
        tool = os.environ.get('S2A_ORCH_TEST_DOTNET') or shutil.which('dotnet')
        with patch.dict(os.environ, {'DOTNET': tool, 'S2A_PREBUILT_TOOLS': ''}):
            engine = stages.Stages(self.store)
            try:
                result = engine.execute('原创', 'romfsidx')
            except stages.StageError as error:
                # A clean checkout may have an SDK but no restored assets.
                # Verify the public environment code/rollback before skipping;
                # restored builds and any non-75 failure must still fail.
                self.assertEqual(error.code, 75, str(error))
                self.assertEqual(self.store.cur('原创'), initial)
                self.assertFalse(list(self.store.path.glob('*.tmp')))
                self.assertFalse((initial / 'romfs.s2aidx').exists())
                if (stages.REPO / 'services/romfs_index/obj/project.assets.json').is_file():
                    raise
                self.skipTest('existing .NET SDK has no offline-restored project assets (exit75 verified)')
            current = self.store.cur('原创')
            raw = (current / 'romfs.s2aidx').read_bytes()
            magic, total, count = struct.unpack_from('<8sqI', raw)
            self.assertEqual(magic, b'S2ARFS01')
            self.assertEqual(count, 1)
            offset, size, start, length = struct.unpack_from('<qqii', raw, 20)
            self.assertEqual(size, 8)
            self.assertGreaterEqual(total, offset + size)
            region = 20 + 24 * count
            path_length = struct.unpack_from('<i', raw, region)[0]
            paths = raw[region + 4:region + 4 + path_length]
            self.assertEqual(paths[start:start + length], b'sub/resource')
            self.assertNotIn(b'RESOURCE', raw)  # index excludes original payload
            self.assertFalse(result['skipped'])
            self.assertTrue(engine.execute('原创', 'romfsidx')['skipped'])
            self.assertEqual(self.store.cur('原创'), current)


if __name__ == '__main__':
    unittest.main()
