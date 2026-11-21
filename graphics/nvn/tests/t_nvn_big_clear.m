// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// NVN 的清除覆盖整张目标；Metal 并进这一遍载入动作的清除只到这一遍的渲染区域（最小附件）。附件比这一遍大时先单开一遍整张清（size_clears，移植自 nxnative 9c1e4494）。
//   01007960049A0000（#1330）：每帧开头 32x32 / 256x256 颜色目标旁挂 1280x720 深度并清深度，只清到那个角，其余处拿旧帧深度做测试，满屏噪点块。
// 期望按构造写死：每张附件先整张填旧值（深度 0.75 / RGBA8 0x11223344），命令流 [清颜色][清深度][结束] 交 nvn_be_exec 回放，读回整张：
//   ① 8x8 颜色 + 32x32 深度一起清 → 深度 32x32 整张新值 0.25、颜色 8x8 新值
//   ② 32x32 颜色 0 + 8x8 颜色 1 一起清 → 颜色 0 整张新值
//   ③ 对照：32x32 颜色 + 32x32 深度（同尺寸，修前修后都对，证明框架本身没问题）
//   ⓪ 平台前提（原生 Metal，不经被测实现）：256x256 颜色 + 1280x1280 深度同遍载入时清除并画一笔，深度只清到 256x256（4%）；不画时整张清——
//      所以只落清除的遍看不出错，①② 另按「单独清了 1 次、主遍改为载入」核机制，③ 同尺寸不单独清
// 反证：去掉 rp_begin_ex_ 里的 size_clears → ①② 单独清 0 次，红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

