// 帧录放（10-31 维护者：满屏 / 画面改动不进游戏、不导航，录一帧反复回放出图）。nvn_mtl.m 末尾包含（要读回放层的静态表）。说明 graphics/nvn/docs/frame_replay.md。
//
// 录：S2A_FRAME_REC=<目录>，或 <出图次数>[,<出图次数>…]:<目录>。到点的那次 nvnQueuePresentTexture（hle_nvn.c 持提交锁调 nvn_frec_present）把这一帧落进 <目录>/<名>/：
//   mem.bin    游戏地址窗口里有内容的页（mincore 在内存 / 已换出的页，整页为 0 的不存）：对象（tex_t / prog_t / sync_t …都在游戏内存）、命令内存、内存池、描述符池全在里面
//   state.bin  回放层自己的表：内存池、活着的贴图序号、CPU 写过的贴图序号、贴图 / 采样器登记、交换链贴图、深度模式 / 原点 / 贴图池容量；命令记录所在的宿主块（hle_nvn.c 命令缓冲影子块）按原地址另存
//   gpu.bin    GPU 私有贴图（渲染目标 / 着色器写过的）的内容，含深度模板、多重采样、压缩格式：回放第一遍之后、尺寸对得上的照原样写回（帧里先读后写的历史缓冲）
//   subs.bin   上一次出图到这次之间的每次提交（命令句柄数组），这次出图的贴图对象地址、间隔、裁剪框
//   manifest.tsv  款、帧号、窗口基址 / 大小、屏幕宽高、宽屏标志、程序号、链号、宿主提交号、录时的 S2A_IN / S2A_GAME_DATA / 现编兜底目录 DM_MSL_FALLBACK
//   名：给帧号时是 f<出图次数>；自动玩家实时通道「REC:<名>」（tests/autoplay/autoplay.c）在下一次出图录成 <名>
// 放：S2A_FRAME_REPLAY=<录像目录>（宿主 host_main.c 占好地址窗口后不装游戏，调 nvn_frame_replay）。窗口基址必须与录时相同（不同就报红退出）。
//   映射回游戏内存 → 按 state.bin 调回放层同一组登记函数 → 把这一帧的提交执行 S2A_FRAME_REPLAY_N 遍（缺省 3：宽屏核心按内容判画布、放宽存储要几遍才稳）→
//   最后一遍抓上屏图（同自动玩家截图那一路）：存 <S2A_DOCS>/shots/replay.png、跑满屏判据（红行同局里，红帧另存 fit_red_<k>.png）、打每笔指令数。
//   录像里是游戏数据：只留本机，不进仓库、不外发（tools/frame_replay.sh 拒绝写进仓库目录）。
// 范围：NVN 前端（hle_nvn.c）。Vulkan 前端（hle_vk.m，超级马力欧银河 1 / 2）自己编码 Metal，不经回放层，这里录不到，录时报红。
//   稀疏（虚拟）内存池的页表在 hle_nvn.c，回放不重建：录时报红、照样落盘（池里能读到的内容按普通内存回放）。
#include <sys/mman.h>
#include <mach/mach.h>   // 用 vm_region_64：iOS SDK 不许 mach_vm.h，arm64 上 vm_address_t 本就 64 位
void s2a_window_get(uint64_t *base, uint64_t *size) __attribute__((weak));
void s2a_frame_replay_screen(int w, int h, int game, int layout, int full) __attribute__((weak));   // runtime/src/widen.c
int s2a_widen_game(void) __attribute__((weak)); int s2a_widen_layout(void) __attribute__((weak)); int s2a_widen_full(void) __attribute__((weak));
uint64_t s2a_npdm_program_id(void) __attribute__((weak));
void s2a_npdm_program_id_set(uint64_t id) __attribute__((weak));   // runtime/src/gfxmode.c
int s2a_hle_cmdshadow_list(void (*cb)(void *ctx, const void *mem, size_t size), void *ctx) __attribute__((weak));   // hle_nvn.c
int s2a_vk_front_used(void) __attribute__((weak));   // graphics/nvn/gfx/vk/hle_vk.m
int s2a_hle_pk_save(FILE *f); int s2a_hle_pk_load(FILE *f);
int s2a_hle_vpool_save(FILE *f); int s2a_hle_vpool_load(FILE *f);   // hle_nvn.c：虚拟池地址段与页表（vpool.bin）
int s2a_vp_arena_has(const void *p, uint64_t n) __attribute__((weak));   // runtime/src/vawin.c 虚拟池区   // hle_nvn.c：程序各阶段键（只在 SetShaders 时算得出）   // graphics/nvn/gfx/vk/hle_vk.m
int mtl_fit_judge_shot(uint64_t tok, const uint8_t *p, size_t w, size_t h, size_t row);
uint64_t mtl_grab_fit_token(void);

enum { FR_MAGIC = 0x31524653u, FR_REC_REGION = 1, FR_REC_DATA = 2, FR_REC_END = 3 };
static int g_fr_on = -1; static char g_fr_dir[900]; static long g_fr_at[64]; static int g_fr_nat;
static char g_fr_req[96]; static _Atomic int g_fr_req_set;   // 实时通道要的下一次出图录像名
static uint64_t *g_fr_h; static size_t g_fr_nh, g_fr_caph; static uint64_t g_fr_pres;   // 本帧提交：[n, 句柄 × n] 依次排；出图计数
static int fr_on(void) {
    if (g_fr_on >= 0) return g_fr_on;
    const char *e = getenv("S2A_FRAME_REC"); g_fr_on = 0;
    if (!e || !*e) return 0;
    const char *c = strchr(e, ':');
    if (c && c != e && strspn(e, "0123456789,") == (size_t)(c - e)) {
        for (const char *q = e; q < c && g_fr_nat < 64; q = strchr(q, ',') && strchr(q, ',') < c ? strchr(q, ',') + 1 : c) g_fr_at[g_fr_nat++] = atol(q);
        e = c + 1;
    }
    // iOS：相对目录按文档根解析（runtime/include/s2a_docs.h，同自动玩家 out_dir）：App 当前目录是只读的 /，真机录帧写不进去（11-06 无人深空真机录帧）。Mac 照旧按当前目录
    const char *base = NULL;
#if TARGET_OS_IPHONE
    static char docs[600];
    if (e[0] != '/') { s2a_docs_root(docs, sizeof docs); base = docs; }
#endif
    if ((base && *base ? strlen(base) + 1 : 0) + strlen(e) >= sizeof g_fr_dir) { MLOG("【红】 帧录：S2A_FRAME_REC 目录太长"); return 0; }
    if (base && *base) snprintf(g_fr_dir, sizeof g_fr_dir, "%s/%s", base, e); else strcpy(g_fr_dir, e);
    mkdir(g_fr_dir, 0755);
    MLOG("帧录：开（目录 %s，%d 个定帧；实时通道 REC:<名> 录下一次出图）", g_fr_dir, g_fr_nat);
    return g_fr_on = 1;
}
int nvn_frec_on(void) { return fr_on(); }
void nvn_frec_request(const char *name) {   // 任意线程（自动玩家实时通道）
    if (!fr_on() || !name || !*name || strchr(name, '/') || strlen(name) >= sizeof g_fr_req) { MLOG("【红】 帧录：录像名 %s 不收（要先开 S2A_FRAME_REC、名字不带 /）", name ? name : "(空)"); return; }
    while (atomic_load(&g_fr_req_set)) usleep(1000);
    strcpy(g_fr_req, name); atomic_store(&g_fr_req_set, 1);
}
// 提交线程，持 hle 提交锁：记下这次提交的命令句柄（录像要的是「上一次出图到下一次出图」之间的全部提交）
void nvn_frec_submit(const uint64_t *h, int n) {
    if (!fr_on() || n <= 0) return;
    if (g_fr_nh + (size_t)n + 1 > g_fr_caph) { size_t c = (g_fr_nh + (size_t)n + 1) * 2; uint64_t *p = realloc(g_fr_h, c * sizeof *p); if (!p) { MLOG("【红】 帧录：提交表分配失败"); return; } g_fr_h = p; g_fr_caph = c; }
    g_fr_h[g_fr_nh++] = (uint64_t)n; memcpy(g_fr_h + g_fr_nh, h, (size_t)n * sizeof *h); g_fr_nh += (size_t)n;
}

static int fr_w(FILE *f, const void *p, size_t n) { return fwrite(p, 1, n, f) == n; }
static int fr_r(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n; }
static int fr_zero(const uint8_t *p, size_t n) { const uint64_t *q = (const uint64_t *)p; for (size_t i = 0; i < n / 8; i++) if (q[i]) return 0; return 1; }

