# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Cleanup must unlink entries without following them into player data."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import Failure
import layout
import library


class CleanupLinkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="s2arm synthetic cleanup ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.c = SimpleNamespace(library=self.root / "library", work_root=self.root / "work")
        self.gid = "0100000000000000"
        self.c.library.mkdir()
        self.output = layout.ios_work(self.c, self.gid)   # 这款文件夹的出包工作目录 build/ios
        self.output.mkdir(parents=True)

    def payload(self, parent):
        parent.mkdir(parents=True, exist_ok=True)
        path = parent / "synthetic.txt"
        path.write_bytes(b"player data must survive")
        return path

    def test_prune_unlinks_intermediates_without_deleting_their_targets(self):
        for retain in (True, False):
            for target in (layout.path(self.c, self.gid, "saves"), self.root / "outside"):
                with self.subTest(retain_compiler=retain, target=target.name):
                    payload = self.payload(target)
                    self.output.mkdir(parents=True, exist_ok=True)   # 上一轮清理把 build/ 整个删了
                    link = self.output / "intermediate"
                    link.unlink(missing_ok=True)
                    link.symlink_to(target, target_is_directory=True)
                    library.prune_build(self.c, self.gid, retain_compiler=retain)
                    self.assertEqual(payload.read_bytes(), b"player data must survive")
                    self.assertFalse(link.is_symlink())

    def test_direct_cache_on_game_volume_no_cross_root_error(self):
        # #754：游戏库和数据目录不在一块盘时，直连缓存跟着游戏放在这款文件夹的 direct-cache（不在工具缓存下）。
        #   原先查「沿途没有链接」一律从工具缓存起算，relative_to 抛 ValueError，出包失败后的清理整个没做；期望照常列出可删的中间件并删掉
        self.c.work_root.mkdir()
        direct = layout.path(self.c, self.gid, "direct-cache"); (direct / "work").mkdir(parents=True); (direct / "store").mkdir()
        got = library.direct_transients(self.c, direct)
        self.assertEqual(got, [direct / "work"])
        self.assertTrue(library._rm_direct_transient(self.c, direct, direct / "work"))
        self.assertFalse((direct / "work").exists()); self.assertTrue((direct / "store").is_dir())

    def test_stage_logs_include_windows_work_logs(self):
        # #754：Windows 一键出包各步日志（seed.log 等）写在 build/ios/work 下，失败后随 build/ 删掉、诊断包里没有；期望拷进 <任务>-stages
        logs = self.root / "logs"; self.c.logs = logs; self.c.task = "t1"
        (self.output / "work").mkdir(); (self.output / "work" / "seed.log").write_text("OSError: [WinError 145] 原错误\n", encoding="utf-8")
        library._keep_stage_logs(self.c, self.gid)
        self.assertEqual((logs / "t1-stages" / "seed.log").read_text(encoding="utf-8"), "OSError: [WinError 145] 原错误\n")

    def seed_root(self, root):
        (root / "ctl").mkdir(parents=True); (root / "programs/1").mkdir(parents=True); (root / "romfs").mkdir(); (root / ".stage_pkg").mkdir()
        for name in ("main.npdm", "main.fixups.tsv", "main.gates.tsv", "main.patched.bin", "icon.jpg", "romfs.s2aidx", "build.log", ".root_src", "ctl/control.nacp",
                     "programs/1/main.npdm", "programs/1/main.fixups.tsv", "programs/1/main.patched.bin", "romfs/huge.bin"):
            (root / name).write_bytes(name.encode())

    def test_container_kit_keeps_only_what_assembly_reads(self):
        root = self.root / "product"; self.seed_root(root)
        kit = library.save_container_kit(self.c, self.gid, root)
        self.assertEqual(sorted(p.relative_to(kit).as_posix() for p in kit.rglob("*") if p.is_file()),
                         sorted(["main.npdm", "main.fixups.tsv", "main.gates.tsv", "main.patched.bin", "icon.jpg", "romfs.s2aidx", "ctl/control.nacp",
                                 "programs/1/main.npdm", "programs/1/main.fixups.tsv", "programs/1/main.patched.bin"]))
        self.assertIsNone(library.save_container_kit(self.c, self.gid, self.root / "missing"))
        self.assertTrue((kit / "main.npdm").is_file())   # 产物根不完整时不动旧的

    def test_success_prune_removes_roots_and_unpack_but_keeps_delivery(self):
        root = self.output / "roots" / "k@pkg"; self.seed_root(root)
        image = layout.image_ios(self.c, self.gid)
        pack = image / "pack"; pack.mkdir(parents=True); (pack / "index.tsv").write_bytes(b"i"); (pack / "manifest.json").write_text("{}")
        (self.output / "logs").mkdir(); (self.output / "logs" / "refresh.log").write_text("l"); (self.output / "work").mkdir()
        unpacked = layout.build_dir(self.c, self.gid); (unpacked / "x").write_bytes(b"x")
        library.save_container_kit(self.c, self.gid, root)
        library.prune_build(self.c, self.gid)
        self.assertEqual(sorted(p.name for p in image.iterdir()), ["kit", "pack"])   # 交付件（容器件、资源包）在 image/ios，不动
        self.assertEqual(sorted(p.relative_to(unpacked).as_posix() for p in unpacked.rglob("*")), ["ios", "ios/logs", "ios/logs/refresh.log"])   # 解包、产物根、work 清掉，出包日志留

    def test_without_kit_prune_keeps_current_root(self):
        root = self.output / "roots" / "k@pkg"; self.seed_root(root)
        (self.output / "roots" / "k@现行").symlink_to("k@pkg")
        pack = layout.image_ios(self.c, self.gid) / "pack"; pack.mkdir(parents=True); (pack / "manifest.json").write_text("{}")   # 老玩家：有资源包没容器件
        library.prune_build(self.c, self.gid)
        self.assertTrue((self.output / "roots" / "k@pkg" / "main.npdm").is_file())

    def test_unlinks_file_and_dangling_links_without_following_them(self):
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        for target in (payload, self.root / "missing"):
            with self.subTest(target=target.name):
                link = self.output / "scratch"
                link.unlink(missing_ok=True)
                payload.write_bytes(b"player data must survive")
                link.symlink_to(target)
                library._rm(self.c, self.c.library, link)
                self.assertFalse(link.is_symlink())
                self.assertEqual(payload.read_bytes(), b"player data must survive")

    def test_refuses_a_symlink_in_an_ancestor(self):
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        link = self.output / "intermediate"
        link.symlink_to(payload.parent, target_is_directory=True)
        with self.assertRaises(Failure):
            library._rm(self.c, self.c.library, link / payload.name)
        self.assertEqual(payload.read_bytes(), b"player data must survive")

    def test_refuses_root_and_outside_entries_but_removes_ordinary_scratch(self):
        outside = self.payload(self.root / "outside")
        for path in (self.c.library, outside):
            with self.subTest(path=path.name), self.assertRaises(Failure):
                library._rm(self.c, self.c.library, path)
        scratch = self.payload(self.output / "scratch")
        library._rm(self.c, self.c.library, scratch.parent)
        self.assertFalse(scratch.parent.exists())
        self.assertEqual(outside.read_bytes(), b"player data must survive")

    @unittest.skipUnless(os.name == "nt", "Windows junction requires Windows")
    def test_junction_is_removed_without_deleting_its_target(self):
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        junction = self.output / "intermediate"
        subprocess.run(["cmd", "/c", "mklink", "/J", str(junction), str(payload.parent)],
                       check=True, capture_output=True)
        with self.assertRaises(Failure):
            library._rm(self.c, self.c.library, junction / payload.name)
        library.prune_build(self.c, self.gid)
        self.assertFalse(junction.exists())
        self.assertEqual(payload.read_bytes(), b"player data must survive")


