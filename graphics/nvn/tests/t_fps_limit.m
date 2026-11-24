// #604：真实生产宿主 / 三前端 / Metal / 时钟。自建交换链，不需要游戏或替身。
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include "../gfx/nvn/nvn_protos.h"
#include "../gfx/nvn/nvn_mtl.h"
#include "s2a_hud.h"
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

void *h_nvnBootstrapLoader(const char *name);
#include <pthread.h>
// FPS_TEST_SPLIT=1（NVN）：每帧的取图在一个固定的另一线程做、上屏在测试主循环线程做（11-02 牧场物语：游戏主线程取图、渲染线程上屏，
//   节拍主人原先是上屏线程，取图线程从不睡节拍，帧率不封顶）。期望帧间隔同单线程：节拍跟着出帧的取图线程
static int split; static dispatch_semaphore_t split_go, split_done; static NVNwindow *volatile split_w; static int split_idx, split_rc;
static void *split_thread(void *a) {
    (void)a;
    for (;;) { dispatch_semaphore_wait(split_go, DISPATCH_TIME_FOREVER); int i = -1;
        split_rc = ((NVNwindowAcquireTextureResult (*)(NVNwindow *, NVNsync *, int *))h_nvnBootstrapLoader("nvnWindowAcquireTexture"))(split_w, NULL, &i);
        split_idx = i; dispatch_semaphore_signal(split_done); }
    return NULL;
}
void *dm_vk_lookup(const char *name);
void *gl_entry(const char *name);
void s2a_front_run(void (*guest_main)(void));
void *s2a_mac_front_layer(void);
void *front_metal_layer(void);
double nvn_be_presented_time(uint64_t ticket);
uint64_t mtl_present_count(void);
int nvn_be_link_active(void);
int nvn_be_link_wait_tick(int vsyncs, uint64_t timeout_ns);
int dm_focus_now(void);
uint64_t dm_focus_in_since(void);
uint64_t now_ns(void);
uint64_t s2a_nvn_pace_waits_self(void);   // hle_nvn.c 只读计数：本线程进入节拍等待（限帧睡眠 / 等显示链接拍）的次数
void s2a_nvn_pace_stats(uint64_t *n, uint64_t *period_ns);   // hle_nvn.c 只读计数：取图里节拍器做过决定的次数、最近一次的节拍周期
void s2a_gl_pace_stats(uint64_t out[5]);   // egl.m 只读计数：交换锁自己时钟一支的排拍次数 / 周期 / 多跨的刻度 / 真睡 / 单次最长要睡
static uint64_t gl_pace0[5], gl_pace1[5], nv_pace0, nv_pace1, nv_period;   // 计时窗口（第 48 帧到第 48+samples 帧）两端的读数

static int checked, failed, interval, windowed, check_hud, dynamic, return_one, deactivate, samples = 60;
static int focus_probe, focus_lost, focus_restored, stall_probe, flap;
static double flap_t[360]; static int flap_itv[360];
static NSWindow *focus_window;
static uint64_t focus_loss_ns;
static const char *frontend;
static double target_ms, stamp[241];
static uint64_t link_start_n, link_start_ns, link_end_n, link_end_ns;
static double clock_s(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
#define CHECK(c, ...) do { checked++; int pass = !!(c); failed += !pass; printf("%s ", pass ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *entry(void *(*lookup)(const char *), const char *name) {
    void *p = lookup(name);
    if (!p) { fprintf(stderr, "缺生产入口 %s\n", name); exit(1); }
    return p;
}
#define NV(name) ((NVNT_##name)entry(h_nvnBootstrapLoader, #name))
#define VK(name) ((PFN_##name)entry(dm_vk_lookup, #name))
#define GL(name, ret, ...) ret (*name)(__VA_ARGS__) = (ret (*)(__VA_ARGS__))entry(gl_entry, #name)
static void window_state(int phase, int frame) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (NSWindow *w in NSApp.windows) printf("窗口状态 phase%d frame%d：active=%d visible=%d occluded=%d minimized=%d key=%d\n",
            phase, frame, NSApp.isActive, w.isVisible, !(w.occlusionState & NSWindowOcclusionStateVisible), w.isMiniaturized, w.isKeyWindow);
        fflush(stdout);
    });
}
static void mark(int frame) {
    if (frame >= 48) stamp[frame - 48] = clock_s();
    if (frame == 48 || frame == 48 + samples) { uint64_t p; s2a_nvn_pace_stats(frame == 48 ? &nv_pace0 : &nv_pace1, &p); if (frame > 48) nv_period = p; s2a_gl_pace_stats(frame == 48 ? gl_pace0 : gl_pace1); }
    if (windowed && frame == 48) nvn_be_link_sample(&link_start_n, &link_start_ns);
    if (windowed && frame == 48 + samples) nvn_be_link_sample(&link_end_n, &link_end_ns);
    if (windowed && (frame == 47 || frame == 48 + samples)) window_state(0, frame);
}
static int slow_ms(void) { static int v = -1; if (v < 0) { const char *e = getenv("FPS_TEST_SLOW_MS"); v = e ? atoi(e) : 0; } return v; }
static void delay(int frame) {
    // FPS_TEST_SLOW_MS=<毫秒>：计时窗口里每帧游戏自己多花这么久（慢机 / 高负载的确定性替身，不在共享主机上造满载）。
    //   12 ms 复现 11-23 门禁机那次（GL 上限 120 均值 12.27 ms > 1.3 倍判红）：限帧器照样每帧排拍，只是帧本身比周期长
    if (slow_ms() && frame > 48 && frame <= 48 + samples) { struct timespec s = {0, (long)slow_ms() * 1000000L}; nanosleep(&s, NULL); }
    // 停顿放在计时窗口（第 48 帧起）之前：仍在 HUD 的 10 秒环里产生慢帧，但不混进周期判据（#619：8.3 ms 周期下 60 个样本只有 0.5 秒，停顿 200 ms 会把均值撑出容差）
    if (check_hud && frame == 20) { struct timespec pause = {0, 200000000}; nanosleep(&pause, NULL); }
}

