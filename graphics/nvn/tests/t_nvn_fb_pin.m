// 同遍反馈采样里，采样器钉住一级的绘制读那一级的单级视图（nvn_mtl.m fb_prepare ⓪ / fb_pinned_level；补齐上游参考实现（MIT）56e4577b 第二项）。
// Switch 语义：采样器的 LOD 下限 = 上限且是整数、带 mip 过滤时，每次取样都落在那一级，不管着色器要的 LOD；渲染第 n 级、同时采样同一张贴图时，
//   读的就是那一级的内容。上采样遍（第 n 级从 n + 1 级画）钉住 n + 1；原先 ① 只留 attachment 以下的级（0..n-1），读到更清晰的 n - 1 级
//   （上游症状：大金刚蕉力全开泛光链，开场霓虹字变粗变实）；渲染视图基级时 ① 根本不建视图，读到正在画的那一级本身。
// 期望（按上面的语义手写，不由被测实现推出），贴图 4x4 三级（4x4 / 2x2 / 1x1），绑定是同槽的组合句柄（TEX + SAMPT）：
//   ① 画第 1 级、钉第 2 级 → 一个视图，只含第 2 级
//   ② 画第 1 级、钉第 0 级 → 一个视图，只含第 0 级
//   ③ 画第 1 级、不钉（LOD -1000..1000）→ attachment 以下的级：第 0 级起 1 级
//   ④ 画第 1 级、LOD 2..2 但没有 mip 过滤（minf 1）→ 同 ③
//   ⑤ 画第 0 级、钉第 1 级 → 一个视图，只含第 1 级
//   ⑥ 画第 0 级、不钉 → 不换视图
//   ⑦ 同 ⑤，但贴图绑在 128 号槽（槽表 0–255 都是贴图；#839 一款动作游戏的 FXAA 从 128 号槽读自己正在写的场景图）→ 同样换成只含第 1 级的视图（修前 128 号以上不查，原地边读边写）
#ifndef NVN_PIN_SOURCE
#define NVN_PIN_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_PIN_SOURCE   // NVN_PIN_SOURCE：修前 / 负对照编同一份单测

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);   // replay's first entry initializes its state
        enum { POOL = 1 << 20, TID = 671, SID = 672 };
        uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, POOL)); memset(mem, 0, POOL);
        pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
        *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = POOL};
        nvn_be_pool_add(mem, POOL);
        static tex_t chain; memset(&chain, 0, sizeof chain); chain.magic = MAGIC('T', 'E', 'X', 0); chain.serial = nvn_new_serial();
        chain.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 4, .height = 4, .depth = 1, .levels = 3, .samples = 1};
        chain.pool = pool; chain.off = 0; chain.mem = mem; nvn_tex_layout(&chain.d, &chain.L); nvn_be_tex_init(&chain);
        nvn_be_sub_begin();
        id<MTLTexture> original = tex_mtl(&chain); REQUIRE(original && original.mipmapLevelCount == 3);
        nvn_be_reg_tex(TID, &chain, NULL);
        NvShader *fs = [NvShader new]; fs->stage = 1; strlcpy(fs->key, "bbbbbbbbbbbbbbbb_b", sizeof fs->key); fs->rf.pos_attr = -1;
        fs->rf.nb = 2; fs->rf.b = calloc(2, sizeof *fs->rf.b); REQUIRE(fs->rf.b);
        fs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 0, .dtt = MTLTextureType2D};
        fs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_SAMPT, .reg = 0, .aid = 1};
        NvProg *pr = [NvProg new]; pr->sh[1] = fs;
        state_reset(); S.tex[1][0] = TID | (uint64_t)SID << 20;
        struct { int level, minf; float lod_min, lod_max; int want_n, want_level, want_levels; const char *label; } c[] = {
            {1, 5, 2, 2, 1, 2, 1, "① 画第 1 级、钉第 2 级（上采样）：只含第 2 级"},
            {1, 5, 0, 0, 1, 0, 1, "② 画第 1 级、钉第 0 级：只含第 0 级"},
            {1, 5, -1000, 1000, 1, 0, 1, "③ 画第 1 级、不钉：attachment 以下的级"},
            {1, 1, 2, 2, 1, 0, 1, "④ 没有 mip 过滤：同 ③"},
            {0, 5, 1, 1, 1, 1, 1, "⑤ 画第 0 级、钉第 1 级：只含第 1 级"},
            {0, 5, -1000, 1000, 0, 0, 0, "⑥ 画第 0 级、不钉：不换视图"},
        };
        for (unsigned i = 0; i < sizeof c / sizeof *c; i++) {
            samp_par sp = {.minf = (uint32_t)c[i].minf, .magf = 1, .ws = 2, .wt = 2, .wr = 2, .lod_min = c[i].lod_min, .lod_max = c[i].lod_max, .aniso = 1};
            nvn_be_reg_samp(SID, &sp);
            memset(&R.rt, 0, sizeof R.rt); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &chain; R.rt.has_cview[0] = 1;
            R.rt.cview[0] = (view_t){.set_levels = 1, .base_level = (uint8_t)c[i].level, .nlevels = 1};
            fb_prepare(pr);
            id<MTLTexture> use = g_fb_n ? g_fb_use[0] : nil;
            CHECK(g_fb_n == c[i].want_n && (!c[i].want_n || (use.parentTexture == original && (int)use.parentRelativeLevel == c[i].want_level && (int)use.mipmapLevelCount == c[i].want_levels)),
                  "%s（换了 %d 个视图，第 %lu 级起 %lu 级）", c[i].label, g_fb_n, (unsigned long)use.parentRelativeLevel, (unsigned long)use.mipmapLevelCount);
            if (g_enc) rp_end();
        }
        {   // ⑦ 128 号槽
            fs->rf.b[0].reg = 128; fs->rf.b[1].reg = 128; state_reset(); S.tex[1][128] = TID | (uint64_t)SID << 20;
            samp_par sp = {.minf = 5, .magf = 1, .ws = 2, .wt = 2, .wr = 2, .lod_min = 1, .lod_max = 1, .aniso = 1}; nvn_be_reg_samp(SID, &sp);
            memset(&R.rt, 0, sizeof R.rt); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &chain; R.rt.has_cview[0] = 1;
            R.rt.cview[0] = (view_t){.set_levels = 1, .base_level = 0, .nlevels = 1};
            fb_prepare(pr);
            id<MTLTexture> use = g_fb_n ? g_fb_use[0] : nil;
            CHECK(g_fb_n == 1 && use.parentTexture == original && (int)use.parentRelativeLevel == 1 && (int)use.mipmapLevelCount == 1,
                  "⑦ 贴图在 128 号槽、画第 0 级、钉第 1 级：只含第 1 级（换了 %d 个视图）", g_fb_n);
            if (g_enc) rp_end();
        }
        uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
        printf("%s t_nvn_fb_pin: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
