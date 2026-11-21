#!/usr/bin/env python3
"""Run the full packaging rewrite stage (C rewriter) on private snapshots; keep hashes, timings and evidence local.

10-31 删 Python 改写器后不再做 Python / C 两后端对照：--baseline 给一份先前的 report.json（例如删前两后端一致时留的），
逐款比全部改写产物 SHA-256，作为真实输入上的金样。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SUFFIXES = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def clone(source, destination):
    subprocess.run([sys.executable, str(ROOT / "tools/clonedir.py"), str(source), str(destination)],
                   check=True, stdout=subprocess.DEVNULL)


def compare(name, source, directory, env, baseline=None):
    # Freeze the input once, so the stage sees a fixed ExeFS/RomFS.
    snapshot = directory / "input"
    clone(source, snapshot)
    # Same module set as pack/stage_rewrite.sh (the host loads main, subsdk0-9 and sdk; other ExeFS files such as main.moduleconfig are not NSOs).
    modules = sorted(p.name for p in (snapshot / "exefs").iterdir()
                     if p.is_file() and re.fullmatch(r"main|sdk|subsdk[0-9]", p.name))
    result = dict(input_sha256={m: digest(snapshot / "exefs" / m) for m in modules}, runs={})
    for mode in ("c",):
        run = directory / mode
        initial = run / "roots" / (name + "@input")
        initial.parent.mkdir(parents=True)
        clone(snapshot, initial)
        (initial / ".stage_rewrite").unlink(missing_ok=True)
        current = initial.parent / (name + "@现行")
        current.write_text(initial.name + "\n")   # 现行指针文件（pack/orch/current.py）：内容 = 版本目录名
        start = time.perf_counter()
        with (run / "stdout.log").open("w") as stdout, (run / "stderr.log").open("w") as stderr:
            # The production stage already bounds each module to 600 seconds.
            process = subprocess.run(["bash", str(ROOT / "pack/stage_rewrite.sh"), name],
                                     env=dict(env, S2A_ROOTS=str(initial.parent),
                                              S2A_ROOTS_SHARED=str(directory / "no-shared"),
                                              S2A_ROOTS_NO_BOOT="1"), stdout=stdout, stderr=stderr)
            rc = process.returncode
        elapsed = time.perf_counter() - start
        outputs = current.parent / current.read_text().strip()
        artifacts = {p.name: digest(p) for p in sorted(outputs.iterdir())
                     if p.is_file() and any(p.name.endswith("." + suffix) for suffix in SUFFIXES)}
        result["runs"][mode] = dict(returncode=rc, elapsed_seconds=elapsed, artifacts=artifacts)
        if rc:
            result["passed"] = False
            return result
        required = {m + "." + suffix for m in modules for suffix in SUFFIXES[:5]}
        if not required <= artifacts.keys():
            raise RuntimeError("改写阶段缺少必需产物")
    result["passed"] = baseline is None or result["runs"]["c"]["artifacts"] == baseline
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new private evidence directory")
    parser.add_argument("--baseline", type=Path, help="earlier report.json; every case must match its artifact SHA-256")
    parser.add_argument("inputs", nargs="+", help="game=existing prepared root (not NSO)")
    args = parser.parse_args()
    cases = []
    for item in args.inputs:
        name, separator, path = item.partition("=")
        source = Path(path).resolve()
        if not separator or not re.fullmatch(r"[A-Za-z0-9_-]+", name) or not (source / "exefs/main").is_file():
            parser.error("输入须为 款名=现行产物根，且根里有 exefs/main")
        if name in {n for n, _ in cases}:
            parser.error("款名重复")
        if args.output.resolve().is_relative_to(source):
            parser.error("输出目录不能放在输入根内部")
        cases.append((name, source))
    base = {}
    if args.baseline:
        for case_name, case in json.loads(args.baseline.read_text())["cases"].items():
            base[case_name] = case["runs"]["c"]["artifacts"]
        missing = [n for n, _ in cases if n not in base]
        if missing:
            parser.error("基线报告里没有这些款：" + " ".join(missing))
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    env = dict(os.environ, S2A_PY=sys.executable, S2A_PYTHON=sys.executable)
    for name in ("S2A_ROOT_CUR", "S2A_STAGE_KEYS"):
        env.pop(name, None)
    # Exclude the one-time C build from stage timings, and record it separately.
    start = time.perf_counter()
    binary = subprocess.check_output([sys.executable, str(ROOT / "pack/rewriter.py"), "c-path"],
                                     env=env, text=True).strip().splitlines()[-1]
    report = dict(schema=1, c_prepare_seconds=time.perf_counter() - start,
                  c_sha256=digest(Path(binary)), target=env.get("S2A_TARGET", "apple"),
                  spin=env.get("S2A_REWRITE_SPIN", "1"),
                  sdk_addr_cut=env.get("S2A_SDK_ADDR_CUT", "1"),
                  baseline_sha256=digest(args.baseline) if args.baseline else None, cases={})
    try:
        for name, source in cases:
            directory = args.output / name
            directory.mkdir()
            result = compare(name, source, directory, env, base.get(name))
            report["cases"][name] = result
            ok = "：全部改写产物 SHA-256 与基线相同" if args.baseline else "：改写阶段完成（未给基线，只记 SHA-256 与耗时）"
            print(name + (ok if result["passed"] else "：失败，检查私有报告"))
            for mode, run in result["runs"].items():
                print(f"  {mode}: rc={run['returncode']} stage={run['elapsed_seconds']:.3f}s artifacts={len(run['artifacts'])}")
    finally:
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(case["passed"] for case in report["cases"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
