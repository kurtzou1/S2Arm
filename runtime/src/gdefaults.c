// 逐款测过的缺省（11-27）：说明见 runtime/include/gdefaults.h
#include "gdefaults.h"
#include "native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef S2A_GAME_DEFAULTS_NO_TABLE
#include "s2a_game_defaults.h"
#endif
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

static const char *gd_plat(void) {
#if defined(__ANDROID__) || defined(__OHOS__)
    return "android";
#elif defined(__APPLE__) && TARGET_OS_IPHONE
    return "ios";
#else
    return "mac";
#endif
}

// 本模块写进进程环境的变量（名字 + 值）：进程内重启先撤（同 caps.c 的做法，只撤值还是自己写的那份）
static struct { char name[48], val[32]; } g_set[16]; static int g_nset;
static void gd_setenv(const char *name, const char *v) {
    if (getenv(name) || setenv(name, v, 0)) return;
    if (g_nset < (int)(sizeof g_set / sizeof g_set[0])) { snprintf(g_set[g_nset].name, sizeof g_set[0].name, "%s", name); snprintf(g_set[g_nset].val, sizeof g_set[0].val, "%s", v); g_nset++; }
}
void s2a_game_defaults_reset(void) {
    for (int i = 0; i < g_nset; i++) { const char *cur = getenv(g_set[i].name); if (cur && !strcmp(cur, g_set[i].val)) unsetenv(g_set[i].name); }
    g_nset = 0;
}

int s2a_game_defaults_peek(const char *dir, char *pid, size_t pn, char *bid, size_t bn) {
    if (pn) pid[0] = 0;
    if (bn) bid[0] = 0;
    if (!dir || !dir[0]) return 0;
    char p[1200]; snprintf(p, sizeof p, "%s/main.npdm", dir);
    FILE *f = fopen(p, "rb");
    if (f) {   // 程序号：META +0x70 = ACI0 偏移，ACI0 +0x10（同 runtime/src/gfxmode.c npdm_read）
        unsigned char meta[0x80], aci[0x18]; unsigned off = 0;
        if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
            memcpy(&off, meta + 0x70, 4);
            if (!fseek(f, (long)off, SEEK_SET) && fread(aci, 1, sizeof aci, f) == sizeof aci && !memcmp(aci, "ACI0", 4)) {
                unsigned long long id; memcpy(&id, aci + 0x10, 8); snprintf(pid, pn, "%016llX", id);
            }
        }
        fclose(f);
    }
    // 构建号：随行表的「# BUILD_ID」行（同 runtime/src/loader.c read_layout_text）——nro_tables.tsv 的 @fixups main 段，没有再看 main.fixups.tsv
    char line[512]; int inside = 0;
    snprintf(p, sizeof p, "%s/nro_tables.tsv", dir);
    if ((f = fopen(p, "r"))) {
        while (fgets(line, sizeof line, f)) {
            if (line[0] == '@') { if (inside) break; line[strcspn(line, "\r\n")] = 0; inside = !strcmp(line, "@fixups\tmain"); }
            else if (inside && !strncmp(line, "# BUILD_ID\t", 11)) { snprintf(bid, bn, "%s", line + 11); break; }
        }
        fclose(f);
    }
    if (bn && !bid[0]) {
        snprintf(p, sizeof p, "%s/main.fixups.tsv", dir);
        if ((f = fopen(p, "r"))) {
            while (fgets(line, sizeof line, f)) if (!strncmp(line, "# BUILD_ID\t", 11)) { snprintf(bid, bn, "%s", line + 11); break; }
            fclose(f);
        }
    }
    if (bn) { bid[strcspn(bid, "\r\n")] = 0; for (char *c = bid; *c; c++) if (*c >= 'A' && *c <= 'F') *c = (char)(*c - 'A' + 'a'); }
    return pn && pid[0] != 0;
}

