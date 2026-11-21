"""启动时清私有目录里作业被打断留下的临时目录（library.sweep_private_tmp，#1471）。期望手写：
① 我们建的名字（tmp + 8 位、s2a-install- / s2a-ds-install- + 8 位）、真目录、超过一天没动 → 删；
② 一天内动过（目录自己或第一层内容）→ 留；别的名字（store- 等）、软链、普通文件 → 留；
③ 本库执行锁或自动重活锁被占（有任务在跑）→ 一个都不删"""
import contextlib
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jobcase  # noqa: E402
import library  # noqa: E402

DAY = 24 * 3600


class PrivateTmpSweep(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.addCleanup(self.t.cleanup)
        self.c = jobcase.fake_context(self.t.name)
        self.c.private.mkdir(parents=True); self.c.library.mkdir(parents=True)
        self.now = 1_800_000_000.0

    def make(self, name, age, inner_age=None):
        p = self.c.private / name
        (p / "roots/g@v1").mkdir(parents=True)
        (p / "roots/g@v1/a.bin").write_bytes(b"x")
        for q in (p / "roots/g@v1/a.bin", p / "roots/g@v1", p / "roots"):
            os.utime(q, (self.now - age, self.now - age))
        if inner_age is not None:
            os.utime(p / "roots", (self.now - inner_age, self.now - inner_age))
        os.utime(p, (self.now - age, self.now - age))
        return p

    def test_removes_only_our_old_dirs(self):
        old = [self.make("tmpsgboeyr4", 2 * DAY), self.make("s2a-install-abcd1234", 2 * DAY), self.make("s2a-ds-install-abcd1234", 2 * DAY)]
        fresh = self.make("tmpabcd1234", 3600)
        touched = self.make("tmpzzzz9999", 2 * DAY, inner_age=600)   # 目录自己旧，第一层 roots 刚动过
        other = self.make("store-abcd1234", 2 * DAY)
        target = self.make("tmplinktarg", 2 * DAY)
        link = self.c.private / "tmplink0000"; link.symlink_to(target)
        (self.c.private / "tmpfile0000").write_bytes(b"f"); os.utime(self.c.private / "tmpfile0000", (self.now - 2 * DAY,) * 2)
        n = library.sweep_private_tmp(self.c, now=self.now)
        self.assertEqual(n, 4)   # 三个装机 / 缺省名的旧目录 + 软链指向的那个旧真目录 tmplinktarg（它本身也是我们的名字、够旧）
        for p in old + [target]:
            self.assertFalse(p.exists(), p)
        for p in (fresh, touched, other):
            self.assertTrue(p.is_dir(), p)
        self.assertTrue(link.is_symlink()); self.assertTrue((self.c.private / "tmpfile0000").is_file())

    def test_busy_library_removes_nothing(self):
        old = self.make("tmpsgboeyr4", 2 * DAY)
        for busy in ("execution", "auto-heavy"):
            @contextlib.contextmanager
            def idle(name="execution", busy=busy):
                yield name != busy
            self.c.idle = idle
            self.assertEqual(library.sweep_private_tmp(self.c, now=self.now), 0, busy)
            self.assertTrue(old.is_dir())


if __name__ == "__main__":
    unittest.main()
