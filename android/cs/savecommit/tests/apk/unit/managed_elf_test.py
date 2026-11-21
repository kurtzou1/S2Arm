#!/usr/bin/env python3
# Android gate: original versioned ELF fixtures using its already-required NDK.
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Actual versioned ELF fixtures, not mocked readelf text or Android execution."""
import importlib.util
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
MANAGED = HERE.parent / "managed"
spec = importlib.util.spec_from_file_location("check_elf", MANAGED / "check-elf.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
sys.path.insert(0, str(HERE.parents[4] / "core-link"))
import link_symbols

ndk = link_symbols.find_ndk()
if ndk is None:
    raise RuntimeError("Android NDK 29.0.14206865 not found via the platform resolver")
host = {"Linux": "linux-x86_64", "Darwin": "darwin-x86_64"}[platform.system()]
tools = ndk / "toolchains/llvm/prebuilt" / host / "bin"
cc, readelf = tools / "aarch64-linux-android34-clang", tools / "llvm-readelf"
args = [e.attrib["Include"] for e in ET.parse(MANAGED / "SaveCommit.AppProbe.csproj").findall(".//LinkerArg")]
expected_arg = "-Wl,-soname,libs2a_savecommit_managed.so"
assert args.count(expected_arg) == 1, "the actual AOT project must supply its SONAME exactly once"
checks = 0


def build(root, provider_args, version="V1.0", bridge_soname=True, dependency=True):
    root.mkdir(exist_ok=True)
    (root / "provider.c").write_text("int probe(void) { return 7; }\n")
    (root / "versions.map").write_text(version + " { global: probe; local: *; };\n")
    subprocess.run([str(cc), "-shared", "-fPIC", str(root / "provider.c"),
                    "-Wl,--version-script=" + str(root / "versions.map"), *provider_args,
                    "-o", str(root / "libs2a_savecommit_managed.so")], check=True)
    source = "extern int probe(void); int entry(void) { return probe(); }\n" if dependency else "int entry(void) { return 7; }\n"
    (root / "bridge.c").write_text(source)
    subprocess.run([str(cc), "-shared", "-fPIC", str(root / "bridge.c"),
                    "-L" + str(root), "-ls2a_savecommit_managed",
                    *(["-Wl,-soname,libmanaged_bridge.so"] if bridge_soname else []),
                    "-o", str(root / "libmanaged_bridge.so")], check=True)


def expect(root, message=None):
    global checks
    try:
        audit.check(readelf, root)
    except ValueError as error:
        assert message and message in str(error), (message, error)
        print(root.name, "rejected:", error)
    else:
        assert message is None, (root.name, "unexpectedly accepted")
        print(root.name, "accepted")
    checks += 1


with tempfile.TemporaryDirectory(prefix="s2a-managed-elf-") as temp:
    base = Path(temp)
    # First prove the real original link command's missing SONAME fails.
    old = base / "original-no-soname"
    build(old, [])
    expect(old, "DT_SONAME")
    good = base / "actual-project-linker-args"
    build(good, args)
    expect(good)
    rollback = base / "withdraw-soname-only"
    build(rollback, [arg for arg in args if arg != expected_arg])
    expect(rollback, "DT_SONAME")
    wrong = base / "wrong-soname"
    build(wrong, ["-Wl,-soname,libwrong.so"])
    expect(wrong, "DT_SONAME")
    bridge = base / "bridge-no-soname"
    build(bridge, args, bridge_soname=False)
    expect(bridge, "DT_SONAME")
    unused = base / "missing-version-reference"
    build(unused, args, dependency=False)
    expect(unused, "unresolved provider versions")
    # Keep a consumer of V1.0 but replace only the actual provider with V2.0.
    replacement = base / "different-version-provider"
    build(replacement, args, version="V2.0")
    (good / "libs2a_savecommit_managed.so").write_bytes((replacement / "libs2a_savecommit_managed.so").read_bytes())
    expect(good, "unresolved provider versions")
print(f"Managed ELF: {checks}/{checks} actual-link assertions; no NativeAOT or device execution.")
