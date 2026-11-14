// 一次提交里连着上传多张打包贴图（nvn_mtl.m up_begin，延后编码 DM_NVN_ENC_THREAD 缺省开）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。
//   CPU 解排布的贴图（怪猎崛起那种稀疏虚拟池上的，只能经页表在 CPU 上读）每张第一次给 GPU 用时各自成一个上传批次（pkg_upload_ 的 CPU 路径：up_begin … up_flush），
//   批次占 3 个槽轮转；第 4 批开头要等第 1 批在 GPU 上做完。单测进程里搭不出稀疏池（地址窗口要本款 main.npdm），所以直接包含生产 nvn_mtl.m、关掉 GPU 解排布
//   （g_nvn_deswz_gpu = 0），普通池的贴图就走同一段 CPU 路径。
//   延后编码时第 1 批的提交只是本线程录制块里的一条记录，没交给编码线程之前 GPU 看不到它：旧实现在这里死等（10-26 怪猎崛起真机第 721 帧停住 45 秒，
//   宿主栈 up_wait_zero ← up_begin ← pkg_upload ← tex_mtl ← encode_args ← draw）。
// 期望：一次提交里 6 张贴图各拷到池里，逐纹素等于各自写进存储的色值（色值手写，与被测实现无关），整件 20 秒内做完（alarm 判卡死）。
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static unsigned checks, fails; static unsigned begins;
enum { U_POOL_SIZE = 16 << 20, U_COMMAND_SIZE = 1 << 20, U_READ_OFFSET = 1 << 20, U_TEX_OFFSET = 2 << 20, U_SIDE = 8, U_NTEX = 6 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void stuck(int sig) { (void)sig; static const char m[] = "FAIL 20 秒没做完：一次提交里连着上传打包贴图卡住（up_begin 等的批次还没交给 GPU）\n✗ t_nvn_updrain\n"; write(1, m, sizeof m - 1); _exit(1); }

int main(void) {
    @autoreleasepool {
        setenv("DM_NVN_ENC_THREAD", "1", 1);   // 延后编码：iPhone 上缺省开、Mac 上缺省关（nvn_rec.h rec_on），这里照真机开
        signal(SIGALRM, stuck); alarm(20);
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
        NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
        REQUIRE(API(nvnQueueInitialize)(&queue, &qb)); mtl_init(); g_nvn_deswz_gpu = 0; REQUIRE(posix_memalign(&storage, 65536, U_POOL_SIZE) == 0); memset(storage, 0, U_POOL_SIZE);   // g_nvn_deswz_gpu = 0：CPU 解排布路径（每张一批）
        NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
        API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, U_POOL_SIZE);
        API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
        static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
        // 6 张 8×8 RGBA8，各自 64 KB 一块存储（建贴图会给它的页加写保护，先写内容再建），每张整段填各自的色值
        NVNtexture tex[U_NTEX]; uint8_t rgba[U_NTEX][4];
        for (int i = 0; i < U_NTEX; i++) {
            NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device); API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
            API(nvnTextureBuilderSetSize2D)(&b, U_SIDE, U_SIDE); API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
            size_t bytes = API(nvnTextureBuilderGetStorageSize)(&b), off = U_TEX_OFFSET + (size_t)i * 65536; REQUIRE(bytes && bytes <= 65536);
            rgba[i][0] = (uint8_t)(0x10 * (i + 1)); rgba[i][1] = (uint8_t)(0xF0 - 0x10 * i); rgba[i][2] = (uint8_t)(0x31 + i); rgba[i][3] = 0xFF;
            for (size_t k = 0; k < bytes; k += 4) memcpy((uint8_t *)storage + off + k, rgba[i], 4);
            API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(&tex[i], &b));
        }
        // 一次提交：6 条贴图 → 缓冲拷贝，中间不夹别的工作；每张都是第一次给 GPU 用，回放时各上传一批
        memset((uint8_t *)storage + U_READ_OFFSET, 0xA5, U_NTEX * U_SIDE * U_SIDE * 4);
        API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, U_COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
        NVNcopyRegion whole = {0, 0, 0, U_SIDE, U_SIDE, 1}; NVNbufferAddress base = API(nvnMemoryPoolGetBufferAddress)(&pool) + U_READ_OFFSET;
        for (int i = 0; i < U_NTEX; i++) API(nvnCommandBufferCopyTextureToBuffer)(&commands, &tex[i], NULL, &whole, base + (NVNbufferAddress)i * U_SIDE * U_SIDE * 4, 0);
        NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
        unsigned seq0 = g_up_seq;
        API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
        begins = g_up_seq - seq0;
        for (int i = 0; i < U_NTEX; i++) {
            const uint8_t *p = (const uint8_t *)storage + U_READ_OFFSET + (size_t)i * U_SIDE * U_SIDE * 4; int bad = 0;
            for (int k = 0; k < U_SIDE * U_SIDE; k++) bad += memcmp(p + 4 * k, rgba[i], 4) != 0;
            checks++; if (bad) { fails++; printf("FAIL 第 %d 张：%d/%d 纹素不符（第 0 个 %02x %02x %02x %02x，期望 %02x %02x %02x %02x）\n", i, bad, U_SIDE * U_SIDE, p[0], p[1], p[2], p[3], rgba[i][0], rgba[i][1], rgba[i][2], rgba[i][3]); }
        }
        checks++; if (begins < 4) { fails++; printf("FAIL 这次提交只开了 %u 个上传批次，不到 4 个，碰不到第 4 批等第 1 批的情形（单测没走到要测的路径）\n", begins); }
        // 批内暂存封顶（nvn_mtl.m up_begin / UP_KEEP_CAP）：一次提交开着时上传批不提交，换下的暂存都攒在 g_up_keep 等这批提交后回收；帧回放一次提交上传全部贴图
        //   曾攒到 2729 块 116 GB、本机锁定内存约 110 GB。照生产调用顺序（每次上传先 up_begin 再挂暂存）挂 12 块 32 MB：期望（手算，256 MB = 8 块）第 9 次 up_begin
        //   先提交这批（提前提交恰好 1 次），挂完 12 块后批内只剩 4 块 128 MB；正对照：第 1–8 次 up_begin 都不提交
        {
            enum { K_N = 12, K_BLK = 32 << 20 }; uint64_t cf0 = g_up_cap_flushes; int early = -1; __weak id<MTLBuffer> wk[K_N];
            for (int i = 0; i < K_N; i++) {
                up_begin(); if (early < 0 && g_up_cap_flushes != cf0) early = i;
                id<MTLBuffer> b = [g_dev newBufferWithLength:K_BLK options:MTLResourceStorageModePrivate]; REQUIRE(b != nil); res_add(b); up_keep_add(b); wk[i] = b;
            }
            uint64_t left = g_up_keep_bytes; up_flush(); API(nvnQueueFinish)(&queue);
            checks++; if (g_up_cap_flushes - cf0 != 1 || early != 8) { fails++; printf("FAIL 挂 12 块 32 MB 暂存：提前提交 %llu 次、首次在第 %d 次 up_begin（期望 1 次、第 9 次即下标 8）\n", (unsigned long long)(g_up_cap_flushes - cf0), early + 1); }
            checks++; if (left != 4ull * K_BLK) { fails++; printf("FAIL 挂完 12 块批内留 %llu MB，期望 128 MB（256 MB 提交后又挂 4 块）\n", (unsigned long long)(left >> 20)); }
            // 暂存只被本批上传命令用：上传做完就移出驻留集（驻留集是它们唯一的长期持有者），不等下一次提交的栅栏；一次提交里提前提交的批次靠这个才真回收
            //   （旧实现走 defer_obj_release 等提交栅栏，回放整帧一次提交，攒到 37 GB）。期望：上传做完 2 秒内 12 块都不在驻留集里
            int inres = K_N; for (int t = 0; t < 200 && inres; t++) { usleep(10000); inres = 0; pthread_mutex_lock(&g_res_mu); for (int i = 0; i < K_N; i++) { id<MTLBuffer> x = wk[i]; inres += x && [g_res_objects containsObject:x]; } pthread_mutex_unlock(&g_res_mu); }
            checks++; if (inres) { fails++; printf("FAIL 上传做完 2 秒后 12 块暂存还有 %d 块在驻留集里（期望 0：随上传完成移出，不等提交栅栏）\n", inres); }
            else puts("✓ 12 块暂存随上传完成移出驻留集（不等提交栅栏）");
            checks++; if (g_up_keep_bytes != 0) { fails++; printf("FAIL 提交后批内暂存计数 %llu，期望 0\n", (unsigned long long)g_up_keep_bytes); }
            if (g_up_cap_flushes - cf0 == 1 && early == 8 && left == 4ull * K_BLK) puts("✓ 批内暂存封顶：12 块 32 MB 在第 9 次 up_begin 提前提交 1 次，批内留 128 MB，提交后清零");
        }
        // 解排布参数块（nvn_mtl.m up_param_alloc / g_up_slot_pblk）：参数格只被录它的那个上传批读，寿命要跟着那批走。旧实现所有批共用一块、写满就 defer_obj_release
        //   （挂在下一次回放提交的栅栏上，与还在读它的上传批没有先后保证，释放时还移出驻留集）——Mac / iPad 两份玩家诊断都是首传贴图后 GPU 缺页。
        //   期望（按 64 KB / 64 字节 = 1024 格手算）：同一批切 1100 格 → 第 1025 格换块，换下的是槽自己的块、留着；新块到批末交给本批的保留表，
        //   不进延后释放队列（旧实现：进）；上传做完 2 秒内新块移出驻留集，槽块仍在；下一批换槽，用的是另一块槽块
        {
            up_begin(); unsigned s0 = g_up_cur_slot; size_t off; id<MTLBuffer> first = up_param_alloc(&off), cur = first; int swaps = 0; __weak id<MTLBuffer> over = nil;
            for (int i = 1; i < 1100; i++) { id<MTLBuffer> b = up_param_alloc(&off); if (b != cur) { swaps++; over = b; cur = b; } }
            int indef = 0; pthread_mutex_lock(&g_deferred_mu); for (NvDeferredRelease *d in g_deferred) indef += d->object == first || (over && d->object == over); pthread_mutex_unlock(&g_deferred_mu);
            checks++; if (first != g_up_slot_pblk[s0] || swaps != 1 || off != (1100 - 1024 - 1) * 64) { fails++; printf("FAIL 参数块：首块是槽块 %d、换块 %d 次（期望 1）、末格偏移 %zu（期望 %d）\n", first == g_up_slot_pblk[s0], swaps, off, (1100 - 1024 - 1) * 64); }
            checks++; if (indef) { fails++; printf("FAIL 参数块：写满换下后进了延后释放队列 %d 块（期望 0：跟着本批上传完成退，不挂在回放提交的栅栏上）\n", indef); }
            up_flush(); API(nvnQueueFinish)(&queue);
            int inres = 1; for (int t = 0; t < 200 && inres; t++) { usleep(10000); pthread_mutex_lock(&g_res_mu); id<MTLBuffer> x = over; inres = x && [g_res_objects containsObject:x]; pthread_mutex_unlock(&g_res_mu); }
            pthread_mutex_lock(&g_res_mu); int slot_in = [g_res_objects containsObject:g_up_slot_pblk[s0]]; pthread_mutex_unlock(&g_res_mu);
            checks++; if (inres || !slot_in) { fails++; printf("FAIL 参数块：上传做完 2 秒后换下的块还在驻留集 %d（期望 0）、槽块在驻留集 %d（期望 1）\n", inres, slot_in); }
            up_begin(); unsigned s1 = g_up_cur_slot; id<MTLBuffer> second = up_param_alloc(&off); up_flush(); API(nvnQueueFinish)(&queue);
            checks++; if (s1 == s0 || second != g_up_slot_pblk[s1] || second == first || off != 0) { fails++; printf("FAIL 参数块：下一批槽 %u→%u、用的是本槽槽块 %d、与上一槽同一块 %d、首格偏移 %zu（期望 换槽、1、0、0）\n", s0, s1, second == g_up_slot_pblk[s1], second == first, off); }
            if (!indef && !inres && slot_in && swaps == 1 && s1 != s0) puts("✓ 解排布参数块跟着上传批走：写满换下的不进延后释放、上传做完移出驻留集，每槽一块");
        }
        // ReadTexels can resolve a fresh host texture outside a replay.  With
        // deferred encoding already active, its initial upload is recorded but
        // not published.  Finishing the GPU must publish it before waiting.
        NVNtexture fresh; NVNtextureBuilder fb;
        API(nvnTextureBuilderSetDefaults)(&fb); API(nvnTextureBuilderSetDevice)(&fb, &device);
        API(nvnTextureBuilderSetTarget)(&fb, NVN_TEXTURE_TARGET_2D);
        API(nvnTextureBuilderSetSize2D)(&fb, U_SIDE, U_SIDE); API(nvnTextureBuilderSetLevels)(&fb, 1);
        API(nvnTextureBuilderSetFormat)(&fb, NVN_FORMAT_RGBA8);
        const size_t fresh_off = U_TEX_OFFSET + U_NTEX * 65536;
        const uint8_t expected[4] = {0x39, 0x86, 0xD2, 0xFF};
        for (size_t k = 0; k < 65536; k += 4) memcpy((uint8_t *)storage + fresh_off + k, expected, 4);
        API(nvnTextureBuilderSetStorage)(&fb, &pool, fresh_off);
        REQUIRE(API(nvnTextureInitialize)(&fresh, &fb));
        uint8_t readback[U_SIDE * U_SIDE * 4]; memset(readback, 0xA5, sizeof readback);
        g_nvn_deswz_gpu = 1;
        fprintf(stderr, "fresh ReadTexels after deferred replay: begin\n");
        API(nvnTextureReadTexels)(&fresh, NULL, &whole, readback);
        for (int k = 0; k < U_SIDE * U_SIDE; k++) REQUIRE(memcmp(readback + 4 * k, expected, 4) == 0);
        alarm(0);
        puts("✓ fresh ReadTexels after deferred replay: 64 expected texels, no unpublished upload wait");
        printf("%s t_nvn_updrain：一次提交里 CPU 解排布上传 %d 张贴图（%u 个上传批次），20 秒内做完、逐纹素对上（%u 条检查，%u 条不符）\n", fails ? "✗" : "✓", U_NTEX, begins, checks, fails);
        return fails != 0;
    }
}
