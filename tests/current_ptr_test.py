# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/current.py pack/orch/roots.py
"""现行指针文件（pack/orch/current.py；玩家诊断 #0fd185：Windows NTFS 上软链、junction 都报 WinError 5，现行改成普通文件）。期望值全部手写：
① 读写：write 后文件内容就是「版本目录名 + 换行」；空、带路径、指向不在的目录、指向 .tmp / .tmp.rb、别的款、「现行」本身、多行 → read 当没有现行；
  write 拒绝这些坏值且不动原指针
② 老库迁移：软链 → 指针文件（版本目录原样）；实目录模式的真目录 → 按 .root_tag 改名成版本目录 + 指针文件（没记 / 名字被占 → 新名字，内容不丢）
③ 迁移在每个中间状态断掉（只写了临时指针 / 旧链接或旧目录已改名、新指针还没就位 / 新指针已就位、旧链接或 .root_tag 没删），
  再取一次现行：结果都是原来那一版、版本目录一个不少；之后 normalize（修剪 / 取现行时做）收掉残留
④ 并发：另一个进程反复真提交（Roots 事务）切现行，读方同时反复取现行，每次都拿到某个完整的已提交版本（读出的名字就是目录里记的名字）
⑤ Roots.cur 走迁移：老软链库第一次取现行就成指针文件；指针坏了（指向被删的版本）按最新的已提交版本自愈
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.orch import current, roots   # noqa: E402


class Stop(Exception):
    """模拟进程在这一步被杀"""


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-curptr-')
        self.root = Path(self.temp.name) / 'roots'
        self.root.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def version(self, name, mark=None):
        d = self.root / name
        d.mkdir()
        (d / 'mark').write_text(mark or name)
        return d

    def names(self):
        return sorted(p.name for p in self.root.iterdir())


class ReadWriteTest(Base):
    def test_write_then_read(self):
        v = self.version('g@v1')
        current.write(self.root, 'g', 'g@v1')
        p = self.root / 'g@现行'
        self.assertTrue(p.is_file() and not p.is_symlink())
        self.assertEqual(p.read_bytes(), 'g@v1\n'.encode())
        self.assertEqual(current.read(self.root, 'g'), v)
        self.assertEqual(self.names(), ['g@v1', 'g@现行'])   # 临时指针没留下

    def test_bad_values_read_as_none(self):
        self.version('g@v1'); self.version('g@w_x.tmp'); self.version('g@w_x.tmp.rb'); self.version('h@v1')
        (self.root / 'sub').mkdir(); self.version('sub/g@v1')
        p = self.root / 'g@现行'
        for raw in ('', '\n', 'sub/g@v1\n', '../roots/g@v1\n', 'g@v1/\n', 'g@v1\\x\n', 'g@gone\n', 'g@w_x.tmp\n', 'g@w_x.tmp.rb\n',
                    'h@v1\n', 'g@现行\n', 'g@\n', 'g@v1\ng@v1\n', 'v1\n'):
            p.write_text(raw, encoding='utf-8')
            self.assertIsNone(current.read(self.root, 'g'), repr(raw))
        p.write_text('g@v1\r\n', encoding='utf-8')   # Windows 记事本存的换行也认
        self.assertEqual(current.read(self.root, 'g'), self.root / 'g@v1')

    def test_version_link_is_not_a_version(self):
        self.version('g@v1')
        os.symlink('g@v1', self.root / 'g@alias')
        (self.root / 'g@现行').write_text('g@alias\n')
        self.assertIsNone(current.read(self.root, 'g'))

    def test_write_rejects_bad_and_keeps_old(self):
        self.version('g@v1'); self.version('g@w_x.tmp')
        current.write(self.root, 'g', 'g@v1')
        for bad in ('', 'g@gone', 'g@w_x.tmp', 'sub/g@v1', 'g@现行', 'h@v1'):
            with self.assertRaises(ValueError):
                current.write(self.root, 'g', bad)
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@v1\n')
        self.assertEqual(self.names(), ['g@v1', 'g@w_x.tmp', 'g@现行'])

    def test_missing_is_none(self):
        self.assertIsNone(current.read(self.root, 'g'))
        self.assertIsNone(current.resolve(self.root, 'g'))


class MigrateTest(Base):
    def test_symlink_becomes_pointer(self):
        self.version('g@v1'); self.version('g@v0')
        os.symlink('g@v1', self.root / 'g@现行')
        self.assertEqual(current.resolve(self.root, 'g'), self.root / 'g@v1')
        p = self.root / 'g@现行'
        self.assertFalse(p.is_symlink()); self.assertEqual(p.read_text(), 'g@v1\n')
        self.assertEqual(self.names(), ['g@v0', 'g@v1', 'g@现行'])
        self.assertEqual((self.root / 'g@v1/mark').read_text(), 'g@v1')

    def test_absolute_symlink_becomes_pointer(self):
        self.version('g@v1')
        os.symlink(self.root / 'g@v1', self.root / 'g@现行')
        self.assertEqual(current.resolve(self.root, 'g'), self.root / 'g@v1')
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@v1\n')

    def test_dangling_symlink_is_dropped(self):
        os.symlink('g@gone', self.root / 'g@现行')
        self.assertIsNone(current.resolve(self.root, 'g'))
        self.assertEqual(self.names(), [])

    def test_plain_dir_becomes_version_and_pointer(self):
        d = self.version('g@现行', 'content-seed')
        (d / '.root_tag').write_text('g@seed\n')
        self.version('g@old')
        self.assertEqual(current.resolve(self.root, 'g'), self.root / 'g@seed')
        self.assertEqual(self.names(), ['g@old', 'g@seed', 'g@现行'])
        self.assertEqual((self.root / 'g@seed/mark').read_text(), 'content-seed')
        self.assertFalse((self.root / 'g@seed/.root_tag').exists())
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@seed\n')

    def test_plain_dir_name_taken_or_missing(self):
        d = self.version('g@现行', 'live')
        (d / '.root_tag').write_text('g@seed\n')
        self.version('g@seed', 'parked')   # 记的名字被占：不能覆盖那一版
        self.assertEqual(current.resolve(self.root, 'g'), self.root / 'g@seed-2')
        self.assertEqual(((self.root / 'g@seed/mark').read_text(), (self.root / 'g@seed-2/mark').read_text()), ('parked', 'live'))
        other = self.version('k@现行', 'k-live')   # 没记版本名
        found = current.resolve(self.root, 'k')
        self.assertTrue(found.name.startswith('k@recovered-'), found.name)
        self.assertEqual((found / 'mark').read_text(), 'k-live')
        self.assertFalse(other.exists() and other.is_dir())


class InterruptTest(Base):
    """在迁移的每一步「被杀」（抛 Stop），再取一次现行"""
    def run_until(self, step, fn='rename'):
        calls = {'rename': 0, 'replace': 0, 'unlink': 0}
        real = {'rename': os.rename, 'replace': os.replace, 'unlink': os.unlink}

        def wrap(name):
            def f(*a, **k):
                calls[name] += 1
                if name == step[0] and calls[name] == step[1]:
                    raise Stop(name)
                return real[name](*a, **k)
            return f
        with patch.object(current.os, 'rename', wrap('rename')), patch.object(current.os, 'replace', wrap('replace')), \
             patch.object(current.os, 'unlink', wrap('unlink')), self.assertRaises(Stop):
            current.normalize(self.root, 'g', log=lambda m: None)

    def link_case(self, step, left):
        self.version('g@v1'); self.version('g@v0')
        os.symlink('g@v1', self.root / 'g@现行')
        self.run_until(step)
        self.assertTrue(any(n.startswith(left) for n in self.names()), (left, self.names()))   # 断在了想要的中间状态
        self.assertEqual(current.resolve(self.root, 'g'), self.root / 'g@v1')
        self.assertEqual((self.root / 'g@v1/mark').read_text(), 'g@v1'); self.assertTrue((self.root / 'g@v0').is_dir())
        self.assertTrue(current.normalize(self.root, 'g', log=lambda m: None))
        self.assertEqual(self.names(), ['g@v0', 'g@v1', 'g@现行'])
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@v1\n')

    def test_link_only_temp_written(self):            # 写了临时指针、旧链接还没改名
        self.link_case(('rename', 1), '.g@现行.new-')

    def test_link_moved_aside_pointer_not_placed(self):   # 旧链接已改名到旁边、新指针还没就位
        self.link_case(('replace', 1), 'g@现行.migr-')

    def test_link_pointer_placed_aside_not_removed(self):   # 新指针已就位、旧链接没删
        self.link_case(('unlink', 1), 'g@现行.migr-')

    def test_link_moved_aside_and_temp_lost(self):    # 旧链接在旁边、临时指针也没了：从旧链接恢复
        self.version('g@v1')
        os.symlink('g@v1', self.root / 'g@现行')
        self.run_until(('replace', 1))
        for t in self.root.glob('.g@现行.new-*'):
            t.unlink()
        self.assertEqual(current.resolve(self.root, 'g'), self.root / 'g@v1')
        self.assertEqual(self.names(), ['g@v1', 'g@现行'])

    def plain_case(self, step, want_names_mid):
        d = self.version('g@现行', 'live'); (d / '.root_tag').write_text('g@seed\n')
        self.version('g@old', 'old')
        self.run_until(step)
        self.assertEqual([n for n in self.names() if not n.startswith('.g@现行.new-')], want_names_mid)
        found = current.resolve(self.root, 'g')
        self.assertEqual((found / 'mark').read_text(), 'live')
        self.assertEqual((self.root / 'g@old/mark').read_text(), 'old')
        current.normalize(self.root, 'g', log=lambda m: None)
        self.assertEqual(self.names(), ['g@old', found.name, 'g@现行'])

    def test_plain_only_temp_written(self):            # 写了临时指针、目录还没改名（被杀不走 normalize 出错时删临时指针那一支：手搭这个状态）
        d = self.version('g@现行', 'live'); (d / '.root_tag').write_text('g@seed\n')
        self.version('g@old', 'old')
        (self.root / '.g@现行.new-killed').write_text('g@seed\n')   # 内容指向还不存在的 g@seed：不合规、不能拿来用
        found = current.resolve(self.root, 'g')
        self.assertEqual((found.name, (found / 'mark').read_text()), ('g@seed', 'live'))
        self.assertEqual(self.names(), ['g@old', 'g@seed', 'g@现行'])

    def test_plain_renamed_pointer_not_placed(self):   # 目录已改名成版本、指针还没就位
        self.plain_case(('replace', 1), ['g@old', 'g@seed'])

    def test_plain_pointer_placed_tag_not_removed(self):   # 指针已就位、.root_tag 没删
        self.plain_case(('unlink', 1), ['g@old', 'g@seed', 'g@现行'])


class ConcurrentTest(Base):
    def test_reader_sees_whole_committed_version(self):
        """写方另起进程：Roots 真事务反复提交（每版写 id = 自己的版本名），不修剪（修剪是留存规则，与切换无关）。
        读方同时反复取现行：每次都有现行、读到的 id 就是指针里的名字。分母：读的次数、见到的不同版本数都要够"""
        store = roots.Roots(self.root, shared=False)
        tx = store.begin('g', 'v0'); (tx.path / 'id').write_text('g@v0'); tx.commit()
        writer = textwrap.dedent(f'''
            import sys, time
            sys.path.insert(0, {str(Path(__file__).resolve().parents[1])!r})
            from pack.orch import roots
            roots.Roots.prune = lambda self, game: None
            store = roots.Roots({str(self.root)!r}, shared=False)
            end = time.monotonic() + 6
            i = 0
            while time.monotonic() < end:
                i += 1
                tx = store.begin('g', f'v{{i}}')
                (tx.path / 'id').write_text(f'g@v{{i}}')
                tx.commit()
            print(i)
        ''')
        p = subprocess.Popen([sys.executable, '-c', writer], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             env=dict(os.environ, S2A_ROOTS_NO_BOOT='1'))
        reads, seen, bad = 0, set(), []
        while p.poll() is None:
            d = current.read(self.root, 'g')
            if d is None:
                bad.append('没有现行')
                continue
            got = (d / 'id').read_text()
            reads += 1; seen.add(got)
            if got != d.name:
                bad.append(f'{d.name} 里记的是 {got}')
        out, err = p.communicate()
        print(f'并发：写方提交 {out.strip()} 次，读方读 {reads} 次、见到 {len(seen)} 个不同版本、错 {len(bad)} 次', file=sys.stderr)
        self.assertEqual(p.returncode, 0, err)
        self.assertEqual(bad, [])
        self.assertGreater(int(out), 5, '写方提交次数')
        self.assertGreater(reads, 100, '读的次数')
        self.assertGreater(len(seen), 3, '读方见到的不同版本数')


class RootsCurTest(Base):
    def test_legacy_link_store_migrates_on_cur(self):
        store = roots.Roots(self.root, shared=False)
        tx = store.begin('g', 'v1'); (tx.path / 'id').write_text('1'); first = tx.commit()
        (self.root / 'g@现行').unlink()
        os.symlink('g@v1', self.root / 'g@现行')   # 改动前的形式
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            self.assertEqual(store.cur('g', pin=False), first)
            self.assertFalse((self.root / 'g@现行').is_symlink())
            tx = store.begin('g', 'v2'); (tx.path / 'id').write_text('2'); second = tx.commit()
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@v2\n')
        self.assertEqual(((second / 'id').read_text(), (first / 'id').read_text()), ('2', '1'))

    def test_dangling_pointer_heals_to_newest(self):
        store = roots.Roots(self.root, shared=False)
        for tag in ('v1', 'v2'):
            tx = store.begin('g', tag); (tx.path / 'id').write_text(tag); tx.commit(); time.sleep(0.01)
        (self.root / 'g@现行').write_text('g@gone\n')
        with patch.dict(os.environ, {'S2A_ROOTS_NO_BOOT': '1'}):
            self.assertEqual(store.cur('g', pin=False), store.path / 'g@v2')
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@v2\n')

    def test_commit_holding_lock_migrates_without_deadlock(self):
        store = roots.Roots(self.root, shared=False)
        tx = store.begin('g', 'v1'); tx.commit()
        nxt = store.begin('g', 'v2')
        (self.root / 'g@现行').unlink(); os.symlink('g@v1', self.root / 'g@现行')   # 开工后、提交前现行变回老形式
        nxt.commit()   # 提交持锁取现行：迁移不再拿同一把锁
        self.assertEqual((self.root / 'g@现行').read_text(), 'g@v2\n')


if __name__ == '__main__':
    unittest.main()
