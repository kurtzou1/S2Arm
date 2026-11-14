// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Depth16 清除值与绘制深度同值（depth_clear_value，11-06 王国之泪：分块光照先把 Depth16 清成 0.5、有灯的块画四边形写深度，再按 EQUAL 画各光照着色器的块；
//   留在清除值的块要和 z = 0.5 的那遍相等。苹果 GPU 光栅深度按最近舍入、清除值截断，0.5 → 32767 对 32768，EQUAL 全不过，这些块全黑）。
// 期望不跑被测实现就能算：NVN / Vulkan 把清除值与光栅深度按同一规则转定点，所以「清成 z、在 z 处按 EQUAL 画」每个像素都过。
//   ① Depth16Unorm：z = k / 65535（k = 0 … 65535，全部 16 位台阶）与台阶中点 (k + 0.5) / 65535（k ≡ 1 mod 3 的那些，含舍入平局）共 65536 + 21845 个，全过
//   ② Depth32Float：同一批 z 全过（换算对它是原值）
// 反证：depth_clear_value 原样返回 z（= 改前）→ ① 约一半 z 不过（红）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 tri(uint i [[vertex_id]], constant float &z [[buffer(0)]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],z,1); }\n"
"fragment float4 one() { return float4(1); }\n";

// 清成 depth_clear_value(f, z)、在 z 处按 EQUAL 画 4×4：返回过了的像素数。每个 z 仍是自己的渲染遍、自己的清除值（同改前），
//   只是一批 NB（2048）个 z 编进同一个命令缓冲、各占 4×4 数组贴图的一层，提交一次、等一次、逐层读回（11-14：原先每个 z 提交并等一次，87381 次同步约 14 秒 / 格式）
enum { NB = 2048 };   // 数组贴图层数上限 2048
static void equal_batch(id<MTLRenderPipelineState> ps, id<MTLDepthStencilState> ds, id<MTLTexture> dt, id<MTLTexture> ct, id<MTLCommandQueue> q, const float *z, int n, int *passed) {
    id<MTLCommandBuffer> cb=[q commandBuffer];
    for (int i=0;i<n;i++) { @autoreleasepool {
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=ct; rp.colorAttachments[0].slice=(NSUInteger)i; rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0); rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        rp.depthAttachment.texture=dt; rp.depthAttachment.slice=(NSUInteger)i; rp.depthAttachment.loadAction=MTLLoadActionClear; rp.depthAttachment.clearDepth=depth_clear_value(dt.pixelFormat,z[i]); rp.depthAttachment.storeAction=MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:ps]; [en setDepthStencilState:ds]; [en setVertexBytes:&z[i] length:4 atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    } }
    [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    for (int i=0;i<n;i++) { uint8_t px[16]; [ct getBytes:px bytesPerRow:4 bytesPerImage:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 slice:(NSUInteger)i]; int c=0; for (int k=0;k<16;k++) c+=px[k]>0; passed[i]=c; }
}

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); REQUIRE(dev); id<MTLCommandQueue> q=[dev newCommandQueue];
    NSError *error=nil; id<MTLLibrary> lib=[dev newLibraryWithSource:source options:nil error:&error]; if (!lib) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new]; dd.depthCompareFunction=MTLCompareFunctionEqual; dd.depthWriteEnabled=NO; id<MTLDepthStencilState> ds=[dev newDepthStencilStateWithDescriptor:dd]; REQUIRE(ds);
    MTLTextureDescriptor *cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:4 height:4 mipmapped:NO]; cd.textureType=MTLTextureType2DArray; cd.arrayLength=NB; cd.usage=MTLTextureUsageRenderTarget; cd.storageMode=MTLStorageModeShared;
    id<MTLTexture> ct=[dev newTextureWithDescriptor:cd]; REQUIRE(ct);
    const MTLPixelFormat fmts[2]={MTLPixelFormatDepth16Unorm,MTLPixelFormatDepth32Float}; const char *names[2]={"Depth16Unorm","Depth32Float"};
    for (int fi=0;fi<2;fi++) {
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmts[fi] width:4 height:4 mipmapped:NO]; td.textureType=MTLTextureType2DArray; td.arrayLength=NB; td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate;
        id<MTLTexture> dt=[dev newTextureWithDescriptor:td]; REQUIRE(dt);
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"tri"]; pd.fragmentFunction=[lib newFunctionWithName:@"one"];
        pd.colorAttachments[0].pixelFormat=MTLPixelFormatR8Unorm; pd.depthAttachmentPixelFormat=fmts[fi];
        id<MTLRenderPipelineState> ps=[dev newRenderPipelineStateWithDescriptor:pd error:&error]; REQUIRE(ps);
        int tot=0, bad=0, n=0; float first=-1; static float zs[NB]; static int got[NB];
        for (int k=0;k<=65535;k++) for (int h=0;h<(k%3==1?2:1);h++) {
            zs[n++]=fminf(1.0f,((float)k+(h?0.5f:0.0f))/65535.0f); tot++;
            int last=k==65535 && h==(k%3==1?1:0);
            if (n==NB || last) { equal_batch(ps,ds,dt,ct,q,zs,n,got); for (int i=0;i<n;i++) if (got[i]!=16) { if (first<0) first=zs[i]; bad++; } n=0; } }
        CHECK(bad==0,"%s %s：清成 z、在 z 处按 EQUAL 画，%d 个 z 里不全过 %d 个（期望 0；第一个 %.9g）",fi?"②":"①",names[fi],tot,bad,first);
    }
} printf("%s t_nvn_d16clear：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
