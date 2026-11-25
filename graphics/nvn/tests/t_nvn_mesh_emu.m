// 宿主自跑任务 / 网格阶段（nvn_geometry.inc）的三处 GPU 改写：直接包含生产 nvn_mtl.m，在真 GPU 上跑生产的核 / 改写后的核，和 CPU 参考逐字比。每项带反证（改坏一处，本测要能看出来）。
//   ① mxe_scan（两级 SIMD 前缀和）：n = 0 / 1 / 255 / 256 / 257 / 4097、间接计数、网格组到 h[4] 上限截断；整个交换缓冲和 CPU 串行参考逐字相同（没写的字保持填充值）。
//      反证：把「本线程起点 = 组前缀 + SIMD 内前缀」改成只取组前缀，n = 257 必须对不上。
//   ② 剔除判据 dm_cull_keep（k_mxc_keep_msl，GPU 跑生产这段源码）：每条手写期望，另由 CPU 复刻（枚举像素中心，不用 floor / ceil 公式）对照。
//      覆盖：同一裁剪面外（四面）、都在眼后、跨面、顶点号重复、共线不同顶点号、子像素无中心、像素中心正压在包围盒边上（正坐标 / 负坐标两侧）、
//      1/256 像素余量内外、开关位关掉。反证：去掉余量的那份判据，余量内那条必须判错。
//   ③ mxc_patch：夹具 t_nvn_mesh_emu.metal（网格 834e5852915bdd02 的翻译原样输出，只换阶段函数体）改写两个入口、编得过；同一组输入跑原版与改写版
//      main0_mc：留下的三角形索引原样、被剔的三个索引都等于它第一个角、整组剔光的组不写顶点也不占索引；开关位清 0 时与原版逐字相同。
//      逐图元输出 / 写视口号 / 写层号 / 读图元号的源码不改写。
//   ④ mxd_patch：改写后编得过，同一组输入下 main0_md 与 main0_mc 的顶点记录、索引逐字相同。反证：阶段内存片区压到顶点区上，必须对不上。
//   ⑤ 网格连段入段条件：宿主阶段读贴图 / 图像 / 纹素缓冲 / 原始内存池表的不入段，只读常量 / 存储缓冲的入段。
//   ⑥ mxd_fits：设备内存那份每组多占一片阶段内存，交换缓冲上限内放得下的组数比线程组那份少时改回 main0_mc。反证：照旧换的话一笔少画的组数。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static id<MTLLibrary> build(NSString *src, int emu) {
    MTLCompileOptions *co = dm_msl_opts(); if (emu) co.preprocessorMacros = @{@"S2A_MESH_EMU": @1};
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:src options:co error:&e];
    if (!l) fprintf(stderr, "build: %s\n", e.localizedDescription.UTF8String);
    return l;
}
static id<MTLComputePipelineState> pso(id<MTLLibrary> l, NSString *name) {
    id<MTLFunction> f = [l newFunctionWithName:name]; if (!f) return nil;
    NSError *e = nil; id<MTLComputePipelineState> p = [g_dev newComputePipelineStateWithFunction:f error:&e];
    if (!p) fprintf(stderr, "pso %s: %s\n", name.UTF8String, e.localizedDescription.UTF8String);
    return p;
}
// 跑一次：bufs[i] 绑到 idx[i]
static void run(id<MTLComputePipelineState> p, int n, const int *idx, __strong id<MTLBuffer> *bufs, MTLSize groups, MTLSize threads) {
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:p]; for (int i = 0; i < n; i++) [ce setBuffer:bufs[i] offset:0 atIndex:(NSUInteger)idx[i]];
    [ce dispatchThreadgroups:groups threadsPerThreadgroup:threads]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
}
static id<MTLBuffer> shared(size_t bytes) { id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; REQUIRE(b); return b; }

