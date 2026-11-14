// 档位梯子单测（#352，runtime/src/qladder_host.c）：玩家选的运行模式（起局时环境里的 S2A_DOCKED）是上限，也是整局的运行模式。
//   期望手算：起局后 S2A_DOCKED = 玩家选的（没设 = 主机），ladder.txt 记的档不改它；梯子从头到尾不调 s2a_console_mode_set。
//   三档款（有 60 帧补丁）只按档压回 / 放开 60 帧：记的是底档（原「掌机 30」）→ 压回 30 帧、模式不变。
//   原先 ① 首次一律从主机起，iPhone 缺省掌机被盖成主机；② 记的是掌机档时起局改成掌机、局中也会切到掌机，
//   盖掉玩家选的主机（一款体育游戏两人以上要求 TV 模式，掌机下弹「请放进底座」）。
#include "native.h"
#include "s2a_qladder.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
static int g_fps, g_hold = -1, g_mode_sets;   // g_fps：这一例是不是三档款；g_hold：最后一次 s2a_fps_hold；g_mode_sets：梯子切模式的次数（应为 0）
int s2a_fps_real_source(void) { return g_fps; } int s2a_fps_enabled(void) { return g_fps; } void s2a_fps_hold(int hold) { g_hold = hold; }
int s2a_widen_game(void) { return 0; } void s2a_console_mode_set(int docked) { (void)docked; g_mode_sets++; } int s2a_console_mode(void) { return -1; }
void s2a_ios_fps_capped(int reason) { (void)reason; }
void s2a_ql_boot(void); void s2a_ql_boot_mode(int docked); void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv);
static int bad;
// 一种情况一个子进程（梯子开关、记下的档都是进程内静态）：fps = 三档款与否、env 里 S2A_DOCKED（NULL = 没设）、ladder.txt 内容（NULL = 没有）；
//   slow_s > 0：起局后再喂 slow_s 秒局内慢帧（10 帧/秒）逼梯子降档。输出「起局后 S2A_DOCKED / 最后 s2a_fps_hold（-1 = 没调）/ 梯子切模式次数」
//   app ≥ 0：走安卓入口 s2a_ql_boot_mode(app)（App 经服务请求给的运行模式，#528 第 6 项），env 只是进程里本来有没有 S2A_DOCKED，入口不该读也不该写它
static void one_at(const char *why, int fps, const char *env, int app, const char *ladder, int slow_s, const char *want) {
    char dir[] = "/tmp/t_qladder_host.XXXXXX"; if (!mkdtemp(dir)) { printf("✗ 建临时目录失败\n"); bad++; return; }
    char p[600]; snprintf(p, sizeof p, "%s/ladder.txt", dir);
    if (ladder) { FILE *f = fopen(p, "w"); fputs(ladder, f); fclose(f); } else unlink(p);
    int fd[2]; if (pipe(fd)) { bad++; return; }
    pid_t pid = fork();
    if (!pid) { close(fd[0]); setenv("S2A_DOCS", dir, 1); unsetenv("S2A_AUTOPLAY"); unsetenv("S2A_LADDER");
        if (env) setenv("S2A_DOCKED", env, 1); else unsetenv("S2A_DOCKED");
        g_fps = fps; if (app >= 0) s2a_ql_boot_mode(app); else s2a_ql_boot();
        uint64_t now = 1000000000ull; s2a_ql_host_frame(now, 0, 16666667ull, 1);
        for (int i = 0; i < slow_s * 10; i++) { now += 100000000ull; s2a_ql_host_frame(now, 1, 100000000ull, 1); }
        const char *d = getenv("S2A_DOCKED"); char out[32]; snprintf(out, sizeof out, "%s %d %d", d ? d : "-", g_hold, g_mode_sets);
        write(fd[1], out, strlen(out)); _exit(0); }
    close(fd[1]); char got[32] = {0}; read(fd[0], got, sizeof got - 1); close(fd[0]); waitpid(pid, 0, 0);
    unlink(p); rmdir(dir);
    int ok = !strcmp(got, want); bad += !ok;
    printf("%s %s：期望「模式 压帧 切模式次数」%s → 实 %s\n", ok ? "✓" : "✗", why, want, got);
}
static void one(const char *why, int fps, const char *env, const char *ladder, int slow_s, const char *want) { one_at(why, fps, env, -1, ladder, slow_s, want); }
int main(void) {
    one("iPhone 首次（设置缺省掌机）", 0, "0", NULL, 0, "0 -1 0");
    one("玩家开了主机、首次", 0, "1", NULL, 0, "1 -1 0");
    one("Mac 没选过（不设）、首次", 0, NULL, NULL, 0, "1 -1 0");
    one("玩家选主机、记下的是掌机档（旧版降过档的机器）：仍主机", 0, "1", "kind=2 tier=1\n", 0, "1 -1 0");
    one("玩家选掌机、记下的是主机档：仍掌机", 0, "0", "kind=2 tier=0\n", 0, "0 -1 0");
    one("两档款、玩家选主机、局内一直慢：梯子不跑、不切模式", 0, "1", NULL, 180, "1 -1 0");
    one("三档款、玩家选主机、首次：放开 60 帧", 1, "1", NULL, 0, "1 0 0");
    one("三档款、玩家选主机、记下的是底档：压回 30 帧、仍主机", 1, "1", "kind=1 tier=2\n", 0, "1 1 0");
    one("三档款、玩家选主机、局内一直慢：降到压回 30 帧、不切模式", 1, "1", NULL, 600, "1 1 0");
    one("三档款、玩家选掌机、首次：60 帧不受掌机限，放开 60 帧、仍掌机", 1, "0", NULL, 0, "0 0 0");
    one("三档款、玩家选掌机、局内一直慢：降到压回 30 帧、仍掌机", 1, "0", NULL, 600, "0 1 0");
    one("三档款、玩家选主机、旧版记下的是运行模式档（kind=2 tier=1）：忽略，从 60 帧起", 1, "1", "kind=2 tier=1\n", 0, "1 0 0");
    // 安卓入口：上限照 App 给的运行模式，S2A_DOCKED 原样不动（没设的仍没设，「-」）
    one_at("安卓掌机（缺省）、两档款：梯子不跑、不写 S2A_DOCKED", 0, NULL, 0, NULL, 0, "- -1 0");
    one_at("安卓掌机、三档款：60 帧不受掌机限，放开 60 帧（同 iOS 掌机）、不写 S2A_DOCKED", 1, NULL, 0, NULL, 0, "- 0 0");
    one_at("安卓主机、三档款、首次：放开 60 帧、不写 S2A_DOCKED", 1, NULL, 1, NULL, 0, "- 0 0");
    one_at("安卓主机、三档款、局内一直慢：降到压回 30 帧、记下档、不切模式", 1, NULL, 1, NULL, 600, "- 1 0");
    one_at("安卓主机、三档款、记下的是 30 帧档：压回 30 帧", 1, NULL, 1, "kind=1 tier=1\n", 0, "- 1 0");
    one_at("安卓掌机、进程里残留 S2A_DOCKED=1：按 App 的掌机、环境不改（三档款掌机也放开 60 帧）", 1, "1", 0, NULL, 0, "1 0 0");
    printf("%s t_qladder_host：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
