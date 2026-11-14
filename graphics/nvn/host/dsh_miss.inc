// 由 host_adapt.m 包含；纯 C 现编接点便于主机用真实实现测依赖边界，不引入另一份实现。
#include <stdatomic.h>
#include "../gfx/nvn/dmsh_chain.h"
static _Atomic uint64_t g_dsh_ok, g_dsh_failed, g_dsh_skipped, g_dsh_reused, g_dsh_typed;
static _Atomic uint64_t g_dsh_eager_n, g_dsh_eager_ok, g_dsh_eager_hit, g_dsh_eager_waited, g_dsh_eager_cancel;   // 后台预编（dsh_eager_start）：交后台 / 编好 / 首遇复用 / 首遇时还在编等了 / 首遇时没开始改同步
// 开发浮层「首遇现建」读（runtime/src/hud.c 经 dlsym）：成功 / 失败 / 跳过 / 复用上局 / 输出类型变体
void s2a_dsh_stats(uint64_t out[5]) { out[0] = atomic_load(&g_dsh_ok); out[1] = atomic_load(&g_dsh_failed); out[2] = atomic_load(&g_dsh_skipped); out[3] = atomic_load(&g_dsh_reused); out[4] = atomic_load(&g_dsh_typed); }
static void dsh_summary(int normal) {
    if (s2a_gfx_mode() != S2A_GFX_DIRECT) return;
    LOG("直连着色器现编汇总：成功 %llu、失败 %llu、跳过 %llu、复用上局 %llu、输出类型变体 %llu（%s）",
        (unsigned long long)atomic_load_explicit(&g_dsh_ok, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&g_dsh_failed, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&g_dsh_skipped, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&g_dsh_reused, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&g_dsh_typed, memory_order_relaxed),
        normal ? "正常收局" : "超时收局");
    if (atomic_load(&g_dsh_eager_n)) LOG("直连着色器后台预编：交后台 %llu 支、编好 %llu 支；首遇时已编好 %llu 支（其中提交线程等它编完 %llu 支）、还没开始改同步 %llu 支",
        (unsigned long long)atomic_load(&g_dsh_eager_n), (unsigned long long)atomic_load(&g_dsh_eager_ok), (unsigned long long)atomic_load(&g_dsh_eager_hit), (unsigned long long)atomic_load(&g_dsh_eager_waited), (unsigned long long)atomic_load(&g_dsh_eager_cancel));
    // #800 采样器归约变体（nvn_mtl.m se_done）：库里不带，绘制真绑了 min / max 采样器、本机不原生归约时在设备上编（本局现出或载上局现出的）
    uint64_t se[2]; mtl_se_stats(se);
    if (se[0] || se[1]) LOG("采样器归约变体：设备编好 %llu / 编不出 %llu", (unsigned long long)se[0], (unsigned long long)se[1]);
    // 顶点补齐变体（nvn_mtl.m vp_ask）：运行期配上的片元要读顶点不写的 user(locn) 时在设备上编
    uint64_t vp[2]; mtl_vp_stats(vp);
    if (vp[0] || vp[1]) LOG("顶点补齐变体：设备编好 %llu / 编不出 %llu", (unsigned long long)vp[0], (unsigned long long)vp[1]);
}
__attribute__((constructor)) static void dsh_register_summary(void) { s2a_direct_summary_register(dsh_summary); }
// 本机现编库的翻译器指纹（S2A.Dsh s2a_dsh_xfp，16 位十六进制）；没链 S2A.Aot 为 NULL
static const char *dsh_xfp(void) {
    static const char *x; static dispatch_once_t once;
    dispatch_once(&once, ^{ const char *(*fn)(void) = (const char *(*)(void))dlsym(RTLD_DEFAULT, "s2a_dsh_xfp"); x = fn ? fn() : NULL; });
    return x;
}
// json 文本里字段 name 的字符串值等于 want（只认 "name": "want" 这种平铺写法，现编 json 是 S2A.Dsh 写的、就是这样）
static int dsh_json_eq(const char *b, const char *name, const char *want) {
    char q[32]; snprintf(q, sizeof q, "\"%s\"", name);
    const char *c = strstr(b, q); c = c ? strchr(c + strlen(q), '"') : NULL; size_t n = strlen(want);
    return c && !strncmp(c + 1, want, n) && c[1 + n] == '"';
}
// 上一局现编过的键：兜底目录里 <键>_b.metal 在、<键>_b.json 记的翻译链版本是本机的、翻译器指纹 xfp 也是本机现编库的
//   （链号只随宿主 / 库接口变，App 升级换了翻译器链号不动、兜底目录又跨更新保留，所以还要比 xfp；拿不到本机指纹就不复用。shader_build 载兜底那支同样两项都核）
static int dsh_have(const char *out, const char *k) {
    char p[1200], b[8192]; snprintf(p, sizeof p, "%s/%s_b.metal", out, k);
    const char *x = dsh_xfp(); if (!x || access(p, R_OK)) return 0;
    snprintf(p, sizeof p, "%s/%s_b.json", out, k); FILE *f = fopen(p, "r"); if (!f) return 0;
    size_t n = fread(b, 1, sizeof b - 1, f); fclose(f); b[n] = 0;
    return dsh_json_eq(b, "chain", DMSH_CHAIN) && dsh_json_eq(b, "xfp", x);
}

