// 社区画面补丁运行时开关（直连线 10-27，维护者：宽屏 / 60 帧 / 画面补丁进包，宿主设置里启停；10-30 起玩家包缺省不带上游补丁字节，只有 S2A_COMMUNITY_PATCHES=1 出的内部包有这张表）：出包 pack/cpatch.py plan 写的 cpatch.tsv，
//   每份补丁在本模块占掩码的一位。代码里的改动已由改写器编成双路跳板（读键页槽 2046 的掩码、按位分路，runtime/rewriter/rewriter.c cpatch_rows），
//   这里只做两件事：按开关算掩码写进槽 2046；开着的补丁的数据写入（代码段之后，ro / data）写成补丁值，写前核原值（对不上 = 包与游戏不配套，那份不开）。
// 开关：S2A_CPATCH_ON = 逗号分隔的补丁编号（iOS 由 App 设置 S2ACommunityPatches 转来，ios/settings.m）；none = 全关；不设时按表里「缺省开」（Apple / Android 同口径，#48 D2 维护方定；安卓目前经调试环境通道设 S2A_CPATCH_ON）。下次启动生效
// 帧率类（编号 fps:）另跟 60 帧开关走（帧率能耗线 runtime/src/fps.c 起局与每次切换调 s2a_cpatch_fps_follow；没有我方帧率表的款才收这类，见 pack/cpatch.py）
// 随包表：cpatch.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单；
//   安卓 android/tools/make_pack.py 按安卓改写器出表放进 modules/，APK 起局经资源读面交 s2a_cpatch_load_source）
#include "native.h"
#include <errno.h>
#include <stdatomic.h>
#include <sys/mman.h>
#define CP_SLOT 2046
static _Thread_local FILE *g_boot_file;
void s2a_cpatch_abort_boot_inputs(void) {
    FILE *file = g_boot_file; g_boot_file = NULL;
    if (file && fclose(file)) LOG("【红】失败装载的社区补丁表关闭失败 errno=%d", errno);
}

static struct cp_fm { _Atomic uint64_t *slot; uint64_t bits; } *g_fm; static int g_cfm;   // 有帧率类补丁的各模块：掩码槽、其中帧率类的位（按需增长，无上限；只在装载时追加）
static struct { module_t *m; char *spec; } g_fd[64]; static int g_nfm, g_nfd;   // 帧率类的数据写入（切换时写补丁值 / 写回原值）
static _Atomic int g_nfps;   // 设置页可与会话装载 / 释放并发查询
int s2a_cpatch_fps_count(void) { return atomic_load(&g_nfps); }

// FPS controls and their writer must already be stopped. Only release host
// registrations; the loader restores the next session's pristine module data.
void s2a_cpatch_session_reset(void) {
    for (int i = 0; i < g_nfd; i++) free(g_fd[i].spec);
    memset(g_fd, 0, sizeof g_fd); free(g_fm); g_fm = NULL; g_cfm = 0;
    g_nfd = g_nfm = 0; atomic_store(&g_nfps, 0);
}

