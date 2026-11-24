// EGL 与上屏（分片「EGL 与上屏」，#272）：一个显示、一个配置、窗口表面、上下文；交换时提交本帧并交给直连公共后端上屏（mtl_present_ext）。
// 窗口表面 = 3 张颜色贴图轮换 + 1 张深度模板，颜色贴图登记进上屏路径（mtl_ext_tex），存储按 GL 行序（第 0 行在底），上屏时翻转（nvn_be_set_origin_lower_left）
// 表面尺寸：游戏按自己 vi::CreateLayer 的尺寸画、不查询表面（数码宝贝不导入 eglQuerySurface），S2Arm 的 vi 在服务层拿不到该尺寸，
//   表面按 vi 层缺省最大 1920×1080 建；本帧 0 号帧缓冲画到的范围（视口右上角）小于表面时上屏只取这块（同 Switch 合成器只显示层内容）
// 当前上下文 / 表面按线程（EGL 1.5 §3.7.3）：eglMakeCurrent 只绑调用线程，别的线程各绑各的；共享组的对象（缓冲 / 纹理 / 程序等）本层名字表本来就全进程一张，
//   共享上下文因此天然共享（不共享的上下文也落在同一张表里：名字不撞、游戏不靠撞名，只是比规范宽）。删除仍被某线程绑着的上下文 / 表面按规范推迟到最后一个线程松开才真放。
//   11-02 火影忍者 终极风暴羁绊：另一线程 eglCreateContext(share) + 无表面 eglMakeCurrent，原先全进程一个当前上下文，把渲染线程的上下文换成新上下文
//   （帧缓冲绑定 0、无表面），渲染线程下一笔清除落到 0 号帧缓冲报「没有绘制表面」+ 0x502，随后游戏客体代码读空指针崩
#include "gl_int.h"
#include "../nvn/nvn_fps.h"
#include <math.h>
#include <pthread.h>
#include <time.h>
const char gl_slice_egl = 1;   // 分片锚（gl_core.m 引用：静态链接时整片进来，见 gl_int.h「分片锚」）

enum { EGL_SUCCESS = 0x3000, EGL_NOT_INITIALIZED = 0x3001, EGL_BAD_ACCESS = 0x3002,
    EGL_BAD_ALLOC = 0x3003, EGL_BAD_ATTRIBUTE = 0x3004, EGL_BAD_CONFIG = 0x3005,
    EGL_BAD_CONTEXT = 0x3006, EGL_BAD_DISPLAY = 0x3008, EGL_BAD_MATCH = 0x3009,
    EGL_BAD_PARAMETER = 0x300C, EGL_BAD_SURFACE = 0x300D, EGL_NONE = 0x3038,
    EGL_HEIGHT = 0x3056, EGL_WIDTH = 0x3057, EGL_OPENGL_ES_API = 0x30A0, EGL_OPENGL_API = 0x30A2,
    EGL_PBUFFER_LIMIT = 16384 };
int nvn_be_fps_target(void); int nvn_be_link_active(void); int nvn_be_link_wait_tick(int vsyncs, uint64_t timeout_ns);   // nvn_mtl.m
void s2a_sleep_ns(int64_t ns);   // runtime/src/thread.c：按时睡
void dm_guest_frame_tick(void); double nvn_be_presented_time(uint64_t n); void dm_perf_present(double iv_ms);

#define NSURF 3
typedef struct surface_t { uint32_t seq, w, h, cur, interval, ext_w, ext_h, wid[NSURF], did; __strong id<MTLTexture> col[NSURF], depth; uint64_t serial[NSURF], ticket[NSURF]; double next_swap; int bound, dead, pbuffer, largest; struct surface_t *next; } surface_t;   // seq：建立序号（即时存档按它认，见文件尾）；next_swap：下一拍（单调钟秒）；wid / did：宽屏核心贴图号（宽屏关 = 0）；w / h 是游戏看到的尺寸，贴图可能被放宽
typedef struct context_t { gl_state st; int bound, dead; uint32_t seq; struct context_t *next; } context_t;   // seq：建立序号（即时存档按它认）；bound：绑着它的线程数；dead：已 eglDestroy*、等最后一个线程松开再放
static __thread surface_t *g_draw;     // 本线程的当前绘制表面（MakeCurrent；无表面上下文 = NULL）
static surface_t *g_surfaces;
static context_t *g_contexts;
static pthread_mutex_t g_egl_mu = PTHREAD_MUTEX_INITIALIZER;   // 护表面 / 上下文链表与 bound / dead（多线程各自建上下文、MakeCurrent）
// 游戏自己要的帧率（开发浮层取，runtime/src/hud.c hud_target）：每次交换按交换间隔折算，0 = 交换间隔 0（游戏不锁垂直同步，只受 S2A_FPS 上限）；-1 = 还没交换过（本局不是 GL 款）
static int g_gl_game_fps = -1;
static uint32_t g_seq_surf, g_seq_ctx;   // 表面 / 上下文的建立序号（持 g_egl_mu）
static void snap_ho(const void *p, const char *fmt, ...);   // 文件尾：交给游戏的句柄按身份登记（即时存档）
static void snap_tb_note(void);
int nvn_gl_game_fps(void) { return __atomic_load_n(&g_gl_game_fps, __ATOMIC_RELAXED); }
// 只读计数（单测按事件判、不量墙钟，t_fps_limit）：交换锁自己时钟这一支（没有显示链接）的限帧决定。
//   [0] 排过节拍的交换次数 [1] 最近一次的节拍周期（ns） [2] 帧比周期长、截止时刻多跨过的刻度累计 [3] 真睡了的次数 [4] 单次要睡的最长时长（ns）。只增不减（[1][4] 记最近 / 最大），不改行为
static uint64_t g_gl_pace[5];
void s2a_gl_pace_stats(uint64_t out[5]) { for (int i = 0; i < 5; i++) out[i] = __atomic_load_n(&g_gl_pace[i], __ATOMIC_RELAXED); }
static __thread EGLenum g_api = EGL_OPENGL_ES_API;   // 当前 API 与错误码都按线程（EGL 1.5 §3.1 / §3.7）
static __thread EGLint g_err = EGL_SUCCESS;
static _Atomic int g_initialized;
static int display_ready(EGLDisplay d) {
    if (d != (EGLDisplay)1) { g_err = EGL_BAD_DISPLAY; return 0; }
    if (!atomic_load(&g_initialized)) { g_err = EGL_NOT_INITIALIZED; return 0; }
    return 1;
}
// Single actual configuration: RGBA8 + Metal Depth32Float_Stencil8, no MSAA,
// native drawing, pixmaps or EGL texture binding. No conformance claim.
static int config_value(EGLint attr, EGLint *v) {
    switch (attr) {
    case 0x3020: *v = 32; break; // EGL_BUFFER_SIZE
    case 0x3021: case 0x3022: case 0x3023: case 0x3024: *v = 8; break;
    case 0x3025: *v = 32; break; // EGL_DEPTH_SIZE matches actual storage.
    case 0x3026: *v = 8; break;
    case 0x3027: *v = 0x3051; break; // EGL_NON_CONFORMANT_CONFIG
    case 0x3028: *v = 1; break;
    case 0x302A: case 0x302C: *v = EGL_PBUFFER_LIMIT; break;
    case 0x302B: *v = EGL_PBUFFER_LIMIT * EGL_PBUFFER_LIMIT; break;
    case 0x3033: *v = 0x0001 | 0x0004; break; // EGL_PBUFFER_BIT | EGL_WINDOW_BIT
    case 0x3034: *v = EGL_NONE; break; // No transparent pixel matching.
    case 0x303C: *v = INT32_MAX; break; // Existing window interval accepts every nonnegative EGLint.
    case 0x303F: *v = 0x308E; break; // EGL_RGB_BUFFER
    case 0x3040: *v = 0x0004 | 0x0008 | 0x0040; break; // ES2 / OpenGL / ES3; no ES1 fixed pipeline.
    case 0x3029: case 0x302D: case 0x302E: case 0x302F: case 0x3031: case 0x3032:
    case 0x3035: case 0x3036: case 0x3037: case 0x3039: case 0x303A: case 0x303B:
    case 0x303D: case 0x303E: case 0x3042: *v = 0; break;
    default: return 0;
    }
    return 1;
}

