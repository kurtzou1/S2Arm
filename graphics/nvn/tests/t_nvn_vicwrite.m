// 交给 NvRm 硬件写的贴图（hle_nvn.c nvnTextureGetNvRmSurfaceNVX 末尾 nvn_be_tex_cpu_written，11-03 幻想水浒 I&II HD 开场 VP9 影片不出帧）：
//   公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。期望值按 Switch 语义手写，不由被测实现推出：贴图被 GPU 用过、再交出 NvRmSurface，之后 VIC 往它的存储写新字节，
//   GPU 下次读必须是 VIC 写的字节（Switch 上 VIC / GPU 读写同一份内存），每写一帧都如此。
// VIC 的写在宿主是 s2a_track_write → 写跟踪放开只读页、记页的写入代号；单测用同一个入口 dm_guest_write_prepare 后 memset（单测没装缺页处理）。
// 各例都选兜底路（ft_add / nvn_ft_poll）排除在外的形态，旧代码里贴图一直是 GPU 私有贴图、读到旧色（反证）：
//   A CPU_NO_ACCESS 池；B CPU_UNCACHED 池上带 COMPRESSIBLE 的贴图；C 交出前当过渲染目标（GPU 清过，宿主侧贴图带渲染目标用途）。
// C 另核「GPU 写过的部分不被游戏内存盖掉」：VIC 写一帧后游戏再用 GPU 清成红，然后 CPU 只写同一 16 KB 页里贴图之外的字节 → 仍读到红（贴图自己的字节没变，不重传）；
//   VIC 再写一帧 → 读到 VIC 的新字节（真机上 VIC 的写同样盖掉 GPU 清的内容）。
// D 线性贴图（不登记，建在池缓冲上零拷贝）：VIC 写后直接读到新字节，与改动前相同。
// 存储整段填同一个 4 字节色值，RGBA8 每个纹素都是它，与块线性布局无关。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
extern void dm_guest_write_prepare(void *addr, size_t len);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool cmd_pool, noaccess, uncached;
static NVNcommandBuffer commands;
static void *cmd_storage, *noaccess_storage, *uncached_storage;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, SIDE = 8 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
// 服务层的 nvmap 句柄入口（pool_nvmap 按名查）：单测回固定句柄
__attribute__((visibility("default"), used)) int S2A_NvMapFromGuest(uint64_t address, uint32_t size) { (void)address; (void)size; return 42; }
static void pool_init(NVNmemoryPool *p, void **storage, int flags) {
    REQUIRE(posix_memalign(storage,65536,POOL_SIZE)==0); memset(*storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,*storage,POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb,flags);
    REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    pool_init(&cmd_pool,&cmd_storage,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    pool_init(&noaccess,&noaccess_storage,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    pool_init(&uncached,&uncached_storage,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static size_t make(NVNtexture *t, NVNmemoryPool *p, size_t off, int flags, int stride) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetFlags)(&b,flags);
    if (stride) API(nvnTextureBuilderSetStride)(&b,stride);
    // 存储不超过 64 KiB：真驱动对可压缩的 32 位色贴图按 64 KiB 对齐、取整（8 × 8 的 B 例答 0x10000，见 nvn_tex.c），各例偏移相隔 0x10000，不重叠
    size_t bytes=API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(bytes && bytes<=0x10000 && off+bytes<=READ_OFFSET);
    API(nvnTextureBuilderSetStorage)(&b,p,(ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(t,&b)); return bytes;
}
// 宿主写游戏内存（VIC 的写、或 CPU 写）：先经写跟踪入口，再写
static void host_fill(uint8_t *at, size_t bytes, const uint8_t rgba[4]) { dm_guest_write_prepare(at,bytes); for (size_t i=0; i<bytes; i+=4) memcpy(at+i,rgba,4); }
// GPU 把整张贴图拷到命令池 READ_OFFSET，逐纹素比 want
static void read_check(NVNtexture *t, const uint8_t want[4], const char *what) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,SIDE*SIDE*4);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    if (!want) return;   // 只为让宿主建好 GPU 侧贴图
    const uint8_t *p=(const uint8_t *)cmd_storage+READ_OFFSET; int bad=0;
    for (int i=0; i<SIDE*SIDE; i++) bad+=memcmp(p+4*i,want,4)!=0;
    checks++; if (bad) { fails++; printf("FAIL %s：%s，%d/%d 纹素不符（第 0 个 %02x %02x %02x %02x，期望 %02x %02x %02x %02x）\n",phase,what,bad,SIDE*SIDE,p[0],p[1],p[2],p[3],want[0],want[1],want[2],want[3]); }
}
static void gpu_clear(NVNtexture *t, const float c[4]) { NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; begin(); API(nvnCommandBufferClearTexture)(&commands,t,NULL,&whole,c,15); submit(); }
static const uint8_t old_rgba[4]={0x11,0x22,0x33,0x44}, f1[4]={0x55,0x66,0x77,0x88}, f2[4]={0x99,0xAA,0xBB,0xCC}, red[4]={0xFF,0,0,0xFF}, other[4]={0x0F,0x1E,0x2D,0x3C};
static const float red_f[4]={1,0,0,1};
typedef void (*nvx_fn)(const NVNtexture *, const void *, void *);
static nvx_fn nvx;
static void export_surface(NVNtexture *t) { uint8_t s[88]; nvx(t,NULL,s); }
// 贴图先被 GPU 读过（宿主建好 GPU 侧贴图），交出 NvRmSurface，VIC 连写两帧，每帧后 GPU 读
static void vic_frames(NVNmemoryPool *p, void *storage, size_t off, int flags, int rt_first, const char *name) {
    phase=name; uint8_t *at=(uint8_t *)storage+off;
    NVNtexture t; size_t bytes=make(&t,p,off,flags,0);
    host_fill(at,bytes,old_rgba);
    if (rt_first) { gpu_clear(&t,red_f); read_check(&t,red,"交出前 GPU 清成红"); }
    else if (flags & NVN_TEXTURE_FLAGS_COMPRESSIBLE) read_check(&t,NULL,"交出前读一次（建 GPU 侧贴图；可压缩贴图的初始内容真机上没定义，不核）");
    else read_check(&t,old_rgba,"交出前读到存储里的色");
    export_surface(&t);
    host_fill(at,bytes,f1); read_check(&t,f1,"VIC 写第 1 帧后读到第 1 帧");
    host_fill(at,bytes,f2); read_check(&t,f2,"VIC 写第 2 帧后读到第 2 帧");
    API(nvnTextureFinalize)(&t); cases++;
}
// C 续：GPU 写过的部分保留；贴图自己的字节被 VIC 改写才重传
static void gpu_kept(void) {
    phase="交出后游戏 GPU 清过：同页别处的 CPU 写不盖掉 GPU 内容，VIC 再写才盖";
    size_t off=0x30000; uint8_t *at=(uint8_t *)uncached_storage+off;
    NVNtexture t; size_t bytes=make(&t,&uncached,off,0,0);
    host_fill(at,bytes,old_rgba); read_check(&t,old_rgba,"交出前读到存储里的色");
    export_surface(&t);
    host_fill(at,bytes,f1); read_check(&t,f1,"VIC 写第 1 帧");
    gpu_clear(&t,red_f); read_check(&t,red,"游戏 GPU 清成红");
    host_fill(at+8192,64,other); read_check(&t,red,"同页贴图之外的 CPU 写之后仍是红");
    host_fill(at,bytes,f2); read_check(&t,f2,"VIC 写第 2 帧盖掉红");
    API(nvnTextureFinalize)(&t); cases++;
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argv; if (argc!=1) { fprintf(stderr,"用法：%s\n",argv[0]); return 2; }
    setup(); nvx=(nvx_fn)load("nvnTextureGetNvRmSurfaceNVX");
    vic_frames(&noaccess,noaccess_storage,0x10000,0,0,"A CPU_NO_ACCESS 池里的块线性贴图");
    vic_frames(&uncached,uncached_storage,0x10000,NVN_TEXTURE_FLAGS_COMPRESSIBLE,0,"B CPU_UNCACHED 池上带 COMPRESSIBLE 的贴图");
    vic_frames(&noaccess,noaccess_storage,0x20000,0,1,"C 交出前当过渲染目标（GPU 清过）");
    gpu_kept();
    phase="D 线性贴图（建在池缓冲上，不登记）";
    { size_t off=0x40000; uint8_t *at=(uint8_t *)uncached_storage+off; NVNtexture t; size_t bytes=make(&t,&uncached,off,NVN_TEXTURE_FLAGS_LINEAR,256);
      host_fill(at,bytes,old_rgba); read_check(&t,old_rgba,"交出前读到存储里的色"); export_surface(&t);
      host_fill(at,bytes,f1); read_check(&t,f1,"VIC 写后读到新色"); API(nvnTextureFinalize)(&t); cases++; }
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&noaccess); API(nvnMemoryPoolFinalize)(&uncached); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device);
    if (fails) { printf("✗ t_nvn_vicwrite：%u 项检查里 %u 项不符\n",checks,fails); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_vicwrite：%u 例 %u 项检查全过（交给 NvRm 硬件写的贴图按 VIC 写的字节重传）\n",cases,checks); return 0;
}}
