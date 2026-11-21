#!/usr/bin/env python3
# 门禁手动：只在 Linux ARM64 上跑（真实 gate/VM 并发准入与停机）；原注释说登记在 tests/gate_not_default.tsv，那份表已不存在——接到哪个 Linux 门禁待 owner 定（11-20 android/gate.sh 接回时查出）
"""Linux ARM64：真实 gate/VM 并发准入与停机回归；不联网，不启动 Android。"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
from publication_revoke import run as run_revoke

ROOT = Path(__file__).resolve().parents[4]
FAULT = Path("android/native/runtime/fault")
SOURCES = [
    Path("android/core-link/runtime-tests/writers-gate/writers_gate_test.c"),
    FAULT / "tests/thread_guest.S", FAULT / "tests/guest_stack.S",
    FAULT / "fault.c", FAULT / "trampoline.S",
    Path("android/native/guest_signal.c"), Path("android/native/redzone.S"),
    Path("runtime/src/crash.c"), Path("runtime/src/xstack.c"), FAULT / "elf_host.c",
    Path("runtime/src/gate.c"), Path("runtime/src/svc_mem.c"), Path("runtime/src/layout.c"),
    Path("runtime/src/det.c"), Path("runtime/src/os.c"), Path("graphics/track/track.c"),
    Path("android/native/runtime/tracking/platform.c"),
    Path("android/native/runtime/tracking/runtime.c"),
    Path("android/native/runtime/tracking/registry.c"),
    Path("android/native/plat_android.c"), Path("android/native/memory.c"),
]
CASES = {
    "race-stack": [], "race-unmap": [], "race-heap": [],
    "external-published": [], "renew-budget": [], "det-poison": [],
    "sleep-pause": [], "sleep-pause-expired": [], "sleep-pause-vm-first": [], "sleep-pause-vm-after": [],
    "sleep-pause-cores": ["sleep-pause", "cores"],
    "sleep-interrupt": [], "sleep-expired": [], "sleep-signals": [],
    "sleep-interrupt-cores": ["sleep-interrupt", "cores"],
    "lifetime-peer": [], "lifetime-wake": [], "lifetime-publication": [], "lifetime-reused-handle": [], "lifetime-priority": [],
    "query-default": ["query-published", "default"],
    "query-ondemand": ["query-published", "ondemand"],
    "query-stop-ondemand": ["query-stop-published", "ondemand"],
    "busy-before": [], "busy-published": [],
    "unmap-before": [], "unmap-published": [],
    "stack-before": [], "stack-published": [],
    "diag-stack-before": ["stack-before", "diag"], "diag-writer-fatal": [], "diag-mprotect-fatal": [],
    "busy-before-cores": ["busy-before", "cores"],
    "busy-published-cores": ["busy-published", "cores"],
    "query-published": ["query-published", "cores"],
    "invalid-published": ["invalid-published", "cores"],
    "timeout-published": [], "nested-fatal": [], "progress-published": [], "progress-stall-published": [],
    "stop-published": [], "stop-acquired-published": [], "query-stop-published": [],
    "callback-map": [], "callback-unmap": [], "callback-unmap-stuck": [],
    "callback-map-adjacent": [], "callback-map-16k-adjacent": [], "callback-map-partial16": [], "map-partial16": [],
    "fast-map-rollback": [], "fast-stop": [], "race-map-map": [], "race-map-unmap": [],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--two-guest-only", action="store_true", help="run the three two-guest cases and their admission negative control")
    args = parser.parse_args()
    if args.two_guest_only and args.case:
        parser.error("--two-guest-only cannot be combined with --case")
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("output must be outside checkout")
    if platform.system() != "Linux" or platform.machine() not in ("aarch64", "arm64"):
        parser.error("native Linux ARM64 required")
    out.mkdir(parents=True, exist_ok=False)
    result = {"commands": [], "android_executed": False, "managed_gpu_executed": False}

    def run(command, name, expected=0, contains=None):
        command = [str(x) for x in command]
        p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
        log = p.stdout + p.stderr
        (out / (name + ".log")).write_text(log)
        passed = p.returncode == expected and (contains is None or contains in log)
        if name == "diag-writer-fatal":
            passed &= (log.count("MapMemory首失败：") == 1 and "原因=writer-admission-fatal result=none errno=35" in log and "账本可用=0 采样=unavailable" in log and "FATAL Android memory SVC 0x4宿主writer协调失败 errno=35" in log)
        elif name == "diag-mprotect-fatal":
            passed &= (log.count("MapMemory首失败：") == 1 and "原因=host-mprotect-fatal result=none errno=12" in log and "账本可用=1 采样=failure" in log and "FATAL MapMemory mprotect errno=12" in log)
        elif name == "diag-stack-before":
            passed &= "MapMemory首失败：" not in log
        elif name == "negative-diag-race-stack":
            passed &= (log.count("MapMemory首失败：") == 1 and "原因=writer-admission-fatal result=none errno=16" in log and "账本可用=0 采样=unavailable" in log)
        elif name in ("callback-unmap-stuck", "callback-map-partial16"):
            passed &= ("writer协调到期" in log and "state=host-callback" in log
                       and "callback=unknown" in log and "errno=110" in log)
        result["commands"].append({"argv": command, "exit": p.returncode,
                                   "expected_exit": expected, "passed": passed, "log": name + ".log"})
        (out / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if not passed:
            raise RuntimeError(name + ": " + log[-2000:])
        print(name, "PASS", flush=True)

    def compile_source(root, source, obj):
        flags = ["-D__ANDROID__", "-DS2A_UNIT_TEST", "-std=gnu11", "-O2", "-Wall", "-Wextra",
                 "-Werror", "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-variable",
                 "-Wno-missing-field-initializers", "-Wno-misleading-indentation", "-Wno-prio-ctor-dtor",
                 "-ffunction-sections", "-fdata-sections", "-pthread",
                 "-I" + str(root / "runtime/include"), "-I" + str(root / "android/native")]
        if compiler_is_clang:
            flags.remove("-Wno-prio-ctor-dtor")  # GCC-only warning name
        if source in [Path("runtime/src/" + x + ".c") for x in ("crash", "xstack", "gate", "svc_mem", "det", "os")] or source.name == "memory.c":
            flags += ["-D_GNU_SOURCE"]
        if source.name == "plat_android.c":
            flags += ["-Dplat_tsd_init=unused_plat_tsd_init", "-Dplat_tsd_base=unused_plat_tsd_base",
                      "-Dplat_tsd_offset=unused_plat_tsd_offset"]
        if source == Path("graphics/track/track.c"):
            flags.remove("-D__ANDROID__")
        run([args.cc, *flags, "-MMD", "-MF", obj.with_suffix(".d"), "-c", root / source, "-o", obj], obj.stem)

    def link(objects, name):
        binary = out / name
        run([args.cc, "-pthread", *objects, "-Wl,--gc-sections", "-Wl,--wrap=pthread_mutex_trylock", "-Wl,--wrap=calloc", "-Wl,--wrap=free", "-Wl,--wrap=pthread_create", "-Wl,--wrap=pthread_mutex_lock", "-Wl,--wrap=pthread_mutex_unlock",
             "-Wl,--wrap=nanosleep", "-Wl,--wrap=s2a_track_backing_begin",
             "-Wl,--wrap=mmap", "-Wl,--wrap=plat_page_size", "-o", binary], name + "-link")
        return binary

    run([args.cc, "--version"], "compiler")
    compiler_is_clang = "clang" in (out / "compiler.log").read_text().lower()
    objects = []
    for i, source in enumerate(SOURCES):
        obj = out / f"candidate-{i}.o"
        compile_source(ROOT, source, obj)
        objects.append(obj)
    files = set(SOURCES)
    for obj in objects:
        dependencies = shlex.split(obj.with_suffix(".d").read_text().replace("\\\n", " "))[1:]
        for dependency in dependencies:
            path = Path(dependency).resolve()
            if path.is_relative_to(ROOT):
                files.add(path.relative_to(ROOT))
    hashes = {str(p): sha(ROOT / p) for p in sorted(files)}
    result["source_sha256"] = hashes
    binary = link(objects, "writers-gate")
    result["binary_sha256"] = sha(binary)
    if args.two_guest_only:
        cases = ("race-stack", "race-unmap", "race-heap")
        for case in cases:
            run([binary, case], case, 0, "PASS actual-gate two memory SVCs")
        run([binary, "stack-before", "diag"], "diag-stack-before", 0, "PASS actual-gate")
        run([binary, "diag-writer-fatal"], "diag-writer-fatal", 134, None)
        run([binary, "diag-mprotect-fatal"], "diag-mprotect-fatal", 134, None)
        # Keep the real SVC and kernel mappings, but remove the serial wait in a
        # private copy. Every case must reject the missing admission protocol.
        private = out / "negative-two-guest-source"
        for path in files:
            target = private / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
        path = private / FAULT / "thread_android.inc"
        before = "    if (error == EBUSY) error = android_vm_wait_serial(self, deadline);"
        source = path.read_text()
        if source.count(before) != 1:
            raise RuntimeError("two-guest negative control target changed")
        path.write_text(source.replace(before, "    /* test-only: omit admission wait */"))
        mutant_obj = out / "negative-two-guest.o"
        compile_source(private, SOURCES[0], mutant_obj)
        mutant = link([mutant_obj, *objects[1:]], "negative-two-guest")
        for case in cases:
            run([mutant, case], "negative-" + case, 134, "宿主writer协调失败 errno=16")
        run([mutant, "diag-race-stack"], "negative-diag-race-stack", 134, "宿主writer协调失败 errno=16")
        result["test_sha256"] = {Path(__file__).name: sha(Path(__file__))}
        result["source_unchanged"] = hashes == {str(p): sha(ROOT / p) for p in sorted(files)}
        result["passed"] = result["source_unchanged"] and all(c["passed"] for c in result["commands"])
        (out / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if not result["passed"]:
            raise RuntimeError("production source changed during test")
        print("PASS two-guest admission regression; Android and managed GPU not executed")
        return
    for case in args.case or [c for c in CASES if c != "external-published"]:
        expected = -6 if case == "det-poison" else 134 if case in ("timeout-published", "nested-fatal", "progress-stall-published", "diag-writer-fatal", "diag-mprotect-fatal", "callback-unmap-stuck", "callback-map-partial16") else 0
        message = ("确定性共享内存无法恢复地址保留" if case == "det-poison" else
                   "宿主writer协调失败 errno=" + ("35" if case == "nested-fatal" else "110") if expected else
                   {"callback-map": "PASS callback-map", "callback-unmap": "PASS callback-unmap",
                    "callback-map-adjacent": "PASS callback-map-adjacent",
                    "callback-map-16k-adjacent": "PASS callback-map-16k-adjacent",
                    "map-partial16": "PASS map-partial16", "fast-map-rollback": "PASS fast-map-rollback",
                    "fast-stop": "PASS fast-stop", "race-map-map": "PASS race-map-map",
                    "race-map-unmap": "PASS race-map-unmap"}.get(case, "PASS actual-gate"))
        if case.startswith("diag-") and expected: message = None
        run([binary, *(CASES[case] or [case])], case, expected, message)

    # Native shared-page binding for external controllers. All timing remains C.
    run([args.cc, '-shared', '-fPIC', '-pthread', '-I'+str(ROOT/'android/native'),
         ROOT/'graphics/vulkan/runtime/control-tests/backing_test.c',
         '-o', out/'libs2a_backing_test.so'], 'shared-authority-build')
    run_revoke(binary, out)

    # 删除真实准入等待调用，保留同一 gate/SVC/VM；必须被并发正例击穿，不能以任意崩溃算红。
    private = out / "negative-source"
    for path in files:
        target = private / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    path = private / FAULT / "thread_android.inc"
    before = "    if (error == EBUSY) error = android_vm_wait_serial(self, deadline);"
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError("negative control target changed")
    path.write_text(text.replace(before, "    /* test-only: omit admission wait */"))
    mutant_obj = out / "negative-admission.o"
    compile_source(private, SOURCES[0], mutant_obj)
    mutant = link([mutant_obj, *objects[1:]], "negative-admission")
    run([mutant, "busy-published"], "negative-admission", 134, "宿主writer协调失败 errno=16")
    # 负控：把 0x2C 改回全体停稳 → 宿主回调未退出时 callback-map 必须按预期协调超时失败（errno=110）。
    svc_index = SOURCES.index(Path("runtime/src/svc_mem.c"))
    private = out / "negative-fast-full-source"
    for path in files:
        target = private / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    path = private / "runtime/src/svc_mem.c"
    before = "    int fast = num == 0x2C && physical_growth_empty(regs[0], regs[1]);"
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError("fast/full negative control target changed")
    path.write_text(text.replace(before, "    int fast = 0;"))
    mutant_obj = out / "negative-fast-full.o"
    compile_source(private, Path("runtime/src/svc_mem.c"), mutant_obj)
    mutant = link([*objects[:svc_index], mutant_obj, *objects[svc_index + 1:]], "negative-fast-full")
    run([mutant, "callback-map"], "negative-fast-full", 134, "宿主writer协调失败 errno=110")
    # 负控：把 0x2D 也错改成只串行 → callback-unmap 的“释放前不完成”断言必须失败。
    private = out / "negative-unmap-fast-source"
    for path in files:
        target = private / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    path = private / "runtime/src/svc_mem.c"
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError("unmap/fast negative control target changed")
    path.write_text(text.replace(before, "    int fast = num == 0x2D || (num == 0x2C && physical_growth_empty(regs[0], regs[1]));"))
    mutant_obj = out / "negative-unmap-fast.o"
    compile_source(private, Path("runtime/src/svc_mem.c"), mutant_obj)
    mutant = link([*objects[:svc_index], mutant_obj, *objects[svc_index + 1:]], "negative-unmap-fast")
    run([mutant, "callback-unmap"], "negative-unmap-fast", 1, "FAIL unmap cannot complete while callback is live")
    # 负控：准入等待不按换页推进续期 → 排空期间第二条线程进内存 SVC 2 s 就 die（复审第 2 轮 P1-A）
    private = out / "negative-renew-source"
    for path in files:
        target = private / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    path = private / FAULT / "thread_android.inc"
    before = "        android_vm_renew(&renewal, now, deadline);\n"
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError("negative control target changed: renew")
    path.write_text(text.replace(before, "        (void)renewal;\n"))
    mutant_obj = out / "negative-renew.o"
    compile_source(private, SOURCES[0], mutant_obj)
    mutant = link([mutant_obj, *objects[1:]], "negative-renew")
    run([mutant, "progress-published"], "negative-renew", 1, "FAIL waiter renewed while the backing change progresses")
    # 负控只改输出目录的实际thread.c；睡眠、身份和锁合同都须由对应断言拒绝。
    for name, before, after, case, message in [
        ("sleep-no-safe-point", "        if (sleeper) android_vm_barrier_poll(sleeper, sleep_wait_boundary);",
         "        (void)sleeper;", "sleep-interrupt",
         "FAIL sleep VM census does not wait for requested duration"),
        ("sleep-single-call", "if (ns > 0) sleep_thread_ontime(me, ns);",
         "if (ns > 0) { struct timespec ts = {ns / 1000000000, ns % 1000000000}; nanosleep(&ts, NULL); }",
         "sleep-interrupt", "FAIL interrupted sleep retains full duration"),
        ("sleep-relative-time", "        if (sleeper) android_vm_barrier_poll(sleeper, sleep_wait_boundary);",
         "        uint64_t parked = now_ns(); if (sleeper) android_vm_barrier_poll(sleeper, sleep_wait_boundary); end += now_ns() - parked;",
         "sleep-interrupt", "FAIL VM park and signals do not extend absolute deadline"),
        ("sleep-no-pause", "        if (sleeper) android_vm_barrier_poll(sleeper, sleep_wait_boundary);",
         "        if (sleeper) android_vm_barrier(sleeper);", "sleep-pause",
         "FAIL SleepThread acknowledges pause before two-second timeout"),
        ("sleep-no-vm-pause-poll", "        if (sleeper) android_vm_barrier_poll(sleeper, sleep_wait_boundary);",
         "        if (sleeper) { sleep_wait_boundary(sleeper); android_vm_barrier(sleeper); }", "sleep-pause-vm-first",
         "FAIL SleepThread acknowledges pause before two-second timeout"),
        ("peer-identity", "p->id != peer.id || ", "", "lifetime-reused-handle",
         "FAIL released peer causes no timeout"),
        ("pthread-publication", "if (!rc) { glock(); t->pt = created; pthread_mutex_unlock(&G); }",
         "if (!rc) t->pt = created;", "lifetime-publication",
         "FAIL CreateThread completes protected parent publication"),
    ]:
        private = out / ("negative-" + name + "-source")
        for path in files:
            target = private / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
        path = private / "runtime/src/thread.c"
        text = path.read_text()
        if text.count(before) != 1:
            raise RuntimeError("negative control target changed: " + name)
        path.write_text(text.replace(before, after))
        mutant_obj = out / ("negative-" + name + ".o")
        compile_source(private, SOURCES[0], mutant_obj)
        mutant = link([mutant_obj, *objects[1:]], "negative-" + name)
        run([mutant, case], "negative-" + name, 1, message)

    # Mutate the sole authority, rather than obsolete per-wait lifecycle caches.
    for kind in ['pause', 'resume', 'observation-reset', 'stale-clock', 'owner', 'epoch', 'withdrawal', 'late-progress']:
        run(["python3", Path(__file__).with_name("renew_model.py"), "--cc", args.cc,
             "--negative", kind, "--out", out / ("negative-model-" + kind)],
            "negative-model-" + kind, 1, "REGRESSION events=")
    run(["python3", Path(__file__).with_name("renew_model.py"), "--cc", args.cc, "--out", out / "model"],
        "renew-model", 0, "PASS native authority model")
    run(["python3", Path(__file__).with_name("roster_handoff.py"), binary, out / "roster"],
        "roster-handoff", 0, "PASS serial admission roster handoff")

    run(["python3", Path(__file__).with_name("renew_model.py"), "--cc", args.cc, "--negative-cap", "--out", out / "negative-cap-model"],
        "negative-cap-model", 1, "REGRESSION events=")

    run([args.cc, '-pthread', '-I'+str(ROOT/'android/native'),
         Path(__file__).with_name('authority_races.c'), '-o', out/'authority-races'], 'authority-races-build')
    run([out/'authority-races'], 'authority-races', 0, 'PASS R7 clock/lifecycle')

    private = out/'negative-clock-lock'; private.mkdir()
    for name in ['wsi_lease.c', 'wsi_lease.h', 'backing_wait.h']:
        shutil.copyfile(ROOT/'android/native'/name, private/name)
    lease = private/'wsi_lease.c'; text=lease.read_text()
    begin=text.index('uint64_t s2a_wsi_backing_progress('); end=text.index('int s2a_wsi_backing_decision(',begin)
    region=text[begin:end].replace('    pthread_mutex_lock(&l->mutex);', '    /* private negative: clock sampled without lifecycle lock */')
    lease.write_text(text[:begin]+region+text[end:])
    probe=private/'probe.c';probe.write_text(Path(__file__).with_name('authority_races.c').read_text().replace('"../../../native/wsi_lease.c"', '"'+str(lease)+'"'))
    run([args.cc,'-pthread',probe,'-o',private/'probe'], 'negative-clock-lock-build')
    run([private/'probe'], 'negative-clock-lock', 1, 'REGRESSION: lifecycle raced native clock')

    result["test_sha256"] = {p.name: sha(p) for p in (Path(__file__), Path(__file__).with_name("publication_revoke.py"))}
    result["source_unchanged"] = hashes == {str(p): sha(ROOT / p) for p in sorted(files)}
    result["passed"] = result["source_unchanged"] and all(c["passed"] for c in result["commands"])
    (out / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    if not result["passed"]:
        raise RuntimeError("production source changed during test")
    print("PASS real writers gate/VM regression; Android and managed GPU not executed")


if __name__ == "__main__":
    main()
