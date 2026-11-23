// 系统库[nvntest]：-framework VideoToolbox（直连层单测链 libnvn.a 时带上，tools/weak_link_decl.py flags nvntest 输出）
// 系统库[nvntest]：-framework CoreMedia
// 系统库[nvntest]：-framework CoreVideo
// Switch 2 直连档：nn::codec 视频解码器、解码图像池、nn::syncpt::sdk 同步点事件、nn::gs::TryWaitNativeSync，以及 NVN2 的原生图像（nvnNativeImage* /
//   nvnTextureInitializeFromNativeImage）——宿主自己解码、自己给图像与同步点，不进 gsv 服务。
// 为什么：Switch 2 SDK 的 nn::codec 视频解码器经 nn::gsv::GetUserSession() 走 gsv 服务（NVIDIA 硬件解码器）。真机由 NVN2 驱动初始化时拉起 gsv，直连档把 NVN 换成
//   宿主实现、驱动不跑，没人建这个会话：GetUserSession 回空，nn::codec::video::Initialize → ShimLibraryGlobal::Initialize → InitializeServerContext 锁空指针崩
//   （火纹 Fortune's Weave 按 A 后的片头：subsdk2 的 movie::VideoDecoder → sdk+0x168f6c）。接管点必须是跨模块导入那一层：sdk 内部互调不经导入表，
//   subsdk2（游戏随包的 movie 播放库）导入的 nn::codec / nn::syncpt / nn::gs 名字、main 导入的 NVN2 原生图像名字由装载器解析到这里（runtime/src/gfxmode.c
//   s2a_direct_lookup → s2a_codec_entry）。nn::movie::MediaExtractor（WebM 拆包）与 movie::VideoDecoder 的播放逻辑不碰服务，照样跑游戏自己的。
// 协议事实取自 kartnative（MIT）docs/reference/movies.md「Switch 2 video decoders」与 dm/host/hle_codec_video.c、hle_syncpt.c（47f2d1d，SDK 19.3.3），
//   在火纹的 SDK 22.2.0 上逐个核过（sdk 偏移是火纹的）：
//   - 偏好（MakeDecodeImagePreference，sdk+0x330fd0，纯函数、留给 SDK）：字 1 = 布局码（图块模式 1：输出格式 2/3/4/5 → 2/1/10/11；模式 2 → 5/4/12/13），
//     字 2 = (宽 − 1) | (高 − 1) << 16。布局码 1 / 4 NV12，2 / 5 四字节 RGBA，10–13 HDR（按 8 位 RGBA 写，红行）。
//   - 图像池（VideoDecoderImagePoolType）：subsdk2 把它放在自己对象的 +0（+0x20 起是它自己的宽高格式），所以宿主只用前 0x18 字节：+4 第一个原生图像句柄
//     （GetDecoderImagePoolNativeImageHandle = 它 + 序号，sdk+0x3314e0）、+8 张数、+0x10 内存。火纹每个池 1 张（subsdk2+0xf7a8）。
//   - 解码器对象：「可提交」SystemEvent 在 +8（GetXxxDecoderSubmissionReadyEvent，sdk+0x336250 回 对象 + 8）；登记 / 释放的缓冲按次序进 8 格环，
//     Acquire 不进服务、直接出环（sdk+0x336400；空环 subsdk2 直接中止）；第 k 个发出去的同步句柄由第 k 帧达到，所以帧按登记 / 释放次序填图。
//   - 同步句柄 NativeSyncHandle = {u32 ~计数器号, u32 模式, u64 值}，模式 1 比 64 位、否则 32 位回绕比；全 0 视为已达到。
// 解码：VP9 / VP8 用仓库现成的 libvpx（services/vpx/build.sh，垫片 s2a_vp9.c / s2a_vp8.c，与服务层 Nvdec 同源）；AV1 用 VideoToolbox 硬件解码
//   VP9 默认 libvpx；S2A_VP9_SYSTEM=1（仅 macOS）时整帧改走 VideoToolbox（关键帧解析 → vpcC，420v/420f → I420，失败自动回退 libvpx）；
//   S2A_VPX 缺省 1（链真 libvpx）；显式设 auto 且探测到本机可走系统 VP9（tools/vp9hw.sh）时不链真 libvpx（链空垫片），那时默认走系统
//   （火纹 82 支片头全是 AV1：2560x1440 78 支、1920x1080 4 支），VideoToolbox 不支持 AV1 的机器（M1 / M2、A16 及更早）用 dav1d 软件解码
//   （services/dav1d/build.sh，垫片 s2a_av1.c）；S2A_AV1_SOFT=1 强制软解（验收用，缺省关）。S2A_DAV1D 缺省 1（链 dav1d）；只有显式设 auto 时
//   才探测本机（tools/av1hw.sh：VideoToolbox 建得出 AV1 会话），有 AV1 硬解就不链 dav1d（无硬解时 AV1 初始化报错，不会出假画面），只给本机自用的构建。H.264 走 VideoToolbox 硬件解码（每台苹果设备都有）：输入按 Annex B（起始码）
//   或 4 字节长度前缀分 NAL，SPS / PPS 取自码流（变了就重建会话），样本按 AVCC 送；按解码次序出帧（带 B 帧的流显示次序会错，见到时间戳倒退报一次黄）。
// 原生图像：main 拿帧的原生图像句柄（movie::VideoFrame::GetNativeImageHandle）经 nvnNativeImage* 建 NVN 纹理（火纹 main+0x1900d80：格式 0x38 RGBA8_SRGB）。
//   宿主把这张图像的内存当成一个 CPU 可写的 NVN 内存池、纹理建成线性（LINEAR，行距 = 图像行距）：Metal 端是池缓冲上的零拷贝线性纹理（nvn_mtl.m tex_linear），
//   解码线程写进图像内存，GPU 执行时读到的就是当前帧。
#include "nvn2.h"
#include "nvn_obj.h"
#include "nvn_mtl.h"
#include "../../host/hle.h"
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <arm_neon.h>
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <TargetConditionals.h>

// services/vpx 的垫片（libs2a_vpx.a：宿主与 iOS App 链直连层时一起链）。NVN 单测链 libnvn.a 不链服务层编解码库：弱引用，按登记放行
// 弱链接[nvntest]：s2a_vp9_open（services/vpx 提供；宿主 / iOS 照常链上，NVN 单测不链，runtime/build.mk 按这行放行未定义）
// 弱链接[nvntest]：s2a_vp9_decode（同上）
// 弱链接[nvntest]：s2a_vp9_close（同上）
// 弱链接[nvntest]：s2a_vp8_open（同上）
// 弱链接[nvntest]：s2a_vp8_decode（同上）
// 弱链接[nvntest]：s2a_vp8_close（同上）
// 弱链接[nvntest,host,ios]：s2a_av1_open（services/dav1d 提供；NVN 单测不链服务层编解码库；宿主 / iOS 的 S2A_DAV1D 显式设 auto 且探测到本机有 AV1 硬解时不链 dav1d（tools/av1hw.sh），那时 host / ios 链接也要放行未定义）
// 弱链接[nvntest,host,ios]：s2a_av1_decode（同上）
// 弱链接[nvntest,host,ios]：s2a_av1_close（同上）
void *s2a_vp9_open(int threads) __attribute__((weak));
int s2a_vp9_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info) __attribute__((weak));
void s2a_vp9_close(void *h) __attribute__((weak));
void *s2a_vp8_open(void) __attribute__((weak));
int s2a_vp8_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *wh) __attribute__((weak));
void s2a_vp8_close(void *h) __attribute__((weak));
// 弱链接[nvntest]：s2a_vpx_linked（真 libvpx 回 1 / 空垫片 services/vpx/stub.c 回 0；宿主与 iOS 链二者之一，
//   = 0 时 VP9 默认走系统（见 vp9_system_enabled）；NVN 单测两样都不链：弱引用 NULL，调用前判）
int s2a_vpx_linked(void) __attribute__((weak));
// 弱链接[nvntest]：s2a_host_mem_avail（宿主还能给多少内存，平台层实现 runtime/src/hostmem_apple.c；iPhone 是离系统给本 App 的上限还剩多少。
//   先解队列按它定格数；NVN 单测不链原生核：弱引用 NULL，调用前判）
uint64_t s2a_host_mem_avail(void) __attribute__((weak));
// services/dav1d 的垫片（libs2a_dav1d.a：同上一起链）
void *s2a_av1_open(int threads) __attribute__((weak));
int s2a_av1_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info) __attribute__((weak));
// 视频按片源帧率出图（nvn_vpace.h，hle_nvn.c s2a_video_frame / s2a_video_frame_pts）：Switch 1 由 Ryujinx Nvdec 每解一帧报一次（services/aot/Compose.cs），Switch 2 由这里 cv_emit
//   每交出一帧新解码的画面报一次，同一口径；片源不超过 30 帧且这段主要在放视频时出图封顶 30。弱链接：单测不链 hle_nvn.c
void s2a_video_frame_pts(int64_t pts_ns) __attribute__((weak));   // 同上，带这一帧的片源时间戳（片源帧率按时间戳判，不被出图节拍反拖）
void s2a_av1_close(void *h) __attribute__((weak));

// SDK 的「环空 / 还没有帧」结果
#define CV_NOT_READY 0x1c286fu
// 每个解码器的输出缓冲（SDK 的环与句柄表都是 8 格）
#define CV_BUFS 8
// 排队输入包少于它时「可提交」事件保持触发
#define CV_MAXQ 8
// 宿主发的原生图像句柄
#define CV_IMAGES 1024
#define SP_COUNTERS 64
#define SP_SLOTS 64
#define CV_TRACE_N 48
#define CV_TR(d, fmt, ...) do { int k_ = atomic_fetch_add(&(d)->ntr, 1); if (k_ < CV_TRACE_N) LOG("Switch 2 视频调用 #%d（%s 解码器 %p）：" fmt, k_ + 1, cv_name[(d)->codec], (d)->guest, __VA_ARGS__); } while (0)
#define CV_RED(n, ...) do { static _Atomic int red_##n; if (!atomic_exchange(&red_##n, 1)) LOG("【红】" __VA_ARGS__); } while (0)

static void *gsym(const char *n) { void *p = guest_sym(n); if (!p) die("Switch 2 视频解码接管：游戏 SDK 缺符号 %s", n); return p; }
static size_t al(size_t v, size_t a) { return (v + a - 1) / a * a; }

// ---------- 宿主触发的 SystemEvent：原生层事件 + SDK 自己的 AttachReadableHandleToSystemEvent 填游戏的 SystemEventType ----------
// 游戏线程上调（Attach 是 SDK 代码）。返回原生事件号：任何线程 s2a_event_signal / s2a_event_clear；游戏照常用 SDK 的 Wait / TryWait / 多重等待（读端句柄走 svc）
static uint64_t sev_attach(void *sev, int autoclear) {
    uint32_t hr = 0; uint64_t ev = s2a_event_create(&hr, NULL);
    if (!ev) die("Switch 2 宿主事件：建事件失败（句柄表满）");
    static void (*attach)(void *, uint32_t, int, int);
    if (!attach) attach = (void (*)(void *, uint32_t, int, int))gsym("_ZN2nn2os33AttachReadableHandleToSystemEventEPNS0_15SystemEventTypeEjbNS0_14EventClearModeE");
    // 托管：SDK 销毁事件时关掉这个句柄；清除方式 0 = 手动、1 = 自动
    attach(sev, hr, 1, autoclear ? 1 : 0);
    return ev;
}

// ---------- nn::vi::GetDisplayVsyncEvent（nvn2.c 的 vi 接管表弱引用）----------
// 金刚 / raiders（11-04，main 导入）：Switch 2 sdk 原路径要 nn::gs 已启动，中止。宿主事件挂到游戏 SystemEvent（托管、自动清除），宿主线程按 60 Hz 触发。
//   事实取自 参考实现（MIT）dm/host/hle_sdk16.c h_vi_VsyncEvent（777a5f6c），代码自写
static uint64_t mono_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
// 线程随会话走（审计 P1-80）：起线程时记下会话代号，进程内重启（会话代号变了）就退出并放掉自己那份事件引用。原先永不退出，每局多留一条 60 Hz 醒的线程、一直给上一局的事件发信号
// 弱链接[nvntest]：s2a_session_generation（会话代号，runtime/src/session.c；NVN 单测不链原生层，链接行按这行放行未定义，runtime/build.mk 自动收）
unsigned s2a_session_generation(void) __attribute__((weak));
typedef struct { uint64_t ev; unsigned gen; } vi_vs_arg;
static _Atomic int g_vi_vs_live;   // 活着的 vsync 线程数（单测读）
int nvn2_vi_vsync_live(void) { return atomic_load(&g_vi_vs_live); }
static void *vi_vsync_thread(void *p) {
    vi_vs_arg a = *(vi_vs_arg *)p; free(p);
    const uint64_t period = 1000000000ull / 60;
    for (uint64_t next = mono_ns() + period;; next += period) {
        uint64_t t = mono_ns(); if (next > t) { struct timespec ts = {(time_t)((next - t) / 1000000000ull), (long)((next - t) % 1000000000ull)}; nanosleep(&ts, NULL); }
        if (s2a_session_generation && s2a_session_generation() != a.gen) break;   // 这一局结束了
        s2a_event_signal(a.ev);
        if (mono_ns() > next + 4 * period) next = mono_ns();   // 落后太多不追（机器卡住后不连发）
    }
    s2a_event_release(a.ev); atomic_fetch_sub(&g_vi_vs_live, 1);
    return NULL;
}
uint32_t nvn2_vi_vsync_event(void *sev, void *disp) {
    (void)disp; uint64_t ev = sev_attach(sev, 1); pthread_t th;
    vi_vs_arg *a = malloc(sizeof *a); if (!a) die("vi::GetDisplayVsyncEvent：内存不足");
    a->ev = ev; a->gen = s2a_session_generation ? s2a_session_generation() : 0; atomic_fetch_add(&g_vi_vs_live, 1);
    if (pthread_create(&th, NULL, vi_vsync_thread, a)) die("vi::GetDisplayVsyncEvent：起不了宿主 vsync 线程");
    pthread_detach(th);
    LOG("vi::GetDisplayVsyncEvent：宿主线程按 60 Hz 触发（自动清除）"); return 0;
}
uint64_t nvn2_chat_video_size(int w, int h, int count); uint32_t nvn2_chat_video_init(void *type, int w, int h, int count, void *buf, uint64_t size);
void nvn2_chat_video_fini(void *type); uint32_t nvn2_chat_video_handle(const void *type, int i);   // 定义见下（GameChat 摄像头视频存储，#116）
void nvn2_chat_video_register(void *size, void *init, void *fini, void *handle);   // nvn2.c（声明不放 nvn2.h：别让头文件改动牵动别处）
__attribute__((constructor)) static void vi_vsync_reg(void) { nvn2_vi_vsync_register((void *)nvn2_vi_vsync_event); nvn2_sev_attach_register(sev_attach);
    nvn2_chat_video_register((void *)nvn2_chat_video_size, (void *)nvn2_chat_video_init, (void *)nvn2_chat_video_fini, (void *)nvn2_chat_video_handle); }

// ---------- 同步计数器与 nn::syncpt::sdk 事件 ----------
typedef struct { uint32_t id_inv, mode; uint64_t value; } cv_sync;
static pthread_mutex_t g_sp_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_sp_cv = PTHREAD_COND_INITIALIZER;
static struct { uint64_t value; int used; } g_ctr[SP_COUNTERS];
// ev：游戏等的 SystemEventType（0x30 字节）
static struct { _Alignas(16) uint8_t ev[0x40]; int used, armed; uint64_t hev; cv_sync want; } g_slot[SP_SLOTS];
static unsigned g_slot_gen;   // 槽表属于哪一局（会话代号）
// 持 g_sp_mu。槽的 SystemEvent 挂的读端句柄在那一局的句柄表里：进程内重启后句柄表整张关掉、重新编号，旧句柄在新一局里不存在
//   （11-14 D-VHSE：重启后第一次建同步点事件就复用了上一局缓存的事件，游戏等它 → svc 回 InvalidHandle 0xe401，SDK 中止）。
//   换局后头一次碰槽表：放掉宿主替旧事件持的那份引用（句柄那份已随句柄表关掉），整张清空，用到时在新一局里重新建、重新挂
static void sp_slots_for_session_locked(void) {
    unsigned g = s2a_session_generation ? s2a_session_generation() : 0;
    if (g == g_slot_gen) return;
    int n = 0;
    for (int i = 0; i < SP_SLOTS; i++) { if (g_slot[i].hev) { s2a_event_release(g_slot[i].hev); n++; } memset(&g_slot[i], 0, sizeof g_slot[i]); }
    if (n) LOG("Switch 2 视频：换局（会话 %u → %u），上一局的 %d 个同步点事件作废，用到时重新建", g_slot_gen, g, n);
    g_slot_gen = g;
}

