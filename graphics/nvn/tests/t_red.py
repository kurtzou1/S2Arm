#!/usr/bin/env python3
# 采样器 LOD 偏置 / min / max 归约的着色器侧单测（#800；S2A.Dsh DshCompiler.FsLb / FsRd / RedHelp：graphics/tools/direct/dsh/Dsh.cs，经 dsh_cmp --fn 调（graphics/tools/direct/tests/dshfn.py）；
#   graphics/nvn/gfx/nvn/nvn_red.h nvn_red_entry）：脱离游戏，在 Mac 上跑
#   （要 macOS 26：Metal 原生 reductionMode / lodBias 作对照）。偏置不出变体：每支片元 / 计算的 main0 自己加，偏置从参数块成员 s2a_lb[采样器成员 id] 读（宿主 lb_fill 写：
#   本机不原生写采样器的 lod_bias，原生写 0）；归约出变体 <键>_se（fs_rd），库里不带、设备上首遇时后台出（nvn_mtl.m se_kick）。改写只有 C# 一份（出包与设备现编同用）。
#   ① 改写逐字核（期望手写）：
#      fs_lb：经单个采样器成员的每次采样加 b = spvDescriptorSet0.s2a_lb[采样器 id]：level(l) → level((l) + b)、bias(x) → bias((x) + b)、gradient → 两个导数 × precise::exp2(b)、
#        没写 LOD → 片元插 bias(b) / 计算插 level(b)（计算只带 min_lod_clamp(m) 的 → level(max(b, m))）；参数块末尾加 constant float* s2a_lb [[id(下一个)]]（数组成员占 n 个 id）；
#        没有可改的采样 / 没有单个采样器成员 / 顶点着色器 / 采样在 main0 之外 / 参数块 id 已到 191 → 原样；已有 s2a_lb → 原样（不叠）
#        深度比较采样 sample_compare 同样加（缺口族 31，LOD 参数排在参考值之后）
#      fs_rd（变体格式 3，11-01）：经单个采样器成员采浮点贴图的每次 sample 改成 s2a_bs(贴图, 采样器, s2a_red[id], 其余参数…)（任意边界色）；其中显式 level 的 2D / 2D 数组
#        （带层号、偏移）再包成「(s2a_red[id].m.x != 0.0 ? (s2a_rs(...)) : (s2a_bs(...)))」，LOD 取 fs_lb 留下的 level((l) + b) 里的 l；fs_lb 给隐式采样插的 level(b) /
#        level(max(b, m)) 不归约；版本行 + RED_HELP + main0 末尾加 constant S2ASe* s2a_red [[buffer(26)]]；main0_u 原样；比较采样 / 非浮点贴图不改；没有可改的 → 原样
#      守卫（真库，动森离线 B 库全部片元 / 计算，S2A_RED_LIB 可改目录）：fs_lb 输出逐处按上面的形态还原 = 输入逐字节；fs_rd 输出去掉包法 = fs_lb 输出逐字节
#      C 改写后的整份源码（片元与计算各一支）xcrun metal -c 编得过
#   ② 归约 GPU 对拍（t_red_run.m）：R32Float 2D / R32Float 2D 数组 / Depth32Float 2D 三张 8×8、4 级贴图，每级每个纹素各一个值；同一采样位置
#      期望 = 本机原生归约生效（Apple10）时取 Metal 26 原生 min / max 归约（采样器自己的过滤）的 .x、另核它等于 CPU 手算；非 Apple10 取 CPU 手算；
#      真结果 = 不带归约的采样器 + 着色器 s2a_rs，逐位相等。过滤组合 12 种（含最近点、缩小放大混合、mip 近邻，缺口族 31）。
#      反证：同样位置用平均采样必须有对不上的（一个纹素足迹的两种除外：表项 0、平均 = 归约）；mip 近邻按旧口径（两级）算必须有对不上的
#      任意边界色（缺口族 31）：RGBA32Float 2D / 2D 数组，夹边框、边界色 (0.25, 0.5, 0.75, 0.6)；期望 = CPU 按过滤定义手算（容差 1e-5）；真结果 = s2a_bs（表里透明黑 / 不透明白
#      两个采样器）；反证：绑定的采样器（Metal 最近的三种之一 = 改前）必须有对不上的；零表项 = 原采样逐位
#   ③ LOD 偏置 GPU 对拍（t_red_run.m --bias）：SPIRV-Cross 形态的计算核与片元核（隐式 / level / bias / gradient / 偏移 / 数组 / cube）原样 + fs_lb 改写后的主体；贴图第 L 级全部纹素 = L，
#      最近点 + mip 线性 → 读数 = 夹到 [0, 3] 的实际 LOD。期望 = 基础 LOD + 偏置 b 手算；真结果 = 主体 + 不带偏置的采样器 + s2a_lb 表写 b（本机不原生那一路），逐位，
#      唯一容差 gradient 形态 ±2/256 级（偏置只能乘进导数）；主体 + 带偏置的采样器 + 零表 与原样 main0 + 同一采样器逐位相等（任何 GPU；= Apple10 那一路）；本机原生偏置生效时另核它等于期望；
#      反证：原样 main0 + 不带偏置的采样器（改写前本机不吃采样器偏置时）对不上手算
#   ③' 比较采样 LOD 偏置 GPU 对拍（t_red_run.m --cmp，缺口族 31）：同 ③，贴图换 Depth32Float（第 L 级深度 0.1 + 0.25 L）、采样器比较 LESS，每项 = 参考值 0.2 / 0.45 / 0.7 三次比较之和
#      （= 所采级号，mip 线性 → 实际 LOD），期望手算同 ③
#   ④ #529 定点深度比较（t_red_run.m --dc）：比较采样参考值改写成 (s2a_lb[192 + id] != 0.0 ? saturate(r) : (r))；GPU 上深度 1.0、LessEqual、参考值 1.1 / 0.5：
#      表标志 0 → 0 / 1、标志 1 → 1 / 1；反证：原样 main0 → 0 / 1（Metal 的 Depth32Float 不替定点格式限制参考值）
# 用法：python3 graphics/nvn/tests/t_red.py（末行「t_red：N 项，失败 F」）；--emit / --emit-fs <主体> <归约变体>：给 t_nvn_red.m 写端到端核
import glob, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '../../..')); TOOLS = os.path.join(ROOT, 'translator')
sys.path.insert(0, os.path.join(ROOT, 'graphics/tools/direct/tests')); import dshfn   # noqa: E402
_memo = {}
def _call(name, src):
    if (name, src) not in _memo: _memo[(name, src)] = dshfn.fn(name, src)
    return _memo[(name, src)]
