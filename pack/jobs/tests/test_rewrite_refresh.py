# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""只重跑改写阶段（pack/jobs/rewrite_refresh.py）的接线：改写器换成按模块打统计行的假程序，游戏库换成内存里的 game.json。
真改写器上的读数（11-11）：路易吉洋馆 3 命中 main、换进的产物等于改写器直接输出；两款反例 kit 一个字节不动；改写器崩的款抛错、kit 不动。"""
import os
import stat
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401  把 pack/jobs 加进路径（同其他作业层单测）
import rewrite_refresh as rr
from core import Failure


def fake_rewriter(d, hits):
    """假改写器：<NSO> <输出目录> <模块> [宽屏表] → 写 <模块>.patched.bin（内容 = 模块名 + new），统计行里 x18_spdyn 按 hits 给"""
    p = Path(d) / "fake-rewrite"
    p.write_text("#!/bin/sh\nprintf 'new-%s' \"$3\" > \"$2/$3.patched.bin\"\nprintf 'fx' > \"$2/$3.fixups.tsv\"\n"
                 "case \" " + " ".join(hits) + " \" in *\" $3 \"*) n=38;; *) n=0;; esac\n"
                 "echo \"$3 {'plain': 1, 'x18_spdyn': $n}\"\n")
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
        self.c = types.SimpleNamespace(private=self.tmp, emit=lambda kind, text, **_: self.events.append(text),
                                       catalog=lambda: {"games": [{"id": g} for g in ("0100A", "0100B")]})

    def kit(self, gid):
        k = self.tmp / ("kit-" + gid); k.mkdir(exist_ok=True)
        for m in ("main", "sdk", "subsdk0"):
            (k / f"{m}.patched.bin").write_bytes(b"old-" + m.encode()); (k / f"{m}.fixups.tsv").write_bytes(b"old")
        return k

    def fake_sgrade(self, mods=("main", "sdk", "subsdk0")):
        """假的「带社区补丁改写」：产物目录里每个模块 sg-<模块>、补丁表与一份金手指原文"""
        def run(c, game, base, exefs, target, work):
            root = Path(work) / "root"; root.mkdir()
            for m in mods:
                (root / f"{m}.patched.bin").write_bytes(b"sg-" + m.encode()); (root / f"{m}.fixups.tsv").write_bytes(b"sgfx")
            (root / "cpatch.tsv").write_text("编号\nwsauto:x:w\n"); (root / "cheat-src.a.txt").write_text("[x]\n")
            self.sg_calls.append((game["id"], target))
            return root, list(mods), [root / "cpatch.tsv", root / "cheat-src.a.txt"]
        return run

    def run_refresh(self, games, hits, fail=(), sgrade=None):
        """sgrade = None：这些款出包时取消了 S 级优化（只按改写器核，原有用例的口径）；给记号串 = 要补 S 级优化、这次的补丁记号"""
        binary = fake_rewriter(self.tmp, hits)
        real = rr.rewrite_modules   # 真的那份：桩里只在「这款要失败」时拦，其余照真函数跑假改写器
        cur = {}
        def exefs_of(c, game, work):
            cur["g"] = game["id"]; return self.exefs
        def rewrite(binary_, env, exefs, out, widen):
            if cur.get("g") in fail:
                raise Failure("fixture rewriter crashed")
            return real(binary_, env, exefs, out, widen)
        kits = {g: self.kit(g) for g in games}
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)), patch.object(rr, "original_exefs", side_effect=exefs_of), \
             patch.object(rr.layout, "ios_kit", side_effect=lambda c, g: kits[g]), \
             patch.object(rr.layout, "game_info", side_effect=lambda c, g: self.info.get(g, {})), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info.setdefault(g, {}).update(f)), \
             patch.object(rr, "rewrite_modules", side_effect=rewrite), \
             patch.object(rr, "sgrade_off", return_value=sgrade is None), \
             patch.object(rr, "sgrade_key", return_value=sgrade or "-"), patch.object(rr, "sgrade_rewrite", side_effect=self.fake_sgrade()):
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
        self.assertTrue(any("【黄】0100A" in e for e in self.events))


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
             patch.object(rr, "sgrade_key", return_value="k1"), patch.object(rr, "sgrade_rewrite", side_effect=self.fake_sgrade(("main", "sdk"))):
            self.assertTrue(rr.refresh_mac(self.c, "0100A", rt))
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
             patch.object(rr.layout, "ios_kit", return_value=self.tmp), \
             patch.object(rr, "check_and_update", side_effect=lambda c, g, *a: "unavailable" if g == "0100A" else "updated"):
            self.assertEqual(rr.refresh_ios(self.c, ["0100A", "0100B"]), ["0100B"])
        self.assertTrue(any("甲游戏" in e and "没补上 S 级优化" in e and "乙游戏" not in e for e in self.events), self.events)

if __name__ == "__main__":
    unittest.main()
