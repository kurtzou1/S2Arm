// S2Arm 内部分辨率的动作（状态与判定见 nvn_rscale.inc）：换存储（缩放 / 退回原尺寸）、开遍前定比例、待退回队列、片元支持缓冲的倍率副本、计算派发前的检查。
// 另有绘制 / 派发前的存储图像槽检查（rs_pre_draw / rs_pre_images）与覆盖面读数（rs_report）。
// 由 nvn_mtl.m 在 widen_glue.inc 之后 #include（要用回放层的 R / S / g_pass / arena_alloc 与宽屏胶水的 wd_tex_scales / g_wd_rs_gpu）。比例为 1 时每个入口第一句返回。
static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror);
static uint64_t g_rs_up, g_rs_down, g_rs_fail;   // 缩了 / 退回原尺寸 / 换存储失败的存储数（日志）
// 覆盖面读数（rs_report）：「不缩」与「退回原尺寸」按原因累计次数。原因是少数几个字符串常量，按内容认；满了并进最后一格「其它」。
//   回放线程记、游戏线程读（rs_report_line）：原因与次数在 g_rs_why_mu 里一起写、一起取快照。它是叶子锁（里面不再取别的锁），持 g_rmu 时可以取（同 rs_bad 的 g_rs_mu 方向）
enum { RS_WHYN = 16 };
typedef struct { const char *why; uint64_t n; } rs_why_t;
static rs_why_t g_rs_skip_why[RS_WHYN], g_rs_back_why[RS_WHYN]; static pthread_mutex_t g_rs_why_mu = PTHREAD_MUTEX_INITIALIZER;
static void rs_why_put(rs_why_t *tb, const char *why) {   // 调用方持 g_rs_why_mu
    if (!why) why = "?";
    int k = 0; while (k < RS_WHYN - 1 && tb[k].why && tb[k].why != why && strcmp(tb[k].why, why)) k++;
    if (k == RS_WHYN - 1 && tb[k].why && strcmp(tb[k].why, why)) why = "其它";
    tb[k].why = why; tb[k].n++;
}
static void rs_why_note(rs_why_t *tb, const char *why) { pthread_mutex_lock(&g_rs_why_mu); rs_why_put(tb, why); pthread_mutex_unlock(&g_rs_why_mu); }

