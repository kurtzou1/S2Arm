# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""翻译器修复的受影响键清单（pack/jobs/xlate_affected.py）与「建议更新」原因 xlateFix（host_update.ios_lib_reasons）。
期望按清单规则手写，不跑被测实现推：清单 = release 0.6.10 X0 → step X1→X2（键 k1）→ step X2→X3（键 k2）。
  · 包在某一步之前：这一步和之后各步的键都算；包已是某步改后的翻译器出的：这一步和之前的不算；位置认不出：不标（None）
  · 反证：清单里放一个包里没有的键 → 不标；放一个包里有的键 → 必须标
  · 接进「建议更新」：只有包里有清单键的那款带 xlateFix，链号 / 代数都对的别的款不受影响"""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_update  # noqa: E402
import layout  # noqa: E402
import rewrite_refresh  # noqa: E402
import xlate_affected as xa  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from tests.jobcase import ios_fixture  # noqa: E402

K1, K2, K3 = "00000000000000a1", "00000000000000b2", "00000000000000c3"
LIST = "\n".join(["# 注释行不算", "release\t0.6.10\tX0", f"step\tX1\tX2\t13\t第一步", f"key\tX2\t{K1}", f"step\tX2\tX3\t13\t第二步", f"key\tX3\t{K2.upper()}", ""])


class KeysAfter(unittest.TestCase):
    def setUp(self):
        self.rows, self.keys = xa.parse(LIST)

    def test_positions(self):
        cases = [
            (dict(version="0.6.10"), {K1, K2}, "0.6.10 出的包：两步都在之后"),
            (dict(xfp="X0"), {K1, K2}, "指纹是 0.6.10 那一行的：同上"),
            (dict(xfp="X1"), {K1, K2}, "第一步改前的翻译器：两步都算"),
            (dict(xfp="X2"), {K2}, "第一步改后（第二步改前）：只算第二步"),
            (dict(xfp="X3"), set(), "已是最新：都不算"),
        ]
        for kw, want, why in cases:
            self.assertEqual(xa.keys_after(self.rows, self.keys, **kw), want, why)
        self.assertIsNone(xa.keys_after(self.rows, self.keys, xfp="ZZ"), "认不出的指纹：不标")
        self.assertIsNone(xa.keys_after(self.rows, self.keys, version="0.6.9"), "清单开始之前的发版：不标")

    def test_bad_row_is_an_error(self):
        with self.assertRaises(ValueError):
            xa.parse("stepp\tX1\tX2\n")

    def test_release_row(self):
        """发版行：切版时追加、出候选前核（发版脚本自动做）。期望按规则手写：最后一行 X3 = 本树 → 追加 release 0.6.11 X3，核对过；
        重跑原样；带不带 v 前缀一样；本树指纹 ≠ 最后一行（翻译器改了没登记 step）→ 拒绝追加；只追加了别的版本 → 核对不过"""
        once = xa.with_release(LIST, "v0.6.11", "X3")
        self.assertTrue(once.endswith("release\t0.6.11\tX3\n"), "追加在末尾、去掉 v 前缀")
        rows, _ = xa.parse(once)
        self.assertTrue(xa.release_ok(rows, "0.6.11", "X3") and xa.release_ok(rows, "v0.6.11", "X3"), "追加后核对过")
        self.assertEqual(xa.with_release(once, "0.6.11", "X3"), once, "重跑不重复加")
        self.assertFalse(xa.release_ok(xa.parse(LIST)[0], "0.6.11", "X3"), "没追加：核对不过（发版红）")
        self.assertFalse(xa.release_ok(rows, "0.6.12", "X3"), "末尾是别的版本：核对不过")
        with self.assertRaises(ValueError):
            xa.with_release(LIST, "0.6.11", "X4")   # 本树已是 X4、清单停在 X3：先登记 step X3→X4，不能拿 release 行盖过去
        with self.assertRaises(ValueError):
            xa.with_release(once, "0.6.11", "X4")   # 切版后翻译器又改了
        self.assertEqual(xa.keys_after(rows, self.keys, version="0.6.11"), set(), "新发版出的包：已有的两步都不算")


class Affected(unittest.TestCase):
    """xlate_affected.affected：兼容记录定位置，资源包 keys.tsv 取交集"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        (self.root / "engine/translator").mkdir(parents=True)
        (self.root / "engine" / xa.LIST).write_text(LIST, encoding="utf-8")
        self.direct = self.root / "pack/shaders/direct"; self.direct.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def count(self, keys, ios):
        (self.direct / "keys.tsv").write_text("".join(k + "\n" for k in keys), encoding="utf-8")
        return xa.affected(self.root / "engine", ios, self.direct)

    def test_negative_and_positive(self):
        old = dict(builtBy=dict(version="0.6.10"))
        self.assertEqual(self.count([K3, "00000000000000d4"], old), 0, "反证：清单的键包里没有 → 不标")
        self.assertEqual(self.count([K3, K1], old), 1, "包里有清单的键 → 标（1 个）")
        self.assertEqual(self.count([K1, K2.upper(), K3], old), 2, "大小写不同也认：两个")
        self.assertEqual(self.count([K1, K2], dict(old, xlateFp="X3")), 0, "包已是最新翻译器出的 → 不标")
        self.assertEqual(self.count([K1, K2], dict(old, xlateFp="X2")), 1, "包是第一步改后出的 → 只算第二步的 k2")
        self.assertEqual(self.count([K1, K2], dict(builtBy=dict(version="0.6.10"), xlateFp="DEV")), 2, "指纹认不出（开发版）→ 按发版号 0.6.10")
        self.assertEqual(self.count([K1, K2], {}), 0, "兼容记录里两样都没有 → 不标")

    def test_no_list_in_engine(self):
        (self.root / "engine" / xa.LIST).unlink()
        self.assertEqual(self.count([K1], dict(builtBy=dict(version="0.6.10"))), 0, "引擎没带清单（之前的版本）→ 不标")

    def test_lib_xfp(self):
        lib = self.direct / "b-chain"; lib.mkdir()
        (lib / "inputs.tsv").write_text("# x\ngame\t0100\ninputs\tab\nxfp\t2d7c7840aeaebd07\nlock\tff\n", encoding="utf-8")
        self.assertEqual(xa.lib_xfp(self.direct), "2d7c7840aeaebd07")


