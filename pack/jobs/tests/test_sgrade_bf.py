# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级升级补可读瓦片版着色器（pack/jobs/sgrade_bf.py 与 rewrite_refresh._refresh_bf_ios）。合成目录夹具，期望值按写进去的内容手算；
整份重出（rebuild：跑出包阶段脚本）桩掉——它的真跑验收是010074F013262000 Mac 产物根实测（见提交说明）"""
import contextlib
import hashlib
import json
import os
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401  把 pack/jobs 加进路径（同其他作业层单测）
import rewrite_refresh as rr
import sgrade_bf
from core import Failure


def setUpModule():
    # 临时目录放哪（library.scratch_root，跟着游戏走）另在 test_space_measured 测；这里的合成作业没有游戏库，临时活放私有目录
    p = patch.object(sgrade_bf, "_scratch", lambda c, g: c.private); p.start(); unittest.addModuleCleanup(p.stop)


class AddToPack(unittest.TestCase):
    def test_rows_under_prefix_replaced_and_manifest_rewritten(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)
            (p / "index.tsv").write_text("game.img\t1\taa\nshaders/direct/b-c/bf/lib.idx\t5\told\n", encoding="utf-8")
            (p / "manifest.json").write_text(json.dumps({"version": 2, "files": 2, "total": 6, "index_sha256": "x"}), encoding="utf-8")
            (p / "shaders/direct/b-c/bf").mkdir(parents=True); (p / "shaders/direct/b-c/bf/lib.idx").write_bytes(b"abc")
            pid = sgrade_bf.add_to_pack(p, "shaders/direct/b-c/bf/", ["shaders/direct/b-c/bf/lib.idx"])
            want = "game.img\t1\taa\nshaders/direct/b-c/bf/lib.idx\t3\t" + hashlib.sha256(b"abc").hexdigest() + "\n"
            self.assertEqual((p / "index.tsv").read_text(encoding="utf-8"), want)
            m = json.loads((p / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual((m["files"], m["total"], m["index_sha256"], m["version"]), (2, 4, hashlib.sha256(want.encode()).hexdigest(), 2))
            self.assertEqual(pid, m["index_sha256"], "返回新资源包号（game.json ios.pack，put_game 据此判要推）")


class RefreshBfIos(unittest.TestCase):
    def setUp(self):
        self.info = {"A": {"ios": {"bfGen": sgrade_bf.BF_GEN}}, "B": {"ios": {}}, "C": {"ios": {"bfGen": 0}}, "D": {"ios": {}}}
        self.events = []
        self.c = types.SimpleNamespace(emit=lambda kind, msg="", **k: self.events.append(msg),
                                       catalog=lambda: {"games": [{"id": g, "name": g + "游戏"} for g in "ABCD"]})

    def test_four_outcomes(self):
        called = []
        def up(c, g):
            called.append(g)
            if g == "D":
                raise Failure("重出失败")
            return {"B": "updated", "C": "unavailable"}[g]
        with patch.object(rr.layout, "game_info", side_effect=lambda c, g: self.info[g]), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info[g].update(f)), \
             patch.object(sgrade_bf, "upgrade_ios", side_effect=up):
            self.assertEqual(rr._refresh_bf_ios(self.c, ["A", "B", "C", "D"]), ["B"])
        self.assertEqual(called, ["B", "C", "D"], "代数已是本引擎的（A）不重出")
        self.assertEqual(self.info["C"]["ios"].get("bfMissing"), sgrade_bf.BF_GEN, "取不到原料：记这一代，「更新 iPhone」不再因它重组容器")
        self.assertNotIn("bfMissing", self.info["D"]["ios"], "出错不是缺原料：不记，下次再试")
        self.assertTrue(any("C游戏" in e and "需要原件" in e and "B游戏" not in e for e in self.events), self.events)
        self.assertTrue(any(e.startswith("【红】D游戏") for e in self.events), self.events)

    def test_due(self):
        with patch.object(sgrade_bf.layout, "game_info", side_effect=lambda c, g: self.info[g]), \
             patch.object(sgrade_bf.layout, "ios_pack", return_value=Path("/nonexistent")), \
             patch.object(sgrade_bf, "lib_dir", return_value=Path("/x/b-c")):
            self.info["C"]["ios"]["bfMissing"] = sgrade_bf.BF_GEN
            self.assertEqual([g for g in "ABCD" if sgrade_bf.due(self.c, g)], ["B", "D"], "A 已是本代、C 本代缺原料试过")


class UpgradeMac(unittest.TestCase):
    def test_swap_and_manifest(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); rt = t / "runtime"; (rt / "romfs").mkdir(parents=True); (rt / "shaders/direct").mkdir(parents=True)
            (rt / "shaders/direct/keys.tsv").write_text("old\n"); (rt / "shaders/direct/old_only.tsv").write_text("o")
            (rt / "manifest.json").write_text(json.dumps({"files": {"main.patched.bin": [3, ""], "shaders/direct/keys.tsv": [4, ""],
                                                                    "shaders/direct/old_only.tsv": [1, ""]}, "rewriterId": "r"}))
            new = t / "new"; (new / "b-c").mkdir(parents=True); (new / "keys.tsv").write_text("k1\nk2\n"); (new / "b-c/lib.idx").write_bytes(b"12345")
            locks = []
            @contextlib.contextmanager
            def lock():
                locks.append(1); yield True
            c = types.SimpleNamespace(emit=lambda *a, **k: None, private=t)
            with patch.object(sgrade_bf, "rebuild", return_value=new):
                self.assertTrue(sgrade_bf.upgrade_mac(c, "G", rt, lock))
                m = json.loads((rt / "manifest.json").read_text())
                self.assertEqual(m["files"], {"main.patched.bin": [3, ""], "shaders/direct/keys.tsv": [6, ""], "shaders/direct/b-c/lib.idx": [5, ""]})
                self.assertEqual((m["bfGen"], m["rewriterId"]), (sgrade_bf.BF_GEN, "r"))
                self.assertEqual(sorted(p.relative_to(rt).as_posix() for p in rt.rglob("*") if p.is_file() and "shaders" in p.parts),
                                 ["shaders/direct/b-c/lib.idx", "shaders/direct/keys.tsv"], "旧库整份换掉、不留临时目录")
                self.assertEqual(locks, [1], "换库在锁里做一次")
                self.assertFalse(sgrade_bf.upgrade_mac(c, "G", rt, lock), "代数已是本引擎的：不再重出")

    def test_busy_gives_up_without_touching(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); rt = t / "runtime"; (rt / "romfs").mkdir(parents=True); (rt / "shaders/direct").mkdir(parents=True)
            (rt / "shaders/direct/keys.tsv").write_text("old\n"); m0 = json.dumps({"files": {"shaders/direct/keys.tsv": [4, ""]}})
            (rt / "manifest.json").write_text(m0)
            new = t / "new"; (new / "b-c").mkdir(parents=True); (new / "keys.tsv").write_text("k\n"); (new / "b-c/lib.idx").write_bytes(b"1")
            @contextlib.contextmanager
            def busy():
                yield False
            c = types.SimpleNamespace(emit=lambda *a, **k: None, private=t)
            with patch.object(sgrade_bf, "rebuild", return_value=new):
                self.assertFalse(sgrade_bf.upgrade_mac(c, "G", rt, busy), "玩家正在开局：这次放弃")
            self.assertEqual(((rt / "shaders/direct/keys.tsv").read_text(), (rt / "manifest.json").read_text()), ("old\n", m0), "运行版本与清单一个字节不动、不记代数")
            self.assertFalse((rt / "shaders/direct.sgbf").exists(), "不留临时目录")

    def test_mac_runtime_with_game_img(self):
        # 一款一份资源（0.6.0）：Mac 运行版本只有 game.img（iPhone 资源包那份的硬链接）、没有 romfs.std / romfs/：重出时 rebuild 看到的 romfs.std
        #   = game.img 的 RomFS 段（字节手写对比），补完删掉，game.img 不动
        import os
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); rt = t / "runtime"; (rt / "shaders/direct").mkdir(parents=True)
            engine = Path(sgrade_bf.__file__).resolve().parents[2]
            img = sgrade_bf._img(types.SimpleNamespace(engine=engine))
            seg = os.urandom(50001); ro = img.PAGE
            with open(rt / "game.img", "wb") as f:
                f.write(img.HDR.pack(img.MAGIC, img.FORMAT, 0, b"0100AAAA00000000", b"", ro, len(seg), ro + len(seg), 0, ro + len(seg)))
                f.seek(ro); f.write(seg)
            before = (rt / "game.img").read_bytes()
            (rt / "shaders/direct/keys.tsv").write_text("old\n")
            (rt / "manifest.json").write_text(json.dumps({"files": {"game.img": [len(before), ""], "shaders/direct/keys.tsv": [4, ""]}}))
            new = t / "new"; new.mkdir(); (new / "keys.tsv").write_text("k\n")
            seen = []
            def rebuild(c, gid, runtime, target, tmp):
                seen.append((runtime / "romfs.std").read_bytes()); return new
            c = types.SimpleNamespace(emit=lambda *a, **k: None, private=t, engine=engine)
            with patch.object(sgrade_bf, "rebuild", rebuild):
                self.assertTrue(sgrade_bf.upgrade_mac(c, "G", rt, None))
            self.assertEqual(seen, [seg], "重出看到的 romfs.std = RomFS 段")
            self.assertFalse((rt / "romfs.std").exists(), "补完删掉临时 romfs.std")
            self.assertEqual((rt / "game.img").read_bytes(), before, "game.img 不动")


class IosInputsImage(unittest.TestCase):
    def test_romfs_segment_becomes_image_byte_for_byte(self):
        # iPhone 款从 game.img 取材：标准 RomFS 段原样拷成临时产物根的 romfs.std（段内容按写进去的字节手写对比：不多不少），不展开成 romfs/ 散文件；
        #   其余条目（aoc/…）照旧放回产物根
        import os
        import struct
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); engine = Path(sgrade_bf.__file__).resolve().parents[2]
            c = types.SimpleNamespace(engine=engine)
            img = sgrade_bf._img(c)
            seg, aoc = os.urandom(70001), b"dlc payload"
            ro = img.PAGE; ao = img.up(ro + len(seg)); toc = img.toc_bytes([("aoc/1/data", ao, len(aoc))]); to = img.up(ao + len(aoc))
            pack, kit, exefs = t / "pack", t / "kit", t / "exefs"
            for d in (pack, kit, exefs): d.mkdir()
            (exefs / "main").write_bytes(b"main")
            with open(pack / "game.img", "wb") as f:
                f.write(img.HDR.pack(img.MAGIC, img.FORMAT, 0, b"0100AAAA00000000", b"pk", ro, len(seg), to, len(toc), to + len(toc)))
                f.seek(ro); f.write(seg); f.seek(ao); f.write(aoc); f.seek(to); f.write(toc)
            fake_sgrade = types.SimpleNamespace(saved_program=lambda c, g: exefs)
            with patch.object(sgrade_bf.layout, "ios_pack", return_value=pack), patch.object(sgrade_bf.layout, "ios_kit", return_value=kit), \
                 patch.object(sgrade_bf.layout, "image_mac", return_value=t / "no-mac"), patch.dict("sys.modules", {"sgrade": fake_sgrade}):
                root, how = sgrade_bf.ios_inputs(c, "0100AAAA00000000", t / "work")
            self.assertEqual(how, "game.img")
            self.assertEqual((root / "romfs.std").read_bytes(), seg, "镜像 = game.img 的 RomFS 段，逐字节相同")
            self.assertFalse((root / "romfs").exists(), "不展开 romfs/")
            self.assertEqual((root / "aoc/1/data").read_bytes(), aoc)
            self.assertTrue(sgrade_bf._has_romfs(root))




class RechainIos(unittest.TestCase):
    """0.6.0（11-17 维护者定）：着色器链变了只重编这款的着色器库、不重出整款（sgrade_bf.rechain_ios）。资源包与 game.json 是合成的，
    rebuild（跑出包阶段脚本）与 ios_inputs（取原料）桩掉；期望按写进去的内容手算"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        t = Path(self.tmp.name)
        self.pack = t / "pack"
        (self.pack / "romfs").mkdir(parents=True); (self.pack / "romfs/a").write_bytes(b"12345")
        old = self.pack / "shaders/direct/b-old"; old.mkdir(parents=True)
        (old / "lib.idx").write_bytes(b"OLD"); (self.pack / "shaders/direct/keys.tsv").write_text("k\n")
        rows = ["romfs/a\t5\th1", "shaders/direct/b-old/lib.idx\t3\th2", "shaders/direct/keys.tsv\t2\th3"]
        (self.pack / "index.tsv").write_text("".join(r + "\n" for r in rows), encoding="utf-8")
        (self.pack / "manifest.json").write_text(json.dumps({"version": 2, "files": 3, "total": 10, "index_sha256": "pid0"}), encoding="utf-8")
        self.new = t / "built/shaders/direct"
        (self.new / "b-new").mkdir(parents=True); (self.new / "b-new/lib.idx").write_bytes(b"NEWLIB"); (self.new / "keys.tsv").write_text("k2\n")
        import host_update
        self.info = {"ios": {"dmshChain": "old", "pack": "pid0", "bfGen": 0, "shellId": "S", "libGen": host_update.LIB_GEN}}
        self.c = types.SimpleNamespace(emit=lambda *a, **k: None, private=str(t), logs=str(t), task="t")

    BUILT = {"version": "9.9.9", "display": "9.9.9"}   # 本版启动器（桩）：重编后记进 builtBy

    def run_rechain(self, chain="new", src=True, rebuilt=None, ios_miss=0, cur="9.9.9"):
        calls = []
        def inputs(c, gid, work):
            return (Path(work) / "root", "game.img") if src else (None, "none")
        def build(c, gid, s, plat, work):
            calls.append(plat); return rebuilt or self.new
        with patch("host_update.engine_compat", lambda c: dict(hostAbi=1, dmshChain=chain)), \
                patch("host_update.shader_misses", lambda c, g: dict(ios=ios_miss, mac=0)), patch("host_update.built_by", lambda c: self.BUILT), \
                patch("core.release_version", lambda engine: cur), patch.object(self.c, "engine", None, create=True), \
                patch.object(sgrade_bf.layout, "game_info", lambda c, g: self.info), patch.object(sgrade_bf.layout, "ios_pack", lambda c, g: self.pack), \
                patch.object(sgrade_bf.layout, "update_info", lambda c, g, ios: self.info.update(ios=ios)), \
                patch.object(sgrade_bf, "ios_inputs", inputs), patch.object(sgrade_bf, "rebuild", build):
            return sgrade_bf.rechain_ios(self.c, "0100AAAA00000000"), calls

    def test_same_chain_skips(self):
        r, calls = self.run_rechain(chain="old")
        self.assertEqual((r, calls), ("skip", []))

    def test_chain_changed_rebuilds_only_shader_library(self):
        r, calls = self.run_rechain()
        self.assertEqual((r, calls), ("updated", ["ios"]))
        d = self.pack / "shaders/direct"
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["b-new", "keys.tsv"], "旧库目录整份换掉")
        self.assertEqual((d / "b-new/lib.idx").read_bytes(), b"NEWLIB")
        self.assertEqual((self.pack / "romfs/a").read_bytes(), b"12345", "资源本体不动")
        want_rows = ["romfs/a\t5\th1", f"shaders/direct/b-new/lib.idx\t6\t{hashlib.sha256(b'NEWLIB').hexdigest()}",
                     f"shaders/direct/keys.tsv\t3\t{hashlib.sha256(b'k2' + bytes([10])).hexdigest()}"]
        ix = (self.pack / "index.tsv").read_text(encoding="utf-8")
        self.assertEqual(ix, "".join(r + "\n" for r in want_rows))
        pid = hashlib.sha256(ix.encode()).hexdigest()
        self.assertEqual(json.loads((self.pack / "manifest.json").read_text(encoding="utf-8"))["index_sha256"], pid)
        import host_update
        self.assertEqual(self.info["ios"], {"dmshChain": "new", "pack": pid, "bfGen": sgrade_bf.BF_GEN, "shellId": "S", "libGen": host_update.LIB_GEN, "builtBy": self.BUILT})
        self.assertFalse((self.pack / "shaders/.direct-old").exists() or (self.pack / "shaders/.direct-new").exists(), "不留临时目录")

    def test_same_chain_old_lib_generation_rebuilds(self):
        # 期望（手写）：链号相同但记录里没有 libGen（0.5.x 出的库，不带客体输入）→ 照样只重编着色器库、记上当前代数；代数已是当前的 → 跳过（上面那条）
        import host_update
        del self.info["ios"]["libGen"]
        r, calls = self.run_rechain(chain="old")
        self.assertEqual((r, calls), ("updated", ["ios"]))
        self.assertEqual((self.info["ios"]["dmshChain"], self.info["ios"]["libGen"]), ("old", host_update.LIB_GEN))

    def test_shader_miss_on_old_build_rebuilds(self):
        # 期望（手写，#1756）：链号、代数都是当前的，但手机上现场翻译过 3 支包里没有的着色器、库是 0.5.8 出的（本版 9.9.9）
        #   → 只重编着色器库、记本版 builtBy（「建议更新」的 shaderMiss 随之消掉）；链号不变
        self.info["ios"]["builtBy"] = {"version": "0.5.8", "display": "0.5.8"}
        r, calls = self.run_rechain(chain="old", ios_miss=3)
        self.assertEqual((r, calls), ("updated", ["ios"]))
        self.assertEqual((self.info["ios"]["dmshChain"], self.info["ios"]["builtBy"]), ("old", self.BUILT))

    def test_shader_miss_on_current_build_skips(self):
        # 期望手写：现场翻译过、但库已是本版出的（9.9.9）→ 重编也补不上（出包流程的事），不重编
        self.info["ios"]["builtBy"] = dict(self.BUILT)
        self.assertEqual(self.run_rechain(chain="old", ios_miss=3), ("skip", []))

    def test_no_miss_old_build_skips(self):
        # 期望手写：库是旧版出的、但手机上没现场翻译过（0 支）→ 不重编（不因版本旧白跑几十分钟）
        self.info["ios"]["builtBy"] = {"version": "0.5.8", "display": "0.5.8"}
        self.assertEqual(self.run_rechain(chain="old", ios_miss=0), ("skip", []))

    def test_no_material_unavailable_and_untouched(self):
        before = (self.pack / "index.tsv").read_text(encoding="utf-8")
        r, calls = self.run_rechain(src=False)
        self.assertEqual((r, calls), ("unavailable", []))
        self.assertEqual((self.pack / "index.tsv").read_text(encoding="utf-8"), before)
        self.assertEqual(self.info["ios"]["dmshChain"], "old", "没重编就不记新链号（「建议更新」照旧提示）")

    def test_windows_without_metal_unavailable_and_untouched(self):
        # 期望手写：Windows 没装 Metal 开发工具时重出给 None（同 Windows 出包不带着色器库）→ 'unavailable'、资源包与链号都不动，推送照常（调用方记一行）
        before = (self.pack / "index.tsv").read_text(encoding="utf-8")
        with patch.object(sgrade_bf, "rebuild", lambda *a: None), patch("host_update.engine_compat", lambda c: dict(hostAbi=1, dmshChain="new")), \
                patch.object(sgrade_bf.layout, "game_info", lambda c, g: self.info), patch.object(sgrade_bf.layout, "ios_pack", lambda c, g: self.pack), \
                patch.object(sgrade_bf, "ios_inputs", lambda c, g, w: (Path(w) / "root", "game.img")):
            r = sgrade_bf.rechain_ios(self.c, "0100AAAA00000000")
        self.assertEqual(r, "unavailable")
        self.assertEqual((self.pack / "index.tsv").read_text(encoding="utf-8"), before)
        self.assertEqual(self.info["ios"]["dmshChain"], "old")

    def test_incomplete_rebuild_raises_and_keeps_old(self):
        bad = Path(self.tmp.name) / "bad/shaders/direct"; bad.mkdir(parents=True)
        with self.assertRaises(Failure):
            self.run_rechain(rebuilt=bad)
        self.assertTrue((self.pack / "shaders/direct/b-old/lib.idx").is_file(), "重编不完整不动旧库")


