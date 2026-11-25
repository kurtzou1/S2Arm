#!/bin/bash
# 门禁覆盖：graphics/dsx/* graphics/tools/direct/dsh/* graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py tests/dsh_harden_test.sh
# 门禁显卡：共享（11-20 读写锁：不按显示时钟判，从独占降为共享；建 Metal 设备、在本机 GPU 上真跑；11-11 维护者补声明：入队预检据此把它的红记「没判、交列车门禁」，门禁走显卡共享锁）
# 直连着色器链的越界保护（#1204 T1：S2A.Dsh 交 SPIRV-Cross 前调 NxgalSpvCross.Harden = libdsx nxgal_spv_harden，与通用路径同一份 gal_spvx.m；直连不加循环上限（11-01 维护者定，见 gal_spvx.m spv_harden）；约 20 秒，要 Metal）
#   一支 GLSL 计算核（存储数组 a 声明 4 个元素，下标 idx 与循环次数 n 都从缓冲读，编译期不知道）：
#     o[0] = a[idx]（越界读）；a[idx] = 77（越界写）；atomicAdd(a[idx], 5)（越界原子，返回值进 o[2]）；for (c < n) c++ → o[1] = c（读数据决定的循环）
#   缓冲布局：a 所在 MTLBuffer 64 字节，a[0..3] = 10..13，a[4..15] 哨兵 0xAAAA0000 + i；idx = 6、n = 2^24（单线程几毫秒，改前跑满也不会挂死 GPU）
#   期望（按 gal_spvx.m 文件头的口径手算，不跑被测实现）：加固后 o[0] = a[3] = 13（越界读只钳下标，11-01 维护者定撤掉读回 0）、哨兵 a[4..15] 全不变（越界写 / 原子不执行）、o[2] = 13（越界原子不执行、返回钳到元素 a[3] 的当前值；11-23 前回 0，读改写重试循环越界时空转不退）、
#     o[1] = 2^24（直连链不加循环上限：读数据决定的循环照原样跑满；通用链的上限由 graphics/metal/tests/t_prog 管）
#   反证（同一支 SPIR-V 不加固，改前直连链的样子）：o[0] = 哨兵 a[6] = 0xAAAA0006、a[6] 被写成 77 + 5
#   另核：直连 Compile 里交 SPIRV-Cross 的两处（Msl 本地函数、TessMsl）都先经 NxgalSpvCross.Harden；S2A.Dsh 翻译指纹输入含 gal_spvx.m
# 第二支（11-02 重进：直连宿主只知道 NVN 槽，界长表按槽索引；首版按 SPIR-V 绑定号，宿主不认、读空指针被撤）：常量缓冲 cp_c7（NVN 槽 4，SPIR-V 绑定号 9）与 cp_c1（着色器自带常量段），
#   存储缓冲 P { uint idx; uint rt[]; }（运行时数组，加固用 OpArrayLength → SPIRV-Cross spvBufferSizeConstants）：o[0] = cp_c7.data[idx].x、o[1] = cp_c1.data[idx].x、o[2] = rt[idx]，idx = 6
#   布局：两个常量缓冲各 16 个 vec4，第 i 个的 x = 0xC7000000 + i / 0xC1000000 + i（按位）；P 64 字节 = [6, 0xBBBB0001, …]；界长表 gal_ubo_len[4] = 4（游戏只绑了 64 字节）、其余 0；
#     spvBufferSizeConstants[P 的 [[id]]] = 16（字节：idx + rt 3 个）
#   期望（手算）：MSL 有成员 gal_ubo_len 且只读 [4u]（槽，不是绑定号 9）；有 spvBufferSizeConstants[P 的 id]；
#     加固 o[0] = 0xC7000003（钳到第 4 个 vec4）、o[1] = 0xC1000006（c1 不钳）、o[2] = rt[2] = 0xBBBB0003；反证不加固 o[0] = 0xC7000006、o[2] = 0xBBBB0007
#   宿主侧的文本约定（表长一致、反射认 ubolen / sbsize / tblead、encode_args 填表）在 tests/dsh_harden_contract_test.sh：只看源码、几秒跑完，本单测只依赖 libdsx 与翻译器
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/dsh_harden.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
command -v glslangValidator > /dev/null || { echo "✗ dsh_harden：没有 glslangValidator"; exit 2; }
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
D=$H/graphics/tools/direct/dsh
cat > "$T/k.comp" <<'EOF'
#version 450
layout(local_size_x = 1) in;
layout(std430, set = 0, binding = 0) buffer A { uint a[4]; };
layout(std430, set = 0, binding = 1) buffer O { uint o[4]; };
layout(std430, set = 0, binding = 2) readonly buffer P { uint idx; uint n; };
void main() {
    o[0] = a[idx];
    a[idx] = 77u;
    o[2] = atomicAdd(a[idx], 5u);
    uint c = 0u; for (uint i = 0u; i < n; i++) c++;
    o[1] = c;
}
EOF
glslangValidator -V -S comp "$T/k.comp" -o "$T/k.spv" > "$T/gv.log" 2>&1 || { echo "✗ glslangValidator 失败：$(tail -2 "$T/gv.log")"; exit 1; }
make -s -C "$H/graphics/dsx" "$H/build/dsx/libdsx.dylib" > "$T/mk.log" 2>&1 || { echo "✗ libdsx 编不过：$(tail -2 "$T/mk.log")"; exit 1; }
python3 - "$H" "$T" <<'PY' || exit 1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
t = sys.argv[2]; spv = open(os.path.join(t, 'k.spv'), 'rb').read().hex()
r = dshfn.batch([('msl_raw', [spv]), ('msl_hardened', [spv])], dsx=os.path.join(sys.argv[1], 'build/dsx/libdsx.dylib'))
for nm, x in zip(('raw', 'hard'), r):
    if 'ok' not in x: sys.exit(f'✗ {nm} 出 MSL 失败：{x}')
    open(os.path.join(t, nm + '.metal'), 'w').write(x['ok'])
