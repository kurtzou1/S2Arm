// 资源包收推送（测试层契约 tests/真机契约.md 第 1、2 节 S2A_PACK_APPLY_ONLY）：App 起来只做——
//   解开 Documents/资源包/.incoming/*.tar（按名字序，解完即删）→ 写 资源包/.applied = manifest.json 的 index_sha256 → 往 Documents/unpack.log 追加一行 → 退出。
//   失败行含「返回 -<码>」（执行器按这个判红）。每解完一个 tar 记一行「进度：…」；全部解完后删掉资源包下不在 index.tsv 里的旧文件（旧版分卷等）；
//   再逐条核 index.tsv 的文件在、大小对（-8），都对才写 .applied / index.applied.tsv——「已应用」= 机上真有。
//   iOS 上在后台线程跑（host_main.c），UIKit 照常起来——近 10 GB 在启动路径上同步跑会被启动看门狗杀（测试设备1 10-19 首局实测）。tar 是执行器用 `tar --format pax` 打的：只认普通文件、目录、pax 扩展头（path / size），
//   路径相对资源包根；绝对路径、含 .. 的路径、其他条目类型一律判失败（不猜）。
#include "native.h"
#include "s2a_docs.h"   // iOS 进程级容器 Documents（s2a_container_docs）
#include "s2a_launch_ctx.h"   // 资源包闸门按启动上下文定文档根（多款容器 = 本款 Documents/games/<游戏号>）
#include "../include/s2a_ui_text.h"   // 提示页 / 说明页文字：中文原宏 + _EN，S2A_UI 按界面语言取（#316）
#include "../include/s2a_selfcheck_page.h"   // 说明页标题「游戏资源不完整」与自检提示页同一句
__attribute__((weak)) int s2a_ui_zh(void) { return 1; }   // 界面语言（s2a_ui_text.h）：iOS ios/app.m、Mac macos/front_mac.m 强定义；别的平台 / 只链本文件的单测按中文
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// 写失败现场（10-20 测试设备2 巫师3 收推送连续「返回 -4」，看不出是哪个条目）：失败的那一步、路径与 errno，解包失败时写进 unpack.log
static char g_untar_err[2400];
static int g_untar_trunc;   // 本次解包碰到截短（读到的少于条目 / 包尾结束块）
static int g_fail_errno;   // 最近一次失败的 errno（只用来判「空间满」给码，s2a_install_code）
static void untar_err(const char *step, const char *path, int e) { g_fail_errno = e; snprintf(g_untar_err, sizeof g_untar_err, "%s %s：errno %d %s", step, path, e, strerror(e)); }
static int mkdirs(char *p) {   // 建 p 的各级父目录（p 是文件路径）；已存在但不是目录（同名文件挡路）也算失败
    for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; int r = mkdir(p, 0755), e = errno; struct stat st;
        if (r && e == EEXIST && (stat(p, &st) || !S_ISDIR(st.st_mode))) { r = -1; e = ENOTDIR; }
        if (r && e != EEXIST) { untar_err("建目录", p, e); *s = '/'; return -1; } *s = '/'; }
    return 0;
}
static uint64_t oct(const char *s, int n) { uint64_t v = 0; for (int i = 0; i < n && s[i]; i++) if (s[i] >= '0' && s[i] <= '7') v = v * 8 + (uint64_t)(s[i] - '0'); return v; }
static int safe(const char *p) { return *p && *p != '/' && !strstr(p, "../") && strcmp(p, "..") && !(strlen(p) >= 3 && !strcmp(p + strlen(p) - 3, "/..")); }

// 解一个 tar 到 root；返回 0 成功，负数 = 失败码（-1 读不了 -2 头坏 -3 路径不安全 -4 写失败；认不出的条目类型跳过、不算失败）；*nf / *nb 累计文件数与字节
int s2a_untar(const char *tar, const char *root, unsigned *nf, uint64_t *nb) {
    g_untar_trunc = 0; g_untar_err[0] = 0;   // 每次从空现场开始：不写现场的失败不能贴上一次的（iOS 装机剃刀 #10）
    int fd = open(tar, O_RDONLY); if (fd < 0) { untar_err("打开包", tar, errno); return -1; }
    uint8_t h[512], buf[1 << 16]; char pax_path[4096] = ""; uint64_t pax_size = (uint64_t)-1; int rc = 0;
    for (;;) {
        // 没读到归档尾（全零块）就到文件末尾 / 只读到半个头 = 包被截短（执行器用 tar 打的包必有归档尾；截在条目边界时旧代码当成解完、把缺文件的状态记成已应用）
        ssize_t r = read(fd, h, 512); if (r >= 0 && r != 512) { untar_err("包被截短（没有归档尾）", tar, EIO); g_untar_trunc = 1; rc = -4; break; } if (r < 0) { untar_err("读包头", tar, errno); rc = -2; break; }
        int zero = 1; for (int i = 0; i < 512 && zero; i++) zero = !h[i]; if (zero) break;   // 归档尾（两块全零）
        unsigned sum = 0; for (int i = 0; i < 512; i++) sum += (i >= 148 && i < 156) ? ' ' : h[i];
        if (sum != oct((char *)h + 148, 8)) { untar_err("条目头校验和不对（包没传对）", tar, EINVAL); rc = -2; break; }
        char type = (char)h[156]; uint64_t size = oct((char *)h + 124, 12);
        char name[4096];
        if (h[345]) snprintf(name, sizeof name, "%.155s/%.100s", (char *)h + 345, (char *)h); else snprintf(name, sizeof name, "%.100s", (char *)h);
        if (pax_size != (uint64_t)-1) size = pax_size;
        if (pax_path[0]) strlcpy(name, pax_path, sizeof name);
        uint64_t pad = (512 - size % 512) % 512;
        if (type == 'x' || type == 'g') {   // pax 扩展头：「长度 键=值\n」记录；只取 path / size，作用于下一个条目（g 全局头忽略）
            if (size > sizeof buf - 1 || read(fd, buf, size) != (ssize_t)size || lseek(fd, (off_t)pad, SEEK_CUR) < 0) { untar_err("读 pax 扩展头", tar, EINVAL); rc = -2; break; }
            buf[size] = 0;   // strtoul 不越过本头数据
            pax_path[0] = 0; pax_size = (uint64_t)-1;
            if (type == 'g') continue;
            for (uint64_t o = 0; o < size;) {
                char *rec = (char *)buf + o; unsigned long len = strtoul(rec, NULL, 10); if (!len || o + len > size) { untar_err("pax 扩展头记录长度不对", tar, EINVAL); rc = -2; break; }
                // 记录格式「长度 键=值\n」：空格与换行都得在本条记录内（11-01 审计 P2-17：缺空格时 strchr 得 NULL、+1 后解引用崩；按整条长度找「=」会越过记录尾），不符判头坏
                char *sp = memchr(rec, ' ', len), *end = rec + len - 1;
                if (!sp || *end != '\n') { untar_err("pax 扩展头记录格式异常（缺空格或换行）", tar, EINVAL); rc = -2; break; }
                char *kv = sp + 1, *eq = memchr(kv, '=', (size_t)(end - kv));
                if (!eq) { untar_err("pax 扩展头记录格式异常（缺等号）", tar, EINVAL); rc = -2; break; }
                if (eq && eq - kv == 4 && !memcmp(kv, "path", 4) && (size_t)(end - eq - 1) < sizeof pax_path) { memcpy(pax_path, eq + 1, (size_t)(end - eq - 1)); pax_path[end - eq - 1] = 0; }
                if (eq && eq - kv == 4 && !memcmp(kv, "size", 4)) pax_size = strtoull(eq + 1, NULL, 10);
                o += len;
            }
            if (rc) break;
            continue;
        }
        pax_path[0] = 0; pax_size = (uint64_t)-1;
        if (!strncmp(name, "./", 2)) memmove(name, name + 2, strlen(name + 2) + 1);
        if (type == '5') { if (!*name) continue; if (!safe(name)) { untar_err("路径不安全", name, EINVAL); rc = -3; break; } char p[8192]; snprintf(p, sizeof p, "%s/%s/x", root, name); if (mkdirs(p)) { rc = -4; break; } continue; }
        // 普通文件 / 目录 / pax 头以外的条目（链接、设备等）：执行器打的包里没有，v0.3.1 起认不出的不挡整次解包——跳过它的数据、记一笔，
        //   真缺了什么由后面 index.tsv 核对按缺文件 / 部分可玩处理（原先返回 -5，整个资源包「安装没完成」）
        if (type != '0' && type != 0) {
            LOG("【黄】解包：%s 条目类型 %c 认不出，跳过（%llu 字节）", name, type, (unsigned long long)size);
            if (lseek(fd, (off_t)(size + pad), SEEK_CUR) < 0) { untar_err("跳过认不出的条目", name, errno); rc = -2; break; }
            continue;
        }
        if (!safe(name)) { LOG("【红】解包：路径不安全 %s", name); untar_err("路径不安全", name, EINVAL); rc = -3; break; }
        char p[8192], tmp[8300]; snprintf(p, sizeof p, "%s/%s", root, name); snprintf(tmp, sizeof tmp, "%s.part", p);
        if (mkdirs(p)) { rc = -4; break; }
        int of = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (of < 0) { untar_err("建临时文件", tmp, errno); rc = -4; break; }
        for (uint64_t left = size; left;) {
            size_t k = left > sizeof buf ? sizeof buf : (size_t)left;
            ssize_t rr = read(fd, buf, k); if (rr != (ssize_t)k) { untar_err(rr < 0 ? "读包" : "包被截短（读到的少于条目大小）", name, rr < 0 ? errno : EIO); if (rr >= 0) g_untar_trunc = 1; rc = -4; break; }
            if (write(of, buf, k) != (ssize_t)k) { untar_err("写文件", tmp, errno); rc = -4; break; }
            left -= k;
        }
        if (close(of) && !rc) { untar_err("关文件", tmp, errno); rc = -4; }
        if (!rc && rename(tmp, p)) { untar_err("改名到", p, errno); rc = -4; }
        if (rc) { unlink(tmp); break; }
        if (pad && lseek(fd, (off_t)pad, SEEK_CUR) < 0) { untar_err("跳过条目填充", name, errno); rc = -2; break; }
        (*nf)++; *nb += size;
    }
    close(fd); return rc;
}