enum { OLD_D = 0x3f400000, NEW_D = 0x3e800000, OLD_C = 0x11223344, NEW_C = 0x80808080 };   // 深度 0.75 → 0.25；RGBA8 → 每通道 0.5
static uint8_t g_ops[256]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static pool_t *g_pool; static id<MTLCommandQueue> g_q; static unsigned g_slot;
static tex_t *mk(int depth, unsigned w) {
    tex_t *t=calloc(1,sizeof *t); REQUIRE(t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=depth?NVN_FORMAT_DEPTH32F_STENCIL8:NVN_FORMAT_RGBA8,.width=w,.height=w,.depth=1,.levels=1};
    t->pool=g_pool; t->off=(int64_t)(g_slot++)*65536; t->mem=g_pool->mem+t->off;
    if (!depth) for (int k=0;k<65536/4;k++) ((uint32_t *)t->mem)[k]=OLD_C;   // 客体内存也是旧值：宿主补同步时读到的同样是旧值
    nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t);
    id<MTLTexture> m=tex_mtl(t); REQUIRE(m);
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
    if (depth) { p.depthAttachment.texture=m; p.depthAttachment.loadAction=MTLLoadActionClear; p.depthAttachment.storeAction=MTLStoreActionStore; p.depthAttachment.clearDepth=.75; }
    else { p.colorAttachments[0].texture=m; p.colorAttachments[0].loadAction=MTLLoadActionClear; p.colorAttachments[0].storeAction=MTLStoreActionStore;
           p.colorAttachments[0].clearColor=MTLClearColorMake(0x44/255.,0x33/255.,0x22/255.,0x11/255.); }
    [[cb renderCommandEncoderWithDescriptor:p] endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    return t;
}
static unsigned new_count(tex_t *t, int depth, unsigned *total) {   // 读回整张，数新值纹素；其余必须是旧值（不是就记成 0 个新值）
    id<MTLTexture> m=tex_mtl(t); unsigned w=(unsigned)m.width, n=w*w; *total=n;
    id<MTLBuffer> r=[g_dev newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
    [b copyFromTexture:m sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,w,1) toBuffer:r destinationOffset:0
        destinationBytesPerRow:w*4 destinationBytesPerImage:n*4 options:depth?MTLBlitOptionDepthFromDepthStencil:MTLBlitOptionNone];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    const uint32_t *px=r.contents; unsigned k=0;
    for (unsigned i=0;i<n;i++) { if (px[i]==(depth?NEW_D:NEW_C)) k++; else if (px[i]!=(depth?OLD_D:OLD_C)) { fprintf(stderr,"  意外值 %#x @%u\n",px[i],i); return 0; } }
    return k;
}
static void run_clear(tex_t *c0, tex_t *c1, tex_t *d) {
    nvn_be_sub_begin(); state_reset(); rp_flush();
    memset(&R.rt,0,sizeof R.rt); R.has_rt=1; R.has_sc=0;
    R.rt.n=c1?2:1; R.rt.color[0]=c0; R.rt.color[1]=c1; R.rt.depth=d;
    g_on=0;
    const p_clear_color cc0={.index=0,.mask=0xf,.rgba={.5f,.5f,.5f,.5f}}; put(OP_CLEAR_COLOR,&cc0,sizeof cc0);
    if (c1) { const p_clear_color cc1={.index=1,.mask=0xf,.rgba={.5f,.5f,.5f,.5f}}; put(OP_CLEAR_COLOR,&cc1,sizeof cc1); }
    if (d) { const p_clear_ds c={.depth=.25f,.depth_mask=1}; put(OP_CLEAR_DS,&c,sizeof c); }
    put(OP_END,NULL,0);
    nvn_be_exec(g_ops); rp_flush();
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
}

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_bigclr_map_XXXXXX",user[]="/tmp/t_bigclr_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("DM_NVN_TBDR"); mtl_init();
    printf("BACKEND Metal%d\n",g_m3?3:4);
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    g_q=[g_dev newCommandQueue];
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    g_pool=calloc(1,sizeof *g_pool); REQUIRE(g_pool); *g_pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    unsigned n, tot; uint64_t b0;

    {   // ⓪ 平台前提：带绘制的遍只清渲染区域（最小附件）
        NSString *src=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 vs(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0.9,1); }\nfragment float4 fs() { return float4(1,0,0,1); }\n";
        NSError *e=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:src options:nil error:&e]; REQUIRE(lib);
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"vs"]; pd.fragmentFunction=[lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm; pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&e]; REQUIRE(ps);
        MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new]; dd.depthCompareFunction=MTLCompareFunctionAlways; dd.depthWriteEnabled=NO;
        id<MTLDepthStencilState> dss=[g_dev newDepthStencilStateWithDescriptor:dd];
        MTLTextureDescriptor *ct=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO]; ct.usage=MTLTextureUsageRenderTarget; ct.storageMode=MTLStorageModePrivate;
        MTLTextureDescriptor *dt=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:1280 height:1280 mipmapped:NO]; dt.usage=MTLTextureUsageRenderTarget; dt.storageMode=MTLStorageModePrivate;
        id<MTLTexture> c=[g_dev newTextureWithDescriptor:ct], d=[g_dev newTextureWithDescriptor:dt];
        id<MTLCommandBuffer> cb=[g_q commandBuffer];
        MTLRenderPassDescriptor *a=[MTLRenderPassDescriptor renderPassDescriptor]; a.depthAttachment.texture=d; a.depthAttachment.loadAction=MTLLoadActionClear; a.depthAttachment.clearDepth=.75; a.depthAttachment.storeAction=MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:a] endEncoding];
        MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture=c; p.colorAttachments[0].loadAction=MTLLoadActionClear; p.colorAttachments[0].storeAction=MTLStoreActionStore;
        p.depthAttachment.texture=d; p.depthAttachment.loadAction=MTLLoadActionClear; p.depthAttachment.clearDepth=.25; p.depthAttachment.storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:p]; [en setRenderPipelineState:ps]; [en setDepthStencilState:dss]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
        id<MTLBuffer> r=[g_dev newBufferWithLength:1280*1280*4 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder]; [b copyFromTexture:d sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1280,1280,1) toBuffer:r destinationOffset:0 destinationBytesPerRow:1280*4 destinationBytesPerImage:1280*1280*4]; [b endEncoding];
        [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
        const float *f=r.contents; unsigned k=0; for (unsigned i=0;i<1280u*1280u;i++) if (f[i]==.25f) k++;
        CHECK(k==256u*256u,"⓪ 平台前提：256x256 颜色 + 1280x1280 深度同遍清除并画一笔，深度只清到渲染区域 %u（期望 %u，整张 %u）",k,256u*256u,1280u*1280u);
    }

    tex_t *c8=mk(0,8), *d32=mk(1,32); b0=g_bigc_n; run_clear(c8,NULL,d32);
    n=new_count(d32,1,&tot); CHECK(n==tot && g_bigc_n-b0==1,"① 8x8 颜色 + 32x32 深度一起清：深度整张新值 %u/%u，单独清 %llu 次（期望 1）",n,tot,(unsigned long long)(g_bigc_n-b0));
    n=new_count(c8,0,&tot); CHECK(n==tot,"① 颜色 8x8 新值 %u/%u",n,tot);

    tex_t *c32=mk(0,32), *c8b=mk(0,8); b0=g_bigc_n; run_clear(c32,c8b,NULL);
    n=new_count(c32,0,&tot); CHECK(n==tot && g_bigc_n-b0==1,"② 32x32 颜色 0 + 8x8 颜色 1 一起清：颜色 0 整张新值 %u/%u，单独清 %llu 次（期望 1）",n,tot,(unsigned long long)(g_bigc_n-b0));
    n=new_count(c8b,0,&tot); CHECK(n==tot,"② 颜色 1 8x8 新值 %u/%u",n,tot);

    tex_t *e32=mk(0,32), *f32=mk(1,32); b0=g_bigc_n; run_clear(e32,NULL,f32);
    unsigned n1=new_count(e32,0,&tot), t1=tot, n2=new_count(f32,1,&tot);
    CHECK(n1==t1 && n2==tot && g_bigc_n==b0,"③ 对照：同尺寸 32x32 颜色 + 深度：整张新值（%u/%u、%u/%u），不单独清（%llu 次）",n1,t1,n2,tot,(unsigned long long)(g_bigc_n-b0));
    unlink(map); unlink(user);
} printf("%s t_nvn_big_clear：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
