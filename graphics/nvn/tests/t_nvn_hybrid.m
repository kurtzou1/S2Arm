// 混合管线（nvn_hybrid.inc）：首遇没有精确管线的绘制，用这对着色器的拉取管线先画。直接包含生产 nvn_mtl.m 调 pso_get_；精确版顶点着色器现编，
//   拉取版是 mk 编好的 <key>_bp.metallib（t_nvn_hybrid_bp.metal：前导 dm_vlayout / dm_fetch 从翻译器 Pull.cs 原样摘出，入口照 Pull.cs 写出的形状），由宿主 pull_fn 从库目录载入。
//   期望按规则手写，不由被测实现推出：
//   ⓪ 两半接口：库容器名 <key>_bp → 种类 55（lib_pack_core.inc / LibPack.cs）、_bp.json 不是一种；反射 pull {entry main0, slot 16} 认、槽不是 16 / 入口不是 main0 / 没有 pull 不认；
//      合批键（_b.json 带 fn_prefix）的拉取库照样载入（_bp 逐键编、入口不带前缀）
//   ① 第一次首遇、这对的拉取基础管线还没有：照旧拿精确管线（不是拉取的，g_pso_pull 0），后台踢出 1 条基础管线
//   ② 基础管线建好后，同一对换一种画布格式（新管线键）首遇：拿到拉取管线（g_pso_pull 1，不是精确那条），精确那条已在后台表里（状态 1 / 2）；特化计数 +1
//   ③ 同一键再取：精确那条编好前给同一条拉取管线（不再特化），编好后给精确的（g_pso_pull 0）
//   ④ 布局块：流 0 基址 0x...2（不按 4 对齐）→ 填的基址是它按 4 下取整、属性偏移 + 2；步长、除数原样；没登记的流（流 1 指向池外）不填、它的属性字 0
//   ⑤ 拉取管线真能画：先核测试自己的 Metal 4 编码能画（无顶点输入的常量色三角形读回 (0.5, 0.25, 0.25, 1)）；再用槽 16 绑布局块画同样 3 个顶点的 RGBA16F 版、
//      流基址余 2（元素地址都是偶数：16 位分量的对齐，Pull.cs / t_vs_pull 的契约；32 位分量要 4 的倍数，Metal 顶点抓取同），一条拉取管线吃另一种顶点格式（基础管线不带顶点布局）；
//      精确管线（建时 RGBA32F）画对齐的 RGBA32F 副本。片元输出插值后的顶点属性：4×4 目标的像素 (1, 1) 中心在 NDC (-0.25, 0.25)，
//      读回 half 逐位 = b400 3400 3400 3c00（-0.25, 0.25, 0.25, 1），两条管线相同
//   ⑥ 随包拉取基础管线（hybrid_pkg_base）：本机 metal-tt 按设备描述出的归档放在 <映射表同级>/pipelines/p<sha256("<顶点键>\t<片元键>\tmain0") 前 40 位>.mtl4archive（shasum 现算）：
//      有这一对 → 第一次首遇就拿到拉取管线、不后台踢、随包命中 +1；包里没有 → 照旧后台踢 1、「包里没有」+1；文件名对但内容是别的片元的 → 照旧后台踢 1、「有文件查不中」+1
//   ⑦ iPhone 包的逐对 lzfse（hybrid_pkg_open）：归档用系统 compression_tool -encode -a lzfse 压成 <名>.mtl4archive.lzfse、不放原样：
//      只有 .lzfse → 第一次首遇就拿到拉取管线、不后台踢、随包命中 +1、「解压」+1、解压耗时 > 0，临时目录里没有留下 s2a_pb_<进程号>_* 解压副本；
//      .lzfse 截掉后一半 → 拉取管线 0、后台踢 1、「有文件查不中」+1、「解压」+0、不崩，标准错误里一行【黄】点名这对顶点 / 片元键；
//      首查预热（hybrid_pkg_warm，测试里直接调）：随包 s2a_warm.metallib + 别的片元的归档冒名 → 「没查中」（2）、一行【黄】；换成本对小库按同一描述出、压过的归档 →
//      「查中」（1）、耗时 > 0、不计入「解压」
//   反证：DM_PSO_HYBRID=0（子进程）→ ② 拿到的是精确管线、g_pso_pull 0
//   ① ⑥ ⑦ 的首遇经 get_held 取：精确那条闸到这次首遇踢了基础管线或取完。反证（11-24 本机）：⑥ ⑦ 改回直接 pso_get_，并在生产 pso_get_ 踢出精确编译与再查状态之间
//      临时插 100 ms → 5 项红，拉取 / 踢 / 命中全零，与门禁 11-19..11-21 留下的 FAIL 行逐字同形；带 get_held 插 100 / 300 ms 照旧 19 项全过
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
// 不符的项连同期望 / 实际记进 g_fail，子进程末行汇总里逐项列出：门禁红组摘录只留 ✗ 行与【红】行，中间的 FAIL 行会被挤掉（11-23 六次红定不了是哪一项）
static char g_fail[8192];
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); char m_[1024]; snprintf(m_, sizeof m_, __VA_ARGS__); printf("%s %s\n", ok_ ? "PASS" : "FAIL", m_); fflush(stdout); \
    if (!ok_) { failures++; strlcat(g_fail, "\n  ✗ 不符：", sizeof g_fail); strlcat(g_fail, m_, sizeof g_fail); } } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
