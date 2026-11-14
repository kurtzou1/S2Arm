"""App 包运行时不写 .pyc（launchers/macos/bundle_engine.py seal_runtime / precompile）。
11-14：已装的 S2Arm.app 被写进 256 个 .pyc，codesign 报「a sealed resource is missing or invalid」。各调用点带 -B 守不住
（-I 忽略 PYTHONDONTWRITEBYTECODE、子进程不继承 -B、encodings 在 site 之前导入）。这里用本机 Python 搭一个小型 Resources 跑真流程，期望手写：
① seal_runtime 后 site-packages 有 sitecustomize，标准库副本、Jobs 里的 .py 都有对应 .pyc，且 .pyc 是 checked-hash（flags = 3）
② precompile(Engine) 后引擎源码也有 .pyc
③ 用这份 Python、不带 -B、清空环境，导入标准库副本 / Jobs / Engine 模块：文件一个不多
   （sitecustomize 那层要真内置 Python 才生效——小型目录借的是本机 Python 的家；已在 v0.3.10 真 App 副本上核过，这里核预编这一层）
④ 负对照：没封过的同样一份，同样调用会多出 .pyc"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "launchers/macos")); sys.path.insert(0, str(HERE.parent / "pack/jobs"))
import bundle_engine   # noqa: E402

VER = f"python{sys.version_info.major}.{sys.version_info.minor}"


def fake_resources(root):
    """小型 Resources：Runtime/python/bin/python3 指向本机 Python 的「家」（标准库副本只放 json 包，够看写不写）、Jobs、Engine"""
    r = root / "Resources"
    home = r / "Runtime/python"
    (home / "bin").mkdir(parents=True); (home / f"lib/{VER}/site-packages").mkdir(parents=True)
    os.symlink(sys.executable, home / "bin/python3")
    shutil.copytree(Path(shutil.__file__).parent / "json", home / f"lib/{VER}/json", ignore=shutil.ignore_patterns("__pycache__"))
    (r / "Jobs").mkdir(); (r / "Jobs/jobmod.py").write_text("X = 1\n")
    (r / "Engine/translator").mkdir(parents=True); (r / "Engine/translator/xmod.py").write_text("Y = 2\n")
    return r


def files(root):
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


def poke(r):
    """最坏的调用：不带 -B、环境清空；导入随包的 json 副本、Jobs、Engine 模块，并打印 dont_write_bytecode"""
    code = ("import sys; sys.path[:0] = [sys.argv[1] + '/Jobs', sys.argv[1] + '/Engine/translator', sys.argv[2]]; "
            "import json, jobmod, xmod; assert json.__file__.startswith(sys.argv[2]), json.__file__")
    subprocess.run([str(r / "Runtime/python/bin/python3"), "-c", code, str(r), str(r / f"Runtime/python/lib/{VER}")],
                         env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, check=True)


class BundleBytecode(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)

    def test_sealed_bundle_writes_nothing(self):
        r = fake_resources(self.t)
        bundle_engine.seal_runtime(r)
        bundle_engine.precompile(r / "Engine", r / bundle_engine.RUNTIME_PYTHON)
        site = r / f"Runtime/python/lib/{VER}/site-packages/sitecustomize.py"
        self.assertIn("dont_write_bytecode = True", site.read_text())
        pycs = list(r.rglob("*.pyc"))
        for src in [*(r / f"Runtime/python/lib/{VER}/json").glob("*.py"), r / "Jobs/jobmod.py", r / "Engine/translator/xmod.py", site]:
            with self.subTest(src=src.name):
                self.assertTrue(any(p.parent == src.parent / "__pycache__" and p.name.startswith(src.stem + ".") for p in pycs))
        for p in pycs:
            self.assertEqual(int.from_bytes(p.read_bytes()[4:8], "little"), 3, p)   # PEP 552：bit0 哈希、bit1 checked
        before = files(r)
        poke(r)
        self.assertEqual(files(r), before)

    def test_unsealed_bundle_gets_bytecode_written(self):
        r = fake_resources(self.t)
        before = files(r)
        poke(r)
        self.assertTrue(set(files(r)) - set(before))


if __name__ == "__main__":
    unittest.main()
