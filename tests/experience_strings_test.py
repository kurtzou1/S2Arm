#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""launchers/shared/experience_strings.py：从体验规格生成 iOS .strings 片段。期望值按规格与 errors.py 手写"""
import json, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "launchers/shared/experience_strings.py"


def run(*args):
    return subprocess.run([sys.executable, "-B", str(TOOL), *args], capture_output=True, text=True, encoding="utf-8")


class ExperienceStrings(unittest.TestCase):
    def test_both_languages_cover_every_ios_code(self):
        codes = sorted(i["code"] for i in json.loads((ROOT / "launchers/shared/experience.v1.json").read_text(encoding="utf-8"))["errors"]["items"] if i["code"].startswith(("ios_install_", "ios_import_")))
        self.assertEqual(len(codes), 10)
        for lang in ("zh-Hans", "zh-Hant", "en"):
            with self.subTest(lang=lang):
                p = run("--lang", lang)
                self.assertEqual(p.returncode, 0, p.stderr)
                keys = [l.split('"')[1] for l in p.stdout.splitlines() if l.startswith('"')]
                self.assertEqual(keys, [f"error.{c}.{k}" for c in codes for k in ("title", "next")])

    def test_zh_hant_from_table_and_missing_sentence_is_red(self):
        # 繁中按简中原句查 experience_zh_hant.json（手写台港用语）；对照表少一句 → 退出 1 并点名那句，不出半套
        out = run("--lang", "zh-Hant").stdout
        self.assertIn('"error.ios_install_no_space.title" = "手機空間不足";', out)
        self.assertIn('"error.ios_install_unknown.next" = "匯出診斷包傳給我們。";', out)
        table = ROOT / "launchers/shared/experience_zh_hant.json"
        saved = table.read_text(encoding="utf-8")
        try:
            t = json.loads(saved); del t["手机空间不够"]
            table.write_text(json.dumps(t, ensure_ascii=False), encoding="utf-8")
            p = run("--lang", "zh-Hant")
            self.assertEqual(p.returncode, 1)
            self.assertIn("手机空间不够", p.stderr)
        finally:
            table.write_text(saved, encoding="utf-8")

    def test_known_values(self):
        self.assertIn('"error.ios_install_unknown.title" = "未知原因";', run("--lang", "zh-Hans").stdout)
        self.assertIn('"error.ios_install_no_space.next" = "Free up some space, then tap Retry.";', run("--lang", "en").stdout)

    @unittest.skipUnless(shutil.which("plutil"), "只有 macOS 带 plutil")
    def test_output_is_a_valid_strings_file(self):
        for lang in ("zh-Hans", "en"):
            with tempfile.TemporaryDirectory() as d:
                f = Path(d, "S2ArmHost.strings"); f.write_text(run("--lang", lang).stdout, encoding="utf-8")
                self.assertEqual(subprocess.run(["plutil", "-lint", str(f)], capture_output=True).returncode, 0, lang)

    def test_missing_english_fails_and_names_the_code(self):
        spec = json.loads((ROOT / "launchers/shared/experience.v1.json").read_text(encoding="utf-8"))
        spec["errors"]["items"].append({"code": "ios_install_zz_probe", "title": {"zh-Hans": "探针", "en": ""}, "detail": {}, "next_action": {"from": "pack/jobs/errors.py"}})
        with tempfile.TemporaryDirectory() as d:
            f = Path(d, "spec.json"); f.write_text(json.dumps(spec, ensure_ascii=False), encoding="utf-8")
            p = run("--lang", "en", "--spec", str(f))
        self.assertEqual(p.returncode, 1); self.assertIn("ios_install_zz_probe", p.stderr)
        self.assertEqual(p.stdout, "")   # 不出半套


if __name__ == "__main__":
    unittest.main()
