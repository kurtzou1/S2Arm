// 直连宽屏：放宽过的多重采样渲染目标解析（Downsample）到游戏同尺寸的单样本贴图（widen_glue.inc wd_widen_resolve_dst，10-30 直连缺陷表 Fit Boxing / 哆啦A梦牧场物语 / 植物大战僵尸：
//   「Downsample case not implemented: 1564x720 2 samples → 1280x720 1 sample」，同几款满屏判据「某列起明显变暗」）。直接包含生产 nvn_mtl.m，真 Metal 设备 + 真宽屏核心。
// 期望手算（与被测实现无关）：屏宽 2346、整套放宽，k = 2346 / 1920，720 高目标放宽宽 = 1280 × k = 1564（同 t_nvn_wdusage）。
//   源 = 1280x720 2 样本 RGBA8 渲染目标，按开遍的生产路径放宽（wd_widen_rts）到 1564，再用测试自己的渲染遍整张清成红 (255, 0, 0, 255)。
//   ① 解析后目标存储宽 1564、高 720（随源放宽）；② 目标 (100, 360)、(1500, 360)（放宽外延里）、(1563, 719) 都 = 红：整张解析了，外延也有内容
//   ③ 反证：源没放宽（宽屏关）时目标不动、仍 1280 宽，解析照旧整张（(100, 360) = 红）——这条改动只在源放宽时起作用
// 窄屏加高的源拷进没加高的贴图（11-02 丝之歌 Duo 外屏重影：主场景每帧整张拷进一张 1024×576 普通贴图，再被全屏叠回场景；拷贝区域只换 x 不换 y，
//   只拷了加高存储上面 576 行 → 叠回去的那份放大约 Ky 倍、上下错开）。期望手算：屏 1920×1318，1080 高额外行 2·round(540·(16/9 ÷ 1920/1318 − 1)) = 238，
//   576 高 → 576 + 2·round(576 × 238 / 1080 / 2) = 702。源存储 [0, 351) 行红、[351, 702) 行绿，整张（游戏坐标 1024×576）拷进 1024×576 的单样本贴图：
//   ④ 同尺寸同矩形拷贝，目的随源加高到 1024×702（同 ⑪ 横向：目的随源放宽；11-05 前只看宽、加高的源不带目的，目的停在 576、按比例压缩拷）；
//   ⑤ 一比一拷：(100, 250) = 红、(100, 330) = 红、(100, 400) = 绿（分界 351）
// 窄屏加高的多重采样目标解析（11-05 哆啦A梦牧场 Duo 标题：两样本 54 加高后解析进 55，55 没登记、上屏居中原尺寸盖在中间，上下条带露出拉满的场景、两条接缝）：
//   屏 1920×1318，720 高 → 720 + 2·round(720 × 238 / 1080 / 2) = 720 + 2·79 = 878。源 1280x720 两样本随开遍加高到 1280x878、整张清红：
//   ⑭ 解析后目标存储 1280x878（随源加高；改前停在 720）；(100, 870) = 红（加高出的下沿也有内容）
// 窄屏加高目标上的带剪刀清屏（审计 P1-79：原先只换算 x）：同 ④ 的 1024x576 → 702 加高目标，游戏坐标 [288, 576) 行按核心高 ÷ 游戏高换算：
//   ⑧ 288 × 702 / 576 = 351、576 × 702 / 576 = 702（起点向下、终点向上取整，整除无余数）；没加高的目标（另建一张没用过的 1024x576 普通贴图）原样 [288, 576)
// 放宽目标第 1 级的贴图区域清除（11-02 马力欧派对泛光 mip 链：每级按游戏尺寸清、按游戏视口画，放宽出来的右侧条带一直是旧显存，合成时采成彩色方块）：
//   1280x720 两级的渲染目标放宽到 1564，存储第 1 级 782x360；游戏清第 1 级整张 640x360：⑨ 存储第 1 级 (780, 100) 也被清成绿（改前只清到 640 列，仍是红）；
//   ⑩ 第 1 级带剪刀的 x [320, 640) 按第 0 级换算：640 · 1564 / 1280 = 782、1280 · 1564 / 1280 = 1564，各除 2 → [391, 782)
// 贴图区域清除报核心（11-02 马里奥和索尼克东京2020 局内左侧 9% 黑：半尺寸特效层每帧用贴图清除清成 (0, 0, 0, 1)，没报核心，首笔粒子按「两侧无内容」把 [0, 88) 清成 0，
//   合成时场景乘它的 alpha 变黑）：⑫ 同一帧两张 800x450 → 977 放宽目标，首笔半透明子视口；整宽贴图清除过的不交两侧条带、没清过的照旧交（手算：条带 = (977 − 800) / 2 = 88 起）；
//   ⑫' 清除早于存储放宽：放宽时按同一清除把新存储整张清满（右条带 970 列也是清除值，不是零），第一笔不交条带
// 贴图清除是 GPU 写（11-02 马里奥索尼克选手名单页：特效层本帧只被清、没画，合回场景那笔被当成 CPU 供的 16:9 图起原比例页、两侧 [0, 178) 清黑）：
//   ⑬ 放宽目标上铺满画布采样一张没放宽的 1600x900 贴图——没清过的对照起原比例页（画法 4），贴图清除过的不起
// 缩放解析（11-02 数码宝贝物语 时空异客：「Downsample case not implemented: 2346x1080 4 samples → 1564x720 1 samples」，关满屏时是 1920x1080 → 1280x720，同样尺寸不同）：
//   游戏把掌机 1280x720 画在 1920x1080 多重采样目标的一角，解析的是那一角（Mac 快测 dg_qt2：按整张缩放时整帧落在左下 2/3、其余黑）：源 x < 960 红、其余绿，第 720 行起蓝（角外）。
//   ⑥ 关满屏：目标 1280x720 取源左上 1280x720：(700, 360) = 红（整张缩放时 700 列取源 1050 列 = 绿）、(1100, 360) = 绿、(1279, 719) = 绿（不是蓝：取的是上面 720 行）
//   ⑦ 开满屏（屏宽 2346）：源放宽到 2346、x < 1173 红；目标随源放宽到 1564，取源左上 1564x720：(900, 360) = 红（整张缩放时 = 绿）、(1300, 360) = 绿、(1563, 719) = 绿
// 同尺寸同矩形的普通拷贝（11-02 马里奥和索尼克东京2020：放宽的 1920x1080 画布每帧拷进没放宽的交换链）：源 1920x1080 渲染目标放宽到 2346、x < 1173 红其余绿（第 720 行起蓝），
//   拷左上 1280x720 到同尺寸普通贴图：⑪ 目的随源放宽到 2346；(900, 360) = 红、(1300, 360) = 绿（源放宽一角 [0, 1564) 原样拷；按各自存储换算成压缩拷贝时 1300 列取源 1588 列外 = 不是绿）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static pool_t *g_pool_t;
static uint32_t g_levels = 1;   // make_tex 建的级数（⑨ 用两级）
static uint32_t g_fmt = NVN_FORMAT_RGBA8;   // make_tex 建的格式（⑯ 目标用 BGRA8）
static size_t g_next;
static void make_tex(tex_t *t, int w, int h, int samples) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = samples > 1 ? NVN_TEXTURE_TARGET_2D_MULTISAMPLE : NVN_TEXTURE_TARGET_2D, .format = g_fmt, .samples = samples,
                         .width = (uint32_t)w, .height = (uint32_t)h, .depth = 1, .levels = g_levels};
    t->pool = g_pool_t; t->off = g_next; t->mem = g_pool_t->mem + g_next; nvn_tex_layout(&t->d, &t->L); g_next += (t->L.size + 65535) & ~(size_t)65535;
    REQUIRE(g_next <= g_pool_t->size); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void clear_red_lv(id<MTLTexture> t, NSUInteger lv);
