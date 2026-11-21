// Mac/iOS 共用的区域布局（docs/方案_地址空间根修.md）。只看 NPDM（地址空间类型、SystemResourceSize）、模块跨度和宿主占到的窗口，不看按款表。
// Horizon 各区是地址承诺，不是内存：游戏真占的只有它映射过的页。宿主占到的窗口放得下标准布局就照标准排（甲）；放不下就把必须有宿主地址的
//   小区（模块、栈、堆、共享映射余量、TLS/IO）排在窗口前段，只有「从低往高长」的别名区伸出窗口（乙）——伸出去的部分只是承诺，
//   游戏映射到那里时 svc 回内存不足（svc_mem.c win_has），不崩。
#include "native.h"
#include "as_type.h"

#define GB (1ull << 30)
#define MB (1ull << 20)
#define A2M(x) (((x) + 2 * MB - 1) & ~(2 * MB - 1))
#define AGB(x) (((x) + GB - 1) & ~(GB - 1))

// VAMM 别名区：Switch 39 位给 64 GiB，SDK 开头放元数据 0x3FE00000，≥1 GiB 的地址区按 GiB 对齐且前后留 4 KiB——
//   别名区基址 ≡ 2 MiB − 16 KiB（mod 1 GiB）、长 63 GiB + 32 KiB − 2 MiB 时，UE4 开局要的 62 GiB 正好放下（地址空间.md A11）
#define VAMM_ALIAS (63 * GB)
// 栈区照 Horizon 39 位给 2 GiB（Ryujinx KPageTableBase stackRegion.Size = 0x80000000）：SDK 建线程（StackGuardManager::MapAtRandomAddress）
//   在栈区里随机挑地址、前后各留保护区，512 次都撞上已占的就中止（Break 原因 0）。10-29 Servonauts / Fit Boxing 3 线程栈占到 43–51 MB 时
//   128 MiB 栈区挑不出位置、开局约 40 秒中止。只有别名优先的款仍压到 128 MiB（同堆一起给别名区让窗口：巫师3 碰到 49.1 GB，iOS 26 窗口 51 GB）
#define VAMM_STACK (2 * GB)
#define ALIAS_FIRST_STACK (128 * MB)
#define VAMM_SHARED (96 * MB)   // 共享内存 / 传输内存随机映射的余量（可随机区 = 栈 + 堆 + 余量）
#define MIN_HEAP (32 * MB)
#define COMPACT_TLSIO (64 * MB)    // 丙（紧凑堆模式，#620）的 TLS/IO 区
#define COMPACT_STACK (256 * MB)   // 丙的栈区
#define ALIAS_FIRST_HEAP (192 * MB)   // 别名优先的乙布局：堆 64 MiB + 远端影子余量 128 MiB（影子与堆共用堆区）
// 窗口里留给宿主自己的地址（Metal 大缓冲、窗口尾部统一分配）：现行包里 63.25 GiB 的款在 64 GiB 空洞里留下的就是这么多（vawin.c TL_SMALL 注释：766 MB），
//   甲里堆先让出它（甲的窗口尾在别名区之外）。乙不在窗口里留：别名区伸出窗口，窗口尾还给宿主就和远端承诺段重叠——
//   宿主放进去的东西会被游戏的远端访问静默读写；乙的宿主保留段由 vawin.c 放在窗口下方
#define HOST_KEEP (768 * MB)

