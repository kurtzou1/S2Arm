// 顶点 / 片元配对核对（pso_pair_ok）：直接包含生产 nvn_mtl.m 调 pso_get_，着色器是现编的真 Metal 函数。期望值按规则手写：
//   片元读 locn1、顶点只写 locn0 → 不交给 Metal（建管线计数不变）、返回空、pso_user.tsv 记一行 P；匹配的一对照常建成；
//   反证：同一对不匹配、但两边位置未知（改前代码 / 没有 user_locs 的库走的路）→ 交给了 Metal（计数加 1）；iOS 上这一步是 Metal 断言崩溃（巫师3 10-26），Mac 上不一定报错
// 首遇现建读数（graphics/nvn/fe_stat.h，10-29 删直连链接版后）：
//   纯计算按手算值核两行固定格式（MARK 前 / 后、转后台前 / 中 / 后各一笔，耗时取整到 0.1 ms 不碰 .x5）；
//   真路径：MARK 前建的两条不进 MARK 口径（0 条），宿主 s2a_ap_log 打「S2A 标记 MARK」后再建一对 → MARK 口径 1 条，与建管线计数增量相同
#include "../gfx/nvn/nvn_mtl.m"
void s2a_ap_log(const char *fmt, ...);   // runtime/src/ap_host.c（本单测链宿主对象）

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
"vertex VO v0(uint i [[vertex_id]]) { VO o; o.p = float4(float(i & 1), float(i >> 1), 0, 1); o.a = float4(1); return o; }\n"
"struct F1 { float4 b [[user(locn1)]]; };\n"
"fragment float4 f1(F1 i [[stage_in]]) { return i.b; }\n"
"struct F0 { float4 a [[user(locn0)]]; };\n"
"fragment float4 f0(F0 i [[stage_in]]) { return i.a; }\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *fn, const char *key, int stage, int known, uint32_t locs) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:fn]; REQUIRE(s->fn); strlcpy(s->key, key, sizeof s->key);
    if (known) { s->rf.has_user = stage == 0 ? 1 : 2; if (stage == 0) s->rf.user_out = locs; else s->rf.user_in = locs; }
    return s;
}
static int p_rows(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return 0; char l[256]; int n = 0;
    while (fgets(l, sizeof l, f)) n += !strncmp(l, "P\taaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbb\n", 36);
    fclose(f); return n;
}

