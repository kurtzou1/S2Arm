#!/usr/bin/env python3
# 跑局里见到、出包没配上的「顶点 + 片元」对 → 配置档的配对表（direct_lib.py ③ 之后、④ 翻译之前）：宿主建管线前发现片元读了顶点没写的 user(locn)（nvn_mtl.m pso_pair_ok），
#   那笔不画、往 pso_user.tsv 记一行「P<TAB>顶点键<TAB>片元键」；这里把这些行并进 shader_pairs.tsv，dmsh_build.py vs_pad 就给那个顶点着色器补上片元要读的输出，
#   值 (0,0,0,1)，同硬件上没写的输出读到的。巫师3 10-26：配对表 158 对、着色器 29672 个，跑局里 4 对没配上，iOS 上建这种管线 Metal 断言崩溃。
# 用法：run_pairs.py <shader_pairs.tsv（就地追加）> <union_keys.tsv（本次出库的并集键）> <来源…（pso_user.tsv 文件，或放 .tsv 的目录）>
# 只收两个键都在本次并集里的行（别的版本 / 别的款的行滤掉），已有的不重复；来源不存在跳过。最后一行是汇总
import os, re, sys

KEY = re.compile(r'[0-9a-f]{16}')

def sources(paths):
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.endswith('.tsv'): yield os.path.join(p, f)
        elif os.path.isfile(p): yield p

def main(pairs, union, srcs):
    have = set()
    for ln in open(pairs):
        if ln.strip() and not ln.startswith('#'): have.add(tuple(ln.split()[:2]))
    keys = {ln.strip() for ln in open(union) if ln.strip()}
    add, seen, outside = [], 0, 0
    for f in sources(srcs):
        for ln in open(f, errors='replace'):
            c = ln.rstrip('\n').split('\t')
            if len(c) < 3 or c[0] != 'P' or not KEY.fullmatch(c[1]) or not KEY.fullmatch(c[2]): continue
            seen += 1
            if c[1] not in keys or c[2] not in keys: outside += 1; continue
            if (c[1], c[2]) in have: continue
            have.add((c[1], c[2])); add.append(f'{c[1]}\t{c[2]}\n')
    if add:
        with open(pairs, 'a', newline='\n') as o: o.writelines(add)
    print(f'跑局配对：P 行 {seen}，不在本次并集 {outside}，新并入配对表 {len(add)}')

if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit('用法：run_pairs.py <shader_pairs.tsv> <union_keys.tsv> <来源…>')
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