static double median10(const double *v) {   // 10 个数的中位数（第 5、6 小的均值）
    double a[10]; memcpy(a, v, sizeof a);
    for (int i = 1; i < 10; i++) for (int j = i; j > 0 && a[j - 1] > a[j]; j--) { double t = a[j]; a[j] = a[j - 1]; a[j - 1] = t; }
    return (a[4] + a[5]) / 2;
}
static void dynamic_result(int phase, const double *times, uint64_t first, double hz) {
    // 期望来自60Hz游戏vsync：2/60、3/60，以及逐帧2↔3的均值，不从被测实现反推。
    const double expected[] = {1000.0 / 30, 50, 1000.0 / 30, 1000.0 / 24};
    double mean = (times[60] - times[0]) * 1000 / 60;
    // 阶段 3（逐帧 2↔3）：30 / 20 Hz 链路给不出 50 / 33.3 ms 的整刻度，链路回 60 Hz，2、3 个 60 Hz 刻度交替，均值 41.7 ms；
    //   11-04 金刚真机：原先链路留在 30 Hz、间隔 3 取整成 2 刻度，均值 50 ms（1.2 倍）也落在旧的 1.3 倍容差里，所以本阶段上限收到 1.1 倍
    double hi = phase == 3 ? 1.10 : 1.30;
    CHECK(mean >= expected[phase] * .90 && mean <= expected[phase] * hi,
        "NVN动态阶段%d真实取图周期 %.3f ms，期望 %.3f ms（上限 %.2f 倍）", phase, mean, expected[phase], hi);
    const double rates[] = {30, 20, 30};
    // Per-frame changes are asynchronous hints, not an instantaneous 24 Hz
    // callback clock. Keep exact stable rates and bound the mixed phase by
    // its two requested rates, with the same 10% measurement tolerance.
    double low_hz = phase == 3 ? 60 : rates[phase], high_hz = phase == 3 ? 60 : rates[phase];
    CHECK(hz > low_hz * .9 && hz < high_hz * 1.1,
        "NVN动态阶段%d实际链接 %.3f Hz，期望 %.0f..%.0f Hz（低频档表示不了当前周期就回 60 Hz）", phase, hz, low_hz, high_hz);
    // 不要求每票都有显示回调；只数真实正presentedTime，保持原45张下限。
    unsigned actual = 0, gaps = 0, unconfirmed = 0, discarded = 0;
    double previous = 0, sum = 0;
    for (uint64_t n = first; n < first + 60; n++) {
        double t = nvn_be_presented_time(n);
        if (t > 0) { actual++; if (previous > 0) { sum += t - previous; gaps++; } previous = t; }
        else if (t < 0) discarded++;
        else unconfirmed++;
    }
    printf("NVN动态阶段%d票%llu..%llu：显示%u、丢弃%u、未确认%u\n", phase,
        (unsigned long long)first, (unsigned long long)(first + 59), actual, discarded, unconfirmed);
    CHECK(actual >= 45, "NVN动态阶段%d真实显示%u/60", phase, actual);
    double shown = gaps ? sum * 1000 / gaps : 0;
    CHECK(shown >= expected[phase] * .90 && shown <= expected[phase] * hi,
        "NVN动态阶段%d实际显示周期 %.3f ms / %u次，期望 %.3f ms", phase, shown, gaps, expected[phase]);
}

