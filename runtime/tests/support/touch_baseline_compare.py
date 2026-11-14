#!/usr/bin/env python3
"""Compile unchanged historical/current touch readers and recorder functions.

No substitute reader, recorder, clock, frame source, or device is provided.
Input vectors exercise host interfaces, not UIKit touch delivery or hardware.
"""
import os
import sys
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/review-touch"
BASE = "e4e5b78b"


def between(text, begin, end):
    start = text.index(begin)
    return text[start:text.index(end, start)]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, cwd=ROOT, **kwargs)


OUT.mkdir(parents=True, exist_ok=True)
old = (ROOT / "runtime/tests/fixtures/touch_baseline" / f"vpad_{BASE}.m").read_text()   # 历史基准夹具（新仓无该提交）
new = (ROOT / "ios/vpad.m").read_text()
# Compile the real production frame/build-id accessors with their own state.
frames = (ROOT / "runtime/src/ap_host.c").read_text()
loader = (ROOT / "runtime/src/loader.c").read_text()
dependencies = between(frames, "static _Atomic uint64_t g_frames;", "void s2a_wg_frame")
dependencies += between(frames, "uint64_t s2a_ap_frames(void)", "void s2a_host_shutdown")
dependencies += between(loader, "static char g_main_build_id", "\n",) + "\n"
dependencies += between(loader, "const char *s2a_main_build_id(void)", "\n") + "\n"
old_publish = between(old, "    atomic_store_explicit(&g_sticks", "    for (UILabel *l in _keys)")
new_publish = between(new, "    int32_t axes[4]; for (int i = 0; i < 4; i++) axes[i] = _ax[i];", "    for (UILabel *l in _keys)")
prefix = """#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sys/stat.h>
#include "native.h"
#include "s2a_pad.h"
#import "settings.h"   // vpad.m g_res_scale → s2a_ios_res_scale（审计 P1-9），连真实 settings.m
#include "s2a_docs.h"   // vpad.m 手柄录制目录取文档根（11-07 文档根唯一取法）
"""
harness = (ROOT / "runtime/tests/support/touch_baseline_harness.inc").read_text()
WEAK = run(sys.executable, str(ROOT / "tools/weak_link_decl.py"), "flags", "touchtest", capture_output=True).stdout.split()   # 按源码「弱链接[touchtest]」登记生成
environment = dict(os.environ)
for name, source in (("old", old), ("new", new)):
    body = between(source, "uint64_t s2a_ap_frames(void);", "@interface S2AVPadView")
    bridge = "static void publish(uint32_t b, const int16_t _ax[4]) {\n"
    bridge += old_publish if name == "old" else new_publish
    bridge += "}\n"
    path = OUT / f"{name}.m"
    path.write_text(prefix + dependencies + body + bridge + harness)
    command = ["xcrun", "--sdk", "macosx", "clang", "-O1", "-g", "-fobjc-arc",
               "-Wall", "-Wextra", "-Wno-unused-parameter", "-Iruntime/include", "-Iruntime/src", "-Iios",
               "-framework", "Foundation", *WEAK,
               "-o", str(OUT / name), str(path), "runtime/src/pad.c", "ios/settings.m", "ios/cpatch_model.m", "runtime/src/caps.c", "runtime/src/patch.c", "runtime/src/launchctx.c"]
    run(*command, env=environment)
    run(str(OUT / name), str(OUT / f"{name}.tsv"), stdout=(OUT / f"{name}.stdout").open("w"))

old_results = (OUT / "old.stdout").read_text()
assert old_results == (OUT / "new.stdout").read_text(), "touch snapshot fields differ"
# Recorder wall time is live, not an injected/frozen oracle. Compare every other
# actual TSV field and assert real elapsed times are nonnegative and monotonic.
def recorded(path):
    rows = [line.split("\t") for line in path.read_text().splitlines()]
    milliseconds = [int(row[-1]) for row in rows]
    assert milliseconds == sorted(milliseconds) and min(milliseconds) >= 0
    return [row[:-1] for row in rows]

assert recorded(OUT / "old.tsv") == recorded(OUT / "new.tsv"), "padrec fields differ"
assert "存档" in (OUT / "old.tsv").read_text(), "save marker was not exercised"
print(f"PASS: {BASE} real touch reader/publisher vs current production: {len(old_results.splitlines())} reads; identical buttons/four axes and padrec fields, including save markers; live wall time checked separately.")
