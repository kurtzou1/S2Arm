// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 即时存档恢复后，窗口对象里的节拍时刻（win_t 的 avail[] / pace，hle_nvn.c）不能照旧用。
//   它们是存档那个进程的单调钟读数（开机以来的纳秒），跟着游戏内存进快照。同一次开机里恢复，这些时刻已经过去，不用等；
//   设备重启后单调钟从零起，它们变成几十小时以后——取图里「睡到可取用时刻」一睡不醒，游戏画完恢复后的第一帧就停住
//   （11-23 iPad：存档时开机 61.1 小时，重启后 536 秒读档，出帧线程停在 mach_wait_until，截止 = 开机后 219956 秒）。
//   全生产 bootstrap、真实 Metal 交换链（2 张，间隔 1）、无头局。期望按语义手写，不由被测实现反推：
//   ① 读档后（hle_snap_win_clock_restored，hle_snap_restore 调的就是它），可取用时刻在 100 秒之后的窗口，节拍主人取图 2 秒内返回
//   ② 那次取图之后上屏：这张的下一次可取用时刻、节拍目标都不晚于现在 + 1 秒
//   ③ 读档后不取图直接上屏（读档前已取在手里的那张）：同 ②
//   ④ 再读一次档（同进程连着读）：同 ①
//   ⑤ 负对照：没读档，可取用时刻在 300 毫秒之后——取图要等到那个时刻才返回：正常的节拍等待不被截掉
//   修前（两处 win_clock_fresh 调用去掉）：① 的取图睡 100 秒，看门 2 秒到点判红并退出
//   前提：无头局里显示链接不激活，取图的节拍等待走「睡到可取用时刻」；链接激活时走链接的拍，① 修前红不出来、⑤ 也等不到那个时刻
#include "nvn_protos.h"
#include "nvn_mtl.h"
#include "nvn_obj.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern void *h_nvnBootstrapLoader(const char *name);
void hle_snap_win_clock_restored(void);   // hle_nvn.c：hle_snap_restore 调的就是它
uint64_t now_ns(void);   // 被测代码用的单调钟（runtime/src/os.c）
static int bad, checks;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); fflush(stdout); bad += !ok_; } while (0)
#define API(type, var, name) type var = (type)api(#name)

static NVNwindow g_win;
static NVNT_nvnWindowAcquireTexture g_acq;
static NVNT_nvnQueuePresentTexture g_pres;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_done;   // 游戏线程走完的步数
static void done(int s) { pthread_mutex_lock(&g_mu); g_done = s; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu); }
static int wait_done(int s, double sec) {   // 等游戏线程走到第 s 步，最多 sec 秒；到了返回 1
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += (time_t)sec; dl.tv_nsec += (long)((sec - (time_t)sec) * 1e9); if (dl.tv_nsec >= 1000000000L) { dl.tv_nsec -= 1000000000L; dl.tv_sec++; }
    pthread_mutex_lock(&g_mu); int rc = 0; while (g_done < s && rc == 0) rc = pthread_cond_timedwait(&g_cv, &g_mu, &dl); int ok = g_done >= s; pthread_mutex_unlock(&g_mu); return ok;
}
static void stale(win_t *o, uint64_t ahead) { uint64_t t = now_ns() + ahead; for (int i = 0; i < 4; i++) o->avail[i] = t; o->pace = t; }   // 像快照里带来的那样：全部在 ahead 纳秒之后
static void restored(void) { hle_snap_win_clock_restored(); }
static double lead_s(uint64_t t) { uint64_t n = now_ns(); return t > n ? (t - n) / 1e9 : -((n - t) / 1e9); }
static struct { int rc1, idx1; double avail2, pace2, avail3, pace3; int rc4, idx4; int rc5; double waited5, early5; } g_r;   // early5：⑤ 取图返回时离那个时刻还差多少秒（≤ 0 = 等到了）