PY
cat > "$T/run.m" <<'EOF'
#import <Metal/Metal.h>
#include <stdio.h>
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("编不过：%s\n", e.description.UTF8String); return 2; }
    id<MTLFunction> f = [lib newFunctionWithName:@"main0"]; id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:f error:&e];
    if (!ps) { printf("管线：%s\n", e.description.UTF8String); return 2; }
    id<MTLBuffer> a = [d newBufferWithLength:64 options:MTLResourceStorageModeShared], o = [d newBufferWithLength:16 options:MTLResourceStorageModeShared], p = [d newBufferWithLength:8 options:MTLResourceStorageModeShared];
    uint32_t *A = a.contents; for (int i = 0; i < 16; i++) A[i] = i < 4 ? 10 + i : 0xAAAA0000u + i;
    memset(o.contents, 0xff, 16); ((uint32_t *)p.contents)[0] = 6; ((uint32_t *)p.contents)[1] = 1u << 24;
    id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:0]; id<MTLBuffer> ab = [d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:ab offset:0]; [ae setBuffer:a offset:0 atIndex:atoi(argv[2])]; [ae setBuffer:o offset:0 atIndex:atoi(argv[3])]; [ae setBuffer:p offset:0 atIndex:atoi(argv[4])];   // 参数块成员 id：SPIRV-Cross 按出现顺序给，不按 binding
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:ab offset:0 atIndex:0];
    [ce useResource:a usage:MTLResourceUsageRead | MTLResourceUsageWrite]; [ce useResource:o usage:MTLResourceUsageWrite]; [ce useResource:p usage:MTLResourceUsageRead];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { printf("GPU 错误：%s\n", cb.error.description.UTF8String); return 3; }
    uint32_t *O = o.contents; int sent = 1; for (int i = 4; i < 16; i++) sent &= A[i] == 0xAAAA0000u + i;
    printf("%u %u %u %d %u\n", O[0], O[1], O[2], sent, A[6]);
    return 0;
} }
EOF
xcrun clang -fobjc-arc -framework Metal -framework Foundation "$T/run.m" -o "$T/run" 2> "$T/cc.log" || { echo "✗ 执行器编不过：$(head -3 "$T/cc.log")"; exit 1; }
ids() { for ty in A O P; do sed -n "s/.*device $ty\* m_[0-9]* \[\[id(\([0-9]*\))\]\];.*/\1/p" "$1" | head -1; done | tr '\n' ' '; }
read -r r0 r1 r2 rs r6 <<< "$("$T/run" "$T/raw.metal" $(ids "$T/raw.metal"))"; read -r h0 h1 h2 hs h6 <<< "$("$T/run" "$T/hard.metal" $(ids "$T/hard.metal"))"
ck "加固：越界读钳到末元素 a[3] = 13" 13 "$h0"
ck "加固：越界写 / 原子不落（哨兵 a[4..15] 全不变）" 1 "$hs"
ck "加固：越界原子返回钳到元素 a[3] 的当前值 13" 13 "$h2"
ck "加固：直连不加循环上限，读数据决定的循环照原样跑满 2^24" 16777216 "$h1"
ck "反证（不加固）：越界读到相邻哨兵 0xAAAA0006" $((0xAAAA0006)) "$r0"
ck "反证（不加固）：越界写 + 原子穿进 a[6] = 82" 82 "$r6"
# ---- 第二支：直连界长表按 NVN 槽 ----
# 审计 #1646 P1-65 起统一缓冲界长表在参数循环后填（要先知道各槽指针后实际有多少字节），存储缓冲表照旧当场填：三处都在才算接上
cat > "$T/u.comp" <<'EOF'
#version 450
layout(local_size_x = 1) in;
layout(std140, set = 0, binding = 9) uniform U7 { vec4 data[4096]; } cp_c7;
layout(std140, set = 0, binding = 2) uniform U1 { vec4 data[4096]; } cp_c1;
layout(std430, set = 0, binding = 0) buffer O { uint o[4]; };
layout(std430, set = 0, binding = 1) readonly buffer P { uint idx; uint rt[]; };
void main() {
    o[0] = floatBitsToUint(cp_c7.data[idx].x);
    o[1] = floatBitsToUint(cp_c1.data[idx].x);
    o[2] = rt[idx];
}
EOF
glslangValidator -V -S comp "$T/u.comp" -o "$T/u.spv" > "$T/gv2.log" 2>&1 || { echo "✗ glslangValidator 失败（第二支）：$(tail -2 "$T/gv2.log")"; exit 1; }
python3 - "$H" "$T" <<'PY' || exit 1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
t = sys.argv[2]; spv = open(os.path.join(t, 'u.spv'), 'rb').read().hex()
r = dshfn.batch([('msl_raw', [spv]), ('msl_hardened', [spv])], dsx=os.path.join(sys.argv[1], 'build/dsx/libdsx.dylib'))
for nm, x in zip(('uraw', 'uhard'), r):
    if 'ok' not in x: sys.exit(f'✗ {nm} 出 MSL 失败：{x}')
    open(os.path.join(t, nm + '.metal'), 'w').write(x['ok'])
