// nvn_plat.h 的安卓实现：日志进 logcat，开关读 debug.s2a.<名字>（只在调试入口打开时认），目录由会话给。
#include <stdatomic.h>
#include <pthread.h>
#include "nvn_plat.h"
#include <android/log.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>
#include "debug_gate.h"

const char *nvk_session_cache_dir(void);

void nvn_plat_log(int level, const char *cls, const char *text) {
    int prio = level == NVN_PLAT_LOG_RED ? ANDROID_LOG_ERROR : level == NVN_PLAT_LOG_WARN ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
    __android_log_print(prio, "S2Arm", "%snvk %s: %s", level == NVN_PLAT_LOG_RED ? "【红】" : "", cls ? cls : "", text ? text : "");
    // 调试入口开着时同一行也写进本局的宿主日志文件（标准错误已接到 host-*.log）。系统日志在真机上会整段丢掉某个进程的行
    // （一晚上遇到五次「游戏在跑、logcat 里这个进程 0 行」，宿主日志文件完好），读数不能只押在它上面。
    if (s2a_debug_entries_open()) fprintf(stderr, "[s2a] %snvk %s: %s\n", level == NVN_PLAT_LOG_RED ? "【红】" : "", cls ? cls : "", text ? text : "");
}

int nvn_plat_flag(const char *name, int dflt) {
    if (!name || !s2a_debug_entries_open()) return dflt;
    char key[PROP_NAME_MAX + 32], v[PROP_VALUE_MAX] = {0};
    snprintf(key, sizeof key, "debug.s2a.%s", name);
    if (__system_property_get(key, v) <= 0 || !v[0]) return dflt;
    return atoi(v);
}

// 回放循环的安全点（nvn_plat.h）：运行时改内存映射要所有游戏线程停下，回放所在的游戏线程一次提交可连续跑数秒，
// 在命令之间让它停到事务结束（android/native/runtime/fault/thread_android.inc）。诊断目标不链运行时：弱符号。
extern void s2a_android_guest_host_safepoint(void) __attribute__((weak));
void nvn_plat_safepoint(void) { if (s2a_android_guest_host_safepoint) s2a_android_guest_host_safepoint(); }

const char *nvn_plat_dir(int which) {
    if (which == NVN_PLAT_DIR_CACHE) return nvk_session_cache_dir();
    if (which == NVN_PLAT_DIR_DIAG) return getenv("S2A_DIRECT_DIAG_DIR");
    return NULL;
}

// 前端还直接按名字要的两个宿主入口（hle_nvn.c / nvn2.c）
const char *nvn_diag_path(const char *p, char *buf, size_t n) { (void)buf; (void)n; return p; }   // 诊断输出路径：原样返回，同非 iOS 的苹果宿主
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && d[0] == '1' && !d[1]; }   // 主机 / 掌机档：S2A_DOCKED=1 主机，其余掌机

// ---------- 每款参数 ----------
// 共用前端按 DM_GAME_* 读每款参数（graphics/nvn/host/game_profile.h）。没有随包档 / 没写的键按 Switch 真实语义的缺省
// （game_tsv.h s2a_game_tsv_defaults：条件渲染照实求值、CPU 写进池的贴图要上传、动态句柄着色器、段内 GPU 时间戳都开）。
// 这里是强定义；vk_engine_host_shim.c 的弱桩是全 0，等于把这些全关掉——贴图在首次使用之后才被游戏填进内容的那些永远传不上来
// （块压缩贴图停在全 0：ASTC 解成错误色洋红，DXT 解成全透明）。随包 game.tsv 由当前已激活 revision 提供。
#include "../../../graphics/nvn/host/game_profile.h"

