#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/Dsh.cs graphics/tools/direct/tests/dsh_cmp/Fn.cs graphics/tools/direct/tests/dshfn.py tests/dmsh_pool_arrays_test.sh
# 追不到槽的句柄读整个池（S2A.Dsh DshCompiler.PoolArrays + Reflect，经 dsh_cmp --fn，约 10 秒）：bash tests/dmsh_pool_arrays_test.sh
# 11-06 Switch2 线 63：翻译器原先把 Ryujinx 回退数组 <阶段>_<t|s>_cb0_40000000 写死 32 项（下标夹到 31），宿主第 k 项绑第 k 个贴图槽：句柄指的贴图编号 ≥ 32 时读到别的贴图
#   （时之笛 4,454 支，抽查一支是阴影深度比较）。现在翻译器按池长出（纹理 2^20、采样器 2^12），PoolArrays 改成指向宿主池表的指针（上游参考实现（MIT）pool_arrays）。
# 期望按语义手写（不跑被测实现推）：合成 MSL = 真库条目的形状（时之笛 6142627246ed… 那支：spvDepthCast(...fp_t2ds_cb0_40000000[int(i)]).sample_compare(...fp_s_cb0_40000000[int(j)], ...)）
#   成员：support_buffer id0、fp_s0 id1、贴图池 2^20 项 id2、采样器池 2^12 项 id1048578、贴图缓冲回退 32 项 id1052674、普通贴图 id1052706、它的采样器 id1052707
#   ① 两个池成员改成 constant spvPool_<名>* 指针，结构体 { uint n; ulong seen; array<元素, 1> e; } 在参数块之前，置位函数 dm_pool_mark 在结构体之前
#   ② 参数号按成员次序重排、指针占 1 个、32 项数组占 32 个：0, 1, 2, 3, 4, 36, 37
#   ③ 贴图读 → (&base->e[0])[dm_pool_mark(base, min(uint(下标), base->n))]；采样器读不置位 → (&base->e[0])[min(uint(下标), base->n)]；32 项贴图缓冲数组原样
#   ④ 着色器自己没有丢弃 / 写深度 / 写内存（存储缓冲只读 const device）→ 片元入口前加 [[early_fragment_tests]]；有 discard_fragment → 不加；已有 → 不重复；
#      声明可写存储缓冲（device，可能写内存）→ 不加
#   ⑤ 没有 ≥ 33 项的 _cb0_40000000 数组 → 原文不动
#   ⑥ 整个池数组当参数传（改写覆盖不到）→ 报 pool rewrite failed，原因含名字
#   ⑦ 改写后的反射：贴图池 kind tex_pool、elem texture2d<float>、arg_id 2；采样器池 kind samp_pool、arg_id 3；普通贴图 arg_id 36
#   ⑧ 改写后的 MSL 交 Metal 编译器（xcrun metal，macOS）能编过（证明形状是合法 MSL，宿主 t_nvn_pool_tex 用同一形状真跑）
#   ⑨ 早测的池片元，FsAlphaMs 不再加函数常量里的 alpha 丢弃（深度已先写，丢弃改不回来；宿主要 alpha 测试时报红 134）；没早测的照加
#   ⑩ 置位函数测位用普通读（device uint*，不用 atomic_load_explicit），只有没置位才原子或（11-13 照 nxnative 04811a63：原子读走共享缓存，同字像素排队）
# 旧代码反证：PoolArrays 不存在（dsh_cmp --fn 报未知函数），① ~ ⑨ 全不通；负对照（把改写里的 dm_pool_mark 去掉）→ ③ 不通。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
[ -x "$PY" ] || PY=$(command -v python3) || { echo "dmsh_pool_arrays_test：缺 Python 解释器，环境未就绪（退出 75）"; exit 75; }
T=$(mktemp -d "${TMPDIR:-/tmp}/t_pool_arrays.XXXXXX"); trap 'rm -rf "$T"' EXIT
out=$("$PY" - "$H" "$T" 2>&1 <<'PYEOF'
import os, re, subprocess, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
T = sys.argv[2]
HEAD = '''#include <metal_stdlib>
using namespace metal;
struct _10 { float4 data[1]; };
struct _23 { uint data[1]; };
template<typename T> static inline depth2d<T> spvDepthCast(texture2d<T> t) { return reinterpret_cast<thread const depth2d<T>&>(t); }

struct main0_out
{
    float4 c [[color(0)]];
};

struct main0_in
{
    float2 uv [[user(locn0)]];
};

'''
msl = HEAD + '''struct spvDescriptorSetBuffer0
{
    constant _10* support_buffer [[id(0)]];
    const device _23* fp_s0 [[id(1)]];
    array<texture2d<float>, 1048576> fp_t2ds_cb0_40000000 [[id(2)]];
    array<sampler, 4096> fp_s_cb0_40000000 [[id(1048578)]];
    array<texture_buffer<float>, 32> fp_tb_cb0_40000000 [[id(1052674)]];
    texture2d<float> fp_t_tcb_8 [[id(1052706)]];
    sampler fp_t_tcb_8Smplr [[id(1052707)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    uint _5 = min(uint(spvDescriptorSet0.fp_s0->data[1]), 1048575u);
    uint _6 = min(uint(spvDescriptorSet0.fp_s0->data[2]), 4095u);
    float _7 = spvDepthCast(spvDescriptorSet0.fp_t2ds_cb0_40000000[int(_5)]).sample_compare(spvDescriptorSet0.fp_s_cb0_40000000[int(_6)], in.uv, 0.5);
    float4 _8 = spvDescriptorSet0.fp_tb_cb0_40000000[int(min(_5, 31u))].read(uint(0));
    out.c = float4(_7) + _8 + spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, in.uv);
    return out;
}
'''
wdev = msl.replace('    const device _23* fp_s0', '    device _23* fp_s0')
disc = msl.replace('    return out;\n}', '    if (_7 < 0.0) discard_fragment();\n    return out;\n}')
early = msl.replace('fragment main0_out main0(', '[[early_fragment_tests]] fragment main0_out main0(')
small = msl.replace('1048576> fp_t2ds', '32> fp_t2ds').replace('4096> fp_s_cb0', '32> fp_s_cb0').replace('1048575u', '31u').replace('4095u', '31u')
whole = msl.replace('    main0_out out = {};', '    main0_out out = {};\n    f(spvDescriptorSet0.fp_t2ds_cb0_40000000);')
r = dshfn.batch([('pool_arrays', [msl]), ('pool_arrays', [disc]), ('pool_arrays', [early]), ('pool_arrays', [small]), ('pool_arrays', [whole]), ('pool_arrays', [wdev])])
o, od, oe, osm, ow, owd = (x.get('ok') for x in r)
ok = isinstance(o, str)
print('1', ok and 'struct spvPool_fp_t2ds_cb0_40000000\n{\n    uint n;\n    ulong seen;\n    array<texture2d<float>, 1> e;\n};' in o
      and 'struct spvPool_fp_s_cb0_40000000\n{\n    uint n;\n    ulong seen;\n    array<sampler, 1> e;\n};' in o
      and o.index('dm_pool_mark(constant P* p') < o.index('struct spvPool_') < o.index('struct spvDescriptorSetBuffer0')
      and 'constant spvPool_fp_t2ds_cb0_40000000* fp_t2ds_cb0_40000000 [[id(2)]];' in o and 'constant spvPool_fp_s_cb0_40000000* fp_s_cb0_40000000 [[id(3)]];' in o)
body = re.search(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', o, re.S).group(1) if ok else ''
print('2', [int(x) for x in re.findall(r'\[\[id\((\d+)\)', body)])
print('3', ok and '(&spvDescriptorSet0.fp_t2ds_cb0_40000000->e[0])[dm_pool_mark(spvDescriptorSet0.fp_t2ds_cb0_40000000, min(uint(int(_5)), spvDescriptorSet0.fp_t2ds_cb0_40000000->n))]' in o
      and '(&spvDescriptorSet0.fp_s_cb0_40000000->e[0])[min(uint(int(_6)), spvDescriptorSet0.fp_s_cb0_40000000->n)]' in o
      and 'spvDescriptorSet0.fp_tb_cb0_40000000[int(min(_5, 31u))].read' in o and 'array<texture_buffer<float>, 32> fp_tb_cb0_40000000 [[id(4)]];' in o)
print('4', ok and o.count('[[early_fragment_tests]] fragment main0_out main0(') == 1, isinstance(od, str) and 'early_fragment_tests' not in od, isinstance(oe, str) and oe.count('early_fragment_tests') == 1, isinstance(owd, str) and 'early_fragment_tests' not in owd)
print('5', osm == small)
print('6', isinstance(ow, dict) and ow.get('err') == 'pool rewrite failed' and 'fp_t2ds_cb0_40000000' in ow.get('detail', ''))
rf = dshfn.batch([('reflect_detail', ['ps', o if ok else '', {'sbufs': [{'binding': 0, 'cb_slot': 0, 'cb_offset': 0x510 // 4, 'flags': 0}]}])])[0].get('ok')
by = {e['msl_name']: e for e in rf} if isinstance(rf, list) else {}
print('7', [(by.get(n, {}).get('kind'), by.get(n, {}).get('elem'), by.get(n, {}).get('arg_id')) for n in ('fp_t2ds_cb0_40000000', 'fp_s_cb0_40000000', 'fp_t_tcb_8')])
if ok:
    open(os.path.join(T, 'p.metal'), 'w').write(o)
    c = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-std=metal3.0', '-c', os.path.join(T, 'p.metal'), '-o', os.path.join(T, 'p.air')], capture_output=True, text=True)
    print('8', c.returncode == 0, (c.stderr.strip().splitlines() or [''])[0][:200])
else: print('8', False, r[0])
fa = dshfn.batch([('fs_alpha_ms', [o if ok else '']), ('fs_alpha_ms', [od if isinstance(od, str) else ''])])
mk = o[o.index('dm_pool_mark(constant P* p'):o.index('struct spvPool_')] if ok else ''
print('10', 'atomic_load_explicit' not in mk and 'if (!(*w & b)) atomic_fetch_or_explicit(reinterpret_cast<device atomic_uint*>(w), b, memory_order_relaxed);' in mk)
print('9', isinstance(fa[0].get('ok'), str) and 'S2A_AT_ON' not in fa[0]['ok'], isinstance(fa[1].get('ok'), str) and 'S2A_AT_ON' in fa[1]['ok'])
PYEOF
)
bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$3」，实得「$2」"; bad=1; fi; }
g() { grep "^$1 " <<< "$out" | head -1 | cut -d' ' -f2-; }
ck "① 两个池成员改成池指针、结构体与置位函数在参数块之前" "$(g 1)" "True"
ck "② 参数号重排：指针占 1、32 项数组占 32" "$(g 2)" "[0, 1, 2, 3, 4, 36, 37]"
ck "③ 贴图读置位、采样器读不置位、贴图缓冲 32 项原样" "$(g 3)" "True"
ck "④ 早测：无副作用加一次 / 有 discard 不加 / 已有不重复 / 可写存储缓冲不加" "$(g 4)" "True True True True"
ck "⑤ 没有 ≥33 项的池数组：原文不动" "$(g 5)" "True"
ck "⑥ 整个池数组当参数：报 pool rewrite failed" "$(g 6)" "True"
ck "⑦ 反射：tex_pool / samp_pool、参数号 2 / 3、普通贴图 36" "$(g 7)" "[('tex_pool', 'texture2d<float>', 2), ('samp_pool', 'sampler', 3), ('tex', None, 36)]"
ck "⑧ 改写后的 MSL 交 Metal 编译器编过" "$(g 8 | cut -d' ' -f1)" "True"
ck "⑨ 早测的池片元不加 alpha 丢弃、没早测的照加" "$(g 9)" "True True"
ck "⑩ 置位测位用普通读、没置位才原子或" "$(g 10)" "True"
[ $bad = 0 ] && { echo "✓ dmsh_pool_arrays_test：10 项全通"; exit 0; }
echo "$out" | head -30; echo "✗ dmsh_pool_arrays_test：10 项有不通"; exit 1
