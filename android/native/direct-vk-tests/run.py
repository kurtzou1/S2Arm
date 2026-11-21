#!/usr/bin/env python3
# 门禁手动：要真机：含经 adb 推到自有设备执行的段（--device-file），按规矩不进门禁；离线构建段还要传 --ndk
"""Build stage-1 Vulkan bridge tests offline; optionally execute on an owned device.

The controlled driver validates adapter semantics. driver_probe uses the actual
Android Vulkan driver. xstack_probe uses actual native xstack/entry.S/Bionic TSD.
None of these tests launches a game or claims visible swapchain acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "android/native"
TESTS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ndk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--device-file", type=Path, help="private JSON with serial; never recorded")
    parser.add_argument("--imports", type=Path, help="optional local text list of static Vulkan API names")
    args = parser.parse_args()
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("output must be outside the source checkout")
    out.mkdir(parents=True, exist_ok=True)
    prebuilt = list((args.ndk / "toolchains/llvm/prebuilt").glob("*"))
    if len(prebuilt) != 1:
        parser.error("need one host toolchain in --ndk")
    cc = prebuilt[0] / "bin/aarch64-linux-android34-clang"
    header = prebuilt[0] / "sysroot/usr/include/vulkan/vulkan_core.h"
    bridge = NATIVE / "direct_vk.c"
    inputs = [bridge, NATIVE / "direct_vk.h", NATIVE / "direct_vk_commands.inc", NATIVE / "wsi_lease.c",
              NATIVE / "direct_wsi.inc", NATIVE / "direct_wsi_plan.h",
              NATIVE / "direct_objects.inc",
              NATIVE / "direct_allocator.inc",
              NATIVE / "direct_callback.c", NATIVE / "direct_callback.h", NATIVE / "direct_callback.S",
              NATIVE / "direct_session.c", NATIVE / "direct_session.h", NATIVE / "direct_choice.c", NATIVE / "direct_choice.h",
              NATIVE / "wsi_lease.h", NATIVE / "tsd.c", NATIVE / "plat_android.c",
              ROOT / "runtime/src/xstack.c", ROOT / "runtime/src/entry.S",
              ROOT / "platform/plat_asm.h", NATIVE / "runtime/fault/elf_host.c"] + sorted(TESTS.glob("*.*"))
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    receipt = {"kind": "Android Vulkan direct stage1", "sourceSha256": hashes,
               "deviceExecuted": False, "gameExecuted": False, "commands": []}

    def save():
        (out / "results.json").write_text(json.dumps(receipt, indent=2) + "\n")

    def run(argv, label, expected=0, private_prefix=0):
        p = subprocess.run([str(x) for x in argv], capture_output=True, text=True, timeout=60)
        text = p.stdout + p.stderr
        if args.device_file:
            text = text.replace(serial, "[device]")
        (out / (label + ".log")).write_text(text)
        receipt["commands"].append({"argv": [str(x) for x in argv[private_prefix:]],
            "exit": p.returncode, "expectedExit": expected, "pass": p.returncode == expected, "log": label + ".log"})
        save()
        if p.returncode != expected:
            raise RuntimeError(f"{label} failed: see {out}")
        return text

    serial = ""
    if args.device_file:
        serial = json.loads(args.device_file.read_text())["serial"]
    run([sys.executable, TESTS / "generate_commands.py", "--header", header, "--out", out / "generated.inc"], "signatures")
    if (out / "generated.inc").read_bytes() != (NATIVE / "direct_vk_commands.inc").read_bytes():
        raise RuntimeError("generated signatures differ from checked-in rows")
    common = [cc, "-std=c11", "-O2", "-g", "-Wall", "-Wextra", "-Werror", "-pthread",
              "-ffunction-sections", "-fdata-sections", "-Wl,--gc-sections",
              "-I" + str(NATIVE), "-I" + str(ROOT / "runtime/include"), "-llog"]
    xstack = [NATIVE / "tsd.c", NATIVE / "plat_android.c", NATIVE / "runtime/fault/elf_host.c",
              ROOT / "runtime/src/xstack.c", ROOT / "runtime/src/entry.S"]
    def compile(source, name, test, dependencies):
        run(common + [source, TESTS / test] + dependencies + ["-ldl", "-o", out / name], "compile-" + name)

    compile(bridge, "bridge-test", "bridge_test.c", [NATIVE / "wsi_lease.c", NATIVE / "direct_choice.c"])
    run(common + [TESTS / "terminal_objects_test.c", "-o", out / "terminal-objects-test"], "compile-terminal-objects-test")
    run(common + [TESTS / "wsi_acquire_test.c", "-o", out / "wsi-acquire-test"], "compile-wsi-acquire-test")
    run(common + ["-DS2A_ANDROID_GAME_RUNTIME=1", TESTS / "shutdown_contract_test.c", "-o", out / "shutdown-contract-test"], "compile-shutdown-contract-test")
    run(common + [TESTS / "wsi_plan_test.c", "-o", out / "wsi-plan-test"], "compile-wsi-plan-test")
    compile(bridge, "driver-probe", "driver_probe.c", [])
    compile(bridge, "xstack-probe", "xstack_probe.c", xstack)
    run(common + [TESTS / "nvn_bigstack_probe.c", *xstack, "-ldl", "-o", out / "nvn-bigstack-probe"], "compile-nvn-bigstack-probe")
    hle = (ROOT / "graphics/nvn/gfx/nvn/hle_nvn.c").read_text()
    sess = (NATIVE / "direct_session.c").read_text()
    if hle.count("s2a_nvn_set_xwrap") != 1 or sess.count("s2a_nvn_set_xwrap(sw_xstack_wrap)") != 1:
        raise RuntimeError("nvn big-stack wrap marker changed")
    # direct_session.c 的 s2a_direct_lookup 引用 NVN 选择器（direct/selection.c 及其依赖），一并编入才链得上
    selection = [NATIVE / "direct" / name for name in
                 ("selection.c", "attempt.c", "graphics.c", "json.c", "sha256.c", "s2a_direct_abi.c")]
    run(common + ["-DS2A_ANDROID_GAME_RUNTIME=1", bridge, NATIVE / "direct_session.c", NATIVE / "direct_choice.c",
        NATIVE / "wsi_lease.c", *selection, TESTS / "session_test.c", "-ldl", "-lm", "-o", out / "session-test"], "compile-session-test")
    def allocator_compile(name, asm=None, source=None):
        run(common + ["-DS2A_DIRECT_CALLBACK_TEST=1", source or bridge,
            NATIVE / "direct_callback.c", asm or NATIVE / "direct_callback.S",
            TESTS / "allocator_probe.c", *xstack, "-ldl", "-o", out / name], "compile-" + name)
    allocator_compile("allocator-probe")
    no_quarantine=out/"no-terminal-quarantine.c"
    marker="if(atomic_load(&terminating)){terminal_free(memory);return;}"
    if bridge.read_text().count(marker)!=1:raise RuntimeError("terminal quarantine mutation marker changed")
    no_quarantine.write_text(bridge.read_text().replace(marker,"/* negative control: invoke frozen guest */"))
    allocator_compile("no-terminal-quarantine",source=no_quarantine)
    asm_original = (NATIVE / "direct_callback.S").read_text()
    callback_mutants = {
        "callback-host-stack": ("    mov sp, x10", "    nop", 1),
        "callback-no-cursor-advance": ("    str x19, [x20]", "    nop", 1),
        "callback-no-cursor-restore": ("    str x21, [x20]", "    nop", 134),
    }
    for name, (before, after, _) in callback_mutants.items():
        if asm_original.count(before) != 1: raise RuntimeError("callback mutation marker changed: " + name)
        asm = out / (name + ".S"); asm.write_text(asm_original.replace(before, after))
        allocator_compile(name, asm=asm)
    core_mutant = out / "callback-no-core.c"
    core_original = bridge.read_text(); marker = "if (blocking) host.block_end();"
    if core_original.count(marker) != 1: raise RuntimeError("callback core marker changed")
    core_mutant.write_text(core_original.replace(marker, "/* negative control */"))
    allocator_compile("callback-no-core", source=core_mutant)
    variants = {
        "no-wrap": ("return host.wrap(name, (void *)adapted);", "return (void *)adapted;"),
        "no-extension-rewrite": ("name = VK_KHR_ANDROID_SURFACE_EXTENSION_NAME; nn = 1;", "nn = 1;"),
        "no-failed-surface-release": ("else release_surface_window();", "else { /* negative control */ }"),
        "early-surface-release": ("destroy(i, s, adapted);", "release_surface_window(); destroy(i, s, adapted);"),
        "no-block-begin": ("        host.block_begin(); \\", "        /* negative control */ \\"),
        "guest-allocator-forwarded": ("VkResult adaptation = adapt_allocator(pAllocator, &adapted);", "VkResult adaptation = VK_SUCCESS; adapted = pAllocator;"),
    }
    original = bridge.read_text()
    for name, (before, after) in variants.items():
        if original.count(before) != 1:
            raise RuntimeError("mutation marker changed: " + name)
        source = out / (name + ".c")
        source.write_text(original.replace(before, after))
        compile(source, name, "bridge_test.c", [NATIVE / "wsi_lease.c", NATIVE / "direct_choice.c"])
    compile(out / "no-wrap.c", "xstack-no-wrap", "xstack_probe.c", xstack)
    if args.device_file:
        adb = [args.adb, "-s", serial]
        # A private, bounded diagnostic folder; no access to saves, keys or game resources.
        remote = "/data/local/tmp/s2arm-direct-vk-stage1"
        model = run(adb + ["shell", "getprop", "ro.product.model"], "model", private_prefix=3).strip()
        abi = run(adb + ["shell", "getprop", "ro.product.cpu.abi"], "abi", private_prefix=3).strip()
        if abi != "arm64-v8a":
            raise RuntimeError("device is not ARM64")
        receipt["model"] = model
        run(adb + ["shell", "mkdir", "-p", remote], "device-directory", private_prefix=3)
        names = ["bridge-test", "terminal-objects-test", "wsi-acquire-test", "shutdown-contract-test", "wsi-plan-test", "driver-probe", "xstack-probe", "nvn-bigstack-probe", "session-test", *variants, "xstack-no-wrap",
                 "allocator-probe", "no-terminal-quarantine", *callback_mutants, "callback-no-core"]
        for name in names:
            run(adb + ["push", out / name, remote + "/" + name], "push-" + name, private_prefix=3)
            run(adb + ["shell", "chmod", "700", remote + "/" + name], "chmod-" + name, private_prefix=3)
        imports_arg = []
        if args.imports:
            # Only command names; never copy executable bytes or the source container.
            names_from_file = args.imports.read_text().splitlines()
            if not names_from_file or not all(s.startswith("vk") and s.isascii() and s.isalnum() for s in names_from_file):
                raise RuntimeError("imports must contain only Vulkan command names")
            run(adb + ["push", args.imports, remote + "/imports.txt"], "push-imports", private_prefix=3)
            imports_arg = [remote + "/imports.txt"]
        def device(name, arguments=(), expected=0, label=None):
            return run(adb + ["shell", "timeout", "20", remote + "/" + name, *arguments],
                       label or name, expected, private_prefix=3)
        device("bridge-test")
        device("terminal-objects-test")
        device("wsi-acquire-test")
        device("shutdown-contract-test", ["acquire"], label="shutdown-contract-acquire")
        device("shutdown-contract-test", ["present"], label="shutdown-contract-present")
        device("wsi-plan-test")
        device("bridge-test", ["fatal-live-instance"], 72, "fatal-live-instance")
        device("bridge-test", ["fatal-allocator"], 72, "fatal-allocator")
        device("driver-probe", imports_arg)
        device("driver-probe", ["--terminal"], label="driver-terminal-drain")
        device("xstack-probe")
        device("nvn-bigstack-probe")
        for mode in ["generic", "direct", "direct-clears-fail", "malformed", "duplicate", "missing",
                     "auto", "auto-missing", "auto-malformed", "auto-fail", "auto-attempt"]:
            device("session-test", [mode, remote + "/session-" + mode], label="session-" + mode)
        device("allocator-probe", label="allocator-controlled")
        device("allocator-probe", ["real"], label="allocator-actual-driver")
        device("allocator-probe", ["terminal"], label="allocator-terminal-drain")
        device("allocator-probe", ["terminal-controlled"],label="allocator-terminal-scratch")
        device("no-terminal-quarantine", ["terminal"],134,"no-terminal-quarantine")
        device("allocator-probe", ["wrong-context"], 134, "allocator-wrong-context")
        for name, (_, _, expected) in callback_mutants.items(): device(name, expected=expected)
        device("callback-no-core", expected=1)
        for name in variants:
            device(name, expected=1)
        device("xstack-no-wrap", expected=1)
        receipt["deviceExecuted"] = True
    if hashes != {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}:
        raise RuntimeError("sources changed during test")
    receipt["pass"] = True
    save()
    print("PASS stage1 compile/signatures" + (", controlled dispatch, actual driver/xstack/terminal drain and 12 mutation controls" if args.device_file else "; device NOT RUN"))


if __name__ == "__main__":
    main()