// ---------- 调试：进程内取样剖析（开关 debug.s2a.nvk_prof=1；默认关） ----------
// 帧时间的大头在图形调用之外时，要知道 CPU 花在哪个模块。系统的剖析器要先放开一个系统属性，这里不动系统设置：
// 按进程 CPU 时间每毫秒来一个 SIGPROF，落在谁身上就记谁当时的指令地址（处理函数里只写一个环，不加锁、不分配）；
// 另有一条线程每 5 秒把这段时间的样本按模块、按 4 KB 页归拢，各打一行。只回答「CPU 时间花在哪」，等待不算在内。
#include <dlfcn.h>
#include <signal.h>
#include <sys/time.h>
#include <unistd.h>
enum { PROF_RING = 1 << 16 };
static uintptr_t g_prof_ring[PROF_RING]; static _Atomic uint64_t g_prof_w;
static void prof_sig(int sig, siginfo_t *si, void *uc) {
    (void)sig; (void)si;
#if defined(__aarch64__) && !defined(__APPLE__)   // 苹果芯片的宿主上也会编这个文件（宿主单测）：那边的信号上下文是另一种布局，取不到就记 0
    uintptr_t pc = (uintptr_t)((ucontext_t *)uc)->uc_mcontext.pc;
#else
    uintptr_t pc = 0; (void)uc;
#endif
    g_prof_ring[atomic_fetch_add_explicit(&g_prof_w, 1, memory_order_relaxed) & (PROF_RING - 1)] = pc;
}
static int prof_cmp(const void *a, const void *b) { uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b; return x < y ? -1 : x > y; }
static void *prof_report(void *arg) {
    (void)arg; uint64_t r = 0; static uintptr_t buf[PROF_RING], raw[PROF_RING];
    for (;;) {
        sleep(5);
        uint64_t w = atomic_load_explicit(&g_prof_w, memory_order_relaxed); if (w - r > PROF_RING) r = w - PROF_RING;
        size_t n = (size_t)(w - r); if (!n) continue;
        for (size_t i = 0; i < n; i++) { raw[i] = g_prof_ring[(r + i) & (PROF_RING - 1)]; buf[i] = raw[i] & ~(uintptr_t)0xfff; }   // 按 4 KB 页
        r = w; qsort(buf, n, sizeof *buf, prof_cmp);
        struct { uintptr_t page; size_t n; } top[12]; int nt = 0;
        struct { char name[40]; size_t n; } mod[16]; int nm = 0;
        for (size_t i = 0; i < n;) { size_t j = i; while (j < n && buf[j] == buf[i]) j++;
            size_t cnt = j - i; Dl_info di; const char *nm0 = "游戏代码";
            if (dladdr((void *)buf[i], &di) && di.dli_fname) { const char *sl = strrchr(di.dli_fname, '/'); nm0 = sl ? sl + 1 : di.dli_fname; }
            int k = 0; for (; k < nm; k++) if (!strncmp(mod[k].name, nm0, sizeof mod[k].name - 1)) break;
            if (k == nm && nm < 16) { snprintf(mod[nm].name, sizeof mod[nm].name, "%s", nm0); mod[nm].n = 0; nm++; }
            if (k < nm) mod[k].n += cnt;
            int at = nt < 12 ? nt : -1; if (at < 0) { int mi = 0; for (int q = 1; q < 12; q++) if (top[q].n < top[mi].n) mi = q; if (top[mi].n < cnt) at = mi; } else nt++;
            if (at >= 0) { top[at].page = buf[i]; top[at].n = cnt; }
            i = j; }
        char line[900]; int o = snprintf(line, sizeof line, "剖析：5 秒 %zu 个样本（每个 1 毫秒 CPU）；按模块：", n);
        for (int pass = 0; pass < nm && pass < 8; pass++) { int bi = -1; for (int k = 0; k < nm; k++) if (mod[k].n && (bi < 0 || mod[k].n > mod[bi].n)) bi = k; if (bi < 0) break;
            o += snprintf(line + o, sizeof line - (size_t)o, " %s %.0f%%", mod[bi].name, 100.0 * (double)mod[bi].n / (double)n); mod[bi].n = 0; }
        __android_log_print(ANDROID_LOG_INFO, "S2Arm", "nvk prof: %s", line);
        o = snprintf(line, sizeof line, "剖析：最热的页：");
        for (int pass = 0; pass < nt && pass < 10; pass++) { int bi = -1; for (int k = 0; k < nt; k++) if (top[k].n && (bi < 0 || top[k].n > top[bi].n)) bi = k; if (bi < 0) break;
            Dl_info di; int ok = dladdr((void *)top[bi].page, &di) && di.dli_fname; const char *sl = ok ? strrchr(di.dli_fname, '/') : NULL;
            o += snprintf(line + o, sizeof line - (size_t)o, " %s+%#lx %.1f%%;", ok ? (sl ? sl + 1 : di.dli_fname) : "游戏", (unsigned long)(ok ? top[bi].page - (uintptr_t)di.dli_fbase : top[bi].page), 100.0 * (double)top[bi].n / (double)n); top[bi].n = 0; }
        __android_log_print(ANDROID_LOG_INFO, "S2Arm", "nvk prof: %s", line);
        {   // 最热的那一页：它落在进程的哪段映射里（/proc/self/maps 的那一行），页里最热的几个地址
            uintptr_t hot = 0; size_t hn = 0;
            for (size_t i = 0; i < n;) { size_t j = i; while (j < n && buf[j] == buf[i]) j++; if (j - i > hn) { hn = j - i; hot = buf[i]; } i = j; }
            char map[200] = "?"; FILE *f = fopen("/proc/self/maps", "r");
            if (f) { char ln[400]; while (fgets(ln, sizeof ln, f)) { unsigned long a = 0, b = 0; if (sscanf(ln, "%lx-%lx", &a, &b) == 2 && hot >= a && hot < b) { size_t L = strlen(ln); if (L && ln[L - 1] == '\n') ln[L - 1] = 0; snprintf(map, sizeof map, "%s", ln); break; } } fclose(f); }
            size_t m = 0; for (size_t i = 0; i < n; i++) if ((raw[i] & ~(uintptr_t)0xfff) == hot) raw[m++] = raw[i];
            qsort(raw, m, sizeof *raw, prof_cmp);
            struct { uintptr_t pc; size_t n; } tp[6]; int np = 0;
            for (size_t i = 0; i < m;) { size_t j = i; while (j < m && raw[j] == raw[i]) j++;
                int at = np < 6 ? np : -1; if (at < 0) { int mi = 0; for (int q = 1; q < 6; q++) if (tp[q].n < tp[mi].n) mi = q; if (tp[mi].n < j - i) at = mi; } else np++;
                if (at >= 0) { tp[at].pc = raw[i]; tp[at].n = j - i; }
                i = j; }
            o = snprintf(line, sizeof line, "剖析：最热页 %#lx（%zu 个样本）在映射 [%s]；页内：", (unsigned long)hot, hn, map);
            for (int k = 0; k < np; k++) { uint32_t ins = 0; memcpy(&ins, (const void *)tp[k].pc, 4); o += snprintf(line + o, sizeof line - (size_t)o, " +%#lx×%zu(指令 %08x)", (unsigned long)(tp[k].pc - hot), tp[k].n, ins); }
            __android_log_print(ANDROID_LOG_INFO, "S2Arm", "nvk prof: %s", line);
            // 这一页连同前后各一页的原始字节落到缓存目录（同一页只落一次），拿回去反汇编看是哪个函数
            static uintptr_t dumped[8]; static int nd; int seen = 0; for (int k = 0; k < nd; k++) if (dumped[k] == hot) seen = 1;
            const char *dir = nvn_plat_dir(NVN_PLAT_DIR_CACHE);
            if (!seen && nd < 8 && dir && hn * 4 > n) { dumped[nd++] = hot; char pth[320]; snprintf(pth, sizeof pth, "%s/nvkprof_%lx.bin", dir, (unsigned long)(hot - 0x1000));
                FILE *o2 = fopen(pth, "wb"); if (o2) { fwrite((const void *)(hot - 0x1000), 1, 0x3000, o2); fclose(o2); __android_log_print(ANDROID_LOG_INFO, "S2Arm", "nvk prof: 已落盘 %s", pth); } }
        }
    }
    return NULL;
}
static void prof_start_once(void) {
    static _Atomic int started; if (atomic_exchange(&started, 1) || !nvn_plat_flag("nvk_prof", 0)) return;
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = prof_sig; sa.sa_flags = SA_SIGINFO | SA_RESTART; sigemptyset(&sa.sa_mask);
    if (sigaction(SIGPROF, &sa, NULL)) return;
    struct itimerval it = {{0, 1000}, {0, 1000}}; setitimer(ITIMER_PROF, &it, NULL);
    pthread_t t; if (!pthread_create(&t, NULL, prof_report, NULL)) pthread_detach(t);
    __android_log_print(ANDROID_LOG_INFO, "S2Arm", "nvk prof: 进程内取样剖析已开（每毫秒 CPU 一个样本）");
}