class SharingViolationRetryTests(unittest.TestCase):
    """#cdec0e：Windows 删旧解包目录时文件被杀毒 / 索引短暂占着（WinError 32）。统一删除对同一项隔一会儿重删。期望手写（间隔表 6 档）：
    ① 前两次占着、第三次放了 → 睡 2 次（0.1、0.2）后删成，不抛；② 一直占着 → 睡满 6 次后抛最后那个 WinError 32；
    ③ 不是 32 的错（如拒绝访问 5）→ 一次不睡、原样抛"""
    def busy(self, code=32):
        e = PermissionError(13, "另一个程序正在使用此文件，进程无法访问。"); e.winerror = code
        return e

    def test_released_after_two_tries(self):
        slept, calls = [], []
        def func(path):
            calls.append(path)
            if len(calls) < 2:
                raise self.busy()
        library._retry_shared(func, "x", self.busy(), sleep=slept.append)
        self.assertEqual((slept, calls), ([0.1, 0.2], ["x", "x"]))

    def test_still_busy_raises_last_error(self):
        slept = []
        def func(path):
            raise self.busy()
        with self.assertRaises(PermissionError) as e:
            library._retry_shared(func, "x", self.busy(), sleep=slept.append)
        self.assertEqual((len(slept), e.exception.winerror), (6, 32))

    def test_other_error_not_retried(self):
        slept = []
        with self.assertRaises(PermissionError) as e:
            library._retry_shared(lambda path: None, "x", self.busy(5), sleep=slept.append)
        self.assertEqual((slept, e.exception.winerror), ([], 5))


