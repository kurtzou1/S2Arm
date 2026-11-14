"""换游戏库：打开已有的、认领旧产物、搬家（同盘 / 跨盘）和失败回滚。"""
import hashlib
import json
import os
import sys
import tempfile
import unittest

from pack.orch import roots   # 搬库改名重试与产物根改名同一套退避（DIR_RENAME_RETRIES）
import unittest.mock as um
from pathlib import Path
from types import MethodType, SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import core
import library
from core import Failure

GID = "0100000000010000"


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


class MoveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.private = self.root / "private"; self.private.mkdir()

    def ctx(self, library_path, **request):
        notes = []
        c = SimpleNamespace(library=library_path, private=self.private, engine=self.root / "engine", r=request, begin=lambda *a, **k: None, check=lambda: None,
                            progress=lambda *a: None, redact=lambda s: s, diagnostic=lambda m, **k: notes.append(m), notes=notes,
                            emit=lambda *a, **k: None, lock_wait=0.3, task="t1", operation="setup")
        c.lock_holder, c.lock = MethodType(core.Context.lock_holder, c), MethodType(core.Context.lock, c)   # 库锁走真实现（剃刀 H2：搬家锁旧库同一语义）
        return c

    def old(self, name="old"):
        lib = self.root / name; (lib / "saves" / GID).mkdir(parents=True); (lib / "iPhone" / GID / "t资源包").mkdir(parents=True); (lib / "games" / GID).mkdir(parents=True)
        (lib / ".s2arm-library.json").write_text(json.dumps({"schema": 1, "id": "library-id"}))
        (lib / "catalog.json").write_text(json.dumps({"schema": 1, "games": [{"id": GID, "name": "甲", "display": "", "packages": []}]}))
        (lib / "saves" / GID / "save.bin").write_bytes(b"save-data-1234")
        (lib / "iPhone" / GID / "t.ipa").write_bytes(b"ipa" * 1000)
        (lib / "iPhone" / GID / "t资源包" / "romfs.img").write_bytes(b"pack" * 100)
        (lib / ".s2arm-work" / "cache" / "air").mkdir(parents=True); (lib / ".s2arm-work" / "cache" / "air" / "shader.bin").write_bytes(b"shader")
        (lib / ".execution.lock").write_text(""); (lib / ".catalog.lock").write_text("")
        return lib

    def run_setup(self, target, **request):
        with um.patch.object(library, "require_apfs"), um.patch.object(library, "require_local"):
            return library.setup(self.ctx(target, **request))

    def assert_moved(self, old, new):
        self.assertEqual(sha(new / "saves" / GID / "save.bin"), hashlib.sha256(b"save-data-1234").hexdigest())
        self.assertTrue((new / "iPhone" / GID / "t.ipa").is_file())
        self.assertTrue((new / "iPhone" / GID / "t资源包" / "romfs.img").is_file())
        self.assertTrue((new / ".s2arm-work" / "cache" / "air" / "shader.bin").is_file())
        self.assertEqual(json.loads((new / "catalog.json").read_text())["games"][0]["id"], GID)
        self.assertFalse((old / "iPhone").exists()); self.assertFalse((new / ".s2arm-moving").exists())

    def assert_untouched(self, old, new):
        self.assertEqual((old / "saves" / GID / "save.bin").read_bytes(), b"save-data-1234")
        self.assertTrue((old / "iPhone" / GID / "t.ipa").is_file()); self.assertTrue((old / ".s2arm-library.json").is_file())
        self.assertFalse((new / ".s2arm-library.json").exists()); self.assertFalse((new / ".s2arm-moving").exists())

    def _cross_setup(self, new, check):
        """跨盘搬库，作业的取消检查换成 check（#924）"""
        ctx = self.ctx(new, moveFrom=str(self.root / "old")); ctx.check = check
        with um.patch.object(library, "require_apfs"), um.patch.object(library, "require_local"), \
             um.patch.object(library, "_same_volume", return_value=False):
            return library.setup(ctx)

    def test_cancel_takes_effect_inside_a_big_directory(self):
        """#924：拷一个大目录时也逐项看取消——原先整个目录拷完才看一次，玩家取消后还要等几分钟。期望手写：第 20 次检查时取消（旧代码只在顶层项之间看，这份夹具整次搬库共 12 次，到不了第 20 次；新代码逐个目录 / 文件看，共 26 次）→ 立刻停、原库不动、临时目录收掉"""
        old, new = self.old(), self.root / "new"
        calls = []
        def check():
            calls.append(1)
            if len(calls) == 20: raise core.Cancelled()
        with self.assertRaises(core.Cancelled):
            self._cross_setup(new, check)
        self.assertEqual(len(calls), 20)
        self.assert_untouched(old, new)

    def test_stage_deleted_mid_copy_says_so_and_rolls_back(self):
        """#924：拷到一半有人删了新位置的 .s2arm-moving → 报「临时文件夹被删掉了、游戏库还在原位置」（library_move_failed），不是原始 FileNotFoundError；原库不动"""
        old, new = self.old(), self.root / "new"
        calls = []
        def check():
            calls.append(1)
            if len(calls) == 6 and (new / ".s2arm-moving").is_dir():
                import shutil; shutil.rmtree(new / ".s2arm-moving")
        with self.assertRaises(Failure) as caught:
            self._cross_setup(new, check)
        self.assertEqual(caught.exception.code, "library_move_failed")
        self.assertIn("临时文件夹（.s2arm-moving）被删掉了", str(caught.exception)); self.assertIn("游戏库还在原来的位置", str(caught.exception))
        self.assert_untouched(old, new)

    # ---- 库路径规则只在 setup（剃刀 W19）：期望按规则手写，临时目录里真建文件夹 ----
    def test_library_inside_or_containing_install_dir_refused(self):
        install = self.root / "work" / "S2Arm-windows-x64"; install.mkdir(parents=True)
        for target, what in ((install / "1", "库在启动器目录里"), (install, "库就是启动器目录"), (self.root / "work", "库包含启动器目录")):
            with self.subTest(what), self.assertRaises(Failure) as e:
                self.run_setup(target, installDir=str(install))
            self.assertIn("启动器自己的文件夹", str(e.exception))
        self.assertFalse((install / "1" / ".s2arm-library.json").exists())
        r = self.run_setup(self.root / "work" / "S2Arm-windows-x64-lib", installDir=str(install))   # 前缀相同的兄弟目录不算
        self.assertEqual(r["outcome"], "created")

    def test_drive_root_and_home_refused(self):
        for target in (Path(self.root.anchor), Path.home()):
            with self.subTest(str(target)), self.assertRaises(Failure) as e:
                self.run_setup(target)
            self.assertIn("独立的游戏库文件夹", str(e.exception))

    def test_free_default_moves_next_to_occupied_default(self):
        lib = self.root / "S2Arm"; (lib / "Engine").mkdir(parents=True); (lib / "S2Arm.exe").write_text("x")   # 玩家把启动器解压到了缺省库同名文件夹
        r = self.run_setup(lib, freeDefault=True)
        self.assertEqual((r["library"], r["outcome"]), (str(self.root / "S2Arm Library"), "created"))
        self.assertTrue((self.root / "S2Arm Library" / ".s2arm-library.json").is_file())
        self.assertEqual(sorted(p.name for p in lib.iterdir()), ["Engine", "S2Arm.exe"])   # 原文件夹一个字节没动
        nxt = self.root / "S2Arm Library"; (nxt / ".s2arm-library.json").unlink(); (nxt / "catalog.json").unlink(); (nxt / ".s2arm-layout.json").unlink()
        (nxt / "note.txt").write_text("x")
        self.assertEqual(self.run_setup(lib, freeDefault=True)["library"], str(self.root / "S2Arm Library 2"))

    def test_free_default_keeps_usable_default(self):
        empty = self.root / "S2Arm"; empty.mkdir(); (empty / "desktop.ini").write_text(""); (empty / "._x").write_text("")
        self.assertEqual(self.run_setup(empty, freeDefault=True)["library"], str(empty))   # 只有系统文件 = 空
        lib = self.old("S2ArmOld")
        r = self.run_setup(lib, freeDefault=True)
        self.assertEqual((r["library"], r["outcome"]), (str(lib), "opened"))   # 已有游戏库照常打开

    def test_occupied_folder_asks_then_uses_it_and_leaves_files_alone(self):
        # v0.3.1：玩家自己选的位置有别的文件 → 不替他换、先问（library_folder_not_empty）；确认后照建游戏库，原有文件不动
        lib = self.root / "S2Arm"; lib.mkdir(); (lib / "S2Arm.exe").write_text("x")
        with self.assertRaises(Failure) as e:
            self.run_setup(lib)
        self.assertEqual(e.exception.code, "library_folder_not_empty")
        self.assertIn("已有别的文件", str(e.exception))
        self.assertEqual(sorted(p.name for p in lib.iterdir()), ["S2Arm.exe"])   # 问之前什么都没写
        r = self.run_setup(lib, acceptForeign=True)
        self.assertEqual((r["library"], r["outcome"]), (str(lib), "created"))
        self.assertEqual((lib / "S2Arm.exe").read_text(), "x")
        self.assertEqual(self.run_setup(lib)["outcome"], "opened")   # 建好以后再打开不再问

    def test_occupied_folder_move_stops_on_same_name_without_touching_anything(self):
        old = self.old(); new = self.root / "picked"; new.mkdir(); (new / "saves").write_text("玩家自己的")
        with self.assertRaises(Failure) as e:
            self.run_setup(new, moveFrom=str(old), acceptForeign=True)
        self.assertEqual(e.exception.code, "library_move_failed"); self.assertIn("saves", str(e.exception))
        self.assertEqual((new / "saves").read_text(), "玩家自己的")
        self.assertTrue((old / "saves" / GID / "save.bin").is_file())
        (new / "saves").unlink(); (new / "mine.txt").write_text("留着")
        self.run_setup(new, moveFrom=str(old), acceptForeign=True)
        self.assert_moved(old, new); self.assertEqual((new / "mine.txt").read_text(), "留着")

    def test_broken_library_marker_opens_with_id_kept_or_new(self):
        # v0.3.1：标识坏了不挡打开——有库号照用、补正 schema；没库号补一个新的
        lib = self.old("lib")
        (lib / ".s2arm-library.json").write_text(json.dumps({"schema": 7, "id": "library-id"}))
        self.assertEqual(self.run_setup(lib)["libraryId"], "library-id")
        self.assertEqual(json.loads((lib / ".s2arm-library.json").read_text())["schema"], 1)
        (lib / ".s2arm-library.json").write_text(json.dumps({"schema": 1}))
        r = self.run_setup(lib)
        self.assertEqual(r["outcome"], "opened"); self.assertTrue(r["libraryId"])
        self.assertEqual(json.loads((lib / ".s2arm-library.json").read_text())["id"], r["libraryId"])

    def test_setup_does_not_adopt_logs_of_a_plain_folder(self):
        import layout
        folder = self.root / "picked"; (folder / "logs").mkdir(parents=True); (folder / "logs" / "mine.txt").write_text("玩家自己的")
        layout.adopt_library_logs(SimpleNamespace(library=folder, private=self.private, logs=self.private / "logs"))
        self.assertEqual((folder / "logs" / "mine.txt").read_text(), "玩家自己的")   # 还不是游戏库：logs 是玩家自己的东西，不收

    def test_opens_existing_library(self):
        lib = self.old("lib")
        r = self.run_setup(lib)
        self.assertEqual((r["outcome"], r["libraryId"]), ("opened", "library-id"))

    def test_empty_folder_without_move_is_new_and_empty(self):
        r = self.run_setup(self.root / "fresh")
        self.assertEqual(r["outcome"], "created")
        self.assertEqual(json.loads((self.root / "fresh/catalog.json").read_text())["games"], [])

    def test_adopts_copied_products_with_their_catalog(self):
        lib = self.old("copied"); (lib / ".s2arm-library.json").unlink()
        r = self.run_setup(lib)
        self.assertEqual(r["outcome"], "adopted"); self.assertTrue(r["libraryId"])
        self.assertEqual(json.loads((lib / "catalog.json").read_text())["games"][0]["name"], "甲")

    def test_adopts_products_without_a_catalog(self):
        lib = self.old("copied"); (lib / ".s2arm-library.json").unlink(); (lib / "catalog.json").unlink()
        self.assertEqual(self.run_setup(lib)["outcome"], "adopted")
        games = json.loads((lib / "catalog.json").read_text())["games"]
        self.assertEqual([g["id"] for g in games], [GID]); self.assertEqual(games[0]["name"], GID)

    def test_unrelated_folder_is_refused_and_left_alone(self):
        d = self.root / "docs"; d.mkdir(); (d / "a.txt").write_text("x")
        with self.assertRaises(Failure): self.run_setup(d)
        self.assertEqual([p.name for p in d.iterdir()], ["a.txt"])

    def test_same_volume_move(self):
        old, new = self.old(), self.root / "new"
        r = self.run_setup(new, moveFrom=str(old))
        self.assertEqual((r["outcome"], r["libraryId"]), ("moved", "library-id"))
        self.assert_moved(old, new)
        self.assertFalse(old.exists())

    def test_rename_imports_pack_like_the_job_runner(self):
        """#812：作业主程序 pack/jobs/main.py 只把 pack/jobs 放进 sys.path（本文件开头导入了 pack.orch.roots，进程内跑测不出来）。
        换一个干净的解释器（-I，只放 pack/jobs）调搬库最后那一步改名：期望先确认 pack 确实导入不了，再照常改名成功——
        main 上这里报 ModuleNotFoundError: No module named 'pack'、目录没搬"""
        import subprocess
        jobs, engine = Path(library.__file__).resolve().parent, Path(library.__file__).resolve().parents[2]
        a, b = self.root / "old" / "games", self.root / "new" / "games"
        a.mkdir(parents=True); (a / "catalog.json").write_text("{}"); b.parent.mkdir()
        probe = ("import importlib.util, sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; from types import SimpleNamespace\n"
                 "assert importlib.util.find_spec('pack') is None, 'pack 不该在作业进程的 sys.path 上'\n"
                 "import library\n"
                 "c = SimpleNamespace(engine=Path(sys.argv[2]), emit=lambda **k: None, check=lambda: None)\n"
                 "library._rename_library_path(c, sys.argv[3], sys.argv[4])\n")
        run = subprocess.run([sys.executable, "-I", "-c", probe, str(jobs), str(engine), str(a), str(b)],
                             cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(a.exists())
        self.assertEqual((b / "catalog.json").read_text(), "{}")

    @unittest.skipUnless(os.name == "nt", "Windows directory-handle sharing errors")
    def test_same_volume_rename_retries_after_temporary_lock(self):
        old, new = self.old(), self.root / "new"
        real, failures, sleeps = os.rename, [0], []

        def locked_once(src, dst):
            if Path(src) == old / "games" and not failures[0]:
                failures[0] += 1
                error = PermissionError(13, "Access is denied", str(src))
                error.winerror = 5
                raise error
            return real(src, dst)

        with um.patch.object(library, "_same_volume", return_value=True), \
             um.patch.object(library.os, "rename", locked_once), \
             um.patch.object(library.time, "sleep", sleeps.append):
            r = self.run_setup(new, moveFrom=str(old))
        self.assertEqual(failures, [1])
        self.assertEqual(sleeps, [roots.DIR_RENAME_RETRIES[0]])
        self.assertEqual((r["outcome"], r["libraryId"]), ("moved", "library-id"))
        self.assert_moved(old, new)
        self.assertFalse(old.exists())

    @unittest.skipUnless(os.name == "nt", "Windows directory-handle sharing errors")
    def test_same_volume_persistent_lock_times_out_and_preserves_source(self):
        old, new = self.old(), self.root / "new"
        real, refusals, sleeps = os.rename, [0], []

        def always_locked(src, dst):
            if Path(src) == old / "games":
                refusals[0] += 1
                error = PermissionError(13, "Access is denied", str(src))
                error.winerror = 32
                raise error
            return real(src, dst)

        with um.patch.object(library, "_same_volume", return_value=True), \
             um.patch.object(library.os, "rename", always_locked), \
             um.patch.object(library.time, "sleep", sleeps.append), \
             self.assertRaises(Failure) as caught:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(caught.exception.code, "library_move_failed")
        self.assertIn("重试约 1 分钟", str(caught.exception))
        self.assertIn("资源管理器", str(caught.exception))
        self.assertIn("原游戏库仍保留在原位置", str(caught.exception))
        self.assertEqual(refusals, [len(roots.DIR_RENAME_RETRIES) + 1])
        self.assertEqual(sleeps, list(roots.DIR_RENAME_RETRIES))
        self.assert_untouched(old, new)
        self.assertEqual(list(new.iterdir()), [])

    def test_nonretryable_no_space_rename_fails_immediately_and_preserves_source(self):
        old, new = self.old(), self.root / "new"
        real, failed, sleeps = os.rename, [0], []

        def no_space(src, dst):
            if Path(src) == old / "games":
                failed[0] += 1
                raise OSError(28, "No space left on device", str(src))
            return real(src, dst)

        with um.patch.object(library, "_same_volume", return_value=True), \
             um.patch.object(library.os, "rename", no_space), \
             um.patch.object(library.time, "sleep", sleeps.append), \
             self.assertRaises(OSError) as caught:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(caught.exception.errno, 28)
        self.assertEqual(failed, [1])
        self.assertEqual(sleeps, [])
        self.assert_untouched(old, new)
        self.assertEqual(list(new.iterdir()), [])

    @unittest.skipUnless(os.name == "nt", "Windows directory-handle sharing semantics")
    def test_windows_directory_handle_times_out_without_moving_source(self):
        import ctypes
        from ctypes import wintypes

        old, new = self.old(), self.root / "new"
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        create_file = kernel32.CreateFileW
        create_file.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        create_file.restype = wintypes.HANDLE
        close_handle = kernel32.CloseHandle
        close_handle.argtypes = [wintypes.HANDLE]
        close_handle.restype = wintypes.BOOL
        handle = create_file(str(old / "games"), 0x80000000, 0x1 | 0x2, None, 3, 0x02000000, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
        errors = []
        real = os.rename

        def observe_rename(src, dst):
            try:
                return real(src, dst)
            except PermissionError as error:
                errors.append(getattr(error, "winerror", None))
                raise

        try:
            with um.patch.object(library.os, "rename", observe_rename), \
                 um.patch.object(library.time, "sleep", lambda _: None), \
                 self.assertRaises(Failure) as caught:
                self.run_setup(new, moveFrom=str(old))
        finally:
            close_handle(handle)
        self.assertTrue(errors and errors[0] in (5, 32), errors)
        self.assertEqual(len(errors), len(roots.DIR_RENAME_RETRIES) + 1)
        self.assertIn("资源管理器", str(caught.exception))
        self.assert_untouched(old, new)
        self.assertEqual(list(new.iterdir()), [])

    def test_cross_volume_move(self):
        old, new = self.old(), self.root / "new"
        with um.patch.object(library, "_same_volume", return_value=False):
            r = self.run_setup(new, moveFrom=str(old))
        self.assertEqual(r["outcome"], "moved"); self.assert_moved(old, new); self.assertFalse(old.exists())

    def test_cross_volume_failed_verification_rolls_back(self):
        old, new = self.old(), self.root / "new"
        real = library._verify_copy
        def corrupt(src, dst, strict):
            if src.name == "saves": (dst / GID / "save.bin").write_bytes(b"damaged-data-!")
            real(src, dst, strict)
        with um.patch.object(library, "_same_volume", return_value=False), um.patch.object(library, "_verify_copy", corrupt), self.assertRaises(Failure) as e:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(e.exception.code, "library_move_failed"); self.assert_untouched(old, new)

    @unittest.skipIf(os.name == "nt", "占锁的子进程用 fcntl.flock")
    def test_busy_old_library_queues_then_reports_library_busy(self):
        # 旧库有任务（出包 t7）一直占着执行锁：排队到上限报 library_busy、带占锁者，旧库新库都不动（旧代码：当场报 library_move_failed、不说是谁）
        import subprocess
        old, new = self.old(), self.root / "new"
        info = {"taskId": "t7", "operation": "build", "gameId": GID, "pid": 1, "startedAt": 1.0}
        holder = subprocess.Popen([sys.executable, "-c", "import sys; sys.path.insert(0,sys.argv[2]); import filelock; f=open(sys.argv[1],'a'); filelock.try_lock(f); "
                                   "open(sys.argv[1]+'.holder','w').write(sys.argv[3]); print('ok',flush=True); sys.stdin.readline()",
                                   str(old / ".execution.lock"), str(Path(library.__file__).parent), json.dumps(info)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "ok")
            with self.assertRaises(Failure) as e:
                self.run_setup(new, moveFrom=str(old))
            self.assertEqual((e.exception.code, e.exception.holder), ("library_busy", info)); self.assert_untouched(old, new)
        finally:
            holder.stdin.write("\n"); holder.stdin.flush(); holder.communicate(timeout=5)

    def test_interrupted_rename_rolls_back(self):
        old, new = self.old(), self.root / "new"
        real, calls = os.rename, [0]
        def flaky(a, b):
            calls[0] += 1
            if calls[0] == 3: raise OSError(28, "no space")
            real(a, b)
        with um.patch.object(library.os, "rename", flaky), self.assertRaises(OSError):
            self.run_setup(new, moveFrom=str(old))
        self.assert_untouched(old, new)
        self.assertEqual(sorted(p.name for p in new.iterdir()), [])

    def test_not_enough_space_changes_nothing(self):
        old, new = self.old(), self.root / "new"
        usage = SimpleNamespace(free=0, total=1, used=1)
        with um.patch.object(library, "_same_volume", return_value=False), um.patch.object(library.shutil, "disk_usage", return_value=usage), self.assertRaises(Failure) as e:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(e.exception.code, "disk_full"); self.assert_untouched(old, new)

    def test_refuses_a_target_inside_the_library(self):
        old = self.old()
        with self.assertRaises(Failure): self.run_setup(old / "inner", moveFrom=str(old))
        self.assertTrue((old / "iPhone" / GID / "t.ipa").is_file())

    def test_default_library_brings_private_caches_along(self):
        old = self.private / "lib"; old.parent.mkdir(exist_ok=True)
        src = self.old(); os.rename(src, old); new = self.root / "new"
        (self.private / "cache" / "pso").mkdir(parents=True); (self.private / "cache" / "pso" / "p.bin").write_bytes(b"pso")
        import shutil; shutil.rmtree(old / ".s2arm-work")
        self.run_setup(new, moveFrom=str(old))
        self.assertTrue((new / ".s2arm-work" / "cache" / "pso" / "p.bin").is_file())
        self.assertFalse((self.private / "cache").exists())

    def test_absolute_links_follow_the_move(self):
        old, new = self.old(), self.root / "new"
        os.symlink(old / "iPhone" / GID / "t.ipa", old / "iPhone" / GID / "current.ipa")
        self.run_setup(new, moveFrom=str(old))
        self.assertEqual(os.readlink(new / "iPhone" / GID / "current.ipa").removeprefix("\\\\?\\"), str(new / "iPhone" / GID / "t.ipa"))
        self.assertTrue((new / "iPhone" / GID / "current.ipa").is_file())


if __name__ == "__main__":
    unittest.main()
