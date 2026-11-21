// 包内顶点补齐变体（0.6.0 出包着色器全覆盖，Build.cs VpFinish；11-20 出包提速起按批合编，Build.cs VarBatches）：直接包含生产 nvn_mtl.m，调 vp_pack 从库容器载 <键>_vp。
//   夹具：两支顶点着色器（入口 main0，各写 user(locn0)），各带补齐掩码函数 dm_vp_mask_<十六进制>（同 Build.cs VpFinish 写法），掩码手写 0x2 / 0x6。
//   ① 批库：两支经生产合编源码（dsh_batch --unity var-src = Unity.VarSrc）合成一份、xcrun metal 编成一个库，两键的 <键>_vp.metallib 是同一份字节，
//      出库打包（dsh_batch --libpack pack）进 b-<链> 容器。期望（手写）：两支都载上（vp_st = SE_READY）、函数名 = s<键>_main0、掩码 = 各自手写值（不串到同批另一支）
//   ② 逐键库（旧包 / 退回逐键）：入口 main0、掩码 dm_vp_mask_<十六进制>：照旧载上、函数名 main0、掩码 = 手写值
//   反证：批库里的函数名不带键前缀时（宿主只找 main0）载不上 —— 由 ① 的「函数名 = s<键>_main0」断言兜：宿主若只认 main0，① 两支都是 SE_NONE、红。
// 用法：make native-test-nvn_vppack（末行 ✓ / ✗）
#include "../gfx/nvn/nvn_mtl.m"

static int failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "REQUIRE failed: %s (%s:%d)\n", #c, __FILE__, __LINE__); exit(2); } } while (0)
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "PASS" : "FAIL", what); failures += !ok; }

static const char *VS =
    "#include <metal_stdlib>\nusing namespace metal;\n\nstruct main0_out\n{\n    float4 gl_Position [[position]];\n    float4 m_%d [[user(locn0)]];\n};\n\n"
    "vertex main0_out main0(uint vid [[vertex_id]])\n{\n    main0_out out = {};\n    out.gl_Position = float4(float(vid) * %d.0);\n    out.m_%d = float4(1.0);\n    return out;\n}\n"
    "\nvertex float4 dm_vp_mask_%x() { return float4(0.0); }\n";
