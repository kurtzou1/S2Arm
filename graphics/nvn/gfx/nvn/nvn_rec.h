// Deferred encoding (DM_NVN_ENC_THREAD=1; included by nvn_mtl.m only): the replay's Metal encoding runs on a worker thread while the submit thread goes on translating.
// About 40% of the submit thread's time was spent inside Metal itself: encoder creation, draw calls, state setters and argument table writes (Breath of the Wild: about 2.7 of 6.5 ms a frame).
// With this switch the replay talks to stand-ins for the main command buffer, its encoders and the argument tables it rewrites per draw. Each call becomes a fixed-size record (objects retained);
// records go to the encode thread in blocks, and the encode thread makes the same calls in the same order on the real objects. Commits of the main command buffer and of upload batches, and
// event signals, are records too, so the queue sees work in exactly the order it did before. The submit thread waits for the encode thread to finish (rec_drain) at the end of each submission
// and before anything that waits for the GPU or uses another queue, so nothing outside the submission can tell the difference.
// Everything else the replay creates (textures, views, pipelines, buffers, residency) stays on the submit thread: device calls, safe from any thread. Queue commits take the residency lock,
// since the submit thread may be adding to the set at the same time.
// A selector the stand-ins do not implement stops the host with its name (forwardingTargetForSelector), so a missing one cannot silently drop work.

// ---------- Copy queue: large uniform shadows (ubp_get) are filled by a worker thread ----------
// A shadow is the bytes of a uniform range as the GPU will read them at that point of the submission (nvn_mtl.m ubp_get): memory, or the previous shadow of the range, with the inline
// updates queued since laid over it. Breath of the Wild makes about 440 a frame, 14 MB of copies, a tenth of the submit thread's time. The submit thread queues the copies in order and
// goes on; one worker makes them in the same order (a shadow may start from the previous one). The GPU reads shadows only after its command buffer is committed, and every commit first
// waits for the copies queued before it (ubc_wait, from the encode thread when Metal encoding is deferred); a CPU read of a shadow waits for its own copies. DM_NVN_UB_COPY_THREAD=0
// copies on the submit thread as before
// Hand-off (ported from nxnative, MIT): the copy thread sleeps on g_ubc_head and a waiter on g_ubc_done (os_sync_wait_on_address via host/addr_wait.h: the kernel compares the word, so a change before the
// sleep is not lost), each woken only by the thread that advanced that word, after it did. A waker never clears the sleeper's flag; the sleeper does, once awake. A push whose wake call
// comes late can meet the flag the thread set for its next sleep, on a word that already includes that push: had the call taken the flag, the thread would sleep with it clear, the next
// push would not wake it and every later wait would hang. Waiters are counted for the same reason. No mutex: before, ubc_wait locked a mutex and signalled a condition on every spin
// while the copy thread slept, and the woken thread could not get that mutex back (nxnative's measurement: the replay thread spent half its busy time there, 170-330k instructions a
// draw against 32-48k)
typedef struct { void *d; const void *s; size_t n; } ubc_op;
enum { UBC_N = 8192, UBC_SPIN = 4096 };   // UBC_SPIN: a waiter's spins before it sleeps (the copies it waits for are usually a few KB)
static ubc_op g_ubc[UBC_N];
static _Alignas(128) _Atomic uint64_t g_ubc_head;   // ops queued (monotonic; the copy thread sleeps on it)
static _Alignas(128) _Atomic uint64_t g_ubc_done;   // ops made (a waiter sleeps on it)
static _Alignas(128) _Atomic uint32_t g_ubc_sleeping, g_ubc_waiting;   // the copy thread is asleep or about to be (it clears this itself) / waiters asleep or about to be
static _Atomic uint64_t g_ubc_wakes;   // wake calls made, both ways (t_nvn_ubc_wait)
#ifndef UBC_T_SLEEPING   // t_nvn_ubc_wait: holds the copy thread on its way to sleep, so that a late wake call lands there
#define UBC_T_SLEEPING() ((void)0)
#endif
static int ubc_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_UB_COPY_THREAD"); v = !(e && !strcmp(e, "0")); } return v; }
// Wake the copy thread if it sleeps; only ubc_push, after its store to g_ubc_head (pushes between the wake and the thread clearing its flag make a call each, harmless)
static inline void ubc_kick(void) {
    if (atomic_load(&g_ubc_sleeping)) { atomic_fetch_add_explicit(&g_ubc_wakes, 1, memory_order_relaxed); addr_wake_one64((void *)&g_ubc_head); }
}
static void *ubc_thread(void *arg) {
    (void)arg; pthread_setname_np("dm-ub-copy"); s2a_qos_set_self(S2A_QOS_UB_COPY);
    for (uint64_t t = 0;;) {
        uint64_t h = atomic_load_explicit(&g_ubc_head, memory_order_acquire);
        for (int spin = 0; spin < 2000 && t == h; spin++) h = atomic_load_explicit(&g_ubc_head, memory_order_acquire);   // a submission queues copies in bursts: stay awake a moment
        while (t == h) {   // the flag first, then the word (both sequentially consistent, as the pusher's store and flag load): a push sees the flag or this sees the push
            atomic_store(&g_ubc_sleeping, 1);
            if ((h = atomic_load(&g_ubc_head)) != t) break;
            UBC_T_SLEEPING();
            addr_wait64((void *)&g_ubc_head, t);   // returns at once if the word is no longer t; EINTR and spurious returns loop
            atomic_store(&g_ubc_sleeping, 0);   // awake: set again before the next sleep's look at the word
            h = atomic_load(&g_ubc_head);
        }
        atomic_store_explicit(&g_ubc_sleeping, 0, memory_order_relaxed);   // also when the look found a push
        for (; t < h; t++) { const ubc_op *o = &g_ubc[t % UBC_N]; memcpy(o->d, o->s, o->n); }
        atomic_store(&g_ubc_done, t);
        if (atomic_load(&g_ubc_waiting)) { atomic_fetch_add_explicit(&g_ubc_wakes, 1, memory_order_relaxed); addr_wake_all64((void *)&g_ubc_done); }
    }
    return NULL;
}
// Wait until the first seq ops are made (the replay thread, or the encode thread at a commit): spin a moment, then sleep on g_ubc_done
static void ubc_wait(uint64_t seq) {
    if (atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= seq) return;
    for (int spin = 0;; spin++) {   // the copies are queued, so the copy thread is awake or woken by their push
        if (spin < UBC_SPIN) { __builtin_arm_yield(); if (atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= seq) break; continue; }
        atomic_fetch_add(&g_ubc_waiting, 1);   // counted first, then the word (as the copy thread's store and count load): it sees this waiter or this sees its store
        uint64_t d = atomic_load(&g_ubc_done);
        if (d < seq) addr_wait64((void *)&g_ubc_done, d);
        atomic_fetch_sub(&g_ubc_waiting, 1);
        if (atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= seq) break;
    }
}
static inline uint64_t ubc_head(void) { return atomic_load_explicit(&g_ubc_head, memory_order_relaxed); }
// Queue a copy (submit thread only); returns the count of ops that must be made for it to be done
static uint64_t ubc_push(void *d, const void *s, size_t n) {
    static int started;
    if (!started) { pthread_t th; if (pthread_create(&th, NULL, ubc_thread, NULL)) MDIE("cannot start the uniform copy thread"); pthread_detach(th); started = 1; }
    uint64_t h = atomic_load_explicit(&g_ubc_head, memory_order_relaxed);
    if (h - atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= UBC_N) ubc_wait(h - UBC_N + 1);
    g_ubc[h % UBC_N] = (ubc_op){d, s, n};
    atomic_store_explicit(&g_ubc_head, h + 1, memory_order_release);
    ubc_kick();
    return h + 1;
}

