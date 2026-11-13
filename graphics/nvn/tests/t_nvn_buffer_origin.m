// #329 Metal 3 buffer-origin regression: production vconv_bind and tf_draw on a real GPU.
// The test owns the MSL source, its B reflection, and the bytes/indices; no host stubs or mirrored implementation.
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

enum { INPUT_N = 256, POOL_BYTES = 16384, TF_PREFIX = 64, TF_BYTES = 256, SECOND_PREFIX = 8192, SECOND_BYTES = 224,
       VCONV_PREFIX = 4096, VCONV_FIRST = 128, VCONV_COUNT = 4, REC_WORDS = 4, REC_BYTES = 16 };
static const uint32_t SENTINEL = 0xa5a5a5a5u;
static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; \
    printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Input { uint4 value [[attribute(0)]]; };\n"
     "vertex float4 main0(Input in [[stage_in]], uint vid [[vertex_id]]) { return float4(0.0, 0.0, 0.0, 1.0); }\n"
     "vertex void main0_tf(Input in [[stage_in]], uint vid [[vertex_id]], uint iid [[instance_id]], device uint *tf0 [[buffer(8)]]) {\n"
     "  uint at = vid * 4; tf0[at] = in.value.x; tf0[at + 1] = in.value.y; tf0[at + 2] = vid; tf0[at + 3] = iid;\n"
     "}\n";

static NvShader *make_shader(id<MTLLibrary> library) {
    NvShader *vs = [NvShader new]; vs->stage = 0;
    vs->fn = [library newFunctionWithName:@"main0"]; REQUIRE(vs->fn);
    vs->tf_fn = [library newFunctionWithName:@"main0_tf"]; REQUIRE(vs->tf_fn);
    vs->tf_stride[0] = REC_BYTES;
    strlcpy(vs->key, "buffer-origin", sizeof vs->key);
    NSDictionary *reflection = @{ @"route": @"B", @"bindings": @[],
        @"vertex_inputs": @[ @{ @"location": @0, @"msl_type": @"uint4" } ] };
    char error[256] = "";
    REQUIRE(!nvn_refl_from_json(reflection, &vs->rf, error, sizeof error));
    REQUIRE(vs->rf.nv == 1 && vs->rf.v[0].loc == 0 && vs->rf.v[0].ct == NVN_CT_UINT);
    return vs;
}

static uint32_t converted(int vertex) {
    int8_t raw = (int8_t)(vertex * 7 + 3);
    return (uint32_t)(int32_t)raw;
}

static void expect_record(const uint32_t *pool, size_t byte_offset, int vertex, int instance, const char *case_name, unsigned ordinal) {
    const uint32_t *got = (const uint32_t *)((const uint8_t *)pool + byte_offset) + ordinal * REC_WORDS;
    int ok = got[0] == converted(vertex) && got[1] == 0 && got[2] == (uint32_t)vertex && got[3] == (uint32_t)instance;
    VERIFY(ok, "%s record %u: value=%#x vertex=%u instance=%u", case_name, ordinal, got[0], got[2], got[3]);
}