class R:   # 被测：C# S2A.Dsh（dsh_cmp --fn）。本测要的形态常量在下面按规格手写（VER / RED_PARAM / RED_CALL / RED_ENTRY），RED_HELP 从改写输出里取（GPU ② 核它的取值）
    fs_lb = staticmethod(lambda s: _call('fs_lb', s))
    fs_rd = staticmethod(lambda s: _call('fs_rd', s))
    next_id = staticmethod(lambda s: _call('next_id', s))
    helper_samples = staticmethod(lambda s: _call('helper_samples', s))
    RED_BEGIN = '// s2a:samp-emu 4 (S2A.Dsh FsRd)\n'
    RED_PARAM = ', constant S2ASe* s2a_red [[buffer(26)]]'   # 模拟表参数：宿主 nvn_mtl.m RED_SLOT = 26（下面核）
    RED_CALL = re.compile(r'spvDescriptorSet0\.(\w+)\.(sample|sample_compare)\(')   # fs_lb 改的两种采样
    RED_ENTRY = re.compile(r'^((?:\[\[[^\]]*\]\]\s*)*)(fragment|kernel) (\S+) main0\((.*)\)\n\{\n', re.M)
    RED_HELP = ''   # 见下面 FS 之后
    @staticmethod
    def balanced(s):
        d = 0
        for c in s:
            d += c in '(['; d -= c in ')]'
            if d < 0: return False
        return d == 0
# --emit <主体> <变体>：给端到端单测（t_nvn_red.m，make native-test-nvn_red）写一个计算核：spirv-cross 形状的参数块（2D 贴图 + 采样器 + 两个存储缓冲），
#   主体 = fs_lb 改写后（库里的 main0：偏置从 s2a_lb 读）、变体 = 再经 fs_rd（库里 / 兜底目录的 <键>_se，se_bind 绑 26 号槽）
E2E = ('#include <metal_stdlib>\nusing namespace metal;\n\nstruct spvDescriptorSetBuffer0\n{\n    texture2d<float> cp_t_tcb_8 [[id(0)]];\n    sampler cp_t_tcb_8Smplr [[id(1)]];\n'
       '    device float* cs_s0 [[id(2)]];\n    const device float4* cs_s1 [[id(3)]];\n};\n\n'
       'kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])\n{\n'
       '    float4 _9 = spvDescriptorSet0.cs_s1[gl_GlobalInvocationID.x];\n'
       '    spvDescriptorSet0.cs_s0[gl_GlobalInvocationID.x] = spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, _9.xy, level(_9.z)).x;\n}\n')
# --emit-fs：片元路径端到端（真 draw → se_want → pso_desc 取变体 → se_bind）：参数块 2D 贴图 + 采样器，画到 RGBA32F 4×4，每像素一个显式 level 采样
E2E_FS = ('#include <metal_stdlib>\nusing namespace metal;\n\n'
          'vertex float4 vs_main(uint vid [[vertex_id]]) { return float4(vid == 0 ? -1.0f : (vid == 1 ? 3.0f : -1.0f), vid == 2 ? 3.0f : -1.0f, 0.5f, 1.0f); }\n\n'
          'struct main0_out\n{\n    float4 m_0 [[color(0)]];\n};\n\n'
          'struct spvDescriptorSetBuffer0\n{\n    texture2d<float> cp_t_tcb_8 [[id(0)]];\n    sampler cp_t_tcb_8Smplr [[id(1)]];\n};\n\n'
          'fragment main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])\n{\n'
          '    main0_out out = {};\n'
          '    out.m_0 = float4(spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, float2(0.34375, 0.6875), level(0.0)).x);\n'
          '    return out;\n}\n')
if sys.argv[1:2] in (['--emit'], ['--emit-fs']):
    lb = R.fs_lb(E2E if sys.argv[1] == '--emit' else E2E_FS)
    # 片元照出包的样子再加 Alpha 测试 / 多重采样关的函数常量声明（Dsh.cs FsAlphaMs，族 34 / 37）：变体由同一份翻译改写，带着同样的声明，宿主取它的入口必须先特化
    #   （11-01 塞尔达第 653 帧 Metal 校验 abort「main0 cannot be used to build a pipeline state」：se_build / se_packed 用了裸 newFunctionWithName）
    if sys.argv[1] == '--emit-fs':
        lb = _call('fs_alpha_ms', lb)
        if 'S2A_AT [[function_constant(' not in lb: sys.exit('✗ fs_alpha_ms 没给端到端片元核加函数常量')
    rd = R.fs_rd(lb)
    if 's2a_lb [[id(' not in lb or 's2a_rs(' not in rd or 's2a_bs(' not in rd or not rd.startswith(R.RED_BEGIN) or 's2a_red [[buffer(26)]]' not in rd: sys.exit('✗ fs_lb / fs_rd 没改写端到端核')
    open(sys.argv[2], 'w').write(lb); open(sys.argv[3], 'w').write(rd); sys.exit(0)
n = bad = 0
def ck(ok, msg):
    global n, bad
    n += 1; bad += not ok; print(f'{"✓" if ok else "✗"} {msg}')

def grp(t, i):   # t[i] == '(' → 与它配对的 ')' 之后的下标
    d = 0
    for k in range(i, len(t)):
        d += t[k] in '(['; d -= t[k] in ')]'
        if not d: return k + 1
    raise ValueError('括号不配对')
LBR = r'spvDescriptorSet0\.s2a_lb\[\d+\]'
def unlb_arg(a):   # fs_lb 改过的一个采样参数 → 原样；None = 这一个是 fs_lb 插进去的（删掉）
    if re.fullmatch(rf'(?:bias|level)\({LBR}\)', a): return None
    m = re.fullmatch(rf'level\(max\({LBR}, (.*)\)\)', a, re.S)
    if m: return f'min_lod_clamp({m.group(1)})'
    m = re.fullmatch(rf'(level|bias)\(\((.*)\) \+ {LBR}\)', a, re.S)
    if m: return f'{m.group(1)}({m.group(2)})'
    m = re.fullmatch(rf'(gradient2d|gradient3d|gradientcube)\(\((.*)\) \* precise::exp2\({LBR}\), \((.*)\) \* precise::exp2\({LBR}\)\)', a, re.S)
    if m and R.balanced(m.group(2)) and R.balanced(m.group(3)): return f'{m.group(1)}({m.group(2)}, {m.group(3)})'
    m = re.fullmatch(rf'\({LBR} != 0\.0 \? saturate\((.*)\) : \((.*)\)\)', a, re.S)   # #529 比较采样的参考值：按表后半段 saturate
    if m and m.group(1) == m.group(2) and R.balanced(m.group(1)): return m.group(1)
    return a
