"""游戏库结构 P3 单测：库外的东西（工具缓存、日志 / 任务记录、引擎副本）搬进默认位置、默认库位置 ~/S2Arm、任务记录保留规则、
工具缓存旧键、整库搬家收尾不跟随链接。期望值按设计规则手写（不跑被测实现推导），每条规则配负对照。"""
import json
import os
from pathlib import Path
import time
import unittest
from unittest.mock import patch

from jobcase import JobCase

import cache_retention
import core
import embedded
import layout
import library
from core import Context, atomic


def touch(path, text="x", mtime=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


class DirectoryRuleTests(JobCase):
    """日志 / 任务记录固定在私有目录（剃刀 H6，期望手写）；工具缓存仍按默认位置：库建好 → <库>/tool-cache，没建好 → 私有目录"""

    def test_logs_stay_private_tool_cache_follows_library(self):
        c = Context(dict(self.request, taskId="t-built", operation="keys"))
        self.assertEqual(c.logs, c.private / "logs")
        self.assertEqual(c.jobpath, c.private / "logs" / "jobs" / "t-built.json")
        self.assertTrue(c.jobpath.is_file())
        self.assertFalse((self.c.library / "logs").exists(), "库里不再写日志")
        self.assertEqual(c.work_root, self.c.library / "tool-cache")
        self.assertEqual(c.env()["S2A_RUN_ROOT"], str(self.c.library / "tool-cache" / "run"))

    def test_unbuilt_library_same_logs_private_tool_cache(self):
        empty = self.root / "not-yet"
        empty.mkdir()
        c = Context(dict(self.request, taskId="t-fresh", operation="setup", library=str(empty)))
        self.assertEqual(c.logs, c.private / "logs")
        self.assertEqual(c.jobpath, c.private / "logs" / "jobs" / "t-fresh.json")
        self.assertEqual(c.work_root, c.private / "tool-cache")

    def test_private_only_readers_find_old_library_records_before_migration(self):
        # v0.3.0 之前库建好后记录写在 <库>/logs/jobs：还没有作业迁回时，只拿得到私有目录的读者（main.py get / events / cancel）照样找得到
        layout.save_index(self.c)
        touch(self.c.library / "logs" / "jobs" / "older.json", json.dumps(dict(id="older", state="completed")))
        self.assertEqual(core.logs_root(self.c.private), self.c.private / "logs")
        self.assertEqual(core.journal(self.c.private, "older")["id"], "older")

    def test_reader_falls_back_to_records_not_yet_adopted(self):
        layout.save_index(self.c)
        touch(self.c.private / "jobs" / "legacy.json", json.dumps(dict(id="legacy", state="completed")))
        self.assertEqual(core.journal(self.c.private, "legacy")["id"], "legacy")


class ConcurrentAdoptTests(JobCase):
    """每个作业建任务时都把旧位置的日志收回私有目录（layout.follow_task → adopt_library_logs）：启动器同时起两个作业时，另一个可能刚把旧目录收空删掉。
    手写时序：判完 is_dir、列目录前目录没了 → 当作已收完，不让作业失败（原先抛 FileNotFoundError，catalog 报「任务所需的文件或目录不存在」）"""

    def test_dir_removed_by_concurrent_job_is_treated_as_adopted(self):
        c = Context(dict(self.request, taskId="t-race", operation="catalog"))
        touch(self.c.library / "logs" / "jobs" / "old.json", json.dumps(dict(id="old", state="completed", ended=1)))
        real = Path.iterdir
        def vanished(self_):   # 对方作业在本作业判完 is_dir 之后把旧目录收空删掉
            if self_ in (self.c.library / "logs" / "jobs", self.c.library / "logs"):
                raise FileNotFoundError(2, "No such file or directory", str(self_))
            return real(self_)
        with patch.object(Path, "iterdir", vanished):
            layout.adopt_library_logs(c)   # 不抛


class Upgrade4Tests(JobCase):
    def v3_library(self):
        atomic(self.c.library / ".s2arm-layout.json", dict(version=3, games=[]))   # P1 + P2 都做完（协调约定：从 3 起步）

    def test_tool_cache_moves_on_same_volume_and_marker_reaches_4(self):
        self.v3_library()
        L, P = self.c.library, self.c.private
        touch(L / ".s2arm-work" / "cache" / "nxaot" / "osx-arm64-k" / "lib.a", "aot")
        touch(L / ".s2arm-work" / "run" / "s2arm" / "cache" / "direct" / "x", "direct")
        touch(P / "cache" / "vpx" / "ios-arm64-v" / "libvpx.a", "vpx")      # 库曾在私有目录里时的旧工具缓存
        touch(L / "tool-cache" / "cache" / "nxaot" / "osx-arm64-k" / "lib.a", "new")   # 新位置已有的同名项：留新位置的
        self.assertTrue(layout.migrate(self.c))
        T = L / "tool-cache"
        self.assertEqual((T / "run" / "s2arm" / "cache" / "direct" / "x").read_text(), "direct")
        self.assertEqual((T / "cache" / "vpx" / "ios-arm64-v" / "libvpx.a").read_text(), "vpx")
        self.assertEqual((T / "cache" / "nxaot" / "osx-arm64-k" / "lib.a").read_text(), "new")
        self.assertFalse((L / ".s2arm-work").exists())
        self.assertFalse((P / "cache").exists())
        self.assertEqual(json.loads((L / ".s2arm-layout.json").read_text())["version"], 4)
        self.assertFalse(layout.migrate(self.c))   # 已是 4：不再动

    def test_cross_volume_tool_cache_is_deleted_not_copied(self):
        self.v3_library()
        touch(self.c.private / "run" / "big" / "f", "rebuildable")
        with patch.object(layout, "_same_volume", lambda a, b: False):
            layout._upgrade_4(self.c)
        self.assertFalse((self.c.private / "run").exists())
        self.assertFalse((self.c.library / "tool-cache" / "run" / "big").exists())

    def test_interrupted_upgrade_resumes(self):
        self.v3_library()
        touch(self.c.private / "cache" / "a" / "f", "a")
        touch(self.c.private / "cache" / "b" / "f", "b")
        moved = []
        real = os.replace

        def kill_after_first(src, dst):
            if Path(src).parent == self.c.private / "cache" and moved:
                raise KeyboardInterrupt   # 模拟搬到一半被杀
            moved.append(src)
            return real(src, dst)
        (self.c.library / "tool-cache" / "cache").mkdir(parents=True)   # 新位置已有目录 → 逐个子项搬
        with patch.object(layout.os, "replace", kill_after_first), self.assertRaises(KeyboardInterrupt):
            layout.migrate(self.c)
        self.assertEqual(json.loads((self.c.library / ".s2arm-layout.json").read_text())["version"], 3)
        self.assertTrue(layout.migrate(self.c))
        for name in ("a", "b"):
            self.assertEqual((self.c.library / "tool-cache" / "cache" / name / "f").read_text(), name)


class AdoptLogsTests(JobCase):
    """旧位置（v0.3.0 之前的 <库>/logs、P3 之前的 <私有目录>/jobs）在建任务时收回 <私有目录>/logs（剃刀 H6）；期望手写"""

    def test_library_logs_and_legacy_jobs_move_back_but_running_task_stays(self):
        P, L = self.c.private, self.c.library
        touch(P / "jobs" / "old.json", json.dumps(dict(id="old", operation="ipa", state="completed")))
        touch(P / "jobs" / "old.request.json", "{}")
        touch(L / "logs" / "lib.log", "lib log")
        touch(L / "logs" / "lib" / "stage.log", "stage")
        touch(L / "logs" / "jobs" / "boot.json", json.dumps(dict(id="boot", operation="setup", state="failed")))
        touch(L / "logs" / "jobs" / "live.json", json.dumps(dict(id="live", operation="ipa", state="running", pid=os.getpid())))
        touch(L / "logs" / "live.log", "still writing")
        Context(dict(self.request, taskId="adopter", operation="catalog"))   # 建任务即收
        self.assertEqual((P / "logs" / "lib.log").read_text(), "lib log")
        self.assertEqual((P / "logs" / "lib" / "stage.log").read_text(), "stage")
        for name in ("old.json", "old.request.json", "boot.json"):
            self.assertTrue((P / "logs" / "jobs" / name).is_file(), name)
        self.assertFalse((P / "jobs").exists())
        # 负对照：进程还活着、没写终态的任务（记录 + 以任务号开头的日志）留在旧位置，读的一方照样找得到
        self.assertTrue((L / "logs" / "jobs" / "live.json").is_file())
        self.assertTrue((L / "logs" / "live.log").is_file())
        self.assertFalse((P / "logs" / "live.log").exists())
        self.assertEqual(core.journal(P, "live")["id"], "live")
        self.assertEqual(json.loads((P / "library-index.json").read_text())["locations"][0]["path"], str(L))

    def test_same_task_rerun_keeps_attempts(self):
        P, L = self.c.private, self.c.library
        touch(L / "logs" / "jobs" / "again.json", json.dumps(dict(id="again", operation="build", state="failed", attemptNo=1, stage="解包")))
        touch(L / "logs" / "jobs" / "again.request.json", "{}")
        c = Context(dict(self.request, taskId="again", operation="build"))
        self.assertEqual(c.jobpath, P / "logs" / "jobs" / "again.json")
        self.assertEqual((c.job["attemptNo"], c.job["previousStage"]), (2, "解包"))
        self.assertFalse((L / "logs" / "jobs" / "again.json").exists())
        self.assertTrue((P / "logs" / "jobs" / "again.request.json").is_file())

    def test_existing_destination_is_never_overwritten(self):
        touch(self.c.private / "logs" / "same.log", "private copy")
        touch(self.c.library / "logs" / "same.log", "library copy")
        Context(dict(self.request, taskId="adopter2", operation="catalog"))
        self.assertEqual((self.c.private / "logs" / "same.log").read_text(), "private copy")
        self.assertEqual((self.c.library / "logs" / "same.log").read_text(), "library copy")


class PruneJobsTests(unittest.TestCase):
    """保留规则：总量上限与时间上限取更严的；每类操作留最近若干条成功的、更多条失败的；没写终态的不动"""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.jobs = Path(self.tmp.name) / "jobs"
        self.now = time.time()

    def put(self, task, operation, state, age_days):
        record = dict(id=task, operation=operation, state=state)
        if state != "running":
            record["ended"] = 1
        stamp = self.now - age_days * 86400
        touch(self.jobs / (task + ".json"), json.dumps(record), stamp)
        touch(self.jobs / (task + ".events.jsonl"), "", stamp)

    def prune(self, **kw):
        args = dict(keep_days=14, keep_count=4, per_operation=1, failed_per_operation=2, jobs=self.jobs)
        args.update(kw)
        return core.prune_jobs(None, **args)

    def test_total_cap_with_per_operation_floors(self):
        for i in range(6):   # catalog c0（最新）… c5
            self.put(f"c{i}", "catalog", "completed", i * 0.01)
        self.put("f0", "catalog", "failed", 0.10)
        self.put("f1", "catalog", "failed", 0.11)
        self.put("f2", "catalog", "failed", 0.12)
        self.put("ipa", "ipa", "completed", 0.20)   # 最旧，超出总量上限
        self.put("run", "ipa", "running", 30)        # 没写终态：一律不动
        removed = set(self.prune()["removed"])
        # 按时间从新到旧：c0..c5（名次 0-5）、f0 f1 f2（6-8）、ipa（9）；总量上限 4 → 名次 ≥4 的超限
        # 保底：catalog 成功 1 条（c0）、catalog 失败 2 条（f0 f1）、ipa 成功 1 条（ipa）
        self.assertEqual(removed, {"c4", "c5", "f2"})
        self.assertTrue((self.jobs / "run.json").is_file())
        self.assertFalse((self.jobs / "c4.events.jsonl").exists())

    def test_age_cap_applies_even_inside_the_count(self):
        self.put("new", "build", "completed", 1)
        self.put("old", "build", "completed", 20)    # 只有 2 条，没超总量，但超过 14 天
        self.put("keep", "launch", "completed", 30)  # 超 14 天但它是 launch 的最近一条：保底留
        self.assertEqual(set(self.prune(keep_count=100)["removed"]), {"old"})

    def test_default_constants_are_the_documented_ones(self):
        self.assertEqual((core.KEEP_TOTAL, core.KEEP_DAYS, core.KEEP_PER_OPERATION, core.KEEP_FAILED_PER_OPERATION), (300, 14, 20, 50))


class RelocateDefaultTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.private = base / "Application Support" / "S2Arm"
        self.old = self.private / "游戏库"
        self.target = base / "home" / "S2Arm"
        self.ext = base / "external-drive" / "S2Arm"   # 第二个存放位置（没连上）：路径原样不动
        self.target.parent.mkdir(parents=True)
        touch(self.old / ".s2arm-library.json", json.dumps(dict(schema=1, id="lib")))
        touch(self.old / "games" / "G" / "saves" / "s.dat", "save")
        os.symlink(str(self.old / "games" / "G" / "saves"), self.old / "link-to-saves")
        atomic(self.private / "preferences.json", dict(library=str(self.old), language="zh"))
        (self.private / "library-location.txt").write_text(str(self.old))
        atomic(self.private / "library-index.json", dict(schema=1, locations=[dict(id="lid", path=str(self.old)), dict(id="x", path=str(self.ext))], games={}))
        self.patches = [patch.object(layout, "standard_private", lambda: self.private),
                        patch.object(layout, "new_default_library", lambda: self.target)]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_same_volume_rename_updates_index_settings_and_links(self):
        self.assertEqual(layout.relocate_default(self.private, self.old), self.target)
        self.assertFalse(self.old.exists())
        self.assertEqual((self.target / "games" / "G" / "saves" / "s.dat").read_text(), "save")
        self.assertEqual(os.readlink(self.target / "link-to-saves"), str(self.target / "games" / "G" / "saves"))
        prefs = json.loads((self.private / "preferences.json").read_text())
        self.assertEqual((prefs["library"], prefs["language"]), (str(self.target), "zh"))
        self.assertEqual((self.private / "library-location.txt").read_text(), str(self.target))
        idx = json.loads((self.private / "library-index.json").read_text())
        self.assertEqual([l["path"] for l in idx["locations"]], [str(self.target), str(self.ext)])
        self.assertEqual(json.loads((self.private / "library-relocate.json").read_text())["state"], "done")
        # 之后照旧传旧路径的请求（前端内存里还是旧值）也落到新位置；前端又把旧路径写回设置时再改一次
        atomic(self.private / "preferences.json", dict(library=str(self.old)))
        self.assertEqual(layout.relocate_default(self.private, self.old), self.target)
        self.assertEqual(json.loads((self.private / "preferences.json").read_text())["library"], str(self.target))

    def test_windows_upgrade_without_settings_file(self):
        """0.1.x Windows 老玩家：库在私有目录 DefaultLibrary、没有 library-location.txt / preferences.json，前端把旧路径交过来：
        ① 新位置不存在 → 搬过去、游戏存档都在、不凭空写设置文件；② 新位置被别的东西占着 → 留在旧路径、游戏存档都在"""
        win = self.private / "DefaultLibrary"
        os.replace(self.old, win)
        (self.private / "preferences.json").unlink()
        (self.private / "library-location.txt").unlink()
        touch(self.target / "README.md", "someone else's checkout")   # ②
        self.assertEqual(layout.relocate_default(self.private, win), win)
        self.assertEqual((win / "games" / "G" / "saves" / "s.dat").read_text(), "save")
        self.assertEqual((self.target / "README.md").read_text(), "someone else's checkout")
        (self.target / "README.md").unlink()
        touch(self.target / ".s2arm-library.json", json.dumps(dict(schema=1, id="empty-new")))   # ③ 0.2.0 在新位置建的空库
        self.assertEqual(layout.relocate_default(self.private, win), win)
        self.assertEqual((win / "games" / "G" / "saves" / "s.dat").read_text(), "save")
        (self.private / "library-location.txt").write_text(str(win))       # 临时绕法：设置指回旧库，照用、不搬
        self.assertEqual(layout.relocate_default(self.private, win), win)
        self.assertEqual((self.private / "library-location.txt").read_text(), str(win))
        (self.private / "library-location.txt").unlink()
        (self.target / ".s2arm-library.json").unlink()
        self.target.rmdir()                                                    # ①
        self.assertEqual(layout.relocate_default(self.private, win), self.target)
        self.assertEqual((self.target / "games" / "G" / "saves" / "s.dat").read_text(), "save")
        self.assertFalse(win.exists())
        self.assertFalse((self.private / "library-location.txt").exists())
        self.assertEqual(layout.relocate_default(self.private, win), self.target)   # 前端之后照旧传旧路径也落到新位置

    def test_concurrent_jobs_all_get_the_new_location(self):
        # v0.2.5 发版用例 upgrade ① 两次红：启动器一打开同时起好几个作业，各自走 relocate_default。期望（手写）：只搬一次，
        #   每个作业都拿到新位置，旧目录不会被拿着旧路径的作业再建出来。复现法：第一个作业判断完、改名前停住，第二个作业这时进来
        import threading
        win = self.private / "DefaultLibrary"
        os.replace(self.old, win)
        first_in, release, results = threading.Event(), threading.Event(), {}
        real_idle = layout._idle
        def slow_idle(lib):
            if not first_in.is_set():
                first_in.set(); release.wait(5)   # 第一个作业停在改名前
            return real_idle(lib)
        def job(name):
            results[name] = layout.relocate_default(self.private, win)
        with patch.object(layout, "_idle", slow_idle):
            a = threading.Thread(target=job, args=("a",)); a.start()
            first_in.wait(5)
            b = threading.Thread(target=job, args=("b",)); b.start()
            b.join(0.5)              # 第二个作业在等锁，不能先判断
            self.assertTrue(b.is_alive())
            release.set(); a.join(5); b.join(5)
        self.assertEqual(results, {"a": self.target, "b": self.target})
        self.assertFalse(win.exists())
        self.assertEqual((self.target / "games" / "G" / "saves" / "s.dat").read_text(), "save")

    @unittest.skipIf(os.name == "nt", "占锁的子进程用 fcntl.flock")
    def test_relocate_lock_stuck_reports_library_busy_not_unlocked_judge(self):
        # 搬家锁被一个卡住的作业一直占着：等到上限报 library_busy，不再「等不到就不拿锁照常判断」（剃刀 H2），旧库原样不动
        import subprocess, sys
        win = self.private / "DefaultLibrary"
        os.replace(self.old, win)
        lock = self.private / layout.RELOCATE_LOCK
        holder = subprocess.Popen([sys.executable, "-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); sys.stdin.readline()",
                                   str(lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "held")
            with patch.object(layout, "RELOCATE_LOCK_WAIT", 0.2), self.assertRaises(layout.Failure) as raised:
                layout.relocate_default(self.private, win)
            self.assertEqual(raised.exception.code, "library_busy")
            self.assertTrue(win.is_dir()); self.assertFalse(self.target.exists())
        finally:
            holder.stdin.write("\n"); holder.stdin.flush(); holder.communicate(timeout=5)

    def test_rename_refused_leaves_library_and_no_moving_marker(self):
        # 旧库里有文件被别的程序开着（Windows 上整目录改不了名）：库原样不动、照旧用旧位置，不留「正在搬」的标记，下次再试；绝不半搬
        win = self.private / "DefaultLibrary"
        os.replace(self.old, win)
        real_replace = os.replace
        def refuse(src, dst):   # 只拒搬库那次整目录改名；写标记的原子写照常
            if Path(src) == win: raise PermissionError(13, "被占用")
            return real_replace(src, dst)
        with patch.object(layout.os, "replace", side_effect=refuse):
            self.assertEqual(layout.relocate_default(self.private, win), win)
        self.assertEqual((win / "games" / "G" / "saves" / "s.dat").read_text(), "save")
        self.assertFalse(self.target.exists())
        self.assertFalse((self.private / "library-relocate.json").exists())
        self.assertEqual(layout.relocate_default(self.private, win), self.target)   # 占用解除后下次照常搬

    def test_killed_after_rename_finishes_on_next_job(self):
        atomic(self.private / "library-relocate.json", {"schema": 1, "from": str(self.old), "to": str(self.target), "state": "moving"})
        os.replace(self.old, self.target)   # 改完名就被杀：设置、索引都还是旧路径
        self.assertEqual(layout.relocate_default(self.private, self.old), self.target)
        self.assertEqual(json.loads((self.private / "preferences.json").read_text())["library"], str(self.target))
        self.assertEqual(json.loads((self.private / "library-index.json").read_text())["locations"][0]["path"], str(self.target))

    def test_stays_put_when_target_exists_or_busy_or_custom_or_chosen(self):
        self.target.mkdir()   # 目标已存在
        self.assertEqual(layout.relocate_default(self.private, self.old), self.old)
        self.target.rmdir()
        import filelock
        with (self.old / ".execution.lock").open("a") as f:   # 库里有任务在跑
            filelock.try_lock(f)
            self.assertEqual(layout.relocate_default(self.private, self.old), self.old)
            filelock.unlock(f)
        with patch.object(layout, "standard_private", lambda: self.private.parent / "elsewhere"):   # 自定义数据目录
            self.assertEqual(layout.relocate_default(self.private, self.old), self.old)
        chosen = Path(self.tmp.name) / "MyGames"
        self.assertEqual(layout.relocate_default(self.private, chosen), chosen)   # 玩家选的位置
        with patch.object(layout, "_same_volume", lambda a, b: False):   # 跨卷
            self.assertEqual(layout.relocate_default(self.private, self.old), self.old)
        self.assertTrue((self.old / ".s2arm-library.json").is_file())
        self.assertFalse((self.private / "library-relocate.json").exists())


class EngineCopyTests(JobCase):
    def fake(self, root, identity, used):
        d = root / identity
        touch(d / ".installed.json", json.dumps(dict(schema=2, id=identity)))
        touch(d / ".last-used", "", used)
        return d

    def test_root_follows_library(self):
        self.assertEqual(embedded.engines_root(self.c), self.c.library / "hosts" / "engine")
        fresh = Context(dict(self.request, taskId="t-e", operation="setup", library=str(self.root / "none")))
        self.assertEqual(embedded.engines_root(fresh), fresh.private / "engines")

    def test_keeps_current_and_previous_only(self):
        root = embedded.engines_root(self.c)
        now = time.time()
        for name, age in (("a" * 64, 300), ("b" * 64, 200), ("c" * 64, 100)):
            self.fake(root, name, now - age)
        current = self.fake(root, "d" * 64, now - 400)   # 现在用的这份（时刻马上会更新）
        (root / ("e" * 64 + ".x.partial")).mkdir()          # 别的作业正在解的：不碰
        embedded._retain(self.c, root, "d" * 64)
        self.assertEqual(sorted(p.name for p in root.iterdir()), sorted(["c" * 64, "d" * 64, "e" * 64 + ".x.partial"]))
        self.assertTrue(current.is_dir())

    def test_private_copies_cleaned_only_when_stale_and_partials_left_alone(self):
        """库建好后私有 engines/ 的旧副本：24 小时没用过的删；刚用过的（可能有作业正用着）留；别的作业正在解的 .partial 不碰（启动时并发作业把它删掉过）"""
        old = self.c.private / "engines"
        day = embedded.PRIVATE_STALE_SECONDS
        stale = self.fake(old, "a" * 64, time.time() - day - 60)
        fresh = self.fake(old, "b" * 64, time.time() - 60)
        partial = old / ("c" * 64 + ".x.partial"); (partial / ".git").mkdir(parents=True); touch(partial / ".git/COMMIT_EDITMSG")
        os.utime(stale / ".installed.json", (time.time() - day - 60,) * 2); os.utime(stale, (time.time() - day - 60,) * 2)
        root = embedded.engines_root(self.c)
        embedded._adopt_private_copy(self.c, root, "b" * 64)
        self.assertFalse(stale.exists())
        self.assertTrue((fresh / ".installed.json").is_file())
        self.assertTrue((partial / ".git/COMMIT_EDITMSG").is_file())
        self.assertFalse((root / ("b" * 64)).exists())   # 不搬：hosts/engine 那份由 install 从 App 包解


class ToolKeyTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.now = 1_000_000.0

    def entry(self, rel, name, mtime):
        d = self.work / rel / name
        d.mkdir(parents=True)
        os.utime(d, (mtime, mtime))
        return d

    def test_rules(self):
        since = self.now - 5000   # 当前引擎装好的时刻
        self.entry("cache/nxaot", "osx-arm64-old1", since - 9000)
        self.entry("cache/nxaot", "osx-arm64-cur", since + 10)      # 当前引擎用过 → 同平台其余全删
        self.entry("cache/nxaot", "ios-arm64-old", since - 9000)
        self.entry("cache/nxaot", "ios-arm64-older", since - 9500)  # 当前引擎没用过 ios → 只留最新一份（-old）
        self.entry("cache/nxaot", ".lock-osx-arm64-x", since - 9000)   # 锁目录不碰
        self.entry("cache/nxaot", "osx-arm64-half.tmp", since - 9000)  # 半成品不碰
        self.entry("cache/vpx", "osx-arm64-1.0-aa", self.now - 60)   # 30 分钟内动过：就算是旧键也不删
        self.entry("cache/vpx", "osx-arm64-1.1-bb", since + 1)
        self.entry("run/s2arm/cache/dav1d", "osx-arm64-1-cc", since - 9000)
        self.entry("run/s2arm/cache/dav1d", "osx-arm64-2-dd", since + 1)
        result = cache_retention.prune_tool_keys(self.work, since, now=self.now)
        self.assertEqual(sorted(result["removed"]), sorted(["cache/nxaot/osx-arm64-old1", "cache/nxaot/ios-arm64-older",
                                                            "run/s2arm/cache/dav1d/osx-arm64-1-cc"]))
        for kept in ("cache/nxaot/osx-arm64-cur", "cache/nxaot/ios-arm64-old", "cache/nxaot/.lock-osx-arm64-x",
                     "cache/nxaot/osx-arm64-half.tmp", "cache/vpx/osx-arm64-1.0-aa"):
            self.assertTrue((self.work / kept).is_dir(), kept)

    def test_source_checkout_engine_never_prunes(self):
        self.entry("cache/nxaot", "osx-arm64-a", 1)
        self.entry("cache/nxaot", "osx-arm64-b", 2)
        self.assertEqual(cache_retention.prune_tool_keys(self.work, None, now=self.now)["removedEntries"], 0)
        self.assertIsNone(cache_retention.engine_installed_at(self.work / "no-engine"))


class DiscardNoFollowTests(unittest.TestCase):
    def test_link_targets_outside_keep_their_mode(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            outside = touch(Path(t) / "outside" / "original.bin", "keep")
            os.chmod(outside, 0o600)
            os.chmod(outside.parent, 0o700)
            doomed = Path(t) / "doomed"
            touch(doomed / "sealed" / "f", "x")
            os.chmod(doomed / "sealed", 0o500)
            os.symlink(outside, doomed / "link.bin")
            os.symlink(outside.parent, doomed / "dirlink")
            library._discard(doomed)
            self.assertFalse(doomed.exists())
            self.assertEqual(oct(outside.stat().st_mode & 0o777), oct(0o600))
            self.assertEqual(oct(outside.parent.stat().st_mode & 0o777), oct(0o700))
            self.assertEqual(outside.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
