// 切后台瘦身只标能从客体内存重建的打包贴图（nvn_mtl.m nvn_be_background_purge，11-16 D-CZCW：纯 GPU 贴图被系统清掉后找不回，回前台花屏）。
// 期望按语义手写，不由被测实现推出：驻留集里三张私有贴图——A 打包贴图（NvPkg，CPU 内容）、B 纯 GPU 贴图、C GPU 写过的打包贴图（NvPkg 带 pgpu）
//   ① 进后台：A 变可清除（Volatile），B、C 保持不可清除（NonVolatile）
//   ② 回前台：A 标回不可清除
//   ③ 存即时快照（nvn_snap.inc snap_dump_pkg）不存显卡内容已经没了的打包贴图：存了就是一张全零，恢复时写回并标成「GPU 写过」，再也不从客体内存重传。
//     前置：再建一张打包贴图 D（CPU 内容）→ 进后台（A、D 标成可清除）→ 模拟系统在后台清掉 A → 回前台（A 登记重传 g_up_lost，D 标回不可清除）
//     ③a 被清掉、登记了重传还没取用的 A 不进文件；内容在的 C、D 进文件
//     ③b 进后台标成可清除、内容还在的 D 照存，存完仍是可清除（瘦身不因存快照失效）
//     ③c 进后台后被系统清掉、还没回前台的 D 不进文件，状态仍是已清（回前台标回时照常登记重传）
//   ④ 恢复时认「记录内容全零」（修好之前存的快照里被清掉的贴图是这样存的，snap_put_pkg 不写回）：全零 → 是；任何一个字节非零（首、中、尾）→ 不是；空 → 不是
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static int pkg_has(const char *path, uint64_t ser, int *n) {   // gfx_pkg.bin 里有没有这个序号的记录；*n = 记录总数
    FILE *f = fopen(path, "rb"); REQUIRE(f); fr_tex_hd hd; int hit = 0; *n = 0;
    while (fread(&hd, sizeof hd, 1, f) == 1) { (*n)++; hit |= hd.ser == ser; REQUIRE(fr_skip_tex(f, &hd)); }
    fclose(f); return hit;
}
static const char *st(MTLPurgeableState s) { return s == MTLPurgeableStateNonVolatile ? "不可清除" : s == MTLPurgeableStateVolatile ? "可清除" : s == MTLPurgeableStateEmpty ? "已清" : "?"; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60); unsetenv("S2A_BG_PURGE");
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> A = [g_dev newTextureWithDescriptor:d], B = [g_dev newTextureWithDescriptor:d], C = [g_dev newTextureWithDescriptor:d]; REQUIRE(A && B && C);
    res_add(A); res_add(B); res_add(C); res_commit();
    NvPkg *pa = [NvPkg new]; pa->tex = A;
    NvPkg *pc = [NvPkg new]; pc->tex = C; pc->pgpu = calloc(1, sizeof(uint64_t));
    uint64_t ka = 101, kb = 102, kc = 103;
    pthread_mutex_lock(&g_smu); hm_put_id(&g_by_serial, &ka, pa); hm_put_id(&g_by_serial, &kb, B); hm_put_id(&g_by_serial, &kc, pc); pthread_mutex_unlock(&g_smu);
    nvn_be_background_purge(1);
    MTLPurgeableState sa = [A setPurgeableState:MTLPurgeableStateKeepCurrent], sb = [B setPurgeableState:MTLPurgeableStateKeepCurrent], sc = [C setPurgeableState:MTLPurgeableStateKeepCurrent];
    CHECK(sa == MTLPurgeableStateVolatile && sb == MTLPurgeableStateNonVolatile && sc == MTLPurgeableStateNonVolatile,
          "① 进后台：打包贴图 A %s（应可清除）、纯 GPU 贴图 B %s、GPU 写过的打包贴图 C %s（都应不可清除）", st(sa), st(sb), st(sc));
    nvn_be_background_purge(0);
    sa = [A setPurgeableState:MTLPurgeableStateKeepCurrent];
    CHECK(sa == MTLPurgeableStateNonVolatile || sa == MTLPurgeableStateEmpty, "② 回前台：A %s（应标回不可清除；被系统清了则为已清、登记重传）", st(sa));
    // ③ 前置：建 D → 进后台 → 系统清掉 A → 回前台，A 登记重传、还没取用；C（GPU 写过）、D 内容都在
    id<MTLTexture> D = [g_dev newTextureWithDescriptor:d]; REQUIRE(D);
    res_add(D); res_commit();
    NvPkg *pd = [NvPkg new]; pd->tex = D; uint64_t kd = 104;
    pthread_mutex_lock(&g_smu); hm_put_id(&g_by_serial, &kd, pd); pthread_mutex_unlock(&g_smu);
    nvn_be_background_purge(1);
    REQUIRE([A setPurgeableState:MTLPurgeableStateKeepCurrent] == MTLPurgeableStateVolatile && [D setPurgeableState:MTLPurgeableStateKeepCurrent] == MTLPurgeableStateVolatile);
    [A setPurgeableState:MTLPurgeableStateEmpty];                 // 模拟后台里系统清掉 A
    nvn_be_background_purge(0);
    os_unfair_lock_lock(&g_up_lost_lk); int a_lost = g_up_lost && [g_up_lost containsObject:A]; os_unfair_lock_unlock(&g_up_lost_lk);
    REQUIRE(a_lost && [D setPurgeableState:MTLPurgeableStateKeepCurrent] == MTLPurgeableStateNonVolatile);
    char path[256]; snprintf(path, sizeof path, "%s/t_nvn_bg_purge_pkg.%d.bin", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
    uint64_t pb = 0; int n = 0, np = snap_dump_pkg(path, &pb);
    int ha = pkg_has(path, ka, &n), hc = pkg_has(path, kc, &n), hd3 = pkg_has(path, kd, &n);
    CHECK(np == 2 && n == 2 && !ha && hc && hd3, "③a 存快照：存下 %d 张、文件里 %d 条（都应 2）；被清掉的 A %s文件（应不在）、C %s、D %s（都应在）", np, n, ha ? "在" : "不在", hc ? "在" : "不在", hd3 ? "在" : "不在");
    nvn_be_background_purge(1);                                   // 进后台：D 可清除、内容还在
    np = snap_dump_pkg(path, &pb); hd3 = pkg_has(path, kd, &n); MTLPurgeableState sd = [D setPurgeableState:MTLPurgeableStateKeepCurrent];
    CHECK(np == 2 && hd3 && sd == MTLPurgeableStateVolatile, "③b 进后台后存快照：存下 %d 张（应 2），D %s文件（应在），存完 D %s（应仍可清除）", np, hd3 ? "在" : "不在", st(sd));
    [D setPurgeableState:MTLPurgeableStateEmpty];                 // 模拟后台里系统清掉 D
    np = snap_dump_pkg(path, &pb); hd3 = pkg_has(path, kd, &n); hc = pkg_has(path, kc, &n); sd = [D setPurgeableState:MTLPurgeableStateKeepCurrent];
    nvn_be_background_purge(0);
    os_unfair_lock_lock(&g_up_lost_lk); int d_lost = g_up_lost && [g_up_lost containsObject:D]; os_unfair_lock_unlock(&g_up_lost_lk);
    CHECK(np == 1 && !hd3 && hc && sd == MTLPurgeableStateEmpty && d_lost, "③c 后台里被清掉后存快照：存下 %d 张（应 1），D %s文件（应不在）、C %s（应在）；存完 D %s（应仍是已清），回前台%s登记重传（应登记）", np, hd3 ? "在" : "不在", hc ? "在" : "不在", st(sd), d_lost ? "已" : "未");
    unlink(path);
    { uint8_t *z = calloc(1, 70000); int all = snap_all_zero(z, 70000), none = snap_all_zero(z, 0);
      z[0] = 1; int h = snap_all_zero(z, 70000); z[0] = 0; z[35000] = 1; int m = snap_all_zero(z, 70000); z[35000] = 0; z[69999] = 1; int e = snap_all_zero(z, 70000); free(z);
      CHECK(all == 1 && !none && !h && !m && !e, "④ 记录内容全零的判断：全零 %d（应 1）、空 %d、首 / 中 / 尾字节非零 %d / %d / %d（都应 0）", all, none, h, m, e); }
    printf("%s t_nvn_bg_purge：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