typedef int (*dsh_comp_fn)(const char *, int, const void *, size_t, const void *, size_t, const char *);
static dsh_comp_fn dsh_comp(void) {
    static dsh_comp_fn comp; static dispatch_once_t once;
    dispatch_once(&once, ^{ comp = (dsh_comp_fn)dlsym(RTLD_DEFAULT, "s2a_dsh_compile");
                            if (!comp) LOG("【红】直连：没有 s2a_dsh_compile（S2A.Aot 没链进来），缺库的着色器不能现编"); });
    return comp;
}
static const char *const dsh_nm[6] = {"vertex", "pixel", "compute", "geometry", "task", "mesh"};   // 下标 = dsh_stage 的阶段号（4 / 5：NVN2 任务 / 网格，shader_map.tsv 第 3 列同名）
// 阶段：图形代码区以 NVN 头魔数 78563412 开头，SPH 字 0（+0x30）第 10..13 位 1 顶点 4 几何 5 像素（字 0 = 0x61 的老 GLSLC 顶点同 1），同 translator/shader_split.py；
//   不是图形头的按计算着色器（10-24 Mac 验：动森计算着色器 99c210942ecd3f8b 代码区直接是指令、没有 79563412 头）。→ 0 vs / 1 ps / 2 cs / 3 gs（NVN2 另有 4 ts / 5 ms），-1 认不出或长度不对
// DM_NVN_SHDUMP=<目录>（诊断）：库里没有、要现编的着色器存 <键>.ctl / <键>.code（控制段 nctl 字节、代码区 ncode 字节），离线补进库 / 查翻译 / 拿代码区在游戏文件里反查出处。
//   Switch 1（dm_shader_miss）与 Switch 2（dsh_nvn2_pend）都存（11-06 着色器漏读排查：原先只 Switch 2 存，Switch 1 的现编一支都没落盘）
static void dsh_dump(const char *k, const void *control, uint32_t nctl, uint64_t code, uint32_t ncode) {
    const char *shd = getenv("DM_NVN_SHDUMP"); if (!shd || !*shd) return;
    char path[1200]; FILE *f;
    snprintf(path, sizeof path, "%s/%s.ctl", shd, k); if ((f = fopen(path, "wb"))) { fwrite(control, 1, nctl, f); fclose(f); }
    snprintf(path, sizeof path, "%s/%s.code", shd, k); if ((f = fopen(path, "wb"))) { fwrite((const void *)(uintptr_t)code, 1, ncode, f); fclose(f); }
}
static int dsh_stage(const uint8_t *cd, const uint8_t *ctl, uint32_t *ncode, uint32_t *nctl) {
    // Switch 2 的 NVN2 控制段（graphics/nvn/gfx/nvn/nvn2.h，版本 0xc9）：代码长在 +0x44、阶段在 +0x56（0 顶点 1 像素 2 几何 5 计算 6 任务 7 网格；外壳 / 域现编不支持），
    //   控制段取自报长度（+0x30，文件里 0xd8 / 0xe0、内存里可能是 0）、不足或认不出按最短的 0xd8；现编链（S2A.Dsh Nvn2Job）认 0xc9 走 Ampere 前端
    if (nvn2_on() && nvn2_ctl(ctl)) {
        uint32_t own; memcpy(ncode, ctl + 0x44, 4); memcpy(&own, ctl + 0x30, 4); *nctl = own >= 0xd8 && own <= NVN2_CTL_COPY ? own : 0xd8;
        int st = ctl[0x56] == 0 ? 0 : ctl[0x56] == 1 ? 1 : ctl[0x56] == 5 ? 2 : ctl[0x56] == 2 ? 3 : ctl[0x56] == 6 ? 4 : ctl[0x56] == 7 ? 5 : -1;   // 4 / 5 = S2A.Dsh 的 ts / ms（11-05 时之笛 11aa3147be208368 阶段字节 6 不能现编）
        return !*ncode || *ncode >= (1u << 24) ? -1 : st;
    }
    uint32_t w; memcpy(ncode, ctl + 0x704, 4); memcpy(nctl, ctl + 0x20, 4); memcpy(&w, cd + 0x30, 4);
    static const uint8_t gfx_magic[4] = {0x78, 0x56, 0x34, 0x12}; int t = (w >> 10) & 0xf; if (t == 0 && (w & 0x1f) == 1) t = 1;
    int st = memcmp(cd, gfx_magic, 4) ? 2 : t == 1 ? 0 : t == 5 ? 1 : t == 4 ? 3 : -1;
    return !*ncode || *ncode >= (1u << 24) || *nctl < 0x100 || *nctl >= (1u << 20) ? -1 : st;
}

