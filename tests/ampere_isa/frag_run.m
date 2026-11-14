// tests/ampere_isa 的 GPU 执行器：编一支翻译出的片元 MSL（入口 main0），画 1 个像素到 RGBA32Uint 目标，打印目标 0 的 4 个 32 位字（十六进制）。
// 顶点由本执行器自带（一个盖住像素中心的三角形）；片元的缓冲槽 0..29 都绑同一块 64 KB 缓冲，开头是输入字（命令行给的十六进制字，其余为 0）：
//   用例从常量缓冲 c[3] 读输入，翻译后它落在哪个槽都读到同一份（输入不能写成立即数：翻译器会把常量运算在 C# 里折掉，GPU 上就没测到发射出的运算）。
//   参数缓冲（SPIRV-Cross 的 spvDescriptorSetBufferN，翻译出的常量缓冲在里面）：-a 槽:成员号:种类 逐项给，in = 那块输入缓冲的 GPU 地址，
//   len = 常量缓冲界长表（gal_ubo_len：每个统一缓冲槽可读的 vec4 个数，填满 4096，即整块 64 KB），sup = 支持缓冲（render_scale / render_scale_y 全 1，同宿主 support_buf），
//   samp = 一个最近点采样器，tex = -T 给的贴图（一维 TLD.LZ 的被读物，见下）。
//   -T <形式>:<元素数 n>：n 个 R32Float（第 i 个 = i + 1），缓冲之后再放 65536 个 999.0（读到它 = 读到缓冲之外）。形式：exact = 宿主给 Ampere 折行读的精确行（nvn_tbuf_rows_exact），
//   fixed = 16384 列的固定行（nvn_tbuf_rows，合并后到 11-04 的形式），tex1d = 一张真一维纹理（n × 1 的 2D，宿主把一维纹理按 2D 绑的形式）；
//   tex2d = 一张 n × n 的 RGBA32Float 二维纹理，纹素 (x, y) = (x + 1, y · n + x + 1, y + 1, 1)（四偏移 gather、二维 TLD 的被读物）
//   槽 30 是翻译出的 alpha 测试参考值（s2a_aref），绑零；函数常量都不定义（不开 alpha 测试 / 采样掩码）。
//   -P 项号:客体起点（十六进制）:提示（0/1）：原始全局内存（地址从内存读来，翻译器追不到存储缓冲，GlobalToStorage.TryGenerateRawStorageOp）的池表与两个池。
//   池表照宿主 nvn_mtl.m gmem_map 的格式：8192 项 × 32 字节 {起点, 终点, 差值 = 池的 GPU 地址 − 客体地址, 提示字, 0}，按起点升序，第 0 项空，空项起点 ~0；
//   第 1..项号−1 项是起点 0x1000·j、16 字节的小区间（垫位，把两个池推到项号处），池 A = 第「项号」项 [起点, 起点 + 4 MiB)（字 i = 0xa0000000 | i），
//   池 B = 下一项，紧接 A（字 i = 0xb0000000 | i）；提示 1 时每个整块落在池里的 2 MiB 块 c 在第 c mod 8192 项写 c << 13 | 项号。
//   成员种类 map = 池表、log = 写记录（256 个字的位图，清零）、sz = 存储缓冲字节数表（全给 1 GB：不钳）；输出行在 4 个字后再打写记录里 A、B 两项所在的字
//   -P 项号:起点:提示:1（按需常驻，nvn_mtl.m gmem_map 11-06）：第 0 项差值字 = 访问位图（清零）的 GPU 地址；A 常驻、要记（字 7 = 5 + 1：位 5），
//   B 不常驻（终点 = 起点、差值字 = 真终点、字 7 = 9 + 1：位 9），A、B 在宿主上是同一块缓冲的前后两半；输出行再多打两个字：访问位图第 0 个字、B 第 16 个字（偏移 0x40）
// 批量（11-13）：frag_run --batch 从标准输入逐行读用例（一行 = 上面的参数，制表符分隔），每例输出一行「ok<TAB>字…」或「err<TAB>退出码<TAB>原因」。
//   一个进程、一个 Metal 设备跑完全部用例：每个用 Metal 的进程退出时，macOS 26.4.1 的驱动会永久漏掉 1 个 IOSurface 客户名额（1020 个用完后本机所有 Metal 程序起不来，
//   只能重启），原先每例起一个进程，跑一遍 196 例就漏 173 个
// 用法：frag_run <片元 MSL> [-a 槽:成员号:in|len|sup|samp|tex|map|log|sz …] [-T 形式:元素数] [-P 项号:起点:提示[:1]] [输入字（十六进制）…]
#import <Metal/Metal.h>
#include <stdio.h>
#include "nvn_tex.h"

