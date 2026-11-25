#!/usr/bin/env python3
# 片元着色器读不读 gl_FragCoord.z（S2A.Dsh DshCompiler.FragZ，经 dsh_cmp --fn frag_z 调；json frag_z，宿主据此决定要不要补片元深度偏移）。
#   frag_coord 连只读 .xy 也会设，frag_z 只在按分量读到 z 时设：.z、带 z 的混洗算；只读 .xy / .w、没有片元坐标、名字只是包含 gl_FragCoord 的都不算。
# 期望按规则手推（不跑被测实现）。用法：python3 t_frag_z.py
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

def fs(body): return "fragment main0_out main0(float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n" + body + "\n    return out;\n}\n"
CASES = [   # (名, MSL, 期望)
    ("自剥离比较 .z", fs("    bool _117 = gl_FragCoord.z > t.sample(s, uv).x;"), True),
    ("混洗 .zw", fs("    float2 a = gl_FragCoord.zw;"), True),
    ("混洗 .xyz", fs("    float3 a = gl_FragCoord.xyz;"), True),
    ("辅助函数形参同名", "float f(thread float4& gl_FragCoord) { return gl_FragCoord.z; }\n" + fs("    float a = gl_FragCoord.x;"), True),
    ("只读 .xy", fs("    float2 uv = gl_FragCoord.xy / 640.0;"), False),
    ("只读 .w", fs("    float a = 1.0 / gl_FragCoord.w;"), False),
    ("只读 .x 与 .y", fs("    float a = gl_FragCoord.x + gl_FragCoord.y;"), False),
    ("名字只是包含", fs("    float a = my_gl_FragCoord.z;"), False),
    ("没有片元坐标", "fragment main0_out main0() { main0_out out = {}; return out; }\n", False),
]
bad = 0
res = dshfn.batch([("frag_z", [c[1]]) for c in CASES])
for (name, _, want), r in zip(CASES, res):
    ok = r.get("ok") is want
    bad += not ok
    print(("  过 " if ok else "  ✗ ") + name + ("" if ok else f"：得到 {r!r}，期望 {want}"))
print(("✓" if not bad else "✗") + f" t_frag_z：{len(CASES)} 项，失败 {bad}")
sys.exit(1 if bad else 0)