static void clear_red(id<MTLTexture> t) { clear_red_lv(t, 0); }
static void clear_red_lv(id<MTLTexture> t, NSUInteger lv) {   // the test's own queue and pass: every sample of the (widened) storage's level lv red
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].level = lv; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
}
static uint32_t px_at_lv(id<MTLTexture> t, NSUInteger lv, NSUInteger x, NSUInteger y);
static uint32_t px_at(id<MTLTexture> t, NSUInteger x, NSUInteger y) { return px_at_lv(t, 0, x, y); }
static uint32_t px_at_lv(id<MTLTexture> t, NSUInteger lv, NSUInteger x, NSUInteger y) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:lv sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    return *(uint32_t *)b.contents;
}
static const uint32_t RED = 255u | 255u << 24;   // RGBA8 little endian: R in the low byte

static id<MTLTexture> resolve(int widen) {   // → the destination's storage after one Downsample of a red source
    static tex_t src, dst;
    make_tex(&src, 1280, 720, 2); make_tex(&dst, 1280, 720, 1);
    nvn_be_sub_begin();
    if (widen) { memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &src; R.has_rt = 1; wd_widen_rts(); rp_end(); }   // the production path that widens a target as its pass opens
    uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull));
    if (widen) REQUIRE(tex_mtl(&src).width == 1564);
    clear_red(tex_mtl(&src));
    nvn_be_sub_begin();
    p_copy_t2t c; memset(&c, 0, sizeof c); c.src = &src; c.dst = &dst; c.flags = DM_COPY_RESOLVE;
    c.sr = (NVNcopyRegion){.width = 1280, .height = 720, .depth = 1}; c.dr = c.sr;
    copy_t2t(&c);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    return tex_mtl(&dst);
}

