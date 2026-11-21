// 手机上导出已装好的一款（0.6.3，GitHub #1793：分发证书玩家换签名重装 S2Arm 后，不想再从电脑整套重推）：
//   反向打出和电脑端 pack/jobs/install.py export_s2arm 同格式的两件套，导入端（runtime/src/pack_apply.c s2a_s2arm_import / img_place）原样认。
//   <名>.s2arm = 一个带内容校验的 zstd 帧，里面是 ustar（只有普通文件、0644、mtime 0；路径放不进 ustar 就报错，同电脑端）：
//     s2arm.json → program/catalogue.json（去掉 dir：导入端会在开头插自己的 dir，留着就是重复键）→ program/<清单 dir 指着的版本目录里全部普通文件>
//     → pack/<资源包派生件白名单：shaders/**、romfs_overlay/**、romfs.s2aidx、game.imgmap、index.tsv、manifest.json>。
//     解出来的 exefs/ ctl/、.applied* / .imported / .partial / .transfer / .pushed / index.applied.tsv 这类机上状态一律不带（导入端认领 game.img 时自己重建）。
//   zstd：App 里只链了解压器（runtime/third_party/zstd/zstddeclib.c），这里不引压缩器，按 RFC 8878 直接写原样块（Raw_Block）：
//     帧头不写内容大小、非单段、窗口 128 KB（= 块上限）、带内容校验（XXH64 种子 0 的低 4 字节，小端）。边读边写，不把整包读进内存，先写 .part 再改名。
//   <名>.img = 资源包里 game.img 同卷硬链接（几 GB 不拷副本）；硬链接不行再 APFS 克隆，都不行报错。
//   电脑「推到 iPhone」装的款没有 game.img、是 romfs.img + 散文件（iPhone 实机）：.img = 资源包的 romfs.img（同样硬链接 / 克隆），
//     pack/ 改按 index.tsv 带它列的除 romfs.img 外全部文件（exefs/ ctl/ systemdata/ shaders/ aoc.tsv romfs.imgmap romfs.s2aidx…）+ index.tsv + manifest.json，
//     s2arm.json 加 img_kind "romfs"、img_size、img_fp（runtime/src/pack_apply.c s2a_img_fp：头尾各 1 MB 的 XXH64），导入端据此认领（romfs_claim）。
//     game.img 布局的 s2arm.json 不写这几个字段（老导入端照旧认）。
//   程序库导出的是手机上已签好的那份（清单 signer 原样带走）：另一个 S2Arm 起局时证书不同，照常重签（ios/program_resign.m）。
#import <Foundation/Foundation.h>
#include "game_export.h"
#include "s2a_docs.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/clonefile.h>
#endif

#ifdef S2A_UNIT_TEST
int s2a_game_export_test_keep_dir;   // 单测负对照：不去掉清单的 dir，核导入后能查出重复键
#endif