id<MTLTexture> gl_surface_color(void) { return g_draw ? g_draw->col[g_draw->cur] : nil; }
void gl_surface_game(uint32_t *w, uint32_t *h) { *w = g_draw ? g_draw->w : 0; *h = g_draw ? g_draw->h : 0; }   // 游戏看到的表面尺寸（eglQuerySurface）；贴图可能按宽屏放宽
id<MTLTexture> gl_surface_depth(void) { return g_draw ? g_draw->depth : nil; }
// 前缓冲 = 上一次交换交给上屏的那张（3 张轮换，交换后 cur 前移一张）；还没交换过没有前缓冲内容
id<MTLTexture> gl_surface_front(void) { return g_draw && g_draw->ticket[(g_draw->cur + NSURF - 1) % NSURF] ? g_draw->col[(g_draw->cur + NSURF - 1) % NSURF] : nil; }
void gl_surface_wid(uint32_t *color, uint32_t *depth) { *color = g_draw ? g_draw->wid[g_draw->cur] : 0; *depth = g_draw ? g_draw->did : 0; }
void gl_surface_extent(GLint x1, GLint y1) {
    if (!g_draw) return;
    uint32_t x = x1 < 0 ? 0 : (uint32_t)x1 > g_draw->w ? g_draw->w : (uint32_t)x1, y = y1 < 0 ? 0 : (uint32_t)y1 > g_draw->h ? g_draw->h : (uint32_t)y1;
    if (x > g_draw->ext_w) g_draw->ext_w = x; if (y > g_draw->ext_h) g_draw->ext_h = y;
}

