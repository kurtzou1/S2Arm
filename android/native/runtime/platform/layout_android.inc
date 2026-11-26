// Android 现有地址需求表与布局。容量在占窗口前确定，GetInfo 后不重排。
#include <stdint.h>

// 布局预算 = 实际保留的整个窗口 72 GiB（普通档原先沿用 64 GiB、窗口 68 GiB；栈区按真值 2 GiB 后上限不定档也放不下）。
typedef struct { unsigned alias_gb, version, unbounded; uint64_t heap_size; } s2a_layout_requirements;
#include "../../../../runtime/include/s2a_window.h"
#define S2A_WINDOW_BUDGET S2A_WIN_SIZE
#define S2A_UNBOUNDED_WINDOW_BUDGET S2A_WIN_SIZE
// 固定部分 = TLS/保护页 2 MiB + 栈区 2 GiB + 共享映射余量 96 MiB。
//   栈区照 Horizon 39 位给 2 GiB（Ryujinx KPageTableBase stackRegion.Size = 0x80000000；同 runtime/src/layout.c VAMM_STACK）：
//   SDK 建线程在栈区里随机挑地址放线程栈（StackGuardManager::MapAtRandomAddress），原先写死 128 MiB，
//   Unity 款开局建线程把栈区占满后断言中止（11-14 奥日：栈区映射 40 MB、最高到区内 +128 MiB 顶满，CreateAliasStackUnsafe → AbortImpl）
#define S2A_LAYOUT_STACK (2048ull << 20)
#define S2A_LAYOUT_FIXED ((2ull << 20) + S2A_LAYOUT_STACK + (96ull << 20))
#include <ctype.h>
#include <errno.h>
#include <limits.h>

#define GB (1ull << 30)
#define MB (1ull << 20)

static int number(const char *s, int base, uint64_t *out) {
    if (!*s) return 0;
    for (const char *p = s; *p; p++)
        if (base == 16 ? !isxdigit((unsigned char)*p) : !isdigit((unsigned char)*p)) return 0;
    errno = 0; char *end; unsigned long long n = strtoull(s, &end, base);
    if (errno || *end) return 0;
    *out = n; return 1;
}

// 1 = 无表（仅 ENOENT），0 = 有效表，-1 = 明确错误。旧表只含别名区GB。
int s2a_android_layout_requirements_read(const char *path, uint64_t program_id, s2a_layout_requirements *out, const char **why) {
    *out = (s2a_layout_requirements){.heap_size = S2A_HEAP_DEFAULT}; *why = NULL;   // 无表：堆按应用池上限，别名区让位（svc_mem.c requirements_near）
    FILE *f = fopen(path, "r");
    if (!f) { if (errno == ENOENT) return 1; *why = "无法读取需求表"; return -1; }
    unsigned seen = 0; uint64_t version = 0, alias = 0, heap = 32, pid = 0;
    char *line = NULL; size_t capacity = 0; ssize_t count;
#define BAD(msg) do { *why = (msg); free(line); fclose(f); return -1; } while (0)
    while ((count = getline(&line, &capacity, f)) >= 0) {
        size_t len = (size_t)count;
        if (len > 511) BAD("需求表行过长");
        if (memchr(line, 0, len)) BAD("需求表包含NUL字节");
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
        if (!len || line[0] == '#') continue;
        char *value = strchr(line, '\t');
        if (!value || strchr(value + 1, '\t')) BAD("需求表应为两列TSV");
        *value++ = 0;
        unsigned bit;
        if (!strcmp(line, "版本")) { bit = 1; if (!number(value, 10, &version) || version != 2) BAD("不支持的需求表版本"); }
        else if (!strcmp(line, "别名区GB")) { bit = 2; if (!number(value, 10, &alias) || alias > 63 || (alias && alias < 4)) BAD("别名区容量无效（4–63GiB，0 表示未测）"); }   // Switch 39 位地址空间别名区至多 64GiB
        else if (!strcmp(line, "普通堆MB")) { bit = 4; if (!number(value, 10, &heap) || heap < 32 || (heap & 1) || heap > UINT64_MAX / MB) BAD("普通堆容量无效（至少32MiB，2MiB对齐）"); }
        else if (!strcmp(line, "程序号")) { bit = 8; if (strlen(value) != 16 || !number(value, 16, &pid) || !pid || pid != program_id) BAD("需求表程序号与NPDM不符"); }
        else if (!strcmp(line, "构建号")) {
            bit = 16; size_t n = strlen(value);
            if (n != 32 && n != 64) BAD("需求表构建号无效");
            for (size_t i = 0; i < n; i++) if (!isxdigit((unsigned char)value[i])) BAD("需求表构建号无效");
        } else if (!strcmp(line, "别名区上限")) { bit = 32; if (strcmp(value, "不定")) BAD("别名区上限只认「不定」"); }
        else if (!strcmp(line, "上限不定原因")) { bit = 64; if (!*value) BAD("上限不定原因为空"); }
        else BAD("需求表包含未知字段");
        if (seen & bit) BAD("需求表包含重复字段");
        seen |= bit;
    }
    if (ferror(f)) BAD("读取需求表失败");
    if (version == 2 ? (seen & 31) != 31 || ((seen >> 5) & 1) != ((seen >> 6) & 1) : seen != 2 || !alias || alias > 63) BAD("需求表缺少字段或旧表格式无效");
    free(line); fclose(f);
#undef BAD
    *out = (s2a_layout_requirements){.alias_gb = (unsigned)alias, .version = version ? 2 : 1,
                                    .unbounded = !!(seen & 32), .heap_size = heap * MB};
    return 0;
}