"struct VI { float4 m_0 [[attribute(0)]]; };\n"
"vertex VO main0(VI in [[stage_in]]) { VO o; o.p = float4(in.m_0.xy, 0, 1); o.a = in.m_0; return o; }\n"
"struct F0 { float4 a [[user(locn0)]]; };\n"
"fragment float4 fa(F0 i [[stage_in]]) { return i.a; }\n"
// ⑤ 的编码自检：无顶点输入、常量色
"vertex float4 ck_v(uint v [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[v], 0, 1); }\n"
"fragment float4 ck_f() { return float4(0.5, 0.25, 0.25, 1); }\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *fn, const char *key, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:fn]; REQUIRE(s->fn); s->plib = lib; strlcpy(s->key, key, sizeof s->key);
    s->rf.has_user = stage == 0 ? 1 : 2; if (stage == 0) s->rf.user_out = 1u; else s->rf.user_in = 1u;
    if (stage == 0) { s->rf.nv = 1; s->rf.v[0].loc = 0; s->rf.v[0].nvn = 0; s->rf.v[0].ct = NVN_CT_FLOAT; s->ventry = @"main0"; }
    return s;
}
static NSString *g_pkg_dir;
// ⑥ 的随包文件名：「p」+ sha256("<顶点键>\t<片元键>\t<入口>") 前 40 位十六进制 + .mtl4archive，用系统 shasum 现算（不经被测实现）
static NSString *pkg_name(const char *vk, const char *fk) {
    char cmd[256]; snprintf(cmd, sizeof cmd, "printf '%%s\\t%%s\\tmain0' %s %s | shasum -a 256", vk, fk);
    FILE *p = popen(cmd, "r"); REQUIRE(p); char h[80] = {0}; REQUIRE(fgets(h, sizeof h, p)); pclose(p); h[40] = 0;
    return [NSString stringWithFormat:@"p%s.mtl4archive", h];
}
// 用本机 metal-tt 按设备描述（拉取顶点 main0 + 片元、8 个颜色附件留空、不带顶点描述、其余缺省）出一份 Metal 4 归档：本机 GPU 架构、本机系统大版本
static int pkg_make(NSString *vlib, NSString *vfn, NSString *flib, NSString *ffn, NSString *out) {
    NSString *un = @"{\"pixel_format\":\"Unspecialized\",\"write_mask\":\"Unspecialized\",\"blending_state\":\"Unspecialized\",\"alpha_blend_operation\":\"Unspecialized\",\"rgb_blend_operation\":\"Unspecialized\","
                    "\"destination_alpha_blend_factor\":\"Unspecialized\",\"destination_rgb_blend_factor\":\"Unspecialized\",\"source_alpha_blend_factor\":\"Unspecialized\",\"source_rgb_blend_factor\":\"Unspecialized\"}";
    NSMutableArray *ca = [NSMutableArray array]; for (int i = 0; i < 8; i++) [ca addObject:un];
    NSString *js = [NSString stringWithFormat:@"{\"version\":{\"major\":0,\"minor\":1,\"sub_minor\":0},\"generator\":\"MetalFramework\",\"libraries\":[{\"label\":\"LV\",\"path\":\"%@\"},{\"label\":\"LF\",\"path\":\"%@\"}],"
        "\"function_descriptors\":{\"library_function_descriptors\":[{\"label\":\"V\",\"name\":\"%@\",\"library\":\"LV\"},{\"label\":\"F\",\"name\":\"%@\",\"library\":\"LF\"}]},"
        "\"pipeline_descriptors\":{\"render_pipeline_descriptors\":[{\"vertex_function_descriptor\":\"fnd:V\",\"fragment_function_descriptor\":\"fnd:F\",\"color_attachments\":[%@]}]}}",
        vlib, flib, vfn, ffn, [ca componentsJoinedByString:@","]];
    NSString *script = [out stringByAppendingString:@".mtl4-json"]; REQUIRE([js writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    char cmd[2048]; snprintf(cmd, sizeof cmd, "xcrun -sdk macosx metal-tt -arch %s -macos-version-min %ld.0 '%s' -o '%s' > /dev/null 2>&1", g_dev.architecture.name.UTF8String,
                             (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion, script.UTF8String, out.UTF8String);
    return system(cmd) == 0;
}
static int sh(NSString *cmd) { return system(cmd.UTF8String) == 0; }
static int tmp_left(void) {   // 临时目录里本进程的解压副本（hybrid_pkg_open 的 s2a_pb_<进程号>_*）
    NSString *pre = [NSString stringWithFormat:@"s2a_pb_%d_", getpid()]; int n = 0;
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil]) n += [f hasPrefix:pre];
    return n;
}
// 跑 fn 期间把标准错误（MLOG 的出口）接到文件，返回这段里写下的
static NSString *capture_stderr(void (^fn)(void)) {
    char path[] = "/tmp/t_nvn_hybrid_err_XXXXXX"; int fd = mkstemp(path); REQUIRE(fd >= 0);
    fflush(stderr); int save = dup(2); dup2(fd, 2); fn(); fflush(stderr); dup2(save, 2); close(save); close(fd);
    NSString *s = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil] ?: @""; unlink(path); return s;
}
// 等后台建好基础管线，兜底 30 秒（原 5 秒：负载高时后台编得慢就假红）；等不到返回 0，调用处判红
static int wait_bases(uint64_t want) { for (int i = 0; i < 3000 && g_hy_bases < want; i++) usleep(10000); return g_hy_bases >= want; }
// 首遇取管线，精确那条的后台编译先闸住（g_pp_test_hold），直到这次首遇踢了基础管线（g_hy_kicked 变了：之后它要等精确那条，得放行）或取完返回才放行。
//   不闸：pso_get_ 踢出精确编译后要再查一次状态，系统着色器缓存热时精确那条在这两步之间就编好（状态 2），混合那条路整条跳过，
//   拉取 0、踢 0、命中 0 全零判红（门禁 11-19..11-23 ⑥ ⑦ 的红样；本机在两步之间插 100 ms 必现，① 同样中）
static id get_held(NvProg *p) {
    uint64_t k0 = g_hy_kicked; __block volatile int done = 0; dispatch_semaphore_t h = dispatch_semaphore_create(0); g_pp_test_hold = h;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ for (int i = 0; i < 30000 && g_hy_kicked == k0 && !done; i++) usleep(1000); dispatch_semaphore_signal(h); });
    id ps = pso_get_(p, nil); done = 1; g_pp_test_hold = nil; return ps;
}

