// 直连内部分辨率（S2A_RES_SCALE，graphics/nvn/gfx/nvn/nvn_rscale*.inc）：公开 NVN bootstrap → 真实录制、Metal 提交、公开读回（同 t_nvn_partial_clear 的搭法）。
// 跑法：t_nvn_rscale scaled | off | up | frac（native-test-nvn_rscale 各在 Metal 4 与 NXGAL_BE=mtl3 下跑一遍）。scaled 设 S2A_RES_SCALE=0.5，off 设 1；
//   up 设 2（64x48 → 128x96）、frac 设 1.5（64x48 → 96x72）：直连内部分辨率放开大于 1。各组的期望按比例 NUM / DEN 手算（色块坐标全是偶数，× 1.5 仍是整像素）；
//   17–21 组是放大专有的：17 奇数坐标的裁剪清除（矩形起点向下、终点向上取整）+ 子区域读回；18 存储像素级的条纹（游戏坐标读回必须是线性缩回，不是取其中一个纹素）；
//   19 放大后超过贴图上限的不放大；20 方形：缩小时深度 / 单通道照缩、多通道不缩（Ryujinx 规则），放大时一律不放大；21 以上各项的原因计数；
//   22 换存储失败（退回原尺寸时新存储建不出）后记录与实际存储尺寸一致（四种模式都跑）；23 读第 1 级（宽 65：各级存储 ÷ 画布的比例不等于设定比例）；
//   24 存储图像槽上的缩放图退不回原尺寸：每次派发报红，同一份存储换存储只试 3 次。
// 25–29 组——放大时窗口贴图（上屏标志；真机读到的标志是 0xd = 上屏 | 存储图像 | 可压缩）也按倍率建存储，上屏那一段跟着对；缩小 / 关照旧是原尺寸（对照）：
//   25 第一次当目标时的存储尺寸（2 → 128x96、1.5 → 96x72、0.5 / 1 → 64x48）与内容；26 上屏抓图（mtl_grab_next_present，无窗口）：对外尺寸是游戏尺寸、
//   内容 = 游戏尺寸期望，带裁剪（偶数 / 奇数坐标）时裁剪按画布 → 存储换算（Ryujinx Window.Present：左上向下、右下向上取整），满屏判据拿到的画面尺寸是游戏尺寸；
//   27 截图（dm_gfx_shot_at）的 PNG 是游戏尺寸；28 上屏抗锯齿的中间图不按存储尺寸建、MetalFX 在输入 ≥ 输出时不建；
//   29 已放大的图整张拷进还没当过目标的窗口贴图：窗口贴图跟着放大（Ryujinx TwodClass：目标按来源的缩放模式建）。
// 期望全部手算（游戏坐标下按矩形填色，不跑被测实现），每步都带反证：
//   - 存储尺寸与缩放记录（nvn_be_tex_storage_size）：scaled 下可缩的渲染目标 64x48 → 32x24（RS_SCALED），off 下 64x48（RS_NONE）；
//   - 原样存储字节（nvn_be_tex_storage_read，不换算回游戏尺寸）：scaled 下必须是 32x24 的缩小图、且等于手算的缩小图（各矩形坐标 ÷ 2）——证明真的缩了、读回也真做了换算；
//   - 游戏坐标读回（ReadTexels / CopyTextureToBuffer）必须等于游戏尺寸的期望图。
// 易花屏的三处各一组：缩放拷贝（缩放图 ↔ 原尺寸图两个方向）、CPU 读写（缓冲写入即退回原尺寸、两条读回路径）、拉黑退回原尺寸（同遍有不可缩附件、绑定检查的待退回队列）。
// 线性滤波的两处（退回原尺寸的放大拷贝、CopyTextureToBuffer 的回读，同 Ryujinx CopyTo(linear)）在色块边缘 1 个游戏像素内允许取两色之间的值，其余逐字节相等。
// 8–13 组——建时带存储图像标志（NVN_TEXTURE_FLAGS_IMAGE）的渲染目标照样缩（Ryujinx 没有建时标志，拉黑在绑定 / 使用时：TextureBindingsManager.UpdateScale），
//   真被当存储图像用才退回原尺寸，而且在用它的那次派发 / 绘制之前就退回（图像读写用游戏坐标的整数纹素，落在缩过的存储上位置全错）：
//   8 当目标时缩；9 计算派发写它；10 开着的遍里片元只读图像；11 开着的遍里片元写图像（本遍附件也退回：缩小的片元网格写不满图像）；
//   12 图像槽里就是本遍附件；13 先当存储图像用过的，以后当目标也不缩；14 派发开头就退回（张量核网络顶替那条不走 rs_pre_compute 的路）；
//   15 覆盖面读数的计数与汇总行（按本文件的步骤手数 / 手写）；16 待退回队列装满时不丢。手写 MSL 的读写位置都是常数纹素坐标，期望图照样手算。
// 第 8 组起（带存储图像标志的渲染目标：当目标时缩、真被当存储图像用才退回）要真着色器走计算派发 / 片元图像槽，所以把 nvn_mtl.m 编进本单元
//   （同 t_nvn_size_abi / t_nvn_pkg_gpu_write 的搭法）：录制、提交、读回照旧走公开 NVN，程序对象经 serial_put 挂手写 MSL（没有替换任何生产函数）。
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);

static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer commands; static void *storage;
static size_t texture_offset = 4 << 20; static unsigned cases, checks; static const char *phase = "初始化";
enum { POOL_SIZE = 32 << 20, COMMAND_SIZE = 1 << 20, BUF_OFFSET = 2 << 20, W = 64, H = 48 };
// 比例 NUM / DEN（scaled 1/2、off 1/1、up 2/1、frac 3/2）；on = 比例不是 1；TW x TH = make_tex 建的贴图尺寸（缺省 W x H；19 / 20 组临时改）
static int NUM = 1, DEN = 1, on, TW = W, TH = H, TL = 1;   // TL：级数（23 组临时改）
// T_NVN_RSCALE_ALL=1（负对照用）：不通的项只记数、接着跑完，一次看全红在哪几组；末尾按不通数返回 1。缺省照旧：第一项不通就退出
static unsigned fails; static int keep_going;
static void failed(void) { fails++; if (!keep_going) exit(1); }
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL [%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); failed(); } } while (0)
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); REQUIRE(e != NULL); return e; }
#define API(name) ((NVNT_##name)load(#name))

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(posix_memalign(&storage, 65536, POOL_SIZE) == 0); memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void make_tex_pkg(NVNtexture *t, NVNformat fmt, int flags, const void *pkg);
static void make_tex(NVNtexture *t, NVNformat fmt, int flags) { make_tex_pkg(t, fmt, flags, NULL); }
static void make_tex_pkg(NVNtexture *t, NVNformat fmt, int flags, const void *pkg) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, TW, TH); API(nvnTextureBuilderSetLevels)(&b, TL);
    API(nvnTextureBuilderSetFormat)(&b, fmt); API(nvnTextureBuilderSetFlags)(&b, flags);
    if (pkg) API(nvnTextureBuilderSetPackagedTextureData)(&b, pkg);
    size_t al = API(nvnTextureBuilderGetStorageAlignment)(&b), sz = API(nvnTextureBuilderGetStorageSize)(&b);
    texture_offset = (texture_offset + al - 1) / al * al; REQUIRE(texture_offset + sz <= POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)texture_offset); texture_offset += sz;
    REQUIRE(API(nvnTextureInitialize)(t, &b));
}

// 游戏坐标的期望图：底色 + 依次覆盖的矩形（整数游戏像素）；也给存储尺寸的图（矩形坐标 × mul ÷ div，全部取偶数坐标，换算后仍是整像素）
typedef struct { int x, y, w, h; uint8_t c[4]; } rect;
static const uint8_t RED[4] = {255, 0, 0, 255}, GREEN[4] = {0, 255, 0, 255}, BLUE[4] = {0, 0, 255, 255}, YELLOW[4] = {255, 255, 0, 255}, GREY[4] = {128, 128, 128, 255};
static void paint(uint8_t *img, int w, int h, const uint8_t base[4], const rect *r, int n, int mul, int div) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *c = base;
        for (int k = 0; k < n; k++) if (x >= r[k].x * mul / div && x < (r[k].x + r[k].w) * mul / div && y >= r[k].y * mul / div && y < (r[k].y + r[k].h) * mul / div) c = r[k].c;
        memcpy(img + 4 * (y * w + x), c, 4);
    }
}
// 落在任一矩形某条边两侧各 tol 个像素的带里（线性滤波可能混色）：竖边 x ∈ [边 − tol, 边 + tol)、y 在矩形上下各外扩 tol 的范围内；横边同理
static int near_edge(int x, int y, const rect *r, int n, int tol) {
    for (int k = 0; k < n; k++) {
        int x0 = r[k].x, x1 = r[k].x + r[k].w, y0 = r[k].y, y1 = r[k].y + r[k].h;
        int in_y = y >= y0 - tol && y < y1 + tol, in_x = x >= x0 - tol && x < x1 + tol;
        if (in_y && ((x >= x0 - tol && x < x0 + tol) || (x >= x1 - tol && x < x1 + tol))) return 1;
        if (in_x && ((y >= y0 - tol && y < y0 + tol) || (y >= y1 - tol && y < y1 + tol))) return 1;
    }
    return 0;
}
static void compare(const uint8_t *got, const uint8_t *want, int w, int h, const rect *r, int n, int tol, const char *what) {
    int exact = 0, edge = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *g = got + 4 * (y * w + x), *e = want + 4 * (y * w + x);
        checks++;
        if (!memcmp(g, e, 4)) { exact++; continue; }
        if (tol && near_edge(x, y, r, n, tol)) { edge++; continue; }
        fprintf(stderr, "FAIL [%s] %s (%d,%d) 得 %d,%d,%d,%d 期望 %d,%d,%d,%d\n", phase, what, x, y, g[0], g[1], g[2], g[3], e[0], e[1], e[2], e[3]); failed(); return;   // 见 failed()
    }
    REQUIRE(exact > w * h / 2);   // 绝大多数逐字节相等（边缘带只是窄窄一圈）
    printf("  %s：%d 个逐字节相等，%d 个在边缘带\n", what, exact, edge);
}
static void read_game(NVNtexture *t, uint8_t *out) { NVNcopyRegion r = {0, 0, 0, W, H, 1}; memset(out, 0xA5, W * H * 4); API(nvnTextureReadTexels)(t, NULL, &r, out); }
static void storage_is(NVNtexture *t, int want_state, int sw, int sh) {
    int w = 0, h = 0, st = nvn_be_tex_storage_size(t, &w, &h);
    printf("  存储 %dx%d 记录 %d（期望 %dx%d 记录 %d）\n", w, h, st, sw, sh, want_state);
    REQUIRE(st == want_state && w == sw && h == sh);
}
static void clear_rt(NVNtexture *t, const rect *r, int n, const uint8_t base[4]) {
    const NVNtexture *ts[1] = {t}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL);
    float f[4]; for (int i = 0; i < 4; i++) f[i] = base[i] / 255.0f;
    API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15);
    for (int k = 0; k < n; k++) { for (int i = 0; i < 4; i++) f[i] = r[k].c[i] / 255.0f; API(nvnCommandBufferSetScissor)(&commands, r[k].x, r[k].y, r[k].w, r[k].h); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); }
}
static void done(void) { static unsigned seen; cases++; printf("%s %s\n", fails == seen ? "PASS" : "FAIL", phase); seen = fails; fflush(stdout); }   // 接着跑时本组有不通的项就标 FAIL

