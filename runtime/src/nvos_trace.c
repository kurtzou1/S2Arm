// 诊断：记录游戏随包 GPU 驱动栈经 NvOsAlloc / NvOsAllocAlign / NvOsRealloc / NvOsFree 向游戏图形分配器要的内存（11-13 金手指堆偏移根修取参照用）。
//   只在 Mac、且设了 S2A_NVOS_TRACE=<输出文件> 时生效；不设什么都不做。iOS / 安卓不编进这段（代码页签名只读）。
//   brk 立即数取 0x7DE0–0x7DEF（macOS 截走 0xB000–0xBFFF，见 diag_brk.c）。
//   做法（不占代码空隙：改写后的 sdk 没有成块的全 0 空隙，sdk 前后也要不到地址）：sdk 里这四个函数各占 16 字节，第一字是一条 B 到分配表跳板、后三字 udf 填充。
//     第一字改成 brk #(0x7DE0+k)：陷入时记参数与调用链，把返回地址压进本线程的小栈、LR 改成 NvOsAlloc+4 处的 brk #0x7DEF，PC 设到原 B 的目标；
//     原函数返回时落到 brk #0x7DEF：记返回值，弹出原返回地址设成 PC。嵌套（重分配里再分配）按栈先进后出。
//   每行：NVOS <序号> <线程> <种类 alloc|align|realloc|free|ret> <x0> <x1> <x2> <返回地址 模块+偏移> <最近的 main 调用点> <调用链前 6 帧>
//   配合 S2A_NVN_REAL=1（gfxmode.c：nvnBootstrapLoader 不接管，跑游戏自带 NVN 驱动）与不设（直连）各跑一局，两份对比 = 直连少做的分配。
#include "native.h"
void s2a_where(uint64_t a, char *b, size_t n);   // crash.c：地址 → 模块+偏移
void s2a_mem_guest_split(uint64_t *heap_lo, uint64_t *heap_len, uint64_t *alias_lo, uint64_t *alias_len, uint64_t *phys);   // svc_mem.c
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#endif

#if defined(__APPLE__) && !TARGET_OS_IPHONE
#include <sys/ucontext.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
static uint64_t g_ent[4], g_tgt[4], g_ret;   // 四个入口、原 B 的目标、返回陷入点
static int g_fd = -1;
static uint64_t g_seq;
static __thread uint64_t t_ret[64]; static __thread int t_n;
// operator new 记录（S2A_NEW_TRACE=1，与 S2A_NVOS_TRACE 同一输出）：main 的 _Znwm / _Znam 第一字（str x19,[sp,#-0x20]!）换成 brk #0x7DE9，
//   陷入里照做这一条、记大小与调用点，LR 换成 NvOsAlloc+12 的 brk #0x7DED 截返回值。只记 ≥ 4 KB 的、或落在堆 [0x5C000000, 0x5C600000) 里的（某款金手指目标附近，S2A_NEW_WIN 可改）
static uint64_t g_new_ent[2], g_nret, g_heap_lo, g_win_lo = 0x5C000000, g_win_hi = 0x5C600000;   // 窗口：S2A_NEW_WIN=<起>-<止>（堆偏移，十六进制），窗口里的分配不论大小都记、带调用链
static __thread struct { uint64_t back, size, lr, heap, align; int fn; } t_new[64]; static __thread int t_nn;
// 堆分配函数记录（S2A_NEW_FN=main+<偏移>,…，第一字须是 sub sp,sp,#imm）：同上换成 brk #0x7DEA，陷入里照做 sp -= imm，记 this / 大小 / 对齐，返回值同走 brk #0x7DED
#define NFN 8
static struct { uint64_t at; uint32_t imm; char name[24]; } g_fn[NFN]; static int g_nfn;
static uint64_t g_sret;   // 调用点返回陷入（NvOsAlloc+8 的 brk #0x7DEE）：BL / BLR 调用点调完回到这里，记返回值（「sret」行）再回原返回地址
static __thread struct { uint64_t back, x2; int site; } t_sret[64]; static __thread int t_ns;   // 本线程待返回的原返回地址（嵌套）
// 调用点（S2A_NVOS_SITES=<模块>+<返回地址偏移>,…，第二遍用）：返回地址前一条 BL / BLR 换成 brk #0x7DE8，陷入时记「call」行、按原指令跳（LR = pc + 4）。
//   用途：把驱动分配按「哪个调用点的第几次调用」切开（同一调用点循环调用时，两次调用之间游戏自己可能也在分配）
#define NSITE 64
static struct { uint32_t *at, orig; char name[40]; } g_site[NSITE]; static int g_nsite;
static const char *const k_name[4] = {"NvOsAlloc", "NvOsAllocAlign", "NvOsRealloc", "NvOsFree"};
static const char *const k_kind[4] = {"alloc", "align", "realloc", "free"};

