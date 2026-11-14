// 张量核网络顶替的输出域（11-05 时之笛游玩画面整屏发白，nvn_tensor.inc 文件头）：出口层的输出 = 它读的低分辨率画面逐分量带符号平方 + 网络残差时，
//   顶替要把输入平方后再放大；不带平方的出口层照原样放大。生产 nvn_mtl.m（包含）+ 真 Metal 设备 + MetalFX 空间放大。
// 夹具：64x64 RGB9E5 输入（贴图 ID 7，计算阶段纹理槽 0）、128x128 R11G11B10F 输出（贴图 ID 8，图像槽 0），整张图同一个值 (0.5, 0.25, 2.0)：
//   RGB9E5 打包 = 尾数 R 64、G 32、B 256、指数 17 → 值 = 尾数 × 2^(17−15−9) = 尾数 / 128 → 0.5 / 0.25 / 2.0，字 0x8C004040（手算）。
//   常数图经 MetalFX 空间放大仍近似常数，但它的 HDR 往返带一个整体增益 g（11-05 M5 Max 实测约 0.95–0.97，不是被测实现给的），所以：
//   ① tensor_sq = 32（出口层有 32 条 HMUL2 R, R, |R|，同 fa3033d05c0a41d6）→ 输出 ≈ g·(0.25, 0.0625, 4.0)（0.5² / 0.25² / 2.0²）
//   ② tensor_sq = 0（标题画面那种读写同域的网络）→ 输出 ≈ g·(0.5, 0.25, 2.0)，与改前相同
//   判据：绝对值容差 8%（含 g）；与 g 无关的那条：① / ② 逐分量 = 输入本身 (0.5, 0.25, 2.0)（x² / x = x），容差 4%（R11G11B10 量化）——不平方时这个比是 1
// 有效区域（第十九版：只有左上 1/4 是画面）：③ ④ 换一个带推常量槽 0 的出口层，输入图改成左上 32x32 = A (0.5, 0.25, 2.0)、其余 = B (2, 2, 2)
//   （RGB9E5 尾数 256 / 256 / 256、指数 17 → 字 0x8C020100，手算），推常量按出口层的排法（nvn_tensor.inc 文件头）：
//   ③ 输出起点 (0,0)、宽高 128x128、步长 c[6].zw = (32/64)/128 = 1/256 → 输入有效 128 × 1/256 × 64 = 32x32 → 整张输出都是 A 的平方：
//      像素 (120,120) ≈ g·(0.25, 0.0625, 4)；不按有效区域（整张输入）时 (120,120) 对到输入 (60,60) = B → ≈ g·(4, 4, 4)
//   ④ 输出起点 (64,64)、宽高 64x64、步长 1/64 → 输入有效 64x64（整张）放大进输出右下 64x64：(80,80) 对到输入 16.5 → A²（R ≈ 0.25）；
//      (120,120) 对到 56.5 → B²（R ≈ 4）；(32,32) 不在区域里，保持 ③ 的 A²（R ≈ 0.25）。不按输出区域（整张输出）时 (80,80) 对到输入 40 → B²（R ≈ 4）
//   ⑤ 推常量不成立（宽 0）→ 照整张图，计数不加
// ⑥ 诊断开关 DM_NVN_TENSOR_STANDIN=0：出口层不顶替、输出图逐位不变；撤掉恢复。负对照（11-11 手工）：去掉 tensor_standin 开头的开关判断 → ⑥ 放大 1 次、关计数 0，两项红
// 每种情形顶替两次、读第二次的输出：新建的 MetalFX 空间放大器（Metal 4）头一次编码约 1/10 写出全 0（11-05 改前代码同样复现：同格式第二个提交里新建放大器 40 次 4 次全 0，
//   是既有现象、不归本单测管，记在 docs/坑记录.md），第二次起稳定
// 负对照（11-05 手工做过，写进报告）：把 tensor_standin 里 in 的取法改回恒为 c（= 改前）→ ① 红（实测输出 0.484 / 0.244 / 1.94、①/② = 1 / 1 / 1）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { POOL_SIZE = 4 << 20, TID_C = 7, TID_O = 8, CW = 64, CH = 64, OW = 128, OH = 128 };
static int near(float v, float want, float tol) { return fabsf(v - want) <= tol * want; }

