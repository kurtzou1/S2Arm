#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Build every program of a multi-program collection and attach programs/<n>/."""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MAX_PROGRAMS = 16
SOURCE_EXTENSIONS = (".nsp", ".xci", ".nsz", ".xcz")
SKIP_DIRS = {"$RECYCLE.BIN", "System Volume Information"}


class BuildError(RuntimeError):
    pass


def _current_module():
    spec = importlib.util.spec_from_file_location(
        "_s2arm_multi_program_current", Path(__file__).with_name("orch") / "current.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def current_root(roots, game):
    return _current_module().read(Path(roots), game)


def unpack_rows(extract):
    path = Path(extract) / "unpack.tsv"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise BuildError(f"读不出解包清单 {path}：{error}") from error
    rows = {}
    for line in lines:
        if "\t" in line:
            key, value = line.split("\t", 1)
            rows[key] = value
    return rows


def programs_of(extract):
    raw = unpack_rows(extract).get("programs")
    if raw is None:
        return 1
    try:
        count = int(raw)
    except ValueError as error:
        raise BuildError(f"解包清单的 programs 不是整数：{raw!r}") from error
    if not 1 <= count <= MAX_PROGRAMS:
        raise BuildError(f"解包清单的 programs 超出 1..{MAX_PROGRAMS}：{count}")
    return count


def title_of(extract):
    title = unpack_rows(extract).get("title_id", "").upper()
    if not re.fullmatch(r"[0-9A-F]{16}", title):
        raise BuildError(f"解包清单没有合法的 16 位 title_id：{title!r}")
    return title


def source_files(source):
    source = Path(source)
    if not source.is_dir():
        return []
    found = []
    for parent, dirs, names in os.walk(source, followlinks=True):
        depth = len(Path(parent).relative_to(source).parts)
        dirs[:] = (
            sorted(d for d in dirs if not d.startswith(".") and d not in SKIP_DIRS)
            if depth < 4
            else []
        )
        for name in names:
            path = Path(parent) / name
            if (
                path.suffix.lower() in SOURCE_EXTENSIONS
                and path.is_file()
                and not name.startswith("._")
            ):
                found.append(path.absolute())
    return sorted(found, key=os.fsencode)


def _tail(log):
    try:
        lines = Path(log).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return "无日志"
    return next((line for line in reversed(lines) if line.strip()), "空日志")


def run_logged(command, log, env, label):
    log = Path(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as output:
        result = subprocess.run(
            [str(arg) for arg in command], stdout=output, stderr=subprocess.STDOUT, env=env
        )
    if result.returncode:
        raise BuildError(f"{label}失败（退出 {result.returncode}）：{_tail(log)}（{log}）")
    return result


def _root_function(repo, function, game, tag, env, log):
    roots = repo / "pack/roots.sh"
    command = [
        "bash",
        "-c",
        'source "$1"; ' + function + ' "$2" "$3"',
        "s2arm-roots",
        str(roots),
        game,
        tag,
    ]
    run_logged(command, log, env, function)
    lines = [line for line in _tail(log).splitlines() if line.strip()]
    return lines[-1] if lines else ""


def _remove(path):
    path = Path(path)
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


def attach_programs(roots, game, programs, env, repo, log):
    roots, log = Path(roots), Path(log)
    tag_log = log.with_name(log.stem + ".tag" + log.suffix)
    begin_log = log.with_name(log.stem + ".begin" + log.suffix)
    commit_log = log.with_name(log.stem + ".commit" + log.suffix)
    abort_log = log.with_name(log.stem + ".abort" + log.suffix)
    tag = _root_function(repo, "root_tag", game, "multi", env, tag_log)
    work = Path(_root_function(repo, "root_begin", game, tag, env, begin_log))
    if (
        work.name != f"{game}@{tag}.tmp"
        or work.parent != roots
        or not work.is_dir()
        or work.is_symlink()
    ):
        raise BuildError(f"多程序合集拿不到合法的产物根事务目录：{work}")
    try:
        old = work / "programs"
        if old.exists() or old.is_symlink():
            run_logged(
                [
                    "bash",
                    "-c",
                    'source "$1"; _root_rm "$2"',
                    "s2arm-roots",
                    str(repo / "pack/roots.sh"),
                    str(old),
                ],
                log,
                env,
                "清理旧子程序目录",
            )
        for index, source in programs:
            destination = work / "programs" / str(index)
            destination.parent.mkdir(parents=True, exist_ok=True)
            child_log = log.with_name(log.stem + f"_p{index}" + log.suffix)
            run_logged(
                [sys.executable, repo / "tools/clonedir.py", source, destination],
                child_log,
                env,
                f"物化子程序序号 {index}",
            )
            if not (destination / "main.npdm").is_file():
                raise BuildError(f"子程序序号 {index} 物化后缺 main.npdm：{destination}")
            romfs = destination / "romfs"
            if romfs.is_symlink() or not (
                romfs.is_dir()
                or (destination / "romfs.std").is_file()
                or (destination / "game.img").is_file()
            ):
                raise BuildError(
                    f"子程序序号 {index} 的 RomFS 没有物化成独立目录或镜像：{destination}"
                )
        run_logged(
            [
                "bash",
                "-c",
                'source "$1"; root_commit "$2" "$3"',
                "s2arm-roots",
                str(repo / "pack/roots.sh"),
                game,
                tag,
            ],
            commit_log,
            env,
            "提交多程序合集产物根",
        )
    except BaseException as error:
        try:
            run_logged(
                [
                    "bash",
                    "-c",
                    'source "$1"; root_abort "$2" "$3"',
                    "s2arm-roots",
                    str(repo / "pack/roots.sh"),
                    game,
                    tag,
                ],
                abort_log,
                env,
                "回滚多程序合集产物根",
            )
        except BuildError as rollback:
            raise BuildError(f"{error}；回滚多程序合集产物根也失败：{rollback}") from error
        raise
    final = current_root(roots, game)
    if final is None:
        raise BuildError(f"多程序合集提交后没有现行产物根：{game}")
    return final


def build(*, extract, work, logs, product, game, source_dir, platform, env=None, repo=None):
    extract, work, logs, product = map(Path, (extract, work, logs, product))
    repo = Path(repo or Path(__file__).resolve().parents[1])
    env = dict(os.environ if env is None else env)
    count = programs_of(extract)
    if count <= 1:
        return product
    sources = source_files(source_dir)
    if not sources:
        raise BuildError(
            f"多程序合集（{count} 支）：--from-extract 只给了序号 0 的解包目录，其余序号要从原件解，原件没一起给"
        )
    roots = Path(env.get("S2A_ROOTS") or "").resolve()
    if not roots.is_dir():
        raise BuildError(f"S2A_ROOTS 不存在：{roots}")
    nxu = Path(env.get("S2A_NX_UNPACK") or "")
    keys = Path(env.get("S2A_KEYS") or "")
    if not nxu.is_file():
        raise BuildError(f"多程序合集解包要 S2A_NX_UNPACK 指向可执行读取器：{nxu}")
    if not keys.is_file():
        raise BuildError(f"多程序合集解包要 S2A_KEYS 指向 prod.keys：{keys}")
    main_title = title_of(extract)
    child_env = dict(
        env,
        S2A_ROOTS=str(roots),
        S2A_GAME_SRC=str(source_dir),
        S2A_SEED_AOC="1",
        S2A_PACK_PLAT=platform,
        S2A_WIDEN_PKG="0",
        S2A_WIDEN_AUTO_RUN="0",
    )
    built = []
    for index in range(1, count):
        child_extract = work / f"extract_p{index}"
        temporary = work / f"extract_p{index}.tmp"
        _remove(temporary)
        _remove(child_extract)
        run_logged(
            [
                nxu,
                keys,
                temporary,
                "--aoc-index",
                f"--title-id={main_title}",
                f"--program-index={index}",
                *sources,
            ],
            logs / f"unpack_p{index}.log",
            child_env,
            f"解包子程序序号 {index}",
        )
        os.replace(temporary, child_extract)
        rows = unpack_rows(child_extract)
        try:
            child_index = int(rows.get("program_index", ""))
        except ValueError as error:
            raise BuildError(f"子程序序号 {index} 的 unpack.tsv 缺 program_index") from error
        child_title = title_of(child_extract)
        expected = f"{int(main_title, 16) + index:016X}"
        if child_index != index or child_title != expected or programs_of(child_extract) != count:
            raise BuildError(
                f"子程序序号 {index} 身份不符：program_index={child_index}，title_id={child_title}，期望 {expected}"
            )
        run_logged(
            [sys.executable, repo / "pack/direct_profile_input.py", child_extract],
            logs / f"direct_profile_p{index}.log",
            child_env,
            f"子程序序号 {index} 版本旁注",
        )
        child_game = "t" + child_title.lower()
        tag = _root_function(
            repo, "root_tag", child_game, f"sub{index}", child_env, logs / f"seed_p{index}.log"
        )
        run_logged(
            ["bash", repo / "pack/seed_root.sh", child_game, tag, child_extract],
            logs / f"seed_p{index}.log",
            child_env,
            f"播种子程序序号 {index}",
        )
        run_logged(
            ["bash", repo / "pack/refresh.sh", child_game],
            logs / f"refresh_p{index}.log",
            child_env,
            f"刷新子程序序号 {index}",
        )
        child_root = current_root(roots, child_game)
        if child_root is None or not (child_root / "main.npdm").is_file():
            raise BuildError(f"子程序序号 {index} 刷新后缺现行产物根或 main.npdm")
        built.append((index, child_root))
        print(f"🟢 多程序合集序号 {index}（{child_title}）→ {child_root}", flush=True)
    final = attach_programs(roots, game, built, child_env, repo, logs / "attach.log")
    print(f"🟢 多程序合集已组装 {count} 支 → {final}", flush=True)
    return final


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extract", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--logs", required=True, type=Path)
    parser.add_argument("--product", required=True, type=Path)
    parser.add_argument("--game", required=True)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--platform", required=True, choices=("macos", "ios"))
    args = parser.parse_args(argv)
    try:
        build(
            extract=args.extract,
            work=args.work,
            logs=args.logs,
            product=args.product,
            game=args.game,
            source_dir=args.source_dir,
            platform=args.platform,
        )
    except (BuildError, OSError, ValueError) as error:
        print(f"【红】{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
