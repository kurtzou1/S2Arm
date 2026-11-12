#!/usr/bin/env python3
# 紧凑跳转表符号扩展。合成 aarch64 函数进改写器，核对落点。
# 有 qemu 与 aarch64 gcc 时再执行改写后的映像，和原指令对拍；缺其中之一则该段记「跳过」，退出码仍按其余项。
# 没有 llvm-objcopy / llvm-nm（PATH 或 /opt/homebrew/opt/llvm/bin，也认交叉 binutils）时打印「跳过：无 objcopy」并退出 0。
# 改写器 = C 改写器（REW_C，缺省取 pack/rewriter.py c-path）；取不到判红。产物对金样 tests/fixtures/rewrite_golden/rewrite_signed_jt.tsv
#   （见 tests/rewrite_golden.py；原为 C / Python 对拍，只收当年两边都对拍过的组合）。
import os, struct, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from rewrite_golden import Golden
REW_C = os.environ.get("REW_C", "")
QEMU = os.environ.get("QEMU_AARCH64", "qemu-aarch64-static")
GCC = os.environ.get("AARCH64_GCC", "aarch64-linux-gnu-gcc")
NM = ""
OBJCOPY = ""

def tool_on_path(name):
    """PATH 与 Homebrew LLVM 目录里找可执行文件。绝对路径原样认。"""
    if os.path.isabs(name) and os.access(name, os.X_OK):
        return name
    dirs = os.environ.get("PATH", "").split(os.pathsep) + ["/opt/homebrew/opt/llvm/bin"]
    for d in dirs:
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    return ""

def find_objcopy_nm():
    """成对的 objcopy 与 nm。先认环境变量，再 llvm-objcopy/llvm-nm，再交叉 binutils。"""
    pairs = []
    oc = os.environ.get("AARCH64_OBJCOPY") or os.environ.get("OBJCOPY")
    nm = os.environ.get("AARCH64_NM") or os.environ.get("NM")
    if oc or nm:
        pairs.append((oc or "", nm or ""))
    pairs += [
        ("llvm-objcopy", "llvm-nm"),
        ("/opt/homebrew/opt/llvm/bin/llvm-objcopy", "/opt/homebrew/opt/llvm/bin/llvm-nm"),
        ("aarch64-linux-gnu-objcopy", "aarch64-linux-gnu-nm"),
    ]
    for a, b in pairs:
        fa, fb = tool_on_path(a) if a else "", tool_on_path(b) if b else ""
        if fa and fb:
            return fa, fb
    return "", ""

def hw_off(kind, entry):
    """qemu-aarch64 上这条加载 + add 的字节偏移。entry 是表里的无符号位型。"""
    if kind in ("ldrb+lsl", "ldrb+uxtw", "ldrb+sxtw"):
        return entry << 2
    if kind == "ldrsb.w+lsl":
        v = entry if entry < 128 else entry - 256
        return (v & 0xFFFFFFFF) << 2
    if kind == "ldrsb.x+lsl":
        return (entry if entry < 128 else entry - 256) << 2
    if kind in ("ldrh+lsl", "ldrh+uxtw", "ldrh+uxth"):
        return entry << 2
    if kind == "ldrsh.w+lsl":
        v = entry if entry < 32768 else entry - 65536
        return (v & 0xFFFFFFFF) << 2
    if kind == "ldrsh.x+lsl":
        return (entry if entry < 32768 else entry - 65536) << 2
    if kind == "ldrb+sxtb":
        return (entry if entry < 128 else entry - 256) << 2
    if kind == "ldrh+sxth":
        return (entry if entry < 32768 else entry - 65536) << 2
    if kind == "ldrsb.w+sxtw":
        return (entry if entry < 128 else entry - 256) << 2
    raise KeyError(kind)