// 别名区预算：已测按表（4–63GiB）；未测（0）时给 64GiB 窗口里除去固定部分与已知堆后放得下的最大整 GiB、至多 63GiB——
//   已知的堆需求不被未测的别名默认值挤出窗口；让到不足 4GiB 即返回 0（调用方报红，请重新打包采集）
static uint64_t alias_budget(const s2a_layout_requirements *req) {
    if (req->unbounded) return 63 * GB;
    if (req->alias_gb) return req->alias_gb <= 63 ? req->alias_gb * GB : 0;
    if (req->heap_size > S2A_WINDOW_BUDGET - S2A_LAYOUT_FIXED) return 0;
    uint64_t room = (S2A_WINDOW_BUDGET - S2A_LAYOUT_FIXED - req->heap_size) & ~(GB - 1);
    if (room > 63 * GB) room = 63 * GB;
    return room >= 4 * GB ? room : 0;
}

int s2a_android_layout_split(s2a_layout_requirements *req, uint64_t module_span, const char **why, char *note, size_t cap) {
    if (cap) note[0] = 0;
    if (module_span > S2A_UNBOUNDED_WINDOW_BUDGET) { *why = "模块段占满窗口预算"; return -1; }
    uint64_t fixed = S2A_LAYOUT_FIXED + ((module_span + 2 * MB - 1) & ~(2 * MB - 1));   // 模块段在窗口尾、按 2 MiB 对齐排（loader.c）
    if (req->unbounded) {
        // 不截堆、不把“未证明有界”当静态大区上限；无法完整容纳则明确拒绝。
        if (fixed > S2A_UNBOUNDED_WINDOW_BUDGET - 63 * GB ||
            req->heap_size > S2A_UNBOUNDED_WINDOW_BUDGET - fixed - 63 * GB) {
            *why = "上限不定的别名区和完整普通堆放不进 72 GiB 窗口"; return -1;
        }
        req->alias_gb = 63;
        snprintf(note, cap, "别名区上限不定：保留 63 GiB 和完整普通堆 %llu MiB", (unsigned long long)(req->heap_size / MB));
        return 0;
    }
    if (module_span > S2A_WINDOW_BUDGET || fixed >= S2A_WINDOW_BUDGET) { *why = "模块段占满窗口预算"; return -1; }
    uint64_t budget = S2A_WINDOW_BUDGET - fixed;
    if (req->alias_gb) {
        uint64_t alias = (uint64_t)req->alias_gb * GB;
        if (alias + 32 * MB > budget) { *why = "已知别名区加最小堆 32 MiB 放不进窗口预算"; return -1; }
        uint64_t room = (budget - alias) & ~(2 * MB - 1);
        if (req->heap_size > room) {
            snprintf(note, cap, "别名区 %u GiB 优先，普通堆 %llu MiB 让到 %llu MiB", req->alias_gb, (unsigned long long)(req->heap_size / MB), (unsigned long long)(room / MB));
            req->heap_size = room;
        }
        return 0;
    }
    uint64_t room = budget > req->heap_size ? (budget - req->heap_size) & ~(GB - 1) : 0;
    if (room > 63 * GB) room = 63 * GB;
    if (room < 4 * GB) { *why = "普通堆加最小别名区 4 GiB 放不进窗口预算"; return -1; }
    req->alias_gb = (unsigned)(room / GB);
    snprintf(note, cap, "别名区未测，普通堆 %llu MiB 优先（%s），别名区让到 %u GiB", (unsigned long long)(req->heap_size / MB),
             req->version ? "表里的值" : "缺省 = 应用池上限", req->alias_gb);
    return 0;
}