static int sp_reached_locked(const cv_sync *h) {
    if (!h->id_inv && !h->mode && !h->value) return 1;
    uint32_t id = ~h->id_inv;
    if (id >= SP_COUNTERS || !g_ctr[id].used) {
        // 不是宿主发的句柄（火纹：main 释放帧时带回的读栅栏，subsdk2 先 nn::gs::TryWaitNativeSync 它）：宿主的 GPU 读完才会再写这张图（8 张轮换），按已达到算
        static _Atomic int said; if (!atomic_exchange(&said, 1)) LOG("Switch 2 视频：同步句柄 {%#x, %u, %llu} 不是宿主计数器发的，按已达到算（只报一次）", h->id_inv, h->mode, (unsigned long long)h->value);
        return 1;
    }
    uint64_t v = g_ctr[id].value;
    return h->mode == 1 ? v >= h->value : (int32_t)((uint32_t)v - (uint32_t)h->value) >= 0;
}
static uint32_t sp_alloc(void) {
    pthread_mutex_lock(&g_sp_mu);
    // 值不清零：旧句柄不会倒退
    for (uint32_t i = 0; i < SP_COUNTERS; i++) if (!g_ctr[i].used) { g_ctr[i].used = 1; pthread_mutex_unlock(&g_sp_mu); return i; }
    pthread_mutex_unlock(&g_sp_mu);
    die("Switch 2 视频：%d 个同步计数器都在用", SP_COUNTERS);
}
static void sp_free(uint32_t id) { pthread_mutex_lock(&g_sp_mu); if (id < SP_COUNTERS) g_ctr[id].used = 0; pthread_mutex_unlock(&g_sp_mu); }
static uint64_t sp_value(uint32_t id) { pthread_mutex_lock(&g_sp_mu); uint64_t v = id < SP_COUNTERS ? g_ctr[id].value : 0; pthread_mutex_unlock(&g_sp_mu); return v; }
static int sp_reached(const cv_sync *h) { pthread_mutex_lock(&g_sp_mu); int r = sp_reached_locked(h); pthread_mutex_unlock(&g_sp_mu); return r; }
// 槽事件的触发 / 清除一律在 g_sp_mu 里做（锁序 g_sp_mu → 原生层全局锁；原生层持它时从不回调这里）。
//   原先在锁外触发：解码线程刚把计数器加到 h1、还没触发时，另一条线程（movie 库 Flush，subsdk0+0x36e0）已能看到 h1 达到、弹出环头、
//   Cancel + Request 下一帧 h2（清事件、武装 h2）；迟到的 h1 触发落在 h2 的请求上，事件管理器醒来取环头 h2 未达到 → AbortImpl（11-06 时之笛读档自中止）
// 任何线程：+1，触发已武装且达到的事件
static void sp_incr(uint32_t id) {
    pthread_mutex_lock(&g_sp_mu);
    if (id < SP_COUNTERS) g_ctr[id].value++;
    for (int i = 0; i < SP_SLOTS; i++) if (g_slot[i].armed && sp_reached_locked(&g_slot[i].want)) { g_slot[i].armed = 0; s2a_event_signal(g_slot[i].hev); }
    pthread_cond_broadcast(&g_sp_cv);
    pthread_mutex_unlock(&g_sp_mu);
}
// 宿主线程：1 达到、0 超时
static int sp_wait(const cv_sync *h, uint64_t timeout_ns) {
    uint64_t end = now_ns() + timeout_ns; int r;
    pthread_mutex_lock(&g_sp_mu);
    while (!(r = sp_reached_locked(h))) {
        uint64_t t = now_ns(); if (t >= end) break;
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        uint64_t ns = (uint64_t)ts.tv_nsec + (end - t); ts.tv_sec += (time_t)(ns / 1000000000ull); ts.tv_nsec = (long)(ns % 1000000000ull);
        pthread_cond_timedwait(&g_sp_cv, &g_sp_mu, &ts);
    }
    pthread_mutex_unlock(&g_sp_mu);
    return r;
}
// SyncPointEventType 里只放 u32 槽号（同 SDK）
static uint32_t sp_slot(const void *t) { uint32_t s = *(const uint32_t *)t; if (s >= SP_SLOTS || !g_slot[s].used) die("Switch 2 视频：同步点事件 %p 的槽 %u 不在用", t, s); return s; }
static Result sp_create(uint32_t *t) {
    pthread_mutex_lock(&g_sp_mu);
    sp_slots_for_session_locked();
    int s = -1; for (int i = 0; i < SP_SLOTS; i++) if (!g_slot[i].used) { s = i; break; }
    if (s >= 0) { g_slot[s].used = 1; g_slot[s].armed = 0; }
    uint64_t ev = s >= 0 ? g_slot[s].hev : 0;
    pthread_mutex_unlock(&g_sp_mu);
    // SDK 无空槽时的结果
    if (s < 0) { LOG("【红】Switch 2 视频：%d 个同步点事件槽都在用", SP_SLOTS); *t = 0; return 0x80f3; }
    // 槽的 SystemEvent 第一次用时在这个游戏线程上建、之后一直留着（SDK 的槽事件也留着）；手动清除，同 SDK
    if (!ev) { ev = sev_attach(g_slot[s].ev, 0); pthread_mutex_lock(&g_sp_mu); g_slot[s].hev = ev; pthread_mutex_unlock(&g_sp_mu); }
    s2a_event_clear(ev);
    *t = (uint32_t)s;
    return RES_OK;
}
static void sp_destroy(uint32_t *t) {
    uint32_t s = sp_slot(t);
    pthread_mutex_lock(&g_sp_mu); g_slot[s].armed = 0; g_slot[s].used = 0; s2a_event_clear(g_slot[s].hev); pthread_mutex_unlock(&g_sp_mu);
}
// 清掉，宿主计数器到了句柄的值再触发
static void sp_request(uint32_t *t, const cv_sync *h) {
    uint32_t s = sp_slot(t);
    // SDK 对全 0 句柄什么也不发
    if (!h->id_inv && !h->mode && !h->value) return;
    pthread_mutex_lock(&g_sp_mu);
    s2a_event_clear(g_slot[s].hev);
    int now = sp_reached_locked(h);
    g_slot[s].want = *h; g_slot[s].armed = !now;
    if (now) s2a_event_signal(g_slot[s].hev);
    pthread_mutex_unlock(&g_sp_mu);
}
// 解除武装并触发（同服务）
static void sp_cancel(uint32_t *t) {
    uint32_t s = sp_slot(t);
    pthread_mutex_lock(&g_sp_mu); g_slot[s].armed = 0; s2a_event_signal(g_slot[s].hev); pthread_mutex_unlock(&g_sp_mu);
}
static void sp_holder(void *holder, uint32_t *t) {
    static void (*init)(void *, void *);
    if (!init) init = (void (*)(void *, void *))gsym("_ZN2nn2os25InitializeMultiWaitHolderEPNS0_19MultiWaitHolderTypeEPNS0_15SystemEventTypeE");
    init(holder, g_slot[sp_slot(t)].ev);
}
static int sp_trywait(const void *t) {
    static int (*tw)(void *);
    if (!tw) tw = (int (*)(void *))gsym("_ZN2nn2os18TryWaitSystemEventEPNS0_15SystemEventTypeE");
    return tw(g_slot[sp_slot(t)].ev) & 1;
}
static int gs_trywait(const cv_sync *h) { return sp_reached(h); }
// 句柄族（11-04 接口面全量）：NativeSyncHandle / SyncPointHandle（同一 16 字节布局，sdk 互转是原样拷贝，火纹 sdk+0x5d45a0）都是宿主计数器发的，
//   sdk 的等待经 syncpt 库表（syncpt::sdk::Initialize 要 gsv 会话，直连档没建：模拟执行跳空）——等待全部由宿主答。TimeSpan 是 i64 纳秒
static void gs_wait(const cv_sync *h) { while (!sp_wait(h, 1000000000ull)) {} }
static int gs_timedwait(const cv_sync *h, int64_t ns) { return sp_wait(h, ns > 0 ? (uint64_t)ns : 0); }
// nn::syncpt::sdk::Initialize / InitializeEx：宿主同步计数器常备，没有要建的
static Result sp_lib_init(void) { return RES_OK; }
// nn::gs：直连档的「图形系统」就是宿主图形层。启动 / 关闭与 nv::InitializeGraphics 同一份状态（nvn2.c）；CheckGraphicsSystemInitialized 照 sdk 语义：没启动就中止
static void gs_init(void *mem, uint64_t size) { nvn2_gs_boot(mem, (size_t)size, "nn::gs::Initialize"); }
static Result gs_boot(void *mem, uint64_t size) { nvn2_gs_boot(mem, (size_t)size, "nn::gs::sdk::BootGraphicsSystem"); return RES_OK; }
static void gs_fini(void) { nvn2_gs_shutdown(); }
static void gs_check(const char *who, uint64_t n) { if (!nvn2_gs_booted()) die("nn::gs::sdk::CheckGraphicsSystemInitialized(%.*s)：图形系统没启动（游戏没调 nv::InitializeGraphics / gs 启动）", (int)(n < 64 ? n : 64), who ? who : ""); }
static void gs_alloc_init(void *a, void *f, void *r, void *u) { nvn2_gs_set_allocator(a, f, r, u); }
static void gs_alloc_get(void **a, void **f, void **r) { void *o[4]; nvn2_gs_allocator(o); if (a) *a = o[0]; if (f) *f = o[1]; if (r) *r = o[2]; }
static void gs_alloc_shutdown(void) { nvn2_gs_set_allocator(NULL, NULL, NULL, NULL); }
// 帧节奏模式（oe::SetGraphicsTargetFrameRate 经它告诉 gs 服务）：宿主按窗口的交换间隔定节奏，GPU 时间片 / 重启模式无处可设——记下
static void gs_frame_mode(int mode) { static _Atomic int last = -1; if (atomic_exchange(&last, mode) != mode) LOG("gs：帧长模式 %d（0 自动、1 30 帧、2 60 帧、3 120 帧）：宿主按 NVN 交换间隔定节奏，只记下", mode); }
static void gs_frame_knob(int mode) { (void)mode; }
// nn::oe::SetGraphicsTargetFrameRate（新版 sdk，#679）：sdk 里它在模块内直接调 gs::sdk::SetGraphicsFrameLengthMode，不经导入表，上面那个接管碰不到；
//   原版去用 gsv 会话，直连档 gs 不启动、会话不存在，首帧后中止。主程序经导入调它，在这一层接住：同帧长模式，宿主按 NVN 交换间隔定节奏，只记、回成功。
//   参数是目标帧率的枚举 / 数值（各 sdk 的改编名后缀不一定相同，按名字前缀认），只用来打日志
#define OE_TARGET_RATE "_ZN2nn2oe26SetGraphicsTargetFrameRateE"
static Result oe_target_rate(int rate) { static _Atomic int last = -1; if (atomic_exchange(&last, rate) != rate) LOG("oe：目标帧率设置 %d：宿主按 NVN 交换间隔定节奏，只记（直连档不启动 gs，不转给 gs 服务）", rate); return RES_OK; }
// nn::oe::SetGraphicsTargetFrameRateAuto()（D-SM6Y，040077201BE50000）：同上，sdk 内直接调 gs::sdk::SetGraphicsFrameLengthMode（自动档）；原版锁 gs 没初始化的互斥量 → 空指针
#define OE_TARGET_RATE_AUTO "_ZN2nn2oe30SetGraphicsTargetFrameRateAutoEv"
static Result oe_target_rate_auto(void) { static _Atomic int said; if (!atomic_exchange(&said, 1)) LOG("oe：目标帧率设为自动：宿主按 NVN 交换间隔定节奏，只记（直连档不启动 gs，不转给 gs 服务）"); return RES_OK; }

// ---------- 图像池与原生图像句柄 ----------
enum { IMG_NONE, IMG_NV12, IMG_RGBA, IMG_HDR };
typedef struct {
    int kind; uint32_t w, h, pitch; size_t chroma_off, size;
    // mem：游戏地址；host：宿主写的地址（远端别名区换成影子，其余同 mem）
    uint8_t *mem, *host;
    // 所在宿主池记录（g_cvp）
    int pool;
} cv_img;
static pthread_mutex_t g_img_mu = PTHREAD_MUTEX_INITIALIZER;
static cv_img g_img[CV_IMAGES]; static uint8_t g_img_used[CV_IMAGES]; static uint32_t g_img_next;
// 宿主池记录：一个解码图像池的整块内存；NVN 第一次从它的图像建纹理时登记成后端内存池（nvn_be_pool_add），pool_t 给纹理引用（记录不释放，纹理可能还留着）
#define CV_POOLS 256
static struct { int used; uint8_t *mem; size_t size; pool_t nv; int nv_on; } g_cvp[CV_POOLS];

// 游戏的 VideoDecoderImagePoolType 前 0x18 字节（subsdk2 自己的字段从 +0x20 起）
typedef struct { uint32_t mem_handle, first, count, magic; uint8_t *mem; } cv_pool;
_Static_assert(sizeof(cv_pool) <= 0x20, "cv_pool 超出 subsdk2 给图像池留的 0x20 字节");

static int cv_kind(uint32_t code) {
    if (code == 1 || code == 4 || code == 7) return IMG_NV12;
    if (code == 2 || code == 5 || code == 3 || code == 6 || code == 8 || code == 9) return IMG_RGBA;
    if (code >= 10 && code <= 13) { CV_RED(hdr, "Switch 2 视频：HDR 图像布局码 %u 按 8 位 RGBA 写（宿主不出 HDR），RgbaHdr 读回按 8 位 SDR", code); return IMG_HDR; }
    return IMG_NONE;
}
// 偏好 → 宿主的线性布局；0 = 不认识的布局码
static int cv_layout(const uint32_t *pref, cv_img *im) {
    memset(im, 0, sizeof *im);
    im->kind = cv_kind(pref[1]);
    im->w = (pref[2] & 0xffff) + 1; im->h = (pref[2] >> 16 & 0xffff) + 1;
    if (!im->kind) { LOG("【红】Switch 2 视频：解码图像布局码 %u 不认识（%ux%u）", pref[1], im->w, im->h); return 0; }
    int nv12 = im->kind == IMG_NV12;
    // 行距按 256 字节对齐：Metal 线性纹理的行距 / 起点对齐要求（minimumLinearTextureAlignment）不超过它；每张图按 16 KB 对齐（池缓冲按页建）
    im->pitch = (uint32_t)al((size_t)im->w * (nv12 ? 1 : 4), 256);
    im->chroma_off = (size_t)im->pitch * al(im->h, 16);
    im->size = al(im->chroma_off + (nv12 ? (size_t)im->pitch * al((im->h + 1) / 2, 16) : 0), 0x4000);
    return 1;
}
static uint8_t *cv_host_of(uint8_t *mem, size_t n) {
    uint8_t *h = s2a_far_g2h((uint64_t)(uintptr_t)mem);
    if (!h) return mem;
    for (uintptr_t x = ((uintptr_t)mem | 0x1FFFFF) + 1; x < (uintptr_t)mem + n; x += 0x200000)
        if (s2a_far_g2h(x) != h + (x - (uintptr_t)mem)) { LOG("【红】Switch 2 视频：图像池 %p+%#zx 的远端影子不连续，宿主写游戏地址（会走缺页代执行）", (void *)mem, n); return mem; }
    return h;
}
static int cv_img_get(uint32_t handle, cv_img *out) {
    pthread_mutex_lock(&g_img_mu);
    int ok = handle && handle <= CV_IMAGES && g_img_used[handle - 1];
    if (ok) *out = g_img[handle - 1];
    pthread_mutex_unlock(&g_img_mu);
    return ok;
}
static Result cv_pool_size(uint64_t *size, uint64_t *align, const uint32_t *pref, uint32_t count) {
    cv_img im; if (!cv_layout(pref, &im)) return RES_FAIL;
    *align = 0x4000; *size = im.size * (count ? count : 1);
    return RES_OK;
}
static Result cv_pool_init(cv_pool *pool, uint8_t *mem, uint64_t memsize, const uint32_t *pref, uint32_t count) {
    memset(pool, 0, sizeof *pool);
    cv_img im; if (!cv_layout(pref, &im)) return RES_FAIL;
    if (!count || im.size * count > memsize) { LOG("【红】Switch 2 视频：%u 张 %ux%u 图像的池要 %#zx 字节，游戏给 %#llx", count, im.w, im.h, im.size * count, (unsigned long long)memsize); return RES_FAIL; }
    uint8_t *host = cv_host_of(mem, im.size * count);
    pthread_mutex_lock(&g_img_mu);
    int p = -1; for (int i = 0; i < CV_POOLS; i++) if (!g_cvp[i].used) { p = i; break; }
    // 句柄轮着发（不就近复用）：main 按句柄缓存它建的 NVN 纹理（main+0x1900c60），刚放掉的句柄马上给新池会让旧纹理指到新内存
    uint32_t first = 0;
    for (uint32_t k = 0; p >= 0 && k < CV_IMAGES && !first; k++) {
        uint32_t s = (g_img_next + k) % CV_IMAGES; if (s + count > CV_IMAGES) continue;
        uint32_t j = 0; while (j < count && !g_img_used[s + j]) j++;
        if (j == count) first = s + 1;
    }
    if (first) {
        g_cvp[p] = (typeof(g_cvp[p])){ .used = 1, .mem = mem, .size = im.size * count };
        for (uint32_t k = 0; k < count; k++) { cv_img *e = &g_img[first - 1 + k]; *e = im; e->mem = mem + im.size * k; e->host = host + im.size * k; e->pool = p; g_img_used[first - 1 + k] = 1; }
        g_img_next = (first - 1 + count) % CV_IMAGES;
    }
    pthread_mutex_unlock(&g_img_mu);
    if (!first) { LOG("【红】Switch 2 视频：放不下再 %u 张解码图像（池记录 %s）", count, p < 0 ? "满" : "有空"); return RES_FAIL; }
    pool->first = first; pool->count = count; pool->mem = mem; pool->magic = 0x4c4f4f50;
    return RES_OK;
}
static void cv_pool_fini(cv_pool *pool) {
    pthread_mutex_lock(&g_img_mu);
    int p = -1;
    for (uint32_t k = 0; k < pool->count; k++) if (pool->first + k - 1 < CV_IMAGES) { p = g_img[pool->first + k - 1].pool; g_img_used[pool->first + k - 1] = 0; }
    int unreg = p >= 0 && g_cvp[p].nv_on; uint8_t *mem = p >= 0 ? g_cvp[p].mem : NULL;
    pool_t *nv = unreg ? &g_cvp[p].nv : NULL;
    if (p >= 0) { g_cvp[p].used = 0; g_cvp[p].nv_on = 0; }
    pthread_mutex_unlock(&g_img_mu);
    if (unreg) {
        nvn_be_pool_del(mem);
        // 该池登记过后端：按它的 pool_t 地址清共享纹理缓存（g_alias）与纹理 ID 视图（g_treg）。
        // 漏这步：g_cvp 槽被新池复用（pool_t 地址不变），新纹理 off / desc 相同时 g_alias 命中旧条目，绑到旧池已释放的 MTLTexture → 花屏
        nvn_be_alias_drop_pool(nv);
    }
    memset(pool, 0, sizeof *pool);
}
static uint32_t cv_pool_handle(const cv_pool *pool, uint32_t i) { return pool->first + i; }
// GameChat 摄像头视频存储（nn::chat::Calculate / Initialize / Finalize{Local,Remote}CameraVideo*、Get*CameraImageHandle，nvn2.c chat_entry 调）：#116 马车世界开机就建
//   本地 / 远端摄像头的图像池，之后按序号取原生图像句柄建 NVN 纹理；没人聊天时这些图像只是从不被写。原先「没在聊」一律回 0，游戏拿句柄 0 调 nvnNativeImageInitialize 后中止（2162-0001）。
//   语义取自 Splatoon Raiders（0400380020056000）sdk 反汇编：Calculate(宽 32–1920, 高 32–1080, 张数 1–4) 按（宽, 高, 0）的图像偏好算图像池大小；Initialize(类型, 宽, 高, 张数, 缓冲, 大小)
//   要缓冲与大小 4 KB 对齐、把 224 字节的类型清零后在缓冲里建池；Get(类型, 序号) 取第 i 张的句柄。宿主这里用解码图像同一套池（RGBA 线性，cv_pool 放进类型的前 0x20 字节）
static int cv_chat_pref(uint32_t pref[3], int w, int h, int count) {
    if (w < 32 || w > 1920 || h < 32 || h > 1080 || count < 1 || count > 4) { LOG("【红】GameChat 摄像头视频：尺寸 %dx%d、%d 张超出 sdk 的范围（宽 32–1920、高 32–1080、1–4 张）", w, h, count); return 0; }
    pref[0] = 0; pref[1] = 2; pref[2] = (uint32_t)(w - 1) | (uint32_t)(h - 1) << 16;   // 布局码 2 = RGBA（cv_kind）
    return 1;
}
uint64_t nvn2_chat_video_size(int w, int h, int count) {
    uint32_t pref[3]; uint64_t size = 0, align = 0;
    if (!cv_chat_pref(pref, w, h, count) || cv_pool_size(&size, &align, pref, (uint32_t)count) != RES_OK) return 0;
    return (size + 0xfff) & ~(uint64_t)0xfff;
}
uint32_t nvn2_chat_video_init(void *type, int w, int h, int count, void *buf, uint64_t size) {
    uint32_t pref[3];
    if (!type) return RES_FAIL;
    memset(type, 0, 224);
    if (!cv_chat_pref(pref, w, h, count) || !buf || ((uintptr_t)buf & 0xfff) || (size & 0xfff)) { LOG("【红】GameChat 摄像头视频：缓冲 %p+%#llx 没按 4 KB 对齐或尺寸不对", buf, (unsigned long long)size); return RES_FAIL; }
    Result r = cv_pool_init((cv_pool *)type, (uint8_t *)buf, size, pref, (uint32_t)count);
    if (r == RES_OK) { static _Atomic int said; if (atomic_fetch_add(&said, 1) < 4) LOG("GameChat 摄像头视频：建 %d 张 %dx%d 原生图像（句柄 %u 起；没人聊天，从不写入）", count, w, h, ((cv_pool *)type)->first); }
    return r;
}
void nvn2_chat_video_fini(void *type) { if (type && ((cv_pool *)type)->magic == 0x4c4f4f50) cv_pool_fini((cv_pool *)type); }
uint32_t nvn2_chat_video_handle(const void *type, int i) {
    const cv_pool *p = type;
    if (!p || p->magic != 0x4c4f4f50 || i < 0 || (uint32_t)i >= p->count) { LOG("【红】GameChat 摄像头视频：取第 %d 张的句柄，存储没建或序号越界", i); return 0; }
    return cv_pool_handle(p, (uint32_t)i);
}
static Result cv_read_rgba(const cv_pool *pool, uint32_t i, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t *dst, uint64_t pitch, uint64_t size) {
    x &= 0xffff; y &= 0xffff; w &= 0xffff; h &= 0xffff;
    cv_img im;
    if (i >= pool->count || !cv_img_get(pool->first + i, &im) || im.kind == IMG_NV12) { LOG("【红】Switch 2 视频：ReadDecoderOutputImageRgba 读池 %u 的第 %u 张，不是 RGBA", pool->first, i); return RES_FAIL; }
    if (x + w > im.w || y + h > im.h || (h && (size_t)(h - 1) * pitch + (size_t)w * 4 > size)) { LOG("【红】Switch 2 视频：ReadDecoderOutputImageRgba 矩形 %u,%u %ux%u 超出 %ux%u 图像或游戏缓冲", x, y, w, h, im.w, im.h); return RES_FAIL; }
    for (uint32_t r = 0; r < h; r++) memcpy(dst + r * pitch, im.host + (size_t)(y + r) * im.pitch + (size_t)x * 4, (size_t)w * 4);
    return RES_OK;
}
static Result cv_read_nv12(const cv_pool *pool, uint32_t i, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t *ydst, uint64_t ypitch, uint64_t ysize, uint8_t *uvdst, uint64_t uvpitch, uint64_t uvsize) {
    x &= 0xffff; y &= 0xffff; w &= 0xffff; h &= 0xffff;
    cv_img im;
    if (i >= pool->count || !cv_img_get(pool->first + i, &im) || im.kind != IMG_NV12) { LOG("【红】Switch 2 视频：ReadDecoderOutputImageNv12 读池 %u 的第 %u 张，不是 NV12", pool->first, i); return RES_FAIL; }
    size_t h2 = (h + 1) / 2, w2 = al(w, 2);
    if (x + w > im.w || y + h > im.h || (h && (size_t)(h - 1) * ypitch + w > ysize) || (h2 && (h2 - 1) * uvpitch + w2 > uvsize)) { LOG("【红】Switch 2 视频：ReadDecoderOutputImageNv12 矩形 %u,%u %ux%u 超出 %ux%u 图像或游戏缓冲", x, y, w, h, im.w, im.h); return RES_FAIL; }
    for (uint32_t r = 0; r < h; r++) memcpy(ydst + r * ypitch, im.host + (size_t)(y + r) * im.pitch + x, w);
    for (size_t r = 0; r < h2; r++) memcpy(uvdst + r * uvpitch, im.host + im.chroma_off + (size_t)(y / 2 + r) * im.pitch + (x & ~1u), w2);
    return RES_OK;
}
// SDK 20（金刚 / Pokopia）另有 BGRA 读法：同一矩形，四字节一像素按 B G R A 存
static Result cv_read_bgra(const cv_pool *pool, uint32_t i, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t *dst, uint64_t pitch, uint64_t size) {
    Result r = cv_read_rgba(pool, i, x, y, w, h, dst, pitch, size);
    if (r) return r;
    w &= 0xffff; h &= 0xffff;
    for (uint32_t row = 0; row < h; row++) for (uint32_t c = 0; c < w; c++) { uint8_t *px = dst + row * pitch + (size_t)c * 4, t = px[0]; px[0] = px[2]; px[2] = t; }
    return RES_OK;
}
// PR2：RgbaHdr 已转发 cv_read_rgba（HDR 布局码的池本就按 8 位 RGBA 写出）；这里只剩 float 读回——float 布局未核（不猜 fp16/fp32），保持失败
static Result cv_read_hdr(void) { CV_RED(rdhdr, "Switch 2 视频：ReadDecoderOutputImageRgbaHdrFloat 保持失败：HDR 的 float 读回布局未核（不猜 fp16/fp32）"); return RES_FAIL; }