static void nvn_frames(void) {
    NVNdevice device = {0}; NVNdeviceBuilder db = {0};
    NV(nvnDeviceBuilderSetDefaults)(&db);
    CHECK(NV(nvnDeviceInitialize)(&device, &db), "NVN 生产设备初始化");
    void *storage = NULL;
    if (posix_memalign(&storage, 16384, 3 * 65536)) exit(1);
    for (unsigned i = 0; i < 3 * 65536 / 4; i++) ((uint32_t *)storage)[i] = 0xff224488;
    NVNmemoryPool pool = {0}; NVNmemoryPoolBuilder pb = {0};
    NV(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    NV(nvnMemoryPoolBuilderSetDefaults)(&pb);
    NV(nvnMemoryPoolBuilderSetStorage)(&pb, storage, 3 * 65536);
    NV(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    CHECK(NV(nvnMemoryPoolInitialize)(&pool, &pb), "NVN 生产内存池初始化");
    NVNtexture textures[3] = {0}; NVNtexture *ptrs[3];
    for (int i = 0; i < 3; i++) {
        NVNtextureBuilder tb = {0};
        NV(nvnTextureBuilderSetDevice)(&tb, &device);
        NV(nvnTextureBuilderSetDefaults)(&tb);
        NV(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
        NV(nvnTextureBuilderSetSize2D)(&tb, 64, 64);
        NV(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
        NV(nvnTextureBuilderSetFlags)(&tb, NVN_TEXTURE_FLAGS_LINEAR);
        NV(nvnTextureBuilderSetStride)(&tb, 256);
        NV(nvnTextureBuilderSetStorage)(&tb, &pool, i * 65536);
        CHECK(NV(nvnTextureInitialize)(&textures[i], &tb), "NVN 生产交换链纹理 %d", i);
        ptrs[i] = &textures[i];
    }
    NVNwindow window = {0}; NVNwindowBuilder wb = {0};
    NV(nvnWindowBuilderSetDevice)(&wb, &device);
    NV(nvnWindowBuilderSetDefaults)(&wb);
    NV(nvnWindowBuilderSetTextures)(&wb, 3, ptrs);
    NV(nvnWindowBuilderSetPresentInterval)(&wb, interval);
    CHECK(NV(nvnWindowInitialize)(&window, &wb), "NVN 生产窗口初始化");
    double submit[60]; uint64_t present_pace = 0; double phase_stamp[4][61] = {0}, phase_hz[4] = {0}, transition[4][12] = {0};
    uint64_t phase_n = 0, phase_ns = 0;
    int frames = flap ? 360 : deactivate || focus_probe || stall_probe ? 139 : dynamic ? 4 * 109 : 49 + samples;
    uint64_t inactive_n = 0, inactive_ns = 0;
    for (int frame = 0; frame < frames; frame++) {
        int phase = frame / 109, local = dynamic ? frame % 109 : frame;
        if (dynamic) {
            interval = phase == 1 ? 3 : phase == 3 ? 2 + (local & 1) : phase == 2 && return_one ? 1 : 2;
            NV(nvnWindowSetPresentInterval)(&window, interval);
            CHECK(NV(nvnWindowGetPresentInterval)(&window) == interval, "动态游戏interval仍%d（帧%d）", interval, frame);
        }
        // FPS_TEST_FLAP（金刚真机形态）：前 60 帧间隔 2（稳 2 秒，链路降 30 Hz），之后每 30 帧 29 帧间隔 3、1 帧间隔 2
        if (flap) { interval = frame < 60 ? 2 : (frame - 60) % 30 == 29 ? 2 : 3; flap_itv[frame] = interval; NV(nvnWindowSetPresentInterval)(&window, interval); }
        delay(frame);
        int index = -1;
        double acquire_at = clock_s();
        if (split) { split_w = &window; dispatch_semaphore_signal(split_go); dispatch_semaphore_wait(split_done, DISPATCH_TIME_FOREVER); index = split_idx;   // FPS_TEST_SPLIT：取图在另一个线程（牧场物语形态：主线程取图、渲染线程上屏）
                     CHECK(split_rc == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS, "NVN acquire（取图线程）%d", frame); }
        else CHECK(NV(nvnWindowAcquireTexture)(&window, NULL, &index) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS, "NVN acquire %d", frame);
        if (dynamic && local < 12) transition[phase][local] = (clock_s() - acquire_at) * 1000;
        if (flap) flap_t[frame] = acquire_at;
        if (!dynamic && !flap) mark(frame);
        else if (dynamic && local >= 48) {
            phase_stamp[phase][local - 48] = clock_s();
            if (local == 48) nvn_be_link_sample(&phase_n, &phase_ns);
            if (local == 108) { uint64_t n, ns; nvn_be_link_sample(&n, &ns); phase_hz[phase] = ns > phase_ns ? (n - phase_n) * 1e9 / (ns - phase_ns) : 0; }
        }
        if (dynamic && (local == 47 || local == 108)) window_state(phase, local);
        if (focus_probe && (frame == 10 || frame == 55)) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSWindow *window = nil;
                for (NSWindow *w in NSApp.windows) if ((__bridge void *)w.contentView.layer == s2a_mac_front_layer()) { window = w; break; }
                if (frame == 10) {
                    BOOL was_key = window.isKeyWindow;
                    int was_focused = dm_focus_now();
                    // Use AppKit's real key-window scheduling. Calling the
                    // resign/become override points directly does not request
                    // an application key-window transition.
                    if (NSApp.isActive && was_key) {
                        focus_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 120, 80) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
                        focus_window.releasedWhenClosed = NO;
                        focus_window.title = @"S2Arm focus probe";
                        [focus_window orderFront:nil]; [focus_window makeKeyWindow];
                    }
                    focus_loss_ns = now_ns();
                    focus_lost = window && was_key && was_focused == 1 && focus_window.isKeyWindow && !window.isKeyWindow && dm_focus_now() == 0;
                    printf("FOCUS_LOST at %llu ns active=%d key=%d getter=%d since=%llu hit=%d\n", (unsigned long long)now_ns(), NSApp.isActive, window.isKeyWindow, dm_focus_now(), (unsigned long long)dm_focus_in_since(), focus_lost);
                } else {
                    // Only our already-active application may restore its own
                    // key window. Never activate an app or steal user focus.
                    if (NSApp.isActive && focus_window.isKeyWindow) [window makeKeyWindow];
                    uint64_t t = now_ns(), since = dm_focus_in_since();
                    focus_restored = focus_lost && NSApp.isActive && window.isKeyWindow && dm_focus_now() == 1 && since > focus_loss_ns && since <= t;
                    printf("FOCUS_RESTORED at %llu ns active=%d key=%d getter=%d since=%llu hit=%d\n", (unsigned long long)t, NSApp.isActive, window.isKeyWindow, dm_focus_now(), (unsigned long long)since, focus_restored);
                    [focus_window close]; focus_window = nil;
                }
                fflush(stdout);
            });
        }
        if (deactivate && frame == 75) {
            nvn_be_link_sample(&inactive_n, &inactive_ns);
            dispatch_sync(dispatch_get_main_queue(), ^{
                printf("受控失活：本测试进程 deactivate，之前active=%d\n", NSApp.isActive);
                [NSApp deactivate];
            });
            window_state(0, frame);
        }
        double t = clock_s(); uint64_t pw = s2a_nvn_pace_waits_self(); NV(nvnQueuePresentTexture)(NULL, &window, index);
        if (local >= 49 && local < 109) { submit[local - 49] = (clock_s() - t) * 1000; present_pace += s2a_nvn_pace_waits_self() - pw; }
    }
    // 同时核公开查询：上限不可通过改写游戏 interval 实现。
    CHECK(NV(nvnWindowGetPresentInterval)(&window) == interval, "NVN 游戏 interval 仍为 %d", interval);
    double total = 0; for (int i = 0; i < 60; i++) total += submit[i];
    // 原判上屏均值 < 5 ms：负载高时上屏线程被抢占就假红。改判上屏里进入节拍等待的次数 = 0（限帧等待只许在取图里做）；用时只打出来参考
    CHECK(present_pace == 0, "NVN present 只入队：60 次上屏里进入限帧等待 %llu 次（期望 0；均值 %.3f ms 仅供参考，不得承担 %.3f ms 限帧等待）", (unsigned long long)present_pace, total / 60, target_ms);
    nvn_be_drain();
    if (deactivate) {
        uint64_t n, ns; nvn_be_link_sample(&n, &ns);
        printf("受控失活后真实链接 %.3f Hz（%llu拍），不把请求60Hz当实际60Hz\n",
            ns > inactive_ns ? (n - inactive_n) * 1e9 / (ns - inactive_ns) : 0, (unsigned long long)(n - inactive_n));
        window_state(0, frames);
    }
    if (dynamic) {
        // 取第 1–10 帧单帧时长的中位数，不取均值（11-10 守望 3c25b2888：门禁机负载下 10 帧里一两帧被多拖一拍，均值 36.692 ms 越过 1.1 倍线 36.667 ms 判红）。
        //   要分的是「立即按 60 Hz 等 2 / 3 拍」与旧行为「留在 30 Hz 等 2 拍 = 66.7 ms」：旧行为每帧都慢，中位数照样是 66.7，个别被拖的帧不动中位数
        double to20 = median10(&transition[1][1]), to30 = median10(&transition[2][1]);
        // 11-04：低频档表示不了新周期就立即回 60 Hz，新周期从第一帧起就按自己的刻度（3 / 2 个 60 Hz 刻度），
        //   不再「首 10 帧仍按原 30 Hz 等 2 拍（66.7 ms）/ 原 20 Hz 等 1 拍（50 ms）」
        CHECK(to20 >= 50 * .90 && to20 <= 50 * 1.10,
            "50ms新周期首10帧立即按60Hz等3拍（单帧中位）：%.3f ms，期望50ms", to20);
        CHECK(to30 >= (1000.0 / 30) * .90 && to30 <= (1000.0 / 30) * 1.10,
            "33.3ms恢复首10帧立即按60Hz等2拍（单帧中位）：%.3f ms，期望33.333ms", to30);
    }
    if (dynamic) for (int phase = 0; phase < 4; phase++) {
        // 不丢过渡证据：SetInterval先于acquire，而link_sync仍在后面的present入口。
        for (int local = 0; local < 12; local++) {
            uint64_t ticket = phase * 109 + local + 1;
            double a = ticket > 1 ? nvn_be_presented_time(ticket - 1) : 0, b = nvn_be_presented_time(ticket);
            printf("NVN动态过渡阶段%d首%d帧票%llu：acquire %.3f ms，actual_present_gap_ms ", phase, local,
                (unsigned long long)ticket, transition[phase][local]);
            if (a > 0 && b > a) printf("%.3f\n", (b - a) * 1000); else puts("未测");
        }
        dynamic_result(phase, phase_stamp[phase], phase * 109 + 50, phase_hz[phase]);
    }
    if (return_one) {
        // No presents remain in the queue: prove the cap in the production
        // tick wait itself, without relying on the drawable hold/backpressure.
        NV(nvnWindowSetPresentInterval)(&window, 1);
        CHECK(NV(nvnWindowGetPresentInterval)(&window) == 1, "混合会话回1保持公开interval");
        // 等真实显示链接拍的上限 30 秒（原 100 ms：负载高时链接回调晚到就判「没等到拍」假红）；拍到了就返回，下面的均值判据不受影响
        for (int i = 0; i < 2; i++) CHECK(nvn_be_link_wait_tick(1, 30000000000ull), "cap30直接真实tick预热%d", i);
        double start = clock_s();
        for (int i = 0; i < 20; i++) CHECK(nvn_be_link_wait_tick(1, 30000000000ull), "cap30直接真实tick%d", i);
        double mean = (clock_s() - start) * 1000 / 20;
        CHECK(mean >= 30 && mean <= 1000.0 / 30 * 1.3,
            "cap30无队列反压直接wait_tick(1)均值 %.3f ms，期望33.333ms", mean);
    }
    for (int i = 0; i < 3; i++) NV(nvnTextureFinalize)(&textures[i]);
    NV(nvnMemoryPoolFinalize)(&pool); NV(nvnDeviceFinalize)(&device); free(storage);
}

