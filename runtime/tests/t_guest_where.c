// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 客体地址翻导出名（native.h module_func_at / s2a_guest_where，#806：玩家那版 sdk 我们手里没有时，卡死现场 / Break / 崩溃回溯也要读得出函数名）。
//   手搭一个模块：符号表 + 字符串表 + 补丁区；期望按「st_value 非 0 的函数符号里地址 ≤ 偏移的最大者，同址取长的、再取名字大的」手写（同 tools/nso_sym.py sym）
#include "../src/native.h"

static uint8_t g_img[0x2000];
static module_t g_m;
module_t *module_of(const void *p) {
    const uint8_t *a = p; return a >= g_img && a < g_img + sizeof g_img ? &g_m : NULL;
}

static int g_bad;
static void eq(const char *what, const char *want, const char *got) {
    int ok = !strcmp(want, got); if (!ok) g_bad++;
    printf("%s %s：期望「%s」→ 实际「%s」\n", ok ? "✓" : "✗", what, want, got);
}

int main(void) {
    static const char str[] = "\0f_a\0f_b\0f_c\0data_d\0imp_e\0f_z";
    //                          0  1    5    9    13     20    26
    static const Elf64_Sym sym[] = {
        {0},
        {1, 2, 0, 1, 0x100, 0x40},    // f_a：函数 0x100..0x140
        {5, 2, 0, 1, 0x200, 0x10},    // f_b：函数 0x200..0x210
        {9, 2, 0, 1, 0x200, 0x20},    // f_c：同址、更长 → 同址取它
        {13, 1, 0, 1, 0x150, 0x8},    // data_d：数据对象（STT_OBJECT），不算函数
        {20, 2, 0, 0, 0, 0},          // imp_e：导入（未定义、值 0），不算
        {26, 0x12, 0, 1, 0x300, 0x10},// f_z：全局绑定的函数（st_info 高 4 位 = 绑定，低 4 位 = 2）
    };
    strcpy(g_m.name, "main"); g_m.base = g_img; g_m.size = 0x2000; g_m.patch_off = 0x1000; g_m.patch_len = 0;   // 近布局：size 含补丁区，映像尾 0x1000..0x2000 是补丁区
    g_m.symtab = sym; g_m.strtab = str; g_m.nsym = sizeof sym / sizeof *sym;
    char b[256]; uint64_t base = (uint64_t)(uintptr_t)g_img;

    s2a_guest_where(base + 0x120, b, sizeof b); eq("函数内", "main+0x120（f_a+0x20）", b);
    s2a_guest_where(base + 0x150, b, sizeof b); eq("越过函数末尾、数据对象不算", "main+0x150（f_a+0x50，外）", b);
    s2a_guest_where(base + 0x210, b, sizeof b); eq("同址取长的", "main+0x210（f_c+0x10）", b);
    s2a_guest_where(base + 0x305, b, sizeof b); eq("全局绑定的函数", "main+0x305（f_z+0x5）", b);
    s2a_guest_where(base + 0x80, b, sizeof b);  eq("第一个函数之前：只打偏移", "main+0x80", b);
    s2a_guest_where(base + 0x1800, b, sizeof b); eq("补丁区不翻名", "main+0x1800（补丁区）", b);
    b[0] = 0; int r = s2a_guest_where(base + 0x3000, b, sizeof b);
    eq("游戏模块外：返回 0、不写", "0 / 空", r == 0 && !b[0] ? "0 / 空" : "写了");
    g_m.symtab = NULL; s2a_guest_where(base + 0x120, b, sizeof b); eq("没有符号表（老包 / 无符号模块）：同旧格式", "main+0x120", b);
    g_m.symtab = sym;
    char small[24]; s2a_guest_where(base + 0x120, small, sizeof small); eq("缓冲小：截断不越界、不留半个字符", "main+0x120（f_a+0x20", small);

    printf("%s t_guest_where：%d 项不符\n", g_bad ? "✗" : "✓", g_bad);
    return g_bad != 0;
}
