"""#1126 / #2024：Mac 菜单、启动台里一排「S2Arm Game」。聚焦收录家目录里的 .app、系统随即登记，局后注销完一扫描又回来。
   根修：放宿主 / 引擎副本的目录名带 .noindex（聚焦整个跳过），旧位置的搬走 / 清掉。期望路径按设计手写，不跑被测实现推导。"""
import json
import os
import time
from pathlib import Path

from jobcase import JobCase

import embedded
import host_update
import layout
from core import Context, atomic

APP_EXE = "S2ArmGame.app/Contents/MacOS/s2arm-host"


def touch(path, text="x", mtime=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


class NoIndexDirsTests(JobCase):
    def test_every_place_a_host_app_lands_is_under_noindex(self):
        L = self.c.library
        self.assertEqual(layout.hosts_mac(self.c), L / "hosts" / "mac.noindex")
        self.assertEqual(embedded.engines_root(self.c), L / "hosts" / "engine.noindex")
        fresh = Context(dict(self.request, taskId="t-n", operation="setup", library=str(self.root / "none")))
        self.assertEqual(embedded.engines_root(fresh), fresh.private / "engines.noindex")   # 还没建库：私有目录


class Upgrade5Tests(JobCase):
    def v4_library(self):
        atomic(self.c.library / ".s2arm-layout.json", dict(version=4, games=[]))

    def test_hosts_move_into_noindex_and_old_host_still_found(self):
        self.v4_library()
        L = self.c.library
        touch(L / "hosts/mac/aaaaaaaaaaaa" / APP_EXE, "old host")            # 不兼容本版的款还在用的旧宿主：不能丢
        touch(L / "hosts/mac/bbbbbbbbbbbb" / APP_EXE, "stale copy")
        touch(L / "hosts/mac.noindex/bbbbbbbbbbbb" / APP_EXE, "new copy")     # 新位置已有同名：留新位置的
        self.assertTrue(layout.migrate(self.c))
        N = L / "hosts/mac.noindex"
        self.assertEqual((N / "aaaaaaaaaaaa" / APP_EXE).read_text(), "old host")
        self.assertEqual((N / "bbbbbbbbbbbb" / APP_EXE).read_text(), "new copy")
        self.assertFalse((L / "hosts/mac").exists())
        self.assertTrue(host_update.host_exe(self.c, "aaaaaaaaaaaa").is_file())
        self.assertEqual(json.loads((L / ".s2arm-layout.json").read_text())["version"], 5)
        self.assertFalse(layout.migrate(self.c))


class OldEngineRootTests(JobCase):
    def test_old_hosts_engine_copies_dropped_once_unused(self):
        old = self.c.library / "hosts" / "engine"
        day = embedded.STALE_SECONDS
        stale = old / ("a" * 64)
        touch(stale / ".installed.json", "{}", time.time() - day - 60); touch(stale / ".last-used", "", time.time() - day - 60)
        os.utime(stale, (time.time() - day - 60,) * 2)
        recent = touch(old / ("b" * 64) / ".last-used", "", time.time() - 60).parent   # 升级当口旧版作业可能还在用：留
        embedded._drop_old_copies(self.c, embedded.engines_root(self.c))
        self.assertFalse(stale.exists())
        self.assertTrue(recent.is_dir())
        for p in (recent / ".last-used", recent):
            os.utime(p, (time.time() - day - 60,) * 2)
        embedded._drop_old_copies(self.c, embedded.engines_root(self.c))
        self.assertFalse(old.exists())   # 空了整个删