// ---------- 像素写入 ----------
// YUV 三平面 → 图像（RGBA 行或 NV12）；矩阵按片子声明（未声明：720 行以上 BT.709，否则 BT.601），整数定点。
//   bpc > 8（10 / 12 位，样本按 16 位存）右移到 8 位；ssx / ssy：色度横 / 纵向减半（4:2:0 = 1 / 1，4:2:2 = 1 / 0，4:4:4 = 0 / 0）；mono：没有色度（按 128）
typedef struct { const uint8_t *p[3]; int stride[3]; int w, h, full, bt709, bpc, ssx, ssy, mono; } cv_pic;
static inline int smp(const cv_pic *s, int pl, uint32_t x, uint32_t y) {
    if (pl && s->mono) return 128;
    const uint8_t *r = s->p[pl] + (size_t)y * s->stride[pl];
    return s->bpc > 8 ? ((const uint16_t *)(const void *)r)[x] >> (s->bpc - 8) : r[x];
}
static void pic_to_img(const cv_pic *s, const cv_img *im) {
    uint32_t cw = (uint32_t)s->w < im->w ? (uint32_t)s->w : im->w, ch = (uint32_t)s->h < im->h ? (uint32_t)s->h : im->h;
    int fast = s->bpc == 8 && s->ssx == 1 && s->ssy == 1 && !s->mono;
    if (im->kind == IMG_NV12) {
        for (uint32_t r = 0; r < ch; r++) {
            uint8_t *o = im->host + (size_t)r * im->pitch;
            if (s->bpc == 8) memcpy(o, s->p[0] + (size_t)r * s->stride[0], cw); else for (uint32_t x = 0; x < cw; x++) o[x] = (uint8_t)smp(s, 0, x, r);
        }
        for (uint32_t r = 0; r < (ch + 1) / 2; r++) {
            uint8_t *o = im->host + im->chroma_off + (size_t)r * im->pitch;
            for (uint32_t x = 0; x < (cw + 1) / 2; x++) {
                uint32_t cx = (2 * x) >> s->ssx, cy = (2 * r) >> s->ssy;
                o[2 * x] = (uint8_t)smp(s, 1, cx, cy); o[2 * x + 1] = (uint8_t)smp(s, 2, cx, cy);
            }
        }
        return;
    }
    double ky = s->full ? 1.0 : 255.0 / 219.0, kc = s->full ? 1.0 : 255.0 / 224.0;
    double rv = s->bt709 ? 1.5748 : 1.402, gu = s->bt709 ? 0.1873 : 0.3441, gv = s->bt709 ? 0.4681 : 0.7141, bu = s->bt709 ? 1.8556 : 1.772;
    int Y = (int)(ky * 65536), RV = (int)(rv * kc * 65536), GU = (int)(gu * kc * 65536), GV = (int)(gv * kc * 65536), BU = (int)(bu * kc * 65536), y0 = s->full ? 0 : 16;
    for (uint32_t r = 0; r < ch; r++) {
        const uint8_t *py = s->p[0] + (size_t)r * s->stride[0], *pu = s->p[1] + (size_t)(r >> 1) * s->stride[1], *pv = s->p[2] + (size_t)(r >> 1) * s->stride[2];
        uint8_t *o = im->host + (size_t)r * im->pitch;
        uint32_t x = 0;
        // 8 位 4:2:0：一次 16 个像素（8 个色度），与下面的逐像素同一套定点算法、结果逐位相同；色度只读到本行色度宽度之内
        for (; fast && x + 16 <= cw; x += 16) {
            uint8x8_t u8 = vld1_u8(pu + x / 2), v8 = vld1_u8(pv + x / 2);
            uint8x16_t yy = vld1q_u8(py + x), uu = vcombine_u8(vzip1_u8(u8, u8), vzip2_u8(u8, u8)), vv = vcombine_u8(vzip1_u8(v8, v8), vzip2_u8(v8, v8));
            uint8x16x4_t px; px.val[3] = vdupq_n_u8(255);
            uint8x8_t ch[3][2];
            for (int hf = 0; hf < 2; hf++) {
                int16x8_t y16 = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(hf ? vget_high_u8(yy) : vget_low_u8(yy))), vdupq_n_s16((int16_t)y0));
                int16x8_t u16 = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(hf ? vget_high_u8(uu) : vget_low_u8(uu))), vdupq_n_s16(128));
                int16x8_t v16 = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(hf ? vget_high_u8(vv) : vget_low_u8(vv))), vdupq_n_s16(128));
                uint16x4_t c[3][2];
                for (int q = 0; q < 2; q++) {
                    int32x4_t l = vmulq_n_s32(vmovl_s16(q ? vget_high_s16(y16) : vget_low_s16(y16)), Y), rnd = vdupq_n_s32(32768);
                    int32x4_t u32 = vmovl_s16(q ? vget_high_s16(u16) : vget_low_s16(u16)), v32 = vmovl_s16(q ? vget_high_s16(v16) : vget_low_s16(v16));
                    c[0][q] = vqmovun_s32(vshrq_n_s32(vaddq_s32(vaddq_s32(l, vmulq_n_s32(v32, RV)), rnd), 16));
                    c[1][q] = vqmovun_s32(vshrq_n_s32(vaddq_s32(vsubq_s32(vsubq_s32(l, vmulq_n_s32(u32, GU)), vmulq_n_s32(v32, GV)), rnd), 16));
                    c[2][q] = vqmovun_s32(vshrq_n_s32(vaddq_s32(vaddq_s32(l, vmulq_n_s32(u32, BU)), rnd), 16));
                }
                for (int k = 0; k < 3; k++) ch[k][hf] = vqmovn_u16(vcombine_u16(c[k][0], c[k][1]));
            }
            for (int k = 0; k < 3; k++) px.val[k] = vcombine_u8(ch[k][0], ch[k][1]);
            vst4q_u8(o + 4 * x, px);
        }
        for (; x < cw; x++) {
            int l, u, v;
            if (fast) { l = (py[x] - y0) * Y; u = pu[x >> 1] - 128; v = pv[x >> 1] - 128; }
            else { l = (smp(s, 0, x, r) - y0) * Y; u = smp(s, 1, x >> s->ssx, r >> s->ssy) - 128; v = smp(s, 2, x >> s->ssx, r >> s->ssy) - 128; }
            int cr = (l + RV * v + 32768) >> 16, cg = (l - GU * u - GV * v + 32768) >> 16, cb = (l + BU * u + 32768) >> 16;
            o[4 * x] = (uint8_t)(cr < 0 ? 0 : cr > 255 ? 255 : cr); o[4 * x + 1] = (uint8_t)(cg < 0 ? 0 : cg > 255 ? 255 : cg);
            o[4 * x + 2] = (uint8_t)(cb < 0 ? 0 : cb > 255 ? 255 : cb); o[4 * x + 3] = 255;
        }
    }
}
// BGRA 行（VideoToolbox 的输出）→ RGBA 图像：交换 R、B
static void bgra_to_img(const uint8_t *src, size_t spitch, uint32_t w, uint32_t h, const cv_img *im) {
    uint32_t cw = w < im->w ? w : im->w, ch = h < im->h ? h : im->h;
    for (uint32_t r = 0; r < ch; r++) {
        const uint8_t *s = src + (size_t)r * spitch; uint8_t *o = im->host + (size_t)r * im->pitch; uint32_t x = 0;
        for (; x + 16 <= cw; x += 16) { uint8x16x4_t p = vld4q_u8(s + 4 * x); uint8x16_t t = p.val[0]; p.val[0] = p.val[2]; p.val[2] = t; vst4q_u8(o + 4 * x, p); }
        for (; x < cw; x++) { o[4 * x] = s[4 * x + 2]; o[4 * x + 1] = s[4 * x + 1]; o[4 * x + 2] = s[4 * x]; o[4 * x + 3] = s[4 * x + 3]; }
    }
}

// ---------- AV1 序列头 → av1C（VideoToolbox 的格式描述要它；游戏的 AV1 初始化不带配置记录）----------
typedef struct { const uint8_t *p; size_t n, bit; int bad; } br_t;
static uint32_t br_f(br_t *b, int k) { uint32_t v = 0; while (k--) { if (b->bit >= b->n * 8) { b->bad = 1; return 0; } v = v << 1 | (b->p[b->bit >> 3] >> (7 - (b->bit & 7)) & 1); b->bit++; } return v; }
static void br_uvlc(br_t *b) { int lz = 0; while (!b->bad && !br_f(b, 1)) lz++; if (lz < 32) br_f(b, lz); }
static int leb128(const uint8_t *p, size_t n, uint64_t *v) { *v = 0; for (int i = 0; i < 8 && (size_t)i < n; i++) { *v |= (uint64_t)(p[i] & 0x7f) << (7 * i); if (!(p[i] & 0x80)) return i + 1; } return 0; }
// 在一个时间单元里找序列头 OBU：out = av1C（4 字节头 + 这个 OBU 原样）；返回 av1C 长度，0 = 没有 / 解析失败
size_t nvn2_av1c_from_tu(const uint8_t *tu, size_t n, uint8_t *out, size_t cap) {
    for (size_t o = 0; o < n;) {
        uint8_t h = tu[o]; int type = h >> 3 & 15, ext = h >> 2 & 1, has_size = h >> 1 & 1;
        size_t hl = 1 + (size_t)ext; uint64_t sz = n - o - hl; int ll = 0;
        if (o + hl > n) return 0;
        if (has_size) { ll = leb128(tu + o + hl, n - o - hl, &sz); if (!ll) return 0; }
        size_t body = o + hl + (size_t)ll; if (body + sz > n) return 0;
        if (type == 1) {
            br_t b = { tu + body, (size_t)sz, 0, 0 };
            uint32_t prof = br_f(&b, 3); br_f(&b, 1); uint32_t reduced = br_f(&b, 1), level = 0, tier = 0;
            if (reduced) level = br_f(&b, 5);
            else {
                uint32_t timing = br_f(&b, 1), dmi = 0, bdl = 0;
                if (timing) { br_f(&b, 32); br_f(&b, 32); if (br_f(&b, 1)) br_uvlc(&b); dmi = br_f(&b, 1); if (dmi) { bdl = br_f(&b, 5) + 1; br_f(&b, 32); br_f(&b, 5); br_f(&b, 5); } }
                uint32_t idd = br_f(&b, 1), cnt = br_f(&b, 5) + 1;
                for (uint32_t i = 0; i < cnt && !b.bad; i++) {
                    br_f(&b, 12); uint32_t lv = br_f(&b, 5), t = lv > 7 ? br_f(&b, 1) : 0;
                    if (!i) { level = lv; tier = t; }
                    if (dmi && br_f(&b, 1)) { br_f(&b, (int)bdl); br_f(&b, (int)bdl); br_f(&b, 1); }
                    if (idd && br_f(&b, 1)) br_f(&b, 4);
                }
            }
            uint32_t fwb = br_f(&b, 4) + 1, fhb = br_f(&b, 4) + 1; br_f(&b, (int)fwb); br_f(&b, (int)fhb);
            if (!reduced && br_f(&b, 1)) { br_f(&b, 4); br_f(&b, 3); }
            // 128x128 超级块、帧内滤波、帧内边缘滤波
            br_f(&b, 3);
            if (!reduced) {
                br_f(&b, 4); uint32_t oh = br_f(&b, 1); if (oh) br_f(&b, 2);
                uint32_t force_sct = br_f(&b, 1) ? 2 : br_f(&b, 1);
                if (force_sct > 0 && !br_f(&b, 1)) br_f(&b, 1);
                if (oh) br_f(&b, 3);
            }
            // superres、CDEF、恢复滤波
            br_f(&b, 3);
            uint32_t hbd = br_f(&b, 1), twelve = prof == 2 && hbd ? br_f(&b, 1) : 0, mono = prof == 1 ? 0 : br_f(&b, 1), sx = 1, sy = 1, csp = 0;
            uint32_t cp = 2, tc = 2, mc = 2;
            if (br_f(&b, 1)) { cp = br_f(&b, 8); tc = br_f(&b, 8); mc = br_f(&b, 8); }
            if (mono) br_f(&b, 1);
            else if (cp == 1 && tc == 13 && mc == 0) { sx = sy = 0; }
            else {
                br_f(&b, 1);
                if (prof == 0) { sx = sy = 1; } else if (prof == 1) { sx = sy = 0; }
                else if (twelve) { sx = br_f(&b, 1); sy = sx ? br_f(&b, 1) : 0; } else { sx = 1; sy = 0; }
                if (sx && sy) csp = br_f(&b, 2);
            }
            if (b.bad || 4 + (hl + (size_t)ll + sz) > cap) return 0;
            out[0] = 0x81; out[1] = (uint8_t)(prof << 5 | (level & 31));
            out[2] = (uint8_t)(tier << 7 | hbd << 6 | twelve << 5 | mono << 4 | sx << 3 | sy << 2 | csp); out[3] = 0;
            memcpy(out + 4, tu + o, hl + (size_t)ll + sz);
            return 4 + hl + (size_t)ll + sz;
        }
        o = body + sz;
    }
    return 0;
}

// ---------- VP9 关键帧 → vpcC（VideoToolbox 的 VP9 格式描述要它，和 AV1 要 av1C 同构）----------
// 返回 1 = 关键帧且 profile 0 / 8-bit 4:2:0（*full = color_range）；0 = 这包还不是关键帧；-1 = 不支持 / 坏包
static int nvn2_vp9_kf(const uint8_t *p, size_t n, int *full) {
    br_t b = { p, n, 0, 0 };
    if (br_f(&b, 2) != 2) return -1;                     // frame_marker
    int pl = (int)br_f(&b, 1), ph = (int)br_f(&b, 1);    // profile_low_bit / profile_high_bit
    int prof = ph << 1 | pl;
    if (prof == 3) br_f(&b, 1);                          // reserved_zero
    if (br_f(&b, 1)) return 0;                           // show_existing_frame：没有色彩配置
    if (br_f(&b, 1) != 0) return 0;                      // frame_type：等关键帧
    br_f(&b, 1);                                         // show_frame
    br_f(&b, 1);                                         // error_resilient_mode
    if (br_f(&b, 24) != 0x498342u) return -1;            // frame_sync_code
    if (prof != 0) return -1;                            // services/vpx 的垫片只接 8-bit 4:2:0
    int cs = (int)br_f(&b, 3);                           // color_config：profile 0 没有 ten_or_twelve_bit
    if (cs == 7) return -1;                              // CS_RGB 只属于 profile 1/3
    *full = (int)br_f(&b, 1);                            // color_range
    return b.bad ? -1 : 1;
}

#if TARGET_OS_OSX
// vpcC：FullBox version=1 flags=0 + VPCodecConfigurationRecord（profile 0 / level 41 / 8-bit 4:2:0）
//   色彩字段写「未指定 2/2/2」：实测不影响解码像素，VT 输出的附件仍按码流；range 必须真实（会改变像素值）。
static OSStatus vp9_vt_fmt(int full, uint32_t w, uint32_t h, CMVideoFormatDescriptionRef *fmt) {
    uint8_t vpcC[] = { 1, 0, 0, 0, 0, 41, (uint8_t)(0x82 | (full ? 1 : 0)), 2, 2, 2, 0, 0 };
    CFDataRef cd = CFDataCreate(NULL, vpcC, sizeof vpcC);
    const void *ak[] = { CFSTR("vpcC") }, *av[] = { cd };
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, ak, av, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *ek[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms }, *ev[] = { atoms };
    CFDictionaryRef ext = CFDictionaryCreate(NULL, ek, ev, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus st = CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_VP9, w, h, ext, fmt);
    CFRelease(ext); CFRelease(atoms); CFRelease(cd);
    return st;
}

// 本机是否有可用的系统 VP9：注册后实际建一次会话（VTIsHardwareDecodeSupported 建不出会话时也会报 true，不能当判据）
int nvn2_vp9_vt_probe(void) {
    if (!__builtin_available(macOS 11.0, *)) return 0;
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
    CMVideoFormatDescriptionRef fmt = NULL;
    if (vp9_vt_fmt(0, 64, 64, &fmt) || !fmt) return 0;
    int32_t pf = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pfn = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    const void *bk[] = { kCVPixelBufferPixelFormatTypeKey }, *bv[] = { pfn };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, bk, bv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionSessionRef sess = NULL;
    OSStatus st = VTDecompressionSessionCreate(NULL, fmt, NULL, attrs, NULL, &sess);
    CFRelease(attrs); CFRelease(pfn); CFRelease(fmt);
    if (sess) { VTDecompressionSessionInvalidate(sess); CFRelease(sess); }
    return st == 0;
}
#else
int nvn2_vp9_vt_probe(void) { return 0; }
#endif

