// #1594：类型 3 句柄（贴图字在 c2 分离贴图表、采样器池下标是着色器里的立即数）的布局映射。
// 真实结果解析（nvn_vk_program_parse_graphics）+ 生产 layout_ent，不另写模型：
//   * 结果里的 constSampler 编成布局项 src_reg2 = NVN_GPU_SAMP2_CONST | 池下标，贴图槽 128 + k，来源 NVN_RB_TEX；
//   * 下标 0 / 4095 是真下标：不等于「没有」(UINT16_MAX)，也不等于采样器槽 0；
//   * 没有 constSampler 的条目（c2 采样器槽 / 取同字 / 组合槽）的 src_reg2 一字不变；
//   * UBO 句柄形态（tex_ubo）里的 FD_SAMP_ID 仍走 TEXU 项，不被误读成常量采样器。
// 片 3：贴图字在游戏 UBO 里的类型 3 句柄（平铺 uboSlot / uboOffset + constSampler）：布局项是 TEXU，采样器来源由生产 usrc_put 进程序的 usrc 表
//   （SAMPI + samp_pool = 1 = 立即数采样器池下标，回放要加池起点）；离线库写法的 {"source":"id"}（登记号原值，含 >= 0x8000 的号）samp_pool 仍为 0。
// 片 7：计算阶段（cs 贴图绑定的 c2 形态）走真实计算解析（nvn_vk_program_parse_compute）+ 同一个 layout_ent，布局项与图形侧一字不差；
//   cs 的 UBO 句柄形态仍具名拒绝。
#include "../native/gfx_plat/nvk_shader.c"
#include "tbuf_spirv_fixtures.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", what); fails++; } } while (0)

// 编码本身的性质：标记位在采样器槽范围（0..127）之外，与池下标位不重叠，且任何池下标都不会撞上「没有」(UINT16_MAX)。
_Static_assert(NVN_GPU_SAMP2_CONST >= 128, "const-sampler flag must sit outside the sampler slot range");
_Static_assert((NVN_GPU_SAMP2_CONST & NVN_GPU_SAMP2_ID_MASK) == 0, "flag and sampler id bits must not overlap");
_Static_assert((NVN_GPU_SAMP2_CONST | NVN_GPU_SAMP2_ID_MASK) != UINT16_MAX, "no sampler id may collide with 'no second source'");
_Static_assert(NVN_GPU_SAMP2_ID_MASK == 4095, "sampler id field is the 12 handle bits");

// 一条 fs 贴图绑定（fields 是 "count":1 之后的原文）→ 真实解析 → 生产布局映射。返回 1 = 解析并映射成功
//   pg 非空时，TEXU / TBUFU 项再经生产 usrc_put 把句柄来源放进程序的 usrc 表（布局项 src_reg2 = 表下标），和生产装载同一条路
static int map_json(const char *fields, nvn_gpu_layout_ent *e, struct rp_prog *pg, char *why, size_t cap) {
    char json[4096];
    int n = snprintf(json, sizeof json,
        "{\"schema\":\"s2a-direct-program-v2\",\"content\":{\"contract\":\"s2a-direct-program-content-v2\","
        "\"stages\":[{\"stage\":\"vs\",\"spirv\":\"%s\"},{\"stage\":\"fs\",\"spirv\":\"%s\"}],"
        "\"bindings\":[{\"stage\":\"fs\",\"kind\":\"texture\",\"set\":2,\"binding\":0,\"count\":1,%s}]}}",
        S2A_TEST_VERT_1, S2A_TEST_FRAG_1, fields);
    struct fd_program p;
    memset(&p, 0, sizeof p);
    memset(e, 0, sizeof *e);
    why[0] = 0;
    if (n <= 0 || (size_t)n >= sizeof json) return 0;
    int rc = nvn_vk_program_parse_graphics((const uint8_t *)json, (size_t)n, &p, why, cap);
    int ok = !rc && p.binding_count == 1 && layout_ent(&p.bindings[0], e);
    if (ok && pg && (e->src_kind == NVN_RB_TEXU || e->src_kind == NVN_RB_TBUFU)) ok = usrc_put(pg, &p.bindings[0], e);
    nvn_vk_program_free(&p);
    return ok;
}
static int map_one(const char *fields, nvn_gpu_layout_ent *e, char *why, size_t cap) { return map_json(fields, e, NULL, why, cap); }