static int run(int hybrid) {
    setenv("DM_NVN_FIRST_SKIP", "0", 1);   // 测的是不能跳的首遇（跳过那条路另有单测）
    if (!hybrid) setenv("DM_PSO_HYBRID", "0", 1);
    char user[] = "/tmp/t_nvn_hybrid_XXXXXX"; int fd = mkstemp(user); REQUIRE(fd >= 0); close(fd); setenv("DM_PSO_USER", user, 1);
    // 映射表放进自己的临时目录：随包归档目录 = 它同级的 pipelines/（pso_archive.h par_open_dir），⑥ 往里放随包基础管线
    char mdir[] = "/tmp/t_nvn_hybrid_map_XXXXXX"; REQUIRE(mkdtemp(mdir)); g_pkg_dir = [@(mdir) stringByAppendingPathComponent:@"pipelines"];
    NSString *map = [@(mdir) stringByAppendingPathComponent:@"shader_map.tsv"]; REQUIRE([@"" writeToFile:map atomically:YES encoding:NSUTF8StringEncoding error:nil]); setenv("DM_NVN_SHMAP", map.UTF8String, 1);
    setenv("DM_NVN_PSO_FRAME_MS", "0", 1);
    const char *libdir = getenv("T_HYBRID_LIB"); REQUIRE(libdir);   // mk 编好的 aaaaaaaaaaaaaaaa_bp.metallib 所在目录
    mtl_init(); shmap_load();   // 映射表先载（同生产：首个管线之前），随包归档目录跟着它定；它会把库目录设成缺省的，下面再指回 mk 的
    g_msl_dir = @(libdir);   // 没有容器（lib.idx）：lib_from_pack 读 <库目录>/<名>.metallib
    if (hybrid && !hybrid_on()) { printf("SKIP 本机不是 Metal 4 后端（macOS 26 以下或 NXGAL_BE=mtl3）：混合管线不适用\n"); return 0; }
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e]; REQUIRE(lib);
    NvShader *vs = shader(lib, @"main0", "aaaaaaaaaaaaaaaa_b", 0), *fs = shader(lib, @"fa", "cccccccccccccccc_b", 1);
    // ⓪ 两半接口
    if (hybrid) {
        VERIFY(lp_kind_of("aaaaaaaaaaaaaaaa_bp", 0) == 55 && LP_K_BP == 55 && lp_kind_of("aaaaaaaaaaaaaaaa_bp", 1) == -1, "⓪ 库容器：<key>_bp → 种类 %d（期望 55）、_bp.json → %d（期望 -1）",
               lp_kind_of("aaaaaaaaaaaaaaaa_bp", 0), lp_kind_of("aaaaaaaaaaaaaaaa_bp", 1));
        int r_ok = pull_refl_ok(@{@"pull": @{@"entry": @"main0", @"entry_z": @"main0_z", @"slot": @16, @"inputs": @[@0]}}), r_slot = pull_refl_ok(@{@"pull": @{@"entry": @"main0", @"slot": @17}}),
            r_ent = pull_refl_ok(@{@"pull": @{@"entry": @"main1", @"slot": @16}}), r_none = pull_refl_ok(@{@"stage": @"vs"});
        VERIFY(r_ok && !r_slot && !r_ent && !r_none, "⓪ 反射 pull：{main0, 16} %d（期望 1）、槽 17 %d、入口 main1 %d、没有 pull %d（期望都 0）", r_ok, r_slot, r_ent, r_none);
    }
    vs->has_pull = pull_refl_ok(@{@"pull": @{@"entry": @"main0", @"slot": @16, @"inputs": @[@0]}}); REQUIRE(vs->has_pull);
    vs->fnpfx = @"s0123456789abcdef_";   // 当作合批键：_b 的函数带前缀（vs->fn 已直接给），_bp 逐键编不带
    if (hybrid) { id<MTLFunction> pf = pull_fn(vs);
        VERIFY(pf && [pf.name isEqual:@"main0"] && vs->pfn_state == 1, "⓪ 合批键的拉取库从库目录载入：入口 %s（期望 main0）、状态 %d（期望 1）", pf.name.UTF8String ?: "-", vs->pfn_state); REQUIRE(pf); }
    NvProg *pr = [NvProg new]; pr->sh[0] = vs; pr->sh[1] = fs;
    // 顶点数据：池里 3 个 RGBA32F 顶点，流 0 基址故意不按 4 对齐（+2）
    static uint8_t *pool; REQUIRE(!posix_memalign((void **)&pool, 16384, 65536)); memset(pool, 0, 65536); nvn_be_pool_add(pool, 65536);
    const float verts[3][4] = {{-1, -1, 0.25f, 1}, {3, -1, 0.25f, 1}, {-1, 3, 0.25f, 1}};
    uint8_t *vb = pool + 4096 + 2; memcpy(vb, verts, sizeof verts);
    memset(&S, 0, sizeof S); S.chmask.mask = 0xffffffffu;   // 颜色写掩码全开（游戏由 ChannelMaskState 设缺省；S 全零 = 管线写掩码全零、什么都不写）
    S.nattr = 1; S.attr[0].fmt = 0x2E; S.attr[0].offset = 0; S.attr[0].stream = 0;
    S.stream[0].stride = 16; S.vbuf[0].address = (uint64_t)(uintptr_t)vb; S.vbuf[0].size = sizeof verts;
    memset(&g_pass, 0, sizeof g_pass); g_pass.cfmt[0] = (uint32_t)MTLPixelFormatRGBA32Float; g_pass.samples = 1;

    // ① 第一次首遇：基础管线还没有
    uint64_t kick0 = g_hy_kicked; id ps1 = hybrid ? get_held(pr) : pso_get_(pr, nil); int pull1 = g_pso_pull;
    if (hybrid) VERIFY(ps1 && !pull1 && g_hy_kicked - kick0 == 1, "① 第一次首遇：拿到精确管线 %d、g_pso_pull %d（期望 0）、后台踢出基础管线 %llu 条（期望 1）", ps1 != nil, pull1, (unsigned long long)(g_hy_kicked - kick0));
    if (hybrid) REQUIRE(wait_bases(1));
    // ② 同一对、换画布格式：新键
    g_pass.cfmt[0] = (uint32_t)MTLPixelFormatRGBA16Float;
    pso_key k2; pso_key_fill(&k2, vs, fs, g_pass.cfmt, 0, 0, 1, 0);
    // 精确那条后台编译先闸住（g_pp_test_hold）：② / ③ 判「精确那条还在编」时它一定没编完。原先靠编译慢：门禁机上归档 / 系统缓存热时 kick 后几微秒就编好，
    //   ② 不走拉取管线判红（11-22 main d354d4f0a / b577e8c1c 两次，本机冷缓存 3/3 绿）
    if (hybrid) g_pp_test_hold = dispatch_semaphore_create(0);
    uint64_t made0 = g_hy_made; id ps2 = pso_get_(pr, nil); int pull2 = g_pso_pull, st2 = pso_pend_state(&k2);
    if (!hybrid) { VERIFY(ps2 && !pull2, "反证 DM_PSO_HYBRID=0：② 拿到精确管线 %d、g_pso_pull %d（期望 0）", ps2 != nil, pull2); return 0; }
    VERIFY(ps2 && pull2 && ps2 != ps1 && (st2 == 1 || st2 == 2) && g_hy_made - made0 == 1, "② 基础管线已建好的首遇：拉取管线 g_pso_pull %d（期望 1）、拿到管线 %d（期望 1）、与 ① 同一条 %d（期望 0）、精确那条在后台表里（状态 %d，期望 1 / 2）、特化 +%llu（期望 1）",
           pull2, ps2 != nil, ps2 == ps1, st2, (unsigned long long)(g_hy_made - made0));
    // ③ 同键再取：精确那条编好前同一条拉取管线、编好后精确的
    id ps3 = pso_get_(pr, nil); int pull3 = g_pso_pull;
    if (pull3) VERIFY(ps3 == ps2 && g_hy_made - made0 == 1, "③ 精确那条还在编：与 ② 同一条拉取管线 %d（期望 1）、不再特化（特化 +%llu，期望 1）", ps3 == ps2, (unsigned long long)(g_hy_made - made0));
    VERIFY(pull3, "③ 闸住期间同键再取：仍给拉取管线（g_pso_pull %d，期望 1）", pull3);
    dispatch_semaphore_signal(g_pp_test_hold); g_pp_test_hold = nil;   // 放行：精确那条开始编
    int waited = 0; for (; waited < 3000 && pso_pend_state(&k2) != 2; waited++) usleep(10000);   // 等精确那条后台编好，兜底 30 秒（原 5 秒）；等不到下一行判红
    int st4 = pso_pend_state(&k2); id ps4 = pso_get_(pr, nil);
    VERIFY(ps4 && !g_pso_pull && ps4 != ps2, "③ 精确那条编好后：给精确管线（g_pso_pull %d，期望 0）、拿到管线 %d（期望 1）、仍是 ② 那条拉取管线 %d（期望 0）；取之前后台状态 %d（期望 2）、等了约 %d ms",
           g_pso_pull, ps4 != nil, ps4 == ps2, st4, waited * 10);
    // ④ 布局块（手算）
    pull_layout L; pull_layout_fill(&L, vs);
    uint64_t gpu = 0; void *mb; uint64_t mo; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)vb, sizeof verts, &mb, &mo, &gpu));
    va_st w; memcpy(&w, &L.attr[0], 4);
    VERIFY(L.s[0].base == (gpu & ~3ull) && L.s[0].stride == 16 && L.s[0].divisor == 0 && w.fmt == 0x2E && w.offset == (gpu & 3) && w.stream == 0,
           "④ 流 0 基址 %#llx（期望 %#llx = 按 4 下取整）、步长 %u、除数 %u；属性 0 格式 %#x、偏移 %u（期望 %llu）、流 %u",
           (unsigned long long)L.s[0].base, (unsigned long long)(gpu & ~3ull), L.s[0].stride, L.s[0].divisor, w.fmt, w.offset, (unsigned long long)(gpu & 3), w.stream);
    S.vbuf[1].address = 0x1234560; S.vbuf[1].size = 64; S.nattr = 2; S.attr[1].fmt = 0x2E; S.attr[1].stream = 1; pull_layout_fill(&L, vs);
    VERIFY(L.s[1].base == 0 && L.attr[1] == 0, "④ 池外的流 1：基址 %#llx、属性 1 字 %#x（期望都 0：读 0）", (unsigned long long)L.s[1].base, L.attr[1]);
    S.nattr = 1; S.vbuf[1].address = 0;
    // ⑤ 真画：编码自检、拉取管线（非对齐流、槽 16 布局块）、精确管线（对齐副本、顶点描述）
    if (@available(macOS 26.0, iOS 26.0, *)) {
        uint8_t *va = pool + 8192; memcpy(va, verts, sizeof verts); void *mba; uint64_t moa, gpua; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)va, sizeof verts, &mba, &moa, &gpua)); REQUIRE(!(gpua & 3));
        static const uint16_t vh[3][4] = {{0xbc00, 0xbc00, 0x3400, 0x3c00}, {0x4200, 0xbc00, 0x3400, 0x3c00}, {0xbc00, 0x4200, 0x3400, 0x3c00}};   // half (-1, -1) (3, -1) (-1, 3)，z 0.25、w 1
        uint8_t *vhp = pool + 12288 + 2; memcpy(vhp, vh, sizeof vh); void *mbh; uint64_t moh, gpuh; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)vhp, sizeof vh, &mbh, &moh, &gpuh)); REQUIRE((gpuh & 3) == 2);
        va_st a0 = S.attr[0]; NVNbufferRange b0 = S.vbuf[0]; uint32_t st0 = S.stream[0].stride;
        S.attr[0].fmt = 0x29; S.vbuf[0].address = (uint64_t)(uintptr_t)vhp; S.vbuf[0].size = sizeof vh; S.stream[0].stride = 8;   // RGBA16F（t_vs_pull 格式表 0x29）
        MTLRenderPipelineDescriptor *cd = [MTLRenderPipelineDescriptor new]; cd.vertexFunction = [lib newFunctionWithName:@"ck_v"]; cd.fragmentFunction = [lib newFunctionWithName:@"ck_f"];
        cd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float; id<MTLRenderPipelineState> cps = [g_dev newRenderPipelineStateWithDescriptor:cd error:&e]; REQUIRE(cps);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        uint16_t px[3][4]; id<MTLRenderPipelineState> pss[3] = {cps, ps2, ps4};
        id<MTLBuffer> lb = [g_dev newBufferWithLength:sizeof L options:MTLResourceStorageModeShared]; pull_layout_fill(&L, vs); memcpy(lb.contents, &L, sizeof L);
        S.attr[0] = a0; S.vbuf[0] = b0; S.stream[0].stride = st0;
        id<MTL4CommandQueue> q = [g_dev newMTL4CommandQueue]; id<MTL4CommandAllocator> ca = [g_dev newCommandAllocator];
        id<MTLResidencySet> rs = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&e]; REQUIRE(rs);
        [rs addAllocation:lb]; [rs addAllocation:(__bridge id<MTLBuffer>)mb]; [rs addAllocation:(__bridge id<MTLBuffer>)mba]; [rs addAllocation:(__bridge id<MTLBuffer>)mbh];   // 顶点数据在后端登记池子的那个缓冲里（mtl_gpu_addr 给的），不在别处
        for (int i = 0; i < 3; i++) {
            id<MTLTexture> t = [g_dev newTextureWithDescriptor:td]; [rs addAllocation:t]; [rs commit];
            id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:ca]; [cb useResidencySet:rs];
            MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 31; id<MTL4ArgumentTable> at = [g_dev newArgumentTableWithDescriptor:ad error:&e]; REQUIRE(at);
            if (i) [at setAddress:(i == 1 ? lb.gpuAddress : gpua) atIndex:16];   // 拉取：布局块；精确：流 0 = VB_SLOT(0) = 16
            [en setArgumentTable:at atStages:MTLRenderStageVertex]; [en setRenderPipelineState:pss[i]];
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding]; [cb endCommandBuffer];
            id<MTLSharedEvent> ev = [g_dev newSharedEvent]; [q commit:&cb count:1]; [q signalEvent:ev value:1]; REQUIRE([ev waitUntilSignaledValue:1 timeoutMS:30000]);   // GPU 完成等待上限 30 秒（原 5 秒）
            [t getBytes:px[i] bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        }
        VERIFY(px[0][0] == 0x3800 && px[0][1] == 0x3400 && px[0][2] == 0x3400 && px[0][3] == 0x3c00, "⑤ 编码自检（常量色三角形）：%04x %04x %04x %04x（期望 3800 3400 3400 3c00）", px[0][0], px[0][1], px[0][2], px[0][3]);
        static const uint16_t want[4] = {0xb400, 0x3400, 0x3400, 0x3c00};
        VERIFY(!memcmp(px[1], want, sizeof want) && !memcmp(px[2], want, sizeof want), "⑤ 拉取管线（RGBA16F、流基址余 2）/ 精确管线（RGBA32F）画出的像素：%04x %04x %04x %04x / %04x %04x %04x %04x（期望都 b400 3400 3400 3c00）",
               px[1][0], px[1][1], px[1][2], px[1][3], px[2][0], px[2][1], px[2][2], px[2][3]);
    }
    // ⑥ 随包拉取基础管线：片元库 hybrid_fs.metallib（mk 编，fb / fy / fz 三个片元）。B 对（fb）有对得上的随包归档；Z 对（fz）包里没有；
    //   Y 对（fy）的文件名对、内容是 fz 的基础管线（查不中）。都是这对第一次首遇
    {
        NSString *ld = @(libdir), *vlib = [ld stringByAppendingPathComponent:@"aaaaaaaaaaaaaaaa_bp.metallib"], *flib = [ld stringByAppendingPathComponent:@"hybrid_fs.metallib"];
        REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:g_pkg_dir withIntermediateDirectories:YES attributes:nil error:nil]);
        REQUIRE(pkg_make(vlib, @"main0", flib, @"fb", [g_pkg_dir stringByAppendingPathComponent:pkg_name("aaaaaaaaaaaaaaaa_b", "eeeeeeeeeeeeeeee_b")]));
        REQUIRE(pkg_make(vlib, @"main0", flib, @"fz", [g_pkg_dir stringByAppendingPathComponent:pkg_name("aaaaaaaaaaaaaaaa_b", "9999999999999999_b")]));
        id<MTLLibrary> fl = [g_dev newLibraryWithURL:[NSURL fileURLWithPath:flib] error:&e]; REQUIRE(fl);
        NvShader *fsb = shader(fl, @"fb", "eeeeeeeeeeeeeeee_b", 1), *fsz = shader(fl, @"fz", "ffffffffffffffff_b", 1), *fsy = shader(fl, @"fy", "9999999999999999_b", 1);
        NvShader *fss[3] = {fsb, fsz, fsy}; int pulled[3]; uint64_t kicked[3], hit[3], nofile[3], miss[3];
        for (int i = 0; i < 3; i++) {
            NvProg *p6 = [NvProg new]; p6->sh[0] = vs; p6->sh[1] = fss[i];
            uint64_t st0[3], st1[3], k0 = g_hy_kicked; mtl_hybrid_pkg_stats(st0);
            id ps = get_held(p6); pulled[i] = ps && g_pso_pull; mtl_hybrid_pkg_stats(st1);
            kicked[i] = g_hy_kicked - k0; hit[i] = st1[0] - st0[0]; nofile[i] = st1[1] - st0[1]; miss[i] = st1[2] - st0[2];
        }
        VERIFY(pulled[0] && !kicked[0] && hit[0] == 1 && !nofile[0] && !miss[0], "⑥ 随包有这一对：第一次首遇就拿到拉取管线 %d（期望 1）、后台踢 %llu（期望 0）、随包命中 +%llu（期望 1）、包里没有 +%llu、有文件查不中 +%llu（期望都 0）",
               pulled[0], (unsigned long long)kicked[0], (unsigned long long)hit[0], (unsigned long long)nofile[0], (unsigned long long)miss[0]);
        VERIFY(!pulled[1] && kicked[1] == 1 && !hit[1] && nofile[1] == 1 && !miss[1], "⑥ 包里没有这一对：拉取管线 %d（期望 0）、后台踢 %llu（期望 1）、包里没有 +%llu（期望 1）、随包命中 +%llu、有文件查不中 +%llu（期望都 0）",
               pulled[1], (unsigned long long)kicked[1], (unsigned long long)nofile[1], (unsigned long long)hit[1], (unsigned long long)miss[1]);
        VERIFY(!pulled[2] && kicked[2] == 1 && !hit[2] && !nofile[2] && miss[2] == 1, "⑥ 文件在、内容是别的片元的：拉取管线 %d（期望 0）、后台踢 %llu（期望 1）、有文件查不中 +%llu（期望 1）、随包命中 +%llu、包里没有 +%llu（期望都 0）",
               pulled[2], (unsigned long long)kicked[2], (unsigned long long)miss[2], (unsigned long long)hit[2], (unsigned long long)nofile[2]);
        // ⑦ 逐对 lzfse：D 对（fd，片元键 dddd…）只有压过的；C 对（fc，片元键 cccc…）压过的截掉后一半
        NSString *pd = [g_pkg_dir stringByAppendingPathComponent:pkg_name("aaaaaaaaaaaaaaaa_b", "dddddddddddddddd_b")], *pc = [g_pkg_dir stringByAppendingPathComponent:pkg_name("aaaaaaaaaaaaaaaa_b", "cccccccccccccccc_b")];
        REQUIRE(pkg_make(vlib, @"main0", flib, @"fd", pd) && sh([NSString stringWithFormat:@"compression_tool -encode -a lzfse -i '%@' -o '%@.lzfse' && rm -f '%@'", pd, pd, pd]));
        REQUIRE(pkg_make(vlib, @"main0", flib, @"fc", pc) && sh([NSString stringWithFormat:@"compression_tool -encode -a lzfse -i '%@' -o '%@.full' && rm -f '%@'", pc, pc, pc]));
        NSData *full = [NSData dataWithContentsOfFile:[pc stringByAppendingString:@".full"]]; REQUIRE(full.length > 64);
        REQUIRE([[full subdataWithRange:NSMakeRange(0, full.length / 2)] writeToFile:[pc stringByAppendingString:@".lzfse"] atomically:YES]);
        REQUIRE(![NSFileManager.defaultManager fileExistsAtPath:pd] && ![NSFileManager.defaultManager fileExistsAtPath:pc]);
        NvShader *fsd = shader(fl, @"fd", "dddddddddddddddd_b", 1), *fsc = shader(fl, @"fc", "cccccccccccccccc_b", 1);
        uint64_t s0[7], s1[7], s2[7]; mtl_hybrid_pkg_stats(s0);
        NvProg *pd7 = [NvProg new]; pd7->sh[0] = vs; pd7->sh[1] = fsd;
        uint64_t kd0 = g_hy_kicked; id psd = get_held(pd7); int pzd = psd && g_pso_pull; uint64_t kzd = g_hy_kicked - kd0; mtl_hybrid_pkg_stats(s1);
        uint64_t hitd = s1[0] - s0[0], unzd = s1[3] - s0[3], nsd = s1[4] - s0[4];
        VERIFY(pzd && !kzd && hitd == 1 && unzd == 1 && nsd > 0 && !tmp_left(), "⑦ 只有 .lzfse：第一次首遇就拿到拉取管线 %d（期望 1）、后台踢 %llu（期望 0）、随包命中 +%llu（期望 1）、解压 +%llu（期望 1）、"
               "解压耗时 %.3f ms（期望 > 0）、临时目录留下的解压副本 %d 份（期望 0）", pzd, (unsigned long long)kzd, (unsigned long long)hitd, (unsigned long long)unzd, nsd / 1e6, tmp_left());
        NvProg *pc7 = [NvProg new]; pc7->sh[0] = vs; pc7->sh[1] = fsc;
        __block int pzc = 0; __block uint64_t kzc = 0;
        NSString *err = capture_stderr(^{ uint64_t k0 = g_hy_kicked; id ps = get_held(pc7); pzc = ps && g_pso_pull; kzc = g_hy_kicked - k0; });
        mtl_hybrid_pkg_stats(s2);
        uint64_t missc = s2[2] - s1[2], unzc = s2[3] - s1[3];
        int yellow = [err rangeOfString:@"【黄】 hybrid pipelines: the package's pulling base of vertex aaaaaaaaaaaaaaaa_b fragment cccccccccccccccc_b did not serve"].location != NSNotFound;
        VERIFY(!pzc && kzc == 1 && missc == 1 && !unzc && yellow, "⑦ .lzfse 截断：拉取管线 %d（期望 0）、后台踢 %llu（期望 1）、有文件查不中 +%llu（期望 1）、解压 +%llu（期望 0）、【黄】一行点名这对 %d（期望 1）",
               pzc, (unsigned long long)kzc, (unsigned long long)missc, (unsigned long long)unzc, yellow);
        // ⑦ 首查预热：随包小库 s2a_warm.metallib；先拿 fb 那对的归档冒名（查不中），再换成本对小库按同一描述出的、压过的归档
        NSString *ws = [g_pkg_dir stringByAppendingPathComponent:@"s2a_warm.metal"], *wl = [g_pkg_dir stringByAppendingPathComponent:@"s2a_warm.metallib"], *wa = [g_pkg_dir stringByAppendingPathComponent:@"s2a_warm.mtl4archive"];
        REQUIRE([@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 s2a_warm_v(uint v [[vertex_id]]) { return float4(0, 0, 0, 1); }\nfragment float4 s2a_warm_f() { return float4(0); }\n"
                 writeToFile:ws atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        REQUIRE(sh([NSString stringWithFormat:@"xcrun -sdk macosx metal '%@' -o '%@'", ws, wl]));
        REQUIRE(pkg_make(vlib, @"main0", flib, @"fb", wa));
        uint64_t w0[7], w1[7], w2[7]; mtl_hybrid_pkg_stats(w0);
        NSString *werr = capture_stderr(^{ if (@available(macOS 26.0, iOS 26.0, *)) hybrid_pkg_warm(); }); mtl_hybrid_pkg_stats(w1);
        int wy = [werr rangeOfString:@"【黄】 hybrid pipelines: the package's warm-up pair did not serve"].location != NSNotFound;
        VERIFY(w1[5] == 2 && wy, "⑦ 首查预热、归档是别的对冒名：状态 %llu（期望 2 没查中）、【黄】一行 %d（期望 1）", (unsigned long long)w1[5], wy);
        REQUIRE(pkg_make(wl, @"s2a_warm_v", wl, @"s2a_warm_f", wa) && sh([NSString stringWithFormat:@"compression_tool -encode -a lzfse -i '%@' -o '%@.lzfse' && rm -f '%@'", wa, wa, wa]));
        if (@available(macOS 26.0, iOS 26.0, *)) hybrid_pkg_warm();
        mtl_hybrid_pkg_stats(w2);
        VERIFY(w2[5] == 1 && w2[6] > w1[6] && w2[3] == w0[3] && !tmp_left(), "⑦ 首查预热、本对压过的归档：状态 %llu（期望 1 查中）、耗时 %.3f ms（期望 > 0）、解压计数 +%llu（期望 0：预热不计）、解压副本留下 %d（期望 0）",
               (unsigned long long)w2[5], (w2[6] - w1[6]) / 1e6, (unsigned long long)(w2[3] - w0[3]), tmp_left());
    }
    return 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 3 && !strcmp(argv[1], "--child")) { run(atoi(argv[2])); printf("%s t_nvn_hybrid 子进程（DM_PSO_HYBRID=%s）：%u 项，%u 项不符%s\n", failures ? "✗" : "✓", argv[2], checks, failures, g_fail); return failures != 0; }
    unsigned bad = 0; static const char *const modes[2] = {"1", "0"};
    for (int m = 0; m < 2; m++) {
        fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
        if (!pid) { execl(argv[0], argv[0], "--child", modes[m], (char *)NULL); _exit(127); }
        int st = 0; pid_t w; do { w = waitpid(pid, &st, 0); } while (w < 0 && errno == EINTR); REQUIRE(w == pid);
        bad += !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
    }
    printf("%s t_nvn_hybrid：缺省 / DM_PSO_HYBRID=0 两个子进程，%u 个不过（混合管线：首遇没有精确管线的绘制用拉取管线先画）\n", bad ? "✗" : "✓", bad);
    return bad != 0;
} }
