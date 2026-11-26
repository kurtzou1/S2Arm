// 混合管线：首遇没有精确管线的绘制不等编译器（照上游参考实现（MIT）hybrid pipelines / dmsh_pull，S2Arm 改写；nvn_mtl.m 内含）。
//   顶点着色器另有拉取式库 <key>_bp（Pull.cs）：入口不带 [[stage_in]]，从槽 16 的布局块（pull_layout，按笔填）自己读顶点流，位级等同 Metal 顶点抓取。
//   用它的管线没有顶点描述，一对着色器的所有顶点布局共用一条「拉取基础管线」：颜色状态留空（Unspecialized），用 Metal 4 编译器后台建一次；
//   之后每种颜色状态按本笔特化（newRenderPipelineStateBySpecializationWithDescriptor，不进着色器编译）。精确管线不在的首遇（不论能不能跳）改用它先画，
//   精确管线照旧后台编（pso_pend_kick），编好后下一笔起换回精确的。拉取基础管线还没建好就照旧走跳过 / 现编等待，并在后台建它，下一次首遇就用上。
//   只在 Metal 4 后端（Metal 4 编译器的特化）；片元只用 main0 本身（带透明测试 / 输出类型 / 采样模拟常量的变体先不走）；合并遍、可读瓦片、顶点补齐变体、
//   写层顶点、曲面细分、变换反馈不走。DM_PSO_HYBRID=0 关
enum { PULL_SLOT = 16 };   // = Pull.cs SLOT：顶点缓冲槽 VB_SLOT(0)，没有顶点描述的管线不用它
_Static_assert(PULL_SLOT == VB_SLOT(0), "Pull.cs SLOT is the first vertex buffer slot (pull_refl_ok)");
typedef struct { uint64_t base; uint32_t stride, divisor; } pull_stream;
typedef struct { pull_stream s[16]; uint32_t attr[32]; } pull_layout;   // = Pull.cs dm_vlayout（流基址 / 步长 / 实例除数；属性字 = va_st 位段：格式 8、偏移 19、流 5）
_Static_assert(sizeof(pull_layout) == 384, "Pull.cs dm_vlayout");
_Static_assert(sizeof(va_st) == 4, "pull_layout attr word");

