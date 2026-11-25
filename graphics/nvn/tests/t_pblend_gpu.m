// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 可编程混合（#674 通用根修，graphics/dsx/gal_colorround.c 的 gal_color_round_pb_msl 门控版）在真 Metal 上跑：maxwell_blend_matrix_test.py 的 pb 实现。
//   输入（Python 写）：魔数 "S2PB"、组数、每组 (6 个 NVN 混合枚举、常量色 float4、格子数 n、n × (源 float4, 第二源 float4, 目标 float4))；
//   每组画一行：附件先填目标值（读入）；片元入口照 SPIRV-Cross 格式写（输出 0 = 源、输出 1 = 第二源），经 gal_color_round_pb_msl 改写，
//   特化时置 s2a_pb0_c = 真（同宿主），按 27 号槽的混合状态自己混合；管线只有附件 0、固定混合关掉，输出 1 不落任何附件（第二源只在片元里用）。
//   输出：每组 n × 结果 float4（附件读回）。附件格式由参数给（rgba32f / rgba16f）。只跑改写后的着色器，不读期望值。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "gal_colorround.h"

typedef struct { uint32_t mask, pad0, pad1, pad2; float k[4]; uint32_t f[8][2][4]; } PBlend;   // 同 k_pblend 的 S2APBlend

static const char *k_frag =
"#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n"
"struct main0_out\n{\n    float4 out_var_SV_Target0 [[color(0)]];\n    float4 out_var_SV_Target1 [[color(1)]];\n};\n\n"
"fragment main0_out main0(float4 gl_FragCoord [[position]], constant float4* src [[buffer(0)]], constant uint& base [[buffer(1)]])\n{\n"
"    main0_out out = {};\n    out.out_var_SV_Target0 = src[2u * (base + uint(gl_FragCoord.x))];\n    out.out_var_SV_Target1 = src[2u * (base + uint(gl_FragCoord.x)) + 1u];\n    return out;\n}\n\n";
static NSString *const k_vert = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 tri(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i], 0, 1); }\n";

