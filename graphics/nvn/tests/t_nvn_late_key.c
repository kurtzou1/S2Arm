// D-WQPH（11-15）：SetShaders 时代码区还不在已登记内存池里的 Switch 1 着色器，到首用（prog_key）才算出键，也要交给首遇现编登记（dm_shader_miss）。
//   修前这类键不进待编表，dm_shader_miss_late 对 Switch 1 只认待编表，不在库里的整支丢、不现编（Mac 奥日2 1.2.0 每局 18–136 支）。
//   判据借 DM_NVN_SHDUMP：dm_shader_miss 认出阶段就把 <键>.ctl / .code 存进这个目录（dsh_miss.inc dsh_dump），所以「目录里出现这个键的 .ctl」= 登记入口被调到了。
//   ① SetShaders：代码区是普通堆内存（不在任何内存池）→ 不取键、目录为空；② 首用 prog_key → 算出键、目录里出现 <键>.ctl；③ 再取一次键不重复登记（文件只写一次，不再改）。
//   ⑥ 11-21 局内用到的着色器（shader_seen.tsv，DM_PSO_USER 同目录）：首用记一行「键<TAB>阶段」；同程序再取、另一个程序用同一份着色器都不重复记；没算出键（全零）的不记。
#include "nvn_protos.h"
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int prog_key(const void *p, unsigned stage, uint8_t key[8]);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

static int count_files(const char *dir) { int n = 0; DIR *d = opendir(dir); struct dirent *e; if (!d) return -1; while ((e = readdir(d))) if (e->d_name[0] != '.') n++; closedir(d); return n; }

