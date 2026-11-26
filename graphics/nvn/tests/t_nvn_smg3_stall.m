// 斯普拉遁3 停帧两件（10-26）：直接包含生产 nvn_mtl.m。期望按规则手写，不由被测实现推出：
//   ① tex_fit：着色器声明立方体数组、贴图是单个立方体 → 一个立方体的立方体数组视图（类型 CubeArray、arrayLength 1），同 Ryujinx GetTargetTexture；
//      3D 贴图进立方体槽 → nil（调用方绑声明类型的零贴图，不再照原样绑）
//   ② pso_pend_take 有界等待：后台没编完的管线，DM_NVN_PSO_WAIT_MS=150 → 约 150 ms 返回、标超时；同一管线再取立即返回（不再等）；编完后取到那份管线
//   ⑤ 不能跳的绘制（may_skip = 0）不受单条上限与帧预算约束，等到编完；⑥ 但有自己的上限兜底（DM_NVN_PSO_UNSAFE_WAIT_MS），超了照超时跳过；⑥b 等满过一次的管线之后不再等
//   「立即返回」按生产计数判，不按墙钟（原判 < 20 ms：负载高时被抢占就假红）：g_pp_wait_n = pso_pend_take 进入等编完的次数，立即返回的不涨。
//     「约 150 / 100 / 300 ms」那几条是产品承诺的时限，照旧量墙钟
//   反证：改前的 nvn_mtl.m 立方体→立方体数组返回 nil、pso_pend_take 无上限（且只有一个参数，本单测编不过）；pso_pend_take 没有 may_skip（两个参数）同样编不过
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) {
    @autoreleasepool {
        setenv("DM_NVN_PSO_WAIT_MS", "150", 1); setenv("DM_NVN_PSO_FRAME_MS", "0", 1);   // ② 先单看每条管线的上限；④ 再开每帧预算
        mtl_init();
        g_treg = calloc(4, sizeof *g_treg); g_ntreg = 4;
        MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:16 mipmapped:YES];
        id<MTLTexture> cube = [g_dev newTextureWithDescriptor:cd]; REQUIRE(cube);
        uint64_t rid = 0; id<MTLTexture> v = tex_fit(1, cube, MTLTextureTypeCubeArray, NVN_DPF_FLOAT, &rid);
        VERIFY(v && v.textureType == MTLTextureTypeCubeArray && v.arrayLength == 1 && v.mipmapLevelCount == cube.mipmapLevelCount && rid,
               "① 立方体读作立方体数组：一个立方体的立方体数组视图（实得 类型 %lu、%lu 个立方体、%lu 级）", (unsigned long)v.textureType, (unsigned long)v.arrayLength, (unsigned long)v.mipmapLevelCount);
        MTLTextureDescriptor *d3 = [MTLTextureDescriptor new]; d3.textureType = MTLTextureType3D; d3.pixelFormat = MTLPixelFormatRGBA8Unorm; d3.width = d3.height = d3.depth = 4;
        id<MTLTexture> t3 = [g_dev newTextureWithDescriptor:d3]; REQUIRE(t3);
        VERIFY(!tex_fit(2, t3, MTLTextureTypeCube, NVN_DPF_FLOAT, &rid), "① 3D 进立方体槽：没有视图（调用方绑零贴图）");
        VERIFY(!tex_fit(2, t3, MTLTextureType2D, NVN_DPF_FLOAT, &rid), "① 3D 进 2D 槽（动森 48 小时内 9 次）：没有视图，同 Ryujinx 不绑（调用方绑零贴图）");

        // ③ 多重采样声明（PR #490）：反射认出 texture2d_ms / _ms_array；多重采样贴图进自己的槽类型相同、不当不符；哑贴图能建出（私有、4 采样）
        nvn_refl rf; char err[200] = "";
        NSDictionary *j = @{ @"route": @"B", @"bindings": @[ @{ @"kind": @"tex", @"reg": @1, @"arg_id": @0, @"msl_name": @"fp_t0", @"msl_type": @"texture2d_ms<float>" },
                                                          @{ @"kind": @"tex", @"reg": @2, @"arg_id": @1, @"msl_name": @"fp_t1", @"msl_type": @"texture2d_ms_array<uint>" } ] };
        REQUIRE(!nvn_refl_from_json(j, &rf, err, sizeof err));
        VERIFY(rf.b[0].dtt == MTLTextureType2DMultisample && rf.b[1].dtt == MTLTextureType2DMultisampleArray && rf.b[1].dpf == NVN_DPF_UINT,
               "③ 反射：texture2d_ms → 2DMS、texture2d_ms_array<uint> → 2DMSArray + uint（实得 %d %d）", rf.b[0].dtt, rf.b[1].dtt);
        id<MTLTexture> zm = dummy_tex(MTLTextureType2DMultisample, NVN_DPF_FLOAT), za = dummy_tex(MTLTextureType2DMultisampleArray, NVN_DPF_UINT), z1 = dummy_tex(MTLTextureType1D, NVN_DPF_UINT);
        VERIFY(zm.textureType == MTLTextureType2DMultisample && za.textureType == MTLTextureType2DMultisampleArray && z1.textureType == MTLTextureType1D && za != z1,
               "③ 多重采样哑贴图建得出，2DMSArray（类型 8）不再与 1D 共用一格");
        id<MTLTexture> zc = tex_fit(1, [g_dev newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO]], MTLTextureTypeCube, NVN_DPF_UINT, &rid);
        VERIFY(zc && zc.textureType == MTLTextureTypeCube && zc.pixelFormat == MTLPixelFormatRGBA32Uint, "③ 2D 进 uint 立方体槽：零立方体按声明的 uint 类（PR #490，原先恒 float）");

        pso_key k; memset(&k, 0x5a, sizeof k);
        pthread_mutex_lock(&g_pp_mu); g_pp[0].k = k; g_pp[0].ps = nil; g_pp[0].done = 0; g_pp[0].late = 0; g_pp[0].used = 1; pthread_mutex_unlock(&g_pp_mu);
        int late = 0; uint64_t t0 = bp_now(); id ps = pso_pend_take(&k, &late, 1); double ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late && ms >= 140 && ms < 1000, "② 没编完：约 150 ms 返回并标超时（实得 %.0f ms、超时 %d）", ms, late);
        uint64_t pw0 = g_pp_wait_n; late = 0; t0 = bp_now(); ps = pso_pend_take(&k, &late, 1); ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late && g_pp_wait_n == pw0, "② 同一管线再取：立即返回（进入等待 %llu 次，期望 0；用时 %.1f ms 仅供参考）、仍标超时", (unsigned long long)(g_pp_wait_n - pw0), ms);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint i [[vertex_id]]) { return float4(0,0,0,1); }\nfragment float4 f() { return float4(1); }\n" options:nil error:nil]; REQUIRE(lib);
        pd.vertexFunction = [lib newFunctionWithName:@"v"]; pd.fragmentFunction = [lib newFunctionWithName:@"f"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> real = [g_dev newRenderPipelineStateWithDescriptor:pd error:nil]; REQUIRE(real);
        pthread_mutex_lock(&g_pp_mu); g_pp[0].ps = real; g_pp[0].done = 1; pthread_cond_broadcast(&g_pp_cv); pthread_mutex_unlock(&g_pp_mu);
        late = 0; ps = pso_pend_take(&k, &late, 1);
        VERIFY(ps == real && !late && !g_pp[0].used, "② 编完后取到那份管线、表项释放");

        // ④ 每帧等待预算（斯普拉遁3 第二局：一帧里几十条各等 1–2 秒、都没过单条上限，整帧 66.9 秒）：预算 100 ms、单条上限 2000 ms，两条都没编完
        setenv("DM_NVN_PSO_FRAME_MS", "100", 1); g_pso_frame_ms = -1;
        pso_key k2, k3; memset(&k2, 0x21, sizeof k2); memset(&k3, 0x33, sizeof k3);
        pthread_mutex_lock(&g_pp_mu); g_pp[1].k = k2; g_pp[1].ps = nil; g_pp[1].done = 0; g_pp[1].late = 0; g_pp[1].used = 1; g_pp[2].k = k3; g_pp[2].ps = nil; g_pp[2].done = 0; g_pp[2].late = 0; g_pp[2].used = 1; pthread_mutex_unlock(&g_pp_mu);
        atomic_fetch_add(&g_cur_frame, 1);
        late = 0; t0 = bp_now(); ps = pso_pend_take(&k2, &late, 1); ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late == 2 && ms >= 90 && ms < 600 && !g_pp[1].late, "④ 本帧第一条：等满预算约 100 ms 返回、记「预算跳过」不记超时（实得 %.0f ms、类 %d）", ms, late);
        pw0 = g_pp_wait_n; late = 0; t0 = bp_now(); ps = pso_pend_take(&k3, &late, 1); ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late == 2 && g_pp_wait_n == pw0, "④ 本帧第二条：预算已尽，立即返回（进入等待 %llu 次，期望 0；用时 %.1f ms 仅供参考）", (unsigned long long)(g_pp_wait_n - pw0), ms);
        atomic_fetch_add(&g_cur_frame, 1);
        late = 0; t0 = bp_now(); ps = pso_pend_take(&k3, &late, 1); ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late == 2 && ms >= 90, "④ 下一帧：预算重置，又能等约 100 ms（实得 %.0f ms）", ms);

        // ⑤ 不能跳的绘制（may_skip = 0：目标跨帧保留内容，如时间抗锯齿历史 / 曝光；奥德赛 Mac 冷启动 10-27 被预算跳过后 3D 全程黑）：本帧预算已尽、该管线也已标超时，
        //    仍等到编完拿到管线；后台 400 ms 后才编完（> 单条上限 150 ms、> 帧预算 100 ms）→ 等待 ≥ 350 ms、拿到 real、不标超时
        setenv("DM_NVN_PSO_WAIT_MS", "150", 1);
        pso_key k4; memset(&k4, 0x44, sizeof k4);
        pthread_mutex_lock(&g_pp_mu); g_pp[3].k = k4; g_pp[3].ps = nil; g_pp[3].done = 0; g_pp[3].late = 1; g_pp[3].used = 1; pthread_mutex_unlock(&g_pp_mu);
        late = 0; ps = pso_pend_take(&k3, &late, 1);   // 先把本帧预算用尽
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * (int64_t)NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            pthread_mutex_lock(&g_pp_mu); g_pp[3].ps = real; g_pp[3].done = 1; pthread_cond_broadcast(&g_pp_cv); pthread_mutex_unlock(&g_pp_mu); });
        late = 0; t0 = bp_now(); ps = pso_pend_take(&k4, &late, 0); ms = (bp_now() - t0) / 1e6;
        VERIFY(ps == real && !late && ms >= 350, "⑤ 不能跳的绘制：预算已尽、已标超时，仍等到编完拿到管线（实得 %.0f ms、超时 %d、拿到 %d）", ms, late, ps == real);
        // ⑥ 不能跳的绘制也有上限兜底（DM_NVN_PSO_UNSAFE_WAIT_MS，缺省 10000）：上限 300 ms、管线一直不编完 → 约 300 ms 返回、标超时（类 1）并记该管线 late（之后照超时处理），调用方跳过并报红
        setenv("DM_NVN_PSO_UNSAFE_WAIT_MS", "300", 1); g_pso_unsafe_ms = -1; atomic_fetch_add(&g_cur_frame, 1);
        pso_key k5; memset(&k5, 0x55, sizeof k5);
        pthread_mutex_lock(&g_pp_mu); g_pp[4].k = k5; g_pp[4].ps = nil; g_pp[4].done = 0; g_pp[4].late = 0; g_pp[4].used = 1; pthread_mutex_unlock(&g_pp_mu);
        late = 0; t0 = bp_now(); ps = pso_pend_take(&k5, &late, 0); ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late == 1 && g_pp[4].late && ms >= 280 && ms < 1500, "⑥ 不能跳的绘制等满上限 300 ms 仍没编完：返回、标超时并记 late（实得 %.0f ms、类 %d）", ms, late);
        // ⑥b 同一管线等满过不安全上限（编译服务卡在它上面）：之后不能跳的绘制也立即跳过、不再各等 300 ms（斯普拉遁3 10-27 PSB：同一管线连等 3 次 10 秒 = 31 秒停帧）；编完后照常取到
        pw0 = g_pp_wait_n; late = 0; t0 = bp_now(); ps = pso_pend_take(&k5, &late, 0); ms = (bp_now() - t0) / 1e6;
        VERIFY(!ps && late == 1 && g_pp_wait_n == pw0, "⑥b 等满过不安全上限的管线：再来不能跳的绘制立即返回（进入等待 %llu 次，期望 0；用时 %.1f ms 仅供参考）、标超时（类 %d）", (unsigned long long)(g_pp_wait_n - pw0), ms, late);
        pthread_mutex_lock(&g_pp_mu); g_pp[4].ps = real; g_pp[4].done = 1; pthread_cond_broadcast(&g_pp_cv); pthread_mutex_unlock(&g_pp_mu);
        late = 0; ps = pso_pend_take(&k5, &late, 0);
        VERIFY(ps == real && !late, "⑥b 编完后不能跳的绘制取到那份管线");

        // ⑦ 首遇跳过先看本帧等待预算（11-25 入水闪白：一上来就跳，画在每帧重画的中间目标上，物体闪白一两帧）：管线在后台编、本帧预算还有 → 不跳（交给 pso_pend_take 有界等）；
        //    预算用完 → 跳；下一帧预算重置 → 又不跳。没有颜色 / 深度目标、着色器不写存储，所以前面几条「能不能跳」的规则都放行，只剩预算这一条在判
        //    反证：改前预算还有时也返回 1（一上来就跳）
        setenv("DM_NVN_PSO_FRAME_MS", "100", 1); g_pso_frame_ms = -1; atomic_fetch_add(&g_cur_frame, 1);
        REQUIRE(R.rt.n == 0 && !R.rt.depth && first_skip_on());
        pso_key k6; memset(&k6, 0x66, sizeof k6);
        pthread_mutex_lock(&g_pp_mu); g_pp[5].k = k6; g_pp[5].ps = nil; g_pp[5].done = 0; g_pp[5].late = 0; g_pp[5].used = 1; pthread_mutex_unlock(&g_pp_mu);
        g_first_skipped = 0;
        VERIFY(first_skip_ok(&k6, NULL, NULL) == 0 && !g_first_skipped, "⑦ 后台在编、本帧预算还有：不跳，先等");
        late = 0; ps = pso_pend_take(&k6, &late, 1);   // 等满本帧预算（约 100 ms）
        VERIFY(!ps && late == 2, "⑦ 等满本帧预算仍没编完：预算跳过（类 %d）", late);
        VERIFY(first_skip_ok(&k6, NULL, NULL) == 1 && g_first_skipped, "⑦ 本帧预算已尽：跳过");
        atomic_fetch_add(&g_cur_frame, 1); g_first_skipped = 0;
        VERIFY(first_skip_ok(&k6, NULL, NULL) == 0 && !g_first_skipped, "⑦ 下一帧预算重置：又先等、不跳");
        pthread_mutex_lock(&g_pp_mu); g_pp[5].ps = real; g_pp[5].done = 1; pthread_cond_broadcast(&g_pp_cv); pthread_mutex_unlock(&g_pp_mu);
        VERIFY(first_skip_ok(&k6, NULL, NULL) == 0, "⑦ 后台已编完：不跳（直接取）");
    }
    if (failures) { printf("✗ t_nvn_smg3_stall：%u / %u 项不过\n", failures, checks); return 1; }
    printf("✓ t_nvn_smg3_stall：%u 项全过（立方体→立方体数组视图、后台管线有界等待、首遇跳过先用本帧预算等）\n", checks);
    return 0;
}