// mem.bin：每段可读映射一条 REGION{地址, 长, 保护}，其后它里面有内容的连续页一条 DATA{地址, 长, 字节}
static int fr_dump_mem(const char *path, uint64_t wb, uint64_t ws, uint64_t *bytes, uint64_t *nreg) {
    FILE *f = fopen(path, "wb"); if (!f) return 0;
    uint32_t mg = FR_MAGIC; int ok = fr_w(f, &mg, 4);
    const size_t pg = (size_t)getpagesize(); static char vec[1 << 16];
    vm_address_t a = wb; *bytes = *nreg = 0;
    while (ok && a < wb + ws) {
        vm_address_t r = a; vm_size_t sz = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &r, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS || r >= wb + ws) break;
        uint64_t lo = r, hi = r + sz > wb + ws ? wb + ws : r + sz;
        if (info.protection & VM_PROT_READ) {
            uint32_t t = FR_REC_REGION; uint64_t hd[3] = {lo, hi - lo, (uint64_t)info.protection}; ok = fr_w(f, &t, 4) && fr_w(f, hd, sizeof hd); (*nreg)++;
            uint64_t run0 = 0, run1 = 0;
#define FR_FLUSH() do { if (ok && run1 > run0) { uint32_t d_ = FR_REC_DATA; uint64_t dh_[2] = {run0, run1 - run0}; \
        ok = fr_w(f, &d_, 4) && fr_w(f, dh_, sizeof dh_) && fr_w(f, (const void *)run0, run1 - run0); *bytes += run1 - run0; } run0 = run1 = 0; } while (0)
            for (uint64_t p = lo; ok && p < hi; p += sizeof vec * pg) {
                uint64_t n = (hi - p) / pg; if (n > sizeof vec) n = sizeof vec;
                if (mincore((void *)p, n * pg, vec)) memset(vec, 1, n);   // 查不了就当都有内容（多存不错存）
                for (uint64_t i = 0; i < n && ok; i++) {
                    uint64_t q = p + i * pg;
                    if (vec[i] && !fr_zero((const uint8_t *)q, pg)) { if (run1 != q) { FR_FLUSH(); run0 = q; } run1 = q + pg; }
                    else FR_FLUSH();
                }
            }
            FR_FLUSH();
#undef FR_FLUSH
        }
        a = r + sz;
    }
    uint32_t e = FR_REC_END; ok = ok && fr_w(f, &e, 4);
    return fclose(f) == 0 && ok;
}
// 命令记录宿主块：在命令记录区（runtime/src/vawin.c，录 / 放两种进程同址各占一块）的先记一条映射段，回放第一遍在原地址 MAP_FIXED 建页、第二遍读回内容；
//   不在区里的（区切满）只记内容，回放按原地址试映射，占不到报红
int s2a_cmd_arena_has(const void *p, uint64_t n) __attribute__((weak));
static int fr_in_arena(uint64_t a, uint64_t n) { return s2a_cmd_arena_has && s2a_cmd_arena_has((const void *)(uintptr_t)a, n); }
static void fr_seg_cb(void *ctx, const void *mem, size_t size) {
    FILE *f = ctx; uint32_t t = FR_REC_DATA; uint64_t dh[2] = {(uint64_t)(uintptr_t)mem, size};
    if (fr_in_arena(dh[0], size)) { uint32_t r = FR_REC_REGION; uint64_t hd[3] = {dh[0], size, (uint64_t)(VM_PROT_READ | VM_PROT_WRITE)}; fr_w(f, &r, 4); fr_w(f, hd, sizeof hd); }
    fr_w(f, &t, 4); fr_w(f, dh, sizeof dh); fr_w(f, mem, size);
}

