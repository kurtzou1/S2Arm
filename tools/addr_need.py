#!/usr/bin/env python3
"""Write the identity-bound version 2 memory table from the program's code alone (no runs, no per-game tables).

别名区GB > 0 = the main NSO claims a huge alias address region at start-up (static_alias_gb), the host lays the
alias region out first; 0 otherwise. 普通堆MB is always the application pool, the bound SetHeapSize can never exceed.
"""
import argparse
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '.')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
import hashlib
from pathlib import Path
import re
import struct
import sys

ALGORITHM_VERSION = 2   # 11-03 识别面扩大不升号：表头进改写阶段键（stage_rewrite.sh addr=），升号会让每一款整段重改写；只有识别值真变的款表才变
GIB = 1 << 30
ALIAS_MAX_GB = 63      # Switch 39-bit address spaces give the alias region at most 64 GiB
APP_POOL_MB = 3284     # Switch application pool (3285 MiB), 2 MiB aligned: SetHeapSize can never legally exceed it (native.h S2A_HEAP_DEFAULT)
SDK_META = 0x3FE00000  # VammManager metadata at the start of the alias region; regions >= 1 GiB are GiB aligned after it
ADDRESS_REGION = "_ZN2nn2os21AllocateAddressRegionEPmm"
# 开局在别名区占大块地址的入口：AllocateAddressRegion，和 VAMM 开着时地址传空的 nn::mem::StandardAllocator 初始化（sdk 里
#   CentralHeap::Init(nullptr, size) → nnmem_nlib_virtual_alloc → AllocateAddressRegion(size)，只占地址、用到才提交）。
#   一款第一方派对游戏 main+0x981fc0 的 56 GiB 走的就是后者（0x981f9c → 0x981ccc → 0x98205c → 0x9820e8 → 0x98212c → Initialize）。
#   ≥ 4 GiB 的常量传给分配器初始化只能是空地址的 VAMM 预留：应用池 3285 MiB，带缓冲初始化给不出这么大的缓冲。
#   nnmem_nlib_virtual_alloc 是导出的中间层（参数同 AllocateAddressRegion：x0 出参、x1 尺寸），游戏直接调它也认
#   （瓦力欧制造 舞动 010045B018EC2000 的 60 GiB 走 StandardAllocator::Initialize(nullptr, 60 GiB, true)，11-05）
NLIB_VIRTUAL = "nnmem_nlib_virtual_alloc"
CLAIM_ENTRIES = (ADDRESS_REGION, NLIB_VIRTUAL, "_ZN2nn3mem17StandardAllocator10InitializeEPvm", "_ZN2nn3mem17StandardAllocator10InitializeEPvmb",
                 "_ZN2nn3mem17StandardAllocatorC1EPvm", "_ZN2nn3mem17StandardAllocatorC1EPvmb",
                 "_ZN2nn3mem17StandardAllocatorC2EPvm", "_ZN2nn3mem17StandardAllocatorC2EPvmb")


def identity(program, build):
    if not re.fullmatch(r"[0-9a-fA-F]{16}", program) or not re.fullmatch(r"(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{64})", build):
        raise ValueError("程序号或主程序构建标识无效")
    return program.lower(), build.lower()


def npdm_program(path):
    """Program id from exefs/main.npdm: the ACI0 block the META header points at (0x70), program id at +0x10."""
    data = Path(path).read_bytes()
    if len(data) < 0x78 or data[:4] != b"META":
        raise ValueError(f"{path} 不是 NPDM（缺 META 头）")
    offset = int.from_bytes(data[0x70:0x74], "little")
    if offset + 0x18 > len(data) or data[offset:offset + 4] != b"ACI0":
        raise ValueError(f"{path} META 指的 ACI0 不在（偏移 {offset:#x}）")
    return "%016x" % int.from_bytes(data[offset + 0x10:offset + 0x18], "little")


def _nso_image(path):
    import lz4.block
    raw = Path(path).read_bytes()
    if raw[:4] != b"NSO0":
        raise ValueError("不是 NSO：" + str(path))
    raw = _nso_plain(raw, str(path))
    flags, image, segments = struct.unpack_from("<I", raw, 0xC)[0], bytearray(), []
    for k, (header, csize) in enumerate(((0x10, 0x60), (0x20, 0x64), (0x30, 0x68))):
        offset, memory, size = struct.unpack_from("<III", raw, header)
        data = raw[offset:offset + struct.unpack_from("<I", raw, csize)[0]]
        data = lz4.block.decompress(data, uncompressed_size=size) if flags & (1 << k) else data
        if len(image) < memory + size:
            image.extend(bytes(memory + size - len(image)))
        image[memory:memory + size] = data
        segments.append((memory, size))
    return image, segments


