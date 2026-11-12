# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Long-batch activity is observed outside the watched build process tree."""
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch
from jobcase import JobCase, ROOT
from core import Cancelled, Failure
from progress_activity import BatchActivity as Activity


class BatchActivity(JobCase):
    stage = '直连库·编批库（MB）'

    def meta(self, **changes):
        data = dict(schema=1, pid=123, stage=self.stage, target=5, pool=10, state='active')
        return '#dsh_activity\t' + json.dumps(data | changes, ensure_ascii=False) + '\n'

    def begin_activity(self):
        self.c._batch_activity = Activity(tree=lambda pid: {pid:(0, 'dsh_batch'), 124:(0, 'metal'), 125:(0, 'metallib'), 126:(0, 'metal.exe')})
        p = self.root / 'progress.tsv'
        p.write_text(f'100\t{self.stage}\t0\t100\n105\t{self.stage}\t20\t100\n' + self.meta(), encoding='utf-8')
        with patch('core.time.monotonic', return_value=105), patch('core.time.time', return_value=105), patch.object(self.c, 'emit') as emit:
            pos = self.c.stage_progress(p, 0)
        return p, pos, emit

    def test_real_progress_reports_target_pool_and_sampled_compilers(self):
        _, _, emit = self.begin_activity()
        event = emit.call_args.kwargs
        self.assertEqual(event.get('activity'), dict(stage=self.stage, pid=123, target=5, pool=10, inFlight=3))
        self.assertEqual((event['done'], event['total']), (20, 100))
        self.assertTrue(event['message'].startswith(self.stage))

    def test_crlf_progress_lines_still_count(self):
        """Windows 文本模式写出的 CRLF 进度行照样发进度（v0.3.1 热修实测：写单一 IMG 24 行进度一条没发出去）"""
        p = self.root / 'progress.tsv'
        p.write_bytes('100\t写单一 IMG\t0\t4000\r\n101\t写单一 IMG\t1000\t4000\r\n'.encode('utf-8'))
        with patch('core.time.monotonic', return_value=105), patch('core.time.time', return_value=105), patch.object(self.c, 'emit') as emit:
            self.c.stage_progress(p, 0)
        self.assertEqual(emit.call_count, 1)
        self.assertEqual((emit.call_args.kwargs['done'], emit.call_args.kwargs['total']), (1000, 4000))

    def test_long_batch_pulse_preserves_done_weights_and_progress_file(self):
        p, pos, _ = self.begin_activity()
        before = p.read_bytes()
        with patch('core.time.monotonic', return_value=115), patch('core.time.time', return_value=115), patch.object(self.c, 'emit') as emit:
            self.assertEqual(self.c.stage_progress(p, pos), pos)
        self.assertEqual(emit.call_count, 1)
        event = emit.call_args.kwargs
        self.assertEqual((event['done'], event['total']), (20, 100))
        self.assertEqual(event['counters'][0]['rate'], 1.333)  # 20 MB / 15 elapsed seconds.
        self.assertEqual(p.read_bytes(), before, 'observer pulse must not write to the watchdog input')

    def test_pulse_is_bounded_and_ended_activity_stops_it(self):
        p, pos, _ = self.begin_activity()
        with patch('core.time.monotonic', return_value=106), patch.object(self.c, 'emit') as emit:
            self.c.stage_progress(p, pos)
        emit.assert_not_called()
        with p.open('a', encoding='utf-8') as f:
            f.write(self.meta(state='ended'))
        with patch('core.time.monotonic', return_value=116), patch.object(self.c, 'emit') as emit:
            pos = self.c.stage_progress(p, pos)
            self.c.stage_progress(p, pos)
        self.assertEqual(emit.call_count, 1)
        self.assertNotIn('activity', emit.call_args.kwargs)
        self.assertEqual(emit.call_args.kwargs['message'], self.stage + ' 20/100')

    def test_other_process_end_does_not_clear_active_owner(self):
        p, pos, _ = self.begin_activity()
        with p.open('a', encoding='utf-8') as f:
            f.write(self.meta(pid=999, state='ended'))
        with patch('core.time.monotonic', return_value=115), patch('core.time.time', return_value=115), patch.object(self.c, 'emit') as emit:
            self.c.stage_progress(p, pos)
        self.assertEqual(emit.call_count, 1)
        self.assertEqual(emit.call_args.kwargs['activity']['pid'], 123)

    def test_malformed_metadata_preserves_legacy_progress(self):
        p = self.root / 'invalid.tsv'
        rows = ['#dsh_activity\t{bad}\n', self.meta(target=True), self.meta(schema=True), self.meta(pool=1)]
        for row in rows:
            with self.subTest(row=row):
                p.write_text(f'100\t{self.stage}\t20\t100\n' + row, encoding='utf-8')
                with patch.object(self.c, 'emit') as emit:
                    self.c.stage_progress(p, 0)
                self.assertEqual((emit.call_args.kwargs['done'], emit.call_args.kwargs['total']), (20, 100))
                self.assertNotIn('activity', emit.call_args.kwargs)

    def test_unavailable_sampling_is_unknown_not_zero_or_ended(self):
        def denied(pid):
            raise PermissionError('synthetic denied enumeration')
        for tree in [denied, lambda pid: {pid: (0, '')}]:
            with self.subTest(tree=tree):
                activity = Activity(tree=tree, alive=lambda pid: True)
                activity.accept(self.meta())
                self.assertIsNone(activity.snapshot()['inFlight'])
                self.assertIsNotNone(activity.data)
                self.assertIn('未知', activity.describe(activity.snapshot()))
        activity = Activity(tree=lambda pid: {pid: (0, 'dsh_batch')})
        activity.accept(self.meta())
        self.assertEqual(activity.snapshot()['inFlight'], 0, 'known live tree without compilers is a measured zero')

    def test_abrupt_owner_exit_clears_display_without_advancing_work(self):
        p, pos, _ = self.begin_activity()
        self.c._batch_activity.tree = lambda pid: {pid: (0, '')}
        self.c._batch_activity.alive = lambda pid: False
        with patch('core.time.monotonic', return_value=115), patch.object(self.c, 'emit') as emit:
            self.c.stage_progress(p, pos)
            self.c.stage_progress(p, pos)
        self.assertIsNone(self.c._batch_activity.data)
        self.assertEqual(emit.call_count, 1)
        self.assertEqual((emit.call_args.kwargs['done'], emit.call_args.kwargs['total']), (20, 100))
        self.assertNotIn('activity', emit.call_args.kwargs)

    def test_cache_only_activity_has_no_invented_denominator(self):
        self.c._batch_activity = Activity(tree=lambda pid: {pid: (0, 'dsh_batch')})
        self.c._counters = {self.stage: dict(name=self.stage, done=20, total=100, t0=100, d0=0, t=105)}
        p = self.root / 'cached.tsv'
        p.write_text(self.meta(), encoding='utf-8')
        with patch.object(self.c, 'emit') as emit:
            pos = self.c.stage_progress(p, 0)
        self.assertIn('activity', emit.call_args.kwargs)
        self.assertNotIn('done', emit.call_args.kwargs)
        self.assertNotIn('total', emit.call_args.kwargs)
        with p.open('a', encoding='utf-8') as f:
            f.write(self.meta(state='ended'))
        with patch.object(self.c, 'emit') as emit:
            self.c.stage_progress(p, pos)
        self.assertEqual(emit.call_args.kwargs, dict(message=self.stage))

    def test_process_sampling_is_bounded_by_the_same_pulse_interval(self):
        with patch('progress_activity.time.monotonic', return_value=100):
            activity = Activity(tree=lambda pid: {pid: (0, 'dsh_batch')})
            activity.accept(self.meta())
        with patch.object(activity, 'tree', wraps=activity.tree) as tree:
            for now in [100, 101, 109, 110]:
                with patch('progress_activity.time.monotonic', return_value=now):
                    activity.snapshot()
            self.assertEqual(tree.call_count, 2)

    def child(self, progress, delay=2.2, code=0, ack=None, need=0):
        """ack / need：握手——子进程写完活动行后不按墙钟睡，等父作业发出 need 次活动脉冲（测试的 emit 每见一次往 ack 文件追加一行）才退出，
        保底 60 秒（父作业真不发脉冲时超时退出、测试照样红）。脉冲数由事件顺序保证，不看机器负载"""
        script = '''import json,os,time,sys
from pathlib import Path
p=Path(os.environ['S2A_PROGRESS']); now=time.time()
p.write_text(f"{now-1}\\t直连库·编批库（MB）\\t0\\t100\\n{now}\\t直连库·编批库（MB）\\t20\\t100\\n",encoding='utf-8')
with p.open('a',encoding='utf-8') as f:
 f.write('#dsh_activity\\t'+json.dumps(dict(schema=1,pid=os.getpid(),stage='直连库·编批库（MB）',target=5,pool=10,state='active'))+'\\n')
ack, need = os.environ.get('S2A_TEST_ACK'), int(sys.argv[3])
if ack:
 end = time.time() + 60
 while time.time() < end and (not os.path.exists(ack) or len(open(ack).read().splitlines()) < need): time.sleep(.05)
else:
 time.sleep(float(sys.argv[1]))
sys.exit(int(sys.argv[2]))
'''
        env = dict(os.environ, S2A_PROGRESS=str(progress))
        if ack:
            env['S2A_TEST_ACK'] = str(ack)
        return [sys.executable, '-c', script, str(delay), str(code), str(need)], env

    def spy(self, ack, on_pulse=None):
        """包住 Context.emit：照常发，见到活动脉冲就往 ack 追加一行（子进程据此推进），并可回调（如取消）"""
        real = self.c.emit
        def emit(*args, **kwargs):
            result = real(*args, **kwargs)
            if 'activity' in kwargs:
                with open(ack, 'a', encoding='utf-8') as f:
                    f.write('pulse\n')
                if on_pulse:
                    on_pulse()
            return result
        return patch.object(self.c, 'emit', side_effect=emit)

    def test_process_success_and_exception_clear_observer_lifetime(self):
        self.c._batch_activity = Activity(interval=.1)
        p = self.root / 'live.tsv'
        for code in [0, 3]:
            with self.subTest(code=code):
                p.unlink(missing_ok=True)
                ack = self.root / f'ack-{code}'
                # 握手：子进程等父作业发出 2 次脉冲才退出（原来子进程睡 2.2 秒、父作业每秒采一次，脉冲数看运气，高负载下 0–1 次）
                command, env = self.child(p, code=code, ack=ack, need=2)
                with self.spy(ack) as emit:
                    if code:
                        with self.assertRaises(Failure):
                            self.c.run(command, env=env, timeout=90)
                    else:
                        self.c.run(command, env=env, timeout=90)
                pulses = [call.kwargs for call in emit.call_args_list if 'activity' in call.kwargs]
                self.assertGreaterEqual(len(pulses), 2)
                self.assertTrue(all((e['done'], e['total']) == (20, 100) for e in pulses))
                self.assertTrue(all(e['activity']['inFlight'] == 0 for e in pulses), 'real live Python child has no Metal descendants')
                self.assertIsNone(self.c._batch_activity.data)
                self.assertFalse(self.c.children)
                with patch.object(self.c, 'emit', wraps=self.c.emit) as emit:
                    self.c.run([sys.executable, '-c', 'import time; time.sleep(1.2)'], env=env, timeout=4)
                self.assertFalse(any('activity' in call.kwargs for call in emit.call_args_list))

    def test_cancellation_clears_observer_and_reaps_child(self):
        self.c._batch_activity = Activity(interval=.1)
        command, env = self.child(self.root / 'cancel.tsv', delay=60)   # 子进程自己不退：只能被取消
        # 见到第一次活动脉冲就取消（原来定时 1.4 秒取消，高负载下可能一次脉冲都还没有）
        try:
            with self.spy(self.root / 'cancel-ack', on_pulse=self.c.stop) as emit:
                with self.assertRaises(Cancelled):
                    self.c.run(command, env=env, timeout=90)
            self.assertTrue(any('activity' in call.kwargs for call in emit.call_args_list))
            self.assertIsNone(self.c._batch_activity.data)
            self.assertFalse(self.c.children)
        finally:
            self.c.cancelled = False

    def test_observer_pulses_do_not_keep_an_idle_child_alive(self):
        self.c._batch_activity = Activity(interval=.1)
        p = self.root / 'idle.tsv'
        command, env = self.child(p, delay=30)
        env['S2A_NOSTALL_POLL'] = '.1'
        watched = [sys.executable, str(ROOT / 'tools/nostall.py'), '--watch', str(p), '2.3', '--', *command]
        with patch.object(self.c, 'emit', wraps=self.c.emit) as emit:
            with self.assertRaises(Failure):
                # 阶段上限 60 秒：只判「看门狗按无进展停掉（124）」，不判多快——子进程睡 30 秒，看门狗真失效时它 30 秒后以 0 正常退出，这里照样红
                #   （原 6 秒：负载 70 时两次起 Python + 2.3 秒无进展判定 + 收进程树要 8 秒多，先撞阶段上限报 stage_timeout，last_rc 还没记）
                self.c.run(watched, env=env, timeout=60)
        self.assertEqual(self.c.last_rc, 124, 'watchdog must detect the idle child despite UI pulses')
        # 有脉冲（这条用例才不空转）而子进程照样被判无进展停掉：脉冲只在父作业里发，不进被盯的进程树 / 文件。
        #   这里不要求两次：看门狗 2.3 秒无进展就停，期间父作业采到几次取决于调度；「脉冲持续发」由上面的握手用例保证
        self.assertGreaterEqual(sum('activity' in call.kwargs for call in emit.call_args_list), 1)
        self.assertIsNone(self.c._batch_activity.data)

    @unittest.skipUnless(os.name == 'posix', 'legacy POSIX progress.sh consumer')
    def test_old_shell_reader_ignores_optional_metadata(self):
        p = self.root / 'legacy.tsv'; plain = self.root / 'plain.tsv'
        text = f'100\t{self.stage}\t0\t100\n105\t{self.stage}\t20\t100\n'
        plain.write_text(text, encoding='utf-8'); p.write_text(text + self.meta(), encoding='utf-8')
        def show(path):
            return subprocess.check_output(['/bin/bash', str(ROOT / 'tools/progress.sh'), 'show', str(path), '115'])
        self.assertEqual(show(p), show(plain))


if __name__ == '__main__':
    unittest.main()
