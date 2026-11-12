// 直连回放层四路后端冒烟（#277 D3-1，#278 D3-2）：在真 Metal 设备上链 libnvn.a，缺省（Metal 4）、NXGAL_BE=mtl3（强制 Metal 3）、
// Metal 3 + DM_NVN_ENC_THREAD=1（编码线程）、Metal 3 + DM_NVN_GPUPROF=0（逐编码器 GPU 时间）各起一个子进程，逐项核（后两路跑同一套各项，断言与前三路一致）：
//   ① 选路行「direct backend: Metal N (依据)」；Metal 3 有「地址查不到」一条红、不得再有「路径未齐」红（#329 D3-4 第 1 类后路径齐），且不得再有「GPU 解交错关」红（#329 D3-4 第 3 类后 GPU 解交错两路都在 GPU 上），Metal 4 下不得出现任何 Metal 3 字样；
//   ② 连交 5 次提交，每次带一个完成后写的事件值（主提交的完成回调、CPU 可见写回、主栅栏推进）；
//   ③ 主命令缓冲里的缓冲拷贝：两路都真拷（目的内容 = 源；Metal 3 走老拷贝编码器）；
//   ③a 同一提交里连拷带填：A → B、B → C（读前一条写的段，拷贝编码器内要屏障：Metal 3 拆成新拷贝编码器、靠栅栏排序）、填 D 再 D → E，C = A、E = 填充值；
//   ③b 回放命令流：整清一张 RGBA8 贴图（渲染遍清屏；贴图先补渲染目标用途，经拷贝编码器搬旧内容）→ 贴图拷进池（拷贝编码器），读回每像素 = 清屏色；
//   ③' 上传批：CPU_NO_ACCESS 池里有内容的块线性 RGBA8 贴图，提交内首次用到时经上传批填进 GPU 贴图（Metal 4：计算编码器 GPU 解交错；Metal 3：老计算编码器 GPU 解交错 + setBytes 参数块，
//       再经老队列从 GPU 贴图读回，逐字节等于 CPU 解交错的结果；
//   ③'a 解交错形状矩阵（#329 D3-4 第 3 类）：BGRA8 / RGB565 / RGBA_DXT1 / RGBA_DXT5 / 2D 数组第 3 层 / 3D 4 片 / mip 1 七个形状，
//       两路都经 GPU 解交错后读回，逐字节等于 CPU 解交错；有形状回退到 CPU 时打 RED_ONCE(41)，①的断言会红；
//   ③c Metal 3 地址反查（m3_buf_at）：池中一点的 GPU 地址反查回同一缓冲与偏移；不在任何常驻缓冲里的地址查不到并报红；
//   ④ 上屏：外部纹理经上屏线程画到离屏 CAMetalLayer 的可绘制体，且必须等外部事件（Metal 4 队列等事件 / Metal 3 命令缓冲内等事件）：
//      事件 300 ms 后才由 CPU 置位，上屏完成（完成回调推进上屏号）早于此即红。
// 不需要游戏；宿主符号在本文件打桩（直连层不起宿主）。用法：make -C gfx/nvn test（末行 ✓ / ✗）
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "../../../runtime/include/s2a_gfx_mode.h"
#include "../gfx/nvn/nvn_obj.h"
#include "../gfx/tex/nvn_deswizzle.h"

void mtl_init(void); void nvn_be_sub_begin(void); uint64_t nvn_be_sub_commit(void); int nvn_be_wait(uint64_t fence, uint64_t timeout_ns);
void mtl_sub_event(volatile uint32_t *val, uint32_t mode, uint32_t v); void mtl_sub_copy(uint64_t src, uint64_t dst, uint64_t n);
void nvn_be_pool_add(const void *mem, uint64_t size); void nvn_be_drain(void); void mtl_sub_fill(uint64_t dst, uint64_t n, uint32_t value);
int mtl_gpu_addr(uint64_t addr, uint64_t len, void **buf, uint64_t *off, uint64_t *gpu); int mtl_m3_buf(uint64_t gpu, void **buf, uint64_t *off);
uint64_t nvn_new_serial(void);
int mtl_tab_selftest(char *why, size_t n);
int mtl_psonorm_selftest(char *why, size_t n);
int mtl_rect_selftest(char *why, size_t n);
uint64_t mtl_ext_tex(void *tex); uint64_t mtl_present_ext(uint64_t serial, double period, void *ev, uint64_t ev_val, const int crop[4]); void nvn_be_present_wait(uint64_t ticket);
int mtl_fit_bad(int kind); int mtl_grab_inflight(void); void mtl_fit_pillar(int kind); uint64_t mtl_grab_fit_token(void); int mtl_fit_judge_shot(uint64_t tok, const uint8_t *p, size_t w, size_t h, size_t row); void mtl_grab_next_present(void (^cb)(const uint8_t *bgra, size_t w, size_t h, size_t row));
void nvn_be_set_frame(uint64_t f);