enum {
    RO_CB_NEW, RO_CB_BEGIN, RO_CB_END, RO_COMMIT, RO_COMMIT_REAL, RO_SIGNAL,
    RO_RE_BEGIN, RO_CE_BEGIN, RO_END,
    RO_BAR_QUEUE, RO_BAR_AFTER_STAGES, RO_BAR_ENCODER,
    RO_R_TABLE, RO_R_PSO, RO_R_DSS, RO_R_VIEWPORT, RO_R_SCISSOR, RO_R_CULL, RO_R_WINDING, RO_R_FILL, RO_R_BIAS, RO_R_CLIP, RO_R_SREF, RO_R_BLEND, RO_R_VIS,
    RO_R_DRAW, RO_R_DRAW_INST, RO_R_DRAW_IND, RO_R_DRAW_IDX, RO_R_DRAW_IDX_IND, RO_R_STORE_C, RO_R_STORE_D, RO_R_STORE_S,
    RO_C_TABLE, RO_C_PSO, RO_C_DISPATCH, RO_C_DISPATCH_IND, RO_C_DISPATCH_THREADS, RO_C_COPY_BB, RO_C_COPY_BT, RO_C_COPY_TB, RO_C_COPY_TT, RO_C_FILL,
    RO_T_ADDR, RO_T_TEX, RO_T_SAMP,
    RO_LABEL, RO_R_TS, RO_C_TS,   // diagnostics: DM_NVN_ENC_LABEL, DM_NVN_GPUPROF
    // Metal 3 (the old encoders on this thread; DM_NVN_ENC_THREAD=1 there): what m3_wait / m4_end / m3_table_apply / blit_barrier and the buffer-and-offset draws ask of an encoder,
    // the copy encoder and the descriptor forms (GPUPROF's sample buffer rides on the descriptor), and a commit of g_q3 (completed handlers, the event signal, commit: m3_commit)
    RO_M3_WAIT, RO_M3_UPD, RO_M3_MB, RO_M3_BUF, RO_M3_TEX, RO_M3_SMP, RO_CB_BLIT, RO_CE_BEGIN_D, RO_COMMIT_M3,
    RO_R_DRAW_IND_B, RO_R_DRAW_IDX_B, RO_R_DRAW_IDX_IND_B, RO_C_DISPATCH_IND_B,
    RO_FX,   // NVN2 EvaluateDlss: a MetalFX temporal scaler encoded into the command buffer itself, its textures and parameters set right before (nvn_dlss.inc dlss_fx_run)
    RO_R_MESH, RO_R_MESH_IND, RO_R_MESH_IND_B,   // NVN2 task / mesh draws (nvn_mtl.m enc_r_mesh / enc_r_mesh_indirect): direct; indirect by GPU address (Metal 4) / buffer + offset (Metal 3)
};
typedef struct { uint32_t op, nobj; uint64_t a[15]; } rec_t;   // the first nobj slots hold retained objects (0 for nil), released once the call is made
enum { REC_BLK = 256 };
typedef struct rec_blk { struct rec_blk *next; int n; rec_t r[REC_BLK]; } rec_blk;

// On by default on iOS: Breath of the Wild on an iPhone 17 Pro Max (handheld, the Great Plateau) took about 8 ms of submit thread per frame without it and 3.3–4.5 ms with it
static int g_rec = -1;
static inline int rec_on(void) {
    if (__builtin_expect(g_rec >= 0, 1)) return g_rec;
    const char *e = getenv("DM_NVN_ENC_THREAD");
    if (g_m3) {
        // Metal 3：只在显式 =1 时开（编码器 / 参数表绑定需要额外适配，暂为保守方案）
        g_rec = e && atoi(e) > 0;
    } else {
#if TARGET_OS_IPHONE
        g_rec = !e || atoi(e) > 0;
#else
        g_rec = e && atoi(e) > 0;
#endif
    }
    if (g_rec) MLOG("Metal encoding runs on its own thread (DM_NVN_ENC_THREAD=0 turns it off)");
    return g_rec;
}
static pthread_mutex_t g_rb_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_rb_work = PTHREAD_COND_INITIALIZER, g_rb_idle = PTHREAD_COND_INITIALIZER;
static rec_blk *g_rb_cur, *g_rb_head, *g_rb_tail, *g_rb_free;   // the submit thread's open block; blocks waiting for the encode thread; empty blocks
static int g_rb_busy, g_rb_started, g_rb_sleeping;              // the encode thread is working through a block; the thread exists; it waits for work