// ---------- ① ----------
enum { HEAD = 32, FILLW = 0xa5a5a5a5u };
static void scan_ref(uint32_t *h, const uint32_t *ind) {   // 约定：任务按序展开成 (任务号 << 10) | 组内序号，前 h[4] 个写进表；头字照生产约定
    uint32_t want = h[6] ? h[6] : ind[0], n = want < h[3] ? want : h[3], acc = 0, o = 0;
    for (uint32_t t = 0; t < n; t++) { uint32_t c = h[h[0] + t]; acc += c; for (uint32_t j = 0; j < c; j++, o++) if (o < h[4]) h[h[2] + o] = (t << 10) | j; }
    h[8] = acc < h[4] ? acc : h[4]; h[9] = 1; h[10] = 1; h[13] = 0; h[14] = 1; h[15] = 0; h[16] = 0; h[17] = 0; h[18] = acc; h[19] = want;
}
// 一种情形：n 个任务（计数 0..40 的伪随机），cap = 网格组上限（0 = 不限），ind = 走间接计数
static int scan_case(id<MTLComputePipelineState> sp, uint32_t n, uint32_t cap, int ind, uint32_t seed) {
    uint32_t capT = n + 3, sum = 0, rs = seed;
    uint32_t cnt[5000]; for (uint32_t t = 0; t < capT; t++) { rs = rs * 1664525u + 1013904223u; cnt[t] = (rs >> 16) % 41; if (t < n) sum += cnt[t]; }
    uint32_t capM = cap ? cap : sum + 7, words = HEAD + capT + capM + 16;
    id<MTLBuffer> hb = shared(words * 4), ib = shared(16);
    uint32_t *h = hb.contents; for (uint32_t i = 0; i < words; i++) h[i] = FILLW;
    h[0] = HEAD; h[2] = HEAD + capT; h[3] = capT; h[4] = capM; h[6] = ind ? 0 : n;
    for (uint32_t t = 0; t < capT; t++) h[HEAD + t] = cnt[t];
    ((uint32_t *)ib.contents)[0] = ind ? n : 0;
    uint32_t *want = malloc(words * 4); memcpy(want, h, words * 4); scan_ref(want, ib.contents);
    NSUInteger nt = MIN((NSUInteger)256, sp.maxTotalThreadsPerThreadgroup) / 32 * 32;   // 同生产 mtk_emu_flush
    int idx[2] = {0, 1}; __strong id<MTLBuffer> bufs[2] = {hb, ib};
    run(sp, 2, idx, bufs, MTLSizeMake(1, 1, 1), MTLSizeMake(nt, 1, 1));
    int bad = 0; for (uint32_t i = 0; i < words; i++) bad += h[i] != want[i];
    free(want); return bad;
}

