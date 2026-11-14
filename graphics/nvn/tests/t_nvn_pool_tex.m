// 追不到槽的句柄读整个池（反射 tex_pool / samp_pool → NVN_RB_TEXP / SAMPP，nvn_mtl.m pool_gpu / pool_tab_new / pool_ent_put / pool_seen_scan / pool_pin_retire；Dsh.cs PoolArrays）。
// 11-06 Switch2 线 63：翻译器原先把 Ryujinx 回退数组 <阶段>_<t|s>_cb0_40000000 写死 32 项、下标夹到 31，宿主第 k 项绑第 k 个贴图槽：句柄指的贴图编号 ≥ 32 时读到别的贴图
//   （时之笛 4,454 支，抽查一支是阴影深度比较）。现照上游参考实现（MIT）the reference port：池指针 + 宿主池表 + 已读位图 + 未写渲染目标不建 + 小贴图预建 + 表复用。
// 着色器 = Dsh.cs PoolArrays 改写后的形状（tests/dmsh_pool_arrays_test.sh 核同一形状由改写产出、能编），走生产 dispatch + 真 Metal 设备。
// 贴图：R32F，编号 id 的贴图每个纹素 = id + 0.5（小的 4x4；大的 2048 宽、高按 12 / 14 / 18 / 20 / 22 MB 取，各不相同）。期望按语义手写，与被测实现无关：
//   ① 句柄 ≥ 32 读到正确贴图：贴图号 40、采样器号 40 → 40.5；贴图号 3 → 3.5
//   ② 位图置位：第一次派发读了 40、3、51、60 → 位图里这 4 位为 1；没读的 41、50 为 0
//   ③ 折叠后只建被读的 + 每帧预建上限：首次走池按小到大预建，本帧 32 MB 放得下小贴图 + 12 MB + 14 MB（共约 26 MB），18 MB（50）/ 20 MB（51）不建，
//      读 51 得占位 0.0；下一次提交折叠位图 → 51 建出、读得 51.5，同时 50（上次没读）仍不建、读得 0.0；再下一次 50 也建出、读得 50.5
//   ④ 没被任何遍写过的渲染目标（COMPRESSIBLE，60）读到也不为读而建：两次读都是 0.0、始终没建；同样大小的普通贴图（61）读得 61.5
//   ⑤ 已读贴图每帧上限 128 MB：本帧已记满时，GPU 置了位的 52（22 MB）留在待建表、不建；记账清零后下一次提交建出、读得 52.5
//   ⑥ 表增量维护（11-06 第 42 版：每次提交整表重走 + 新建表缓冲，19.7 帧 / 秒、低区地址空间耗尽）：之后几次提交里改登记 3 次，整表重走 0 次、新建表缓冲 0 张、
//      表地址不变；每次改登记后的那次提交只重查改了的那 1 个编号（登记重查计数 +1）
//   ⑨ 跨提交换贴图：40 改登记成另一张贴图（77.5），下一次提交表里第 40 项就是新贴图的资源号、读得 77.5
//      ⑨b 读过的编号换了存储（序号指向另一张贴图、旧的仍被共享表留着不退役）：下一次提交表里就是新的
//   ⑩ 旧贴图活到引用它的提交做完：表里有 91 的贴图 X，它的内存池销毁、X 交退役。退役栅栏过了、下一次提交开头清延迟队列时 X 仍在常驻集合（表还指着它）；
//      这次提交取表时第 91 项换成占位；这次提交做完、再下一次清队列后 X 才出常驻集合
//   ⑦ 池基址：绑定的贴图池基址 260 时，句柄里的本地号 40 → 第 300 号贴图 → 300.5
//   ⑧ 对照（旧语义）：同一句柄 40 经 32 项槽位数组（TEXD）读 → 夹到槽 31（空）→ 0.0，不是 40.5
// 修前（main 的 nvn_refl.m / nvn_mtl.m）：反射报「B binding kind tex_pool not implemented」，①–⑦ 跑不起来，只有 ⑧ 照旧。
// 8c522975b 的宿主（代号一变整表重走、每次新建表缓冲、不钉常驻）没有这些接口，编不过本单测；它的做法由负对照「整表重走」「不钉常驻」复现，⑥ ⑩ 红。
// 负对照：删 pool_gpu 里的 pool_seen_scan() → ③ 51 不建（红）；pool_unwritten_target 恒 0 → ④ 60 被建（红）；pool_pin_retire 恒 0（不钉常驻）→ ⑩ 红；
//   有改登记就整表重走（丢表重建）→ ⑥ 红；不处理改登记的编号 → ⑥ ⑨ 红；读过的编号不随存储变化重查 → ⑨b 红
#include "../gfx/nvn/nvn_mtl.m"
#include <malloc/malloc.h>

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MEM = 160 << 20, IO_OFF = 0x1000 };
static uint8_t *memory; static pool_t *pool; static size_t mem_next = 0x100000;
static tex_t texs[400];

