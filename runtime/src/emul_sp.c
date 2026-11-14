// 游戏代码栈指针未对齐时替它做那一条读写（接口见 runtime/src/crash.c 的调用处；读写解码复用 emul_ld.c / emul_st.c）
#include "s2a_emul_ld.h"
#include "s2a_emul_st.h"
#include <string.h>
#if defined(__APPLE__)
#include <sys/ucontext.h>
// 栈指针未对齐（ESR 异常类别 0x26，11-13）：Switch 系统不给应用开 SP 对齐检查（SCTLR_EL1.SA0 = 0），游戏里个别函数 `sub sp, sp, #0x98`
//   这类不是 16 倍数的帧照跑；苹果系统开着，接下来以 sp 为基址的每条读写都 SIGBUS（一款 0100C3601518C000 在 main+0x4e8a18 `str x1, [sp]`）。
//   照参考实现（NCE 的对齐故障处理）在信号里替游戏做这一条读 / 写：地址就是原地址（栈是正常可访问内存，只是没对齐），寄存器与变址回写照常，pc 前进；
//   sp 不动，函数尾 `add sp` 后自然对齐。不认识的（独占、原子…）返回 0，调用方照崩溃处理
int s2a_emul_sp_unaligned(void *ucv) {
    ucontext_t *uc = ucv; _STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss; _STRUCT_ARM_NEON_STATE64 *ns = &uc->uc_mcontext->__ns;
    uint32_t insn = *(const uint32_t *)(uintptr_t)ss->__pc;
    s2a_regs r;
    for (int k = 0; k < 29; k++) r.x[k] = ss->__x[k];
    r.x[29] = ss->__fp; r.x[30] = ss->__lr; r.sp = ss->__sp;
    for (int k = 0; k < 32; k++) memcpy(r.v[k], &ns->__v[k], 16);
    if (!s2a_emul_store_regs(insn, &r, 0, 0, ~0ull, NULL, NULL, NULL) && !s2a_emul_load_regs(insn, &r, 0, 0, ~0ull, NULL, NULL, NULL)) return 0;
    for (int k = 0; k < 29; k++) ss->__x[k] = r.x[k];
    ss->__fp = r.x[29]; ss->__lr = r.x[30]; ss->__sp = r.sp;
    for (int k = 0; k < 32; k++) memcpy(&ns->__v[k], r.v[k], 16);
    ss->__pc += 4;
    return 1;
}
#elif defined(__ANDROID__) && defined(__aarch64__)
#include <signal.h>
#include <asm/sigcontext.h>
// 安卓（Linux arm64）同一件事：内核同样给 EL0 开着 SP 对齐检查，SIGBUS（si_code BUS_ADRALN，ESR 类别 0x26）。
//   通用寄存器在 mcontext.regs[0..30] / sp / pc；向量寄存器在 __reserved 里的 fpsimd_context 记录（找不到就不替做，照崩溃处理）。
static struct fpsimd_context *fpsimd_of(mcontext_t *mc) {
    unsigned char *at = (unsigned char *)mc->__reserved; size_t left = sizeof mc->__reserved;
    while (left >= sizeof(struct _aarch64_ctx)) {
        struct _aarch64_ctx *h = (struct _aarch64_ctx *)(void *)at;
        if (!h->magic || h->size < sizeof *h || h->size > left) return NULL;
        if (h->magic == FPSIMD_MAGIC && h->size >= sizeof(struct fpsimd_context)) return (struct fpsimd_context *)(void *)h;
        at += h->size; left -= h->size;
    }
    return NULL;
}
int s2a_emul_sp_unaligned(void *ucv) {
    ucontext_t *uc = ucv; mcontext_t *mc = &uc->uc_mcontext;
    struct fpsimd_context *fp = fpsimd_of(mc);
    if (!fp) return 0;
    uint32_t insn = *(const uint32_t *)(uintptr_t)mc->pc;
    s2a_regs r;
    for (int k = 0; k < 31; k++) r.x[k] = mc->regs[k];
    r.sp = mc->sp;
    for (int k = 0; k < 32; k++) memcpy(r.v[k], &fp->vregs[k], 16);
    if (!s2a_emul_store_regs(insn, &r, 0, 0, ~0ull, NULL, NULL, NULL) && !s2a_emul_load_regs(insn, &r, 0, 0, ~0ull, NULL, NULL, NULL)) return 0;
    for (int k = 0; k < 31; k++) mc->regs[k] = r.x[k];
    mc->sp = r.sp;
    for (int k = 0; k < 32; k++) memcpy(&fp->vregs[k], r.v[k], 16);
    mc->pc += 4;
    return 1;
}
#endif