static int hybrid_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_PSO_HYBRID"); int os26 = 0; if (@available(macOS 26.0, iOS 26.0, *)) os26 = 1;
        v = os26 && !g_m3 && !(e && !strcmp(e, "0"));
        MLOG("hybrid pipelines %s", v ? "on: a first use that cannot be skipped draws with its pair's pulling pipeline while its own compiles" : "off: a first use that cannot be skipped waits for its pipeline"); }
    return v;
}
static os_unfair_lock g_pull_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_pull_loaded, g_pull_failed;
static id<MTLFunction> pull_fn(NvShader *vs) {   // 拉取入口（与 vs->ventry 同名：main0 / main0_z），第一次要时载入；不可用是定局（这对的首遇照旧等）
    if (!vs || !vs->has_pull || vs->layer_out) return nil;
    os_unfair_lock_lock(&g_pull_lock);
    if (!vs->pfn_state) {
        vs->pfn_state = 2;
        size_t kl = strlen(vs->key); NSString *path = [NSString stringWithFormat:@"%.*s_bp", (int)(kl > 2 ? kl - 2 : kl), vs->key];
        // _bp 逐键编（Build.cs PullBuild），不进合批库：入口就叫 main0 / main0_z，不带 _b 合批的 fn_prefix（fnn）
        NSError *e = nil; id<MTLLibrary> lib = lib_from_pack(path.UTF8String, &e); id<MTLFunction> f = lib_entry(lib, vs->ventry);
        const char *why = !lib ? "no library" : !f ? "no entry point" : NULL;
        if (f && vs->rf.nb && argcheck_on() && [f newArgumentEncoderWithBufferIndex:vs->rf.abi].encodedLength != vs->arg_len) { why = "its argument buffer differs from the base library's"; f = nil; }
        if (f) { vs->pfn = f; vs->pull_lib = lib; vs->pfn_state = 1; g_pull_loaded++; }
        else if (g_pull_failed++ < 8) MLOG("【红】 pulling library of %s not usable (%s%s%s): its first uses wait for their pipelines", vs->key, why, e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
    }
    id<MTLFunction> f = vs->pfn_state == 1 ? vs->pfn : nil;
    os_unfair_lock_unlock(&g_pull_lock);
    return f;
}

// 本笔的布局块：流基址按 4 字节对齐、低位并进属性偏移（dm_fetch 在元素对齐时按整字读）；没落在任何池里的流，它的属性读 0（同零缓冲）。只填本笔顶点着色器读的流
static void pull_layout_fill(pull_layout *L, NvShader *vs) {
    memset(L, 0, sizeof *L); uint32_t lo[16] = {0};
    for (int st = 0; st < 16; st++) {
        uint64_t addr = S.vbuf[st].address, gpu, pav; void *mb; uint64_t mo;
        if (!addr || !gpu_addr_want(addr, 1, S.vbuf[st].size, &mb, &mo, &gpu, &pav)) continue;
        L->s[st].base = gpu & ~3ull; lo[st] = (uint32_t)(gpu & 3); L->s[st].stride = S.stream[st].stride; L->s[st].divisor = S.stream[st].divisor;
    }
    (void)vs;
    for (int a = 0; a < 16 && a < S.nattr; a++) {
        va_st v = S.attr[a];
        if (!v.fmt || v.stream >= 16 || !L->s[v.stream].base) continue;
        v.offset += lo[v.stream]; memcpy(&L->attr[a], &v, 4);
    }
}
static void pull_bind(id en, NvShader *vs) {   // en：Metal 4 渲染编码器（变量用 id，tools/mtl4_baseline.txt 棘轮）
    pull_layout L; pull_layout_fill(&L, vs);
    __unsafe_unretained id<MTLBuffer> ab; size_t off = arena_alloc_u(sizeof L, &ab);
    memcpy((uint8_t *)ab.contents + off, &L, sizeof L);
    enc_r_vbuf(en, PULL_SLOT, ab.gpuAddress + off);
}

// 拉取基础管线：按（拉取入口、片元函数、样本数、alpha 覆盖、拓扑类）认；颜色状态留空。后台串行队列建，建过的（成败）不再建
typedef struct { const void *vf, *ff; uint32_t samples, a2c, a21, topo; } pbase_key;   // vf / ff：顶点 / 片元着色器对象（NvShader，常驻）
static nvn_hmap g_pbase = {.klen = sizeof(pbase_key)};   // → id<MTLRenderPipelineState>，失败 NSNull
static nvn_hmap g_pso_hy = {.klen = sizeof(pso_key)};   // 特化好的拉取管线，按它顶替的精确管线的键（提交线程）
static os_unfair_lock g_pbase_lock = OS_UNFAIR_LOCK_INIT;
// 基础管线也是活着的管线，算进管线额度（nvn_pso_budget.inc ⑥）：放进 g_pbase 一律经 pb_base_put_locked、用到经 pb_base_touch_locked（都在 g_pbase_lock 下）
static void pb_base_put_locked(const pbase_key *bk, id ps); static void pb_base_touch_locked(const pbase_key *bk);
static id g_hy_comp;   // Metal 4 编译器（m4_compiler）
static int g_pso_pull;   // pso_get_ 这次返回的是拉取管线（绘制改绑布局块，不做 CPU 顶点转换）
static _Atomic uint64_t g_hy_draws, g_hy_made, g_hy_none, g_hy_kicked, g_hy_bases, g_hy_base_fail, g_hy_spec_ns;
// 随包拉取基础管线（出包时 graphics/tools/direct/base_pipelines.py 按同一描述离线编，<库映射表同级>/pipelines/p<键>.mtl4archive，一对一个 Metal 4 归档）：
//   键 = sha256("<顶点键>\t<片元键>\t<顶点入口>") 前 20 字节十六进制（顶点 / 片元键带 _b，与出包 bkey 同一串）。归档只查不编（MTL4Archive 的建管线就是按描述查，
//   查不中返回 nil，同 FailOnBinaryArchiveMiss），查不中（别的 GPU / 系统大版本、多重采样 / alpha-to-coverage 这类离线不出的描述、近平面 0 模式的 main0_z）照旧后台建。
//   打开的归档留着（Metal 映射整份文件；一对只开一次，本局真用到的对才开）。DM_PSO_ARCHIVE=0 连随包的一起关（pso_archive.h par_open_dir）
//   iPhone 包逐对 lzfse 压成 <名>.mtl4archive.lzfse（Mac 包原样）：首遇时在后台队列解这一份（hybrid_pkg_open）。开局后台先查中一次随包的预热对（hybrid_pkg_warm）
//   查随包归档在后台队列（hybrid_q，同现建）：这一对的第一次首遇照旧跳过 / 等精确管线，之后的首遇用上拉取管线
static _Atomic uint64_t g_hy_pkg_hit, g_hy_pkg_nofile, g_hy_pkg_miss, g_hy_pkg_unz, g_hy_pkg_unz_ns, g_hy_pkg_warm_ns, g_hy_pkg_warm;   // g_hy_pkg_warm：0 没做、1 查中、2 没查中
static NSMutableArray *g_hy_pkg_open;   // g_pbase_lock
static NSString *hybrid_pkg_name(NvShader *vs, NvShader *fs) {
    NSData *b = [[NSString stringWithFormat:@"%s\t%s\t%@", vs->key, fs->key, vs->ventry] dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(b.bytes, (CC_LONG)b.length, h);
    NSMutableString *n = [NSMutableString stringWithString:@"p"]; for (int i = 0; i < 20; i++) [n appendFormat:@"%02x", h[i]];
    return [n stringByAppendingString:@".mtl4archive"];
}
// 开随包归档 path（…/<名>.mtl4archive）：有原样直接开；没有而有 <path>.lzfse → 读入、解压（Foundation，不新增链接库：libnvn.a 的链接方大多没链 libcompression）、
//   写临时文件、开、立即删（Metal 已映射，删了照常可查；不常驻解压副本。真机 11-19：解压 + 写开删 + 查 ≈ 0.41–0.51 ms / 对）。
//   → 归档，或 nil；*had：有没有这一对的文件（原样或压过的）；*e：打不开 / 解不开的原因。count：计入「解压 K 份、合计 X ms」（预热对不计）
static id hybrid_pkg_open(NSString *path, int *had, NSError **e, int count) API_AVAILABLE(macos(26.0), ios(26.0)) {
    *had = 1;
    if (!access(path.fileSystemRepresentation, R_OK)) return [g_dev newArchiveWithURL:[NSURL fileURLWithPath:path] error:e];   // id：Metal 4 归档类型不出 nvn_mtl.m 包装（mtl4 棘轮）
    NSData *z = [NSData dataWithContentsOfFile:[path stringByAppendingString:@".lzfse"] options:NSDataReadingMappedIfSafe error:nil];
    if (!z) { *had = 0; return nil; }
    uint64_t t0 = bp_now();
    NSData *raw = [z decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZFSE error:e];
    if (!raw.length) { if (e && !*e) *e = [NSError errorWithDomain:@"s2a" code:1 userInfo:@{NSLocalizedDescriptionKey: @"lzfse gave nothing"}]; return nil; }
    static _Atomic uint64_t seq;   // 临时文件名：进程号 + 序号，提交线程与开局预热同时解也不撞
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"s2a_pb_%d_%llu.mtl4archive", getpid(), (unsigned long long)++seq]];
    id a = nil;
    if ([raw writeToFile:tmp options:0 error:e]) { a = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:tmp] error:e]; unlink(tmp.fileSystemRepresentation); }
    if (a && count) { g_hy_pkg_unz++; g_hy_pkg_unz_ns += bp_now() - t0; }
    return a;
}
// 开局后台（warm_start）：进程里第一次从 Metal 4 归档查中管线有一次性初始化（真机 11-19：16–25 ms），在这里先查中随包的预热对把它付掉，不落在提交线程的第一次首遇上。
//   只有查中才付这笔（11-19 本机实测：先拿别的函数 / 别的附件写法查、查不中，之后第一次查中照样 6–9 ms；先查中一对不相干的小库，之后 0.16 ms），
//   所以预热对是出包时现编的一对小函数（graphics/tools/direct/base_pipelines.py WARM：s2a_warm.metallib + s2a_warm.mtl4archive[.lzfse]），库随包、不现编（现编的函数哈希对不上归档）。
//   描述走与基础管线同一个建法（m4_render_desc unspec，缺省采样 1 / 拓扑类未指定 / alpha 两项关）；iPhone 包它也是压过的，顺带把解压的初次开销一起付掉。包里没有（老包 / 没出）就不做
static void hybrid_pkg_warm(void) API_AVAILABLE(macos(26.0), ios(26.0)) {
    par_open_dir(); if (!g_par_bdir) return;
    NSData *ld = [NSData dataWithContentsOfFile:[g_par_bdir stringByAppendingPathComponent:@"s2a_warm.metallib"]];
    if (!ld) return;
    uint64_t t0 = bp_now(); NSError *e = nil; int had = 0;
    id<MTLLibrary> lib = [g_dev newLibraryWithData:dispatch_data_create(ld.bytes, ld.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e];
    id<MTLFunction> vf = [lib newFunctionWithName:@"s2a_warm_v"], ff = [lib newFunctionWithName:@"s2a_warm_f"];
    id a = vf && ff ? hybrid_pkg_open([g_par_bdir stringByAppendingPathComponent:@"s2a_warm.mtl4archive"], &had, &e, 0) : nil;
    id<MTLRenderPipelineState> ps = a ? [a newRenderPipelineStateWithDescriptor:m4_render_desc([MTLRenderPipelineDescriptor new], spec_probe_fn(lib, vf), spec_probe_fn(lib, ff), nil, 1) error:&e] : nil;
    g_hy_pkg_warm_ns += bp_now() - t0; g_hy_pkg_warm = ps ? 1 : 2;
    if (!ps) MLOG("【黄】 hybrid pipelines: the package's warm-up pair did not serve (%s): the first lookup in the package's pulling bases pays the one-time setup",
                  e ? [e.localizedDescription componentsSeparatedByString:@"\n"].firstObject.UTF8String : !lib ? "its library did not load" : !vf || !ff ? "its functions are not in its library" : "no archive");
}
static id<MTLRenderPipelineState> hybrid_pkg_base(id bd, NvShader *vs, NvShader *fs) API_AVAILABLE(macos(26.0), ios(26.0)) {
    par_open_dir(); if (!g_par_bdir) return nil;
    NSString *path = [g_par_bdir stringByAppendingPathComponent:hybrid_pkg_name(vs, fs)];
    NSError *e = nil; int had = 0; id a = hybrid_pkg_open(path, &had, &e, 1);
    if (!had) { g_hy_pkg_nofile++; return nil; }
    id<MTLRenderPipelineState> ps = a ? [a newRenderPipelineStateWithDescriptor:bd error:&e] : nil;
    if (a) { os_unfair_lock_lock(&g_pbase_lock); if (!g_hy_pkg_open) g_hy_pkg_open = [NSMutableArray array]; [g_hy_pkg_open addObject:a]; os_unfair_lock_unlock(&g_pbase_lock); }
    if (ps) { g_hy_pkg_hit++; return ps; }
    uint64_t n = ++g_hy_pkg_miss;
    if (n <= 4) MLOG("【黄】 hybrid pipelines: the package's pulling base of vertex %s fragment %s did not serve (%s): built in the background", vs->key, fs->key, e ? [e.localizedDescription componentsSeparatedByString:@"\n"].firstObject.UTF8String : "no error");
    return nil;
}
void mtl_hybrid_pkg_stats(uint64_t out[7]) { out[0] = g_hy_pkg_hit; out[1] = g_hy_pkg_nofile; out[2] = g_hy_pkg_miss; out[3] = g_hy_pkg_unz; out[4] = g_hy_pkg_unz_ns; out[5] = g_hy_pkg_warm; out[6] = g_hy_pkg_warm_ns; }
static id hybrid_comp(void) API_AVAILABLE(macos(26.0), ios(26.0)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_hy_comp = m4_compiler("hybrid pipelines (first uses wait for their pipelines)"); });
    return g_hy_comp;
}
// 精确管线的描述 d → 拉取版的 Metal 4 描述：顶点换拉取入口、不带顶点描述；unspec：颜色状态留空（基础管线）
static id pull_desc4(MTLRenderPipelineDescriptor *d, NvShader *vs, NvShader *fs, int unspec) API_AVAILABLE(macos(26.0), ios(26.0)) {
    return m4_render_desc(d, spec_probe_fn(vs->pull_lib, vs->pfn), spec_probe_fn(fs->plib, fs->fn), nil, unspec);
}
// 这一笔能不能用拉取管线：Metal 4、普通绘制（vs 是 sh[0]、不是合并遍 / 可读瓦片 / 诊断片元），精确描述的顶点是 vs->fn 或影子输入入口（拉取版两者都替），片元是 fs->fn 本身
static int hybrid_fits(MTLRenderPipelineDescriptor *d, NvShader *vs, NvShader *fs) {
    return d && fs && fs->plib && d.rasterizationEnabled && d.fragmentFunction == fs->fn && (d.vertexFunction == vs->fn || (vs->vfn && d.vertexFunction == vs->vfn)) && pull_fn(vs);
}
// 基底键：这对着色器 + 采样数 / a2c / a21 / 拓扑类（颜色状态不进键，按本笔特化）
static pbase_key pbase_key_of(MTLRenderPipelineDescriptor *d, NvShader *vs, NvShader *fs) {
    pbase_key bk; memset(&bk, 0, sizeof bk); bk.vf = (__bridge const void *)vs; bk.ff = (__bridge const void *)fs;
    bk.samples = (uint32_t)d.rasterSampleCount; bk.a2c = d.alphaToCoverageEnabled; bk.a21 = d.alphaToOneEnabled; bk.topo = (uint32_t)d.inputPrimitiveTopology;
    return bk;
}
// 顶替 k 的拉取管线：特化过就直接给；基础管线在 → 按本笔颜色状态特化（提交线程，不进着色器编译）；不在 → 后台建、这次给 nil（照旧等）
// 预热时先取随包拉取基础管线（预热工人调，warm_task_ 的绘制行）：这对着色器、这一种采样 / 拓扑类的基础管线随包有就取进 g_pbase，首遇直接按本笔特化，
//   不跳过也不等（查随包归档要经编译服务特化函数，几十到几百毫秒，放在首遇里不是卡就是跳过：11-25 一款动作冒险游戏查询挪到后台后约 800 次首遇改成跳过，
//   跳过的绘制多 8 倍，角色闪白）。只查随包、不现建（没有的首遇时照旧后台建）；同一把基底键只查一次。条件同 pso_get_ 走混合管线的那一笔
static NSMutableSet<NSData *> *g_hy_pre_tried;   // g_pbase_lock
static _Atomic uint64_t g_hy_pre_n, g_hy_pre_hit, g_hy_pre_ns;   // 预热里查了几把基底键 / 查中几把 / 查询耗时合计
static int hybrid_prefetch(const pso_key *k, NvShader *vs, NvShader *fs) {   // → 1 查中、0 没查中、-1 没查（已有 / 查过 / 不走混合管线）
    if (!vs || !fs || !vs->has_pull || k->fc || k->fsfn || !hybrid_on()) return -1;
    if (pb_prefetch_full()) return -1;   // 管线额度到预热线：不再先取（不占额度），首遇时照旧在后台建
    if (@available(macOS 26.0, iOS 26.0, *)) {
        MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0);
        if (!hybrid_fits(d, vs, fs)) return -1;
        pbase_key bk = pbase_key_of(d, vs, fs);
        NSData *tk = [NSData dataWithBytes:&bk length:sizeof bk];
        os_unfair_lock_lock(&g_pbase_lock);
        int skip = hm_get_id(&g_pbase, &bk) != nil || [g_hy_pre_tried containsObject:tk];
        if (!skip) { if (!g_hy_pre_tried) g_hy_pre_tried = [NSMutableSet set]; [g_hy_pre_tried addObject:tk]; }
        os_unfair_lock_unlock(&g_pbase_lock);
        if (skip) return -1;
        uint64_t t0 = bp_now(); id<MTLRenderPipelineState> pb = hybrid_pkg_base(pull_desc4(d, vs, fs, 1), vs, fs);
        atomic_fetch_add(&g_hy_pre_n, 1); atomic_fetch_add(&g_hy_pre_ns, bp_now() - t0);
        if (!pb) return 0;
        atomic_fetch_add(&g_hy_pre_hit, 1);
        os_unfair_lock_lock(&g_pbase_lock); if (!hm_get_id(&g_pbase, &bk)) pb_base_put_locked(&bk, pb); os_unfair_lock_unlock(&g_pbase_lock);
        return 1;
    }
    return -1;
}
// 拉取基础管线的后台队列（串行、utility）：查随包归档与现建都在这里；单测 dispatch_sync 一个空块等它做完
static dispatch_queue_t hybrid_q(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("dm.nvn.hybrid", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    return q;
}
static __unsafe_unretained id<MTLRenderPipelineState> hybrid_get(const pso_key *k, NvShader *vs, NvShader *fs) {
    __unsafe_unretained id h = hm_get_id(&g_pso_hy, k);
    if (h) return h == (id)NSNull.null ? nil : h;   // NSNull：特化失败过，这个键不再试
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (!hybrid_comp()) return nil;
        MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0);
        if (!hybrid_fits(d, vs, fs)) return nil;
        // 基底键认着色器对象（D-92BW）：原先认函数指针，预热后放掉的着色器补回后函数是新对象，旧键不再命中；放掉的旧函数地址还可能被别的新函数占去、撞出错的基底。
        //   着色器对象常驻：同一对着色器 → 同一拉取入口（pull_fn 按 vs 的键与入口名载）与同一片元主入口
        pbase_key bk = pbase_key_of(d, vs, fs);
        os_unfair_lock_lock(&g_pbase_lock); id base = hm_get_id(&g_pbase, &bk); if (!base) hm_put_id(&g_pbase, &bk, NSNull.null); else if (base != NSNull.null) pb_base_touch_locked(&bk); os_unfair_lock_unlock(&g_pbase_lock);
        id bd = base ? nil : pull_desc4(d, vs, fs, 1);
        // 第一次：查随包归档、查不中就现建，都在后台队列（hybrid_q）做，这一笔照旧给 nil（首遇跳过 / 等精确管线）；占位 NSNull 防重复踢，好了换成管线。
        //   查随包归档也不放提交线程：查中了 Metal 4 归档建管线仍要经编译服务特化一次函数（AGX Metal4To3 转换 createFunction → MTLCompilerScheduler 同步请求），
        //   内存吃紧时单次 40–770 ms、线程 CPU < 2 ms（11-25 一款动作冒险游戏入水那一下：同一帧踩到十几对，整帧 0.8–1.3 s；挪到后台后那一帧 69 ms）
        if (!base) {
            g_hy_kicked++;
            dispatch_async(hybrid_q(), ^{ @autoreleasepool { NSError *e = nil; id<MTLRenderPipelineState> ps = hybrid_pkg_base(bd, vs, fs);
                if (!ps) ps = [g_hy_comp newRenderPipelineStateWithDescriptor:bd compilerTaskOptions:nil error:&e];
                if (ps) { os_unfair_lock_lock(&g_pbase_lock); pb_base_put_locked(&bk, ps); os_unfair_lock_unlock(&g_pbase_lock); g_hy_bases++; }
                else { uint64_t n = ++g_hy_base_fail; if (n <= 8) MLOG("【红】 hybrid pipelines: pulling base for vertex %s fragment %s failed: %s (that pair's first uses wait)", vs->key, fs->key, e.localizedDescription.UTF8String); } } });
            g_hy_none++; return nil;
        }
        if (base == NSNull.null) { g_hy_none++; return nil; }   // 还在建，或建不出
        NSError *e = nil; uint64_t t0 = bp_now();
        id<MTLRenderPipelineState> ps = [g_hy_comp newRenderPipelineStateBySpecializationWithDescriptor:pull_desc4(d, vs, fs, 0) pipeline:base error:&e];
        g_hy_spec_ns += bp_now() - t0;
        if (!ps) { static int n; if (n++ < 8) MLOG("【红】 hybrid pipelines: specializing the pulling base for vertex %s fragment %s failed: %s", vs->key, fs->key, e.localizedDescription.UTF8String); hm_put_id(&g_pso_hy, k, NSNull.null); return nil; }
        uint64_t m = ++g_hy_made; hm_put_id(&g_pso_hy, k, ps);
        if (!(m & (m - 1))) MLOG("hybrid pipelines: %llu made by specializing a pulling base (mean %.2f ms), %llu draws with them; %llu first uses found no base ready (%llu bases built, %llu failed)",
                                 (unsigned long long)m, g_hy_spec_ns / 1e6 / m, (unsigned long long)g_hy_draws, (unsigned long long)g_hy_none, (unsigned long long)g_hy_bases, (unsigned long long)g_hy_base_fail);
        return ps;
    }
    return nil;
}
