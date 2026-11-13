// 无 BC 显卡上 BC1–5、BC6H 与 BC7 的 GPU 解压核 bcd（graphics/nvn/gfx/tex/nvn_bcd_msl.h）单测：真值 = CPU 端 bcdec（nvn_bcdec.c，独立实现、无 BC 显卡的 CPU 路径就用它）。
// 每种格式（BC1 / BC2 / BC3 / BC4 / BC4 有符号 / BC5 / BC5 有符号）一张 13×10 贴图（右、下边是不满 4×4 的块），块内容 = 固定种子随机 + 几个特殊块
// （BC1 三色带透明模式 c0 ≤ c1、BC4 六值模式 a0 ≤ a1、有符号端点 -128），GPU 解进解压格式贴图读回，逐纹素逐通道比：
// 期望每通道差 ≤ 1 级（核按浮点插值、写贴图时舍入，bcdec 按整数近似；差 1 级是两种舍入的固有差，差 2 级以上就是解错了），且解出的纹素数 = 13 × 10。
// BC7（S2Arm #582）：核按 bcdec 的整数运算移植，要求逐纹素完全相等；61×37 一张（16×10 块，右、下边不满），第 i 块的模式强制成 i % 9（模式 0–7 + 保留模式），
// 其余位随机，分区号、旋转、索引选择位都随之打散；sRGB 版（0x4e）照上传路径经 RGBA8Unorm 视图写进 sRGB 贴图，读回的原始值也要与 bcdec 相等。
// BC6H 无 / 有符号（0x50 / 0x4f）：同样 61×37，第 i 块的模式码轮流取 14 个有效码 + 4 个保留码，每 5 块把端点位清成接近 0（出非规格化半精度），
// 读回 RGBA16Float 的半精度位要与 bcdec 逐位相等（容差 0；表里 ch 是每纹素字节数）。
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../gfx/tex/nvn_bcd_msl.h"
#include "../gfx/tex/nvn_bcdec.h"

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("t_bcd_gpu: 没有 Metal 设备\n"); return 1; }
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_bcd_msl) options:nil error:&e];
        id<MTLComputePipelineState> ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bcd"] error:&e] : nil;
        if (!ps) { printf("t_bcd_gpu: 解压核建不出：%s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const struct { uint32_t nvn, kf, bb, ch; int sn; MTLPixelFormat pf; const char *name; uint32_t W, H; int tol; } F[] = {
            {0x42, 1, 8, 4, 0, MTLPixelFormatRGBA8Unorm, "BC1", 13, 10, 1}, {0x43, 2, 16, 4, 0, MTLPixelFormatRGBA8Unorm, "BC2", 13, 10, 1}, {0x44, 3, 16, 4, 0, MTLPixelFormatRGBA8Unorm, "BC3", 13, 10, 1},
            {0x49, 4, 8, 1, 0, MTLPixelFormatR8Unorm, "BC4", 13, 10, 1}, {0x4a, 5, 8, 1, 1, MTLPixelFormatR8Snorm, "BC4 有符号", 13, 10, 1},
            {0x4b, 6, 16, 2, 0, MTLPixelFormatRG8Unorm, "BC5", 13, 10, 1}, {0x4c, 7, 16, 2, 1, MTLPixelFormatRG8Snorm, "BC5 有符号", 13, 10, 1},
            {0x4d, 8, 16, 4, 0, MTLPixelFormatRGBA8Unorm, "BC7", 61, 37, 0}, {0x4e, 8, 16, 4, 0, MTLPixelFormatRGBA8Unorm_sRGB, "BC7 sRGB", 61, 37, 0},
            {0x50, 9, 16, 8, 0, MTLPixelFormatRGBA16Float, "BC6H", 61, 37, 0}, {0x4f, 10, 16, 8, 0, MTLPixelFormatRGBA16Float, "BC6H 有符号", 61, 37, 0},
        };
        int bad = 0;
        for (size_t k = 0; k < sizeof F / sizeof F[0]; k++) {
            const uint32_t W = F[k].W, H = F[k].H, BX = (W + 3) / 4, BY = (H + 3) / 4;
            uint32_t pitch = BX * F[k].bb; size_t n = (size_t)pitch * BY; uint8_t *blk = malloc(n);
            srand(1026 + (unsigned)k); for (size_t i = 0; i < n; i++) blk[i] = (uint8_t)(rand() >> 7);
            // 特殊块：第 0 块走少见分支（BC1 c0 ≤ c1 的三色 + 透明；单通道 a0 ≤ a1 的六值 + 0 / 1；有符号端点 -128 夹到 -127）
            if (F[k].kf == 1) { blk[0] = 0x10; blk[1] = 0x20; blk[2] = 0x30; blk[3] = 0x40; }
            if (F[k].kf >= 4) { blk[0] = F[k].sn ? 0x80 : 0x20; blk[1] = 0x70; }
            if (F[k].kf == 3) { blk[0] = 0x20; blk[1] = 0x90; }
            if (F[k].kf == 8) for (size_t i = 0; i < n / 16; i++) { unsigned m = i % 9; blk[i * 16] = m < 8 ? (uint8_t)((blk[i * 16] & (0xfeu << m)) | (1u << m)) : 0; }   // 模式 m = 最低的 1 位
            if (F[k].kf >= 9) for (size_t i = 0; i < n / 16; i++) {   // BC6H：模式码 = 低 2 位（0 / 1）或低 5 位
                static const uint8_t code[18] = {0, 1, 2, 6, 10, 14, 18, 22, 26, 30, 3, 7, 11, 15, 19, 23, 27, 31}; uint8_t c = code[i % 18], *q = blk + i * 16;
                if (i % 5 == 0) memset(q, 0, 9);
                q[0] = c < 2 ? (uint8_t)((q[0] & ~3u) | c) : (uint8_t)((q[0] & ~31u) | c); }
            id<MTLBuffer> src = [dev newBufferWithBytes:blk length:n options:MTLResourceStorageModeShared];
            struct { uint32_t off, pitch, w, h, fmt, z; } p = {0, pitch, W, H, F[k].kf, 0};
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[k].pf width:W height:H mipmapped:NO];
            td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            id<MTLTexture> wv = F[k].pf == MTLPixelFormatRGBA8Unorm_sRGB ? [tex newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm] : tex;   // 上传路径同款：sRGB 贴图经 RGBA8Unorm 视图写原始值
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps]; [ce setBuffer:src offset:0 atIndex:0]; [ce setBytes:&p length:sizeof p atIndex:1]; [ce setTexture:wv atIndex:0];
            [ce dispatchThreadgroups:MTLSizeMake((BX + 7) / 8, (BY + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
            size_t dp = (size_t)W * F[k].ch; uint8_t *gpu = calloc(dp * H, 1), *cpu = calloc(dp * H, 1);
            [tex getBytes:gpu bytesPerRow:dp fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            if (nvn_bc_decode(F[k].nvn, blk, pitch, W, H, cpu, dp)) { printf("✗ %s：bcdec 不认这个格式\n", F[k].name); bad = 1; continue; }
            int mx = 0, nd = 0;
            for (size_t i = 0; i < dp * H; i++) { int a = F[k].sn ? (int8_t)gpu[i] : gpu[i], b = F[k].sn ? (int8_t)cpu[i] : cpu[i], d = abs(a - b); if (d > mx) mx = d; nd += d != 0; }
            int ok = mx <= F[k].tol;
            printf("%s %s：%u×%u 共 %u 个纹素 × %u 字节，与 bcdec 最大差 %d 级（有差的 %d 个，允许 %d 级）\n", ok ? "✓" : "✗", F[k].name, W, H, W * H, F[k].ch, mx, nd, F[k].tol);
            bad |= !ok; free(blk); free(gpu); free(cpu);
        }
        if (bad) printf("✗ t_bcd_gpu：有格式与 bcdec 的差超出允许\n"); else printf("✓ t_bcd_gpu：11 种格式与 bcdec 逐纹素比全过（BC7 / BC6H 完全相等）\n");
        return bad;
    }
}
