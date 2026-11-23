#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""NVN2 任务 / 网格着色器包装（S2A.Dsh MeshStage.cs，经 dsh_cmp --fn 调；11-05 时之笛 3D 场景 task / mesh 缺库）：python3 t_meshstage.py <dsh_cmp.dll>
期望按接口约定（side-session-notes 22_网格着色接口约定.md）与 上游参考实现（MIT） dmsh_meshstage.py 的布局手算，不跑被测实现推：
  ① 手排控制段 + SPH → 事实（阶段、线程、载荷、有无任务、最多顶点 / 图元、OMAP 分量顺序、逐图元 SPH 只留通用属性）
  ② 阶段内存：载荷按 16 对齐接在 +0x10 之后；网格属性每 32 顶点一块、每分量 0x80 字节；图元区 = 4 + 3 × 最多图元 按 4 对齐
  ③ 包装文本：入口种类与名字、缓冲槽 29、属性字地址、图元数 / 索引字节地址、近平面换算只在 main0、载荷字 1 = 网格组数（上限 1024）
  ④ 拒绝：超 Metal 网格上限、阶段字节不是 6 / 7、自有共享内存（LDS / STS / ATOMS 操作码）
  ⑤ 三份包装后的 MSL 按出包 iOS 编法（dsh/batch/Build.cs IosMetal）交 xcrun metal -c 编过"""
import json, os, struct, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import dshfn
if len(sys.argv) > 1: os.environ['DSH_CMP_DLL'] = os.path.abspath(sys.argv[1])

n = bad = 0
def ck(name, ok, got=None):
    global n, bad
    n += 1; bad += 0 if ok else 1
    print(('✓ ' if ok else '✗ ') + name + ('' if ok or got is None else f'（实得：{str(got)[:300]}）'))


def ctl(stage, threads, payload, task=0, mv=0, mp=0, prim_at=0):
    c = bytearray(0xe0); c[:4] = bytes.fromhex('34127698'); c[4:8] = b'\xc9\0\0\0'
    c[0x56] = stage; struct.pack_into('<HH', c, 0x58, threads, payload); c[0x5e] = task; struct.pack_into('<HH', c, 0x60, mv, mp)
    if prim_at: struct.pack_into('<I', c, 0x64, prim_at); c[0x68] = 0x80
    return bytes(c)


def area(sph0=(0, 0), prim=None):
    """代码区：SPH（0x35 / 0x36 / 0x37 三个 OMAP 字节）+ 指令占位；prim = (+0x100 处逐图元 SPH 的 0x35, 0x36, 0x37)"""
    a = bytearray(0x200); a[0x35], a[0x36], a[0x37] = 0xf0, *sph0
    if prim: a[0x135], a[0x136], a[0x137] = prim
    return bytes(a)


A_CTL, A_AREA = ctl(7, 32, 0x100, task=1, mv=64, mp=126), area((0x3f, 0))          # 网格有任务：位置 xyzw、属性 0 xyzw、属性 1 xy
B_CTL, B_AREA = ctl(7, 32, 0, mv=32, mp=32, prim_at=0x100), area((0, 0), (0xf0, 0, 0x01))   # 网格无任务：位置 xyzw；逐图元 SPH 位置（不算）+ 属性 2 x
C_CTL, C_AREA = ctl(6, 32, 3200), area()                                            # 任务：载荷 3200 字节
D_CTL, D_AREA = ctl(6, 32, 0x5000), area()                                          # 任务：载荷 20480 字节（超 Metal 对象载荷 16 KB → 设备中转）
E_CTL, E_AREA = ctl(7, 26, 0x5000, task=1, mv=64, mp=126), area((0x3f, 0))          # 网格：同 A 的属性、载荷 20480 字节、26 线程（同一款体育游戏近海网格 d60092d7）

HEAD = '''#include <metal_stdlib>
using namespace metal;
template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    thread T& operator [] (size_t pos) thread { return elements[pos]; }
    constexpr const thread T& operator [] (size_t pos) const thread { return elements[pos]; }
    threadgroup T& operator [] (size_t pos) threadgroup { return elements[pos]; }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup { return elements[pos]; }
    device T& operator [] (size_t pos) device { return elements[pos]; }
    constexpr const device T& operator [] (size_t pos) const device { return elements[pos]; }
};
struct B { uint v[64]; };
'''
def kernel(words, own_lid):
    """SPIRV-Cross 出计算核的样子：阶段内存是第一条语句；本体里有提前返回"""
    lid = 'gl_LocalInvocationID.x' if own_lid else 'gl_SubgroupInvocationID'
    p = 'uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]], ' if own_lid else ''
    return HEAD + f'''kernel void main0(device B& b [[buffer(0)]], {p}uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])
{{
    threadgroup spvUnsafeArray<uint, {words}> _35;
    if ({lid} > 30u)
    {{
        return;
    }}
    _35[4u + {lid}] = b.v[{lid} & 63u] + _35[0];
}}
'''

r = dshfn.batch([('mesh_info', [A_CTL.hex(), A_AREA.hex()]), ('mesh_info', [B_CTL.hex(), B_AREA.hex()]), ('mesh_info', [C_CTL.hex(), C_AREA.hex()]),
                 ('mesh_memory', [A_CTL.hex(), A_AREA.hex()]), ('mesh_memory', [B_CTL.hex(), B_AREA.hex()]), ('mesh_memory', [C_CTL.hex(), C_AREA.hex()]),
                 ('mesh_to_stage', [kernel(1444, True), A_CTL.hex(), A_AREA.hex()]), ('mesh_to_stage', [kernel(189, False), B_CTL.hex(), B_AREA.hex()]),
                 ('mesh_to_stage', [kernel(1604, False), C_CTL.hex(), C_AREA.hex()]),
                 ('mesh_to_stage', [kernel(64, False), ctl(7, 32, 0, mv=300, mp=32).hex(), area().hex()]),
                 ('mesh_info', [ctl(5, 32, 0).hex(), area().hex()]),
                 ('mesh_own_shared', [(struct.pack('<H', 0x988) + bytes(14)).hex()]), ('mesh_own_shared', [(struct.pack('<H', 0x986) + bytes(14)).hex()]),
                 ('mesh_memory', [D_CTL.hex(), D_AREA.hex()]), ('mesh_memory', [E_CTL.hex(), E_AREA.hex()]),
                 ('mesh_to_stage', [kernel(5124, False), D_CTL.hex(), D_AREA.hex()]), ('mesh_to_stage', [kernel(6500, True), E_CTL.hex(), E_AREA.hex()])])
pos = [[None, 0], [None, 1], [None, 2], [None, 3]]
ck('① 网格有任务：事实', r[0].get('ok') == {'kind': 'ms', 'threads': 32, 'payload': 256, 'task': True, 'max_v': 64, 'max_p': 126,
                                         'vertex': pos + [[0, 0], [0, 1], [0, 2], [0, 3], [1, 0], [1, 1]], 'primitive': []}, r[0])
ck('① 网格无任务：逐图元 SPH 的位置分量不算、属性 2 x 算', r[1].get('ok') == {'kind': 'ms', 'threads': 32, 'payload': 0, 'task': False, 'max_v': 32, 'max_p': 32,
                                         'vertex': pos, 'primitive': [[2, 0]]}, r[1])
ck('① 任务：事实（无顶点 / 图元）', r[2].get('ok') == {'kind': 'ts', 'threads': 32, 'payload': 3200, 'task': False, 'max_v': 0, 'max_p': 0, 'vertex': [], 'primitive': []}, r[2])
# ② 手算：A 输出 0x10 + 256 = 272；4 块 × 10 分量 × 128 字节 = 5120 → 图元 5392；+ (4 + 378 + 3) & ~3 = 384 → 5776
ck('② 网格有任务：[0, 16, 272, 5392] / 5776 字节', r[3].get('ok') == [[0, 16, 272, 5392], 5776], r[3])
# B 输出 16；1 块 × 5 分量 × 128 = 640 → 656；+ (4 + 96 + 3) & ~3 = 100 → 756
ck('② 网格无任务：[0, 16, 16, 656] / 756 字节', r[4].get('ok') == [[0, 16, 16, 656], 756], r[4])
# C 输出 0x10 + 3200 = 3216，图元位 = 3216 + 3200 = 6416；大小 3216 + 3200 = 6416
ck('② 任务：[0, 16, 3216, 6416] / 6416 字节', r[5].get('ok') == [[0, 16, 3216, 6416], 6416], r[5])
A0, B0, C0 = (x.get('ok') or '' for x in r[6:9])
# #770 宿主自跑任务 / 网格阶段的入口与循环圈数上限都在 #ifdef S2A_MESH_EMU 里（出包不定义它）：③ 的逐字检查看去掉这些块之后的文本，⑦ 单独查它们
import re
def base(x): return re.sub(r'#ifdef S2A_MESH_EMU\n.*?#endif\n', '', x, flags=re.S)
A, B, C = base(A0), base(B0), base(C0)
ck('③ A：两个网格入口、有载荷参数、不带槽 29', A.count('[[mesh]] void main0(') == 1 and A.count('[[mesh]] void main0_z(') == 1 and 'const object_data dm_payload_t& dm_payload [[payload]]' in A and 'buffer(29)' not in A, A[-400:])
ck('③ A：网格类型 64 顶点 126 图元无逐图元', 'using dm_mesh_t = metal::mesh<dm_vertex_t, void, 64, 126, metal::topology::triangle>;' in A)
ck('③ A：线程号取计算核的 gl_LocalInvocationID.x、不另加 dm_lid', 'for (uint i = gl_LocalInvocationID.x; i < 1444u; i += 32u) _35[i] = 0u;' in A and 'dm_lid' not in A)
ck('③ A：载荷 64 字拷到输入（字 4 起），字 0 / 输入字 0 = 线程组号', 'for (uint i = gl_LocalInvocationID.x; i < 64u; i += 32u) _35[4u + i] = dm_payload.w[i];' in A and '{ _35[0] = dm_tg; _35[4] = dm_tg; }' in A)
ck('③ A：块地址 68 + (n/32)·320 + n%32、属性 1 = 分量 8 / 9', 'uint b = 68u + (n / 32u) * 320u + n % 32u;' in A and 'v.a1 = float4(as_type<float>(_35[b + 256u]), as_type<float>(_35[b + 288u]), 0.0, 1.0);' in A)
ck('③ A：图元数在字 1348 高字节、索引字节从 5396 起', 'uint np = min(_35[1348] >> 24, 126u);' in A and 'uint at = 5396u + n;' in A)
z = A.split('[[mesh]] void main0_z(')
ck('③ A：近平面换算只在 main0（GL -w），main0_z 不换', len(z) == 2 and 'v.position.z = fma(v.position.z, 0.5, v.position.w * 0.5);' in z[0] and 'fma(' not in z[1])
ck('③ B：无任务读槽 29 的起始组号', 'constant uint* dm_first [[buffer(29)]]' in B and 'if (dm_lid == 0u) _35[0] = dm_first[0] + dm_tg;' in B and 'object_data' not in B)
# 属性区按硬件排法（顶点块与图元块不交错，见 MeshStage.ToStage 注释：网格 192226654c410372 本体写顶点 (v >> 5) × 2432、图元 12160 + (p >> 5) × 384）：
#   B 有 4 个顶点分量、1 个图元分量、32 顶点 / 32 图元 → 顶点块长 4 × 32 = 128 字，图元区从 1 块顶点之后起（4 + 128 = 132），块长 1 × 32 字、属性 2 是图元区第 0 个分量
ck('③ B：逐图元属性 2 = 图元区分量 0、按图元写', 'float4 p2 [[user(locn2)]];' in B and 'p.p2 = float4(as_type<float>(_35[b + 0u]), 0.0, 0.0, 1.0);' in B and 'metal::mesh<dm_vertex_t, dm_prim_t, 32, 32' in B)
ck('③ B：顶点块 4 + (n/32)·128、图元块 132 + (n/32)·32、图元数字 164、索引从 660', 'uint b = 4u + (n / 32u) * 128u + n % 32u;' in B and 'uint b = 132u + (n / 32u) * 32u + n % 32u;' in B
   and 'min(_35[164] >> 24, 32u)' in B and 'uint at = 660u + n;' in B)
ck('③ C：对象入口、载荷 800 字从字 804 拷出、网格组数 = 字 805 封顶 1024', '[[object]] void main0(' in C and 'struct dm_payload_t { uint w[800]; };' in C
   and 'dm_payload.w[i] = _35[804u + i];' in C and 'dm_grid.set_threadgroups_per_grid(uint3(min(_35[805], 1024u), 1u, 1u));' in C and 'constant uint* dm_first [[buffer(29)]]' in C
   and '_35[0] = dm_first[0] + dm_tg;' in C)
ck('③ 计算核本体成内联函数、阶段内存作引用参数、提前返回留在本体', all('static inline __attribute__((always_inline)) void dm_stage_body(' in x and 'threadgroup spvUnsafeArray<uint, ' in x and 'kernel void' not in x for x in (A, B, C)))
ck('④ 300 顶点超 Metal 上限：报错不出包装', r[9].get('err') == 'DshError:mesh stage failed', r[9])
ck('④ 阶段字节 5 不是任务 / 网格：报错', r[10].get('err') == 'DshError:bad record', r[10])
ck('④ 自有共享内存：STS 0x988 认出、STG 0x986 不认', r[11].get('ok') is True and r[12].get('ok') is False, (r[11], r[12]))
# ⑥ 载荷超 16 KB（设备中转，MeshStage.Relay；11-12 一款体育游戏近海任务 07abb052 / 网格 d60092d7 载荷 27904 字节，原先任务 55824、网格 39056 字节超 32 KB 线程组内存、整笔不画）
#   任务不读输入：中转时不留载荷大小的输入区 → [0, 16, 16, 20496] / 20496（不中转时同 C 的排法会是 16 + 20480 + 20480 = 40976，超 32 KB）
ck('⑥ 中转任务：不留输入区 [0, 16, 16, 20496] / 20496 字节', r[13].get('ok') == [[0, 16, 16, 20496], 20496], r[13])
# E 网格照常：输出 16 + 20480 = 20496；4 块 × 10 分量 × 128 = 5120 → 图元 25616；+ 384 → 26000
ck('⑥ 中转网格：布局不变 [0, 16, 20496, 25616] / 26000 字节', r[14].get('ok') == [[0, 16, 20496, 25616], 26000], r[14])
D0, E0 = (x.get('ok') or '' for x in r[15:17])
D, E = base(D0), base(E0)
ck('⑥ D：object_data 只带任务组号、中转缓冲在槽 27', 'struct dm_payload_t { uint tg; };' in D and 'device uint* dm_relay [[buffer(27)]]' in D and 'uint w[' not in D, D[-600:])
ck('⑥ D：载荷 5120 字从字 4 写进中转（头 8 字后、每组 5120 字），越界组不写', 'device uint* dm_p = dm_relay + 8u + dm_tg * 5120u;' in D and 'bool dm_in = dm_tg < dm_relay[1];' in D
   and 'if (dm_in) for (uint i = dm_lid; i < 5120u; i += 32u) dm_p[i] = _35[4u + i];' in D)
ck('⑥ D：派生数 = 字 5 钳到任务线程数 32、越界组 0', 'dm_payload.tg = dm_tg; dm_grid.set_threadgroups_per_grid(uint3(dm_in ? min(_35[5], 32u) : 0u, 1u, 1u));' in D)
ck('⑥ E：阶段内存是中转缓冲里一片（片号 = 任务组 × 头字 2 + 网格组）、不再有线程组阶段内存',
   'device spvUnsafeArray<uint, 6500>& _35 = *(device spvUnsafeArray<uint, 6500>*)(dm_relay + dm_relay[0] + (dm_payload.tg * dm_relay[2] + dm_tg) * 6500u);' in E
   and 'threadgroup spvUnsafeArray<uint, 6500>' not in E and 'device spvUnsafeArray<uint, 6500>& _35)' in E, E[-900:])
ck('⑥ E：载荷从中转读进输入（字 4 起）、栅栏带 mem_device', 'for (uint i = gl_LocalInvocationID.x; i < 5120u; i += 26u) _35[4u + i] = dm_relay[8u + dm_payload.tg * 5120u + i];' in E
   and 'threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);' in E and 'threadgroup_barrier(mem_flags::mem_threadgroup);' not in E)
ck('⑥ 对照：载荷 ≤ 16 KB 的 A / C 不带中转', all('dm_relay' not in x and 'mem_device' not in x for x in (A, C)))
with tempfile.TemporaryDirectory(prefix='t_meshstage_') as t:
    for nm, src in (('A', A), ('B', B), ('C', C), ('D', D), ('E', E)):
        f = os.path.join(t, nm + '.metal'); open(f, 'w').write(src)
        p = subprocess.run(['xcrun', '-sdk', 'iphoneos', 'metal', '-c', '-w', '-mios-version-min=18.0', '-fmetal-math-mode=relaxed', '-fpreserve-invariance', f, '-o', f + '.air'], capture_output=True, text=True)
        ck(f'⑤ {nm} 交 xcrun metal（iphoneos，出包 iOS 编法）编过', p.returncode == 0, p.stderr.strip()[-300:])
# ⑦ #770 宿主自跑入口：有任务的网格出 main0_mc / main0_mc_z（计算核，读交换缓冲槽 28）与顶点函数 main0_mv；任务出 main0_tc；无任务的网格不带逐图元属性时也出（F），带的不出（B）；
#   定义 S2A_MESH_EMU 后照出包编法编得过（宿主现编时定义它）
ck('⑦ 有任务的网格：S2A_MESH_EMU 下有 main0_mc / main0_mc_z / main0_mv，读槽 28', all(k in A0 for k in ('kernel void main0_mc(', 'kernel void main0_mc_z(', 'vertex dm_vertex_t main0_mv(', '[[buffer(28)]]')) and 'kernel void main0_mc(' not in A)
ck('⑦ 任务：S2A_MESH_EMU 下有 main0_tc，写载荷与派生数（钳 1024）', 'kernel void main0_tc(' in C0 and 'dm_xo[dm_xo[0] + dm_tg] = min(_35[805], 1024u);' in C0)
# ⑨ 带逐图元属性的网格（B：32 顶点 / 32 图元、逐图元属性 2）也出宿主入口：每个三角形展开成 3 个顶点记录 dm_xvertex_t，带该三角形的逐图元属性；
#   原先不出（逐图元属性没有承载处），M1 / M2 上整笔跳过（一款体育游戏岛上植被等 3 支网格）
B_EMU = B0.split('#ifdef S2A_MESH_EMU')[-1] if 'kernel void main0_mc(' in B0 else ''
ck('⑨ B：S2A_MESH_EMU 下有 main0_mc / main0_mc_z / main0_mv，顶点记录 dm_xvertex_t 带逐图元属性 locn2',
   all(k in B_EMU for k in ('kernel void main0_mc(', 'kernel void main0_mc_z(', 'vertex dm_xvertex_t main0_mv(', 'float4 p2 [[user(locn2)]];')), B0[-1500:])
ck('⑨ B：每组 32 × 3 个展开记录，角的顶点属性按索引字节取、逐图元属性按三角形号取',
   'device dm_xvertex_t* dm_vb = (device dm_xvertex_t*)(dm_xo + dm_xo[11]) + dm_tg * 96u;' in B_EMU and 'uint b = 4u + (dm_c / 32u) * 128u + dm_c % 32u;' in B_EMU
   and 'b = 132u + (dm_p / 32u) * 32u + dm_p % 32u;' in B_EMU and 'v.p2 = float4(as_type<float>(_35[b + 0u]), 0.0, 0.0, 1.0);' in B_EMU, B_EMU[:2000])
ck('⑨ B：索引 = 本组展开记录的顺序号', 'dm_ib[n] = dm_v0 + n;' in B_EMU and 'uint dm_v0 = dm_tg * 96u;' in B_EMU, B_EMU[-900:])
ck('⑨ 对照：不带逐图元属性的 A 照旧按顶点存（dm_vertex_t、每组 MaxV 个）', 'dm_xvertex_t' not in A0, A0[-600:])
# ⑦ 无任务、无逐图元属性的网格（F，#1542：M1 上这类原先没有宿主入口、悄悄落回驱动网格）：出 main0_mc / main0_mc_z / main0_mv；没有载荷与排表，
#   组号 = 派发线程组号（dm_j = dm_tg），工作组字 = 起始组号 + 组号（读槽 29 的 dm_first，同驱动入口），交换缓冲仍在槽 28
F0 = dshfn.fn('mesh_to_stage', kernel(189, False), ctl(7, 32, 0, mv=32, mp=32).hex(), area().hex())
F_EMU = F0.split('#ifdef S2A_MESH_EMU')[-1] if 'kernel void main0_mc(' in F0 else ''
ck('⑦ 无任务、无逐图元属性的网格（F）：S2A_MESH_EMU 下有 main0_mc / main0_mc_z / main0_mv',
   all(k in F_EMU for k in ('kernel void main0_mc(', 'kernel void main0_mc_z(', 'vertex dm_vertex_t main0_mv(', 'device uint* dm_xo [[buffer(28)]], constant uint* dm_first [[buffer(29)]]')), F0[-1500:])
# ⑧ 载荷超 16 KB 的任务 / 网格也出宿主入口（原先中转时一律不出，M1 / M2 上这一对整笔跳过、水面发黑）：任务 main0_tc 载荷照写交换缓冲（设备内存、不受 16 KB），
#   网格 main0_mc 的阶段内存（6500 字超线程组内存）放交换缓冲头字 23 起的片区、一个网格组一片，载荷从交换缓冲读
ck('⑧ 中转任务（D）：S2A_MESH_EMU 下有 main0_tc，载荷 5120 字写交换缓冲、派生数钳 1024', 'kernel void main0_tc(' in D0 and 'device uint* dm_p = dm_xo + dm_xo[1] + dm_tg * 5120u;' in D0
   and 'dm_xo[dm_xo[0] + dm_tg] = min(_35[5], 1024u);' in D0, D0[-1200:])
E_EMU = E0.split('#ifdef S2A_MESH_EMU')[-1] if 'kernel void main0_mc(' in E0 else ''
ck('⑧ 中转网格（E）：S2A_MESH_EMU 下有 main0_mc / main0_mc_z / main0_mv', all(k in E_EMU for k in ('kernel void main0_mc(', 'kernel void main0_mc_z(', 'vertex dm_vertex_t main0_mv(')), E0[-1500:])
ck('⑧ E：阶段内存是交换缓冲字 23 起的一片（片号 = 网格组号）、不是线程组内存、不读中转槽 27',
   'device spvUnsafeArray<uint, 6500>& _35 = *(device spvUnsafeArray<uint, 6500>*)(dm_xo + dm_xo[23] + (ulong)dm_tg * 6500u);' in E_EMU
   and 'threadgroup spvUnsafeArray<uint, 6500>' not in E_EMU and 'dm_relay' not in E_EMU, E_EMU[:1500])
ck('⑧ E：载荷从交换缓冲读进输入（字 4 起）', '_35[4u + i] = dm_xo[dm_xo[1] + dm_t * dm_xo[5] + i];' in E_EMU, E_EMU[:1500])
ck('⑦ F：组号取派发线程组号、工作组字 = 起始组号 + 组号，不读排表 / 载荷', 'uint dm_j = dm_tg;' in F_EMU and '_35[0] = dm_first[0] + dm_tg;' in F_EMU and 'dm_xo[dm_xo[2]' not in F_EMU and 'dm_xo[dm_xo[1]' not in F_EMU, F_EMU[:1200])
loop_kernel = kernel(1444, True).replace('    if (', '''    for (uint i = 0; i < 2u; i++)
    {
        _35[i] = i;
    }
    if (''', 1)
guarded_mesh = dshfn.batch([('mesh_to_stage', [loop_kernel, A_CTL.hex(), A_AREA.hex()])])[0]
G0 = guarded_mesh.get('ok', '')
ck('⑦ 核入口有循环：仍能提取阶段内存并保留循环护栏',
   all(s in G0 for s in ('    DM_LG_DECL()\n', '        DM_LG()\n', 'kernel void main0_mc_z(')), guarded_mesh.get('err'))
with tempfile.TemporaryDirectory() as t:
    for nm, src in (('A', A0), ('B', B0), ('C', C0), ('D', D0), ('E', E0), ('F', F0), ('G', G0)):
        f = os.path.join(t, nm + '.metal'); open(f, 'w').write(src)
        p = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-w', '-DS2A_MESH_EMU=1', '-fmetal-math-mode=relaxed', '-fpreserve-invariance', f, '-o', f + '.air'], capture_output=True, text=True)
        ck(f'⑦ {nm} 定义 S2A_MESH_EMU 交 xcrun metal（macosx）编过', bool(src) and p.returncode == 0, p.stderr.strip()[-300:])
print(f"{'✗' if bad else '✓'} meshstage：{n} 项，{bad} 项不符（手排 5 种控制段 / SPH、2 种拒绝、载荷中转、5 份 MSL 编 iOS）")
sys.exit(bool(bad))
