// 双补丁岛的 brk 兜底（原生层 10-30）：改写器双岛模式下，前岛（基址前）和后岛（键页后）都够不着的必改点原地写成 brk #(0x8000 + 序号)，
//   点表在 fixups.tsv 的 # TRAP 行（loader.c 读进 module_t.traps）。执行到时 SIGTRAP（crash.c 先问这里）：按序号查表、核模块与偏移，
//   照补丁区里那个点本来的块模拟原指令（与 runtime/rewriter/rewriter.c gensite 同语义），然后 pc += 4：
//     tpidr_r   mrs xN, tpidr_el0    → xN = 线程槽 KTLS（线程槽基址 + 键页 KTLS 偏移，与块里 tp() + slot() 同一取法）
//     tpidrro_r mrs xN, tpidrro_el0  → xN = 线程槽 KTLR
//     tpidr_w   msr tpidr_el0, xN    → 线程槽 KTLS = xN
//     ctr       mrs xN, ctr_el0      → xN = Switch 常数 0x8444C004
//   N = 31 时读丢弃、写 0（xzr）。每点记命中次数，收局打一行（s2a_trap_report）；热点要另想办法（单次陷入约几 µs）。
#include "native.h"
#include <signal.h>
#include <sys/ucontext.h>

// 线程槽基址：与补丁块的 tp() 逐条相同——苹果读 tpidrro_el0（不掩低位，块里也不掩），安卓读 tpidr_el0 再取 [x − 8]（bionic TLS_SLOT_BIONIC_TLS）
static uint64_t slot_base(void) {
#if defined(__aarch64__)
    uint64_t t;
#if defined(__ANDROID__)
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(t));
    return *(const uint64_t *)(t - 8);
#else
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(t));
    return t;
#endif
#else
    return 0;
#endif
}
#if defined(__ANDROID__)
#define REG(uc, n) ((uc)->uc_mcontext.regs[n])
#define PC(uc) ((uc)->uc_mcontext.pc)
#else
static uint64_t *reg_at(ucontext_t *uc, unsigned n) { return n < 29 ? &uc->uc_mcontext->__ss.__x[n] : n == 29 ? &uc->uc_mcontext->__ss.__fp : &uc->uc_mcontext->__ss.__lr; }
#define REG(uc, n) (*reg_at((uc), (n)))
#define PC(uc) ((uc)->uc_mcontext->__ss.__pc)
#endif

#ifdef S2A_UNIT_TEST
uint64_t (*s2a_trap_test_slot_base)(void);   // 单测：换掉线程槽基址
#endif

// 远跳（出包线 10-31，brk #0xA000）：两岛都够不着的 x18 单元，改写器照常把块生成进岛，越射程的 B（原代码进岛、岛里跳回原代码）写成这条 brk、
//   fixups.tsv # FAR 行记 <从> <到>。这里按 pc 找模块（代码段或补丁岛）、按 from 二分，把 pc 设到 <到>：信号返回不受 B 的 ±128 MiB 射程限制。
//   块本身就是正常改写的 x18 块（虚拟 x18 槽等语义与岛内其余单元一样），每过一次单元多两次陷入（进、出）。入口计命中（= 单元执行次数）
static int far_jump(ucontext_t *uc, uint64_t pc) {   // → 1 认领；0 是这条 brk 但表里没有；−1 不是远跳 brk（交给按编号的陷入）
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->nfar) continue;
        int64_t off = (int64_t)(pc - (uint64_t)m->base);
        if (!((off >= 0 && (uint64_t)off < m->text_end) || s2a_in_patch(m, pc))) continue;
        if (*(const uint32_t *)pc != (0xD4200000u | S2A_FAR_IMM << 5)) return -1;   // pc 在本模块代码段 / 岛里才读指令字
        unsigned lo = 0, hi = m->nfar;
        while (lo < hi) { unsigned mid = (lo + hi) / 2; if (m->fars[mid].from < off) lo = mid + 1; else hi = mid; }
        if (lo == m->nfar || m->fars[lo].from != off) return 0;
        __atomic_fetch_add(&m->fars[lo].hits, 1, __ATOMIC_RELAXED);
        PC(uc) = (uint64_t)m->base + (uint64_t)m->fars[lo].to;
        return 1;
    }
    return -1;
}

