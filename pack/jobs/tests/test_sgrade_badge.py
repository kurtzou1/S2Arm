# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""游戏库封面金色 S（pack/jobs/library.py sgrade_badge，v0.4.0）：已打进补丁 / 快照里有这款的包 → 亮；都没有、或出包页取消过「出包时打入」→ 不亮。期望手写"""
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import layout
import library
import patches


class SGradeBadgeTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = types.SimpleNamespace(private=self.t, r={})
        self.img = self.t / "img"; self.img.mkdir(); self.kit = self.t / "kit"; self.kit.mkdir()
        self.info = {}
        for p in (patch.object(layout, "game_info", side_effect=lambda c, g: self.info), patch.object(layout, "ios_kit", return_value=self.kit),
                  patch.dict(patches._MANIFEST, {"snap": {"g/0100AAAA00000000": {"items": 3}, "g/0100CCCC00000000": {"items": 0}}})):
            p.start(); self.addCleanup(p.stop)

    def test_badge(self):
        self.assertTrue(library.sgrade_badge(self.c, "0100aaaa00000000", self.img), "快照里有这款的包（程序号大小写不论）")
        self.assertFalse(library.sgrade_badge(self.c, "0100BBBB00000000", self.img), "快照里没有、也没打进补丁")
        self.assertFalse(library.sgrade_badge(self.c, "0100CCCC00000000", self.img), "包里 0 条不算")
        (self.kit / "cpatch.tsv").write_text("编号\n")
        self.assertFalse(library.sgrade_badge(self.c, "0100BBBB00000000", self.img), "只有表头的补丁表不算")
        (self.kit / "cpatch.tsv").write_text("编号\nwsauto:x:w\n")
        self.assertTrue(library.sgrade_badge(self.c, "0100BBBB00000000", self.img), "iPhone 程序件里已打进补丁")
        self.info["sgradeOff"] = True
        self.assertFalse(library.sgrade_badge(self.c, "0100AAAA00000000", self.img), "出包页取消过：不亮")


if __name__ == "__main__":
    unittest.main()
