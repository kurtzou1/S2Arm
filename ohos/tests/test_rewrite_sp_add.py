#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute actual rewritten ADD x18,sp,#imm boundaries with Unicorn.

Usage: python -B test_rewrite_sp_add.py --out NEW_DIRECTORY --previous OLD_REWRITER
The optional previous rewriter supplies a real regression negative control and
an Apple byte-for-byte comparison. Inputs are entirely synthetic. Requires the
rewriter's pinned dependencies and Unicorn 2.1.4; no native compiler or device.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

from unicorn import Uc, UC_ARCH_ARM64, UC_HOOK_CODE, UC_HOOK_MEM_WRITE, UC_MODE_ARM
from unicorn import arm64_const as arm

REPO = Path(__file__).resolve().parents[2]
IMMEDIATES = (0xFEF, 0xFF0, 0xFFC, 0xFFF)
CASES = [(imm, shift) for shift in (0, 12) for imm in IMMEDIATES]
REGS = [getattr(arm, "UC_ARM64_REG_X" + str(i)) for i in range(31)]
BASE, TP, TABLE = 0x100000, 0x300800, 0x400800
STACK, STACK_SIZE, SP = 0x500000, 0x2000, 0x501800
KEYS = (0, 7, 21, 32)
INITIAL = [0xA000000000001000 + i * 0x101 for i in range(31)]
SLOTS = (0x13579, 0x24680, 0xABCDEF, 0x600000)


def fixture():
    words = [0x910003F2 | (imm << 10) | ((shift == 12) << 22) for imm, shift in CASES]
    assert words[2] == 0x913FF3F2
    words.append(0xD65F03C0)
    text, ro = bytearray(0x1000), bytearray(0x1000)
    struct.pack_into("<II", text, 0, 0x14000040, 0x1000)
    struct.pack_into("<" + "I" * len(words), text, 0x100, *words)
    # MOD0 and one artificial FDE cover the entire sequence, as in the upstream
    # rewrite_target fixture. No production executable bytes are used.
    eh, ef = 0x100, 0x200
    struct.pack_into("<4sIIIii", ro, 0, b"MOD0", 0, 0, 0, eh, eh + 0x20)
    struct.pack_into("<BBBBiIii", ro, eh, 1, 0x1B, 0x03, 0x3B,
                     ef - (eh + 4), 1, 0x100 - (0x1000 + eh), ef + 0x18 - eh)
    cie = struct.pack("<II", 0x14, 0) + b"\x01zR\0\x04\x78\x1e\x01\x1b" + bytes(7)
    ro[ef:ef + 0x18] = cie
    fde = 0x1000 + ef + 0x18
    struct.pack_into("<IIii", ro, ef + 0x18, 0x10, 0x1C, 0x100 - (fde + 8), len(words) * 4)
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    for i in range(3):
        struct.pack_into("<III", header, 0x10 + 0x10 * i, 0x100 + i * 0x1000, i * 0x1000, 0x1000)
        struct.pack_into("<I", header, 0x60 + i * 4, 0x1000)
    header[0x40:0x60] = bytes(range(32))
    return bytes(header) + text + ro + bytes(0x1000), bytes(text)


def rewrite(script, source, destination, target, commands):
    destination.mkdir()
    argv = ([sys.executable, "-B", str(script)] if str(script).endswith(".py") else [str(script)]) + [str(source), str(destination), "main"]
    env = dict(os.environ, S2A_TARGET=target, PYTHONUTF8="1")
    env.pop("S2A_REWRITE_SPIN", None)
    result = subprocess.run(argv, env=env, capture_output=True)
    (destination / "rewrite.stdout.txt").write_bytes(result.stdout)
    (destination / "rewrite.stderr.txt").write_bytes(result.stderr)
    commands.append({"argv": argv, "target": target, "exitCode": result.returncode})
    assert result.returncode == 0, result.stderr.decode("utf-8", "replace")
    headers = dict(line[2:].split("\t", 1) for line in (destination / "main.fixups.tsv").read_text().splitlines() if line.startswith("# "))
    return (destination / "main.patched.bin").read_bytes(), headers


