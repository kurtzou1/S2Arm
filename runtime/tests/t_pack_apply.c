// 解包单测：用系统 tar 以执行器同样的参数（pax、中文长路径、子目录、空文件）打包，s2a_pack_apply 解到临时 Documents，逐字节核对；
// 再核：.incoming 里的 tar 解完即删、.applied = manifest 的 index_sha256、unpack.log 一行无「返回 -」；坏包（路径含 ..）判失败且日志带「返回 -3」。
#include "../src/native.h"
#include "s2a_launch_ctx.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <signal.h>
#include "s2a_docs.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#if defined(__linux__)
#define TAR_OPTIONS "--format pax --no-xattrs --blocking-factor=1"
#define TAR_RENAME "--transform='s,^a.txt,x/../../逃逸.txt,'"
#else
#define TAR_OPTIONS "--format pax --no-xattrs --no-mac-metadata"
#define TAR_RENAME "-s ',^a.txt,x/../../逃逸.txt,'"
#endif
int s2a_pack_apply(const char *docs); const char *s2a_pack_apply_failure(void);
int s2a_untar(const char *tar, const char *root, unsigned *nf, uint64_t *nb); int s2a_pack_check(const char *root, char *first, size_t n);
int s2a_import_docs_pick(const s2a_launch_ctx *c, int game_data_env, const char *proc_docs, char *out, size_t n); int s2a_import_state_game(const char *proc_docs, const char *gid);
int s2a_import_state_game_quick(const char *proc_docs, const char *gid);
int s2a_game_install_state(const char *proc_docs, const char *gid);
int s2a_img_scan(const char *proc_docs); const char *s2a_img_scan_failure(void);
int s2a_img_scan_source(const char *proc_docs, const char *dir, const char *srcid, const char *skip); int s2a_pack_source_forget(const char *proc_docs, const char *srcid);
int s2a_pack_migrate_one(const char *docs); int s2a_pack_migrate(const char *proc_docs, int *failed);
const char *s2a_install_code(int rc, int err, int truncated, int from_img); const char *s2a_pack_apply_code(void); const char *s2a_img_scan_code(void);
extern void (*s2a_pack_apply_phase)(int phase, uint64_t done, uint64_t total);
static uint64_t g_ph[4][2]; static int g_phn[4]; static void phase(int ph, uint64_t d, uint64_t t) { if (ph > 0 && ph < 4) { g_ph[ph][0] = d; g_ph[ph][1] = t; g_phn[ph]++; } } int s2a_import_state(const char *docs); void s2a_pack_help_detail(int st, int again, char *d, size_t n); extern void (*s2a_pack_apply_progress)(int done, int total);
// 与 runtime/src/pack_apply.c 同（闸门下一步与指纹记录）
enum { S2A_GATE_READY, S2A_GATE_IMPORT, S2A_GATE_WAIT, S2A_GATE_STALLED, S2A_GATE_NONE, S2A_GATE_BROKEN };
struct s2a_gate_watch { int n; uint64_t fp; time_t changed; };
int s2a_import_transferring(const char *root, char *why, size_t n); int s2a_import_decide(const char *docs, struct s2a_gate_watch *w, time_t now, char *why, size_t n);
static int g_pd = -1, g_pt = -1, g_pcalls; static void prog(int d, int t) { g_pd = d; g_pt = t; g_pcalls++; }
uint64_t now_ns(void) { return 0; }
static int g_ui_zh = 1; int s2a_ui_zh(void) { return g_ui_zh; }   // 界面语言（s2a_ui_text.h）：盖过 pack_apply.c 的弱缺省，⑨b 切英文
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
static int sh(const char *c) { return system(c); }
// 造一个 512 字节的 ustar 头（name / size / 类型 / 校验和），给手写的异常 pax 头用
static void tar_hdr(uint8_t h[512], const char *name, unsigned size, char type) {
    memset(h, 0, 512); snprintf((char *)h, 100, "%s", name); memcpy(h + 100, "0000644", 8); memcpy(h + 108, "0000000", 8); memcpy(h + 116, "0000000", 8);
    snprintf((char *)h + 124, 12, "%011o", size); memcpy(h + 136, "00000000000", 12); h[156] = (uint8_t)type; memcpy(h + 257, "ustar", 6); memcpy(h + 263, "00", 2);
    unsigned sum = 0; for (int i = 0; i < 512; i++) sum += (i >= 148 && i < 156) ? ' ' : h[i]; snprintf((char *)h + 148, 8, "%06o", sum); h[155] = ' ';
}
// 在子进程里跑 s2a_untar：返回「返回 -N」或「崩溃（信号 N）」，崩了不拖死整个单测
static void untar_child(const char *tar, const char *root, char *out, size_t n) {
    pid_t pid = fork(); if (pid == 0) { unsigned nf = 0; uint64_t nb = 0; int r = s2a_untar(tar, root, &nf, &nb); _exit(r < 0 ? -r : 0); }
    int st = 0; waitpid(pid, &st, 0);
    if (WIFSIGNALED(st)) snprintf(out, n, "崩溃（信号 %d）", WTERMSIG(st)); else snprintf(out, n, "返回 -%d", WEXITSTATUS(st));
}
static int same(const char *a, const char *b) { char c[4096]; snprintf(c, sizeof c, "cmp -s '%s' '%s'", a, b); return sh(c) == 0; }
// 程序描述（#1059）：解包核对要求 <资源包根>/exefs/main.npdm 是非空普通文件，且要列进 index.tsv（不列会被清旧文件删掉）。
//   夹具统一放 4 字节「npdm」；NPDM_ROW 是对应的 index.tsv 行（写在 shell printf 的格式串里）
#define NPDM_ROW "exefs/main.npdm\\t4\\tx\\n"
static void put_npdm(const char *root) { char c[2400]; snprintf(c, sizeof c, "mkdir -p '%s/exefs' && printf npdm > '%s/exefs/main.npdm'", root, root); CHECK(sh(c) == 0, "放程序描述失败：%s", root); }
// Original synthetic tar headers; no game or user data. Lengths and expected rc are hand-written.
static void tar_entry(FILE *f, const char *name, char type, const char *data, size_t n) {
    uint8_t h[512], zero[512] = {0}; tar_hdr(h, name, (unsigned)n, type);
    CHECK(fwrite(h, 1, sizeof h, f) == sizeof h, "合成 tar 头写失败");
    CHECK(fwrite(data, 1, n, f) == n, "合成 tar 内容写失败");
    size_t pad = (512 - n % 512) % 512;
    CHECK(fwrite(zero, 1, pad, f) == pad, "合成 tar 补齐失败");
}
static void boundary_cases(const char *T) {
    const char *records[] = {"7 path\n12 path=abc\n", "12 path=abc\n"};
    char path[1024], root[1024]; snprintf(root, sizeof root, "%s/pax", T); CHECK(!mkdir(root, 0755), "建 pax 目录失败");
    for (unsigned i = 0; i < 2; i++) {
        snprintf(path, sizeof path, "%s/pax-%u.tar", T, i); FILE *f = fopen(path, "wb");
        CHECK(f != NULL, "造 pax 文件失败"); if (!f) continue;
        tar_entry(f, "PaxHeader", 'x', records[i], strlen(records[i]));
        tar_entry(f, "original", '0', "ok", 2); char zero[1024] = {0}; fwrite(zero, 1, sizeof zero, f); fclose(f);
        fflush(NULL); pid_t pid = fork(); CHECK(pid >= 0, "pax fork 失败");
        if (!pid) { unsigned nf = 0; uint64_t nb = 0; int rc = s2a_untar(path, root, &nf, &nb);
            _exit(i == 0 ? (rc == -2 && nf == 0 && nb == 0 ? 0 : 1) : (rc == 0 && nf == 1 && nb == 2 ? 0 : 1)); }
        if (pid > 0) { int status = 0; CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "pax case %u: 期望 %s 且不崩，wait status=%d", i, i == 0 ? "-2/0文件/0字节" : "0/1文件/2字节", status); }
    }
    // v0.3.1：认不出的条目类型（软链 '2'、带数据的 'Z'）跳过、后面的文件照解：期望 rc 0、2 个文件 / 4 字节、没有链接落地
    { char lt[1024], lr[1024]; snprintf(lt, sizeof lt, "%s/odd.tar", T); snprintf(lr, sizeof lr, "%s/odd", T); CHECK(!mkdir(lr, 0755), "建 odd 目录失败");
      FILE *o = fopen(lt, "wb"); CHECK(o != NULL, "造 odd 包失败");
      if (o) { tar_entry(o, "a.bin", '0', "ab", 2); tar_entry(o, "link", '2', "", 0); tar_entry(o, "weird", 'Z', "xxxxxxxxxx", 10);
               tar_entry(o, "b.bin", '0', "cd", 2); char z[1024] = {0}; fwrite(z, 1, sizeof z, o); fclose(o);
               unsigned nf = 0; uint64_t nb = 0; int rc = s2a_untar(lt, lr, &nf, &nb); char q[1100]; struct stat qs;
               CHECK(rc == 0 && nf == 2 && nb == 4, "认不出的条目：期望 rc 0 / 2 文件 / 4 字节，实际 %d / %u / %llu", rc, nf, (unsigned long long)nb);
               snprintf(q, sizeof q, "%s/b.bin", lr); CHECK(!stat(q, &qs) && qs.st_size == 2, "认不出的条目之后的 b.bin 没解出来");
               snprintf(q, sizeof q, "%s/link", lr); CHECK(lstat(q, &qs) != 0, "认不出的软链条目不该落地");
               snprintf(q, sizeof q, "%s/weird", lr); CHECK(lstat(q, &qs) != 0, "认不出的条目不该落地"); } }
    snprintf(path, sizeof path, "%s/abc", root); FILE *f = fopen(path, "rb"); char value[3] = {0};
    CHECK(f && fread(value, 1, 2, f) == 2 && !strcmp(value, "ok"), "合法 pax path 内容不符"); if (f) fclose(f);
}