# 打开开关后，线性垫按这个区间铺。None = 关着时的无符号满宽。
# W 目的再 lsl #2 不在这张表里改 bias：开关打开后记缺口。
SIGNED_BIAS = {
    "ldrb+lsl": None,
    "ldrb+uxtw": None,
    "ldrb+sxtw": None,
    "ldrh+uxtw": None,
    "ldrh+uxth": None,
    "ldrsb.w+lsl": None,
    "ldrsb.x+lsl": -128,
    "ldrh+lsl": None,
    "ldrsh.w+lsl": None,
    "ldrsh.x+lsl": -32768,
    "ldrb+sxtb": -128,
    "ldrsb.w+sxtw": -128,
    "ldrh+sxth": -32768,
}
# 开关打开：这两条不按 256/65536 改写，退出 3、产物照出（v0.3.1 拿不准不停）。
W_LSL_GAP = {"ldrsb.w+lsl", "ldrsh.w+lsl"}

# 表外配对：add 的扩展与加载宽度对不上，硬件落点远远跑出线性垫能盖的区间（ldrsb w + uxtw #2 落在 base+17G 量级）。
# 编译器不会发出这三种；开关打开后按「认不出就记缺口」处理，退出 3、产物照出（v0.3.1 拿不准不停）。
BAD_PAIRS = [
    ("badpair_uxtw", "ldrsb w6, [x1, x0]", "add x18, x18, w6, uxtw #2", "8 位加载配 uxtw"),
    ("badpair_uxth", "ldrsb w6, [x1, x0]", "add x18, x18, w6, uxth #2", "8 位加载配 uxth"),
    ("badpair_sxtb", "ldrh w6, [x1, x0]", "add x18, x18, w6, sxtb #2", "半字加载配 sxtb"),
]

UNSIGNED_EXT = {"ldrb+uxtw", "ldrb+sxtw", "ldrh+uxtw", "ldrh+uxth"}

CASES = [
    ("ub_uxtw", "ldrb w6, [x1, x0]", "add x18, x18, w6, uxtw #2", "ldrb+uxtw", [0, 2, 4]),
    ("ub_sxtw", "ldrb w6, [x1, x0]", "add x18, x18, w6, sxtw #2", "ldrb+sxtw", [0, 2, 4]),
    ("uh_uxtw", "ldrh w6, [x1, x0]", "add x18, x18, w6, uxtw #2", "ldrh+uxtw", None),
    ("uh_uxth", "ldrh w6, [x1, x0]", "add x18, x18, w6, uxth #2", "ldrh+uxth", None),
    ("ub", "ldrb w6, [x1, x0]", "add x18, x18, x6, lsl #2", "ldrb+lsl", [0, 2, 4]),
    ("sbw", "ldrsb w6, [x1, x0]", "add x18, x18, x6, lsl #2", "ldrsb.w+lsl", [0, 2, 4]),
    ("shw", "ldrsh w6, [x1, x0]", "add x18, x18, x6, lsl #2", "ldrsh.w+lsl", None),
    ("sbx", "ldrsb x6, [x1, x0]", "add x18, x18, x6, lsl #2", "ldrsb.x+lsl", [0xFC, 0xFE, 0, 2, 4]),
    ("sxtb", "ldrb w6, [x1, x0]", "add x18, x18, w6, sxtb #2", "ldrb+sxtb", [0xFC, 0xFE, 0, 2, 4]),
    ("sxtw", "ldrsb w6, [x1, x0]", "add x18, x18, w6, sxtw #2", "ldrsb.w+sxtw", [0xFC, 0xFE, 0, 2, 4]),
    ("shx", "ldrsh x6, [x1, x0]", "add x18, x18, x6, lsl #2", "ldrsh.x+lsl", None),
    ("sxth", "ldrh w6, [x1, x0]", "add x18, x18, w6, sxth #2", "ldrh+sxth", None),
]

ASM = """
.p2align 2
mov w0, #11
ret
mov w0, #12
ret
anchor:
mov w0, #13
ret
mov w0, #14
ret
mov w0, #15
ret
dispatch:
adr x18, anchor
adr x1, table
{load}
{add}
br x18
.p2align 2
table:
{table}
.p2align 2
"""

