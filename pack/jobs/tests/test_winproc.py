# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1100 native Windows task boundaries. Original synthetic files/processes only."""
import contextlib
import ctypes as C
from ctypes import wintypes as W
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import core


class PinnablePath(unittest.TestCase):
    """逐级钉句柄打开的起点（纯字符串判断，各平台都跑）：盘符根、网络共享根放行（#427 游戏库在 SMB 共享盘上），设备路径和相对路径拒绝。期望手写"""
    def test_drive_and_share_roots(self):
        import winproc as w
        a = w.pinnable_path(r'D:\Games\S2Arm\logs')
        self.assertEqual((a.anchor, a.parts[1:]), ('D:\\', ('Games', 'S2Arm', 'logs')))
        b = w.pinnable_path(r'\\nas\share\S2Arm\logs')
        self.assertEqual((b.anchor, b.parts[1:]), ('\\\\nas\\share\\', ('S2Arm', 'logs')))

    def test_device_and_relative_paths_are_refused(self):
        import winproc as w
        for text in (r'\\?\C:\x', r'\\.\pipe\x', 'logs', r'S2Arm\logs'):
            with self.subTest(text=text), self.assertRaises(OSError):
                w.pinnable_path(text)


class FileTimes(unittest.TestCase):
    """#854：Windows 句柄取的文件信息要带 st_mtime（诊断包按任务记录改动时间挑最近 50 个）。纯换算，各平台都跑。
    期望按定义手写：FILETIME 是 1601-01-01 起的 100 纳秒数，Unix 零点 = 116444736000000000；
    Unix 10 亿秒（2001-09-09 01:46:40 UTC）= 116444736000000000 + 10^9 × 10^7 = 126444736000000000；半秒 = 再加 5000000"""
    def test_filetime_to_unix(self):
        import winproc as w
        def ft(n):
            return W.FILETIME(n & 0xFFFFFFFF, n >> 32)
        self.assertEqual(w._unix_time(ft(116444736000000000)), 0.0)
        self.assertEqual(w._unix_time(ft(126444736000000000)), 1_000_000_000.0)
        self.assertEqual(w._unix_time(ft(126444736005000000)), 1_000_000_000.5)


class ReferencedNamesExist(unittest.TestCase):
    """全仓（pack/ tools/）代码里引用的 winproc.<名字> 都得在 winproc 里有，各平台都跑。
    11-11 删请求文件 ACL 复核时把 _current_sid 一起删了，pack/orch/roots.py _win_acl 还在调，Windows 播种 / 删目录全部 AttributeError，
    而 Windows 专属用例只在真 Windows 上跑、门禁没拦住（#669 复现时发现）"""
    def test_every_reference_resolves(self):
        import ast
        import winproc as w
        repo = JOBS.parents[1]
        missing = []
        for path in [*repo.joinpath('pack').rglob('*.py'), *repo.joinpath('tools').rglob('*.py')]:
            if path.name == 'winproc.py' or 'tests' in path.parts:
                continue
            tree = ast.parse(path.read_text(encoding='utf-8'), str(path))
            for node in ast.walk(tree):
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == 'winproc' and not hasattr(w, node.attr):
                    missing.append(f'{path.relative_to(repo)}:{node.lineno} winproc.{node.attr}')
        self.assertEqual(missing, [])


class OriginalContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='s2arm winproc 中文 ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    @unittest.skipUnless(os.name == 'nt', 'Windows request ACL')
    def test_real_worker_accepts_private_request(self):
        request = self.root / 'request.json'
        from jobcase import _windows_private_request
        _windows_private_request(request,dict(schema=1,taskId='acl-fixture',operation='downloadMetal',
            engineDir=str(JOBS.parents[1]),privateRoot=str(self.root/'private'),library=str(self.root/'library')))
        entry = self.root / 'worker.py'
        entry.write_text('import sys\nsys.path.insert(0,' + repr(str(JOBS)) + ')\nimport main\n'
                         'main.embedded.install=lambda c:None\nmain.toolchain.download_metal=lambda c:{}\n'
                         'raise SystemExit(main.main())\n')
        result = subprocess.run([sys.executable,'-X','utf8',str(entry),'--request',str(request)],
                                capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])['state'],'succeeded')

    def context(self):
        self.output = io.StringIO()
        with contextlib.redirect_stdout(self.output):
            return core.Context(dict(schema=1,taskId='process',operation='setup',engineDir=str(JOBS.parents[1]),
                privateRoot=str(self.root/'private'),library=str(self.root/'library')))

    def test_missing_cwd_keeps_original_cause(self):
        c = self.context()
        caught = None
        try:
            c.run([sys.executable,'-c','pass'],cwd=self.root/'absent')
        except OSError as error:
            caught = error
        self.assertIsInstance(caught, FileNotFoundError)
        self.assertIsInstance(caught.__cause__, OSError)

    def test_callback_failure_cancels_owned_child(self):
        c = self.context(); children = []
        def broken(line):
            children.extend(c.children)
            raise ValueError('synthetic callback')
        caught = None
        try:
            c.run([sys.executable,'-c',"import time;print('ready',flush=True);time.sleep(15)"],on_line=broken)
        except Exception as error:
            caught = error
        finally:
            for child in children:
                if child.poll() is None: child.kill()
                child.wait(timeout=5)
        self.assertIsInstance(caught, ValueError)
        self.assertEqual(str(caught), 'synthetic callback')
        self.assertTrue(children)
        self.assertTrue(all(p.poll() is not None for p in children))
        self.assertFalse(c.children)