const s2a_game_default_row *s2a_game_default_find(const s2a_game_default_row *rows, const char *pid, const char *bid, const char *plat, const char *key) {
    char b16[17] = ""; snprintf(b16, sizeof b16, "%s", bid ? bid : "");
    const char *bids[2] = {b16, "*"}, *plats[2] = {plat, "*"};
    for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++)
        for (const s2a_game_default_row *r = rows; r && r->pid; r++)
            if (!strcmp(r->pid, pid) && !strcmp(r->key, key) && !strcmp(r->bid, bids[i]) && !strcmp(r->plat, plats[j])) return r;
    return NULL;
}

// 能力清单里这款有没有走直连（direct 1）、有没有 fps60 行（有帧率来源）：没有清单 = 都没有
static void gd_caps(const char *caps_dir, int *direct, int *fps60) {
    *direct = *fps60 = 0;
    if (!caps_dir || !caps_dir[0]) return;
    char p[1200], line[256], cap[64], val[64]; snprintf(p, sizeof p, "%s/s2a_caps.tsv", caps_dir);
    FILE *f = fopen(p, "r"); if (!f) return;
    while (fgets(line, sizeof line, f)) {
        char *h = strchr(line, '#'); if (h) *h = 0;
        if (sscanf(line, "%63s %63s", cap, val) != 2) continue;
        if (!strcmp(cap, "direct")) *direct = !strcmp(val, "1");
        if (!strcmp(cap, "fps60")) *fps60 = 1;
    }
    fclose(f);
}

void s2a_game_defaults_apply_rows(const s2a_game_default_row *rows, const char *module_dir, const char *caps_dir) {
    char pid[17], bid[80]; s2a_game_defaults_peek(module_dir, pid, sizeof pid, bid, sizeof bid);
    if (!pid[0]) return;
    int direct, fps60; gd_caps(caps_dir, &direct, &fps60);
    const char *plat = gd_plat(); int seen = 0;
    for (const s2a_game_default_row *r = rows; r && r->pid; r++) {
        if (strcmp(r->pid, pid) || s2a_game_default_find(rows, pid, bid, plat, r->key) != r) continue;   // 每项只用最匹配的那一行
        seen++;
        if (getenv(r->env)) { LOG("逐款缺省：%s 不用（%s 已由启动环境 / 玩家设置给成 %s）", r->key, r->env, getenv(r->env)); continue; }
        int ok = !strcmp(r->key, "quality") && (!strcmp(r->value, "MetalFX") || !strcmp(r->value, "Fsr")) ? direct   // 同 Mac community.launch_env：锐利放大要走直连
               : !strcmp(r->key, "fpsPick") && strcmp(r->value, "0") ? fps60 : 1;                                   // 具体帧率档要清单有帧率来源
        if (!ok) { LOG("【黄】逐款缺省：%s=%s 这款用不上（%s），按全局缺省", r->key, r->value, !strcmp(r->key, "quality") ? "没走直连" : "能力清单没有帧率来源"); continue; }
        gd_setenv(r->env, r->env_value);
        LOG("逐款缺省：%s=%s（%s=%s；构建号 %s、平台 %s；依据：%s）", r->key, r->value, r->env, r->env_value, r->bid, r->plat, r->why);
    }
    if (!seen) LOG("逐款缺省：本款 %s（构建号 %.16s、平台 %s）没有逐款值，按全局缺省", pid, bid[0] ? bid : "读不到", plat);
}

#ifndef S2A_GAME_DEFAULTS_NO_TABLE
void s2a_game_defaults_apply(const char *module_dir, const char *caps_dir) { s2a_game_defaults_apply_rows(s2a_game_default_rows, module_dir, caps_dir); }
const char *s2a_game_default_value(const char *module_dir, const char *key) {
    char pid[17], bid[80]; if (!s2a_game_defaults_peek(module_dir, pid, sizeof pid, bid, sizeof bid)) return NULL;
    const s2a_game_default_row *r = s2a_game_default_find(s2a_game_default_rows, pid, bid, gd_plat(), key);
    return r ? r->value : NULL;
}
#endif
