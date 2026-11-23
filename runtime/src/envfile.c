// 通用启动配置文件：<Documents>/env.txt 每行一个 KEY=VALUE，读进来当环境变量用（#285 / 直连线规格 ①–⑤）。
//
// 为什么需要它：iPhone 上从桌面图标点开 App（SideStore / Xcode 装的包）带不了环境变量，
// devicectl 起局虽然能传，但玩家日常不会那样起。真机上没有通用开关通道，调试开关（NXGAL_WAIT_SITE、
// S2A_WIDEN_FULL 之类）就一个都改不动。一处实现，所有 getenv 开关都能用。
//
// 口径与 App 设置页（settings.m）一致：setenv(KEY, VALUE, 0) —— 起局时显式给的环境变量优先，
// env.txt 只补缺。文件不在 = 什么都不做，行为与没有这个功能时完全一样。
#include "native.h"   // LOG()
#include "s2a_docs.h"   // 文档根唯一取法
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// 构造期日志 fd（os.c:100）尚未就绪，先存静态缓冲；host_run 开头统一输出。
// 超出缓冲只省略日志，不停止应用配置。
enum { NOTE_MAX = 64, NOTE_SIZE = 4096 };
static char notes[NOTE_MAX][NOTE_SIZE];
static unsigned note_count, note_omitted;
__attribute__((format(printf, 1, 2))) static void note(const char *fmt, ...) {
    if (note_count == NOTE_MAX) { note_omitted++; return; }
    va_list ap; va_start(ap, fmt);
    vsnprintf(notes[note_count++], NOTE_SIZE, fmt, ap);
    va_end(ap);
}
void s2a_envfile_log_flush(void) {
    for (unsigned i = 0; i < note_count; i++) LOG("%s", notes[i]);
    if (note_omitted) LOG("启动配置：另有 %u 行未列", note_omitted);
    note_count = note_omitted = 0;
}

// 判 KEY 合法：非空、只含 [A-Z0-9_]
static int key_ok(const char *k, size_t n) {
    if (n == 0 || n > 255) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = k[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return 0;
    }
    return 1;
}

// 一行行读 KEY=VALUE 并 setenv（只补缺）。diag = 诊断码一次性文件：只收 DM_ 开头的诊断开关，日志来源写「诊断码」
static int apply_lines(FILE *f, const char *path, int diag) {
    const char *src = diag ? "诊断码" : "env.txt";
    int applied = 0, lineno = 0;
    char line[2048];
    while (fgets(line, sizeof line, f)) {
        lineno++;
        // 去行尾 CR / LF（VALUE 原样取到行尾，只去掉 \r）
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (n == 0) continue;            // 空行
        if (line[0] == '#') continue;    // 注释行
        char *eq = strchr(line, '=');
        if (!eq) { note("【红】启动配置 %s 第 %d 行没有 '='，跳过", path, lineno); continue; }   // 不带原文：整行可能就是令牌（11-01 审计 P2-22）
        const char *k = line;
        size_t klen = (size_t)(eq - line);
        const char *v = eq + 1;          // VALUE 原样到行尾
        if (!key_ok(k, klen)) {
            char kb[64]; size_t c = klen < sizeof kb - 1 ? klen : sizeof kb - 1;
            memcpy(kb, k, c); kb[c] = 0;
            note("【红】启动配置 %s 第 %d 行 KEY 不合法（只收 [A-Z0-9_]+），跳过：%s", path, lineno, kb);
            continue;
        }
        char key[256]; memcpy(key, k, klen); key[klen] = 0;
        if (diag && strncmp(key, "DM_", 3)) { note("【红】诊断码：%s 不是诊断开关（只收 DM_ 开头），跳过", key); continue; }
        // 显式环境变量优先：已经有值就不覆盖（setenv 第三参数 0 的语义），但要让他知道没生效。
        //   日志只记键名、来源与是否覆盖，不记值（11-01 审计 P2-22：host.log 进诊断包，值里会有路径、令牌）
        if (getenv(key)) { note("启动配置：%s（%s 有，启动环境已给，不覆盖）", key, src); continue; }
        if (setenv(key, v, 0) == 0) { applied++; note("启动配置：%s（来源 %s）", key, src); }
        else note("【红】启动配置：%s 设不进去（errno %d）", key, errno);
    }
    fclose(f);
    return applied;
}

// docs：Documents 目录（iOS = $HOME/Documents，Mac 可用 S2A_DOCS 指）。返回生效（真的 setenv 了）的条数。
int s2a_envfile_apply(const char *docs) {
    if (!docs || !*docs) return 0;
    char path[1100];
    snprintf(path, sizeof path, "%s/env.txt", docs);
    FILE *f = fopen(path, "r");
    if (!f) return 0;   // 文件不在：不打任何日志，行为同现状
    return apply_lines(f, path, 0);
}

// 诊断码（#1449）：电脑启动器推游戏时把玩家粘的诊断码写成 <本款文档根>/diag_once.txt（pack/jobs/diagcode.py），只管这一局。
//   先改名成 diag_once.used 再读：读到就算用掉，这局中途崩了下一局也不再开（重探针拖帧率）；改不了名就不开，免得每局都开。
//   只收 DM_ 开头的诊断开关（诊断码贴在公开帖里，不让它改别的启动行为）
int s2a_envfile_apply_once(const char *docs) {
    if (!docs || !*docs) return 0;
    char path[1100], used[1100];
    snprintf(path, sizeof path, "%s/diag_once.txt", docs);
    snprintf(used, sizeof used, "%s/diag_once.used", docs);
    if (access(path, F_OK)) return 0;   // 没有诊断码：什么都不做
    unlink(used);
    if (rename(path, used)) { note("【红】诊断码：%s 改不了名（errno %d），这一局不开", path, errno); return 0; }
    FILE *f = fopen(used, "r");
    if (!f) { note("【红】诊断码：%s 打不开（errno %d），这一局不开", used, errno); return 0; }
    int n = apply_lines(f, used, 1);
    note("诊断码：本局开 %d 项诊断开关，已用掉（下一局不再开）", n);
    return n;
}

// 必须早于日志 fd（100）、地址窗口（101）和分配采样（200）读取开关。
// 构造期这份是进程级（容器的 Documents）：多款容器里每款自己的 env.txt 在启动上下文冻结后由 launchctx.c 补读（s2a_launch_ctx_apply_game_env）
static char g_proc_docs[1024];
const char *s2a_envfile_process_docs(void) { return g_proc_docs; }
__attribute__((constructor(99))) static void envfile_boot(void) {
    s2a_docs_root(g_proc_docs, sizeof g_proc_docs);
    s2a_envfile_apply(g_proc_docs);
}
