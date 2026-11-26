#!/usr/bin/env python3
"""挪起点的确定性判据（docs/对照局模板.md「挪起点」，tools/ab_fixed.sh move 调）：同一份旧起点 + 同一段手柄录像走两次，
两次存下的新起点（即时存档目录里的 a_last.png，存档那一刻的整帧）画面要一致，才说明输入是确定的、新起点可复现。
比法同 tools/route_speed.py：缩到 128×72 亮度、零均值归一化相关（整幅，不搜位移）；相关 ≥ 0.9 算一致。
用法：ab_fixed_snapcmp.py <新起点 1 目录> <新起点 2 目录>   末行 JSON {verdict, corr, why}；退出码 0 一致、1 不一致、2 读不出"""
import json
import sys

W, H, MIN_CORR = 128, 72, 0.9


def luma(path):
    from PIL import Image
    with Image.open(path) as im:
        return list(im.convert('L').resize((W, H)).tobytes())


def corr(a, b):
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    va, vb = [x - ma for x in a], [x - mb for x in b]
    sa, sb = sum(x * x for x in va) ** 0.5, sum(x * x for x in vb) ** 0.5
    return sum(x * y for x, y in zip(va, vb)) / (sa * sb) if sa and sb else 0.0


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    try:
        a, b = (luma(f'{d}/a_last.png') for d in argv)
    except (OSError, ValueError) as e:
        print(json.dumps({'verdict': '读不出', 'corr': None, 'why': str(e)}, ensure_ascii=False))
        return 2
    c = corr(a, b)
    ok = c >= MIN_CORR
    print(json.dumps({'verdict': '一致' if ok else '不一致', 'corr': round(c, 3),
                      'why': f'两次新起点画面相关 {c:.3f}（≥ {MIN_CORR} 算一致）' + ('' if ok else '：同一段输入两次走到的地方不同，输入不确定，新起点不能用')}, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
