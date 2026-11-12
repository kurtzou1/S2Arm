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
int s2a_games_repair(const char *proc_docs); const char *s2a_games_repair_detail(void); unsigned s2a_games_repair_files(void); unsigned s2a_games_repair_owner(void); int s2a_untar(const char *tar, const char *root, unsigned *nf, uint64_t *nb); int s2a_pack_check(const char *root, char *first, size_t n);
int s2a_import_docs_pick(const s2a_launch_ctx *c, int game_data_env, const char *proc_docs, char *out, size_t n); int s2a_import_state_game(const char *proc_docs, const char *gid);
int s2a_import_state_game_quick(const char *proc_docs, const char *gid);
int s2a_game_install_state(const char *proc_docs, const char *gid);
int s2a_img_scan(const char *proc_docs); const char *s2a_img_scan_failure(void);
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

int main(void) {
    char T[] = "/tmp/s2a_t_pack_XXXXXX"; if (!mkdtemp(T)) return 1;
    boundary_cases(T);
    // 失败给码（11-11 维护者「补上说人话的原因」）：返回码 / errno / 截短 / 是否出在 game.img 那步 → 规格码。期望按码表含义手写：
    //   目录写不进优先（重开 App 会迁）；其次空间满（不管哪步）；截短或包头坏 = 没传完；格式号 / IMG 坏；核对缺文件；清单读不出；其余写失败；认不出的 unknown
    { struct { int rc, err, trunc, img; const char *want; } m[] = {
        {0, 0, 0, 0, ""}, {-12, 0, 0, 0, "ios_install_dir_unwritable"}, {-12, ENOSPC, 0, 0, "ios_install_dir_unwritable"},
        {-4, ENOSPC, 0, 0, "ios_install_no_space"}, {-4, EDQUOT, 0, 1, "ios_install_no_space"}, {-4, ENOSPC, 1, 0, "ios_install_no_space"},
        {-4, EIO, 1, 0, "ios_install_pack_truncated"}, {-2, 0, 0, 0, "ios_install_pack_truncated"},
        {-11, 0, 0, 1, "ios_install_img_format"}, {-10, 0, 0, 1, "ios_install_img_corrupt"}, {-3, EINVAL, 0, 1, "ios_install_img_corrupt"},
        {-3, 0, 0, 0, "ios_install_unknown"}, {-5, 0, 0, 0, "ios_install_unknown"}, {-8, 0, 0, 0, "ios_install_files_missing"},
        {-6, 0, 0, 0, "ios_install_manifest_bad"}, {-7, 0, 0, 0, "ios_install_manifest_bad"}, {-4, EACCES, 0, 0, "ios_install_write_failed"},
        {-99, 0, 0, 0, "ios_install_unknown"} };
      for (size_t i = 0; i < sizeof m / sizeof *m; i++) { const char *got = s2a_install_code(m[i].rc, m[i].err, m[i].trunc, m[i].img);
          CHECK(!strcmp(got, m[i].want), "给码 rc %d errno %d 截短 %d IMG %d：期望 %s，实际 %s", m[i].rc, m[i].err, m[i].trunc, m[i].img, m[i].want, got); }
      // 引擎会给的每个码都在共用规格里（屏上文案按码从规格生成，查不到就只能显示「未知原因」）
      char sp[1200]; snprintf(sp, sizeof sp, "%s", __FILE__); char *cut = strstr(sp, "runtime/tests/"); if (cut) *cut = 0; strlcat(sp, "launchers/shared/experience.v1.json", sizeof sp);
      FILE *sf = fopen(sp, "r"); char spec[200000] = ""; size_t sk = sf ? fread(spec, 1, sizeof spec - 1, sf) : 0; if (sf) fclose(sf); spec[sk] = 0;
      CHECK(sk > 0, "读共用规格 %s", sp);
      const char *codes[] = {"ios_install_dir_unwritable", "ios_install_no_space", "ios_install_pack_truncated", "ios_install_img_format", "ios_install_img_corrupt",
          "ios_install_files_missing", "ios_install_manifest_bad", "ios_install_write_failed", "ios_install_unknown", "ios_import_img_failed"};
      for (size_t i = 0; i < sizeof codes / sizeof *codes; i++) { char q[80]; snprintf(q, sizeof q, "\"code\": \"%s\"", codes[i]); CHECK(strstr(spec, q) != NULL, "规格里应有码 %s", codes[i]); } }
    char c[8192];
    snprintf(c, sizeof c, "cd %s && mkdir -p src/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子 docs/资源包/.incoming && "
        "head -c 70000 /dev/urandom > 'src/romfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子/文件.bin' && : > src/空.txt && printf abc > src/a.txt && "
        "cd src && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/1_000.tar romfs a.txt && "
        "COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/1_001.tar 空.txt && cd .. && "
        "printf '{\"version\":2,\"index_sha256\":\"deadbeef01\"}' > docs/资源包/manifest.json && "
        "printf 'a.txt\\t3\\tx\\n空.txt\\t0\\tx\\nromfs/很长的中文目录名用来超过一百个字节的老式头部限制很长的中文目录名用来超过一百个字节/子/文件.bin\\t70000\\tx\\n' > docs/资源包/index.tsv && "
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
    snprintf(c, sizeof c, "grep -q '解开 2 个包 3 个文件' %s/docs/unpack.log && ! grep -q '返回 -' %s/docs/unpack.log", T, T); CHECK(sh(c) == 0, "unpack.log 行不对");
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
    // 写失败要带现场（10-20 测试设备2 巫师3 连续「返回 -4」看不出哪个条目）：资源包下已有同名普通文件 aoc，包里要建 aoc/ 目录 →
    // 期望「返回 -4」，且同一行带「现场：建目录 <…>/aoc：errno 20 Not a directory」（ENOTDIR = 20）
    snprintf(c, sizeof c, "cd %s && rm -f docs/资源包/.incoming/2_000.tar && printf x > docs/资源包/aoc && mkdir -p src2/aoc && printf y > src2/aoc/d.bin && "
        "cd src2 && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf ../docs/资源包/.incoming/3_000.tar aoc/d.bin", T);
    CHECK(sh(c) == 0, "造冲突包失败");
    CHECK(s2a_pack_apply(docs) != 0, "同名文件挡路应判失败");
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '返回 -4.*现场：建目录 .*/资源包/aoc：errno 20 Not a directory'", T); CHECK(sh(c) == 0, "失败行应含「返回 -4」与建目录现场（errno 20）");
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
        "printf 'a.txt\\t3\\tx\\nexefs/main\\t504067\\tx\\n' > docs/资源包/index.tsv && "
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
    snprintf(c, sizeof c, "cd %s && printf 'a.txt\\t3\\tx\\nshaders/direct/keys.tsv\\t504067\\tx\\n' > docs/资源包/index.tsv && "
        "printf '{\"version\":2,\"index_sha256\":\"deadbeef04\"}' > docs/资源包/manifest.json", T); sh(c);
    CHECK(s2a_pack_apply(docs) == 0, "只缺非核心文件：应判部分可玩、不判失败");
    snprintf(c, sizeof c, "tail -1 %s/docs/unpack.log | grep -q '缺 1 个非必需文件（例：shaders/direct/keys.tsv（不在））.*部分可玩 = deadbeef04'", T); CHECK(sh(c) == 0, "部分可玩行应写明缺几个、例子、清单 sha");
    snprintf(c, sizeof c, "head -1 %s/docs/资源包/.partial | grep -qx deadbeef04", T); CHECK(sh(c) == 0, ".partial 第一行应是本清单 sha");
    snprintf(c, sizeof c, "grep -qx deadbeef01 %s/docs/资源包/.applied && cmp -s %s/ia.bak %s/docs/资源包/index.applied.tsv", T, T, T); CHECK(sh(c) == 0, "部分可玩时 .applied / index.applied.tsv 不应变（电脑照样补推）");
    snprintf(c, sizeof c, "cd %s && printf 'a.txt\\t4\\tx\\n' > docs/资源包/index.tsv && printf '{\"version\":2,\"index_sha256\":\"deadbeef05\"}' > docs/资源包/manifest.json", T); sh(c);
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
    //   index.applied.tsv（10 字节）写得下、.applied（64 字节）写不下。期望按语义手写：解包判失败（退出码 1）、.applied 仍是 oldmark、不留 .applied.tmp。
    //   旧代码 fopen("w") 先把 .applied 截成 0 字节再写失败 → 旧标记丢了
    { char D[2100], c2[4096], ap[2200], got[128] = ""; struct stat s2; snprintf(D, sizeof D, "%s/atom", T);
      snprintf(c2, sizeof c2, "mkdir -p '%s/资源包' && cd '%s/资源包' && printf abc > a.txt && printf 'a.txt\\t3\\tx\\n' > index.tsv && printf oldmark > .applied && "
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
      snprintf(c2, sizeof c2, "cd %s && mkdir -p src2 '%s/资源包/.incoming' && echo hi > src2/a.txt && cd src2 && COPYFILE_DISABLE=1 tar " TAR_OPTIONS " -cf '%s/资源包/.incoming/1_000.tar' a.txt && cd .. && cp '%s/资源包/.incoming/1_000.tar' '%s/资源包/.incoming/1_001.tar' && printf 'a.txt\\t3\\tx\\n' > '%s/资源包/index.tsv' && printf '{\"version\":2,\"index_sha256\":\"cafe01\"}' > '%s/资源包/manifest.json'", T, D, D, D, D, D, D);
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
      CHECK(s2a_import_decide(D, &w, 103, why, sizeof why) == S2A_GATE_BROKEN, "⑫ 剃刀 #33：不完整、文件变了也不等，仍是说明页");
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
      CHECK(s2a_pack_apply(D) != 0, "⑬e 格式号 9 → 解包失败");
      snprintf(c, sizeof c, "grep -q '格式号' '%s/unpack.log'", D); CHECK(sh(c) == 0, "⑬e 解包日志带「格式号」"); 
      // ⑭ 玩家把 IMG 放进「文件」里 S2Arm 的「放这里导入」文件夹：s2a_img_scan 挪进 games/<头里的游戏号>/资源包/game.img、写 manifest（资源包号同头）与 index.tsv；
      //   拷到一半的（长度不等于头里的整个文件长）不动；导入文件夹以外的（Documents/下载）不扫、不动（v0.3.0）；挪好后应用成功
      char D3[1300]; snprintf(D3, sizeof D3, "%s/scan_docs", T);   // 小文件清单借 ⑬ 的夹具（exefs/main.npdm = 随机 5000 字节、ctl = NACP）
      snprintf(c, sizeof c, "mkdir -p '%s/放这里导入/x' '%s/下载' && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/放这里导入/x/某游戏.img' --gid 0100abcd00000002 --pack-id img789 > /dev/null"
               " && head -c 20000 '%s/放这里导入/x/某游戏.img' > '%s/放这里导入/半个.img'"
               " && python3 '%s/pack/img.py' build - '%s/src/others.tsv' '%s/下载/别处.img' --gid 0100abcd00000003 --pack-id img790 > /dev/null", D3, D3, R, D, D3, D3, D3, R, D, D3);
      CHECK(sh(c) == 0, "⑭ 造夹具（导入文件夹第二层一个完整 IMG、导入文件夹下一个拷到一半的、导入文件夹外一个完整 IMG）");
      CHECK(s2a_img_scan(D3) == 1, "⑭ 扫到并挪好 1 个");
      snprintf(c, sizeof c, "g='%s/games/0100ABCD00000002/资源包'; test -s \"$g/game.img\" && test ! -e '%s/放这里导入/x/某游戏.img' && test -e '%s/放这里导入/半个.img' && test -e '%s/下载/别处.img' && test ! -e '%s/games/0100ABCD00000003' && grep -q '\"index_sha256\": \"img789\"' \"$g/manifest.json\" && test \"$(cut -f1 \"$g/index.tsv\")\" = game.img", D3, D3, D3, D3, D3);
      CHECK(sh(c) == 0, "⑭ 落到 games/<游戏号>/资源包/game.img、manifest 资源包号 = 头里的、index.tsv 只有 game.img、拷一半的没动");
      { char g3[1500]; snprintf(g3, sizeof g3, "%s/games/0100ABCD00000002", D3);
        CHECK(s2a_import_state(g3) == 1, "⑭ 挪好后 → 待导入（状态 %d）", s2a_import_state(g3));
        s2a_pack_apply_phase = phase; memset(g_ph, 0, sizeof g_ph); memset(g_phn, 0, sizeof g_phn);
        CHECK(s2a_pack_apply(g3) == 0, "⑭ 应用成功");
        s2a_pack_apply_phase = NULL;
        // 分段进度（游戏库「安装中」蒙版）：② 从 game.img 解小文件按字节报到满（exefs/main.npdm 5000 + ctl/control.nacp 4）；③ 核对机上文件报到满；没有推送包不报 ①
        CHECK(g_phn[2] > 0 && g_ph[2][0] == g_ph[2][1] && g_ph[2][1] == 5004, "⑭ 分段进度 ② 解小文件 %llu / %llu（期望 5004 / 5004）", (unsigned long long)g_ph[2][0], (unsigned long long)g_ph[2][1]);
        CHECK(g_phn[3] > 0 && g_ph[3][0] == g_ph[3][1] && g_ph[3][1] >= 1, "⑭ 分段进度 ③ 核对 %llu / %llu", (unsigned long long)g_ph[3][0], (unsigned long long)g_ph[3][1]);
        CHECK(g_phn[1] == 0, "⑭ 没有推送包不报 ①（报了 %d 次）", g_phn[1]);
        snprintf(c, sizeof c, "cmp -s '%s/src/npdm' '%s/资源包/exefs/main.npdm'", D, g3); CHECK(sh(c) == 0, "⑭ 小文件逐字节解出"); }
      CHECK(s2a_img_scan(D3) == 0, "⑭ 再扫一次：没有新的（拷到一半的仍不动）");
      CHECK(!*s2a_img_scan_code(), "⑭ 认领没失败：码为空（实际 %s）", s2a_img_scan_code());
      // 格式号 2（更新版 S2Arm 做的）：不认、原样留着，给码 ios_install_img_format
      char D4[1300], f4[1400]; snprintf(D4, sizeof D4, "%s/img_docs4", T); mkdir(D4, 0755); snprintf(f4, sizeof f4, "%s/Import Here", D4); mkdir(f4, 0755);
      snprintf(f4, sizeof f4, "%s/Import Here/新格式.img", D4);   // 英文界面建的导入文件夹名也认
      FILE *o4 = fopen(f4, "wb"); uint8_t h4[8192] = {0}; memcpy(h4, "S2AIMG01", 8); h4[8] = 2; memcpy(h4 + 16, "0100ABCD00000000", 16); uint64_t tot = sizeof h4; memcpy(h4 + 128, &tot, 8);
      CHECK(o4 && fwrite(h4, 1, sizeof h4, o4) == sizeof h4 && !fclose(o4), "造格式号 2 的 IMG");
      CHECK(s2a_img_scan(D4) == 0 && !access(f4, F_OK) && !strcmp(s2a_img_scan_code(), "ios_install_img_format"),
            "格式号 2：不挪、给码 ios_install_img_format（实际 %s「%s」）", s2a_img_scan_code(), s2a_img_scan_failure()); }
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
    // #540：游戏目录（多款容器 Documents/games/<游戏号>/）根本不在 → unpack.log 也建不了；失败原因仍要填上，并说明日志建不了。
    //   先跑一次成功的同名目录，核成功后原因清空（不留上一次的失败原因）
    { char gone[1100]; snprintf(gone, sizeof gone, "%s/games/0100000000000000", T); struct stat gs;
      CHECK(stat(gone, &gs) != 0, "夹具：游戏目录应不在");
      CHECK(s2a_pack_apply(gone) != 0, "游戏目录不在应判失败");
      const char *why = s2a_pack_apply_failure();
      CHECK(why && strstr(why, "index.tsv 打不开") && strstr(why, "返回 -8"), "目录不在：期望原因含「index.tsv 打不开」「返回 -8」→ 「%s」", why ? why : "(null)");
      CHECK(why && strstr(why, "unpack.log 建不了") && strstr(why, "No such file"), "目录不在：期望原因注明 unpack.log 建不了（No such file）→ 「%s」", why ? why : "(null)");
      CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_files_missing"), "核对缺文件（返回 -8）给码 ios_install_files_missing（实际 %s）", s2a_pack_apply_code());
      char ok[1100]; snprintf(ok, sizeof ok, "%s/ok", T); snprintf(c, sizeof c, "mkdir -p %s/资源包 && printf '{\"index_sha256\":\"aa\"}' > %s/资源包/manifest.json && : > %s/资源包/index.tsv", ok, ok, ok);
      CHECK(sh(c) == 0, "造空包夹具失败");
      CHECK(s2a_pack_apply(ok) == 0, "空索引的包应解开");
      CHECK(!*s2a_pack_apply_failure(), "成功后失败原因应清空 →「%s」", s2a_pack_apply_failure());
      CHECK(!*s2a_pack_apply_code(), "成功后码应清空 →「%s」", s2a_pack_apply_code()); }
    // #569 游戏目录 App 写不进（玩家机上 games 一串归 root、0755）：解包一个包都不解、直接报目录与属主；s2a_games_repair 克隆进新树、
    //   换名，旧的留在 .s2a-unwritable-*；全可写不动；树里有不认识的类型（命名管道）迁移失败、原样不动、新树清掉。期望按规则手写
    if (getuid() != 0) {
        char base[] = "/tmp/s2a_t_repair_XXXXXX"; if (!mkdtemp(base)) return 1;
        char c[4096]; const char *gid = "0100000000ABC000";
        snprintf(c, sizeof c, "mkdir -p '%s/games/%s/资源包/.incoming' && printf 'hello' > '%s/games/%s/资源包/romfs.img' && printf 'x' > '%s/games/%s/资源包/.incoming/a.tar'", base, gid, base, gid, base, gid); sh(c);
        CHECK(s2a_games_repair(base) == 0, "目录都写得进：迁移不动（返回 0）");
        char root[600]; snprintf(root, sizeof root, "%s/games/%s/资源包", base, gid); chmod(root, 0555);
        char gd[600]; snprintf(gd, sizeof gd, "%s/games/%s", base, gid);
        int arc = s2a_pack_apply(gd);
        CHECK(arc != 0 && strstr(s2a_pack_apply_failure(), "目录 App 写不进") && strstr(s2a_pack_apply_failure(), "资源包") && strstr(s2a_pack_apply_failure(), "权限 555"),
              "资源包目录写不进：解包先报目录与权限（实际 %d「%s」）", arc, s2a_pack_apply_failure());
        CHECK(!strcmp(s2a_pack_apply_code(), "ios_install_dir_unwritable"), "目录写不进给码 ios_install_dir_unwritable（实际 %s）", s2a_pack_apply_code());
#if defined(__APPLE__)
        int r = s2a_games_repair(base);
        char ng[600]; snprintf(ng, sizeof ng, "%s/games/%s/资源包", base, gid);
        char buf[16] = ""; char fp[700]; snprintf(fp, sizeof fp, "%s/romfs.img", ng); FILE *f = fopen(fp, "r"); if (f) { size_t k = fread(buf, 1, sizeof buf - 1, f); buf[k] = 0; fclose(f); }
        snprintf(c, sizeof c, "ls -d '%s'/.s2a-unwritable-* >/dev/null 2>&1", base);
        CHECK(r == 1 && s2a_games_repair_files() == 3 && !access(ng, W_OK) && !strcmp(buf, "hello") && sh(c) == 0,
              "写不进 → 迁好：返回 1、克隆 3 个文件（romfs.img、a.tar、上一步失败写下的 unpack.log）、新资源包可写、内容一致、旧目录留在 .s2a-unwritable-*（实际 %d / %u / 内容「%s」）", r, s2a_games_repair_files(), buf);
        CHECK(s2a_pack_apply(gd) != 0 && !strstr(s2a_pack_apply_failure(), "写不进"), "迁好后解包不再报目录写不进（这里因夹具不是真包会别的原因失败）：「%s」", s2a_pack_apply_failure());
        CHECK(s2a_games_repair(base) == 0, "迁好后再查：都写得进（返回 0）");
        // 迁移失败：新游戏目录放一个命名管道（不是普通文件 / 目录 / 链接）再设成写不进
        char g2[600]; snprintf(g2, sizeof g2, "%s/games/0100000000DEF000", base); mkdir(g2, 0755);
        char fifo[700]; snprintf(fifo, sizeof fifo, "%s/pipe", g2); mkfifo(fifo, 0644); chmod(g2, 0555);
        int r2 = s2a_games_repair(base);
        snprintf(c, sizeof c, "ls -d '%s'/.s2a-games-new-* >/dev/null 2>&1", base);
        struct stat st2;
        CHECK(r2 < 0 && strstr(s2a_games_repair_detail(), "不是普通文件") && !stat(fifo, &st2) && sh(c) != 0,
              "迁移失败：返回负数、原因说明哪一个、原目录原样、新树清掉（实际 %d「%s」）", r2, s2a_games_repair_detail());
        chmod(g2, 0755);
#endif
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
        snprintf(c, sizeof c, "set -e; printf q9 > '%s/.applied'; mkdir -p '%s/资源包/.incoming'; head -c 1024 /dev/zero > '%s/资源包/.incoming/1_000.tar'", N1, G1, G1);
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
        // ⑦ #569 写不进修复也管新位置：Library 那棵 games/<游戏号>/资源包 归不可写 → 克隆换上、可写
        char lg[1500]; snprintf(lg, sizeof lg, "%s/Library/Application Support/S2Arm/games/0100BBBB00000011/资源包", base);
        chmod(lg, 0555);
        int r7 = s2a_games_repair(P);
        CHECK(r7 == 1 && !access(lg, W_OK), "⑮⑦ 新位置写不进 → 修好（返回 %d、可写 %d）", r7, !access(lg, W_OK));
        snprintf(c, sizeof c, "chmod -R u+w '%s' 2>/dev/null; rm -rf '%s'", base, base); sh(c);
    }
    printf("%s t_pack_apply：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
