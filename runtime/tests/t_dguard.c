// 直连安全网单测（runtime/include/s2a_dguard.h）：期望值按口径手写（有失败证据的连续 3 次才提示、没证据的结束不算、首帧后前台满 60 秒清零、换包从 0 数）。
// 一次「起局」= fork 一个子进程：begin / arm / frame / background / evidence 之后直接 _exit，等于这一局在那一刻没了（崩溃要先记 evidence「崩溃」，同 crash.c）。
// 每例一个空的 S2A_DOCS 临时目录。自动化局（S2A_AUTOPLAY，s2a_unattended.h）不起提示页。
#include "../src/native.h"
#include "s2a_dguard.h"
#include "s2a_unattended.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define S 1000000000ull
static int fails;
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); _exit(1); } } while (0)
#define CASE(name, body) do { char d[] = "/tmp/t_dguard.XXXXXX"; if (!mkdtemp(d)) { perror("mkdtemp"); return 1; } setenv("S2A_DOCS", d, 1); \
    pid_t p = fork(); if (!p) { body; _exit(0); } int st; waitpid(p, &st, 0); \
    if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("✗ %s\n", name); } else printf("  ✓ %s\n", name); } while (0)
// 一次起局：子进程里跑 body 后直接退出（模拟崩溃 / 被杀），父进程等它
#define LAUNCH(body) do { pid_t q = fork(); if (!q) { body; _exit(0); } int qs; waitpid(q, &qs, 0); WANT(WIFEXITED(qs) && !WEXITSTATUS(qs)); } while (0)
#define PID 0x0100152000022000ull
#define CRASHED s2a_dguard_evidence("崩溃", 0)

static int begin_count(uint64_t pid, const char *pack, const char *host) { int n = -1; int fd[2]; WANT(!pipe(fd));
    pid_t q = fork(); if (!q) { int v = s2a_dguard_begin(pid, pack, host); write(fd[1], &v, sizeof v); _exit(0); }
    waitpid(q, NULL, 0); read(fd[0], &n, sizeof n); close(fd[0]); close(fd[1]); return n; }