// GPU 私有贴图字节数 / 像素（只认渲染目标常见的非压缩、非深度模板格式；其余不存，回放靠重画）
static unsigned fr_bpp(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatA8Unorm: return 1;
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float:
        case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: return 2;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatBGR10A2Unorm:
        case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint:
        case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float: return 4;
        case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: return 8;
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
        default: return 0;
    }
}
// 每张贴图按「面」存：普通颜色 1 面（每像素 bpp 字节）；压缩格式 1 面（每块 bb 字节，块 bw×bh）；深度模板拆成深度面 + 模板面（blit 的 DepthFromDepthStencil /
//   StencilFromDepthStencil 选项）；多重采样（blit 拷不了）用计算着色器逐样本读进缓冲，回放用逐样本（[[sample_id]]）的渲染遍写回。
//   11-05 旷野之息录像每帧不存 28 张（深度模板 / 多重采样 / 压缩），回放场景发白，单帧问题只能实玩一局局跑
enum { FR_TK_PLAIN = 0, FR_TK_MS = 1 };
typedef struct { uint32_t bw, bh, bb, opt; } fr_plane;   // 块宽 / 块高 / 每块字节 / blit 选项（MTLBlitOption）
typedef struct { uint64_t ser; uint32_t type, fmt, w, h, depth, layers, levels, kind, samples, nplane, pad; fr_plane pl[2]; uint64_t bytes; } fr_tex_hd;
#define FR_GPU_MAGIC 0x32555047u   // gpu.bin 开头（「GPU2」）：旧录像没有，读到不认就整份不写回（旧录法缺这三类，要重录）
static int fr_compressed(MTLPixelFormat f, fr_plane *p) {   // 压缩格式的块：BC / ETC2 / EAC / ASTC（LDR、sRGB、HDR）
    switch (f) {
        case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB: case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm:
        case MTLPixelFormatETC2_RGB8: case MTLPixelFormatETC2_RGB8_sRGB: case MTLPixelFormatETC2_RGB8A1: case MTLPixelFormatETC2_RGB8A1_sRGB:
        case MTLPixelFormatEAC_R11Unorm: case MTLPixelFormatEAC_R11Snorm: *p = (fr_plane){4, 4, 8, 0}; return 1;
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB: case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
        case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm: case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat:
        case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB: case MTLPixelFormatEAC_RGBA8: case MTLPixelFormatEAC_RGBA8_sRGB:
        case MTLPixelFormatEAC_RG11Unorm: case MTLPixelFormatEAC_RG11Snorm: *p = (fr_plane){4, 4, 16, 0}; return 1;
        default: break;
    }
    static const struct { MTLPixelFormat ldr, srgb, hdr; uint8_t w, h; } astc[] = {
        {MTLPixelFormatASTC_4x4_LDR, MTLPixelFormatASTC_4x4_sRGB, MTLPixelFormatASTC_4x4_HDR, 4, 4}, {MTLPixelFormatASTC_5x4_LDR, MTLPixelFormatASTC_5x4_sRGB, MTLPixelFormatASTC_5x4_HDR, 5, 4},
        {MTLPixelFormatASTC_5x5_LDR, MTLPixelFormatASTC_5x5_sRGB, MTLPixelFormatASTC_5x5_HDR, 5, 5}, {MTLPixelFormatASTC_6x5_LDR, MTLPixelFormatASTC_6x5_sRGB, MTLPixelFormatASTC_6x5_HDR, 6, 5},
        {MTLPixelFormatASTC_6x6_LDR, MTLPixelFormatASTC_6x6_sRGB, MTLPixelFormatASTC_6x6_HDR, 6, 6}, {MTLPixelFormatASTC_8x5_LDR, MTLPixelFormatASTC_8x5_sRGB, MTLPixelFormatASTC_8x5_HDR, 8, 5},
        {MTLPixelFormatASTC_8x6_LDR, MTLPixelFormatASTC_8x6_sRGB, MTLPixelFormatASTC_8x6_HDR, 8, 6}, {MTLPixelFormatASTC_8x8_LDR, MTLPixelFormatASTC_8x8_sRGB, MTLPixelFormatASTC_8x8_HDR, 8, 8},
        {MTLPixelFormatASTC_10x5_LDR, MTLPixelFormatASTC_10x5_sRGB, MTLPixelFormatASTC_10x5_HDR, 10, 5}, {MTLPixelFormatASTC_10x6_LDR, MTLPixelFormatASTC_10x6_sRGB, MTLPixelFormatASTC_10x6_HDR, 10, 6},
        {MTLPixelFormatASTC_10x8_LDR, MTLPixelFormatASTC_10x8_sRGB, MTLPixelFormatASTC_10x8_HDR, 10, 8}, {MTLPixelFormatASTC_10x10_LDR, MTLPixelFormatASTC_10x10_sRGB, MTLPixelFormatASTC_10x10_HDR, 10, 10},
        {MTLPixelFormatASTC_12x10_LDR, MTLPixelFormatASTC_12x10_sRGB, MTLPixelFormatASTC_12x10_HDR, 12, 10}, {MTLPixelFormatASTC_12x12_LDR, MTLPixelFormatASTC_12x12_sRGB, MTLPixelFormatASTC_12x12_HDR, 12, 12} };
    for (size_t i = 0; i < sizeof astc / sizeof astc[0]; i++) if (f == astc[i].ldr || f == astc[i].srgb || f == astc[i].hdr) { *p = (fr_plane){astc[i].w, astc[i].h, 16, 0}; return 1; }
    return 0;
}
static int fr_planes(MTLPixelFormat f, fr_plane pl[2]) {   // 单采样贴图拆成几面：0 = 不认的格式
    unsigned bpp = fr_bpp(f); if (bpp) { pl[0] = (fr_plane){1, 1, bpp, 0}; return 1; }
    if (fr_compressed(f, &pl[0])) return 1;
    switch (f) {
        case MTLPixelFormatDepth16Unorm: pl[0] = (fr_plane){1, 1, 2, 0}; return 1;
        case MTLPixelFormatDepth32Float: pl[0] = (fr_plane){1, 1, 4, 0}; return 1;
        case MTLPixelFormatStencil8: pl[0] = (fr_plane){1, 1, 1, 0}; return 1;
        case MTLPixelFormatDepth32Float_Stencil8: pl[0] = (fr_plane){1, 1, 4, (uint32_t)MTLBlitOptionDepthFromDepthStencil}; pl[1] = (fr_plane){1, 1, 1, (uint32_t)MTLBlitOptionStencilFromDepthStencil}; return 2;
        default: return 0;
    }
}
static uint64_t fr_plane_bytes(const fr_plane *p, NSUInteger w, NSUInteger h, NSUInteger d) { return (uint64_t)((w + p->bw - 1) / p->bw) * ((h + p->bh - 1) / p->bh) * d * p->bb; }
// 多重采样：着色器按格式类（浮点 / 无符号整数 / 有符号整数 / 深度）分四种；每样本存 16 字节（颜色 4 分量）或 4 字节（深度）
static int fr_ms_class(MTLPixelFormat f) {   // 0 浮点颜色 1 无符号 2 有符号 3 深度；-1 不认（含模板的多重采样：模板写不回，计不存）
    if (f == MTLPixelFormatDepth32Float || f == MTLPixelFormatDepth16Unorm) return 3;
    if (!fr_bpp(f)) return -1;
    switch (f) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatR16Uint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG16Uint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA32Uint: return 1;
        case MTLPixelFormatR8Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatR16Sint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatRG16Sint:
        case MTLPixelFormatR32Sint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA32Sint: return 2;
        default: return 0;
    }
}
static id<MTLLibrary> fr_ms_lib(void) {
    static id<MTLLibrary> lib; static int tried;
    if (tried++) return lib;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void rd0(texture2d_ms<float, access::read> t [[texture(0)]], device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { uint n = t.get_num_samples(), w = t.get_width(); if (p.x >= w || p.y >= t.get_height()) return; for (uint s = 0; s < n; s++) o[(p.y * w + p.x) * n + s] = t.read(p, s); }\n"
        "kernel void rd1(texture2d_ms<uint, access::read> t [[texture(0)]], device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { uint n = t.get_num_samples(), w = t.get_width(); if (p.x >= w || p.y >= t.get_height()) return; for (uint s = 0; s < n; s++) o[(p.y * w + p.x) * n + s] = t.read(p, s); }\n"
        "kernel void rd2(texture2d_ms<int, access::read> t [[texture(0)]], device int4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { uint n = t.get_num_samples(), w = t.get_width(); if (p.x >= w || p.y >= t.get_height()) return; for (uint s = 0; s < n; s++) o[(p.y * w + p.x) * n + s] = t.read(p, s); }\n"
        "kernel void rd3(depth2d_ms<float, access::read> t [[texture(0)]], device float *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { uint n = t.get_num_samples(), w = t.get_width(); if (p.x >= w || p.y >= t.get_height()) return; for (uint s = 0; s < n; s++) o[(p.y * w + p.x) * n + s] = t.read(p, s); }\n"
        "struct V { float4 p [[position]]; };\n"
        "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V v; v.p = float4(q * 2 - 1, 0, 1); return v; }\n"
        "fragment float4 wr0(V v [[stage_in]], uint s [[sample_id]], const device float4 *b [[buffer(0)]], constant uint2 &wn [[buffer(1)]]) { uint2 p = uint2(v.p.xy); return b[(p.y * wn.x + p.x) * wn.y + s]; }\n"
        "fragment uint4 wr1(V v [[stage_in]], uint s [[sample_id]], const device uint4 *b [[buffer(0)]], constant uint2 &wn [[buffer(1)]]) { uint2 p = uint2(v.p.xy); return b[(p.y * wn.x + p.x) * wn.y + s]; }\n"
        "fragment int4 wr2(V v [[stage_in]], uint s [[sample_id]], const device int4 *b [[buffer(0)]], constant uint2 &wn [[buffer(1)]]) { uint2 p = uint2(v.p.xy); return b[(p.y * wn.x + p.x) * wn.y + s]; }\n"
        "struct D { float d [[depth(any)]]; };\n"
        "fragment D wr3(V v [[stage_in]], uint s [[sample_id]], const device float *b [[buffer(0)]], constant uint2 &wn [[buffer(1)]]) { uint2 p = uint2(v.p.xy); D o; o.d = b[(p.y * wn.x + p.x) * wn.y + s]; return o; }\n";
    NSError *e = nil; lib = [g_dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) MLOG("【红】 帧录：多重采样存放着色器编不出（%s），多重采样贴图不存", e.localizedDescription.UTF8String);
    return lib;
}
static int fr_ms_ok(id<MTLTexture> t) { return t.textureType == MTLTextureType2DMultisample && (t.usage & MTLTextureUsageShaderRead) && fr_ms_class(t.pixelFormat) >= 0 && fr_ms_lib(); }
static uint64_t fr_ms_bytes(id<MTLTexture> t) { return (uint64_t)t.width * t.height * t.sampleCount * (fr_ms_class(t.pixelFormat) == 3 ? 4 : 16); }
static int fr_ms_read(id<MTLTexture> t, id<MTLBuffer> b) {
    int c = fr_ms_class(t.pixelFormat); NSError *e = nil;
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:[fr_ms_lib() newFunctionWithName:[NSString stringWithFormat:@"rd%d", c]] error:&e]; if (!ps) return 0;
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setTexture:t atIndex:0]; [ce setBuffer:b offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(t.width, t.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [ce endEncoding];
    return cb_run(cb) && !cb.error;   // cb_run：GPU 安全停后不交（nvn_mtl.m）
}
static int fr_ms_write(id<MTLTexture> t, id<MTLBuffer> b) {
    int c = fr_ms_class(t.pixelFormat); NSError *e = nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [fr_ms_lib() newFunctionWithName:@"vs"]; pd.fragmentFunction = [fr_ms_lib() newFunctionWithName:[NSString stringWithFormat:@"wr%d", c]];
    pd.rasterSampleCount = t.sampleCount;
    if (c == 3) pd.depthAttachmentPixelFormat = t.pixelFormat; else pd.colorAttachments[0].pixelFormat = t.pixelFormat;
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) return 0;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (c == 3) { rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionDontCare; rp.depthAttachment.storeAction = MTLStoreActionStore; }
    else { rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore; }
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    if (c == 3) { MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; [re setDepthStencilState:[g_dev newDepthStencilStateWithDescriptor:dd]]; }
    uint32_t wn[2] = {(uint32_t)t.width, (uint32_t)t.sampleCount};
    [re setFragmentBuffer:b offset:0 atIndex:0]; [re setFragmentBytes:wn length:sizeof wn atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    return cb_run(cb) && !cb.error;
}
// 单采样贴图各面各级各层 ↔ 缓冲（to_buf 1 = 存，0 = 放回）
static int fr_blit_planes(id<MTLTexture> t, const fr_tex_hd *hd, id<MTLBuffer> b, int to_buf) {
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; uint64_t off = 0;
    for (uint32_t k = 0; k < hd->nplane; k++) { const fr_plane *p = &hd->pl[k];
        for (uint32_t l = 0; l < hd->levels; l++) for (uint32_t s = 0; s < hd->layers; s++) {
            NSUInteger w = MAX(1, hd->w >> l), h = MAX(1, hd->h >> l), d = MAX(1, hd->depth >> l), bpr = (w + p->bw - 1) / p->bw * p->bb, bpi = bpr * ((h + p->bh - 1) / p->bh);
            if (to_buf) [be copyFromTexture:t sourceSlice:s sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, d) toBuffer:b destinationOffset:off destinationBytesPerRow:bpr destinationBytesPerImage:bpi options:(MTLBlitOption)p->opt];
            else [be copyFromBuffer:b sourceOffset:off sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:MTLSizeMake(w, h, d) toTexture:t destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0) options:(MTLBlitOption)p->opt];
            off += (uint64_t)bpi * d;
        } }
    [be endEncoding];
    return cb_run(cb) && !cb.error;
}
static NSUInteger fr_slices(id<MTLTexture> t) { NSUInteger s = t.arrayLength ? t.arrayLength : 1; return t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? s * 6 : s; }
// gpu.bin：[FR_GPU_MAGIC][fr_tex_hd, 内容]…；返回存了几张。*skipped 只剩：缓冲 / 父贴图视图之外、确实存不了的（含模板的多重采样、多重采样数组、没有 ShaderRead 的多重采样、> 256 MB、不认的格式）
static int fr_dump_gpu(const char *path, uint64_t *bytes, int *skipped) {
    FILE *f = fopen(path, "wb"); if (!f) return -1;
    uint32_t mg = FR_GPU_MAGIC; if (!fr_w(f, &mg, 4)) { fclose(f); return -1; }
    NSMutableArray *objs = [NSMutableArray array]; NSMutableArray<NSNumber *> *sers = [NSMutableArray array];
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_by_serial.cap; i++) if (g_by_serial.vals[i]) { uint64_t s; memcpy(&s, g_by_serial.keys + (size_t)i * 8, 8); [sers addObject:@(s)]; [objs addObject:(__bridge id)g_by_serial.vals[i]]; }
    pthread_mutex_unlock(&g_smu);
    size_t n = objs.count;
    int saved = 0; *bytes = 0; *skipped = 0;
    for (size_t k = 0; k < n; k++) {
        id o = objs[k]; if (![o conformsToProtocol:@protocol(MTLTexture)]) continue;
        id<MTLTexture> t = o;
        if (!(t.usage & (MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite)) || t.buffer || t.parentTexture) continue;
        fr_tex_hd hd = {sers[k].unsignedLongLongValue, (uint32_t)t.textureType, (uint32_t)t.pixelFormat, (uint32_t)t.width, (uint32_t)t.height, (uint32_t)t.depth, (uint32_t)fr_slices(t), (uint32_t)t.mipmapLevelCount,
                        FR_TK_PLAIN, (uint32_t)t.sampleCount};
        uint64_t tot = 0;
        if (t.sampleCount > 1) {
            if (!fr_ms_ok(t)) { (*skipped)++; continue; }
            hd.kind = FR_TK_MS; tot = fr_ms_bytes(t);
        } else {
            hd.nplane = (uint32_t)fr_planes(t.pixelFormat, hd.pl); if (!hd.nplane) { (*skipped)++; continue; }
            for (uint32_t q = 0; q < hd.nplane; q++) for (NSUInteger l = 0; l < t.mipmapLevelCount; l++)
                tot += fr_plane_bytes(&hd.pl[q], MAX(1, t.width >> l), MAX(1, t.height >> l), MAX(1, t.depth >> l)) * hd.layers;   // 3D：每级整块 w×h×d（双人成行体积雾的历史贴图跨帧累积）
        }
        if (tot > (256ull << 20)) { (*skipped)++; continue; }
        id<MTLBuffer> b = [g_dev newBufferWithLength:tot options:MTLResourceStorageModeShared];
        if (!b) { (*skipped)++; continue; }
        int ok = hd.kind == FR_TK_MS ? fr_ms_read(t, b) : fr_blit_planes(t, &hd, b, 1);
        if (!ok) { (*skipped)++; continue; }
        hd.bytes = tot;
        if (!fr_w(f, &hd, sizeof hd) || !fr_w(f, b.contents, tot)) { fclose(f); return -1; }
        *bytes += tot; saved++;
    }
    return fclose(f) == 0 ? saved : -1;
}