#include <stdarg.h>
#include <ftw.h>
static void log_line(const char *logp, const char *fmt, ...) {
    time_t now = time(NULL); char ts[32]; strftime(ts, sizeof ts, "%m-%d %H:%M:%S", localtime(&now));
    char b[1024]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    FILE *f = fopen(logp, "a"); if (f) { fprintf(f, "%s %s\n", ts, b); fclose(f); }
}
// 清旧文件：遍历资源包根，删掉不在 index.tsv 里的普通文件（index.tsv / manifest.json / 以 . 开头的执行器与 App 记账文件、.incoming 目录除外）
// ---- 单一 IMG v1（pack/img.py，v0.3.0）：资源包根的 game.img。RomFS 由服务层按偏移直接读；exefs / ctl / aoc / 系统数据这类小文件在这里一次性解到资源包根，
//   运行时照旧按路径读（不改各读取点）。头：0 "S2AIMG01" | 8 u32 格式号 | 112/120 目录表偏移 / 长 | 128 整个文件长；
//   目录表：u32 槽数 | u32 条目数 | 槽数 × {u64 路径哈希（0 = 空槽）, u64 偏移, u64 长度, u32 路径偏移, u32 路径长} | 路径区。romfs.list 是给服务层的、不解
typedef struct { char *rel; uint64_t off, len; } img_ent;
// 应用资源包的分段进度（游戏库「安装中」扇形蒙版用，s2a_pack_apply_progress 照旧只报待解包数）：
//   phase 1 = 解开推送包（done / total = 包数）；2 = 从 game.img 解小文件（字节）；3 = 核对机上文件（文件数）。主调方设、本文件只调，NULL = 不报
void (*s2a_pack_apply_phase)(int phase, uint64_t done, uint64_t total);
#define PHASE(ph, d, t) do { if (s2a_pack_apply_phase) s2a_pack_apply_phase((ph), (d), (t)); } while (0)
static int img_toc(const char *root, img_ent **out, size_t *n) {   // 0 = 读到（*n 条）；1 = 没有 game.img；负数 = IMG 坏 / 格式号不认
    char p[2200]; snprintf(p, sizeof p, "%s/game.img", root); *out = NULL; *n = 0;
    int fd = open(p, O_RDONLY); if (fd < 0) return 1;
    uint8_t h[136]; struct stat st; int rc = -10;
    if (pread(fd, h, sizeof h, 0) != (ssize_t)sizeof h || memcmp(h, "S2AIMG01", 8) || fstat(fd, &st)) goto out;
    uint32_t fmt; memcpy(&fmt, h + 8, 4); if (fmt != 1) { rc = -11; goto out; }
    uint64_t to, tl, total; memcpy(&to, h + 112, 8); memcpy(&tl, h + 120, 8); memcpy(&total, h + 128, 8);
    if (total != (uint64_t)st.st_size || tl < 8 || tl > (64u << 20) || to + tl > total) goto out;
    uint8_t *t = malloc(tl); if (!t || pread(fd, t, tl, (off_t)to) != (ssize_t)tl) { free(t); goto out; }
    uint32_t slots; memcpy(&slots, t, 4); size_t pbase = 8 + (size_t)slots * 32;
    if (pbase > tl) { free(t); goto out; }
    img_ent *e = calloc(slots ? slots : 1, sizeof *e); size_t k = 0;
    for (uint32_t i = 0; i < slots; i++) { const uint8_t *s = t + 8 + (size_t)i * 32; uint64_t hh; memcpy(&hh, s, 8); if (!hh) continue;
        uint32_t po, pl; memcpy(&e[k].off, s + 8, 8); memcpy(&e[k].len, s + 16, 8); memcpy(&po, s + 24, 4); memcpy(&pl, s + 28, 4);
        if (pbase + po + pl > tl || e[k].off + e[k].len > total) { for (size_t j = 0; j < k; j++) free(e[j].rel); free(e); free(t); goto out; }
        e[k].rel = strndup((const char *)t + pbase + po, pl);
        if (!strcmp(e[k].rel, "romfs.list")) { free(e[k].rel); continue; }
        k++; }
    free(t); *out = e; *n = k; rc = 0;
out:
    close(fd); return rc;
}
static void img_free(img_ent *e, size_t n) { for (size_t i = 0; i < n; i++) free(e[i].rel); free(e); }
// 把目录表里的文件解到资源包根：已在且长度对的跳过（重复调用是空操作）；先写 .img.tmp 再改名，断了不留半个文件。→ 0 / 负数（g_untar_err 记现场）
static int img_extract(const char *root, unsigned *nf, uint64_t *nb) {
    img_ent *e; size_t n; int rc = img_toc(root, &e, &n); if (rc) return rc > 0 ? 0 : rc;
    char ip[2200]; snprintf(ip, sizeof ip, "%s/game.img", root); int fd = open(ip, O_RDONLY); if (fd < 0) { img_free(e, n); return -10; }
    uint8_t *buf = malloc(1 << 20); rc = 0;
    uint64_t all = 0, got = 0; for (size_t i = 0; i < n; i++) all += e[i].len;
    PHASE(2, 0, all);
    for (size_t i = 0; i < n && !rc; i++) {
        if (!safe(e[i].rel)) { untar_err("IMG 路径不安全", e[i].rel, EINVAL); rc = -3; break; }
        char p[2400], tmp[2500]; struct stat st; snprintf(p, sizeof p, "%s/%s", root, e[i].rel);
        if (!stat(p, &st) && (uint64_t)st.st_size == e[i].len) { got += e[i].len; PHASE(2, got, all); continue; }
        if (mkdirs(p)) { rc = -4; break; }
        snprintf(tmp, sizeof tmp, "%s.img.tmp", p); int o = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (o < 0) { untar_err("建", tmp, errno); rc = -4; break; }
        for (uint64_t done = 0; done < e[i].len && !rc;) { size_t want = e[i].len - done > (1u << 20) ? (1u << 20) : (size_t)(e[i].len - done);
            ssize_t r = pread(fd, buf, want, (off_t)(e[i].off + done));
            if (r <= 0 || write(o, buf, (size_t)r) != r) { untar_err("从 IMG 解", e[i].rel, errno); rc = -4; } else { done += (uint64_t)r; got += (uint64_t)r; PHASE(2, got, all); } }
        if (close(o) && !rc) { untar_err("写完关闭", tmp, errno); rc = -4; }
        if (!rc && rename(tmp, p)) { untar_err("改名", p, errno); rc = -4; }
        if (rc) unlink(tmp); else { (*nf)++; *nb += e[i].len; }
    }
    free(buf); close(fd); img_free(e, n); return rc;
}
// 资源包根有 game.img、还没按这份清单应用过（.applied ≠ manifest 的 index_sha256）→ 要先解开（导入状态判「待导入」，游戏库 / 闸门照常触发 s2a_pack_apply）
static int manifest_sha(const char *path, char *out, size_t n);
//   清单读不出（推送开头置空了、还没写回）按「要解」：原先当「不用解」，闸门判就绪放行半截镜像（iOS 装机剃刀 #29）；在不在传由闸门另判（s2a_import_transferring）
static int img_needs_apply(const char *root) {
    char p[2200], want[200], got[200] = ""; struct stat st; snprintf(p, sizeof p, "%s/game.img", root); if (stat(p, &st)) return 0;
    snprintf(p, sizeof p, "%s/manifest.json", root); if (manifest_sha(p, want, sizeof want)) return 1;
    snprintf(p, sizeof p, "%s/.applied", root); FILE *f = fopen(p, "r"); if (f) { size_t k = fread(got, 1, sizeof got - 1, f); got[k] = 0; got[strcspn(got, "\r\n")] = 0; fclose(f); }
    return strcmp(got, want) != 0;
}

static char **g_keep; static size_t g_nkeep, g_rootlen; static unsigned *g_nd; static uint64_t *g_db;
static int keep_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static int prune_one(const char *p, const struct stat *st, int flag, struct FTW *f) {
    (void)f; if (flag != FTW_F) return 0;
    const char *rel = p + g_rootlen + 1;
    if (!strcmp(rel, "index.tsv") || !strcmp(rel, "index.applied.tsv") || !strcmp(rel, "manifest.json") || rel[0] == '.' || !strncmp(rel, ".incoming/", 10)) return 0;   // index.applied.tsv：核对不过时它得留着（执行器据它补推）
    if (bsearch(&rel, g_keep, g_nkeep, sizeof *g_keep, keep_cmp)) return 0;
    if (!unlink(p)) { (*g_nd)++; *g_db += (uint64_t)st->st_size; }
    return 0;
}
// 删空了的目录也清掉（10-25 测试设备2 马车8：旧直连库的 shaders/direct/b-<链>/ 文件删光、目录还在，开局「包里有 b-… 但没有 shader_map.tsv」报红误导排查）。
//   后序遍历（子目录先于父目录），只删空目录（rmdir 非空即失败、不管）；根、以 . 开头的目录（.incoming 等记账目录）及其下不动
static int prune_dir(const char *p, const struct stat *st, int flag, struct FTW *f) {
    (void)st; if (flag != FTW_DP || f->level == 0) return 0;
    const char *rel = p + g_rootlen + 1;
    if (rel[0] == '.' || strstr(rel, "/.")) return 0;
    rmdir(p);
    return 0;
}
static int prune(const char *root, unsigned *nd, uint64_t *db) {
    char ip[2100]; snprintf(ip, sizeof ip, "%s/index.tsv", root);
    FILE *f = fopen(ip, "r"); if (!f) return -7;
    size_t cap = 1024; g_keep = malloc(cap * sizeof *g_keep); g_nkeep = 0; char line[4600];
    while (fgets(line, sizeof line, f)) { char *t = strchr(line, '\t'); if (!t) continue; *t = 0; if (g_nkeep == cap) g_keep = realloc(g_keep, (cap *= 2) * sizeof *g_keep); g_keep[g_nkeep++] = strdup(line); }
    fclose(f);
    { img_ent *e; size_t n; if (!img_toc(root, &e, &n)) { for (size_t i = 0; i < n; i++) { if (g_nkeep == cap) g_keep = realloc(g_keep, (cap *= 2) * sizeof *g_keep); g_keep[g_nkeep++] = strdup(e[i].rel); } img_free(e, n); } }   // 从 game.img 解出来的小文件不在 index.tsv 里，不能当旧文件删
    qsort(g_keep, g_nkeep, sizeof *g_keep, keep_cmp);
    g_rootlen = strlen(root); g_nd = nd; g_db = db;
    nftw(root, prune_one, 32, FTW_PHYS);
    nftw(root, prune_dir, 32, FTW_PHYS | FTW_DEPTH);
    for (size_t i = 0; i < g_nkeep; i++) free(g_keep[i]); free(g_keep);
    return 0;
}

