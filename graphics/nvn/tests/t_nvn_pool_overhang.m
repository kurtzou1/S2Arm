// 池上伸出池尾的缓冲对象（D-6VG6，11-25）：公开 NVN 接口 → 真实 Metal 提交 → 读回 CPU 存储。期望值按 Switch 语义手写，不由被测实现推出：
//   缓冲对象 = 池 + 偏移 + 大小的视图，建时不查是否越过池尾；真机上它整段都有缓冲区地址，GPU 读写越过池尾的部分落在池存储之后同一处内存。
//   夹具同旷野之息拍照存图那一对：池 0x195000 字节、缓冲对象偏移 0、大小 0x1b0000（尾部 0x1b000 = 108 KB 在池外）；池存储之后的内存属于同一块映射、可读写。
//   ① GPU 拷贝写进缓冲对象尾部（池尾之后 0x1a0000 处）：读回存储同一偏移等于源；② GPU 从尾部读回池内：等于尾部内容。
//   Switch 1（缓冲区地址在宿主分的 GPU 地址窗口里）与 Switch 2（缓冲区地址 = 存储 CPU 地址）各跑一遍。
//   改前：尾部不在池的 Metal 缓冲里、Switch 1 的 GPU 地址段也只到池尾——拷贝目标解析不到被跳过，尾部保持 0xA5，① 判红
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
uint64_t s2a_npdm_window_need(const char *npdm);   // runtime/src/svc_mem.c：读 NPDM，Switch 2 的 ACID 布局置平台位（nvn2_on）
extern int nvn2_on(void);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNcommandBuffer commands;
static unsigned checks;
static const char *phase = "初始化";
enum { CMD_POOL = 4 << 20, COMMAND_SIZE = 1 << 20, POOL = 0x195000, BUF = 0x1b0000, BACKING = 0x200000, SRC = 0x1000, TAIL = 0x1a0000, BACK = 0x2000, N = 4096 };
#define REQUIRE(x) do { checks++; if (!(x)) { printf("✗ t_nvn_pool_overhang：[%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void ounce_on(void) {   // 同 t_nvn_gva：写一份 Switch 2 布局的 NPDM，经原生层读一遍置平台位
    char path[1024]; const char *td = getenv("TMPDIR"); snprintf(path, sizeof path, "%s/t_nvn_pool_overhang_npdm_XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); REQUIRE(fd >= 0);
    static uint8_t npdm[0x80 + 0x400]; memcpy(npdm, "META", 4); uint32_t acid = 0x80; memcpy(npdm + 0x78, &acid, 4); memcpy(npdm + 0x80 + 0x300, "ACID", 4);
    REQUIRE(write(fd, npdm, sizeof npdm) == (ssize_t)sizeof npdm);
    close(fd); s2a_npdm_window_need(path); unlink(path);
}
static NVNmemoryPool make_pool(uint8_t *mem, size_t size) {
    NVNmemoryPool p; NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, size);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&p, &pb));
    return p;
}
static void copy(NVNmemoryPool *cmd, NVNbufferAddress from, NVNbufferAddress to) {
    API(nvnCommandBufferAddCommandMemory)(&commands, cmd, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
    API(nvnCommandBufferCopyBufferToBuffer)(&commands, from, to, N, 0);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void run(NVNmemoryPool *cmd, const char *what) {
    void *raw; REQUIRE(posix_memalign(&raw, 65536, BACKING) == 0);   // 池存储之后到 BACKING 仍是同一块可读写映射（同游戏堆里池后面的内存）
    uint8_t *mem = raw; memset(mem, 0, BACKING); memset(mem + POOL, 0xA5, BACKING - POOL);
    NVNmemoryPool p = make_pool(mem, POOL);
    NVNbufferBuilder bb; API(nvnBufferBuilderSetDefaults)(&bb); API(nvnBufferBuilderSetDevice)(&bb, &device);
    API(nvnBufferBuilderSetStorage)(&bb, &p, 0, BUF); NVNbuffer buf; REQUIRE(API(nvnBufferInitialize)(&buf, &bb));
    NVNbufferAddress ba = API(nvnBufferGetAddress)(&buf);
    for (int i = 0; i < N; i++) mem[SRC + i] = (uint8_t)(i * 13 + 5);
    char ph[160];
    snprintf(ph, sizeof ph, "%s ①：GPU 写进缓冲对象尾部（池尾之后 %#x）", what, TAIL); phase = ph;
    copy(cmd, ba + SRC, ba + TAIL);
    REQUIRE(memcmp(mem + TAIL, mem + SRC, N) == 0);
    snprintf(ph, sizeof ph, "%s ②：GPU 从缓冲对象尾部读回池内", what); phase = ph;
    copy(cmd, ba + TAIL, ba + BACK);
    REQUIRE(memcmp(mem + BACK, mem + TAIL, N) == 0);
    API(nvnBufferFinalize)(&buf); API(nvnMemoryPoolFinalize)(&p);
}
int main(void) {
    @autoreleasepool {
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
        NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
        REQUIRE(API(nvnQueueInitialize)(&queue, &qb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
        static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
        void *cm; REQUIRE(posix_memalign(&cm, 65536, CMD_POOL) == 0); memset(cm, 0, CMD_POOL);
        NVNmemoryPool cmd = make_pool(cm, CMD_POOL);
        run(&cmd, "Switch 1（池 0x195000、缓冲对象 0x1b0000）");
        ounce_on(); phase = "平台位"; REQUIRE(nvn2_on());
        run(&cmd, "Switch 2（池 0x195000、缓冲对象 0x1b0000）");
        printf("✓ t_nvn_pool_overhang：全部通过（%u 项检查）\n", checks);
    }
    return 0;
}
