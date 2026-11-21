# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳：启动器新版本打开时的快速比对「建议更新」（pack/jobs/host_update.py update_hints，《文件与程序管理体系》⑦ ③）。
游戏库是真的（library.setup + layout 写 game.json），本版启动器的值用替身给定（改写器指纹 RIDNOW、约定号 2、着色器链 chainNOW），期望按记录手写。"""
import builtins
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_update  # noqa: E402
import layout  # noqa: E402
import program_pack  # noqa: E402
import rewrite_refresh  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from tests.jobcase import ios_fixture  # noqa: E402

NOW = dict(hostAbi=2, dmshChain="chainNOW")


class UpdateHints(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown
    A, B, C, D, E, F = "0100000000010000", "0100000000020000", "0100000000030000", "0100000000040000", "0100000000050000", "0100000000060000"

    def fixture(self):
        ok = dict(rewriterId="RIDNOW", hostAbi=2, dmshChain="chainNOW", libGen=host_update.LIB_GEN)
        ios_fixture(self.c, self.A, compat=dict(ok, rewriterId="RIDOLD"))     # 改写器更新
        ios_fixture(self.c, self.B, compat=dict(ok, hostAbi=1))               # 约定号变了
        ios_fixture(self.c, self.C, compat=dict(ok, dmshChain="chainOLD"))    # 着色器链更新
        ios_fixture(self.c, self.D, compat=ok)                                # 全对上：不标
        # E 没打过 iPhone 包（没有程序兼容记录）：不标
        if getattr(self, "with_old_lib", False):
            ios_fixture(self.c, self.F, compat={k: v for k, v in ok.items() if k != "libGen"})   # 旧包：库没有客体输入（缺 libGen）
        for g in (self.A, self.B, self.C, self.D):   # 每款放一个游戏大文件：比对不许读它
            (layout.image_ios(self.c, g) / ".pack/game.img").write_bytes(b"\0" * 4096)
        for g in (self.A, self.B, self.C, self.D) + ((self.F,) if getattr(self, "with_old_lib", False) else ()):
            lib = layout.image_ios(self.c, g) / ".pack/shaders/direct/b-chain"   # 直连包：着色器原因只对有直连库的款算（host_update.ios_lib_reasons，只看在不在、不打开）
            lib.mkdir(parents=True, exist_ok=True); (lib / "lib.idx").write_bytes(b"")
        ids = [self.A, self.B, self.C, self.D, self.E] + ([self.F] if getattr(self, "with_old_lib", False) else [])
        self.c.catalog = lambda: {"games": [{"id": g, "name": g} for g in ids]}

    def hints(self, on=True):
        with patch.object(rewrite_refresh, "rewriter_id", lambda c: "RIDNOW"), \
                patch.object(host_update, "engine_compat", lambda c: NOW):
            return host_update.update_hints(self.c)

    def test_three_reasons_and_matching_game_not_marked(self):
        self.fixture()
        self.assertEqual(self.hints(), dict(games=[
            dict(gameId=self.A, reasons=["rewriter"]), dict(gameId=self.B, reasons=["hostAbi"]), dict(gameId=self.C, reasons=["shader"])]))

    def test_does_not_read_game_files(self):
        # 只读程序兼容记录（几 KB）：游戏大文件 game.img、资源包目录里的任何文件都不打开
        self.fixture()
        opened, real_open, real_io = [], builtins.open, io.open
        def spy(f, *a, **k):
            opened.append(str(f)); return real_open(f, *a, **k)
        def spy_io(f, *a, **k):
            opened.append(str(f)); return real_io(f, *a, **k)
        with patch.object(builtins, "open", spy), patch.object(io, "open", spy_io):
            r = self.hints()
        self.assertEqual(len(r["games"]), 3)
        self.assertEqual([p for p in opened if "game.img" in p or "/.pack/" in p], [])
        self.assertTrue(any(p.endswith("game.json") for p in opened), "读的是 game.json")

    def test_rewriter_id_unavailable_is_not_a_reason(self):
        # 取不到改写器指纹：这一项不判（不因此给所有款标「建议更新」），约定号 / 着色器链照判
        self.fixture()
        from core import Failure
        def boom(c):
            raise Failure("取不到")
        with patch.object(rewrite_refresh, "rewriter_id", boom), \
                patch.object(host_update, "engine_compat", lambda c: NOW):
            r = host_update.update_hints(self.c)
        self.assertEqual(r["games"], [dict(gameId=self.B, reasons=["hostAbi"]), dict(gameId=self.C, reasons=["shader"])])

    def test_old_lib_generation_is_a_reason(self):
        # 直连库内容代数（host_update.LIB_GEN）：记录里没有 libGen 的旧包（0.5.x 出的，库不带客体输入）→ 原因 libGen；带了当前代数的不标
        self.with_old_lib = True; self.fixture()
        self.assertEqual(self.hints()["games"][-1], dict(gameId=self.F, reasons=["libGen"]))
        self.assertNotIn(self.D, [g["gameId"] for g in self.hints()["games"]])


if __name__ == "__main__":
    unittest.main()
