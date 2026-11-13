// General geometry replay: native VS capture -> GS compute -> ordered index
// compaction -> ordinary rendering. Included after the resource/pipeline helpers.
#define GEO_RED(...) do { nvn_be_bad_draw_feat(); MLOG(__VA_ARGS__); } while (0)   // S2Arm: a geometry draw dropped counts for the picture check (mtl_bad_draws)
static NvProg *g_geo_program;
static uint64_t g_geo_indices, g_geo_index_bytes, g_geo_args;
static void draw(const p_draw *dw, const p_draw_idx *di);
static void lc_land(void);

// ---------- S2Arm transform feedback past the vertex stage (10-26, Xenoblade 3: particle geometry shader c01e3ade8e15a842 captures 11 outputs, then DrawTransformFeedback) ----------
// A geometry shader's capture: geo_tf after the compaction, the kernels in nvn_geometry.h. How many vertices it emitted is known on the GPU only, so from the first such capture in a
// Begin the offsets live in g_tf_cnt (bytes per buffer); before it they are the host's tf_off (vertex captures, tf_draw). End / Pause keep a Begin's counts by its control buffer
// (g_tfs: copied on the GPU when they are there); DrawTransformFeedback(mode, address) draws bytes / stride vertices of the buffer whose entry the address names, 8 bytes per buffer
// from the control buffer (taken for the NVN driver's 32-byte control buffer: 4 buffers; the first case is logged with the alternatives, to be checked), stride = vertex stream 0's
// (the hardware's DrawAuto stride), the capture's when that is 0
static id<MTLBuffer> g_tf_cnt, g_tf_snapbuf; static uint64_t g_tf_cnt_gpu;
static id<MTLComputePipelineState> g_tf_ps[4];   // geo_tf_write, geo_tf_count, tf_draw_args, tf_snap
static uint32_t g_tf_last_stride[4];             // bytes per vertex of the latest capture into each buffer
enum { TFS_N = 64 };
static struct { uint64_t ctl; int gpu; uint32_t bytes[4], stride[4]; } g_tfs[TFS_N]; static int g_tfs_next;
static uint64_t g_tfd_args;   // the DrawTransformFeedback being drawn: GPU address of its MTLDrawPrimitivesIndirectArguments (draw)
static int tf_init(void) {
    if (g_tf_ps[3]) return 1;
    static int failed; if (failed) return 0;
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_nvn_geo_tf_msl) options:nil error:&e];
    const char *nm[4] = {"geo_tf_write", "geo_tf_count", "tf_draw_args", "tf_snap"};
    for (int i = 0; lib && i < 4; i++) g_tf_ps[i] = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(nm[i])] error:&e];
    g_tf_cnt = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; g_tf_snapbuf = [g_dev newBufferWithLength:16 * TFS_N options:MTLResourceStorageModeShared];
    if (!g_tf_ps[3] || !g_tf_cnt || !g_tf_snapbuf) { failed = 1; GEO_RED("【红】 transform feedback kernels: %s", e ? e.localizedDescription.UTF8String : "no buffer"); return 0; }
    res_add(g_tf_cnt); res_add(g_tf_snapbuf); g_tf_cnt_gpu = g_tf_cnt.gpuAddress;
    return 1;
}
// After geo_pack_indices (rec = the output records, idx / args = the compacted list and its count): write each feedback buffer the geometry shader captures into
static int geo_tf(NvShader *gs, uint64_t rec, uint64_t idx, uint64_t args, uint64_t capacity) {
    if (!tf_init()) return 0;
    nvn_geo_tf j = {.rec = rec, .idx = idx, .args = args, .cnt = g_tf_cnt_gpu, .use_cnt = (uint32_t)S.tf_gpu, .rec_words = gs->geo_stride,
                    .per_prim = gs->geo_output == 1 ? 1 : gs->geo_output == 6 ? 2 : 3};
    for (int b = 0; b < 4; b++) {
        if (!gs->geo_tf_stride[b]) continue;
        void *mb; uint64_t mo, g;
        if (!S.tf[b].addr || !S.tf[b].size || !mtl_gpu_addr(S.tf[b].addr, S.tf[b].size, &mb, &mo, &g)) {
            GEO_RED("【红】 geometry transform feedback buffer %d of %s is unbound or in no memory pool (%#llx + %llu): not captured", b, gs->key, (unsigned long long)S.tf[b].addr, (unsigned long long)S.tf[b].size); return 0; }
        j.dst[b] = g; j.size[b] = (uint32_t)MIN(S.tf[b].size, UINT32_MAX); j.stride[b] = gs->geo_tf_stride[b]; j.start[b] = (uint32_t)S.tf_off[b]; j.ne[b] = gs->geo_tf_n[b];
        memcpy(j.off[b], gs->geo_tf_off[b], sizeof j.off[b]); memcpy(j.comp[b], gs->geo_tf_comp[b], sizeof j.comp[b]);
        g_tf_last_stride[b] = gs->geo_tf_stride[b];
        pend_add(S.tf[b].addr, S.tf[b].size, 4);   // how far it reaches is known on the GPU only: the whole buffer
    }
    id<MTLBuffer> ab; size_t ao = arena_alloc(sizeof j, &ab); memcpy((uint8_t *)ab.contents + ao, &j, sizeof j); uint64_t jg = ab.gpuAddress + ao;
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin(NULL); enc_c_pso(ce, g_tf_ps[0]); enc_c_args(ce, jg, 0);
    enc_c_dispatch(ce, MTLSizeMake((capacity + 63) / 64, 1, 1), MTLSizeMake(64, 1, 1)); enc_c_end(ce);
    ce = enc_c_begin(NULL); enc_c_pso(ce, g_tf_ps[1]); enc_c_args(ce, jg, 0); enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1)); enc_c_end(ce);
    S.tf_gpu = 1;
    static int once; if (!once++) MLOG("transform feedback: first geometry capture (%s, buffer 0 %u bytes per vertex, %u entries)", gs->key, gs->geo_tf_stride[0], gs->geo_tf_n[0]);
    return 1;
}
// Replay of End / Pause (before state_op): keep this Begin's counts under its control buffer
static void tf_state_end(const p_tf_state *b) {
    if ((b->what != 1 && b->what != 2) || !S.tf_on) return;
    int k = g_tfs_next; g_tfs_next = (g_tfs_next + 1) % TFS_N;
    g_tfs[k].ctl = b->ctl ? b->ctl : S.tf_ctl; g_tfs[k].gpu = S.tf_gpu;
    for (int i = 0; i < 4; i++) { g_tfs[k].bytes[i] = (uint32_t)S.tf_off[i]; g_tfs[k].stride[i] = g_tf_last_stride[i]; }
    if (!S.tf_gpu || !tf_init()) return;
    if (defer_has_active()) defer_fallback();
    lc_land(); rp_flush(); rp_end(); ubd_land();
    nvn_tf_args j = {.cnt = g_tf_cnt_gpu, .args = g_tf_snapbuf.gpuAddress + 16 * (uint64_t)k};
    id<MTLBuffer> ab; size_t ao = arena_alloc(sizeof j, &ab); memcpy((uint8_t *)ab.contents + ao, &j, sizeof j);
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin(NULL); enc_c_pso(ce, g_tf_ps[3]); enc_c_args(ce, ab.gpuAddress + ao, 0);
    enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1)); enc_c_end(ce);
}
// DrawTransformFeedback at replay: the indirect arguments (GPU address, 0 = nothing to draw); draw then draws them (g_tfd_args)
static uint64_t tfd_args(const p_draw *d) {
    int k = -1; uint64_t a = d->tfc;
    for (int i = 0; i < TFS_N && k < 0; i++) { int x = (g_tfs_next - 1 - i + TFS_N) % TFS_N; if (g_tfs[x].ctl && a >= g_tfs[x].ctl && a < g_tfs[x].ctl + 32) k = x; }
    if (k < 0 && a == 1) k = (g_tfs_next - 1 + TFS_N) % TFS_N;   // no address given: the latest
    if (k < 0 || !g_tfs[k].ctl) { nvn_be_bad_draw_feat(); RED_ONCE(127, "DrawTransformFeedback: counter address %#llx is in no ended capture's control buffer: not drawn", (unsigned long long)a); return 0; }
    uint32_t b = (uint32_t)((a - g_tfs[k].ctl) / 8) & 3, stride = S.stream[0].stride ? S.stream[0].stride : g_tfs[k].stride[b];
    static int once; if (!once++) MLOG("DrawTransformFeedback: first draw (mode %d, counter %#llx = control buffer %#llx + %llu → buffer %u; vertex stream 0 stride %u, capture stride %u; counts %s)",
        d->prim, (unsigned long long)a, (unsigned long long)g_tfs[k].ctl, (unsigned long long)(a - g_tfs[k].ctl), b, S.stream[0].stride, g_tfs[k].stride[b], g_tfs[k].gpu ? "on the GPU" : "on the CPU");
    if (!stride) { nvn_be_bad_draw_feat(); RED_ONCE(121, "DrawTransformFeedback: no stride (vertex stream 0 and the capture both 0): not drawn"); return 0; }
    id<MTLBuffer> ab; size_t ao = arena_alloc(32, &ab); uint8_t *p = (uint8_t *)ab.contents + ao; uint64_t g = ab.gpuAddress + ao;
    if (!g_tfs[k].gpu) { uint32_t arg[4] = {g_tfs[k].bytes[b] / stride, 1, 0, 0}; memcpy(p, arg, 16); return arg[0] ? g : 0; }
    if (!tf_init()) return 0;
    if (defer_has_active()) defer_fallback();
    lc_land(); rp_flush(); rp_end(); ubd_land();
    nvn_tf_args j = {.cnt = g_tf_snapbuf.gpuAddress + 16 * (uint64_t)k, .args = g, .b = b, .stride = stride}; memcpy(p + 16, &j, sizeof j);
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin(NULL); enc_c_pso(ce, g_tf_ps[2]); enc_c_args(ce, g + 16, 0);
    enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1)); enc_c_end(ce);
    return g;
}

