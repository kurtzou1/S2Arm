// SPDX-License-Identifier: Apache-2.0
// #778：纹理收尾（nvnTextureFinalize）之后，已录好的命令按旧编号采样，要读到 GPU 写过的内容，不能从全零客体存储重建。
//   探针来自 #778 报告者 shengyifan 的最小复现（由本仓 t_nvn_pkg_sub.m 改出），原样收入；逐用例调用与结论行在 t_nvn_tex_finalize.sh、期望见 runtime/tests/mk/nvn_tex_finalize.mk
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>

extern void *h_nvnBootstrapLoader(const char *);
int s2a_direct_fault(void *, int, void *);
static NVNdevice dev;
static NVNqueue queue;
static NVNtexturePool pool;
static NVNmemoryPool storage;
static NVNtexture texture;
static NVNmemoryPool physical_pool, virtual_pool;
static uint8_t *physical_bytes;
static NVNmemoryPool second_physical;
static int sparse;
typedef struct { NVNmemoryPool *physical; int64_t physical_offset,virtual_offset; uint64_t size; int32_t storage_class,pad; } virtual_mapping;
static void configure_pool(NVNmemoryPool *pool, void *memory, uint64_t size, int flags);
static NVNcommandBuffer writer, reader;
static prog_t program;
static unsigned char *memory;
enum { SIZE = 16<<20, PIXELS = 5<<20, OUT = 4<<20, CMDS = 8<<20, W=100, H=56 };
#define REQUIRE(x) do { if(!(x)) { fprintf(stderr,"SETUP FAIL %s:%d (%s)\n",__FILE__,__LINE__,#x); exit(2); } } while(0)
static void *api(const char *s) { void *p=h_nvnBootstrapLoader(s); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))
static void fault(int s, siginfo_t *si, void *uc) { if(s2a_direct_fault(si->si_addr,1,uc)) return; signal(s,SIG_DFL); }
static void configure_pool(NVNmemoryPool *pool,void *memory,uint64_t size,int flags) {
    NVNmemoryPoolBuilder pb;API(nvnMemoryPoolBuilderSetDefaults)(&pb);API(nvnMemoryPoolBuilderSetDevice)(&pb,&dev);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,memory,size);API(nvnMemoryPoolBuilderSetFlags)(&pb,flags);REQUIRE(API(nvnMemoryPoolInitialize)(pool,&pb));
}
static void compute_shader(void) {
    NSError *err=nil;
    NSString *src=@"#include <metal_stdlib>\nusing namespace metal; struct Args { texture2d<float> t [[id(0)]]; device float4 *out [[id(1)]]; }; kernel void check(constant Args &a [[buffer(0)]],uint3 p [[thread_position_in_grid]]) { if(p.x==0) a.out[0]=a.t.read(uint2(10,10)); }";
    MTLCompileOptions *opts=[MTLCompileOptions new]; opts.languageVersion=MTLLanguageVersion2_3;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:src options:opts error:&err]; if(!lib) fprintf(stderr,"%s\n",err.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *cs=[NvShader new]; cs->stage=5; cs->fn=[lib newFunctionWithName:@"check"]; REQUIRE(cs->fn);
    strlcpy(cs->key,"test_snapshot_reader_b",sizeof cs->key);
    cs->ae=[cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len=cs->ae.encodedLength;
    NSDictionary *refl=@{@"route":@"B",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[
        @{@"kind":@"tex",@"reg":@3,@"arg_id":@0,@"msl_type":@"texture2d<float>"},
        @{@"kind":@"sbuf",@"reg":@0,@"arg_id":@1,@"rw":@YES}]};
    char msg[512]; REQUIRE(nvn_refl_from_json(refl,&cs->rf,msg,sizeof msg)==0);
    NvProg *np=[NvProg new]; np->sh[5]=cs; program.magic=MAGIC('P','R','O','G'); program.serial=nvn_new_serial(); serial_put(program.serial,np);
}
static void record_sample(NVNcommandBuffer *cb,int offset) {
    API(nvnCommandBufferSetTexturePool)(cb,&pool);
    API(nvnCommandBufferBindProgram)(cb,(NVNprogram *)&program,NVN_SHADER_STAGE_COMPUTE_BIT);
    API(nvnCommandBufferBindTexture)(cb,NVN_SHADER_STAGE_COMPUTE,3,API(nvnDeviceGetTextureHandle)(&dev,0,0));
    API(nvnCommandBufferBindStorageBuffer)(cb,NVN_SHADER_STAGE_COMPUTE,0,API(nvnMemoryPoolGetBufferAddress)(&storage)+OUT+offset,16);
    API(nvnCommandBufferDispatchCompute)(cb,1,1,1);
}
static NVNcommandHandle handle(NVNcommandBuffer *cb,int off,int writes) {
    static unsigned char control[2][16384]; REQUIRE(API(nvnCommandBufferInitialize)(cb,&dev));
    API(nvnCommandBufferAddControlMemory)(cb,control[writes],sizeof control[0]);
    API(nvnCommandBufferAddCommandMemory)(cb,&storage,off,1<<20);
    API(nvnCommandBufferBeginRecording)(cb);
    if(writes) { const float white[4]={1,1,1,1}; NVNcopyRegion reg={0,0,0,W,H,1};
        API(nvnCommandBufferClearTexture)(cb,&texture,NULL,&reg,white,15); }
    record_sample(cb,writes?16:0);
    NVNcommandHandle result=API(nvnCommandBufferEndRecording)(cb); REQUIRE(result); return result;
}
static void submit(NVNcommandHandle h,int wait) {
    API(nvnQueueSubmitCommands)(&queue,1,&h);
    if(wait) {API(nvnQueueFinish)(&queue); REQUIRE(!mtl_last_commit_error());}
}
static void setup(int prefill,NVNtextureBuilder *b) {
    struct sigaction sa={0};sa.sa_sigaction=fault;sa.sa_flags=SA_SIGINFO;sigaction(SIGSEGV,&sa,NULL);sigaction(SIGBUS,&sa,NULL);
    NVNdeviceBuilder db;API(nvnDeviceBuilderSetDefaults)(&db);REQUIRE(API(nvnDeviceInitialize)(&dev,&db));
    NVNqueueBuilder qb;API(nvnQueueBuilderSetDefaults)(&qb);API(nvnQueueBuilderSetDevice)(&qb,&dev);REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(!posix_memalign((void**)&memory,65536,SIZE)); memset(memory,0,SIZE);
    NVNmemoryPoolBuilder pb;API(nvnMemoryPoolBuilderSetDefaults)(&pb);API(nvnMemoryPoolBuilderSetDevice)(&pb,&dev);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,memory,SIZE);API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);REQUIRE(API(nvnMemoryPoolInitialize)(&storage,&pb));
    REQUIRE(API(nvnTexturePoolInitialize)(&pool,&storage,1<<20,512));
    API(nvnTextureBuilderSetDefaults)(b);API(nvnTextureBuilderSetDevice)(b,&dev);API(nvnTextureBuilderSetTarget)(b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(b,W,H);API(nvnTextureBuilderSetFormat)(b,NVN_FORMAT_R8);API(nvnTextureBuilderSetLevels)(b,1);
    if(sparse) {
       REQUIRE(!posix_memalign((void**)&physical_bytes,65536,65536));memset(physical_bytes,0,65536);
       configure_pool(&physical_pool,physical_bytes,65536,NVN_MEMORY_POOL_FLAGS_PHYSICAL|NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
       configure_pool(&virtual_pool,NULL,65536,NVN_MEMORY_POOL_FLAGS_VIRTUAL|NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE|NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
       virtual_mapping mapping={&physical_pool,0,0,65536,0,0};REQUIRE(API(nvnMemoryPoolMapVirtual)(&virtual_pool,1,(const NVNmappingRequest*)&mapping));
       API(nvnTextureBuilderSetStorage)(b,&virtual_pool,0);
    } else API(nvnTextureBuilderSetStorage)(b,&storage,PIXELS);
    REQUIRE(API(nvnTextureInitialize)(&texture,b));
    if(prefill&&!sparse) {NVNcopyRegion r={0,0,0,W,H,1};static unsigned char black[W*H];API(nvnTextureWriteTexels)(&texture,NULL,&r,black);}
    API(nvnTexturePoolRegisterTexture)(&pool,0,&texture,NULL);compute_shader();
}
int main(int argc,char **argv) { @autoreleasepool {
    const char *mode=argc>1?argv[1]:"live"; int early=!strcmp(mode,"early"), flight=!strcmp(mode,"flight"),alias=!strcmp(mode,"new"),gpu_only=!strcmp(mode,"gpu-only"),remap=!strcmp(mode,"remap"),pin=!strcmp(mode,"pin");
    REQUIRE(early||flight||alias||gpu_only||pin||remap||!strcmp(mode,"late")||!strcmp(mode,"live"));
    sparse=argc>2&&!strcmp(argv[2],"sparse"); NVNtextureBuilder b;setup(!gpu_only,&b);
    tex_t initial=*(tex_t*)&texture;
    if(sparse) {REQUIRE(!initial.has_layout&&initial.L.size==8192&&initial.pool->flags==0x2a1);
        REQUIRE(initial.d.flags==0&&initial.d.format==1&&nvn_sparse_pool(initial.pool));
        printf("sparse setup: pool=%#x size=%llu format=%u texture_flags=%#x layout=%d no CPU texture write\n",initial.pool->flags,initial.L.size,initial.d.format,initial.d.flags,initial.has_layout);}

    uint64_t serial=((tex_t*)&texture)->serial; NVNcommandHandle rd=handle(&reader,CMDS,0),wr=handle(&writer,CMDS+(1<<20),1);
    if(early) API(nvnTextureFinalize)(&texture);
    float *out=(float*)(memory+OUT);out[0]=-7;out[4]=-7;submit(rd,1);REQUIRE(out[0]==0);
    id<MTLSharedEvent> gate=nil;
    if(flight) {REQUIRE(!g_m3);gate=[g_dev newSharedEvent]; [g_q4 waitForEvent:gate value:1]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{gate.signaledValue=1;});}
    submit(wr,!flight);
    id held=pin?tex_get(serial):nil; BOOL pkg=[tex_get(serial) isKindOfClass:NvPkg.class]; uint64_t firstup=g_pfv_upgrades;
    if(flight) {pthread_mutex_lock(&g_mu);printf("writer_in_flight=%d fence=%llu done=%llu\n",g_fence>g_done,g_fence,g_done);pthread_mutex_unlock(&g_mu); REQUIRE(gate.signaledValue==0);}
    if(!early&&strcmp(mode,"live")) API(nvnTextureFinalize)(&texture);
    if(pin) tex_put(serial,held);
    if(alias) {REQUIRE(API(nvnTextureInitialize)(&texture,&b));API(nvnTexturePoolRegisterTexture)(&pool,0,&texture,NULL);}
    if(remap) {
        REQUIRE(sparse);
        uint8_t *new_bytes=NULL; REQUIRE(!posix_memalign((void**)&new_bytes,65536,65536)); memset(new_bytes,73,65536);
        configure_pool(&second_physical,new_bytes,65536,NVN_MEMORY_POOL_FLAGS_PHYSICAL|NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        virtual_mapping mapping={&second_physical,0,0,65536,0,0};
        REQUIRE(API(nvnMemoryPoolMapVirtual)(&virtual_pool,1,(const NVNmappingRequest*)&mapping));
    }
    if(gate) gate.signaledValue=1;
    out[0]=-7;submit(rd,1);
    int a=lroundf(255*out[4]),v=lroundf(255*out[0]);
    printf("mode=%s Metal%d W=%d H=%d original_packed=%d CPU_storage_R=%u GPU_after_write=%d GPU_saved_descriptor=%d first_uploads=%llu reuploads=%llu upgrades=%llu\n",mode,g_m3?3:4,W,H,pkg,sparse?physical_bytes[0]:memory[PIXELS],a,v,g_pkg_uploads,g_pkg_reuploads,firstup);
    REQUIRE(a==255);REQUIRE(sparse?physical_bytes[0]==0:memory[PIXELS]==0);
    if(!alias) {submit(wr,1);printf("after_next_attachment total_upgrades=%llu\n",g_pfv_upgrades);}
    return v==(remap?73:255)?0:1;
} }