int main(void) {
    @autoreleasepool {
        setenv("DM_NVN_FIRST_SKIP", "0", 1);   // 测的是等管线这条路径，不走首遇跳过
        // 等管线不限时：单条上限（DM_NVN_PSO_WAIT_MS，缺省 2 秒）、每帧预算（DM_NVN_PSO_FRAME_MS，缺省 100 ms）、不可跳过绘制上限（DM_NVN_PSO_UNSAFE_WAIT_MS）
        //   都是墙钟：负载高时现编一条 Metal 管线超过 100 ms，pso_get_ 先回空、这一笔跳过，「匹配的一对照常建成」「MARK 后再建一对」两项假红（11-21 门禁负载 70 / 18 核）。
        //   本测核的是配对核对与计数口径，与编译快慢无关
        setenv("DM_NVN_PSO_WAIT_MS", "0", 1); setenv("DM_NVN_PSO_FRAME_MS", "0", 1); setenv("DM_NVN_PSO_UNSAFE_WAIT_MS", "0", 1);
        char user[] = "/tmp/t_pairguard_XXXXXX"; int fd = mkstemp(user); REQUIRE(fd >= 0); close(fd); setenv("DM_PSO_USER", user, 1);
        char map[] = "/tmp/t_pairguard_map_XXXXXX"; fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); setenv("DM_NVN_SHMAP", map, 1);
        mtl_init();
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e]; REQUIRE(lib);
        NvShader *vs = shader(lib, @"v0", "aaaaaaaaaaaaaaaa_b", 0, 1, 1u << 0);
        NvShader *bad = shader(lib, @"f1", "bbbbbbbbbbbbbbbb_b", 1, 1, 1u << 1);
        NvShader *good = shader(lib, @"f0", "cccccccccccccccc_b", 1, 1, 1u << 0);
        NvShader *bad_unknown = shader(lib, @"f1", "dddddddddddddddd_b", 1, 0, 0);
        memset(&g_pass, 0, sizeof g_pass); g_pass.cfmt[0] = (uint32_t)MTLPixelFormatRGBA8Unorm; g_pass.samples = 1;
        NvProg *pr = [NvProg new]; pr->sh[0] = vs;

        uint64_t n0 = g_bp_pso_n;
        pr->sh[1] = bad; id ps = pso_get_(pr, nil);
        VERIFY(!ps && g_bp_pso_n == n0, "片元读 locn1、顶点只写 locn0：不交给 Metal（建管线计数 %llu → %llu），返回空", (unsigned long long)n0, (unsigned long long)g_bp_pso_n);
        VERIFY(p_rows(user) == 1, "pso_user.tsv 记了一行 P<TAB>顶点键<TAB>片元键（%d 行）", p_rows(user));
        ps = pso_get_(pr, nil);
        VERIFY(!ps && g_bp_pso_n == n0 && p_rows(user) == 1, "同一对再来一次：仍不建、P 行不重复");

        pr->sh[1] = good; ps = pso_get_(pr, nil);
        VERIFY(ps && g_bp_pso_n == n0 + 1, "匹配的一对（都在 locn0）：照常建成（计数 +1）");

        pr->sh[1] = bad_unknown; ps = pso_get_(pr, nil);
        // Metal 对「片元读的位置顶点没写」不总报错（这一对 Mac 上建成了；巫师3 那几对报 not written by vertex shader），判据只看交没交给它
        VERIFY(g_bp_pso_n == n0 + 2, "反证：同样不匹配但片元位置未知（改前代码的路）→ 交给了 Metal 建（计数 %llu，期望 %llu）；iOS 上巫师3 就崩在这一步",
               (unsigned long long)g_bp_pso_n, (unsigned long long)(n0 + 2));

        // 首遇现建读数：真路径（上面两次交给 Metal 建都在 MARK 前）
        VERIFY(g_fe.mark.n == 0 && s2a_ap_marked() == 0, "MARK 前建的 %llu 条不进 MARK 口径（实 %llu 条）", (unsigned long long)(g_bp_pso_n - n0), (unsigned long long)g_fe.mark.n);
        s2a_ap_log("S2A 标记 MARK：帧 %d", 100);
        NvShader *after = shader(lib, @"f0", "eeeeeeeeeeeeeeee_b", 1, 1, 1u << 0); uint64_t n1 = g_bp_pso_n;
        pr->sh[1] = after; ps = pso_get_(pr, nil);
        char ln[256]; fe_line_mark(ln, sizeof ln, &g_fe);
        VERIFY(ps && s2a_ap_marked() == 1 && g_fe.mark.n == 1 && g_bp_pso_n - n1 == 1 && !strncmp(ln, "首遇现建：MARK 后提交线程现建管线 1 条，最长 ", strlen("首遇现建：MARK 后提交线程现建管线 1 条，最长 ")),
               "MARK 后再建一对：MARK 口径 1 条（建管线计数 +%llu），行「%s」", (unsigned long long)(g_bp_pso_n - n1), ln);
        fe_line_bg(ln, sizeof ln, &g_fe, bp_now());
        VERIFY(!strcmp(ln, "预热转后台：0 条，后台编完用时 0.0 ms，期间提交线程现建 0 条（最长 0.0 ms）"), "没撞预热上限：转后台行照打、全 0（「%s」）", ln);

        // 首遇现建读数：纯计算，手算期望
        fe_stat f = {0}; char a[256], b[256];
        fe_note(&f, 1500000, 0);                       // MARK 前、没转后台：两个口径都不计
        fe_bg_begin(&f, 120, 1000000000ull);           // 首帧撞上限，120 行转后台
        fe_note(&f, 2000000, 1);                       // MARK 后、后台在编：两边都计
        fe_note(&f, 4300000, 0);                       // MARK 前、后台在编：只计后台期间
        fe_line_bg(b, sizeof b, &f, 1700000000ull);    // 后台还在编：用时到打印时刻 = 700 ms
        VERIFY(!strcmp(b, "预热转后台：120 条，后台编完用时 700.0 ms，期间提交线程现建 2 条（最长 4.3 ms）"), "后台在编时的转后台行「%s」", b);
        fe_bg_end(&f, 3500000000ull);                  // 后台编完：用时 2500 ms
        fe_note(&f, 9000000, 1);                       // 编完以后：只计 MARK 口径
        fe_line_mark(a, sizeof a, &f); fe_line_bg(b, sizeof b, &f, 9000000000ull);
        VERIFY(!strcmp(a, "首遇现建：MARK 后提交线程现建管线 2 条，最长 9.0 ms，合计 11.0 ms"), "MARK 口径：2 条（2.0 + 9.0）、最长 9.0、合计 11.0（「%s」）", a);
        VERIFY(!strcmp(b, "预热转后台：120 条，后台编完用时 2500.0 ms，期间提交线程现建 2 条（最长 4.3 ms）"), "转后台：120 条、2500.0 ms、期间 2 条最长 4.3（编完后那笔不计；「%s」）", b);

        unlink(user); unlink(map);
    }
    if (failures) { printf("✗ t_nvn_pairguard：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_pairguard：%u 项全过（不匹配的顶点 / 片元对不交给 Metal、记 P 行；匹配的照建；位置未知的反证走到 Metal；首遇现建读数两行）\n", checks); return 0;
}
