// 命令列表嵌套调用不吃宿主栈（nvn_mtl.m nvn_be_exec 的显式返回栈）：直接包含生产 nvn_mtl.m，在真 Metal 队列上回放手写的记录流，
//   整个提交跑在一条只有 256 KB 栈的线程上（游戏线程宿主栈是 1 MB；11-12 旷野之息 Mac 嵌套 24 层以上时递归版吃满栈 SIGBUS）。
//   期望按 NVN 语义手写：① 200 层 CALL 链，最里层把 W 填 0x33，最外层 CALL 之后把 W 拷到 V → V = 0x33（每层返回后接着跑调用方 CALL 之后）
//   ② 列表调用自己（命令内存被改写成调回自己）：在深度上限处跳过这次调用、不死循环，外层 CALL 之后的「Q 填 0x66」照常执行
//   负对照（11-13）：换回递归版 nvn_be_exec，② 在 256 KB 栈上 SIGBUS（退出码 138，同旷野之息现场）；① 递归版也能过（这条路径每层帧小），① 只证明返回顺序对
#include "../gfx/nvn/nvn_mtl.m"
#include <pthread.h>
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
typedef struct { uint8_t b[128]; size_t n; } stream;
static void put(stream *s, uint32_t op, const void *pl, uint32_t n) { op_hdr h = {op, 8 + n}; REQUIRE(s->n + h.size + 8 <= sizeof s->b); memcpy(s->b + s->n, &h, 8); if (n) memcpy(s->b + s->n + 8, pl, n); s->n += h.size; }
static void fill(stream *s, uint8_t *dst, uint64_t n, uint32_t v) { p_clear_buf c = {(uint64_t)(uintptr_t)dst, n, v, 0}; put(s, OP_CLEAR_BUF, &c, sizeof c); }
static void copy(stream *s, const uint8_t *src, uint8_t *dst, uint64_t n) { uint64_t p[3] = {(uint64_t)(uintptr_t)src, (uint64_t)(uintptr_t)dst, n}; put(s, OP_COPY_B2B, p, 24); }
static void call(stream *s, const stream *t) { uint64_t p = (uint64_t)(uintptr_t)t->b; put(s, OP_CALL, &p, 8); }
static void end(stream *s) { put(s, OP_END, NULL, 0); }
#define DEPTH 200   // 上限 CALL_DEPTH_MAX 256 以内
static stream g_chain[DEPTH], g_top, g_loop, g_top2;
static uint8_t *W, *V, *P, *Q;
static void *run(void *arg) { (void)arg; @autoreleasepool {
    static queue_t QA; uint64_t frame = 1;
    // ① 200 层：chain[i] 调 chain[i+1]，最里层填 W
    for (int i = 0; i < DEPTH; i++) { g_chain[i].n = 0; if (i + 1 < DEPTH) call(&g_chain[i], &g_chain[i + 1]); else fill(&g_chain[i], W, 4096, 0x33333333u); end(&g_chain[i]); }
    g_top.n = 0; call(&g_top, &g_chain[0]); copy(&g_top, W, V, 4096); end(&g_top);
    uint64_t h = (uint64_t)(uintptr_t)g_top.b; nvn_be_set_frame(++frame); nvn_be_submit(&QA, &h, 1);
    VERIFY(nvn_be_wait(nvn_be_last_fence(), 5000000000ull), "① 200 层嵌套调用在 256 KB 栈上回放完成（提交完成）");
    // ② 自己调自己：loop = 「P 填 0x55 → 调 loop → 结束」；top2 = 「调 loop → Q 填 0x66 → 结束」
    g_loop.n = 0; fill(&g_loop, P, 4096, 0x55555555u); call(&g_loop, &g_loop); end(&g_loop);
    g_top2.n = 0; call(&g_top2, &g_loop); fill(&g_top2, Q, 4096, 0x66666666u); end(&g_top2);
    h = (uint64_t)(uintptr_t)g_top2.b; nvn_be_set_frame(++frame); nvn_be_submit(&QA, &h, 1);
    VERIFY(nvn_be_wait(nvn_be_last_fence(), 5000000000ull), "② 成环的调用在深度上限处停下，提交完成（不死循环）");
    return NULL; } }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init(); state_reset();
    uint8_t *pool = NULL; REQUIRE(!posix_memalign((void **)&pool, 65536, 1 << 20)); memset(pool, 0, 1 << 20); nvn_be_pool_add(pool, 1 << 20);
    W = pool; V = pool + 4096; P = pool + 8192; Q = pool + 12288; memset(V, 0x11, 4096); memset(Q, 0x11, 4096);
    pthread_attr_t a; pthread_attr_init(&a); REQUIRE(!pthread_attr_setstacksize(&a, 256 << 10));
    pthread_t t; REQUIRE(!pthread_create(&t, &a, run, NULL)); pthread_join(t, NULL);
    int v_ok = 1, q_ok = 1; for (int i = 0; i < 4096; i++) { v_ok &= V[i] == 0x33; q_ok &= Q[i] == 0x66; }
    VERIFY(v_ok, "① 最里层的填写经 200 层返回后被最外层 CALL 之后的拷贝读到：V = 0x33");
    VERIFY(P[0] == 0x55, "② 成环列表本身的命令执行了：P = 0x55");
    VERIFY(q_ok, "② 成环调用被跳过后，外层 CALL 之后的命令照常执行：Q = 0x66");
    printf("%s t_nvn_call_depth：%u 项，不符 %u\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
} }