// 把存储 base 换成按画布 × s（to_scaled）或画布原尺寸的新存储，内容用缩放拷贝带过去（Ryujinx SetScale：GetScaledHostTexture(copy) + ReplaceStorage），
//   所有表里指向旧存储的项换成新的（tex_swap_storage）。只在没有开着的渲染遍时调（copy_t2t_draw 自己收遍）。失败 = 旧存储不动、记成不缩（以后不再试）。返回新存储
// 失败时旧存储的记录跟着它的实际尺寸走（rs_rescale_failed）：没缩放过的记成不缩；已缩放、退不回原尺寸的保持已缩放的记录（画布尺寸还在，各处换算照旧对得上）。
//   原先一律记成不缩且画布清零：退回失败时存储仍是缩放尺寸、记录却说没缩放，之后的视口 / 拷贝 / 读回全按原尺寸算。
//   放大的方向另查设备贴图上限（rs_eligible 已挡在前面，这里是换存储这一处自己的底线：超过上限 Metal 直接断言退出）
static int g_rs_fail_test;   // 单测开关（t_nvn_rscale 第 22 组）：非 0 = 新存储当作建不出
static void rs_rescale_failed(id<MTLTexture> base, NvRsInfo *i) {
    pthread_mutex_lock(&g_rs_why_mu); g_rs_fail++; pthread_mutex_unlock(&g_rs_why_mu);   // 计数与 rs_report_line 的快照同一把锁
    if (!(i && i->state == RS_SCALED)) rs_set_info(base, RS_BLACK, 0, 0, 1.0);
    else i->fails++;   // 满 RS_FAIL_MAX 次不再试（rs_stuck）
}
// s = 新存储 ÷ 画布（1 = 退回原尺寸）。rs_rescale 的 to_scaled 取这份画布的缩放比例（rs_want），退回取 1；超上限缩建的附件定了一遍的比例时 rs_rts 直接给 s
static id<MTLTexture> rs_rescale_to(id<MTLTexture> base, double s, const char *why) {
    NvRsInfo *i = rs_info(base); int to_scaled = s != 1.0;
    NSUInteger cw = i && i->state == RS_SCALED ? i->cw : base.width, ch = i && i->state == RS_SCALED ? i->ch : base.height;
    NSUInteger w = to_scaled ? rs_up(cw, s) : cw, h = to_scaled ? rs_up(ch, s) : ch;
    if (!to_scaled && rs_stuck(base)) return nil;   // 退回失败满 RS_FAIL_MAX 次：不再建新存储
    if (w == base.width && h == base.height) { rs_set_info(base, to_scaled ? RS_SCALED : RS_BLACK, cw, ch, s); return base; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = base.textureType; d.pixelFormat = base.pixelFormat; d.width = w; d.height = h; d.depth = base.depth;
    d.arrayLength = base.arrayLength; d.mipmapLevelCount = base.mipmapLevelCount; d.sampleCount = base.sampleCount;
    d.storageMode = base.storageMode; d.cpuCacheMode = base.cpuCacheMode; d.hazardTrackingMode = base.hazardTrackingMode; d.resourceOptions = base.resourceOptions;
    // 新存储一定当渲染目标用（缩放拷贝画进去、之后游戏在上面画）：旧存储没有渲染目标用途时补上（打包贴图建时不带，copy_t2t_draw 见目标没有这一用途就画不了，
    //   11-09 #312 暗黑地牢2：1280x720 RG11B10Float 颜色目标「缩放拷贝画不了，不缩」，同遍深度却缩了）
    d.usage = base.usage | (mtl_fmt_block(base.pixelFormat) ? 0 : MTLTextureUsageRenderTarget);
    if ((s > 1.0 && (w > rs_tex_max() || h > rs_tex_max())) || w > rs_dev_max() || h > rs_dev_max()) {   // 放大超上限；或超上限缩建的存储要退回原尺寸（画布本身超上限）：都建不出（Metal 断言退出）
        RED_ONCE(189, "内部分辨率：%lux%lu 格式 %lu 的存储换成 %lux%lu 超过贴图上限 %lu，不换（%s）", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat, (unsigned long)w, (unsigned long)h, (unsigned long)(s > 1.0 ? rs_tex_max() : rs_dev_max()),
                 to_scaled ? "放大" : "超上限缩建的存储退不回原尺寸");
        rs_rescale_failed(base, i); return nil; }
    id<MTLTexture> n = g_rs_fail_test ? nil : [g_dev newTextureWithDescriptor:d];   // 单测开关
    if (!n) { RED_ONCE(114, "内部分辨率：%lux%lu 格式 %lu 的存储换成 %lux%lu 失败（建不出），不缩", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat, (unsigned long)w, (unsigned long)h);
        rs_rescale_failed(base, i); return nil; }   // 原为 g_rs_fail++ 加 rs_set_info(base, RS_BLACK, 0, 0)
    res_add(n);
    for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) {
        NVNcopyRegion sr = {0, 0, 0, (int)rs_mip(base.width, l), (int)rs_mip(base.height, l), (int)base.arrayLength};
        NVNcopyRegion dr = {0, 0, 0, (int)rs_mip(w, l), (int)rs_mip(h, l), (int)base.arrayLength};
        if (!copy_t2t_draw(base, n, (unsigned)l, 0, (unsigned)l, 0, &sr, &dr, 1, 0)) {
            RED_ONCE(115, "内部分辨率：%lux%lu 格式 %lu 的缩放拷贝画不了，不缩（首例）", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat);
            defer_obj_release(n); rs_rescale_failed(base, i); return nil; }   // 同上
    }
    rs_set_info(n, to_scaled ? RS_SCALED : RS_BLACK, cw, ch, s);
    tex_swap_storage(base, n);
    pthread_mutex_lock(&g_rs_why_mu);   // 覆盖面读数：份数与原因在同一把锁里一起加（rs_report_line 取快照用同一把）
    uint64_t k = to_scaled ? g_rs_up++ : g_rs_down++;
    if (!to_scaled) rs_why_put(g_rs_back_why, why);
    pthread_mutex_unlock(&g_rs_why_mu);
    if (k < 12 || !(k & (k - 1))) MLOG("内部分辨率：存储 %lux%lu 格式 %lu %s %lux%lu（第 %llu 份%s%s）", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat,
                                        !to_scaled ? "退回原尺寸" : s > 1.0 ? "放大到" : "缩到", (unsigned long)w, (unsigned long)h, (unsigned long long)k + 1, why ? "；" : "", why ? why : "");
    return n;
}
static id<MTLTexture> rs_rescale(id<MTLTexture> base, int to_scaled, const char *why) {
    if (!to_scaled) return rs_rescale_to(base, 1.0, why);
    NvRsInfo *i = rs_info(base); NSUInteger cw = i && i->state == RS_SCALED ? i->cw : base.width, ch = i && i->state == RS_SCALED ? i->ch : base.height;
    return rs_rescale_to(base, rs_want(cw, ch), why);
}