static id<MTLRenderPipelineState> geo_capture_pso(NvShader *vs) {
    pso_key k; static const uint32_t cf[8]; pso_key_fill(&k, vs, nil, cf, 0, 0, 1, 0); k.fsfn = GEO_MARK;
    id<MTLRenderPipelineState> ps = hm_get_id(&g_pso, &k);
    if (ps || hm_get_id(&g_pso_fail, &k)) return ps;
    NSError *e = nil;
    ps = [g_dev newRenderPipelineStateWithDescriptor:pso_desc(&k, vs, nil, nil, 0) error:&e];
    if (ps) hm_put_id(&g_pso, &k, ps);
    else { hm_put_id(&g_pso_fail, &k, NSNull.null); MLOG("【红】 geometry vertex capture %s: %s", vs->key, e.localizedDescription.UTF8String); }
    return ps;
}
// ---------- NVN2 task / mesh draws: nvnCommandBufferDrawMeshTasks / DrawMeshTasksIndirect (11-05, The Legend of Zelda: Ocarina of Time 0400486024DEC000's 3D scenes) ----------
// A program's task and mesh shaders are Metal object and mesh functions (the translation's [[object]] / [[mesh]] main0, mesh main0_z for near = 0), kept at stages 3 / 4 (nvn2_cmd.h
// nvn2_stage_host; NvShader.mesh_kind tells them from hull / domain shaders). The draw goes through draw() with a program of its pixel stage alone, as a geometry draw's raster stage
// does, so it takes the render pass, the depth / blend / viewport state and the fragment arguments like any draw; draw() asks mtk_pso for its pipeline and mtk_encode binds and draws.
// The mesh stage shares the vertex stage's argument table (it has no vertex fetch: vertex-table slot 29 is vertex stream 13's, VB_SLOT, rebound through the enc_r_vbuf cache by the
// next vertex draw), a task shader has the object table g_ot; both read the draw's first workgroup at buffer MESH_FIRST_SLOT (interface contract item 3). Indirect: the GPU-written
// {count, first} become MTLDispatchThreadgroupsIndirectArguments {count, 1, 1} with first at word 4 on the GPU (ixc_run), so neither is read on the CPU.
// A pipeline is built in the background (g_mtk_q); until it is ready the draw is skipped and counted (g_mtk_wait), a refused one is reported red once and its draws skipped.
// After the upstream reference (MIT) 1d4b8e82b / #1312 (MIT): mesh_tasks_draw / mtk_pso / mtk_encode, written for this host's two backends, recording and binding state
enum { MESH_FIRST_SLOT = 29 };
_Static_assert(VB_SLOT(13) == MESH_FIRST_SLOT, "slot 29 of the vertex table is vertex stream 13's: a mesh draw writes it through enc_r_vbuf so the next vertex draw rebinds the stream (see above)");
static struct { int on, miss; NvShader *ts, *ms; uint32_t first, count; uint64_t ind; } g_mtk;   // the draw being encoded (on: draw() is drawing it)
typedef struct { pso_key k; const void *ts; uint32_t pad; } mtk_key;   // pso_key with the mesh shader in its vertex place, the task shader (the pipeline's third function), and the user(locn) mask of the padded mesh variant used (0 = none)
static nvn_hmap g_pso_mtk = {.klen = sizeof(mtk_key)}; static os_unfair_lock g_pso_mtk_lock = OS_UNFAIR_LOCK_INIT;
static NSObject *g_pso_mtk_building; static dispatch_queue_t g_mtk_q; static dispatch_group_t g_mtk_group;
static uint64_t g_mtk_n, g_mtk_ind_n, g_mtk_wait, g_mtk_skip;   // drawn (of them indirect), skipped while the pipeline was built, skipped as not drawable (red)
// #770 实验开关 S2A_MESH_PACE（缺省 0 = 关，照旧建好即交付）：M1 Max（没有硬件网格着色，驱动走软件网格）换图时 GPU 挂死，都紧跟某条网格管线交付、
//   且发生在多条网格管线排队待交付时；跳过网格绘制不挂；清掉系统缓存全部现编照样挂（作者 11-12 反例，所以不是缓存）。两档各验一个假设：
//   1 = 建好的先攒着，后台一条都不在编了才一起交付（假设：新管线首次上 GPU 时编译服务还在编下一条软件网格管线 → 挂）；
//   2 = 每帧最多交付一条（假设：同一帧里几条新管线首次上 GPU → 挂）。交付和每条管线第一次被画都记帧号与还在编的条数，挂死前最后几行能对上是哪种
static int mtk_pace(void) {
    static int v = -1; if (v >= 0) return v;
    const char *e = getenv("S2A_MESH_PACE"); v = e && (*e == '1' || *e == '2') && !e[1] ? *e - '0' : 0;
    if (v) MLOG("task / mesh pipelines: pace %d (S2A_MESH_PACE: %s)", v, v == 1 ? "deliver only when no mesh pipeline is still building" : "deliver at most one per frame");
    return v;
}
static _Atomic int g_mtk_inflight;   // mesh pipelines queued or building in the background
static NSMutableArray *g_mtk_ready;   // pace on: built, not delivered yet (each @[NSData key, pipeline or NSNull]); under g_pso_mtk_lock
static uint64_t g_mtk_pub_frame = UINT64_MAX;
static NSMutableSet *g_mtk_drawn;   // pipelines already drawn once (first-draw log)
static NSMapTable *g_mtk_names;   // pipeline → "task … mesh … fragment …" for the #770 logs (not the pipeline's label: -label is also a Metal 4 encoder selector, t_nvn_rec_cover); under g_pso_mtk_lock
static const char *mtk_name(id p) { if (!p || p == NSNull.null) return "(refused)"; os_unfair_lock_lock(&g_pso_mtk_lock); NSString *n = [g_mtk_names objectForKey:p]; os_unfair_lock_unlock(&g_pso_mtk_lock); return n ? n.UTF8String : "?"; }
static void mtk_publish(void) {   // pace on, submit thread, before a mesh draw looks its pipeline up
    int pace = mtk_pace(); if (!pace || !g_mtk_ready.count) return;
    uint64_t f = atomic_load_explicit(&g_cur_frame, memory_order_relaxed); int fly = atomic_load(&g_mtk_inflight);
    if (pace == 1 && fly) return;
    if (pace == 2 && f == g_mtk_pub_frame) return;
    os_unfair_lock_lock(&g_pso_mtk_lock);
    NSUInteger n = pace == 2 ? 1 : g_mtk_ready.count;
    for (NSUInteger i = 0; i < n; i++) { NSArray *r = g_mtk_ready[i]; mtk_key kk; [(NSData *)r[0] getBytes:&kk length:sizeof kk]; hm_put_id(&g_pso_mtk, &kk, r[1]); }
    NSArray *done = [g_mtk_ready subarrayWithRange:NSMakeRange(0, n)]; [g_mtk_ready removeObjectsInRange:NSMakeRange(0, n)]; NSUInteger left = g_mtk_ready.count;
    os_unfair_lock_unlock(&g_pso_mtk_lock);
    g_mtk_pub_frame = f;
    for (NSArray *r in done) MLOG("task / mesh pipeline delivered (pace %d) at frame %llu: %s; still building %d, built and held %lu", pace, (unsigned long long)f,
                                  mtk_name(r[1]), fly, (unsigned long)left);
}
static id<MTLRenderPipelineState> mtk_pso(NvProg *raster) {
    NvShader *ts = g_mtk.ts, *ms = g_mtk.ms, *fs = raster->sh[1]; int merged = g_pso_lmap != NULL;
    mtk_key mk; memset(&mk, 0, sizeof mk); pso_key *k = &mk.k;
    pso_key_fill(k, ms, fs, g_pass.cfmt, g_pass.dfmt, g_pass.sfmt, g_pass.samples, merged);
    memset(k->attr, 0, sizeof k->attr); memset(k->stream, 0, sizeof k->stream);   // no vertex fetch
    if (merged) { memcpy(k->lmap, g_pso_lmap, 8); k->fsfn = (__bridge void *)g_pso_fsfn; }   // as pso_get_vs keys a merged pass's pipeline
    if (g_pso_fc && !merged && !g_pso_fsfn && fs && !pso_fout_need(k, fs, 0)) k->fc = (uint8_t)g_pso_fc;
    g_pso_color_round = pso_color_round_mask(k, fs, merged);
    mk.ts = (__bridge void *)ts;
    // #674: a fragment shader the game pairs at run time with a mesh shader that does not write a user(locn) it reads (Metal refuses the pipeline). Mesh shaders carry no user_out in
    //   their json, so the miss is known from the refusal: then the padded mesh variant for every location the fragment reads is asked for (vp_ask, dm_shader_vpad → dm_mesh_pad_src:
    //   only the locations the mesh does not write get (0,0,0,1)); until it is ready the pair's draws are skipped as before, then the pipeline is built with it (its own cache entry)
    uint32_t want = fs && (fs->rf.has_user & 2) ? fs->rf.user_in : 0; id<MTLFunction> pf = want ? vp_fn(ms, want) : nil;
    if (pf) mk.pad = want;
    os_unfair_lock_lock(&g_pso_mtk_lock); __unsafe_unretained id ps = hm_get_id(&g_pso_mtk, &mk);
    if (!ps) { if (!g_pso_mtk_building) g_pso_mtk_building = [NSObject new]; hm_put_id(&g_pso_mtk, &mk, g_pso_mtk_building); }
    os_unfair_lock_unlock(&g_pso_mtk_lock);
    if (ps == NSNull.null && !mk.pad && want) vp_ask(S.prog, ms, want);   // refused unpadded: ask for the padded variant (once; a variant that cannot be made stays failed)
    if (ps && ps != NSNull.null && ps != g_pso_mtk_building) {   // #770: the first draw of each pipeline, with the frame and how many are still building
        if (!g_mtk_drawn) g_mtk_drawn = [NSMutableSet set];
        if (![g_mtk_drawn containsObject:ps]) { [g_mtk_drawn addObject:ps];
            MLOG("task / mesh pipeline first drawn at frame %llu: %s; still building %d", (unsigned long long)atomic_load_explicit(&g_cur_frame, memory_order_relaxed),
                 mtk_name(ps), atomic_load(&g_mtk_inflight)); }
    }
    if (ps) return ps == NSNull.null || ps == g_pso_mtk_building ? nil : ps;
    MTLRenderPipelineDescriptor *d = pso_desc(k, nil, fs, g_pso_fsfn, merged);   // the fragment function variant and the attachments, as a vertex draw's (no vertex stage)
    MTLMeshRenderPipelineDescriptor *m = [MTLMeshRenderPipelineDescriptor new];
    m.meshFunction = pf ?: ms->fn; m.fragmentFunction = d.fragmentFunction; m.maxTotalThreadsPerMeshThreadgroup = ms->mesh_threads;
    if (ts) { m.objectFunction = ts->fn; m.payloadMemoryLength = ts->mesh_relay ? 16 : ((NSUInteger)ts->mesh_payload + 15) & ~(NSUInteger)15; m.maxTotalThreadsPerObjectThreadgroup = ts->mesh_threads; }   // relayed: object_data carries the task workgroup alone
    m.rasterSampleCount = d.rasterSampleCount; m.alphaToCoverageEnabled = d.alphaToCoverageEnabled;
    for (int i = 0; i < 8; i++) m.colorAttachments[i] = d.colorAttachments[i];
    m.depthAttachmentPixelFormat = d.depthAttachmentPixelFormat; m.stencilAttachmentPixelFormat = d.stencilAttachmentPixelFormat;
    NSString *names = [NSString stringWithFormat:@"task %s mesh %s%s fragment %s", ts ? ts->key : "-", ms->key, pf ? " (padded)" : "", fs ? fs->key : "-"]; mtk_key kk = mk;
    atomic_fetch_add(&g_mtk_inflight, 1);
    if (!g_mtk_q) { g_mtk_q = dispatch_queue_create("dm.nvn.mesh", s2a_qos_queue_attr(DISPATCH_QUEUE_SERIAL, S2A_QOS_SHADER_VARIANT)); g_mtk_group = dispatch_group_create(); }
    dispatch_group_async(g_mtk_group, g_mtk_q, ^{ @autoreleasepool {
        NSError *e = nil; uint64_t t0 = bp_now();
        id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithMeshDescriptor:m options:MTLPipelineOptionNone reflection:nil error:&e];
        int left = atomic_fetch_sub(&g_mtk_inflight, 1) - 1;
        if (p) MLOG("task / mesh pipeline: %s, %.1f ms in the background (frame %llu, still building %d)", names.UTF8String, (bp_now() - t0) / 1e6,
                    (unsigned long long)atomic_load_explicit(&g_cur_frame, memory_order_relaxed), left);
        else MLOG("【红】 task / mesh pipeline refused (%s): %s; its draws are skipped", names.UTF8String, e.localizedDescription.UTF8String);
        os_unfair_lock_lock(&g_pso_mtk_lock);
        if (p) { if (!g_mtk_names) g_mtk_names = [NSMapTable strongToStrongObjectsMapTable]; [g_mtk_names setObject:names forKey:p]; }
        if (mtk_pace()) { if (!g_mtk_ready) g_mtk_ready = [NSMutableArray array]; [g_mtk_ready addObject:@[[NSData dataWithBytes:&kk length:sizeof kk], p ? (id)p : NSNull.null]]; }   // held: mtk_publish delivers
        else hm_put_id(&g_pso_mtk, &kk, p ?: NSNull.null);
        os_unfair_lock_unlock(&g_pso_mtk_lock);
    } });
    return nil;
}
static void mtk_encode(id en_) {
    id en = en_; NvShader *ts = g_mtk.ts, *ms = g_mtk.ms;
    uint64_t first = g_mtk.ind ? g_mtk.ind + 16 : 0;   // indirect: the converted arguments carry it at word 4 (ixc_arrays)
    if (!first) { id<MTLBuffer> b; size_t o = arena_alloc(16, &b); memcpy((uint8_t *)b.contents + o, &g_mtk.first, 4); first = b.gpuAddress + o; }
    enc_r_table(en, g_vt, MTLRenderStageMesh);
    if (ts) { enc_r_table(en, g_ot, MTLRenderStageObject); g_args_object = 1; encode_args(en, ts, 3, 0); g_args_object = 0; enc_o_args(first, MESH_FIRST_SLOT); }
    encode_args(en, ms, 4, 1); enc_r_vbuf(en, MESH_FIRST_SLOT, first);
    // Payload relay (S2A.Dsh MeshStage.Relay: a payload past Metal's 16 KB): one buffer, head {mesh slice start (words), task workgroups, slices per task workgroup}, then one payload per
    //   task workgroup, then one mesh stage-memory slice per (task workgroup, mesh workgroup < the task's thread count, which the task clamps its grid to). Bound at the relay slot of the
    //   object table and of the mesh stage (vertex stream 11's slot, through enc_r_vbuf)
    if (ts && ts->mesh_relay) {
        uint64_t n = g_mtk.count, pw = ts->mesh_relay_pw, sw = ms->mesh_relay_sw, head = 8, base = (head + n * pw + 3) & ~3ull, grid = ts->mesh_threads, bytes = (base + n * grid * sw) * 4;
        id<MTLBuffer> rb; size_t ro = arena_alloc((size_t)bytes, &rb); uint32_t *h = (uint32_t *)((uint8_t *)rb.contents + ro); h[0] = (uint32_t)base; h[1] = (uint32_t)n; h[2] = (uint32_t)grid;
        enc_o_args(rb.gpuAddress + ro, ts->mesh_relay); enc_r_vbuf(en, ms->mesh_relay, rb.gpuAddress + ro);
        static int once; if (!once++) MLOG("task / mesh payload relay: first draw (task %s mesh %s), %llu task workgroups, %.1f MB", ts->key, ms->key, (unsigned long long)n, bytes / 1048576.0);
    }
    NSUInteger ot = ts ? ts->mesh_threads : 1, mt = ms->mesh_threads;
    if (g_mtk.ind) enc_r_mesh_indirect(en, g_mtk.ind, ot, mt); else enc_r_mesh(en, g_mtk.count, ot, mt);
}
static void mesh_tasks_draw(const p_draw *dw) {
    if (!dw->ind && dw->count <= 0) return;
    if (!g_mesh_ok) { g_mtk_skip++; RED_ONCE(149, "task / mesh draw: this GPU has no object / mesh pipelines (Apple7+ / Mac2): skipped"); return; }
    __unsafe_unretained NvProg *pr = S.prog ? prog_get(S.prog) : nil;
    NvShader *ms = pr ? pr->sh[4] : nil, *ts = pr ? pr->sh[3] : nil;
    if (!ms || ms->mesh_kind != 2 || !ms->mesh_task || (ts && ts->mesh_kind != 1)) ts = nil;   // a task shader only for a mesh shader that takes one (a hull shader of an earlier bind is not)
    if (ts && ts->mesh_relay && (dw->ind || !ms || !ms->mesh_relay || (uint64_t)dw->count * ts->mesh_threads * ms->mesh_relay_sw * 4 > (512ull << 20))) {   // relayed payload: the buffer is sized on the CPU from the workgroup count
        g_mtk_skip++; RED_ONCE(152, "task / mesh draw with a relayed payload (task %s): %s, skipped", ts->key, dw->ind ? "indirect (workgroup count not known on the CPU)" : !ms || !ms->mesh_relay ? "the mesh shader does not take a relayed payload" : "relay buffer past 512 MiB"); return; }
    if (!ms || ms->mesh_kind != 2 || !ms->fn || (ms->mesh_task && !ts)) {
        g_mtk_skip++; BAD_ERR(); RED_ONCE(147, "task / mesh draw without its shaders (task %s, mesh %s%s): skipped", pr && pr->sh[3] ? pr->sh[3]->key : "-", ms ? ms->key : "-",
                                       ms && ms->mesh_kind == 2 && ms->mesh_task && !ts ? ", which takes a task shader" : ms && ms->mesh_kind != 2 ? ", not a mesh shader" : ""); return; }
    if (S.rast_discard) { g_mtk_skip++; RED_ONCE(150, "task / mesh draw with the rasterizer discarded (mesh %s): its storage side effects are not run, skipped", ms->key); return; }
    if (!img_atomic_prepare(ts, 3) || !img_atomic_prepare(ms, 4)) return;
    if (g_nubd && (g_enc || ubd_lazy()) && ((dw->ind && ubd_hits(dw->ind, dw->ind + 8)) || (ts && ubd_conflict_sh(ts, 3)) || ubd_conflict_sh(ms, 4))) { g_ubd_conflicts++; rp_end(); ubd_land(); }   // as draw() does for its stages
    uint64_t ind = 0;
    if (dw->ind) {
        const ixc_ent *ix = ixc_find(dw, NULL);
        // Not converted yet: the pass ends and inline updates land before the conversion takes its write epoch (ixc_run), else landing them at its compute encoder moved the epoch on and
        //   the conversion was never found again
        if (!ix) { rp_end(); ubd_land(); ixc_run(dw, NULL); ix = ixc_find(dw, NULL); }
        if (!ix || !ix->args) { g_mtk_skip++; RED_ONCE(148, "indirect task / mesh draw skipped: argument address %#llx is in no memory pool, or the conversion pipeline was not created", (unsigned long long)dw->ind); return; }
        ind = ix->args;
    }
    NvProg *raster = pr->geo_raster;   // the pixel stage alone (geo_draw keeps its reader program here; a mesh program has no geometry stage)
    if (!raster || raster->sh[0] || raster->sh[1] != pr->sh[1]) { raster = [NvProg new]; raster->sh[1] = pr->sh[1]; raster->gp = pr->gp; pr->geo_raster = raster; }
    mtk_publish();   // #770 S2A_MESH_PACE: deliver held pipelines first
    g_mtk.on = 1; g_mtk.miss = 0; g_mtk.ts = ts; g_mtk.ms = ms; g_mtk.first = (uint32_t)dw->first; g_mtk.count = (uint32_t)dw->count; g_mtk.ind = ind;
    g_geo_program = raster;
    p_draw triangle = {.prim = 4, .count = 3, .instances = 1};
    draw(&triangle, NULL);
    g_geo_program = nil; g_mtk.on = 0; g_mtk.ts = g_mtk.ms = nil; args_dirty_all();
    if (g_mtk.miss) { g_mtk_wait++; return; }
    swrite_note(pr);   // the task / mesh stages' storage writes (draw() saw the pixel stage alone)
    if (!g_mtk_n++) MLOG("task / mesh: first draw (%s), task %s mesh %s fragment %s, %u workgroups from %u", ind ? "indirect" : "direct", ts ? ts->key : "-", ms->key, pr->sh[1] ? pr->sh[1]->key : "-",
                         g_mtk.count, g_mtk.first);
    if (ind) g_mtk_ind_n++;
}