// ---- XXH64（种子 0，zstd 内容校验用；zstddeclib 里那份是文件私有的）：照 xxHash 规范的流式实现 ----
#define P1 0x9E3779B185EBCA87ULL
#define P2 0xC2B2AE3D27D4EB4FULL
#define P3 0x165667B19E3779F9ULL
#define P4 0x85EBCA77C2B2AE63ULL
#define P5 0x27D4EB2F165667C5ULL
typedef struct { uint64_t v[4], total; uint8_t mem[32]; size_t memn; } xxh64_t;
static uint64_t rotl(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }
static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t xround(uint64_t acc, uint64_t in) { acc += in * P2; acc = rotl(acc, 31); return acc * P1; }
static uint64_t xmerge(uint64_t h, uint64_t v) { h ^= xround(0, v); return h * P1 + P4; }
static void xxh64_init(xxh64_t *s) { memset(s, 0, sizeof *s); s->v[0] = P1 + P2; s->v[1] = P2; s->v[2] = 0; s->v[3] = 0 - P1; }
static void xxh64_update(xxh64_t *s, const uint8_t *p, size_t n) {
    s->total += n;
    if (s->memn + n < 32) { memcpy(s->mem + s->memn, p, n); s->memn += n; return; }
    if (s->memn) { size_t k = 32 - s->memn; memcpy(s->mem + s->memn, p, k); p += k; n -= k;
        for (int i = 0; i < 4; i++) s->v[i] = xround(s->v[i], rd64(s->mem + 8 * i)); s->memn = 0; }
    for (; n >= 32; p += 32, n -= 32) for (int i = 0; i < 4; i++) s->v[i] = xround(s->v[i], rd64(p + 8 * i));
    memcpy(s->mem, p, n); s->memn = n;
}
uint64_t s2a_xxh64_digest(const void *data, size_t n);   // 单测核规范给的已知值用
int s2a_img_fp(const char *path, uint64_t size, char out[17]);   // runtime/src/pack_apply.c：romfs 镜像指纹（导入端认领用同一个函数）
static uint64_t xxh64_digest(const xxh64_t *s) {
    uint64_t h = s->total >= 32 ? rotl(s->v[0], 1) + rotl(s->v[1], 7) + rotl(s->v[2], 12) + rotl(s->v[3], 18) : P5;
    if (s->total >= 32) for (int i = 0; i < 4; i++) h = xmerge(h, s->v[i]);
    h += s->total;
    const uint8_t *p = s->mem; size_t n = s->memn;
    for (; n >= 8; p += 8, n -= 8) { h ^= xround(0, rd64(p)); h = rotl(h, 27) * P1 + P4; }
    if (n >= 4) { h ^= (uint64_t)rd32(p) * P1; h = rotl(h, 23) * P2 + P3; p += 4; n -= 4; }
    for (; n; p++, n--) { h ^= *p * P5; h = rotl(h, 11) * P1; }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
    return h;
}
uint64_t s2a_xxh64_digest(const void *data, size_t n) { xxh64_t s; xxh64_init(&s); xxh64_update(&s, data, n); return xxh64_digest(&s); }

// ---- zstd 帧（只写原样块）----
enum { ZBLOCK = 128 * 1024 };   // 块上限 128 KB（RFC 8878 Block_Maximum_Size），窗口给同样大
typedef struct { int fd; uint8_t *buf; size_t n; xxh64_t h; int err; } zw_t;
static int put_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) { ssize_t k = write(fd, b, n); if (k < 0 && errno == EINTR) continue; if (k <= 0) return -1; b += k; n -= (size_t)k; }
    return 0;
}
static void zw_block(zw_t *w, int last) {   // 块头 3 字节小端：bit0 = 最后一块，bit1-2 = 块类型（0 = 原样），其余 = 块长
    if (w->err) return;
    uint32_t hd = (uint32_t)(w->n << 3) | (last ? 1u : 0u); uint8_t h3[3] = {(uint8_t)hd, (uint8_t)(hd >> 8), (uint8_t)(hd >> 16)};
    if (put_all(w->fd, h3, 3) || put_all(w->fd, w->buf, w->n)) w->err = errno ? errno : EIO;
    w->n = 0;
}
static int zw_begin(zw_t *w, int fd) {
    memset(w, 0, sizeof *w); w->fd = fd; xxh64_init(&w->h);
    if (!(w->buf = malloc(ZBLOCK))) return -1;
    // 魔数 FD2FB528（小端）| 帧头描述 0x04（不写内容大小、非单段、带内容校验、无字典）| 窗口描述 0x38（指数 7 → 2^(10+7) = 128 KB）
    static const uint8_t hd[6] = {0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38};
    if (put_all(fd, hd, sizeof hd)) { w->err = errno ? errno : EIO; return -1; }
    return 0;
}
static void zw_put(zw_t *w, const void *p, size_t n) {
    const uint8_t *b = p; xxh64_update(&w->h, b, n);
    while (n && !w->err) { if (w->n == ZBLOCK) zw_block(w, 0);
        size_t k = ZBLOCK - w->n < n ? ZBLOCK - w->n : n; memcpy(w->buf + w->n, b, k); w->n += k; b += k; n -= k; }
}
static int zw_end(zw_t *w) {   // 剩下的当最后一块（内容正好是 128 KB 整倍数时是 0 长的最后一块，合法）+ 4 字节校验
    zw_block(w, 1);
    uint32_t c = (uint32_t)xxh64_digest(&w->h); uint8_t c4[4] = {(uint8_t)c, (uint8_t)(c >> 8), (uint8_t)(c >> 16), (uint8_t)(c >> 24)};
    if (!w->err && put_all(w->fd, c4, 4)) w->err = errno ? errno : EIO;
    free(w->buf); w->buf = NULL;
    return w->err ? -1 : 0;
}

