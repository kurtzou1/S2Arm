# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Windows strict realpath fallback for application-owned short-root junctions."""
import os
import stat
import sys
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from pack.orch import winlong


class StrictShortRootResolve(unittest.TestCase):
    def setUp(self):
        self.original_realpath = winlong.ntpath.realpath
        self.real_lstat = winlong.os.lstat
        self.real_stat = winlong.os.stat
        self.alias = r"C:\S2AFixture\j\z9e9"
        self.source = self.alias + r"\games\game\build\extract"
        self.table = "A:\\_game\\ios\\games\t" + self.alias
        self.error = OSError(22, "filesystem final-path query unsupported")
        self.error.winerror = 1005

    def tearDown(self):
        winlong.ntpath.realpath = self.original_realpath

    @staticmethod
    def info(reparse=False):
        return type("Stat", (), {
            "st_mode": stat.S_IFDIR,
            "st_file_attributes": 0x400 if reparse else 0,
        })()

    def wrap(self, *, lstat, stat_call=None, junction=True, error=None):
        patcher = patch.object(winlong.ntpath, "realpath", side_effect=error or self.error)
        patcher.start()
        winlong._wrap_realpath()
        self.addCleanup(patcher.stop)
        self.addCleanup(setattr, winlong.ntpath, "realpath", self.original_realpath)
        alias = winlong.ntpath.normcase(self.alias)

        def scoped_lstat(path, *args, **kwargs):
            if winlong.ntpath.normcase(os.fspath(path)).startswith(alias):
                return lstat(path)
            return self.real_lstat(path, *args, **kwargs)

        lstat_patcher = patch.object(winlong.os, "lstat", side_effect=scoped_lstat)
        lstat_patcher.start()
        self.addCleanup(lstat_patcher.stop)
        junction_patcher = patch.object(
            winlong.os.path,
            "isjunction",
            side_effect=lambda path: junction and winlong.ntpath.normcase(path) == alias,
            create=True,
        )
        junction_patcher.start()
        self.addCleanup(junction_patcher.stop)
        if stat_call is not None:
            def scoped_stat(path, *args, **kwargs):
                if winlong.ntpath.normcase(os.fspath(path)).startswith(alias):
                    return stat_call(path)
                return self.real_stat(path, *args, **kwargs)

            stat_patcher = patch.object(winlong.os, "stat", side_effect=scoped_stat)
            stat_patcher.start()
            self.addCleanup(stat_patcher.stop)
        env_patcher = patch.dict(os.environ, {"S2A_SHORT_ROOTS": self.table})
        env_patcher.start()
        self.addCleanup(env_patcher.stop)

    def test_strict_1005_falls_back_only_inside_existing_managed_junction(self):
        alias = winlong.ntpath.normcase(self.alias)

        def lstat(path):
            path = winlong.ntpath.normcase(path)
            return self.info(reparse=path == alias)

        self.wrap(lstat=lstat, stat_call=lambda _path: self.info())
        self.assertEqual(winlong.ntpath.realpath(self.source, strict=True), self.source)

    def test_strict_1005_accepts_extended_length_spelling_of_managed_junction(self):
        alias = winlong.ntpath.normcase(self.alias)

        def lstat(path):
            path = winlong.ntpath.normcase(path)
            return self.info(reparse=path == alias)

        self.wrap(lstat=lstat, stat_call=lambda _path: self.info())
        extended = "\\\\?\\" + self.source
        self.assertEqual(winlong.ntpath.realpath(extended, strict=True), self.source)

    def test_strict_1005_is_not_hidden_for_path_outside_managed_junction(self):
        self.wrap(lstat=lambda _path: self.info(reparse=True))
        with self.assertRaises(OSError) as caught:
            winlong.ntpath.realpath(r"A:\\outside\\game", strict=True)
        self.assertIs(caught.exception, self.error)

    def test_other_strict_errors_are_not_hidden(self):
        error = OSError(5, "access denied")
        error.winerror = 5
        self.wrap(lstat=lambda _path: self.info(reparse=True), error=error)
        with self.assertRaises(OSError) as caught:
            winlong.ntpath.realpath(self.source, strict=True)
        self.assertIs(caught.exception, error)

    def test_strict_1005_is_not_hidden_if_short_root_is_not_a_junction(self):
        self.wrap(lstat=lambda _path: self.info(reparse=False))
        with self.assertRaises(OSError) as caught:
            winlong.ntpath.realpath(self.source, strict=True)
        self.assertIs(caught.exception, self.error)

    def test_strict_1005_is_not_hidden_if_short_root_is_a_symlink_not_junction(self):
        self.wrap(lstat=lambda _path: self.info(reparse=True), junction=False)
        with self.assertRaises(OSError) as caught:
            winlong.ntpath.realpath(self.source, strict=True)
        self.assertIs(caught.exception, self.error)

    def test_strict_1005_is_not_hidden_if_nested_component_is_reparse_point(self):
        alias = winlong.ntpath.normcase(self.alias)
        nested = winlong.ntpath.normcase(self.alias + r"\games\game")

        def lstat(path):
            path = winlong.ntpath.normcase(path)
            return self.info(reparse=path in (alias, nested))

        self.wrap(lstat=lstat, stat_call=lambda _path: self.info())
        with self.assertRaises(OSError) as caught:
            winlong.ntpath.realpath(self.source, strict=True)
        self.assertIs(caught.exception, self.error)

    def test_strict_short_root_fallback_preserves_missing_path_error(self):
        alias = winlong.ntpath.normcase(self.alias)

        def lstat(path):
            path = winlong.ntpath.normcase(path)
            if path == alias:
                return self.info(reparse=True)
            return self.info()

        missing = FileNotFoundError(2, "missing source")
        self.wrap(lstat=lstat, stat_call=lambda _path: (_ for _ in ()).throw(missing))
        with self.assertRaises(FileNotFoundError) as caught:
            winlong.ntpath.realpath(self.source, strict=True)
        self.assertIs(caught.exception, missing)

    @unittest.skipUnless(os.name == "nt", "requires a Windows directory junction")
    def test_pathlib_strict_resolve_survives_final_path_query_error_on_real_junction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "library"
            target.mkdir()
            (target / "extract").mkdir()
            alias = root / "junction"
            winlong.create_junction(str(target), str(alias))
            try:
                alias_text = str(alias)
                table = f"{target}\t{alias_text}"
                underlying = self.original_realpath

                def realpath_with_volume_error(path, **kwargs):
                    value = os.fspath(path)
                    if winlong.ntpath.normcase(value).startswith(winlong.ntpath.normcase(alias_text)):
                        error = OSError(22, "filesystem final-path query unsupported")
                        error.winerror = 1005
                        raise error
                    return underlying(path, **kwargs)

                with patch.dict(os.environ, {"S2A_SHORT_ROOTS": table}):
                    winlong.ntpath.realpath = realpath_with_volume_error
                    winlong._wrap_realpath()
                    resolved = (alias / "extract").resolve(strict=True)
                self.assertEqual(resolved, alias / "extract")
            finally:
                os.rmdir(alias)


if __name__ == "__main__":
    unittest.main()