// 片 7：同一条 cs 贴图绑定走真实计算解析（nvn_vk_program_parse_compute）+ 同一个生产 layout_ent。返回 1 = 解析并映射成功
static int map_cs(const char *fields, nvn_gpu_layout_ent *e, char *why, size_t cap) {
    char json[4096];
    int n = snprintf(json, sizeof json,
        "{\"schema\":\"s2a-direct-program-v2\",\"content\":{\"contract\":\"s2a-direct-program-content-v2\",\"kind\":\"compute\","
        "\"hasUnalignedStorageBuffer\":false,\"c0Reads\":[],\"stages\":[{\"stage\":\"cs\",\"spirv\":\"%s\"}],"
        "\"bindings\":[{\"stage\":\"cs\",\"kind\":\"texture\",\"set\":2,\"binding\":0,\"count\":1,%s}],"
        "\"supportLayout\":{\"requiredSize\":2608},\"supportReads\":[]}}", S2A_TEST_COMP_1, fields);
    struct nvn_vk_compute_program p;
    memset(&p, 0, sizeof p);
    memset(e, 0, sizeof *e);
    why[0] = 0;
    if (n <= 0 || (size_t)n >= sizeof json) return 0;
    int rc = nvn_vk_program_parse_compute((const uint8_t *)json, (size_t)n, &p, why, cap);
    int ok = !rc && p.binding_count == 1 && layout_ent(&p.bindings[0], e);
    nvn_vk_program_free_compute(&p);
    return ok;
}