// 待退回队列：绑定时发现缩放图被不支持缩放的地方读写，下一个安全点（开遍前 rs_rts / 派发前 rs_pre_compute）换回原尺寸。根存储去重
enum { RS_BADQ = 64 };
static __strong id<MTLTexture> g_rs_bad[RS_BADQ]; static const char *g_rs_bad_why[RS_BADQ]; static int g_rs_nbad; static pthread_mutex_t g_rs_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_rs_badq = RS_BADQ, g_rs_bad_drop;   // 队列容量（≤ RS_BADQ；单测调小）；队列满、有存储没进队（g_rs_mu 里写，rs_bad_dropped 读后清）
static void rs_bad(id<MTLTexture> t, const char *why) {
    if (!t || !rs_on()) return;
    id<MTLTexture> r = rs_root(t);
    if (rs_state(r) != RS_SCALED) return;
    pthread_mutex_lock(&g_rs_mu);
    int k = 0; while (k < g_rs_nbad && g_rs_bad[k] != r) k++;
    if (k == g_rs_nbad && g_rs_nbad < g_rs_badq) { g_rs_bad[g_rs_nbad] = r; g_rs_bad_why[g_rs_nbad++] = why; }   // 容量走 g_rs_badq
    else if (k == g_rs_nbad) g_rs_bad_drop = 1;   // 满了没进队：rs_pre_draw / rs_pre_images 清完队列再扫一遍
    pthread_mutex_unlock(&g_rs_mu);
}
static int rs_bad_dropped(void) { pthread_mutex_lock(&g_rs_mu); int d = g_rs_bad_drop; g_rs_bad_drop = 0; pthread_mutex_unlock(&g_rs_mu); return d; }
static void rs_flush(void) {
    if (!rs_on() || !g_rs_nbad) return;
    __strong id<MTLTexture> q[RS_BADQ]; const char *w[RS_BADQ]; int n;
    pthread_mutex_lock(&g_rs_mu); n = g_rs_nbad; for (int k = 0; k < n; k++) { q[k] = g_rs_bad[k]; w[k] = g_rs_bad_why[k]; g_rs_bad[k] = nil; } g_rs_nbad = 0; pthread_mutex_unlock(&g_rs_mu);
    for (int k = 0; k < n; k++) if (rs_state(q[k]) == RS_SCALED) rs_rescale(q[k], 0, w[k]);
}

