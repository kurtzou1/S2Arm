// 布局回归（layout.c，docs/方案_地址空间根修.md）：期望值按 SDK 别名区规则（元数据 0x3FE00000、≥1 GiB 按 GiB 对齐、前后 4 KiB 保护页）、
//   应用池 3284 MiB、宿主保留 768 MiB 手算，不调被测算式。模块段一律取 300 MiB。
#include "../src/native.h"
#define GB (1ull << 30)
#define MB (1ull << 20)
#define W 0x7000000000ull
#define MOD (300 * MB)
static int bad;
#define EQ(a, b) do { uint64_t x_ = (a), y_ = (b); if (x_ != y_) { printf("✗ %s = %#llx，期望 %#llx\n", #a, (unsigned long long)x_, (unsigned long long)y_); bad++; } } while (0)
// 各区两两不重叠；有宿主地址的小区（TLS/IO、栈、堆起点 32 MiB、模块段）必须落在宿主占到的窗口里
static void sane(const s2a_layout *L, uint64_t mod_base) {
    uint64_t r[5][2] = {{L->alias_base,L->alias_size},{L->heap_base,L->heap_size},{L->stack_base,L->stack_size},{L->tlsio_base,L->tlsio_size},{mod_base,MOD}};
    for (int i = 0; i < 5; i++) for (int j = i + 1; j < 5; j++) if (r[i][0] < r[j][0]+r[j][1] && r[j][0] < r[i][0]+r[i][1]) { printf("✗ 区 %d / %d 重叠\n", i, j); bad++; }
    uint64_t e = L->win_base + L->win_size;
    if (L->tlsio_base + L->tlsio_size > e || L->stack_base + L->stack_size > e || L->heap_base + 32*MB > e || mod_base + MOD > e) { printf("✗ 小区伸出窗口\n"); bad++; }
}
// SDK 在别名区里给 UE4 的 62 GiB 地址区找位置：元数据之后按 GiB 对齐，末尾留 4 KiB（地址空间.md A5/A6/A11）
static void fits62(const s2a_layout *L) {
    uint64_t reg = (L->alias_base + 0x3FE00000ull + 0x1000 + GB - 1) & ~(GB - 1);
    if (reg + 62*GB > L->alias_base + L->alias_size - 0x1000) { printf("✗ 62 GiB 地址区放不下（起 %#llx）\n", (unsigned long long)reg); bad++; }
}
int main(void) {
    s2a_layout L; uint64_t mb, sb;
    // 标准布局跨度：VAMM = 63G + TLS 2M + 栈 2048M（Horizon 39 位栈区 0x80000000）+ 堆 3284M + 余量 96M + 模块；堆模式 = 32G + 模块
    EQ(s2a_layout_need(3,80*MB,MOD),63*GB+(2+2048+3284+96+300)*MB);
    EQ(s2a_layout_need(3,0,MOD),32*GB+MOD);
    // 36 位（类型 1，老 SDK）：跨度 = 可随机区 32G（模块在 0x78000000 代码区里，不另加）；模块 + 2M TLR 塞不进代码区 → 0
    EQ(s2a_layout_need(1,0,MOD),32*GB); EQ(s2a_layout_need(1,80*MB,MOD),32*GB); EQ(s2a_layout_need(1,0,1918*MB),0); EQ(s2a_layout_need(1,0,1916*MB),32*GB);
    EQ(s2a_layout_need(0,0,MOD),0); EQ(s2a_layout_need(2,0,MOD),0);

    // 甲（VAMM，iOS 27 / Mac 的 64 GiB 空洞，别名优先 → 栈区压到 128M）：固定部分 63G + 526M，余 498M < 768 + 32 → 堆 32M，宿主拿回其余
    EQ(s2a_layout_compute(3,80*MB,MOD,1,W,64*GB,&L,&mb,&sb),0);
    EQ(L.tlsio_base,W); EQ(L.alias_base,W+2*MB-0x4000); EQ(L.alias_base+L.alias_size,W+63*GB+0x4000);
    EQ(L.stack_base,W+63*GB+2*MB); EQ(L.heap_base,W+63*GB+130*MB); EQ(L.heap_size,32*MB);
    EQ(L.aslr_base,L.stack_base); EQ(L.aslr_size,256*MB); EQ(mb,W+63*GB+258*MB); EQ(L.win_size,63*GB+558*MB);
    sane(&L,mb); fits62(&L);
    // 甲，空洞 66G（基址 64G，免得越过 2^39）：堆 = 66G − (63G+526M) − 768M = 1778M
    EQ(s2a_layout_compute(3,80*MB,MOD,1,0x1000000000ull,66*GB,&L,&mb,&sb),0); EQ(L.heap_size,1778*MB); EQ(L.win_size,63*GB+526*MB+1778*MB);
    // 甲，空洞 70G、不是别名优先：栈区给足 2048M，固定部分 63G + 2446M；堆 = 7168 − 2446 − 768 = 3954M，封顶应用池 3284M
    EQ(s2a_layout_compute(3,80*MB,MOD,0,0x1000000000ull,70*GB,&L,&mb,&sb),0); EQ(L.heap_size,3284*MB); sane(&L,mb); fits62(&L);
    EQ(L.stack_base,0x1000000000ull+63*GB+2*MB); EQ(L.stack_size,2*GB); EQ(L.heap_base,L.stack_base+2*GB); EQ(L.aslr_size,(2048+3284+96)*MB);

    // 乙（VAMM，16 GiB）：模块 [W, +300M)，栈 +300M 长 2048M，堆区 +2348M 长 3284M + 256M（影子从堆区顶往下分、与堆共用），余量到 +5984M
    //   → TLS/IO 在下一个 GiB（+6G），别名区从 +6G+2M−16K 伸出窗口；窗口整段给布局（宿主保留段在窗口下方，vawin.c）
    EQ(s2a_layout_compute(3,80*MB,MOD,0,W,16*GB,&L,&mb,&sb),0);
    EQ(mb,W); EQ(L.stack_base,W+300*MB); EQ(L.stack_size,2*GB); EQ(L.heap_base,W+2348*MB); EQ(L.heap_size,3540*MB);
    EQ(L.aslr_base,W+300*MB); EQ(L.aslr_size,5684*MB); EQ(sb,W+2348*MB);
    EQ(L.tlsio_base,W+6*GB); EQ(L.alias_base,W+6*GB+2*MB-0x4000); EQ(L.alias_base+L.alias_size,W+69*GB+0x4000);
    EQ(L.win_size,16*GB); sane(&L,mb); fits62(&L);
    // 乙下限：放得下到 TLS/IO 末（+6G+2M）
    EQ(s2a_layout_compute(3,80*MB,MOD,0,W,6*GB+2*MB,&L,&mb,&sb),0);
    EQ(s2a_layout_compute(3,80*MB,MOD,0,W,6*GB+1*MB,&L,&mb,&sb),(uint64_t)-2);
    EQ(sb,0);   // 上一例走甲：没有影子区
    // 甲 / 乙分界：固定部分 + 32M 堆 = 63G+558M 正好甲，少 1M 走乙
    EQ(s2a_layout_compute(3,80*MB,MOD,1,W,63*GB+558*MB,&L,&mb,&sb),0); EQ(L.tlsio_base,W); EQ(L.heap_size,32*MB);
    EQ(s2a_layout_compute(3,80*MB,MOD,63,W,63*GB+556*MB,&L,&mb,&sb),0); EQ(mb,W); EQ(L.tlsio_base,W+716*MB);   // 别名优先的乙：TLS/IO 紧接前段 300+128+192+96 MB
    //   八方2 类（静态大区 62 GiB + 元数据 → 63 GB）：要 63 + 1 + 2×4（应用池 3285M 取整 4G）= 72G > 窗口里能给的 63G+556M−716M → 照旧承诺 64 GiB、开远端
    EQ(L.alias_size,64*GB); EQ(sb,W+428*MB);

    // 乙 + 别名优先（iOS 26 布局：窗口 13 GB 起 50 GB）：模块 300M，栈 +300M，堆区 +428M 长 192M，余量到 +716M → TLS/IO 在 +716M（2 MiB 对齐、
    //   不按 GiB），别名区 +718M−16K 起承诺 64 GiB；巫师3 碰到 49.1 GB → 末端 13 GB + 0.70 GB + 49.1 GB < 63 GB
    //   巫师3 静态大区 48 GiB + 元数据 → 49 GB：要 49 + 1 + 8 = 58G > 窗口里能给的 50G − 718M + 16K → 照旧 64 GiB
    { const uint64_t W26 = 13 * GB;
      EQ(s2a_layout_compute(3,80*MB,MOD,49,W26,50*GB,&L,&mb,&sb),0);
      EQ(L.stack_size,128*MB); EQ(L.heap_base,W26+428*MB); EQ(L.heap_size,192*MB); EQ(sb,W26+428*MB); EQ(L.aslr_size,416*MB);
      EQ(L.tlsio_base,W26+716*MB); EQ(L.alias_base,W26+718*MB-0x4000); EQ(L.alias_size,64*GB); EQ(L.win_size,50*GB);
      sane(&L,mb);
      if (L.alias_base + 50278*MB > 63*GB) { printf("✗ 巫师3 碰到的 50278 MB 越过 63 GB\n"); bad++; }
      // SDK 对齐没被削（≥1 GiB 区域按 GiB 对齐）时 62 GiB 照样放下：元数据之后按 GiB 取整，末尾留 4 KiB
      uint64_t reg = (L.alias_base + 0x3FE00000ull + 0x1000 + GB - 1) & ~(GB - 1);
      if (reg + 62*GB + 0x1000 > L.alias_base + L.alias_size) { printf("✗ 别名优先：62 GiB 地址区放不下\n"); bad++; } }
    // 别名优先的乙收窗口的账（11-03 新账）：要的 = 静态大区（含元数据）+ 对齐 1 GiB + 18 × 应用池（每个 4 KiB 整段提交的小区最坏占
    //   4 KiB + 64 KiB + 0xFFF 地址，见 layout.c）+ 8 KiB。应用池 0xCD500000 = 3285 MiB → 18 × = 59130 MiB。
    // 火炬之光3 Mac 实局（c1103_recheck7 host.log）：窗口 0x7040000000 +63G、模块 142M、静态 38 GB → 要 38G + 1G + 59130M + 8K ≈ 96.7 GiB，
    //   能给 63G − 560M + 16K ≈ 62.45 GiB → 不收：照旧 64 GiB、影子从堆区 0x7050e00000 起（日志第 21 行同）；别名基址 0x7062ffc000 不变
    { const uint64_t WT = 0x7040000000ull;
      EQ(s2a_layout_compute(3,80*MB,142*MB,38,WT,63*GB,&L,&mb,&sb),0);
      EQ(L.alias_base,0x7062ffc000ull); EQ(L.alias_size,64*GB); EQ(sb,0x7050e00000ull);
      EQ(mb,WT); EQ(L.win_size,63*GB); EQ(L.heap_size,192*MB); EQ(L.stack_size,128*MB);
      // 同一组数字、上限不定（−38）：同样不收
      EQ(s2a_layout_compute(3,80*MB,142*MB,-38,WT,63*GB,&L,&mb,&sb),0);
      EQ(L.alias_base,0x7062ffc000ull); EQ(L.alias_size,64*GB); EQ(sb,0x7050e00000ull); }
    // 静态大区 ≥ 4 GiB（识别值 ≥ 5）时要的 ≥ 5G + 1G + 59130M > 64 GiB 空洞：真游戏都不收。分界只在假想的 1 GB 上出现：
    //   要 1G + 1G + 59130M + 8K = 61178M + 8K；模块 300M 时能给 = 窗口 − 718M + 16K → 窗口 61896M − 8K 正好收（别名长 = 要的），少 4K 不收
    EQ(s2a_layout_compute(3,80*MB,MOD,1,W,61896*MB-0x2000,&L,&mb,&sb),0); EQ(L.alias_size,61178*MB+0x2000); EQ(sb,0);
    EQ(s2a_layout_compute(3,80*MB,MOD,1,W,61896*MB-0x3000,&L,&mb,&sb),0); EQ(L.alias_size,64*GB); EQ(sb,W+428*MB);
    // 64 GiB 空洞、不是别名优先的款（王国之泪类：要满额堆）：放不下 63G + 526M + 3284M → 乙，堆给满 3284M + 256M 放前段，不是让到 32M
    EQ(s2a_layout_compute(3,80*MB,MOD,0,W,64*GB,&L,&mb,&sb),0); EQ(L.heap_size,3540*MB); EQ(mb,W); EQ(L.stack_size,2*GB); EQ(L.tlsio_base,W+6*GB);
    // 同空洞、别名优先（八方2 / 巫师3 / 异度3 类）：照旧甲，别名区在前、堆让到 32M
    EQ(s2a_layout_compute(3,80*MB,MOD,1,W,64*GB,&L,&mb,&sb),0); EQ(L.tlsio_base,W); EQ(L.heap_size,32*MB); EQ(sb,0);
    // 堆模式甲：32G + 模块正好放下，照 39 位布局，模块在 +32G
    EQ(s2a_layout_compute(3,0,MOD,0,W,32*GB+MOD,&L,&mb,&sb),0);
    EQ(L.tlsio_base,W); EQ(L.stack_base,W+GB); EQ(L.heap_base,W+3*GB); EQ(L.heap_size,6*GB); EQ(L.alias_base,W+9*GB);
    EQ(L.aslr_base,W); EQ(L.aslr_size,32*GB); EQ(mb,W+32*GB); EQ(L.win_size,32*GB+MOD); sane(&L,mb);
    // 堆模式乙（16 GiB）：模块在前，各区整体后移到 +1G；堆 [W+4G, …) 有 12G 宿主地址；不调 MapPhysicalMemory，没有影子区
    EQ(s2a_layout_compute(3,0,MOD,0,W,16*GB,&L,&mb,&sb),0);
    EQ(mb,W); EQ(sb,0); EQ(L.tlsio_base,W+GB); EQ(L.stack_base,W+2*GB); EQ(L.heap_base,W+4*GB); EQ(L.alias_base,W+10*GB); EQ(L.aslr_base,W+GB);
    EQ(L.win_size,16*GB); sane(&L,mb);
    EQ(s2a_layout_compute(3,0,MOD,0,W,4*GB+32*MB,&L,&mb,&sb),0);
    // 堆模式丙（#620，紧凑）：乙放不下（4G+31M）时，模块后按 2 MiB 对齐，TLS/IO 64M、栈区 256M，堆紧随其后；堆区 / 别名 / 可随机区尺寸同乙
    EQ(s2a_layout_compute(3,0,MOD,0,W,4*GB+31*MB,&L,&mb,&sb),0);
    EQ(mb,W); EQ(sb,0); EQ(L.tlsio_base,W+300*MB); EQ(L.tlsio_size,64*MB); EQ(L.stack_base,W+364*MB); EQ(L.stack_size,256*MB);
    EQ(L.heap_base,W+620*MB); EQ(L.heap_size,6*GB); EQ(L.alias_base,W+620*MB+6*GB); EQ(L.alias_size,8*GB); EQ(L.aslr_base,W+300*MB); EQ(L.aslr_size,32*GB);
    EQ(L.win_size,4*GB+31*MB); sane(&L,mb);
    // 丙下限：300M 模块 + 64M + 256M + 32M 堆 = 652M 放得下，651M 放不下
    EQ(s2a_layout_compute(3,0,MOD,0,W,652*MB,&L,&mb,&sb),0); sane(&L,mb);
    EQ(s2a_layout_compute(3,0,MOD,0,W,651*MB,&L,&mb,&sb),(uint64_t)-2);
    // #620 真实情形：老 iPad 窗口 0x3c0000000 起 2048M，模块段 616M（不是 2 MiB 整数倍也按 2 MiB 对齐）→ 丙：TLS/IO 在 +616M，堆在 +936M，窗口里有 1112M 堆
    { uint64_t w620 = 0x3c0000000ull, m620 = 615*MB + 512*1024;
      EQ(s2a_layout_compute(3,0,m620,0,w620,2*GB,&L,&mb,&sb),0);
      EQ(mb,w620); EQ(L.tlsio_base,w620+616*MB); EQ(L.stack_base,w620+680*MB); EQ(L.heap_base,w620+936*MB); EQ(L.win_size,2*GB); }
    // Switch 2 堆模式（应用池 9 GiB，Pokopia）：堆区放大到 9G、别名区顺延到 +12G，32G 跨度不变；测完复原 Switch 池
    s2a_app_pool_set(9*GB);
    EQ(s2a_layout_compute(3,0,MOD,0,W,32*GB+MOD,&L,&mb,&sb),0);
    EQ(L.heap_base,W+3*GB); EQ(L.heap_size,9*GB); EQ(L.alias_base,W+12*GB); EQ(L.alias_size,8*GB); EQ(L.aslr_size,32*GB); EQ(mb,W+32*GB); sane(&L,mb);
    s2a_app_pool_set(0xCD500000ull);

    // 36 位（类型 1，11-05 Minecraft: Story Mode）：照 Ryujinx AddressSpace64BitDeprecated——代码区 0x78000000（1920M：模块 300M → TLR 2M → 栈区 1618M）、
    //   堆区 6G（0x180000000）、别名区 6G（0x180000000），可随机区罩住全部取 32G；整段在 2^36 以下（老 SDK 的 HIPC 描述符只编 36 位地址）。
    //   W36 = 12G（macOS 26 / iOS 26 构造函数时刻 [12, 63) GB 的空洞），窗口 34G（32G + 尾部 2G）
    { const uint64_t W36 = 0x300000000ull;
      EQ(s2a_layout_compute(1,0,MOD,0,W36,34*GB,&L,&mb,&sb),0);
      EQ(mb,W36); EQ(sb,0); EQ(L.as_type,1);
      EQ(L.tlsio_base,W36+300*MB); EQ(L.tlsio_size,2*MB);
      EQ(L.stack_base,W36+302*MB); EQ(L.stack_size,1618*MB); EQ(L.stack_base+L.stack_size,W36+0x78000000ull);
      EQ(L.heap_base,W36+2*GB); EQ(L.heap_size,6*GB);
      EQ(L.alias_base,W36+8*GB); EQ(L.alias_size,6*GB);
      EQ(L.aslr_base,W36); EQ(L.aslr_size,32*GB); EQ(L.win_size,32*GB);
      EQ(L.aslr_base+L.aslr_size <= (1ull<<36),1); sane(&L,mb);
      EQ(s2a_layout_compute(1,80*MB,MOD,0,W36,34*GB,&L,&mb,&sb),0); EQ(L.alias_size,6*GB); EQ(L.heap_size,6*GB);   // 有系统资源同一布局（别名区不随 39 位放大到 64G）
      EQ(s2a_layout_compute(1,0,MOD,0,W36,14*GB,&L,&mb,&sb),0); EQ(L.aslr_size,14*GB); EQ(L.win_size,14*GB); EQ(L.alias_base+L.alias_size,W36+14*GB);   // 窗口小：最少 2G + 6G + 6G
      EQ(s2a_layout_compute(1,0,MOD,0,W36,14*GB-1*MB,&L,&mb,&sb),(uint64_t)-2);
      EQ(s2a_layout_compute(1,0,MOD,0,(1ull<<36)-32*GB,32*GB,&L,&mb,&sb),0);            // 顶正好到 2^36
      EQ(s2a_layout_compute(1,0,MOD,0,(1ull<<36)-32*GB,33*GB,&L,&mb,&sb),(uint64_t)-2);   // 越过 2^36
      EQ(s2a_layout_compute(1,0,MOD,0,W,34*GB,&L,&mb,&sb),(uint64_t)-2);                 // 0x70_0000_0000 的窗口（39 位款的位置）对 36 位款不合法
      EQ(s2a_layout_compute(1,0,1918*MB,0,W36,34*GB,&L,&mb,&sb),(uint64_t)-2); }
    // 拒绝：地址空间类型不支持、窗口基址不按 GiB 对齐、窗口越过 2^39
    EQ(s2a_layout_compute(0,0,MOD,0,W,64*GB,&L,&mb,&sb),(uint64_t)-1);
    EQ(s2a_layout_compute(2,0,MOD,0,W,64*GB,&L,&mb,&sb),(uint64_t)-1);
    EQ(s2a_layout_compute(3,0,MOD,0,W+32*MB,64*GB,&L,&mb,&sb),(uint64_t)-2);
    EQ(s2a_layout_compute(3,0,MOD,0,W,65*GB,&L,&mb,&sb),(uint64_t)-2);
    printf("%s t_layout：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