// ---------- 几何绘制段（S2Arm 11-06 能耗线，金刚：一帧 541 笔几何绘制首尾相接、同一组渲染目标，每笔 抓顶点 / 几何核 / 重开主遍 3 个编码器，主遍断 541 次） ----------
// 段里的几何绘制共用一个抓顶点编码器（录制主流）、一个几何核编码器（道 1）和不断开的主绘制遍（道 2）。段结束时（geo_run_flush）道 1、道 2 接在主流后面，
//   GPU 上的次序成了「全部抓顶点 → 全部几何核 + 索引压缩 → 主遍里全部合成绘制」。与逐笔交错相比只换了这些工作彼此的先后，成立的前提是段里没有别的工作夹在中间、
//   互相不读写对方的输出：
//   ① 段只收「能入段」的几何绘制（geo_run_ok）；执行循环里状态设置之外的任何操作、非几何绘制、结束主遍、开别的编码器、提交 / 发信号 / 等 GPU 都先结束段；
//   ② 片元阶段不写存储缓冲 / 图像（几何核读的输入不会被同段的光栅改）；唯一放进来的片元写是预测生效时的原始池表写（写区间 = 学到的池，geo_runset fw），
//      后面各笔的抓顶点 / 几何核碰到就先结束段；几何核之间每次派发后一道编码器内屏障，按原顺序；
//   ③ 抓顶点读的统一缓冲与顶点：段里没有内联更新（有待落的更新不入段，OP_UPDATE_UB 结束段），各笔的参数在编码当时写进参数表（表每笔快照），
//      换道时作废顶点表缓存、全部参数块重编，所以每笔看到的是它自己那一刻的绑定。
//   只在 Metal 4 + 录制线程（DM_NVN_ENC_THREAD，iOS 缺省开）时成段：分道靠录制流的顺序；其余照原路逐笔
// 几何核之间的屏障（11-06 能耗线 ②，金刚真机：一段 615 笔，每笔「几何核 → 屏障 → 压缩 → 屏障」串行，道 1 每帧 43.4 ms）：
//   几何核只在它读 / 写的区间碰到本段前面几何核写过的区间、或它写的区间碰到前面读过的区间时，才在它前面加一道编码器内屏障；
//   读写区间列举不全的（可写图像、句柄在统一缓冲里的存储缓冲 / 贴图缓冲 / 图像）一律加，之后的也加。压缩只读本笔几何核写的记录、
//   只写本笔自己的暂存，全部挪到段末所有几何核之后，中间一道屏障（geo_run_flush）
typedef struct { uint64_t lo, hi; } geo_rg;
// 原始池表写的预测（nvn_mtl.m gml_take）在本笔几何绘制时的样子，geo_draw 开头取一次，本笔各阶段都按它（geo_fs_writes / geo_stage_ranges）：n = 学到的池区间数，
//   -1 = 还没预测 / 已记满（写在哪都算）/ 多于 GEO_GML_N（按列举不全）。区间是 CPU 地址，与绑定区间同一种（录制入口已把游戏的 GPU 地址换回 CPU，hle_nvn.c GA；
//   学到的区间取自池表的 CPU 起点 g_gmem_cpu）。学到的池只增不减，所以段里后来再取的一份包含前面各笔记写时用的那份（geo_runset_gml）
enum { GEO_GML_N = 256 };
static struct { int n; geo_rg r[GEO_GML_N]; } g_geo_gml = {-1};
static void geo_gml_snap(void) {
    if (!g_gml_on) { g_geo_gml.n = -1; return; }   // 还没有带池表写的着色器跑过：不可能在预测
    pthread_mutex_lock(&g_gml_mu);
    int n = !g_gml_over && g_gml_stable >= GML_STABLE && g_gml_n <= GEO_GML_N ? g_gml_n : -1;   // 同 gml_take 的 predict
    for (int i = 0; i < n; i++) g_geo_gml.r[i] = (geo_rg){g_gml_lo[i], g_gml_hi[i]};
    g_geo_gml.n = n;
    pthread_mutex_unlock(&g_gml_mu);
}
static int geo_gmem_writes(NvShader *sh) { if (sh) for (int i = 0; i < sh->rf.nb; i++) if (sh->rf.b[i].kind == NVN_RB_GMEM && sh->rf.b[i].rw) return 1; return 0; }
enum { GEO_HZ_N = 64 };
typedef struct { geo_rg w[GEO_HZ_N], r[GEO_HZ_N]; int nw, nr, all; } geo_hz;
static int geo_rg_hit(const geo_rg *a, int na, const geo_rg *b, int nb) {
    for (int i = 0; i < na; i++) for (int j = 0; j < nb; j++) if (a[i].lo < b[j].hi && b[j].lo < a[i].hi) return 1;
    return 0;
}
// 这次几何核（读 rd、写 wr）要不要排在前面已派的几何核之后
static int geo_hz_conflict(const geo_hz *h, const geo_rg *rd, int nrd, const geo_rg *wr, int nwr) {
    return h->all || geo_rg_hit(rd, nrd, h->w, h->nw) || geo_rg_hit(wr, nwr, h->w, h->nw) || geo_rg_hit(wr, nwr, h->r, h->nr);
}
static void geo_hz_add(geo_hz *h, const geo_rg *rd, int nrd, const geo_rg *wr, int nwr) {
    if (h->nw + nwr > GEO_HZ_N || h->nr + nrd > GEO_HZ_N) { h->all = 1; return; }   // 记不下：之后的一律加屏障
    memcpy(h->w + h->nw, wr, sizeof *wr * (size_t)nwr); h->nw += nwr; memcpy(h->r + h->nr, rd, sizeof *rd * (size_t)nrd); h->nr += nrd;
}
// 某一阶段（st：0 顶点、1 片元、2 几何）的着色器经绑定读写的游戏内存区间。返回位：GEO_RK 读区间齐全、GEO_WK 写区间齐全（列举不全的绑定只清它涉及的那一位：
//   只读的贴图缓冲 / 只读句柄不让「写」变不明——11-06 金刚直通几何核 dda4fd846f421f3b 带只读贴图缓冲，原先整个记成列举不全，段里之后每笔都结束段）
enum { GEO_RK = 1, GEO_WK = 2 };
static int geo_stage_ranges(NvShader *gs, int st, geo_rg *rd, int *nrd, geo_rg *wr, int *nwr, int cap) {
    *nrd = *nwr = 0; int k = GEO_RK | GEO_WK, gm = 0;
    if (!gs) return k;
    for (int i = 0; i < gs->rf.nb; i++) { const nvn_rbind *b = &gs->rf.b[i];
        switch (b->kind) {
            case NVN_RB_SBUFP: case NVN_RB_UBOP: case NVN_RB_CBUF: {
                int w = b->kind == NVN_RB_SBUFP && b->rw;
                if (b->reg >= 16) { k &= ~(w ? GEO_WK | GEO_RK : GEO_RK); continue; }
                const p_bind_buf *u = b->kind == NVN_RB_SBUFP ? &S.ssbo[st][b->reg] : &S.ubo[st][b->reg];
                if (!u->addr) continue;
                if ((w ? *nwr : *nrd) >= cap) { k &= ~(w ? GEO_WK : GEO_RK); continue; }
                (w ? wr : rd)[(w ? (*nwr)++ : (*nrd)++)] = (geo_rg){u->addr, u->addr + (u->size ? u->size : 1)};
                break; }
            case NVN_RB_IMG: case NVN_RB_IMGA: if (b->rw) k &= ~GEO_WK; break;   // 图像写：所写贴图的内存这里不列举（读的贴图不在缓冲区间里，不影响读位）
            case NVN_RB_IMGU: case NVN_RB_SBUFU: k &= ~(b->rw ? GEO_WK | GEO_RK : GEO_RK); break;   // 地址在统一缓冲 / 贴图句柄里：不列举
            case NVN_RB_TBUF: case NVN_RB_TBUFU: k &= ~GEO_RK; break;   // 贴图缓冲只读
            case NVN_RB_GMEM:   // 原始池表（地址从内存读来）：可达任一列表里的池，读区间列举不全；写区间在预测生效时 = 学到的池（gml_take 记写的同一份），否则也不全（审计 P1-119 / 120）
                k &= ~GEO_RK;
                if (b->rw && !gm++) { if (g_geo_gml.n < 0 || *nwr + g_geo_gml.n > cap) k &= ~GEO_WK; else { memcpy(wr + *nwr, g_geo_gml.r, sizeof *wr * (size_t)g_geo_gml.n); *nwr += g_geo_gml.n; } }
                break;
            default: break;
        }
    }
    return k;
}
static int geo_gs_ranges(NvShader *gs, geo_rg *rd, int *nrd, geo_rg *wr, int *nwr, int cap) { return geo_stage_ranges(gs, 2, rd, nrd, wr, nwr, cap) == (GEO_RK | GEO_WK); }
// 段内次序的另两种冒险（11-06 审计 P1-120）：段里 GPU 次序是「全部抓顶点 → 全部几何核 + 压缩 → 主遍全部合成绘制」，相对逐笔交错，
//   A 后一笔的抓顶点排到了前面几何核之前：它读的顶点缓冲 / 顶点阶段统一与存储缓冲若是前面几何核写的，读到写之前的字节；
//   B 前一笔的主遍绘制排到了后面几何核之后：后面几何核写的区间若是前面片元阶段读的，读到写之后的字节。
//   段里另记整段累计的几何核写区间 w 与片元读区间 r（geo_hz 的 hz 遇屏障会清，不能当整段记录）；入段前撞上就先结束段（逐笔次序），列举不全按撞上算
enum { GEO_RS_N = 1024 };   // 整段记录：有序、不相交，二分查（11-06 金刚：几何核写的区间分散，64 段 50 笔左右就记满）
//   C 前一笔片元阶段经原始池表的写（只在预测生效时入段，写区间 = 学到的池）排到了后面各笔的抓顶点与几何核之后：后一笔抓顶点读、几何核读 / 写若碰到，
//     读到写之前的字节、或被它盖掉。段里另记片元写区间 fw；gml：段里有按预测记的池表写（1 几何核、2 片元），之后每笔先按当时的预测补进去（geo_runset_gml）。
//   x：有池表写的着色器跑过（g_gml_on）后段里各笔列举到的读写区间，段里有按预测记的写时段末交给 g_gsr：预测漏学的池（gml_read 事后才发现）若落在其中，按同一口径报【红】
typedef struct { geo_rg w[GEO_RS_N], r[GEO_RS_N], fw[GEO_RS_N], x[GEO_RS_N]; int nw, nr, wall, rall, nfw, fwall, gml, nx, xall; geo_rg xb; } geo_runset;
// 有序不相交表 a 与任意区间组 x 有没有相交：每个 x 二分找第一段 hi > x.lo
static int geo_rs_hit(const geo_rg *x, int nx, const geo_rg *a, int na) {
    for (int k = 0; k < nx; k++) { int lo = 0, hi = na; while (lo < hi) { int m = (lo + hi) / 2; if (a[m].hi <= x[k].lo) lo = m + 1; else hi = m; }
        if (lo < na && a[lo].lo < x[k].hi) return 1; }
    return 0;
}
// 返回 0 = 不撞；1..6 = 撞上的原因（geo_hazard_why）
static int geo_run_hazard(const geo_runset *s, const geo_rg *cap, int ncap, int cap_known, const geo_rg *gw, int ngw, int gw_known) {
    if (s->wall) return 1;                                   // A：前面有几何核写区间列举不全
    if (!cap_known && s->nw) return 2;                       // A：本笔抓顶点读区间列举不全
    if (geo_rs_hit(cap, ncap, s->w, s->nw)) return 3;        // A：抓顶点读到前面几何核写过的
    if (s->rall && (ngw || !gw_known)) return 4;             // B：前面有片元读区间列举不全
    if (!gw_known && s->nr) return 5;                        // B：本笔几何核写区间列举不全
    if (geo_rs_hit(gw, ngw, s->r, s->nr)) return 6;          // B：几何核写到前面片元读过的
    return 0;
}
// C（见上）：返回 0 = 不撞；8..10 = 撞上的原因（geo_hazard_why）。gr / gw：本笔几何核读 / 写，cap：抓顶点读（含顶点阶段写）
static int geo_run_hazard_fw(const geo_runset *s, const geo_rg *cap, int ncap, int cap_known, const geo_rg *gr, int ngr, int gr_known, const geo_rg *gw, int ngw, int gw_known) {
    if (s->fwall) return 8;                                  // 前面有片元写区间列举不全
    if (!s->nfw) return 0;
    if (!cap_known || !gr_known || !gw_known) return 9;      // 本笔抓顶点 / 几何核的读写列举不全
    if (geo_rs_hit(cap, ncap, s->fw, s->nfw) || geo_rs_hit(gr, ngr, s->fw, s->nfw) || geo_rs_hit(gw, ngw, s->fw, s->nfw)) return 10;
    return 0;
}
static const char *const geo_hazard_why[] = {"-", "an earlier geometry kernel's writes are not all known", "this capture's reads are not all known", "this capture reads what an earlier geometry kernel wrote",
    "an earlier fragment stage's reads are not all known", "this geometry kernel's writes are not all known", "this geometry kernel writes what an earlier fragment stage read",
    "the pool table's write prediction ended inside the run", "an earlier fragment stage's writes are not all known",
    "this capture's or geometry kernel's accesses are not all known after a fragment stage's pool-table writes", "this capture or geometry kernel touches what an earlier fragment stage wrote through the pool table"};