__attribute__((weak)) void s2a_gl_first_use(void) {}   // graphics/nvn/host_adapt.m：定着色器库路径、起直连异常看门（单测不链宿主，用这个空的）
GLB(eglGetDisplay, EGLDisplay, void *native) { @autoreleasepool { (void)native; s2a_gl_first_use(); return (EGLDisplay)1; }}   // 游戏进 GL 的第一个调用；写日志 / 建目录，走宿主栈
GL(eglInitialize, EGLBoolean, EGLDisplay d, EGLint *major, EGLint *minor) { if (d != (EGLDisplay)1) { g_err = EGL_BAD_DISPLAY; return 0; } atomic_store(&g_initialized, 1); if (major) *major = 1; if (minor) *minor = 5; return 1; }
GL(eglTerminate, EGLBoolean, EGLDisplay d) { if (d != (EGLDisplay)1) { g_err = EGL_BAD_DISPLAY; return 0; } atomic_store(&g_initialized, 0); return 1; }
GL(eglGetError, EGLint, void) { EGLint e = g_err; g_err = EGL_SUCCESS; return e; }
GL(eglBindAPI, EGLBoolean, EGLenum api) {
    if (api != EGL_OPENGL_ES_API && api != EGL_OPENGL_API) { g_err = EGL_BAD_PARAMETER; return 0; }
    g_api = api; snap_tb_note(); return 1;
}
GL(eglQueryAPI, EGLenum, void) { return g_api; }
GL(eglQueryString, const char *, EGLDisplay d, EGLint name) {
    // EGL 1.5 §3.3 permits client version/extensions without a display.
    if (!d && (name == 0x3054 || name == 0x3055)) return name == 0x3054 ? "1.5 S2Arm" : "";
    if (!display_ready(d)) return NULL;
    switch (name) {
    case 0x3053: return "S2Arm";
    case 0x3054: return "1.5 S2Arm";
    case 0x3055: return "EGL_KHR_create_context"; // 上下文属性（eglCreateContext 认的那几个）；同步等别的扩展没实现，不报
    case 0x308D: return "OpenGL OpenGL_ES";
    default: g_err = EGL_BAD_PARAMETER; return NULL;
    }
}
GL(eglGetConfigAttrib, EGLBoolean, EGLDisplay d, EGLConfig c, EGLint attr, EGLint *v) {
    if (!display_ready(d)) return 0;
    if (c != (EGLConfig)1) { g_err = EGL_BAD_CONFIG; return 0; }
    if (!v) { g_err = EGL_BAD_PARAMETER; return 0; }
    if (!config_value(attr, v)) { g_err = EGL_BAD_ATTRIBUTE; return 0; }
    return 1;
}
// 只有一个配置；配置的查询值以 config_value 为准。
GL(eglChooseConfig, EGLBoolean, EGLDisplay d, const EGLint *attrib, EGLConfig *cfg, EGLint size, EGLint *num) {
    (void)d; (void)attrib; if (num) *num = 1; if (cfg && size > 0) cfg[0] = (EGLConfig)1; return 1;
}
GL(eglGetConfigs, EGLBoolean, EGLDisplay d, EGLConfig *cfg, EGLint size, EGLint *num) { (void)d; if (num) *num = 1; if (cfg && size > 0) cfg[0] = (EGLConfig)1; return 1; }
// 窗口表面的颜色轮换贴图与深度（建表面、即时存档恢复都走这里）
static void surface_window_build(surface_t *s) {
    // 宽屏（gl_widen.inc）：表面贴图建的时候就知道是渲染目标，按核心给的宽建；游戏看到的仍是 s->w × s->h（关时一样宽）
    int wd = gl_wd_on() > 0; uint32_t tw = s->w, th = s->h;   // 窄屏加高：表面高按核心给的高（gl_widen.inc gl_wd_rt）
    @autoreleasepool {
        for (int i = 0; i < NSURF; i++) {
            if (wd) { s->wid[i] = gl_wd_new_id(); tw = gl_wd_rt(s->wid[i], s->w, s->h, &th); }
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:tw height:th mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
            s->col[i] = [gl_dev newTextureWithDescriptor:td]; s->serial[i] = mtl_ext_tex((__bridge void *)s->col[i]);
        }
        if (wd) { s->did = gl_wd_new_id(); tw = gl_wd_rt(s->did, s->w, s->h, &th); }
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:tw height:th mipmapped:NO];
        dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate; s->depth = [gl_dev newTextureWithDescriptor:dd];
    }
    nvn_be_set_origin_lower_left(1);   // 存储按 GL 行序：上屏翻转
    GLOG("窗口表面 %ux%u，%d 张颜色贴图轮换%s", s->w, s->h, NSURF, tw != s->w || th != s->h ? [NSString stringWithFormat:@"（宽屏放宽到 %ux%u）", tw, th].UTF8String : "");
}
GLB(eglCreateWindowSurface, EGLSurface, EGLDisplay d, EGLConfig c, EGLNativeWindowType win, const EGLint *attrib) { @autoreleasepool {
    (void)d; (void)c; (void)win; (void)attrib; gl_dev_init();
    surface_t *s = calloc(1, sizeof *s); if (!s) die("[gl] 表面分配失败");
    pthread_mutex_lock(&g_egl_mu); s->seq = ++g_seq_surf; s->next = g_surfaces; g_surfaces = s; pthread_mutex_unlock(&g_egl_mu);
    s->w = 1920; s->h = 1080; s->interval = 1;
    surface_window_build(s);
    snap_ho(s, "gl:surf:%u", s->seq);
    return s;
}}
static void surface_unlink(surface_t *s) {   // 持 g_egl_mu
    surface_t **slot = &g_surfaces; while (*slot && *slot != s) slot = &(*slot)->next;
    if (*slot) *slot = s->next;
}
static void surface_free(surface_t *s, int wait) {   // 已摘链、没有线程绑着
    for (int i = 0; i < NSURF; i++) {
        if (wait && s->ticket[i]) nvn_be_present_wait(s->ticket[i]);
        s->col[i] = nil; gl_wd_release_id(s->wid[i]);
    }
    gl_wd_release_id(s->did); s->depth = nil;
    free(s);
}
// 离屏表面的颜色 / 深度（建表面、即时存档恢复都走这里）：largest 时放不下就逐次减半；0 = 分配失败
//   Pbuffers have no present registration, widening IDs or swapchain. A legal
//   zero-sized surface keeps minimal Metal backing while exposing size zero.
static int surface_pbuffer_build(surface_t *s) {
    for (;;) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:MAX(s->w, 1u) height:MAX(s->h, 1u) mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
        s->col[0] = [gl_dev newTextureWithDescriptor:td];
        td.pixelFormat = MTLPixelFormatDepth32Float_Stencil8; td.usage = MTLTextureUsageRenderTarget;
        s->depth = [gl_dev newTextureWithDescriptor:td];
        if (s->col[0] && s->depth) return 1;
        s->col[0] = nil; s->depth = nil;
        if (!s->largest || (s->w <= 1 && s->h <= 1)) return 0;
        if (s->w >= s->h && s->w > 1) s->w /= 2; else s->h /= 2;
    }
}
GLB(eglCreatePbufferSurface, EGLSurface, EGLDisplay d, EGLConfig c, const EGLint *attrib) { @autoreleasepool {
    if (!display_ready(d)) return NULL;
    if (c != (EGLConfig)1) { g_err = EGL_BAD_CONFIG; return NULL; }
    EGLint w = 0, h = 0, largest = 0, format = 0x305C, target = 0x305C;
    if (attrib) for (const EGLint *a = attrib; a[0] != EGL_NONE; a += 2) {
        switch (a[0]) {
        case EGL_WIDTH: w = a[1]; break;
        case EGL_HEIGHT: h = a[1]; break;
        case 0x3058: if (a[1] != 0 && a[1] != 1) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } largest = a[1]; break;
        case 0x3080: if (a[1] < 0x305C || a[1] > 0x305E) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } format = a[1]; break;
        case 0x3081: if (a[1] != 0x305C && a[1] != 0x305F) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } target = a[1]; break;
        case 0x3082: if (a[1] != 0 && a[1] != 1) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } break; // No texture: mipmap attribute has no effect.
        case 0x309D: if (a[1] != 0x308A) { g_err = EGL_BAD_MATCH; return NULL; } break; // EGL_GL_COLORSPACE_LINEAR
        default: g_err = EGL_BAD_ATTRIBUTE; return NULL;
        }
    }
    if (w < 0 || h < 0) { g_err = EGL_BAD_PARAMETER; return NULL; }
    // EGL_BIND_TO_TEXTURE_RGB/RGBA are false: never return a fake texture-backed pbuffer.
    if (format != 0x305C || target != 0x305C) { g_err = EGL_BAD_MATCH; return NULL; }
    if ((w > EGL_PBUFFER_LIMIT || h > EGL_PBUFFER_LIMIT) && !largest) { g_err = EGL_BAD_ALLOC; return NULL; }
    if (w > EGL_PBUFFER_LIMIT) w = EGL_PBUFFER_LIMIT;
    if (h > EGL_PBUFFER_LIMIT) h = EGL_PBUFFER_LIMIT;
    surface_t *s = calloc(1, sizeof *s); if (!s) { g_err = EGL_BAD_ALLOC; return NULL; }
    s->pbuffer = 1; s->largest = largest; s->w = (uint32_t)w; s->h = (uint32_t)h;
    gl_dev_init();
    if (!surface_pbuffer_build(s)) { surface_free(s, 0); g_err = EGL_BAD_ALLOC; return NULL; }
    pthread_mutex_lock(&g_egl_mu); s->seq = ++g_seq_surf; s->next = g_surfaces; g_surfaces = s; pthread_mutex_unlock(&g_egl_mu);
    snap_ho(s, "gl:surf:%u", s->seq);
    return s;
}}
GLB(eglDestroySurface, EGLBoolean, EGLDisplay d, EGLSurface sf) { @autoreleasepool {
    (void)d; surface_t *s = sf; if (!s) { g_err = EGL_BAD_SURFACE; return 0; }
    pthread_mutex_lock(&g_egl_mu);
    if (s->dead) { pthread_mutex_unlock(&g_egl_mu); g_err = EGL_BAD_SURFACE; return 0; }
    s->dead = 1; int now = !s->bound; if (now) surface_unlink(s);   // 还被某线程绑着：规范是松开时才放（EGL 1.5 §3.5.6）
    pthread_mutex_unlock(&g_egl_mu);
    if (now) surface_free(s, 1);
    return 1;
}}
GL(eglQuerySurface, EGLBoolean, EGLDisplay d, EGLSurface sf, EGLint attr, EGLint *v) {
    (void)d; surface_t *s = sf; if (!s) { g_err = EGL_BAD_SURFACE; return 0; }
    if (!v) { g_err = EGL_BAD_PARAMETER; return 0; }
    if (attr == EGL_WIDTH) *v = (EGLint)s->w; else if (attr == EGL_HEIGHT) *v = (EGLint)s->h;
    else if (s->pbuffer && attr == 0x3058) *v = s->largest;
    else if (s->pbuffer && (attr == 0x3080 || attr == 0x3081)) *v = 0x305C; // EGL_NO_TEXTURE
    else if (s->pbuffer && (attr == 0x3082 || attr == 0x3083)) *v = 0;
    else { g_err = EGL_BAD_ATTRIBUTE; return 0; }
    return 1;
}
GL(eglCreateContext, EGLContext, EGLDisplay d, EGLConfig c, EGLContext share, const EGLint *attrib) {
    (void)d; (void)c;
    // 上下文属性（EGL 1.5 §3.7.1 / EGL_KHR_create_context）：每个上下文都是同一份实现（ES 3.2 / 桌面 4.5，同 eglQueryContext 0x3098），
    //   版本要求不超出就建、超出回 EGL_BAD_MATCH；标志 / 配置档 / 重置策略只是提示，认得就接受；认不出的属性回 EGL_BAD_ATTRIBUTE。
    //   #2057 王国保卫战：复仇：SDL 要 ES 3 上下文时先查显示的扩展名，没有 EGL_KHR_create_context 就报「context attributes are not supported」、不建上下文，游戏随即崩在开局
    EGLint maj = 1, min = 0;
    for (const EGLint *a = attrib; a && a[0] != EGL_NONE; a += 2) switch (a[0]) {
        case 0x3098: maj = a[1]; break;   // EGL_CONTEXT_MAJOR_VERSION（= EGL_CONTEXT_CLIENT_VERSION）
        case 0x30FB: min = a[1]; break;   // EGL_CONTEXT_MINOR_VERSION
        case 0x30FC: if (a[1] & ~7) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } break;   // EGL_CONTEXT_FLAGS_KHR：调试 1 / 向前兼容 2 / 鲁棒访问 4
        case 0x30FD: if (g_api == EGL_OPENGL_API && (!a[1] || (a[1] & ~3))) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } break;   // 配置档：核心 1 / 兼容 2，ES 上下文忽略（KHR 规定）
        case 0x31B0: case 0x31B1: case 0x31B2: if (a[1] != 0 && a[1] != 1) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } break;   // EGL 1.5 调试 / 向前兼容 / 鲁棒访问（布尔）
        case 0x31BD: if (a[1] != 0x31BE && a[1] != 0x31BF) { g_err = EGL_BAD_ATTRIBUTE; return NULL; } break;   // 重置通知策略：不通知 / 丢上下文
        default: g_err = EGL_BAD_ATTRIBUTE; return NULL;
    }
    if (g_api == EGL_OPENGL_ES_API ? maj > 3 || (maj == 3 && min > 2) : maj > 4 || (maj == 4 && min > 5)) { g_err = EGL_BAD_MATCH; return NULL; }
    if (share && ((context_t *)share)->dead) { g_err = EGL_BAD_CONTEXT; return NULL; }   // 共享组：对象名字表全进程一张（文件头），无须另建
    context_t *x = calloc(1, sizeof *x); if (!x) die("[gl] 上下文分配失败");
    x->st.api = g_api; x->st.depth_mask = 1; x->st.default_draw[0] = 0x0405; /* GL_BACK */
    for (int i = 0; i < GL_COLOR_TARGETS; i++) {
        gl_color_state *color = &x->st.color[i];
        for (int k = 0; k < 4; k++) color->mask[k] = 1;
        color->eq[0] = color->eq[1] = 0x8006; /* GL_FUNC_ADD */
        color->factor[0] = color->factor[2] = 1; /* GL_ONE；目标因子与常量色初值为 0 */
    }
    x->st.stencil_wmask[0] = x->st.stencil_wmask[1] = ~0u;
    for (int i = 0; i < 2; i++) { x->st.stencil_func[i] = 0x0207; /* GL_ALWAYS */ x->st.stencil_mask[i] = ~0u; x->st.stencil_op[i][0] = x->st.stencil_op[i][1] = x->st.stencil_op[i][2] = 0x1E00; /* GL_KEEP */ }
    x->st.depth_range[1] = 1; x->st.clear_depth = 1; x->st.depth_func = 0x0201; /* GL_LESS */ x->st.cull = 0x0405; /* GL_BACK */ x->st.front = 0x0901; /* GL_CCW */
    x->st.unpack_align = 4; x->st.unpack_row = 0; x->st.pack_align = 4; x->st.line_width = 1; x->st.point_size = 1; // #272：每个上下文独立的 GL 初始像素存储。
    x->st.default_read = 0x0405; /* GL_BACK */ x->st.poly_mode = 0x1B02; /* GL_FILL */
    for (int i = 0; i < 16; i++) x->st.attr_cur[i][3] = 1;   // 当前通用顶点属性初值 (0, 0, 0, 1)
    x->st.dirty = ~0u;
    pthread_mutex_lock(&g_egl_mu); x->seq = ++g_seq_ctx; x->next = g_contexts; g_contexts = x; pthread_mutex_unlock(&g_egl_mu);
    snap_ho(x, "gl:ctx:%u", x->seq);
    return x;
}
static void context_unlink(context_t *c) {   // 持 g_egl_mu
    context_t **slot = &g_contexts; while (*slot && *slot != c) slot = &(*slot)->next;
    if (*slot) *slot = c->next;
}
static void context_free(context_t *c) { gl_tex_context_drop(&c->st); free(c); }   // 已摘链、没有线程绑着；宿主栈
static context_t *cur_context(void) { return gl_cur ? (context_t *)((uint8_t *)gl_cur - offsetof(context_t, st)) : NULL; }
GLB(eglDestroyContext, EGLBoolean, EGLDisplay d, EGLContext c) { @autoreleasepool {
    (void)d; context_t *x = c; if (!x) { g_err = EGL_BAD_CONTEXT; return 0; }
    pthread_mutex_lock(&g_egl_mu);
    if (x->dead) { pthread_mutex_unlock(&g_egl_mu); g_err = EGL_BAD_CONTEXT; return 0; }
    x->dead = 1; int now = !x->bound; if (now) context_unlink(x);   // 还是某线程的当前上下文：照常可用，松开时才放（EGL 1.5 §3.7.2）
    pthread_mutex_unlock(&g_egl_mu);
    if (now) context_free(x);
    return 1;
}}
void gl_egl_session_reset(void) {
    // The shared present backend is already drained; its texture registry is
    // cleared by the common graphics shutdown after these references are dropped.
    // 客体线程都已退出：不管还绑着与否全部放掉（调用线程自己的绑定也清）
    while (g_surfaces) { surface_t *s = g_surfaces; g_surfaces = s->next; surface_free(s, 0); }
    while (g_contexts) { context_t *c = g_contexts; g_contexts = c->next; context_free(c); }
    g_draw = NULL; gl_cur = NULL; g_api = EGL_OPENGL_ES_API; g_err = EGL_SUCCESS;
    atomic_store(&g_initialized, 0);
    g_gl_game_fps = -1;
}
// 换绑本线程：新的先记绑定、旧的松开；松开后没人绑、又已删的当场放（宿主栈：放贴图 / 等上屏）
static void bind_current(surface_t *draw, context_t *c) {
    surface_t *os = g_draw; context_t *oc = cur_context(), *fc = NULL; surface_t *fs = NULL;
    pthread_mutex_lock(&g_egl_mu);
    if (c) c->bound++; if (draw) draw->bound++;
    if (oc && !--oc->bound && oc->dead) { context_unlink(oc); fc = oc; }
    if (os && !--os->bound && os->dead) { surface_unlink(os); fs = os; }
    pthread_mutex_unlock(&g_egl_mu);
    g_draw = draw; gl_cur = c ? &c->st : NULL;
    snap_tb_note();
    if (fc) context_free(fc);
    if (fs) surface_free(fs, 1);
}
// draw = NULL 且 c 非空：无表面上下文（EGL_KHR_surfaceless_context，游戏只画自己的帧缓冲对象；0 号帧缓冲不存在）
GLB(eglMakeCurrent, EGLBoolean, EGLDisplay d, EGLSurface draw, EGLSurface read, EGLContext c) { @autoreleasepool {
    (void)d; if (read != draw) { g_err = EGL_BAD_MATCH; return 0; }
    context_t *x = c; surface_t *s = draw;
    if (x && x != cur_context() && x->dead) { g_err = EGL_BAD_CONTEXT; return 0; }   // 已删的上下文不能新绑（还绑着的线程照用）
    if (s && s != g_draw && s->dead) { g_err = EGL_BAD_SURFACE; return 0; }
    bind_current(s, x);
    if (gl_cur && g_draw && !gl_cur->vp[2]) { gl_cur->vp[2] = gl_cur->sc[2] = (GLint)g_draw->w; gl_cur->vp[3] = gl_cur->sc[3] = (GLint)g_draw->h; }   // 第一次绑表面：视口 / 裁剪 = 整个表面（规范）
    return 1;
}}
GL(eglGetCurrentContext, EGLContext, void) { return cur_context(); }
// 当前显示 / 表面 / 上下文属性（EGL 1.5 §3.7.4 / §3.7.3；#1440 一款 GL 游戏开局就问，没实现时装载期未解析、一调即退）：
//   只有一个显示（eglGetDisplay 回 1）、读写表面恒同一个（eglMakeCurrent 要求 read == draw）、一个配置（号 1）
GL(eglGetCurrentDisplay, EGLDisplay, void) { return cur_context() ? (EGLDisplay)1 : NULL; }   // 没有当前上下文：EGL_NO_DISPLAY
GL(eglGetCurrentSurface, EGLSurface, EGLint readdraw) {
    if (readdraw != 0x3059 && readdraw != 0x305A) { g_err = EGL_BAD_PARAMETER; return NULL; }   // EGL_DRAW / EGL_READ
    return cur_context() ? g_draw : NULL;   // 无表面上下文或没有当前上下文：EGL_NO_SURFACE
}
GL(eglQueryContext, EGLBoolean, EGLDisplay d, EGLContext c, EGLint attr, EGLint *v) {
    if (!display_ready(d)) return 0;
    context_t *x = c; if (!x || x->dead) { g_err = EGL_BAD_CONTEXT; return 0; }
    if (!v) { g_err = EGL_BAD_PARAMETER; return 0; }
    switch (attr) {
    case 0x3028: *v = 1; break;                                            // EGL_CONFIG_ID：唯一的配置
    case 0x3097: *v = (EGLint)x->st.api; break;                            // EGL_CONTEXT_CLIENT_TYPE
    case 0x3098: *v = x->st.api == EGL_OPENGL_ES_API ? 3 : 4; break;      // EGL_CONTEXT_CLIENT_VERSION（= MAJOR_VERSION）：同 GL_MAJOR_VERSION（ES 3.2 / 桌面 4.5）
    case 0x3086: *v = x == cur_context() && g_draw ? 0x3084 : 0x3038; break;   // EGL_RENDER_BUFFER：绑着表面是后缓冲，否则 EGL_NONE
    default: g_err = EGL_BAD_ATTRIBUTE; return 0;
    }
    return 1;
}
GLB(eglWaitGL, EGLBoolean, void) { @autoreleasepool {
    // EGL 1.5 §3.8: waits the ES context, regardless of the currently bound API.
    // OpenGL and ES share the one current GL context slot in this frontend.
    if (!gl_cur || gl_cur->api != EGL_OPENGL_ES_API) return 1;
    if (gl_session_stopping()) { g_err = EGL_BAD_ACCESS; return 0; }
    uint64_t v = gl_commit(); gl_wait(v);
    if (gl_session_stopping() || gl_ev.signaledValue < v) { g_err = EGL_BAD_ACCESS; return 0; }
    return 1;
}}
GL(eglWaitNative, EGLBoolean, EGLint engine) {
    if (engine != 0x305B) { g_err = EGL_BAD_PARAMETER; return 0; } // EGL_CORE_NATIVE_ENGINE
    // No supported surface shares its color storage with native rendering.
    // The specified no-op (including without a current context), not a GPU wait.
    return 1;
}
GL(eglSwapInterval, EGLBoolean, EGLDisplay d, EGLint n) { (void)d; if (g_draw) g_draw->interval = n < 0 ? 0 : (uint32_t)n; return 1; }
// S2Arm 标称帧率（host_adapt.m 在 dm_guest_frame_tick 里取，即 eglSwapBuffers 的线程）：出图实际跟的节拍 = 目标帧率 / 交换间隔（间隔 0 = 不等垂直同步，上屏仍按目标帧率的最短显示时长）；
//   还没有表面交换过回 0（这局不是 GL 款）
int gl_present_fps(void) { return g_draw && atomic_load(&gl_n_frames) ? nvn_be_fps_target() / (int)(g_draw->interval ? g_draw->interval : 1) : 0; }
// 交换：提交本帧（本层共享事件到 v），交给公共后端在 v 之后上屏；轮到下一张颜色贴图，等它上一次上屏交出去后才往里画
GLB(eglSwapBuffers, EGLBoolean, EGLDisplay d, EGLSurface sf) { @autoreleasepool {
    if (gl_session_stopping()) return 0;
    (void)d; surface_t *s = sf; if (!s) { g_err = EGL_BAD_SURFACE; return 0; }
    if (s->pbuffer) {
        if (!gl_cur || g_draw != s) { g_err = EGL_BAD_SURFACE; return 0; }
        gl_commit(); // EGL §3.10.3 implicit flush; no presentation, rotation or pacing.
        return 1;
    }
    dm_gfx_enter(); uint64_t t_in = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t v = gl_commit();
    // 存储按 GL 行序：GL 的左下 (0,0) 起 ext_w × ext_h 就是贴图第 0 行起的这块（上屏再翻转）
    int crop[4] = {0, 0, (int)s->ext_w, (int)s->ext_h}, part = s->ext_w && s->ext_h && (s->ext_w < s->w || s->ext_h < s->h);
    if (part) { static uint32_t lw, lh; if (lw != s->ext_w || lh != s->ext_h) { lw = s->ext_w; lh = s->ext_h; GLOG("上屏取窗口表面左下 %ux%u（游戏的 vi 层尺寸）", lw, lh); } }
    s->ext_w = s->ext_h = 0;
    if (s->wid[s->cur]) { if (!part) crop[2] = crop[3] = 0; gl_wd_present(s->wid[s->cur], s->w, s->h, crop); part = crop[2] > 0 && crop[3] > 0; }   // 宽屏：裁剪按放宽换算（核心定出图范围）
    s->ticket[s->cur] = mtl_present_ext(s->serial[s->cur], nvn_fps_period((s->interval ? s->interval : 1) / (double)nvn_be_fps_target()), (__bridge void *)gl_ev, v, part ? crop : NULL);
    s->cur = (s->cur + 1) % NSURF;
    uint64_t t_pw = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); if (s->ticket[s->cur]) nvn_be_present_wait(s->ticket[s->cur]);
    uint64_t t_pace = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); dm_gfx_leave();
    // 交换锁垂直同步（Switch 语义：NVIDIA 驱动的 eglSwapBuffers 等到第 interval 次垂直同步才返回，游戏主循环靠它锁帧）。只交给上屏路径不等的话，
    //   上屏路径没按显示刷新节拍卡住时（Mac 宿主离屏图层、Spare-host 无显示器）游戏主循环空转到每秒几百帧（10-25 数码宝贝 Mac 局 321 / Spare-host 716 帧/秒）。
    //   按 interval / 刷新率的节拍等到下一拍；落后超过一拍不补帧，从现在重新对齐。interval 0 = 不等
    //   有显示链接（iPhone、Mac 窗口）时跟链接的拍（同 Vulkan 层 vkAcquireNextImageKHR）：自己的时钟和链接相位对不上，两套节拍叠加每帧多错过 1–3 拍
    //   （10-25 测试设备2 数码宝贝标题页上屏间隔 50 / 67 / 83 ms、12–16 帧/秒）；链接已过拍（本帧已落后）就不等
    double per = nvn_fps_period(s->interval / (double)nvn_be_fps_target());
    __atomic_store_n(&g_gl_game_fps, s->interval ? nvn_be_fps_target() / (int)s->interval : 0, __ATOMIC_RELAXED);   // 节拍周期 interval / 目标帧率 的倒数（上限另算）
    // interval 0 原来不等；显式上限启用后也应限帧。上限 30 由链接自身降为 30 Hz，interval 2 只等同一拍。
    if (per > 0 && nvn_be_link_active()) nvn_be_link_wait_tick(s->interval ? (int)s->interval : nvn_fps_limit() > 60 ? 0 : 1, (uint64_t)(2e9 * per));
    else if (per > 0) {
        struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); double now = ts.tv_sec + ts.tv_nsec * 1e-9;
        __atomic_fetch_add(&g_gl_pace[0], 1, __ATOMIC_RELAXED); __atomic_store_n(&g_gl_pace[1], (uint64_t)(per * 1e9 + 0.5), __ATOMIC_RELAXED);
        // 截止时刻按刻度走（真机垂直同步语义）：上次刻度 + k × 周期，k 取让它 ≥ 现在的最小值（≥ 1）。帧比周期长就落到下一个刻度、只等到那一刻，
        //   不补发、也不再「从现在重新起拍再整睡一周期」（11-23 前的做法：12 ms 的帧在 8.3 ms 周期下被拖到约 24 ms，20 ms 的帧在 60 档被拖到 36.7 ms，真机是 16.7 / 33.3）。
        //   首帧从现在起拍；停了很久回来同样落到 ≥ 现在的那个刻度，不会一口气补帧
        if (s->next_swap <= 0) s->next_swap = now;
        { double k = ceil((now - s->next_swap) / per); if (k < 1) k = 1;
          if (k > 1) __atomic_fetch_add(&g_gl_pace[2], (uint64_t)(k - 1), __ATOMIC_RELAXED);
          s->next_swap += k * per; }
        double wait = s->next_swap - now;
        if (wait > 0) { uint64_t w = (uint64_t)(wait * 1e9); __atomic_fetch_add(&g_gl_pace[3], 1, __ATOMIC_RELAXED); if (w > __atomic_load_n(&g_gl_pace[4], __ATOMIC_RELAXED)) __atomic_store_n(&g_gl_pace[4], w, __ATOMIC_RELAXED); }
        if (wait > 0) s2a_sleep_ns((int64_t)(wait * 1e9));   // 不用 nanosleep：游戏线程 utility 下定时器余量放宽、多睡上百毫秒（同 Vulkan 层 vkAcquireNextImageKHR）
    }
    // 每 300 帧一行拆账（真机定位用，10-25 测试设备2 标题页 12–16 帧/秒）：两次交换之间的墙钟 = 游戏自己（含等 GPU）+ 交换里提交 + 等上屏 + 节拍等待
    {   extern _Atomic uint64_t gl_n_tex_alloc; static uint64_t t_prev, acc_frame, acc_pw, acc_pace, acc_sub, w_n0, w_ns0, a_n0; uint64_t t_out = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (t_prev) acc_frame += t_out - t_prev;
        t_prev = t_out; acc_sub += t_pw - t_in; acc_pw += t_pace - t_pw; acc_pace += t_out - t_pace;
        if ((gl_n_frames + 1) % 300 == 0) {
            uint64_t wn = gl_wait_n - w_n0, wns = gl_wait_ns - w_ns0;
            // 显存账（11-01 街霸 30 周年 Spare-host：每帧新建一张 384x224、Metal 内部内存一路涨到分配失败）：新建贴图存储次数 + 设备当前已分配字节，看新建了是否都放掉
            GLOG("近 300 帧拆账：每帧 %.1f ms = 游戏 %.1f（其中等 GPU %llu 次 共 %.1f）+ 交换提交 %.1f + 等上屏 %.1f + 节拍等 %.1f；交换间隔 %u、显示链接 %s、目标 %d 帧/秒；新建贴图 %llu 张、设备已分配 %.0f MB",
                 acc_frame / 300e6, (acc_frame - acc_sub - acc_pw - acc_pace) / 300e6, (unsigned long long)wn, wns / 300e6, acc_sub / 300e6, acc_pw / 300e6, acc_pace / 300e6,
                 s->interval, nvn_be_link_active() ? "开" : "关", nvn_be_fps_target(), (unsigned long long)(gl_n_tex_alloc - a_n0), gl_dev.currentAllocatedSize / 1048576.0);
            acc_frame = acc_pw = acc_pace = acc_sub = 0; w_n0 = gl_wait_n; w_ns0 = gl_wait_ns; a_n0 = gl_n_tex_alloc; }
    }
    uint64_t f = ++gl_n_frames; dm_guest_frame_tick();
    if (f > 9) { double a = nvn_be_presented_time(f - 8), b = nvn_be_presented_time(f - 9); dm_perf_present(a < 0 ? -1 : a > 0 && b > 0 ? (a - b) * 1e3 : 0); }   // 同 Vulkan 层：上屏序号即票号
    return 1;
}}
GL(eglGetProcAddress, void *, const char *name) { void *p = gl_entry_or_stub(name); if (p && name) snap_ho(p, "gl:proc:%s", name); return p; }   // 重活套切栈桩（gl_core.m）；没实现的核心名给安全空实现
// 松开本线程的当前上下文与表面（EGL 1.5 §3.11：同 eglMakeCurrent 全空），错误码 / API 回初值；已删的此时才放
GLB(eglReleaseThread, EGLBoolean, void) { @autoreleasepool { bind_current(NULL, NULL); g_api = EGL_OPENGL_ES_API; g_err = EGL_SUCCESS; return 1; }}

