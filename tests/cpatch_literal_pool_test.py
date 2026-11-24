#!/usr/bin/env python3
"""金手指自带字面量池（#1321，Mac 0.6.9 一款游戏、构建号 F74B633E480E4E16 的 7 段转换失败原文）：pack/cpatch.py literal_pool 认哪些 LDR / 常量字。
夹具是玩家贴的原文（04000000 <偏移> <新字>）；原代码按「全是 nop（非填充）」合成：空隙原来不是 0 / udf，这些字都走 p 行双路。
期望按 AArch64 编码手算（LDR literal 目标 = 本条 + imm19×4），不跑被测实现推导。"""
import os
import struct
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pack"))
import cpatch  # noqa: E402

CHEATS = {
    "金钱获取后最大": """03FCC688 14FC92F1
07EF124C 180000E1
07EF1250 17036D0F
03FCC7D0 14FC92A1
07EF1254 180000A1
07EF1258 17036D5F
03408128 152BA44D
07EF125C 18000068
07EF1260 B90012A8
07EF1264 16D45BB2
07EF1268 0098967F""",
    "耐力100%": """02B0843C 154FA38E
07EF1274 1C000061
07EF1278 BD004261
07EF127C 16B05C71
07EF1280 4479C000""",
    "秒杀": """033A2D30 152D395C
07EF12A0 1C000040
07EF12A4 16D2C6A4
07EF12A8 497423F0""",
    "送NPC礼物": """034184C0 152B6382
07EF12C8 18000055
07EF12CC 16D49C7E
07EF12D0 0098967F""",
    "master code": """07FC0578 0098967F""",
    "金钱获取后最大（第二段）": """04094988 14FCCD79
07FC7F6C 180000E1
07FC7F70 17033287
04094AD0 14FCCD29
07FC7F74 180000A1
07FC7F78 170332D7
0345F008 152DA3DD
07FC7F7C 18000068
07FC7F80 B90012A8
07FC7F84 0098967F""",
    "原料999": """039D8E90 1517BC42
07FC7F98 180000CA
07FC7F9C B90016CA
07FC7FA0 16E843BD
039D8F08 1517BC27
07FC7FA4 18000069
07FC7FA8 B90016C9
07FC7FAC 16E843D8
07FC7FB0 000003E7""",
}


class NopImage:
    """整份映像的每个字都是 nop（0xD503201F，非填充）：只按 cpatch.fill 读的 im[a:a+4] 切片回答"""
    def __getitem__(self, s):
        n = s.stop - s.start
        return (struct.pack("<I", 0xD503201F) * (n // 4 + 1))[:n]


def words_of(text):
    return {int(a, 16): bytearray(struct.pack("<I", int(w, 16))) for a, w in (l.split() for l in text.splitlines())}


class LiteralPoolTest(unittest.TestCase):
    def pool(self, name):
        return cpatch.literal_pool(NopImage(), words_of(CHEATS[name]))

    def test_money(self):   # 三条 ldr w1 / w1 / w8 都读 0x7EF1268（124C+0x1C、1254+0x14、125C+0xC），前一字 1264 是 b
        self.assertEqual(self.pool("金钱获取后最大"), ({0x7EF124C: 0x0098967F, 0x7EF1254: 0x0098967F, 0x7EF125C: 0x0098967F}, {0x7EF1268}))

    def test_float_literals(self):   # ldr s1 / s0：1274+0xC、12A0+0x8；常量前一字都是 b
        self.assertEqual(self.pool("耐力100%"), ({0x7EF1274: 0x4479C000}, {0x7EF1280}))
        self.assertEqual(self.pool("秒杀"), ({0x7EF12A0: 0x497423F0}, {0x7EF12A8}))

    def test_gift(self):   # ldr w21, 12C8+0x8
        self.assertEqual(self.pool("送NPC礼物"), ({0x7EF12C8: 0x0098967F}, {0x7EF12D0}))

    def test_materials(self):   # ldr w10 7F98+0x18、ldr w9 7FA4+0xC 都读 7FB0，前一字 7FAC 是 b
        self.assertEqual(self.pool("原料999"), ({0x7FC7F98: 0x3E7, 0x7FC7FA4: 0x3E7}, {0x7FC7FB0}))

    def test_not_a_pool(self):
        # master code：只写一个常量字、没有 LDR 读它 → 不是池，照旧出 p 行（改写器记「解不出」、整份不收：原代码上的数据字没有双路可分）
        self.assertEqual(self.pool("master code"), ({}, set()))
        # 第二段「金钱获取后最大」：三条 ldr 都读 7F88（7F6C+0x1C、7F74+0x14、7F7C+0xC），本份补丁没写 7F88；常量写在 7F84、前一字是 str 不是 b
        #   （从第一段搬过来时少了跳回去的 b，常量正好落在要执行的位置上）→ 不按池处理，照旧不收
        self.assertEqual(self.pool("金钱获取后最大（第二段）"), ({}, set()))

    def test_fill_cave_is_not_a_pool(self):   # 空隙原来是 0（填充）：w 行常写，内存里就是补丁写的常量，照旧走原路，不改成装值
        class Zero:
            def __getitem__(self, s): return bytes(s.stop - s.start)
        self.assertEqual(cpatch.literal_pool(Zero(), words_of(CHEATS["耐力100%"])), ({}, set()))


if __name__ == "__main__":
    unittest.main()
