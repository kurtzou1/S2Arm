// 采样器 LOD 偏置 / 归约按 GPU 能力原生或着色器模拟的端到端（10-28 / 10-29，#800）：直接包含生产 nvn_mtl.m，走真 dispatch / draw → encode_args（lb_fill：主体 main0 的 s2a_lb 偏置表）
//   → se_want（判要不要归约变体、载变体）→ se_bind（26 号槽）/ samp_by_id。
// 着色器 = t_red.py --emit 写的计算核：主体 = dmsh_red.py fs_lb 改写后（库里的 main0，偏置从参数块成员 s2a_lb 读）、归约变体 = 再经 fs_rd（与设备上 S2A.Dsh FsRd 逐字同）；
//   变体照设备上的样子放进兜底目录（DM_MSL_FALLBACK：<键>_b.metal + 本链 _b.json + 不比它旧的 <键>_se.metal），反射照出库反射（S2A.Dsh DshCompiler.Reflect，graphics/tools/direct/dsh/Dsh.cs）手写（含 lb 成员）；
//   贴图 = R32F 8×8、4 级，块线性存储经生产上传路径进 GPU。
// 四个子进程：缺省（本机能力：M5 = Apple10 归约原生、偏置实测生效即原生：s2a_lb 表写 0）与 S2A_SAMP_EMU=1（非 Apple10 那一路：采样器不带归约 / 偏置，偏置写进 s2a_lb 表、
//   归约走变体，S2A_SE_SYNC=1 首遇同步现编、第一笔就是变体）× Metal 4 / NXGAL_BE=mtl3。
// 另两个子进程核「后台编 + 替身」（10-29 夜终版，nvn_mtl.m se_want / se_kick）：S2A_SAMP_EMU=1 片元绑 min 归约采样器画两笔——缺省第一笔是 main0 替身（不归约、取平均：
//   读数严格落在足迹两纹素之间，min < 读数 < max，手算两纹素），等后台编好后第二笔 = min 手算逐位；S2A_SE_SYNC=1 第一笔就 = min 手算逐位。
//   子进程 stderr 存文件，核编好那一行的固定格式（「[s2a] 归约变体：程序号 <16 位> 着色器 <键> 后台编完成 / 同步现编完成 <x.y> ms」，普查按它汇总）。
// 期望 = CPU 按定义手算，不跑被测实现：归约 = 所采级（LOD + 采样器偏置）双线性足迹里权重非零的纹素取 min / max；带偏置的普通采样器（最近点 + mip 最近）= LOD + 偏置就近取级后
//   取所在纹素（偏置取 1.25 / −0.75，LOD + 偏置的小数部分只有 .25 / .75，不落在两级正中）。寻址按 NVN 模式。每路逐位等于期望，六路之间逐位相等。
// 守卫（期望手写）：每条管线的模拟位 = 这次绑的采样器按定义要的（归约：min / max、本机不原生；任意边界色：任何 GPU；偏置不出变体），本机原生归约（Apple10）时只有边界色那项建变体管线。
// 任意边界色（11-01，缺口族 31）：一项线性 + mip 线性、夹边框、边界色 (0.25, 0.5, 0.75, 0.6) 的普通采样器，期望 = CPU 三线性手算（界外权重 × 0.25），容差 1e-5（其余项逐位）；
//   走 se_bind 填表项、samp_border_rid 建透明黑 / 不透明白两个采样器，两种 GPU 能力都用变体。
// 反证：同一贴图配不带归约的采样器（取平均），与归约期望对不上的位置必须 > 0（判据不会绿着失效）。用法：make native-test-nvn_red（末行 ✓ / ✗）
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>
#include <regex.h>
#include <fcntl.h>