def strip_lb(t):
    """fs_lb 输出 → 输入：去掉 s2a_lb 成员行；每处带 s2a_lb 的采样逐个参数还原（从后往前）"""
    t = re.sub(r'    constant float\* s2a_lb \[\[id\(\d+\)\]\];\n', '', t, count=1)
    for st in sorted((m.start() for m in R.RED_CALL.finditer(t)), reverse=True):
        m = R.RED_CALL.match(t, st); i = a0 = m.end(); depth = 1; args = []
        while depth and i < len(t):
            c = t[i]; depth += c in '(['; depth -= c in ')]'
            if (c == ',' and depth == 1) or not depth: args.append(t[a0:i].strip()); a0 = i + 1
            i += 1
        if 's2a_lb[' not in t[st:i]: continue
        na = [x for x in (unlb_arg(a) for a in args) if x is not None]
        t = t[:st] + f'spvDescriptorSet0.{m.group(1)}.{m.group(2)}({", ".join(na)})' + t[i:]
    return t
def top_args(t, a):   # t[a] == '(' → (该括号组顶层逗号分开的参数, 配对 ')' 之后的下标)
    b = grp(t, a); args = []; d = 0; c0 = a + 1
    for k in range(a + 1, b - 1):
        d += t[k] in '(['; d -= t[k] in ')]'
        if t[k] == ',' and d == 0: args.append(t[c0:k].strip()); c0 = k + 1
    args.append(t[c0:b - 1].strip()); return args, b
def strip_rd(t):
    """fs_rd 输出 → 输入：去掉版本行、RED_HELP、表参数；(s2a_red[E].m.x != 0.0 ? (…) : (原)) → 原（外层先换）；s2a_bs(X, S, s2a_red[E], 其余…) → X.sample(S, 其余…)"""
    if not t.startswith(R.RED_BEGIN): return t
    t = t[len(R.RED_BEGIN):].replace(R.RED_HELP + '\n', '', 1).replace(R.RED_PARAM, '', 1)
    pat = re.compile(r'\(s2a_red\[\d+\]\.m\.x != 0\.0 \? \(')
    while True:
        m = pat.search(t)
        if not m: break
        a = m.end() - 1; b = grp(t, a)
        if t[b:b + 3] != ' : ': raise ValueError(f'改写形态不对：{t[b:b + 20]!r}')
        c = b + 3; d = grp(t, c)
        if t[d] != ')': raise ValueError(f'改写形态不对：{t[d:d + 20]!r}')
        t = t[:m.start()] + t[c + 1:d - 1] + t[d + 1:]
    while True:
        k = t.find('s2a_bs(')
        if k < 0: return t
        args, b = top_args(t, k + len('s2a_bs'))
        if len(args) < 4 or not re.fullmatch(r'spvDescriptorSet0\.\w+', args[0]) or not re.fullmatch(r's2a_red\[\d+\]', args[2]): raise ValueError(f'改写形态不对：{t[k:k + 60]!r}')
        t = t[:k] + f'{args[0]}.sample({", ".join([args[1]] + args[3:])})' + t[b:]

HEAD = ('struct spvDescriptorSetBuffer0\n{\n    texture2d<float> cp_t_tcb_8 [[id(0)]];\n    sampler cp_t_tcb_8Smplr [[id(1)]];\n    texture2d_array<float> cp_t_tcb_A [[id(2)]];\n'
        '    sampler cp_t_tcb_ASmplr [[id(3)]];\n    texturecube<float> cp_t_tcb_C [[id(4)]];\n    sampler cp_t_tcb_CSmplr [[id(5)]];\n    array<texture2d<float>, 2> cp_t_tcb_D [[id(6)]];\n')
HEAD0 = HEAD + '};\n\n'
HEADL = HEAD + '    constant float* s2a_lb [[id(8)]];\n};\n\n'   # 期望手写：数组 cp_t_tcb_D 占 6、7，下一个是 8
PARAMS = 'constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], device float* o [[buffer(1)]]'
S1 = 'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, _9, level(2.0))'
S2 = 'spvDescriptorSet0.cp_t_tcb_A.sample(spvDescriptorSet0.cp_t_tcb_ASmplr, _9, uint(rint(_8.y)), level(_8.z), int2(1, -1))'
S3 = 'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, _9)'
S4 = 'spvDescriptorSet0.cp_t_tcb_C.sample(spvDescriptorSet0.cp_t_tcb_CSmplr, float3(1.0), level(0.0))'
B1, B3, B5 = 'spvDescriptorSet0.s2a_lb[1]', 'spvDescriptorSet0.s2a_lb[3]', 'spvDescriptorSet0.s2a_lb[5]'
S1B = f'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, _9, level((2.0) + {B1}))'
S2B = f'spvDescriptorSet0.cp_t_tcb_A.sample(spvDescriptorSet0.cp_t_tcb_ASmplr, _9, uint(rint(_8.y)), level((_8.z) + {B3}), int2(1, -1))'
S3B = f'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, _9, level({B1}))'   # 计算核的隐式采样：插 level(b)
S4B = f'spvDescriptorSet0.cp_t_tcb_C.sample(spvDescriptorSet0.cp_t_tcb_CSmplr, float3(1.0), level((0.0) + {B5}))'   # cube：只加偏置
PRE = '    float2 _9 = float2(0.25);\n    float4 _8 = float4(0.5);\n'
POST = '    o[0] = _1 + _2 + _3 + _4;\n'
HDR = '#include <metal_stdlib>\nusing namespace metal;\n\n'
KER = lambda body, extra='': f'kernel void main0({PARAMS}{extra})\n{{\n{body}}}\n'
BODY = lambda a, b, c, d: PRE + f'    float _1 = {a}.x;\n    float _2 = {b}.x;\n    float _3 = {c}.x;\n    float _4 = {d}.x;\n' + POST
RD = lambda e, rs, inner: f'(s2a_red[{e}].m.x != 0.0 ? ({rs}) : ({inner}))'   # 期望手写的归约包法（e = 采样器成员 id）
def BSW(smp):   # 期望手写的边界色包法：spvDescriptorSet0.X.sample(S, 其余…) → s2a_bs(spvDescriptorSet0.X, S, s2a_red[S 的 id], 其余…)（本测参数块的采样器 id 照 HEAD）
    m = re.match(r'(spvDescriptorSet0\.(\w+))\.sample\((spvDescriptorSet0\.\w+), ', smp); assert m and smp.endswith(')'), smp
    return f's2a_bs({m.group(1)}, {m.group(3)}, s2a_red[{SID[m.group(2)]}], {smp[m.end():-1]})'
