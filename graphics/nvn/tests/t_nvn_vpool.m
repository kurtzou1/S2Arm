// 虚拟池（flags 0x200）一律按页表（hle_nvn.c vpool_*，11-03 火炬之光3 / Trine 5 / 无人深空同族）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。期望按 NVN 语义手写，不由被测实现推出：
//   虚拟池是一段 GPU 地址，MapVirtual 把物理池的页按请求逐段挂上去；每段请求各自独立（物理偏移 − 虚拟偏移不必相同），后来的请求不影响先前的；
//   贴图 / 缓冲按虚拟偏移读，读到的是该页当前挂着的物理页内容。真驱动（无人深空 SDK 静态核）：虚拟池的 nvnMemoryPoolMap 恒为 NULL，缓冲 Map 转调池 Map 也是 NULL；
//   虚拟池上建缓冲不要求已映射（驱动只记池 + 偏移），地址 = 池的缓冲区地址 + 偏移。
// 物理池每 64 KB 一块填同一个 4 字节色值：RGBA8 贴图的每个纹素整个落在某一块里，读回按色值计数即可，与块线性布局无关（一块 64 KB = 16384 个纹素）。
// 只验虚拟池这一条：随包 game.tsv 写 tex_dirty_upload off（不加写保护，本进程写物理池不缺页）。
#include "nvn_protos.h"
#include "nvn_obj.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach/mach.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool cmd_pool, phys;
static NVNcommandBuffer commands;
static void *cmd_storage, *phys_storage;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { BLOCK = 0x10000, PHYS_SIZE = 64 * BLOCK, CMD_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, W = 256, H = 128, TEX_BYTES = W * H * 4 };   // 贴图 256x128 RGBA8 = 2 块
enum { VFLAGS = NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS };   // 0x221：火炬之光3 / Trine 5 / 无人深空的池
static char data_dir[256];
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
#define CHECK(x, ...) do { checks++; if (!(x)) { fails++; printf("FAIL [%s] %s：",phase,#x); printf(__VA_ARGS__); putchar('\n'); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNmemoryPool *phys; int64_t poff, voff; uint64_t size; int32_t storage_class, _pad; } map_req;   // NVNmappingRequest，0x28 字节
static uint32_t color(int block) { return 0xFF000000u | (uint32_t)(block + 1) * 0x010203u; }   // 每块一个不同的不透明色
static void pool_init(NVNmemoryPool *p, void *storage, uint64_t size, int flags) {
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,size); API(nvnMemoryPoolBuilderSetFlags)(&pb,flags);
    REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