// 缺库的键先登记、到第一次真正用到才现编（10-27 交付线两段式出包）：ProgramSetShaders 时游戏会把它所有的程序一口气建出来（斯普拉遁3 开机 10 秒 1.26 万个），
//   多数一局里根本不画；在那里同步现编，热键版包开机要卡上万次。所以这里只拷下控制段（只在这次调用里有效）记进待编表，
//   等提交线程第一次用这个程序建管线（nvn_mtl.m prog_get）再调 dm_shader_miss_late 现编——那时程序在用，代码区一定有效
typedef struct dsh_pend { struct dsh_pend *next; uint8_t key[8]; int st; uint32_t nctl; uint8_t ctl[]; } dsh_pend;
enum { DSH_PEND_BUCKETS = 4096 };
static dsh_pend *g_dsh_pend[DSH_PEND_BUCKETS]; static pthread_mutex_t g_dsh_pend_mu = PTHREAD_MUTEX_INITIALIZER; static _Atomic uint64_t g_dsh_pend_n;
static unsigned dsh_bucket(const uint8_t key[8]) { uint32_t h; memcpy(&h, key, 4); return h % DSH_PEND_BUCKETS; }
static _Atomic int g_dsh_bad;
// 后台预编（11-07 卡顿线：时之笛开局 12 支计算着色器在提交线程上同步现编约 6 秒、异度3 场景首帧 20 支 + 后来 3 支各卡 1–5 秒）：缺库的键登记时
//   （ProgramSetShaders，读档 / 进场景前）就拷下控制段与代码区、丢进一条串行后台队列开编，产物照常写兜底目录；提交线程第一次用到时（dm_shader_miss_late）：
//   后台已编好 → 按兜底目录复用；正在编 → 等它编完（同键不编两遍）；还在队里没开始 → 取消、当场同步编（不排在别的键后面干等）；后台失败 → 照旧同步再编一次。
//   只预编前 S2A_DSH_EAGER_MAX（开时取 512 之类）个：斯普拉遁3 这类开机登记上万个程序的热键版包，多数一局都不画，其余照旧推迟到第一次用到。
//   C# 现编入口（s2a_dsh_compile）不假定可重入：后台与提交线程的现编共用一把锁 g_dsh_comp_mu
//   11-07 缺省关（S2A_DSH_EAGER_MAX 缺省 0，设 >0 才开）：异度3 冷装读档真机，后台交 512 支、编好 512 支，首遇真用到的 5 支（游戏登记的程序远多于画到的）；
//   C# 翻译器在托管堆上分配，整局 GC 380 次、可玩段停顿最长 77–115 ms（分配闸门红）；不预编的 000eb61e0 局 GC 5 次，首遇同步现编 33 次、多数 3–36 ms、最长 183 ms。
//   时之笛开局那 12 支已随 NDSR 抽取修复进库，预编的原始动机不在了
//   11-07 晚缺省改 256（翻译器关 DebugMode 后分配 −38%，perf/dsh-debugoff）：异度3 冷装测试设备1 两臂同包各一局（xbeager e256_r2 / e0），
//   开场 4 支全「后台预编好」；三处大卡顿 2417→1782、3362→2358、3688→2505 ms；GC 停顿最长 120.6→51.5 ms（次数 109→310、每次短）；OOM / 崩溃 0。
//   剩下的卡顿是帧内载着色器库 + 建管线（110 s 处 8 库 2 管线 1.46 s），不归预编管。设 0 关
typedef struct dsh_job { struct dsh_job *next; uint8_t key[8]; int st; uint32_t nctl, ncode; _Atomic int ref, state; dispatch_semaphore_t done; uint64_t ns; uint8_t *code; uint8_t ctl[]; } dsh_job;
enum { DSH_JOB_QUEUED, DSH_JOB_RUNNING, DSH_JOB_OK, DSH_JOB_FAILED, DSH_JOB_CANCELLED };
static dsh_job *g_dsh_job[DSH_PEND_BUCKETS]; static pthread_mutex_t g_dsh_job_mu = PTHREAD_MUTEX_INITIALIZER, g_dsh_comp_mu = PTHREAD_MUTEX_INITIALIZER;
static void dsh_job_put(dsh_job *j) { if (atomic_fetch_sub(&j->ref, 1) == 1) { free(j->code); free(j); } }
static int dsh_eager_max(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_DSH_EAGER_MAX"); v = e && *e ? atoi(e) : 256; if (v < 0) v = 0; } return v; }
// 在编的输入（#467 植物大战僵尸 和睦小镇：手机上现编时翻译器在某支着色器上 SIGSEGV，整个 App 闪退，崩的是哪支、输入是什么都没留下）：
//   开编前只在内存里记下这支的控制段 / 代码区指针和两个落盘路径（两次 snprintf，不碰盘），翻译器返回后清掉。进程崩了时崩溃处理
//   （runtime/src/crash.c）调 s2a_dsh_crash_dump，用 open / write / close 把它写成兜底目录里的 <键>.inflight.ctl / .code，诊断包（ios/diag.m）带走。
//   正常路径零写盘（首版每支都写盘再删，iPhone 卡顿代价没量过，已撤）。现编整个在 g_dsh_comp_mu 里，同一时刻只有一支在编，一个槽够
static struct { const void *ctl, *cd; size_t nctl, ncode; char pc[1200], pd[1200]; } g_dsh_fly;
static _Atomic int g_dsh_fly_on;
static void dsh_fly_set(const char *out, const char *k, const void *ctl, size_t nctl, const void *cd, size_t ncode) {
    if (!out || !*out || !strcmp(out, "/dev/null")) return;
    snprintf(g_dsh_fly.pc, sizeof g_dsh_fly.pc, "%s/%s.inflight.ctl", out, k); snprintf(g_dsh_fly.pd, sizeof g_dsh_fly.pd, "%s/%s.inflight.code", out, k);
    g_dsh_fly.ctl = ctl; g_dsh_fly.nctl = nctl; g_dsh_fly.cd = cd; g_dsh_fly.ncode = ncode; atomic_store(&g_dsh_fly_on, 1);
}
static void dsh_fly_clear(void) { atomic_store(&g_dsh_fly_on, 0); }
// 崩溃处理里调：只用异步信号安全的 open / write / close，不分配、不加锁、不格式化
void s2a_dsh_crash_dump(void) {
    if (!atomic_load(&g_dsh_fly_on)) return;
    int fd = open(g_dsh_fly.pc, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0) { ssize_t w = write(fd, g_dsh_fly.ctl, g_dsh_fly.nctl); (void)w; close(fd); }
    fd = open(g_dsh_fly.pd, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0) { ssize_t w = write(fd, g_dsh_fly.cd, g_dsh_fly.ncode); (void)w; close(fd); }
}
static int dsh_comp_locked(dsh_comp_fn comp, const char *k, int st, const void *cd, size_t ncode, const void *ctl, size_t nctl, const char *out) {
    pthread_mutex_lock(&g_dsh_comp_mu); dsh_fly_set(out, k, ctl, nctl, cd, ncode);
    int rc = comp(k, st, cd, ncode, ctl, nctl, out);
    dsh_fly_clear(); pthread_mutex_unlock(&g_dsh_comp_mu); return rc;
}
// 变体要的那份源码（审计 #1646 P1-123：输出类型 / 采样器归约 / 顶点补齐三处原先直接调 comp，不拿 g_dsh_comp_mu，后台预编在编时会并发进 C# 现编入口）：
//   锁里再查一次「兜底目录里已有本键源码」——锁外查过没有、等锁期间后台预编刚编完同一个键的，直接用，不重编。返回同 comp（0 = 成功）
static int dsh_comp_src_locked(dsh_comp_fn comp, const char *k, int st, const void *cd, size_t ncode, const void *ctl, size_t nctl, const char *out) {
    pthread_mutex_lock(&g_dsh_comp_mu); int rc = 0;
    if (!dsh_have(out, k)) { dsh_fly_set(out, k, ctl, nctl, cd, ncode); rc = comp(k, st, cd, ncode, ctl, nctl, out); dsh_fly_clear(); }
    pthread_mutex_unlock(&g_dsh_comp_mu); return rc;
}
// Library-resident NVN2 mesh shaders normally bypass fallback translation. Keep only their bounded
// guest inputs under the final bind-time key: Metal may later reject a dynamically paired fragment interface.
typedef struct dsh_mesh_src { struct dsh_mesh_src *next; uint8_t key[8]; uint32_t ncode, nctl; uint8_t bytes[]; } dsh_mesh_src;
enum { DSH_MESH_SRC_BUCKETS = 1024, DSH_MESH_SRC_CAP = 32 * 1024 * 1024 };
static dsh_mesh_src *g_mesh_src[DSH_MESH_SRC_BUCKETS]; static size_t g_mesh_src_bytes; static pthread_mutex_t g_mesh_src_mu = PTHREAD_MUTEX_INITIALIZER;
static unsigned dsh_mesh_bucket(const uint8_t key[8]) { uint32_t h; memcpy(&h, key, 4); return h % DSH_MESH_SRC_BUCKETS; }
void dm_shader_mesh_hold_key(const uint8_t key[8], uint64_t code, const void *control) {
    if (!nvn2_on() || !code || !control || (uintptr_t)control >= (1ull << 47)) return;
    const uint8_t *ctl = control; if (!nvn2_ctl(ctl) || ctl[0x56] != 7) return;
    uint32_t ncode = 0, nctl = 0; memcpy(&ncode, ctl + 0x44, 4); memcpy(&nctl, ctl + 0x30, 4);
    if (!ncode || ncode >= (1u << 24)) return;
    if (nctl < 0xd8 || nctl > NVN2_CTL_COPY) nctl = 0xd8;
    size_t total = (size_t)nctl + ncode; unsigned b = dsh_mesh_bucket(key);
    pthread_mutex_lock(&g_mesh_src_mu);
    for (dsh_mesh_src *e = g_mesh_src[b]; e; e = e->next) if (!memcmp(e->key, key, 8)) { pthread_mutex_unlock(&g_mesh_src_mu); return; }
    pthread_mutex_unlock(&g_mesh_src_mu);
    const char *out = getenv("DM_MSL_FALLBACK"); char k[17];
    int cached = 0;
    if (out && *out) { for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]); cached = dsh_have(out, k); }
    size_t payload = cached ? 0 : total;
    dsh_mesh_src *e = malloc(sizeof *e + payload); if (!e) return;
    memcpy(e->key, key, 8); e->nctl = cached ? 0 : nctl; e->ncode = cached ? 0 : ncode;
    if (!cached) { memcpy(e->bytes, ctl, nctl); memcpy(e->bytes + nctl, (const void *)(uintptr_t)code, ncode); }
    pthread_mutex_lock(&g_mesh_src_mu);
    for (dsh_mesh_src *old = g_mesh_src[b]; old; old = old->next) if (!memcmp(old->key, key, 8)) { pthread_mutex_unlock(&g_mesh_src_mu); free(e); return; }
    size_t saved = sizeof *e + payload;
    if (saved > DSH_MESH_SRC_CAP - g_mesh_src_bytes) { pthread_mutex_unlock(&g_mesh_src_mu); free(e); static _Atomic int warned; if (!atomic_exchange(&warned, 1)) LOG("【红】直连 mesh 源快照达到 %u MiB 上限，后续未缓存键无法生成运行期补齐变体", DSH_MESH_SRC_CAP / (1024 * 1024)); return; }
    e->next = g_mesh_src[b]; g_mesh_src[b] = e; g_mesh_src_bytes += saved;
    pthread_mutex_unlock(&g_mesh_src_mu);
}
void dm_shader_mesh_hold(uint64_t code, const void *control) {
    if (!nvn2_on() || !code || !control || (uintptr_t)control >= (1ull << 47)) return;
    const uint8_t *ctl = control; if (!nvn2_ctl(ctl) || ctl[0x56] != 7) return;
    uint8_t key[8]; if (nvn2_key(ctl, (const void *)(uintptr_t)code, key)) dm_shader_mesh_hold_key(key, code, control);
}
static dsh_mesh_src *dsh_mesh_src_get(const uint8_t key[8]) {
    unsigned b = dsh_mesh_bucket(key); pthread_mutex_lock(&g_mesh_src_mu);
    dsh_mesh_src *e = g_mesh_src[b]; while (e && memcmp(e->key, key, 8)) e = e->next;
    pthread_mutex_unlock(&g_mesh_src_mu); return e && e->ncode ? e : NULL;
}
static void dsh_eager_start(const uint8_t key[8], int st, const uint8_t *cd, uint32_t ncode, const uint8_t *ctl, uint32_t nctl, const char *out) {
    if (atomic_fetch_add(&g_dsh_eager_n, 1) >= (uint64_t)dsh_eager_max()) { atomic_fetch_sub(&g_dsh_eager_n, 1); return; }
    dsh_job *j = calloc(1, sizeof *j + nctl); uint8_t *code = j ? malloc(ncode) : NULL;
    if (!j || !code) { free(j); free(code); atomic_fetch_sub(&g_dsh_eager_n, 1); return; }
    memcpy(j->key, key, 8); j->st = st; j->nctl = nctl; j->ncode = ncode; memcpy(j->ctl, ctl, nctl); memcpy(code, cd, ncode); j->code = code;   // 代码区拷一份：后台开编时游戏可能已换掉那块内存
    j->done = dispatch_semaphore_create(0); atomic_store(&j->ref, 2); atomic_store(&j->state, DSH_JOB_QUEUED);   // 一份给表、一份给后台块
    unsigned b = dsh_bucket(key);
    pthread_mutex_lock(&g_dsh_job_mu); j->next = g_dsh_job[b]; g_dsh_job[b] = j; pthread_mutex_unlock(&g_dsh_job_mu);
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("s2a.dsh.eager", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0)); });
    char *o = strdup(out);
    dispatch_async(q, ^{
        int want = DSH_JOB_QUEUED;
        if (atomic_compare_exchange_strong(&j->state, &want, DSH_JOB_RUNNING)) {
            char k[17]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", j->key[i]);
            dsh_comp_fn comp = dsh_comp(); uint64_t t0 = now_ns();
            int rc = !comp ? -1 : dsh_comp_locked(comp, k, j->st, j->code, j->ncode, j->ctl, j->nctl, o);
            j->ns = now_ns() - t0; atomic_store(&j->state, rc ? DSH_JOB_FAILED : DSH_JOB_OK);
            if (!rc) { uint64_t n = atomic_fetch_add(&g_dsh_eager_ok, 1) + 1; LOG("直连着色器后台预编 %llu 支：%s（%s，%.1f ms）", (unsigned long long)n, k, dsh_nm[j->st], j->ns / 1e6); }
        }
        dispatch_semaphore_signal(j->done); free(o); dsh_job_put(j);
    });
}
static dsh_job *dsh_job_take(const uint8_t key[8]) {   // 从表里取走这个键的后台任务（取走的引用归调用方）
    unsigned b = dsh_bucket(key); pthread_mutex_lock(&g_dsh_job_mu);
    dsh_job **pp = &g_dsh_job[b]; while (*pp && memcmp((*pp)->key, key, 8)) pp = &(*pp)->next;
    dsh_job *j = *pp; if (j) *pp = j->next;
    pthread_mutex_unlock(&g_dsh_job_mu); return j;
}
void dm_shader_miss(const uint8_t key[8], uint64_t code, const void *control) {
    char k[17]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]);
    if (!control || !code) { atomic_fetch_add_explicit(&g_dsh_skipped, 1, memory_order_relaxed); return; }
    if (mtl_shmap_known(k) && mtl_shlib_has(k)) { return; }   // 映射表有、库里没有（热键版包的冷键）照样走现编，见 nvn_mtl.m mtl_shlib_has
    dsh_comp_fn comp = dsh_comp();
    const uint8_t *ctl = control, *cd = (const uint8_t *)(uintptr_t)code; uint32_t ncode, nctl;
    int st = dsh_stage(cd, ctl, &ncode, &nctl);
    if (st >= 0) dsh_dump(k, ctl, nctl, code, ncode);
    if (st < 0 || !comp) { if (!atomic_fetch_add(&g_dsh_bad, 1)) LOG("【红】直连：着色器 %s 不在映射表，不能现编（阶段 %d、代码 %u 字节、控制段 %u 字节）", k, st, ncode, nctl); atomic_fetch_add_explicit(&g_dsh_skipped, 1, memory_order_relaxed); return; }
    const char *out = getenv("DM_MSL_FALLBACK"); if (!out || !*out) { atomic_fetch_add_explicit(&g_dsh_skipped, 1, memory_order_relaxed); return; }
    mkdir(out, 0755);
    if (dsh_have(out, k)) { mtl_shmap_rt_add(k, dsh_nm[st]); atomic_fetch_add_explicit(&g_dsh_reused, 1, memory_order_relaxed); return; }   // 10-24 异度3：第二局把上局编过的键又全编了一遍
    unsigned b = dsh_bucket(key);
    pthread_mutex_lock(&g_dsh_pend_mu);
    dsh_pend *e = g_dsh_pend[b]; while (e && memcmp(e->key, key, 8)) e = e->next;
    int fresh = 0;
    if (!e && (e = malloc(sizeof *e + nctl))) { memcpy(e->key, key, 8); e->st = st; e->nctl = nctl; memcpy(e->ctl, ctl, nctl); e->next = g_dsh_pend[b]; g_dsh_pend[b] = e; atomic_fetch_add_explicit(&g_dsh_pend_n, 1, memory_order_relaxed); fresh = 1; }
    pthread_mutex_unlock(&g_dsh_pend_mu);
    if (fresh) dsh_eager_start(key, st, cd, ncode, ctl, nctl, out);   // 登记即后台开编（有上限，见 dsh_eager_start）
}
// 没登记过的键（帧回放：程序从录像放回、不经 ProgramSetShaders 登记）：兜底目录里有上一局现编过、本机能复用的就按 json 的阶段加进映射，成功返回 1
int dm_shader_reuse(const char *k16) {
    static const char *const js[6] = {"vs", "ps", "cs", "gs", "ts", "ms"};
    const char *out = getenv("DM_MSL_FALLBACK"); char k[17], p[1200], b[8192]; snprintf(k, sizeof k, "%.16s", k16);
    if (!out || !*out || !dsh_have(out, k)) return 0;
    snprintf(p, sizeof p, "%s/%s_b.json", out, k); FILE *f = fopen(p, "r"); if (!f) return 0;
    size_t n = fread(b, 1, sizeof b - 1, f); fclose(f); b[n] = 0;
    for (int st = 0; st < 6; st++) if (dsh_json_eq(b, "stage", js[st])) { mtl_shmap_rt_add(k, dsh_nm[st]); atomic_fetch_add_explicit(&g_dsh_reused, 1, memory_order_relaxed); return 1; }
    return 0;
}
// 第一次用到（提交线程建程序时库里没有这支）：待编表里有就现编，成功返回 1（映射已加，调用方再装载一次）；没登记过 / 现编失败返回 0。code：在用程序的代码区
// control：在用程序的控制段。Switch 2 用：NVN2 的键到第一次用到才算（hle_nvn.c keys_hash），SetShaders 时没登记进待编表，这里按在用控制段登记（Switch 1 不走这里）。
//   → 1 上局编过、映射已加（*e 不动）；0 *e = 新的待编项；-1 编不了（已报 / 已计数）
static int dsh_nvn2_pend(const uint8_t key[8], const char *k, uint64_t code, const void *control, dsh_pend **pe) {
    uint32_t ncode, nctl; int st = dsh_stage((const uint8_t *)(uintptr_t)code, control, &ncode, &nctl);
    if (st < 0 || !dsh_comp()) {
        if (!atomic_fetch_add(&g_dsh_bad, 1)) LOG("【红】直连：Switch 2 着色器 %s 不在库里，不能现编（阶段字节 %u、代码 %u 字节）", k, ((const uint8_t *)control)[0x56], ncode);
        atomic_fetch_add_explicit(&g_dsh_skipped, 1, memory_order_relaxed); return -1;
    }
    dsh_dump(k, control, nctl, code, ncode);
    const char *out = getenv("DM_MSL_FALLBACK");
    if (!out || !*out) { atomic_fetch_add_explicit(&g_dsh_skipped, 1, memory_order_relaxed); return -1; }
    mkdir(out, 0755);
    if (dsh_have(out, k)) { mtl_shmap_rt_add(k, dsh_nm[st]); atomic_fetch_add_explicit(&g_dsh_reused, 1, memory_order_relaxed); return 1; }
    dsh_pend *e = malloc(sizeof *e + nctl); if (!e) return -1;
    memcpy(e->key, key, 8); e->st = st; e->nctl = nctl; memcpy(e->ctl, control, nctl); e->next = NULL; *pe = e;
    return 0;
}
// 同一 NVN2 键只试一次（成功后映射已加、失败照旧报红，都不再进这里）
static int dsh_nvn2_first(const uint8_t key[8]) {
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static uint64_t *seen; static size_t nseen, cap;
    uint64_t kk; memcpy(&kk, key, 8); int first = 1;
    pthread_mutex_lock(&mu);
    for (size_t i = 0; i < nseen; i++) if (seen[i] == kk) { first = 0; break; }
    if (first && nseen == cap) { size_t nc = cap ? cap * 2 : 256; uint64_t *ns = realloc(seen, nc * sizeof *ns); if (ns) { seen = ns; cap = nc; } else first = 0; }
    if (first) seen[nseen++] = kk;
    pthread_mutex_unlock(&mu);
    return first;
}
int dm_shader_miss_late(const char *k16, uint64_t code, const void *control) {
    uint8_t key[8]; for (int i = 0; i < 8; i++) { unsigned v; if (sscanf(k16 + 2 * i, "%2x", &v) != 1) return 0; key[i] = (uint8_t)v; }
    char k[17]; snprintf(k, sizeof k, "%.16s", k16);
    unsigned b = dsh_bucket(key);
    pthread_mutex_lock(&g_dsh_pend_mu);
    dsh_pend **pp = &g_dsh_pend[b]; while (*pp && memcmp((*pp)->key, key, 8)) pp = &(*pp)->next;
    dsh_pend *e = *pp; if (e) *pp = e->next;   // 取出：同一键只编一次，失败也不再试（失败照旧报红、画面缺这支）
    pthread_mutex_unlock(&g_dsh_pend_mu);
    if (!e) {
        // 兜底目录里已有同链同翻译器指纹的产物：直接复用，不碰控制段。帧回放放回的程序不经 ProgramSetShaders，control 是录时的宿主指针（已失效），
        //   原先先读它（nvn2_ctl）再看兜底目录，Switch 2 录像一放就 SIGBUS（11-04 Pokopia f6000：dm_shader_miss_late+0x158）；现场局里同样先复用，结果不变（dsh_nvn2_pend 也是先查 dsh_have）
        if (dm_shader_reuse(k)) return 1;
        if (!control || !code || !nvn2_on() || !nvn2_ctl(control) || !dsh_nvn2_first(key)) return 0;
        int r = dsh_nvn2_pend(key, k, code, control, &e);
        if (r) return r > 0;
    }
    const char *out = getenv("DM_MSL_FALLBACK"); uint32_t ncode;
    dsh_job *j = dsh_job_take(key);
    if (j) {   // 登记时已交后台：没开始就取消、当场同步编；在编就等；编好就复用兜底目录（见 dsh_eager_start）
        int want = DSH_JOB_QUEUED; uint64_t w0 = now_ns();
        if (atomic_compare_exchange_strong(&j->state, &want, DSH_JOB_CANCELLED)) atomic_fetch_add(&g_dsh_eager_cancel, 1);
        else {
            if (atomic_load(&j->state) == DSH_JOB_RUNNING) { dispatch_semaphore_wait(j->done, DISPATCH_TIME_FOREVER); atomic_fetch_add(&g_dsh_eager_waited, 1); }
            int ok = atomic_load(&j->state) == DSH_JOB_OK && out && *out && dsh_have(out, k);
            if (ok) {
                int st = e->st; free(e); dsh_job_put(j);
                mtl_shmap_rt_add(k, dsh_nm[st]); atomic_fetch_add(&g_dsh_eager_hit, 1);
                uint64_t n = atomic_fetch_add_explicit(&g_dsh_ok, 1, memory_order_relaxed) + 1;
                LOG("直连着色器首遇现编 %llu 次：%s（%s，后台预编好，提交线程等 %.1f ms）", (unsigned long long)n, k, dsh_nm[st], (now_ns() - w0) / 1e6);
                return 1;
            }
        }
        dsh_job_put(j);   // 取消 / 后台失败：照旧同步编
    }
    if (nvn2_on() && nvn2_ctl(e->ctl)) memcpy(&ncode, e->ctl + 0x44, 4); else memcpy(&ncode, e->ctl + 0x704, 4);
    const uint8_t *cd = (const uint8_t *)(uintptr_t)code; dsh_comp_fn comp = dsh_comp();
    int rc = !code || !out || !*out || !comp ? -1 : 0;
    uint64_t t0 = now_ns(); if (!rc) rc = dsh_comp_locked(comp, k, e->st, cd, ncode, e->ctl, e->nctl, out);
    // 翻译器报错（rc > 0：编了、没编出来）：不管开没开 DM_NVN_SHDUMP，都把这支的控制段 / 代码区存进兜底目录 <键>.fail.ctl / .fail.code。翻译器的确定性 bug 修前要能在本机复现，
    //   而这类着色器多是运行时才遇到的（不在离线着色器表里），没有输入就只能请玩家开开关重走（#442 夜之仪式：切场景后 4 支计算着色器越界，帧率跌到 6 帧）。只在失败时写，每键一次
    if (rc > 0 && out && *out && strcmp(out, "/dev/null")) {
        char fp[1200]; FILE *f;
        snprintf(fp, sizeof fp, "%s/%s.fail.ctl", out, k); if ((f = fopen(fp, "wb"))) { fwrite(e->ctl, 1, e->nctl, f); fclose(f); }
        snprintf(fp, sizeof fp, "%s/%s.fail.code", out, k); if ((f = fopen(fp, "wb"))) { fwrite(cd, 1, ncode, f); fclose(f); }
        LOG("直连着色器现编失败的输入已存：%s/%s.fail.ctl / .fail.code（控制段 %u 字节、代码区 %u 字节；反馈问题时请附上）", out, k, e->nctl, ncode);
    }
    int st = e->st; free(e);
    if (rc) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); atomic_fetch_add(&g_dsh_bad, 1); LOG("【红】直连着色器现编失败：%s（%s）rc=%d", k, dsh_nm[st], rc); return 0; }
    mtl_shmap_rt_add(k, dsh_nm[st]);
    uint64_t n = atomic_fetch_add_explicit(&g_dsh_ok, 1, memory_order_relaxed) + 1;
    LOG("直连着色器首遇现编 %llu 次：%s（%s，%.1f ms）", (unsigned long long)n, k, dsh_nm[st], (now_ns() - t0) / 1e6);
    return 1;
}