class WindowsRebuildTests(unittest.TestCase):
    """Windows 重出直连库（_rebuild_win）：另起进程跑 Windows 出包的直连库那一步（oneclick_win.direct），环境用作业层的（c.env）＋ iOS 平台 ＋ 这款的直连缓存。期望按方案手写"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        t = Path(self.tmp.name)
        self.root = t / "src"; (self.root / "exefs").mkdir(parents=True)
        (self.root / "shaders/direct/b-old").mkdir(parents=True); (self.root / "extract").mkdir()   # 旧库与旧抽取：重出前要清掉
        self.seen = {}; self.metal = True
        def run(args, log, env, cwd=None, **k):
            root, work, tid = Path(args[-3]), Path(args[-2]), args[-1]
            self.seen.update(code=args[4], root=root, tid=tid, env=env, cwd=cwd, stale=[p for p in ("shaders/direct", "extract") if (root / p).exists()])
            out = work / "direct"
            if self.metal:
                (out / "b-new").mkdir(parents=True); (out / "b-new/lib.idx").write_bytes(b"L"); (out / "keys.tsv").write_text("k\n")
            (work / "direct_result.txt").write_text(str(out) if self.metal else "", encoding="utf-8")
        self.c = types.SimpleNamespace(engine=str(t / "eng"), logs=str(t / "logs"), task="t", env=lambda: {"S2A_PREBUILT_TOOLS": "pre"}, run=run)

    def rebuild(self):
        with patch.object(sgrade_bf, "WIN", True), patch.object(sgrade_bf, "_win_profile", lambda c, root: self.seen.setdefault("profile", Path(root))), \
                patch("library.direct_cache_dir", lambda c, g: Path(self.tmp.name) / "dcache" / g):
            return sgrade_bf.rebuild(self.c, "0100aaaa00000000", self.root, "ios", Path(self.tmp.name) / "w")

    def test_runs_windows_direct_step_in_job_env(self):
        out = self.rebuild()
        self.assertEqual(sgrade_bf.lib_dir(out).name, "b-new")
        self.assertIn("ow.direct(", self.seen["code"])
        self.assertEqual((self.seen["root"], self.seen["tid"], self.seen["cwd"]), (self.root, "0100AAAA00000000", self.c.engine))
        self.assertEqual(self.seen["profile"], self.root, "先补配置档")
        self.assertEqual(self.seen["stale"], [], "旧库 / 旧抽取不带进重出")
        env = self.seen["env"]
        self.assertEqual((env["S2A_PREBUILT_TOOLS"], env["S2A_PACK_PLAT"], env["S2A_DIRECT_CACHE"]),
                         ("pre", "ios", str(Path(self.tmp.name) / "dcache" / "0100aaaa00000000")), "作业层环境（随包预编件）＋ iOS ＋ 这款出包时的直连缓存")

    def test_no_metal_gives_none(self):
        self.metal = False
        self.assertIsNone(self.rebuild())

if __name__ == "__main__":
    unittest.main()
