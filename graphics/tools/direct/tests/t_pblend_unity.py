#!/usr/bin/env python3
# 可编程混合（#674，graphics/dsx/gal_colorround.c 直连版，经 dsh_cmp --fn color_round 调）进成批合编（C# Unity.Src，graphics/tools/direct/dsh/batch/Unity.cs）。
# 期望按契约手写：
#   ① 两支改过的片元拼一批：每个开关常量声明行（s2a_pb<n>_c，函数常量编号 110 + n）在批里只出现一次、在 using namespace metal; 之后、各键命名空间之外
#      （各键各声明一次即同编号的函数常量声明两次，Metal 编不过）
#   ② 批源码用 xcrun metal 编得过
# 反证：未补 UG 之前声明行留在各键命名空间里，① 计数为 2、② 报重复的函数常量。用法：t_pblend_unity.py
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(HERE, '../../../..')); sys.path.insert(0, HERE); import dshfn
sys.path.insert(0, os.path.join(R, 'translator')); import dsh_batch
HEAD = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
FS = (HEAD + 'struct main0_out\n{\n    float4 m_0 [[color(0)]];\n    float4 m_1 [[color(1)]];\n};\n\nstruct main0_in\n{\n    float4 m_0 [[user(locn0)]];\n};\n\n'
      'fragment main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    out.m_0 = in.m_0;\n    out.m_1 = in.m_0.wzyx;\n    return out;\n}\n\n')
FS1 = FS.replace('    float4 m_1 [[color(1)]];\n', '').replace('    out.m_1 = in.m_0.wzyx;\n', '')
D0 = 'constant bool s2a_pb0_c [[function_constant(110)]];'
D1 = 'constant bool s2a_pb1_c [[function_constant(111)]];'
fails = []
def ck(what, cond):
    print(('✓ ' if cond else '✗ ') + what)
    if not cond: fails.append(what)

r = dshfn.batch([('color_round', [FS]), ('color_round', [FS1])], dsx=dshfn.DSX)
if any('ok' not in x for x in r): print('✗ dsh_cmp --fn color_round 报错：', [x.get('err') for x in r]); sys.exit(1)
a, b = (x['ok'] for x in r)
ck('前提：改写后两支都带附件 0 的开关常量、只有第一支带附件 1 的', a.count(D0) == 1 and b.count(D0) == 1 and a.count(D1) == 1 and D1 not in b)

with tempfile.TemporaryDirectory(prefix='t_pblend_unity_') as td:
    args = []
    for i, txt in enumerate((a, b)):
        p = os.path.join(td, f'{i}.metal'); open(p, 'w').write(txt); args += [f'{i}' * 16, p]
    o = os.path.join(td, 'u.metal'); c = subprocess.run([*dsh_batch.get()[0], '--unity', 'src', o, *args], capture_output=True, text=True)
    if c.returncode: print('✗ dsh_batch --unity src 报错：' + (c.stdout + c.stderr).strip()[-300:]); sys.exit(1)
    u = open(o).read()
    first_ns = u.find('namespace n')
    ck(f'① 开关常量声明各一次（附件 0：{u.count(D0)} 次，附件 1：{u.count(D1)} 次）', u.count(D0) == 1 and u.count(D1) == 1)
    ck('① 声明在 using namespace metal; 之后、第一个键命名空间之前',
       D0 in u and u.index('using namespace metal;') < u.index(D0) and first_ns > 0 and u.index(D0) < first_ns and u.index(D1) < first_ns)
    m = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', o, '-o', os.path.join(td, 'u.air')], capture_output=True, text=True)
    ck('② 批源码编得过' + ('' if not m.returncode else '：' + m.stderr.strip()[-300:]), m.returncode == 0)

print(f'{"✗" if fails else "✓"} t_pblend_unity：不通 {len(fails)}')
sys.exit(1 if fails else 0)