typedef struct { uint64_t lo, size; } fr_pool;
typedef struct { int32_t tid, has_v; tex_t t; view_t v; } fr_treg;
typedef struct { int32_t sid; samp_par p; } fr_sreg;
typedef struct { uint32_t magic, depth_zero, origin_ll, tpool_n, npool, nlive, ncpu, ntreg, nsreg, nxv; } fr_state_hd;
static int fr_dump_state(const char *path) {
    FILE *f = fopen(path, "wb"); if (!f) return 0;
    fr_state_hd hd = {FR_MAGIC, (uint32_t)atomic_load(&g_depth_zero), (uint32_t)atomic_load(&g_origin_ll) | (s2a_nvn_rast_flip ? 2u : 0u) | 4u, (uint32_t)g_tpool_n};   // origin_ll bit 1: the queue's front-face raster flip, bit 2: recorded (older recordings: keep the default)
    fr_pool *pools = NULL; uint64_t *live = NULL, *cpu = NULL; fr_treg *tr = NULL; fr_sreg *sr = NULL;
    pthread_mutex_lock(&g_mu);
    pools = malloc((size_t)(g_npool + 1) * sizeof *pools);
    for (int i = 0; pools && i < g_npool; i++) {   // 虚拟池的段不进这张表：回放由 vpool.bin 重建时登记（s2a_hle_vpool_load）
        if (s2a_vp_arena_has && s2a_vp_arena_has((const void *)(uintptr_t)g_pools[i].lo, g_pools[i].hi - g_pools[i].lo)) continue;
        pools[hd.npool++] = (fr_pool){g_pools[i].lo, g_pools[i].hi - g_pools[i].lo}; }
    pthread_mutex_unlock(&g_mu);
    pthread_mutex_lock(&g_smu);
    live = malloc((g_tex_live.n + 1) * 8);
    for (uint32_t i = 0; live && i < g_tex_live.cap; i++) if (g_tex_live.vals[i]) memcpy(&live[hd.nlive++], g_tex_live.keys + (size_t)i * 8, 8);
    // CPU 写过（按随包贴图上传）的：显式标过的 + 已经解析成随包（NvPkg）的。回放里它们要从游戏内存上传，不然按 GPU 贴图建、内容是 0
    cpu = malloc((g_by_serial.n + 1) * 8);
    for (uint32_t i = 0; cpu && i < g_by_serial.cap; i++) if (g_by_serial.vals[i] && [(__bridge id)g_by_serial.vals[i] isKindOfClass:[NvPkg class]]) memcpy(&cpu[hd.ncpu++], g_by_serial.keys + (size_t)i * 8, 8);
    pthread_mutex_unlock(&g_smu);
    pthread_mutex_lock(&g_cpu_tex_mu);
    if (g_cpu_tex.n) { uint64_t *c2 = realloc(cpu, (hd.ncpu + g_cpu_tex.n + 1) * 8); if (c2) { cpu = c2; for (uint32_t i = 0; i < g_cpu_tex.cap; i++) if (g_cpu_tex.vals[i]) memcpy(&cpu[hd.ncpu++], g_cpu_tex.keys + (size_t)i * 8, 8); } }
    pthread_mutex_unlock(&g_cpu_tex_mu);
    pthread_mutex_lock(&g_rmu);
    tr = malloc((size_t)(g_ntreg + 1) * sizeof *tr);
    for (int i = 0; tr && i < g_ntreg; i++) if (g_treg[i].ok) { fr_treg *e = &tr[hd.ntreg++]; memset(e, 0, sizeof *e); e->tid = i; e->t = g_treg[i].t; e->has_v = g_treg[i].has_v; if (e->has_v) e->v = g_treg[i].v; }
    sr = malloc((size_t)(g_nsreg + 1) * sizeof *sr);
    for (int i = 0; sr && i < g_nsreg; i++) if (g_sreg_ok[i]) sr[hd.nsreg++] = (fr_sreg){i, g_sreg[i]};
    pthread_mutex_unlock(&g_rmu);
    hd.nxv = (uint32_t)g_xv_npresent;
    int ok = pools && live && cpu && tr && sr && fr_w(f, &hd, sizeof hd) && fr_w(f, pools, hd.npool * sizeof *pools) && fr_w(f, live, hd.nlive * 8) && fr_w(f, cpu, hd.ncpu * 8)
             && fr_w(f, tr, hd.ntreg * sizeof *tr) && fr_w(f, sr, hd.nsreg * sizeof *sr) && fr_w(f, g_xv_present, hd.nxv * 8);
    // 末尾一节：池的 GPU 地址表（hle_nvn.c GPU 地址空间）。游戏内存里存的 GPU 地址（Deferred 缓冲范围、自存的存储缓冲地址）回放时靠它换回 CPU；旧文件没有这节，回放当空表
    if (ok) { uint64_t *gt = malloc(3 * 8 * 65536); uint32_t ng = gt ? (uint32_t)nvn_gva_snapshot(gt, 65536) : 0; ok = gt && fr_w(f, &ng, 4) && fr_w(f, gt, (size_t)ng * 24); free(gt); }
    // 再一节：游戏手里有 GPU 地址的池范围（nvn_mtl.m g_addr，原始全局内存池表只收这些池）。缺了它回放的池表是 0 段，着色器从池表读回 0：
    //   用两次读之差减 1 作循环次数的计算着色器下溢成上亿次循环，一帧 GPU 忙几秒后挂死安全停。旧文件没有这节，回放当空表
    if (ok) { pthread_mutex_lock(&g_mu); uint32_t na = (uint32_t)g_naddr; ok = fr_w(f, &na, 4) && fr_w(f, g_addr, (size_t)na * sizeof *g_addr); pthread_mutex_unlock(&g_mu); }
    // 接着一节：录的这一刻为池表驻留着的池（pool_ent.gm）。池表里没驻留的池是「冷项」，着色器读它得 0、只置访问位，下一次提交才驻留；
    //   回放从全冷开始的话第一遍就读回 0，同样下溢。按录时的驻留状态放回，回放第一遍看到的池表与录时一致
    if (ok) { pthread_mutex_lock(&g_mu); uint32_t nm = 0; for (int i = 0; i < g_npool; i++) nm += g_pools[i].gm && !g_pools[i].reg;
        ok = fr_w(f, &nm, 4); for (int i = 0; ok && i < g_npool; i++) if (g_pools[i].gm && !g_pools[i].reg) { uintptr_t r[2] = {g_pools[i].lo, g_pools[i].hi}; ok = fr_w(f, r, sizeof r); }
        pthread_mutex_unlock(&g_mu); }
    free(pools); free(live); free(cpu); free(tr); free(sr);
    return fclose(f) == 0 && ok;
}

