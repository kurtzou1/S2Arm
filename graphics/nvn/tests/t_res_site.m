// 驻留集按来源统计（#1117：只被驻留集留着的纹理一局涨约 2 GB，要分清是哪一处加进去后再没移出）。含生产 nvn_mtl.m 源码（同 t_link_restart.m 写法）。期望按语义手写：
//   来源 9001 加 3 个各 64 KB 的缓冲、来源 9002 加 1 个 64 KB；移出 9001 的 2 个、9002 的 1 个 →
//   本窗口：removed 3（line 9001: 2, line 9002: 1）；当前驻留：只剩 line 9001 一个（9002 归零不列）
//   下一窗口什么都不做：removed 0、当前驻留仍是 line 9001: 1（当前驻留不随窗口清零）
//   负对照：旧实现这一行没有「resident by adding line」与按来源的移出
//   按个数（大池长局 64 KB 小共享缓冲涨了看不出来源）：再由来源 9003 加 6 个 4 KB、来源 9004 加 1 个 8 MB → 按字节的前四 9004 排第一；
//     按个数的前四 9003（6 个）排第一（初始化时别处也加了几个对象，其余名次不断言）。负对照：旧实现没有「most objects by adding line」
#ifndef RES_SITE_SOURCE
#define RES_SITE_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include RES_SITE_SOURCE

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)

int main(void) { @autoreleasepool {
    setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
    mtl_init();
    char s[1400]; nvn_be_res_stats(s, sizeof s);   // 清掉初始化时的窗口
    id<MTLBuffer> a[3], b;
    for (int i = 0; i < 3; i++) { a[i] = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared]; res_add_at(a[i], 9001); }
    b = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared]; res_add_at(b, 9002);
    res_remove(a[0]); res_remove(a[1]); res_remove(b);
    nvn_be_res_stats(s, sizeof s); printf("%s\n", s);
    CHECK(strstr(s, "removed 3 (line 9001: 2, line 9002: 1)") != NULL, "本窗口按来源移出：9001 两个、9002 一个");
    char want[128]; snprintf(want, sizeof want, "line 9001: 1, %.0f MB", a[2].allocatedSize / 1048576.0);
    CHECK(strstr(s, "resident by adding line (") && strstr(s, want) && !strstr(strstr(s, "resident by adding line"), "line 9002"), "当前驻留：只剩来源 9001 一个（%s），9002 已归零不列", want);
    nvn_be_res_stats(s, sizeof s); printf("%s\n", s);
    CHECK(strstr(s, "removed 0 ()") && strstr(s, want), "下一窗口：没有移出；当前驻留不随窗口清零（仍是 %s）", want);
    { id<MTLBuffer> c[6], d = [g_dev newBufferWithLength:8u << 20 options:MTLResourceStorageModeShared];
      for (int i = 0; i < 6; i++) { c[i] = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; res_add_at(c[i], 9003); }
      res_add_at(d, 9004);
      nvn_be_res_stats(s, sizeof s); printf("%s\n", s);
      const char *by_b = strstr(s, "resident by adding line ("), *by_n = strstr(s, "most objects by adding line (");
      CHECK(by_b && strncmp(by_b + strlen("resident by adding line ("), "line 9004: 1", 12) == 0, "按字节：8 MB 的来源 9004 排第一");
      CHECK(by_n && strncmp(by_n + strlen("most objects by adding line ("), "line 9003: 6", 12) == 0,
            "按个数：6 个小缓冲的来源 9003 排第一（按字节它排不到前面；旧实现没有这一段）"); }
    printf("%s t_res_site：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
} }