int main(void) {
    nvn_gpu_layout_ent e;
    char why[192];

    static const struct { int slot, sampler, tex; } cs[] = {{90, 257, 128}, {92, 0, 129}, {124, 1, 145}, {344, 4095, 255}};
    for (unsigned k = 0; k < sizeof cs / sizeof cs[0]; k++) {
        char f[96], what[320];
        snprintf(f, sizeof f, "\"slot\":%d,\"constSampler\":%d", cs[k].slot, cs[k].sampler);
        int ok = map_one(f, &e, why, sizeof why);
        snprintf(what, sizeof what, "constant sampler %d (slot %d) maps to TEX %d + flagged src_reg2 (why=%s)", cs[k].sampler, cs[k].slot, cs[k].tex, why);
        CHECK(ok && e.cls == NVN_GPU_RES_TEX_SAMP && e.src_kind == NVN_RB_TEX && e.src_reg == cs[k].tex && e.count == 1 &&
              e.src_reg2 == (uint16_t)(NVN_GPU_SAMP2_CONST | (unsigned)cs[k].sampler), what);
        snprintf(what, sizeof what, "constant sampler %d is neither 'none' nor a sampler slot (src_reg2=%#x)", cs[k].sampler, (unsigned)e.src_reg2);
        CHECK(ok && e.src_reg2 != UINT16_MAX && (e.src_reg2 & NVN_GPU_SAMP2_CONST) && e.src_reg2 >= 128, what);
    }

    // 片 7：计算阶段同一份合同——真实计算解析 + 同一个 layout_ent，布局项与图形侧一字不差（回放派发按这个 src_reg2 取采样器）
    for (unsigned k = 0; k < sizeof cs / sizeof cs[0]; k++) {
        char f[96], what[320];
        snprintf(f, sizeof f, "\"slot\":%d,\"constSampler\":%d", cs[k].slot, cs[k].sampler);
        int ok = map_cs(f, &e, why, sizeof why);
        snprintf(what, sizeof what, "compute constant sampler %d (slot %d) maps to TEX %d + flagged src_reg2 (why=%s)", cs[k].sampler, cs[k].slot, cs[k].tex, why);
        CHECK(ok && e.cls == NVN_GPU_RES_TEX_SAMP && e.src_kind == NVN_RB_TEX && e.src_reg == cs[k].tex && e.count == 1 &&
              e.src_reg2 == (uint16_t)(NVN_GPU_SAMP2_CONST | (unsigned)cs[k].sampler), what);
    }
    CHECK(map_cs("\"slot\":90,\"samp_slot\":3", &e, why, sizeof why) && e.src_kind == NVN_RB_TEX && e.src_reg == 128 && e.src_reg2 == 3,
          "compute samp_slot form keeps the sampler slot as src_reg2");
    CHECK(map_cs("\"slot\":90", &e, why, sizeof why) && e.src_kind == NVN_RB_TEX && e.src_reg == 128 && e.src_reg2 == UINT16_MAX,
          "compute direct separate texture keeps 'no second source'");
    CHECK(!map_cs("\"slot\":90,\"uboSlot\":1,\"uboOffset\":1024,\"constSampler\":7", &e, why, sizeof why) && strstr(why, "constant sampler"),
          "compute UBO-handle constant sampler stays rejected by name");

    // 没有 constSampler 的条目：src_reg2 不变
    CHECK(map_one("\"slot\":90,\"samp_slot\":3", &e, why, sizeof why) && e.src_kind == NVN_RB_TEX && e.src_reg == 128 && e.src_reg2 == 3,
          "samp_slot form keeps the sampler slot as src_reg2");
    CHECK(map_one("\"slot\":90,\"samp_slot\":127", &e, why, sizeof why) && e.src_reg2 == 127 && !(e.src_reg2 & NVN_GPU_SAMP2_CONST),
          "the largest sampler slot is not mistaken for the const-sampler flag");
    CHECK(map_one("\"slot\":90", &e, why, sizeof why) && e.src_kind == NVN_RB_TEX && e.src_reg == 128 && e.src_reg2 == UINT16_MAX,
          "direct separate texture (sampler from the same word) keeps 'no second source'");
    CHECK(map_one("\"slot\":8", &e, why, sizeof why) && e.src_kind == NVN_RB_TEX && e.src_reg == 0 && e.src_reg2 == UINT16_MAX,
          "combined texture slot keeps 'no second source'");

    // UBO 句柄形态：FD_SAMP_UBO 仍走 TEXU；手搭 FD_SAMP_ID + tex_ubo 也不被读成常量采样器
    CHECK(map_one("\"uboSlot\":1,\"uboOffset\":1024", &e, why, sizeof why) && e.src_kind == NVN_RB_TEXU && e.src_reg2 == UINT16_MAX,
          "uboSlot texture keeps the TEXU layout entry");
    {
        struct fd_binding b; memset(&b, 0, sizeof b);
        b.kind = 2; b.count = 1; b.tex_slot = -1; b.samp_slot = -1; b.tex_ubo = 1; b.samp_src = FD_SAMP_ID; b.samp_val = 257;
        b.tex_u.slot = 1; b.tex_u.offset = 1024;
        CHECK(layout_ent(&b, &e) && e.src_kind == NVN_RB_TEXU && e.src_reg2 == UINT16_MAX, "a UBO-handle texture with a sampler id stays a TEXU entry");
    }
    // 解析器保证 0..4095；手搭的越界值不截断成别的下标，整项当作不支持
    {
        struct fd_binding b; memset(&b, 0, sizeof b);
        b.kind = 2; b.count = 1; b.tex_slot = 128; b.samp_slot = -1; b.samp_src = FD_SAMP_ID; b.samp_val = 4096;
        CHECK(!layout_ent(&b, &e), "a sampler id above 4095 is not truncated into another index");
        b.samp_val = 4095;
        CHECK(layout_ent(&b, &e) && e.src_reg2 == (uint16_t)(NVN_GPU_SAMP2_CONST | 4095u), "the largest sampler id maps");
    }

    // 片 3：贴图字在游戏 UBO + constSampler。布局项仍是 TEXU（src_reg / src_off = 贴图字所在的 UBO 号 / 字节偏移），src_reg2 是 usrc 表下标；
    //   采样器来源在表项里：SAMPI + 池下标 + samp_pool = 1。下标 0 / 4095 是真下标。
    {
        static const struct { int ubo, off, sampler; } ub[] = {{2, 160, 260}, {0, 0, 0}, {15, 65532, 4095}};
        for (unsigned k = 0; k < sizeof ub / sizeof ub[0]; k++) {
            struct rp_prog pg; memset(&pg, 0, sizeof pg);
            char f[128], what[320];
            snprintf(f, sizeof f, "\"uboSlot\":%d,\"uboOffset\":%d,\"constSampler\":%d", ub[k].ubo, ub[k].off, ub[k].sampler);
            int ok = map_json(f, &e, &pg, why, sizeof why);
            snprintf(what, sizeof what, "UBO %d +%d with constant sampler %d maps to a TEXU entry + usrc[0] (why=%s)", ub[k].ubo, ub[k].off, ub[k].sampler, why);
            CHECK(ok && e.cls == NVN_GPU_RES_TEX_SAMP && e.src_kind == NVN_RB_TEXU && e.src_reg == ub[k].ubo && (int)e.src_off == ub[k].off && e.count == 1 &&
                  e.src_reg2 == 0 && pg.nusrc == 1, what);
            const struct rp_usrc *u = &pg.usrc[0];
            snprintf(what, sizeof what, "usrc[0]: texture word at UBO %d +%d, sampler = immediate pool index %d (SAMPI, samp_pool 1)", ub[k].ubo, ub[k].off, ub[k].sampler);
            CHECK(u->tex.reg == ub[k].ubo && u->tex.off == ub[k].off && !u->tex.sid && !u->tex.pair &&
                  u->samp_kind == NVN_RB_SAMPI && u->samp_reg == ub[k].sampler && u->samp_pool == 1, what);
        }
        // 同一个程序里两条：各取各的表项，src_reg2 = 各自的表下标
        struct rp_prog two; memset(&two, 0, sizeof two);
        nvn_gpu_layout_ent e0, e1;
        CHECK(map_json("\"uboSlot\":2,\"uboOffset\":160,\"constSampler\":260", &e0, &two, why, sizeof why) &&
              map_json("\"uboSlot\":3,\"uboOffset\":160,\"constSampler\":262", &e1, &two, why, sizeof why) &&
              e0.src_reg2 == 0 && e1.src_reg2 == 1 && two.nusrc == 2 && two.usrc[0].samp_reg == 260 && two.usrc[1].samp_reg == 262 &&
              two.usrc[0].tex.reg == 2 && two.usrc[1].tex.reg == 3, "two constant-sampler UBO textures keep their own usrc entries");
    }
    // 对照：别的来源的 usrc 表项不带池下标标记（口径不混）
    {
        struct rp_prog pg; memset(&pg, 0, sizeof pg);
        CHECK(map_json("\"uboHandle\":{\"slot\":1,\"offset\":1024},\"sampler\":{\"source\":\"id\",\"id\":257}", &e, &pg, why, sizeof why) &&
              e.src_kind == NVN_RB_TEXU && pg.usrc[0].samp_kind == NVN_RB_SAMPI && pg.usrc[0].samp_reg == 257 && pg.usrc[0].samp_pool == 0,
              "a library-style sampler id keeps the raw registered id (SAMPI, samp_pool 0)");
        // 登记号不受 12 位限制：>= 0x8000 的号照旧是原值（采样器池下标的标记是单独的 samp_pool，不占 samp_reg 的位）
        memset(&pg, 0, sizeof pg);
        CHECK(map_json("\"uboHandle\":{\"slot\":1,\"offset\":1024},\"sampler\":{\"source\":\"id\",\"id\":40000}", &e, &pg, why, sizeof why) &&
              pg.usrc[0].samp_kind == NVN_RB_SAMPI && pg.usrc[0].samp_reg == 40000 && pg.usrc[0].samp_pool == 0,
              "a registered id above 0x7FFF is not mistaken for a pool index");
        memset(&pg, 0, sizeof pg);
        CHECK(map_json("\"uboSlot\":1,\"uboOffset\":1024", &e, &pg, why, sizeof why) &&
              pg.usrc[0].samp_kind == NVN_RB_SAMPU && pg.usrc[0].samp_pool == 0, "a flat UBO texture without constSampler keeps 'sampler from the same word' (SAMPU)");
    }

    if (fails) { fprintf(stderr, "const-sampler layout: %d FAILED\n", fails); return 1; }
    puts("PASS: const-sampler layout (real parse + production layout_ent)");
    return 0;
}
