// 逐款测过的缺省（11-27，runtime/src/gdefaults.c）宿主端单测：夹具表 runtime/tests/data/game_defaults_fixture.tsv 由 tools/game_defaults.py emit 生成头
//   （同生产的生成路径），编进来当行表；临时模块目录造 main.npdm（程序号）+ main.fixups.tsv（构建号）+ s2a_caps.tsv。期望按夹具表手写（Mac 平台），
//   tests/game_defaults_test.py 对同一夹具按同一组期望核 Python 那份 lookup（Mac 启动设置页显示用）。
#include "gdefaults.h"
#include "s2a_game_defaults_fixture.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static int fails;
static void expect(const char *what, const char *want, const char *got) {
    int ok = (!want && !got) || (want && got && !strcmp(want, got));
    printf("%s %s 期望 %s → 真结果 %s\n", ok ? "PASS" : "FAIL", what, want ? want : "(未设)", got ? got : "(未设)");
    if (!ok) fails++;
}
static const char *E[] = {"S2A_DOCKED", "S2A_SCALING_FILTER", "S2A_FPS_PICK", "DM_NVN_BARRIER"};
static void clear(void) { for (int i = 0; i < 4; i++) unsetenv(E[i]); }
static void put(const char *dir, const char *name, const void *b, size_t n) {
    char p[600]; snprintf(p, sizeof p, "%s/%s", dir, name); FILE *f = fopen(p, "wb"); fwrite(b, 1, n, f); fclose(f);
}
// 造一个模块目录：npdm（META，+0x70 = ACI0 偏移 0x80；ACI0 +0x10 = 程序号）、main.fixups.tsv（# BUILD_ID）、能力清单
static void module(const char *dir, unsigned long long pid, const char *bid, const char *caps) {
    mkdir(dir, 0755);
    unsigned char npdm[0x80 + 0x18] = {0}; memcpy(npdm, "META", 4); unsigned off = 0x80; memcpy(npdm + 0x70, &off, 4);
    memcpy(npdm + 0x80, "ACI0", 4); memcpy(npdm + 0x80 + 0x10, &pid, 8); put(dir, "main.npdm", npdm, sizeof npdm);
    char t[200]; int n = snprintf(t, sizeof t, "# BUILD_ID\t%s\n0x0\t0\n", bid); put(dir, "main.fixups.tsv", t, (size_t)n);
    put(dir, "s2a_caps.tsv", caps, strlen(caps));
}

int main(void) {
    char T[] = "/tmp/t_game_defaults_XXXXXX"; if (!mkdtemp(T)) return 1;
    char a[600], b[600], c[600], d[600], e[600];
    snprintf(a, sizeof a, "%s/a", T); snprintf(b, sizeof b, "%s/b", T); snprintf(c, sizeof c, "%s/c", T); snprintf(d, sizeof d, "%s/d", T); snprintf(e, sizeof e, "%s/e", T);
    const char *full = "direct\t1\nfps60\t0\t# 有来源\n";
    module(a, 0x0100000000ABC000ull, "1111111111111111AAAA", full);            // 构建号只比前 16 位
    module(b, 0x0100000000ABC000ull, "2222222222222222", full);
    module(c, 0x0100000000ABC000ull, "1111111111111111", "direct\t1\n");      // 清单没有 fps60 行
    module(d, 0x0100000000DEF000ull, "1111111111111111", full);               // 表里没有的款
    module(e, 0x0100000000ABC000ull, "3333333333333333", full);

    char pid[17], bid[80]; s2a_game_defaults_peek(a, pid, sizeof pid, bid, sizeof bid);
    expect("① 读程序号", "0100000000ABC000", pid); expect("① 读构建号（小写原样）", "1111111111111111aaaa", bid);

    clear(); s2a_game_defaults_apply_rows(s2a_game_default_rows, a, a);
    expect("② * 行：档位主机 → S2A_DOCKED", "1", getenv("S2A_DOCKED"));
    expect("② 平台 mac 行优先于别的平台：画质 Nearest", "Nearest", getenv("S2A_SCALING_FILTER"));
    expect("② 帧率档 60（清单有帧率来源）", "60", getenv("S2A_FPS_PICK"));
    expect("② 引擎档案键：按游戏屏障", "game", getenv("DM_NVN_BARRIER"));
    s2a_game_defaults_reset();
    expect("② 重启前撤销：自己写的撤掉", NULL, getenv("S2A_DOCKED"));

    clear(); s2a_game_defaults_apply_rows(s2a_game_default_rows, b, b);
    expect("③ 精确构建号行盖过 * 行：掌机", "0", getenv("S2A_DOCKED"));
    s2a_game_defaults_reset();

    clear(); setenv("S2A_DOCKED", "1", 1); setenv("S2A_SCALING_FILTER", "Bilinear", 1);
    s2a_game_defaults_apply_rows(s2a_game_default_rows, b, b);
    expect("④ 玩家选过 / 启动环境给的不盖：档位", "1", getenv("S2A_DOCKED"));
    expect("④ 选回全局缺省值也不盖：画质 Bilinear", "Bilinear", getenv("S2A_SCALING_FILTER"));
    s2a_game_defaults_reset();
    expect("④ 撤销不碰别人写的", "1", getenv("S2A_DOCKED"));

    clear(); s2a_game_defaults_apply_rows(s2a_game_default_rows, c, c);
    expect("⑤ 清单没有帧率来源：帧率档不写", NULL, getenv("S2A_FPS_PICK"));
    expect("⑤ 其余照写", "1", getenv("S2A_DOCKED"));
    s2a_game_defaults_reset();

    clear(); s2a_game_defaults_apply_rows(s2a_game_default_rows, d, d);
    int none = 1; for (int i = 0; i < 4; i++) if (getenv(E[i])) none = 0;
    expect("⑥ 表里没有的款：一个都不写", "1", none ? "1" : "0");

    clear(); s2a_game_defaults_apply_rows(s2a_game_default_rows, e, e);
    expect("⑦ 没有精确行的构建号走 * 行", "1", getenv("S2A_DOCKED"));
    s2a_game_defaults_reset();

    const s2a_game_default_row *r = s2a_game_default_find(s2a_game_default_rows, "0100000000ABC000", "1111111111111111", "ios", "quality");
    expect("⑧ 查表：iOS 画质", "MetalFX", r ? r->value : NULL);
    r = s2a_game_default_find(s2a_game_default_rows, "0100000000ABC000", "1111111111111111", "android", "quality");
    expect("⑧ 查表：没有安卓行也没有 * 行 → 无", NULL, r ? r->value : NULL);

    char cmd[700]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", T); (void)system(cmd);
    if (fails) { printf("✗ t_game_defaults：%d 项不符\n", fails); return 1; }
    printf("✓ t_game_defaults：逐款缺省宿主端全过（精确构建号 > *、精确平台 > *、未设才写、杠杆不在不写、撤销只撤自己的）\n");
    return 0;
}