uint64_t s2a_android_layout_need(uint32_t as_type, uint64_t sys_resource_size, const s2a_layout_requirements *req) {
    if (as_type != 3) return 0;
    if (!sys_resource_size) return 32 * GB;
#if defined(S2A_VAMM_BALANCED) && S2A_VAMM_BALANCED
    // Preserve Android's explicit legacy experiment. Normal builds use v2.
    (void)req;
    return 63 * GB;
#endif
    if (!req || (req->alias_gb && req->alias_gb < 4) || req->heap_size < 32 * MB || (req->heap_size & (2 * MB - 1))) return 0;
    uint64_t alias = alias_budget(req);
    if (!alias) return 0;
    // TLS/保护页到别名末共 alias + 2MiB；尾部：栈 2GiB + 按需堆 + 共享映射余量96MiB。
    uint64_t fixed = alias + S2A_LAYOUT_FIXED;
    if (req->heap_size > UINT64_MAX - fixed) return 0;
    return fixed + req->heap_size;
}

int s2a_android_layout_compute(uint32_t as_type, uint64_t sys_resource_size, const s2a_layout_requirements *req, uint64_t W, uint64_t S, s2a_layout *o) {
    memset(o, 0, sizeof *o);
    if (as_type != 3) return -1;
    uint64_t need = s2a_android_layout_need(as_type, sys_resource_size, req);
    if (!need) return -3;
    if (S < need || (W & (GB - 1)) || W > UINT64_MAX - need) return -2;
    o->win_base = W; o->win_size = need; o->as_type = as_type; o->sys_resource_size = sys_resource_size;
    if (sys_resource_size) {
#if defined(S2A_VAMM_BALANCED) && S2A_VAMM_BALANCED
        o->tlsio_base = W;                   o->tlsio_size = 2 * MB - 0x4000;
        o->alias_base = W + 2 * MB - 0x4000; o->alias_size = 56 * GB + 0x8000 - 2 * MB;
        uint64_t tail = W + 56 * GB + 2 * MB;
        o->stack_base = tail;                o->stack_size = 128 * MB;
        o->heap_base = tail + 128 * MB;       o->heap_size = 6 * GB;
        o->aslr_base = tail;                 o->aslr_size = 7 * GB - 2 * MB;
#else
        uint64_t A = alias_budget(req);
        // SDK 元数据占0x3FE00000，>=1GiB分配按GiB对齐且前后留4KiB。
        // 既有起点使62GiB地址区域能容纳于63GiB别名预算（地址空间.md A11）。
        o->tlsio_base = W;                       o->tlsio_size = 2 * MB - 0x4000;
        o->alias_base = W + 2 * MB - 0x4000;     o->alias_size = A + 0x8000 - 2 * MB;
        uint64_t tail = W + A + 2 * MB;
        o->stack_base = tail;                   o->stack_size = S2A_LAYOUT_STACK;
        o->heap_base = tail + S2A_LAYOUT_STACK; o->heap_size = req->heap_size;
        o->aslr_base = tail;                    o->aslr_size = S2A_LAYOUT_STACK + 96 * MB + req->heap_size;
#endif
    } else {
        // 非VAMM沿用39位布局；实际物理分配仍由SVC的应用池限制。
        // 堆区 6 GiB；应用池比它大（Switch 2 的 9 GiB）时放大到池（GiB 对齐）、别名区顺延，同 runtime/src/layout.c heapmode：
        //   不放大则 SetHeapSize 给不满池（Switch 2 一款开局要 9579790336 字节，堆区只有 6 GiB → 0xD001，起局即崩）。3 + 9 + 8 = 20 GiB，32 GiB 跨度内放得下
        uint64_t pool = (S2A_APP_POOL + GB - 1) & ~(GB - 1), heap = pool > 6 * GB ? pool : 6 * GB;
        o->tlsio_base = W;              o->tlsio_size = GB;
        o->stack_base = W + GB;         o->stack_size = 2 * GB;
        o->heap_base = W + 3 * GB;      o->heap_size = heap;
        o->alias_base = W + 3 * GB + heap; o->alias_size = 8 * GB;
        o->aslr_base = W;               o->aslr_size = need;
    }
    return 0;
}
