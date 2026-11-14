// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 超大目标的遍只开到剪裁框远角（g_rp_aw / g_rp_ah，照 nxnative c8521eeb，MIT；11-13 能耗性能线）：目标 ≥ 16 M 像素、遍里没有清除、剪裁框远角围出的区域不超过目标一半时，
// 开遍设 renderTargetWidth / Height = 远角，GPU 不读入也不写回区域外的部分（Metal 保留区域外的内容）。一笔出了区域就先结束这一遍再开。
// 期望按构造写死（不跑被测实现推）：4096x4096 RGBA8 目标先整张填 64（0.25），全屏三角写 128（0.5）：
//   ① 剪裁 (16,16,32,32) 画一笔：开遍区域 48x48；读回框内 (16,16)(47,47) = 128，框外 (15,15)(48,48)(100,100)(4095,4095) = 64（区域外的内容保留）
//   ② 先剪裁 (16,16,32,32) 画、再剪裁 (0,2000,64,64) 画：第二笔出了 48x48 区域 → 结束重开，区域 64x2064；两个框都画上、框外仍是 64
//   ③ 64x64 小目标：不用区域（g_rp_aw = 0），画法照旧
// 反证：去掉开遍那段区域设置 → ① ② 的区域检查红；去掉 draw() 里「出了区域就结束」那行 → ② 第二个框读回 64（被区域裁掉）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"fragment float4 half_grey() { return float4(0.5f); }\n";

enum { BIG = 4096 };
static void texture(tex_t *t, pool_t *pool, size_t off, int n) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.flags=NVN_TEXTURE_FLAGS_IMAGE,.width=n,.height=n,.depth=1,.levels=1};
    t->pool=pool; t->off=off; t->mem=pool->mem+off; nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static id<MTLBuffer> buf;
