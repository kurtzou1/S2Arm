// 栈指针未对齐替做读写的安卓（Linux arm64 信号上下文）版：与 runtime/tests/t_emul_sp.c（苹果 ucontext 版）同四条，
//   造一个 mcontext（regs / sp / pc + __reserved 里的 fpsimd_context 记录），sp 故意差 8 字节没对齐，pc 指向指令字。
// 期望按 A64 编码手算，不跑被测实现推：
//   ① str x1, [sp]（f90003e1）：[sp] 8 字节 = x1，pc + 4，sp 不变
//   ② stp x29, x30, [sp, #-16]!（a9bf7bfd）：[sp-16] = x29、[sp-8] = x30，sp -= 16，pc + 4
//   ③ ldp x16, x17, [sp], #32（a8c247f0）：x16 = [sp]、x17 = [sp+8]，sp += 32
//   ④ ldxr x0, [sp]（c85f7fe0，独占读）不认 → 返回 0，寄存器、pc 都不动
//   ⑤ 没有 fpsimd 记录的上下文 → 返回 0（不替做，照崩溃处理）
// 只能在 arm64 安卓上跑：NDK 编出来 adb push 到手机执行（见文件末尾用法）。
#include <signal.h>
#include <asm/sigcontext.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ucontext.h>
int s2a_emul_sp_unaligned(void *ucv);
static int count, fail;
#define EXPECT(name, want, got) do { unsigned long long w_ = (unsigned long long)(want), g_ = (unsigned long long)(got); count++; \
    if (w_ != g_) { fail++; printf("✗ %s：期望 %#llx → 真结果 %#llx\n", name, w_, g_); } } while (0)
static uint8_t stack[256] __attribute__((aligned(16)));
static uint32_t insn;
static void setup(ucontext_t *uc, uint32_t w, int with_fp) {
    memset(uc, 0, sizeof *uc);
    insn = w; uc->uc_mcontext.pc = (uint64_t)(uintptr_t)&insn; uc->uc_mcontext.sp = (uint64_t)(uintptr_t)(stack + 128 + 8);   // 差 8 字节没对齐
    for (int k = 0; k < 29; k++) uc->uc_mcontext.regs[k] = 0x1000 + (uint64_t)k;
    uc->uc_mcontext.regs[29] = 0xF29; uc->uc_mcontext.regs[30] = 0xF30;
    if (with_fp) {   // 内核信号帧的样子：fpsimd_context 打头，后面一个 magic 0 的结束头
        struct fpsimd_context *f = (struct fpsimd_context *)(void *)uc->uc_mcontext.__reserved;
        f->head.magic = FPSIMD_MAGIC; f->head.size = sizeof *f;
    }
}
int main(void) {
    static ucontext_t uc; uint64_t sp0, v;
    setup(&uc, 0xF90003E1, 1); sp0 = uc.uc_mcontext.sp;
    EXPECT("① str x1,[sp]：模拟了", 1, s2a_emul_sp_unaligned(&uc));
    memcpy(&v, (void *)(uintptr_t)sp0, 8); EXPECT("① [sp] = x1", 0x1001, v);
    EXPECT("① pc + 4", (uint64_t)(uintptr_t)&insn + 4, uc.uc_mcontext.pc); EXPECT("① sp 不变", sp0, uc.uc_mcontext.sp);

    setup(&uc, 0xA9BF7BFD, 1); sp0 = uc.uc_mcontext.sp;
    EXPECT("② stp x29,x30,[sp,#-16]!：模拟了", 1, s2a_emul_sp_unaligned(&uc));
    memcpy(&v, (void *)(uintptr_t)(sp0 - 16), 8); EXPECT("② [sp-16] = x29", 0xF29, v);
    memcpy(&v, (void *)(uintptr_t)(sp0 - 8), 8); EXPECT("② [sp-8] = x30", 0xF30, v);
    EXPECT("② sp -= 16", sp0 - 16, uc.uc_mcontext.sp);

    setup(&uc, 0xA8C247F0, 1); sp0 = uc.uc_mcontext.sp;
    v = 0xAAAA; memcpy((void *)(uintptr_t)sp0, &v, 8); v = 0xBBBB; memcpy((void *)(uintptr_t)(sp0 + 8), &v, 8);
    EXPECT("③ ldp x16,x17,[sp],#32：模拟了", 1, s2a_emul_sp_unaligned(&uc));
    EXPECT("③ x16 = [sp]", 0xAAAA, uc.uc_mcontext.regs[16]); EXPECT("③ x17 = [sp+8]", 0xBBBB, uc.uc_mcontext.regs[17]);
    EXPECT("③ sp += 32", sp0 + 32, uc.uc_mcontext.sp);

    setup(&uc, 0xC85F7FE0, 1); sp0 = uc.uc_mcontext.sp;
    EXPECT("④ ldxr 不认", 0, s2a_emul_sp_unaligned(&uc));
    EXPECT("④ pc 不动", (uint64_t)(uintptr_t)&insn, uc.uc_mcontext.pc); EXPECT("④ x0 不动", 0x1000, uc.uc_mcontext.regs[0]);

    setup(&uc, 0xF90003E1, 0);
    EXPECT("⑤ 没有 fpsimd 记录不替做", 0, s2a_emul_sp_unaligned(&uc));
    EXPECT("⑤ pc 不动", (uint64_t)(uintptr_t)&insn, uc.uc_mcontext.pc);

    printf("%s t_emul_sp_android：%d 项检查，%d 项不符\n", fail ? "✗" : "✓", count, fail);
    return fail != 0;
}
// android/test.sh 用固定 NDK 编译链接（宿主跑不了：要 arm64 安卓信号上下文）；在手机上执行：
// 用法（出包机）：$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android29-clang -O1 -Iruntime/include \
//   android/tests/emul_sp_android_test.c runtime/src/emul_sp.c runtime/src/emul_ld.c runtime/src/emul_st.c -o t_emul_sp_android
//   adb push t_emul_sp_android /data/local/tmp/ && adb shell /data/local/tmp/t_emul_sp_android