static inline uint64_t rec_obj(id o) { return o ? (uint64_t)(uintptr_t)CFBridgingRetain(o) : 0; }
static inline id rec_id(uint64_t v) { return (__bridge id)(void *)(uintptr_t)v; }
static inline uint64_t rec_f(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float rec_fv(uint64_t v) { uint32_t u = (uint32_t)v; float f; memcpy(&f, &u, 4); return f; }

// ---------- The encode thread ----------
// Metal 3 (nvn_mtl.m): the argument tables are DmTable3, written and applied on the submit thread as without this thread (tab_*, m3_table_apply); what m3_table_apply sets on the
// encoder is recorded (RO_M3_BUF / TEX / SMP), so the real encoder gets the same calls in the same order. Fences are g_fence3; commits are m3_commit (defined after this include)
static void m3_commit(id<MTLCommandBuffer> cb, NSArray *fb, id<MTLSharedEvent> ev, uint64_t v);
static id<MTLCommandBuffer> m3_cb(void);
static id g_rx_cb, g_rx_enc;   // the encode thread's real command buffer and open encoder
static void dlss_fx_run(id cb, const uint64_t *a);   // nvn_dlss.inc: a[0] scaler, a[1..4] color / depth / motion / output (retained by the record), the rest its parameters
static void rec_exec(const rec_t *r) {
    const uint64_t *a = r->a; id e = g_rx_enc;
    switch (r->op) {
    case RO_CB_NEW: g_rx_cb = g_m3 ? [g_q3 commandBufferWithUnretainedReferences] : [g_dev newCommandBuffer]; break;   // Metal 3: as m3_cb
    case RO_CB_BEGIN: if (!g_m3) [(id<MTL4CommandBuffer>)g_rx_cb beginCommandBufferWithAllocator:rec_id(a[0])]; break;   // Metal 3: the old command buffer has no allocator
    case RO_CB_END: if (!g_m3) [(id<MTL4CommandBuffer>)g_rx_cb endCommandBuffer]; break;   // Metal 3: m3_commit takes a buffer without endCommandBuffer, as on the submit thread
    case RO_COMMIT: case RO_COMMIT_REAL: {
        if (r->op == RO_COMMIT) ubc_wait(a[2]);   // the uniform shadows this command buffer reads
        id<MTL4CommandBuffer> buffers[] = {r->op == RO_COMMIT ? g_rx_cb : rec_id(a[1])}; MTL4CommitOptions *o = rec_id(a[0]);
        if (gpu_go()) {   // GPU 安全停（nvn_mtl.m mtl_gpu_halt）后不交
            pthread_mutex_lock(&g_res_mu);
            if (o) [g_q4 commit:buffers count:1 options:o]; else [g_q4 commit:buffers count:1];
            pthread_mutex_unlock(&g_res_mu);
        }
        if (r->op == RO_COMMIT) g_rx_cb = nil;
        break; }
    case RO_SIGNAL: if (!mtl_gpu_halted()) [g_q4 signalEvent:rec_id(a[0]) value:a[1]]; break;
    case RO_FX: dlss_fx_run(g_rx_cb, a); break;
    case RO_RE_BEGIN: g_rx_enc = [(id<MTL4CommandBuffer>)g_rx_cb renderCommandEncoderWithDescriptor:rec_id(a[0])]; break;
    case RO_CE_BEGIN: g_rx_enc = [(id<MTL4CommandBuffer>)g_rx_cb computeCommandEncoder]; break;
    case RO_END: [(id<MTL4CommandEncoder>)e endEncoding]; g_rx_enc = nil; break;
    case RO_BAR_QUEUE: [(id<MTL4CommandEncoder>)e barrierAfterQueueStages:a[0] beforeStages:a[1] visibilityOptions:a[2]]; break;
    case RO_BAR_AFTER_STAGES: [(id<MTL4CommandEncoder>)e barrierAfterStages:a[0] beforeQueueStages:a[1] visibilityOptions:a[2]]; break;
    case RO_BAR_ENCODER: [(id<MTL4CommandEncoder>)e barrierAfterEncoderStages:a[0] beforeEncoderStages:a[1] visibilityOptions:a[2]]; break;
    case RO_R_TABLE: [(id<MTL4RenderCommandEncoder>)e setArgumentTable:rec_id(a[0]) atStages:a[1]]; break;
    case RO_R_PSO: [(id<MTL4RenderCommandEncoder>)e setRenderPipelineState:rec_id(a[0])]; break;
    case RO_R_DSS: [(id<MTL4RenderCommandEncoder>)e setDepthStencilState:rec_id(a[0])]; break;
    case RO_R_VIEWPORT: { MTLViewport v; memcpy(&v, a, sizeof v); [(id<MTL4RenderCommandEncoder>)e setViewport:v]; break; }
    case RO_R_SCISSOR: { MTLScissorRect s; memcpy(&s, a, sizeof s); [(id<MTL4RenderCommandEncoder>)e setScissorRect:s]; break; }
    case RO_R_CULL: [(id<MTL4RenderCommandEncoder>)e setCullMode:a[0]]; break;
    case RO_R_WINDING: [(id<MTL4RenderCommandEncoder>)e setFrontFacingWinding:a[0]]; break;
    case RO_R_FILL: [(id<MTL4RenderCommandEncoder>)e setTriangleFillMode:a[0]]; break;
    case RO_R_BIAS: [(id<MTL4RenderCommandEncoder>)e setDepthBias:rec_fv(a[0]) slopeScale:rec_fv(a[1]) clamp:rec_fv(a[2])]; break;
    case RO_R_CLIP: [(id<MTL4RenderCommandEncoder>)e setDepthClipMode:a[0]]; break;
    case RO_R_SREF: [(id<MTL4RenderCommandEncoder>)e setStencilFrontReferenceValue:(uint32_t)a[0] backReferenceValue:(uint32_t)a[1]]; break;
    case RO_R_BLEND: [(id<MTL4RenderCommandEncoder>)e setBlendColorRed:rec_fv(a[0]) green:rec_fv(a[1]) blue:rec_fv(a[2]) alpha:rec_fv(a[3])]; break;
    case RO_R_VIS: [(id<MTL4RenderCommandEncoder>)e setVisibilityResultMode:a[0] offset:a[1]]; break;
    case RO_R_DRAW: [(id<MTL4RenderCommandEncoder>)e drawPrimitives:a[0] vertexStart:a[1] vertexCount:a[2]]; break;
    case RO_R_DRAW_INST: [(id<MTL4RenderCommandEncoder>)e drawPrimitives:a[0] vertexStart:a[1] vertexCount:a[2] instanceCount:a[3] baseInstance:a[4]]; break;
    case RO_R_DRAW_IND: [(id<MTL4RenderCommandEncoder>)e drawPrimitives:a[0] indirectBuffer:a[1]]; break;
    case RO_R_DRAW_IDX: [(id<MTL4RenderCommandEncoder>)e drawIndexedPrimitives:a[0] indexCount:a[1] indexType:a[2] indexBuffer:a[3] indexBufferLength:a[4] instanceCount:a[5] baseVertex:(NSInteger)a[6] baseInstance:a[7]]; break;
    case RO_R_DRAW_IDX_IND: [(id<MTL4RenderCommandEncoder>)e drawIndexedPrimitives:a[0] indexType:a[1] indexBuffer:a[2] indexBufferLength:a[3] indirectBuffer:a[4]]; break;
    case RO_R_STORE_C: [(id<MTL4RenderCommandEncoder>)e setColorStoreAction:a[0] atIndex:a[1]]; break;
    case RO_R_STORE_D: [(id<MTL4RenderCommandEncoder>)e setDepthStoreAction:a[0]]; break;
    case RO_R_STORE_S: [(id<MTL4RenderCommandEncoder>)e setStencilStoreAction:a[0]]; break;
    case RO_C_TABLE: [(id<MTL4ComputeCommandEncoder>)e setArgumentTable:rec_id(a[0])]; break;
    case RO_C_PSO: [(id<MTL4ComputeCommandEncoder>)e setComputePipelineState:rec_id(a[0])]; break;
    case RO_C_DISPATCH: [(id<MTL4ComputeCommandEncoder>)e dispatchThreadgroups:MTLSizeMake(a[0], a[1], a[2]) threadsPerThreadgroup:MTLSizeMake(a[3], a[4], a[5])]; break;
    case RO_C_DISPATCH_IND: [(id<MTL4ComputeCommandEncoder>)e dispatchThreadgroupsWithIndirectBuffer:a[0] threadsPerThreadgroup:MTLSizeMake(a[1], a[2], a[3])]; break;
    case RO_C_DISPATCH_THREADS: [(id<MTL4ComputeCommandEncoder>)e dispatchThreads:MTLSizeMake(a[0], a[1], a[2]) threadsPerThreadgroup:MTLSizeMake(a[3], a[4], a[5])]; break;
    case RO_C_COPY_BB: [(id<MTL4ComputeCommandEncoder>)e copyFromBuffer:rec_id(a[0]) sourceOffset:a[2] toBuffer:rec_id(a[1]) destinationOffset:a[3] size:a[4]]; break;
    case RO_C_COPY_BT: [(id<MTL4ComputeCommandEncoder>)e copyFromBuffer:rec_id(a[0]) sourceOffset:a[2] sourceBytesPerRow:a[3] sourceBytesPerImage:a[4] sourceSize:MTLSizeMake(a[5], a[6], a[7])
                           toTexture:rec_id(a[1]) destinationSlice:a[8] destinationLevel:a[9] destinationOrigin:MTLOriginMake(a[10], a[11], a[12])]; break;
    case RO_C_COPY_TB: [(id<MTL4ComputeCommandEncoder>)e copyFromTexture:rec_id(a[0]) sourceSlice:a[2] sourceLevel:a[3] sourceOrigin:MTLOriginMake(a[4], a[5], a[6]) sourceSize:MTLSizeMake(a[7], a[8], a[9])
                           toBuffer:rec_id(a[1]) destinationOffset:a[10] destinationBytesPerRow:a[11] destinationBytesPerImage:a[12]]; break;
    case RO_C_COPY_TT: [(id<MTL4ComputeCommandEncoder>)e copyFromTexture:rec_id(a[0]) sourceSlice:a[2] sourceLevel:a[3] sourceOrigin:MTLOriginMake(a[4], a[5], a[6]) sourceSize:MTLSizeMake(a[7], a[8], a[9])
                           toTexture:rec_id(a[1]) destinationSlice:a[10] destinationLevel:a[11] destinationOrigin:MTLOriginMake(a[12], a[13], a[14])]; break;
    case RO_C_FILL: [(id<MTL4ComputeCommandEncoder>)e fillBuffer:rec_id(a[0]) range:NSMakeRange(a[1], a[2]) value:(uint8_t)a[3]]; break;
    case RO_T_ADDR: [(id<MTL4ArgumentTable>)rec_id(a[0]) setAddress:a[1] atIndex:a[2]]; break;
    case RO_T_TEX: [(id<MTL4ArgumentTable>)rec_id(a[0]) setTexture:(MTLResourceID){a[1]} atIndex:a[2]]; break;
    case RO_T_SAMP: [(id<MTL4ArgumentTable>)rec_id(a[0]) setSamplerState:(MTLResourceID){a[1]} atIndex:a[2]]; break;
    case RO_LABEL: [(id<MTL4CommandEncoder>)e setLabel:rec_id(a[0])]; break;
    case RO_R_TS: [(id<MTL4RenderCommandEncoder>)e writeTimestampWithGranularity:a[1] afterStage:a[2] intoHeap:rec_id(a[0]) atIndex:a[3]]; break;
    case RO_C_TS: [(id<MTL4ComputeCommandEncoder>)e writeTimestampWithGranularity:a[1] intoHeap:rec_id(a[0]) atIndex:a[2]]; break;
    // Metal 3: the old encoders. The fence is g_fence3 in every case (m3_wait / m4_end); a[0] says render (stages in a[1]) or not
    case RO_M3_WAIT: if (a[0]) [(id<MTLRenderCommandEncoder>)e waitForFence:g_fence3 beforeStages:(MTLRenderStages)a[1]]; else [(id<MTLBlitCommandEncoder>)e waitForFence:g_fence3]; break;
    case RO_M3_UPD: if (a[0]) [(id<MTLRenderCommandEncoder>)e updateFence:g_fence3 afterStages:(MTLRenderStages)a[1]]; else [(id<MTLBlitCommandEncoder>)e updateFence:g_fence3]; break;
    case RO_M3_MB: [(id<MTLComputeCommandEncoder>)e memoryBarrierWithScope:(MTLBarrierScope)a[0]]; break;
    case RO_M3_BUF:   // a[1]: 0 vertex, 1 fragment, 2 compute, 3 object, 4 mesh (m3_table_apply)
        if (a[1] == 0) [(id<MTLRenderCommandEncoder>)e setVertexBuffer:rec_id(a[0]) offset:a[2] atIndex:a[3]];
        else if (a[1] == 1) [(id<MTLRenderCommandEncoder>)e setFragmentBuffer:rec_id(a[0]) offset:a[2] atIndex:a[3]];
        else if (a[1] == 3) [(id<MTLRenderCommandEncoder>)e setObjectBuffer:rec_id(a[0]) offset:a[2] atIndex:a[3]];
        else if (a[1] == 4) [(id<MTLRenderCommandEncoder>)e setMeshBuffer:rec_id(a[0]) offset:a[2] atIndex:a[3]];
        else [(id<MTLComputeCommandEncoder>)e setBuffer:rec_id(a[0]) offset:a[2] atIndex:a[3]];
        break;
    case RO_M3_TEX:
        if (a[1] == 0) [(id<MTLRenderCommandEncoder>)e setVertexTexture:rec_id(a[0]) atIndex:a[2]];
        else if (a[1] == 1) [(id<MTLRenderCommandEncoder>)e setFragmentTexture:rec_id(a[0]) atIndex:a[2]];
        else if (a[1] == 3) [(id<MTLRenderCommandEncoder>)e setObjectTexture:rec_id(a[0]) atIndex:a[2]];
        else if (a[1] == 4) [(id<MTLRenderCommandEncoder>)e setMeshTexture:rec_id(a[0]) atIndex:a[2]];
        else [(id<MTLComputeCommandEncoder>)e setTexture:rec_id(a[0]) atIndex:a[2]];
        break;
    case RO_M3_SMP:
        if (a[1] == 0) [(id<MTLRenderCommandEncoder>)e setVertexSamplerState:rec_id(a[0]) atIndex:a[2]];
        else if (a[1] == 1) [(id<MTLRenderCommandEncoder>)e setFragmentSamplerState:rec_id(a[0]) atIndex:a[2]];
        else if (a[1] == 3) [(id<MTLRenderCommandEncoder>)e setObjectSamplerState:rec_id(a[0]) atIndex:a[2]];
        else if (a[1] == 4) [(id<MTLRenderCommandEncoder>)e setMeshSamplerState:rec_id(a[0]) atIndex:a[2]];
        else [(id<MTLComputeCommandEncoder>)e setSamplerState:rec_id(a[0]) atIndex:a[2]];
        break;
    case RO_CB_BLIT: g_rx_enc = [(id<MTLCommandBuffer>)g_rx_cb blitCommandEncoder]; break;
    case RO_CE_BEGIN_D: g_rx_enc = [(id<MTLCommandBuffer>)g_rx_cb computeCommandEncoderWithDescriptor:rec_id(a[0])]; break;
    case RO_COMMIT_M3: {   // a[0] handlers (NSArray or nil), a[1] event (or nil), a[2] a real command buffer (an upload batch) or 0 for the main one, a[3] the event value, a[4] the uniform shadows the main one reads
        id<MTLCommandBuffer> cb = a[2] ? rec_id(a[2]) : g_rx_cb;
        if (!a[2]) ubc_wait(a[4]);   // same calls as m3_commit on the submit thread (which does not end the buffer either)
        m3_commit(cb, rec_id(a[0]), rec_id(a[1]), a[3]);
        if (!a[2]) g_rx_cb = nil;
        break; }
    case RO_R_DRAW_IND_B: [(id<MTLRenderCommandEncoder>)e drawPrimitives:a[1] indirectBuffer:rec_id(a[0]) indirectBufferOffset:a[2]]; break;
    case RO_R_DRAW_IDX_B: [(id<MTLRenderCommandEncoder>)e drawIndexedPrimitives:a[1] indexCount:a[2] indexType:a[3] indexBuffer:rec_id(a[0]) indexBufferOffset:a[4] instanceCount:a[5] baseVertex:(NSInteger)a[6] baseInstance:a[7]]; break;
    case RO_R_DRAW_IDX_IND_B: [(id<MTLRenderCommandEncoder>)e drawIndexedPrimitives:a[2] indexType:a[3] indexBuffer:rec_id(a[0]) indexBufferOffset:a[4] indirectBuffer:rec_id(a[1]) indirectBufferOffset:a[5]]; break;
    case RO_C_DISPATCH_IND_B: [(id<MTLComputeCommandEncoder>)e dispatchThreadgroupsWithIndirectBuffer:rec_id(a[0]) indirectBufferOffset:a[1] threadsPerThreadgroup:MTLSizeMake(a[2], a[3], a[4])]; break;
    // NVN2 task / mesh draws: the selector of the direct one is the same on both encoders; a[1] / a[2] threads per object / mesh threadgroup
    case RO_R_MESH: [e drawMeshThreadgroups:MTLSizeMake(a[0], 1, 1) threadsPerObjectThreadgroup:MTLSizeMake(a[1], 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(a[2], 1, 1)]; break;
    case RO_R_MESH_IND: [e drawMeshThreadgroupsWithIndirectBuffer:a[0] threadsPerObjectThreadgroup:MTLSizeMake(a[1], 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(a[2], 1, 1)]; break;
    case RO_R_MESH_IND_B: [(id<MTLRenderCommandEncoder>)e drawMeshThreadgroupsWithIndirectBuffer:rec_id(a[0]) indirectBufferOffset:a[3] threadsPerObjectThreadgroup:MTLSizeMake(a[1], 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(a[2], 1, 1)]; break;
    default: MDIE("deferred encoding: unknown record %u", r->op);
    }
    for (uint32_t i = 0; i < r->nobj; i++) if (a[i]) CFRelease((CFTypeRef)(uintptr_t)a[i]);
}
// 编码线程 / 上屏线程按性能档分账（11-06 Switch2 线 71，验 s2a_qos.h 的取值）：thread_selfcounts 第 4 类，每档 {指令, 周期, 用户, 系统 mach 时间}，档 0 = 性能核。
//   [线程 0 编码 / 1 上屏][档 0 / 1][0 时间 1 周期]；hle_nvn.c「translation detail」行读 dm_thread_lv_stats
int thread_selfcounts(int type, void *buf, size_t nbytes);
static _Atomic uint64_t g_thr_lv[2][2][2];
static inline void thr_lv_take(uint64_t v[2][4]) { memset(v, 0, 2 * sizeof v[0]); thread_selfcounts(4, v, 2 * sizeof v[0]); }
static inline void thr_lv_add(int who, uint64_t a[2][4], uint64_t b[2][4]) {
    for (int k = 0; k < 2; k++) { atomic_fetch_add(&g_thr_lv[who][k][0], (b[k][2] + b[k][3]) - (a[k][2] + a[k][3])); atomic_fetch_add(&g_thr_lv[who][k][1], b[k][1] - a[k][1]); }
}
void dm_thread_lv_stats(uint64_t out[2][2][2]) { for (int w = 0; w < 2; w++) for (int k = 0; k < 2; k++) for (int j = 0; j < 2; j++) out[w][k][j] = atomic_load(&g_thr_lv[w][k][j]); }
static void *rec_thread(void *arg) {
    (void)arg; pthread_setname_np("dm-encode");
    s2a_qos_set_self(S2A_QOS_ENCODE);
    for (;;) {
        pthread_mutex_lock(&g_rb_mu);
        while (!g_rb_head) { g_rb_sleeping = 1; pthread_cond_wait(&g_rb_work, &g_rb_mu); g_rb_sleeping = 0; }
        rec_blk *b = g_rb_head; g_rb_head = b->next; if (!g_rb_head) g_rb_tail = NULL; g_rb_busy = 1;
        pthread_mutex_unlock(&g_rb_mu);
        uint64_t lv0[2][4], lv1[2][4]; thr_lv_take(lv0);
        @autoreleasepool { for (int i = 0; i < b->n; i++) rec_exec(&b->r[i]); }
        thr_lv_take(lv1); thr_lv_add(0, lv0, lv1);
        pthread_mutex_lock(&g_rb_mu);
        b->n = 0; b->next = g_rb_free; g_rb_free = b; g_rb_busy = 0;
        if (!g_rb_head) pthread_cond_broadcast(&g_rb_idle);
        pthread_mutex_unlock(&g_rb_mu);
    }
    return NULL;
}

// ---------- The submit thread's side ----------
static void rec_publish(void) {
    if (!g_rb_cur || !g_rb_cur->n) return;
    pthread_mutex_lock(&g_rb_mu);
    g_rb_cur->next = NULL; if (g_rb_tail) g_rb_tail->next = g_rb_cur; else g_rb_head = g_rb_cur; g_rb_tail = g_rb_cur; g_rb_cur = NULL;
    if (g_rb_sleeping) pthread_cond_signal(&g_rb_work);
    pthread_mutex_unlock(&g_rb_mu);
}
// S2Arm 11-06 能耗线（几何绘制段，nvn_geometry.inc geo_run）：录制分道。道 1 / 2 的记录先存在私有块链里、不交编码线程，rec_lane_splice 时接在主流后面
//   （先主流当前块，再道 1、道 2），编码线程照这个顺序执行：于是同一时间提交线程上可以有三个「打开」的编码器（主流的抓顶点、道 1 的几何核、道 2 的主绘制遍），
//   编码线程上仍然一次只有一个
static int g_rlane;
static rec_blk *g_lane_head[3], *g_lane_tail[3];
static rec_blk *rec_blk_get(void) {
    pthread_mutex_lock(&g_rb_mu); rec_blk *b = g_rb_free; if (b) g_rb_free = b->next; pthread_mutex_unlock(&g_rb_mu);
    if (!b) { b = malloc(sizeof *b); if (!b) MDIE("deferred encoding: out of memory"); }
    b->n = 0; b->next = NULL; return b;
}
static void rec_lane(int k) { g_rlane = k; }
static void rec_lane_splice(void) {
    if (g_rlane) MDIE("deferred encoding: lanes spliced from lane %d", g_rlane);
    rec_publish();
    pthread_mutex_lock(&g_rb_mu);
    for (int k = 1; k < 3; k++) { if (!g_lane_head[k]) continue;
        if (g_rb_tail) g_rb_tail->next = g_lane_head[k]; else g_rb_head = g_lane_head[k];
        g_rb_tail = g_lane_tail[k]; g_lane_head[k] = g_lane_tail[k] = NULL; }
    if (g_rb_sleeping) pthread_cond_signal(&g_rb_work);
    pthread_mutex_unlock(&g_rb_mu);
}
static rec_t *rec_put(uint32_t op, uint32_t nobj) {
    if (g_rlane) { int k = g_rlane; rec_blk *b = g_lane_tail[k];
        if (!b || b->n == REC_BLK) { rec_blk *nb = rec_blk_get(); if (b) b->next = nb; else g_lane_head[k] = nb; g_lane_tail[k] = b = nb; }
        rec_t *r = &b->r[b->n++]; r->op = op; r->nobj = nobj; return r; }
    if (g_rb_cur && g_rb_cur->n == REC_BLK) rec_publish();
    if (!g_rb_cur) {
        pthread_mutex_lock(&g_rb_mu);
        if (!g_rb_started) { pthread_t th; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 1 << 20);
            if (pthread_create(&th, &at, rec_thread, NULL)) MDIE("deferred encoding: cannot start the encode thread"); pthread_attr_destroy(&at); g_rb_started = 1; }
        g_rb_cur = g_rb_free; if (g_rb_cur) g_rb_free = g_rb_cur->next;
        pthread_mutex_unlock(&g_rb_mu);
        if (!g_rb_cur) { g_rb_cur = malloc(sizeof *g_rb_cur); if (!g_rb_cur) MDIE("deferred encoding: out of memory"); }
        g_rb_cur->n = 0;
    }
    rec_t *r = &g_rb_cur->r[g_rb_cur->n++]; r->op = op; r->nobj = nobj; return r;
}
static void geo_run_flush(void);   // nvn_geometry.inc: a geometry run's lanes go into the stream before anything that commits, signals or waits
// Hand over what is recorded and wait until the encode thread has made every call
static void rec_drain(void) {
    if (!g_rlane) geo_run_flush();   // inside a lane (a run's main-pass draw uploading a texture, up_begin): only the stream handed over so far is drained; the lanes are not waited for
    int lane = g_rlane; g_rlane = 0;
    if (!g_rb_started) { g_rlane = lane; return; }
    rec_publish();
    pthread_mutex_lock(&g_rb_mu);
    while (g_rb_head || g_rb_busy) pthread_cond_wait(&g_rb_idle, &g_rb_mu);
    pthread_mutex_unlock(&g_rb_mu);
    g_rlane = lane;
}
static __attribute__((noreturn)) void rec_missing(id o, SEL s) { MDIE("deferred encoding: %s has no stand-in for -%s (DM_NVN_ENC_THREAD=0 runs without it)", object_getClassName(o), sel_getName(s)); }

// Argument tables: every stand-in is made once and kept for good (rec_table), so the real table is passed without a retain
@interface DmRecTable : NSObject { @public id real; } @end
static inline void rec_table_op(uint32_t op, id t, uint64_t v, NSUInteger i) { rec_t *r = rec_put(op, 0); r->a[0] = (uint64_t)(uintptr_t)(__bridge void *)((DmRecTable *)t)->real; r->a[1] = v; r->a[2] = i; }
@implementation DmRecTable
- (void)setAddress:(uint64_t)gpu atIndex:(NSUInteger)i { rec_table_op(RO_T_ADDR, self, gpu, i); }
- (void)setTexture:(MTLResourceID)t atIndex:(NSUInteger)i { rec_table_op(RO_T_TEX, self, t._impl, i); }
- (void)setSamplerState:(MTLResourceID)t atIndex:(NSUInteger)i { rec_table_op(RO_T_SAMP, self, t._impl, i); }
- (id)forwardingTargetForSelector:(SEL)s { rec_missing(self, s); }
@end
static inline id rec_table_real(id t) { return [t isKindOfClass:[DmRecTable class]] ? ((DmRecTable *)t)->real : t; }

// render: the stand-in also answers for a render encoder (m4_end asks before it picks the fence update; Metal 3 only)
@interface DmRecEnc : NSObject { @public int render; } @end
@implementation DmRecEnc
- (BOOL)conformsToProtocol:(Protocol *)p { return p == @protocol(MTL4CommandEncoder) || p == @protocol(MTL4RenderCommandEncoder) || p == @protocol(MTL4ComputeCommandEncoder) || (render && p == @protocol(MTLRenderCommandEncoder)) || [super conformsToProtocol:p]; }
- (id)forwardingTargetForSelector:(SEL)s { rec_missing(self, s); }
- (void)endEncoding { rec_put(RO_END, 0); }
// Metal 3: what the old encoders are asked (m3_wait, m4_end, m3_table_apply, blit_barrier, the buffer-and-offset draws). The fence is always g_fence3
- (void)waitForFence:(id<MTLFence>)f beforeStages:(MTLRenderStages)s { rec_t *r = rec_put(RO_M3_WAIT, 0); r->a[0] = 1; r->a[1] = s; }
- (void)waitForFence:(id<MTLFence>)f { rec_put(RO_M3_WAIT, 0)->a[0] = 0; }
- (void)updateFence:(id<MTLFence>)f afterStages:(MTLRenderStages)s { rec_t *r = rec_put(RO_M3_UPD, 0); r->a[0] = 1; r->a[1] = s; }
- (void)updateFence:(id<MTLFence>)f { rec_put(RO_M3_UPD, 0)->a[0] = 0; }
- (void)memoryBarrierWithScope:(MTLBarrierScope)s { rec_put(RO_M3_MB, 0)->a[0] = s; }
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_BUF, 1); r->a[0] = rec_obj(b); r->a[1] = 0; r->a[2] = o; r->a[3] = i; }
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_BUF, 1); r->a[0] = rec_obj(b); r->a[1] = 1; r->a[2] = o; r->a[3] = i; }
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_BUF, 1); r->a[0] = rec_obj(b); r->a[1] = 2; r->a[2] = o; r->a[3] = i; }
- (void)setVertexTexture:(id<MTLTexture>)x atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_TEX, 1); r->a[0] = rec_obj(x); r->a[1] = 0; r->a[2] = i; }
- (void)setFragmentTexture:(id<MTLTexture>)x atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_TEX, 1); r->a[0] = rec_obj(x); r->a[1] = 1; r->a[2] = i; }
- (void)setTexture:(id<MTLTexture>)x atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_TEX, 1); r->a[0] = rec_obj(x); r->a[1] = 2; r->a[2] = i; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_SMP, 1); r->a[0] = rec_obj(s); r->a[1] = 0; r->a[2] = i; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_SMP, 1); r->a[0] = rec_obj(s); r->a[1] = 1; r->a[2] = i; }
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_SMP, 1); r->a[0] = rec_obj(s); r->a[1] = 2; r->a[2] = i; }
// Metal 3 object / mesh stages (a task / mesh draw: m3_bind_mesh)
- (void)setObjectBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_BUF, 1); r->a[0] = rec_obj(b); r->a[1] = 3; r->a[2] = o; r->a[3] = i; }
- (void)setMeshBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_BUF, 1); r->a[0] = rec_obj(b); r->a[1] = 4; r->a[2] = o; r->a[3] = i; }
- (void)setObjectTexture:(id<MTLTexture>)x atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_TEX, 1); r->a[0] = rec_obj(x); r->a[1] = 3; r->a[2] = i; }
- (void)setMeshTexture:(id<MTLTexture>)x atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_TEX, 1); r->a[0] = rec_obj(x); r->a[1] = 4; r->a[2] = i; }
- (void)setObjectSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_SMP, 1); r->a[0] = rec_obj(s); r->a[1] = 3; r->a[2] = i; }
- (void)setMeshSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_M3_SMP, 1); r->a[0] = rec_obj(s); r->a[1] = 4; r->a[2] = i; }
- (void)drawMeshThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)b indirectBufferOffset:(NSUInteger)o threadsPerObjectThreadgroup:(MTLSize)ot threadsPerMeshThreadgroup:(MTLSize)mt {
    rec_t *r = rec_put(RO_R_MESH_IND_B, 1); r->a[0] = rec_obj(b); r->a[1] = ot.width; r->a[2] = mt.width; r->a[3] = o; }
