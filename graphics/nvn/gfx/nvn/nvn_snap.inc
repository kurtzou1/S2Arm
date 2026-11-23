#include "../../../../runtime/src/snapfmt.h"
// 即时存档（苹果端缺省开、S2A_SNAP_MODE=0 关，见 runtime/src/snapsw.c；恢复局 S2A_SNAP_RESTORE）：直连图形层的实时状态存 / 取。nvn_mtl.m 末尾包含（读回放层的静态表），复用帧录的存取函数（nvn_frame_rec.inc）。
//   存：冻结后（游戏线程全停在门里）排空 GPU，存回放层表（state / 程序键 / 虚拟池）、命令记录宿主块（命令记录区固定地址，S2A_CMD_ARENA=1）、栅栏与出图序号计数器。
//   取：新进程正常起好图形层（游戏线程未起）、游戏内存已写回之后调；首版不写回 GPU 私有贴图（渲染目标靠游戏下一帧重画，开头几帧时间累积效果会有瑕疵）
uint64_t nvn_serial_now(void);   // hle_nvn.c
void s2a_snap_arena_get(uint64_t *base, uint64_t *used, uint64_t *vused) __attribute__((weak));   // runtime/src/vawin.c
void s2a_snap_arena_set(uint64_t used, uint64_t vused) __attribute__((weak));
static int (*nvn2_snap_codec_save)(FILE *f), (*nvn2_snap_codec_restore)(FILE *f);   // nvn2_codec.c 开局时登记进来（不直接引用：图形单测不链视频解码模块和它要的宿主符号）
void nvn_snap_codec_register(int (*save)(FILE *), int (*restore)(FILE *)) { nvn2_snap_codec_save = save; nvn2_snap_codec_restore = restore; }
void s2a_gl_first_use(void) __attribute__((weak));
int hle_snap_save(FILE *f); int hle_snap_restore(FILE *f); int hle_snap_ft_restore(const void *(*lookup)(uint64_t ser));   // hle_nvn.c
int nvn2_snap_gs_save(FILE *f) __attribute__((weak)); int nvn2_snap_gs_restore(FILE *f) __attribute__((weak));   // nvn2.c   // host_adapt.m：着色器库路径（正常局在游戏第一次进 NVN 时定）
typedef struct { uint32_t magic, ver; uint64_t fence, done, pq_in, pq_done, pq_read, serial, frame, ca_base, ca_used, va_used; } nvn_snap_live;

// 预排布资产贴图（NvPkg）：全部存显卡内容（一款游戏 531 张 95 MB）。只存 GPU 写过的不够：载入时 GPU 拷贝写进去的、稀疏池里的，内容都只在显卡里
static void snap_up_sync(void);
static int snap_dump_tex(FILE *f, uint64_t ser, id<MTLTexture> t, uint64_t *bytes) {
    fr_tex_hd hd = {ser, (uint32_t)t.textureType, (uint32_t)t.pixelFormat, (uint32_t)t.width, (uint32_t)t.height, (uint32_t)t.depth, (uint32_t)fr_slices(t), (uint32_t)t.mipmapLevelCount, FR_TK_PLAIN, (uint32_t)t.sampleCount};
    if (t.sampleCount > 1) return 0;
    hd.nplane = (uint32_t)fr_planes(t.pixelFormat, hd.pl); if (!hd.nplane) return 0;
    uint64_t tot = 0;
    for (uint32_t q = 0; q < hd.nplane; q++) for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) tot += fr_plane_bytes(&hd.pl[q], MAX(1, t.width >> l), MAX(1, t.height >> l), MAX(1, t.depth >> l)) * hd.layers;
    if (!tot || tot > (256ull << 20)) return 0;
    id<MTLBuffer> b = [g_dev newBufferWithLength:tot options:MTLResourceStorageModeShared]; if (!b || !fr_blit_planes(t, &hd, b, 1)) return 0;
    if (!fr_w_tex(f, &hd, b.contents, tot)) return -1;
    *bytes += tot; return 1;
}
// 显卡内容已经没了的打包贴图不存。切后台瘦身（nvn_mtl.m nvn_be_background_purge）把能从客体内存重建的打包贴图标成可清除，系统清掉后回前台只登记
//   （g_up_lost），等下次取用才整张重传；没再取用过的那些读出来是全零，存进快照后恢复时写回并整张标成「GPU 刚写过」，从此不再从客体内存重传。
//   不存的那些恢复后没有记录，第一次取用走正常路径从客体内存上传（瘦身只标这一类，本来就靠这条路径重建）。
//   返回 1 = 内容没了。*pin = 1：这张当时是可清除、内容还在，为读它先钉成不可清除，调用方读完标回可清除（瘦身不因存快照失效，回前台照常标回）。
//   调用方从问这一句到标回，全程持 g_bg_purge_mu（nvn_mtl.m，与瘦身的标 / 标回互斥）
static int snap_tex_gone(id<MTLTexture> t, int *pin) {
    *pin = 0;
    if (up_lost_has(t)) return 1;                                        // 内容没了（清掉后回过前台，或上传那一批被丢）：登记了重传、还没取用
    if (t.buffer || t.parentTexture || t.heap || t.storageMode != MTLStorageModePrivate) return 0;   // 瘦身不标这几类（nvn_be_background_purge），不问它们的可清除状态
    MTLPurgeableState s = [t setPurgeableState:MTLPurgeableStateKeepCurrent];
    if (s == MTLPurgeableStateEmpty) return 1;                           // 清掉了、还没回前台：留着已清状态，回前台标回时照常登记
    if (s != MTLPurgeableStateVolatile) return 0;
    if ([t setPurgeableState:MTLPurgeableStateNonVolatile] == MTLPurgeableStateEmpty) { [t setPurgeableState:MTLPurgeableStateEmpty]; return 1; }   // 两次查询之间被清：放回已清
    *pin = 1; return 0;
}
static int g_snap_pkg_gone;   // 上一次 snap_dump_pkg 没存的张数（日志）
static int snap_dump_pkg(const char *path, uint64_t *bytes) {
    FILE *f = fopen(path, "wb"); if (!f) return -1; int n = 0; *bytes = 0; g_snap_pkg_gone = 0;
    NSMutableArray *objs = [NSMutableArray array]; NSMutableArray<NSNumber *> *sers = [NSMutableArray array];
    pthread_mutex_lock(&g_smu);
    { uint64_t c[3] = {0}, b[3] = {0};   // 统计：预排布贴图 全部 / 稀疏池 / GPU 写过（张数、显存字节）
      for (uint32_t i = 0; i < g_by_serial.cap; i++) if (g_by_serial.vals[i]) { id o = (__bridge id)g_by_serial.vals[i]; if (![o isKindOfClass:[NvPkg class]] || !((NvPkg *)o)->tex) continue;
          NvPkg *pk = o; uint64_t sz = pk->tex.allocatedSize; c[0]++; b[0] += sz; if (pk->sparse) { c[1]++; b[1] += sz; } if (pk->pgpu) { c[2]++; b[2] += sz; } }
      MLOG("即时存档统计：预排布贴图 %llu 张 %.0f MB；其中稀疏池 %llu 张 %.0f MB、GPU 写过 %llu 张 %.0f MB", (unsigned long long)c[0], b[0] / 1048576.0, (unsigned long long)c[1], b[1] / 1048576.0, (unsigned long long)c[2], b[2] / 1048576.0); }
    for (uint32_t i = 0; i < g_by_serial.cap; i++) if (g_by_serial.vals[i]) { id o = (__bridge id)g_by_serial.vals[i];
        if ([o isKindOfClass:[NvPkg class]] && 1 && ((NvPkg *)o)->tex) { uint64_t sr; memcpy(&sr, g_by_serial.keys + (size_t)i * 8, 8); [sers addObject:@(sr)]; [objs addObject:o]; } }
    pthread_mutex_unlock(&g_smu);
    for (NSUInteger k = 0; k < objs.count; k++) {
        id<MTLTexture> t = ((NvPkg *)objs[k])->tex; int pin, r = 0;
        pthread_mutex_lock(&g_bg_purge_mu);
        int gone = snap_tex_gone(t, &pin); if (!gone) r = snap_dump_tex(f, sers[k].unsignedLongLongValue, t, bytes); if (pin) [t setPurgeableState:MTLPurgeableStateVolatile];
        pthread_mutex_unlock(&g_bg_purge_mu);
        if (gone) { g_snap_pkg_gone++; continue; }
        if (r < 0) { fclose(f); return -1; } n += r; }
    return fclose(f) == 0 ? n : -1;
}
// 只读的显卡私有普通贴图（不能当渲染目标、不能被着色器写，帧录不存；内容是游戏用 GPU 拷贝填的，游戏内存里那份是空的）：全部存
static int snap_dump_plain(const char *path, uint64_t *bytes, int *skipped) {
    FILE *f = fopen(path, "wb"); if (!f) return -1; int n = 0; *bytes = 0; *skipped = 0;
    NSMutableArray *objs = [NSMutableArray array]; NSMutableArray<NSNumber *> *sers = [NSMutableArray array];
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_by_serial.cap; i++) if (g_by_serial.vals[i]) { id o = (__bridge id)g_by_serial.vals[i];
        if (![o conformsToProtocol:@protocol(MTLTexture)]) continue; id<MTLTexture> t = o;
        if ((t.usage & (MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite)) || t.buffer || t.parentTexture || t.storageMode != MTLStorageModePrivate) continue;
        uint64_t sr; memcpy(&sr, g_by_serial.keys + (size_t)i * 8, 8); [sers addObject:@(sr)]; [objs addObject:o]; }
    pthread_mutex_unlock(&g_smu);
    for (NSUInteger k = 0; k < objs.count; k++) { int r = snap_dump_tex(f, sers[k].unsignedLongLongValue, objs[k], bytes); if (r < 0) { fclose(f); return -1; } if (r) n++; else (*skipped)++; }
    return fclose(f) == 0 ? n : -1;
}
// 预排布贴图写回：原先每张一条命令缓冲、提交后等完（11-18 iPhone 大金刚 621 张 0.44–0.57 s，几乎全是逐张等 GPU）。
//   改成两步：先逐张认贴图（tex_mtl 建对象时可能往上传批次里攒游戏内存的内容）、读进暂存缓冲；全部认完同步一次上传批次（snap_up_sync，免得批次后交盖掉写回），
//   再把拷贝编进同一条命令缓冲，暂存每满 128 MB 交一次（限住同时占的共享内存），最后等完一次
// 旧快照里记录内容全零的不写回。snap_dump_pkg 修好之前存的快照（gfx_live.bin 的 ver < 2）里，被系统在后台清掉的打包贴图是按全零存的
//   （11-23 iPad 两份：352 张里 219 张、343 张里 229 张；Mac 上没走过瘦身的两份 127 / 290 张里 0 张）；写回并标成「GPU 刚写过」就一直是全零，
//   之后再存的快照照样带着。不写回：上面 tex_mtl 刚按客体内存建好这张，留着就是对的。ver ≥ 2 的快照不存内容没了的，全零记录就是真的全零，照常写回。
//   已销毁环里的同样处理（snap_alias_restore kind 3）
static int g_snap_pkg_old;   // 正在恢复的快照是修好之前存的（nvn_snap_restore_body 读 gfx_live.bin 时定）
static int snap_all_zero(const uint8_t *p, uint64_t n) { return n && !p[0] && !memcmp(p, p + 1, n - 1); }
static int g_snap_pkg_zero;   // 上一次 snap_put_pkg 里这样处理的张数（日志）
static void snap_put_pkg(const char *path, nvn_hmap *addr, int *put, int *miss) {
    *put = *miss = 0; g_snap_pkg_zero = 0; FILE *f = fopen(path, "rb"); if (!f) return; fr_tex_hd hd;
    typedef struct { __unsafe_unretained NvPkg *pk; __unsafe_unretained id<MTLTexture> mt; __unsafe_unretained id<MTLBuffer> b; fr_tex_hd hd; } pend_t;   // 对象由 keep 持住
    NSMutableArray *keep = [NSMutableArray array];   // 持住暂存缓冲与贴图，等这一批命令做完
    pend_t *pv = NULL; int np = 0, cap = 0;
    while (snap_fread(&hd, sizeof hd, 1, f, "mtl.tex_hd")) {
        const tex_t *t = nvn_hm_get(addr, &hd.ser);
        if (!t || t->serial != hd.ser || !tex_mtl(t)) { fr_skip_tex(f, &hd); (*miss)++; continue; }
        __unsafe_unretained id o = tex_get(hd.ser); NvPkg *pk = [o isKindOfClass:[NvPkg class]] ? (NvPkg *)o : nil; id<MTLTexture> mt = pk ? pk->tex : nil;
        if (!mt || mt.width != hd.w || mt.height != hd.h || (uint32_t)mt.pixelFormat != hd.fmt || mt.mipmapLevelCount != hd.levels) { fr_skip_tex(f, &hd); (*miss)++; continue; }
        id<MTLBuffer> b = [g_dev newBufferWithLength:hd.bytes options:MTLResourceStorageModeShared];
        if (!b || !fr_r_tex(f, &hd, b.contents)) { (*miss)++; break; }
        if (g_snap_pkg_old && snap_all_zero(b.contents, hd.bytes)) { g_snap_pkg_zero++; continue; }
        if (np == cap) { cap = cap ? cap * 2 : 256; pv = realloc(pv, sizeof *pv * (size_t)cap); }
        memset(&pv[np], 0, sizeof pv[np]); pv[np].hd = hd; [keep addObject:pk]; [keep addObject:mt]; [keep addObject:b];
        pv[np].pk = pk; pv[np].mt = mt; pv[np].b = b; np++;
    }
    fclose(f);
    if (np) {
        snap_up_sync();
        int ok = 1; uint64_t inflight = 0; id<MTLCommandBuffer> cb = nil; id<MTLBlitCommandEncoder> be = nil;
        for (int i = 0; i < np && ok; i++) {
            if (!cb) { cb = [g_q commandBuffer]; be = [cb blitCommandEncoder]; }
            fr_blit_planes_enc(be, pv[i].mt, &pv[i].hd, pv[i].b, 0); inflight += pv[i].hd.bytes;
            if (inflight >= (128ull << 20) || i == np - 1) { [be endEncoding]; ok = cb_run(cb) && !cb.error; cb = nil; be = nil; inflight = 0; }
        }
        for (int i = 0; i < np; i++) {
            if (!ok) { (*miss)++; continue; }
            NvPkg *pk = pv[i].pk;
            // 整张标成「GPU 刚写过」：之后内存池有变动时只按 CPU 后写的页重传，不拿池里的旧内容盖掉写回的显卡内容
            if (pk->nph) { if (!pk->pgpu) pk->pgpu = calloc(pk->nph, sizeof *pk->pgpu); uint64_t now = nvn_dirty_now(); for (uint32_t q = 0; pk->pgpu && q < pk->nph; q++) pk->pgpu[q] = now; }
            (*put)++;
        }
    }
    free(pv); [keep removeAllObjects];
}

