// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

void *sw_xstack_wrap(const char *name, void *fn);
void sw_xstack_thread_init(uint64_t top, uint64_t gtop);
void sw_xstack_thread_fini(void);
int g_lazy_core;
void gate_dispatch(void) {}
void s2a_guest_return(void) {}
void s2a_touch_body(void) {}
void sw_thread_returned(void) {}

__attribute__((noinline)) static uint64_t raw20(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7,
                                                uint64_t a8, uint64_t a9, uint64_t a10, uint64_t a11, uint64_t a12, uint64_t a13, uint64_t a14, uint64_t a15,
                                                uint64_t a16, uint64_t a17, uint64_t a18, uint64_t a19) {
    return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19;
}

__attribute__((naked, used)) void guest_invoke(void *fn, const uint64_t *regs, const uint64_t *stack) {
    __asm__ volatile(
        "mov x16, x0\n mov x10, x1\n mov x11, x2\n mov x19, x30\n sub sp, sp, #16\n"
        "ldr x0, [x10, #0]\n ldr x1, [x10, #8]\n ldr x2, [x10, #16]\n ldr x3, [x10, #24]\n"
        "ldr x4, [x10, #32]\n ldr x5, [x10, #40]\n ldr x6, [x10, #48]\n ldr x7, [x10, #56]\n"
        "ldr x9, [x11, #0]\n str x9, [sp, #0]\n"
        "ldr x9, [x11, #8]\n str x9, [sp, #8]\n"
        "ldr x9, [x11, #16]\n str x9, [sp, #16]\n"
        "ldr x9, [x11, #24]\n str x9, [sp, #24]\n"
        "ldr x9, [x11, #32]\n str x9, [sp, #32]\n"
        "ldr x9, [x11, #40]\n str x9, [sp, #40]\n"
        "ldr x9, [x11, #48]\n str x9, [sp, #48]\n"
        "ldr x9, [x11, #56]\n str x9, [sp, #56]\n"
        "ldr x9, [x11, #64]\n str x9, [sp, #64]\n"
        "ldr x9, [x11, #72]\n str x9, [sp, #72]\n"
        "ldr x9, [x11, #80]\n str x9, [sp, #80]\n"
        "ldr x9, [x11, #88]\n str x9, [sp, #88]\n"
        "blr x16\n"
        "add sp, sp, #16\n"
        "mov x30, x19\n"
        "ret\n");
}

static uint64_t call_on_guest(void *fn, const uint64_t *regs, const uint64_t *stack, uint64_t guest_sp, int *sp_ok) {
    uint64_t host_sp = 0, after = 0, result = 0;
    __asm__ volatile("mov %[h], sp" : [h] "=r"(host_sp));
    __asm__ volatile(
        "mov x0, %[fn]\n mov x1, %[regs]\n mov x2, %[stack]\n"
        "mov sp, %[guest]\n"
        "bl _guest_invoke\n"
        "mov sp, %[host]\n"
        "mov %[after], sp\n"
        "mov %[result], x0\n"
        : [after] "=&r"(after), [result] "=&r"(result)
        : [fn] "r"(fn), [regs] "r"(regs), [stack] "r"(stack), [guest] "r"(guest_sp), [host] "r"(host_sp)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x19", "memory", "cc");
    *sp_ok = host_sp == after; return result;
}

int main(void) {
    long page = sysconf(_SC_PAGESIZE);
    uint8_t *guest = mmap(NULL, (size_t)page * 16, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (guest == MAP_FAILED) { perror("mmap"); return 1; }
    uint64_t guest_top = (uint64_t)(guest + page * 16), guest_sp = (guest_top - 256) & ~15ull;
    uint64_t host_top = ((uint64_t)&host_top - 0x8000) & ~15ull;
    sw_xstack_thread_init(host_top, guest_top);
    uint64_t regs[8], stack[12];
    for (int i = 0; i < 8; i++) regs[i] = (uint64_t)i + 1;
    for (int i = 0; i < 12; i++) stack[i] = (uint64_t)i + 9;
    void *stub = sw_xstack_wrap("xstack_args", (void *)raw20);
    int sp_ok = 0; uint64_t got = call_on_guest(stub, regs, stack, guest_sp, &sp_ok);
    int bad = got != 210 || !sp_ok;
    printf("%s t_xstack_args：20 个 AAPCS64 参数合计 210 → %llu，sp 恢复=%s\n", bad ? "✗" : "✓", (unsigned long long)got, sp_ok ? "是" : "否");
    sw_xstack_thread_fini(); munmap(guest, (size_t)page * 16); return bad;
}
