// D-92BW 着色器库按活跃集持有（nvn_mtl.m sh_release_unused / sh_hydrate_locked / shader_used / warm_shader）：含生产 nvn_mtl.m 源码（同 t_nvn_shader_flight.m 写法），
//   库放在按格式手造的库容器里（同 t_lib_pack.m write_pack；两键单独成段 + 两键共用一个批库段），走真加载、真预热入口、真 Metal 建管线并上 GPU 画、读回像素。
//   期望全按规则手写、不跑被测实现推：
//   ⓪ 没设 DM_NVN_SH_RELEASE 时 Mac 默认不放（sh_release_on）：放之后映射照旧 3 页、放掉 0 个、函数都在；之后设 DM_NVN_SH_RELEASE=1，按 iOS 的默认测 ①–⑥
//   ① 预热建了 4 个键（A 单库、B 单库、C/D 同一批库），游戏用过 A：放之前本进程映射着 3 页 .pak（A、B、批库各一段、各一页），放之后只剩 A 那 1 页（B 与批库的映射释放）；放掉的个数 = 3（B、C、D）
//   ② 放之前用 B 建好的管线，放之后照常画（读回 0.375）
//   ③ 游戏第一次用 B（shader_get）：同一个对象、函数补回（非空）、映射回到 2 段、用补回的函数新建管线画（0.375）、补回计数 +1
//   ④ 游戏用过的 A 不放：放完 A 的函数还在、同一个函数对象
//   ⑤ 再次预热（多程序换程序后）拿到已放的 C：warm_shader 先补回，函数非空、批库映射回来（3 段）
//   ⑥ 补回失败（库容器里这一键的库段读不出）：shader_get 返回空、报红一次，不崩
//   反证（撤收口必红）：把 shader_used 里的补回去掉编同一份测试（NVN_LIB_ACTIVE_SOURCE 指向改过的源码），③ 必红；放库时不清批库字典（改前 ulibs 一直强引用）批库映射放不掉，① 必红
#ifndef NVN_LIB_ACTIVE_SOURCE
#define NVN_LIB_ACTIVE_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_LIB_ACTIVE_SOURCE
#include <libproc.h>
#include <mach/mach_vm.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while(0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)

