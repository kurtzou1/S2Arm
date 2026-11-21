// #1783 vertex fetch limit: production bind_vbufs on a real GPU (Metal 4 and Metal 3 child processes).
// Maxwell's vertex fetch stops at the bound range's size and an attribute past it reads zero; Metal fetches by address with no length. A four-vertex stream sits in a pool whose
// bytes after it are a marker (as Breath of the Wild's Malice projection read index and descriptor bytes past a 128-byte quad): every vertex id past the range must read 0.
// The test owns the MSL, its reflection, the vertex bytes and the indices; the expected records are written out by hand below, not computed by the code under test.
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

enum { POOL_BYTES = 16384, STRIDE = 16, NVERT = 4, REC_WORDS = 4, OUT_RECS = 64 };
static const uint32_t MARK = 0xdeadbeefu;   // the pool's bytes after the bound range
static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; \
    printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Input { uint4 value [[attribute(0)]]; };\n"
     "vertex float4 main0(Input in [[stage_in]]) { return float4(0.0, 0.0, 0.0, 1.0); }\n"
     "vertex void main0_tf(Input in [[stage_in]], uint vid [[vertex_id]], device uint4 *tf0 [[buffer(8)]]) { tf0[vid] = in.value; }\n";

static NvShader *make_shader(id<MTLLibrary> library) {
    NvShader *vs = [NvShader new]; vs->stage = 0;
    vs->fn = [library newFunctionWithName:@"main0"]; REQUIRE(vs->fn);
    vs->tf_fn = [library newFunctionWithName:@"main0_tf"]; REQUIRE(vs->tf_fn);
    vs->tf_stride[0] = REC_WORDS * 4;
    strlcpy(vs->key, "vbuf-limit", sizeof vs->key);
    NSDictionary *reflection = @{ @"route": @"B", @"bindings": @[], @"vertex_inputs": @[ @{ @"location": @0, @"msl_type": @"uint4" } ] };
    char error[256] = "";
    REQUIRE(!nvn_refl_from_json(reflection, &vs->rf, error, sizeof error));
    return vs;
}

static uint32_t *g_out; static uint16_t *g_idx; static id<MTLRenderPipelineState> g_ps;
// One draw over a fresh output: idx = indices already in the index pool (direct draw when n_idx = 0: vertices first .. first + count - 1), records land at their vertex id.
//   Every index list is written before the first draw: ix_range write-protects the pages it read, and this process has no fault handler to take a later write (the runtime's)
static void run(NvShader *vs, const uint16_t *idx, int n_idx, int base_vertex, int first, int count) {
    for (int i = 0; i < OUT_RECS * REC_WORDS; i++) g_out[i] = 0x11111111u;
    nvn_be_sub_begin();
    MTL4RenderPassDescriptor *pass = pass_desc(); pass.renderTargetWidth = 1; pass.renderTargetHeight = 1; pass.defaultRasterSampleCount = 1;
    id<MTL4RenderCommandEncoder> en = enc_r_begin(pass); REQUIRE(en);
    enc_r_pso(en, g_ps);
    p_draw dw = {.prim = 0, .first = first, .count = count, .instances = 1};
    p_draw_idx di = {.prim = 0, .itype = 1, .count = n_idx, .base_vertex = base_vertex, .instances = 1, .ibuf = (uint64_t)(uintptr_t)idx};
    bind_vbufs(en, vs, n_idx ? NULL : &dw, n_idx ? &di : NULL);
    void *ob; uint64_t oo, og; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)g_out, OUT_RECS * REC_WORDS * 4, &ob, &oo, &og));
    enc_r_vbuf(en, TF_SLOT, og);
    if (n_idx) { void *ib; uint64_t io, ig; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)idx, (uint64_t)n_idx * 2, &ib, &io, &ig));
        enc_r_draw_indexed(en, MTLPrimitiveTypePoint, (NSUInteger)n_idx, MTLIndexTypeUInt16, ig, (NSUInteger)n_idx * 2, 1, base_vertex, 0); }
    else enc_r_draw(en, MTLPrimitiveTypePoint, (NSUInteger)first, (NSUInteger)count);
    enc_r_end(en);
    REQUIRE(nvn_be_wait(nvn_be_sub_commit(), 10000000000ull));
    VERIFY(!mtl_last_commit_error(), "submission completes without command-buffer error");
}
// Vertex v inside the range holds (v * 10 + 1, + 2, + 3, + 4); past it 0, 0, 0, 0
static void expect(int vid, int inside, const char *name) {
    const uint32_t *r = g_out + vid * REC_WORDS;
    uint32_t want[4] = {0, 0, 0, 0}; if (inside) for (int c = 0; c < 4; c++) want[c] = (uint32_t)(vid * 10 + 1 + c);
    VERIFY(!memcmp(r, want, sizeof want), "%s vertex %d reads %#x %#x %#x %#x (want %#x %#x %#x %#x)", name, vid, r[0], r[1], r[2], r[3], want[0], want[1], want[2], want[3]);
}