enum { W = 8, NL = 4, NPAD = 640, TID = 7, POOL = 1 << 20, OUT_OFF = 65536 };
static const int MX[] = {-40, -8, 0, 7, 16, 33, 48, 64, 100, 128, 144, 200, 240, 255, 256, 270, 330}, MY[] = {-5, 16, 37, 128, 250};   // 坐标 = m / 256（各级纹素的 1/256 格点）
static const float LODS[] = {0, 1, 2, 3, 5, -1, 1.5f};
enum { NMX = sizeof MX / sizeof *MX, NMY = sizeof MY / sizeof *MY, NLOD = sizeof LODS / sizeof *LODS, NP = NMX * NMY * NLOD };
static const int MF[3] = {1, 3, 5}, WR[5] = {7, 1, 6, 3, 5};   // NVN 缩小过滤：线性无 mip / 线性 + mip 近邻 / 线性 + mip 线性；寻址：夹边 / 重复 / 镜像重复 / 镜像夹边 / 夹边框（白）
enum { NCASE = 2 * 3 * 5, NBR = 2 * 2 * 2, NBP = 2 * 2, NBD = NCASE + 1 + NBR + NBP, NRUN = NBD + 1 };   // NCASE 归约、1 反证（不带归约）、NBR 归约 + 偏置、NBP 普通采样器 + 偏置、1 任意边界色（NBD）
static const float BORDER[4] = {0.25f, 0.5f, 0.75f, 0.6f};
static const float BIAS[2] = {1.25f, -0.75f};
// 本测扮演链了 S2A.Aot 的 App：兜底目录的 json 要带与它相同的翻译器指纹才载（nvn_mtl.m fb_json_current，dlsym 在主程序里找到它）
const char *s2a_dsh_xfp(void) { return "0123456789abcdef"; }
static unsigned failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static float val(int lv, int x, int y) {   // 每级、每个纹素各一个值（k / 1023）
    uint32_t h = (uint32_t)x * 73856093u ^ (uint32_t)y * 19349663u ^ (uint32_t)lv * 83492791u; h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15; return (float)(h & 1023u) / 1023.0f;
}
static int wrap_i(int i, int n, int m) {   // NVN 寻址模式按定义折回；-1 = 边框色
    switch (m) {
    case 1: { int r = i % n; return r < 0 ? r + n : r; }   // REPEAT
    case 6: { int p = 2 * n, r = i % p; if (r < 0) r += p; return r < n ? r : p - 1 - r; }   // MIRRORED_REPEAT
    case 3: { int k = i < 0 ? -1 - i : i; return k < n ? k : n - 1; }   // MIRROR_CLAMP_TO_EDGE
    case 5: return i < 0 || i >= n ? -1 : i;   // CLAMP_TO_BORDER
    default: return i < 0 ? 0 : i >= n ? n - 1 : i;   // CLAMP_TO_EDGE
    }
}
static float cpu_near(int wrap, float u, float v, float lod) {   // 最近点 + mip 最近：LOD 钳 [0, 3] 后就近取级（小数部分不是 .5），取 (u, v) 所在纹素
    float l = lod < 0 ? 0 : lod > NL - 1 ? NL - 1 : lod; int lv = (int)floorf(l + 0.5f), w = W >> lv;
    int xi = wrap_i((int)floorf(u * w), w, wrap), yj = wrap_i((int)floorf(v * w), w, wrap); return xi < 0 || yj < 0 ? 1.0f : val(lv, xi, yj);
}
static float cpu_red(int red, int minf, int wrap, float u, float v, float lod) {   // 无 mip：只读第 0 级；mip 近邻：LOD 钳 [0, 3] 后取 ceil(l − 0.5) 一级（Metal 最近 mip，11-01 实测）；mip 线性：小数时两级都算
    float l = minf <= 1 ? 0 : lod < 0 ? 0 : lod > NL - 1 ? NL - 1 : lod; if (minf == 2 || minf == 3) l = ceilf(l - 0.5f);
    int l0 = (int)floorf(l), nl = l > l0 ? 2 : 1, first = 1; float r = 0;
    for (int k = 0; k < nl; k++) { int lv = l0 + k, w = W >> lv;
        float fx = u * w - 0.5f, fy = v * w - 0.5f; int x0 = (int)floorf(fx), y0 = (int)floorf(fy), nx = fx > x0 ? 2 : 1, ny = fy > y0 ? 2 : 1;   // 小数部分 0：右 / 下邻权重 0，不参与
        for (int j = 0; j < ny; j++) for (int i = 0; i < nx; i++) { int xi = wrap_i(x0 + i, w, wrap), yj = wrap_i(y0 + j, w, wrap);
            float t = xi < 0 || yj < 0 ? 1.0f : val(lv, xi, yj); r = first ? t : red == 2 ? fmaxf(r, t) : fminf(r, t); first = 0; } }
    return r;
}
static double cpu_tri(float u, float v, float lod) {   // 线性 + mip 线性、夹边框、边界色 BORDER 的 R：两级（小数时）双线性按权重求和，界外纹素取 0.25，再按 LOD 小数混合
    float l = lod < 0 ? 0 : lod > NL - 1 ? NL - 1 : lod; int l0 = (int)floorf(l), nl = l > l0 ? 2 : 1; double r = 0, f = l - l0;
    for (int k = 0; k < nl; k++) { int lv = l0 + k, w = W >> lv; double fx = (double)u * w - 0.5, fy = (double)v * w - 0.5, s = 0; int x0 = (int)floor(fx), y0 = (int)floor(fy); double ax = fx - x0, ay = fy - y0;
        for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) { int xi = wrap_i(x0 + i, w, 5), yj = wrap_i(y0 + j, w, 5); s += (i ? ax : 1 - ax) * (j ? ay : 1 - ay) * (xi < 0 || yj < 0 ? BORDER[0] : val(lv, xi, yj)); }
        r += (nl == 1 ? 1 : k ? f : 1 - f) * s; }
    return r;
}
static void points(float (*p)[4]) {
    int n = 0;
    for (int l = 0; l < NLOD; l++) for (int a = 0; a < NMX; a++) for (int b = 0; b < NMY; b++) { p[n][0] = MX[a] / 256.0f; p[n][1] = MY[b] / 256.0f; p[n][2] = LODS[l]; p[n][3] = 0; n++; }
    for (; n < NPAD; n++) { p[n][0] = p[n][1] = 0.5f; p[n][2] = p[n][3] = 0; }
}
// 第 c 项采样器配置：归约 red（0 无）、NVN 缩小过滤 minf / 放大 magf、寻址 wrap、LOD 偏置 bias
static void case_of(int c, int *red, int *minf, int *magf, int *wrap, float *bias) {
    *magf = 1; *bias = 0;
    if (c < NCASE) { *red = 1 + c / 15; *minf = MF[c / 5 % 3]; *wrap = WR[c % 5]; return; }
    if (c == NCASE) { *red = 0; *minf = 5; *wrap = 7; return; }
    c -= NCASE + 1;
    if (c < NBR) { *red = 1 + c / 4; *minf = c / 2 % 2 ? 5 : 3; *wrap = 7; *bias = BIAS[c % 2]; return; }   // 归约 + 偏置：线性 + mip 近邻 / 线性，夹边
    c -= NBR;
    if (c >= NBP) { *red = 0; *minf = 5; *wrap = 5; return; }   // 任意边界色（NBD）：线性 + mip 线性、夹边框
    *red = 0; *minf = 2; *magf = 0; *wrap = c / 2 ? 1 : 7; *bias = BIAS[c % 2];   // 普通采样器 + 偏置：最近点 + mip 最近，夹边 / 重复
}
static float cpu_case(int c, float u, float v, float lod) {
    int red, minf, magf, wrap; float b; case_of(c, &red, &minf, &magf, &wrap, &b);
    return c == NBD ? (float)cpu_tri(u, v, lod) : red ? cpu_red(red, minf, wrap, u, v, lod + b) : cpu_near(wrap, u, v, lod + b);
}
static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static const char CS_KEY[] = "c5e0000000000001", FS_KEY[] = "f5e0000000000002";   // 兜底目录里的键（16 位十六进制，同库名）
// 期望手写的管线模拟位（nvn_red.h SE_RD 2）：配置 c 绑的采样器按定义要不要模拟变体——min / max 且本机不原生（本测各项足迹都不止一个纹素）、或任意边界色（任何 GPU）。
//   偏置不出变体（主体 main0 从 s2a_lb 表加），恒不占位
static int want_fc(int c, int red_emu, int lb_emu) {
    int red, minf, magf, wrap; float bias; case_of(c, &red, &minf, &magf, &wrap, &bias); (void)lb_emu;
    return c == NBD || (red_emu && red) ? 2 : 0;
}
// 渲染目标的 GPU 内容（RGBA32F 4×4）：拷到共享缓冲读（同 t_nvn_scissored_ds.m read_planes）
static void read_rt(const tex_t *t, float *px) {
    id<MTLTexture> mt = tex_mtl(t); REQUIRE(mt != nil);
    id<MTLCommandQueue> q = [mt.device newCommandQueue]; id<MTLBuffer> d = [mt.device newBufferWithLength:4 * 16 options:MTLResourceStorageModeShared]; REQUIRE(q && d);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:d destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:256];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted && !cb.error);
    memcpy(px, d.contents, 4 * 16 * 4);
}
static NvShader *fixture(id<MTLLibrary> lib) {
    NvShader *s = [NvShader new]; s->stage = 5; strlcpy(s->key, CS_KEY, sizeof s->key);
    s->fn = [lib newFunctionWithName:@"main0"]; REQUIRE(s->fn);
    s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae); s->arg_len = s->ae.encodedLength;
    REQUIRE(s->arg_len >= 4 * 8 && !(s->arg_len % 8) && s->arg_len <= NVN_REFL_MAXARG * 8);
    NSDictionary *j = @{ @"route": @"B", @"threadgroup_size": @[@64, @1, @1], @"bindings": @[
        @{ @"kind": @"tex", @"reg": @0, @"arg_id": @0, @"msl_name": @"cp_t_tcb_8", @"msl_type": @"texture2d<float>" },
        @{ @"kind": @"samp_tex", @"reg": @0, @"arg_id": @1, @"msl_name": @"cp_t_tcb_8Smplr", @"msl_type": @"sampler" },
        @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @2, @"rw": @YES, @"msl_type": @"device float*" },
        @{ @"kind": @"sbuf", @"reg": @1, @"arg_id": @3, @"rw": @NO, @"msl_type": @"const device float4*" },
        @{ @"kind": @"lb", @"arg_id": @4, @"msl_name": @"s2a_lb", @"msl_type": @"constant float*" } ] };   // = DshCompiler.Reflect（Dsh.cs）给 fs_lb 加的成员（主体 main0 的偏置表）
    char e[512]; REQUIRE(!nvn_refl_from_json(j, &s->rf, e, sizeof e));
    REQUIRE(s->rf.nb == 5 && s->rf.b[1].kind == NVN_RB_SAMPT && s->rf.b[3].kind == NVN_RB_SBUFP && s->rf.b[4].kind == NVN_RB_LB);
    return s;
}
// 贴图：R32F 8×8、4 级，块线性存储在 CPU_NO_ACCESS 池里（首次用到时经上传批进 GPU，同 t_nvn_m3 ③'），注册为 TID
static void tex_setup(void) {
    static pool_t tp; uint8_t *tm = NULL; REQUIRE(!posix_memalign((void **)&tm, 65536, POOL)); memset(tm, 0, POOL);
    static tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0);
    t.d = (nvn_texdesc){NVN_TEXTURE_TARGET_2D, NVN_FORMAT_R32F, 0, 0, W, W, 1, NL, 0, 0}; nvn_tex_layout(&t.d, &t.L); REQUIRE(t.L.size <= POOL);
    for (int l = 0; l < NL; l++) { int w = W >> l; float lin[W * W]; for (int y = 0; y < w; y++) for (int x = 0; x < w; x++) lin[y * w + x] = val(l, x, y);
        REQUIRE(!nvn_swizzle(&t.d, (unsigned)l, 0, lin, (size_t)w * 4, tm)); }
    tp = (pool_t){MAGIC('P', 'O', 'O', 'L'), NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, tm, POOL};
    nvn_be_pool_add(tm, POOL); t.pool = &tp; t.mem = tm; t.serial = nvn_new_serial(); nvn_be_tex_init(&t); nvn_be_reg_tex(TID, &t, NULL);
}
// 片元核夹具：顶点 vs_main（只读 vertex_id）+ 片元 main0（键 FS_KEY，反射照 DshCompiler.Reflect（Dsh.cs）手写：贴图、samp_tex、lb）；程序登记进 *fprog
static NvShader *fs_fixture(const char *fsmsl, prog_t *fprog) {
    NSError *fe = nil; NSString *fsrc = [NSString stringWithContentsOfFile:@(fsmsl) encoding:NSUTF8StringEncoding error:&fe]; REQUIRE(fsrc);
    id<MTLLibrary> flib = [g_dev newLibraryWithSource:fsrc options:nil error:&fe]; if (!flib) fprintf(stderr, "FS MSL: %s\n", fe.localizedDescription.UTF8String); REQUIRE(flib);
    NvShader *fvs = [NvShader new]; fvs->stage = 0; fvs->fn = [flib newFunctionWithName:@"vs_main"]; REQUIRE(fvs->fn);
    fvs->ae = nil; fvs->arg_len = 8;   // 顶点无 argument buffer 参数（vs_main 只读 vertex_id）
    NSDictionary *jv = @{ @"route": @"B", @"bindings": @[] }; char ev[512]; REQUIRE(!nvn_refl_from_json(jv, &fvs->rf, ev, sizeof ev));
    NvShader *ffs = [NvShader new]; ffs->stage = 1; strlcpy(ffs->key, FS_KEY, sizeof ffs->key); ffs->fn = lib_entry(flib, @"main0"); REQUIRE(ffs->fn);   // 带函数常量（t_red.py --emit-fs 经 FsAlphaMs）：同 shader_load 先特化
    ffs->ae = [ffs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(ffs->ae); ffs->arg_len = ffs->ae.encodedLength;
    NSDictionary *jf = @{ @"route": @"B", @"bindings": @[
        @{ @"kind": @"tex", @"reg": @0, @"arg_id": @0, @"msl_name": @"cp_t_tcb_8", @"msl_type": @"texture2d<float>" },
        @{ @"kind": @"samp_tex", @"reg": @0, @"arg_id": @1, @"msl_name": @"cp_t_tcb_8Smplr", @"msl_type": @"sampler" },
        @{ @"kind": @"lb", @"arg_id": @2, @"msl_name": @"s2a_lb", @"msl_type": @"constant float*" } ] };
    char ef[512]; REQUIRE(!nvn_refl_from_json(jf, &ffs->rf, ef, sizeof ef));
    REQUIRE(ffs->rf.nb == 3 && ffs->rf.b[1].kind == NVN_RB_SAMPT && ffs->rf.b[2].kind == NVN_RB_LB);
    NvProg *pr = [NvProg new]; pr->sh[0] = fvs; pr->sh[1] = ffs;
    memset(fprog, 0, sizeof *fprog); fprog->magic = MAGIC('P', 'R', 'O', 'G'); fprog->serial = nvn_new_serial(); serial_put(fprog->serial, pr);
    return ffs;
}
// 渲染目标 RGBA32F 4×4，注册为贴图 id：各一块存储、各一个池（存储重叠的两张贴图宿主会当成同一张）
static void rt_setup(tex_t *rt, int id) {
    uint8_t *m = NULL; REQUIRE(!posix_memalign((void **)&m, 65536, POOL)); memset(m, 0, POOL); nvn_be_pool_add(m, POOL);
    pool_t *p = calloc(1, sizeof *p); REQUIRE(p); *p = (pool_t){MAGIC('P', 'O', 'O', 'L'), NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_UNCACHED, m, POOL};
    memset(rt, 0, sizeof *rt); rt->magic = MAGIC('T', 'E', 'X', 0);
    rt->d = (nvn_texdesc){NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA32F, 0, 0, 4, 4, 1, 1, 0, 0}; nvn_tex_layout(&rt->d, &rt->L); REQUIRE(rt->L.size <= POOL);
    rt->pool = p; rt->mem = m; rt->serial = nvn_new_serial(); nvn_be_tex_init(rt); nvn_be_reg_tex(id, rt, NULL);
}
// 一笔绘制（一次提交、等完）：配置 c 的采样器（已 nvn_be_reg_samp 为 1 + c）画进 rt。直接设 S / R 状态后调 draw()，与计算路径直接调 dispatch() 一致；
//   不走 ops 流（p_bind_program 含 prog_t snap，放不进固定缓冲）
static void fs_draw(prog_t *fprog, tex_t *rt, int c) {
    S.prog = fprog; S.chmask.mask = 0xffffffffu;   // 颜色写掩码全开（游戏由 ChannelMaskState 设缺省；S 全零 = 什么都不写）
    nvn_be_sub_begin();
    R.rt.n = 1; R.rt.color[0] = rt; R.has_rt = 1;
    S.tex[1][0] = (uint64_t)TID | (uint64_t)(1 + c) << 20; args_dirty_all();   // 绑定变了：同 ops 流里的绑定操作，参数块重编
    p_draw dw = {.prim = 4, .first = 0, .count = 3, .instances = 1}; draw(&dw, NULL);
    uint64_t ff = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(ff, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
}
static unsigned pso_fc_set(void) {   // 已建渲染管线的模拟位集合（位 fc）
    unsigned got = 0; for (uint32_t i = 0; i < g_pso.cap; i++) if (g_pso.vals[i]) got |= 1u << ((const pso_key *)(g_pso.keys + (size_t)i * g_pso.klen))->fc; return got;
}
static void reg_case(int c) {   // 配置 c 的采样器注册为 1 + c
    int red, minf, magf, wrap; float bias; case_of(c, &red, &minf, &magf, &wrap, &bias); const float white[4] = {1, 1, 1, 1};
    samp_par sp; memset(&sp, 0, sizeof sp); sp.minf = (uint8_t)minf; sp.magf = (uint8_t)magf; sp.ws = sp.wt = sp.wr = (uint8_t)wrap; sp.reduction = (uint8_t)red;
    sp.lod_min = 0; sp.lod_max = 1000; sp.lod_bias = bias; sp.aniso = 1; memcpy(sp.border, c == NBD ? BORDER : white, sizeof white);
    nvn_be_reg_samp(1 + c, &sp);
}
// 后台编 + 替身（10-29 夜终版，nvn_mtl.m se_want / se_kick）：S2A_SAMP_EMU=1，片元绑 min 归约采样器（配置 0：线性无 mip、夹边）画两笔，采 (0.34375, 0.6875) 第 0 级：
//   fx = 2.25、fy = 5 → 足迹 (2, 5) 权重 0.75、(3, 5) 权重 0.25。期望全手算（val 两纹素，cpu_case = 其中小的那个）：
//   sync 0：第一笔 = main0 替身（采样器不带归约、取平均）→ 16 像素都严格落在 (min, max) 之间、渲染管线只有 fc 0；等变体编好（≤ 20 秒），第二笔 = min 逐位、多出 fc 2 的管线
//   sync 1（S2A_SE_SYNC=1）：第一笔就 = min 逐位，管线 fc 0 一条都不建
//   sync 2（包内，缺口族 31 出包预编：库容器 T_RED_PACK 里有 <键>_se.metallib，种类 51）：后台编队列扣住也不影响，第一笔就 = min 逐位、管线 fc 0 一条都不建（se_packed 同步载）
//   sync 3（包内批库，11-20）：同 sync 2，变体在两键合编的批库里（函数 s<键>_main0）；反证：宿主只认 main0 时这一路载不到、第一笔是替身 → 红
static int child_async(const char *fsmsl, int sync) {
    alarm(60);
    mtl_init();
    REQUIRE(g_red_emu);
    if (sync >= 2) { const char *pk = getenv(sync == 3 ? "T_RED_PACK_BATCH" : "T_RED_PACK"); REQUIRE(pk); g_msl_dir = @(pk); }
    tex_setup(); reg_case(0);
    static prog_t fprog; NvShader *ffs = fs_fixture(fsmsl, &fprog);
    static tex_t rt[2]; rt_setup(&rt[0], 9); rt_setup(&rt[1], 10);
    float a = val(0, 2, 5), b = val(0, 3, 5), lo = fminf(a, b), hi = fmaxf(a, b), mn = cpu_case(0, 0.34375f, 0.6875f, 0); REQUIRE(a != b && fb(mn) == fb(lo));
    const char *tag = sync == 3 ? "包内批库" : sync == 2 ? "包内预编" : sync ? "S2A_SE_SYNC=1" : "后台编";
    float px[16 * 4]; int n;
    // 后台编那一路先扣住 se_kick 的队列，第一笔读回后再放：编好前那一笔是替身由构造保证（10-30 列车 4 次红：gate-host 高负载时编码排在后台编完之后，
    //   第一笔已是变体、管线位集合 0x4；产品行为是对的——编好就用——错在单测假定了时序）
    if (sync != 1) dispatch_suspend(se_queue());   // 包内那一路也扣住：第一笔是变体只能来自包里，不是后台编抢先
    fs_draw(&fprog, &rt[0], 0); read_rt(&rt[0], px);
    unsigned fc1 = pso_fc_set();
    if (sync != 1) dispatch_resume(se_queue());
    if (sync) { n = 0; for (int i = 0; i < 16; i++) n += fb(px[4 * i]) == fb(mn);
        failures += n != 16 || fc1 != 1u << SE_RD; printf("%s %s 第一笔 = 变体：16 像素逐位等于 min 手算 %d / 16（期望 %.9g，首像素 %.9g）、管线位集合 %#x（期望 %#x）\n", n == 16 && fc1 == 1u << SE_RD ? "PASS" : "FAIL", tag, n, mn, px[0], fc1, 1u << SE_RD);
    } else { n = 0; for (int i = 0; i < 16; i++) n += px[4 * i] > lo && px[4 * i] < hi;
        failures += n != 16 || fc1 != 1u; printf("%s %s 第一笔 = main0 替身（取平均）：16 像素严格在 (%.9g, %.9g) 之间 %d / 16（首像素 %.9g）、管线位集合 %#x（期望 0x1）\n", n == 16 && fc1 == 1u ? "PASS" : "FAIL", tag, lo, hi, n, px[0], fc1);
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); int ready = 0;
        while (!(ready = se_fn(ffs, SE_RD) != nil) && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 < 20000000000ull) usleep(10000);
        failures += !ready; printf("%s %s 变体后台编好：%s（等了 %.0f ms）\n", ready ? "PASS" : "FAIL", tag, ready ? "是" : "20 秒没好", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        fs_draw(&fprog, &rt[1], 0); read_rt(&rt[1], px); unsigned fc2 = pso_fc_set();
        n = 0; for (int i = 0; i < 16; i++) n += fb(px[4 * i]) == fb(mn);
        failures += n != 16 || fc2 != (1u | 1u << SE_RD); printf("%s %s 第二笔 = 变体：16 像素逐位等于 min 手算 %d / 16（期望 %.9g，首像素 %.9g）、管线位集合 %#x（期望 %#x）\n", n == 16 && fc2 == (1u | 1u << SE_RD) ? "PASS" : "FAIL", tag, n, mn, px[0], fc2, 1u | 1u << SE_RD);
    }
    nvn_be_drain();
    return failures != 0;
}
static int child(const char *msl, int m3, int emu, const char *dump, const char *fsmsl) {   // msl / fsmsl：原样（库里的 main0）；变体在兜底目录（父进程放好）
    alarm(60);
    mtl_init();
    REQUIRE(g_m3 == m3 && (!emu || (g_red_emu && g_lb_emu)));   // S2A_SAMP_EMU=1 → 两项都走着色器；缺省按本机能力（M5：都原生）
    NSError *e = nil; NSString *src = [NSString stringWithContentsOfFile:@(msl) encoding:NSUTF8StringEncoding error:&e]; REQUIRE(src);
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String);
    REQUIRE(lib);
    NvShader *sh = fixture(lib);
    static prog_t prog; memset(&prog, 0, sizeof prog); prog.magic = MAGIC('P', 'R', 'O', 'G'); prog.serial = nvn_new_serial();
    { NvProg *o = [NvProg new]; o->sh[5] = sh; serial_put(prog.serial, o); }
    tex_setup();
    // 位置与输出：CPU 可见池
    uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 16384, POOL)); memset(mem, 0xa5, POOL); nvn_be_pool_add(mem, POOL);
    points((float (*)[4])mem);
    nvn_be_sub_begin();
    for (int c = 0; c < NRUN; c++) {
        reg_case(c);
        S.cprog = &prog; S.tex[5][0] = (uint64_t)TID | (uint64_t)(1 + c) << 20;   // 组合句柄：贴图 ID | 采样器 ID << 20（samp_tex 取高位）
        S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + OUT_OFF + (size_t)c * NPAD * 4), .size = NPAD * 4};
        S.ssbo[5][1] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)mem, .size = NPAD * 16};
        p_dispatch d = {.x = NPAD / 64, .y = 1, .z = 1}; dispatch(&d);
    }
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    static float P[NPAD][4]; points(P);
    const float *out = (const float *)(mem + OUT_OFF);
    const char *path = emu ? "S2A_SAMP_EMU=1（着色器归约 / 偏置）" : g_red_emu || g_lb_emu ? "本机能力（部分着色器模拟）" : "本机能力（Metal 26 原生 reductionMode / lodBias）";
    for (int c = 0; c < NRUN; c++) {
        if (c == NCASE) continue;   // 反证项另算
        int red, minf, magf, wrap; float bias; case_of(c, &red, &minf, &magf, &wrap, &bias); int eq = 0, first = -1;
        for (int i = 0; i < NP; i++) { float x = cpu_case(c, P[i][0], P[i][1], P[i][2]), g = out[c * NPAD + i]; if (c == NBD ? fabsf(g - x) <= 1e-5f : fb(g) == fb(x)) eq++; else if (first < 0) first = i; }
        failures += eq != NP;
        printf("%s Metal %d %s %s 缩小过滤 %d 放大 %d 寻址 %d 偏置 %g：%s手算 %d / %d", eq == NP ? "PASS" : "FAIL", m3 ? 3 : 4, path, c == NBD ? "边界色 (0.25,0.5,0.75,0.6)" : red == 1 ? "min" : red == 2 ? "max" : "普通",
               minf, magf, wrap, bias, c == NBD ? "等于（容差 1e-5）" : "逐位等于", eq, NP);
        if (first >= 0) printf("；首个不等 u %g v %g lod %g：GPU %.9g 期望 %.9g", P[first][0], P[first][1], P[first][2], out[c * NPAD + first], cpu_case(c, P[first][0], P[first][1], P[first][2]));
        putchar('\n');
    }
    { int ne = 0; for (int i = 0; i < NP; i++) ne += fb(out[NCASE * NPAD + i]) != fb(cpu_red(1, 5, 7, P[i][0], P[i][1], P[i][2]));
      failures += !ne; printf("%s Metal %d 反证：不带归约的采样器（取平均）与 min 期望对不上 %d 处（要 > 0）\n", ne ? "PASS" : "FAIL", m3 ? 3 : 4, ne); }
    // 选入口（dispatch → red_want）：模拟路径 = 归约 / 带偏置的配置走 main0_r（g_cps_red 一条管线）、不带归约也不带偏置的那一项（反证）仍走 main0（g_cps 一条）；原生路径全走 main0。
    //   期望手写，不跑被测实现；反证那一项的输出另由主进程跨路对拍原生读回（dump 含第 NCASE 项）
    // 守卫：计算管线的模拟位集合 = 各配置期望手写的模拟位集合（去 0）；main0 那条在（反证一项 / 原生路径都走它）。本机两项都原生时变体管线 0 条、变体库没载过
    { unsigned want = 0, got = 0; for (int c = 0; c < NRUN; c++) { int f = want_fc(c, g_red_emu, g_lb_emu); if (f) want |= 1u << f; }
      for (uint32_t i = 0; i < g_cps_se.cap; i++) if (g_cps_se.vals[i]) { const cps_se_key *k = (const cps_se_key *)(g_cps_se.keys + (size_t)i * g_cps_se.klen); got |= k->cs == (__bridge const void *)sh ? 1u << k->fc : 1u << 8; }
      const void *k0 = (__bridge const void *)sh; int nm = hm_get_id(&g_cps, &k0) != nil;
      int loaded = se_fn(sh, SE_RD) != nil, ok = nm && got == want && loaded == (want != 0);
      failures += !ok; printf("%s Metal %d 计算模拟位：变体管线位集合 %#x（期望 %#x：按配置要的归约 / 边界色 2）、main0 管线 %d、变体库%s载入\n", ok ? "PASS" : "FAIL", m3 ? 3 : 4, got, want,
                              nm, loaded ? "已" : "未"); }
    FILE *df = fopen(dump, "wb"); REQUIRE(df); REQUIRE(fwrite(out, 4, (size_t)NRUN * NPAD, df) == (size_t)NRUN * NPAD); fclose(df);

    // 片元路径测试（10-28）：走真 draw（带渲染目标）→ red_want 选 main0_r → pso_get_ 选 fn_r → red_bind（26 号槽）；核对渲染管线选择
    //   三次绘制：min 归约采样器、只带 LOD 偏置的普通采样器（模拟路径都走 main0_r，pso_key.red=1）、不带归约也不带偏置的采样器（走 main0，pso_key.red=0）
    {
        static prog_t fprog; NvShader *ffs = fs_fixture(fsmsl, &fprog);
        // 三笔绘制各画进自己的 RGBA32F 4×4（各一次提交）：c 0 min 归约采样器、c 1 只带 LOD 偏置的普通采样器、c 2 普通采样器（不归约不偏置，走 main0）
        static const int FC[3] = {0, NCASE + 1 + NBR, NCASE}; static tex_t frt[3];
        for (int c = 0; c < 3; c++) rt_setup(&frt[c], 9 + c);
        // 直接设 S / R 状态后调 draw()，与计算路径直接调 dispatch() 一致；不走 ops 流（p_bind_program 含 prog_t snap，放不进固定缓冲）
        for (int c = 0; c < 3; c++) fs_draw(&fprog, &frt[c], FC[c]);
        // 守卫：渲染管线的模拟位集合 = 三笔期望手写的（去 0）+ main0（c 2 不要模拟）
        unsigned want = 1, got = 0;   // 位 0：fc 0（main0）那条
        for (int c = 0; c < 3; c++) want |= 1u << want_fc(FC[c], g_red_emu, g_lb_emu);
        got = pso_fc_set();
        int ok_fs = got == want && (want == 1) == !se_fn(ffs, SE_RD);
        failures += !ok_fs; printf("%s Metal %d 片元模拟位：渲染管线位集合 %#x（期望 %#x）、变体库%s载入\n", ok_fs ? "PASS" : "FAIL", m3 ? 3 : 4, got, want, se_fn(ffs, SE_RD) ? "已" : "未");
        // 读数：片元采 (0.34375, 0.6875) level 0（第 0 级 fx = 2.25、fy = 5：足迹 (2, 5)、(3, 5)），c 0 期望 = min 归约手算、c 1 = 最近点 + mip 最近 LOD 0 + 1.25 手算，逐位、16 像素
        for (int c = 0; c < 2; c++) {
            float wantv = cpu_case(FC[c], 0.34375f, 0.6875f, 0), px[16 * 4]; int eq = 0;
            read_rt(&frt[c], px);
            for (int i = 0; i < 16; i++) eq += fb(px[4 * i]) == fb(wantv);
            failures += eq != 16; printf("%s Metal %d 片元读数 %s：16 像素逐位等于手算 %d / 16（期望 %.9g，首像素 %.9g）\n", eq == 16 ? "PASS" : "FAIL", m3 ? 3 : 4, c ? "LOD 偏置 1.25" : "min 归约", eq, wantv, px[0]);
        }
        // 变体来源（10-29 夜终版：库里不带归约变体，只在设备上编）：用到变体的着色器各编好一次、失败 0；两项都原生 = 都 0。期望按 want_fc 手算用到变体的着色器数
        { int nuse = 0; for (int c = 0; c < NRUN; c++) if (want_fc(c, g_red_emu, g_lb_emu)) { nuse++; break; }
          for (int c = 0; c < 3; c++) if (want_fc(FC[c], g_red_emu, g_lb_emu)) { nuse++; break; }
          uint64_t se[2]; mtl_se_stats(se); int ok = se[0] == (uint64_t)nuse && se[1] == 0;
          failures += !ok; printf("%s Metal %d 变体来源：设备编好 %llu / 失败 %llu（期望 %d / 0：%s）\n", ok ? "PASS" : "FAIL", m3 ? 3 : 4, (unsigned long long)se[0], (unsigned long long)se[1],
                                  nuse, nuse ? "兜底目录的设备端变体" : "本机两项都原生"); }
    }

    nvn_be_drain();
    return failures != 0;
}