SID = {'cp_t_tcb_8': 1, 'cp_t_tcb_A': 3, 'cp_t_tcb_C': 5, 't8': 1, 'tA': 3, 'tC': 5}
RS1 = 's2a_rs(spvDescriptorSet0.cp_t_tcb_8, _9, 0u, 2.0, int2(0), s2a_red[1])'
RS2 = 's2a_rs(spvDescriptorSet0.cp_t_tcb_A, _9, uint(rint(_8.y)), _8.z, int2(1, -1), s2a_red[3])'
VER = '// s2a:samp-emu 4 (S2A.Dsh FsRd)\n'   # 期望手写：与 C# Dsh.cs RED_BEGIN 同串，宿主 nvn_mtl.m SE_VERSION 认「// s2a:samp-emu 3 」（改了它这里也要改）
DSH = open(os.path.join(ROOT, 'graphics/tools/direct/dsh/Dsh.cs'), encoding='utf-8').read()
ck('RED_BEGIN = "// s2a:samp-emu 4 (S2A.Dsh FsRd)\\n";' in DSH and 'const string LB = "s2a_lb";' in DSH and 'const long LB_MAXID = 191;' in DSH and 'const int RED_SLOT = 26;' in DSH,
   f'C# Dsh.cs：版本行 = {VER!r}；偏置表成员 s2a_lb；成员 id 上限 191；归约表槽 26')
hp = open(os.path.join(ROOT, 'graphics/nvn/gfx/nvn/nvn_mtl.m'), encoding='utf-8').read(); rh = open(os.path.join(ROOT, 'graphics/nvn/gfx/nvn/nvn_refl.h'), encoding='utf-8').read()
_ma = re.search(r'#define NVN_REFL_MAXARG (\d+)', rh)
ck('SE_VERSION = 4' in hp and 'RED_SLOT = 26' in hp and _ma and int(_ma.group(1)) >= 191 + 1, f'宿主 nvn_mtl.m 的变体格式 / 表槽同 C# 改写（3 / 26）；nvn_refl.h 参数块上限 {_ma and _ma.group(1)} ≥ 偏置表成员 id 上限 191 + 1（宿主表装得下改写器放的 s2a_lb）')
FS = HDR + HEAD0 + KER(BODY(S1, S2, S3, S4))
_rd0 = R.fs_rd(FS); _p0 = VER + HDR + HEAD0   # RED_HELP：改写器插在版本行 + 原文头 + 参数块之后、main0 之前的那段（取值由 ② GPU 对拍核）
R.RED_HELP = _rd0[len(_p0):_rd0.index('\nkernel void main0(')] if _rd0.startswith(_p0) and '\nkernel void main0(' in _rd0 else ''
ck(R.RED_HELP.startswith('struct S2ASe { float4 m; float4 l; float4 c; sampler s0; sampler s1; };\n') and 'float4 s2a_rs(' in R.RED_HELP and ' s2a_bs(' in R.RED_HELP,
   f'fs_rd 在 main0 前插表项 S2ASe（= nvn_red.h nvn_se_ent）与辅助函数 s2a_rw / s2a_rt / s2a_bmix / s2a_bs / s2a_rs（{len(R.RED_HELP)} 字节）')
lbw = HDR + HEADL + KER(BODY(S1B, S2B, S3B, S4B))
lbg = R.fs_lb(FS)
ck(lbg == lbw, 'fs_lb 计算：level 加偏置（2D / 2D 数组带层号偏移 / cube）、隐式插 level(b)；参数块加 s2a_lb，id 跳过数组占的两个')
if lbg != lbw: print('  真结果：\n' + lbg)
ck(strip_lb(lbg) == FS, f'守卫 fs_lb 计算：按形态还原 = 输入逐字节（{len(FS)} 字节）')
ck(R.fs_lb(lbg) == lbg, 'fs_lb 再跑一遍（已有 s2a_lb）→ 原样，不叠第二遍')
rdw = VER + HDR + HEADL + R.RED_HELP + '\n' + KER(BODY(RD(1, RS1, BSW(S1B)), RD(3, RS2, BSW(S2B)), BSW(S3B), BSW(S4B)), R.RED_PARAM)
rdg = R.fs_rd(lbg)
ck(rdg == rdw, 'fs_rd 计算：每次浮点采样包 s2a_bs（边界色）；2D level 2.0、2D 数组层号 + level + 偏移再包归约判断（LOD 取 level((l) + b) 里的 l）；隐式插的 level(b) 与 cube 只包 s2a_bs；版本行 + RED_HELP + 表参数')
if rdg != rdw: print('  真结果：\n' + rdg)
ck(strip_rd(rdg) == lbg, '守卫 fs_rd 计算：去掉包法 = fs_lb 输出逐字节')
ck(R.fs_rd(rdg) == rdg, 'fs_rd 再跑一遍（已有版本行）→ 原样')
ck(R.fs_rd(FS) == VER + HDR + HEAD0 + R.RED_HELP + '\n' + KER(BODY(RD(1, RS1, BSW(S1)), RD(3, RS2, BSW(S2)), BSW(S3), BSW(S4)), R.RED_PARAM), 'fs_rd 没经 fs_lb 的源码：level(l) 照样认')
# 片元：带 [[early_fragment_tests]]；fs_lb 在整数输出入口复制 main0 之前跑（只有 main0）；fs_rd 的输入是整份翻译（main0_u 已接在后面）：只改 main0
FIN = 'struct main0_out\n{\n    float4 m_0 [[color(0)]];\n};\n\n'
FPAR = 'float4 gl_FragCoord [[position]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]]'
FB = lambda s, t: '    main0_out out = {};\n' + PRE + f'    float _1 = {s}.x;\n    float _3 = {t}.x;\n' + '    out.m_0 = float4(_1 + _3);\n    return out;\n'
S3F = f'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, _9, bias({B1}))'   # 片元隐式：插 bias(b)
PS = HDR + HEAD0 + FIN + f'[[early_fragment_tests]] fragment main0_out main0({FPAR})\n{{\n' + FB(S1, S3) + '}\n'
plw = HDR + HEADL + FIN + f'[[early_fragment_tests]] fragment main0_out main0({FPAR})\n{{\n' + FB(S1B, S3F) + '}\n'
plg = R.fs_lb(PS)
ck(plg == plw, 'fs_lb 片元：属性与返回类型照抄，level 加偏置、隐式插 bias(b)')
if plg != plw: print('  真结果：\n' + plg)
U = ('\nstruct main0_out_u\n{\n    uint4 m_0 [[color(0)]];\n};\n\n'
     f'fragment main0_out_u main0_u({FPAR})\n{{\n' + FB(S1B, S3F).replace('return out;', 'return main0_out_u{as_type<uint4>(out.m_0)};') + '}\n')
prw = VER + HDR + HEADL + FIN + R.RED_HELP + '\n' + f'[[early_fragment_tests]] fragment main0_out main0({FPAR}{R.RED_PARAM})\n{{\n' + FB(RD(1, RS1, BSW(S1B)), BSW(S3F)) + '}\n' + U
prg = R.fs_rd(plg + U)
ck(prg == prw, 'fs_rd 片元：只改 main0，main0_u 原样')
if prg != prw: print('  真结果：\n' + prg)
ck(strip_rd(prg) == plg + U and strip_lb(plg) == PS, '守卫 片元：两步各自还原 = 各自输入逐字节')
NOLV = HDR + HEAD0 + KER(BODY(S3, S4, S3, S4))
ck(R.fs_rd(R.fs_lb(NOLV)) == VER + HDR + HEADL + R.RED_HELP + '\n' + KER(BODY(BSW(S3B), BSW(S4B), BSW(S3B), BSW(S4B)), R.RED_PARAM) and R.fs_lb(NOLV) != NOLV,
   'fs_rd 只有隐式 2D 采样与 cube level 采样 → 只包 s2a_bs（边界色），没有归约包法；fs_lb 照样加偏置')