if __name__ == "__main__":
    unittest.main()


class RemoveWhileSomethingWritesTests(unittest.TestCase):
    """#369：游戏库在外置盘，删的同时访达往正在删的目录写 .DS_Store，shutil.rmtree 报 Errno 66（目录非空）。期望手写：
    ① 第一次删目标目录时被塞进一个 .DS_Store（模拟访达）→ 统一删除 library._rmtree 清掉系统文件再删，整棵删干净；
    ② 塞进的是普通文件（真有程序在写）→ 不硬删：报 ENOTEMPTY，原文点名剩下的那个文件，目录还在；
    ③ _rmdir_past_os_junk 直接调：只剩 .DS_Store / ._x / desktop.ini 的目录 → 删掉"""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="s2arm enotempty ")
        self.root = Path(self.temp.name) / "extract"
        (self.root / "romfs" / "sub").mkdir(parents=True)
        for name in ("a.bin", "romfs/b.bin", "romfs/sub/c.bin"):
            (self.root / name).write_bytes(b"x")

    def tearDown(self):
        self.temp.cleanup()

    def injected(self, name):
        """os.rmdir 换桩：第一次删 romfs 目录（shutil 按目录句柄删时只给名字「romfs」）之前往里塞一个文件，模拟删的同时有程序写入"""
        from unittest import mock
        real, hits = os.rmdir, []
        def rmdir(path, *args, **kw):
            if not hits and os.path.basename(os.fspath(path)) == "romfs":
                hits.append(path)
                (self.root / "romfs" / name).write_bytes(b"late")
            return real(path, *args, **kw)
        return mock.patch.object(os, "rmdir", rmdir), hits

    def test_os_junk_written_during_delete_is_cleared(self):
        patcher, hits = self.injected(".DS_Store")
        with patcher:
            library._rmtree(self.root)
        self.assertTrue(hits)   # 注入真的发生了
        self.assertFalse(self.root.exists())

    def test_real_file_written_during_delete_is_not_forced(self):
        import errno as E
        patcher, hits = self.injected("game.nsp")
        with patcher, self.assertRaises(OSError) as caught:
            library._rmtree(self.root)
        self.assertTrue(hits)
        self.assertEqual(caught.exception.errno, E.ENOTEMPTY)
        self.assertIn("game.nsp", str(caught.exception))
        self.assertTrue((self.root / "romfs" / "game.nsp").exists())

    def test_only_os_junk_left_is_removed(self):
        import errno as E
        d = Path(self.temp.name) / "junk"
        d.mkdir()
        for name in (".DS_Store", "._x.nsp", "desktop.ini"):
            (d / name).write_bytes(b"")
        library._rmdir_past_os_junk(str(d), OSError(E.ENOTEMPTY, "x"), wait=0)
        self.assertFalse(d.exists())
