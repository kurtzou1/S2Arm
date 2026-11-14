#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Exercise the production GiantFix seam, using only original synthetic compute shaders."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import dshfn

HERE = Path(__file__).resolve().parent
HEADER = "#include <metal_stdlib>\nusing namespace metal;\nstruct Scratch { uint words[32]; };\n"
SIGNATURE = "kernel void main0(device uint* dst [[buffer(0)]], uint gid [[thread_position_in_grid]])\n"


def shader(extra="", operations=130, blocks=64):
    body = ["    threadgroup Scratch shared;", "    Scratch local = {};", "    uint acc = gid + 1u;", "    const uint step = 3u;"]
    for i in range(blocks):
        body += [f"    if ((gid & 3u) != {i % 4}u)", "    {"]
        body += ["        acc = acc * 1664525u + 1013904223u + step;"] * operations
        body += ["        local.words[0] = acc;", "        shared.words[gid & 31u] = local.words[0];", "        acc = shared.words[gid & 31u];", "        dst[gid] = acc;", "    }"]
    return HEADER + SIGNATURE + "{\n" + extra + "\n".join(body) + "\n    threadgroup_barrier(mem_flags::mem_threadgroup);\n    dst[gid] = acc;\n}\n"


cases = [
    shader(),
    shader(operations=2, blocks=2),
    shader("    uint acc2 = 0u;\n").replace("        dst[gid] = acc;", "        return;"),
    shader().replace("        dst[gid] = acc;", "        threadgroup_barrier(mem_flags::mem_device);"),
    shader().replace("    const uint step = 3u;", "    const uint step = 3u;\n    volatile uint unsupported = 0u;"),
    shader().replace("    const uint step = 3u;", "    const uint step = 3u;\n    uint acc = 5u;"),
    shader().replace("    const uint step = 3u;", "    const uint step = 3u;\n    dst = dst + 1;"),
    shader().replace("    const uint step = 3u;", "    const uint step = 3u;\n    /* block comments are outside the accepted dialect */\n"),
    shader().replace("        dst[gid] = acc;", '        // braces and strings in a comment: " { } return\n        dst[gid] = acc;'),
    shader().replace(SIGNATURE, "constant uint hidden = 7u;\n#define VALUE (hidden)\n" + SIGNATURE).replace("    uint acc = gid + 1u;", "    uint hidden = gid;\n    uint acc = gid + 1u;").replace("        dst[gid] = acc;", "        dst[gid] = VALUE;").replace("    dst[gid] = acc;\n}", "}"),
    shader().replace(SIGNATURE, "/* prefix */ #define VALUE (acc)\n" + SIGNATURE),
]
results = dshfn.batch([("giant_fix", [source]) for source in cases])
outputs = [result.get("ok", [None])[0] for result in results]
n = bad = 0


def check(name, ok):
    global n, bad
    n += 1
    bad += not ok
    print(("✓ " if ok else "✗ ") + name, flush=True)


out = outputs[0] or ""
check("large compute entry is outlined through the production GiantFix seam", "static __attribute__((noinline)) void s2a_outline_0(" in out)
check("all disjoint closed bodies extracted", out.count("static __attribute__((noinline)) void s2a_outline_") == 64)
check("mutable thread scalar remains a reference", "thread uint& acc" in out)
check("constant scalar qualifier retained", "thread const uint& step" in out)
check("threadgroup and private aggregate storage remains by reference", "threadgroup Scratch& shared" in out and "thread Scratch& local" in out)
check("entry signature and dispatch attributes unchanged", SIGNATURE in out)
restored = out[out.index(SIGNATURE):] if SIGNATURE in out else ""
for helper in re.finditer(r"static __attribute__\(\(noinline\)\) void (s2a_outline_\d+)\([^\n]*\)\n\{\n(.*?)^\}\n", out, re.MULTILINE | re.DOTALL):
    restored, count = re.subn(r"^[ \t]*" + helper[1] + r"\([^\n]*\);\n", lambda _: helper[2], restored, count=1, flags=re.MULTILINE)
    check(helper[1] + " has exactly one call site", count == 1)
check("inlining emitted bodies reconstructs the original entry byte for byte", restored == cases[0][cases[0].index(SIGNATURE):])
check("small shader unchanged byte for byte", outputs[1] == cases[1])
for i, name in enumerate(("exits", "barriers", "unknown declarations", "shadowed locals", "reassigned buffer pointers", "comment syntax"), 2):
    check(name + " are not outlined", outputs[i] == cases[i])
again = dshfn.fn("giant_fix", out)[0] if out else ""
check("transformation is idempotent", out == again)
check("line comments do not affect lexical scope or exit detection", outputs[8] is not None and "static __attribute__((noinline)) void s2a_outline_0(" in outputs[8] and '// braces and strings in a comment: " { } return' in outputs[8])
check("prefix macros hiding local captures leave the entire source unchanged", outputs[9] == cases[9])
check("comments before preprocessing directives cannot bypass the macro guard", outputs[10] == cases[10])

if not bad:
    with tempfile.TemporaryDirectory(prefix="compute_outline_") as temp:
        root = Path(temp)
        for name, source in (("original", cases[0]), ("outlined", out), ("macro-original", cases[9]), ("macro-guarded", outputs[9])):
            path = root / (name + ".metal")
            path.write_text(source)
            for sdk, minimum in (("macosx", "-mmacosx-version-min=15.0"), ("iphoneos", "-mios-version-min=18.0")):
                air = root / (name + "-" + sdk + ".air")
                subprocess.run(["xcrun", "-sdk", sdk, "metal", "-c", minimum, "-fmetal-math-mode=relaxed", "-fpreserve-invariance", str(path), "-o", str(air)], check=True, timeout=90)
                if sdk == "macosx":
                    subprocess.run(["xcrun", "-sdk", sdk, "metallib", str(air), "-o", str(root / (name + ".metallib"))], check=True, timeout=30)
        runner = root / "run"
        subprocess.run(["clang", "-fobjc-arc", "-framework", "Metal", "-framework", "Foundation", str(HERE / "t_compute_outline.m"), "-o", str(runner)], check=True, timeout=30)
        result = subprocess.run([str(runner), str(root / "original.metallib"), str(root / "outlined.metallib")], text=True, capture_output=True, timeout=90)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        check("GPU output equals independent uint32 CPU oracle, before and after outlining", result.returncode == 0)
        result = subprocess.run([str(runner), str(root / "macro-original.metallib"), str(root / "macro-guarded.metallib"), "identity"], text=True, capture_output=True, timeout=90)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        check("prefix-macro guard preserves local name lookup on GPU", result.returncode == 0)
print(f"{'✗' if bad else '✓'} t_compute_outline: {n} checks, {bad} failures")
sys.exit(1 if bad else 0)