// ---- ustar ----
// 头：名字 100 + 前缀 155（同 Python tarfile 的 ustar：从左找第一个能让两段都放下的「/」）；0644、uid/gid 0、mtime 0、普通文件
static int tar_head(uint8_t h[512], const char *path, uint64_t size) {
    memset(h, 0, 512);
    size_t L = strlen(path); const char *nm = path; size_t pl = 0;
    if (L > 100) { const char *s = path; nm = NULL;
        while ((s = strchr(s, '/'))) { size_t a = (size_t)(s - path), b = L - a - 1; if (a <= 155 && b <= 100 && b) { nm = s + 1; pl = a; break; } s++; }
        if (!nm) return -1; }
    if (size > 077777777777ULL) return -1;   // 11 位八进制放不下（> 8 GB）
    memcpy(h, nm, strlen(nm)); if (pl) memcpy(h + 345, path, pl);
    memcpy(h + 100, "0000644", 8); memcpy(h + 108, "0000000", 8); memcpy(h + 116, "0000000", 8);
    snprintf((char *)h + 124, 12, "%011llo", (unsigned long long)size); memcpy(h + 136, "00000000000", 12);
    h[156] = '0'; memcpy(h + 257, "ustar", 6); memcpy(h + 263, "00", 2); memcpy(h + 329, "0000000", 8); memcpy(h + 337, "0000000", 8);
    unsigned sum = 0; for (int i = 0; i < 512; i++) sum += (i >= 148 && i < 156) ? ' ' : h[i];
    snprintf((char *)h + 148, 8, "%06o", sum); h[155] = ' ';
    return 0;
}
static const uint8_t g_zero[1024];
static void tar_pad(zw_t *w, uint64_t size) { size_t pad = (size_t)((512 - size % 512) % 512); if (pad) zw_put(w, g_zero, pad); }

// ---- 条目清单 ----
typedef struct { char *name, *path; uint64_t size; } ent_t;
typedef struct { ent_t *v; size_t n, cap; } ents_t;
static int ents_add(ents_t *e, const char *name, const char *path, uint64_t size) {
    if (e->n == e->cap) { size_t c = e->cap ? e->cap * 2 : 64; ent_t *v = realloc(e->v, c * sizeof *v); if (!v) return -1; e->v = v; e->cap = c; }
    e->v[e->n].name = strdup(name); e->v[e->n].path = strdup(path); e->v[e->n].size = size;
    if (!e->v[e->n].name || !e->v[e->n].path) return -1;
    e->n++; return 0;
}
static void ents_free(ents_t *e) { for (size_t i = 0; i < e->n; i++) { free(e->v[i].name); free(e->v[i].path); } free(e->v); memset(e, 0, sizeof *e); }
static int ent_cmp(const void *a, const void *b) { return strcmp(((const ent_t *)a)->name, ((const ent_t *)b)->name); }
// dir 下全部普通文件（递归；跳过点开头的名字：写到一半的临时件），条目名 = prefix + 相对路径
static int walk(ents_t *e, const char *dir, const char *prefix, int skip_dot) {
    DIR *d = opendir(dir); if (!d) return errno == ENOENT ? 0 : -1;
    struct dirent *x; int rc = 0;
    while (!rc && (x = readdir(d))) {
        if (!strcmp(x->d_name, ".") || !strcmp(x->d_name, "..") || (skip_dot && x->d_name[0] == '.')) continue;
        char p[4096], n[4096]; struct stat st;
        if (snprintf(p, sizeof p, "%s/%s", dir, x->d_name) >= (int)sizeof p || snprintf(n, sizeof n, "%s%s", prefix, x->d_name) >= (int)sizeof n) { rc = -1; errno = ENAMETOOLONG; break; }
        if (lstat(p, &st)) { rc = -1; break; }
        if (S_ISDIR(st.st_mode)) { char np[4100]; snprintf(np, sizeof np, "%s/", n); rc = walk(e, p, np, skip_dot); }
        else if (S_ISREG(st.st_mode)) rc = ents_add(e, n, p, (uint64_t)st.st_size);
    }
    closedir(d); return rc;
}

