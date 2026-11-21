// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Two storage cases a compute image write must reach, through the production dispatch / binding path and independent Metal readback.
//   split A / B: one storage (same pool, same offset, same 3D RGBA16F description) named by an image object A (IMAGE) and a sampled object B (no IMAGE flag) in a pool
//     the CPU can write, the storage holding non-zero bytes (half 1.0). A kernel stores (0.25, 0.5, 0.75, 1) through A; reading B must give that, in either creation order
//     (A first; B first and already uploaded as a CPU-written texture), and no split is logged. A split these rules do not join (B written through WriteTexels) is logged once per pair.
//   fit: a compute image slot the shader declares uint, holding an RG32F texture made without the format-view usage, dispatched once: the words it stores must be in the texture.
// Expected values are the constants the kernels store, written by hand.
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
enum { N=4, POOL_SIZE=16<<20, OUT_OFF=0, TID_A=7, TID_B=8, TID_F=9 };
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool;
static uint8_t *memory; static prog_t writer, reader, uwriter;
static void fault(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr,1,uc)) return; signal(s,SIG_DFL); }
static void finish(void) { uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"struct W3 { texture3d<float,access::write> image [[id(0)]]; };\n"
"kernel void wr3(constant W3 &a [[buffer(0)]],uint3 p [[thread_position_in_grid]]) { a.image.write(float4(0.25,0.5,0.75,1),p); }\n"
"struct R3 { texture3d<float> image [[id(0)]]; device float4 *out [[id(1)]]; };\n"
"kernel void rd3(constant R3 &a [[buffer(0)]]) { a.out[0]=a.image.read(uint3(0)); a.out[1]=a.image.read(uint3(3)); }\n"
"struct WU { texture2d<uint,access::write> image [[id(0)]]; };\n"
"kernel void wru(constant WU &a [[buffer(0)]],uint2 p [[thread_position_in_grid]]) { a.image.write(uint4(0x11223344u,0x55667788u,0,0),p); }\n";
static NvShader *shader(id<MTLLibrary> lib, NSString *name, const char *key, NSDictionary *reflection) {
    NvShader *s=[NvShader new]; s->stage=5; s->fn=[lib newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key,key,sizeof s->key); s->rf.pos_attr=-1; s->rf.has_user=1;
    char error[512]; REQUIRE(!nvn_refl_from_json(reflection,&s->rf,error,sizeof error));
    s->ae=[s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae); s->arg_len=s->ae.encodedLength;
    return s;
}
static void program(prog_t *p, NvProg *np) { *p=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p->serial,np); }
static NVNtexture texture(int target, int format, int flags, uint64_t off) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,target);
    if (target==NVN_TEXTURE_TARGET_3D) API(nvnTextureBuilderSetSize3D)(&b,N,N,N); else API(nvnTextureBuilderSetSize2D)(&b,N,N);
    API(nvnTextureBuilderSetFormat)(&b,format); API(nvnTextureBuilderSetLevels)(&b,1);
    API(nvnTextureBuilderSetFlags)(&b,flags); API(nvnTextureBuilderSetStorage)(&b,&pool,off);
    NVNtexture t={0}; REQUIRE(API(nvnTextureInitialize)(&t,&b)); return t;
}
static void write3(int tid) {
    nvn_be_sub_begin(); state_reset(); S.tex_base=0; S.cprog=&writer; S.img[5][0]=tid; args_dirty_all();
    p_dispatch d={.x=N,.y=N,.z=N}; dispatch(&d); finish();
}
static void read3(int tid, float out[8]) {
    memset(memory+OUT_OFF,0,32);
    nvn_be_sub_begin(); state_reset(); S.tex_base=0; S.cprog=&reader; S.tex[5][0]=tid;
    S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(uintptr_t)(memory+OUT_OFF),.size=32}; args_dirty_all();
    p_dispatch d={.x=1,.y=1,.z=1}; dispatch(&d); finish();
    memcpy(out,memory+OUT_OFF,32);
}
static int is_written(const float *o) { return o[0]==0.25f && o[1]==0.5f && o[2]==0.75f && o[3]==1 && o[4]==0.25f && o[5]==0.5f && o[6]==0.75f && o[7]==1; }
// Storage filled with half 1.0 (0x3C00) before the textures are made: every texel reads (1, 1, 1, 1) whatever the block-linear layout
static void fill_ones(uint64_t off, size_t n) { uint16_t *p=(uint16_t *)(memory+off); for (size_t i=0;i<n/2;i++) p[i]=0x3C00; }
static void split_case(int b_first, uint64_t off) {
    const char *name=b_first?"B (sampled) first":"A (image) first";
    fill_ones(off,64<<10);
    NVNtexture ta=texture(NVN_TEXTURE_TARGET_3D,NVN_FORMAT_RGBA16F,NVN_TEXTURE_FLAGS_IMAGE,off), tb=texture(NVN_TEXTURE_TARGET_3D,NVN_FORMAT_RGBA16F,0,off);
    tex_t *a=(tex_t *)&ta, *b=(tex_t *)&tb; nvn_be_reg_tex(TID_A,a,NULL); nvn_be_reg_tex(TID_B,b,NULL);
    float o[8]; uint64_t logged=g_split_logged;
    if (b_first) {
        read3(TID_B,o);
        REQUIRE([tex_get(b->serial) isKindOfClass:[NvPkg class]]);   // the case under test: B is a texture taken from its CPU-written storage before A exists
        CHECK(o[0]==1 && o[3]==1 && o[4]==1 && o[7]==1,"%s: B before any GPU write reads the CPU bytes expected=(1,1,1,1) actual=(%.3g,%.3g,%.3g,%.3g)",name,o[0],o[1],o[2],o[3]);
    }
    write3(TID_A);
    read3(TID_B,o);
    printf("CASE %s: B resolves to %s\n",name,[tex_get(b->serial) isKindOfClass:[NvPkg class]]?"a CPU-written texture (NvPkg)":"a GPU texture");
    CHECK(is_written(o),"%s: B reads what the image store through A wrote expected=(0.25,0.5,0.75,1)x2 actual=(%.3g,%.3g,%.3g,%.3g)(%.3g,%.3g,%.3g,%.3g)",name,o[0],o[1],o[2],o[3],o[4],o[5],o[6],o[7]);
    CHECK(g_split_logged==logged,"%s: no split storage logged expected=0 new lines actual=%llu",name,(unsigned long long)(g_split_logged-logged));
    API(nvnTextureFinalize)(&ta); API(nvnTextureFinalize)(&tb);
}
// Splits the image path does not join, the diagnostic line's cases: B filled through WriteTexels (a CPU-written texture of its own, re-uploaded when the CPU writes it again)
//   and image stores through A over the same storage. a_first: A is resolved and written before the CPU writes B, so A is the shared GPU texture; otherwise the CPU write
//   since init makes A a CPU-written texture as well (two of them). Either way the first GPU write through A after B exists names the pair in one line, the next adds none
static void split_logged_case(int a_first, uint64_t off) {
    const char *name=a_first?"WriteTexels B, shared image A":"WriteTexels B, CPU-written image A";
    NVNtexture ta=texture(NVN_TEXTURE_TARGET_3D,NVN_FORMAT_RGBA16F,NVN_TEXTURE_FLAGS_IMAGE,off), tb=texture(NVN_TEXTURE_TARGET_3D,NVN_FORMAT_RGBA16F,0,off);
    tex_t *a=(tex_t *)&ta, *b=(tex_t *)&tb; nvn_be_reg_tex(TID_A,a,NULL); nvn_be_reg_tex(TID_B,b,NULL);
    if (a_first) write3(TID_A);
    uint16_t ones[N*N*N*4]; for (int i=0;i<N*N*N*4;i++) ones[i]=0x3C00;
    NVNcopyRegion full={0,0,0,N,N,N}; API(nvnTextureWriteTexels)(&tb,NULL,&full,ones);
    float o[8]; read3(TID_B,o); REQUIRE([tex_get(b->serial) isKindOfClass:[NvPkg class]]);
    uint64_t logged=g_split_logged;
    write3(TID_A);
    REQUIRE([tex_get(a->serial) isKindOfClass:[NvPkg class]]==!a_first);
    CHECK(g_split_logged==logged+1,"%s: split storage logged at the first write through A expected=1 new line actual=%llu",name,(unsigned long long)(g_split_logged-logged));
    write3(TID_A);
    CHECK(g_split_logged==logged+1,"%s: logged once for the pair expected=1 line after a second write actual=%llu",name,(unsigned long long)(g_split_logged-logged));
    API(nvnTextureFinalize)(&ta); API(nvnTextureFinalize)(&tb);
}
static void fit_case(uint64_t off) {
    NVNtexture tf=texture(NVN_TEXTURE_TARGET_2D,NVN_FORMAT_RG32F,NVN_TEXTURE_FLAGS_IMAGE,off); tex_t *f=(tex_t *)&tf;
    nvn_be_reg_tex(TID_F,f,NULL);
    nvn_be_sub_begin(); state_reset(); S.tex_base=0; id<MTLTexture> t0=tex_mtl(f); REQUIRE(t0); finish();
    REQUIRE(!(t0.usage & MTLTextureUsagePixelFormatView));   // the case under test: made without the format-view usage
    nvn_be_sub_begin(); state_reset(); S.tex_base=0; S.cprog=&uwriter; S.img[5][0]=TID_F; args_dirty_all();
    p_dispatch d={.x=N,.y=N,.z=1}; dispatch(&d); finish();
    nvn_be_sub_begin(); state_reset(); id<MTLTexture> t=tex_mtl(f); REQUIRE(t); finish();
    id<MTLBuffer> buf=[g_dev newBufferWithLength:N*N*8 options:MTLResourceStorageModeShared]; REQUIRE(buf);
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> enc=[cb blitCommandEncoder]; REQUIRE(enc);
    [enc copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(N,N,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:N*8 destinationBytesPerImage:N*N*8];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    const uint32_t *w=buf.contents, *z=w+(N*N-1)*2;
    CHECK(w[0]==0x11223344u && w[1]==0x55667788u && z[0]==0x11223344u && z[1]==0x55667788u,
          "uint image slot over an RG32F texture without format views, one dispatch: words stored expected=(0x11223344,0x55667788) actual=(%#x,%#x)(%#x,%#x)",w[0],w[1],z[0],z[1]);
    API(nvnTextureFinalize)(&tf);
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    setvbuf(stdout,NULL,_IOLBF,0); setenv("DM_PSO_ARCHIVE","0",1);
    struct sigaction sa={0}; sa.sa_sigaction=fault; sa.sa_flags=SA_SIGINFO; sigaction(SIGBUS,&sa,NULL); sigaction(SIGSEGV,&sa,NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(!posix_memalign((void **)&memory,65536,POOL_SIZE)); memset(memory,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,memory,POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb));
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty); printf("BACKEND Metal%d\n",g_m3?3:4);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; if(!lib) fprintf(stderr,"MSL %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvProg *wp=[NvProg new]; wp->sh[5]=shader(lib,@"wr3","cccccccccccccccc_b",@{@"route":@"B",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[@{@"kind":@"img",@"reg":@0,@"arg_id":@0,@"rw":@YES,@"msl_type":@"texture3d<float, access::write>"}]}); program(&writer,wp);
    NvProg *rp=[NvProg new]; rp->sh[5]=shader(lib,@"rd3","dddddddddddddddd_b",@{@"route":@"B",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[@{@"kind":@"tex",@"reg":@0,@"arg_id":@0,@"msl_type":@"texture3d<float>"},@{@"kind":@"sbuf",@"reg":@0,@"arg_id":@1,@"rw":@YES}]}); program(&reader,rp);
    NvProg *up=[NvProg new]; up->sh[5]=shader(lib,@"wru","eeeeeeeeeeeeeeee_b",@{@"route":@"B",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[@{@"kind":@"img",@"reg":@0,@"arg_id":@0,@"rw":@YES,@"msl_type":@"texture2d<uint, access::write>"}]}); program(&uwriter,up);
    split_case(0,1<<20);
    split_case(1,2<<20);
    split_logged_case(1,3<<20);
    split_logged_case(0,4<<20);
    fit_case(5<<20);
    printf("%s t_nvn_img_split: %u checks, %u failures\n",failures?"✗":"✓",checks,failures); return failures?1:0;
} }