static int where(uint64_t a, char *out, size_t n) {
    module_t *m = module_of((void *)a);
    if (!m || a < (uint64_t)m->base || a - (uint64_t)m->base >= m->size) return snprintf(out, n, "?%llx", (unsigned long long)a);
    return snprintf(out, n, "%s+%llx", m->name, (unsigned long long)(a - (uint64_t)m->base));
}

static void emit(const char *kind, const uint64_t *x, uint64_t lr, uint64_t fp, int args) {
    char line[1024], ra[64], site[64] = "-", chain[512] = "";
    where(lr, ra, sizeof ra);
    size_t cl = 0; int got = 0;
    for (int i = 0; i < 24 && fp && !(fp & 7); i++) {
        uint64_t next = ((const uint64_t *)fp)[0], ret = ((const uint64_t *)fp)[1];
        char b[64]; where(ret, b, sizeof b);
        if (i < 6 && cl < sizeof chain - 70) cl += (size_t)snprintf(chain + cl, sizeof chain - cl, "%s%s", cl ? "," : "", b);
        if (!got && !strncmp(b, "main+", 5)) { snprintf(site, sizeof site, "%s", b); got = 1; }
        if (next <= fp) break;
        fp = next;
    }
    uint64_t seq = __atomic_fetch_add(&g_seq, 1, __ATOMIC_RELAXED);
    int n = args ? snprintf(line, sizeof line, "NVOS\t%llu\t%p\t%s\t%llx\t%llx\t%llx\t%s\t%s\t%s\n", (unsigned long long)seq, (void *)pthread_self(), kind,
                            (unsigned long long)x[0], (unsigned long long)x[1], (unsigned long long)x[2], ra, site, chain)
                 : snprintf(line, sizeof line, "NVOS\t%llu\t%p\t%s\t%llx\t-\t-\t%s\t%s\t%s\n", (unsigned long long)seq, (void *)pthread_self(), kind,
                            (unsigned long long)x[0], ra, site, chain);
    if (n > 0 && g_fd >= 0) (void)!write(g_fd, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
}

int s2a_nvos_trace_trap(void *ctx) {
    if (!g_ret) return 0;
    ucontext_t *uc = ctx;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    if (g_nret && pc == g_nret) {
        if (t_nn <= 0) return 0;
        t_nn--; uint64_t ptr = uc->uc_mcontext->__ss.__x[0], sz = t_new[t_nn].size, back = t_new[t_nn].back;
        if (!g_heap_lo) { uint64_t hn, al, an, ph; s2a_mem_guest_split(&g_heap_lo, &hn, &al, &an, &ph); }
        uint64_t off = ptr - g_heap_lo; int inwin = off >= g_win_lo && off < g_win_hi;
        if (sz >= 0x1000 || inwin) {
            int fi = t_new[t_nn].fn; char w[64], line[700]; s2a_where(t_new[t_nn].lr, w, sizeof w); uint64_t seq = __atomic_fetch_add(&g_seq, 1, __ATOMIC_RELAXED);
            int n = snprintf(line, sizeof line, "NVOS\t%llu\t%p\t%s\t%llx\t%llx\t%llx\t%s\t%llx\t-\n", (unsigned long long)seq, (void *)pthread_self(), fi < 0 ? "new" : g_fn[fi].name,
                             (unsigned long long)sz, (unsigned long long)off, (unsigned long long)t_new[t_nn].align, w, (unsigned long long)(t_new[t_nn].heap - g_heap_lo));
            if (inwin && n > 1 && n < (int)sizeof line) {   // 窗口里的：把 fp 链前 8 帧接在行尾（替掉末尾的「-」）
                n -= 2; uint64_t fp = uc->uc_mcontext->__ss.__fp;
                for (int i = 0; i < 8 && fp && !(fp & 7) && n < (int)sizeof line - 40; i++) { char b[48]; s2a_where(((const uint64_t *)fp)[1], b, sizeof b); n += snprintf(line + n, sizeof line - (size_t)n, "%s%s", i ? "," : "", b); uint64_t nx = ((const uint64_t *)fp)[0]; if (nx <= fp) break; fp = nx; }
                n += snprintf(line + n, sizeof line - (size_t)n, "\n");
            }
            if (n > 0 && g_fd >= 0) (void)!write(g_fd, line, (size_t)n);
        }
        uc->uc_mcontext->__ss.__pc = back;
        return 1;
    }
    for (int k = 0; k < 2; k++) if (g_new_ent[k] && pc == g_new_ent[k]) {
        uint64_t *sp = &uc->uc_mcontext->__ss.__sp; *sp -= 0x20; *(uint64_t *)*sp = uc->uc_mcontext->__ss.__x[19];   // 照做 str x19, [sp, #-0x20]!
        if (t_nn < 64) { t_new[t_nn].back = uc->uc_mcontext->__ss.__lr; t_new[t_nn].size = uc->uc_mcontext->__ss.__x[0]; t_new[t_nn].lr = uc->uc_mcontext->__ss.__lr; t_new[t_nn].heap = g_heap_lo; t_new[t_nn].align = 0; t_new[t_nn].fn = -1; t_nn++; uc->uc_mcontext->__ss.__lr = g_nret; }
        uc->uc_mcontext->__ss.__pc = pc + 4;
        return 1;
    }
    for (int k = 0; k < g_nfn; k++) if (pc == g_fn[k].at) {
        uc->uc_mcontext->__ss.__sp -= g_fn[k].imm;   // 照做 sub sp, sp, #imm
        uint64_t *x = uc->uc_mcontext->__ss.__x;
        if (t_nn < 64) { t_new[t_nn].back = uc->uc_mcontext->__ss.__lr; t_new[t_nn].size = x[1]; t_new[t_nn].lr = uc->uc_mcontext->__ss.__lr; t_new[t_nn].heap = x[0]; t_new[t_nn].align = x[2]; t_new[t_nn].fn = k; t_nn++; uc->uc_mcontext->__ss.__lr = g_nret; }
        uc->uc_mcontext->__ss.__pc = pc + 4;
        return 1;
    }
    if (pc == g_sret && g_sret) {
        if (t_ns <= 0) return 0;
        t_ns--; uint64_t back = t_sret[t_ns].back, x2 = t_sret[t_ns].x2; int si = t_sret[t_ns].site;
        int32_t v2 = 0; mach_vm_size_t got = 0;   // 调用时 x2 指向的 4 字节（nvnDeviceGetInteger 的写回值）；不是指针就读失败、记 0
        if (mach_vm_read_overwrite(mach_task_self(), x2, 4, (mach_vm_address_t)&v2, &got) != KERN_SUCCESS) v2 = 0;
        char line[200]; uint64_t seq = __atomic_fetch_add(&g_seq, 1, __ATOMIC_RELAXED);
        int n = snprintf(line, sizeof line, "NVOS\t%llu\t%p\tsret\t%llx\t%llx\t%d\t%s\t%s\t-\n", (unsigned long long)seq, (void *)pthread_self(),
                         (unsigned long long)uc->uc_mcontext->__ss.__x[0], (unsigned long long)uc->uc_mcontext->__ss.__x[1], v2, g_site[si].name, g_site[si].name);
        if (n > 0 && g_fd >= 0) (void)!write(g_fd, line, (size_t)n);
        uc->uc_mcontext->__ss.__pc = back;
        return 1;
    }
    if (pc == g_ret) {
        if (t_n <= 0) return 0;
        uint64_t back = t_ret[--t_n];
        emit("ret", uc->uc_mcontext->__ss.__x, back, uc->uc_mcontext->__ss.__fp, 0);
        uc->uc_mcontext->__ss.__pc = back;
        return 1;
    }
    for (int i = 0; i < g_nsite; i++) {
        if (pc != (uint64_t)g_site[i].at) continue;
        uint32_t w = g_site[i].orig; uint64_t tgt;
        if ((w & 0xFC000000u) == 0x94000000u) tgt = pc + (uint64_t)((int64_t)((uint64_t)w << 38) >> 36);
        else tgt = uc->uc_mcontext->__ss.__x[(w >> 5) & 31];   // BLR / BR Xn（装时核过只有这三种；x30 作 Rn 不收）
        char line[260]; uint64_t seq = __atomic_fetch_add(&g_seq, 1, __ATOMIC_RELAXED);
        Dl_info di; const char *sym = dladdr((void *)tgt, &di) && di.dli_sname ? di.dli_sname : "-";   // 目标是宿主代码（直连的 NVN 桩）时给符号名
        int n = snprintf(line, sizeof line, "NVOS\t%llu\t%p\tcall\t%llx\t%s\t-\t%s\t%s\tx0=%llx x1=%llx\n", (unsigned long long)seq, (void *)pthread_self(), (unsigned long long)tgt, sym, g_site[i].name, g_site[i].name,
                         (unsigned long long)uc->uc_mcontext->__ss.__x[0], (unsigned long long)uc->uc_mcontext->__ss.__x[1]);
        if (n > 0 && g_fd >= 0) (void)!write(g_fd, line, (size_t)n);
        if (getenv("S2A_NVOS_QDEV")) {   // 诊断：调用时 x0 当 NVN 队列 builder，读 [x0+0x10] 标志与 [x0+8] 设备里真驱动算队列内存用的字段（安全读，不是指针就记 0）
            uint64_t b0 = uc->uc_mcontext->__ss.__x[0], dev = 0; uint32_t fl = 0, f[6] = {0}; mach_vm_size_t got;
            static const uint32_t off[6] = {0x70, 0x78, 0x7c, 0xc4, 0xc8, 0x1aa4};
            mach_vm_read_overwrite(mach_task_self(), b0 + 8, 8, (mach_vm_address_t)&dev, &got); mach_vm_read_overwrite(mach_task_self(), b0 + 0x10, 4, (mach_vm_address_t)&fl, &got);
            for (int q = 0; q < 6; q++) mach_vm_read_overwrite(mach_task_self(), dev + off[q], 4, (mach_vm_address_t)&f[q], &got);
            char l2[200]; int n2 = snprintf(l2, sizeof l2, "NVOS\t%llu\t%p\tqdev\t%x\t%x %x %x\t%x %x\t%s\t%x\t-\n", (unsigned long long)seq, (void *)pthread_self(), fl, f[0], f[1], f[2], f[3], f[4], g_site[i].name, f[5]);
            if (n2 > 0 && g_fd >= 0) (void)!write(g_fd, l2, (size_t)n2);
        }
        if ((w & 0xFFFFFC1Fu) != 0xD61F0000u) {   // BL / BLR：返回地址先进本线程栈，LR 改成返回陷入（记返回值）；BR（尾调桩）不改 LR
            if (t_ns < 64) { t_sret[t_ns].back = pc + 4; t_sret[t_ns].x2 = uc->uc_mcontext->__ss.__x[2]; t_sret[t_ns].site = i; t_ns++; uc->uc_mcontext->__ss.__lr = g_sret; }
            else uc->uc_mcontext->__ss.__lr = pc + 4;
        }
        uc->uc_mcontext->__ss.__pc = tgt;
        return 1;
    }
    for (int k = 0; k < 4; k++) {
        if (pc != g_ent[k]) continue;
        uint64_t lr = uc->uc_mcontext->__ss.__lr;
        emit(k_kind[k], uc->uc_mcontext->__ss.__x, lr, uc->uc_mcontext->__ss.__fp, 1);
        if (t_n < 64) { t_ret[t_n++] = lr; uc->uc_mcontext->__ss.__lr = g_ret; }   // 栈满（不该发生）就不截返回值，照常返回
        uc->uc_mcontext->__ss.__pc = g_tgt[k];
        return 1;
    }
    return 0;
}

// 代码页按文件映射、最高权限只读可执行，mprotect 改不了写：可写时用 mach_vm_protect 带 VM_PROT_COPY 换成本进程私有的写时拷贝页
static int set_prot(uint64_t a, size_t n, int rw) {
    uint64_t p0 = a & ~(uint64_t)0x3FFF, p1 = (a + n + 0x3FFF) & ~(uint64_t)0x3FFF;
    if (rw) return mach_vm_protect(mach_task_self(), p0, p1 - p0, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS;
    return mach_vm_protect(mach_task_self(), p0, p1 - p0, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS;
}

// 堆锚点核对（S2A_PEEK=<秒>:<值>:<偏移>,<偏移>…，诊断，只 Mac）：起局后等这么多秒，在每个「堆起点 + 偏移」前后 256 KB 里找等于 <值> 的 4 字节，
//   打最近的几处与偏移差。用途：拿金手指作者的真机地址（那里原本存着已知值，如 16:9 画幅 0x3FE38E39）量本局堆布局在那一段差多少
static void *peek_thread(void *arg) {
    char *spec = arg; unsigned secs = 0, val = 0; char *p = spec;
    if (sscanf(p, "%u:%x:", &secs, &val) != 2) { LOG("【红】堆锚点：S2A_PEEK 格式不认：%s", spec); return NULL; }
    LOG("堆锚点：%u 秒后在已知值 %#x 附近核对", secs, val);
    p = strchr(p, ':') + 1; p = strchr(p, ':') + 1;
    for (unsigned w = 0; w < secs; w++) { sleep(1); if (w % 5 == 4) LOG("堆锚点：已等 %u 秒", w + 1); }
    uint64_t hl = 0, hn, al, an, ph; void s2a_mem_guest_split(uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *); s2a_mem_guest_split(&hl, &hn, &al, &an, &ph);
    LOG("堆锚点：开始核对（堆起点 %#llx，已用 %#llx）", (unsigned long long)hl, (unsigned long long)hn);
    static uint32_t buf[0x4000 / 4];
    for (char *t = strtok(p, ","); t; t = strtok(NULL, ",")) {
        uint64_t off = strtoull(t, NULL, 16), lo = (off > 0x40000 ? off - 0x40000 : 0) & ~(uint64_t)0x3fff; char line[400]; int n = 0, k = 0;
        { uint32_t v0 = 0; mach_vm_size_t g0 = 0; mach_vm_read_overwrite(mach_task_self(), hl + off, 4, (mach_vm_address_t)&v0, &g0);
          n += snprintf(line + n, sizeof line - (size_t)n, "堆锚点 %#llx（此处值 %#x）：", (unsigned long long)off, v0); }
        for (uint64_t a = lo; a < off + 0x40000 && a + sizeof buf <= hn && k < 8; a += sizeof buf) {
            mach_vm_size_t got = 0;
            if (mach_vm_read_overwrite(mach_task_self(), hl + a, sizeof buf, (mach_vm_address_t)buf, &got) != KERN_SUCCESS) continue;
            for (unsigned q = 0; q < sizeof buf / 4 && k < 8; q++) if (buf[q] == val) { n += snprintf(line + n, sizeof line - (size_t)n, " %+lld", (long long)(a + q * 4) - (long long)off); k++; }
        }
        LOG("%s%s", line, k ? "" : " 附近没有");
    }
    return NULL;
}
void s2a_nvos_trace_install(void) {
    { const char *pk = getenv("S2A_PEEK"); if (pk && *pk) { pthread_t t; pthread_create(&t, NULL, peek_thread, strdup(pk)); pthread_detach(t); } }
    const char *out = getenv("S2A_NVOS_TRACE");
    if (!out || !*out) return;
    module_t *sdk = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "sdk")) sdk = &g_mod[i];
    if (!sdk) { LOG("【红】NvOs 分配记录：没有 sdk 模块"); return; }
    uint32_t *f[4];
    for (int k = 0; k < 4; k++) {
        f[k] = module_sym(sdk, k_name[k]);
        if (!f[k] || (f[k][0] & 0xFC000000u) != 0x14000000u) { LOG("【红】NvOs 分配记录：sdk 的 %s 不是一条 B（%p），不装", k_name[k], (void *)f[k]); return; }
        int64_t d = (int64_t)((uint64_t)f[k][0] << 38) >> 36;   // imm26 符号扩展 × 4
        g_ent[k] = (uint64_t)f[k]; g_tgt[k] = (uint64_t)f[k] + (uint64_t)d;
    }
    if (f[0][1] != 0 || f[0][2] != 0) { LOG("【红】NvOs 分配记录：NvOsAlloc+4 / +8 不是 udf 填充（%08x %08x），不装", f[0][1], f[0][2]); return; }
    g_fd = open(out, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (g_fd < 0) { LOG("【红】NvOs 分配记录：打不开 %s", out); return; }
    g_ret = (uint64_t)&f[0][1];
    for (int k = 0; k < 4; k++) {
        if (set_prot((uint64_t)f[k], 8, 1)) { LOG("【红】NvOs 分配记录：%s 所在页改不成可写", k_name[k]); g_ret = 0; return; }
        f[k][0] = 0xD4200000u | ((0x7DE0u + (uint32_t)k) << 5);
        if (k == 0) { f[0][1] = 0xD4200000u | (0x7DEFu << 5); f[0][2] = 0xD4200000u | (0x7DEEu << 5); g_sret = (uint64_t)&f[0][2]; }
        set_prot((uint64_t)f[k], 8, 0);
        sys_icache_invalidate(f[k], 8);
    }
    if (getenv("S2A_NEW_TRACE")) {
        { const char *w = getenv("S2A_NEW_WIN"); unsigned long long a, b; if (w && sscanf(w, "%llx-%llx", &a, &b) == 2) { g_win_lo = a; g_win_hi = b; } }
        module_t *mm = NULL; for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) mm = &g_mod[i];
        uint64_t hl = 0, hn, al, an, ph; void s2a_mem_guest_split(uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *); s2a_mem_guest_split(&hl, &hn, &al, &an, &ph); g_heap_lo = hl;
        static const char *nn[2] = {"_Znwm", "_Znam"};
        if (mm && f[0][3] == 0 && !set_prot((uint64_t)&f[0][3], 4, 1)) {
            f[0][3] = 0xD4200000u | (0x7DEDu << 5); set_prot((uint64_t)&f[0][3], 4, 0); sys_icache_invalidate(&f[0][3], 4); g_nret = (uint64_t)&f[0][3];
            for (int k = 0; k < 2; k++) {
                uint32_t *e = module_sym(mm, nn[k]);
                if (!e || *e != 0xF81E0FF3u || set_prot((uint64_t)e, 4, 1)) { LOG("【红】operator new 记录：main 的 %s 入口不是 str x19,[sp,#-0x20]!，不装", nn[k]); continue; }
                *e = 0xD4200000u | (0x7DE9u << 5); set_prot((uint64_t)e, 4, 0); sys_icache_invalidate(e, 4); g_new_ent[k] = (uint64_t)e;
            }
            for (const char *q = getenv("S2A_NEW_FN"); q && *q && g_nfn < NFN;) {
                unsigned long long o = 0; const char *c = strchr(q, ',');
                if (strncmp(q, "main+", 5) || sscanf(q + 5, "%llx", &o) != 1) break;
                uint32_t *e = (uint32_t *)(mm->base + o);
                if ((*e & 0xFFC003FFu) != 0xD10003FFu || set_prot((uint64_t)e, 4, 1)) { LOG("【红】堆分配记录：main+%llx 第一字不是 sub sp,sp,#imm（%08x），不装", o, *e); }
                else { g_fn[g_nfn].at = (uint64_t)e; g_fn[g_nfn].imm = (*e >> 10) & 0xFFF; snprintf(g_fn[g_nfn].name, sizeof g_fn[g_nfn].name, "fn%llx", o);
                       *e = 0xD4200000u | (0x7DEAu << 5); set_prot((uint64_t)e, 4, 0); sys_icache_invalidate(e, 4); g_nfn++; }
                q = c ? c + 1 : NULL;
            }
            LOG("operator new 记录：开（堆起点 %#llx，另记堆分配函数 %d 个）", (unsigned long long)hl, g_nfn);
        }
    }
    const char *sites = getenv("S2A_NVOS_SITES");
    for (const char *q = sites; q && *q && g_nsite < NSITE;) {
        char mod[16] = {0}; unsigned long long off = 0; const char *plus = strchr(q, '+'), *comma = strchr(q, ',');
        if (!plus || plus - q >= (long)sizeof mod || sscanf(plus + 1, "%llx", &off) != 1) break;
        memcpy(mod, q, (size_t)(plus - q));
        module_t *m = NULL; for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, mod)) m = &g_mod[i];
        uint32_t *at = m && off >= 4 ? (uint32_t *)(m->base + off - 4) : NULL;
        if (at && ((*at & 0xFC000000u) == 0x94000000u || (((*at & 0xFFFFFC1Fu) == 0xD63F0000u || (*at & 0xFFFFFC1Fu) == 0xD61F0000u) && ((*at >> 5) & 31) != 30)) && !set_prot((uint64_t)at, 4, 1)) {
            g_site[g_nsite].at = at; g_site[g_nsite].orig = *at; snprintf(g_site[g_nsite].name, sizeof g_site[g_nsite].name, "%s+%llx", mod, off);
            *at = 0xD4200000u | (0x7DE8u << 5); set_prot((uint64_t)at, 4, 0); sys_icache_invalidate(at, 4); g_nsite++;
        } else LOG("【红】NvOs 分配记录：调用点 %s+%llx 前一条不是 BL / BLR，不装", mod, off);
        q = comma ? comma + 1 : NULL;
    }
    LOG("NvOs 分配记录：开（sdk 四个 NvOs 分配函数入口改成陷入、调用点 %d 个，记到 %s）", g_nsite, out);
}
#else
int s2a_nvos_trace_trap(void *ctx) { (void)ctx; return 0; }
void s2a_nvos_trace_install(void) {}
#endif
