# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/roots.py pack/orch/dirrename.py
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
from pack.orch import dirrename, roots



def writable(path):
    """真去以写方式打开一下（不写）：Windows 的封存是拒写的访问控制项，os.access 只看只读位、判不出来"""
    try:
        with open(path, 'r+b'):
            return True
    except PermissionError:
        return False


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
        with patch.object(dirrename, 'os', _Os(name)), patch.object(Path, 'rename', rename):
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
        with patch.object(roots.curptr, 'write', side_effect=OSError('activation denied')):   # 切现行指针那一步失败
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

    def test_copy_tree_judges_volume_once_per_tree(self):
        # 11-16 出包轻阶段：每个阶段事务克隆现行，追加内容几千个文件原先逐个判「同一 ReFS 卷」（每个文件两次 realpath + 两次查卷）。
        #   期望手写：一棵 3 个文件、2 层子目录的树 → 判卷 1 次，判的是源根与目标根，判出的结果交给每个文件；字节逐个相同；
        #   只有空目录的树 → 0 次；单个文件不给 refs 照旧自己判 1 次，给了 refs=False 不判
        src = self.home / 'aoc-src'
        (src / '1/sub').mkdir(parents=True); (src / 'empty').mkdir()
        files = {'a.bin': b'A' * 3, '1/b.bin': b'B' * 5, '1/sub/c.bin': b'C' * 7}
        for rel, data in files.items():
            (src / rel).write_bytes(data)
        judge = Mock(return_value=False)
        with patch.object(roots.sys, 'platform', 'win32'), patch.object(roots, 'refs_same_volume', judge), \
             contextlib.redirect_stderr(io.StringIO()):
            self.store._copy_tree(src, self.home / 'aoc-dst')
            self.assertEqual(judge.call_count, 1)
            self.assertEqual(judge.call_args.args[0], src)
            self.assertEqual(Path(judge.call_args.args[1]).parent, self.home / 'aoc-dst')
            for rel, data in files.items():
                self.assertEqual((self.home / 'aoc-dst' / rel).read_bytes(), data)
            self.assertTrue((self.home / 'aoc-dst/empty').is_dir())
            judge.reset_mock()
            (self.home / 'only-dirs/x/y').mkdir(parents=True)
            self.store._copy_tree(self.home / 'only-dirs', self.home / 'only-dirs-copy')
            self.assertEqual(judge.call_count, 0)
            roots.copy_file(src / 'a.bin', self.home / 'single')
            self.assertEqual(judge.call_count, 1)
            roots.copy_file(src / 'a.bin', self.home / 'single2', refs=False)
            self.assertEqual(judge.call_count, 1)
        self.assertEqual((self.home / 'single2').read_bytes(), b'AAA')

    def test_shared_tree_written_in_place_is_refused_at_commit(self):
        # 11-16 维护者：硬链接的前提「aoc/ 只许整目录替换、不许原地改」要有守护。期望手写：
        #   ① 阶段原地改 aoc/d1/a.bin → 提交报冲突、点名 aoc/d1/a.bin，现行版本号不变（Windows 硬链接下现行那份文件已被连带改，非 Windows 不变）；② 整目录换掉 aoc/（aoc 阶段那条路）→ 正常提交、内容是新的；
        #   ③ 不动 aoc/、只改别处 → 正常提交
        first = self.seed()
        tx = self.store.begin('原创', 'aoc0')
        (tx.path / 'aoc' / 'd1').mkdir(parents=True); (tx.path / 'aoc/d1/a.bin').write_bytes(b'dlc a'); (tx.path / 'aoc/b.bin').write_bytes(b'dlc b')
        base = tx.commit()
        tx = self.store.begin('原创', 'aoc1')
        linked = os.path.samefile(tx.path / 'aoc/d1/a.bin', base / 'aoc/d1/a.bin')   # Windows 上是硬链接（_copy_tree hardlink），别处是克隆 / 实拷
        if linked and roots.sealing():   # 开发 / 门禁机上它已封存（Transaction._seal_shared）：原地写在第一下就失败，另见 test_shared_tree_sealed_on_dev_machines_only
            with self.assertRaises(PermissionError):
                (tx.path / 'aoc/d1/a.bin').write_bytes(b'dlc a changed in place')
            tx.abort()
            return
        (tx.path / 'aoc/d1/a.bin').write_bytes(b'dlc a changed in place')
        with self.assertRaises(roots.Conflict) as cm:
            tx.commit()
        self.assertIn('aoc/d1/a.bin', str(cm.exception).replace(os.sep, '/'))
        # 守护只能在提交时发现、拦住这一版上线；硬链接下原地写已经连带改了现行那份文件（这正是只许整目录替换的原因），克隆 / 实拷下现行不受影响
        self.assertEqual((self.store.cur('原创'), (base / 'aoc/d1/a.bin').read_bytes()), (base, b'dlc a changed in place' if linked else b'dlc a'))
        self.assertEqual(linked, os.name == 'nt')
        tx = self.store.begin('原创', 'aoc2')
        roots.remove_owned(tx.path / 'aoc'); tx.replaced('aoc'); (tx.path / 'aoc').mkdir(); (tx.path / 'aoc/c.bin').write_bytes(b'dlc c')
        two = tx.commit()
        self.assertEqual(sorted(p.name for p in (two / 'aoc').iterdir()), ['c.bin'])
        tx = self.store.begin('原创', 'aoc3')
        (tx.path / 'exefs/main').write_bytes(b'new main')
        self.assertEqual((tx.commit() / 'aoc/c.bin').read_bytes(), b'dlc c')
        self.assertNotEqual(first, two)
        # ④ 整目录换掉却没声明（tx.replaced）→ 照样报冲突：不靠树目录 inode 判「换没换」（ext4 上删掉的目录 inode 会马上被新目录复用，11-16 Linux 门禁误报）
        tx = self.store.begin('原创', 'aoc4')
        roots.remove_owned(tx.path / 'aoc'); (tx.path / 'aoc').mkdir(); (tx.path / 'aoc/c.bin').write_bytes(b'dlc C changed')
        with self.assertRaises(roots.Conflict):
            tx.commit()
        self.assertEqual((self.store.cur('原创') / 'aoc/c.bin').read_bytes(), b'dlc c')

    def test_shared_tree_sealed_on_dev_machines_only(self):
        # 11-16 维护者定：共用数据树（aoc/）只在开发 / 门禁机（S2A_ROMFS_SEAL=1）封成只读，玩家机不封。期望手写：
        #   ① 门禁机提交后 aoc 下的文件不可写，别处（exefs）照旧可写；② Windows 上下一版的 aoc 是同一个文件的硬链接：原地写在第一下就失败、现行内容不变；
        #   ③ 下一版整目录换掉 aoc（remove_owned + replaced）照常提交，删掉的只是这一版的链接，上一版那份仍封着；④ 玩家机提交后 aoc 照旧可写
        self.seed()
        with patch.dict(os.environ, {'S2A_ROMFS_SEAL': '1'}):
            tx = self.store.begin('原创', 'seal0')
            (tx.path / 'aoc').mkdir(); (tx.path / 'aoc/a.bin').write_bytes(b'dlc a')
            base = tx.commit()
            self.assertEqual((writable(base / 'aoc/a.bin'), writable(base / 'exefs/main')), (False, True))
            tx = self.store.begin('原创', 'seal1')
            if os.name == 'nt':
                self.assertTrue(os.path.samefile(tx.path / 'aoc/a.bin', base / 'aoc/a.bin'))
                with self.assertRaises(PermissionError):
                    (tx.path / 'aoc/a.bin').write_bytes(b'dlc a changed in place')
            self.assertEqual((base / 'aoc/a.bin').read_bytes(), b'dlc a')
            roots.remove_owned(tx.path / 'aoc'); tx.replaced('aoc'); (tx.path / 'aoc').mkdir(); (tx.path / 'aoc/b.bin').write_bytes(b'dlc b')
            two = tx.commit()
            self.assertEqual(sorted(p.name for p in (two / 'aoc').iterdir()), ['b.bin'])
            self.assertEqual(((base / 'aoc/a.bin').read_bytes(), writable(base / 'aoc/a.bin')), (b'dlc a', False))
        with patch.dict(os.environ, {'S2A_ROMFS_SEAL': ''}):
            tx = self.store.begin('原创', 'seal2')
            (tx.path / 'aoc/c.bin').write_bytes(b'dlc c')
            tx.replaced('aoc')
            self.assertTrue(writable(tx.commit() / 'aoc/c.bin'))

    def test_shared_trees_hardlinked_on_windows_and_fall_back_to_copy(self):
        # 11-16 出包轻阶段：追加内容（aoc）各版本共用、不原地改，阶段事务克隆现行时 Windows 上逐个建硬链接，不逐个块克隆。
        #   期望手写：① 阶段事务克隆现行：aoc 走硬链接、exefs 不走；② Windows 下硬链接树：每个文件与源同一个文件、空目录照建、不调 copy_file；
        #   ③ 硬链接建不了（FAT 类卷）：说一句黄、这一棵全部照常 copy_file（3 个文件 3 次），字节相同、与源不是同一个文件
        tx = self.store.begin('原创', 'with-aoc')
        (tx.path / 'exefs').mkdir(); (tx.path / 'exefs/main').write_bytes(b'main')
        (tx.path / 'aoc/1').mkdir(parents=True); (tx.path / 'aoc/1/data').write_bytes(b'dlc')
        tx.commit()
        seen = {}; real = self.store._copy_tree
        def spy(source, dest, *a, hardlink=False, **k):
            seen[Path(source).name] = hardlink
            return real(source, dest, *a, hardlink=hardlink, **k)
        with patch.object(self.store, '_copy_tree', side_effect=spy):
            self.store.begin('原创', 'next').abort()
        self.assertEqual(seen, {'aoc': True, 'exefs': False})
        src = self.home / 'aoc-src'
        (src / '1/sub').mkdir(parents=True); (src / '2').mkdir()
        files = {'a.bin': b'A' * 3, '1/b.bin': b'B' * 5, '1/sub/c.bin': b'C' * 7}
        for rel, data in files.items():
            (src / rel).write_bytes(data)
        nt = _Os('nt')
        posix_link = patch.object(roots, 'is_link', lambda p: Path(p).is_symlink())   # 只把硬链接这一步看成 Windows；判链接照本机
        with patch.object(roots, 'os', nt), posix_link, patch.object(roots, 'copy_file', side_effect=AssertionError('copied')):
            self.store._copy_tree(src, self.home / 'linked', hardlink=True)
        for rel in files:
            self.assertTrue(os.path.samefile(src / rel, self.home / 'linked' / rel), rel)
        self.assertTrue((self.home / 'linked/2').is_dir())
        nt.link = Mock(side_effect=OSError(errno.EPERM, 'no hard links on this volume'))
        err = io.StringIO()
        with patch.object(roots, 'os', nt), posix_link, patch.object(roots, 'refs_same_volume', return_value=False), \
             patch.object(roots, 'copy_file', wraps=roots.copy_file) as copied, contextlib.redirect_stderr(err):
            self.store._copy_tree(src, self.home / 'copied', hardlink=True)
        self.assertEqual(copied.call_count, 3)
        self.assertEqual(nt.link.call_count, 1)
        self.assertIn('硬链接不可用', err.getvalue())
        for rel, data in files.items():
            self.assertEqual((self.home / 'copied' / rel).read_bytes(), data)
            self.assertFalse(os.path.samefile(src / rel, self.home / 'copied' / rel))

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
    def test_junction_fallback(self):
        a = self.home / 'a'
        a.mkdir()
        (a / 'file').write_bytes(b'A')
        with patch.object(roots.os, 'symlink', side_effect=OSError(1314, 'no privilege')):
            roots.directory_link(a, self.home / 'romfs')
        self.assertTrue((self.home / 'romfs').is_junction())
        self.assertEqual((self.home / 'romfs/file').read_bytes(), b'A')

    def test_prune_keeps_current_previous(self):
        self.seed()
        for tag in ('v2', 'v3', 'v4'):
            self.store.begin('原创', tag).commit()
        names = sorted(p.name for p in self.store.path.glob('原创@*') if p.is_dir())
        self.assertEqual(names, ['原创@v3', '原创@v4'])

    def test_prune_failure_does_not_fail_commit(self):
        # D-GGG5：新版本已提交、指针已写，prune 删旧版本时 Windows 删除挂起（WinError 145，重试后仍删不掉）。期望（手写）：
        #   commit 照常返回新版本、现行指针指向它；删不掉的那份留着，下次 prune 再删；错误只在 stderr 说一句黄
        self.seed()
        for tag in ('v2', 'v3'):
            self.store.begin('原创', tag).commit()
        real = roots.remove_owned
        def stuck(p):
            if Path(p).name == '原创@v2':
                raise OSError(errno.ENOTEMPTY, '目录不是空的。', str(p))
            return real(p)
        err = io.StringIO()
        with patch.object(roots, 'remove_owned', side_effect=stuck), contextlib.redirect_stderr(err):
            final = self.store.begin('原创', 'v4').commit()
        self.assertEqual(final.name, '原创@v4')
        self.assertEqual(self.store.cur('原创', pin=False).name, '原创@v4')
        self.assertIn('原创@v2', sorted(p.name for p in self.store.path.glob('原创@*') if p.is_dir()), '删不掉的留着')
        self.assertIn('【黄】旧版本没删干净', err.getvalue())
        self.store.begin('原创', 'v5').commit()   # 下次 prune 删得掉了就删
        self.assertEqual(sorted(p.name for p in self.store.path.glob('原创@*') if p.is_dir()), ['原创@v4', '原创@v5'])

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
    """现行指针的自愈（v0.3.1）。期望手写：
    ① 现行指针丢了（被删 / 换版本中途被杀在写指针之前）：cur() 取最新的已提交版本重写指针，内容是那一版；没有任何版本时照旧 None
    ② 写指针那一步失败：现行还是旧版（已有用例 test_failed_activation_leaves_current）；之后再提交照常"""
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
        self.assertEqual(live.read_text(encoding='utf-8'), '原创@v2\n'); self.assertEqual(cur.name, '原创@v2'); self.assertEqual((cur / 'f').read_bytes(), b'2')