// 变体不比它的源码旧（同一秒内的修改时间按纳秒比；源码重编过，旧变体就作废）
static int dsh_variant_newer(const char *variant, const char *base) {
    struct stat a, b; if (stat(variant, &a) || stat(base, &b)) return 0;
    return a.st_mtimespec.tv_sec > b.st_mtimespec.tv_sec || (a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec >= b.st_mtimespec.tv_nsec);
}
// 兜底目录里的 <键>_t<u>_<s>.metal 能不能直接载（nvn_mtl.m fs_typed_fn，后台预建也走这里）：源码 <键>_b 是本机翻译链的（dsh_have），且变体不比源码旧。
//   翻译链变了或源码重编过，旧变体的绑定布局可能和本局的反射对不上——画错还不报红，所以不载、记一行，建管线失败时 dm_shader_fout 重出
int dm_shader_fout_fresh(const char *key16, uint32_t umask, uint32_t smask) {
    const char *out = getenv("DM_MSL_FALLBACK"); if (!out || !*out) return 0;
    char k[17], base[1200], var[1200]; snprintf(k, sizeof k, "%.16s", key16);
    snprintf(var, sizeof var, "%s/%s_t%x_%x.metal", out, k, umask, smask);
    if (access(var, R_OK)) return 0;
    snprintf(base, sizeof base, "%s/%s_b.metal", out, k);
    if (dsh_have(out, k) && dsh_variant_newer(var, base)) return 1;
    LOG("直连片元输出类型变体：%s u=%#x s=%#x 是别的翻译链或比源码旧，不载、重出", k, umask, smask);
    return 0;
}

