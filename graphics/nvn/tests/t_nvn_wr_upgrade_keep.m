// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 同一贴图反复「升级成可写」（D-67FG / D-6A9G / D-XJNP：同一 serial 一局 3–5 万次，每次新建 + 整张拷贝，与卡顿、坏指针崩溃同现）。
// 场景：不带 IMAGE 标志建的 RGBA8 贴图，CPU 写过（预排布贴图 NvPkg），每轮先由 CPU 整张重写、再被计算着色器当图像写（生产 dispatch，图像槽 img_wr_note → img_wr_upgrade）。
// 期望（不跑被测实现就能定）：可写用途只需加一次——第 1 轮升级 1 次，之后 CPU 重写只换内容、不该丢掉已加的用途：4 轮合计升级 ≤ 1 次；
//   每轮 CPU 重写后解析出的贴图都带 ShaderWrite；每轮写完读回 = 着色器写的红色（内容对）。
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>
extern void *h_nvnBootstrapLoader(const char *name);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *api(const char *name) { void *p=h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))
enum { W=256, H=256, POOL_SIZE=16<<20, TEX_OFF=5<<20, OUT_OFF=4<<20, TID=7 };
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool;
static uint8_t *memory; static prog_t graphics, writer, reader;
static void fault(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr,1,uc)) return; signal(s,SIG_DFL); }
static void finish(void) { uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 tri(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"fragment float4 red() { return float4(1,0,0,1); }\n"
"struct Write { texture2d<float,access::write> image [[id(0)]]; };\n"
"kernel void wr(constant Write &a [[buffer(0)]],uint2 p [[thread_position_in_grid]]) { a.image.write(float4(1,0,0,1),p); }\n"
"struct Read { texture2d<float,access::read> image [[id(0)]]; device float4 *out [[id(1)]]; };\n"
"kernel void rd(constant Read &a [[buffer(0)]]) { a.out[0]=a.image.read(uint2(0)); a.out[1]=a.image.read(uint2(255)); }\n";
static NvShader *shader(id<MTLLibrary> lib, NSString *name, int stage, NSDictionary *reflection) {
    NvShader *s=[NvShader new]; s->stage=stage; s->fn=[lib newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key,stage==0?"aaaaaaaaaaaaaaaa_b":stage==1?"bbbbbbbbbbbbbbbb_b":[name isEqualToString:@"wr"]?"cccccccccccccccc_b":"dddddddddddddddd_b",sizeof s->key); s->rf.pos_attr=-1; s->rf.has_user=1;
    if (reflection) { char error[512]; REQUIRE(!nvn_refl_from_json(reflection,&s->rf,error,sizeof error));
        s->ae=[s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae); s->arg_len=s->ae.encodedLength; }
    return s;
}
static void program(prog_t *p, NvProg *np) { *p=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p->serial,np); }
static void read_bound(void) {
    nvn_be_sub_begin(); state_reset(); S.tex_base=0; S.cprog=&reader; S.tex[5][0]=TID;
    S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(uintptr_t)(memory+OUT_OFF),.size=32}; args_dirty_all();
    p_dispatch d={.x=1,.y=1,.z=1}; dispatch(&d); finish();
}

