#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/CodeGen/Spirv/Instructions.cs tests/vs_lane_id_test.sh
# 门禁显卡：共享（11-20 读写锁：不按显示时钟判，从独占降为共享；建 Metal 设备、在本机 GPU 上真跑；11-11 维护者补声明：入队预检据此把它的红记「没判、交列车门禁」，门禁走显卡共享锁）
# 顶点阶段车道号的计算（Ryujinx 补丁 vertex-lane-id-exact：Instructions.EmulatedLaneId，约 3 秒，要 Metal）：bash tests/vs_lane_id_test.sh
# Metal 顶点函数没有车道号输入（SPIRV-Cross 拒绝 SubgroupLocalInvocationId），翻译器在顶点阶段算出它：r = simd_prefix_exclusive_sum(1)（活跃车道里的排名），
#   车道号 = 硬件 ballot(true) 位图里第 r 个置位的位置（先按四个字的置位累计定位落在第几个字，再在字内 popcount 五步二分；审计 1101 18:00 P1-61：
#   同一份 SPIR-V 也给安卓 Vulkan，子组可到 64 / 128 宽，只看第一个字会落错）。下面的 MSL 是 SPIRV-Cross 对 EmulatedLaneId 的原样输出形态（11-01 王国之泪 1eee2726aae7493e
#   翻出的 _b.metal 第 74–83 行，换了变量名）。期望按定义手算，不跑翻译器：
#   ① 计算核（有硬件真值 thread_index_in_simdgroup）：车道 i 按 8 种分歧模式提前返回（全活跃、奇数、低半、高半、每 3 个留 1、只留最高、只留最低、随机），
#      留下的车道算出的车道号逐个 = 硬件车道号
#   ② 端到端（王国之泪可见计数的形态，顶点函数、关光栅）：顶点 v 按同样模式提前返回，留下的做 ballot(true)，「位图最高位 == 我的车道号」的那个车道
#      原子加 popcount(位图) → 计数 = 留下的顶点数（手算）；每种模式 4096 个顶点
#   ③ 反证：车道号用旧公式（只取排名 r）时，②里至少一种有缺口的模式计数对不上（判据不会绿着失效；全活跃模式两公式相同）
#   ⑤ 宽子组（CPU 按同一算法逐车道模拟，期望 = 真车道号）：32 / 64 / 128 宽 × 8 种分歧模式，新算法逐个等于真车道号；反证：只看第一个字（改前）在 64 / 128 宽对不上
#   ④ 翻译器源码：EmulatedLaneId 里是 ballot(true)、四个字逐字累计 + 五步 BitCount 二分（防止源码退回旧公式而本测照绿）；LaneIdEmulated 覆盖顶点与域（TessellationEvaluation）两个阶段
#      （域着色器在 Metal 是后曲面顶点函数，同样没有车道号输入：蓓优妮塔3 DS_Vanish05 两支原先 SPIRV-Cross「Subgroup builtins」失败）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/vs_lane.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
SRC=$H/compat/tree/src/Ryujinx.Graphics.Shader/CodeGen/Spirv/Instructions.cs
body=$(awk '/private static SpvInstruction EmulatedLaneId/,/^        }$/' "$SRC")
if grep -q 'GroupNonUniformBallot' <<< "$body" && grep -q 'BitCount' <<< "$body" && grep -q 'new\[\] { 16, 8, 4, 2, 1 }' <<< "$body" && grep -q 'i < 4; i++' <<< "$body"; then echo "✓ ④ 翻译器 EmulatedLaneId：ballot(true)、四个字累计 + 五步 BitCount 二分"
else echo "✗ ④ 翻译器 EmulatedLaneId 不是 ballot、四个字累计 + 五步二分的形态"; bad=1; fi
stage=$(awk '/internal static bool LaneIdEmulated/,/^        }$/' "$SRC")
if grep -q 'ShaderStage.Vertex' <<< "$stage" && grep -q 'ShaderStage.TessellationEvaluation' <<< "$stage"; then echo "✓ ④ LaneIdEmulated 覆盖顶点与域两个阶段"
else echo "✗ ④ LaneIdEmulated 没覆盖域阶段（TessellationEvaluation）"; bad=1; fi
cat > "$T/t.m" <<'EOF'
#import <Metal/Metal.h>
#include <stdio.h>
static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
  "static inline bool gone(uint m, uint i, uint v) { switch (m) { case 0: return false; case 1: return (i & 1u) == 0u; case 2: return i >= 16u; case 3: return i < 16u;"
  " case 4: return i % 3u != 0u; case 5: return i != 31u; case 6: return i != 0u; default: return ((v * 2654435761u) >> 28) < 7u; } }\n"
  "static inline uint lane_new() { uint r = simd_prefix_exclusive_sum(1u); uint4 b = uint4(as_type<uint2>((simd_vote::vote_t)simd_ballot(true)), 0u, 0u);\n"
  "  uint c0 = popcount(b.x), c1 = c0 + popcount(b.y), c2 = c1 + popcount(b.z); bool i0 = r < c0, i1 = r < c1, i2 = r < c2;\n"
  "  uint m = i0 ? b.x : i1 ? b.y : i2 ? b.z : b.w; uint f = i0 ? 0u : i1 ? 32u : i2 ? 64u : 96u; r -= i0 ? 0u : i1 ? c0 : i2 ? c1 : c2; uint p = 0u;\n"
  "  uint n = p + 16u; p = (popcount(m & ((1u << n) - 1u)) <= r) ? n : p; n = p + 8u; p = (popcount(m & ((1u << n) - 1u)) <= r) ? n : p;\n"
  "  n = p + 4u; p = (popcount(m & ((1u << n) - 1u)) <= r) ? n : p; n = p + 2u; p = (popcount(m & ((1u << n) - 1u)) <= r) ? n : p;\n"
  "  n = p + 1u; p = (popcount(m & ((1u << n) - 1u)) <= r) ? n : p; return f + p; }\n"
  "static inline uint lane_old() { return simd_prefix_exclusive_sum(1u); }\n"
  "kernel void k(device uint* o [[buffer(0)]], constant uint& mode [[buffer(1)]], uint gid [[thread_position_in_grid]], uint hw [[thread_index_in_simdgroup]]) {\n"
  "  o[gid] = 0xffffffffu; if (gone(mode, hw, gid)) return; uint l = lane_new(); o[gid] = l == hw ? 1u : 0u; }\n"
  "template<bool NEW> static inline void count(uint v, uint mode, device atomic_uint* c) { if (gone(mode, v & 31u, v)) return;\n"
  "  uint b = uint(as_type<uint2>((simd_vote::vote_t)simd_ballot(true)).x); uint l = NEW ? lane_new() : lane_old();\n"
  "  if (uint(31 - clz(b)) == l) atomic_fetch_add_explicit(c, uint(popcount(b)), memory_order_relaxed); }\n"
  "vertex void vn(uint v [[vertex_id]], constant uint& mode [[buffer(1)]], device atomic_uint* c [[buffer(0)]]) { count<true>(v, mode, c); }\n"
  "vertex void vo(uint v [[vertex_id]], constant uint& mode [[buffer(1)]], device atomic_uint* c [[buffer(0)]]) { count<false>(v, mode, c); }\n";
