// 帧录状态里原始内存池表依赖的两张表（nvn_frame_rec.inc fr_dump_state / fr_restore_state）：直接包含生产 nvn_mtl.m。
//   建三个池 A B C（各 64 KB）：A、B 记成「游戏手里有 GPU 地址」（nvn_be_pool_addressed），B 再置成为池表驻留（gm = 1）。
//   录 → 把三个池删掉、地址范围表清空（相当于新进程）→ 放。期望手写：
//   ① 放回后地址范围表恰好盖住 A、B，不盖 C
//   ② B 为池表驻留（gm = 1、在驻留集里），A、C 不是
//   ③ 旧格式文件（把末尾两节截掉）照样放得回，两张表都是空的
//   修前（录帧不存这两张表）①② 红：带原始全局内存的款回放时池表 0 段或全是冷项，着色器读回 0
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/mman.h>
#include <sys/stat.h>
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { SZ = 64 << 10 };
static void drop(void *m[3]) {   // 新进程的样子：池没了、地址范围表空
    for (int i = 0; i < 3; i++) nvn_be_pool_del(m[i]);
    pthread_mutex_lock(&g_mu); g_naddr = 0; pthread_mutex_unlock(&g_mu);
}
static pool_ent *pe(void *m) { int k = pool_find((uint64_t)(uintptr_t)m, 1); return k < 0 ? NULL : &g_pools[k]; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    void *m[3];
    for (int i = 0; i < 3; i++) { m[i] = mmap(NULL, SZ, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(m[i] != MAP_FAILED); nvn_be_pool_add(m[i], SZ); REQUIRE(pe(m[i])); }
    nvn_be_pool_addressed(m[0], SZ); nvn_be_pool_addressed(m[1], SZ);
    pthread_mutex_lock(&g_mu); { pool_ent *p = pe(m[1]); if (!p->res) { res_add(p->buf); p->res = 1; g_pool_res_n++; } p->gm = 1; res_commit(); } pthread_mutex_unlock(&g_mu);
    char path[256], old[256]; snprintf(path, sizeof path, "%s/t_nvn_frec_gmem.%d.bin", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", getpid()); snprintf(old, sizeof old, "%s.old", path);
    int na = g_naddr;   // 相邻的池范围会并成一段：按实际段数算末尾两节的长度
    REQUIRE(na == 1 || na == 2);
    REQUIRE(fr_dump_state(path));
    drop(m);
    int ntex = 0; REQUIRE(fr_restore_state(path, &ntex));
    pthread_mutex_lock(&g_mu);
    VERIFY(addr_meets((uintptr_t)m[0], (uintptr_t)m[0] + SZ) && addr_meets((uintptr_t)m[1], (uintptr_t)m[1] + SZ), "① 放回后 A、B 在地址范围表里");
    VERIFY(!addr_meets((uintptr_t)m[2], (uintptr_t)m[2] + SZ), "① C 不在地址范围表里");
    VERIFY(pe(m[1]) && pe(m[1])->gm == 1 && pe(m[1])->res == 1, "② B 为池表驻留（gm %d res %d，期望 1 1）", pe(m[1]) ? pe(m[1])->gm : -1, pe(m[1]) ? pe(m[1])->res : -1);
    VERIFY(pe(m[0]) && pe(m[0])->gm == 0 && pe(m[2]) && pe(m[2])->gm == 0, "② A、C 不为池表驻留");
    pthread_mutex_unlock(&g_mu);
    // ③ 旧格式：末尾两节 = 4 + na × 16（地址范围）+ 4 + 1 × 16（驻留池）字节
    struct stat st; REQUIRE(stat(path, &st) == 0);
    { FILE *a = fopen(path, "rb"), *b = fopen(old, "wb"); REQUIRE(a && b); size_t n = (size_t)st.st_size - (size_t)(4 + na * 16 + 4 + 16); char *buf = malloc(n); REQUIRE(buf && fread(buf, 1, n, a) == n && fwrite(buf, 1, n, b) == n); free(buf); fclose(a); fclose(b); }
    drop(m);
    VERIFY(fr_restore_state(old, &ntex), "③ 旧格式文件放得回");
    pthread_mutex_lock(&g_mu);
    VERIFY(g_naddr == 0, "③ 旧格式：地址范围表空（%d 段，期望 0）", g_naddr);
    VERIFY(pe(m[1]) && pe(m[1])->gm == 0, "③ 旧格式：B 不为池表驻留");
    pthread_mutex_unlock(&g_mu);
    unlink(path); unlink(old);
    if (failures) { printf("✗ t_nvn_frec_gmem：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_frec_gmem：%u 项全过（帧录状态：有 GPU 地址的池范围 / 为池表驻留的池 存放还原，旧格式照放）\n", checks); return 0;
} }