// ---------- 后端跨提交延续的状态（报告 15 节 4、5、8、10、12、13）----------
// 只存值；宿主指针只有两类：S 里程序指向拼合程序缓存 g_bind_cache.cp（宿主静态区），R.rt 指向 R.kept（宿主静态区）：按 A / B 里这两块的地址差平移；其余指针是游戏对象（同址）
static int ms_w(FILE *f, const void *p, size_t n) { return fwrite(p, 1, n, f) == n; }
static int ms_r(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n; }
static const void *ms_rel(const void *p, uintptr_t alo, size_t n, uintptr_t blo) { uintptr_t v = (uintptr_t)p; return v >= alo && v < alo + n ? (const void *)(v - alo + blo) : p; }
static int snap_mtl_save(FILE *f) {
    int ok = 1; uint32_t mg = 0x31544D53u;   // "SMT1"
    if (g_nxq) MLOG("【红】 即时存档：跨队列挂起的命令还有 %d 段（冻结排空后应为空），恢复后这段不会再执行", g_nxq);
    uint64_t ab[2] = {(uint64_t)(uintptr_t)&g_bind_cache, (uint64_t)(uintptr_t)&R};
    ok &= ms_w(f, &mg, 4) && ms_w(f, ab, sizeof ab) && ms_w(f, &S, sizeof S) && ms_w(f, &R, sizeof R) && ms_w(f, &g_bind_cache, sizeof g_bind_cache) && ms_w(f, &g_push_seq, 8);
    pthread_mutex_lock(&g_mu); vis_fold(); pthread_mutex_unlock(&g_mu);
    int vv[3] = {g_vis_on, g_vis_counting, g_nvs}; ok &= ms_w(f, vv, sizeof vv) && ms_w(f, &g_vis_base, 8);
    if (g_nvs) MLOG("【黄】 即时存档：遮挡计数还有 %d 格没折进累计（提交没完成）", g_nvs);
    pthread_mutex_lock(&g_gpw_mu);
    uint32_t n = g_gpw.n; ok &= ms_w(f, &g_gpw_gen, 8) && ms_w(f, &n, 4);
    for (uint32_t i = 0; i < g_gpw.cap; i++) if (g_gpw.vals[i]) ok &= ms_w(f, g_gpw.keys + (size_t)i * 8, 8) && ms_w(f, g_gpw.vals[i], sizeof(gpw_blk));
    n = g_gpw_ser.n; ok &= ms_w(f, &n, 4);
    for (uint32_t i = 0; i < g_gpw_ser.cap; i++) if (g_gpw_ser.vals[i]) { const gpw_dd *d = g_gpw_ser.vals[i];
        ok &= ms_w(f, g_gpw_ser.keys + (size_t)i * 8, 8) && ms_w(f, &d->gen, 8) && ms_w(f, &d->n, 4) && ms_w(f, d->bits, ((size_t)d->n + 63) / 64 * 8); }
    n = g_gpw_own.n; ok &= ms_w(f, &n, 4);
    for (uint32_t i = 0; i < g_gpw_own.cap; i++) if (g_gpw_own.vals[i]) ok &= ms_w(f, g_gpw_own.keys + (size_t)i * 8, 8) && ms_w(f, g_gpw_own.vals[i], sizeof(gpw_own));
    pthread_mutex_unlock(&g_gpw_mu);
    pthread_mutex_lock(&g_pool_gpuw_mu); n = g_pool_gpuw.n; ok &= ms_w(f, &n, 4);
    for (uint32_t i = 0; i < g_pool_gpuw.cap; i++) if (g_pool_gpuw.vals[i]) ok &= ms_w(f, g_pool_gpuw.keys + (size_t)i * 8, 8);
    pthread_mutex_unlock(&g_pool_gpuw_mu);
    os_unfair_lock_lock(&g_rmu); ok &= ms_w(f, g_seen_done, sizeof g_seen_done); os_unfair_lock_unlock(&g_rmu);
    pthread_mutex_lock(&g_mu); n = 0; for (int i = 0; i < g_npool; i++) n += g_pools[i].reg != 0; ok &= ms_w(f, &n, 4);
    for (int i = 0; i < g_npool; i++) if (g_pools[i].reg) { uint64_t lo = g_pools[i].lo; ok &= ms_w(f, &lo, 8); }
    pthread_mutex_unlock(&g_mu);
    // 变换反馈：按控制缓冲记的各次捕获字节数（GPU 计数在 g_tf_cnt / g_tf_snapbuf 里，排空后可直接读）
    { uint8_t z[16 * TFS_N] = {0}; int has = g_tf_cnt != nil;
      ok &= ms_w(f, &has, 4) && ms_w(f, g_tfs, sizeof g_tfs) && ms_w(f, &g_tfs_next, 4) && ms_w(f, g_tf_last_stride, sizeof g_tf_last_stride)
         && ms_w(f, has ? g_tf_cnt.contents : z, 16) && ms_w(f, has ? g_tf_snapbuf.contents : z, 16 * TFS_N); }
    MLOG("%s即时存档：后端延续状态 GPU 写记账 %u 块 / %u 张 / %u 张、写过的池 %u、遮挡计数 开=%d 计数中=%d 累计 %llu、常驻池 %u", ok ? "" : "【红】", g_gpw.n, g_gpw_ser.n, g_gpw_own.n, g_pool_gpuw.n, vv[0], vv[1], (unsigned long long)g_vis_base, n);
    return ok ? 0 : -1;
}
static int snap_mtl_restore(FILE *f) {
    uint32_t mg = 0; uint64_t ab[2]; if (!ms_r(f, &mg, 4) || mg != 0x31544D53u || !ms_r(f, ab, sizeof ab)) return -1;
    int ok = snap_fread(&S, sizeof S, 1, f, "mtl.S") && snap_fread(&R, sizeof R, 1, f, "mtl.R") && snap_fread(&g_bind_cache, sizeof g_bind_cache, 1, f, "mtl.bind_cache") && ms_r(f, &g_push_seq, 8);
    if (!ok) return -1;
    uintptr_t abc = (uintptr_t)ab[0], bbc = (uintptr_t)&g_bind_cache, ar = (uintptr_t)ab[1], br = (uintptr_t)&R; int nrel = 0;
    #define MS_PROG(x) do { const void *o_ = (x); (x) = ms_rel(o_, abc, sizeof g_bind_cache, bbc); nrel += (x) != o_; } while (0)
    MS_PROG(S.prog); MS_PROG(S.cprog); for (int i = 0; i < 5; i++) MS_PROG(S.bst[i]);
    for (int i = 0; i < 8; i++) { const void *o_ = R.rt.color[i]; R.rt.color[i] = ms_rel(o_, ar, sizeof R, br); nrel += R.rt.color[i] != o_; }
    { const void *o_ = R.rt.depth; R.rt.depth = ms_rel(o_, ar, sizeof R, br); nrel += R.rt.depth != o_; }
    #undef MS_PROG
    memset(g_args_dirty, 1, sizeof g_args_dirty);
    int vv[3]; ok = ms_r(f, vv, sizeof vv) && ms_r(f, &g_vis_base, 8); if (!ok) return -1;
    g_vis_on = vv[0]; g_vis_counting = vv[1]; g_nvs = 0; g_vis_cur = -1;
    uint32_t n, nb = 0, nd = 0, no = 0, np = 0;
    pthread_mutex_lock(&g_gpw_mu);
    ok = ms_r(f, &g_gpw_gen, 8) && ms_r(f, &n, 4);
    for (uint32_t i = 0; ok && i < n; i++) { uint64_t k; gpw_blk *b = calloc(1, sizeof *b); ok = b && ms_r(f, &k, 8) && snap_fread(b, sizeof *b, 1, f, "mtl.gpw_blk"); if (ok) { nvn_hm_put(&g_gpw, &k, b); atomic_fetch_add(&g_gpw_nblk, 1); nb++; } }
    ok = ok && ms_r(f, &n, 4);
    for (uint32_t i = 0; ok && i < n; i++) { uint64_t k, gen; uint32_t dn; ok = ms_r(f, &k, 8) && ms_r(f, &gen, 8) && ms_r(f, &dn, 4); if (!ok) break;
        gpw_dd *d = calloc(1, sizeof *d + ((size_t)dn + 63) / 64 * 8); ok = d && ms_r(f, d->bits, ((size_t)dn + 63) / 64 * 8); if (ok) { d->gen = gen; d->n = dn; nvn_hm_put(&g_gpw_ser, &k, d); nd++; } }
    ok = ok && ms_r(f, &n, 4);
    for (uint32_t i = 0; ok && i < n; i++) { uint64_t k; gpw_own *o = calloc(1, sizeof *o); ok = o && ms_r(f, &k, 8) && snap_fread(o, sizeof *o, 1, f, "mtl.gpw_own"); if (ok) { nvn_hm_put(&g_gpw_own, &k, o); no++; } }
    pthread_mutex_unlock(&g_gpw_mu);
    ok = ok && ms_r(f, &n, 4);
    pthread_mutex_lock(&g_pool_gpuw_mu);
    for (uint32_t i = 0; ok && i < n; i++) { uint64_t k; ok = ms_r(f, &k, 8); if (ok) { nvn_hm_put(&g_pool_gpuw, &k, (void *)1); np++; } }
    pthread_mutex_unlock(&g_pool_gpuw_mu); if (np) atomic_store(&g_pool_gpuw_new, 1);
    if (!ok) return -1;
    // 着色器读过的贴图编号：标成待处理，首次提交（pool_seen_scan）按预算把它们建出来、放进表
    os_unfair_lock_lock(&g_rmu); ok = ms_r(f, g_seen_done, sizeof g_seen_done); memcpy(g_seen_todo, g_seen_done, sizeof g_seen_todo); g_seen_sub = ~0ull; g_seen_dirty = ~0ull; os_unfair_lock_unlock(&g_rmu);
    uint32_t nseen = 0; for (unsigned i = 0; i < POOL_SEEN_WORDS; i++) nseen += (uint32_t)__builtin_popcount(g_seen_done[i]);
    uint32_t nreg = 0, hit = 0; ok = ok && ms_r(f, &nreg, 4);
    pthread_mutex_lock(&g_mu);
    for (uint32_t i = 0; ok && i < nreg; i++) { uint64_t lo; ok = ms_r(f, &lo, 8); if (!ok) break; for (int j = 0; j < g_npool; j++) if (g_pools[j].lo == lo) { pool_res(j); hit++; break; } }
    pthread_mutex_unlock(&g_mu);
    { int has = 0; uint8_t c[16], sb[16 * TFS_N];
      ok = ok && ms_r(f, &has, 4) && ms_r(f, g_tfs, sizeof g_tfs) && ms_r(f, &g_tfs_next, 4) && ms_r(f, g_tf_last_stride, sizeof g_tf_last_stride) && ms_r(f, c, 16) && ms_r(f, sb, sizeof sb);
      if (ok && has) { if (tf_init()) { memcpy(g_tf_cnt.contents, c, 16); memcpy(g_tf_snapbuf.contents, sb, sizeof sb); } else MLOG("【红】 即时存档恢复：变换反馈计数缓冲建不了"); } }
    MLOG("%s即时存档恢复：后端延续状态 绘制 / 目标状态（平移宿主指针 %d 个）、GPU 写记账 %u 块 / %u 张 / %u 张、写过的池 %u、遮挡计数 开=%d 计数中=%d 累计 %llu、着色器读过的编号 %u、常驻池 %u/%u",
         ok ? "" : "【红】", nrel, nb, nd, no, np, g_vis_on, g_vis_counting, (unsigned long long)g_vis_base, nseen, hit, nreg);
    return ok ? 0 : -1;
}