// ---------- 解码器 ----------
enum { CV_H264, CV_VP8, CV_VP9, CV_AV1 };
static const char *const cv_name[] = { "H.264", "VP8", "VP9", "AV1" };
typedef struct { uint8_t *p; size_t n; int64_t pts_ns; int eos; } cv_in;
typedef struct cvdec {
    void *guest; int codec, w, h;
    pthread_mutex_t mu; pthread_cond_t cv; pthread_t th;
    uint32_t ctr; uint64_t handed;
    struct { int reg, filled; uint32_t img; uint64_t seq; cv_sync fence; uint16_t fw, fh; int64_t pts_ns; int eos; } buf[CV_BUFS];
    // 游戏取帧的环（登记 / 释放次序）
    uint32_t ring[CV_BUFS]; int rh, rn;
    // 同一次序，给解码线程填
    uint32_t fill[CV_BUFS]; int fh, fn;
    cv_in *q; int qh, qn, qcap; uint64_t nsub;
    int started, quit, gen, last;
    // 「可提交」事件（游戏对象 +8）的原生事件号
    uint64_t ready_ev;
    // 以下只归解码线程
    int dgen; void *vpx; VTDecompressionSessionRef vt; CMVideoFormatDescriptionRef vtfmt; int vt_nv12;
    // VP9 系统后端（S2A_VP9_SYSTEM=1，仅 macOS）：vpcC 的范围 / VT 输出解交织缓冲（420v/420f → I420）
    int vp9_system, vp9_no_vt, vp9_full, vp9_vt_used; uint8_t *vt_u, *vt_v; size_t vt_uv_cap;
    // dav1d 软件解码（AV1 在 VideoToolbox 不支持 / 强制软解时）
    void *av1; int av1_soft;
    struct { CVPixelBufferRef pb; } vtout[4]; int nvtout;
    // H.264：码流里最近的 SPS / PPS（建格式描述用；变了就重建会话）、上一帧时间戳（判 B 帧重排）
    uint8_t sps[256], pps[256]; size_t nsps, npps; int64_t h264_pts; int h264_any;
    // 解码耗时（每包：送进解码器到拿到图，不含写进图像）
    uint64_t frames, dec_n, dec_ns, dec_max;
    // 游戏对这个解码器的前 CV_TRACE_N 次调用逐条记一行（D-2KHS：RGBA 输出那段片子 2/2 局游戏自己中止，宿主没一行红：要看它最后调了什么、回了什么）
    _Atomic int ntr;
    // 写进图像的耗时（YUV 转 RGBA / 拷 NV12 / 交换 BGRA）
    uint64_t wr_n, wr_ns;
    // 先解几帧（ah）：游戏只登记 2 个缓冲（一个在显示、一个在填），解码线程原本最多领先 1 帧；dav1d 一包偶尔 100+ ms（关键帧、和编译服务抢核），
    //   游戏就重复上一帧、影片越放越慢，声音照真实时间放、跑到前面（一款动作冒险游戏：154 s 的片子多放约 9 s）。
    //   解码线程把转好格式的帧放进宿主内存的先解队列（按图像布局，最多 CV_AHEAD_BYTES），出帧线程（eth）有空缓冲就拷进去、照旧发同步点
    struct cv_ahead { uint8_t *p; size_t cap, size; uint16_t fw, fh; int64_t pts; int eos, gen, has; } ah[32]; int ah_h, ah_n, ah_cap, ah_epoch; size_t ah_frame; pthread_t eth;
    uint64_t ah_peak, ah_low;   // 队列最深 / 出帧线程取到时队列已空（解码跟不上）的次数
    uint64_t props_wait_n, props_wait_ns;   // 游戏取帧属性时那一格还没帧、等了的次数 / 合计
} cvdec;
#define CV_AHEAD_MAX 32
#define CV_AHEAD_BYTES (96u << 20)
static pthread_mutex_t g_dec_mu = PTHREAD_MUTEX_INITIALIZER;
static cvdec *g_dec[64];
static cvdec *cv_of(const void *t) {
    pthread_mutex_lock(&g_dec_mu); cvdec *d = NULL; for (int i = 0; i < 64; i++) if (g_dec[i] && g_dec[i]->guest == t) { d = g_dec[i]; break; } pthread_mutex_unlock(&g_dec_mu);
    if (!d) die("Switch 2 视频：解码器 %p 不是宿主初始化的", t);
    return d;
}
// 持 mu
static void cv_ready_signal(cvdec *d) { if (d->started && d->qn < CV_MAXQ) s2a_event_signal(d->ready_ev); }
// 把一帧交给填充次序里的下一张缓冲：wr(图像, 参数) 写像素（NULL = 上一帧原样再给一次，带流结束标记用）；0 = 先来了 Flush / Stop / Finalize
static void wr_ahead(const cv_img *im, void *a);
static int cv_emit_now(cvdec *d, void (*wr)(const cv_img *, void *), void *arg, uint16_t fw, uint16_t fh, int64_t pts_ns, int eos, int gen) {
    pthread_mutex_lock(&d->mu);
    while (!d->quit && d->gen == gen && !d->fn) pthread_cond_wait(&d->cv, &d->mu);
    if (d->quit || d->gen != gen) { pthread_mutex_unlock(&d->mu); return 0; }
    uint32_t i = d->fill[d->fh]; d->fh = (d->fh + 1) % CV_BUFS; d->fn--;
    cv_sync fence = d->buf[i].fence; uint32_t img = d->buf[i].img; int last = d->last; uint32_t limg = last >= 0 ? d->buf[last].img : 0;
    if (!wr && last >= 0) { fw = d->buf[last].fw; fh = d->buf[last].fh; }
    pthread_mutex_unlock(&d->mu);
    if (!sp_wait(&fence, 100000000ull)) CV_RED(fence, "Switch 2 视频：缓冲 %u 的读栅栏 100 ms 没过，照写（只报一次）", i);
    cv_img im, lm;
    if (cv_img_get(img, &im)) {
        dm_guest_write_prepare(im.mem, im.size);
        if (wr) { uint64_t t0 = now_ns(); wr(&im, arg); if (wr != wr_ahead) { d->wr_ns += now_ns() - t0; d->wr_n++; } }
        else if (limg && limg != img && cv_img_get(limg, &lm) && lm.size == im.size) memcpy(im.host, lm.host, im.size);
    }
    pthread_mutex_lock(&d->mu);
    d->buf[i].fw = fw; d->buf[i].fh = fh; d->buf[i].pts_ns = pts_ns; d->buf[i].eos = eos; d->buf[i].filled = 1; d->last = (int)i;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    // 达到缓冲 i 的句柄（它的序号），唤醒游戏的同步点事件
    if (wr && !eos && s2a_video_frame_pts) s2a_video_frame_pts(pts_ns);   // 新解码的一帧报给出图节奏（重复上一帧 / 结束标记不算）；在唤醒游戏之前报，游戏拿到帧时这一帧已经计上
    sp_incr(d->ctr);
    d->frames++;
    return 1;
}
static void wr_pic(const cv_img *im, void *a) { pic_to_img(a, im); }
static void wr_pb(const cv_img *im, void *a) {
    CVPixelBufferRef pb = a;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    uint32_t w = (uint32_t)CVPixelBufferGetWidth(pb), h = (uint32_t)CVPixelBufferGetHeight(pb);
    // NV12 图像要的
    if (CVPixelBufferIsPlanar(pb)) {
        uint32_t cw = w < im->w ? w : im->w, ch = h < im->h ? h : im->h;
        const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t yp = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvp = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        if (im->kind == IMG_NV12) {
            for (uint32_t r = 0; r < ch; r++) memcpy(im->host + (size_t)r * im->pitch, y + r * yp, cw);
            for (uint32_t r = 0; r < (ch + 1) / 2; r++) memcpy(im->host + im->chroma_off + (size_t)r * im->pitch, uv + r * uvp, al(cw, 2));
        }
    } else bgra_to_img(CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetBytesPerRow(pb), w, h, im);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}
static void wr_ahead(const cv_img *im, void *a) { const struct cv_ahead *x = a; memcpy(im->host, x->p, x->size < im->size ? x->size : im->size); }
// 已登记缓冲的图像布局（同一个池，布局一样）；0 = 还没有登记的
static int cv_tpl_locked(cvdec *d, cv_img *out) { for (int i = 0; i < CV_BUFS; i++) if (d->buf[i].reg && cv_img_get(d->buf[i].img, out)) return 1; return 0; }
// 先解队列格数：上限 CV_AHEAD_BYTES；iOS 再按当时剩余内存（平台层 s2a_host_mem_avail）压到 / 8（读 0 就只开 1 格），
//   装不下就少开几格，最少 1 格、最多 CV_AHEAD_MAX。每格内存到解码器销毁才放，整段影片都占着。DM_NVN_AVAIL_MB 可代替读数（测试 / 在 Mac 上看读数）
static int cv_ahead_slots(cvdec *d, size_t frame) {
    uint64_t lim = CV_AHEAD_BYTES, avail = 0; int have_avail = 0;
    const char *e = getenv("DM_NVN_AVAIL_MB");
    if (e && *e && atoll(e) >= 0) { avail = (uint64_t)atoll(e) << 20; have_avail = 1; }
#if TARGET_OS_IPHONE
    else if (s2a_host_mem_avail) { avail = s2a_host_mem_avail(); have_avail = 1; }
#endif
    if (have_avail && avail / 8 < lim) lim = avail / 8;
    uint64_t c = frame ? lim / frame : 1;
    int n = (int)(c < 1 ? 1 : c > CV_AHEAD_MAX ? CV_AHEAD_MAX : c);
    char av[48] = ""; if (have_avail) snprintf(av, sizeof av, "，剩余内存 %.0f MB", avail / 1048576.0);
    LOG("视频解码：先解队列 %d 格 × %zu 字节 = %.1f MB（上限 %.1f MB%s）", n, frame, n * (double)frame / 1048576.0, lim / 1048576.0, av);
    d->ah_frame = frame;
    return n;
}
// 解码线程：转好的一帧进先解队列（满了等出帧线程取走）；0 = 解码器要退 / 换代（同 cv_emit_now）
static int cv_emit(cvdec *d, void (*wr)(const cv_img *, void *), void *arg, uint16_t fw, uint16_t fh, int64_t pts_ns, int eos, int gen) {
    cv_img tpl;
    pthread_mutex_lock(&d->mu);
    int have = cv_tpl_locked(d, &tpl);
    if (wr && !have) { pthread_mutex_unlock(&d->mu); return cv_emit_now(d, wr, arg, fw, fh, pts_ns, eos, gen); }   // 还没登记缓冲：照旧直接等
    if (!d->ah_cap && have) d->ah_cap = cv_ahead_slots(d, tpl.size);
    int cap = d->ah_cap ? d->ah_cap : 1;   // 还没登记缓冲时进队的只有不带图像的帧（不占内存）
    while (!d->quit && d->gen == gen && d->ah_n >= cap) pthread_cond_wait(&d->cv, &d->mu);
    if (d->quit || d->gen != gen) { pthread_mutex_unlock(&d->mu); return 0; }
    struct cv_ahead *a = &d->ah[(d->ah_h + d->ah_n) % CV_AHEAD_MAX];
    pthread_mutex_unlock(&d->mu);
    a->has = 0;
    if (wr) {
        if (a->cap < tpl.size) { free(a->p); a->p = malloc(tpl.size); a->cap = a->p ? tpl.size : 0; }
        if (!a->p) { CV_RED(ahmem, "视频解码：先解队列 %zu 字节分配不出，这一帧直接等空缓冲（不先解）", tpl.size); return cv_emit_now(d, wr, arg, fw, fh, pts_ns, eos, gen); }
        cv_img tmp = tpl; tmp.host = tmp.mem = a->p;
        uint64_t t0 = now_ns(); wr(&tmp, arg); d->wr_ns += now_ns() - t0; d->wr_n++;
        a->size = tpl.size; a->has = 1;
    }
    a->fw = fw; a->fh = fh; a->pts = pts_ns; a->eos = eos; a->gen = gen;
    pthread_mutex_lock(&d->mu);
    d->ah_n++; if ((uint64_t)d->ah_n > d->ah_peak) d->ah_peak = (uint64_t)d->ah_n;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    return 1;
}
// 出帧线程：先解队列 → 游戏的空缓冲（拷贝 + 读栅栏 + 同步点，同原先解码线程做的）
static void *cv_emitter(void *arg) {
    cvdec *d = arg;
    pthread_setname_np("s2a video emit");
    pthread_mutex_lock(&d->mu);
    for (;;) {
        if (!d->ah_n && !d->quit) d->ah_low++;
        while (!d->quit && !d->ah_n) pthread_cond_wait(&d->cv, &d->mu);
        if (d->quit) break;
        struct cv_ahead *a = &d->ah[d->ah_h]; int ep = d->ah_epoch;
        if (a->gen == d->gen) {
            pthread_mutex_unlock(&d->mu);
            cv_emit_now(d, a->has ? wr_ahead : NULL, a, a->fw, a->fh, a->pts, a->eos, a->gen);
            pthread_mutex_lock(&d->mu);
        }
        if (ep == d->ah_epoch && d->ah_n) { d->ah_h = (d->ah_h + 1) % CV_AHEAD_MAX; d->ah_n--; }   // 即时存档恢复清过队列（ah_epoch 变了）：不再出队
        pthread_cond_broadcast(&d->cv);
    }
    pthread_mutex_unlock(&d->mu);
    return NULL;
}
static void cv_vt_drop(cvdec *d) {
    if (d->vt) { VTDecompressionSessionInvalidate(d->vt); CFRelease(d->vt); d->vt = NULL; }
    if (d->vtfmt) { CFRelease(d->vtfmt); d->vtfmt = NULL; }
    for (int i = 0; i < d->nvtout; i++) CVPixelBufferRelease(d->vtout[i].pb);
    d->nvtout = 0;
}
static void cv_reset_codec(cvdec *d) {
    if (d->vpx) { if (d->codec == CV_VP9) s2a_vp9_close(d->vpx); else s2a_vp8_close(d->vpx); d->vpx = NULL; }
    if (d->av1) { s2a_av1_close(d->av1); d->av1 = NULL; }
    cv_vt_drop(d);
}
static void vt_out(void *ref, void *src, OSStatus st, VTDecodeInfoFlags fl, CVImageBufferRef ib, CMTime pts, CMTime dur) {
    (void)src; (void)fl; (void)pts; (void)dur;
    cvdec *d = ref;
    if (st) { CV_RED(vtst, "Switch 2 视频：VideoToolbox %s 解码出错 %d（只报一次）", cv_name[d->codec], (int)st); return; }
    if (ib && d->nvtout < 4) d->vtout[d->nvtout++].pb = CVPixelBufferRetain(ib);
}
static int cv_threads(void) { long n = sysconf(_SC_NPROCESSORS_ONLN); return n >= 8 ? 4 : 2; }
// S2A_AV1_SOFT=1：AV1 强制走 dav1d（有硬件的机器上验收软解用；缺省关）
static int av1_soft_forced(void) { const char *e = getenv("S2A_AV1_SOFT"); return e && !strcmp(e, "1"); }
// S2A_VP9_SYSTEM=1：nn::codec 的整帧 VP9 走 macOS VideoToolbox（仅 macOS）；=0 强制 libvpx。没设时：宿主链的是空垫片（S2A_VPX
//   探测到本机可走系统 VP9、不链真 libvpx，tools/vp9hw.sh；s2a_vpx_linked() = 0）→ 默认走系统；链了真身的机器默认 libvpx，失败自动回退
#if TARGET_OS_OSX
static int vp9_system_enabled(void) {
    const char *e = getenv("S2A_VP9_SYSTEM");
    if (e) return !strcmp(e, "1");
    return s2a_vpx_linked && !s2a_vpx_linked();
}
#endif
static _Atomic unsigned long long g_vp9_vt_frames;
unsigned long long nvn2_vp9_vt_frames(void) { return atomic_load(&g_vp9_vt_frames); }
static void cv_soft_open(cvdec *d, const char *why) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (!s2a_av1_open) die("Switch 2 视频：%s；宿主没链 dav1d 垫片（services/dav1d；本机构建有 AV1 硬解时不链，S2A_DAV1D），解不了 AV1（%dx%d）", why, d->w, d->h);
    if (!(d->av1 = s2a_av1_open(n >= 8 ? 6 : (int)n))) die("Switch 2 视频：dav1d 建不出 AV1 解码器（%dx%d）", d->w, d->h);
    if (!d->av1_soft++) LOG("Switch 2 视频：AV1 %dx%d 走 dav1d 软件解码（%s）", d->w, d->h, why);
}
static void dec_time(cvdec *d, uint64_t t0) { uint64_t t = now_ns() - t0; d->dec_n++; d->dec_ns += t; if (t > d->dec_max) d->dec_max = t; }
// 按 d->vtfmt 建 VideoToolbox 解码会话（AV1 / H.264 共用）：输出 BGRA（RGBA 图像）或 NV12（看图像池）；0 = 建好
static OSStatus cv_vt_session(cvdec *d) {
    int32_t pf = d->vt_nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA;
    CFNumberRef pfn = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    const void *bk[] = { kCVPixelBufferPixelFormatTypeKey }, *bv[] = { pfn };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, bk, bv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord cb = { vt_out, d };
    OSStatus st = VTDecompressionSessionCreate(NULL, d->vtfmt, NULL, attrs, &cb, &d->vt);
    CFRelease(attrs); CFRelease(pfn);
    if (st) d->vt = NULL;
    return st;
}
// 一个样本（s 归这里：交给块缓冲后由它 free）送 VideoToolbox 并等出图；回解码状态
static OSStatus cv_vt_submit(cvdec *d, uint8_t *s, size_t sn, int64_t pts_ns) {
    CMBlockBufferRef bb = NULL; CMSampleBufferRef sb = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, s, sn, kCFAllocatorMalloc, NULL, 0, sn, 0, &bb);
    if (!st) { size_t ss = sn; CMSampleTimingInfo ti = { kCMTimeInvalid, CMTimeMake(pts_ns / 1000, 1000000), kCMTimeInvalid }; st = CMSampleBufferCreateReady(NULL, bb, d->vtfmt, 1, 1, &ti, 1, &ss, &sb); }
    else free(s);
    if (!st) st = VTDecompressionSessionDecodeFrame(d->vt, sb, 0, NULL, NULL);
    if (sb) CFRelease(sb);
    if (bb) CFRelease(bb);
    if (!st) VTDecompressionSessionWaitForAsynchronousFrames(d->vt);
    return st;
}
// 把 VideoToolbox 回调攒下的图交给游戏的缓冲；0 = 中途来了 Flush / Stop / Finalize（剩下的放掉）
static int cv_vt_emit(cvdec *d, int64_t pts, int gen) {
    for (int i = 0; d->vt && i < d->nvtout; i++) {
        CVPixelBufferRef pb = d->vtout[i].pb;
        int ok = cv_emit(d, wr_pb, pb, (uint16_t)CVPixelBufferGetWidth(pb), (uint16_t)CVPixelBufferGetHeight(pb), pts, 0, gen);
        CVPixelBufferRelease(pb);
        if (!ok) { for (int k = i + 1; k < d->nvtout; k++) CVPixelBufferRelease(d->vtout[k].pb); d->nvtout = 0; return 0; }
    }
    d->nvtout = 0;
    return 1;
}
// H.264 一包 → NAL 单元（起止偏移）：开头是起始码（00 00 01 / 00 00 00 01）按 Annex B 切，否则按 4 字节大端长度前缀（AVCC）切；
//   长度前缀越界 / 0 长度当坏包（回 -1）。回 NAL 个数（最多 cap）
int nvn2_h264_nals(const uint8_t *p, size_t n, size_t (*nal)[2], int cap) {
    int k = 0;
    if (n >= 3 && !p[0] && !p[1] && (p[2] == 1 || (n >= 4 && !p[2] && p[3] == 1))) {
        size_t o = 0;
        while (o + 3 <= n) {   // 找下一个起始码
            size_t sc = o; while (sc + 3 <= n && !(!p[sc] && !p[sc + 1] && p[sc + 2] == 1)) sc++;
            if (sc + 3 > n) break;
            size_t b = sc + 3, e = b; while (e + 3 <= n && !(!p[e] && !p[e + 1] && p[e + 2] <= 1)) e++;
            if (e + 3 > n) e = n;
            size_t t = e; while (t > b && !p[t - 1]) t--;   // 去掉下一个 4 字节起始码前的 0（零尾巴不属于这个 NAL）
            if (t > b && k < cap) { nal[k][0] = b; nal[k][1] = t; k++; }
            o = e;
        }
        return k;
    }
    for (size_t o = 0; o < n;) {
        if (o + 4 > n) return -1;
        size_t l = (size_t)p[o] << 24 | (size_t)p[o + 1] << 16 | (size_t)p[o + 2] << 8 | p[o + 3];
        if (!l || o + 4 + l > n) return -1;
        if (k < cap) { nal[k][0] = o + 4; nal[k][1] = o + 4 + l; k++; }
        o += 4 + l;
    }
    return k;
}
// H.264 一包：记 SPS / PPS（变了就重建会话），其余 NAL 按 AVCC（4 字节长度）拼成样本送 VideoToolbox；访问单元分隔符不送
static void cv_h264_decode(cvdec *d, const cv_in *in, int64_t pts, int gen) {
    size_t nal[64][2]; int nn = nvn2_h264_nals(in->p, in->n, nal, 64);
    if (nn < 0) { CV_RED(h264bad, "Switch 2 视频：H.264 包既不是起始码分隔、长度前缀也对不上（%zu 字节）：这一包没有画面", in->n); return; }
    uint8_t *s = malloc(in->n + 4 * (size_t)nn + 4); size_t sn = 0; int changed = 0;
    if (!s) { CV_RED(h264mem, "Switch 2 视频：H.264 样本缓冲 %zu 字节分配不出（宿主地址 / 内存耗尽），这一包没有画面", in->n); return; }   // 兜底，根修见 cv_submit
    for (int i = 0; i < nn; i++) {
        const uint8_t *q = in->p + nal[i][0]; size_t l = nal[i][1] - nal[i][0]; int ty = q[0] & 0x1f;
        if (ty == 7 || ty == 8) {
            uint8_t *dst = ty == 7 ? d->sps : d->pps; size_t *dn = ty == 7 ? &d->nsps : &d->npps;
            if (l > sizeof d->sps) { CV_RED(h264ps, "Switch 2 视频：H.264 参数集 %zu 字节超过 %zu，忽略", l, sizeof d->sps); continue; }
            if (*dn != l || memcmp(dst, q, l)) { memcpy(dst, q, l); *dn = l; changed = 1; }
            continue;
        }
        if (ty == 9) continue;
        s[sn++] = (uint8_t)(l >> 24); s[sn++] = (uint8_t)(l >> 16); s[sn++] = (uint8_t)(l >> 8); s[sn++] = (uint8_t)l;
        memcpy(s + sn, q, l); sn += l;
    }
    if (changed && d->vt) { cv_vt_drop(d); LOG("Switch 2 视频：H.264 参数集变了，重建 VideoToolbox 会话"); }
    if (!d->vt) {
        if (!d->nsps || !d->npps) { free(s); CV_RED(h264nops, "Switch 2 视频：H.264 码流里还没见到 SPS / PPS，等下一包（这一包没有画面）"); return; }
        const uint8_t *ps[2] = { d->sps, d->pps }; size_t pn[2] = { d->nsps, d->npps };
        OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, pn, 4, &d->vtfmt);
        if (!st) st = cv_vt_session(d);
        if (st) { free(s); cv_vt_drop(d); CV_RED(h264open, "Switch 2 视频：H.264 的 VideoToolbox 格式描述 / 会话建不出（%d）：这一包没有画面", (int)st); return; }
        LOG("Switch 2 视频：H.264 %dx%d 走 VideoToolbox 硬件解码（SPS %zu、PPS %zu 字节，输出 %s）", d->w, d->h, d->nsps, d->npps, d->vt_nv12 ? "NV12" : "BGRA→RGBA");
    }
    if (!sn) { free(s); return; }   // 只有参数集 / 分隔符：本来就没有画面
    if (d->h264_any && in->pts_ns < d->h264_pts) { static _Atomic int said; if (!atomic_exchange(&said, 1)) LOG("【黄】Switch 2 视频：H.264 时间戳倒退（%lld → %lld ns，带 B 帧）：宿主按解码次序出帧，显示次序会错", (long long)d->h264_pts, (long long)in->pts_ns); }
    d->h264_pts = in->pts_ns; d->h264_any = 1;
    uint64_t t0 = now_ns(); OSStatus st = cv_vt_submit(d, s, sn, in->pts_ns); dec_time(d, t0);
    if (st) CV_RED(h264dec, "Switch 2 视频：H.264 VideoToolbox 解码失败（%d，首个 %zu 字节）：这一包没有画面", (int)st, in->n);
    cv_vt_emit(d, pts, gen);
}
// 为 AV1 建 VideoToolbox 会话（第一个带序列头的包）；输出 BGRA（RGBA 图像）或 NV12
static int cv_vt_open(cvdec *d, const uint8_t *p, size_t n) {
    uint8_t av1c[512]; size_t an = nvn2_av1c_from_tu(p, n, av1c, sizeof av1c);
    if (!an) return 0;
    CFDataRef cd = CFDataCreate(NULL, av1c, (CFIndex)an);
    const void *ak[] = { CFSTR("av1C") }, *av[] = { cd };
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, ak, av, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *ek[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms }, *ev[] = { atoms };
    CFDictionaryRef ext = CFDictionaryCreate(NULL, ek, ev, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus st = CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_AV1, d->w, d->h, ext, &d->vtfmt);
    CFRelease(ext); CFRelease(atoms); CFRelease(cd);
    if (st) { LOG("Switch 2 视频：AV1 格式描述建不出（%d），改用 dav1d", (int)st); return -1; }
    if ((st = cv_vt_session(d))) { LOG("Switch 2 视频：AV1 的 VideoToolbox 会话建不出（%d），改用 dav1d", (int)st); return -1; }
    LOG("Switch 2 视频：AV1 %dx%d 走 VideoToolbox 硬件解码（av1C %zu 字节，输出 %s）", d->w, d->h, an, d->vt_nv12 ? "NV12" : "BGRA→RGBA");
    return 1;
}
#if TARGET_OS_OSX
// 返回 1 = 会话建好；0 = 这包还不是关键帧（先不出画面）；-1 = 不支持 / 建不出（调用方回 libvpx）
static int cv_vt_open_vp9(cvdec *d, const uint8_t *p, size_t n) {
    int full = 0;
    int k = nvn2_vp9_kf(p, n, &full);
    if (k <= 0) return k;
    if (!__builtin_available(macOS 11.0, *)) return -1;
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = vp9_vt_fmt(full, (uint32_t)d->w, (uint32_t)d->h, &fmt);
    if (st || !fmt) { LOG("Switch 2 视频：VP9 的 vpcC/格式描述建不出（%d），改走 libvpx", (int)st); return -1; }
    int32_t pf = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pfn = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    const void *bk[] = { kCVPixelBufferPixelFormatTypeKey }, *bv[] = { pfn };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, bk, bv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord cb = { vt_out, d };
    st = VTDecompressionSessionCreate(NULL, fmt, NULL, attrs, &cb, &d->vt);
    CFRelease(attrs); CFRelease(pfn);
    if (st) { CFRelease(fmt); LOG("Switch 2 视频：VP9 的 VideoToolbox 会话建不出（%d），改走 libvpx", (int)st); return -1; }
    d->vtfmt = fmt; d->vp9_full = full; d->vp9_vt_used = 1;
    LOG("Switch 2 视频：VP9 %dx%d 走 VideoToolbox（vpcC 12 字节，%s范围）", d->w, d->h, full ? "全" : "视频");
    return 1;
}

