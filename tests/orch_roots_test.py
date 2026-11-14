# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/roots.py
# 门禁手动：W1限定七新增文件且不改列车入口；Windows与Mac显式原生运行本测试，命令与分母随PR交付
"""Original files only: transaction/CAS, independent bytes and outside sentinels."""
import contextlib
import errno
import io
import os
import stat
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.orch import roots


class _Os:
    """只给 roots 模块看的 os：name 换成 nt，其余转给真 os（不改全进程 os.name，见 pack/jobs/tests/jobcase.py OsView）"""
    def __init__(self, name): self.name = name
    def __getattr__(self, key): return getattr(os, key)


class RenameDirTest(unittest.TestCase):
    # #361：刚写完大量文件的目录，Windows 上杀软 / 索引扫描时开着句柄，目录改名报 WinError 5 / 32；扫完放开。期望手写：
    #   ① nt：前两次被拒、第三次成 → 改名成功，睡了 DIR_RENAME_RETRIES 前两档；② nt：一直被拒 → 重试满后报 PermissionError，原文点名目录并建议加杀软排除；
    #   ③ 非 nt：被拒一次就原样抛、不睡；④ nt：别的 WinError（如 3 路径不存在）不重试
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-rename-'); self.home = Path(self.temp.name)
        (self.home / 'a.tmp').mkdir()

    def tearDown(self): self.temp.cleanup()

    def run_case(self, name, refusals, winerror=5):
        real = Path.rename; left = [refusals]; sleeps = []
        def rename(path, target):
            if left[0]:
                left[0] -= 1
                e = PermissionError(13, '拒绝访问。'); e.winerror = winerror; raise e
            return real(path, target)
        with patch.object(roots, 'os', _Os(name)), patch.object(Path, 'rename', rename):
            try:
                roots.rename_dir(self.home / 'a.tmp', self.home / 'a', sleep=sleeps.append); error = None
            except PermissionError as e:
                error = e
        return error, sleeps

    def test_windows_retries_until_scanner_lets_go(self):
        error, sleeps = self.run_case('nt', 2)
        self.assertIsNone(error); self.assertTrue((self.home / 'a').is_dir())
        self.assertEqual(sleeps, list(roots.DIR_RENAME_RETRIES[:2]))

    def test_windows_gives_up_with_actionable_message(self):
        error, sleeps = self.run_case('nt', len(roots.DIR_RENAME_RETRIES) + 1)
        self.assertIsInstance(error, PermissionError); self.assertEqual(sleeps, list(roots.DIR_RENAME_RETRIES))
        self.assertIn(str(self.home / 'a.tmp'), str(error)); self.assertIn('排除', str(error))
        self.assertTrue((self.home / 'a.tmp').is_dir())

    def test_other_platforms_do_not_retry(self):
        error, sleeps = self.run_case('posix', 1)
        self.assertIsInstance(error, PermissionError); self.assertEqual(sleeps, [])

    def test_windows_other_errors_not_retried(self):
        error, sleeps = self.run_case('nt', 1, winerror=3)
        self.assertIsInstance(error, PermissionError); self.assertEqual(sleeps, [])


class RootsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-orch-')
        self.home = Path(self.temp.name)
        self.store = roots.Roots(self.home / 'roots', shared=False)

    def tearDown(self):
        roots.remove_owned(self.home)
        self.temp.cleanup()

    def seed(self):
        tx = self.store.begin('原创', 'seed')
        (tx.path / 'exefs').mkdir()
        (tx.path / 'exefs/main').write_bytes(b'original main\x00')
        (tx.path / 'romfs').mkdir()
        (tx.path / 'romfs/data').write_bytes(b'original resource\x00')
        (tx.path / '.stage_rewrite').write_bytes(b'rw0\n')
        return tx.commit()

    def test_seed_twice_same_roots(self):   # 11-06 Windows 出包机死机后原样重起：同一工作目录二次播种，icon.jpg / ctl/control.nacp 已在现行版本里，原先 copy_file 撞「目标已在」整单红
        from pack.orch import refresh
        src = self.home / 'ex'; (src / 'exefs').mkdir(parents=True); (src / 'exefs/main').write_bytes(b'm')
        (src / 'romfs').mkdir(); (src / 'romfs/a').write_bytes(b'r'); (src / 'ctl').mkdir(); (src / 'ctl/control.nacp').write_bytes(b'n1')
        (src / 'icon.jpg').write_bytes(b'i1'); (src / 'unpack.tsv').write_text('title_id\t0100aaaa00000000\n')
        with patch.dict(os.environ, {'S2A_DUAL': '0'}):
            refresh.seed(self.store, '原创', src)
            (src / 'icon.jpg').write_bytes(b'i2'); (src / 'ctl/control.nacp').write_bytes(b'n2')
            cur = refresh.seed(self.store, '原创', src)
        self.assertEqual(((cur / 'icon.jpg').read_bytes(), (cur / 'ctl/control.nacp').read_bytes()), (b'i2', b'n2'))

    def test_commit_abort_keeps_previous_and_reuses_store(self):
        first = self.seed()
        resource = (first / 'romfs').resolve()
        tx = self.store.begin('原创', 'abort')
        (tx.path / 'exefs/main').write_bytes(b'not published')
        tx.abort()
        self.assertEqual(self.store.cur('原创'), first)
        self.assertEqual((first / 'exefs/main').read_bytes(), b'original main\x00')
        tx = self.store.begin('原创', 'next')
        (tx.path / 'exefs/main').write_bytes(b'new main')
        second = tx.commit()
        self.assertEqual((second / 'romfs').resolve(), resource)
        self.assertEqual((second / 'romfs/data').read_bytes(), b'original resource\x00')
        self.assertEqual((first / 'exefs/main').read_bytes(), b'original main\x00')
        self.assertEqual(self.store.cur('原创'), second)

    def intern_fails(self, how):
        """收进共享存储那几步按 how 出错：期望提交照常成功，RomFS 以真目录留在本版本里、内容不变，存储里没有半截身份，打一行黄（#754）"""
        tx = self.store.begin('原创', 'seed')
        (tx.path / 'exefs').mkdir(); (tx.path / 'exefs/main').write_bytes(b'm')
        (tx.path / 'romfs/arc/sub').mkdir(parents=True); (tx.path / 'romfs/arc/sub/f').write_bytes(b'resource')
        real_link, real_rename = roots.directory_link, roots.rename_dir
        def half_junction(target, link, **k):   # junction 退路建了空目录、写重解析点时失败（_junction 自己的回收也没成）；别的链接照常
            if Path(link).name != 'romfs': return real_link(target, link, **k)
            Path(link).mkdir(); raise OSError(145, '目录不是空的。')
        def move_fails(src, dst, **k):
            if Path(dst).parent.name == '原创' and '.romfs_store' in str(dst): raise PermissionError(5, '拒绝访问。')
            return real_rename(src, dst, **k)
        err = io.StringIO()
        with contextlib.redirect_stderr(err), \
             patch.object(roots, 'directory_link', side_effect=half_junction if how == 'link' else real_link), \
             patch.object(roots, 'rename_dir', side_effect=move_fails if how == 'move' else real_rename):
            final = tx.commit()
        self.assertFalse(roots.is_link(final / 'romfs'))
        self.assertEqual((final / 'romfs/arc/sub/f').read_bytes(), b'resource')
        self.assertFalse((final / '.romfs.intern').exists())
        store = self.home / 'roots/.romfs_store/原创'
        self.assertEqual(list(store.iterdir()) if store.is_dir() else [], [])
        self.assertIn('【黄】RomFS 没收进共享存储', err.getvalue())
        return final

    def test_intern_link_failure_keeps_romfs_in_version(self):
        final = self.intern_fails('link')
        tx = self.store.begin('原创', 'next')   # 下一个阶段照常从这一版开工
        self.assertEqual((tx.path / 'romfs/arc/sub/f').read_bytes(), b'resource')
        tx.abort()

    def test_intern_move_failure_keeps_romfs_in_version(self):
        self.intern_fails('move')

    def test_failed_activation_leaves_current(self):
        first = self.seed()
        tx = self.store.begin('原创', 'fail')
        with patch.object(roots, 'replace_link', side_effect=OSError('activation denied')):
            with self.assertRaises(OSError):
                tx.commit()
        self.assertEqual(self.store.cur('原创'), first)
        self.assertEqual((first / 'exefs/main').read_bytes(), b'original main\x00')

    def test_concurrent_unclaimed_write_is_rejected(self):
        self.seed()
        a = self.store.begin('原创', 'a')
        b = self.store.begin('原创', 'b')
        (a.path / 'a').write_bytes(b'A')
        (b.path / 'b').write_bytes(b'B')
        current = a.commit()
        with self.assertRaises(roots.Conflict):
            b.commit()
        self.assertEqual(self.store.cur('原创'), current)
        self.assertFalse((current / 'b').exists())
        self.assertFalse(b.path.exists())

    def test_replay_preserves_other_stage_and_deletions(self):
        self.seed()
        a = self.store.begin('原创', 'a')
        b = self.store.begin('原创', 'b')
        (a.path / 'a').write_bytes(b'A')
        (b.path / 'b').write_bytes(b'B')
        (b.path / 'exefs/main').unlink()
        a.commit()
        current = b.commit(replay=('b', 'exefs/main'))
        self.assertEqual((current / 'a').read_bytes(), b'A')
        self.assertEqual((current / 'b').read_bytes(), b'B')
        self.assertFalse((current / 'exefs/main').exists())

    def test_external_link_rejected_and_original_untouched(self):
        first = self.seed()
        outside = self.home / 'outside'
        outside.mkdir()
        (outside / 'sentinel').write_bytes(b'KEEP')
        roots.directory_link(outside, first / 'evil')
        with self.assertRaises(roots.UnsafeRoot):
            self.store.begin('原创', 'bad')
        self.assertEqual((outside / 'sentinel').read_bytes(), b'KEEP')
        self.assertEqual(self.store.cur('原创'), first)

    def test_wrong_game_store_link_is_rejected(self):
        first = self.seed()
        roots.remove_owned(first / 'romfs')
        outside = self.store.path / '.romfs_store/别款/id'
        outside.mkdir(parents=True)
        roots.directory_link(outside, first / 'romfs')
        with self.assertRaises(roots.UnsafeRoot):
            self.store.begin('原创', 'bad')

    def test_store_parent_link_rejected_before_creating_external_directory(self):
        outside = self.home / 'outside-store'
        outside.mkdir()
        roots.directory_link(outside, self.store.path / '.romfs_store')
        tx = self.store.begin('原创', 'bad-store')
        (tx.path / 'romfs').mkdir()
        (tx.path / 'romfs/data').write_bytes(b'original')
        with self.assertRaises(roots.UnsafeRoot):
            tx.commit()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertIsNone(self.store.cur('原创'))

    def test_romfs_is_physically_readonly(self):
        # 开发 / 门禁机（S2A_ROMFS_SEAL=1）：共享存储物理只读，阶段误写当场失败
        with patch.dict(os.environ, {'S2A_ROMFS_SEAL': '1'}):
            first = self.seed()
        probe = 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"BAD")'
        result = subprocess.run([sys.executable, '-c', probe, str(first / 'romfs/data')], capture_output=True)
        if os.name != 'nt' and hasattr(os, 'geteuid') and os.geteuid() == 0:
            self.skipTest('root bypasses POSIX permission bits; normal-user check required')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((first / 'romfs/data').read_bytes(), b'original resource\x00')

    def test_romfs_player_writable(self):
        # 玩家机（不设 S2A_ROMFS_SEAL）：存储在玩家看得见的游戏库里，不许只读——玩家手动删旧产物不能被挡
        with patch.dict(os.environ, {'S2A_ROMFS_SEAL': ''}):
            first = self.seed()
        target = (first / 'romfs').resolve()
        if os.name == 'nt':
            probe = 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(Path(sys.argv[1]).read_bytes())'
            self.assertEqual(subprocess.run([sys.executable, '-c', probe, str(target / 'data')]).returncode, 0)
        else:
            stuck = [p for p in [target, *target.rglob('*')] if not p.is_symlink() and not os.stat(p).st_mode & stat.S_IWUSR]
            self.assertEqual(stuck, [])

    def test_ntfs_romfs_hardlink(self):
        # #291：Windows 同卷非 ReFS（NTFS）播种 RomFS 建硬链接、不逐文件实拷；别的目录（link_ok 不给）照旧实拷成独立的一份。
        #   期望手写：link_ok → 目标与源同一个文件（同 inode、链接数 2）、不打「实拷」；不给 → 独立文件、字节相同、打「实拷」；
        #   建链接失败（跨卷 / FAT）→ 退回实拷。在 Mac / Linux 上把平台看成 win32、ReFS 判否来走这条路（硬链接 posix 照样能建）
        src = self.home / 'romfs-file'
        src.write_bytes(bytes(range(256)) * 17)
        def run(dst, **kw):
            err = io.StringIO()
            with patch.object(roots.sys, 'platform', 'win32'), patch.object(roots, 'refs_same_volume', return_value=False), \
                 contextlib.redirect_stderr(err):
                roots.copy_file(src, dst, **kw)
            return err.getvalue()
        out = run(self.home / 'linked', link_ok=True)
        self.assertTrue(os.path.samefile(src, self.home / 'linked'))
        self.assertEqual(os.stat(src).st_nlink, 2)
        self.assertNotIn('实拷', out)
        out = run(self.home / 'copied')
        self.assertFalse(os.path.samefile(src, self.home / 'copied'))
        self.assertEqual(src.read_bytes(), (self.home / 'copied').read_bytes())
        self.assertIn('实拷', out)
        with patch.object(roots.os, 'link', side_effect=OSError(errno.EXDEV, 'cross-device')):
            out = run(self.home / 'fallback', link_ok=True)
        self.assertFalse(os.path.samefile(src, self.home / 'fallback'))
        self.assertIn('硬链接不可用', out)

    def test_realcopy_warns_and_bytes_match(self):
        src = self.home / 'source'
        dst = self.home / 'dest'
        src.write_bytes(bytes(range(256)) * 33)
        err = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(roots, 'refs_same_volume', return_value=False))
            if sys.platform == 'darwin':
                # Same-volume clonefile can succeed on APFS. Exercise the
                # real-copy fallback deliberately, not by assuming the host.
                libc = type('LibC', (), {'clonefile': Mock(return_value=-1)})()
                stack.enter_context(patch.object(roots.C, 'CDLL', return_value=libc))
                stack.enter_context(patch.object(roots.C, 'get_errno', return_value=errno.EXDEV))
            elif sys.platform.startswith('linux'):
                import fcntl
                stack.enter_context(patch.object(fcntl, 'ioctl', side_effect=OSError(errno.EXDEV, 'original fallback')))
            stack.enter_context(contextlib.redirect_stderr(err))
            roots.copy_file(src, dst)
        self.assertEqual(src.read_bytes(), dst.read_bytes())
        self.assertIn('实拷', err.getvalue())

    @unittest.skipUnless(os.name == 'nt', 'native Windows junction fallback')
    def test_junction_fallback_and_atomic_switch(self):
        a, b = self.home / 'a', self.home / 'b'
        a.mkdir(); b.mkdir()
        (a / 'file').write_bytes(b'A')
        (b / 'file').write_bytes(b'B')
        with patch.object(roots.os, 'symlink', side_effect=OSError(1314, 'no privilege')):
            roots.directory_link(a, self.home / 'current')
            roots.directory_link(b, self.home / 'next')
        self.assertTrue((self.home / 'current').is_junction())
        roots.replace_link(self.home / 'next', self.home / 'current')
        self.assertEqual((self.home / 'current/file').read_bytes(), b'B')
        self.assertEqual((a / 'file').read_bytes(), b'A')

    def test_prune_keeps_current_previous(self):
        self.seed()
        for tag in ('v2', 'v3', 'v4'):
            self.store.begin('原创', tag).commit()
        names = sorted(p.name for p in self.store.path.glob('原创@*') if not roots.is_link(p))
        self.assertEqual(names, ['原创@v3', '原创@v4'])

    def test_replay_exclusion_preserves_new_nested_data(self):
        self.seed()
        a = self.store.begin('原创', 'a')
        b = self.store.begin('原创', 'b')
        (a.path / 'shaders/direct').mkdir(parents=True)
        (a.path / 'shaders/direct/key').write_bytes(b'new-direct')
        (b.path / 'shaders').mkdir()
        (b.path / 'shaders/other').write_bytes(b'new-other')
        a.commit()
        current = b.commit(replay=('shaders', '!shaders/direct'))
        self.assertEqual((current / 'shaders/direct/key').read_bytes(), b'new-direct')
        self.assertEqual((current / 'shaders/other').read_bytes(), b'new-other')

    def test_kernel_lock_excludes_another_process(self):
        script = ('from pathlib import Path; from pack.orch.roots import Roots; '
                  'import sys; r=Roots(sys.argv[1],shared=False); '
                  'exec("try:\\n with r.locked(\'原创\',timeout=.2): pass\\nexcept TimeoutError:\\n sys.exit(7)")')
        with self.store.locked('原创'):
            p = subprocess.run([sys.executable, '-X', 'utf8', '-c', script, str(self.store.path)],
                               cwd=roots.REPO, capture_output=True)
        self.assertEqual(p.returncode, 7, p.stderr.decode('utf-8'))
        with self.store.locked('原创', timeout=.2):
            pass

    def test_live_reader_pin_prevents_prune(self):
        first = self.seed()
        script = ('from pack.orch.roots import Roots; import sys,time; '
                  'r=Roots(sys.argv[1],shared=False); r.cur("原创"); '
                  'print("pinned",flush=True); time.sleep(30)')
        p = subprocess.Popen([sys.executable, '-X', 'utf8', '-c', script, str(self.store.path)],
                             cwd=roots.REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(p.stdout.readline().strip(), b'pinned')
            for tag in ('v2', 'v3'):
                self.store.begin('原创', tag).commit()
            self.assertTrue(first.is_dir())
        finally:
            p.terminate(); p.communicate(timeout=10)
        self.store.prune('原创')
        self.assertFalse(first.exists())

    def test_shared_newer_same_stage_cannot_be_replayed_back(self):
        repo = self.home / 'git'
        repo.mkdir()
        def git(*args):
            return subprocess.run(['git', '-C', str(repo), *args], check=True,
                                  capture_output=True).stdout.decode().strip()
        git('init', '-q')
        git('config', 'user.name', 'Original fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        (repo / 'version').write_bytes(b'old')
        git('add', 'version'); git('commit', '-qm', 'original old')
        old = git('rev-parse', 'HEAD')
        (repo / 'version').write_bytes(b'new')
        git('commit', '-qam', 'original new')
        newer = git('rev-parse', 'HEAD')
        git('update-ref', 'refs/remotes/origin/main', newer)
        git('checkout', '--detach', '-q', old)
        store = roots.Roots(self.home / 'shared', shared=True, repo=repo)
        initial = store.begin('原创', 'initial')
        (initial.path / '.stage_rewrite').write_bytes(b'old\n')
        initial.commit()
        slow = store.begin('原创', 'slow')
        (slow.path / '.stage_rewrite').write_bytes(b'old-rebuilt\n')
        git('checkout', '--detach', '-q', newer)
        fast = store.begin('原创', 'fast')
        (fast.path / '.stage_rewrite').write_bytes(b'new\n')
        current = fast.commit()
        with self.assertRaises(roots.Conflict):
            slow.commit(replay=('.stage_rewrite',))
        self.assertEqual(store.cur('原创'), current)
        self.assertEqual((current / '.stage_rewrite').read_bytes(), b'new\n')
        git('checkout', '--detach', '-q', old)
        with self.assertRaises(roots.Conflict):
            store.begin('原创', 'backward')

    @unittest.skipUnless(os.name == 'nt', 'Windows exited process object lifetime')
    def test_exited_process_object_is_not_a_live_reader(self):
        from pack.jobs import winproc
        p = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'])
        try:
            with winproc._process(p.pid) as held:
                stamp = winproc._creation_time(held)
                self.assertEqual(roots.process_start(p.pid), stamp)
                p.terminate(); p.communicate(timeout=10)
                # Deliberately retain a query handle: a creation timestamp
                # remains obtainable even though this original child exited.
                self.assertEqual(winproc._creation_time(held), stamp)
                self.assertEqual(roots.process_start(p.pid), '')
        finally:
            if p.poll() is None:
                p.terminate(); p.communicate(timeout=10)


class SelfHealLinkModeTest(unittest.TestCase):
    """链接模式（NTFS / APFS）的自愈（v0.3.1）。期望手写：
    ① 现行链接丢了（被删 / 换版本中途被杀在换链接之前）：cur() 取最新的已提交版本重建现行，内容是那一版；没有任何版本时照旧 None
    ② 换链接那一步失败：现行还是旧版（已有用例 test_failed_activation_leaves_current）；之后再提交照常"""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-heal-'); self.home = Path(self.temp.name)
        self.store = roots.Roots(self.home / 'roots', shared=False)

    def tearDown(self):
        roots.remove_owned(self.home); self.temp.cleanup()

    def test_missing_current_link_heals_to_newest(self):
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            self.assertIsNone(self.store.cur('原创'))
            for tag, data in (('v1', b'1'), ('v2', b'2')):
                tx = self.store.begin('原创', tag); (tx.path / 'f').write_bytes(data); tx.commit(); time.sleep(0.01)
            live = self.store.path / '原创@现行'
            roots.remove_owned(live)
            cur = self.store.cur('原创')
        self.assertTrue(roots.is_link(live)); self.assertEqual(cur.name, '原创@v2'); self.assertEqual((cur / 'f').read_bytes(), b'2')


class PlainRootsTest(unittest.TestCase):
    """实目录模式（v0.3.1：游戏库 / 存放位置在 exFAT / FAT32 上，卷上建不了目录链接；S2A_ROOTS_PLAIN=1 在 Mac 上走同一条）。期望手写：
    ① 现行是真目录（不是链接），版本名记在 .root_tag；再提交一次，旧现行改回 <款>@<它的版本名>、内容不变，romfs 留在版本里、不建 .romfs_store
    ② 两个事务从同一现行起，先提交的赢，后提交的没声明重放就 Conflict（版本身份按 .root_tag 比，不按固定的「@现行」目录名）
    ③ 声明了重放：两边的改动都在
    ④ 第二次改名（新版本 → 现行）失败：旧现行改回原位、仍是现行（两次改名中间失败的自愈）；被杀在两次改名之间 / 现行被删 / 版本名记录丢了也自愈（见各用例）
    ⑤ prune 留现行 + 上一版，更早的删掉
    ⑥ 播种 move_romfs：不把原处 romfs 整个搬走（搬走后原处没法留联接），原处还在、现行里有一份"""
    def setUp(self):
        self.env = patch.dict(os.environ, {'S2A_ROOTS_PLAIN': '1'}); self.env.start()
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-plain-')
        self.home = Path(self.temp.name)
        self.store = roots.Roots(self.home / 'roots', shared=False)

    @unittest.skipUnless(os.name == 'nt', 'UNC volume probe is Windows-only')
    def test_unc_share_uses_plain_mode_without_volume_junction_probe(self):
        with patch.dict(os.environ, {'S2A_ROOTS_PLAIN': ''}), \
             patch.object(roots, '_api', side_effect=AssertionError('UNC roots must not query junction-capable volume APIs')):
            self.assertFalse(roots.links_supported(r'\\server\share\game-library'))

    def tearDown(self):
        roots.remove_owned(self.home); self.temp.cleanup(); self.env.stop()

    def commit(self, tag, files):
        tx = self.store.begin('原创', tag)
        for name, data in files.items():
            (tx.path / name).parent.mkdir(parents=True, exist_ok=True); (tx.path / name).write_bytes(data)
        return tx.commit()

    def test_current_is_real_directory_and_old_is_parked(self):
        self.assertTrue(self.store.plain)
        first = self.commit('seed', {'exefs/main': b'm1', 'romfs/data': b'r1'})
        live = self.store.path / '原创@现行'
        self.assertEqual(first, live); self.assertFalse(roots.is_link(live)); self.assertTrue(live.is_dir())
        self.assertEqual(roots.read(live / '.root_tag'), '原创@seed')
        self.commit('next', {'exefs/main': b'm2'})
        self.assertEqual(self.store.cur('原创'), live)
        self.assertEqual(roots.read(live / '.root_tag'), '原创@next')
        self.assertEqual((live / 'exefs/main').read_bytes(), b'm2'); self.assertEqual((live / 'romfs/data').read_bytes(), b'r1')
        old = self.store.path / '原创@seed'
        self.assertEqual((old / 'exefs/main').read_bytes(), b'm1')
        self.assertFalse(roots.is_link(live / 'romfs')); self.assertFalse((self.home / 'roots' / '.romfs_store').exists())

    def test_concurrent_conflict_and_replay(self):
        self.commit('seed', {'exefs/main': b'm'})
        a = self.store.begin('原创', 'a'); b = self.store.begin('原创', 'b'); c = self.store.begin('原创', 'c')
        (a.path / 'a').write_bytes(b'A'); (b.path / 'b').write_bytes(b'B'); (c.path / 'c').write_bytes(b'C')
        live = a.commit()
        with self.assertRaises(roots.Conflict):
            b.commit()
        self.assertFalse((live / 'b').exists())
        live = c.commit(replay=('c',))
        self.assertEqual(((live / 'a').read_bytes(), (live / 'c').read_bytes()), (b'A', b'C'))

    def test_failed_second_rename_restores_current(self):
        self.commit('seed', {'exefs/main': b'm1'})
        live = self.store.path / '原创@现行'
        tx = self.store.begin('原创', 'next')
        real = roots.rename_dir
        def rename(src, dst, **kw):
            if Path(dst) == live and Path(src) == tx.path:
                raise OSError('rename denied')
            return real(src, dst, **kw)
        with patch.object(roots, 'rename_dir', rename), self.assertRaises(OSError):
            tx.commit()
        self.assertEqual(self.store.cur('原创'), live)
        self.assertEqual(roots.read(live / '.root_tag'), '原创@seed'); self.assertEqual((live / 'exefs/main').read_bytes(), b'm1')

    def test_prune_keeps_current_and_previous(self):
        for i in range(4):
            self.commit(f'v{i}', {'exefs/main': str(i).encode()})
            time.sleep(0.01)
        names = sorted(p.name for p in (self.home / 'roots').glob('原创@*') if p.is_dir())
        self.assertEqual(names, ['原创@v2', '原创@现行'])

    def test_killed_between_two_renames_heals_to_new_version(self):
        # ① 换版本中途被杀：旧现行已停回 <款>@seed，新版本还在 <款>@next.tmp（已写 .root_tag = 已校验、正在换上），没有现行 →
        #   cur() 把换到一半的那个换上；内容是新版、版本名是 原创@next
        self.commit('seed', {'exefs/main': b'm1'})
        live = self.store.path / '原创@现行'
        tx = self.store.begin('原创', 'next'); (tx.path / 'exefs/main').write_bytes(b'm2')
        roots.text(tx.path / '.root_tag', '原创@next\n')
        roots.rename_dir(live, self.store.path / '原创@seed')   # 被杀前已做完的第一次改名
        cur = self.store.cur('原创')
        self.assertEqual(cur, live); self.assertEqual((live / 'exefs/main').read_bytes(), b'm2')
        self.assertEqual(roots.read(live / '.root_tag'), '原创@next')
        self.assertTrue((self.store.path / '原创@seed').is_dir())

    def test_missing_current_heals_to_newest_parked(self):
        # ① 另一种被杀时机（新版本还没写 .root_tag）/ 现行目录被删：取最新的已提交版本换上
        self.commit('v1', {'f': b'1'}); time.sleep(0.01); self.commit('v2', {'f': b'2'})
        live = self.store.path / '原创@现行'
        roots.remove_owned(live)
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            cur = self.store.cur('原创')
        self.assertEqual(cur, live); self.assertEqual((live / 'f').read_bytes(), b'1')   # v2 是被删的那个现行；剩下最新的是 v1
        self.assertEqual(roots.read(live / '.root_tag'), '原创@v1')

    def test_lost_tag_is_rewritten_and_next_commit_parks_old(self):
        # ② 现行的版本名记录（.root_tag）丢了：cur() 补记一个新名字；再提交时旧现行停到那个名字下，新的成现行
        self.commit('seed', {'f': b'1'})
        live = self.store.path / '原创@现行'
        (live / '.root_tag').unlink()
        self.store.cur('原创')
        tag = roots.read(live / '.root_tag')
        self.assertTrue(tag.startswith('原创@recovered-'))
        self.commit('next', {'f': b'2'})
        self.assertEqual((live / 'f').read_bytes(), b'2'); self.assertEqual(((self.store.path / tag) / 'f').read_bytes(), b'1')

    def test_seed_does_not_move_romfs_away(self):
        from pack.orch import refresh
        src = self.home / 'ex'; (src / 'exefs').mkdir(parents=True); (src / 'exefs/main').write_bytes(b'm')
        (src / 'romfs').mkdir(); (src / 'romfs/a').write_bytes(b'r'); (src / 'unpack.tsv').write_text('title_id\t0100aaaa00000000\n')
        with patch.dict(os.environ, {'S2A_DUAL': '0'}):
            cur = refresh.seed(self.store, '原创', src, move_romfs=True)
        self.assertEqual((src / 'romfs/a').read_bytes(), b'r'); self.assertFalse(roots.is_link(src / 'romfs'))
        self.assertEqual((cur / 'romfs/a').read_bytes(), b'r')


class ShortRootLinkTest(unittest.TestCase):
    # #461：Windows 上目录链接一律写绝对的玩家路径（短根换回长路径）；读链接自己拼，老的相对链接经短根联接也读得出。期望手写：
    #   ① nt（模拟）：给了 relative、目标在短根下 → os.symlink 收到的是长路径下的绝对目标，不是相对、不是短路径
    #   ② 原生 Windows：经短根联接访问时，老的相对软链 link_target 解析到真实目录；directory_link 新建的链接内容 = 长路径绝对目标，经联接 stat / listdir 正常
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-461-'); self.home = Path(self.temp.name)

    def tearDown(self): self.temp.cleanup()

    def test_nt_writes_absolute_long_target(self):
        fake = _Os('nt'); fake.symlink = Mock()
        long, short = self.home / 'long', self.home / 'j' / 'ab12'
        with patch.object(roots, 'os', fake), patch.object(roots, 'table_now', return_value=__import__('pack.orch.winlong', fromlist=['parse_table']).parse_table(f'{long}\t{short}')):
            roots.directory_link(short / 'roots' / 'g@v1', short / 'roots' / 'g@现行', relative='g@v1')
        value = fake.symlink.call_args.args[0]
        self.assertEqual(value, os.path.normpath(str(long / 'roots' / 'g@v1')))
        self.assertTrue(fake.symlink.call_args.kwargs.get('target_is_directory'))

    @unittest.skipUnless(os.name == 'nt', 'native Windows short-root junction')
    def test_native_relative_old_link_and_new_absolute_link(self):
        import _winapi
        long, short = self.home / 'long', self.home / 'j' / 'ab12'
        (long / 'roots' / 'v1').mkdir(parents=True); (long / 'roots' / 'v1' / 'f').write_bytes(b'x'); short.parent.mkdir()
        _winapi.CreateJunction(str(long), str(short))
        try:
            try:
                os.symlink('v1', long / 'roots' / 'old', target_is_directory=True)   # #461 之前的写法
            except OSError as e:
                self.skipTest(f'建不了软链（没开开发者模式、非提权）：{e}')
            got = roots.link_target(short / 'roots' / 'old')
            self.assertEqual(os.path.normcase(str(got)), os.path.normcase(str((long / 'roots' / 'v1').resolve())))
            env = {'S2A_SHORT_ROOTS': f'{long}\t{short}'}
            with patch.dict(os.environ, env):
                roots.directory_link(short / 'roots' / 'v1', short / 'roots' / 'new', relative='v1')
            link = short / 'roots' / 'new'
            raw = os.readlink(link)
            for prefix in ('\\\\?\\', '\\??\\'):
                raw = raw[len(prefix):] if raw.startswith(prefix) else raw
            self.assertEqual(os.path.normcase(raw), os.path.normcase(str(long / 'roots' / 'v1')))
            os.stat(link); self.assertEqual(os.listdir(link), ['f'])
        finally:
            os.rmdir(short)


if __name__ == '__main__':
    unittest.main()
