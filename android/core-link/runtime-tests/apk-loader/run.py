#!/usr/bin/env python3
"""macOS ARM64 authored APK-memory loader fixtures, not Android/guest execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import subprocess

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
HOST_ANDROID_COMPAT = HERE / "host_android_compat.h"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "clang"))
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in ("arm64", "aarch64"):
        parser.error("this fixture requires macOS ARM64 and actual Apple TSD; it is not Bionic")
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("--out must be outside the source checkout")
    out.mkdir(parents=True, exist_ok=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    sources = [ROOT / "runtime/src/loader.c", ROOT / "android/native/module.c",
               ROOT / "runtime/src/gate.c", ROOT / "runtime/src/widen.c", ROOT / "runtime/src/cpatch.c", HERE / "loader_mem_test.c", ROOT / "runtime/src/nrodefer.c", ROOT / "platform/apple/plat_apple.c"]
    inputs = sources + [ROOT / "runtime/src/native.h", ROOT / "runtime/src/loader.h",
                        ROOT / "runtime/include/s2a_native.h", ROOT / "platform/plat.h",
                        ROOT / "android/native/module.h", HOST_ANDROID_COMPAT,
                        Path(__file__).resolve()]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    records = []

    def run(command, name, expected=0):
        result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=30)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        records.append({"name": name, "command": list(map(str, command)),
                        "exit": result.returncode, "expected_exit": expected})
        (out / "results.json").write_text(json.dumps({"source": hashes, "records": records,
            "scope": "authored bytes, actual mapper/loader/relocations, Apple TSD; no Android/guest execution"}, indent=2) + "\n")
        if result.returncode != expected:
            raise RuntimeError(f"{name}: got {result.returncode}, expected {expected}; see {out / (name + '.log')}")
        return result.stdout + result.stderr

    flags = [args.cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
             "-DS2A_UNIT_TEST", "-ffunction-sections", "-fdata-sections",
             "-I" + str(ROOT), "-I" + str(ROOT / "runtime/src"), "-I" + str(ROOT / "runtime/include")]
    objects = []
    for index, source in enumerate(sources):
        obj = out / (str(index) + ".o")
        # Only the platform adapter uses the real Apple branch; everything under
        # test is the Android APK-memory loader branch and authored endpoints.
        defines = [] if source == sources[-1] else ["-D__ANDROID__"]
        # loader.c runs as the Android branch on macOS, where __APPLE__ is also
        # defined: its Apple-only session reset touches the desktop window
        # cursor, which the Android branch does not declare, and the Apple boot
        # helpers are unused on this path. The compat header supplies the two
        # inert fixture symbols; only the unused-function warning is relaxed
        # for this hybrid translation unit.
        if source.name == "loader.c":
            defines += ["-include", str(HOST_ANDROID_COMPAT), "-Wno-unused-function"]
        run(flags + defines + ["-c", source, "-o", obj], "compile-" + str(index))
        objects.append(obj)
    binary = out / "loader-memory"
    run([args.cc, *objects, "-Wl,-dead_strip", "-pthread", "-o", binary], "link")
    passing = ("widen", "widen-policy", "cpatch", "valid", "missing", "weak", "empty-gates", "zero-bias")
    rejected = ("cpatch-rejected", "cpatch-nul", "widen-overlap", "widen-malformed", "widen-rejected", "nonzero-bias", "apple", "wrong", "missing-abi", "bad-abi", "duplicate-abi", "bad-gates",
                "outside-gate", "trailing-gate", "missing-sidecar", "hash-rejected", "nul-fixups",
                "long-fixups", "duplicate-name", "load-twice", "duplicate-gate")
    for name in passing + rejected:
        log = run([binary, name], name, 0 if name in passing else -6)
        if name in passing:
            assert "PASS actual memory-only loader" in log
        else:
            assert "FATAL" in log, (name, "must reject at actual production admission")
    assert hashes == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    print("PASS 25 authored APK-memory loader cases; no Android/guest execution")


if __name__ == "__main__":
    main()