static void fr_capture(const char *name, const tex_t *pt, double period, const int crop[4]) {
    uint64_t t0 = now_ns(), wb = 0, ws = 0;
    char d[1100], p[1200]; snprintf(d, sizeof d, "%s/%s", g_fr_dir, name); mkdir(d, 0755);
    if (s2a_vk_front_used && s2a_vk_front_used()) { MLOG("【红】 帧录 %s：本款走 Vulkan 前端（hle_vk.m 自己编码 Metal，不经 NVN 回放层），这一版录不到", name); return; }
    if (!s2a_window_get) { MLOG("【红】 帧录 %s：宿主没有地址窗口接口", name); return; }
    s2a_window_get(&wb, &ws);
    // the pool's host bytes are elsewhere (a far-alias shadow, or one view of it: pool_host).
    //   11-11：#450（71a0524e）把这行的注释写在了解锁前面，解锁被注释掉、g_mu 一直占着，随后 mtl_finish_gpu → nvn_be_wait 再锁 g_mu 自锁死，任何录帧都卡在出图（t_nvn_frec_tex ⑥）
    { pthread_mutex_lock(&g_mu); int sparse = 0; for (int i = 0; i < g_npool; i++) sparse |= g_pools[i].host != g_pools[i].base; pthread_mutex_unlock(&g_mu);
      if (sparse) MLOG("【红】 帧录 %s：有内存池在远端别名区（影子另址），回放按游戏地址读不到它们的内容", name); }
    mtl_finish_gpu();   // GPU 做完这一帧之前的提交：GPU 私有贴图的内容、事件值都落定
    uint64_t mb = 0, nreg = 0, gb = 0; int skipped = 0;
    snprintf(p, sizeof p, "%s/mem.bin", d); int okm = fr_dump_mem(p, wb, ws, &mb, &nreg);
    if (okm && s2a_hle_cmdshadow_list) {   // 命令记录所在的宿主块（hle 的影子块，窗口外）：追加在 mem.bin 末尾前
        FILE *f = fopen(p, "r+b"); if (f) { fseek(f, -4, SEEK_END); int n = s2a_hle_cmdshadow_list(fr_seg_cb, f); uint32_t e = FR_REC_END; fr_w(f, &e, 4); fclose(f); if (n) MLOG("帧录 %s：命令记录宿主块 %d 段一并存（在命令记录区的回放按映射段放回原地址）", name, n); } }
    snprintf(p, sizeof p, "%s/state.bin", d); int oks = fr_dump_state(p);
    { snprintf(p, sizeof p, "%s/progkeys.bin", d); FILE *kf = fopen(p, "wb"); int nk = kf ? s2a_hle_pk_save(kf) : -1; if (!kf || fclose(kf)) oks = 0; else MLOG("帧录 %s：程序键 %d 个", name, nk); }
    { snprintf(p, sizeof p, "%s/vpool.bin", d); FILE *vf = fopen(p, "wb"); int nv = vf ? s2a_hle_vpool_save(vf) : -1; if (!vf || fclose(vf) || nv < 0) oks = 0; else if (nv) MLOG("帧录 %s：虚拟池 %d 个（地址段 + 页表）", name, nv); }
    snprintf(p, sizeof p, "%s/gpu.bin", d); int ng = fr_dump_gpu(p, &gb, &skipped);
    snprintf(p, sizeof p, "%s/subs.bin", d);
    FILE *f = fopen(p, "wb"); int nsub = 0;
    for (size_t i = 0; i < g_fr_nh; i += 1 + g_fr_h[i]) nsub++;
    uint64_t pr[3] = {(uint64_t)(uintptr_t)pt, (uint64_t)nsub, 0}; double per = period; int cr[4] = {0}; if (crop) memcpy(cr, crop, sizeof cr);
    int okf = f && fr_w(f, pr, sizeof pr) && fr_w(f, &per, sizeof per) && fr_w(f, cr, sizeof cr) && fr_w(f, &g_fr_nh, sizeof g_fr_nh) && fr_w(f, g_fr_h, g_fr_nh * 8);
    if (f) okf = fclose(f) == 0 && okf;
    snprintf(p, sizeof p, "%s/manifest.tsv", d);
    f = fopen(p, "w");
    if (f) {
        const char *in = getenv("S2A_IN"), *gd = getenv("S2A_GAME_DATA"), *g = getenv("S2A_GAME"), *fb = getenv("DM_MSL_FALLBACK");
        fprintf(f, "版本\t1\n名\t%s\n款\t%s\n出图次数\t%llu\n帧\t%llu\n窗口基址\t%#llx\n窗口大小\t%#llx\n屏幕宽\t%d\n屏幕高\t%d\n宽屏_游戏出宽图\t%d\n宽屏_界面布局\t%d\n宽屏_整套放宽\t%d\n程序号\t%016llx\n链号\t%s\n提交数\t%d\n录时_S2A_IN\t%s\n录时_S2A_GAME_DATA\t%s\n录时_兜底目录\t%s\n",
                name, g ? g : "", (unsigned long long)g_fr_pres, (unsigned long long)atomic_load(&g_cur_frame), (unsigned long long)wb, (unsigned long long)ws, s2a_screen_w(), s2a_screen_h(),
                s2a_widen_game ? s2a_widen_game() : 0, s2a_widen_layout ? s2a_widen_layout() : 0, s2a_widen_full ? s2a_widen_full() : 1,
                (unsigned long long)(s2a_npdm_program_id ? s2a_npdm_program_id() : 0), DMSH_CHAIN, nsub, in ? in : "", gd ? gd : "", fb ? fb : "");
        fclose(f);
    }
    MLOG("%s 帧录 %s：第 %llu 次出图，提交 %d 次；游戏内存 %llu MB（%llu 段）、GPU 私有贴图 %d 张 %llu MB（不存 %d 张：含模板的多重采样 / 多重采样数组 / 不可读的多重采样 / 过大 / 不认的格式）；%.1f 秒 → %s",
         okm && oks && ng >= 0 && okf ? "" : "【红】", name, (unsigned long long)g_fr_pres, nsub, (unsigned long long)(mb >> 20), (unsigned long long)nreg, ng, (unsigned long long)(gb >> 20), skipped, (now_ns() - t0) / 1e9, d);
}
static void fr_png(const char *path, uint8_t *bgra, size_t w, size_t h, size_t row) {   // BGRA 整帧存 PNG（回放 replay.png、录时 live.png）
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(bgra, w, h, 8, row, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = url ? CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL) : NULL;
    if (ctx && img && dst) { CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst); }
    if (dst) CFRelease(dst); if (url) CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}
