# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#746 写单一 IMG 边写边腾解包（ipa.to_img → pack/img.py convert --consume）：
  ① 同一款不接着出别的平台：带 --consume；写失败 → 出包工作目录除 build/ios/logs 外清空（解包已删了一部分，重试从解包重做）
  ② 接着还要出别的平台（followUp）：不带 --consume；写失败也不清（解包留给下一个平台）
  ③ 取消 / 进程被杀（玩家报「romfs.s2aidx 里的 X 不在 game.img 的 RomFS 段」）：取消同样清空；被杀来不及清的，靠出包工作目录里的
     .img_consume_inflight 标记，下次出包开头（drop_half_consumed）清空；写成功标记删掉"""
import unittest
from unittest.mock import patch
from jobcase import JobCase
from core import Cancelled, Context, Failure
import ipa, layout

GID = "0100F43008C44000"


class ImgConsume(JobCase):
    def run_to_img(self, **extra):
        self.sequence += 1
        c = Context(self.request | dict(taskId=f"img-{self.sequence}", operation="ipa", gameId=GID) | extra)
        out = layout.ios_work(c, GID)
        for rel in ("roots/kuan@v1/romfs/a.bin", "extract/romfs/a.bin", "pack/index.tsv", "logs/ipa.log"):
            (out / rel).parent.mkdir(parents=True, exist_ok=True); (out / rel).write_bytes(b"x")
        seen = []
        def fail(args, *a, **kw):
            seen.append([str(x) for x in args]); raise Failure("写到一半盘满了", code="tool_exit")
        with patch.object(c, "run", side_effect=fail), self.assertRaises(Failure) as e:
            ipa.to_img(c, GID, out / "roots/kuan@v1", out / "pack")
        self.assertEqual(e.exception.code, "package_failed")
        return seen[0], sorted(p.name for p in out.iterdir())

    def test_consume_unless_follow_up_and_failure_clears_work(self):
        args, left = self.run_to_img()
        self.assertIn("--consume", args)
        self.assertEqual(args[args.index("--work") + 1], str(layout.ios_work(Context(self.request | dict(operation="ipa", gameId=GID)), GID)))   # 只删这款出包工作目录里的
        self.assertEqual(left, ["logs"])
        args, left = self.run_to_img(followUp=True)
        self.assertNotIn("--consume", args)
        self.assertEqual(left, ["extract", "logs", "pack", "roots"])


    def _work(self, **extra):
        self.sequence += 1
        c = Context(self.request | dict(taskId=f"img-{self.sequence}", operation="ipa", gameId=GID) | extra)
        out = layout.ios_work(c, GID)
        for rel in ("roots/kuan@v1/romfs/a.bin", "pack/index.tsv", "logs/ipa.log"):
            (out / rel).parent.mkdir(parents=True, exist_ok=True); (out / rel).write_bytes(b"x")
        return c, out

    def test_cancel_also_clears_work(self):
        c, out = self._work()
        with patch.object(c, "run", side_effect=Cancelled()), self.assertRaises(Cancelled):
            ipa.to_img(c, GID, out / "roots/kuan@v1", out / "pack")
        self.assertEqual(sorted(q.name for q in out.iterdir()), ["logs"])

    def test_killed_mid_consume_cleared_next_time_and_success_drops_mark(self):
        c, out = self._work()
        ipa.drop_half_consumed(c, GID)   # 没标记：什么都不删
        self.assertEqual(sorted(q.name for q in out.iterdir()), ["logs", "pack", "roots"])
        (out / ipa.CONSUME_MARK).write_text("上一个任务")   # 进程被杀：标记留着
        ipa.drop_half_consumed(c, GID)
        self.assertEqual(sorted(q.name for q in out.iterdir()), ["logs"])
        c, out = self._work()
        with patch.object(c, "run", return_value=None):   # 写成功：标记删掉、别的不动
            ipa.to_img(c, GID, out / "roots/kuan@v1", out / "pack")
        self.assertFalse((out / ipa.CONSUME_MARK).exists()); self.assertIn("roots", [q.name for q in out.iterdir()])

if __name__ == "__main__":
    unittest.main()
