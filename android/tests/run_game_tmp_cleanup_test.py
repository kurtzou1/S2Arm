#!/usr/bin/env python3
"""run_game_test.py 的用例收场后，临时目录里不得留下东西（宿主单测，不起局、不碰设备）：
  ① 通过的用例：RunGameTest.setUp 建的 s2a-rungame-* 目录被删
  ② 失败的用例（断言不成立）：同样被删
  ③ setUp 在建完目录之后出错、用例体根本没跑：同样被删——清理要在建目录的那一刻就登记，不能只靠 tearDown
做法：把 tempfile 的默认目录指到一个私有目录，真起 RunGameTest 的 setUp（探针只换用例体或 _png），
收场后看私有目录里还剩什么。探针必须记到 setUp 建的目录、且目录在私有目录之下，否则不算数。
"""
import importlib.util, io, os, shutil, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("run_game_test", HERE / "run_game_test.py")
run_game_test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_game_test)   # 文件末尾有 __main__ 守卫：导入只定义类，不跑用例


def run_probe(case_class, name):
    """在私有临时目录下真跑 case_class(name)；返回 (结果, 私有目录路径, 私有目录里剩下的项)。"""
    root = tempfile.mkdtemp(prefix="s2a-rungame-cleanup-")   # 在改默认目录之前建，探针目录才会落在它下面
    saved = tempfile.tempdir
    tempfile.tempdir = root
    try:
        runner = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0)
        result = runner.run(unittest.TestSuite([case_class(name)]))
        return result, Path(root), sorted(os.listdir(root))
    finally:
        tempfile.tempdir = saved
        shutil.rmtree(root, ignore_errors=True)


class RunGameTmpCleanupTest(unittest.TestCase):
    # 探针是测试方法里的局部类：放在模块层会被 unittest 当成用例收走，连带跑 RunGameTest 的 113 个用例。

    def check(self, result, root, left, seen, failures, errors):
        self.assertEqual((result.testsRun, len(result.failures), len(result.errors)), (1, failures, errors),
                         "探针没有按预期收场：%r" % (result,))
        self.assertEqual(len(seen), 1, "探针没有记到 setUp 建的目录")
        self.assertEqual(seen[0].parent, root, "setUp 的临时目录没有落在私有目录下（tempfile 默认目录没生效），本条不算数")
        self.assertEqual(left, [], "RunGameTest 的用例收场后，私有临时目录里还留着：%s" % left)

    def test_passing_case_leaves_nothing(self):
        seen = []

        class Probe(run_game_test.RunGameTest):
            def test_probe(self):
                seen.append(self.tmp)

        result, root, left = run_probe(Probe, "test_probe")
        self.check(result, root, left, seen, failures=0, errors=0)

    def test_failing_case_leaves_nothing(self):
        seen = []

        class Probe(run_game_test.RunGameTest):
            def test_probe(self):
                seen.append(self.tmp)
                self.fail("探针故意失败")

        result, root, left = run_probe(Probe, "test_probe")
        self.check(result, root, left, seen, failures=1, errors=0)

    def test_setup_error_after_the_directory_exists_leaves_nothing(self):
        seen = []

        class Probe(run_game_test.RunGameTest):
            def _png(self):
                seen.append(self.tmp)   # setUp 已建好目录、正要写第一个文件
                raise RuntimeError("探针：setUp 在建目录之后出错")

            def test_probe(self):
                raise AssertionError("setUp 出错时用例体不该被执行")

        result, root, left = run_probe(Probe, "test_probe")
        self.check(result, root, left, seen, failures=0, errors=1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
