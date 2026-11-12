#!/usr/bin/env python3
"""Real C CLI integration through the packaging rewrite stage, offline."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests/rewrite_corpus"))
spec = importlib.util.spec_from_file_location("corpus", ROOT / "tests/rewrite_corpus/run.py")
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)
spec = importlib.util.spec_from_file_location("pack_rewriter", ROOT / "pack/rewriter.py")
rewriter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rewriter)


def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


class DependencyDiscovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rewriter-deps-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.explicit = self.root / "explicit"
        self.checkout = self.root / "repo/build/rewriter-deps"
        self.shared = self.root / "home/.s2arm/run/s2arm/deps/rewriter-deps"
        self.enterContext(mock.patch.object(rewriter, "ROOT", self.root / "repo"))
        self.enterContext(mock.patch.object(Path, "home", return_value=self.root / "home"))
        self.enterContext(mock.patch.dict(os.environ, S2A_REWRITER_DEPS=str(self.explicit)))

    def prepare(self, directory):
        # Only test discovery here; real dependency compilation is exercised below.
        for name in ("capstone-5.0.7/src/CMakeLists.txt", "lz4-4.4.5/lz4libs/lz4.c"):
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("discovery fixture\n")

    def test_explicit_then_checkout_then_shared(self):
        for directory in (self.shared, self.checkout, self.explicit):
            self.prepare(directory)
            self.assertEqual(rewriter.dependency_dir(), directory.resolve())

    def test_shared_is_used_without_environment_override(self):
        self.prepare(self.shared)
        with mock.patch.dict(os.environ, S2A_REWRITER_DEPS=""):
            self.assertEqual(rewriter.dependency_dir(), self.shared.resolve())

    def test_incomplete_candidate_does_not_hide_complete_shared_directory(self):
        self.prepare(self.explicit)
        (self.explicit / "lz4-4.4.5/lz4libs/lz4.c").unlink()
        self.prepare(self.shared)
        self.assertEqual(rewriter.dependency_dir(), self.shared.resolve())

    def test_all_candidates_missing_fail_without_creating_directories(self):
        with self.assertRaisesRegex(ValueError, "缺 C 改写器固定依赖"):
            rewriter.dependency_dir()
        self.assertEqual(list(self.root.iterdir()), [])


class GoldenWorkflow(unittest.TestCase):
    """Only test the C golden gate orchestration with explicit protocol stand-ins."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rewrite-golden-flow-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("tests/fixtures", "pack", "data"):
            (self.root / name).mkdir(parents=True)
        for name in ("rewrite_apple_golden_test.sh", "rewriter_exec.py"):
            shutil.copy2(ROOT / "tests" / name, self.root / "tests" / name)
        self.calls = self.root / "calls.log"
        self.env = dict(os.environ, S2A_PY=sys.executable,
                        S2A_REWRITE_GOLDEN_DIR=str(self.root / "data"), GOLDEN_CALLS=str(self.calls))
        self.env.pop("REW", None)
        rows = []
        for name in ("case_a", "case_b"):
            source = self.root / "data" / name / "exefs/main"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"workflow input, not an NSO")
            rows.append("\t".join((name, hashlib.sha256(b"expected-bin").hexdigest(),
                                    hashlib.sha256(b"expected-fixups").hexdigest())))
        (self.root / "tests/fixtures/rewrite_apple_golden.tsv").write_text("\n".join(rows) + "\n")
        data = b"workflow input, not an NSO"   # 输入身份表：替身输入不是 NSO，构建号（0x40 起）读出来是空
        (self.root / "tests/fixtures/rewrite_apple_golden_inputs.tsv").write_text("# 款\tSHA-256\t字节数\t构建号\n" + "".join(
            f"{name}\t{hashlib.sha256(data).hexdigest()}\t{len(data)}\t\n" for name in ("case_a", "case_b")))
        for mode, relative in (("C", "c-command"), ("Extra", "extra-command")):
            command = self.root / relative
            command.write_text("#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\n"
                               f"mode = {mode!r}\n"
                               "with open(os.environ['GOLDEN_CALLS'], 'a') as log: log.write(mode + '\\n')\n"
                               "out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)\n"
                               "binary = b'wrong' if os.environ.get('GOLDEN_BAD') == mode else b'expected-bin'\n"
                               "(out / 'main.patched.bin').write_bytes(binary)\n"
                               "(out / 'main.fixups.tsv').write_bytes(b'expected-fixups')\n")
            command.chmod(0o755)
        (self.root / "pack/rewriter.py").write_text(
            "import os, sys\nfrom pathlib import Path\n"
            "assert sys.argv[1:] == ['c-path']\n"
            "with open(os.environ['GOLDEN_CALLS'], 'a') as log: log.write('resolve\\n')\n"
            "if os.environ.get('GOLDEN_NO_C') == '1': sys.exit(1)\n"
            "print(Path(__file__).resolve().parent.parent / 'c-command')\n")

    def run_gate(self, expected, **options):
        result = subprocess.run(["bash", str(self.root / "tests/rewrite_apple_golden_test.sh")],
                                env=dict(self.env, **options), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_c_compares_with_the_table(self):
        self.assertIn("C 2 / 2 同", self.run_gate(0))
        self.assertEqual(self.calls.read_text().splitlines(), ["resolve", "C", "C"])

    def test_c_mismatch_fails(self):
        self.assertIn("与 golden 不符", self.run_gate(1, GOLDEN_BAD="C"))

    def test_missing_input_is_red(self):
        (self.root / "data/case_a/exefs/main").unlink()
        self.assertIn("C 1 / 2 同", self.run_gate(1))

    def test_input_not_golden_version_is_reported_before_products(self):
        (self.root / "data/case_a/exefs/main").write_bytes(b"workflow input, not an NSO!")
        out = self.run_gate(1)
        self.assertIn("case_a 输入不是金样版本", out)
        self.assertLess(out.index("输入不是金样版本"), out.index("C 2 / 2 同"))

    def test_c_resolution_failure_is_red(self):
        self.assertIn("不能取得出包 C 改写器", self.run_gate(1, GOLDEN_NO_C="1"))
        self.assertEqual(self.calls.read_text().splitlines(), ["resolve"])

    def test_rew_override_is_extra_and_cannot_replace_the_required_c_run(self):
        self.assertIn("C 2 / 2 同", self.run_gate(
            1, REW=str(self.root / "extra-command"), GOLDEN_BAD="Extra"))
        self.assertEqual(self.calls.read_text().splitlines(), ["resolve", "C", "Extra", "C", "Extra"])


class PackagingRewrite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="pack-rewrite-")
        cls.base = Path(cls.temp.name)
        cls.env = dict(os.environ, S2A_PY=str(Path(sys.executable)), S2A_PYTHON=sys.executable,
                       S2A_JOBS="1", S2A_REWRITER_CACHE=str(cls.base / "C cache 含空格"),
                       S2A_WIDEN_AUTO=str(cls.base / "no-auto"),
                       S2A_ROOTS_SHARED=str(cls.base / "no-shared"),
                       S2A_ROOTS_NO_BOOT="1", S2A_REWRITE_SPIN="1", S2A_TARGET="apple")
        for name in ("S2A_REWRITER", "S2A_REWRITER_C", "S2A_REWRITER_BUNDLED", "S2A_ROOT_CUR", "S2A_STAGE_KEYS",
                     "S2A_JOBPOOL", "S2A_WIDEN_DIR"):
            cls.env.pop(name, None)
        cls.env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + str(ROOT / "tools/bin") + os.pathsep + cls.env["PATH"]
        result = subprocess.run([sys.executable, str(ROOT / "pack/rewriter.py"), "c-path"],
                                env=cls.env, capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.binary = Path(result.stdout.strip())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
        shutil.rmtree(corpus.T)

    def setUp(self):
        self.directory = self.base / self._testMethodName
        initial = self.directory / "roots/probe@seed"
        (initial / "exefs").mkdir(parents=True)
        (initial / "romfs").mkdir()
        self.good = initial / "exefs/main"
        corpus.nso([0xb9400008, 0x34ffffe8, 0xd53bd040, 0x91002243, 0xd4000021,
                    0xd65f03c0], {}, 24, str(self.good))
        shutil.copyfile(self.good, initial / "exefs/sdk")
        # 只出通用的根（S2A_DUAL=0 播种）没有 unpack.tsv：改写阶段的地址需求采集按 main.npdm 的 ACI0 取程序号（#459）
        npdm = bytearray(0x1000); npdm[:4] = b"META"; npdm[0x70:0x74] = (0x80).to_bytes(4, "little")
        npdm[0x80:0x84] = b"ACI0"; npdm[0x90:0x98] = (0x0100AAAA00000000).to_bytes(8, "little")
        (initial / "exefs/main.npdm").write_bytes(bytes(npdm))
        (initial / "exefs/rtld").write_bytes(b"not-an-nso: must be skipped")
        # exefs 里不是代码模块的文件（11-02 普查 010020D01B890000 的文本 main.moduleconfig）：只改写宿主装载的 main / subsdk0–9 / sdk
        (initial / "exefs/main.moduleconfig").write_bytes(b"VIA_MODULE_AUDIORENDER;VIA_MODULE_GRAPHICS")
        self.link = initial.parent / "probe@现行"
        self.link.symlink_to(initial.name, target_is_directory=True)
        self.env = dict(self.env, S2A_ROOTS=str(initial.parent))

    def stage(self, expected=0, **options):
        result = subprocess.run(["bash", str(ROOT / "pack/stage_rewrite.sh"), "probe"],
                                env=dict(self.env, **options), capture_output=True,
                                text=True, timeout=120)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def key(self, **options):
        result = subprocess.run([sys.executable, str(ROOT / "pack/rewriter.py"), "key"],
                                env=dict(self.env, **options), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def artifacts(self):
        root = self.link.resolve()
        return {p.name: p.read_bytes() for p in root.iterdir()
                if p.suffix in (".bin", ".tsv") and p.name.split(".")[0] in ("main", "sdk")}

    def test_default_c_complete_artifacts(self):
        text = self.stage()
        self.assertNotIn("跳过", text)
        before = self.artifacts()
        self.assertEqual(len(before), 10)
        self.assertFalse((self.link / "rtld.patched.bin").exists())
        self.assertFalse((self.link / "main.moduleconfig.patched.bin").exists())
        self.assertIn("跳过", self.stage())
        self.assertEqual(before, self.artifacts())
        self.assertIn("跳过", self.stage(S2A_REWRITER_DEPS=str(self.base / "absent")))

    def test_actual_c_gap_degrades_and_continues(self):
        # v0.3.1 拿不准不停：改写有缺口（退出码 3、产物照出）不再中止事务；新版本切成现行，缺口按类写进 degrade.rewrite.tsv、打【黄】（v0.3.0 起这里是 rc=1、现行不动）
        good = self.good.read_bytes()
        self.stage()
        current = self.link.resolve()
        corpus.nso([0xd503207f, 0xd65f03c0], {}, 8, str(current / "exefs/main"))
        text = self.stage(S2A_TARGET="android")
        new = self.link.resolve()
        self.assertNotEqual(current, new)
        self.assertTrue((new / "main.patched.bin").is_file())
        self.assertIn("【黄】probe 改写降级继续：没改写的缺口 1 处", text)
        rows = [line.split("\t") for line in (new / "degrade.rewrite.tsv").read_text(encoding="utf-8").splitlines() if not line.startswith("#")]
        self.assertEqual([r[:3] for r in rows][:1], [["rewrite", "gap", "1"]])
        self.assertIn("这款有 1 处程序代码暂时没法改写", rows[0][3])
        self.assertEqual(len([r for r in rows if r[1].startswith("gap:")]), 1)
        self.assertEqual(list(new.parent.glob("*.tmp")), [])
        (new / "exefs/main").write_bytes(good)   # 改回无缺口的输入：降级表随新版本消失
        self.stage(S2A_TARGET="android")
        self.assertFalse((self.link.resolve() / "degrade.rewrite.tsv").exists())

    def test_missing_c_and_invalid_backend_never_fall_back(self):
        current = self.link.resolve()
        before = hashes(current)
        self.assertIn("不可执行", self.stage(expected=1, S2A_REWRITER_C=str(self.base / "missing")))
        self.assertIn("只认 c", self.stage(expected=1, S2A_REWRITER="typo"))
        text = self.stage(expected=1, S2A_REWRITER_CACHE=str(self.directory / "empty-cache"),
                          CC=str(self.directory / "missing-compiler"))
        self.assertIn("【红】改写器", text)
        self.assertEqual(current, self.link.resolve())
        self.assertEqual(before, hashes(current))
        self.assertEqual(list(current.parent.glob("*.tmp")), [])
        # Python 改写器已删除（10-31）：显式要 python 也只报红，不回退
        self.assertIn("Python 改写器已删除", self.stage(expected=1, S2A_REWRITER="python",
                      S2A_REWRITER_C=str(self.base / "missing"),
                      S2A_REWRITER_DEPS=str(self.base / "absent")))
        self.assertEqual(before, hashes(current))

    def test_explicit_binary_content_and_backend_are_cache_inputs(self):
        binary = self.directory / "C binary 含空格"
        shutil.copy2(self.binary, binary)
        first = self.key(S2A_REWRITER_C=str(binary))
        self.assertNotEqual(first, self.key())
        self.assertNotIn("跳过", self.stage(S2A_REWRITER_C=str(binary)))
        self.assertIn("跳过", self.stage(S2A_REWRITER_C=str(binary)))
        # Only inspect the key after changing the bytes; do not execute a modified Mach-O.
        with binary.open("ab") as out:
            out.write(b"cache-key-probe")
        self.assertNotEqual(first, self.key(S2A_REWRITER_C=str(binary)))

    def test_bundled_binary_used_only_when_source_digest_matches(self):
        # App 自带（Runtime/bin/s2a-rewrite + .source）：指纹对得上就用它，对不上不用、缺依赖时报红点明
        binary = self.directory / "Runtime 含空格/bin/s2a-rewrite"
        binary.parent.mkdir(parents=True)
        shutil.copy2(self.binary, binary)
        stamp = binary.with_name("s2a-rewrite.source")
        source = hashlib.sha256()
        for name in ("CMakeLists.txt", "main.c", "rewriter.c", "rewriter.h", "prepare_deps.py"):
            source.update(name.encode() + b"\0" + (ROOT / "runtime/rewriter" / name).read_bytes())
        stamp.write_text(source.hexdigest() + "\n")
        version = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=True)
        self.assertTrue(version.stdout.startswith("s2a-rewrite capstone 5."), version.stdout)
        absent = dict(S2A_REWRITER_BUNDLED=str(binary), S2A_REWRITER_CACHE=str(self.directory / "no-cache"),
                      S2A_REWRITER_DEPS=str(self.directory / "absent"),
                      HOME=str(self.directory / "home"))   # 共享依赖回落也不在：指纹不符时只能报红
        self.assertEqual(self.key(**absent), "c:" + hashlib.sha256(binary.read_bytes()).hexdigest())
        self.assertNotIn("跳过", self.stage(**absent))
        self.assertFalse((self.directory / "no-cache").exists())
        stamp.write_text("0" * 64 + "\n")
        self.assertEqual(self.key(**absent), "c")
        self.assertIn("指纹不符", self.stage(expected=1, **absent))

    def test_key_only_does_not_build_or_write_roots(self):
        current = self.link.resolve()
        before = hashes(current)
        keys = self.directory / "keys.tsv"
        cache = self.directory / "not-created"
        self.stage(S2A_ROOT_CUR=str(current), S2A_STAGE_KEYS=str(keys),
                   S2A_REWRITER_CACHE=str(cache), S2A_REWRITER_DEPS=str(self.base / "absent"))
        self.assertTrue(keys.read_text().startswith("rewrite\t"))
        self.assertFalse(cache.exists())
        self.assertEqual(before, hashes(current))

    def test_real_inputs_enter_the_key(self):
        # 10-30 根修：改写阶段实际跑过的生成器记进 .stage_rewrite.deps 并进键（原先手工列名单，fps_warehouse / profile_guess 等漏了，热出包跳过改写用旧产物）。
        #   在仓库最小副本里跑（git 提交一次，树对象号才取得到），逐个改真实生成器：键必须变、不跳过；只算键模式（P4 快路径比键用）与落盘的键一致
        repo = self.directory / "repo"
        listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-co", "--exclude-standard", "--", "pack", "tools", "graphics/widen",
                                 "graphics/nvn/games", "graphics/nvn/tools", "translator", "runtime/rewriter", "runtime/fps", "runtime/src", "graphics/metal", "graphics/widen", "graphics/cpatch", "docs"],
                                capture_output=True, text=True, check=True).stdout.splitlines()
        for name in listed:
            if (ROOT / name).is_file():
                (repo / name).parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT / name, repo / name)
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(git + ["add", "-A"], check=True); subprocess.run(git + ["commit", "-qm", "副本"], check=True)

        def run(stage="rewrite", **options):
            r = subprocess.run(["bash", str(repo / f"pack/stage_{stage}.sh"), "probe"], env=dict(self.env, **options),
                               capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr); return r.stdout + r.stderr

        def key_only():
            keys = self.directory / "keys.tsv"; keys.unlink(missing_ok=True)
            run(S2A_ROOT_CUR=str(self.link.resolve()), S2A_STAGE_KEYS=str(keys), S2A_REWRITER_DEPS=str(self.base / "absent"))
            return keys.read_text().split("\t")[1].strip()

        def stored(): return (self.link / ".stage_rewrite").read_text().strip()
        self.assertNotIn("跳过", run())
        deps = (self.link / ".stage_rewrite.deps").read_text()
        for name in ("R:tools/fps_generic.py", "R:graphics/nvn/games/profile_guess.py", "R:tools/nro_exports.py", "R:tools/addr_need.py"):
            self.assertIn("f\t" + name + "\t", deps)
        self.assertNotIn(str(self.link.resolve().parent), deps); self.assertNotIn(str(repo), deps); self.assertNotIn("__pycache__", deps)
        self.assertIn("f\tR:pack/stage_rewrite.sh\t", deps)   # 本阶段脚本也在清单里
        self.assertEqual(key_only(), stored())
        self.assertIn("跳过", run())
        deps = lambda name="rewrite": (self.link / f".stage_{name}.deps").read_text()
        for gen in ("tools/fps_generic.py", "graphics/nvn/games/profile_guess.py", "tools/nro_exports.py"):
            before, bd = stored(), deps()
            with (repo / gen).open("a") as out:
                out.write("\n# 生成器改了（单测）\n")
            self.assertEqual(key_only(), before + "~d", gen)   # 有效键变（P4 快路径比键不相等）；存下的基础键是声明输入，不变
            self.assertNotIn("跳过", run(), gen)
            self.assertEqual(stored(), before, gen); self.assertNotEqual(deps(), bd, gen)   # 重做后清单记的是新内容
            self.assertEqual(key_only(), stored(), gen)
            self.assertIn("跳过", run(), gen)
        with (repo / "tools/stage_deps_hook/README").open("w") as out:   # 改没被读的文件：键不变
            out.write("x\n")
        self.assertIn("跳过", run())
        # 能力清单阶段同一套：判定代码按实际读入进键（原先手工列 7 个文件）
        self.assertNotIn("跳过", run("caps"))
        cd = (self.link / ".stage_caps.deps").read_text()
        self.assertIn("f\tR:tools/caps_policy.py\t", cd); self.assertNotIn("名单_验证账", cd)
        self.assertIn("跳过", run("caps"))
        bd = deps("caps")
        with (repo / "tools/caps_policy.py").open("a") as out:
            out.write("\n# 判定代码改了（单测）\n")
        self.assertNotIn("跳过", run("caps"))
        self.assertNotEqual(deps("caps"), bd)
        self.assertIn("跳过", run("caps"))
        with (repo / "tools/stage_deps_hook/README").open("w") as out:
            out.write("y\n")
        self.assertIn("跳过", run("caps"))
        # 能力的宿主实现文件（caps_policy SIGNAL_IMPL）由强信号失效键按去注释的判定文本进键、不按原始字节整份记（10-31：caps.c 改一行注释清单重出 46 秒）
        self.assertNotIn("runtime/src/caps.c", deps("caps"))
        with (repo / "runtime/src/caps.c").open("a") as out:
            out.write("\n/* 只改注释（单测） */\n")
        self.assertIn("跳过", run("caps"))
        with (repo / "runtime/src/caps.c").open("a") as out:
            out.write("static int s2a_unit_probe_caps = 1;\n")
        self.assertNotIn("跳过", run("caps"))   # 判定文本变了：强信号失效键变、清单重出
        self.assertIn("跳过", run("caps"))


    def test_default_c_cache_tracks_actual_source_bytes(self):
        tree = self.directory / "source copy"
        shutil.copytree(ROOT / "runtime/rewriter", tree / "runtime/rewriter")
        (tree / "pack").mkdir()
        shutil.copy2(ROOT / "pack/rewriter.py", tree / "pack/rewriter.py")
        command = [sys.executable, str(tree / "pack/rewriter.py"), "c-path"]
        first = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(first.stdout.strip(), str(self.binary))
        with (tree / "runtime/rewriter/main.c").open("ab") as out:
            out.write(b"\n/* changed source contents */\n")
        # The source changed while no Git commit or mtime contract was involved.
        # Rebuild from the changed bytes, even if a shared dependency fallback exists.
        result = subprocess.run(command, env=self.env, capture_output=True, text=True,
                                check=True, timeout=180)
        self.assertNotEqual(result.stdout.strip(), str(self.binary))
        self.assertTrue(Path(result.stdout.strip()).is_file())

    def test_shared_dependency_fallback_builds_and_runs_actual_c(self):
        deps = rewriter.dependency_dir()
        tree = self.directory / "checkout"
        shutil.copytree(ROOT / "runtime/rewriter", tree / "runtime/rewriter")
        home = self.directory / "home"
        shared = home / ".s2arm/run/s2arm/deps/rewriter-deps"
        shared.parent.mkdir(parents=True)
        shared.symlink_to(deps, target_is_directory=True)
        with mock.patch.object(rewriter, "ROOT", tree), \
                mock.patch.object(Path, "home", return_value=home), \
                mock.patch.dict(os.environ, S2A_REWRITER_DEPS="", S2A_REWRITER_C="",
                                S2A_REWRITER_CACHE=str(self.directory / "fallback cache")):
            binary = rewriter.c_path()
        output = self.directory / "fallback output"
        output.mkdir()
        result = subprocess.run([str(binary), str(self.good), str(output), "main"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(list(output.iterdir())), 5)

    def test_concurrent_c_builds_publish_complete_executable(self):
        cache = self.directory / "concurrent cache"
        command = [sys.executable, str(ROOT / "pack/rewriter.py"), "c-path"]
        env = dict(self.env, S2A_REWRITER_CACHE=str(cache))
        processes = [subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = [process.communicate(timeout=180) for process in processes]
        for process, (stdout, stderr) in zip(processes, results):
            self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertEqual(results[0][0], results[1][0])
        self.assertEqual(list(cache.glob(".build-*")), [])
        binary = Path(results[0][0].strip())
        output = self.directory / "published output"
        output.mkdir()
        result = subprocess.run([str(binary), str(self.good), str(output), "main"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(list(output.iterdir())), 5)

    def test_full_stage_comparison_retains_hashes_and_timings(self):
        source = self.link.resolve()
        before = hashes(source)
        output = self.directory / "private evidence"
        result = subprocess.run([sys.executable, str(ROOT / "tests/pack_rewrite_compare.py"),
                                 "--output", str(output), "probe=" + str(source)], env=self.env,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((output / "report.json").read_text())
        case = report["cases"]["probe"]
        self.assertTrue(case["passed"])
        self.assertEqual(list(case["runs"]), ["c"])
        self.assertEqual(len(case["runs"]["c"]["artifacts"]), 10)
        for run in case["runs"].values():
            self.assertEqual(run["returncode"], 0)
            self.assertGreater(run["elapsed_seconds"], 0)
        self.assertEqual(before, hashes(source))
        self.assertTrue((output / "probe/c/stdout.log").is_file())
        again = subprocess.run([sys.executable, str(ROOT / "tests/pack_rewrite_compare.py"),
                                "--output", str(output), "probe=" + str(source)], env=self.env,
                               capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)
        self.assertEqual(report, json.loads((output / "report.json").read_text()))
        # 基线：同一输入再跑一遍，全部产物 SHA-256 必须与上次报告相同；改坏基线里一个哈希必须判失败
        rerun = self.directory / "baseline rerun"
        result = subprocess.run([sys.executable, str(ROOT / "tests/pack_rewrite_compare.py"), "--baseline", str(output / "report.json"),
                                 "--output", str(rerun), "probe=" + str(source)], env=self.env, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("与基线相同", result.stdout)
        bad = json.loads((output / "report.json").read_text())
        first = sorted(bad["cases"]["probe"]["runs"]["c"]["artifacts"])[0]
        bad["cases"]["probe"]["runs"]["c"]["artifacts"][first] = "0" * 64
        (self.directory / "bad-baseline.json").write_text(json.dumps(bad))
        result = subprocess.run([sys.executable, str(ROOT / "tests/pack_rewrite_compare.py"), "--baseline", str(self.directory / "bad-baseline.json"),
                                 "--output", str(self.directory / "bad rerun"), "probe=" + str(source)], env=self.env, capture_output=True, text=True, timeout=120)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(before, hashes(source))


if __name__ == "__main__":
    unittest.main()