- (void)drawPrimitives:(MTLPrimitiveType)p indirectBuffer:(id<MTLBuffer>)b indirectBufferOffset:(NSUInteger)o { rec_t *r = rec_put(RO_R_DRAW_IND_B, 1); r->a[0] = rec_obj(b); r->a[1] = p; r->a[2] = o; }
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi {
    rec_t *r = rec_put(RO_R_DRAW_IDX_B, 1); r->a[0] = rec_obj(b); r->a[1] = p; r->a[2] = n; r->a[3] = t; r->a[4] = o; r->a[5] = i; r->a[6] = (uint64_t)bv; r->a[7] = bi; }
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o indirectBuffer:(id<MTLBuffer>)ib indirectBufferOffset:(NSUInteger)io {
    rec_t *r = rec_put(RO_R_DRAW_IDX_IND_B, 2); r->a[0] = rec_obj(b); r->a[1] = rec_obj(ib); r->a[2] = p; r->a[3] = t; r->a[4] = o; r->a[5] = io; }
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)b indirectBufferOffset:(NSUInteger)o threadsPerThreadgroup:(MTLSize)t {
    rec_t *r = rec_put(RO_C_DISPATCH_IND_B, 1); r->a[0] = rec_obj(b); r->a[1] = o; r->a[2] = t.width; r->a[3] = t.height; r->a[4] = t.depth; }