static void vamm_alias(s2a_layout *o, uint64_t t) {   // t：1 GiB 对齐的 TLS/IO 起点
    o->tlsio_base = t;                 o->tlsio_size = 2 * MB - 0x4000;
    o->alias_base = t + 2 * MB - 0x4000; o->alias_size = VAMM_ALIAS + 0x8000 - 2 * MB;
}
static void vamm_small(s2a_layout *o, uint64_t at, uint64_t stack, uint64_t heap) {   // 栈 → 堆 → 共享余量，可随机区罩住三者
    o->stack_base = at;                o->stack_size = stack;
    o->heap_base = at + stack;         o->heap_size = heap;
    o->aslr_base = at;                 o->aslr_size = stack + heap + VAMM_SHARED;
}
// 这款上一局真要过的普通堆（svc_mem.c SetHeapSize 超出堆区时记进 wire/<程序号>/heap_need，起局布局前读回设到这里；0 = 没记过）：
//   别名优先的款堆区按静态识别压小（ALIAS_FIRST_HEAP），堆大小是运行时算出来的款（D-NGH9：开局要 3.1 GB）静态认不出、每局都在 nninitStartup 里 abort。
//   记过就至少给到这么多（乙再加远端影子余量），下一局起得来
static uint64_t g_heap_floor;
void s2a_layout_heap_floor_set(uint64_t v) { g_heap_floor = v; }
static uint64_t alias_first_heap(void) { uint64_t f = A2M(g_heap_floor) + (ALIAS_FIRST_HEAP - 64 * MB); return f > ALIAS_FIRST_HEAP ? f : ALIAS_FIRST_HEAP; }   // 堆 + 影子余量 128 MiB
static uint64_t g_app_pool = 0xCD500000ull;
uint64_t s2a_app_pool(void) { return g_app_pool; }
void s2a_app_pool_set(uint64_t v) { g_app_pool = v; }
static void heapmode(s2a_layout *o, uint64_t b) {   // 堆模式（系统资源为 0）沿用 39 位布局；物理分配仍受应用池限制。别名区不调 MapPhysicalMemory 就不碰
    // 堆区 6 GiB；应用池比它大（Switch 2 的 9 GiB）时堆区放大到池（GiB 对齐），否则 SetHeapSize 给不满池（Pokopia 开局要约 8 GiB 堆）。别名区顺延，32 GiB 跨度内放得下
    uint64_t heap = AGB(S2A_APP_POOL) > 6 * GB ? AGB(S2A_APP_POOL) : 6 * GB;
    o->tlsio_base = b;          o->tlsio_size = GB;
    o->stack_base = b + GB;     o->stack_size = 2 * GB;
    o->heap_base = b + 3 * GB;  o->heap_size = heap;
    o->alias_base = b + 3 * GB + heap; o->alias_size = 8 * GB;
    o->aslr_base = b;           o->aslr_size = 32 * GB;
}

// 36 位（NPDM 地址空间类型 1，老 SDK）照 Ryujinx KPageTableBase AddressSpace64BitDeprecated：代码区 0x78000000，栈区与 TLS/IO 区不单列、
//   就是代码区（stackAndTlsIo = 代码区），堆区 6 GiB（同 heapmode：应用池更大时放大到池）、别名区 0x180000000，可随机区罩住全部（Ryujinx 是整个 2^36，
//   这里同堆模式给 32 GiB，其余 18 GiB 留给共享内存 / 传输内存随机映射）。各区都要在 2^36 以下：老 SDK 打包 HIPC 缓冲描述符只编 36 位地址
//   （sdk HipcMessageBufferAccessor::SetSend 只取地址 32–35 位，36–38 位不写），游戏地址落在 2^36 以上传给服务就丢了高位（s2a_as_type_top）。
//   代码区 [W, W + 0x78000000) 里依次是模块段、TLS/IO（TLR 页，不进 GetInfo）、栈区：报给游戏的栈区去掉前两段（Ryujinx 的栈区 = 整个代码区，
//   内核在区里找空位；我方 MapMemory 只核映射表、TLR 按序往上切，栈区与模块 / TLR 重叠就会被映射盖掉，同 39 位各区不相交的做法）。主线程栈照旧在栈区最高处
#define AS36_CODE 0x78000000ull
#define AS36_ALIAS 0x180000000ull
#define AS36_TLR (2 * MB)
static uint64_t as36_heap(void) { return AGB(S2A_APP_POOL) > 6 * GB ? AGB(S2A_APP_POOL) : 6 * GB; }
static int as36(s2a_layout *o, uint64_t W, uint64_t S, uint64_t mod, uint64_t *mod_base) {
    uint64_t heap = as36_heap(), span = AGB(AS36_CODE) + heap + AS36_ALIAS;   // 代码区 → 堆 → 别名：最少要这么多宿主地址
    if (mod + AS36_TLR >= AS36_CODE || S < span) return -2;   // 模块 + TLR 要在代码区里给栈留地方
    uint64_t asz = S >= 32 * GB ? 32 * GB : S & ~(GB - 1);
    o->tlsio_base = W + mod;               o->tlsio_size = AS36_TLR;
    o->stack_base = W + mod + AS36_TLR;    o->stack_size = AS36_CODE - mod - AS36_TLR;
    o->heap_base = W + AGB(AS36_CODE);     o->heap_size = heap;
    o->alias_base = o->heap_base + heap;   o->alias_size = AS36_ALIAS;
    o->aslr_base = W;                      o->aslr_size = asz;
    *mod_base = W; o->win_size = asz;
    return 0;
}

