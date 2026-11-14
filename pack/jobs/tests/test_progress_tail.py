# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""子进程退出前写进 S2A_PROGRESS 的最后几行，父作业收完进程后要补读一次再结束：写到几就要收到几。

原先父作业只在子进程活着时每秒读一次进度，子进程写完最后几行马上退出，循环一结束就不再读，
界面停在退出前一秒的读数（期望值手算：子进程写 1..N 共 N 行、总数 N，最后一条进度必须是 N/N）。"""
import sys
import unittest
from unittest.mock import patch
from jobcase import JobCase
from core import Failure
from progress_activity import BatchActivity as Activity

N = 50
STAGE = '编库'


class ProgressTail(JobCase):
    def child(self, progress, code=0):
        # 一口气写完 N 行就退出，不睡：父作业活着时那几次读一行都赶不上
        script = f'''import os,sys,time
p=os.environ['S2A_PROGRESS']
with open(p,'a',encoding='utf-8') as f:
    for i in range(1,{N}+1): f.write(f"{{time.time()}}\\t{STAGE}\\t{{i}}\\t{N}\\n")
sys.exit({code})
'''
        return [sys.executable, '-c', script]

    def last_progress(self, emit):
        events = [c.kwargs for c in emit.call_args_list if 'done' in c.kwargs and 'total' in c.kwargs]
        return (events[-1]['done'], events[-1]['total']) if events else None

    def test_lines_written_just_before_exit_are_delivered(self):
        p = self.root / 'progress.tsv'
        env = dict(__import__('os').environ, S2A_PROGRESS=str(p))
        with patch.object(self.c, 'emit', wraps=self.c.emit) as emit:
            self.c.run(self.child(p), env=env, timeout=60)
        self.assertEqual(self.last_progress(emit), (N, N))
        self.assertEqual([c.kwargs for c in emit.call_args_list if 'done' in c.kwargs][-1]['unit'], '项')   # 普通计数照旧「项」
        self.assertEqual(self.c._counters[STAGE]['done'], N)

    def test_failed_tool_still_reports_how_far_it_got(self):
        # 工具失败退出时也补读：错误页看得到停在哪一步（同一份读数，不另造）
        p = self.root / 'progress.tsv'
        env = dict(__import__('os').environ, S2A_PROGRESS=str(p))
        with patch.object(self.c, 'emit', wraps=self.c.emit) as emit:
            with self.assertRaises(Failure):
                self.c.run(self.child(p, code=3), env=env, timeout=60)
        self.assertEqual(self.last_progress(emit), (N, N))


    def test_tail_read_after_exit_sends_no_activity_pulse(self):
        # 子进程退出前写了直连批次的活动行：补读时它已不在，只发计数，不能再报「还在编」；活动状态清空
        p = self.root / 'progress.tsv'
        stage = '直连库·编批库（MB）'
        script = f'''import json,os,sys,time
p=os.environ['S2A_PROGRESS']
with open(p,'a',encoding='utf-8') as f:
    f.write(f"{{time.time()}}\\t{stage}\\t20\\t100\\n")
    f.write('#dsh_activity\\t'+json.dumps(dict(schema=1,pid=os.getpid(),stage='{stage}',target=5,pool=10,state='active'))+'\\n')
'''
        env = dict(__import__('os').environ, S2A_PROGRESS=str(p))
        # 不带存活检查的观察器：只验「收完进程树就知道活动结束」这条本身，不靠事后查 PID 推断（PID 可能已被复用）
        self.c._batch_activity = Activity(interval=.1)
        with patch.object(self.c, 'emit', wraps=self.c.emit) as emit:
            self.c.run([sys.executable, '-c', script], env=env, timeout=60)
        last = [c.kwargs for c in emit.call_args_list if 'done' in c.kwargs][-1]
        self.assertEqual((last['done'], last['total']), (20, 100))
        self.assertEqual(last['unit'], 'MB')   # #944：编批库计数是源码 MB，不写「项」
        self.assertNotIn('activity', last)
        self.assertIsNone(self.c._batch_activity.data)

if __name__ == '__main__':
    unittest.main()
