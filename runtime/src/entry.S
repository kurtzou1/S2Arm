// 原生层入口汇编（旧库 sw/host/entry.S 改后搬：删掉未实现导入的静态桩表，新架构不按名字给 SDK 函数接桩）。
// 1) sw_gate：改写器把 svc / cntpct 读换成「bl 到本入口」。进来时 lr = 门块返回点（gate_dispatch 据此查是哪个门），
//    切到本线程宿主栈，保存 x0-x30 / q0-q31 / nzcv / fpsr / fpcr 到连续帧，调 gate_dispatch(ret, regs)，回读寄存器，返回。
// 2) xs_stubs / xs_entry：交给客体的宿主函数一律经切栈桩（xstack.c）。
// 3) sw_thread_enter：客体线程起点。4) sw_call_on_stack：主线程在客体栈上跑 SDK 初始化。
#include "../../platform/plat_asm.h"

    .text
// 切栈（xstack.c）：宿主代码不跑在客体栈上。本线程槽 {cur, top, bottom} 在 TSD 基址 + g_xs_off；没有槽 = 不切。
//    xs_stubs：第 k 个 = movz x9,#k; b xs_entry（装载器把交给客体的宿主函数解析成这些桩，目标在 g_xs_fn[k]）。
//    xs_entry 只动 x9..x17（AAPCS 临时寄存器，不是参数）；x0..x8、q0..q7 原样进被调函数，返回值原样带回。
    .globl PLAT_ASM_SYM(xs_stubs)
    .p2align 3
PLAT_ASM_SYM(xs_stubs):
    .set k, 0
    .rept 8192                // = xstack.c XS_MAX
    movz x9, #k
    b PLAT_ASM_SYM(xs_entry)
    .set k, k + 1
    .endr

    .p2align 2
