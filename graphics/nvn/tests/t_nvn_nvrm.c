// nvnTextureGetNvRmSurfaceNVX（织梦岛开场动画的视频播放器把 NVN 纹理交给 NvRm 解码 / VIC 写入）：生产引导 / 登记 / 跳板，真对象与真内存池。
// 期望按游戏 sdk 里真 NVN 驱动的填法手算（sdk+0x4299a0；块线性行距 = NvRmSurfaceComputePitch，行字节按 64 取整，已在本机原样执行其机器码 48 例核过）：
//   +0 宽 +4 高 +8 NvColorFormat +16 布局（1 线性 / 3 块线性）+20 行距 +24 池的 nvmap 句柄 +28 池内偏移 +32 Kind（块线性 0xFE）+36 块高 log2 +56 尺寸，其余 0。
// 池的句柄由服务层导出 S2A_NvMapFromGuest 开（这里用本文件的同名函数顶替：记参数、按序回句柄号），每个池只开一次。
// 反证：旧代码按名查不到这个入口（load 的 CHECK 红）
// 另：nvnSyncInitializeFromNvRmSyncNVX（Metroid Dread）按名可查，同步对象一开始就已发出信号；nvnSyncGetNvRmSyncNVX 导出无效同步点（末尾两例）
// 再另（审计 #1534 P1-47）：GPU 栅栏没完成时 nvnSyncGetNvRmSyncNVX 不报完成——等到完成为止；会话收尾时仍没完成就回假、不写导出。
//   期望按语义手算：栅栏号取远超已提交的 2^40（永远到不了），1.5 秒后别的线程收尾（dm_nvn_request_stop）→ 调用至少等了 1.4 秒、回假、输出 8 字节保持哨兵。
//   旧实现等 1 秒就写 {0xFFFFFFFF, 0} 并回真：红
#include "nvn_protos.h"
#include "nvn_obj.h"
#include <pthread.h>
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static const char *phase = "准备";
static unsigned checks;
static NVNdevice device;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name); CHECK(entry != NULL); return entry;
}
#define API(name) ((NVNT_##name)load(#name))

int dm_nvn_request_stop(void);
static void *stop_later(void *a) { (void)a; usleep(1500000); dm_nvn_request_stop(); return NULL; }   // 会话收尾（同真机切后台 / 重启）：nvn_be_wait 被唤醒放弃
static unsigned nmk; static uint64_t mk_addr[4]; static uint32_t mk_size[4];
__attribute__((visibility("default"), used)) int S2A_NvMapFromGuest(uint64_t address, uint32_t size) {
    CHECK(nmk < 4); mk_addr[nmk] = address; mk_size[nmk] = size; return 41 + (int)++nmk;
}

