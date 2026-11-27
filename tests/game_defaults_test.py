#!/usr/bin/env python3
"""逐款测过的缺省（11-27，tools/game_defaults.py）：表的规矩、查表优先级、生成头新鲜度、Mac 设置页「本款推荐」。期望全部手写。
  ① 真仓库：表合格、runtime/include/s2a_game_defaults.h 与表一致；改表不重新生成 → check 报红（反证）
  ② 夹具表（runtime/tests/data/game_defaults_fixture.tsv，宿主单测 t_game_defaults.c 同一份）按同一组期望查：精确构建号 > *、精确平台 > *
  ③ lint 每条规则正反：列数、程序号、构建号、平台、设置 id / 无 env、值不在 options、缺对照、缺测过的构建号、重复
  ④ 读模块目录：npdm 程序号、nro_tables.tsv 的 main 段构建号优先于别的模块段、退回 main.fixups.tsv
  ⑤ Mac 设置页：没选过的项显示本款值并标 recommended；选过的照选的、不标；没走直连时 MetalFX 逐款值不算"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import game_defaults as g  # noqa: E402

FIX = ROOT / "runtime/tests/data/game_defaults_fixture.tsv"
PID = "0100000000ABC000"
OK_WHY = "\t# 甲 vs 乙；测过 1111111111111111"


class Repo(unittest.TestCase):
    def test_real_table_and_header(self):
        r = subprocess.run([sys.executable, str(ROOT / "tools/game_defaults.py"), "check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # 反证：表多一行、头没重新生成 → check 报红
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        for rel in ("tools/game_defaults.py", "launchers/shared/game_settings.v1.json", "launchers/shared/game_defaults.v1.tsv", "runtime/include/s2a_game_defaults.h"):
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True); shutil.copy(ROOT / rel, tmp / rel)
        with (tmp / "launchers/shared/game_defaults.v1.tsv").open("a", encoding="utf-8") as f:
            f.write(f"{PID}\t*\t*\tdocked\tdocked{OK_WHY}\n")
        r = subprocess.run([sys.executable, str(tmp / "tools/game_defaults.py"), "check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout); self.assertIn("与表不一致", r.stdout)


class Lookup(unittest.TestCase):
    rows = g.parse(FIX.read_text(encoding="utf-8"))

    def test_fixture_lints(self):
        self.assertEqual(g.lint(self.rows, g.settings_items()), [])

    def test_same_expectations_as_host(self):
        L = lambda bid, plat, key: (g.lookup(self.rows, PID, bid, plat, key) or (None,))[0]
        self.assertEqual(L("1111111111111111aaaa", "mac", "docked"), "docked")      # * 行；构建号只比前 16 位
        self.assertEqual(L("2222222222222222", "mac", "docked"), "handheld")         # 精确构建号行盖过 *
        self.assertEqual(L("3333333333333333", "mac", "docked"), "docked")          # 没有精确行走 *
        self.assertEqual(L("1111111111111111", "mac", "quality"), "Nearest")
        self.assertEqual(L("1111111111111111", "ios", "quality"), "MetalFX")
        self.assertEqual(L("1111111111111111", "android", "quality"), None)
        self.assertEqual(L("1111111111111111", "mac", "drawBarriers"), "game")
        self.assertEqual(g.lookup(self.rows, "0100000000DEF000", "1111111111111111", "mac", "docked"), None)
        self.assertEqual(g.env_of(g.settings_items()["docked"], "docked"), ("S2A_DOCKED", "1"))
        self.assertEqual(g.env_of(g.settings_items()["quality"], "MetalFX"), ("S2A_SCALING_FILTER", "MetalFX"))


class Lint(unittest.TestCase):
    def errs(self, line):
        return g.lint(g.parse(line), g.settings_items())

    def test_each_rule(self):
        self.assertEqual(self.errs(f"{PID}\t*\t*\tdocked\tdocked{OK_WHY}\n"), [])
        for bad, word in ((f"{PID}\t*\tdocked\tdocked{OK_WHY}", "5 列"),
                          (f"0100000000abc000\t*\t*\tdocked\tdocked{OK_WHY}", "程序号"),
                          (f"{PID}\tXYZ\t*\tdocked\tdocked{OK_WHY}", "构建号"),
                          (f"{PID}\t*\tpc\tdocked\tdocked{OK_WHY}", "平台"),
                          (f"{PID}\t*\t*\trumble\tTrue{OK_WHY}", "没有 env"),
                          (f"{PID}\t*\t*\tdocked\ttv{OK_WHY}", "options"),
                          (f"{PID}\t*\t*\tdocked\tdocked\t# 测过 1111111111111111", "对照"),
                          (f"{PID}\t*\t*\tdocked\tdocked\t# 甲 vs 乙", "测过的构建号")):
            with self.subTest(word=word):
                e = self.errs(bad + "\n")
                self.assertTrue(any(word in x for x in e), e)
        e = self.errs(f"{PID}\t*\t*\tdocked\tdocked{OK_WHY}\n{PID}\t*\t*\tdocked\thandheld{OK_WHY}\n")
        self.assertTrue(any("重复" in x for x in e), e)


class Peek(unittest.TestCase):
    def test_module_dir(self):
        d = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, d)
        npdm = bytearray(0x98); npdm[0:4] = b"META"; npdm[0x70:0x74] = (0x80).to_bytes(4, "little")
        npdm[0x80:0x84] = b"ACI0"; npdm[0x90:0x98] = (0x0100000000ABC000).to_bytes(8, "little")
        (d / "main.npdm").write_bytes(bytes(npdm))
        self.assertEqual(g.peek_pid(d), PID)
        (d / "main.fixups.tsv").write_text("# BUILD_ID\tCCCC111111111111\n")
        self.assertEqual(g.peek_bid(d), "cccc111111111111")
        (d / "nro_tables.tsv").write_text("说明\n@fixups\tsubsdk0\n# BUILD_ID\t9999999999999999\n@fixups\tmain\n# BUILD_ID\tABCD000000000000\n@gates\tmain\n")
        self.assertEqual(g.peek_bid(d), "abcd000000000000")   # 合并随行表 main 段优先，不取别的模块段
        self.assertEqual(g.peek_pid(d / "nope"), ""); self.assertEqual(g.peek_bid(d / "nope"), "")


class MacSettings(unittest.TestCase):
    def test_recommended_shown(self):
        sys.path.insert(0, str(ROOT / "pack/jobs")); sys.path.insert(0, str(ROOT / "pack/jobs/tests"))
        import jobcase, community, layout
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        eng = tmp / "engine"
        for rel in ("tools/game_defaults.py", "launchers/shared/game_settings.v1.json"):
            (eng / rel).parent.mkdir(parents=True, exist_ok=True); shutil.copy(ROOT / rel, eng / rel)
        shutil.copy(FIX, eng / "launchers/shared/game_defaults.v1.tsv")
        c = jobcase.fake_context(tmp, engine=eng)
        mac = layout.image_mac(c, PID); mac.mkdir(parents=True, exist_ok=True); (mac / "main.fixups.tsv").write_text("# BUILD_ID\t2222222222222222\n")
        (mac / "s2a_caps.tsv").write_text("direct\t0\n")
        s = community.mac_settings(c, PID)
        self.assertEqual((s["docked"]["value"], s["docked"].get("recommended")), ("handheld", True))   # 精确构建号行
        self.assertEqual((s["quality"]["value"], s["quality"].get("recommended")), ("Nearest", True))  # mac 行（Nearest 不要直连）
        self.assertNotIn("recommended", s["fpsLimit"])                                                 # 表里没有的项
        p = community.launch_path(c, PID); p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"schema": 1, "settings": {"docked": "docked"}, "patches": {}}), encoding="utf-8")   # 玩家选过主机（launch.json 原样）
        s = community.mac_settings(c, PID)
        self.assertEqual((s["docked"]["value"], s["docked"].get("recommended")), ("docked", None))      # 选过的照选的、不标
        (eng / "launchers/shared/game_defaults.v1.tsv").write_text(f"{PID}\t*\tmac\tquality\tMetalFX{OK_WHY}\n", encoding="utf-8")
        s = community.mac_settings(c, PID)
        self.assertEqual((s["quality"]["value"], s["quality"].get("recommended")), ("Bilinear", None))  # 没走直连：MetalFX 逐款值不算


if __name__ == "__main__":
    unittest.main(verbosity=1)
