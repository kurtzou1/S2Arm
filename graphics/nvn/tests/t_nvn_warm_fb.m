// 本机现编过的着色器（兜底目录 DM_MSL_FALLBACK 里同链同翻译器指纹的 <键>_b.metal + .json）要进预热和预取，不能当「别的游戏版本」丢掉。
//   11-06 七龙珠 电光炸裂 ZERO 测试设备1：一局里从兜底目录载入的 25 个库全不在包映射表（2105 键）里；预热清单 pso_user.tsv 里用到它们的行被 warm_stale 判过期
//   （「not in the shader map 429」），ProgramSetShaders 时的预取只查包映射表、取不到阶段也不载，于是每局第一次画到都在提交线程现编 MSL。
// 期望（按规则手写，与被测实现无关）：包映射表只有键 K（vertex）；兜底目录有 F（本机指纹）、O（旧翻译器指纹）；Z 哪里都没有
//   ① warm_stale：K_b / F_b 不算过期，O_b（本机旧翻译器译过）也不算（D-NJC8：预热里按单支重译），Z_b 算过期（期望 0 / 0 / 0 / 1）
//   ② warm_parse 一份清单 R(F_b 顶点、无片元) + S F_b 0 + S O_b 0 + S Z_b 0 → 任务 3 个（渲染 1 个、顶点键 F_b；着色器 2 个：F_b、O_b），计入 3 行
//   ③ 预取：F 按 ProgramSetShaders 时 dm_shader_miss 的做法登记进运行时映射（mtl_shmap_rt_add F vertex）后 nvn_be_shader_prefetch(F)
//      → 预取通道真载出 F_b（真 Metal 从 MSL 编库，入口 plain），交接表里有 kind 3 的 F_b、预取计数 +1
//   ④ 边界：G 在兜底目录、但运行时映射没登记（游戏这局没建用它的程序）→ 预取不载（计数不变、交接表没有 G_b）
//   ⑤ 11-06 预热收尾单核（异度3 一对着色器 73 行串行）：同一对着色器 2 行（渲染状态不同）→ 2 个任务、各 1 行（修前按对合成 1 个任务 2 行）
//   ⑥–⑧ D-NJC8（#2158，S2Arm 更新后首局 616 支全在提交线程现编）：兜底目录里旧翻译器指纹的 <键>_b + 补料（shader_miss/<键>.ctl / .code）→ 预热 warm_shader
//      用补料按本机翻译器重译（dsh_miss.inc dm_shader_refresh）再载：⑥ 重译出同样源码 → 载出、json 指纹换成本机的、计「源码没变」1；
//      ⑦ 重译出不同源码 → 载出、计「变了」1；⑧ 没有补料 → 不载、翻译器不被调、计「做不了」1
// 反证（修前）：同一单测编改前的 nvn_mtl.m（-DNVN_WARM_FB_SOURCE=...）→ ① F_b 算过期、② 只剩 0 个任务、③ 交接表没有 F_b
//   （D-NJC8 修前）：① O_b 算过期、⑥ ⑦ 载不出（旧翻译器译过的整批作废）
#ifndef NVN_WARM_FB_SOURCE
#define NVN_WARM_FB_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_WARM_FB_SOURCE

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// 本测扮演链了 S2A.Aot 的 App：兜底目录 json 的翻译器指纹与它相同才算本机现编的（nvn_mtl.m fb_json_current，dlsym 在主程序里找到它）
const char *s2a_dsh_xfp(void) { return "0123456789abcdef"; }
static NSString *fallback;
static NSString *const vertex_source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float value; };\n"
    "float4 pos(uint i) { const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i], 0, 1); }\n"
    "vertex V plain(uint i [[vertex_id]]) { return {pos(i), 0.25}; }\n"
    "vertex V zero(uint i [[vertex_id]]) { return {pos(i), 0.5}; }\n";