#include "host_stubs.h"   // 宿主替身（与 Vulkan 层单测共用）

static int fail;
#define CHECK(c, ...) do { if (!(c)) { fail = 1; printf("✗ "); } else printf("✓ "); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static int child(int m3) {
    setenv("DM_PRESENT_LINK", "0", 1);   // 上屏线程自取可绘制体（显示节拍要屏幕上的层）
    if (m3 && getenv("T_M3_ENC")) setenv("DM_NVN_ENC_THREAD", "1", 1);  // Metal 3 编码线程测试
    if (getenv("T_GPUPROF")) setenv("DM_NVN_GPUPROF", "0", 1);          // ⑥ GPUPROF：第 0 帧（gp_active 第一次调用就锁存环境变量，必须在这里设）
    g_layer = [CAMetalLayer layer]; g_layer.drawableSize = CGSizeMake(64, 64);
    mtl_init();
    // ② 5 次提交，各带一个完成后写的事件值
    static volatile uint32_t ev[5]; uint64_t f = 0;
    for (int i = 0; i < 5; i++) { nvn_be_sub_begin(); mtl_sub_event(&ev[i], 0, 100 + i); f = nvn_be_sub_commit(); }
    int done = nvn_be_wait(f, 5000000000ull), evok = 1; for (int i = 0; i < 5; i++) evok &= ev[i] == 100u + i;
    CHECK(done && f == 5 && evok, "5 次提交：栅栏 %llu %s，完成后写的事件值%s", (unsigned long long)f, done ? "已完成" : "超时", evok ? "全对" : "不对");
    // ③ 主命令缓冲里的缓冲拷贝（池内 4 KiB → 4 KiB）
    uint8_t *pool = NULL; posix_memalign((void **)&pool, 16384, 65536); memset(pool, 0xA5, 4096); memset(pool + 8192, 0, 4096);
    nvn_be_pool_add(pool, 65536);
    nvn_be_sub_begin(); mtl_sub_copy((uint64_t)(uintptr_t)pool, (uint64_t)(uintptr_t)(pool + 8192), 4096); f = nvn_be_sub_commit();
    done = nvn_be_wait(f, 5000000000ull);
    int copied = pool[8192] == 0xA5 && pool[8192 + 4095] == 0xA5;
    CHECK(done && copied, "Metal %d 主命令缓冲拷贝：目的%s", m3 ? 3 : 4, copied ? "= 源" : "不对");
    // ③a 同一提交里连拷带填：A(0) → B(16K) → C(24K)，填 D(32K) 再 D → E(40K)；第二、四条读前一条写的段，拷贝编码器内要屏障
    {
        uint64_t P = (uint64_t)(uintptr_t)pool; memset(pool + 16384, 0, 32768);
        nvn_be_sub_begin(); mtl_sub_copy(P, P + 16384, 4096); mtl_sub_copy(P + 16384, P + 24576, 4096); mtl_sub_fill(P + 32768, 4096, 0x5A5A5A5Au); mtl_sub_copy(P + 32768, P + 40960, 4096);
        f = nvn_be_sub_commit(); done = nvn_be_wait(f, 5000000000ull);
        int bad = 0; for (int i = 0; i < 4096; i++) bad += (pool[24576 + i] != 0xA5) + (pool[40960 + i] != 0x5A);
        CHECK(done && !bad, "连拷带填（读前一条写的段，编码器内屏障）：C = A、E = 填充值%s（不对的字节 %d）", done ? "" : "，提交超时", bad);
    }
    // ③' 上传批：块线性 64x64 RGBA8 在 CPU_NO_ACCESS 池里（池建立时存储里就有内容 = 贴图初值，tex_init_fill）
    {
        static pool_t pl; uint8_t *mem = NULL; posix_memalign((void **)&mem, 65536, 1 << 20);
        tex_t t; memset(&t, 0, sizeof t);
        t.magic = MAGIC('T', 'E', 'X', 0); t.d = (nvn_texdesc){NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 0, 0, 64, 64, 1, 1, 0, 0};
        nvn_tex_layout(&t.d, &t.L);
        for (uint64_t i = 0; i < t.L.size; i++) mem[i] = (uint8_t)(i * 131 + 7);
        pl = (pool_t){MAGIC('P', 'O', 'O', 'L'), NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, mem, 1 << 20};
        nvn_be_pool_add(mem, 1 << 20);
        t.pool = &pl; t.mem = mem; t.serial = nvn_new_serial(); nvn_be_tex_init(&t);
        static uint8_t got[64 * 64 * 4], want[64 * 64 * 4]; memset(got, 0xEE, sizeof got);
        NVNcopyRegion r = {0, 0, 0, 64, 64, 1};
        nvn_be_sub_begin(); nvn_be_read_texels(&t, 0, 0, &r, got, 64 * 4, sizeof got); f = nvn_be_sub_commit(); done = nvn_be_wait(f, 5000000000ull);
        int dz = nvn_deswizzle(&t.d, 0, 0, mem, want, 64 * 4);
        CHECK(done && !dz && t.L.size >= sizeof want && !memcmp(got, want, sizeof want), "上传批：目的 = 源（%llu 字节存储，GPU 贴图读回 = CPU 解交错）", (unsigned long long)t.L.size);
    }
    // ③'n 地址不在任何池里时报前后最近的两个池（#674 顶点缓冲槽读零，mtl_pool_near）。期望从自己分配的地址手算：一整块 1 MB 里登记 [base, +0x10000) 与 [base+0x40000, +0x20000)，
    //   查 base+0x19000 → 前一个池结束处距它 0x9000、后一个池开始处距它 0x27000（这两段都在本块里，别的池插不进来）；落在池里的地址回 0、不写
    {
        int mtl_pool_near(uint64_t addr, char *out, size_t n);
        uint8_t *blk = NULL; posix_memalign((void **)&blk, 1 << 20, 1 << 20); uintptr_t base = (uintptr_t)blk;
        nvn_be_pool_add(blk, 0x10000); nvn_be_pool_add(blk + 0x40000, 0x20000);
        char near[300] = "", want[300];
        int r = mtl_pool_near(base + 0x19000, near, sizeof near);
        snprintf(want, sizeof want, "previous pool %#lx size 0x10000 (ends 0x9000 before it), next pool %#lx size 0x20000 (starts 0x27000 after it); ", (unsigned long)base, (unsigned long)(base + 0x40000));
        CHECK(r == 1 && !strncmp(near, want, strlen(want)), "池缝里的地址：报出前后最近的池（实得「%s」）", near);
        char in[64] = "untouched"; r = mtl_pool_near(base + 0x41000, in, sizeof in);
        CHECK(r == 0 && !strcmp(in, "untouched"), "落在池里的地址：回 0、不写（实得 %d「%s」）", r, in);
    }
    // ③'a 解交错形状矩阵（#329 D3-4 第 3 类）：格式 / 块宽 / 数组层 / 3D 深度 / mip 级各取一个，同一份块线性存储经 GPU 解交错后读回，逐字节等于 CPU 解交错。
    //   回退到 CPU 会打 RED_ONCE(41)（不支持 format / target），父进程那条断言会变红，所以「形状都能上 GPU」本身也被核到
    {
        typedef struct { int target, format; uint32_t w, h, d, levels; unsigned level; int layer; const char *name; } dc;
        static const dc cases[] = {
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_BGRA8, 64, 32, 1, 1, 0, 0, "BGRA8 64x32"},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGB565, 128, 32, 1, 1, 0, 0, "RGB565 128x32"},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 128, 64, 1, 1, 0, 0, "RGBA_DXT1 128x64"},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT5, 64, 64, 1, 1, 0, 0, "RGBA_DXT5 64x64"},
            {NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA8, 64, 64, 3, 1, 0, 2, "2D 数组 RGBA8 64x64 第 3 层"},
            {NVN_TEXTURE_TARGET_3D, NVN_FORMAT_RGBA8, 32, 32, 4, 1, 0, 0, "3D RGBA8 32x32x4"},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 64, 64, 1, 3, 1, 0, "RGBA8 64x64 mip 1"},
        };
        int nbad = 0, ncase = 0;
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            const dc *c = &cases[i];
            static pool_t pl; uint8_t *mem = NULL; if (posix_memalign((void **)&mem, 65536, 4u << 20)) return 1;
            tex_t t; memset(&t, 0, sizeof t);
            t.magic = MAGIC('T', 'E', 'X', 0);
            t.d = (nvn_texdesc){c->target, c->format, 0, 0, c->w, c->h, c->d, c->levels, 0, 0};
            nvn_tex_layout(&t.d, &t.L);
            if (t.L.size > (4u << 20)) continue;
            for (uint64_t k = 0; k < t.L.size; k++) mem[k] = (uint8_t)(k * 131 + 7 + i * 29);
            pl = (pool_t){MAGIC('P', 'O', 'O', 'L'), NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, mem, 4u << 20};
            nvn_be_pool_add(mem, 4u << 20);
            t.pool = &pl; t.mem = mem; t.serial = nvn_new_serial(); nvn_be_tex_init(&t);
            int bw, bh, bpb = nvn_fmt_bpb(c->format, &bw, &bh);
            uint32_t w = MAX(c->w >> c->level, 1u), h = MAX(c->h >> c->level, 1u), z = c->target == NVN_TEXTURE_TARGET_3D ? MAX(c->d >> c->level, 1u) : 1;
            size_t row = (size_t)((w + bw - 1) / bw) * bpb, rows = (h + bh - 1) / bh, img = row * rows;
            uint8_t *got = calloc(z, img), *want = calloc(z, img);
            NVNcopyRegion r = {0, 0, c->layer, (int)w, (int)h, (int)z};   // 3D：zoffset 切片、整段深度；数组：zoffset 选层
            nvn_be_sub_begin(); nvn_be_read_texels(&t, c->level, 0, &r, got, row, img); uint64_t fc = nvn_be_sub_commit();
            int okc = nvn_be_wait(fc, 5000000000ull);
            int dzc = nvn_deswizzle(&t.d, c->level, (unsigned)c->layer, mem, want, row);
            int same = !dzc && !memcmp(got, want, img * z);
            ncase++; if (!(okc && same)) nbad++;
            printf("  %s %s：读回 = CPU 解交错 %s（%ux%u%s，行 %zu 字节、%d 片）\n", okc && same ? "✓" : "✗", c->name, same ? "是" : "否",
                   w, h, c->target == NVN_TEXTURE_TARGET_3D ? "x深" : "", row, (int)z);
            free(got); free(want);
        }
        CHECK(!nbad && ncase >= 6, "解交错形状矩阵：%d 个形状，%d 个不对", ncase, nbad);
    }
    // ③b 回放命令流：整清 64x64 RGBA8（渲染遍）→ 贴图拷进池 48K 处（拷贝编码器）
    {
        static pool_t pl; uint8_t *mem = NULL; posix_memalign((void **)&mem, 65536, 1 << 20); memset(mem, 0, 1 << 20);
        pl = (pool_t){MAGIC('P', 'O', 'O', 'L'), NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, mem, 1 << 20};
        nvn_be_pool_add(mem, 1 << 20);
        static tex_t t; memset(&t, 0, sizeof t);
        t.magic = MAGIC('T', 'E', 'X', 0); t.d = (nvn_texdesc){NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 0, 0, 64, 64, 1, 1, 0, 0};
        nvn_tex_layout(&t.d, &t.L); t.pool = &pl; t.mem = mem; t.serial = nvn_new_serial(); nvn_be_tex_init(&t);
        static uint64_t ops[64]; uint8_t *q = (uint8_t *)ops;
        p_clear_tex ct; memset(&ct, 0, sizeof ct); ct.tex = &t; ct.r = (NVNcopyRegion){0, 0, 0, 64, 64, 1}; ct.mask = 0xF; ct.c.f[0] = 1; ct.c.f[1] = 0; ct.c.f[2] = 1; ct.c.f[3] = 1;
        p_copy_b2t cp; memset(&cp, 0, sizeof cp); cp.src = (uint64_t)(uintptr_t)(pool + 49152); cp.tex = &t; cp.r = (NVNcopyRegion){0, 0, 0, 64, 64, 1};
        #define OP_PUT(code, arg) do { op_hdr h_ = {(code), (uint32_t)((sizeof(op_hdr) + sizeof(arg) + 7) & ~7u)}; memcpy(q, &h_, sizeof h_); memcpy(q + sizeof h_, &(arg), sizeof(arg)); q += h_.size; } while (0)
        OP_PUT(OP_CLEAR_TEX, ct); OP_PUT(OP_COPY_T2B, cp);
        op_hdr end = {OP_END, sizeof(op_hdr)}; memcpy(q, &end, sizeof end);
        #undef OP_PUT
        memset(pool + 49152, 0, 16384);
        uint64_t h = (uint64_t)(uintptr_t)ops;
        nvn_be_sub_begin(); nvn_be_sub_index(&h, 1); nvn_be_exec_rest(NULL, 0); nvn_be_exec((const uint8_t *)ops); f = nvn_be_sub_commit(); done = nvn_be_wait(f, 5000000000ull);
        int bad = 0; for (int i = 0; i < 64 * 64; i++) { uint32_t px; memcpy(&px, pool + 49152 + 4 * i, 4); bad += px != 0xFFFF00FFu; }
        uint32_t px0; memcpy(&px0, pool + 49152, 4);
        CHECK(done && !bad, "回放：整清（渲染遍）→ 贴图拷进池，读回每像素 = 清屏色 RGBA 1,0,1,1（首像素 %08x，不对的 %d 个%s）", px0, bad, done ? "" : "，提交超时");
    }
    // ③c Metal 3 地址反查
    if (m3) {
        void *b1 = NULL, *b2 = NULL, *b3 = (void *)1; uint64_t o1 = 0, o2 = 0, o3 = 0, g1 = 0;
        int in = mtl_gpu_addr((uint64_t)(uintptr_t)pool + 100, 4, &b1, &o1, &g1), hit = mtl_m3_buf(g1, &b2, &o2), miss = mtl_m3_buf(16, &b3, &o3);
        CHECK(in && hit && b2 == b1 && o2 == o1 && !miss && !b3, "Metal 3 地址反查：池中一点 → 同一缓冲、偏移 %llu；不在任何常驻缓冲里的地址查不到", (unsigned long long)o2);
    }
    // ③''' Metal 3 参数表（#279 D3-3）：池外缓冲按内部地址绑（地址反查），真老计算编码器派发读回；不在任何驻留缓冲里的地址不绑、计数；撤出驻留后不再反查到
    if (m3) { char why[300]; int r = mtl_tab_selftest(why, sizeof why); CHECK(r == 0, "Metal 3 参数表：%s", why); }
    { char why[300]; int r = mtl_psonorm_selftest(why, sizeof why); CHECK(r == 0, "管线键归一：%s", why); }
    { char why[300]; int r = mtl_rect_selftest(why, sizeof why); CHECK(r == 0, "局部重传几何（字节 ↔ 纹素矩形）：%s", why); }
    // ④ 外部纹理上屏，等外部事件
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td]; uint32_t px[64 * 64]; for (int i = 0; i < 64 * 64; i++) px[i] = 0xff3366cc;
    [tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:64 * 4];
    id<MTLSharedEvent> xev = [dev newSharedEvent];
    uint64_t ser = mtl_ext_tex((__bridge void *)tex);
    // 登记后不先提交、直接上屏（#298：mtl_ext_tex 原先只加驻留集不 commit，Metal 4 上屏命令缓冲缺页；现在登记即 commit），「无命令缓冲报错」那条兜着
    uint64_t t0 = now_ns(), tk = mtl_present_ext(ser, 0, (__bridge void *)xev, 1, NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ xev.signaledValue = 1; });
    nvn_be_present_wait(tk); double ms = (now_ns() - t0) / 1e6;
    CHECK(tk == 1 && ms >= 280, "上屏 1 次：等外部事件后才完成（%.0f ms，事件 300 ms 置位）", ms);
    tk = mtl_present_ext(ser, 0, (__bridge void *)xev, 1, NULL); nvn_be_present_wait(tk);
    nvn_be_drain();
    CHECK(tk == 2, "上屏 2 次（事件已到，直接画），全部完成");
    // ⑥ GPUPROF（DM_NVN_GPUPROF=0）：第 0 帧收尾——帧号推到 1 后再提交一次，帧末尾那次提交把累计的编码器时间解析出来（gp_report）
    if (getenv("T_GPUPROF")) {
        nvn_be_set_frame(1);
        nvn_be_sub_begin(); mtl_sub_fill((uint64_t)(uintptr_t)pool, 64, 0x3C3C3C3Cu); f = nvn_be_sub_commit(); done = nvn_be_wait(f, 5000000000ull);
        CHECK(done, "GPUPROF：第 0 帧收尾的提交完成（栅栏 %llu）", (unsigned long long)f);
    }
    // ⑤ 满屏判据（10-26，同通用模式出图层；期望按像素手算，不跑被测实现）：屏 208×96（宽高比 2.167，同 iPhone 2346×1080 量级），在自动玩家要的整屏截图上判、至少隔 30 次出图判一次、连续 2 次才报
    //   a 出图 208×96、中间 [18,190) 灰、两侧各 18 列纯黑（in = (208 − round(96×16/9)) / 2 = 18）→ 内容判没满屏；b 同尺寸整幅灰 → 内容恢复；
    //   c 出图 171×96（16:9）→ 上屏视口宽 171 < 屏宽 208 − 2 → 几何判没满屏（截图有内容才确认）
    //   判红那一帧存盘（10-30）：S2A_DOCS 指临时目录，a 记红后 <S2A_DOCS>/shots/fit_red_1.png 是 208×96、第 0 列纯黑、第 104 列灰 0x80（按构造）
    {
        char docs[] = "/tmp/t_nvn_m3_docs.XXXXXX"; if (mkdtemp(docs)) setenv("S2A_DOCS", docs, 1);
        g_layer.drawableSize = CGSizeMake(208, 96);
        id<MTLTexture> (^mk)(int, int, int) = ^(int w, int h, int band) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [dev newTextureWithDescriptor:d]; uint32_t *q = malloc((size_t)w * h * 4);
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) q[y * w + x] = x < band || x >= w - band ? 0xff000000 : 0xff808080;
            [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:q bytesPerRow:(NSUInteger)w * 4]; free(q); return t; };
        // 取图方同 host_adapt.m：回调（上屏线程）里只拷字节、记令牌，判据在本线程（取图方）用拷贝判；judge = 0 时取图方不判（上屏线程不许自己判，10-30 d2r 慢帧）
        __block uint8_t *cp = NULL; __block size_t cw = 0, ch = 0; __block uint64_t ctok = 0;
        void (^run)(id<MTLTexture>, int) = ^(id<MTLTexture> t, int judge) { uint64_t s = mtl_ext_tex((__bridge void *)t);
            for (int i = 0; i < 100; i++) {
                dispatch_semaphore_t got = dispatch_semaphore_create(0);   // the bytes arrive from the copy's completed handler (not on the present thread, not before the present returns)
                mtl_grab_next_present(^(const uint8_t *b, size_t w, size_t h, size_t r) { if (b) { cp = realloc(cp, w * h * 4); for (size_t y = 0; y < h; y++) memcpy(cp + y * w * 4, b + y * r, w * 4); cw = w; ch = h; ctok = mtl_grab_fit_token(); } dispatch_semaphore_signal(got); });
                nvn_be_present_wait(mtl_present_ext(s, 0, (__bridge void *)xev, 1, NULL));
                // 截图到了（拷贝回调里发信号）还要等这次取图收尾（g_grab_busy 清零）再出下一张：回调先于清标志调用，紧接着出图会撞上「还在取」而这一帧不取（11-06 gate-host 满载
                //   「第 41 次出图的截图 5 秒没到」就是这个竞态）。等的是事件，60 秒只是防卡死的兜底
                if (dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) { printf("✗ 满屏判据：第 %d 次出图的截图 60 秒没到（取图收尾 %d）\n", i, mtl_grab_inflight()); fail++; mtl_grab_next_present(nil); break; }
                while (mtl_grab_inflight()) sched_yield();
                if (judge && ctok) mtl_fit_judge_shot(ctok, cp, cw, ch, cw * 4);
                ctok = 0; } };
        run(mk(208, 96, 18), 0); int a0 = mtl_fit_bad(1);
        CHECK(!a0, "满屏判据：取图方不判时上屏线程不判 → 内容 %d（期望 0）", a0);
        run(mk(208, 96, 18), 1); int a = mtl_fit_bad(1);
        { char png[1100]; snprintf(png, sizeof png, "%s/shots/fit_red_1.png", docs); size_t pw = 0, ph = 0; uint8_t px[2][4] = {{0}};
          CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)png, strlen(png), false); CGImageSourceRef src = u ? CGImageSourceCreateWithURL(u, NULL) : NULL;
          CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
          if (im) { pw = CGImageGetWidth(im); ph = CGImageGetHeight(im); uint8_t *buf = calloc(pw * ph, 4); CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
              CGContextRef cx = CGBitmapContextCreate(buf, pw, ph, 8, pw * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
              if (cx) { CGContextDrawImage(cx, CGRectMake(0, 0, pw, ph), im); memcpy(px[0], buf + (48 * pw + 0) * 4, 4); memcpy(px[1], buf + (48 * pw + 104) * 4, 4); CGContextRelease(cx); }
              CGColorSpaceRelease(cs); free(buf); CGImageRelease(im); }
          if (src) CFRelease(src); if (u) CFRelease(u);
          CHECK(pw == 208 && ph == 96 && px[0][0] == 0 && px[0][1] == 0 && px[0][2] == 0 && px[1][0] == 0x80 && px[1][1] == 0x80 && px[1][2] == 0x80,
                "满屏判据：判红那一帧存盘 %s → %zux%zu、第 0 列 %02x%02x%02x、第 104 列 %02x%02x%02x（期望 208x96、000000、808080）", png, pw, ph, px[0][2], px[0][1], px[0][0], px[1][2], px[1][1], px[1][0]); }
        run(mk(208, 96, 0), 1); int b = mtl_fit_bad(1), b0 = mtl_fit_bad(0);
        run(mk(171, 96, 0), 1); int c = mtl_fit_bad(0);
        // ⑤' 无窗口（Mac 普查 / 健康表局没有出图层）也判几何：虚拟画布宽高比 = 16:9 × k ÷ ky（宽屏核心的屏）。替身设 k = 208 ÷ (96 × 16/9) = 1.21875、ky = 1
        //   → 画布同上面的 208×96：整幅 208×96 → 几何满屏；16:9 出图 171×96 → 只占 171 / 208 宽 → 几何没满屏（11-02 饥荒普查假绿：无窗口从不判几何）
        CAMetalLayer *keep = g_layer; g_layer = nil; g_stub_widen_k = 1.21875f;
        run(mk(208, 96, 0), 1); int d = mtl_fit_bad(0);
        run(mk(171, 96, 0), 1); int e = mtl_fit_bad(0);
        g_layer = keep; g_stub_widen_k = 1;
        CHECK(!d && e, "满屏判据（无窗口）：屏 208×96 的虚拟画布上整幅出图 → 几何 %d（期望 0）；16:9 出图 171×96 → 几何没满屏 %d（期望 1）", d, e);
        // ⑤'' 留黑边段第一帧存盘（11-02 维护者：段里要有截图才能分局内 / 界面页）：包装层标原比例页（1）后出两侧各 18 列黑的 208×96 → 判据进原比例状态、
        //   <S2A_DOCS>/shots/fit_pil_1.png 存在、208 宽；再出一张同样的 → 状态没变、不再存第 2 张（按构造）
        mtl_fit_pillar(1); run(mk(208, 96, 18), 1); run(mk(208, 96, 18), 1); mtl_fit_pillar(0);
        { char f1[1100], f2[1100]; snprintf(f1, sizeof f1, "%s/shots/fit_pil_1.png", docs); snprintf(f2, sizeof f2, "%s/shots/fit_pil_2.png", docs);
          CGImageSourceRef src = NULL; CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)f1, strlen(f1), false); if (u) src = CGImageSourceCreateWithURL(u, NULL);
          CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL; size_t pw = im ? CGImageGetWidth(im) : 0;
          if (im) CGImageRelease(im); if (src) CFRelease(src); if (u) CFRelease(u);
          CHECK(pw == 208 && access(f2, F_OK) != 0, "满屏判据：留黑边段第一帧存盘 %s → 宽 %zu（期望 208），同一段第二张不存（fit_pil_2 %s）", f1, pw, access(f2, F_OK) ? "没有" : "有");
          unlink(f1); unlink(f2); }
        nvn_be_drain(); free(cp);
        CHECK(a && !b && !b0 && c, "满屏判据：两侧黑带 → 内容没满屏 %d（期望 1）；整幅有内容 → 内容 %d / 几何 %d（期望 0 / 0）；16:9 出图上 208 宽屏 → 几何没满屏 %d（期望 1）", a, b, b0, c);
        for (int k = 1; k <= 3; k++) { char f[1100]; snprintf(f, sizeof f, "%s/shots/fit_red_%d.png", docs, k); unlink(f); }   // 临时文档目录用完即删（本段最多记 3 次红）
        { char d[1100]; snprintf(d, sizeof d, "%s/shots", docs); rmdir(d); rmdir(docs); }
    }
    return fail;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--child")) return child(atoi(argv[2]));
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("✗ t_nvn_m3：没有 Metal 设备\n"); return 1; }
    int os26 = 0; if (@available(macOS 26.0, *)) os26 = 1;
    if (!os26 || ![dev supportsFamily:MTLGPUFamilyMetal4]) { printf("✗ t_nvn_m3：本机不是 Metal 4 设备（26 起、Metal 4 家族），缺省一路核不了 Metal 4\n"); return 1; }
    int bad = 0;
    for (int run = 0; run < 4; run++) {
        int m3 = run >= 1, enc = run == 2, prof = run == 3;  // 0: Metal 4, 1: Metal 3, 2: Metal 3 + 编码线程, 3: Metal 3 + GPUPROF
        char log[] = "/tmp/t_nvn_m3.XXXXXX"; int fd = mkstemp(log); if (fd < 0) return 1;
        printf("== %s\n", prof ? "NXGAL_BE=mtl3 + DM_NVN_GPUPROF=0（Metal 3 逐编码器 GPU 时间）" : enc ? "NXGAL_BE=mtl3 + DM_NVN_ENC_THREAD=1（Metal 3 编码线程）" : m3 ? "NXGAL_BE=mtl3（强制 Metal 3）" : "缺省（Metal 4）"); fflush(stdout);
        pid_t p = fork();
        if (!p) { dup2(fd, 2); if (m3) setenv("NXGAL_BE", "mtl3", 1); else unsetenv("NXGAL_BE"); if (enc) setenv("T_M3_ENC", "1", 1); if (prof) setenv("T_GPUPROF", "1", 1);
                  execl(argv[0], argv[0], "--child", m3 ? "1" : "0", (char *)NULL); _exit(127); }
        int st; waitpid(p, &st, 0); close(fd);
        FILE *f = fopen(log, "r"); static char buf[1 << 20]; size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0; buf[n] = 0; if (f) fclose(f); unlink(log);
        int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
        printf("%s 子进程%s\n", ok ? "✓" : "✗", ok ? "各项通过" : WIFSIGNALED(st) ? "被信号杀掉（崩溃）" : "有项不过");
        const char *want = m3 ? "direct backend: Metal 3 (forced by NXGAL_BE=mtl3)" : "direct backend: Metal 4 (GPU in the Metal 4 family)";
        int line = strstr(buf, want) != NULL; printf("%s 选路行：%s\n", line ? "✓" : "✗", want); ok &= line;
        if (m3) {
            int inc = strstr(buf, "【红】 Metal 3 path incomplete") != NULL, path = strstr(buf, "Metal 3 path: ") != NULL, dz = strstr(buf, "【红】 Metal 3: GPU deswizzle off") != NULL,
                miss = strstr(buf, "【红】 Metal 3: GPU address 0x10 is in no resident buffer") != NULL,
                on = strstr(buf, "Metal 3: GPU deswizzle on") != NULL,
                fb = strstr(buf, "GPU deswizzle does not support format") != NULL || strstr(buf, "swizzled texture storage is not in a memory pool") != NULL;
            printf("%s 报红：路径未齐 %d（应为 0，路径行 %d）、GPU 解交错关 %d（应为 0）、地址查不到 %d；解交错在 GPU 上 %d、回退到 CPU %d（应为 0）\n",
                   !inc && path && !dz && miss && on && !fb ? "✓" : "✗", inc, path, dz, miss, on, fb); ok &= !inc && path && !dz && miss && on && !fb;
        } else {
            int clean = !strstr(buf, "Metal 3"); printf("%s Metal 4 下没有任何 Metal 3 字样\n", clean ? "✓" : "✗"); ok &= clean;
        }
        if (enc) {
            int thrd = strstr(buf, "Metal encoding runs on its own thread") != NULL;
            printf("%s Metal 3 编码线程：日志有「Metal encoding runs on its own thread」\n", thrd ? "✓" : "✗"); ok &= thrd;
        }
        if (prof) {   // ⑥ GPUPROF 的 Metal 3 版：同一 [gpuprof] 行格式（逐编码器 + 帧合计）。本机 GPU 不支持阶段边界采样时它自己报一条红线，那条也算诚实答案
            int rows = strstr(buf, " us render pass ") != NULL || strstr(buf, " us compute / copy after pass ") != NULL, sum = strstr(buf, "[gpuprof] frame 0: render ") != NULL,
                red = strstr(buf, "【红】 DM_NVN_GPUPROF is off on Metal 3") != NULL,
                unsup = strstr(buf, "GPUPROF on Metal 3 needs the timestamp counter set") != NULL || strstr(buf, "GPUPROF: no Metal 3 sample buffer") != NULL;
            int good = !red && (rows && sum || unsup);
            printf("%s Metal 3 GPUPROF：逐编码器行 %d、帧合计行 %d、不支持的红 %d；旧「Metal 3 上关闭」红 %d（应 0）\n", good ? "✓" : "✗", rows, sum, unsup, red);
            ok &= good;
        }
        int fill = strstr(buf, "initial content: ser=") != NULL; printf("%s 上传批经过「初值填充」一路（tex_init_fill）\n", fill ? "✓" : "✗"); ok &= fill;
        int err = strstr(buf, "command buffer error") != NULL || strstr(buf, "FATAL") != NULL; printf("%s 无命令缓冲报错 / FATAL\n", err ? "✗" : "✓"); ok &= !err;
        if (!ok) { printf("---- 子进程标准错误（末 3000 字节）\n%s\n----\n", n > 3000 ? buf + n - 3000 : buf); bad++; }
    }
    printf("%s t_nvn_m3：四路后端冒烟（Metal 4、Metal 3、Metal 3 编码线程、Metal 3 GPUPROF），%d 路不过\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