// 只在整份文件读完后调用共用解析器；读取错误 / 分配失败不能把半份参数当成成功。
static int prof_read(const char *path, s2a_game_tsv *out, char *err, size_t en) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char *text = NULL, chunk[4096]; size_t len = 0, n; int ok = 1;
    while ((n = fread(chunk, 1, sizeof chunk, f)) != 0) {
        if (len > SIZE_MAX - n - 1) { ok = 0; break; }
        char *next = realloc(text, len + n + 1);
        if (!next) { ok = 0; break; }
        text = next; memcpy(text + len, chunk, n); len += n; text[len] = 0;
    }
    if (ferror(f)) ok = 0;
    if (fclose(f)) ok = 0;
    if (ok) s2a_game_tsv_parse(text, out, err, en);
    free(text); return ok;
}

const s2a_nvn_profile *s2a_nvn_prof(void) {
    prof_start_once();
    static s2a_nvn_profile p;
    static char *loaded_root;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    // provider 在激活前设置此根；revision 内容不可变。换局换根必须重读，不能沿用上一款。
    // 与会话激活一样，环境变量只在无运行中游戏时更换；调用方不得跨换局持有此参数指针。
    pthread_mutex_lock(&mu);
    const char *root = getenv("S2A_SHADER_REVISION_ROOT");
    if (!root) root = "";
    if (!loaded_root || strcmp(loaded_root, root)) {
        char *new_root = strdup(root);
        if (!new_root) {
            // 无法缓存身份时不发布可被下一位读者改写的 p；返回只初始化一次的缺省快照。
            static s2a_nvn_profile fallback; static int fallback_ready;
            if (!fallback_ready) { s2a_game_tsv_defaults(&fallback.t); fallback_ready = 1; }
            nvn_plat_log(NVN_PLAT_LOG_WARN, "game.tsv", "无法分配参数路径，全按缺省");
            pthread_mutex_unlock(&mu); return &fallback;
        }
        s2a_game_tsv_defaults(&p.t);
        const char suffix[] = "/shaders/direct/game.tsv";
        size_t len = strlen(root); char err[200] = ""; int got = 0;
        char *path = len <= SIZE_MAX - sizeof suffix ? malloc(len + sizeof suffix) : NULL;
        if (*root && path) {
            memcpy(path, root, len); memcpy(path + len, suffix, sizeof suffix);
            got = prof_read(path, &p.t, err, sizeof err);
        }
        free(path);
        nvn_plat_log(*err ? NVN_PLAT_LOG_RED : got ? NVN_PLAT_LOG_INFO : NVN_PLAT_LOG_WARN,
                     "game.tsv", *err ? err : got ? "已读取随包参数；未写的键按缺省" : "随包参数缺失或无法读取，全按缺省");
        free(loaded_root); loaded_root = new_root;
    }
    pthread_mutex_unlock(&mu);
    return &p;
}
int s2a_nvn_render_cond(void) { return s2a_nvn_prof()->t.render_cond; }   // 回放核心问：条件渲染开没开
