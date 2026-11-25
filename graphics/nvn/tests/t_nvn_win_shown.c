// #141 / #416：真机取图只交已归还的图。同线程撞上在屏 drawable、或等翻走 500 ms 超时后，
//   优先改交另一张未被租用的活跃图并保持 SUCCESS；没有已归还图时保持旧行为，仍 SUCCESS 交原下标并计红。
//   判据按返回值 / 下标 / 事件计数，不按墙钟。超时用例在首次呈现前直接摆好 shown / next，确保没有节拍主人、也没有呈现方来翻。
#include "nvn_protos.h"
#include "nvn_mtl.h"
#include "nvn_obj.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); bad++; } } while (0)
#define API(type, var, name) type var = (type)api(#name)

void s2a_nvn_acq_counts(uint64_t c[3]);
static NVNwindow g_win;
static NVNT_nvnWindowAcquireTexture g_acq;
static NVNT_nvnQueuePresentTexture g_pres;
typedef struct { int rc, idx; uint64_t c0[3], c1[3]; } acq_rec;

static void *timeout_worker(void *arg) {
    (void)arg; acq_rec *r = malloc(sizeof *r); if (!r) return NULL;
    int i = -1; s2a_nvn_acq_counts(r->c0); r->rc = g_acq(&g_win, NULL, &i); r->idx = i; s2a_nvn_acq_counts(r->c1);
    g_pres(NULL, &g_win, i);   // 清租约并让后续主线程把节拍主人坐稳
    return r;
}
static void *borrow_worker(void *arg) {
    (void)arg; acq_rec *r = malloc(sizeof *r); if (!r) return NULL;
    int i = -1; s2a_nvn_acq_counts(r->c0); r->rc = g_acq(&g_win, NULL, &i); r->idx = i; s2a_nvn_acq_counts(r->c1);
    g_pres(NULL, &g_win, i);
    return r;
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
    API(NVNT_nvnWindowFinalize, winFini, nvnWindowFinalize);
    API(NVNT_nvnTextureFinalize, texFini, nvnTextureFinalize);
    API(NVNT_nvnMemoryPoolFinalize, poolFini, nvnMemoryPoolFinalize);
    API(NVNT_nvnDeviceFinalize, devFini, nvnDeviceFinalize);
    g_acq = (NVNT_nvnWindowAcquireTexture)api("nvnWindowAcquireTexture");
    g_pres = (NVNT_nvnQueuePresentTexture)api("nvnQueuePresentTexture");
    if (bad) return 1;

    NVNdevice device = {0}; NVNdeviceBuilder db = {0};
    dbDef(&db); CHECK(devInit(&device, &db), "NVN 生产设备初始化");
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
    win_t *o = (win_t *)&g_win;

    // ① 真正的 500 ms 超时：首次呈现前没有节拍主人，shown=2 / next=1 强制撞图；无呈现方翻走，只能走超时后的候选分支。
    o->shown = 2; o->next = 1;
    pthread_t t; if (pthread_create(&t, NULL, timeout_worker, NULL)) return 1;
    void *joined = NULL; if (pthread_join(t, &joined)) return 1;
    acq_rec *r = joined;
    CHECK(r && r->rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && r->idx == 0,
          "① 等满 500 ms 未翻走：结果 %d、下标 %d（应 SUCCESS、另一张已归还图 0）", r ? r->rc : -1, r ? r->idx : -1);
    CHECK(r && r->c1[0] == r->c0[0] + 1 && r->c1[2] == r->c0[2],
          "① 超时路径：进入翻走等待 %llu 次（应 1）、交出在屏那张 %llu 次（应 0）",
          r ? (unsigned long long)(r->c1[0] - r->c0[0]) : 0ull, r ? (unsigned long long)(r->c1[2] - r->c0[2]) : 0ull);
    free(r);

    // 主线程连续 6 次 1:1 取图上屏，坐稳节拍主人；轮换仍为 0,1,0,1,0,1。
    int want[6] = {0, 1, 0, 1, 0, 1};
    for (int i = 0; i < 6; i++) {
        int idx = -1;
        CHECK(g_acq(&g_win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == want[i],
              "坐稳节拍第 %d 次取图下标 %d（应 %d）", i + 1, idx, want[i]);
        g_pres(NULL, &g_win, idx);
    }

    // ② 借帧线程仍立即返回，不进入翻走等待；随后它自己上屏，清掉租约。
    o->next = 1;
    if (pthread_create(&t, NULL, borrow_worker, NULL)) return 1;
    joined = NULL; if (pthread_join(t, &joined)) return 1;
    r = joined;
    CHECK(r && r->rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && r->idx == 1,
          "② 借帧线程撞上屏上那张：结果 %d、下标 %d（应 SUCCESS、1）", r ? r->rc : -1, r ? r->idx : -1);
    CHECK(r && r->c1[0] == r->c0[0] && r->c1[1] == r->c0[1] + 1 && r->c1[2] == r->c0[2],
          "② 借帧线程：进入翻走等待 %llu 次（应 0）、立即交出 %llu 次（应 1）、交出在屏计数不涨",
          r ? (unsigned long long)(r->c1[0] - r->c0[0]) : 0ull, r ? (unsigned long long)(r->c1[1] - r->c0[1]) : 0ull);
    free(r);

    // ③ 同线程撞图：另一张图 0 已归还且未被租用，必须保持 SUCCESS 并交 0，不能交在屏图 1。
    o->next = 1;
    uint64_t c0[3], c1[3]; int idx = -1;
    s2a_nvn_acq_counts(c0); int rc = g_acq(&g_win, NULL, &idx); s2a_nvn_acq_counts(c1);
    CHECK(rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == 0,
          "③ 主线程撞上屏上那张：结果 %d、下标 %d（应 SUCCESS、另一张已归还图 0）", rc, idx);
    CHECK(c1[0] == c0[0] && c1[2] == c0[2],
          "③ 同线程撞图：进入翻走等待 %llu 次（应 0：不等自己）、交出在屏那张 %llu 次（应 0）",
          (unsigned long long)(c1[0] - c0[0]), (unsigned long long)(c1[2] - c0[2]));
    g_pres(NULL, &g_win, idx);

    // ④ 另一张图 0 已被本线程取走、尚未呈现时再撞图：没有已归还图，保持旧行为，SUCCESS 交原在屏下标 1 并计红。
    o->shown = 2; o->next = 1;
    idx = -1; CHECK(g_acq(&g_win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == 0,
                   "④ 先租下图 0：结果成功、下标 0");
    o->next = 1; idx = -1;
    s2a_nvn_acq_counts(c0); rc = g_acq(&g_win, NULL, &idx); s2a_nvn_acq_counts(c1);
    CHECK(rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == 1,
          "④ 无已归还图时：结果 %d、下标 %d（应 SUCCESS、旧下标 1）", rc, idx);
    CHECK(c1[0] == c0[0] && c1[2] == c0[2] + 1, "④ 无候选：不等自己、交出在屏计数 +1");
    g_pres(NULL, &g_win, 0);

    nvn_be_drain();
    winFini(&g_win);
    for (int i = 0; i < 2; i++) texFini(&textures[i]);
    poolFini(&pool); devFini(&device); free(storage);
    printf("%s t_nvn_win_shown：500ms 超时改交已归还图 / 借帧立即返回 / 同线程撞图保持成功 / 无候选保持旧行为 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