// 本进程映射着 <dir> 下 .pak 的页数（按区域自己的文件路径认，同 t_lib_pack.m pak_maps）。数页不数区域：相邻两段的文件映射偏移也相邻时内核会并成一个区域；
//   容器里每段各自对齐到页首、且不足一页（write_pack），所以一个活着的库段正好一页
static int pak_maps(const char *dir) {
    uint64_t n = 0; mach_vm_address_t a = 0; mach_vm_size_t sz; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c; mach_port_t obj; struct proc_regionwithpathinfo ri;
    for (;; a += sz) { c = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &obj) != KERN_SUCCESS) break;
        if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &ri, sizeof ri) == (int)sizeof ri && ri.prp_prinfo.pri_address == a
            && strstr(ri.prp_vip.vip_path, dir) && strstr(ri.prp_vip.vip_path, ".pak")) n += sz; }
    return (int)(n / (uint64_t)getpagesize());
}
// 映射在 dispatch_data 的析构里放（库容器的 IO 队列上，异步）：等到等于 want 或 10 秒
static int pak_maps_settle(const char *dir, int want) {
    uint64_t deadline = bp_now() + 10000000000ull; int n;
    while ((n = pak_maps(dir)) != want && bp_now() < deadline) usleep(5000);
    return n;
}
static NSData *metallib(NSString *tmp, NSString *name, NSString *src) {
    NSString *m = [tmp stringByAppendingPathComponent:[name stringByAppendingString:@".metal"]], *air = [m stringByAppendingString:@".air"], *lib = [m stringByAppendingString:@".metallib"];
    REQUIRE([src writeToFile:m atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *cmd = [NSString stringWithFormat:@"xcrun -sdk macosx metal -c '%@' -o '%@' && xcrun -sdk macosx metallib '%@' -o '%@'", m, air, air, lib];
    REQUIRE(system(cmd.UTF8String) == 0);
    NSData *d = [NSData dataWithContentsOfFile:lib]; REQUIRE(d); return d;
}
typedef struct { uint64_t key; uint8_t kind; uint32_t len; uint64_t off; } rec;
// 单分片容器（格式同 t_lib_pack.m write_pack）：segs[i] 同一个 NSData 对象 = 共用一段（批库）；记录须按 (键, 种类) 升序给
static void write_pack(NSString *dir, NSArray<NSData *> *segs, const uint64_t *keys, const uint8_t *kinds, int n) {
    NSMutableData *sh = [NSMutableData data]; rec r[16]; REQUIRE(n <= 16);
    for (int i = 0; i < n; i++) { int j = 0;
        while (j < i && segs[j] != segs[i]) j++;
        if (j < i) { r[i] = r[j]; r[i].key = keys[i]; r[i].kind = kinds[i]; continue; }
        while (sh.length % (NSUInteger)getpagesize()) [sh appendBytes:"\0" length:1];   // 每段从页首起（pak_maps 按页数）
        REQUIRE(segs[i].length < (NSUInteger)getpagesize());
        r[i] = (rec){keys[i], kinds[i], (uint32_t)segs[i].length, sh.length}; [sh appendData:segs[i]]; }
    REQUIRE([sh writeToFile:[dir stringByAppendingPathComponent:@"lib.000.pak"] atomically:YES]);
    NSMutableData *ix = [NSMutableData data]; uint32_t ver = 1, nn = (uint32_t)n, ns = 1, z = 0; char ch[12] = {0}; memcpy(ch, DMSH_CHAIN, strlen(DMSH_CHAIN) < 12 ? strlen(DMSH_CHAIN) : 12);
    [ix appendBytes:"S2ALIB\0\0" length:8]; [ix appendBytes:&ver length:4]; [ix appendBytes:&nn length:4]; [ix appendBytes:&ns length:4]; [ix appendBytes:&z length:4];
    [ix appendBytes:ch length:12]; [ix appendBytes:&z length:4]; [ix appendBytes:&z length:4]; [ix appendBytes:&z length:4];
    uint64_t sz = sh.length, zz = 0; [ix appendBytes:&sz length:8]; [ix appendBytes:&zz length:8];
    for (int i = 0; i < n; i++) { uint16_t z16 = 0; uint8_t s0 = 0; [ix appendBytes:&r[i].key length:8]; [ix appendBytes:&r[i].kind length:1]; [ix appendBytes:&s0 length:1];
        [ix appendBytes:&z16 length:2]; [ix appendBytes:&r[i].len length:4]; [ix appendBytes:&r[i].off length:8]; }
    REQUIRE([ix writeToFile:[dir stringByAppendingPathComponent:@"lib.idx"] atomically:YES]);
}
static NSData *json(NSString *entry) {
    return [NSJSONSerialization dataWithJSONObject:@{@"chain":@DMSH_CHAIN, @"route":@"B", @"bindings":@[], @"entry":entry} options:0 error:nil];
}
static id<MTLRenderPipelineState> pipeline(id<MTLFunction> vf) {
    static id<MTLFunction> ff; if (!ff) { NSError *e = nil;
        id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; float value; };\nfragment float4 color(V v [[stage_in]]) { return float4(v.value,0,0,1); }\n" options:nil error:&e];
        REQUIRE(l); ff = [l newFunctionWithName:@"color"]; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = vf; pd.fragmentFunction = ff; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    NSError *e = nil; id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!p) fprintf(stderr, "PSO: %s\n", e.localizedDescription.UTF8String); return p;
}
static float draw_red(id<MTLRenderPipelineState> p) {   // 画满一张 1×1 的图、读回红分量
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; id<MTLTexture> t = [g_dev newTextureWithDescriptor:td]; REQUIRE(t);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, -1, -1, -1);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:p]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    id<MTLBuffer> out = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256]; [b endEncoding];
    [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    return *(float *)out.contents;
}
#define VS(name, value) @"vertex V " name "(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return {float4(p[i],0,1)," value "}; }\n"
static NSString *const head = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; float value; };\n";