NOTEX = FS.replace('texture2d<float> cp_t_tcb_8', 'texture2d<half> cp_t_tcb_8').replace('texture2d_array<float> cp_t_tcb_A', 'texture2d_array<half> cp_t_tcb_A').replace('texturecube<float> cp_t_tcb_C', 'texturecube<half> cp_t_tcb_C')
ck(R.fs_rd(R.fs_lb(NOTEX)) == R.fs_lb(NOTEX), 'fs_rd 不是浮点贴图（half）→ 不改（不归约、不包边界色），原样')
NOSMP = FS.replace('    sampler cp_t_tcb_8Smplr [[id(1)]];\n', '').replace('    sampler cp_t_tcb_ASmplr [[id(3)]];\n', '').replace('    sampler cp_t_tcb_CSmplr [[id(5)]];\n', '')
ck(R.fs_lb(NOSMP) == NOSMP and R.fs_rd(NOSMP) == NOSMP, '参数块里没有单个采样器成员 → 两步都原样（逐字节）')
VS = FS.replace(f'kernel void main0({PARAMS})', 'vertex float4 main0(' + PARAMS + ')').replace(POST, '    return float4(_1);\n')
ck(R.fs_lb(VS) == VS and R.fs_rd(VS) == VS, '顶点着色器 → 两步都原样')
OUTSIDE = HDR + HEAD0 + f'static inline float f(constant spvDescriptorSetBuffer0& spvDescriptorSet0, float2 _9) {{ return {S1}.x; }}\n' + KER(PRE + '    float _1 = f(spvDescriptorSet0, _9);\n    o[0] = _1;\n')
ck(R.fs_lb(OUTSIDE) == OUTSIDE and R.fs_rd(OUTSIDE) == OUTSIDE, '采样不在 main0 函数体里（辅助函数）→ 两步都原样（保守边界：SPIRV-Cross 把采样内联在 main0 里）')
INNER_RD = RD(1, RS1, BSW(S1B))
OUTER = f'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, {S1}.xy, level(1.0))'
OUTERB = f'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, {S1B}.xy, level((1.0) + {B1}))'
OUTERR = RD(1, f's2a_rs(spvDescriptorSet0.cp_t_tcb_8, {INNER_RD}.xy, 0u, 1.0, int2(0), s2a_red[1])', f's2a_bs(spvDescriptorSet0.cp_t_tcb_8, spvDescriptorSet0.cp_t_tcb_8Smplr, s2a_red[1], {INNER_RD}.xy, level((1.0) + {B1}))')
NEST = HDR + HEAD0 + KER(PRE + f'    float _1 = {OUTER}.x;\n    o[0] = _1;\n')
nlb = R.fs_lb(NEST)
ck(nlb == HDR + HEADL + KER(PRE + f'    float _1 = {OUTERB}.x;\n    o[0] = _1;\n'), '外层采样的坐标里套着内层采样：两层都加偏置（内层先改、外层按改过的串重新解析）')
ck(R.fs_rd(nlb) == VER + HDR + HEADL + R.RED_HELP + '\n' + KER(PRE + f'    float _1 = {OUTERR}.x;\n    o[0] = _1;\n', R.RED_PARAM), '套着的两层都包归约判断（外层的坐标是内层改过的整串）')
ck(strip_rd(R.fs_rd(nlb)) == nlb and strip_lb(nlb) == NEST, '守卫 套采样：两步还原逐字节')
FS190 = FS.replace('cp_t_tcb_D [[id(6)]]', 'cp_t_tcb_D [[id(190)]]')
ck(R.fs_lb(FS190) == FS190 and R.fs_rd(FS190).startswith(VER), '参数块已占到 191（数组 190、191）：fs_lb 原样（宿主绑不了第 192 个），fs_rd 照常（表走缓冲参数）')
ck(R.next_id('    texture2d<float> a [[id(0)]];\n    array<sampler, 3> b [[id(4)]];\n') == 7 and R.next_id('') == 0, 'next_id：数组成员占 n 个 id（4 + 3 = 7）')
# 审计 1101 18:00 P1-18：[[id(N)]] 后面还有第二段属性（SPIRV-Cross 给片元同步资源写 raster_order_group；马力欧派对 超级巨星 10-30）的成员同样算进去
ck(R.next_id('    texture2d<float> a [[id(0)]];\n    texture2d<float, access::read_write> b [[id(3), raster_order_group(0)]];\n') == 4, 'next_id：带第二属性的成员也算（3 + 1 = 4，旧正则漏掉它得 1）')
ROGL = '    texture2d<float, access::read_write> cp_rw [[id(8), raster_order_group(0)]];\n'
ck(R.fs_lb(HDR + HEAD + ROGL + '};\n\n' + KER(BODY(S1, S2, S3, S4))) == HDR + HEAD + ROGL + '    constant float* s2a_lb [[id(9)]];\n};\n\n' + KER(BODY(S1B, S2B, S3B, S4B)),
   'fs_lb：参数块里有带第二属性的成员（id 8）→ s2a_lb 排在 9（旧正则漏掉它、和它撞在 8）')
FROG = FS.replace('texture2d<float> cp_t_tcb_8 [[id(0)]]', 'texture2d<float> cp_t_tcb_8 [[id(0), raster_order_group(0)]]')
ck(R.fs_lb(FROG) == lbw.replace('texture2d<float> cp_t_tcb_8 [[id(0)]]', 'texture2d<float> cp_t_tcb_8 [[id(0), raster_order_group(0)]]'), 'fs_lb：被采样的贴图带第二属性照样加偏置（旧正则不认这张贴图、不加）')
# 审计 1101 18:00 P2-2：采样在 main0 之外（辅助函数）时只记笔记、不改（真库 0 支）
ck(R.helper_samples(OUTSIDE) is True and R.helper_samples(FS) is False and R.helper_samples(lbg) is False, 'helper_samples：辅助函数里有采样 → 真；采样都在 main0 → 假')
with tempfile.TemporaryDirectory() as tmp:
    for nm, t in (('计算主体', lbg), ('计算变体', rdg), ('片元主体', plg), ('片元变体', prg)):
        mp = os.path.join(tmp, 'c.metal'); open(mp, 'w').write(t)
        r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', mp, '-o', os.path.join(tmp, 'c.air')], capture_output=True, text=True)
        ck(r.returncode == 0, f'C {nm}：整份 xcrun -sdk macosx metal -c 编过' + ('' if r.returncode == 0 else f'：{r.stderr.strip()[:400]}'))