static NSString *json_value(id v) {   // 一个值的 JSON 文本（字符串 / 数字 / 对象），供手拼 s2arm.json；转不了给 null
    NSData *d = v ? [NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingFragmentsAllowed | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil] : nil;
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
}

// 一次导出的现场：出错时由 s2a_game_export 统一收尾（关文件、删 .part、放内存）
typedef struct { int fd; char part[2400]; ents_t ents; zw_t w; uint8_t *buf; } gexp_t;
#define FAIL(code, ...) do { if (why && why_n) snprintf(why, why_n, __VA_ARGS__); return (code); } while (0)
static int export_body(gexp_t *x, const char *proc_docs, const char *gid_in, const char *out_dir, char *s2arm_out, size_t s2arm_n, char *img_out, size_t img_n, char *why, size_t why_n) {
    char gid[17]; size_t gl = gid_in ? strlen(gid_in) : 0;
    if (gl != 16) FAIL(S2A_GEXP_NO_PROGRAM, "游戏号「%s」不对", gid_in ? gid_in : "");
    for (int i = 0; i < 16; i++) { char c = gid_in[i]; if (c >= 'a' && c <= 'f') c -= 32;
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) FAIL(S2A_GEXP_NO_PROGRAM, "游戏号「%s」不对", gid_in); gid[i] = c; }
    gid[16] = 0;
    // 位置：同导入端（s2a_s2arm_import 写 <base>/games/<号>/program 与 资源包；s2a_pack_root 是游戏库 / 起局用的资源包根）
    char base[1200], gdocs[1400], root[1600], want[1600], prog[1600];
    if (s2a_pack_base(base, sizeof base, proc_docs) <= 0) FAIL(S2A_GEXP_IO, "文档根 %s 不是 …/Documents，找不到资源位置", proc_docs ? proc_docs : "");
    snprintf(gdocs, sizeof gdocs, "%s/games/%s", proc_docs, gid); s2a_pack_root(root, sizeof root, gdocs);
    snprintf(want, sizeof want, "%s/games/%s/资源包", base, gid); snprintf(prog, sizeof prog, "%s/games/%s/program", base, gid);
    if (strcmp(root, want)) FAIL(S2A_GEXP_IN_BUNDLE, "这款的资源包在 App 包里（%s），不能导出", root);
    // 程序包：清单 + 它的 dir 指着的版本目录
    NSString *catp = [@(prog) stringByAppendingPathComponent:@"catalogue.json"];
    NSData *cd = [NSData dataWithContentsOfFile:catp];
    id co = cd ? [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil] : nil;
    if (![co isKindOfClass:NSDictionary.class]) FAIL(S2A_GEXP_NO_PROGRAM, "%s", cd ? "程序包清单 program/catalogue.json 读不出来" : "这款没有程序包（program/catalogue.json 不在）");
    NSDictionary *cat = co; NSString *dir = [cat[@"dir"] isKindOfClass:NSString.class] ? cat[@"dir"] : nil;
    if (!dir.length || ![dir hasPrefix:@"v-"] || [dir containsString:@"/"] || [dir containsString:@".."]) FAIL(S2A_GEXP_NO_PROGRAM, "程序包清单没有可用的版本目录（dir「%s」）", dir.UTF8String ?: "");
    NSString *vdir = [@(prog) stringByAppendingPathComponent:dir]; BOOL isdir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:vdir isDirectory:&isdir] || !isdir) FAIL(S2A_GEXP_NO_PROGRAM, "程序包版本目录 %s 不在", dir.UTF8String);
    struct stat st; char p[2400];
    snprintf(p, sizeof p, "%s/.partial", root); if (!lstat(p, &st)) FAIL(S2A_GEXP_PARTIAL, "这款资源包只部分可玩（有 .partial），补齐后再导出");
    char gimg[2400]; snprintf(gimg, sizeof gimg, "%s/game.img", root); int romfs = 0; uint64_t img_size = 0;
    if (stat(gimg, &st) || !S_ISREG(st.st_mode)) { snprintf(gimg, sizeof gimg, "%s/romfs.img", root); romfs = 1;   // 推送布局：romfs.img + 散文件
        if (stat(gimg, &st) || !S_ISREG(st.st_mode)) FAIL(S2A_GEXP_NO_IMG, "资源包里既没有 game.img 也没有 romfs.img（%s）", root);
        img_size = (uint64_t)st.st_size; }
    // 导出的清单：去掉 dir（导入端在开头插自己的），其余原样
    NSMutableDictionary *mc = [cat mutableCopy];
