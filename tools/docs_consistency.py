#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Read-only check that the collaboration policy in CONTRIBUTING matches the scripts.

Policy values come from train.sh / contrib_check.sh, never from a second table.
Use --render to print the block used in CONTRIBUTING.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
from pathlib import Path
import re
import sys

BEGIN = '<!-- S2ARM_POLICY:BEGIN -->'
END = '<!-- S2ARM_POLICY:END -->'
DOCUMENTS = ('CONTRIBUTING.md',)


class PolicyError(ValueError):
    pass


def train_source(repo):
    """Merge-train script is maintainer-side; S2A_PRIVATE_TOOLS points at it. None = public checkout."""
    if os.environ.get('S2A_PRIVATE_TOOLS'):
        return Path(os.environ['S2A_PRIVATE_TOOLS']) / 'train' / 'train.sh'   # 11-09 列车脚本收进 private-tools 库后的唯一真值（原根目录 train.sh 是旧副本，已删）
    local = repo / 'tools/train.sh'
    return local if local.exists() else None


def policy_block(train, contrib):
    # Parse static positive defaults only; changed source shapes require review.
    code = '\n'.join(line for line in train.splitlines() if not line.lstrip().startswith('#'))
    values = {}
    for name in ('TRAIN_BATCH_MAX', 'TRAIN_FULL_MAX', 'TRAIN_BISECT_MIN', 'TRAIN_PAR_DEPTH'):
        found = set(re.findall(r'\$\{' + name + r':-([^}]*)\}', code))
        if len(found) != 1 or any(not re.fullmatch(r'[1-9][0-9]*', value) for value in found):
            raise PolicyError(f'{name} 缺少唯一静态正整数缺省值')
        values[name] = next(iter(found))
    match = re.search(r'^seqchk\(\).*?(?=^halfland\(\))', code, re.M | re.S)
    seq = match[0] if match else ''
    if (not re.search(r'\[ \$# -gt "\$\{TRAIN_BISECT_MIN:-\d+\}" \]', seq)
            or not re.search(r'\[ "\$d" -lt "\$\{TRAIN_PAR_DEPTH:-\d+\}" \]', seq)
            or '( export S2A_TRAIN_PD=' not in seq or 'wait $pa $pb' not in seq
            or 'for e in "$@"' not in seq or 'halfland ' not in seq):
        raise PolicyError('seqchk 归责/分批形状已变，需重新核对文档语义')
    statuses = {int(a or b) for a, b in re.findall(r'\bexit[ \t]+(\d+)\b|\bEXIT=(\d+)\b', contrib)}
    meanings = {0: '第一层本机已证通过（待宿主/第二层仍单列）', 1: '有红',
                2: '不完整或参数/基线错误', 75: '环境未就绪', 130: '被中断'}
    if statuses != meanings.keys():
        raise PolicyError(f'自检退出码集合已变：{sorted(statuses)}')
    return '\n'.join((
        BEGIN,
        '以下内容由 `python3 tools/docs_consistency.py --render` 从实际脚本生成；修改后用同一工具核对。',
        f'- 批上限：快档 `TRAIN_BATCH_MAX` 缺省 {values["TRAIN_BATCH_MAX"]} 支；'
        f'full 档 `TRAIN_FULL_MAX` 缺省 {values["TRAIN_FULL_MAX"]} 支。',
        '- 红批归责：先按红行/红步定位并隔离相关支；无关支只继承输入未变的检查结论。'
        f'相关支多于 `TRAIN_BISECT_MIN`（缺省 {values["TRAIN_BISECT_MIN"]}）时，'
        '实际 `seqchk` 会对半分批，只核红步及两半共路由的步骤；'
        f'并行深度低于 `TRAIN_PAR_DEPTH`（缺省 {values["TRAIN_PAR_DEPTH"]}）时两半同时跑，'
        '到上限后先后跑；不满足分批条件时逐支核。路由不明则跑整份门禁。',
        '- 自检退出码：' + '；'.join(f'`{code}` {meanings[code]}' for code in sorted(statuses)) + '。',
        END,
    ))


def check(repo):
    problems = []
    train = train_source(repo)
    try:
        # Public checkout has no train script: markers are still checked, block content is checked by maintainers
        expected = None if train is None else policy_block(train.read_text(encoding='utf-8'),
                                (repo / 'tools/contrib_check.sh').read_text(encoding='utf-8'))
    except PolicyError as exc:
        problems.append(f'规则来源：{exc}')
        return problems
    for name in DOCUMENTS:
        if name == 'docs/协作循环.md' and not (repo / name).is_file():
            continue   # 内部开发流程文档不进公开快照
        text = (repo / name).read_text(encoding='utf-8')
        if text.count(BEGIN) != 1 or text.count(END) != 1:
            problems.append(f'{name}: 缺少唯一生成规则块')
        elif text.index(END) < text.index(BEGIN):
            problems.append(f'{name}: 规则块边界倒置')
        elif expected is not None and text[text.index(BEGIN):text.index(END) + len(END)] != expected:
            problems.append(f'{name}: 文档规则与脚本不一致（运行 --render）')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--render', action='store_true')
    args = parser.parse_args()
    try:
        if args.render:
            print(policy_block((train_source(args.repo) or args.repo / 'tools/train.sh').read_text(encoding='utf-8'),
                               (args.repo / 'tools/contrib_check.sh').read_text(encoding='utf-8')))
            return 0
        problems = check(args.repo)
    except (OSError, UnicodeError, PolicyError) as exc:
        print(f'文档检查未完成：{exc}', file=sys.stderr)
        return 2
    for problem in problems:
        print(problem)
    print(f'文档一致性：规则问题 {len(problems)} 处（{len(DOCUMENTS)} 份规则文档）')
    return 1 if problems else 0


if __name__ == '__main__':
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    raise SystemExit(main())
