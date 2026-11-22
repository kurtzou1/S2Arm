// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 会话销毁（nvn_be_shutdown_session：进程内重启、游戏进行中按快照恢复）后新局不读旧局的表：「进程内重启后的状态 = 冷启动的状态」。直接包含生产 nvn_mtl.m。
//   判据（期望值手写）：
//   ① 原始池表的访问位（gslot：位 → 池表下标）：640 MB 大池 + 5 个 1 MB 小池，查出一块并加长、给块（池表第 5 条）一个访问位并置上 → 会话销毁 →
//      发出过的访问位 0 个、位图首字 0；大池记录 0、池表 0 条；新会话重新登记再查，查到的宿主地址 = 游戏地址
//   ② 其余按旧局地址 / 序号 / 栅栏号记的表：跨队列挂起记录、共享存储最后写入、幽灵淘汰环、贴图 GPU 写入归属、GPU 写过的池（代数要变大）、宽屏贴图表与 3D 标记、
//      兜底池键、条件渲染已提交记录、写过报告的地址、见过的事件地址各放一条 → 会话销毁后全空
//   反证：去掉 nvn_session.inc 清访问位那一行 → ① 访问位一项红（1 个、位图首字 0x1）；去掉清其余表的几行 → ② 五项红（各表仍是 1 条）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define MB (1ull << 20)
static int entries_of(const void *mem) { int n=0; pthread_mutex_lock(&g_mu); for (int i=0;i<g_npool;i++) n+=g_pools[i].key==mem; pthread_mutex_unlock(&g_mu); return n; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    alarm(60); unsetenv("NXGAL_BE"); unsetenv("DM_NVN_POOL_CHUNKS");
    mtl_init();
    const uint64_t SZ = 640 * MB; uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 16*MB, SZ));   // 16 MB 对齐：块按绝对地址取步长
    nvn_be_pool_add(mem, SZ);
    // ① 先让池表里排在块前面的条目多几条，块的下标（5）在新会话的池表里越界
    uint8_t *sm[5]; for (int i = 0; i < 5; i++) { REQUIRE(!posix_memalign((void **)&sm[i], 16384, 1*MB)); nvn_be_pool_add(sm[i], 1*MB); }
    void *bp0; uint64_t off0, gpu0; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 100*MB + 16, 64, &bp0, &off0, &gpu0));
    REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 100*MB, 40*MB, &bp0, &off0, &gpu0));   // 加长，替下 1 个旧缓冲（销毁时要走放旧缓冲那一支）
    if (!g_gbits) g_gbits = [g_dev newBufferWithLength:GSLOT_MAX / 8 options:MTLResourceStorageModeShared];
    int bit;
    { pthread_mutex_lock(&g_mu); int nb = g_nbig, ne = g_npool, nold = (int)g_big[0].old.count; bit = gslot_get(5);   // 块在池表第 5 条：给它一个访问位并置上（照着色器访问过）
      if (bit >= 0) atomic_fetch_or((_Atomic uint32_t *)g_gbits.contents + (bit >> 5), 1u << (bit & 31)); pthread_mutex_unlock(&g_mu);
      CHECK(nb==1 && entries_of(mem)==1 && ne==6 && nold==1 && bit==0,"① 销毁前：大池记录 %d、块条目 %d、池表 %d 条、旧缓冲 %d、访问位 %d（期望 1、1、6、1、0）",nb,entries_of(mem),ne,nold,bit); }
    // ② 其余按旧局地址 / 序号 / 栅栏号记的表：各放一条，销毁后都要是空的
    uint64_t ser = 77, pk = 0x7100200000ull, ra = 0x7100300000ull; alias_key ak; memset(&ak, 0, sizeof ak); ak.off = 0x1000;
    pthread_mutex_lock(&g_smu); nvn_hm_put(&g_alias_wrote, &ak, (void *)(uintptr_t)901); pthread_mutex_unlock(&g_smu);
    g_ghost_ring[0] = ser; g_ghost_next = 1;
    pthread_mutex_lock(&g_gpw_mu); nvn_hm_put(&g_gpw_own, &ser, calloc(1, sizeof(gpw_own))); pthread_mutex_unlock(&g_gpw_mu);
    pthread_mutex_lock(&g_pool_gpuw_mu); nvn_hm_put(&g_pool_gpuw, &pk, (void *)1); pthread_mutex_unlock(&g_pool_gpuw_mu);
    uint64_t gen0 = atomic_load(&g_pool_gpuw_gen);
    g_wd_t[0].ser = ser; g_wd_t[0].w = 64; g_wd_s3d[0] = ser; g_wd_s3d_n = 1;
    g_adhoc_key[0] = (uintptr_t)pk; g_adhoc_nk = 1;
    g_rc_submitted = calloc(1, sizeof *g_rc_submitted); g_rc_scap = 1; g_rc_submitted[0].addr = ra; g_rc_submitted[0].fence = 900; g_rc_nsubmitted = 1;
    rc_occ_add(ra); g_eva[0].val = (volatile uint32_t *)(uintptr_t)ra; g_neva = 1;
    memset(&g_xq[0], 0, sizeof g_xq[0]); g_xq[0].q = (void *)(uintptr_t)pk; g_xq[0].cont = malloc(16); g_nxq = 1;
    REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    { pthread_mutex_lock(&g_smu); int aw = nvn_hm_get(&g_alias_wrote, &ak) != NULL; pthread_mutex_unlock(&g_smu);
      pthread_mutex_lock(&g_gpw_mu); int go = nvn_hm_get(&g_gpw_own, &ser) != NULL; pthread_mutex_unlock(&g_gpw_mu);
      pthread_mutex_lock(&g_pool_gpuw_mu); int pg = nvn_hm_get(&g_pool_gpuw, &pk) != NULL; pthread_mutex_unlock(&g_pool_gpuw_mu);
      CHECK(g_nxq==0,"② 跨队列挂起记录 %d 条（期望 0）",g_nxq);
      CHECK(!aw && !g_ghost_ring[0] && !go,"② 共享存储最后写入 %d、幽灵淘汰环首格 %llu、贴图 GPU 写入归属 %d（期望都 0）",aw,(unsigned long long)g_ghost_ring[0],go);
      CHECK(!pg && atomic_load(&g_pool_gpuw_gen) > gen0,"② GPU 写过的池 %d、代数 %llu → %llu（期望 0、变大）",pg,(unsigned long long)gen0,(unsigned long long)atomic_load(&g_pool_gpuw_gen));
      CHECK(!g_wd_t[0].ser && !g_wd_s3d[0] && !g_wd_s3d_n,"② 宽屏贴图表首格序号 %llu、3D 标记 %d 条（期望都 0）",(unsigned long long)g_wd_t[0].ser,g_wd_s3d_n);
      CHECK(!g_adhoc_nk && !g_rc_nsubmitted && !g_rc_on && !g_neva,"② 兜底池键 %d、条件渲染已提交 %u、写过报告的地址 %u、见过的事件地址 %d（期望都 0）",g_adhoc_nk,g_rc_nsubmitted,g_rc_on,g_neva); }
    g_nxq = 0; g_adhoc_nk = 0;   // 没清时（负对照）不带进后面的登记
    { pthread_mutex_lock(&g_mu); int nb = g_nbig, ne = g_npool, hi = g_gslot_hi; uint32_t w0 = *(uint32_t *)g_gbits.contents; pthread_mutex_unlock(&g_mu);
      CHECK(nb==0 && ne==0,"① 会话销毁后：大池记录 %d、池表 %d 条（期望都 0）",nb,ne);
      CHECK(hi==0 && w0==0,"① 会话销毁后：发出过的访问位 %d 个、位图首字 %#x（期望都 0；留着的话新局 gmem_scan 按旧下标取池表）",hi,w0); }
    pthread_mutex_lock(&g_mu); g_gslot_hi = g_gslot_nfree = 0; memset(g_gbits.contents, 0, GSLOT_MAX / 8); pthread_mutex_unlock(&g_mu);   // 没清时（负对照）到此为止：再查会按旧下标读新池表外的内存
    nvn_be_pool_add(mem, SZ);
    void *bp1; uint64_t off1, gpu1; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 100*MB + 16, 64, &bp1, &off1, &gpu1));
    uint8_t *host = (uint8_t *)((__bridge id<MTLBuffer>)bp1).contents + off1;
    { pthread_mutex_lock(&g_mu); int nb = g_nbig; pthread_mutex_unlock(&g_mu);
      CHECK(nb==1 && entries_of(mem)==1 && host==mem + 100*MB + 16,"① 新会话重新登记后再查：大池记录 %d、块条目 %d、查到的宿主地址 %s（期望 1、1、对）",nb,entries_of(mem),host==mem + 100*MB + 16?"对":"不对"); }
    printf("%s t_nvn_session_reset：%u 项，%u 项失败\n",failures?"✗":"✓",checks,failures);
    return failures!=0;
} }