static void fixture(NSString *key, NSString *xfp) {
    NSError *e = nil;
    REQUIRE([vertex_source writeToFile:[fallback stringByAppendingPathComponent:[key stringByAppendingString:@".metal"]] atomically:YES encoding:NSUTF8StringEncoding error:&e]);
    NSDictionary *j = @{@"chain": @DMSH_CHAIN, @"xfp": xfp, @"route": @"B", @"stage": @"vs", @"bindings": @[], @"entry": @"plain", @"entry_z": @"zero"};
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil]; REQUIRE(d);
    REQUIRE([d writeToFile:[fallback stringByAppendingPathComponent:[key stringByAppendingString:@".json"]] atomically:YES]);
}
static WarmItem *handed(NSString *key) {
    WarmItem *found = nil;
    os_unfair_lock_lock(&g_warm_lock);
    for (WarmItem *it in g_warm_items) if (it->kind == 3 && [it->key isEqual:key]) { found = it; break; }
    os_unfair_lock_unlock(&g_warm_lock);
    return found;
}
// 本测扮演 S2A.Dsh 现编入口（dsh_miss.inc dlsym s2a_dsh_compile）：把 retrans_src 写成 <键>_b.metal，json 记本机指纹
static NSString *retrans_src; static int retrans_calls;
int s2a_dsh_compile(const char *key, int stage, const void *code, size_t nc, const void *ctl, size_t nt, const char *out) {
    (void)stage; (void)code; (void)nc; (void)ctl; (void)nt; retrans_calls++;
    NSString *k = [@(key) stringByAppendingString:@"_b"], *o = @(out);
    if (![retrans_src writeToFile:[o stringByAppendingPathComponent:[k stringByAppendingString:@".metal"]] atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
    NSDictionary *j = @{@"chain": @DMSH_CHAIN, @"xfp": @"0123456789abcdef", @"route": @"B", @"stage": @"vs", @"bindings": @[], @"entry": @"plain", @"entry_z": @"zero"};
    return [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:[o stringByAppendingPathComponent:[k stringByAppendingString:@".json"]] atomically:YES] ? 0 : 1;
}
// 补料：一支 Switch 1 顶点着色器的控制段（0x710 字节，+0x20 自报长度、+0x704 代码长）+ 代码区（NVN 头魔数、SPH 字 0 阶段 1 = 顶点）
static void salvage(NSString *dir, NSString *key) {
    uint8_t ctl[0x710] = {0}, code[0x80] = {0}; uint32_t nctl = sizeof ctl, ncode = sizeof code, w = (1u << 10) | 1;
    memcpy(ctl + 0x20, &nctl, 4); memcpy(ctl + 0x704, &ncode, 4); memcpy(code, "\x78\x56\x34\x12", 4); memcpy(code + 0x30, &w, 4);
    REQUIRE([[NSData dataWithBytes:ctl length:sizeof ctl] writeToFile:[dir stringByAppendingPathComponent:[key stringByAppendingString:@".ctl"]] atomically:YES]);
    REQUIRE([[NSData dataWithBytes:code length:sizeof code] writeToFile:[dir stringByAppendingPathComponent:[key stringByAppendingString:@".code"]] atomically:YES]);
}
static void key_md(NSString *k, uint8_t md[8]) { for (int i = 0; i < 8; i++) { unsigned v; REQUIRE(sscanf(k.UTF8String + 2 * i, "%2x", &v) == 1); md[i] = (uint8_t)v; } }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    char tmp[] = "/tmp/t_nvn_warm_fb_XXXXXX"; REQUIRE(mkdtemp(tmp)); NSString *root = @(tmp);
    fallback = [root stringByAppendingPathComponent:@"fallback"];
    NSString *miss = [root stringByAppendingPathComponent:@"shader_miss"];
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:miss withIntermediateDirectories:YES attributes:nil error:nil]);
    setenv("S2A_SHADER_SALVAGE", miss.fileSystemRepresentation, 1);
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *K = @"1111111111111111", *F = @"f0f0f0f0f0f0f0f0", *O = @"0e0e0e0e0e0e0e0e", *Z = @"0123456789abcdef", *G = @"9a9a9a9a9a9a9a9a";
    NSString *map = [root stringByAppendingPathComponent:@"shader_map.tsv"];
    NSString *mapline = [NSString stringWithFormat:@"original\t0\tvertex\t%@\n", K];
    REQUIRE([mapline writeToFile:map atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"b-" DMSH_CHAIN] withIntermediateDirectories:YES attributes:nil error:nil]);
    setenv("DM_NVN_SHMAP", map.fileSystemRepresentation, 1); setenv("DM_MSL_DIR", root.fileSystemRepresentation, 1);
    setenv("DM_MSL_FALLBACK", fallback.fileSystemRepresentation, 1); setenv("DM_PSO_MANIFEST", "off", 1);
    setenv("DM_PSO_ARCHIVE", "0", 1); setenv("DM_PSO_USER", [root stringByAppendingPathComponent:@"user.tsv"].fileSystemRepresentation, 1);
    mtl_init(); shmap_load();
    REQUIRE(g_shmap[K] && !g_shmap[F]);
    fixture([F stringByAppendingString:@"_b"], @"0123456789abcdef"); fixture([O stringByAppendingString:@"_b"], @"fedcba9876543210"); fixture([G stringByAppendingString:@"_b"], @"0123456789abcdef");

    NSMutableSet<NSString *> *st = [NSMutableSet set];
    int k = warm_stale([K stringByAppendingString:@"_b"], st), f = warm_stale([F stringByAppendingString:@"_b"], st);
    int o = warm_stale([O stringByAppendingString:@"_b"], st), z = warm_stale([Z stringByAppendingString:@"_b"], st);
    VERIFY(!k && !f && !o && z, "① K_b / F_b / O_b / Z_b 过期判定 得 %d / %d / %d / %d，期望 0 / 0 / 0 / 1", k, f, o, z);

    pso_skey sk; memset(&sk, 0, sizeof sk); snprintf(sk.vs, sizeof sk.vs, "%s_b", F.UTF8String);
    char hx[sizeof sk * 2 + 1]; pso_skey_hex(&sk, hx);
    NSString *list = [NSString stringWithFormat:@"# user\nR\t%s\nS\t%@_b\t0\nS\t%@_b\t0\nS\t%@_b\t0\n", hx, F, O, Z];
    NSString *path = [root stringByAppendingPathComponent:@"pso_user_list.tsv"];
    REQUIRE([list writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    long lines = 0; NSArray<WarmTask *> *tasks = warm_parse(@[path], &lines);
    int nr = 0, ns = 0; NSString *vk = @"";
    for (WarmTask *t in tasks) { if (t->kind == 1) { nr++; vk = t->vkey; } else if (t->kind == 0) ns++; }
    VERIFY(tasks.count == 3 && nr == 1 && ns == 2 && [vk isEqualToString:[F stringByAppendingString:@"_b"]] && lines == 3,
           "② 清单 4 行 → 任务 %lu 个（渲染 %d、着色器 %d，渲染任务顶点键 %s，计入 %ld 行；期望 3 / 1 / 2 / F_b / 3）", (unsigned long)tasks.count, nr, ns, vk.UTF8String, lines);

    { pso_skey s2 = sk; s2.merged = 1; char h2[sizeof s2 * 2 + 1]; pso_skey_hex(&s2, h2);   // ⑤ 同一对着色器两行渲染状态不同
      NSString *l2 = [NSString stringWithFormat:@"R\t%s\nR\t%s\n", hx, h2], *p2 = [root stringByAppendingPathComponent:@"pso_pair_list.tsv"];
      REQUIRE([l2 writeToFile:p2 atomically:YES encoding:NSUTF8StringEncoding error:nil]);
      long n2 = 0; NSArray<WarmTask *> *t2 = warm_parse(@[p2], &n2); int r1 = 0; for (WarmTask *t in t2) r1 += t->kind == 1 && t->rs.count == 1;
      VERIFY(t2.count == 2 && r1 == 2 && n2 == 2, "⑤ 同一对着色器 2 行 → 任务 %lu 个（每个 1 行的渲染任务 %d 个，计入 %ld 行；期望 2 / 2 / 2：一行一个任务，收尾能分到各核）", (unsigned long)t2.count, r1, n2); }

    uint8_t md[8]; uint64_t n0 = g_shpre_n;
    mtl_shmap_rt_add(F.UTF8String, "vertex");   // ProgramSetShaders 时 dm_shader_miss 见兜底目录已有（dsh_have）就这样登记
    key_md(F, md); nvn_be_shader_prefetch(md); shpre_sync();
    WarmItem *it = handed([F stringByAppendingString:@"_b"]);
    VERIFY(it && it->shader && it->shader->fn && [it->shader->ventry isEqualToString:@"plain"] && g_shpre_n == n0 + 1,
           "③ 预取载出本机现编过的 F_b：交接 %s、函数 %s、入口 %s、预取计数 +%llu（期望 有 / 有 / plain / +1）",
           it ? "有" : "无", it && it->shader && it->shader->fn ? "有" : "无", it && it->shader ? it->shader->ventry.UTF8String : "-", (unsigned long long)(g_shpre_n - n0));

    n0 = g_shpre_n; key_md(G, md); nvn_be_shader_prefetch(md); shpre_sync();
    VERIFY(!handed([G stringByAppendingString:@"_b"]) && g_shpre_n == n0, "④ 运行时映射没登记的 G：交接 %s、预取计数 +%llu（期望 无 / +0）",
           handed([G stringByAppendingString:@"_b"]) ? "有" : "无", (unsigned long long)(g_shpre_n - n0));

    {   // ⑥–⑧ 旧翻译器译过的键：预热里按单支重译
        NSString *P = @"5a5a5a5a5a5a5a5a", *Q = @"3c3c3c3c3c3c3c3c";
        fixture([P stringByAppendingString:@"_b"], @"fedcba9876543210"); fixture([Q stringByAppendingString:@"_b"], @"fedcba9876543210");
        salvage(miss, O); salvage(miss, P);   // Q 没有补料
        uint64_t r0[3], r1[3]; dm_shader_refresh_stats(r0);
        retrans_src = vertex_source; NvShader *so = warm_shader([O stringByAppendingString:@"_b"], 0); dm_shader_refresh_stats(r1);
        NSDictionary *jo = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[fallback stringByAppendingPathComponent:[O stringByAppendingString:@"_b.json"]]] options:0 error:nil];
        VERIFY(so && so->fn && [jo[@"xfp"] isEqual:@"0123456789abcdef"] && r1[0] - r0[0] == 1 && r1[1] == r0[1],
               "⑥ O_b 重译出同样源码：载出 %s、json 指纹 %s、计 没变 +%llu / 变了 +%llu（期望 有 / 0123456789abcdef / +1 / +0）",
               so && so->fn ? "有" : "无", [jo[@"xfp"] description].UTF8String, (unsigned long long)(r1[0] - r0[0]), (unsigned long long)(r1[1] - r0[1]));
        retrans_src = [vertex_source stringByAppendingString:@"// translator changed this one\n"]; NvShader *sp = warm_shader([P stringByAppendingString:@"_b"], 0); dm_shader_refresh_stats(r0);
        VERIFY(sp && sp->fn && r0[1] - r1[1] == 1 && r0[0] == r1[0], "⑦ P_b 重译出不同源码：载出 %s、计 变了 +%llu / 没变 +%llu（期望 有 / +1 / +0）",
               sp && sp->fn ? "有" : "无", (unsigned long long)(r0[1] - r1[1]), (unsigned long long)(r0[0] - r1[0]));
        int calls = retrans_calls; NvShader *sq = warm_shader([Q stringByAppendingString:@"_b"], 0); dm_shader_refresh_stats(r1);
        VERIFY(!sq && retrans_calls == calls && r1[2] - r0[2] == 1, "⑧ Q_b 没有补料：载出 %s、翻译器调用 +%d、计 做不了 +%llu（期望 无 / +0 / +1）",
               sq ? "有" : "无", retrans_calls - calls, (unsigned long long)(r1[2] - r0[2]));
    }

    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("%s t_nvn_warm_fb：%u 项，%u 项失败（本机现编过的着色器进预热与预取，旧翻译器译过的按单支重译，不当别的游戏版本丢掉）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