static int in_list(const char *list, const char *id) {
    size_t n = strlen(id);
    for (const char *p = list; (p = strstr(p, id)); p += n)
        if ((p == list || p[-1] == ',') && (p[n] == 0 || p[n] == ',')) return 1;
    return 0;
}
static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
// 数据写入「偏移:原字节:新字节」逐段：0 只核完整格式 / 范围 / 原值，1 写新值，2 写回原值。
// 先用 mode 0 核完整份，再允许写入或登记 follow；不截断长 spec、不在部分校验后写前半份。
int s2a_cpatch_data_writes(module_t *m, const char *spec, int mode);
static int data_writes(module_t *m, const char *spec, int mode) { return s2a_cpatch_data_writes(m, spec, mode); }
// 补丁包 [data] 段（patch_data.c）复用同一写入：范围 = 代码段末页之后到键页前，先 mode 0 全核再 mode 1 写
int s2a_cpatch_data_writes(module_t *m, const char *spec, int mode) {
    for (const char *t = spec; *t; ) {
        if (*t == ' ') { t++; continue; }
        const char *a = strchr(t, ':'), *b = a ? strchr(a + 1, ':') : NULL;
        if (!a || a == t || !b) return -1;
        uint64_t off = 0;
        for (const char *p = t; p < a; p++) {
            int v = hex_digit(*p); if (v < 0 || off > (UINT64_MAX - (unsigned)v) / 16) return -1;
            off = off * 16 + (unsigned)v;
        }
        const char *e = strchr(b + 1, ' '); if (!e) e = b + 1 + strlen(b + 1);
        size_t no = (size_t)(b - a - 1), nn = (size_t)(e - b - 1);
        if (!nn || no != nn || nn % 2) return -1;
        nn /= 2;
        // 同 loader.c map_image 的 text 封页边界；键页及其后的补丁区不属于原映像数据。
        uint64_t low = ((m->text_end + m->load_bias + 0x3fff) & ~0x3fffull) - m->load_bias;
        if (off < low || off > m->key_page_off || nn > m->key_page_off - off ||
            off > m->size || nn > m->size - off) return -1;
        for (size_t i = 0; i < nn; i++) {
            int oh = hex_digit(a[1 + 2 * i]), ol = hex_digit(a[2 + 2 * i]);
            int vh = hex_digit(b[1 + 2 * i]), vl = hex_digit(b[2 + 2 * i]);
            if (oh < 0 || ol < 0 || vh < 0 || vl < 0) return -1;
            uint8_t o = (uint8_t)(oh * 16 + ol), v = (uint8_t)(vh * 16 + vl);
            if (!mode && m->base[off + i] != o) return -1;
            if (mode) m->base[off + i] = mode == 1 ? v : o;
        }
        t = e;
    }
    return 0;
}
// 一个模块按表装载：f 由调用方打开（目录装载 = 模块目录的 cpatch.tsv；APK 起局 = 已验签的内存表），这里读完关掉
static void cpatch_load_stream(module_t *m, FILE *f) {
    g_boot_file = f;
    const char *on = getenv("S2A_CPATCH_ON");
    uint64_t mask = 0, fbits = 0; int n = 0;
    static char line[1 << 16];
    if (!fgets(line, sizeof line, f)) { fclose(f); g_boot_file = NULL; return; }   // 表头
    while (fgets(line, sizeof line, f)) {
        if (!strchr(line, '\n') && !feof(f)) {   // 不能把截断的前半行当完整份准入
            int ch; while ((ch = fgetc(f)) != '\n' && ch != EOF) {}
            LOG("【红】社区补丁 %s：表行过长，不开", m->name); continue;
        }
        line[strcspn(line, "\r\n")] = 0;
        char *c[9] = {0}; char *s = line; for (int i = 0; i < 9 && s; i++) { c[i] = s; s = strchr(s, '\t'); if (s) *s++ = 0; }
        if (!c[8] || strcmp(c[1], m->name)) continue;
        char *end; long bit = strtol(c[2], &end, 10);
        int en = on ? (strcmp(on, "none") && in_list(on, c[0])) : atoi(c[8]), fps = !strncmp(c[0], "fps:", 4);
        n++;
        if (c[2][0] < '0' || c[2][0] > '9' || *end || bit < 0 || bit >= 64) {
            LOG("【红】社区补丁 %s %s：位编号不在 0–63，不开", m->name, c[0]); continue;
        }
        if ((fps || en) && c[7][0] && data_writes(m, c[7], 0)) {
            LOG("【红】社区补丁 %s %s：数据格式 / 范围 / 原值不符（包与游戏不配套），不开", m->name, c[0]); continue;
        }
        if (fps) {
            if (c[7][0] && g_nfd >= 64) {
                LOG("【红】社区补丁 %s %s：帧率跟随表容量已满，整份不开", m->name, c[0]); continue;
            }
            if (c[7][0]) {
                char *spec = strdup(c[7]); if (!spec) die("社区帧率补丁数据分配失败");
                g_fd[g_nfd].m = m; g_fd[g_nfd].spec = spec; g_nfd++;
            }
            atomic_fetch_add(&g_nfps, 1); fbits |= 1ull << bit;
        }
        if (en && c[7][0] && data_writes(m, c[7], 1)) die("社区补丁已校验的数据写入失败");
        if (en) mask |= 1ull << bit;
        LOG("社区补丁：%s %s（%s · %s · 许可 %s）%s", m->name, c[0], c[3], c[4], c[5][0] ? c[5] : "未声明", en ? "开" : "关");
    }
    fclose(f); g_boot_file = NULL;
    if (!n) return;
    uint8_t *page = m->base + m->key_page_off;   // 键页（宽屏点同样把它改成可写：命中槽要写）
    if (mprotect(page, m->key_page_size, PROT_READ | PROT_WRITE)) die("%s 键页改可写失败（社区补丁槽）", m->name);
    ((uint64_t *)page)[CP_SLOT] = mask;
    if (fbits && g_nfm == g_cfm) {
        int nc = g_cfm ? g_cfm * 2 : 16; struct cp_fm *q = realloc(g_fm, (size_t)nc * sizeof *q);
        if (!q) die("社区帧率跟随表 %d 项分配失败", nc);
        g_fm = q; g_cfm = nc;
    }
    if (fbits) { g_fm[g_nfm].slot = (_Atomic uint64_t *)((uint64_t *)page + CP_SLOT); g_fm[g_nfm].bits = fbits; g_nfm++; }
}
void s2a_cpatch_load(module_t *m, const char *dir) {
    char p[1100]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "r"); if (!f) return;
    cpatch_load_stream(m, f);
}
// APK 起局（loader.c load_modules_from_source）：表与模块旁车同经已验签的 APK 资源读面读进内存，每个模块各按表装一遍。
//   表进了包却读不到 / 读坏 = 包有问题，报红中止（同 s2a_widen_load_source）；没有这张表的包由调用方跳过
void s2a_cpatch_load_source(module_t *m, const void *bytes, size_t length) {
    if (!bytes || !length || length > 16 * 1024 * 1024 || memchr(bytes, 0, length)) die("%s：APK 社区补丁表无效", m->name);
    FILE *f = fmemopen((void *)(uintptr_t)bytes, length, "r");   // 只读打开，不写回调用方的租约内存
    if (!f) die("APK 社区补丁表无法读取 errno=%d", errno);
    cpatch_load_stream(m, f);
}
// 60 帧开关（fps.c 起局一次、运行中每次切换调）：帧率类各位一起置开 / 关；它们的数据写入写补丁值 / 写回原值（原值在装载时核过）
void s2a_cpatch_fps_follow(int on) {
    for (int i = 0; i < g_nfm; i++) { if (on) atomic_fetch_or(g_fm[i].slot, g_fm[i].bits); else atomic_fetch_and(g_fm[i].slot, ~g_fm[i].bits); }
    for (int i = 0; i < g_nfd; i++) {
        if (data_writes(g_fd[i].m, g_fd[i].spec, on ? 1 : 2)) die("社区帧率补丁已准入的数据写入失败");
    }
    if (g_nfm || g_nfd) LOG("社区补丁：帧率类 %d 份跟 60 帧开关 %s", g_nfps, on ? "开" : "关");
}
