#!/usr/bin/env python3
# 采样模拟变体的出包预编请求表（缺口族 31：任意边界色 / 非 Apple10 上的 min / max 归约，11-01 维护者定：出包只预编跑局见过的键，没见过的照旧首遇时设备上后台编）：
#   跑局记录 pso_user.tsv 里真绑过要模拟的采样器的键 → 配置档 se_want.tsv（dmsh_build.py se_finish 按它出 <键>_se.metallib 进库容器，种类 51；进链的输入表 dmsh_chain.py INPUT_TABLES）
#   C\t<键>\t<fc 十六进制>：计算着色器，fc & 2（SE_RD）非 0；R\t<pso_skey 十六进制>：渲染管线，skey 432 字节，片元键 = 第 24–47 字节（C 串，取前 16 位）、fc = 第 157 字节，& 2 非 0
# 用法：se_want.py <se_want.tsv（整份重写）> <union_keys.tsv（本次出库的并集键）> <来源…（pso_user.tsv 文件，或放 .tsv 的目录）>；只收本次并集里的键，来源不存在跳过。最后一行是汇总
#   出包（direct_lib.py）用 --keys <快照 se_want.tsv>：来源换成跑局知识快照（run_knowledge.py 已用本文件的 wants 推导好的键），只做按并集滤与写表
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_pairs import KEY, sources

SE_RD, SKEY_LEN, FS_KEY, FC = 2, 432, slice(24, 48), 157

def wants(lines):   # → 跑局记录里要变体的键（不管在不在本次并集）
    out = set()
    for ln in lines:
        c = ln.rstrip('\n').split('\t')
        try:
            if c[0] == 'C' and len(c) >= 3 and KEY.fullmatch(c[1]) and int(c[2], 16) & SE_RD: out.add(c[1])
            elif c[0] == 'R' and len(c) >= 2 and len(c[1]) == 2 * SKEY_LEN:
                b = bytes.fromhex(c[1]); k = b[FS_KEY].split(b'\0')[0][:16].decode('ascii', 'replace')
                if b[FC] & SE_RD and KEY.fullmatch(k): out.add(k)
        except ValueError: continue
    return out

def main(table, union, srcs):
    keys = {ln.strip() for ln in open(union) if ln.strip()}
    seen = set()
    if srcs[:1] == ['--keys']:   # 来源是跑局知识快照的 se_want.tsv（run_knowledge.py：已按 wants 推导、去重排序的键，一行一个）
        for f in srcs[1:]: seen |= {ln.strip() for ln in open(f) if KEY.fullmatch(ln.strip())}
    else:
        for f in sources(srcs): seen |= wants(open(f, errors='replace'))
    take = sorted(seen & keys)
    with open(table, 'w', newline='\n') as o:
        o.write('# 采样模拟变体出包预编的键（graphics/tools/direct/se_want.py，跑局 pso_user.tsv 里 fc & 2）\n'); o.writelines(k + '\n' for k in take)
    print(f'采样模拟变体请求：跑局见过 {len(seen)} 个键，本次出库里有 {len(take)} 个（预编 <键>_se）')

if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit('用法：se_want.py <se_want.tsv> <union_keys.tsv> <来源…>')
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
