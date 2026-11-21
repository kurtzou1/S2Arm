#!/usr/bin/env python3
"""tools/addr_need.py on synthetic NSO / NPDM (no game data): static alias claim, heap = application pool, no runs or tables.

Expected values are computed by hand: alias budget = claimed size + VammManager metadata (0x3FE00000, under 1 GiB)
rounded up to GiB, at most 63; constants under 4 GiB are not a claim; 普通堆MB is always 3284 (the application pool).
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))
import addr_need  # noqa: E402

PROGRAM, BUILD = "0100aaaa00000000", "ab" * 16
fails = 0


def check(name, want, got):
    global fails
    ok = want == got
    fails += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want}，实 {got}")


def budget(table):
    rows = dict(line.split("\t") for line in table.splitlines() if "\t" in line)
    return int(rows["别名区GB"]), int(rows["普通堆MB"])


# ① static alias claim (10-26: one pack is a complete pack, recognised from code, never from runs)
def nso(code_words, got_slot, plt_at, name=b"_ZN2nn2os21AllocateAddressRegionEPmm", more=()):
    """Uncompressed NSO with one import (nn::os::AllocateAddressRegion unless named) resolved through a PLT stub at plt_at;
    more = further (name, got_slot, plt_at) imports."""
    img = bytearray(0x4000)
    struct.pack_into("<I", img, 4, 0x100)                         # MOD0 offset
    img[0x100:0x104] = b"MOD0"; struct.pack_into("<i", img, 0x104, 0x100)   # dynamic at 0x200
    strtab, symtab, rela = 0x800, 0x900, 0xA00
    imports = ((name, got_slot, plt_at),) + tuple(more)
    at = strtab + 1
    for k, (nm, got, plt) in enumerate(imports, 1):
        img[at:at + len(nm) + 1] = nm + b"\0"
        struct.pack_into("<IBBHQQ", img, symtab + 24 * k, at - strtab, 0x12, 0, 0, 0, 0)    # symbol k, undefined
        struct.pack_into("<QQq", img, rela + 24 * (k - 1), got, (k << 32) | 1026, 0)       # R_AARCH64_JUMP_SLOT
        page = ((got & ~0xFFF) - (plt & ~0xFFF)) >> 12
        stub = [0x90000010 | ((page & 3) << 29) | (((page >> 2) & 0x7FFFF) << 5), 0xF9400211 | ((got & 0xFFF) // 8) << 10, 0xD61F0220]
        for i, w in enumerate(stub): struct.pack_into("<I", img, plt + 4 * i, w)
        at += len(nm) + 1
    for i, (tag, value) in enumerate(((5, strtab), (6, symtab), (23, rela), (2, 24 * len(imports)), (0, 0))):
        struct.pack_into("<qQ", img, 0x200 + 16 * i, tag, value)
    for at, w in code_words: struct.pack_into("<I", img, at, w)
    head = bytearray(0x100); head[:4] = b"NSO0"
    struct.pack_into("<III", head, 0x10, 0x100, 0, len(img))      # text segment = whole image
    struct.pack_into("<III", head, 0x20, 0x100 + len(img), len(img), 0)
    struct.pack_into("<III", head, 0x30, 0x100 + len(img), len(img), 0)
    struct.pack_into("<III", head, 0x60, len(img), 0, 0)
    return bytes(head) + bytes(img)

def bl(at, target): return 0x94000000 | (((target - at) // 4) & 0x3FFFFFF)
def movz(imm, hw): return 0xD2800000 | (hw << 21) | (imm << 5)   # movz x0, #imm, lsl #(16 * hw)
GIB60, GIB64, GIB3 = movz(0xF, 2), movz(0x10, 2), movz(0xC000, 1)   # 0xF << 32 = 60 GiB；0x10 << 32 = 64 GiB；0xC000 << 16 = 3 GiB
RET, PRO, PLT, GOT = 0xD65F03C0, 0xA9BF7BFD, 0x3000, 0x3800
MOV_62 = 0xB2400000 | (33 << 16) | (4 << 10) | 0x3E0 | 8      # mov x8, #0xF80000000（位掩码立即数：5 个 1 从第 31 位起）= 62 GiB
with tempfile.TemporaryDirectory(prefix="s2a-addr-static-") as d:
    def direct_call(name, word):
        p = Path(d) / name; p.write_bytes(nso([(0x1000, RET), (0x1004, word), (0x1008, bl(0x1008, PLT)), (0x100C, RET)], GOT, PLT)); return p
    direct, cap, small = direct_call("direct", MOV_62), direct_call("cap", GIB64), direct_call("small", GIB3)
    # 包装把尺寸参数 x0 挪进 x1 再调 AllocateAddressRegion（真包装的样子；上限判定按寄存器追来源，见 ⑤）
    wrapped = Path(d) / "wrapped"; wrapped.write_bytes(nso([(0x1000, RET), (0x1004, PRO), (0x1008, 0xAA0003E1), (0x100C, bl(0x100C, PLT)), (0x1010, RET),
                                                               (0x1014, GIB60), (0x1018, bl(0x1018, 0x1004)), (0x101C, RET)], GOT, PLT))
    plain = Path(d) / "plain"; plain.write_bytes(nso([(0x1000, RET), (0x1004, bl(0x1004, PLT)), (0x1008, RET)], GOT, PLT))
    # 62 + 元数据（<1 GiB）向上取整 → 63；60 经一层包装 → 61；64 + 元数据 = 65 → 封顶 63；3 GiB 不到 4 GiB 不算；无常量 → 0
    check("静态别名：直接 62GiB（UE4）/ 经一层包装 60GiB（xc3）/ 64GiB 封顶 63 / 3GiB 不算 / 没有大常量",
          (63, 61, 63, 0, 0), tuple(addr_need.static_alias_gb(x) for x in (direct, wrapped, cap, small, plain)))
    # 11-02 Torchlight III（UE4）：37 GiB 由 movz + movk 拼出（movz x0, #0x4000, lsl #16 = 1 GiB；movk x0, #9, lsl #32 → 0x940000000），
    #   包装函数序言是 str x23, [sp, #-0x40]!（不是 stp x29, x30 前移）。手算：37 GiB + 元数据（<1 GiB）向上取整 → 38。
    #   反例：movz 之后寄存器被别的指令改写再 movk → 不再是已知常量 → 0；movk 前没有 movz（寄存器值未知）→ 0
    MOVK9 = 0xF2800000 | (2 << 21) | (9 << 5)                      # movk x0, #9, lsl #32
    GIB1 = movz(0x4000, 1)                                         # movz x0, #0x4000, lsl #16 = 1 GiB
    STR_PRE = 0xF8000C00 | ((-0x40 & 0x1FF) << 12) | (31 << 5) | 23   # str x23, [sp, #-0x40]!
    ADD1 = 0x91000400                                              # add x0, x0, #1
    def caller_of_wrapper(name, prologue, body):
        p = Path(d) / name
        words = [(0x1000, RET), (0x1004, prologue), (0x1008, bl(0x1008, PLT)), (0x100C, RET)]
        at = 0x1010
        for w in body + [bl(at + 4 * len(body), 0x1004), RET]:
            words.append((at, w)); at += 4
        p.write_bytes(nso(words, GOT, PLT)); return p
    movk_direct = Path(d) / "movk-direct"; movk_direct.write_bytes(nso([(0x1000, RET), (0x1004, GIB1), (0x1008, MOVK9), (0x100C, bl(0x100C, PLT)), (0x1010, RET)], GOT, PLT))
    check("静态别名 movz + movk：直接 37GiB / 经 str 前移序言的包装 37GiB / 中间被改写 / 只有 movk",
          (38, 38, 0, 0), (addr_need.static_alias_gb(movk_direct),
                           addr_need.static_alias_gb(caller_of_wrapper("movk-wrapped", STR_PRE, [GIB1, MOVK9])),
                           addr_need.static_alias_gb(caller_of_wrapper("movk-clobbered", STR_PRE, [GIB1, ADD1, MOVK9])),
                           addr_need.static_alias_gb(caller_of_wrapper("movk-only", STR_PRE, [MOVK9]))))
    # 11-03 超级马力欧派对（nn::bezel）：VAMM 开着时 StandardAllocator::Initialize(nullptr, 0xE00000000, true) 只占地址 56 GiB，
    #   经两个尾调用小桩（mov w3, #1; b Initialize / b 包装）和两层包装，常量在第五层调用点前（main+0x981fc0 → 0x981fdc）。
    #   手算：56 GiB + 元数据（<1 GiB）向上取整 → 57。同一条链换成 AllocateAddressRegion 导入也是 57；链上没有 ≥4 GiB 常量 → 0
    MOVW3, B_ = 0x52800023, (lambda at, t: 0x14000000 | (((t - at) // 4) & 0x3FFFFFF))   # mov w3, #1；b t
    GIB56 = movz(0xE, 2)                                           # 0xE << 32 = 56 GiB
    def thunk_chain(name, imp, const):
        p = Path(d) / name
        p.write_bytes(nso([(0x1000, RET), (0x1004, MOVW3), (0x1008, B_(0x1008, PLT)),            # 小桩 1：mov w3, #1; b 导入
                           (0x100C, RET), (0x1010, PRO), (0x1014, bl(0x1014, 0x1004)), (0x1018, RET),   # 包装 1
                           (0x101C, B_(0x101C, 0x1010)),                                        # 小桩 2：b 包装 1
                           (0x1020, PRO), (0x1024, bl(0x1024, 0x101C)), (0x1028, RET),          # 包装 2（尺寸经结构体，调用点前没有常量）
                           (0x102C, const), (0x1030, bl(0x1030, 0x1020)), (0x1034, RET)], GOT, PLT, imp)); return p
    SA_INIT = b"_ZN2nn3mem17StandardAllocator10InitializeEPvmb"
    check("静态别名：分配器空地址初始化 56GiB 经两个尾调用小桩 + 两层包装 / 同链 AllocateAddressRegion / 链上只有 3GiB",
          (57, 57, 0), (addr_need.static_alias_gb(thunk_chain("sa-thunk", SA_INIT, GIB56)),
                        addr_need.static_alias_gb(thunk_chain("aar-thunk", b"_ZN2nn2os21AllocateAddressRegionEPmm", GIB56)),
                        addr_need.static_alias_gb(thunk_chain("sa-small", SA_INIT, GIB3))))
    # 大区来源（11-20，宿主分配器初始化闸）：同一条链，导入是分配器初始化 → 来源记分配器；是 AllocateAddressRegion → 不记（闸门压不了）；
    #   表里只有前者多一行「大区来源 分配器初始化」，后者与改前逐字节相同
    sa, aar = thunk_chain("sa-src", SA_INIT, GIB56), thunk_chain("aar-src", b"_ZN2nn2os21AllocateAddressRegionEPmm", GIB56)
    check("大区来源：分配器初始化链 (57, 是) / AllocateAddressRegion 链 (57, 否) / 链上只有 3GiB (0, 否)",
          ((57, True), (57, False), (0, False)), (addr_need.static_claim(sa), addr_need.static_claim(aar), addr_need.static_claim(thunk_chain("sa-src-small", SA_INIT, GIB3))))
    check("大区来源行：只在分配器初始化链的表里",
          (True, False), tuple("大区来源\t分配器初始化\n" in addr_need.collect(PROGRAM, BUILD, main=m) for m in (sa, aar)))
    # 11-05 瓦力欧制造 舞动（WarioWare: Move It!）：StandardAllocator::Initialize(nullptr, 60 GiB, true)（SDK 里 CentralHeap::Init →
    #   nnmem_nlib_virtual_alloc → AllocateAddressRegion）。形状照原件：调用方 mov x1, #60GiB; bl 包装；包装 stp 序言、mov x1, xzr、
    #   bl 小跳板；跳板 mov w3, #1; b 桩。手算：60 GiB + 元数据（<1 GiB）向上取整 → 61。nnmem_nlib_virtual_alloc 直接 60 GiB → 61。
    #   负对照：同样的 60 GiB 传给不认领地址区的导入（StandardAllocator::Allocate）→ 0
    MOV60_X1 = movz(0xF, 2) | 1                                    # movz x1, #0xF, lsl #32 = 60 GiB
    def wario(name, entry):
        p = Path(d) / name
        p.write_bytes(nso([(0x1000, RET), (0x1004, PRO), (0x1008, MOV_X1_XZR), (0x100C, bl(0x100C, 0x1018)), (0x1010, RET),
                           (0x1014, RET), (0x1018, MOVW3), (0x101C, B_(0x101C, PLT)),
                           (0x1020, RET), (0x1024, MOV60_X1), (0x1028, bl(0x1028, 0x1004)), (0x102C, RET)], GOT, PLT, entry)); return p
    MOV_X1_XZR = 0xAA1F03E1                                        # mov x1, xzr
    vdirect = Path(d) / "nlib-virtual"
    vdirect.write_bytes(nso([(0x1000, RET), (0x1004, MOV60_X1), (0x1008, bl(0x1008, PLT)), (0x100C, RET)], GOT, PLT, b"nnmem_nlib_virtual_alloc"))
    check("静态别名 SDK 分配器：StandardAllocator::Initialize(nullptr, 60GiB, true) 经包装 + 跳板 / nnmem_nlib_virtual_alloc 直接 / 非认领导入（负对照）",
          (61, 61, 0), (addr_need.static_alias_gb(wario("wario", SA_INIT)),
                        addr_need.static_alias_gb(vdirect),
                        addr_need.static_alias_gb(wario("not-claim", b"_ZN2nn3mem17StandardAllocator8AllocateEm"))))
    # 11-03 上限不定（维护者：证明不了就不收窗口）。每个 main 都带一处 62 GiB 常量认领（别名 63），再加一处只占地址的申请，尺寸来源不同：
    #   常量 → 读码有上限，表不加行；读内存（配置 / 全局，疯兔 main+0x2c4a29c 类）/ 运行时计算（疯兔 main+0x9a12e8 的 << 16 类）→ 上限不定；
    #   申请后紧跟 AllocateMemoryPages 整段提交（UE4 包装）→ 受应用池封顶，不算；分配器初始化：地址空（xzr）+ 尺寸读内存（血污 main+0x778c88）
    #   → 不定，地址是缓冲（读内存得来）→ 不占地址、不算
    AMP_NAME, AMP_PLT, AMP_GOT = b"_ZN2nn2os19AllocateMemoryPagesEmm", 0x3100, 0x3808
    SA_PLT, SA_GOT = 0x3200, 0x3810
    MOV_62_X1 = MOV_62 - 8 + 1                                     # mov x1, #0xF80000000
    MOV_X1_X0, LDR_X0, LDR_X2, ADD_X0, MOV_X1_ZR = 0xAA0003E1, 0xF9400040, 0xF9400022, 0x8B090100, 0xAA1F03E1   # mov x1, x0；ldr x0, [x2]；ldr x2, [x1]；add x0, x8, x9；mov x1, xzr
    def unbounded_case(name, tail):
        p = Path(d) / name
        words = [(0x1000, RET), (0x1004, MOV_62_X1), (0x1008, bl(0x1008, PLT)), (0x100C, RET),              # 62 GiB 常量认领（直接给 x1）
                 (0x1010, PRO), (0x1014, MOV_X1_X0), (0x1018, bl(0x1018, PLT)), (0x101C, RET)] + tail      # 包装：size 参数 x0 → x1 → 只占地址
        p.write_bytes(nso(words, GOT, PLT, more=((AMP_NAME, AMP_GOT, AMP_PLT), (SA_INIT, SA_GOT, SA_PLT)))); return p
    def rows(p):
        t = addr_need.collect(PROGRAM, BUILD, main=p)
        r = dict(line.split("\t", 1) for line in t.splitlines() if "\t" in line)
        return int(r["别名区GB"]), r.get("别名区上限", "有"), r.get("上限不定原因", "")
    GIB16 = movz(0x4, 2)                                           # 0x4 << 32 = 16 GiB
    cases = {
        "常量尺寸": [(0x1020, GIB16), (0x1024, bl(0x1024, 0x1010)), (0x1028, RET)],
        "读内存尺寸": [(0x1020, LDR_X0), (0x1024, bl(0x1024, 0x1010)), (0x1028, RET)],
        "运行时计算尺寸": [(0x1020, ADD_X0), (0x1024, bl(0x1024, 0x1010)), (0x1028, RET)],
        # 分配器两例里包装只被常量 16 GiB 调用（0x1040），不定只可能来自分配器那一处；没有直接调用者的包装本身就是「来源不明」
        "空地址分配器 + 读内存尺寸": [(0x1020, PRO), (0x1024, MOV_X1_ZR), (0x1028, LDR_X2), (0x102C, bl(0x102C, SA_PLT)), (0x1030, RET),
                                (0x1040, GIB16), (0x1044, bl(0x1044, 0x1010)), (0x1048, RET)],
        "带缓冲分配器 + 读内存尺寸": [(0x1020, PRO), (0x1024, LDR_X0), (0x1028, MOV_X1_X0), (0x102C, LDR_X2), (0x1030, bl(0x1030, SA_PLT)), (0x1034, RET),
                                (0x1040, GIB16), (0x1044, bl(0x1044, 0x1010)), (0x1048, RET)],
    }
    got = {k: rows(unbounded_case("ub-" + str(i), v))[:2] for i, (k, v) in enumerate(cases.items())}
    check("上限：常量 / 读内存 / 运行时计算 / 空地址分配器读内存尺寸 / 带缓冲分配器",
          {"常量尺寸": (63, "有"), "读内存尺寸": (63, "不定"), "运行时计算尺寸": (63, "不定"),
           "空地址分配器 + 读内存尺寸": (63, "不定"), "带缓冲分配器 + 读内存尺寸": (63, "有")}, got)
    committed = Path(d) / "ub-commit"
    committed.write_bytes(nso([(0x1000, RET), (0x1004, MOV_62_X1), (0x1008, bl(0x1008, PLT)), (0x100C, RET),
                               (0x1010, PRO), (0x1014, MOV_X1_X0), (0x1018, bl(0x1018, PLT)), (0x101C, bl(0x101C, AMP_PLT)), (0x1020, RET),
                               (0x1024, LDR_X0), (0x1028, bl(0x1028, 0x1010)), (0x102C, RET)], GOT, PLT, more=((AMP_NAME, AMP_GOT, AMP_PLT),)))
    _, bound, _ = rows(committed)
    why = rows(unbounded_case("ub-why", cases["读内存尺寸"]))[2]
    check("上限：申请后紧跟整段提交（读内存尺寸也算有上限）/ 原因写调用点与来源类别", ("有", True),
          (bound, "main+0x1018" in why and "读内存" in why and "@0x1020" in why))
    # 模仿真实控制流：预留成功后根据标志位跳过后续提交。操作码为自造，不带游戏文件。
    conditional = Path(d) / "ub-conditional-commit"
    TBZ_W2_BIT0_PLUS8 = 0x36000042
    conditional.write_bytes(nso([(0x1000, RET), (0x1004, MOV_62_X1), (0x1008, bl(0x1008, PLT)), (0x100C, RET),
                                 (0x1010, PRO), (0x1014, MOV_X1_X0), (0x1018, bl(0x1018, PLT)),
                                 (0x101C, TBZ_W2_BIT0_PLUS8), (0x1020, bl(0x1020, AMP_PLT)), (0x1024, RET),
                                 (0x1028, LDR_X0), (0x102C, bl(0x102C, 0x1010)), (0x1030, RET)],
                                GOT, PLT, more=((AMP_NAME, AMP_GOT, AMP_PLT),)))
    _, conditional_bound, conditional_reason = rows(conditional)
    check("上限：提交可被条件分支跳过时不能当整段提交", ("不定", True),
          (conditional_bound, "预留后提交是条件性的，地址可只预留" in conditional_reason))
    check("有静态认领：别名 = 静态结果，堆 = 应用池上限", (63, 3284), budget(addr_need.collect(PROGRAM, BUILD, main=direct)))
    check("包装认领：别名 61，堆 = 应用池上限", (61, 3284), budget(addr_need.collect(PROGRAM, BUILD, main=wrapped)))
    check("无静态认领：别名 0，堆 = 应用池上限", (0, 3284), budget(addr_need.collect(PROGRAM, BUILD, main=plain)))
    check("不给 main：别名 0，堆 = 应用池上限", (0, 3284), budget(addr_need.collect(PROGRAM, BUILD)))
    want = f"# 地址需求采集算法 2\n版本\t2\n程序号\t{PROGRAM}\n构建号\t{BUILD}\n别名区GB\t61\n普通堆MB\t3284\n"
    check("表格式：版本 2 五个字段、身份绑定、大写身份转小写", want, addr_need.collect(PROGRAM.upper(), BUILD.upper(), main=wrapped))
    try:
        addr_need.collect("0100", BUILD); check("无效程序号", "红", "无红")
    except ValueError:
        check("无效程序号", "红", "红")
    not_nso = Path(d) / "not-nso"; not_nso.write_bytes(b"XXXX" * 64)
    try:
        addr_need.static_alias_gb(not_nso)
        check("main 不是 NSO", "红", "无红")
    except ValueError:
        check("main 不是 NSO", "红", "红")

    # ② CLI: --key prints the fingerprint of exactly the table written; retired --table / --logs are rejected
    cli = [sys.executable, str(REPO / "tools/addr_need.py"), BUILD, str(Path(d) / "k.tsv"), "--program-id", PROGRAM, "--main", str(direct), "--key"]
    r = subprocess.run(cli, capture_output=True, text=True)
    written = (Path(d) / "k.tsv").read_text(encoding="utf-8") if r.returncode == 0 else ""
    check("命令行 --key：指纹 = 写出的表的 sha256、表里别名 63",
          (0, addr_need.fingerprint(written), (63, 3284)), (r.returncode, r.stdout.strip(), budget(written) if written else None))
    for retired in (["--table", str(Path(d) / "k.tsv")], ["--logs", str(Path(d) / "*.log")]):
        r = subprocess.run(cli + retired, capture_output=True, text=True)
        check(f"命令行 {retired[0]} 已退役：拒收", 2, r.returncode)

# ③ program id from exefs/main.npdm (#459: roots seeded for generic-only packs have no unpack.tsv)
def npdm(program, aci=0x80, sysres=0):
    b = bytearray(aci + 0x40); b[:4] = b"META"; b[0x70:0x74] = aci.to_bytes(4, "little"); b[0x14:0x18] = sysres.to_bytes(4, "little")
    b[aci:aci + 4] = b"ACI0"; b[aci + 0x10:aci + 0x18] = program.to_bytes(8, "little"); return bytes(b)
with tempfile.TemporaryDirectory(prefix="s2a-addr-npdm-") as d:
    good, at200, meta, aci = (Path(d) / n for n in ("good", "at200", "nometa", "noaci"))
    good.write_bytes(npdm(0x0100AAAA00000000)); at200.write_bytes(npdm(0x010019C00E9CC000, 0x200))
    meta.write_bytes(b"XXXX" + npdm(1)[4:]); aci.write_bytes(npdm(1).replace(b"ACI0", b"ACIX"))
    def red(x):
        try: addr_need.npdm_program(x); return "无红"
        except ValueError: return "红"
    check("npdm 程序号：META 指的 ACI0 +0x10（两个偏移）/ 缺 META、缺 ACI0 报红",
          ("0100aaaa00000000", "010019c00e9cc000", "红", "红"), (addr_need.npdm_program(good), addr_need.npdm_program(at200), red(meta), red(aci)))
    # 审计 P2-26：pack/srcs.sh prog_id（没有 unpack.tsv 时）与 npdm_program 同一种取法。反例：META 标题名（0x20 起）里碰巧有 ACI0 四字节，
    #   按「find 第一处」会读成标题名后面的字节；按 META +0x70 指的 ACI0 读才是 0100AAAA00000000（手算：ACI0 在 0x80，+0x10 处写入的值）
    decoy = bytearray(npdm(0x0100AAAA00000000)); decoy[0x20:0x24] = b"ACI0"; decoy[0x30:0x38] = (0x0100DEAD00000000).to_bytes(8, "little")
    (Path(d) / "root/exefs").mkdir(parents=True); (Path(d) / "root/exefs/main.npdm").write_bytes(bytes(decoy))
    r = subprocess.run(["bash", "-c", 'source "$1/pack/srcs.sh"; prog_id "$2"', "_", str(REPO), str(Path(d) / "root")],
                       capture_output=True, text=True, env={**__import__("os").environ, "S2A_NX_UNPACK": "/usr/bin/false"})
    check("srcs.sh prog_id：标题名里有 ACI0 诱饵，仍取 META 指的 ACI0（与 npdm_program 一致）",
          ("0100AAAA00000000", "0100AAAA00000000"), (r.stdout.strip(), addr_need.npdm_program(Path(d) / "root/exefs/main.npdm").upper()))
    r = subprocess.run([sys.executable, str(REPO / "tools/addr_need.py"), BUILD, str(Path(d) / "o.tsv"), "--npdm", str(good)],
                       capture_output=True, text=True)
    check("命令行 --npdm：只给 npdm 也出表、程序号取自 ACI0、堆 = 应用池上限", (0, True, True),
          (r.returncode, "程序号\t0100aaaa00000000" in r.stdout, "普通堆MB\t3284" in r.stdout))

# ③b VAMM 关（SystemResourceSize = 0，堆模式）时代码里的大常量是死代码：别名 0；开着才按静态认领（11-03 超级马力欧派对 010036B0034E4000）
with tempfile.TemporaryDirectory(prefix="s2a-addr-vamm-") as d:
    m = Path(d) / "main"; m.write_bytes(nso([(0x1000, RET), (0x1004, MOV_62), (0x1008, bl(0x1008, PLT)), (0x100C, RET)], GOT, PLT))
    def run(sr):
        n = Path(d) / f"npdm{sr}"; n.write_bytes(npdm(0x0100AAAA00000000, sysres=sr))
        r = subprocess.run([sys.executable, str(REPO / "tools/addr_need.py"), BUILD, str(Path(d) / "o.tsv"), "--npdm", str(n), "--main", str(m)],
                           capture_output=True, text=True)
        return budget(r.stdout)[0] if r.returncode == 0 else ("rc", r.returncode)
    check("命令行 --npdm：SystemResourceSize 0（VAMM 关）别名 0 / 0x1000000 按静态认领 63", (0, 63), (run(0), run(0x1000000)))

# ④ callers: no per-game table, no run logs, no previous table reach the collector
stage = (REPO / "pack/stage_rewrite.sh").read_text(encoding="utf-8")
build_py = (REPO / "pack/jobs/build.py").read_text(encoding="utf-8")
android = (REPO / "android/tools/make_pack.py").read_text(encoding="utf-8")
check("调用方不传 --table / --logs、不设 S2A_ADDR_*", (False, False, False, False, False),
      ("--table" in stage, "--logs" in stage, "S2A_ADDR_" in build_py, "--table" in android, "--logs" in android))

print(f"{'✓' if not fails else '✗'} addr_need_test：{fails} 处不符")
sys.exit(1 if fails else 0)