static void xfer(tex_t *t, int n, int up) {
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    if (up) [e copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:n*4 sourceBytesPerImage:(NSUInteger)n*n*4 sourceSize:MTLSizeMake(n,n,1) toTexture:tex_mtl(t) destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    else [e copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(n,n,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:n*4 destinationBytesPerImage:(NSUInteger)n*n*4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
}
static uint8_t g_ops[1024]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static prog_t pg; static NSUInteger g_aw_seen[4], g_ah_seen[4]; static int g_nseen;
// 回放：目标 t（边长 n）整张填 64，命令流 g_ops；每笔绘制之后记下当时开着的遍的区域（钩在 OP_DRAW 之间不好插，改成逐笔回放）
static void run(tex_t *t, int n, const p_scissor *sc, int nsc) {
    memset(buf.contents,64,(size_t)n*n*4); xfer(t,n,1);
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    nvn_be_sub_begin(); state_reset(); S.prog=&pg; rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=1; R.rt.color[0]=t; R.has_rt=1; g_pso_dirty=1; args_dirty_all();
    g_nseen=0;
    for (int i=0;i<nsc;i++) {
        g_on=0; put(OP_SCISSOR,&sc[i],sizeof sc[i]); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
        nvn_be_exec(g_ops); g_aw_seen[g_nseen]=g_enc?g_rp_aw:9999; g_ah_seen[g_nseen++]=g_enc?g_rp_ah:9999;
    }
    rp_flush();
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    memset(buf.contents,0xA5,(size_t)n*n*4); xfer(t,n,0);
}
static int px(int n, int x, int y) { return ((const uint8_t *)buf.contents)[((size_t)y*n+x)*4]; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_rp_area_map_XXXXXX",user[]="/tmp/t_rp_area_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("DM_NVN_TBDR"); unsetenv("DM_NVN_RP_AREA"); mtl_init(); printf("BACKEND Metal%d\n",g_m3?3:4);
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; if(!lib) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *vs=[NvShader new]; vs->stage=0; vs->fn=[lib newFunctionWithName:@"triangle"]; strlcpy(vs->key,"aaaaaaaaaaaaaaaa_b",sizeof vs->key); vs->rf.pos_attr=-1; vs->rf.has_user=1;
    NvShader *fs=[NvShader new]; fs->stage=1; fs->fn=[lib newFunctionWithName:@"half_grey"]; strlcpy(fs->key,"eeeeeeeeeeeeeeee_b",sizeof fs->key); fs->rf.pos_attr=-1; fs->rf.has_user=2; fs->rf.color_known=1; fs->rf.color_mask=1;
    REQUIRE(vs->fn && fs->fn);
    NvProg *g=[NvProg new]; g->sh[0]=vs; g->sh[1]=fs;
    pg=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(pg.serial,g);
    size_t big=(size_t)BIG*BIG*4, psz=big+(1<<20);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,psz)); memset(memory,0,psz);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=psz}; nvn_be_pool_add(memory,psz);
    tex_t T, S64; texture(&T,pool,0,BIG); texture(&S64,pool,big,64);
    buf=[g_dev newBufferWithLength:big options:MTLResourceStorageModeShared]; REQUIRE(buf);

    const p_scissor s1={16,16,32,32}, s2={0,2000,64,64};
    run(&T,BIG,&s1,1);
    CHECK(g_aw_seen[0]==48 && g_ah_seen[0]==48,"① 4096x4096 目标、剪裁 (16,16,32,32)：开遍区域 %lux%lu（期望 48x48）",(unsigned long)g_aw_seen[0],(unsigned long)g_ah_seen[0]);
    CHECK(px(BIG,16,16)==128 && px(BIG,47,47)==128,"① 框内画上：(16,16)=%d (47,47)=%d（期望 128）",px(BIG,16,16),px(BIG,47,47));
    CHECK(px(BIG,15,15)==64 && px(BIG,48,48)==64 && px(BIG,100,100)==64 && px(BIG,4095,4095)==64,"① 框外与区域外保留：(15,15)=%d (48,48)=%d (100,100)=%d (4095,4095)=%d（期望 64）",
          px(BIG,15,15),px(BIG,48,48),px(BIG,100,100),px(BIG,4095,4095));

    const p_scissor s12[2]={s1,s2};
    run(&T,BIG,s12,2);
    CHECK(g_aw_seen[0]==48 && g_ah_seen[0]==48 && g_aw_seen[1]==64 && g_ah_seen[1]==2064,"② 第二笔出了区域 → 重开：区域 %lux%lu → %lux%lu（期望 48x48 → 64x2064）",
          (unsigned long)g_aw_seen[0],(unsigned long)g_ah_seen[0],(unsigned long)g_aw_seen[1],(unsigned long)g_ah_seen[1]);
    CHECK(px(BIG,20,20)==128 && px(BIG,0,2000)==128 && px(BIG,63,2063)==128,"② 两个框都画上：(20,20)=%d (0,2000)=%d (63,2063)=%d（期望 128）",px(BIG,20,20),px(BIG,0,2000),px(BIG,63,2063));
    CHECK(px(BIG,64,2000)==64 && px(BIG,0,1999)==64 && px(BIG,30,1000)==64 && px(BIG,4095,0)==64,"② 框外保留：(64,2000)=%d (0,1999)=%d (30,1000)=%d (4095,0)=%d（期望 64）",
          px(BIG,64,2000),px(BIG,0,1999),px(BIG,30,1000),px(BIG,4095,0));

    run(&S64,64,&s1,1);
    CHECK(g_aw_seen[0]==0,"③ 64x64 小目标不用区域：g_rp_aw=%lu（期望 0）",(unsigned long)g_aw_seen[0]);
    CHECK(px(64,16,16)==128 && px(64,47,47)==128 && px(64,15,15)==64 && px(64,48,48)==64,"③ 画法照旧：(16,16)=%d (47,47)=%d (15,15)=%d (48,48)=%d",px(64,16,16),px(64,47,47),px(64,15,15),px(64,48,48));
    unlink(map); unlink(user);
} printf("%s t_nvn_rp_area：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