// 8–13 组的手写着色器。读写位置全是常数纹素坐标（游戏坐标），与片元位置 / 遍的比例无关，所以期望不依赖被测实现：
//   cs_block 计算：线程 (x, y) 往图像槽 0 的 (48 + x, 32 + y) 写黄（派发 8×8×1 = 黄块 48,32 8×8）；fs_green 输出绿；
//   fs_read 片元：读图像槽 0 的 (40, 28) 当输出；fs_write 片元：往图像槽 0 的 (40..47, 28..35) 写黄、输出灰；fs_self 片元：声明并读图像槽 0（乘 0）、输出蓝
static NSString *const shader_source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct ImgW { texture2d<float, access::write> img [[id(0)]]; };\n"
"struct ImgR { texture2d<float, access::read> img [[id(0)]]; };\n"
"kernel void cs_block(constant ImgW &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { a.img.write(float4(1, 1, 0, 1), uint2(48 + p.x, 32 + p.y)); }\n"
"vertex float4 vs_tri(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[i], 0, 1); }\n"
"fragment float4 fs_green() { return float4(0, 1, 0, 1); }\n"
"fragment float4 fs_read(constant ImgR &a [[buffer(0)]]) { return a.img.read(uint2(40, 28)); }\n"
"fragment float4 fs_write(constant ImgW &a [[buffer(0)]]) { for (uint y = 0; y < 8; y++) for (uint x = 0; x < 8; x++) a.img.write(float4(1, 1, 0, 1), uint2(40 + x, 28 + y));\n"
"  return float4(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1); }\n"
"fragment float4 fs_self(constant ImgR &a [[buffer(0)]]) { return float4(0, 0, 1, 1) + a.img.read(uint2(0, 0)) * 0.0; }\n"
// 第 18 组：按真实（存储）像素列的奇偶出红 / 绿——手写 MSL 的 [[position]] 是存储像素坐标，不经游戏着色器的片元坐标倍率
"fragment float4 fs_stripe(float4 p [[position]]) { return (uint(p.x) & 1u) ? float4(0, 1, 0, 1) : float4(1, 0, 0, 1); }\n";
#define RED_IMG_HITS g_red_once[191]   // 第 24 组：RED_ONCE 191 的命中数
static NVNtexturePool descriptors;
enum { DESC_OFFSET = 3 << 20, IMG_NONE = 0, IMG_READ = 1, IMG_WRITE = 2 };
static NvShader *make_shader(id<MTLLibrary> lib, NSString *name, int stage, const char *key, int image) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:name]; REQUIRE(s->fn != nil);
    strlcpy(s->key, key, sizeof s->key); s->rf.pos_attr = -1; s->rf.has_user = stage == 1 ? 2 : 1;
    if (stage == 1) { s->rf.color_known = 1; s->rf.color_mask = 1; }
    if (stage == 5) {   // 计算：反射照生产走 JSON（同 t_nvn_dispatch_clear）
        char err[256] = ""; REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
            @{ @"kind": @"img", @"reg": @0, @"arg_id": @0, @"msl_name": @"img", @"msl_type": @"texture2d<float, access::write>" } ] }, &s->rf, err, sizeof err));
        REQUIRE(s->rf.nb == 1 && s->rf.b[0].kind == NVN_RB_IMG && s->rf.b[0].rw);
    } else if (image) {   // 片元：图像槽 0 ↔ 参数缓冲 id(0)（同 t_nvn_feedback_snapshot 手填反射）
        s->rf.nb = 1; s->rf.b = calloc(1, sizeof *s->rf.b); REQUIRE(s->rf.b != NULL);
        s->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .aid = 0, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .rw = image == IMG_WRITE};
    }
    if (image) { s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae != nil); s->arg_len = s->ae.encodedLength; }
    return s;
}
// 公开的程序对象挂上已建好的着色器（同 t_nvn_size_abi 的 program()：进 prog_get 用的序号表，不替换加载器）
static NVNprogram *make_program(NvShader *vs, NvShader *fs, NvShader *cs) {
    static NVNprogram programs[8]; static unsigned count; REQUIRE(count < 8);
    NVNprogram *p = &programs[count++]; REQUIRE(API(nvnProgramInitialize)(p, &device));
    prog_t *guest = (prog_t *)p; guest->serial = nvn_new_serial(); NvProg *native = [NvProg new]; native->gp = guest;
    native->sh[0] = vs; native->sh[1] = fs; native->sh[5] = cs; serial_put(guest->serial, native); return p;
}
static NVNimageHandle image_handle(NVNtexture *t) {
    static int next = 256; int id = next++;
    API(nvnTexturePoolRegisterImage)(&descriptors, id, t, NULL); return API(nvnDeviceGetImageHandle)(&device, id);
}
// 绘制的公共状态：缺省光栅 / 深度模板 / 混合 / 通道掩码 / 多重采样，目标 t，满幅视口与裁剪
static void draw_setup_ds(NVNtexture *t, NVNtexture *z);
static void draw_setup(NVNtexture *t) { draw_setup_ds(t, NULL); }
static void draw_setup_ds(NVNtexture *t, NVNtexture *z) {
    NVNpolygonState p; API(nvnPolygonStateSetDefaults)(&p); API(nvnCommandBufferBindPolygonState)(&commands, &p);
    NVNdepthStencilState d; API(nvnDepthStencilStateSetDefaults)(&d); API(nvnCommandBufferBindDepthStencilState)(&commands, &d);
    NVNcolorState c; API(nvnColorStateSetDefaults)(&c); API(nvnCommandBufferBindColorState)(&commands, &c);
    NVNchannelMaskState m; API(nvnChannelMaskStateSetDefaults)(&m); API(nvnCommandBufferBindChannelMaskState)(&commands, &m);
    NVNmultisampleState ms; API(nvnMultisampleStateSetDefaults)(&ms); API(nvnCommandBufferBindMultisampleState)(&commands, &ms);
    const NVNtexture *ts[1] = {t}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, z, NULL);
    API(nvnCommandBufferSetViewport)(&commands, 0, 0, W, H); API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H);
    API(nvnCommandBufferSetTexturePool)(&commands, &descriptors);
}
static void draw_tri(NVNprogram *p) {
    API(nvnCommandBufferBindProgram)(&commands, p, NVN_SHADER_STAGE_VERTEX_BIT | NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferDrawArrays)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
}