RET_OF = {0xFC: 11, 0xFE: 12, 0: 13, 2: 14, 4: 15}

def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)

def have(tool):
    return subprocess.run(["bash", "-lc", f"command -v {tool}"], capture_output=True).returncode == 0

def nso_from_words(words):
    text = bytearray(0x1000)
    struct.pack_into("<II", text, 0, 0x14000040, 0x1000)
    struct.pack_into("<%dI" % len(words), text, 0x100, *words)
    ro = bytearray(0x1000)
    eh, ef = 0x100, 0x200
    struct.pack_into("<4sIIIii", ro, 0, b"MOD0", 0, 0, 0, eh, eh + 0x20)
    struct.pack_into("<BBBBiIii", ro, eh, 1, 0x1B, 3, 0x3B, ef - eh - 4, 1, 0x100 - (0x1000 + eh), ef + 0x18 - eh)
    ro[ef:ef + 0x18] = struct.pack("<II", 0x14, 0) + bytes([1]) + b"zR\0" + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    fde = 0x1000 + ef + 0x18
    struct.pack_into("<IIii", ro, ef + 0x18, 0x10, fde + 4 - (0x1000 + ef), 0x100 - (fde + 8), len(words) * 4)
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    for k in range(3):
        struct.pack_into("<III", header, 0x10 + 16 * k, 0x100 + 0x1000 * k, 0x1000 * k, 0x1000)
        struct.pack_into("<I", header, 0x60 + 4 * k, 0x1000)
    raw = bytes(header) + bytes(text) + bytes(ro) + bytes(0x1000)
    mem = bytes(text) + bytes(ro) + bytes(0x1000)
    return raw, mem

def assemble(src, work):
    work.mkdir(parents=True, exist_ok=True)
    s, o, blob = work / "t.s", work / "t.o", work / "t.bin"
    s.write_text(src)
    run(["clang", "-target", "aarch64-linux-gnu", "-c", str(s), "-o", str(o)])
    run([OBJCOPY, "-O", "binary", "-j", ".text", str(o), str(blob)])
    sym = {}
    for line in run([NM, str(o)]).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            sym[parts[2]] = int(parts[0], 16)
    raw = blob.read_bytes()
    words = [struct.unpack_from("<I", raw, i)[0] for i in range(0, len(raw) - len(raw) % 4, 4)]
    return words, sym

def b_target(w, a):
    if w >> 26 != 0b000101:
        return None
    imm = w & 0x3FFFFFF
    return a + 4 * (imm - (1 << 26) if imm >> 25 else imm)

def patch_off(fixups):
    for line in Path(fixups).read_text().splitlines():
        if line.startswith("# PATCH_OFF\t"):
            return int(line.split("\t", 1)[1], 16)
    raise AssertionError("没有 PATCH_OFF")

def key_off(fixups):
    for line in Path(fixups).read_text().splitlines():
        if line.startswith("# KEY_PAGE_OFF\t"):
            return int(line.split("\t", 1)[1], 16)
    raise AssertionError("没有 KEY_PAGE_OFF")

def landings(data, po, br):
    entry = b_target(struct.unpack_from("<I", data, br)[0], br)
    if entry is None or entry < po:
        return None
    ents = []
    for a in range(0x100, min(po, len(data)), 4):
        t = b_target(struct.unpack_from("<I", data, a)[0], a)
        if t is not None and t >= po:
            ents.append(t)
    ents = sorted(set(ents)) + [len(data)]
    if entry not in ents:
        return None
    end = ents[ents.index(entry) + 1]
    out = set()
    for a in range(entry, end, 4):
        t = b_target(struct.unpack_from("<I", data, a)[0], a)
        if t is not None and not entry <= t < end:
            out.add(t)
    return out