// hle_nvn.c nvnQueuePresentTexture，持提交锁、在把这次出图交给回放层之前调
void nvn_frec_present(const tex_t *t, double period, const int crop[4]) {
    if (!fr_on()) return;
    g_fr_pres++;
    char name[128] = "";
    if (atomic_load(&g_fr_req_set)) { snprintf(name, sizeof name, "%s", g_fr_req); atomic_store(&g_fr_req_set, 0); }
    else for (int i = 0; i < g_fr_nat; i++) if ((long)g_fr_pres == g_fr_at[i]) snprintf(name, sizeof name, "f%llu", (unsigned long long)g_fr_pres);
    if (name[0] && t) {
        fr_capture(name, t, period, crop);
        // 录的这一帧实际上屏的图存成 <名>/live.png：回放出的 replay.png 与它对照（11-05：旷野之息回放发白，要有实玩同帧的图才判得出对不对）
        char *lp = NULL; if (asprintf(&lp, "%s/%s/live.png", g_fr_dir, name) > 0)
            mtl_grab_next_present(^(const uint8_t *bgra, size_t w, size_t h, size_t row) { uint8_t *cp = malloc(row * h); if (cp) { memcpy(cp, bgra, row * h); fr_png(lp, cp, w, h, row); free(cp); } free(lp); });
    }
    g_fr_nh = 0;
}

