#!/usr/bin/env python3
"""改写降级汇总（v0.3.1 起「有缺口降级继续」）：缺口按类别、兼容写法按处数，写产物根 degrade.rewrite.tsv
（出包作业收尾读它给玩家提示、诊断包收它）；没有降级就删掉旧表。
Mac / Linux 的 pack/stage_rewrite.sh 与 Windows 的 pack/orch/stages.py 共用这一份（#893：原先只在 shell 里内联，Windows 没搬，缺口直接整包失败）。
用法：rewrite_degrade.py <改写事务目录> <游戏号>；有降级时打一行【黄】，退出 0"""
import collections
import glob
import os
import re
import sys


def summarize(w, g):
    kinds = collections.Counter(); mods = collections.defaultdict(set); compat = 0
    for log in sorted(glob.glob(os.path.join(w, '*.rewrite.log'))):
        m = os.path.basename(log)[:-len('.rewrite.log')]
        for line in open(log, encoding='utf-8', errors='replace'):
            c = re.search(r"'x18_compat': (\d+)", line)
            if c: compat += int(c[1])
        gp = os.path.join(w, m + '.gaps.tsv')
        if os.path.isfile(gp):
            for line in open(gp, encoding='utf-8', errors='replace'):
                if line.startswith('#') or '\t' not in line: continue
                k = line.split('\t')[1]; kinds[k] += 1; mods[k].add(m)
    out = os.path.join(w, 'degrade.rewrite.tsv'); n = sum(kinds.values())
    if not n and not compat:
        if os.path.exists(out): os.remove(out)
        return None
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# 阶段\t类别\t处数\t玩家提示\t说明\n')
        if compat: f.write(f'rewrite\tx18_compat\t{compat}\t这款有 {compat} 处用了兼容写法，个别场景可能不稳定，遇到请反馈\t恢复 sp 后挑不出已死的临时寄存器，这几处退回压栈写法\n')
        if n: f.write(f'rewrite\tgap\t{n}\t这款有 {n} 处程序代码暂时没法改写、保持原样，玩到用到它们的地方可能出错，遇到请反馈\t缺口点保持原指令，逐条见 <模块>.gaps.tsv\n')
        for k, c in sorted(kinds.items()): f.write(f'rewrite\tgap:{k}\t{c}\t\t模块 {" ".join(sorted(mods[k]))}\n')
    parts = ([f'兼容写法 {compat} 处'] if compat else []) + ([f'没改写的缺口 {n} 处（{"、".join(f"{k} {c}" for k, c in sorted(kinds.items()))}）'] if n else [])
    return f'【黄】{g} 改写降级继续：{"；".join(parts)}（{out}）'


if __name__ == '__main__':
    line = summarize(*sys.argv[1:3])
    if line: print(line)