// 建管线时画布的整数格式和库里的片元入口对不上（nvn_mtl.m pso_fout_variant；10-24 异度3 G-buffer 浮点 / 整数画布混用）：兜底目录里先要有这个键的 <键>_b.metal
//   （库里的着色器此时才现编一份源码，不登记进映射旁表：建库照旧走库），再出逐位置定类型的 <键>_t<u>_<s>.metal（S2A.Dsh FsTyped；比源码旧就重出）。成功 0、path = 变体源码
int dm_shader_fout(const uint8_t key[8], uint64_t code, const void *control, uint32_t umask, uint32_t smask, char *path, size_t n) {
    char k[17]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]);
    static int (*fv)(const char *, uint32_t, uint32_t, const char *); static dispatch_once_t once;
    dispatch_once(&once, ^{ fv = (int (*)(const char *, uint32_t, uint32_t, const char *))dlsym(RTLD_DEFAULT, "s2a_dsh_fout_variant"); });
    dsh_comp_fn comp = dsh_comp(); const char *out = getenv("DM_MSL_FALLBACK"); uint32_t ncode = 0, nctl = 0;
    int st = control && code ? dsh_stage((const uint8_t *)(uintptr_t)code, control, &ncode, &nctl) : -1;
    if (!comp || !fv || !out || !*out || st != 1) { LOG("【红】直连：片元 %s 要输出类型变体 u=%#x s=%#x，做不了（%s）", k, umask, smask, !comp || !fv ? "S2A.Aot 没链进来" : !out || !*out ? "没设 DM_MSL_FALLBACK" : "不是片元或长度不对"); return 1; }
    mkdir(out, 0755);
    char base[1200]; snprintf(base, sizeof base, "%s/%s_b.metal", out, k);
    int fresh = !dsh_have(out, k);
    if (fresh && dsh_comp_src_locked(comp, k, st, (const void *)(uintptr_t)code, ncode, control, nctl, out)) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); LOG("【红】直连：片元 %s 现编源码失败，出不了输出类型变体", k); return 1; }
    snprintf(path, n, "%s/%s_t%x_%x.metal", out, k, umask, smask);
    if ((fresh || !dsh_variant_newer(path, base)) && fv(base, umask, smask, path)) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); return 1; }
    atomic_fetch_add_explicit(&g_dsh_typed, 1, memory_order_relaxed);
    LOG("直连片元输出类型变体：%s u=%#x s=%#x", k, umask, smask);
    return 0;
}

