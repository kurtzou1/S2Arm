// 包内能力清单单测（10-28 全能力出包）：造临时 s2a_caps.tsv，核 widen / fps60 设环境变量、优先级（启动环境 > 清单 > 缺省；用户设置先于清单写，见 t_ios_settings）
#include "../src/native.h"
#include <unistd.h>
#include <sys/wait.h>

#include "../include/caps.h"

static int fails;
static void expect(const char *what, const char *want, const char *got) {
    printf("%s 期望 %s → 真结果 %s\n", what, want ? want : "(null)", got ? got : "(null)");
    int match = (want && got && !strcmp(want, got)) || (!want && !got);
    if (!match) fails++;
}

int main(void) {
    char T[] = "/tmp/t_caps_XXXXXX";
    if (!mkdtemp(T)) return 1;

    // ① 没有 s2a_caps.tsv：不报错，不设任何环境变量
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_WIDEN_CAPS"); unsetenv("S2A_FPS60");
                s2a_caps_apply(T); _exit(getenv("S2A_WIDEN_CAPS") || getenv("S2A_FPS60") ? 1 : 0); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("① 无 s2a_caps.tsv：不设环境变量", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }

    // 造 s2a_caps.tsv：widen 1、fps60 1
    char path[700]; snprintf(path, sizeof path, "%s/s2a_caps.tsv", T);
    FILE *f = fopen(path, "w");
    fprintf(f, "# 单测能力清单\nwiden\t1\t# 有表\nfps60\t1\t# 有表\ngyro\t0\t# 无（测试行）\n");
    fclose(f);

    // ② widen / fps60 都未设：都设上
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_WIDEN_CAPS"); unsetenv("S2A_FPS60");
                s2a_caps_apply(T);
                _exit((getenv("S2A_WIDEN_CAPS") && !strcmp(getenv("S2A_WIDEN_CAPS"), "1") && !getenv("S2A_FPS60")) ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("② widen / fps60 都未设：清单设 widen 1；fps60 不替玩家设（11-11：60 帧玩家手动开）", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }

    // ③ S2A_WIDEN_CAPS 已设 0（启动环境）：不覆盖
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { setenv("S2A_WIDEN_CAPS", "0", 1); unsetenv("S2A_FPS60");
                s2a_caps_apply(T);
                _exit((getenv("S2A_WIDEN_CAPS") && !strcmp(getenv("S2A_WIDEN_CAPS"), "0") && !getenv("S2A_FPS60")) ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("③ S2A_WIDEN_CAPS=0（启动环境）：不覆盖，fps60 不替玩家设", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }

    // ④ S2A_FPS60 已设 0（启动环境）：不覆盖
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_WIDEN_CAPS"); setenv("S2A_FPS60", "0", 1);
                s2a_caps_apply(T);
                _exit((getenv("S2A_WIDEN_CAPS") && !strcmp(getenv("S2A_WIDEN_CAPS"), "1") &&
                       getenv("S2A_FPS60") && !strcmp(getenv("S2A_FPS60"), "0")) ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("④ S2A_FPS60=0（启动环境）：不覆盖，widen 设 1", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }

    // ⑤ 清单里 widen 0（能力不可用）：不设环境变量
    f = fopen(path, "w");
    fprintf(f, "widen\t0\t# 无表\nfps60\t1\t# 有表\n");
    fclose(f);
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_WIDEN_CAPS"); unsetenv("S2A_FPS60");
                s2a_caps_apply(T);
                _exit((getenv("S2A_WIDEN_CAPS") && !strcmp(getenv("S2A_WIDEN_CAPS"), "0") && !getenv("S2A_FPS60")) ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("⑤ 清单 widen 0（发布包未验）：S2A_WIDEN_CAPS 设 0（显式关），fps60 不替玩家设", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }

    // ⑥ 清单 fps60 0（发布包未验）：S2A_FPS60 设 0；已设 S2A_FPS60=1（启动环境）时不覆盖
    f = fopen(path, "w"); fprintf(f, "fps60\t0\t# 未验：无登记\n"); fclose(f);
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_FPS60"); s2a_caps_apply(T); _exit(!getenv("S2A_FPS60") ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("⑥ 清单 fps60 0：不写 S2A_FPS60（没设 = 原帧率）", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { setenv("S2A_FPS60", "1", 1); s2a_caps_apply(T); _exit(!strcmp(getenv("S2A_FPS60"), "1") ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("⑥ 启动环境 S2A_FPS60=1 时清单的 0 不覆盖", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }
    // ⑥b 11-11 速度已验证正确的款保留默认 60（清单原因认来源）：期望手算——fps.tsv / A/B 绿 / 原生 60 → 玩家没设时设 1；
    //   全引擎档 / Unity·UE 推导 → 不设；玩家显式 0 → 照旧 0；社区帧率补丁（11-13）→ 设 1、玩家显式 0 照旧 0
    { static const struct { const char *why, *env, *want; } vc[] = {
          {"默认开：来源 fps.tsv", NULL, "1"},
          {"默认开：来源 逻辑速度同局 A/B 绿（ρ 1.01、q 0.99，放开出图间隔）", NULL, "1"},
          {"默认开：来源 游戏原生 60 帧", NULL, "1"},
          {"默认开：来源 引擎通用：放开出图间隔（全引擎，同局 A/B 判红才关）", NULL, NULL},
          {"默认开：来源 引擎通用第一层（Unity / UE4 放开交换间隔）", NULL, NULL},
          {"默认开：来源 fps.tsv", "0", "0"},
          {"默认开：来源 社区帧率补丁", NULL, "1"},          // 11-13：社区帧率补丁版本精确命中才进得了包，默认开
          {"默认开：来源 社区帧率补丁", "0", "0"}};          // 玩家关了照旧关
      for (int i = 0; i < 8; i++) {
          f = fopen(path, "w"); fprintf(f, "fps60\t1\t# %s\n", vc[i].why); fclose(f);
          fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
          if (!p) { if (vc[i].env) setenv("S2A_FPS60", vc[i].env, 1); else unsetenv("S2A_FPS60");
                    s2a_caps_apply(T); const char *x = getenv("S2A_FPS60");
                    _exit(vc[i].want ? (x && !strcmp(x, vc[i].want) ? 0 : 1) : (!x ? 0 : 1)); }
          int ws = 0; waitpid(p, &ws, 0); char what[256];
          snprintf(what, sizeof what, "⑥b 清单 fps60 1「%s」、玩家%s → S2A_FPS60 %s", vc[i].why, vc[i].env ? "设了 0" : "没设", vc[i].want ? vc[i].want : "不设");
          expect(what, "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); } }
    f = fopen(path, "w"); fprintf(f, "fps60\t0\t# 未验：无登记\n"); fclose(f);
    // ⑦ 普查同局 A/B 模式（S2A_FPS_AB=1）：清单 fps60 0 → 另设 DM_PRESENT_INTERVAL=display（平时由 fps.c 降档原因 3 退回原帧率）；没开 A/B 模式、或已显式给了间隔都不设
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_FPS60"); unsetenv("DM_PRESENT_INTERVAL"); setenv("S2A_FPS_AB", "1", 1); s2a_caps_apply(T);
                _exit(getenv("DM_PRESENT_INTERVAL") && !strcmp(getenv("DM_PRESENT_INTERVAL"), "display") ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("⑦ 普查 A/B 模式、清单 fps60 0：设 DM_PRESENT_INTERVAL=display", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_FPS60"); unsetenv("DM_PRESENT_INTERVAL"); unsetenv("S2A_FPS_AB"); s2a_caps_apply(T); _exit(getenv("DM_PRESENT_INTERVAL") ? 1 : 0); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("⑦ 没开 A/B 模式：不设 DM_PRESENT_INTERVAL", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }
    { pid_t p = fork(); if (p < 0) return 1;
      if (!p) { unsetenv("S2A_FPS60"); setenv("DM_PRESENT_INTERVAL", "game", 1); setenv("S2A_FPS_AB", "1", 1); s2a_caps_apply(T); _exit(!strcmp(getenv("DM_PRESENT_INTERVAL"), "game") ? 0 : 1); }
      int ws = 0; waitpid(p, &ws, 0);
      expect("⑦ 已显式给 DM_PRESENT_INTERVAL=game：不覆盖", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩"); }

    // ⑧ 补丁（runtime/src/patch.c，补丁包 v1 第 12.7 节优先级：启动环境 / 设置 > [except] > 补丁 [caps] > 包内清单）：
    //   包内清单 widen 0、fps60 1；补丁 [except] fps60 0、[caps] fps60 1 + widen 1。期望（手算）：S2A_WIDEN_CAPS=1（补丁压过包内 0）、S2A_FPS60=0（例外压过补丁 [caps] 与包内 1）；
    //   ⑨ 启动环境已给 S2A_FPS60=1 → 照旧 1（玩家 / 调度最高）；⑩ 补丁程序号不对 → 整份不用 → 包内清单 widen 0、fps60 1
    f = fopen(path, "w"); fprintf(f, "widen\t0\t# 包内\nfps60\t1\t# 包内\n"); fclose(f);
    { uint8_t npdm[0x98] = {0}; memcpy(npdm, "META", 4); uint32_t ao = 0x80; memcpy(npdm + 0x70, &ao, 4); memcpy(npdm + 0x80, "ACI0", 4);
      uint64_t pid = 0x0100000000000042ull; memcpy(npdm + 0x90, &pid, 8);
      char q[800]; snprintf(q, sizeof q, "%s/main.npdm", T); FILE *g = fopen(q, "wb"); fwrite(npdm, 1, sizeof npdm, g); fclose(g);
      snprintf(q, sizeof q, "mkdir -p %s/patches/0100000000000042", T); (void)!system(q);
      snprintf(q, sizeof q, "%s/patches", T); setenv("S2A_PATCH_DIR", q, 1); }
    for (int k = 0; k < 3; k++) {
        char q[800]; snprintf(q, sizeof q, "%s/patches/0100000000000042/patch.tsv", T); FILE *g = fopen(q, "w");
        fprintf(g, "schema\t1\nprogram\t%s\nbuild\tabc\n[caps]\nfps60\t1\t# 补丁开\nwiden\t1\t# 补丁开\n[except]\nfps60\t0\t# 强信号：逻辑速度红\n", k == 2 ? "0100000000000099" : "0100000000000042"); fclose(g);
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) { unsetenv("S2A_WIDEN_CAPS"); if (k == 1) setenv("S2A_FPS60", "1", 1); else unsetenv("S2A_FPS60");
                  s2a_caps_apply(T); const char *w = getenv("S2A_WIDEN_CAPS"), *x = getenv("S2A_FPS60");
                  const char *ww = k == 2 ? "0" : "1";   // 60 帧：清单 / 补丁都不再写 S2A_FPS60（11-11），只有 ⑨ 启动环境给的 1 留着
                  _exit(w && !strcmp(w, ww) && (k == 1 ? x && !strcmp(x, "1") : !x) ? 0 : 1); }
        int ws = 0; waitpid(p, &ws, 0);
        expect(k == 0 ? "⑧ 补丁：满屏取补丁 1、60 帧不写环境（玩家手动开）" : k == 1 ? "⑨ 启动环境 S2A_FPS60=1 照旧" : "⑩ 补丁程序号不对：整份不用、按包内清单（60 帧不写环境）",
               "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩");
    }
    // ⑪ 补丁 [fps]：写成 <补丁目录>/.fps.tsv（首行 build = 补丁编写构建），S2A_FPS_TABLE 指过去；⑫ 启动环境已给 S2A_FPS_TABLE → 不覆盖
    for (int k = 0; k < 2; k++) {
        char q[800]; snprintf(q, sizeof q, "%s/patches/0100000000000042/patch.tsv", T); FILE *g = fopen(q, "w");
        fprintf(g, "schema\t1\nprogram\t0100000000000042\nbuild\tabcdef0123456789\n[fps]\nw main 0x1028 i32 61 *0x8*0x10\n"); fclose(g);
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) { if (k) setenv("S2A_FPS_TABLE", "/x/given.tsv", 1); else unsetenv("S2A_FPS_TABLE");
                  s2a_caps_apply(T); const char *e = getenv("S2A_FPS_TABLE"); char want[800]; snprintf(want, sizeof want, "%s/patches/0100000000000042/.fps.tsv", T);
                  if (k) _exit(e && !strcmp(e, "/x/given.tsv") ? 0 : 1);
                  FILE *r = e ? fopen(e, "r") : NULL; char b[256] = ""; if (r) { (void)!fread(b, 1, sizeof b - 1, r); fclose(r); }
                  _exit(e && !strcmp(e, want) && !strcmp(b, "build\tabcdef0123456789\nw main 0x1028 i32 61 *0x8*0x10\n") ? 0 : 1); }
        int ws = 0; waitpid(p, &ws, 0);
        expect(k ? "⑫ 启动环境已给 S2A_FPS_TABLE：补丁 [fps] 不覆盖" : "⑪ 补丁 [fps]：写 .fps.tsv 并设 S2A_FPS_TABLE", "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩");
    }
    { char q[800]; snprintf(q, sizeof q, "rm -rf %s/patches %s/main.npdm", T, T); (void)!system(q); unsetenv("S2A_PATCH_DIR"); }

    // ⑬ 放开出图间隔的来源（s2a_fps60_display_source）：期望手算——60 帧开着时，清单 fps60_display 1（全引擎档 / A/B 绿）放开；
    //   已验证款 fps.tsv / 游戏原生 60 帧不由清单放开（帧率表自带 present display 行 / 跟随游戏间隔）；未验证款（全引擎档无标记行、强信号 0）玩家开了就放开；60 帧关一律不放开
    { static const struct { const char *name, *caps; const char *env; int want; } dc[] = {
          {"fps.tsv", "fps60\t1\t# 默认开：来源 fps.tsv\n", NULL, 0},
          {"原生 60", "fps60\t1\t# 默认开：来源 游戏原生 60 帧\n", NULL, 0},
          {"原生 60", "fps60\t1\t# 默认开：来源 游戏原生 60 帧\n", "1", 0},
          {"A/B 绿 + 放开行", "fps60\t1\t# 默认开：来源 逻辑速度同局 A/B 绿（ρ 1.0）\nfps60_display\t1\t# A/B\n", NULL, 1},
          {"全引擎档 + 放开行", "fps60\t1\t# 默认开：来源 引擎通用：放开出图间隔\nfps60_display\t1\t# 全引擎\n", NULL, 0},
          {"全引擎档 + 放开行", "fps60\t1\t# 默认开：来源 引擎通用：放开出图间隔\nfps60_display\t1\t# 全引擎\n", "1", 1},
          {"Unity·UE 第一层", "fps60\t1\t# 默认开：来源 引擎通用第一层（Unity / UE4 放开交换间隔）\n", "1", 1},
          {"强信号 0", "fps60\t0\t# 强信号\n", "1", 1},
          {"强信号 0", "fps60\t0\t# 强信号\n", NULL, 0},
          {"A/B 绿 + 放开行", "fps60\t1\t# 默认开：来源 逻辑速度同局 A/B 绿（ρ 1.0）\nfps60_display\t1\t# A/B\n", "0", 0} };
      for (unsigned i = 0; i < sizeof dc / sizeof *dc; i++) {
          f = fopen(path, "w"); fputs(dc[i].caps, f); fclose(f);
          pid_t p = fork(); if (p < 0) return 1;
          if (!p) { unsetenv("S2A_FPS_AB"); unsetenv("DM_PRESENT_INTERVAL"); if (dc[i].env) setenv("S2A_FPS60", dc[i].env, 1); else unsetenv("S2A_FPS60");
                    s2a_caps_apply(T); _exit(s2a_fps60_display_source() ? 1 : 0); }
          int ws = 0; waitpid(p, &ws, 0); char what[400];
          snprintf(what, sizeof what, "⑬ 放开来源：清单 %s、启动环境 S2A_FPS60=%s", dc[i].name, dc[i].env ? dc[i].env : "（没设）");
          expect(what, dc[i].want ? "1" : "0", WIFEXITED(ws) ? (WEXITSTATUS(ws) ? "1" : "0") : "崩");
      } }

    unlink(path);
    if (fails) { printf("✗ %d 项失败\n", fails); return 1; }
    printf("✓ t_caps\n");
    return 0;
}
