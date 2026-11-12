# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Mac 运行包必须包含独立 RomFS；共享存储链接不能漏拷或逃逸。"""
import errno
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import types
from unittest.mock import patch
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build
from core import Failure


class RuntimeRomfs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm Application Support ")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "roots/game@stage"
        self.source.mkdir(parents=True)
        self.store = self.base / "roots/.romfs_store/game/input-v1"
        (self.store / "empty").mkdir(parents=True)
        (self.store / "data.bin").write_bytes(b"synthetic resource\x00")
        (self.source / "romfs").symlink_to("../.romfs_store/game/input-v1")
        self.dest = self.base / "library/games/game/releases/new.partial"
        self.dest.mkdir(parents=True)
        self.c = types.SimpleNamespace(library=self.base / "library", check=lambda: None, progress=lambda *a: None)

    def test_store_link_materializes_independent_readonly_files(self):
        (self.store / "data.bin").chmod(0o444)
        self.store.chmod(0o555)
        self.addCleanup(lambda: self.store.chmod(0o755) if self.store.exists() else None)
        build.clone_tree(self.c, self.source, self.dest, materialize_romfs=True)
        self.assertFalse((self.dest / "romfs").is_symlink())
        self.assertTrue((self.dest / "romfs/empty").is_dir())
        self.assertEqual((self.dest / "romfs/data.bin").read_bytes(), b"synthetic resource\x00")
        self.assertFalse(os.stat(self.dest / "romfs/data.bin").st_mode & 0o222)
        self.assertIn("romfs/data.bin", build.snapshot(self.c, self.dest))
        self.store.chmod(0o755)
        shutil.rmtree(self.store)
        self.assertEqual((self.dest / "romfs/data.bin").read_bytes(), b"synthetic resource\x00")

    def test_reports_whether_every_file_was_cloned(self):
        # #329：返回值决定 Mac 出包后解包目录留不留——整棵都是真克隆（同一克隆族、不另占盘）才 True；有一个退成普通复制（跨卷 / 非 APFS / Windows）就 False
        real = build.clone
        cloned = build.clone_tree(self.c, self.source, self.dest, materialize_romfs=True)
        self.assertEqual(cloned, sys.platform == "darwin")   # 测试临时目录在 APFS 同卷：Mac 上整棵克隆；别的系统没有克隆
        other = self.base / "library/games/game/releases/other.partial"; other.mkdir()
        with patch.object(build, "clone", lambda a, b, progress=None: (real(a, b, progress), False)[1]):   # 模拟一个文件退成了普通复制
            self.assertFalse(build.clone_tree(self.c, self.source, other, materialize_romfs=True))
        self.assertEqual((other / "romfs/data.bin").read_bytes(), b"synthetic resource\x00")

    def test_legacy_real_directory_keeps_empty_directories(self):
        (self.source / "romfs").unlink()
        (self.source / "romfs/empty").mkdir(parents=True)
        build.clone_tree(self.c, self.source, self.dest, materialize_romfs=True)
        self.assertTrue((self.dest / "romfs/empty").is_dir())

    def test_invalid_store_links_rejected(self):
        for link in ("../missing", str(self.store), "../.romfs_store/other/input-v1", "../.romfs_store/game/missing", "../.romfs_store/game/../game/input-v1"):
            with self.subTest(link=link):
                (self.source / "romfs").unlink()
                (self.source / "romfs").symlink_to(link)
                with self.assertRaises(Failure):
                    build.clone_tree(self.c, self.source, self.dest, materialize_romfs=True)

    def test_symlinked_store_identity_rejected(self):
        real = self.base / "outside"
        self.store.rename(real)
        self.store.symlink_to(real, target_is_directory=True)
        with self.assertRaises(Failure):
            build.clone_tree(self.c, self.source, self.dest, materialize_romfs=True)

    def test_nested_and_unrelated_directory_links_rejected(self):
        for root, link in ((self.source, "other"), (self.store, "nested")):
            with self.subTest(link=link):
                p = root / link; p.symlink_to(self.base, target_is_directory=True)
                try:
                    with self.assertRaises(Failure):
                        build.clone_tree(self.c, self.source, self.dest, materialize_romfs=True)
                finally:
                    p.unlink()

    def test_generic_clone_does_not_expand_romfs_links(self):
        with self.assertRaises(Failure):
            build.clone_tree(self.c, self.source, self.dest)

    def test_unreadable_romfs_subdirectory_stops_publication(self):
        scandir = os.scandir
        for shared in (True, False):
            with self.subTest(shared=shared):
                if shared:
                    root = self.store
                else:
                    (self.source / "romfs").unlink()
                    root = self.source / "romfs"
                    root.mkdir()
                blocked = root / "unreadable"
                blocked.mkdir()
                (blocked / "required.bin").write_bytes(b"must not be skipped")
                destination = self.dest / str(shared)
                destination.mkdir()

                def deny(path):
                    if isinstance(path, (str, os.PathLike)) and Path(path).resolve() == blocked.resolve():
                        raise PermissionError(errno.EACCES, "permission denied", str(blocked))
                    return scandir(path)

                with mock.patch("os.scandir", side_effect=deny), self.assertRaises(Failure):
                    build.clone_tree(self.c, self.source, destination, materialize_romfs=True)

    def test_library_listing_skips_per_file_checks_but_launch_does_not(self):
        host = self.dest / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True); host.write_bytes(b"synthetic"); host.chmod(0o755)
        (self.dest / "romfs").mkdir(); (self.dest / "romfs/a.bin").write_bytes(b"data")
        manifest = dict(schema=1, engine="S2Arm", target="macos-arm64", files=build.snapshot(self.c, self.dest))
        (self.dest / "manifest.json").write_text(json.dumps(manifest))
        (self.dest / "romfs/a.bin").unlink()
        with patch.object(build, "validate_files") as files:
            build.validate_runtime(self.c, self.dest, full=False, files=False)
        files.assert_not_called()
        with self.assertRaises(Failure) as error:   # 真正启动走完整校验，文件少了照样拦下
            build.validate_runtime(self.c, self.dest)
        self.assertEqual(error.exception.code, "runtime_invalid")

    def test_memory_table_mismatch_or_missing_still_launches(self):
        # v0.3.1（认不出的直接做）：宿主读 addr_need.tsv 只认几行、程序号不符按 0，表坏了 / 没了最多布局提示不生效，不挡起局
        host = self.dest / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True); host.write_bytes(b"synthetic"); host.chmod(0o755)
        (self.dest / "romfs").mkdir(); (self.dest / "addr_need.tsv").write_text("程序号\t0100000000000001\n")
        manifest = dict(schema=1, engine="S2Arm", target="macos-arm64", files=build.snapshot(self.c, self.dest),
                        memoryRequirementsVersion=2, memoryRequirementsSha256="0" * 64)
        (self.dest / "manifest.json").write_text(json.dumps(manifest))
        with patch.object(build, "validate_files"):
            self.assertEqual(build.validate_runtime(self.c, self.dest)["memoryRequirementsVersion"], 2)
            (self.dest / "addr_need.tsv").unlink()
            build.validate_runtime(self.c, self.dest)

    def test_runtime_rejects_missing_romfs_even_with_matching_manifest(self):
        host = self.dest / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True); host.write_bytes(b"synthetic"); host.chmod(0o755)
        manifest = dict(schema=1, engine="S2Arm", target="macos-arm64", files=build.snapshot(self.c, self.dest))
        (self.dest / "manifest.json").write_text(json.dumps(manifest))
        for full in (False, True):
            with self.subTest(full=full), self.assertRaises(Failure) as error:
                build.validate_runtime(self.c, self.dest, full=full)
            self.assertEqual(error.exception.code, "runtime_invalid")
        (self.dest / "romfs").mkdir()
        build.validate_runtime(self.c, self.dest)
        (self.dest / "romfs").rmdir()
        (self.dest / "romfs").symlink_to(self.store)
        with self.assertRaises(Failure):
            build.validate_runtime(self.c, self.dest)