static int gone(unsigned m, unsigned i, unsigned v) { switch (m) { case 0: return 0; case 1: return (i & 1) == 0; case 2: return i >= 16; case 3: return i < 16;
  case 4: return i % 3 != 0; case 5: return i != 31; case 6: return i != 0; default: return ((v * 2654435761u) >> 28) < 7; } }
int main(void) { @autoreleasepool {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [d newCommandQueue]; NSError *e = nil;
  id<MTLLibrary> lib = [d newLibraryWithSource:kSrc options:nil error:&e]; if (!lib) { printf("✗ MSL 编不过：%s\n", e.description.UTF8String); return 1; }
  id<MTLComputePipelineState> kp = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e];
  id<MTLRenderPipelineState> vp[2];
  for (int i = 0; i < 2; i++) { MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:i ? @"vo" : @"vn"]; pd.rasterizationEnabled = NO;
    vp[i] = [d newRenderPipelineStateWithDescriptor:pd error:&e]; if (!vp[i]) { printf("✗ 顶点管线：%s\n", e.description.UTF8String); return 1; } }
  if (kp.threadExecutionWidth != 32) { printf("✗ SIMD 宽 %lu，本测按 32 写\n", (unsigned long)kp.threadExecutionWidth); return 1; }
  enum { N = 4096 }; int bad = 0, oldmiss = 0;
  id<MTLBuffer> o = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared], c = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
  for (unsigned m = 0; m < 8; m++) {
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:kp]; [ce setBuffer:o offset:0 atIndex:0]; [ce setBytes:&m length:4 atIndex:1]; [ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    int live = 0, eq = 0; for (int i = 0; i < N; i++) { unsigned x = ((unsigned *)o.contents)[i]; if (x != 0xffffffffu) { live++; eq += x == 1; } }
    int ok = live > 0 && eq == live; bad |= !ok; printf("%s ① 分歧模式 %u：留下 %d 个车道，算出的车道号 = 硬件车道号 %d / %d\n", ok ? "✓" : "✗", m, live, eq, live);
    unsigned got[2], want = 0; for (unsigned v = 0; v < N; v++) want += !gone(m, v & 31, v);
    for (int f = 0; f < 2; f++) {
      *(unsigned *)c.contents = 0; cb = [q commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.renderTargetWidth = 1; rp.renderTargetHeight = 1; rp.defaultRasterSampleCount = 1;
      id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:vp[f]]; [re setVertexBuffer:c offset:0 atIndex:0]; [re setVertexBytes:&m length:4 atIndex:1];
      [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:N]; [re endEncoding]; [cb commit]; [cb waitUntilCompleted]; got[f] = *(unsigned *)c.contents;
    }
    ok = got[0] == want; bad |= !ok; oldmiss += got[1] != want;
    printf("%s ② 可见计数 模式 %u：%u（期望留下的顶点数 %u）；旧公式 %u\n", ok ? "✓" : "✗", m, got[0], want, got[1]);
  }
  int ok = oldmiss > 0; bad |= !ok; printf("%s ③ 反证：旧公式（只取排名）有 %d / 8 种模式计数对不上\n", ok ? "✓" : "✗", oldmiss);
  for (int W = 32; W <= 128; W *= 2) { int n4 = 0, eq4 = 0, eq1 = 0;
    for (unsigned m = 0; m < 8; m++) for (unsigned g = 0; g < 16; g++) {
      uint32_t b[4] = {0}; for (int i = 0; i < W; i++) if (!gone(m, i % 32 == i ? i : i % 32, g * 1000u + (unsigned)i) && !(m == 5 && i != W - 1) && !(m == 3 && i < W / 2) && !(m == 2 && i >= W / 2)) b[i / 32] |= 1u << (i % 32);
      unsigned rank = 0;
      for (int i = 0; i < W; i++) { if (!(b[i / 32] >> (i % 32) & 1)) continue;
        unsigned c0 = __builtin_popcount(b[0]), c1 = c0 + __builtin_popcount(b[1]), c2 = c1 + __builtin_popcount(b[2]); int i0 = rank < c0, i1 = rank < c1, i2 = rank < c2;
        uint32_t mk = i0 ? b[0] : i1 ? b[1] : i2 ? b[2] : b[3]; unsigned f = i0 ? 0 : i1 ? 32 : i2 ? 64 : 96, r = rank - (i0 ? 0 : i1 ? c0 : i2 ? c1 : c2), p = 0;
        for (unsigned st = 16; st; st >>= 1) { unsigned nn = p + st; uint32_t lw = nn >= 32 ? 0xffffffffu : (1u << nn) - 1u; if ((unsigned)__builtin_popcount(mk & lw) <= r) p = nn; }
        unsigned q = 0; for (unsigned st = 16; st; st >>= 1) { unsigned nn = q + st; uint32_t lw = nn >= 32 ? 0xffffffffu : (1u << nn) - 1u; if ((unsigned)__builtin_popcount(b[0] & lw) <= rank) q = nn; }
        n4++; eq4 += (int)(f + p) == i; eq1 += (int)q == i; rank++; } }
    ok = n4 > 0 && eq4 == n4 && (W == 32 ? eq1 == n4 : eq1 < n4); bad |= !ok;
    printf("%s ⑤ %d 宽子组（CPU 模拟）：四个字算法 %d / %d 车道号正确；只看第一个字 %d / %d（期望 %s）\n", ok ? "✓" : "✗", W, eq4, n4, eq1, n4, W == 32 ? "全对" : "有错，反证");
  }
  return bad;
} }
EOF
xcrun clang -fobjc-arc -framework Metal -framework Foundation "$T/t.m" -o "$T/t" 2> "$T/cc.log" || { echo "✗ 执行器编不过：$(head -3 "$T/cc.log")"; exit 1; }
"$T/t" || bad=1
[ $bad = 0 ] && echo "vs_lane_id：全过" || echo "vs_lane_id：有失败"; exit $bad