static void gl_frames(void) {
    // 不调用首次使用的 GetDisplay：它为真实游戏准备着色器库；本测只做真实表面清屏，无着色器。
    GL(eglCreateWindowSurface, void *, void *, void *, void *, const int *);
    GL(eglCreateContext, void *, void *, void *, void *, const int *);
    GL(eglMakeCurrent, unsigned, void *, void *, void *, void *);
    GL(eglSwapInterval, unsigned, void *, int);
    GL(eglSwapBuffers, unsigned, void *, void *);
    GL(eglDestroySurface, unsigned, void *, void *);
    GL(eglDestroyContext, unsigned, void *, void *);
    GL(glClearColor, void, float, float, float, float);
    GL(glClear, void, unsigned);
    void *surface = eglCreateWindowSurface(NULL, NULL, NULL, NULL);
    void *context = eglCreateContext(NULL, NULL, NULL, NULL);
    CHECK(surface && context && eglMakeCurrent(NULL, surface, surface, context), "GL 生产 EGL 表面和上下文");
    CHECK(eglSwapInterval(NULL, interval), "GL 游戏交换间隔 %d", interval);
    glClearColor(.125, .25, .5, 1);
    for (int frame = 0; frame <= 48 + samples; frame++) {
        delay(frame);
        glClear(0x4000);
        CHECK(eglSwapBuffers(NULL, surface), "GL swap %d", frame);
        mark(frame);
    }
    nvn_be_drain();
    CHECK(eglDestroySurface(NULL, surface) && eglDestroyContext(NULL, context), "GL 生产表面和上下文释放");
}