@unittest.skipUnless(os.name == 'nt', 'Windows native API')
class WindowsBoundaries(OriginalContracts):
    # OriginalContracts above is separately run against the unchanged baseline.
    def setUp(self):
        super().setUp()
        import winproc
        self.w = winproc

    def child(self, *args, managed=True):
        spawn = self.w.popen if managed else subprocess.Popen
        p = spawn([sys.executable,'-u','-c',*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        def cleanup():
            if managed:
                self.w.reap_session(p.pid)
                p._s2a_job.terminate()
                p._s2a_job.close()
            if p.poll() is None:
                p.kill()
            p.communicate(timeout=5)
        self.addCleanup(cleanup)
        return p

    def junction(self, target, link):
        import _winapi
        _winapi.CreateJunction(str(target),str(link))

    def test_static_reparse_and_linked_ancestor_refused(self):
        target=self.root/'outside';target.mkdir();(target/'private').write_text('{}')
        link=self.root/'link';self.junction(target,link)
        self.addCleanup(lambda: os.rmdir(link))
        with self.assertRaises(OSError): self.w.open_dir_nofollow(link)

    def test_process_runs_only_after_job_assignment(self):
        mark=self.root/'ran'
        assign=self.w._resume_initial_thread
        def inspect(p):
            self.assertFalse(mark.exists())
            self.assertIn(p.pid,p._s2a_job.members())
            assign(p)
        with patch.object(self.w,'_resume_initial_thread',side_effect=inspect):
            p=self.child("from pathlib import Path;Path("+repr(str(mark))+").write_text('ran')")
        self.assertEqual(p.wait(timeout=5),0)
        self.assertEqual(mark.read_text(),'ran')

    def grandchild(self):
        return self.child("import subprocess,sys,time;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);"
                          "print(p.pid,flush=True);time.sleep(30)")

    def assert_dead(self,pid):
        end=time.monotonic()+5
        while time.monotonic()<end:
            try:
                with self.w._process(pid) as h:
                    code=W.DWORD();self.w._checked(self.w._api('kernel32','GetExitCodeProcess',W.BOOL,W.HANDLE,C.c_void_p)(h,C.byref(code)))
                    if code.value!=259:return
            except ProcessLookupError:return
            time.sleep(.02)
        self.fail('owned grandchild survived')

    def test_cancel_kills_grandchild_without_harming_outside(self):
        outside=self.child('import time;time.sleep(30)',managed=False)
        p=self.grandchild();pid=int(p.stdout.readline())
        self.w.signal_child(p);p.wait(timeout=5);self.assert_dead(pid)
        self.assertIsNone(outside.poll())

    def test_reap_after_parent_exit_kills_grandchild(self):
        outside=self.child('import time;time.sleep(30)',managed=False)
        p=self.child("import subprocess,sys;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);print(p.pid,flush=True)")
        pid=int(p.stdout.readline());self.assertEqual(p.wait(timeout=5),0)
        names=self.w.reap_session(p.pid)
        self.assert_dead(pid);self.assertTrue(names);self.assertIsNone(outside.poll())
        self.assertEqual(self.w.reap_session(p.pid),[])

    def test_reap_skips_member_that_exited_after_listing(self):
        # Tianyan census caps stage: a grandchild listed by the job exited
        # before its image name was read; reap raised WinError 31.
        gone = subprocess.Popen([sys.executable, '-c', 'pass']); gone.wait()
        p = self.w.popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            job = self.w._jobs[p.pid]
            with patch.object(job, 'members', side_effect=[[gone.pid, p.pid], [p.pid]]):
                self.assertEqual(self.w.reap_session(p.pid), ['python.exe'])
            p.wait(timeout=10)
        finally:
            if p.poll() is None:
                p.kill()

    def test_nostall_waits_for_busy_child_and_stops_idle_one(self):
        # 11-05 Trine 5: a working tool must outlive the limit; an idle one must not.
        busy = self.child('import time\nt = time.time()\nwhile time.time() - t < 4: pass\nprint("done")')
        out, _ = self.w.communicate_nostall(busy, 1.5, poll=0.3)
        self.assertEqual((busy.returncode, out.strip()), (0, b'done'))
        idle = self.child('import time; time.sleep(30)')
        t = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            self.w.communicate_nostall(idle, 1.5, poll=0.3)
        self.assertLess(time.monotonic() - t, 6)

    def test_alive_running_exited_and_missing(self):
        # 期望手写：本进程 → 活；跑完已退出但我们还拿着句柄的子进程 → 死（不能只看 OpenProcess 成功）；不存在的进程号 → 死
        import winproc as w
        self.assertTrue(w.alive(os.getpid()))
        child = subprocess.Popen([sys.executable, '-c', 'pass']); child.wait()   # Popen 仍持有进程句柄
        self.assertFalse(w.alive(child.pid))
        self.assertFalse(core.pid_alive(child.pid))
        self.assertFalse(w.alive(0x7FFFFFF0))

    def test_cancel_forged_or_missing_creation_time_refuses(self):
        from errors import Failure
        p=self.child('import time;time.sleep(30)',managed=False)
        actual=self.w.pid_start(p.pid);self.assertTrue(actual.isdecimal())
        for forged in ('',str(int(actual)+1)):
            with self.subTest(forged=bool(forged)), self.assertRaises(Failure) as caught:
                self.w.cancel_verified(p.pid,forged,'TERM')
            self.assertEqual(caught.exception.code,'job_pid_reused');self.assertIsNone(p.poll())
        self.w.cancel_verified(p.pid,actual,'TERM');p.wait(timeout=5)

    def test_core_cancel_verifies_before_signalling_and_supports_kill(self):
        from errors import Failure
        p=self.child('import time;time.sleep(30)',managed=False)
        private=self.root/'private';task='cancel-fixture'
        record=dict(id=task,state='running',pid=p.pid,pidStart='1')
        core.atomic(private/'jobs'/(task+'.json'),record)
        with self.assertRaises(Failure) as caught:core.cancel(private,task)
        self.assertEqual(caught.exception.code,'job_pid_reused');self.assertIsNone(p.poll())
        record['pidStart']=self.w.pid_start(p.pid);core.atomic(private/'jobs'/(task+'.json'),record)
        self.assertTrue(core.cancel(private,task,'KILL')['cancelled']);p.wait(timeout=5)

    def test_permission_denial_refuses_cancel(self):
        from errors import Failure
        with patch.object(self.w,'_process',side_effect=PermissionError()), self.assertRaises(Failure) as caught:
            self.w.cancel_verified(123,'1','TERM')
        self.assertEqual(caught.exception.code,'job_not_ours')

    def test_finished_unmanaged_process_needs_no_job_signal(self):
        p=self.child('pass',managed=False);p.wait(timeout=5)
        self.w.signal_child(p)

    def test_closing_job_alone_terminates_owned_tree(self):
        p=self.grandchild();pid=int(p.stdout.readline())
        p._s2a_job.close();p.wait(timeout=5);self.assert_dead(pid)

    def test_assignment_failure_never_runs_child_code(self):
        mark=self.root/'escaped';api=self.w._api
        def functions(dll,name,*signature):
            if name=='AssignProcessToJobObject':
                def fail(*args):C.set_last_error(5);return 0
                return fail
            return api(dll,name,*signature)
        before=set(self.w._jobs)
        with patch.object(self.w,'_api',side_effect=functions), self.assertRaises(PermissionError):
            self.w.popen([sys.executable,'-c','from pathlib import Path;Path('+repr(str(mark))+').touch()'],
                         stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.assertFalse(mark.exists());self.assertEqual(set(self.w._jobs),before)

    def test_task_path_resolves_its_own_tool(self):
        # Reuse the installed interpreter as a local disposable executable;
        # never download/install a tool or publish this derived fixture.
        tool=self.root/'synthetic_winproc_tool.exe'
        shutil.copyfile(sys.executable,tool)
        env=dict(os.environ,PATH=str(self.root)+os.pathsep+str(Path(sys.executable).parent),PYTHONHOME=sys.base_prefix)
        caught=None;p=None
        try:
            p=self.w.popen([tool.name,'-c',"print('task-path')"],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        except OSError as error:
            caught=error
        self.assertIsNone(caught,'task PATH must select this task-provided tool')
        try:
            stdout,stderr=p.communicate(timeout=5)
            self.assertEqual(p.returncode,0,stderr);self.assertEqual(stdout.strip(),b'task-path')
        finally:
            self.w.reap_session(p.pid)
            if p.poll() is None:p.kill()
            p.wait(timeout=5)

    def test_handle_reads_enumerates_and_deletes_original_objects(self):
        d=self.root/'directory';d.mkdir();(d/'keep.log').write_bytes(b'original')
        (d/'nested').mkdir();(d/'nested'/'delete').write_bytes(b'fixture')
        with self.w.open_dir_nofollow(d) as parent:
            self.assertEqual(set(parent.names()),{'keep.log','nested'})
            with self.w.open_file('keep.log',parent) as source:self.assertEqual(source.read(),b'original')
            self.w.remove_at(parent,'nested')
        self.assertFalse((d/'nested').exists());self.assertEqual((d/'keep.log').read_bytes(),b'original')

    def test_replacement_after_check_is_refused_not_followed(self):
        d=self.root/'directory';d.mkdir();(d/'item').mkdir()
        outside=self.root/'outside';outside.mkdir();(outside/'keep').write_text('protected fixture')
        with self.w.open_dir_nofollow(d) as parent:
            self.assertTrue(self.w.stat_at('item',parent))
            (d/'item').rmdir();self.junction(outside,d/'item')
            try:
                with self.assertRaises(OSError):self.w.remove_at(parent,'item')
            finally:os.rmdir(d/'item')
        self.assertEqual((outside/'keep').read_text(),'protected fixture')

    def test_open_handle_prevents_renaming_to_unchecked_object(self):
        d=self.root/'directory';d.mkdir();p=d/'keep.log';p.write_bytes(b'original')
        with self.w.open_dir_nofollow(d) as parent, self.w.open_file('keep.log',parent) as source:
            with self.assertRaises(OSError):p.rename(d/'moved.log')
            self.assertEqual(source.read(),b'original')


if __name__=='__main__':unittest.main()