// 开遍前（rp_begin_ex_，宽屏放宽之后）：本遍颜色 / 深度目标定比例。都可缩（或已缩）→ 没缩的缩；有一个不可缩 / 被拉黑 → 已缩的退回、没定的记不缩（Ryujinx：黑名单在目标间传播）
static void rs_note_skip(const tex_t *t, const char *why) {
    rs_why_note(g_rs_skip_why, why);   // 覆盖面读数（下面的日志只打前 16 条）
    static int n; if (n++ < 16) MLOG("内部分辨率：渲染目标 ser=%llu %ux%u 格式 %#x 标志 %#x 不缩（%s）", (unsigned long long)t->serial, t->d.width, t->d.height, t->d.format, t->d.flags, why ? why : "?");
}
static double rs_fit_tex(const tex_t *t);   // nvn_mtl.m（超上限缩建的比例）
static void rs_rts(void) {
    if (!rs_on()) {   // 还没有缩放存储：本遍附件里有要超上限缩建、还没建的（第一次开遍时才建），照样往下走，同遍附件跟它的比例
        int any = 0; for (int i = 0; i < R.rt.n && i < 8 && !any; i++) any = R.rt.color[i] && rs_fit_tex(R.rt.color[i]) != 1.0;
        if (!any && !(R.rt.depth && rs_fit_tex(R.rt.depth) != 1.0)) return;
    }
    rs_flush();
    const tex_t *ts[9]; int n = 0, block = 0;
    for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i]) ts[n++] = R.rt.color[i];
    if (R.rt.depth) ts[n++] = R.rt.depth;
    // 本遍有超上限缩建的附件（rs_pinned：退不回原尺寸）：它的比例就是本遍的比例，别的附件不论可不可缩、拉没拉黑都换到这个比例
    //   （同一遍附件存储比例必须一致，视口 / 裁剪按一个比例换算）。几份超上限的比例不同时取最小的，另几份也换过去
    { double pin = 0;
      for (int k = 0; k < n; k++) { id<MTLTexture> b = tex_mtl(ts[k]); if (b && rs_pinned(b)) { double s = rs_of(b); pin = pin > 0 ? MIN(pin, s) : s; } }
      if (pin > 0) {
          for (int k = 0; k < n; k++) {
              id<MTLTexture> b = tex_mtl(ts[k]);
              if (!b || (rs_state(b) == RS_SCALED && rs_of(b) == pin)) continue;
              if (!rs_rescale_to(b, pin, "同一遍有超贴图上限缩建的附件"))
                  RED_ONCE(111, "内部分辨率：渲染目标 ser=%llu %ux%u 格式 %#x 换不到同遍超上限附件的比例 %.4f：本遍附件尺寸不一，这一遍画面会错位", (unsigned long long)ts[k]->serial, ts[k]->d.width, ts[k]->d.height, ts[k]->d.format, pin);
          }
          return;
      }
    }
    if (!rs_scaling()) return;   // 只有超上限缩建、没设定比例：别的遍不定比例
    for (int k = 0; k < n; k++) {
        id<MTLTexture> b = tex_mtl(ts[k]); int st = rs_state(b);
        if (!b) continue;
        if (st == RS_BLACK) block = 1;
        else if (st == RS_NONE) { const char *why = NULL; if (!rs_eligible(ts[k], b, &why)) { rs_set_info(b, RS_BLACK, 0, 0, 1.0); rs_note_skip(ts[k], why); block = 1; } }
    }
    for (int k = 0; k < n; k++) {
        id<MTLTexture> b = tex_mtl(ts[k]); int st = rs_state(b);
        if (!b) continue;
        if (block) { if (st == RS_SCALED) rs_rescale(b, 0, "同一遍有不缩的附件"); else if (st == RS_NONE) { rs_set_info(b, RS_BLACK, 0, 0, 1.0); rs_why_note(g_rs_skip_why, "同一遍有不缩的附件"); } }   // 覆盖面读数（自己可缩、被同遍附件带成不缩的也计）
        else if (st == RS_NONE && !rs_rescale(b, 1, NULL)) block = 1;   // 换存储失败（rs_rescale 已把它记成不缩）
    }
    // 同一遍里有附件没缩成：已缩的附件退回原尺寸，同一遍的附件尺寸必须一致（11-09 #312：颜色目标缩放拷贝失败、深度照样缩到一半，同遍尺寸不一，iPhone 上闪粉色块）
    if (block) for (int k = 0; k < n; k++) {
        id<MTLTexture> b = tex_mtl(ts[k]); int st = rs_state(b);
        if (!b) continue;
        if (st == RS_SCALED) rs_rescale(b, 0, "同一遍有附件没缩成"); else if (st == RS_NONE) { rs_set_info(b, RS_BLACK, 0, 0, 1.0); rs_why_note(g_rs_skip_why, "同一遍有附件没缩成"); }   // 覆盖面读数
    }
}

