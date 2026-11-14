// 包含生产现编接点，仅替换编译器、映射和日志依赖；不需要 GPU 或游戏。
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
#include "../../../runtime/include/s2a_gfx_mode.h"
static int known, inlib = 1, compile_rc, mode = S2A_GFX_DIRECT, missing, noxfp;
#define XFP "0123456789abcdef"   // 本测的「本机现编库指纹」（s2a_dsh_xfp 桩返回它）
static _Atomic int compiler_calls, variant_calls, se_calls, vp_calls; static int se_rc, vp_rc; static uint32_t vp_mask;
static void (*registered)(int);
void s2a_direct_summary_register(void (*fn)(int)) { registered = fn; }
int s2a_gfx_mode(void) { return mode; }
int mtl_shmap_known(const char *key) { (void)key; return known; }
int mtl_shlib_has(const char *key) { (void)key; return inlib; }
static char rt_stage[16];   // 最近一次 mtl_shmap_rt_add 的阶段名（32 / 33 核）
void mtl_shmap_rt_add(const char *key, const char *stage) { (void)key; snprintf(rt_stage, sizeof rt_stage, "%s", stage); }
void mtl_se_stats(uint64_t out[2]) { out[0] = out[1] = 0; }   // 采样器模拟变体计数（nvn_mtl.m）：本测不建变体
void mtl_vp_stats(uint64_t out[2]) { out[0] = out[1] = 0; }   // 顶点补齐变体计数（nvn_mtl.m）：本测不建变体
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec; }
static int compiled_stage = -1;   // 最近一次交给 S2A.Dsh 的阶段号（34–36 核 NVN2 任务 / 网格 = 4 / 5）
static const char *chain_name(void);   // DMSH_CHAIN（dmsh_chain.h 随 dsh_miss.inc 在下面才包含）
static int write_out, slow_first;   // 39–41（后台预编）：编译器桩真把产物写进兜底目录（dsh_have 认它）；41：键 0 编得慢（让排在它后面的键停在队里）
static _Atomic int in_comp, overlap;   // 42：C# 现编入口不可重入，同时有两个调用在里面就计一次
static int compiler_(const char *key, int stage, const char *out);
static int crash_in_comp;   // 44：替身翻译器编到一半崩（真 SIGSEGV），看崩溃处理落没落下输入
static int compiler(const char *key, int stage, const void *code, size_t nc, const void *ctl, size_t nt, const char *out) {
    (void)code; (void)nc; (void)ctl; (void)nt;
    if (crash_in_comp) *(volatile int *)(uintptr_t)8 = 1;   // 同 #467 现场：读写 0x8 段错误
    if (atomic_fetch_add(&in_comp, 1)) atomic_fetch_add(&overlap, 1);
    int rc_ = compiler_(key, stage, out); atomic_fetch_sub(&in_comp, 1); return rc_;
}
static int compiler_(const char *key, int stage, const char *out) {
    compiled_stage = stage; atomic_fetch_add(&compiler_calls, 1);   // 先计数再慢：41 据此知道键 0 已在编（键 1 还在队里）
    if (slow_first && !strcmp(key, "0000000000000000")) usleep(300000);
    if (write_out && !compile_rc && out && strcmp(out, "/dev/null")) {
        char p[1200]; FILE *f; snprintf(p, sizeof p, "%s/%s_b.metal", out, key); if ((f = fopen(p, "w"))) {
            if (stage == 5) fputs("struct dm_vertex_t {\n    float4 position [[position]];\n};\nstruct dm_prim_t {\n};\nvoid main0() {\n        dm_vertex_t v;\n}\n", f);
            fclose(f);
        }
        snprintf(p, sizeof p, "%s/%s_b.json", out, key); if ((f = fopen(p, "w"))) { fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\",\n \"stage\": \"%s\"\n}\n", chain_name(), stage == 5 ? "ms" : "cs"); fclose(f); }
    }
    return compile_rc;
}
static int variant(const char *in, uint32_t u, uint32_t s, const char *out) { (void)in; (void)u; (void)s; (void)out; atomic_fetch_add(&variant_calls, 1); return 0; }
static int se_variant(const char *in, const char *out) { (void)in; (void)out; atomic_fetch_add(&se_calls, 1); return se_rc; }
static int vp_variant(const char *in, uint32_t m, const char *out) { (void)in; (void)out; vp_mask = m; atomic_fetch_add(&vp_calls, 1); return vp_rc; }
static const char *xfp(void) { return XFP; }
static void *fake_dlsym(void *handle, const char *name) { (void)handle; return missing ? NULL : !strcmp(name, "s2a_dsh_xfp") ? (noxfp ? NULL : (void *)xfp) : !strcmp(name, "s2a_dsh_fout_variant") ? (void *)variant : !strcmp(name, "s2a_dsh_samp_emu") ? (void *)se_variant : !strcmp(name, "s2a_dsh_vs_pad") ? (void *)vp_variant : (void *)compiler; }
// 捕获固定汇总行；逐次成功/红行仍经生产调用，只在本依赖桩中不打印。
static void fixture_log(const char *fmt, ...) {
    if (strncmp(fmt, "直连着色器现编汇总：", strlen("直连着色器现编汇总："))) return;
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); putchar('\n');
}
#define dlsym fake_dlsym
#define LOG(...) fixture_log(__VA_ARGS__)
#include "../gfx/nvn/nvn2.h"   // dsh_miss.inc 认 Switch 2 控制段；34–37 是 Switch 2 场景（nvn2_on 桩返回 nvn2），其余 Switch 1
static int nvn2;
int nvn2_on(void) { return nvn2; }
int nvn2_key(const void *control, const void *code, uint8_t out[8]) { (void)code; if (!control) return 0; memcpy(out, (const uint8_t *)control + 0x20, 8); return 1; }
#include "../host/dsh_miss.inc"
static const char *chain_name(void) { return DMSH_CHAIN; }
#undef dlsym
static uint8_t ctl[0x880], code[0x100], key[8];
static void late(void) { dm_shader_miss_late("0000000000000000", (uint64_t)(uintptr_t)code, NULL); }
static void call(void) { dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl); late(); }   // 建程序（登记）+ 第一次用到（现编）
static void *many(void *arg) { for (int i = 0; i < (int)(intptr_t)arg; i++) dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl); return NULL; }   // 多线程只建程序
static void check(int ok) { if (!ok) _exit(40); }
static void crash_handler44(int sig) { (void)sig; s2a_dsh_crash_dump(); _exit(0); }   // 照 crash.c：原始现场后调 s2a_dsh_crash_dump
static void scenario(int n) {
    alarm(10); setvbuf(stdout, NULL, _IONBF, 0);
    setenv("S2A_DSH_EAGER_MAX", n >= 39 ? "8" : "0", 1);   // 0–38 是登记时不编的旧语义（后台预编关）；39–41 测后台预编
    uint32_t size = sizeof code, csize = sizeof ctl;
    memcpy(ctl + 0x704, &size, 4); memcpy(ctl + 0x20, &csize, 4);
    setenv("DM_MSL_FALLBACK", "/dev/null", 1); // 编译器桩不写文件。
    check(registered != NULL);
    if (n == 1) call();
    if (n == 2) { compile_rc = 7; call(); }
    if (n == 43) {   // #442：翻译器报错时，控制段 / 代码区自动存进兜底目录 <键>.fail.ctl / .fail.code（不开 DM_NVN_SHDUMP），内容逐字节等于交给翻译器的那份
        char d[] = "/tmp/t_dsh_failXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1); unsetenv("DM_NVN_SHDUMP");
        for (int i = 0x40; i < 0x80; i++) ctl[i] = (uint8_t)i; for (int i = 0x40; i < 0x80; i++) code[i] = (uint8_t)(0xff - i);
        compile_rc = 7; call();
        uint8_t got[sizeof ctl]; FILE *f;
        snprintf(p, sizeof p, "%s/0000000000000000.fail.ctl", d); f = fopen(p, "rb"); check(f != NULL); check(fread(got, 1, sizeof got, f) == sizeof ctl); fclose(f); check(!memcmp(got, ctl, sizeof ctl)); unlink(p);
        snprintf(p, sizeof p, "%s/0000000000000000.fail.code", d); f = fopen(p, "rb"); check(f != NULL); check(fread(got, 1, sizeof got, f) == sizeof code); fclose(f); check(!memcmp(got, code, sizeof code)); unlink(p);
        rmdir(d);
    }
    if (n == 44) {   // #467：正常编完不写盘；编到一半崩了，崩溃处理（这里装的处理函数照 crash.c 调 s2a_dsh_crash_dump）把输入落盘成 <键>.inflight.*，逐字节同交给翻译器的那份
        char d[] = "/tmp/t_dsh_inflXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1); unsetenv("DM_NVN_SHDUMP");
        for (int i = 0x40; i < 0x80; i++) ctl[i] = (uint8_t)(i ^ 0x5a); for (int i = 0x40; i < 0x80; i++) code[i] = (uint8_t)(i * 3);
        struct stat sb; char pc[256], pd[256]; snprintf(pc, sizeof pc, "%s/0000000000000000.inflight.ctl", d); snprintf(pd, sizeof pd, "%s/0000000000000000.inflight.code", d);
        pid_t c = fork();
        if (!c) { struct sigaction sa = {0}; sa.sa_handler = (void (*)(int))(void *)crash_handler44; sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
                  crash_in_comp = 1; compile_rc = 0; call(); _exit(3); }   // 走到这里 = 没崩
        int st; waitpid(c, &st, 0); check(WIFEXITED(st) && WEXITSTATUS(st) == 0);
        uint8_t got[sizeof ctl]; FILE *f;
        f = fopen(pc, "rb"); check(f != NULL); check(fread(got, 1, sizeof got, f) == sizeof ctl); fclose(f); check(!memcmp(got, ctl, sizeof ctl)); unlink(pc);
        f = fopen(pd, "rb"); check(f != NULL); check(fread(got, 1, sizeof got, f) == sizeof code); fclose(f); check(!memcmp(got, code, sizeof code)); unlink(pd);
        crash_in_comp = 0; compile_rc = 0; call(); check(stat(pc, &sb) != 0 && stat(pd, &sb) != 0);   // 正常编完：不落盘
        rmdir(d);
    }
    if (n == 3) {
        dm_shader_miss(key, 0, NULL);
        const uint8_t magic[] = {0x78,0x56,0x34,0x12}; memcpy(code, magic, 4);
        uint32_t stage = 8 << 10; memcpy(code + 0x30, &stage, 4); call();
        uint32_t zero = 0; memcpy(ctl + 0x704, &zero, 4); call();
    }
    if (n == 4) { missing = 1; call(); }
    if (n == 5) { unsetenv("DM_MSL_FALLBACK"); call(); }
    if (n == 6) mode = S2A_GFX_GENERIC;
    if (n == 7) {
        pthread_t t[4];
        for (int i = 0; i < 4; i++) check(!pthread_create(t + i, NULL, many, (void *)1000));
        for (int i = 0; i < 4; i++) check(!pthread_join(t[i], NULL));
        check(atomic_load(&compiler_calls) == 0); late(); late(); check(atomic_load(&compiler_calls) == 1);   // 4000 次登记同一键 → 首遇只编一次
    }
    if (n == 9) { known = 1; call(); check(atomic_load(&compiler_calls) == 0); }
    if (n == 18) { dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl); check(atomic_load(&compiler_calls) == 0); late(); check(atomic_load(&compiler_calls) == 1); }   // 建程序时不编，第一次用到才编
    if (n == 17) { known = 1; inlib = 0; call(); check(atomic_load(&compiler_calls) == 1); }   // 映射表有、库里没有（热键版包的冷键）：照样现编
    if (n == 10 || n == 11 || (n >= 29 && n <= 31)) {   // 上局编过：同链同指纹复用、不调编译器；链不同（11）/ 指纹不同（29）/ json 没有 xfp（30）/ 没链 s2a_dsh_xfp（31）重编
        char d[] = "/tmp/t_dsh_reuseXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); FILE *f = fopen(p, "w"); check(f != NULL); fclose(f);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"key\": \"0000000000000000_b\",\n \"chain\": \"%s\"%s\n}\n", n == 11 ? "000000000000" : DMSH_CHAIN,
                n == 29 ? ",\n \"xfp\": \"0123456789abcdee\"" : n == 30 ? "" : ",\n \"xfp\": \"" XFP "\""); fclose(f);
        if (n == 31) noxfp = 1;
        call(); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
        check(atomic_load(&compiler_calls) == (n != 10));
    }
    if (n == 12 || n == 13) {   // 输出类型变体：片元先现编源码、再出变体，路径按掩码；不是片元（计算着色器的代码区）拒绝、两个桩都不调
        if (n == 12) { const uint8_t magic[] = {0x78,0x56,0x34,0x12}; memcpy(code, magic, 4); uint32_t ps = 5 << 10; memcpy(code + 0x30, &ps, 4); }
        char d[] = "/tmp/t_dsh_foutXXXXXX", path[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        int rc = dm_shader_fout(key, (uint64_t)(uintptr_t)code, ctl, 0x4, 0x2, path, sizeof path); rmdir(d);
        char want[256]; snprintf(want, sizeof want, "%s/0000000000000000_t4_2.metal", d);
        check(n == 12 ? rc == 0 && !strcmp(path, want) && compiler_calls == 1 && variant_calls == 1 : rc != 0 && compiler_calls == 0 && variant_calls == 0);
    }
    if (n >= 14 && n <= 16) {   // 兜底目录里的变体能不能直接载：14 同链、变体比源码新 → 能；15 源码是别的链 → 不能；16 变体比源码旧 → 不能
        char d[] = "/tmp/t_dsh_freshXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        const char *names[] = {"0000000000000000_b.metal", "0000000000000000_t4_0.metal"};
        for (int k = 0; k < 2; k++) { snprintf(p, sizeof p, "%s/%s", d, names[k]); FILE *f = fopen(p, "w"); check(f != NULL); fclose(f);
            struct timeval tv[2] = {{1000 + (k ^ (n == 16)) * 10, 0}, {1000 + (k ^ (n == 16)) * 10, 0}}; check(!utimes(p, tv)); }   // 16：源码时间 1010、变体 1000
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); FILE *f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\"\n}\n", n == 15 ? "000000000000" : DMSH_CHAIN); fclose(f);
        int got = dm_shader_fout_fresh("0000000000000000", 4, 0);
        unlink(p); for (int k = 0; k < 2; k++) { snprintf(p, sizeof p, "%s/%s", d, names[k]); unlink(p); } rmdir(d);
        check(got == (n == 14));
    }
    if (n >= 19 && n <= 22) {   // 采样器模拟变体（#800）：19 片元、20 计算（代码区不是图形头）都先现编源码再出变体、路径 <键>_se.metal；21 顶点拒绝、两个桩都不调；22 没有能改的采样 → 3
        uint32_t st = n == 21 ? 1 << 10 : 5 << 10; const uint8_t magic[] = {0x78,0x56,0x34,0x12};
        if (n != 20) { memcpy(code, magic, 4); memcpy(code + 0x30, &st, 4); }
        if (n == 22) se_rc = 3;
        char d[] = "/tmp/t_dsh_seXXXXXX", path[256] = ""; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        int rc = dm_shader_se(key, (uint64_t)(uintptr_t)code, ctl, path, sizeof path); rmdir(d);
        char want[256]; snprintf(want, sizeof want, "%s/0000000000000000_se.metal", d);
        check(n == 21 ? rc == 1 && compiler_calls == 0 && se_calls == 0 : rc == (n == 22 ? 3 : 0) && !strcmp(path, want) && compiler_calls == 1 && se_calls == 1);
    }
    if (n >= 23 && n <= 25) {   // 兜底目录里的 <键>_se.metal 能不能直接载：23 同链、变体比源码新 → 能；24 源码是别的链 → 不能；25 变体比源码旧 → 不能
        char d[] = "/tmp/t_dsh_sefXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        const char *names[] = {"0000000000000000_b.metal", "0000000000000000_se.metal"};
        for (int k = 0; k < 2; k++) { snprintf(p, sizeof p, "%s/%s", d, names[k]); FILE *f = fopen(p, "w"); check(f != NULL); fclose(f);
            struct timeval tv[2] = {{1000 + (k ^ (n == 25)) * 10, 0}, {1000 + (k ^ (n == 25)) * 10, 0}}; check(!utimes(p, tv)); }
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); FILE *f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\"\n}\n", n == 24 ? "000000000000" : DMSH_CHAIN); fclose(f);
        int got = dm_shader_se_fresh("0000000000000000");
        unlink(p); for (int k = 0; k < 2; k++) { snprintf(p, sizeof p, "%s/%s", d, names[k]); unlink(p); } rmdir(d);
        check(got == (n == 23));
    }
    if (n >= 26 && n <= 28) {   // 顶点补齐变体（运行期配对的 user(locn)）：26 顶点先现编源码再出变体、路径 <键>_vp8.metal、掩码原样传给 S2A.Dsh；27 片元拒绝、两个桩都不调；28 没什么可补 → 3
        uint32_t st = n == 27 ? 5 << 10 : 1 << 10; const uint8_t magic[] = {0x78,0x56,0x34,0x12};
        memcpy(code, magic, 4); memcpy(code + 0x30, &st, 4);
        if (n == 28) vp_rc = 3;
        char d[] = "/tmp/t_dsh_vpXXXXXX", path[256] = ""; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        int rc = dm_shader_vpad(key, (uint64_t)(uintptr_t)code, ctl, 0x8, path, sizeof path); rmdir(d);
        char want[256]; snprintf(want, sizeof want, "%s/0000000000000000_vp8.metal", d);
        check(n == 27 ? rc == 1 && compiler_calls == 0 && vp_calls == 0 : rc == (n == 28 ? 3 : 0) && !strcmp(path, want) && compiler_calls == 1 && vp_calls == 1 && vp_mask == 0x8);
    }
    if (n == 32 || n == 33) {   // 没登记过的键（帧回放）：兜底目录有本机同链同指纹的现编产物就按 json 阶段加映射、不调编译器（32：ps → pixel）；json 没写阶段（33）→ 不复用
        char d[] = "/tmp/t_dsh_reuseXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); FILE *f = fopen(p, "w"); check(f != NULL); fclose(f);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\"%s\n}\n", DMSH_CHAIN, n == 32 ? ",\n \"stage\": \"ps\"" : ""); fclose(f);
        int got = dm_shader_reuse("0000000000000000");
        unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
        check(n == 32 ? got == 1 && !strcmp(rt_stage, "pixel") : got == 0 && !rt_stage[0]); check(atomic_load(&compiler_calls) == 0);
    }
    if (n == 34) {   // 帧回放的 Switch 2 程序（11-04 Pokopia f6000）：没登记过、控制段指针是录时的宿主地址（这里给一页不可读的内存），兜底目录里已有同链同指纹的产物 →
        //   dm_shader_miss_late 直接复用、返回 1、不读控制段也不调编译器；改前先读控制段，回放一放就 SIGBUS
        char d[] = "/tmp/t_dsh_replayXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); FILE *f = fopen(p, "w"); check(f != NULL); fclose(f);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\",\n \"stage\": \"vs\"\n}\n", DMSH_CHAIN); fclose(f);
        void *stale = mmap(NULL, 0x4000, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); check(stale != MAP_FAILED);
        int got = dm_shader_miss_late("0000000000000000", (uint64_t)(uintptr_t)code, stale);
        unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
        check(got == 1 && !strcmp(rt_stage, "vertex") && atomic_load(&compiler_calls) == 0);
    }
    if (n >= 35 && n <= 37) {   // Switch 2 首遇（11-05 时之笛 11aa3147be208368 阶段字节 6「不能现编」）：控制段 +0x56 = 6 任务 / 7 网格 → S2A.Dsh 阶段号 4 / 5、映射阶段名 task / mesh、
        //   各现编 1 次；37 外壳（3）现编不支持 → 跳过 1、编译器不调
        nvn2 = 1; uint8_t c2[0xe0] = {0}; uint32_t m = NVN2_CTL_MAGIC, v = NVN2_CTL_VERSION, own = sizeof c2, nc = sizeof code;
        memcpy(c2, &m, 4); memcpy(c2 + 4, &v, 4); memcpy(c2 + 0x30, &own, 4); memcpy(c2 + 0x44, &nc, 4); c2[0x56] = n == 35 ? 6 : n == 36 ? 7 : 3;
        int got = dm_shader_miss_late("0000000000000000", (uint64_t)(uintptr_t)code, c2);
        if (n == 37) check(got == 0 && compiler_calls == 0 && !rt_stage[0]);
        else check(got == 1 && compiled_stage == (n == 35 ? 4 : 5) && !strcmp(rt_stage, n == 35 ? "task" : "mesh"));
    }
    if (n == 38) {   // 没登记过的键：兜底目录里上局现编的网格（json stage "ms"）按 mesh 加映射、不调编译器
        char d[] = "/tmp/t_dsh_reuseXXXXXX", p[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); FILE *f = fopen(p, "w"); check(f != NULL); fclose(f);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\",\n \"stage\": \"ms\"\n}\n", DMSH_CHAIN); fclose(f);
        int got = dm_shader_reuse("0000000000000000");
        unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
        check(got == 1 && !strcmp(rt_stage, "mesh") && atomic_load(&compiler_calls) == 0);
    }
    if (n == 45) {   // 运行期 mesh 的 guest 控制段已失效：仅允许用本机同链 / 同指纹 / mesh 阶段缓存生成补齐 MSL
        static const char mesh[] = "struct dm_vertex_t {\n    float4 position [[position]];\n};\nstruct dm_prim_t {\n};\nvoid main0() {\n        dm_vertex_t v;\n}\n";
        char d[] = "/tmp/t_dsh_vpcache.XXXXXX", p[256], path[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); FILE *f = fopen(p, "w"); check(f != NULL); fwrite(mesh, 1, sizeof mesh - 1, f); fclose(f);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); f = fopen(p, "w"); check(f != NULL);
        fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\",\n \"stage\": \"ms\"\n}\n", DMSH_CHAIN); fclose(f);
        int rc = dm_shader_vpad_cached_mesh(key, 1u << 5, path, sizeof path); f = fopen(path, "r"); check(rc == 0 && f != NULL);
        char result[2048] = {0}; if (f) { size_t z = fread(result, 1, sizeof result - 1, f); result[z] = 0; fclose(f); }
        check(strstr(result, "dm_pad5 [[user(locn5)]]") && strstr(result, "v.dm_pad5 = float4(0.0, 0.0, 0.0, 1.0)"));
        unlink(path); snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
    }
    if (n == 46) {   // 包内 mesh shader：SetShaders 时只保留输入；Metal 首次拒绝后才现编基础 MSL 并补齐
        char d[] = "/tmp/t_dsh_vpsnap.XXXXXX", p[256], path[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        write_out = 1; nvn2 = 1; inlib = 1; known = 1;
        uint32_t magic = NVN2_CTL_MAGIC, version = NVN2_CTL_VERSION, ncode = sizeof code, nctl = 0xe0; uint16_t mesh = 7;
        memcpy(ctl, &magic, 4); memcpy(ctl + 4, &version, 4); memcpy(ctl + 0x30, &nctl, 4); memcpy(ctl + 0x44, &ncode, 4); memcpy(ctl + 0x56, &mesh, 2);
        uint8_t mesh_key[8]; check(nvn2_key(ctl, code, mesh_key));
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl); dm_shader_mesh_hold((uint64_t)(uintptr_t)code, ctl);
        check(atomic_load(&compiler_calls) == 0);   // ProgramSetShaders 路径不编
        nvn2 = 0; memset(ctl, 0, sizeof ctl); memset(code, 0, sizeof code);   // 模拟游戏释放 / 复用 guest 输入
        int rc = dm_shader_vpad_cached_mesh(mesh_key, 1u << 5, path, sizeof path); FILE *f = fopen(path, "r"); check(rc == 0 && f != NULL);
        char result[2048] = {0}; if (f) { size_t z = fread(result, 1, sizeof result - 1, f); result[z] = 0; fclose(f); }
        check(atomic_load(&compiler_calls) == 1 && compiled_stage == 5 && strstr(result, "dm_pad5 [[user(locn5)]]"));
        unlink(path); snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
    }
    if (n == 42) {   // 审计 #1646 P1-123：后台预编在编片元 0 时来一支输出类型变体（同键）：变体要的源码走同一把锁、锁里复查，不并发进 C# 现编入口、不重编
        //   修前（三处直接调 comp）反证：overlap 1、compiler_calls 2
        const uint8_t magic[] = {0x78,0x56,0x34,0x12}; memcpy(code, magic, 4); uint32_t ps = 5 << 10; memcpy(code + 0x30, &ps, 4);
        char d[] = "/tmp/t_dsh_varlock.XXXXXX", path[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1); write_out = 1; slow_first = 1;
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        for (int i = 0; i < 200 && atomic_load(&compiler_calls) < 1; i++) usleep(10000);   // 后台已在编（慢 300 ms）
        int rc = dm_shader_fout(key, (uint64_t)(uintptr_t)code, ctl, 0x4, 0x2, path, sizeof path);
        for (int i = 0; i < 200 && atomic_load(&g_dsh_eager_ok) < 1; i++) usleep(10000);
        char p[256]; snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p); rmdir(d);
        check(rc == 0 && atomic_load(&overlap) == 0 && atomic_load(&compiler_calls) == 1 && atomic_load(&variant_calls) == 1);
    }
    if (n >= 39 && n <= 41) {   // 后台预编（dsh_eager_start）：登记即交后台；首遇时编好的复用、在编的等、没开始的取消改同步、失败的同步再编
        char d[] = "/tmp/t_dsh_eager.XXXXXX"; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1); write_out = 1;
        if (n == 40) compile_rc = 7;   // 后台那次失败
        if (n == 41) slow_first = 1;
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        uint8_t key2[8] = {1}; if (n == 41) dm_shader_miss(key2, (uint64_t)(uintptr_t)code, ctl);   // 41：第二个键排在慢键后面
        for (int i = 0; i < 200 && atomic_load(&compiler_calls) < 1; i++) usleep(10000);   // 等后台开编（41：键 0 在编、键 1 还在队里）
        if (n == 39) { for (int i = 0; i < 200 && atomic_load(&g_dsh_eager_ok) < 1; i++) usleep(10000); late(); check(atomic_load(&compiler_calls) == 1 && !strcmp(rt_stage, "compute") && atomic_load(&g_dsh_eager_hit) == 1); }
        if (n == 40) { for (int i = 0; i < 200 && atomic_load(&compiler_calls) < 1; i++) usleep(10000); usleep(50000); compile_rc = 0; late(); check(atomic_load(&compiler_calls) == 2 && !strcmp(rt_stage, "compute")); }
        if (n == 41) { dm_shader_miss_late("0100000000000000", (uint64_t)(uintptr_t)code, NULL); usleep(500000);
            check(atomic_load(&g_dsh_eager_cancel) == 1 && atomic_load(&compiler_calls) == 2); }   // 键 1 取消改同步（键 0 后台 + 键 1 同步 = 2；键 1 的后台块不再编）
    }
    registered(n != 8); _exit(0);
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static const char *expect[] = {
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 1、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 3、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 1、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 1、复用上局 0、输出类型变体 0（正常收局）", "",
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（超时收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 1、输出类型变体 0（正常收局）",
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 1（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 29–31 指纹不同 / 没有 xfp / 没链 s2a_dsh_xfp：重编
        "成功 0、失败 0、跳过 0、复用上局 1、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 32 / 33 没登记过的键按兜底目录复用
        "成功 0、失败 0、跳过 0、复用上局 1、输出类型变体 0（正常收局）",   // 34 帧回放：控制段指针已失效，先按兜底目录复用
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 35 / 35 Switch 2 任务 / 网格首遇现编
        "成功 0、失败 0、跳过 1、复用上局 0、输出类型变体 0（正常收局）", "成功 0、失败 0、跳过 0、复用上局 1、输出类型变体 0（正常收局）",    // 37 外壳不现编；37 网格按兜底目录复用
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）", "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 39 后台编好首遇复用 / 40 后台失败首遇同步再编
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 41 排在慢键后面的键：首遇取消后台、同步编
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 1（正常收局）",   // 42 原注释见下行
        "成功 0、失败 1、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 43 见下行
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 44 编的时候输入落盘成 .inflight.*、返回后删掉；43 翻译器报错：输入自动存进兜底目录；42 后台在编同键时来输出类型变体：同锁、不并发、不重编（后台编好、没有首遇来取：不计成功）
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 45 guest 控制段过期时，从同链同指纹的本机 mesh MSL 缓存补齐
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）"    // 46 包内 mesh：仅在 Metal 拒绝时从 SetShaders 快照按需现编 MSL
    };
    int bad = 0;
    for (int n = 0; n < 47; n++) {
        int fd[2]; pipe(fd); pid_t p = fork();
        if (!p) { close(fd[0]); dup2(fd[1], 1); close(fd[1]); scenario(n); }
        close(fd[1]); char buf[1024]; size_t at = 0; ssize_t got;
        while (at < sizeof buf - 1 && (got = read(fd[0], buf + at, sizeof buf - 1 - at)) > 0) at += (size_t)got;
        buf[at] = 0; close(fd[0]); int st; waitpid(p, &st, 0);
        char line[512]; snprintf(line, sizeof line, "直连着色器现编汇总：%s\n", expect[n]);
        int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0 && !strcmp(buf, n == 6 ? "" : line);
        printf("%s 现编汇总场景 %d\n", ok ? "✓" : "✗", n);
        if (!ok) { bad++; puts(buf); }
    }
    printf("%s t_dsh_stats：47 场景，%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
