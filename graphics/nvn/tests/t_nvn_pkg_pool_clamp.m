// #819：按稀疏规则排布（SPARSE 标志、整页对齐）的贴图放进比它小的普通池，算出的存储越过池尾；上传时逐页哈希 / 写保护 / 去混排源按全长读，读进池后没映射的内存，iPad 上 SIGBUS。
//   tex_rd_size 把宿主读的长度截到池尾。期望手写：① 64 KB 的贴图在 8 KB 池头 → 可读 8192、页数 = 8192 跨的宿主页数、逐页哈希不碰池后的不可访问页；
//   ② 池内、没越界 → L.size；③ 没有池 → L.size；④ 贴图起点不在这个池里 → L.size。不起 GPU，只测纯函数
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/mman.h>
static unsigned checks, failures;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    size_t pg = (size_t)getpagesize();
    uint8_t *m = mmap(NULL, pg + 0x20000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);   // 一页可读写，后面全不可访问
    if (m == MAP_FAILED || mprotect(m + pg, 0x20000, PROT_NONE)) { printf("FAIL setup mmap\n"); return 1; }
    memset(m, 0x5a, pg);
    pool_t pl = {0}; pl.mem = m; pl.size = 8192;
    tex_t t = {0}; t.pool = &pl; t.mem = m; t.L.size = 65536;
    VERIFY(tex_rd_size(&t) == 8192, "① 64 KB 贴图在 8 KB 池头：可读 %llu（期望 8192）", (unsigned long long)tex_rd_size(&t));
    uint32_t n = page_count(&t); size_t hp = nvn_dirty_page_size(), want = (8192 + hp - 1) / hp;
    VERIFY(n == want, "① 页数 %u（宿主页 %zu，期望 %zu）", n, hp, want);
    uint64_t h = 0; size_t tot = 0;
    for (uint32_t k = 0; k < n; k++) { const uint8_t *lo; size_t len; page_span(&t, k, &lo, &len); h ^= span_hash(lo, len); tot += len; }
    VERIFY(tot == 8192 && h != 0, "① 逐页哈希只读池内 %zu 字节、没碰池后的不可访问页", tot);
    // ⑤ 后台首次上传的逐页哈希（ph_hash_pages，#956）按 tex_rd_size 给的长度读：同样只读池内、与提交线程逐页算的同值；
    //   按 L.size 全长给它会读进池后不可访问的页、进程直接崩（反证：传 t.L.size 即崩在这里）
    { uint64_t hb[8] = {0}, hs = 0; ph_hash_pages(t.mem, tex_rd_size(&t), n, hb);
      for (uint32_t k = 0; k < n; k++) { const uint8_t *lo; size_t len; page_span(&t, k, &lo, &len); hs ^= span_hash(lo, len) ^ hb[k]; }
      VERIFY(n <= 8 && hs == 0, "⑤ 后台逐页哈希只读池内、与提交线程算的逐页同值"); }
    t.L.size = 4096; VERIFY(tex_rd_size(&t) == 4096, "② 池内没越界：%llu（期望 4096）", (unsigned long long)tex_rd_size(&t));
    t.L.size = 65536; t.pool = NULL; VERIFY(tex_rd_size(&t) == 65536, "③ 没有池：%llu（期望 65536）", (unsigned long long)tex_rd_size(&t));
    pool_t other = {0}; uint8_t buf[64]; other.mem = buf; other.size = sizeof buf; t.pool = &other;
    VERIFY(tex_rd_size(&t) == 65536, "④ 贴图起点不在这个池里：%llu（期望 65536）", (unsigned long long)tex_rd_size(&t));
  }
    if (failures) { printf("✗ t_nvn_pkg_pool_clamp：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_pkg_pool_clamp：%u 项全过（贴图存储越过池尾时，宿主只读到池尾）\n", checks); return 0;
}
