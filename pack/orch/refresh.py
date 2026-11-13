# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""python -m pack.orch.refresh <game> --from-extract DIR --stages rewrite,romfsidx,direct_profile"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import sys
import time

from .roots import Conflict, Roots, UnsafeRoot, cleanup_after, copy_file, directory_link, is_link, plain_entries, remove_owned, remove_patterns, rename_dir, text
from .stages import ENTRY, LIGHT_ORDER, REWRITE_OUTPUTS, StageError, Stages


def _ticker(stage, total):
    """tools/progress.py 的 Ticker（同一份进度协议写端）；按文件路径载入，不改 sys.path"""
    import importlib.util
    spec = importlib.util.spec_from_file_location('_s2a_progress', Path(__file__).resolve().parents[2] / 'tools' / 'progress.py')
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod.Ticker(stage, total)


def seed(roots, game, source, *, move_romfs=False):
    source = Path(source).resolve(strict=True)
    if not (source / 'exefs').is_dir():
        raise StageError('播种源缺 exefs/')
    # Top-level inputs may resolve to real directories, but their contents
    # cannot contain links. Validate before beginning a transaction.
    names = ['exefs', 'romfs', 'systemdata', 'upd', 'rt_shaders']   # 同 pack/seed_root.sh SEED_DIRS：rt_shaders = 真机转储的着色器（<键>.ctl / .code），直连阶段并进库（11-06 Switch2 线 75：原先漏了，Windows 播种丢转储）
    if os.environ.get('S2A_SEED_AOC') == '1':
        names.append('aoc')
    files = 0
    for name in names:
        p = source / name
        if p.is_dir():
            files += sum(1 for e in plain_entries(p.resolve()) if not e.is_dir())
    # 播种的进度（#361：Switch 2 大款 20.6 万个文件逐个拷了约 30 分钟，进度条一直停在「解包 100%」像卡死）：每拷完一个文件计一次，
    #   按出包进度协议写「播种 已拷 / 总数」（tools/progress.py，每秒最多一行；没给 S2A_PROGRESS 不写）；整目录改名搬进来的 RomFS 一次计满
    tick = _ticker('播种', files)
    # 不独占 RomFS 开工：下面先 remove_owned 再放新的（死机重起续接的前提，Windows 端到端线 11-06），独占克隆来的整份 RomFS 立刻就被删掉，白拷白删
    tx = roots.begin(game, roots.tag(game, 'seed-' + str(time.time_ns())))
    moved = None
    try:
        w = tx.path
        for name in names:
            if (source / name).is_dir():
                remove_owned(w / name)
                src = source / name
                # move_romfs（只给一键出包自己的解包目录，下次解包整目录重建）：同卷就把 RomFS 整目录改名搬进来（一次操作），不逐文件克隆
                #   （11-06 出包速度线：0100F2C0115B6000 30.5 万个文件，Windows 出包机播种 1253 秒，逐文件克隆约 1 毫秒一个）；提交后原处留联接指向存储里的这份
                # 实目录模式（exFAT 等建不了链接）不搬：搬走后原处没法留联接回指，界面布局等后续阶段要读原处
                if name == 'romfs' and move_romfs and not roots.plain and not is_link(src) and os.stat(src).st_dev == os.stat(w).st_dev:
                    rename_dir(src, w / 'romfs'); moved = src
                    tick.step(sum(1 for e in plain_entries(w / 'romfs') if not e.is_dir()))
                else:
                    # RomFS 不可变：Windows NTFS 同卷建硬链接代替逐文件实拷（#291，copy_file link_ok）；别的目录（exefs 等产物要可写）照旧
                    roots._copy_tree(src.resolve(), w / name, tick=tick.step, link_ok=name == 'romfs')
        remove_patterns(w, (*REWRITE_OUTPUTS, '.stage_uilayout', '.stage_romfsidx', '.stage_romfsidx.deps',
                            '.stage_pkg', 'ui_overlay.tsv', 'romfs.s2aidx', 'unpack.tsv'))
        extras = ['unpack.tsv', 'icon.jpg', 'ctl/control.nacp']
        extras.append('direct-profile-input.json')
        (w / 'direct-profile-input.json').unlink(missing_ok=True)
        (w / '.stage_direct_profile').unlink(missing_ok=True)
        if os.environ.get('S2A_SEED_AOC') == '1':
            extras.append('aoc.tsv')
            for name in ('aoc.tsv', 'aoc.log', '.stage_aoc'):
                (w / name).unlink(missing_ok=True)
        for name in extras:
            if (source / name).is_file():
                if is_link(source / name):
                    raise UnsafeRoot('播种元数据不能是链接')
                # 事务从现行版本克隆来，上次播种的 icon.jpg / ctl/control.nacp 还在；copy_file 目标已在就报错（ReFS CopyFile2 0x80070050、clonefile EEXIST），
                #   同一工作目录二次播种必红（11-06 Windows 出包机死机后原样重起的 3 单全红在这里）：先删旧的再复制
                remove_owned(w / name)
                copy_file(source / name, w / name)
        text(w / 'seed.txt', f'src={source}\ntag={tx.tag}\nat={datetime.now():%Y-%m-%d %H:%M:%S}\n')
        final = tx.commit()
        if moved is not None:   # 原处（seed.txt 记的 src/romfs，界面布局读原版）联到存储里这份不可变的身份
            directory_link(roots._romfs(final, game), moved)
        return final
    except BaseException as e:
        cleanup_after(e, tx.abort)   # 删半成品再出错（#669 WinError 145）不许盖住起因
        raise


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game')
    parser.add_argument('--stages', default='rewrite,romfsidx,direct_profile',
                        help='ordered subset; empty string permits seed-only')
    parser.add_argument('--roots', type=Path)
    parser.add_argument('--from-extract', type=Path)
    parser.add_argument('--move-romfs', action='store_true', help='解包目录是本单自己的（下次解包整目录重建）：同卷时 RomFS 整目录搬进产物根，原处留联接')
    args = parser.parse_args(argv)
    names = [s for s in args.stages.split(',') if s]
    if names == ['all-light']:
        names = list(LIGHT_ORDER)
    if len(set(names)) != len(names) or any(s not in ENTRY for s in names):
        parser.error('阶段必须为不重复的已知名称，或单独的 all-light')
    if names != sorted(names, key=LIGHT_ORDER.index):
        parser.error('阶段顺序必须为 ' + ' → '.join(LIGHT_ORDER))
    try:
        roots = Roots(args.roots)
        if args.from_extract:
            current = seed(roots, args.game, args.from_extract, move_romfs=args.move_romfs)
            print(f'🟢 {args.game} 播种，现行 → {current.name}')
        engine = Stages(roots)
        for stage in names:
            result = engine.execute(args.game, stage)
            print(f'🟢 {stage} {result["seconds"]:.6f}秒；现行 → {result["version"]}；键={result["key"]}；跳过={result["skipped"]}')
        return 0
    except StageError as error:
        print(('【黄】' if error.code in (3, 75) else '【红】') + str(error), file=sys.stderr)
        return error.code
    except (OSError, ValueError, Conflict) as error:
        if isinstance(error, (OSError, ValueError)):   # 系统调用层的错误只带系统消息（11-05 Windows 出包机无人深空「[WinError 31] 连到系统上的设备没有发挥作用」原样重跑不复现、定不了是哪一处）：调用栈一并写进日志
            import traceback
            print(''.join('  ' + l for l in traceback.format_exception(error)[-12:]), file=sys.stderr, end='')
        # 红字放最后：出包摘要取日志最后几行（pack/orch/oneclick_win.py sh），原先最后几行是调用栈末帧（winlong 包装层），起因和附注都看不见（#669）
        print('【红】编排中止：' + ' '.join([str(error), *getattr(error, '__notes__', ())]), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