static tex_t g_tall_src, g_tall_dst;   // ⑧ reads their clear mapping after ④
static id<MTLTexture> tall_copy(void) {   // → the destination's storage after one plain copy of a tall source (top half red, bottom half green)
    make_tex(&g_tall_src, 1024, 576, 1); make_tex(&g_tall_dst, 1024, 576, 1);
    nvn_be_sub_begin();
    memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &g_tall_src; R.has_rt = 1; wd_widen_rts(); rp_end();
    uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull));
    id<MTLTexture> s = tex_mtl(&g_tall_src); REQUIRE(s.width == 1024 && s.height == 702);
    clear_red(s);
    NSUInteger rows = 702 - 351; id<MTLBuffer> g = [g_dev newBufferWithLength:1024 * 4 * rows options:MTLResourceStorageModeShared];
    for (NSUInteger i = 0; i < 1024 * rows; i++) ((uint32_t *)g.contents)[i] = 255u << 8 | 255u << 24;
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:g sourceOffset:0 sourceBytesPerRow:1024 * 4 sourceBytesPerImage:1024 * 4 * rows sourceSize:MTLSizeMake(1024, rows, 1) toTexture:s destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 351, 0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    nvn_be_sub_begin();
    p_copy_t2t c; memset(&c, 0, sizeof c); c.src = &g_tall_src; c.dst = &g_tall_dst;
    c.sr = (NVNcopyRegion){.width = 1024, .height = 576, .depth = 1}; c.dr = c.sr;
    copy_t2t(&c);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    return tex_mtl(&g_tall_dst);
}
static const uint32_t GREEN = 255u << 8 | 255u << 24;