// 子进程 stderr（文件）里有没有一行完全符合「[s2a] 归约变体：程序号 <16 位十六进制> 着色器 FS_KEY <how> <x.y> ms」（普查按这一正则汇总）；line：命中的那行
static int log_has(const char *path, const char *how, char *line, size_t n) {
    char pat[300]; snprintf(pat, sizeof pat, "^\\[s2a\\] 归约变体：程序号 [0-9A-F]{16} 着色器 %s %s [0-9]+\\.[0-9] ms$", FS_KEY, how);
    regex_t re; REQUIRE(!regcomp(&re, pat, REG_EXTENDED | REG_NOSUB));
    FILE *f = fopen(path, "r"); int hit = 0; char l[4096]; line[0] = 0;
    while (f && !hit && fgets(l, sizeof l, f)) { l[strcspn(l, "\n")] = 0; if (!regexec(&re, l, 0, NULL, 0)) { hit = 1; strlcpy(line, l, n); } }
    if (f) fclose(f); regfree(&re); return hit;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 7 && !strcmp(argv[1], "--child")) return child(argv[2], atoi(argv[3]), atoi(argv[4]), argv[5], argv[6]);
        if (argc == 4 && !strcmp(argv[1], "--async")) return child_async(argv[2], atoi(argv[3]));
        // argv[1] / [2] = 计算核原样 / 变体，argv[3] / [4] = 片元核原样 / 变体（t_red.py --emit / --emit-fs）
        REQUIRE(argc == 5);
        int os26 = 0; if (@available(macOS 26.0, *)) os26 = 1;
        char tmpl[] = "/tmp/t_nvn_red.XXXXXX"; REQUIRE(mkdtemp(tmpl));
        // 兜底目录照设备上的样子放：<键>_b.metal（这支的翻译）+ <键>_b.json（本链）+ 之后写的 <键>_se.metal（变体，不比源码旧：dm_shader_se_fresh）
        char fbd[300]; snprintf(fbd, sizeof fbd, "%s/fb", tmpl); REQUIRE(!mkdir(fbd, 0755));
        for (int i = 0; i < 2; i++) { const char *key = i ? FS_KEY : CS_KEY, *src[2] = {argv[1 + 2 * i], argv[2 + 2 * i]}, *ext[2] = {"_b.metal", "_se.metal"};
            char p[400]; snprintf(p, sizeof p, "%s/%s_b.json", fbd, key); FILE *f = fopen(p, "w"); REQUIRE(f); fprintf(f, "{\"chain\": \"%s\", \"xfp\": \"%s\"}\n", DMSH_CHAIN, s2a_dsh_xfp()); fclose(f);
            for (int k = 0; k < 2; k++) { NSString *t = [NSString stringWithContentsOfFile:@(src[k]) encoding:NSUTF8StringEncoding error:nil]; REQUIRE(t);
                snprintf(p, sizeof p, "%s/%s%s", fbd, key, ext[k]); REQUIRE([t writeToFile:@(p) atomically:NO encoding:NSUTF8StringEncoding error:nil]); } }
        setenv("DM_MSL_FALLBACK", fbd, 1);
        // {Metal 3?, S2A_SAMP_EMU=1?}：模拟那两路带 S2A_SE_SYNC=1（首遇同步现编，第一笔起就是变体，逐配置读数才可比）；后台编 + 替身另由下面两路 --async 核
        static const int runs[4][2] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
        unsigned bad = 0, nrun = 0; char dumps[4][256];
        for (int r = 0; r < 4; r++) { int m3 = runs[r][0], emu = runs[r][1];
            snprintf(dumps[r], sizeof dumps[r], "%s/out%d.bin", tmpl, r);
            if (!emu && !os26) { printf("SKIP Metal %d 原生 reductionMode：系统早于 macOS 26\n", m3 ? 3 : 4); dumps[r][0] = 0; continue; }
            char user[300]; snprintf(user, sizeof user, "%s/pso_user%d.tsv", tmpl, r);
            fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
            if (!pid) {
                if (m3) setenv("NXGAL_BE", "mtl3", 1); else unsetenv("NXGAL_BE");
                // 本机能力那一路也带 S2A_SE_SYNC=1（10-30 列车线：在没有原生归约的 GPU 上——gate-host 的 M4 Pro——「本机能力」本身就走着色器模拟，不带同步现编时
                //   第一笔是 main0 替身（取平均），逐配置读数和片元读数都对不上，门禁在 gate-host 上 3 项红；Apple10 上不需要模拟，这个开关不起作用。后台编 + 替身由下面两路 --async 专门核）
                if (emu) setenv("S2A_SAMP_EMU", "1", 1); else unsetenv("S2A_SAMP_EMU");
                setenv("S2A_SE_SYNC", "1", 1);
                setenv("DM_NVN_ENC_THREAD", "0", 1); setenv("DM_PRESENT_LINK", "0", 1); setenv("DM_PSO_USER", user, 1);
                execl(argv[0], argv[0], "--child", argv[1], m3 ? "1" : "0", emu ? "1" : "0", dumps[r], argv[3], (char *)NULL); _exit(127);
            }
            int st = 0; pid_t w; do { w = waitpid(pid, &st, 0); } while (w < 0 && errno == EINTR); REQUIRE(w == pid);
            int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0; bad += !ok; nrun++; unlink(user);
            printf("%s process Metal %d %s (status=%d)\n", ok ? "PASS" : "FAIL", m3 ? 3 : 4, emu ? "S2A_SAMP_EMU=1 S2A_SE_SYNC=1" : "native", st);
        }
        // 包内预编（缺口族 31）：片元变体用 xcrun metal 编成 <键>_se.metallib，出库的打包（C# LibPack.PackFiles，dsh_batch --libpack pack）打进 b-<链> 库容器（种类 51）
        char pkd[400], pks[400]; snprintf(pkd, sizeof pkd, "%s/pk/b-%s", tmpl, DMSH_CHAIN); snprintf(pks, sizeof pks, "%s/pk/src", tmpl);
        { char cmd[1600]; snprintf(cmd, sizeof cmd, "mkdir -p '%s' && xcrun -sdk macosx metal -fpreserve-invariance '%s' -o '%s/%s_se.metallib' && python3 translator/dsh_batch.py --libpack pack '%s' '%s' %s > /dev/null",
                                   pks, argv[4], pks, FS_KEY, pks, pkd, DMSH_CHAIN);
          fflush(NULL); int rc = system(cmd); REQUIRE(rc == 0); setenv("T_RED_PACK", pkd, 1); }
        // 包内批库（11-20 出包提速，S2A.Dsh Build.SeFinish）：变体按批合编，源码出自生产 Unity.VarSrc（dsh_batch --unity var-src：函数改名 s<键>_main0、折行标记核 s<键>_main0_fold），
        //   本键与另一个键同批、两键的 <键>_se.metallib 是同一份字节；宿主 se_packed 按 s<键>_main0 取，第一笔就 = min 逐位（同包内预编那一路）
        char pbd[400], pbs[400]; snprintf(pbd, sizeof pbd, "%s/pkb/b-%s", tmpl, DMSH_CHAIN); snprintf(pbs, sizeof pbs, "%s/pkb/src", tmpl);
        { char cmd[2400]; snprintf(cmd, sizeof cmd, "mkdir -p '%s' && python3 translator/dsh_batch.py --unity var-src '%s/batch.metal' %s '%s' ffff00000000000e '%s' && xcrun -sdk macosx metal -fpreserve-invariance '%s/batch.metal' -o '%s/%s_se.metallib' "
                                   "&& cp '%s/%s_se.metallib' '%s/ffff00000000000e_se.metallib' && rm '%s/batch.metal' && python3 translator/dsh_batch.py --libpack pack '%s' '%s' %s > /dev/null",
                                   pbs, pbs, FS_KEY, argv[4], argv[4], pbs, pbs, FS_KEY, pbs, FS_KEY, pbs, pbs, pbs, pbd, DMSH_CHAIN);
          fflush(NULL); int rc = system(cmd); REQUIRE(rc == 0); setenv("T_RED_PACK_BATCH", pbd, 1); }
        // 后台编 + 替身：S2A_SAMP_EMU=1、Metal 4，缺省（后台编）/ S2A_SE_SYNC=1 / 包内预编三路；stderr 存文件核编好那一行的格式
        for (int sync = 0; sync < 4; sync++) {
            char user[300], elog[300]; snprintf(user, sizeof user, "%s/pso_user_a%d.tsv", tmpl, sync); snprintf(elog, sizeof elog, "%s/err_a%d.log", tmpl, sync);
            fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
            if (!pid) {
                int fd = open(elog, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0 || dup2(fd, 2) < 0) _exit(126);
                unsetenv("NXGAL_BE"); setenv("S2A_SAMP_EMU", "1", 1); if (sync) setenv("S2A_SE_SYNC", "1", 1); else unsetenv("S2A_SE_SYNC");
                setenv("DM_NVN_ENC_THREAD", "0", 1); setenv("DM_PRESENT_LINK", "0", 1); setenv("DM_PSO_USER", user, 1);
                execl(argv[0], argv[0], "--async", argv[3], sync == 3 ? "3" : sync == 2 ? "2" : sync ? "1" : "0", (char *)NULL); _exit(127);
            }
            int st = 0; pid_t w; do { w = waitpid(pid, &st, 0); } while (w < 0 && errno == EINTR); REQUIRE(w == pid);
            int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0; bad += !ok; nrun++; unlink(user);
            printf("%s process Metal 4 S2A_SAMP_EMU=1 %s (status=%d)\n", ok ? "PASS" : "FAIL", sync == 3 ? "包内批库" : sync == 2 ? "包内预编" : sync ? "S2A_SE_SYNC=1" : "后台编 + 替身", st);
            char line[4096]; const char *how = sync >= 2 ? "包内完成" : sync ? "同步现编完成" : "后台编完成"; int hit = log_has(elog, how, line, sizeof line);
            bad += !hit; printf("%s 日志行格式（%s）：%s\n", hit ? "PASS" : "FAIL", how, hit ? line : "没有符合「[s2a] 归约变体：程序号 <16 位> 着色器 <键> … <x.y> ms」的行");
            if (!ok || !hit) { char cmd[400]; snprintf(cmd, sizeof cmd, "tail -40 '%s'", elog); fflush(NULL); system(cmd); }
            unlink(elog);
        }
        // 四路输出两两逐位相等（原生 vs 模拟、Metal 4 vs 3）
        static uint8_t ref[NRUN * NPAD * 4], cur[NRUN * NPAD * 4]; int have = 0, same = 1, ncmp = 0;
        for (int r = 0; r < 4; r++) { if (!dumps[r][0]) continue; FILE *f = fopen(dumps[r], "rb"); if (!f) { same = 0; continue; }
            size_t n = fread(have ? cur : ref, 1, sizeof cur, f); fclose(f); if (n != sizeof cur) { same = 0; continue; }
            if (have) { same &= !memcmp(ref, cur, sizeof cur); ncmp++; } have = 1; unlink(dumps[r]); }
        for (int i = 0; i < 2; i++) for (int k = 0; k < 3; k++) { char p[400]; snprintf(p, sizeof p, "%s/%s%s", fbd, i ? FS_KEY : CS_KEY, k == 0 ? "_b.json" : k == 1 ? "_b.metal" : "_se.metal"); unlink(p); }
        rmdir(fbd); { char cmd[500]; snprintf(cmd, sizeof cmd, "rm -rf '%s/pk' '%s/pkb'", tmpl, tmpl); system(cmd); } rmdir(tmpl);
        bad += !same || !ncmp;
        printf("%s 各路输出逐位相等：%d 路对第 1 路，各 %d 个配置（含反证一项）× %d 个位置\n", same && ncmp ? "PASS" : "FAIL", ncmp, NRUN, NP);
        if (bad) printf("✗ t_nvn_red：%u 路子进程 + 跨路对拍，%u 项不过\n", nrun, bad);
        else printf("✓ t_nvn_red：%u 路子进程（本机能力 / S2A_SAMP_EMU=1 同步现编 × Metal 4 / 3，后台编 + 替身 / S2A_SE_SYNC=1 / 包内预编三路）全过，跨路逐位相等（%d 配置 × %d 位置）\n", nrun, NRUN, NP);
        return bad != 0;
    }
}