class UpdateHintReason(unittest.TestCase):
    """接进 host_update：链号 / 代数都对的两款，只有包里有清单键的那款带 xlateFix"""
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown
    A, B = "0100000000010000", "0100000000020000"
    NOW = dict(hostAbi=2, dmshChain="chainNOW")

    def test_only_the_pack_with_a_listed_key(self):
        ok = dict(rewriterId="RIDNOW", hostAbi=2, dmshChain="chainNOW", libGen=host_update.LIB_GEN, builtBy=dict(version="0.6.10"))
        for g, keys in ((self.A, [K1, K3]), (self.B, [K3])):
            ios_fixture(self.c, g, compat=ok)
            direct = layout.image_ios(self.c, g) / ".pack/shaders/direct"
            (direct / "b-chain").mkdir(parents=True, exist_ok=True); (direct / "b-chain/lib.idx").write_bytes(b"")
            (direct / "keys.tsv").write_text("".join(k + "\n" for k in keys))
        self.c.catalog = lambda: {"games": [{"id": g, "name": g} for g in (self.A, self.B)]}
        rows = xa.parse(LIST)
        with patch.object(rewrite_refresh, "rewriter_id", lambda c: "RIDNOW"), patch.object(host_update, "engine_compat", lambda c: self.NOW), \
                patch.object(host_update, "built_older", lambda c, b: False), patch.object(xa, "load", lambda engine: rows):
            got = host_update.update_hints(self.c)
        self.assertEqual(got, dict(games=[dict(gameId=self.A, reasons=["xlateFix"])]), "A 包里有 k1 → 标；B 只有清单外的键 → 不标")


if __name__ == "__main__":
    unittest.main()
