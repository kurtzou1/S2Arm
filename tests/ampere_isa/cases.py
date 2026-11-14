#!/usr/bin/env python3
"""Switch 2（Ampere，sm_86）指令单测：合成的 NVN2 片元着色器照出包（S2A.Dsh DshCompiler.Compile，经 dsh_cmp --fn ampere_compile）翻成 MSL，在 GPU 上画 1 个像素读回（frag_run.m）。
每例：先从常量缓冲 c[3] 读输入进寄存器（输入不能写成立即数：翻译器会在 C# 里把常量运算折掉，GPU 上就没测到发射出的运算），跑受测指令，R0..R3 按 uint 写出目标 0。
期望值按公开规格手算（不跑被测实现）：浮点位型用 struct 打包；整数按 PTX ISA / NAK（Mesa，MIT）的语义式子。编码字段按 NAK sm70_encode.rs 与 pokopia-recomp 的反汇编器
（SPDX MIT，字段经 nvdisasm 核过）——每例注释写出所依字段。
用法：cases.py <frag_run 可执行> [--list] [--filter 正则]；DSH_CMP_DLL 指定被测翻译器（缺省按 dshfn.py 现编）。退出码 0 = 全过。
负对照（去掉修复必红）：DSH_CMP_DLL 指向改动前的翻译器跑同一批例，标了 new 的例必须红（翻不过或结果不符），见 02_Ampere指令集_报告.md 的读数"""
import json, os, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '../..'))
sys.path.insert(0, os.path.join(ROOT, 'graphics/tools/direct/tests')); import dshfn

# ---- 编码（128 位指令；字段 [lo, hi)） ----
PT, RZ, URZ = 7, 255, 63
def inst(op12, **f):
    """守卫 PT（12..15）、调度位：停 1 拍（105..109）、不设写 / 读屏障（110..113 / 113..116 = 7，翻译器的记分板模型据此不推迟写回）、不等屏障（116..122 = 0）"""
    v = op12 | PT << 12 | 1 << 105 | 7 << 110 | 7 << 113
    for _, (lo, val) in f.items(): v |= (val & ((1 << 64) - 1)) << lo
    return v
def alu(op9, form, rd=RZ, ra=RZ, **f): return inst(op9 | form << 9, rd=(16, rd), ra=(24, ra), **f)
def MOVC(rd, word): return alu(0x002, 5, rd, off=(38, 4 * word), bank=(54, 3), m=(72, 0xf))   # MOV Rd, c[3][4·word]（NAK OpMov：源在 32..64 槽，四车道掩码 72..76 = 0xf）
def MOVI(rd, imm): return alu(0x002, 4, rd, imm=(32, imm), m=(72, 0xf))
def MOVU(rd, ur): return alu(0x002, 6, rd, ur=(32, ur), m=(72, 0xf))   # MOV Rd, URb（形式 6）
def ULDC(urd, word): return inst(0xab9, urd=(16, urd), off=(38, 4 * word), bank=(54, 3), size=(73, 4))   # ULDC.32 URd, c[3][4·word]（NAK OpLdc 统一数据通路）
EXIT = inst(0x94d, c=(87, PT))
def R(rb): return {'rb': (32, rb)}   # 形式 1 的第二源（32..40）

def f32(v): return struct.unpack('<I', struct.pack('<f', v))[0]
def f64(v): lo, hi = struct.unpack('<II', struct.pack('<d', v)); return lo, hi
def f16(v): return struct.unpack('<H', struct.pack('<e', v))[0]
def u32(v): return v & 0xffffffff

def shader(body):
    """SPH 第 4 版 0x80 字节（前 0x50 按第 3 版：字 0 = 类型 2（片元）| 版本 3 << 5 | 阶段 5 << 10，字 18 = 目标 0 的 RGBA 输出），指令，补齐到 0x80；
    NVN2 控制段 0xd8 字节：魔数、版本 0xc9、+0x38 指令区长、+0x40 / +0x44 c1 段起止（空）= 代码区长、+0x56 阶段 1（片元）（ns2_shaders.py / Dsh.cs Nvn2Job 读的就是这些）"""
    sph = bytearray(0x80); struct.pack_into('<I', sph, 0, 2 | 3 << 5 | 5 << 10); struct.pack_into('<I', sph, 18 * 4, 0xf)
    code = bytes(sph) + b''.join(i.to_bytes(16, 'little') for i in body + [EXIT]); code += bytes(-len(code) % 0x80)
    ctl = bytearray(0xd8); struct.pack_into('<II', ctl, 0, 0x98761234, 0xc9); struct.pack_into('<I', ctl, 0x38, len(code))
    struct.pack_into('<II', ctl, 0x40, len(code), len(code)); ctl[0x56] = 1
    return code, bytes(ctl)

CASES = []   # (名, 是否本次新增（负对照里必须红）, 输入字, 指令, 期望 R0..R3, 依据, 贴图（frag_run -T 形式:元素数）或 None)
def case(name, new, inputs, body, want, why, tex=None): CASES.append((name, new, [u32(v) for v in inputs], body, [u32(v) for v in want], why, tex))