// ---------- 共享存储贴图表 g_alias 与已销毁贴图环 g_ghost（报告 15 节 9）----------
// 按序号表（g_by_serial）只覆盖还活着的对象；每帧在同一段存储上重建对象的渲染目标、长期命令列表里引用的已销毁贴图，只在这两张表里。
//   存：每个共享贴图的键 + 描述（用途 / 存储方式 / 色彩通道映射）+ 整份显卡内容；已销毁的：是共享贴图就记它在共享表里的序号，否则单独存内容。
//   恢复：在重建活对象之前放回共享表（之后 tex_mtl 走「同存储同描述 = 同一张」直接拿到恢复的那张），已销毁的按序号放回环
// 写回显卡内容前：把建对象时攒在上传批次里的（从游戏内存读的）上传先交出去并等完，否则批次后交会把写回的内容盖掉（同 q_cb 的规矩）。
//   恢复时提交线程还没起（或就在提交线程上：已销毁贴图的延后写回），两种情况都可以动批次
static void snap_up_sync(void) {
    if (atomic_load(&g_sub_thread_set) && !on_sub_thread()) { MLOG("【红】 即时存档恢复：不在提交线程上，上传批次动不了，写回可能被盖"); return; }
    // 交批次 → 把记下的块交给编码线程并等它做完 → 等批次完成（同提交线程取命令缓冲 q_cb 的顺序）。延迟编码线程一进程只起一次：进程内重启后它还在，
    //   批次的提交只被记进待编码的块；恢复时不在任何一帧里，不交出去就永远等不到完成（进程内「回到快照」卡在这里）。冷启动时线程还没起，rec_drain 直接返回
    up_flush(); rec_drain(); up_wait_zero(&g_up_pending);
}
typedef struct { uint64_t usage, smode, swz; } snap_al_x;
static int snap_al_dump(FILE *f, id<MTLTexture> t, uint64_t *bytes) {   // 1 存了，0 不存（多重采样 / 格式不认 / 太大），-1 写失败
    snap_al_x x = {t.usage, t.storageMode, 0}; MTLTextureSwizzleChannels sw = t.swizzle; memcpy(&x.swz, &sw, sizeof sw);
    fr_tex_hd hd = {0, (uint32_t)t.textureType, (uint32_t)t.pixelFormat, (uint32_t)t.width, (uint32_t)t.height, (uint32_t)t.depth, (uint32_t)fr_slices(t), (uint32_t)t.mipmapLevelCount, FR_TK_PLAIN, (uint32_t)t.sampleCount};
    if (t.sampleCount > 1 || t.buffer || t.parentTexture) return 0;
    hd.nplane = (uint32_t)fr_planes(t.pixelFormat, hd.pl); if (!hd.nplane) return 0;
    uint64_t tot = 0;
    for (uint32_t q = 0; q < hd.nplane; q++) for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) tot += fr_plane_bytes(&hd.pl[q], MAX(1, t.width >> l), MAX(1, t.height >> l), MAX(1, t.depth >> l)) * hd.layers;
    if (!tot || tot > (256ull << 20)) return 0;
    id<MTLBuffer> b = [g_dev newBufferWithLength:tot options:MTLResourceStorageModeShared]; if (!b || !fr_blit_planes(t, &hd, b, 1)) return 0;
    if (!fr_w(f, &x, sizeof x) || !fr_w_tex(f, &hd, b.contents, tot)) return -1;
    *bytes += tot; return 1;
}
static int g_snap_al_zero;   // 上一次 snap_al_load_x 读到的内容是不是全零（snap_alias_restore kind 3 用）
static id<MTLTexture> snap_al_load_x(FILE *f, int res);
static id<MTLTexture> snap_al_load(FILE *f) { return snap_al_load_x(f, 1); }
static id<MTLTexture> snap_al_load_x(FILE *f, int res) {   // 读一张：建同描述的贴图、写回内容；读坏返回 nil 且 errno = EIO。res：登记进本层常驻集（GL 出图层的贴图不登记）
    snap_al_x x; fr_tex_hd hd; errno = 0;
    if (!fr_r(f, &x, sizeof x) || !snap_fread(&hd, sizeof hd, 1, f, "mtl.tex_hd")) { errno = EIO; return nil; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = (MTLTextureType)hd.type; d.pixelFormat = (MTLPixelFormat)hd.fmt; d.width = hd.w; d.height = hd.h; d.depth = MAX(1u, hd.depth); d.mipmapLevelCount = hd.levels; d.sampleCount = 1;
    d.arrayLength = hd.type == MTLTextureTypeCube || hd.type == MTLTextureTypeCubeArray ? MAX(1u, hd.layers / 6) : hd.type == MTLTextureType3D ? 1 : MAX(1u, hd.layers);
    d.usage = (MTLTextureUsage)x.usage; d.storageMode = (MTLStorageMode)x.smode; MTLTextureSwizzleChannels sw; memcpy(&sw, &x.swz, sizeof sw); d.swizzle = sw;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    id<MTLBuffer> b = [g_dev newBufferWithLength:MAX(hd.bytes, 1ull) options:MTLResourceStorageModeShared];
    if (!b || !fr_r_tex(f, &hd, b.contents)) { errno = EIO; return nil; }
    g_snap_al_zero = g_snap_pkg_old && snap_all_zero(b.contents, hd.bytes);
    if (!t) return nil;
    if (res) res_add(t);
    if (!fr_blit_planes(t, &hd, b, 0)) { if (res) res_remove(t); return nil; }   // 写回失败的没有表引用它，出常驻集
    return t;
}
// GL 出图层（gfx/gl 即时存档）用：整张贴图（不是视图）连描述一起存 / 取。内容存不了（多重采样 / 格式不认 / 超 256 MB）的只存描述，取时建同描述的空贴图（下一帧重画）
//   记录：[u8 1][snap_al_dump 那一张] 或 [u8 0][snap_al_x][fr_tex_hd（bytes = 0）]；存回 1 存了内容 / 0 只存描述 / -1 写失败；取回贴图，读坏 nil
int nvn_snap_tex_save(FILE *f, void *tex) {
    id<MTLTexture> t = (__bridge id<MTLTexture>)tex; uint64_t bytes = 0; long pos = ftell(f); uint8_t k = 1;
    if (!fr_w(f, &k, 1)) return -1;
    int r = snap_al_dump(f, t, &bytes); if (r != 0) return r;
    fseek(f, pos, SEEK_SET); k = 0;
    snap_al_x x = {t.usage, t.storageMode, 0}; MTLTextureSwizzleChannels sw = t.swizzle; memcpy(&x.swz, &sw, sizeof sw);
    fr_tex_hd hd = {0, (uint32_t)t.textureType, (uint32_t)t.pixelFormat, (uint32_t)t.width, (uint32_t)t.height, (uint32_t)t.depth, (uint32_t)fr_slices(t), (uint32_t)t.mipmapLevelCount, FR_TK_PLAIN, (uint32_t)t.sampleCount};
    return fr_w(f, &k, 1) && fr_w(f, &x, sizeof x) && fr_w(f, &hd, sizeof hd) ? 0 : -1;
}
void *nvn_snap_tex_load(FILE *f) {
    uint8_t k; if (!fr_r(f, &k, 1)) return NULL;
    if (k == 1) { id<MTLTexture> t = snap_al_load_x(f, 0); return t ? (__bridge_retained void *)t : NULL; }
    snap_al_x x; fr_tex_hd hd; if (!fr_r(f, &x, sizeof x) || !snap_fread(&hd, sizeof hd, 1, f, "mtl.tex_hd")) return NULL;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = (MTLTextureType)hd.type; d.pixelFormat = (MTLPixelFormat)hd.fmt; d.width = MAX(1u, hd.w); d.height = MAX(1u, hd.h); d.depth = MAX(1u, hd.depth); d.mipmapLevelCount = MAX(1u, hd.levels); d.sampleCount = MAX(1u, hd.samples);
    d.arrayLength = hd.type == MTLTextureTypeCube || hd.type == MTLTextureTypeCubeArray ? MAX(1u, hd.layers / 6) : hd.type == MTLTextureType3D ? 1 : MAX(1u, hd.layers);
    d.usage = (MTLTextureUsage)x.usage; d.storageMode = (MTLStorageMode)x.smode; MTLTextureSwizzleChannels sw; memcpy(&sw, &x.swz, sizeof sw); d.swizzle = sw;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; return t ? (__bridge_retained void *)t : NULL;
}
static int snap_alias_save(const char *path) {
    FILE *f = fopen(path, "wb"); if (!f) return -1;
    NSMutableArray *objs = [NSMutableArray array]; NSMutableData *keys = [NSMutableData data]; NSMutableArray *gobj = [NSMutableArray array]; NSMutableData *gser = [NSMutableData data];
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_alias.cap; i++) if (g_alias.vals[i]) { [keys appendBytes:g_alias.keys + (size_t)i * sizeof(alias_key) length:sizeof(alias_key)]; [objs addObject:(__bridge id)g_alias.vals[i]]; }
    for (unsigned r = 0; r < NGHOST; r++) { uint64_t k = g_ghost_ring[(g_ghost_next + r) % NGHOST]; id o = k ? hm_get_id(&g_ghost, &k) : nil; if (o) { [gser appendBytes:&k length:8]; [gobj addObject:o]; } }   // 由旧到新
    pthread_mutex_unlock(&g_smu);
    uint32_t n = (uint32_t)objs.count, sv = 0, sk = 0; uint64_t bytes = 0; int ok = fr_w(f, &n, 4);
    for (uint32_t i = 0; ok && i < n; i++) {
        id o = objs[i]; int r = 0; uint8_t has = 0;
        ok = fr_w(f, (const uint8_t *)keys.bytes + (size_t)i * sizeof(alias_key), sizeof(alias_key));
        if (ok && [o conformsToProtocol:@protocol(MTLTexture)]) { long pos = ftell(f); has = 1; ok = fr_w(f, &has, 1); r = ok ? snap_al_dump(f, o, &bytes) : -1;
            if (r == 0) { fseek(f, pos, SEEK_SET); has = 0; ok = fr_w(f, &has, 1); } else ok = r > 0; }
        else ok = ok && fr_w(f, &has, 1);
        if (r > 0) sv++; else { sk++; id<MTLTexture> mt = [o conformsToProtocol:@protocol(MTLTexture)] ? o : nil; const alias_key *kk = (const alias_key *)((const uint8_t *)keys.bytes + (size_t)i * sizeof(alias_key));
            MLOG("即时存档诊断：共享贴图不存 池 %#llx+%#llx NVN 格式 %#x %ux%u 级 %u；Metal 格式 %d 采样 %d 类型 %d 用途 %#lx%s", (unsigned long long)kk->pool, (unsigned long long)kk->off, kk->d.format, kk->d.width, kk->d.height, kk->d.levels,
                 mt ? (int)mt.pixelFormat : -1, mt ? (int)mt.sampleCount : -1, mt ? (int)mt.textureType : -1, mt ? (unsigned long)mt.usage : 0ul, mt ? "" : "（不是贴图）"); }
    }
    uint32_t ng = (uint32_t)gobj.count, gs = 0, ga = 0, gk = 0; ok = ok && fr_w(f, &ng, 4);
    for (uint32_t i = 0; ok && i < ng; i++) {
        id o = gobj[i]; uint64_t ser; memcpy(&ser, (const uint8_t *)gser.bytes + (size_t)i * 8, 8); uint32_t ai = UINT32_MAX;
        for (uint32_t j = 0; j < n; j++) if (objs[j] == o) { ai = j; break; }
        id po = [o isKindOfClass:[NvPkg class]] ? ((NvPkg *)o)->tex : nil;   // 预排布贴图（已销毁）：存它的显卡内容，恢复时按登记表里的描述重建对象再写回
        int pin = 0; id<MTLTexture> pt = po; if (pt) pthread_mutex_lock(&g_bg_purge_mu);   // 内容已经没了的不存（同 snap_dump_pkg），按「不存」记；锁到本轮末尾标回之后
        if (po && snap_tex_gone(po, &pin)) po = nil;
        uint8_t kind = ai != UINT32_MAX ? 1 : [o conformsToProtocol:@protocol(MTLTexture)] ? 2 : po ? 3 : 0; if (kind == 3) o = po;
        ok = fr_w(f, &ser, 8) && fr_w(f, &kind, 1);
        if (ok && kind == 1) { ok = fr_w(f, &ai, 4); ga++; }
        else if (ok && (kind == 2 || kind == 3)) { long pos = ftell(f); int r = snap_al_dump(f, o, &bytes); if (r == 0) { fseek(f, pos - 1, SEEK_SET); kind = 0; ok = fr_w(f, &kind, 1); gk++; } else { ok = r > 0; gs++; } }
        else gk++;
        if (pin) [pt setPurgeableState:MTLPurgeableStateVolatile];
        if (pt) pthread_mutex_unlock(&g_bg_purge_mu);
    }
    ok = fclose(f) == 0 && ok;
    MLOG("%s即时存档：共享存储贴图 %u 张（存内容 %u、不存 %u），已销毁贴图环 %u 个（指共享表 %u、单存 %u、不存 %u），共 %.0f MB", ok ? "" : "【红】", n, sv, sk, ng, ga, gs, gk, bytes / 1048576.0);
    return ok ? 0 : -1;
}
// 已销毁的预排布贴图：在贴图池登记表里找这个序号的描述（登记时的快照），按它走正常路径建对象（不是活对象，进已销毁环），再把 A 的显卡内容拷进去、整张标成 GPU 刚写过
static int snap_ghost_put(NvPkg *pk, id<MTLTexture> src);
// 登记表里没有描述的（只在命令记录的快照里）：内容先留在待写回表，B 第一次按序号重建它（回放到引用它的命令）时写进去
static void snap_ghost_apply(uint64_t ser, id o) {
    void *v = nvn_hm_del(&g_snap_ghost_pend, &ser); if (!v) return;
    id<MTLTexture> src = CFBridgingRelease(v); int ok = snap_ghost_put((NvPkg *)o, src);
    res_remove(src);   // 内容已写进重建的贴图（拷贝是同步跑完的），这张只是来源：出常驻集，不然一直不放
    MLOG("%s即时存档恢复：已销毁贴图 ser=%llu 重建时写回 A 的显卡内容%s（待写回还剩 %u）", ok ? "" : "【黄】", (unsigned long long)ser, ok ? "" : "失败（描述不同）", g_snap_ghost_pend.n);
}
static int snap_ghost_pkg(uint64_t ser, id<MTLTexture> src) {
    tex_t t; int found = 0;
    os_unfair_lock_lock(&g_rmu); for (int i = 0; i < g_ntreg; i++) if (g_treg[i].ok && g_treg[i].t.serial == ser) { t = g_treg[i].t; found = 1; break; } os_unfair_lock_unlock(&g_rmu);
    if (!found) { nvn_hm_put(&g_snap_ghost_pend, &ser, (void *)CFBridgingRetain(src)); return 2; }
    if (!tex_mtl(&t)) return 0;
    __unsafe_unretained id o = tex_get(ser); return snap_ghost_put([o isKindOfClass:[NvPkg class]] ? (NvPkg *)o : nil, src);
}
static int snap_ghost_put(NvPkg *pk, id<MTLTexture> src) {
    id<MTLTexture> mt = pk ? pk->tex : nil;
    if (!mt || mt.width != src.width || mt.height != src.height || mt.pixelFormat != src.pixelFormat || mt.mipmapLevelCount != src.mipmapLevelCount || mt.arrayLength != src.arrayLength || mt.textureType != src.textureType) return 0;
    snap_up_sync();
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:src toTexture:mt]; [be endEncoding];
    if (!cb_run(cb) || cb.error) return 0;
    if (pk->nph) { if (!pk->pgpu) pk->pgpu = calloc(pk->nph, sizeof *pk->pgpu); uint64_t now = nvn_dirty_now(); for (uint32_t q = 0; pk->pgpu && q < pk->nph; q++) pk->pgpu[q] = now; }
    return 1;
}
static int snap_alias_restore(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return -1;
    uint32_t n = 0, put = 0, miss = 0; int ok = fr_r(f, &n, 4);
    NSMutableArray *objs = [NSMutableArray arrayWithCapacity:n];
    pthread_mutex_lock(&g_smu); if (!g_alias_set) g_alias_set = CFSetCreateMutable(NULL, 0, NULL); pthread_mutex_unlock(&g_smu);
    for (uint32_t i = 0; ok && i < n; i++) {
        alias_key ak; uint8_t has; ok = snap_fread(&ak, sizeof ak, 1, f, "mtl.alias_key") && fr_r(f, &has, 1); if (!ok) break;
        id<MTLTexture> t = nil; if (has) { t = snap_al_load(f); if (!t && errno == EIO) { ok = 0; break; } }
        [objs addObject:t ? (id)t : (id)[NSNull null]];
        if (!t) { miss++; continue; }
        pthread_mutex_lock(&g_smu); hm_put_id(&g_alias, &ak, t); CFSetAddValue(g_alias_set, (__bridge const void *)t); nvn_hm_put(&g_alias_seen, &ak, (void *)(uintptr_t)(g_fence + 1)); pthread_mutex_unlock(&g_smu);
        put++;
    }
    uint32_t ng = 0, gp = 0, gm = 0, gw = 0, gz = 0; ok = ok && fr_r(f, &ng, 4);
    for (uint32_t i = 0; ok && i < ng; i++) {
        uint64_t ser; uint8_t kind; ok = fr_r(f, &ser, 8) && fr_r(f, &kind, 1); if (!ok) break;
        id o = nil;
        if (kind == 1) { uint32_t ai; ok = fr_r(f, &ai, 4); if (ok && ai < objs.count && objs[ai] != [NSNull null]) o = objs[ai]; }
        else if (kind == 2 || kind == 3) { o = snap_al_load(f); if (!o && errno == EIO) { ok = 0; break; } }
        if (!o) { gm++; continue; }
        if (kind == 3 && g_snap_pkg_old && g_snap_al_zero) { res_remove(o); gm++; gz++; continue; }   // 旧快照里按全零存的已销毁打包贴图：不放回，重建时按客体内存上传
        if (kind == 3) { int r = snap_ghost_pkg(ser, o); if (r == 1) gp++; else if (r == 2) gw++; else gm++; if (r != 2) res_remove(o); continue; }   // 当场写回 / 没放回的，来源贴图出常驻集（等重建的留到 snap_ghost_apply / 会话销毁）
        pthread_mutex_lock(&g_smu); tex_put_locked(ser, o); pthread_mutex_unlock(&g_smu); gp++;
    }
    fclose(f);
    MLOG("%s即时存档恢复：共享存储贴图放回 %u 张（没放回 %u），已销毁贴图环放回 %u 个（等重建时写回 %u、没放回 %u）", ok ? "" : "【红】", put, miss, gp, gw, gm);
    if (gz) MLOG("即时存档恢复：旧快照里已销毁的预排布贴图 %u 张的记录内容全零，不放回（算在没放回里）", gz);
    return ok ? 0 : -1;
}
// GL 出图层（graphics/nvn/gfx/gl/egl.m）；图形单测不链 GL 片时为空
int gl_snap_used(void) __attribute__((weak)); void gl_snap_fps(snap_fp_cb cb) __attribute__((weak)); int gl_snap_save(const char *path) __attribute__((weak)); int gl_snap_restore(const char *path) __attribute__((weak));
// Vulkan 出图层（graphics/nvn/gfx/vk/vk_snap.inc）；图形单测不链 Vulkan 片时为空
int vk_snap_used(void) __attribute__((weak)); void vk_snap_fps(snap_fp_cb cb) __attribute__((weak)); int vk_snap_save(const char *path) __attribute__((weak)); int vk_snap_restore(const char *path) __attribute__((weak));
// 本文件按整块存的后端结构的布局指纹（不同 = 布局变了：读入处经 snap_fread 按字段转；见 snapfmt.h）
void nvn_snap_fps(snap_fp_cb cb) {
    cb("mtl.S", SNAP_FP_OF(S)); cb("mtl.R", SNAP_FP_OF(R)); cb("mtl.bind_cache", SNAP_FP_OF(g_bind_cache)); cb("mtl.live", SNAP_FP_TYPE(nvn_snap_live));
    cb("mtl.gpw_blk", SNAP_FP_TYPE(gpw_blk)); cb("mtl.gpw_own", SNAP_FP_TYPE(gpw_own)); cb("mtl.tex_hd", SNAP_FP_TYPE(fr_tex_hd)); cb("mtl.alias_key", SNAP_FP_TYPE(alias_key));
    cb("mtl.tfs", SNAP_FP_OF(g_tfs[0]));
    if (gl_snap_fps) gl_snap_fps(cb);   // GL 出图层（egl.m）
    if (vk_snap_fps) vk_snap_fps(cb);   // Vulkan 出图层（vk_snap.inc）
}
void s2a_snap_progress(const char *layer) __attribute__((weak));
#define SNAP_AT(s) do { if (s2a_snap_progress) s2a_snap_progress(s); } while (0)
static int nvn_snap_save_body(const char *dir);
int nvn_snap_save(const char *dir) { @autoreleasepool { return nvn_snap_save_body(dir); } }   // 同 nvn_snap_restore，存的时候读回贴图建的对象也当场放
static int nvn_snap_save_body(const char *dir) {
    if (!s2a_snap_arena_get) { MLOG("【红】 即时存档：宿主没有命令记录区接口"); return -1; }
    // GL 出图层（外部生产者）：先排空那一层、存它的对象与上下文（gfx/gl egl.m gl_snap_save）；Vulkan 层另做
    SNAP_AT("图形 GL 出图层");
    if (gl_snap_save && gl_snap_used && gl_snap_used()) { char gp[1200]; snprintf(gp, sizeof gp, "%s/gfx_gl.bin", dir); if (gl_snap_save(gp)) { MLOG("【红】 即时存档：GL 出图层状态没存成"); return -1; } }
    SNAP_AT("图形 Vulkan 出图层");
    if (vk_snap_save && vk_snap_used && vk_snap_used()) { char vp[1200]; snprintf(vp, sizeof vp, "%s/gfx_vk.bin", dir); if (vk_snap_save(vp)) { MLOG("【红】 即时存档：Vulkan 出图层状态没存成"); return -1; } }
    uint64_t ca = 0, cu = 0, vu = 0; s2a_snap_arena_get(&ca, &cu, &vu);
    if (!ca) { MLOG("【红】 即时存档：命令记录区没开（存档模式要 S2A_CMD_ARENA=1），命令句柄落点不固定，存不了"); return -1; }
    SNAP_AT("图形 等 GPU 做完"); mtl_present_flush(); mtl_finish_gpu();
    char p[1200]; int ok = 1;
    SNAP_AT("图形 gfx_state");
    snprintf(p, sizeof p, "%s/gfx_state.bin", dir); ok &= fr_dump_state(p);
    SNAP_AT("图形 gfx_progkeys");
    { snprintf(p, sizeof p, "%s/gfx_progkeys.bin", dir); FILE *f = fopen(p, "wb"); ok &= f && s2a_hle_pk_save(f) >= 0; if (f) ok &= fclose(f) == 0; }
    SNAP_AT("图形 gfx_vpool");
    { snprintf(p, sizeof p, "%s/gfx_vpool.bin", dir); FILE *f = fopen(p, "wb"); ok &= f && s2a_hle_vpool_save(f) >= 0; if (f) ok &= fclose(f) == 0; }
    int nseg = 0;
    SNAP_AT("图形 gfx_shadow");
    { snprintf(p, sizeof p, "%s/gfx_shadow.bin", dir); FILE *f = fopen(p, "wb"); ok &= f != NULL;
      if (f) { nseg = s2a_hle_cmdshadow_list ? s2a_hle_cmdshadow_list(fr_seg_cb, f) : 0; uint32_t e = FR_REC_END; fr_w(f, &e, 4); ok &= fclose(f) == 0; } }
    nvn_snap_live lv = {0x31534E4Eu, 2 /* 2 = 打包贴图只存显卡内容还在的（snap_tex_gone）；读的一方只拿它判 g_snap_pkg_old */, 0, 0, 0, 0, 0, nvn_serial_now(), atomic_load(&g_cur_frame), ca, cu, vu};
    pthread_mutex_lock(&g_mu); lv.fence = g_fence; lv.done = g_done; pthread_mutex_unlock(&g_mu);
    pthread_mutex_lock(&g_pq_mu); lv.pq_in = g_pq_in; lv.pq_done = g_pq_done; lv.pq_read = g_pq_read; pthread_mutex_unlock(&g_pq_mu);
    SNAP_AT("图形 gfx_live");
    { snprintf(p, sizeof p, "%s/gfx_live.bin", dir); FILE *f = fopen(p, "wb"); ok &= f && fr_w(f, &lv, sizeof lv); if (f) ok &= fclose(f) == 0; }
    SNAP_AT("图形 gfx_hle");
    { snprintf(p, sizeof p, "%s/gfx_hle.bin", dir); FILE *f = fopen(p, "wb"); ok &= f && hle_snap_save(f) == 0; if (f) ok &= fclose(f) == 0; }
    SNAP_AT("图形 gfx_gs");
    { snprintf(p, sizeof p, "%s/gfx_gs.bin", dir); FILE *f = fopen(p, "wb"); ok &= f && nvn2_snap_gs_save && nvn2_snap_gs_save(f) == 0; if (f) ok &= fclose(f) == 0; }
    // 对象序号 → 游戏里贴图对象地址（只留对象里序号仍是它的，即还活着的）
    SNAP_AT("图形 gfx_texaddr");
    //   g_smu 下只拷出（序号, 地址）；查可读（每项一次 vm_region 系统调用）、读对象、写文件都在锁外（游戏线程已冻结，对象不会变）——持 g_smu 不做系统调用和 IO。
    //   不在了的（内存已还 / 序号已换：没 Finalize 就释放）最后持锁从表里删，表只剩活对象
    { snprintf(p, sizeof p, "%s/gfx_texaddr.bin", dir); FILE *f = fopen(p, "wb"); uint32_t n = 0, nfree = 0, nstale = 0, tot = 0; ok &= f != NULL;
      pthread_mutex_lock(&g_smu);
      uint64_t (*ta)[2] = g_snap_texaddr.n ? malloc((size_t)g_snap_texaddr.n * sizeof *ta) : NULL;
      for (uint32_t i = 0; ta && i < g_snap_texaddr.cap; i++) if (g_snap_texaddr.vals[i]) { memcpy(&ta[tot][0], g_snap_texaddr.keys + (size_t)i * 8, 8); ta[tot][1] = (uint64_t)(uintptr_t)g_snap_texaddr.vals[i]; tot++; }
      pthread_mutex_unlock(&g_smu);
      ok &= !g_snap_texaddr.n || ta != NULL;
      uint32_t ndead = 0;
      for (uint32_t i = 0; i < tot; i++) {
          const tex_t *t = (const tex_t *)(uintptr_t)ta[i][1]; int live = span_readable(t, sizeof *t) && t->serial == ta[i][0];
          if (!live) { if (span_readable(t, sizeof *t)) nstale++; else nfree++; ta[ndead++][0] = ta[i][0]; continue; }   // 游戏已把放对象的内存还掉 / 收成不可访问，或那块已是别的对象：不存
          uint64_t r[2] = {ta[i][0], ta[i][1]}; if (f) ok &= fr_w(f, r, sizeof r); n++;
      }
      if (ndead) { pthread_mutex_lock(&g_smu); for (uint32_t i = 0; i < ndead; i++) nvn_hm_del(&g_snap_texaddr, &ta[i][0]); pthread_mutex_unlock(&g_smu); }
      free(ta); if (f) ok &= fclose(f) == 0;
      MLOG("即时存档：活着的贴图对象 %u 个（表里 %u 项；对象内存已不可读 %u 个、已换成别的对象 %u 个，已从表里删）", n, tot, nfree, nstale); }
    SNAP_AT("图形 gfx_gpu");
    { uint64_t gb = 0; int skipped = 0; snprintf(p, sizeof p, "%s/gfx_gpu.bin", dir); int ng = fr_dump_gpu(p, &gb, &skipped); ok &= ng >= 0; MLOG("即时存档：GPU 私有贴图 %d 张 %.0f MB（不存 %d 张）", ng, gb / 1048576.0, skipped); }
    SNAP_AT("图形 gfx_plain");
    { uint64_t pb = 0; int sk = 0; snprintf(p, sizeof p, "%s/gfx_plain.bin", dir); int np = snap_dump_plain(p, &pb, &sk); ok &= np >= 0; MLOG("即时存档：只读的显卡私有普通贴图 %d 张 %.0f MB（不存 %d 张）", np, pb / 1048576.0, sk); }
    SNAP_AT("图形 gfx_pkg");
    { uint64_t pb = 0; snprintf(p, sizeof p, "%s/gfx_pkg.bin", dir); int np = snap_dump_pkg(p, &pb); ok &= np >= 0; MLOG("即时存档：GPU 写过的预排布贴图 %d 张 %.0f MB", np, pb / 1048576.0);
      if (g_snap_pkg_gone) MLOG("即时存档：预排布贴图 %d 张的显卡内容已经没了（系统在后台清掉，或上传被丢）、还没重传，不存（恢复后第一次取用从客体内存上传）", g_snap_pkg_gone); }
    SNAP_AT("图形 gfx_alias");
    { snprintf(p, sizeof p, "%s/gfx_alias.bin", dir); ok &= snap_alias_save(p) == 0; }
    SNAP_AT("图形 gfx_mtl");
    { snprintf(p, sizeof p, "%s/gfx_mtl.bin", dir); FILE *f = fopen(p, "wb"); ok &= f && snap_mtl_save(f) == 0; if (f) ok &= fclose(f) == 0; }
    SNAP_AT("图形 gfx_codec");
    { snprintf(p, sizeof p, "%s/gfx_codec.bin", dir); FILE *f = fopen(p, "wb"); int nc = f && nvn2_snap_codec_save ? nvn2_snap_codec_save(f) : 0; ok &= f && nc >= 0; if (f) ok &= fclose(f) == 0; if (nc > 0) MLOG("即时存档：视频解码器 %d 个", nc); }
    MLOG("%s即时存档：图形 栅栏 %llu/%llu、出图序号 %llu、对象序号 %llu、帧 %llu、命令记录宿主块 %d 段（区已用 %llu MB）", ok ? "" : "【红】", (unsigned long long)lv.fence, (unsigned long long)lv.done,
         (unsigned long long)lv.pq_in, (unsigned long long)lv.serial, (unsigned long long)lv.frame, nseg, (unsigned long long)(cu >> 20));
    return ok ? 0 : -1;
}
// 恢复把栅栏号 / 出图票号倒回快照里的数。「这份分配器占用到几号」的两张表（g_alloc_fence / g_present_alloc_fence）记的是旧局的大号，
//   进程内恢复时不清就等不到：显示链接回调在 present_now 里等 g_pq_done 追上旧票号，画面停在恢复那一帧，追上后下一槽等的正是自己这张票，永久停。
//   走到这里时旧局的提交与上屏都已排空（session_wait_backend / nvn_be_present_shutdown），两张表清零即「全部空闲」；冷启动恢复本来就是零
static void snap_seq_rewind(uint64_t fence, uint64_t pq_in) {
    pthread_mutex_lock(&g_mu); g_fence = g_done = fence; memset(g_alloc_fence, 0, sizeof g_alloc_fence); pthread_mutex_unlock(&g_mu);
    // 同理「这段内存的 GPU 写入到几号栅栏才落地」的表：会话清理只清 g_gw / g_gw_all，大范围写入表与在途内联常量更新表的旧号留着，
    //   ubo_wait_submitted 会在提交线程上等它（等的线程自己就是推进栅栏号的那个）。ifw 清桶头即可，表项按 seq 核对、够不着就不算
    memset(g_gw, 0, sizeof g_gw); g_gw_all = 0; memset(g_gw_wide, 0, sizeof g_gw_wide); memset(g_ifw_head, 0, sizeof g_ifw_head);
    g_reclaim_next = 0;   // 低内存贴图回收「下一次到几号栅栏」：留着旧的大号，追上之前不回收
    g_ev.signaledValue = fence;
    pthread_mutex_lock(&g_pq_mu); g_pq_in = g_pq_done = g_pq_read = pq_in; memset(g_present_alloc_fence, 0, sizeof g_present_alloc_fence); pthread_mutex_unlock(&g_pq_mu);
}
static nvn_hmap *g_snap_addr_lk;
static const void *snap_addr_lookup(uint64_t ser) { return g_snap_addr_lk ? nvn_hm_get(g_snap_addr_lk, &ser) : NULL; }
// 恢复里建的 Metal 对象（放回贴图用的拷贝编码器、命令缓冲、暂存缓冲）多是自动释放的，调用线程是长活的会话线程、没有自己的池：
//   不包一层的话它们连同引用的贴图一直不放，每在游戏中回一次快照图形内存涨一份（Mac 11-21：IOAccelerator 661 → 1229 → 1843 → 2458 MB）
static int nvn_snap_restore_body(const char *dir);
int nvn_snap_restore(const char *dir) { @autoreleasepool { return nvn_snap_restore_body(dir); } }
static int nvn_snap_restore_body(const char *dir) {
    g_snap_restored = 1;
    char p[1200]; nvn_snap_live lv; int ok = 1;
    // 分步计时（11-17 iPhone 大金刚「核对」1.09 s，其中图形一段要拆开看）：命令块 / 回放层表 / 共享存储贴图 / GPU 私有贴图 / 只读普通贴图 / 预排布贴图 / 后端状态 + 视频
    double tg[9]; int ng = 0; tg[ng++] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
#define SNAP_TG() (tg[ng < 9 ? ng++ : 8] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9)
    g_snap_newtex_log = 600;
    if (s2a_gl_first_use) s2a_gl_first_use(); else MLOG("【红】 即时存档恢复：宿主没有着色器路径初始化入口");
    { snprintf(p, sizeof p, "%s/gfx_live.bin", dir); FILE *f = fopen(p, "rb"); ok = f && snap_fread(&lv, sizeof lv, 1, f, "mtl.live") && lv.magic == 0x31534E4Eu; if (f) fclose(f); }
    if (!ok) { MLOG("【红】 即时存档恢复：图形计数器读不了"); return -1; }
    g_snap_pkg_old = lv.ver < 2;
    uint64_t ca = 0, cu = 0, vu = 0; if (s2a_snap_arena_get) s2a_snap_arena_get(&ca, &cu, &vu);
    if (ca != lv.ca_base) { MLOG("【红】 即时存档恢复：命令记录区基址不同（快照 %#llx，本进程 %#llx），命令句柄放不回原地址", (unsigned long long)lv.ca_base, (unsigned long long)ca); return -1; }
    nvn_serial_floor(lv.serial + 1);
    // 命令记录宿主块：按原地址放回（区里本来就是本进程的保留），区的游标接到 A 的已用量之后
    { snprintf(p, sizeof p, "%s/gfx_shadow.bin", dir); FILE *f = fopen(p, "rb"); int nd = 0; uint64_t bytes = 0;
      while (ok && f) { uint32_t t; if (!fr_r(f, &t, 4) || t == FR_REC_END) break;
          if (t == FR_REC_REGION) { uint64_t hd[3]; ok = fr_r(f, hd, sizeof hd) && mmap((void *)(uintptr_t)hd[0], hd[1], PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) == (void *)(uintptr_t)hd[0]; continue; }
          uint64_t dh[2]; ok = fr_r(f, dh, sizeof dh);
          if (ok && !fr_rw_mapped(dh[0], dh[1])) { MLOG("【红】 即时存档恢复：命令记录宿主块 %#llx+%#llx 不在区里", (unsigned long long)dh[0], (unsigned long long)dh[1]); ok = 0; break; }
          ok = ok && fr_r(f, (void *)(uintptr_t)dh[0], dh[1]); nd++; bytes += dh[1]; }
      if (f) fclose(f); if (!f) ok = 0;
      if (s2a_snap_arena_set) s2a_snap_arena_set(lv.ca_used, lv.va_used);
      MLOG("%s即时存档恢复：命令记录宿主块 %d 块 %.1f MB 放回原地址", ok ? "" : "【红】", nd, bytes / 1048576.0); }
    if (!ok) return -1;
    SNAP_TG();
    { snprintf(p, sizeof p, "%s/gfx_progkeys.bin", dir); FILE *f = fopen(p, "rb"); ok = f && s2a_hle_pk_load(f) >= 0; if (f) fclose(f); }
    { snprintf(p, sizeof p, "%s/gfx_vpool.bin", dir); FILE *f = fopen(p, "rb"); ok = ok && f && s2a_hle_vpool_load(f) >= 0; if (f) fclose(f); }
    { snprintf(p, sizeof p, "%s/gfx_hle.bin", dir); FILE *f = fopen(p, "rb"); ok = ok && f && hle_snap_restore(f) == 0; if (f) fclose(f); }
    int ntreg = 0; snprintf(p, sizeof p, "%s/gfx_state.bin", dir); ok = ok && fr_restore_state(p, &ntreg);
    if (!ok) { MLOG("【红】 即时存档恢复：图形回放层表恢复失败"); return -1; }
    // 栅栏 / 出图序号：游戏内存里的同步对象与窗口票据记的是 A 的数，B 从 A 的值接着数（都已完成）
    snap_seq_rewind(lv.fence > lv.done ? lv.fence : lv.done, lv.pq_in);
    atomic_store(&g_cur_frame, lv.frame);
    { snprintf(p, sizeof p, "%s/gfx_gs.bin", dir); FILE *f = fopen(p, "rb"); int in = f && nvn2_snap_gs_restore ? nvn2_snap_gs_restore(f) : -1; if (f) fclose(f);
      if (in < 0) { MLOG("【红】 即时存档恢复：图形系统启动记账读不了"); return -1; } }
    SNAP_TG();
    { snprintf(p, sizeof p, "%s/gfx_alias.bin", dir); if (snap_alias_restore(p)) { MLOG("【红】 即时存档恢复：共享存储贴图读不了"); return -1; } }
    SNAP_TG();
    {   // GPU 私有贴图：gpu.bin 里每张按序号找游戏里的贴图对象，先建出 Metal 贴图，再整份写回内容
        nvn_hmap addr = {0}; nvn_hm_init(&addr, 8); uint64_t r[2]; int na = 0, made = 0, put = 0, miss = 0;
        snprintf(p, sizeof p, "%s/gfx_texaddr.bin", dir); FILE *f = fopen(p, "rb");
        while (f && fr_r(f, r, sizeof r)) { nvn_hm_put(&addr, &r[0], (void *)(uintptr_t)r[1]); na++;
            if (snap_on()) { pthread_mutex_lock(&g_smu); if (!g_snap_texaddr.klen) nvn_hm_init(&g_snap_texaddr, 8); nvn_hm_put(&g_snap_texaddr, &r[0], (void *)(uintptr_t)r[1]); pthread_mutex_unlock(&g_smu); } }   // 恢复局里再存：快照前建的贴图也要在表里
        if (f) fclose(f);
        snprintf(p, sizeof p, "%s/gfx_gpu.bin", dir); f = fopen(p, "rb"); uint32_t mg = 0;
        if (f && fr_r(f, &mg, 4) && mg == FR_GPU_MAGIC) { fr_tex_hd hd;
            while (snap_fread(&hd, sizeof hd, 1, f, "mtl.tex_hd")) { const tex_t *t = nvn_hm_get(&addr, &hd.ser); if (t && t->serial == hd.ser && tex_mtl(t)) made++; fr_skip_tex(f, &hd); } }
        if (f) fclose(f);
        snap_up_sync();
        fr_restore_gpu(p, &put, &miss);
        MLOG("即时存档恢复：GPU 私有贴图 按地址建 %d 张（地址表 %d 项），内容写回 %d 张、没写回 %d 张", made, na, put, miss);
        SNAP_TG();
        {   int qp = 0, qm = 0, qmade = 0; snprintf(p, sizeof p, "%s/gfx_plain.bin", dir); FILE *pf = fopen(p, "rb"); fr_tex_hd hd;
            while (pf && snap_fread(&hd, sizeof hd, 1, pf, "mtl.tex_hd")) {
                const tex_t *tt = nvn_hm_get(&addr, &hd.ser); if (tt && tt->serial == hd.ser && tex_mtl(tt)) qmade++;
                id o = tex_get(hd.ser); id<MTLTexture> mt = [o conformsToProtocol:@protocol(MTLTexture)] ? o : nil;
                if (!mt || mt.width != hd.w || mt.height != hd.h || (uint32_t)mt.pixelFormat != hd.fmt || mt.mipmapLevelCount != hd.levels) { fr_skip_tex(pf, &hd); qm++; continue; }
                id<MTLBuffer> b = [g_dev newBufferWithLength:hd.bytes options:MTLResourceStorageModeShared];
                if (!b || !fr_r_tex(pf, &hd, b.contents)) { qm++; break; }
                snap_up_sync(); if (fr_blit_planes(mt, &hd, b, 0)) qp++; else qm++;
            }
            if (pf) fclose(pf);
            MLOG("即时存档恢复：只读的显卡私有普通贴图 按地址建 %d 张，写回 %d 张、没写回 %d 张", qmade, qp, qm); }
        SNAP_TG();
        g_snap_addr_lk = &addr; hle_snap_ft_restore(snap_addr_lookup); g_snap_addr_lk = NULL;
        int pp = 0, pm = 0; snprintf(p, sizeof p, "%s/gfx_pkg.bin", dir); snap_put_pkg(p, &addr, &pp, &pm);
        MLOG("即时存档恢复：GPU 写过的预排布贴图 写回 %d 张、没写回 %d 张", pp, pm);
        if (g_snap_pkg_zero) MLOG("即时存档恢复：旧快照里预排布贴图 %d 张的记录内容全零（存的时候显卡内容已被系统清掉），不写回，用按客体内存建的那张", g_snap_pkg_zero);
    }
    SNAP_TG();
    { snprintf(p, sizeof p, "%s/gfx_mtl.bin", dir); FILE *f = fopen(p, "rb"); int r = f ? snap_mtl_restore(f) : -1; if (f) fclose(f);
      if (r) { MLOG("【红】 即时存档恢复：后端延续状态读不了"); return -1; } }
    { snprintf(p, sizeof p, "%s/gfx_codec.bin", dir); FILE *f = fopen(p, "rb"); int nc = f && nvn2_snap_codec_restore ? nvn2_snap_codec_restore(f) : -1; if (f) fclose(f);
      if (nc < 0) { MLOG("【红】 即时存档恢复：视频解码器表读不了"); return -1; } if (nc) MLOG("即时存档恢复：视频解码器 %d 个按原参数重建", nc); }
    { snprintf(p, sizeof p, "%s/gfx_gl.bin", dir); if (!access(p, F_OK)) { if (!gl_snap_restore || gl_snap_restore(p)) { MLOG("【红】 即时存档恢复：GL 出图层状态没恢复"); return -1; } } }
    { snprintf(p, sizeof p, "%s/gfx_vk.bin", dir); if (!access(p, F_OK)) { if (!vk_snap_restore || vk_snap_restore(p)) { MLOG("【红】 即时存档恢复：Vulkan 出图层状态没恢复"); return -1; } } }
    SNAP_TG();
    if (ng == 8) MLOG("即时存档恢复：图形拆账 命令块 %.2f、回放层表 %.2f、共享存储贴图 %.2f、GPU 私有贴图 %.2f、只读普通贴图 %.2f、预排布贴图 %.2f、后端状态 + 视频 %.2f（秒）",
                      tg[1] - tg[0], tg[2] - tg[1], tg[3] - tg[2], tg[4] - tg[3], tg[5] - tg[4], tg[6] - tg[5], tg[7] - tg[6]);
#undef SNAP_TG
    MLOG("即时存档恢复：图形 贴图登记 %d 个、栅栏接到 %llu、出图序号接到 %llu、对象序号下限 %llu、帧 %llu（GPU 私有贴图首版不写回）", ntreg, (unsigned long long)g_fence, (unsigned long long)lv.pq_in, (unsigned long long)lv.serial + 1, (unsigned long long)lv.frame);
    return 0;
}
// 即时存档验证：抓下一次上屏的画面存 PNG（阻塞至多 3 秒）。A 在冻结前抓「存档时刻」，B 恢复后按时刻抓，两边对比
int nvn_snap_redump(const char *dir) {   // 诊断：游戏跑着时重存预排布贴图与 GPU 贴图（与快照同格式），供逐张对比
    char p[1200]; uint64_t b = 0; int sk = 0;
    snprintf(p, sizeof p, "%s/b5_pkg.bin", dir); int n1 = snap_dump_pkg(p, &b);
    snprintf(p, sizeof p, "%s/b5_gpu.bin", dir); int n2 = fr_dump_gpu(p, &b, &sk);
    MLOG("即时存档诊断：恢复后重存 预排布 %d 张、GPU 贴图 %d 张", n1, n2);
    // 往返自检：每张预排布贴图 读出 → 写进同描述新贴图 → 再读出，两次字节比对（判写回函数是否与导出互逆）
    NSMutableArray *objs = [NSMutableArray array];
    pthread_mutex_lock(&g_smu); for (uint32_t i = 0; i < g_by_serial.cap; i++) if (g_by_serial.vals[i]) { id o = (__bridge id)g_by_serial.vals[i]; if ([o isKindOfClass:[NvPkg class]] && ((NvPkg *)o)->tex) [objs addObject:((NvPkg *)o)->tex]; } pthread_mutex_unlock(&g_smu);
    int same = 0, diff = 0, skip = 0;
    for (id<MTLTexture> t in objs) {
        fr_tex_hd hd = {0, (uint32_t)t.textureType, (uint32_t)t.pixelFormat, (uint32_t)t.width, (uint32_t)t.height, (uint32_t)t.depth, (uint32_t)fr_slices(t), (uint32_t)t.mipmapLevelCount, FR_TK_PLAIN, 1};
        hd.nplane = (uint32_t)fr_planes(t.pixelFormat, hd.pl); uint64_t tot = 0;
        for (uint32_t q = 0; q < hd.nplane; q++) for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) tot += fr_plane_bytes(&hd.pl[q], MAX(1, t.width >> l), MAX(1, t.height >> l), MAX(1, t.depth >> l)) * hd.layers;
        if (!hd.nplane || !tot || t.sampleCount > 1) { skip++; continue; }
        MTLTextureDescriptor *d = [MTLTextureDescriptor new]; d.textureType = t.textureType; d.pixelFormat = t.pixelFormat; d.width = t.width; d.height = t.height; d.depth = t.depth; d.mipmapLevelCount = t.mipmapLevelCount; d.arrayLength = t.arrayLength; d.usage = t.usage; d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> u = [g_dev newTextureWithDescriptor:d];
        id<MTLBuffer> b1 = [g_dev newBufferWithLength:tot options:MTLResourceStorageModeShared], b2 = [g_dev newBufferWithLength:tot options:MTLResourceStorageModeShared];
        if (!u || !b1 || !b2 || !fr_blit_planes(t, &hd, b1, 1) || !fr_blit_planes(u, &hd, b1, 0) || !fr_blit_planes(u, &hd, b2, 1)) { skip++; continue; }
        if (!memcmp(b1.contents, b2.contents, tot)) same++;
        else { diff++; if (diff <= 12) { const uint8_t *x = b1.contents, *y = b2.contents; uint64_t first = 0; while (first < tot && x[first] == y[first]) first++;
            MLOG("即时存档诊断：往返不一致 Metal 格式 %d %lux%lu 级 %lu 首个不同字节 %llu / %llu", (int)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.mipmapLevelCount, (unsigned long long)first, (unsigned long long)tot); } }
    }
    MLOG("即时存档诊断：预排布贴图往返自检 一致 %d、不一致 %d、跳过 %d", same, diff, skip);
    return 0;
}
// 快照缩略图（游戏库卡片 / 存完提示 / 启动器 / 备份清单用，不读整帧图）：读 src（整帧 PNG），等比放大到盖满 w×h、居中裁掉多出的部分，写 dst（PNG）。0 = 写好了
int nvn_snap_thumb(const char *src, const char *dst, int w, int h) {
    int ok = 0;
    CFURLRef su = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)src, (CFIndex)strlen(src), false);
    CGImageSourceRef is = su ? CGImageSourceCreateWithURL(su, NULL) : NULL;
    CGImageRef img = is ? CGImageSourceCreateImageAtIndex(is, 0, NULL) : NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = img ? CGBitmapContextCreate(NULL, (size_t)w, (size_t)h, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : NULL;
    if (ctx) {
        double iw = (double)CGImageGetWidth(img), ih = (double)CGImageGetHeight(img), k = fmax(w / iw, h / ih);   // 盖满：取大的比例，多出的一边居中裁掉
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake((w - iw * k) / 2, (h - ih * k) / 2, iw * k, ih * k), img);
        CGImageRef t = CGBitmapContextCreateImage(ctx);
        CFURLRef du = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)dst, (CFIndex)strlen(dst), false);
        CGImageDestinationRef d = du && t ? CGImageDestinationCreateWithURL(du, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL) : NULL;
        if (d) { CGImageDestinationAddImage(d, t, NULL); ok = CGImageDestinationFinalize(d); CFRelease(d); }
        if (du) CFRelease(du); CGImageRelease(t); CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs); CGImageRelease(img); if (is) CFRelease(is); if (su) CFRelease(su);
    MLOG("%s即时存档：缩略图 %d×%d %s %s", ok ? "" : "【黄】 ", w, h, ok ? "存到" : "没存成", dst);
    return ok ? 0 : -1;
}
// 验证截图：取「下一次出图」的画面。取图钩子只有一个槽，自动玩家截图等也用它，后来的请求会把前面的回调盖掉（11-17：iPhone 上第 5 / 20 秒两张逐字节相同、
//   Mac 上第 20 秒那张等不到）：3 秒没等到就重新请求，最多 3 次；回调里记下截自第几帧
int nvn_snap_grab(const char *path) {
    for (int attempt = 1; attempt <= 3; attempt++) {
        __block int done = 0; char *pp = strdup(path); int at = attempt;
        mtl_grab_next_present(^(const uint8_t *bgra, size_t w, size_t h, size_t row) {
            uint8_t *cp = malloc(row * h); if (cp) { memcpy(cp, bgra, row * h); fr_png(pp, cp, w, h, row); free(cp); }
            MLOG("即时存档：验证截图 %s 取自第 %llu 帧（第 %d 次请求）", pp, (unsigned long long)atomic_load(&g_cur_frame), at);
            free(pp); __atomic_store_n(&done, 1, __ATOMIC_RELEASE); });
        for (int i = 0; i < 300 && !__atomic_load_n(&done, __ATOMIC_ACQUIRE); i++) usleep(10000);
        if (done) return 0;
        MLOG("【黄】 即时存档：验证截图 %s 第 %d 次请求 3 秒内没等到（取图槽可能被别的请求占了），重新请求", path, attempt);
    }
    return -1;
}
// 测试开关 DM_TEST_BG_LOSE 用（nvn_mtl.m nvn_be_background_purge）：把一张贴图的内容写成全零
static void snap_test_zero(id<MTLTexture> t) {
    fr_tex_hd hd = {0, (uint32_t)t.textureType, (uint32_t)t.pixelFormat, (uint32_t)t.width, (uint32_t)t.height, (uint32_t)t.depth, (uint32_t)fr_slices(t), (uint32_t)t.mipmapLevelCount, FR_TK_PLAIN, (uint32_t)t.sampleCount};
    if (t.sampleCount > 1) return;
    hd.nplane = (uint32_t)fr_planes(t.pixelFormat, hd.pl); if (!hd.nplane) return;
    uint64_t tot = 0;
    for (uint32_t q = 0; q < hd.nplane; q++) for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) tot += fr_plane_bytes(&hd.pl[q], MAX(1, t.width >> l), MAX(1, t.height >> l), MAX(1, t.depth >> l)) * hd.layers;
    if (!tot || tot > (256ull << 20)) return;
    id<MTLBuffer> b = [g_dev newBufferWithLength:tot options:MTLResourceStorageModeShared]; if (!b) return;
    memset(b.contents, 0, tot); fr_blit_planes(t, &hd, b, 0);
}