static void die(const char *m) { fprintf(stderr, "t_pblend_gpu: %s\n", m); exit(2); }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4) die("用法：t_pblend_gpu <输入> <输出> rgba32f|rgba16f");
        MTLPixelFormat fmt = !strcmp(argv[3], "rgba16f") ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA32Float;
        NSData *in = [NSData dataWithContentsOfFile:@(argv[1])]; if (!in) die("读不到输入");
        const uint8_t *p = in.bytes, *end = p + in.length;
        if (in.length < 8 || memcmp(p, "S2PB", 4)) die("输入魔数不对");
        uint32_t groups; memcpy(&groups, p + 4, 4); p += 8;
        typedef struct { uint32_t st[6]; float k[4]; uint32_t n; const float *cells; } G;
        G *gs = calloc(groups, sizeof *gs); uint32_t width = 1; size_t total = 0;
        for (uint32_t g = 0; g < groups; g++) {
            if (end - p < 44) die("输入截断");
            memcpy(gs[g].st, p, 24); memcpy(gs[g].k, p + 24, 16); memcpy(&gs[g].n, p + 40, 4); p += 44;
            if ((size_t)(end - p) < (size_t)gs[g].n * 48) die("输入截断（格子）");
            gs[g].cells = (const float *)p; p += (size_t)gs[g].n * 48;
            if (gs[g].n > width) width = gs[g].n; total += gs[g].n;
        }
        if (!groups) { [[NSData data] writeToFile:@(argv[2]) atomically:YES]; printf("t_pblend_gpu：0 组\n"); return 0; }
        char why[256] = "";
        char *msl = gal_color_round_pb_msl(k_frag, "main0", why);
        if (!msl) { fprintf(stderr, "改写失败：%s\n", why); return 1; }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) die("没有 Metal 设备");
        MTLCompileOptions *co = [MTLCompileOptions new]; co.mathMode = MTLMathModeRelaxed; co.preserveInvariance = YES;   // 同运行时（nvn_mtl.m）
        NSError *err = nil;
        id<MTLLibrary> fl = [dev newLibraryWithSource:@(msl) options:co error:&err];
        if (!fl) { fprintf(stderr, "片元编不过：%s\n---\n%s\n", err.localizedDescription.UTF8String, msl); return 1; }
        id<MTLLibrary> vl = [dev newLibraryWithSource:k_vert options:co error:&err]; if (!vl) die("顶点编不过");
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; bool on = true;
        [cv setConstantValue:&on type:MTLDataTypeBool withName:@"s2a_pb0_c"];   // 同宿主：附件 0 走可编程混合
        id<MTLFunction> ff = [fl newFunctionWithName:@"main0" constantValues:cv error:&err];
        if (!ff) { fprintf(stderr, "特化失败：%s\n", err.localizedDescription.UTF8String); return 1; }
        pd.vertexFunction = [vl newFunctionWithName:@"tri"]; pd.fragmentFunction = ff;
        pd.colorAttachments[0].pixelFormat = fmt; pd.colorAttachments[0].blendingEnabled = NO;   // 可编程混合：固定混合关掉
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) { fprintf(stderr, "管线建不出：%s\n", err.localizedDescription.UTF8String); return 1; }
        // 目标值：每组一行，先整张填好（附件读入）
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:width height:groups mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        size_t px = fmt == MTLPixelFormatRGBA16Float ? 8 : 16;
        uint8_t *row = calloc(width, px);
        float *src = calloc(total ? total : 1, 32); size_t at = 0;   // 每格：源、第二源
        uint32_t *base = calloc(groups, 4);
        for (uint32_t g = 0; g < groups; g++) {
            base[g] = (uint32_t)at;
            for (uint32_t i = 0; i < gs[g].n; i++) {
                const float *c = gs[g].cells + (size_t)i * 12;
                memcpy(src + (at + i) * 8, c, 32);
                if (px == 16) memcpy(row + i * 16, c + 8, 16);
                else for (int j = 0; j < 4; j++) { __fp16 h = (__fp16)c[8 + j]; memcpy(row + i * 8 + j * 2, &h, 2); }
            }
            at += gs[g].n;
            [tex replaceRegion:MTLRegionMake2D(0, g, width, 1) mipmapLevel:0 withBytes:row bytesPerRow:width * px];
        }
        id<MTLBuffer> sb = [dev newBufferWithBytes:src length:(total ? total : 1) * 32 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionLoad; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps]; [e setFragmentBuffer:sb offset:0 atIndex:0];
        for (uint32_t g = 0; g < groups; g++) {
            if (!gs[g].n) continue;
            PBlend b = {0};
            memcpy(b.k, gs[g].k, 16);
            for (int j = 0; j < 3; j++) { b.f[0][0][j] = gs[g].st[j]; b.f[0][1][j] = gs[g].st[3 + j]; }
            [e setFragmentBytes:&b length:sizeof b atIndex:GAL_COLOR_ROUND_SLOT];
            [e setFragmentBytes:&base[g] length:4 atIndex:1];
            [e setViewport:(MTLViewport){0, g, gs[g].n, 1, 0, 1}];
            [e setScissorRect:(MTLScissorRect){0, g, gs[g].n, 1}];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { fprintf(stderr, "GPU 出错：%s\n", cb.error.localizedDescription.UTF8String); return 1; }
        NSMutableData *out = [NSMutableData dataWithLength:total * 16];
        float *o = out.mutableBytes; at = 0;
        for (uint32_t g = 0; g < groups; g++) {
            [tex getBytes:row bytesPerRow:width * px fromRegion:MTLRegionMake2D(0, g, width, 1) mipmapLevel:0];
            for (uint32_t i = 0; i < gs[g].n; i++) {
                if (px == 16) memcpy(o + (at + i) * 4, row + i * 16, 16);
                else for (int j = 0; j < 4; j++) { __fp16 h; memcpy(&h, row + i * 8 + j * 2, 2); o[(at + i) * 4 + j] = (float)h; }
            }
            at += gs[g].n;
        }
        if (![out writeToFile:@(argv[2]) atomically:YES]) die("写不出输出");
        printf("✓ t_pblend_gpu：%u 组、%zu 格、%s（只出结果；和模型比由 maxwell_blend_matrix_test.py 做）\n", groups, total, argv[3]);
        free(msl);
    }
    return 0;
}
