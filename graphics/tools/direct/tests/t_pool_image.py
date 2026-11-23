#!/usr/bin/env python3
# 图像的整池回退数组（S2A.Dsh DshCompiler.PoolArrays / IsPoolName，经 dsh_cmp --fn pool_arrays / reflect 调）：
#   翻译器对追不到槽的图像句柄出 array<图像, 池长> <阶段>_i<类型>_cb0_40000000_<格式>（compat ResourceManager 名字带格式后缀，格式认不出时是空串）。
#   11-22 #2051（0100AD80208A8000）：8 支计算着色器的 cp_ib_cb0_40000000_（图像缓冲、格式空）原先只按 _cb0_40000000 收尾判，没改成池指针，
#   反射成没有槽号的 img，宿主「B binding … has no resolved slot number」整支拒载，游戏发起的计算落空。
# 期望按规则手写（不跑被测实现）：
#   ① 图像缓冲池、格式空（名字以「_」收尾）→ 成员换成 constant spvPool_<名>* [[id(0)]]，写改成 (&…->e[0])[dm_pool_mark(…)]；反射 kind tex_pool、elem 原样
#   ② 2D 读写图像池、格式带下划线（rgb10_a2）→ 同上
#   ③ 格式 r32ui 的图像缓冲池 → 同上
#   ④ 负对照：同名形状但不够池长（32 项，POOL_MIN 33 以下）→ 原样
#   ⑤ 负对照：句柄库不是 cb0（cp_i2d_cb2_40000000_rgba8）→ 原样
#   反证：DSH_CMP_DLL 指向改动前的翻译器时 ①②③ 红（成员不变、反射不是 tex_pool）。用法：python3 t_pool_image.py
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn


def kernel(member, use):
    return ('struct spvDescriptorSetBuffer0\n{\n    ' + member + ' [[id(0)]];\n};\n\n'
            'kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]])\n{\n'
            '    uint _5 = gl_LocalInvocationID.x;\n    ' + use + '\n}\n')


IB = 'cp_ib_cb0_40000000_'
I2 = 'cp_i2d_cb0_40000000_rgb10_a2'
IR = 'cp_ib_cb0_40000000_r32ui'
cases = [
    ('① 图像缓冲池、格式空', IB, 'texture_buffer<uint, access::write>', 1048576, f'spvDescriptorSet0.{IB}[_5 & 1048575u].write(uint4(1u), uint(0));', True),
    ('② 2D 读写图像池、格式 rgb10_a2', I2, 'texture2d<float, access::read_write>', 1048576, f'spvDescriptorSet0.{I2}[_5 & 1048575u].write(float4(0.5), uint2(0));', True),
    ('③ 图像缓冲池、格式 r32ui', IR, 'texture_buffer<uint, access::write>', 1048576, f'spvDescriptorSet0.{IR}[_5 & 1048575u].write(uint4(_5), uint(1));', True),
    ('④ 负对照：32 项（不够池长）', IB, 'texture_buffer<uint, access::write>', 32, f'spvDescriptorSet0.{IB}[_5 & 31u].write(uint4(1u), uint(0));', False),
    ('⑤ 负对照：句柄库 cb2', 'cp_i2d_cb2_40000000_rgba8', 'texture2d<float, access::write>', 1048576, 'spvDescriptorSet0.cp_i2d_cb2_40000000_rgba8[_5 & 1048575u].write(float4(0.5), uint2(0));', False),
]
srcs = [kernel(f'array<{el}, {n}> {nm}', use) for _, nm, el, n, use, _ in cases]
res = dshfn.batch([('pool_arrays', [s]) for s in srcs])
refl = dshfn.batch([('reflect', ['cs', r.get('ok'), {'sbufs': []}]) if isinstance(r.get('ok'), str) else ('reflect', ['cs', '', {}]) for r in res])
n = bad = 0
for (name, nm, el, ln, use, pooled), src, r, rf in zip(cases, srcs, res, refl):
    n += 1; out = r.get('ok')
    if not isinstance(out, str): err = f'调用失败 {r}'
    elif not pooled: err = None if out == src else '应原样，真结果改了'
    else:
        need = [f'constant spvPool_{nm}* {nm} [[id(0)]];', f'struct spvPool_{nm}\n{{\n    uint n;\n    ulong seen;\n    array<{el}, 1> e;\n}};',
                f'(&spvDescriptorSet0.{nm}->e[0])[dm_pool_mark(spvDescriptorSet0.{nm}, ']
        err = next((f'改写后缺 {m!r}' for m in need if m not in out), None)
        if err is None:
            b = rf.get('ok'); b = b[0] if isinstance(b, list) and b else b
            got = (b.get('kind'), b.get('elem')) if isinstance(b, dict) else b
            err = None if got == ('tex_pool', el) else f'反射 {got}，应 (tex_pool, {el})'
    bad += err is not None
    print(f'{"✓" if err is None else "✗"} {name}{"" if err is None else "：" + err}')
print(f'图像整池回退数组：{n - bad}/{n} 例过')
sys.exit(1 if bad else 0)
