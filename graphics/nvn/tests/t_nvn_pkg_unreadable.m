// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// 有池指针、存储却不在池登记缓冲里、而且读不了的贴图走 CPU 上传（诊断#a4a895，0.4.1 仍崩：#b5a081 的截短只在没有池指针时做）。
//   现场：「swizzled texture storage is not in a memory pool; falling back to the CPU」之后，块线性拷贝（nvn_deswizzle.c move）直接从存储起点读，
//   起点落在没映射的 2 MB 块里（当前权限 ---），提交线程 SIGBUS。
// 构造（期望按语义手写，与被测实现无关）：16×16 RGBA8 单级二维贴图，池指针指向一块可读的假池（存储不在它里面），存储指向一页 PROT_NONE 的内存。
//   ① pkg_upload 不崩、建出 16×16 的贴图（读不了的字节按 0）；② 打出那一行红「only 0 of its 1024 storage bytes are mapped」。
// 反证：同一用例编改前的 nvn_mtl.m（截短只在 !t->pool 时做）→ 进程在 move 里 SIGBUS，测试走不到汇总行。
static int g_stage_fail;   // ⑨：>0 时 CPU 上传暂存的下一次分配给 nil（模拟分配不到）
#define UP_CPU_STAGE_NEW(n) (g_stage_fail > 0 ? (g_stage_fail--, (id<MTLBuffer>)nil) : [g_dev newBufferWithLength:(n) options:MTLResourceStorageModeShared])
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <sys/mman.h>

extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device; static NVNqueue queue;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
static unsigned checks, fails;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    NVNdeviceBuilder db; ((NVNT_nvnDeviceBuilderSetDefaults)h_nvnBootstrapLoader("nvnDeviceBuilderSetDefaults"))(&db);
    REQUIRE(((NVNT_nvnDeviceInitialize)h_nvnBootstrapLoader("nvnDeviceInitialize"))(&device, &db));
    NVNqueueBuilder qb; ((NVNT_nvnQueueBuilderSetDefaults)h_nvnBootstrapLoader("nvnQueueBuilderSetDefaults"))(&qb); ((NVNT_nvnQueueBuilderSetDevice)h_nvnBootstrapLoader("nvnQueueBuilderSetDevice"))(&qb, &device);
    REQUIRE(((NVNT_nvnQueueInitialize)h_nvnBootstrapLoader("nvnQueueInitialize"))(&queue, &qb));
    mtl_init();   // Metal 设备（真机上起局时建）
    size_t pg = (size_t)getpagesize();
    // 现场：存储起点在池基址前面、落在没映射的块里（「extends past the pool」那条不成立，走的是「not in a memory pool」）：一页 PROT_NONE 紧挨在池前
    uint8_t *reg = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(reg != MAP_FAILED);
    REQUIRE(!mprotect(reg, pg, PROT_NONE)); uint8_t *hole = reg;
    static pool_t pool; pool.mem = reg + pg; pool.size = 2 * pg;   // 池指针非空，贴图存储不在它里面
    static tex_t t; memset(&t, 0, sizeof t);
    t.d.target = 1; t.d.format = 0x25; t.d.width = 16; t.d.height = 16; t.d.depth = 1; t.d.levels = 1;
    nvn_tex_layout(&t.d, &t.L); t.mem = hole; t.pool = &pool; t.serial = 1;
    int pfd[2]; REQUIRE(!pipe(pfd)); int keep = dup(2); dup2(pfd[1], 2); close(pfd[1]);   // 收 stderr 里的红行
    uint64_t stamp = 0; id<MTLTexture> mt = pkg_upload(&t, &stamp, nil, NULL, NULL, 0);
    fflush(stderr); dup2(keep, 2); close(keep);
    char buf[65536]; ssize_t k = read(pfd[0], buf, sizeof buf - 1); buf[k > 0 ? k : 0] = 0; close(pfd[0]);
    VERIFY(mt && mt.width == 16 && mt.height == 16, "① 存储读不了：不崩、建出 16×16 贴图（实测 %lux%lu）", (unsigned long)mt.width, (unsigned long)mt.height);
    if (!mt || !strstr(buf, "only 0 of its")) fputs(buf, stdout);   // 不符时把收来的 stderr 打出来
    VERIFY(strstr(buf, "only 0 of its") != NULL, "② 打出「只映射了 0 字节、其余按 0 读」那一行红");
    {   // ③ 重传（提交线程上直接逐页哈希）：同一张读不了的存储，要哈希（ph 非空、不交后台）也不崩，哈希判作废（PH_BAD）
        uint64_t *ph3 = NULL; uint32_t n3 = 0; id<MTLTexture> m3 = pkg_upload(&t, &stamp, nil, &ph3, &n3, 0);
        VERIFY(m3 && ph3 && n3 && atomic_load(ph_state(ph3, n3)) == PH_BAD, "③ 重传时逐页哈希：不崩、哈希判作废（状态 %d）", ph3 && n3 ? (int)atomic_load(ph_state(ph3, n3)) : -1);
        free(ph3); }
    {   // 诊断#f83b30（v0.4.3 仍崩，tex_mtl → tp_fp_u → memmove）：存储页写过（在内存里）、之后改成不可访问——驻留不等于可读。
        //   期望（手写）：④ tp_fp_u 不崩、这块按 0 记「没读」；⑤ GPU 写回账的 GOB 哈希不崩、按全 0 GOB；⑥ 整段读入口 tex_src 不崩、给出全 0 的副本。
        //   反证：改前 tp_fp_u 用 mincore 驻留判「能读」直接 memcpy → Bus error: 10（同玩家现场），走不到汇总行
        uint8_t *r2 = mmap(NULL, 2 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(r2 != MAP_FAILED);
        memset(r2, 0x5A, 2 * pg); REQUIRE(!mprotect(r2, pg, PROT_NONE));
        unsigned char inc = 0; REQUIRE(!mincore(r2, pg, (char *)&inc));
        static pool_t p2; p2.mem = r2; p2.size = 2 * pg;
        static tex_t t2; memset(&t2, 0, sizeof t2);
        t2.d.target = 1; t2.d.format = 0x25; t2.d.width = 16; t2.d.height = 16; t2.d.depth = 1; t2.d.levels = 1;
        nvn_tex_layout(&t2.d, &t2.L); t2.mem = r2; t2.pool = &p2; t2.serial = 2;
        int ut = 0; (void)tp_fp_u(&t2, &ut);
        VERIFY(ut == 1, "④ tp_fp_u：存储页驻留（mincore %s）但不可读 → 不崩、记「没读」（untouched=%d）", inc & MINCORE_INCORE ? "在内存" : "不在内存", ut);
        gob_win w = gob_win_new(); uint64_t g = (uint64_t)(uintptr_t)r2 >> 9;
        VERIFY(gob_hash_w(&w, g, g + 1) == gob_zero_hash(), "⑤ GOB 哈希：不可读的页按全 0 GOB、不读");
        uint8_t *pp = NULL; const uint8_t *ss = tex_src(&t2, t2.L.size, &pp); int zero = 1; for (uint64_t i = 0; i < t2.L.size; i++) zero &= ss[i] == 0;
        VERIFY(ss != t2.mem && pp && zero, "⑥ 整段读入口 tex_src：给出副本、全 0（%llu 字节）", (unsigned long long)t2.L.size);
        free(pp);
        // ⑦ 对照：同一页恢复可读后 tp_fp_u 照读；tex_src 给出的内容 = 原存储（不在登记池里的存储一律安全拷，内容一字不差）
        REQUIRE(!mprotect(r2, pg, PROT_READ | PROT_WRITE)); ut = 0; (void)tp_fp_u(&t2, &ut); ss = tex_src(&t2, t2.L.size, &pp);
        VERIFY(ut == 0 && ss && !memcmp(ss, t2.mem, t2.L.size), "⑦ 对照：可读时 tp_fp_u 照读（untouched=%d）、tex_src 内容与原存储一致", ut);
        free(pp);
        munmap(r2, 2 * pg); }
    {   // ⑧ 常驻冒烟一台测试设备上稳定复现的那款（v0.4.3，move ← pkg_upload，崩前没有「只映射了 N 字节」红行 = 按权限判整段可读）：页权限可读、背后的存储已不在 →
        //   读就 SIGBUS。造法：文件 MAP_SHARED 映射两页后把文件截成 0。期望（手写）：tex_src 不崩、给出全 0 副本；改前（按权限判可读就直接读原存储）→ Bus error
        char fp[] = "/tmp/t_nvn_pkg_trunc_XXXXXX"; int fd = mkstemp(fp); REQUIRE(fd >= 0); unlink(fp); REQUIRE(!ftruncate(fd, (off_t)(2 * pg)));
        uint8_t *r3 = mmap(NULL, 2 * pg, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); REQUIRE(r3 != MAP_FAILED); memset(r3, 0x77, 2 * pg); REQUIRE(!ftruncate(fd, 0));
        static pool_t p3; p3.mem = r3; p3.size = 2 * pg;
        static tex_t t3; memset(&t3, 0, sizeof t3);
        t3.d.target = 1; t3.d.format = 0x25; t3.d.width = 16; t3.d.height = 16; t3.d.depth = 1; t3.d.levels = 1;
        nvn_tex_layout(&t3.d, &t3.L); t3.mem = r3; t3.pool = &p3; t3.serial = 3;
        uint64_t rd3 = mem_readable(r3, t3.L.size);
        uint8_t *pp3 = NULL; const uint8_t *s3 = tex_src(&t3, t3.L.size, &pp3); int z3 = 1; for (uint64_t i = 0; i < t3.L.size; i++) z3 &= s3[i] == 0;
        VERIFY(s3 != t3.mem && z3, "⑧ 权限可读（按权限判可读 %llu / %llu 字节）但背后文件已截短：tex_src 不崩、给出全 0 副本", (unsigned long long)rd3, (unsigned long long)t3.L.size);
        free(pp3); munmap(r3, 2 * pg); close(fd); }
    {   // ⑨ D-8QFH：CPU 上传暂存第一次分配不到（返回 nil）。期望（手写）：不抛 ObjC 异常、交出在途批后重分配，建出 16×16 贴图、重试计数 +1、打一行「重分配成功」
        //   反证：改前 nil 直接进 up_keep_add → NSInvalidArgumentException「object cannot be nil」，进程中止，走不到汇总行
        int pfd2[2]; REQUIRE(!pipe(pfd2)); int keep2 = dup(2); dup2(pfd2[1], 2); close(pfd2[1]);
        uint64_t r0 = g_up_stage_retries; g_stage_fail = 1; uint64_t st9 = 0; id<MTLTexture> m9 = pkg_upload(&t, &st9, nil, NULL, NULL, 0);
        fflush(stderr); dup2(keep2, 2); close(keep2);
        char b9[65536]; ssize_t k9 = read(pfd2[0], b9, sizeof b9 - 1); b9[k9 > 0 ? k9 : 0] = 0; close(pfd2[0]);
        VERIFY(m9 && m9.width == 16 && g_stage_fail == 0 && g_up_stage_retries == r0 + 1 && strstr(b9, "重分配成功"),
               "⑨ 暂存第一次分配不到：不崩、重分配后建出贴图（%lux%lu）、重试 %llu 次、打出重分配成功", (unsigned long)m9.width, (unsigned long)m9.height, (unsigned long long)(g_up_stage_retries - r0));
        if (!strstr(b9, "重分配成功")) fputs(b9, stdout); }
    printf("%s t_nvn_pkg_unreadable：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
} }