// ---------- 即时存档（苹果端缺省开、S2A_SNAP_MODE=0 关，见 runtime/src/snapsw.c；恢复局 S2A_SNAP_RESTORE） ----------
// 交给游戏的宿主指针：表面 / 上下文句柄（calloc 的地址）、eglGetProcAddress 交出的函数、glGetString 的串。游戏把它们拷进自己的内存，新进程里地址全变：
//   建 / 交出时按身份登记（gl:surf:<序号>、gl:ctx:<序号>、gl:proc:<名字>、gl:str:…），恢复时快照引擎按身份问 gl_snap_resolve 要本进程的值、扫写回的页换掉。
//   表面 / 上下文在那时先建空壳（序号同快照），gl_snap_restore 再按快照填内容、建贴图
// 弱链接[nvntest]：s2a_snap_conv_get（runtime/src/snapshot.c 提供；GL 各片读整块存的结构时按布局转换表转，经 snapfmt.h snap_conv_get；同下）
// 弱链接[nvntest]：s2a_snap_thread_self（runtime/src/thread.c 提供；图形单测不链宿主，链接行按这行放行未定义）
void s2a_snap_handout_id(uint64_t v, const char *id) __attribute__((weak));
int s2a_snap_mode(void) __attribute__((weak));
uint64_t s2a_snap_thread_self(void) __attribute__((weak));
static int snap_on(void) { return s2a_snap_mode && s2a_snap_mode() && s2a_snap_handout_id; }
static void snap_ho(const void *p, const char *fmt, ...) {
    if (!p || !snap_on()) return;
    char id[128]; va_list ap; va_start(ap, fmt); vsnprintf(id, sizeof id, fmt, ap); va_end(ap);
    s2a_snap_handout_id((uint64_t)(uintptr_t)p, id);
}
// 各游戏线程的当前上下文 / 表面 / API（线程本地变量存不进快照：按客体线程号记一张表，恢复时各线程就位就接回，见 gl_snap_thread_bind）
typedef struct { uint64_t tid; uint32_t ctx, surf, api; } snap_tb;
static snap_tb g_tb[64]; static int g_ntb;   // 持 g_egl_mu
static void snap_tb_note(void) {
    if (!snap_on() || !s2a_snap_thread_self) return;
    uint64_t tid = s2a_snap_thread_self(); if (!tid) return;
    context_t *c = cur_context();
    pthread_mutex_lock(&g_egl_mu);
    int i = 0; while (i < g_ntb && g_tb[i].tid != tid) i++;
    if (i == g_ntb && g_ntb < 64) g_ntb++;
    if (i < 64) g_tb[i] = (snap_tb){tid, c ? c->seq : 0, g_draw ? g_draw->seq : 0, g_api};
    pthread_mutex_unlock(&g_egl_mu);
}
static surface_t *surf_by_seq(uint32_t k, int make) {   // 持 g_egl_mu
    for (surface_t *s = g_surfaces; s; s = s->next) if (s->seq == k) return s;
    if (!make) return NULL;
    surface_t *s = calloc(1, sizeof *s); if (!s) return NULL; s->seq = k; s->next = g_surfaces; g_surfaces = s; if (k > g_seq_surf) g_seq_surf = k; return s;
}
static context_t *ctx_by_seq(uint32_t k, int make) {   // 持 g_egl_mu
    for (context_t *c = g_contexts; c; c = c->next) if (c->seq == k) return c;
    if (!make) return NULL;
    context_t *c = calloc(1, sizeof *c); if (!c) return NULL; c->seq = k; c->next = g_contexts; g_contexts = c; if (k > g_seq_ctx) g_seq_ctx = k; return c;
}
// 快照引擎（runtime/src/snapshot.c handout_resolve）：身份 → 本进程的值；不认的回 0（引擎报红）
uint64_t gl_snap_resolve(const char *id) {
    if (!strncmp(id, "gl:surf:", 8) || !strncmp(id, "gl:ctx:", 7)) {
        int surf = id[3] == 's'; uint32_t k = (uint32_t)strtoul(id + (surf ? 8 : 7), NULL, 10); if (!k) return 0;
        pthread_mutex_lock(&g_egl_mu); void *o = surf ? (void *)surf_by_seq(k, 1) : (void *)ctx_by_seq(k, 1); pthread_mutex_unlock(&g_egl_mu);
        return (uint64_t)(uintptr_t)o;
    }
    if (!strncmp(id, "gl:proc:", 8)) return (uint64_t)(uintptr_t)gl_entry_or_stub(id + 8);
    if (!strncmp(id, "gl:str:", 7)) return (uint64_t)(uintptr_t)gl_snap_str(id + 7);
    if (!strncmp(id, "gl:map:", 7)) return gl_buf_snap_map(id + 7);
    return 0;
}
// 快照引擎写交出指针表之前调（冻结后）：只在存档那一刻才有意义的交出指针（映射着的缓冲）这时登记
void gl_snap_handout_now(void) { if (snap_on()) gl_buf_snap_handout(); }
int gl_snap_used(void) { pthread_mutex_lock(&g_egl_mu); int u = g_surfaces || g_contexts; pthread_mutex_unlock(&g_egl_mu); return u; }