// ---------- 回放 ----------
// [a, a+n) 在本进程里整段空着，或整段落在一块不可访问的保留里：真机录的命令记录块（iOS 录帧进程的命令记录区在窗口尾之上，11-06 旷野之息测试设备1）
//   在 Mac 回放进程里正落在复现 iPhone 地址约束占的保留中，可以按原地址盖上；落在已映射（库 / 堆 / 游戏内存）里的不碰（同 hle_nvn.c vp_in_none_reservation）
static int fr_claimable(uint64_t a, uint64_t n) {
    vm_address_t r = (vm_address_t)a; vm_size_t rs = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &r, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return 1;
    if ((uint64_t)r >= a + n) return 1;
    return (uint64_t)r <= a && a + n <= (uint64_t)r + rs && info.protection == VM_PROT_NONE;
}
static int fr_rw_mapped(uint64_t a, uint64_t n) {   // [a, a+n) 整段在本进程一块可读写的映射里
    vm_address_t r = (vm_address_t)a; vm_size_t rs = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &r, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return 0;
    return (uint64_t)r <= a && a + n <= (uint64_t)r + rs && (info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE);
}
static int fr_map_mem(const char *path, uint64_t wb, uint64_t ws, uint64_t *bytes) {
    FILE *f = fopen(path, "rb"); if (!f) return 0;
    uint32_t mg = 0; if (!fr_r(f, &mg, 4) || mg != FR_MAGIC) { fclose(f); return 0; }
    int ok = 1; *bytes = 0; uint64_t cur_lo = 0, cur_hi = 0;   // 相邻的映射段合成一次 mmap：零拷贝内存池要求整池落在一段虚拟内存里
    long pos = ftell(f);
    // 第一遍：段 → 合并后 mmap
    for (;;) {
        uint32_t t; if (!fr_r(f, &t, 4)) { ok = 0; break; }
        if (t == FR_REC_END) break;
        if (t == FR_REC_REGION) { uint64_t hd[3]; if (!fr_r(f, hd, sizeof hd)) { ok = 0; break; }
            if ((hd[0] < wb || hd[0] + hd[1] > wb + ws) && !fr_in_arena(hd[0], hd[1]) && !fr_claimable(hd[0], hd[1])) { MLOG("【红】 回放：录像的映射段 %#llx+%#llx 不在本进程地址窗口里", (unsigned long long)hd[0], (unsigned long long)hd[1]); ok = 0; break; }
            if (hd[0] == cur_hi) cur_hi += hd[1];
            else { if (cur_hi > cur_lo && mmap((void *)cur_lo, cur_hi - cur_lo, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) == MAP_FAILED) { ok = 0; break; } cur_lo = hd[0]; cur_hi = hd[0] + hd[1]; } }
        else if (t == FR_REC_DATA) { uint64_t dh[2]; if (!fr_r(f, dh, sizeof dh) || fseeko(f, (off_t)dh[1], SEEK_CUR)) { ok = 0; break; } }
        else { ok = 0; break; }
    }
    if (ok && cur_hi > cur_lo && mmap((void *)cur_lo, cur_hi - cur_lo, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) == MAP_FAILED) ok = 0;
    if (!ok) { MLOG("【红】 回放：映射游戏内存段失败（errno %d）", errno); fclose(f); return 0; }
    // 第二遍：内容。窗口外的（命令记录宿主块）按原地址映射，占不到原地址就报红
    fseek(f, pos, SEEK_SET);
    for (;;) {
        uint32_t t; if (!fr_r(f, &t, 4) || t == FR_REC_END) break;
        if (t == FR_REC_REGION) { uint64_t hd[3]; fr_r(f, hd, sizeof hd); continue; }
        uint64_t dh[2]; if (!fr_r(f, dh, sizeof dh)) { ok = 0; break; }
        if ((dh[0] < wb || dh[0] + dh[1] > wb + ws) && !fr_in_arena(dh[0], dh[1]) && !fr_rw_mapped(dh[0], dh[1])) {   // 第一遍已按映射段占上的（真机录的命令记录区）不再占
            size_t pg = (size_t)getpagesize(); uint64_t lo = dh[0] & ~(uint64_t)(pg - 1), hi = (dh[0] + dh[1] + pg - 1) & ~(uint64_t)(pg - 1);
            void *m = fr_claimable(lo, hi - lo) ? mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) : mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (m != (void *)lo) { MLOG("【红】 回放：命令记录宿主块 %#llx+%#llx 占不到原地址（得到 %p），这一帧引用它的命令回放不了", (unsigned long long)dh[0], (unsigned long long)dh[1], m); if (m != MAP_FAILED) munmap(m, hi - lo); fseeko(f, (off_t)dh[1], SEEK_CUR); ok = 0; continue; }
        }
        if (!fr_r(f, (void *)dh[0], dh[1])) { ok = 0; break; }
        *bytes += dh[1];
    }
    fclose(f);
    return ok;
}
static int fr_restore_state(const char *path, int *ntex) {
    FILE *f = fopen(path, "rb"); if (!f) return 0;
    fr_state_hd hd; if (!fr_r(f, &hd, sizeof hd) || hd.magic != FR_MAGIC) { fclose(f); return 0; }
    nvn_be_set_depth_zero((int)hd.depth_zero); nvn_be_set_origin_lower_left((int)(hd.origin_ll & 1)); nvn_be_set_tex_pool_n((int)hd.tpool_n);
    if (hd.origin_ll & 4) s2a_nvn_rast_flip = (int)((hd.origin_ll >> 1) & 1);   // front-face raster flip (hle_nvn.c nvnQueueInitialize); older recordings keep the default (on)
    int ok = 1;
    // Dirty tracking too, as nvnMemoryPoolInitialize does: an untracked pool's packaged textures count as changed at every use and were re-uploaded on every bind (one Breath of the Wild frame uploaded 100+ GB)
    for (uint32_t i = 0; ok && i < hd.npool; i++) { fr_pool pl; ok = fr_r(f, &pl, sizeof pl); if (ok) { nvn_be_pool_add((const void *)(uintptr_t)pl.lo, pl.size); nvn_dirty_add_range((const void *)(uintptr_t)pl.lo, pl.size); } }
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; ok && i < hd.nlive; i++) { uint64_t s; ok = fr_r(f, &s, 8); if (ok) nvn_hm_put(&g_tex_live, &s, (void *)1); }
    pthread_mutex_unlock(&g_smu);
    pthread_mutex_lock(&g_cpu_tex_mu); if (!g_cpu_tex.klen) nvn_hm_init(&g_cpu_tex, 8);
    for (uint32_t i = 0; ok && i < hd.ncpu; i++) { uint64_t s; ok = fr_r(f, &s, 8); if (ok) nvn_hm_put(&g_cpu_tex, &s, (void *)1); }
    pthread_mutex_unlock(&g_cpu_tex_mu);
    for (uint32_t i = 0; ok && i < hd.ntreg; i++) { fr_treg e; ok = fr_r(f, &e, sizeof e); if (ok) nvn_be_reg_tex(e.tid, &e.t, e.has_v ? &e.v : NULL); }
    for (uint32_t i = 0; ok && i < hd.nsreg; i++) { fr_sreg e; ok = fr_r(f, &e, sizeof e); if (ok) nvn_be_reg_samp(e.sid, &e.p); }
    for (uint32_t i = 0; ok && i < hd.nxv; i++) { uint64_t s; ok = fr_r(f, &s, 8); if (ok) nvn_be_xv_window_tex(s); }
    uint32_t ng = 0;   // 末尾的 GPU 地址表（见 fr_dump_state）；旧文件读不到就是 0 段
    if (ok && fr_r(f, &ng, 4) && ng) { uint64_t *gt = malloc((size_t)ng * 24); if (gt && fr_r(f, gt, (size_t)ng * 24)) nvn_gva_restore(gt, (int)ng); else ok = 0; free(gt); }
    // 有 GPU 地址的池范围、录时为池表驻留着的池（见 fr_dump_state）：11-12 起才录。旧录像没有这两节就不放：回放的原始内存池表会是 0 段 / 全冷，
    //   读全局内存的着色器读回 0，用读到的值当循环次数的着色器跑飞、整队列挂死——11-13 一款直连 3D 游戏 11-06 的录像在两台 Mac 上都第 7 遍稳定「卡死」，
    //   追了一整轮才发现是录像缺表的假象（docs/坑记录.md）。报红说清楚、不放，免得下一个人再拿它找游戏的毛病；用当前宿主重录
    uint32_t na = 0, nm = 0, nmr = 0;
    int has_na = ok && fr_r(f, &na, 4);
    for (uint32_t i = 0; ok && has_na && i < na; i++) { uintptr_t r[2]; ok = fr_r(f, r, sizeof r); if (ok) nvn_be_pool_addressed((const void *)r[0], r[1] - r[0]); }
    int has_nm = ok && has_na && fr_r(f, &nm, 4);
    if (ok && !has_nm) {
        MLOG("【红】 回放：录像 %s 没有「有 GPU 地址的池范围 / 为池表驻留的池」两节（11-12 之前的旧录像）：放了原始内存池表是 0 段，"
             "读全局内存的着色器读回 0、可能整帧跑飞挂死 GPU（不是游戏的问题）。不放，请用当前宿主重录", path);
        fclose(f); return 0;
    }
    if (ok && nm) { pthread_mutex_lock(&g_mu);
        for (uint32_t i = 0; ok && i < nm; i++) { uintptr_t r[2]; ok = fr_r(f, r, sizeof r); int k = ok ? pool_find(r[0], 1) : -1; if (k < 0 || g_pools[k].reg || g_pools[k].gm) continue;
            pool_ent *p = &g_pools[k]; if (!p->res) { res_add(p->buf); p->res = 1; g_pool_res_n++; } p->gm = 1; p->gseen = mtl_present_count(); nmr++; }
        if (nmr) { res_commit(); g_gmem_rgen++; }
        pthread_mutex_unlock(&g_mu);
        MLOG("回放：录时为原始内存池表驻留着的池 %u 个，放回 %u 个", nm, nmr); }
    *ntex = (int)hd.ntreg;
    fclose(f);
    return ok;
}
// 第一遍之后：GPU 私有贴图里录到的内容写回（回放建出的存储与录时同尺寸、同格式的才写；放宽 / 换了存储的跳过，靠重画）
static void fr_restore_gpu(const char *path, int *put, int *miss) {
    *put = *miss = 0;
    FILE *f = fopen(path, "rb"); if (!f) return;
    uint32_t mg = 0; if (!fr_r(f, &mg, 4) || mg != FR_GPU_MAGIC) { MLOG("【红】 回放：gpu.bin 是旧录法（不存深度模板 / 多重采样 / 压缩贴图），整份不写回：用本宿主重录"); fclose(f); return; }
    fr_tex_hd hd;
    while (fr_r(f, &hd, sizeof hd)) {
        id o = tex_get(hd.ser); id<MTLTexture> t = [o conformsToProtocol:@protocol(MTLTexture)] ? o : nil;
        if (!t || t.width != hd.w || t.height != hd.h || t.depth != hd.depth || (uint32_t)t.pixelFormat != hd.fmt || fr_slices(t) != hd.layers || t.mipmapLevelCount != hd.levels || t.sampleCount != hd.samples) {
            if (*miss < 32) MLOG("回放：贴图 ser=%llu 没写回：录时 %ux%ux%u 格式 %u 级 %u 层 %u 采样 %u，回放存储 %s%lux%lux%lu 格式 %lu 级 %lu", (unsigned long long)hd.ser, hd.w, hd.h, hd.depth, hd.fmt, hd.levels, hd.layers, hd.samples,
                                 t ? "" : "（没建出）", (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth, (unsigned long)t.pixelFormat, (unsigned long)t.mipmapLevelCount);
            fseeko(f, (off_t)hd.bytes, SEEK_CUR); (*miss)++; continue; }
        id<MTLBuffer> b = [g_dev newBufferWithLength:hd.bytes options:MTLResourceStorageModeShared];
        if (!b || !fr_r(f, b.contents, hd.bytes)) { (*miss)++; break; }
        if (hd.kind == FR_TK_MS ? fr_ms_write(t, b) : fr_blit_planes(t, &hd, b, 0)) (*put)++; else (*miss)++;
    }
    fclose(f);
}
static const char *fr_man(const char *man, const char *key, char *out, size_t n) {   // manifest.tsv 里 key 的值
    out[0] = 0; const char *p = man; size_t kl = strlen(key);
    while (p && *p) { if (!strncmp(p, key, kl) && p[kl] == '\t') { const char *v = p + kl + 1, *e = strchr(v, '\n'); size_t l = e ? (size_t)(e - v) : strlen(v); if (l >= n) l = n - 1; memcpy(out, v, l); out[l] = 0; return out; }
        p = strchr(p, '\n'); if (p) p++; }
    return NULL;
}
int nvn_frame_replay(const char *dir) {
    char p[1200], man[8192] = "", v[256];
    snprintf(p, sizeof p, "%s/manifest.tsv", dir);
    { FILE *f = fopen(p, "r"); if (!f) { MLOG("【红】 回放：没有 %s", p); return 1; } size_t n = fread(man, 1, sizeof man - 1, f); man[n] = 0; fclose(f); }
    if (!fr_man(man, "链号", v, sizeof v) || strcmp(v, DMSH_CHAIN)) MLOG("【红】 回放：录像的链号 %s 与本宿主 %s 不同：着色器库按本宿主的链号找", v, DMSH_CHAIN);
    uint64_t wb = 0, ws = 0, rwb = strtoull(fr_man(man, "窗口基址", v, sizeof v) ? v : "0", NULL, 0), rws = strtoull(fr_man(man, "窗口大小", v, sizeof v) ? v : "0", NULL, 0);
    if (!s2a_window_get) { MLOG("【红】 回放：宿主没有地址窗口接口"); return 1; }
    s2a_window_get(&wb, &ws);
    if (wb != rwb || rwb + rws > wb + ws) { MLOG("【红】 回放：本进程地址窗口 %#llx+%#llx 与录像 %#llx+%#llx 不同，游戏内存放不回原地址", (unsigned long long)wb, (unsigned long long)ws, (unsigned long long)rwb, (unsigned long long)rws); return 1; }
    int sw = atoi(fr_man(man, "屏幕宽", v, sizeof v) ? v : "1920"), sh = atoi(fr_man(man, "屏幕高", v, sizeof v) ? v : "1080");
    int wg = atoi(fr_man(man, "宽屏_游戏出宽图", v, sizeof v) ? v : "0"), wl = atoi(fr_man(man, "宽屏_界面布局", v, sizeof v) ? v : "0"), wf = atoi(fr_man(man, "宽屏_整套放宽", v, sizeof v) ? v : "1");
    if (s2a_frame_replay_screen) s2a_frame_replay_screen(sw, sh, wg, wl, wf); else MLOG("【红】 回放：宿主没有 s2a_frame_replay_screen，屏幕宽高按环境变量");
    if (s2a_npdm_program_id_set && fr_man(man, "程序号", v, sizeof v)) s2a_npdm_program_id_set(strtoull(v, NULL, 16));
    { const char *gd = getenv("S2A_GAME_DATA"); char q[1300];   // 着色器库 / 映射表：同局里第一次 nvnBootstrapLoader 定的（host_adapt.m direct_paths），这里没有游戏，按 S2A_GAME_DATA 定
      if (gd && *gd) { snprintf(q, sizeof q, "%s/shaders/direct", gd); setenv("DM_MSL_DIR", q, 0); snprintf(q, sizeof q, "%s/shaders/direct/shader_map.tsv", gd); setenv("DM_NVN_SHMAP", q, 0); }
      // 同局现编过的键：录时的兜底目录（11-07 起 Mac 局落局目录 <S2A_DOCS>/wire，回放的 S2A_DOCS 是输出目录，按清单找回；旧录像没这一行按文档根）
      if (fr_man(man, "录时_兜底目录", q, sizeof q) && q[0]) setenv("DM_MSL_FALLBACK", q, 0);
      if (s2a_npdm_program_id) { s2a_docs_path(q, sizeof q, "wire/%016llX/shaders", (unsigned long long)s2a_npdm_program_id()); setenv("DM_MSL_FALLBACK", q, 0); }   // 同局现编过的键（host_adapt.m 同一目录）：程序放回不经登记，缺键时 dm_shader_reuse 从这里复用
      if (!getenv("DM_NVN_SHMAP") || !getenv("DM_MSL_DIR")) { MLOG("【红】 回放：给 S2A_GAME_DATA（产物根），或 DM_NVN_SHMAP 与 DM_MSL_DIR"); return 1; } }
    uint64_t t0 = now_ns(), mb = 0;
    nvn_serial_floor(1ull << 40);   // 回放进程新建的对象不与录像里的序号撞（录时的计数远小于 2^40）
    mtl_init();
    snprintf(p, sizeof p, "%s/mem.bin", dir); if (!fr_map_mem(p, wb, ws, &mb)) { MLOG("【红】 回放：游戏内存放回失败"); return 1; }
    { snprintf(p, sizeof p, "%s/progkeys.bin", dir); FILE *kf = fopen(p, "rb"); int nk = kf ? s2a_hle_pk_load(kf) : -1; if (kf) fclose(kf);
      if (nk < 0) { MLOG("【红】 回放：progkeys.bin 读不了（旧录像没有：重录）"); return 1; } }
    { snprintf(p, sizeof p, "%s/vpool.bin", dir); FILE *vf = fopen(p, "rb"); int nv = vf ? s2a_hle_vpool_load(vf) : -1; if (vf) fclose(vf);   // 在登记池之前：虚拟池的段由这里登记（state.bin 里不再带）
      if (nv < 0) { MLOG("【红】 回放：vpool.bin 读不了（旧录像没有：重录）"); return 1; } if (nv) MLOG("回放：虚拟池 %d 个同址重建", nv); }
    int ntreg = 0; snprintf(p, sizeof p, "%s/state.bin", dir); if (!fr_restore_state(p, &ntreg)) { MLOG("【红】 回放：回放层的表恢复失败"); return 1; }
    snprintf(p, sizeof p, "%s/subs.bin", dir);
    FILE *f = fopen(p, "rb"); uint64_t pr[3]; double period = 0; int crop[4]; size_t nh = 0; uint64_t *h = NULL;
    int ok = f && fr_r(f, pr, sizeof pr) && fr_r(f, &period, sizeof period) && fr_r(f, crop, sizeof crop) && fr_r(f, &nh, sizeof nh) && (h = malloc(nh * 8 + 8)) && fr_r(f, h, nh * 8);
    if (f) fclose(f);
    if (!ok) { MLOG("【红】 回放：subs.bin 读不了"); return 1; }
    const tex_t *pt = (const tex_t *)(uintptr_t)pr[0];
    MLOG("回放 %s：游戏内存 %llu MB 放回、贴图登记 %d 个，%.1f 秒；这一帧 %llu 次提交，出图贴图 ser=%llu", dir, (unsigned long long)(mb >> 20), ntreg, (now_ns() - t0) / 1e9, (unsigned long long)pr[1], (unsigned long long)pt->serial);
    const char *ne = getenv("S2A_FRAME_REPLAY_N"); int N = ne ? atoi(ne) : 3; if (N < 1) N = 1;
    const char *dd = getenv("S2A_DOCS"); char shots[1100]; snprintf(shots, sizeof shots, "%s/shots", dd && *dd ? dd : "."); mkdir(shots, 0755);
    __block int grabbed = 0; __block int judged = 0; char png[1200]; snprintf(png, sizeof png, "%s/replay.png", shots); const char *pngp = png;
    uint64_t base_frame = atomic_load(&g_cur_frame) + 1;
    for (int it = 0; it < N; it++) {
        nvn_be_set_frame(base_frame + (uint64_t)it);
        uint64_t ps0, dr0, ps1, dr1, c0[2] = {0, 0}, c1[2] = {0, 0}; nvn_be_stats(&ps0, &dr0); uint64_t w0 = now_ns();
        thread_selfcounts(1, c0, sizeof c0);
        for (size_t i = 0; i < nh; i += 1 + h[i]) {
            int n = (int)h[i]; const uint64_t *hh = h + i + 1;
            nvn_be_sub_begin(); nvn_be_sub_index(hh, n);
            for (int k = 0; k < n; k++) { nvn_be_exec_rest(hh + k + 1, n - k - 1); nvn_be_exec((const uint8_t *)hh[k]); }
            nvn_be_exec_rest(NULL, 0); nvn_be_sub_commit();
        }
        thread_selfcounts(1, c1, sizeof c1); uint64_t w1 = now_ns(); nvn_be_stats(&ps1, &dr1);
        int last = it == N - 1;
        if (last) g_fj_last = UINT64_MAX - 1000;   // 满屏判据「至多隔 30 次出图判一次」：回放最后一遍一定判
        if (last) mtl_grab_next_present(^(const uint8_t *bgra, size_t w, size_t hh2, size_t row) {
            uint64_t tok = mtl_grab_fit_token(); uint8_t *cp = malloc(row * hh2); if (!cp) return; memcpy(cp, bgra, row * hh2);
            fr_png(pngp, cp, w, hh2, row);
            judged = tok ? mtl_fit_judge_shot(tok, cp, w, hh2, row) : 0;
            free(cp); __atomic_store_n(&grabbed, 1, __ATOMIC_RELEASE);
        });
        uint64_t tk = nvn_be_present(pt, period, crop[2] || crop[3] ? crop : NULL);
        nvn_be_present_wait(tk); mtl_finish_gpu();
        uint64_t nd = dr1 - dr0;
        // 周期数（本线程自己跑的 CPU 周期，不含被抢占、不随别的进程起伏）：tools/frame_bench.sh 拿它比编译参数，墙钟 ms 在多会话共用的机器上波动超 3%
        MLOG("回放第 %d / %d 遍：%llu 遍渲染、%llu 笔绘制，提交线程 %.2f ms、%llu 条指令、%llu 个周期%s", it + 1, N, (unsigned long long)(ps1 - ps0), (unsigned long long)nd, (w1 - w0) / 1e6,
             (unsigned long long)(c1[0] - c0[0]), (unsigned long long)(c1[1] - c0[1]), nd ? [NSString stringWithFormat:@"，每笔 %.1fk 条指令", (double)(c1[0] - c0[0]) / nd / 1000].UTF8String : "");
        if (it == 0) { int put = 0, miss = 0; snprintf(p, sizeof p, "%s/gpu.bin", dir); fr_restore_gpu(p, &put, &miss); MLOG("回放：GPU 私有贴图写回 %d 张（尺寸 / 格式对不上没写 %d 张，靠重画）", put, miss); }
    }
    for (int i = 0; i < 500 && !__atomic_load_n(&grabbed, __ATOMIC_ACQUIRE); i++) usleep(10000);
    if (!grabbed) { MLOG("【红】 回放：最后一遍的上屏图没抓到（5 秒）"); return 1; }
    MLOG("回放完：截图 %s，满屏判据%s（红行见上，没有红行 = 满屏）；共 %.1f 秒", png, judged ? "已判" : "没轮到判（几何项照判）", (now_ns() - t0) / 1e9);
    return 0;
}
