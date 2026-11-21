# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""只重跑改写阶段（pack/jobs/rewrite_refresh.py）的接线：改写器换成按模块打统计行的假程序，游戏库换成内存里的 game.json。
真改写器上的读数（11-11）：路易吉洋馆 3 命中 main、换进的产物等于改写器直接输出；两款反例 kit 一个字节不动；改写器崩的款抛错、kit 不动。"""
import os
import shutil
import stat
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401  把 pack/jobs 加进路径（同其他作业层单测）
import rewrite_refresh as rr
from core import Failure


def fake_rewriter(d, hits, key="x18_spdyn"):
    """假改写器：<NSO> <输出目录> <模块> [宽屏表] → 写 <模块>.patched.bin（内容 = 模块名 + new），统计行里 x18_spdyn 按 hits 给"""
    p = Path(d) / "fake-rewrite"
    p.write_text("#!/bin/sh\nprintf 'new-%s' \"$3\" > \"$2/$3.patched.bin\"\nprintf 'fx' > \"$2/$3.fixups.tsv\"\n"
                 "case \" " + " ".join(hits) + " \" in *\" $3 \"*) n=38;; *) n=0;; esac\n"
                 "echo \"$3 {'plain': 1, '" + key + "': $n}\"\n")
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return str(p)


class RewriteRefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.exefs = self.tmp / "exefs"; self.exefs.mkdir()
        for m in ("main", "sdk", "subsdk0", "main.npdm", "rtld"):
            (self.exefs / m).write_bytes(b"x")
        self.info = {}
        self.events = []
        self.sg_calls = []
        self.c = jobcase.fake_context(self.tmp, private=self.tmp, emit=lambda kind, text, **_: self.events.append(text), library=self.tmp / "library", work_root=self.tmp / "work",
                                       catalog=lambda: {"games": [{"id": g} for g in ("0100A", "0100B")]})

    def test_rewriter_bin_decodes_utf8_child_output_explicitly(self):
        binary = self.tmp / "rewriter"
        binary.write_text("fixture")

        def run(args, **kwargs):
            # The Windows child runs with -X utf8, while the host locale may be GBK.
            # Require a decoder that can read the child's UTF-8 output and diagnostics.
            self.assertEqual(kwargs.get("encoding"), "utf-8")
            self.assertEqual(kwargs.get("errors"), "replace")
            return subprocess.CompletedProcess(args, 0, stdout=f"{binary}\n", stderr="")

        with patch.object(rr.subprocess, "run", side_effect=run):
            self.assertEqual(rr.rewriter_bin(self.c), str(binary))

    def kit(self, gid):
        k = self.tmp / ("kit-" + gid); k.mkdir(exist_ok=True)
        for m in ("main", "sdk", "subsdk0"):
            (k / f"{m}.patched.bin").write_bytes(b"old-" + m.encode()); (k / f"{m}.fixups.tsv").write_bytes(b"old")
        return k

    def fake_sgrade(self, mods=("main", "sdk", "subsdk0")):
        """假的「带社区补丁改写」：产物目录里每个模块 sg-<模块>、补丁表与一份金手指原文"""
        def run(c, game, base, exefs, target, work):
            if game["id"] in getattr(self, "sg_fail", ()):
                raise Failure("fixture rewriter crashed on this game")
            root = Path(work) / "root"; root.mkdir()
            for m in mods:
                (root / f"{m}.patched.bin").write_bytes(b"sg-" + m.encode()); (root / f"{m}.fixups.tsv").write_bytes(b"sgfx")
            (root / "cpatch.tsv").write_text("编号\nwsauto:x:w\n"); (root / "cheat-src.a.txt").write_text("[x]\n")
            self.sg_calls.append((game["id"], target))
            return root, list(mods), [root / "cpatch.tsv", root / "cheat-src.a.txt"]
        return run

    def run_refresh(self, games, hits, fail=(), sgrade=None, key="x18_spdyn", big=False):
        """sgrade = None：这些款出包时取消了 S 级优化（只按改写器核，原有用例的口径）；给记号串 = 要补 S 级优化、这次的补丁记号"""
        binary = fake_rewriter(self.tmp, hits, key)
        real = rr.rewrite_modules   # 真的那份：桩里只在「这款要失败」时拦，其余照真函数跑假改写器
        cur = {}
        def exefs_of(c, game, work):
            cur["g"] = game["id"]; return self.exefs
        def rewrite(binary_, env, exefs, out, widen, **kw):
            if cur.get("g") in fail:
                raise Failure("fixture rewriter crashed")
            return real(binary_, env, exefs, out, widen, **kw)
        kits = {g: self.kit(g) for g in games}
        for k in kits.values():
            (k / "addr_need.tsv").write_text(f"版本\t2\n程序号\t0100a\n构建号\t{'0' * 32}\n别名区GB\t{57 if big else 0}\n")
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)), patch.object(rr, "original_exefs", side_effect=exefs_of), \
             patch.object(rr.layout, "ios_kit", side_effect=lambda c, g: kits[g]), \
             patch.object(rr.layout, "nro_kept", return_value=self.tmp / "no-kept"), \
             patch.object(rr.layout, "game_info", side_effect=lambda c, g: self.info.get(g, {})), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info.setdefault(g, {}).update(f)), \
             patch.object(rr, "rewrite_modules", side_effect=rewrite), \
             patch.object(rr, "sgrade_off", return_value=sgrade is None), \
             patch.object(rr, "sgrade_key", return_value=sgrade or "-"), patch.object(rr, "sgrade_rewrite", side_effect=self.fake_sgrade()), \
             patch.object(rr, "_refresh_bf_ios", return_value=[]):   # 补 _bf 一段另有单测（test_sgrade_bf.py）
            return rr.refresh_ios(self.c, games), kits

    def test_affected_module_replaced_others_untouched_and_id_recorded(self):
        self.info["0100A"] = {"ios": {"shellId": "s1", "pack": "p1"}}
        updated, kits = self.run_refresh(["0100A"], hits=["main"])
        self.assertEqual(updated, ["0100A"])
        k = kits["0100A"]
        self.assertEqual((k / "main.patched.bin").read_bytes(), b"new-main", "命中的模块换成新产物")
        self.assertEqual((k / "main.fixups.tsv").read_bytes(), b"fx")
        self.assertEqual((k / "sdk.patched.bin").read_bytes(), b"old-sdk", "没命中的模块一个字节不动")
        self.assertEqual(self.info["0100A"]["ios"], {"shellId": "s1", "pack": "p1", "rewriterId": "rid-new", "mainBid": ""}, "记下改写器指纹，原有字段保留")

    def test_pacga_module_counts_as_affected(self):
        # 11-17：改写器把 pacga 换成确定性实现；只带 pacga 的模块（统计行 pacga > 0、x18_spdyn 没有）也要换新产物
        updated, kits = self.run_refresh(["0100A"], hits=["sdk"], key="pacga")
        self.assertEqual(updated, ["0100A"])
        self.assertEqual((kits["0100A"] / "sdk.patched.bin").read_bytes(), b"new-sdk")
        self.assertEqual((kits["0100A"] / "main.patched.bin").read_bytes(), b"old-main")

    def test_sainit_counts_only_with_static_big_claim(self):
        # 11-20 分配器初始化闸：几乎每款 sdk 都挂得上（统计 sdk_sainit > 0），只有地址表认出开局大区（别名区GB ≠ 0）的款算受影响：
        #   换 sdk 产物并换上重出的地址表；没有大区的款 sdk 一个字节不动、地址表不动
        with patch.object(rr, "addr_table", return_value="新表\n") as at:
            updated, kits = self.run_refresh(["0100A"], hits=["sdk"], key="sdk_sainit", big=True)
        self.assertEqual(updated, ["0100A"]); k = kits["0100A"]
        self.assertEqual(((k / "sdk.patched.bin").read_bytes(), (k / "main.patched.bin").read_bytes()), (b"new-sdk", b"old-main"))
        self.assertEqual((k / "addr_need.tsv").read_text(), "新表\n"); self.assertEqual(at.call_count, 1)
        self.info.clear()
        with patch.object(rr, "addr_table", side_effect=AssertionError("没有大区不重出地址表")):
            updated, kits = self.run_refresh(["0100A"], hits=["sdk"], key="sdk_sainit", big=False)
        self.assertEqual(updated, []); self.assertEqual((kits["0100A"] / "sdk.patched.bin").read_bytes(), b"old-sdk")

    def test_static_big_and_addr_table(self):
        # 地址表：别名区GB 非 0（含负值 = 上限不定）算有大区；重出时身份取旧表，与旧表相同 / 读不了 main → None（沿用旧表）
        d = self.tmp / "t"; d.mkdir()
        for v, want in (("57", True), ("-57", True), ("0", False)):
            (d / "addr_need.tsv").write_text(f"程序号\t0100a\n构建号\tb\n别名区GB\t{v}\n"); self.assertEqual(rr.static_big(d), want, v)
        self.assertFalse(rr.static_big(self.tmp / "none"))
        eng = self.tmp / "eng"; (eng / "tools").mkdir(parents=True)
        (eng / "tools/addr_need.py").write_text("def collect(p, b, main=None):\n    import pathlib\n    if pathlib.Path(main).read_bytes() == b'bad': raise ValueError('坏')\n"
                                               "    return '程序号\\t%s\\n构建号\\t%s\\n别名区GB\\t57\\n大区来源\\t分配器初始化\\n' % (p, b)\n")
        c = types.SimpleNamespace(engine=eng, emit=lambda *a, **k: None)
        (d / "addr_need.tsv").write_text("程序号\t0100a\n构建号\tb\n别名区GB\t57\n")
        self.assertEqual(rr.addr_table(c, d, self.exefs), "程序号\t0100a\n构建号\tb\n别名区GB\t57\n大区来源\t分配器初始化\n")
        (d / "addr_need.tsv").write_text(rr.addr_table(c, d, self.exefs)); self.assertIsNone(rr.addr_table(c, d, self.exefs), "与旧表相同")
        (self.exefs / "main").write_bytes(b"bad"); self.assertIsNone(rr.addr_table(c, d, self.exefs), "读不了 main")
        rr.write_table(d / "addr_need.tsv", "甲\n"); self.assertEqual(((d / "addr_need.tsv").read_bytes(), sorted(p.name for p in d.iterdir())), ("甲\n".encode(), ["addr_need.tsv"]))

    def test_sgrade_rewrite_needs_no_symlink_privilege(self):
        # #1153：Windows 没开开发者模式建目录软链 WinError 1314，每款都「补丁打入失败」；改写根里的 exefs 要是真目录、内容同原件
        import patches
        def refuse(*a, **k):
            raise OSError(1314, "客户端没有所需的特权。")
        class Stop(Exception):
            pass
        work = self.tmp / "work"; work.mkdir()
        kit = self.tmp / "kitx"; kit.mkdir()
        with patch.object(os, "symlink", side_effect=refuse), patch.object(Path, "symlink_to", side_effect=refuse), \
             patch.object(patches, "fetch", side_effect=Stop):
            with self.assertRaises(Stop):
                rr.sgrade_rewrite(self.c, {"id": "0100a"}, kit, self.exefs, "ios", work)
        got = work / "root" / "exefs"
        self.assertTrue(got.is_dir() and not got.is_symlink())
        self.assertEqual(sorted(p.name for p in got.iterdir()), sorted(p.name for p in self.exefs.iterdir()))
    def test_each_checked_game_gets_its_own_line(self):
        # #1132：升级后第一次导出每款都在「核对」里重核、整体进度停 0%——逐款报一行「核对程序 i/N：名字」
        self.c.catalog = lambda: {"games": [{"id": "0100A", "name": "甲游戏"}, {"id": "0100B"}]}
        self.run_refresh(["0100A", "0100B"], hits=[])
        self.assertEqual([e for e in self.events if e.startswith("核对程序")], ["核对程序 1/2：甲游戏", "核对程序 2/2：0100B"])

    def test_unaffected_game_keeps_kit_but_is_marked_checked(self):
        updated, kits = self.run_refresh(["0100A"], hits=[])
        self.assertEqual(updated, [])
        self.assertEqual((kits["0100A"] / "main.patched.bin").read_bytes(), b"old-main")
        self.assertEqual(self.info["0100A"]["ios"]["rewriterId"], "rid-new")

    def test_same_rewriter_is_skipped_without_running_it(self):
        self.info["0100A"] = {"ios": {"rewriterId": "rid-new"}}
        with patch.object(rr, "check_and_update", side_effect=AssertionError("不该核")):
            updated, _ = self.run_refresh(["0100A"], hits=["main"])
        self.assertEqual(updated, [])

    def test_one_game_failing_does_not_block_the_rest(self):
        updated, kits = self.run_refresh(["0100A", "0100B"], hits=["main"], fail=("0100A",))
        self.assertNotIn("0100A", updated)
        self.assertEqual((kits["0100A"] / "main.patched.bin").read_bytes(), b"old-main", "核不了的款保留原产物")
        self.assertNotIn("rewriterId", self.info.get("0100A", {}).get("ios", {}), "核不了不记指纹：下次再核")
        self.assertTrue(any("【黄】0100A" in e for e in self.events), "出包时取消过 S 级优化（sgrade=None）：不涉及补丁，照旧黄字")
        self.assertNotIn("sgradeResult", self.info.get("0100A", {}))

    def test_rewriter_error_on_sgrade_game_is_reported_as_patch_failure(self):
        # 11-14 维护者：改写器在这款上出错 = 「不匹配，补丁打入失败」——红字点名、记进结果（升级 / 装机结果页列），这款保留原来的程序
        self.sg_fail = ("0100A",)
        updated, kits = self.run_refresh(["0100A", "0100B"], hits=["main"], sgrade="rid-new:plan:k1")
        self.assertNotIn("0100A", updated)
        self.assertTrue(any(e.startswith("【红】0100A：S 级优化补丁打入失败") for e in self.events))
        self.assertIn("error", self.info["0100A"]["sgradeResult"]["ios"])
        self.assertEqual(self.info["0100A"]["sgradeResult"]["ios"]["applied"], [])


    def test_mac_runtime_updates_files_and_manifest(self):
        import json
        rt = self.tmp / "mac"; (rt / "exefs").mkdir(parents=True)
        for m in ("main", "sdk"):
            (rt / "exefs" / m).write_bytes(b"x"); (rt / f"{m}.patched.bin").write_bytes(b"old-" + m.encode() + b"-longer")
        files = {f"{m}.patched.bin": [len(b"old-" + m.encode() + b"-longer"), ""] for m in ("main", "sdk")}
        (rt / "manifest.json").write_text(json.dumps({"schema": 1, "files": files, "gameId": "0100A"}))
        binary = fake_rewriter(self.tmp, ["main"])
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)), patch.object(rr, "sgrade_off", return_value=True):
            self.assertTrue(rr.refresh_mac(self.c, "0100A", rt))
            m = json.loads((rt / "manifest.json").read_text())
            self.assertEqual((rt / "main.patched.bin").read_bytes(), b"new-main")
            self.assertEqual(m["files"]["main.patched.bin"], [len(b"new-main"), ""], "清单大小跟着换：起局前按清单核文件")
            self.assertEqual(m["files"]["main.fixups.tsv"], [2, ""])
            self.assertEqual(m["files"]["sdk.patched.bin"], files["sdk.patched.bin"], "没命中的模块清单不动")
            self.assertEqual(m["rewriterId"], "rid-new")
            with patch.object(rr, "rewrite_modules", side_effect=AssertionError("同一改写器不该再核")):
                self.assertFalse(rr.refresh_mac(self.c, "0100A", rt))

    def test_mac_sainit_swaps_table_and_records_it(self):
        import json
        rt = self.tmp / "mac"; (rt / "exefs").mkdir(parents=True)
        for m in ("main", "sdk"):
            (rt / "exefs" / m).write_bytes(b"x"); (rt / f"{m}.patched.bin").write_bytes(b"old-" + m.encode())
        (rt / "addr_need.tsv").write_text("别名区GB\t57\n")
        (rt / "manifest.json").write_text(json.dumps({"schema": 1, "files": {"addr_need.tsv": [14, ""]}, "gameId": "0100A"}))
        binary = fake_rewriter(self.tmp, ["sdk"], key="sdk_sainit")
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)), patch.object(rr, "sgrade_off", return_value=True), \
             patch.object(rr, "addr_table", return_value="别名区GB\t57\n大区来源\t分配器初始化\n"):
            self.assertTrue(rr.refresh_mac(self.c, "0100A", rt))
        m = json.loads((rt / "manifest.json").read_text())
        self.assertEqual((rt / "sdk.patched.bin").read_bytes(), b"new-sdk")
        self.assertEqual(m["files"]["addr_need.tsv"], [(rt / "addr_need.tsv").stat().st_size, ""], "清单跟着记新表大小")
        self.assertIn("大区来源", (rt / "addr_need.tsv").read_text())

    def test_mac_hold_busy_leaves_runtime_untouched(self):
        # 诊断 D-R8NG：后台补 S 级在锁外改写，换进前 hold() 拿不到锁（玩家点了开始）→ 放弃这款：返回 False，运行版本文件与清单原样
        import contextlib, json
        rt = self.tmp / "mac-hold"; (rt / "exefs").mkdir(parents=True)
        for m in ("main", "sdk"):
            (rt / "exefs" / m).write_bytes(b"x"); (rt / f"{m}.patched.bin").write_bytes(b"old")
        man = json.dumps({"schema": 1, "files": {"main.patched.bin": [3, ""], "sdk.patched.bin": [3, ""]}, "gameId": "0100A"})
        (rt / "manifest.json").write_text(man)
        binary = fake_rewriter(self.tmp, ["main"])
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)), patch.object(rr, "sgrade_off", return_value=True):
            self.assertFalse(rr.refresh_mac(self.c, "0100A", rt, hold=lambda: contextlib.nullcontext(False)))
            self.assertEqual(((rt / "main.patched.bin").read_bytes(), (rt / "manifest.json").read_text()), (b"old", man))
            self.assertTrue(rr.refresh_mac(self.c, "0100A", rt, hold=lambda: contextlib.nullcontext(True)), "拿得到锁：照常换进")
            self.assertEqual((rt / "main.patched.bin").read_bytes(), b"new-main")
            self.assertEqual(json.loads((rt / "manifest.json").read_text())["rewriterId"], "rid-new")

    # S 级优化补到老游戏（v0.4.0）：补丁记号变了 → 全部模块换成带补丁的产物、补丁表与金手指原文进 kit（旧原文删掉）、记下记号；记号没变不再做
    def test_sgrade_upgrade_replaces_all_modules_and_tables(self):
        self.info["0100A"] = {"ios": {"rewriterId": "rid-new", "sgradeKey": "k-old"}}
        k = self.kit("0100A"); (k / "cheat-src.old.txt").write_text("旧")
        updated, kits = self.run_refresh(["0100A"], hits=[], sgrade="k-new")
        self.assertEqual(updated, ["0100A"]); self.assertEqual(self.sg_calls, [("0100A", "ios")])
        k = kits["0100A"]
        self.assertEqual([(k / f"{m}.patched.bin").read_bytes() for m in ("main", "sdk", "subsdk0")], [b"sg-main", b"sg-sdk", b"sg-subsdk0"], "全部模块换成带补丁的产物")
        self.assertEqual((k / "cpatch.tsv").read_text(), "编号\nwsauto:x:w\n")
        self.assertEqual(sorted(p.name for p in k.glob("cheat-src.*")), ["cheat-src.a.txt"], "旧金手指原文删掉、新的拷进来")
        self.assertEqual(self.info["0100A"]["ios"]["sgradeKey"], "k-new")
        with patch.object(rr, "check_and_update", side_effect=AssertionError("记号没变不该再核")):
            self.assertEqual(self.run_refresh(["0100A"], hits=[], sgrade="k-new")[0], [])

    def test_sgrade_off_game_is_not_patched(self):
        # 出包页取消过「出包时打入」：只按改写器核，改写器没变就整款跳过，不碰补丁
        self.info["0100A"] = {"ios": {"rewriterId": "rid-new"}}
        updated, kits = self.run_refresh(["0100A"], hits=[])
        self.assertEqual((updated, self.sg_calls), ([], []))
        self.assertFalse((kits["0100A"] / "cpatch.tsv").exists())

    def test_mac_sgrade_upgrade_updates_manifest(self):
        import json
        rt = self.tmp / "mac2"; (rt / "exefs").mkdir(parents=True)
        for m in ("main", "sdk"):
            (rt / "exefs" / m).write_bytes(b"x"); (rt / f"{m}.patched.bin").write_bytes(b"old")
        (rt / "cheat-src.old.txt").write_text("旧")
        files = {"main.patched.bin": [3, ""], "sdk.patched.bin": [3, ""], "cheat-src.old.txt": [3, ""]}
        (rt / "manifest.json").write_text(json.dumps({"schema": 1, "files": files, "gameId": "0100A", "rewriterId": "rid-new"}))
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "sgrade_off", return_value=False), \
             patch.object(rr, "sgrade_key", return_value="k1"), patch.object(rr, "sgrade_rewrite", side_effect=self.fake_sgrade(("main", "sdk"))), \
             patch.object(rr.layout, "game_info", side_effect=lambda c, g: self.info.get(g, {})), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info.setdefault(g, {}).update(f)):
            self.assertTrue(rr.refresh_mac(self.c, "0100A", rt))
            self.assertIn("mac", self.info["0100A"]["sgradeResult"], "补完记下这一端的打入结果")
            m = json.loads((rt / "manifest.json").read_text())
            self.assertEqual((rt / "main.patched.bin").read_bytes(), b"sg-main")
            self.assertEqual(m["files"]["sdk.patched.bin"], [len(b"sg-sdk"), ""])
            self.assertEqual(m["files"]["cpatch.tsv"], [len("编号\nwsauto:x:w\n".encode()), ""], "补丁表记进清单：起局前按清单核")
            self.assertNotIn("cheat-src.old.txt", m["files"]); self.assertFalse((rt / "cheat-src.old.txt").exists())
            self.assertEqual(m["sgradeKey"], "k1")
            self.assertFalse(rr.refresh_mac(self.c, "0100A", rt), "记号没变不再做")

    # 原件不在：出过 Mac 版的款用 Mac 运行版本自带的 exefs/（老游戏补 S 级优化不必回原件）
    def test_original_exefs_falls_back_to_mac_runtime(self):
        import build
        mac = self.tmp / "img-mac"; (mac / "exefs").mkdir(parents=True)
        (mac / "exefs/main").write_bytes(b"x"); (mac / "exefs/main.npdm").write_bytes(b"x")
        import sgrade
        with patch.object(sgrade, "saved_program", return_value=None), patch.object(build, "extract_valid", return_value=False), \
             patch.object(rr.layout, "image_mac", return_value=mac):
            self.assertEqual(rr.original_exefs(self.c, {"id": "0100A"}, self.tmp), mac / "exefs")

    # 补不上的款不悄悄跳过：点名、说怎么补
    def test_unavailable_games_are_named(self):
        self.c.catalog = lambda: {"games": [{"id": "0100A", "name": "甲游戏"}, {"id": "0100B", "name": "乙游戏"}]}
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "sgrade_off", return_value=False), \
             patch.object(rr, "sgrade_key", return_value="k"), patch.object(rr.layout, "game_info", return_value={}), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info.setdefault(g, {}).update(f)), \
             patch.object(rr.layout, "ios_kit", return_value=self.tmp), patch.object(rr.layout, "nro_kept", return_value=self.tmp / "no-kept"), \
             patch.object(rr, "check_and_update", side_effect=lambda c, g, *a: "unavailable" if g == "0100A" else "updated"), \
             patch.object(rr, "_refresh_bf_ios", return_value=[]):
            self.assertEqual(rr.refresh_ios(self.c, ["0100A", "0100B"]), ["0100B"])
        self.assertTrue(any("甲游戏" in e and "没补上 S 级优化" in e and "乙游戏" not in e for e in self.events), self.events)
        self.assertEqual(self.info["0100A"]["ios"]["sgradeMissing"], "k", "缺原件补不上：记下这一版记号，「更新 iPhone」不再因它重装（install.sgrade_pending）")

if __name__ == "__main__":
    unittest.main()


def synthetic_nro(tag):
    """合成 NRO（同 tests/nro_to_nso_test.sh 夹具，按 switchbrew NRO 手写）：text / ro / data 各 0x1000、bss 0x1000，构建号末字节 = tag"""
    import struct
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0, 0x1000)
    text[0x10:0x14] = b'NRO0'; struct.pack_into('<III', text, 0x14, 0, 0x3000, 0)
    struct.pack_into('<6I', text, 0x20, 0, 0x1000, 0x1000, 0x1000, 0x2000, 0x1000)
    struct.pack_into('<I', text, 0x38, 0x1000); text[0x48] = tag
    ro = bytearray(0x1000); struct.pack_into('<4s', ro, 0, b'MOD0')
    return bytes(text) + bytes(ro) + bytes(0x1000)


class KeptNroRefreshTests(unittest.TestCase):
    """运行时留下的 NRO 自动补进程序（#8be819，rewrite_refresh.add_kept_nros / kept_nros_mac / refresh_ios）。
    期望按约定手写：只补还没进 nro_modules.tsv 的；新模块接着原有编号（已有 nro0 → nro1）、来源 kept:<文件名>；产物 = 改写器输出；已有模块与表里原有行不动；
    补过一次再核 = 不再动；Mac 运行版本清单记上新文件大小；refresh_ios 把补上的款算进「更新了」"""
    def setUp(self):
        import hashlib
        self.tmp = Path(tempfile.mkdtemp())
        self.events = []
        self.c = jobcase.fake_context(self.tmp, private=self.tmp, engine=Path(__file__).resolve().parents[3], env=lambda: dict(os.environ), library=self.tmp / "library", work_root=self.tmp / "work",
                                       emit=lambda kind, text, **_: self.events.append(text), catalog=lambda: {"games": [{"id": "0100A"}]})
        self.kept = self.tmp / "kept"; self.kept.mkdir()
        self.nro = synthetic_nro(7); self.sha = hashlib.sha256(self.nro).hexdigest()
        (self.kept / f"{self.sha}.nro").write_bytes(self.nro)
        self.base = self.tmp / "base"; self.base.mkdir()
        (self.base / "nro_modules.tsv").write_text("# 表头\nnro0\t" + "b" * 64 + "\t0x3000\t0x1000\tnro/a.nro\n")
        (self.base / "nro0.patched.bin").write_bytes(b"old-nro0")
        self.rew = fake_rewriter(self.tmp, [])

    def run_add(self, fn, *a):
        with patch.object(rr.layout, "nro_kept", return_value=self.kept), patch.object(rr, "rewriter_bin", return_value=self.rew), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)):
            return fn(self.c, "0100A", *a)

    def test_add_once(self):
        self.assertEqual(self.run_add(rr.add_kept_nros, self.base, "ios"), ["nro1"])
        rows = [l.split("\t") for l in (self.base / "nro_modules.tsv").read_text().splitlines() if not l.startswith("#")]
        self.assertEqual([(r[0], r[1], r[4]) for r in rows], [("nro0", "b" * 64, "nro/a.nro"), ("nro1", self.sha, f"kept:{self.sha}.nro")])
        self.assertEqual([r[2:4] for r in rows][1], ["0x3000", "0x1000"])
        self.assertEqual((self.base / "nro1.patched.bin").read_bytes(), b"new-nro1")
        self.assertEqual((self.base / "nro0.patched.bin").read_bytes(), b"old-nro0")
        self.assertEqual(self.run_add(rr.add_kept_nros, self.base, "ios"), [], "补过一次再核不再动")

    def test_mac_manifest(self):
        import json
        (self.base / "exefs").mkdir()
        (self.base / "manifest.json").write_text(json.dumps({"files": {"nro0.patched.bin": [8, ""]}}))
        self.assertEqual(self.run_add(rr.kept_nros_mac, self.base), ["nro1"])
        files = json.loads((self.base / "manifest.json").read_text())["files"]
        self.assertEqual(files["nro1.patched.bin"], [len(b"new-nro1"), ""])
        self.assertEqual(files["nro_modules.tsv"][0], (self.base / "nro_modules.tsv").stat().st_size)
        self.assertEqual(files["nro0.patched.bin"], [8, ""])
        self.assertTrue(any("已补上 1 个" in e for e in self.events))

    def test_refresh_ios_counts_kept(self):
        with patch.object(rr, "rewriter_id", return_value="rid"), patch.object(rr, "pending_ios", return_value=[]), \
             patch.object(rr.layout, "ios_kit", return_value=self.base), patch.object(rr, "_refresh_bf_ios", return_value=[]):
            self.assertEqual(self.run_add(lambda c, g: rr.refresh_ios(c, [g])), ["0100A"])
        self.assertTrue((self.base / "nro1.patched.bin").is_file())


class SwapKeepsOld(unittest.TestCase):
    """审计 P1-186：S 级优化 / 新版改写器把产物和补丁表换进正在用的 kit / 运行版本，要么全换上、要么一个都不动。
    合成目录夹具（不要游戏原件）：期望值手写——中途失败后旧的 main.patched.bin、旧补丁表 cpatch.tsv、旧金手指原文都在且内容不变，目录里不留 .rw / .rwold"""
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); d = Path(self.t.name)
        self.kit, self.out = d / "kit", d / "out"; self.kit.mkdir(); self.out.mkdir()
        for n, v in (("main.patched.bin", "old-main"), ("main.fixups.tsv", "old-fx"), ("cheat-src.x.txt", "old-cheat")):
            (self.kit / n).write_text(v)
        if rr.SGRADE_TABLES:
            (self.kit / rr.SGRADE_TABLES[0]).write_text("old-table")
        (self.out / "main.patched.bin").write_text("new-main"); (self.out / "main.fixups.tsv").write_text("new-fx")
        self.newtab = d / (rr.SGRADE_TABLES[0] if rr.SGRADE_TABLES else "cpatch.tsv"); self.newtab.write_text("new-table")

    def tearDown(self):
        self.t.cleanup()

    def state(self):
        return {p.name: p.read_text() for p in sorted(self.kit.iterdir())}

    def test_all_swapped_on_success(self):
        rr.apply_sgrade(self.out, self.kit, ["main"], [self.newtab])
        s = self.state()
        self.assertEqual((s["main.patched.bin"], s["main.fixups.tsv"], s[self.newtab.name]), ("new-main", "new-fx", "new-table"))
        self.assertNotIn("cheat-src.x.txt", s)   # 这次没出的金手指原文删掉（同原 put_tables）
        self.assertFalse([n for n in s if n.endswith((".rw", ".rwold"))])

    def test_failure_midway_leaves_old_set(self):
        before = self.state()
        real = os.replace; n = [0]
        def flaky(a, b):   # 第二次「临时名改正名」失败（模拟 Windows 目标被占用 WinError 32）
            if str(a).endswith(".rw"):
                n[0] += 1
                if n[0] == 2:
                    raise PermissionError(32, "目标被占用")
            return real(a, b)
        with patch.object(rr.os, "replace", side_effect=flaky), self.assertRaises(PermissionError):
            rr.apply_sgrade(self.out, self.kit, ["main"], [self.newtab])
        self.assertEqual(self.state(), before)

    def test_staging_failure_touches_nothing(self):
        before = self.state()
        real = rr.shutil.copyfile
        def boom(src, dst):
            if str(dst).endswith("main.fixups.tsv.rw"):
                raise OSError(28, "盘满")
            return real(src, dst)
        with patch.object(rr.shutil, "copyfile", side_effect=boom), self.assertRaises(OSError):
            rr.apply_sgrade(self.out, self.kit, ["main"], [self.newtab])
        self.assertEqual(self.state(), before)


class OriginalExefsFormatTests(unittest.TestCase):
    """S 级升级的原始 exefs 来源：NUP、Switch 2 dump、extract / loose；只用合成数据。"""

    TID = "0100000000000000"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = self.tmp / "saved-program"
        self.engine = Path(__file__).resolve().parents[3]
        self.game = {"id": self.TID, "name": "synthetic"}
        self.packages = []
        self.reader_args = None

        def run(args, log, env):
            self.reader_args = list(map(str, args))
            out = Path(args[2]) / "exefs"
            out.mkdir(parents=True)
            (out / "main").write_bytes(b"reader-main")
            (out / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16)))

        self.c = types.SimpleNamespace(
            private=self.tmp, library=self.tmp / "library", work_root=self.tmp / "work", engine=self.engine,
            keys=self.tmp / "prod.keys", env=lambda: dict(os.environ), run=run,
        )
        self.c.keys.write_text("synthetic")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def original(self, packages=None):
        import build, library, sgrade
        rows = self.packages if packages is None else packages
        with patch.object(sgrade, "saved_program", return_value=None), \
             patch.object(build, "extract_valid", return_value=False), \
             patch.object(rr.layout, "image_mac", return_value=self.tmp / "no-mac"), \
             patch.object(rr.layout, "path", return_value=self.saved), \
             patch.object(rr.layout, "program_exefs", return_value=self.saved), \
             patch("programs.save_exefs", side_effect=self._save_exefs), \
             patch.object(library, "selected_packages", return_value=rows):
            return rr.original_exefs(self.c, self.game, self.tmp / "work")

    def package(self, source, fmt, kind="base", version=0):
        return {"type": kind, "version": version, "format": fmt, "path": str(source),
                "titleId": self.TID if kind == "base" else f"{int(self.TID, 16) | 0x800:016X}"}

    def _save_exefs(self, c, gid, src):   # 常驻归档（pack/jobs/programs.py）另有单测；这里只核原件格式解出的 exefs 存的是哪一份
        shutil.rmtree(self.saved, ignore_errors=True); shutil.copytree(src, self.saved)
        return self.saved

    def assert_saved(self, source_main):
        result = self.original()
        self.assertEqual(result, self.saved)
        self.assertEqual((self.saved / "main").read_bytes(), source_main)
        self.assertEqual((self.saved / "main.npdm").read_bytes(), jobcase.synthetic_npdm(int(self.TID, 16)))

    def test_extract_and_loose_use_existing_exefs_layout_and_save_copy(self):
        for fmt in ("extract", "loose"):
            with self.subTest(format=fmt):
                import shutil
                shutil.rmtree(self.saved, ignore_errors=True)
                root = self.tmp / fmt
                exefs = root / "exefs"; exefs.mkdir(parents=True)
                (exefs / "main").write_bytes(fmt.encode())
                (exefs / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16)))
                self.packages = [self.package(root, fmt)]
                self.assert_saved(fmt.encode())
                self.assertEqual((exefs / "main").read_bytes(), fmt.encode(), "来源目录保持原样")

    def test_dump_uses_selected_latest_update_exefs_and_saves_copy(self):
        root = self.tmp / "dump"
        base = root / "base" / "exefs"; base.mkdir(parents=True)
        (base / "main").write_bytes(b"base-main")
        (base / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16)))
        older = root / "updates" / "2" / "exefs"; older.mkdir(parents=True)
        (older / "main").write_bytes(b"older-update")
        (older / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16)))
        newest = root / "updates" / "9" / "exefs"; newest.mkdir(parents=True)
        (newest / "main").write_bytes(b"selected-update")
        (newest / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16)))
        self.packages = [self.package(root, "dump")]
        self.assert_saved(b"selected-update")

    def test_nup_uses_base_plus_selected_update_and_saves_copy(self):
        import library
        ns2_nup = library.engine_tool(self.c, "ns2_nup")
        ns2_dump = library.engine_tool(self.c, "ns2_dump")
        from jobcase import synthetic_nup, synthetic_npdm
        source = self.tmp / "synthetic.nup"
        app = int(self.TID, 16)
        synthetic_nup(source, app, [
            (ns2_nup.BASE, app, 0,
             {"main": b"nup-base", "main.npdm": synthetic_npdm(app)}, {"base.bin": b"base-romfs"}, {}),
            (ns2_nup.UPDATE, app | 0x800, 65536,
             {"main": b"nup-old-update", "main.npdm": synthetic_npdm(app)}, {"old.bin": b"old-romfs"}, {}),
            (ns2_nup.UPDATE, app | 0x800, 131072,
             {"main": b"nup-selected-update", "main.npdm": synthetic_npdm(app)}, {"huge.bin": b"not-extracted"}, {}),
        ])
        self.packages = [self.package(source, "nup", "base"),
                         self.package(source, "nup", "update", 131072)]
        import hashlib
        with ns2_nup.Nup(str(source)) as container:
            expected_exefs = ns2_nup.scan(container)[2][131072].exefs
        before = hashlib.sha256(source.read_bytes()).digest()
        with patch.object(library, "engine_tool", side_effect=lambda _c, name: {"ns2_nup": ns2_nup, "ns2_dump": ns2_dump}[name]), \
             patch.object(ns2_nup, "write_tree", wraps=ns2_nup.write_tree) as write_tree:
            self.assert_saved(b"nup-selected-update")
        self.assertEqual(write_tree.call_args.args[1], expected_exefs, "只写所选更新包的 exefs 目录，不解 romfs")
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before, "NUP 原件保持不变")

    def test_each_extracted_format_missing_npdm_returns_none(self):
        for fmt in ("dump", "extract", "loose"):
            with self.subTest(format=fmt):
                root = self.tmp / (fmt + "-missing")
                exefs = root / ("base/exefs" if fmt == "dump" else "exefs")
                exefs.mkdir(parents=True)
                (exefs / "main").write_bytes(b"main-without-npdm")
                self.packages = [self.package(root, fmt)]
                self.assertIsNone(self.original())

    def test_nup_missing_main_returns_none(self):
        import library
        ns2_nup = library.engine_tool(self.c, "ns2_nup")
        from jobcase import synthetic_nup, synthetic_npdm
        source = self.tmp / "missing-main.nup"
        app = int(self.TID, 16)
        synthetic_nup(source, app, [(ns2_nup.BASE, app, 0,
                                     {"main.npdm": synthetic_npdm(app)}, {"r": b"r"}, {})])
        self.packages = [self.package(source, "nup")]
        self.assertIsNone(self.original())

    def test_nsp_reader_exefs_only_remains_negative_control(self):
        import toolchain
        source = self.tmp / "synthetic.nsp"; source.write_bytes(b"nsp fixture")
        self.packages = [self.package(source, "nsp")]
        with patch.object(toolchain, "reader", return_value="synthetic-reader"):
            result = self.original()
        self.assertEqual(result, self.saved)
        self.assertIn("--exefs-only", self.reader_args)
        self.assertIn(str(source), self.reader_args)

    def test_wrong_program_id_is_failure_not_crash(self):
        # 维护方修正：程序号不符等原件问题统一成 Failure（升级循环 check_and_update 外层只接 Failure / OSError / SubprocessError；
        #   原先 ValueError 穿出去整轮升级作业崩掉）。期望手写：抛 Failure、不留保存的副本
        from core import Failure
        root = self.tmp / "wrong"; exefs = root / "exefs"; exefs.mkdir(parents=True)
        (exefs / "main").write_bytes(b"x")
        (exefs / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16) ^ 0x1000))
        self.packages = [self.package(root, "extract")]
        with self.assertRaises(Failure):
            self.original()
        self.assertFalse((self.saved / "main").exists())

    def test_zbic_reader_passed_explicitly(self):
        # 维护方修正：ZBIC 压缩的 NSO 要 nx_unpack 解；S 级升级这条路显式把读取器交给 normalize_exefs（作业进程环境里没有 S2A_NX_UNPACK）
        import build, library
        ns2_dump = library.engine_tool(self.c, "ns2_dump")
        reader = self.tmp / "nx_unpack"; reader.write_bytes(b"#!")
        root = self.tmp / "zb"; exefs = root / "exefs"; exefs.mkdir(parents=True)
        (exefs / "main").write_bytes(b"m"); (exefs / "main.npdm").write_bytes(jobcase.synthetic_npdm(int(self.TID, 16)))
        self.packages = [self.package(root, "extract")]
        seen = []
        real = ns2_dump.normalize_exefs
        def spy(src, dst, tid, nxu=None):
            seen.append(nxu); return real(src, dst, tid, nxu)
        with patch.object(build, "reader_program", return_value=reader), patch.object(ns2_dump, "normalize_exefs", side_effect=spy), \
             patch.object(library, "engine_tool", side_effect=lambda _c, name: ns2_dump):
            self.original()
        self.assertEqual(seen, [str(reader)])


class NoBackgroundRewriteTests(unittest.TestCase):
    """11-17 维护者定：改写器指纹变了不再在后台重改写全部游戏（准备更新 iPhone、打开启动器补 S 级都走 ignore_rewriter），
    只在玩家对这一款出包 / 推送 / 装机 / 起局时前台做；补丁记号里改写器之后的部分（补丁库版本、金手指等）变了照旧补。
    改写器本身换成计数的替身，期望按规则手写"""
    G = "0100000000010000"

    def run_ios(self, stored, now_key, ignore):
        c = types.SimpleNamespace(emit=lambda *a, **k: None, catalog=lambda: {"games": [{"id": self.G, "name": "甲"}]})
        calls, saved = [], {"ios": dict(stored)}
        def check(cc, g, kit, target, rid, ignore_rewriter=False):
            calls.append((g, rid)); return "unaffected"
        with patch.object(rr, "rewriter_id", lambda cc: "NEWRID"), patch.object(rr, "ios_key", lambda cc, g, rid: now_key(rid)), \
                patch.object(rr, "kept_todo", lambda *a: False), patch.object(rr, "check_and_update", check), \
                patch.object(rr, "_refresh_bf_ios", lambda cc, games: []), \
                patch.object(rr.layout, "game_info", lambda cc, g: saved), patch.object(rr.layout, "ios_kit", lambda cc, g: Path("/kit")), \
                patch("core.trace", lambda *a, **k: None, create=True), patch("programs.save_recipe", lambda *a: None, create=True):
            rr.refresh_ios(c, [self.G], ignore_rewriter=ignore)
        return calls

    def test_rewriter_change_alone_skipped_in_background(self):
        # 改写器指纹从 OLDRID 换成 NEWRID、补丁记号其余部分不变：后台（ignore_rewriter）0 次改写；前台（玩家推这一款）改写 1 次
        stored = dict(rewriterId="OLDRID", sgradeKey="OLDRID:plan:v1:-")
        key = lambda rid: f"{rid}:plan:v1:-"
        self.assertEqual(self.run_ios(stored, key, True), [])
        self.assertEqual(self.run_ios(stored, key, False), [(self.G, "NEWRID")])

    def test_patch_library_change_still_refreshed_in_background(self):
        # 补丁库版本 v1 → v2（记号里改写器之后的部分变了）：后台照旧补（11-14 维护者：补丁库更新 / 导入金手指要补进程序）
        stored = dict(rewriterId="OLDRID", sgradeKey="OLDRID:plan:v1:-")
        self.assertEqual(self.run_ios(stored, lambda rid: f"{rid}:plan:v2:-", True), [(self.G, "NEWRID")])

    def test_sgrade_off_game_never_rewritten_in_background(self):
        # 出包时取消过 S 级优化（记号 None，只看改写器指纹）：后台 0 次；前台照旧按新改写器做
        stored = dict(rewriterId="OLDRID")
        self.assertEqual(self.run_ios(stored, lambda rid: None, True), [])
        self.assertEqual(self.run_ios(stored, lambda rid: None, False), [(self.G, "NEWRID")])

    def test_mac_background_skips_rewriter_change_alone(self):
        # Mac 运行版本（打开启动器后台补 S 级用 ignore_rewriter）：改写器指纹单独变了直接返回，不跑改写器；前台起局（不带）要跑
        with tempfile.TemporaryDirectory() as t:
            rt = Path(t)
            (rt / "exefs").mkdir()
            (rt / "exefs/main").write_bytes(bytes(0x48))
            import json as _json
            (rt / "manifest.json").write_text(_json.dumps({"files": {}, "rewriterId": "OLDRID"}))
            c = types.SimpleNamespace(emit=lambda *a, **k: None, catalog=lambda: {"games": []}, private=t)
            ran = []
            def boom(*a, **k):
                ran.append(1); raise Failure("前台才该跑到这里")
            with patch.object(rr, "rewriter_id", lambda cc: "NEWRID"), patch.object(rr, "sgrade_off", lambda cc, g: True), \
                    patch.object(rr, "rewriter_bin", boom):
                self.assertFalse(rr.refresh_mac(c, self.G, rt, ignore_rewriter=True))
                self.assertEqual(ran, [])
                self.assertFalse(rr.refresh_mac(c, self.G, rt))   # 前台：要按新改写器做（替身抛错 → 核不了不挡起局，返回 False）
                self.assertEqual(ran, [1])


class FpslKey(unittest.TestCase):
    """D-7AQ2：FPSLocker 转换代码修了，已出过包的款要走 S 级补进重出表。补丁记号（sgrade_key）只在这款带 FPSLocker 配置时多一段 :fpsl<转换代码指纹>：
    期望手写——带配置：记号以 :fpsl<指纹> 结尾、转换代码一变记号就变；不带：记号与没加这段时一字不差（不让别的款白白重补）；补丁库取不到：当没带"""
    def key(self, items, fp="aaaaaaaaaaaa"):
        c = types.SimpleNamespace(engine=Path(__file__).resolve().parents[3])
        import patches
        with patch.object(patches, "version_key", return_value="vk"), patch.object(rr, "plan_code_id", return_value="pc"), \
             patch.object(rr, "cheats_digest", return_value="-"), patch("mods.code_digest", return_value="-"), \
             patch.object(rr, "fpsl_code_id", return_value=fp), patch.object(patches, "items_for", side_effect=items if callable(items) else (lambda *a: items)):
            return rr.sgrade_key(c, "0100AD80208A8000", "rid", "68E3A0EA176A79F4")

    def test_key(self):
        # 替身与真函数同形：patches.items_for 返回 [(条目字典, 内容字节)]（11-17 原先替身给字典，真函数给元组，单测绿、真游戏上 AttributeError）
        base = "rid:pc:vk:-"
        self.assertEqual(self.key([({"kind": "fpsl", "name": "68E3A0EA176A79F4.yaml"}, b"MASTER_WRITE:")]), base + ":fpslaaaaaaaaaaaa")
        self.assertNotEqual(self.key([({"kind": "fpsl"}, b"")], fp="bbbbbbbbbbbb"), self.key([({"kind": "fpsl"}, b"")]), "转换代码变了记号跟着变")
        self.assertEqual(self.key([({"kind": "pchtxt", "name": "x.pchtxt"}, b"")]), base, "不带 FPSLocker 配置：记号不变")
        def gone(*a):
            raise OSError("补丁库取不到")
        self.assertEqual(self.key(gone), base, "补丁库取不到：当没带")

    def test_code_id_tracks_converter_files(self):
        c = types.SimpleNamespace(engine=Path(__file__).resolve().parents[3])
        a = rr.fpsl_code_id(c)
        self.assertRegex(a, r"^[0-9a-f]{12}$")


class FpslKeyRealLibrary(unittest.TestCase):
    """补丁记号拿真补丁库条目算（11-17 维护者：替身与真函数不同形，单测绿、真游戏上 AttributeError）：造一份与随启动器装的快照同格式的补丁库
    （tools/patch_pack.py snapshot：index.json + 各款 g/<程序号>.json.gz），不替换 patches.items_for，走真函数读条目。期望手写——
    带 FPSLocker 配置（kind fpsl、*.yaml）的款记号以 :fpsl<转换代码指纹> 结尾；只有别的补丁的款没有这段；补丁库里没有的款没有这段；都不抛异常"""
    def test_key_from_real_items_for(self):
        import base64, gzip, hashlib, io, json, tarfile, tempfile
        import patches
        def item(name, kind, data):
            return dict(name=name, kind=kind, cat="fps", data=base64.b64encode(data).decode(), sha256=hashlib.sha256(data).hexdigest())
        bundles = {"g/0100AAAA00000000": [item("68E3A0EA176A79F4.yaml", "fpsl", b"MASTER_WRITE:\n")],
                   "g/0100BBBB00000000": [item("60fps.pchtxt", "pchtxt", b"@nsobid-0000\n")]}
        with tempfile.TemporaryDirectory() as t:
            snap = Path(t) / "patches-v2.tar"; man, blobs = {}, {}
            for k, items in bundles.items():
                blob = gzip.compress(json.dumps(dict(schema=2, key=k, items=items)).encode()); blobs[k] = blob
                man[k] = dict(sha256=hashlib.sha256(blob).hexdigest(), size=len(blob), items=len(items))
            with tarfile.open(snap, "w") as tf:
                for n, data in [("index.json", json.dumps(dict(schema=2, generated=1, upstreams={}, bundles=man)).encode())] + [(k + ".json.gz", b) for k, b in blobs.items()]:
                    ti = tarfile.TarInfo(n); ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
            c = types.SimpleNamespace(engine=Path(__file__).resolve().parents[3], private=Path(t) / "private", r={})
            env = dict(os.environ, S2A_PATCH_SNAPSHOT=str(snap))
            with patch.dict(os.environ, env), patch.object(patches, "cloud_manifest", return_value=None), patch.dict(patches._MANIFEST, clear=True), \
                 patch.object(rr, "cheats_digest", return_value="-"), patch("mods.code_digest", return_value="-"):
                self.assertEqual(len(patches.items_for(c, "0100AAAA00000000", "")), 1, "夹具自证：真 items_for 读得到快照里的条目")
                fp = rr.fpsl_code_id(c)
                a = rr.sgrade_key(c, "0100AAAA00000000", "rid", "")
                b = rr.sgrade_key(c, "0100BBBB00000000", "rid", "")
                n = rr.sgrade_key(c, "0100CCCC00000000", "rid", "")
        self.assertTrue(a.endswith(":fpsl" + fp), a)
        self.assertNotIn(":fpsl", b); self.assertNotIn(":fpsl", n)


class OwnFrameTableTest(unittest.TestCase):
    """11-18 #1607：旧包产物根里带改指令（c 行）的我方帧率表只在内部对照口径 S2A_CAPS_OWN=1 交改写器。期望手写——
    缺省：rewrite_env 不设 S2A_FPS_TSV（不打改指令，60 帧关着游戏不再被解锁）；S2A_CAPS_OWN=1：设成 kit/fps.tsv；
    own_table 只认带 c 行的 fps.tsv（只有 w 行的通用表、别的文件名都不算）"""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "fps.tsv").write_text("build 277178b7dba1b6d4\nc main 0x100 word 6b08015f 7100055f   # x\n", encoding="utf-8")

    def env_of(self, extra):
        c = types.SimpleNamespace(env=lambda: dict(extra), engine=str(self.tmp))
        return rr.rewrite_env(c, self.tmp, None, "ios")

    def test_default_does_not_bake_own_table(self):
        self.assertNotIn("S2A_FPS_TSV", self.env_of({}))
        self.assertNotIn("S2A_FPS_TSV", self.env_of({"S2A_FPS_TSV": "/leftover"}))

    def test_internal_comparison_still_bakes(self):
        self.assertEqual(self.env_of({"S2A_CAPS_OWN": "1"})["S2A_FPS_TSV"], str(self.tmp / "fps.tsv"))

    def test_own_table_detection(self):
        self.assertTrue(rr.own_table(self.tmp / "fps.tsv"))
        w = self.tmp / "w" / "fps.tsv"; w.parent.mkdir(); w.write_text("present display\nw main 0x1000 f32 60\n# c main 不算\n", encoding="utf-8")
        self.assertFalse(rr.own_table(w))
        o = self.tmp / "widen_sites.tsv"; o.write_text("c main 0x100\n", encoding="utf-8")
        self.assertFalse(rr.own_table(o))