static const char *VS = "#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 s2a_vs(uint v [[vertex_id]]) { float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) }; return float4(p[v], 0, 1); }\n";

#define ERRF(...) snprintf(err, errn, __VA_ARGS__)
// 一例：argv[1] = 片元 MSL，其余同命令行；结果写进 out（一行四到八个十六进制字），出错写进 err 并返回非 0
static int run_case(id<MTLDevice> dev, id<MTLCommandQueue> cq, int argc, char **argv, char *out, size_t outn, char *err, size_t errn) {
    @autoreleasepool {
        NSError *e = nil;
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&e];
        MTLCompileOptions *o = [MTLCompileOptions new]; o.preserveInvariance = YES; o.mathMode = MTLMathModeRelaxed;   // 同载入端（nvn_mtl.m dm_msl_opts）与离线出库（batch/Build.cs -fmetal-math-mode=relaxed）；缺省的 fast 冲刷非规格化数，与真机不同
        id<MTLLibrary> fl = [@(argv[1]) hasSuffix:@".metallib"] ? [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e] : src ? [dev newLibraryWithSource:src options:o error:&e] : nil;
        if (!fl) { ERRF("【红】片元 MSL 编不过：%s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLLibrary> vl = [dev newLibraryWithSource:@(VS) options:nil error:&e];
        id<MTLFunction> ff = [fl newFunctionWithName:@"main0" constantValues:[MTLFunctionConstantValues new] error:&e], vf = [vl newFunctionWithName:@"s2a_vs"];
        if (!ff || !vf) { ERRF("【红】取不到入口\n"); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf; pd.fragmentFunction = ff; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!ps) { ERRF("【红】管线建不了：%s\n", e.localizedDescription.UTF8String); return 1; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> in = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared], zero = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLBuffer> lens = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        for (int i = 0; i < 64; i++) ((uint32_t *)lens.contents)[i] = 4096;
        id<MTLBuffer> args[30] = { nil };
        int nin = 0;
        id<MTLBuffer> sup = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        for (int i = 0; i < 73; i++) { ((float *)((uint8_t *)sup.contents + 192 + 16 * i))[0] = 1.0f; ((float *)((uint8_t *)sup.contents + 1440 + 16 * i))[0] = 1.0f; }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.supportArgumentBuffers = YES; id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        id<MTLTexture> tex = nil; id<MTLBuffer> tbuf = nil;
        id<MTLBuffer> gmap = nil, glog = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared], gsz = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared], gpool[2] = { nil, nil }; uint64_t goff[2] = { 0, 0 };
        for (int i = 0; i < 64; i++) ((uint32_t *)gsz.contents)[i] = 1u << 30;
        unsigned pk = 0, lazy = 0; id<MTLBuffer> gbits = nil;
        for (int i = 2; i + 1 < argc; i++) if (!strcmp(argv[i], "-P")) {
            unsigned long long g; unsigned hint;
            if (sscanf(argv[i + 1], "%u:%llx:%u:%u", &pk, &g, &hint, &lazy) < 3 || pk < 1 || pk + 1 >= 8192 || (uint64_t)pk * 0x1000 + 16 > g) { ERRF("【红】-P %s 不认得\n", argv[i + 1]); return 2; }
            enum { PS = 4 << 20 };
            gmap = [dev newBufferWithLength:8192 * 32 options:MTLResourceStorageModeShared];
            uint8_t *t = gmap.contents; memset(t, 0, 8192 * 32); for (int k = 1; k < 8192; k++) memset(t + k * 32, 0xff, 8);
            // 按需常驻时 A、B 在宿主上是同一块缓冲的前后两半（goff）：拿 A 的差值去读 B 的客体地址会读到 B 的字，不是 0——借错差值的实现读不出 0（11-07 区间缓存负对照）
            if (lazy) { gpool[0] = gpool[1] = [dev newBufferWithLength:2 * PS options:MTLResourceStorageModeShared]; goff[1] = PS; }
            for (int p = 0; p < 2; p++) { if (!lazy) gpool[p] = [dev newBufferWithLength:PS options:MTLResourceStorageModeShared]; uint32_t *w = (uint32_t *)((uint8_t *)gpool[p].contents + goff[p]); for (int k = 0; k < PS / 4; k++) w[k] = (p ? 0xb0000000u : 0xa0000000u) | (uint32_t)k; }
            for (unsigned k = 1; k < pk; k++) { uint64_t e[3] = { (uint64_t)k * 0x1000, (uint64_t)k * 0x1000 + 16, gpool[0].gpuAddress + goff[0] - g }; memcpy(t + k * 32, e, sizeof e); }
            for (int p = 0; p < 2; p++) { uint64_t s0 = g + (uint64_t)p * PS, e[3] = { s0, s0 + PS, gpool[p].gpuAddress + goff[p] - s0 }; memcpy(t + (pk + p) * 32, e, sizeof e);
                if (hint) for (uint64_t c = (s0 + (1u << 21) - 1) >> 21; c < (s0 + PS) >> 21 && c < (1u << 19); c++) { uint32_t h = (uint32_t)(c << 13 | (pk + p)); memcpy(t + (c % 8192) * 32 + 24, &h, 4); } }
            if (lazy) {
                gbits = [dev newBufferWithLength:8192 options:MTLResourceStorageModeShared]; uint64_t ba = gbits.gpuAddress; memcpy(t + 16, &ba, 8);
                uint32_t sa = 5 + 1, sb = 9 + 1; memcpy(t + pk * 32 + 28, &sa, 4); memcpy(t + (pk + 1) * 32 + 28, &sb, 4);
                uint64_t *eb = (uint64_t *)(t + (pk + 1) * 32); eb[2] = eb[1]; eb[1] = eb[0];   // B：终点 = 起点，真终点进差值字
            }
            i++;
        }
        for (int i = 2; i + 1 < argc; i++) if (!strcmp(argv[i], "-T")) {
            char mode[16]; unsigned long long n; if (sscanf(argv[i + 1], "%15[a-z0-9]:%llu", mode, &n) != 2 || !n) { ERRF("【红】-T %s 不认得\n", argv[i + 1]); return 2; }
            if (!strcmp(mode, "tex2d")) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:n height:n mipmapped:NO];
                td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared; tex = [dev newTextureWithDescriptor:td];
                float *px = calloc(n * n * 4, sizeof(float));
                for (unsigned long long y = 0; y < n; y++) for (unsigned long long x = 0; x < n; x++) { float *q = px + 4 * (y * n + x); q[0] = x + 1; q[1] = y * n + x + 1; q[2] = y + 1; q[3] = 1; }
                [tex replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:0 withBytes:px bytesPerRow:n * 16]; free(px);
                i++; continue;
            }
            NSUInteger al = [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Float]; uint32_t w = (uint32_t)n, h = 1, row = (uint32_t)((n * 4 + al - 1) / al * al);
            int ok = !strcmp(mode, "exact") ? nvn_tbuf_rows_exact(n, 4, (uint32_t)al, &w, &h, &row) : !strcmp(mode, "fixed") ? nvn_tbuf_rows(n, 4, (uint32_t)al, &w, &h, &row) : !strcmp(mode, "tex1d");
            if (!ok) { ERRF("【红】%s 形式放不下 %llu 个元素\n", mode, n); return 2; }
            size_t total = (size_t)row * h + 65536 * 4;
            tbuf = [dev newBufferWithLength:total options:MTLResourceStorageModeShared];
            float *p = tbuf.contents; for (size_t k = 0; k < total / 4; k++) p[k] = k < n ? (float)(k + 1) : 999.0f;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:w height:h mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            if (!strcmp(mode, "tex1d")) { td.storageMode = MTLStorageModeShared; tex = [dev newTextureWithDescriptor:td]; [tex replaceRegion:MTLRegionMake2D(0, 0, w, 1) mipmapLevel:0 withBytes:p bytesPerRow:n * 4]; }
            else { td.resourceOptions = tbuf.resourceOptions; tex = [tbuf newTextureWithDescriptor:td offset:0 bytesPerRow:row]; }   // 同 nvn_mtl.m tbuf_as_2d
            if (!tex) { ERRF("【红】建不了贴图\n"); return 1; }
            i++;
        }
        for (int i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "-a") && i + 1 < argc) {
                int slot, id; char kind[8];
                if (sscanf(argv[++i], "%d:%d:%7s", &slot, &id, kind) != 3 || slot < 0 || slot >= 30 || id < 0 || id >= 64) { ERRF("【红】-a %s 不认得\n", argv[i]); return 2; }
                if (!args[slot]) args[slot] = [dev newBufferWithLength:64 * 8 options:MTLResourceStorageModeShared];
                uint64_t *e = &((uint64_t *)args[slot].contents)[id];
                if (!strcmp(kind, "tex")) { if (!tex) { ERRF("【红】着色器读贴图，没给 -T\n"); return 2; } *e = tex.gpuResourceID._impl; }
                else if (!strcmp(kind, "samp")) *e = smp.gpuResourceID._impl;
                else if (!strcmp(kind, "map")) { if (!gmap) { ERRF("【红】着色器有原始池表，没给 -P\n"); return 2; } *e = gmap.gpuAddress; }
                else if (!strcmp(kind, "log")) *e = glog.gpuAddress;
                else if (!strcmp(kind, "sz")) *e = gsz.gpuAddress;
                else *e = (!strcmp(kind, "len") ? lens : !strcmp(kind, "sup") ? sup : in).gpuAddress;
            } else if (!strcmp(argv[i], "-T") || !strcmp(argv[i], "-P")) i++;
            else if (nin < 16384) ((uint32_t *)in.contents)[nin++] = (uint32_t)strtoul(argv[i], NULL, 16);
        }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLCommandBuffer> cb = [cq commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        for (int i = 0; i < 30; i++) [re setFragmentBuffer:args[i] ?: in offset:0 atIndex:i];
        [re useResource:in usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; [re useResource:lens usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [re useResource:sup usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; if (tex) [re useResource:tex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        if (gmap) { [re useResource:gmap usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; [re useResource:glog usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:MTLRenderStageFragment];
            [re useResource:gsz usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            for (int p = 0; p < 2; p++) [re useResource:gpool[p] usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:MTLRenderStageFragment];
            if (gbits) [re useResource:gbits usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:MTLRenderStageFragment]; }
        [re setFragmentBuffer:zero offset:0 atIndex:30];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { ERRF("【红】GPU 执行失败：%s\n", cb.error.localizedDescription.UTF8String); return 1; }
        uint32_t px[4] = { 0 };
        [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        if (gbits) { const uint32_t *lw = glog.contents; snprintf(out, outn, "%08x %08x %08x %08x %08x %08x %08x %08x\n", px[0], px[1], px[2], px[3], lw[pk >> 5], lw[(pk + 1) >> 5], ((uint32_t *)gbits.contents)[0], ((uint32_t *)((uint8_t *)gpool[1].contents + goff[1]))[16]); }
        else if (gmap) { const uint32_t *lw = glog.contents; snprintf(out, outn, "%08x %08x %08x %08x %08x %08x\n", px[0], px[1], px[2], px[3], lw[pk >> 5], lw[(pk + 1) >> 5]); }
        else snprintf(out, outn, "%08x %08x %08x %08x\n", px[0], px[1], px[2], px[3]);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法：frag_run <片元 MSL> [-a 槽:成员号:in|len …] [输入字…]；frag_run --batch < 用例行\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> cq = [dev newCommandQueue];
    if (!dev || !cq) { fprintf(stderr, "【红】没有 Metal 设备\n"); return 1; }
    static char out[512], err[1024];
    if (strcmp(argv[1], "--batch")) {
        out[0] = err[0] = 0; int rc = run_case(dev, cq, argc, argv, out, sizeof out, err, sizeof err);
        if (rc) fputs(err, stderr); else fputs(out, stdout);
        return rc;
    }
    char *line = NULL; size_t cap = 0; ssize_t n;
    while ((n = getline(&line, &cap, stdin)) > 0) {
        if (line[n - 1] == '\n') line[--n] = 0;
        if (!n) continue;
        char *av[256]; int ac = 0; av[ac++] = argv[0];
        for (char *t = line, *tok; ac < 255 && (tok = strsep(&t, "\t")); ) if (*tok) av[ac++] = tok;
        av[ac] = NULL; out[0] = err[0] = 0;
        int rc = ac < 2 ? (snprintf(err, sizeof err, "空用例"), 2) : run_case(dev, cq, ac, av, out, sizeof out, err, sizeof err);
        if (rc) { for (char *c = err; *c; c++) if (*c == '\n' || *c == '\t') *c = ' '; printf("err\t%d\t%s\n", rc, err); }
        else { out[strcspn(out, "\n")] = 0; printf("ok\t%s\n", out); }
        fflush(stdout);
    }
    free(line);
    return 0;
}