// 本文件的字段号（只增不改；删字段留空号）
enum { GE_INIT = 1, GE_FPS, GE_SEQS, GE_SEQC,
       GS_SEQ = 1, GS_W, GS_H, GS_INTERVAL, GS_PBUF, GS_LARGEST, GS_CUR, GS_DEAD,
       GC_SEQ = 1, GC_DEAD, GC_API, GC_VAO, GC_PROG, GC_FBD, GC_FBR, GC_BUFB, GC_UNPACK_ALIGN, GC_UNPACK_ROW, GC_PACK_ALIGN, GC_RB, GC_POLY_F, GC_POLY_U, GC_LINEW, GC_POINTSZ,
       GC_TEXU, GC_SMPU, GC_ACTIVE, GC_UBO, GC_UBO_OFF, GC_UBO_SIZE, GC_VP, GC_SC, GC_DRANGE, GC_ENABLE, GC_COLOR, GC_DDRAW, GC_DREAD, GC_POLYMODE, GC_ATTRCUR,
       GC_DEPTHF, GC_CULL, GC_FRONT, GC_STF, GC_STOP, GC_STREF, GC_STMASK, GC_STWMASK, GC_DMASK, GC_BLENDC, GC_CLEARC, GC_CLEARD, GC_CLEARS, GC_ERR, GC_DVAO,
       GT_TID = 1, GT_CTX, GT_SURF, GT_API };