static tex_t *texture_ex(int id, uint32_t w, uint32_t h, int flags, float val) {   // 每个纹素 = val
    tex_t *t = &texs[id]; memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_R32F, .width = w, .height = h, .depth = 1, .levels = 1, .flags = flags};
    nvn_tex_layout(&t->d, &t->L); REQUIRE(t->L.size);
    size_t off = (mem_next + 0xffff) & ~(size_t)0xffff; REQUIRE(off + t->L.size <= MEM); mem_next = off + t->L.size;
    t->pool = pool; t->off = (int64_t)off; t->mem = pool->mem + off;
    float *p = (float *)(memory + off); for (size_t i = 0; i < t->L.size / 4; i++) p[i] = val;   // 每个纹素同值：块线性排布不影响
    nvn_be_tex_init(t); nvn_be_reg_tex(id, t, NULL);
    return t;
}
static tex_t *texture(int id, uint32_t w, uint32_t h, int flags) { return texture_ex(id, w, h, flags, (float)id + 0.5f); }
// 这次提交里贴图池表（基址 0）第 tid 项：直接经 pool_gpu 取（不派发）
static uint64_t table_entry(int tid, int unused, uint64_t *gpu) {
    (void)unused; const pool_tab *tp = NULL; for (int i = 0; i < POOL_TABS; i++) if (g_ptab[i].used && !g_ptab[i].samp && g_ptab[i].base == 0) tp = &g_ptab[i];
    REQUIRE(tp);
    pthread_mutex_lock(&g_rmu);
    __unsafe_unretained id<MTLBuffer> b = nil; uint64_t a = pool_gpu(0, tp->dtt, tp->dpf, 0, &b); REQUIRE(b);
    uint64_t e = ((const uint64_t *)((const uint8_t *)b.contents + DMSH_POOL_HEAD))[tid];
    pthread_mutex_unlock(&g_rmu);
    if (gpu) *gpu = a;
    return e;
}
static uint64_t cur_rid(int tid) { pthread_mutex_lock(&g_rmu); uint64_t r = tex_fast_rid(tid, NULL); pthread_mutex_unlock(&g_rmu); return r; }
static int resident(id<MTLResource> r) { pthread_mutex_lock(&g_res_mu); int k = [g_res_objects containsObject:r]; pthread_mutex_unlock(&g_res_mu); return k; }
static void empty_sub(void) { nvn_be_sub_begin(); uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
static int made(int id) { return tex_get(texs[id].serial) != nil; }
static int seen_bit(int id) { return g_seen_buf && (((const uint32_t *)g_seen_buf.contents)[id >> 5] >> (id & 31) & 1); }
static NvShader *shader(NSString *src, NSDictionary *refl, char *err, int errlen) {
    NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_4;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:src] options:o error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); exit(2); }
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"main0"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    int rc = nvn_refl_from_json(refl, &cs->rf, err, errlen);
    return rc ? nil : cs;
}
static void run_cs(NvShader *cs) {
    static prog_t pg; memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(pg.serial, np);
    nvn_be_sub_begin();
    S.cprog = &pg; args_dirty_all();
    p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
}
// Dsh.cs PoolArrays 改写后的形状：贴图池读置位（dm_pool_mark）、采样器池不置位；句柄从存储缓冲第 0 个 uint4 取，结果写进第 1 个 float4
static NSString *const POOL_SRC =
    @"template<typename P> static inline __attribute__((always_inline)) uint dm_pool_mark(constant P* p, uint i)\n{\n"
     "    device uint* w = reinterpret_cast<device uint*>(p->seen) + (i >> 5);\n    uint b = 1u << (i & 31u);\n"
     "    if (!(*w & b)) atomic_fetch_or_explicit(reinterpret_cast<device atomic_uint*>(w), b, memory_order_relaxed);\n    return i;\n}\n\n"
     "struct spvPool_cp_t2d_cb0_40000000\n{\n    uint n;\n    ulong seen;\n    array<texture2d<float>, 1> e;\n};\n\n"
     "struct spvPool_cp_s_cb0_40000000\n{\n    uint n;\n    ulong seen;\n    array<sampler, 1> e;\n};\n\n"
     "struct spvDescriptorSetBuffer0\n{\n    device uint4* cp_s0 [[id(0)]];\n    constant spvPool_cp_t2d_cb0_40000000* cp_t2d_cb0_40000000 [[id(1)]];\n"
     "    constant spvPool_cp_s_cb0_40000000* cp_s_cb0_40000000 [[id(2)]];\n};\n\n"
     "kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gid [[thread_position_in_grid]])\n{\n"
     "    if (gid.x != 0) return;\n    uint4 h = spvDescriptorSet0.cp_s0[0]; float4 r;\n"
     "    for (int k = 0; k < 4; k++) {\n        uint t = min(h[k] & 1048575u, 1048575u), s = min(h[k] >> 20u, 4095u);\n"
     "        r[k] = (&spvDescriptorSet0.cp_t2d_cb0_40000000->e[0])[dm_pool_mark(spvDescriptorSet0.cp_t2d_cb0_40000000, min(uint(t), spvDescriptorSet0.cp_t2d_cb0_40000000->n))]"
     ".sample((&spvDescriptorSet0.cp_s_cb0_40000000->e[0])[min(uint(s), spvDescriptorSet0.cp_s_cb0_40000000->n)], float2(0.5), level(0.0)).x;\n    }\n"
     "    spvDescriptorSet0.cp_s0[1] = as_type<uint4>(r);\n}\n";