static void reg_tex(tex_t *t, pool_t *pool, uint8_t *mem, uint64_t off, int fmt, uint32_t w, uint32_t h, int tid) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial(); t->pool = pool; t->off = off; t->mem = mem + off;
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .width = w, .height = h, .depth = 1, .levels = 1};
    nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t); nvn_be_reg_tex(tid, t, NULL);
}
// 输出图中心一个纹素的 RGB：下一个提交里在生产队列上（队列顺序 + 全屏障排在放大之后）拷进共享缓冲区，等提交完成后在 CPU 上解 R11G11B10F（不经被测实现）
static float uf(uint32_t m, uint32_t e, int mb) { return e ? ldexpf(1.0f + (float)m / (float)(1 << mb), (int)e - 15) : ldexpf((float)m / (float)(1 << mb), -14); }
static void read_at(id<MTLTexture> o, NSUInteger x, NSUInteger y, float out[3]) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; memset(b.contents, 0, 256); res_add(b);
    nvn_be_sub_begin(); rp_flush();
    enc_b_copy_texture_buffer(blit(), o, 0, 0, MTLOriginMake(x, y, 0), MTLSizeMake(1, 1, 1), b, 0, 256, 256); enc_close_blit();
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    uint32_t v = *(const uint32_t *)b.contents;   // R11G11B10F：R 位 0..10（尾数 6、指数 5）、G 11..21、B 22..31（尾数 5、指数 5）
    out[0] = uf(v & 63, (v >> 6) & 31, 6); out[1] = uf((v >> 11) & 63, (v >> 17) & 31, 6); out[2] = uf((v >> 22) & 31, (v >> 27) & 31, 5);
}
static void standin(NvShader *cs) {
    nvn_be_sub_begin();
    S.tex[5][0] = TID_C; S.img[5][0] = TID_O;
    tensor_standin(cs);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    if (!dlss_class("MTLFXSpatialScalerDescriptor")) { printf("✓ t_nvn_tensor_sq：跳过（这台设备没有 MetalFX 空间放大）\n"); return 0; }
    uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, POOL_SIZE)); memset(mem, 0, POOL_SIZE);
    pool_t pool = {.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = POOL_SIZE};
    nvn_be_pool_add(mem, POOL_SIZE);
    // 输入图是 GPU 画出来的低分辨率画面（游戏里是渲染目标 / 着色器图像），③ ④ 的新内容也由测试在 GPU 上直接拷进去、不经存储：按 NVN 语义贴图内容就是存储，
    //   绕过存储改内容只有 GPU 写这一条路，而后端在录 GPU 写时把池记成 GPU 写过（hle_nvn.c SetRenderTargets / 清贴图 / 拷进贴图，nvn_be_pool_gpu_written）。
    //   这里同样先记上，否则首用取存储（tex_cpu_content）按「GPU 没写过的池里的未压缩贴图 = CPU 写的内容」把它当随包贴图，
    //   本进程池没登记脏页跟踪，每次用到都从存储（整张 A）重传，盖掉测试拷进去的 A / B 图（11-06 列车退回：④ (120,120) 读到 A²）
    nvn_be_pool_gpu_written(&pool);
    tex_t tc, to;
    reg_tex(&tc, &pool, mem, 65536, NVN_FORMAT_RGB9E5F, CW, CH, TID_C);
    reg_tex(&to, &pool, mem, 1 << 20, NVN_FORMAT_R11G11B10F, OW, OH, TID_O);
    for (uint32_t i = 0; i < CW * CH; i++) ((uint32_t *)tc.mem)[i] = 0x8C004040u;   // 池里也放同一个值（整张同值，与块线性排布无关）：首次用时从存储填初值也是它
    nvn_be_sub_begin(); id<MTLTexture> c = tex_mtl(&tc), o = tex_mtl(&to); uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(c && o && c.pixelFormat == MTLPixelFormatRGB9E5Float && o.pixelFormat == MTLPixelFormatRG11B10Float);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; REQUIRE(q);
    {   // 测试自己填输入（不经被测实现）
        id<MTLBuffer> src = [g_dev newBufferWithLength:CW * CH * 4 options:MTLResourceStorageModeShared]; for (int i = 0; i < CW * CH; i++) ((uint32_t *)src.contents)[i] = 0x8C004040u;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:CW * 4 sourceBytesPerImage:CW * CH * 4 sourceSize:MTLSizeMake(CW, CH, 1) toTexture:c destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    }
    NvShader *cs = [NvShader new]; snprintf(cs->key, sizeof cs->key, "tensor_sq_test"); cs->stage = 5; cs->tensor = 1;
    cs->rf.b = calloc(2, sizeof *cs->rf.b); REQUIRE(cs->rf.b);   // NvShader frees it
    cs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .rw = 1}; cs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0}; cs->rf.nb = 2;
    float v[3], w[3];
    // ①
    cs->tensor_sq = 32; uint64_t up0 = g_tensor_up, sq0 = g_tensor_sq_runs;
    standin(cs); standin(cs); read_at(tex_mtl(&to), OW / 2, OH / 2, v);
    VERIFY(g_tensor_up == up0 + 2 && g_tensor_sq_runs == sq0 + 2, "① 放大 2 次（实 %llu）、平方一遍 2 次（实 %llu）", (unsigned long long)(g_tensor_up - up0), (unsigned long long)(g_tensor_sq_runs - sq0));
    VERIFY(near(v[0], 0.25f, 0.08f) && near(v[1], 0.0625f, 0.08f) && near(v[2], 4.0f, 0.08f), "① 出口层平方域：输出 (%g, %g, %g)（期望 ≈ 0.25, 0.0625, 4）", v[0], v[1], v[2]);
    // ②
    cs->tensor_sq = 0; cs->tensor_log = 0; up0 = g_tensor_up; sq0 = g_tensor_sq_runs;
    standin(cs); standin(cs); read_at(tex_mtl(&to), OW / 2, OH / 2, w);
    VERIFY(g_tensor_up == up0 + 2 && g_tensor_sq_runs == sq0, "② 放大 2 次（实 %llu）、平方 0 次（实 %llu）", (unsigned long long)(g_tensor_up - up0), (unsigned long long)(g_tensor_sq_runs - sq0));
    VERIFY(near(w[0], 0.5f, 0.08f) && near(w[1], 0.25f, 0.08f) && near(w[2], 2.0f, 0.08f), "② 读写同域：输出 (%g, %g, %g)（期望 ≈ 0.5, 0.25, 2）", w[0], w[1], w[2]);
    VERIFY(w[0] > 0 && w[1] > 0 && w[2] > 0 && near(v[0] / w[0], 0.5f, 0.04f) && near(v[1] / w[1], 0.25f, 0.04f) && near(v[2] / w[2], 2.0f, 0.04f),
           "①/② 逐分量 (%g, %g, %g)（期望 = 输入 0.5, 0.25, 2；不平方时为 1）", v[0] / w[0], v[1] / w[1], v[2] / w[2]);
    // ⑦ sRGB 域出口层（11-14 一款体育游戏画面发白，nvn_tensor.inc 文件头「输出域之二」）：tensor_srgb = 48、tensor_sq = 0 → 输入逐分量 sRGB 解码后放大：
    //   期望 ≈ g·(0.2140, 0.0509, 4.954)（((x + 0.055) / 1.055)^2.4，手算）。g 随像素最亮分量变（11-14 M 系实测：最亮 2 → 0.97、4 → 0.95、4.95 → 0.91），
    //   所以绝对值容差 12%，与 g 无关的那条看同一像素的分量比：R/B = 0.04321、G/B = 0.01027（不解码时 0.25 / 0.125），容差 5%（R11G11B10 量化）。
    //   负对照（11-14 手工）：tensor_standin 里 dom 恒取 0（= 改前）→ ⑦ 计数与两项数值都红（输出 ≈ ② 本身、R/B 0.25）
    cs->tensor_srgb = 48; cs->tensor_log = 0; up0 = g_tensor_up; sq0 = g_tensor_sq_runs; uint64_t sr0 = g_tensor_srgb_runs; float x7[3];
    standin(cs); standin(cs); read_at(tex_mtl(&to), OW / 2, OH / 2, x7);
    VERIFY(g_tensor_up == up0 + 2 && g_tensor_srgb_runs == sr0 + 2 && g_tensor_sq_runs == sq0, "⑦ 放大 2 次（实 %llu）、sRGB 解码 2 次（实 %llu）、平方 0 次（实 %llu）",
           (unsigned long long)(g_tensor_up - up0), (unsigned long long)(g_tensor_srgb_runs - sr0), (unsigned long long)(g_tensor_sq_runs - sq0));
    VERIFY(near(x7[0], 0.2140f, 0.12f) && near(x7[1], 0.0509f, 0.12f) && near(x7[2], 4.954f, 0.12f), "⑦ 出口层 sRGB 域：输出 (%g, %g, %g)（期望 ≈ 0.214, 0.0509, 4.95）", x7[0], x7[1], x7[2]);
    VERIFY(x7[2] > 0 && near(x7[0] / x7[2], 0.04321f, 0.05f) && near(x7[1] / x7[2], 0.01027f, 0.05f),
           "⑦ 同像素分量比 R/B %g、G/B %g（期望 0.0432、0.0103；不解码时 0.25、0.125）", x7[0] / x7[2], x7[1] / x7[2]);
    {   // 平方域优先：两种计数都有时照平方（tensor_sq 先判）
        cs->tensor_sq = 32; cs->tensor_log = 0; sq0 = g_tensor_sq_runs; sr0 = g_tensor_srgb_runs;
        standin(cs);
        VERIFY(g_tensor_sq_runs == sq0 + 1 && g_tensor_srgb_runs == sr0, "⑦ 平方与 sRGB 都有：平方 %llu 次、解码 %llu 次（期望 1 / 0）", (unsigned long long)(g_tensor_sq_runs - sq0), (unsigned long long)(g_tensor_srgb_runs - sr0));
        cs->tensor_sq = 0; cs->tensor_srgb = 0; cs->tensor_log = 0;
    }
    {   // ③ ④ 的输入：左上 32x32 = A、其余 = B（测试自己填）
        id<MTLBuffer> src = [g_dev newBufferWithLength:CW * CH * 4 options:MTLResourceStorageModeShared];
        for (int y = 0; y < CH; y++) for (int x = 0; x < CW; x++) ((uint32_t *)src.contents)[y * CW + x] = x < 32 && y < 32 ? 0x8C004040u : 0x8C020100u;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:CW * 4 sourceBytesPerImage:CW * CH * 4 sourceSize:MTLSizeMake(CW, CH, 1) toTexture:tex_mtl(&tc) destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    }
    NvShader *cr = [NvShader new]; snprintf(cr->key, sizeof cr->key, "tensor_rect_test"); cr->stage = 5; cr->tensor = 1; cr->tensor_sq = 32;
    cr->rf.b = calloc(3, sizeof *cr->rf.b); REQUIRE(cr->rf.b);
    cr->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .rw = 1}; cr->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0}; cr->rf.b[2] = (nvn_rbind){.kind = NVN_RB_PUSH, .reg = 0}; cr->rf.nb = 3;
    #define PUSH(X0, Y0, W, H, K) do { int32_t i_[4] = {(X0), (Y0), (W), (H)}; float k_ = (K); memset(S.push[1][0], 0, NVN2_PUSH_BYTES); \
        memcpy(S.push[1][0] + 16, &i_[0], 4); memcpy(S.push[1][0] + 20, &i_[1], 4); memcpy(S.push[1][0] + 96, &i_[2], 4); memcpy(S.push[1][0] + 100, &i_[3], 4); \
        memcpy(S.push[1][0] + 104, &k_, 4); memcpy(S.push[1][0] + 108, &k_, 4); } while (0)
    float p[3], q2[3], r3[3];
    // ③
    uint64_t rc0 = g_tensor_rect_runs; PUSH(0, 0, OW, OH, 1.0f / 256);
    standin(cr); standin(cr); read_at(tex_mtl(&to), 120, 120, p);
    VERIFY(g_tensor_rect_runs == rc0 + 2, "③ 按有效区域放大 2 次（实 %llu）", (unsigned long long)(g_tensor_rect_runs - rc0));
    VERIFY(near(p[0], 0.25f, 0.08f) && near(p[1], 0.0625f, 0.08f) && near(p[2], 4.0f, 0.08f), "③ 输入有效 32x32：(120,120) = (%g, %g, %g)（期望 ≈ A² 0.25, 0.0625, 4；整张输入时 ≈ 4, 4, 4）", p[0], p[1], p[2]);
    // ④
    PUSH(64, 64, 64, 64, 1.0f / 64);
    standin(cr); standin(cr); read_at(tex_mtl(&to), 80, 80, p); read_at(tex_mtl(&to), 120, 120, q2); read_at(tex_mtl(&to), 32, 32, r3);
    VERIFY(near(p[0], 0.25f, 0.08f) && near(p[1], 0.0625f, 0.08f), "④ 输出区域 (64,64) 起 64x64：(80,80) = (%g, %g, %g)（期望 ≈ A² 0.25, 0.0625；整张输出时 ≈ 4, 4）", p[0], p[1], p[2]);
    VERIFY(near(q2[0], 4.0f, 0.08f) && near(q2[1], 4.0f, 0.08f), "④ (120,120) = (%g, %g, %g)（期望 ≈ B² 4, 4）", q2[0], q2[1], q2[2]);
    VERIFY(near(r3[0], 0.25f, 0.08f) && near(r3[1], 0.0625f, 0.08f), "④ 区域外 (32,32) 保持 ③：(%g, %g, %g)（期望 ≈ 0.25, 0.0625）", r3[0], r3[1], r3[2]);
    // ⑤
    rc0 = g_tensor_rect_runs; uint64_t up1 = g_tensor_up; PUSH(0, 0, 0, OH, 1.0f / 256);
    standin(cr);
    VERIFY(g_tensor_rect_runs == rc0 && g_tensor_up == up1 + 1 && (cr->tensor_log & 4), "⑤ 推常量宽 0：不按有效区域（实 %llu 次）、照整张放大 1 次（实 %llu）、报红 %d",
           (unsigned long long)(g_tensor_rect_runs - rc0), (unsigned long long)(g_tensor_up - up1), (cr->tensor_log & 4) != 0);
    #undef PUSH
    // ⑥ 诊断开关 DM_NVN_TENSOR_STANDIN（11-11 #376）：取值表手写（=0 关，不设 / 空 / 其他值开，同 DM_NVN_GMEM）；①–⑤ 都在不设时跑 = 缺省照旧顶替
    VERIFY(tensor_standin_decide(NULL) == 1 && tensor_standin_decide("") == 1 && tensor_standin_decide("1") == 1 && tensor_standin_decide("0") == 0,
           "⑥ 取值：不设 %d、空 %d、1 %d、0 %d（期望 1 1 1 0）", tensor_standin_decide(NULL), tensor_standin_decide(""), tensor_standin_decide("1"), tensor_standin_decide("0"));
    {   // 经真 getenv 关掉：出口层不顶替（不放大、不平方、记一次关），输出图逐位不变；撤掉后回到顶替
        float b0[3], b1[3]; read_at(tex_mtl(&to), 32, 32, b0);
        setenv("DM_NVN_TENSOR_STANDIN", "0", 1); g_tensor_standin_on = -1;
        uint64_t up2 = g_tensor_up, sq2 = g_tensor_sq_runs, off2 = g_tensor_off; cs->tensor_sq = 0;   // 不平方：真顶替会把 (32,32) 写成 A ≈ 0.5（≠ 现值 A² ≈ 0.25），逐位比才有判别力
        standin(cs); read_at(tex_mtl(&to), 32, 32, b1);
        VERIFY(g_tensor_up == up2 && g_tensor_sq_runs == sq2 && g_tensor_off == off2 + 1, "⑥ =0：放大 %llu 次、平方 %llu 次、关计数 +%llu（期望 0 / 0 / 1）",
               (unsigned long long)(g_tensor_up - up2), (unsigned long long)(g_tensor_sq_runs - sq2), (unsigned long long)(g_tensor_off - off2));
        VERIFY(!memcmp(b0, b1, sizeof b0), "⑥ =0：输出图 (32,32) 前 (%g, %g, %g) 后 (%g, %g, %g)（期望逐位相同）", b0[0], b0[1], b0[2], b1[0], b1[1], b1[2]);
        unsetenv("DM_NVN_TENSOR_STANDIN"); g_tensor_standin_on = -1; up2 = g_tensor_up;
        standin(cs);
        VERIFY(g_tensor_up == up2 + 1, "⑥ 撤掉后照旧顶替：放大 %llu 次（期望 1）", (unsigned long long)(g_tensor_up - up2));
    }
    printf("%s t_nvn_tensor_sq：%u 项，%u 项不过（张量核网络顶替：平方域出口层先平方输入、sRGB 域先解码输入、同域照原样；按推常量取输入有效区域与输出区域；诊断开关关掉不顶替）\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
} }