static uint64_t upgrades(void) { return g_pfv_upgrades; }
static void cpu_fill(NVNtexture *texture, uint8_t r, uint8_t g, uint8_t b) {
    uint8_t *px=malloc(W*H*4); REQUIRE(px); for (int i=0;i<W*H;i++) { px[4*i]=r; px[4*i+1]=g; px[4*i+2]=b; px[4*i+3]=255; }
    NVNcopyRegion full={0,0,0,W,H,1}; API(nvnTextureWriteTexels)(texture,NULL,&full,px); free(px);
}
static void run_rounds(void) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b,W,H);
    API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetLevels)(&b,1);
    API(nvnTextureBuilderSetFlags)(&b,0); API(nvnTextureBuilderSetStorage)(&b,&pool,TEX_OFF);   // 不带 IMAGE：建出来没有 ShaderWrite
    NVNtexture texture={0}; REQUIRE(API(nvnTextureInitialize)(&texture,&b)); tex_t *t=(tex_t *)&texture;
    cpu_fill(&texture,0,0,255); nvn_be_reg_tex(TID,t,NULL); read_bound();
    REQUIRE([tex_get(t->serial) isKindOfClass:[NvPkg class]]);
    uint64_t u0=upgrades(); int lost=0;
    for (int r=0;r<4;r++) {
        cpu_fill(&texture,(uint8_t)(10*r),(uint8_t)(20+r),0);   // 每页都变：整张换内容
        nvn_be_sub_begin(); state_reset(); id<MTLTexture> m=tex_mtl(t); finish();
        int w=m && (m.usage & MTLTextureUsageShaderWrite);
        if (r>0 && !w) lost++;
        printf("round %d: after CPU rewrite usage=%#lx (ShaderWrite %s), holder %s, upgrades so far %llu\n",r,(unsigned long)m.usage,w?"yes":"no",
               [tex_get(t->serial) isKindOfClass:[NvPkg class]]?"NvPkg":"texture",(unsigned long long)(upgrades()-u0));
        nvn_be_sub_begin(); state_reset(); args_dirty_all(); S.cprog=&writer; S.img[5][0]=TID; p_dispatch d={.x=W,.y=H,.z=1}; dispatch(&d); finish();
        read_bound(); const float *out=(float *)(memory+OUT_OFF);
        CHECK(out[0]==1 && out[1]==0 && out[2]==0 && out[3]==1,"round %d image write read back expected red (1,0,0,1), actual=(%.2f,%.2f,%.2f,%.2f)",r,out[0],out[1],out[2],out[3]);
    }
    uint64_t n=upgrades()-u0;
    CHECK(n<=1,"4 rounds of CPU rewrite + image write: shader-write upgrades expected <= 1, actual %llu",(unsigned long long)n);
    CHECK(lost==0,"rounds 2-4: texture resolved after a CPU rewrite keeps ShaderWrite, rounds that lost it expected 0, actual %d",lost);
    API(nvnTextureFinalize)(&texture);
}
int main(int argc, char **argv) { @autoreleasepool {
    int scaled=0; (void)argc; (void)argv;
    setenv("S2A_RES_SCALE",scaled?"0.5":"1",1);
    setvbuf(stdout,NULL,_IOLBF,0); setenv("DM_PSO_ARCHIVE","0",1);
    struct sigaction sa={0}; sa.sa_sigaction=fault; sa.sa_flags=SA_SIGINFO; sigaction(SIGBUS,&sa,NULL); sigaction(SIGSEGV,&sa,NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(!posix_memalign((void **)&memory,65536,POOL_SIZE)); memset(memory,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,memory,POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb));
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty); printf("BACKEND Metal%d\n",g_m3?3:4);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; if(!lib) fprintf(stderr,"MSL %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvProg *gp=[NvProg new]; gp->sh[0]=shader(lib,@"tri",0,nil); gp->sh[1]=shader(lib,@"red",1,nil); gp->sh[1]->rf.color_known=1; gp->sh[1]->rf.color_mask=1; program(&graphics,gp);
    NvProg *wp=[NvProg new]; wp->sh[5]=shader(lib,@"wr",5,@{@"route":@"B",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[@{@"kind":@"img",@"reg":@0,@"arg_id":@0,@"rw":@YES,@"msl_type":@"texture2d<float, access::write>"}]}); program(&writer,wp);
    NvProg *rp=[NvProg new]; rp->sh[5]=shader(lib,@"rd",5,@{@"route":@"B",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[@{@"kind":@"tex",@"reg":@0,@"arg_id":@0,@"msl_type":@"texture2d<float>"},@{@"kind":@"sbuf",@"reg":@0,@"arg_id":@1,@"rw":@YES}]}); program(&reader,rp);
    run_rounds();
    printf("%s t_nvn_wr_upgrade_keep: %u checks, %u failures\n",failures?"✗":"✓",checks,failures); return failures?1:0;
} }