# 守卫，真库：动森离线 B 库全部片元 / 计算着色器（旧链的翻译 = 改写前的输入），fs_lb 还原 = 原样、fs_rd 还原 = fs_lb 输出（逐字节）
LIB = os.environ.get('S2A_RED_LIB', os.path.expanduser('~/.s2arm/ext/games/acnh/01006F8002326000_build/shader/cache/b-3f4cd4aacd1d'))
fs_all = sorted(glob.glob(os.path.join(LIB, '*_b.metal')))
if not fs_all: print(f'· 守卫真库：{LIB} 不在，跳过（未验证真库）')
else:
    # 可读瓦片变体 _bf（C# DshFetch.Variant）认的采样经 fs_lb 后多了 bias(s2a_lb[N])：改写前后出变体的键要同一批（10-29 新链考卷 _bf 404 → 0，t_dsh ⑨ 超时）
    #   C# 一次进程批量调（每批 300 支：真库 MSL 共几百 MB，不整份进一个用例文件）
    import json   # noqa: E402
    def okv(r): return r['ok'] if 'ok' in r else None
    scan = same = lbn = rdn = 0; first = None; bf0 = bf1 = 0; lost = []
    for c0 in range(0, len(fs_all), 300):
        chunk = []
        for f in fs_all[c0:c0 + 300]:
            s = open(f, encoding='utf-8', errors='replace').read()
            try: j = json.load(open(f[:-len('.metal')] + '.json'))
            except (OSError, ValueError): j = None
            red, ps = bool(R.RED_ENTRY.search(s)), bool(j) and j.get('stage') == 'ps'
            if red or ps: chunk.append((f, s, red, ps, (j or {}).get('bindings', [])))
        lbs = [okv(r) for r in dshfn.batch([('fs_lb', [s]) for _, s, _, _, _ in chunk])]
        cases = []
        for (f, s, red, ps, bnd), lb in zip(chunk, lbs):
            if red: cases.append(('fs_rd', [lb]))
            if ps: cases += [('fetch_variant', [s, bnd, False]), ('fetch_variant', [lb, bnd, False])]
        res = iter(dshfn.batch(cases))
        for (f, s, red, ps, bnd), lb in zip(chunk, lbs):
            if red:
                scan += 1; rd = okv(next(res)); lbn += lb != s; rdn += rd != lb
                try: ok = lb is not None and rd is not None and strip_lb(lb) == s and strip_rd(rd) == lb
                except ValueError: ok = False
                same += ok; first = first or (None if ok else os.path.basename(f))
            if ps:
                va, vb = okv(next(res)), okv(next(res)); x = bool(va) and va[0] is not None; y = bool(vb) and vb[0] is not None; bf0 += x; bf1 += y
                if x != y: lost.append(os.path.basename(f)[:16])
    ck(scan > 0 and same == scan, f'守卫 真库：{LIB} 片元 / 计算 {scan} 支，fs_lb 改写 {lbn} 支、fs_rd 出变体 {rdn} 支，两步还原逐字节同 {same} / {scan}' + (f'；首个不同 {first}' if first else ''))
    ck(bf0 > 0 and not lost, f'守卫 真库：可读瓦片变体 _bf 出得了的片元键 改写前 {bf0} 支 → fs_lb 后 {bf1} 支' + (f'；不同 {len(lost)} 支，首个 {lost[0]}' if lost else '（同一批）'))
SIG = ' t [[texture(0)]], sampler s [[sampler(0)]], constant S2ASe* q [[buffer(0)]], device const float4* P [[buffer(1)]], device float* O [[buffer(2)]], uint i [[thread_position_in_grid]])\n'
SIG4 = SIG.replace('device float* O', 'device float4* O')   # 边界色核：四通道
KERS = ('#include <metal_stdlib>\nusing namespace metal;\n' + R.RED_HELP +
        'kernel void k2(texture2d<float>' + SIG + '{ float4 p = P[i]; O[2 * i] = t.sample(s, p.xy, level(p.z)).x; O[2 * i + 1] = s2a_rs(t, p.xy, 0u, p.z, int2(0), q[0]).x; }\n'
        'kernel void k2o(texture2d<float>' + SIG + '{ float4 p = P[i]; O[2 * i] = t.sample(s, p.xy, level(p.z), int2(1, -1)).x; O[2 * i + 1] = s2a_rs(t, p.xy, 0u, p.z, int2(1, -1), q[0]).x; }\n'
        'kernel void ka(texture2d_array<float>' + SIG + '{ float4 p = P[i]; O[2 * i] = t.sample(s, p.xy, uint(p.w), level(p.z)).x; O[2 * i + 1] = s2a_rs(t, p.xy, uint(p.w), p.z, int2(0), q[0]).x; }\n'
        # 边界色：表项 1（核表项步长 64 字节），绑定的采样器 = 改前的读数
        'kernel void kb(texture2d<float>' + SIG4 + '{ float4 p = P[i]; O[2 * i] = t.sample(s, p.xy, level(p.z)); O[2 * i + 1] = s2a_bs(t, s, q[1], p.xy, level(p.z)); }\n'
        'kernel void kbo(texture2d<float>' + SIG4 + '{ float4 p = P[i]; O[2 * i] = t.sample(s, p.xy, level(p.z), int2(1, -1)); O[2 * i + 1] = s2a_bs(t, s, q[1], p.xy, level(p.z), int2(1, -1)); }\n'
        'kernel void kba(texture2d_array<float>' + SIG4 + '{ float4 p = P[i]; O[2 * i] = t.sample(s, p.xy, uint(p.w), level(p.z)); O[2 * i + 1] = s2a_bs(t, s, q[1], p.xy, uint(p.w), level(p.z)); }\n')
# 位置 u = m / 256：每一级（宽 8 / 4 / 2 / 1）的纹素坐标都落在 1/256 格点上；m ≡ 16 (mod 32) 在 0 级是纹素中心（右邻零权重），负数与 > 256 越出 [0, 1]
MX = [-40, -8, 0, 7, 16, 33, 48, 64, 100, 128, 144, 200, 240, 255, 256, 270, 330]; MY = [-5, 16, 37, 128, 250]
LODS = [0.0, 1.0, 2.0, 3.0, 5.0, -1.0, 1.5]   # 5 / -1：钳到 3 / 0；1.5：两级都算
pts = [(mx / 256, my / 256, l, (mx + my) & 1) for l in LODS for mx in MX for my in MY]
BHEAD = ('#include <metal_stdlib>\nusing namespace metal;\n\nstruct spvDescriptorSetBuffer0\n{\n    texture2d<float> t8 [[id(0)]];\n    sampler t8Smplr [[id(1)]];\n'
         '    texture2d_array<float> tA [[id(2)]];\n    sampler tASmplr [[id(3)]];\n    texturecube<float> tC [[id(4)]];\n    sampler tCSmplr [[id(5)]];\n')