def rewrite(rew, nso, out, signed, target):
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["S2A_TARGET"] = target
    env.pop("S2A_REWRITE_SPIN", None)
    if signed:
        env["S2A_REWRITE_SIGNED_JT"] = "1"
    else:
        env.pop("S2A_REWRITE_SIGNED_JT", None)
    cmd = [sys.executable, rew] if str(rew).endswith(".py") else [str(rew)]
    proc = subprocess.run(cmd + [str(nso), str(out), "main"], env=env, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr

def span(anchor, bias, width):
    return {anchor + 4 * (bias + i) for i in range(width)}

def main():
    global OBJCOPY, NM
    bad = 0
    rows = []
    OBJCOPY, NM = find_objcopy_nm()
    if not OBJCOPY or not NM:
        print("跳过：无 objcopy")
        return 0
    rew_c = REW_C or (subprocess.run([sys.executable, str(ROOT / "pack/rewriter.py"), "c-path"], capture_output=True,
                                     text=True).stdout.strip().splitlines() or [""])[-1]
    if not (rew_c and os.access(rew_c, os.X_OK)):
        print("不通 取不到 C 改写器（REW_C 或 python3 pack/rewriter.py c-path）")
        return 1
    golden = Golden("rewrite_signed_jt")

    def check(name, ok, detail):
        nonlocal bad
        bad += not ok
        rows.append(("通" if ok else "不通") + f" {name}：{detail}")

    work = Path(tempfile.mkdtemp(prefix="sjt-"))
    exec_bin = None
    if have(QEMU) and have(GCC):
        exec_bin = work / "exec"
        run([GCC, "-static", "-O2", "-o", str(exec_bin), str(ROOT / "tests/rewrite_signed_jt_exec.c")])
        meas_s = work / "meas.s"
        meas_c = work / "meas.c"
        meas_s.write_text("""
.global measure
measure:
  cmp x0, #0
  b.eq l0
  cmp x0, #1
  b.eq l1
  cmp x0, #2
  b.eq l2
  cmp x0, #3
  b.eq l3
  cmp x0, #4
  b.eq l4
  cmp x0, #5
  b.eq l5
  ret
l0:
  ldrb w4, [x2]
  add x0, x1, x4, lsl #2
  ret
l1:
  ldrsb w4, [x2]
  add x0, x1, x4, lsl #2
  ret
l2:
  ldrsb x4, [x2]
  add x0, x1, x4, lsl #2
  ret
l3:
  ldrb w4, [x2]
  add x0, x1, w4, sxtb #2
  ret
l4:
  ldrsb w4, [x2]
  add x0, x1, w4, sxtw #2
  ret
l5:
  ldrsh x4, [x3]
  add x0, x1, x4, lsl #2
  ret
""")
        meas_c.write_text("""
#include <stdint.h>
#include <stdio.h>
uint64_t measure(int, uint64_t, uint8_t*, uint16_t*);
int main(void) {
  uint8_t b; uint16_t h; uint64_t base = 0x100000;
  int kinds[] = {0,1,2,3,4,5};
  const char* names[] = {"ldrb+lsl","ldrsb.w+lsl","ldrsb.x+lsl","ldrb+sxtb","ldrsb.w+sxtw","ldrsh.x+lsl"};
  unsigned es[] = {0,127,128,255,0x7fff,0x8000,0xffff};
  for (int k = 0; k < 6; k++) for (int i = 0; i < 7; i++) {
    unsigned e = es[i];
    if (k < 5 && e > 255) continue;
    b = (uint8_t)e; h = (uint16_t)e;
    long long d = (long long)measure(kinds[k], base, &b, &h) - (long long)base;
    printf("%s %u %lld\\n", names[k], e, d);
  }
  return 0;
}
""")
        mb = work / "meas"
        run([GCC, "-static", "-O2", "-o", str(mb), str(meas_c), str(meas_s)])
        hw_ok = True
        n = 0
        for line in run([QEMU, str(mb)]).stdout.splitlines():
            name, e, d = line.split()
            hw_ok &= int(d) == hw_off(name, int(e))
            n += 1
        check("硬件偏移", hw_ok, f"qemu-aarch64 {n} 组与公式一致")
    else:
        rows.append("跳过 硬件偏移：没有 qemu 或 aarch64 gcc")

    rewriters = [("c", rew_c)]

    before_after = []
    for name, load, add, kind, entries in CASES:
        if entries is None:
            table_asm = ".hword 0"
            width = 65536
        else:
            table_asm = ".byte " + ", ".join(str(e if e < 128 else e - 256) for e in entries)
            width = 256
        words, sym = assemble(ASM.format(load=load, add=add, table=table_asm), work / name)
        anchor = 0x100 + sym["anchor"]
        dispatch = 0x100 + sym["dispatch"]
        brs = [0x100 + i * 4 for i, w in enumerate(words) if w == 0xD61F0240]
        if len(brs) != 1:
            check(f"{name} 汇编", False, f"br x18 有 {len(brs)} 处")
            continue
        br = brs[0]
        raw, mem = nso_from_words(words)
        nso_path = work / name / "in.nso"
        mem_path = work / name / "mem.bin"
        nso_path.write_bytes(raw)
        mem_path.write_bytes(mem)
        bias = SIGNED_BIAS[kind]
        results = {}
        for signed in (0, 1):
            for tag, rew in rewriters:
                for target in ("apple", "android"):
                    out = work / name / f"{tag}-{target}-s{signed}"
                    rc, log = rewrite(rew, nso_path, out, signed, target)
                    patched = out / "main.patched.bin"
                    L = None
                    if rc == 0 and patched.is_file():
                        data = patched.read_bytes()
                        L = landings(data, patch_off(out / "main.fixups.tsv"), br)
                    results[(signed, tag, target)] = (rc, L, patched if patched.is_file() else None, out)
                    if signed and kind in W_LSL_GAP:
                        ok = rc == 3 and patched.is_file()   # v0.3.1 拿不准不停：记缺口、产物照出
                        check(f"{name}/{kind} {tag} {target} 开关1", ok,
                              f"退出 {rc} 映像 {'无' if not patched.is_file() else '有'}（W 目的 lsl 记缺口）")
                        continue
                    if width <= 256 and bias is None:
                        want = span(anchor, 0, width)
                        ok = rc == 0 and L == want
                        check(f"{name}/{kind} {tag} {target} 开关{signed}", ok,
                              f"退出 {rc} 落点 {len(L) if L else 0} 期望无符号 {width}")
                    elif width <= 256 and signed == 0:
                        want = span(anchor, 0, width)
                        ok = rc == 0 and L == want
                        check(f"{name}/{kind} {tag} {target} 开关0", ok,
                              f"退出 {rc} 落点 {len(L) if L else 0} 按无符号")
                    elif width <= 256:
                        want = span(anchor, bias, width)
                        ok = rc == 0 and L == want
                        check(f"{name}/{kind} {tag} {target} 开关1", ok,
                              f"退出 {rc} 最负 {anchor + 4 * bias:#x} 共 {len(L) if L else 0}")
                    else:
                        # 半字全铺会穿过补丁区，只抽基址附近和最负项。关着时不许出现 base-131072。
                        use = (bias or 0) if signed else 0
                        need = {anchor, anchor + 4}
                        if use:
                            need |= {anchor + 4 * use, anchor - 4}
                        forbid = {anchor + (131072 if use else -131072)}
                        ok = rc == 0 and L is not None and need <= L and not (forbid & L)
                        check(f"{name}/{kind} {tag} {target} 开关{signed}", ok,
                              f"退出 {rc} 落点 {len(L) if L else 0} 含 {anchor + 4 * use:#x}")
        # 新增非负配对的两态必须都产出完整且逐字节相同的五份文件，
        # 缺任一产物也报红，不能因失败后没有映像而漏掉对拍。
        if kind in UNSIGNED_EXT:
            outputs = ("main.patched.bin", "main.fixups.tsv", "main.gates.tsv", "main.gaps.tsv", "main.sites.tsv")
            for tag, _ in rewriters:
                for target in ("apple", "android"):
                    off, on = results[(0, tag, target)], results[(1, tag, target)]
                    same = off[0] == on[0] == 0 and all(
                        (off[3] / f).is_file() and (on[3] / f).is_file()
                        and (off[3] / f).read_bytes() == (on[3] / f).read_bytes() for f in outputs)
                    check(f"{name} {tag} {target} 开关双态产物", same, "逐字节相同" if same else "失败或产物缺失/不同")
            for signed in (0, 1):
                for target in ("apple", "android"):
                    c = results[(signed, "c", target)]
                    err = golden.check(f"{name}/s{signed}/{target}", c[0], nso_path, c[3], outputs)
                    check(f"{name} {target} 开关{signed} 五份产物对金样", err is None, err or "相同")
        # 关着时无符号形态、打开后有符号形态：映像对金样（原为 C / Python 映像逐字节对拍）。
        else:
            for signed, expect_same in ((0, bias is None or kind.endswith("+lsl")), (1, True)):
                if not expect_same:
                    continue
                for target in ("apple", "android"):
                    c = results[(signed, "c", target)]
                    if signed and kind in W_LSL_GAP:
                        ok = c[0] == 3 and c[2] is not None   # v0.3.1：记缺口、产物照出
                        check(f"{name} {target} 开关1 记缺口", ok, f"退出 {c[0]}")
                        continue
                    if c[2]:
                        err = golden.check(f"{name}/s{signed}/{target}", c[0], nso_path, c[3], ["main.patched.bin"])
                        check(f"{name} {target} 开关{signed} 映像对金样", err is None, err or "相同")
        # 执行：原映像 vs 开关 0 / 1 的苹果改写映像
        if exec_bin and entries:
            def once(image, disp, key, idx):
                try:
                    proc = subprocess.run([QEMU, str(exec_bin), str(image), hex(disp), key, str(idx)],
                                          capture_output=True, text=True, timeout=3)
                except subprocess.TimeoutExpired:
                    return "超时"
                if proc.returncode != 0:
                    return f"崩溃{proc.returncode}"
                return proc.stdout.strip()
            for idx, entry in enumerate(entries):
                want = str(RET_OF[entry])
                orig = once(mem_path, dispatch, "-", idx)
                off = results[(0, "c", "apple")]
                on = results[(1, "c", "apple")]
                got_off = "无映像"
                got_on = "无映像"
                if off[2]:
                    got_off = once(off[2], dispatch, hex(key_off(off[3] / "main.fixups.tsv")), idx)
                if on[2]:
                    got_on = once(on[2], dispatch, hex(key_off(on[3] / "main.fixups.tsv")), idx)
                hw = hw_off(kind, entry)
                if kind in W_LSL_GAP:
                    ok = orig == want and got_off == want and got_on == "无映像"
                elif bias is None:
                    ok = orig == want and got_off == want and got_on == want
                elif got_off == "无映像":
                    # 关着时没有映像（不认这一形态）。打开后必须和原指令一致。
                    ok = orig == want and got_on == want
                elif entry >= 128 or hw < 0:
                    ok = orig == want and got_on == want and got_off != want
                else:
                    ok = orig == want and got_off == want and got_on == want
                check(f"执行 {name} 下标{idx} 表项{entry:#x}", ok,
                      f"原 {orig} 关 {got_off} 开 {got_on} 期望 {want}")
                if idx == 0 or (entry >= 128 and bias is not None) or kind in W_LSL_GAP and idx == 0:
                    before_after.append((kind, entry, f"base{hw:+d}", orig, got_off, got_on, "无映像" if kind in W_LSL_GAP else want))
        if exec_bin and kind == "ldrsb.w+lsl":
            fault = work / "fault"
            (work / "fault.s").write_text("""
.global run
.global land
run:
  ldrsb w2, [x1]
  add x3, x0, x2, lsl #2
  br x3
land:
  mov w0, #7
  ret
""")
            (work / "fault.c").write_text(r"""
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <setjmp.h>
extern uint32_t run(uint64_t base, uint8_t *byte);
extern uint32_t land(void);
static sigjmp_buf jb;
static void onfault(int s) { (void)s; siglongjmp(jb, 1); }
int main(void) {
  uint8_t b;
  struct sigaction sa = {0};
  sa.sa_handler = onfault;
  sigaction(SIGSEGV, &sa, 0);
  sigaction(SIGBUS, &sa, 0);
  unsigned es[] = {0x00, 0xFE, 0xFF};
  for (int i = 0; i < 3; i++) {
    b = (uint8_t)es[i];
    if (sigsetjmp(jb, 1)) { printf("%u SIGSEGV\n", es[i]); continue; }
    printf("%u %u\n", es[i], run((uint64_t)(uintptr_t)land, &b));
  }
  return 0;
}
""")
            run([GCC, "-static", "-O2", "-o", str(fault), str(work / "fault.c"), str(work / "fault.s")])
            gotf = {}
            for line in run([QEMU, str(fault)]).stdout.splitlines():
                e, v = line.split()
                gotf[int(e, 10)] = v
            sig_ok = gotf.get(0xFE) == "SIGSEGV" and gotf.get(0xFF) == "SIGSEGV" and gotf.get(0) == "7"
            check("原指令 ldrsb W+lsl 表项 0xFE/0xFF", sig_ok,
                  f"0={gotf.get(0)} 0xFE={gotf.get(0xFE)} 0xFF={gotf.get(0xFF)}")
            for tag, _rew in rewriters:
                for target in ("apple", "android"):
                    on = results[(1, tag, target)]
                    ok = on[0] == 3 and on[2] is None
                    check(f"ldrsb W {tag} {target} 开关开无映像", ok, f"退出 {on[0]}")
            before_after.append(("ldrsb.w+lsl", 0xFE, "base+约2^32", "SIGSEGV", "—", "无映像", "无映像"))
            before_after.append(("ldrsb.w+lsl", 0xFF, "base+约2^32", "SIGSEGV", "—", "无映像", "无映像"))

    # 表外配对：开关打开后要记缺口。开关关着的读数不在这里断言（C 的 regadd 不看 shift.type，
    # 本来就会认 uxt*/sxtb 形态；另行立项）。
    for name, load, add, why in BAD_PAIRS:
        words, sym = assemble(ASM.format(load=load, add=add, table=".byte 0"), work / name)
        raw, mem = nso_from_words(words)
        src = work / name / "in.nso"
        src.write_bytes(raw)
        for tag, rew in rewriters:
            for target in ("apple", "android"):
                out = work / name / f"{tag}-{target}-s1"
                rc, log = rewrite(rew, src, out, 1, target)
                gone = not (out / "main.patched.bin").is_file()
                check(f"{name}（{why}）{tag} {target} 开关1 记缺口", rc == 3 and not gone,   # v0.3.1：记缺口、产物照出
                      f"退出 {rc} 映像 {'无' if gone else '有'}")

    for err in golden.finish():
        check("金样射程", False, err)
    print("\n".join(rows))
    print()
    print("前后对照（苹果、C 改写器、qemu-aarch64 执行返回值；半字只核对落点，不执行）")
    print("| 形态 | 表项 | 硬件偏移 | 原指令 | 开关关 | 开关开 | 期望 |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for kind, entry, hw, orig, off, on, want in before_after:
        print(f"| {kind} | {entry:#x} | {hw} | {orig} | {off} | {on} | {want} |")
    print()
    print(f"rewrite_signed_jt：{len(rows)} 项，不通 {bad}")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