int main(void) { @autoreleasepool {
    char tmp[] = "/tmp/t_nvn_lib_active_XXXXXX"; REQUIRE(mkdtemp(tmp)); NSString *root = @(tmp);
    NSString *libdir = [root stringByAppendingPathComponent:@"b-" DMSH_CHAIN];
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:libdir withIntermediateDirectories:YES attributes:nil error:nil]);
    // 键：A = 0xa1…、B = 0xb2…（各自一段库）；C = 0xc3…、D = 0xd4…（同一个批库段，函数名带 s<键>_ 前缀）；E = 0xe5…（json 在、库段坏：补回失败用）
    NSString *A = @"a1a1a1a1a1a1a1a1", *B = @"b2b2b2b2b2b2b2b2", *C = @"c3c3c3c3c3c3c3c3", *D = @"d4d4d4d4d4d4d4d4", *E = @"e5e5e5e5e5e5e5e5";
    NSData *la = metallib(root, @"a", [head stringByAppendingString:VS("plain", "0.25")]), *lb = metallib(root, @"b", [head stringByAppendingString:VS("plain", "0.375")]);   // 与 A 的库内容不同：Metal 对逐字节相同的库数据只留一份，相同就数不出两页
    NSData *lcd = metallib(root, @"cd", [NSString stringWithFormat:@"%@%@%@", head, [NSString stringWithFormat:VS("s%@_plain", "0.5"), C], [NSString stringWithFormat:VS("s%@_plain", "0.75"), D]]);
    NSMutableDictionary *jc = [NSJSONSerialization JSONObjectWithData:json(@"plain") options:NSJSONReadingMutableContainers error:nil];
    jc[@"fn_lib"] = @"batch_cd"; jc[@"fn_prefix"] = [NSString stringWithFormat:@"s%@_", C];
    NSMutableDictionary *jd = [jc mutableCopy]; jd[@"fn_prefix"] = [NSString stringWithFormat:@"s%@_", D];
    NSData *bad = [@"not a metallib" dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t keys[10] = {0xa1a1a1a1a1a1a1a1ull, 0xa1a1a1a1a1a1a1a1ull, 0xb2b2b2b2b2b2b2b2ull, 0xb2b2b2b2b2b2b2b2ull, 0xc3c3c3c3c3c3c3c3ull, 0xc3c3c3c3c3c3c3c3ull,
                         0xd4d4d4d4d4d4d4d4ull, 0xd4d4d4d4d4d4d4d4ull, 0xe5e5e5e5e5e5e5e5ull, 0xe5e5e5e5e5e5e5e5ull};
    uint8_t kinds[10] = {LP_K_B, LP_K_BJSON, LP_K_B, LP_K_BJSON, LP_K_B, LP_K_BJSON, LP_K_B, LP_K_BJSON, LP_K_B, LP_K_BJSON};
    NSData *je = json(@"plain");
    write_pack(libdir, @[la, json(@"plain"), lb, json(@"plain"), lcd, [NSJSONSerialization dataWithJSONObject:jc options:0 error:nil],
                         lcd, [NSJSONSerialization dataWithJSONObject:jd options:0 error:nil], bad, je], keys, kinds, 10);
    NSString *map = [root stringByAppendingPathComponent:@"shader_map.tsv"];
    NSString *rows = [NSString stringWithFormat:@"original\t0\tvertex\t%@\noriginal\t0\tvertex\t%@\noriginal\t0\tvertex\t%@\noriginal\t0\tvertex\t%@\noriginal\t0\tvertex\t%@\n", A, B, C, D, E];
    REQUIRE([rows writeToFile:map atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    setenv("DM_NVN_SHMAP", map.fileSystemRepresentation, 1); setenv("DM_MSL_DIR", root.fileSystemRepresentation, 1);
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "0", 1); setenv("DM_PSO_USER", [root stringByAppendingPathComponent:@"user.tsv"].fileSystemRepresentation, 1);
    unsetenv("DM_MSL_FALLBACK");
    mtl_init(); shmap_load(); printf("GPU %s\n", g_dev.name.UTF8String);
    const char *ld = libdir.fileSystemRepresentation;
    NSString *ka = [A stringByAppendingString:@"_b"], *kb = [B stringByAppendingString:@"_b"], *kc = [C stringByAppendingString:@"_b"], *kd = [D stringByAppendingString:@"_b"], *ke = [E stringByAppendingString:@"_b"];

    NvShader *a, *b, *c, *d; id<MTLFunction> a_fn; id<MTLRenderPipelineState> pb;
    @autoreleasepool {
        a = warm_shader(ka, 0); b = warm_shader(kb, 0); c = warm_shader(kc, 0); d = warm_shader(kd, 0);
        REQUIRE(a && b && c && d && a->fn && b->fn && c->fn && d->fn);
        REQUIRE(shader_get(ka, 0) == a); a_fn = a->fn;
        pb = pipeline(b->fn); REQUIRE(pb);
    }
    int before = pak_maps_settle(ld, 3);
    {   // ⓪ 默认（没设 DM_NVN_SH_RELEASE）：Mac 不放（sh_release_on），iOS 放（下面 ① 起的情形，这里只核 Mac）
        unsetenv("DM_NVN_SH_RELEASE"); g_sh_rel = -1; uint64_t r0 = atomic_load(&g_rel_n);
        @autoreleasepool { sh_release_unused(); }
        int still = pak_maps_settle(ld, 3);
        if (!TARGET_OS_IPHONE) CHECK(atomic_load(&g_rel_n) == r0 && still == 3 && b->fn && !b->skel && c->fn && d->fn,
                                     "⓪ Mac 默认不放：放掉 %llu 个（期望 0）、映射 %d 页（期望 3）、B / C / D 函数都在", (unsigned long long)(atomic_load(&g_rel_n) - r0), still);
        setenv("DM_NVN_SH_RELEASE", "1", 1); g_sh_rel = -1;   // 以下按 iOS 的默认（放）测
    }
    uint64_t rel0 = atomic_load(&g_rel_n);
    @autoreleasepool { sh_release_unused(); }
    int after = pak_maps_settle(ld, 1);
    CHECK(before == 3 && after == 1 && atomic_load(&g_rel_n) - rel0 == 3, "① 放之前映射 %d 页（期望 3）、放之后 %d 页（期望 1）、放掉 %llu 个（期望 3）", before, after, (unsigned long long)(atomic_load(&g_rel_n) - rel0));
    CHECK(!b->fn && b->skel && !c->fn && !d->fn, "① 只被预热用过的 B / C / D 只剩骨架（函数空）");
    float v = draw_red(pb);
    CHECK(v == 0.375f, "② 放之前用 B 建的管线照常画：读回 %.3f（期望 0.375）", v);
    CHECK(a->fn && a->fn == a_fn && !a->skel, "④ 游戏用过的 A 不放：函数还在、同一个对象");

    uint64_t h0 = atomic_load(&g_hyd_n);
    NvShader *b2 = shader_get(kb, 0);
    int maps_b = pak_maps_settle(ld, 2);
    CHECK(b2 == b && b->fn && !b->skel && atomic_load(&g_hyd_n) - h0 == 1 && maps_b == 2,
          "③ 游戏第一次用 B：同一对象 %s、函数%s、补回 +%llu（期望 +1）、映射 %d 页（期望 2）", b2 == b ? "是" : "否", b->fn ? "补回" : "仍空", (unsigned long long)(atomic_load(&g_hyd_n) - h0), maps_b);
    id<MTLRenderPipelineState> pb2 = b->fn ? pipeline(b->fn) : nil;
    v = pb2 ? draw_red(pb2) : -9;
    CHECK(v == 0.375f, "③ 用补回的函数新建管线画：读回 %.3f（期望 0.375）", v);

    NvShader *c2 = warm_shader(kc, 0);
    int maps_c = pak_maps_settle(ld, 3);
    CHECK(c2 == c && c->fn && !c->skel && maps_c == 3, "⑤ 再次预热拿到已放的 C：同一对象、函数补回、批库映射回来（%d 页，期望 3）", maps_c);
    id<MTLRenderPipelineState> pc = c->fn ? pipeline(c->fn) : nil;
    v = pc ? draw_red(pc) : -9;
    CHECK(v == 0.5f, "⑤ C 补回的函数是批库里它自己那一个：读回 %.2f（期望 0.5）", v);

    // ⑥ 补回失败：容器里 E 的库段是坏的（不是 metallib），E 建不起来；直接放一个 E 的骨架进缓存（同预热建过、预热后被放掉的状态），游戏再要它时补回失败
    NvShader *e = [NvShader new]; e->stage = 0; e->pkg_lib = 1; e->warm_lib = 1; e->skel = 1; strlcpy(e->key, ke.UTF8String, sizeof e->key);
    os_unfair_lock_lock(&g_shader_lock); if (!g_shcache) g_shcache = [NSMutableDictionary dictionary]; g_shcache[shader_identity(ke, 0, 0, 0)] = e; os_unfair_lock_unlock(&g_shader_lock);
    uint64_t f0 = atomic_load(&g_hyd_fail);
    NvShader *e2 = shader_get(ke, 0);
    CHECK(!e2 && atomic_load(&g_hyd_fail) - f0 == 1, "⑥ 补回失败：shader_get 返回%s、失败计数 +%llu（期望 +1）、不崩", e2 ? "非空" : "空", (unsigned long long)(atomic_load(&g_hyd_fail) - f0));

    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("%s t_nvn_lib_active: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
} }