int main(void) {
    char dir[] = "/tmp/t_nvn_late_key.XXXXXX"; if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("DM_NVN_SHDUMP", dir, 1); unsetenv("DM_MSL_FALLBACK");
    char sdir[] = "/tmp/t_nvn_seen.XXXXXX"; if (!mkdtemp(sdir)) { perror("mkdtemp"); return 1; }
    char pso[600], seenp[600]; snprintf(pso, sizeof pso, "%s/pso_user.tsv", sdir); snprintf(seenp, sizeof seenp, "%s/shader_seen.tsv", sdir);
    setenv("DM_PSO_USER", pso, 1);
    NVNT_nvnProgramSetShaders set = (NVNT_nvnProgramSetShaders)h_nvnBootstrapLoader("nvnProgramSetShaders");
    if (!set) { printf("✗ 找不到 nvnProgramSetShaders\n"); return 1; }

    // Switch 1 控制段：自报长度 0x880（+0x20）、代码长 64（+0x704）；代码区首字不是图形头 → 计算阶段（dsh_stage）
    uint8_t *ctl = calloc(1, 0x880), *code = calloc(1, 64);
    uint32_t nctl = 0x880, ncode = 64; memcpy(ctl + 0x20, &nctl, 4); memcpy(ctl + 0x704, &ncode, 4);
    for (int i = 0; i < 64; i++) code[i] = (uint8_t)(i * 7 + 1);
    union { NVNprogram p; char raw[256]; } prog; memset(&prog, 0, sizeof prog);
    NVNshaderData sd = { (NVNbufferAddress)(uintptr_t)code, ctl };

    // ① SetShaders：代码区不在内存池 → 不取键、不登记
    CHECK(set(&prog.p, 1, &sd), "SetShaders 返回失败");
    CHECK(count_files(dir) == 0, "① SetShaders 时代码区不在内存池，不该登记，目录里却有 %d 个文件", count_files(dir));

    // ② 首用取键 → 登记（目录里出现 <键>.ctl / .code）
    uint8_t key[8]; CHECK(prog_key(&prog.p, 0, key) == 1, "② prog_key 没给出键");
    char hx[17]; for (int i = 0; i < 8; i++) snprintf(hx + 2 * i, 3, "%02x", key[i]);
    char path[512]; struct stat st;
    snprintf(path, sizeof path, "%s/%s.ctl", dir, hx); int have_ctl = !stat(path, &st) && st.st_size == 0x880;
    snprintf(path, sizeof path, "%s/%s.code", dir, hx); int have_code = !stat(path, &st) && st.st_size == 64;
    CHECK(have_ctl && have_code, "② 首用算出键 %s 后没交给首遇现编登记（%s.ctl %s、.code %s）", hx, hx, have_ctl ? "有" : "无", have_code ? "有" : "无");

    // ③ 再取一次：键已算过，不再登记（目录文件数不变）
    int before = count_files(dir); uint8_t key2[8]; prog_key(&prog.p, 0, key2);
    CHECK(!memcmp(key, key2, 8) && count_files(dir) == before, "③ 第二次取键应与第一次相同且不再登记（文件 %d → %d）", before, count_files(dir));

    // ④ 11-16 D-XDQS：代码区地址是空缓冲地址加偏移（0x100），原先首用取键时宿主直接读 0x100 段错误。期望：不崩、键全零（上层按「不在着色器表」报）、不登记
    {
        union { NVNprogram p; char raw[256]; } bad_prog; memset(&bad_prog, 0, sizeof bad_prog);
        NVNshaderData bsd = { (NVNbufferAddress)0x100, ctl };
        CHECK(set(&bad_prog.p, 1, &bsd), "④ SetShaders 返回失败");
        int before4 = count_files(dir); uint8_t key4[8];
        static const uint8_t z8[8]; prog_key(&bad_prog.p, 0, key4);
        CHECK(!memcmp(key4, z8, 8) && count_files(dir) == before4, "④ 代码区 0x100：键应全零（不出键）、不登记（文件 %d → %d）", before4, count_files(dir));
    }

    // ⑤ 11-17 #713 D-ZBQS：代码区是一页 PROT_NONE（游戏窗口里游戏没映射的地址，不在任何虚拟池），原先「不在虚拟池 = 可读」、首用取键时 CC_SHA256 读它 SIGBUS。
    //   期望：不崩、键全零、不登记。改前：本进程在这里崩（单测直接死，判红）
    {
        void *hole = mmap(NULL, 0x10000, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        CHECK(hole != MAP_FAILED, "⑤ 占不可访问页失败");
        union { NVNprogram p; char raw[256]; } hp; memset(&hp, 0, sizeof hp);
        NVNshaderData hsd = { (NVNbufferAddress)(uintptr_t)hole, ctl };
        CHECK(set(&hp.p, 1, &hsd), "⑤ SetShaders 返回失败");
        int before5 = count_files(dir); uint8_t key5[8] = {1}; static const uint8_t z8b[8];
        prog_key(&hp.p, 0, key5);
        CHECK(!memcmp(key5, z8b, 8) && count_files(dir) == before5, "⑤ 代码区是不可访问页：键应全零（不出键）、不登记（文件 %d → %d）", before5, count_files(dir));
        munmap(hole, 0x10000);
    }

    // ⑥ shader_seen.tsv：此时只该有 ② 那一支（③ 同程序再取、④ ⑤ 全零键都不记）；另一个程序用同一份着色器也不再记
    {
        union { NVNprogram p; char raw[256]; } p2; memset(&p2, 0, sizeof p2);
        CHECK(set(&p2.p, 1, &sd), "⑥ SetShaders 返回失败");
        uint8_t k6[8]; prog_key(&p2.p, 0, k6);
        char want[64]; snprintf(want, sizeof want, "%s\t0\n", hx);
        char got[256] = ""; FILE *f = fopen(seenp, "r"); size_t n = f ? fread(got, 1, sizeof got - 1, f) : 0; if (f) fclose(f); got[n] = 0;
        CHECK(!strcmp(got, want), "⑥ shader_seen.tsv 应只有一行「%s<TAB>0」，实际 %zu 字节：%s", hx, n, got);
    }

    char cmd[600]; snprintf(cmd, sizeof cmd, "rm -rf '%s' '%s'", dir, sdir); system(cmd);
    printf("%s t_nvn_late_key：SetShaders 时代码区不在内存池的着色器，首用取键时交给首遇现编登记 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