// 放大时，已放大的图拷进一张还没定比例的窗口贴图（游戏用拷贝把场景交给窗口贴图、窗口贴图从不当渲染目标的那条路）：窗口贴图先放大，
//   拷贝两边同比例、放大的像素原样带过去（Ryujinx TwodClass：目标用 srcTexture.ScaleMode == Scaled 当 preferScaling 建）。只管带上屏标志的目标：
//   其它目标照旧在第一次当渲染目标时定比例。copy_t2t 开头调（此处可以换存储：同一函数里解析目标的退回也在这里做）。不可放大的不记成不缩，留给 rs_rts 定
static void rs_copy_up(const tex_t *src, const tex_t *dst) {
    if (!rs_up_on() || !src || !dst || !(dst->d.flags & NVN_TEXTURE_FLAGS_DISPLAY)) return;
    id<MTLTexture> s = tex_mtl(src), d = tex_mtl(dst);
    if (!s || !d || rs_state(s) != RS_SCALED || rs_state(d) != RS_NONE || !rs_eligible(dst, d, NULL)) return;
    rs_rescale(d, 1, NULL);
}
// 片元阶段的支持缓冲（encode_args_ NVN_RB_SUPPORT；调用时已持 g_rmu，所以用 wd_tex_scales_locked——10-30 真机：调加锁版在同一线程上自锁，缩放局第一笔精确着色器的绘制就卡死）：片元坐标倍率 = 宽屏核心给的 × 本遍比例；取图 / 尺寸查询倍率 = 所绑贴图「存储 ÷ 游戏」两轴（wd_tex_scales：宽屏 k 与 s 自然相乘），
//   只在着色器精确（scale_exact 且清单没截断）时写。都是 1 = 照旧（宽屏的副本或静态那份），不另起副本
// cpu（可空）：同时给出这份支持缓冲的 CPU 字节（ABI2 尺寸表 size_abi_begin 以它为底，内部分辨率下片元倍率不丢）
static uint64_t rs_support_cpu(const NvShader *fs, const uint8_t **cpu) {
    uint64_t wd = g_wd > 0 && g_wd_rs_gpu ? g_wd_rs_gpu : 0;
    float f0 = wd ? g_wd_fsc : 1.0f, fy0 = wd ? g_wd_fsyc : 1.0f, f = (float)(f0 * g_pass.rs), fy = (float)(fy0 * g_pass.rs);
    uint8_t ix[72]; float v[72], vy[72]; int n = fs && fs->exact == 1 && !fs->ts_lost ? wd_tex_scales_locked(fs, f, ix, v, fy, vy) : 0;
    int any = f != f0 || fy != fy0; for (int i = 0; i < n; i++) any |= v[i] != 1.0f || vy[i] != 1.0f;
    if (!any) { if (cpu) *cpu = wd ? g_wd_rs_data : support_buf().contents; return wd ? wd : support_gpu(); }
    static uint64_t last_gpu, last_sub; static const uint8_t *last_data; static float lf, lfy, lv[72], lvy[72]; static uint8_t lix[72]; static int ln;
    if (!(last_gpu && last_sub == g_arena_gen && lf == f && lfy == fy && ln == n && !memcmp(lix, ix, (size_t)n) && !memcmp(lv, v, sizeof *v * (size_t)n) && !memcmp(lvy, vy, sizeof *vy * (size_t)n))) {
        id<MTLBuffer> ab; size_t o = arena_alloc(4096, &ab); uint8_t *d = (uint8_t *)ab.contents + o;
        memcpy(d, support_buf().contents, 4096); memcpy(d + 192, &f, 4); memcpy(d + 1440, &fy, 4);   // render_scale[i] 在 192 + 16 i、render_scale_y[i] 在 1440 + 16 i（取 .x），同 wd_rscale
        for (int i = 0; i < n; i++) { memcpy(d + 192 + 16 * ix[i], &v[i], 4); memcpy(d + 1440 + 16 * ix[i], &vy[i], 4); }
        last_gpu = ab.gpuAddress + o; last_data = d; last_sub = g_arena_gen; lf = f; lfy = fy; ln = n; memcpy(lix, ix, (size_t)n); memcpy(lv, v, sizeof *v * (size_t)n); memcpy(lvy, vy, sizeof *vy * (size_t)n);
    }
    if (cpu) *cpu = last_data;
    return last_gpu;
}
static uint64_t rs_support(const NvShader *fs) { return rs_support_cpu(fs, NULL); }
// 还没缩过的贴图被存储图像槽绑上：记成不缩，以后当渲染目标也不缩（Ryujinx BlacklistScale 不看当前比例；缩小了再退回会把图像里的内容糊掉）。
//   只把带可压缩标志的（渲染目标候选）计进「不缩」读数。调用方持 g_rmu
static void rs_image_first(int tid, id<MTLTexture> t) {
    if (g_treg[tid].t.d.flags & NVN_TEXTURE_FLAGS_COMPRESSIBLE) rs_why_note(g_rs_skip_why, "先当存储图像用");
    rs_set_info(t, RS_BLACK, 0, 0, 1.0);
}
// 计算着色器读缩放图（11-22 D-ZR6V：Mac 2 倍局主场景的深度被计算阶段读、整遍退回原尺寸，2 倍看不出）：同 Ryujinx（取图倍率片元与计算两个阶段都支持），
//   ABI2 尺寸表精确的计算程序（size_exact，清单没截断）照常读缩放图——整数取图坐标与尺寸查询按尺寸表里这张图的「游戏 ÷ 存储」换算（nvn_size_abi.inc size_abi_texture，
//   计算阶段同样逐绑定填表），普通取图本来与尺寸无关。只放行按槽号绑的贴图（NVN_RB_TEX）：尺寸表只认它，经统一缓冲句柄取的（TEXU）照旧退回。
//   存储图像槽不在此列：读写图像的仍在派发前换回原尺寸（rs_pre_images），写的图像坐标因此不用换算（翻译器 ABI2 判定不再因写图像判不精确）
//   张量核网络顶替（tensor == 1，nvn_tensor.inc）不在此列：它不派发、按游戏尺寸的有效区域读写，读的放大图照旧先退回
static inline int rs_compute_ok(const NvShader *sh) { return sh && sh->size_abi && sh->size_exact && !sh->ts_lost && sh->tensor != 1; }
// 绑定时：这张图在这里读写不支持缩放（顶点等非片元阶段、尺寸表不精确的计算着色器、不精确的片元着色器、句柄数组、存储图像槽）→ 记进待退回（只对已缩的起作用）
//   kind：0 = 按槽号绑的贴图，3 = 经统一缓冲句柄取的贴图（TEXU），1 = 句柄数组，2 = 存储图像槽
static inline void rs_bind_check(id<MTLTexture> t, const NvShader *sh, int nvn_stage, int kind) {
    if (!t || !rs_on()) return;
    if (kind == 2) rs_bad(t, "绑在存储图像槽");
    else if (kind == 1) rs_bad(t, "被句柄数组读");
    else if (nvn_stage == 5 && (kind != 0 || !rs_compute_ok(sh))) rs_bad(t, "被计算阶段读（尺寸表不精确 / 句柄取图）");
    else if (nvn_stage != 1 && nvn_stage != 5) rs_bad(t, "被顶点 / 几何等非片元阶段读");
    // 二维存储被当成立方体 / 3D 等非二维视图读：着色器对非二维访问一律按原尺寸（不缩放，rs_never 的放行也以此为前提，SpirvFetchScale NeverScaled），缩过的存储在这里退回
    else if (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DArray && t.textureType != MTLTextureType2DMultisample) rs_bad(t, "被非二维视图读");
    else if (nvn_stage == 1 && (sh->exact != 1 || sh->ts_lost || (sh->size_abi && !sh->size_exact && !sh->rs_never))) rs_bad(t, "被取图倍率不精确的片元着色器读");   // ABI2 非 exact（legacy_1x）同不精确；只因读宿主从不缩放的种类而 legacy_1x 的（rs_never）照旧走取图倍率
}
// 计算派发前（dispatch，此时没有开着的遍）：这次派发要读写的缩放图当场换回原尺寸，这次派发就读到对的（绑定时的检查只能等下一个安全点）。
//   尺寸表精确的计算程序（rs_compute_ok）按槽号读的贴图不换（同 rs_bind_check）；图像槽、句柄取图照换
static void rs_pre_compute(NvShader *sh) {
    if (!rs_on() || !sh) return;
    int read_ok = rs_compute_ok(sh);
    __strong id<MTLTexture> q[32]; int n = 0;
    os_unfair_lock_lock(&g_rmu);
    for (int i = 0; i < sh->rf.nb && n < 32; i++) {
        const nvn_rbind *b = &sh->rf.b[i]; int reg = b->reg, tid = 0;
        if (b->kind == NVN_RB_TEX) { if (read_ok) continue; tid = (int)(tex_slot_h(S.tex[5], S.img[5], reg) & 0xfffff); }
        else if (b->kind == NVN_RB_TEXU) tid = b->n ? ubo_tex_id(ubo_handle(5, reg, b->off)) : ubo_tex_id(ubo_packed(5, b));
        else if (b->kind == NVN_RB_IMG || b->kind == NVN_RB_IMGU) tid = img_tid(b, 5);
        else continue;
        void *tv = NULL; if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) tex_fast_rid(tid, &tv);
        id<MTLTexture> t = (__bridge id<MTLTexture>)tv;
        if (t && rs_state(t) == RS_SCALED) q[n++] = rs_root(t);
    }
    os_unfair_lock_unlock(&g_rmu);
    for (int k = 0; k < n; k++) if (rs_state(q[k]) == RS_SCALED) rs_rescale(q[k], 0, "计算派发读写");
    rs_flush();
}
// 存储图像槽上绑的贴图在用它的那次绘制 / 派发之前定成不缩——已缩的当场换回原尺寸，没缩过的记成不缩。
//   Ryujinx：CommitImageBindings → UpdateScale → BlacklistScale 在这次绘制之前同步做完，被拉黑的是当前渲染目标时 CommitBindings 再 UpdateRenderTargetState。
//   绑定时的 rs_bind_check 只能排到下一个安全点：图像读写用游戏坐标的整数纹素，这一遍里落在缩过的存储上位置全错（t_nvn_rscale 第 10 / 11 组）。
// 一个阶段的存储图像槽（调用方持 g_rmu）：已缩的进待退回队列（rs_bad 按根存储去重；返回 1 = 有），没缩过的记成不缩；wr（可空）置 1 = 这个阶段写其中的图像
// stuck 置 1 = 有退不回原尺寸的缩放图（退回失败满 RS_FAIL_MAX 次：不再排队，调用方报红）
static int rs_image_slots(const NvShader *sh, int st, int *wr, int *stuck) {
    int any = 0;
    for (int i = 0; i < sh->rf.nb; i++) {
        const nvn_rbind *b = &sh->rf.b[i]; if (b->kind != NVN_RB_IMG && b->kind != NVN_RB_IMGU) continue;
        int tid = img_tid(b, st); void *tv = NULL; if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) tex_fast_rid(tid, &tv);
        id<MTLTexture> t = (__bridge id<MTLTexture>)tv; if (!t) continue;
        if (wr && b->rw) *wr = 1;
        int state = rs_state(t);
        if (state == RS_SCALED && rs_stuck(t)) *stuck = 1;
        else if (state == RS_SCALED) { rs_bad(t, "绑在存储图像槽"); any = 1; } else if (state == RS_NONE) rs_image_first(tid, t);
    }
    return any;
}
// 这个阶段的存储图像槽里还有没有缩放图（只看、不排队；调用方持 g_rmu）：清完待退回队列后核一遍，还有 = 换存储失败
static int rs_image_scaled(const NvShader *sh, int st) {
    for (int i = 0; i < sh->rf.nb; i++) {
        const nvn_rbind *b = &sh->rf.b[i]; if (b->kind != NVN_RB_IMG && b->kind != NVN_RB_IMGU) continue;
        int tid = img_tid(b, st); void *tv = NULL; if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) tex_fast_rid(tid, &tv);
        if (tv && rs_state((__bridge id<MTLTexture>)tv) == RS_SCALED) return 1;
    }
    return 0;
}
#define RS_RED_IMG(what) RED_ONCE(191, "内部分辨率：存储图像槽上的缩放图退不回原尺寸（换存储失败），这次" what "的图像读写按游戏坐标落在缩放的存储上、位置不对，照旧进行")
static int rs_has_image(const NvShader *sh) { for (int i = 0; i < sh->rf.nb; i++) if (sh->rf.b[i].kind == NVN_RB_IMG || sh->rf.b[i].kind == NVN_RB_IMGU) return 1; return 0; }
// 队列装满时（RS_BADQ 份）rs_bad 不收新的：清完队列再扫，已退回的不再是已缩，剩下的这一遍进队，直到某一遍没有丢。每遍至少退回一份，RS_PRE_MAX 遍是防死循环的上限
enum { RS_PRE_MAX = 256 };
// 派发开头（dispatch()，在图像原子升级 img_atomic_prepare 与张量核网络顶替 tensor_standin 之前）：计算阶段的存储图像槽。
//   放在这两处之前：原子升级会把存储换成整数格式，之后缩放拷贝画不了、退不回原尺寸；顶替不走 rs_pre_compute，却按游戏尺寸的有效区域写输出图。
//   这里只管图像槽，读的贴图仍由 rs_pre_compute 管（顶替读的贴图不动）
static void rs_pre_images(const NvShader *cs) {
    if (!rs_on() || !cs || !rs_has_image(cs)) return;
    for (int it = 0; it < RS_PRE_MAX; it++) {
        (void)rs_bad_dropped();
        int stuck = 0;
        os_unfair_lock_lock(&g_rmu); int any = rs_image_slots(cs, 5, NULL, &stuck); os_unfair_lock_unlock(&g_rmu);
        if (!any) { if (stuck) RS_RED_IMG("派发"); return; }
        rp_end(); rs_flush();
        if (!rs_bad_dropped()) {   // 队列清完了：槽里还有缩放图 = 退回失败（rs_rescale 失败时存储仍是缩放尺寸），报红
            os_unfair_lock_lock(&g_rmu); int left = rs_image_scaled(cs, 5); os_unfair_lock_unlock(&g_rmu);
            if (left || stuck) RS_RED_IMG("派发");
            return; }
    }
    RED_ONCE(188, "内部分辨率：派发的存储图像槽扫了 %d 遍仍有缩放图没退回（待退回队列一直装满），这次派发照旧进行", RS_PRE_MAX);
}
// 绘制前（draw() 开头；这里收遍、换存储都排在这次绘制之前）：这次绘制的程序各阶段的存储图像槽。
//   片元阶段写存储图像（rw）的绘制，本遍附件也定成不缩：片元坐标按游戏坐标交给着色器，缩小的遍每个存储像素只对上一个游戏像素，按片元坐标写的图像会留洞。
//   图像就是本遍附件时不用另管：它已是不缩，重开遍时 rs_rts 把同遍其余附件一起退回
static void rs_pre_draw(const NvProg *pr) {
    if (!rs_on() || !pr) return;
    int has = 0;
    for (int st = 0; st < 5 && !has; st++) has = pr->sh[st] && rs_has_image(pr->sh[st]);
    if (!has) return;
    for (int it = 0; it < RS_PRE_MAX; it++) {
        int any = 0, fs_write = 0, stuck = 0;
        (void)rs_bad_dropped();
        os_unfair_lock_lock(&g_rmu);
        for (int st = 0; st < 5; st++) if (pr->sh[st]) any |= rs_image_slots(pr->sh[st], st, st == 1 ? &fs_write : NULL, &stuck);
        os_unfair_lock_unlock(&g_rmu);
        if (fs_write && R.has_rt) for (int i = 0; i < 9; i++) {
            const tex_t *a = i < 8 ? (i < R.rt.n ? R.rt.color[i] : NULL) : R.rt.depth; id<MTLTexture> b = a ? tex_mtl(a) : nil; int state = rs_state(b);
            if (state == RS_SCALED) { rs_bad(b, "同一遍有片元阶段写存储图像"); any = 1; }
            else if (b && state == RS_NONE) { rs_set_info(b, RS_BLACK, 0, 0, 1.0); rs_why_note(g_rs_skip_why, "同一遍有片元阶段写存储图像"); }
        }
        if (!any) { if (stuck) RS_RED_IMG("绘制"); return; }
        rp_end(); rs_flush();
        if (!rs_bad_dropped()) {   // 同 rs_pre_images
            int left = 0; os_unfair_lock_lock(&g_rmu); for (int st = 0; st < 5 && !left; st++) if (pr->sh[st]) left = rs_image_scaled(pr->sh[st], st); os_unfair_lock_unlock(&g_rmu);
            if (left || stuck) RS_RED_IMG("绘制");
            return; }
    }
    RED_ONCE(188, "内部分辨率：绘制的存储图像槽扫了 %d 遍仍有缩放图没退回（待退回队列一直装满），这次绘制照旧进行", RS_PRE_MAX);
}
// 覆盖面读数（nvn_be_mem_stat 每 300 帧调，在游戏线程的小栈上：只用整数格式、行缓冲放静态区）：到这一帧为止缩了 / 退回原尺寸 / 换存储失败各多少份，
//   「不缩」与「退回」按原因的累计次数。比例为 1 不打；数字没变不重复打
static size_t rs_report_why(char *line, size_t o, size_t cap, const rs_why_t *tb) {
    int any = 0;
    for (int k = 0; k < RS_WHYN && o < cap; k++) { const char *w = tb[k].why; uint64_t n = tb[k].n; if (!w || !n) continue;
        o += (size_t)snprintf(line + o, cap - o, "%s%s ×%llu", any ? "、" : "", w, (unsigned long long)n); any = 1; }
    if (!any && o < cap) o += (size_t)snprintf(line + o, cap - o, "无");
    return o < cap ? o : cap - 1;
}
// 拼这一行（rs_report 与单测 t_nvn_rscale 第 15 组调）：比例为 1 → 返回 0、不动 out；否则写进 out、返回 1。原因表在 g_rs_why_mu 里取快照，行与 sum 都出自这一份快照：
//   sum（可空）= 各计数之和，含两张原因表的次数（任何一项变了 rs_report 都会再打）。「换存储失败」份数也在这把锁里加（rs_rescale_failed）
static int rs_report_line(uint64_t frame, char *out, size_t cap, uint64_t *sum) {
    if (!rs_on() || cap < 2) return 0;
    rs_why_t skip[RS_WHYN], back[RS_WHYN];
    pthread_mutex_lock(&g_rs_why_mu); memcpy(skip, g_rs_skip_why, sizeof skip); memcpy(back, g_rs_back_why, sizeof back); uint64_t up = g_rs_up, down = g_rs_down, fail = g_rs_fail; pthread_mutex_unlock(&g_rs_why_mu);
    if (sum) { *sum = up + down + fail; for (int k = 0; k < RS_WHYN; k++) *sum += skip[k].n + back[k].n; }
    size_t o = (size_t)snprintf(out, cap, "内部分辨率：到第 %llu 帧 %s %llu / 退回原尺寸 %llu / 换存储失败 %llu 份；不缩（按原因）：", (unsigned long long)frame,
                                g_rs > 1.0 ? "放大了" : "缩了", (unsigned long long)up, (unsigned long long)down, (unsigned long long)fail);
    if (o > cap - 1) o = cap - 1;
    o = rs_report_why(out, o, cap, skip);
    if (o < cap - 1) o += (size_t)snprintf(out + o, cap - o, "；退回（按原因）：");
    if (o > cap - 1) o = cap - 1;
    rs_report_why(out, o, cap, back);
    return 1;
}
static void rs_report(uint64_t frame) {
    static uint64_t last = UINT64_MAX; static char line[1536]; uint64_t sum = 0;
    if (!rs_report_line(frame, line, sizeof line, &sum) || sum == last) return;
    last = sum; MLOG("%s", line);
}
