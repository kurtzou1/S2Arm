// envfile.c 单测：链接顺序与宿主一致，构造期读配置，main 后才输出暂存日志。
// 用例：构造期生效 / 路径 / 显式环境优先 / 文件不存在 / 解析 / 有界日志。
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

// envfile.c 里 LOG → s2a_log_line；native.h 已给 static inline 实现，单测不需要额外桩

int s2a_envfile_apply_once(const char *docs);   // 诊断码（s2a_launch_ctx.h；本单测只引 native.h）

static int fails = 0;
static void ck(int ok, const char *what) { if (!ok) { printf("✗ %s\n", what); fails++; } else printf("✓ %s\n", what); }

static char early_value[64];
__attribute__((constructor(150))) static void read_early(void) {
    const char *e = getenv("T_EARLY");
    if (e) snprintf(early_value, sizeof early_value, "%s", e);
}

static void write_file(const char *dir, const char *body) {
    char p[1024]; snprintf(p, sizeof p, "%s/env.txt", dir);
    FILE *f = fopen(p, "w"); if (!f) { printf("【红】写不了 %s\n", p); exit(99); }
    fwrite(body, 1, strlen(body), f); fclose(f);
}

int main(int argc, char **argv) {
    // make 检查这是 stderr 的第一行：若构造函数直接 LOG，检查必红。
    fprintf(stderr, "T_ENVFILE_MAIN\n");
    const char *expected = getenv("T_EXPECT_EARLY");
    ck(expected && !strcmp(early_value, expected), "构造期消费者读值符合文件 / 显式环境 / 缺文件预期");
    s2a_envfile_log_flush();
    char dir[] = "/tmp/t_envfile_XXXXXX";
    if (!mkdtemp(dir)) { printf("【红】mkdtemp\n"); return 99; }
    unsetenv("T_A"); unsetenv("T_B"); unsetenv("T_C"); unsetenv("T_D"); unsetenv("T_X");

    // 1) 正常生效 + 注释 / 空行 / CRLF
    write_file(dir, "# 注释行跳过\n\nT_A=1\nT_B=hello world\r\n");
    int n = s2a_envfile_apply(dir);
    ck(n == 2, "正常生效 2 条");
    ck(getenv("T_A") && !strcmp(getenv("T_A"), "1"), "T_A=1 生效");
    ck(getenv("T_B") && !strcmp(getenv("T_B"), "hello world"), "T_B 的 CRLF 与空格原样保留");

    // 2) 显式环境变量优先：先 setenv 再 apply，必须还是 env 的值
    setenv("T_X", "env", 1);
    write_file(dir, "T_X=file\nT_C=3\n");
    n = s2a_envfile_apply(dir);
    ck(!strcmp(getenv("T_X"), "env"), "显式环境变量优先（T_X 仍是 env）");
    ck(getenv("T_C") && !strcmp(getenv("T_C"), "3"), "同文件里没被占的 T_C 照样生效");

    // 3) KEY 不合法跳过（小写 / 带减号 / 没等号）
    write_file(dir, "bad_key=1\nT-B=2\nNOEQ\nT_D=4\n");
    n = s2a_envfile_apply(dir);
    ck(getenv("bad_key") == NULL, "小写 KEY 被跳过");
    ck(getenv("T-B") == NULL, "带减号 KEY 被跳过");
    ck(getenv("T_D") && !strcmp(getenv("T_D"), "4"), "合法行照常生效");

    // 4) 文件不存在：返回 0、不改任何变量
    char empty[] = "/tmp/t_envfile_none_XXXXXX";
    if (!mkdtemp(empty)) { printf("【红】mkdtemp2\n"); return 99; }
    unsetenv("T_A");
    n = s2a_envfile_apply(empty);
    ck(n == 0, "文件不在返回 0");
    ck(getenv("T_A") == NULL, "文件不在不改任何变量");
    rmdir(empty);

    // 5) 日志不带值（11-01 审计 P2-22：host.log 进诊断包）：启动环境已给的值、env.txt 的值、没有 '=' 的整行原文都不许进日志；键名、行号、来源照记
    setenv("T_SEC_ENV", "env-secret-111", 1); unsetenv("T_SEC_NEW");
    write_file(dir, "T_SEC_ENV=file-secret-222\nT_SEC_NEW=file-secret-333\n# 注释\nsecret-line-444\n");
    s2a_envfile_apply(dir);
    ck(getenv("T_SEC_NEW") && !strcmp(getenv("T_SEC_NEW"), "file-secret-333"), "值照常生效（T_SEC_NEW）");

    // 真日志经管道检查：flush 后清空；没有新增配置的第二次 flush 不重复输出。
    int fd[2]; if (pipe(fd) || fcntl(fd[0], F_SETFL, O_NONBLOCK) < 0) return 99;
    int oldfd = g_s2a_logfd; g_s2a_logfd = fd[1];
    s2a_envfile_log_flush();
    char log[8192]; ssize_t got = read(fd[0], log, sizeof log - 1);
    ck(got > 0, "暂存诊断可输出");
    if (got > 0) {
        log[got] = 0;
        ck(strstr(log, "T_A（来源 env.txt）") != NULL, "生效诊断保留（只记键名）");
        ck(strstr(log, "T_X（env.txt 有，启动环境已给，不覆盖）") != NULL, "不覆盖诊断保留（只记键名）");
        ck(strstr(log, "T_SEC_NEW（来源 env.txt）") && strstr(log, "T_SEC_ENV（env.txt 有，启动环境已给，不覆盖）") && strstr(log, "第 4 行没有 '='，跳过"), "值不进日志：键名 / 行号照记");
        ck(!strstr(log, "secret-111") && !strstr(log, "secret-222") && !strstr(log, "secret-333") && !strstr(log, "secret-444"), "值不进日志：启动环境值 / env.txt 值 / 坏行原文都不在");
        ck(strstr(log, "KEY 不合法") && strstr(log, "没有 '='"), "非法配置诊断保留");
    }
    s2a_envfile_log_flush();
    ck(read(fd[0], log, sizeof log) == -1 && errno == EAGAIN, "重复 flush 无输出");

    // 超出 64 行仍要应用全部配置，只把未列的日志行数汇总。
    char body[2048]; size_t off = 0;
    for (int i = 0; i < 70; i++) {
        char key[32]; snprintf(key, sizeof key, "T_OVER_%d", i); unsetenv(key);
        off += (size_t)snprintf(body + off, sizeof body - off, "%s=1\n", key);
    }
    write_file(dir, body);
    ck(s2a_envfile_apply(dir) == 70, "超过日志容量仍应用 70 条配置");
    ck(getenv("T_OVER_69") && !strcmp(getenv("T_OVER_69"), "1"), "第 70 条值生效");
    s2a_envfile_log_flush();
    got = read(fd[0], log, sizeof log - 1);
    if (got > 0) log[got] = 0;
    ck(got > 0 && strstr(log, "另有 6 行未列"), "64 行日志加 6 行省略摘要");
    s2a_envfile_log_flush();
    ck(read(fd[0], log, sizeof log) == -1 && errno == EAGAIN, "省略摘要也不重复输出");
    g_s2a_logfd = oldfd; close(fd[0]); close(fd[1]);

    // 诊断码一次性文件（#1449）：只收 DM_ 开头、读一次即改名作废、没有文件什么都不做
    {
        char once[1024], used[1024]; snprintf(once, sizeof once, "%s/diag_once.txt", dir); snprintf(used, sizeof used, "%s/diag_once.used", dir);
        unsetenv("DM_T_SCAN"); unsetenv("T_NOT_DIAG");
        ck(s2a_envfile_apply_once(dir) == 0, "没有诊断码文件 → 0 项");
        FILE *f = fopen(once, "w"); fputs("DM_T_SCAN=30c6f0c2aa7c3e79:30:600\nT_NOT_DIAG=1\n", f); fclose(f);
        ck(s2a_envfile_apply_once(dir) == 1, "诊断码生效 1 项（DM_ 开头那条）");
        ck(getenv("DM_T_SCAN") && !strcmp(getenv("DM_T_SCAN"), "30c6f0c2aa7c3e79:30:600"), "DM_ 开关值原样");
        ck(!getenv("T_NOT_DIAG"), "不是 DM_ 开头的不设");
        ck(access(once, F_OK) != 0 && access(used, F_OK) == 0, "读过即改名成 diag_once.used");
        unsetenv("DM_T_SCAN");
        ck(s2a_envfile_apply_once(dir) == 0 && !getenv("DM_T_SCAN"), "下一局不再开");
        s2a_envfile_log_flush();
        unlink(used);
    }

    // 清理
    char p[1024]; snprintf(p, sizeof p, "%s/env.txt", dir); unlink(p); rmdir(dir);
    printf("envfile 单测：%s（失败 %d）\n", fails ? "红" : "全过", fails);
    if (!fails && argc > 1 && !strcmp(argv[1], "docs")) printf("✓ t_envfile\n");   // 多场景合计一组
    return fails ? 1 : 0;
}