PY
cat > "$T/urun.m" <<'EOF'
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
// argv: metal c7 c1 O P ulen sizes（参数块成员 id，-1 = 没有该成员）
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil; int id_[6]; for (int i = 0; i < 6; i++) id_[i] = atoi(argv[2 + i]);
    NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("编不过：%s\n", e.description.UTF8String); return 2; }
    id<MTLFunction> f = [lib newFunctionWithName:@"main0"]; id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:f error:&e];
    if (!ps) { printf("管线：%s\n", e.description.UTF8String); return 2; }
    id<MTLBuffer> c7 = [d newBufferWithLength:256 options:MTLResourceStorageModeShared], c1 = [d newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> o = [d newBufferWithLength:16 options:MTLResourceStorageModeShared], p = [d newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> ul = [d newBufferWithLength:64 options:MTLResourceStorageModeShared], sz = [d newBufferWithLength:256 options:MTLResourceStorageModeShared];
    uint32_t *C7 = c7.contents, *C1 = c1.contents, *P = p.contents, *U = ul.contents, *Z = sz.contents;
    for (int i = 0; i < 16; i++) { C7[4 * i] = 0xC7000000u + i; C1[4 * i] = 0xC1000000u + i; P[i] = 0xBBBB0000u + i; }
    P[0] = 6; memset(o.contents, 0xff, 16); memset(U, 0, 64); U[4] = 4; memset(Z, 0, 256); if (id_[3] >= 0) Z[id_[3]] = 16;
    id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:0]; id<MTLBuffer> ab = [d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:ab offset:0]; id<MTLBuffer> bs[6] = { c7, c1, o, p, ul, sz };
    for (int i = 0; i < 6; i++) if (id_[i] >= 0) [ae setBuffer:bs[i] offset:0 atIndex:id_[i]];
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:ab offset:0 atIndex:0]; [ce setBuffer:sz offset:0 atIndex:25];   // 25：SPIRV-Cross 入口里不读的那份长度表参数
    for (int i = 0; i < 6; i++) [ce useResource:bs[i] usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { printf("GPU 错误：%s\n", cb.error.description.UTF8String); return 3; }
    uint32_t *O = o.contents; printf("%u %u %u\n", O[0], O[1], O[2]);
    return 0;
} }
EOF
xcrun clang -fobjc-arc -framework Metal -framework Foundation "$T/urun.m" -o "$T/urun" 2> "$T/cc2.log" || { echo "✗ 执行器编不过（第二支）：$(head -3 "$T/cc2.log")"; exit 1; }
mid() { local v; v=$(sed -n "s/.*[ *]$2 \[\[id(\([0-9]*\))\]\];.*/\1/p" "$1" | head -1); echo "${v:--1}"; }
tid() { local v; v=$(sed -n "s/.*device $2\* m_[0-9]* \[\[id(\([0-9]*\))\]\];.*/\1/p" "$1" | head -1); echo "${v:--1}"; }
uargs() { echo "$(mid "$1" cp_c7) $(mid "$1" cp_c1) $(tid "$1" O) $(tid "$1" P) $(mid "$1" gal_ubo_len) $(mid "$1" spvBufferSizeConstants)"; }
UH=$T/uhard.metal; PI=$(tid "$UH" P)
ck "直连：参数块有成员 gal_ubo_len" 1 "$([ "$(mid "$UH" gal_ubo_len)" -ge 0 ] && echo 1 || echo 0)"
ck "直连：界长表只按 NVN 槽读 [4u]（不按绑定号 9）" "4u" "$(grep -o 'gal_ubo_len)\._m0\[[0-9]*u\]' "$UH" | sed 's/.*\[\(.*\)\]/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//')"
ck "直连：存储缓冲长度按 P 的 [[id]] 取" 1 "$(grep -c "spvBufferSizeConstants\[$PI\];" "$UH" | awk '{print ($1 > 0)}')"
read -r g0 g1 g2 <<< "$("$T/urun" "$UH" $(uargs "$UH"))"; read -r w0 w1 w2 <<< "$("$T/urun" "$T/uraw.metal" $(uargs "$T/uraw.metal"))"
ck "直连加固：常量缓冲按槽表钳到第 4 个 vec4" $((0xC7000003)) "$g0"
ck "直连加固：c1 不钳" $((0xC1000006)) "$g1"
ck "直连加固：存储缓冲运行时数组按字节数表钳到 rt[2]" $((0xBBBB0003)) "$g2"
ck "反证（不加固）：常量缓冲读到第 7 个 vec4" $((0xC7000006)) "$w0"
ck "反证（不加固）：运行时数组读到 rt[6]" $((0xBBBB0007)) "$w2"
# ---- 第三支：#798 纹素缓冲前导（gal_spvx.c spv_tbias）----
#   一支计算核读纹素缓冲 cp_tb：o[i] = texelFetch(cp_tb, i).x（i < 64），o[64] = textureSize(cp_tb)。
#   布局（同宿主的纹素缓冲前导视图）：池缓冲里纹素缓冲从字节 8 开始（低于 16 的对齐，前导 2 个 R32F），第 i 个 = 100 + i，前 8 字节是 0xDEAD0000；
#   视图从字节 0 开、宽 64 + 2；前导项 gal_tbl_cp_tb 指向值为 2 的一格。
#   期望（手算）：加固后 MSL 有成员 gal_tbl_cp_tb；o[i] = 100 + i（全部 64 个）、o[64] = 64；反证（不加固、同一视图）o[0] 读到前 8 字节（不是 100）、o[64] = 66
cat > "$T/b.comp" <<'GLSL'
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 3) uniform samplerBuffer cp_tb;
layout(std430, set = 0, binding = 0) buffer O { float o[]; };
void main() {
    uint i = gl_GlobalInvocationID.x;
    o[i] = texelFetch(cp_tb, int(i)).x;
    if (i == 0u) o[64] = float(textureSize(cp_tb));
}
GLSL
glslangValidator -V -S comp "$T/b.comp" -o "$T/b.spv" > "$T/gv3.log" 2>&1 || { echo "✗ glslangValidator 失败（第三支）：$(tail -2 "$T/gv3.log")"; exit 1; }
python3 - "$H" "$T" <<'PY' || exit 1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
t = sys.argv[2]; spv = open(os.path.join(t, 'b.spv'), 'rb').read().hex()
r = dshfn.batch([('msl_raw', [spv]), ('msl_hardened', [spv])], dsx=os.path.join(sys.argv[1], 'build/dsx/libdsx.dylib'))
for nm, x in zip(('braw', 'bhard'), r):
    if 'ok' not in x: sys.exit(f'✗ {nm} 出 MSL 失败：{x}')
    open(os.path.join(t, nm + '.metal'), 'w').write(x['ok'])