class BundleLayoutRomfsImport(unittest.TestCase):
    """出包布局里 Jobs 在 Contents/Resources/Jobs 下：build.py 的 parents[2] 是 Contents（没有 graphics/），
    clone_tree 只认仓库根的 romfs_list 时，运行包首跑「初始化内置 S2Arm 引擎」即 input_missing（11-07 实测）。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm bundle layout ")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.jobs = self.base / "Contents/Resources/Jobs"
        shutil.copytree(
            Path(__file__).resolve().parents[1],
            self.jobs,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        shutil.copy2(
            Path(__file__).resolve().parents[3] / "graphics/nvn/tools/romfs_list.py",
            self.jobs / "romfs_list.py",
        )
        self.source = self.base / "roots/game@v1"
        self.source.mkdir(parents=True)
        (self.source / "a.bin").write_bytes(b"engine file")
        self.dest = self.base / "dest"
        self.dest.mkdir()
        self.c = types.SimpleNamespace(check=lambda: None, progress=lambda *a: None)

    def staged_build(self):
        spec = importlib.util.spec_from_file_location("_s2arm_bundle_build", self.jobs / "build.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_clone_tree_imports_romfs_list_staged_beside_jobs(self):
        module = self.staged_build()
        module.clone_tree(self.c, self.source, self.dest)
        self.assertEqual((self.dest / "a.bin").read_bytes(), b"engine file")

    def test_missing_romfs_list_reports_failure(self):
        (self.jobs / "romfs_list.py").unlink()
        module = self.staged_build()
        with self.assertRaises(Failure):
            module.clone_tree(self.c, self.source, self.dest)


if __name__ == "__main__":
    unittest.main()
