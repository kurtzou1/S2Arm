// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 宿主单测：android/native/gfx_plat/flag_cache.h（nvn_plat_flag 的线程内读数缓存）。期望值全部手算：
//   命中不再读、过期边界（now == until 就算过期）、没设返回「本次调用的缺省」、值 0 与没设区分、同槽冲突与超量名字不串、长名字直读、TTL=0 每次都读。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "flag_cache.h"

static int nfail;
#define CHECK(cond, ...) do { if (!(cond)) { nfail++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// 替身属性表：名字 → {有没有, 值}；rd 每调用一次 g_reads 加 1
struct kv { char name[64]; int has, val; };
static struct kv g_kv[512]; static int g_nkv, g_reads;
static void kv_set(const char *name, int has, int val) {
    for (int i = 0; i < g_nkv; i++) if (!strcmp(g_kv[i].name, name)) { g_kv[i].has = has; g_kv[i].val = val; return; }
    snprintf(g_kv[g_nkv].name, sizeof g_kv[g_nkv].name, "%s", name); g_kv[g_nkv].has = has; g_kv[g_nkv].val = val; g_nkv++;
}
static int rd(const char *name, int *val, void *user) {
    (void)user; g_reads++;
    for (int i = 0; i < g_nkv; i++) if (!strcmp(g_kv[i].name, name)) { if (g_kv[i].has) { *val = g_kv[i].val; return 1; } return 0; }
    return 0;
}
static struct fc_tab g_tab;
static void reset(void) { memset(&g_tab, 0, sizeof g_tab); g_nkv = 0; g_reads = 0; }
static int get(const char *name, int dflt, uint64_t now, uint64_t ttl) { return fc_get(&g_tab, name, dflt, now, ttl, rd, NULL); }