class PlainRootsTest(unittest.TestCase):
    """实目录模式（v0.3.1：游戏库 / 存放位置在 exFAT / FAT32 上，卷上建不了目录链接；S2A_ROOTS_PLAIN=1 在 Mac 上走同一条）。期望手写：
    ① 现行与别的卷一样是指针文件、版本是 <款>@<标签> 真目录，不再把现行目录改名来改名去；romfs 留在版本里、不建 .romfs_store
    ② 两个事务从同一现行起，先提交的赢，后提交的没声明重放就 Conflict
    ③ 声明了重放：两边的改动都在
    ④ 写指针失败：现行还是旧版；现行指针被删：按最新的已提交版本自愈
    ⑤ prune 留现行 + 上一版，更早的删掉
    ⑥ 播种 move_romfs：不把原处 romfs 整个搬走（搬走后原处没法留联接），原处还在、现行里有一份
    ⑦ 老实目录模式留下的状态：现行是真目录（.root_tag 记版本名）→ 第一次取现行改成版本目录 + 指针；
       旧码换版本中途被杀（旧现行已停回 <款>@seed、新版本还在 <款>@next.tmp 且 .root_tag = 原创@next、没有现行）→ 换上 原创@next"""
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

    def test_current_is_pointer_and_versions_stay(self):
        self.assertTrue(self.store.plain)
        first = self.commit('seed', {'exefs/main': b'm1', 'romfs/data': b'r1'})
        live = self.store.path / '原创@现行'
        self.assertEqual(first, self.store.path / '原创@seed'); self.assertEqual(live.read_text(encoding='utf-8'), '原创@seed\n')
        second = self.commit('next', {'exefs/main': b'm2'})
        self.assertEqual(self.store.cur('原创'), second); self.assertEqual(live.read_text(encoding='utf-8'), '原创@next\n')
        self.assertEqual((second / 'exefs/main').read_bytes(), b'm2'); self.assertEqual((second / 'romfs/data').read_bytes(), b'r1')
        self.assertEqual((first / 'exefs/main').read_bytes(), b'm1')
        self.assertFalse(roots.is_link(second / 'romfs')); self.assertFalse((self.home / 'roots' / '.romfs_store').exists())

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

    def test_failed_pointer_write_keeps_current(self):
        first = self.commit('seed', {'exefs/main': b'm1'})
        tx = self.store.begin('原创', 'next')
        with patch.object(roots.curptr, 'write', side_effect=OSError('write denied')), self.assertRaises(OSError):
            tx.commit()
        self.assertEqual(self.store.cur('原创'), first); self.assertEqual((first / 'exefs/main').read_bytes(), b'm1')

    def test_prune_keeps_current_and_previous(self):
        for i in range(4):
            self.commit(f'v{i}', {'exefs/main': str(i).encode()})
            time.sleep(0.01)
        names = sorted(p.name for p in (self.home / 'roots').glob('原创@*') if p.is_dir())
        self.assertEqual(names, ['原创@v2', '原创@v3'])

    def test_missing_current_heals_to_newest(self):
        self.commit('v1', {'f': b'1'}); time.sleep(0.01); self.commit('v2', {'f': b'2'})
        live = self.store.path / '原创@现行'
        live.unlink()
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            cur = self.store.cur('原创')
        self.assertEqual(cur.name, '原创@v2'); self.assertEqual((cur / 'f').read_bytes(), b'2')
        self.assertEqual(live.read_text(encoding='utf-8'), '原创@v2\n')

    def test_legacy_plain_current_migrates(self):
        legacy = self.store.path / '原创@现行'
        (legacy / 'exefs').mkdir(parents=True); (legacy / 'exefs/main').write_bytes(b'live')
        roots.text(legacy / '.root_tag', '原创@seed\n')
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            cur = self.store.cur('原创')
        self.assertEqual(cur, self.store.path / '原创@seed'); self.assertEqual((cur / 'exefs/main').read_bytes(), b'live')
        self.assertFalse((cur / '.root_tag').exists()); self.assertEqual(legacy.read_text(encoding='utf-8'), '原创@seed\n')
        second = self.commit('next', {'exefs/main': b'm2'})
        self.assertEqual(self.store.cur('原创'), second); self.assertEqual((cur / 'exefs/main').read_bytes(), b'live')

    def test_legacy_killed_between_two_renames_heals_to_new_version(self):
        parked = self.store.path / '原创@seed'; (parked / 'exefs').mkdir(parents=True); (parked / 'exefs/main').write_bytes(b'm1')
        pending = self.store.path / '原创@next.tmp'; (pending / 'exefs').mkdir(parents=True); (pending / 'exefs/main').write_bytes(b'm2')
        roots.text(pending / '.root_tag', '原创@next\n')
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            cur = self.store.cur('原创')
        self.assertEqual(cur, self.store.path / '原创@next'); self.assertEqual((cur / 'exefs/main').read_bytes(), b'm2')
        self.assertFalse(pending.exists()); self.assertEqual((parked / 'exefs/main').read_bytes(), b'm1')

    def test_seed_does_not_move_romfs_away(self):
        from pack.orch import refresh
        src = self.home / 'ex'; (src / 'exefs').mkdir(parents=True); (src / 'exefs/main').write_bytes(b'm')
        (src / 'romfs').mkdir(); (src / 'romfs/a').write_bytes(b'r'); (src / 'unpack.tsv').write_text('title_id\t0100aaaa00000000\n')
        with patch.dict(os.environ, {'S2A_DUAL': '0'}):
            cur = refresh.seed(self.store, '原创', src, move_romfs=True)
        self.assertEqual((src / 'romfs/a').read_bytes(), b'r'); self.assertFalse(roots.is_link(src / 'romfs'))
        self.assertEqual((cur / 'romfs/a').read_bytes(), b'r')