static void vk_frames(void) {
    VkSwapchainCreateInfoKHR ci = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .minImageCount = 3,
        .imageFormat = VK_FORMAT_R8G8B8A8_UNORM, .imageExtent = {64, 64}, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, .presentMode = VK_PRESENT_MODE_FIFO_KHR};
    VkSwapchainKHR chain = VK_NULL_HANDLE;
    CHECK(VK(vkCreateSwapchainKHR)(VK_NULL_HANDLE, &ci, NULL, &chain) == VK_SUCCESS && chain, "VK 生产交换链");
    for (int frame = 0; frame <= 48 + samples; frame++) {
        delay(frame);
        uint32_t index;
        CHECK(VK(vkAcquireNextImageKHR)(VK_NULL_HANDLE, chain, UINT64_MAX, VK_NULL_HANDLE, VK_NULL_HANDLE, &index) == VK_SUCCESS, "VK acquire %d", frame);
        mark(frame);
        VkPresentInfoKHR pi = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .swapchainCount = 1, .pSwapchains = &chain, .pImageIndices = &index};
        CHECK(VK(vkQueuePresentKHR)(VK_NULL_HANDLE, &pi) == VK_SUCCESS, "VK present %d", frame);
    }
    nvn_be_drain(); VK(vkDestroySwapchainKHR)(VK_NULL_HANDLE, chain, NULL);
}

static void hud_result(void) {
    // 只读真实生产者ap_host的上屏时间戳；不写环、不伪造时钟。此局不到10秒，全部109次真实帧边界都应仍在窗内。
    extern _Atomic uint64_t g_s2a_hud_ft[2048], g_s2a_hud_fn;
    // 期望目标由脚本按场景给（FPS_TEST_HUD_TARGET = 上限：原生 60 + 上限 30 → 30；GL 交换间隔 0 + 上限 120 → 120），慢帧阈值 1.5 × 1/目标独立手算
    const char *te = getenv("FPS_TEST_HUD_TARGET"); int want = te ? atoi(te) : 30;
    CHECK(want == 30 || want == 60 || want == 120, "FPS_TEST_HUD_TARGET=%s 只接受 30/60/120", te ? te : "");
    if (want != 30 && want != 60 && want != 120) return;
    uint64_t n = atomic_load(&g_s2a_hud_fn); unsigned slow = 0;
    CHECK(n == 109, "HUD生产者记录109个真实帧边界，实有%llu", (unsigned long long)n);
    if (n != 109) return;
    for (uint64_t i = 1; i < n; i++) {
        uint64_t a = atomic_load(&g_s2a_hud_ft[i - 1]), b = atomic_load(&g_s2a_hud_ft[i]);
        CHECK(a && b > a, "HUD真实时间戳%llu递增", (unsigned long long)i);
        if (b - a > 1500000000ull / (uint64_t)want) slow++;   // 独立真值：1.5 × 1/目标（30 → 50 ms，120 → 12.5 ms）
    }
    // 原另判慢帧 < 10：负载高时真实帧间隔多被拖长就假红（慢帧数随负载涨，不是 HUD 的错）。HUD 的判据是它算出的慢帧占比与同一批真实时间戳独立数出的一致（下面），
    //   这里只留「200 ms 停顿至少产生一个慢帧」
    CHECK(slow > 0, "200ms真实停顿产生慢帧：%u/%llu间隔", slow, (unsigned long long)(n - 1));
    char text[4096]; char *out = text;
    dispatch_sync(dispatch_get_main_queue(), ^{
        s2a_hud_host h = {.thermal = "未测", .build_id = "fps-limit-test", .battery_rate_pm = NAN, .battery_level = -1};
        s2a_hud_text(out, 4096, &h);
    });
    int target = 0, denominator = 0; double percent = -1;
    const char *p = strstr(text, "目标 "); if (p) sscanf(p, "目标 %d", &target);
    p = strstr(text, "慢帧 "); if (p) sscanf(p, "慢帧 %lf", &percent);
    p = strstr(text, "近 10 秒 "); if (p) sscanf(p, "近 10 秒 %d", &denominator);
    CHECK(target == want, "HUD有效目标%d（实际生效周期 max(游戏间隔, 1/上限) 对应的帧率），实际%d", want, target);
    CHECK(denominator == 108, "HUD慢帧分母是108个真实间隔，实际%d", denominator);
    double expected = round(1000.0 * slow / 108) / 10;
    CHECK(fabs(percent - expected) < .001, "HUD慢帧%.1f%%，真实%u/108间隔应%.1f%%", percent, slow, expected);
}

