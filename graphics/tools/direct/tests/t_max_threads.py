#!/usr/bin/env python3
# 计算核线程数声明（S2A.Dsh DshCompiler.MaxThreads，经 dsh_cmp --fn max_threads 调；#2118 玩家 M1 Pro 实测：1024 线程的实例剔除核管线只给 640，加声明后 1024）。
#   线程组 > 256 的核：kernel 行前单独一行 [[max_total_threads_per_threadgroup(N)]]，「kernel void main0(」行首不变；≤ 256、> 1024、没有尺寸的原样。
#   改写后的源码真交 Metal 编译：管线上限 = 声明的 N（N 取 512，比本机不带声明时的 1024 低，证明声明被编译器认了、位置对）。
# 期望按规则手推（不跑被测实现）。负对照：DSH_CMP_DLL 指向改动前的翻译器，所有例都红（没有这个函数）。用法：python3 t_max_threads.py
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

MSL = "#include <metal_stdlib>\nusing namespace metal;\n\nkernel void main0(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]])\n{\n    o[i] = i;\n}\n"
HEAD = "#include <metal_stdlib>\nusing namespace metal;\n\n"
CASES = [   # (名, 线程组尺寸, 期望)
    ("1024 线程", [1024, 1, 1], HEAD + "[[max_total_threads_per_threadgroup(1024)]]\n" + MSL[len(HEAD):]),
    ("512 = 16×16×2", [16, 16, 2], HEAD + "[[max_total_threads_per_threadgroup(512)]]\n" + MSL[len(HEAD):]),
    ("257 线程", [257, 1, 1], HEAD + "[[max_total_threads_per_threadgroup(257)]]\n" + MSL[len(HEAD):]),
    ("256 线程不改", [256, 1, 1], MSL),
    ("64 线程不改", [8, 8, 1], MSL),
    ("没有尺寸不改", None, MSL),
    ("超 1024 不改", [2048, 1, 1], MSL),
]
bad = 0
res = dshfn.batch([("max_threads", [MSL, c[1]]) for c in CASES])
for (name, _, want), r in zip(CASES, res):
    ok = r.get("ok") == want
    bad += not ok
    print(("  过 " if ok else "  ✗ ") + name + ("" if ok else f"：得到 {r!r}"))

# 真编译：声明 512 的那份，管线上限应是 512
probe = r'''#import <Metal/Metal.h>
int main(int c, char **v) { @autoreleasepool { NSError *e = nil; id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  NSString *s = [NSString stringWithContentsOfFile:@(v[1]) encoding:NSUTF8StringEncoding error:nil];
  id<MTLLibrary> l = [d newLibraryWithSource:s options:nil error:&e]; if (!l) { printf("lib %s\n", e.localizedDescription.UTF8String); return 2; }
  id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"main0"] error:&e]; printf("%lu\n", (unsigned long)p.maxTotalThreadsPerThreadgroup); return 0; } }
'''
got512 = res[1].get("ok")
if isinstance(got512, str):
    with tempfile.TemporaryDirectory() as t:
        src, exe, msl = os.path.join(t, "p.m"), os.path.join(t, "p"), os.path.join(t, "k.metal")
        open(src, "w").write(probe); open(msl, "w").write(got512)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Metal", "-framework", "Foundation", src, "-o", exe], check=True)
        out = subprocess.run([exe, msl], capture_output=True, text=True).stdout.strip()
    ok = out == "512"; bad += not ok
    print(("  过 " if ok else "  ✗ ") + f"改写后的源码 Metal 编出管线上限 {out}（期望 512）")
else:
    bad += 1; print("  ✗ 没有改写结果，跳不了真编译")
print(("✓" if not bad else "✗") + f" t_max_threads：{len(CASES) + 1} 项，失败 {bad}")
sys.exit(1 if bad else 0)
