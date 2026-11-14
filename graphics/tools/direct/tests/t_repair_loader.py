#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Real shader_build + library-container cache regression, using original synthetic kernels.

This test intentionally supplies a real Metal device directly. It tests the production
loader and reflection boundary, not host initialization, NVN recording, or gameplay.
Uncalled native-host paths are dead-stripped or linked with dynamic_lookup; no loader,
reflection, or Metal-function provider is replaced.
"""
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE.parent))
import repair_compute as repair

KEY_A, KEY_B = 0x1111111111111111, 0x2222222222222222
BATCH = """#include <metal_stdlib>
using namespace metal;
kernel void sa_main0(device uint* out [[buffer(0)]]) { *out = 11; }
kernel void sb_main0(device uint* out [[buffer(0)]]) { *out = 22; }
"""
REPLACEMENT = """#include <metal_stdlib>
using namespace metal;
kernel void sa_main0(device uint* out [[buffer(0)]]) { *out = 33; }
"""


def run(command, env, timeout=60):
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n{result.stdout[-1000:]}{result.stderr[-6000:]}")
    return result


def compile_tools(work, env):
    gen = work / "gen"
    headers = [gen / f"nvn_aa_{name}.h" for name in ("edge", "blend", "neighbour", "lut")]
    headers.append(gen / "gal_tess_msl.h")
    # Request only generated headers: the 'avail' target also scans every backend source.
    run(["make", "-C", str(ROOT / "graphics/nvn"), "OUT=" + str(work), *map(str, headers)], env)
    command = ["xcrun", "clang", "-O1", "-std=gnu11", "-fobjc-arc", "-Wno-unused-function", "-Wno-unguarded-availability-new", "-Wno-unguarded-availability"]
    for include in (gen, ROOT / "runtime/include", ROOT / "graphics/nvn/host", ROOT / "graphics/nvn/gfx/nvn", ROOT / "graphics/nvn/gfx/nvn/include", ROOT / "graphics/nvn/third_party/vulkan-headers/include"):
        command.append("-I" + str(include))
    source = ROOT / "graphics/nvn/gfx/nvn/nvn_mtl.m"
    command += [f'-DNVN_REPAIR_SOURCE="{source}"', str(HERE / "t_repair_loader.m"), str(ROOT / "graphics/nvn/gfx/nvn/nvn_refl.m"), "-Wl,-dead_strip", "-Wl,-undefined,dynamic_lookup"]
    for framework in ("Metal", "Foundation", "QuartzCore", "CoreGraphics", "ImageIO", "UniformTypeIdentifiers"):
        command += ["-framework", framework]
    executable = work / "loader"
    run([*command, "-lc++", "-o", str(executable)], env, timeout=120)
    return executable


def metallib(work, name, source, env):
    msl, air, lib = (work / (name + suffix) for suffix in (".metal", ".air", ".metallib"))
    msl.write_text(source)
    run(["xcrun", "-sdk", "macosx", "metal", "-c", str(msl), "-o", str(air)], env)
    run(["xcrun", "-sdk", "macosx", "metallib", str(air), "-o", str(lib)], env)
    return lib.read_bytes()


def fixture(work, batch, replacement, chain):
    library = work / "container"
    library.mkdir()
    meta_a = {"stage": "cs", "chain": chain, "route": "B", "entry": "main0", "fn_prefix": "sa_", "fn_lib": "original_shared", "bindings": []}
    meta_b = dict(meta_a, fn_prefix="sb_")
    payloads = [batch, json.dumps(meta_a).encode(), json.dumps(meta_b).encode()]
    offsets = [0, len(payloads[0]), len(payloads[0]) + len(payloads[1])]
    records = []
    for key, metadata_index in ((KEY_A, 1), (KEY_B, 2)):
        for kind, index in ((0, 0), (1, metadata_index)):
            records.append(struct.pack("<QBBHIQ", key, kind, 0, 0, len(payloads[index]), offsets[index]))
    shard = b"".join(payloads)
    header = bytearray(48)
    header[:8] = b"S2ALIB\0\0"
    struct.pack_into("<III", header, 8, 1, len(records), 1)
    header[24:36] = chain.encode()
    (library / "lib.idx").write_bytes(header + struct.pack("<QQ", len(shard), 0) + b"".join(records))
    (library / "lib.000.pak").write_bytes(shard)
    output = work / "repair"
    output.mkdir()
    report = repair.write_replacements(repair.Library(library), output, {KEY_A: replacement})
    (library / "lib.idx").write_bytes((output / "patched.idx").read_bytes())
    (library / report["shard"]).write_bytes((output / report["shard"]).read_bytes())
    return library, report, meta_a


def restore_shared_identity(library, report, original_metadata):
    # Negative control changes only A's fn_lib; the compiled functions and B's metadata stay intact.
    current = repair.Library(library)
    record, shard, reserved, _, _ = current.records[KEY_A, 1]
    path = library / report["shard"]
    data = path.read_bytes()
    metadata = json.dumps(original_metadata).encode()
    path.write_bytes(data + metadata)
    index = bytearray(current.index)
    struct.pack_into("<Q", index, 48 + shard * 16, len(data) + len(metadata))
    struct.pack_into("<QBBHIQ", index, current.base + record * 24, KEY_A, 1, shard, reserved, len(metadata), len(data))
    (library / "lib.idx").write_bytes(index)


def main():
    env = dict(os.environ)  # Respect the caller's Xcode/toolchain selection.
    match = re.search(r'^#define DMSH_CHAIN "([0-9a-f]{12})"', (ROOT / "graphics/nvn/gfx/nvn/dmsh_chain.h").read_text(), re.MULTILINE)
    if not match:
        raise ValueError("Cannot read the production library chain")
    checks = 0
    with tempfile.TemporaryDirectory(prefix="repair_loader_") as temp:
        work = Path(temp).resolve()
        executable = compile_tools(work, env)
        batch = metallib(work, "batch", BATCH, env)
        replacement = metallib(work, "replacement", REPLACEMENT, env)
        library, report, metadata = fixture(work, batch, replacement, match[1])
        # Separate processes retain the real loader's static once/caches without resetting production state.
        for order in ("0", "1"):
            result = subprocess.run([str(executable), str(library), order], env=env, text=True, capture_output=True, timeout=30)
            print(result.stdout, end="")
            if result.returncode != 0 or result.stdout.count("expected=") != 2:
                raise AssertionError(f"Positive order {order} failed ({result.returncode}): {result.stderr}")
            checks += 1
        restore_shared_identity(library, report, metadata)
        for order in ("0", "1"):
            result = subprocess.run([str(executable), str(library), order], env=env, text=True, capture_output=True, timeout=30)
            evidence = "loader failed key=2222222222222222_b" in result.stderr if order == "0" else "expected=33 actual=11" in result.stdout
            if result.returncode != 1 or not evidence:
                raise AssertionError(f"Negative order {order} did not catch shared-cache reuse ({result.returncode}): {result.stdout}{result.stderr}")
            print(f"negative order={order}: expected failure caught")
            checks += 1
    print(f"✓ t_repair_loader: {checks} checks, 0 failures; 4 positive GPU results, 2 negative controls")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, AssertionError, subprocess.TimeoutExpired) as error:
        print(f"✗ t_repair_loader: {error}", file=sys.stderr)
        sys.exit(1)