int main(void) {
    // T1 命中：第一次读一次，之后 99 次同一时刻调用都不再读
    reset(); kv_set("nvk_a", 1, 7);
    CHECK(get("nvk_a", -1, 1000, 250) == 7, "T1 首次读：期望 7");
    for (int i = 0; i < 99; i++) CHECK(get("nvk_a", -1, 1000, 250) == 7, "T1 命中第 %d 次：期望 7", i);
    CHECK(g_reads == 1, "T1 100 次调用的真读次数：期望 1 → %d", g_reads);

    // T2 过期边界：until = 1000 + 250 = 1250；now = 1249 仍命中，now = 1250 过期重读（拿到新值 9）
    kv_set("nvk_a", 1, 9);
    CHECK(get("nvk_a", -1, 1249, 250) == 7 && g_reads == 1, "T2 now=1249 仍命中旧值 7、不读：值/读次数 期望 7/1 → %d/%d", get("nvk_a", -1, 1249, 250), g_reads);
    CHECK(get("nvk_a", -1, 1250, 250) == 9 && g_reads == 2, "T2 now=1250 过期重读拿到 9：读次数 期望 2 → %d", g_reads);
    CHECK(get("nvk_a", -1, 1251, 250) == 9 && g_reads == 2, "T2 重读之后在新 TTL 内命中：读次数 期望 2 → %d", g_reads);

    // T3 没设：返回本次调用传的缺省（5 / 11 各返回各的），两次调用只真读一次
    reset(); kv_set("nvk_c", 0, 0); g_reads = 0;
    CHECK(get("nvk_c", 5, 0, 100) == 5, "T3 没设缺省 5：期望 5");
    CHECK(get("nvk_c", 11, 0, 100) == 11, "T3 没设缺省 11：期望 11（不是缓存里的 5）");
    CHECK(g_reads == 1, "T3 没设也缓存：两次调用真读次数 期望 1 → %d", g_reads);
    // 还没在属性里出现过的名字：同样当「没设」
    CHECK(get("nvk_never", 8, 0, 100) == 8, "T3 属性里没有这个名字：期望缺省 8");

    // T4 值为 0 与没设要分开：值 0、缺省 3 → 0
    reset(); kv_set("nvk_b", 1, 0);
    CHECK(get("nvk_b", 3, 0, 100) == 0, "T4 值 0 缺省 3：期望 0");
    CHECK(get("nvk_b", 3, 0, 100) == 0, "T4 值 0 命中：期望 0");

    // T5 先设后取消：过期重读后回到缺省；再设回来又能读到
    reset(); kv_set("nvk_d", 1, 4);
    CHECK(get("nvk_d", 2, 0, 50) == 4, "T5 设了 4：期望 4");
    kv_set("nvk_d", 0, 0);
    CHECK(get("nvk_d", 2, 49, 50) == 4, "T5 TTL 内取消还看不到：期望 4");
    CHECK(get("nvk_d", 2, 50, 50) == 2, "T5 过期后取消生效：期望缺省 2");
    kv_set("nvk_d", 1, 6);
    CHECK(get("nvk_d", 2, 100, 50) == 6, "T5 又设回 6：期望 6");

    // T6 超量名字不串：300 个名字（> 64 个槽，必然挤占 / 同槽冲突），每个的值 = i*3+1，i 是 7 的倍数的没设；5 轮轮流问，期望值每次都对
    reset();
    for (int i = 0; i < 300; i++) { char nm[32]; snprintf(nm, sizeof nm, "nvk_t%d", i); kv_set(nm, i % 7 != 0, i * 3 + 1); }
    int bad = 0, total = 0;
    for (int round = 0; round < 5; round++)
        for (int i = 0; i < 300; i++) {
            char nm[32]; snprintf(nm, sizeof nm, "nvk_t%d", i);
            const int want = i % 7 != 0 ? i * 3 + 1 : -77, got = get(nm, -77, 5000, 1000000); total++;
            if (got != want) { if (!bad) printf("FAIL T6 名字 %s：期望 %d → %d\n", nm, want, got); bad++; }
        }
    CHECK(bad == 0, "T6 300 个名字 × 5 轮 = %d 次问，答错 %d 次：期望 0", total, bad);
    // 放得进表的 24 个名字轮流问 5 轮（共 120 次）：真读应当远少于问的次数（首轮 24 次，加上偶发的同窗口挤占）
    reset();
    for (int i = 0; i < 24; i++) { char nm[32]; snprintf(nm, sizeof nm, "nvk_u%d", i); kv_set(nm, 1, i); }
    for (int round = 0; round < 5; round++) for (int i = 0; i < 24; i++) { char nm[32]; snprintf(nm, sizeof nm, "nvk_u%d", i); if (get(nm, -1, 9, 1000000) != i) bad++; }
    CHECK(bad == 0, "T6 24 个名字 × 5 轮：答错期望 0 → %d", bad);
    CHECK(g_reads <= 48, "T6 缓存应当起作用：120 次问的真读次数 期望 ≤ 48 → %d", g_reads);

    // T7 同槽冲突：找 6 个名字落在同一个槽（探测窗口 FC_PROBE=4，第 5、6 个要挤占），按顺序各问两遍，值必须都对
    reset();
    {   char names[6][32]; int found = 0;
        for (int i = 0; i < 100000 && found < 6; i++) {
            char nm[32]; snprintf(nm, sizeof nm, "nk%d", i);
            uint32_t h = 2166136261u; for (const char *p = nm; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
            if ((h & (FC_SLOTS - 1)) == 5) { snprintf(names[found], sizeof names[found], "%s", nm); kv_set(nm, 1, 100 + found); found++; }
        }
        CHECK(found == 6, "T7 找同槽名字：期望 6 个 → %d", found);
        int wrong = 0;
        for (int pass = 0; pass < 2; pass++) for (int i = 0; i < found; i++) if (get(names[i], -1, 0, 1000) != 100 + i) wrong++;
        CHECK(wrong == 0, "T7 6 个同槽名字各问两遍：答错期望 0 → %d", wrong);
    }

    // T8 长名字（≥ FC_NAME_MAX 个字节）不进表：每次都读，值对
    reset();
    {   char longn[64]; memset(longn, 'x', 45); longn[45] = 0; kv_set(longn, 1, 42); g_reads = 0;
        CHECK(get(longn, 0, 0, 1000) == 42 && get(longn, 0, 0, 1000) == 42 && get(longn, 0, 0, 1000) == 42, "T8 长名字：期望 42");
        CHECK(g_reads == 3, "T8 长名字不缓存：3 次调用真读 3 次 → %d", g_reads);
        // 恰好 39 个字节（FC_NAME_MAX - 1）的名字还能进表
        char edge[64]; memset(edge, 'y', FC_NAME_MAX - 1); edge[FC_NAME_MAX - 1] = 0; kv_set(edge, 1, 43); g_reads = 0;
        CHECK(get(edge, 0, 0, 1000) == 43 && get(edge, 0, 0, 1000) == 43, "T8 39 字节名字：期望 43");
        CHECK(g_reads == 1, "T8 39 字节名字缓存：2 次调用真读 1 次 → %d", g_reads);
    }

    // T9 TTL = 0：永远过期，每次都读
    reset(); kv_set("nvk_z", 1, 1); g_reads = 0;
    for (int i = 0; i < 10; i++) get("nvk_z", 0, 7, 0);
    CHECK(g_reads == 10, "T9 TTL=0：10 次调用真读 10 次 → %d", g_reads);

    printf("nvk_flag_cache 宿主单测：%s（%d 处不符）\n", nfail ? "红" : "绿", nfail);
    return nfail ? 1 : 0;
}