// 核对机上实况（10-25 测试设备2 马车8：执行器推了 4 批、App 解开 0 个包，照样把新 index.tsv 记成 index.applied.tsv / .applied，
//   之后两局执行器信这份「已应用」只推 3 个文件，机上没有直连库、退回通用）：index.tsv 每一行的文件都在、是普通文件、大小对得上，才算完整。
//   返回缺 / 不符的个数，ex 记第一个（「路径（不在 / 大小不符 / 不是文件）」，进日志）；progress = 1 时报「校验文件」阶段进度（解包那步）。
//   解包核对与闸门 s2a_pack_check 共用这一份（iOS 装机剃刀 #14：原先两份，闸门那份不查是不是普通文件，同名目录占位时两边结论相反）。
//   逐个 stat，九款最大索引约 39 万行、本机约 1 秒
// 起局离不了的核心文件（v0.3.1 缺件照玩）：程序（exefs/）、标题信息、单一 IMG / 旧 romfs 镜像。缺它们照旧不放行（物理上起不来）；
//   缺别的（旧形态的 romfs 散文件、着色器库、系统数据等）让玩家确认后照玩，真读到时游戏 Break → s2a_pack_help_on_break 说人话
int s2a_pack_core_path(const char *rel) {
    return !strncmp(rel, "exefs/", 6) || !strcmp(rel, "ctl/control.nacp") || !strcmp(rel, "game.img") || !strcmp(rel, "romfs.img");
}
static unsigned index_check_core(const char *root, char *ex, size_t exn, int progress, unsigned *core);
static unsigned index_check(const char *root, char *ex, size_t exn, int progress) { return index_check_core(root, ex, exn, progress, NULL); }
static unsigned index_check_core(const char *root, char *ex, size_t exn, int progress, unsigned *core) {
    char ip[2100]; snprintf(ip, sizeof ip, "%s/index.tsv", root); FILE *f = fopen(ip, "r");
    if (core) *core = 0;
    if (!f) { if (exn) snprintf(ex, exn, "index.tsv 打不开：%s", errno == ENOENT ? "不在" : strerror(errno)); if (core) *core = 1; return 1; }   // 审计 P2-7：原先只记缺 1 个、例子为空
    char line[4600], p[6800]; unsigned miss = 0; struct stat st; if (exn) ex[0] = 0;
    uint64_t total = 0, done = 0;
    if (progress) { while (fgets(line, sizeof line, f)) total++; rewind(f); PHASE(3, 0, total); }
    while (fgets(line, sizeof line, f)) {
        if (progress && (++done % 256 == 0 || done == total)) PHASE(3, done, total);
        char *t = strchr(line, '\t'); if (!t) continue; *t = 0; long long want = atoll(t + 1);
        snprintf(p, sizeof p, "%s/%s", root, line);
        int gone = stat(p, &st) != 0;
        if (gone || !S_ISREG(st.st_mode) || st.st_size != want) { if (!miss++ && exn) snprintf(ex, exn, "%s（%s）", line, gone ? "不在" : !S_ISREG(st.st_mode) ? "不是文件" : "大小不符");
            if (core && s2a_pack_core_path(line)) (*core)++; }
    }
    if (ferror(f)) { if (exn) snprintf(ex, exn, "index.tsv 读失败：%s", strerror(errno)); miss++; if (core) (*core)++; }
    fclose(f); return miss;
}
// root/src 整份拷成 root/dst（先写 dst.tmp 再改名）；返回 0 成功
static int copy_atomic(const char *root, const char *src, const char *dst) {
    char a[2100], b[2100], t[2110]; snprintf(a, sizeof a, "%s/%s", root, src); snprintf(b, sizeof b, "%s/%s", root, dst); snprintf(t, sizeof t, "%s.tmp", b);
    FILE *in = fopen(a, "rb"); if (!in) return -1; FILE *out = fopen(t, "wb"); if (!out) { fclose(in); return -1; }
    char buf[65536]; size_t k; int bad = 0; while ((k = fread(buf, 1, sizeof buf, in)) > 0) if (fwrite(buf, 1, k, out) != k) { bad = 1; break; }
    bad |= ferror(in); fclose(in); bad |= fclose(out) != 0;
    if (bad || rename(t, b)) { unlink(t); return -1; } return 0;
}
// 写 root/name = s（先写 name.tmp 再改名；11-01 审计 P2-16：原先 fopen("w") 先截断再写，中途被杀 / 写失败旧标记就丢了）；返回 0 成功
static int write_atomic(const char *root, const char *name, const char *s) {
    char p[2100], t[2110]; snprintf(p, sizeof p, "%s/%s", root, name); snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w"); if (!f) return -1;
    int bad = fputs(s, f) < 0; bad |= fclose(f) != 0;
    if (bad || rename(t, p)) { unlink(t); return -1; } return 0;
}
static int name_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
// 读 manifest.json 里 "index_sha256":"…"（执行器写的定长格式，只取这一个键）
static int manifest_sha(const char *path, char *out, size_t n) {
    FILE *f = fopen(path, "r"); if (!f) return -1; char b[4096]; size_t k = fread(b, 1, sizeof b - 1, f); fclose(f); b[k] = 0;
    char *p = strstr(b, "\"index_sha256\""); if (!p || !(p = strchr(p + 14, '"'))) return -1;
    char *e = strchr(++p, '"'); if (!e || (size_t)(e - p) >= n) return -1;
    memcpy(out, p, (size_t)(e - p)); out[e - p] = 0; return 0;
}
// 玩家导入（s2a_import_gate）用：每批解完回调一次（已解批数、总批数），失败原因留给提示页
void (*s2a_pack_apply_progress)(int done, int total);
static char g_apply_fail[2400], g_apply_code[48];
const char *s2a_pack_apply_failure(void) { return g_apply_fail; }
// 失败给码（11-11 维护者「补上说人话的原因」）：码表在 launchers/shared/experience.v1.json errors.items（下一步在 pack/jobs/errors.py RECOVERY），
//   屏上按码显示标题 + 下一步，原文（s2a_pack_apply_failure）只进日志 / 诊断包。from_img = 失败出在从 game.img 解小文件那步。规格里没有的情形一律 ios_install_unknown
const char *s2a_install_code(int rc, int err, int truncated, int from_img) {
    if (!rc) return "";
    if (rc == -12) return "ios_install_dir_unwritable";
    if (err == ENOSPC || err == EDQUOT) return "ios_install_no_space";
    if (truncated || rc == -2) return "ios_install_pack_truncated";   // -2：推送包头 / 校验和不对，同样是没传对，重推补齐
    if (rc == -11) return "ios_install_img_format";
    if (rc == -10 || (from_img && rc == -3)) return "ios_install_img_corrupt";
    if (rc == -8) return "ios_install_files_missing";
    if (rc == -6 || rc == -7) return "ios_install_manifest_bad";
    if (rc == -4) return "ios_install_write_failed";
    return "ios_install_unknown";
}
const char *s2a_pack_apply_code(void) { return g_apply_code; }
// 返回进程退出码（0 成功）；docs = Documents 目录
int s2a_pack_apply(const char *docs) {
    char root[2048], inc[2100], logp[2100]; s2a_pack_root(root, sizeof root, docs); snprintf(inc, sizeof inc, "%s/.incoming", root); snprintf(logp, sizeof logp, "%s/unpack.log", docs);
    uint64_t t0 = now_ns(); unsigned ntar = 0, nf = 0; uint64_t nb = 0; int rc = 0, from_img = 0; char what[2300] = ""; g_fail_errno = 0; g_untar_trunc = 0; g_untar_err[0] = 0;
    // 本款目录 / 资源包 / 待解包目录 App 写不进（#569：玩家机上这一串归 root、0755，App 是 501）：一个包都不解，先把真实原因说清楚，
    //   不再去解包、报一句含糊的「解 xxx.tar」。迁到 App 自己的新目录在 s2a_games_repair（游戏库挂上时做）
    { const char *dirs[] = {docs, root, inc}; struct stat ds;
      for (int i = 0; i < 3 && !rc; i++) if (!stat(dirs[i], &ds) && S_ISDIR(ds.st_mode) && access(dirs[i], W_OK)) {
          rc = -12; snprintf(what, sizeof what, "目录 App 写不进：%s（属主 uid %u、权限 %o，App 是 uid %u），重开 S2Arm 会自动迁到新目录", dirs[i], (unsigned)ds.st_uid, (unsigned)(ds.st_mode & 07777), (unsigned)getuid()); } }
    // 待解包只由推送端（tools/push_pack.py）写进 .incoming：不再跳过访达拷来的 `._` 附属文件、不设个数上限（iOS 装机剃刀 #20，随 #28）
    DIR *d = rc ? NULL : opendir(inc); char **names = NULL; int nn = 0, cap = 0;
    if (d) { struct dirent *e; while ((e = readdir(d))) { size_t l = strlen(e->d_name); if (l > 4 && !strcmp(e->d_name + l - 4, ".tar")) {
        if (nn == cap) { char **grown = realloc(names, (size_t)(cap = cap ? cap * 2 : 64) * sizeof *names); if (!grown) break; names = grown; }
        names[nn++] = strdup(e->d_name); } } closedir(d); }
    if (nn) qsort(names, (size_t)nn, sizeof *names, name_cmp);
    if (s2a_pack_apply_progress) s2a_pack_apply_progress(0, nn);
    if (nn) PHASE(1, 0, (uint64_t)nn);
    for (int i = 0; i < nn && !rc; i++) {
        char t[2400]; snprintf(t, sizeof t, "%s/%s", inc, names[i]);
        unsigned f0 = nf; uint64_t b0 = nb, t1 = now_ns();
        rc = s2a_untar(t, root, &nf, &nb);
        // 截短的推送包（推送中途被杀留下的）永远解不开：删掉它、它后面所有待解包和推送记录 .pushed，下次部署执行器只按 index.applied.tsv 补推（10-20 测试设备2 巫师3 同一个残包连红 4 局）。
        //   只删残包不够（10-21 测试出包线）：执行器见 .incoming 里还有包就把 .pushed 记的文件当「已推」，残包里的文件不补推；后面的包解完照写 index.applied.tsv = 全部目标，
        //   机上缺文件 / 留半截文件却记成已应用。待解包全删 = 机上状态退回 index.applied.tsv 那一刻，执行器补推的就是缺的全部
        if (rc) { int del = 0;
            if (g_untar_trunc && !unlink(t)) { del = 1; for (int j = i + 1; j < nn; j++) { char u[2400]; snprintf(u, sizeof u, "%s/%s", inc, names[j]); del += !unlink(u); }
                char pp[2100]; snprintf(pp, sizeof pp, "%s/.pushed", root); unlink(pp); }
            snprintf(what, sizeof what, "解 %s%s", names[i], del ? "（截短包：已删它与其后待解包、推送记录，下次部署按已应用索引补推）" : ""); }
        else { unlink(t); ntar++; if (s2a_pack_apply_progress) s2a_pack_apply_progress(i + 1, nn); PHASE(1, (uint64_t)(i + 1), (uint64_t)nn); log_line(logp, "进度：解开 %s（%u/%d）%u 个文件 %llu MB（%.1f 秒）", names[i], i + 1, nn, nf - f0, (unsigned long long)((nb - b0) >> 20), (now_ns() - t1) / 1e9); }
    }
    if (!rc) { int r = img_extract(root, &nf, &nb); if (r) { rc = r; from_img = 1; snprintf(what, sizeof what, "从 game.img 解小文件（%s）", r == -11 ? "格式号不认识，请更新 S2Arm" : r == -10 ? "IMG 坏或没传完" : "写失败"); } }
    unsigned partial = 0; char pex[2200] = "";
    if (!rc) { char ex[2200]; unsigned core = 0, miss = index_check_core(root, ex, sizeof ex, 1, &core);
        if (miss && !core) { partial = miss; snprintf(pex, sizeof pex, "%s", ex); }   // v0.3.1 缺件照玩：只缺非核心文件 → 记部分可玩（.partial），不记已应用，执行器下次照样补推
        else if (miss) { rc = -8; snprintf(what, sizeof what, "核对：index.tsv 里 %u 个文件机上缺或大小不符（例：%s），不记已应用，执行器下次按旧的已应用索引补推", miss, ex); } }   // 核对在清旧文件之前：核不过不删任何文件
    if (!rc) { unsigned nd = 0; uint64_t db = 0; int r2 = prune(root, &nd, &db);   // 清旧文件：资源包下不在 index.tsv 里的（旧版分卷等）
        if (r2) { rc = r2; snprintf(what, sizeof what, "清旧文件（读 index.tsv）"); }
        else if (nd) log_line(logp, "进度：清掉不在 index.tsv 里的旧文件 %u 个 %llu MB", nd, (unsigned long long)(db >> 20)); }
    for (int i = 0; i < nn; i++) free(names[i]);
    free(names);
    char sha[200] = "";
    if (!rc) { char mp[2100]; snprintf(mp, sizeof mp, "%s/manifest.json", root);
        if (manifest_sha(mp, sha, sizeof sha)) { rc = -6; snprintf(what, sizeof what, "读 manifest.json 的 index_sha256"); }
        else if (partial) {   // 部分可玩：不存 index.applied.tsv（它说「机上都有」，执行器会以为齐了、不再补推缺的）、不写 .applied；写 .partial = 清单 sha、缺几个、例子
            char pv[2600]; snprintf(pv, sizeof pv, "%s\n%u\n%s\n", sha, partial, pex);
            if (write_atomic(root, ".partial", pv)) { rc = -4; g_fail_errno = errno; snprintf(what, sizeof what, "写 .partial"); }
            else { char tp[2100]; snprintf(tp, sizeof tp, "%s/.transfer", root); unlink(tp); } }
        else if (copy_atomic(root, "index.tsv", "index.applied.tsv")) { rc = -4; g_fail_errno = errno; snprintf(what, sizeof what, "存 index.applied.tsv"); }   // 「机上实际有什么」：执行器据它算补推
        else if (write_atomic(root, ".applied", sha)) { rc = -4; g_fail_errno = errno; snprintf(what, sizeof what, "写 .applied"); }
        else { char tp[2100], pp[2100]; snprintf(tp, sizeof tp, "%s/.transfer", root); unlink(tp); snprintf(pp, sizeof pp, "%s/.partial", root); unlink(pp); } }   // 解开了：这次推送的传输清单（tools/push_pack.py 写）用完，游戏库不再按它画进度；齐了就撤掉部分可玩标记
    time_t now = time(NULL); char ts[32]; strftime(ts, sizeof ts, "%m-%d %H:%M:%S", localtime(&now));
    FILE *lf = fopen(logp, "a"); int lerr = lf ? 0 : errno;
    // 失败原因不依赖 unpack.log 打得开（#540：游戏目录 Documents/games/<游戏号>/ 不在时 unpack.log 也建不了，原先原因只在 lf 打开时才填，
    //   host.log 那一行「解开 … 没成：」后面是空的、又指去一个不存在的 unpack.log）：先填原因，日志打不开再把这一句接上
    g_apply_fail[0] = 0; snprintf(g_apply_code, sizeof g_apply_code, "%s", s2a_install_code(rc, g_fail_errno, g_untar_trunc, from_img));
    if (rc) { int k = snprintf(g_apply_fail, sizeof g_apply_fail, "%s（返回 %d）", what, rc);
        if (!lf && k > 0 && (size_t)k < sizeof g_apply_fail) snprintf(g_apply_fail + k, sizeof g_apply_fail - (size_t)k, "；unpack.log 建不了：%s %s", logp, strerror(lerr)); }
    if (lf) {
        if (rc) fprintf(lf, "%s 解包失败：%s 返回 %d（已解 %u 个包 %u 个文件）%s%s\n", ts, what, rc, ntar, nf, g_untar_err[0] ? "；现场：" : "", g_untar_err);
        else if (partial) fprintf(lf, "%s 解开 %u 个包 %u 个文件 %llu MB，缺 %u 个非必需文件（例：%s），部分可玩 = %s（%.1f 秒）\n", ts, ntar, nf, (unsigned long long)(nb >> 20), partial, pex, sha, (now_ns() - t0) / 1e9);
        else fprintf(lf, "%s 解开 %u 个包 %u 个文件 %llu MB，.applied = %s（%.1f 秒）\n", ts, ntar, nf, (unsigned long long)(nb >> 20), sha, (now_ns() - t0) / 1e9);
        fclose(lf);
    }
    if (rc) LOG("资源包收推送：失败（%s）：%s", g_apply_code, g_apply_fail); else LOG("资源包收推送：完成");
    return rc ? 1 : 0;
}

