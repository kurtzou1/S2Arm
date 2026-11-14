// 张量核网络顶替的分屏区域（nvn_tensor.inc tensor_rect_io）：不带平方的出口层、1 张贴图 + 1 张图 + 推常量槽 0，
//   c[0].xyzw（int）= 输入区域 起点 x,y + 宽高减一，c[1].xyzw（int）= 输出区域 起点 x,y + 宽高减一。
//   双人分屏时输出图分两次派发、各写一块，读的半屏画面和整张输出图宽高比不同：改前按整张输出图挑输入、挑不出就不写（3D 全黑，只剩界面）。
//   生产 nvn_mtl.m（包含）+ 真 Metal 设备 + MetalFX 空间放大。
// 夹具：输出 128x72 R11G11B10F（贴图 ID 8）；RGB9E5 两个值（手算，同 t_nvn_tensor_sq）：A = 字 0x8C004040 → (0.5, 0.25, 2.0)，B = 字 0x8C020100 → (2, 2, 2)
//   ① 左右分屏：输入 32x36（ID 7，宽高比 0.889，和输出 16:9 不同）。先填 A、写左半 c[1] = 0,0,63,71；再填 B、写右半 c[1] = 64,0,63,71。
//      期望 (32,36) ≈ A、(96,36) ≈ B，按区域放大计数 +4。改前：两次都挑不出输入、不写 → 输出保持初值 0（三项红）
//   ② 上下分屏、两块共用一张输入图、输入块不在左上角：输入 64x36（ID 9），上 18 行 = A、下 18 行 = B；
//      上半输出 c[1] = 0,0,127,35 读输入下半 c[0] = 0,18,63,17；下半输出 c[1] = 0,36,127,35 读输入上半 c[0] = 0,0,63,17。
//      期望 (64,18) ≈ B、(64,54) ≈ A。改前：整张输入（宽高比 16:9 对得上）放大进整张输出 → (64,18) ≈ A、(64,54) ≈ B（两项红）
//   ③ 负对照（单人整屏）：同 ② 的输入，c[0] = 整张输入、c[1] = 整张输出 → 走原路径（按区域计数不加），(64,18) ≈ A、(64,54) ≈ B，与改前相同
//   ⑤ 四人四格：同 ② 的输入图只用左上 32x18（16:9，和整张输出同宽高比），左上格 c[1] = 0,0,63,35 填 A、右下格 c[1] = 64,36,63,35 填 B。
//      期望 (32,18) ≈ A、(96,54) ≈ B。改前：输入宽高比和整张输出对得上，每格都整张放大盖满全屏 → (32,18) 也 ≈ B（一项红）
//   ④ 推常量不成立（输出区域越出图）→ 不按区域；① 的输入宽高比对不上，照改前不写（放大计数不加、报红）
// 每种情形顶替两次、读第二次的输出：新建的 MetalFX 空间放大器（Metal 4）头一次编码约 1/10 写出全 0（docs/坑记录.md，t_nvn_tensor_sq 同样做法）
// 负对照（手工，写进报告）：tensor_standin 里不调 tensor_rect_io（= 改前）→ ① ② ⑤ 红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { POOL_SIZE = 4 << 20, TID_H = 7, TID_O = 8, TID_V = 9, OW = 128, OH = 72, HW = 32, HH = 36, VW = 64, VH = 36 };
enum : uint32_t { A = 0x8C004040u, B = 0x8C020100u };
static int near(float v, float want, float tol) { return fabsf(v - want) <= tol * want; }
static int is_a(const float v[3]) { return near(v[0], 0.5f, 0.1f) && near(v[1], 0.25f, 0.1f) && near(v[2], 2.0f, 0.1f); }
static int is_b(const float v[3]) { return near(v[0], 2.0f, 0.1f) && near(v[1], 2.0f, 0.1f) && near(v[2], 2.0f, 0.1f); }