// 甲（标准）布局的跨度：VAMM = 别名 + 小区（堆给满应用池）+ 模块；堆模式 = 32 GiB + 模块。宿主占窗口按它要（vawin.c），要不到整块也照样起
uint64_t s2a_layout_need(uint32_t as_type, uint64_t sys_resource_size, uint64_t module_span) {
    if ((as_type != 3 && as_type != 1) || module_span > 64 * GB) return 0;
    uint64_t mod = A2M(module_span);
    if (as_type == 1) return mod + AS36_TLR >= AS36_CODE ? 0 : 32 * GB;   // 模块在代码区里，跨度就是可随机区
    return sys_resource_size ? VAMM_ALIAS + 2 * MB + VAMM_STACK + S2A_HEAP_DEFAULT + VAMM_SHARED + mod : 32 * GB + mod;
}

// 报给游戏的别名区大小（GetInfo AliasSize，#1441）。内部布局不动（别名区仍按标准尺寸、伸出窗口那段照旧走远端兜底），只是告诉游戏小一点：
//   SDK 给新地址区挑「最高那段空隙的底部」，报多大游戏就往多高爬（上面「别名优先」那段的火炬之光3 读码），报到窗口末，内存就落在窗口里、不再缺页代执行。
//   只在这几种情况都成立时收：① 没有出包静态结论（alias_gb == 0；> 0 的上面已按证明收进窗口，< 0 = 上限不定、宁慢不崩）；
//   ② 宿主占到的空洞放不下标准布局（hole < need；放得下的机型与游戏报给游戏的值一个字节不变）；③ 别名区确实伸出窗口；
//   ④ 本款没记过「收小后游戏照旧映射到收掉的那段」（full_flag，svc_mem.c 发现就记、下次起局恢复原值）。
//   收到窗口末、按 GiB 取整；不足 8 GiB 不收（39 位款的别名区标准是 64 GiB，收到太小风险大于收益，照旧走远端）
uint64_t s2a_alias_report_size(uint64_t alias_base, uint64_t alias_size, uint64_t win_end, uint64_t hole, uint64_t need, int alias_gb, int full_flag) {
    if (alias_gb || full_flag || !need || hole >= need || alias_base + alias_size <= win_end || win_end <= alias_base) return alias_size;
    uint64_t r = (win_end - alias_base) & ~(GB - 1);
    return r >= 8 * GB && r < alias_size ? r : alias_size;
}

// 地址空间不够这款的判据（11-20 维护者定，宁漏勿误）：出包静态认出的开局大区（alias_gb GB = 大区 + SDK 元数据向上取整，大区本身是整 GiB，
//   故大区长 = (|alias_gb| − 1) GiB）由 SDK 放在元数据之后、按 GiB 对齐的起点（起点 = (别名基址 + 0x3FE00000 + 1 GiB − 1) & −1 GiB）；
//   大区末端顶到或超过窗口末 → 游戏其余地址区（SDK 放在「最高空隙的底部」= 大区之上，一款大游戏实测这里用 864 MB）必落窗口外 → 1。
//   大区末端还在窗口里（上面还留着空间）→ 0：其余地址区放不放得下读码定不了，不弹（宁漏）。alias_gb == 0（没有静态大区）→ 0
int s2a_alias_big_tops_window(uint64_t alias_base, int alias_gb, uint64_t win_end) {
    if (!alias_gb) return 0;
    uint64_t gb = (uint64_t)(alias_gb < 0 ? -alias_gb : alias_gb);
    uint64_t start = (alias_base + 0x3FE00000ull + GB - 1) & ~(GB - 1), end = start + (gb - 1) * GB;
    return end >= win_end;
}