int main(void) {
    CASE("没有记录：此前 0 次、不要界面", {
        WANT(begin_count(PID, "aaaa", "h1") == 0); WANT(!s2a_dguard_needs_ui()); });
    CASE("首帧前崩 3 次：第 4 次起局见 3 次、要界面；诊断三行都是「首帧前」", {
        for (int i = 0; i < 3; i++) { WANT(begin_count(PID, "aaaa", "h1") == i); LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; }); }
        WANT(begin_count(PID, "aaaa", "h1") == 3); WANT(s2a_dguard_needs_ui());
        s2a_dguard_begin(PID, "aaaa", "h1"); char b[2048]; s2a_dguard_diag(b, sizeof b, "B1", "C1");
        WANT(strstr(b, "程序号 0100152000022000")); WANT(strstr(b, "出包指纹 aaaa")); WANT(strstr(b, "主程序构建号 B1")); WANT(strstr(b, "翻译链 C1"));
        WANT(strstr(b, "连续失败 3 次")); WANT(strstr(b, "第 3 次：首帧前（崩溃）")); WANT(!strstr(b, "第 4 次")); });
    CASE("只崩 2 次：不要界面", {
        for (int i = 0; i < 2; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 2); WANT(!s2a_dguard_needs_ui()); });
    CASE("没有失败证据就没了（被外部结束 / 玩家在长预热里退出）：首帧前、首帧后各 3 次都不算", {
        for (int i = 0; i < 3; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); });
        for (int i = 0; i < 3; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_frame(5 * S); });
        WANT(begin_count(PID, "aaaa", "h1") == 0); WANT(!s2a_dguard_needs_ui());
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; });   // 夹在中间的有证据的那次照算
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); });
        WANT(begin_count(PID, "aaaa", "h1") == 1); });
    CASE("前台内存告警后没了：算；告警后进后台再没了：不算", {
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_evidence("内存告警", 0); });
        WANT(begin_count(PID, "aaaa", "h1") == 1);
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_evidence("内存告警", 0); s2a_dguard_background(1, 3 * S); });
        WANT(begin_count(PID, "aaaa", "h1") == 1);
        s2a_dguard_begin(PID, "aaaa", "h1"); char b[2048]; s2a_dguard_diag(b, sizeof b, "", ""); WANT(strstr(b, "第 1 次：首帧后 0–10 秒（内存告警）")); });
    CASE("画面停住后没了：算（进后台去划掉也算）；停住后帧又走了再没了：不算", {
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_evidence("画面停住", 1); s2a_dguard_background(1, 20 * S); });
        WANT(begin_count(PID, "aaaa", "h1") == 1);
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_evidence("画面停住", 1); s2a_dguard_evidence(NULL, 1); });
        WANT(begin_count(PID, "aaaa", "h1") == 1);
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_evidence("画面停住", 1); s2a_dguard_evidence(NULL, 1); CRASHED; });   // 停住撤回后又崩：算
        WANT(begin_count(PID, "aaaa", "h1") == 2); });
    CASE("首帧后 25 秒崩：记「首帧后 20–30 秒」", {
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); for (uint64_t t = 1 * S; t <= 26 * S; t += S / 2) s2a_dguard_frame(t); CRASHED; });
        s2a_dguard_begin(PID, "aaaa", "h1"); char b[2048]; s2a_dguard_diag(b, sizeof b, "", ""); WANT(strstr(b, "第 1 次：首帧后 20–30 秒（崩溃）")); });
    CASE("首帧后前台满 60 秒：清零（之前 2 次也清掉）；59.9 秒时还没清", {
        for (int i = 0; i < 2; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; });
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(5 * S); s2a_dguard_frame(5 * S + 59 * S + S * 9 / 10); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 3);   // 59.9 秒时崩：这次也算
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(5 * S); s2a_dguard_frame(65 * S); });
        WANT(begin_count(PID, "aaaa", "h1") == 0); WANT(!s2a_dguard_needs_ui()); });
    CASE("进后台后被杀：本次不算；回前台再崩：算", {
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(1 * S); s2a_dguard_background(1, 10 * S); });
        WANT(begin_count(PID, "aaaa", "h1") == 0);
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_background(1, 2 * S); s2a_dguard_background(0, 50 * S); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 1); });
    CASE("60 秒只数前台：前台 30 秒 + 后台 100 秒 + 前台 29 秒 不清零，再 1 秒清零", {
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_frame(30 * S); s2a_dguard_background(1, 30 * S);
                 s2a_dguard_frame(100 * S); s2a_dguard_background(0, 130 * S); s2a_dguard_frame(159 * S); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 1);
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); s2a_dguard_frame(0); s2a_dguard_frame(30 * S); s2a_dguard_background(1, 30 * S);
                 s2a_dguard_background(0, 130 * S); s2a_dguard_frame(160 * S); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 0); });
    CASE("换包（出包指纹不同）或换款：从 0 数", {
        for (int i = 0; i < 3; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; });
        WANT(begin_count(PID, "bbbb", "h1") == 0); WANT(begin_count(PID + 1, "aaaa", "h1") == 0); WANT(begin_count(PID, "aaaa", "h1") == 3);
        LAUNCH({ s2a_dguard_begin(PID, "bbbb", "h1"); s2a_dguard_arm(0); CRASHED; });   // 新包起一局崩：记录改成新包的 1 次
        WANT(begin_count(PID, "bbbb", "h1") == 1); WANT(begin_count(PID, "aaaa", "h1") == 0); WANT(!s2a_dguard_needs_ui()); });
    CASE("只换宿主（提交号不同、着色器包不变）：从 0 数；同包同宿主：继续累计；旧记录没有宿主字段：从 0 数", {
        for (int i = 0; i < 3; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 3);   // 同包同宿主：累计
        WANT(begin_count(PID, "aaaa", "h2") == 0);   // 只换宿主：清零
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h2"); s2a_dguard_arm(0); CRASHED; });   // 新宿主起一局崩：记录改成新宿主的 1 次
        WANT(begin_count(PID, "aaaa", "h2") == 1); WANT(!s2a_dguard_needs_ui());
        s2a_dguard_begin(PID, "aaaa", "h2"); char b[2048]; s2a_dguard_diag(b, sizeof b, "", ""); WANT(strstr(b, "宿主提交号 h2"));
        char p[1200]; snprintf(p, sizeof p, "%s/wire/direct_guard", getenv("S2A_DOCS"));   // 旧格式（头里只有程序号 + 出包指纹）
        FILE *f = fopen(p, "w"); fprintf(f, "s2a_dguard 1 %016llX aaaa\n首帧前（崩溃）\n首帧前（崩溃）\n首帧前（崩溃）\n", (unsigned long long)PID); fclose(f);
        WANT(s2a_dguard_needs_ui());                 // 读得懂旧记录（3 次）
        WANT(begin_count(PID, "aaaa", "h1") == 0);   // 新宿主有提交号 ≠ 旧记录的「-」：从 0 数
        WANT(begin_count(PID, "aaaa", "") == 3); });  // 取不到提交号（「-」）对旧记录：照旧累计
    CASE("记录坏了（头不对）：当 0 次、不崩", {
        char p[1200]; snprintf(p, sizeof p, "%s/wire", getenv("S2A_DOCS")); mkdir(p, 0755); strlcat(p, "/direct_guard", sizeof p);
        FILE *f = fopen(p, "w"); fputs("乱码\n首帧前\n首帧前\n首帧前\n", f); fclose(f);
        WANT(!s2a_dguard_needs_ui()); WANT(begin_count(PID, "aaaa", "h1") == 0); });
    CASE("出包指纹：manifest.json 的 index_sha256 前 16 位；没有文件 / 字段 = \"-\"", {
        char d[1200]; snprintf(d, sizeof d, "%s/pk", getenv("S2A_DOCS")); mkdir(d, 0755);
        WANT(!strcmp(s2a_dguard_pack_fp(d), "-")); WANT(!strcmp(s2a_dguard_pack_fp(NULL), "-"));
        char p[1300]; snprintf(p, sizeof p, "%s/manifest.json", d); FILE *f = fopen(p, "w");
        fputs("{\"game\": \"x\", \"index_sha256\": \"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}", f); fclose(f);
        WANT(!strcmp(s2a_dguard_pack_fp(d), "0123456789abcdef"));
        f = fopen(p, "w"); fputs("{\"game\": \"x\"}", f); fclose(f); WANT(!strcmp(s2a_dguard_pack_fp(d), "-")); });
    CASE("自动化 / 开发工具起的局（S2A_AUTOPLAY 非空且不是 0）：满 3 次也不起界面；=0 / 空 / 没有照常起界面", {
        for (int i = 0; i < 3; i++) LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); s2a_dguard_arm(0); CRASHED; });
        setenv("S2A_AUTOPLAY", "1", 1); WANT(s2a_unattended()); WANT(!s2a_dguard_needs_ui());
        setenv("S2A_AUTOPLAY", "0", 1); WANT(!s2a_unattended()); WANT(s2a_dguard_needs_ui());
        setenv("S2A_AUTOPLAY", "", 1); WANT(!s2a_unattended()); WANT(s2a_dguard_needs_ui());
        unsetenv("S2A_AUTOPLAY"); WANT(!s2a_unattended()); WANT(s2a_dguard_needs_ui());
        setenv("S2A_AUTOPLAY", "0", 1); setenv("S2A_UNATTENDED", "1", 1); WANT(s2a_unattended()); WANT(!s2a_dguard_needs_ui());   // 自动玩家关、工具逐键驱动的局
        setenv("S2A_UNATTENDED", "0", 1); WANT(!s2a_unattended()); unsetenv("S2A_UNATTENDED"); unsetenv("S2A_AUTOPLAY");
        WANT(begin_count(PID, "aaaa", "h1") == 3); });   // 记录不因自动化局改动
    CASE("反证：不 arm 的起局崩了不算（计数只靠 arm 落盘）", {
        LAUNCH({ s2a_dguard_begin(PID, "aaaa", "h1"); CRASHED; });
        WANT(begin_count(PID, "aaaa", "h1") == 0); });
    if (fails) { printf("✗ t_dguard：%d 例不通\n", fails); return 1; }
    printf("✓ t_dguard：16 例全过\n"); return 0;
}
