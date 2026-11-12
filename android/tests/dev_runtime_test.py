#!/usr/bin/env python3
"""tools/dev_runtime.py without a device: the ELF / JNI ABI checks of `manifest`, and `push` against a fake
adb (a script that answers pm path / sha256sum / run-as / logcat and records every call)."""
import hashlib
import importlib.util
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
from pathlib import Path

ANDROID = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dev_runtime", ANDROID / "tools/dev_runtime.py")
dev_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev_runtime)


def elf(align=16384, soname=b"libs2arm_android.so", payload=b""):
    """AArch64 ELF64: one LOAD over the file, PT_DYNAMIC with DT_STRTAB / DT_SONAME, then payload."""
    dyn, = (64 + 2 * 56,)
    strtab = dyn + 3 * 16
    names = b"\0" + soname + b"\0"
    size = strtab + len(names) + len(payload)
    b = bytearray(size)
    b[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<H", b, 18, 183)
    struct.pack_into("<Q", b, 32, 64)
    struct.pack_into("<HH", b, 54, 56, 2)
    struct.pack_into("<IIQQQQQQ", b, 64, 1, 5, 0, 0, 0, size, size, align)
    struct.pack_into("<IIQQQQQQ", b, 120, 2, 6, dyn, dyn, dyn, 48, 48, 8)
    struct.pack_into("<qQqQqQ", b, dyn, 5, strtab, 14 if soname else 0, 1, 0, 0)
    b[strtab:strtab + len(names)] = names
    b[strtab + len(names):] = payload
    return bytes(b)


FAKE_ADB = textwrap.dedent('''\
    #!/usr/bin/env python3
    import hashlib, json, shlex, sys
    state = json.load(open(sys.argv[1]))
    args = sys.argv[4:]          # fake-adb <state> -s <serial> ...
    with open(state["log"], "a") as log: log.write(json.dumps(args) + "\\n")
    def save():
        with open(sys.argv[1], "w") as f: json.dump(state, f)
    if args[0] == "push" and len(args) == 3:
        state.setdefault("pushed", {})[args[2]] = hashlib.sha256(open(args[1], "rb").read()).hexdigest()
        save(); sys.exit(0)
    if len(args) != 2 or args[0] != "shell": sys.exit(2)
    argv = shlex.split(args[1])  # adb shell passes one command to the device shell
    pkg = "org.s2arm.game.t0100000000abcdef"
    prop = "debug.s2a.debug_env"
    if argv == ["pm", "path", pkg]: print("package:/data/app/x/base.apk")
    elif argv == ["sha256sum", "/data/app/x/base.apk"]: print(state["installed"] + "  /data/app/x/base.apk")
    elif argv == ["pidof", pkg]: sys.exit(1)
    elif argv == ["pidof", pkg + ":game"]:
        if state.get("pidof_error"):
            print("pidof: permission denied", file=sys.stderr); sys.exit(1)
        state["game_queries"] = state.get("game_queries", 0) + 1; save()
        if state.get("game_alive") or (state.get("game_appears") and state["game_queries"] > 1): print("4242")
        else: sys.exit(1)
    elif argv[:4] == ["run-as", pkg, "sh", "-c"] and len(argv) == 5:
        cmd = argv[4]
        if cmd == "id -u": print("10000")
        elif cmd == "sha256sum files/dev-runtime/" + state["lib"] + "/libs2arm_android.so":
            if not state.get("copied"): sys.exit(1)
            print(state["lib"] + "  f")
        elif "mkdir -p files/dev-runtime/" + state["lib"] in cmd:
            tmp = "/data/local/tmp/s2a-dev-" + state["lib"][:16] + ".so"
            if state.get("pushed", {}).get(tmp) != state["lib"]: sys.exit(1)
            state["copied"] = True; save()
        else: sys.exit(2)
    elif argv[:2] == ["rm", "-f"] and len(argv) == 4: pass
    elif argv == ["getprop", prop]:
        if state.get("getprop_error"):
            print("getprop failed", file=sys.stderr); sys.exit(1)
        print(state.get("gate", ""))
    elif argv[:2] == ["setprop", prop] and len(argv) == 3:
        if not (argv[2] == "1" and state.get("enable_no_effect")):
            state["gate"] = argv[2]; save()
        if argv[2] == "1" and state.get("fail_enable"): sys.exit(1)
        if argv[2] == state.get("previous") and state.get("fail_restore"): sys.exit(1)
    elif argv == ["logcat", "-c"]: pass
    elif argv[:3] == ["am", "start", "-W"]:
        if argv[3:5] not in (["-n", pkg + "/org.s2arm.android.LibraryActivity"],
                             ["-n", pkg + "/org.s2arm.android.MainActivity"]):
            print("activity not exported or unexpected", file=sys.stderr); sys.exit(1)
        state["start"] = argv; save()
    elif argv == ["logcat", "-d", "-s", "S2Arm:V"]:
        start = state.get("start", [])
        if (not state.get("game_alive") and state.get("user_selects_game") and state.get("gate") == "1" and len(start) >= 9 and start[3:5] == ["-n", pkg + "/org.s2arm.android.LibraryActivity"]
                and start[5:8] == ["--es", "s2arm.dev_runtime", state["lib"]]):
            print("W S2Arm : runtime-library: dev-override sha256=" + state["lib"] + " base-apk=x")
    else: sys.exit(2)
''')


GIT = shutil.which("git")   # the manifest records the source identity from git


class DevRuntime(unittest.TestCase):
    def test_elf_checks_match_the_app(self):
        with tempfile.TemporaryDirectory() as temp:
            for data, problem in ((elf(), None), (elf(align=4096), "16 KB"), (elf(soname=b"libs2arm_androix.so"), "DT_SONAME"),
                                  (elf(soname=b""), "DT_SONAME"), (b"\x7fELF\x01" + bytes(100), "AArch64")):
                path = Path(temp) / "lib.so"
                path.write_bytes(data)
                got = dev_runtime.elf_problem(path)
                self.assertEqual(got is None, problem is None, got)
                if problem:
                    self.assertIn(problem, got)

    @unittest.skipUnless(GIT, "dev_runtime.py manifest needs git (source identity); no git on PATH")
    def test_manifest_requires_this_trees_jni_abi(self):
        with tempfile.TemporaryDirectory() as temp:
            t = Path(temp)
            (t / "app.apk").write_bytes(b"apk")
            (t / "old.so").write_bytes(elf(payload=b"0" * 64))
            r = dev_runtime.main(["manifest", "--lib", str(t / "old.so"), "--apk", str(t / "app.apk"), "--out", str(t / "o1")])
            self.assertEqual(r, 2)
            self.assertFalse((t / "o1").exists())
            (t / "new.so").write_bytes(elf(payload=dev_runtime.jni_abi().encode()))
            self.assertEqual(dev_runtime.main(["manifest", "--lib", str(t / "new.so"), "--apk", str(t / "app.apk"),
                                               "--out", str(t / "o2")]), 0)
            doc = json.loads((t / "o2/dev-runtime.json").read_text())
            self.assertEqual(doc["libSha256"], hashlib.sha256((t / "new.so").read_bytes()).hexdigest())
            self.assertEqual(doc["baseApkSha256"], hashlib.sha256(b"apk").hexdigest())
            self.assertRegex(doc["sourceCommit"], r"^[0-9a-f]{40}$")
            self.assertIsInstance(doc["dirty"], bool)

    def push(self, temp, installed=None, previous="", fail_enable=False, fail_restore=False, no_start=False, user_selects_game=True, game_alive=False, pidof_error=False, game_appears=False, getprop_error=False, enable_no_effect=False):
        t = Path(temp)
        lib = elf(payload=dev_runtime.jni_abi().encode())
        (t / "app.apk").write_bytes(b"apk")
        (t / "lib.so").write_bytes(lib)
        dev_runtime.main(["manifest", "--lib", str(t / "lib.so"), "--apk", str(t / "app.apk"), "--out", str(t / "out")])
        state = {"log": str(t / "calls.jsonl"), "lib": hashlib.sha256(lib).hexdigest(),
                 "installed": installed or hashlib.sha256(b"apk").hexdigest(), "gate": previous,
                 "previous": previous, "fail_enable": fail_enable, "fail_restore": fail_restore,
                 "user_selects_game": user_selects_game, "game_alive": game_alive,
                 "pidof_error": pidof_error, "game_appears": game_appears,
                 "getprop_error": getprop_error, "enable_no_effect": enable_no_effect}
        (t / "state.json").write_text(json.dumps(state))
        (t / "adb.py").write_text(FAKE_ADB)
        args = ["push", "--serial", "S1", "--package", "org.s2arm.game.t0100000000abcdef",
                               "--console-mode", "docked", "--lib-dir", str(t / "out"), "--clean",
                               "--adb", f"{sys.executable} {t / 'adb.py'} {t / 'state.json'}"]
        if no_start: args.append("--no-start")
        verdict = dev_runtime.verdict
        with mock.patch.object(dev_runtime, "verdict", side_effect=lambda d, sha: verdict(d, sha, seconds=0.1)):
            rc = dev_runtime.main(args)
        calls = [json.loads(l) for l in (t / "calls.jsonl").read_text().splitlines()]
        return rc, calls, json.loads((t / "state.json").read_text())

    @unittest.skipUnless(GIT, "the pushed manifest is made with git; no git on PATH")
    def test_push_installs_read_only_and_starts_with_the_extra(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp)
            shell = [" ".join(c[1:]) for c in calls if c[0] == "shell"]
            copy = next(c for c in shell if "files/dev-runtime/" + state["lib"] in c and "chmod 0555" in c)
            self.assertIn("chmod 0444", copy)
            self.assertIn('chmod -R u+w "$x"; rm -rf "$x"', copy)
            start = next(c for c in shell if c.startswith("am start -W"))
            self.assertIn("-n org.s2arm.game.t0100000000abcdef/org.s2arm.android.LibraryActivity", start)
            self.assertIn(f"--es s2arm.dev_runtime {state['lib']} --es s2arm.console_mode docked", start)
            self.assertEqual(rc, 0)

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_property_stays_enabled_after_verdict_for_native_configuration(self):
        for previous in ("", "0", "1", "two words"):
            with self.subTest(previous=previous), tempfile.TemporaryDirectory() as temp:
                rc, calls, state = self.push(temp, previous=previous)
                shell = [c[1] for c in calls if c[0] == "shell"]
                start = next(i for i, c in enumerate(shell) if c.startswith("am start -W"))
                self.assertIn("setprop debug.s2a.debug_env 1", shell[:start])
                self.assertIn("logcat -d -s S2Arm:V", shell[start:])
                # Native debug entries read the property after the runtime-library log.
                self.assertEqual(state["gate"], "1")
                receipt = json.loads(next((Path(temp) / "out").glob("push-*.json")).read_text())
                self.assertEqual(receipt["debug_gate_previous"], previous)
                self.assertTrue(receipt["debug_gate_left_enabled"])
                self.assertEqual(rc, 0)

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_enable_failure_still_restores_previous_and_does_not_start(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp, previous="0", fail_enable=True)
            self.assertNotEqual(rc, 0)
            self.assertFalse(any(c[0] == "shell" and c[1].startswith("am start -W") for c in calls))
            self.assertEqual(state["gate"], "0")

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_restore_failure_is_not_reported_as_success(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, _, _ = self.push(temp, previous="0", fail_restore=True, user_selects_game=False)
            self.assertNotEqual(rc, 0)
            receipt = json.loads(next((Path(temp) / "out").glob("push-*.json")).read_text())
            self.assertFalse(receipt["debug_gate_restored"])
            self.assertIn("restore failed", receipt["error"])

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_no_start_does_not_touch_property(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp, previous="0", no_start=True)
            self.assertEqual(rc, 0)
            self.assertEqual(state["gate"], "0")
            self.assertFalse(any(c[0] == "shell" and "prop debug.s2a.debug_env" in c[1] for c in calls))

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_library_without_user_selection_does_not_claim_acceptance(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, _, state = self.push(temp, previous="0", user_selects_game=False)
            self.assertNotEqual(rc, 0)
            self.assertEqual(state["gate"], "0")

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_game_process_without_library_process_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp, previous="0", game_alive=True)
            self.assertNotEqual(rc, 0)
            self.assertFalse(any(c[0] == "push" for c in calls), "must not push while :game is alive")
            self.assertFalse(any(c[0] == "shell" and ("am force-stop" in c[1] or "--activity-single-top" in c[1]) for c in calls))
            self.assertEqual(state["gate"], "0")

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_game_appearing_during_stop_prevents_push(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, _ = self.push(temp, game_appears=True)
            self.assertNotEqual(rc, 0)
            self.assertFalse(any(c[0] == "push" for c in calls))

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_pidof_error_does_not_mean_process_absent(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, _ = self.push(temp, pidof_error=True)
            self.assertNotEqual(rc, 0)
            self.assertFalse(any(c[0] == "push" for c in calls))

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_gate_read_failure_does_not_change_unknown_value(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp, previous="0", getprop_error=True)
            self.assertNotEqual(rc, 0)
            self.assertEqual(state["gate"], "0")
            self.assertFalse(any(c[0] == "shell" and ("setprop " in c[1] or c[1].startswith("am start -W")) for c in calls))

    @unittest.skipUnless(GIT, "manifest needs git")
    def test_gate_readback_mismatch_prevents_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp, previous="0", enable_no_effect=True)
            self.assertNotEqual(rc, 0)
            self.assertEqual(state["gate"], "0")
            self.assertFalse(any(c[0] == "shell" and c[1].startswith("am start -W") for c in calls))

    @unittest.skipUnless(GIT, "the pushed manifest is made with git; no git on PATH")
    def test_push_refuses_another_installed_apk(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, _ = self.push(temp, installed="99" * 32)
            self.assertEqual(rc, 2)
            self.assertFalse(any(c[0] == "push" for c in calls), "nothing pushed")
            self.assertFalse(any("am start -W" in " ".join(c) for c in calls), "nothing started")


if __name__ == "__main__":
    sys.exit(unittest.main())