typedef void (*nvx_fn_fwd)(const NVNtexture *, const void *, void *);
typedef struct { NVNmemoryPool pool; uint8_t *bytes; size_t size; } pool_box;
// 无存储 / 虚拟池（存储是物理池的页、没有单一 nvmap 句柄）：mem 为 NULL 的池，flags 由例子给
static void pool_make_bare(pool_box *p, size_t size, NVNmemoryPoolFlags flags) {
    p->size = size; p->bytes = NULL;
    NVNmemoryPoolBuilder b = {{0}};
    API(nvnMemoryPoolBuilderSetDefaults)(&b); API(nvnMemoryPoolBuilderSetDevice)(&b, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&b, flags);
    API(nvnMemoryPoolBuilderSetStorage)(&b, NULL, size);
    CHECK(API(nvnMemoryPoolInitialize)(&p->pool, &b));
}
// 截 LOG（g_s2a_logfd，runtime/src/native.h 的弱定义、链接后同一个）：调用期间写到临时文件，回读成字符串
extern int g_s2a_logfd;
static char logbuf[8192];
static const char *log_of(nvx_fn_fwd nvx, const NVNtexture *t, uint8_t *out) {
    char path[] = "/tmp/t_nvn_nvrm_log.XXXXXX"; int fd = mkstemp(path); CHECK(fd >= 0); unlink(path);
    int old = g_s2a_logfd; g_s2a_logfd = fd;
    nvx(t, NULL, out);
    g_s2a_logfd = old;
    ssize_t n = pread(fd, logbuf, sizeof logbuf - 1, 0); close(fd); CHECK(n >= 0); logbuf[n] = 0;
    return logbuf;
}
static void pool_make(pool_box *p, size_t size) {
    p->size = size; CHECK(posix_memalign((void **)&p->bytes, 65536, size) == 0); memset(p->bytes, 0, size);
    NVNmemoryPoolBuilder b = {{0}};
    API(nvnMemoryPoolBuilderSetDefaults)(&b); API(nvnMemoryPoolBuilderSetDevice)(&b, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&b, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&b, p->bytes, size);
    CHECK(API(nvnMemoryPoolInitialize)(&p->pool, &b));
}
static void tex_make(NVNtexture *t, pool_box *p, ptrdiff_t off, NVNformat f, int w, int h, NVNtextureFlags flags, ptrdiff_t stride) {
    NVNtextureBuilder b; memset(&b, 0, sizeof b);
    API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, w, h);
    API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, f); API(nvnTextureBuilderSetFlags)(&b, flags);
    if (stride) API(nvnTextureBuilderSetStride)(&b, stride);
    CHECK((size_t)off + API(nvnTextureBuilderGetStorageSize)(&b) <= p->size);
    API(nvnTextureBuilderSetStorage)(&b, &p->pool, off);
    memset(t, 0, sizeof *t); CHECK(API(nvnTextureInitialize)(t, &b));
}
typedef struct { uint32_t w, h; uint64_t cf; uint32_t layout, pitch, hmem, off, kind, bh; uint64_t size; } surf_want;
typedef void (*nvx_fn)(const NVNtexture *, const void *, void *);
static void check_surf(nvx_fn nvx, const NVNtexture *t, const surf_want *e) {
    uint8_t s[96]; memset(s, 0xcd, sizeof s);
    nvx(t, NULL, s);
    uint32_t u[22]; memcpy(u, s, 88); uint64_t cf, size; memcpy(&cf, s + 8, 8); memcpy(&size, s + 56, 8);
    CHECK(u[0] == e->w); CHECK(u[1] == e->h); CHECK(cf == e->cf); CHECK(u[4] == e->layout); CHECK(u[5] == e->pitch);
    CHECK(u[6] == e->hmem); CHECK(u[7] == e->off); CHECK(u[8] == e->kind); CHECK(u[9] == e->bh); CHECK(size == e->size);
    for (int k = 40; k < 56; k++) CHECK(s[k] == 0);
    for (int k = 64; k < 88; k++) CHECK(s[k] == 0);
    for (int k = 88; k < 96; k++) CHECK(s[k] == 0xcd);   // 只写 88 字节
}
int main(void) {
    NVNdeviceBuilder db = {{0}};
    API(nvnDeviceBuilderSetDefaults)(&db); CHECK(API(nvnDeviceInitialize)(&device, &db));
    nvx_fn nvx = (nvx_fn)load("nvnTextureGetNvRmSurfaceNVX");
    pool_box a, b; pool_make(&a, 4 << 20); pool_make(&b, 1 << 20);
    NVNtexture y, uv, rgba, f16;

    phase = "块线性 R8 1280×720（视频 Y 平面），池内偏移 0x10000";
    tex_make(&y, &a, 0x10000, NVN_FORMAT_R8, 1280, 720, 0, 0);
    check_surf(nvx, &y, &(surf_want){1280, 720, 0xE09200408ull, 3, 1280, 42, 0x10000, 0xFE, 4, 1280ull * 768});
    CHECK(nmk == 1 && mk_addr[0] == (uint64_t)(uintptr_t)a.bytes && mk_size[0] == a.size);
    printf("%s：通过\n", phase);

    phase = "块线性 RG8 640×360（UV 平面），同一个池：句柄不重开";
    tex_make(&uv, &a, 0x200000, NVN_FORMAT_RG8, 640, 360, 0, 0);
    check_surf(nvx, &uv, &(surf_want){640, 360, 0xE08440710ull, 3, 1280, 42, 0x200000, 0xFE, 4, 1280ull * 384});
    check_surf(nvx, &y, &(surf_want){1280, 720, 0xE09200408ull, 3, 1280, 42, 0x10000, 0xFE, 4, 1280ull * 768});
    CHECK(nmk == 1);
    printf("%s：通过\n", phase);

    phase = "线性 RGBA8 64×32 行距 256，另一个池";
    tex_make(&rgba, &b, 0, NVN_FORMAT_RGBA8, 64, 32, NVN_TEXTURE_FLAGS_LINEAR, 256);
    check_surf(nvx, &rgba, &(surf_want){64, 32, 0x100532120ull, 1, 256, 43, 0, 0, 0, 256ull * 32});
    CHECK(nmk == 2 && mk_addr[1] == (uint64_t)(uintptr_t)b.bytes && mk_size[1] == b.size);
    printf("%s：通过\n", phase);

    phase = "驱动表里没有的格式（RGBA16F）：颜色格式 0、行距 0、尺寸 0";
    tex_make(&f16, &b, 0x40000, NVN_FORMAT_RGBA16F, 64, 64, 0, 0);
    check_surf(nvx, &f16, &(surf_want){64, 64, 0, 3, 0, 43, 0x40000, 0xFE, 3, 0});   // 64 行 = 8 个 GOB → 块高 8（log2 3）
    printf("%s：通过\n", phase);

    // 句柄 0 的三支按铁律报红（010045B018EC2000 普查：句柄 0 进 nvgr_import_nvrmsurface → NvMap GetId / FromId 失败 → 导入缓冲被释放、播放器照样 NvBlit，sdk 内 SIGSEGV；
    //   原先这三支不出声）。返回语义不变：句柄仍是 0、其余字段照填，不另开 nvmap 句柄。期望按语义手算：报红行含「【红】 nvnTextureGetNvRmSurfaceNVX」与原因。
    //   反证：main 上这三支 return 0 不写日志，strstr 红
    phase = "虚拟池里的纹理：句柄 0 且报红（原因：虚拟池）";
    { pool_box v; pool_make_bare(&v, 1 << 20, NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
      NVNtexture vt; tex_make(&vt, &v, 0x10000, NVN_FORMAT_R8, 256, 64, 0, 0);
      unsigned before = nmk; uint8_t s[88]; memset(s, 0xcd, sizeof s);
      const char *l = log_of(nvx, &vt, s); uint32_t hm; memcpy(&hm, s + 24, 4);
      CHECK(hm == 0); CHECK(nmk == before);
      CHECK(strstr(l, "【红】 nvnTextureGetNvRmSurfaceNVX") != NULL); CHECK(strstr(l, "虚拟池") != NULL);
      printf("%s：通过\n", phase); }

    phase = "池没有存储（非虚拟、存储为空）：句柄 0 且报红（原因：池没有存储）";
    { pool_box e; pool_make_bare(&e, 1 << 20, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
      NVNtexture et; tex_make(&et, &e, 0, NVN_FORMAT_R8, 256, 64, 0, 0);
      unsigned before = nmk; uint8_t s[88]; memset(s, 0xcd, sizeof s);
      const char *l = log_of(nvx, &et, s); uint32_t hm; memcpy(&hm, s + 24, 4);
      CHECK(hm == 0); CHECK(nmk == before);
      CHECK(strstr(l, "【红】 nvnTextureGetNvRmSurfaceNVX") != NULL); CHECK(strstr(l, "池没有存储") != NULL);
      printf("%s：通过\n", phase); }

    phase = "有句柄的池不报红（负控：正常路径不多出红行）";
    { uint8_t s[88]; const char *l = log_of(nvx, &y, s); uint32_t hm; memcpy(&hm, s + 24, 4);
      CHECK(hm == 42); CHECK(strstr(l, "【红】") == NULL);
      printf("%s：通过\n", phase); }

    // nvnSyncInitializeFromNvRmSyncNVX（10-30 Metroid Dread 按名查不到、拿空指针崩在 subsdk0）：按名查得到；初始化成功，等待（超时 0）即返回「已发出信号」
    //   （视频解码等引擎在服务层的 CPU 上做完才交出 fence，同步对象一开始就是已完成）。反证：旧代码查这个名字得空指针（load 的 CHECK 红）
    phase = "nvnSyncInitializeFromNvRmSyncNVX：按名可查、一开始就已发出信号";
    { typedef NVNboolean (*init_fn)(NVNsync *, NVNdevice *, const void *);
      init_fn init = (init_fn)load("nvnSyncInitializeFromNvRmSyncNVX");
      NVNsync sy; memset(&sy, 0xcc, sizeof sy); const uint32_t rm[2] = {7, 1234};
      CHECK(init(&sy, &device, rm));
      CHECK(API(nvnSyncWait)(&sy, 0) == NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED);
      printf("%s：通过\n", phase); }

    // nvnSyncGetNvRmSyncNVX（10-31 直连缺陷表：蓝精灵 / 塞尔达智慧的再现 / 密特罗德 Dread 按名查不到）：按名可查；导出的是无效同步点 {0xFFFFFFFF, 0}（Ryujinx NvFence.InvalidSyncPointId，
    //   使用方不等），返回真；没有 fence 的同步对象同样导出。反证：旧代码查这个名字得空指针（load 的 CHECK 红）
    phase = "nvnSyncGetNvRmSyncNVX：按名可查、导出无效同步点";
    { typedef NVNboolean (*init_fn)(NVNsync *, NVNdevice *, const void *); typedef NVNboolean (*get_fn)(const NVNsync *, void *);
      init_fn init = (init_fn)load("nvnSyncInitializeFromNvRmSyncNVX"); get_fn get = (get_fn)load("nvnSyncGetNvRmSyncNVX");
      NVNsync sy; memset(&sy, 0xcc, sizeof sy); const uint32_t rm[2] = {7, 1234}; CHECK(init(&sy, &device, rm));
      uint32_t out[3] = {1, 2, 0xA5A5A5A5u}; CHECK(get(&sy, out));
      CHECK(out[0] == 0xFFFFFFFFu && out[1] == 0); CHECK(out[2] == 0xA5A5A5A5u);   // 只写 8 字节
      printf("%s：通过\n", phase); }

    phase = "nvnSyncGetNvRmSyncNVX：GPU 栅栏没完成不导出「已触发」（审计 #1534 P1-47）";
    { typedef NVNboolean (*get_fn)(const NVNsync *, void *); get_fn get = (get_fn)load("nvnSyncGetNvRmSyncNVX");
      NVNsync sy; memset(&sy, 0, sizeof sy); CHECK(API(nvnSyncInitialize)(&sy, &device));
      sync_publish((sync_t *)&sy, 1ull << 40);   // 一个永远到不了的栅栏号（本进程只提交过个位数）
      pthread_t th; CHECK(pthread_create(&th, NULL, stop_later, NULL) == 0);
      uint32_t out[2] = {0x5A5A5A5Au, 0x5A5A5A5Au}; struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
      NVNboolean r = get(&sy, out); clock_gettime(CLOCK_MONOTONIC, &t1); pthread_join(th, NULL);
      double el = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
      CHECK(el >= 1.4);                                                    // 没在 1 秒处放弃
      CHECK(!r);                                                           // 没等到：回假
      CHECK(out[0] == 0x5A5A5A5Au && out[1] == 0x5A5A5A5Au);               // 不写「无效同步点 = 已触发」
      printf("%s：通过（等了 %.2f 秒）\n", phase, el); }

    printf("✓ t_nvn_nvrm：%u 条断言（10 例，句柄开 %u 次）\n", checks, nmk);
    return 0;
}
