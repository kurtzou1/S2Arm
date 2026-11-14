// #141（伊苏 8 闪退待证）：真机取图绝不交还在屏上的那张——最近一次呈现的图要等下一次呈现翻走才归还（hle_nvn.c 取图的撞张等待）。
//   全生产 bootstrap、真实 Metal 交换链（2 张）、无头局（直连层无窗口只计数，出票照常完成）。
//   主线程 1:1 取图上屏 4 帧坐稳节拍主人，别的线程（非主人路径——TMNT 加载线程形态）再取图撞上屏上那张。
//   期望按真机语义手写，不由被测实现反推：
//   ① 别的线程撞上的取图必须等出翻走它的那笔呈现才返回（主线程 30 ms 后上屏另一张）：修前立即返回（约 0 ms）；
//   ② 没撞上的取图立即返回（撞张等待不得波及正常取图）；
//   ③ 等不到下一笔呈现（取图线程外没有呈现方）到 2 个呈现周期（33.3 ms）上限兜底交出、不卡死：修前立即返回；
//   ④ 节拍主人（主线程自己）撞上：下一次呈现多半由本线程自己发出、等它等于等自己——不进入等待，按原行为交出并报红
//     （不设这条，单线程引擎每撞一次白等 2 个呈现周期，帧率直接掉半）。
#include "nvn_protos.h"
#include "nvn_mtl.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); bad++; } } while (0)
#define API(type, var, name) type var = (type)api(#name)

static double ms_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static NVNwindow g_win;
static NVNT_nvnWindowAcquireTexture g_acq;
static NVNT_nvnQueuePresentTexture g_pres;
typedef struct { int rc, idx; double ms; } acq_rec;
static acq_rec g_a, g_ctrl, g_b;   // ① 撞张等翻走 / ② 没撞对照 / ③ 超时兜底（都在别的线程取图）
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_step;
static void step(int s) { pthread_mutex_lock(&g_mu); g_step = s; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu); }
// 单调等（g_step < s 即等）：步号只增不减，等的一方被唤醒前对端可能已走到更后面的步号——按相等等会永久等一个被跳过的值
static void wait_step(int s) { pthread_mutex_lock(&g_mu); while (g_step < s) pthread_cond_wait(&g_cv, &g_mu); pthread_mutex_unlock(&g_mu); }

static void *w1(void *arg) {   // ① 撞张等翻走 + ② 没撞对照；收尾把对照那张上屏（在 ③ 的工作线程之后，让 ④ 撞上它）
    (void)arg;
    wait_step(1);
    { int i = -1; double t = ms_now(); g_a.rc = g_acq(&g_win, NULL, &i); g_a.idx = i; g_a.ms = ms_now() - t; }
    step(2);                                    // ① 返回即翻走呈现已落地（主线程先上屏再收这一步）
    g_pres(NULL, &g_win, g_a.idx);              // 自己那张也上屏：② 的撞张判定要 shown 指着另一张
    wait_step(3);
    { int i = -1; double t = ms_now(); g_ctrl.rc = g_acq(&g_win, NULL, &i); g_ctrl.idx = i; g_ctrl.ms = ms_now() - t; }
    step(4);
    wait_step(9);                               // 收尾上屏排在 ③ 工作线程之后（主线程 step(9) 指挥）
    g_pres(NULL, &g_win, g_ctrl.idx);
    step(10);
    return NULL;
}
static void *w2(void *arg) {   // ③ 超时兜底：全新线程（没取过图，也不是节拍主人 / 屏上那张的取图线程），撞上后无呈现方来翻
    (void)arg;
    wait_step(5);
    { int i = -1; double t = ms_now(); g_b.rc = g_acq(&g_win, NULL, &i); g_b.idx = i; g_b.ms = ms_now() - t; }
    step(6);
    wait_step(7);
    g_pres(NULL, &g_win, g_b.idx);              // 先上屏这张（shown 仍指它），主线程再指挥 ① 线程上屏另一张
    step(8);
    return NULL;
}