// 25–29 组（窗口贴图按倍率画）的公共件。WIN_FLAGS = 真机读到的窗口贴图标志 0xd
enum { WIN_FLAGS = NVN_TEXTURE_FLAGS_DISPLAY | NVN_TEXTURE_FLAGS_IMAGE | NVN_TEXTURE_FLAGS_COMPRESSIBLE };
static uint8_t *grab_px; static size_t grab_w, grab_h;
// 上屏一次（无窗口：present_now 判几何、交抓图后返回），取这次的抓图：BGRA → RGBA 存 grab_px（透明度不比：固定写 255）
static void present_grab(NVNtexture *t, const int crop[4]) {
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    while (mtl_grab_inflight()) sched_yield();
    grab_w = grab_h = 0;
    mtl_grab_next_present(^(const uint8_t *b, size_t w, size_t h, size_t row) {
        if (b) { grab_px = realloc(grab_px, w * h * 4);
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { const uint8_t *q = b + y * row + 4 * x; uint8_t *o = grab_px + 4 * (y * w + x); o[0] = q[2]; o[1] = q[1]; o[2] = q[0]; o[3] = 255; }
            grab_w = w; grab_h = h; }
        dispatch_semaphore_signal(got); });
    nvn_be_present_wait(nvn_be_present((const tex_t *)t, 0, crop));
    REQUIRE(!dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)));
    while (mtl_grab_inflight()) sched_yield();
}
// 抓图尺寸与满屏判据拿到的画面尺寸（fit_geom 记在 g_fj_cw / g_fj_ch）
static void grab_is(int w, int h, int pw, int ph) {
    printf("  抓图 %zux%zu（期望 %dx%d）；满屏判据的画面尺寸 %dx%d（期望 %dx%d）\n", grab_w, grab_h, w, h, g_fj_cw, g_fj_ch, pw, ph);
    REQUIRE(grab_w == (size_t)w && grab_h == (size_t)h); REQUIRE(g_fj_cw == pw && g_fj_ch == ph);
}
static int grab_all(const uint8_t c[4]) { int ok = grab_w && grab_h; for (size_t i = 0; i < grab_w * grab_h; i++) ok &= !memcmp(grab_px + 4 * i, c, 4); return ok; }
// PNG → RGBA（透明度固定 255）；返回 1 = 读到
static int png_read(const char *path, uint8_t *rgba, size_t cap, size_t *w, size_t *h) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL(url, NULL) : NULL; CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL; int ok = 0;
    if (img) { *w = CGImageGetWidth(img); *h = CGImageGetHeight(img);
        if (*w * *h * 4 <= cap) { CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef c = CGBitmapContextCreate(rgba, *w, *h, 8, *w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
            if (c) { CGContextSetBlendMode(c, kCGBlendModeCopy); CGContextDrawImage(c, CGRectMake(0, 0, *w, *h), img); CGContextRelease(c); ok = 1; for (size_t i = 0; i < *w * *h; i++) rgba[4 * i + 3] = 255; }
            CGColorSpaceRelease(cs); } }
    if (img) CGImageRelease(img); if (src) CFRelease(src); if (url) CFRelease(url);
    return ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
    static const struct { const char *name, *env; int num, den; } modes[] = {{"scaled", "0.5", 1, 2}, {"off", "1", 1, 1}, {"up", "2", 2, 1}, {"frac", "1.5", 3, 2}};
    int mode = -1; for (int k = 0; argc == 2 && k < 4; k++) if (!strcmp(argv[1], modes[k].name)) mode = k;
    if (mode < 0) { fprintf(stderr, "用法：t_nvn_rscale scaled | off | up | frac\n"); return 2; }
    NUM = modes[mode].num; DEN = modes[mode].den; on = NUM != DEN; keep_going = getenv("T_NVN_RSCALE_ALL") != NULL; if (keep_going) setvbuf(stdout, NULL, _IONBF, 0);
    setenv("S2A_RES_SCALE", modes[mode].env, 1);
    // 手写着色器的管线不进用户的着色器 / 管线记录（同 t_nvn_lc_order）
    char map[] = "/tmp/t_rscale_map_XXXXXX", user[] = "/tmp/t_rscale_user_XXXXXX";
    { int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); fd = mkstemp(user); REQUIRE(fd >= 0); close(fd); }
    setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    setup();
    REQUIRE(API(nvnTexturePoolInitialize)(&descriptors, &pool, DESC_OFFSET, 512));
    NSError *serr = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:shader_source options:nil error:&serr];
    if (!lib) fprintf(stderr, "MSL: %s\n", serr.localizedDescription.UTF8String);
    REQUIRE(lib != nil);
    NvShader *vs = make_shader(lib, @"vs_tri", 0, "aaaaaaaaaaaaaaaa_b", IMG_NONE);
    NVNprogram *p_green = make_program(vs, make_shader(lib, @"fs_green", 1, "bbbbbbbbbbbbbbbb_b", IMG_NONE), nil);
    NVNprogram *p_read = make_program(vs, make_shader(lib, @"fs_read", 1, "cccccccccccccccc_b", IMG_READ), nil);
    NVNprogram *p_write = make_program(vs, make_shader(lib, @"fs_write", 1, "dddddddddddddddd_b", IMG_WRITE), nil);
    NVNprogram *p_self = make_program(vs, make_shader(lib, @"fs_self", 1, "eeeeeeeeeeeeeeee_b", IMG_READ), nil);
    NVNprogram *p_block = make_program(nil, nil, make_shader(lib, @"cs_block", 5, "ffffffffffffffff_b", IMG_WRITE));
    NVNprogram *p_stripe = make_program(vs, make_shader(lib, @"fs_stripe", 1, "8888888888888888_b", IMG_NONE), nil);
    NvShader *cs_tensor = make_shader(lib, @"cs_block", 5, "9999999999999999_b", IMG_WRITE); cs_tensor->tensor = 1;   // 判成张量核网络的计算程序：不派发，走 tensor_standin
    NVNprogram *p_tensor = make_program(nil, nil, cs_tensor);
    int SW = W * NUM / DEN, SH = H * NUM / DEN, SCALED_ST = on ? RS_SCALED : RS_NONE;
    // 线性滤波的边缘带：缩小局（退回 = 放大拷贝、回读 = 放大）色块边缘 1 个游戏像素内可混色；放大局（退回 / 回读 = 线性缩回，偶数坐标的色块每个游戏像素取到的存储纹素同色）逐字节
    int TOL = NUM < DEN ? 1 : 0;
    static uint8_t got[W * H * 4], want[W * H * 4], raw[W * H * 16], rawwant[W * H * 16];   // 原样存储最大 2 倍边长
    NVNtexture A, B, C, D, E, Z;

    // 1. 第一次当渲染目标时缩；遍内清除（整屏 + 裁剪）按画布 → 存储换算；CPU 读回（ReadTexels，最近邻取回）是游戏尺寸
    phase = "1 渲染目标缩放 + 遍内裁剪清除 + ReadTexels";
    rect r1[] = {{16, 8, 32, 16, {0}}}; memcpy(r1[0].c, GREEN, 4);
    make_tex(&A, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); clear_rt(&A, r1, 1, RED); submit();
    storage_is(&A, SCALED_ST, SW, SH);
    nvn_be_tex_storage_read(&A, raw, (size_t)SW * 4); paint(rawwant, SW, SH, RED, r1, 1, NUM, DEN);
    compare(raw, rawwant, SW, SH, NULL, 0, 0, "原样存储 = 手算的（缩小）图");   // 反证：scaled 下存储真是 32x24 的缩小图
    paint(want, W, H, RED, r1, 1, 1, 1); read_game(&A, got); compare(got, want, W, H, NULL, 0, 0, "ReadTexels = 游戏尺寸期望");
    done();

    // 2. 缩放拷贝：缩放图 → 原尺寸图（最近邻，逐字节），原尺寸图上 ClearTexture，再原尺寸图 → 缩放图；缩放图上 ClearTexture（复制引擎清除，区域按比例）
    phase = "2 缩放拷贝两个方向 + 复制引擎清除";
    make_tex(&B, NVN_FORMAT_RGBA8, 0);   // 不可压缩：不缩
    begin();
    { NVNcopyRegion sr = {8, 4, 0, 48, 32, 1}, dr = {0, 0, 0, 48, 32, 1}; API(nvnCommandBufferCopyTextureToTexture)(&commands, &A, NULL, &sr, &B, NULL, &dr, 0); }
    { NVNcopyRegion r = {0, 0, 0, 16, 8, 1}; float f[4] = {0, 0, 1, 1}; API(nvnCommandBufferClearTexture)(&commands, &B, NULL, &r, f, 15); }
    submit();
    storage_is(&B, RS_NONE, W, H);
    // B 期望：A 的 (8,4) 起 48x32 搬到 (0,0)：A 的绿块 (16,8,32,16) → (8,4,32,16)；再蓝块 (0,0,16,8)；其余（48 宽以外）是 0
    { rect rb[] = {{0, 0, 48, 32, {0}}, {8, 4, 32, 16, {0}}, {0, 0, 16, 8, {0}}}; memcpy(rb[0].c, RED, 4); memcpy(rb[1].c, GREEN, 4); memcpy(rb[2].c, BLUE, 4);
      const uint8_t zero[4] = {0, 0, 0, 0}; paint(want, W, H, zero, rb, 3, 1, 1); read_game(&B, got); compare(got, want, W, H, NULL, 0, 0, "B（缩放图 → 原尺寸图）"); }
    begin();
    { NVNcopyRegion sr = {0, 0, 0, 16, 8, 1}, dr = {40, 36, 0, 16, 8, 1}; API(nvnCommandBufferCopyTextureToTexture)(&commands, &B, NULL, &sr, &A, NULL, &dr, 0); }
    { NVNcopyRegion r = {0, 40, 0, 8, 8, 1}; float f[4] = {128 / 255.0f, 128 / 255.0f, 128 / 255.0f, 1}; API(nvnCommandBufferClearTexture)(&commands, &A, NULL, &r, f, 15); }
    submit();
    storage_is(&A, SCALED_ST, SW, SH);
    rect r2[] = {{16, 8, 32, 16, {0}}, {40, 36, 16, 8, {0}}, {0, 40, 8, 8, {0}}}; memcpy(r2[0].c, GREEN, 4); memcpy(r2[1].c, BLUE, 4); memcpy(r2[2].c, GREY, 4);
    nvn_be_tex_storage_read(&A, raw, (size_t)SW * 4); paint(rawwant, SW, SH, RED, r2, 3, NUM, DEN); compare(raw, rawwant, SW, SH, NULL, 0, 0, "A 原样存储");
    paint(want, W, H, RED, r2, 3, 1, 1); read_game(&A, got); compare(got, want, W, H, NULL, 0, 0, "A（原尺寸图 → 缩放图 + 清除）ReadTexels");
    done();

    // 3. GPU 回读到缓冲（CopyTextureToBuffer：缩放图先缩放拷贝回游戏尺寸，线性，同 Ryujinx flush）
    phase = "3 CopyTextureToBuffer 回读";
    NVNbufferAddress pa = API(nvnMemoryPoolGetBufferAddress)(&pool);
    begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToBuffer)(&commands, &A, NULL, &r, pa + BUF_OFFSET, 0); } submit();
    compare((uint8_t *)storage + BUF_OFFSET, want, W, H, r2, 3, TOL, "缓冲内容 = 游戏尺寸期望");
    done();

    // 4. CPU 写入（CopyBufferToTexture）：缩放图先退回原尺寸（Ryujinx 部分写入即拉黑），写入区逐字节，其余内容保留
    phase = "4 缓冲写入退回原尺寸";
    for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) memcpy((uint8_t *)storage + BUF_OFFSET + 4 * (y * 16 + x), YELLOW, 4);
    begin(); { NVNcopyRegion r = {24, 40, 0, 16, 8, 1}; API(nvnCommandBufferCopyBufferToTexture)(&commands, pa + BUF_OFFSET, &A, NULL, &r, 0); } submit();
    storage_is(&A, on ? RS_BLACK : RS_NONE, W, H);
    rect r4[] = {{16, 8, 32, 16, {0}}, {40, 36, 16, 8, {0}}, {0, 40, 8, 8, {0}}, {24, 40, 16, 8, {0}}}; memcpy(r4[0].c, GREEN, 4); memcpy(r4[1].c, BLUE, 4); memcpy(r4[2].c, GREY, 4); memcpy(r4[3].c, YELLOW, 4);
    paint(want, W, H, RED, r4, 4, 1, 1); read_game(&A, got); compare(got, want, W, H, r4, 3, TOL, "A 写入后（黄块逐字节，其余放大拷贝带边缘）");
    { int ok = 1; for (int y = 40; y < 48; y++) for (int x = 24; x < 40; x++) ok &= !memcmp(got + 4 * (y * W + x), YELLOW, 4); REQUIRE(ok); }
    // 再当渲染目标：已拉黑，不再缩
    begin(); clear_rt(&A, r1, 1, RED); submit(); storage_is(&A, on ? RS_BLACK : RS_NONE, W, H);
    done();

    // 5. 绑定检查的待退回队列：标记后，下一遍开遍前换回原尺寸，内容保留（单色：放大拷贝逐字节）
    phase = "5 待退回队列（存储图像 / 计算 / 不精确着色器读到缩放图的那条路）";
    make_tex(&C, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&D, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); clear_rt(&C, NULL, 0, BLUE); submit(); storage_is(&C, SCALED_ST, SW, SH);
    nvn_be_rs_mark_bad(&C);
    begin(); clear_rt(&D, NULL, 0, RED); submit();   // 别的目标开遍：安全点
    storage_is(&C, on ? RS_BLACK : RS_NONE, W, H); storage_is(&D, SCALED_ST, SW, SH);
    paint(want, W, H, BLUE, NULL, 0, 1, 1); read_game(&C, got); compare(got, want, W, H, NULL, 0, 0, "C 退回后内容");
    done();


    // 6. 同一遍有不可缩的附件（D16 深度：缩放拷贝画不了）→ 颜色目标也不缩（黑名单在目标间传播）
    phase = "6 同遍有不可缩附件";
    make_tex(&E, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&Z, NVN_FORMAT_DEPTH16, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); { const NVNtexture *ts[1] = {&E}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &Z, NULL); float f[4] = {0, 1, 0, 1};
        API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff); } submit();
    storage_is(&E, on ? RS_BLACK : RS_NONE, W, H);
    paint(want, W, H, GREEN, NULL, 0, 1, 1); read_game(&E, got); compare(got, want, W, H, NULL, 0, 0, "E 内容");
    done();

    // 7. 同一遍里有附件缩放失败 → 已缩的附件退回、同遍尺寸一致（11-09 #312 暗黑地牢2：颜色目标是打包贴图，存储建时不带渲染目标用途，缩放拷贝画不了；
    //    原先它记成不缩、同遍的深度照样缩到一半，同遍附件尺寸不一，iPhone 上闪粉色块）。修后：新存储补渲染目标用途 → 颜色也缩成；任何附件缩不成时同遍全部原尺寸
    phase = "7 打包数据的颜色目标 + 可缩深度：同遍尺寸一致";
    { static uint8_t pkgdata[1 << 20]; for (int i = 0; i < W * H; i++) memcpy(pkgdata + 4 * i, GREY, 4);   // 宿主按存储大小（块线性，大于 W×H×4）拷
      NVNtexture P, PZ; texture_offset = (texture_offset + 65535) / 65536 * 65536;   // 新起一页：前面贴图所在页已被写保护（单测桩不接缺页钩子），建时拷打包数据会 SIGBUS
      make_tex_pkg(&P, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, pkgdata); make_tex(&PZ, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      uint64_t up0 = g_pfv_upgrades;
      begin(); { const NVNtexture *ts[1] = {&P}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &PZ, NULL); float f[4] = {0, 0, 1, 1};
          API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff); } submit();
      // #1634：打包贴图建时就带渲染目标用途，第一次当附件不再整张复制补用途（修前这一遍 +1）
      printf("  打包颜色目标当附件：贴图升级 +%llu（期望 0）\n", (unsigned long long)(g_pfv_upgrades - up0)); REQUIRE(g_pfv_upgrades == up0);
      int cw = 0, ch = 0, zw = 0, zh = 0, cs = nvn_be_tex_storage_size(&P, &cw, &ch), zs = nvn_be_tex_storage_size(&PZ, &zw, &zh);
      printf("  颜色存储 %dx%d 记录 %d，深度存储 %dx%d 记录 %d（期望两者相同）\n", cw, ch, cs, zw, zh, zs);
      REQUIRE(cw == zw && ch == zh);
      if (on) REQUIRE(cs == RS_SCALED && cw == SW && ch == SH);   // 补了渲染目标用途，颜色缩成
      paint(want, W, H, BLUE, NULL, 0, 1, 1);   // 打包贴图的 ReadTexels 以池内存为准（读到打包原数据），GPU 内容走 CopyTextureToBuffer
      begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToBuffer)(&commands, &P, NULL, &r, pa + BUF_OFFSET, 0); } submit();
      compare((uint8_t *)storage + BUF_OFFSET, want, W, H, NULL, 0, 0, "P 内容 = 清屏蓝"); }
    done();

    // 8–13 组（见文件头）。BLACK_ST：缩放开时「退回 / 不缩」的记录，关时没有记录
    int BLACK_ST = on ? RS_BLACK : RS_NONE;
    const uint8_t ZERO[4] = {0, 0, 0, 0};
    rect yblock_cs[] = {{48, 32, 8, 8, {0}}}, yblock_fs[] = {{40, 28, 8, 8, {0}}}; memcpy(yblock_cs[0].c, YELLOW, 4); memcpy(yblock_fs[0].c, YELLOW, 4);

    // 8. 建时带存储图像标志（COMPRESSIBLE | IMAGE）的颜色目标 + 深度：第一次当渲染目标时照样缩（改前：标志一票否决，两份都 64x48 记录 2）
    phase = "8 带存储图像标志的颜色目标 + 深度：当目标时缩";
    NVNtexture F, FZ;
    make_tex(&F, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE); make_tex(&FZ, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE);
    begin(); { const NVNtexture *ts[1] = {&F}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &FZ, NULL); float f[4] = {1, 0, 0, 1};
        API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff);
        float g[4] = {0, 1, 0, 1}; API(nvnCommandBufferSetScissor)(&commands, r1[0].x, r1[0].y, r1[0].w, r1[0].h); API(nvnCommandBufferClearColor)(&commands, 0, g, 15); } submit();
    storage_is(&F, SCALED_ST, SW, SH); storage_is(&FZ, SCALED_ST, SW, SH);
    nvn_be_tex_storage_read(&F, raw, (size_t)SW * 4); paint(rawwant, SW, SH, RED, r1, 1, NUM, DEN);
    compare(raw, rawwant, SW, SH, NULL, 0, 0, "F 原样存储 = 手算的（缩小）图");
    paint(want, W, H, RED, r1, 1, 1, 1); read_game(&F, got); compare(got, want, W, H, NULL, 0, 0, "F ReadTexels = 游戏尺寸期望");
    done();

    // 9. 它真被计算派发当存储图像写：派发之前退回原尺寸（rs_pre_images），黄块落在游戏坐标 (48,32) 8x8、逐字节；原来的内容放大带过来（绿块边缘 1 像素带线性）
    //    反证在内容上：存储若还是 32x24，(48..55, 32..39) 全在界外，写入被丢，黄块不存在
    phase = "9 带存储图像标志的目标被计算派发写：先退回原尺寸";
    NVNimageHandle hF = image_handle(&F);
    begin(); API(nvnCommandBufferSetTexturePool)(&commands, &descriptors); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_COMPUTE, 0, hF);
    API(nvnCommandBufferBindProgram)(&commands, p_block, NVN_SHADER_STAGE_COMPUTE_BIT); API(nvnCommandBufferDispatchCompute)(&commands, 8, 8, 1); submit();
    storage_is(&F, BLACK_ST, W, H);
    { rect r9[] = {r1[0], yblock_cs[0]}; paint(want, W, H, RED, r9, 2, 1, 1); read_game(&F, got); compare(got, want, W, H, r9, 1, TOL, "F 派发后（黄块逐字节，绿块放大带边缘）");
      int ok = 1; for (int y = 32; y < 40; y++) for (int x = 48; x < 56; x++) ok &= !memcmp(got + 4 * (y * W + x), YELLOW, 4); REQUIRE(ok); }
    done();

    // 10. 开着的遍里（目标 T 已缩），片元着色器从图像槽只读一张缩放图 G（不是本遍附件）的纹素 (40,28)：这次绘制之前 G 就得是原尺寸（rs_pre_draw），
    //     读到黄（G 的黄块 32,24 16x16 内部），T 整张黄；只读图像不牵连本遍，T 仍是缩的。反证在内容上：G 若还是 32x24，(40,28) 在界外读到 0，T 是 0,0,0,0
    phase = "10 开着的遍里片元只读图像槽里的缩放图：绘制前退回原尺寸";
    NVNtexture G, T; rect rg[] = {{32, 24, 16, 16, {0}}}; memcpy(rg[0].c, YELLOW, 4);
    make_tex(&G, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE); make_tex(&T, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); clear_rt(&G, rg, 1, BLUE); submit(); storage_is(&G, SCALED_ST, SW, SH);
    NVNimageHandle hG = image_handle(&G);
    begin(); draw_setup(&T); draw_tri(p_green); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_FRAGMENT, 0, hG); draw_tri(p_read); submit();
    paint(want, W, H, YELLOW, NULL, 0, 1, 1); read_game(&T, got); compare(got, want, W, H, NULL, 0, 0, "T = 整张黄（读到 G 的 (40,28)）");   // 内容先核：缺口红在这里
    storage_is(&G, BLACK_ST, W, H); storage_is(&T, SCALED_ST, SW, SH);
    paint(want, W, H, BLUE, rg, 1, 1, 1); read_game(&G, got); compare(got, want, W, H, rg, 1, TOL, "G 退回后内容");
    nvn_be_tex_storage_read(&T, raw, (size_t)SW * 4); paint(rawwant, SW, SH, YELLOW, NULL, 0, 1, 1); compare(raw, rawwant, SW, SH, NULL, 0, 0, "T 原样存储 = 整张黄");
    done();

    // 11. 开着的遍里片元着色器往图像槽写（G2 不是本遍附件）：绘制前 G2 退回原尺寸，黄块落在 (40,28) 8x8、逐字节（底色蓝是单色，放大逐字节）；
    //     本遍附件 T2 也退回原尺寸（片元写存储图像时片元网格得是游戏分辨率），T2 = 第二笔的灰。反证：G2 若还是 32x24，x ≥ 32 / y ≥ 24 的写入在界外被丢
    phase = "11 开着的遍里片元写图像槽里的缩放图：绘制前退回原尺寸，本遍附件也退回";
    NVNtexture G2, T2;
    make_tex(&G2, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE); make_tex(&T2, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); clear_rt(&G2, NULL, 0, BLUE); submit(); storage_is(&G2, SCALED_ST, SW, SH);
    NVNimageHandle hG2 = image_handle(&G2);
    begin(); draw_setup(&T2); draw_tri(p_green); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_FRAGMENT, 0, hG2); draw_tri(p_write); submit();
    paint(want, W, H, BLUE, yblock_fs, 1, 1, 1); read_game(&G2, got); compare(got, want, W, H, NULL, 0, 0, "G2 = 蓝底 + 黄块 (40,28) 8x8");   // 内容先核：缺口红在这里
    storage_is(&G2, BLACK_ST, W, H); storage_is(&T2, BLACK_ST, W, H);
    paint(want, W, H, GREY, NULL, 0, 1, 1); read_game(&T2, got); compare(got, want, W, H, NULL, 0, 0, "T2 = 第二笔的灰");
    done();

    // 12. 图像槽里绑的就是本遍的附件 S（已缩、遍开着）：绘制前 S 退回原尺寸，遍按原尺寸接着画（同遍比例一致），第二笔的蓝盖满 64x48
    phase = "12 图像槽里是本遍附件：绘制前退回原尺寸，遍按原尺寸接着画";
    NVNtexture S_;
    make_tex(&S_, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE);
    begin(); clear_rt(&S_, NULL, 0, RED); submit(); storage_is(&S_, SCALED_ST, SW, SH);
    NVNimageHandle hS = image_handle(&S_);
    begin(); draw_setup(&S_); draw_tri(p_green); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_FRAGMENT, 0, hS); draw_tri(p_self); submit();
    storage_is(&S_, BLACK_ST, W, H);
    paint(want, W, H, BLUE, NULL, 0, 1, 1); read_game(&S_, got); compare(got, want, W, H, NULL, 0, 0, "S = 第二笔的蓝");
    done();

    // 13. 先被当存储图像用过（还没缩过）的贴图 K：记成不缩，以后当渲染目标也不缩（不来回换存储；缩小再放大会糊掉图像里的内容）。
    //     内容全程逐字节：新贴图的 0 + 计算写的黄块 (48,32) 8x8 + 当目标时带裁剪清的绿块 (0,0) 16x8
    phase = "13 先当存储图像用过的贴图：以后当渲染目标也不缩";
    NVNtexture K;
    make_tex(&K, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE);
    NVNimageHandle hK = image_handle(&K);
    begin(); API(nvnCommandBufferSetTexturePool)(&commands, &descriptors); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_COMPUTE, 0, hK);
    API(nvnCommandBufferBindProgram)(&commands, p_block, NVN_SHADER_STAGE_COMPUTE_BIT); API(nvnCommandBufferDispatchCompute)(&commands, 8, 8, 1); submit();
    storage_is(&K, BLACK_ST, W, H);
    begin(); { const NVNtexture *ts[1] = {&K}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL); float g[4] = {0, 1, 0, 1};
        API(nvnCommandBufferSetScissor)(&commands, 0, 0, 16, 8); API(nvnCommandBufferClearColor)(&commands, 0, g, 15); } submit();
    storage_is(&K, BLACK_ST, W, H);
    { rect rk[] = {yblock_cs[0], {0, 0, 16, 8, {0}}}; memcpy(rk[1].c, GREEN, 4); paint(want, W, H, ZERO, rk, 2, 1, 1); read_game(&K, got); compare(got, want, W, H, NULL, 0, 0, "K = 0 + 黄块 + 绿块"); }
    done();
    // 14. 派发开头（rs_pre_images，在图像原子升级与张量核网络顶替之前）就把图像槽里的缩放图退回原尺寸。用判成张量核网络的计算程序走到：它不派发、不经 rs_pre_compute，
    //     顶替按游戏尺寸的有效区域写输出图。这里它读的贴图一张没有，顶替自己报「没有…低分辨率画面，这一遍不写」（日志里那行【红】是预期的），输出图内容不变：单色红，放大逐字节
    phase = "14 派发开头退回图像槽里的缩放图（张量核网络顶替之前）";
    NVNtexture N;
    make_tex(&N, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE);
    begin(); clear_rt(&N, NULL, 0, RED); submit(); storage_is(&N, SCALED_ST, SW, SH);
    NVNimageHandle hN = image_handle(&N);
    begin(); API(nvnCommandBufferSetTexturePool)(&commands, &descriptors); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_COMPUTE, 0, hN);
    API(nvnCommandBufferBindProgram)(&commands, p_tensor, NVN_SHADER_STAGE_COMPUTE_BIT); API(nvnCommandBufferDispatchCompute)(&commands, 8, 8, 1); submit();
    storage_is(&N, BLACK_ST, W, H);
    paint(want, W, H, RED, NULL, 0, 1, 1); read_game(&N, got); compare(got, want, W, H, NULL, 0, 0, "N 内容不变");
    done();

    // 15. 覆盖面读数（rs_report 那一行的数）：按上面各组的步骤手数，不看被测实现的日志。
    //     缩了 13 份：A、C、D、P、PZ、F、FZ、G、T、G2、T2、S、N；退回 8 份：A（缓冲写入）、C（测试标记）、F / G / G2 / S / N（绑在存储图像槽，5）、T2（同一遍有片元阶段写存储图像）；
    //     不缩 3 次：Z（格式）、E（同一遍有不缩的附件）、K（先当存储图像用）；换存储失败 0。关（比例 1）时全是 0，也不打行。
    //     汇总行（rs_report_line，rs_report 打进日志的就是它）对着手写的期望逐字比
    phase = "15 覆盖面读数";
    { uint64_t skip = 0, back = 0, img = 0, fsw = 0, first = 0;
      for (int k = 0; k < RS_WHYN; k++) { skip += g_rs_skip_why[k].n; back += g_rs_back_why[k].n;
          if (g_rs_back_why[k].why && !strcmp(g_rs_back_why[k].why, "绑在存储图像槽")) img = g_rs_back_why[k].n;
          if (g_rs_back_why[k].why && !strcmp(g_rs_back_why[k].why, "同一遍有片元阶段写存储图像")) fsw = g_rs_back_why[k].n;
          if (g_rs_skip_why[k].why && !strcmp(g_rs_skip_why[k].why, "先当存储图像用")) first = g_rs_skip_why[k].n; }
      printf("  缩了 %llu / 退回 %llu / 失败 %llu；不缩 %llu 次（先当存储图像用 %llu）；退回按原因合计 %llu（绑在存储图像槽 %llu、同一遍有片元阶段写存储图像 %llu）\n", (unsigned long long)g_rs_up, (unsigned long long)g_rs_down,
             (unsigned long long)g_rs_fail, (unsigned long long)skip, (unsigned long long)first, (unsigned long long)back, (unsigned long long)img, (unsigned long long)fsw);
      if (on) REQUIRE(g_rs_up == 13 && g_rs_down == 8 && g_rs_fail == 0 && skip == 3 && first == 1 && back == 8 && img == 5 && fsw == 1);
      else REQUIRE(g_rs_up == 0 && g_rs_down == 0 && g_rs_fail == 0 && skip == 0 && back == 0);
      // 汇总行逐字比：期望手写（原因按第一次出现的先后：不缩 = 第 6 组的 Z、E，第 13 组的 K；退回 = 第 4 组 A、第 5 组 C、第 9 组 F、第 11 组 T2）。比例 1：不产生行、不动缓冲
      static char line[1536]; line[0] = 0; uint64_t sum = 0; int made = rs_report_line(300, line, sizeof line, &sum);
      char want_line[1024]; snprintf(want_line, sizeof want_line, "内部分辨率：到第 300 帧 %s 13 / 退回原尺寸 8 / 换存储失败 0 份；不缩（按原因）：%s", NUM > DEN ? "放大了" : "缩了",
          "格式（整数 / D16 / 只有模板：缩放拷贝画不了） ×1、同一遍有不缩的附件 ×1、先当存储图像用 ×1；退回（按原因）："
          "缓冲写入（CPU 数据） ×1、测试标记 ×1、绑在存储图像槽 ×5、同一遍有片元阶段写存储图像 ×1");
      printf("  汇总行：%s\n", made ? line : "（不产生）");
      if (on) { REQUIRE(made == 1); REQUIRE(!strcmp(line, want_line)); REQUIRE(sum == 13 + 8 + 0 + 3 + 8); }
      else { REQUIRE(made == 0); REQUIRE(line[0] == 0); }
      rs_report(300); }   // 生产入口照打一遍进日志（比例 1 不打）
    done();
    // 16. 待退回队列装满时不丢：把队列容量调成 1，一次绘制要退回 3 份存储（图像槽里的 G3 + 片元写图像牵连的本遍颜色 T3、深度 Z3）。
    //     三份都得在这次绘制之前退回原尺寸：G3 = 蓝底 + 黄块 (40,28) 8x8，T3 = 第二笔的灰，逐字节。改前：只有先进队的 G3 退回，T3 / Z3 被丢、仍是 32x24
    phase = "16 待退回队列装满（容量 1）：一次绘制要退回的 3 份存储都退回";
    { NVNtexture G3, T3, Z3;
      make_tex(&G3, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE); make_tex(&T3, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      make_tex(&Z3, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      begin(); clear_rt(&G3, NULL, 0, BLUE); submit(); storage_is(&G3, SCALED_ST, SW, SH);
      begin(); { const NVNtexture *ts[1] = {&T3}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &Z3, NULL); float f[4] = {1, 0, 0, 1};
          API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff); } submit();
      storage_is(&T3, SCALED_ST, SW, SH); storage_is(&Z3, SCALED_ST, SW, SH);
      NVNimageHandle hG3 = image_handle(&G3);
      int cap0 = g_rs_badq; g_rs_badq = 1;
      begin(); draw_setup_ds(&T3, &Z3); draw_tri(p_green); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_FRAGMENT, 0, hG3); draw_tri(p_write); submit();
      g_rs_badq = cap0;
      storage_is(&G3, BLACK_ST, W, H); storage_is(&T3, BLACK_ST, W, H); storage_is(&Z3, BLACK_ST, W, H);
      paint(want, W, H, BLUE, yblock_fs, 1, 1, 1); read_game(&G3, got); compare(got, want, W, H, NULL, 0, 0, "G3 = 蓝底 + 黄块 (40,28) 8x8");
      paint(want, W, H, GREY, NULL, 0, 1, 1); read_game(&T3, got); compare(got, want, W, H, NULL, 0, 0, "T3 = 第二笔的灰"); }
    done();

    // 17–22 组：放大（up 2、frac 1.5）专有的几处；scaled / off 下同样有手算期望（对照）
    // 17. 奇数坐标的裁剪清除：游戏矩形 x 5..14、y 3..10 → 存储矩形起点向下、终点向上取整（rs_rect），手算：
    //     0.5 → x ⌊2.5⌋=2..⌈7⌉=7、y ⌊1.5⌋=1..⌈5⌉=5；1 → 原样；2 → x 10..28、y 6..20；1.5 → x ⌊7.5⌋=7..⌈21⌉=21、y ⌊4.5⌋=4..⌈15⌉=15。
    //     整张读回在矩形边缘 1 个游戏像素内可混色（2 倍与关逐字节）；只读矩形自己那块（偏移不为 0 的子区域）每个纹素都得是绿：
    //     ReadTexels 的取样点 (x + 0.5) × s 所用的存储纹素全在存储矩形内（1.5：x=5 → 8.25 用 7、8 列，x=13 → 20.25 用 19、20 列；y=3 → 5.25 用 4、5 行，y=9 → 14.25 用 13、14 行）
    phase = "17 奇数坐标的裁剪清除：矩形取整 + 子区域读回";
    { NVNtexture O; rect ro[] = {{5, 3, 9, 7, {0, 255, 0, 255}}};
      static const rect so[4] = {{2, 1, 5, 4, {0, 255, 0, 255}}, {5, 3, 9, 7, {0, 255, 0, 255}}, {10, 6, 18, 14, {0, 255, 0, 255}}, {7, 4, 14, 11, {0, 255, 0, 255}}};   // 按 modes[] 的次序
      make_tex(&O, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      begin(); clear_rt(&O, ro, 1, RED); submit(); storage_is(&O, SCALED_ST, SW, SH);
      nvn_be_tex_storage_read(&O, raw, (size_t)SW * 4); paint(rawwant, SW, SH, RED, &so[mode], 1, 1, 1); compare(raw, rawwant, SW, SH, NULL, 0, 0, "O 原样存储 = 手算的存储矩形");
      paint(want, W, H, RED, ro, 1, 1, 1); read_game(&O, got); compare(got, want, W, H, ro, 1, on && NUM != 2 ? 1 : 0, "O ReadTexels（整张）");
      NVNcopyRegion sub = {5, 3, 0, 9, 7, 1}; static uint8_t part[9 * 7 * 4]; int ok = 1;
      memset(part, 0xA5, sizeof part); API(nvnTextureReadTexels)(&O, NULL, &sub, part);
      for (int i = 0; i < 9 * 7; i++) ok &= !memcmp(part + 4 * i, GREEN, 4);
      printf("  ReadTexels 子区域 (5,3) 9x7 全绿：%d\n", ok); REQUIRE(ok);
      // CopyTextureToBuffer 的区域按四舍五入换算（wd_copy_xy）再线性拷回：2 → 存储 x 10..28、y 6..20，每个游戏像素取 2x2 全在矩形内；
      //   1.5 → x 8..21（13 列 → 9）、y 5..15（10 行 → 7），取样点 8 + (px + 0.5) × 13 / 9 ∈ [8.72, 20.28] 用 8..20 列，5 + (py + 0.5) × 10 / 7 ∈ [5.71, 14.29] 用 5..14 行，全在矩形内。
      //   缩小局是线性放大（x 3..7 四列 → 9：最后一个像素取样点 6.78 用到矩形外的第 7 列，会混色），不在这里核
      if (NUM >= DEN) {
          memset((uint8_t *)storage + BUF_OFFSET, 0xA5, 9 * 7 * 4);
          begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands, &O, NULL, &sub, pa + BUF_OFFSET, 0); submit();
          ok = 1; for (int i = 0; i < 9 * 7; i++) ok &= !memcmp((uint8_t *)storage + BUF_OFFSET + 4 * i, GREEN, 4);
          printf("  CopyTextureToBuffer 子区域 (5,3) 9x7 全绿：%d\n", ok); REQUIRE(ok); } }
    done();

    // 18. 存储像素级的内容：整屏三角形按存储像素列的奇偶出红（偶）/ 绿（奇）。游戏坐标读回（两条路径）手算：
    //     关：游戏列 x 偶 = 红、奇 = 绿。0.5（ReadTexels 取最近纹素 ⌊(x + 0.5) / 2⌋ = ⌊x / 2⌋）：⌊x / 2⌋ 偶 = 红、奇 = 绿。
    //     2：每个游戏像素盖一红一绿两列，线性缩回 = 两者各半 = (127.5, 127.5, 0, 255)，取 127 或 128——只取其中一个纹素会是纯红或纯绿。
    //     1.5：取样点 1.5 x + 0.75。x = 2k → 3k + 0.75，用 3k 列（权 0.75）与 3k + 1 列（0.25）；x = 2k + 1 → 3k + 2.25，用 3k + 1 列（0.25）与 3k + 2 列（0.75）。
    //          k 偶：3k 偶红、3k + 1 奇绿、3k + 2 偶红 → 两个像素都是 0.75 红 + 0.25 绿 = (191.25, 63.75, 0, 255)；k 奇：反过来 = (63.75, 191.25, 0, 255)。容差 ±2
    phase = "18 存储像素级的条纹：游戏坐标读回是线性缩回";
    { NVNtexture Q; make_tex(&Q, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      begin(); draw_setup(&Q); draw_tri(p_stripe); submit(); storage_is(&Q, SCALED_ST, SW, SH);
      nvn_be_tex_storage_read(&Q, raw, (size_t)SW * 4);
      { int ok = 1; for (int y = 0; y < SH; y++) for (int x = 0; x < SW; x++) ok &= !memcmp(raw + 4 * (y * SW + x), x & 1 ? GREEN : RED, 4); printf("  原样存储 = 逐列红绿：%d\n", ok); REQUIRE(ok); }
      read_game(&Q, got);
      begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToBuffer)(&commands, &Q, NULL, &r, pa + BUF_OFFSET, 0); } submit();
      for (int path = 0; path < 2; path++) {
          if (path && NUM < DEN) continue;   // 缩小局的 CopyTextureToBuffer 是线性放大（另一种混色），第 3 组已核；这里只核 ReadTexels
          const uint8_t *g = path ? (uint8_t *)storage + BUF_OFFSET : got; int bad = 0, bx = 0, by = 0;
          for (int y = 0; y < H; y++) for (int x = 0; x < W && !bad; x++) {
              const uint8_t *q = g + 4 * (y * W + x); int er, eg, tol;
              if (NUM == 2) { er = eg = 128; tol = 1; }
              else if (NUM == 3) { er = (x / 2) & 1 ? 64 : 191; eg = 255 - er; tol = 2; }
              else if (NUM == 1 && DEN == 2) { er = (x / 2) & 1 ? 0 : 255; eg = 255 - er; tol = 0; }
              else { er = x & 1 ? 0 : 255; eg = 255 - er; tol = 0; }
              checks++;
              if (abs(q[0] - er) > tol || abs(q[1] - eg) > tol || q[2] != 0 || q[3] != 255) { bad = 1; bx = x; by = y;
                  fprintf(stderr, "FAIL [%s] %s (%d,%d) 得 %d,%d,%d,%d 期望 %d,%d,0,255（±%d）\n", phase, path ? "CopyTextureToBuffer" : "ReadTexels", bx, by, q[0], q[1], q[2], q[3], er, eg, tol); failed(); }
          }
          if (!bad) printf("  %s = 手算的线性缩回值（(0,0) 得 %d,%d,%d,%d）\n", path ? "CopyTextureToBuffer" : "ReadTexels", g[0], g[1], g[2], g[3]);
      } }
    done();

    // 19. 放大后任一边超过贴图上限的不放大（记成不缩）。上限用测试可调的 g_rs_texmax（生产 = 设备的上限）：
    //     2 倍取 100：L1 64x48 → 128x96 只有宽超、L2 48x64 → 96x128 只有高超；1.5 倍取 80：L1 → 96x72 只有宽超、L2 → 72x96 只有高超。两张都得留在原尺寸、记录 2。
    //     0.5 / 关取 16（比任何一边都小）：上限只管放大，L1 照样缩到 32x24、L2 24x32
    phase = "19 放大后超过贴图上限：不放大";
    { NVNtexture L1, L2; int max0 = g_rs_texmax; g_rs_texmax = NUM == 2 ? 100 : NUM == 3 ? 80 : 16;
      make_tex(&L1, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); TW = H; TH = W; make_tex(&L2, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); TW = W; TH = H;
      begin(); clear_rt(&L1, NULL, 0, BLUE); submit();
      begin(); { const NVNtexture *ts[1] = {&L2}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL); float f[4] = {0, 1, 0, 1};
          API(nvnCommandBufferSetScissor)(&commands, 0, 0, H, W); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); } submit();
      g_rs_texmax = max0;
      if (NUM > DEN) { storage_is(&L1, RS_BLACK, W, H); storage_is(&L2, RS_BLACK, H, W); }
      else { storage_is(&L1, SCALED_ST, SW, SH); storage_is(&L2, SCALED_ST, SH, SW); }
      paint(want, W, H, BLUE, NULL, 0, 1, 1); read_game(&L1, got); compare(got, want, W, H, NULL, 0, 0, "L1 内容"); }
    done();

    // 20. 方形 64x64：缩小时照 Ryujinx 的安全规则——深度（D32F）与单通道（R8）照缩，多通道颜色（RGBA8）不缩；
    //     放大时方形一律不放大（比 Ryujinx 严：方形多半是阴影图 / 查找表，放大 2 倍边长占 4 倍内存、对清晰度没用），三张都留在 64x64、记录 2
    phase = "20 方形：缩小时深度 / 单通道照缩，放大时一律不放大";
    { NVNtexture SQ1, SQZ, SQC; TW = TH = 64;
      make_tex(&SQ1, NVN_FORMAT_R8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&SQZ, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&SQC, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      TW = W; TH = H;
      begin(); { const NVNtexture *ts[1] = {&SQ1}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &SQZ, NULL); float f[4] = {1, 0, 0, 1};
          API(nvnCommandBufferSetScissor)(&commands, 0, 0, 64, 64); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff); } submit();
      begin(); { const NVNtexture *ts[1] = {&SQC}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL); float f[4] = {1, 0, 0, 1};
          API(nvnCommandBufferSetScissor)(&commands, 0, 0, 64, 64); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); } submit();
      if (NUM < DEN) { storage_is(&SQ1, RS_SCALED, 32, 32); storage_is(&SQZ, RS_SCALED, 32, 32); storage_is(&SQC, RS_BLACK, 64, 64); }
      else { int st = on ? RS_BLACK : RS_NONE; storage_is(&SQ1, st, 64, 64); storage_is(&SQZ, st, 64, 64); storage_is(&SQC, st, 64, 64); } }
    done();

    // 21. 19 / 20 组的「不缩」原因计数（手数）：放大——超过贴图上限 2 次（L1、L2）、方形（放大）3 次（SQ1、SQZ 各自判出，SQC），老的「方形」0 次；
    //     缩小——「方形」1 次（SQC），另两个原因 0 次；关——全 0
    phase = "21 放大专有的不缩原因计数";
    { uint64_t lim = 0, squp = 0, sq = 0;
      for (int k = 0; k < RS_WHYN; k++) { const char *w = g_rs_skip_why[k].why; if (!w) continue;
          if (!strcmp(w, "放大后超过贴图上限")) lim = g_rs_skip_why[k].n; if (!strcmp(w, "方形（放大时一律不放大）")) squp = g_rs_skip_why[k].n; if (!strcmp(w, "方形")) sq = g_rs_skip_why[k].n; }
      printf("  超过贴图上限 %llu、方形（放大） %llu、方形 %llu\n", (unsigned long long)lim, (unsigned long long)squp, (unsigned long long)sq);
      if (NUM > DEN) REQUIRE(lim == 2 && squp == 3 && sq == 0); else if (on) REQUIRE(lim == 0 && squp == 0 && sq == 1); else REQUIRE(lim == 0 && squp == 0 && sq == 0); }
    done();

    // 22. 换存储失败（单测开关 g_rs_fail_test：新存储当作建不出）：退回原尺寸失败的存储仍是缩放尺寸，记录也得仍是「已缩放」（画布尺寸还在），游戏坐标读回照旧对。
    //     原先记成不缩：记录说没缩放、存储却是缩放尺寸，之后的读回 / 视口 / 拷贝全按原尺寸算。开关关掉后再标一次：照常退回原尺寸。
    //     Y 先缩放好再开开关：开关开着的那一遍只有 X 的退回会去建存储。失败数只加 1；关（比例 1）：标记不起作用，什么都不变
    phase = "22 退回原尺寸失败：记录跟着实际存储走";
    { NVNtexture X, Y; uint64_t fail0 = g_rs_fail;
      make_tex(&X, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&Y, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      begin(); clear_rt(&X, r1, 1, RED); submit(); begin(); clear_rt(&Y, NULL, 0, BLUE); submit(); storage_is(&X, SCALED_ST, SW, SH); storage_is(&Y, SCALED_ST, SW, SH);
      g_rs_fail_test = 1; nvn_be_rs_mark_bad(&X); begin(); clear_rt(&Y, NULL, 0, BLUE); submit(); g_rs_fail_test = 0;   // Y 开遍 = 安全点：X 的退回在这里失败（日志里那行【红】是预期的）
      storage_is(&X, SCALED_ST, SW, SH); storage_is(&Y, SCALED_ST, SW, SH);
      printf("  换存储失败 %llu 次（期望 %d）\n", (unsigned long long)(g_rs_fail - fail0), on ? 1 : 0); REQUIRE(g_rs_fail - fail0 == (on ? 1u : 0u));
      paint(want, W, H, RED, r1, 1, 1, 1); read_game(&X, got); compare(got, want, W, H, NULL, 0, 0, "X 退回失败后 ReadTexels = 游戏尺寸期望");
      nvn_be_rs_mark_bad(&X); begin(); clear_rt(&Y, NULL, 0, BLUE); submit();
      storage_is(&X, BLACK_ST, W, H); read_game(&X, got); compare(got, want, W, H, r1, 1, TOL, "X 开关关掉后照常退回"); }
    done();

    // 23. ReadTexels 读第 1 级，宽 65（不整除）：第 0 级存储 ⌈65 s⌉，第 1 级存储是它的一半（向下取整），画布第 1 级 32 宽——这一级「存储 ÷ 画布」不等于设定比例：
    //     1.5 → 98 → 49，49 / 32 = 1.53125；2 → 130 → 65，65 / 32 = 2.03125；0.5 → 33 → 16，恰 0.5。读回得按这一级自己的比例取样，按设定比例会向左偏、漏掉末列。
    //     内容：还没缩放时用 ClearTexture 把第 1 级清成红、最后一列（x = 31）清成绿，再当渲染目标（第 0 级）→ 各级按整级缩放拷贝（线性）带过去。手算（r = 这一级的比例）：
    //       存储纹素 j 的来源位置 (j + 0.5) / r − 0.5；游戏像素 31 的取样位置 31.5 r − 0.5。
    //       1.5：取样 47.734 = 纹素 47（权 0.266）与 48（0.734）。纹素 47 来源 30.520 = 0.480 红 + 0.520 绿（G 133）；纹素 48 来源 31.17，右邻夹到 31 = 纯绿。
    //            G = 0.266 × 133 + 0.734 × 255 = 222.6，R = 255 − G = 32.4。（按设定比例 1.5 取样 46.75 = 纹素 46 纯红 0.25 + 纹素 47 0.75 → G 99.8：差 123）
    //       2：取样 63.484 = 纹素 63（0.516）与 64（0.484）。纹素 63 来源 30.762（G 194）；纹素 64 来源 31.25 纯绿。G = 0.516 × 194 + 0.484 × 255 = 223.5，R = 31.5。
    //            （按设定比例 2 取样 62.5 = 纹素 62（来源 30.27，G 69）与 63 各半 → G 131.5：差 92）
    //       0.5（取最近纹素）：像素 31 → 纹素 ⌊31.5 × 0.5⌋ = 15 = 来源第 30（红）、31（绿）列各半 = (127.5, 127.5)。关：纯绿。
    //     x = 0..29 四种模式都逐字节红（用到的存储纹素来源都在第 29 列以左）。容差 ±4（两次 8 位取整）
    phase = "23 读第 1 级（宽 65，各级比例不等于设定比例）";
    { NVNtexture M; TW = 65; TL = 2; make_tex(&M, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); TW = W; TL = 1;
      NVNtextureView v1; API(nvnTextureViewSetDefaults)(&v1); API(nvnTextureViewSetLevels)(&v1, 1, 1);
      begin(); { NVNcopyRegion a = {0, 0, 0, 32, 24, 1}, b = {31, 0, 0, 1, 24, 1}; float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1};
          API(nvnCommandBufferClearTexture)(&commands, &M, &v1, &a, red, 15); API(nvnCommandBufferClearTexture)(&commands, &M, &v1, &b, green, 15); } submit();
      begin(); clear_rt(&M, NULL, 0, BLUE); submit();
      storage_is(&M, SCALED_ST, NUM == 3 ? 98 : NUM == 2 ? 130 : on ? 33 : 65, SH);
      static uint8_t l1[32 * 24 * 4]; NVNcopyRegion r = {0, 0, 0, 32, 24, 1}; memset(l1, 0xA5, sizeof l1); API(nvnTextureReadTexels)(&M, &v1, &r, l1);
      int er = NUM > DEN ? 32 : on ? 128 : 0, eg = NUM > DEN ? 223 : on ? 128 : 255, tol = on ? 4 : 0, ok = 1, ok31 = 1;
      for (int y = 0; y < 24; y++) { for (int x = 0; x < 30; x++) ok &= !memcmp(l1 + 4 * (y * 32 + x), RED, 4);
          const uint8_t *q = l1 + 4 * (y * 32 + 31); ok31 &= abs(q[0] - er) <= tol && abs(q[1] - eg) <= tol && q[2] == 0 && q[3] == 255; }
      printf("  第 1 级 x 0..29 逐字节红：%d；x = 30 得 %d,%d,%d,%d；x = 31 得 %d,%d,%d,%d（期望 %d,%d,0,255 ±%d）\n", ok, l1[120], l1[121], l1[122], l1[123], l1[124], l1[125], l1[126], l1[127], er, eg, tol);
      REQUIRE(ok); REQUIRE(ok31); }
    done();

    // 24. 存储图像槽上的缩放图退不回原尺寸（单测开关让新存储建不出）：这次派发的图像读写按游戏整数坐标落在缩放存储上，位置不对——每次派发都得报红（RED_ONCE 185 的命中数），
    //     派发照旧进行。同一份存储换存储只试 RS_FAIL_MAX = 3 次（之后不再建新存储，免得每次绘制 / 派发都建一份）。手数：开关开着派发 5 次 → 红命中 5、失败数 +3、存储仍是缩放尺寸；
    //     开关关掉再派发 1 次 → 已试满 3 次，不再试：红命中 6、失败数不变、仍是缩放尺寸。关（比例 1）：全 0
    phase = "24 存储图像槽上的缩放图退不回：每次报红，换存储只试 3 次";
    { NVNtexture V; uint64_t fail0 = g_rs_fail; int red0 = RED_IMG_HITS;
      make_tex(&V, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE);
      begin(); clear_rt(&V, NULL, 0, RED); submit(); storage_is(&V, SCALED_ST, SW, SH);
      NVNimageHandle hV = image_handle(&V);
      for (int k = 0; k < 6; k++) { g_rs_fail_test = k < 5;
          begin(); API(nvnCommandBufferSetTexturePool)(&commands, &descriptors); API(nvnCommandBufferBindImage)(&commands, NVN_SHADER_STAGE_COMPUTE, 0, hV);
          API(nvnCommandBufferBindProgram)(&commands, p_block, NVN_SHADER_STAGE_COMPUTE_BIT); API(nvnCommandBufferDispatchCompute)(&commands, 8, 8, 1); submit();
          if (k == 4 || k == 5) { int hits = RED_IMG_HITS - red0; unsigned long long nf = g_rs_fail - fail0;
              printf("  第 %d 次派发后：红命中 %d（期望 %d）、换存储失败 %llu（期望 %d）\n", k + 1, hits, on ? k + 1 : 0, nf, on ? 3 : 0);
              REQUIRE(hits == (on ? k + 1 : 0)); REQUIRE(nf == (on ? 3u : 0u)); storage_is(&V, SCALED_ST, SW, SH); } }
      g_rs_fail_test = 0; }
    done();

    // 25–29 组：窗口贴图（上屏标志）。放大（up / frac）时它也按倍率建存储；缩小（scaled）照旧被标志否决、关（off）没有记录——两者都是 64x48（对照）
    //   单测设备是左下角原点（日志「window origin: lower left … present flipped」）：窗口图自下而上存，上屏 / 截图把它翻正。所以抓图与截图的期望 = 游戏坐标图上下翻转：
    //   绿块 (16,8) 32x16 → y = 48 − (8 + 16) = 24，即 r1f = (16,24) 32x16；裁剪区域整块同色的（26 组 b / c）翻不翻一样
    rect r1f[] = {{16, 24, 32, 16, {0}}}; memcpy(r1f[0].c, GREEN, 4);
    int UP = NUM > DEN, WSW = UP ? SW : W, WSH = UP ? SH : H, WIN_ST = UP ? RS_SCALED : on ? RS_BLACK : RS_NONE, WMUL = UP ? NUM : 1, WDIV = UP ? DEN : 1;

    // 25. 窗口贴图第一次当渲染目标：2 → 128x96、1.5 → 96x72（记录 1）；0.5 → 64x48 记录 2（标志否决，同改前）；1 → 64x48 记录 0。
    //     原样存储 = 手算的存储尺寸图（绿块 16,8 32x16 各坐标 × 比例），游戏坐标读回 = 游戏尺寸期望
    phase = "25 窗口贴图（上屏标志 0xd）：放大时按倍率建存储，缩小 / 关照旧原尺寸";
    NVNtexture WIN; make_tex(&WIN, NVN_FORMAT_RGBA8, WIN_FLAGS);
    begin(); clear_rt(&WIN, r1, 1, RED); submit();
    storage_is(&WIN, WIN_ST, WSW, WSH);
    nvn_be_tex_storage_read(&WIN, raw, (size_t)WSW * 4); paint(rawwant, WSW, WSH, RED, r1, 1, WMUL, WDIV); compare(raw, rawwant, WSW, WSH, NULL, 0, 0, "WIN 原样存储 = 手算的存储尺寸图");
    paint(want, W, H, RED, r1, 1, 1, 1); read_game(&WIN, got); compare(got, want, W, H, NULL, 0, 0, "WIN ReadTexels = 游戏尺寸期望");
    done();

    // 26. 上屏抓图（无窗口：抓图尺寸 = 画面按裁剪的宽高比、高取窗口贴图的高，全按游戏尺寸算）。四种模式期望相同（手算）：
    //     a 不带裁剪：64x48，内容 = 游戏尺寸期望（2 倍：每个出图像素的取样点 2x + 1 落在同色的两个存储纹素中间；1.5 倍：1.5x + 0.75，x = 2k 用 3k、3k+1 列，
    //       x = 2k+1 用 3k+1、3k+2 列，都在游戏列 2k..2k+1 对应的存储列 3k..3k+2 里，色块边是偶数坐标 → 同色，逐字节）；判据画面尺寸 64x48。
    //     b 裁剪 (16,8) 32x16 = 绿块：抓图 round(32 × 48 / 16) = 96 宽、48 高，全绿（取样夹在有效区的纹素中心内）；判据画面尺寸 32x16。
    //     c 奇数起点的裁剪 (5,3) 40x30，贴图上同一矩形清成绿：存储上清除矩形与上屏裁剪都是起点向下、终点向上取整（1.5 → x ⌊7.5⌋=7..⌈67.5⌉=68、y ⌊4.5⌋=4..⌈49.5⌉=50；
    //       2 → x 10..90、y 6..66），抓图 round(40 × 48 / 30) = 64 宽、48 高，全绿；判据画面尺寸 40x30。裁剪没换算成存储纹素时（2 倍）取到的是游戏 (2.5..22.5, 1.5..16.5)，
    //       左上一条在绿块外，是红。（裁剪不取更小的：1.5 倍下 9x7 的存储裁剪是 14x11，宽高比与 9:7 差 1.5%，过了上屏「差 1% 以内铺满」的线会留边——
    //       取整最多差 1 个存储纹素，画面边长 × 倍率 ≥ 约 200 时到不了 1%）
    phase = "26 窗口贴图上屏抓图：对外游戏尺寸，裁剪按画布 → 存储换算";
    present_grab(&WIN, NULL); grab_is(W, H, W, H); paint(want, W, H, RED, r1f, 1, 1, 1);
    if (grab_w == W && grab_h == H) compare(grab_px, want, W, H, NULL, 0, 0, "抓图（不带裁剪）= 游戏尺寸期望（翻正）");
    { int crop[4] = {16, 8, 32, 16}; present_grab(&WIN, crop); grab_is(96, 48, 32, 16); int ok = grab_all(GREEN); printf("  抓图（裁剪 16,8 32x16）全绿：%d\n", ok); REQUIRE(ok); }
    { NVNtexture WO; rect ro[] = {{5, 3, 40, 30, {0, 255, 0, 255}}}; make_tex(&WO, NVN_FORMAT_RGBA8, WIN_FLAGS);
      begin(); clear_rt(&WO, ro, 1, RED); submit(); storage_is(&WO, WIN_ST, WSW, WSH);
      int crop[4] = {5, 3, 40, 30}; present_grab(&WO, crop); grab_is(64, 48, 40, 30); int ok = grab_all(GREEN); printf("  抓图（裁剪 5,3 40x30）全绿：%d\n", ok); REQUIRE(ok); }
    done();

    // 27. 截图（dm_gfx_shot_at：下一次上屏时存 PNG）：四种模式都是 64x48、内容 = 游戏尺寸期望（放大的存储线性缩回，同色的纹素取平均仍是原色，逐字节）
    phase = "27 窗口贴图截图：PNG 是游戏尺寸";
    { char png[] = "/tmp/t_rscale_shot_XXXXXX.png"; int fd = mkstemps(png, 4); REQUIRE(fd >= 0); close(fd); unlink(png);
      dm_gfx_shot_at(0, png); nvn_be_present_wait(nvn_be_present((const tex_t *)&WIN, 0, NULL));
      static uint8_t px[W * H * 16]; size_t pw = 0, ph = 0; int rd = png_read(png, px, sizeof px, &pw, &ph); unlink(png);
      printf("  截图 %zux%zu（期望 %dx%d）\n", pw, ph, W, H); REQUIRE(rd); REQUIRE(pw == W && ph == H);
      if (rd && pw == W && ph == H) { paint(want, W, H, RED, r1f, 1, 1, 1); compare(px, want, W, H, NULL, 0, 0, "截图 = 游戏尺寸期望（翻正）"); } }
    // sRGB 格式的窗口贴图，存储像素列红（偶）/ 绿（奇）相间（fs_stripe，同第 18 组）：截图与上屏抓图取的都是存储原字节（上屏不解码 sRGB：present_raw_src），
    //   缩回游戏尺寸是原字节的线性混合，两者一致。手算（同第 18 组）：2 → 每个游戏像素一红一绿各半 = (127.5, 127.5)；1.5 → x/2 偶 (191.25, 63.75)、奇 (63.75, 191.25)；
    //   0.5 / 关（存储就是游戏尺寸）→ x 偶红、奇绿。若按解码后的线性光混合再编码：2 倍是 (188, 188)，差 60。容差同第 18 组
    { NVNtexture WS; make_tex(&WS, NVN_FORMAT_RGBA8_SRGB, WIN_FLAGS);
      begin(); draw_setup(&WS); draw_tri(p_stripe); submit(); storage_is(&WS, WIN_ST, WSW, WSH);
      char png[] = "/tmp/t_rscale_shot_XXXXXX.png"; int fd = mkstemps(png, 4); REQUIRE(fd >= 0); close(fd); unlink(png);
      dm_gfx_shot_at(0, png); present_grab(&WS, NULL);
      static uint8_t px[W * H * 16]; size_t pw = 0, ph = 0; int rd = png_read(png, px, sizeof px, &pw, &ph); unlink(png);
      REQUIRE(rd && pw == W && ph == H); grab_is(W, H, W, H);
      for (int path = 0; path < 2 && rd && pw == W && ph == H && grab_w == W && grab_h == H; path++) {
          const uint8_t *g = path ? grab_px : px; int bad = 0;
          for (int y = 0; y < H && !bad; y++) for (int x = 0; x < W && !bad; x++) {
              const uint8_t *q = g + 4 * (y * W + x); int er, eg, tol;
              if (UP && NUM == 2) { er = eg = 128; tol = 1; } else if (UP) { er = (x / 2) & 1 ? 64 : 191; eg = 255 - er; tol = 2; } else { er = x & 1 ? 0 : 255; eg = 255 - er; tol = 0; }
              checks++;
              if (abs(q[0] - er) > tol || abs(q[1] - eg) > tol || q[2] != 0) { bad = 1;
                  fprintf(stderr, "FAIL [%s] sRGB 窗口贴图%s (%d,%d) 得 %d,%d,%d 期望 %d,%d,0（±%d）\n", phase, path ? "抓图" : "截图", x, y, q[0], q[1], q[2], er, eg, tol); failed(); } }
          if (!bad) printf("  sRGB 窗口贴图%s = 存储原字节的线性混合（(0,0) 得 %d,%d,%d）\n", path ? "抓图" : "截图", g[0], g[1], g[2]); } }
    done();

    // 28. 上屏抗锯齿（SMAA）与 MetalFX：抓图的出图是 64x48。
    //     抗锯齿：中间图取「存储裁剪」与「它在出图上的视口」里小的那个 = 64x48（四种模式相同；按存储尺寸建是 128x96 / 96x72，s² 倍内存）；内容在色块边 2 个像素以外逐字节。
    //     MetalFX：输入（存储裁剪）≥ 输出（视口）不是放大，不建放大器（槽是空的），出图照旧双线性、逐字节
    phase = "28 窗口贴图上屏：抗锯齿中间图不按存储尺寸建，MetalFX 输入 ≥ 输出时不建";
    present_options(); paint(want, W, H, RED, r1f, 1, 1, 1);
    g_present_aa = 3; present_grab(&WIN, NULL); g_present_aa = 0; grab_is(W, H, W, H);
    { NvPresentAA *aa = g_present_aa_slots[3]; unsigned long aw = aa ? aa->input.width : 0, ah = aa ? aa->input.height : 0;
      printf("  抗锯齿中间图 %lux%lu（期望 %dx%d）\n", aw, ah, W, H); REQUIRE(aw == W && ah == H); }
    if (grab_w == W && grab_h == H) compare(grab_px, want, W, H, r1f, 1, 2, "抓图（开抗锯齿）");
    g_present_fx = 1; present_grab(&WIN, NULL); g_present_fx = 0; grab_is(W, H, W, H);
    printf("  MetalFX 槽：%s（期望 空）\n", g_present_fx_slots[3] ? "建了" : "空"); REQUIRE(g_present_fx_slots[3] == nil);
    if (grab_w == W && grab_h == H) compare(grab_px, want, W, H, NULL, 0, 0, "抓图（滤镜 MetalFX，不是放大）");
    done();

    // 29. 已放大的图 SC 整张拷进还没当过渲染目标的窗口贴图 W2（游戏用拷贝把场景交给窗口贴图的那条路）：放大时 W2 跟着放大（同比例 = 原样拷贝，存储逐字节）；
    //     缩小 / 关：W2 不动（64x48、没有记录，同改前），内容 = 游戏尺寸期望（缩放拷贝取最近纹素，同第 2 组）。抓图 64x48 = 游戏尺寸期望
    phase = "29 已放大的图拷进窗口贴图：窗口贴图跟着放大";
    { NVNtexture SC, W2; make_tex(&SC, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&W2, NVN_FORMAT_RGBA8, WIN_FLAGS);
      begin(); clear_rt(&SC, r1, 1, RED); submit(); storage_is(&SC, SCALED_ST, SW, SH);
      begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToTexture)(&commands, &SC, NULL, &r, &W2, NULL, &r, 0); } submit();
      storage_is(&W2, UP ? RS_SCALED : RS_NONE, WSW, WSH);
      nvn_be_tex_storage_read(&W2, raw, (size_t)WSW * 4); paint(rawwant, WSW, WSH, RED, r1, 1, WMUL, WDIV); compare(raw, rawwant, WSW, WSH, NULL, 0, 0, "W2 原样存储 = 手算的存储尺寸图");
      paint(want, W, H, RED, r1, 1, 1, 1); read_game(&W2, got); compare(got, want, W, H, NULL, 0, 0, "W2 ReadTexels = 游戏尺寸期望");
      present_grab(&W2, NULL); grab_is(W, H, W, H); paint(want, W, H, RED, r1f, 1, 1, 1); if (grab_w == W && grab_h == H) compare(grab_px, want, W, H, NULL, 0, 0, "W2 抓图 = 游戏尺寸期望（翻正）"); }
    done();

    // 30. 缩放过的深度（D32F）拷进打包的原尺寸深度图（打包贴图建时不带渲染目标用途），以及拷进普通的原尺寸深度图。D-HT4P：渲染倍率不是 1x 时，
    //     1080x608 → 1440x810 这笔深度拷贝走到「没实现」、目标留旧深度，3D 场景按旧深度算雾 → 隔几帧蒙一层白。
    //     期望（手算）：两笔拷贝都不走「没实现」（g_t2t_unimpl 不涨；修前打包目标那笔 +1）；普通目标读回全图 = 源清成的 0.25（证明深度缩放拷贝写得对）。
    //     打包目标不读回：打包图的 ReadTexels 读包里数据，读存储对深度图本身不可用
    phase = "30 缩放深度拷进不带渲染目标用途的原尺寸深度图";
    { extern uint64_t g_t2t_unimpl; NVNtexture ZA, ZB, ZC; static uint8_t zpkg[1 << 20]; for (int i = 0; i < (1 << 20) / 4; i++) ((float *)zpkg)[i] = 0.5f;
      make_tex(&ZA, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex_pkg(&ZB, NVN_FORMAT_DEPTH32F, 0, zpkg); make_tex(&ZC, NVN_FORMAT_DEPTH32F, 0);
      begin(); { API(nvnCommandBufferSetRenderTargets)(&commands, 0, NULL, NULL, &ZA, NULL); API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H);
          API(nvnCommandBufferClearDepthStencil)(&commands, 0.25f, 1, 0, 0xff); } submit();
      uint64_t u0 = g_t2t_unimpl;
      begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToTexture)(&commands, &ZA, NULL, &r, &ZB, NULL, &r, 0);
          API(nvnCommandBufferCopyTextureToTexture)(&commands, &ZA, NULL, &r, &ZC, NULL, &r, 0); } submit();
      printf("  走到「没实现」%llu 次（期望 0）\n", (unsigned long long)(g_t2t_unimpl - u0)); REQUIRE(g_t2t_unimpl == u0);
      float *zw = (float *)want; for (int i = 0; i < W * H; i++) zw[i] = 0.25f;
      read_game(&ZC, got); compare(got, want, W, H, NULL, 0, 0, "ZC 深度 = 0.25（缩放深度拷贝写对）"); }
    done();

    // 31. 片元着色器绑定检查（rs_bind_check）：尺寸表 ABI2 下 legacy_1x、原因全是「宿主从不缩放的种类」（翻译器 never_scaled_*，rs_never）的，读放大图不退回（二维取图走取图倍率）；
    //     同样 legacy_1x、原因是别的（rs_never = 0），照旧在下一个安全点退回
    phase = "31 只因读从不缩放种类而 legacy_1x 的片元着色器";
    { NVNtexture G1, G2, G3; make_tex(&G3, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&G1, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&G2, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      begin(); clear_rt(&G1, NULL, 0, BLUE); submit(); begin(); clear_rt(&G2, NULL, 0, BLUE); submit();
      storage_is(&G1, SCALED_ST, SW, SH); storage_is(&G2, SCALED_ST, SW, SH);
      NvShader *fs = [NvShader new]; fs->stage = 1; fs->exact = 1; fs->size_abi = 1; fs->size_exact = 0;
      fs->rs_never = 1; rs_bind_check(tex_mtl((const tex_t *)&G1), fs, 1, 0);
      fs->rs_never = 0; rs_bind_check(tex_mtl((const tex_t *)&G2), fs, 1, 0);
      begin(); clear_rt(&G3, NULL, 0, RED); submit();   // 别的目标开遍：安全点
      storage_is(&G1, SCALED_ST, SW, SH); storage_is(&G2, on ? RS_BLACK : RS_NONE, W, H);
      printf("  rs_never=1 读后仍是放大存储，rs_never=0 读后退回原尺寸\n"); }
    done();

    // 32. 计算阶段读缩放图（11-22 D-ZR6V：主场景深度被计算着色器读、整遍退回）：尺寸表精确（size_abi && size_exact）的计算程序按槽号读（kind 0）不退回；
    //     尺寸表不精确的、经统一缓冲句柄取图（kind 3）的、张量核网络顶替（tensor == 1）的，照旧在下一个安全点退回
    phase = "32 计算阶段读缩放图";
    { NVNtexture K1, K2, K3, K4, K5; NVNtexture *ks[] = { &K1, &K2, &K3, &K4 };
      for (int k = 0; k < 4; k++) { make_tex(ks[k], NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); begin(); clear_rt(ks[k], NULL, 0, BLUE); submit(); storage_is(ks[k], SCALED_ST, SW, SH); }
      make_tex(&K5, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      NvShader *cs = [NvShader new]; cs->stage = 5; cs->size_abi = 1; cs->size_exact = 1;
      rs_bind_check(tex_mtl((const tex_t *)&K1), cs, 5, 0);                    // 精确、按槽号：放行
      rs_bind_check(tex_mtl((const tex_t *)&K2), cs, 5, 3);                    // 精确、句柄取图：退回
      cs->size_exact = 0; rs_bind_check(tex_mtl((const tex_t *)&K3), cs, 5, 0); // 不精确：退回
      cs->size_exact = 1; cs->tensor = 1; rs_bind_check(tex_mtl((const tex_t *)&K4), cs, 5, 0); cs->tensor = 0;   // 张量核顶替：退回
      begin(); clear_rt(&K5, NULL, 0, RED); submit();   // 别的目标开遍：安全点
      storage_is(&K1, SCALED_ST, SW, SH);
      for (int k = 1; k < 4; k++) storage_is(ks[k], on ? RS_BLACK : RS_NONE, W, H);
      printf("  精确计算程序按槽号读后仍是放大存储；句柄取图 / 不精确 / 张量核顶替读后退回原尺寸\n"); }
    done();
    unlink(map); unlink(user);
    if (fails) { printf("t_nvn_rscale %s：%u 组、%u 项里 %u 项不通\n", argv[1], cases, checks, fails); return 1; }

    printf("t_nvn_rscale %s：%u 组、%u 项全过\n", argv[1], cases, checks);
    }
    return 0;
}
