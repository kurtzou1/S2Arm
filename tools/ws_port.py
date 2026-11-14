#!/usr/bin/env python3
"""宽屏（画幅）补丁跨游戏版本移植（实验工具，11-13；帧率 / 金手指不做）：旧版本的一份 pchtxt → 新版本主程序上的同一份。

  python3 tools/ws_port.py <旧版补丁 pchtxt> <新版主程序 NSO> <补丁画幅，如 2.3889> [--out <移植后的 pchtxt>] [--truth <新版作者自己的 pchtxt>]

补丁按地址写字节；游戏一更新地址就挪。这里不按地址照搬，按「这一处原来是什么」在新版程序里重新找：
  画幅值（tools/ws_wash.py 认出的 fmov / movz+movk 单精度 / 数据区单精度，值落在画幅式上）：原值必是同一式的 16:9 值
    → 在新版里找同写法、同目标寄存器、值 = 式(16/9) 的位置；
  渲染尺寸对（宽 ÷ 高 = 画幅的两条 MOV 立即数）：原值是一对 16:9 尺寸 → 找同目标寄存器、宽 ÷ 高 = 16/9 的两条，两条间距与旧版相同；
  其余行（显存、界面开关…原值不知道）：在新位置附近找「去掉立即数后同一条指令」（同操作码、同寄存器）的唯一一处，没有 / 不止一处就不移植这一行。
  候选按离「旧地址 + 已定位各处的地址平移」最近取；画幅值找不到唯一一处 → 整份不移植（宁缺不错）。
--truth 给了就逐行比：移植结果与作者自己出的新版补丁地址 / 字节是否一致。
"""
import os, re, struct, sys

H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(H, '..', 'pack')); sys.path.insert(0, H)
import cpatch   # noqa: E402
import ws_wash   # noqa: E402

R = 16 / 9
WIN = 0x400   # 其余行在新位置前后找同形指令的范围（±1 KB：补丁换了操作码的行原指令不同形，放宽会在远处找到无关同形指令——一款 2.7.6→2.7.7 实测 ±64 KB 时阴影行错移 +0x1164）


def image(path):
    _, segs = cpatch.nso_image(path)
    im = bytearray(max(mo + len(d) for mo, d in segs))
    for mo, d in segs: im[mo:mo + len(d)] = d
    text_end, ro, ln, key = cpatch.module_layout(path)
    return bytes(im), text_end


def words_of(writes):
    w = {}
    for off, b in writes:
        for k, v in enumerate(b):
            o = off + k; w.setdefault(o & ~3, {})[o & 3] = v
    return {o: int.from_bytes(bytes(d.get(i, 0) for i in range(4)), 'little') for o, d in w.items() if len(d) == 4}


def scan_words(im, lo, hi, pred):
    return [o for o in range(max(0, lo) & ~3, min(len(im) - 4, hi), 4) if pred(int.from_bytes(im[o:o + 4], 'little'))]


def port(old_text, new_main, A):
    """同 pack/cpatch.py port_writes（出包与本工具共用一份）→ ([(新偏移, 字)], 说明行)"""
    _, secs = cpatch.parse_pchtxt(old_text)
    writes = [x for s in secs if s['enabled'] for x in s['writes']]
    im, text_end = image(new_main)
    out, rep = cpatch.port_writes(writes, A, im, text_end)
    return (None if out is None else [(o, int.from_bytes(b, 'little')) for o, b in out]), rep


def main(argv):
    if len(argv) < 3 or argv[0] in ('-h', '--help'): print(__doc__); return 0
    old, new_main, A = argv[0], argv[1], float(argv[2])
    out, report = port(open(old, encoding='utf-8', errors='replace').read(), new_main, A)
    print('\n'.join(report))
    if out is None: return 1
    if '--out' in argv:
        bid = open(new_main, 'rb').read()[0x40:0x60].hex().upper()
        with open(argv[argv.index('--out') + 1], 'w') as f:
            f.write(f'@nsobid-{bid}\n\n# 移植自 {os.path.basename(old)}（tools/ws_port.py）\n\n@flag offset_shift 0x100\n\n@enabled\n')
            for o, x in out: f.write(f'{o:08x} {x.to_bytes(4, "little").hex().upper()}\n')
            f.write('@stop\n')
    if '--truth' in argv:
        _, secs = cpatch.parse_pchtxt(open(argv[argv.index('--truth') + 1], encoding='utf-8', errors='replace').read())
        tw = words_of([x for s in secs if s['enabled'] for x in s['writes']])
        mine = dict(out)
        same_off = sorted(set(mine) & set(tw)); only_mine = sorted(set(mine) - set(tw)); only_truth = sorted(set(tw) - set(mine))
        same_bytes = [o for o in same_off if mine[o] == tw[o]]
        print(f'对拍作者新版：作者 {len(tw)} 处；地址对上 {len(same_off)}（字节也相同 {len(same_bytes)}）；只在移植里 {[hex(o) for o in only_mine]}；移植漏了 {[hex(o) for o in only_truth]}')
        for o in same_off:
            if mine[o] != tw[o]: print(f'  {o:#x} 字节不同：移植 {mine[o]:08x} / 作者 {tw[o]:08x}（同处不同值 = 两版作者给的档不同）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