__attribute__((weak)) int s2a_nvos_trace_trap(void *ctx) { (void)ctx; return 0; }   // nvos_trace.c 强定义：诊断记录 NvOs 分配的两个 brk（没开记录恒 0）；只链 traps.c 的单测用这个
int s2a_trap_brk(void *ctx) {
    ucontext_t *uc = ctx;
    uint64_t pc = PC(uc);
    if (s2a_nvos_trace_trap(ctx)) return 1;
    int fj = far_jump(uc, pc);
    if (fj >= 0) return fj;
    module_t *m = module_of((void *)pc);
    if (!m || !m->ntrap || pc < (uint64_t)m->base || pc - (uint64_t)m->base >= m->text_end) return 0;
    uint32_t w = *(const uint32_t *)pc, imm = (w >> 5) & 0xFFFF;
    if ((w & 0xFFE0001Fu) != 0xD4200000u || imm < S2A_TRAP_IMM0 || imm - S2A_TRAP_IMM0 >= m->ntrap) return 0;   // 游戏自己的 brk 照原路径
    struct s2a_trap *t = &m->traps[imm - S2A_TRAP_IMM0];
    if (t->off != pc - (uint64_t)m->base) return 0;
    const uint64_t *page = (const uint64_t *)(m->base + m->key_page_off);
#ifdef S2A_UNIT_TEST
    uint64_t base = s2a_trap_test_slot_base ? s2a_trap_test_slot_base() : slot_base();
#else
    uint64_t base = slot_base();
#endif
    unsigned n = t->reg;
    switch (t->kind) {
    case S2A_TRAP_TPIDR_R: case S2A_TRAP_TPIDRRO_R: {
        uint64_t v = *(const uint64_t *)(base + page[m->key_idx[t->kind == S2A_TRAP_TPIDR_R ? 1 : 2]]);
        if (n != 31) REG(uc, n) = v;
        break; }
    case S2A_TRAP_TPIDR_W:
        *(uint64_t *)(base + page[m->key_idx[1]]) = n == 31 ? 0 : REG(uc, n);
        break;
    case S2A_TRAP_CTR:
        if (n != 31) REG(uc, n) = 0x8444C004u;
        break;
    default:
        return 0;
    }
    __atomic_fetch_add(&t->hits, 1, __ATOMIC_RELAXED);
    PC(uc) = pc + 4;
    return 1;
}

static void far_report(const char *when, module_t *m) {   // 远跳：入口被执行的总次数、执行过的入口个数、最热的 8 个（命中多的单元要另想办法：每过一次两次陷入）
    uint64_t sum = 0; unsigned nent = 0, hit = 0, top[8] = {0}; int ntop = 0;
    for (unsigned j = 0; j < m->nfar; j++) {
        if (!m->fars[j].entry) continue;
        nent++; uint64_t h = __atomic_load_n(&m->fars[j].hits, __ATOMIC_RELAXED);
        if (!h) continue;
        hit++; sum += h;
        int k;
        if (ntop < 8) k = ntop++;
        else if (h > __atomic_load_n(&m->fars[top[7]].hits, __ATOMIC_RELAXED)) k = 7;
        else continue;
        top[k] = j;   // 插入后往前冒泡，top 按命中降序
        for (; k > 0 && m->fars[top[k]].hits > m->fars[top[k - 1]].hits; k--) { unsigned t = top[k]; top[k] = top[k - 1]; top[k - 1] = t; }
    }
    char b[512]; size_t n = 0;
    for (int k = 0; k < ntop && n < sizeof b - 48; k++)
        n += (size_t)snprintf(b + n, sizeof b - n, " +%#llx×%llu", (long long)m->fars[top[k]].from, (unsigned long long)m->fars[top[k]].hits);
    b[n] = 0;
    LOG("%s：%s 远跳 %u 个单元（brk #0xA000），执行过 %u 个，共 %llu 次（每次进出各陷入一次）；最热：%s", when, m->name, nent, hit, (unsigned long long)sum, n ? b : " 无");
}

void s2a_trap_report(const char *when) {
    static const char *const kn[] = {"tpidr_r", "tpidrro_r", "tpidr_w", "ctr"};
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (m->nfar) far_report(when, m);
        if (!m->ntrap) continue;
        char b[1536]; size_t k = 0; uint64_t sum = 0;
        for (unsigned j = 0; j < m->ntrap; j++) {
            uint64_t h = __atomic_load_n(&m->traps[j].hits, __ATOMIC_RELAXED); sum += h;
            if (j < 48 && k < sizeof b - 64)
                k += (size_t)snprintf(b + k, sizeof b - k, " +%#llx/%s×%llu", (unsigned long long)m->traps[j].off, kn[m->traps[j].kind & 3], (unsigned long long)h);
        }
        b[k] = 0;
        LOG("%s：%s 双补丁岛 brk 兜底 %u 处，共命中 %llu 次：%s%s", when, m->name, m->ntrap, (unsigned long long)sum, b, m->ntrap > 48 ? " …" : "");
    }
}
