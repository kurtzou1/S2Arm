#!/usr/bin/env python3
"""片元深度寄存器（#869）：用合成的 Maxwell 片元程序过生产翻译器（translator/dmsh_xlate_bin），看 gl_FragDepth 取的是哪个寄存器。
颜色输出每个启用的目标占 4 个寄存器（EmitterContext regIndexBase += 4），深度在最后一个颜色输出之后两个寄存器 = 启用的目标数 × 4 + 1。
期望（按上面的排布手算，不跑被测实现）：
  ① OmapTargets = 0x10f（目标 0 四个分量 + 目标 2 一个分量）、OmapDepth = 1 → 深度读 R9（2 × 4 + 1）。
     程序里 R9 = 输入属性（非常数）、R6 = 常数 0.25（旧公式「启用分量数 + 1」= 6 会读到它）→ gl_FragDepth 不是常数。
  ② OmapTargets = 0xf（一个目标写满 4 个分量）→ 深度读 R5，新旧公式相同（1 × 4 + 1 = 4 + 1）。R5 = 输入属性、R6 = 常数 0.25 → 不是常数。
  反证（手工，不进门禁）：XLATE 指向改前的 dmsh_xlate_bin，① 的 gl_FragDepth 是常数 0.25。
只用标准库：自己拆 SPIR-V 找 FragDepth 内建变量上的 OpStore，看存进去的值是不是 OpConstant。
指令编码同 tests/shader_cases/run.py（MOV32I / ALD / EXIT 与调度字布局）。"""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
XLATE = Path(os.environ.get("XLATE") or ROOT / "translator/dmsh_xlate_bin/dmsh_xlate").parent / "dmsh_xlate.dll"
EXIT = 0xe30000000007000f


def mov32i(rd, bits): return 0x0100000000000000 | ((bits & 0xffffffff) << 20) | (7 << 16) | (15 << 12) | rd


def ald(rd, loc, comp): return 0xefd8000000000000 | (255 << 39) | ((0x80 + loc * 16 + comp * 4) << 20) | (7 << 16) | (255 << 8) | rd


def fragment(targets, ops):
    """0x50 字节片元 SPH（同 shader_cases：类型 / 版本字；ALD 用到的属性位置标成透视插值）+ 每 3 条指令前一个调度字；OmapTargets 在字 18、OmapDepth 是字 19 的第 1 位"""
    ops = ops + [EXIT]
    n = (len(ops) + 2) // 3 * 3
    b = bytearray(0x50 + n // 3 * 32)
    struct.pack_into("<I", b, 0, 2 | (3 << 5) | (5 << 10))
    b[24] = 0xaa   # 属性位置 0 的四个分量都读
    struct.pack_into("<I", b, 72, targets)
    struct.pack_into("<I", b, 76, 1 << 1)
    for i in range(n): struct.pack_into("<Q", b, 0x50 + (i // 3 * 4 + i % 3 + 1) * 8, ops[i] if i < len(ops) else EXIT)
    return bytes(b)


def frag_depth_store(spv):
    """SPIR-V 里存进 FragDepth 内建变量的值 → ("const", 浮点值) / ("value", 定义它的操作码)；没存 → None"""
    w = struct.unpack(f"<{len(spv) // 4}I", spv)
    assert w[0] == 0x07230203, "不是 SPIR-V"
    i, depth, defs, consts, stores = 5, set(), {}, {}, []
    while i < len(w):
        op, n = w[i] & 0xffff, w[i] >> 16
        a = w[i + 1:i + n]
        if op == 71 and len(a) >= 3 and a[1] == 11 and a[2] == 22: depth.add(a[0])   # OpDecorate <id> BuiltIn FragDepth
        elif op == 43: consts[a[1]] = struct.unpack("<f", struct.pack("<I", a[2]))[0]   # OpConstant 类型 id 值
        elif op == 62: stores.append((a[0], a[1]))   # OpStore 指针 值
        elif n > 2: defs.setdefault(a[1], op)   # 带结果的指令：结果 id 在第 2 个操作数
        i += n
    for ptr, val in stores:
        if ptr in depth: return ("const", consts[val]) if val in consts else ("value", defs.get(val))
    return None


def dotnet():
    dn = os.environ.get("DOTNET") or os.path.expanduser("~/.dotnet/dotnet")
    return dn if os.access(dn, os.X_OK) else shutil.which("dotnet")


class FragDepthRegister(unittest.TestCase):
    def translate(self, targets, ops):
        with tempfile.TemporaryDirectory() as d:
            code = Path(d) / "ps.bin"; code.write_bytes(fragment(targets, ops))
            fout = {str(t): "float" for t in range(8) if targets >> (t * 4) & 0xf}
            (Path(d) / "job.json").write_text(json.dumps([{"key": "ps", "stage": "ps", "code": str(code), "debug": False, "attr": {"0": "float"}, "fout": fout}]))
            r = subprocess.run([dotnet(), str(XLATE), str(Path(d) / "job.json"), str(Path(d) / "out")], capture_output=True, text=True, timeout=120)
            spv = Path(d) / "out" / "ps.spv"
            self.assertTrue(spv.is_file(), f"翻译器没出 SPIR-V：rc={r.returncode} {(r.stdout + r.stderr)[-400:]}")
            return frag_depth_store(spv.read_bytes())

    def test_partial_target_reads_r9(self):   # ①
        got = self.translate(0x10f, [ald(9, 0, 0), mov32i(6, 0x3e800000)])
        self.assertIsNotNone(got, "没有写 gl_FragDepth")
        self.assertEqual(got[0], "value", f"gl_FragDepth 是常数 {got[1]}：读到了 R6（按启用分量数算的旧位置），不是 R9")

    def test_full_target_unchanged_r5(self):   # ②
        got = self.translate(0xf, [ald(5, 0, 0), mov32i(6, 0x3e800000)])
        self.assertIsNotNone(got, "没有写 gl_FragDepth")
        self.assertEqual(got[0], "value", f"gl_FragDepth 是常数 {got[1]}：一个写满的目标，深度应读 R5")


if __name__ == "__main__":
    if not dotnet() or not XLATE.is_file(): sys.exit(f"【红】缺 dotnet 或翻译器 {XLATE}")
    unittest.main()