static void sh(const char *cmd) { fflush(NULL); int rc = system(cmd); if (rc) fprintf(stderr, "命令失败（%d）：%s\n", rc, cmd); REQUIRE(rc == 0); }
static NSString *fname(id f) { return f ? ((id<MTLFunction>)f).name : nil; }
static NvShader *vshader(const char *key) {
    NvShader *v = [NvShader new]; v->stage = 0; strlcpy(v->key, key, sizeof v->key); v->ventry = @"main0"; v->arg_len = 0; v->vp_st = SE_NONE; v->vp_pk = 0;
    return v;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    mtl_init();
    char tmpl[] = "/tmp/t_nvn_vppack.XXXXXX"; REQUIRE(mkdtemp(tmpl));
    const char *K1 = "ffff00000000a001", *K2 = "ffff00000000a002", *K3 = "ffff00000000a003"; const unsigned M1 = 0x2, M2 = 0x6, M3 = 0xa;
    char p[600], cmd[3000];
    for (int i = 0; i < 3; i++) {
        snprintf(p, sizeof p, "%s/v%d.metal", tmpl, i + 1); FILE *f = fopen(p, "w"); REQUIRE(f);
        fprintf(f, VS, i + 1, i + 1, i + 1, i == 0 ? M1 : i == 1 ? M2 : M3); fclose(f);
    }
    // ① 批库：K1 + K2 合编
    snprintf(cmd, sizeof cmd, "mkdir -p '%s/b/src' && python3 translator/dsh_batch.py --unity var-src '%s/b/batch.metal' %s '%s/v1.metal' %s '%s/v2.metal'"
             " && xcrun -sdk macosx metal '%s/b/batch.metal' -o '%s/b/src/%s_vp.metallib' && cp '%s/b/src/%s_vp.metallib' '%s/b/src/%s_vp.metallib'"
             " && python3 translator/dsh_batch.py --libpack pack '%s/b/src' '%s/b/b-%s' %s > /dev/null",
             tmpl, tmpl, K1, tmpl, K2, tmpl, tmpl, tmpl, K1, tmpl, K1, tmpl, K2, tmpl, tmpl, DMSH_CHAIN, DMSH_CHAIN);
    sh(cmd);
    // ② 逐键库：K3 原样编
    snprintf(cmd, sizeof cmd, "mkdir -p '%s/k/src' && xcrun -sdk macosx metal '%s/v3.metal' -o '%s/k/src/%s_vp.metallib' && python3 translator/dsh_batch.py --libpack pack '%s/k/src' '%s/k/b-%s' %s > /dev/null",
             tmpl, tmpl, tmpl, K3, tmpl, tmpl, DMSH_CHAIN, DMSH_CHAIN);
    sh(cmd);

    snprintf(p, sizeof p, "%s/b/b-%s", tmpl, DMSH_CHAIN); g_msl_dir = @(p);
    NvShader *a = vshader(K1), *b = vshader(K2);
    vp_pack(a); vp_pack(b);
    NSString *w1 = [NSString stringWithFormat:@"s%s_main0", K1], *w2 = [NSString stringWithFormat:@"s%s_main0", K2];
    char m[400];
    snprintf(m, sizeof m, "① 批库 %s：载上 %d、函数 %s（期望 %s）、掩码 %#x（期望 %#x）", K1, a->vp_st == SE_READY, fname(a->vp_main).UTF8String ?: "无", w1.UTF8String, a->vp_mask, M1);
    check(a->vp_st == SE_READY && [fname(a->vp_main) isEqualToString:w1] && a->vp_mask == M1, m);
    snprintf(m, sizeof m, "① 批库 %s：载上 %d、函数 %s（期望 %s）、掩码 %#x（期望 %#x，不串到同批另一支）", K2, b->vp_st == SE_READY, fname(b->vp_main).UTF8String ?: "无", w2.UTF8String, b->vp_mask, M2);
    check(b->vp_st == SE_READY && [fname(b->vp_main) isEqualToString:w2] && b->vp_mask == M2, m);

    // 换容器：lp_pack_get 按 g_msl_dir 开一次就缓存，② 用子进程跑
    if (!getenv("T_VPPACK_CHILD")) {
        snprintf(p, sizeof p, "%s/k/b-%s", tmpl, DMSH_CHAIN); setenv("T_VPPACK_DIR", p, 1); setenv("T_VPPACK_CHILD", "1", 1);
        fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
        if (!pid) { execl(argv[0], argv[0], "--child", (char *)NULL); _exit(127); }
        int st = 0; pid_t w; do { w = waitpid(pid, &st, 0); } while (w < 0 && errno == EINTR); REQUIRE(w == pid);
        failures += !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
        snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmpl); system(cmd);
        if (failures) { printf("✗ t_nvn_vppack：%d 项不过\n", failures); return 1; }
        printf("✓ t_nvn_vppack：批库两支按 s<键>_main0 载上、掩码各自；逐键库照旧按 main0\n"); return 0;
    }
    return 0;
}

__attribute__((constructor)) static void vppack_child(void) {
    // 子进程（② 逐键库）：在 main 之前接管，跑完退出
    const char *d = getenv("T_VPPACK_DIR"); if (!getenv("T_VPPACK_CHILD") || !d) return;
    extern char ***_NSGetArgv(void); char **av = *_NSGetArgv(); if (!av[1] || strcmp(av[1], "--child")) return;
    @autoreleasepool {
        mtl_init(); g_msl_dir = @(d);
        NvShader *c = vshader("ffff00000000a003"); vp_pack(c);
        char m[300]; snprintf(m, sizeof m, "② 逐键库：载上 %d、函数 %s（期望 main0）、掩码 %#x（期望 0xa）", c->vp_st == SE_READY, fname(c->vp_main).UTF8String ?: "无", c->vp_mask);
        check(c->vp_st == SE_READY && [fname(c->vp_main) isEqualToString:@"main0"] && c->vp_mask == 0xa, m);
        fflush(NULL); _exit(failures ? 1 : 0);
    }
}