#define GL_STATE_FIELDS(X) X(GC_API, api) X(GC_VAO, vao) X(GC_PROG, prog) X(GC_FBD, fb_draw) X(GC_FBR, fb_read) X(GC_BUFB, buf_bound) X(GC_UNPACK_ALIGN, unpack_align) \
    X(GC_UNPACK_ROW, unpack_row) X(GC_PACK_ALIGN, pack_align) X(GC_RB, rb_bound) X(GC_POLY_F, poly_factor) X(GC_POLY_U, poly_units) X(GC_LINEW, line_width) X(GC_POINTSZ, point_size) \
    X(GC_TEXU, tex_unit) X(GC_SMPU, smp_unit) X(GC_ACTIVE, active_unit) X(GC_UBO, ubo) X(GC_UBO_OFF, ubo_off) X(GC_UBO_SIZE, ubo_size) X(GC_VP, vp) X(GC_SC, sc) X(GC_DRANGE, depth_range) \
    X(GC_ENABLE, enable) X(GC_COLOR, color) X(GC_DDRAW, default_draw) X(GC_DREAD, default_read) X(GC_POLYMODE, poly_mode) X(GC_ATTRCUR, attr_cur) X(GC_DEPTHF, depth_func) X(GC_CULL, cull) \
    X(GC_FRONT, front) X(GC_STF, stencil_func) X(GC_STOP, stencil_op) X(GC_STREF, stencil_ref) X(GC_STMASK, stencil_mask) X(GC_STWMASK, stencil_wmask) X(GC_DMASK, depth_mask) \
    X(GC_BLENDC, blend_color) X(GC_CLEARC, clear_color) X(GC_CLEARD, clear_depth) X(GC_CLEARS, clear_stencil) X(GC_ERR, error) X(GC_DVAO, default_vao)