def execute(blob, site, flags, target=None, headers=None, tsd_offset=0):
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    uc.mem_map(BASE, (len(blob) + 4095) & ~4095)
    uc.mem_write(BASE, blob)
    uc.mem_map(STACK, STACK_SIZE)
    for reg, value in zip(REGS, INITIAL):
        uc.reg_write(reg, value)
    uc.reg_write(arm.UC_ARM64_REG_SP, SP)
    uc.reg_write(arm.UC_ARM64_REG_NZCV, flags)
    slot_addresses = []
    if target:
        uc.mem_map(0x300000, 0x1000)
        uc.mem_map(0x400000, 0x1000)
        uc.reg_write(arm.UC_ARM64_REG_TPIDR_EL0, TP)
        key_page = BASE + int(headers["KEY_PAGE_OFF"], 16)
        if target == "ohos":
            offsets = [(key + 1) * 8 for key in KEYS]
            uc.mem_write(TP + tsd_offset, struct.pack("<Q", TABLE))
            uc.mem_write(key_page, struct.pack("<4Qq", *offsets, tsd_offset))
            slot_addresses = [TABLE + key * 8 for key in KEYS]
        else:
            offsets = [key * 16 + 8 for key in KEYS]
            uc.mem_write(TP - 8, struct.pack("<Q", TABLE))
            uc.mem_write(key_page, struct.pack("<4Q", *offsets))
            slot_addresses = [TABLE + offset for offset in offsets]
        for address, value in zip(slot_addresses, SLOTS):
            uc.mem_write(address, struct.pack("<Q", value))

    pending, writes, violations = [], [], []
    state = {"pc": 0, "sp": SP}

    def finish_instruction(machine):
        # AArch64 pre-index allocates its frame in the same instruction as the
        # store. Unicorn may report the memory hook before SP writeback. Compare
        # both instruction boundaries: a proper pre-index allocation is legal,
        # while STP [sp,#-16] with no writeback remains below the active SP.
        active_sp = min(state["sp"], machine.reg_read(arm.UC_ARM64_REG_SP))
        for address, size in pending:
            if STACK <= address < STACK + STACK_SIZE and address < active_sp:
                violations.append((state["pc"], address, size, active_sp))
        pending.clear()

    def on_code(machine, address, size, user):
        finish_instruction(machine)
        state.update(pc=address, sp=machine.reg_read(arm.UC_ARM64_REG_SP))

    def on_write(machine, access, address, size, value, user):
        pending.append((address, size))
        writes.append((address, size))

    uc.hook_add(UC_HOOK_CODE, on_code)
    uc.hook_add(UC_HOOK_MEM_WRITE, on_write)
    uc.emu_start(BASE + site, BASE + site + 4, count=200)
    finish_instruction(uc)
    assert uc.reg_read(arm.UC_ARM64_REG_PC) == BASE + site + 4, "did not return to the next original instruction"
    values = [uc.reg_read(reg) for reg in REGS]
    slots = [struct.unpack("<Q", uc.mem_read(address, 8))[0] for address in slot_addresses]
    if target:
        for address, size in writes:
            assert SP - 16 <= address and address + size <= SP or (address == slot_addresses[0] and size == 8), "unexpected memory write"
    return values, uc.reg_read(arm.UC_ARM64_REG_SP), uc.reg_read(arm.UC_ARM64_REG_NZCV), slots, violations


def check_execution(blob, headers, original, target, expect_unsafe=False):
    runs, unsafe_cases = 0, set()
    offsets = (-0x80, 0x48) if target == "ohos" else (0,)
    for index, (immediate, shift) in enumerate(CASES):
        site = 0x100 + index * 4
        for flags_nibble in range(16):
            flags = flags_nibble << 28
            reference = execute(original, site, flags)
            assert reference[0][18] == SP + (immediate << shift)
            for offset in offsets:
                actual = execute(blob, site, flags, target, headers, offset)
                wanted = list(reference[0])
                wanted[18] = INITIAL[18]  # Host x18 is untouched; guest x18 lives in TSD.
                assert actual[0] == wanted, (target, immediate, shift, "GPR corruption")
                assert actual[1:3] == reference[1:3], (target, immediate, shift, "SP/NZCV corruption")
                assert actual[3] == [reference[0][18], *SLOTS[1:]], (target, immediate, shift, "TSD corruption")
                if actual[4]:
                    unsafe_cases.add((immediate, shift))
                if not expect_unsafe:
                    assert not actual[4], (target, immediate, shift, "write below active SP", actual[4])
                runs += 1
    if expect_unsafe:
        assert unsafe_cases == {(0xFF0, 0), (0xFFC, 0), (0xFFF, 0)}, unsafe_cases
    return {"runs": runs, "unsafe_cases": sorted(unsafe_cases)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    source = args.out / "synthetic.nso"
    container, original = fixture()
    source.write_bytes(container)
    # C 改写器（Python patch_nso.py 已在上游删除）：S2A_REWRITER_C，否则 pack/rewriter.py c-path（要 S2A_REWRITER_DEPS）
    script = Path(subprocess.run([sys.executable, str(REPO / "pack/rewriter.py"), "c-path"], check=True,
                                 capture_output=True, text=True).stdout.strip().splitlines()[-1])
    commands, results = [], {}
    for target in ("apple", "android", "ohos"):
        destination = args.out / target
        blob, headers = rewrite(script, source, destination, target, commands)
        if target != "apple":
            assert headers["REWRITE_ABI"] == target + "-sp-safe-v1"
            results[target] = check_execution(blob, headers, original, target)
        if args.previous:
            old = args.out / ("old-" + target)
            old_blob, old_headers = rewrite(args.previous, source, old, target, commands)
            if target == "apple":
                current_files = {p.name: p.read_bytes() for p in destination.glob("main.*")}
                previous_files = {p.name: p.read_bytes() for p in old.glob("main.*")}
                assert current_files == previous_files, "Apple output changed"
                results["apple"] = {"identical_files": sorted(current_files)}
            else:
                assert old_headers["REWRITE_ABI"] == target + "-below-sp-v1"
                results["old-" + target] = check_execution(old_blob, old_headers, original, target, True)
    summary = {
        "commands": commands,
        "results": results,
        "rewriter_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
        "synthetic_input_sha256": hashlib.sha256(container).hexdigest(),
    }
    if args.previous:
        summary["previous_sha256"] = hashlib.sha256(args.previous.read_bytes()).hexdigest()
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