static void setup(void) {
    char *dir=data_dir; snprintf(data_dir,sizeof data_dir,"%s/t_nvn_vpool.%d",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp",(int)getpid());
    char p[512]; snprintf(p,sizeof p,"%s/shaders",dir); mkdir(dir,0700); mkdir(p,0700); snprintf(p,sizeof p,"%s/shaders/direct",dir); mkdir(p,0700);
    snprintf(p,sizeof p,"%s/shaders/direct/game.tsv",dir); FILE *f=fopen(p,"w"); REQUIRE(f!=NULL); fputs("tex_dirty_upload\toff\n",f); fclose(f);
    setenv("S2A_GAME_DATA",dir,1);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(posix_memalign(&cmd_storage,65536,CMD_SIZE)==0); memset(cmd_storage,0,CMD_SIZE);
    pool_init(&cmd_pool,cmd_storage,CMD_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(posix_memalign(&phys_storage,65536,PHYS_SIZE)==0);
    for (int b=0; b<PHYS_SIZE/BLOCK; b++) { uint32_t c=color(b); for (size_t i=0; i<BLOCK; i+=4) memcpy((uint8_t *)phys_storage+(size_t)b*BLOCK+i,&c,4); }
    pool_init(&phys,phys_storage,PHYS_SIZE,NVN_MEMORY_POOL_FLAGS_PHYSICAL|NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static void vpool_init(NVNmemoryPool *v, uint64_t size) { memset(v,0,sizeof *v); pool_init(v,NULL,size,VFLAGS); }
static int map(NVNmemoryPool *v, int64_t voff, int block, uint64_t size) {   // 虚拟偏移 voff 起 size 字节 ← 物理池第 block 块起
    map_req r={&phys,(int64_t)block*BLOCK,voff,size,0,0};
    return API(nvnMemoryPoolMapVirtual)(v,1,(const NVNmappingRequest *)&r);
}
static void tex_init(NVNtexture *t, NVNmemoryPool *v, int64_t off) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,W,H); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    REQUIRE(API(nvnTextureBuilderGetStorageSize)(&b)==TEX_BYTES);
    API(nvnTextureBuilderSetStorage)(&b,v,(ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(t,&b));
}
// GPU 把整张贴图拷到命令池 READ_OFFSET，数每个物理块色值的纹素数
static void tex_count(NVNtexture *t, int want_a, int want_b, const char *what) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,TEX_BYTES);
    NVNcopyRegion whole={0,0,0,W,H,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    const uint8_t *p=(const uint8_t *)cmd_storage+READ_OFFSET; uint32_t ca=color(want_a), cb=color(want_b); int na=0, nb=0, other=0; uint32_t first_other=0;
    for (int i=0; i<W*H; i++) { uint32_t c; memcpy(&c,p+4*i,4); if (c==ca) na++; else if (c==cb) nb++; else { if (!other++) first_other=c; } }
    CHECK(na==W*H/2 && nb==W*H/2 && !other,"%s：块 %d 的色 %d 个、块 %d 的色 %d 个、别的 %d 个（首个 %#x），期望各 %d 个、别的 0",what,want_a,na,want_b,nb,other,first_other,W*H/2);
}
// GPU 按缓冲区地址从虚拟池读 4 字节（拷到命令池），期望是挂在那页的物理块色值
static void buf_check(NVNmemoryPool *v, int64_t voff, int want, const char *what) {
    uint32_t *out=(uint32_t *)((uint8_t *)cmd_storage+READ_OFFSET); *out=0xA5A5A5A5u;
    NVNbufferAddress src=API(nvnMemoryPoolGetBufferAddress)(v)+(uint64_t)voff, dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyBufferToBuffer)(&commands,src,dst,4,0); submit();
    CHECK(*out==color(want),"%s：读到 %#x，期望块 %d 的色 %#x",what,*out,want,color(want));
}

// 火炬之光3 形状：小虚拟池（远小于应用池），先挂尾部、再挂头部，两段的物理偏移 − 虚拟偏移不同（旧路第二段报「non-contiguous」并失败）
static void two_runs(void) {
    phase="小虚拟池两段不连续映射：贴图 / 缓冲读到各自的物理块"; NVNmemoryPool v; vpool_init(&v,3*BLOCK);
    CHECK(map(&v,BLOCK,5,BLOCK),"尾段（虚拟 1 块 ← 物理块 5）映射成功");
    CHECK(map(&v,0,9,BLOCK),"头段（虚拟 0 块 ← 物理块 9，基址与尾段不同）映射成功");
    NVNtexture t; tex_init(&t,&v,0); tex_count(&t,9,5,"贴图 [0, 2 块) 一半来自块 9、一半来自块 5");
    buf_check(&v,0x40,9,"缓冲地址 +0x40"); buf_check(&v,BLOCK+0x80,5,"缓冲地址 +1 块 +0x80");
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// 负偏移：第一段挂在虚拟偏移 2 块、物理块 1（旧路别名基址 = 物理池起点 − 1 块，落到物理池前面）；贴图在虚拟 [0, 2 块)，后挂到物理块 20、21
static void negative_base(void) {
    phase="首段别名基址在物理池之前（负偏移）"; NVNmemoryPool v; vpool_init(&v,3*BLOCK);
    CHECK(map(&v,2*BLOCK,1,BLOCK),"虚拟 2 块 ← 物理块 1 映射成功");
    CHECK(map(&v,0,20,2*BLOCK),"虚拟 [0, 2 块) ← 物理块 20–21 映射成功");
    NVNtexture t; tex_init(&t,&v,0); tex_count(&t,20,21,"贴图读到块 20 与块 21，不是物理池前面的内存");
    buf_check(&v,2*BLOCK,1,"缓冲地址 +2 块 = 块 1");
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// 改映射：同一页换挂别的物理块后，贴图再读是新块（页表代次：映射变了要重传）
static void remap(void) {
    phase="同一段换挂物理块后贴图跟着变"; NVNmemoryPool v; vpool_init(&v,2*BLOCK);
    CHECK(map(&v,0,30,2*BLOCK),"虚拟 [0, 2 块) ← 物理块 30–31");
    NVNtexture t; tex_init(&t,&v,0); tex_count(&t,30,31,"第一次读块 30 / 31");
    map_req un={NULL,0,0,BLOCK,0,0}; CHECK(API(nvnMemoryPoolMapVirtual)(&v,1,(const NVNmappingRequest *)&un),"撤掉虚拟 0 块");
    CHECK(map(&v,0,40,BLOCK),"虚拟 0 块改挂物理块 40");
    tex_count(&t,40,31,"再读：头一块变成块 40，后一块仍是块 31");
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// #962：0 字节的请求（游戏按页大小算出 0）照成功、什么都不挂也不撤：原先交给 vm_remap 回 KERN_INVALID_ARGUMENT，整次 MapVirtual 失败
static void zero_size(void) {
    phase="0 字节映射请求照成功、不影响已挂的页"; NVNmemoryPool v; vpool_init(&v,2*BLOCK);
    CHECK(map(&v,0,50,2*BLOCK),"虚拟 [0, 2 块) ← 物理块 50–51");
    CHECK(map(&v,0,60,0),"虚拟 0 起 0 字节 ← 物理块 60：成功");
    map_req un={NULL,0,BLOCK,0,0,0}; CHECK(API(nvnMemoryPoolMapVirtual)(&v,1,(const NVNmappingRequest *)&un),"撤 0 字节：成功");
    NVNtexture t; tex_init(&t,&v,0); tex_count(&t,50,51,"贴图仍读块 50 / 51");
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// Trine 5：96 MB 虚拟池还没映射就建整池缓冲；建成、地址 = 池地址 + 偏移；两个 Map 同真驱动给 NULL
static void buffer_before_map(void) {
    phase="未映射的虚拟池上建缓冲（Trine 5）"; NVNmemoryPool v; vpool_init(&v,0x6000000);
    NVNbufferBuilder bb; NVNbuffer buf; API(nvnBufferBuilderSetDefaults)(&bb); API(nvnBufferBuilderSetDevice)(&bb,&device);
    API(nvnBufferBuilderSetStorage)(&bb,&v,0x10000,0x5ff0000);
    CHECK(API(nvnBufferInitialize)(&buf,&bb),"BufferInitialize 成功");
    NVNbufferAddress pa=API(nvnMemoryPoolGetBufferAddress)(&v), ba=API(nvnBufferGetAddress)(&buf);
    CHECK(pa!=0 && (pa&0xFFFF)==0 && ba==pa+0x10000,"池地址 %#llx（64 KB 对齐、非 0），缓冲地址 %#llx = 池 + 0x10000",(unsigned long long)pa,(unsigned long long)ba);
    CHECK(API(nvnBufferGetMemoryPool)(&buf)==&v,"缓冲的池是这个虚拟池");
    CHECK(API(nvnMemoryPoolMap)(&v)==NULL,"虚拟池 Map = NULL（真驱动 mov x0, xzr）");
    CHECK(API(nvnBufferMap)(&buf)==NULL,"虚拟池上缓冲 Map = NULL（转调池 Map）");
    CHECK(map(&v,0x10000,3,BLOCK),"之后再挂物理块 3");
    buf_check(&v,0x10000+0x100,3,"缓冲地址读到块 3");
    API(nvnBufferFinalize)(&buf); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// 无人深空：52 GB 虚拟池，预留只有 1 GB（复现 iPhone 地址约束，缺省），在约 2 GB 偏移挂页、放贴图：贴图经页表读到物理块；池 Map 仍是 NULL；存储类别非 0（游戏据此不走 Map 直写）
static void beyond_reservation(void) {
    phase="超出预留段的映射（无人深空 52 GB 池，偏移 0x80010000）"; NVNmemoryPool v; vpool_init(&v,0xd00000000ull);
    CHECK(map(&v,0x80010000,12,2*BLOCK),"虚拟 0x80010000 起 2 块 ← 物理块 12–13 映射成功");
    NVNtexture t; tex_init(&t,&v,0x80010000); tex_count(&t,12,13,"贴图读到块 12 与块 13");
    CHECK(API(nvnMemoryPoolMap)(&v)==NULL,"虚拟池 Map = NULL");
    // 游戏按存储类别选上传路：0 = CPU 经 Map 直写（真机不走，Map 为 NULL 即崩）；真驱动恒回 0x100 | kind（sdk+0x4b6834 `mov w8, #0x100; bfxil`）
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,W,H); API(nvnTextureBuilderSetLevels)(&b,8); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    unsigned bsc=(unsigned)API(nvnTextureBuilderGetStorageClass)(&b), tsc=(unsigned)API(nvnTextureGetStorageClass)(&t);
    CHECK((bsc&~0xFFu)==0x100,"TextureBuilderGetStorageClass = %#x，期望 0x100..0x1ff（非 0）",bsc);
    CHECK((tsc&~0xFFu)==0x100,"TextureGetStorageClass = %#x，期望 0x100..0x1ff（非 0）",tsc);
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// 很多小虚拟池同时活着（火炬之光3 一局建 1140 个、同时几百个；旧表 4 格）：每个都按自己的页表读
static void many_pools(void) {
    phase="300 个小虚拟池同时活着"; enum { N = 300 }; static NVNmemoryPool v[N];
    int ok=1; for (int i=0; i<N; i++) { vpool_init(&v[i],2*BLOCK); ok&=map(&v[i],0,i%32,BLOCK); ok&=map(&v[i],BLOCK,32+i%32,BLOCK); }
    CHECK(ok,"300 个池 × 2 段全部映射成功");
    for (int i=0; i<N; i+=37) { char w[64]; snprintf(w,sizeof w,"池 %d 头一块",i); buf_check(&v[i],0x20,i%32,w); snprintf(w,sizeof w,"池 %d 后一块",i); buf_check(&v[i],BLOCK+0x20,32+i%32,w); }
    for (int i=0; i<N; i++) API(nvnMemoryPoolFinalize)(&v[i]);
    cases++;
}
// 帧录 / 帧回放：虚拟池同址重建（hle_nvn.c s2a_hle_vpool_save / load，11-05 旷野之息唯一的虚拟池不在录像里，回放读到别的映射或 SIGBUS）。本进程带 S2A_CMD_ARENA=1 当录的进程。期望手写：
//   ① 池基址落在虚拟池区（runtime/src/vawin.c）；② 映射两段：头一块 ← 物理块 3（宿主页对齐：别名，GPU 可读）、0x11000+0x2000 ← 物理块 7（不对齐：只进页表）→ 存 1 个；
//   ③ 池对象快照 → Finalize（池没了）→ 对象写回（回放放回游戏内存）→ 读录像：重建 1 个、页表读两段 = 块 3 / 块 7 的色、GPU 经别名读头一块 = 块 3 的色；
//   ④ 子进程当回放进程（S2A_FRAME_REPLAY：区只占不切）：同址整段是空保留。旧实现（池地址 mmap(NULL)、录像不带虚拟池）①③④红
extern int s2a_hle_vpool_save(FILE *f); extern int s2a_hle_vpool_load(FILE *f); extern int s2a_vp_arena_has(const void *p, uint64_t n);
extern int nvn_sparse_pool(const void *pool); extern uint64_t nvn_sparse_copy(const void *pool, void *dst, uint64_t a, uint64_t n);
extern int nvn_gva_snapshot(uint64_t *out, int cap); extern void nvn_gva_restore(const uint64_t *t, int n);
extern char **environ;
static int replay_check(uint64_t a, uint64_t n) {
    vm_address_t r = (vm_address_t)a; vm_size_t rs = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj = MACH_PORT_NULL;
    int in = s2a_vp_arena_has((const void *)(uintptr_t)a, n), got = vm_region_64(mach_task_self(), &r, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) == KERN_SUCCESS;
    int empty = got && r <= a && a + n <= r + rs && info.protection == VM_PROT_NONE;
    if (!in || !empty) fprintf(stderr, "虚拟池 %#llx+%#llx：在回放进程虚拟池区里 %d、是空保留 %d\n", (unsigned long long)a, (unsigned long long)n, in, empty);
    return in && empty ? 0 : 1;
}
static void frame_rec(void) {
    phase="帧录 / 回放：虚拟池同址重建"; const char *self = getenv("T_NVN_VPOOL_SELF");
    static NVNmemoryPool v; vpool_init(&v,4*BLOCK);
    REQUIRE(map(&v,0,3,BLOCK)); REQUIRE(map(&v,BLOCK+0x1000,7,0x2000));
    uint64_t base=(uint64_t)(uintptr_t)((const pool_t *)&v)->mem;   // 池的宿主基址（贴图 / 缓冲的 CPU 地址 = 它 + 偏移；GPU 地址另算）
    CHECK(s2a_vp_arena_has((const void *)(uintptr_t)base,4*BLOCK),"① 池基址 %#llx 在虚拟池区里",(unsigned long long)base);
    char path[]="/tmp/t_nvn_vpool_rec_XXXXXX"; int fd=mkstemp(path); REQUIRE(fd>=0); FILE *f=fdopen(fd,"wb"); REQUIRE(f);
    int ns=s2a_hle_vpool_save(f); fclose(f);
    CHECK(ns==1,"② 存 %d 个（期望 1）",ns);
    static uint64_t gt[3*4096]; int ng=nvn_gva_snapshot(gt,4096);   // 回放另由 state.bin 放回 GPU 地址表（fr_restore_state），这里照同一顺序：先虚拟池、再地址表
    NVNmemoryPool snap=v; API(nvnMemoryPoolFinalize)(&v);
    CHECK(!nvn_sparse_pool(&v),"Finalize 后池不再登记");
    v=snap; f=fopen(path,"rb"); REQUIRE(f); int nl=s2a_hle_vpool_load(f); fclose(f); unlink(path); nvn_gva_restore(gt,ng);
    uint32_t a=0,b=0; nvn_sparse_copy(&v,&a,base+0x20,4); nvn_sparse_copy(&v,&b,base+BLOCK+0x1000+0x20,4);
    CHECK(nl==1 && nvn_sparse_pool(&v),"③ 重建 %d 个（期望 1）、池已登记 %d",nl,nvn_sparse_pool(&v));
    CHECK(a==color(3) && b==color(7),"③ 页表读回 %#x / %#x，期望块 3 %#x / 块 7 %#x",a,b,color(3),color(7));
    buf_check(&v,0x20,3,"③ GPU 经别名读头一块");
    if (self) { char sa[24], sn[24]; snprintf(sa,sizeof sa,"%#llx",(unsigned long long)base); snprintf(sn,sizeof sn,"%#llx",(unsigned long long)(4*BLOCK));
        char *av[]={(char *)self,"--replay-check",sa,sn,NULL}; pid_t pid; int st=-1;
        setenv("S2A_FRAME_REPLAY","/nonexistent/t_nvn_vpool",1);
        REQUIRE(posix_spawn(&pid,self,NULL,NULL,av,environ)==0); REQUIRE(waitpid(pid,&st,0)==pid); unsetenv("S2A_FRAME_REPLAY");
        CHECK(WIFEXITED(st) && WEXITSTATUS(st)==0,"④ 回放进程里同址是空保留（退出 %d）",WIFEXITED(st)?WEXITSTATUS(st):-1); }
    API(nvnMemoryPoolFinalize)(&v); cases++;
}
// 宿主低区被切碎、最大空洞 511 MB（S2A_VPOOL_HOLE_MB=511，11-06 FC26 真机）：512 MB 虚拟池。期望按 NVN 语义手写：池照常建成，
//   预留内（偏移 0x100000）和预留外（偏移 0x18000000 = 384 MB，大于减半后的 256 MB）两段映射都成功；预留内 GPU 按缓冲地址读到物理块，
//   预留外放贴图经页表读到物理块（预留外的缓冲没有宿主地址，是 beyond_reservation 那支既有的边界，不在本例）。
//   旧实现：512 MB 预留失败整池放弃，两段 MapVirtual 都被拒（只有 >1 GB 才退一档）。子进程跑：空洞开关进程内只读一次，且不能带帧录区（区里取址不经空洞）
static void hole_511(void) {
    phase="最大空洞 511 MB 时的 512 MB 虚拟池"; NVNmemoryPool v; vpool_init(&v,0x20000000);
    CHECK(map(&v,0x100000,7,BLOCK),"预留内 0x100000 ← 物理块 7 映射成功");
    CHECK(map(&v,0x18000000,8,2*BLOCK),"预留外 0x18000000 起 2 块 ← 物理块 8–9 映射成功");
    buf_check(&v,0x100000+0x40,7,"缓冲地址 0x100040 读到块 7");
    NVNtexture t; tex_init(&t,&v,0x18000000); tex_count(&t,8,9,"预留外贴图读到块 8 与块 9");
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
static void fragmented(void) {
    phase="低区碎片（子进程 S2A_VPOOL_HOLE_MB=511）"; const char *self=getenv("T_NVN_VPOOL_SELF"); REQUIRE(self);
    char *av[]={(char *)self,"--hole",NULL}; pid_t pid; int st=-1;
    setenv("S2A_VPOOL_HOLE_MB","511",1); unsetenv("S2A_CMD_ARENA");
    REQUIRE(posix_spawn(&pid,self,NULL,NULL,av,environ)==0); REQUIRE(waitpid(pid,&st,0)==pid);
    setenv("S2A_CMD_ARENA","1",1); unsetenv("S2A_VPOOL_HOLE_MB");
    CHECK(WIFEXITED(st) && WEXITSTATUS(st)==0,"子进程（512 MB 池、最大空洞 511 MB）各项全过（退出 %d）",WIFEXITED(st)?WEXITSTATUS(st):-1); cases++;
}
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);   // 逐行出：旧实现上某例崩了，前面各例的结论仍在
    if (argc==4 && !strcmp(argv[1],"--replay-check")) return replay_check(strtoull(argv[2],NULL,0),strtoull(argv[3],NULL,0));
    if (argc==2 && !strcmp(argv[1],"--hole")) { setup(); hole_511(); printf("%s 子进程 hole_511：%u 项检查、%u 项不符\n",fails?"✗":"✓",checks,fails); return fails?1:0; }
    if (!getenv("S2A_CMD_ARENA")) { setenv("S2A_CMD_ARENA","1",1); setenv("T_NVN_VPOOL_SELF",argv[0],1); execv(argv[0],argv); perror("execv"); return 1; }   // 帧录区在构造期按环境变量占
    static const struct { const char *name; void (*fn)(void); } all[]={{"two_runs",two_runs},{"negative_base",negative_base},{"remap",remap},{"buffer_before_map",buffer_before_map},{"beyond_reservation",beyond_reservation},{"many_pools",many_pools},{"fragmented",fragmented},{"frame_rec",frame_rec},{"zero_size",zero_size}};
    if (argc>2) { fprintf(stderr,"用法：%s [例名]\n",argv[0]); return 2; }
    setup();
    int ran=0; for (size_t i=0; i<sizeof all/sizeof *all; i++) if (argc==1 || !strcmp(argv[1],all[i].name)) { all[i].fn(); ran++; }
    if (!ran) { fprintf(stderr,"没有叫 %s 的例\n",argv[1]); return 2; }
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&phys); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device);
    { char p[512]; snprintf(p,sizeof p,"%s/shaders/direct/game.tsv",data_dir); unlink(p); snprintf(p,sizeof p,"%s/shaders/direct",data_dir); rmdir(p); snprintf(p,sizeof p,"%s/shaders",data_dir); rmdir(p); rmdir(data_dir); }
    if (fails) { printf("✗ t_nvn_vpool：%u 项检查里 %u 项不符\n",checks,fails); return 1; }
    printf("✓ t_nvn_vpool：%u 例 %u 项检查全过（虚拟池一律按页表：不连续映射、负偏移、改映射、未映射建缓冲、超出预留、多池、低区碎片、帧录同址重建）\n",cases,checks); return 0;
}}