// 存：调用方已冻结全部游戏线程。path = 快照目录里的 gfx_gl.bin
int gl_snap_save(const char *path) {
    if (!gl_snap_drain()) { GLOG("【红】 即时存档：GL 出图层排空超时"); return -1; }
    FILE *f = fopen(path, "wb"); if (!f) return -1;
    sfw w; int ns = 0, nc = 0;
    pthread_mutex_lock(&g_egl_mu);
    sfw_sec(&w, f, "gl.egl", 1); sfw_rec(&w);
    { int in = atomic_load(&g_initialized); GLSF_W(&w, GE_INIT, in); } GLSF_W(&w, GE_FPS, g_gl_game_fps); GLSF_W(&w, GE_SEQS, g_seq_surf); GLSF_W(&w, GE_SEQC, g_seq_ctx);
    sfw_end_rec(&w); int bad = sfw_end(&w);
    sfw_sec(&w, f, "gl.surf", 1);
    for (surface_t *s = g_surfaces; s; s = s->next) { sfw_rec(&w); GLSF_W(&w, GS_SEQ, s->seq); GLSF_W(&w, GS_W, s->w); GLSF_W(&w, GS_H, s->h); GLSF_W(&w, GS_INTERVAL, s->interval);
        GLSF_W(&w, GS_PBUF, s->pbuffer); GLSF_W(&w, GS_LARGEST, s->largest); GLSF_W(&w, GS_CUR, s->cur); GLSF_W(&w, GS_DEAD, s->dead); sfw_end_rec(&w); ns++; }
    bad |= sfw_end(&w);
    sfw_sec(&w, f, "gl.ctx", 1);
    for (context_t *c = g_contexts; c; c = c->next) { sfw_rec(&w); GLSF_W(&w, GC_SEQ, c->seq); GLSF_W(&w, GC_DEAD, c->dead);
        #define X(id, fld) GLSF_W(&w, id, c->st.fld);
        GL_STATE_FIELDS(X)
        #undef X
        sfw_end_rec(&w); nc++; }
    bad |= sfw_end(&w);
    sfw_sec(&w, f, "gl.thr", 1);
    for (int i = 0; i < g_ntb; i++) { sfw_rec(&w); GLSF_W(&w, GT_TID, g_tb[i].tid); GLSF_W(&w, GT_CTX, g_tb[i].ctx); GLSF_W(&w, GT_SURF, g_tb[i].surf); GLSF_W(&w, GT_API, g_tb[i].api); sfw_end_rec(&w); }
    bad |= sfw_end(&w);
    // 各上下文的默认纹理（上下文私有、不在名字表里）：按上下文链表顺序、每个 4 个
    uint32_t n = (uint32_t)nc; bad |= fwrite(&n, 4, 1, f) != 1;
    for (context_t *c = g_contexts; c && !bad; c = c->next) { bad |= fwrite(&c->seq, 4, 1, f) != 1; for (int k = 0; k < 4 && !bad; k++) bad |= gl_tex_snap_one_save(f, c->st.default_tex[k]) < 0; }
    pthread_mutex_unlock(&g_egl_mu);
    bad |= gl_buf_snap_save(f) || gl_tex_snap_save(f) || gl_prog_snap_save(f) || gl_fb_snap_save(f) || gl_draw_snap_save(f);
    bad |= fclose(f) != 0;
    GLOG("%s即时存档：GL 出图层 表面 %d 个、上下文 %d 个、绑定线程 %d 条", bad ? "【红】 " : "", ns, nc, g_ntb);
    return bad ? -1 : 0;
}