# ---- #1590 Maxwell SHF：点名的 InstEmitShift.EmitShf，不走 Ampere AShf ----
# 32位取模零值语义：https://docs.nvidia.com/cuda/parallel-thread-execution/#logic-and-shift-instructions-shf
# Maxwell 字段/取高低字另核 Mesa NAK OpShf.fold（sm<70 分支），不是由 PTX.b32 推出独立 SASS.HI/LO：
# https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/b1fe47e94409d81924c8663f58fac97e66ab4527/src/nouveau/compiler/nak/ir.rs#4501
def maxwell_shader(body):
    """NVN1：0x30 记录头 + 0x50 SPH；每组一个调度字和三条 64 位指令。
    编码字段与 InstShfL/RR/LI/RI、InstLopC 对齐；输入来自 c[3]，不把数据常量折叠掉。
    """
    ops = body + [0xe30000000007000f]
    n = (len(ops) + 2) // 3 * 3
    code = bytearray(0x30 + 0x50 + n // 3 * 32)
    struct.pack_into('<I', code, 0x30, 2 | 3 << 5 | 5 << 10)
    struct.pack_into('<I', code, 0x30 + 72, 0xf)
    for i in range(n):
        struct.pack_into('<Q', code, 0x80 + (i // 3 * 4 + i % 3 + 1) * 8,
                         ops[i] if i < len(ops) else 0xe30000000007000f)
    ctl = bytearray(0x880)
    struct.pack_into('<II', ctl, 0x700, len(code), len(code))
    return ('ps', bytes(code), bytes(ctl))


def maxwell_shf(left, wrap, wide, immediate, count):
    # LOP.PASS_B R4/R5/R6, RZ, c[3][word*4]；保留运行期 A/C/寄存器移位量。
    def load(rd, word):
        return 0x4c40000000000000 | 7 << 48 | 3 << 41 | 3 << 34 | word << 20 | 7 << 16 | 255 << 8 | rd
    inputs, body = [], []
    pairs = [(0x01234567, 0x89abcdef), (0x80000001, 0x12345678), (0xffffffff, 0), (0, 0xffffffff)]
    for lane, (a, c) in enumerate(pairs):
        inputs += [a, c, count]
        body += [load(4, 3 * lane), load(5, 3 * lane + 1)]
        if not immediate: body += [load(6, 3 * lane + 2)]
        op = (0x36f8000000000000 if left else 0x38f8000000000000) if immediate else (0x5bf8000000000000 if left else 0x5cf8000000000000)
        body += [op | wrap << 50 | 5 << 39 | wide << 37 | (count if immediate else 6) << 20 | 7 << 16 | 4 << 8 | lane]
    # 独立期望：把 {C:A} 当一个 64 位整数移位、取高/低字；不调用编码器/翻译器求答案。
    limit = 64 if wide else 32
    n = count & (limit - 1) if wrap else min(count, limit)
    want = []
    for a, c in pairs:
        value = c << 32 | a
        if not left and wide == 3 and c >> 31: value -= 1 << 64
        want += [u32((value << n) >> 32 if left else value >> n)]
    return inputs, maxwell_shader(body), want, n


for left in (True, False):
    for wide, mode in ((0, 'u32'), (2, 'u64'), (3, 's64')):
        for wrap in (True, False):
            for immediate in (True, False):
                counts = [0, 1, 31, 32] if wrap or wide else [0, 1, 31]
                if wrap and not immediate: counts += [64]
                for count in counts:
                    inp, body, want, n = maxwell_shf(left, wrap, wide, immediate, count)
                    # new 指须旧 DLL 负控击中的零值缺陷；非零是本片新增的边界正控。
                    case(f'maxwell_shf_{"l_hi" if left else "r_lo"}_{mode}_{"wrap" if wrap else "clamp"}_{"imm" if immediate else "reg"}_{count}', n == 0,
                         inp, body, want, '64位整数字段独立期望；零值缺陷/非零正控；默认32位clamp端点另待规格裁决')


# ---- #798 Maxwell FMUL / FFMA .FMZ（InstEmitFloatArithmetic EmitFmz，不走 Ampere AFmz）：积里有一个因子是 0，积就是 0（D3D9 规则，Inf / NaN × 0 = 0）----
#   编码按 Ryujinx 解码器（InstDecoders.cs InstFmulR / InstFfmaR）：FMUL R = 0101110001101…（0x5c68 << 48），Rd 0..8、Ra 8..16、Rb 20..28、守卫 16..19 = PT、
#   .FMZ = 44..46 取 2、乘数缩放 41..44 = 0（不缩放）；FFMA R = 010110011…（0x5980 << 48），Rc 39..47、.FMZ = 53..55 取 2。期望按规则手算，不跑翻译器
def maxwell_load(rd, word): return 0x4c40000000000000 | 7 << 48 | 3 << 41 | 3 << 34 | word << 20 | 7 << 16 | 255 << 8 | rd   # LOP.PASS_B Rd, RZ, c[3][4·word]（同上 SHF 例）
def maxwell_fmul_fmz(rd, ra, rb): return 0x5c68000000000000 | 2 << 44 | rb << 20 | 7 << 16 | ra << 8 | rd
def maxwell_ffma_fmz(rd, ra, rb, rc): return 0x5980000000000000 | 2 << 53 | rc << 39 | rb << 20 | 7 << 16 | ra << 8 | rd
INF, NAN = float('inf'), float('nan')
fm = [(0.0, INF), (INF, 0.0), (NAN, 0.0), (2.0, 3.0)]   # 车道 3 是非零正控
case('Maxwell FMUL.FMZ（0 × Inf / Inf × 0 / NaN × 0 = 0）', True, [f32(v) for a in fm for v in a],
     maxwell_shader([maxwell_load(4 + 2 * i, 2 * i) for i in range(4)] + [maxwell_load(5 + 2 * i, 2 * i + 1) for i in range(4)]
                    + [maxwell_fmul_fmz(i, 4 + 2 * i, 5 + 2 * i) for i in range(4)]),
     [0, 0, 0, f32(6.0)], 'D3D9 乘零规则（FMZ）：因子有一个是 0 → 积为 +0；车道 3 = 2 × 3')
ff = [(0.0, INF, 5.0), (INF, 0.0, -1.0), (NAN, 0.0, 2.0), (2.0, 3.0, 1.0)]
case('Maxwell FFMA.FMZ（0 × Inf + c = c）', True, [f32(v) for a in ff for v in a],
     maxwell_shader([maxwell_load(4 + 3 * i + k, 3 * i + k) for i in range(4) for k in range(3)]
                    + [maxwell_ffma_fmz(i, 4 + 3 * i, 5 + 3 * i, 6 + 3 * i) for i in range(4)]),
     [f32(5.0), f32(-1.0), f32(2.0), f32(7.0)], 'FMZ：积为 0 → 结果 = 加数 c；车道 3 = 2 × 3 + 1')

# ---- BMSK / UBMSK（0x01b / 0x09b；位置 A、宽度第二源、.W = 75）：PTX bmsk —— .wrap 两者取模 32，.clamp 两者封顶 32；宽 0 → 0；超出 31 位的截掉 ----
def bmsk(pos, width, wrap):
    if wrap: pos &= 31; width &= 31
    else: pos = min(pos, 32); width = min(width, 32)
    return 0 if width == 0 or pos >= 32 else ((1 << width) - 1) << pos & 0xffffffff
for wrap in (1, 0):
    ins = [(4, 8), (36, 40), (28, 8), (5, 0)] if wrap else [(0, 32), (32, 5), (4, 100), (31, 1)]
    body = [MOVC(4 + 2 * i, 2 * i) for i in range(4)] + [MOVC(5 + 2 * i, 2 * i + 1) for i in range(4)]
    body += [alu(0x01b, 1, i, 4 + 2 * i, w=(75, wrap), **R(5 + 2 * i)) for i in range(4)]
    case(f'BMSK{".W" if wrap else ""} 寄存器形式', True, [v for p in ins for v in p], body, [bmsk(p, w, wrap) for p, w in ins], 'PTX bmsk.wrap / .clamp')
case('BMSK.W 立即数宽度（形式 4：宽度在 32..64）', True, [12], [MOVC(4, 0), alu(0x01b, 4, 0, 4, w=(75, 1), imm=(32, 4)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     [bmsk(12, 4, 1), 0, 0, 0], 'PTX bmsk.wrap')
# ---- S2UR URd, SR 0x84（0x9c3，SR 号 72..80）：Switch 2 片元着色器读它、UPRMT 取第 1 / 2 字节（0x7771 / 0x7772）后当除数（04008E001F098000 有 611 支）----
#   看作粗粒度着色（可变着色率）的片元宽 / 高：宿主按全速率着色 = 1 × 1。原先 SReg 表没有 0x84、走 default 给 0，着色器算出 1 / 0（海面 Inf / NaN，自动曝光被拖垮）
UPRMT = lambda urd, ura, sel: alu(0x096, 4, urd, ura, imm=(32, sel), rc=(64, URZ))   # UPRMT URd, URa, imm32, URc（形式 4，同反汇编 0x896：选择子在 32..64，第三源 URc 在 64..70）
case('S2UR SR 0x84（片元粗着色尺寸：第 1 / 2 字节 = 1 × 1）', True, [],
     [inst(0x9c3, urd=(16, 4), sr=(72, 0x84)), UPRMT(5, 4, 0x7771), UPRMT(6, 4, 0x7772), MOVU(0, 4), MOVU(1, 5), MOVU(2, 6), MOVI(3, 0)],
     [0x00010100, 1, 1, 0], '宿主全速率着色：宽 = 高 = 1（游戏的 611 支只取这两个字节；其余字节没有读者，按 0）')
case('UBMSK（统一数据通路，UR 6 位寄存器号）', True, [3, 7], [ULDC(4, 0), ULDC(5, 1), alu(0x09b, 1, 6, 4, w=(75, 1), **R(5)), MOVU(0, 6), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     [bmsk(3, 7, 1), 0, 0, 0], 'PTX bmsk.wrap')

# ---- 双精度：DADD 0x029 / DMUL 0x028 / DFMA 0x02b / DSETP 0x02a（NAK；修饰位同 FADD / FMUL / FFMA / FSETP：A 取负 72 绝对值 73，B 取负 63 绝对值 62；64 位立即数是高 32 位） ----
# 值都取单精度能精确表示的（Metal 没有双精度，dmsh_xlate 降成单精度算：只有这样的值两边逐位相同）
def dpair(*vals): return [w for v in vals for w in f64(v)]
def D2R(lo_rd, w): return [MOVC(lo_rd, w), MOVC(lo_rd + 1, w + 1)]   # 双精度寄存器对 ← c[3] 两个字
case('DADD 寄存器对', True, dpair(1.5, 2.25), D2R(4, 0) + D2R(6, 2) + [alu(0x029, 1, 0, 4, **R(6)), MOVI(2, 0), MOVI(3, 0)], [*f64(3.75), 0, 0], 'IEEE 754：1.5 + 2.25 = 3.75')
case('DADD -|a| + 立即数（形式 4，立即数 = 0.5 的高字）', True, dpair(-1.5), D2R(4, 0) + [alu(0x029, 4, 0, 4, imm=(32, f64(0.5)[1]), na=(72, 1), aa=(73, 1)), MOVI(2, 0), MOVI(3, 0)],
     [*f64(-1.0), 0, 0], '-|-1.5| + 0.5 = -1')
case('DMUL a · -b', True, dpair(-1.5, 4.0), D2R(4, 0) + D2R(6, 2) + [alu(0x028, 1, 0, 4, nb=(63, 1), **R(6)), MOVI(2, 0), MOVI(3, 0)], [*f64(6.0), 0, 0], '-1.5 · -4 = 6')
case('DFMA a · b + c（C 在 64..72）', True, dpair(2.0, 3.0, 0.5), D2R(4, 0) + D2R(6, 2) + D2R(8, 4) + [alu(0x02b, 1, 0, 4, rc=(64, 8), **R(6)), MOVI(2, 0), MOVI(3, 0)],
     [*f64(6.5), 0, 0], '2 · 3 + 0.5 = 6.5')
# DSETP.LT.AND P0, P1, a, b, PT 然后 SEL：P0 = 1.5 < 2.25 真、P1 = 非（a < b）与 PT = 假
SEL = lambda rd, ra, imm, p: alu(0x007, 4, rd, ra, imm=(32, imm), p=(87, p))   # SEL Rd, Ra, imm, P：P ? Ra : imm（NAK OpSel）
case('DSETP.LT.AND（比较 76..80 = 1 LT，逻辑 74..76 = 0 AND，Pd0 81、Pd1 84）', True, dpair(1.5, 2.25) + [0x11],
     D2R(4, 0) + D2R(6, 2) + [MOVC(9, 4), alu(0x02a, 1, RZ, 4, cmp=(76, 1), pd0=(81, 0), pd1=(84, 1), pacc=(87, PT), **R(6)), SEL(0, 9, 0x22, 0), SEL(1, 9, 0x22, 1), MOVI(2, 0), MOVI(3, 0)],
     [0x11, 0x22, 0, 0], '1.5 < 2.25：P0 真取 Ra、P1 假取立即数')

# ---- 转换族：F2F 0x104 / 0x110、F2I 0x105 / 0x111、I2F 0x106 / 0x112、FRND 0x107 / 0x113（大小 84..86 源 / 75..77 目的，取 log2 字节；有符号 F2I 72 / I2F 74；舍入 78..80） ----
def conv(op9, form, rd, rb, src, dst, rnd=0, **f): return alu(op9, form, rd, rb=(32, rb), ss=(84, src), ds=(75, dst), rnd=(78, rnd), **f)
case('F2F.F32.F32.FLOOR（同大小：78..80 是取整方式）', True, [f32(2.75), f32(-2.25)],
     [MOVC(4, 0), MOVC(5, 1), conv(0x104, 1, 0, 4, 2, 2, 1), conv(0x104, 1, 1, 5, 2, 2, 2), conv(0x104, 1, 2, 4, 2, 2, 3), conv(0x104, 1, 3, 5, 2, 2, 0)],
     [f32(2.0), f32(-2.0), f32(2.0), f32(-2.25)], 'floor 2.75 = 2，ceil -2.25 = -2，trunc 2.75 = 2，不取整原值')
case('F2F.F16.F16.CEIL / F2F.F64.F32.TRUNC（同大小半精度、加宽带取整）', True, [f16(1.25), f32(-2.75)], [MOVC(4, 0), MOVC(5, 1), conv(0x104, 1, 0, 4, 1, 1, 2), conv(0x110, 1, 2, 5, 2, 3, 3), MOVI(1, 0)],
     [f16(2.0), 0, *f64(-2.0)], 'ceil 1.25 = 2（半精度落低 16 位）；trunc -2.75 = -2 再加宽')
case('F2F.F16.F32（缩窄、就近）', False, [f32(1.0), f32(-0.5)], [MOVC(4, 0), MOVC(5, 1), conv(0x104, 1, 0, 4, 2, 1), conv(0x104, 1, 1, 5, 2, 1), MOVI(2, 0), MOVI(3, 0)],
     [f16(1.0), f16(-0.5), 0, 0], 'IEEE 半精度：1.0 = 0x3c00，-0.5 = 0xb800，高 16 位 0')
case('F2F.F64.F32 / F2F.F32.F64（0x110）', True, [f32(1.5)] + dpair(-2.75), [MOVC(4, 0)] + D2R(6, 1) + [conv(0x110, 1, 0, 4, 2, 3), conv(0x110, 1, 2, 6, 3, 2), MOVI(3, 0)],
     [*f64(1.5), f32(-2.75), 0], '单 ↔ 双精度精确')
case('FRND.F64.FLOOR（0x113）', True, dpair(-2.5), D2R(4, 0) + [conv(0x113, 1, 0, 4, 3, 3, 1), MOVI(2, 0), MOVI(3, 0)], [*f64(-3.0), 0, 0], 'floor -2.5 = -3')
case('FRND.F32 四种取整', False, [f32(-2.5), f32(2.5)], [MOVC(4, 0), MOVC(5, 1), conv(0x107, 1, 0, 4, 2, 2, 0), conv(0x107, 1, 1, 5, 2, 2, 0), conv(0x107, 1, 2, 4, 2, 2, 2), conv(0x107, 1, 3, 4, 2, 2, 3)],
     [f32(-2.0), f32(2.0), f32(-2.0), f32(-2.0)], '就近取偶 -2.5 → -2、2.5 → 2；ceil -2.5 = -2；trunc -2.5 = -2')
case('F2I.S64.F32.FLOOR（0x111，Rd 对低字在前）', True, [f32(-1.5), f32(-(2.0 ** 33))], [MOVC(4, 0), MOVC(5, 1), conv(0x111, 1, 0, 4, 2, 3, 1, sg=(72, 1)), conv(0x111, 1, 2, 5, 2, 3, 1, sg=(72, 1))],
     [-2, -1, 0, 0xfffffffe], 'floor -1.5 = -2 = 0xffffffff_fffffffe；-2^33 = 0xfffffffe_00000000（低字 0 时高字不借位）')
case('F2I.U64.F32.TRUNC（0x111，原有一式）', False, [f32(1.5 * 2 ** 32)], [MOVC(4, 0), conv(0x111, 1, 0, 4, 2, 3, 3), MOVI(2, 0), MOVI(3, 0)],
     [0x80000000, 1, 0, 0], '1.5 · 2^32 = 0x1_80000000')
case('F2I.S32.F64.TRUNC（0x111：源是双精度）', True, dpair(-7.75), D2R(4, 0) + [conv(0x111, 1, 0, 4, 3, 2, 3, sg=(72, 1)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     [-7, 0, 0, 0], 'trunc -7.75 = -7')
case('I2F.F64.S32（0x112）', True, [-3], [MOVC(4, 0), conv(0x112, 1, 0, 4, 2, 3, sg=(74, 1)), MOVI(2, 0), MOVI(3, 0)], [*f64(-3.0), 0, 0], '-3 → -3.0')
case('I2F.F64.U64 / I2F.F32.S64（0x112，源寄存器对）', True, [0, 3, 0, 0xffffffff], [MOVC(4, 0), MOVC(5, 1), MOVC(6, 2), MOVC(7, 3), conv(0x112, 1, 0, 4, 3, 3), conv(0x112, 1, 2, 6, 3, 2, sg=(74, 1)), MOVI(3, 0)],
     [*f64(3.0 * 2 ** 32), f32(-(2.0 ** 32)), 0], '3 · 2^32；有符号 0xffffffff_00000000 = -2^32')
case('I2F.F16.S16（半精度结果落低 16 位）', False, [0x8000fffd], [MOVC(4, 0), conv(0x106, 1, 0, 4, 1, 1, sg=(74, 1)), conv(0x106, 1, 1, 4, 1, 2, sg=(74, 1), sel=(60, 1)), MOVI(2, 0), MOVI(3, 0)],
     [f16(-3.0), f32(-32768.0), 0, 0], '低半 0xfffd = -3；高半（60..62 = 1）0x8000 = -32768')

# ---- MUFU.TANH（op 74..80 = 9，NAK MuFuOp::Tanh）：tanh 0 = 0、tanh(±20) 在单精度里就是 ±1（1 − tanh 20 ≈ 8.5e-18 < 2^-24） ----
case('MUFU.TANH', True, [f32(0.0), f32(20.0), f32(-20.0)], [MOVC(4, 0), MOVC(5, 1), MOVC(6, 2)] + [alu(0x108, 1, i, rb=(32, 4 + i), op=(74, 9)) for i in range(3)] + [MOVI(3, 0)],
     [f32(0.0), f32(1.0), f32(-1.0), 0], 'tanh 0 = 0，tanh ±20 = ±1（单精度）')

# ---- 一维 TLD.LZ（tbuf_oob，11-04 越界读）：TLD.LZ R0, R4（0xb66，维 0、LZ、只取 R，贴图句柄 c[2][0xa0] = 槽 16；字段照 Pokopia 00012055e7421703 的实指令）。
#   描述符是缓冲：第 x 个元素，x ≥ 元素数读 0（硬件）；是一维纹理：第 x 个纹素，越界同样 0。被读物第 i 个 = float(i + 1)，之后是 999.0（读到它 = 读到缓冲之外）。
#   宿主按 Ampere 折行读的约定绑「精确行」（nvn_tbuf_rows_exact：W × H = 元素数，H > 1 时 W 是 2 的幂；一维纹理是 n × 1），翻译器从绑上的形式取 W、H、界外读 0
TLD = lambda rd, ra: inst(0xb66, rd=(16, rd), ra=(24, ra), rb=(32, RZ), h=(40, 0x28), bank=(54, 2), scr=(60, 1), mask=(72, 1), rc=(64, RZ), res=(81, PT), lod=(87, 1))
for form, n, x, want, why in [
        ('exact', 20000, 0, 1, '界内首个'), ('exact', 20000, 19999, 20000, '界内末个（第 625 行）'),
        ('exact', 20000, 20000, 0, '越界 1 个：硬件读 0（固定 16384 列的行在这里读到缓冲之后）'), ('exact', 20000, 32767, 0, '原先最后一行末尾：读 0'),
        ('exact', 20000, 32768, 0, '越过原先全部行：读 0'), ('exact', 32768, 32768, 0, '整 2 行（W 16384）越界：读 0'),
        ('exact', 1000, 999, 1000, '单行界内末个'), ('exact', 1000, 1000, 0, '单行越界：读 0'),
        ('tex1d', 1000, 999, 1000, '真一维纹理界内末个'), ('tex1d', 1000, 1000, 0, '真一维纹理越界：读 0'),
        ('exact', 1016320, 1016319, 1016320, 'Pokopia 那两张缓冲的元素数（2^9 × 1985：精确行 512 × 1985）界内末个'),
        ('exact', 1016320, 1016320, 0, 'Pokopia 尺寸越界 1 个：读 0'), ('exact', 1016320, 1032191, 0, 'Pokopia 尺寸、原先第 63 行末尾：读 0')]:
    case(f'TLD.LZ 一维 {form} n={n} x={x}', True, [x], [MOVC(4, 0), TLD(0, 4), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)], [f32(float(want)) if want else 0, 0, 0, 0], why, (form, n))

# ---- ATOMG.CAS（0x3a9，PTX atom.global.cas：mem == 比较值时写新值，Rd = 旧值）：片元阶段的存储缓冲描述符在 c[0][0x510]（Dsh.cs SSBO("ps")），LDC.64 取地址，
#   翻译器（GlobalToStorage）把这个地址认成存储缓冲 0；frag_run 把它绑到输入块（第 0 个字 = 内存原值）。CAS 后再 LDG 同一地址读回新值
LDC64 = lambda rd, off: inst(0xb82, rd=(16, rd), ra=(24, RZ), off=(38, off), bank=(54, 0), size=(73, 5))
CAS = lambda rd, ra, rb, rc: inst(0x3a9, rd=(16, rd), ra=(24, ra), rb=(32, rb), rc=(64, rc), e=(72, 1), p=(81, PT))
LDG = lambda rd, ra: inst(0x381, rd=(16, rd), ra=(24, ra), e=(72, 1), size=(73, 4))
MOVR = lambda rd, rb: alu(0x002, 1, rd, rb=(32, rb), m=(72, 0xf))
for mem, cmp, new, old, after, why in [(5, 5, 9, 5, 9, '相等：写入新值'), (5, 6, 9, 5, 5, '不等：不写')]:
    case(f'ATOMG.CAS 内存 {mem} 比较 {cmp} 新值 {new}', True, [mem, cmp, new],
         [LDC64(8, 0x510), MOVC(4, 1), MOVC(5, 2), CAS(6, 8, 4, 5), LDG(7, 8), MOVR(0, 6), MOVR(1, 7), MOVI(2, 0), MOVI(3, 0)], [old, after, 0, 0], why)

# ---- F2IP.U8.F32.NTZ（0x243，PTX cvt.rni.s32.f32 两次 + cvt.pack.sat.u8.s32.b32 融成一条：NVIDIA 论坛 255571 的 sm_89 编译读数）：
#   d = { c[15:0] → 高 16 位，sat_u8(rni(a)) → 字节 1，sat_u8(rni(b)) → 字节 0 }（PTX cvt.pack 的位次）；NaN 读 0（NTZ），就近取偶；修饰位只认塞尔达 10 条里那一种（72..92 = 只有位 74）
F2IP = lambda rd, ra, rb, rc: alu(0x043, 1, rd, ra, rb=(32, rb), rc=(64, rc), u8=(74, 1))
for a, b, c, want, why in [(200.5, -3.0, 0x1234, 0x1234c800, 'a 200.5 就近取偶 200 → 字节 1，b −3 截到 0 → 字节 0，c 低 16 位 0x1234 → 高半'),
                           (300.0, 127.5, 0xffff0000, 0x0000ff80, 'a 截到 255，b 127.5 取偶 128；c 只取低 16 位（0）'),
                           (float('nan'), 254.5, 0, 0x000000fe, 'NaN 读 0（NTZ），254.5 取偶 254')]:
    case(f'F2IP.U8.F32 a={a} b={b} c={c:#x}', True, [f32(a), f32(b), c], [MOVC(4, 0), MOVC(5, 1), MOVC(6, 2), F2IP(0, 4, 5, 6), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
         [want, 0, 0, 0], why)

# F2IP 的取整在 78..80（同 F2I：0 就近取偶、1 向下、2 向上、3 截断）；时之笛 8 支网格着色器是 72..92 = 0xc4（截断）
F2IPR = lambda rd, ra, rb, rc, rnd: alu(0x043, 1, rd, ra, rb=(32, rb), rc=(64, rc), u8=(74, 1), rnd=(78, rnd))
for a, b, c, rnd, want, why in [(200.9, -0.5, 0x1234, 3, 0x1234c800, '截断：200.9 → 200，-0.5 → 0'),
                                (2.5, 254.9, 0, 1, 0x000002fe, '向下：2.5 → 2，254.9 → 254'),
                                (2.5, 254.1, 0, 2, 0x000003ff, '向上：2.5 → 3，254.1 → 255')]:
    case(f'F2IP.U8.F32 取整 {rnd} a={a} b={b}', True, [f32(a), f32(b), c], [MOVC(4, 0), MOVC(5, 1), MOVC(6, 2), F2IPR(0, 4, 5, 6, rnd), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
         [want, 0, 0, 0], why)

# ---- WARPSYNC（0x148 的 ALU 形式；单线程语义无事可做） ----
case('WARPSYNC 寄存器 / 常量缓冲 / 统一寄存器形式（0x348 / 0xb48 / 0xd48）', True, [0x5a5a5a5a, 0xffffffff],
     [MOVC(0, 0), MOVC(4, 1), inst(0x348, rb=(32, 4)), inst(0xb48, off=(38, 4), bank=(54, 3)), inst(0xd48, ur=(32, URZ)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     [0x5a5a5a5a, 0, 0, 0], '只等车道，单线程不改寄存器')


# ==== 11-05 上游参考实现（MIT）777a5f6c 之后的翻译修正（docs/坑记录.md 同日各条） ====
def at(v, **f):
    """改调度位 / 守卫：wb 写屏障（110..113）、wait 等待掩码（116..122）、g 守卫谓词（12..15，gi 取反位 15）"""
    for k, (lo, n, val) in {'wb': (110, 3, f.get('wb')), 'wait': (116, 6, f.get('wait')), 'g': (12, 3, f.get('g')), 'gi': (15, 1, f.get('gi'))}.items():
        if val is not None: v = v & ~(((1 << n) - 1) << lo) | val << lo
    return v
def FSETP(pd, ra, cmp, ftz, b=None, imm=None, pd1=PT):
    """FSETP.cmp[.FTZ].AND Pd, Pd1, Ra, b, PT（0x00b；比较 76..80，逻辑 74..76 = AND，.FTZ 80，Pd 81、Pd1 84、累加谓词 87 = PT；b 寄存器形式 1 在 32..40，立即数形式 4 在 32..64）"""
    if imm is not None: return alu(0x00b, 4, RZ, ra, imm=(32, imm), cmp=(76, cmp), ftz=(80, ftz), pd0=(81, pd), pd1=(84, pd1), pacc=(87, PT))
    return alu(0x00b, 1, RZ, ra, cmp=(76, cmp), ftz=(80, ftz), pd0=(81, pd), pd1=(84, pd1), pacc=(87, PT), **R(b))
LT, EQ, LE, GT, NE, GE, NEU = 1, 2, 3, 4, 5, 6, 13
DEN = f32(2.0 ** -130)            # 正的非规格化数（位型 0x00200000）；NVIDIA 带 .FTZ 的比较把它当 0
NDEN = f32(-(2.0 ** -130))
ONE = f32(1.0)
def ftz_case(name, new, inputs, cmps, want, why):
    """最多 4 个比较：第 i 个写 Pi，再 SEL Ri = Pi ? 0x11 : 0x22（R9 = 0x11 从 c[3] 末字读）"""
    body = [MOVC(4 + k, k) for k in range(len(inputs))] + [MOVC(9, len(inputs))]
    for i, c in enumerate(cmps): body.append(FSETP(i, *c))
    body += [SEL(i, 9, 0x22, i) for i in range(len(cmps))] + [MOVI(i, 0) for i in range(len(cmps), 4)]
    case(name, new, inputs + [0x11], body, [0x11 if w else 0x22 for w in want] + [0] * (4 - len(want)), why)
# ---- .FTZ 比较（84dea6983 不追的依据）：NVIDIA 带 .FTZ 时非规格化操作数按 0 比。Apple GPU 自己就把 fp32 非规格化数冲成 0（11-05 M5 Max 实测 safe / relaxed / fast 三种数学模式，
#      比较与算术都冲；Metal 规范允许），翻译器照原样比就对，不加冲刷运算（加了 500 支抽样语句 +1.5%）。这几例守的是这条硬件前提：哪台设备不冲刷，它们就红，届时再议。
#      标「旧」（修前修后都过）；不带 .FTZ（NVIDIA 保留非规格化数）在这类硬件上翻不出，不设例（docs/坑记录.md） ----
ftz_case('FSETP.FTZ 与 0 比（NE / GT / LT / EQ）', False, [DEN, NDEN], [(4, NE, 1, RZ), (4, GT, 1, RZ), (5, LT, 1, RZ), (4, EQ, 1, RZ)], [0, 0, 0, 1],
         '2^-130 当 0：≠0 假、>0 假；-2^-130 当 0：<0 假；==0 真')
ftz_case('FSETP.FTZ 与 0 比（GE / LE / NEU）及 NaN', False, [NDEN, DEN, 0x7fc00000], [(4, GE, 1, RZ), (5, LE, 1, RZ), (5, NEU, 1, RZ), (6, NEU, 1, RZ)], [1, 1, 0, 1],
         '-2^-130 当 0：>=0 真；2^-130 当 0：<=0 真、≠0（无序）假；NaN 无序比较为真')
ftz_case('FSETP.FTZ 两边都是寄存器', False, [DEN, NDEN, f32(2.0 ** -129)], [(4, EQ, 1, 5), (4, LT, 1, 6), (6, GT, 1, 4), (4, NE, 1, 5)], [1, 0, 0, 0],
         '三个非规格化数都当 0：相等真，小于 / 大于 / 不等都假')
ftz_case('FSETP.FTZ 常量在左（Ra = RZ）与非 0 常量', False, [DEN, NDEN], [(RZ, LT, 1, 4), (RZ, GT, 1, 5), (4, LT, 1, None, ONE), (5, GT, 1, None, f32(-1.0))], [0, 0, 1, 1],
         '0 < 2^-130 假、0 > -2^-130 假（冲刷后同为 0）；与 ±1 比冲不冲刷都一样（立即数形式 4：32..64 整个 float）')
# FSET.NEU.FTZ Rd：真写 1.0，假写 0（0x00a，同 FSETP 的比较字段，Rd 在 16）
FSET = lambda rd, ra, cmp, ftz, rb: alu(0x00a, 1, rd, ra, cmp=(76, cmp), ftz=(80, ftz), pacc=(87, PT), **R(rb))
case('FSET.NEU.FTZ（非规格化数 / 1.0）', False, [DEN, ONE], [MOVC(4, 0), MOVC(5, 1), FSET(0, 4, NEU, 1, RZ), FSET(1, 5, NEU, 1, RZ), MOVI(2, 0), MOVI(3, 0)], [0, ONE, 0, 0],
     '2^-130 当 0：≠0 假写 0；1.0 ≠ 0 真写 1.0')

# ---- VOTEU 写统一谓词（95f9a6a92）：VOTEU.ANY URZ, UP1, P0 之后 UP2UR 读 UP1；P1（车道谓词）不该被动。P0 = 1.0 > 0 真，P1 = 1.0 < 0 假 ----
VOTEU = lambda pd, p, mode: inst(0x886, urd=(16, URZ), mode=(72, mode), pd=(81, pd), p=(87, p))
UP2UR = lambda urd, mask: inst(0x883, urd=(16, urd), ura=(24, URZ), imm=(32, mask), u=(91, 1))
case('VOTEU.ANY 写 UP1、不写 P1', True, [ONE, 0x11], [MOVC(4, 0), MOVC(9, 1), FSETP(0, 4, GT, 0, RZ), FSETP(1, 4, LT, 0, RZ), VOTEU(1, 0, 1), UP2UR(5, 0x2), MOVU(0, 5), SEL(1, 9, 0x22, 1), MOVI(2, 0), MOVI(3, 0)],
     [2, 0x22, 0, 0], 'UP1 = any(P0) = 真 → UP2UR 掩码 2 读出 2；P1 仍假 → 0x22（修前写到 P1：0、0x11）')

# ---- 0x925 覆盖像素读（7bccfc88a）：画到的像素读 1（辅助调用读 0，1 像素的画无从读邻居，未测） ----
case('0x925 覆盖到的像素读 1', True, [], [inst(0x925, rd=(16, 0), f=(78, 1), p=(81, PT)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)], [1, 0, 0, 0], '画到的像素不是辅助调用')

# ---- 带守卫的可变延迟写（9507c221c）：@P4 MUFU.EX2 R17（写屏障 0）发出后、等屏障前 @!P4 MOV R17 自己写；守卫假时 EX2 什么都不写，R17 留 @!P4 那次的值 ----
EX2 = lambda rd, rb: alu(0x108, 1, rd, rb=(32, rb), op=(74, 2))
def sb_body(p4_true):
    return [MOVC(4, 0), MOVC(17, 1), MOVC(6, 2), FSETP(4, 4, GT if p4_true else LT, 0, RZ),
            at(EX2(17, 4), wb=0, g=4), at(MOVR(17, 6), g=4, gi=1), at(MOVR(0, 17), wait=1), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)]
case('守卫假的 EX2 不抄回旧值', True, [f32(3.0), f32(100.0), f32(-7.0)], sb_body(False), [f32(-7.0), 0, 0, 0], 'P4 = 3 < 0 假：EX2 不写，R17 = @!P4 写的 -7（修前抄回发出时的 100）')
case('守卫真的 EX2 照常落地', False, [f32(3.0), f32(100.0), f32(-7.0)], sb_body(True), [f32(8.0), 0, 0, 0], 'P4 真：2^3 = 8 在等屏障时落到 R17，@!P4 不执行')

# 同一寄存器两笔可变延迟写都没等就到了：EX2 R17 ← 2^3（写屏障 3），再 @P4 EX2 R17 ← 2^1（写屏障 0），然后等两个屏障读 R17。后发的写后落地：P4 真读 2，P4 假读 8
# （时之笛 e1c9adbcf6bd2996 的 IPA R10 ← 属性 4 / @P0 IPA R10 ← 属性 5 同形）。修前守卫写丢了前一笔（P4 假读到发出前的 100）
def sb2_body(p4_true):
    return [MOVC(4, 0), MOVC(17, 1), MOVC(7, 2), FSETP(4, 4, GT if p4_true else LT, 0, RZ),
            at(EX2(17, 4), wb=3), at(EX2(17, 7), wb=0, g=4), at(MOVR(0, 17), wait=0b1001), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)]
case('两笔待落地写同一寄存器、后一笔守卫假', True, [f32(3.0), f32(100.0), f32(1.0)], sb2_body(False), [f32(8.0), 0, 0, 0], 'P4 假：后一笔不写，R17 = 前一笔的 2^3 = 8（修前 100）')
case('两笔待落地写同一寄存器、后一笔守卫真', False, [f32(3.0), f32(100.0), f32(1.0)], sb2_body(True), [f32(2.0), 0, 0, 0], 'P4 真：后发的 2^1 = 2 后落地，前一笔的 8 不得盖回')

# ---- LDG.P 目的即地址寄存器（9507c221c）：P0 真时从 [R8.64 + 4] 读；修前先把 R8 写 0 再算地址 ----
LDGP = lambda rd, ra, off, p: inst(0x981, rd=(16, rd), ra=(24, ra), off=(40, off), e=(72, 1), size=(73, 4), p=(64, 7 - p))
case('LDG.P R8, [R8.64 + 4]（谓词真）', True, [ONE, 0xabcd1234], [MOVC(4, 0), FSETP(0, 4, GT, 0, RZ), LDC64(8, 0x510), LDGP(8, 8, 4, 0), MOVR(0, 8), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     [0xabcd1234, 0, 0, 0], '存储缓冲第 1 个字（输入块，frag_run 绑同一块）')

# ==== 11-06 上游参考实现（MIT）时之笛修正：死代码删除与四偏移 gather（docs/坑记录.md 同日条目） ====
# 被读物：-T tex2d:16 = 16 × 16 RGBA32Float，纹素 (x, y) = (x + 1, y · 16 + x + 1, y + 1, 1)（frag_run.m）；纹理句柄 c[2][0xa0] = 槽 16（同上面一维 TLD），二维（61..64 = 1）
TW = 16
def texel(x, y): return (x + 1, y * TW + x + 1, y + 1, 1)
# 二维 TLD.LZ R4, R6（0xb66，坐标 R6 = x、R7 = y，四车道掩码 72..76 = 0b0011 → R4 = .x、R5 = .y）。R4 随即被 MOV R0, R5 之外再无人读：.x 那条拷贝是死代码。
#   死代码删除顺着拷贝的源找到读指令，读指令的 .y 仍有人用、留在块里，修前却照样把它的源（坐标 R6 = c[3][0] + c[3][1]、R7 = c[3][2]）的用处摘掉，
#   下一轮把算坐标的链删了，坐标成了未定义值（时之笛风场 04942f42cae10d0f 的读坐标 y 来自 undef）
TLD2 = lambda rd, ra, m: inst(0xb66, rd=(16, rd), ra=(24, ra), rb=(32, RZ), h=(40, 0x28), bank=(54, 2), dim=(61, 1), mask=(72, m), rc=(64, RZ), res=(81, PT), lod=(87, 1))
IADD3 = lambda rd, ra, rb: alu(0x010, 1, rd, ra, rb=(32, rb), rc=(64, RZ), p0=(81, PT), p1=(84, PT), q0=(87, PT), q1=(77, PT))   # IADD3 Rd = Ra + Rb + RZ（NAK OpIAdd3）
for x0, dx, y0 in [(2, 3, 9), (11, 2, 4)]:
    case(f'二维 TLD .x 不用 / .y 用：坐标链不被删（({x0}+{dx}, {y0})）', True, [x0, dx, y0],
         [MOVC(8, 0), MOVC(9, 1), IADD3(6, 8, 9), MOVC(7, 2), TLD2(4, 6, 0b0011), MOVR(0, 5), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
         [f32(float(texel(x0 + dx, y0)[1])), 0, 0, 0], f'纹素 ({x0 + dx}, {y0}).y = {y0}·16 + {x0 + dx} + 1 = {texel(x0 + dx, y0)[1]}', ('tex2d', TW))

# TLD4.PTP R0, R4, R8（0xb63，偏移方式 76..78 = 2：每纹素一个偏移，源 B = R8、R9；分量 87..89 = 1 取 .y；坐标 R4 = u、R5 = v 归一化）。四个偏移每个 6 位有符号，
#   R8 的字节 0 / 1 = 纹素 0 的 x / y、字节 2 / 3 = 纹素 1，R9 同样放纹素 2 / 3（InstEmitAmpereMem.cs ATex）。偏移是立即数 → SPIR-V ConstOffsets → SPIRV-Cross 的 spvGatherConstOffsets
#   用循环把 coffsets[i] 传给 gather()，Metal 只认常量偏移、编译不报错，读到的纹素不对（时之笛 NDSR 放大器 b106afba1a18faa9 的 9 处 gather 同形）。
#   期望（GL textureGatherOffsets / SPIR-V ConstOffsets 规格）：结果第 k 个分量 = 足迹左上纹素 (i0, j0) 加偏移 k 处那个纹素的 .y；坐标取 ((x0 + 1) / 16, (y0 + 1) / 16)，
#   u · 16 − 0.5 = x0 + 0.5 → i0 = x0、j0 = y0（最近点、边缘夹取，偏移后都在界内）
TLD4P = lambda rd, ra, rb, comp: inst(0xb63, rd=(16, rd), ra=(24, ra), rb=(32, rb), h=(40, 0x28), bank=(54, 2), dim=(61, 1), mask=(72, 0xf), rc=(64, RZ), res=(81, PT), off=(76, 2), comp=(87, comp))
def pack_off(a, b): return (a[0] & 63) | (a[1] & 63) << 8 | (b[0] & 63) << 16 | (b[1] & 63) << 24
for x0, y0, offs in [(6, 7, [(-1, 2), (3, 0), (0, -2), (2, 1)]), (4, 10, [(0, 0), (1, 0), (0, 1), (-3, -4)])]:
    case(f'TLD4.PTP 四个立即数偏移（{x0}, {y0}）{offs}', True, [f32((x0 + 1) / TW), f32((y0 + 1) / TW)],
         [MOVC(4, 0), MOVC(5, 1), MOVI(8, pack_off(offs[0], offs[1])), MOVI(9, pack_off(offs[2], offs[3])), TLD4P(0, 4, 8, 1)],
         [f32(float(texel(x0 + ox, y0 + oy)[1])) for ox, oy in offs], '纹素 (x0 + ox, y0 + oy).y = (y0 + oy)·16 + x0 + ox + 1，按偏移次序', ('tex2d', TW))


# ---- 只看翻译结果的例（GPU 上不画：要贴图 / 图像绑定，frag_run 不备）：(名, 新, 指令, 判定(msl, 反射) → 不符时的说明或 None, 依据) ----
REFL = []
def refl(name, new, body, check, why): REFL.append((name, new, body, check, why))
def refl_job(body):
    """body：指令表（片元，shader() 拼）或现成的 (阶段, 代码区, 控制段)"""
    return body if isinstance(body, tuple) else ('ps',) + shader(body)
def cs_shader(body, push=0, ubos=0, ssbos=0, tex=0, sep_tex=0, sep_samp=0, images=0):
    """NVN2 计算着色器：代码区 = 指令（无 SPH），补齐到 0x80；控制段 0x760 字节：魔数、版本 0xc9、+0x38 指令区长、+0x40 / +0x44 c1 起止（空）、
    c[0] 布局 +0xa9 推送常量字数、+0xb1..+0xb5 uniform / storage / 纹理 / 分离纹理 / 分离采样器项数、+0xba 大小（Dsh.cs Nvn2Job nvn2_cs），+0x748 线程组 1×1×1"""
    code = b''.join((i if isinstance(i, int) else i).to_bytes(16, 'little') for i in body + [EXIT]); code += bytes(-len(code) % 0x80)
    ctl = bytearray(0x760); struct.pack_into('<II', ctl, 0, 0x98761234, 0xc9); struct.pack_into('<I', ctl, 0x38, len(code)); struct.pack_into('<II', ctl, 0x40, len(code), len(code))
    ctl[0x56] = 5; ctl[0xa9] = push; ctl[0xb1:0xb6] = bytes((ubos, ssbos, tex, sep_tex, sep_samp))
    struct.pack_into('<H', ctl, 0xba, 0x10 + 4 * push + 0x10 * (ubos + ssbos) + 8 * (tex + sep_tex + sep_samp + images)); struct.pack_into('<III', ctl, 0x748, 1, 1, 1)
    return ('cs', code, bytes(ctl))
ULDC2 = lambda urd, off: inst(0xab9, urd=(16, urd), off=(38, off), bank=(54, 2), size=(73, 4))   # ULDC.32 URd, c[2][off]
ULOP3_OR = lambda urd, ura, urb: alu(0x092, 1, urd, ura, rb=(32, urb), rc=(64, URZ), lut=(72, 0xfc), pd=(81, PT), q=(87, PT))   # ULOP3.LUT URd = URa | URb
TEXU = lambda op, ur, **f: inst(op, rd=(16, 0), ra=(24, 4), rb=(32, RZ), ur=(40, ur), dim=(61, 1), mask=(72, 0xf), rc=(64, RZ), res=(81, PT), **f)   # 2D，句柄在 UR（40..46）
def binds(j): return [(b.get('kind'), b.get('reg')) for b in json.loads(j).get('bindings', [])]
def has_tex_samp(tex, samp):
    def f(msl, j):
        b = binds(j)
        return None if any(k in ('tex', 'samp_tex') and r == tex for k, r in b) and any(k in ('samp', 'samp_tex') and r == samp for k, r in b) else f'绑定 {b}'
    return f
# 分离纹理字在 c[2] 0x168 + 8r（槽 128 + r），分离采样器字在 0x568 + 8r（槽 r）：nvn_mtl.m C2_SEPTEX / C2_SAMP、nvn_obj.h NVN_SEPTEX_SLOT0
refl('句柄两字先采样器后纹理（67f1d0055）', True,
     [MOVC(4, 0), MOVC(5, 0), ULDC2(4, 0x568 + 8), ULDC2(5, 0x168 + 16), ULOP3_OR(6, 4, 5), TEXU(0xf60, 6, lod=(87, 1)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     lambda msl, j: has_tex_samp(130, 1)(msl, j) or (None if '_1057005E ' in msl else 'MSL 里的合成句柄不是 0x1057005E（采样器字被当成纹理字）'),
     'c[2] 0x568 起是分离采样器表：纹理 = 0x178 → 槽 130，采样器 = 0x570 → 槽 1；合成句柄 = 1 << 28 | (0x570 / 4) << 18 | 0x178 / 4 = 0x1057005E，'
     '按纹理句柄查的类型答案用它（修前反射照样归对槽，句柄却是 0x1017815C）')
refl('句柄两字先纹理后采样器（原有）', False,
     [MOVC(4, 0), MOVC(5, 0), ULDC2(4, 0x168 + 16), ULDC2(5, 0x568 + 8), ULOP3_OR(6, 4, 5), TEXU(0xf60, 6, lod=(87, 1)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     has_tex_samp(130, 1), '同上，先后对调')
# 守卫下拼句柄：R6 = 纹理字；@P0 R6 |= 采样器字；@P1 TEX 用 R6（P0、P1 读处对不上）。0x361：句柄在第二源块第一个寄存器（Rb）
LOP3_OR_R = lambda rd, ra, urb: alu(0x012, 6, rd, ra, ur=(32, urb), rc=(64, RZ), lut=(72, 0xfc), pd=(81, PT), q=(87, PT))   # LOP3.LUT Rd = Ra | URb（形式 6：第二源统一寄存器）
TEXR = lambda rb, **f: inst(0x361, rd=(16, 0), ra=(24, 4), rb=(32, rb), dim=(61, 1), mask=(72, 0xf), rc=(64, RZ), res=(81, PT), **f)
refl('守卫下拼成的句柄（4a0551e4b）', True,
     [MOVC(4, 0), MOVC(5, 1), MOVC(7, 2), FSETP(0, 7, GT, 0, RZ), FSETP(1, 7, GE, 0, RZ), ULDC2(4, 0x168 + 16), ULDC2(5, 0x568 + 8), MOVU(6, 4),
      at(LOP3_OR_R(6, 6, 5), g=0), at(TEXR(6, lod=(87, 1)), g=1), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     has_tex_samp(130, 1), 'phi(纹理字, 纹理字 | 采样器字)：单独的纹理字是半路的句柄，取拼好的（修前读被删、绑定为空）')
def has(s, what): return lambda msl, j: None if s in msl else f'MSL 里没有 {what}'
# 无绑定 TXD / TLD4 / TLD（f9b438fba）：0xf6c / 0xf63 句柄在 UR，0x367 / 0x364 句柄在 Rb；其余字段同 0xb6c / 0xb63 / 0xb66 / 0xb63
refl('TXD 句柄在统一寄存器（0xf6c）', True,
     [MOVC(4, 0), MOVC(5, 0), MOVC(6, 0), MOVC(7, 0), MOVC(8, 0), MOVC(9, 0), ULDC2(4, 0x20 + 8), inst(0xf6c, rd=(16, 0), ra=(24, 4), rb=(32, 6), ur=(40, 4), dim=(61, 1), mask=(72, 0xf), rc=(64, RZ), res=(81, PT)),
      MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)], has('gradient2d', '带梯度的取样'), 'TXD = 显式梯度取样')
refl('TLD 句柄在寄存器（0x367）', True,
     [MOVC(4, 0), MOVC(5, 0), MOVC(6, 0), inst(0x367, rd=(16, 0), ra=(24, 4), rb=(32, 6), dim=(61, 1), mask=(72, 0xf), rc=(64, RZ), res=(81, PT), lod=(87, 1)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     has('.read(', '整数坐标读'), 'TLD = 整数坐标读')
refl('TLD4 句柄在统一寄存器（0xf63）', True,
     [MOVC(4, 0), MOVC(5, 0), ULDC2(4, 0x20 + 8), inst(0xf63, rd=(16, 0), ra=(24, 4), rb=(32, RZ), ur=(40, 4), dim=(61, 1), mask=(72, 0xf), rc=(64, RZ), res=(81, PT)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     has('.gather(', '四纹素收集'), 'TLD4 = gather')
# 追不到槽的句柄（Switch2 线 63，11-06）：句柄从存储缓冲读（LDC.64 c[0] 0x510 取缓冲地址、LDG 读句柄，同时之笛那类句柄表）→ Ryujinx 回退数组 <阶段>_<t|s>_cb0_40000000。
#   期望：翻译器按池长出（纹理 2^20、采样器 2^12），Dsh.cs PoolArrays 改成池指针、反射 tex_pool / samp_pool，贴图读带置位（dm_pool_mark），改写后的 MSL 交 Metal 编译器编得过。
#   修前：数组 32 项、下标夹到 31（宿主第 k 项绑第 k 个贴图槽，句柄 ≥ 32 读错贴图），反射里没有 tex_pool
def pool_read(msl, j):
    k = [b.get('kind') for b in json.loads(j).get('bindings', [])]
    if 'tex_pool' not in k or 'samp_pool' not in k: return f'反射种类 {k}（期望含 tex_pool、samp_pool）'
    if 'dm_pool_mark(' not in msl or not re.search(r'constant spvPool_\w+_cb0_40000000\* \w+_cb0_40000000 \[\[id', msl): return 'MSL 里没有池指针 / 置位'
    with tempfile.TemporaryDirectory() as t:
        open(os.path.join(t, 'p.metal'), 'w').write(msl)
        c = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', os.path.join(t, 'p.metal'), '-o', os.path.join(t, 'p.air')], capture_output=True, text=True)
    return None if c.returncode == 0 else 'Metal 编不过：' + (c.stderr.strip().splitlines() or [''])[0][:160]
refl('追不到槽的句柄读整个池（Switch2 线 63）', True,
     [LDC64(8, 0x510), LDG(6, 8), MOVC(4, 2), MOVC(5, 3), TEXR(6, lod=(87, 1)), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     pool_read, '句柄 = 存储缓冲 0 的第 0 个字：池指针 + 置位，Metal 能编（修前 32 项数组）')

# 无绑定 TMML（11-06，上游参考实现（MIT）8feddfee）：0xf69 句柄在统一寄存器（其余字段同 0xb69）、0x36a 句柄在 Rb（同 0x367 / 0x364 一族）。TMML = 取样会用的细节层级，
#   Metal 是 calculate_(un)clamped_lod。修前两种编码都不认（「unknown opcode」拒翻整支）
def has_lod(msl, j): return None if re.search(r'\.calculate_(?:un)?clamped_lod\(', msl) else 'MSL 里没有细节层级查询 calculate_*_lod'
refl('TMML 句柄在统一寄存器（0xf69）', True,
     [MOVC(4, 0), MOVC(5, 0), ULDC2(4, 0x20 + 8), inst(0xf69, rd=(16, 0), ra=(24, 4), rb=(32, RZ), ur=(40, 4), dim=(61, 1), mask=(72, 0x3), rc=(64, RZ), res=(81, PT)), MOVI(2, 0), MOVI(3, 0)],
     has_lod, 'TMML 读 x / y 两个细节层级（8.8 定点）')
refl('TMML 句柄在寄存器（0x36a）', True,
     [MOVC(4, 0), MOVC(5, 0), MOVC(6, 0), inst(0x36a, rd=(16, 0), ra=(24, 4), rb=(32, 6), dim=(61, 1), mask=(72, 0x3), rc=(64, RZ), res=(81, PT)), MOVI(2, 0), MOVI(3, 0)],
     has_lod, '同上，句柄在第二源块第一个寄存器')

# 0x80d 守卫带剔除（11-06，上游参考实现（MIT）8feddfee）：顶点着色器位置之后两条，立即数 0xc4321111（无谓词结果）、立即数 0x80000000 比较 6（结果守卫一个 EXIT）。
#   宿主不知道硬件凭什么丢，按「从不丢」翻：谓词恒假、EXIT 不走，顶点照常写输出。期望：顶点着色器翻得过；同一指令放在片元着色器里（不是这一式）照旧拒翻
def vs_shader(body):
    """SPH 第 3 版 0x80 字节：字 0 = 类型 1（顶点）| 版本 3 << 5 | 阶段 1（顶点）<< 10；控制段同片元（+0x56 阶段 0）"""
    code, ctl = shader(body); sph = bytearray(code[:0x80]); sph[:] = bytes(0x80); struct.pack_into('<I', sph, 0, 1 | 3 << 5 | 1 << 10)
    ctl = bytearray(ctl); ctl[0x56] = 0
    return ('vs', bytes(sph) + code[0x80:], bytes(ctl))
GCULL = lambda imm, pd, cmp: inst(0x80d, ra=(24, RZ), imm=(32, imm), cmp=(76, cmp), pd=(81, pd), pd2=(84, PT), ps=(87, PT))
EXIT_P0 = inst(0x94d, c=(87, PT)) & ~(0xf << 12) | 0 << 12   # @P0 EXIT（守卫 12..15 = P0）
def translated(msl, j): return None if 'vertex ' in msl else 'MSL 里没有顶点入口'
refl('0x80d 守卫带剔除（顶点）', True, vs_shader([GCULL(0xc4321111, PT, 0), GCULL(0x80000000, 0, 6), EXIT_P0]), translated,
     '两条 0x80d 照原样：结果恒假、EXIT 不走；修前「unknown opcode 0x80d」拒翻整支（星之卡比 6,319 支顶点着色器都有）')

# 四偏移 gather 的翻译形状（11-06）：本机（M5 Max）GPU 上修前的循环形式读回也对（上面两例修前即绿），偏移是否成了运行时值只能看 MSL：
#   不得再调 spvGatherConstOffsets（它在循环里把 coffsets[i] 交 gather()），四次 gather 的偏移都写成 int2 常量
def gather_const(msl, j):
    calls = [m for m in re.finditer(r'\bspvGather(?:Compare)?ConstOffsets\(', msl) if not msl.startswith('const ', m.end())]
    if calls: return f'MSL 仍调用包装 spvGatherConstOffsets {len(calls)} 处（循环里偏移是运行时值）'
    got = re.findall(r'\.gather\([^;]*?, (int2\([^()]*\)), component::y\)\.w', msl)
    return None if got == ['int2(-1, 2)', 'int2(3, 0)', 'int2(0, -2)', 'int2(2, 1)'] else f'常量偏移 gather {got}，应为四个按次序的 int2 常量'
refl('TLD4.PTP 立即数偏移：四次常量偏移 gather（时之笛 NDSR b106afba1a18faa9）', True,
     [MOVC(4, 0), MOVC(5, 1), MOVI(8, pack_off((-1, 2), (3, 0))), MOVI(9, pack_off((0, -2), (2, 1))), TLD4P(0, 4, 8, 1)], gather_const,
     'SPIR-V ConstOffsets 第 k 个分量取偏移 k 处的纹素；Metal gather 偏移只认常量表达式')

# SURED 的操作取 87..91（9507c221c）：原先只认 ADD。SURED [R4], R6（0x59f）：坐标 R4、R5，值 R6，句柄 c[2] 0x120（图像槽 0，字偏移 0x48 在 40..54、库 2 在 54..59），
# 维度 61..64 = 3（SuDim 二维），字 2 = 0x0010e000 | 操作 << 23（MAX 2、OR 6，RedOp 同 SUATOM 的次序）
SURED = lambda op: inst(0x59f, ra=(24, 4), rb=(32, 6), h=(40, 0x48), bank=(54, 2), dim=(61, 3), w2=(64, 0x0010e000 | op << 23))
refl('SURED.MAX / SURED.OR（9507c221c）', True,
     [MOVC(4, 0), MOVC(5, 0), MOVC(6, 0), SURED(2), SURED(6), MOVI(0, 0), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)],
     lambda msl, j: None if 'atomic_fetch_max' in msl and 'atomic_fetch_or' in msl else 'MSL 里没有图像原子 max / or', '修前只认 ADD，别的操作拒翻')

# 时之笛 d17eefaff4f0bc23（计算，真机现编报 SURED form 0310e000）那条原样：0001e2000310e000600084000400159f = SURED [R0], R4，二维（61..64 = 3），句柄 c[0] 字 0x84（0x210），
# 字 2 = 0x0010e000 | 6 << 23（OR）。c[0] 布局按控制段：推送 0、uniform 0、storage 0、纹理 64 项（0x10..0x210）、图像 1 项 → 0x210 是图像槽 0（AMapC0 → c[2] 0x120）
refl('SURED.OR 句柄在计算 c[0]（时之笛 d17eefaff4f0bc23 原指令字）', True,
     cs_shader([MOVI(0, 1), MOVI(1, 2), MOVI(4, 0x10), 0x0001e2000310e000600084000400159f], tex=64, images=1),
     lambda msl, j: None if 'atomic_fetch_or' in msl else 'MSL 里没有图像原子 or', '修前 SURED 只认 ADD（字 2 = 0x0010e000）')

# 计算 c[0] 0x4 / 0x8 / 0xc = 本次派发的线程组数 x / y / z（时之笛天空辐照度 21d9f83e6027c565：线程号 = (组 y × 32 + y) × (c[0][4] × 32) + 组 x × 32 + x，
# 再除以总数 (c[0][4] × 32) × (c[0][8] × 32)）。宿主把它们放在 c[0] + 0x200（nvn_mtl.m g_dispatch_dim），翻译器要把读处映过去：
# ULDC UR4 ← c[0][4]、UR5 ← c[0][8]、UR6 ← c[0][0xc]，三个值经 STG 写进存储槽 0（布局：推送 0、uniform 0、storage 1 → 槽 0 的地址在 c[0] 0x10 → 宿主表 0x310）。
# 期望（按宿主布局手算）：MSL 读 c[0] 第 32 个 vec4 的 x / y / z（0x200 / 0x204 / 0x208），不再读第 0 个 vec4 的 y / z / w（修前原地读 0x4..0xc，宿主那里是 0 → 除以 0）
ULDC0 = lambda urd, off: inst(0xab9, urd=(16, urd), off=(38, off), bank=(54, 0), size=(73, 4))   # ULDC.32 URd, c[0][off]
STG32 = lambda ra, rb, off: inst(0x386, ra=(24, ra), rb=(32, rb), off=(40, off), e=(72, 1), size=(73, 4))   # STG.E.32 [Ra.64 + off], Rb
def c0_dims(msl, j):
    got = sorted(set(re.findall(r'cp_c0\)?\._m0\[(\d+)u?\]\.([xyzw])', msl)))
    want = [('32', 'x'), ('32', 'y'), ('32', 'z')]
    return None if all(w in got for w in want) and not any(g[0] == '0' for g in got) else f'c[0] 读处 {got}，应含 {want}、不含第 0 个 vec4'
refl('计算 c[0] 0x4 / 0x8 / 0xc 线程组数映到宿主 0x200（时之笛 21d9f83e6027c565）', True,
     cs_shader([ULDC0(4, 0x4), ULDC0(5, 0x8), ULDC0(6, 0xc), LDC64(8, 0x10), MOVU(0, 4), MOVU(1, 5), MOVU(2, 6), STG32(8, 0, 0), STG32(8, 1, 4), STG32(8, 2, 8)], ssbos=1),
     c0_dims, '宿主只在 c[0] + 0x200 放派发的线程组数；修前原地读 0x4..0xc 得 0，21d9 除以 0、天空辐照度和成 inf / NaN')

# ATOMS.ADD.F32.FTZ.RN（0x38c，大小 73..76 = 3、操作 87..91 = 0 加）：共享内存上的浮点加（11-06，上游参考实现（MIT）b1d7c707 的比较交换循环扩到所有存储种类；
#   我方 a83499002 只做了全局内存，共享内存走「Invalid reduction type」记一行丢掉）。期望：MSL 里有线程组内存上的比较交换（atomic_compare_exchange 落在 threadgroup atomic_uint*），
#   反射 notes 里没有 Invalid reduction；结果经 STG 写进存储槽 0，原子不会被当死代码删。控制段 +0x58 线程组 32×1×1、+0x64 共享内存 16 字节（Dsh.cs Nvn2Job 读的字段）
ATOMS_F32 = lambda rd, rb, off: inst(0x38c, rd=(16, rd), ra=(24, RZ), rb=(32, rb), off=(40, off), size=(73, 3), op=(87, 0))
def cs_shared(job, shared=16):
    st, code, ctl = job; ctl = bytearray(ctl); struct.pack_into('<IIII', ctl, 0x58, 32, 1, 1, shared); return (st, code, bytes(ctl))
def shared_f32_cas(msl, j):
    if 'Invalid reduction' in (j if isinstance(j, str) else json.dumps(j)): return '反射 notes 里有 Invalid reduction（浮点加被丢弃）'
    return None if re.search(r'atomic_compare_exchange\w*\(\(threadgroup atomic_uint\*\)', msl) else 'MSL 里没有线程组内存上的比较交换'
refl('ATOMS.ADD.F32 共享内存：比较交换循环（b1d7c707）', True,
     cs_shared(cs_shader([MOVI(5, f32(1.5)), ATOMS_F32(0, 5, 4), LDC64(8, 0x10), STG32(8, 0, 0)], ssbos=1)), shared_f32_cas,
     '共享内存字 1 上加 1.5：Load → FPAdd → 比较交换、不等重来，返回加之前的值；修前只认全局内存，记一行丢掉')

# 只有派发里第一个调用做的存储（11-06，上游参考实现（MIT）c8521eeb + e07cba1c first_store；时之笛 4,091 支计算着色器里 0 支有这形状，补齐给斯普拉遁 突击队 / 马车世界这类）：
#   S2R R0 = 工作组号 x、R1 = 线程号 x，R2 = R0 << 5，R3 = -R1，ISETP.NE P0 = R3 != R2（只有 R0 = R1 = 0 时假），@!P0 STG [存储槽 0 + 4] ← RZ（清零），
#   随后各线程 STG [+8] ← R1 + R2。线程组 32×1×1（答案表行给 local）。期望（手推）：反射 first_store = [{reg 0（存储槽 0）, word 1（偏移 4 / 4）, value 0}]，
#   MSL 里不再有守卫 if (!…) 下的 = 0u 存储；各线程那条照旧。修前没有 first_store、存储留在着色器里（Apple GPU 工作组不分先后，晚到的清零抹掉先追加的）
S2R = lambda rd, sr: inst(0x919, rd=(16, rd), sr=(72, sr))
SHL32 = lambda rd, ra, n: alu(0x019, 4, rd, ra, imm=(32, n), rc=(64, RZ), ty=(73, 3))   # SHF.L.U32 Rd = Ra << n
NEGR = lambda rd, ra: alu(0x010, 1, rd, ra, rb=(32, RZ), rc=(64, RZ), ng=(72, 1), p0=(81, PT), p1=(84, PT), q0=(87, PT), q1=(77, PT))   # IADD3 Rd = -Ra
ISETP_NE = lambda p, ra, rb: alu(0x00c, 1, RZ, ra, rb=(32, rb), s=(73, 1), cmp=(76, 5), pd=(81, p), pd2=(84, PT), ps=(87, PT))
def not_p0(v): return v & ~(0xf << 12) | 8 << 12   # 守卫 @!P0
def first_store_refl(msl, j):
    j = json.loads(j) if isinstance(j, str) else j
    if j.get('first_store') != [{'reg': 0, 'word': 1, 'value': 0}]: return f'反射 first_store = {j.get("first_store")}，应 [{{reg 0, word 1, value 0}}]'
    if re.search(r'if \(!_\d+\)\s*\{[^{}]*\{[^{}]*= 0u;', msl): return 'MSL 里守卫下的清零存储还在'
    return None if '= uint(' in msl else '各线程那条存储不见了'
refl('第一个调用的存储挪给宿主（first_store）', True,
     cs_shader([S2R(0, 0x25), S2R(1, 0x21), SHL32(2, 0, 5), NEGR(3, 1), ISETP_NE(0, 3, 2), LDC64(8, 0x10), not_p0(STG32(8, RZ, 4)), IADD3(4, 1, 2), STG32(8, 4, 8)], ssbos=1) + ({'local': [32, 1, 1]},),
     first_store_refl, '-线程号 == 工作组号 << log2(32) 只对整个派发的第一个调用成立：清零挪到派发前由宿主写')

def ts_shader(body, payload=0x100):
    """NVN2 任务着色器：代码区 = 0x80 字节 SPH（任务不读）+ 指令，补齐到 0x80；控制段 0xe0 字节：魔数、版本 0xc9、+0x38 指令区长、+0x40 / +0x44 c1（空）、
    +0x56 阶段 6（任务）、+0x58 线程 32、+0x5a 载荷字节数（t_meshstage.py ctl 同一套字段）"""
    code = bytes(0x80) + b''.join(i.to_bytes(16, 'little') for i in body + [EXIT]); code += bytes(-len(code) % 0x80)
    ctl = bytearray(0xe0); struct.pack_into('<II', ctl, 0, 0x98761234, 0xc9); struct.pack_into('<I', ctl, 0x38, len(code)); struct.pack_into('<II', ctl, 0x40, len(code), len(code))
    ctl[0x56] = 6; struct.pack_into('<HH', ctl, 0x58, 32, payload)
    return ('ts', code, bytes(ctl))
# ISBERD 模式 0xb8 = 读本阶段输出区（任务的载荷）的字，与 0x927 的 0xb8 写同一处：时之笛 5d3a096025e375a1（任务）先 0x927 b8 [RZ + 0x10] ← R4，紧接 ISBERD R5 ← b8 [RZ + 0x10]
STO = lambda off, rb: inst(0x927, ra=(24, RZ), rb=(32, rb), off=(40, off), mode=(72, 0xb8))
ISB = lambda rd, off, mode: inst(0x923, rd=(16, rd), ra=(24, RZ), off=(40, off), mode=(72, mode))
refl('ISBERD.b8 读回任务自己写的载荷字（时之笛 5d3a096025e375a1）', True,
     ts_shader([MOVI(4, 0x1234), STO(0x10, 4), ISB(5, 0x10, 0xb8), STO(0x14, 5)]),
     lambda msl, j: (lambda m: None if m and re.search(r'= (?:as_type<\w+>\()?%s\[%s\]' % (m.group(1), m.group(2)), msl) and re.search(r'%s\[%d\] = ' % (m.group(1), int(m.group(2)) + 1), msl)
                     else '读回的不是刚写的那个阶段内存字（或没写到 +0x14）')(re.search(r'(\w+)\[(\d+)\] = 4660u;', msl)),
     '写 [+0x10] = 0x1234、读回同一个字、再写 [+0x14]（下一个字）；修前「ISBERD mode b8 in a task or mesh shader」拒翻')

# 投票的位掩码留在原处（04008E001F098000 近海任务着色器 8acb4308：最低活动车道之外都 return 之后才写 popcount(ballot)）：任务着色器 32 线程，
#   S2R R0 = 车道号，P1 = 车道号 != 0，VOTE.ANY R5 ← ballot(P1)（31 个车道置位），全体车道先写 POPC(R5) 到载荷 +0x10，@P1 EXIT，剩下的车道 0 再写 POPC(R5) 到 +0x14。
#   期望（手推）：位掩码在 return 之前就取（硬件上 VOTE 执行时 32 车道都在：两处 POPC 都是 31）。修前 AST 优化把位掩码（一元运算、源是变量，用两次也挪）
#   复制到每个使用处，第二处落在其他车道 return 之后，只剩车道 0 自己（它的 P1 假，POPC = 0；近海每组 32 块只画 1 块）。
#   用任务着色器：计算着色器这条单测链不做表达式传播，测不出来；谓词要是车道变量：常量 ballot(true) 修前也不挪
VOTE_ANY = lambda rd, p: inst(0x806, rd=(16, rd), mode=(72, 1), pd=(81, PT), p=(87, p))
POPC = lambda rd, rb: alu(0x109, 1, rd, RZ, rb=(32, rb))
def at_p1(v): return v & ~(0xf << 12) | 1 << 12   # 守卫 @P1
def ballot_before_return(msl, j):
    body = msl[msl.find('dm_stage_body'):] if 'dm_stage_body' in msl else msl
    r = body.find('return;'); bs = [m.start() for m in re.finditer(r'spvSubgroupBallot\(', body)]
    if not bs: return 'MSL 里没有 spvSubgroupBallot'
    return None if r < 0 or max(bs) < r else '位掩码在其他车道 return 之后才取'
refl('投票位掩码不挪过提前返回（近海 8acb4308）', True,
     ts_shader([S2R(0, 0x00), ISETP_NE(1, 0, RZ), VOTE_ANY(5, 1), POPC(7, 5), STO(0x10, 7), at_p1(EXIT), POPC(6, 5), STO(0x14, 6)]),
     ballot_before_return, 'VOTE 在全体车道都在时取位掩码，车道 0 之后才 POPC：位掩码不能等到 POPC 处才算')

# 多处池表读（11-05 时之笛慢编；11-07 时之笛主遍顶点）：地址从内存里读出来的全局读，翻译器追不到具体存储缓冲，走查内存池表。11-05 把整个查表函数改成不内联（每处一份展开时
# 3d0d6d61bb9076e7 253 处、IR 6.5 万条），可函数带线程私有字（上次命中项）的引用，调用点按调用约定存栈取栈：时之笛主遍顶点着色器每顶点 253 次调用、主遍六成时间。
# 11-07：每处访问的辅助函数内联（区间缓存在私有字里，命中不查表），只有查找（提示字 + 二分 + 访问位图）全着色器一份、不内联、不带私有字引用。
# 这里：LDC64 R8 = c[0] 0x510（追得到的存储缓冲）、LDG.64 R10 ← [R8.64]（读出一个地址），再对 [R10.64]、[R10.64 + 4]、[R10.64 + 8] 各读一次 → 3 处池表读。
# 期望：不内联的函数恰 1 个、参数里没有可写线程引用（thread 后不跟 const）、入口不直接调它；内联的访问函数被入口调用 3 次、函数体里调查找
LDG64 = lambda rd, ra: inst(0x381, rd=(16, rd), ra=(24, ra), e=(72, 1), size=(73, 5))
LDGO = lambda rd, ra, off: inst(0x381, rd=(16, rd), ra=(24, ra), off=(40, off), e=(72, 1), size=(73, 4))
LDG128 = lambda rd, ra: inst(0x381, rd=(16, rd), ra=(24, ra), e=(72, 1), size=(73, 6))   # LDG.E.128 Rd..Rd+3 ← [Ra.64]（LsSize B128 = 6）
STG128 = lambda ra, rb, off: inst(0x386, ra=(24, ra), rb=(32, rb), off=(40, off), e=(72, 1), size=(73, 6))   # STG.E.128 [Ra.64 + off] ← Rb..Rb+3
def msl_fns(msl):
    """MSL 的辅助函数 → {名: (不内联?, 参数串, 函数体)}；入口（fragment / vertex / kernel）的函数体拼在一起作 '<入口>'"""
    fns = {m.group(2): (m.group(1) == 'noinline', m.group(3), m.group(4))
           for m in re.finditer(r'static (?:inline )?__attribute__\(\((always_inline|noinline)\)\)\n\w[\w <>:,*&]* (\w+)\(([^\n]*)\)\n\{(.*?)\n\}\n', msl, re.S)}
    fns['<入口>'] = (False, '', ''.join(re.findall(r'\n(?:fragment|vertex|kernel) [^\n]*\n\{(.*?)\n\}\n', msl, re.S)))
    return fns
def calls(body, name): return len(re.findall(r'\b%s\(' % name, body))
def pool_split(n):
    def f(msl, j):
        fns = msl_fns(msl)
        slow = [k for k, v in fns.items() if v[0]]
        if len(slow) != 1: return f'不内联的函数应有 1 个，实有 {len(slow)}'
        if re.search(r'\bthread (?!const\b)', fns[slow[0]][1]): return f'不内联的查找 {slow[0]} 带可写线程引用（{fns[slow[0]][1]}）：私有字会进栈'
        if calls(fns['<入口>'][2], slow[0]): return f'入口直接调不内联的 {slow[0]}（每处访问一次调用）'
        fast = [k for k, v in fns.items() if not v[0] and k != '<入口>' and calls(v[2], slow[0])]
        got = sum(calls(fns['<入口>'][2], k) for k in fast)
        return None if len(fast) == 1 and got == n else f'调查找的内联访问函数 {fast}，入口调它们 {got} 次，应 1 个、{n} 次'
    return f
refl('多处池表读：查找只一份、不内联、不带私有字；访问的快路内联', True,
     [LDC64(8, 0x510), LDG64(10, 8), LDGO(0, 10, 0), LDGO(1, 10, 4), LDGO(2, 10, 8), MOVI(3, 0)], pool_split(3),
     '3 处地址取自内存的全局读：修前不内联的整个查表函数带上次命中项的线程引用、入口调 3 次（调用点存栈取栈）')
def vec_pieces(msl, j):
    fns = msl_fns(msl)
    slow = [k for k, v in fns.items() if v[0]]
    if len(slow) != 1: return f'不内联的函数应有 1 个，实有 {len(slow)}'
    entry = fns['<入口>'][2]
    used = {k: calls(entry, k) for k in fns if k != '<入口>' and calls(entry, k)}
    full = [k for k in used if calls(fns[k][2], slow[0])]
    piece = [k for k in used if k not in full]
    if [used[k] for k in full] != [1]: return f'入口调查表的访问函数 {[(k, used[k]) for k in full]}，应 1 个调 1 次（第一个字）'
    if [used[k] for k in piece] != [3]: return f'入口调不查表的访问函数 {[(k, used[k]) for k in piece]}，应 1 个调 3 次（后三个字）'
    return None if not re.search(r'_s\d+\b', fns[piece[0]][1]) else f'后三个字的函数 {piece[0]} 还带池表参数（{fns[piece[0]][1]}）'
refl('LDG.128 原始读：只第一个字查表，后三个字用它选中的项', True, [LDC64(8, 0x510), LDG64(10, 8), LDG128(0, 10)], vec_pieces,
     '对齐的 16 字节在同一页、同一项（宿主的项由整页的池组成）；修前四个字各调一次整个查表函数')


# ==== 原始池表（11-06 时之笛，上游参考实现（MIT）b1d7c707 / 0f510fd5）：地址从内存读来的全局访问，翻译器追不到具体存储缓冲，按宿主的原始池表查池
#   （GlobalToStorage.TryGenerateRawStorageOp）。表 8,191 项（GmemMapLog2 13）、2 MiB 块提示字、上次命中项（每个查表函数一个线程私有字，初值 0 = 空项）、写记录是每项一位的位图。
#   frag_run -P 项号:起点:提示 照宿主格式建表：第「项号」项 = 池 A [起点, 起点 + 4 MiB)（字 i = 0xa0000000 | i），下一项 = 池 B 紧接 A（字 i = 0xb0000000 | i），
#   前面垫满小区间把它们推到项号处；输出在 R0..R3 之后再打写记录里 A、B 所在的两个字。输入块（存储缓冲 0）：字 0..1 = 地址 1，字 2..3 = 地址 2，字 4 = 要写的值。
#   LDC64 R8 ← c[0][0x510]（存储缓冲 0）、LDG.64 R10 ← [R8]、LDG.64 R12 ← [R8 + 8]：R10 / R12 是从内存读出的地址，再经它们读写 → 原始池表访问
LDG64O = lambda rd, ra, off: inst(0x381, rd=(16, rd), ra=(24, ra), off=(40, off), e=(72, 1), size=(73, 5))
RAW_HEAD = [LDC64(8, 0x510), LDG64(10, 8), LDG64O(12, 8, 8)]
def lohi(a): return [a & 0xffffffff, a >> 32]
PS = 4 << 20
G1, G2 = 0x200400000, 0x300000000   # 都在 4 GiB 之上：地址高字非 0
case('原始读：池在第 5000 项、走 2 MiB 提示字', True, lohi(G1 + 0x10) + lohi(G1 + PS + 8),
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 10, 4), LDGO(2, 12, 0), LDGO(3, 10, 8)], [0xa0000004, 0xa0000005, 0xb0000002, 0xa0000006, 0, 0],
     '表 8,191 项：第 5000 项够得着（修前只查 4,096 项、读 0）；A、A、B、A 交替：上次命中项不含地址时重查（B 不能按 A 的差值读）；只读不写，写记录全 0', ('pool', 5000, G1, 1))
case('原始读：池在第 6000 项、无提示字（走 13 步二分查找）', True, lohi(G2 + 0x3ffff0) + lohi(G2 + PS),
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 12, 0), LDGO(2, 10, 4), LDGO(3, 12, 4)], [0xa00ffffc, 0xb0000000, 0xa00ffffd, 0xb0000001, 0, 0],
     'A 末尾 16 字节内与 B 开头（相邻两项的边界两侧）', ('pool', 6000, G2, 0))
case('原始读：地址不在任何池里读 0', False, lohi(G1 + 0x10) + lohi(G1 + 2 * PS + 0x100),
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 12, 0), LDGO(2, 10, 4), LDGO(3, 12, 4)], [0xa0000004, 0, 0xa0000005, 0, 0, 0],
     'B 之后（没有池）读 0，其间夹着 A 的读：上次命中项是 A 时，池外地址不能借 A 的差值', ('pool', 100, G1, 1))
case('原始写：写进 B、写记录位图置 B 那一项的位', True, lohi(G1 + 0x10) + lohi(G1 + PS + 0x40) + [0x12345678],
     RAW_HEAD + [MOVC(4, 4), STG32(12, 4, 0), LDGO(0, 12, 0), LDGO(1, 10, 0), MOVI(2, 0), MOVI(3, 0)], [0x12345678, 0xa0000004, 0, 0, 1 << 5, 1 << 5],
     'B = 第 101 项 → 第 3 个字的位 5（修前写记录是按页的哈希集合，这个字不是 0x20）；同一线程读回刚写的值', ('pool', 100, G1, 1))

# ==== 按需常驻（11-06 Switch2 线，nvn_mtl.m gmem_map / gmem_scan）：池表只把常驻的池当可访问；没常驻的池那一项终点 = 起点、真终点在差值字里，
#   字 7 = 宿主访问位图里的位号 + 1，第 0 项差值字 = 访问位图地址。frag_run -P …:1：A 常驻要记（位 5）、B 不常驻（位 9）；输出多两个字：访问位图第 0 字、B 的第 16 字。
#   期望按约定手算：读 / 写 B 一律跳过（读 0、B 的存储不变、写记录不置位），B 的位 9 置上；A 照常读写，位 5 置上；不在任何池里（选中第 0 项）不记位。
#   旧翻译（不认字 7 / 冷项）：B 同样跳过（终点 = 起点，GPU 不碰不常驻的内存），但访问位图全 0 → 标「新」的例红
B40 = 0xb0000000 | 16
case('按需常驻：读常驻池 A 记位 5、读不常驻池 B 得 0 并记位 9（提示字）', True, lohi(G1 + 0x10) + lohi(G1 + PS + 8),
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 12, 0), LDGO(2, 10, 4), LDGO(3, 12, 4)], [0xa0000004, 0, 0xa0000005, 0, 0, 0, (1 << 5) | (1 << 9), B40],
     'A、B、A、B 交替：B 的项走提示字选中，冷项不按差值字（真终点）解引用；GPU 不碰不常驻的 B', ('pool', 5000, G1, 1, 1))
case('按需常驻：不常驻池 B 走二分查找也得 0 并记位', True, lohi(G2 + 0x3ffff0) + lohi(G2 + PS),
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 12, 0), LDGO(2, 10, 4), LDGO(3, 12, 4)], [0xa00ffffc, 0, 0xa00ffffd, 0, 0, 0, (1 << 5) | (1 << 9), B40],
     'A 末尾与 B 开头（相邻两项边界两侧），无提示字', ('pool', 6000, G2, 0, 1))
case('按需常驻：写不常驻池 B 被丢、写记录不置位、记位 9', True, lohi(G1 + 0x10) + lohi(G1 + PS + 0x40) + [0x12345678],
     RAW_HEAD + [MOVC(4, 4), STG32(12, 4, 0), LDGO(0, 12, 0), LDGO(1, 10, 0), MOVI(2, 0), MOVI(3, 0)], [0, 0xa0000004, 0, 0, 0, 0, (1 << 5) | (1 << 9), B40],
     'B 的第 16 字仍是 0xb0000010（没写进去）；写记录 B 那一位 0：宿主不会把没发生的写当已写', ('pool', 100, G1, 1, 1))
case('按需常驻：不在任何池里的地址（选中第 0 项）不记位', True, lohi(G1 + 0x10) + [0x10, 0],
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 12, 0), LDGO(2, 10, 4), LDGO(3, 12, 4)], [0xa0000004, 0, 0xa0000005, 0, 0, 0, 1 << 5, B40],
     '第 0 项起点 = 终点 = 0、差值字是位图地址：形似冷项，字 7 = 0 不记；只有 A 的位 5', ('pool', 100, G1, 1, 1))

# 11-07 区间缓存与向量访问（期望按约定手算，同上）：缓存区间的边界 = 项的终点（A 末字命中 A、B 首字不能借 A 的差值）；LDG / STG .128 只第一个字查表，后三个字用它选中的项、
#   第一个字被跳过（池不常驻）时一起跳过（修前四个字各调不内联的整个查表函数，这三例的 MSL 运行时编译失败、无错误信息）。负对照（改翻译器后跑，见 docs/坑记录.md 11-07 条）：区间判断边界改成 ≤ 终点 → 边界例红；后三个字不看「被跳过」→ 不常驻例红
case('原始读：A 末字与 B 首字交替（区间缓存的边界）', False, lohi(G2 + PS - 4) + lohi(G2 + PS),
     RAW_HEAD + [LDGO(0, 10, 0), LDGO(1, 12, 0), LDGO(2, 10, 0), LDGO(3, 12, 0)], [0xa00fffff, 0xb0000000, 0xa00fffff, 0xb0000000, 0, 0],
     'B 首字 = A 的终点：缓存着 A 时偏移 = A 的大小，不在区间里，重查得 B', ('pool', 6000, G2, 0))
case('LDG.128 原始读：先读 A、再从 B 读四个字（R7 不用）', True, lohi(G1 + 0x10) + lohi(G1 + PS + 0x20),
     RAW_HEAD + [LDGO(0, 10, 0), LDG128(4, 12), MOVR(1, 4), MOVR(2, 5), MOVR(3, 6)], [0xa0000004, 0xb0000008, 0xb0000009, 0xb000000a, 0, 0],
     'B 的第一个字查表换项，后两个字按 B 的差值', ('pool', 5000, G1, 1))
case('LDG.128 原始读：不常驻池 B 的四个字一起跳过、只记位 9', True, lohi(G1 + 0x10) + lohi(G1 + PS + 0x20),
     RAW_HEAD + [LDGO(0, 10, 0), LDG128(4, 12), MOVR(1, 4), MOVR(2, 5), MOVR(3, 6)], [0xa0000004, 0, 0, 0, 0, 0, (1 << 5) | (1 << 9), B40],
     '第一个字的项是冷项：查找记位、跳过；后两个字不能借缓存里 A 的差值', ('pool', 5000, G1, 1, 1))
case('STG.128 原始写：写进 B 四个字再读回、写记录置 B 的位', True, lohi(G1 + 0x10) + lohi(G1 + PS + 0x40) + [0x11, 0x22, 0x33, 0x44],
     RAW_HEAD + [MOVC(4, 4), MOVC(5, 5), MOVC(6, 6), MOVC(7, 7), STG128(12, 4, 0), LDG128(0, 12)], [0x11, 0x22, 0x33, 0x44, 1 << 5, 1 << 5],
     'B = 第 101 项 → 写记录第 3 字位 5；第一个字记写记录，后三个字同一项', ('pool', 100, G1, 1))

def raw_kinds(want_rw, want_log):
    def f(msl, j):
        j = json.loads(j) if isinstance(j, str) else j
        b = {x.get('kind'): x for x in j.get('bindings', ())}
        if 'sbuf_ubo' in b: return f'哨兵槽 0xff 还被当成统一缓冲槽 {b["sbuf_ubo"].get("reg")}（sbuf_ubo）'
        if 'gmem_map' not in b: return f'没有 gmem_map 绑定（种类 {sorted(b)}）'
        if bool(b['gmem_map'].get('rw')) != want_rw: return f'gmem_map rw = {b["gmem_map"].get("rw")}，应 {want_rw}'
        if ('gmem_log' in b) != want_log: return f'gmem_log {"有" if "gmem_log" in b else "没有"}，应{"有" if want_log else "没有"}'
        return None
    return f
refl('原始池表的反射种类：只读', True, RAW_HEAD + [LDGO(0, 10, 0), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)], raw_kinds(False, False),
     '哨兵槽 0xff 偏移 0 → gmem_map（不可写），没有写记录；修前成 sbuf_ubo reg 252，宿主绑哑缓冲')
refl('原始池表的反射种类：有写', True, RAW_HEAD + [MOVC(4, 4), STG32(12, 4, 0), MOVI(0, 0), MOVI(1, 0), MOVI(2, 0), MOVI(3, 0)], raw_kinds(True, True),
     '有 Store 走池表 → gmem_map 可写，偏移 1 → gmem_log')
def ts_local_word(msl, j):
    if 'void dm_stage_body(' not in msl: return '没有阶段本体 dm_stage_body'
    body = msl[msl.index('void dm_stage_body('):]; body = body[:body.find('\n}\n')]
    return None if re.search(r'\n    uint _\d+ = 0u;\n', body) else '上次命中项的线程字（uint _N = 0u;）不在阶段本体里'
refl('任务着色器里的原始读：上次命中项的线程字留在阶段本体里', True, ts_shader([LDC64(8, 0x670), LDG64(10, 8), LDGO(4, 10, 0), STO(0x10, 4)]), ts_local_word,
     'SPIRV-Cross 把带初值的私有变量排在阶段内存前（0f510fd5 同改 dmsh_meshstage）；修前 MeshStage 认不出 kernel 开头，整支「没有以阶段内存开头的 kernel main0」')


def arg_spec(msl, refl_j=None):
    """MSL 里参数缓冲（spvDescriptorSetBufferN）的成员 → frag_run 的 -a 项：常量缓冲指向输入块、gal_ubo_len 指向界长表；
    refl_j（原始池表例）：反射种类 gmem_map / gmem_log 的成员 → 池表 / 写记录，spvBufferSizeConstants → 不钳的字节数表（其余例照旧指向输入块）"""
    out = []; pk = {}
    if refl_j is not None:
        j = json.loads(refl_j) if isinstance(refl_j, str) else refl_j
        pk = {b['msl_name']: {'gmem_map': 'map', 'gmem_log': 'log'}[b['kind']] for b in j.get('bindings', ()) if b.get('kind') in ('gmem_map', 'gmem_log')}
        pk['spvBufferSizeConstants'] = 'sz'
    for m in re.finditer(r'struct spvDescriptorSetBuffer(\d+)\n\{(.*?)\n\};', msl, re.S):
        for mm in re.finditer(r'(\w+) \[\[id\((\d+)\)\]\]', m.group(2)):
            nm = mm.group(1)
            kind = pk[nm] if nm in pk else 'len' if nm == 'gal_ubo_len' else 'sup' if nm == 'support_buffer' else 'samp' if nm.endswith('Smplr') else 'tex' if re.match(r'fp_t_', nm) else 'in'
            out += ['-a', f'{m.group(1)}:{mm.group(2)}:{kind}']
    slots = re.findall(r'spvDescriptorSetBuffer(\d+)& \w+ \[\[buffer\((\d+)\)\]\]', msl)
    if any(a != b for a, b in slots): raise SystemExit(f'✗ 参数缓冲槽与集合号不一致：{slots}（frag_run 按集合号当槽）')
    return out


def main():
    global CASES, REFL
    run = sys.argv[1]
    if '--filter' in sys.argv:
        pattern = re.compile(sys.argv[sys.argv.index('--filter') + 1])
        CASES = [c for c in CASES if pattern.search(c[0])]
        REFL = [c for c in REFL if pattern.search(c[0])]
        if not CASES and not REFL: raise SystemExit('筛选未命中用例')
    if '--list' in sys.argv:
        for c in CASES + REFL: print(('新 ' if c[1] else '旧 ') + c[0])
        return 0
    ir_bad = False
    if any(c[0].startswith('maxwell_shf_') for c in CASES):
        import shf_ir_test
        ir_bad = shf_ir_test.main() != 0   # 继续跑 GPU，旧 DLL 不能因 CPU 红而省略 GPU 负控
    jobs = [('ampere_compile', [st, code.hex(), ctl.hex(), json.dumps({'fout': {'0': 'uint'}})]) for _, _, _, body, _, _, _ in CASES for st, code, ctl in [refl_job(body)]]
    jobs += [('ampere_compile', [st, code.hex(), ctl.hex(), json.dumps(fx[0] if fx else {'fout': {'0': 'uint'}} if st == 'ps' else {})]) for _, _, body, _, _ in REFL for st, code, ctl, *fx in [refl_job(body)]]   # 第 4 项：答案表行（缺省同出包）
    res = dshfn.batch(jobs, dsx=dshfn.DSX)
    res, rres = res[:len(CASES)], res[len(CASES):]
    bad = 0
    for (name, new, body, check, why), r in zip(REFL, rres):
        v = r.get('ok')
        err = f'翻不过 {v[1:] if isinstance(v, list) else r}' if not isinstance(v, list) or v[0] == 'fail' else check(v[0], v[1])
        bad += err is not None
        print(f'{"✓" if err is None else "✗"} {name}：{"符合" if err is None else err}（{why}）')
    # 全部 GPU 用例交给一个 frag_run 进程（--batch，一行一例）：每个用 Metal 的进程退出都会永久漏掉 1 个 IOSurface 名额（macOS 26.4.1 驱动），原先每例一个进程
    with tempfile.TemporaryDirectory() as t:
        lines, todo = [], []
        for i, ((name, new, inputs, body, want, why, tex), r) in enumerate(zip(CASES, res)):
            v = r.get('ok')
            if not isinstance(v, list) or v[0] == 'fail':
                bad += 1; print(f'✗ {name}：翻不过 {v[1:] if isinstance(v, list) else r}'); continue
            mp = os.path.join(t, f'f{i}.metal'); open(mp, 'w').write(v[0])
            pool = tex and tex[0] == 'pool'
            texarg = ['-P', f'{tex[1]}:{tex[2]:x}:{tex[3]}' + ''.join(f':{x}' for x in tex[4:])] if pool else ['-T', f'{os.environ.get("TBUF_FORM", tex[0]) if tex[0] not in ("tex1d", "tex2d") else tex[0]}:{tex[1]}'] if tex else []   # TBUF_FORM=fixed：负对照
            lines.append('\t'.join([mp, *arg_spec(v[0], v[1] if pool else None), *texarg, *[f'{w:08x}' for w in inputs]])); todo.append((name, want, why))
        p = subprocess.run([run, '--batch'], input='\n'.join(lines) + '\n', capture_output=True, text=True, timeout=60 + 5 * len(lines))
        outs = p.stdout.splitlines()
        if len(outs) != len(todo): bad += 1; print(f'✗ frag_run 批量只回了 {len(outs)} / {len(todo)} 行（退出 {p.returncode}）：{p.stderr.strip()[:300]}')
        for (name, want, why), o in zip(todo, outs):
            f = o.split('\t')
            got = [int(w, 16) for w in f[1].split()] if f[0] == 'ok' else None
            ok = got == want; bad += not ok
            print(f'{"✓" if ok else "✗"} {name}：期望 {" ".join(f"{w:08x}" for w in want)} → 真结果 {" ".join(f"{w:08x}" for w in got) if got else f[-1][:200]}（{why}）')
    n = len(CASES) + len(REFL)
    print(f'Ampere 指令单测：{n - bad}/{n} 例过（GPU 读回 {len(CASES)} 例 + 只看翻译结果 {len(REFL)} 例；标「新」的 {sum(c[1] for c in CASES) + sum(c[1] for c in REFL)} 例）')
    return 1 if bad or ir_bad else 0


if __name__ == '__main__': sys.exit(main())
