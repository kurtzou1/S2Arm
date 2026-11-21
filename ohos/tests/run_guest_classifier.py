#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁手动：要鸿蒙官方 native SDK（--ndk）编鸿蒙可执行文件，产物要上鸿蒙设备跑；单跑：python3 ohos/tests/run_guest_classifier.py --ndk <OpenHarmony native SDK> --out <新目录>
"""Build a real OHOS dlopen/classifier regression, without using a device.

Usage: python run_guest_classifier.py --ndk <official-native-SDK> --out <new-dir>
Only the Python standard library and installed OHOS SDK are required. Output
contains fixed and old-classifier executables plus a synthetic DSO. On an OHOS
device, run each executable with the absolute path to that DSO. The fixed test
must return 0 and print its final PASS; the old test must return 1 with exactly
"FAIL registered text is guest". Neither execution is claimed by this builder.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
TESTS = Path("ohos/tests")
ELF_HOST = Path("android/native/runtime/fault/elf_host.c")
INPUTS = [
    Path("native/src/xstack.c"),
    Path("native/src/loader.c"),
    Path("native/src/native.h"),
    Path("native/src/loader.h"),
    Path("native/include/s2a_native.h"),
    Path("platforms/plat.h"),
    Path("android/native/module.h"),
    ELF_HOST,
    TESTS / "test_guest_classifier.c",
    TESTS / "guest_classifier_fixture.S",
    TESTS / "run_guest_classifier.py",
]
GUARD = "    if (module_of((const void *)(uintptr_t)address)) return 0;"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ndk", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("output must be outside the checkout")
    if out.exists():
        parser.error("output already exists; choose a fresh evidence directory")
    ndk = args.ndk.resolve()
    suffix = ".exe" if os.name == "nt" else ""
    cc = ndk / "llvm/bin" / ("clang" + suffix)
    readelf = ndk / "llvm/bin" / ("llvm-readelf" + suffix)
    for tool in (cc, readelf):
        if not tool.is_file():
            parser.error("missing installed tool: " + str(tool))
    out.mkdir(parents=True)
    before = {str(p): sha(ROOT / p) for p in INPUTS}
    receipt = {
        "kind": "OHOS guest classifier regression build",
        "source_sha256": before,
        "tools_sha256": {str(p): sha(p) for p in (cc, readelf)},
        "commands": [], "checks": {}, "artifacts": {},
        "device_executed": False, "behavior_pass": None,
        "scope": "actual xstack.c, loader.c module_of and ELF phdr scan; unrelated sections discarded; no runtime providers",
    }

    def save():
        (out / "manifest.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

    def check(name, good):
        receipt["checks"][name] = bool(good)
        save()
        if not good:
            raise RuntimeError(name)

    def run(argv, label, stdin=None):
        values = [str(v) for v in argv]
        result = subprocess.run(values, input=stdin, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                encoding="utf-8", errors="replace", timeout=60)
        log = label + ".log"
        (out / log).write_text(result.stdout, encoding="utf-8")
        receipt["commands"].append({"argv": values, "exit": result.returncode, "log": log})
        save()
        if result.returncode:
            raise RuntimeError(label + " failed; see " + log)
        return result.stdout

    def snapshot(directory):
        for path in INPUTS:
            target = directory / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)

    try:
        snapshot(out / "source")
        target = [cc, "--target=aarch64-linux-ohos", "--sysroot=" + str(ndk / "sysroot"), "-D__MUSL__"]
        run([cc, "--version"], "compiler")
        macros = run(target + ["-dM", "-E", "-x", "c", "-"], "platform-macros", "")
        check("real_ohos_not_android", "#define __OHOS__" in macros and "#define __ANDROID__" not in macros)
        common = ["-D_GNU_SOURCE", "-DS2A_UNIT_TEST", "-std=gnu11", "-O2",
                  "-ffunction-sections", "-fdata-sections", "-fPIE", "-Wall", "-Wextra",
                  "-Werror=implicit-function-declaration", "-Werror=incompatible-pointer-types"]
        source = out / "source"
        include = ["-I" + str(source / "native/src"), "-I" + str(source / "native/include")]
        objects = []
        for number, path in enumerate((Path("native/src/loader.c"), ELF_HOST, TESTS / "test_guest_classifier.c")):
            obj = out / ("common-" + str(number) + ".o")
            run(target + common + include + ["-c", source / path, "-o", obj], "compile-common-" + str(number))
            objects.append(obj)
        link = ["-pie", "-pthread", "-Wl,--gc-sections,--no-undefined,-z,noexecstack,-z,max-page-size=16384"]
        for variant in ("fixed", "old"):
            variant_root = source
            if variant == "old":
                variant_root = out / "old-source"
                snapshot(variant_root)
                old = variant_root / "native/src/xstack.c"
                content = old.read_text(encoding="utf-8")
                check("one_guest_guard_removed_only_in_private_negative", content.count(GUARD) == 1)
                old.write_text(content.replace(GUARD, "    /* Regression counterexample: omit registered-guest exclusion. */"), encoding="utf-8")
                receipt["old_classifier_sha256"] = sha(old)
            obj = out / (variant + "-xstack.o")
            run(target + common + include + ["-c", variant_root / "native/src/xstack.c", "-o", obj], "compile-" + variant)
            binary = out / ("guest-classifier-" + variant)
            run(target + link + [obj] + objects + ["-ldl", "-o", binary], "link-" + variant)
            symbols = run([readelf, "--symbols", "--wide", binary], "symbols-" + variant)
            for name in ("module_of", "sw_is_host_code", "s2a_android_is_host_code"):
                check(variant + "_real_" + name, re.search(r"\bFUNC\b[^\n]*\s(?!UND\b)\S+\s+" + name + r"$", symbols, re.M) is not None)
            receipt["artifacts"][binary.name] = {"sha256": sha(binary), "bytes": binary.stat().st_size}
            run([readelf, "--program-headers", "--wide", binary], "segments-" + variant)
        fixture = out / "libclassifier_fixture.so"
        fixture_object = out / "fixture.o"
        # This fixture has no C preprocessor input. Keeping both outputs explicit
        # also avoids compiler-created .s files in Windows sandbox temp folders.
        run(target + ["-x", "assembler", "-c", source / TESTS / "guest_classifier_fixture.S",
                      "-o", fixture_object], "compile-fixture")
        run(target + ["-nostdlib", "-shared", "-Wl,--no-undefined,-z,noexecstack,-z,max-page-size=16384,-soname,libclassifier_fixture.so",
                      fixture_object, "-o", fixture], "link-fixture")
        run([readelf, "--program-headers", "--wide", fixture], "segments-fixture")
        receipt["artifacts"][fixture.name] = {"sha256": sha(fixture), "bytes": fixture.stat().st_size}
        check("source_unchanged", before == {str(p): sha(ROOT / p) for p in INPUTS})
        receipt["build_pass"] = True
        receipt["device_commands"] = [
            {"argv": ["<device-dir>/guest-classifier-fixed", "<device-dir>/libclassifier_fixture.so"],
             "expected_exit": 0, "required_output": "PASS guest classifier: 25 checks; actual xstack + module_of + dlopen ELF"},
            {"argv": ["<device-dir>/guest-classifier-old", "<device-dir>/libclassifier_fixture.so"],
             "expected_exit": 1, "required_output": "FAIL registered text is guest"},
        ]
        save()
        print("BUILT fixed and negative OHOS regressions; device execution pending: " + str(out / "manifest.json"))
    except Exception as error:
        receipt["build_pass"] = False
        receipt["error"] = str(error)
        save()
        raise


if __name__ == "__main__":
    main()