SMP = lambda t, a: f'spvDescriptorSet0.{t}.sample(spvDescriptorSet0.{t}Smplr, {a})'
BCS = (BHEAD + '    device float4* cs_s0 [[id(6)]];\n};\n\nkernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])\n{\n    float2 _9 = float2(0.3, 0.6);\n'
       f'    spvDescriptorSet0.cs_s0[0] = float4({SMP("t8", "_9")}.x, {SMP("t8", "_9, level(1.0)")}.x, {SMP("t8", "_9, gradient2d(float2(0.25, 0.0), float2(0.0, 0.25))")}.x, '
       f'{SMP("t8", "_9, min_lod_clamp(0.0)")}.x);\n'
       f'    spvDescriptorSet0.cs_s0[1] = float4({SMP("tA", "_9, uint(rint(1.0))")}.x, {SMP("tA", "_9, uint(rint(1.0)), level(2.0)")}.x, {SMP("tC", "float3(1.0, 0.2, 0.3), level(1.0)")}.x, 0.0);\n}}\n')
BFS = (BHEAD + '};\n\nstruct main0_out\n{\n    float4 m_0 [[color(0)]];\n    float4 m_1 [[color(1)]];\n};\n\n'
       'fragment main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n'
       '    float2 _9 = gl_FragCoord.xy * float2(0.125);\n'
       f'    out.m_0 = float4({SMP("t8", "_9")}.x, {SMP("t8", "_9, bias(0.5)")}.x, {SMP("t8", "_9, level(1.0)")}.x, {SMP("t8", "_9, gradient2d(float2(0.25, 0.0), float2(0.0, 0.25))")}.x);\n'
       f'    out.m_1 = float4({SMP("t8", "_9, int2(1, 0)")}.x, {SMP("tA", "_9, uint(rint(1.0))")}.x, {SMP("tA", "_9, uint(rint(1.0)), bias(0.5)")}.x, {SMP("t8", "_9, min_lod_clamp(0.0)")}.x);\n'
       '    return out;\n}\n')
bcs, bfs = R.fs_lb(BCS), R.fs_lb(BFS)
L1 = 'spvDescriptorSet0.s2a_lb[1]'; L3 = 'spvDescriptorSet0.s2a_lb[3]'
for nm, t, want in (('计算隐式 → 插 level(b)', bcs, SMP('t8', f'_9, level({L1})')), ('计算 gradient → 导数 × precise::exp2(b)', bcs, SMP('t8', f'_9, gradient2d((float2(0.25, 0.0)) * precise::exp2({L1}), (float2(0.0, 0.25)) * precise::exp2({L1}))')),
                    ('计算只带 min_lod_clamp(m) → level(max(b, m))（level 与它不能同用）', bcs, SMP('t8', f'_9, level(max({L1}, 0.0))')),
                    ('计算数组隐式 → 层号后插 level(b)', bcs, SMP('tA', f'_9, uint(rint(1.0)), level({L3})')), ('计算参数块加 s2a_lb [[id(7)]]', bcs, 'constant float* s2a_lb [[id(7)]];'),
                    ('片元隐式 → 插 bias(b)', bfs, SMP('t8', f'_9, bias({L1})')), ('片元 bias(0.5) → bias((0.5) + b)', bfs, SMP('t8', f'_9, bias((0.5) + {L1})')),
                    ('片元带偏移 → 偏移前插 bias(b)', bfs, SMP('t8', f'_9, bias({L1}), int2(1, 0)')), ('片元只带 min_lod_clamp → 它前面插 bias(b)', bfs, SMP('t8', f'_9, bias({L1}), min_lod_clamp(0.0)')),
                    ('片元参数块加 s2a_lb [[id(6)]]', bfs, 'constant float* s2a_lb [[id(6)]];')):
    ck(want in t, f'③ 改写：{nm}')
ck(strip_lb(bcs) == BCS and strip_lb(bfs) == BFS, '③ 守卫：两支按形态还原 = 原样逐字节')
# ③' 比较采样（缺口族 31）：同 ③ 的 16 项，每项 = 参考值 0.2 / 0.45 / 0.7 三次 sample_compare 之和；LOD 参数在参考值之后（数组：层号、参考值之后）
CHEAD = BHEAD.replace('texture2d<float> t8', 'depth2d<float> t8').replace('texture2d_array<float> tA', 'depth2d_array<float> tA').replace('texturecube<float> tC', 'depthcube<float> tC')
def SMC(t, a, ref, post=''): return f'spvDescriptorSet0.{t}.sample_compare(spvDescriptorSet0.{t}Smplr, {a}, {ref}' + (f', {post}' if post else '') + ')'
def RC(ref, i): return f'(spvDescriptorSet0.s2a_lb[{192 + i}] != 0.0 ? saturate({ref}) : ({ref}))'   # #529：fs_lb 改过的参考值（表后半段 = 192 + 采样器成员 id，手写）
def C3(t, a, post=''): return '(' + ' + '.join(SMC(t, a, r, post) for r in ('0.2', '0.45', '0.7')) + ')'
GR = 'gradient2d(float2(0.25, 0.0), float2(0.0, 0.25))'
CCS = (CHEAD + '    device float4* cs_s0 [[id(6)]];\n};\n\nkernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])\n{\n    float2 _9 = float2(0.3, 0.6);\n'
       f'    spvDescriptorSet0.cs_s0[0] = float4({C3("t8", "_9")}, {C3("t8", "_9", "level(1.0)")}, {C3("t8", "_9", GR)}, {C3("t8", "_9", "min_lod_clamp(0.0)")});\n'
       f'    spvDescriptorSet0.cs_s0[1] = float4({C3("tA", "_9, uint(rint(1.0))")}, {C3("tA", "_9, uint(rint(1.0))", "level(2.0)")}, {C3("tC", "float3(1.0, 0.2, 0.3)", "level(1.0)")}, 0.0);\n}}\n')
CFS = (CHEAD + '};\n\nstruct main0_out\n{\n    float4 m_0 [[color(0)]];\n    float4 m_1 [[color(1)]];\n};\n\n'
       'fragment main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n'
       '    float2 _9 = gl_FragCoord.xy * float2(0.125);\n'
       f'    out.m_0 = float4({C3("t8", "_9")}, {C3("t8", "_9", "bias(0.5)")}, {C3("t8", "_9", "level(1.0)")}, {C3("t8", "_9", GR)});\n'
       f'    out.m_1 = float4({C3("t8", "_9", "int2(1, 0)")}, {C3("tA", "_9, uint(rint(1.0))")}, {C3("tA", "_9, uint(rint(1.0))", "bias(0.5)")}, {C3("t8", "_9", "min_lod_clamp(0.0)")});\n'
       '    return out;\n}\n')
