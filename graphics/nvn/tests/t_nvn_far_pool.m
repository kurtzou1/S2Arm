// 远端别名区里的内存池影子不连续（nvn_mtl.m pool_host，#450：一款第一方 RPG 在 iPhone 上首帧前中止，61 MB 的池影子在 2 MiB 边界处断开）。
// 影子按 2 MiB 一块、按游戏映射的先后分（runtime/src/far.c），跨多次映射拼起来的池，相邻游戏块不一定落在相邻影子块。原先遇到就 FATAL 退出。
// 用生产 runtime/src/far.c（S2A_FAR_LINEAR=0：同 iOS 按 2 MiB 分块；Mac 有 #419 线性影子不会遇到）：按游戏地址递增先映射 [G, G+2M)、再映射 [G+2M, G+4M)（影子从堆区顶往下切：后一次落在前一次下面），两块影子倒过来不相邻；
//   [H, H+4M) 一次映射，影子连续。期望（按语义手写，不由被测实现推出）：
//   ① 跨两次映射的池建得出（进程不退出），池的宿主地址既不是 G 也不是 G+2M 的影子（一段新的连续视图）
//   ② 视图与影子是同一份内存：往两块影子写的字节从视图对应偏移读得到；从视图写的字节在影子里看得到
//   ③ GPU 读的也是同一份：经池的缓冲把第 2 块开头 16 字节拷出来，读到的是写进第 2 块影子的字节
//   ④ 一次映射的池照旧直接用影子（宿主地址 = H 的影子），不另建视图
//   ⑤ GPU 写记账（gpw_add，块线性渲染目标被画时）对远端池的客人地址取指纹不碰客人地址（P1-160：客人地址没有映射，原先直接读它；单测里没有远端缺页代执行，读了就崩）：
//      记下的指纹 = 按语义从影子字节算的同一个 512 字节指纹
//   ⑥ 过期判定（gpw_stale，#357 无人引用扫描与贴图上传前都走它）同样读影子：没改的那块仍算 GPU 写的（1 段 512 字节）；经影子改了 1 字节的那块判为已改写（不再算）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MB2 = 2 << 20 };
static const uint64_t G = 0x8000000000ull, H = 0x8001000000ull;
void s2a_far_set(uint64_t lo, uint64_t hi, uint64_t sh_lo, uint64_t sh_hi); int s2a_far_map(uint64_t a, uint64_t n);   // runtime/src/far.c
static uintptr_t host_of(uint64_t g) { pthread_mutex_lock(&g_mu); uintptr_t h = 0; for (int i = 0; i < g_npool; i++) if (g_pools[i].lo == g) h = g_pools[i].host; pthread_mutex_unlock(&g_mu); return h; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    setenv("S2A_FAR_LINEAR", "0", 1);
    void *sh = mmap(NULL, 64u << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(sh != MAP_FAILED);
    uint64_t shl = ((uint64_t)(uintptr_t)sh + MB2 - 1) & ~(uint64_t)(MB2 - 1);
    s2a_far_set(G, G + (32u << 20), shl, shl + (48u << 20));
    REQUIRE(!s2a_far_map(G, MB2) && !s2a_far_map(G + MB2, MB2) && !s2a_far_map(H, 2 * MB2));
    uint8_t *A = s2a_far_g2h(G), *B = s2a_far_g2h(G + MB2), *C = s2a_far_g2h(H);
    printf("影子 A %p B %p C %p C2 %p\n", A, B, C, s2a_far_g2h(H + MB2));
    REQUIRE(A && B && C && B != A + MB2 && s2a_far_g2h(H + MB2) == C + MB2);   // 前提：两次映射的影子不相邻、一次映射的相邻
    nvn_be_pool_add((const void *)(uintptr_t)G, 2 * MB2);
    uint8_t *v = (uint8_t *)host_of(G);
    CHECK(v && v != A && v != B, "① 影子断开的池建得出，宿主地址是一段新的视图（%p；A %p、B %p）", v, A, B);
    A[100] = 0x11; B[200] = 0x22;
    int same = v && v[100] == 0x11 && v[MB2 + 200] == 0x22;
    if (v) { v[300] = 0x33; v[MB2 + 400] = 0x44; }
    CHECK(same && A[300] == 0x33 && B[400] == 0x44, "② 视图与影子是同一份内存（双向读写都看得到）");
    for (int i = 0; i < 16; i++) B[i] = (uint8_t)(0xa0 + i);
    id<MTLBuffer> src = nil; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) if (g_pools[i].lo == G) src = g_pools[i].buf; pthread_mutex_unlock(&g_mu);
    id<MTLBuffer> dst = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(dst.contents, 0, 16);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:src sourceOffset:MB2 toBuffer:dst destinationOffset:0 size:16]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int gpu_ok = 1; for (int i = 0; i < 16; i++) gpu_ok &= ((uint8_t *)dst.contents)[i] == (uint8_t)(0xa0 + i);
    CHECK(src && gpu_ok, "③ GPU 经池的缓冲读第 2 块开头，读到写进 B 的字节");
    nvn_be_pool_add((const void *)(uintptr_t)H, 2 * MB2);
    CHECK(host_of(H) == (uintptr_t)C, "④ 影子连续的池照旧直接用影子（%#lx）", (unsigned long)host_of(H));
    {   // ⑤ ⑥：池 [G, G+4M) 里第 2 块开头附近两个 GOB（512 字节一块）
        uint64_t g0 = (G + MB2 + 4096) >> 9; const uint8_t *s0 = B + 4096;
        for (int i = 0; i < 1024; i++) B[4096 + i] = (uint8_t)(i * 7 + 3);
        pthread_mutex_lock(&g_gpw_mu); gpw_add((void *)(uintptr_t)(G + MB2 + 4096), 0, 1024); pthread_mutex_unlock(&g_gpw_mu);
        uint64_t k = g0 >> 9; gpw_blk *bk = nvn_hm_get(&g_gpw, &k); unsigned i0 = (unsigned)(g0 & 511), i1 = (unsigned)((g0 + 1) & 511);
        CHECK(bk && bk->h[i0] == span_hash(s0, 512) && bk->h[i1] == span_hash(s0 + 512, 512), "⑤ 远端池的 GPU 写记账按影子取指纹（两块都对上）");
        B[4096 + 512 + 9] ^= 0xff;   // 只改第二块
        uint64_t *runs = NULL, bytes = 0; int n = gpw_stale((const uint8_t *)(uintptr_t)(G + MB2 + 4096), 1024, &runs, &bytes);
        CHECK(n == 1 && runs && runs[0] == 0 && runs[1] == 512 && bytes == 512, "⑥ 过期判定读影子：没改的块仍算 GPU 写的、改过的块不算（%d 段 %llu 字节）", n, (unsigned long long)bytes);
        free(runs);
    }
    {   // ⑦ 页 / GOB 指纹哈希（span_hash：打包贴图每个写过的 16 KB 页上传时取一次、检查时再取一次；gob_hash 每个 GPU 写记账的 512 B GOB 一次）改动必检得出来的性质，
        //      不依赖具体哈希值（换哈希实现只要性质保持就过）：同一输入两次取值相同；任一字节翻转（主循环整词、不足 32 字节的余词、< 8 字节的尾段全覆盖，
        //      逐个位置各判一次——实现漏看任何一个字节，对应位置当场红，每个位置自证、不需要另设负对照）；同前缀长度少一字节指纹必变；
        //      n 覆盖 GOB 整块、整页、整页少 5 字节（主循环 + 余词 + 尾段）、512+13（主循环 + 1 余词 + 5 尾字节）、40（1 圈主循环 + 1 余词、无尾）、29（不足 32 字节整段余词 + 尾）
        static const size_t ns[] = {512, 512 + 13, 29, 40, 16384, 16384 - 5};
        static uint8_t buf[16384];
        for (size_t i = 0; i < sizeof buf; i++) buf[i] = (uint8_t)(i * 131 + 7);
        for (size_t j = 0; j < sizeof ns / sizeof *ns; j++) { size_t n = ns[j];
            uint64_t h0 = span_hash(buf, n);
            int det = h0 == span_hash(buf, n), len_ok = h0 != span_hash(buf, n - 1), ok = det && len_ok;
            for (size_t bi = 0; bi < n && ok; bi++) { buf[bi] ^= 0x80; ok = span_hash(buf, n) != h0; buf[bi] ^= 0x80; }
            CHECK(ok, "⑦ 指纹哈希 n=%zu：同一输入稳定、逐字节翻转必变、长度少一字节必变（%d）", n, ok);
        }
    }
    printf("%s t_nvn_far_pool: %u checks %u failures; backend %s\n", failures ? "✗" : "✓", checks, failures, g_m3 ? "Metal3" : "Metal4");
    return failures != 0;
} }