// 有序区间表里并进一段：重叠或相接的合成一段（段里各笔几何核多写同一批暂存 / 相邻输出，合并后段数很少）；放不下返回 0
static int geo_rg_merge_in(geo_rg *a, int *n, geo_rg x) {
    int i = 0, h = *n; while (i < h) { int m = (i + h) / 2; if (a[m].hi < x.lo) i = m + 1; else h = m; }   // 第一段与 x 重叠或相接、或在 x 之后的
    int j = i; while (j < *n && a[j].lo <= x.hi) { if (a[j].lo < x.lo) x.lo = a[j].lo; if (a[j].hi > x.hi) x.hi = a[j].hi; j++; }
    int nn = *n - (j - i) + 1; if (nn > GEO_RS_N) return 0;
    memmove(a + i + 1, a + j, sizeof *a * (size_t)(*n - j)); a[i] = x; *n = nn; return 1;
}
static void geo_runset_add(geo_runset *s, const geo_rg *gw, int ngw, int gw_known, const geo_rg *fr, int nfr, int fr_known) {
    if (!gw_known) s->wall = 1; else for (int i = 0; i < ngw && !s->wall; i++) if (!geo_rg_merge_in(s->w, &s->nw, gw[i])) s->wall = 1;   // 11-06 金刚：不合并时 33 笔就记满 64 段
    if (!fr_known) s->rall = 1; else for (int i = 0; i < nfr && !s->rall; i++) if (!geo_rg_merge_in(s->r, &s->nr, fr[i])) s->rall = 1;
}
static void geo_runset_add_fw(geo_runset *s, const geo_rg *fw, int nfw, int fw_known) {
    if (!fw_known) s->fwall = 1; else for (int i = 0; i < nfw && !s->fwall; i++) if (!geo_rg_merge_in(s->fw, &s->nfw, fw[i])) s->fwall = 1;
}
// 段里按预测记的池表写，在新的一笔查冒险前按这一刻的预测补全：前面一笔记写时取的预测，可能比它的 gml_take 真正用的少（中间另一份写记录读完、学到了新池）；
//   学到的只增不减，这一刻的一份包含那份。预测已不生效（记满：写在哪都算）返回 7
static int geo_runset_gml(geo_runset *s) {
    if (!s->gml) return 0;
    if (g_geo_gml.n < 0) return 7;
    if (s->gml & 1) geo_runset_add(s, g_geo_gml.r, g_geo_gml.n, 1, NULL, 0, 1);
    if (s->gml & 2) geo_runset_add_fw(s, g_geo_gml.r, g_geo_gml.n, 1);
    return 0;
}
static void geo_runset_note(geo_runset *s, const geo_rg *x, int n) {   // x：记不下时退成一段包住全部的区间（只用于事后查，宽了只会多报）
    for (int i = 0; i < n; i++) {
        if (!s->xb.hi || x[i].lo < s->xb.lo) s->xb.lo = x[i].lo;
        if (x[i].hi > s->xb.hi) s->xb.hi = x[i].hi;
        if (!s->xall && !geo_rg_merge_in(s->x, &s->nx, x[i])) s->xall = 1;
    }
}
// 段末：段里有按预测记的池表写，把 x 交给 g_gsr（同 ubp_get 记的统一缓冲影子，带本次提交的栅栏），gml_read 事后发现漏学的池时一并查
static void geo_runset_gsr(const geo_runset *s) {
    if (!s->gml || !g_gml_on) return;
    const geo_rg *x = s->xall ? &s->xb : s->x; int n = s->xall ? (s->xb.hi > s->xb.lo) : s->nx;
    pthread_mutex_lock(&g_gsr_mu);
    for (int i = 0; i < n; i++) { uint64_t k = g_gsr_n++ % GSR_N; g_gsr[k].fence = g_fence + 1; g_gsr[k].lo = x[i].lo; g_gsr[k].hi = x[i].hi; }
    pthread_mutex_unlock(&g_gsr_mu);
}
static struct { int active, gpc, gpk; id cap, gs, cap_pso; uint64_t runs, draws, kernels, barriers, cut, hazard; geo_hz hz; geo_runset rs; id pack; uint64_t *jobs; size_t njobs, cjobs; } g_gr;   // cap_pso: the capture lane's current pipeline (only captures set one there; cleared when the lanes begin)   // gpc / gpk: the lane encoders' GPUPROF labels (gp_lane_begin); jobs: the run's compactions, encoded at its end
static int geo_run_active(void) { return g_gr.active; }   // for pass_color_unwritten (nvn_mtl.m, before this include)
static int geo_fs_writes(NvShader *fs) {
    if (!fs) return 0;
    for (int i = 0; i < fs->rf.nb; i++) if (fs->rf.b[i].rw && (fs->rf.b[i].kind == NVN_RB_IMG || fs->rf.b[i].kind == NVN_RB_IMGU || fs->rf.b[i].kind == NVN_RB_IMGA || fs->rf.b[i].kind == NVN_RB_SBUFP ||
        (fs->rf.b[i].kind == NVN_RB_GMEM && g_geo_gml.n < 0))) return 1;   // 原始池表写：预测生效时写区间已知（geo_stage_ranges），入段按 C 查；否则同 g_pass_swrite
    return 0;
}
static void geo_run_flush(void) {
    if (!g_gr.active) return;
    if (g_rlane) MDIE("geometry run: flushed from lane %d (an encoder, commit or wait inside a lane)", g_rlane);
    g_gr.active = 0;   // first: the calls below must not come back here
    gp_lane_end(g_gr.cap, g_gr.gpc, (uint32_t)g_gr.draws); enc_full_barrier_end(g_gr.cap); [g_gr.cap endEncoding];
    rec_lane(1);
    if (g_gr.njobs) {   // the compactions, after every geometry kernel of the run: each reads only its own kernel's records and writes its own scratch
        enc_c_inner_barrier(g_gr.gs); NSUInteger th = MIN([(id<MTLComputePipelineState>)g_gr.pack maxTotalThreadsPerThreadgroup], 1024) / 32 * 32;
        enc_c_pso(g_gr.gs, g_gr.pack);   // every compaction of the run uses the same pipeline: set it once
        for (size_t i = 0; i < g_gr.njobs; i++) { enc_c_args(g_gr.gs, g_gr.jobs[i], 0); enc_c_dispatch(g_gr.gs, MTLSizeMake(1, 1, 1), MTLSizeMake(th, 1, 1)); }
        g_gr.njobs = 0; }
    gp_lane_end(g_gr.gs, g_gr.gpk, (uint32_t)g_gr.draws); enc_full_barrier_end(g_gr.gs); [g_gr.gs endEncoding]; rec_lane(0);
    geo_runset_gsr(&g_gr.rs); memset(&g_gr.hz, 0, sizeof g_gr.hz); memset(&g_gr.rs, 0, sizeof g_gr.rs);
    rec_lane_splice();
    g_gr.cap = g_gr.gs = g_gr.cap_pso = nil; g_vt_valid = 0; args_dirty_all();
    if (g_gr.runs == 1 || g_gr.runs % 2000 == 0) MLOG("geometry run: %llu runs, %llu geometry draws in them, barriers before %llu of %llu geometry kernels, %llu runs ended to cut the segment for scratch, %llu ended for a read / write across the run's reordering (a run: captures, geometry kernels and main-pass draws each in one encoder)",
        (unsigned long long)g_gr.runs, (unsigned long long)g_gr.draws, (unsigned long long)g_gr.barriers, (unsigned long long)g_gr.kernels, (unsigned long long)g_gr.cut, (unsigned long long)g_gr.hazard);
}
// The run begins: no encoder is open (geo_draw ended the pass); the two lane encoders begin with a full barrier, not through main_barrier_begin (its state follows the main stream)
static void geo_run_begin(void) {
    main_barrier_reset();
    id rd = pass_desc(); [rd setRenderTargetWidth:1]; [rd setRenderTargetHeight:1]; [rd setDefaultRasterSampleCount:1];   // as geo_draw's capture pass
    g_gr.cap = [g_cb renderCommandEncoderWithDescriptor:rd]; g_gr.cap_pso = nil; enc_full_barrier_begin(g_gr.cap);
    enc_r_table(g_gr.cap, g_vt, MTLRenderStageVertex); enc_r_table(g_gr.cap, g_ft, MTLRenderStageFragment); g_gr.gpc = gp_lane_begin(g_gr.cap, 'P', (uint32_t)g_gr.draws);
    rec_lane(1); g_gr.gs = [g_cb computeCommandEncoder]; enc_full_barrier_begin(g_gr.gs); enc_c_table(g_gr.gs, g_ct); g_gr.gpk = gp_lane_begin(g_gr.gs, 'K', (uint32_t)g_gr.draws); rec_lane(0);
    g_gr.active = 1; g_gr.runs++;
}
// Before a geometry draw takes `total` bytes of scratch: once the segment holds ARENA_CUT bytes, hand it to the GPU so its scratch comes back (NvArena, nvn_mtl.m). Outside a run no
//   encoder is open there (geo_draw ended the pass). Inside one the main pass is open and sub_cut cannot cut: the run ends first (its lanes go into the stream), then the pass, then the
//   cut, and the draw begins a new run. 11-06 Donkey Kong (维护者's hand test): a run's draws piled their scratch into one uncut segment past ARENA_CAP, and the next block waited
//   ARENA_WAIT_S for the GPU ("frame scratch: waited 2 s", a 2.1 s freeze)
static void geo_scratch_cut(int run, uint64_t total) {
    if (g_arena_seg + total < ARENA_CUT) return;
    if (run && g_gr.active) { geo_run_flush(); rp_end(); g_gr.cut++; }
    sub_cut();
}
// Exec loop: the ops a run lets through (state only; draws decide in draw())
static int geo_run_keeps(uint32_t op) {
    switch (op) {
        case OP_DRAW: case OP_DRAW_IDX: case OP_SCISSOR: case OP_BIND_PROGRAM: case OP_BIND_STATE: case OP_BIND_VATTR: case OP_BIND_VSTREAM: case OP_BIND_VBUF:
        case OP_BIND_UBO: case OP_BIND_SSBO: case OP_BIND_TEX: case OP_BIND_TEX1: case OP_BIND_SAMP: case OP_BIND_IMG: case OP_STENCIL:
        case OP_POLY_OFFSET: case OP_VIEWPORTS: case OP_DEPTH_RANGE: case OP_DEPTH_CLAMP: case OP_VP_SWIZZLE: case OP_BLEND_COLOR: case OP_PRIM_RESTART: case OP_ALPHA_REF:
        case OP_JUMP: case OP_CALL: case OP_END: return 1;
        default: return 0;
    }
}
static void geo_lane(int k) { rec_lane(k); g_vt_valid = 0; args_dirty_all(); }
// 几何模拟变体按程序缓存（S2Arm 11-06 能耗线：金刚提交线程 Time Profiler，每笔几何绘制现拼「<键>_bg<n>」「_bgv」再按名字查表，
//   shader_get + 拼字符串占翻译时间约 13.5%）。缓存挂在程序对象上（随它销毁），记着当时的几何阶段 geo_base：几何阶段换了整格作废重查；
//   读记录的顶点变体按深度模式分两格（shader_get 的顶点阶段按 g_depth_zero 取库）；没查到的不缓存，下一笔照原样再查。
//   着色器缓存的条目一经放入不再替换（shader_load_depth），所以缓存住的对象就是 shader_get 会再给的那个
static NvShader *geo_lookup_shader(NSString *k, int st) { return shader_get(k, st); }
static NvShader *(*g_geo_lookup)(NSString *, int) = geo_lookup_shader;   // 单测换成计数版
static void geo_variants(NvProg *pr, NvShader *base, int topology, NvShader **gs, NvShader **reader) {
    *gs = *reader = nil;
    if (topology < 0 || topology >= 5) return;
    if (pr->geo_base != base) { for (int i = 0; i < 5; i++) pr->geo_gs[i] = pr->geo_ps[i] = nil; pr->geo_rd[0] = pr->geo_rd[1] = pr->geo_rc[0] = pr->geo_rc[1] = nil; pr->geo_base = base; }
    int dz = atomic_load(&g_depth_zero) ? 1 : 0;
    if (!pr->geo_gs[topology] || !pr->geo_rd[dz]) {
        NSString *key = [[NSString stringWithUTF8String:base->key] substringToIndex:16];
        if (!pr->geo_gs[topology]) pr->geo_gs[topology] = g_geo_lookup([key stringByAppendingFormat:@"_bg%d", topology], 2);
        if (!pr->geo_rd[dz]) pr->geo_rd[dz] = g_geo_lookup([key stringByAppendingString:@"_bgv"], 0);
    }
    *gs = pr->geo_gs[topology]; *reader = pr->geo_rd[dz];
}
// 直通几何快路（S2Arm 11-06 能耗线）：头标直通、几何本体不写输出也不自己发射的几何着色器（反射 geometry.passthrough，Dsh.cs GeometryFinish），输出图元就是输入图元、
//   顶点值就是顶点阶段抓下的输出。几何核换成只算副作用的 _bgs<拓扑>（不写记录、不写下标），主遍顶点换成读抓顶点缓冲的 _bgc，按 CPU 装好的输入图元下标（map）直接画，
//   不派压缩核。金刚 f5800 回放：几何核道 ÷ 抓顶点道 3.4–3.9 → 1.3–2.3（只删记录写的测量库）。
//   只在：没开变换反馈、单实例、单次调用（实例 / 调用多于 1 时记录与图元号按组排，主遍下标与图元号对不上）、非邻接拓扑（点 0 / 线 1 / 三角 3：邻接的直通取 0 2 4 / 1 2 号顶点，
//   下标与 map 不同）。老库没有标记、或缺 _bgs / _bgc：照旧走记录。DM_NVN_GEO_PT=0 关（回放逐像素对照用）。查表结果按程序缓存，规则同 geo_variants
static int g_geo_pt_off = -1; static uint64_t g_geo_pt_draws;
static void geo_pt_variants(NvProg *pr, NvShader *base, NvShader *gs, int topology, NvShader **side, NvShader **creader) {
    *side = *creader = nil;
    if (g_geo_pt_off < 0) { const char *e = getenv("DM_NVN_GEO_PT"); g_geo_pt_off = e && !strcmp(e, "0"); }
    if (g_geo_pt_off || !gs || !gs->geo_pt || topology < 0 || topology >= 5) return;
    int dz = atomic_load(&g_depth_zero) ? 1 : 0;
    if (!pr->geo_ps[topology] || !pr->geo_rc[dz]) {
        NSString *key = [[NSString stringWithUTF8String:base->key] substringToIndex:16];
        if (!pr->geo_ps[topology]) pr->geo_ps[topology] = g_geo_lookup([key stringByAppendingFormat:@"_bgs%d", topology], 2);
        if (!pr->geo_rc[dz]) pr->geo_rc[dz] = g_geo_lookup([key stringByAppendingString:@"_bgc"], 0);
    }
    *side = pr->geo_ps[topology]; *creader = pr->geo_rc[dz];
}
// 这笔走不走快路：走就把几何核 / 主遍顶点换成 _bgs / _bgc（条件见上）
static int geo_pt_pick(NvProg *pr, NvShader *base, int tf, int instances, int topology, NvShader **gs, NvShader **reader) {
    if (tf || instances != 1 || (*gs)->geo_invocations != 1 || !(topology == 0 || topology == 1 || topology == 3)) return 0;
    NvShader *side, *creader; geo_pt_variants(pr, base, *gs, topology, &side, &creader);
    if (!side || !creader || side->geo_invocations != 1) return 0;
    *gs = side; *reader = creader; return 1;
}
static void geo_draw(NvProg *pr, const p_draw *dw0, const p_draw_idx *di0) {
    NvShader *vs = pr->sh[0], *base = pr->sh[2];
    // Feedback on with a geometry shader that has no capture layout (control section strides all 0, e.g. Xenoblade 3 95bfab6122539993): the GPU captures nothing and still draws,
    // as the vertex path does for a vertex shader without one (draw, not tf_draw)
    int tf = S.tf_on && (base && (base->geo_tf_stride[0] || base->geo_tf_stride[1] || base->geo_tf_stride[2] || base->geo_tf_stride[3]));
    if (!vs || !vs->geo_fn || !base || !base->geo_vertices || pr->sh[3] || pr->sh[4]) {
        GEO_RED("【红】 geometry draw cannot capture this pipeline (vertex %s, geometry %s, tessellation %d, feedback %d)", vs ? vs->key : "-", base ? base->key : "-", !!(pr->sh[3] || pr->sh[4]), S.tf_on); return;
    }
    p_draw dw = dw0 ? *dw0 : (p_draw){0}; p_draw_idx di = di0 ? *di0 : (p_draw_idx){0};
    if (di0 && (di.itype < 0 || di.itype > 2)) { GEO_RED("【红】 geometry index type %d is invalid", di.itype); return; }
    uint64_t ind = dw0 ? dw.ind : di.ind;
    // Indirect records and GPU-written index data need a coherent CPU snapshot for primitive assembly. Index data waits only when the GPU may have written it and not finished:
    // a write queued in this submission (pend), a storage write in it (sbw), or a GPU write of an earlier submission still running (gw); the same test as ubp_get. Waiting on every
    // indexed draw made Xenoblade 3 (95bfab6122539993, hundreds of indexed geometry draws a frame) take 0.4-2 s a frame on the submit thread
    uint64_t ilo = di0 ? di.ibuf : 0, ihi = di0 ? di.ibuf + ((uint64_t)di.count << di.itype) : 0;
    int wait = ind != 0 || (di0 && (pend_hits(ilo, ihi - ilo) || g_sbw_over || sbw_hits(ilo, ihi) || gw_live(ilo, ihi)));
    for (int i = 0; i < 16; i++) if (S.vbuf[i].size && pend_hits(S.vbuf[i].address, S.vbuf[i].size)) wait = 1;
    for (int i = 0; i < vs->rf.nv; i++) if (vconv_wanted(&vs->rf, i, NULL, 0)) wait = 1;
    geo_gml_snap();   // 本笔各阶段的原始池表写按这一份预测（geo_fs_writes / geo_stage_ranges）
    int run = !g_m3 && rec_on() && g_cb && !tf && !wait && !ind && !S.rast_discard && !g_nubd && !defer_has_active() && !g_hoist_n && !g_fz.active && !geo_fs_writes(pr->sh[1]);
    // 这笔的抓顶点读区间（顶点缓冲 + 顶点阶段统一 / 存储缓冲）、几何核写区间、片元读区间（审计 P1-120，见 geo_runset）；撞上本段已记的就先结束段
    geo_rg h_cap[48], h_gw[32], h_gr[32], h_fr[32], h_fw[32], h_tmp[32]; int h_ncap = 0, h_ngw = 0, h_ngr = 0, h_nfr = 0, h_nfw = 0, h_nt = 0, h_ck = 1, h_gk = 1, h_grk = 1, h_fk = 1, h_fwk = 1;
    if (run) {
        for (int i = 0; i < 16; i++) if (S.vbuf[i].address && S.vbuf[i].size) h_cap[h_ncap++] = (geo_rg){S.vbuf[i].address, S.vbuf[i].address + S.vbuf[i].size};
        h_ck = geo_stage_ranges(vs, 0, h_cap + h_ncap, &h_nt, h_tmp, &h_ngw, 16) == (GEO_RK | GEO_WK); h_ncap += h_nt;   // 顶点阶段写的也当读算，两位都要齐
        if (h_ngw) { memcpy(h_cap + h_ncap, h_tmp, sizeof *h_tmp * (size_t)h_ngw); h_ncap += h_ngw; } h_ngw = 0;   // 顶点阶段写的也当读算（同一笔前后都要对）
        int gk = geo_stage_ranges(base, 2, h_gr, &h_ngr, h_gw, &h_ngw, 32); h_gk = !!(gk & GEO_WK); h_grk = !!(gk & GEO_RK);   // B 看几何核写，C 读写都看
        int fk = geo_stage_ranges(pr->sh[1], 1, h_fr, &h_nfr, h_fw, &h_nfw, 32); h_fk = !!(fk & GEO_RK); h_fwk = !!(fk & GEO_WK);   // B 看片元读；片元的写入段的只有预测下的原始池表写（geo_fs_writes），C 看它
        int why = 0;
        if (g_gr.active && !(why = geo_runset_gml(&g_gr.rs)) && !(why = geo_run_hazard(&g_gr.rs, h_cap, h_ncap, h_ck, h_gw, h_ngw, h_gk))) why = geo_run_hazard_fw(&g_gr.rs, h_cap, h_ncap, h_ck, h_gr, h_ngr, h_grk, h_gw, h_ngw, h_gk);
        if (why) { geo_run_flush(); if (g_gr.hazard++ < 8) MLOG("geometry run ended before a draw (%llu ends so far): %s (geometry %s)", (unsigned long long)g_gr.hazard, geo_hazard_why[why], base->key); }
    }
    if (!run) geo_run_flush();
    if (!(run && g_gr.active)) {
        if (defer_has_active()) defer_fallback();
        lc_land(); rp_flush(); rp_end(); ubd_land();
    }
    if (wait) { mdi_wait(); if (g_mdi_ev.signaledValue < g_mdi_v) return; memset(g_vconv, 0, sizeof g_vconv); }
    if (ind) {
        uint32_t a[5] = {0}; size_t n = dw0 ? 16 : 20;
        if (!nvn_host_readable(ind, n)) { GEO_RED("【红】 geometry indirect arguments are not readable"); return; }
        memcpy(a, (void *)(uintptr_t)ind, n);
        if (!a[0] || !a[1]) return;
        if (a[0] > INT32_MAX || a[1] > INT32_MAX) { GEO_RED("【红】 geometry indirect draw exceeds the host count range"); return; }
        if (dw0) { dw.count = a[0]; dw.instances = a[1]; dw.first = a[2]; dw.base_instance = a[3]; dw.ind = dw.mdi_cnt = 0; }
        else { di.count = a[0]; di.instances = a[1]; di.ibuf += (uint64_t)a[2] << di.itype; di.base_vertex = (int32_t)a[3]; di.base_instance = a[4]; di.ind = di.mdi_cnt = 0; }
    }
    int prim = dw0 ? dw.prim : di.prim, topology = nvn_geo_topology(prim);
    int count = dw0 ? dw.count : di.count, instances = dw0 ? dw.instances : di.instances;
    uint32_t first_instance = (uint32_t)(dw0 ? dw.base_instance : di.base_instance);
    g_draw_binst = first_instance;
    if (count <= 0 || instances < 0) return;
    if (!instances) instances = 1;
    if (topology < 0 || count > (1 << 22)) { GEO_RED("【红】 geometry primitive %d or count %d exceeds the assembly path", prim, count); return; }
    NvShader *gs, *reader; geo_variants(pr, base, topology, &gs, &reader);
    if (!gs || !reader) { nvn_be_bad_draw_feat(); return; }
    int fast = geo_pt_pick(pr, base, tf, instances, topology, &gs, &reader);
    id<MTLRenderPipelineState> capture = geo_capture_pso(vs); if (!capture) { nvn_be_bad_draw_feat(); return; }
    if (gs->geo_pso_bad) { nvn_be_bad_draw_feat(); return; }
    if (!gs->geo_pso) { NSError *e = nil; gs->geo_pso = [g_dev newComputePipelineStateWithFunction:gs->fn error:&e];
        if (!gs->geo_pso) { gs->geo_pso_bad = 1; GEO_RED("【红】 geometry compute %s: %s（之后这支的几何绘制跳过、不重建）", gs->key, e.localizedDescription.UTF8String); return; } }
    if (gs->geo_pso.maxTotalThreadsPerThreadgroup < 32) { GEO_RED("【红】 geometry kernel cannot run a 32-thread group"); return; }
    static id<MTLComputePipelineState> pack;
    if (!pack) { NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_nvn_geo_pack_msl) options:nil error:&e];
        if (lib) pack = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"geo_pack_indices"] error:&e];
        if (!pack) { GEO_RED("【红】 geometry index compaction: %s", e.localizedDescription.UTF8String); return; } }

    // Index scratch kept across draws (submit thread only; 11-06 quality line: two malloc / free per geometry draw were a measurable share of the submit thread)
    static uint32_t *order, *unique; static size_t idx_cap;
    if ((size_t)count > idx_cap) {
        size_t cap = MAX((size_t)count, idx_cap * 2); uint32_t *o2 = realloc(order, cap * 4), *u2 = o2 ? realloc(unique, cap * 4) : NULL;
        if (o2) order = o2;
        if (!o2 || !u2) { GEO_RED("【红】 geometry index allocation failed"); return; }
        unique = u2; idx_cap = cap;
    }
    uint32_t lo = UINT32_MAX, hi = 0; size_t nu = 0;
    int restart = di0 && S.restart.on;
    int isz = di0 ? 1 << di.itype : 0;
    uint32_t restart_index = S.restart.index & (isz == 1 ? UINT8_MAX : isz == 2 ? UINT16_MAX : UINT32_MAX);
    if (di0 && (di.itype < 0 || di.itype > 2 || !nvn_host_readable(di.ibuf, (uint64_t)count * isz))) {
        GEO_RED("【红】 geometry index buffer is not readable"); return;
    }
    for (int i = 0; i < count; i++) {
        uint32_t v = (uint32_t)i;
        if (di0) {   // typed loads, not a variable-length memcpy per index (a library call each; unaligned-safe through memcpy of a fixed size)
            const uint8_t *q = (const uint8_t *)(uintptr_t)di.ibuf + (size_t)i * isz;
            if (isz == 2) { uint16_t h; memcpy(&h, q, 2); v = h; } else if (isz == 4) memcpy(&v, q, 4); else v = *q;
        }
        order[i] = v;
        if (restart && v == restart_index) continue;
        lo = MIN(lo, v); hi = MAX(hi, v); unique[nu++] = v;
    }
    if (!nu) { return; }
    int64_t first = di0 ? (int64_t)lo + di.base_vertex : dw.first;
    uint64_t span = (uint64_t)hi - lo + 1;
    if (first < 0 || first + span > (uint64_t)UINT32_MAX + 1) { GEO_RED("【红】 geometry vertex range is outside 32-bit vertex IDs"); return; }
    // Normalize only after assembly, so a restart value cannot collide with a
    // normalized vertex number. Indexed captures use a sorted unique index list.
    size_t words = nvn_geo_assemble(prim, order, count, restart, restart_index, NULL, 0);
    int width = nvn_geo_width(topology);
    uint64_t np = words == SIZE_MAX ? 0 : words / width;
    if (!np) { return; }
    uint64_t groups = np * (uint64_t)instances * gs->geo_invocations;
    if (groups > UINT32_MAX || span * (uint64_t)instances > (256ull << 20) / (144 * 4) ||
        (uint64_t)first_instance + instances > (uint64_t)UINT32_MAX + 1) {
        GEO_RED("【红】 geometry draw exceeds the capture or invocation bound"); return;
    }
    uint64_t input_size = span * instances * 144 * 4;
    uint64_t output_size = fast ? 0 : groups * gs->geo_vertices * gs->geo_stride * 4;   // the fast path's kernel writes no records and no indices
    uint64_t raw_size = fast ? 0 : groups * gs->geo_index_stride * 4;
    uint64_t packed_size = fast ? 0 : groups * gs->geo_vertices * (gs->geo_output == 7 ? 3 : gs->geo_output == 6 ? 2 : 1) * 4;
    uint64_t total = input_size + output_size + raw_size + packed_size + words * 4 + nu * 4 + 4096;
    if (groups > UINT32_MAX || total > (256ull << 20) || np > UINT32_MAX) {
        GEO_RED("【红】 geometry draw needs %llu MiB of scratch, above the 256 MiB bound", (unsigned long long)(total >> 20)); return;
    }
    geo_scratch_cut(run, total);
    id<MTLBuffer> scratch; size_t off = arena_alloc((size_t)total, &scratch);
    uint8_t *cpu = (uint8_t *)scratch.contents + off; uint64_t gpu = scratch.gpuAddress + off;
    size_t used = 0;
    #define GEO_ALLOC(N, G, P) do { used = (used + 255) & ~(size_t)255; (G) = gpu + used; (P) = cpu + used; used += (size_t)(N); } while (0)
    uint64_t input, output, raw, packed, map, capture_ix, info, capture_info, args, job;
    void *pinput, *poutput, *praw, *ppacked, *pmap, *pcapture_ix, *pinfo, *pcapture_info, *pargs, *pjob;
    GEO_ALLOC(input_size, input, pinput); GEO_ALLOC(output_size, output, poutput); GEO_ALLOC(raw_size, raw, praw); GEO_ALLOC(packed_size, packed, ppacked);
    GEO_ALLOC(words * 4, map, pmap); GEO_ALLOC(nu * 4, capture_ix, pcapture_ix); GEO_ALLOC(32, info, pinfo); GEO_ALLOC(32, capture_info, pcapture_info);
    GEO_ALLOC(20, args, pargs); GEO_ALLOC(40, job, pjob);
    #undef GEO_ALLOC
    (void)pinput; (void)poutput; (void)praw; (void)ppacked;
    if (used > total) MDIE("geometry scratch size accounting");
    nvn_geo_assemble(prim, order, count, restart, restart_index, pmap, words);
    for (size_t i = 0; i < words; i++) ((uint32_t *)pmap)[i] -= lo;
    static uint64_t *uq_bm; static size_t uq_words;   // submit thread only
    size_t unique_count = nvn_geo_unique_sorted(unique, nu, lo, hi, (uint32_t *)pcapture_ix, &uq_bm, &uq_words);
    uint32_t vi[8] = {(uint32_t)span, (uint32_t)instances, 0, 0, (uint32_t)np, 0, 0, 0}; memcpy(pinfo, vi, 32);
    uint64_t ci[2] = {input, 0}; memcpy(pcapture_info, ci, 16);
    uint32_t cc[4] = {(uint32_t)first, (uint32_t)span, first_instance, (uint32_t)instances}; memcpy((uint8_t *)pcapture_info + 16, cc, 16);
    memset(pargs, 0, 20);
    if (fast) { uint32_t a[5] = {(uint32_t)words, 1, 0, 0, 0}; memcpy(pargs, a, 20); }   // what the compaction would write: every input primitive, in order (k_nvn_geo_pack_msl args)
    struct { uint64_t src, dst, args; uint32_t groups, stride, topology, capacity; } pj = {raw, packed, args, (uint32_t)groups, gs->geo_index_stride, gs->geo_output, (uint32_t)(packed_size / 4)};
    memcpy(pjob, &pj, sizeof pj);
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTL4RenderCommandEncoder> re;
    if (run) {
        if (!g_gr.active) geo_run_begin();
        geo_runset_add(&g_gr.rs, h_gw, h_ngw, h_gk, h_fr, h_nfr, h_fk); geo_runset_add_fw(&g_gr.rs, h_fw, h_nfw, h_fwk);
        g_gr.rs.gml |= (h_gk && geo_gmem_writes(base)) | (h_fwk && geo_gmem_writes(pr->sh[1])) << 1;   // 按预测记的池表写（之后每笔 geo_runset_gml 补全）
        if (g_gml_on) { geo_runset_note(&g_gr.rs, h_cap, h_ncap); geo_runset_note(&g_gr.rs, h_gr, h_ngr); geo_runset_note(&g_gr.rs, h_gw, h_ngw); geo_runset_note(&g_gr.rs, h_fr, h_nfr); }
        g_gr.draws++; geo_lane(0); re = g_gr.cap;
    } else {
        MTL4RenderPassDescriptor *rd = pass_desc(); rd.renderTargetWidth = rd.renderTargetHeight = rd.defaultRasterSampleCount = 1;
        re = enc_r_begin(rd);
    }
    if (!run || g_gr.cap_pso != capture) { enc_r_pso(re, capture); if (run) g_gr.cap_pso = capture; }   // the capture lane keeps its pipeline across the run's draws
    bind_vbufs(re);
    p_draw vertex_range = {.first = (int32_t)first, .count = (int32_t)span, .instances = instances, .base_instance = (int32_t)first_instance};
    vconv_bind(re, vs, 1, &vertex_range, NULL);
    args_dirty_all(); encode_args(re, vs, 0, 1); enc_r_vbuf(re, 13, capture_info);
    if (di0) enc_r_draw_indexed(re, MTLPrimitiveTypePoint, unique_count, MTLIndexTypeUInt32, capture_ix, nu * 4, instances, di.base_vertex, first_instance);
    else enc_r_draw_instanced(re, MTLPrimitiveTypePoint, dw.first, dw.count, instances, first_instance);
    if (!run) enc_r_end(re);
    g_geo_bind[0] = input; g_geo_bind[1] = output; g_geo_bind[2] = raw; g_geo_bind[3] = info; g_geo_bind[4] = map;
    g_geo_size[0] = input_size; g_geo_size[1] = output_size; g_geo_size[2] = raw_size; g_geo_size[3] = 32; g_geo_size[4] = words * 4;
    id<MTL4ComputeCommandEncoder> ce;
    if (run && !g_gr.active) MDIE("geometry run ended inside its draw's capture (an encoder or commit from encode_args)");
    if (run) {
        geo_lane(1); ce = g_gr.gs;
        geo_rg rd[32], wr[32]; int nrd, nwr, known = geo_gs_ranges(gs, rd, &nrd, wr, &nwr, 32);
        if (!known || geo_hz_conflict(&g_gr.hz, rd, nrd, wr, nwr)) { if (g_gr.kernels) { enc_c_inner_barrier(ce); g_gr.barriers++; } memset(&g_gr.hz, 0, sizeof g_gr.hz); }
        if (!known) g_gr.hz.all = 1; else geo_hz_add(&g_gr.hz, rd, nrd, wr, nwr);
        g_gr.kernels++;
    } else ce = enc_c_begin(NULL);
    args_dirty_all(); encode_args(ce, gs, 2, 0); enc_c_pso(ce, gs->geo_pso);
    enc_c_dispatch(ce, MTLSizeMake((np + 31) / 32, instances, gs->geo_invocations), MTLSizeMake(32, 1, 1));
    // S2Arm 11-05 能耗线（金刚：一帧 790 笔几何绘制，每笔 4 个编码器）：索引压缩读几何核写的记录，同一个计算编码器里隔一道编码器内屏障接着做，
    //   不再另开一个编码器（少一次编码器切换与入口全量屏障）。参数表在每次派发编码时取当时内容，几何核的绑定不受后面改槽 0 影响（原先两个编码器也共用 g_ct）
    if (fast) { if (run) geo_lane(0); else enc_c_end(ce); g_geo_pt_draws++; }
    else if (run) {   // the compaction waits for the run's end (geo_run_flush), after every geometry kernel
        if (g_gr.njobs == g_gr.cjobs) { g_gr.cjobs = g_gr.cjobs ? 2 * g_gr.cjobs : 256; g_gr.jobs = realloc(g_gr.jobs, g_gr.cjobs * sizeof *g_gr.jobs); if (!g_gr.jobs) MDIE("geometry run: out of memory"); }
        g_gr.jobs[g_gr.njobs++] = job; g_gr.pack = pack; geo_lane(0);
    } else {
        enc_c_inner_barrier(ce);
        enc_c_pso(ce, pack); enc_c_args(ce, job, 0);   // one threadgroup, as many threads as the pipeline takes up to 1024 (whole SIMD groups): see k_nvn_geo_pack_msl
        enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(MIN(pack.maxTotalThreadsPerThreadgroup, 1024) / 32 * 32, 1, 1)); enc_c_end(ce);
    }
    if (tf && !geo_tf(gs->geo_tf_stride[0] || gs->geo_tf_stride[1] || gs->geo_tf_stride[2] || gs->geo_tf_stride[3] ? gs : base, output, packed, args, packed_size / 4)) nvn_be_bad_draw_feat();   // the capture (see geo_tf)
    args_dirty_all(); if (!run) { g_enc_pso = nil; g_enc_dss = nil; g_ed.ok = 0; }   // in a run the main pass's encoder state is unchanged (the lane encoders are others)
    swrite_note(pr); udc_note_draw(pr); g_wr_epoch++; g_mdx_epoch++;
    if (S.rast_discard) return;
    NvProg *raster = pr->geo_raster;
    if (!raster || raster->sh[0] != reader || raster->sh[1] != pr->sh[1]) {
        raster = [NvProg new]; raster->sh[0] = reader; raster->sh[1] = pr->sh[1]; raster->gp = pr->gp; pr->geo_raster = raster;   // gp: the fragment stage's guest program (its sampler-emulation variant, se_want)
    }
    g_geo_program = raster; g_geo_indices = fast ? map : packed; g_geo_index_bytes = fast ? words * 4 : packed_size; g_geo_args = args;   // fast: the input primitives' capture indices (map) are the main pass's
    p_draw synthetic = {.prim = gs->geo_output == 1 ? 0 : gs->geo_output == 6 ? 1 : 4, .count = 3, .instances = 1, .base_instance = (int32_t)first_instance};
    if (run) { geo_lane(2); if (!g_enc) { g_game_barrier = 1; main_barrier_reset(); } }   // the main pass opened in lane 2 waits for everything before it: the compactions in lane 1
    draw(&synthetic, NULL);
    if (run) { geo_lane(0); if (!g_gr.active) MDIE("geometry run ended inside its draw's main-pass draw"); }
    g_geo_program = nil; args_dirty_all();
    static int once; if (!once++) MLOG("geometry compute: vertex %s, geometry %s, %llu input primitives, %d instances", vs->key, gs->key, (unsigned long long)np, instances);
    if (fast && (g_geo_pt_draws == 1 || g_geo_pt_draws % 20000 == 0)) MLOG("geometry passthrough fast path: %llu draws (kernel %s, main pass reads the vertex capture, no records, no compaction)", (unsigned long long)g_geo_pt_draws, gs->key);
}