class FailedSymlinkStubTest(unittest.TestCase):
    # #1431：玩家 Windows（26300、库在 ReFS 开发驱动器、没开开发者模式）上 os.symlink 报失败时 link 处已经留下了东西，
    #   junction 退路随即 mkdir 撞 WinError 183，播种每次都红；撤回时 remove_owned 又删不掉这份残留，abort 报「目录不是空的」。期望手写：
    #   ① nt（模拟）：软链失败前 link 不在、失败后在 → 删掉残留再走退路，退路建链时 link 不在；软链前 link 已经在 → 不删，照原样把错误交给退路
    #   ② remove_owned：在、但既不是链接也不是文件 / 目录的残留 → 删掉，上一级能删空
    #   ③ 原生 Windows：软链失败并留下空目录 → 照样建成 junction，经它读到目标里的文件
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-1431-'); self.home = Path(self.temp.name)
        (self.home / 'target').mkdir(); (self.home / 'target/f').write_bytes(b'T')

    def tearDown(self): self.temp.cleanup()

    def stub_symlink(self, src, dst, target_is_directory=False):   # 失败但留下一个空目录（玩家机上看到的样子）
        os.mkdir(dst)
        e = OSError(22, '客户端没有所需的特权。'); e.winerror = 1314; raise e

    def run_nt(self, link):
        fake = _Os('nt'); fake.symlink = self.stub_symlink; seen = []
        def junction(target, at):   # 同 _junction 第一步：link.mkdir()，已在就是 WinError 183
            seen.append(os.path.lexists(at)); Path(at).mkdir()
        with patch.object(roots, 'os', fake), patch.object(roots, 'table_now', return_value=[]), \
             patch.object(roots, '_junction', junction), contextlib.redirect_stderr(io.StringIO()):
            roots.directory_link(self.home / 'target', link)
        return seen

    def test_nt_removes_stub_left_by_failed_symlink(self):
        self.assertEqual(self.run_nt(self.home / 'link'), [False])

    def test_nt_existing_link_path_is_not_removed(self):
        (self.home / 'link').mkdir(); (self.home / 'link/keep').write_bytes(b'K')
        with self.assertRaises(FileExistsError):
            self.run_nt(self.home / 'link')
        self.assertEqual((self.home / 'link/keep').read_bytes(), b'K')

    def test_remove_owned_removes_unknown_stub(self):
        box = self.home / 'box'; box.mkdir(); (box / 'stub').mkdir()
        real_lexists = os.path.lexists
        with patch.object(roots, 'is_link', lambda p: False), \
             patch.object(Path, 'is_dir', lambda p: False if p.name == 'stub' else os.path.isdir(p)), \
             patch.object(Path, 'exists', lambda p: False if p.name == 'stub' else real_lexists(p)):
            roots.remove_owned(box)
        self.assertFalse(real_lexists(box))

    # #0fd185（0.5.8 照中，#1431 修复已在）：软链报 WinError 2 后留下的那一项 os.path.lexists 认不出（它遇到任何 OSError 都答「不在」），
    #   「失败后多出来的先删」没删，junction 退路 mkdir 撞 WinError 183。期望手写：
    #   ④ nt（模拟）：残留在、lexists 对它答「不在」→ 照样删掉再走退路，退路建链时 link 不在；日志点名留下了一项
    #   ⑤ remove_owned：残留让 is_link 抛 OSError、lexists 答「不在」→ 照样删掉，上一级能删空
    def stub_symlink_enoent(self, src, dst, target_is_directory=False):   # 0.5.8 玩家机：WinError 2，链接处留下一项
        os.mkdir(dst)
        e = FileNotFoundError(2, '系统找不到指定的文件。'); e.winerror = 2; raise e

    def test_nt_removes_stub_lexists_cannot_see(self):
        link = self.home / 'link'
        fake = _Os('nt'); fake.symlink = self.stub_symlink_enoent; seen = []
        real = os.path
        fake.path = type('P', (), {'__getattr__': lambda _s, k: getattr(real, k),
                                   'lexists': staticmethod(lambda p: False if Path(p).name == 'link' else real.lexists(p))})()
        def junction(target, at):
            seen.append(real.lexists(at)); Path(at).mkdir()
        err = io.StringIO()
        with patch.object(roots, 'os', fake), patch.object(roots, 'table_now', return_value=[]), \
             patch.object(roots, '_junction', junction), contextlib.redirect_stderr(err):
            roots.directory_link(self.home / 'target', link)
        self.assertEqual(seen, [False])
        self.assertIn('留下了一项', err.getvalue())

    def test_remove_owned_removes_stub_lstat_cannot_read(self):
        box = self.home / 'box'; box.mkdir(); (box / 'stub').mkdir()
        real_lexists = os.path.lexists
        def is_link(p):
            if Path(p).name == 'stub':
                e = OSError(22, '无法访问此文件'); e.winerror = 1920; raise e
            return False
        with patch.object(roots, 'is_link', is_link), \
             patch.object(Path, 'is_dir', lambda p: False if p.name == 'stub' else os.path.isdir(p)), \
             patch.object(Path, 'exists', lambda p: False if p.name == 'stub' else real_lexists(p)), \
             patch.object(os.path, 'lexists', lambda p: False if Path(p).name == 'stub' else real_lexists(p)):
            roots.remove_owned(box)
        self.assertFalse(real_lexists(box))

    @unittest.skipUnless(os.name == 'nt', 'native Windows junction fallback')
    def test_native_junction_after_stub(self):
        link = self.home / 'link'
        with patch.object(roots.os, 'symlink', self.stub_symlink), contextlib.redirect_stderr(io.StringIO()):
            roots.directory_link(self.home / 'target', link)
        self.assertTrue(link.is_junction())
        self.assertEqual((link / 'f').read_bytes(), b'T')


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
            roots.directory_link(short / 'roots' / '.romfs_store' / 'g' / 'id', short / 'roots' / 'g@v1' / 'romfs', relative='../.romfs_store/g/id')
        value = fake.symlink.call_args.args[0]
        self.assertEqual(value, os.path.normpath(str(long / 'roots' / '.romfs_store' / 'g' / 'id')))
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
