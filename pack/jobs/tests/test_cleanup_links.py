# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Cleanup must unlink entries without following them into player data."""
import errno
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import jobcase  # noqa: E402（作业上下文替身统一工厂 jobcase.fake_context）

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import Failure
import layout
import library


class CleanupLinkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="s2arm synthetic cleanup ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.c = jobcase.fake_context(self.root, library=self.root / "library", work_root=self.root / "work", engine=jobcase.ROOT)   # 引擎根取真仓库：存 kit 要按引擎根载入 pack/orch/dirrename.py
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

    def test_stage_logs_include_windows_failed_rewrite_log(self):
        # #1476：Windows 改写失败时本款的 <款>_main.rewrite.log 留在 build/ios/work/roots/.failed（pack/orch/stages.py _keep_failed_logs），
        #   原先作业层不收这一处、诊断包里只有 light.log；期望拷进本任务的 <任务>-stages
        logs = self.root / "logs"; self.c.logs = logs; self.c.task = "t2"
        kept = self.output / "work" / "roots" / ".failed"; kept.mkdir(parents=True)
        (kept / "g_main.rewrite.log").write_text("PFRW mod=main need=9\n", encoding="utf-8")
        library._keep_stage_logs(self.c, self.gid)
        self.assertEqual((logs / "t2-stages" / "g_main.rewrite.log").read_text(encoding="utf-8"), "PFRW mod=main need=9\n")

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
        self.assertEqual(sorted(p.name for p in image.iterdir()), ["pack"])   # 资源包在 image/ios，不动
        import programs
        self.assertTrue((layout.program_store(self.c, self.gid) / "recipe.tar.zst").is_file())   # 程序件的配方在程序常驻，不动
        self.assertTrue((programs.cache(self.c, self.gid) / "kit" / "main.npdm").is_file())   # 程序件在程序缓存（不在出包工作目录 build/），出包收尾不清
        self.assertEqual(sorted(p.relative_to(unpacked).as_posix() for p in unpacked.rglob("*")), ["ios", "ios/logs", "ios/logs/refresh.log"])   # 解包、产物根、work 清掉，出包日志留

    def test_without_kit_prune_keeps_current_root(self):
        root = self.output / "roots" / "k@pkg"; self.seed_root(root)
        (self.output / "roots" / "k@现行").write_text("k@pkg" + '\n')
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

    def test_library_reached_through_a_link_still_counts_as_managed(self):
        # 游戏库经符号链接（或在另一块盘上挂出来）访问：记着的库路径是别名、要删的路径是真实写法（或反过来），原先按字面比报「操作路径不属于托管目录」。
        #   期望（手写）：两种写法都照常删掉中间件；库里一级目录链进存档的照样拒删（只解析锚这一级，锚以下不跟随链接）
        alias = self.root / "library-alias"
        alias.symlink_to(self.c.library, target_is_directory=True)
        for root, base in ((alias, self.c.library), (self.c.library, alias)):
            with self.subTest(root=root.name, path=base.name):
                scratch = self.payload(self.output / "scratch")
                library._rm(self.c, root, base / scratch.parent.relative_to(self.c.library))
                self.assertFalse(scratch.parent.exists())
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        link = self.output / "intermediate"
        link.symlink_to(payload.parent, target_is_directory=True)
        with self.assertRaises(Failure):
            library._rm(self.c, alias, link / payload.name)
        self.assertEqual(payload.read_bytes(), b"player data must survive")

    def test_cleanup_skipping_an_unmanaged_path_is_not_shown_as_an_error(self):
        # 真不在存放位置里的路径：清理收尾只记日志，不作为第二个错误码（job_failed）给玩家看（原先把排查带偏）
        notes = []
        self.c.diagnostic = lambda message, **k: notes.append((message, k))
        def outside(c, gid, **k):
            library._rm(c, c.library, self.payload(self.root / "outside"))
        from unittest.mock import patch
        import ipa
        with patch.object(library, "prune_build", outside):
            self.assertFalse(ipa.prune_unless_follow_up(self.c, self.gid))
        self.assertEqual(notes, [])

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


class MissingPathDuringCleanupTests(unittest.TestCase):
    def run_rmtree_callback(self, error):
        parent = Path(tempfile.mkdtemp(prefix="s2arm synthetic volume error "))
        root = parent / "tree"
        target = root / "extract"
        target.mkdir(parents=True)
        try:
            from unittest.mock import patch
            def emulate_windows_rmtree(path, *, onexc):
                if isinstance(error, FileNotFoundError):
                    target.rmdir()
                def failed_scan(path):
                    raise error
                onexc(failed_scan, str(target), error)
            with patch.object(library.shutil, "rmtree", side_effect=emulate_windows_rmtree), \
                 patch.object(os.path, "lexists", return_value=False):
                library._rmtree(root)
        finally:
            import shutil
            shutil.rmtree(parent, ignore_errors=True)

    def test_missing_scan_target_is_treated_as_already_removed(self):
        error = FileNotFoundError(errno.ENOENT, "synthetic vanished directory")
        self.run_rmtree_callback(error)

    def test_unrecognized_volume_error_is_not_treated_as_missing(self):
        error = OSError(errno.EIO, "synthetic volume failure")
        error.winerror = 1005
        with self.assertRaises(OSError) as caught:
            self.run_rmtree_callback(error)
        self.assertEqual(caught.exception.winerror, 1005)


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