PLAT_ASM_SYM(xs_entry):
    PLAT_ASM_ADRP(x16, PLAT_ASM_SYM(g_xs_fn))
    PLAT_ASM_ADD(x16, PLAT_ASM_SYM(g_xs_fn))
    ldr x16, [x16, x9, lsl #3]           // 目标
    PLAT_ASM_ADRP(x10, PLAT_ASM_SYM(g_xs_off))
    PLAT_ASM_LDR(x10, x10, PLAT_ASM_SYM(g_xs_off))
    cbz x10, 1f                          // 偏移未就绪：直接跳
    PLAT_TSD_BASE(x11)
    PLAT_TSD_BASE_SECOND(x11)
    and x11, x11, #~7
    ldr x12, [x11, x10]                  // 本线程槽（偏移是字节，不再移位）
    cbz x12, 1f                          // 没登记：直接跳
    ldr x14, [x12, #8]                   // top
    ldr x15, [x12, #16]                  // bottom
    mov x17, sp
    cmp x17, x14
    b.hi 2f                              // sp 在宿主栈之上 ⇒ 在客体栈
    cmp x17, x15
    b.hi 1f                              // bottom < sp ≤ top ⇒ 已在宿主栈：直接跳
2:  ldr x13, [x12]                       // cur
    sub x13, x13, #208                   // 新帧：64 字节栈参数副本 + 保存区 + 钩子保存区（[0,64) 参数副本 / [64,80) 客体sp+旧cur / [80,96) fp,lr / [96,104) 槽 / [112,176) q0..q3 / [176,208) 备用）
    and x13, x13, #~15
    mov x9, x17                          // 拷客体 sp 起 64 字节（栈上传的参数，余量），不越过客体栈顶（槽 +24，0 = 不限）
    mov x14, x13
    add x15, x17, #64
    ldr x10, [x12, #24]
    cbz x10, 3f
    cmp x15, x10
    csel x15, x10, x15, hi
    cmp x9, x15
    b.hs 8f
3:  ldp x10, x11, [x9], #16
    stp x10, x11, [x14], #16
    cmp x9, x15
    b.lo 3b
8:  ldr x10, [x12]
    stp x17, x10, [x13, #64]             // 客体 sp、旧 cur
    stp x29, x30, [x13, #80]             // 帧记录：fp 链接回客体帧（回溯能穿过去）
    str x12, [x13, #96]                  // 槽
    str x13, [x12]                       // cur = 新帧
    mov sp, x13
    add x29, sp, #80
    blr x16
    // 惰性取核钩子（10-30）：只有这条路径回客体代码（下面 ret 之后就是客体代码）；1: br x16 的尾跳不回，故不挂。
    //   x13 是 caller-saved、被 blr 打掉了，这里一律用 sp 寻址。
    //   先看开关再存寄存器：开关 0（缺省旧行为）时这里只多 4 条指令、不写任何内存，"关掉零行为变化" 是字面意义上的。
    PLAT_ASM_ADRP(x16, PLAT_ASM_SYM(g_lazy_core))
    PLAT_ASM_ADD(x16, PLAT_ASM_SYM(g_lazy_core))
    ldr w16, [x16]
    cbz w16, 9f                          // 0 = 关；-1 首次（钩子读 S2A_LAZY_CORE 后写回）/ 1 开
    stp x0, x1, [sp, #0]                 // 覆盖已用完的栈参数副本 [0,64)
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp q0, q1, [sp, #112]               // 整数返回 x0/x1、HFA 最多 q0..q3；x8 / x9..x18 出口无用，标志位 blr 已经打掉
    stp q2, q3, [sp, #144]
    bl PLAT_ASM_SYM(s2a_guest_return)    // 宿主栈帧里调：不碰客体栈（entry.S:78 真机 svc 不碰用户栈）
    ldp q2, q3, [sp, #144]
    ldp q0, q1, [sp, #112]
    ldp x6, x7, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
9:  ldr x12, [sp, #96]
    ldp x17, x10, [sp, #64]
    str x10, [x12]                       // 还原 cur
    ldp x29, x30, [sp, #80]
    mov sp, x17
    ret
1:  br x16

    .globl PLAT_ASM_SYM(sw_gate)
    .p2align 2
PLAT_ASM_SYM(sw_gate):
    // 切栈后在宿主栈上开 832 字节帧：[0,800) 保存 x0..x30 / q0..q31 / 状态，门可读改 x0..x30；[800] 客体 sp（含下面借的 32 字节）、[808] 旧 cur、[816] 槽（0 = 不切）。
    // 借客体栈 32 字节暂存 x15..x17 换出三个临时寄存器（真机 svc 不碰用户栈；这是唯一触碰，远小于原来的 800 字节 + 整个门的 C 调用链）
    stp x16, x17, [sp, #-32]!
    str x15, [sp, #16]
    mrs x15, nzcv                        // 下面的比较会改标志：先存（门内存的 nzcv 必须是客体的；cntpct 门处在客体代码中间，标志可能正活着）
    str x15, [sp, #24]
    mov x15, sp                          // 客体 sp（含借的 32 字节）
    PLAT_ASM_ADRP(x16, PLAT_ASM_SYM(g_xs_off))
    PLAT_ASM_LDR(x16, x16, PLAT_ASM_SYM(g_xs_off))
    cbz x16, 4f                          // 偏移未就绪：不切栈
    PLAT_TSD_BASE(x17)
    PLAT_TSD_BASE_SECOND(x17)
    and x17, x17, #~7
    ldr x16, [x17, x16]                  // 槽（偏移是字节，不再移位）
    cbz x16, 4f
    ldr x17, [x16, #8]
    cmp x15, x17
    b.hi 5f                              // 在客体栈：切
    ldr x17, [x16, #16]
    cmp x15, x17
    b.ls 5f
4:  sub x17, x15, #832                   // 不切（没槽 / 已在宿主栈）：就地开帧，槽记 0
    and x17, x17, #~15
    str xzr, [x17, #816]
    b 6f
5:  ldr x17, [x16]                       // 切：在 cur 下开帧
    sub x17, x17, #832
    and x17, x17, #~15
    str x16, [x17, #816]
    ldr x15, [x16]
    str x15, [x17, #808]                 // 旧 cur
    str x17, [x16]                       // cur = 新帧
    mov x15, sp
6:  str x15, [x17, #800]
    mov sp, x17
    ldr x17, [sp, #800]                  // 取回借存的标志与 x15..x17
    ldr x15, [x17, #24]
    msr nzcv, x15
    ldr x15, [x17, #16]
    ldr x16, [x17]
    ldr x17, [x17, #8]
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    stp q0, q1, [sp, #256]
    stp q2, q3, [sp, #288]
    stp q4, q5, [sp, #320]
    stp q6, q7, [sp, #352]
    stp q8, q9, [sp, #384]
    stp q10, q11, [sp, #416]
    stp q12, q13, [sp, #448]
    stp q14, q15, [sp, #480]
    stp q16, q17, [sp, #512]
    stp q18, q19, [sp, #544]
    stp q20, q21, [sp, #576]
    stp q22, q23, [sp, #608]
    stp q24, q25, [sp, #640]
    stp q26, q27, [sp, #672]
    stp q28, q29, [sp, #704]
    stp q30, q31, [sp, #736]
    mrs x9, nzcv
    str x9, [sp, #768]
    mrs x9, fpsr
    str x9, [sp, #776]
    mrs x9, fpcr
    str x9, [sp, #784]
    mov x0, x30              // 返回点 = 门标识
    mov x1, sp               // regs
    bl PLAT_ASM_SYM(gate_dispatch)
    ldr x9, [sp, #784]
    msr fpcr, x9
    ldr x9, [sp, #776]
    msr fpsr, x9
    ldr x9, [sp, #768]
    msr nzcv, x9
    ldp q0, q1, [sp, #256]
    ldp q2, q3, [sp, #288]
    ldp q4, q5, [sp, #320]
    ldp q6, q7, [sp, #352]
    ldp q8, q9, [sp, #384]
    ldp q10, q11, [sp, #416]
    ldp q12, q13, [sp, #448]
    ldp q14, q15, [sp, #480]
    ldp q16, q17, [sp, #512]
    ldp q18, q19, [sp, #544]
    ldp q20, q21, [sp, #576]
    ldp q22, q23, [sp, #608]
    ldp q24, q25, [sp, #640]
    ldp q26, q27, [sp, #672]
    ldp q28, q29, [sp, #704]
    ldp q30, q31, [sp, #736]
    // 门可改任意通用寄存器：svc 出参在 x0..x8，mrs cntpct 的目标可以是任意 xN（sdk 33 处里 14 处是 x19..x23）
    // ⇒ x0..x29 全部回读（x18 是苹果平台寄存器，客体的 x18 已改写到线程槽，跳过不碰）
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldr x19, [sp, #152]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    // 回客体栈：还原 cur；门改过的 x16 / x17 经借存位带回（帧里的值写进客体栈借存位，切回后弹出）
    ldr x17, [sp, #816]
    cbz x17, 7f
    ldr x16, [sp, #808]
    str x16, [x17]
7:  ldr x16, [sp, #800]
    ldr x17, [sp, #128]
    str x17, [x16]
    ldr x17, [sp, #136]
    str x17, [x16, #8]
    mov sp, x16
    ldp x16, x17, [sp], #32
    ret
// 门的结束标记：门的进出两头以客体 sp 为基址读写（借的 32 字节）；客体 sp 没对齐时这几条在苹果上 SIGBUS，crash.c 认 [sw_gate, sw_gate_end) 替它做（emul_sp.c）
    .globl PLAT_ASM_SYM(sw_gate_end)
PLAT_ASM_SYM(sw_gate_end):

// sw_thread_enter(entry, arg, sp)：客体线程起点。切到 SDK 给的客体栈，x0 = 参数调入口；
//    Horizon 线程须经 ExitThread 退出，入口返回即报错。
    .globl PLAT_ASM_SYM(sw_thread_enter)
    .p2align 2
PLAT_ASM_SYM(sw_thread_enter):
    mov sp, x2
    mov x29, #0
    mov x16, x0
    mov x0, x1
    adr x30, 1f
    br x16
1:  bl PLAT_ASM_SYM(sw_thread_returned)
    brk #0

// sw_call_on_stack(fn, sp)：在给定栈上调 fn()，返回后切回原栈（客体主线程用：guest_main 整段跑在主线程客体栈上）
    .globl PLAT_ASM_SYM(sw_call_on_stack)
    .p2align 2
PLAT_ASM_SYM(sw_call_on_stack):
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x9, sp
    sub x1, x1, #16
    str x9, [x1]                         // 新栈顶下 16 字节存原 sp
    mov sp, x1
    blr x0
    ldr x9, [sp]
    mov sp, x9
    ldp x29, x30, [sp], #16
    ret

// sw_touch_tramp：写跟踪 A 方案的改道落点（touch.c）。缺页处理把游戏线程的 pc 改到这里、sp 改到宿主帧、x0 = 缺页地址，
//    在正常上下文里调 s2a_touch_body（同步回写 GPU 数据），然后 brk 陷入：SIGTRAP 处理按缺页时存下的整套寄存器恢复、重执行那条写
#if defined(__APPLE__)
    .globl PLAT_ASM_SYM(sw_touch_tramp)
    .globl PLAT_ASM_SYM(sw_touch_brk)
    .p2align 2
PLAT_ASM_SYM(sw_touch_tramp):
    mov x29, #0
    bl PLAT_ASM_SYM(s2a_touch_body)
PLAT_ASM_SYM(sw_touch_brk):
    brk #0x7a5
#endif
#if defined(__ANDROID__)
    .section .note.GNU-stack,"",%progbits
#endif