// 即时存档命令记录区 + 虚拟池区（共 a 字节）放哪（窗口放不下标准布局时，vawin_reserve）：纯函数（放这里与布局算式同处，单测只链本文件），t_vawin_snaparena 测。
//   1 = 窗口所在空洞之外（[4 GB, 空洞起点) 里最大一块 out ≥ a）；2 = 窗口下方宿主保留段底部（段长 below，切走 a 后仍 ≥ host_min——
//   11-20 关快照的那次改动只看窗口外，iOS 27 那一段被共享缓存占满、量出 0，可按应用池留的宿主段有 21 GB，所有游戏的快照都被关了，#1867）；
//   0 = 都放不下，这一局关快照。宿主段只有 host_min 那么多时不切：Metal 着色器库要从那里放（原先切满 3 GB 首帧前 NSMallocException）
int s2a_snap_arena_place(uint64_t out, uint64_t below, uint64_t a, uint64_t host_min) {
    if (out >= a) return 1;
    if (below >= a + host_min) return 2;
    return 0;
}
// 同上，宿主段本来不够时按游戏实际要多少让窗口（11-21）：fit = 宿主占到的空洞，*below = 窗口下方宿主段（放宿主段底部时可能加长到 a + host_min）；
//   span = 本款已知的最高跨度（本机记录 / 种子表，0 = 还不知道）。不知道 → 让（按需起局，碰到上限再学）；知道且 span + margin ≤ fit − (a + host_min) → 让；
//   否则 0（这台设备的地址空间真不够同时放下这款与快照）。空洞连 a + host_min 都不到 → 0
// 选定游戏后收尾还给系统的 released 字节里放不放得下快照区 a 再给宿主留 host_min（vawin.c snap_late_take，11-21）
int s2a_snap_late_fits(uint64_t released, uint64_t a, uint64_t host_min) { return released >= a + host_min; }
int s2a_snap_arena_place2(uint64_t out, uint64_t fit, uint64_t *below, uint64_t a, uint64_t host_min, uint64_t span, uint64_t margin) {
    int w = s2a_snap_arena_place(out, *below, a, host_min);
    if (w) return w;
    uint64_t want = a + host_min;
    if (fit <= want) return 0;
    if (span && span + margin > fit - want) return 0;
    *below = want;
    return 2;
}

// 分配器预留压小（改写器在 nn::mem::StandardAllocator 初始化入口挂的闸，svc_mem.c s2a_sainit_gate）：游戏传「地址空、尺寸 size」时
//   SDK 在别名区划一整块，起点 = 元数据之后按 GiB 对齐（同上 s2a_alias_big_tops_window），末尾留 4 KiB 保护页。
//   放得下 = 别名区整段在窗口里，或这块（连前后保护页 8 KiB）的末端在窗口里 → 原样，与今天逐字节相同（判据同「地址空间不够」提示）。
//   放不下 → 压到「窗口末 − 起点 − 余量」按 GiB 向下取整。余量 = 应用池 + 8 KiB：块之后的其余地址区由 SDK 一路往上放
//   （s2a_layout_compute 注释），它们的提交总量受应用池封顶，按每字节占一字节地址留（≥2 MiB 的区实测不到 2.01 倍、4 KiB 小区更多——
//   留不够的那部分落到窗口外照旧走远端，只是慢，不会错）。压出来不到 1 GiB（窗口实在太小）→ 不压。返回值 = 该交给 SDK 的尺寸，等于 size 即不动
uint64_t s2a_sainit_size(uint64_t alias_base, uint64_t alias_size, uint64_t win_end, uint64_t pool, uint64_t size) {
    if (alias_base + alias_size <= win_end) return size;
    uint64_t start = (alias_base + 0x3FE00000ull + GB - 1) & ~(GB - 1);
    if (start < win_end && size + 0x2000 <= win_end - start) return size;
    if (start >= win_end || win_end - start <= pool + 0x2000) return size;
    uint64_t y = (win_end - start - pool - 0x2000) & ~(GB - 1);
    return y >= GB && y < size ? y : size;
}

