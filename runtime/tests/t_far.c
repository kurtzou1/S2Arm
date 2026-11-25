// 远端影子单测（far.c）：游戏地址保持不可访问（PROT_NONE 预留），内容在影子区；真信号走一遍缺页代执行。
//   期望值都从「往哪写了什么」直接推出，不调被测的翻译算式：经游戏地址写 → 影子里读到；影子里写 → 经游戏地址读到。
#include "../src/native.h"
#include <setjmp.h>
#include <signal.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
module_t *module_of(const void *p) { (void)p; return NULL; }   // 单测不装模块：点全记成宿主代码
static uint64_t g_he; uint64_t s2a_mem_heap_end(void) { return g_he; }   // 堆顶（svc_mem.c 的桩）：缺省 0 = 没有堆
int s2a_guest_zero(uint64_t a, uint64_t n) { (void)a; (void)n; return 0; } int s2a_guest_in_file(uint64_t a, uint64_t n) { (void)a; (void)n; return 0; } void *s2a_guest_map_any(uint64_t len) { (void)len; return MAP_FAILED; }   // vawin.c 的桩：没有客体内存文件后备
static int bad, cnt;
int s2a_far_session_reset(void);
#define EQ(name, want, got) do { unsigned long long w_ = (unsigned long long)(want), g_ = (unsigned long long)(got); cnt++; if (w_ != g_) { bad++; printf("✗ %s：期望 %#llx → 真结果 %#llx\n", name, w_, g_); } } while (0)
static uint64_t g_fc, g_fp, g_fn; static void fake_flush(const void *p, size_t n) { g_fc++; g_fp = (uint64_t)p; g_fn = n; }
static sigjmp_buf g_jb; static volatile int g_refused;
static void on_fault(int sig, siginfo_t *si, void *ctx) {
    uint32_t esr = ((ucontext_t *)ctx)->uc_mcontext->__es.__esr;
    if (s2a_far_fault(ctx, (uint64_t)si->si_addr, (int)(esr >> 6 & 1))) return;
    g_refused = 1; siglongjmp(g_jb, 1);
}
int main(void) {
    setenv("S2A_FAR_LINEAR", "0", 1);   // 以下老用例测分块影子（iOS 的走法：影子放堆区、堆区不够改占宿主任意地址）；线性影子（Mac）在末尾单测
    const uint64_t MB = 1ull << 20, SPAN = 16 * MB;
    // 影子区：布局给的堆区（窗口里的不可访问保留，这里自己占 64 MiB，没有堆）；远端：只取地址、不预先映射，s2a_far_set 自己把空洞占成不可访问
    const uint64_t SH = 64 * MB; uint8_t *sraw = mmap(NULL, SH + 2 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint8_t *shadow = (uint8_t *)(((uint64_t)sraw + 2 * MB - 1) & ~(2 * MB - 1));   // 同真实布局：堆区起止按 2 MiB 对齐
    uint8_t *raw = mmap(NULL, SPAN + 4 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint64_t G = ((uint64_t)raw + 0x4000 + 2 * MB - 1) & ~(2 * MB - 1);   // 远端起点按 2 MiB 对齐（同布局：别名区伸出窗口处在 GiB 边界上）
    munmap((void *)G, SPAN);   // 只把远端那段放出去（s2a_far_set 自己占）；G 下方那页仍是本单测的保留，跨窗口末尾用例拿它当窗口末页
    s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
    typedef struct { uint64_t lo; int64_t *dir; } far_desc_t;   // 同 far.c s2a_far_desc 布局（C# Native.FarDesc 照它声明）
    const far_desc_t *fd = s2a_far_desc_get();
    EQ("描述符（C# GuestMemory 取的那张）：远端起点", G, fd->lo); EQ("描述符：目录已建", 1, fd->dir != NULL);
    { uint8_t v; EQ("远端空洞已占成不可访问（mincore 认得这段 = 有映射）", 0, mincore((void *)G, 0x4000, (char *)&v)); }
    struct sigaction sa = {0}; sa.sa_sigaction = on_fault; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    EQ("给页 [G, +32K)", 0, s2a_far_map(G, 0x8000));
    EQ("给页 [G+2M, +16K)", 0, s2a_far_map(G + 2 * MB, 0x4000));
    uint8_t *h0 = s2a_far_g2h(G), *h2 = s2a_far_g2h(G + 2 * MB);
    EQ("描述符目录第 1 块 = 该块影子 − 游戏", (uint64_t)h2 - (G + 2 * MB), (uint64_t)fd->dir[1]);
    EQ("影子从堆区顶往下分：第一块在顶", (uint64_t)shadow + SH - 2 * MB, (uint64_t)(h0 - 0));
    EQ("第二块紧贴第一块下方（与游戏地址顺序相反，跨块访存走并排槽）", (uint64_t)h0 - 2 * MB, (uint64_t)h2);
    EQ("影子已分到的最低地址", (uint64_t)h2, s2a_far_floor());
    EQ("游戏地址本身仍不可访问（影子与游戏地址不同）", 1, (uint64_t)h0 != G);
    *(volatile uint64_t *)(G + 8) = 0x1122334455667788ull;
    EQ("经游戏地址写 8 字节 → 影子", 0x1122334455667788ull, *(uint64_t *)(h0 + 8));
    h0[16] = 0xAB;
    EQ("影子写 → 经游戏地址读 1 字节", 0xAB, *(volatile uint8_t *)(G + 16));
    { uint64_t a = 0x0101010101010101ull, b = 0x0202020202020202ull; __asm__ volatile("stp %0, %1, [%2]" :: "r"(a), "r"(b), "r"(G + 0x40) : "memory");
      EQ("寄存器对写 前半", a, *(uint64_t *)(h0 + 0x40)); EQ("寄存器对写 后半", b, *(uint64_t *)(h0 + 0x48)); }
    { memcpy(h0 + 0x3FFC, "\x11\x22\x33\x44\x55\x66\x77\x88", 8); uint64_t v; __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(G + 0x3FFC) : "memory");
      EQ("跨 16 KB 页（同一影子块）读 8 字节", 0x8877665544332211ull, v); }
    { memset(h0 + 0x80, 0xFF, 64); __asm__ volatile("dc zva, %0" :: "r"(G + 0x80) : "memory");
      uint64_t z = 0; for (int i = 0; i < 64; i++) z |= h0[0x80 + i]; EQ("DC ZVA 清影子 64 字节", 0, z); }
    __asm__ volatile("dc civac, %0" :: "r"(G + 0x100) : "memory"); EQ("DC CIVAC 跳过不崩", 0, g_refused);
    {   // 快照区让掉的那段窗口另数缺页（快照被关根修 ⑥，far.c s2a_far_squeeze_band / s2a_far_squeeze_faults）：段 = [G, G + 16K)。
        //   期望：段外（G + 2M）读一次 → 段内计数不变；段内（G + 0x200）读一次 → +1；段的上界不含（G + 16K）→ 不变
        void s2a_far_squeeze_band(uint64_t, uint64_t); uint64_t s2a_far_squeeze_faults(void);
        s2a_far_squeeze_band(G, G + 0x4000); uint64_t q0 = s2a_far_squeeze_faults(), v;
        __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(G + 2 * MB) : "memory"); EQ("让掉段外读：段内计数不变", q0, s2a_far_squeeze_faults());
        __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(G + 0x200) : "memory"); EQ("让掉段内读：段内计数 +1", q0 + 1, s2a_far_squeeze_faults());
        __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(G + 0x4000) : "memory"); EQ("让掉段上界（不含）读：不变", q0 + 1, s2a_far_squeeze_faults());
        (void)v; s2a_far_squeeze_band(0, 0); }
    {   // 11-14 D-52P7：跨窗口末尾的访存（前半在窗口最后一页、后半在远端首页影子）：窗口里游戏地址 = 宿主地址，与远端首页影子并排进槽代执行。
        //   期望从两边各写了什么直接推：窗口页末 4 字节 11 22 33 44、影子首 4 字节 55 66 77 88 → 8 字节读 = 0x8877665544332211；
        //   写 8 字节 0xA1..A8 → 窗口页末 4 字节 A1 A2 A3 A4、影子首 4 字节 A5 A6 A7 A8。反证：去掉 far.c 窗口末页那行，两项都被拒绝（走崩溃老路）
        uint8_t *W = (uint8_t *)(G - 0x4000);   // 本单测自己保留的那页（raw 里 G 下方）
        if (mprotect(W, 0x4000, PROT_READ | PROT_WRITE)) { bad++; printf("✗ 窗口末页改可读写失败\n"); }
        else {
            memcpy(W + 0x3FFC, "\x11\x22\x33\x44", 4); memcpy(h0, "\x55\x66\x77\x88", 4);
            uint64_t v = 0, zero = 0; g_refused = 0;
            if (!sigsetjmp(g_jb, 1)) __asm__ volatile("ldr %0, [%1, %2]" : "=r"(v) : "r"(G - 4), "r"(zero) : "memory");
            EQ("跨窗口末尾读 8 字节（寄存器偏移 LDR）：不拒绝", 0, g_refused); EQ("跨窗口末尾读 8 字节：前半窗口页、后半远端影子", 0x8877665544332211ull, v);
            uint64_t x = 0xA8A7A6A5A4A3A2A1ull; g_refused = 0;
            if (!sigsetjmp(g_jb, 1)) __asm__ volatile("str %0, [%1, %2]" :: "r"(x), "r"(G - 4), "r"(zero) : "memory");
            EQ("跨窗口末尾写 8 字节：不拒绝", 0, g_refused); EQ("跨窗口末尾写：窗口页末 4 字节", 0xA4A3A2A1u, *(uint32_t *)(W + 0x3FFC)); EQ("跨窗口末尾写：影子首 4 字节", 0xA8A7A6A5u, *(uint32_t *)h0);
            mprotect(W, 0x4000, PROT_NONE);
        }
    }
    g_refused = 0; if (!sigsetjmp(g_jb, 1)) { (void)*(volatile uint64_t *)(G + 4 * MB); }
    EQ("碰没映射的远端地址：拒绝代执行（走崩溃老路）", 1, g_refused);
    { EQ("给页 [G+2M−16K, +16K)：与 [G+2M, …) 相邻", 0, s2a_far_map(G + 2 * MB - 0x4000, 0x4000));   // 第一块已分，只放开影子页
      uint64_t a = 0x0303030303030303ull, b = 0x0404040404040404ull; __asm__ volatile("stp %0, %1, [%2]" :: "r"(a), "r"(b), "r"(G + 2 * MB - 8) : "memory");
      EQ("跨 2 MiB 块（影子不相邻）的寄存器对写 前半（落第一块）", a, *(uint64_t *)(h0 + 2 * MB - 8)); EQ("跨块 后半（落第二块）", b, *(uint64_t *)h2);
      uint64_t v[2]; __asm__ volatile("ldp %0, %1, [%2]" : "=r"(v[0]), "=r"(v[1]) : "r"(G + 2 * MB - 8) : "memory");
      EQ("跨块读回 前半", a, v[0]); EQ("跨块读回 后半", b, v[1]); }
    // 独占 / 原子（far_atomic）：期望值从初值直接推
    { uint64_t g = G + 0x200; *(uint64_t *)(h0 + 0x200) = 41; uint32_t st;
      __asm__ volatile("1: ldaxr x8, [%1]\n add x8, x8, #1\n stlxr %w0, x8, [%1]\n cbnz %w0, 1b" : "=&r"(st) : "r"(g) : "x8", "memory");
      EQ("独占循环加一 41 → 42", 42, *(uint64_t *)(h0 + 0x200)); }
    { uint64_t g = G + 0x210, old; *(uint64_t *)(h0 + 0x210) = 100;
      __asm__ volatile(".arch armv8.1-a\n ldadd %1, %0, [%2]" : "=&r"(old) : "r"((uint64_t)5), "r"(g) : "memory");
      EQ("LDADD 回旧值 100", 100, old); EQ("LDADD 后 105", 105, *(uint64_t *)(h0 + 0x210)); }
    { uint64_t g = G + 0x220, e = 7; *(uint32_t *)(h0 + 0x220) = 7;
      __asm__ volatile(".arch armv8.1-a\n cas %w0, %w1, [%2]" : "+r"(e) : "r"((uint64_t)9), "r"(g) : "memory");
      EQ("CAS 成功：旧值 7", 7, e); EQ("CAS 成功：写成 9", 9, *(uint32_t *)(h0 + 0x220));
      e = 7; __asm__ volatile(".arch armv8.1-a\n cas %w0, %w1, [%2]" : "+r"(e) : "r"((uint64_t)11), "r"(g) : "memory");
      EQ("CAS 失败：回现值 9", 9, e); EQ("CAS 失败：不写", 9, *(uint32_t *)(h0 + 0x220)); }
    { uint64_t g = G + 0x230, old; *(uint64_t *)(h0 + 0x230) = 0xAA;
      __asm__ volatile(".arch armv8.1-a\n swp %1, %0, [%2]" : "=&r"(old) : "r"((uint64_t)0x55), "r"(g) : "memory");
      EQ("SWP 回旧值", 0xAA, old); EQ("SWP 写入", 0x55, *(uint64_t *)(h0 + 0x230)); }
    { uint64_t g = G + 0x240; uint32_t st; *(uint64_t *)(h0 + 0x240) = 1; *(uint64_t *)(h0 + 0x248) = 2;
      __asm__ volatile("1: ldxp x8, x9, [%1]\n add x8, x8, #10\n add x9, x9, #20\n stxp %w0, x8, x9, [%1]\n cbnz %w0, 1b" : "=&r"(st) : "r"(g) : "x8", "x9", "memory");
      EQ("独占对 前半 1 → 11", 11, *(uint64_t *)(h0 + 0x240)); EQ("独占对 后半 2 → 22", 22, *(uint64_t *)(h0 + 0x248)); }
    // 写独占对的第二个寄存器是 xzr（stlxp w8, x21, xzr, [x28]：一款游戏在远端清一个 16 字节槽的后半，玩家诊断三份因此 SIGSEGV）：前半写值、后半写 0
    { uint64_t g = G + 0x250; uint32_t st; *(uint64_t *)(h0 + 0x250) = 5; *(uint64_t *)(h0 + 0x258) = 6;
      g_refused = 0;   // 不认这一形的旧代码会拒绝代执行：跳回这里报红，不在独占循环里重试挂死
      if (!sigsetjmp(g_jb, 1)) __asm__ volatile("1: ldaxp x8, x9, [%1]\n add x8, x8, #1\n stlxp %w0, x8, xzr, [%1]\n cbnz %w0, 1b" : "=&r"(st) : "r"(g) : "x8", "x9", "memory");
      EQ("写独占对带 xzr：不拒绝", 0, g_refused); EQ("写独占对带 xzr 前半 5 → 6", 6, *(uint64_t *)(h0 + 0x250)); EQ("写独占对带 xzr 后半写成 0", 0, *(uint64_t *)(h0 + 0x258)); }
    // SDK 内存函数族（s2a_far_bind）：G 起两块已分（[G, +32K) 与 [G+2M−16K, G+2M+16K)，两块影子不相邻）
    { void *(*mc)(void *, const void *, size_t) = (void *)s2a_far_bind("memcpy", 1), *(*ms)(void *, int, size_t) = (void *)s2a_far_bind("memset", 1),
           *(*mm)(void *, const void *, size_t) = (void *)s2a_far_bind("memmove", 1);
      EQ("不在名单的导入原样回", 77, s2a_far_bind("strlen", 77));
      uint8_t src[64]; for (int i = 0; i < 64; i++) src[i] = (uint8_t)(i + 1);
      mc((void *)(G + 2 * MB - 32), src, 64);   // 近 → 远端，跨块
      EQ("memcpy 跨块 前段落第一块影子", 1, h0[2 * MB - 32]); EQ("memcpy 跨块 后段落第二块影子", 64, h2[31]);
      uint8_t back[64]; mc(back, (void *)(G + 2 * MB - 32), 64);   // 远端 → 近
      EQ("memcpy 远端读回", 0, memcmp(back, src, 64));
      ms((void *)(G + 2 * MB - 8), 0xEE, 16); EQ("memset 跨块 前半", 0xEE, h0[2 * MB - 1]); EQ("memset 跨块 后半", 0xEE, h2[7]);
      for (int i = 0; i < 32; i++) h0[0x300 + i] = (uint8_t)i;
      mm((void *)(G + 0x304), (void *)(G + 0x300), 16);   // 远端内重叠后移
      EQ("memmove 重叠后移：首字节", 0, h0[0x304]); EQ("memmove 重叠后移：末字节", 15, h0[0x313]); }
    { void (*fl)(const void *, size_t) = (void *)s2a_far_bind("_ZN2nn2os14FlushDataCacheEPKvm", (uint64_t)fake_flush);
      uint8_t near[16]; fl(near, 16); EQ("FlushDataCache 近地址：原函数、原指针", (uint64_t)near, g_fp);
      g_fc = 0; fl((void *)(G + 0x100), 64); EQ("FlushDataCache 远端：原函数调 1 次", 1, g_fc); EQ("FlushDataCache 远端：传影子地址", (uint64_t)(h0 + 0x100), g_fp); EQ("FlushDataCache 远端：长度", 64, g_fn); }
    s2a_far_release(G, 0x4000); EQ("还页后再给", 0, s2a_far_map(G, 0x4000));
    EQ("还过的页再给出去是零页", 0, *(volatile uint64_t *)(G + 8));
    // 一次请求跨三块（[G+6M−16K, G+10M+16K) 涉及 3、4、5 号块）：三块影子按游戏地址升序连成一段（显存池整池一个零拷贝缓冲靠它）
    EQ("一次请求给页跨三块", 0, s2a_far_map(G + 6 * MB - 0x4000, 4 * MB + 0x8000));
    EQ("同请求的块影子连续 3→4", (uint64_t)s2a_far_g2h(G + 6 * MB - 0x4000) + 0x4000, (uint64_t)s2a_far_g2h(G + 6 * MB));
    EQ("同请求的块影子连续 4→5", (uint64_t)s2a_far_g2h(G + 6 * MB) + 2 * MB, (uint64_t)s2a_far_g2h(G + 8 * MB));
    // 堆区放不下（堆顶长到堆区顶）：影子改从宿主任意空闲地址整段分，照样连续、照样经游戏地址读写；堆的上限（s2a_far_floor）不动
    { uint64_t fl0 = s2a_far_floor(); g_he = (uint64_t)shadow + SH;
      EQ("堆区放不下：给页 [G+12M, +4M) 照样成功", 0, s2a_far_map(G + 12 * MB, 4 * MB));
      uint64_t h6 = (uint64_t)s2a_far_g2h(G + 12 * MB), h7 = (uint64_t)s2a_far_g2h(G + 14 * MB);
      EQ("堆区外的影子不在堆区里", 1, h6 + 4 * MB <= (uint64_t)shadow || h6 >= (uint64_t)shadow + SH);
      EQ("堆区外同请求的两块影子连续", h6 + 2 * MB, h7);
      if (h6 && h7) {   // 给页失败时游戏地址没有影子，再碰会一直缺页：上两项已报红，这里跳过
        *(volatile uint64_t *)(G + 14 * MB - 8) = 0x1122334455667788ull; EQ("经游戏地址写（缺页代执行）→ 堆区外影子读到", 0x1122334455667788ull, *(uint64_t *)(h7 - 8));
        *(uint64_t *)(h7 + 0x10) = 0xa5a5a5a5a5a5a5a5ull; EQ("堆区外影子写 → 经游戏地址读到", 0xa5a5a5a5a5a5a5a5ull, *(volatile uint64_t *)(G + 14 * MB + 0x10));
      } else EQ("堆区外影子已分", 1, 0);
      EQ("堆的上限不因堆区外的影子下移", fl0, s2a_far_floor()); g_he = 0; }
    s2a_far_report("单测");
    EQ("第一局远端退休", 0, s2a_far_session_reset());
    // 远端区间里有宿主可访问的映射（11-01 审计 P1-12）：不开远端——描述符目录留空、s2a_far_has 回 0（旧代码打红照开，游戏访存落到宿主内存上）
    { uint8_t *host = mmap((void *)(G + 4 * MB), 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
      EQ("重叠用例：在远端区间里放一页宿主读写映射", (uint64_t)(G + 4 * MB), (uint64_t)host);
      s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
      EQ("与宿主映射重叠：描述符目录留空 / 远端不认 / 堆上限不受影子限制", 0x101, (fd->dir == NULL ? 0x100 : 0) | (s2a_far_has(G, 0x4000) ? 0 : 1) | (s2a_far_floor() == UINT64_MAX ? 0 : 0x10));
      if (fd->dir) EQ("（重叠用例误开后退休）", 0, s2a_far_session_reset());
      mmap((void *)(G + 4 * MB), 0x4000, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0); }
    // 真实两块请求放不进一块大的影子区；不借助堆顶桩，走生产 mmap 溢出路径。
    s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + 2 * MB);
    EQ("小影子区放不下首个 4 MiB 请求", 0, s2a_far_map(G, 4 * MB));
    EQ("一块请求仍能使用窗口内影子", 0, s2a_far_map(G + 6 * MB, 0x4000));
    EQ("小影子区放不下第二个 4 MiB 请求", 0, s2a_far_map(G + 10 * MB, 4 * MB));
    uint8_t *overflow[4] = {s2a_far_g2h(G), s2a_far_g2h(G + 2 * MB),
        s2a_far_g2h(G + 10 * MB), s2a_far_g2h(G + 12 * MB)};
    for (unsigned i = 0; i < 4; i++) {
        EQ("退休前溢出块在窗口外", 1, (uint64_t)overflow[i] + 2 * MB <= (uint64_t)shadow || (uint64_t)overflow[i] >= (uint64_t)shadow + SH);
        overflow[i][0] = (uint8_t)(i + 1);
    }
    EQ("窗口内外影子混合退休", 0, s2a_far_session_reset());
    for (unsigned i = 0; i < 4; i++) {
        vm_address_t address = (vm_address_t)overflow[i]; vm_size_t size = 0;
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = vm_region_64(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        EQ("退休后整个窗口外影子块没有 VM 映射", 1,
            result == KERN_INVALID_ADDRESS || (result == KERN_SUCCESS && address >= (vm_address_t)overflow[i] + 2 * MB));
    }
    { vm_address_t address = (vm_address_t)shadow; vm_size_t size = 0;
      vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
      mach_port_t object = MACH_PORT_NULL;
      kern_return_t result = vm_region_64(mach_task_self(), &address, &size,
          VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
      if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
      EQ("窗口内影子仍交给 window reset 回收", 1,
          result == KERN_SUCCESS && address <= (vm_address_t)shadow && address + size >= (vm_address_t)shadow + 0x4000); }
    EQ("退休后远端描述符已撤销", 1, fd->dir == NULL && fd->lo == 0);
    EQ("空会话重复退休", 0, s2a_far_session_reset());
    // 影子页放不开（11-01 审计 P2-19）：影子区的最高保护压成只读，mprotect 读写必失败。期望：给页回 -1、目录不发布（游戏地址查不到影子）、
    //   影子余量收回（堆上限回到影子区顶）、之后同一块照常可给（旧代码先发布目录再 mprotect，失败不收回）
    { uint8_t *ro = mmap(NULL, 6 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t rb = ((uint64_t)ro + 2 * MB - 1) & ~(2 * MB - 1);
      EQ("放不开用例：影子区最高保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)rb, 4 * MB, TRUE, VM_PROT_READ));
      s2a_far_set(G, G + SPAN, rb, rb + 4 * MB);
      EQ("影子页放不开：给页回 -1", (uint64_t)-1, (uint64_t)(int64_t)s2a_far_map(G, 0x4000));
      EQ("影子页放不开：目录不发布（游戏地址查不到影子）", 0, (uint64_t)s2a_far_g2h(G));
      EQ("影子页放不开：影子余量收回（堆上限 = 影子区顶）", rb + 4 * MB, s2a_far_floor());
      EQ("放不开用例退休", 0, s2a_far_session_reset()); munmap(ro, 6 * MB); }
    // 已分块里的页中途放不开（P2-19 后续）：块内 4 页原保护 读写 / 不可访问 / 不可访问 / 第 4 页最高保护压成只读（mprotect 读写必失败）。
    //   期望给页 [第 1 页, +4 页) 回 -1，前 3 页回到各自原保护（读写 / 无 / 无）；旧代码逐页改成读写、失败不退回（第 2、3 页留在读写）。
    //   再一例：请求跨已分块（1 页不可访问）与新块，新块影子放不开 → 已分块那页也要退回不可访问
    { uint8_t *sr = mmap(NULL, 10 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t sb = ((uint64_t)sr + 2 * MB - 1) & ~(2 * MB - 1);
      s2a_far_set(G, G + SPAN, sb, sb + 8 * MB);
      EQ("中途放不开用例：先给整块首 4 页", 0, s2a_far_map(G, 0x10000));
      uint8_t *c0 = s2a_far_g2h(G);
      s2a_far_release(G + 0x4000, 0x8000);   // 第 2、3 页还回 = 不可访问
      EQ("第 4 页最高保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)(c0 + 0xC000), 0x4000, TRUE, VM_PROT_READ));
      EQ("第 4 页当前保护随之降为只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)(c0 + 0xC000), 0x4000, FALSE, VM_PROT_READ));
      EQ("已分块第 4 页放不开：给页回 -1", (uint64_t)-1, (uint64_t)(int64_t)s2a_far_map(G, 0x10000));
      int pr[4];
      for (int i = 0; i < 4; i++) { vm_address_t ad = (vm_address_t)(c0 + i * 0x4000); vm_size_t sz = 0; vm_region_basic_info_data_64_t in; mach_msg_type_number_t ct = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t ob = MACH_PORT_NULL;
        pr[i] = vm_region_64(mach_task_self(), &ad, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&in, &ct, &ob) == KERN_SUCCESS && ad <= (vm_address_t)(c0 + i * 0x4000) ? in.protection : -1;
        if (ob != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ob); }
      EQ("中途放不开：前 3 页保护回原值（读写 / 无 / 无 编码 0x300）、第 4 页仍只读", 0x3001, (uint64_t)(pr[0] << 12 | pr[1] << 8 | pr[2] << 4 | pr[3]));
      // 新块放不开：下一块影子落在 floor − 2M，先把它最高保护压成只读
      uint64_t nb = s2a_far_floor() - 2 * MB;
      EQ("新块影子最高保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)nb, 2 * MB, TRUE, VM_PROT_READ));
      EQ("跨已分块与新块、新块放不开：给页回 -1", (uint64_t)-1, (uint64_t)(int64_t)s2a_far_map(G + 2 * MB - 0x4000, 0x8000));
      { vm_address_t ad = (vm_address_t)(c0 + 2 * MB - 0x4000); vm_size_t sz = 0; vm_region_basic_info_data_64_t in; mach_msg_type_number_t ct = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t ob = MACH_PORT_NULL;
        int p = vm_region_64(mach_task_self(), &ad, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&in, &ct, &ob) == KERN_SUCCESS && ad <= (vm_address_t)(c0 + 2 * MB - 0x4000) ? in.protection : -1;
        if (ob != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ob);
        EQ("新块放不开：已分块那页退回不可访问", 0, (uint64_t)p); }
      EQ("中途放不开用例退休", 0, s2a_far_session_reset()); munmap(sr, 10 * MB); }
    // #419：游戏地址相邻、分两次映射的两块，显存池跨这两次映射时影子必须连续（nvn_mtl.m pool_host 整池建零拷贝缓冲）
    {   const uint64_t A = G + 4 * MB;   // 两次请求：[A, A+2M) 与 [A+2M, A+4M)；池 [A+1M, A+3M) 跨界
        setenv("S2A_FAR_LINEAR", "0", 1); s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
        EQ("分块（负对照）：第一次请求", 0, s2a_far_map(A, 2 * MB)); EQ("分块（负对照）：第二次请求", 0, s2a_far_map(A + 2 * MB, 2 * MB));
        EQ("分块（负对照）：跨两次映射的池影子不连续（#419 现场）", 0, s2a_far_g2h(A + 3 * MB - 0x4000) == s2a_far_g2h(A + MB) + 2 * MB - 0x4000);
        EQ("分块退休", 0, s2a_far_session_reset());
        setenv("S2A_FAR_LINEAR", "1", 1); s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
        EQ("线性：第一次请求", 0, s2a_far_map(A, 2 * MB)); EQ("线性：第二次请求", 0, s2a_far_map(A + 2 * MB, 2 * MB));
        uint8_t *h1 = s2a_far_g2h(A + MB), *h2 = s2a_far_g2h(A + 3 * MB - 0x4000);
        EQ("线性：跨两次映射的池影子连续", 1, h1 && h2 == h1 + 2 * MB - 0x4000);
        EQ("线性：影子不在堆区（不占堆）", 1, (uint64_t)(uintptr_t)h1 < (uint64_t)shadow || (uint64_t)(uintptr_t)h1 >= (uint64_t)shadow + SH);
        EQ("线性：堆下限不被影子压低", (uint64_t)shadow + SH, s2a_far_floor());
        if (h1 && h2) { h1[0] = 0x5a; h2[0] = 0xa5; }
        EQ("线性：经游戏地址读到影子里写的（缺页代执行）", 0x5a, *(volatile uint8_t *)(uintptr_t)(A + MB));
        EQ("线性：池尾页同样", 0xa5, *(volatile uint8_t *)(uintptr_t)(A + 3 * MB - 0x4000));
        EQ("线性：反着先映射高的那块，再映射低的那块也连续", 0, s2a_far_map(A + 6 * MB, 2 * MB) | s2a_far_map(A + 4 * MB, 2 * MB));
        EQ("线性：反序两块连续", 1, s2a_far_g2h(A + 6 * MB) == s2a_far_g2h(A + 4 * MB) + 2 * MB);
        EQ("线性退休", 0, s2a_far_session_reset()); }
    {   // #442 逐秒账：远端开着，这一秒碰了远端 → 打一行「远端每秒 … 缺页 N、代执行 N」；没碰的秒不出行。期望手写：先静 1.2 秒把前面用例的缺页结掉，
        //   再碰 5 次远端（5 次读，各缺页一次），等 2.2 秒；截到的日志里恰有一行，缺页 5、代执行 5
        setenv("S2A_FAR_LINEAR", "1", 1); s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
        EQ("逐秒账：给页", 0, s2a_far_map(G, 0x4000));
        // 按结算进度等，不按墙钟对齐秒边界：先等前面的缺页都记完账再截日志，读完 5 次再等这 5 次记完账（30 秒兜底）
        uint64_t s2a_far_tick_seen(void), s2a_far_faults_total(void);
        for (int i = 0; i < 3000 && s2a_far_tick_seen() != s2a_far_faults_total(); i++) usleep(10000);
        char tp[] = "/tmp/t_far_tick.XXXXXX"; int tf = mkstemp(tp), save = dup(g_s2a_logfd);
        dup2(tf, g_s2a_logfd);
        uint64_t f0 = s2a_far_faults_total();
        for (int i = 0; i < 5; i++) (void)*(volatile uint8_t *)(uintptr_t)(G + 0x100 + (uint64_t)i);
        for (int i = 0; i < 3000 && s2a_far_tick_seen() < f0 + 5; i++) usleep(10000);
        { uint64_t s2a_far_tick_n(void), n0 = s2a_far_tick_n(); for (int i = 0; i < 3000 && s2a_far_tick_n() < n0 + 2; i++) usleep(10000); }   // 再醒两次：窗口里必有没碰远端的一秒，验「不出行」
        dup2(save, g_s2a_logfd); close(save);
        char buf[4096] = {0}; lseek(tf, 0, SEEK_SET); ssize_t rn = read(tf, buf, sizeof buf - 1); close(tf); unlink(tp); (void)rn;
        // 判各行合计（5 次读可能跨两秒记成两行，那是对的）：至少一行、缺页合计 5、代执行合计 5
        int lines = 0, zero = 0; unsigned long long sf = 0, se = 0;
        for (const char *q = buf; (q = strstr(q, "远端每秒")); q++) { unsigned long long sec_, a_, b_; const char *r = strstr(q, "秒：缺页 ");
            if (r && sscanf(r, "秒：缺页 %llu、代执行 %llu", &a_, &b_) == 2) { sf += a_; se += b_; zero += a_ == 0; } (void)sec_; lines++; }
        EQ("逐秒账：至少一行", 1, lines >= 1);
        EQ("逐秒账：缺页合计 5、代执行合计 5", 1, sf == 5 && se == 5);
        EQ("逐秒账：没碰远端的秒不出行（每行缺页 ≥ 1）", 0, zero);
        if (lines < 1 || sf != 5 || se != 5) printf("  截到（%d 行、缺页 %llu、代执行 %llu）：%s\n", lines, sf, se, buf);
        EQ("逐秒账退休", 0, s2a_far_session_reset()); }
    {   // 即时存档：远端按游戏地址存 / 取。存完复位、换一块影子区重开（模拟新进程 / 新版本里影子落在别处），取回后经游戏地址读内容与权限
        int s2a_snap_far_save(FILE *), s2a_snap_far_load(FILE *);
        setenv("S2A_FAR_LINEAR", "0", 1);
        uint8_t *s1raw = mmap(NULL, SH + 2 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0), *s1 = (uint8_t *)(((uint64_t)s1raw + 2 * MB - 1) & ~(2 * MB - 1));
        s2a_far_set(G, G + SPAN, (uint64_t)s1, (uint64_t)s1 + SH);
        EQ("快照：给页 G+16K", 0, s2a_far_map(G + 0x4000, 0x4000)); EQ("快照：给页 G+4M+32K", 0, s2a_far_map(G + 4 * MB + 0x8000, 0x4000)); EQ("快照：给页 G+6M", 0, s2a_far_map(G + 6 * MB, 0x4000));
        uint8_t *a1 = s2a_far_g2h(G + 0x4000), *b1 = s2a_far_g2h(G + 4 * MB + 0x8000), *c1 = s2a_far_g2h(G + 6 * MB);
        for (int i = 0; i < 0x4000; i++) { a1[i] = (uint8_t)(i * 7 + 1); b1[i] = (uint8_t)(i * 13 + 5); c1[i] = (uint8_t)(i ^ 0x5a); }
        mprotect(c1, 0x4000, PROT_READ);   // 游戏那页是只读的
        FILE *sf = tmpfile(); EQ("快照：存", 0, s2a_snap_far_save(sf));
        EQ("快照：复位", 0, s2a_far_session_reset());
        uint8_t *s2raw = mmap(NULL, SH + 4 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0), *s2 = (uint8_t *)(((uint64_t)s2raw + 4 * MB - 1) & ~(2 * MB - 1));
        s2a_far_set(G, G + SPAN, (uint64_t)s2, (uint64_t)s2 + SH);
        rewind(sf); EQ("快照：取", 0, s2a_snap_far_load(sf)); fclose(sf);
        uint8_t *a2 = s2a_far_g2h(G + 0x4000), *b2 = s2a_far_g2h(G + 4 * MB + 0x8000), *c2 = s2a_far_g2h(G + 6 * MB);
        EQ("快照：取回后影子在新影子区里（不是原宿主地址）", 1, a2 && (uint64_t)a2 >= (uint64_t)s2 && (uint64_t)a2 < (uint64_t)s2 + SH);
        int okA = 1, okB = 1, okC = 1; for (int i = 0; i < 0x4000; i++) { okA &= a2 && a2[i] == (uint8_t)(i * 7 + 1); okB &= b2 && b2[i] == (uint8_t)(i * 13 + 5); okC &= c2 && c2[i] == (uint8_t)(i ^ 0x5a); }
        EQ("快照：G+16K 内容逐字节一致", 1, okA); EQ("快照：G+4M+32K 内容逐字节一致", 1, okB); EQ("快照：G+6M 内容逐字节一致", 1, okC);
        { vm_address_t ra = (vm_address_t)(uintptr_t)c2; vm_size_t rs = 0; vm_region_basic_info_data_64_t bi; mach_msg_type_number_t ct = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t ob;
          int ro = c2 && vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &ct, &ob) == KERN_SUCCESS && (bi.protection & VM_PROT_READ) && !(bi.protection & VM_PROT_WRITE);
          EQ("快照：只读页取回后仍只读", 1, ro); }
        EQ("快照：没给过的页（G+8M）取回后仍没分块", 0, (uint64_t)(uintptr_t)s2a_far_g2h(G + 8 * MB));
        EQ("快照：收尾复位", 0, s2a_far_session_reset()); }
    printf("%s t_far：%d / %d 项通过\n", bad ? "✗" : "✓", cnt - bad, cnt);
    return bad != 0;
}