static void *game(void *arg) {   // 游戏的出帧线程：取图、上屏都在这一条上（节拍主人）
    (void)arg; win_t *o = (win_t *)&g_win; int idx = -1;
    for (int i = 0; i < 4; i++) { g_acq(&g_win, NULL, &idx); g_pres(NULL, &g_win, idx); }   // 坐稳节拍主人
    done(1);
    stale(o, 100000000000ull); restored();
    g_r.rc1 = g_acq(&g_win, NULL, &idx); g_r.idx1 = idx; done(2);                              // ①
    g_pres(NULL, &g_win, idx); g_r.avail2 = lead_s(o->avail[idx]); g_r.pace2 = lead_s(o->pace); done(3);   // ②
    g_acq(&g_win, NULL, &idx); stale(o, 100000000000ull); restored();
    g_pres(NULL, &g_win, idx); g_r.avail3 = lead_s(o->avail[idx]); g_r.pace3 = lead_s(o->pace); done(4);   // ③
    stale(o, 100000000000ull); restored();
    g_r.rc4 = g_acq(&g_win, NULL, &idx); g_r.idx4 = idx; g_pres(NULL, &g_win, idx); done(5);     // ④
    stale(o, 300000000ull); uint64_t dl = o->pace;                                             // ⑤ 没读档
    uint64_t t0 = now_ns(); g_r.rc5 = g_acq(&g_win, NULL, &idx); uint64_t t1 = now_ns(); g_r.waited5 = (t1 - t0) / 1e9; g_r.early5 = t1 >= dl ? 0 : (dl - t1) / 1e9; g_pres(NULL, &g_win, idx); done(6);
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    API(NVNT_nvnDeviceBuilderSetDefaults, dbDef, nvnDeviceBuilderSetDefaults);
    API(NVNT_nvnDeviceInitialize, devInit, nvnDeviceInitialize);
    API(NVNT_nvnMemoryPoolBuilderSetDevice, pbDev, nvnMemoryPoolBuilderSetDevice);
    API(NVNT_nvnMemoryPoolBuilderSetDefaults, pbDef, nvnMemoryPoolBuilderSetDefaults);
    API(NVNT_nvnMemoryPoolBuilderSetStorage, pbStore, nvnMemoryPoolBuilderSetStorage);
    API(NVNT_nvnMemoryPoolBuilderSetFlags, pbFlags, nvnMemoryPoolBuilderSetFlags);
    API(NVNT_nvnMemoryPoolInitialize, poolInit, nvnMemoryPoolInitialize);
    API(NVNT_nvnTextureBuilderSetDevice, tbDev, nvnTextureBuilderSetDevice);
    API(NVNT_nvnTextureBuilderSetDefaults, tbDef, nvnTextureBuilderSetDefaults);
    API(NVNT_nvnTextureBuilderSetTarget, tbTarget, nvnTextureBuilderSetTarget);
    API(NVNT_nvnTextureBuilderSetSize2D, tbSize, nvnTextureBuilderSetSize2D);
    API(NVNT_nvnTextureBuilderSetFormat, tbFmt, nvnTextureBuilderSetFormat);
    API(NVNT_nvnTextureBuilderSetFlags, tbFlags, nvnTextureBuilderSetFlags);
    API(NVNT_nvnTextureBuilderSetStride, tbStride, nvnTextureBuilderSetStride);
    API(NVNT_nvnTextureBuilderSetStorage, tbStore, nvnTextureBuilderSetStorage);
    API(NVNT_nvnTextureInitialize, texInit, nvnTextureInitialize);
    API(NVNT_nvnWindowBuilderSetDevice, wbDev, nvnWindowBuilderSetDevice);
    API(NVNT_nvnWindowBuilderSetDefaults, wbDef, nvnWindowBuilderSetDefaults);
    API(NVNT_nvnWindowBuilderSetTextures, wbTex, nvnWindowBuilderSetTextures);
    API(NVNT_nvnWindowBuilderSetPresentInterval, wbItv, nvnWindowBuilderSetPresentInterval);
    API(NVNT_nvnWindowInitialize, winInit, nvnWindowInitialize);
    g_acq = (NVNT_nvnWindowAcquireTexture)api("nvnWindowAcquireTexture");
    g_pres = (NVNT_nvnQueuePresentTexture)api("nvnQueuePresentTexture");
    if (bad) return 1;

    NVNdevice device = {0}; NVNdeviceBuilder db = {0};
    dbDef(&db);
    if (!devInit(&device, &db)) { printf("✗ NVN 生产设备初始化\n"); return 2; }
    void *storage = NULL;
    if (posix_memalign(&storage, 16384, 2 * 65536)) exit(2);
    memset(storage, 0x44, 2 * 65536);
    NVNmemoryPool pool = {0}; NVNmemoryPoolBuilder pb = {0};
    pbDev(&pb, &device); pbDef(&pb); pbStore(&pb, storage, 2 * 65536);
    pbFlags(&pb, NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    if (!poolInit(&pool, &pb)) { printf("✗ NVN 生产内存池初始化\n"); return 2; }
    NVNtexture textures[2] = {0}; NVNtexture *ptrs[2];
    for (int i = 0; i < 2; i++) {
        NVNtextureBuilder tb = {0};
        tbDev(&tb, &device); tbDef(&tb); tbTarget(&tb, NVN_TEXTURE_TARGET_2D); tbSize(&tb, 64, 64);
        tbFmt(&tb, NVN_FORMAT_RGBA8); tbFlags(&tb, NVN_TEXTURE_FLAGS_LINEAR); tbStride(&tb, 256);
        tbStore(&tb, &pool, i * 65536);
        if (!texInit(&textures[i], &tb)) { printf("✗ NVN 生产交换链纹理 %d\n", i); return 2; }
        ptrs[i] = &textures[i];
    }
    NVNwindowBuilder wb = {0};
    wbDev(&wb, &device); wbDef(&wb); wbTex(&wb, 2, ptrs); wbItv(&wb, 1);
    if (!winInit(&g_win, &wb)) { printf("✗ NVN 生产窗口初始化\n"); return 2; }

    pthread_t th; pthread_create(&th, NULL, game, NULL);
    if (!wait_done(1, 10)) { printf("✗ 开局 4 帧 10 秒没走完（搭台失败）\n"); return 2; }
    int ok1 = wait_done(2, 2);
    CHECK(ok1 && g_r.rc1 == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS, "① 读档后取图：%s（应 2 秒内返回；窗口里的可取用时刻在 100 秒之后）", ok1 ? "2 秒内返回" : "2 秒没返回");
    if (!ok1) { printf("✗ t_nvn_win_restore_clock：出帧线程睡在取图里，后面几项没法跑（%d 项，%d 项不符）\n", checks, bad); fflush(stdout); _Exit(1); }
    int ok2 = wait_done(3, 2);
    CHECK(ok2 && g_r.avail2 <= 1 && g_r.pace2 <= 1, "② 读档后第一次上屏：这张下一次可取用时刻在 %.3f 秒之后、节拍目标在 %.3f 秒之后（都应 ≤ 1）", g_r.avail2, g_r.pace2);
    int ok3 = wait_done(4, 2);
    CHECK(ok3 && g_r.avail3 <= 1 && g_r.pace3 <= 1, "③ 读档后不取图直接上屏：可取用时刻在 %.3f 秒之后、节拍目标在 %.3f 秒之后（都应 ≤ 1）%s", g_r.avail3, g_r.pace3, ok3 ? "" : "；2 秒没走到");
    if (!ok3) _Exit(1);
    int ok4 = wait_done(5, 2);
    CHECK(ok4 && g_r.rc4 == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS, "④ 再读一次档后取图：%s（应 2 秒内返回）", ok4 ? "2 秒内返回" : "2 秒没返回");
    if (!ok4) _Exit(1);
    int ok5 = wait_done(6, 3);
    CHECK(ok5 && g_r.early5 <= 0 && g_r.waited5 < 2, "⑤ 负对照（没读档，可取用时刻在 0.3 秒之后）：取图返回时比那个时刻早 %.3f 秒（应 0：等到了才返回），等了 %.3f 秒", g_r.early5, g_r.waited5);
    printf("%s t_nvn_win_restore_clock：%d 项，%d 项不符\n", bad ? "✗" : "✓", checks, bad); fflush(stdout);
    _Exit(bad != 0);
}
