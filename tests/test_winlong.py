#!/usr/bin/env python3
"""Windows 长路径（pack/orch/winlong.py）。纯函数在所有平台测；真实文件操作只在 Windows 上跑"""
import ntpath
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.orch import winlong
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import redact


class LongPathTest(unittest.TestCase):
    def test_short_paths_untouched(self):
        self.assertEqual(winlong.long_path("C:\\a\\b.txt"), "C:\\a\\b.txt")
        self.assertEqual(winlong.long_path(7), 7)     # 文件描述符
        self.assertIsNone(winlong.long_path(None))

    def test_long_paths_prefixed(self):
        path = "C:\\" + "a\\" * 130 + "f.txt"
        self.assertGreater(len(path), winlong.LIMIT)
        self.assertEqual(winlong.long_path(path), "\\\\?\\" + path)
        self.assertEqual(winlong.long_path("\\\\?\\" + path), "\\\\?\\" + path)   # 不重复加
        unc = "\\\\srv\\share\\" + "a\\" * 130 + "f"
        self.assertEqual(winlong.long_path(unc), "\\\\?\\UNC\\srv\\share\\" + "a\\" * 130 + "f")

    def test_reparse_buffer_layout(self):   # 期望按 Windows REPARSE_DATA_BUFFER 挂载点版手写：替换名 8 个宽字符、显示名 4 个宽字符
        sub = "\\??\\C:\\a".encode("utf-16-le"); shown = "C:\\a".encode("utf-16-le")
        self.assertEqual(len(sub), 16); self.assertEqual(len(shown), 8)
        body = (0).to_bytes(2, "little") + (16).to_bytes(2, "little") + (18).to_bytes(2, "little") + (8).to_bytes(2, "little") + sub + b"\0\0" + shown + b"\0\0"
        self.assertEqual(winlong.reparse_buffer("C:\\a"), (0xA0000003).to_bytes(4, "little") + (36).to_bytes(2, "little") + b"\0\0" + body)

    def test_scandir_keeps_callers_path_form(self):   # #138：目录项路径带 \\?\ 前缀时，relative_to 比不上不带前缀的根
        import types
        parent = "C:\\" + "a\\" * 130 + "d"
        closed = []
        class Entries:
            def __iter__(self): return self
            def __init__(self): self.items = iter([types.SimpleNamespace(name="f.bin", path="\\\\?\\" + parent + "\\f.bin", is_dir=lambda follow_symlinks=True: False)])
            def __next__(self): return next(self.items)
            def close(self): closed.append(True)
        seen = []
        fake = types.SimpleNamespace(scandir=lambda p=".": (seen.append(p), Entries())[1])
        winlong._wrap_scandir(fake)
        with fake.scandir(parent) as it:
            entries = list(it)
        self.assertEqual(seen, ["\\\\?\\" + parent])            # 系统调用用长路径前缀
        self.assertEqual(entries[0].path, parent + "\\f.bin")      # 调用方拿到的路径没有前缀
        self.assertEqual(os.fspath(entries[0]), parent + "\\f.bin")
        self.assertEqual((entries[0].name, entries[0].is_dir()), ("f.bin", False))
        self.assertEqual(closed, [True])
        short = "C:\\a"
        fake.scandir(short)
        self.assertEqual(seen[-1], short)

    def test_short_entry_mapping(self):
        from pack.orch import shortroot as sr
        long = "R:\\" + "d" * 200 + "\\lib"
        link = "C:\\Users\\u\\AppData\\Local\\S2A\\j\\ab12"
        t = sr.parse_table(f"{long}\t{link}")
        self.assertEqual(sr.to_short(long + "\\work\\a.bin", t), link + "\\work\\a.bin")
        self.assertEqual(sr.to_short("\\\\?\\" + long + "\\x", t), link + "\\x")
        self.assertEqual(sr.to_short(long.upper() + "\\x", t), link + "\\x")
        self.assertEqual(sr.to_short(long + "2\\x", t), long + "2\\x")
        self.assertEqual(sr.to_long(link + "\\work", t), long + "\\work")
        self.assertEqual(sr.to_long("C:\\x", t), "C:\\x")

    def test_remap_env_moves_tool_cache_vars_under_short_root(self):
        # v0.3.0 win_cases deep：工具缓存 <库>/tool-cache 经环境变量传给出包链，库在深目录时要一并换成短入口。期望手写
        from pack.orch import shortroot
        lib = 'T:\\deep\\' + 'p' * 200 + '\\DefaultLibrary'
        env = {'S2A_RUN_ROOT': lib + '\\tool-cache\\run', 'S2A_CS_CACHE': lib + '\\tool-cache\\cache\\nxaot',
               'S2A_PROGRESS': 'C:\\Users\\u\\AppData\\Local\\S2Arm\\logs\\t.tsv', 'PATH': 'C:\\Windows', 'X': lib + '\\tool-cachex', 'EMPTY': ''}
        changed = shortroot.remap_env(env, lib + '\\tool-cache', 'C:\\L\\S2A\\j\\ab12\\tool-cache')
        self.assertEqual(sorted(changed), ['S2A_CS_CACHE', 'S2A_RUN_ROOT'])
        self.assertEqual(env['S2A_RUN_ROOT'], 'C:\\L\\S2A\\j\\ab12\\tool-cache\\run')
        self.assertEqual(env['S2A_CS_CACHE'], 'C:\\L\\S2A\\j\\ab12\\tool-cache\\cache\\nxaot')
        self.assertEqual(env['X'], lib + '\\tool-cachex', '同名前缀的兄弟目录不动')
        self.assertTrue(env['S2A_PROGRESS'].startswith('C:\\Users'), '不在工具缓存下的不动')

    def test_short_codes_are_stable_four_chars_and_probe(self):
        from pack.orch import shortroot as sr
        a = list(sr.codes("R:\\lib"))
        self.assertEqual(a[:3], list(sr.codes("r:\\LIB"))[:3])   # 同一目录每次相同（路径不分大小写）
        self.assertTrue(all(len(c) == 4 for c in a)); self.assertEqual(len(set(a)), len(a))   # 被占用时顺延，不重复
        self.assertNotEqual(a[0], next(sr.codes("R:\\lib2")))

    def test_targets_use_common_parent_per_drive(self):
        from pack.orch import shortroot as sr
        self.assertEqual(sr.group_targets(["R:\\lib\\iPhone\\g\\work", "R:\\lib\\cache\\g\\extract"]), ["R:\\lib"])
        self.assertEqual(sorted(sr.group_targets(["R:\\lib\\w", "D:\\x"])), ["D:\\x", "R:\\lib\\w"])

    def test_sweep_removes_orphan_pid_without_junction(self):   # 审计 P2-217：写了 .pid、联接没建成就被杀，残留 .pid 要被扫掉；进程还活着的不动
        from pack.orch import shortroot as sr
        with tempfile.TemporaryDirectory() as root:
            Path(root, "ab12.pid").write_text("111")
            Path(root, "cd34.pid").write_text("222")
            self.assertEqual(sr.sweep(root, alive=lambda pid: pid == 222), 1)
            self.assertEqual(sorted(os.listdir(root)), ["cd34.pid"])

    @unittest.skipUnless(os.name == "nt", "只在 Windows 上有目录联接")
    def test_junction_to_long_target_is_usable(self):   # 目标超过 240 字符：不能加 \\\\?\\，否则联接非法
        import _winapi
        with tempfile.TemporaryDirectory() as t:
            deep = t
            while len(deep) < 260: deep = os.path.join(deep, "d" * 30)
            winlong.install(); os.makedirs(deep); Path(deep, "f.txt").write_bytes(b"x")
            link = os.path.join(t, "j"); _winapi.CreateJunction(deep, link)
            self.assertEqual(Path(link, "f.txt").read_bytes(), b"x")
            os.rmdir(link)

    @unittest.skipUnless(os.name == "nt", "只在 Windows 上有目录联接")
    def test_teardown_removes_only_the_junction(self):
        import _winapi
        from pack.orch import shortroot as sr
        with tempfile.TemporaryDirectory() as t:
            target = os.path.join(t, "target"); os.makedirs(os.path.join(target, "sub"))
            Path(target, "sub", "keep.bin").write_bytes(b"x")
            os.environ["LOCALAPPDATA"], old = t, os.environ.get("LOCALAPPDATA")
            try:
                got = sr.enter(target)
                link = next(iter(got.values()))
                self.assertTrue(os.path.isfile(os.path.join(link, "sub", "keep.bin")))
                self.assertEqual(sr.show(link + "\\sub"), target + "\\sub")
                sr.remove_entry(link)
                self.assertFalse(os.path.lexists(link)); self.assertFalse(os.path.exists(link + ".pid"))
                self.assertEqual(Path(target, "sub", "keep.bin").read_bytes(), b"x")      # 目标原样
                root = sr.entry_dir(); stale = os.path.join(root, "zzzz"); _winapi.CreateJunction(target, stale); Path(stale + ".pid").write_text("1")
                self.assertEqual(sr.sweep(root, alive=lambda pid: False), 1); self.assertFalse(os.path.lexists(stale)); self.assertTrue(os.path.isfile(os.path.join(target, "sub", "keep.bin")))
                live = os.path.join(root, "yyyy"); _winapi.CreateJunction(target, live); Path(live + ".pid").write_text("1")
                self.assertEqual(sr.sweep(root, alive=lambda pid: True), 0); self.assertTrue(os.path.lexists(live)); sr.remove_entry(live)
            finally:
                os.environ["LOCALAPPDATA"] = old or ""

    @unittest.skipUnless(os.name == "nt", "只在 Windows 上有目录联接")
    def test_enter_skips_code_held_by_pid_file(self):   # 审计 P2-217：首选短号只剩 .pid（另一任务刚占 / 活着的残留）时顺延到下一个，不整次退回长路径
        from pack.orch import shortroot as sr
        with tempfile.TemporaryDirectory() as t:
            target = os.path.join(t, "target"); os.makedirs(target)
            os.environ["LOCALAPPDATA"], old = t, os.environ.get("LOCALAPPDATA")
            try:
                root = sr.entry_dir(); os.makedirs(root, exist_ok=True)
                first, second = list(sr.codes(ntpath.abspath(target)))[:2]
                Path(root, first + ".pid").write_text(str(os.getpid()))   # 本进程活着：sweep 不扫
                got = sr.enter(target)
                self.assertEqual(ntpath.basename(next(iter(got.values()))), second)
                sr.remove_entry(ntpath.join(root, second)); os.remove(ntpath.join(root, first + ".pid"))
            finally:
                os.environ["LOCALAPPDATA"] = old or ""

    @unittest.skipUnless(os.name == "nt", "只在 Windows 上有 OpenProcess")
    def test_alive_treats_access_denied_as_alive(self):   # 审计 P2-217：打不开的系统进程（拒绝访问）算活着，不存在的进程号算死
        from pack.orch import shortroot as sr
        import subprocess
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq csrss.exe", "/FO", "CSV", "/NH"], capture_output=True, text=True).stdout
        pid = int(out.split(",")[1].strip('"'))
        self.assertTrue(sr._alive(pid))
        self.assertTrue(sr._alive(os.getpid()))
        self.assertFalse(sr._alive(0x7FFFFFF0))

    def test_redact_keeps_windows_path_length(self):
        out = redact.redact_text(r"[WinError 206] : 'C:\Users\example\a\b.txt'")
        self.assertIn("[PRIVATE_PATH len=", out)
        self.assertNotIn("example", out.split("PRIVATE_PATH")[1])
        self.assertEqual(redact.redact_text("/Users/example/a.txt"), "[PRIVATE_PATH]")   # 非 Windows 路径不变


@unittest.skipUnless(os.name == "nt", "真实文件操作只在 Windows 上跑")
class RealFilesTest(unittest.TestCase):
    def test_operations_past_260(self):
        winlong.install()
        root = tempfile.mkdtemp()
        deep = Path(root, *["d" * 30] * 10)
        self.addCleanup(shutil.rmtree, winlong.long_path(root), True)
        deep.mkdir(parents=True)
        f = deep / "file.txt"
        self.assertGreater(len(str(f)), 260)
        f.write_text("x", encoding="utf-8")
        self.assertTrue(f.exists() and f.is_file() and os.path.isfile(f))
        self.assertEqual(f.stat().st_size, 1)
        self.assertEqual([p.name for p in deep.iterdir()], ["file.txt"])
        copied = deep / "copy.txt"
        shutil.copy2(f, copied)
        self.assertEqual(copied.read_text(encoding="utf-8"), "x")
        moved = deep / "moved.txt"
        os.replace(copied, moved)
        self.assertEqual(sorted(n for _, _, names in os.walk(root) for n in names), ["file.txt", "moved.txt"])


if __name__ == "__main__":
    unittest.main()
