// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// #327 绑定取过址的池久不取址就出驻留集（nvn_mtl.m pool_age / gout_drain），以及测试开关检查（S2A_POOL_RES_CHECK，rchk_verify）。直接包含生产 nvn_mtl.m，真 Metal 设备、真提交。
//   期望按规则手算（每 60 帧查一次；久 = 600 帧，每被请出过一次翻倍；查时先让地址缓存全失效，上次查之后取过址的池不动），不由被测实现推出：
//   第 100 帧第一次查（没有上一次，什么都不请出），随后 A B C E F G 都由绑定取址（rseen = 100）；之后每 60 帧（160, 220, …）只取 B 的址
//   ① 取址后再取 A：走地址缓存（pc_get 命中），不经 pool_res
//   ② 第 700 帧查：A 不动（700 − 100 = 600，不超过 600）；第 760 帧查：A 请出（660 > 600）——reg 0、请出次数 1，仍在驻留集（等这次提交完成）
//   ③ 请出即作废旧编码：同一提交里 pc_get(A) 不再命中（地址缓存的代号变了），顶点缓冲缓存的代号也变了
//   ④ 760 那次提交完成后下一次提交开始：A 离开驻留集（res 0、不在 g_res_objects）
//   ⑤ 排除项：B（每轮都取址）、C（池缓冲上建过贴图）、E（缓冲被一个别名条目共用）、F（跨队列停放持有它的缓冲），到 760 都还是 reg 1、在驻留集
//   ⑥ 原始池表交接：G 的地址段给过游戏（nvn_be_pool_addressed）且池表开着 → 请出时转成按访问跟踪（gm 1、gseen 760），不进待放队列、仍在驻留集
//   ⑦ 测试开关检查抓得到：模拟一个没跟着作废的地址缓存（把 A 的旧条目放回线程缓存、代号对上），再取 A → 提交时报 1 条，路径是「gpu_addr_want: address cache (pc_get)」
//   ⑧ 再取址就放回：A 经 pool_res 回到 reg 1、res 1、在 g_res_objects；整局正常路径上检查报的只有 ⑦ 那 1 条
//   ⑨ 翻倍：A 第二次在第 761 帧取址后，1960 帧查不请出（1199 ≤ 1200），2020 帧查请出（1259 > 1200），请出次数 2
//   ⑩ S2A_POOL_AGE 的判法：未设 / "1" 开，"0" 关
//   反证：去掉 pool_age 里每次查都动 g_pool_gen 那行 → ③ 红（pc_get 照样命中）；去掉 pool_age_keeps 里贴图视图那条 → ⑤ C 红；
//         去掉交接那行 → ⑥ 红（G 进待放队列）；把 gout_drain 的 res_remove 挪到不等围栏 → ② 里「仍在驻留集」红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok = !!(c); failures += !ok; printf("%s ", ok ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define PSZ (1u << 20)