ccs, cfs = R.fs_lb(CCS), R.fs_lb(CFS)
for nm, t, want in (('计算比较隐式 → 参考值后插 level(b)', ccs, SMC('t8', '_9', RC('0.45', 1), f'level({L1})')), ('计算比较 level(1) → level((1.0) + b)', ccs, SMC('t8', '_9', RC('0.7', 1), f'level((1.0) + {L1})')),
                    ('计算比较 gradient → 导数 × precise::exp2(b)', ccs, SMC('t8', '_9', RC('0.2', 1), f'gradient2d((float2(0.25, 0.0)) * precise::exp2({L1}), (float2(0.0, 0.25)) * precise::exp2({L1}))')),
                    ('计算比较只带 min_lod_clamp(m) → level(max(b, m))', ccs, SMC('t8', '_9', RC('0.2', 1), f'level(max({L1}, 0.0))')),
                    ('计算比较数组隐式 → 层号、参考值后插 level(b)', ccs, SMC('tA', '_9, uint(rint(1.0))', RC('0.2', 3), f'level({L3})')),
                    ('片元比较隐式 → 参考值后插 bias(b)', cfs, SMC('t8', '_9', RC('0.2', 1), f'bias({L1})')), ('片元比较 bias(0.5) → bias((0.5) + b)', cfs, SMC('t8', '_9', RC('0.45', 1), f'bias((0.5) + {L1})')),
                    ('片元比较带偏移 → 偏移前插 bias(b)', cfs, SMC('t8', '_9', RC('0.7', 1), f'bias({L1}), int2(1, 0)')), ('片元比较参数块加 s2a_lb [[id(6)]]', cfs, 'constant float* s2a_lb [[id(6)]];')):
    ck(want in t, f"③' 改写：{nm}")
ck(strip_lb(ccs) == CCS and strip_lb(cfs) == CFS, "③' 守卫：两支按形态还原 = 原样逐字节")
ck(R.fs_rd(cfs) == cfs, "③' fs_rd：只有比较采样 → 不出变体（比较采样不进边界色混合：比较对边界深度不是线性）")
# ④ #529 定点深度比较：比较采样的参考值按表后半段 s2a_lb[192 + 采样器成员 id] saturate（宿主按客体格式写：D16 / D24 / D24S8 写 1、D32F 写 0）。
#   计算核：深度全 1.0 的 depth2d、LessEqual 采样器，参考值 1.1 与 0.5 各比一次（显式 level(0.0)）；期望见 t_red_run.m dc_run（标志 0 → 0 / 1，标志 1 → 1 / 1，原样 → 0 / 1）
DCS = (CHEAD + '    device float4* cs_s0 [[id(6)]];\n};\n\nkernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])\n{\n'
       f'    spvDescriptorSet0.cs_s0[0] = float4({SMC("t8", "float2(0.5)", "1.1", "level(0.0)")}, {SMC("t8", "float2(0.5)", "0.5", "level(0.0)")}, 0.0, 0.0);\n}}\n')
dcs = R.fs_lb(DCS)
ck(SMC('t8', 'float2(0.5)', RC('1.1', 1), f'level((0.0) + {L1})') in dcs, '④ 改写：比较采样参考值 → (s2a_lb[192 + 1] != 0.0 ? saturate(r) : (r))')
ck(strip_lb(dcs) == DCS, '④ 守卫：按形态还原 = 原样逐字节')
with tempfile.TemporaryDirectory() as tmp:
    exe = os.path.join(tmp, 't_red_run')
    r = subprocess.run(['xcrun', 'clang', '-O1', '-fobjc-arc', '-Wall', '-I', os.path.join(ROOT, 'graphics/nvn/gfx/nvn'), '-o', exe, os.path.join(HERE, 't_red_run.m'),
                        '-framework', 'Metal', '-framework', 'Foundation'], capture_output=True, text=True)
    if r.returncode: ck(False, f'执行器编不过：{r.stderr.strip()[:300]}')
    else:
        kp, pp = os.path.join(tmp, 'k.metal'), os.path.join(tmp, 'p.txt')
        open(kp, 'w').write(KERS); open(pp, 'w').write(''.join(' '.join(repr(float(v)) for v in p) + '\n' for p in pts))
        r = subprocess.run([exe, kp, pp], capture_output=True, text=True, timeout=150)
        lines = [l for l in r.stdout.splitlines() if l[:1] in ('✓', '✗')]
        for l in lines: ck(l.startswith('✓'), l[2:])
        if r.returncode and not any(l.startswith('✗') for l in lines): ck(False, f'执行器退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-300:]}')
        VSM = 'vertex float4 vs_main(uint vid [[vertex_id]]) { return float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.5, 1.0); }\n\nstruct main0_out\n'
        fp = [os.path.join(tmp, f) for f in ('bcs.metal', 'bfs.metal', 'bcs_lb.metal', 'bfs_lb.metal')]
        for p, t in zip(fp, (BCS, BFS.replace('struct main0_out\n', VSM, 1), bcs, bfs.replace('struct main0_out\n', VSM, 1))): open(p, 'w').write(t)
        r = subprocess.run([exe, '--bias', *fp], capture_output=True, text=True, timeout=150)
        lines = [l for l in r.stdout.splitlines() if l[:1] in ('✓', '✗')]
        for l in lines: ck(l.startswith('✓'), l[2:])
        if r.returncode and not any(l.startswith('✗') for l in lines) or not lines: ck(False, f'偏置执行器退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-300:]}')
        fq = [os.path.join(tmp, f) for f in ('ccs.metal', 'cfs.metal', 'ccs_lb.metal', 'cfs_lb.metal')]
        for p, t in zip(fq, (CCS, CFS.replace('struct main0_out\n', VSM, 1), ccs, cfs.replace('struct main0_out\n', VSM, 1))): open(p, 'w').write(t)
        r = subprocess.run([exe, '--cmp', *fq], capture_output=True, text=True, timeout=150)
        lines = [l for l in r.stdout.splitlines() if l[:1] in ('✓', '✗')]
        for l in lines: ck(l.startswith('✓'), l[2:])
        if r.returncode and not any(l.startswith('✗') for l in lines) or not lines: ck(False, f'比较偏置执行器退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-300:]}')
        fd = [os.path.join(tmp, f) for f in ('dc.metal', 'dc_lb.metal')]
        for p, t in zip(fd, (DCS, dcs)): open(p, 'w').write(t)
        r = subprocess.run([exe, '--dc', *fd], capture_output=True, text=True, timeout=150)
        lines = [l for l in r.stdout.splitlines() if l[:1] in ('✓', '✗')]
        for l in lines: ck(l.startswith('✓'), l[2:])
        if r.returncode and not any(l.startswith('✗') for l in lines) or not lines: ck(False, f'定点深度比较执行器退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-300:]}')
print(f't_red：{n} 项，失败 {bad}（GPU 每项 {len(pts)} 个位置）')
sys.exit(1 if bad else 0)