int main(void) {
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
    API(NVNT_nvnTextureFinalize, texFini, nvnTextureFinalize);
    API(NVNT_nvnMemoryPoolFinalize, poolFini, nvnMemoryPoolFinalize);
    API(NVNT_nvnDeviceFinalize, devFini, nvnDeviceFinalize);
    g_acq = (NVNT_nvnWindowAcquireTexture)api("nvnWindowAcquireTexture");
    g_pres = (NVNT_nvnQueuePresentTexture)api("nvnQueuePresentTexture");
    if (bad) return 1;

    NVNdevice device = {0}; NVNdeviceBuilder db = {0};
    dbDef(&db);
    CHECK(devInit(&device, &db), "NVN 生产设备初始化");
    void *storage = NULL;
    if (posix_memalign(&storage, 16384, 2 * 65536)) exit(1);
    for (unsigned i = 0; i < 2 * 65536 / 4; i++) ((uint32_t *)storage)[i] = 0xff224488;
    NVNmemoryPool pool = {0}; NVNmemoryPoolBuilder pb = {0};
    pbDev(&pb, &device); pbDef(&pb); pbStore(&pb, storage, 2 * 65536);
    pbFlags(&pb, NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    CHECK(poolInit(&pool, &pb), "NVN 生产内存池初始化");
    NVNtexture textures[2] = {0}; NVNtexture *ptrs[2];
    for (int i = 0; i < 2; i++) {
        NVNtextureBuilder tb = {0};
        tbDev(&tb, &device); tbDef(&tb); tbTarget(&tb, NVN_TEXTURE_TARGET_2D); tbSize(&tb, 64, 64);
        tbFmt(&tb, NVN_FORMAT_RGBA8); tbFlags(&tb, NVN_TEXTURE_FLAGS_LINEAR); tbStride(&tb, 256);
        tbStore(&tb, &pool, i * 65536);
        CHECK(texInit(&textures[i], &tb), "NVN 生产交换链纹理 %d", i);
        ptrs[i] = &textures[i];
    }
    NVNwindowBuilder wb = {0};
    wbDev(&wb, &device); wbDef(&wb); wbTex(&wb, 2, ptrs); wbItv(&wb, 1);
    CHECK(winInit(&g_win, &wb), "NVN 生产窗口初始化（2 张，间隔 1）");

    int idx, want[4] = {0, 1, 0, 1};
    for (int i = 0; i < 4; i++) {   // 1:1 取图上屏：节拍主人坐稳（连续 3 笔），轮换与真机一致
        CHECK(g_acq(&g_win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == want[i],
              "开局第 %d 次取图下标 %d（应 %d）", i + 1, idx, want[i]);
        g_pres(NULL, &g_win, idx);
    }
    { int i = -1; CHECK(g_acq(&g_win, NULL, &i) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && i == 0, "压着不上屏的那张取到下标 %d（应 0）", i); idx = i; }
    pthread_t t1, t2; if (pthread_create(&t1, NULL, w1, NULL) || pthread_create(&t2, NULL, w2, NULL)) { fprintf(stderr, "起不了工作线程\n"); return 1; }
    step(1);
    struct timespec d30 = {0, 30000000}; nanosleep(&d30, NULL);   // 工作线程进等之后再上屏翻走：30 ms 覆盖起线程与进撞张等待的全部调度余量
    g_pres(NULL, &g_win, idx);   // 屏上换成图 0：图 1 翻走归还，① 工作线程的取图等的就是这一笔
    wait_step(2);
    CHECK(g_a.rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && g_a.idx == 1,
          "① 撞上屏上那张的取图下标 %d（应 1，轮换顺序不变）", g_a.idx);
    CHECK(g_a.ms >= 20 && g_a.ms <= 1000,
          "① 撞上屏上那张等翻走 %.1f ms（应 ≥20：30 ms 后的呈现翻走它才交；修前约 0 ms）", g_a.ms);
    step(3); wait_step(4);
    CHECK(g_ctrl.rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && g_ctrl.idx == 0,
          "② 没撞上的取图下标 %d（应 0）", g_ctrl.idx);
    CHECK(g_ctrl.ms < 20, "② 没撞上的取图 %.1f ms 立即返回（应 <20，撞张等待不得波及）", g_ctrl.ms);
    step(5); wait_step(6);
    CHECK(g_b.rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && g_b.idx == 1,
          "③ 等不到翻走的取图下标 %d（应 1，兜底仍按轮换交出）", g_b.idx);
    CHECK(g_b.ms >= 15 && g_b.ms <= 1000,
          "③ 等不到翻走 %.1f ms 兜底交出（应 ≥15：2 个呈现周期上限 33.3 ms；修前约 0 ms）", g_b.ms);
    step(7); wait_step(8);   // ③ 工作线程把自己那张上屏（shown 仍指它）
    step(9); wait_step(10);  // ① 工作线程再把另一张上屏：shown 换到图 0，④ 主线程自己撞上它
    {   // ④ 节拍主人（主线程自己）撞上还在屏上的那张：下一次呈现多半由本线程自己发出、等它等于等自己——
        //   不进入等待，按原行为交出并报红。先睡 100 ms（>3 个呈现周期）把节拍债务清掉（① ③ 工作线程不走主人路径、
        //   不睡节拍，它们的呈现跑到了槽位前面，avail 落在未来最多 2 个周期处）：此后本次取图的节拍等待为 0，
        //   时长只反映撞张等待本身——同线程跳过 <15 ms；不跳过（等自己那笔不存在的呈现）会等满上限 ≥33 ms
        struct timespec d100 = {0, 100000000}; nanosleep(&d100, NULL);
        double t = ms_now(); int i = -1;
        int rc = g_acq(&g_win, NULL, &i);
        double ms = ms_now() - t;
        CHECK(rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && i == 0, "④ 主线程撞上屏上那张的取图下标 %d（应 0，轮换顺序不变）", i);
        CHECK(ms < 15, "④ 主线程（节拍主人）撞上屏上那张 %.1f ms 返回（应 <15：同线程不等；等自己会 ≥33 ms）", ms);
        g_pres(NULL, &g_win, i);
    }
    pthread_join(t1, NULL); pthread_join(t2, NULL);
    nvn_be_drain();
    for (int i = 0; i < 2; i++) texFini(&textures[i]);
    poolFini(&pool); devFini(&device); free(storage);
    printf("%s t_nvn_win_shown：撞上等翻走 / 没撞立即返回 / 等不到兜底 / 同线程不等 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