PY
cat > "$T/brun.m" <<'OBJC'
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
// argv: metal 纹素缓冲 id、O id、gal_tbl_cp_tb id、spvBufferSizeConstants id（-1 = 没有）
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil; int it = atoi(argv[2]), io = atoi(argv[3]), il = atoi(argv[4]), is = atoi(argv[5]);
    NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("编不过：%s\n", e.description.UTF8String); return 2; }
    id<MTLFunction> f = [lib newFunctionWithName:@"main0"]; id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:f error:&e];
    if (!ps) { printf("管线：%s\n", e.description.UTF8String); return 2; }
    id<MTLBuffer> pool = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared], o = [d newBufferWithLength:65 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> lead = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    uint32_t *P = pool.contents; P[0] = 0xDEAD0000u; P[1] = 0xDEAD0001u; float *F = (float *)(P + 2); for (int i = 0; i < 64; i++) F[i] = 100.0f + (float)i;
    ((uint32_t *)lead.contents)[0] = 2;
    id<MTLBuffer> sz = [d newBufferWithLength:256 options:MTLResourceStorageModeShared]; memset(sz.contents, 0, 256); if (io >= 0) ((uint32_t *)sz.contents)[io] = 65 * 4;   // 加固按它夹 o[] 的写
    MTLTextureDescriptor *td = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Float width:66 resourceOptions:pool.resourceOptions usage:MTLTextureUsageShaderRead];
    id<MTLTexture> v = [pool newTextureWithDescriptor:td offset:0 bytesPerRow:272];
    id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:0]; id<MTLBuffer> ab = [d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:ab offset:0]; [ae setTexture:v atIndex:it]; [ae setBuffer:o offset:0 atIndex:io]; if (il >= 0) [ae setBuffer:lead offset:0 atIndex:il]; if (is >= 0) [ae setBuffer:sz offset:0 atIndex:is];
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:ab offset:0 atIndex:0]; [ce setBuffer:sz offset:0 atIndex:25];
    [ce useResource:v usage:MTLResourceUsageRead]; [ce useResource:o usage:MTLResourceUsageWrite]; [ce useResource:lead usage:MTLResourceUsageRead]; [ce useResource:sz usage:MTLResourceUsageRead];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { printf("GPU 错误：%s\n", cb.error.description.UTF8String); return 3; }
    float *O = o.contents; int ok = 1; for (int i = 0; i < 64; i++) ok &= O[i] == 100.0f + (float)i;
    printf("%d %g %g\n", ok, O[0], O[64]);
    return 0;
} }
OBJC
xcrun clang -fobjc-arc -framework Metal -framework Foundation "$T/brun.m" -o "$T/brun" 2> "$T/cc3.log" || { echo "✗ 执行器编不过（第三支）：$(head -3 "$T/cc3.log")"; exit 1; }
bargs() { echo "$(mid "$1" cp_tb) $(tid "$1" O) $(mid "$1" gal_tbl_cp_tb) $(mid "$1" spvBufferSizeConstants)"; }
BH=$T/bhard.metal
ck "#798 前导：加固后参数块有成员 gal_tbl_cp_tb" 1 "$([ "$(mid "$BH" gal_tbl_cp_tb)" -ge 0 ] && echo 1 || echo 0)"
ck "#798 前导：不加固没有该成员" -1 "$(mid "$T/braw.metal" gal_tbl_cp_tb)"
read -r bok b0 bw <<< "$("$T/brun" "$BH" $(bargs "$BH"))"; read -r rok r0b rwb <<< "$("$T/brun" "$T/braw.metal" $(bargs "$T/braw.metal"))"
ck "#798 前导：取数下标挪前导，64 个全对（o[i] = 100 + i）" 1 "$bok"
ck "#798 前导：textureSize 减前导 = 64" 64 "$bw"
ck "反证（不加固、同一视图）：o[0] 不是 100（读到对齐边界前的字节）" 1 "$([ "$r0b" != 100 ] && echo 1 || echo 0)"
ck "反证（不加固）：textureSize = 视图宽 66" 66 "$rwb"
[ $bad = 0 ] && echo "dsh_harden：全过" || echo "dsh_harden：有失败"; exit $bad