// ---- 玩家首次打开时从「文件」导入资源（用户体验线 10-23，原生层线审：后台线程解包、解完提示重新打开、不同进程内接着进游戏）----
// 状态：先改名（Documents/资源包 不在、且恰好一个名字以「资源包」结尾的目录 → 改名成「资源包」，同卷原子；多个不猜）→ 有 .incoming/*.tar = 待导入 → 有 manifest.json = 就绪 → 否则没有资源
enum { S2A_IMPORT_READY = 0, S2A_IMPORT_PENDING = 1, S2A_IMPORT_NONE = 2, S2A_IMPORT_BROKEN = 3, S2A_IMPORT_PARTIAL = 4 };   // 4：只缺非核心文件，玩家确认后照玩（v0.3.1）
// 闸门下一步（s2a_import_decide）与它的节拍：稳住 3 秒才导入、1 分钟内变过算正在拷、推送没完且 3 分钟没动算停住
enum { S2A_GATE_READY, S2A_GATE_IMPORT, S2A_GATE_WAIT, S2A_GATE_STALLED, S2A_GATE_NONE, S2A_GATE_BROKEN };
enum { S2A_GATE_STALL_S = 90 };   // 停住：同游戏库 transferStall（S2ArmShellHostModel.swift，iOS 装机剃刀 #32：原先闸门 180 秒、库 90 秒两套）
struct s2a_gate_watch { int n; uint64_t fp; time_t changed; };
// 资源包完整性（10-26 测试设备2：装机拷到一半被 App 改名，留下有 manifest.json、缺 ctl/control.nacp 的「资源包」，原先只凭 manifest 判就绪，
//   游戏起来读不到数据 Break、App 退出像闪退）：按 index.tsv（路径<TAB>字节<TAB>sha256）逐个核在不在、大小对不对，返回不符个数，first 记第一个。
//   index.tsv 由 pack/pack.py 与 manifest.json 同写、出包保证在：不在 / 打不开 / 读不了都按不完整（审计 P2-7：原先打不开当「老包不核」判就绪），first 记 index.tsv 与原因
static int g_pack_bad; static char g_pack_first[512];
// 说明页正文（app.m s2a_ios_show_pack_help）。again = 玩家刚按过「重新检查」、还是不行：开头先说一句，不然整页原样重画，玩家以为按钮没生效（审计 P2-2）
void s2a_pack_help_detail(int st, int again, char *d, size_t n) {
    const char *pre = again ? S2A_UI(S2A_UI_PACK_AGAIN) : "";
    // 缺哪个文件（g_pack_first）只进日志（s2a_import_state 已打），不上屏（11-02 维护者：index.tsv 这类内部词玩家看不懂）
    snprintf(d, n, "%s%s", pre, st == S2A_IMPORT_PARTIAL ? S2A_UI(S2A_UI_PACK_PARTIAL_DETAIL) : st == S2A_IMPORT_BROKEN ? S2A_UI(S2A_UI_PACK_BROKEN_DETAIL) : S2A_UI(S2A_UI_PACK_NONE_DETAIL));
}
int s2a_pack_check(const char *root, char *first, size_t n) { return (int)index_check(root, first, first ? n : 0, 0); }
static int ends_with(const char *s, const char *t) { size_t a = strlen(s), b = strlen(t); return a >= b && !strcmp(s + a - b, t); }
static int applied_ready(const char *root);
static int partial_ready(const char *root);
int s2a_import_state(const char *docs) {
    char root[2048]; struct stat st; s2a_pack_root(root, sizeof root, docs);
    int have = !stat(root, &st) && S_ISDIR(st.st_mode);
    // 「资源包」不在 = 没有资源。原先还会把 Documents 下唯一一个「<游戏名>资源包」改名成「资源包」、把空的「资源包」挪开（玩家用访达拷整个文件夹那条路，
    //   10-26）：v0.3.0 起单一 IMG 交付、单款壳不出，说明页只教「装到 iPhone」与「文件」里放 game.img，这条路连同查询里的改名副作用一起删（iOS 装机剃刀 #28）
    if (!have) return S2A_IMPORT_NONE;
    // 先用游戏库那条快判（applied_ready）：解开时核对过每个文件、写下的 .applied 等于当前清单、程序描述在 = 就绪，不再逐文件核。
    //   原先闸门先看 .incoming、库先看 .applied，顺序相反：机上留一个包且清单没变时库说能玩、闸门判待导入 + 在传，等到「停住了」进不去；
    //   每次起局还要对同一目录逐文件核一遍（Play 时主线程 s2a_import_needs_ui 再核一遍）。逐文件核只留在没有 .applied 的路径与游戏 Break 时（iOS 装机剃刀 #27 / #38 / #39）
    if (applied_ready(root)) return S2A_IMPORT_READY;
    if (partial_ready(root)) return S2A_IMPORT_PARTIAL;
    char inc[2100]; snprintf(inc, sizeof inc, "%s/.incoming", root); int ntar = 0;
    DIR *d = opendir(inc); if (d) { struct dirent *e; while ((e = readdir(d))) if (ends_with(e->d_name, ".tar")) ntar++; closedir(d); }
    if (ntar) return S2A_IMPORT_PENDING;
    char mf[2100]; snprintf(mf, sizeof mf, "%s/manifest.json", root);
    if (stat(mf, &st)) return S2A_IMPORT_NONE;
    unsigned core = 0; g_pack_bad = (int)index_check_core(root, g_pack_first, sizeof g_pack_first, 0, &core);
    if (g_pack_bad && !core) { LOG("资源导入：缺 %d 个非必需文件（如 %s），部分可玩：玩家确认后照玩", g_pack_bad, g_pack_first); return S2A_IMPORT_PARTIAL; }
    if (g_pack_bad) { LOG("资源导入：资源包不完整，缺 / 不对 %d 个文件（如 %s，其中核心 %u 个）", g_pack_bad, g_pack_first, core); return S2A_IMPORT_BROKEN; }
    if (img_needs_apply(root)) return S2A_IMPORT_PENDING;   // game.img 到了、小文件还没解：先解开再就绪
    return S2A_IMPORT_READY;
}
// ---- 游戏目录 App 写不进时迁到新目录（#569）：玩家机上 Documents/games、games/<游戏号>、资源包、.incoming 归 root（0755），App（501）
//   一个解包文件都建不了、起 App 后解包始终不开始，界面也不说为什么（来源未明：启动器线没复现出推送建 root 目录）。App 删不掉也改不了
//   这些目录，但 Documents 是自己的：新建一棵树，目录照建、文件 APFS 克隆（CLONE_NOOWNERCOPY：新文件归 App、共享数据块不占空间），
//   全部成功后旧 games 改名成 Documents/.s2a-unwritable-<时刻>、新树改名成 games（第二步失败就改回去）；任何一步失败只删新树、不动原样。
//   之后路径不变，判据、推送、起局都不用改。旧目录 App 删不掉（归 root），由电脑端下次连上时删（Documents/.s2a-unwritable-*）
// 迁移结果给宿主拼成界面语言的一句话（ios/app.m）：旧目录属主、克隆的文件数、失败时哪一步怎么失败（路径 + 系统错误）
static char g_repair_why[1600], g_repair_skip1[1200]; static unsigned g_repair_uid, g_repair_files, g_repair_skipped;
const char *s2a_games_repair_detail(void) { return g_repair_why; }
unsigned s2a_games_repair_owner(void) { return g_repair_uid; }
unsigned s2a_games_repair_files(void) { return g_repair_files; }
// 第一个写不进的目录（games 往下三层：games、每款目录、资源包、.incoming）；都写得进返回 0
static int games_unwritable(const char *games, char *bad, size_t n, struct stat *bs) {
    struct stat st; if (stat(games, &st) || !S_ISDIR(st.st_mode)) return 0;
    if (access(games, W_OK)) { snprintf(bad, n, "%s", games); *bs = st; return 1; }
    DIR *d = opendir(games); if (!d) return 0; struct dirent *e; int hit = 0;
    while (!hit && (e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        const char *sub[] = {"", "/资源包", "/资源包/.incoming"};
        for (int i = 0; i < 3 && !hit; i++) {
            char p[2400]; snprintf(p, sizeof p, "%s/%s%s", games, e->d_name, sub[i]);
            if (!stat(p, &st) && S_ISDIR(st.st_mode) && access(p, W_OK)) { snprintf(bad, n, "%s", p); *bs = st; hit = 1; }
        }
    }
    closedir(d); return hit;
}
#if defined(__APPLE__)
#include <sys/clonefile.h>
#endif
// 读不到的那一项跳过、计数（反防御：读得到的都搬过去照常装；缺的文件由资源包核对报出来，从电脑重装补齐）
static void clone_skip(const char *what, const char *path, int err) {
    if (!g_repair_skipped++) snprintf(g_repair_skip1, sizeof g_repair_skip1, "%s %s：%s", what, path, err ? strerror(err) : "不是普通文件 / 目录 / 链接");
    LOG("【黄】游戏目录迁移：%s %s 读不到（%s），跳过", what, path, err ? strerror(err) : "不是普通文件 / 目录 / 链接");
}
// 克隆不了（跨卷、文件系统不支持、属主限制）就逐字节拷：新文件归 App。源读不开回 1（调用方跳过）；写新文件失败回 -1（真写不进：停）
static int copy_file(const char *from, const char *to, mode_t mode, char *why, size_t n) {
    int in = open(from, O_RDONLY); if (in < 0) return 1;
    int out = open(to, O_WRONLY | O_CREAT | O_EXCL, (mode & 0777) | 0600);
    if (out < 0) { snprintf(why, n, "建 %s：%s", to, strerror(errno)); close(in); return -1; }
    static char buf[1 << 20]; ssize_t k; int rc = 0;
    while ((k = read(in, buf, sizeof buf)) > 0) if (write(out, buf, (size_t)k) != k) { snprintf(why, n, "写 %s：%s", to, strerror(errno)); rc = -1; break; }
    if (!rc && k < 0) { rc = 1; unlink(to); }   // 读到一半读不下去：当读不到，跳过
    close(in); if (close(out) && !rc) { snprintf(why, n, "写 %s：%s", to, strerror(errno)); rc = -1; }
    if (rc < 0) unlink(to);
    return rc;
}
// 把 from 整棵搬到 to（to 不存在）：目录照建、普通文件克隆（不行就拷）、符号链接照抄；读不到的项跳过计数。新位置建不了 / 写不进返回负数并在 why 写哪一个
static int clone_tree(const char *from, const char *to, unsigned *files, uint64_t *bytes, char *why, size_t n) {
    struct stat st; if (lstat(from, &st)) { clone_skip("读", from, errno); return 0; }
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(from); if (!d) { clone_skip("列目录", from, errno); return 0; }
        if (mkdir(to, 0755)) { snprintf(why, n, "建 %s：%s", to, strerror(errno)); closedir(d); return -1; }
        struct dirent *e; int rc = 0;
        while (!rc && (e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char a[2400], b[2400]; snprintf(a, sizeof a, "%s/%s", from, e->d_name); snprintf(b, sizeof b, "%s/%s", to, e->d_name);
            rc = clone_tree(a, b, files, bytes, why, n);
        }
        closedir(d); return rc;
    }
    if (S_ISLNK(st.st_mode)) {
        char t[2400]; ssize_t k = readlink(from, t, sizeof t - 1); if (k < 0) { clone_skip("读链接", from, errno); return 0; }
        t[k] = 0; if (symlink(t, to)) { snprintf(why, n, "建链接 %s：%s", to, strerror(errno)); return -1; }
        return 0;
    }
    if (!S_ISREG(st.st_mode)) { clone_skip("搬", from, 0); return 0; }
#if defined(__APPLE__)
    if (clonefile(from, to, CLONE_NOOWNERCOPY))
#endif
    { int c = copy_file(from, to, st.st_mode, why, n); if (c < 0) return -1; if (c > 0) { clone_skip("读", from, errno); return 0; } }
    (*files)++; *bytes += (uint64_t)st.st_size; return 0;
}
static void remove_tree(const char *p) {   // 只删自己刚建的新树（归 App，删得掉）
    struct stat st; if (lstat(p, &st)) return;
    if (S_ISDIR(st.st_mode)) { DIR *d = opendir(p); if (d) { struct dirent *e; while ((e = readdir(d))) { if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char c[2400]; snprintf(c, sizeof c, "%s/%s", p, e->d_name); remove_tree(c); } closedir(d); } rmdir(p); }
    else unlink(p);
}
// 修一棵树：parent/games 往下写不进 → 克隆成新树换上。0 = 都写得进（没动）；1 = 迁好了；负数 = 迁移失败（原样留着）
static int repair_tree(const char *proc_docs) {
    char games[2048], bad[2400] = ""; struct stat bs; snprintf(games, sizeof games, "%s/games", proc_docs);
    if (!games_unwritable(games, bad, sizeof bad, &bs)) return 0;
    LOG("【红】游戏目录：%s App 写不进（属主 uid %u、权限 %o，App 是 uid %u），迁到新目录", bad, (unsigned)bs.st_uid, (unsigned)(bs.st_mode & 07777), (unsigned)getuid());
    time_t now = time(NULL); char ts[32]; strftime(ts, sizeof ts, "%Y%m%d-%H%M%S", gmtime(&now));
    char fresh[2100], keep[2100], why[1600] = ""; snprintf(fresh, sizeof fresh, "%s/.s2a-games-new-%s", proc_docs, ts); snprintf(keep, sizeof keep, "%s/.s2a-unwritable-%s", proc_docs, ts);
    { struct stat x; for (int k = 2; (!lstat(fresh, &x) || !lstat(keep, &x)) && k < 1000; k++) {   // 同一秒里第二次迁（上一回的旧目录还在）：名字加序号，不撞
        snprintf(fresh, sizeof fresh, "%s/.s2a-games-new-%s-%d", proc_docs, ts, k); snprintf(keep, sizeof keep, "%s/.s2a-unwritable-%s-%d", proc_docs, ts, k); } }
    unsigned files = 0; uint64_t bytes = 0; uint64_t t0 = now_ns(); g_repair_skipped = 0; g_repair_skip1[0] = 0;
    int rc = clone_tree(games, fresh, &files, &bytes, why, sizeof why);
    if (!rc && rename(games, keep)) { snprintf(why, sizeof why, "把旧目录改名成 %s：%s", keep, strerror(errno)); rc = -2; }
    if (!rc && rename(fresh, games)) {
        int e = errno; int back = rename(keep, games);
        snprintf(why, sizeof why, "把新目录改名成 games：%s%s", strerror(e), back ? "；旧目录也没能改回原名（在 .s2a-unwritable-* 里，数据都在）" : "；旧目录已改回原名");
        rc = -3;
    }
    g_repair_uid = (unsigned)bs.st_uid; g_repair_files = files;
    if (rc) {
        if (rc != -3) remove_tree(fresh);
        snprintf(g_repair_why, sizeof g_repair_why, "%s（写不进的是 %s）", why, bad);
        LOG("【红】游戏目录：迁移没成：%s", g_repair_why); return rc;
    }
    LOG("游戏目录：迁好了：%u 个文件 %llu MB 克隆进新目录（%.1f 秒），旧的改名为 %s%s%s", files, (unsigned long long)(bytes >> 20), (now_ns() - t0) / 1e9, keep,
        g_repair_skipped ? "；读不到跳过的第一项：" : "", g_repair_skipped ? g_repair_skip1 : "");
    if (g_repair_skipped) LOG("【黄】游戏目录：%u 项读不到没搬（缺的文件资源包核对会报出来，从电脑重新装这款补齐）", g_repair_skipped);
    return 1;
}
// 资源包那棵（Library 下）：主位置 Library/Application Support/S2Arm 这条链 App 建不出 / 写不进（iOS 27 玩家机上 Application Support/S2Arm 归 root，
//   连迁移用的新树都建不了）→ 建备用位置 Library/S2Arm（Library 归 App），games 下读得到的照搬过去，旧的原样留着；之后宿主与电脑端都认备用位置（s2a_docs.h）。
//   已经在备用位置 / 主位置写得进：同 Documents 那棵，只修 games 往下写不进的目录
static int mkdir_chain(const char *dir) {   // 逐级建（已有算成）；最后一级写得进回 0，否则回 errno
    char p[2048]; snprintf(p, sizeof p, "%s", dir);
    for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
    if (mkdir(p, 0755) && errno != EEXIST) return errno;
    return access(p, W_OK) ? errno : 0;
}
static int repair_pack_base(const char *proc_docs) {
    char main_[2048], alt[2048], altg[2100], games[2100]; struct stat st;
    if (s2a_pack_base_main(main_, sizeof main_, proc_docs) < 0 || s2a_pack_base_alt(alt, sizeof alt, proc_docs) < 0) return 0;
    snprintf(altg, sizeof altg, "%s/games", alt);
    if (!stat(altg, &st) && S_ISDIR(st.st_mode)) return repair_tree(alt);
    int e = mkdir_chain(main_);
    if (!e) return repair_tree(main_);
    snprintf(games, sizeof games, "%s/games", main_);
    struct stat ms; unsigned uid = stat(main_, &ms) ? 0 : (unsigned)ms.st_uid;
    LOG("【红】游戏目录：%s App 写不进（%s，属主 uid %u，App 是 uid %u），资源包改放 %s，读得到的搬过去", main_, strerror(e), uid, (unsigned)getuid(), alt);
    g_repair_uid = uid; g_repair_skipped = 0; g_repair_skip1[0] = 0;
    int ea = mkdir_chain(alt);
    if (ea) { snprintf(g_repair_why, sizeof g_repair_why, "建 %s：%s（%s 也写不进：%s）", alt, strerror(ea), main_, strerror(e)); LOG("【红】游戏目录：迁移没成：%s", g_repair_why); return -1; }
    time_t now = time(NULL); char ts[32]; strftime(ts, sizeof ts, "%Y%m%d-%H%M%S", gmtime(&now));
    char fresh[2200], why[1600] = ""; snprintf(fresh, sizeof fresh, "%s/.s2a-games-new-%s", alt, ts);
    unsigned files = 0; uint64_t bytes = 0; uint64_t t0 = now_ns(); int rc = 0;
    if (!stat(games, &st) && S_ISDIR(st.st_mode)) rc = clone_tree(games, fresh, &files, &bytes, why, sizeof why);
    else if (mkdir(fresh, 0755)) { snprintf(why, sizeof why, "建 %s：%s", fresh, strerror(errno)); rc = -1; }
    if (!rc && rename(fresh, altg)) { snprintf(why, sizeof why, "把新目录改名成 %s：%s", altg, strerror(errno)); rc = -3; }
    g_repair_files = files;
    if (rc) { remove_tree(fresh); snprintf(g_repair_why, sizeof g_repair_why, "%s（写不进的是 %s）", why, main_); LOG("【红】游戏目录：迁移没成：%s", g_repair_why); return rc; }
    LOG("游戏目录：资源包改放 %s：%u 个文件 %llu MB 搬过去（%.1f 秒），旧的 %s 留着不动%s%s", altg, files, (unsigned long long)(bytes >> 20), (now_ns() - t0) / 1e9, main_,
        g_repair_skipped ? "；读不到跳过的第一项：" : "", g_repair_skipped ? g_repair_skip1 : "");
    return files ? 1 : 0;
}
// 0 = 都写得进（没动）；1 = 迁好了；负数 = 迁移失败（原样留着）。结果细节经上面三个函数取。
//   两棵树都修：进程级 Documents/games（存档、旧位置的资源包）与新位置 Library/Application Support/S2Arm/games（v0.3.0 起的资源包，电脑端推包也写这里）
int s2a_games_repair(const char *proc_docs) {
    g_repair_why[0] = 0; g_repair_uid = 0; g_repair_files = 0;
    int a = repair_tree(proc_docs);
    char why_a[sizeof g_repair_why]; unsigned uid_a = g_repair_uid, files_a = g_repair_files; snprintf(why_a, sizeof why_a, "%s", g_repair_why);
    int b = repair_pack_base(proc_docs);
    if (a < 0) { snprintf(g_repair_why, sizeof g_repair_why, "%s", why_a); g_repair_uid = uid_a; g_repair_files = files_a; return a; }   // 先报 Documents 那棵的失败
    if (b) return b;
    if (a) { snprintf(g_repair_why, sizeof g_repair_why, "%s", why_a); g_repair_uid = uid_a; g_repair_files = files_a; }
    return a;
}

// ---- 资源包挪出 Documents（v0.3.0，11-11 真机复现：Documents 里几万个资源包文件拖住「文件」App 与系统选择器的「最近项目」，一直「正在加载」）：
//   每款 Documents/games/<游戏号>/资源包 → Library/Application Support/S2Arm/games/<游戏号>/资源包（s2a_docs.h s2a_pack_root）。
//   同一个容器同一个卷：rename(2) 一次挪整个目录，不拷贝不重写，几毫秒；rename 是原子的，迁到一半被杀 = 这一款要么还在旧位置要么已在新位置，下次再判接着迁。
//   存档（S2A/ryujinx）、金手指、unpack.log 都在本款文档根别处，不在挪动范围里。
//   新位置已有（电脑端先推了新位置、或上次迁过）：旧位置是一次新推送（老版本电脑端推的：有待解包 / 清单不同）→ 换掉新位置；
//   否则新位置已就绪（.applied 对得上清单）→ 旧位置是重复的，删掉；新位置没就绪 → 两处都不动、下次再判（不丢任何一份）。
//   docs = 本款文档根 Documents/games/<游戏号>。返回 1 = 挪了 / 删了旧的；0 = 没有旧位置或不是多款容器的文档根；-1 = 新位置没就绪、两处都留着；-2 = 挪失败（原样留着）
static int applied_ready(const char *root);
static char g_migrate_why[600];
const char *s2a_pack_migrate_failure(void) { return g_migrate_why; }
int s2a_pack_migrate_one(const char *docs) {
    char old[2200], neu[2200]; struct stat st;
    s2a_pack_legacy_root(old, sizeof old, docs);
    if (s2a_pack_root(neu, sizeof neu, docs) >= (int)sizeof neu || !strcmp(old, neu)) return 0;   // 单款兼容 / Mac：资源包本来就在文档根下
    if (lstat(old, &st) || !S_ISDIR(st.st_mode)) return 0;
    if (!lstat(neu, &st)) {
        // 两处都有：旧位置若是一次「新推送」（老版本电脑端推到了旧位置：.incoming 里有包，或清单不是新位置已应用的那份）→ 它新，换掉新位置；
        //   否则旧位置是重复 / 删到一半的残留：新位置已就绪 → 删旧的；新位置没就绪 → 两处都不动、下次再判（不丢任何一份）
        char inc[2300], omf[2300], nap[2300], osha[200] = "", nsha[200] = ""; snprintf(inc, sizeof inc, "%s/.incoming", old);
        snprintf(omf, sizeof omf, "%s/manifest.json", old); snprintf(nap, sizeof nap, "%s/.applied", neu);
        int pending = 0; DIR *d = opendir(inc); if (d) { struct dirent *e; while (!pending && (e = readdir(d))) pending = ends_with(e->d_name, ".tar"); closedir(d); }
        FILE *f = fopen(nap, "r"); if (f) { size_t k = fread(nsha, 1, sizeof nsha - 1, f); fclose(f); nsha[k] = 0; nsha[strcspn(nsha, "\r\n")] = 0; }
        int differs = !manifest_sha(omf, osha, sizeof osha) && strcmp(osha, nsha);
        if (pending || differs) {
            // 三步改名（同 repair_tree；审计 P1-169：原先先删新位置再改名，改名失败或删到一半被杀，已经能玩的新位置就缺了文件）：
            //   ① 新位置改名挪开留作退路 ② 旧位置改名进来 ③ 成功后才删挪开的那份；② 失败就把 ① 改回原名，两处都不丢
            char keep[2300]; snprintf(keep, sizeof keep, "%s.s2a-old-%llu", neu, (unsigned long long)now_ns());
            if (rename(neu, keep)) { snprintf(g_migrate_why, sizeof g_migrate_why, "把新位置 %s 挪开（换成旧位置的新推送前）：%s", neu, strerror(errno)); LOG("【红】资源包迁移：%s", g_migrate_why); return -2; }
            if (rename(old, neu)) {
                int e = errno, back = rename(keep, neu);
                snprintf(g_migrate_why, sizeof g_migrate_why, "把旧位置的新推送 %s 换到 %s：%s%s", old, neu, strerror(e),
                         back ? "；新位置原来那份也没能改回原名（在 .s2a-old-* 里，文件都在）" : "；新位置原来那份已改回原名");
                LOG("【红】资源包迁移：%s", g_migrate_why); return -2;
            }
            remove_tree(keep);
            LOG("资源包迁移：旧位置是一次新推送（%s），换掉新位置的旧资源包", pending ? "有待解包" : "清单不同");
            return 1;
        }
        if (!applied_ready(neu)) { LOG("资源包迁移：%s 新旧两处都有、新位置还没就绪，都不动，下次再判", docs); return -1; }
        remove_tree(old);
        LOG("资源包迁移：新位置已就绪，删掉旧位置的重复资源包 %s", old);
        return 1;
    }
    char parent[2200]; snprintf(parent, sizeof parent, "%s", neu);
    if (mkdirs(parent)) { snprintf(g_migrate_why, sizeof g_migrate_why, "建 %s 的上级目录失败：%s", neu, g_untar_err); LOG("【红】资源包迁移：%s", g_migrate_why); return -2; }   // 只建到上一级：rename 要目标本身不存在
    uint64_t t0 = now_ns();
    if (rename(old, neu)) { snprintf(g_migrate_why, sizeof g_migrate_why, "把 %s 改名到 %s：%s", old, neu, strerror(errno)); LOG("【红】资源包迁移：%s", g_migrate_why); return -2; }
    LOG("资源包迁移：%s → %s（同盘改名 %.1f ms）", old, neu, (now_ns() - t0) / 1e6);
    return 1;
}
// 进程级 Documents 下每一款都迁：返回挪了几款（失败的计在 *failed）。游戏库挂上时（app.m img_scan_bg）在 #569 修复之后、认领 IMG 之前做
int s2a_pack_migrate(const char *proc_docs, int *failed) {
    char games[2048]; snprintf(games, sizeof games, "%s/games", proc_docs); if (failed) *failed = 0;
    DIR *d = opendir(games); if (!d) return 0;
    int moved = 0; struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char docs[2300]; snprintf(docs, sizeof docs, "%s/%s", games, e->d_name);
        int r = s2a_pack_migrate_one(docs);
        if (r > 0) moved++; else if (r == -2 && failed) (*failed)++;
    }
    closedir(d);
    return moved;
}