// 采样器归约变体（#800；nvn_mtl.m se_kick / se_build）：本机 GPU 缺原生归约（非 Apple10）、绘制又真绑了 min / max 采样器时要它（偏置不出变体：主体 main0 自己加，lb_fill）。
//   离线库不带（10-29 夜：动森 / 马车8 真绑的 0 支，静态全集却让动森库 +75%），首遇时在设备上出、缺省在后台线程（code / control 是 dm_shader_snap 的拷贝）：
//   兜底目录里先要有这个键的 <键>_b.metal（库里的着色器此时才现编一份源码，同 dm_shader_fout），再出 <键>_se.metal（S2A.Dsh FsRd；比源码旧就重出）。
//   成功 0、path = 变体源码；main0 里没有能归约的采样 3；做不了 1
int dm_shader_se(const uint8_t key[8], uint64_t code, const void *control, char *path, size_t n) {
    char k[17]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]);
    static int (*fv)(const char *, const char *); static dispatch_once_t once;
    dispatch_once(&once, ^{ fv = (int (*)(const char *, const char *))dlsym(RTLD_DEFAULT, "s2a_dsh_samp_emu"); });
    dsh_comp_fn comp = dsh_comp(); const char *out = getenv("DM_MSL_FALLBACK"); uint32_t ncode = 0, nctl = 0;
    int st = control && code ? dsh_stage((const uint8_t *)(uintptr_t)code, control, &ncode, &nctl) : -1;
    if (!comp || !fv || !out || !*out || (st != 1 && st != 2)) { LOG("【红】直连：%s 要采样器模拟变体，做不了（%s）", k, !comp || !fv ? "S2A.Aot 没链进来" : !out || !*out ? "没设 DM_MSL_FALLBACK" : "不是片元 / 计算或长度不对"); return 1; }
    mkdir(out, 0755);
    char base[1200]; snprintf(base, sizeof base, "%s/%s_b.metal", out, k);
    int fresh = !dsh_have(out, k);
    if (fresh && dsh_comp_src_locked(comp, k, st, (const void *)(uintptr_t)code, ncode, control, nctl, out)) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); LOG("【红】直连：%s 现编源码失败，出不了采样器模拟变体", k); return 1; }
    snprintf(path, n, "%s/%s_se.metal", out, k);
    if (!fresh && dsh_variant_newer(path, base)) return 0;
    int rc = fv(base, path);
    if (rc == 3) return 3;
    if (rc) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); return 1; }
    LOG("直连采样器模拟变体：%s（%s）", k, dsh_nm[st]);
    return 0;
}
// 顶点着色器补齐变体（nvn_mtl.m vp_kick / vp_build）：运行期配上的片元着色器要读这支不写的 user(locn)（mask 位 n = locn），Metal 拒建这对管线。
//   出包时的配对表覆盖不全（游戏按阶段拼程序），以前只能这局跳过这笔绘制、记进 pso_user.tsv 等下次出包补（vs_pad），玩家拿到的包永远补不上。
//   现在首遇时在设备上出：兜底目录里先要有这个键的 <键>_b.metal（库里的着色器此时才现编一份源码，同 dm_shader_se），再出 <键>_vp<掩码>.metal（S2A.Dsh VsPadMask，
//   补 (0,0,0,1)，同离线 vs_pad；比源码旧就重出）。成功 0、path = 变体源码；没什么可补 3；做不了 1
#include "mesh_pad.h"   // dm_mesh_pad_src：网格着色器补齐（#674）
static int mesh_pad_file(const char *base, uint32_t mask, const char *path) {
    FILE *f = fopen(base, "rb"); if (!f) return 1;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET); char *src = sz > 0 ? malloc((size_t)sz + 1) : NULL;
    if (!src || fread(src, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); free(src); return 1; } fclose(f); src[sz] = 0;
    char *o = NULL; int rc = dm_mesh_pad_src(src, mask, &o); free(src); if (rc) return rc;
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.tmp", path); f = fopen(tmp, "wb");   // 先写临时文件再改名：别的线程 / 下一局只会看到完整的
    size_t len = strlen(o); int ok = f && fwrite(o, 1, len, f) == len; if (f) ok = !fclose(f) && ok; free(o);
    return ok && !rename(tmp, path) ? 0 : 1;
}
int dm_shader_vpad(const uint8_t key[8], uint64_t code, const void *control, uint32_t mask, char *path, size_t n) {
    char k[17]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]);
    static int (*fv)(const char *, uint32_t, const char *); static dispatch_once_t once;
    dispatch_once(&once, ^{ fv = (int (*)(const char *, uint32_t, const char *))dlsym(RTLD_DEFAULT, "s2a_dsh_vs_pad"); });
    dsh_comp_fn comp = dsh_comp(); const char *out = getenv("DM_MSL_FALLBACK"); uint32_t ncode = 0, nctl = 0;
    int st = control && code ? dsh_stage((const uint8_t *)(uintptr_t)code, control, &ncode, &nctl) : -1;
    if (!comp || (st == 0 && !fv) || !out || !*out || (st != 0 && st != 5)) { LOG("【红】直连：%s %s 要补齐变体 %#x，做不了（%s）", st == 5 ? "网格" : "顶点", k, mask, !comp || !fv ? "S2A.Aot 没链进来" : !out || !*out ? "没设 DM_MSL_FALLBACK" : "不是顶点 / 网格着色器或认不出"); return 1; }   // 5 = 网格（dsh_stage），宿主侧改文本补（dm_mesh_pad_src）
    mkdir(out, 0755);
    char base[1200]; snprintf(base, sizeof base, "%s/%s_b.metal", out, k);
    int fresh = !dsh_have(out, k);
    if (fresh && dsh_comp_src_locked(comp, k, st, (const void *)(uintptr_t)code, ncode, control, nctl, out)) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); LOG("【红】直连：顶点 %s 现编源码失败，出不了补齐变体", k); return 1; }
    snprintf(path, n, "%s/%s_vp%x.metal", out, k, mask);
    if (!fresh && dsh_variant_newer(path, base)) return 0;
    int rc = st == 5 ? mesh_pad_file(base, mask, path) : fv(base, mask, path);
    if (rc == 3) return 3;
    if (rc) { atomic_fetch_add_explicit(&g_dsh_failed, 1, memory_order_relaxed); return 1; }
    LOG("直连%s补齐变体：%s 补 user(locn) 掩码 %#x", st == 5 ? "网格" : "顶点", k, mask);
    return 0;
}
// Mesh shader whose guest control/code has expired can still be padded from this device's
// chain- and translator-matched translation. The caller must establish mesh_kind == 2.
int dm_shader_vpad_cached_mesh(const uint8_t key[8], uint32_t mask, char *path, size_t n) {
    char k[17], base[1200]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]);
    const char *out = getenv("DM_MSL_FALLBACK");
    if (!out || !*out) return 1;
    if (!dsh_have(out, k)) {
        dsh_mesh_src *src = dsh_mesh_src_get(key); dsh_comp_fn comp = dsh_comp();
        if (!src || !comp) { static _Atomic int missing; if (!atomic_exchange(&missing, 1)) LOG("【红】直连 mesh 补齐：%s 没有 SetShaders 时同键源码快照（NVN2 首遇键可能与 SetShaders 时不同）", k); return 1; }
        if (dsh_comp_src_locked(comp, k, 5, src->bytes + src->nctl, src->ncode, src->bytes, src->nctl, out)) return 1;
        LOG("直连网格基础源码：%s 首次配对失败时按需翻译", k);
    }
    if (!dsh_have(out, k)) return 1;
    snprintf(base, sizeof base, "%s/%s_b.metal", out, k);
    char meta[1200], b[8192]; snprintf(meta, sizeof meta, "%s/%s_b.json", out, k);
    FILE *f = fopen(meta, "r"); if (!f) return 1;
    size_t z = fread(b, 1, sizeof b - 1, f); fclose(f); b[z] = 0;
    if (!dsh_json_eq(b, "stage", "ms")) return 1;
    snprintf(path, n, "%s/%s_vp%x.metal", out, k, mask);
    if (dsh_variant_newer(path, base)) return 0;
    int rc = mesh_pad_file(base, mask, path); if (rc) return rc;
    LOG("直连网格补齐变体：%s 从本机同链同指纹源码缓存补 user(locn) 掩码 %#x", k, mask);
    return 0;
}
// 后台出归约变体用的拷贝（nvn_mtl.m se_kick）：控制段只在 SetShaders 里保证有效、代码区游戏也可能另用，提交线程上先整份拷下（控制段在前、代码区在后），
//   后台拿拷贝调 dm_shader_se（它只读 [code, code + 代码长) 与控制段）。*code_out / *control_out 指进返回的那块，调用方 free；NULL = 不是认得的着色器或内存不够
void *dm_shader_snap(uint64_t code, const void *control, uint64_t *code_out, const void **control_out) {
    uint32_t ncode = 0, nctl = 0;
    if (!code || !control || dsh_stage((const uint8_t *)(uintptr_t)code, control, &ncode, &nctl) < 0) return NULL;
    uint8_t *b = malloc((size_t)nctl + ncode); if (!b) return NULL;
    memcpy(b, control, nctl); memcpy(b + nctl, (const void *)(uintptr_t)code, ncode);
    *control_out = b; *code_out = (uint64_t)(uintptr_t)(b + nctl); return b;
}
// 兜底目录里的 <键>_se.metal 能不能直接载（nvn_mtl.m se_build，后台预建 se_warm 也走这里）：源码 <键>_b 是本机翻译链的（dsh_have），且变体不比源码旧（同 dm_shader_fout_fresh）。
//   变体格式（文件头一行）由 se_fn 再核
int dm_shader_se_fresh(const char *key16) {
    const char *out = getenv("DM_MSL_FALLBACK"); if (!out || !*out) return 0;
    char k[17], base[1200], var[1200]; snprintf(k, sizeof k, "%.16s", key16);
    snprintf(var, sizeof var, "%s/%s_se.metal", out, k);
    if (access(var, R_OK)) return 0;
    snprintf(base, sizeof base, "%s/%s_b.metal", out, k);
    if (dsh_have(out, k) && dsh_variant_newer(var, base)) return 1;
    LOG("直连采样器模拟变体：%s 是别的翻译链或比源码旧，不载、重出", k);
    return 0;
}