static int idx_of(const void *mem) { for (int i = 0; i < g_npool; i++) if (g_pools[i].key == mem && !g_pools[i].alias) return i; return -1; }
static pool_ent ent(const void *mem) { pthread_mutex_lock(&g_mu); int i = idx_of(mem); pool_ent e = i >= 0 ? g_pools[i] : (pool_ent){0}; pthread_mutex_unlock(&g_mu); return e; }
static int in_set(const void *mem) { pool_ent e = ent(mem); if (!e.buf) return 0; pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:e.buf]; pthread_mutex_unlock(&g_res_mu); return r; }
static int queued(const void *mem) { pool_ent e = ent(mem); pthread_mutex_lock(&g_mu); int q = 0; for (NSArray *o in g_gout_q) q |= o[0] == e.buf; pthread_mutex_unlock(&g_mu); return q; }
static uint64_t addr(const void *mem) { return (uint64_t)(uintptr_t)mem + 4096; }
static void take(const void *mem) { void *b; uint64_t o, g; REQUIRE(mtl_gpu_addr(addr(mem), 64, &b, &o, &g)); }
static void frame(uint64_t f) { g_present_n = f; }
static void commit(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
static uint8_t *pool(void) { uint8_t *m = NULL; REQUIRE(!posix_memalign((void **)&m, 16384, PSZ)); memset(m, 0, PSZ); nvn_be_pool_add(m, PSZ); return m; }

int main(void) {
    @autoreleasepool {
        alarm(120);
        char map[] = "/tmp/t_pool_age_map_XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); setenv("DM_NVN_SHMAP", map, 1);
        unsetenv("NXGAL_BE"); unsetenv("S2A_POOL_AGE"); unsetenv("DM_NVN_GMEM"); setenv("S2A_POOL_RES_CHECK", "1", 1);
        mtl_init();
        CHECK(rage_decide(NULL) == 1 && rage_decide("1") == 1 && rage_decide("0") == 0, "⑩ S2A_POOL_AGE：未设 %d、\"1\" %d、\"0\" %d（期望 1 1 0）", rage_decide(NULL), rage_decide("1"), rage_decide("0"));
        uint8_t *A = pool(), *B = pool(), *C = pool(), *E = pool(), *F = pool(), *G = pool();
        REQUIRE(nvn_be_pool_alias(0x10000100000ull, 64, addr(E)));
        nvn_be_pool_addressed(G, PSZ);   // G 的地址段给过游戏：原始池表列它
        (void)gmem_map();   // 池表开着（建出访问位图）
        REQUIRE(g_gbits);
        frame(100); nvn_be_sub_begin();
        take(A); take(B); take(C); take(E); take(F); take(G);
        pool_tview_note(ent(C).buf);
        xq_buf_hold_add((__bridge void *)ent(F).buf);
        const pc_ent *hit = pc_get(addr(A), 64);
        CHECK(hit && hit->buf == ent(A).buf && ent(A).rseen == 100, "① 再取 A：地址缓存命中 %d、rseen %llu（期望命中、100）", hit != NULL, (unsigned long long)ent(A).rseen);
        commit();
        for (uint64_t f = 160; f <= 700; f += 60) { frame(f); nvn_be_sub_begin(); take(B); commit(); }
        CHECK(ent(A).reg == 1 && ent(A).rout == 0, "② 第 700 帧查后：A reg %d、请出次数 %d（期望 1、0：600 不超过 600）", ent(A).reg, ent(A).rout);
        uint64_t vgen0 = atomic_load(&g_pool_gen);
        frame(760); nvn_be_sub_begin();
        { pool_ent a = ent(A);
          CHECK(a.reg == 0 && a.rout == 1 && a.res == 1 && in_set(A) && queued(A) && a.gfence == g_fence + 1,
                "② 第 760 帧查：A reg %d、请出次数 %d、res %d、在驻留集 %d、待放 %d、围栏 = 本次提交 %d（期望 0 1 1 1 1 1）", a.reg, a.rout, a.res, in_set(A), queued(A), a.gfence == g_fence + 1); }
        CHECK(pc_get(addr(A), 64) == NULL && atomic_load(&g_pool_gen) != vgen0, "③ 请出后同一提交里：pc_get(A) 命中 %d（期望 0），池代号变了 %d（期望 1：顶点缓冲缓存同代号作废）",
              pc_get(addr(A), 64) != NULL, atomic_load(&g_pool_gen) != vgen0);
        CHECK(ent(B).reg && in_set(B) && ent(C).reg && in_set(C) && ent(E).reg && in_set(E) && ent(F).reg && in_set(F),
              "⑤ 排除项到 760 仍 reg 1、在驻留集：B %d/%d、C %d/%d、E %d/%d、F %d/%d", ent(B).reg, in_set(B), ent(C).reg, in_set(C), ent(E).reg, in_set(E), ent(F).reg, in_set(F));
        { pool_ent g = ent(G);
          CHECK(g.reg == 0 && g.gm == 1 && g.gseen == 760 && !queued(G) && in_set(G), "⑥ G 交给原始池表：reg %d、gm %d、gseen %llu、待放 %d、在驻留集 %d（期望 0 1 760 0 1）",
                g.reg, g.gm, (unsigned long long)g.gseen, queued(G), in_set(G)); }
        commit();
        frame(761); nvn_be_sub_begin();
        CHECK(ent(A).res == 0 && !in_set(A) && !queued(A), "④ 760 那次提交完成后：A res %d、在驻留集 %d、待放 %d（期望 0 0 0）", ent(A).res, in_set(A), queued(A));
        // ⑦ 模拟没跟着作废的地址缓存：A 的旧条目放回线程缓存、代号对上
        { pthread_mutex_lock(&g_mu); int i = idx_of(A); pool_ent a = g_pools[i]; pthread_mutex_unlock(&g_mu);
          uint64_t gen = atomic_load(&g_pool_gen); if (t_pc.gen != gen) { memset(t_pc.r, 0, sizeof t_pc.r); memset(t_pc.e, 0, sizeof t_pc.e); t_pc.gen = gen; }
          pc_ent c = {a.lo, a.hi, a.base, a.buf, a.gpu, a.host, pool_end(i)}; t_pc.e[pc_slot(addr(A))] = c; }
        uint64_t bad0 = g_rchk_bad; take(A); uint64_t got = rchk_verify();
        CHECK(got == 1 && g_rchk_last && !strcmp(g_rchk_last, "gpu_addr_want: address cache (pc_get)") && ent(A).res == 0,
              "⑦ 旧缓存给出已出驻留集的 A：检查报 %llu 条（期望 1），路径「%s」", (unsigned long long)got, g_rchk_last ? g_rchk_last : "");
        atomic_fetch_add(&g_pool_gen, 1);   // 收起模拟的旧缓存
        take(A);
        CHECK(ent(A).reg == 1 && ent(A).res == 1 && in_set(A) && ent(A).rseen == 761, "⑧ 再取址：A reg %d、res %d、在驻留集 %d、rseen %llu（期望 1 1 1 761）", ent(A).reg, ent(A).res, in_set(A), (unsigned long long)ent(A).rseen);
        commit();
        uint64_t reg1960 = 9;
        for (uint64_t f = 820; f <= 2020; f += 60) { frame(f); nvn_be_sub_begin(); if (f == 1960) reg1960 = ent(A).reg; commit(); }
        CHECK(reg1960 == 1 && ent(A).reg == 0 && ent(A).rout == 2, "⑨ 翻倍：1960 帧 A reg %llu（期望 1：1199 ≤ 1200），2020 帧 reg %d、请出次数 %d（期望 0、2）", (unsigned long long)reg1960, ent(A).reg, ent(A).rout);
        CHECK(g_rchk_bad - bad0 == 1, "⑧ 整局检查报的只有 ⑦ 那 1 条：%llu", (unsigned long long)(g_rchk_bad - bad0));
        xq_buf_hold_del((__bridge void *)ent(F).buf);
        unlink(map);
    }
    printf("%s t_nvn_pool_age：%u 项，%u 项失败\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
}