// ---------- Single-draw vertex capture (diagnostic DM_NVN_VCAP=<in-frame draw index>, frame replay: graphics/nvn/docs/frame_replay.md) ----------
// Before that draw runs, its vertex shader's capture entry point (main0_gs, the one geo_draw uses) runs once over the draw's vertex range with the same vertex buffers, arguments and
// instances, and the replay waits for it (mdi_wait): <S2A_DOCS or cwd>/vcap_f<frame>_d<n>.tsv gets a row per vertex (vertex, instance, clip x y z w, x/w, y/w). The capture entry has no
// edge-push tail (dmsh_build.py vs_push), so these are the positions before the widen push; draw() appends the draw's push parameters (g_wd_push) to the same file.
// Not handled (a red line, the draw itself unchanged): indirect draws, a vertex shader without the capture entry
static char g_vcap_path[1200]; static int g_vcap_hit;
static void vcap_draw(NvProg *pr, const p_draw *dw, const p_draw_idx *di, uint64_t frame, long n) {
    NvShader *vs = pr->sh[0];
    if (!vs || !vs->geo_fn || (dw ? dw->ind : di->ind)) { MLOG("【红】 DM_NVN_VCAP draw %ld: %s, not captured", n, !vs ? "no vertex shader" : !vs->geo_fn ? "the vertex shader has no capture entry point" : "an indirect draw"); return; }
    id<MTLRenderPipelineState> capture = geo_capture_pso(vs); if (!capture) return;
    mdi_wait();   // index / vertex data the GPU may still be writing, and a clean point to encode from
    int instances = dw ? dw->instances : di->instances; if (instances <= 0) instances = 1;
    uint32_t first_instance = (uint32_t)(dw ? dw->base_instance : di->base_instance);
    int64_t first; uint64_t span;
    if (dw) { first = dw->first; span = dw->count > 0 ? (uint64_t)dw->count : 0; }
    else {   // the index range the draw uses, read on the CPU (as geo_draw)
        int isz = 1 << di->itype; uint32_t lo = UINT32_MAX, hi = 0;
        if (di->itype < 0 || di->itype > 2 || di->count <= 0 || !nvn_host_readable(di->ibuf, (uint64_t)di->count * isz)) { MLOG("【红】 DM_NVN_VCAP draw %ld: index buffer not readable", n); return; }
        for (int i = 0; i < di->count; i++) { uint32_t v = 0; memcpy(&v, (const uint8_t *)(uintptr_t)di->ibuf + (size_t)i * isz, isz); if (S.restart.on && v == (S.restart.index & (isz == 1 ? UINT8_MAX : isz == 2 ? UINT16_MAX : UINT32_MAX))) continue; lo = MIN(lo, v); hi = MAX(hi, v); }
        if (lo > hi) return;
        first = (int64_t)lo + di->base_vertex; span = (uint64_t)hi - lo + 1;
    }
    if (!span || first < 0 || span * (uint64_t)instances > (64ull << 20) / (144 * 4)) { MLOG("【红】 DM_NVN_VCAP draw %ld: vertex range %lld+%llu × %d out of bounds", n, (long long)first, (unsigned long long)span, instances); return; }
    id<MTLBuffer> out = [g_dev newBufferWithLength:span * instances * 144 * 4 options:MTLResourceStorageModeShared]; res_add(out);
    id<MTLBuffer> ib; size_t io = arena_alloc(32, &ib); uint8_t *ip = (uint8_t *)ib.contents + io;
    uint64_t ci[2] = {out.gpuAddress, 0}; uint32_t cc[4] = {(uint32_t)first, (uint32_t)span, first_instance, (uint32_t)instances}; memcpy(ip, ci, 16); memcpy(ip + 16, cc, 16);
    lc_land(); rp_flush(); rp_end(); ubd_land();
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    MTL4RenderPassDescriptor *rd = pass_desc(); rd.renderTargetWidth = rd.renderTargetHeight = rd.defaultRasterSampleCount = 1;
    id<MTL4RenderCommandEncoder> re = enc_r_begin(rd); enc_r_pso(re, capture); bind_vbufs(re);
    p_draw range = {.first = (int32_t)first, .count = (int32_t)span, .instances = instances, .base_instance = (int32_t)first_instance};
    vconv_bind(re, vs, 1, &range, NULL);
    args_dirty_all(); encode_args(re, vs, 0, 1); enc_r_vbuf(re, 13, ib.gpuAddress + io);
    enc_r_draw_instanced(re, MTLPrimitiveTypePoint, (NSUInteger)first, (NSUInteger)span, (NSUInteger)instances, first_instance);
    enc_r_end(re);
    args_dirty_all(); g_enc_pso = nil; g_enc_dss = nil; g_ed.ok = 0;
    mdi_wait();
    const char *dir = getenv("S2A_DOCS"); snprintf(g_vcap_path, sizeof g_vcap_path, "%s/vcap_f%llu_d%ld.tsv", dir && *dir ? dir : ".", (unsigned long long)frame, n);
    FILE *f = fopen(g_vcap_path, "w"); if (!f) { MLOG("【红】 DM_NVN_VCAP: cannot write %s", g_vcap_path); return; }
    fprintf(f, "# vs %s fs %s, %s draw, vertices %lld..%lld, %d instances; clip-space position before the widen push\nvertex\tinstance\tx\ty\tz\tw\tx/w\ty/w\n", vs->key, pr->sh[1] ? pr->sh[1]->key : "-", dw ? "plain" : "indexed", (long long)first, (long long)(first + (int64_t)span - 1), instances);
    const float *v = out.contents; float mn = INFINITY, mx = -INFINITY;
    for (int in = 0; in < instances; in++) for (uint64_t k = 0; k < span; k++) { const float *p = v + ((uint64_t)in * span + k) * 144; float t = p[3] != 0 ? p[0] / p[3] : NAN;
        fprintf(f, "%lld\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n", (long long)(first + (int64_t)k), in, p[0], p[1], p[2], p[3], t, p[3] != 0 ? p[1] / p[3] : NAN); if (t == t) { mn = MIN(mn, t); mx = MAX(mx, t); } }
    fclose(f); g_vcap_hit = 1;
    MLOG("DM_NVN_VCAP draw %ld (frame %llu): %llu vertices × %d instances of vs %s, clip x/w %.4f .. %.4f → %s", n, (unsigned long long)frame, (unsigned long long)span, instances, vs->key, mn, mx, g_vcap_path);
}