- (void)barrierAfterQueueStages:(MTLStages)a beforeStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)v { rec_t *r = rec_put(RO_BAR_QUEUE, 0); r->a[0] = a; r->a[1] = b; r->a[2] = v; }
- (void)barrierAfterStages:(MTLStages)a beforeQueueStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)v { rec_t *r = rec_put(RO_BAR_AFTER_STAGES, 0); r->a[0] = a; r->a[1] = b; r->a[2] = v; }
- (void)barrierAfterEncoderStages:(MTLStages)a beforeEncoderStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)v { rec_t *r = rec_put(RO_BAR_ENCODER, 0); r->a[0] = a; r->a[1] = b; r->a[2] = v; }
// Render
- (void)setArgumentTable:(id)t atStages:(MTLRenderStages)s { id x = rec_table_real(t); int keep = x != t; rec_t *r = rec_put(RO_R_TABLE, !keep); r->a[0] = keep ? (uint64_t)(uintptr_t)(__bridge void *)x : rec_obj(x); r->a[1] = s; }
- (void)setRenderPipelineState:(id)p { rec_t *r = rec_put(RO_R_PSO, 1); r->a[0] = rec_obj(p); }
- (void)setDepthStencilState:(id)s { rec_t *r = rec_put(RO_R_DSS, 1); r->a[0] = rec_obj(s); }
- (void)setViewport:(MTLViewport)v { rec_t *r = rec_put(RO_R_VIEWPORT, 0); memcpy(r->a, &v, sizeof v); }
- (void)setScissorRect:(MTLScissorRect)s { rec_t *r = rec_put(RO_R_SCISSOR, 0); memcpy(r->a, &s, sizeof s); }
- (void)setCullMode:(MTLCullMode)m { rec_put(RO_R_CULL, 0)->a[0] = m; }
- (void)setFrontFacingWinding:(MTLWinding)w { rec_put(RO_R_WINDING, 0)->a[0] = w; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { rec_put(RO_R_FILL, 0)->a[0] = m; }
- (void)setDepthBias:(float)u slopeScale:(float)s clamp:(float)c { rec_t *r = rec_put(RO_R_BIAS, 0); r->a[0] = rec_f(u); r->a[1] = rec_f(s); r->a[2] = rec_f(c); }
- (void)setDepthClipMode:(MTLDepthClipMode)m { rec_put(RO_R_CLIP, 0)->a[0] = m; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { rec_t *r = rec_put(RO_R_SREF, 0); r->a[0] = f; r->a[1] = b; }   // enc_r_stencil_ref: NVN keeps one reference per face
- (void)setBlendColorRed:(float)r_ green:(float)g blue:(float)b alpha:(float)a { rec_t *r = rec_put(RO_R_BLEND, 0); r->a[0] = rec_f(r_); r->a[1] = rec_f(g); r->a[2] = rec_f(b); r->a[3] = rec_f(a); }
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)m offset:(NSUInteger)o { rec_t *r = rec_put(RO_R_VIS, 0); r->a[0] = m; r->a[1] = o; }
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n { rec_t *r = rec_put(RO_R_DRAW, 0); r->a[0] = p; r->a[1] = v; r->a[2] = n; }
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i baseInstance:(NSUInteger)b {
    rec_t *r = rec_put(RO_R_DRAW_INST, 0); r->a[0] = p; r->a[1] = v; r->a[2] = n; r->a[3] = i; r->a[4] = b; }
- (void)drawPrimitives:(MTLPrimitiveType)p indirectBuffer:(uint64_t)g { rec_t *r = rec_put(RO_R_DRAW_IND, 0); r->a[0] = p; r->a[1] = g; }
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(uint64_t)g indexBufferLength:(NSUInteger)len instanceCount:(NSUInteger)i baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi {
    rec_t *r = rec_put(RO_R_DRAW_IDX, 0); r->a[0] = p; r->a[1] = n; r->a[2] = t; r->a[3] = g; r->a[4] = len; r->a[5] = i; r->a[6] = (uint64_t)bv; r->a[7] = bi; }
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexType:(MTLIndexType)t indexBuffer:(uint64_t)g indexBufferLength:(NSUInteger)len indirectBuffer:(uint64_t)ind {
    rec_t *r = rec_put(RO_R_DRAW_IDX_IND, 0); r->a[0] = p; r->a[1] = t; r->a[2] = g; r->a[3] = len; r->a[4] = ind; }
- (void)drawMeshThreadgroups:(MTLSize)g threadsPerObjectThreadgroup:(MTLSize)ot threadsPerMeshThreadgroup:(MTLSize)mt { rec_t *r = rec_put(RO_R_MESH, 0); r->a[0] = g.width; r->a[1] = ot.width; r->a[2] = mt.width; }
- (void)drawMeshThreadgroupsWithIndirectBuffer:(uint64_t)g threadsPerObjectThreadgroup:(MTLSize)ot threadsPerMeshThreadgroup:(MTLSize)mt { rec_t *r = rec_put(RO_R_MESH_IND, 0); r->a[0] = g; r->a[1] = ot.width; r->a[2] = mt.width; }
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_R_STORE_C, 0); r->a[0] = a; r->a[1] = i; }
- (void)setDepthStoreAction:(MTLStoreAction)a { rec_put(RO_R_STORE_D, 0)->a[0] = a; }
- (void)setStencilStoreAction:(MTLStoreAction)a { rec_put(RO_R_STORE_S, 0)->a[0] = a; }
// Compute and copies (Metal 4 copies are on the compute encoder)
- (void)setArgumentTable:(id)t { id x = rec_table_real(t); int keep = x != t; rec_t *r = rec_put(RO_C_TABLE, !keep); r->a[0] = keep ? (uint64_t)(uintptr_t)(__bridge void *)x : rec_obj(x); }
- (void)setComputePipelineState:(id)p { rec_t *r = rec_put(RO_C_PSO, 1); r->a[0] = rec_obj(p); }
- (void)dispatchThreadgroups:(MTLSize)n threadsPerThreadgroup:(MTLSize)t { rec_t *r = rec_put(RO_C_DISPATCH, 0); r->a[0] = n.width; r->a[1] = n.height; r->a[2] = n.depth; r->a[3] = t.width; r->a[4] = t.height; r->a[5] = t.depth; }
- (void)dispatchThreadgroupsWithIndirectBuffer:(uint64_t)g threadsPerThreadgroup:(MTLSize)t { rec_t *r = rec_put(RO_C_DISPATCH_IND, 0); r->a[0] = g; r->a[1] = t.width; r->a[2] = t.height; r->a[3] = t.depth; }
- (void)dispatchThreads:(MTLSize)n threadsPerThreadgroup:(MTLSize)t { rec_t *r = rec_put(RO_C_DISPATCH_THREADS, 0); r->a[0] = n.width; r->a[1] = n.height; r->a[2] = n.depth; r->a[3] = t.width; r->a[4] = t.height; r->a[5] = t.depth; }   // enc_c_dispatch_threads: the last group is not padded (tessellation TCS)
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so toBuffer:(id)d destinationOffset:(NSUInteger)doff size:(NSUInteger)n {
    rec_t *r = rec_put(RO_C_COPY_BB, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = so; r->a[3] = doff; r->a[4] = n; }
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)img sourceSize:(MTLSize)z toTexture:(id)d destinationSlice:(NSUInteger)sl destinationLevel:(NSUInteger)lv destinationOrigin:(MTLOrigin)o {
    rec_t *r = rec_put(RO_C_COPY_BT, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = so; r->a[3] = row; r->a[4] = img; r->a[5] = z.width; r->a[6] = z.height; r->a[7] = z.depth;
    r->a[8] = sl; r->a[9] = lv; r->a[10] = o.x; r->a[11] = o.y; r->a[12] = o.z; }
- (void)copyFromTexture:(id)s sourceSlice:(NSUInteger)sl sourceLevel:(NSUInteger)lv sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)z toBuffer:(id)d destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)img {
    rec_t *r = rec_put(RO_C_COPY_TB, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = sl; r->a[3] = lv; r->a[4] = o.x; r->a[5] = o.y; r->a[6] = o.z; r->a[7] = z.width; r->a[8] = z.height; r->a[9] = z.depth;
    r->a[10] = doff; r->a[11] = row; r->a[12] = img; }
- (void)copyFromTexture:(id)s sourceSlice:(NSUInteger)sl sourceLevel:(NSUInteger)lv sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)z toTexture:(id)d destinationSlice:(NSUInteger)dsl destinationLevel:(NSUInteger)dlv destinationOrigin:(MTLOrigin)dorg {
    rec_t *r = rec_put(RO_C_COPY_TT, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = sl; r->a[3] = lv; r->a[4] = o.x; r->a[5] = o.y; r->a[6] = o.z; r->a[7] = z.width; r->a[8] = z.height; r->a[9] = z.depth;
    r->a[10] = dsl; r->a[11] = dlv; r->a[12] = dorg.x; r->a[13] = dorg.y; r->a[14] = dorg.z; }
- (void)fillBuffer:(id)b range:(NSRange)rg value:(uint8_t)v { rec_t *r = rec_put(RO_C_FILL, 1); r->a[0] = rec_obj(b); r->a[1] = rg.location; r->a[2] = rg.length; r->a[3] = v; }
// Diagnostics: encoder labels (DM_NVN_ENC_LABEL) and timestamps into a counter heap (DM_NVN_GPUPROF); the render form names a stage, the compute form none
- (void)setLabel:(NSString *)l { rec_put(RO_LABEL, 1)->a[0] = rec_obj(l); }
- (void)writeTimestampWithGranularity:(MTL4TimestampGranularity)g afterStage:(MTLRenderStages)st intoHeap:(id)h atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_R_TS, 1); r->a[0] = rec_obj(h); r->a[1] = g; r->a[2] = st; r->a[3] = i; }
- (void)writeTimestampWithGranularity:(MTL4TimestampGranularity)g intoHeap:(id)h atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_C_TS, 1); r->a[0] = rec_obj(h); r->a[1] = g; r->a[2] = i; }
@end

