#!/usr/bin/env python3
"""管线键 pso_skey 布局（#1100 W6，11-04 Windows 出包线）：读 pso_layout.json（graphics/tools/direct/pso_layout_gen.m 在 Mac 上导出、提交进仓库），
给出库的 Python 工具按运行时结构体 nvn_pso_skey.h 解 R 行，Mac / Windows 同一份（原先 pso_skey_size.m / fout_want.m 要现编 Objective-C）。
  pso_layout.py skey-size        打印 pso_skey 字节数（原 pso_skey_size.m；direct_lib.py 交 pso_seed.py 核 R 行长度）
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_L = None


def load():
    global _L
    if _L is None:
        with open(os.path.join(HERE, 'pso_layout.json'), encoding='utf-8') as f:
            _L = json.load(f)
    return _L


class Skey:
    """一条 R 行（十六进制）解出的管线键：只取 fout_want 要的字段，与 nvn_pso_skey.h 同一布局"""
    def __init__(self, raw):
        L = load(); self.raw = raw
        o, n = L['fs']; fs = raw[o:o + n]; z = fs.find(b'\0')
        self.fs = fs if z < 0 else fs[:z]   # C 字符串语义：到第一个 0 为止
        self.merged, self.fz = raw[L['merged']], raw[L['fz']]
        self.cfmt = [int.from_bytes(raw[L['cfmt'] + 4 * i:L['cfmt'] + 4 * i + 4], 'little') for i in range(8)]
        self.lmap = list(raw[L['lmap']:L['lmap'] + 8])
        self.blend_en = int.from_bytes(raw[L['blend_en']:L['blend_en'] + 4], 'little')
        b0 = int.from_bytes(raw[L['blend0']:L['blend0'] + 8], 'little')
        self.blend0 = {k: b0 >> s & ((1 << w) - 1) for k, (s, w) in L['blend_bits'].items()}

    def dual_source(self):   # = nvn_pso_skey.h pso_dual_source(&sk.k, sk.merged)
        if self.merged or not self.cfmt[0] or not self.blend_en & 1: return False
        return any(0x10 <= self.blend0[k] <= 0x13 for k in ('src_rgb', 'dst_rgb', 'src_a', 'dst_a'))


def parse(hexs):
    """R 行十六进制 → Skey；长度不对或不是十六进制回 None（= pso_skey_parse 返回 -1）"""
    if len(hexs) != 2 * load()['skey_size']: return None
    try: return Skey(bytes.fromhex(hexs))
    except ValueError: return None


def int_kind(fmt):   # = nvn_pfkind.h pf_int_kind：1 无符号整数、2 有符号整数、0 其余
    L = load(); return 1 if fmt in L['uint_formats'] else 2 if fmt in L['sint_formats'] else 0


if __name__ == '__main__':
    if sys.argv[1:] == ['skey-size']: print(load()['skey_size'])
    else: sys.exit(__doc__)