#ifdef S2A_UNIT_TEST
    if (!s2a_game_export_test_keep_dir)
#endif
    [mc removeObjectForKey:@"dir"];
    NSData *catb = [NSJSONSerialization dataWithJSONObject:mc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
    if (!catb) FAIL(S2A_GEXP_IO, "程序包清单转不回 JSON");
    // 条目：程序版本目录全部普通文件 + 资源包派生件白名单
    ents_t *E = &x->ents;
    if (walk(E, vdir.fileSystemRepresentation, "program/", 0)) FAIL(S2A_GEXP_IO, "读程序包版本目录 %s 失败：%s", dir.UTF8String, strerror(errno));
    size_t nprog = E->n;
    static const char *const tree[] = {"shaders", "romfs_overlay"}, *const one[] = {"romfs.s2aidx", "game.imgmap", "index.tsv", "manifest.json"};
    if (romfs) {   // index.tsv 列的除 romfs.img 外全部文件（机上状态文件、index.applied.tsv 不在表里；保险起见点开头的也不带）+ index.tsv、manifest.json 自己
        snprintf(p, sizeof p, "%s/index.tsv", root); FILE *f = fopen(p, "r"); if (!f) FAIL(S2A_GEXP_IO, "资源包没有 index.tsv（%s）：%s", root, strerror(errno));
        char line[4600]; int bad = 0;
        while (!bad && fgets(line, sizeof line, f)) { char *t = strchr(line, '\t'); if (!t) continue; *t = 0;
            if (!*line || *line == '.' || strstr(line, "/.") || *line == '/' || !strcmp(line, "romfs.img") || !strcmp(line, "index.tsv") || !strcmp(line, "manifest.json") || !strcmp(line, "index.applied.tsv")) continue;
            char fp[6800], nm[4700]; snprintf(fp, sizeof fp, "%s/%s", root, line); snprintf(nm, sizeof nm, "pack/%s", line);
            if (stat(fp, &st) || !S_ISREG(st.st_mode)) bad = 1; else if (ents_add(E, nm, fp, (uint64_t)st.st_size)) bad = 2; }
        fclose(f);
        if (bad == 1) FAIL(S2A_GEXP_PARTIAL, "资源包缺 %s（安装没完成），补齐后再导出", line);
        if (bad == 2) FAIL(S2A_GEXP_IO, "内存不够");
        for (size_t i = 2; i < sizeof one / sizeof *one; i++) { char nm[64]; snprintf(p, sizeof p, "%s/%s", root, one[i]); snprintf(nm, sizeof nm, "pack/%s", one[i]);
            if (!stat(p, &st) && S_ISREG(st.st_mode) && ents_add(E, nm, p, (uint64_t)st.st_size)) FAIL(S2A_GEXP_IO, "内存不够"); }
    } else
    for (size_t i = 0; i < sizeof tree / sizeof *tree; i++) { char pre[64]; snprintf(p, sizeof p, "%s/%s", root, tree[i]); snprintf(pre, sizeof pre, "pack/%s/", tree[i]);
        if (walk(E, p, pre, 1)) FAIL(S2A_GEXP_IO, "读资源包 %s 失败：%s", tree[i], strerror(errno)); }
    if (!romfs) for (size_t i = 0; i < sizeof one / sizeof *one; i++) { char nm[64]; snprintf(p, sizeof p, "%s/%s", root, one[i]); snprintf(nm, sizeof nm, "pack/%s", one[i]);
        if (!stat(p, &st) && S_ISREG(st.st_mode) && ents_add(E, nm, p, (uint64_t)st.st_size)) FAIL(S2A_GEXP_IO, "内存不够"); }
    qsort(E->v, nprog, sizeof *E->v, ent_cmp); qsort(E->v + nprog, E->n - nprog, sizeof *E->v, ent_cmp);
    uint64_t total = catb.length; for (size_t i = 0; i < E->n; i++) total += E->v[i].size;
    // s2arm.json：字段与次序同电脑端 export_s2arm（json.dumps indent=1），另加 exported_by
    NSString *pack_sha = @"";
    { snprintf(p, sizeof p, "%s/manifest.json", root); NSData *md = [NSData dataWithContentsOfFile:@(p)];
      id mo = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
      if ([mo isKindOfClass:NSDictionary.class] && [mo[@"index_sha256"] isKindOfClass:NSString.class]) pack_sha = mo[@"index_sha256"]; }
    NSMutableString *head = [NSMutableString stringWithFormat:@"{\n \"format\": \"s2arm\",\n \"schema\": 1,\n \"title_id\": \"%s\"", gid];
    for (NSString *k in @[@"name", @"display_version", @"host_abi", @"chain", @"rewriter_id", @"image", @"image_sha256", @"source_sha256"])
        if (cat[k] && cat[k] != NSNull.null) [head appendFormat:@",\n \"%@\": %@", k, json_value(cat[k])];
    [head appendFormat:@",\n \"pack\": %@,\n \"bytes\": %llu", json_value(pack_sha), (unsigned long long)total];
    if (cat[@"signer"]) [head appendFormat:@",\n \"signer\": %@", json_value(cat[@"signer"])];
    if (romfs) { char fp[17]; if (s2a_img_fp(gimg, img_size, fp)) FAIL(S2A_GEXP_IO, "读 %s 算指纹失败：%s", gimg, strerror(errno));
        [head appendFormat:@",\n \"img_kind\": \"romfs\",\n \"img_size\": %llu,\n \"img_fp\": \"%s\"", (unsigned long long)img_size, fp]; }
    [head appendString:@",\n \"exported_by\": \"phone\"\n}"];
    NSData *headb = [head dataUsingEncoding:NSUTF8StringEncoding];
    // 文件名：同电脑端 s2arm_name（游戏名里 \/:*?"<>| 与控制字符换空格、去首尾空格和点；空了用游戏号）
    NSString *nm = [cat[@"name"] isKindOfClass:NSString.class] ? cat[@"name"] : @"";
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < nm.length; i++) { unichar c = [nm characterAtIndex:i];
        if (c < 0x20 || (c < 0x80 && strchr("\\/:*?\"<>|", (int)c))) [clean appendString:@" "]; else [clean appendFormat:@"%C", c]; }
    NSString *stem = [clean stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    if (!stem.length) stem = @(gid);
    char outp[2400], imgp[2400];
    if (snprintf(outp, sizeof outp, "%s/%s.s2arm", out_dir, stem.fileSystemRepresentation) >= (int)sizeof outp || snprintf(imgp, sizeof imgp, "%s/%s.img", out_dir, stem.fileSystemRepresentation) >= (int)sizeof imgp
        || snprintf(x->part, sizeof x->part, "%s.part", outp) >= (int)sizeof x->part) { x->part[0] = 0; FAIL(S2A_GEXP_IO, "导出路径太长"); }
    // 写 .s2arm.part：边读边写
    if ((x->fd = open(x->part, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0) FAIL(S2A_GEXP_IO, "建 %s 失败：%s", x->part, strerror(errno));
    zw_t *w = &x->w; uint8_t h[512];
    if (zw_begin(w, x->fd)) FAIL(S2A_GEXP_IO, "写 %s 失败：%s", x->part, strerror(w->err ? w->err : ENOMEM));
    tar_head(h, "s2arm.json", headb.length); zw_put(w, h, 512); zw_put(w, headb.bytes, headb.length); tar_pad(w, headb.length);
    tar_head(h, "program/catalogue.json", catb.length); zw_put(w, h, 512); zw_put(w, catb.bytes, catb.length); tar_pad(w, catb.length);
    if (!(x->buf = malloc(1 << 20))) FAIL(S2A_GEXP_IO, "内存不够");
    for (size_t i = 0; i < E->n && !w->err; i++) {
        ent_t *e = &E->v[i];
        if (tar_head(h, e->name, e->size)) FAIL(S2A_GEXP_IO, "%s 文件路径太长（或文件超过 8 GB），打不进 .s2arm", e->name);
        zw_put(w, h, 512);
        int in = open(e->path, O_RDONLY); if (in < 0) FAIL(S2A_GEXP_IO, "打不开 %s：%s", e->path, strerror(errno));
        uint64_t got = 0; ssize_t r;
        while (got < e->size && (r = read(in, x->buf, (size_t)(e->size - got < (1 << 20) ? e->size - got : (1 << 20)))) != 0) {
            if (r < 0) { if (errno == EINTR) continue; break; }
            zw_put(w, x->buf, (size_t)r); got += (uint64_t)r; }
        close(in);
        if (got != e->size) FAIL(S2A_GEXP_IO, "读 %s 读到 %llu 字节，和大小 %llu 对不上（文件在变）", e->path, (unsigned long long)got, (unsigned long long)e->size);
        tar_pad(w, e->size);
    }
    zw_put(w, g_zero, sizeof g_zero);   // 归档尾：两块全零
    int bad = zw_end(w), er = w->err; if (close(x->fd) && !bad) { bad = 1; er = errno; } x->fd = -1;
    if (bad) FAIL(S2A_GEXP_IO, "写 %s 失败：%s", x->part, strerror(er));
    if (rename(x->part, outp)) FAIL(S2A_GEXP_IO, "%s 改名失败：%s", x->part, strerror(errno));
    x->part[0] = 0;
    // .img：同卷硬链接（不占新空间）→ 不行再克隆 → 都不行报错
    unlink(imgp);
    if (link(gimg, imgp)) { int e1 = errno;
#if defined(__APPLE__)
        if (clonefile(gimg, imgp, 0))
#endif
        { int e2 = errno; unlink(outp); FAIL(S2A_GEXP_IO, "%s 放不到导出文件夹（硬链接：%s；克隆：%s）", romfs ? "romfs.img" : "game.img", strerror(e1), strerror(e2)); } }
    if (s2arm_out && s2arm_n) snprintf(s2arm_out, s2arm_n, "%s", outp);
    if (img_out && img_n) snprintf(img_out, img_n, "%s", imgp);
    return 0;
}
#undef FAIL
int s2a_game_export(const char *proc_docs, const char *gid, const char *out_dir, char *s2arm_out, size_t s2arm_n, char *img_out, size_t img_n, char *why, size_t why_n) {
    if (why && why_n) why[0] = 0;
    if (s2arm_out && s2arm_n) s2arm_out[0] = 0;
    if (img_out && img_n) img_out[0] = 0;
    gexp_t x; memset(&x, 0, sizeof x); x.fd = -1;
    int rc;
    @autoreleasepool { rc = export_body(&x, proc_docs, gid, out_dir, s2arm_out, s2arm_n, img_out, img_n, why, why_n); }
    if (x.w.buf) free(x.w.buf);
    free(x.buf);
    if (x.fd >= 0) close(x.fd);
    if (x.part[0]) unlink(x.part);
    ents_free(&x.ents);
    return rc;
}