// VT 输出 NV12（420v/420f）→ 解交织成 U/V 两份，交给现有 pic_to_img：NV12 / RGBA 图像池、BT.601/709、全/视频范围都和 libvpx 同一条路
static int cv_vp9_vt_emit(cvdec *d, CVPixelBufferRef pb, int64_t pts, int gen) {
    if (CVPixelBufferGetPlaneCount(pb) < 2) { CV_RED(vp9fmt, "Switch 2 视频：VP9 的 VideoToolbox 输出不是双平面（这一包没有画面）"); return 1; }
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), cw = (w + 1) / 2, ch = (h + 1) / 2;
    if (d->vt_uv_cap < cw * ch) {
        uint8_t *u = malloc(cw * ch), *v = malloc(cw * ch);
        free(d->vt_u); free(d->vt_v); d->vt_u = u; d->vt_v = v;
        d->vt_uv_cap = u && v ? cw * ch : 0;
    }
    if (!d->vt_uv_cap) { CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly); CV_RED(vp9mem, "Switch 2 视频：VP9 系统解码的色度缓冲分配不出（这一包没有画面）"); return 1; }
    const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t uvp = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (size_t r = 0; r < ch; r++) {
        const uint8_t *s = uv + r * uvp; uint8_t *u = d->vt_u + r * cw, *v = d->vt_v + r * cw;
        for (size_t x = 0; x < cw; x++) { u[x] = s[2 * x]; v[x] = s[2 * x + 1]; }
    }
    // 矩阵：VT 按码流给附件；没有附件时沿用 libvpx 的同一启发（>=720 行 BT.709）
    int m = -1;
    CFTypeRef a = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
    if (a) { if (CFGetTypeID(a) == CFStringGetTypeID()) m = CFEqual(a, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ? 1 : 0; CFRelease(a); }
    cv_pic pic = { { CVPixelBufferGetBaseAddressOfPlane(pb, 0), d->vt_u, d->vt_v },
                   { (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0), (int)cw, (int)cw },
                   (int)w, (int)h, d->vp9_full, m == 1 || (m < 0 && d->h >= 720), 8, 1, 1, 0 };
    int ok = cv_emit(d, wr_pic, &pic, (uint16_t)w, (uint16_t)h, pts, 0, gen);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (ok) atomic_fetch_add(&g_vp9_vt_frames, 1);
    return ok;
}

// 返回 1 = VT 已处理（包括成功但没画面）；0 = 本包没走 VT（调用方走 libvpx）
static int cv_vp9_vt_decode(cvdec *d, const cv_in *in, int64_t pts, int gen) {
    if (!d->vt) {
        int r = cv_vt_open_vp9(d, in->p, in->n);
        if (r < 0) { d->vp9_no_vt = 1; CV_RED(vp9vt, "Switch 2 视频：VP9 的 VideoToolbox 后端不可用（%dx%d），改走 libvpx（到下一个关键帧前可能没有画面）", d->w, d->h); return 0; }
        if (r == 0) { CV_RED(vp9kf, "Switch 2 视频：VP9 系统后端还没收到关键帧（这一包没有画面）"); return 1; }
    }
    uint8_t *s = malloc(in->n); if (!s) { CV_RED(vp9mem, "Switch 2 视频：VP9 系统解码的包缓冲分配不出（这一包没有画面）"); return 1; }
    memcpy(s, in->p, in->n);
    CMBlockBufferRef bb = NULL; CMSampleBufferRef sb = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, s, in->n, kCFAllocatorMalloc, NULL, 0, in->n, 0, &bb);
    if (st) free(s);
    size_t ss = in->n;
    CMSampleTimingInfo ti = { kCMTimeInvalid, CMTimeMake(in->pts_ns / 1000, 1000000), kCMTimeInvalid };
    if (!st) st = CMSampleBufferCreateReady(NULL, bb, d->vtfmt, 1, 1, &ti, 1, &ss, &sb);
    uint64_t t0 = now_ns();
    if (!st) st = VTDecompressionSessionDecodeFrame(d->vt, sb, 0, NULL, NULL);
    if (!st) st = VTDecompressionSessionWaitForAsynchronousFrames(d->vt);
    if (sb) CFRelease(sb);
    if (bb) CFRelease(bb);
    dec_time(d, t0);
    if (st) {
        d->vp9_no_vt = 1;
        cv_vt_drop(d);
        CV_RED(vp9dec, "Switch 2 视频：VP9 VideoToolbox 解码失败（%d），改走 libvpx（到下一个关键帧前可能没有画面）", (int)st);
        return 0;
    }
    for (int i = 0; i < d->nvtout; i++) {
        CVPixelBufferRef pb = d->vtout[i].pb;
        int ok = cv_vp9_vt_emit(d, pb, pts, gen);
        CVPixelBufferRelease(pb);
        if (!ok) { for (int k = i + 1; k < d->nvtout; k++) CVPixelBufferRelease(d->vtout[k].pb); d->nvtout = 0; return 1; }
    }
    d->nvtout = 0;
    return 1;
}
#endif // TARGET_OS_OSX

static void cv_decode(cvdec *d, const cv_in *in, int gen) {
    // SDK 按微秒发（sdk+0x336260），按 微秒 × 1000 报
    int64_t pts = in->pts_ns / 1000 * 1000;
    int vt_handled = 0;
#if TARGET_OS_OSX
    if (in->n && d->codec == CV_VP9 && d->vp9_system && !d->vp9_no_vt) vt_handled = cv_vp9_vt_decode(d, in, pts, gen);
#endif
    if (!vt_handled && in->n && (d->codec == CV_VP9 || d->codec == CV_VP8)) {
        if (!d->vpx && s2a_vpx_linked && !s2a_vpx_linked()) die("Switch 2 视频：宿主没链真 libvpx（S2A_VPX 探测到本机可走系统 VP9 不链，tools/vp9hw.sh），这条 %s 流走不了系统路线又没有软解兜底，解不了（要兜底设 S2A_VPX=1）", cv_name[d->codec]);
        if (!d->vpx && !s2a_vp9_open) die("Switch 2 视频：宿主没链 libvpx 垫片（services/vpx），解不了 %s", cv_name[d->codec]);
        if (!d->vpx && !(d->vpx = d->codec == CV_VP9 ? s2a_vp9_open(cv_threads()) : s2a_vp8_open())) die("Switch 2 视频：libvpx 建不出 %s 解码器", cv_name[d->codec]);
        uint8_t *pl[3]; int32_t st[3], info[4] = { 0, 0, -1, 0 }; uint64_t t0 = now_ns();
        int r = d->codec == CV_VP9 ? s2a_vp9_decode(d->vpx, in->p, (uint32_t)in->n, pl, st, info) : s2a_vp8_decode(d->vpx, in->p, (uint32_t)in->n, pl, st, info);
        dec_time(d, t0);
        if (r == 0) {
            cv_pic pic = { { pl[0], pl[1], pl[2] }, { st[0], st[1], st[2] }, info[0], info[1], info[3], info[2] == 1 || (info[2] < 0 && d->h >= 720), 8, 1, 1, 0 };
            cv_emit(d, wr_pic, &pic, (uint16_t)info[0], (uint16_t)info[1], pts, 0, gen);
        } else if (r < 0) CV_RED(vpxerr, "Switch 2 视频：%s 解码失败（%s，首个 %zu 字节）：这一包没有画面", cv_name[d->codec], r == -2 ? "不是 8 位 4:2:0" : "libvpx 报错", in->n);
    } else if (!vt_handled && in->n && d->codec == CV_H264) {
        cv_h264_decode(d, in, pts, gen);
    } else if (!vt_handled && in->n && d->codec == CV_AV1) {
        if (!d->vt && !d->av1) {
            if (av1_soft_forced()) cv_soft_open(d, "S2A_AV1_SOFT=1 强制");
            else if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) cv_soft_open(d, "这台机器 VideoToolbox 不支持 AV1");
            else {
                int r = cv_vt_open(d, in->p, in->n);
                if (r < 0) cv_soft_open(d, "VideoToolbox 会话建不出");
                else if (!r) CV_RED(av1nosh, "Switch 2 视频：AV1 包里还没有序列头，等下一包（这一包没有画面）");
            }
        }
        if (d->vt) {
            // 去掉时间分隔 OBU（ISOBMFF / Matroska 的 AV1 样本约定不带它）
            // 同时看包里有没有帧数据（帧头 3、分块组 4、帧 6、冗余帧头 7）：只有时间分隔 / 填充 / 元数据的包本来就没有画面，
            //   原先照样送 VideoToolbox，回 -12903（数据坏）并报红（诊断 #4ddff2：3 字节的包）。这种包直接跳过、不报红；解析不了的尾巴按有帧数据送去
            uint8_t *s = malloc(in->n); size_t sn = 0; uint64_t t0 = now_ns(); int frame = 0;
            if (!s) { CV_RED(av1mem, "Switch 2 视频：AV1 样本缓冲 %zu 字节分配不出（宿主地址 / 内存耗尽），这一包没有画面", in->n); return; }   // 兜底，根修见 cv_submit
            for (size_t o = 0; o < in->n;) {
                uint8_t h = in->p[o]; size_t hl = 1 + (h >> 2 & 1); uint64_t sz = in->n - o - hl; int ll = 0, ty = h >> 3 & 15;
                if (h >> 1 & 1) ll = leb128(in->p + o + hl, in->n - o - hl, &sz);
                size_t e = o + hl + (size_t)ll + (size_t)sz; if (e > in->n || o + hl > in->n) { memcpy(s + sn, in->p + o, in->n - o); sn += in->n - o; frame = 1; break; }
                if (ty != 2) { memcpy(s + sn, in->p + o, e - o); sn += e - o; }
                if (ty == 3 || ty == 4 || ty == 6 || ty == 7) frame = 1;
                o = e;
            }
            if (!frame) { free(s); static _Atomic int said; if (!atomic_exchange(&said, 1)) LOG("Switch 2 视频：AV1 包里没有帧数据（%zu 字节，只有时间分隔 / 填充之类），跳过（本来就没有画面）", in->n); return; }
            OSStatus st = cv_vt_submit(d, s, sn, in->pts_ns);
            dec_time(d, t0);
            if (st == kVTVideoDecoderNotAvailableNowErr || st == kVTCouldNotFindVideoDecoderErr || st == kVTVideoDecoderUnsupportedDataFormatErr) {
                // 硬件解码器这时不可用：之后全部改走 dav1d（从这一包起；引用帧丢了的话到下一个关键帧前 dav1d 报错、没有画面，红行里有）
                cv_vt_drop(d); cv_soft_open(d, "VideoToolbox 解码时报不支持");
            } else if (st) CV_RED(vtdec, "Switch 2 视频：AV1 VideoToolbox 解码失败（%d，首个 %zu 字节）：这一包没有画面", (int)st, in->n);
            if (!cv_vt_emit(d, pts, gen)) return;
        }
        if (d->av1) {
            uint8_t *pl[3]; int32_t st[3], info[6]; uint64_t t0 = now_ns();
            int r = s2a_av1_decode(d->av1, in->p, (uint32_t)in->n, pl, st, info);
            dec_time(d, t0);
            if (r == 0) {
                cv_pic pic = { { pl[0], pl[1], pl[2] }, { st[0], st[1], st[2] }, info[0], info[1], info[5], info[4] == 1 || (info[4] < 0 && d->h >= 720), info[2],
                               info[3] == 1 || info[3] == 2, info[3] == 1, info[3] == 0 };
                if (!cv_emit(d, wr_pic, &pic, (uint16_t)info[0], (uint16_t)info[1], pts, 0, gen)) return;
            } else if (r < 0) CV_RED(av1err, "Switch 2 视频：AV1 dav1d 解码失败（首个 %zu 字节）：这一包没有画面", in->n);
        }
    }
    // 流结束：再出一帧带标记（图是上一帧）
    if (in->eos) cv_emit(d, NULL, NULL, (uint16_t)d->w, (uint16_t)d->h, pts, 1, gen);
}
static void *cv_worker(void *arg) {
    cvdec *d = arg;
    pthread_setname_np("s2a video decoder");
    pthread_mutex_lock(&d->mu);
    for (;;) {
        while (!d->quit && !(d->started && d->qn)) pthread_cond_wait(&d->cv, &d->mu);
        if (d->quit) break;
        cv_in in = d->q[d->qh]; d->qh = (d->qh + 1) % d->qcap; d->qn--;
        int gen = d->gen;
        cv_ready_signal(d);
        pthread_mutex_unlock(&d->mu);
        if (d->dgen != gen) { cv_reset_codec(d); d->dgen = gen; }
        cv_decode(d, &in, gen);
        free(in.p);
        pthread_mutex_lock(&d->mu);
    }
    pthread_mutex_unlock(&d->mu);
    return NULL;
}
// 持 mu
static void cv_drop_inputs(cvdec *d) { while (d->qn) { free(d->q[d->qh].p); d->qh = (d->qh + 1) % d->qcap; d->qn--; } }

