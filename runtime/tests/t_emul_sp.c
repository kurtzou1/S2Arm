// 栈指针未对齐时替游戏做那一条读写（runtime/src/emul_sp.c，11-13）：造一个信号上下文，sp 故意差 8 字节没对齐，pc 指向指令字。
// 期望按 A64 编码手算，不跑被测实现推：
//   ① str x1, [sp]（f90003e1，一款游戏 main+0x4e8a18 原样）：[sp] 8 字节 = x1，pc + 4，sp 不变
//   ② stp x29, x30, [sp, #-16]!（a9bf7bfd，门块与函数序言）：[sp-16] = x29、[sp-8] = x30，sp -= 16，pc + 4
//   ③ ldp x16, x17, [sp], #32（a8c247f0，门返回）：x16 = [sp]、x17 = [sp+8]，sp += 32
//   ④ ldxr x0, [sp]（c85f7fe0，独占读）不认 → 返回 0，寄存器、pc 都不动
#include "s2a_emul_ld.h"
#include <stdio.h>
#include <string.h>
#include <sys/ucontext.h>
int s2a_emul_sp_unaligned(void *ucv);
static int count, fail;
#define EXPECT(name, want, got) do { unsigned long long w_ = (unsigned long long)(want), g_ = (unsigned long long)(got); count++; if (w_ != g_) { fail++; printf("✗ %s：期望 %#llx → 真结果 %#llx\n", name, w_, g_); } } while (0)
static uint8_t stack[256] __attribute__((aligned(16)));
static uint32_t insn;
static void setup(_STRUCT_MCONTEXT64 *mc, ucontext_t *uc, uint32_t w) {
    memset(mc, 0, sizeof *mc); memset(uc, 0, sizeof *uc); uc->uc_mcontext = mc;
    insn = w; mc->__ss.__pc = (uint64_t)(uintptr_t)&insn; mc->__ss.__sp = (uint64_t)(uintptr_t)(stack + 128 + 8);   // 差 8 字节没对齐
    for (int k = 0; k < 29; k++) mc->__ss.__x[k] = 0x1000 + (uint64_t)k;
    mc->__ss.__fp = 0xF29; mc->__ss.__lr = 0xF30;
}
int main(void) {
    _STRUCT_MCONTEXT64 mc; ucontext_t uc; uint64_t sp0, v;
    setup(&mc, &uc, 0xF90003E1); sp0 = mc.__ss.__sp;
    EXPECT("① str x1,[sp]：模拟了", 1, s2a_emul_sp_unaligned(&uc));
    memcpy(&v, (void *)(uintptr_t)sp0, 8); EXPECT("① [sp] = x1", 0x1001, v);
    EXPECT("① pc + 4", (uint64_t)(uintptr_t)&insn + 4, mc.__ss.__pc); EXPECT("① sp 不变", sp0, mc.__ss.__sp);

    setup(&mc, &uc, 0xA9BF7BFD); sp0 = mc.__ss.__sp;
    EXPECT("② stp x29,x30,[sp,#-16]!：模拟了", 1, s2a_emul_sp_unaligned(&uc));
    memcpy(&v, (void *)(uintptr_t)(sp0 - 16), 8); EXPECT("② [sp-16] = x29", 0xF29, v);
    memcpy(&v, (void *)(uintptr_t)(sp0 - 8), 8); EXPECT("② [sp-8] = x30", 0xF30, v);
    EXPECT("② sp -= 16", sp0 - 16, mc.__ss.__sp);

    setup(&mc, &uc, 0xA8C247F0); sp0 = mc.__ss.__sp;
    v = 0xAAAA; memcpy((void *)(uintptr_t)sp0, &v, 8); v = 0xBBBB; memcpy((void *)(uintptr_t)(sp0 + 8), &v, 8);
    EXPECT("③ ldp x16,x17,[sp],#32：模拟了", 1, s2a_emul_sp_unaligned(&uc));
    EXPECT("③ x16 = [sp]", 0xAAAA, mc.__ss.__x[16]); EXPECT("③ x17 = [sp+8]", 0xBBBB, mc.__ss.__x[17]); EXPECT("③ sp += 32", sp0 + 32, mc.__ss.__sp);

    setup(&mc, &uc, 0xC85F7FE0); sp0 = mc.__ss.__sp;
    EXPECT("④ ldxr 不认：返回 0", 0, s2a_emul_sp_unaligned(&uc));
    EXPECT("④ pc 不动", (uint64_t)(uintptr_t)&insn, mc.__ss.__pc); EXPECT("④ x0 不动", 0x1000, mc.__ss.__x[0]);
    if (fail) { printf("✗ t_emul_sp：%d / %d 项失败\n", fail, count); return 1; }
    printf("✓ t_emul_sp：%d 项，失败 0\n", count); return 0;
}
