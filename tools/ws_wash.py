#!/usr/bin/env python3
"""宽屏补丁库体检（只读补丁文本，不要游戏程序）：逐份认出「随画幅变的值」，统计能参数化成自适应满屏的比例。

  python3 tools/ws_wash.py <统一补丁包目录（index.json + g/*.json.gz）> [--tsv <逐份明细输出>]

每份宽屏补丁先定它的画幅 A（索引 aspect 列 → 上游路径目录名 → 文件标题「- 21:9」），再逐个 4 字节写入认：
  fmov 立即数 / movz+movk 拼的单精度 / 直接写的单精度，值落在画幅式上（a = A、w = A÷(16/9)、n = (16/9)÷A、i = 1÷A；
    fmov 只能编约 2 位有效数字，容差 0.07，其余 2e-3）→ 画幅值；
  一对 MOV 立即数「宽 ÷ 高 = A」（容差 1%）→ 渲染尺寸；其余 → 定值（照原样写）。
结论按份：参数化（至少一处画幅值或渲染尺寸）/ 认不出（全是定值：可能是改了计算逻辑，只能原样用）/ 画幅不明 / 读不了。
渲染尺寸只改了一组的（主机或掌机，要看游戏程序原值才分得清）在出包时由 pack/cpatch.py 补齐，这里只计数。
"""
import ast, base64, collections, glob, gzip, json, os, re, struct, sys

H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(H, '..', 'pack'))
import cpatch   # noqa: E402

R = 16 / 9
FORMS = {'a': lambda A: A, 'w': lambda A: A / R, 'n': lambda A: R / A, 'i': lambda A: 1 / A}
_TITLE = re.compile(r'-\s*(\d{1,2}(?:\.\d+)?)\s*[:x]\s*(\d{1,2}(?:\.\d+)?)\s*$', re.M)


def _list(x):
    return x if isinstance(x, list) else (ast.literal_eval(x) if x else [])


# 名义画幅与实际写进补丁的值常不同（21:9 的补丁按 3440×1440 = 43:18 写 2.389、按 2560×1080 = 64:27 写 2.370）：名义 21:9 附带这几种候选
_NEAR = {round(21 / 9, 4): (64 / 27, 43 / 18, 12 / 5)}


def aspects(item, text):
    """→ 候选画幅（去重、按来源先后）：路径里的分辨率（最准）→ 索引 aspect 列 → 路径目录名 → 文件标题；名义 21:9 附带常见实际值"""
    out = []
    src = item.get('source')
    src = ast.literal_eval(src) if isinstance(src, str) and src.startswith('{') else (src or {})
    for p in (src.get('member', ''), src.get('path', '')):
        for m in cpatch._RES_RE.finditer(p):
            if int(m[2]) and 0.4 <= int(m[1]) / int(m[2]) <= 6: out.append(int(m[1]) / int(m[2]))
    m = re.fullmatch(r'(\d+(?:\.\d+)?)[:x](\d+(?:\.\d+)?)', item.get('aspect') or '')
    if m and float(m[2]): out.append(float(m[1]) / float(m[2]))
    for p in (src.get('member', ''), src.get('path', '')):
        A, _ = cpatch.path_aspect('/' + p + '/x')
        if A: out.append(A)
    m = _TITLE.search(text or '')
    if m and float(m[2]): out.append(float(m[1]) / float(m[2]))
    for A in list(out): out += _NEAR.get(round(A, 4), ())
    seen = []
    for A in out:
        if all(abs(A - B) > 1e-6 for B in seen): seen.append(A)
    return seen


def fit(v, A, tol):
    for k, f in FORMS.items():
        t = f(A)
        if abs(v - t) <= tol * max(1.0, abs(t)): return k
    return None


def classify(writes, A):
    """同 pack/cpatch.py aspect_classify（出包与体检共用一份）"""
    return cpatch.aspect_classify(writes, A)


def main(argv):
    if not argv or argv[0] in ('-h', '--help'): print(__doc__); return 0
    d = argv[0]; out = argv[argv.index('--tsv') + 1] if '--tsv' in argv else None
    rows, verdict = [], collections.Counter()
    combos = collections.defaultdict(lambda: collections.Counter())
    for p in sorted(glob.glob(os.path.join(d, 'g', '*.json.gz'))):
        for it in json.load(gzip.open(p))['items']:
            if it.get('cat') != 'widescreen': continue
            raw = base64.b64decode(it.get('data') or '')
            text = raw.decode('utf-8', 'replace') if it.get('kind', 'pchtxt') != 'ips' and not raw.startswith(b'IPS') else ''
            try:
                if text: _, secs = cpatch.parse_pchtxt(text); writes = [x for s in secs if s['enabled'] for x in s['writes']]
                else: writes = cpatch.parse_ips(raw)
            except Exception as e:   # 体检工具：一份读不了记下原因，不停
                writes = None; why = f'{type(e).__name__}'
            As = aspects(it, text); A = As[0] if As else None
            if writes is None: v, par, res, nconst = '读不了', [], [], 0
            elif A is None: v, par, res, nconst = '画幅不明', [], [], 0
            else:
                best = max(((classify(writes, B), B) for B in As), key=lambda x: len(x[0][0]) + 2 * len(x[0][1]))
                (par, res, nconst), A = best
                v = '参数化' if par or res else '认不出'
            verdict[v] += 1
            for gid in _list(it.get('gids')) or ['?']:
                for b in _list(it.get('bids')) or ['?']: combos[(gid.upper(), b.upper()[:16])][v] += 1
            rows.append([it.get('id', ''), ','.join(g.upper() for g in _list(it.get('gids'))), f'{A:.4f}' if A else '', v,
                         ' '.join(f'{o:#x}:{t}:{k}' for o, t, k in par), ' '.join(f'{o:#x}/{q:#x}={w}x{h}' for o, q, w, h in res), str(nconst)])
    total = sum(verdict.values())
    print(f'宽屏补丁 {total} 份：' + '、'.join(f'{k} {n}（{n * 100 // max(total, 1)}%）' for k, n in verdict.most_common()))
    cv = collections.Counter('有参数化' if c['参数化'] else '没有' for c in combos.values())
    print(f'（游戏, 版本）组合 {len(combos)} 个：至少一份能参数化 {cv["有参数化"]}，一份都不能 {cv["没有"]}')
    kinds = collections.Counter(t for r in rows for t in re.findall(r':(fmov|movpair|float):', r[4]))
    print('画幅值写法：' + '、'.join(f'{k} {n}' for k, n in kinds.most_common()) + f'；带渲染尺寸对的份数 {sum(1 for r in rows if r[5])}')
    if out:
        with open(out, 'w', encoding='utf-8') as f:
            f.write('编号\t程序号\t画幅\t结论\t画幅值（偏移:写法:式）\t渲染尺寸对\t定值字数\n')
            for r in rows: f.write('\t'.join(r) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
