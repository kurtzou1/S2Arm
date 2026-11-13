// GC 上限自适应四档（runtime/src/gclimit.c）。期望按设计手算：总上限要低区最大一块 ≥ 10240 + 1024 MB，分堆 ≥ 2688 + 1024 MB，按需档（384 / 256 / 64 MB）≥ 870 + 1024 MB，否则不设；
//   外部已设任何一个 GC 上限变量就不改。实测来源：Mac 动森 不设 / 总 2 GB / 分堆三档 C# 初始化后低区最大一块 30392 / 20152 / 27708 MB；巫师3 真机 1251 MB
#include "../src/native.h"
int s2a_gc_limit_scaled(uint64_t largest, uint64_t *soh, uint64_t *loh, uint64_t *poh);   // gclimit.c 缩放档（只单测用，不进 native.h：那是抽取阶段键）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t g_largest;
void s2a_low_holes(uint64_t *total, uint64_t *largest) { *total = g_largest + (100ull << 20); *largest = g_largest; }

static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static const char *const vars[] = {"DOTNET_GCHeapHardLimit", "DOTNET_GCHeapHardLimitPercent", "DOTNET_GCHeapHardLimitSOH", "DOTNET_GCHeapHardLimitLOH", "DOTNET_GCHeapHardLimitPOH"};
static void clear(void) { for (unsigned i = 0; i < 5; i++) unsetenv(vars[i]); }
static const char *ev(const char *n) { const char *v = getenv(n); return v ? v : "-"; }

int main(void) {
    const uint64_t MBy = 1ull << 20;
    struct { uint64_t mb; int want; const char *why; } p[] = {
        {30392, 1, "Mac 动森不设上限时的最大一块"}, {11264, 1, "总上限边界 10240 + 1024"}, {11263, 2, "差 1 MB 落分堆"},
        {3712, 2, "分堆边界 2688 + 1024"}, {3711, 3, "差 1 MB 落按需档"}, {3072, 3, "异度3 / 时之笛真机低区最大一块"},
        {1894, 3, "按需边界 870 + 1024"}, {1893, 0, "差 1 MB 不设"}, {1251, 0, "巫师3 真机低区最大一块"}, {0, 0, "低区没有空洞"}};
    for (unsigned i = 0; i < sizeof p / sizeof *p; i++) {
        int got = s2a_gc_limit_pick(p[i].mb * MBy);
        CHECK(got == p[i].want, "pick(%llu MB，%s)：应 %d，实 %d", (unsigned long long)p[i].mb, p[i].why, p[i].want, got);
    }
    clear(); g_largest = 30392 * MBy; s2a_gc_limit_apply();
    CHECK(!strcmp(ev("DOTNET_GCHeapHardLimit"), "80000000") && !strcmp(ev("DOTNET_GCHeapHardLimitSOH"), "-"),
          "总上限档：应只设 DOTNET_GCHeapHardLimit=80000000，实 总 %s / SOH %s", ev("DOTNET_GCHeapHardLimit"), ev("DOTNET_GCHeapHardLimitSOH"));
    clear(); g_largest = 5000 * MBy; s2a_gc_limit_apply();
    CHECK(!strcmp(ev("DOTNET_GCHeapHardLimit"), "-") && !strcmp(ev("DOTNET_GCHeapHardLimitSOH"), "60000000")
          && !strcmp(ev("DOTNET_GCHeapHardLimitLOH"), "20000000") && !strcmp(ev("DOTNET_GCHeapHardLimitPOH"), "8000000"),
          "分堆档：应设 SOH 60000000 / LOH 20000000 / POH 8000000、不设总上限，实 总 %s / SOH %s / LOH %s / POH %s",
          ev("DOTNET_GCHeapHardLimit"), ev("DOTNET_GCHeapHardLimitSOH"), ev("DOTNET_GCHeapHardLimitLOH"), ev("DOTNET_GCHeapHardLimitPOH"));
    clear(); g_largest = 3072 * MBy; s2a_gc_limit_apply();
    CHECK(!strcmp(ev("DOTNET_GCHeapHardLimit"), "-") && !strcmp(ev("DOTNET_GCHeapHardLimitSOH"), "18000000")
          && !strcmp(ev("DOTNET_GCHeapHardLimitLOH"), "10000000") && !strcmp(ev("DOTNET_GCHeapHardLimitPOH"), "4000000"),
          "按需档（异度3 3072 MB）：应设 SOH 18000000 / LOH 10000000 / POH 4000000（384 / 256 / 64 MB）、不设总上限，实 总 %s / SOH %s / LOH %s / POH %s",
          ev("DOTNET_GCHeapHardLimit"), ev("DOTNET_GCHeapHardLimitSOH"), ev("DOTNET_GCHeapHardLimitLOH"), ev("DOTNET_GCHeapHardLimitPOH"));
    clear(); g_largest = 1251 * MBy; s2a_gc_limit_apply();
    int none = 1; for (unsigned i = 0; i < 5; i++) none &= !getenv(vars[i]);
    CHECK(none, "不设档（巫师3 1251 MB）：五个 GC 上限变量都不应设");
    clear(); setenv("DOTNET_GCHeapHardLimit", "0", 1); g_largest = 30392 * MBy; s2a_gc_limit_apply();
    CHECK(!strcmp(ev("DOTNET_GCHeapHardLimit"), "0") && !strcmp(ev("DOTNET_GCHeapHardLimitSOH"), "-"), "外部已设 DOTNET_GCHeapHardLimit=0：应照用不改，实 总 %s / SOH %s",
          ev("DOTNET_GCHeapHardLimit"), ev("DOTNET_GCHeapHardLimitSOH"));
    // 重选（窗口当场放宽后低区变小，v0.3.4）：自己选的总上限档 → 按 3072 MB 重选成按需档；外部指定的不动
    { void s2a_gc_limit_reapply(void);
      clear(); g_largest = 60416 * MBy; s2a_gc_limit_apply(); g_largest = 3072 * MBy; s2a_gc_limit_reapply();
      CHECK(!strcmp(ev("DOTNET_GCHeapHardLimit"), "-") && !strcmp(ev("DOTNET_GCHeapHardLimitSOH"), "18000000"), "重选：60416 MB 选的总上限档，低区缩到 3072 MB 后应改按需档，实 总 %s / SOH %s",
            ev("DOTNET_GCHeapHardLimit"), ev("DOTNET_GCHeapHardLimitSOH"));
      clear(); setenv("DOTNET_GCHeapHardLimit", "0", 1); g_largest = 60416 * MBy; s2a_gc_limit_apply(); g_largest = 3072 * MBy; s2a_gc_limit_reapply();
      CHECK(!strcmp(ev("DOTNET_GCHeapHardLimit"), "0") && !strcmp(ev("DOTNET_GCHeapHardLimitSOH"), "-"), "重选：外部指定的不动，实 总 %s / SOH %s", ev("DOTNET_GCHeapHardLimit"), ev("DOTNET_GCHeapHardLimitSOH")); }
    clear();
    printf("%s t_gclimit：%d 处不符（四档门槛 10 例、各档设变量、外部指定不改）\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