static void cv_teardown(cvdec *d, int guest_event);
static Result cv_init(void *t, int codec, uint32_t w, uint32_t h) {
    w &= 0xffff; h &= 0xffff;
    // 同一块对象没 Finalize 又 Initialize（12 份诊断，0.3.5–0.3.10，时之笛过场 / 玩家开始事件后）：真机 SDK 不中止，照新参数重新初始化。
    //   原先这里 die（「初始化两次」）。先把旧的宿主解码器收掉（停线程、放缓冲与同步点），游戏对象里的事件不销毁（已归这一次），再按新的建
    {
        pthread_mutex_lock(&g_dec_mu); cvdec *old = NULL;
        for (int i = 0; i < 64; i++) if (g_dec[i] && g_dec[i]->guest == t) { old = g_dec[i]; g_dec[i] = NULL; break; }
        pthread_mutex_unlock(&g_dec_mu);
        if (old) { LOG("【黄】Switch 2 视频：解码器 %p 没 Finalize 又初始化：先收掉旧的 %s 解码器，按新的 %ux%u 重建", t, cv_name[old->codec], w, h); cv_teardown(old, 0); }
    }
    cvdec *d = calloc(1, sizeof *d); if (!d) die("Switch 2 视频：内存不足");
    d->guest = t; d->codec = codec; d->w = (int)w; d->h = (int)h; d->last = -1;
#if TARGET_OS_OSX
    d->vp9_system = codec == CV_VP9 && vp9_system_enabled();
    if (d->vp9_system) LOG("Switch 2 视频：VP9 走系统解码（VideoToolbox；%s，失败回退 libvpx）", getenv("S2A_VP9_SYSTEM") && !strcmp(getenv("S2A_VP9_SYSTEM"), "1") ? "S2A_VP9_SYSTEM=1" : "宿主没链真 libvpx，默认系统");
#endif
    d->qcap = 64; d->q = calloc((size_t)d->qcap, sizeof *d->q);
    pthread_mutex_init(&d->mu, NULL); pthread_cond_init(&d->cv, NULL);
    d->ctr = sp_alloc(); d->handed = sp_value(d->ctr);
    // SDK 放它的位置（sdk+0x336250）
    d->ready_ev = sev_attach((uint8_t *)t + 8, 1);
    pthread_mutex_lock(&g_dec_mu);
    int k = -1; for (int i = 0; i < 64; i++) { if (g_dec[i] && g_dec[i]->guest == t) die("Switch 2 视频：解码器 %p 初始化两次", t); if (!g_dec[i] && k < 0) k = i; }
    if (k < 0) die("Switch 2 视频：同时在用的解码器超过 64 个");
    g_dec[k] = d;
    pthread_mutex_unlock(&g_dec_mu);
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 4 << 20);
    if (pthread_create(&d->th, &a, cv_worker, d)) die("Switch 2 视频：解码线程起不来");
    if (pthread_create(&d->eth, &a, cv_emitter, d)) die("视频解码：出帧线程起不来");
    pthread_attr_destroy(&a);
    LOG("Switch 2 视频：%s 解码器 %ux%u（宿主线程解码，不进 gsv）", cv_name[codec], w, h);
    return RES_OK;
}
static void cv_fini(void *t) {
    cvdec *d = cv_of(t);
    pthread_mutex_lock(&g_dec_mu); for (int i = 0; i < 64; i++) if (g_dec[i] == d) g_dec[i] = NULL; pthread_mutex_unlock(&g_dec_mu);
    cv_teardown(d, 1);
}
// 收掉一个宿主解码器（已从 g_dec 摘下）。guest_event：连游戏对象里的 SystemEvent 一起销毁（正常 Finalize）；
//   0 = 游戏在同一块对象上重新初始化，那块事件已归新的一次所有，只放掉我们这边的引用
static void cv_teardown(cvdec *d, int guest_event) {
    void *t = d->guest;
    pthread_mutex_lock(&d->mu); d->quit = 1; pthread_cond_broadcast(&d->cv); pthread_mutex_unlock(&d->mu);
    DM_BLOCK_BEGIN(); pthread_join(d->th, NULL); pthread_join(d->eth, NULL); DM_BLOCK_END();
    cv_reset_codec(d); cv_drop_inputs(d); free(d->q); free(d->vt_u); free(d->vt_v);
    for (int i = 0; i < CV_AHEAD_MAX; i++) free(d->ah[i].p);
    sp_free(d->ctr);
    static void (*destroy)(void *);
    if (guest_event) {
        if (!destroy) destroy = (void (*)(void *))gsym("_ZN2nn2os18DestroySystemEventEPNS0_15SystemEventTypeE");
        destroy((uint8_t *)t + 8);   // 托管句柄随之关掉
    }
    s2a_event_release(d->ready_ev);
    LOG("视频解码：先解队列 %d 格（%.1f MB）、最深 %llu 帧，出帧线程取到空队列 %llu 次；游戏取帧属性时那格还没帧 %llu 次、合计等 %.1f ms", d->ah_cap, d->ah_cap * (double)d->ah_frame / 1048576.0, (unsigned long long)d->ah_peak,
        (unsigned long long)d->ah_low, (unsigned long long)d->props_wait_n, d->props_wait_ns / 1e6);
    LOG("Switch 2 视频：%s 解码器结束，出帧 %llu；解码 %llu 包，每包平均 %.2f ms、最长 %.2f ms；写进图像每帧平均 %.2f ms（%s）", cv_name[d->codec], (unsigned long long)d->frames, (unsigned long long)d->dec_n,
        d->dec_n ? d->dec_ns / 1e6 / (double)d->dec_n : 0.0, d->dec_max / 1e6, d->wr_n ? d->wr_ns / 1e6 / (double)d->wr_n : 0.0,
        d->codec == CV_AV1 ? (d->av1_soft ? "dav1d 软件解码" : "VideoToolbox") : d->codec == CV_H264 ? "VideoToolbox" : d->codec == CV_VP9 && d->vp9_vt_used && !d->vp9_no_vt ? "VideoToolbox" : "libvpx");
    pthread_mutex_destroy(&d->mu); pthread_cond_destroy(&d->cv); free(d);
}
// 持 mu：登记 / 释放的缓冲拿下一个句柄，进两条次序
static void cv_queue(cvdec *d, uint32_t i) {
    d->buf[i].seq = ++d->handed; d->buf[i].filled = 0;
    d->ring[(d->rh + d->rn++) % CV_BUFS] = i;
    d->fill[(d->fh + d->fn++) % CV_BUFS] = i;
    pthread_cond_broadcast(&d->cv);
}
static Result cv_register(void *t, uint32_t i, const cv_pool *pool, uint32_t img) {
    cvdec *d = cv_of(t);
    if (i >= CV_BUFS || img >= pool->count) { LOG("【红】Switch 2 视频：登记缓冲 %u（图像 %u / %u）越界", i, img, pool->count); return RES_FAIL; }
    pthread_mutex_lock(&d->mu);
    // SDK 对重复登记的结果
    if (d->buf[i].reg) { pthread_mutex_unlock(&d->mu); LOG("【红】Switch 2 视频：缓冲 %u 重复登记，回 0xfa26f（游戏拿到失败会自己中止）", i); return 0xfa26f; }
    d->buf[i].reg = 1; d->buf[i].img = pool->first + img; memset(&d->buf[i].fence, 0, sizeof d->buf[i].fence);
    cv_img im; if (cv_img_get(d->buf[i].img, &im)) d->vt_nv12 = im.kind == IMG_NV12;
    cv_queue(d, i);
    int rn = d->rn, kind = cv_img_get(d->buf[i].img, &im) ? im.kind : 0;
    pthread_mutex_unlock(&d->mu);
    CV_TR(d, "Register 缓冲 %u ← 图像 %u（%s），环里 %d", i, pool->first + img, kind == IMG_NV12 ? "NV12" : kind == IMG_RGBA ? "RGBA" : kind == IMG_HDR ? "HDR" : "不认识", rn);
    return RES_OK;
}
static Result cv_start(void *t) { cvdec *d = cv_of(t); pthread_mutex_lock(&d->mu); d->started = 1; pthread_cond_broadcast(&d->cv); cv_ready_signal(d); int rn = d->rn; pthread_mutex_unlock(&d->mu); CV_TR(d, "Start，环里 %d", rn); return RES_OK; }
// 排队的包丢掉、解码器重来；等帧的缓冲继续等
static Result cv_flush(void *t, int stop) {
    cvdec *d = cv_of(t);
    pthread_mutex_lock(&d->mu);
    cv_drop_inputs(d); d->gen++;
    if (stop) d->started = 0;
    pthread_cond_broadcast(&d->cv); cv_ready_signal(d);
    int rn = d->rn, fn = d->fn;
    pthread_mutex_unlock(&d->mu);
    CV_TR(d, "%s，环里 %d、等帧 %d", stop ? "Stop" : "Flush", rn, fn);
    return RES_OK;
}
static Result cv_submit(uint64_t *id, void *t, const void *p, uint64_t n, int64_t pts_ns, uint32_t eos) {
    cvdec *d = cv_of(t);
    cv_in in = { n ? malloc(n) : NULL, n, pts_ns, (int)(eos & 1) };
    // 兜底（D-R2VX / D-NK6Y：宿主低区地址耗尽时 malloc 回空，原先直接 memcpy 到 0 崩）：这一包当空包排进去（没有画面、流照走），打红行。
    //   根修是宿主下限（vawin.c s2a_window_host_floor），这里只是耗尽时不崩在这儿
    if (n && !in.p) { CV_RED(submem, "Switch 2 视频：提交的包缓冲 %llu 字节分配不出（宿主地址 / 内存耗尽），这一包当空包、没有画面", (unsigned long long)n); in.n = 0; }
    if (in.n) memcpy(in.p, p, n);
    pthread_mutex_lock(&d->mu);
    // 游戏不看可提交事件也提交：队列加长，不丢包
    if (d->qn == d->qcap) {
        cv_in *q = calloc((size_t)d->qcap * 2, sizeof *q);
        for (int k = 0; k < d->qn; k++) q[k] = d->q[(d->qh + k) % d->qcap];
        free(d->q); d->q = q; d->qh = 0; d->qcap *= 2;
    }
    d->q[(d->qh + d->qn++) % d->qcap] = in;
    *id = ++d->nsub;
    if (d->nsub <= 4 || eos) CV_TR(d, "Submit 第 %llu 包 %llu 字节 时间 %lld ns%s", (unsigned long long)d->nsub, (unsigned long long)n, (long long)pts_ns, eos & 1 ? "（流结束）" : "");
    if (d->qn >= CV_MAXQ) s2a_event_clear(d->ready_ev);
    pthread_cond_broadcast(&d->cv); cv_ready_signal(d);
    pthread_mutex_unlock(&d->mu);
    return RES_OK;
}
static Result cv_acquire(uint32_t *idx, cv_sync *h, void *t) {
    cvdec *d = cv_of(t);
    pthread_mutex_lock(&d->mu);
    if (!d->rn) { int fn = d->fn; pthread_mutex_unlock(&d->mu); CV_TR(d, "Acquire 环空，回 %#x（等帧 %d）", CV_NOT_READY, fn); return CV_NOT_READY; }
    uint32_t i = d->ring[d->rh]; d->rh = (d->rh + 1) % CV_BUFS; d->rn--;
    *idx = i; *h = (cv_sync){ ~d->ctr, 1, d->buf[i].seq };
    uint64_t seq = d->buf[i].seq; int rn = d->rn;
    pthread_mutex_unlock(&d->mu);
    CV_TR(d, "Acquire → 缓冲 %u 句柄 %llu，环里剩 %d", i, (unsigned long long)seq, rn);
    return RES_OK;
}
static void cv_release(void *t, uint32_t i, uint64_t h0, uint64_t h1) {
    cvdec *d = cv_of(t);
    if (i >= CV_BUFS) return;
    pthread_mutex_lock(&d->mu);
    int reg = d->buf[i].reg;
    if (reg) { uint64_t hv[2] = { h0, h1 }; memcpy(&d->buf[i].fence, hv, 16); cv_queue(d, i); }
    int rn = d->rn;
    pthread_mutex_unlock(&d->mu);
    CV_TR(d, "Release 缓冲 %u 读栅栏 %#llx %#llx%s，环里 %d", i, (unsigned long long)h0, (unsigned long long)h1, reg ? "" : "（没登记，丢掉）", rn);
}
// 退登记：缓冲出两条次序（取帧环、填帧序），之后 Acquire 不再给它；没登记过的回 SDK 对重复登记同族的错
static Result cv_unregister(void *t, uint32_t i) {
    cvdec *d = cv_of(t);
    CV_TR(d, "Unregister 缓冲 %u", i);
    if (i >= CV_BUFS) { LOG("【红】Switch 2 视频：退登记缓冲 %u 越界（宿主 %d 格）", i, CV_BUFS); return RES_FAIL; }
    pthread_mutex_lock(&d->mu);
    if (!d->buf[i].reg) { pthread_mutex_unlock(&d->mu); LOG("【红】Switch 2 视频：退登记缓冲 %u，它没登记", i); return RES_FAIL; }
    d->buf[i].reg = 0; d->buf[i].filled = 0;
    int n = 0; for (int k = 0; k < d->rn; k++) { uint32_t v = d->ring[(d->rh + k) % CV_BUFS]; if (v != i) d->ring[(d->rh + n++) % CV_BUFS] = v; } d->rn = n;
    n = 0; for (int k = 0; k < d->fn; k++) { uint32_t v = d->fill[(d->fh + k) % CV_BUFS]; if (v != i) d->fill[(d->fh + n++) % CV_BUFS] = v; } d->fn = n;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    return RES_OK;
}
static Result cv_props(uint16_t *w, uint16_t *h, uint16_t *w2, uint16_t *h2, int64_t *pts, uint8_t *eos, void *t, uint32_t i) {
    cvdec *d = cv_of(t);
    if (i >= CV_BUFS) { LOG("【红】Switch 2 视频：取缓冲 %u 的帧属性，越界（宿主 %d 格）", i, CV_BUFS); return RES_FAIL; }
    pthread_mutex_lock(&d->mu);
    // SDK 也等服务的下一帧（一般已经在了）
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 1;
    uint64_t w0 = d->buf[i].reg && !d->buf[i].filled && !d->quit ? (d->props_wait_n++, now_ns()) : 0;
    while (d->buf[i].reg && !d->buf[i].filled && !d->quit) {
        DM_BLOCK_BEGIN(); int r = pthread_cond_timedwait(&d->cv, &d->mu, &dl); DM_BLOCK_END();
        if (r == ETIMEDOUT) break;
    }
    if (w0) d->props_wait_ns += now_ns() - w0;
    if (!d->buf[i].filled) { pthread_mutex_unlock(&d->mu); LOG("【红】Switch 2 视频：取缓冲 %u 的帧属性，它还没有帧", i); return CV_NOT_READY; }
    *w = *w2 = d->buf[i].fw; *h = *h2 = d->buf[i].fh; *pts = d->buf[i].pts_ns; *eos = (uint8_t)d->buf[i].eos;
    pthread_mutex_unlock(&d->mu);
    CV_TR(d, "GetProperties 缓冲 %u → %ux%u 时间 %lld ns%s", i, *w, *h, (long long)*pts, *eos ? " 流结束" : "");
    return RES_OK;
}
// SDK 19 的取输出缓冲属性（#955：大金刚新版本导入它；nxnative 同名实现，MIT）：时间前多一个 nn::movie::ColorSpace*，9 个参数、序号在第一个栈槽
//   （游戏 AAPCS64 每个栈参数占 8 字节，苹果 arm64 按自然宽度紧排：声明成 u64）。颜色空间是服务按 32 位填的值，宿主写 0（nxnative 核过一款游戏两处调用附近都不读它、
//   NV12 自己转）。没接它时：初始化走宿主、取属性走回 sdk 原路径，sdk 读它从没建过的解码器状态 → 空指针（#955 每局都在宿主接管 VP9 后一帧崩在 sdk 里）
static Result cv_props19(uint16_t *w, uint16_t *h, uint16_t *w2, uint16_t *h2, uint32_t *cs, int64_t *pts, uint8_t *eos, void *t, uint64_t i) {
    if (cs) *cs = 0;
    return cv_props(w, h, w2, h2, pts, eos, t, (uint32_t)i);
}

// SDK 入口（每种编解码一套；解码器对象 +8 是「可提交」SystemEvent）。栈上传的 32 位参数（输出格式 / 输出模式）声明成 u64：Switch 每个栈参数占 8 字节
static Result h_fini(void *t) { cv_fini(t); return RES_OK; }
static void *h_ready(uint8_t *t) { return t + 8; }
// SDK 20 旧版（金刚）：可提交事件经出参写回（同一个对象 +8 的事件），回成功；工作缓冲大小：宿主解码不用游戏给的工作缓冲（h_init_tm 不读），回 4 KB / 4 KB 对齐，游戏照常分配后交给初始化
static Result h_ready_old(void **out, uint8_t *t) { if (out) *out = t + 8; return RES_OK; }
static Result h_work_size(uint64_t *size, uint64_t *align, uint64_t a, uint32_t w, uint32_t h) { (void)a; (void)w; (void)h; if (size) *size = 0x1000; if (align) *align = 0x1000; return RES_OK; }
static void h_stop(void *t) { cv_flush(t, 1); }
static Result h_flushr(void *t) { return cv_flush(t, 0); }
#define CV_INITS(C, K) \
    static Result h_init_tm_##C(void *t, void *work, uint64_t wn, uint64_t a, uint32_t w, uint32_t h, uint32_t rate, uint32_t in, uint64_t out, uint64_t mode) { (void)work; (void)wn; (void)a; (void)rate; (void)in; (void)out; (void)mode; return cv_init(t, K, w, h); } \
    static Result h_init_rm_##C(void *t, uint64_t a, uint32_t w, uint32_t h, uint32_t rate, uint32_t in, uint32_t out, uint32_t mode) { (void)a; (void)rate; (void)in; (void)out; (void)mode; return cv_init(t, K, w, h); } \
    /* SDK 19 的按远程内存初始化（`mmttj`，nxnative 同名实现）：图像尺寸前两个大小参数，8 个都在寄存器里 */ \
    static Result h_init_mm_##C(void *t, uint64_t a, uint64_t b, uint32_t w, uint32_t h, uint32_t rate, uint32_t in, uint32_t out) { (void)a; (void)b; (void)rate; (void)in; (void)out; return cv_init(t, K, w, h); }
CV_INITS(vp9, CV_VP9)
CV_INITS(vp8, CV_VP8)
CV_INITS(av1, CV_AV1)
// H.264 的初始化多带参数集（指针、长度）在栈上，宿主不用
CV_INITS(h264, CV_H264)