static void reg_tex(tex_t *t, pool_t *pool, uint8_t *mem, uint64_t off, int fmt, uint32_t w, uint32_t h, int tid) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial(); t->pool = pool; t->off = off; t->mem = mem + off;
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .width = w, .height = h, .depth = 1, .levels = 1};
    nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t); nvn_be_reg_tex(tid, t, NULL);
}
static float uf(uint32_t m, uint32_t e, int mb) { return e ? ldexpf(1.0f + (float)m / (float)(1 << mb), (int)e - 15) : ldexpf((float)m / (float)(1 << mb), -14); }
// 输出图一个纹素：下一个提交里拷进共享缓冲区，等完成后在 CPU 上解 R11G11B10F（不经被测实现）
static void read_at(id<MTLTexture> o, NSUInteger x, NSUInteger y, float out[3]) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; memset(b.contents, 0, 256); res_add(b);
    nvn_be_sub_begin(); rp_flush();
    enc_b_copy_texture_buffer(blit(), o, 0, 0, MTLOriginMake(x, y, 0), MTLSizeMake(1, 1, 1), b, 0, 256, 256); enc_close_blit();
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    uint32_t v = *(const uint32_t *)b.contents;
    out[0] = uf(v & 63, (v >> 6) & 31, 6); out[1] = uf((v >> 11) & 63, (v >> 17) & 31, 6); out[2] = uf((v >> 22) & 31, (v >> 27) & 31, 5);
}
// 测试自己在 GPU 上填输入（不经被测实现）：上 split 行 = top、其余 = bottom
static void fill(id<MTLCommandQueue> q, id<MTLTexture> t, uint32_t w, uint32_t h, uint32_t split, uint32_t top, uint32_t bottom) {
    id<MTLBuffer> src = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) ((uint32_t *)src.contents)[y * w + x] = y < split ? top : bottom;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:w * h * 4 sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
}
static void push(int32_t ix, int32_t iy, int32_t iw1, int32_t ih1, int32_t ox, int32_t oy, int32_t ow1, int32_t oh1) {
    int32_t v[8] = {ix, iy, iw1, ih1, ox, oy, ow1, oh1}; memset(S.push[1][0], 0, NVN2_PUSH_BYTES); memcpy(S.push[1][0], v, sizeof v);
}
static void standin(NvShader *cs, int tid_in) {
    nvn_be_sub_begin();
    S.tex[5][0] = tid_in; S.img[5][0] = TID_O;
    tensor_standin(cs);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    if (!dlss_class("MTLFXSpatialScalerDescriptor")) { printf("✓ t_nvn_tensor_split：跳过（这台设备没有 MetalFX 空间放大）\n"); return 0; }
    uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, POOL_SIZE)); memset(mem, 0, POOL_SIZE);
    pool_t pool = {.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = POOL_SIZE};
    nvn_be_pool_add(mem, POOL_SIZE);
    nvn_be_pool_gpu_written(&pool);   // 输入由测试在 GPU 上直接写（同 t_nvn_tensor_sq：否则首用按随包贴图从存储重传，盖掉测试写的内容）
    tex_t th, to, tv;
    reg_tex(&th, &pool, mem, 65536, NVN_FORMAT_RGB9E5F, HW, HH, TID_H);
    reg_tex(&to, &pool, mem, 1 << 20, NVN_FORMAT_R11G11B10F, OW, OH, TID_O);
    reg_tex(&tv, &pool, mem, 2 << 20, NVN_FORMAT_RGB9E5F, VW, VH, TID_V);
    nvn_be_sub_begin(); id<MTLTexture> h = tex_mtl(&th), o = tex_mtl(&to), v = tex_mtl(&tv); uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(h && o && v && h.pixelFormat == MTLPixelFormatRGB9E5Float && o.pixelFormat == MTLPixelFormatRG11B10Float);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; REQUIRE(q);
    NvShader *cs = [NvShader new]; snprintf(cs->key, sizeof cs->key, "tensor_split_test"); cs->stage = 5; cs->tensor = 1; cs->tensor_sq = 0;
    cs->rf.b = calloc(3, sizeof *cs->rf.b); REQUIRE(cs->rf.b);   // NvShader frees it
    cs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .rw = 1}; cs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0}; cs->rf.b[2] = (nvn_rbind){.kind = NVN_RB_PUSH, .reg = 0}; cs->rf.nb = 3;
    float l[3], r[3], t[3], b[3];
    // ①
    uint64_t rc0 = g_tensor_rect_runs, up0 = g_tensor_up;
    fill(q, tex_mtl(&th), HW, HH, HH, A, A); push(0, 0, HW - 1, HH - 1, 0, 0, OW / 2 - 1, OH - 1); standin(cs, TID_H); standin(cs, TID_H);
    fill(q, tex_mtl(&th), HW, HH, HH, B, B); push(0, 0, HW - 1, HH - 1, OW / 2, 0, OW / 2 - 1, OH - 1); standin(cs, TID_H); standin(cs, TID_H);
    read_at(tex_mtl(&to), 32, 36, l); read_at(tex_mtl(&to), 96, 36, r);
    VERIFY(g_tensor_rect_runs == rc0 + 4 && g_tensor_up == up0 + 4, "① 左右分屏：按区域放大 %llu 次、放大 %llu 次（期望 4 / 4）", (unsigned long long)(g_tensor_rect_runs - rc0), (unsigned long long)(g_tensor_up - up0));
    VERIFY(is_a(l), "① 左半 (32,36) = (%g, %g, %g)（期望 ≈ A 0.5, 0.25, 2；改前不写 = 0）", l[0], l[1], l[2]);
    VERIFY(is_b(r), "① 右半 (96,36) = (%g, %g, %g)（期望 ≈ B 2, 2, 2；改前不写 = 0）", r[0], r[1], r[2]);
    // ②
    rc0 = g_tensor_rect_runs; up0 = g_tensor_up;
    fill(q, tex_mtl(&tv), VW, VH, VH / 2, A, B);
    push(0, VH / 2, VW - 1, VH / 2 - 1, 0, 0, OW - 1, OH / 2 - 1); standin(cs, TID_V); standin(cs, TID_V);
    push(0, 0, VW - 1, VH / 2 - 1, 0, OH / 2, OW - 1, OH / 2 - 1); standin(cs, TID_V); standin(cs, TID_V);
    read_at(tex_mtl(&to), 64, 18, t); read_at(tex_mtl(&to), 64, 54, b);
    VERIFY(g_tensor_rect_runs == rc0 + 4 && g_tensor_up == up0 + 4, "② 上下分屏：按区域放大 %llu 次、放大 %llu 次（期望 4 / 4）", (unsigned long long)(g_tensor_rect_runs - rc0), (unsigned long long)(g_tensor_up - up0));
    VERIFY(is_b(t), "② 上半 (64,18) 读输入下半 = (%g, %g, %g)（期望 ≈ B；改前整张放大 ≈ A）", t[0], t[1], t[2]);
    VERIFY(is_a(b), "② 下半 (64,54) 读输入上半 = (%g, %g, %g)（期望 ≈ A；改前整张放大 ≈ B）", b[0], b[1], b[2]);
    // ③
    rc0 = g_tensor_rect_runs; up0 = g_tensor_up;
    push(0, 0, VW - 1, VH - 1, 0, 0, OW - 1, OH - 1); standin(cs, TID_V); standin(cs, TID_V);
    read_at(tex_mtl(&to), 64, 18, t); read_at(tex_mtl(&to), 64, 54, b);
    VERIFY(g_tensor_rect_runs == rc0 && g_tensor_up == up0 + 2, "③ 单人整屏走原路径：按区域 %llu 次、放大 %llu 次（期望 0 / 2）", (unsigned long long)(g_tensor_rect_runs - rc0), (unsigned long long)(g_tensor_up - up0));
    VERIFY(is_a(t) && is_b(b), "③ 整张放大：(64,18) = (%g, %g, %g) ≈ A、(64,54) = (%g, %g, %g) ≈ B（与改前相同）", t[0], t[1], t[2], b[0], b[1], b[2]);
    // ⑤
    rc0 = g_tensor_rect_runs; up0 = g_tensor_up;
    fill(q, tex_mtl(&tv), VW, VH, VH, A, A); push(0, 0, VW / 2 - 1, VH / 2 - 1, 0, 0, OW / 2 - 1, OH / 2 - 1); standin(cs, TID_V); standin(cs, TID_V);
    fill(q, tex_mtl(&tv), VW, VH, VH, B, B); push(0, 0, VW / 2 - 1, VH / 2 - 1, OW / 2, OH / 2, OW / 2 - 1, OH / 2 - 1); standin(cs, TID_V); standin(cs, TID_V);
    read_at(tex_mtl(&to), 32, 18, t); read_at(tex_mtl(&to), 96, 54, b);
    VERIFY(g_tensor_rect_runs == rc0 + 4 && g_tensor_up == up0 + 4, "⑤ 四格：按区域放大 %llu 次、放大 %llu 次（期望 4 / 4）", (unsigned long long)(g_tensor_rect_runs - rc0), (unsigned long long)(g_tensor_up - up0));
    VERIFY(is_a(t), "⑤ 左上格 (32,18) = (%g, %g, %g)（期望 ≈ A；改前后一格整张盖满 ≈ B）", t[0], t[1], t[2]);
    VERIFY(is_b(b), "⑤ 右下格 (96,54) = (%g, %g, %g)（期望 ≈ B）", b[0], b[1], b[2]);
    // ④
    rc0 = g_tensor_rect_runs; up0 = g_tensor_up; uint64_t red0 = g_tensor_red;
    push(0, 0, HW - 1, HH - 1, OW / 2 + 8, 0, OW / 2 - 1, OH - 1); standin(cs, TID_H);
    VERIFY(g_tensor_rect_runs == rc0 && g_tensor_up == up0 && g_tensor_red == red0 + 1, "④ 输出区域越出图：按区域 %llu 次、放大 %llu 次、报红 +%llu（期望 0 / 0 / 1，同改前）",
           (unsigned long long)(g_tensor_rect_runs - rc0), (unsigned long long)(g_tensor_up - up0), (unsigned long long)(g_tensor_red - red0));
    printf("%s t_nvn_tensor_split：%u 项，%u 项不过（张量核网络顶替：分屏按推常量的输入 / 输出区域放大；单人整屏照旧）\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
} }