static void fill_split(id<MTLTexture> t, float split, float rows) {   // the test's own pass: rows from y = rows down blue; above them left of x = split red, the rest green
    static id<MTLRenderPipelineState> ps;
    if (!ps) {
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
            "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); return o; }\n"
            "fragment float4 fs(V in [[stage_in]], constant float2 &sp [[buffer(0)]]) { return in.p.y >= sp.y ? float4(0, 0, 1, 1) : in.p.x < sp.x ? float4(1, 0, 0, 1) : float4(0, 1, 0, 1); }\n" options:nil error:&e];
        REQUIRE(lib);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = t.pixelFormat; pd.rasterSampleCount = t.sampleCount; ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e]; REQUIRE(ps);
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; float sp[2] = {split, rows}; [en setFragmentBytes:sp length:sizeof sp atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
}
static int g_sr_x;   // ⑮：源矩形起点 x（游戏坐标）
static id<MTLTexture> resolve_scaled(int widen) {   // → the destination's storage after one Downsample of a 1920x1080 4-sample split source into a 1280x720 texture
    static tex_t src[3], dst[3]; int k = g_sr_x ? 2 : widen;   // ⑮ 用第三组（不放宽）
    make_tex(&src[k], 1920, 1080, 4); make_tex(&dst[k], 1280, 720, 1);
    nvn_be_sub_begin();
    if (widen) { memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &src[k]; R.has_rt = 1; wd_widen_rts(); rp_end(); }
    uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull));
    id<MTLTexture> s = tex_mtl(&src[k]); REQUIRE(s.width == (widen ? 2346 : 1920));
    fill_split(s, s.width / 2.0f, 720.0f);
    nvn_be_sub_begin();
    p_copy_t2t c; memset(&c, 0, sizeof c); c.src = &src[k]; c.dst = &dst[k]; c.flags = DM_COPY_RESOLVE;
    c.sr = (NVNcopyRegion){.xoffset = g_sr_x, .width = 1920 - g_sr_x, .height = 1080, .depth = 1}; c.dr = (NVNcopyRegion){.width = 1280, .height = 720, .depth = 1};
    copy_t2t(&c);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    return tex_mtl(&dst[k]);
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        uint8_t *memory = NULL; size_t sz = 256 << 20; REQUIRE(!posix_memalign((void **)&memory, 65536, sz)); memset(memory, 0, sz);
        g_pool_t = calloc(1, sizeof *g_pool_t); REQUIRE(g_pool_t);
        *g_pool_t = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = sz};
        nvn_be_pool_add(memory, sz);

        id<MTLTexture> d0 = resolve(0);   // ③ first: the widen core is still off
        VERIFY(d0.width == 1280 && px_at(d0, 100, 360) == RED, "③ 反证：源没放宽 → 目标仍 %lu 宽（期望 1280），(100, 360) = %08x（期望 %08x）", (unsigned long)d0.width, px_at(d0, 100, 360), RED);

        id<MTLTexture> n0 = resolve_scaled(0);
        { uint32_t a = px_at(n0, 700, 360), b = px_at(n0, 1100, 360), e = px_at(n0, 1279, 719);
          VERIFY(n0.width == 1280 && a == RED && b == GREEN && e == GREEN, "⑥ 关满屏 1920x1080 4 样本 → 1280x720 取左上一角：宽 %lu（期望 1280），(700, 360) = %08x（期望红 %08x）、(1100, 360) = %08x、(1279, 719) = %08x（期望绿 %08x；整张缩放时 700 列取源 1050 列 = 绿）",
                 (unsigned long)n0.width, a, RED, b, e, GREEN); }

        g_sr_x = 640; id<MTLTexture> n1 = resolve_scaled(0); g_sr_x = 0;
        { uint32_t a = px_at(n1, 100, 360), b = px_at(n1, 400, 360);
          VERIFY(n1.width == 1280 && a == RED && b == GREEN, "⑮ 源矩形从 x 640 起的缩放解析（审计 P1-88）：(100, 360) 取源 740 列 = %08x（期望红）、(400, 360) 取源 1040 列 = %08x（期望绿；原点写死 0 时取源 400 列 = 红）", a, b); }
        g_wd = s2a_widen_init(2346, 1080, S2A_WIDEN_FULL); REQUIRE(g_wd == S2A_WIDEN_ALL);
        id<MTLTexture> w0 = resolve_scaled(1);
        { uint32_t a = w0.width > 1563 ? px_at(w0, 900, 360) : 0, b = w0.width > 1563 ? px_at(w0, 1300, 360) : 0, e = w0.width > 1563 ? px_at(w0, 1563, 719) : 0;
          VERIFY(w0.width == 1564 && a == RED && b == GREEN && e == GREEN, "⑦ 开满屏取左上一角：目标宽 %lu（期望随源放宽到 1564），(900, 360) = %08x（期望红）、(1300, 360) = %08x、(1563, 719) = %08x（期望绿：分界 1173）",
                 (unsigned long)w0.width, a, b, e); }
        {   // ⑪ 同尺寸同矩形的普通拷贝：目的随源放宽
            static tex_t cs, cd; make_tex(&cs, 1920, 1080, 1); make_tex(&cd, 1920, 1080, 1);
            nvn_be_sub_begin(); memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &cs; R.has_rt = 1; wd_widen_rts(); rp_end();
            uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull));
            id<MTLTexture> s = tex_mtl(&cs); REQUIRE(s.width == 2346); fill_split(s, s.width / 2.0f, 720.0f);
            nvn_be_sub_begin();
            p_copy_t2t c; memset(&c, 0, sizeof c); c.src = &cs; c.dst = &cd; c.sr = (NVNcopyRegion){.width = 1280, .height = 720, .depth = 1}; c.dr = c.sr;
            copy_t2t(&c);
            uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            id<MTLTexture> t = tex_mtl(&cd); uint32_t a = t.width > 1300 ? px_at(t, 900, 360) : 0, b = t.width > 1300 ? px_at(t, 1300, 360) : 0;
            VERIFY(t.width == 2346 && a == RED && b == GREEN, "⑪ 同尺寸同矩形拷贝：目的存储宽 %lu（期望随源放宽到 2346），(900, 360) = %08x（期望红）、(1300, 360) = %08x（期望绿）", (unsigned long)t.width, a, b);
        }
        id<MTLTexture> d = resolve(1);
        VERIFY(d.width == 1564 && d.height == 720, "① 源放宽到 1564：解析后目标存储 %lux%lu（期望 1564x720）", (unsigned long)d.width, (unsigned long)d.height);
        static const unsigned P[3][2] = {{100, 360}, {1500, 360}, {1563, 719}};
        for (int i = 0; i < 3; i++) {
            uint32_t got = d.width > P[i][0] && d.height > P[i][1] ? px_at(d, P[i][0], P[i][1]) : 0;
            VERIFY(got == RED, "② 目标 (%u, %u) = %08x（期望 %08x：整张解析了%s）", P[i][0], P[i][1], got, RED, P[i][0] >= 1280 ? "，放宽外延也有内容" : "");
        }

        {   // ⑨ ⑩ 放宽目标第 1 级的清除
            static tex_t m; g_levels = 2; make_tex(&m, 1280, 720, 1); g_levels = 1;
            nvn_be_sub_begin();
            memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &m; R.has_rt = 1; wd_widen_rts(); rp_end();
            uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull));
            id<MTLTexture> mt = tex_mtl(&m); REQUIRE(mt.width == 1564 && mt.mipmapLevelCount >= 2);
            clear_red_lv(mt, 1);
            nvn_be_sub_begin();
            p_clear_tex c; memset(&c, 0, sizeof c); c.tex = &m; c.has_view = 1; c.view.set_levels = 1; c.view.base_level = 1; c.view.nlevels = 1;
            c.r = (NVNcopyRegion){.width = 640, .height = 360, .depth = 1}; c.mask = 0xf; c.c.f[1] = 1; c.c.f[3] = 1;
            clear_tex(&c);
            uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            mt = tex_mtl(&m); uint32_t a = px_at_lv(mt, 1, 100, 100), b = px_at_lv(mt, 1, 780, 100);
            VERIFY(a == GREEN && b == GREEN, "⑨ 清放宽目标第 1 级整张（游戏 640x360）：存储第 1 级 (100, 100) = %08x、(780, 100) = %08x（期望都是 %08x 绿；改前 780 列仍红）", a, b, GREEN);
            long x0 = 320, x1 = 640; wd_clear_x(&m, 1, &x0, &x1);
            VERIFY(x0 == 391 && x1 == 782, "⑩ 第 1 级 x [320, 640) → [%ld, %ld)（期望 [391, 782)）", x0, x1);
        }
        {   // ⑫ 贴图整宽清除算「两侧本帧有内容」：清过的目标第一笔（半透明、子视口）不交两侧条带；没清过的对照照旧交
            static tex_t q[3]; int sides[3];
            for (int i = 0; i < 3; i++) {   // 0 没清过；1 放宽后整宽清；2 放宽前整宽清（放宽时再清一遍新存储）
                make_tex(&q[i], 800, 450, 1);
                p_clear_tex c; memset(&c, 0, sizeof c); c.tex = &q[i]; c.r = (NVNcopyRegion){.width = 800, .height = 450, .depth = 1}; c.mask = 0xf; c.c.f[3] = 1;
                nvn_be_sub_begin(); if (i == 2) clear_tex(&c);
                memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &q[i]; R.has_rt = 1; wd_widen_rts(); rp_end();
                if (i == 1) clear_tex(&c);
                uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(tex_mtl(&q[i]).width == 977);
                s2a_widen_targets((uint32_t)q[i].serial, 0); REQUIRE(s2a_widen_viewport(0, 560, 315, 1.0f));
                s2a_widen_draw_in in; memset(&in, 0, sizeof in); in.vp_w = 560; in.vp_h = 315; in.target_scale = 1; in.flags = S2A_WIDEN_DRAW_COLOR | S2A_WIDEN_DRAW_WRITES;
                s2a_widen_draw_out out; memset(&out, 0, sizeof out); s2a_widen_draw(&in, &out); sides[i] = (out.flags & S2A_WIDEN_OUT_PAGE_SIDES) != 0;
            }
            VERIFY(sides[0] && !sides[1], "⑫ 800x450 放宽目标本帧第一笔（半透明、视口 560x315）：没清过的交两侧条带 %d（期望 1，对照）、贴图整宽清过的 %d（期望 0；改前 1，左 88 列被清成 0）", sides[0], sides[1]);
            uint32_t l2 = px_at(tex_mtl(&q[2]), 10, 100), r2 = px_at(tex_mtl(&q[2]), 970, 100);
            VERIFY(!sides[2] && l2 == 0xff000000u && r2 == 0xff000000u, "⑫' 存储放宽前整宽清成 (0,0,0,1)：放宽后 (10, 100) = %08x、(970, 100) = %08x（期望都是 ff000000：放宽时按同一清除再清满；只拷旧存储时 970 列 = 0），第一笔交两侧条带 %d（期望 0）", l2, r2, sides[2]);
        }
        {   // ⑬ 只被贴图清除过、没放宽的 1600x900 贴图不是 CPU 供图：放宽目标上铺满画布采样它的那笔不起原比例页；没清过的对照照旧起页
            static tex_t tg[2], src[2]; int mode[2];   // 各用各的目标：同一目标上前一笔起了页，后一笔沿用（PageActive）
            for (int i = 0; i < 2; i++) {
                make_tex(&tg[i], 1600, 900, 1);
                nvn_be_sub_begin(); memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &tg[i]; R.has_rt = 1; wd_widen_rts(); rp_end();
                uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(tex_mtl(&tg[i]).width == 1955);
                make_tex(&src[i], 1600, 900, 1);
                if (i) { p_clear_tex c; memset(&c, 0, sizeof c); c.tex = &src[i]; c.r = (NVNcopyRegion){.width = 1600, .height = 900, .depth = 1}; c.mask = 0xf; c.c.f[3] = 1;
                         nvn_be_sub_begin(); clear_tex(&c); f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(tex_mtl(&src[i]).width == 1600); }
                s2a_widen_targets((uint32_t)tg[i].serial, 0); REQUIRE(s2a_widen_viewport(0, 1600, 900, 1.0f));
                s2a_widen_tex tx = {(uint32_t)src[i].serial, 1600, 900, 1.0f, 0};
                s2a_widen_draw_in in; memset(&in, 0, sizeof in); in.vp_w = 1600; in.vp_h = 900; in.target_scale = 1; in.flags = S2A_WIDEN_DRAW_COLOR | S2A_WIDEN_DRAW_WRITES; in.tex = &tx; in.ntex = 1;
                s2a_widen_draw_out out; memset(&out, 0, sizeof out); mode[i] = s2a_widen_draw(&in, &out);
            }
            VERIFY(mode[0] == S2A_WIDEN_PAGE && mode[1] != S2A_WIDEN_PAGE, "⑬ 放宽目标上铺满画布采样没放宽的 1600x900 贴图：没清过的画法 %d（期望 %d 原比例页，对照）、贴图清除过的 %d（期望不是 %d；改前也起页、两侧清黑）", mode[0], S2A_WIDEN_PAGE, mode[1], S2A_WIDEN_PAGE);
        }
        g_wd = s2a_widen_init(1920, 1318, S2A_WIDEN_FULL); REQUIRE(g_wd == S2A_WIDEN_ALL);
        id<MTLTexture> t = tall_copy();
        VERIFY(t.width == 1024 && t.height == 702, "④ 窄屏加高的源（1024x702）整张拷进同尺寸普通贴图：目的存储 %lux%lu（期望随源加高到 1024x702）", (unsigned long)t.width, (unsigned long)t.height);
        uint32_t a = px_at(t, 100, 250), b = t.height > 330 ? px_at(t, 100, 330) : 0, b2 = t.height > 400 ? px_at(t, 100, 400) : 0;
        VERIFY(a == RED && b == RED && b2 == GREEN, "⑤ 一比一拷：(100, 250) = %08x、(100, 330) = %08x（期望都是 %08x 红）、(100, 400) = %08x（期望 %08x 绿：分界 351）", a, b, RED, b2, GREEN);
        {   // ⑭ 窄屏加高的两样本目标解析进同尺寸单样本贴图
            static tex_t ts, td; make_tex(&ts, 1280, 720, 2); make_tex(&td, 1280, 720, 1);
            nvn_be_sub_begin(); memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &ts; R.has_rt = 1; wd_widen_rts(); rp_end();
            uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull));
            REQUIRE(tex_mtl(&ts).width == 1280 && tex_mtl(&ts).height == 878);   // 前提：源随开遍加高
            clear_red(tex_mtl(&ts));
            nvn_be_sub_begin();
            p_copy_t2t c; memset(&c, 0, sizeof c); c.src = &ts; c.dst = &td; c.flags = DM_COPY_RESOLVE; c.sr = (NVNcopyRegion){.width = 1280, .height = 720, .depth = 1}; c.dr = c.sr;
            copy_t2t(&c);
            uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            id<MTLTexture> dt = tex_mtl(&td); uint32_t e = dt.height > 870 ? px_at(dt, 100, 870) : 0;
            VERIFY(dt.width == 1280 && dt.height == 878 && e == RED, "⑭ 加高的两样本目标解析：目标存储 %lux%lu（期望随源加高到 1280x878），(100, 870) = %08x（期望 %08x 红）", (unsigned long)dt.width, (unsigned long)dt.height, e, RED);
        }
        { static tex_t plain; make_tex(&plain, 1024, 576, 1);   // 没当过目标、没被拷进过的普通贴图（④ 的目的现在随源加高了，不能再当对照）
          long y0 = 288, y1 = 576; wd_clear_y(&g_tall_src, &y0, &y1); long z0 = 288, z1 = 576; wd_clear_y(&plain, &z0, &z1);
          VERIFY(y0 == 351 && y1 == 702 && z0 == 288 && z1 == 576, "⑧ 带剪刀清屏的行按加高换算：加高目标 [288, 576) → [%ld, %ld)（期望 [351, 702)）、没加高的 → [%ld, %ld)（期望原样）", y0, y1, z0, z1); }
        {   // ⑯ 单样本 RGBA8 → 同尺寸单样本 BGRA8 的 Downsample（#751：游戏最后一遍把 1280x720 RGBA8 画面「解析」进上屏用的 BGRA8 贴图；改前报未实现、整步跳过，黑屏有声）
            //   期望手算：源整张红 (255, 0, 0, 255)；目标按 BGRA 字节序存，小端读一个像素 = B | G << 8 | R << 16 | A << 24 = ffff0000（改前目标没被写，读 0）
            static tex_t s1, d1; g_fmt = NVN_FORMAT_RGBA8; make_tex(&s1, 1280, 720, 1); g_fmt = NVN_FORMAT_BGRA8; make_tex(&d1, 1280, 720, 1); g_fmt = NVN_FORMAT_RGBA8;
            REQUIRE(tex_mtl(&s1).pixelFormat == MTLPixelFormatRGBA8Unorm && tex_mtl(&d1).pixelFormat == MTLPixelFormatBGRA8Unorm);   // 前提：就是 #751 日志里的 70 → 80
            clear_red(tex_mtl(&s1));
            nvn_be_sub_begin();
            p_copy_t2t c; memset(&c, 0, sizeof c); c.src = &s1; c.dst = &d1; c.flags = DM_COPY_RESOLVE; c.sr = (NVNcopyRegion){.width = 1280, .height = 720, .depth = 1}; c.dr = c.sr;
            copy_t2t(&c);
            uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            uint32_t a = px_at(tex_mtl(&d1), 0, 0), b = px_at(tex_mtl(&d1), 1279, 719);
            VERIFY(a == 0xffff0000u && b == 0xffff0000u, "⑯ 单样本 RGBA8 → BGRA8 同尺寸 Downsample：(0, 0) = %08x、(1279, 719) = %08x（期望都是 ffff0000：BGRA 存的红；改前 0，整步跳过）", a, b);
        }
        nvn_be_drain();
        printf("%s t_nvn_wdresolve：%u 项，%u 项失败（%s）\n", failures ? "✗" : "✓", checks, failures, g_m3 ? "Metal 3" : "Metal 4");
        return failures != 0;
    }
}
