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
const char *s2a_app_version(void) { return ""; }   // 宿主 host_adapt.m 给 App 版本；本测的计数文件「app」由 sfb_write 参数直接给
int mtl_shmap_known(const char *key) { (void)key; return known; }
int mtl_shlib_has(const char *key) { (void)key; return inlib; }
static char rt_stage[16];   // 最近一次 mtl_shmap_rt_add 的阶段名（32 / 33 核）
void mtl_shmap_rt_add(const char *key, const char *stage) { (void)key; snprintf(rt_stage, sizeof rt_stage, "%s", stage); }
void mtl_se_stats(uint64_t out[2]) { out[0] = out[1] = 0; }   // 采样器模拟变体计数（nvn_mtl.m）：本测不建变体
void mtl_vp_stats(uint64_t out[2]) { out[0] = out[1] = 0; }   // 顶点补齐变体计数（nvn_mtl.m）：本测不建变体
void mtl_hybrid_pkg_stats(uint64_t out[7]) { for (int i = 0; i < 7; i++) out[i] = 0; }   // 随包拉取基础管线计数（nvn_hybrid.inc）：本测不建管线
void mtl_libact_stats(uint64_t out[6]) { for (int i = 0; i < 6; i++) out[i] = 0; }   // 着色器库按活跃集计数（nvn_mtl.m，D-92BW）：本测不放库
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec; }
static int compiled_stage = -1;   // 最近一次交给 S2A.Dsh 的阶段号（34–36 核 NVN2 任务 / 网格 = 4 / 5）
static const char *chain_name(void);   // DMSH_CHAIN（dmsh_chain.h 随 dsh_miss.inc 在下面才包含）
static int write_out, slow_first; static _Atomic int hold_first;   // hold_first：41 键 0 停在编里直到测试开闸（按事件，不靠「慢 300 ms」赶时间窗）
// 等事件（11-19：原先 200×10 ms 只等 2 秒、等不到也往下判，负载高时后台还没开编就判 → 假红）；60 秒兜底只防挂死
#define WAITFOR(c) do { for (int w_ = 0; w_ < 6000 && !(c); w_++) usleep(10000); } while (0)
// write_out / slow_first：39–41（后台预编）：编译器桩真把产物写进兜底目录（dsh_have 认它）；41：键 0 编得慢（让排在它后面的键停在队里）
static _Atomic int in_comp, overlap;   // 42：C# 现编入口不可重入，同时有两个调用在里面就计一次
static int compiler_(const char *key, int stage, const char *out);
static int crash_in_comp;   // 44：替身翻译器编到一半崩（真 SIGSEGV），看崩溃处理落没落下输入
static uint8_t got_in[0x1000]; static size_t got_nt, got_nc;   // 46 / 47 / 52：最近一次交给翻译器的控制段 + 代码区（核是不是包里那份）
static int compiler(const char *key, int stage, const void *code, size_t nc, const void *ctl, size_t nt, const char *out) {
    if (nt + nc <= sizeof got_in) { memcpy(got_in, ctl, nt); memcpy(got_in + nt, code, nc); got_nt = nt; got_nc = nc; }
    if (crash_in_comp) *(volatile int *)(uintptr_t)8 = 1;   // 同 #467 现场：读写 0x8 段错误
    if (atomic_fetch_add(&in_comp, 1)) atomic_fetch_add(&overlap, 1);
    int rc_ = compiler_(key, stage, out); atomic_fetch_sub(&in_comp, 1); return rc_;
}
static int compiler_(const char *key, int stage, const char *out) {
    int rc = compile_rc;   // 进来就定下这次的返回码（40：测试见计数到 1 就把 compile_rc 改回 0，不用睡一会儿等桩读完）
    compiled_stage = stage; atomic_fetch_add(&compiler_calls, 1);   // 先计数再慢：41 据此知道键 0 已在编（键 1 还在队里）
    if (slow_first && !strcmp(key, "0000000000000000")) { if (atomic_load(&hold_first)) { while (atomic_load(&hold_first)) usleep(1000); } else usleep(300000); }
    if (write_out && !rc && out && strcmp(out, "/dev/null")) {
        char p[1200]; FILE *f; snprintf(p, sizeof p, "%s/%s_b.metal", out, key); if ((f = fopen(p, "w"))) {
            if (stage == 5) fputs("struct dm_vertex_t {\n    float4 position [[position]];\n};\nstruct dm_prim_t {\n};\nvoid main0() {\n        dm_vertex_t v;\n}\n", f);
            fclose(f);
        }
        snprintf(p, sizeof p, "%s/%s_b.json", out, key); if ((f = fopen(p, "w"))) { fprintf(f, "{\n \"chain\": \"%s\",\n \"xfp\": \"" XFP "\",\n \"stage\": \"%s\"\n}\n", chain_name(), stage == 5 ? "ms" : stage == 0 ? "vs" : stage == 1 ? "ps" : "cs"); fclose(f); }   // 0 顶点 = "vs"（同 S2A.Dsh；47 核顶点补齐按它认阶段）
    }
    return rc;
}
static int variant(const char *in, uint32_t u, uint32_t s, const char *out) { (void)in; (void)u; (void)s; (void)out; atomic_fetch_add(&variant_calls, 1); return 0; }
static int se_variant(const char *in, const char *out) { (void)in; (void)out; atomic_fetch_add(&se_calls, 1); return se_rc; }
static int vp_variant(const char *in, uint32_t m, const char *out) { (void)in; (void)out; vp_mask = m; atomic_fetch_add(&vp_calls, 1); return vp_rc; }
static const char *xfp(void) { return XFP; }
static void *fake_dlsym(void *handle, const char *name) { (void)handle; return missing ? NULL : !strcmp(name, "s2a_dsh_xfp") ? (noxfp ? NULL : (void *)xfp) : !strcmp(name, "s2a_dsh_fout_variant") ? (void *)variant : !strcmp(name, "s2a_dsh_samp_emu") ? (void *)se_variant : !strcmp(name, "s2a_dsh_vs_pad") ? (void *)vp_variant : (void *)compiler; }
// 捕获固定汇总行；逐次成功/红行仍经生产调用，只在本依赖桩中不打印。说「客体输入」的红行计数（48 / 53：包里没有输入时照报红）
static _Atomic int guest_red;
static void fixture_log(const char *fmt, ...) {
    if (strstr(fmt, "【红】") && strstr(fmt, "客体输入")) atomic_fetch_add(&guest_red, 1);
    if (strncmp(fmt, "直连着色器现编汇总：", strlen("直连着色器现编汇总："))) return;
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); putchar('\n');
}
#define dlsym fake_dlsym
#define LOG(...) fixture_log(__VA_ARGS__)
#include "../gfx/nvn/nvn2.h"   // dsh_miss.inc 认 Switch 2 控制段；34–37 是 Switch 2 场景（nvn2_on 桩返回 nvn2），其余 Switch 1
static int nvn2;
int nvn2_on(void) { return nvn2; }
int nvn2_key(const void *control, const void *code, uint8_t out[8]) { (void)code; if (!control) return 0; memcpy(out, (const uint8_t *)control + 0x20, 8); return 1; }
// 包里的客体输入（生产 nvn_mtl.m mtl_guest_input：库容器种类 56，读法 lib_pack.inc lp_guest_get 在 t_lib_pack.m 测）：本测替身按「包里有哪个键、哪个阶段、哪份字节」答，
//   pkg_on = 0 时同没有这一段的旧包（返回 1）
static int pkg_on, pkg_st; static uint8_t pkg_key[8], pkg_bytes[0x1000]; static uint32_t pkg_nctl, pkg_ncode; static _Atomic int pkg_asks;
int mtl_guest_input(const uint8_t k8[8], int st, uint8_t **buf, uint32_t *nctl, uint32_t *ncode) {
    atomic_fetch_add(&pkg_asks, 1); *buf = NULL; *nctl = *ncode = 0;
    if (!pkg_on || memcmp(k8, pkg_key, 8) || st != pkg_st) return 1;
    *buf = malloc(pkg_nctl + pkg_ncode); memcpy(*buf, pkg_bytes, pkg_nctl + pkg_ncode); *nctl = pkg_nctl; *ncode = pkg_ncode; return 0;
}
static void pkg_put(const uint8_t k8[8], int st, const uint8_t *c, uint32_t nc, const uint8_t *d, uint32_t nd) {
    memcpy(pkg_key, k8, 8); pkg_st = st; memcpy(pkg_bytes, c, nc); memcpy(pkg_bytes + nc, d, nd); pkg_nctl = nc; pkg_ncode = nd; pkg_on = 1;
}
#include "../host/dsh_miss.inc"
static void *release_on_cancel(void *x) { (void)x; WAITFOR(atomic_load(&g_dsh_eager_cancel) >= 1); hold_first = 0; return NULL; }   // 41：键 1 取消了才放键 0 编完
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
    // 后台预编只给测它的 39–42 开；其余场景是登记时不编的语义（后台预编关）。原为 n >= 39，之后新加的 42–53 都被顺带打开：
    //   场景 51 断言「首遇时代码区不可读 → 不调编译器」，后台预编用登记时拷的代码区抢先编完时编译器替身被调，60 次红 7 次（11-19）
    //   42 也要开（11-19：上一条收窄时漏了它——42 测「后台在编时来输出类型变体」，后台不开时它一直空过：2 秒等后台开编白等到头、变体自己编一次照样绿）
    setenv("S2A_DSH_EAGER_MAX", n >= 39 && n <= 42 ? "8" : "0", 1);
    uint32_t size = sizeof code, csize = sizeof ctl;
    memcpy(ctl + 0x704, &size, 4); memcpy(ctl + 0x20, &csize, 4);
    setenv("DM_MSL_FALLBACK", "/dev/null", 1); // 编译器桩不写文件。
    check(registered != NULL);
    if (n == 49) {   // 诊断#354a81：控制段自报长度越过映射末尾（放在一页可读的末尾、后面紧跟 PROT_NONE 页，自报 0x2000 字节）。
        //   期望（手算）：修前 memcpy(e->ctl, ctl, nctl) 读到 PROT_NONE 页崩；修后 dsh_stage 判整段不可读 → 认不出阶段 → 跳过 1，不崩
        long pg = sysconf(_SC_PAGESIZE); uint8_t *m = mmap(NULL, (size_t)pg * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); check(m != MAP_FAILED);
        check(mprotect(m + pg, (size_t)pg, PROT_NONE) == 0);
        uint8_t *c2 = m + pg - 0x900; memcpy(c2, ctl, 0x900); uint32_t big = 0x2000; memcpy(c2 + 0x20, &big, 4);
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, c2);
    }
    if (n == 50) {   // #fb7116：控制段 +0x20 自报 0x302 字节（< 代码长字段 +0x704 的位置），+0x704 处是段外的数。
        //   期望（手算）：0x302 < 0x708 → 认不出阶段 → 跳过 1、不调编译器。修前：登记拷 0x302 字节、首遇从拷贝 +0x704 读段外的数当代码长 → 编译器被调（成功 1）
        uint32_t small = 0x302; memcpy(ctl + 0x20, &small, 4); call(); check(compiler_calls == 0);
    }
    if (n == 51) {   // 登记后代码区被解除映射（懒清零改不可访问）：代码区放在一页末尾，登记时可读，首遇前 mprotect 成不可访问。
        //   期望（手算）：首遇时代码区不是整段可读 → 放弃、跳过 1、不调编译器、不崩。修前：照样把这段交给翻译器（真翻译器读到就崩；替身不读 → 成功 1）
        long pg = sysconf(_SC_PAGESIZE); uint8_t *m = mmap(NULL, (size_t)pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); check(m != MAP_FAILED);
        uint8_t *c2 = m + pg - sizeof code; memcpy(c2, code, sizeof code);
        dm_shader_miss(key, (uint64_t)(uintptr_t)c2, ctl); check(mprotect(m, (size_t)pg, PROT_NONE) == 0);
        dm_shader_miss_late("0000000000000000", (uint64_t)(uintptr_t)c2, NULL); check(compiler_calls == 0);
    }
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
    if (n == 54 || n == 55) {   // 一款 Switch 2 游戏的 14 支：控制段阶段字节 1、代码区没有 SPH、游戏在派发 → 按计算（阶段号 2、映射名 compute）；55 代码区开头写像素 SPH（类型 2、阶段 5：0x000c5482）→ 仍按像素
        nvn2 = 1; uint8_t c2[0xe0] = {0}; uint32_t m = NVN2_CTL_MAGIC, v = NVN2_CTL_VERSION, own = sizeof c2, nc = sizeof code;
        memcpy(c2, &m, 4); memcpy(c2 + 4, &v, 4); memcpy(c2 + 0x30, &own, 4); memcpy(c2 + 0x44, &nc, 4); c2[0x56] = 1;
        if (n == 55) { uint32_t sph = 0x000c5482; memcpy(code, &sph, 4); }
        int got = dm_shader_miss_late("0000000000000000", (uint64_t)(uintptr_t)code, c2);
        check(got == 1 && compiled_stage == (n == 54 ? 2 : 1) && !strcmp(rt_stage, n == 54 ? "compute" : "pixel"));
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
        int rc = dm_shader_vpad_cached(key, 5, 1u << 5, path, sizeof path); f = fopen(path, "r"); check(rc == 0 && f != NULL);
        char result[2048] = {0}; if (f) { size_t z = fread(result, 1, sizeof result - 1, f); result[z] = 0; fclose(f); }
        check(strstr(result, "dm_pad5 [[user(locn5)]]") && strstr(result, "v.dm_pad5 = float4(0.0, 0.0, 0.0, 1.0)"));
        unlink(path); snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p);
        snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
    }
    if (n == 46) {   // 包内 mesh shader：设备上不留输入；Metal 首次拒绝后按包里的客体输入（种类 56，阶段 5）现编基础 MSL 并补齐。
        //   期望（手算）：编译器 1 次、阶段 5、交给翻译器的控制段 0xe0 + 代码 0x100 字节 = 包里写的那份（游戏这时已清零自己的副本）、补齐文本带 locn5
        char d[] = "/tmp/t_dsh_vpsnap.XXXXXX", p[256], path[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        write_out = 1; nvn2 = 1; inlib = 1; known = 1;
        uint32_t magic = NVN2_CTL_MAGIC, version = NVN2_CTL_VERSION, ncode = sizeof code, nctl = 0xe0; uint16_t mesh = 7;
        memcpy(ctl, &magic, 4); memcpy(ctl + 4, &version, 4); memcpy(ctl + 0x30, &nctl, 4); memcpy(ctl + 0x44, &ncode, 4); memcpy(ctl + 0x56, &mesh, 2);
        for (int i = 0; i < (int)sizeof code; i++) code[i] = (uint8_t)(0x40 + i);
        uint8_t mesh_key[8]; check(nvn2_key(ctl, code, mesh_key));
        uint8_t want[0xe0 + sizeof code]; memcpy(want, ctl, 0xe0); memcpy(want + 0xe0, code, sizeof code);
        pkg_put(mesh_key, 5, ctl, 0xe0, code, sizeof code);
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        check(atomic_load(&compiler_calls) == 0);   // ProgramSetShaders 路径不编
        nvn2 = 0; memset(ctl, 0, sizeof ctl); memset(code, 0, sizeof code);   // 模拟游戏释放 / 复用 guest 输入
        int rc = dm_shader_vpad_cached(mesh_key, 5, 1u << 5, path, sizeof path); FILE *f = fopen(path, "r"); check(rc == 0 && f != NULL);
        char result[2048] = {0}; if (f) { size_t z = fread(result, 1, sizeof result - 1, f); result[z] = 0; fclose(f); }
        check(atomic_load(&compiler_calls) == 1 && compiled_stage == 5 && strstr(result, "dm_pad5 [[user(locn5)]]"));
        check(got_nt == 0xe0 && got_nc == sizeof code && !memcmp(got_in, want, sizeof want));
        unlink(path); snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
    }
    if (n == 47 || n == 48) {   // 11-14 D-R4CP（Switch 1 顶点着色器，人物与地形缺失）：包内顶点着色器，游戏复用控制段之后首次配对缺 user(locn)：
        //   47 包里有它的客体输入（种类 56，阶段 0）→ 按它现编基础源码再出补齐变体（编译器 1 次、阶段 0、交给翻译器的 0x880 + 0x100 字节 = 包里那份、补齐桩 1 次、掩码原样、
        //   路径 <键>_vp8.metal、不报红）。48 反证：旧包（没有种类 56）→ 做不了（返回 1）、问过包 1 次、两个桩都不调、报一行「客体输入」红
        uint32_t st = 1 << 10; const uint8_t magic[] = {0x78,0x56,0x34,0x12}; memcpy(code, magic, 4); memcpy(code + 0x30, &st, 4); for (int i = 0x40; i < (int)sizeof code; i++) code[i] = (uint8_t)i;
        char d[] = "/tmp/t_dsh_vssnap.XXXXXX", p[256], path[256] = ""; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        write_out = 1; inlib = 1; known = 1;
        uint8_t want_in[sizeof ctl + sizeof code]; memcpy(want_in, ctl, sizeof ctl); memcpy(want_in + sizeof ctl, code, sizeof code);
        if (n == 47) pkg_put(key, 0, ctl, sizeof ctl, code, sizeof code);
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        check(atomic_load(&compiler_calls) == 0);   // SetShaders 路径不编
        memset(ctl, 0, sizeof ctl); memset(code, 0, sizeof code);   // 模拟游戏释放 / 复用 guest 输入
        int rc = dm_shader_vpad_cached(key, 0, 0x8, path, sizeof path);
        char want[256]; snprintf(want, sizeof want, "%s/0000000000000000_vp8.metal", d);
        if (n == 47) check(rc == 0 && !strcmp(path, want) && atomic_load(&compiler_calls) == 1 && compiled_stage == 0 && atomic_load(&vp_calls) == 1 && vp_mask == 0x8 && atomic_load(&guest_red) == 0
                           && got_nt == sizeof ctl && got_nc == sizeof code && !memcmp(got_in, want_in, sizeof want_in));
        else check(rc == 1 && atomic_load(&pkg_asks) == 1 && atomic_load(&compiler_calls) == 0 && atomic_load(&vp_calls) == 0 && atomic_load(&guest_red) == 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
    }
    if (n == 52 || n == 53) {   // 采样器模拟变体（nvn_mtl.m se_build）控制段过期：诊断里 55 次没出成的变体 46 次是「游戏已不持有控制段」。包内片元着色器，游戏复用控制段之后首次绑 min / max 采样器：
        //   52 包里有它的客体输入（种类 56，阶段 1）→ 现编基础源码再出变体（编译器 1 次、阶段 1、交给翻译器的 = 包里那份、模拟桩 1 次、路径 <键>_se.metal、不报红）。
        //   53 反证：包里同键记的是顶点（阶段 0），要的是片元 → 按没有：做不了、两个桩都不调、报一行「客体输入」红
        uint32_t ps = 5 << 10; const uint8_t magic[] = {0x78,0x56,0x34,0x12}; memcpy(code, magic, 4); memcpy(code + 0x30, &ps, 4); for (int i = 0x40; i < (int)sizeof code; i++) code[i] = (uint8_t)(i ^ 0x5a);
        char d[] = "/tmp/t_dsh_sesnap.XXXXXX", p[256], path[256] = ""; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1);
        write_out = 1; inlib = 1; known = 1;
        uint8_t want_in[sizeof ctl + sizeof code]; memcpy(want_in, ctl, sizeof ctl); memcpy(want_in + sizeof ctl, code, sizeof code);
        pkg_put(key, n == 52 ? 1 : 0, ctl, sizeof ctl, code, sizeof code);
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        check(atomic_load(&compiler_calls) == 0);   // SetShaders 路径不编
        memset(ctl, 0, sizeof ctl); memset(code, 0, sizeof code);   // 模拟游戏释放 / 复用 guest 输入
        int rc = dm_shader_se_cached(key, 1, path, sizeof path);
        char want[256]; snprintf(want, sizeof want, "%s/0000000000000000_se.metal", d);
        if (n == 52) check(rc == 0 && !strcmp(path, want) && atomic_load(&compiler_calls) == 1 && compiled_stage == 1 && atomic_load(&se_calls) == 1 && atomic_load(&guest_red) == 0
                           && got_nt == sizeof ctl && got_nc == sizeof code && !memcmp(got_in, want_in, sizeof want_in));
        else check(rc == 1 && atomic_load(&compiler_calls) == 0 && atomic_load(&se_calls) == 0 && atomic_load(&guest_red) == 1);
        snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); rmdir(d);
    }
    if (n == 42) {   // 审计 #1646 P1-123：后台预编在编片元 0 时来一支输出类型变体（同键）：变体要的源码走同一把锁、锁里复查，不并发进 C# 现编入口、不重编
        //   修前（三处直接调 comp）反证：overlap 1、compiler_calls 2
        const uint8_t magic[] = {0x78,0x56,0x34,0x12}; memcpy(code, magic, 4); uint32_t ps = 5 << 10; memcpy(code + 0x30, &ps, 4);
        char d[] = "/tmp/t_dsh_varlock.XXXXXX", path[256]; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1); write_out = 1; slow_first = 1;
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        WAITFOR(atomic_load(&compiler_calls) >= 1);   // 后台已在编（慢 300 ms）
        int rc = dm_shader_fout(key, (uint64_t)(uintptr_t)code, ctl, 0x4, 0x2, path, sizeof path);
        WAITFOR(atomic_load(&in_comp) == 0);   // 后台那次编完再数（原先等 g_dsh_eager_ok ≥ 1：本场景它不涨，2 秒上限一直是白等）
        char p[256]; snprintf(p, sizeof p, "%s/0000000000000000_b.metal", d); unlink(p); snprintf(p, sizeof p, "%s/0000000000000000_b.json", d); unlink(p); rmdir(d);
        check(rc == 0 && atomic_load(&overlap) == 0 && atomic_load(&compiler_calls) == 1 && atomic_load(&variant_calls) == 1);
    }
    if (n >= 39 && n <= 41) {   // 后台预编（dsh_eager_start）：登记即交后台；首遇时编好的复用、在编的等、没开始的取消改同步、失败的同步再编
        char d[] = "/tmp/t_dsh_eager.XXXXXX"; check(mkdtemp(d) != NULL); setenv("DM_MSL_FALLBACK", d, 1); write_out = 1;
        if (n == 40) compile_rc = 7;   // 后台那次失败
        if (n == 41) { slow_first = 1; hold_first = 1; }   // 键 0 停在编里，直到键 1 首遇做完再开闸
        dm_shader_miss(key, (uint64_t)(uintptr_t)code, ctl);
        uint8_t key2[8] = {1}; if (n == 41) dm_shader_miss(key2, (uint64_t)(uintptr_t)code, ctl);   // 41：第二个键排在慢键后面
        WAITFOR(atomic_load(&compiler_calls) >= 1);   // 等后台开编（41：键 0 在编、键 1 还在队里）
        if (n == 39) { WAITFOR(atomic_load(&g_dsh_eager_ok) >= 1); late(); check(atomic_load(&compiler_calls) == 1 && !strcmp(rt_stage, "compute") && atomic_load(&g_dsh_eager_hit) == 1); }
        if (n == 40) { WAITFOR(atomic_load(&compiler_calls) >= 1); compile_rc = 0; late(); check(atomic_load(&compiler_calls) == 2 && !strcmp(rt_stage, "compute")); }
        if (n == 41) { pthread_t rel; pthread_create(&rel, NULL, release_on_cancel, NULL);   // 键 1 被取消（同步编之前）再开闸：同步编和后台编同一把锁，不开闸就互等
            dm_shader_miss_late("0100000000000000", (uint64_t)(uintptr_t)code, NULL); pthread_join(rel, NULL); WAITFOR(atomic_load(&g_dsh_eager_ok) >= 1);
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
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 46 包内 mesh：仅在 Metal 拒绝时按包里的客体输入现编 MSL
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 47 包内 Switch 1 顶点：包里的客体输入 → 控制段过期后照样出补齐变体
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 48 反证：旧包没有种类 56 → 做不了、报红
        "成功 0、失败 0、跳过 1、复用上局 0、输出类型变体 0（正常收局）",   // 49 控制段自报长度越过映射末尾：放弃这一份、不崩（#354a81）
        "成功 0、失败 0、跳过 1、复用上局 0、输出类型变体 0（正常收局）",   // 50 控制段短于代码长字段位置：认不出、不现编（#fb7116）
        "成功 0、失败 0、跳过 1、复用上局 0、输出类型变体 0（正常收局）",   // 51 登记后代码区被解除映射：首遇放弃、不崩
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 52 包内片元：包里的客体输入 → 控制段过期后照样出采样器模拟变体
        "成功 0、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 53 反证：没有容器 → 做不了、报红
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）",   // 54 NVN2 阶段字节 1、代码没有 SPH（计算着色器）：按计算现编
        "成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）"    // 55 负对照：阶段字节 1、代码带像素 SPH：仍按像素
    };
    int bad = 0;
    for (int n = 0; n < 56; n++) {
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
    {   // 曲面外壳 / 域（Switch 1 SPH 类型 2 / 3）：设备首遇现编不支持，原先在「不能现编」那一行里只报一次、悄悄丢（#2264 排查，11-27）；现在每支计数（g_dsh_tess）、
        //   收局汇总多一行红。期望手写：喂一支类型 2（外壳）→ 计 1；再喂一支类型 5（像素，能现编的阶段）→ 不计，仍是 1
        pid_t p = fork();
        if (!p) {
            memset(code, 0, sizeof code); memcpy(code, "\x78\x56\x34\x12", 4);
            uint32_t w = 2u << 10 | 1; memcpy(code + 0x30, &w, 4); uint8_t k1[8] = {0x77}; dm_shader_miss(k1, (uint64_t)(uintptr_t)code, ctl);
            uint64_t a = atomic_load(&g_dsh_tess);
            w = 5u << 10 | 1; memcpy(code + 0x30, &w, 4); uint8_t k2[8] = {0x78}; dm_shader_miss(k2, (uint64_t)(uintptr_t)code, ctl);
            uint64_t b = atomic_load(&g_dsh_tess);
            printf("曲面外壳计数 %llu、再喂像素后 %llu\n", (unsigned long long)a, (unsigned long long)b);
            _exit(a == 1 && b == 1 ? 0 : 1);
        }
        int st; waitpid(p, &st, 0); int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
        printf("%s 曲面外壳 / 域：映射表外的一支计数 1、像素不计（期望 1 / 1）\n", ok ? "✓" : "✗"); if (!ok) bad++;
    }
    {   // 着色器覆盖计数文件（sfb_write）：期望手算——新建计 2、再加 1 得 3、"app" 照给的写；兜底目录不是 …/wire/<程序号>/shaders 形状 → -1、不写文件
        char t[] = "/tmp/t_dsh_sfb.XXXXXX"; if (!mkdtemp(t)) { puts("✗ 建临时目录失败"); return 1; }
        char fb[512], js[600], b[256]; snprintf(fb, sizeof fb, "%s/0400486024DEC000/wire/0400486024DEC000/shaders", t); snprintf(js, sizeof js, "%s/0400486024DEC000/shader_fallback.json", t);
        char mk[600]; snprintf(mk, sizeof mk, "mkdir -p '%s'", fb); system(mk);
        int r1 = sfb_write(fb, 2, "0.6.0"); FILE *f = fopen(js, "r"); size_t z = f ? fread(b, 1, sizeof b - 1, f) : 0; if (f) fclose(f); b[z] = 0;
        unsigned long long c1 = 0; char app1[16] = ""; sscanf(strstr(b, "\"count\"") ? strstr(b, "\"count\"") : "", "\"count\": %llu", &c1); const char *ap = strstr(b, "\"app\": \""); if (ap) sscanf(ap + 8, "%15[^\"]", app1);
        int r2 = sfb_write(fb, 1, ""); f = fopen(js, "r"); z = f ? fread(b, 1, sizeof b - 1, f) : 0; if (f) fclose(f); b[z] = 0;
        unsigned long long c2 = 0; sscanf(strstr(b, "\"count\"") ? strstr(b, "\"count\"") : "", "\"count\": %llu", &c2);
        char bad_fb[512], bad_js[600]; snprintf(bad_fb, sizeof bad_fb, "%s/elsewhere/shaders", t); snprintf(bad_js, sizeof bad_js, "%s/shader_fallback.json", t);
        int r3 = sfb_write(bad_fb, 1, "x"); int none = access(bad_js, F_OK) != 0;
        int ok = r1 == 0 && c1 == 2 && !strcmp(app1, "0.6.0") && r2 == 0 && c2 == 3 && r3 == -1 && none;
        printf("%s 着色器覆盖计数文件：新建 %llu（期望 2）、app %s（期望 0.6.0）、再加 1 → %llu（期望 3）、别的形状返回 %d（期望 -1）且不写文件 %d（期望 1）\n", ok ? "✓" : "✗", c1, app1, c2, r3, none);
        bad += !ok; snprintf(mk, sizeof mk, "rm -rf '%s'", t); system(mk);
    }
    printf("%s t_dsh_stats：56 场景，%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