// 取：新进程，游戏线程未起；快照引擎写回游戏内存时已按句柄身份建好表面 / 上下文空壳
int gl_snap_restore(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return -1;
    gl_dev_init();
    sfr r; int bad = 0, ns = 0, nc = 0;
    if (sfr_sec(&r, f, "gl.egl", 1)) { fclose(f); GLOG("【红】 即时存档恢复：GL 快照段头不认（比本版新或已坏）"); return -1; }
    while (sfr_rec(&r) == 1) {
        int in = 1; GLSF_R(&r, GE_INIT, in); atomic_store(&g_initialized, in); GLSF_R(&r, GE_FPS, g_gl_game_fps);
        uint32_t a = 0, b = 0; GLSF_R(&r, GE_SEQS, a); GLSF_R(&r, GE_SEQC, b);
        pthread_mutex_lock(&g_egl_mu); if (a > g_seq_surf) g_seq_surf = a; if (b > g_seq_ctx) g_seq_ctx = b; pthread_mutex_unlock(&g_egl_mu);
    }
    sfr_done(&r);
    if (sfr_sec(&r, f, "gl.surf", 1)) bad = 1;
    while (!bad && sfr_rec(&r) == 1) {
        uint32_t k = 0; GLSF_R(&r, GS_SEQ, k); if (!k) continue;
        pthread_mutex_lock(&g_egl_mu); surface_t *s = surf_by_seq(k, 1); pthread_mutex_unlock(&g_egl_mu); if (!s) { bad = 1; break; }
        s->w = 1920; s->h = 1080; s->interval = 1;
        GLSF_R(&r, GS_W, s->w); GLSF_R(&r, GS_H, s->h); GLSF_R(&r, GS_INTERVAL, s->interval); GLSF_R(&r, GS_PBUF, s->pbuffer); GLSF_R(&r, GS_LARGEST, s->largest); GLSF_R(&r, GS_DEAD, s->dead);
        uint32_t cur = 0; GLSF_R(&r, GS_CUR, cur); s->cur = cur % NSURF;
        if (s->pbuffer) { if (!surface_pbuffer_build(s)) { GLOG("【红】 即时存档恢复：离屏表面 %u（%ux%u）建不出来", k, s->w, s->h); bad = 1; } }
        else surface_window_build(s);
        ns++;
    }
    sfr_done(&r);
    if (!bad && sfr_sec(&r, f, "gl.ctx", 1)) bad = 1;
    while (!bad && sfr_rec(&r) == 1) {
        uint32_t k = 0; GLSF_R(&r, GC_SEQ, k); if (!k) continue;
        pthread_mutex_lock(&g_egl_mu); context_t *c = ctx_by_seq(k, 1); pthread_mutex_unlock(&g_egl_mu); if (!c) { bad = 1; break; }
        GLSF_R(&r, GC_DEAD, c->dead);
        #define X(id, fld) GLSF_R(&r, id, c->st.fld);
        GL_STATE_FIELDS(X)
        #undef X
        GLSF_RC(&r, GC_COLOR, c->st.color, "gl.color_state", gl_color_state);   // 带布局指纹的结构数组：旧布局按字段转（上面那遍原样读的盖掉）
        memset(c->st.default_tex, 0, sizeof c->st.default_tex); c->st.dirty = ~0u; c->bound = 0;
        nc++;
    }
    sfr_done(&r);
    if (!bad && sfr_sec(&r, f, "gl.thr", 1)) bad = 1;
    pthread_mutex_lock(&g_egl_mu); g_ntb = 0;
    while (!bad && sfr_rec(&r) == 1) { if (g_ntb == 64) continue; snap_tb *t = &g_tb[g_ntb]; memset(t, 0, sizeof *t); t->api = EGL_OPENGL_ES_API;
        GLSF_R(&r, GT_TID, t->tid); GLSF_R(&r, GT_CTX, t->ctx); GLSF_R(&r, GT_SURF, t->surf); GLSF_R(&r, GT_API, t->api); if (t->tid) g_ntb++; }
    pthread_mutex_unlock(&g_egl_mu);
    sfr_done(&r);
    uint32_t n = 0; if (!bad && fread(&n, 4, 1, f) != 1) bad = 1;
    for (uint32_t i = 0; !bad && i < n; i++) {
        uint32_t k = 0; if (fread(&k, 4, 1, f) != 1) { bad = 1; break; }
        pthread_mutex_lock(&g_egl_mu); context_t *c = ctx_by_seq(k, 0); pthread_mutex_unlock(&g_egl_mu);
        for (int t = 0; t < 4; t++) { long at = ftell(f); uint8_t has; if (fread(&has, 1, 1, f) != 1) { bad = 1; break; } fseek(f, at, SEEK_SET);
            gl_texture *x = gl_tex_snap_one_load(f); if (has && !x) { bad = 1; break; } if (c) c->st.default_tex[t] = x; }
    }
    bad = bad || gl_buf_snap_restore(f) || gl_tex_snap_restore(f) || gl_prog_snap_restore(f) || gl_fb_snap_restore(f) || gl_draw_snap_restore(f);
    fclose(f);
    GLOG("%s即时存档恢复：GL 出图层 表面 %d 个、上下文 %d 个、绑定线程 %d 条", bad ? "【红】 " : "", ns, nc, g_ntb);
    return bad ? -1 : 0;
}
// 恢复局：每条游戏线程就位时调（runtime/src/thread.c snap_thread_main，客体线程号）：按快照接回它的当前上下文 / 表面 / API
void gl_snap_thread_bind(uint64_t tid) {
    pthread_mutex_lock(&g_egl_mu);
    snap_tb t = {0}; for (int i = 0; i < g_ntb; i++) if (g_tb[i].tid == tid) t = g_tb[i];
    context_t *c = t.ctx ? ctx_by_seq(t.ctx, 0) : NULL; surface_t *s = t.surf ? surf_by_seq(t.surf, 0) : NULL;
    if (c) c->bound++; if (s) s->bound++;
    pthread_mutex_unlock(&g_egl_mu);
    if (!t.tid) return;
    g_draw = s; gl_cur = c ? &c->st : NULL; g_api = t.api ? t.api : EGL_OPENGL_ES_API;
    GLOG("即时存档恢复：线程 %llu 接回 GL 上下文 %u、表面 %u", (unsigned long long)tid, t.ctx, t.surf);
}
// 本层按整块存的小结构（数组元素、嵌套结构）的布局指纹；整体结构按字段号存，不在此列
void gl_snap_fps(gl_fp_cb cb) {
    struct gl_program *p = NULL; (void)p;
    cb("gl.uniform", SNAP_FP_TYPE(gl_uniform)); cb("gl.attrib", SNAP_FP_TYPE(gl_attrib)); cb("gl.vao", SNAP_FP_TYPE(struct gl_vao)); cb("gl.color_state", SNAP_FP_TYPE(gl_color_state));
    cb("gl.prog.smp", SNAP_FP_OF(p->smp[0])); cb("gl.prog.blk", SNAP_FP_OF(p->blk[0])); cb("gl.prog.attr", SNAP_FP_OF(p->attr[0])); cb("gl.prog.bind", SNAP_FP_OF(p->bind[0]));
    gl_tex_snap_fps(cb); gl_fb_snap_fps(cb);
}