// ---------- ② ----------
typedef struct { float p[3][4]; uint32_t ix[3]; uint32_t cf; float cv[4]; int want; const char *what; } cull_case;
static int cull_cpu(const cull_case *k) {   // 复刻：按定义逐条判；子像素那条枚举像素中心 k + 0.5，看有没有落进放宽 1/256 的包围盒（不用 floor / ceil 公式）
    if (!(k->cf & 1)) return 1;
    if (k->ix[0] == k->ix[1] || k->ix[1] == k->ix[2] || k->ix[0] == k->ix[2]) return 0;
    int allw = 1, out[4] = {1, 1, 1, 1};
    for (int v = 0; v < 3; v++) { const float *q = k->p[v]; allw &= q[3] <= 0; out[0] &= q[0] < -q[3]; out[1] &= q[0] > q[3]; out[2] &= q[1] < -q[3]; out[3] &= q[1] > q[3]; }
    if (allw || out[0] || out[1] || out[2] || out[3]) return 0;
    if ((k->cf & 2) && k->p[0][3] > 0 && k->p[1][3] > 0 && k->p[2][3] > 0) {
        for (int ax = 0; ax < 2; ax++) {
            double hs = k->cv[2 + ax] * 0.5, lo = 1e30, hi = -1e30;
            for (int v = 0; v < 3; v++) { double s = k->cv[ax] + hs + (double)k->p[v][ax] / k->p[v][3] * hs; if (s < lo) lo = s; if (s > hi) hi = s; }
            lo -= 1.0 / 256; hi += 1.0 / 256; int any = 0;
            for (long c = (long)lo - 3; c <= (long)hi + 3; c++) any |= c + 0.5 >= lo && c + 0.5 <= hi;
            if (!any) return 0;
        }
    }
    return 1;
}
#define SC(x) (((x) - 32.0f) / 32.0f)   // 视口 (0, 0, 64, 64)、w = 1 下屏幕坐标 x 的裁剪坐标
#define SN(x) (((x) + 8.0f) / 32.0f)    // 视口 (-40, -40, 64, 64)：屏幕 = -8 + 32 × 裁剪
#define T3(ax, ay, bx, by, cx, cy, f) {{f(ax), f(ay), 0.5f, 1}, {f(bx), f(by), 0.5f, 1}, {f(cx), f(cy), 0.5f, 1}}
static const cull_case k_cases[] = {
    {T3(8, 8, 56, 8, 8, 56, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "大三角形"},
    {{{-1.5f, 0, 0.5f, 1}, {-1.2f, 0.5f, 0.5f, 1}, {-1.1f, -0.5f, 0.5f, 1}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "都在左面外"},
    {{{1.5f, 0, 0.5f, 1}, {1.2f, 0.5f, 0.5f, 1}, {1.1f, -0.5f, 0.5f, 1}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "都在右面外"},
    {{{0, -1.5f, 0.5f, 1}, {0.5f, -1.2f, 0.5f, 1}, {-0.5f, -1.1f, 0.5f, 1}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "都在下面外"},
    {{{0, 1.5f, 0.5f, 1}, {0.5f, 1.2f, 0.5f, 1}, {-0.5f, 1.1f, 0.5f, 1}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "都在上面外"},
    {{{0, 0, 0.5f, -1}, {0.5f, 0, 0.5f, -0.5f}, {0, 0.5f, 0.5f, 0}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "都在眼后（w ≤ 0）"},
    {{{-1.5f, 0, 0.5f, 1}, {0.5f, 0.5f, 0.5f, 1}, {-1.1f, -0.5f, 0.5f, 1}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "一个角在里面（跨左面）"},
    {{{-1.5f, 1.5f, 0.5f, 1}, {1.5f, 1.2f, 0.5f, 1}, {0, -1.5f, 0.5f, 1}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "三个角分在不同面外（包住视口）"},
    {T3(8, 8, 56, 8, 8, 56, SC), {0, 0, 2}, 3, {0, 0, 64, 64}, 0, "顶点号重复（零面积）"},
    {T3(2, 2.5f, 10, 2.5f, 20, 2.5f, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "共线、顶点号不同、压在像素中心行上：不剔（只按顶点号判零面积）"},
    {T3(10.625f, 10.625f, 10.875f, 10.625f, 10.625f, 10.875f, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "子像素、包围盒里没有像素中心"},
    {T3(10.625f, 10.625f, 10.875f, 10.625f, 10.625f, 10.875f, SC), {0, 1, 2}, 1, {0, 0, 64, 64}, 1, "同上、子像素位关：不剔"},
    {T3(10.5f, 20.5f, 10.75f, 20.5f, 10.5f, 20.75f, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "像素中心 (10.5, 20.5) 正压在包围盒左下角"},
    {T3(10.25f, 20.25f, 10.5f, 20.25f, 10.25f, 20.5f, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "像素中心 (10.5, 20.5) 正压在包围盒右上角"},
    {T3(10.501953125f, 20.25f, 10.875f, 20.25f, 10.501953125f, 20.75f, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "x 离像素中心 1/512（余量内）：不剔"},
    {T3(10.5078125f, 20.25f, 10.875f, 20.25f, 10.5078125f, 20.75f, SC), {0, 1, 2}, 3, {0, 0, 64, 64}, 0, "x 离像素中心 1/128（余量外）：剔"},
    {T3(-10.875f, -10.875f, -10.625f, -10.875f, -10.875f, -10.625f, SN), {0, 1, 2}, 3, {-40, -40, 64, 64}, 0, "负坐标子像素、没有像素中心（同正坐标那条对称）"},
    {T3(-10.75f, -10.75f, -10.5f, -10.75f, -10.75f, -10.5f, SN), {0, 1, 2}, 3, {-40, -40, 64, 64}, 1, "负坐标、像素中心 (-10.5, -10.5) 正压在包围盒右上角"},
    {T3(-10.5f, -10.5f, -10.25f, -10.5f, -10.5f, -10.25f, SN), {0, 1, 2}, 3, {-40, -40, 64, 64}, 1, "负坐标、像素中心 (-10.5, -10.5) 正压在包围盒左下角"},
    {{{-1.5f, 0, 0.5f, 1}, {-1.2f, 0.5f, 0.5f, 1}, {-1.1f, -0.5f, 0.5f, 1}}, {0, 1, 2}, 0, {0, 0, 64, 64}, 1, "开关位全关：都在左面外也不剔"},
    {{{-0.5f, -0.5f, 1, 2}, {1, -0.5f, 1, 2}, {-0.5f, 1, 1, 2}}, {0, 1, 2}, 3, {0, 0, 64, 64}, 1, "w = 2 的透视三角形"},
};
#define NCASE ((int)(sizeof k_cases / sizeof *k_cases))
static int cull_gpu(NSString *keep_src, int *got) {   // 用给定的判据源码跑所有情形；回不对的条数（按手写期望）
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@"
        "kernel void t_cull(device const float4* p [[buffer(0)]], device const uint4* ix [[buffer(1)]], device const float4* cv [[buffer(2)]], device uint* out [[buffer(3)]], uint i [[thread_position_in_grid]]) {\n"
        "    out[i] = dm_cull_keep(p[3 * i], p[3 * i + 1], p[3 * i + 2], ix[i].x, ix[i].y, ix[i].z, cv[i], ix[i].w) ? 1u : 0u;\n}\n", keep_src];
    id<MTLLibrary> l = build(src, 0); REQUIRE(l); id<MTLComputePipelineState> p = pso(l, @"t_cull"); REQUIRE(p);
    id<MTLBuffer> pb = shared(NCASE * 48), xb = shared(NCASE * 16), cb = shared(NCASE * 16), ob = shared(NCASE * 4);
    for (int i = 0; i < NCASE; i++) { memcpy((float *)pb.contents + 12 * i, k_cases[i].p, 48); uint32_t x[4] = {k_cases[i].ix[0], k_cases[i].ix[1], k_cases[i].ix[2], k_cases[i].cf};
        memcpy((uint32_t *)xb.contents + 4 * i, x, 16); memcpy((float *)cb.contents + 4 * i, k_cases[i].cv, 16); }
    int idx[4] = {0, 1, 2, 3}; __strong id<MTLBuffer> bufs[4] = {pb, xb, cb, ob};
    run(p, 4, idx, bufs, MTLSizeMake(NCASE, 1, 1), MTLSizeMake(1, 1, 1));
    int bad = 0; for (int i = 0; i < NCASE; i++) { got[i] = (int)((uint32_t *)ob.contents)[i]; bad += got[i] != k_cases[i].want; }
    return bad;
}

// ---------- ③ / ④：夹具网格的一次运行 ----------
enum { MAXV = 96, MAXP = 32, PW = 800, VS = 128, G = 3 };   // 夹具：每组 96 顶点、32 三角形，载荷 800 字，顶点记录 8 个 float4
typedef struct { id<MTLBuffer> x; uint32_t vbo, ibo, sl, words; } xrun;
static float g_pos[G][MAXV][4]; static uint8_t g_idx[G][MAXP][3]; static uint32_t g_np[G];
static int tri_keep(int g, int p) {   // 夹具三角形的 CPU 期望（同 ② 的复刻）
    cull_case k = {.cf = 3, .cv = {0, 0, 64, 64}}; for (int v = 0; v < 3; v++) { memcpy(k.p[v], g_pos[g][g_idx[g][p][v]], 16); k.ix[v] = g_idx[g][p][v]; }
    return cull_cpu(&k);
}
static void geo_make(void) {   // 组 0：② 的前 16 条（正坐标视口的）各占一个三角形，余下是普通三角形；组 1：全在左面外；组 2：全是普通三角形
    int nk = 0; int pick[MAXP]; for (int i = 0; i < NCASE && nk < 16; i++) if (k_cases[i].cv[0] == 0 && k_cases[i].cf == 3) pick[nk++] = i;
    for (int g = 0; g < G; g++) { g_np[g] = MAXP;
        for (int p = 0; p < MAXP; p++) {
            const cull_case *k = g == 0 && p < nk ? &k_cases[pick[p]] : NULL;
            for (int v = 0; v < 3; v++) {
                float *q = g_pos[g][3 * p + v];
                if (k) memcpy(q, k->p[v], 16);
                else if (g == 1) { q[0] = -1.5f - 0.01f * v; q[1] = 0.1f * v; q[2] = 0.5f; q[3] = 1; }
                else { q[0] = SC(4 + p) + (v == 1 ? 0.25f : 0); q[1] = SC(4 + v * 9); q[2] = 0.25f; q[3] = 1; }
                g_idx[g][p][v] = (uint8_t)(3 * p + v);
            }
            if (k && k->ix[1] == k->ix[0]) g_idx[g][p][1] = g_idx[g][p][0];
        } }
}
static xrun xrun_new(uint32_t sw, uint32_t cf) {
    uint32_t capT = G, capM = G, tab = HEAD + capT + capT * PW, vbo = (tab + capM + 3) & ~3u, ibo = vbo + capM * MAXV * (VS / 4), sl = (ibo + capM * MAXP * 3 + 3) & ~3u, words = sl + capM * sw + 64;
    xrun r = {shared(words * 4), vbo, ibo, sl, words}; uint32_t *h = r.x.contents;
    for (uint32_t i = 0; i < words; i++) h[i] = FILLW;
    memset(h, 0, HEAD * 4); h[0] = HEAD; h[1] = HEAD + capT; h[2] = tab; h[3] = capT; h[4] = capM; h[5] = PW; h[11] = vbo; h[12] = ibo; h[13] = 0; h[23] = sw ? sl : 0;
    float cv[4] = {0, 0, 64, 64}; memcpy(h + 24, cv, 16); h[28] = cf;
    for (int g = 0; g < G; g++) {
        uint32_t *pl = h + h[1] + g * PW; memset(pl, 0, PW * 4);
        for (int n = 0; n < MAXV; n++) { for (int c = 0; c < 4; c++) memcpy(&pl[1 + n * 5 + c], &g_pos[g][n][c], 4); float a0 = (float)(g * 1000 + n); memcpy(&pl[1 + n * 5 + 4], &a0, 4); }
        memcpy(pl + 481, g_idx[g], sizeof g_idx[g]); pl[505] = g_np[g];
        h[tab + g] = (uint32_t)g << 10;   // 一个任务一个网格组
    }
    return r;
}
static void xrun_go(id<MTLComputePipelineState> p, xrun *r) {
    id<MTLBuffer> d = shared(64), z = shared(64);
    int idx[3] = {0, 25, 28}; __strong id<MTLBuffer> bufs[3] = {d, z, r->x};
    run(p, 3, idx, bufs, MTLSizeMake(G, 1, 1), MTLSizeMake(32, 1, 1));
}
// 索引区按组切开（同组的索引连成一段，组号 = 索引 / MAXV）；seg[g] = 该组那段的起点（-1 = 没有），len[g] = 长度
static void segs(const xrun *r, int *seg, int *len) {
    const uint32_t *h = r->x.contents, *ib = h + r->ibo; for (int g = 0; g < G; g++) { seg[g] = -1; len[g] = 0; }
    for (uint32_t i = 0; i < h[13]; i++) { int g = (int)(ib[i] / MAXV); if (g >= G) continue; if (seg[g] < 0) seg[g] = (int)i; len[g]++; }
}

int main(void) {
    @autoreleasepool {
        setenv("DM_PRESENT_LINK", "0", 1);
        mtl_init();
        const char *fx = getenv("T_MESH_EMU_SRC"); REQUIRE(fx);
        NSString *src = [NSString stringWithContentsOfFile:@(fx) encoding:NSUTF8StringEncoding error:nil]; REQUIRE(src);

        // ①
        { id<MTLComputePipelineState> sp = mxe_scan_pso(); REQUIRE(sp);
          static const uint32_t ns[] = {0, 1, 255, 256, 257, 4097};
          for (size_t i = 0; i < sizeof ns / sizeof *ns; i++) { int bad = scan_case(sp, ns[i], 0, 0, 7 + (uint32_t)i);
              VERIFY(!bad, "① mxe_scan n = %u：整个交换缓冲与 CPU 参考逐字相同（不同 %d 字）", ns[i], bad); }
          int b1 = scan_case(sp, 257, 0, 1, 99); VERIFY(!b1, "① mxe_scan 间接计数 n = 257：逐字相同（不同 %d 字）", b1);
          int b2 = scan_case(sp, 300, 1000, 0, 5); VERIFY(!b2, "① mxe_scan n = 300、网格组到 h[4] = 1000 截断：逐字相同（不同 %d 字）", b2);
          int b3 = scan_case(sp, 4097, 37, 1, 11); VERIFY(!b3, "① mxe_scan 间接 n = 4097、h[4] = 37：逐字相同（不同 %d 字）", b3);
          NSString *k = @(k_mxe_msl); NSString *bad_k = [k stringByReplacingOccurrencesOfString:@"uint o = part[sg] + x;" withString:@"uint o = part[sg];"];
          REQUIRE(![bad_k isEqual:k]);
          id<MTLComputePipelineState> wrong = pso(build(bad_k, 0), @"mxe_scan"); REQUIRE(wrong);
          int rb = scan_case(wrong, 257, 0, 0, 7); VERIFY(rb > 0, "① 反证：起点漏加 SIMD 内前缀的 mxe_scan，n = 257 对不上（不同 %d 字）", rb); }

        // ②
        { int got[NCASE], cpu_bad = 0;
          int bad = cull_gpu(@(k_mxc_keep_msl), got);
          for (int i = 0; i < NCASE; i++) { int c = cull_cpu(&k_cases[i]); cpu_bad += c != k_cases[i].want;
              VERIFY(got[i] == k_cases[i].want && c == k_cases[i].want, "② %s：期望 %s（GPU %s，CPU 复刻 %s）", k_cases[i].what, k_cases[i].want ? "留" : "剔", got[i] ? "留" : "剔", c ? "留" : "剔"); }
          VERIFY(!bad && !cpu_bad, "② 剔除判据 %d 条：GPU 与手写期望不符 %d 条，CPU 复刻不符 %d 条", NCASE, bad, cpu_bad);
          NSString *nomargin = [@(k_mxc_keep_msl) stringByReplacingOccurrencesOfString:@" - 1.0 / 256.0" withString:@""];
          nomargin = [nomargin stringByReplacingOccurrencesOfString:@" + 1.0 / 256.0" withString:@""];
          REQUIRE(![nomargin isEqual:@(k_mxc_keep_msl)]);
          int got2[NCASE]; cull_gpu(nomargin, got2); int mi = -1; for (int i = 0; i < NCASE; i++) if (strstr(k_cases[i].what, "1/512")) mi = i; REQUIRE(mi >= 0);
          VERIFY(got2[mi] == 0, "② 反证：去掉 1/256 余量的判据把「%s」判成剔（实得 %s）", k_cases[mi].what, got2[mi] ? "留" : "剔"); }

        // ③
        geo_make();
        NSString *pat = mxc_patch(src, "834e5852915bdd02_b");
        NSUInteger ncall = [pat componentsSeparatedByString:@"dm_cull_keep("].count - 1;
        VERIFY(![pat isEqual:src] && ncall == 3, "③ mxc_patch 改写夹具：两个宿主入口各调一次判据、判据定义一次（实得 %lu 处）", (unsigned long)ncall);
        for (NSString *x in @[@"dm_prim_t", @"[[viewport_array_index]]", @"[[render_target_array_index]]", @"[[primitive_id]]"]) {
            NSString *s2 = [src stringByAppendingFormat:@"\n// %@\n", x];
            VERIFY(mxc_patch(s2, "834e5852915bdd02_b") == s2, "③ 源码含 %s：不改写", x.UTF8String); }
        id<MTLLibrary> lo = build(src, 1), lp = build(pat, 1);
        VERIFY(lo && lp, "③ 原版 / 改写版夹具都编得过");
        REQUIRE(lo && lp);
        id<MTLComputePipelineState> po = pso(lo, @"main0_mc"), pp = pso(lp, @"main0_mc"), ppz = pso(lp, @"main0_mc_z"); REQUIRE(po && pp && ppz);
        xrun ro = xrun_new(0, 3), rp = xrun_new(0, 3), rz = xrun_new(0, 0);
        xrun_go(po, &ro); xrun_go(pp, &rp); xrun_go(pp, &rz);
        { const uint32_t *ho = ro.x.contents, *hp = rp.x.contents; int so[G], lo_[G], sp[G], lp_[G]; segs(&ro, so, lo_); segs(&rp, sp, lp_);
          int wrong = 0, kept = 0, culled = 0, vdiff = 0; uint32_t want13 = 0;
          for (int g = 0; g < G; g++) {
              int any = 0; for (int p = 0; p < MAXP; p++) any |= tri_keep(g, p);
              if (!any) { VERIFY(sp[g] < 0, "③ 组 %d 三角形全被剔：不占索引（实得 %d 个）", g, lp_[g]);
                  int vt = 0; for (uint32_t w = 0; w < MAXV * VS / 4; w++) vt += hp[rp.vbo + g * MAXV * VS / 4 + w] != FILLW; VERIFY(!vt, "③ 组 %d 全被剔：顶点记录一字没写（写了 %d 字）", g, vt); continue; }
              want13 += MAXP * 3;
              REQUIRE(so[g] >= 0 && sp[g] >= 0 && lo_[g] == MAXP * 3 && lp_[g] == MAXP * 3);
              for (int p = 0; p < MAXP; p++) { int k = tri_keep(g, p); kept += k; culled += !k;
                  for (int v = 0; v < 3; v++) { uint32_t o = ho[ro.ibo + so[g] + 3 * p + v], e = k ? o : ho[ro.ibo + so[g] + 3 * p], got = hp[rp.ibo + sp[g] + 3 * p + v]; wrong += got != e; } }
              vdiff += memcmp(ho + ro.vbo + g * MAXV * VS / 4, hp + rp.vbo + g * MAXV * VS / 4, MAXV * VS) != 0;
          }
          VERIFY(!wrong && kept && culled, "③ 改写版：留下的三角形索引原样、被剔的三个索引等于第一个角（不符 %d 个索引；留 %d、剔 %d）", wrong, kept, culled);
          VERIFY(hp[13] == want13 && !vdiff, "③ 改写版：索引数 %u（期望 %u），有三角形留下的组顶点记录与原版逐字相同（不同 %d 组）", hp[13], want13, vdiff);
          // 开关位清 0（h[28] = 0）：改写版照画所有三角形，索引按组与原版逐字相同、顶点记录相同
          const uint32_t *hz = rz.x.contents; int sz[G], lz[G]; segs(&rz, sz, lz); int zd = hz[13] != ho[13];
          for (int g = 0; g < G && !zd; g++) zd |= sz[g] < 0 || lz[g] != lo_[g] || memcmp(hz + rz.ibo + sz[g], ho + ro.ibo + so[g], (size_t)lz[g] * 4) || memcmp(hz + rz.vbo, ho + ro.vbo, G * MAXV * VS);
          VERIFY(!zd, "③ 改写版、开关位清 0：索引（按组）与顶点记录同原版逐字相同");
          xrun ry = xrun_new(0, 3); xrun_go(ppz, &ry); const uint32_t *hy = ry.x.contents;
          VERIFY(hy[13] == want13, "③ main0_mc_z 改写版同样剔（索引数 %u，期望 %u）", hy[13], want13); }

        // ④
        { NSString *dev = mxd_patch(src, "834e5852915bdd02_b"); REQUIRE(dev);
          uint32_t sw = [g_mxd_sw[@"834e5852915bdd02_b"] unsignedIntValue];
          id<MTLLibrary> ld = build(dev, 1); VERIFY(ld && sw >= 2845, "④ mxd_patch 改写后编得过（一片 %u 字）", sw); REQUIRE(ld);
          id<MTLComputePipelineState> pd = pso(ld, @"main0_md"); REQUIRE(pd);
          xrun rm = xrun_new(0, 0), rd = xrun_new(sw, 0); xrun_go(po, &rm); xrun_go(pd, &rd);
          const uint32_t *hm = rm.x.contents, *hd = rd.x.contents; int s1[G], l1[G], s2[G], l2[G]; segs(&rm, s1, l1); segs(&rd, s2, l2);
          int diff = hm[13] != hd[13] || memcmp(hm + rm.vbo, hd + rd.vbo, G * MAXV * VS);
          for (int g = 0; g < G && !diff; g++) diff |= l1[g] != l2[g] || s1[g] < 0 || s2[g] < 0 || memcmp(hm + rm.ibo + s1[g], hd + rd.ibo + s2[g], (size_t)l1[g] * 4);
          VERIFY(!diff, "④ main0_md 与 main0_mc：顶点记录、索引（按组）逐字相同（索引数 %u / %u）", hm[13], hd[13]);
          xrun rbad = xrun_new(sw, 0); ((uint32_t *)rbad.x.contents)[23] = rbad.vbo + 8; xrun_go(pd, &rbad);   // 反证：片区压到顶点区上
          int bd = memcmp(hm + rm.vbo, (uint32_t *)rbad.x.contents + rbad.vbo, G * MAXV * VS) != 0;
          VERIFY(bd, "④ 反证：阶段内存片区压到顶点区上，顶点记录对不上"); }

        // ⑤
        { NvShader *a = [NvShader new], *b = [NvShader new]; a->rf.b = calloc(2, sizeof(nvn_rbind)); b->rf.b = calloc(2, sizeof(nvn_rbind)); REQUIRE(a->rf.b && b->rf.b);   // 随 NvShader 释放
          a->rf.nb = 2; a->rf.b[0].kind = NVN_RB_CBUF; a->rf.b[1].kind = NVN_RB_SBUFP;
          b->rf.nb = 2; b->rf.b[0].kind = NVN_RB_CBUF; b->rf.b[1].kind = NVN_RB_TEX;
          VERIFY(!mesh_stage_reads_images(a) && mesh_stage_reads_images(b), "⑤ 只读常量 / 存储缓冲的宿主阶段可入段、读贴图的不入段");
          static const int kinds[] = {NVN_RB_TEXU, NVN_RB_IMG, NVN_RB_IMGU, NVN_RB_TBUF, NVN_RB_GMEM}; int all = 1;
          for (size_t i = 0; i < sizeof kinds / sizeof *kinds; i++) { b->rf.b[1].kind = (uint8_t)kinds[i]; all &= mesh_stage_reads_images(b); }
          VERIFY(all, "⑤ 读图像 / 纹素缓冲 / 原始内存池表的同样不入段"); }
        // ⑥
        { const uint64_t B = 32ull << 20, p0 = 10000; const uint32_t dsw = 1504;   // 32 MB 上限，每组 10000 字节，阶段内存一片 1504 字：线程组那份放得下 3355 组，设备内存那份 2095 组
          VERIFY(mxd_fits(100, B, p0, dsw) && mxd_fits(2095, B, p0, dsw), "⑥ 组数在设备内存那份的上限内：用 main0_md");
          VERIFY(!mxd_fits(3000, B, p0, dsw) && !mxd_fits(5000, B, p0, dsw), "⑥ 设备内存那份放不下、线程组那份放得下（或放得多）：改回 main0_mc");
          VERIFY(mxd_fits(5000, B, p0, 0), "⑥ 没有阶段内存片：照用");
          uint64_t lost = MIN(3000ull, B / p0) - MIN(3000ull, B / (p0 + dsw * 4ull));
          VERIFY(lost == 905, "⑥ 反证：照旧换 main0_md，3000 组的一笔只画得出 2095 组（少 %llu 组）", (unsigned long long)lost); }

        if (failures) printf("✗ t_nvn_mesh_emu：%u 项，%u 项不过\n", checks, failures); else printf("✓ t_nvn_mesh_emu：%u 项全过\n", checks);
        return failures ? 1 : 0;
    }
}