def _import_stubs(image, text, name):
    """PLT stubs (adrp x16 / ldr x17, [x16, #slot]) whose GOT slot is the relocation of the named import (or of any of
    several names: one pass over the text)."""
    return set(_import_stub_names(image, text, (name,) if isinstance(name, str) else name))


def _import_stub_names(image, text, names):
    """{PLT 桩地址: 导入名}，一趟扫完代码段。"""
    names = {n.encode() for n in names}
    mod0 = struct.unpack_from("<I", image, 4)[0]
    dynamic, tags = mod0 + struct.unpack_from("<i", image, mod0 + 4)[0], {}
    while True:
        tag, value = struct.unpack_from("<qQ", image, dynamic)
        dynamic += 16
        if tag == 0:
            break
        tags.setdefault(tag, value)
    if 5 not in tags or 6 not in tags:
        return {}
    slots = {}
    for base, size in ((tags.get(23), tags.get(2)), (tags.get(7), tags.get(8))):
        for k in range((size or 0) // 24 if base else 0):
            offset, info, _ = struct.unpack_from("<QQq", image, base + k * 24)
            if info >> 32:
                at = tags[5] + struct.unpack_from("<I", image, tags[6] + (info >> 32) * 24)[0]
                symbol = bytes(image[at:image.index(b"\0", at)])
                if symbol in names:
                    slots[offset] = symbol.decode()
    lo, size = text
    stubs = {}
    for a in range(lo, lo + size - 8, 4):
        w0, w1 = struct.unpack_from("<II", image, a)
        if (w0 & 0x9F00001F) == 0x90000010 and (w1 & 0xFFC003FF) == 0xF9400211:
            imm = (((w0 >> 5) & 0x7FFFF) << 2) | ((w0 >> 29) & 3)
            imm -= (1 << 21) if imm & (1 << 20) else 0
            slot = (a & ~0xFFF) + (imm << 12) + ((w1 >> 10) & 0xFFF) * 8
            if slot in slots:
                stubs[a] = slots[slot]
    return stubs


def _bitmask(n, immr, imms):
    length = (n << 6 | (~imms & 0x3F)).bit_length() - 1
    if length < 1:
        return None
    size = 1 << length
    s, r = imms & (size - 1), immr & (size - 1)
    if s == size - 1:
        return None
    element = (1 << (s + 1)) - 1
    element = ((element >> r) | (element << (size - r))) & ((1 << size) - 1)
    return sum(element << (i * size) for i in range(64 // size))


def _move_immediate(word):
    if (word & 0xFF800000) == 0xD2800000:   # movz xN, #imm16, lsl #(16 * hw)
        return ((word >> 5) & 0xFFFF) << (16 * ((word >> 21) & 3))
    if (word & 0xFF8003E0) == 0xB20003E0:   # mov xN, #bitmask (orr xN, xzr, #imm)
        return _bitmask((word >> 22) & 1, (word >> 16) & 0x3F, (word >> 10) & 0x3F)
    return None


def _register_constants(block):
    """Constants the straight-line block leaves in registers, in order: movz / mov-bitmask set a register, movk patches
    16 bits of a register already known (Torchlight III: movz x0, #0x4000, lsl #16; movk x0, #9, lsl #32 = 37 GiB);
    any other instruction forgets its low-5-bit register (conservative: only ever loses a value, never invents one)."""
    known = {}
    for word in block:
        register, value = word & 0x1F, _move_immediate(word)
        if value is None and (word & 0xFF800000) == 0xF2800000 and register in known:   # movk xN, #imm16, lsl #(16 * hw)
            shift = 16 * ((word >> 21) & 3)
            value = known[register] & ~(0xFFFF << shift) | ((word >> 5) & 0xFFFF) << shift
        if value is None:
            known.pop(register, None)
        else:
            known[register] = value
            yield value


class _Code:
    """main 的代码段：按地址取字、B / BL 反查调用者、函数起点（序言 / 尾调用小桩）。识别大区与判上限共用。"""

    def __init__(self, main):
        self.image, self.segments = _nso_image(main)
        self.lo, size = self.segments[0]
        self.words = struct.unpack_from("<%dI" % (size // 4), self.image, self.lo)
        self.callers = {}
        for i, word in enumerate(self.words):
            if (word & 0x7C000000) == 0x14000000:   # B / BL
                offset = word & 0x3FFFFFF
                offset -= (1 << 26) if offset & (1 << 25) else 0
                self.callers.setdefault(self.lo + 4 * (i + offset), []).append(self.lo + 4 * i)

    def word_at(self, address):
        return self.words[(address - self.lo) // 4]

    @staticmethod
    def boundary_word(word):
        return word in (0xD65F03C0, 0xD503201F, 0) or (word & 0xFC000000) == 0x14000000

    @staticmethod
    def branch_word(word):
        """任何改变控制流的指令：B / BL / B.cond / CBZ / CBNZ / TBZ / TBNZ / BR / BLR / RET。"""
        return (word & 0x7C000000) == 0x14000000 or (word & 0x7E000000) in (0x34000000, 0x36000000) \
            or (word & 0xFF000010) == 0x54000000 or (word & 0xFE1FFC1F) == 0xD61F0000

    def function_start(self, address):
        # 尾调用小桩（一款第一方派对游戏 0x98212c：mov w3, #1; b Initialize）：B 之前几条都不是分支、再往前是 ret / b / udf，桩从那之后起
        if (self.word_at(address) & 0xFC000000) == 0x14000000:
            for k in range(0, 4):
                at = address - 4 * k
                if at <= self.lo:
                    break
                if self.boundary_word(self.word_at(at - 4)):
                    return at
                if self.branch_word(self.word_at(at - 4)):
                    break
        for k in range(1, 4096):
            at = address - 4 * k
            if at <= self.lo:
                return self.lo
            word, before = self.word_at(at), self.word_at(at - 4)
            # stp xA, xB, [sp, #-n]! / str xN, [sp, #-n]!（Torchlight III 包装：str x23, [sp, #-0x40]!）/ sub sp, sp, #n
            prologue = ((word & 0xFFC003E0) == 0xA98003E0 and word & (1 << 21)) or ((word & 0xFFE00FE0) == 0xF8000FE0 and word & (1 << 20)) \
                or (word & 0xFF0003FF) == 0xD10003FF
            if prologue and self.boundary_word(before):
                return at
        return None


def static_alias_gb(main, depth=6, window=16, wrapper_max=96, code=None):
    """Alias budget the program claims at start-up, read from its code: the largest constant size (>= 4 GiB, whole GiB)
    passed to nn::os::AllocateAddressRegion or to an nn::mem::StandardAllocator initialisation (CLAIM_ENTRIES), directly or
    through short wrappers and tail-call thunks that pass the size on (UE4 FSwitchPlatformMemory 62 GiB, Xenoblade 3 60 GiB
    through three levels, Super Mario Party Jamboree 56 GiB through five). Budget = size + VammManager metadata, GiB
    rounded, at most ALIAS_MAX_GB; 0 when no such call is found."""
    return static_claim(main, depth, window, wrapper_max, code)[0]


ALLOCATOR_ENTRIES = frozenset(n for n in CLAIM_ENTRIES if n.startswith("_ZN2nn3mem17StandardAllocator"))


def static_claim(main, depth=6, window=16, wrapper_max=96, code=None):
    """(别名预算 GB, 大区是否经 StandardAllocator 初始化申请)：同 static_alias_gb，另记最大那个常量是顺着哪类入口找到的
    （包装函数继承它所调入口的类别）。经分配器初始化的大区宿主开局闸门压得了（runtime/src/svc_mem.c s2a_sainit_gate），
    直接 AllocateAddressRegion / nnmem_nlib_virtual_alloc 的不能压；两类同为最大时按不能压记。"""
    c = code or _Code(main)
    members = {at: name in ALLOCATOR_ENTRIES for at, name in _import_stub_names(c.image, c.segments[0], CLAIM_ENTRIES).items()}
    seen, largest, alloc = set(), 0, False
    for _ in range(depth):
        wrappers = {}
        for member, via_alloc in members.items():
            for site in c.callers.get(member, ()):
                if site in seen:
                    continue
                seen.add(site)
                block = []
                for k in range(1, window + 1):
                    word = c.word_at(site - 4 * k)
                    if (word & 0x7C000000) == 0x14000000 or word == 0xD65F03C0:
                        break
                    block.insert(0, word)
                found = max((v for v in _register_constants(block) if v >= 4 * GIB and v % GIB == 0 and v < (1 << 39)), default=0)
                if found:
                    if found > largest:
                        largest, alloc = found, via_alloc
                    elif found == largest:
                        alloc = alloc and via_alloc
                    continue
                start = c.function_start(site)
                if start is not None and (site - start) // 4 <= wrapper_max:
                    wrappers[start] = wrappers.get(start, True) and via_alloc
        members = wrappers
        if not members:
            break
    return (min(ALIAS_MAX_GB, (largest + SDK_META + GIB - 1) // GIB), alloc) if largest else (0, False)


# ---------- 上限不定（11-03 维护者：证明不了就不收窗口，宁慢不崩）----------
# 别名区收到窗口末的前提是：开局大区之外，游戏活着的地址区总量有上限。只占地址、不提交的申请，尺寸若不是代码里的常量
#   （读配置 / 全局 / 结构体、运行时算出来、来源不明），读码就给不出上限——这类款判「上限不定」，布局照旧承诺 64 GiB + 远端。
#   整段提交的申请（AllocateAddressRegion 后紧跟 AllocateMemoryPages）受应用池封顶，不算。
#   StandardAllocator 初始化只有地址参数是空（xzr / #0）才占别名区；带缓冲（地址来自分配结果 / 静态缓冲）只用那块缓冲，不占地址。
COMMIT_ENTRY = "_ZN2nn2os19AllocateMemoryPagesEmm"


def _gpr_writes(word):
    """这条指令写哪些通用寄存器（0–30；31 = sp / xzr 不算）。None = 认不出（按「运行时计算」处理，只会更保守）。"""
    rd, rn, rt2 = word & 31, (word >> 5) & 31, (word >> 10) & 31
    def only(*regs): return {r for r in regs if r != 31}
    if (word & 0x1C000000) == 0x14000000:                                   # 分支 / 异常 / 系统
        if (word & 0xFC000000) == 0x94000000 or (word & 0xFFFFFC1F) == 0xD63F0000:
            return {30}                                                      # BL / BLR
        if (word & 0xFFF00000) == 0xD5300000:
            return only(rd)                                                  # MRS
        return set()
    if (word & 0x1C000000) == 0x10000000:                                    # 数据处理（立即数）
        return only(rd)
    if (word & 0x0E000000) == 0x0A000000:                                    # 数据处理（寄存器）
        return only(rd)
    if (word & 0x0A000000) == 0x08000000:                                    # 读写内存
        vector = bool(word & (1 << 26))
        if (word & 0x3B000000) == 0x18000000:                                # 字面量取数
            return set() if vector else only(rd)
        if (word & 0x3A000000) == 0x28000000:                                # 成对
            writes = only(rn) if (word >> 23) & 1 else set()                 # 前 / 后变址写回基址
            if (word >> 22) & 1 and not vector:
                writes |= only(rd, rt2)
            return writes
        if (word & 0x3B000000) == 0x39000000 or (word & 0x3B200000) == 0x38000000 or (word & 0x3B200C00) == 0x38200800:
            writes = only(rn) if (word & 0x3B200000) == 0x38000000 and (word >> 10) & 1 else set()
            opc, sz = (word >> 22) & 3, word >> 30
            if opc and not vector and not (sz == 3 and opc == 2):           # 取数（prfm 除外）
                writes |= only(rd)
            return writes
        if (word & 0x3F000000) == 0x08000000:                                # 独占
            return only(rd) if (word >> 22) & 1 else only((word >> 16) & 31)
        if (word & 0x3B200C00) == 0x38200000:                                # LSE 原子
            return only(rd)
        return None
    if (word & 0x7F3FFC00) in (0x1E260000, 0x9E660000) or (word & 0xBFE0FC00) == 0x0E003C00:
        return only(rd)                                                      # fmov / umov 到通用寄存器
    return set() if (word & 0x0E000000) in (0x0E000000, 0x0C000000) else None


def _source_kind(word, reg):
    """reg 的最后写入者是 word：('常量', 值) / ('寄存器', 来源号) / ('读内存', 说明) / ('计算', 说明)。"""
    if (word & 0x7F800000) == 0x52800000:                                    # movz
        return "常量", ((word >> 5) & 0xFFFF) << (16 * ((word >> 21) & 3))
    if (word & 0x7F800000) == 0x12800000:                                    # movn
        v = ~(((word >> 5) & 0xFFFF) << (16 * ((word >> 21) & 3)))
        return "常量", v & ((1 << 64) - 1 if word >> 31 else (1 << 32) - 1)
    if (word & 0x7F8003E0) == 0x320003E0:                                    # mov #位掩码（orr rd, zr, #imm）
        v = _bitmask((word >> 22) & 1, (word >> 16) & 0x3F, (word >> 10) & 0x3F)
        return ("常量", v) if v is not None else ("计算", "位掩码立即数")
    if (word & 0x7FE0FFE0) == 0x2A0003E0:                                    # mov rd, rm（orr rd, zr, rm）
        rm = (word >> 16) & 31
        return ("常量", 0) if rm == 31 else ("寄存器", rm)
    if (word & 0x7FFFFC00) == 0x11000000:                                    # add rd, rn, #0（mov 与 sp 互拷）
        return "寄存器", (word >> 5) & 31
    if (word & 0x0A000000) == 0x08000000:
        return "读内存", "取数（配置 / 全局 / 结构体）"
    return "计算", "运行时计算"


def _trace(code, site, reg, depth, budget):
    """调用点 site 处 reg 的全部来源（逐条路径到头）：列表 [(类别, 值或说明, 落点)]。参数沿调用者往上追，最多 depth 层。"""
    out, x, movk = [], site - 4, None
    start = code.function_start(site)
    while True:
        if budget[0] <= 0:
            return [("不明", "追踪步数用完", site)]
        budget[0] -= 1
        if start is not None and x < start:                                  # 到函数头还没写：是参数
            if reg > 7:
                return [("不明", f"x{reg} 进函数前就有（非参数寄存器）", start)]
            if depth <= 0:
                return [("不明", "调用链过深", start)]
            callers = code.callers.get(start, [])
            if not callers:
                return [("不明", "间接调用（无直接调用者）", start)]
            for c in callers:
                out += _trace(code, c, reg, depth - 1, budget)
            return out
        if x < code.lo:
            return [("不明", "越过代码段", x)]
        word = code.word_at(x)
        if code.branch_word(word) and not (word & 0xFC000000) == 0x94000000:
            return [("不明", "控制流汇合", x)]
        writes = _gpr_writes(word)
        if writes is None:
            return [("计算", "认不出的指令", x)]
        if (word & 0xFC000000) == 0x94000000 and reg in range(0, 19):
            return [("计算", "调用返回值", x)] if reg == 0 else [("不明", "调用后易失寄存器", x)]
        if reg in writes:
            if (word & 0x7F800000) == 0x72800000:                            # movk：先记下这 16 位，再找更早的 movz
                movk = (movk or []) + [word]
                x -= 4
                continue
            kind, value = _source_kind(word, reg)
            if kind == "寄存器":
                if movk:
                    return [("计算", "movk 拼在寄存器拷贝上", x)]
                reg = value
                x -= 4
                continue
            if kind == "常量" and movk:
                for k in reversed(movk):
                    sh = 16 * ((k >> 21) & 3)
                    value = value & ~(0xFFFF << sh) | ((k >> 5) & 0xFFFF) << sh
            elif movk:
                return [("计算", "movk 拼在非常量上", x)]
            return [(kind, value, x)]
        x -= 4


def alias_unbounded(main, depth=6, code=None):
    """只占地址、尺寸不是常量的申请：[(调用点, 类别, 说明)]；空 = 读码给得出上限。"""
    c = code or _Code(main)
    stubs = _import_stub_names(c.image, c.segments[0], CLAIM_ENTRIES + (COMMIT_ENTRY,))
    commit = {s for s, n in stubs.items() if n == COMMIT_ENTRY}
    reasons = []
    for stub, name in sorted(stubs.items()):
        if name == COMMIT_ENTRY:
            continue
        for site in sorted(c.callers.get(stub, ())):
            if name in (ADDRESS_REGION, NLIB_VIRTUAL):
                # 紧跟整段提交（24 条以内、遇 ret 停）：受应用池封顶
                committed = False
                conditional_commit = False
                saw_condition = False
                for k in range(1, 25):
                    w = c.word_at(site + 4 * k)
                    if w == 0xD65F03C0:
                        break
                    # 有条件跳转可绕过提交；线性扫描看到调用不等于每条成功路径都会提交。
                    if (w & 0x7E000000) in (0x34000000, 0x36000000) or (w & 0xFF000010) == 0x54000000:
                        saw_condition = True
                    elif c.branch_word(w) and (w & 0xFC000000) != 0x94000000:
                        break  # 无条件跳转 / 间接跳转后顺序字节不一定可达
                    if (w & 0xFC000000) == 0x94000000:
                        off = w & 0x3FFFFFF
                        off -= (1 << 26) if off & (1 << 25) else 0
                        if site + 4 * (k + off) in commit:
                            committed = not saw_condition
                            conditional_commit = saw_condition
                            break
                if committed:
                    continue
                size_reg = 1
            else:
                addr = _trace(c, site, 1, depth, [4000])
                if not any(kind == "常量" and value == 0 for kind, value, _ in addr):
                    continue                                                 # 带缓冲：不占别名区
                size_reg = 2
            for kind, value, at in _trace(c, site, size_reg, depth, [4000]):
                if kind != "常量":
                    detail = f"{value}@{at:#x}"
                    if name in (ADDRESS_REGION, NLIB_VIRTUAL) and conditional_commit:
                        detail += "；预留后提交是条件性的，地址可只预留"
                    reasons.append((site, kind, detail))
    return reasons


def npdm_system_resource(path):
    """SystemResourceSize from exefs/main.npdm (META +0x14, same field runtime/src/svc_mem.c npdm_read reads). 0 = the
    process has no system resource, so nn::os virtual address memory (VAMM) is off: AllocateAddressRegion and the
    null-address allocator path never run, whatever constants the code holds (Super Mario Party 010036B0034E4000: heap
    mode, 3222 MB heap, the bezel engine's 60 GiB VAMM branch is dead code)."""
    data = Path(path).read_bytes()
    if len(data) < 0x18 or data[:4] != b"META":
        raise ValueError(f"{path} 不是 NPDM（缺 META 头）")
    return int.from_bytes(data[0x14:0x18], "little")


def collect(program, build, main=None, vamm=True):
    """The table of one identity: alias = the static claim of main (0 without main or claim, or with VAMM off),
    heap = APP_POOL_MB. With a claim, address requests whose size has no static bound add 别名区上限 = 不定 and the
    reasons (call site, source kind): the host then keeps the 64 GiB promise instead of fitting the alias region into
    its window (runtime/src/layout.c). Tables without such requests are byte-identical to before."""
    program, build = identity(program, build)
    alias, reasons, via_alloc = 0, [], False
    if main and vamm:
        code = _Code(main)
        alias, via_alloc = static_claim(main, code=code)
        reasons = alias_unbounded(main, code=code) if alias else []
    if alias:
        print(f"地址需求静态来源：{main} 开局在别名区申请大块地址区，别名预算 {alias} GB（别名优先，堆在宿主按窗口预算让位）", file=sys.stderr)
    table = (f"# 地址需求采集算法 {ALGORITHM_VERSION}\n版本\t2\n程序号\t{program}\n构建号\t{build}\n"
             f"别名区GB\t{alias}\n普通堆MB\t{APP_POOL_MB}\n")
    if alias and via_alloc:
        # 大区经分配器初始化申请：宿主闸门放不下时压小、不弹「地址不够」页（svc_mem.c）。只有这类款的表多这一行，其余逐字节同前
        table += "大区来源\t分配器初始化\n"
    if reasons:
        # 一行不超过 400 字节（安卓读表单行上限 511，layout_android.inc）：放得下几处列几处，其余计数
        items = [f"main+{site:#x} {kind}（{detail}）" for site, kind, detail in reasons]
        for n in range(len(items), 0, -1):
            more = f"；另 {len(items) - n} 处" if n < len(items) else ""
            line = f"只占地址、尺寸非常量的申请 {len(items)} 处：" + "；".join(items[:n]) + more
            if len(line.encode()) <= 400:
                break
        table += f"别名区上限\t不定\n上限不定原因\t{line}\n"
    return table


def fingerprint(table):
    return hashlib.sha256(table.encode("utf-8")).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build")
    parser.add_argument("output", type=Path)
    who = parser.add_mutually_exclusive_group(required=True)
    who.add_argument("--program-id")
    who.add_argument("--npdm", type=Path, help="exefs/main.npdm: the program id is its ACI0 (every root has it, with or without unpack.tsv)")
    parser.add_argument("--main", type=Path, help="the program's original main NSO, for the static alias claim")
    parser.add_argument("--key", action="store_true")
    args = parser.parse_args()
    try:
        table = collect(args.program_id or npdm_program(args.npdm), args.build, args.main,
                        vamm=npdm_system_resource(args.npdm) > 0 if args.npdm else True)
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, "【红】地址需求采集失败：" + str(error) + "\n")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(table, encoding="utf-8", newline="\n")   # Windows 文本模式缺省写 CRLF：与 Mac 产物逐字节同
    print(fingerprint(table) if args.key else table, end="\n" if args.key else "")


if __name__ == "__main__":
    main()