@interface DmRecCB : NSObject @end
@implementation DmRecCB
- (id)forwardingTargetForSelector:(SEL)s { rec_missing(self, s); }
- (void)beginCommandBufferWithAllocator:(id)a { rec_put(RO_CB_BEGIN, 1)->a[0] = rec_obj(a); }
- (void)endCommandBuffer { rec_put(RO_CB_END, 0); }
- (id)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)d { rec_put(RO_RE_BEGIN, 1)->a[0] = rec_obj([d copy]); DmRecEnc *e = [DmRecEnc new]; e->render = 1; return e; }   // copied: the replay may reuse or change the descriptor afterwards
- (id)computeCommandEncoder { rec_put(RO_CE_BEGIN, 0); return [DmRecEnc new]; }
// Metal 3: the copy encoder and the compute encoder made from a descriptor (GPUPROF's sample buffer rides on that one)
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { rec_put(RO_CB_BLIT, 0); return [DmRecEnc new]; }
- (id)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d { rec_put(RO_CE_BEGIN_D, 1)->a[0] = rec_obj([d copy]); return [DmRecEnc new]; }
@end

// The replay's entry points
static id rec_cb_new(void) { if (!rec_on()) return g_m3 ? m3_cb() : [g_dev newCommandBuffer]; rec_put(RO_CB_NEW, 0); return [DmRecCB new]; }   // Metal 3 off: m3_cb; on: recorded like Metal 4
// Metal 3 commit: a record too, so the encode thread commits in the order the work was recorded (main: a[2] = 0, decodes on the encode thread's buffer)
static void ubq_flush(void);   // nvn_mtl.m: the shadow copies not made yet go before the commit
static void rec_commit_m3(id cb, id fb, id ev, uint64_t v, int main) {
    geo_run_flush();
    if (main) ubq_flush();
    if (rec_on() && g_rb_started) { rec_t *r = rec_put(RO_COMMIT_M3, 3); r->a[0] = rec_obj(fb); r->a[1] = rec_obj(ev); r->a[2] = main ? 0 : rec_obj(cb); r->a[3] = v; r->a[4] = main ? ubc_head() : 0; return; }
    // Committed right here (no encode thread: Metal 3's default): the main buffer reads the uniform shadows queued to the copy worker, which must be made first, as rec_commit
    //   and the encode thread's RO_COMMIT_M3 do. It used to commit without waiting: the GPU could read a shadow the worker had not written yet (t_nvn_ubd_index ⑥)
    if (main) ubc_wait(ubc_head());
    m3_commit(cb, fb, ev, v);
}
static id rec_table(id t) { if (!rec_on() || !t || g_m3) return t; DmRecTable *s = [DmRecTable new]; s->real = t; return s; }   // Metal 3: DmTable3 is written directly by tab_* and applied by m3_table_apply on the submit thread
// The replay's main command buffer: committed once the uniform shadows queued so far are made (ubc_wait)
static void rec_commit(id cb, MTL4CommitOptions *o) {
    geo_run_flush();
    ubq_flush();
    if ([cb isKindOfClass:[DmRecCB class]]) { rec_t *r = rec_put(RO_COMMIT, 1); r->a[0] = rec_obj(o); r->a[2] = ubc_head(); return; }
    ubc_wait(ubc_head());
    id<MTL4CommandBuffer> buffers[] = {cb};
    if (!gpu_go()) return;   // GPU 安全停后不交
    if (o) [g_q4 commit:buffers count:1 options:o]; else [g_q4 commit:buffers count:1];
}
// An upload batch: its place in the queue is after what is recorded so far (it reads no uniform shadow)
static void rec_commit_upload(id cb, MTL4CommitOptions *o) {
    // Inside a lane too it goes into the main stream: an upload batch runs before the whole main command buffer in any case (it is committed when recorded, the main buffer at its end),
    //   and up_begin's wait for a slot must find the batch's commit handed over, not held in a lane
    if (rec_on() && g_rb_started) { int lane = g_rlane; g_rlane = 0; rec_t *r = rec_put(RO_COMMIT_REAL, 2); r->a[0] = rec_obj(o); r->a[1] = rec_obj(cb); g_rlane = lane; return; }
    id<MTL4CommandBuffer> buffers[] = {cb};
    if (!gpu_go()) return;   // GPU 安全停后不交
    if (o) [g_q4 commit:buffers count:1 options:o]; else [g_q4 commit:buffers count:1];
}
static void rec_signal(id ev, uint64_t v) { geo_run_flush(); if (rec_on() && g_rb_started) { rec_t *r = rec_put(RO_SIGNAL, 1); r->a[0] = rec_obj(ev); r->a[1] = v; } else if (!mtl_gpu_halted()) [g_q4 signalEvent:ev value:v]; }