static int child(int metal3) {
    alarm(60);
    setenv("DM_PRESENT_LINK", "0", 1);
    setenv("DM_NVN_VCONV_RANGE", "1", 1);
    mtl_init();
    REQUIRE(g_m3 == metal3);
    if (!metal3) { int supported = 0; if (@available(macOS 26.0, *)) supported = [g_dev supportsFamily:MTLGPUFamilyMetal4]; REQUIRE(supported); }

    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:options error:&error];
    if (!library) fprintf(stderr, "MSL compile: %s\n", error.localizedDescription.UTF8String);
    REQUIRE(library);
    NvShader *vs = make_shader(library); NvProg *program = [NvProg new]; program->sh[0] = vs;

    int8_t *input = NULL; uint32_t *output = NULL; uint32_t *indices = NULL;
    REQUIRE(!posix_memalign((void **)&input, 16384, POOL_BYTES));
    REQUIRE(!posix_memalign((void **)&output, 16384, POOL_BYTES));
    REQUIRE(!posix_memalign((void **)&indices, 16384, POOL_BYTES));
    for (int i = 0; i < INPUT_N; i++) input[i] = (int8_t)(i * 7 + 3);
    for (size_t i = 0; i < POOL_BYTES / sizeof(uint32_t); i++) output[i] = SENTINEL;
    const uint32_t index_data[5] = {0, 1, 0, 2, 3};
    const uint32_t negative_base_indices[4] = {20, 22, 20, 21};
    memcpy(indices, index_data, sizeof index_data);
    memcpy(indices + 8, negative_base_indices, sizeof negative_base_indices);
    nvn_be_pool_add(input, POOL_BYTES); nvn_be_pool_add(output, POOL_BYTES); nvn_be_pool_add(indices, POOL_BYTES);

    memset(&S, 0, sizeof S);
    S.nattr = 1; S.attr[0] = (va_st){.fmt = 0x04, .offset = 0, .stream = 0}; // signed byte feeding a uint input must take vconv
    S.nstream = 1; S.stream[0] = (vs_st){.stride = 1, .divisor = 0};
    S.vbuf[0] = (NVNbufferRange){.address = (uint64_t)(uintptr_t)input, .size = INPUT_N};

    nvn_be_sub_begin();

    // Direct vconv_bind path (tf=0): a high first makes the converted arena binding precede its new MTLBuffer.
    p_draw direct_vconv = {.prim = 0, .first = VCONV_FIRST, .count = VCONV_COUNT, .instances = 1};
    id<MTLRenderPipelineState> ps = tf_pso(vs); REQUIRE(ps);
    MTL4RenderPassDescriptor *pass = pass_desc(); pass.renderTargetWidth = 1; pass.renderTargetHeight = 1; pass.defaultRasterSampleCount = 1;
    id<MTL4RenderCommandEncoder> encoder = enc_r_begin(pass);
    REQUIRE(encoder);
    enc_r_pso(encoder, ps); bind_vbufs(encoder, vs);
    vconv_bind(encoder, vs, 0, &direct_vconv, NULL);
    uint64_t vconv_gpu = 0; void *vconv_buf = NULL; uint64_t vconv_off = 0;
    uint64_t vconv_target = (uint64_t)(uintptr_t)(output + VCONV_PREFIX / sizeof(uint32_t));
    REQUIRE(mtl_gpu_addr(vconv_target, VCONV_COUNT * REC_BYTES, &vconv_buf, &vconv_off, &vconv_gpu));
    REQUIRE(vconv_off >= (uint64_t)VCONV_FIRST * REC_BYTES);
    enc_r_vbuf(encoder, TF_SLOT, vconv_gpu - (uint64_t)VCONV_FIRST * REC_BYTES);
    enc_r_draw(encoder, MTLPrimitiveTypePoint, VCONV_FIRST, VCONV_COUNT);
    enc_r_end(encoder);

    // Production tf_draw direct capture: first*stride exceeds the transform-feedback pool's origin.
    // The second indexed capture appends to the same range, carries baseVertex, duplicates index 0, and draws two instances.
    S.tf_on = 1; S.rast_discard = 1;
    S.tf[0] = (p_tf_bind){.index = 0, .addr = (uint64_t)(uintptr_t)(output + TF_PREFIX / sizeof(uint32_t)), .size = TF_BYTES};
    p_draw tf_direct = {.prim = 0, .first = 64, .count = 3, .instances = 2};
    tf_draw(program, &tf_direct, NULL);
    p_draw_idx tf_indexed = {.prim = 0, .itype = 2, .count = 5, .base_vertex = 40, .instances = 2,
        .ibuf = (uint64_t)(uintptr_t)indices};
    tf_draw(program, NULL, &tf_indexed);
    uint64_t fence = nvn_be_sub_commit();
    int completed = nvn_be_wait(fence, 10000000000ull);
    REQUIRE(completed);
    VERIFY(!mtl_last_commit_error(), "Metal %d submission completes without command-buffer error", metal3 ? 3 : 4);

    for (unsigned i = 0; i < VCONV_COUNT; i++) expect_record(output, VCONV_PREFIX, VCONV_FIRST + (int)i, 0, "vconv direct first=128", i);
    for (int instance = 0; instance < 2; instance++) for (int vertex = 0; vertex < 3; vertex++)
        expect_record(output, TF_PREFIX + (size_t)instance * 3 * REC_BYTES, 64 + vertex, instance, "tf array first=64", (unsigned)vertex);
    for (int instance = 0; instance < 2; instance++) {
        static const int order[5] = {40, 41, 40, 42, 43};
        for (int i = 0; i < 5; i++) expect_record(output, TF_PREFIX + 6 * REC_BYTES + (size_t)instance * 5 * REC_BYTES,
            order[i], instance, "tf indexed baseVertex=40 duplicate-index continuation", (unsigned)i);
    }
    unsigned guard_bad = 0;
    for (size_t i = 0; i < POOL_BYTES / sizeof(uint32_t); i++) {
        int tf_payload = i >= TF_PREFIX / sizeof(uint32_t) && i < (TF_PREFIX + TF_BYTES) / sizeof(uint32_t);
        int vconv_payload = i >= VCONV_PREFIX / sizeof(uint32_t) && i < (VCONV_PREFIX + VCONV_COUNT * REC_BYTES) / sizeof(uint32_t);
        if (!tf_payload && !vconv_payload) guard_bad += output[i] != SENTINEL;
    }
    VERIFY(!guard_bad && S.tf_off[0] == TF_BYTES, "TF continuation writes exactly %u bytes; prefix/trailing sentinels intact (changed %u words)", TF_BYTES, guard_bad);

    // Reuse a completed submission's arena. Indexed TF is first here, so its
    // scratch must carry its own prefix; no earlier allocation can hide it.
    nvn_be_sub_begin();
    S.tf[0].addr = (uint64_t)(uintptr_t)((uint8_t *)output + SECOND_PREFIX); S.tf[0].size = SECOND_BYTES; S.tf_off[0] = 0;
    p_draw_idx negative = {.prim = 0, .itype = 2, .count = 4, .base_vertex = -8, .instances = 2, .base_instance = 7,
        .ibuf = (uint64_t)(uintptr_t)(indices + 8)};
    tf_draw(program, NULL, &negative);
    // This destination has enough prefix already: it must retain direct binding.
    p_draw enough_prefix = {.prim = 0, .first = 200, .count = 3, .instances = 2, .base_instance = 9};
    tf_draw(program, &enough_prefix, NULL);
    uint64_t before_bad = atomic_load(&g_bad_feat), before_off = S.tf_off[0];
    p_draw too_small = {.prim = 0, .first = 0, .count = 1, .instances = 1};
    tf_draw(program, &too_small, NULL);
    VERIFY(atomic_load(&g_bad_feat) == before_bad + 1 && S.tf_off[0] == before_off,
        "full TF target rejects the next record without advancing its offset");
    fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull));
    VERIFY(!mtl_last_commit_error(), "Metal %d second submission completes", metal3 ? 3 : 4);
    static const int negative_order[4] = {12, 14, 12, 13};
    for (int instance = 0; instance < 2; instance++) for (int i = 0; i < 4; i++)
        expect_record(output, SECOND_PREFIX + (size_t)instance * 4 * REC_BYTES, negative_order[i], 7 + instance, "negative baseVertex, nonzero baseInstance", i);
    for (int instance = 0; instance < 2; instance++) for (int i = 0; i < 3; i++)
        expect_record(output, SECOND_PREFIX + 8 * REC_BYTES + (size_t)instance * 3 * REC_BYTES, 200 + i, 9 + instance, "direct target with existing prefix", i);
    guard_bad = 0;
    for (size_t i = 0; i < POOL_BYTES / 4; i++) {
        int payload = (i >= TF_PREFIX / 4 && i < (TF_PREFIX + TF_BYTES) / 4) ||
            (i >= VCONV_PREFIX / 4 && i < VCONV_PREFIX / 4 + VCONV_COUNT * REC_WORDS) ||
            (i >= SECOND_PREFIX / 4 && i < (SECOND_PREFIX + SECOND_BYTES) / 4);
        if (!payload) guard_bad += output[i] != SENTINEL;
    }
    VERIFY(!guard_bad && S.tf_off[0] == SECOND_BYTES, "second submission and rejected overflow preserve all pool guards");
    unsigned input_bad = 0;
    for (int i = 0; i < INPUT_N; i++) input_bad += input[i] != (int8_t)(i * 7 + 3);
    VERIFY(!input_bad && !memcmp(indices, index_data, sizeof index_data) && !memcmp(indices + 8, negative_base_indices, sizeof negative_base_indices),
        "vertex bytes and both index sequences remain unchanged");
    nvn_be_drain();
    printf("%s t_nvn_buffer_origin Metal %d: %u checks, %u failures (production vconv_bind + tf_draw)\n",
        failures ? "FAIL" : "PASS", metal3 ? 3 : 4, checks, failures);
    // The production no-copy buffers remain registered until process exit.
    // Their backing allocations must live just as long.
    return failures != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--child")) return child(atoi(argv[2]));
        REQUIRE(argc == 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("FAIL t_nvn_buffer_origin: no Metal device\n"); return 1; }
        int os26 = 0; if (@available(macOS 26.0, *)) os26 = 1;
        if (!os26 || ![device supportsFamily:MTLGPUFamilyMetal4]) { printf("FAIL t_nvn_buffer_origin: Metal 4 family required for both backend runs\n"); return 1; }
        unsigned bad = 0;
        for (int metal3 = 0; metal3 < 2; metal3++) {
            fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
            if (!pid) {
                if (metal3) setenv("NXGAL_BE", "mtl3", 1); else unsetenv("NXGAL_BE");
                execl(argv[0], argv[0], "--child", metal3 ? "1" : "0", (char *)NULL); _exit(127);
            }
            int status = 0; pid_t waited; do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
            REQUIRE(waited == pid);
            int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            printf("%s process Metal %d (status=%d)\n", ok ? "PASS" : "FAIL", metal3 ? 3 : 4, status);
            bad += !ok;
        }
        printf("%s t_nvn_buffer_origin: %u backend processes failed\n", bad ? "✗" : "✓", bad);
        return bad != 0;
    }
}
