# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""git 调用钉死仓库（11-11 维护者 Windows 覆盖安装：Engine\\.git 缺 refs 空目录 → git 不认、一路往上认到玩家主目录的空仓库，播种报 128）。
期望手写：缺 refs 的快照补上空目录后照常取到 HEAD；没有自己 .git 的目录不往上认外层仓库；作业层自检同样补好"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "pack" / "jobs"))
from pack.orch import roots  # noqa: E402


def sh(*args, cwd):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=env)


class GitPinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="s2a-gitpin-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # 外层：玩家主目录里的一个空仓库（没有任何提交）
        sh("init", "-q", cwd=self.tmp)
        # 引擎快照：自己一库、一次提交、引用全打进 packed-refs，再把 refs/ 整个删掉（模拟安装时空目录丢了）
        self.engine = self.tmp / "Programs" / "S2Arm" / "Engine"
        self.engine.mkdir(parents=True)
        sh("init", "-q", cwd=self.engine)
        (self.engine / "a.txt").write_text("x")
        sh("add", "a.txt", cwd=self.engine); sh("commit", "-q", "-m", "snapshot", cwd=self.engine)
        self.head = sh("rev-parse", "HEAD", cwd=self.engine).stdout.strip()
        sh("pack-refs", "--all", "--prune", cwd=self.engine)
        shutil.rmtree(self.engine / ".git" / "refs")

    def test_broken_snapshot_is_not_a_repo_without_repair(self):
        # 负对照：缺 refs 时裸 git 认不出引擎自己的仓库（往上走到外层空仓库，HEAD 不存在 → 退出码 128）
        r = sh("-C", str(self.engine), "rev-parse", "HEAD", cwd=self.tmp)
        self.assertNotEqual(r.returncode, 0)

    def test_roots_git_repairs_and_reads_own_head(self):
        self.assertEqual(roots.git("rev-parse", "HEAD", repo=self.engine), self.head)
        for d in ("refs", "refs/heads", "refs/tags"):
            self.assertTrue((self.engine / ".git" / d).is_dir(), d)

    def test_no_walk_up_to_outer_repo(self):
        # 没有自己 .git 的目录（引擎的 .git 整个没了）：不往上认外层仓库，如实失败
        bare = self.tmp / "Programs" / "S2Arm" / "Engine2"
        bare.mkdir(parents=True)
        self.assertFalse(roots.git("rev-parse", "--git-dir", repo=bare, check=False))

    def test_job_check_git_repairs_too(self):
        import embedded
        embedded.check_git(self.engine)   # 不抛 = 认出的就是引擎自己的 .git
        self.assertTrue((self.engine / ".git" / "refs" / "heads").is_dir())
        self.assertEqual(embedded.repair_git_skeleton(self.engine / ".git"), [])
        self.assertEqual(roots.repair_git_skeleton(self.tmp / "nope"), [], "不是仓库的目录不动")


if __name__ == "__main__":
    unittest.main()
