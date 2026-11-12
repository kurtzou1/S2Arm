# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/stages.py pack/orch/refresh.py
# 门禁入口：bash tests/orch_stages_light_test.sh（S2A_PY 可指定现有 Python）
"""Original tiny roots; no game bytes, downloads, compiler or device access."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.orch import roots, stages, refresh


class LightTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-orch-light-')
        self.home = Path(self.temp.name)
        self.store = roots.Roots(self.home / 'roots', shared=False)
        self.source = self.home / 'source'
        (self.source / 'exefs').mkdir(parents=True)
        (self.source / 'romfs').mkdir()
        (self.source / 'exefs/main').write_bytes(b'NSO0' + bytes(128))
        self.sources = self.home / 'containers'
        self.sources.mkdir()
        self.environment = patch.dict(os.environ, {
            'S2A_GAME_SRC': str(self.sources), 'S2A_RUN_ROOT': str(self.home / 'run'),
            'S2A_SRC_IDS': str(self.home / 'source-ids.tsv'),
            'S2A_AOC_CACHE': str(self.home / 'aoc-cache'),
            'S2A_WIDEN_DIR': str(self.home / 'overlays'),
            'S2A_KEYS': str(self.home / 'unused-original.keys'),
            'S2A_SYSDATA': '', 'S2A_FONTS': '', 'S2A_APP_FONTS_DIRS': '',
            'S2A_OPENFONTS_DIR': str(self.home / 'openfonts')})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        roots.remove_owned(self.home)
        self.temp.cleanup()

    def test_all_light_expands_once_in_dependency_order(self):
        calls = []
        class Engine:
            def __init__(self, store):
                pass
            def execute(self, game, stage):
                calls.append(stage)
                return dict(seconds=0, version='original', key='key', skipped=False)
        with patch.object(refresh, 'Roots', return_value=self.store), patch.object(refresh, 'Stages', Engine), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                code = refresh.main(['原创', '--stages', 'all-light'])
            except SystemExit as error:
                code = error.code
        self.assertEqual(code, 0)
        self.assertEqual(calls, ['rewrite', 'sysdata', 'uilayout', 'aoc', 'caps',
                                 'romfsidx', 'nacp', 'direct_profile'])

    def test_cli_os_error_logs_traceback(self):   # 11-05 Windows 出包机无人深空：系统调用层错误只有系统消息、定不了出处 → 中止时把调用栈写进日志（指到抛错的函数）
        class Engine:
            def __init__(self, store):
                pass
            def execute(self, game, stage):
                def deep_win32_call(): raise OSError(31, '连到系统上的设备没有发挥作用。')
                deep_win32_call()
        err = io.StringIO()
        with patch.object(refresh, 'Roots', return_value=self.store), patch.object(refresh, 'Stages', Engine), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = refresh.main(['原创', '--stages', 'caps'])
        self.assertEqual(code, 1)
        self.assertIn('【红】编排中止：[Errno 31] 连到系统上的设备没有发挥作用。', err.getvalue())
        self.assertIn('deep_win32_call', err.getvalue())

    def test_seed_cleanup_error_keeps_cause(self):
        # #669：播种某步失败 → 删半成品时又报 WinError 145（目录不是空的）。原先 145 盖住起因、红字又不在日志最后几行，玩家报告只剩包装层一帧。
        #   期望手写：日志最后一行是红字，含起因「改名失败」和清理失败的附注；不再是 145 当主错误
        def commit(self, **kw): raise OSError(13, '改名失败')
        def abort(self): raise OSError(41, '目录不是空的。')
        err = io.StringIO()
        with patch.object(refresh, 'Roots', return_value=self.store), patch.object(roots.Transaction, 'commit', commit), \
                patch.object(roots.Transaction, 'abort', abort), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = refresh.main(['原创', '--from-extract', str(self.source), '--stages', ''])
        self.assertEqual(code, 1)
        last = err.getvalue().strip().splitlines()[-1]
        self.assertTrue(last.startswith('【红】编排中止：[Errno 13] 改名失败'), last)
        self.assertIn('随后的清理 abort', last)
        self.assertIn('目录不是空的', last)

    def test_seed_reports_file_progress(self):
        # #361：播种逐文件拷时写「播种 已拷 / 总数」（出包进度协议），不再让进度条停在解包 100% 像卡死。期望手写：源里 exefs 1 个 + romfs 3 个文件 →
        #   总数 4，最后一行已拷 = 4（每秒最多一行，末项必写）
        for n in ('a', 'b', 'c'):
            (self.source / 'romfs' / n).write_bytes(n.encode())
        prog = self.home / 'progress.tsv'
        with patch.dict(os.environ, {'S2A_PROGRESS': str(prog)}):
            refresh.seed(self.store, '原创', self.source)
        rows = [l.split('\t') for l in prog.read_text(encoding='utf-8').splitlines() if '\t播种\t' in l]
        self.assertTrue(rows); self.assertEqual(rows[-1][2:], ['4', '4'])

    def test_shaders_stage_is_gone(self):
        # 只服务通用模式的着色器阶段（11-07 拆通用模式）：编排不再认它，--stages shaders 当未知阶段拒（argparse 退 2）
        self.assertNotIn('shaders', stages.ENTRY)
        self.assertNotIn('shaders', stages.LIGHT_ORDER)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            refresh.main(['原创', '--stages', 'shaders'])
        self.assertEqual(error.exception.code, 2)

    def test_caps_real_core_cache_and_rewrite_key_change(self):
        fixture = stages.module('tests/direct_profile_test.py', '_orch_light_original_nso')
        source = self.home / 'nso'
        fixture.extraction(source)
        refresh.seed(self.store, '原创', source)
        tx = self.store.begin('原创', self.store.tag('原创', 'original-rewrite'))
        roots.text(tx.path / '.stage_rewrite', 'original\n')
        tx.commit()
        engine = stages.Stages(self.store)
        result = engine.execute('原创', 'caps')
        self.assertFalse(result['skipped'])
        first_key = result['key']
        current = self.store.cur('原创')
        for name in ('s2a_caps.tsv', 's2a_caps.all.tsv'):
            raw = (current / name).read_bytes()
            self.assertNotIn(b'\r', raw)
            self.assertIn(b'gyro\t1\t# ', raw)
            self.assertIn(b'haptics\t1\t# ', raw)
        self.assertTrue(engine.execute('原创', 'caps')['skipped'])
        tx = self.store.begin('原创', self.store.tag('原创', 'changed-rewrite'))
        roots.text(tx.path / '.stage_rewrite', 'changed\n')
        tx.commit()
        result = engine.execute('原创', 'caps')
        self.assertFalse(result['skipped'])
        self.assertNotEqual(result['key'], first_key)

    def test_caps_protocol_has_exact_bytes_for_both_modes(self):
        class Decision:
            env = {}
            def python(self, *args, **kwargs):
                return '1\t原创帧率\t0\t原创宽屏\t1\n0\t原测试帧率\t1\t原测试宽屏\t0\n', 0
        output = self.home / 'caps'
        output.mkdir()
        stages.Stages._caps(output, Decision())
        common = '# 格式：<能力>\\t<值>\\t# <原因>（1 = 开，0 = 显式关）；优先级：启动环境 > Settings.bundle（用户改过的设置）> 本文件\n'
        expected = ('plat\tapple\n'
                    '# 包内能力清单（发布包：60 帧默认开、强信号才关；满屏默认关、真机验过或有补丁才开（tools/caps_policy.py））\n'
                    + common + 'widen\t0\t# 原创宽屏\nfps60\t1\t# 原创帧率\ndirect\t1\t# 直连可用\n'
                    'gyro\t1\t# 宿主通用能力\nhaptics\t1\t# 宿主通用能力\n'
                    'fps60_display\t1\t# 引擎通用：放开出图间隔（全引擎，同局 A/B 判红才关）\n')
        self.assertEqual((output / 's2a_caps.tsv').read_bytes(), expected.encode('utf-8'))
        expected = ('plat\tapple\n' + '# 包内能力清单（--all-caps 出包：有来源即开、不看强信号）\n' + common
                    + 'widen\t1\t# 原测试宽屏\nfps60\t0\t# 原测试帧率\ndirect\t1\t# 直连可用\n'
                    'gyro\t1\t# 宿主通用能力\nhaptics\t1\t# 宿主通用能力\n')
        self.assertEqual((output / 's2a_caps.all.tsv').read_bytes(), expected.encode('utf-8'))

    def test_sysdata_real_core_fonts_synth_skip_and_font_change(self):
        zone = self.source / 'systemdata/010000000000080e'
        zone.mkdir(parents=True)
        (zone / 'original').write_bytes(b'original timezone')
        fonts = self.home / 'fonts'
        fonts.mkdir()
        (fonts / 'original.bfttf').write_bytes(b'original font fixture')
        refresh.seed(self.store, '原创', self.source)
        engine = stages.Stages(self.store)
        with patch.dict(os.environ, {'S2A_FONTS': str(fonts)}), patch.object(engine, '_tz_pins', side_effect=AssertionError('real zone must not depend on IANA pins')):
            first = engine.execute('原创', 'sysdata')
            current = self.store.cur('原创')
            self.assertFalse(first['skipped'])
            self.assertEqual((current / '.stage_sysdata').read_bytes(), b'real\n')
            self.assertFalse((current / '.stage_sysdata.deps').exists())
            self.assertEqual((current / 'systemdata/010000000000080E/original').read_bytes(), b'original timezone')
            for sid in ('0100000000000802', '0100000000000823'):
                self.assertTrue((current / 'systemdata' / sid).is_dir())
                self.assertTrue((current / 'systemdata' / (sid + '.synth')).is_file())
            self.assertTrue(engine.execute('原创', 'sysdata')['skipped'])
            (fonts / 'original.bfttf').write_bytes(b'changed original fixture')
            self.assertFalse(engine.execute('原创', 'sysdata')['skipped'])
            self.assertEqual((self.store.cur('原创') / 'systemdata/fonts/original.bfttf').read_bytes(), b'changed original fixture')
        self.assertEqual((zone / 'original').read_bytes(), b'original timezone')

    def test_missing_sysdata_input_is_75_and_does_not_commit(self):
        before = refresh.seed(self.store, '原创', self.source)
        with patch.object(stages.Stages, '_tz_bundle', side_effect=stages.StageError('original missing input', 75)):
            with self.assertRaises(stages.StageError) as error:
                stages.Stages(self.store).execute('原创', 'sysdata')
        self.assertEqual(error.exception.code, 75)
        self.assertEqual(self.store.cur('原创'), before)
        self.assertFalse(list(self.store.path.glob('*.tmp')))

    def test_timezone_bundle_checks_exact_tree_digest_and_never_builds(self):
        bundle = self.home / 'tz/output'
        bundle.mkdir(parents=True)
        (bundle / 'original').write_bytes(b'original timezone bytes')
        rows = [{'path': 'original', 'size': 23,
                 'sha256': hashlib.sha256(b'original timezone bytes').hexdigest()}]
        expected = hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        repo = self.home / 'empty-repo'
        with patch.object(stages, 'REPO', repo), patch.dict(os.environ, {'S2A_TZDATA_CACHE': str(bundle.parent)}):
            self.assertEqual(stages.Stages._tz_bundle({'TZ_OUTPUT_SHA256': expected}), bundle)
            (bundle / 'original').write_bytes(b'changed timezone bytes!')
            with self.assertRaises(stages.StageError) as error:
                stages.Stages._tz_bundle({'TZ_OUTPUT_SHA256': expected})
        self.assertEqual(error.exception.code, 1)

    def test_font_generator_cannot_download_missing_input(self):
        repo = self.home / 'font-repo'
        gen = repo / 'pack/fonts/make_open_fonts.py'
        gen.parent.mkdir(parents=True)
        # The child must replace urlopen before this original controlled script
        # reaches it. A file URL would otherwise succeed without networking.
        original = self.home / 'offline.txt'
        original.write_bytes(b'original local input')
        gen.write_text('import urllib.request\nurllib.request.urlopen(' + repr(original.as_uri()) + ')\n', encoding='utf-8')
        with patch.object(stages, 'REPO', repo):
            with self.assertRaises(stages.StageError) as error:
                stages.Stages._fonts()
        self.assertEqual(error.exception.code, 75)
        self.assertFalse((self.home / 'openfonts').exists())

    def _layout_cache(self):
        generator = stages.REPO / 'graphics/widen/scan/ui_lyt.py'
        files = ('graphics/widen/scan/ui_lyt.py', 'graphics/widen/scan/yaz0enc.c',
                 'graphics/nvn/tools/romfs_list.py', 'graphics/tools/nxfmt.py', 'graphics/tools/yaz0dec.c')
        tv = hashlib.sha256(b''.join((stages.REPO / p).read_bytes() for p in files)).hexdigest()[:12]
        overlay = self.home / 'overlays' / ('原创_' + bytes(16).hex()) / ('ui_w2346_' + tv + '_' + stages.layout_source_identity(self.source / 'romfs'))
        (overlay / 'romfs/Layout').mkdir(parents=True)
        return overlay, tv

    def test_layout_ignores_seed_source_of_another_game(self):
        # v0.3.0 Windows 玩家实报：seed.txt 记的解包目录指到了别的款（unpack.tsv 程序号不同、里面有同名布局文件）。期望：不拿它当原版，
        #   改用现行产物根的 romfs（本款原版）——用的覆盖缓存按本款原版的身份找到、覆盖层是本款的；打一行黄字说明
        (self.source / 'unpack.tsv').write_text('title_id\t0100AAAA00000000\n', encoding='utf-8')
        (self.source / 'romfs/Layout').mkdir(); (self.source / 'romfs/Layout/one').write_bytes(b'ours one')
        refresh.seed(self.store, '原创', self.source)
        other = self.home / 'other-game-extract'; (other / 'romfs/Layout').mkdir(parents=True)
        (other / 'romfs/Layout/one').write_bytes(b'THEIRS one!'); (other / 'unpack.tsv').write_text('title_id\t01007EF00011E000\n', encoding='utf-8')
        tx = self.store.begin('原创', self.store.tag('原创', 'wrong-seed'))
        roots.text(tx.path / 'seed.txt', f'src={other}\n'); tx.commit()
        current = self.store.cur('原创')
        generator = stages.REPO / 'graphics/widen/scan/ui_lyt.py'
        files = ('graphics/widen/scan/ui_lyt.py', 'graphics/widen/scan/yaz0enc.c',
                 'graphics/nvn/tools/romfs_list.py', 'graphics/tools/nxfmt.py', 'graphics/tools/yaz0dec.c')
        tv = hashlib.sha256(b''.join((stages.REPO / q).read_bytes() for q in files)).hexdigest()[:12]
        overlay = self.home / 'overlays' / ('原创_' + bytes(16).hex()) / ('ui_w2346_' + tv + '_' + stages.layout_source_identity(current / 'romfs'))
        (overlay / 'romfs/Layout').mkdir(parents=True); (overlay / 'romfs/Layout/one').write_bytes(b'widen ours')
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            stages.Stages(self.store).execute('原创', 'uilayout')
        current = self.store.cur('原创')
        self.assertEqual((current / 'ui_overlay/romfs/Layout/one').read_bytes(), b'widen ours')
        self.assertEqual((current / 'romfs/Layout/one').read_bytes(), b'ours one')
        self.assertIn('是另一款 01007EF00011E000 的', err.getvalue())

    def test_layout_exact_key_restore_index_invalidation_and_original_unchanged(self):
        layout = self.source / 'romfs/Layout'
        layout.mkdir()
        (layout / 'one').write_bytes(b'original one')
        (layout / 'two').write_bytes(b'original two')
        refresh.seed(self.store, '原创', self.source)
        overlay, tv = self._layout_cache()
        (overlay / 'romfs/Layout/one').write_bytes(b'widen one')
        (overlay / 'romfs/Layout/two').write_bytes(b'widen two')
        tx = self.store.begin('原创', self.store.tag('原创', 'old-index'))
        roots.text(tx.path / '.stage_romfsidx', 'old\n')
        (tx.path / 'romfs.s2aidx').write_bytes(b'old index')
        tx.commit()
        rows = ''.join(hashlib.sha256(raw).hexdigest() + '  Layout/' + name + '\n'
                       for name, raw in [('one', b'widen one'), ('two', b'widen two')])
        oh = hashlib.sha256(rows.encode()).hexdigest()[:16]
        expected = hashlib.sha256(('w2346 ' + tv + ' ' + oh).encode()).hexdigest()[:16]
        engine = stages.Stages(self.store)
        result = engine.execute('原创', 'uilayout')
        self.assertEqual(result['key'], expected)
        current = self.store.cur('原创')
        self.assertEqual((current / 'ui_overlay.tsv').read_bytes(), b'Layout/one\nLayout/two\n')
        # 覆盖层（11-06）：RomFS 仍联到存储里那份不可变的原版身份，改动只在 ui_overlay/romfs/；读方覆盖层优先
        self.assertEqual((current / 'ui_overlay/romfs/Layout/one').read_bytes(), b'widen one')
        self.assertEqual((current / 'romfs/Layout/one').read_bytes(), b'original one')
        self.assertTrue(roots.is_link(current / 'romfs'))
        self.assertEqual(stages.overlay_sizes(current), {'Layout/one': 9, 'Layout/two': 9})
        self.assertFalse((current / 'romfs.s2aidx').exists())
        self.assertFalse((current / '.stage_romfsidx').exists())
        self.assertFalse((current / '.stage_uilayout.deps').exists())
        self.assertTrue(engine.execute('原创', 'uilayout')['skipped'])
        (overlay / 'romfs/Layout/two').unlink()
        self.assertFalse(engine.execute('原创', 'uilayout')['skipped'])
        current = self.store.cur('原创')
        self.assertFalse((current / 'ui_overlay/romfs/Layout/two').exists())   # 不再覆盖 → 读到底下原版
        self.assertEqual((current / 'romfs/Layout/two').read_bytes(), b'original two')
        self.assertEqual((current / 'ui_overlay.tsv').read_bytes(), b'Layout/one\n')
        self.assertEqual((layout / 'one').read_bytes(), b'original one')
        self.assertEqual((layout / 'two').read_bytes(), b'original two')
        # 审计 #1534 P1-54：原版换了（同大小、修改时间变）、构建号与工具都没变 → 不再用上一份覆盖包（目录名带原版身份），去重新生成
        (layout / 'one').write_bytes(b'ORIGINAL one')
        os.utime(layout / 'one', ns=(1_700_000_000_000_000_000, 1_700_000_000_000_000_000))
        with patch.object(stages.Stages, '_layout_tools', side_effect=stages.StageError('regenerate', 75)):
            with self.assertRaises(stages.StageError) as error:
                engine.execute('原创', 'uilayout')
        self.assertEqual(str(error.exception), 'regenerate')

    def test_layout_legacy_in_place_root_restores_original_into_overlay(self):   # 11-06 覆盖层：旧格式版本（就地改过 RomFS）不再覆盖的文件，原版放进覆盖层
        layout = self.source / 'romfs/Layout'
        layout.mkdir()
        (layout / 'one').write_bytes(b'original one')
        (layout / 'two').write_bytes(b'original two')
        refresh.seed(self.store, '原创', self.source)
        tx = self.store.begin('原创', self.store.tag('原创', 'legacy-ui'), own_romfs=True)   # 旧写法：独占 RomFS、就地改
        (tx.path / 'romfs/Layout/two').unlink(); (tx.path / 'romfs/Layout/two').write_bytes(b'legacy widened two')
        roots.text(tx.path / 'ui_overlay.tsv', 'Layout/two\n')
        tx.commit()
        overlay, _ = self._layout_cache()
        (overlay / 'romfs/Layout/one').write_bytes(b'widen one')
        stages.Stages(self.store).execute('原创', 'uilayout')
        current = self.store.cur('原创')
        self.assertEqual((current / 'ui_overlay/romfs/Layout/one').read_bytes(), b'widen one')
        self.assertEqual((current / 'ui_overlay/romfs/Layout/two').read_bytes(), b'original two')   # 底下仍是旧格式改过的那份 → 覆盖层放原版
        self.assertEqual((current / 'ui_overlay.tsv').read_bytes(), b'Layout/one\nLayout/two\n')

    def test_seed_move_romfs_relinks_source_and_reseeds(self):   # 11-06：本单自己的解包目录，播种整目录搬 RomFS、原处联到存储身份
        (self.source / 'romfs/Layout').mkdir()
        (self.source / 'romfs/Layout/a').write_bytes(b'aaa')
        (self.source / 'romfs/b').write_bytes(b'bb')
        current = refresh.seed(self.store, '原创', self.source, move_romfs=True)
        identity = self.store._romfs(current, '原创')
        self.assertTrue(roots.is_link(self.source / 'romfs'))
        self.assertEqual((self.source / 'romfs').resolve(), identity.resolve())
        self.assertEqual((self.source / 'romfs/Layout/a').read_bytes(), b'aaa')
        self.assertEqual((current / 'romfs/b').read_bytes(), b'bb')
        # 布局阶段照旧从 seed.txt 记的 src/romfs 读原版
        self.assertIn(f'src={self.source.resolve()}', roots.read(current / 'seed.txt'))
        # 下一单：解包前只删联接（不进去删存储），重解后再播，照常成功
        roots.remove_owned(self.source / 'romfs')
        self.assertTrue(identity.is_dir() and (identity / 'b').read_bytes() == b'bb')
        (self.source / 'romfs').mkdir(); (self.source / 'romfs/b').write_bytes(b'b2')
        again = refresh.seed(self.store, '原创', self.source, move_romfs=True)
        self.assertEqual((again / 'romfs/b').read_bytes(), b'b2')
        self.assertTrue(roots.is_link(self.source / 'romfs'))

    def test_seed_without_move_keeps_source_real_dir(self):
        (self.source / 'romfs/b').write_bytes(b'bb')
        current = refresh.seed(self.store, '原创', self.source)
        self.assertFalse(roots.is_link(self.source / 'romfs'))
        self.assertEqual((self.source / 'romfs/b').read_bytes(), b'bb')
        self.assertEqual((current / 'romfs/b').read_bytes(), b'bb')

    def test_layout_rejects_persisted_traversal_before_transaction(self):
        refresh.seed(self.store, '原创', self.source)
        tx = self.store.begin('原创', self.store.tag('原创', 'unsafe-list'))
        roots.text(tx.path / 'ui_overlay.tsv', '../outside\n')
        before = tx.commit()
        with self.assertRaises(stages.StageError):
            stages.Stages(self.store).execute('原创', 'uilayout')
        self.assertEqual(self.store.cur('原创'), before)

    def test_layout_missing_native_tools_keeps_current_and_no_cache(self):
        (self.source / 'romfs/Layout').mkdir()
        before = refresh.seed(self.store, '原创', self.source)
        with patch.object(stages.shutil, 'which', return_value=None):
            with self.assertRaises(stages.StageError) as error:
                stages.Stages(self.store).execute('原创', 'uilayout')
        self.assertEqual(error.exception.code, 75)
        self.assertEqual(self.store.cur('原创'), before)
        self.assertFalse(list((self.home / 'overlays').rglob('gen.log')))

    def _layout_generator_fixture(self, message='', code=0):
        """Original executable boundary; no compiler or real archive bytes."""
        repo = self.home / 'layout-repo'
        files = ('graphics/widen/scan/ui_lyt.py', 'graphics/widen/scan/yaz0enc.c',
                 'graphics/nvn/tools/romfs_list.py', 'graphics/tools/nxfmt.py', 'graphics/tools/yaz0dec.c')
        for name in files:
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# original module\n' if name.endswith('.py') else '/* original C */\n',
                            encoding='utf-8', newline='\n')
        counter = self.home / 'layout-invocations.txt'
        script = ("from pathlib import Path\nimport sys\n"
                  "here=Path(__file__).resolve()\n"
                  "sys.path.insert(0,str(here.parents[2]/'tools'))\n"
                  "sys.path.insert(0,str(here.parents[2]/'nvn/tools'))\n"
                  "import nxfmt, romfs_list\n"
                  "counter=Path(" + repr(str(counter)) + ")\n"
                  "with counter.open('a',encoding='utf-8') as f: f.write('called\\n')\n"
                  "out=Path(sys.argv[2])/'Layout/one'\nout.parent.mkdir(parents=True)\n"
                  "out.write_bytes(b'original widened boundary')\n"
                  "print(" + repr(message) + ")\nraise SystemExit(" + str(code) + ")\n")
        (repo / files[0]).write_text(script, encoding='utf-8', newline='\n')
        layout = self.source / 'romfs/Layout'
        layout.mkdir(exist_ok=True)
        (layout / 'one').write_bytes(b'original layout input')
        return repo, files, counter

    def test_layout_imports_and_native_decoder_change_both_cache_and_stage_keys(self):
        repo, files, counter = self._layout_generator_fixture()
        refresh.seed(self.store, '原创', self.source)
        with patch.object(stages, 'REPO', repo), patch.object(stages.Stages, '_layout_tools',
                return_value=dict(os.environ, PYTHONDONTWRITEBYTECODE='1')):
            engine = stages.Stages(self.store)
            previous = None
            for index, changed in enumerate((None, *files[2:])):
                with self.subTest(changed=changed):
                    if changed:
                        with (repo / changed).open('a', encoding='utf-8', newline='\n') as f:
                            f.write('# changed input\n' if changed.endswith('.py') else '/* changed input */\n')
                    result = engine.execute('原创', 'uilayout')
                    tv = hashlib.sha256(b''.join((repo / p).read_bytes() for p in files)).hexdigest()[:12]
                    expected_cache = self.home / 'overlays' / ('原创_' + bytes(16).hex()) / ('ui_w2346_' + tv + '_' + stages.layout_source_identity(self.source / 'romfs'))
                    self.assertTrue(expected_cache.is_dir(), 'each imported module/native decoder belongs to cache identity')
                    rows = hashlib.sha256(b'original widened boundary').hexdigest() + '  Layout/one\n'
                    oh = hashlib.sha256(rows.encode()).hexdigest()[:16]
                    expected_key = hashlib.sha256(('w2346 ' + tv + ' ' + oh).encode()).hexdigest()[:16]
                    self.assertFalse(result['skipped'])
                    self.assertEqual(result['key'], expected_key)
                    self.assertNotEqual(result['key'], previous)
                    previous = result['key']
                    self.assertEqual(counter.read_text().splitlines(), ['called'] * (index + 1))
                    self.assertTrue(engine.execute('原创', 'uilayout')['skipped'])

    def test_layout_python_failures_do_not_publish_or_commit_and_retry(self):
        messages = (
            "  【红】Layout/bad：AttributeError module 'os' has no attribute 'uname'",
            'Traceback (most recent call last):\n  File "original.py", line 1\nRuntimeError: original failure',
            'ModuleNotFoundError: original dependency missing',
            'original tool crashed without a content diagnostic',
        )
        for message in messages:
            with self.subTest(message=message):
                repo, _, counter = self._layout_generator_fixture(message, 1)
                game = '失败' + str(messages.index(message))
                before = refresh.seed(self.store, game, self.source)
                before_calls = len(counter.read_text().splitlines()) if counter.exists() else 0
                with patch.object(stages, 'REPO', repo), patch.object(stages.Stages, '_layout_tools',
                        return_value=dict(os.environ, PYTHONDONTWRITEBYTECODE='1')):
                    engine = stages.Stages(self.store)
                    for attempt in range(2):
                        with self.assertRaises(stages.StageError) as error:
                            engine.execute(game, 'uilayout')
                        self.assertEqual(error.exception.code, 75)
                        self.assertEqual(self.store.cur(game), before)
                        self.assertFalse(list((self.home / 'overlays' / (game + '_' + bytes(16).hex())).glob('ui_w*')))
                        self.assertFalse((before / '.stage_uilayout').exists())
                        self.assertEqual(len(counter.read_text().splitlines()), before_calls + attempt + 1)

    def test_layout_explicit_content_partial_is_published_and_reused(self):
        message = ('  【红】Layout/bad：内容缺口：原创新格式不支持\n'
                   '界面布局：包 2 个，报错 1（屏幕宽 2346）')
        repo, _, counter = self._layout_generator_fixture(message, 1)
        refresh.seed(self.store, '原创', self.source)
        with patch.object(stages, 'REPO', repo), patch.object(stages.Stages, '_layout_tools',
                return_value=dict(os.environ, PYTHONDONTWRITEBYTECODE='1')):
            engine = stages.Stages(self.store)
            result = engine.execute('原创', 'uilayout')
            self.assertFalse(result['skipped'])
            current = self.store.cur('原创')
            self.assertEqual((current / 'ui_overlay/romfs/Layout/one').read_bytes(), b'original widened boundary')
            self.assertTrue(engine.execute('原创', 'uilayout')['skipped'])
            self.assertEqual(counter.read_text().splitlines(), ['called'])

    def _container_fixture(self):
        pid = '0100000000001000'
        (self.source / 'unpack.tsv').write_text('title_id\t' + pid + '\n', encoding='utf-8')
        container = self.sources / 'original.nsz'
        container.write_bytes(b'ORIGINAL CONTAINER BOUNDARY')
        tool = self.home / 'nx_unpack.exe'
        tool.write_bytes(b'ORIGINAL EXECUTION BOUNDARY')
        return pid, container, tool

    def test_nacp_only_missing_invokes_and_never_writes_stamp(self):
        pid, container, tool = self._container_fixture()
        refresh.seed(self.store, '原创', self.source)
        actual = stages.run
        calls = []
        def core(args, **kwargs):
            if Path(args[0]) != tool:
                return actual(args, **kwargs)
            calls.append(args)
            output = Path(args[2])
            (output / 'ctl').mkdir(exist_ok=True)
            (output / 'ctl/control.nacp').write_bytes(b'original nacp bytes')
            roots.text(output / 'unpack.tsv', 'title_id\t' + pid + '\n')
            Path(kwargs['log']).write_bytes(b'original nx boundary\n')
            return '', 0
        engine = stages.Stages(self.store)
        with patch.object(engine, '_nxu', return_value=tool), patch.object(stages, 'run', core):
            self.assertFalse(engine.execute('原创', 'nacp')['skipped'])
            before = len(calls)
            self.assertTrue(engine.execute('原创', 'nacp')['skipped'])
            self.assertEqual(len(calls), before)
        current = self.store.cur('原创')
        self.assertEqual((current / 'ctl/control.nacp').read_bytes(), b'original nacp bytes')
        self.assertFalse((current / '.stage_nacp').exists())
        self.assertFalse((current / '.stage_nacp.deps').exists())
        self.assertEqual(container.read_bytes(), b'ORIGINAL CONTAINER BOUNDARY')

    def test_nacp_zero_without_output_is_failure_and_aborts(self):
        pid, container, tool = self._container_fixture()
        before = refresh.seed(self.store, '原创', self.source)
        engine = stages.Stages(self.store)
        st = container.stat()
        rows = [[str(container), str(st.st_size), str(int(st.st_mtime)), pid]]
        with patch.object(engine, '_nxu', return_value=tool), patch.object(engine, '_source_rows', return_value=rows), patch.object(stages, 'run', return_value=('', 0)):
            with self.assertRaises(stages.StageError) as error:
                engine.execute('原创', 'nacp')
        self.assertEqual(error.exception.code, 1)
        self.assertEqual(self.store.cur('原创'), before)

    def test_source_probe_failure_is_not_cached_as_identified(self):
        pid, container, tool = self._container_fixture()
        engine = stages.Stages(self.store)
        work = self.home / 'probe'
        work.mkdir()
        def failed(args, **kwargs):
            roots.text(Path(args[2]) / 'unpack.tsv', 'title_id\t' + pid + '\n')
            return '', 3
        with patch.object(stages, 'run', failed):
            rows = engine._source_rows(tool, work, dict(os.environ))
        self.assertEqual(len(rows), 1)
        self.assertFalse((self.home / 'source-ids.tsv').exists())

    def test_multi_base_container_gets_one_row_per_program_and_title_id_downstream(self):
        # 11-05 census #26: one cartridge holds the game plus an art-book app. Without
        # --title-id, --nacp-only answers "exactly 1 base expected, got 2" (exit 1);
        # src_ids must list both ids via --inspect, and nacp/aoc must pass the id down.
        pid, container, tool = self._container_fixture()
        other = '0100000000002000'
        refresh.seed(self.store, '原创', self.source)
        actual = stages.run
        calls = []
        def core(args, **kwargs):
            if Path(args[0]) != tool:
                return actual(args, **kwargs)
            args = [str(a) for a in args]
            calls.append(args)
            if '--inspect' in args:
                return json.dumps({'schema': 1, 'packages': [{'titleId': t, 'type': 'base'} for t in (other, pid)]}), 0
            titles = [a for a in args if a.startswith('--title-id=')]
            if not titles:
                Path(kwargs['log']).write_text('🔴 基础程序应恰好 1 个（按程序号），实际 2\n', encoding='utf-8')
                return '', 1
            output = Path(args[2])
            Path(kwargs['log']).write_bytes(b'ok\n')
            if '--nacp-only' in args:
                (output / 'ctl').mkdir(exist_ok=True)
                (output / 'ctl/control.nacp').write_bytes(b'nacp')
            else:
                roots.text(output / 'aoc.tsv', 'idx\ttitle_id\tversion\tfiles\tbytes\n')
            return '', 0
        engine = stages.Stages(self.store)
        work = self.home / 'probe'
        work.mkdir()
        with patch.object(stages, 'run', core):
            rows = engine._source_rows(tool, work, dict(os.environ))
            self.assertEqual([row[3] for row in rows], [pid, other])
            self.assertEqual({row[0] for row in rows}, {str(container)})
            before = len(calls)
            self.assertEqual(engine._source_rows(tool, work, dict(os.environ)), rows)
            self.assertEqual(len(calls), before)
        cached = (self.home / 'source-ids.tsv').read_text(encoding='utf-8').splitlines()
        self.assertEqual(sorted(line.split('\t')[3] for line in cached), sorted([pid, other]))
        calls.clear()
        with patch.object(engine, '_nxu', return_value=tool), patch.object(stages, 'run', core):
            engine.execute('原创', 'nacp')
            engine.execute('原创', 'aoc')
        work_calls = [c for c in calls if '--nacp-only' in c or '--aoc-only' in c]
        self.assertEqual(len(work_calls), 2)
        for call in work_calls:
            self.assertIn('--title-id=' + pid, call)
            self.assertIn(str(container), call)

    def test_aoc_exact_host_key_replacement_same_size_and_mtime_invalidates(self):
        pid, container, tool = self._container_fixture()
        current = refresh.seed(self.store, '原创', self.source)
        dll = tool.with_suffix('.dll')
        dll.write_bytes(b'original dll')
        st = container.stat()
        rows = [[str(container), str(st.st_size), str(int(st.st_mtime)), pid]]
        raw = '\t'.join(rows[0]) + '\n'
        raw += f'{st.st_size} {st.st_mtime_ns} {st.st_ctime_ns} {st.st_ino}\n'
        raw += hashlib.sha256(b'original dll').hexdigest() + '  -\n'
        raw += hashlib.sha256(b'ORIGINAL EXECUTION BOUNDARY').hexdigest() + '  -\n'
        raw += bytes(16).hex() + '\n'
        expected = hashlib.sha256(raw.encode()).hexdigest()[:16]
        self.assertEqual(stages.Stages._aoc_base(current, rows, tool), expected)
        replacement = self.sources / 'replacement'
        replacement.write_bytes(b'X' * st.st_size)
        os.utime(replacement, ns=(st.st_atime_ns, st.st_mtime_ns))
        os.replace(replacement, container)
        self.assertEqual(container.stat().st_size, st.st_size)
        self.assertEqual(container.stat().st_mtime_ns, st.st_mtime_ns)
        self.assertNotEqual(stages.Stages._aoc_base(current, rows, tool), expected)

    def test_aoc_real_transaction_cache_skip_and_host_change(self):
        pid, container, tool = self._container_fixture()
        refresh.seed(self.store, '原创', self.source)
        actual = stages.run
        extracted = []
        def core(args, **kwargs):
            if Path(args[0]) != tool:
                return actual(args, **kwargs)
            output = Path(args[2])
            Path(kwargs['log']).write_bytes(b'original nx boundary\n')
            if '--nacp-only' in args:
                roots.text(output / 'unpack.tsv', 'title_id\t' + pid + '\n')
            else:
                self.assertNotIn('S2A_HDD_READ', kwargs['env'])
                extracted.append(output)
                (output / 'aoc/2').mkdir(parents=True)
                (output / 'aoc/2/original').write_bytes(b'ORIGINAL DLC')
                roots.text(output / 'aoc.tsv', 'idx\ttitle_id\tversion\tfiles\tbytes\n2\t0100000000002002\t0\t1\t12\n')
            return '', 0
        engine = stages.Stages(self.store)
        with patch.object(engine, '_nxu', return_value=tool), patch.object(stages, 'run', core), patch.dict(os.environ, {'S2A_HDD_READ': '1'}):
            self.assertFalse(engine.execute('原创', 'aoc')['skipped'])
            self.assertTrue(engine.execute('原创', 'aoc')['skipped'])
            self.assertEqual(len(extracted), 1)
            container.write_bytes(b'CHANGED ORIGINAL CONTAINER')
            self.assertFalse(engine.execute('原创', 'aoc')['skipped'])
            self.assertEqual(len(extracted), 2)
        current = self.store.cur('原创')
        self.assertEqual((current / 'aoc/2/original').read_bytes(), b'ORIGINAL DLC')
        self.assertTrue((current / '.stage_aoc.deps').is_file())

    def test_aoc_failed_extraction_keeps_old_data_and_reports_missing(self):
        pid, container, tool = self._container_fixture()
        refresh.seed(self.store, '原创', self.source)
        tx = self.store.begin('原创', self.store.tag('原创', 'old-aoc'))
        (tx.path / 'aoc/7').mkdir(parents=True)
        (tx.path / 'aoc/7/original').write_bytes(b'KEEP OLD DLC')
        roots.text(tx.path / 'aoc.tsv', 'idx\ttitle_id\tversion\tfiles\tbytes\n7\t0100000000002007\t0\t1\t12\n')
        roots.text(tx.path / '.stage_aoc', 'old\n')
        tx.commit()
        actual = stages.run
        def core(args, **kwargs):
            if Path(args[0]) != tool:
                return actual(args, **kwargs)
            output = Path(args[2])
            Path(kwargs['log']).write_bytes(b'original content gap\n')
            if '--nacp-only' in args:
                roots.text(output / 'unpack.tsv', 'title_id\t' + pid + '\n')
                return '', 0
            return '', 3
        engine = stages.Stages(self.store)
        with patch.object(engine, '_nxu', return_value=tool), patch.object(stages, 'run', core):
            self.assertFalse(engine.execute('原创', 'aoc')['skipped'])
            current = self.store.cur('原创')
            self.assertEqual((current / 'aoc/7/original').read_bytes(), b'KEEP OLD DLC')
            self.assertEqual((current / '.stage_aoc').read_bytes(), b'old\n')
            self.assertIn('追加内容缺\toriginal.nsz\toriginal content gap\n', (current / 'aoc.log').read_text(encoding='utf-8'))
            self.assertTrue(engine.execute('原创', 'aoc')['skipped'])
        self.assertFalse(list((self.home / 'aoc-cache').glob('原创-*')))

    def test_aoc_individual_fallback_preserves_good_dlc_and_names_bad_dlc(self):
        pid, container, tool = self._container_fixture()
        good, bad = self.sources / 'good.nsp', self.sources / 'bad.nsp'
        good.write_bytes(b'original good fixture')
        bad.write_bytes(b'original bad fixture')
        current = refresh.seed(self.store, '原创', self.source)
        rows = [[str(p), str(p.stat().st_size), '1', identity]
                for p, identity in ((container, pid), (good, '-'), (bad, '-'))]
        output = self.home / 'aoc-output'
        output.mkdir()
        actual = stages.run
        def core(args, **kwargs):
            if Path(args[0]) != tool:
                return actual(args, **kwargs)
            if '--inspect' in args:
                return '{"schema":1,"packages":[{"type":"dlc"}]}', 0
            part = Path(args[2])
            Path(kwargs['log']).write_bytes(b'original bad content\n')
            self.assertIn('--title-id=' + pid, args)
            if len(args) == 7 and str(args[-1]) == str(good):
                (part / 'aoc/2').mkdir(parents=True)
                (part / 'aoc/2/original').write_bytes(b'GOOD')
                roots.text(part / 'aoc.tsv', 'idx\ttitle_id\tversion\tfiles\tbytes\n2\t0100000000002002\t0\t1\t4\n')
                return '', 0
            return '', 3
        class Records:
            env = dict(os.environ)
        with patch.object(stages, 'run', core):
            missing, keep = stages.Stages(self.store)._aoc_extract(tool, current, rows, output, Records())
        self.assertFalse(keep)
        self.assertEqual(missing, [('bad.nsp', 'original bad content')])
        self.assertEqual((output / 'aoc/2/original').read_bytes(), b'GOOD')
        self.assertEqual((output / 'aoc.tsv').read_bytes(), b'idx\ttitle_id\tversion\tfiles\tbytes\n2\t0100000000002002\t0\t1\t4\n')
        self.assertIn(b'bad.nsp', (output / 'aoc.log').read_bytes())
        self.assertFalse((output / 'exefs').exists())


class WindowsBashTest(unittest.TestCase):
    """#26：PATH 第一个 bash 是 WSL 存根。手算期望：存根不选；存根的 UTF-16 输出（非 0 退出 / 带 \\x00）不能进配置值"""

    def test_stub_is_rejected_and_real_bash_preferred(self):
        from pack.orch import bash as B
        stub = r'C:\Windows\System32\bash.exe'
        git = r'C:\Program Files\Git\bin\bash.exe'
        ship = r'C:\S2Arm\Runtime\git\usr\bin\bash.exe'
        self.assertTrue(B.is_wsl_stub(stub))
        self.assertFalse(B.is_wsl_stub(git))
        with mock.patch.object(B.shutil, 'which', return_value=stub), mock.patch.object(B.os.path, 'isfile', return_value=True):
            self.assertEqual(B.find_bash({'S2A_BASH': ship}, nt=True), ship)     # 随包 bash 最优先
            self.assertEqual(B.find_bash({}, nt=True), git)                      # 没有随包的用 Git Bash
        with mock.patch.object(B.shutil, 'which', return_value=stub), mock.patch.object(B.os.path, 'isfile', side_effect=lambda p: p == stub):
            self.assertIsNone(B.find_bash({}, nt=True))                          # 只有存根 = 没有 bash

    def test_machine_cfg_ignores_stub_output(self):
        from pack.orch import stages as S
        stub_out = '\x00'.join('The attempted operation')
        for rc, out in ((1, stub_out), (0, stub_out)):
            with mock.patch.object(S, 'find_bash', return_value='bash'), \
                 mock.patch.object(S.subprocess, 'run', return_value=mock.Mock(returncode=rc, stdout=out)):
                self.assertEqual(S.machine_cfg({}, 'S2A_COMMUNITY_DIR'), '')
        with mock.patch.object(S, 'find_bash', return_value='bash'), \
             mock.patch.object(S.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout='/data\n')):
            self.assertEqual(S.machine_cfg({}, 'S2A_COMMUNITY_DIR'), '/data')    # 正常值原样返回


if __name__ == '__main__':
    unittest.main()