// 旧语义：32 项槽位数组（TEXD / SAMPD），下标夹到 31
static NSString *const SLOT_SRC =
    @"struct spvDescriptorSetBuffer0\n{\n    device uint4* cp_s0 [[id(0)]];\n    array<texture2d<float>, 32> cp_t2d_cb0_40000000 [[id(1)]];\n    array<sampler, 32> cp_s_cb0_40000000 [[id(33)]];\n};\n\n"
     "kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gid [[thread_position_in_grid]])\n{\n"
     "    if (gid.x != 0) return;\n    uint h = spvDescriptorSet0.cp_s0[0].x; uint t = min(h & 1048575u, 31u), s = min(h >> 20u, 31u);\n"
     "    float v = spvDescriptorSet0.cp_t2d_cb0_40000000[t].sample(spvDescriptorSet0.cp_s_cb0_40000000[s], float2(0.5), level(0.0)).x;\n"
     "    spvDescriptorSet0.cp_s0[1] = as_type<uint4>(float4(v));\n}\n";
static float out4[4];
static void read4(NvShader *cs, uint32_t h0, uint32_t h1, uint32_t h2, uint32_t h3) {
    uint32_t *io = (uint32_t *)(memory + IO_OFF); io[0] = h0; io[1] = h1; io[2] = h2; io[3] = h3; for (int i = 4; i < 8; i++) io[i] = 0xffffffffu;
    S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)io, .size = 32};
    run_cs(cs);
    memcpy(out4, io + 4, 16);
}
static int near(float a, float b) { return fabsf(a - b) < 1e-4f; }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    REQUIRE(!posix_memalign((void **)&memory, 65536, MEM)); memset(memory, 0, MEM);
    pool = calloc(1, sizeof *pool); REQUIRE(pool);
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = MEM};
    nvn_be_pool_add(memory, MEM);
    const int MB = 1 << 20; const uint32_t W = 2048;   // 大贴图 2048 宽 R32F：一行 8 KB，高 = 字节 / 8 KB
    texture(3, 4, 4, 0); texture(40, 4, 4, 0); texture(41, 4, 4, 0); texture(61, 4, 4, 0); texture(300, 4, 4, 0);
    texture(60, 4, 4, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    texture(70, W, 12 * MB / (W * 4), 0); texture(71, W, 14 * MB / (W * 4), 0); texture(50, W, 18 * MB / (W * 4), 0); texture(51, W, 20 * MB / (W * 4), 0);
    REQUIRE(texs[70].L.size < texs[71].L.size && texs[71].L.size < texs[50].L.size && texs[50].L.size < texs[51].L.size);
    samp_par sp; memset(&sp, 0, sizeof sp); sp.lod_max = 1000; nvn_be_reg_samp(40, &sp); nvn_be_reg_samp(1, &sp);
    S.tex_base = 0; S.samp_base = 0;
    char err[512] = "";
    NSDictionary *refl = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"cp_s0", @"msl_type": @"device uint4*" },
        @{ @"kind": @"tex_pool", @"elem": @"texture2d<float>", @"arg_id": @1, @"msl_name": @"cp_t2d_cb0_40000000", @"msl_type": @"constant spvPool_cp_t2d_cb0_40000000*" },
        @{ @"kind": @"samp_pool", @"elem": @"sampler", @"arg_id": @2, @"msl_name": @"cp_s_cb0_40000000", @"msl_type": @"constant spvPool_cp_s_cb0_40000000*" } ] };
    NvShader *cs = shader(POOL_SRC, refl, err, sizeof err);
    VERIFY(cs && cs->rf.nb == 3 && cs->rf.b[1].kind == NVN_RB_TEXP && cs->rf.b[2].kind == NVN_RB_SAMPP && cs->rf.pool && cs->rf.bindless,
           "反射：tex_pool → TEXP、samp_pool → SAMPP、记成池 / 无绑定（%s）", cs ? "转换成功" : err);
    if (cs) {
        // 第一次提交：读 40（采样器 40）、3、51、60
        read4(cs, 40u | 40u << 20, 3u | 1u << 20, 51u | 1u << 20, 60u | 1u << 20);
        VERIFY(near(out4[0], 40.5f) && near(out4[1], 3.5f), "① 句柄 40（采样器 40）→ %.2f（期望 40.50）、句柄 3 → %.2f（期望 3.50）", out4[0], out4[1]);
        VERIFY(seen_bit(40) && seen_bit(3) && seen_bit(51) && seen_bit(60) && !seen_bit(41) && !seen_bit(50),
               "② 位图：40 %d、3 %d、51 %d、60 %d（期望全 1）；41 %d、50 %d（期望 0）", seen_bit(40), seen_bit(3), seen_bit(51), seen_bit(60), seen_bit(41), seen_bit(50));
        VERIFY(made(70) && made(71) && !made(50) && !made(51) && near(out4[2], 0.0f),
               "③ 首次走池预建到本帧 32 MB：12 MB %d、14 MB %d（期望 1）；18 MB %d、20 MB %d（期望 0）；读 51 → %.2f（期望占位 0.00）", made(70), made(71), made(50), made(51), out4[2]);
        // 第二次提交：折叠位图 → 51 建；50 上次没读，仍不建
        read4(cs, 51u | 1u << 20, 41u | 1u << 20, 50u | 1u << 20, 60u | 1u << 20);
        VERIFY(made(51) && near(out4[0], 51.5f) && !made(50) && near(out4[2], 0.0f) && near(out4[1], 41.5f),
               "③ 折叠后只建被读的：51 已建 %d、读得 %.2f（期望 1、51.50）；50 已建 %d、读得 %.2f（期望 0、0.00）；41 → %.2f（期望 41.50）", made(51), out4[0], made(50), out4[2], out4[1]);
        read4(cs, 50u | 1u << 20, 60u | 1u << 20, 61u | 1u << 20, 3u | 1u << 20);
        VERIFY(made(50) && near(out4[0], 50.5f), "③ 再下一次：50 已建 %d、读得 %.2f（期望 1、50.50）", made(50), out4[0]);
        VERIFY(!made(60) && near(out4[1], 0.0f) && near(out4[2], 61.5f), "④ 没写过的渲染目标 60：已建 %d、读得 %.2f（期望 0、0.00）；普通贴图 61 → %.2f（期望 61.50）", made(60), out4[1], out4[2]);
        // ⑤ 本帧已读贴图记满 128 MB：GPU 置了 52 的位（这里直接置），下一次提交不建
        texture(52, W, 22 * MB / (W * 4), 0);
        ((uint32_t *)g_seen_buf.contents)[52 >> 5] |= 1u << (52 & 31);
        g_walk_req = POOL_REQ_BYTES;
        read4(cs, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20);
        int todo52 = g_seen_todo[52 >> 5] >> (52 & 31) & 1;
        VERIFY(!made(52) && todo52, "⑤ 记满 128 MB：52 已建 %d（期望 0）、仍在待建表 %d（期望 1）", made(52), todo52);
        g_walk_req = 0;
        read4(cs, 52u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20);
        VERIFY(made(52) && near(out4[0], 52.5f), "⑤ 记账清零后：52 已建 %d、读得 %.2f（期望 1、52.50）", made(52), out4[0]);
        // ⑥ 增量维护：之后的提交里改登记，不整表重走、不新建表缓冲、表地址不变，只重查改了的编号
        uint64_t w0 = g_pool_walks, m0 = g_pool_made, gpu0 = 0; nvn_be_sub_begin(); table_entry(3, 0, &gpu0); { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        unsigned one = 1; uint64_t gpu1 = gpu0;
        for (int k = 0; k < 3; k++) {
            texture_ex(41, 4, 4, NVN_TEXTURE_FLAGS_IMAGE, 41.5f);
            uint64_t d0 = g_pool_upd_dirty; nvn_be_sub_begin(); table_entry(3, 0, &gpu1); { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
            if (g_pool_upd_dirty - d0 != 1 || gpu1 != gpu0) one = 0;
        }
        VERIFY(g_pool_walks - w0 == 0 && g_pool_made - m0 == 0 && one, "⑥ 改登记 3 次：整表重走 %llu 次、新建表缓冲 %llu 张（期望 0、0）；每次只重查 1 个编号且表地址不变 %u（期望 1）",
               (unsigned long long)(g_pool_walks - w0), (unsigned long long)(g_pool_made - m0), one);
        // ⑦ 池基址 260：本地号 40 → 第 300 号
        S.tex_base = 260;
        read4(cs, 40u | 1u << 20, 40u | 1u << 20, 40u | 1u << 20, 40u | 1u << 20);
        VERIFY(near(out4[0], 300.5f), "⑦ 贴图池基址 260、句柄 40 → %.2f（期望 300.50）", out4[0]);
        S.tex_base = 0;
        // ⑨ 跨提交换贴图（新登记的带 IMAGE：不归「首用取存储」，单测里每次解析都重传、资源号每次都变，比不出新旧）
        read4(cs, 40u | 40u << 20, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20);
        atomic_fetch_add(&g_cur_frame, 1);   // 新的一帧：本帧预建额度重新算（单测不出帧，帧号不会自己走）
        texture_ex(40, 4, 4, NVN_TEXTURE_FLAGS_IMAGE, 77.5f);
        nvn_be_sub_begin(); uint64_t e40 = table_entry(40, 0, NULL), now40 = cur_rid(40); { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        read4(cs, 40u | 40u << 20, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20);
        VERIFY(e40 == now40 && near(out4[0], 77.5f), "⑨ 改登记后的下一次提交：第 40 项 = 新贴图 %d（期望 1）；读 40 → %.2f（期望 77.50）", e40 == now40, out4[0]);
        // ⑨b 被读过的编号换了存储（序号指向另一张贴图，旧的仍被共享表留着、不退役）：下一次提交表里就是新的
        atomic_fetch_add(&g_cur_frame, 1);
        texture_ex(90, 4, 4, NVN_TEXTURE_FLAGS_IMAGE, 90.5f);
        read4(cs, 90u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20);
        REQUIRE(near(out4[0], 90.5f));
        id<MTLTexture> X9 = tex_get(texs[90].serial); REQUIRE([X9 conformsToProtocol:@protocol(MTLTexture)]);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:X9.pixelFormat width:X9.width height:X9.height mipmapped:NO]; td.usage = X9.usage; td.storageMode = X9.storageMode;
        id<MTLTexture> Y = [g_dev newTextureWithDescriptor:td]; REQUIRE(Y); res_add(Y);
        empty_sub(); nvn_be_sub_begin(); table_entry(90, 0, NULL); { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }   // 90 的读位已折进 g_seen_done（不再是待建）
        serial_put(texs[90].serial, Y);
        nvn_be_sub_begin(); uint64_t e90 = table_entry(90, 0, NULL); { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        VERIFY(e90 == Y.gpuResourceID._impl, "⑨b 读过的 90 换了存储：下一次提交第 90 项 = 新贴图 %d（期望 1）", e90 == Y.gpuResourceID._impl);
        // ⑩ 旧贴图活到引用它的提交做完：91 在另一个内存池里，表里有它的贴图 X；池销毁（hle_nvn.c dpool_finalize 的做法：清共享表 → 贴图交退役 → 池失效）
        atomic_fetch_add(&g_cur_frame, 1);
        pool_t *pool2 = calloc(1, sizeof *pool2); REQUIRE(pool2);
        *pool2 = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = pool->flags, .mem = memory, .size = MEM};   // 另一个池对象（同一段宿主内存）
        pool_t *keep = pool; pool = pool2; texture_ex(91, 4, 4, NVN_TEXTURE_FLAGS_IMAGE, 91.5f); pool = keep;
        read4(cs, 91u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20, 3u | 1u << 20);
        REQUIRE(near(out4[0], 91.5f));
        id<MTLTexture> X = tex_get(texs[91].serial); REQUIRE([X conformsToProtocol:@protocol(MTLTexture)]);
        nvn_be_sub_begin(); REQUIRE(table_entry(91, 0, NULL) == X.gpuResourceID._impl); { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        nvn_be_alias_drop_pool(pool2); pool2->magic = 0;   // X 退役挂在下一次提交的栅栏上
        serial_del(texs[91].serial);
        empty_sub();
        nvn_be_sub_begin();   // 开头清延迟队列：X 的退役栅栏已过
        int res1 = resident(X);
        uint64_t e91 = table_entry(91, 0, NULL); int res2 = resident(X);
        { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        empty_sub();   // 开头清队列：取表那次提交已做完
        int res3 = resident(X);
        uint64_t dmy = g_dummy_tex_rid[MTLTextureType2D][0];
        VERIFY(res1 && e91 == dmy && res2 && !res3, "⑩ 池销毁后的旧贴图 X：退役栅栏过后仍常驻 %d（期望 1，表还指着它）；取表时第 91 项换成占位 %d（期望 1）、X 仍常驻 %d（期望 1）；取表那次提交做完后出常驻集合 %d（期望 1）",
               res1, e91 == dmy, res2, !res3);
    }
    // ⑪ 表长大后对象数组和登记的容量一样长：越过缓冲（按 64 KB 取整）的长大换新缓冲，之后在新缓冲容量内再长大不再 realloc，
    //    所以对象数组必须一次给够 t->cap 项（修前只给 n + n/4 + 1 项，第二次长大后 pool_ent_put 读越界，第47版 objc_retain 0x1f7 崩）
    { int ti = -1; for (int k = 0; k < POOL_TABS; k++) if (g_ptab[k].used && !g_ptab[k].samp) { ti = k; break; }
      pool_tab *t = ti >= 0 ? &g_ptab[ti] : NULL; size_t have = 0, need = 0; uint32_t c0 = t ? t->cap : 0;
      if (t) { pool_tab_put_n(t, t->cap); pool_tab_put_n(t, t->cap - 1); have = malloc_size(t->obj); need = (size_t)t->cap * sizeof(void *); }
      VERIFY(t && t->cap > c0 && have >= need, "⑪ 池表长大越过缓冲后：容量 %u → %u，对象数组 %zu 字节（期望 ≥ 容量 × 8 = %zu）", c0, t ? t->cap : 0, have, need); }
    // ⑧ 对照：旧的 32 项槽位数组
    NSDictionary *refl_slot = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"cp_s0", @"msl_type": @"device uint4*" },
        @{ @"kind": @"tex", @"arg_id": @1, @"msl_name": @"cp_t2d_cb0_40000000", @"msl_type": @"array<texture2d<float>, 32>" },
        @{ @"kind": @"?", @"arg_id": @33, @"msl_name": @"cp_s_cb0_40000000", @"msl_type": @"array<sampler, 32>" } ] };
    err[0] = 0; NvShader *old = shader(SLOT_SRC, refl_slot, err, sizeof err);
    if (old) { read4(old, 40u | 40u << 20, 0, 0, 0); }
    VERIFY(old && old->rf.dyn && near(out4[0], 0.0f), "⑧ 对照：同一句柄 40 经 32 项槽位数组 → %.2f（旧语义夹到槽 31、读占位 0.00，不是 40.50；%s）", old ? out4[0] : -1.0f, old ? "TEXD" : err);
    printf("%s t_nvn_pool_tex：%u 项，%u 项失败（追不到槽的句柄按编号读池：池表 + 已读位图 + 未写渲染目标不建 + 小贴图预建 + 表复用）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