static void run(void) {
    @autoreleasepool {
        if (!strcmp(frontend, "nvn")) nvn_frames();
        else if (!strcmp(frontend, "gl")) gl_frames();
        else if (!strcmp(frontend, "vk")) vk_frames();
        else exit(2);
        if (flap) {
            // 期望（按 60 Hz 刻度手算，不跑被测实现）：间隔 3 的帧 50 ms、间隔 2 的帧 33.3 ms，各取第 90 帧以后的均值（避开开头换档）；
            //   旧实现链路留在 30 Hz：间隔 3 取整成 2 刻度 ≈ 66.7 ms；留在 20 Hz：间隔 2 被拖成 50 ms；容差 ±10%
            double sum[4] = {0}; int cnt[4] = {0};
            for (int f = 90; f < 359; f++) { int i = flap_itv[f]; sum[i] += (flap_t[f + 1] - flap_t[f]) * 1000; cnt[i]++; }
            double m3 = cnt[3] ? sum[3] / cnt[3] : 0, m2 = cnt[2] ? sum[2] / cnt[2] : 0;
            CHECK(m3 >= 50 * .90 && m3 <= 50 * 1.10, "来回切间隔3帧周期 %.3f ms（%d 帧），期望 50 ms", m3, cnt[3]);
            CHECK(m2 >= (1000.0 / 30) * .90 && m2 <= (1000.0 / 30) * 1.10, "来回切间隔2帧周期 %.3f ms（%d 帧），期望 33.333 ms", m2, cnt[2]);
        }
        if (dynamic || deactivate || focus_probe || stall_probe || flap) {
            if (focus_probe && !focus_restored) puts("UNTESTED 真实失焦/恢复未完整命中，不激活App补造条件");
            printf("fps limit: %d/%d passed\n", checked - failed, checked); printf("%s t_fps_limit\n", failed ? "✗" : "✓"); fflush(stdout);
            exit(failed ? 1 : focus_probe && !focus_restored ? 2 : 0);
        }
        double link_hz = link_end_ns > link_start_ns ? (link_end_n - link_start_n) * 1e9 / (link_end_ns - link_start_ns) : 0;
        if (windowed) printf("实际显示链接计数频率 %.3f Hz（%llu 拍 / %.3f ms）\n", link_hz,
            (unsigned long long)(link_end_n - link_start_n), (link_end_ns - link_start_ns) / 1e6);
        int pin30 = getenv("DM_FPS") && atoi(getenv("DM_FPS")) == 30;
        int pin60 = getenv("DM_FPS") && atoi(getenv("DM_FPS")) == 60;
        int auto20 = !strcmp(frontend, "nvn") && interval == 3 && !pin30 && !pin60;
        if (windowed && auto20) CHECK(link_hz > 18 && link_hz < 22,
            "interval3实际显示链接 %.3f Hz，期望20Hz（不以60Hz上出20帧代替）", link_hz);
        if (windowed && !auto20 && atoi(getenv("DM_PRESENT_LINK")) == 2 && atoi(getenv("S2A_FPS")) != 30 && (link_hz < 110 || link_hz > 130)) {
            printf("UNTESTED 120 Hz 窗口场景：真实显示链接为 %.3f Hz，不能证明120支持\n", link_hz); exit(2);
        }
        double elapsed_ms = (stamp[samples] - stamp[0]) * 1000, mean = elapsed_ms / samples;
        // 只有用户上限在限帧（GL 交换间隔 0 / NVN 无原生节拍 DM_PRESENT_HZ=0）、且没有显示链接时：节拍全靠我们自己的限帧器睡。墙钟均值的上沿量的是机器快不快
        //   （11-23 门禁机负载下 GL 上限 120 均值 12.27 ms > 1.3 倍判红、时红时绿，守望误派），改按限帧器自己的决定判：窗口里每帧都排过节拍、
        //   算出的周期 = 1/上限（期望按上限独立算，不读被测实现）、单次要睡不超过 1.5 个周期（正确实现 ≤ 1 个，睡两拍的错误是 2 个）；
        //   墙钟只留下沿（负载只会让它更慢，不会更快：限帧器被拿掉时均值远低于周期）
        int cap = getenv("S2A_FPS") ? atoi(getenv("S2A_FPS")) : 0, hz = getenv("DM_PRESENT_HZ") ? atoi(getenv("DM_PRESENT_HZ")) : 60;
        int gl0 = !strcmp(frontend, "gl") && interval == 0, nv0 = !strcmp(frontend, "nvn") && hz == 0;
        if (target_ms > 0 && cap > 0 && (gl0 || nv0) && !nvn_be_link_active()) {
            uint64_t want = (uint64_t)(1e9 / cap + .5);
            uint64_t n = gl0 ? gl_pace1[0] - gl_pace0[0] : nv_pace1 - nv_pace0, per = gl0 ? gl_pace1[1] : nv_period;
            CHECK(n == (uint64_t)samples, "%s 限帧器：计时窗口 %d 帧里排过节拍 %llu 帧（期望每帧都排）", frontend, samples, (unsigned long long)n);
            CHECK(per + 1 >= want && per <= want + 1, "%s 限帧器算出的周期 %llu ns，期望 1/%d 秒 = %llu ns", frontend, (unsigned long long)per, cap, (unsigned long long)want);
            // 截止时刻按刻度走：要睡的永远 ≤ 1 个周期（首帧从现在起拍那一次正好 1 个周期；留 1 µs 取整）
            if (gl0) CHECK(gl_pace1[4] <= per + 1000, "GL 限帧器单次最长要睡 %.3f ms，期望 ≤ 1 个周期 %.3f ms（多跨刻度 %llu 个、真睡 %llu 次）",
                gl_pace1[4] / 1e6, per / 1e6, (unsigned long long)(gl_pace1[2] - gl_pace0[2]), (unsigned long long)(gl_pace1[3] - gl_pace0[3]));
            // 慢机格（帧比周期长）：每帧都该落到下一个刻度——窗口里多跨的刻度 ≥ 帧数（期望按「帧长 > 周期 ⇒ k ≥ 2」独立推，不读实现）。
            //   11-23 前「从现在重新起拍再整睡一周期」不跨刻度（0 个），12 ms 帧被拖到约 24 ms；帧间隔中位只作读数（墙钟，负载下会变）
            if (gl0 && slow_ms() && slow_ms() * 1000000.0 > per) {
                double iv[240]; int ni = 0; for (int k = 1; k <= samples; k++) iv[ni++] = (stamp[k] - stamp[k - 1]) * 1000;
                for (int a = 1; a < ni; a++) for (int b = a; b > 0 && iv[b - 1] > iv[b]; b--) { double t = iv[b]; iv[b] = iv[b - 1]; iv[b - 1] = t; }
                CHECK(gl_pace1[2] - gl_pace0[2] >= (uint64_t)samples, "GL 慢帧落到下一个刻度：窗口 %d 帧多跨刻度 %llu 个（期望 ≥ %d：每帧 %d ms > 周期 %.3f ms）；帧间隔中位 %.3f ms（读数，按刻度应约 %.3f ms）",
                    samples, (unsigned long long)(gl_pace1[2] - gl_pace0[2]), samples, slow_ms(), per / 1e6, iv[ni / 2], ceil(slow_ms() * 1e6 / per) * per / 1e6);
            }
            CHECK(mean >= target_ms * .90, "%s 真实时钟：%d 周期 %.3f ms、均值 %.3f ms；期望 ≥ %.3f ms 的九成（只判下沿，上沿看限帧器读数）", frontend, samples, elapsed_ms, mean, target_ms);
            // 慢调度注入那一格：先证注入真生效（均值确实超出旧判据的 1.3 倍上沿，旧判据在这里必红），上面的计数判据照样要绿
            if (slow_ms()) CHECK(mean > target_ms * 1.30, "慢调度注入生效：每帧多花 %d ms，均值 %.3f ms > %.3f ms（旧墙钟上沿判据在这里会红）", slow_ms(), mean, target_ms * 1.30);
        } else CHECK(target_ms ? mean >= target_ms * .90 && mean <= target_ms * 1.30 : mean < 5,
            "%s 真实时钟：%d 周期 %.3f ms、均值 %.3f ms；期望 %.3f ms（上限0/无原生节拍时 <5 ms）", frontend, samples, elapsed_ms, mean, target_ms);
        if (windowed) {
            CHECK(nvn_be_link_active() == (atoi(getenv("DM_PRESENT_LINK")) != 0), "生产显示链接选路");
            // 票号即实际入队次数；mtl_present_count是取出的张数，FIFO合并时不能拿它当末票号。
            uint64_t count = 49 + samples, first = count - samples + 1; int actual = 0, unpaced = !strcmp(frontend, "gl") && !interval && !atoi(getenv("S2A_FPS"));
            CHECK(mtl_present_count() <= count, "实际取出张数不超过入队%llu张", (unsigned long long)count);
            // Apple只在已呈现后承诺handler，系统跳过的drawable可能始终为0。只等足够正时间戳，0绝不计显示。
            unsigned shown_n = 0; double deadline = clock_s() + 3;
            do {
                shown_n = 0; for (uint64_t n = first; n <= count; n++) shown_n += nvn_be_presented_time(n) > 0;
                if (shown_n >= 45) break;
                struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
            } while (clock_s() < deadline);
            double previous = 0, sum = 0; unsigned intervals = 0, unconfirmed = 0, discarded = 0;
            // 无节拍控制扩大到240个实际周期（约1秒），覆盖合法FIFO合并；至少45次真实显示与时间判据不变。
            for (uint64_t n = first; n <= count; n++) {
                double t = nvn_be_presented_time(n);
                if (t > 0) { actual++; if (previous > 0) { sum += t - previous; intervals++; } previous = t; }
                else if (t < 0) discarded++;
                else unconfirmed++;
            }
            printf("呈现票号%llu..%llu：真实显示%d，明确丢弃%u，未确认显示%u（0不计成功）\n",
                (unsigned long long)first, (unsigned long long)count, actual, discarded, unconfirmed);
            CHECK(actual >= 45, "真实 GPU 呈现回调 %d/%d（系统丢弃不算显示）", actual, samples);
            double shown = intervals ? sum * 1000 / intervals : 0;
            double display_ms = unpaced && link_hz > 0 ? 1000 / link_hz : target_ms;
            CHECK(display_ms > 0 && shown >= display_ms * .90 && shown <= display_ms * 1.30,
                "实际显示周期 %.3f ms / %u 次；期望 %.3f ms", shown, intervals, display_ms);
        }
        if (check_hud) hud_result();
        printf("fps limit: %d/%d passed\n", checked - failed, checked); printf("%s t_fps_limit\n", failed ? "✗" : "✓"); fflush(stdout); exit(failed ? 1 : 0);
    }
}
int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "用法：%s nvn|gl|vk interval expected_ms windowed\n", argv[0]); return 2; }
    frontend = argv[1]; interval = atoi(argv[2]); target_ms = atof(argv[3]); windowed = atoi(argv[4]); alarm(30);
    check_hud = getenv("FPS_TEST_HUD") && !strcmp(getenv("FPS_TEST_HUD"), "1");
    dynamic = getenv("FPS_TEST_DYNAMIC") && !strcmp(getenv("FPS_TEST_DYNAMIC"), "1");
    return_one = getenv("FPS_TEST_RETURN_ONE") && !strcmp(getenv("FPS_TEST_RETURN_ONE"), "1");
    deactivate = getenv("FPS_TEST_DEACTIVATE") && !strcmp(getenv("FPS_TEST_DEACTIVATE"), "1");
    focus_probe = getenv("FPS_TEST_FOCUS") && !strcmp(getenv("FPS_TEST_FOCUS"), "1");
    stall_probe = getenv("FPS_TEST_STALL") && !strcmp(getenv("FPS_TEST_STALL"), "1");
    split = getenv("FPS_TEST_SPLIT") && !strcmp(getenv("FPS_TEST_SPLIT"), "1");
    flap = getenv("FPS_TEST_FLAP") && !strcmp(getenv("FPS_TEST_FLAP"), "1");
    if (flap && (dynamic || !windowed || strcmp(frontend, "nvn"))) { fputs("来回切只支持真实窗口NVN\n", stderr); return 2; }
    if (split) { split_go = dispatch_semaphore_create(0); split_done = dispatch_semaphore_create(0); pthread_t th; pthread_create(&th, NULL, split_thread, NULL); pthread_detach(th); }
    if (stall_probe && (dynamic || deactivate || focus_probe || !windowed || strcmp(frontend, "nvn") || interval != 3)) {
        fputs("卡顿恢复仅支持独立真实NVN窗口interval3\n", stderr); return 2;
    }
    if (focus_probe && (dynamic || deactivate || !windowed || strcmp(frontend, "nvn") || interval != 3)) {
        fputs("失焦恢复仅支持独立真实NVN窗口interval3\n", stderr); return 2;
    }
    if (deactivate && (dynamic || !windowed || strcmp(frontend, "nvn") || interval != 3)) {
        fputs("受控失活仅支持独立真实NVN窗口interval3\n", stderr); return 2;
    }
    if (return_one && (!dynamic || atoi(getenv("S2A_FPS")) != 30)) { fputs("3→1场景须动态且cap30\n", stderr); return 2; }
    if (dynamic && (!windowed || strcmp(frontend, "nvn"))) { fputs("动态节拍只支持真实窗口NVN\n", stderr); return 2; }
    if (windowed && !strcmp(frontend, "gl") && !interval && !atoi(getenv("S2A_FPS"))) samples = 240;
    if (!windowed) { run(); return 1; }
    dispatch_async(dispatch_get_main_queue(), ^{
        CHECK(s2a_mac_front_layer() && front_metal_layer() == s2a_mac_front_layer(), "生产 Mac 前端出图层");
        [CATransaction flush];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSWindow *window = nil;
            for (NSWindow *candidate in NSApp.windows)
                if ((__bridge void *)candidate.contentView.layer == s2a_mac_front_layer()) { window = candidate; break; }
            CHECK(window && (window.occlusionState & NSWindowOcclusionStateVisible), "生产 Mac 窗口可见");
            if (failed) exit(1);
            NSScreen *screen = window.screen;
            CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
            printf("实际窗口屏幕 %s，最大 %ld Hz，当前显示模式 %.3f Hz（0表示系统未给固定刷新率）\n",
                screen.localizedName.UTF8String, (long)screen.maximumFramesPerSecond, mode ? CGDisplayModeGetRefreshRate(mode) : 0);
            if (mode) CGDisplayModeRelease(mode);
            if (atoi(getenv("DM_PRESENT_LINK")) == 2 && screen.maximumFramesPerSecond < 120) { puts("UNTESTED 120 Hz 窗口场景：实际屏幕最大刷新率低于120"); exit(2); }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ run(); });
        });
    });
    s2a_front_run(NULL); return 1;
}