// ---------- S2Arm vertex-stage side effects under rasterizer discard (10-27, Xenoblade 3) ----------
// A vertex shader that writes a storage buffer runs for its writes alone with the rasterizer discarded: Xenoblade 3 skins its characters so, one draw a model between
// SetRasterizerDiscard(1) / (0) with no transform feedback begun, and the character draws read the skinned vertices back. tf_draw dropped every discarded draw without
// feedback as harmless, so the skinned buffers were never written and Noah, the party and the enemies were invisible (10-27 xc3_1027101629_1; the Mac the same).
// Metal runs no vertex function with rasterization off unless it returns void: the shader's geometry capture entry point (main0_gs, dmsh_geometry.py capture) is that function,
// its stores of the vertex outputs going into a scratch buffer nothing reads, in an encoder of its own as geo_draw's capture pass. An indexed draw runs over the index range it
// uses (read on the CPU, as geo_draw does, after the GPU work that may write the indices). → 1 when the draw is handled here (run, or dropped with a red line), 0 when the
// vertex shader writes nothing and the caller skips the draw as before
static int sx_draw(NvProg *pr, const p_draw *dw0, const p_draw_idx *di0) {
    NvShader *vs = pr ? pr->sh[0] : nil;
    if (!vs || !shader_writes(vs)) return 0;
    static int said;
    if (!vs->geo_fn || pr->sh[2] || pr->sh[3] || pr->sh[4]) { if (!said++) GEO_RED("【红】 rasterizer discard: vertex shader %s writes storage but %s: not run", vs->key, vs->geo_fn ? "the pipeline has a geometry / tessellation stage" : "has no capture entry point"); else nvn_be_bad_draw_feat(); return 1; }
    p_draw dw = dw0 ? *dw0 : (p_draw){0}; p_draw_idx di = di0 ? *di0 : (p_draw_idx){0};
    if ((dw0 ? dw.ind : di.ind) || (dw0 ? dw.mdi_cnt : di.mdi_cnt)) { if (!said++) GEO_RED("【红】 rasterizer discard: indirect draw of vertex shader %s that writes storage: not run", vs->key); else nvn_be_bad_draw_feat(); return 1; }
    int count = dw0 ? dw.count : di.count, instances = dw0 ? dw.instances : di.instances;
    uint32_t first_instance = (uint32_t)(dw0 ? dw.base_instance : di.base_instance);
    if (count <= 0 || instances < 0) return 1;
    if (!instances) instances = 1;
    id<MTLRenderPipelineState> capture = geo_capture_pso(vs); if (!capture) { nvn_be_bad_draw_feat(); return 1; }
    if (defer_has_active()) defer_fallback();
    lc_land(); rp_flush(); rp_end(); ubd_land();
    int64_t first = dw.first; uint64_t span = (uint64_t)count; uint32_t *uix = NULL; size_t nu = 0;
    if (di0) {   // the vertices the indices name, each once (sorted, as geo_draw's capture), drawn as 32-bit indices: NVN's 8-bit indices have no Metal type
        int isz = di.itype >= 0 && di.itype <= 2 ? 1 << di.itype : 0;
        if (!isz || !nvn_host_readable(di.ibuf, (uint64_t)count * isz)) { if (!said++) GEO_RED("【红】 rasterizer discard: index buffer of vertex shader %s not readable: not run", vs->key); else nvn_be_bad_draw_feat(); return 1; }
        mdi_wait(); if (g_mdi_ev.signaledValue < g_mdi_v) return 1;
        uint32_t restart_index = S.restart.index & (isz == 1 ? UINT8_MAX : isz == 2 ? UINT16_MAX : UINT32_MAX), lo = UINT32_MAX, hi = 0;
        if (!(uix = malloc((size_t)count * 4))) { GEO_RED("【红】 rasterizer discard: index allocation failed"); return 1; }
        for (int i = 0; i < count; i++) { uint32_t v = 0; memcpy(&v, (const uint8_t *)(uintptr_t)di.ibuf + (size_t)i * isz, isz); if (S.restart.on && v == restart_index) continue; lo = MIN(lo, v); hi = MAX(hi, v); uix[nu++] = v; }
        if (lo > hi) { free(uix); return 1; }
        static uint64_t *uq_bm; static size_t uq_words; nu = nvn_geo_unique_sorted(uix, nu, lo, hi, uix, &uq_bm, &uq_words);   // submit thread only
        first = (int64_t)lo + di.base_vertex; span = (uint64_t)hi - lo + 1;
    }
    uint64_t bytes = span * (uint64_t)instances * 144 * 4;   // main0_gs stores 144 words a vertex (dmsh_geometry.py capture)
    if (first < 0 || first + span > (uint64_t)UINT32_MAX + 1 || bytes > (256ull << 20)) { free(uix); if (!said++) GEO_RED("【红】 rasterizer discard: vertex shader %s over %llu vertices × %d instances exceeds the scratch bound: not run", vs->key, (unsigned long long)span, instances); else nvn_be_bad_draw_feat(); return 1; }
    id<MTLBuffer> scratch; size_t off = arena_alloc((size_t)(bytes + nu * 4 + 512), &scratch);
    uint8_t *cpu = (uint8_t *)scratch.contents + off; uint64_t gpu = scratch.gpuAddress + off, ix = (gpu + 255) & ~255ull, info = (ix + nu * 4 + 255) & ~255ull, dst = info + 256;
    if (nu) { memcpy(cpu + (ix - gpu), uix, nu * 4); } free(uix);
    uint64_t ci[2] = {dst, 0}; uint32_t cc[4] = {(uint32_t)first, (uint32_t)span, first_instance, (uint32_t)instances};
    memcpy(cpu + (info - gpu), ci, 16); memcpy(cpu + (info - gpu) + 16, cc, 16);
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    MTL4RenderPassDescriptor *rd = pass_desc(); rd.renderTargetWidth = rd.renderTargetHeight = rd.defaultRasterSampleCount = 1;
    id<MTL4RenderCommandEncoder> re = enc_r_begin(rd); enc_r_pso(re, capture); bind_vbufs(re);
    p_draw vertex_range = {.first = (int32_t)first, .count = (int32_t)span, .instances = instances, .base_instance = (int32_t)first_instance};
    g_draw_binst = first_instance;
    vconv_bind(re, vs, 1, &vertex_range, NULL);
    wd_drop(); args_dirty_all(); encode_args(re, vs, 0, 1); enc_r_vbuf(re, 13, info);   // 宽屏不改写只产出数据的绘制（widen_glue.inc wd_drop）
    if (di0) enc_r_draw_indexed(re, MTLPrimitiveTypePoint, nu, MTLIndexTypeUInt32, ix, nu * 4, instances, di.base_vertex, first_instance);
    else enc_r_draw_instanced(re, MTLPrimitiveTypePoint, dw.first, count, instances, first_instance);
    enc_r_end(re);
    args_dirty_all(); g_enc_pso = nil; g_enc_dss = nil; g_ed.ok = 0;
    swrite_note(pr); udc_note_draw(pr); g_wr_epoch++; g_mdx_epoch++;
    static int once; if (!once++) MLOG("rasterizer discard: vertex shader %s that writes storage run for its writes (%s, %llu vertices, %d instances)", vs->key, di0 ? "indexed" : "array", (unsigned long long)span, instances);
    return 1;
}
