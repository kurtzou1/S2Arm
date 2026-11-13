// GC 上限自适应（10-26）：开局先量低区最大一块，再决定给 .NET GC 设哪档上限（S2A_Init 之前设环境变量，GC 初始化时读）。
// 为什么要上限：本宿主的 NativeAOT GC 是 segments 版（没有 regions），运行中长新段会扩卡表；只读（frozen）段只要与 GC 地址范围部分重叠
//   就被标「在范围内」，下一次扩表 copy_brick_card_range 以它的起点算 brick_of(start) = (size_t)(start − lowest_address) / 4096 无符号下溢
//   → +2^53 地址 → 信号 11（普查只只大冒险；dotnet/runtime release/10.0 gc.cpp）。有上限时 GC 开局按上限一次留够、不再长新段，扩表这条路不走。
// 为什么要自适应：上限要一整块连续低区（Mac 动森实测：总上限 2 GB 一次保留 10,240 MB，分堆 1.5 GB / 512 MB / 128 MB 保留约 2,688 MB），
//   别名区 63 GB 的款（巫师3）低区最大一块只剩约 1.2 GB，硬设总上限 .NET 运行时直接初始化失败（10-26 巫师3 冒烟）。
// 四档：放得下总上限 → 2 GB；放得下分堆 → SOH 1.5 GB / LOH 512 MB / POH 128 MB；分堆也放不下 → 按需档 SOH 384 / LOH 256 / POH 64 MB；
//   按需档也放不下 → 不设（退回原行为，打【黄】）。
// 按需档（11-07 卡顿线）：原先这里直接不设，GC 运行中长新段只能落 0x1_0000_0000–0x1_8000_0000 那段低区（10-24 坑记录），局中那段被文件映射 / malloc / Metal
//   占满后长段失败 → 托管 OOM：异度3 测试设备2 局中第一次跑 C# 翻译器，4 支缺库键现编全 OOM（GC 堆才 33 MB、系统余 6.4 GB、那段只剩 45 MB），随后 Vp9 解码线程连带崩。
//   同包外部给 SOH 256 / LOH 128 / POH 32 → OOM 0、崩 0、67 支现编全成，C# 初始化后低区合计只少 358 MB（fua_gcl/out_1107091403）。
//   上限按需要定、不按空闲地址放大（11-06 缩放档按最大一块缩出 1472 MB、保留约 2.8 GB，时之笛 Duo 低区见底 malloc 崩，已回退）：
//   近 4 天 1288 局 46 款直连模式托管堆峰值最大 SOH 170 / LOH 177 / POH 28 MB（异度3 带上限局 LOH 101 已贴近 128），取约 1.5–2.3 倍余量。
//   余量 1 GB：宿主线程栈与 Metal ≤256 MB 缓冲也从低区最大一块取。外部已设任何一个 GC 上限变量就照用，不改
#include "native.h"
#include <stdlib.h>

#define MB (1ull << 20)
enum { GC_LIMIT_NONE, GC_LIMIT_TOTAL, GC_LIMIT_HEAPS, GC_LIMIT_NEED };
static const uint64_t k_total_reserve = 10240 * MB, k_heaps_reserve = 2688 * MB, k_spare = 1024 * MB;
// 按需档保留量上界：按分堆档实测保留 / 上限比 2688 / 2176 折 704 MB 上限 ≈ 870 MB（异度3 416 MB 上限实测只占 358 MB，比值更小，这里取保守）
static const uint64_t k_need_reserve = 870 * MB;

int s2a_gc_limit_pick(uint64_t largest) {
    if (largest >= k_total_reserve + k_spare) return GC_LIMIT_TOTAL;
    if (largest >= k_heaps_reserve + k_spare) return GC_LIMIT_HEAPS;
    if (largest >= k_need_reserve + k_spare) return GC_LIMIT_NEED;
    return GC_LIMIT_NONE;
}

static const char *const vars[] = {"DOTNET_GCHeapHardLimit", "DOTNET_GCHeapHardLimitPercent", "DOTNET_GCHeapHardLimitSOH",
                                   "DOTNET_GCHeapHardLimitLOH", "DOTNET_GCHeapHardLimitPOH"};
static int g_own;   // 变量是本函数按低区设的（不是外部指定）：低区变了可以重选（s2a_gc_limit_reapply）
void s2a_gc_limit_apply(void) {
    for (unsigned i = 0; i < sizeof vars / sizeof *vars; i++)
        if (getenv(vars[i])) { g_own = 0; LOG("GC 上限：外部指定（%s=%s），照用", vars[i], getenv(vars[i])); return; }
    uint64_t total = 0, largest = 0; s2a_low_holes(&total, &largest);
    g_own = 1;
    switch (s2a_gc_limit_pick(largest)) {
    case GC_LIMIT_TOTAL:
        setenv("DOTNET_GCHeapHardLimit", "80000000", 1);   // DOTNET_ 数值按十六进制
        LOG("GC 上限：总 2048 MB（低区最大一块 %llu MB ≥ %llu MB；开局一次保留约 %llu MB）",
            (unsigned long long)(largest / MB), (unsigned long long)((k_total_reserve + k_spare) / MB), (unsigned long long)(k_total_reserve / MB));
        break;
    case GC_LIMIT_HEAPS:
        setenv("DOTNET_GCHeapHardLimitSOH", "60000000", 1); setenv("DOTNET_GCHeapHardLimitLOH", "20000000", 1); setenv("DOTNET_GCHeapHardLimitPOH", "8000000", 1);
        LOG("GC 上限：分堆 SOH 1536 / LOH 512 / POH 128 MB（低区最大一块 %llu MB，放不下总上限要的 %llu MB；开局一次保留约 %llu MB）",
            (unsigned long long)(largest / MB), (unsigned long long)((k_total_reserve + k_spare) / MB), (unsigned long long)(k_heaps_reserve / MB));
        break;
    case GC_LIMIT_NEED:
        setenv("DOTNET_GCHeapHardLimitSOH", "18000000", 1); setenv("DOTNET_GCHeapHardLimitLOH", "10000000", 1); setenv("DOTNET_GCHeapHardLimitPOH", "4000000", 1);
        LOG("GC 上限：按需 SOH 384 / LOH 256 / POH 64 MB（低区最大一块 %llu MB，放不下分堆要的 %llu MB；开局一次保留至多约 %llu MB，GC 不再运行中长新段）",
            (unsigned long long)(largest / MB), (unsigned long long)((k_heaps_reserve + k_spare) / MB), (unsigned long long)(k_need_reserve / MB));
        break;
    default:
        LOG("【黄】GC 上限：不设（低区最大一块 %llu MB、合计 %llu MB，放不下按需上限要的 %llu MB）——退回不设上限，GC 运行中扩表的那个缺陷没挡住",
            (unsigned long long)(largest / MB), (unsigned long long)(total / MB), (unsigned long long)((k_need_reserve + k_spare) / MB));
    }
}
// 低区在 GC 初始化前变小时重选（vawin.c s2a_window_span_widen，v0.3.4）：窗口按学到的跨度收窄时下方空着几十 GB，这里选了总上限档（开局一次保留 10 GB），
//   布局放不下、窗口当场放宽后下方只剩 3 GiB，GC 初始化保留不到 → .NET 运行时初始化失败（iPhone 实机实测）。只重选本函数自己设的；外部指定的照用
void s2a_gc_limit_reapply(void) {
    if (!g_own) return;
    for (unsigned i = 0; i < sizeof vars / sizeof *vars; i++) unsetenv(vars[i]);
    g_own = 0; s2a_gc_limit_apply();
}
