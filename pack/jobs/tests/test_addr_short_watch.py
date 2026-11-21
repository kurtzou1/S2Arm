# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Mac 一局的宿主输出里出现「地址空间不够这款」那条黄行 → 发一次 notice addr_short（pack/jobs/build.py addr_short_watch）。
期望手写：有那行 → 恰好一条事件（重复出现也只一条）；没有那行（别的黄行 / 红行 / 普通行）→ 0 条"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build  # noqa: E402

LINE = "[s2a] 【黄】地址空间不够这款：静态大区 57 GB 的末端顶到窗口末（窗口 59392 MB），游戏其余地址区会落在窗口外走远端，可能非常卡或停在开头"


class Ctx:
    def __init__(self): self.events = []
    def emit(self, kind="progress", message="", **extra): self.events.append((kind, message, extra))


class AddrShortWatch(unittest.TestCase):
    def test_line_emits_once(self):
        c = Ctx(); w = build.addr_short_watch(c)
        for line in ("[s2a] 窗口已占", LINE, "[s2a] 首帧", LINE):
            w(line)
        self.assertEqual(c.events, [("notice", "", {"code": "addr_short"})])

    def test_no_line_no_event(self):
        c = Ctx(); w = build.addr_short_watch(c)
        for line in ("[s2a] 【黄】这台手机内存偏小", "[s2a] 【红】地址窗口不足", "[s2a] 地址按需：标准布局要 70286 MB"):
            w(line)
        self.assertEqual(c.events, [])


if __name__ == "__main__":
    unittest.main()