int s2a_layout_compute(uint32_t as_type, uint64_t sys_resource_size, uint64_t module_span, int alias_gb, uint64_t W, uint64_t S, s2a_layout *o, uint64_t *mod_base, uint64_t *shadow_base) {
    memset(o, 0, sizeof *o); *mod_base = *shadow_base = 0;
    uint64_t top = s2a_as_type_top(as_type);
    if (!top) return -1;
    if ((W & (GB - 1)) || module_span > 64 * GB || !s2a_as_type_end(as_type, W, S)) return -2;   // 36 位款可在 2^36 以上按 2^36 对齐的一块里（as_type.h）
    uint64_t mod = A2M(module_span);
    o->win_base = W; o->as_type = as_type; o->sys_resource_size = sys_resource_size;
    if (as_type == 1) { if (as36(o, W, S, mod, mod_base)) { memset(o, 0, sizeof *o); return -2; } return 0; }
    if (sys_resource_size) {
        // 甲：别名区在前、整段有宿主地址；其后栈 / 堆 / 余量 / 模块。堆只对别名优先的款让位（从应用池上限往下让到窗口放得下，至少 32 MiB）——
        //   别的款不知道要多大堆（王国之泪首次就要 2.05 GB），放不下「别名 + 满额堆」就走乙：堆给满放前段、别名区伸出窗口（承诺，远端翻译兜底）
        uint64_t stack = alias_gb ? ALIAS_FIRST_STACK : VAMM_STACK, fixed = VAMM_ALIAS + 2 * MB + stack + VAMM_SHARED + mod;
        uint64_t min_heap = A2M(g_heap_floor) > MIN_HEAP ? A2M(g_heap_floor) : MIN_HEAP;   // 记过真要的堆（g_heap_floor）：甲放不下它就走乙（堆给够、别名区伸出窗口走远端）——慢一点也要起得来
        if (alias_gb ? S >= fixed + min_heap : S >= fixed + S2A_HEAP_DEFAULT) {
            uint64_t heap = S >= fixed + HOST_KEEP + MIN_HEAP ? (S - fixed - HOST_KEEP) & ~(2 * MB - 1) : MIN_HEAP;
            if (heap > S2A_HEAP_DEFAULT) heap = S2A_HEAP_DEFAULT;
            if (alias_gb && A2M(g_heap_floor) > heap && S >= fixed + A2M(g_heap_floor)) heap = A2M(g_heap_floor);   // 上一局真要过这么多（见 g_heap_floor），窗口放得下就给
            vamm_alias(o, W);
            vamm_small(o, W + VAMM_ALIAS + 2 * MB, stack, heap);
            *mod_base = o->aslr_base + o->aslr_size;
            o->win_size = fixed + heap;
            return 0;
        }
        // 乙：模块、栈、堆、余量在前段，别名区在其后、伸出窗口（伸出段的内容放影子区，far.c）。影子区与堆共用堆区这段地址：
        //   堆从底往上长、影子块从顶往下分——两者真占的物理页合起来受应用池封顶，地址不必各留一份（iOS 26 大空洞只有 51.0 GiB，省下的都给别名区）
        //   别名优先（出包静态认出「开局在别名区要一整块巨大地址区」= 内存走 VAMM 自管，tools/addr_need.py static_alias_gb）：堆区 64 MiB +
        //   影子余量 128 MiB，别名区紧接前段、不按 GiB 对齐，窗口里放不下要的时承诺放到 64 GiB（元数据 ≤1 GiB + 对齐浪费 ≤1 GiB + 62 GiB 照样放下，SDK 对齐没被削也成立）——
        //   巫师3 碰到 49.1 GB，iOS 26 的 [12, 63) GB 空洞（下方 1 GiB 留宿主）放得下的前提
        vamm_small(o, W + mod, stack, alias_gb ? alias_first_heap() : S2A_HEAP_DEFAULT + S2A_FAR_SLACK);
        uint64_t t = alias_gb ? A2M(o->aslr_base + o->aslr_size) : AGB(o->aslr_base + o->aslr_size);
        if (t + 2 * MB > W + S) { memset(o, 0, sizeof *o); return -2; }   // 前段 + TLS/IO 都放不下
        vamm_alias(o, t);
        // 别名优先：承诺 = 宿主兜得住的那段（别名区收到窗口末、不开远端），前提是放得下游戏代码证明要的；放不下才承诺 64 GiB、伸出段走远端。
        //   SDK 给新地址区挑位置是「最高那段空隙的底部」（VammManager::AllocateAddressRegion 的找空隙函数从末尾哨兵往前走前驱，
        //   火炬之光3 sdk+0xd23d0 反汇编），活着的地址区一路往上爬：承诺多高、游戏迟早碰到多高，与真用多少无关——火炬之光3 真映射 1.2 GB，
        //   地址爬到 64 GiB 别名区顶 +63.4 GB，伸出窗口那 1.5 GB 一碰就缺页代执行，每帧约 150 ms。
        //   要的（11-03 维护者：账要算对，不选倍数）= 静态大区连元数据（alias_gb，addr_need.py 已含 0x3FE00000）+ 大区按 GiB 对齐最多浪费 1 GiB
        //   + 大区之外活着的地址区的最坏地址账：这些区都整段提交（上限不定的款不走这里），提交总量 ≤ 应用池 P；SDK 放区的起点
        //   = (前一区末 + (粒度 | 0xFFF)) & −粒度（sdk+0xd23d0），每个区最多多占「粒度 + 0xFFF」，粒度 <2 MiB 的区是 64 KiB、
        //   [2, 4) MiB 是 2 MiB、[4, 32) MiB 是 4 MiB、[32 MiB, 1 GiB) 是 32 MiB、≥1 GiB 是 1 GiB（地址空间.md A6）。
        //   每字节提交最坏占地址 = (4 KiB + 64 KiB + 0xFFF) / 4 KiB < 18（4 KiB 小区；≥2 MiB 的区不到 2.01）→ 18 P；末区之后再留 4 KiB 保护页
        //   出包读码判「上限不定」（alias_gb < 0：有只占地址、尺寸非常量的申请，addr_need.py alias_unbounded）：证明不了就不收，照旧 64 GiB + 远端（宁慢不崩）
        if (alias_gb) {
            uint64_t fit = W + S - o->alias_base, need = (uint64_t)(alias_gb < 0 ? -alias_gb : alias_gb) * GB + GB + 18 * S2A_APP_POOL + 0x2000;
            o->alias_size = alias_gb > 0 && fit >= need ? fit : 64 * GB;
        }
        *mod_base = W; *shadow_base = o->alias_base + o->alias_size > W + S ? o->heap_base : 0; o->win_size = S;
        return 0;
    }
    if (S >= 32 * GB + mod) { heapmode(o, W); *mod_base = W + 32 * GB; o->win_size = 32 * GB + mod; return 0; }
    // 乙：模块在前，各区整体后移到下一个 GiB；堆区之前的部分（TLS/IO、栈）与至少 32 MiB 堆必须有宿主地址
    uint64_t b = AGB(W + mod);
    heapmode(o, b);
    if (o->heap_base + MIN_HEAP <= W + S) { *mod_base = W; o->win_size = S; return 0; }
    // 丙（#620：老 iPad / iPhone 给 App 的地址窗口只有 2 GiB，模块段 616 MB 的小游戏也被「乙」挡下）：乙按满尺寸排 TLS/IO 1 GiB、栈区 2 GiB，
    //   堆要从窗口起点往后 3 GiB 以上才开始。这两区只是线程栈 / TLR / TLS 块的地址范围（svc_mem.c 按 L.* 取，不写死尺寸），小游戏用不到：
    //   模块后按 2 MiB 对齐，TLS/IO 64 MiB、栈区 256 MiB，堆区 / 别名 / 可随机区尺寸同乙、起点前移；仍要至少 32 MiB 堆有宿主地址。
    //   游戏要的线程栈或堆超出时，照常在 MapMemory / SetHeapSize 那里回资源不足（日志可查），不在起局一律拒
    heapmode(o, A2M(W + mod));
    uint64_t hs = o->heap_size, h0 = o->tlsio_base + COMPACT_TLSIO + COMPACT_STACK;
    o->tlsio_size = COMPACT_TLSIO;
    o->stack_base = o->tlsio_base + COMPACT_TLSIO; o->stack_size = COMPACT_STACK;
    o->heap_base = h0; o->heap_size = hs;
    o->alias_base = h0 + hs;
    if (o->heap_base + MIN_HEAP > W + S) { memset(o, 0, sizeof *o); return -2; }
    *mod_base = W; o->win_size = S;
    return 0;
}