static const struct { const char *n; void *f; } g_cv_names[] = {
    { "_ZN2nn5codec5video10InitializeEv", (void *)(uintptr_t)0 },
    { "_ZN2nn5codec5video8FinalizeEv", (void *)(uintptr_t)0 },
    { "_ZN2nn5codec31CalculateDecoderImagePoolBufferEPmS1_RKNS0_27VideoDecoderImagePreferenceEj", (void *)cv_pool_size },
    { "_ZN2nn5codec26InitializeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeEPvmRKNS0_27VideoDecoderImagePreferenceEj", (void *)cv_pool_init },
    { "_ZN2nn5codec24FinalizeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeE", (void *)cv_pool_fini },
    { "_ZN2nn5codec36GetDecoderImagePoolNativeImageHandleEPKNS0_25VideoDecoderImagePoolTypeEj", (void *)cv_pool_handle },
    { "_ZN2nn5codec26ReadDecoderOutputImageNv12EPKNS0_25VideoDecoderImagePoolTypeEjttttPvmmS4_mm", (void *)cv_read_nv12 },
    { "_ZN2nn5codec26ReadDecoderOutputImageRgbaEPKNS0_25VideoDecoderImagePoolTypeEjttttPvmm", (void *)cv_read_rgba },
    // PR2：HDR 布局码（10–13）的池布局本就按 8 位 RGBA 写出（cv_kind / cv_layout）→ RgbaHdr 转发 Rgba 读回（非致命回退）；float 版布局未核，保持失败
    { "_ZN2nn5codec29ReadDecoderOutputImageRgbaHdrEPKNS0_25VideoDecoderImagePoolTypeEjttttPvmm", (void *)cv_read_rgba },
    { "_ZN2nn5codec34ReadDecoderOutputImageRgbaHdrFloatEPKNS0_25VideoDecoderImagePoolTypeEjttttPvmm", (void *)cv_read_hdr },
// SDK 版本差异（11-04 金刚 SDK 20.5；火纹是 SDK 22）：旧版初始化不带输出模式（ByTransferMemory 版 = Initialize<C>Decoder(类型, 内存, 长, 长, 宽, 高, 率, 输入, 输出)，
//   ByRemoteMemory 版 = 同名去掉内存指针），图像池初始化末尾多一个 CodecMode。参数前段与新版逐位相同，多 / 少的都在末尾、宿主不读 → 接同一个实现
#define CV_SET_OLD(C, I) \
    { "_ZN2nn5codec20Initialize" C "DecoderEPNS0_14" C "DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", (void *)h_init_tm_##I }, \
    { "_ZN2nn5codec20Initialize" C "DecoderEPNS0_14" C "DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", (void *)h_init_rm_##I }, \
    { "_ZN2nn5codec33Get" C "DecoderSubmissionReadyEventEPPNS_2os15SystemEventTypeEPNS0_14" C "DecoderTypeE", (void *)h_ready_old }, \
    { "_ZN2nn5codec29Calculate" C "DecoderWorkBufferEPmS1_mtt", (void *)h_work_size },
#define CV_SET(C, I) \
    { "_ZN2nn5codec36Initialize" C "DecoderByTransferMemoryEPNS0_14" C "DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE", (void *)h_init_tm_##I }, \
    { "_ZN2nn5codec34Initialize" C "DecoderByRemoteMemoryEPNS0_14" C "DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE", (void *)h_init_rm_##I }, \
    { "_ZN2nn5codec18Finalize" C "DecoderEPNS0_14" C "DecoderTypeE", (void *)h_fini }, \
    { "_ZN2nn5codec24Register" C "DecoderBufferEPNS0_14" C "DecoderTypeEjPNS0_25VideoDecoderImagePoolTypeEj", (void *)cv_register }, \
    { "_ZN2nn5codec26Unregister" C "DecoderBufferEPNS0_14" C "DecoderTypeEj", (void *)cv_unregister }, \
    { "_ZN2nn5codec15Start" C "DecoderEPNS0_14" C "DecoderTypeE", (void *)cv_start }, \
    { "_ZN2nn5codec14Stop" C "DecoderEPNS0_14" C "DecoderTypeE", (void *)h_stop }, \
    { "_ZN2nn5codec15Flush" C "DecoderEPNS0_14" C "DecoderTypeE", (void *)h_flushr }, \
    { "_ZN2nn5codec33Get" C "DecoderSubmissionReadyEventEPNS0_14" C "DecoderTypeE", (void *)h_ready }, \
    { "_ZN2nn5codec27Submit" C "DecoderInputBufferEPmPNS0_14" C "DecoderTypeEPKvmNS_8TimeSpanEb", (void *)cv_submit }, \
    { "_ZN2nn5codec29Acquire" C "DecoderOutputBufferEPjPNS_2gs16NativeSyncHandleEPNS0_14" C "DecoderTypeE", (void *)cv_acquire }, \
    { "_ZN2nn5codec29Release" C "DecoderOutputBufferEPNS0_14" C "DecoderTypeEjNS_2gs16NativeSyncHandleE", (void *)cv_release }, \
    { "_ZN2nn5codec35Get" C "DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_8TimeSpanEPbPNS0_14" C "DecoderTypeEj", (void *)cv_props },
    CV_SET_OLD("Vp9", vp9)
    CV_SET_OLD("Vp8", vp8)
    CV_SET_OLD("Av1", av1)
    // SDK 19 的两种形式（#955；名字照游戏导入表原样抄）：初始化 `mmttj`（H.264 另带参数集在栈上，宿主不用）、取属性带 ColorSpace*
    { "_ZN2nn5codec20InitializeVp9DecoderEPNS0_14Vp9DecoderTypeEmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", (void *)h_init_mm_vp9 },
    { "_ZN2nn5codec35GetVp9DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_5movie10ColorSpaceEPNS_8TimeSpanEPbPNS0_14Vp9DecoderTypeEj", (void *)cv_props19 },
    { "_ZN2nn5codec20InitializeVp8DecoderEPNS0_14Vp8DecoderTypeEmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", (void *)h_init_mm_vp8 },
    { "_ZN2nn5codec35GetVp8DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_5movie10ColorSpaceEPNS_8TimeSpanEPbPNS0_14Vp8DecoderTypeEj", (void *)cv_props19 },
    { "_ZN2nn5codec20InitializeAv1DecoderEPNS0_14Av1DecoderTypeEmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", (void *)h_init_mm_av1 },
    { "_ZN2nn5codec35GetAv1DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_5movie10ColorSpaceEPNS_8TimeSpanEPbPNS0_14Av1DecoderTypeEj", (void *)cv_props19 },
    { "_ZN2nn5codec21InitializeH264DecoderEPNS0_15H264DecoderTypeEmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatEPKvm", (void *)h_init_mm_h264 },
    { "_ZN2nn5codec36GetH264DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_5movie10ColorSpaceEPNS_8TimeSpanEPbPNS0_15H264DecoderTypeEj", (void *)cv_props19 },
    { "_ZN2nn5codec21InitializeH264DecoderEPNS0_15H264DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatEPKvm", (void *)h_init_tm_h264 },
    { "_ZN2nn5codec21InitializeH264DecoderEPNS0_15H264DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatEPKvm", (void *)h_init_rm_h264 },
    { "_ZN2nn5codec26InitializeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeEPvmRKNS0_27VideoDecoderImagePreferenceEjNS0_9CodecModeE", (void *)cv_pool_init },
    { "_ZN2nn5codec34GetH264DecoderSubmissionReadyEventEPPNS_2os15SystemEventTypeEPNS0_15H264DecoderTypeE", (void *)h_ready_old },
    { "_ZN2nn5codec30CalculateH264DecoderWorkBufferEPmS1_mtt", (void *)h_work_size },
    // SDK 20 的 H.264 第三种初始化（带输出模式、经传输内存）：前段参数与上面同，栈上多一个模式
    { "_ZN2nn5codec21InitializeH264DecoderEPNS0_15H264DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeEPKvm", (void *)h_init_tm_h264 },
    { "_ZN2nn5codec26ReadDecoderOutputImageBgraEPKNS0_25VideoDecoderImagePoolTypeEjttttPvmm", (void *)cv_read_bgra },
    CV_SET("Vp9", vp9)
    CV_SET("Vp8", vp8)
    CV_SET("Av1", av1)
    // H.264 的名字长度多 1（类型名 H264DecoderType 15 个字符），单列
    { "_ZN2nn5codec37InitializeH264DecoderByTransferMemoryEPNS0_15H264DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeEPKvm", (void *)h_init_tm_h264 },
    { "_ZN2nn5codec35InitializeH264DecoderByRemoteMemoryEPNS0_15H264DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeEPKvm", (void *)h_init_rm_h264 },
    { "_ZN2nn5codec19FinalizeH264DecoderEPNS0_15H264DecoderTypeE", (void *)h_fini },
    { "_ZN2nn5codec25RegisterH264DecoderBufferEPNS0_15H264DecoderTypeEjPNS0_25VideoDecoderImagePoolTypeEj", (void *)cv_register },
    { "_ZN2nn5codec27UnregisterH264DecoderBufferEPNS0_15H264DecoderTypeEj", (void *)cv_unregister },
    { "_ZN2nn5codec16StartH264DecoderEPNS0_15H264DecoderTypeE", (void *)cv_start },
    { "_ZN2nn5codec15StopH264DecoderEPNS0_15H264DecoderTypeE", (void *)h_stop },
    { "_ZN2nn5codec16FlushH264DecoderEPNS0_15H264DecoderTypeE", (void *)h_flushr },
    { "_ZN2nn5codec34GetH264DecoderSubmissionReadyEventEPNS0_15H264DecoderTypeE", (void *)h_ready },
    { "_ZN2nn5codec28SubmitH264DecoderInputBufferEPmPNS0_15H264DecoderTypeEPKvmNS_8TimeSpanEb", (void *)cv_submit },
    { "_ZN2nn5codec30AcquireH264DecoderOutputBufferEPjPNS_2gs16NativeSyncHandleEPNS0_15H264DecoderTypeE", (void *)cv_acquire },
    { "_ZN2nn5codec30ReleaseH264DecoderOutputBufferEPNS0_15H264DecoderTypeEjNS_2gs16NativeSyncHandleE", (void *)cv_release },
    { "_ZN2nn5codec36GetH264DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_8TimeSpanEPbPNS0_15H264DecoderTypeEj", (void *)cv_props },
    { "_ZN2nn6syncpt3sdk20CreateSyncPointEventEPNS1_18SyncPointEventTypeE", (void *)sp_create },
    { "_ZN2nn6syncpt3sdk21DestroySyncPointEventEPNS1_18SyncPointEventTypeE", (void *)sp_destroy },
    { "_ZN2nn6syncpt3sdk21RequestSyncPointEventEPNS1_18SyncPointEventTypeERKNS1_15SyncPointHandleE", (void *)sp_request },
    { "_ZN2nn6syncpt3sdk20CancelSyncPointEventEPNS1_18SyncPointEventTypeE", (void *)sp_cancel },
    { "_ZN2nn6syncpt3sdk25InitializeMultiWaitHolderEPNS_2os19MultiWaitHolderTypeEPNS1_18SyncPointEventTypeE", (void *)sp_holder },
    { "_ZN2nn6syncpt3sdk21TryWaitSyncPointEventEPKNS1_18SyncPointEventTypeE", (void *)sp_trywait },
    { "_ZN2nn2gs17TryWaitNativeSyncERKNS0_16NativeSyncHandleE", (void *)gs_trywait },
    { "_ZN2nn2gs14WaitNativeSyncERKNS0_16NativeSyncHandleE", (void *)gs_wait },
    { "_ZN2nn2gs19TimedWaitNativeSyncERKNS0_16NativeSyncHandleENS_8TimeSpanE", (void *)gs_timedwait },
    { "_ZN2nn6syncpt3sdk13WaitSyncPointERKNS1_15SyncPointHandleE", (void *)gs_wait },
    { "_ZN2nn6syncpt3sdk16TryWaitSyncPointERKNS1_15SyncPointHandleE", (void *)gs_trywait },
    { "_ZN2nn6syncpt3sdk18TimedWaitSyncPointERKNS1_15SyncPointHandleENS_8TimeSpanE", (void *)gs_timedwait },
    { "_ZN2nn6syncpt3sdk10InitializeEv", (void *)sp_lib_init },
    { "_ZN2nn6syncpt3sdk12InitializeExEPvmNS1_14LibraryOptionsE", (void *)sp_lib_init },
    { "_ZN2nn2gs10InitializeEPvm", (void *)gs_init },
    { "_ZN2nn2gs8FinalizeEv", (void *)gs_fini },
    { "_ZN2nn2gs3sdk18BootGraphicsSystemEPvm", (void *)gs_boot },
    { "_ZN2nn2gs3sdk30CheckGraphicsSystemInitializedEPKcm", (void *)gs_check },
    { "_ZN2nn2gs3sdk27InitializeGraphicsAllocatorEPFPvmmS2_EPFvS2_S2_EPFS2_S2_mS2_ES2_", (void *)gs_alloc_init },
    { "_ZN2nn2gs3sdk20GetGraphicsAllocatorEPPFPvmmS2_EPPFvS2_S2_EPPFS2_S2_mS2_E", (void *)gs_alloc_get },
    { "_ZN2nn2gs3sdk25ShutdownGraphicsAllocatorEv", (void *)gs_alloc_shutdown },
    { "_ZN2nn2gs3sdk26SetGraphicsFrameLengthModeENS1_23GraphicsFrameLengthModeE", (void *)gs_frame_mode },
    { "_ZN2nn2gs3sdk27SetGraphicsFrameRestartModeENS1_24GraphicsFrameRestartModeE", (void *)gs_frame_knob },
    { "_ZN2nn2gs3sdk32SetGraphicsFrameGpuTimesliceModeENS1_29GraphicsFrameGpuTimesliceModeE", (void *)gs_frame_knob },
};

// ---------- NVN2 原生图像 ----------
// 游戏在栈上给的构建器（火纹 0x100 字节）
typedef struct { NVNdevice *dev; uint32_t handle; int perm; int format; } ni_builder;
// NVNnativeImage（火纹留 0x200 字节）
typedef struct { uint32_t magic, handle; int format; NVNdevice *dev; } ni_image;
#define NI_MAGIC 0x474d494eu
static void ni_set_device(ni_builder *b, NVNdevice *d) { b->dev = d; }
// 设备留着：火纹先 SetDevice 再 SetDefaults
static void ni_set_defaults(ni_builder *b) { NVNdevice *d = b->dev; memset(b, 0, sizeof *b); b->dev = d; }
static void ni_set_handle(ni_builder *b, uint32_t h) { b->handle = h; }
static void ni_set_perm(ni_builder *b, int p) { b->perm = p; }
static void ni_set_format(ni_builder *b, int f) { b->format = f; }
static NVNdevice *ni_get_device(const ni_builder *b) { return b->dev; }
static uint32_t ni_get_handle(const ni_builder *b) { return b->handle; }
static int ni_get_perm(const ni_builder *b) { return b->perm; }
static int ni_get_format(const ni_builder *b) { return b->format; }
static int ni_init(ni_image *im, const ni_builder *b) {
    cv_img ci;
    if (!cv_img_get(b->handle, &ci)) { LOG("【红】Switch 2 视频：nvnNativeImageInitialize 的原生图像句柄 %u 不是宿主发的", b->handle); return 0; }
    im->magic = NI_MAGIC; im->handle = b->handle; im->format = b->format; im->dev = b->dev;
    return 1;
}
static void ni_fini(ni_image *im) { im->magic = 0; }
static int ni_texture(NVNtexture *t, const ni_image *im) {
    cv_img ci;
    if (im->magic != NI_MAGIC || !cv_img_get(im->handle, &ci)) { LOG("【红】Switch 2 视频：nvnTextureInitializeFromNativeImage 的原生图像没初始化 / 句柄已放掉"); return 0; }
    int bw = 0, bh = 0, bpb = nvn_fmt_bpb(im->format, &bw, &bh);
    if (ci.kind == IMG_NV12 || bpb != 4 || bw != 1 || bh != 1) { LOG("【红】Switch 2 视频：原生图像 %u（%s %ux%u）按 NVN 格式 %#x 建纹理，宿主只接四字节一像素的格式", im->handle, ci.kind == IMG_NV12 ? "NV12" : "RGBA", ci.w, ci.h, im->format); return 0; }
    pthread_mutex_lock(&g_img_mu);
    int p = ci.pool, reg = 0;
    // 这块池第一次被 NVN 用：登记成后端内存池（CPU 可写、GPU 缓存），pool_t 给纹理引用
    if (p >= 0 && g_cvp[p].used && !g_cvp[p].nv_on) {
        pool_t *o = &g_cvp[p].nv; memset(o, 0, sizeof *o);
        o->magic = MAGIC('P', 'O', 'O', 'L'); o->flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED; o->mem = g_cvp[p].mem; o->size = g_cvp[p].size;
        g_cvp[p].nv_on = 1; reg = 1;
    }
    pool_t *pool = p >= 0 ? &g_cvp[p].nv : NULL;
    pthread_mutex_unlock(&g_img_mu);
    if (!pool) return 0;
    if (reg) nvn_be_pool_add(pool->mem, pool->size);
    tex_t *o = (tex_t *)t;
    memset(o, 0, sizeof *o);
    o->magic = MAGIC('T', 'E', 'X', 0);
    o->d.target = NVN_TEXTURE_TARGET_2D; o->d.format = im->format; o->d.flags = NVN_TEXTURE_FLAGS_LINEAR;
    o->d.width = ci.w; o->d.height = ci.h; o->d.depth = 1; o->d.levels = 1; o->d.stride = ci.pitch;
    o->pool = pool; o->off = ci.mem - pool->mem; o->mem = ci.mem;
    nvn_tex_layout(&o->d, &o->L);
    o->serial = nvn_new_serial(); nvn_be_tex_init(o);
    static _Atomic int said; if (atomic_fetch_add(&said, 1) < 2) LOG("Switch 2 视频：原生图像 %u → NVN 线性纹理 %ux%u 格式 %#x 行距 %u（解码图像内存零拷贝）", im->handle, ci.w, ci.h, im->format, ci.pitch);
    return 1;
}
static int ni_texture_cxx(const ni_image *im, NVNtexture *t) { return ni_texture(t, im); }   // nvn::NativeImage::InitializeTexture(this = 图像, 纹理)
static const struct { const char *n; void *f; } g_ni_names[] = {
    { "_Z30nvnNativeImageBuilderSetDeviceP21NVNnativeImageBuilderP9NVNdevice", (void *)ni_set_device },
    { "_Z32nvnNativeImageBuilderSetDefaultsP21NVNnativeImageBuilder", (void *)ni_set_defaults },
    { "_Z41nvnNativeImageBuilderSetNativeImageHandleP21NVNnativeImageBuilderN2nn2gs17NativeImageHandleE", (void *)ni_set_handle },
    { "_Z40nvnNativeImageBuilderSetMemoryPermissionP21NVNnativeImageBuilder30NVNnativeImageMemoryPermission", (void *)ni_set_perm },
    { "_Z30nvnNativeImageBuilderSetFormatP21NVNnativeImageBuilder9NVNformat", (void *)ni_set_format },
    { "_Z30nvnNativeImageBuilderGetDevicePK21NVNnativeImageBuilder", (void *)ni_get_device },
    { "_Z41nvnNativeImageBuilderGetNativeImageHandlePK21NVNnativeImageBuilder", (void *)ni_get_handle },
    { "_Z40nvnNativeImageBuilderGetMemoryPermissionPK21NVNnativeImageBuilder", (void *)ni_get_perm },
    { "_Z30nvnNativeImageBuilderGetFormatPK21NVNnativeImageBuilder", (void *)ni_get_format },
    { "_Z24nvnNativeImageInitializeP14NVNnativeImagePK21NVNnativeImageBuilder", (void *)ni_init },
    { "_Z22nvnNativeImageFinalizeP14NVNnativeImage", (void *)ni_fini },
    { "_Z35nvnTextureInitializeFromNativeImageP10NVNtextureP14NVNnativeImage", (void *)ni_texture },
    // C++ 包装（nvn::NativeImageBuilder / nvn::NativeImage 成员：this 在前，参数同 C 版；sdk 里它们尾调 sdk 自己的 C 版，不经导入表，所以也要接，火纹 sdk+0x6b0680）
    { "_ZN3nvn18NativeImageBuilder9SetDeviceEPNS_6DeviceE", (void *)ni_set_device },
    { "_ZN3nvn18NativeImageBuilder11SetDefaultsEv", (void *)ni_set_defaults },
    { "_ZN3nvn18NativeImageBuilder20SetNativeImageHandleEN2nn2gs17NativeImageHandleE", (void *)ni_set_handle },
    { "_ZN3nvn18NativeImageBuilder19SetMemoryPermissionENS_27NativeImageMemoryPermissionE", (void *)ni_set_perm },
    { "_ZN3nvn18NativeImageBuilder9SetFormatENS_6FormatE", (void *)ni_set_format },
    { "_ZNK3nvn18NativeImageBuilder9GetDeviceEv", (void *)ni_get_device },
    { "_ZNK3nvn18NativeImageBuilder20GetNativeImageHandleEv", (void *)ni_get_handle },
    { "_ZNK3nvn18NativeImageBuilder19GetMemoryPermissionEv", (void *)ni_get_perm },
    { "_ZNK3nvn18NativeImageBuilder9GetFormatEv", (void *)ni_get_format },
    { "_ZN3nvn11NativeImage10InitializeEPKNS_18NativeImageBuilderE", (void *)ni_init },
    { "_ZN3nvn11NativeImage8FinalizeEv", (void *)ni_fini },
    { "_ZN3nvn11NativeImage17InitializeTextureEPNS_7TextureE", (void *)ni_texture_cxx },
};

static Result cv_lib_ok(void) { return RES_OK; }
// 不必接管（sdk 原路径可跑；依据见 4 款 sdk 的调用图与「gs 未启动」模拟执行，03_SDK接管层_报告）：纯计算 / 格式换算 / 只读本模块常量
static int ns2_pure(const char *n) {
    static const char *const pre[] = {
        "_ZN2nn5codec25MakeDecodeImagePreference", "_ZN2nn5codec25MakeEncodeImagePreference",   // 只查表（火纹 sdk+0x330fd0）
        "_ZN2nn5codec3sdk34MakeDecodeImagePreferenceForCompat",   // SDK 19：同 MakeDecodeImagePreference、输出格式少几种（nxnative 核过 sdk+0x2c6040），布局一样，照样留给 SDK
        // 编码器里只算尺寸 / 取对象内地址的（模拟执行正常返回、调用图不达 gsv；GetH264EncoderOutputReadyEvent = 对象 + 8，火纹 sdk+0x333e80）：
        //   Pokopia subsdk0 导入它们，可能只问尺寸不真编码——做成红桩会把原本能过的路堵死
        "_ZN2nn5codec30CalculateH264EncoderWorkBuffer", "_ZN2nn5codec30GetH264EncoderOutputReadyEvent", "_ZN2nn5codec36GetEncoderImagePoolNativeImageHandle",
        "_ZN2nn6syncpt17GetLibraryVersion", "_ZN2nn6syncpt3sdk35MakeDebugSyncCounterSyncPointHandle",
        "_ZN2nn6syncpt3sdk39MakeNativeSyncHandleFromSyncPointHandle", "_ZN2nn6syncpt3sdk39MakeSyncPointHandleFromNativeSyncHandle",   // 同一 16 字节原样拷贝
        "_ZN3nvn11NativeImageC", "_ZN3nvn11NativeImageaSE",   // 复制构造 / 赋值：只拷字节
        "_ZN2nn2gs6system", "_ZN2nn2gs4impl",
    };
    for (unsigned i = 0; i < sizeof pre / sizeof *pre; i++) if (!strncmp(n, pre[i], strlen(pre[i]))) return 1;
    // nn::gs 的纯 CPU 函数：用户图像读写 / 清空、图像格式与布局计算、只读本模块常量（模拟执行正常返回，调用图不达 gs / gsv）
    static const char *const gs_cpu[] = { "InstallIpcResultCheckFor", "BlankUserImage", "ReadUserImage", "WriteUserImage", "ImageFormatEii", "CalculateNativeImage",
                                          "CanBootWithRemoteMemory", "GetAppletResourceUserId", "GetGraphicsResourceUserId" };
    if (!strncmp(n, "_ZN2nn2gs", 9)) for (unsigned i = 0; i < sizeof gs_cpu / sizeof *gs_cpu; i++) if (strstr(n, gs_cpu[i])) return 1;
    return 0;
}
// nn::codec 的视频部分（音频解码器 / AAC 编码器在 sdk 里是纯软件，照跑游戏自己的）
static int cv_video(const char *n) {
    if (strncmp(n, "_ZN2nn5codec", 12) && strncmp(n, "_ZNK2nn5codec", 13)) return 0;
    static const char *const audio[] = { "Opus", "Aac", "aac", "Audio", "Adpcm", "Celt", "Pcm", "Sbr", "sbr", "Transport", "FDK" };
    for (unsigned i = 0; i < sizeof audio / sizeof *audio; i++) if (strstr(n, audio[i])) return 0;
    static const char *const video[] = { "Video", "H264", "Hevc", "Vp8", "Vp9", "Av1", "Image", "5video", "Encoder", "NativeSync" };
    for (unsigned i = 0; i < sizeof video / sizeof *video; i++) if (strstr(n, video[i])) return 1;
    return 0;
}
// 宿主做不到的原因（红桩点名用）
static const char *ns2_why(const char *n) {
    if (cv_video(n)) {
        if (strstr(n, "Encoder") || strstr(n, "Encode")) return "视频编码器（H.264 编码经 gsv）：宿主没有视频编码";
        if (strstr(n, "Encrypted")) return "加密的视频输入（DRM）：宿主不解";
        if (strstr(n, "AliasImagePool")) return "别名图像池（别处建的原生图像）：宿主的图像池只认自己建的";
        if (strstr(n, "5video6detail") || strstr(n, "ServerContext")) return "gsv 视频服务会话（sdk 内部）：直连档不起 gsv，宿主解码不经它";
        return "视频解码接口：宿主没接这一个";
    }
    if (!strncmp(n, "_ZN2nn6syncpt", 13)) {
        if (strstr(n, "DebugSync")) return "调试同步设备 / 计数器（经 gsv）：宿主没有";
        return "SyncPointHandle / CounterId / 同步报告请求的构造与拆解（经 syncpt 库表，要 gsv 会话）：宿主计数器不按 NvRm 编号，没接";
    }
    if (strstr(n, "NativeSync") && strstr(n, "nvn")) return "NVN 同步对象（nvnSync）由 NVN 入口实现（hle_nvn.c，另一子任务）";
    if (strstr(n, "NativeWindow")) return "NVN2 驱动的原生窗口：直连上屏归宿主 NVN 窗口";
    if (strstr(n, "NvRm") || strstr(n, "8external")) return "NvRm 内存 / 栅栏：宿主没有 NVIDIA 驱动";
    if (strstr(n, "NativeMemory") || strstr(n, "VprMemory")) return "原生内存 / 受保护内存（经 gsv）：宿主没有";
    return "要 nn::gs / gsv 已启动（NVN2 驱动）：宿主没有";
}
// 装载器按名字问（runtime/src/gfxmode.c）：nn::codec 的视频部分、nn::syncpt、nn::gs、NVN2 原生图像（C 与 C++ 包装）；只在 Switch 2 进程上接。
//   规格源 = 4 款 sdk 的导出表（金刚 20.5 / raiders 21.4 / 火纹 22 / Pokopia）：这几族是句柄族（宿主发的解码器 / 图像 / 同步句柄，sdk 认不得）或依赖 gs / gsv 启动，
//   有实现的回实现；宿主做不到且有实证原路径必中止的回红桩（装载打红行，调用即中止点名）；其余回 NULL 照原路径
void *s2a_codec_entry(const char *name) {
    if (!name || !nvn2_on()) return NULL;
    for (unsigned i = 0; i < sizeof g_cv_names / sizeof *g_cv_names; i++)
        if (!strcmp(name, g_cv_names[i].n)) return g_cv_names[i].f ? g_cv_names[i].f : (void *)cv_lib_ok;
    if (!strncmp(name, OE_TARGET_RATE, sizeof OE_TARGET_RATE - 1)) return (void *)oe_target_rate;
    if (!strcmp(name, OE_TARGET_RATE_AUTO)) return (void *)oe_target_rate_auto;
    for (unsigned i = 0; i < sizeof g_ni_names / sizeof *g_ni_names; i++) if (!strcmp(name, g_ni_names[i].n)) return g_ni_names[i].f;
    int fam = cv_video(name) || !strncmp(name, "_ZN2nn6syncpt", 13) || !strncmp(name, "_ZNK2nn6syncpt", 14) || !strncmp(name, "_ZN2nn2gs", 9) || !strncmp(name, "_ZNK2nn2gs", 10)
        || (!strncmp(name, "_Z", 2) && (strstr(name, "nvnNativeImage") || strstr(name, "FromNativeImage") || strstr(name, "3nvn11NativeImage") || strstr(name, "3nvn18NativeImageBuilder")
                                        || strstr(name, "nvnSyncInitializeFromNativeSyncHandle") || strstr(name, "3nvn34InitializeSyncFromNativeSyncHandle")));
    if (!fam || ns2_pure(name)) return NULL;
    // 数据符号（EmptyNativeSyncHandle 等常量对象）不是函数：照原路径绑 sdk 的
    if (!strcmp(name, "_ZN2nn2gs21EmptyNativeSyncHandleE") || !strcmp(name, "_ZN2nn2gs24InvalidNativeImageHandleE")) return NULL;
    // 红桩只给有实证的（03 报告）：4 款 sdk 里至少一款「gs 未启动」模拟执行进了 gs Check / gsv 会话 / nv::InitCheck 且没正常返回，
    //   或经 syncpt 库表转发（表由 syncpt::sdk::Initialize 填、要 gsv 会话，直连档为空：跳空，火纹 sdk+0x5d4360 起各函数）。其余族内没接的照原路径、打红行
    static const char *const red[] = {
        "_ZN2nn2gs3sdk15CreateVprMemoryEPNS1_15VprMemoryHandleEm",
        "_ZN2nn2gs3sdk16DestroyVprMemoryENS1_15VprMemoryHandleE",
        "_ZN2nn2gs3sdk26BootNativeMemoryManagementENS_3gsv19MemoryBlockModeBitsE",
        "_ZN2nn2gs3sdk27BootGraphicsFrameManagementEv",
        "_ZN2nn2gs3sdk27QueryApplicationGpuTimeSpanEPNS_8TimeSpanEmm",
        "_ZN2nn2gs3sdk37QueryNativeMemoryNvsNvRmMemIdForDebugEPNS0_8external9NvRmMemIdEPmNS0_18NativeMemoryHandleE",
        "_ZN2nn2gs8external16WaitNvRmFenceRecERKNS1_12NvRmFenceRecE",
        "_ZN2nn2gs8external32GetNativeSyncHandleFromNvRmFenceERKNS1_12NvRmFenceRecE",
        "_ZN2nn5codec24FinalizeEncoderImagePoolEPNS0_25VideoEncoderImagePoolTypeE",
        "_ZN2nn5codec26InitializeEncoderImagePoolEPNS0_25VideoEncoderImagePoolTypeENS_5gsdrv16WeakNativeHandleEmRKNS0_27VideoEncoderImagePreferenceEj",
        "_ZN2nn5codec26InitializeEncoderImagePoolEPNS0_25VideoEncoderImagePoolTypeEPvmRKNS0_27VideoEncoderImagePreferenceEj",
        "_ZN2nn5codec26WriteEncoderInputImageNv12EPKNS0_25VideoEncoderImagePoolTypeEjPKvmmS5_mmtttt",
        "_ZN2nn5codec26WriteEncoderInputImageRgbaEPKNS0_25VideoEncoderImagePoolTypeEjPKvmmtttt",
        "_ZN2nn5codec31CalculateEncoderImagePoolBufferEPmS1_RKNS0_27VideoEncoderImagePreferenceEj",
        "_ZN2nn5codec31InitializeDecoderAliasImagePoolEPNS0_25VideoDecoderImagePoolTypeENS_2gs17NativeImageHandleEj",
        "_ZN2nn5codec31InitializeEncoderAliasImagePoolEPNS0_25VideoEncoderImagePoolTypeENS_2gs17NativeImageHandleEj",
        "_ZN2nn5codec5video6detail17ShimLibraryGlobal10InitializeEv",
        "_ZN2nn5codec5video6detail17ShimLibraryGlobal17InitializeForTestERKNS_3gsv26VideoDecoderLibraryVersionE",
        "_ZN2nn5codec5video6detail17ShimLibraryGlobal19InitializeForSystemENS2_14SystemUserNameE",
        "_ZN2nn5codec5video6detail21FinalizeServerContextEv",
        "_ZN2nn5codec5video6detail23InitializeServerContextEbRKNS_3gsv26VideoDecoderLibraryVersionE",
        "_ZN2nn5codec5video6detail32InitializeServerContextForSystemENS2_14SystemUserNameE",
        "_ZN2nn6syncpt3sdk13MakeCounterIdEj",
        "_ZN2nn6syncpt3sdk19MakeNvRmSyncPointIdENS1_13SyncCounterIdE",
        "_ZN2nn6syncpt3sdk19MakeSyncPointHandleENS1_13SyncCounterIdEmNS1_13SyncValueModeE",
        "_ZN2nn6syncpt3sdk21CreateDebugSyncDeviceEPNS1_19DebugSyncDeviceTypeE",
        "_ZN2nn6syncpt3sdk21MakeSyncReportRequestENS1_13SyncCounterIdEmNS1_13SyncValueModeE",
        "_ZN2nn6syncpt3sdk21QuerySyncCounterValueEPmPNS1_13SyncValueModeENS1_13SyncCounterIdE",
        "_ZN2nn6syncpt3sdk22CreateDebugSyncCounterEPmPNS1_20DebugSyncCounterTypeEPKNS1_19DebugSyncDeviceTypeE",
        "_ZN2nn6syncpt3sdk22ExtractSyncPointHandleEPNS1_13SyncCounterIdEPmPNS1_13SyncValueModeERKNS1_15SyncPointHandleE",
        "_ZN2nn6syncpt3sdk23DestroyDebugSyncCounterEPNS1_20DebugSyncCounterTypeE",
        "_ZN2nn6syncpt3sdk24ExtractSyncReportRequestEPNS1_13SyncCounterIdEPmPNS1_13SyncValueModeERKNS1_17SyncReportRequestE",
        "_ZN2nn6syncpt3sdk27ReportDebugSyncCounterValueEPKNS1_20DebugSyncCounterTypeEm",
        "_ZN2nn6syncpt3sdk32MakeNvRmFenceFromSyncPointHandleEPjS2_RKNS1_15SyncPointHandleE",
        "_ZN2nn6syncpt3sdk32MakeSyncPointHandleFromNvRmFenceEjj",
    };
    for (unsigned i = 0; i < sizeof red / sizeof *red; i++) if (!strcmp(name, red[i])) return nvn2_red(name, ns2_why(name));
    LOG("【红】直连：Switch 2 游戏导入 %s，宿主没接管：照原路径进 sdk（%s）", name, ns2_why(name));
    return NULL;
}
// 即时存档：视频模块的宿主表整表存取——同步计数器 / 同步点槽、活着的解码器（按原参数重建 + 缓冲记账 + 原计数器号）、解码图像表与池记录。
//   指针都是游戏地址 / 远端影子；槽里的宿主事件（hev）不存，恢复后用到时按原逻辑重建；未解完的包丢掉（到下一个关键帧画面才干净）
int nvn2_snap_codec_save(FILE *f) {
    int e = 0;
    pthread_mutex_lock(&g_sp_mu);
    e |= fwrite(g_ctr, sizeof g_ctr, 1, f) != 1;
    uint32_t s2a_snap_event_handle_of(uint64_t ev);
    for (int i = 0; i < SP_SLOTS; i++) { int r[2] = {g_slot[i].used, g_slot[i].armed}; uint32_t hh = g_slot[i].hev ? s2a_snap_event_handle_of(g_slot[i].hev) : 0;
        e |= fwrite(r, sizeof r, 1, f) != 1 || fwrite(&g_slot[i].want, sizeof g_slot[i].want, 1, f) != 1 || fwrite(g_slot[i].ev, sizeof g_slot[i].ev, 1, f) != 1 || fwrite(&hh, 4, 1, f) != 1; }
    pthread_mutex_unlock(&g_sp_mu);
    pthread_mutex_lock(&g_dec_mu); uint32_t n = 0; for (int i = 0; i < 64; i++) n += g_dec[i] != NULL;
    e |= fwrite(&n, 4, 1, f) != 1;
    for (int i = 0; i < 64; i++) if (g_dec[i]) { cvdec *d = g_dec[i]; uint64_t r[6] = {(uint64_t)(uintptr_t)d->guest, (uint64_t)d->codec, (uint64_t)d->w, (uint64_t)d->h, d->ctr, d->handed}; e |= fwrite(r, sizeof r, 1, f) != 1;
        pthread_mutex_lock(&d->mu);
        e |= fwrite(d->buf, sizeof d->buf, 1, f) != 1 || fwrite(d->ring, sizeof d->ring, 1, f) != 1 || fwrite(&d->rh, sizeof(int), 1, f) != 1 || fwrite(&d->rn, sizeof(int), 1, f) != 1
          || fwrite(d->fill, sizeof d->fill, 1, f) != 1 || fwrite(&d->fh, sizeof(int), 1, f) != 1 || fwrite(&d->fn, sizeof(int), 1, f) != 1
          || fwrite(&d->started, sizeof(int), 1, f) != 1 || fwrite(&d->gen, sizeof(int), 1, f) != 1 || fwrite(&d->last, sizeof(int), 1, f) != 1 || fwrite(&d->nsub, 8, 1, f) != 1;
        pthread_mutex_unlock(&d->mu); }
    pthread_mutex_unlock(&g_dec_mu);
    pthread_mutex_lock(&g_img_mu);
    e |= fwrite(g_img, sizeof g_img, 1, f) != 1 || fwrite(g_img_used, sizeof g_img_used, 1, f) != 1 || fwrite(&g_img_next, sizeof g_img_next, 1, f) != 1 || fwrite(g_cvp, sizeof g_cvp, 1, f) != 1;
    pthread_mutex_unlock(&g_img_mu);
    return e ? -1 : (int)n;
}
int nvn2_snap_codec_restore(FILE *f) {
    int e = 0;
    pthread_mutex_lock(&g_sp_mu);
    sp_slots_for_session_locked();   // 槽表归本局（不然第一次用就被当成上一局清掉）
    e |= fread(g_ctr, sizeof g_ctr, 1, f) != 1;
    uint64_t s2a_snap_event_of_handle(uint32_t h);
    for (int i = 0; i < SP_SLOTS && !e; i++) { int r[2]; uint32_t hh = 0;
        // 槽里的系统事件结构（游戏拿着它的指针等）照 A 原样放回，里面的读句柄是 A 的号；宿主事件对象按这个号取 B 里同号句柄背后的那个（句柄表已恢复）
        e |= fread(r, sizeof r, 1, f) != 1 || fread(&g_slot[i].want, sizeof g_slot[i].want, 1, f) != 1 || fread(g_slot[i].ev, sizeof g_slot[i].ev, 1, f) != 1 || fread(&hh, 4, 1, f) != 1;
        g_slot[i].used = r[0]; g_slot[i].armed = r[1]; g_slot[i].hev = hh ? s2a_snap_event_of_handle(hh) : 0;
        if (hh && !g_slot[i].hev) LOG("【红】即时存档恢复：视频同步点槽 %d 的事件句柄 %#x 在 B 里没有", i, hh); }
    pthread_mutex_unlock(&g_sp_mu);
    uint32_t n = 0; if (e || fread(&n, 4, 1, f) != 1) return -1;
    for (uint32_t i = 0; i < n; i++) { uint64_t r[6]; if (fread(r, sizeof r, 1, f) != 1) return -1;
        cv_init((void *)(uintptr_t)r[0], (int)r[1], (uint32_t)r[2], (uint32_t)r[3]);
        cvdec *d = cv_of((void *)(uintptr_t)r[0]);
        if (d->ctr != (uint32_t)r[4]) { sp_free(d->ctr); pthread_mutex_lock(&g_sp_mu); g_ctr[r[4]].used = 1; pthread_mutex_unlock(&g_sp_mu); d->ctr = (uint32_t)r[4]; }   // 游戏手里的同步句柄认的是 A 的计数器号
        pthread_mutex_lock(&d->mu); d->handed = r[5];
        e = fread(d->buf, sizeof d->buf, 1, f) != 1 || fread(d->ring, sizeof d->ring, 1, f) != 1 || fread(&d->rh, sizeof(int), 1, f) != 1 || fread(&d->rn, sizeof(int), 1, f) != 1
          || fread(d->fill, sizeof d->fill, 1, f) != 1 || fread(&d->fh, sizeof(int), 1, f) != 1 || fread(&d->fn, sizeof(int), 1, f) != 1
          || fread(&d->started, sizeof(int), 1, f) != 1 || fread(&d->gen, sizeof(int), 1, f) != 1 || fread(&d->last, sizeof(int), 1, f) != 1 || fread(&d->nsub, 8, 1, f) != 1;
        d->ah_h = (d->ah_h + d->ah_n) % CV_AHEAD_MAX; d->ah_n = 0; d->ah_epoch++; pthread_cond_broadcast(&d->cv);   // 先解队列是存档之后解的帧，不跟着恢复
        pthread_mutex_unlock(&d->mu); if (e) return -1; }
    pthread_mutex_lock(&g_img_mu);
    e = fread(g_img, sizeof g_img, 1, f) != 1 || fread(g_img_used, sizeof g_img_used, 1, f) != 1 || fread(&g_img_next, sizeof g_img_next, 1, f) != 1 || fread(g_cvp, sizeof g_cvp, 1, f) != 1;
    for (int i = 0; i < CV_POOLS; i++) { g_cvp[i].nv_on = 0; memset(&g_cvp[i].nv, 0, sizeof g_cvp[i].nv); }
    pthread_mutex_unlock(&g_img_mu);
    return e ? -1 : (int)n;
}

// 即时存档：同步点槽里的系统事件结构在宿主数据区、游戏拿着指向它的指针——整段登记成「交给游戏的宿主数据」，恢复时按偏移差平移游戏内存里的这类指针
void s2a_snap_handout_range(uint64_t lo, uint64_t n, const char *name) __attribute__((weak));
void nvn_snap_codec_register(int (*save)(FILE *), int (*restore)(FILE *));   // nvn_snap.inc（nvn_mtl.m）：解码器状态的存 / 读由本模块登记过去
// 单独链本文件的解码单测（t_nvn2_codec）没有快照引擎、nvn_mtl.m 与 thread.c：弱缺省 = 不登记、不换算；宿主 / iOS 壳链进真定义
__attribute__((weak)) void s2a_snap_handout_range(uint64_t lo, uint64_t n, const char *name) { (void)lo; (void)n; (void)name; }
__attribute__((weak)) void nvn_snap_codec_register(int (*save)(FILE *), int (*restore)(FILE *)) { (void)save; (void)restore; }
__attribute__((weak)) uint32_t s2a_snap_event_handle_of(uint64_t ev) { (void)ev; return 0; }
__attribute__((weak)) uint64_t s2a_snap_event_of_handle(uint32_t h) { (void)h; return 0; }
__attribute__((constructor)) static void snap_slot_range(void) { if (s2a_snap_handout_range) s2a_snap_handout_range((uint64_t)(uintptr_t)g_slot, sizeof g_slot, "nvn2_codec.sync_slots");
    nvn_snap_codec_register(nvn2_snap_codec_save, nvn2_snap_codec_restore); }

// 即时存档：本文件按整块存的宿主结构的布局指纹（snapfmt.h；不同 = 布局变了，恢复拒绝）
#include "../../../../runtime/src/snapfmt.h"
void nvn2_codec_snap_fps(snap_fp_cb cb) {
    cb("codec.ctr", SNAP_FP_OF(g_ctr[0])); cb("codec.slot", SNAP_FP_OF(g_slot[0])); cb("codec.img", SNAP_FP_OF(g_img[0])); cb("codec.cvp", SNAP_FP_OF(g_cvp[0]));
    cb("codec.cvdec", SNAP_FP_TYPE(cvdec));
}