unsigned s2a_pack_repair_modes_as(const char *docs, const char *root, unsigned self_uid); extern unsigned s2a_pack_repair_self_override; unsigned s2a_pack_repair_tree(const char *dir);
const char *s2a_img_scan_skipped(void);
unsigned s2a_foreign_scan(const char *home, uint64_t *bytes, char *line, size_t n); unsigned s2a_foreign_scan_as(const char *home, unsigned self_uid, uint64_t *bytes, char *line, size_t n);
// 压缩传输的 game.img 块（v0.5.0，runtime/src/pack_apply.c img_unzst；块大小本单测编成 64 KB，见 runtime/tests/mk/pack_apply.mk）。
//   夹具：合成单一 IMG（头 + 规律字节 + 文件尾 40 字节空目录表，长 2 × 64 KB + 5000），按 64 KB 切 3 块，每块用 zstd 命令行（没有就 Python zstd 模块）
//   各压成一帧，放进 .incoming。期望手写：解完 game.img 与源逐字节相同、块全删、.applied = 清单号；缺块 / 坏帧 / 截短 → 截短包码、块与 .pushed 都删
#define ZC 65536
static char g_zcmd[64];   // 压缩命令：zstd 命令行或 python3
static int zstd_pick(void) {
    if (!g_zcmd[0]) { if (sh("command -v zstd >/dev/null 2>&1") == 0) snprintf(g_zcmd, sizeof g_zcmd, "zstd");
        else if (sh("python3 -c 'from compression import zstd' 2>/dev/null || python3 -c 'import zstandard' 2>/dev/null") == 0) snprintf(g_zcmd, sizeof g_zcmd, "python3"); else snprintf(g_zcmd, sizeof g_zcmd, "-"); }
    return g_zcmd[0] != '-';
}
static int zcomp(const char *in, const char *out) {   // 一个文件压成一个带校验的 zstd 帧
    char c[3000];
    if (!strcmp(g_zcmd, "zstd")) snprintf(c, sizeof c, "zstd -q -f --check -o '%s' '%s'", out, in);
    else snprintf(c, sizeof c, "python3 -c \"import sys\ntry:\n from compression import zstd; z=lambda b: zstd.compress(b, options={zstd.CompressionParameter.checksum_flag: 1})\n"
                  "except ImportError:\n import zstandard; z=zstandard.ZstdCompressor(write_checksum=True).compress\nopen(sys.argv[2],'wb').write(z(open(sys.argv[1],'rb').read()))\" '%s' '%s'", in, out);
    return sh(c);
}
static void wfile(const char *p, const void *b, size_t n) { FILE *f = fopen(p, "wb"); CHECK(f && fwrite(b, 1, n, f) == n, "写 %s", p); if (f) fclose(f); }
static const char ZSHA[] = "0123456789abcdef";
// 布置一份待解的资源包：src = 期望的 game.img；chunks 位掩码 = 放哪几块（第 i 位 = 第 i 块）；old = 机上已有的 game.img 前缀长度（-1 = 放一份更长的旧内容）
static void zsetup(const char *docs, const uint8_t *src, size_t L, unsigned chunks, long old) {
    char root[1300], p[1600], c[3000]; s2a_pack_root(root, sizeof root, docs);
    snprintf(c, sizeof c, "rm -rf '%s' && mkdir -p '%s/.incoming' '%s/exefs' '%s/zparts' && printf npdm > '%s/exefs/main.npdm' && printf '{\"index_sha256\": \"zz1\"}' > '%s/manifest.json'"
             " && printf 'game.img\\t%zu\\t%s000000000000000000000000000000000000000000000000\\n" NPDM_ROW "' > '%s/index.tsv' && printf x > '%s/.pushed'",
             docs, root, root, docs, root, root, L, ZSHA, root, root);
    CHECK(sh(c) == 0, "布置 %s", docs);
    if (old == -1) { size_t n = L + 5000; uint8_t *b = malloc(n); memset(b, 'o', n); snprintf(p, sizeof p, "%s/game.img", root); wfile(p, b, n); free(b); }
    else if (old > 0) { snprintf(p, sizeof p, "%s/game.img", root); wfile(p, src, (size_t)old); }
    for (unsigned k = 0; k * ZC < L; k++) { if (!(chunks >> k & 1)) continue;
        char part[1600], out[1600]; snprintf(part, sizeof part, "%s/zparts/p%u", docs, k); size_t n = L - k * ZC < ZC ? L - k * ZC : ZC; wfile(part, src + k * ZC, n);
        snprintf(out, sizeof out, "%s/.incoming/game.img.%s.%04u.zst", root, ZSHA, k); CHECK(zcomp(part, out) == 0, "压第 %u 块", k); }
}
static int zleft(const char *root) { char c[1600]; snprintf(c, sizeof c, "ls '%s/.incoming' | grep -c 'zst$' | grep -qx 0", root); return sh(c) != 0; }   // 还有 .zst → 1
static void zst_cases(const char *T) {
    if (!zstd_pick()) { printf("⚠ t_pack_apply：没有 zstd 命令行也没有 Python zstd 模块，压缩块用例没跑\n"); return; }
    size_t L = 2 * ZC + 5000; uint8_t *src = calloc(1, L);
    memcpy(src, "S2AIMG01", 8); uint32_t fmt = 1; memcpy(src + 8, &fmt, 4);
    uint64_t to = L - 40, tl = 40, tot = L; memcpy(src + 112, &to, 8); memcpy(src + 120, &tl, 8); memcpy(src + 128, &tot, 8);
    for (size_t i = 16384; i < L - 40; i++) src[i] = (uint8_t)(i / 7 * 13);
    uint32_t slots = 1; memcpy(src + L - 40, &slots, 4);   // 空目录表：1 个空槽、0 条
    char D[1300], R[1400], p[1600], c[3000], sp[1400]; struct stat st;
    snprintf(sp, sizeof sp, "%s/zsrc.img", T); wfile(sp, src, L);
    // Ⓐ 三块齐、机上有一份更长的旧 game.img、另有别的版本的块和一个空的本版块名：待导入 → 解开后逐字节相同、块全删、.applied = zz1、日志 3 行进度
    snprintf(D, sizeof D, "%s/zA", T); s2a_pack_root(R, sizeof R, D); zsetup(D, src, L, 7, -1);
    snprintf(p, sizeof p, "%s/.incoming/game.img.eeeeeeeeeeeeeeee.0000.zst", R); wfile(p, "old", 3);
    snprintf(p, sizeof p, "%s/.incoming/game.img.%s.0009.zst", R, ZSHA); wfile(p, "", 0);
    CHECK(s2a_import_state(D) == 1, "Ⓐ 有压缩块 → 待导入（实际 %d）", s2a_import_state(D));
    int rc = s2a_pack_apply(D); snprintf(p, sizeof p, "%s/game.img", R);
    CHECK(rc == 0, "Ⓐ 解压缩块应成功：%s", s2a_pack_apply_failure());
    CHECK(same(p, sp), "Ⓐ 解出的 game.img 应与源逐字节相同");
    CHECK(!zleft(R), "Ⓐ 解完 .incoming 里不留 .zst（含别的版本、空块）");
    snprintf(c, sizeof c, "test \"$(cat '%s/.applied')\" = zz1 && test \"$(grep -c '进度：解开 game.img.%s.000' '%s/unpack.log')\" = 3", R, ZSHA, D);
    CHECK(sh(c) == 0, "Ⓐ .applied = zz1、解包日志 3 行块进度");
    // Ⓑ 第 0 块上次已解进去（game.img 有前 64 KB、块已删），只剩第 1、2 块 → 接着解，逐字节相同
    snprintf(D, sizeof D, "%s/zB", T); s2a_pack_root(R, sizeof R, D); zsetup(D, src, L, 6, ZC);
    rc = s2a_pack_apply(D); snprintf(p, sizeof p, "%s/game.img", R);
    CHECK(rc == 0 && same(p, sp), "Ⓑ 接着解剩下的块应成功且逐字节相同（rc %d：%s）", rc, s2a_pack_apply_failure());
    // Ⓒ 缺中间一块（只有第 0、2 块）→ 失败、截短包码、块与 .pushed 都删
    // Ⓓ 第 1 块中间改一个字节（帧坏 / 校验不对）→ 同上
    // Ⓔ 第 2 块去掉最后一个字节（截短）→ 同上
    for (int v = 0; v < 3; v++) {
        snprintf(D, sizeof D, "%s/z%c", T, 'C' + v); s2a_pack_root(R, sizeof R, D); zsetup(D, src, L, v == 0 ? 5 : 7, 0);
        if (v) { snprintf(p, sizeof p, "%s/.incoming/game.img.%s.%04d.zst", R, ZSHA, v); CHECK(stat(p, &st) == 0, "Ⓓ/Ⓔ 块在");
            if (v == 1) { FILE *f = fopen(p, "r+b"); fseek(f, st.st_size / 2, SEEK_SET); int ch = fgetc(f); fseek(f, st.st_size / 2, SEEK_SET); fputc(ch ^ 0x5a, f); fclose(f); }
            else CHECK(truncate(p, st.st_size - 1) == 0, "Ⓔ 截掉一个字节"); }
        rc = s2a_pack_apply(D);
        snprintf(p, sizeof p, "%s/.pushed", R);
        CHECK(rc != 0 && !strcmp(s2a_pack_apply_code(), "ios_install_pack_truncated"), "%s 应失败且给截短包码（rc %d 码 %s：%s）", v == 0 ? "Ⓒ 缺块" : v == 1 ? "Ⓓ 坏帧" : "Ⓔ 截短", rc, s2a_pack_apply_code(), s2a_pack_apply_failure());
        CHECK(!zleft(R) && stat(p, &st) != 0, "%s 失败后块与 .pushed 都应删掉（下次电脑端整份重推）", v == 0 ? "Ⓒ" : v == 1 ? "Ⓓ" : "Ⓔ");
        CHECK(strstr(s2a_pack_apply_failure(), v == 0 ? "缺压缩块" : v == 1 ? "压缩块" : "截短"), "%s 失败原因应说清（%s）", v == 0 ? "Ⓒ" : v == 1 ? "Ⓓ" : "Ⓔ", s2a_pack_apply_failure());
    }
    free(src);
}
// 小游戏包 .s2arm 导入（s2a_s2arm_import，0.6.0 通用壳）：合成包（无游戏数据），期望手写：
//   ① 导好：程序进 program/v-<image_sha256 前 16 位>-s2arm/、清单补上 dir 换上、派生件进 资源包/、临时 tar 不留；游戏号按大写
//   ② 帧没到尾（拷了一半）→ 1、什么都不写 ③ 第一个条目不是 s2arm.json → -2 / ios_install_manifest_bad ④ 条目路径带 .. → -2、清单不换
//   ⑤ 放进「放这里导入」：扫描导入、导好删掉原文件
//   ⑥ 导入文件夹里的坏 .s2arm：扫描报失败（码 ios_install_manifest_bad、原因带文件名，库界面才弹得出来）、文件留着；没改再扫 → 跳过、不报；改了再扫 → 重试、再报
int s2a_s2arm_import(const char *proc_docs, const char *src, char *gid_out, size_t gid_n); const char *s2a_s2arm_import_code(void);
static void s2arm_pack(const char *T, const char *out, const char *first, const char *bad_name) {
    char tp[1024]; snprintf(tp, sizeof tp, "%s/s2arm.tar", T); FILE *f = fopen(tp, "wb"); CHECK(f != NULL, "造 .s2arm tar 失败"); if (!f) return;
    const char *j = "{\n \"format\": \"s2arm\",\n \"schema\": 1,\n \"title_id\": \"0100abcde0000000\",\n \"image_sha256\": \"0123456789abcdefffff\"\n}";
    tar_entry(f, first, '0', j, strlen(j));
    const char *cat = "{\"schema\": 1, \"title_id\": \"0100ABCDE0000000\", \"team\": null}";
    tar_entry(f, "program/catalogue.json", '0', cat, strlen(cat));
    tar_entry(f, "program/S2AImages-0100ABCDE0000000.dylib", '0', "DYLIB", 5);
    tar_entry(f, "program/Games/0100ABCDE0000000/x.txt", '0', "x", 1);
    tar_entry(f, "pack/index.tsv", '0', "shaders/a\t1\t-\n", 14);
    tar_entry(f, bad_name ? bad_name : "pack/ctl/control.nacp", '0', "N", 1);
    uint8_t zero[1024] = {0}; fwrite(zero, 1, sizeof zero, f); fclose(f);
    CHECK(zcomp(tp, out) == 0, "压 .s2arm 失败");
}
static int s2arm_read_is(const char *p, const char *want) { char b[256] = ""; FILE *f = fopen(p, "rb"); if (!f) return 0; size_t n = fread(b, 1, sizeof b - 1, f); fclose(f); b[n] = 0; return !strcmp(b, want); }
static void s2arm_cases(const char *T) {
    if (!zstd_pick()) { printf("（跳过 .s2arm 导入：本机既没有 zstd 命令行也没有 Python zstd 模块）\n"); return; }
    char docs[1024], c[2400], src[1200], g[17], base[1200], p[2400]; snprintf(docs, sizeof docs, "%s/s2h/Documents", T);
    snprintf(c, sizeof c, "mkdir -p '%s/放这里导入'", docs); CHECK(sh(c) == 0, "布置 .s2arm 文档根");
    snprintf(base, sizeof base, "%s/s2h/Library/Application Support/S2Arm/games/0100ABCDE0000000", T);
    snprintf(src, sizeof src, "%s/a.s2arm", T); s2arm_pack(T, src, "s2arm.json", NULL);
    int rc = s2a_s2arm_import(docs, src, g, sizeof g);
    CHECK(rc == 0 && !strcmp(g, "0100ABCDE0000000"), "① 导入：返回 %d、游戏号「%s」（期望 0、0100ABCDE0000000）", rc, g);
    snprintf(p, sizeof p, "%s/program/v-0123456789abcdef-s2arm/S2AImages-0100ABCDE0000000.dylib", base); CHECK(s2arm_read_is(p, "DYLIB"), "① 程序库进了 v-0123456789abcdef-s2arm/");
    snprintf(p, sizeof p, "%s/program/v-0123456789abcdef-s2arm/Games/0100ABCDE0000000/x.txt", base); CHECK(s2arm_read_is(p, "x"), "① 随行目录进了版本目录");
    snprintf(p, sizeof p, "%s/program/catalogue.json", base);
    CHECK(s2arm_read_is(p, "{\"dir\": \"v-0123456789abcdef-s2arm\",\"schema\": 1, \"title_id\": \"0100ABCDE0000000\", \"team\": null}"), "① 清单补上 dir 换上");
    snprintf(p, sizeof p, "%s/资源包/index.tsv", base); CHECK(s2arm_read_is(p, "shaders/a\t1\t-\n"), "① 派生件 index.tsv 进了资源包");
    snprintf(p, sizeof p, "%s/资源包/ctl/control.nacp", base); CHECK(s2arm_read_is(p, "N"), "① 派生件 ctl/control.nacp 进了资源包");
    snprintf(c, sizeof c, "ls -a '%s/s2h/Library/Application Support/S2Arm' | grep -c s2arm-import", T); CHECK(sh(c) != 0, "① 临时 tar 不留");
    // ② 拷了一半：截掉后半
    { char half[1200]; snprintf(half, sizeof half, "%s/half.s2arm", T); struct stat st; stat(src, &st);
      snprintf(c, sizeof c, "head -c %lld '%s' > '%s'", (long long)st.st_size / 2, src, half); sh(c);
      rc = s2a_s2arm_import(docs, half, g, sizeof g); CHECK(rc == 1, "② 拷了一半：返回 %d（期望 1，原样留着下次再看）", rc); }
    // ③ 第一个条目不对
    snprintf(src, sizeof src, "%s/b.s2arm", T); s2arm_pack(T, src, "readme.txt", NULL);
    rc = s2a_s2arm_import(docs, src, g, sizeof g); CHECK(rc == -2 && !strcmp(s2a_s2arm_import_code(), "ios_install_manifest_bad"), "③ 不是小游戏包：返回 %d、码 %s", rc, s2a_s2arm_import_code());
    // ④ 路径带 ..：清单不换（还是①那份）
    snprintf(p, sizeof p, "%s/program/catalogue.json", base); unlink(p);
    snprintf(src, sizeof src, "%s/c.s2arm", T); s2arm_pack(T, src, "s2arm.json", "pack/../evil");
    rc = s2a_s2arm_import(docs, src, g, sizeof g); struct stat st;
    CHECK(rc == -2 && stat(p, &st) != 0, "④ 条目路径带 ..：返回 %d（期望 -2），清单没换上", rc);
    // ⑤ 放进导入文件夹：扫描导入、原文件删掉
    snprintf(src, sizeof src, "%s/放这里导入/d.s2arm", docs); s2arm_pack(T, src, "s2arm.json", NULL);
    s2a_img_scan(docs);
    CHECK(stat(src, &st) != 0 && stat(p, &st) == 0, "⑤ 导入文件夹里的 .s2arm：导好、原文件删掉");
    // ⑥ 坏 .s2arm 放进导入文件夹
    snprintf(src, sizeof src, "%s/放这里导入/bad.s2arm", docs); s2arm_pack(T, src, "readme.txt", NULL);
    s2a_img_scan(docs);
    CHECK(!strcmp(s2a_img_scan_code(), "ios_install_manifest_bad") && strstr(s2a_img_scan_failure(), "bad.s2arm") && stat(src, &st) == 0,
          "⑥ 坏 .s2arm：码「%s」（期望 ios_install_manifest_bad）、原因「%s」带文件名、文件留着", s2a_img_scan_code(), s2a_img_scan_failure());
    s2a_img_scan(docs);
    CHECK(!s2a_img_scan_code()[0] && !s2a_img_scan_failure()[0] && stat(src, &st) == 0, "⑥ 没改再扫：跳过（码「%s」、原因「%s」都应为空），文件还在", s2a_img_scan_code(), s2a_img_scan_failure());
    { FILE *f = fopen(src, "ab"); if (f) { fputc(0, f); fclose(f); } }
    s2a_img_scan(docs);
    CHECK(s2a_img_scan_code()[0] && strstr(s2a_img_scan_failure(), "bad.s2arm"), "⑥ 改了再扫：重试、再报（码「%s」）", s2a_img_scan_code());
    unlink(src);
}
// 两路同时解同一款（11-19 Duo：游戏库与资源导入闸门各起一路，后一路打开已被前一路解完删掉的 tar 回 errno 2、按失败收场）。
//   A 解完第 1 个包时（进度回调）起 B，A 再停 300 毫秒：串行时 B 等 A 做完、见待解包已空且 .applied = 清单号 → 直接成功；
//   旧实现里 B 在这 300 毫秒里解掉第 2、3 个包并删掉，A 醒来打开第 2 个包回 errno 2 → A 失败
#include <pthread.h>
static char g_race_docs[600]; static pthread_t g_race_b; static int g_race_brc = -100, g_race_started; static pthread_t g_race_a;
static void *race_b(void *a) { (void)a; g_race_brc = s2a_pack_apply(g_race_docs); return NULL; }
static void race_prog(int d, int t) { (void)t; if (pthread_equal(pthread_self(), g_race_a) && d == 1 && !g_race_started) { g_race_started = 1; pthread_create(&g_race_b, NULL, race_b, NULL); usleep(300000); } }
static void race_case(const char *T) {
    char c[4096]; snprintf(g_race_docs, sizeof g_race_docs, "%s/race", T);
    snprintf(c, sizeof c, "cd %s && mkdir -p rsrc/exefs race/资源包/.incoming && printf npdm > rsrc/exefs/main.npdm && printf a > rsrc/a.txt && printf bb > rsrc/b.txt && printf ccc > rsrc/c.txt && "
        "cd rsrc && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../race/资源包/.incoming/9_000.tar exefs a.txt && "
        "COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../race/资源包/.incoming/9_001.tar b.txt && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../race/资源包/.incoming/9_002.tar c.txt && cd .. && "
        "printf '{\"version\":2,\"index_sha256\":\"race01\"}' > race/资源包/manifest.json && printf 'a.txt\\t1\\tx\\nb.txt\\t2\\tx\\nc.txt\\t3\\tx\\n" NPDM_ROW "' > race/资源包/index.tsv", T);
    CHECK(sh(c) == 0, "两路并发：造包失败");
    g_race_a = pthread_self(); s2a_pack_apply_progress = race_prog; int ra = s2a_pack_apply(g_race_docs);
    if (g_race_started) pthread_join(g_race_b, NULL);
    s2a_pack_apply_progress = NULL;
    CHECK(g_race_started, "两路并发：B 没起来（进度回调没到第 1 个包）");
    CHECK(ra == 0, "两路并发：A 应成功（实际 %d：%s）", ra, s2a_pack_apply_failure());
    CHECK(g_race_brc == 0, "两路并发：B 应成功（实际 %d：%s）", g_race_brc, s2a_pack_apply_failure());
    snprintf(c, sizeof c, "cd %s/race/资源包 && test \"$(cat a.txt b.txt c.txt)\" = abbccc && grep -qx race01 .applied && test -z \"$(ls .incoming)\"", T);
    CHECK(sh(c) == 0, "两路并发：三个文件都在、.applied = race01、待解包已空");
}
int main(void) {
    char T[] = "/tmp/s2a_t_pack_XXXXXX"; if (!mkdtemp(T)) return 1;
    boundary_cases(T);
    s2arm_cases(T);
    // 失败给码（11-11 维护者「补上说人话的原因」）：返回码 / errno / 截短 / 是否出在 game.img 那步 → 规格码。期望按码表含义手写：
    //   目录写不进优先（重开 App 会迁）；其次空间满（不管哪步）；截短或包头坏 = 没传完；格式号 / IMG 坏；核对缺文件；清单读不出；其余写失败；认不出的 unknown
    { struct { int rc, err, trunc, img; const char *want; } m[] = {
        {0, 0, 0, 0, ""}, {-12, 0, 0, 0, "ios_install_dir_unwritable"}, {-12, ENOSPC, 0, 0, "ios_install_dir_unwritable"},
        {-4, ENOSPC, 0, 0, "ios_install_no_space"}, {-4, EDQUOT, 0, 1, "ios_install_no_space"}, {-4, ENOSPC, 1, 0, "ios_install_no_space"},
        {-4, EIO, 1, 0, "ios_install_pack_truncated"}, {-2, 0, 0, 0, "ios_install_pack_truncated"},
        {-11, 0, 0, 1, "ios_install_img_format"}, {-10, 0, 0, 1, "ios_install_img_corrupt"}, {-3, EINVAL, 0, 1, "ios_install_img_corrupt"},
        {-3, 0, 0, 0, "ios_install_unknown"}, {-5, 0, 0, 0, "ios_install_unknown"}, {-8, 0, 0, 0, "ios_install_files_missing"},
        {-6, 0, 0, 0, "ios_install_manifest_bad"}, {-7, 0, 0, 0, "ios_install_manifest_bad"}, {-4, EACCES, 0, 0, "ios_install_dir_unwritable"}, {-4, EPERM, 0, 0, "ios_install_dir_unwritable"}, {-4, EIO, 0, 0, "ios_install_write_failed"},
        {-99, 0, 0, 0, "ios_install_unknown"} };
      for (size_t i = 0; i < sizeof m / sizeof *m; i++) { const char *got = s2a_install_code(m[i].rc, m[i].err, m[i].trunc, m[i].img);
          CHECK(!strcmp(got, m[i].want), "给码 rc %d errno %d 截短 %d IMG %d：期望 %s，实际 %s", m[i].rc, m[i].err, m[i].trunc, m[i].img, m[i].want, got); }
      // 引擎会给的每个码都在共用规格里（屏上文案按码从规格生成，查不到就只能显示「未知原因」）
      char sp[1200]; snprintf(sp, sizeof sp, "%s", __FILE__); char *cut = strstr(sp, "runtime/tests/"); if (cut) *cut = 0; strlcat(sp, "launchers/shared/experience.v1.json", sizeof sp);
      FILE *sf = fopen(sp, "r"); char spec[200000] = ""; size_t sk = sf ? fread(spec, 1, sizeof spec - 1, sf) : 0; if (sf) fclose(sf); spec[sk] = 0;
      CHECK(sk > 0, "读共用规格 %s", sp);
      const char *codes[] = {"ios_install_dir_unwritable", "ios_install_no_space", "ios_install_pack_truncated", "ios_install_img_format", "ios_install_img_corrupt",
          "ios_install_files_missing", "ios_install_manifest_bad", "ios_install_write_failed", "ios_install_unknown", "ios_import_img_failed", "ios_import_update_no_base", "ios_import_update_mismatch"};
      for (size_t i = 0; i < sizeof codes / sizeof *codes; i++) { char q[80]; snprintf(q, sizeof q, "\"code\": \"%s\"", codes[i]); CHECK(strstr(spec, q) != NULL, "规格里应有码 %s", codes[i]); } }
    char c[8192];
    snprintf(c, sizeof c, "cd %s && mkdir -p src/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子 docs/资源包/.incoming && "
        "head -c 70000 /dev/urandom > 'src/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子/文件.bin' && : > src/空.txt && printf abc > src/a.txt && "
        "mkdir -p src/exefs && printf npdm > src/exefs/main.npdm && "
        "cd src && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/1_000.tar romfs a.txt exefs && "
        "COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/1_001.tar 空.txt && cd .. && "
        "printf '{\"version\":2,\"index_sha256\":\"deadbeef01\"}' > docs/资源包/manifest.json && "
        "printf 'a.txt\\t3\\tx\\n空.txt\\t0\\tx\\n" NPDM_ROW "romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子/文件.bin\\t70000\\tx\\n' > docs/资源包/index.tsv && "
        "mkdir -p docs/资源包/old && head -c 3000 /dev/zero > docs/资源包/old/part000 && printf p > docs/资源包/.pushed && mkdir -p docs/资源包/shaders/direct/b-0a7dae3c1e7b docs/资源包/.hid/空", T);
    CHECK(sh(c) == 0, "造包失败");
    char docs[512]; snprintf(docs, sizeof docs, "%s/docs", T);
    CHECK(s2a_pack_apply(docs) == 0, "解包返回非 0");
    snprintf(c, sizeof c, "%s/src/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子/文件.bin", T); char d[8192];
    snprintf(d, sizeof d, "%s/docs/资源包/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子/文件.bin", T);
    CHECK(same(c, d), "长中文路径文件逐字节不符");
    snprintf(c, sizeof c, "%s/src/a.txt", T); snprintf(d, sizeof d, "%s/docs/资源包/a.txt", T); CHECK(same(c, d), "a.txt 不符");
    struct stat st; snprintf(d, sizeof d, "%s/docs/资源包/空.txt", T); CHECK(!stat(d, &st) && st.st_size == 0, "空文件没解出来");
    snprintf(d, sizeof d, "%s/docs/资源包/.incoming/1_000.tar", T); CHECK(stat(d, &st) != 0, "解完的 tar 没删");
    snprintf(c, sizeof c, "grep -qx deadbeef01 %s/docs/资源包/.applied", T); CHECK(sh(c) == 0, ".applied 不对");
    snprintf(c, sizeof c, "grep -qx deadbeef01 %s/docs/资源包/.applied_by_shell", T); CHECK(sh(c) == 0, ".applied_by_shell（0.6 起解开的来源标记，游戏库据此不当 0.5 老款）没写或不对");
    // 4 个文件 = 文件.bin、a.txt、exefs/main.npdm（1_000.tar）+ 空.txt（1_001.tar）；目录不计
    snprintf(c, sizeof c, "grep -q '解开 2 个包 4 个文件' %s/docs/unpack.log && ! grep -q '返回 -' %s/docs/unpack.log", T, T); CHECK(sh(c) == 0, "unpack.log 行不对");
    snprintf(c, sizeof c, "test $(grep -c '进度：解开 1_00' %s/docs/unpack.log) = 2 && grep -q '清掉不在 index.tsv 里的旧文件 1 个' %s/docs/unpack.log", T, T); CHECK(sh(c) == 0, "进度行（每个 tar 一行）或清旧文件行不对");
    snprintf(d, sizeof d, "%s/docs/资源包/old/part000", T); CHECK(stat(d, &st) != 0, "不在 index.tsv 里的旧分卷没删");
    snprintf(d, sizeof d, "%s/docs/资源包/.pushed", T); CHECK(stat(d, &st) == 0, "执行器记账文件 .pushed 被误删");
    // 删空了的目录一并清掉（10-25 马车8 旧直连库 b-<链>/ 空目录残留）；有文件的目录、以 . 开头的目录（.incoming / .hid）留着
    snprintf(d, sizeof d, "%s/docs/资源包/old", T); CHECK(stat(d, &st) != 0, "旧分卷删光后的空目录 old/ 没删");
    snprintf(d, sizeof d, "%s/docs/资源包/shaders", T); CHECK(stat(d, &st) != 0, "空目录链 shaders/direct/b-…/ 没删干净");
    snprintf(d, sizeof d, "%s/docs/资源包/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子", T); CHECK(stat(d, &st) == 0, "有文件的目录被误删");
    snprintf(d, sizeof d, "%s/docs/资源包/.incoming", T); CHECK(stat(d, &st) == 0, ".incoming 被误删");
    snprintf(d, sizeof d, "%s/docs/资源包/.hid/空", T); CHECK(stat(d, &st) == 0, "以 . 开头目录下的空目录被误删");
    // 坏包：路径含 ..（tar 默认会去掉 ..，用 -s 改名造出来）
    snprintf(c, sizeof c, "cd %s/src && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " " TAR_RENAME " -cf ../docs/资源包/.incoming/2_000.tar a.txt 2>/dev/null", T); sh(c);
    CHECK(s2a_pack_apply(docs) != 0, "含 .. 的包应判失败");
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '返回 -3'", T); CHECK(sh(c) == 0, "失败行应含「返回 -3」");
    snprintf(d, sizeof d, "%s/docs/逃逸.txt", T); CHECK(stat(d, &st) != 0, "路径逃逸写出了资源包目录");
    // 旧布局挡路（「0.3.10 → 0.4.3 重装装不上」：同一位置旧版是文件、新版要目录，每次重解都在建目录那步 -4，点重试没用）：
    //   资源包下已有同名普通文件 aoc，包里要建 aoc/d.bin → 期望不再 -4：挡路的旧文件删掉、aoc/d.bin 解出来，host 日志记一句「已删」
    snprintf(c, sizeof c, "cd %s && rm -f docs/资源包/.incoming/2_000.tar && printf x > docs/资源包/aoc && mkdir -p src2/aoc && printf y > src2/aoc/d.bin && "
        "cd src2 && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/3_000.tar aoc/d.bin", T);
    CHECK(sh(c) == 0, "造冲突包失败");
    { char lg[1100]; snprintf(lg, sizeof lg, "%s/host_stale.log", T); int lfd = open(lg, O_WRONLY | O_CREAT | O_TRUNC, 0644), keep = g_s2a_logfd; g_s2a_logfd = lfd;
      s2a_pack_apply(docs); g_s2a_logfd = keep; close(lfd);
      snprintf(c, sizeof c, "! grep -q '返回 -4' %s/docs/unpack.log.last 2>/dev/null; tail -1 %s/docs/unpack.log | grep -vq '返回 -4'", T, T); CHECK(sh(c) == 0, "旧布局挡路：不应再「返回 -4」");
      snprintf(c, sizeof c, "grep -q '旧布局的文件 aoc 挡着新目录，已删' %s", lg); CHECK(sh(c) == 0, "旧布局挡路：host 日志应记「旧布局的文件 aoc 挡着新目录，已删」"); }
    // 反过来：资源包下已有同名目录 big（里面还有旧文件），包里要放文件 big → 目录整棵删掉、文件解出来
    snprintf(c, sizeof c, "cd %s && rm -f docs/资源包/.incoming/*.tar && mkdir -p docs/资源包/big/old && printf o > docs/资源包/big/old/x && mkdir -p src3 && printf z > src3/big && "
        "cd src3 && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/3_001.tar big", T);
    CHECK(sh(c) == 0, "造反向冲突包失败");
    s2a_pack_apply(docs);
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -vq '返回 -4'", T); CHECK(sh(c) == 0, "旧目录占着新文件的位置：不应再「返回 -4」");
    // 写失败要带现场（10-20 测试设备2 巫师3 连续「返回 -4」看不出哪个条目）：资源包下 locked/ 只读，包里要往里写 locked/e.bin →
    //   期望「返回 -4」，unpack.log 与 host 日志同一行都带「现场：建临时文件 <…>/locked/e.bin.part：errno 13 Permission denied」（EACCES = 13）
    snprintf(c, sizeof c, "cd %s && rm -f docs/资源包/.incoming/*.tar && mkdir -p docs/资源包/locked src4/locked && chmod 0555 docs/资源包/locked && printf w > src4/locked/e.bin && "
        "cd src4 && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/3_002.tar locked/e.bin", T);
    CHECK(sh(c) == 0, "造只读目录包失败");
    { char lg[1100]; snprintf(lg, sizeof lg, "%s/host_locked.log", T); int lfd = open(lg, O_WRONLY | O_CREAT | O_TRUNC, 0644), keep = g_s2a_logfd; g_s2a_logfd = lfd;
      s2a_pack_repair_self_override = (unsigned)getuid() + 1;   // 这条测「别人的只读目录」写失败带现场：自己的只读目录现在会被补回写权限（D-A76N）
      CHECK(s2a_pack_apply(docs) != 0, "只读目录应判失败"); s2a_pack_repair_self_override = 0; g_s2a_logfd = keep; close(lfd);
      snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '返回 -4.*现场：建临时文件 .*/资源包/locked/e.bin.part：errno 13'", T); CHECK(sh(c) == 0, "失败行应含「返回 -4」与建临时文件现场（errno 13）");
      snprintf(c, sizeof c, "grep -q '资源包收推送：失败.*现场：建临时文件 .*locked/e.bin.part：errno 13' %s", lg); CHECK(sh(c) == 0, "host 日志的失败行也应带现场（errno 原文）"); }
    snprintf(c, sizeof c, "cd %s && chmod 0755 docs/资源包/locked && rm -rf docs/资源包/locked docs/资源包/.incoming/*.tar", T); sh(c);
    // 已应用索引：解包成功时 index.tsv 整份存成 index.applied.tsv（执行器据它算补推）
    snprintf(c, sizeof c, "cmp -s %s/docs/资源包/index.tsv %s/docs/资源包/index.applied.tsv", T, T); CHECK(sh(c) == 0, "解包成功后 index.applied.tsv 应与 index.tsv 相同");
    // 截短包（推送中途被杀留下的）：① 截在条目边界——条目完整、只少了归档尾两块全零（旧代码当成解完）；② 截在条目中间。
    //   期望：判失败「返回 -4」并注明「截短包：已删」，tar 已删、排在它后面的待解包与 .pushed 也删（执行器只按 index.applied.tsv 补推）；.applied / index.applied.tsv 不动（机上状态没变）
    for (int k = 0; k < 2; k++) {
        snprintf(c, sizeof c, "cd %s && rm -f docs/资源包/.incoming/*.tar docs/资源包/aoc && cp docs/资源包/index.applied.tsv ia.bak && cd src && "
            "COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../t.tar a.txt romfs && cd .. && "
            "n=$(wc -c < t.tar) && head -c $(( %s )) t.tar > docs/资源包/.incoming/4_000.tar && cp t.tar docs/资源包/.incoming/4_001.tar && printf 'a.txt\\th\\n' > docs/资源包/.pushed && "
            "printf '{\"version\":2,\"index_sha256\":\"deadbeef02\"}' > docs/资源包/manifest.json", T, k == 0 ? "n - 1024" : "n / 2");
        CHECK(sh(c) == 0, "造截短包失败（%d）", k);
        CHECK(s2a_pack_apply(docs) != 0, "截短包应判失败（%s）", k == 0 ? "截在条目边界" : "截在条目中间");
        snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '截短包：已删.*返回 -4'", T); CHECK(sh(c) == 0, "失败行应注明截短包已删、返回 -4（%d）", k);
        CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_pack_truncated"), "截短包给码 ios_install_pack_truncated（%d，实际 %s）", k, s2a_pack_apply_code());
        snprintf(d, sizeof d, "%s/docs/资源包/.incoming/4_000.tar", T); CHECK(stat(d, &st) != 0, "截短包应已删（%d）", k);
        snprintf(d, sizeof d, "%s/docs/资源包/.incoming/4_001.tar", T); CHECK(stat(d, &st) != 0, "截短包后面的待解包也应删（%d）", k);
        snprintf(d, sizeof d, "%s/docs/资源包/.pushed", T); CHECK(stat(d, &st) != 0, "推送记录 .pushed 应删（%d）", k);
        snprintf(c, sizeof c, "grep -qx deadbeef01 %s/docs/资源包/.applied && cmp -s %s/ia.bak %s/docs/资源包/index.applied.tsv", T, T, T); CHECK(sh(c) == 0, ".applied / index.applied.tsv 不应变（%d）", k);
    }
    // 核对机上实况（10-25 测试设备2：推了 4 批、解开 0 个包却记成已应用）：index.tsv 里有、没有任何推送包送来的文件。
    //   v0.3.1 缺件照玩：缺的是核心文件（exefs/ 程序、ctl/control.nacp、game.img / romfs.img）→ 照旧判失败「返回 -8」、行里写明缺几个和第一个的路径；
    //   .applied / index.applied.tsv 不动（执行器下次按旧的已应用索引补推）；核对在清旧文件之前：核不过不删任何文件（旧包的文件都还在）
    snprintf(c, sizeof c, "cd %s && rm -f docs/资源包/.incoming/*.tar && cp docs/资源包/index.applied.tsv ia.bak && "
        "printf 'a.txt\\t3\\tx\\n" NPDM_ROW "exefs/main\\t504067\\tx\\n' > docs/资源包/index.tsv && "
        "printf '{\"version\":2,\"index_sha256\":\"deadbeef03\"}' > docs/资源包/manifest.json", T);
    CHECK(sh(c) == 0, "造缺文件夹具失败");
    CHECK(s2a_pack_apply(docs) != 0, "索引里的核心文件机上不在，应判失败");
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '1 个文件机上缺或大小不符（例：exefs/main（不在））.*返回 -8'", T); CHECK(sh(c) == 0, "失败行应写明缺 1 个、例 exefs/main、返回 -8");
    // iOS 装机剃刀 #10：这次失败在核对（不写解包现场），上一次（截短包）的现场「包被截短」不能贴到这一行上
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '现场'", T); CHECK(sh(c) != 0, "核对失败的行不应带现场（旧代码贴上一次截短包的现场）");
    snprintf(c, sizeof c, "grep -qx deadbeef01 %s/docs/资源包/.applied && cmp -s %s/ia.bak %s/docs/资源包/index.applied.tsv", T, T, T); CHECK(sh(c) == 0, "缺文件时 .applied / index.applied.tsv 不应变");
    snprintf(d, sizeof d, "%s/docs/资源包/空.txt", T); CHECK(stat(d, &st) == 0, "核对没过不应清旧文件（空.txt 被删了）");
    // 缺的只是非核心文件（着色器库、旧形态 romfs 散文件等）→ 部分可玩：不判失败；写 .partial（第一行 = 清单 sha），.applied / index.applied.tsv 不动
    //   （执行器下次照样补推缺的）；unpack.log 写「缺 N 个非必需文件（例：…），部分可玩 = <sha>」（tools/push_pack.py 认这一行）
    snprintf(c, sizeof c, "cd %s && printf 'a.txt\\t3\\tx\\n" NPDM_ROW "shaders/direct/keys.tsv\\t504067\\tx\\n' > docs/资源包/index.tsv && "
        "printf '{\"version\":2,\"index_sha256\":\"deadbeef04\"}' > docs/资源包/manifest.json", T); sh(c);
    CHECK(s2a_pack_apply(docs) == 0, "只缺非核心文件：应判部分可玩、不判失败");
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '缺 1 个非必需文件（例：shaders/direct/keys.tsv（不在））.*部分可玩 = deadbeef04'", T); CHECK(sh(c) == 0, "部分可玩行应写明缺几个、例子、清单 sha");
    snprintf(c, sizeof c, "head -1 %s/docs/资源包/.partial | grep -qx deadbeef04", T); CHECK(sh(c) == 0, ".partial 第一行应是本清单 sha");
    snprintf(c, sizeof c, "grep -qx deadbeef01 %s/docs/资源包/.applied && cmp -s %s/ia.bak %s/docs/资源包/index.applied.tsv", T, T, T); CHECK(sh(c) == 0, "部分可玩时 .applied / index.applied.tsv 不应变（电脑照样补推）");
    snprintf(c, sizeof c, "cd %s && printf 'a.txt\\t4\\tx\\n" NPDM_ROW "' > docs/资源包/index.tsv && printf '{\"version\":2,\"index_sha256\":\"deadbeef05\"}' > docs/资源包/manifest.json", T); sh(c);
    CHECK(s2a_pack_apply(docs) == 0, "非核心文件大小不符：也是部分可玩");
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '例：a.txt（大小不符）.*部分可玩 = deadbeef05'", T); CHECK(sh(c) == 0, "部分可玩行应写明 a.txt 大小不符");
    // pax 扩展头记录缺空格（11-01 审计 P2-17）：头数据 "4abc\0"（长度 5），记录「4abc」长度 4 合法、没有空格；旧代码 strchr 到 \0 得 NULL、+1 后解引用崩。
    //   期望按语义手写：判头坏「返回 -2」、不崩；unpack 级的现场串里写明是 pax 记录格式异常（这里直接调 s2a_untar，只核返回）
    { char tp[2100], r[64], root2[2100]; snprintf(tp, sizeof tp, "%s/badpax.tar", T); snprintf(root2, sizeof root2, "%s/badpax_root", T); mkdir(root2, 0755);
      uint8_t h[512], z[1024] = {0}; int fd = open(tp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      tar_hdr(h, "PaxHeader/x", 5, 'x'); write(fd, h, 512); memset(h, 0, 512); memcpy(h, "4abc", 5); write(fd, h, 512); write(fd, z, sizeof z); close(fd);
      untar_child(tp, root2, r, sizeof r);
      CHECK(!strcmp(r, "返回 -2"), "pax 记录缺空格：期望 返回 -2 → %s", r); }
    // iOS 装机剃刀 #4：条目头校验和不对（包没传对）→ 返回 -2、日志行带这次的现场「校验和」，给码按没传完
    { char c2[4096]; uint8_t h[512], z[1024] = {0}; char tp[2200]; snprintf(tp, sizeof tp, "%s/docs/资源包/.incoming/5_000.tar", T);
      snprintf(c2, sizeof c2, "rm -f %s/docs/资源包/.incoming/*.tar", T); sh(c2);
      int fd = open(tp, O_WRONLY | O_CREAT | O_TRUNC, 0644); tar_hdr(h, "a.txt", 0, '0'); h[0] = 'b'; write(fd, h, 512); write(fd, z, sizeof z); close(fd);
      CHECK(s2a_pack_apply(docs) != 0, "校验和坏的包应判失败");
      snprintf(c2, sizeof c2, "tail -1 %s/docs/unpack.log | grep -q '返回 -2.*现场：条目头校验和不对'", T); CHECK(sh(c2) == 0, "校验和坏：失败行应含「返回 -2」与校验和现场");
      CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_pack_truncated"), "校验和坏给码 ios_install_pack_truncated（实际 %s）", s2a_pack_apply_code());
      unlink(tp); }
    // iOS 装机剃刀 #14：闸门的核对（s2a_pack_check）和解包核对同一份：index.tsv 里的 d 被同名目录占着、大小恰好写成目录的大小 →
    //   两边都判不完整、例子写明「不是文件」（旧闸门那份不查是不是普通文件，判完整）
    { char R[2100], c2[4096], first[256] = ""; struct stat ds; snprintf(R, sizeof R, "%s/dirtaken", T);
      snprintf(c2, sizeof c2, "mkdir -p '%s/d'", R); sh(c2);
      snprintf(c2, sizeof c2, "%s/d", R); stat(c2, &ds);
      snprintf(c2, sizeof c2, "printf 'd\\t%lld\\tx\\n' > '%s/index.tsv'", (long long)ds.st_size, R); sh(c2);
      int bad1 = s2a_pack_check(R, first, sizeof first);
      CHECK(bad1 == 1 && strstr(first, "d（不是文件）"), "同名目录占位：闸门核对应判 1 个不符、例「d（不是文件）」→ %d「%s」", bad1, first); }
    // .applied 不先截断（11-01 审计 P2-16）：旧 .applied = oldmark；这次 manifest 的 index_sha256 是 64 字符，子进程把单文件上限设成 32 字节（SIGXFSZ 忽略），
    //   index.applied.tsv（a.txt 行 10 + 程序描述行 20 = 30 字节）写得下、.applied（64 字节）写不下。期望按语义手写：解包判失败（退出码 1）、.applied 仍是 oldmark、不留 .applied.tmp。
    //   旧代码 fopen("w") 先把 .applied 截成 0 字节再写失败 → 旧标记丢了
    { char D[2100], c2[4096], ap[2200], got[128] = ""; struct stat s2; snprintf(D, sizeof D, "%s/atom", T);
      snprintf(c2, sizeof c2, "mkdir -p '%s/资源包' && cd '%s/资源包' && printf abc > a.txt && mkdir -p exefs && printf npdm > exefs/main.npdm && printf 'a.txt\\t3\\tx\\n" NPDM_ROW "' > index.tsv && printf oldmark > .applied && "
          "printf '{\"version\":2,\"index_sha256\":\"%%064d\"}' 7 > manifest.json", D, D);
      CHECK(sh(c2) == 0, "造 .applied 夹具失败");
      pid_t pid = fork(); if (pid == 0) { signal(SIGXFSZ, SIG_IGN); struct rlimit rl = {32, 32}; setrlimit(RLIMIT_FSIZE, &rl); _exit(s2a_pack_apply(D)); }
      int st = 0; waitpid(pid, &st, 0); int ec = WIFEXITED(st) ? WEXITSTATUS(st) : 100 + WTERMSIG(st);
      snprintf(ap, sizeof ap, "%s/资源包/.applied", D); FILE *f = fopen(ap, "r"); if (f) { size_t k = fread(got, 1, sizeof got - 1, f); got[k] = 0; fclose(f); }
      snprintf(ap, sizeof ap, "%s/资源包/.applied.tmp", D);
      CHECK(ec == 1 && !strcmp(got, "oldmark") && stat(ap, &s2) != 0, ".applied 写失败：期望 退出 1 / oldmark / 无 .applied.tmp → 退出 %d / %s / %s", ec, got, stat(ap, &s2) ? "无 .applied.tmp" : "留了 .applied.tmp"); }
    // 玩家导入闸门（用户体验线 10-23）：状态 0 就绪 / 1 待导入 / 2 没有资源。期望按规则手写：
    //   ① 空 Documents → 2；② 「资源包」里有 .incoming/*.tar → 1；③ 解开后（有 manifest.json、没有 tar）→ 0，进度回调最后一次 = (总批数, 总批数)；
    //   ④ 只有「…资源包」（访达拷的整个文件夹）、没有「资源包」→ 2，且不改名（iOS 装机剃刀 #28：那条路删了，原先唯一一个会被改名成「资源包」）；
    //   ⑤ 只有「资源包」没有 manifest、没有 tar → 2；⑥ 空「资源包」+ 可用的「smg2资源包」→ 仍是 2、两个都不动（原先把空的挪开、改用后者）
    { char D[2100], c2[4096]; struct stat s2;
      snprintf(D, sizeof D, "%s/imp1", T); mkdir(D, 0755); CHECK(s2a_import_state(D) == 2, "① 空 Documents 应判没有资源");
      snprintf(c2, sizeof c2, "cd %s && mkdir -p src2 '%s/资源包/.incoming' && echo hi > src2/a.txt && mkdir -p src2/exefs && printf npdm > src2/exefs/main.npdm && cd src2 && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf '%s/资源包/.incoming/1_000.tar' a.txt exefs && cd .. && cp '%s/资源包/.incoming/1_000.tar' '%s/资源包/.incoming/1_001.tar' && printf 'a.txt\\t3\\tx\\n" NPDM_ROW "' > '%s/资源包/index.tsv' && printf '{\"version\":2,\"index_sha256\":\"cafe01\"}' > '%s/资源包/manifest.json'", T, D, D, D, D, D, D);
      CHECK(sh(c2) == 0, "造导入夹具失败");
      CHECK(s2a_import_state(D) == 1, "② 有待导入的 tar 应判待导入");
      s2a_pack_apply_progress = prog; int r = s2a_pack_apply(D); s2a_pack_apply_progress = NULL;
      CHECK(r == 0 && g_pd == 2 && g_pt == 2 && g_pcalls == 3, "③ 解包应成功、进度回调 3 次且最后 = 2/2（rc %d，最后 %d/%d，%d 次）", r, g_pd, g_pt, g_pcalls);
      CHECK(s2a_import_state(D) == 0, "③ 解开后应判就绪");
      snprintf(D, sizeof D, "%s/imp2", T); snprintf(c2, sizeof c2, "mkdir -p '%s/甲资源包/.incoming' && echo '{}' > '%s/甲资源包/manifest.json'", D, D); sh(c2);
      CHECK(s2a_import_state(D) == 2, "④ 只有「甲资源包」应判没有资源");
      snprintf(c2, sizeof c2, "%s/甲资源包", D); CHECK(stat(c2, &s2) == 0, "④ 剃刀 #28：不应改名");
      snprintf(c2, sizeof c2, "%s/资源包", D); CHECK(stat(c2, &s2) != 0, "④ 剃刀 #28：不应冒出「资源包」");
      snprintf(D, sizeof D, "%s/imp3", T); snprintf(c2, sizeof c2, "mkdir -p '%s/资源包'", D); sh(c2);
      CHECK(s2a_import_state(D) == 2, "⑤ 空的「资源包」应判没有资源");
      snprintf(c2, sizeof c2, "mkdir -p '%s/smg2资源包/ctl' && echo '{}' > '%s/smg2资源包/manifest.json' && echo n > '%s/smg2资源包/ctl/control.nacp' && printf 'ctl/control.nacp\\t2\\tx\\n' > '%s/smg2资源包/index.tsv'", D, D, D, D); sh(c2);
      CHECK(s2a_import_state(D) == 2, "⑥ 剃刀 #28：空「资源包」+ 可用的「smg2资源包」仍判没有资源");
      snprintf(c2, sizeof c2, "ls -d '%s'/资源包.空.* > /dev/null 2>&1", D); CHECK(sh(c2) != 0, "⑥ 剃刀 #28：空的「资源包」不应被挪开");
      // ⑦ 资源放进「资源包」（推送 / 认领 game.img 落的就是这里）→ 就绪；旁边的「…资源包」不动
      snprintf(c2, sizeof c2, "cp -R '%s/smg2资源包/.' '%s/资源包/'", D, D); sh(c2);
      CHECK(s2a_import_state(D) == 0, "⑦ 「资源包」里有可用内容应判就绪");
      snprintf(c2, sizeof c2, "%s/smg2资源包", D); CHECK(stat(c2, &s2) == 0, "⑦ 旁边的「smg2资源包」不应被挪");
      // ⑧ 10-26 测试设备2：manifest.json 在、但 index.tsv 记的文件缺（拷到一半）。期望按 index.tsv 手写：ctl/control.nacp 2 字节在、romfs/x.bin 5 字节缺。
      //   v0.3.1 缺件照玩：缺的 romfs/x.bin 不是核心文件 → 4 部分可玩（玩家确认后照玩）；核心文件 ctl/control.nacp 缺 → 3 不完整；补齐 → 0
      snprintf(c2, sizeof c2, "printf 'ctl/control.nacp\\t2\\tx\\nromfs/x.bin\\t5\\tx\\n' > '%s/资源包/index.tsv'", D); sh(c2);
      CHECK(s2a_import_state(D) == 4, "⑧ 只缺非核心文件应判部分可玩(4)");
      snprintf(c2, sizeof c2, "mkdir -p '%s/资源包/romfs' && printf 1234 > '%s/资源包/romfs/x.bin'", D, D); sh(c2);
      CHECK(s2a_import_state(D) == 4, "⑧ 非核心文件大小不对（4 ≠ 5）也是部分可玩(4)");
      snprintf(c2, sizeof c2, "mv '%s/资源包/ctl/control.nacp' '%s/nacp.bak'", D, D); sh(c2);
      CHECK(s2a_import_state(D) == 3, "⑧ 核心文件 ctl/control.nacp 缺：照旧判不完整(3)");
      snprintf(c2, sizeof c2, "mv '%s/nacp.bak' '%s/资源包/ctl/control.nacp'", D, D); sh(c2);
      // ⑧b 部分可玩的快判（v0.3.1）：解包时写的 .partial 第一行 = 当前清单 sha、程序描述在 → 4，不再逐文件核；闸门把它当就绪（确认在 s2a_import_gate 里问）；
      //   清单换了（电脑补推了新的）→ .partial 失效、回到逐文件核；补齐且写了 .applied → 0
      { char E[1300], ER[1400]; snprintf(E, sizeof E, "%s/imp_partial", T); snprintf(ER, sizeof ER, "%s/资源包", E);
        snprintf(c2, sizeof c2, "mkdir -p '%s/exefs' && printf npdm > '%s/exefs/main.npdm' && printf '{\"version\":2,\"index_sha256\":\"p1\"}' > '%s/manifest.json' && "
                 "printf 'exefs/main.npdm\\t4\\tx\\nromfs/gone.bin\\t9\\tx\\n' > '%s/index.tsv' && printf 'p1\\n1\\nromfs/gone.bin（不在）\\n' > '%s/.partial'", ER, ER, ER, ER, ER); sh(c2);
        CHECK(s2a_import_state(E) == 4, "⑧b .partial = 清单 sha、程序描述在 → 部分可玩(4)");
        struct s2a_gate_watch wp = {0}; char wy[200];
        CHECK(s2a_import_decide(E, &wp, 1, wy, sizeof wy) == S2A_GATE_READY, "⑧b 闸门：部分可玩当就绪（玩家确认在 s2a_import_gate 里问）");
        snprintf(c2, sizeof c2, "printf '{\"version\":2,\"index_sha256\":\"p2\"}' > '%s/manifest.json'", ER); sh(c2);
        CHECK(s2a_import_state(E) == 4, "⑧b 清单换了：.partial 失效，逐文件核仍只缺非核心 → 4");
        snprintf(c2, sizeof c2, "mkdir -p '%s/romfs' && printf 123456789 > '%s/romfs/gone.bin' && printf p2 > '%s/.applied'", ER, ER, ER); sh(c2);
        CHECK(s2a_import_state(E) == 0, "⑧b 补齐且 .applied = 清单 → 就绪(0)"); }
      snprintf(c2, sizeof c2, "printf 12345 > '%s/资源包/romfs/x.bin'", D); sh(c2);
      CHECK(s2a_import_state(D) == 0, "⑧ 补齐后应判就绪");
      // ⑨ 审计 P2-2：说明页正文。按过「重新检查」还不行，开头说「刚刚查过」；首次不说（文字手写）
      char hd[1024]; s2a_pack_help_detail(2, 1, hd, sizeof hd); CHECK(!strncmp(hd, "刚刚查过，还是没有完整的资源包。", strlen("刚刚查过，还是没有完整的资源包。")), "⑨ 重新检查后仍缺：开头说刚刚查过");
      s2a_pack_help_detail(2, 0, hd, sizeof hd); CHECK(!strstr(hd, "刚刚查过") && strstr(hd, "外壳"), "⑨ 首次显示：不说刚刚查过");
      s2a_pack_help_detail(3, 1, hd, sizeof hd); CHECK(strstr(hd, "刚刚查过") && strstr(hd, "没传全"), "⑨ 不完整重新检查后：也说刚刚查过");
      // ⑨b #316：英文界面（s2a_ui_zh 回 0）说明页正文出英文（文字手写），且不含中文（11-11 起正文不再提「资源包」文件夹）
      g_ui_zh = 0;
      s2a_pack_help_detail(2, 1, hd, sizeof hd); CHECK(!strncmp(hd, "Checked just now", 16) && strstr(hd, "shell"), "⑨b 英文：重新检查后仍缺 → 「Checked just now」开头、说 shell（实得 %s）", hd);
      s2a_pack_help_detail(3, 0, hd, sizeof hd); CHECK(!strncmp(hd, "Some of the game’s data", strlen("Some of the game’s data")) && !strstr(hd, "Checked"), "⑨b 英文：不完整首次 → 不说 Checked just now（实得 %s）", hd);
      { int cjk = 0; for (unsigned char *q = (unsigned char *)hd; *q; q++) if (*q == 0xE4 || (*q >= 0xE5 && *q <= 0xE9)) cjk = 1; CHECK(!cjk, "⑨b 英文：无中文（实得 %s）", hd); }
      g_ui_zh = 1;
      // ⑩ 审计 P2-7：index.tsv 由 pack/pack.py 与 manifest.json 同写，出包保证在。manifest.json 在而 index.tsv 不在 / 打不开（自环软链 ELOOP，root 下也打不开）/ 读不了（目录，fopen 成功、读 EISDIR）
      //   → 期望都判 3 不完整；旧代码打不开当「老包不核」判 0 就绪。11-02 维护者：说明页不点名 index.tsv 这类内部词（缺哪个只进日志）
      snprintf(D, sizeof D, "%s/imp4", T); snprintf(c2, sizeof c2, "mkdir -p '%s/资源包/ctl' && echo '{}' > '%s/资源包/manifest.json' && echo n > '%s/资源包/ctl/control.nacp'", D, D, D); sh(c2);
      const char *how[3] = {"不在", "打不开", "读不了"};
      for (int k = 0; k < 3; k++) {
          if (k == 1) { snprintf(c2, sizeof c2, "cd '%s/资源包' && ln -s index.tsv index.tsv", D); sh(c2); }
          if (k == 2) { snprintf(c2, sizeof c2, "cd '%s/资源包' && rm index.tsv && mkdir index.tsv", D); sh(c2); }
          int got = s2a_import_state(D); s2a_pack_help_detail(got, 0, hd, sizeof hd);
          CHECK(got == 3 && !strstr(hd, "index.tsv") && strstr(hd, "装到 iPhone"), "⑩ index.tsv %s：期望 3 不完整、说明页不点名 index.tsv、给出「装到 iPhone」 → %d「%s」", how[k], got, hd);
      }
      // ⑪ 解包核对读 index.tsv 打不开（自环软链）→ 期望判失败、unpack.log 写明「index.tsv 打不开」（旧代码按缺 1 个文件报、例子为空）
      snprintf(D, sizeof D, "%s/imp5", T); snprintf(c2, sizeof c2, "mkdir -p '%s/资源包' && printf '{\"version\":2,\"index_sha256\":\"cafe05\"}' > '%s/资源包/manifest.json' && cd '%s/资源包' && ln -s index.tsv index.tsv", D, D, D); sh(c2);
      CHECK(s2a_pack_apply(D) != 0, "⑪ index.tsv 打不开时解包应判失败");
      snprintf(c2, sizeof c2, "tail -1 '%s/unpack.log' | grep -q 'index.tsv 打不开'", D); CHECK(sh(c2) == 0, "⑪ 失败行应写明 index.tsv 打不开"); }
    // ⑫ 11-02 维护者 测试设备2 暗黑3：推送中途点开 App。推送契约（tools/push_pack.sh）：tar 先到、index.tsv 与 manifest.json 最后到。期望按契约手写：
    //   清单没到 / 清单还是已导入那份 / 有包没写完 → 判「还在传」，闸门只等不解（旧闸门见待导入就解 → 下面 ⑫a 复现出 维护者 那页的「index.tsv 打不开 / 返回 -8」）；
    //   清单到齐、包都写完 → 当轮就导入（剃刀 #31：原先还要指纹稳住 ≥ 3 秒）；推送没完且 180 秒没动 → 停住；没有 / 不完整的资源包首轮直接给说明页，1 分钟内在变（访达正拷）→ 等，拷齐 → 就绪
    { char D[2100], R[2200], c2[4096], why[600]; struct s2a_gate_watch w = {0};
      snprintf(D, sizeof D, "%s/imp6", T); snprintf(R, sizeof R, "%s/资源包", D);
      snprintf(c2, sizeof c2, "mkdir -p '%s/.incoming' && cd %s/src && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf '%s/.incoming/1_000.tar' a.txt && printf aa11 > '%s/.applied'", R, T, R, R);
      CHECK(sh(c2) == 0, "⑫ 造推送中夹具失败");
      CHECK(s2a_import_state(D) == 1, "⑫ 有 tar 应判待导入");
      CHECK(s2a_import_transferring(R, why, sizeof why) == 1 && strstr(why, "index.tsv"), "⑫ 清单没到：应判还在传、原因点名 index.tsv →「%s」", why);
      CHECK(s2a_import_decide(D, &w, 1000, why, sizeof why) == S2A_GATE_WAIT && s2a_import_decide(D, &w, 1010, why, sizeof why) == S2A_GATE_WAIT, "⑫ 清单没到：闸门应一直等、不导入");
      // ⑫a 旧闸门（待导入就解）在这一刻解包：失败、点名 index.tsv 打不开——维护者 照片上那页的由来
      snprintf(c2, sizeof c2, "rm -rf '%s/imp6old' && cp -R '%s' '%s/imp6old'", T, D, T); sh(c2); snprintf(c2, sizeof c2, "%s/imp6old", T);
      CHECK(s2a_pack_apply(c2) != 0, "⑫a 推送中途解包应失败（旧行为复现）");
      snprintf(c2, sizeof c2, "tail -1 '%s/imp6old/unpack.log' | grep -q 'index.tsv 打不开.*返回 -8'", T); CHECK(sh(c2) == 0, "⑫a 旧行为失败行应是 index.tsv 打不开、返回 -8");
      snprintf(c2, sizeof c2, "printf 'a.txt\\t3\\tx\\n' > '%s/index.tsv'", R); sh(c2);
      CHECK(s2a_import_transferring(R, why, sizeof why) == 1 && strstr(why, "manifest.json"), "⑫ 只到了 index.tsv：应判还在传、点名 manifest.json →「%s」", why);
      snprintf(c2, sizeof c2, "printf '{\"version\":2,\"index_sha256\":\"aa11\"}' > '%s/manifest.json'", R); sh(c2);
      // iOS 装机剃刀 #24：清单的 index_sha256 = .applied、包都写完 = 同一份清单重推（推送端开推会把清单置空，新清单没到时这里读不出）→ 不算在传，交给解包
      CHECK(s2a_import_transferring(R, why, sizeof why) == 0, "⑫ 清单 = .applied、包写完（同一份清单重推）：不应判还在传 →「%s」", why);
      snprintf(c2, sizeof c2, "printf '{\"version\":2,\"index_sha256\":\"bb22\"}' > '%s/manifest.json'", R); sh(c2);
      CHECK(s2a_import_transferring(R, why, sizeof why) == 0, "⑫ 新清单到齐、包写完：不应判还在传 →「%s」", why);
      w = (struct s2a_gate_watch){0};
      int a0 = s2a_import_decide(D, &w, 2000, why, sizeof why), a1, a2;
      CHECK(a0 == S2A_GATE_IMPORT, "⑫ 推送已完：首轮就导入（剃刀 #31，旧闸门要等稳住 3 秒）→ %d", a0);
      // 有包没写完（推到一半：完整包去掉末尾 1024 字节归档尾）→ 还在传；指纹 180 秒没动 → 停住；包又长了 → 回到等
      snprintf(c2, sizeof c2, "cd '%s/.incoming' && n=$(wc -c < 1_000.tar) && head -c $((n - 1024)) 1_000.tar > 1_001.tar", R); CHECK(sh(c2) == 0, "⑫ 造半截包失败");
      CHECK(s2a_import_transferring(R, why, sizeof why) == 1 && strstr(why, "1_001.tar"), "⑫ 半截包：应判还在传、点名 1_001.tar →「%s」", why);
      w = (struct s2a_gate_watch){0};
      a0 = s2a_import_decide(D, &w, 3000, why, sizeof why); a1 = s2a_import_decide(D, &w, 3089, why, sizeof why); a2 = s2a_import_decide(D, &w, 3090, why, sizeof why);
      CHECK(a0 == S2A_GATE_WAIT && a1 == S2A_GATE_WAIT && a2 == S2A_GATE_STALLED, "⑫ 半截包不动：0 / 89 秒等、90 秒停住（同游戏库 transferStall）→ %d %d %d", a0, a1, a2);
      snprintf(c2, sizeof c2, "head -c 512 /dev/urandom >> '%s/.incoming/1_001.tar'", R); sh(c2);
      CHECK(s2a_import_decide(D, &w, 3200, why, sizeof why) == S2A_GATE_WAIT, "⑫ 半截包又长了：应回到等");
      // 剃刀 #32：推送端直写 game.img（不经 .incoming），传输清单 .transfer 列着它（路径用 \uXXXX 写也认）。镜像在长 → 闸门照样看得见、不报停住；
      //   旧闸门指纹只看 .incoming 与三个小文件，90 秒后（旧阈值 180 秒）误报停住
      snprintf(c2, sizeof c2, "printf x > '%s/game.img' && printf '{\"schema\":1,\"total\":9,\"files\":[[\"game.img\",9],[\"\\u955c\\u50cf.bin\",1]]}' > '%s/.transfer'", R, R); sh(c2);
      w = (struct s2a_gate_watch){0};
      a0 = s2a_import_decide(D, &w, 4000, why, sizeof why);
      snprintf(c2, sizeof c2, "printf y >> '%s/game.img'", R); sh(c2); a1 = s2a_import_decide(D, &w, 4080, why, sizeof why);
      snprintf(c2, sizeof c2, "printf z >> '%s/镜像.bin'", R); sh(c2); a2 = s2a_import_decide(D, &w, 4170, why, sizeof why);   // 只有中文名文件长：离上次 90 秒，没解出 \uXXXX 路径就会判停住
      snprintf(c2, sizeof c2, "printf y >> '%s/game.img'", R); sh(c2); int a3 = s2a_import_decide(D, &w, 4250, why, sizeof why);
      CHECK(a0 == S2A_GATE_WAIT && a1 == S2A_GATE_WAIT && a2 == S2A_GATE_WAIT && a3 == S2A_GATE_WAIT,
            "⑫ 剃刀 #32：.transfer 列的 game.img / 中文名文件轮流长、间隔 80–90 秒、共 250 秒 → 一直等、不报停住 → %d %d %d %d", a0, a1, a2, a3);
      CHECK(s2a_import_decide(D, &w, 4340, why, sizeof why) == S2A_GATE_STALLED, "⑫ 剃刀 #32：最后一次长之后 90 秒都不动 → 停住");
      snprintf(c2, sizeof c2, "rm -f '%s/game.img' '%s/镜像.bin' '%s/.transfer'", R, R, R); sh(c2);
      snprintf(c2, sizeof c2, "%s/.incoming/1_000.tar", R); struct stat s3; CHECK(stat(c2, &s3) == 0, "⑫ 等待期间不应解 / 删任何包");
      // 不完整（没在传）：直接说明页；之后文件变了也不再「当成正在拷」去等（剃刀 #33），补齐 → 就绪
      snprintf(D, sizeof D, "%s/imp7", T); snprintf(R, sizeof R, "%s/资源包", D);
      snprintf(c2, sizeof c2, "mkdir -p '%s/exefs' && echo '{}' > '%s/manifest.json' && printf 'exefs/main.npdm\\t2\\tx\\nexefs/main\\t5\\tx\\n' > '%s/index.tsv' && printf 12 > '%s/exefs/main.npdm'", R, R, R, R); sh(c2);   // 缺的是核心文件（v0.3.1 起非核心缺件算部分可玩）
      w = (struct s2a_gate_watch){0};
      CHECK(s2a_import_decide(D, &w, 100, why, sizeof why) == S2A_GATE_BROKEN, "⑫ 不完整、首轮：应直接说明页");
      snprintf(c2, sizeof c2, "printf 12 > '%s/exefs/main'", R); sh(c2);
      // 维护者 11-17 撤掉「校验不过就整个拒绝」：核心文件在、只是大小和清单不符 → 部分可玩（起局时问玩家仍要启动），不再是说明页
      CHECK(s2a_import_decide(D, &w, 103, why, sizeof why) == S2A_GATE_READY, "⑫ 核心文件在但大小不符：按部分可玩放行（问玩家），不再拦成说明页");
      snprintf(c2, sizeof c2, "printf 12345 > '%s/exefs/main'", R); sh(c2);
      CHECK(s2a_import_decide(D, &w, 170, why, sizeof why) == S2A_GATE_READY, "⑫ 补齐：应就绪");
      snprintf(D, sizeof D, "%s/imp8", T); mkdir(D, 0755); w = (struct s2a_gate_watch){0};
      CHECK(s2a_import_decide(D, &w, 1, why, sizeof why) == S2A_GATE_NONE, "⑫ 没有资源包、首轮：应直接说明页"); }
    snprintf(c, sizeof c, "rm -rf %s", T); sh(c);
    // 资源包闸门按启动上下文定查哪儿（11-07 Duo：多款容器选了游戏后 export_env 写了 S2A_GAME_DATA，原先「设了就不查」→ 资源包不在也照起，服务层 DirectoryNotFound）
    {   s2a_launch_ctx c; char out[1024];
        memset(&c, 0, sizeof c); c.source = S2A_LCTX_CONTAINER; snprintf(c.docs, sizeof c.docs, "%s/home/Documents/games/0100FD70134FA000", T);
        CHECK(s2a_import_docs_pick(&c, 1, "/proc/Documents", out, sizeof out) == 1 && !strcmp(out, c.docs), "多款容器（S2A_GAME_DATA 已由选游戏写进环境）：要查、查本款文档根（得 %s）", out);
        memset(&c, 0, sizeof c); c.source = S2A_LCTX_COMPAT;
        CHECK(s2a_import_docs_pick(&c, 0, "/proc/Documents", out, sizeof out) == 1 && !strcmp(out, "/proc/Documents"), "单款兼容来源、没设 S2A_GAME_DATA：查进程级 Documents（同原先）");
        CHECK(s2a_import_docs_pick(&c, 1, "/proc/Documents", out, sizeof out) == 0, "单款、开发指定了 S2A_GAME_DATA：不查（同原先）");
        c.source = S2A_LCTX_FILE;
        CHECK(s2a_import_docs_pick(&c, 1, "/proc/Documents", out, sizeof out) == 0, "单款文件来源（构造期写了 S2A_GAME_DATA）：不查（同原先）");
        CHECK(s2a_import_docs_pick(NULL, 0, "/proc/Documents", out, sizeof out) == 1 && !strcmp(out, "/proc/Documents"), "上下文不可用、没设 S2A_GAME_DATA：查进程级 Documents");
        // 游戏库按款判（多款容器，资源包在 Library/Application Support/S2Arm/games/<游戏号>/资源包，v0.3.0）：资源包不在 → 没有资源；放好完整资源包 → 就绪；游戏号带 / 或以 . 开头 → 按没有资源（不进路径）
        char h[1024], pd[1100], cmd[4096]; snprintf(h, sizeof h, "%s/home", T); snprintf(pd, sizeof pd, "%s/Documents", h);
        CHECK(s2a_import_state_game(pd, "0100FD70134FA000") == 2, "本款资源包不在 → S2A_IMPORT_NONE(2)");
        snprintf(cmd, sizeof cmd, "mkdir -p %1$s && cd %1$s && mkdir -p 'Library/Application Support/S2Arm/games/0100FD70134FA000/资源包'/exefs && printf x > 'Library/Application Support/S2Arm/games/0100FD70134FA000/资源包'/exefs/main.npdm && "
            "printf 'exefs/main.npdm\t1\tx\n' > 'Library/Application Support/S2Arm/games/0100FD70134FA000/资源包'/index.tsv && printf '{}' > 'Library/Application Support/S2Arm/games/0100FD70134FA000/资源包'/manifest.json", h);
        CHECK(sh(cmd) == 0, "造本款资源包失败");
        CHECK(s2a_import_state_game(pd, "0100FD70134FA000") == 0, "本款资源包完整 → S2A_IMPORT_READY(0)");
        CHECK(s2a_import_state_game(pd, "0100C2500FC20000") == 2, "另一款没放 → 不受这款影响");
        CHECK(s2a_import_state_game(NULL, "0100FD70134FA000") == 2 && s2a_import_state_game(pd, "../x") == 2 && s2a_import_state_game(pd, ".hid") == 2 && s2a_import_state_game(pd, "") == 2, "不合规游戏号 → 按没有资源");
        snprintf(cmd, sizeof cmd, "rm %s/'Library/Application Support/S2Arm/games/0100FD70134FA000/资源包'/exefs/main.npdm", h); sh(cmd);
        CHECK(s2a_import_state_game(pd, "0100FD70134FA000") == 3, "缺 main.npdm（Duo 那种没导完）→ S2A_IMPORT_BROKEN(3)");
        // 库界面快判：.applied 等于清单的 index_sha256 就不逐文件核（主线程上 10 万文件要几秒）；不等 / 没有 .applied 退回完整核对；非法游戏号同完整判据
        { char qc[4096], qr[2300], qd[2300]; snprintf(qd, sizeof qd, "%s/games/0100FD70134FA000", pd); s2a_pack_root(qr, sizeof qr, qd);   // 资源包根（v0.3.0 在 Library 下）
          snprintf(qc, sizeof qc, "printf '{\"version\":2,\"index_sha256\":\"abc123\"}' > '%s/manifest.json' && printf 'abc123' > '%s/.applied'", qr, qr); CHECK(sh(qc) == 0, "造快判夹具失败");
          CHECK(s2a_import_state_game_quick(pd, "0100FD70134FA000") == 3, "快判（审计 P2-212）：.applied 等于清单但缺 main.npdm → 不报就绪，退回完整核对(3)");
          CHECK(s2a_import_state_game(pd, "0100FD70134FA000") == 3, "完整判据不受影响：照旧查出缺文件(3)");
          snprintf(qc, sizeof qc, "printf x > '%s/exefs/main.npdm'", qr); CHECK(sh(qc) == 0, "放回 main.npdm 失败");
          CHECK(s2a_import_state_game_quick(pd, "0100FD70134FA000") == 0, "快判：.applied 等于清单、main.npdm 在 → 就绪(0)，不逐文件核");
          snprintf(qc, sizeof qc, "rm '%s/exefs/main.npdm'", qr); sh(qc);
          snprintf(qc, sizeof qc, "printf 'other' > '%s/.applied'", qr); sh(qc);
          CHECK(s2a_import_state_game_quick(pd, "0100FD70134FA000") == 3, "快判：.applied 不等于清单 → 退回完整核对(3)");
          snprintf(qc, sizeof qc, "rm '%s/.applied'", qr); sh(qc);
          CHECK(s2a_import_state_game_quick(pd, "0100FD70134FA000") == 3, "快判：没有 .applied → 退回完整核对(3)");
          CHECK(s2a_import_state_game_quick(pd, "../x") == 2, "快判：非法游戏号 → 没有资源(2)");
          // 游戏库的装机阶段（s2a_game_install_state：库界面每秒刷新画图块与蒙版，只做便宜判断、不逐文件核对）。期望按夹具逐步手写：
          //   1 就绪 / 2 清单读得出、不在传 → 库后台解开（核对不过报「安装没完成」）/ 3 推包端写了 .transfer、推送没完 → 画进度 / 0 不显示
          #define IS(want, why) CHECK(s2a_game_install_state(pd, "0100FD70134FA000") == (want), why)
          IS(2, "清单读得出、没有 .applied、不在传 → 2 待解开（缺 main.npdm 由库解开时核对报出，不在这里逐文件核）");
          CHECK(s2a_game_install_state(pd, "0100C2500FC20000") == 0, "没放资源 → 0 不显示");
          { char ec[2400]; snprintf(ec, sizeof ec, "mkdir -p '%s/games/0100C2500FC20001/资源包'", pd); sh(ec);
            CHECK(s2a_game_install_state(pd, "0100C2500FC20001") == 0, "剃刀 #26：资源包在但是空的 → 0 不显示（0 只留给这种）"); }
          snprintf(qc, sizeof qc, "printf 'abc123' > '%s/.applied'", qr); sh(qc);
          IS(2, ".applied 等于清单但缺 main.npdm（审计 P2-212）→ 2 待解开（库解开时核对报出缺文件；原先经「新清单没到」判在传、又没有 .transfer → 0 从库里消失，剃刀 #24 / #26）");
          snprintf(qc, sizeof qc, "printf x > '%s/exefs/main.npdm'", qr); sh(qc);
          IS(1, ".applied 等于清单、main.npdm 在 → 1 就绪");
          // D-YGEC（11-17 iOS 0.5.1）：本体 game.img 被截短——头里写整个文件长 1000、实际只有 136 字节头，.applied 仍等于清单。期望：快判、装机阶段都不判就绪；
          //   补回完整（头里写 136）后又就绪。改前：照判就绪（1 / 快判 0），点开服务层才报 IMG 没传完
          snprintf(qc, sizeof qc, "{ printf S2AIMG01; head -c 120 /dev/zero; printf '\\350\\003\\0\\0\\0\\0\\0\\0'; } > '%s/game.img'", qr); sh(qc);
          IS(2, "D-YGEC：本体 game.img 截短（头写 1000、实际 136）→ 不就绪，落到 2 由库重新解开核对");
          CHECK(s2a_import_state_game_quick(pd, "0100FD70134FA000") != 0, "D-YGEC：快判也不判就绪（实际 %d）", s2a_import_state_game_quick(pd, "0100FD70134FA000"));
          snprintf(qc, sizeof qc, "{ printf S2AIMG01; head -c 120 /dev/zero; printf '\\210\\0\\0\\0\\0\\0\\0\\0'; } > '%s/game.img'", qr); sh(qc);
          IS(1, "D-YGEC：本体补回完整（头写 136、实际 136）→ 1 就绪");
          snprintf(qc, sizeof qc, "rm '%s/game.img'", qr); sh(qc);
          snprintf(qc, sizeof qc, "rm '%s/exefs/main.npdm'", qr); sh(qc);
          // 推送包齐了只等解开（11-09 根修 Windows 装完游戏库空：推完起 App 解包没成，.applied 仍是推送开头清空的空文件）
          snprintf(qc, sizeof qc, "mkdir -p '%s/.incoming' && head -c 1024 /dev/zero > '%s/.incoming/1_000.tar' && touch '%s/index.tsv' && printf '' > '%s/.applied'", qr, qr, qr, qr); CHECK(sh(qc) == 0, "造待解开夹具失败");
          IS(2, "包齐、清单到了、.applied 为空（Windows 起 App 解包没成）→ 2，库解开");
          snprintf(qc, sizeof qc, "rm '%s/.applied'", qr); sh(qc);
          IS(2, "包齐、没有 .applied → 2");
          snprintf(qc, sizeof qc, "printf '' > '%s/manifest.json'", qr); sh(qc);
          IS(3, "清单被推送开头置空、没有传输清单（老电脑端推的）→ 3 传输中（剃刀 #26：有数据不再从库里消失，库按文件改动判传断了）");
          snprintf(qc, sizeof qc, "printf '{\"version\":2,\"index_sha256\":\"abc123\"}' > '%s/manifest.json' && printf x > '%s/.incoming/1_000.tar'", qr, qr); sh(qc);
          IS(3, "有包没写完（没有归档尾）、没有传输清单 → 3 传输中（剃刀 #26：原先 0 不显示）");
          snprintf(qc, sizeof qc, "head -c 1024 /dev/zero > '%s/.incoming/1_000.tar' && printf 'abc123' > '%s/.applied'", qr, qr); sh(qc);
          IS(2, "清单 = .applied、包写完（同一份清单重推）、没有传输清单 → 2 待解开（剃刀 #24：原先判在传 → 0 不显示）");
          snprintf(qc, sizeof qc, "printf '{}' > '%s/.transfer'", qr); sh(qc);
          IS(2, "同上 + 推包端写了 .transfer → 仍是 2 待解开（推送已完，.transfer 在也不算传输中）");
          snprintf(qc, sizeof qc, "printf '' > '%s/manifest.json'", qr); sh(qc);
          IS(3, "清单被推送开头置空 + .transfer → 3 传输中");
          snprintf(qc, sizeof qc, "printf '{\"version\":2,\"index_sha256\":\"def456\"}' > '%s/manifest.json'", qr); sh(qc);
          IS(2, "新清单到了、包写完 → 2 只等解开（.transfer 还在也不算传输中）");
          CHECK(s2a_game_install_state(pd, "../x") == 0 && s2a_game_install_state(NULL, "0100FD70134FA000") == 0, "非法游戏号 / 没有文档根 → 0");
          snprintf(qc, sizeof qc, "rm -rf '%s/.incoming' && printf x > '%s/exefs/main.npdm' && printf 'def456' > '%s/.applied'", qr, qr, qr); sh(qc);
          IS(1, "已应用 → 1 就绪");
          #undef IS
          // 解开成功顺手删掉传输清单（库不再按它画进度）：用 s2a_pack_apply 真解一次空待解包目录
          { char dd[2300]; snprintf(dd, sizeof dd, "%s/games/0100FD70134FA000", pd);
            snprintf(qc, sizeof qc, "printf '{}' > '%s/.transfer' && printf '' > '%s/.applied' && printf 'exefs/main.npdm\t1\tx\n' > '%s/index.tsv'", qr, qr, qr); sh(qc);
            CHECK(s2a_pack_apply(dd) == 0, "没有待解包时 s2a_pack_apply 只核对、写 .applied（只直写镜像的推送）");
            snprintf(qc, sizeof qc, "test ! -e '%s/.transfer'", qr); CHECK(sh(qc) == 0, "解开成功后 .transfer 已删");
            CHECK(s2a_game_install_state(pd, "0100FD70134FA000") == 1, "解开后 → 1 就绪"); } }
    }
    // ⑬ 单一 IMG v1（资源包根 game.img，pack/img.py 写）：exefs / ctl 等小文件一次性解到资源包根。夹具现造（不含 RomFS 段，不要 dotnet），期望 = 夹具文件本身：
    //   a 应用前导入状态 = 待导入（IMG 到了、小文件没解）；b s2a_pack_apply 成功、小文件逐字节同夹具、romfs.list 不解、.applied = manifest 的 index_sha256；
    //   c 解出的文件没被「清掉不在 index.tsv 里的旧文件」删掉，应用后状态就绪；d 再应用一次不重写（修改时间不变）；e 格式号 9 → 解包失败、原因带「格式号」
    { char R[1024]; snprintf(R, sizeof R, "%s", __FILE__); char *cut = strstr(R, "runtime/tests/"); if (cut) *cut = 0; if (!R[0]) strcpy(R, "./");
      char D[1200], G[1300], c[6000]; snprintf(D, sizeof D, "%s/img_docs", T); snprintf(G, sizeof G, "%s/资源包", D);
      snprintf(c, sizeof c, "mkdir -p '%s/src' '%s/shaders/direct' && head -c 5000 /dev/urandom > '%s/src/npdm' && printf NACP > '%s/src/nacp' && printf k > '%s/shaders/direct/keys.tsv'"
               " && printf 'exefs/main.npdm\t%s/src/npdm\nctl/control.nacp\t%s/src/nacp\n' > '%s/src/others.tsv'"
               " && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/game.img' --gid 0100abcd00000000 --pack-id img123 > /dev/null"
               " && printf 'game.img\t%%s\tx\nshaders/direct/keys.tsv\t1\tx\n' $(stat -f %%z '%s/game.img' 2>/dev/null || stat -c %%s '%s/game.img') > '%s/index.tsv'"
               " && printf '{\"version\":3,\"format\":\"img\",\"imgFile\":\"game.img\",\"index_sha256\":\"img123\"}' > '%s/manifest.json'",
               D, G, D, D, G, D, D, D, R, D, G, G, G, G, G); CHECK(sh(c) == 0, "⑬ 造 IMG 夹具");
      CHECK(s2a_import_state(D) == 1, "⑬a 应用前 → 待导入（状态 %d）", s2a_import_state(D));
      CHECK(s2a_pack_apply(D) == 0, "⑬b s2a_pack_apply 成功");
      snprintf(c, sizeof c, "cmp -s '%s/src/npdm' '%s/exefs/main.npdm' && cmp -s '%s/src/nacp' '%s/ctl/control.nacp' && test ! -e '%s/romfs.list' && test \"$(cat '%s/.applied')\" = img123",
               D, G, D, G, G, G); CHECK(sh(c) == 0, "⑬b 小文件逐字节同夹具、romfs.list 不解、.applied = img123");
      CHECK(s2a_import_state(D) == 0, "⑬c 应用后 → 就绪（状态 %d，解出的文件没被清旧文件删掉）", s2a_import_state(D));
      snprintf(c, sizeof c, "touch -t 202001010000 '%s/exefs/main.npdm'", G); sh(c);
      CHECK(s2a_pack_apply(D) == 0, "⑬d 再应用一次成功");
      snprintf(c, sizeof c, "test \"$(stat -f %%m '%s/exefs/main.npdm' 2>/dev/null || stat -c %%Y '%s/exefs/main.npdm')\" = \"$(date -j -f %%Y%%m%%d%%H%%M%%S 20200101000000 +%%s 2>/dev/null || date -d 2020-01-01T00:00 +%%s)\"", G, G);
      CHECK(sh(c) == 0, "⑬d 已在且长度对的不重写（修改时间不变）");
      snprintf(c, sizeof c, "printf '\\011' | dd of='%s/game.img' bs=1 seek=8 conv=notrunc 2>/dev/null && rm -rf '%s/exefs' && printf '' > '%s/.applied'", G, G, G); sh(c);
      CHECK(s2a_pack_apply(D) == 0, "⑬e 格式号 9（维护者 11-17：版本号不认不再整个拒绝）→ 打一行后按格式 1 照常解开");
      { // ⑬f D-4VAX（本体目录表路径区错位：表里出现「…/0100000000000823/」这种相邻两条路径首尾拼成的一截，原先当文件写 → 每次同一处 -4 EISDIR）：
        //   读表自检，路径以「/」结尾 / 有重复路径 = 本体被改坏 → 不硬解，判 IMG 坏（码 ios_install_img_corrupt），现场写明。期望手写
        // 两条都先用 img.py 造合法表、再在文件里改字节（img.py 自己不写「/」结尾项、也不写重复项，见 pack/img.py toc_bytes）：
        //   0：末字符 X 改成「/」；1：npdX 改成 npdm，和第一行重复
        const char *bad8[2] = {"823/ac_2_b1_nxsystemdata/0100000000000823X", "exefs/main.npdX"};
        const char *from8[2] = {"0100000000000823X", "exefs/main.npdX"}, *to8[2] = {"0100000000000823/", "exefs/main.npdm"};
        const char *expect8[2] = {"IMG 目录表路径不对", "IMG 目录表有重复路径"};
        for (int v = 0; v < 2; v++) {
            char D8[1300], G8[1400]; snprintf(D8, sizeof D8, "%s/img_docs8_%d", T, v); snprintf(G8, sizeof G8, "%s/资源包", D8);
            snprintf(c, sizeof c, "mkdir -p '%s' && : > '%s/src/empty' && printf 'exefs/main.npdm\t%s/src/npdm\nctl/control.nacp\t%s/src/nacp\n%s\t%s/src/empty\n' > '%s/src/others_bad%d.tsv'"
                     " && python3 '%s/pack/img.py' build - '%s/src/others_bad%d.tsv' '%s/game.img' --gid 0100abcd0000000a --pack-id img8 > /dev/null"
                     " && printf 'game.img\t%%s\tx\n' $(stat -f %%z '%s/game.img' 2>/dev/null || stat -c %%s '%s/game.img') > '%s/index.tsv'"
                     " && printf '{\"version\":3,\"format\":\"img\",\"imgFile\":\"game.img\",\"index_sha256\":\"img8\"}' > '%s/manifest.json'",
                     G8, D, D, D, bad8[v], D, D, v, R, D, v, G8, G8, G8, G8, G8);
            int built = sh(c) == 0;
            if (built) { snprintf(c, sizeof c, "python3 -c \"import sys;p=sys.argv[1];b=open(p,'rb').read();assert b.count(b'%s')==1;open(p,'wb').write(b.replace(b'%s',b'%s'))\" '%s/game.img'", from8[v], from8[v], to8[v], G8); built = sh(c) == 0; }
            int r8 = built ? s2a_pack_apply(D8) : 99;
            CHECK(built && r8 != 0 && !strcmp(s2a_pack_apply_code(), "ios_install_img_corrupt") && strstr(s2a_pack_apply_failure(), expect8[v]),
                  "⑬f 坏表 %d：不硬解、判 IMG 坏、现场写「%s」（造 %d、返回 %d、码 %s「%s」）", v, expect8[v], built, r8, s2a_pack_apply_code(), s2a_pack_apply_failure());
            if (built && v == 1) {   // ⑬g 同一份坏 IMG 是从「放这里导入」认领来的（.imported 与清单同号）→ 码换导入那条；号对不上（之后电脑推送重写过清单）→ 照旧推送那条
                snprintf(c, sizeof c, "cp '%s/manifest.json' '%s/.imported'", G8, G8); sh(c); s2a_pack_apply(D8);
                CHECK(!strcmp(s2a_pack_apply_code(), "ios_import_img_corrupt"), "⑬g 导入来的坏 IMG → ios_import_img_corrupt（码 %s）", s2a_pack_apply_code());
                snprintf(c, sizeof c, "printf '{\"index_sha256\": \"old\"}' > '%s/.imported'", G8); sh(c); s2a_pack_apply(D8);
                CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_img_corrupt"), "⑬g 导入号与清单不同（电脑推送过）→ ios_install_img_corrupt（码 %s）", s2a_pack_apply_code());
            }
        }
      }
      // ⑭ 玩家把 IMG 放进「文件」里 S2Arm 的「放这里导入」文件夹：s2a_img_scan 挪进 games/<头里的游戏号>/资源包/game.img、写 manifest（资源包号同头）与 index.tsv；
      //   拷到一半的（长度不等于头里的整个文件长）不动；导入文件夹以外的（Documents/下载）不扫、不动（v0.3.0）；挪好后应用成功
      char D3[1300]; snprintf(D3, sizeof D3, "%s/scan_docs", T);   // 小文件清单借 ⑬ 的夹具（exefs/main.npdm = 随机 5000 字节、ctl = NACP）
      // 带着色器库（目录表里有 shaders/，= 导出文件夹里的 <游戏名>.img）：不带的认领时不收，见 ⑭b
      snprintf(c, sizeof c, "printf 'x' > '%s/src/sh.bin' && cp '%s/src/others.tsv' '%s/src/others_sh.tsv' && printf 'shaders/a.metallib\t%s/src/sh.bin\n' >> '%s/src/others_sh.tsv'", D, D, D, D, D);
      CHECK(sh(c) == 0, "⑭ 造带 shaders/ 的清单");
      snprintf(c, sizeof c, "mkdir -p '%s/放这里导入/x' '%s/下载' && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/x/某游戏.img' --gid 0100abcd00000002 --pack-id img789 > /dev/null"
               " && head -c 20000 '%s/放这里导入/x/某游戏.img' > '%s/放这里导入/半个.img'"
               " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/下载/别处.img' --gid 0100abcd00000003 --pack-id img790 > /dev/null", D3, D3, R, D, D3, D3, D3, R, D, D3);
      CHECK(sh(c) == 0, "⑭ 造夹具（导入文件夹第二层一个完整 IMG、导入文件夹下一个拷到一半的、导入文件夹外一个完整 IMG）");
      CHECK(s2a_img_scan(D3) == 1, "⑭ 扫到并挪好 1 个");
      snprintf(c, sizeof c, "g='%s/games/0100ABCD00000002/资源包'; test -s \"$g/game.img\" && test ! -e '%s/放这里导入/x/某游戏.img' && test -e '%s/放这里导入/半个.img' && test -e '%s/下载/别处.img' && test ! -e '%s/games/0100ABCD00000003' && grep -q '\"index_sha256\": \"img789\"' \"$g/manifest.json\" && cmp -s \"$g/manifest.json\" \"$g/.imported\" && test \"$(cut -f1 \"$g/index.tsv\")\" = game.img", D3, D3, D3, D3, D3);
      CHECK(sh(c) == 0, "⑭ 落到 games/<游戏号>/资源包/game.img、manifest 资源包号 = 头里的、.imported 同清单、index.tsv 只有 game.img、拷一半的没动");
      { char g3[1500]; snprintf(g3, sizeof g3, "%s/games/0100ABCD00000002", D3);
        CHECK(s2a_import_state(g3) == 1, "⑭ 挪好后 → 待导入（状态 %d）", s2a_import_state(g3));
        s2a_pack_apply_phase = phase; memset(g_ph, 0, sizeof g_ph); memset(g_phn, 0, sizeof g_phn);
        CHECK(s2a_pack_apply(g3) == 0, "⑭ 应用成功");
        s2a_pack_apply_phase = NULL;
        // 分段进度（游戏库「安装中」蒙版）：② 从 game.img 解小文件按字节报到满（exefs/main.npdm 5000 + ctl/control.nacp 4 + shaders/a.metallib 1）；③ 核对机上文件报到满；没有推送包不报 ①
        CHECK(g_phn[2] > 0 && g_ph[2][0] == g_ph[2][1] && g_ph[2][1] == 5005, "⑭ 分段进度 ② 解小文件 %llu / %llu（期望 5005 / 5005）", (unsigned long long)g_ph[2][0], (unsigned long long)g_ph[2][1]);
        CHECK(g_phn[3] > 0 && g_ph[3][0] == g_ph[3][1] && g_ph[3][1] >= 1, "⑭ 分段进度 ③ 核对 %llu / %llu", (unsigned long long)g_ph[3][0], (unsigned long long)g_ph[3][1]);
        CHECK(g_phn[1] == 0, "⑭ 没有推送包不报 ①（报了 %d 次）", g_phn[1]);
        snprintf(c, sizeof c, "cmp -s '%s/src/npdm' '%s/资源包/exefs/main.npdm'", D, g3); CHECK(sh(c) == 0, "⑭ 小文件逐字节解出"); }
      CHECK(s2a_img_scan(D3) == 0, "⑭ 再扫一次：没有新的（拷到一半的仍不动）");
      { // ⑭h D-4VAX 复现：拷贝方先把目标撑到全长、再从头往后填（长度已等于头里的总长，尾巴的目录表还是 0）——原先照样认领挪走，
        //   之后解包 / 套更新包读到半截目录表。期望手写：撑到全长只写了前一半 → 认领 0 个、文件原样留在导入文件夹；补写完 → 认领 1 个
        char D9[1300]; snprintf(D9, sizeof D9, "%s/scan_docs9", T);
        snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/full.img' --gid 0100abcd0000000b --pack-id img9 > /dev/null"
                 " && python3 -c \"import os,sys;s,d=sys.argv[1],sys.argv[2];b=open(s,'rb').read();fd=os.open(d,os.O_WRONLY|os.O_CREAT,0o644);os.ftruncate(fd,len(b));os.write(fd,b[:len(b)//2]);os.close(fd)\" '%s/full.img' '%s/放这里导入/半截.img'",
                 D9, R, D, D9, D9, D9);
        CHECK(sh(c) == 0, "⑭h 造撑到全长的半截 IMG");
        int h0 = s2a_img_scan(D9);
        snprintf(c, sizeof c, "test -e '%s/放这里导入/半截.img'", D9); int stay = sh(c) == 0;
        CHECK(h0 == 0 && stay, "⑭h 半截（长度对、目录表还是 0）：认领 0 个（实际 %d）、原样留着（%s）", h0, stay ? "留着" : "被挪走了");
        snprintf(c, sizeof c, "cp '%s/full.img' '%s/放这里导入/半截.img'", D9, D9); sh(c);
        CHECK(s2a_img_scan(D9) == 1, "⑭h 补写完：认领 1 个"); }

      CHECK(!*s2a_img_scan_code(), "⑭ 认领没失败：码为空（实际 %s）", s2a_img_scan_code());
      // ⑭b 认领时有没有着色器库（诊断 D-9864 / D-F6W7 / D-9ZF9：自签玩家把电脑资源包文件夹里的 game.img 直接放进来）。物理上做得下去（现编），
      //   一律认领、不拦（不许堵门）；不带着色器库的只记一行【黄】（换完整包的提示由游戏库那边弹）。期望手写：三个都认领；
      //   只对不带 shaders/、机上也没有这款着色器库的 game.img 记一行【黄】；机上已有着色器库的那款，原有着色器库行保留在 index.tsv
      { char D5[1300], lg[1400]; snprintf(D5, sizeof D5, "%s/img_docs5", T); snprintf(lg, sizeof lg, "%s/scan5.log", T);
        snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' '%s/games/0100ABCD00000007/资源包'"
                 " && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/放这里导入/game.img' --gid 0100abcd00000005 --pack-id img501 > /dev/null"
                 " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/某游戏.img' --gid 0100abcd00000006 --pack-id img601 > /dev/null"
                 " && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/放这里导入/重拷.img' --gid 0100abcd00000007 --pack-id img701 > /dev/null"
                 " && printf 'game.img\t1\t-\nshaders/a.metallib\t1\tx\n' > '%s/games/0100ABCD00000007/资源包/index.tsv'",
                 D5, D5, R, D, D5, R, D, D5, R, D, D5, D5);
        CHECK(sh(c) == 0, "⑭b 造夹具（不带 shaders/、带 shaders/、不带但机上已有着色器库的 IMG 各一个）");
        int lfd = open(lg, O_WRONLY | O_CREAT | O_TRUNC, 0644), keep = g_s2a_logfd; g_s2a_logfd = lfd;
        int placed = s2a_img_scan(D5); g_s2a_logfd = keep; close(lfd);
        CHECK(placed == 3, "⑭b 三个都认领（实际 %d）", placed);
        CHECK(!*s2a_img_scan_code(), "⑭b 认领没失败：码为空（实际 %s）", s2a_img_scan_code());
        snprintf(c, sizeof c, "grep '没有着色器库' '%s' | grep -q 'game.img 里' && test \"$(grep -c '没有着色器库' '%s')\" = 1", lg, lg);
        CHECK(sh(c) == 0, "⑭b 只对不带 shaders/、机上也没有的 game.img 记一行【黄】");
        snprintf(c, sizeof c, "grep -q 'shaders/a.metallib' '%s/games/0100ABCD00000007/资源包/index.tsv'", D5);
        CHECK(sh(c) == 0, "⑭b 机上已有的着色器库行保留在 index.tsv");
        { const char *s2a_img_scan_noshaders(void); CHECK(!strcmp(s2a_img_scan_noshaders(), "game.img"), "⑭b 不带着色器的文件名给界面 = game.img（实际「%s」）", s2a_img_scan_noshaders()); } }
      // ⑭s 同一个导入文件夹里有同款的 .s2arm（派生件 index.tsv 带着色器库行）和不带 shaders/ 的 .img（导出两件套）：先导 .s2arm、再认领 IMG，
      //   着色器库行留在 index.tsv，不记「没有着色器库」。期望手写：认领 2 个、日志里 0 行「没有着色器库」、界面文件名为空、index.tsv 有 shaders/a 行。
//   文件名取 Game.*：APFS 上 readdir 先列 Game.img（实测；Slay.* 先列 .s2arm），不按次序处理时这一例会红
      if (zstd_pick()) { char Ds[1300], lg[1400]; snprintf(Ds, sizeof Ds, "%s/s2hs/Documents", T); snprintf(lg, sizeof lg, "%s/scans.log", T);
        snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/放这里导入/Game.img' --gid 0100abcde0000000 --pack-id imgs01 > /dev/null", Ds, R, D, Ds);
        CHECK(sh(c) == 0, "⑭s 造不带 shaders/ 的 IMG");
        char sp2[1500]; snprintf(sp2, sizeof sp2, "%s/放这里导入/Game.s2arm", Ds); s2arm_pack(T, sp2, "s2arm.json", NULL);
        int lfd = open(lg, O_WRONLY | O_CREAT | O_TRUNC, 0644), keep = g_s2a_logfd; g_s2a_logfd = lfd;
        int placed = s2a_img_scan(Ds); g_s2a_logfd = keep; close(lfd);
        snprintf(c, sizeof c, "test \"$(grep -c '没有着色器库' '%s')\" = 0 && grep -q '^shaders/a' '%s/../Library/Application Support/S2Arm/games/0100ABCDE0000000/资源包/index.tsv'", lg, Ds);
        const char *s2a_img_scan_noshaders(void);
        CHECK(placed == 2 && sh(c) == 0 && !*s2a_img_scan_noshaders(), "⑭s .s2arm + .img 同文件夹：认领 %d 个（期望 2）、不报没有着色器库、index.tsv 留着色器行（界面文件名「%s」）", placed, s2a_img_scan_noshaders()); }
      // ⑭i 0.6.0 截掉导入本体里重复的派生件：导出格式的 .img（pack/img.py export：电脑资源包的 game.img + 尾部追加 shaders/、game.imgmap 进目录表）导入并解开后，
      //   派生件解成文件、本体尾部那份截掉。期望手写：解开成功；本体比导入时小；本体目录表里没有 shaders/ 与 game.imgmap、其余条目与原资源包 game.img 的完全一样；
      //   头里整长 = 文件长；index.tsv 有 shaders/a.metallib 行、game.img 那行长度 = 文件长；解出的 game.imgmap 头里记的整长 = 本体文件长；再应用一次仍成功、本体不变
      { char Di[1300]; snprintf(Di, sizeof Di, "%s/img_docsi", T);
        snprintf(c, sizeof c, "set -e; P='%s/pk'; mkdir -p \"$P/shaders\" '%s/放这里导入'; printf 'metallib-bytes-xyz' > \"$P/shaders/a.metallib\""
                 " && python3 '%s/pack/img.py' build - '%s/src/others.tsv' \"$P/game.img\" --gid 0100abcd0000000c --pack-id imgc01 > /dev/null"
                 " && python3 -c \"import struct,sys,os;p=sys.argv[1];t=os.path.getsize(p+'/game.img');open(p+'/game.imgmap','wb').write(b'S2ARIM01'+struct.pack('<qi',t,0));"
                 "open(p+'/index.tsv','w').write('game.img\\t%%d\\timgc01\\nshaders/a.metallib\\t18\\t-\\n' %% t)\" \"$P\""
                 " && python3 -c \"import sys;sys.path.insert(0,sys.argv[1]+'/pack');import img;img.export(sys.argv[2],sys.argv[3])\" '%s' \"$P\" '%s/放这里导入/导出.img'"
                 " && python3 '%s/pack/img.py' ls \"$P/game.img\" | sort > '%s/orig.ls'", Di, Di, R, D, R, Di, R, Di);
        CHECK(sh(c) == 0, "⑭i 造导出格式的 .img（本体 + shaders/a.metallib + game.imgmap）");
        struct stat ei; char ef[1500]; snprintf(ef, sizeof ef, "%s/放这里导入/导出.img", Di); long long big = stat(ef, &ei) ? -1 : (long long)ei.st_size;
        CHECK(s2a_img_scan(Di) == 1, "⑭i 认领");
        char gi[1500]; snprintf(gi, sizeof gi, "%s/games/0100ABCD0000000C", Di);
        CHECK(s2a_pack_apply(gi) == 0, "⑭i 解开（%s）", s2a_pack_apply_failure());
        snprintf(c, sizeof c, "set -e; g='%s/资源包'; s=$(stat -f %%z \"$g/game.img\"); test \"$s\" -lt %lld"
                 " && python3 '%s/pack/img.py' ls \"$g/game.img\" | sort | cmp -s - '%s/orig.ls'"
                 " && python3 -c \"import sys,struct;b=open(sys.argv[1],'rb').read();sys.exit(0 if struct.unpack_from('<Q',b,128)[0]==len(b) else 1)\" \"$g/game.img\""
                 " && grep -q \"^game.img\t$s\t\" \"$g/index.tsv\" && grep -q '^shaders/a.metallib\t18\t-' \"$g/index.tsv\""
                 " && test \"$(cat \"$g/shaders/a.metallib\")\" = metallib-bytes-xyz"
                 " && python3 -c \"import sys,struct;sys.exit(0 if struct.unpack_from('<q',open(sys.argv[1],'rb').read(),8)[0]==int(sys.argv[2]) else 1)\" \"$g/game.imgmap\" \"$s\"",
                 gi, big, R, Di);
        CHECK(sh(c) == 0, "⑭i 本体变小、目录表只剩原条目、头里整长 = 文件长、index.tsv 记派生件且 game.img 长度对、着色器内容对、偏移表整长 = 本体长");
        snprintf(c, sizeof c, "shasum '%s/资源包/game.img' > '%s/after1.sha'", gi, Di); sh(c);
        CHECK(s2a_pack_apply(gi) == 0, "⑭i 再应用一次仍成功");
        snprintf(c, sizeof c, "shasum '%s/资源包/game.img' | cmp -s - '%s/after1.sha'", gi, Di);
        CHECK(sh(c) == 0, "⑭i 再应用一次本体不变"); }
      // 格式号 9（更新版 S2Arm 做的；2 是着色器更新包，见 ⑭c）：不认、原样留着，给码 ios_install_img_format
      char D4[1300], f4[1400]; snprintf(D4, sizeof D4, "%s/img_docs4", T); mkdir(D4, 0755); snprintf(f4, sizeof f4, "%s/Import Here", D4); mkdir(f4, 0755);
      snprintf(f4, sizeof f4, "%s/Import Here/新格式.img", D4);   // 英文界面建的导入文件夹名也认
      FILE *o4 = fopen(f4, "wb"); uint8_t h4[8192] = {0}; memcpy(h4, "S2AIMG01", 8); h4[8] = 9; memcpy(h4 + 16, "0100ABCD00000000", 16); uint64_t tot = sizeof h4; memcpy(h4 + 128, &tot, 8);
      CHECK(o4 && fwrite(h4, 1, sizeof h4, o4) == sizeof h4 && !fclose(o4), "造格式号 9 的 IMG");
      { int r9 = s2a_img_scan(D4);   // 维护者 11-17：版本号不认不再整个拒收——按格式 1 照常收进库（真读不出的在解包 / 起局时按原因报）
        CHECK(r9 == 1 && access(f4, F_OK) && !*s2a_img_scan_code(), "格式号 9：照常导入 1 个、文件挪进库、不给拒收码（实际 %d、%s、码「%s」）",
              r9, access(f4, F_OK) ? "已挪走" : "还在", s2a_img_scan_code()); }
      // ⑮ 外部游戏来源（11-22 维护者：游戏库设置里加的来源文件夹，如外接硬盘；s2a_img_scan_source / s2a_pack_source_forget）。期望手写：
      //   a 扫来源：两层内两份完整 .img（扩展名大小写不论）链上（返回 2）；拷一半的、不叫 .img 的、第三层的不认；本体是软链接指向来源里的文件、
      //     .source = 来源号\t相对路径\t资源包号、清单资源包号 = 头里的、index.tsv 首行 game.img；外部文件字节不变
      //   b 等解开(2) → 解开成功 → 就绪(1)、小文件逐字节同夹具；外部文件仍不变（导入来的本体会截派生件，外部来源不做）
      //   c 再扫：同一份不重链（返回 0）  d 来源离线（文件夹挪走）→ 装机状态 5、快判不报就绪、扫来源返回 -1
      //   e 换路径回来（外接盘重新挂载）→ 两款只改软链接（返回 2）、不重解、状态回 1
      //   f 同款从导入文件夹认领进 App：软链接换成真文件、.source 删掉、外部文件不变；之后再扫来源不改回软链接
      //   g 移除来源：从它链来的款（只剩甲）资源包根删掉 → 状态 0，外部文件不动、乙不受影响；别的来源号拆 0 款
      //   h 库里删过的款：例行扫描（带跳过名单）不链回来，主动加文件夹（不带名单）链回来
      //   i 同一来源里同款两份：只链新的、再扫不动  j 两个来源各有一份：不抢；链着的那份打不开才换，插回不换回
      //   k 来源里的 .s2arm：导进 App、盘上的不删、同一个文件不重导、改过重导
      { char E[1300], ED[1400], EV[1400], EV2[1400], rA[1600], rB[1600], rC[1600], gA[1500], gB[1500], gC[1500], lk[2000], tgt[2000], want[2000];
        snprintf(E, sizeof E, "%s/exth/Documents", T); snprintf(ED, sizeof ED, "%s/ext_drive", T); snprintf(EV, sizeof EV, "%s/ext_gone", T); snprintf(EV2, sizeof EV2, "%s/ext_drive2", T);
        snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' '%s/sub' '%s/a/b/c' && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/sub/甲.img' --gid 0100abcd000000e1 --pack-id ext1 > /dev/null"
                 " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/a/b/乙.IMG' --gid 0100abcd000000e2 --pack-id ext2 > /dev/null"
                 " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/a/b/c/深.img' --gid 0100abcd000000e3 --pack-id ext3 > /dev/null"
                 " && head -c 20000 '%s/sub/甲.img' > '%s/半个.img' && cp '%s/sub/甲.img' '%s/sub/甲.txt' && cp '%s/sub/甲.img' '%s/甲_原样.bin' && cp '%s/a/b/乙.IMG' '%s/乙_原样.bin'",
                 E, ED, ED, R, D, ED, R, D, ED, R, D, ED, ED, ED, ED, ED, ED, T, ED, T);
        CHECK(sh(c) == 0, "⑮ 造来源文件夹夹具");
        snprintf(gA, sizeof gA, "%s/games/0100ABCD000000E1", E); snprintf(gB, sizeof gB, "%s/games/0100ABCD000000E2", E); snprintf(gC, sizeof gC, "%s/games/0100ABCD000000E3", E);
        s2a_pack_root(rA, sizeof rA, gA); s2a_pack_root(rB, sizeof rB, gB); s2a_pack_root(rC, sizeof rC, gC);
        int ne = s2a_img_scan_source(E, ED, "src1", NULL);
        CHECK(ne == 2, "⑮a 扫来源链上 2 款（实际 %d）", ne);
        snprintf(lk, sizeof lk, "%s/game.img", rA); ssize_t tk = readlink(lk, tgt, sizeof tgt - 1); tgt[tk > 0 ? tk : 0] = 0; snprintf(want, sizeof want, "%s/sub/甲.img", ED);
        CHECK(tk > 0 && !strcmp(tgt, want), "⑮a 本体是软链接、指向来源里的文件（实际「%s」）", tgt);
        snprintf(c, sizeof c, "test \"$(cat '%s/.game.img.source')\" = \"$(printf 'src1\\tsub/甲.img\\text1')\" && grep -q '\"index_sha256\": \"ext1\"' '%s/manifest.json'"
                 " && test \"$(head -1 '%s/index.tsv' | cut -f1,3)\" = \"$(printf 'game.img\\t-')\" && test -L '%s/game.img' && test ! -e '%s' && cmp -s '%s/sub/甲.img' '%s/甲_原样.bin'",
                 rA, rA, rA, rB, rC, ED, T);
        CHECK(sh(c) == 0, "⑮a .source、清单资源包号、index.tsv 首行对，乙也是软链接，第三层的没链，外部文件字节不变");
        CHECK(s2a_game_install_state(E, "0100ABCD000000E1") == 2, "⑮b 链上后等解开(2)（实际 %d）", s2a_game_install_state(E, "0100ABCD000000E1"));
        CHECK(s2a_pack_apply(gA) == 0, "⑮b 解开成功：%s", s2a_pack_apply_failure());
        CHECK(s2a_game_install_state(E, "0100ABCD000000E1") == 1, "⑮b 解开后就绪(1)（实际 %d）", s2a_game_install_state(E, "0100ABCD000000E1"));
        snprintf(c, sizeof c, "cmp -s '%s/src/npdm' '%s/exefs/main.npdm' && cmp -s '%s/sub/甲.img' '%s/甲_原样.bin' && test -L '%s/game.img'", D, rA, ED, T, rA);
        CHECK(sh(c) == 0, "⑮b 小文件逐字节解出、外部文件仍不变（没截派生件）、本体仍是软链接");
        CHECK(s2a_img_scan_source(E, ED, "src1", NULL) == 0, "⑮c 再扫同一份不重链");
        CHECK(rename(ED, EV) == 0, "⑮d 挪走来源文件夹");
        CHECK(s2a_game_install_state(E, "0100ABCD000000E1") == 5, "⑮d 来源离线 → 5（实际 %d）", s2a_game_install_state(E, "0100ABCD000000E1"));
        CHECK(s2a_import_state_game_quick(E, "0100ABCD000000E1") != 0, "⑮d 离线时快判不报就绪");
        CHECK(s2a_img_scan_source(E, ED, "src1", NULL) == -1, "⑮d 来源文件夹打不开 → -1");
        CHECK(rename(EV, EV2) == 0, "⑮e 换个路径放回来");
        ne = s2a_img_scan_source(E, EV2, "src1", NULL);
        tk = readlink(lk, tgt, sizeof tgt - 1); tgt[tk > 0 ? tk : 0] = 0; snprintf(want, sizeof want, "%s/sub/甲.img", EV2);
        CHECK(ne == 2 && !strcmp(tgt, want), "⑮e 两款只改软链接（返回 %d，指向「%s」）", ne, tgt);
        CHECK(s2a_game_install_state(E, "0100ABCD000000E1") == 1, "⑮e 不重解、状态回 1（实际 %d）", s2a_game_install_state(E, "0100ABCD000000E1"));
        snprintf(c, sizeof c, "cp '%s/乙_原样.bin' '%s/放这里导入/乙.img'", T, E); sh(c);
        CHECK(s2a_img_scan(E) == 1, "⑮f 导入文件夹认领乙");
        snprintf(c, sizeof c, "test -f '%s/game.img' && test ! -L '%s/game.img' && test ! -e '%s/.game.img.source' && cmp -s '%s/a/b/乙.IMG' '%s/乙_原样.bin'", rB, rB, rB, EV2, T);
        CHECK(sh(c) == 0, "⑮f 乙的软链接换成真文件、.source 删掉、外部文件不变");
        CHECK(s2a_img_scan_source(E, EV2, "src1", NULL) == 0, "⑮f 再扫来源：App 内已有本体的乙不改回软链接");
        snprintf(c, sizeof c, "test ! -L '%s/game.img'", rB); CHECK(sh(c) == 0, "⑮f 乙仍是 App 内的真文件");
        CHECK(s2a_pack_source_forget(E, "src9") == 0, "⑮g 别的来源号拆 0 款");
        CHECK(s2a_pack_source_forget(E, "src1") == 1, "⑮g 移除来源拆 1 款（甲）");
        snprintf(c, sizeof c, "test ! -e '%s' && cmp -s '%s/sub/甲.img' '%s/甲_原样.bin' && test -f '%s/game.img'", rA, EV2, T, rB);
        CHECK(sh(c) == 0, "⑮g 甲的资源包根删掉、外部文件不动、乙不受影响");
        CHECK(s2a_game_install_state(E, "0100ABCD000000E1") == 0, "⑮g 移除后甲 → 0（实际 %d）", s2a_game_install_state(E, "0100ABCD000000E1"));
        // h 玩家在库里删过甲：例行扫描带跳过名单 → 不链回来；玩家主动加文件夹（不带名单）→ 链回来
        CHECK(s2a_img_scan_source(E, EV2, "src2", "0100ABCD00000099,0100ABCD000000E1") == 0, "⑮h 删过的甲：例行扫描不链回来");
        snprintf(c, sizeof c, "test ! -e '%s'", rA); CHECK(sh(c) == 0, "⑮h 甲的资源包根仍不在");
        CHECK(s2a_img_scan_source(E, EV2, "src2", NULL) == 1, "⑮h 主动加文件夹：甲链回来");
        // i 同一来源里同一款有两份（资源包号不同，如老「S2Arm 自签导出」与「S2Arm 游戏包」各一份）：只链修改时间新的那份，
        //   再扫两次都不动（原先按读目录次序逐个链，每次来回改链、每次重解）
        { char S3[1400], gD[1500], rD[1600]; snprintf(S3, sizeof S3, "%s/ext_two", T); snprintf(gD, sizeof gD, "%s/games/0100ABCD000000E4", E); s2a_pack_root(rD, sizeof rD, gD);
          snprintf(c, sizeof c, "mkdir -p '%s/老' '%s/新' && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/老/丁.img' --gid 0100abcd000000e4 --pack-id old4 > /dev/null"
                   " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/新/丁.img' --gid 0100abcd000000e4 --pack-id new4 > /dev/null"
                   " && touch -t 202601010000 '%s/老/丁.img' && touch -t 202611010000 '%s/新/丁.img'", S3, S3, R, D, S3, R, D, S3, S3, S3);
          CHECK(sh(c) == 0, "⑮i 造同一来源两份同款");
          int r1 = s2a_img_scan_source(E, S3, "src3", NULL), r2 = s2a_img_scan_source(E, S3, "src3", NULL), r3 = s2a_img_scan_source(E, S3, "src3", NULL);
          snprintf(c, sizeof c, "test \"$(readlink '%s/game.img')\" = '%s/新/丁.img' && grep -q new4 '%s/manifest.json'", rD, S3, rD);
          CHECK(r1 == 1 && r2 == 0 && r3 == 0 && sh(c) == 0, "⑮i 只链新的那份，之后不再改链（返回 %d / %d / %d）", r1, r2, r3);
          // j 另一个来源里也有这一款：现在链着的那份打得开 → 不抢（返回 0、软链接不变）；那份打不开（盘拔了）→ 换成这一份；原来的盘插回 → 不再换回去
          char S4[1400]; snprintf(S4, sizeof S4, "%s/ext_other", T);
          snprintf(c, sizeof c, "mkdir -p '%s' && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/丁.img' --gid 0100abcd000000e4 --pack-id oth4 > /dev/null", S4, R, D, S4);
          CHECK(sh(c) == 0, "⑮j 造另一个来源");
          int j1 = s2a_img_scan_source(E, S4, "src4", NULL), j1b = s2a_img_scan_source(E, S3, "src3", NULL);
          snprintf(c, sizeof c, "test \"$(readlink '%s/game.img')\" = '%s/新/丁.img'", rD, S3);
          CHECK(j1 == 0 && j1b == 0 && sh(c) == 0, "⑮j 两个来源轮流扫：不抢、不来回改链（返回 %d / %d）", j1, j1b);
          char S3x[1500]; snprintf(S3x, sizeof S3x, "%s_gone", S3); CHECK(rename(S3, S3x) == 0, "⑮j 拔掉第一个来源");
          int j2 = s2a_img_scan_source(E, S4, "src4", NULL);
          snprintf(c, sizeof c, "test \"$(readlink '%s/game.img')\" = '%s/丁.img'", rD, S4);
          CHECK(j2 == 1 && sh(c) == 0, "⑮j 原来那份打不开：换成另一个来源的（返回 %d）", j2);
          CHECK(rename(S3x, S3) == 0, "⑮j 第一个来源插回");
          int j3 = s2a_img_scan_source(E, S3, "src3", NULL), j4 = s2a_img_scan_source(E, S4, "src4", NULL);
          CHECK(j3 == 0 && j4 == 0 && sh(c) == 0, "⑮j 插回后不再换回去（返回 %d / %d）", j3, j4); }
        // k 来源里的 .s2arm（程序件，一块盘 Mac / iPhone 两端通用）：扫描时导进 App、盘上的不删；同一个文件再扫不重导（删掉导好的清单再扫，不会被重写）；
        //   文件改过（修改时间变了）再扫 → 重导
        if (zstd_pick()) { char S5[1400], pg[1600], cat[1700]; struct stat ks; snprintf(S5, sizeof S5, "%s/ext_prog/sub", T);
          snprintf(c, sizeof c, "mkdir -p '%s'", S5); sh(c);
          char sp[1500]; snprintf(sp, sizeof sp, "%s/某游戏.s2arm", S5); s2arm_pack(T, sp, "s2arm.json", NULL);
          snprintf(pg, sizeof pg, "%s/exth/Library/Application Support/S2Arm/games/0100ABCDE0000000/program", T); snprintf(cat, sizeof cat, "%s/catalogue.json", pg);
          snprintf(S5, sizeof S5, "%s/ext_prog", T);
          int k1 = s2a_img_scan_source(E, S5, "src5", NULL);
          CHECK(k1 == 1 && stat(cat, &ks) == 0 && stat(sp, &ks) == 0, "⑮k 程序件导进 App（返回 %d）、盘上的 .s2arm 还在", k1);
          unlink(cat);
          int k2 = s2a_img_scan_source(E, S5, "src5", NULL);
          CHECK(k2 == 0 && stat(cat, &ks) != 0, "⑮k 同一个文件再扫不重导（返回 %d）", k2);
          snprintf(c, sizeof c, "touch -t 202612010000 '%s'", sp); sh(c);
          int k3 = s2a_img_scan_source(E, S5, "src5", NULL);
          CHECK(k3 == 1 && stat(cat, &ks) == 0, "⑮k 文件改过再扫 → 重导（返回 %d）", k3); } }
      // ⑭c 着色器更新包（格式号 2，维护者 11-13）：先导完整包（带 shaders/a.metallib = 'x'）并解开；再导更新包（同游戏号同资源包号，a.metallib = 'y'——
      //   同长度：旧的若还在本体目录表里，下次解包会按「长度对就跳过 / 照目录表回写」把它弄回 'x'）。期望手写：
      //   认领 1 个、更新包从导入文件夹删掉、a.metallib = 'y'、本体目录表里不再有 shaders/ 条目、本体头里整长 = 文件长、再次应用后仍是 'y'；
      //   资源包号不同的更新包 → 不收、给码 ios_import_update_mismatch；本机没这款本体的更新包 → 不收、给码 ios_import_update_no_base
      { char D6[1300]; snprintf(D6, sizeof D6, "%s/img_docs6", T);
        snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' && printf 'y' > '%s/src/sh2.bin' && printf 'shaders/a.metallib\t%s/src/sh2.bin\n' > '%s/src/upd.tsv'"
                 " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/完整.img' --gid 0100abcd00000008 --pack-id img801 > /dev/null", D6, D, D, D, R, D, D6);
        CHECK(sh(c) == 0, "⑭c 造完整包");
        CHECK(s2a_img_scan(D6) == 1, "⑭c 完整包认领");
        char g6[1500]; snprintf(g6, sizeof g6, "%s/games/0100ABCD00000008", D6);
        { // ⑭d 本体认领了还没解开时放更新包：不套、不报错、原样留着（诊断#fe33c2：套到一半被解开时的目录整理删掉 → ENOENT）；解开后下一次扫描再套（见下面 ⑭c）
          snprintf(c, sizeof c, "python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/先到的更新包.img' --gid 0100abcd00000008 --pack-id img801 > /dev/null"
                   " && printf '\002' | dd of='%s/放这里导入/先到的更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", R, D, D6, D6);
          CHECK(sh(c) == 0, "⑭d 造更新包");
          CHECK(s2a_img_scan(D6) == 0 && !s2a_img_scan_code()[0], "⑭d 本体没解开：更新包不套、不给失败码（实际 %s「%s」）", s2a_img_scan_code(), s2a_img_scan_failure());
          snprintf(c, sizeof c, "test -e '%s/放这里导入/先到的更新包.img' && rm '%s/放这里导入/先到的更新包.img'", D6, D6); CHECK(sh(c) == 0, "⑭d 更新包原样留着"); }
        CHECK(s2a_pack_apply(g6) == 0, "⑭c 完整包解开");
        snprintf(c, sizeof c, "test \"$(cat '%s/资源包/shaders/a.metallib')\" = x", g6); CHECK(sh(c) == 0, "⑭c 完整包解出 a.metallib = x");
        snprintf(c, sizeof c, "python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/某游戏 着色器更新包.img' --gid 0100abcd00000008 --pack-id img801 > /dev/null"
                 " && printf '\002' | dd of='%s/放这里导入/某游戏 着色器更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", R, D, D6, D6);
        CHECK(sh(c) == 0, "⑭c 造更新包（格式号 2）");
        CHECK(s2a_img_scan(D6) == 1, "⑭c 更新包认领（%s「%s」）", s2a_img_scan_code(), s2a_img_scan_failure());
        snprintf(c, sizeof c, "g='%s/资源包'; test ! -e '%s/放这里导入/某游戏 着色器更新包.img' && test \"$(cat \"$g/shaders/a.metallib\")\" = y"
                 " && ! python3 '%s/pack/img.py' ls \"$g/game.img\" | grep -q '^shaders/'"
                 " && python3 -c \"import sys,struct;b=open(sys.argv[1],'rb').read();t=struct.unpack_from('<Q',b,128)[0];sys.exit(0 if t==len(b) else 1)\" \"$g/game.img\""
                 " && grep -q '^shaders/a.metallib\t1\t-' \"$g/index.tsv\"", g6, D6, R);
        CHECK(sh(c) == 0, "⑭c 更新包删掉、a.metallib = y、本体目录表没有 shaders/、本体整长 = 文件长、index.tsv 记新派生件");
        CHECK(s2a_pack_apply(g6) == 0, "⑭c 套更新包后解包成功");
        snprintf(c, sizeof c, "test \"$(cat '%s/资源包/shaders/a.metallib')\" = y", g6); CHECK(sh(c) == 0, "⑭c 再次应用后 a.metallib 仍是 y（旧的没回写）");
        { // ⑭g D-4VAX（「文件」导入：完整包与着色器更新包同时放进导入文件夹，一次扫描「认出并放好 2 个」，之后每次解开都 -4）：
          //   期望手写：一次扫描只认领完整包（更新包要等本体解开后再套）→ 返回 1、更新包留在导入文件夹；随后解开成功（返回 0）、a.metallib = x；
          //   再扫一次套上更新包 → a.metallib = y，再解开仍成功
          char D7[1300]; snprintf(D7, sizeof D7, "%s/img_docs7", T);
          snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/完整.img' --gid 0100abcd00000009 --pack-id img901 > /dev/null"
                   " && python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/完整 着色器更新包.img' --gid 0100abcd00000009 --pack-id img901 > /dev/null"
                   " && printf '\002' | dd of='%s/放这里导入/完整 着色器更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", D7, R, D, D7, R, D, D7, D7);
          CHECK(sh(c) == 0, "⑭g 造：完整包 + 更新包同时在导入文件夹");
          char g7[1500]; snprintf(g7, sizeof g7, "%s/games/0100ABCD00000009", D7);
          char lg[1500]; snprintf(lg, sizeof lg, "%s/host_g.log", T); int lfd = open(lg, O_WRONLY | O_CREAT | O_TRUNC, 0644), keep = g_s2a_logfd; g_s2a_logfd = lfd;
          int pg = s2a_img_scan(D7);
          int ra = s2a_pack_apply(g7);
          g_s2a_logfd = keep; close(lfd);
          snprintf(c, sizeof c, "test -e '%s/放这里导入/完整 着色器更新包.img'", D7); int left = sh(c) == 0;
          snprintf(c, sizeof c, "cat '%s'; tail -2 '%s/unpack.log'", lg, g7); if (pg != 1 || ra != 0) sh(c);
          CHECK(pg == 1 && left, "⑭g 一次扫描：只认领完整包（实际 %d）、更新包留着（%s）", pg, left ? "留着" : "被套了");
          CHECK(ra == 0, "⑭g 随后解开成功（实际 %d）", ra);
          CHECK(s2a_img_scan(D7) == 1 && s2a_pack_apply(g7) == 0, "⑭g 解开后再扫：套上更新包、再解开仍成功");
          snprintf(c, sizeof c, "test \"$(cat '%s/资源包/shaders/a.metallib')\" = y", g7); CHECK(sh(c) == 0, "⑭g 最终 a.metallib = y"); }
        { // ⑭i D-455Z / D-MACF：着色器更新包带 200 个派生件（原先换件的回滚记录固定 64 格，超过就报 E2BIG、整份拒收）。
          //   期望手写：认领 1 个、200 个派生件全部落盘、抽查的内容对、index.tsv 记 200 行这类派生件、再解开仍成功
          char D10[1300]; snprintf(D10, sizeof D10, "%s/img_docs10", T);
          snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' '%s/src/u200' && for i in $(seq -w 0 199); do printf \"v$i\" > '%s/src/u200/'$i;"
                   " printf 'shaders/direct/b-x/lib.%%s.pak\t%s/src/u200/%%s\n' $i $i; done > '%s/src/upd200.tsv'"
                   " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/完整.img' --gid 0100abcd0000000c --pack-id img1001 > /dev/null", D10, D, D, D, D, R, D, D10);
          CHECK(sh(c) == 0, "⑭i 造完整包与 200 个派生件的清单");
          char g10[1500]; snprintf(g10, sizeof g10, "%s/games/0100ABCD0000000C", D10);
          CHECK(s2a_img_scan(D10) == 1 && s2a_pack_apply(g10) == 0, "⑭i 完整包认领并解开");
          snprintf(c, sizeof c, "python3 '%s/pack/img.py' build - '%s/src/upd200.tsv' '%s/放这里导入/完整 着色器更新包.img' --gid 0100abcd0000000c --pack-id img1001 > /dev/null"
                   " && printf '\002' | dd of='%s/放这里导入/完整 着色器更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", R, D, D10, D10);
          CHECK(sh(c) == 0, "⑭i 造 200 个派生件的更新包（格式号 2）");
          int got = s2a_img_scan(D10);
          CHECK(got == 1, "⑭i 更新包认领 1 个（实际 %d，%s「%s」）", got, s2a_img_scan_code(), s2a_img_scan_failure());
          snprintf(c, sizeof c, "g='%s/资源包'; test \"$(ls \"$g/shaders/direct/b-x\" | wc -l | tr -d ' ')\" = 200 && test \"$(cat \"$g/shaders/direct/b-x/lib.137.pak\")\" = v137"
                   " && test \"$(grep -c '^shaders/direct/b-x/lib\\.' \"$g/index.tsv\")\" = 200", g10);
          CHECK(sh(c) == 0, "⑭i 200 个派生件全部落盘、lib.137 = v137、index.tsv 记 200 行");
          CHECK(s2a_pack_apply(g10) == 0, "⑭i 套更新包后再解开成功"); }
        { // ⑭f 审计 P1-169：更新包写派生件失败（派生件 shaders/a.metallib 的位置被一个非空目录占着，改名进不去）→ 失败、不能把这款从库里弄没：
          //   期望手写：返回 0 个、给失败码；清单 manifest.json 与 .applied 都还在、内容不变；本体 game.img 逐字节不变；更新包留在导入文件夹
          snprintf(c, sizeof c, "set -e; g='%s/资源包'; cp \"$g/manifest.json\" '%s/mf.bak'; cp \"$g/.applied\" '%s/ap.bak'; cp \"$g/game.img\" '%s/img.bak';"
                   " rm -f \"$g/shaders/a.metallib\"; mkdir -p \"$g/shaders/a.metallib/占位\"; echo z > \"$g/shaders/a.metallib/占位/f\";"
                   " python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/坏更新包.img' --gid 0100abcd00000008 --pack-id img801 > /dev/null"
                   " && printf '\\002' | dd of='%s/放这里导入/坏更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", g6, T, T, T, R, D, D6, D6);
          CHECK(sh(c) == 0, "⑭f 造：派生件位置被目录占着 + 一个更新包");
          int pf = s2a_img_scan(D6);
          snprintf(c, sizeof c, "g='%s/资源包'; cmp -s \"$g/manifest.json\" '%s/mf.bak' && cmp -s \"$g/.applied\" '%s/ap.bak' && cmp -s \"$g/game.img\" '%s/img.bak' && test -e '%s/放这里导入/坏更新包.img'", g6, T, T, T, D6);
          CHECK(pf == 0 && s2a_img_scan_code()[0] && sh(c) == 0, "⑭f 写派生件失败：认领 0 个（实际 %d）、给码（%s）、清单 / .applied / 本体都不变、更新包留着", pf, s2a_img_scan_code());
          snprintf(c, sizeof c, "rm -rf '%s/资源包/shaders/a.metallib' '%s/放这里导入/坏更新包.img'", g6, D6); sh(c); }
        { // ⑭e 审计 P1-169：认领完整包时改名进不去（资源包里 game.img 的位置被一个非空目录占着）→ 失败，这款不能从库里消失：
          //   期望手写：认领 0 个、给失败码；manifest.json 与 .applied 都还在、内容不变；源 IMG 留在导入文件夹
          snprintf(c, sizeof c, "set -e; g='%s/资源包'; cp \"$g/manifest.json\" '%s/mf2.bak'; cp \"$g/.applied\" '%s/ap2.bak'; mv \"$g/game.img\" '%s/img2.bak'; mkdir -p \"$g/game.img/占位\"; echo z > \"$g/game.img/占位/f\";"
                   " python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/新完整.img' --gid 0100abcd00000008 --pack-id img802 > /dev/null", g6, T, T, T, R, D, D6);
          CHECK(sh(c) == 0, "⑭e 造：game.img 位置被目录占着 + 一个新完整包");
          int pe = s2a_img_scan(D6);
          snprintf(c, sizeof c, "g='%s/资源包'; cmp -s \"$g/manifest.json\" '%s/mf2.bak' && cmp -s \"$g/.applied\" '%s/ap2.bak' && test -e '%s/放这里导入/新完整.img'", g6, T, T, D6);
          CHECK(pe == 0 && s2a_img_scan_code()[0] && sh(c) == 0, "⑭e 改名失败：认领 0 个（实际 %d）、给码（%s）、清单 / .applied 不变、源 IMG 留着", pe, s2a_img_scan_code());
          snprintf(c, sizeof c, "g='%s/资源包'; rm -rf \"$g/game.img\" '%s/放这里导入/新完整.img'; mv '%s/img2.bak' \"$g/game.img\"", g6, D6, T); sh(c); }
        { // ⑭g 审计 P1-169 兄弟站点：更新包换上本体 / 派生件之后才失败（index.tsv 的临时位置被非空目录占着，写不出）→ 已换上的全部退回：
          //   期望手写：认领 0 个、给码；manifest.json / .applied / index.tsv / 本体 game.img 逐字节不变；派生件 shaders/a.metallib 退回到套之前（不存在）；
          //   资源包里不留 .s2a-prev / .upd.tmp；更新包留在导入文件夹
          snprintf(c, sizeof c, "set -e; g='%s/资源包'; rm -rf \"$g/shaders/a.metallib\"; for f in manifest.json .applied index.tsv game.img; do cp \"$g/$f\" '%s/g_'\"$f\"; done;"
                   " mkdir -p \"$g/index.tsv.tmp/占位\"; echo z > \"$g/index.tsv.tmp/占位/f\";"
                   " python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/晚失败更新包.img' --gid 0100abcd00000008 --pack-id img801 > /dev/null"
                   " && printf '\\002' | dd of='%s/放这里导入/晚失败更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", g6, T, R, D, D6, D6);
          CHECK(sh(c) == 0, "⑭g 造：index.tsv 临时位置被目录占着 + 一个更新包");
          int pg = s2a_img_scan(D6);
          snprintf(c, sizeof c, "g='%s/资源包'; for f in manifest.json .applied index.tsv game.img; do cmp -s \"$g/$f\" '%s/g_'\"$f\" || exit 1; done;"
                   " test ! -e \"$g/shaders/a.metallib\" && test -z \"$(find \"$g\" -name '*.s2a-prev' -o -name '*.upd.tmp')\" && test -e '%s/放这里导入/晚失败更新包.img'", g6, T, D6);
          CHECK(pg == 0 && s2a_img_scan_code()[0] && sh(c) == 0, "⑭g 换上后写 index.tsv 失败：认领 0 个（实际 %d）、给码（%s）、清单 / .applied / 目录表 / 本体不变、派生件退回、不留中间件、更新包留着", pg, s2a_img_scan_code());
          snprintf(c, sizeof c, "rm -rf '%s/资源包/index.tsv.tmp' '%s/放这里导入/晚失败更新包.img'", g6, D6); sh(c); }
        { // ⑭h 审计 P1-169 兄弟站点：认领完整包时新 game.img 已经换上、之后写 index.tsv 失败 → 新包挪回导入文件夹、旧本体换回：
          //   期望手写：认领 0 个、给码；本体 game.img / index.tsv / manifest.json / .applied 逐字节不变；源 IMG 回到导入文件夹；不留 game.img.s2a-prev
          snprintf(c, sizeof c, "set -e; g='%s/资源包'; for f in manifest.json .applied index.tsv game.img; do cp \"$g/$f\" '%s/h_'\"$f\"; done;"
                   " mkdir -p \"$g/index.tsv.tmp/占位\"; echo z > \"$g/index.tsv.tmp/占位/f\";"
                   " python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/放这里导入/晚失败完整.img' --gid 0100abcd00000008 --pack-id img803 > /dev/null", g6, T, R, D, D6);
          CHECK(sh(c) == 0, "⑭h 造：index.tsv 临时位置被目录占着 + 一个新完整包");
          int ph = s2a_img_scan(D6);
          snprintf(c, sizeof c, "g='%s/资源包'; for f in manifest.json .applied index.tsv game.img; do cmp -s \"$g/$f\" '%s/h_'\"$f\" || exit 1; done;"
                   " test ! -e \"$g/game.img.s2a-prev\" && test -s '%s/放这里导入/晚失败完整.img'", g6, T, D6);
          CHECK(ph == 0 && s2a_img_scan_code()[0] && sh(c) == 0, "⑭h 换上后写 index.tsv 失败：认领 0 个（实际 %d）、给码（%s）、本体 / 目录表 / 清单 / .applied 不变、源 IMG 回到导入文件夹", ph, s2a_img_scan_code());
          snprintf(c, sizeof c, "rm -rf '%s/资源包/index.tsv.tmp' '%s/放这里导入/晚失败完整.img'", g6, D6); sh(c); }
        snprintf(c, sizeof c, "python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/错版.img' --gid 0100abcd00000008 --pack-id img999 > /dev/null"
                 " && printf '\002' | dd of='%s/放这里导入/错版.img' bs=1 seek=8 conv=notrunc 2>/dev/null", R, D, D6, D6);
        CHECK(sh(c) == 0, "⑭c 造资源包号不同的更新包");
        // 维护者 11-17：配套与否玩家判断不了，替他判——不套用、不报错（无码），记下跳过的文件名给库上说一句；文件原样留在导入文件夹
        CHECK(s2a_img_scan(D6) == 0 && !s2a_img_scan_code()[0] && !strcmp(s2a_img_scan_skipped(), "错版.img"), "⑭c 资源包号不同：跳过不套、不给错误码、记下跳过（实际码「%s」、跳过「%s」）", s2a_img_scan_code(), s2a_img_scan_skipped());
        snprintf(c, sizeof c, "test -e '%s/放这里导入/错版.img' && rm '%s/放这里导入/错版.img'"
                 " && python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/没本体.img' --gid 0100abcd00000009 --pack-id img901 > /dev/null"
                 " && printf '\002' | dd of='%s/放这里导入/没本体.img' bs=1 seek=8 conv=notrunc 2>/dev/null", D6, D6, R, D, D6, D6);
        CHECK(sh(c) == 0, "⑭c 错版原样留着；造本机没本体的更新包");
        CHECK(s2a_img_scan(D6) == 0 && !strcmp(s2a_img_scan_code(), "ios_import_update_no_base") && strstr(s2a_img_scan_failure(), "完整"),
              "⑭c 没本体：不收、给码、原因说先导完整包（实际 %s「%s」）", s2a_img_scan_code(), s2a_img_scan_failure());
        // ⑭e 完整包与更新包同一次放（诊断#0787f1 D-YY32）：更新包放在先扫的「放这里导入」、完整包放在后扫的「Import Here」，旧代码按目录顺序先看更新包 → 报 no_base。
        //   期望手写：认领 1 个（完整包）、不给失败码、更新包原样留着等本体解开后再套
        { char D7[1300]; snprintf(D7, sizeof D7, "%s/img_docs7", T);
          snprintf(c, sizeof c, "mkdir -p '%s/放这里导入' '%s/Import Here'"
                   " && python3 '%s/pack/img.py' build - '%s/src/others_sh.tsv' '%s/Import Here/某游戏.img' --gid 0100abcd0000000a --pack-id imga01 > /dev/null"
                   " && python3 '%s/pack/img.py' build - '%s/src/upd.tsv' '%s/放这里导入/某游戏 着色器更新包.img' --gid 0100abcd0000000a --pack-id imga01 > /dev/null"
                   " && printf '\002' | dd of='%s/放这里导入/某游戏 着色器更新包.img' bs=1 seek=8 conv=notrunc 2>/dev/null", D7, D7, R, D, D7, R, D, D7, D7);
          CHECK(sh(c) == 0, "⑭e 造同时放的完整包与更新包");
          int n7 = s2a_img_scan(D7);
          CHECK(n7 == 1 && !s2a_img_scan_code()[0], "⑭e 同时放：认领完整包 1 个、不报没本体（实际 %d、%s「%s」）", n7, s2a_img_scan_code(), s2a_img_scan_failure());
          snprintf(c, sizeof c, "test -e '%s/放这里导入/某游戏 着色器更新包.img'", D7); CHECK(sh(c) == 0, "⑭e 更新包原样留着、等本体解开"); } } }
    // iOS 装机剃刀 #27 / #38：闸门与游戏库同一条快判。夹具：.applied = 清单、程序描述在、.incoming 里还留着一个写完的包（推送端盖残批的空包）。
    //   期望 s2a_import_state 判就绪 0（旧闸门先看 .incoming 判待导入 1，库却说能玩）。
    // 剃刀 #29：有 game.img、清单被推送开头置空、index.tsv 里的文件都在 → 期望不判就绪（旧代码清单读不出时当「不用解」→ 就绪 0）
    { char D[2100], c2[4096]; snprintf(D, sizeof D, "%s/gate_quick", T);
      snprintf(c2, sizeof c2, "mkdir -p '%s/资源包/.incoming' '%s/资源包/exefs' && cd '%s/资源包' && printf x > exefs/main.npdm && printf 'exefs/main.npdm\t1\tx\n' > index.tsv && "
          "printf '{\"version\":2,\"index_sha256\":\"cc33\"}' > manifest.json && printf cc33 > .applied && head -c 1024 /dev/zero > .incoming/9_000.tar", D, D, D);
      CHECK(sh(c2) == 0, "造闸门快判夹具失败");
      int st1 = s2a_import_state(D); CHECK(st1 == 0, "剃刀 #27：.applied = 清单、程序描述在、留着一个写完的包 → 闸门判就绪 0（实际 %d）", st1);
      snprintf(c2, sizeof c2, "cd '%s/资源包' && rm -f .incoming/*.tar .applied && printf img > game.img && printf 'exefs/main.npdm\t1\tx\ngame.img\t3\tx\n' > index.tsv && printf '' > manifest.json", D);
      CHECK(sh(c2) == 0, "造 IMG 清单置空夹具失败");
      int st2 = s2a_import_state(D); CHECK(st2 != 0, "剃刀 #29：有 game.img、清单被置空 → 闸门不判就绪（实际 %d）", st2); }
    // 多款容器第一次装一款：本款文档根 <容器>/Documents/games/<游戏号>/ 还不在，资源包在 <容器>/Library/Application Support/S2Arm/games/<游戏号>/资源包。
    //   期望解开成功且 unpack.log 建在文档根、带完成行「.applied = <清单 sha>」（电脑端 tools/push_pack.py 只认这一行；旧代码日志建不了，电脑端白等 180 秒误报）
    { char cdocs[1100], croot[1300]; snprintf(cdocs, sizeof cdocs, "%s/ctr/Documents/games/0100000000000002", T);
      snprintf(croot, sizeof croot, "%s/ctr/Library/Application Support/S2Arm/games/0100000000000002/资源包", T);
      snprintf(c, sizeof c, "mkdir -p '%s' && printf '{\"index_sha256\":\"cc02\"}' > '%s/manifest.json' && printf '" NPDM_ROW "' > '%s/index.tsv'", croot, croot, croot);
      CHECK(sh(c) == 0, "造多款容器夹具失败"); put_npdm(croot);
      CHECK(s2a_pack_apply(cdocs) == 0, "多款容器文档根不在：资源包应照样解开（%s）", s2a_pack_apply_failure());
      snprintf(c, sizeof c, "grep -q '\\.applied = cc02' '%s/unpack.log'", cdocs); CHECK(sh(c) == 0, "多款容器文档根不在：期望建出文档根、unpack.log 有完成行 .applied = cc02"); }
    // #1059 D-PB7S：index.tsv 全部核对通过，但清单没列 exefs/main.npdm、机上也没有 → 旧代码报「解开了」写 .applied，游戏库却按缺程序描述判等解开、每秒重解。
    //   期望按规则手写：解包判失败、原因含「exefs/main.npdm 不在」、给码 ios_install_files_missing、不写 .applied；
    //   变体：main.npdm 在但是 0 字节（清单列为 0 字节，index 核对照样通过）→ 原因含「是空的」，仍不写 .applied
    { char nd[1100], nr[1200], ap[1300]; struct stat ns; snprintf(nd, sizeof nd, "%s/npdm_gate", T); snprintf(nr, sizeof nr, "%s/资源包", nd); snprintf(ap, sizeof ap, "%s/.applied", nr);
      snprintf(c, sizeof c, "mkdir -p '%s' && printf abc > '%s/a.txt' && printf 'a.txt\\t3\\tx\\n' > '%s/index.tsv' && printf '{\"index_sha256\":\"nn01\"}' > '%s/manifest.json'", nr, nr, nr, nr);
      CHECK(sh(c) == 0, "造缺程序描述夹具失败");
      CHECK(s2a_pack_apply(nd) != 0, "清单全对、没列也没有 exefs/main.npdm：应判失败");
      CHECK(strstr(s2a_pack_apply_failure(), "exefs/main.npdm 不在") != NULL, "缺程序描述：原因应含「exefs/main.npdm 不在」→「%s」", s2a_pack_apply_failure());
      CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_files_missing"), "缺程序描述：给码 ios_install_files_missing（实际 %s）", s2a_pack_apply_code());
      CHECK(stat(ap, &ns) != 0, "缺程序描述：不应写 .applied");
      snprintf(c, sizeof c, "mkdir -p '%s/exefs' && : > '%s/exefs/main.npdm' && printf 'a.txt\\t3\\tx\\nexefs/main.npdm\\t0\\tx\\n' > '%s/index.tsv'", nr, nr, nr);
      CHECK(sh(c) == 0, "造空程序描述夹具失败");
      CHECK(s2a_pack_apply(nd) != 0, "程序描述是 0 字节：应判失败");
      CHECK(strstr(s2a_pack_apply_failure(), "exefs/main.npdm 是空的") != NULL, "空程序描述：原因应含「是空的」→「%s」", s2a_pack_apply_failure());
      CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_files_missing"), "空程序描述：给码 ios_install_files_missing（实际 %s）", s2a_pack_apply_code());
      CHECK(stat(ap, &ns) != 0, "空程序描述：不应写 .applied"); }
    // #540：游戏目录（多款容器 Documents/games/<游戏号>/）根本不在：解包先把它建出来，失败行照样写进 unpack.log、失败原因照样填上。
    //   日志真建不了（文档根挡在一个普通文件下面）时原因注明「unpack.log 建不了」。先跑一次成功的同名目录，核成功后原因清空（不留上一次的失败原因）
    { char gone[1100]; snprintf(gone, sizeof gone, "%s/games/0100000000000000", T); struct stat gs;
      CHECK(stat(gone, &gs) != 0, "夹具：游戏目录应不在");
      CHECK(s2a_pack_apply(gone) != 0, "游戏目录不在（资源包也不在）应判失败");
      const char *why = s2a_pack_apply_failure();
      CHECK(why && strstr(why, "index.tsv 打不开") && strstr(why, "返回 -8"), "目录不在：期望原因含「index.tsv 打不开」「返回 -8」→ 「%s」", why ? why : "(null)");
      CHECK(why && !strstr(why, "建不了"), "目录不在：日志应建得出来，原因不该再说建不了 → 「%s」", why ? why : "(null)");
      snprintf(c, sizeof c, "tail -1 '%s/unpack.log' | grep -q '返回 -8'", gone); CHECK(sh(c) == 0, "目录不在：期望建出游戏目录、unpack.log 末行是「返回 -8」的失败行");
      CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_files_missing"), "核对缺文件（返回 -8）给码 ios_install_files_missing（实际 %s）", s2a_pack_apply_code());
      char blocked[1100]; snprintf(blocked, sizeof blocked, "%s/plainfile/games/0100000000000000", T); snprintf(c, sizeof c, ": > '%s/plainfile'", T);
      CHECK(sh(c) == 0, "造挡路文件夹具失败");
      CHECK(s2a_pack_apply(blocked) != 0, "文档根挡在普通文件下应判失败");
      why = s2a_pack_apply_failure();
      CHECK(why && strstr(why, "unpack.log 建不了") && strstr(why, "Not a directory"), "日志建不了：期望原因注明 unpack.log 建不了（Not a directory）→ 「%s」", why ? why : "(null)");
      char ok[1100]; snprintf(ok, sizeof ok, "%s/ok", T); snprintf(c, sizeof c, "mkdir -p %s/资源包 && printf '{\"index_sha256\":\"aa\"}' > %s/资源包/manifest.json && printf '" NPDM_ROW "' > %s/资源包/index.tsv", ok, ok, ok);
      CHECK(sh(c) == 0, "造空包夹具失败"); { char okr[1200]; snprintf(okr, sizeof okr, "%s/资源包", ok); put_npdm(okr); }
      CHECK(s2a_pack_apply(ok) == 0, "索引只有程序描述的包应解开");
      CHECK(!*s2a_pack_apply_failure(), "成功后失败原因应清空 →「%s」", s2a_pack_apply_failure());
      CHECK(!*s2a_pack_apply_code(), "成功后码应清空 →「%s」", s2a_pack_apply_code()); }
    // #569 游戏目录 App 写不进（玩家机上 games 一串归 root、0755）：解包一个包都不解、直接报目录与属主、给码 ios_install_dir_unwritable（不再迁移：App 改不了删不掉，提示玩家导出存档后重装）；
    //   期望按规则手写
    if (getuid() != 0) {
        char base[] = "/tmp/s2a_t_repair_XXXXXX"; if (!mkdtemp(base)) return 1;
        char c[4096]; const char *gid = "0100000000ABC000";
        snprintf(c, sizeof c, "mkdir -p '%s/games/%s/资源包/.incoming' && printf 'hello' > '%s/games/%s/资源包/romfs.img' && printf 'x' > '%s/games/%s/资源包/.incoming/a.tar'", base, gid, base, gid, base, gid); sh(c);
        char root[600]; snprintf(root, sizeof root, "%s/games/%s/资源包", base, gid); chmod(root, 0555);
        char gd[600]; snprintf(gd, sizeof gd, "%s/games/%s", base, gid);
        s2a_pack_repair_self_override = (unsigned)getuid() + 1;   // #569 是「归 root」：测试改不了属主，把自己当外人，补权限不动它
        int arc = s2a_pack_apply(gd); s2a_pack_repair_self_override = 0;
        CHECK(arc != 0 && strstr(s2a_pack_apply_failure(), "目录 App 写不进") && strstr(s2a_pack_apply_failure(), "资源包") && strstr(s2a_pack_apply_failure(), "权限 555"),
              "资源包目录写不进：解包先报目录与权限（实际 %d「%s」）", arc, s2a_pack_apply_failure());
        CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_dir_unwritable"), "目录写不进给码 ios_install_dir_unwritable（实际 %s）", s2a_pack_apply_code());
        chmod(root, 0755);
        snprintf(c, sizeof c, "chmod -R u+w '%s' 2>/dev/null; rm -rf '%s'", base, base); sh(c);
    }
    // ⑮ 资源包挪出 Documents（v0.3.0）：容器形状的临时目录 <容器>/Documents/games/<游戏号>；期望按规则手写（s2a_docs.h s2a_pack_root、pack_apply.c s2a_pack_migrate_one）
    {
        char base[] = "/tmp/s2a_t_migrate_XXXXXX"; if (!mkdtemp(base)) return 1;
        char P[1200], c[8192]; snprintf(P, sizeof P, "%s/Documents", base);
        // 夹具：一款旧布局（资源包 3 个文件 + 存档 1 个），另存一份对照
        snprintf(c, sizeof c, "set -e; d='%s/games/0100AAAA00000001'; mkdir -p \"$d/资源包/romfs/a\" \"$d/资源包/exefs\" \"$d/S2A/ryujinx/bis/user/save/1\";"
                 " echo r1 > \"$d/资源包/romfs/a/x.bin\"; head -c 70000 /dev/urandom > \"$d/资源包/exefs/main.npdm\"; echo idx > \"$d/资源包/index.tsv\";"
                 " echo save > \"$d/S2A/ryujinx/bis/user/save/1/data\"; mkdir -p '%s/ref'; cp -R \"$d/资源包\" '%s/ref/pack'; cp -R \"$d/S2A\" '%s/ref/S2A'", P, base, base, base);
        CHECK(sh(c) == 0, "⑮ 造旧布局夹具");
        char G1[1300]; snprintf(G1, sizeof G1, "%s/games/0100AAAA00000001", P);
        char N1[1500]; snprintf(N1, sizeof N1, "%s/Library/Application Support/S2Arm/games/0100AAAA00000001/资源包", base);
        // ① 只有旧位置 → 同盘改名挪过去：文件逐字节一样、旧位置没了、存档不动
        CHECK(s2a_pack_migrate_one(G1) == 1, "⑮① 只有旧位置：挪（返回 1）");
        snprintf(c, sizeof c, "diff -r '%s/ref/pack' '%s' && test ! -e '%s/资源包' && diff -r '%s/ref/S2A' '%s/S2A'", base, N1, G1, base, G1);
        CHECK(sh(c) == 0, "⑮① 新位置文件逐字节同原来、旧位置没了、存档逐字节不变");
        // ② 再迁一次：没有旧位置 → 0、不动
        CHECK(s2a_pack_migrate_one(G1) == 0, "⑮② 再迁：没有旧位置，返回 0");
        // ③ 两处都有、新位置已就绪（.applied = 清单、程序描述在）→ 删旧的重复
        snprintf(c, sizeof c, "set -e; printf '{\"index_sha256\": \"abc\"}' > '%s/manifest.json'; printf abc > '%s/.applied'; mkdir -p '%s/资源包/romfs'; echo dup > '%s/资源包/romfs/dup'", N1, N1, G1, G1);
        CHECK(sh(c) == 0, "⑮③ 造：新位置就绪 + 旧位置一份残留");
        CHECK(s2a_pack_migrate_one(G1) == 1 && access(N1, F_OK) == 0, "⑮③ 新位置就绪：删旧的（返回 1），新位置还在");
        snprintf(c, sizeof c, "test ! -e '%s/资源包' && diff -r '%s/ref/S2A' '%s/S2A'", G1, base, G1); CHECK(sh(c) == 0, "⑮③ 旧位置删掉、存档不变");
        // ④ 两处都有、新位置没就绪 → 都不动（不丢任何一份）
        snprintf(c, sizeof c, "set -e; rm -f '%s/.applied'; mkdir -p '%s/资源包'; echo keep > '%s/资源包/k'", N1, G1, G1); sh(c);
        CHECK(s2a_pack_migrate_one(G1) == -1, "⑮④ 新位置没就绪：两处都留（返回 -1）");
        snprintf(c, sizeof c, "test -s '%s/资源包/k' && test -s '%s/exefs/main.npdm'", G1, N1); CHECK(sh(c) == 0, "⑮④ 两处文件都在");
        // ⑧ 两处都有、旧位置是老版本电脑端推的新资源包（清单不同 / 有待解包）→ 旧的换掉新位置（不删新推的那份）
        snprintf(c, sizeof c, "set -e; rm -rf '%s/资源包'; printf q0 > '%s/.applied'; printf '{\"index_sha256\": \"q0\"}' > '%s/manifest.json';"
                 " mkdir -p '%s/资源包'; printf '{\"index_sha256\": \"q9\"}' > '%s/资源包/manifest.json'; echo new > '%s/资源包/n'", G1, N1, N1, G1, G1, G1);
        CHECK(sh(c) == 0, "⑮⑧ 造：新位置就绪（q0）+ 旧位置一份清单 q9 的新推送");
        snprintf(c, sizeof c, "grep -q q9 '%s/manifest.json' && test -s '%s/n' && test ! -e '%s/资源包'", N1, N1, G1);
        CHECK(s2a_pack_migrate_one(G1) == 1 && sh(c) == 0, "⑮⑧ 清单不同：旧位置的新推送换掉新位置（新位置清单 = q9、旧位置没了）");
        snprintf(c, sizeof c, "set -e; printf q9 > '%s/.applied'; mkdir -p '%s/资源包/.incoming'; echo t > '%s/资源包/.incoming/t.txt'; tar -cf '%s/资源包/.incoming/1_000.tar' -C '%s/资源包/.incoming' t.txt; rm '%s/资源包/.incoming/t.txt'", N1, G1, G1, G1, G1, G1);
        sh(c);
        snprintf(c, sizeof c, "test -s '%s/.incoming/1_000.tar' && test ! -e '%s/资源包'", N1, G1);
        CHECK(s2a_pack_migrate_one(G1) == 1 && sh(c) == 0, "⑮⑧ 旧位置有待解包：换掉新位置（待解包到了新位置、旧位置没了）");
        // ⑧c 审计 P1-169：换的时候第二步改名失败（旧位置的上级只读，删不掉旧条目）→ 新位置原样（清单 q9、待解包还在）、
        //   不留挪开的 .s2a-old-* 副本、旧位置那份也在、返回 -2（新位置此时是上一步换进来的那份：只有待解包、没有清单）。原先先删新位置再改名：这一步失败新位置就没了
        snprintf(c, sizeof c, "set -e; mkdir -p '%s/资源包'; printf '{\"index_sha256\": \"q7\"}' > '%s/资源包/manifest.json'; chmod 555 '%s'", G1, G1, G1);
        CHECK(sh(c) == 0, "⑮⑧c 造：旧位置清单 q7、上级只读");
        int r8 = s2a_pack_migrate_one(G1);
        snprintf(c, sizeof c, "chmod 755 '%s'; test -s '%s/.incoming/1_000.tar' && test ! -e '%s/manifest.json' && ! ls -d '%s'.s2a-old-* >/dev/null 2>&1 && grep -q q7 '%s/资源包/manifest.json'", G1, N1, N1, N1, G1);
        CHECK(r8 == -2 && sh(c) == 0, "⑮⑧c 第二步改名失败：返回 -2（实际 %d）、新位置原样（待解包在、没有清单）、没留挪开的副本、旧位置在", r8);
        snprintf(c, sizeof c, "rm -rf '%s/资源包'", G1); sh(c);
        snprintf(c, sizeof c, "set -e; printf '{\"index_sha256\": \"abc\"}' > '%s/manifest.json'; printf abc > '%s/.applied'; mkdir -p '%s/exefs'; head -c 100 /dev/urandom > '%s/exefs/main.npdm'; rm -rf '%s/.incoming'", N1, N1, N1, N1, N1);
        sh(c);
        // ⑧e 审计 P1-169 余项（改前读数要的那一款）：新位置已就绪（清单 abc、.applied abc、本体 game.img 在），旧位置 .incoming 里只有一个 1024 字节全零 tar
        //   （空包：只有归档结束块，没有一个条目）、没有清单。期望按规则手写：空包不算新推送 → 新位置已就绪 → 删旧的重复（返回 1）；新位置的 game.img 还在、清单还是 abc
        // game.img 用最小合法 IMG：136 字节头（魔数 S2AIMG01、+128 整个文件长 = 136），快判核长度（D-YGEC）也认它完整
        snprintf(c, sizeof c, "set -e; { printf S2AIMG01; head -c 120 /dev/zero; printf '\\210\\0\\0\\0\\0\\0\\0\\0'; } > '%s/game.img'; mkdir -p '%s/资源包/.incoming'; head -c 1024 /dev/zero > '%s/资源包/.incoming/1_000.tar'", N1, G1, G1);
        CHECK(sh(c) == 0, "⑮⑧e 造：新位置就绪带 game.img + 旧位置只有一个空 tar");
        int r8e = s2a_pack_migrate_one(G1);
        snprintf(c, sizeof c, "test \"$(head -c 8 '%s/game.img')\" = S2AIMG01 && grep -q abc '%s/manifest.json' && test ! -e '%s/资源包'", N1, N1, G1);
        CHECK(r8e == 1 && sh(c) == 0, "⑮⑧e 空 tar 不算新推送：返回 1（实际 %d）、新位置 game.img 与清单都在、旧位置删掉", r8e);
        snprintf(c, sizeof c, "rm -f '%s/game.img'", N1); sh(c);
        // ⑤ 迁到一半被杀：30 款，子进程迁、几毫秒后 SIGKILL，再迁一次 → 30 款都在新位置、每款 50 个文件一个不少、存档都在
        snprintf(c, sizeof c, "set -e; for i in $(seq 10 39); do d='%s/games/0100BBBB000000'$i; mkdir -p \"$d/资源包/f\" \"$d/S2A/ryujinx/bis/user/save\"; "
                 "for j in $(seq 1 50); do echo $i$j > \"$d/资源包/f/$j\"; done; echo s$i > \"$d/S2A/ryujinx/bis/user/save/s\"; done", P);
        CHECK(sh(c) == 0, "⑮⑤ 造 30 款旧布局");
        pid_t kid = fork();
        if (kid == 0) { int f; s2a_pack_migrate(P, &f); _exit(0); }
        usleep(2000); kill(kid, SIGKILL); waitpid(kid, NULL, 0);
        int failed = -1; s2a_pack_migrate(P, &failed);
        snprintf(c, sizeof c, "n=0; for i in $(seq 10 39); do d='%s/games/0100BBBB000000'$i; g='%s/Library/Application Support/S2Arm/games/0100BBBB000000'$i'/资源包';"
                 " test ! -e \"$d/资源包\" || exit 1; test \"$(ls \"$g/f\" | wc -l | tr -d ' ')\" = 50 || exit 2; test \"$(cat \"$d/S2A/ryujinx/bis/user/save/s\")\" = s$i || exit 3; done", P, base);
        CHECK(failed == 0 && sh(c) == 0, "⑮⑤ 杀掉后再迁：30 款都在新位置、每款 50 个文件、存档都在、旧位置没有（失败 %d 款）", failed);
        // ⑥ 迁好后闸门 / 游戏库按新位置判：新位置就绪 → 就绪；资源包状态读的是 Library 那份
        snprintf(c, sizeof c, "set -e; g='%s/Library/Application Support/S2Arm/games/0100BBBB00000010/资源包'; mkdir -p \"$g/exefs\"; head -c 100 /dev/urandom > \"$g/exefs/main.npdm\";"
                 " printf '{\"index_sha256\": \"q1\"}' > \"$g/manifest.json\"; printf q1 > \"$g/.applied\"", base);
        sh(c);
        CHECK(s2a_import_state_game_quick(P, "0100BBBB00000010") == 0, "⑮⑥ 游戏库快判读新位置：就绪");
        snprintf(c, sizeof c, "chmod -R u+w '%s' 2>/dev/null; rm -rf '%s'", base, base); sh(c);
    }
        { // 容器内属主不是 App 的条目清点（#569 / 维护者 11-15：不迁移、只清点 + 有影响才提示）。期望手写：
      //   自己建的目录（3 个条目：目录 a、子目录 a/b、文件 a/b/f 4096 字节）按真 uid 数 → 0；把「自己」当成别的 uid 数 → 4 个（含根目录本身）、文件实占 ≥ 4096、
      //   最早一条读数行里带「属主 uid <真 uid>」
      char F[1200]; snprintf(F, sizeof F, "%s/foreign_home", T);
      snprintf(c, sizeof c, "mkdir -p '%s/a/b' && head -c 4096 /dev/zero > '%s/a/b/f'", F, F); CHECK(sh(c) == 0, "造容器样本");
      uint64_t b0 = 1, b1 = 0; char l0[1600], l1[1600];
      unsigned n0 = s2a_foreign_scan(F, &b0, l0, sizeof l0), n1 = s2a_foreign_scan_as(F, (unsigned)getuid() + 1, &b1, l1, sizeof l1);
      char want[64]; snprintf(want, sizeof want, "属主 uid %u", (unsigned)getuid());
      CHECK(n0 == 0 && b0 == 0, "清点：全是自己的 → 0 个、0 字节（实际 %u、%llu）", n0, (unsigned long long)b0);
      CHECK(n1 == 4 && b1 >= 4096 && strstr(l1, want) && strstr(l1, "4 个"), "清点：把自己当外人 → 4 个、≥4096 字节、读数行带属主（实际 %u、%llu「%s」）", n1, (unsigned long long)b1, l1); }
    { // 资源包里 App 自己的、缺写权限的目录 / 文件补回属主读写（D-A76N）。期望手写：
      //   文档根 D（0555）、资源包根 R 下子目录 s（0555）、文件 s/f（0444）、文件 g（0644）→ 按真 uid 补 3 个（D、s、s/f），D / s 变 0755、s/f 变 0644、g 不动；
      //   补完后在 s 里能建文件；把「自己」当成别的 uid 再跑 → 一个都不补
      char D[1200], R[1300], s[1400], f[1500], g[1400], nf[1500]; struct stat a, b, cst, d;
      snprintf(D, sizeof D, "%s/repair_docs", T); snprintf(R, sizeof R, "%s/pack", D); snprintf(s, sizeof s, "%s/s", R);
      snprintf(f, sizeof f, "%s/f", s); snprintf(g, sizeof g, "%s/g", R); snprintf(nf, sizeof nf, "%s/new", s);
      snprintf(c, sizeof c, "mkdir -p '%s' && echo x > '%s' && echo y > '%s' && chmod 444 '%s' && chmod 555 '%s' && chmod 555 '%s'", s, f, g, f, s, D); CHECK(sh(c) == 0, "造只读样本");
      CHECK(s2a_pack_repair_modes_as(D, R, (unsigned)getuid() + 1) == 0, "补权限：属主不是自己 → 一个都不动");
      unsigned n = s2a_pack_repair_modes_as(D, R, (unsigned)getuid());
      stat(D, &a); stat(s, &b); stat(f, &cst); stat(g, &d);
      CHECK(n == 3, "补权限：补 3 个（实际 %u）", n);
      CHECK((a.st_mode & 0777) == 0755 && (b.st_mode & 0777) == 0755 && (cst.st_mode & 0777) == 0644 && (d.st_mode & 0777) == 0644,
            "补权限：D / s 0755、s/f 0644、g 不动 0644（实际 %o %o %o %o）", a.st_mode & 0777, b.st_mode & 0777, cst.st_mode & 0777, d.st_mode & 0777);
      FILE *w = fopen(nf, "w"); CHECK(w != NULL, "补完后能在原只读目录里建文件"); if (w) fclose(w);
      snprintf(c, sizeof c, "chmod -R u+w '%s' 2>/dev/null; rm -rf '%s'", D, D); sh(c); }
    { // 启动时整棵补（D-A76N 第二回：推送报写不进就停，走不到解包那次补）。期望手写：树 L 下 a（0555）/ a/b（0555）/ a/b/f（0444）→ 补 3 个，
      //   a、a/b 变 0755、f 变 0644、补完能在 a/b 里建文件；把「自己」当成别的 uid 再造一份 → 一个都不补；目录不存在 → 0、不崩
      char L[1200], A[1300], B[1400], F[1500]; struct stat sa, sb, sf;
      snprintf(L, sizeof L, "%s/launch_tree", T); snprintf(A, sizeof A, "%s/a", L); snprintf(B, sizeof B, "%s/b", A); snprintf(F, sizeof F, "%s/f", B);
      snprintf(c, sizeof c, "mkdir -p '%s' && echo x > '%s' && chmod 444 '%s' && chmod 555 '%s' '%s'", B, F, F, B, A); CHECK(sh(c) == 0, "造启动补权限样本");
      s2a_pack_repair_self_override = (unsigned)getuid() + 1; unsigned n0 = s2a_pack_repair_tree(L); s2a_pack_repair_self_override = 0;
      CHECK(n0 == 0, "启动补权限：属主不是自己 → 一个都不动（实际 %u）", n0);
      unsigned n = s2a_pack_repair_tree(L); stat(A, &sa); stat(B, &sb); stat(F, &sf);
      CHECK(n == 3 && (sa.st_mode & 0777) == 0755 && (sb.st_mode & 0777) == 0755 && (sf.st_mode & 0777) == 0644,
            "启动补权限：补 3 个、a / b 0755、f 0644（实际 %u，%o %o %o）", n, sa.st_mode & 0777, sb.st_mode & 0777, sf.st_mode & 0777);
      snprintf(c, sizeof c, "%s/new", B); FILE *w = fopen(c, "w"); CHECK(w != NULL, "启动补权限：补完能在 a/b 里建文件"); if (w) fclose(w);
      snprintf(c, sizeof c, "%s/不存在", T); CHECK(s2a_pack_repair_tree(c) == 0, "启动补权限：目录不存在 → 0");
      snprintf(c, sizeof c, "chmod -R u+w '%s' 2>/dev/null; rm -rf '%s'", L, L); sh(c); }
zst_cases(T);
race_case(T);
printf("%s t_pack_apply：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