// ---- 玩家把 IMG 放进「文件」里 S2Arm 的「放这里导入」文件夹（v0.3.0，自签 / 侧载玩家）：s2a_img_scan 扫这个文件夹（往下两层，跳过隐藏目录），
//   认文件开头的魔数（不看扩展名，改了名也认）。长度不等于头里的整个文件长 = 还在拷，先不动下次再看；认出来就读头里的游戏号，
//   同卷改名挪到本款资源包根 Library/Application Support/S2Arm/games/<游戏号>/资源包/game.img（s2a_pack_root；文件夹不在就建，玩家不用知道程序号），写 index.tsv（game.img 一行 + 原有的直连库 / 覆盖层行）
//   与清单 manifest.json（version 3、资源包号取头）、作废 .applied——之后就是「待导入」，游戏库 / 闸门照常解小文件（s2a_pack_apply）
static char g_img_err[600], g_img_code[48];
const char *s2a_img_scan_failure(void) { return g_img_err; }
// 认领失败给码（同 s2a_install_code）：格式号不认识 = ios_install_img_format，挪 / 写时空间满 = ios_install_no_space，其余 ios_import_img_failed
const char *s2a_img_scan_code(void) { return g_img_code; }
static int img_place(const char *proc_docs, const char *path) {   // 0 = 挪好了；1 = 不是 IMG / 还在拷（不动）；负数 = 失败（原样留着）
    int fd = open(path, O_RDONLY); if (fd < 0) return 1;
    uint8_t h[136]; struct stat st; int ok = pread(fd, h, sizeof h, 0) == (ssize_t)sizeof h && !memcmp(h, "S2AIMG01", 8) && !fstat(fd, &st); close(fd);
    if (!ok) return 1;
    uint64_t total; memcpy(&total, h + 128, 8); if (total != (uint64_t)st.st_size) return 1;   // 还在拷
    uint32_t fmt; memcpy(&fmt, h + 8, 4);
    if (fmt != 1) { snprintf(g_img_err, sizeof g_img_err, "%s 是格式号 %u 的资源包，这个 S2Arm 只认 1：请更新 S2Arm", path, fmt); return -11; }
    char gid[17], pid[65]; memcpy(gid, h + 16, 16); gid[16] = 0; memcpy(pid, h + 32, 64); pid[64] = 0;
    for (int i = 0; i < 16; i++) if (!((gid[i] >= '0' && gid[i] <= '9') || (gid[i] >= 'A' && gid[i] <= 'F'))) { snprintf(g_img_err, sizeof g_img_err, "%s 头里的游戏号不对", path); return -10; }
    if (!pid[0]) snprintf(pid, sizeof pid, "img-%llx", (unsigned long long)total);   // 没写资源包号的（老工具）：按长度给一个，至少换了文件能触发重新应用
    char root[1400], p[2400], old[2400], gdocs[1200]; snprintf(gdocs, sizeof gdocs, "%s/games/%s", proc_docs, gid); s2a_pack_root(root, sizeof root, gdocs);
    snprintf(p, sizeof p, "%s/game.img", root); if (mkdirs(p)) { snprintf(g_img_err, sizeof g_img_err, "建 %s 失败：%s", root, g_untar_err); return -4; }
    snprintf(old, sizeof old, "%s/manifest.json", root); unlink(old); snprintf(old, sizeof old, "%s/.applied", root); unlink(old);   // 先作废：挪到一半断了不会判成就绪
    if (rename(path, p)) { snprintf(g_img_err, sizeof g_img_err, "把 %s 挪进资源包失败：%s", path, strerror(errno)); return -4; }
    // index.tsv：game.img 一行 + 原有 index.tsv 里的直连库 / 覆盖层行（着色器库与覆盖层是 App 管的缓存、不进 IMG；电脑推过的那部分不丢）
    char ip[2400], tp[2500]; snprintf(ip, sizeof ip, "%s/index.tsv", root); snprintf(tp, sizeof tp, "%s.tmp", ip);
    FILE *o = fopen(tp, "w"), *in = fopen(ip, "r"); if (!o) { if (in) fclose(in); snprintf(g_img_err, sizeof g_img_err, "写 index.tsv 失败：%s", strerror(errno)); return -4; }
    fprintf(o, "game.img\t%llu\t-\n", (unsigned long long)total);
    if (in) { char line[4600]; while (fgets(line, sizeof line, in)) if (!strncmp(line, "shaders/", 8) || !strncmp(line, "romfs_overlay/", 14)) fputs(line, o); fclose(in); }
    if (fclose(o) || rename(tp, ip)) { snprintf(g_img_err, sizeof g_img_err, "写 index.tsv 失败：%s", strerror(errno)); return -4; }
    char mf[600]; snprintf(mf, sizeof mf, "{\"version\": 3, \"format\": \"img\", \"imgFile\": \"game.img\", \"index_sha256\": \"%s\"}\n", pid);
    snprintf(p, sizeof p, "%s/manifest.json", root); snprintf(tp, sizeof tp, "%s.tmp", p);
    FILE *m = fopen(tp, "w"); if (!m || fputs(mf, m) < 0 || fclose(m) || rename(tp, p)) { snprintf(g_img_err, sizeof g_img_err, "写 manifest.json 失败：%s", strerror(errno)); return -4; }
    LOG("资源导入：%s → %s/game.img（%llu MB），等游戏库解开", strrchr(path, '/') ? strrchr(path, '/') + 1 : path, root, (unsigned long long)(total >> 20));
    return 0;
}
static int img_scan_dir(const char *proc_docs, const char *dir, int depth, int *placed) {
    DIR *d = opendir(dir); if (!d) return 0;
    char *names[512]; int nn = 0; struct dirent *e;
    while ((e = readdir(d)) && nn < 512) { if (e->d_name[0] == '.') continue; if (depth == 0 && !strcmp(e->d_name, "games")) continue; names[nn++] = strdup(e->d_name); }
    closedir(d);
    for (int i = 0; i < nn; i++) {
        char p[2400]; struct stat st; snprintf(p, sizeof p, "%s/%s", dir, names[i]);
        if (!lstat(p, &st)) {
            if (S_ISDIR(st.st_mode) && depth < 2) img_scan_dir(proc_docs, p, depth + 1, placed);
            else if (S_ISREG(st.st_mode) && st.st_size >= 4096) { int r = img_place(proc_docs, p); if (!r) (*placed)++; else if (r < 0) { int e = errno;
                snprintf(g_img_code, sizeof g_img_code, "%s", r == -11 ? "ios_install_img_format" : r == -4 && (e == ENOSPC || e == EDQUOT) ? "ios_install_no_space" : "ios_import_img_failed");
                LOG("【红】资源导入（%s）：%s", g_img_code, g_img_err); } }
        }
        free(names[i]);
    }
    return 0;
}
// 认领只扫 Documents 下的导入文件夹（v0.3.0 起，原先扫整个 Documents）：名字按界面语言建（app.m），两种都认，切了语言照样认
const char *const s2a_img_import_dirs[2] = {"放这里导入", "Import Here"};
int s2a_img_scan(const char *proc_docs) {   // 回前台 / 「重新检查」可能同时调：一把锁串起来，免得两边抢着挪同一个文件
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu); int placed = 0; g_img_err[0] = 0; g_img_code[0] = 0;
    for (int i = 0; i < 2; i++) { char dir[2200]; snprintf(dir, sizeof dir, "%s/%s", proc_docs, s2a_img_import_dirs[i]); img_scan_dir(proc_docs, dir, 0, &placed); }
    pthread_mutex_unlock(&mu); return placed;
}
// 资源还在传（11-02 维护者 测试设备2 暗黑3：推 21.7 GB 中途点开 App，已到的几批被解开、核对时 index.tsv 还没到，报「返回 -8」要玩家删文件夹重拷）。
//   推送契约（tools/push_pack.py）：开推先把机上 manifest.json 置空，各批 tar 推进 .incoming/，index.tsv 与 manifest.json 最后推。所以下面任一条成立 = 这次推送还没完，不能开始解：
//   ① index.tsv / manifest.json 不在或读不出 index_sha256（首次推送清单还没到 / 这次推送开头置空了）；
//   ② 有 tar 没写完（没有归档尾：不足两块、大小不是 512 的倍数、末尾 1024 字节不全零）——在写的包去解会被当截短包，连同后面的包和 .pushed 一起删。
//   原先另有一条「清单的 index_sha256 就是 .applied = 新清单还没到」（11-02 暗黑3，那时推送不置空清单）：置空契约后它与 ① 重复，留着只剩误判——
//   同一份清单重推、推送端用空包盖掉残批时清单没变，永远判「还在传」解不开（iOS 装机剃刀 #24）
//   返回 1 = 还在传，why 写一句原因（日志用）
static int tar_done(const char *p) {
    struct stat st; if (stat(p, &st) || st.st_size < 1024 || st.st_size % 512) return 0;
    int fd = open(p, O_RDONLY); if (fd < 0) return 0;
    uint8_t b[1024]; int ok = pread(fd, b, sizeof b, st.st_size - (off_t)sizeof b) == (ssize_t)sizeof b; close(fd);
    for (size_t i = 0; ok && i < sizeof b; i++) ok = !b[i];
    return ok;
}
int s2a_import_transferring(const char *root, char *why, size_t n) {
    char p[2100], sha[200]; struct stat st; why[0] = 0;
    snprintf(p, sizeof p, "%s/index.tsv", root); int idx = !stat(p, &st);
    snprintf(p, sizeof p, "%s/manifest.json", root);
    if (!idx || stat(p, &st)) { snprintf(why, n, "%s还没到", idx ? "manifest.json" : "index.tsv"); return 1; }
    if (manifest_sha(p, sha, sizeof sha)) { snprintf(why, n, "manifest.json 还没写完（读不出 index_sha256）"); return 1; }
    snprintf(p, sizeof p, "%s/.incoming", root); DIR *d = opendir(p); int busy = 0;
    if (d) { struct dirent *e; while (!busy && (e = readdir(d))) { if (!ends_with(e->d_name, ".tar")) continue;
        char t[2400]; snprintf(t, sizeof t, "%s/%s", p, e->d_name); if (!tar_done(t)) { busy = 1; snprintf(why, n, "%s 还没写完", e->d_name); } } closedir(d); }
    return busy;
}
// 资源包指纹：待导入时看 .incoming 的包、清单，以及推送端开推写的传输清单 .transfer 和它列的文件（同游戏库按 .transfer 判传断了，
//   S2ArmShellHostModel.swift transferStage；原先闸门只看 .incoming，推送直写 game.img 时镜像在长闸门看不见、到点误报停住，iOS 装机剃刀 #32）；
//   指纹在变 = 推送还在往里写。原先没有 / 不完整时还每 3 秒扫整个资源包目录、1 分钟内变过算「正在用访达拷」，随那条路删了（iOS 装机剃刀 #33）
static uint64_t g_fp_n, g_fp_b;
static int fp_one(const char *p, const struct stat *st, int flag, struct FTW *f) { (void)p; (void)f; if (flag == FTW_F) { g_fp_n++; g_fp_b += (uint64_t)st->st_size; } return 0; }
// .transfer 的 "files": [["相对路径", 字节], …]（tools/push_pack.py json.dumps，非 ASCII 写成 \uXXXX）：逐个把路径解出来交给 fn
static void transfer_files(const char *root, void (*fn)(const char *path)) {
    char tp[2200]; snprintf(tp, sizeof tp, "%s/.transfer", root); FILE *f = fopen(tp, "r"); if (!f) return;
    enum { CAP = 1 << 20 }; char *buf = malloc(CAP); if (!buf) { fclose(f); return; }
    size_t k = fread(buf, 1, CAP - 1, f); fclose(f); buf[k] = 0;
    char *q = strstr(buf, "\"files\""); if (!q) { free(buf); return; }
    while ((q = strstr(q, "[\""))) {
        q += 2; char rel[2048]; size_t o = 0; int ok = 1;
        for (; *q && *q != '"' && ok; q++) {
            unsigned c = (unsigned char)*q;
            if (c == '\\') {
                q++;
                if (*q == 'u') {   // \uXXXX（含代理对）→ UTF-8
                    unsigned cp = (unsigned)strtoul((char[5]){q[1], q[2], q[3], q[4], 0}, NULL, 16); q += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && q[1] == '\\' && q[2] == 'u') { unsigned lo = (unsigned)strtoul((char[5]){q[3], q[4], q[5], q[6], 0}, NULL, 16); cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); q += 6; }
                    char u[4]; int n = cp < 0x80 ? (u[0] = (char)cp, 1) : cp < 0x800 ? (u[0] = (char)(0xC0 | cp >> 6), u[1] = (char)(0x80 | (cp & 63)), 2)
                        : cp < 0x10000 ? (u[0] = (char)(0xE0 | cp >> 12), u[1] = (char)(0x80 | (cp >> 6 & 63)), u[2] = (char)(0x80 | (cp & 63)), 3)
                        : (u[0] = (char)(0xF0 | cp >> 18), u[1] = (char)(0x80 | (cp >> 12 & 63)), u[2] = (char)(0x80 | (cp >> 6 & 63)), u[3] = (char)(0x80 | (cp & 63)), 4);
                    if (o + (size_t)n < sizeof rel) { memcpy(rel + o, u, (size_t)n); o += (size_t)n; } else ok = 0;
                    continue;
                }
                c = (unsigned char)*q;   // \" \\ \/
            }
            if (o + 1 < sizeof rel) rel[o++] = (char)c; else ok = 0;
        }
        rel[o] = 0;
        if (ok && rel[0] && rel[0] != '/' && !strstr(rel, "..")) { char p[4300]; snprintf(p, sizeof p, "%s/%s", root, rel); fn(p); }
    }
    free(buf);
}
static void fp_path(const char *p) { struct stat st; if (!stat(p, &st)) { g_fp_n++; g_fp_b += (uint64_t)st.st_size ^ (uint64_t)st.st_mtime << 20; } }
static uint64_t pack_fp(const char *root) {
    g_fp_n = g_fp_b = 0; char p[2100]; struct stat st;
    const char *top[] = {".incoming", "index.tsv", "manifest.json", ".applied", ".transfer"};
    for (int i = 0; i < 5; i++) { snprintf(p, sizeof p, "%s/%s", root, top[i]); if (i) { if (!stat(p, &st)) fp_one(p, &st, FTW_F, NULL); } else nftw(p, fp_one, 8, FTW_PHYS); }
    transfer_files(root, fp_path);
    return g_fp_n * 0x9E3779B97F4A7C15ULL ^ g_fp_b;
}
// 闸门每隔几秒判一次下一步（iOS 闸门线程按它显示页面）。w 记上次的指纹、它最后变的时刻、是否真变过（首轮不算变）：
//   就绪 → 进游戏；待导入且推送已完 → 导入（推送完没完由契约判，s2a_import_transferring；原先另要指纹稳住 3 秒，白等 3–6 秒，iOS 装机剃刀 #31）；
//   推送没完 → 等（指纹 90 秒没动 → 停住了，请回电脑重装）；没有 / 不完整 → 说明页（原先 1 分钟内变过算「正在用访达拷」再等，随那条路删了）
int s2a_import_decide(const char *docs, struct s2a_gate_watch *w, time_t now, char *why, size_t n) {
    int st = s2a_import_state(docs); why[0] = 0;
    if (st == S2A_IMPORT_READY || st == S2A_IMPORT_PARTIAL) return S2A_GATE_READY;   // 部分可玩：资源可用，玩家确认在 s2a_import_gate 里问
    char root[2048]; s2a_pack_root(root, sizeof root, docs);
    if (st != S2A_IMPORT_PENDING) return st == S2A_IMPORT_BROKEN ? S2A_GATE_BROKEN : S2A_GATE_NONE;
    if (!s2a_import_transferring(root, why, n)) return S2A_GATE_IMPORT;
    uint64_t fp = pack_fp(root);
    if (!w->n++ || fp != w->fp) { w->fp = fp; w->changed = now; }
    return now - w->changed >= S2A_GATE_STALL_S ? S2A_GATE_STALLED : S2A_GATE_WAIT;
}
// 资源包闸门查哪个文档根、查不查（11-07 Duo「游戏没能启动：系统功能没能准备好」定因）：原先只看「S2A_GAME_DATA 没设」才查、且一律查进程级 Documents——
//   多款容器选了游戏后 launchctx.c export_env 总会写 S2A_GAME_DATA → 不查，资源包不在也照起，服务层读 资源包/exefs/main.npdm 抛 DirectoryNotFound、归成 service_init。
//   现在：多款容器 → 查本款文档根（ctx->docs = Documents/games/<游戏号>，资源包在它下面）；单款兼容来源没设 S2A_GAME_DATA → 进程级 Documents（同原先）；
//   其余（单款文件来源 / 开发起局指定了 S2A_GAME_DATA）不查（同原先）。返回 1 = 要查，docs 写进 out；0 = 不查
int s2a_import_docs_pick(const s2a_launch_ctx *c, int game_data_env, const char *proc_docs, char *out, size_t n) {
    if (n) out[0] = 0;
    if (c && c->source == S2A_LCTX_CONTAINER) { snprintf(out, n, "%s", c->docs); return 1; }
    if (game_data_env) return 0;
    snprintf(out, n, "%s", proc_docs ? proc_docs : ""); return 1;
}
// 多款容器的游戏库（app.m s2a_shell_game_install_state / 选游戏前）：本款资源包状态，按同一个判据（s2a_import_state）查 Documents/games/<游戏号>
//   proc_docs = 进程级 Documents（iOS 调用方取 s2a_container_docs），本款文档根 = <proc_docs>/games/<游戏号>（同 launchctx.c s2a_launch_ctx_resolve_game）
int s2a_import_state_game(const char *proc_docs, const char *gid) {
    char docs[1024]; if (!proc_docs || !*proc_docs || !gid || !*gid || strchr(gid, '/') || gid[0] == '.') return S2A_IMPORT_NONE;
    snprintf(docs, sizeof docs, "%s/games/%s", proc_docs, gid);
    return s2a_import_state(docs);
}
// 游戏库快判：解包成功时写的 .applied 等于当前清单 = 这份已核对过每个文件，直接算就绪。
//   库界面在主线程、每次回前台都判，逐文件 stat 一款 10 万文件的游戏要 2.5 秒以上（冷缓存更久，玩家「每次打开都要等」）；
//   完整核对仍在点 Play 后的导入闸门（s2a_import_state）做
static int applied_ready(const char *root) {   // 资源包目录 root：.applied 等于清单的 index_sha256、程序描述在
    char mf[2300], ap[2300], np[2300], want[200], got[200] = ""; struct stat ns;
    snprintf(mf, sizeof mf, "%s/manifest.json", root); snprintf(ap, sizeof ap, "%s/.applied", root); snprintf(np, sizeof np, "%s/exefs/main.npdm", root);
    FILE *f = fopen(ap, "r");
    if (f) { size_t k = fread(got, 1, sizeof got - 1, f); fclose(f); got[k] = 0; got[strcspn(got, "\r\n")] = 0; }
    // 快判也核程序描述 exefs/main.npdm 在、是普通文件（审计 P2-212：只认 .applied 时删掉它库里仍显示可玩，点开始才报缺）；只 stat 一个文件，不逐文件核
    return got[0] && !manifest_sha(mf, want, sizeof want) && !strcmp(got, want) && !stat(np, &ns) && S_ISREG(ns.st_mode) && ns.st_size > 0;
}
// 部分可玩（v0.3.1）：解包时只缺非核心文件写的 .partial 第一行 = 当前清单 sha、程序描述在
static int partial_ready(const char *root) {
    char mf[2300], pp[2300], np[2300], want[200], got[2700] = ""; struct stat ns;
    snprintf(mf, sizeof mf, "%s/manifest.json", root); snprintf(pp, sizeof pp, "%s/.partial", root); snprintf(np, sizeof np, "%s/exefs/main.npdm", root);
    FILE *f = fopen(pp, "r"); if (!f) return 0;
    size_t k = fread(got, 1, sizeof got - 1, f); fclose(f); got[k] = 0; got[strcspn(got, "\r\n")] = 0;
    return got[0] && !manifest_sha(mf, want, sizeof want) && !strcmp(got, want) && !stat(np, &ns) && S_ISREG(ns.st_mode) && ns.st_size > 0;
}
int s2a_import_state_game_quick(const char *proc_docs, const char *gid) {
    if (proc_docs && *proc_docs && gid && *gid && !strchr(gid, '/') && gid[0] != '.') {
        char root[2200], gdocs[1200]; snprintf(gdocs, sizeof gdocs, "%s/games/%s", proc_docs, gid); s2a_pack_root(root, sizeof root, gdocs);
        if (applied_ready(root)) return S2A_IMPORT_READY;
    }
    return s2a_import_state_game(proc_docs, gid);
}
// 游戏库按款的装机阶段（库界面画图块与蒙版用，ios/app.m s2a_shell_game_install_state）。库界面每秒刷新，只做便宜的判断、不逐文件核对：
//   1 就绪——.applied 等于清单、程序描述在（同快判）；
//   2 传完了、只等解开——清单读得出、不在传（11-09 根修 Windows 装完游戏库空：推送开头把清单置空、最后才写，「清单读得出 + 包都写完」= 推送完整）。
//     库在后台跑 s2a_pack_apply 解开（没有待解包时它只核对、写 .applied：只直写了镜像的推送、访达拷进来的也一样），显示「安装中」；核对不过报「安装没完成」；
//   3 传输中——这次推送没完（清单还没写回，或还有包没写完）：有 .transfer 时库按它画进度，没有（老电脑端推的、被删了）时库按资源包里文件的改动判传断了；
//   0 没有（不显示）——只给「资源包」不在或是空的。原先清单读不出 / 在传又没有 .transfer 也给 0，有数据的款从库里静默消失（iOS 装机剃刀 #26 / #45）
int s2a_game_install_state(const char *proc_docs, const char *gid) {
    if (!proc_docs || !*proc_docs || !gid || !*gid || strchr(gid, '/') || gid[0] == '.') return 0;
    char root[2200], mf[2300], want[200], why[256], gdocs[1200];
    snprintf(gdocs, sizeof gdocs, "%s/games/%s", proc_docs, gid); s2a_pack_root(root, sizeof root, gdocs); snprintf(mf, sizeof mf, "%s/manifest.json", root);
    if (applied_ready(root)) return 1;
    if (partial_ready(root)) return 4;   // 部分可玩：库里显示可玩，点开始时闸门问一次（v0.3.1）
    if (manifest_sha(mf, want, sizeof want) || s2a_import_transferring(root, why, sizeof why)) {
        DIR *d = opendir(root); int any = 0;   // 资源包里有没有东西（. 开头的也算：.incoming / .transfer / .applied）
        if (d) { struct dirent *e; while (!any && (e = readdir(d))) any = strcmp(e->d_name, ".") && strcmp(e->d_name, ".."); closedir(d); }
        return any ? 3 : 0;
    }
    return 2;
}
#if defined(__APPLE__) && TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
// 只有 iOS 起局闸门问「仍要启动」用它（安卓没有这一问，放外面会 -Werror=unused-function）。玩家对这份部分可玩的资源包点过「仍要启动」：.partial_ok = 当时的清单 sha（同一份资源包以后不再问；电脑补推齐了 / 换了包就失效）
static int partial_confirmed(const char *root) {
    char mf[2300], ok[2300], want[200], got[200] = "";
    snprintf(mf, sizeof mf, "%s/manifest.json", root); snprintf(ok, sizeof ok, "%s/.partial_ok", root);
    FILE *f = fopen(ok, "r"); if (!f) return 0;
    size_t k = fread(got, 1, sizeof got - 1, f); fclose(f); got[k] = 0; got[strcspn(got, "\r\n")] = 0;
    return got[0] && !manifest_sha(mf, want, sizeof want) && !strcmp(got, want);
}
#include <dispatch/dispatch.h>
#include <stdatomic.h>
void s2a_ios_show_notice(const char *symbol, const char *title, const char *body, int done, int total, int diag);   // app.m：整屏提示页（notice.m 画）
void s2a_ios_keep_awake(int on);   // app.m：导入期间关自动锁屏（原生层线审：锁屏 = 挂起 = 解包停住）
void s2a_front_run(void (*guest_main)(void)); int s2a_front_is_running(void);
// 提示页文案（11-02 维护者：一句人话说清发生了什么 + 玩家下一步；失败原因、文件名、返回码只进 host.log / unpack.log，经「导出诊断包」带走）。
//   「导入完」请重新打开（原生层线 10-23：不同进程内接着进游戏）。字面在 runtime/include/s2a_ui_text.h（中英两份，S2A_UI 按界面语言取）
static void note_wait(void) { s2a_ios_show_notice("arrow.down.circle.fill", S2A_UI(S2A_UI_IMPORT_WAIT_TITLE), S2A_UI(S2A_UI_IMPORT_WAIT_BODY), 0, 0, 0); }
static void note_stalled(void) { s2a_ios_show_notice("pause.circle.fill", S2A_UI(S2A_UI_IMPORT_STALLED_TITLE), S2A_UI(S2A_UI_IMPORT_STALLED_BODY), 0, 0, 0); }
static void note_done(void) { s2a_ios_show_notice("checkmark.circle.fill", S2A_UI(S2A_UI_IMPORT_DONE_TITLE), S2A_UI(S2A_UI_IMPORT_REOPEN_BODY), 0, 0, 0); }
static void note_entering(void) { s2a_ios_show_notice("checkmark.circle.fill", S2A_UI(S2A_UI_IMPORT_DONE_TITLE), S2A_UI(S2A_UI_IMPORT_ENTERING_BODY), 0, 0, 0); }   // 有人等（预热路径）：导入完当场接着起游戏
static void note_ready_reopen(void) { s2a_ios_show_notice("checkmark.circle.fill", S2A_UI(S2A_UI_IMPORT_READY_TITLE), S2A_UI(S2A_UI_IMPORT_REOPEN_BODY), 0, 0, 0); }
static void note_fail(void) { s2a_ios_show_notice("exclamationmark.triangle.fill", S2A_UI(S2A_UI_IMPORT_FAIL_TITLE), S2A_UI(S2A_UI_IMPORT_FAIL_BODY), 0, 0, 1); }
static const char *help_title(int st) { return st == S2A_IMPORT_BROKEN || st == S2A_IMPORT_PARTIAL ? S2A_UI(S2A_SELFCHECK_PKG_TITLE) : S2A_UI(S2A_UI_PACK_MISSING_TITLE); }   // 说明页标题
static char g_imp_docs[1024], g_imp_name[256];
// 缺资源包 / 资源包不全的说明页（app.m s2a_ios_show_pack_help：示意图 + 三步 + 「我已放好，重新检查」）。10-26 维护者：「壳上做好说明别闪退，
//   打开发现缺资源包就告诉用户把启动器导出的资源包导到手机上指定位置」
void s2a_ios_show_pack_help(const char *title, const char *detail, const char *app, void (*recheck)(void));
void s2a_ios_hide_pack_help(void); void s2a_ios_hide_notice(void);
// 闸门线程（11-02 根修「资源没传完就打开 App」）：每 3 秒按 s2a_import_decide 判一次——还在传就说「还没传完、传完自动继续」，传完自己开始导入；
//   不再一看到待导入的包就解（推送中途解 = 清单没到报「返回 -8」/ 在写的包被当截短包删掉）。说明页的「重新检查」= 立刻再判一次
static dispatch_semaphore_t g_poll_sem, g_ready_sem; static _Atomic int g_gate_waiting;
static void gate_recheck(void) { dispatch_semaphore_signal(g_poll_sem); }
static void imp_progress(int done, int total) { s2a_ios_show_notice("shippingbox.fill", S2A_UI(S2A_UI_IMPORT_PROGRESS_TITLE), S2A_UI(S2A_UI_IMPORT_PROGRESS_BODY), done, total, 0); }
static void gate_show(int act, int again) {
    if (act == S2A_GATE_WAIT) { note_wait(); return; }
    if (act == S2A_GATE_STALLED) { note_stalled(); return; }
    int st = act == S2A_GATE_BROKEN ? S2A_IMPORT_BROKEN : S2A_IMPORT_NONE; char d[1024]; s2a_pack_help_detail(st, again, d, sizeof d);
    s2a_ios_show_pack_help(help_title(st), d, g_imp_name, gate_recheck);
}
static void *gate_thread(void *a) { (void)a;
    static const char *const act_name[] = {"就绪", "导入", "等包稳住", "资源还在传", "资源传输停住了", "没有游戏资源", "资源包不完整"};
    struct s2a_gate_watch w = {0}; int last = -1, poked = 0;
    for (;;) {
        char why[600]; int act = s2a_import_decide(g_imp_docs, &w, time(NULL), why, sizeof why);
        if (act == S2A_GATE_READY) {
            // 预热路径：宿主线程在 s2a_import_gate 里等 → 收起页面、接着起游戏；老路径（闸门在主线程、UIKit 接管后不返回）没人等 → 请玩家重新打开。
            //   有没有人等在起线程前就定了（s2a_import_gate），不再在这里等 2 秒看宿主线程到没到（iOS 装机剃刀 #34：时间补丁，没赶上就误走「请重新打开」）
            s2a_ios_keep_awake(0); s2a_ios_hide_pack_help();
            if (atomic_load(&g_gate_waiting)) { s2a_ios_hide_notice(); LOG("资源导入：就绪，收起页面、接着起游戏"); dispatch_semaphore_signal(g_ready_sem); }
            else { LOG("资源导入：就绪，提示玩家重新打开"); note_ready_reopen(); }
            return NULL;
        }
        if (act == S2A_GATE_IMPORT) {
            LOG("资源导入：推送已完、包已稳住，后台解开");
            s2a_ios_keep_awake(1); imp_progress(0, 1); s2a_pack_apply_progress = imp_progress; int rc = s2a_pack_apply(g_imp_docs); s2a_pack_apply_progress = NULL;
            // 导入完回去再判一次：就绪 → 宿主线程在等（预热路径）就当场接着起游戏，没人等（老路径）才请玩家重新打开（11-02 用户体验线：首启导入完还要划掉重开是硬伤；
            //   10-23 定「重新打开」时闸门还在主线程、UIKit 接管后不返回，接不下去；10-26 预热路径能接了，这一支没跟上）。解包是流式的、文件都关了，不留占用
            //   页面也分两路：有人等就说「正在进入游戏」，「划掉重开」只留给没人等的老路径（11-02 用户体验线：成功路径先闪一句叫玩家划掉，紧接着游戏自己进去了）
            if (!rc) { LOG("资源导入：完成，再判一次就绪（有人等就接着起游戏）"); if (atomic_load(&g_gate_waiting)) note_entering(); else note_done(); w = (struct s2a_gate_watch){0}; last = -1; continue; }
            // 解到一半又来了新推送（执行器重推 / 又拷进一份）：回去等它传完再试，不报失败
            char root[2048], w2[600]; s2a_pack_root(root, sizeof root, g_imp_docs);
            if (s2a_import_state(g_imp_docs) == S2A_IMPORT_PENDING && s2a_import_transferring(root, w2, sizeof w2)) {
                LOG("资源导入：这次没解成（%s），但又有资源在传（%s）：等传完自动重试", s2a_pack_apply_failure(), w2); w = (struct s2a_gate_watch){0}; last = -1; continue; }
            s2a_ios_keep_awake(0); note_fail(); LOG("【红】资源导入：失败 %s", s2a_pack_apply_failure());
            return NULL;   // 不退出进程：UIKit 留着显示结果（玩家看到 _exit 会以为闪退）
        }
        if (act != last || poked) {
            if (act != last) LOG("资源导入：%s%s%s", act_name[act], why[0] ? "：" : "", why);
            gate_show(act, poked && act == last); s2a_ios_keep_awake(act == S2A_GATE_WAIT); last = act;
        }
        poked = !dispatch_semaphore_wait(g_poll_sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }
}
// host_main.c 自检之后、占地址窗口之前调（只在没指定 S2A_GAME_DATA 时，即玩家正常打开）：就绪直接返回 0；否则起闸门线程显示页面、等它判就绪。
//   预热路径（UIKit 已在主线程，本函数在宿主线程）里 s2a_front_run 立即返回：等到就绪就返回 1 接着起游戏（当场进）；老路径里 s2a_front_run 不返回。
//   返回 1 = 本局资源是闸门当场解开的：起局前读过的随包补丁 / 能力清单读的是解开前的资源包，调用方要重读（审计 P1-106）
static int imp_docs(char *out, size_t n) {   // 本局资源包闸门的文档根；0 = 本局不查（见 s2a_import_docs_pick）
    char proc[1024]; s2a_container_docs(proc, sizeof proc);
    return s2a_import_docs_pick(s2a_launch_ctx_get(), getenv("S2A_GAME_DATA") != NULL, proc, out, n);
}
int s2a_import_gate_applies(void) { char d[1024]; return imp_docs(d, sizeof d); }
// 资源包只缺非核心文件（v0.3.1 缺件照玩）：问玩家「仍要启动」。同一份资源包点过一次就记下（.partial_ok），不再问。
//   本线程等玩家点（s2a_ios_ask_continue 只在宿主工作线程上能等）；返回 1 = 放行，0 = 问不了（主线程上，调用方照旧走闸门）
int s2a_ios_ask_continue(const char *symbol, const char *title, const char *body, const char *go);   // ios/app.m
static int partial_ask(void) {
    char root[2048], mf[2300], sha[200]; s2a_pack_root(root, sizeof root, g_imp_docs);
    if (partial_confirmed(root)) { LOG("资源导入：缺 %d 个非必需文件，这份资源包玩家已确认过，照常起局", g_pack_bad); return 1; }
    if (!s2a_ios_ask_continue("exclamationmark.triangle.fill", S2A_UI(S2A_UI_PACK_PARTIAL_TITLE), S2A_UI(S2A_UI_PACK_PARTIAL_ASK), S2A_UI(S2A_UI_PACK_PARTIAL_GO))) return 0;
    snprintf(mf, sizeof mf, "%s/manifest.json", root);
    if (!manifest_sha(mf, sha, sizeof sha) && write_atomic(root, ".partial_ok", sha)) LOG("【黄】资源导入：记不下「已确认」（%s），下次还会再问", strerror(errno));
    LOG("资源导入：缺 %d 个非必需文件（如 %s），玩家点了「仍要启动」，照常起局；真读到缺的文件时游戏 Break → 说明页", g_pack_bad, g_pack_first);
    return 1;
}
int s2a_import_gate(void) {
    if (!imp_docs(g_imp_docs, sizeof g_imp_docs)) return 0;
    s2a_pack_migrate_one(g_imp_docs);   // 直接起这款（没经过游戏库）也先把旧位置的资源包挪过去（v0.3.0）
    CFStringRef dn = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("CFBundleDisplayName"));
    if (!dn || !CFStringGetCString(dn, g_imp_name, sizeof g_imp_name, kCFStringEncodingUTF8)) strlcpy(g_imp_name, "S2Arm", sizeof g_imp_name);
    int st = s2a_import_state(g_imp_docs);
    if (st == S2A_IMPORT_READY) return 0;
    if (st == S2A_IMPORT_PARTIAL && s2a_front_is_running() && partial_ask()) return 0;   // 只缺非核心文件：问一次「仍要启动」，点了照常起局
    LOG("资源导入：资源没就绪（状态 %d），起闸门线程每 3 秒判一次（UIKit 先起来，免得被启动看门狗杀）", st);
    g_poll_sem = dispatch_semaphore_create(0); g_ready_sem = dispatch_semaphore_create(0);
    // 有没有人等：界面已在跑（预热路径）→ 下面 s2a_front_run 立即返回、本线程等闸门；否则 s2a_front_run 进 UIApplicationMain 不返回，没人等
    atomic_store(&g_gate_waiting, s2a_front_is_running());
    pthread_t th; if (pthread_create(&th, NULL, gate_thread, NULL)) die("资源导入线程起不来");
    s2a_front_run(NULL);
    dispatch_semaphore_wait(g_ready_sem, DISPATCH_TIME_FOREVER); atomic_store(&g_gate_waiting, 0);
    if (s2a_import_state(g_imp_docs) == S2A_IMPORT_PARTIAL) partial_ask();   // 当场解开后发现只缺非核心文件：同样先问
    return 1;
}
// main() 起 UIKit 前问：资源包没就绪（要显示说明页 / 导入进度）就走延后启动，闸门在宿主线程上等「重新检查」
int s2a_import_needs_ui(void) {
    char docs[1024]; if (!imp_docs(docs, sizeof docs)) return 0;
    s2a_pack_migrate_one(docs);   // 起 UIKit 前判就绪：先迁（同 s2a_import_gate），免得旧位置有资源被判成「没有」
    return s2a_import_state(docs) != S2A_IMPORT_READY;
}
// 游戏中途因缺数据 Break（lifecycle.c 收局前问）：资源包这时核不过 = 是缺资源，不退出，弹同一页；游戏线程已坏、接不上，重新检查就绪后请玩家重新打开。
//   返回 1 = 已接管（调用方不退出，本线程停在这里）；资源包是好的返回 0（照常退出，是别的原因）
static void break_recheck(void) {
    int st = s2a_import_state(g_imp_docs);
    if (st == S2A_IMPORT_READY) { s2a_ios_hide_pack_help(); note_ready_reopen(); return; }
    char d[1024]; s2a_pack_help_detail(st, 1, d, sizeof d); s2a_ios_show_pack_help(help_title(st), d, g_imp_name, break_recheck);
}
int s2a_pack_help_on_break(void) {
    if (!imp_docs(g_imp_docs, sizeof g_imp_docs)) s2a_container_docs(g_imp_docs, sizeof g_imp_docs);   // 不查闸门的局（开发指定资源包）照旧核进程级 Documents
    if (!g_imp_name[0]) { CFStringRef dn = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("CFBundleDisplayName"));
        if (!dn || !CFStringGetCString(dn, g_imp_name, sizeof g_imp_name, kCFStringEncodingUTF8)) strlcpy(g_imp_name, "S2Arm", sizeof g_imp_name); }
    int st = s2a_import_state(g_imp_docs); if (st == S2A_IMPORT_READY) return 0;
    LOG("【红】游戏 Break 时资源包%s：不退出，显示说明页", st == S2A_IMPORT_BROKEN ? "不完整" : "不在");
    char d[1024]; s2a_pack_help_detail(st, 0, d, sizeof d); s2a_ios_show_pack_help(help_title(st), d, g_imp_name, break_recheck);
    return 1;
}
#endif