static int child(int metal3) {
    alarm(60);
    setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    REQUIRE(g_m3 == metal3);
    NSError *error = nil; MTLCompileOptions *options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:options error:&error];
    if (!library) fprintf(stderr, "MSL compile: %s\n", error.localizedDescription.UTF8String);
    REQUIRE(library);
    NvShader *vs = make_shader(library);

    uint32_t *input = NULL;
    REQUIRE(!posix_memalign((void **)&input, 16384, POOL_BYTES));
    REQUIRE(!posix_memalign((void **)&g_out, 16384, POOL_BYTES));
    REQUIRE(!posix_memalign((void **)&g_idx, 16384, POOL_BYTES));
    for (size_t i = 0; i < POOL_BYTES / 4; i++) input[i] = MARK;
    for (int v = 0; v < NVERT; v++) for (int c = 0; c < 4; c++) input[v * 4 + c] = (uint32_t)(v * 10 + 1 + c);
    nvn_be_pool_add(input, POOL_BYTES); nvn_be_pool_add(g_out, POOL_BYTES); nvn_be_pool_add(g_idx, POOL_BYTES);
    static const uint16_t L_in[4] = {3, 0, 2, 1}, L_past[6] = {9, 0, 1, 9, 2, 5}, L_based[4] = {0, 1, 2, 4};
    uint16_t *in_range = g_idx, *past = g_idx + 64, *based = g_idx + 128;
    memcpy(in_range, L_in, sizeof L_in); memcpy(past, L_past, sizeof L_past); memcpy(based, L_based, sizeof L_based);
    nvn_dirty_add_range(g_idx, POOL_BYTES);   // as hle_nvn.c registers a game's pools: an indexed draw's index range is read only from tracked memory (ix_range)

    memset(&S, 0, sizeof S);
    S.nattr = 1; S.attr[0] = (va_st){.fmt = 0x2F, .offset = 0, .stream = 0};   // RGBA32UI into a uint4 input: Metal's own fetch, no conversion
    S.nstream = 1; S.stream[0] = (vs_st){.stride = STRIDE, .divisor = 0};
    S.vbuf[0] = (NVNbufferRange){.address = (uint64_t)(uintptr_t)input, .size = NVERT * STRIDE};
    g_ps = tf_pso(vs); REQUIRE(g_ps);   // its vertex descriptor is built from the attribute state above

    // Indexed, inside the range: read as bound, no limited copy made
    uint64_t n0 = g_vlim_n;
    run(vs, in_range, 4, 0, 0, 0);
    for (int v = 0; v < 4; v++) expect(v, 1, "indexed inside");
    VERIFY(g_vlim_n == n0, "an indexed draw inside the range binds the stream as it is (limited copies %llu → %llu)", (unsigned long long)n0, (unsigned long long)g_vlim_n);
    // Indexed past the range (the #1783 shape: a fan around a far index)
    run(vs, past, 6, 0, 0, 0);
    expect(0, 1, "indexed past"); expect(1, 1, "indexed past"); expect(2, 1, "indexed past"); expect(5, 0, "indexed past"); expect(9, 0, "indexed past");
    VERIFY(g_vlim_n == n0 + 1, "an indexed draw past the range binds one limited copy (%llu)", (unsigned long long)(g_vlim_n - n0));
    // Indexed with a base vertex: vertex ids 2, 3, 4, 6
    run(vs, based, 4, 2, 0, 0);
    expect(2, 1, "base vertex 2"); expect(3, 1, "base vertex 2"); expect(4, 0, "base vertex 2"); expect(6, 0, "base vertex 2");
    // Direct draw past the range: vertices 2 .. 6
    run(vs, NULL, 0, 0, 2, 5);
    expect(2, 1, "direct 2..6"); expect(3, 1, "direct 2..6"); for (int v = 4; v <= 6; v++) expect(v, 0, "direct 2..6");
    // Direct draw that starts past the range: every vertex reads 0
    run(vs, NULL, 0, 0, 5, 3);
    for (int v = 5; v <= 7; v++) expect(v, 0, "direct 5..7");
    // Direct draw inside the range: no limited copy
    n0 = g_vlim_n;
    run(vs, NULL, 0, 0, 0, 4);
    for (int v = 0; v < 4; v++) expect(v, 1, "direct inside");
    VERIFY(g_vlim_n == n0, "a direct draw inside the range binds the stream as it is");
    unsigned mark_bad = 0; for (size_t i = NVERT * 4; i < POOL_BYTES / 4; i++) mark_bad += input[i] != MARK;
    VERIFY(!mark_bad, "the pool's bytes after the range are untouched (%u changed)", mark_bad);
    nvn_be_drain();
    printf("%s t_nvn_vbuf_limit Metal %d: %u checks, %u failures (production bind_vbufs)\n", failures ? "FAIL" : "PASS", metal3 ? 3 : 4, checks, failures);
    return failures != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--child")) return child(atoi(argv[2]));
        REQUIRE(argc == 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("FAIL t_nvn_vbuf_limit: no Metal device\n"); return 1; }
        int os26 = 0; if (@available(macOS 26.0, *)) os26 = 1;
        if (!os26 || ![device supportsFamily:MTLGPUFamilyMetal4]) { printf("FAIL t_nvn_vbuf_limit: Metal 4 family required for both backend runs\n"); return 1; }
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
        printf("%s t_nvn_vbuf_limit: %u backend processes failed\n", bad ? "✗" : "✓", bad);
        return bad != 0;
    }
}
