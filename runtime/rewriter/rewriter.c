/* J08: semantic port of patch_nso.py at main@4e1660c4114e0e9de42177735f9b98def332373f.
 * Instruction ordering and byte layout intentionally follow the Python oracle.
 * capstone/lz4 provenance and preparation: THIRD_PARTY.md. */
#include "rewriter.h"
#include <capstone/capstone.h>
#include <lz4.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <direct.h>
#define MKDIR(p) _mkdir(p)
#define TLS __declspec(thread)
#else
#define MKDIR(p) mkdir(p, 0777)
#define TLS _Thread_local
#endif
#define NOP 0xd503201fu
typedef unsigned __int128 Mask;
#define BIT(n) ((Mask)1 << (n))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define VEC(T)     \
  struct {         \
    T* v;          \
    size_t n, cap; \
  }
typedef int64_t A;
typedef struct {
  A a, b;
} Pair;
typedef VEC(A) AV;
typedef struct {
  A at;
  uint32_t w;
  char m[16];
  /* r18 / tgt：全量扫描的热路径（has18、直接跳转目标）在 decode 时顺手记下，不为它们重解详情（#509 合入时补：
   * 详情改按需重解后常规游戏改写慢 18–36%）。tgt = 详情最后一个操作数的 imm，同原 target() 读法 */
  uint8_t valid, sp, r18, has_tgt;
  Mask rd, wr;
  uint64_t regs;
  A tgt;
} Ins;
typedef VEC(Ins) IV;
typedef struct {
  A at;
  const char* kind;
  int arg, done;
} Site;
typedef struct {
  A at;
  char kind[32];
  char* why;
} Gap;
typedef struct {
  A at;
  const char* kind;
  int reg;
  uint32_t w;
} Trap; /* 两岛都够不着的必改点：原地 brk #(TRAP_IMM0 + 序号)，fixups 表头 # TRAP 行，装载器在 SIGTRAP 里按序号模拟（runtime/src/traps.c） */
typedef struct {
  A from, to;
  int entry;
} Far; /* 远跳（出包线 10-31，Minecraft [128, 144) MiB 那段 6325 个 x18 改写点）：两岛都够不着的单元照常生成进岛，越射程的 B 写成 brk #FAR_IMM，
        * fixups 表头 # FAR 行记 <从> <到>，装载器在 SIGTRAP 里按 pc 查表把 pc 设到 <到>（信号返回不受 ±128 MiB 射程限制）；entry = 从原代码进岛的那一跳（命中次数 = 单元执行次数） */
typedef struct {
  A ret, orig;
  const char* kind;
  int arg;
} Gate;
typedef struct {
  char key[40];
  size_t n;
} Stat;
typedef struct {
  IV ins;
} Segment;
typedef VEC(Segment) SegV;
typedef struct {
  SegV seg;
} Window;
typedef VEC(Window) WV;
typedef struct {
  A at, tbl, base;
  int type, B, I, T, count, setT, open, bias;
  AV targets, span;
  IV mids;
  int x1617_ok;     /* 调用方置 1：general 形态允许用到 x16/x17（目标集识别都认不出时的最后一条路） */
  int uses_x16x17;  /* 1 = 表基址/索引/拷贝用到 x16/x17：brrel 改借 x9–x15 */
  int cd;           /* general 形态里基址拷贝的目的寄存器（无拷贝 -1） */
} Jump; /* 1 compact, 2 classic relative, 3 general relative, 4 tail, 5 target set */
typedef VEC(Jump) JV;
typedef struct {
  int idx;
  A off;
  char kind[32];
  uint32_t w;
} Wide;
typedef struct {
  A head;
  AV backs;
} SpinSite;
/* Allocation headers make growth O(1), and guarantee cleanup after a gap or
 * malformed input. max_align_t keeps all vectors and 128-bit register masks aligned. */
typedef union Alloc {
  struct {
    union Alloc *prev, *next;
  } links;
  max_align_t alignment;
} Alloc;
typedef struct {
  cs_arm64 d;
  A at;
  uint32_t w;
  char op[160];
  int valid;
} DetailCache;
typedef struct {
  s2a_rewrite_request r;
  FILE *log, *out;
  csh cs;
  cs_insn* one;
  DetailCache detail_cache[8];
  unsigned detail_next;
  A one_at;   /* g->one 里现在是哪条（decode / detail 解完记下）：decode 后紧接着取详情（自旋区分析）直接拷，不重解 */
  uint32_t one_w;
  int one_ok;
  jmp_buf err, local;
  int guarding, android, ohos, far, below, sdk_cut, signed_jt, acq_off, rel_off;
  /* 双补丁岛（原生层 10-30）：dual = 本轮前岛（基址前）与后岛（映像后）都是候选；patch / po 是当前岛，patch2 / po2 是另一个岛（切岛 = 整体交换），
   * swapped = 当前岛不是本布局原来的那个岛；range_err = 本单元最近一次失败是 B 越射程；range_miss = 本轮出现过越射程 */
  int dual, swapped, range_err, range_miss;
  int farjump; /* 远跳模式：本单元越射程的 B 改发 brk #FAR_IMM 并记进 fars（见 Far） */
  char error[600];
  uint8_t *img, *orig;
  size_t len, text, ro, data, filelen, imagesize, front, bias;   // bias：装载偏置 LOAD_BIAS（见 patch_nso.py）
  A po, key, ehs;
  char id[33];
  VEC(uint32_t) patch, patch2;
  A po2, split;   // 双岛：另一个岛的偏移；split = 后岛偏移 / 2，低于它的单元先试前岛
  VEC(Trap) traps;
  VEC(Far) fars;
  AV spin_miss;   // 双岛：两岛都够不着、没改写的自旋区头
  VEC(Site) sites;
  VEC(Gap) gaps;
  VEC(Gate) gates;
  VEC(Stat) stats;
  WV windows;
  JV jumps;
  VEC(Wide) wide;
  VEC(SpinSite) spins;
  AV starts, bounds;
  /* 已占用的指令地址（done）：代码段内按字记位图，段外（不应出现，照收）记表；按地址查是 O(1)。
   * 原先是线性表 + 逐项比较，改写点多的模块（#251 EA SPORTS FC 27）查一次要扫几十万项 */
  uint8_t* consumed_map;
  AV consumed_far;
  /* 当前分析中函数的直接跳转目标（analyze 里每个函数只算一次；原先每条 br x18 的每种识别都整函数重算一遍并且不释放，#251） */
  const Ins* ftg_of;
  size_t ftg_n;
  AV ftg;
  size_t* fsrc_at;   /* ftg 第 i 个目标的来源（直接跳转在 l 里的下标，升序）= fsrc[fsrc_at[i] .. fsrc_at[i + 1]) */
  int* fsrc;
  size_t fwrites[128];   /* 当前函数里写寄存器 n 的指令条数（writes(x, n) 计数） */
  VEC(Pair) jidx;   /* (地址, 下标) 按地址再按下标排序：jump_at 二分 */
  VEC(Pair) cov;
  /* 动态段 RELA 表里的 R_AARCH64_RELATIVE（槽位, 加数），按槽位排序；.eh_frame 用绝对指针编码（absptr）时取加数（ehabs） */
  VEC(Pair) rela;
  int rela_loaded;
  uint8_t* codemap;   /* 非空 = 代码段混有内嵌数据，按字（4 字节）记真实代码范围（data_in_text） */
  size_t fixrefs;
  Alloc* allocs;
  /* 布局重选（同 patch_nso.py #290）：retry_front 非 0 = 本轮是容量不足后的重做；req / now = 上一轮 / 本轮成功的自旋回边 (头, 回边) */
  size_t retry_front, next_front;
  int retry_dual, next_dual;   // 本轮 / 下一轮是双岛布局
  const Pair* req;
  size_t nreq;
  Pair* now;
  size_t nnow;
  /* 活跃分析与危险函数判定的缓存（lv_get / lv_live / sp_dynamic）：随本轮 g 新建、随 g 的分配账一起释放。
   *   不能放线程本地静态变量按 g 指针认主：每轮重试 calloc 新 g，旧 g 释放后新 g 常拿到同一地址，缓存会拿着已释放的内存（11-11 动森 SPIN 重试 abort） */
  struct LvI* lv_tab;
  size_t lv_cap, lv_n;
  A* lv_sa;
  unsigned __int128* lv_sm;
  uint32_t* lv_sg;
  uint32_t lv_gen;
  A* spd_key;
  int8_t* spd_val;
  size_t spd_n, spd_cap;
} RW;
static TLS RW* g;
static void fail(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g->error, sizeof(g->error), fmt, ap);
  va_end(ap);
  if (g->guarding)
    longjmp(g->local, 1);
  longjmp(g->err, 1);
}
#define REQUIRE(x)                                \
  do {                                            \
    if (!(x))                                     \
      fail("条件不成立：%s（%d）", #x, __LINE__); \
  } while (0)
static void* resize(void* p, size_t n) {
  REQUIRE(n <= SIZE_MAX - sizeof(Alloc));
  Alloc* a = p ? (Alloc*)p - 1 : NULL;
  Alloc* prev = a ? a->links.prev : NULL;
  Alloc* next = a ? a->links.next : g->allocs;
  Alloc* q = realloc(a, sizeof(Alloc) + (n ? n : 1));
  if (!q)
    fail("内存不足");
  q->links.prev = prev;
  q->links.next = next;
  if (prev)
    prev->links.next = q;
  else
    g->allocs = q;
  if (next)
    next->links.prev = q;
  return q + 1;
}
static void release(void* p) {
  if (!p)
    return;
  Alloc* a = (Alloc*)p - 1;
  if (a->links.prev)
    a->links.prev->links.next = a->links.next;
  else
    g->allocs = a->links.next;
  if (a->links.next)
    a->links.next->links.prev = a->links.prev;
  free(a);
}
#define PUSH(x, value)                                 \
  do {                                                 \
    if ((x).n == (x).cap) {                            \
      (x).cap = (x).cap ? 2 * (x).cap : 16;            \
      (x).v = resize((x).v, (x).cap * sizeof(*(x).v)); \
    }                                                  \
    (x).v[(x).n++] = (value);                          \
  } while (0)
static void* zalloc(size_t n) {
  void* p = resize(NULL, n);
  memset(p, 0, n);
  return p;
}
static char* vformat(const char* fmt, va_list args) {
  va_list copy;
  va_copy(copy, args);
  int n = vsnprintf(NULL, 0, fmt, copy);
  va_end(copy);
  REQUIRE(n >= 0);
  char* text = resize(NULL, (size_t)n + 1);
  vsnprintf(text, (size_t)n + 1, fmt, args);
  return text;
}
static char* format(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char* text = vformat(fmt, args);
  va_end(args);
  return text;
}
static void msg(const char* fmt, ...) {
  if (!g->log)
    return;
  va_list a;
  va_start(a, fmt);
  vfprintf(g->log, fmt, a);
  va_end(a);
}
static int eq(const char* a, const char* b) {
  return !strcmp(a, b);
}
static int pre(const char* a, const char* b) {
  return !strncmp(a, b, strlen(b));
}
/* Capstone operand text is ASCII. Match the Python oracle's \b boundaries,
 * including digits and underscores: #0x18 is an immediate, not register x18. */
static int wordchar(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}
static int word_bounds(const char* text, const char* p, size_t n) {
  return (p == text || !wordchar(p[-1])) && !wordchar(p[n]);
}
static const char* find_word(const char* text, const char* word) {
  size_t n = strlen(word);
  for (const char* p = text; (p = strstr(p, word)); p++)
    if (word_bounds(text, p, n))
      return p;
  return NULL;
}
static int in(const char* m, const char* list) {
  size_t n = strlen(m);
  for (const char* p = list; *p;) {
    const char* e = strchr(p, '|');
    if (!e)
      e = p + strlen(p);
    if ((size_t)(e - p) == n && !memcmp(m, p, n))
      return 1;
    p = *e ? e + 1 : e;
  }
  return 0;
}
static int cmpa(const void* a, const void* b) {
  A x = *(const A*)a, y = *(const A*)b;
  return (x > y) - (x < y);
}
static void sort(AV* a) {
  if (a->n > 1)
    qsort(a->v, a->n, sizeof(A), cmpa);
  size_t n = 0;
  for (size_t i = 0; i < a->n; i++)
    if (!n || a->v[i] != a->v[n - 1])
      a->v[n++] = a->v[i];
  a->n = n;
}
static int contains(const AV* a, A x) {
  for (size_t i = 0; i < a->n; i++)
    if (a->v[i] == x)
      return 1;
  return 0;
}
static size_t upper(const AV* a, A x);
static int has(const AV* a, A x) {   /* a 已排序去重（sort）：二分查 */
  size_t i = upper(a, x);
  return i && a->v[i - 1] == x;
}
static size_t upper(const AV* a, A x) {
  size_t l = 0, r = a->n;
  while (l < r) {
    size_t m = l + (r - l) / 2;
    if (a->v[m] <= x)
      l = m + 1;
    else
      r = m;
  }
  return l;
}
static uint32_t u32(const uint8_t* p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void wr32(uint8_t* p, uint32_t w) {
  for (int i = 0; i < 4; i++)
    p[i] = (uint8_t)(w >> (8 * i));
}
static uint32_t iw(A at) {
  REQUIRE(at >= 0 && (uint64_t)at + 4 <= g->len);
  return u32(g->img + at);
}
static int32_t si(A at) {
  return (int32_t)iw(at);
}
static uint64_t iu64(A at) {
  return iw(at) | (uint64_t)iw(at + 4) << 32;
}
static void put(A at, uint32_t w) {
  REQUIRE(at >= 0 && (uint64_t)at + 4 <= g->len);
  wr32(g->img + at, w);
}
static A here(void) {
  return g->po + (A)g->patch.n * 4;
}
static void emit(uint32_t w) {
  PUSH(g->patch, w);
}
static void bump(const char* k) {
  for (size_t i = 0; i < g->stats.n; i++)
    if (eq(g->stats.v[i].key, k)) {
      g->stats.v[i].n++;
      return;
    }
  Stat s = {0};
  snprintf(s.key, sizeof(s.key), "%s", k);
  s.n = 1;
  PUSH(g->stats, s);
}
static void gap(A at, const char* k, const char* fmt, ...) {
  Gap x = {0};
  x.at = at;
  snprintf(x.kind, sizeof(x.kind), "%s", k);
  va_list a;
  va_start(a, fmt);
  x.why = vformat(fmt, a);
  va_end(a);
  for (char* p = x.why; *p; p++)
    if (*p == '\n' || *p == '\t')
      *p = ' ';
  PUSH(g->gaps, x);
}
/* 满屏候选点放不下（不在可改代码 / 已是别的改写点 / 原字对不上 / 跳板生成失败）：丢掉这个点、记黄，不进缺口（11-02 一次成功线：丹干V3 原生档出包因一个
 * movz 候选落在已改写处整单失败）。候选点是可选能力（缺省关，开要启用表 / 补丁），丢掉只少一个可开的点；候选表按收下的行顺排序号，不会错位 */
static void wskip(A at, const char* fmt, ...) {
  va_list a;
  va_start(a, fmt);
  char* why = vformat(fmt, a);
  va_end(a);
  msg("【黄】%s 满屏候选 0x%" PRIx64 " 跳过（不计缺口）：%s\n", g->r.module, (uint64_t)at, why);
  release(why);
  bump("widen_skip");
}
static const char* shx(char* b, A a) { /* 同 Python f'{a:#x}'：负数写成 -0x… */
  snprintf(b, 24, "%s0x%" PRIx64, a < 0 ? "-" : "", a < 0 ? (uint64_t)-a : (uint64_t)a);
  return b;
}
#define FAR_IMM 0xA000 /* 远跳 brk 的立即数（按编号的陷入用 0x8000–0x9FFF，见 TRAP_MAX；macOS 截走 0xB000–0xBFFF） */
static uint32_t branch(A pc, A to) {
  A d = to - pc;
  if (g->farjump && !(d >= -(1LL << 27) && d < (1LL << 27)) && d % 4 == 0) {
    Far f = {pc, to, pc >= 0 && (size_t)pc < g->text};
    PUSH(g->fars, f);
    return 0xd4200000u | ((uint32_t)FAR_IMM << 5);
  }
  /* 回滚保护内越界 = 撤本单元：越射程置 range_err（双岛据此换岛 / 下一轮开双岛），消息与 patch_nso.py B() 逐字节相同（越射程不许无声） */
  if (g->guarding && !(d >= -(1LL << 27) && d < (1LL << 27) && d % 4 == 0)) {
    char x[24], y[24], z[24];
    g->range_err = !(d >= -(1LL << 27) && d < (1LL << 27));
    fail("B range frm %s to %s off %s", shx(x, pc), shx(y, to), shx(z, d));
  }
  REQUIRE(d >= -(1LL << 27) && d < (1LL << 27) && d % 4 == 0);
  return 0x14000000 | ((uint32_t)(d >> 2) & 0x3ffffff);
}
/* 切岛：当前岛与另一个岛整体交换，here() / emit() / 回填（g->po + 4 * 下标）随之换岛 */
static void swap_island(void) {
  __typeof__(g->patch) t = g->patch;
  g->patch = g->patch2;
  g->patch2 = t;
  A o = g->po;
  g->po = g->po2;
  g->po2 = o;
  g->swapped = !g->swapped;
}
static void island(int front) {
  if (g->dual && (g->po < 0) != front)
    swap_island();
}
static void home(void) {
  if (g->swapped)
    swap_island();
}
/* 跑一个改写单元：按地址选岛（低于 split 先试前岛），回滚点取在切岛之后；越射程换另一个岛再试一次。
 * 成功回 1；失败回 0（已回滚补丁区 / 槽计数 / 门表，undo 撤单元自己的原位改动；g->error 是原因，g->range_err 标是否越射程） */
static int unit_run(A at, void (*fn)(void*), void* arg, void (*undo)(void*)) {
  int first = at < g->split, tries = g->dual ? 2 : 1;
  for (int k = 0; k < tries; k++) {
    island(k ? !first : first);
    size_t p = g->patch.n, f = g->fixrefs, gt = g->gates.n, fr = g->fars.n;
    g->range_err = 0;
    if (!setjmp(g->local)) {
      fn(arg);
      return 1;
    }
    g->patch.n = p;
    g->fixrefs = f;
    g->gates.n = gt;
    g->fars.n = fr;
    if (undo)
      undo(arg);
    if (!g->range_err)
      return 0;
    g->range_miss = 1;
  }
  return 0;
}
static uint32_t pair(uint32_t op, int t, int t2, int n, int off) {
  return op | (((uint32_t)(off / 8) & 127) << 15) | (t2 << 10) | (n << 5) | t;
}
#define STP(t, t2, n, o) pair(0xa9000000, t, t2, n, o)
#define LDP(t, t2, n, o) pair(0xa9400000, t, t2, n, o)
#define STPRE(t, t2, n, o) pair(0xa9800000, t, t2, n, o)
#define LDPOST(t, t2, n, o) pair(0xa8c00000, t, t2, n, o)
#define STUR(t, n, o) (0xf8000000u | (((uint32_t)(o) & 511) << 12) | ((n) << 5) | (t))
#define LDUR(t, n, o) (0xf8400000u | (((uint32_t)(o) & 511) << 12) | ((n) << 5) | (t))
#define LDR(t, n, o) (0xf9400000u | ((o) << 10) | ((n) << 5) | (t))
#define STR(t, n, o) (0xf9000000u | ((o) << 10) | ((n) << 5) | (t))
#define ADDI(d, n, i, s) (0x91000000u | ((s) << 22) | ((i) << 10) | ((n) << 5) | (d))
#define SUBI(d, n, i, s) (0xd1000000u | ((s) << 22) | ((i) << 10) | ((n) << 5) | (d))
#define ADDR(d, n, m) (0x8b000000u | ((m) << 16) | ((n) << 5) | (d))
#define BR(n) (0xd61f0000u | ((n) << 5))
#define BLR(n) (0xd63f0000u | ((n) << 5))
#define MOVZ(d, i, h) (0xd2800000u | ((h) << 21) | ((i) << 5) | (d))
#define MOVK(d, i, h) (0xf2800000u | ((h) << 21) | ((i) << 5) | (d))
#define STRPRE(t, n, o) (0xf8000c00u | (((uint32_t)(o) & 511) << 12) | ((n) << 5) | (t))
#define LDRPOST(t, n, o) (0xf8400400u | (((uint32_t)(o) & 511) << 12) | ((n) << 5) | (t))
static uint32_t adrp(int d, A pc, A to) {
  A im = ((to & ~4095LL) - (pc & ~4095LL)) >> 12;
  REQUIRE(im >= -(1LL << 20) && im < (1LL << 20));
  return 0x90000000 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5) | d;
}
static void key(int t, int k);
static int noredzone(void) { return g->android || g->ohos; }
/* Thread-slot base. scratch is already saved by each caller and next used for its key offset.
 * OHOS musl: TP + probed signed TSDOFF contains the pthread key table; logical base = table - 8.
 * Apple/Android instruction streams remain byte-for-byte unchanged. */
static void tp(int t, int scratch) {
  if (g->android) {
    emit(0xd53bd040 | t); /* mrs t, tpidr_el0 */
    emit(LDUR(t, t, -8));
  } else if (g->ohos) {
    REQUIRE(t != scratch);
    emit(0xd53bd040 | t); /* mrs t, tpidr_el0 */
    key(scratch, 4);      /* TSDOFF */
    emit(ADDR(t, t, scratch));
    emit(LDR(t, t, 0));
    emit(SUBI(t, t, 8, 0));
  } else
    emit(0xd53bd060 | t); /* mrs t, tpidrro_el0 */
}
static void key(int t, int k) {
  g->fixrefs++;
  emit(adrp(t, here(), g->key));
  emit(LDR(t, t, k));
}
static void slot(int base, int tmp, int k) {
  key(tmp, k);
  emit(ADDR(base, base, tmp));
}
static void stash(int s, int t, int nrz) {
  emit(nrz ? STPRE(s, t, 31, -16) : STP(s, t, 31, -16));
}
static void unstash(int s, int t, int nrz) {
  emit(nrz ? LDPOST(s, t, 31, 16) : LDP(s, t, 31, -16));
}
static int regnum(unsigned r) {
  const char* n = cs_reg_name(g->cs, r);
  if (!n)
    return -1;
  if (eq(n, "fp"))
    return 29;
  if (eq(n, "lr"))
    return 30;
  if ((n[0] == 'x' || n[0] == 'w') && n[1] >= '0' && n[1] <= '9')
    return atoi(n + 1);
  return -1;
}
static int regbit(unsigned r) {
  int n = regnum(r);
  if (n >= 0)
    return n;
  const char* s = cs_reg_name(g->cs, r);
  if (!s)
    return -1;
  if (in(s, "sp|wsp"))
    return 31;
  if (eq(s, "nzcv"))
    return 32;
  if (strchr("bhsdqv", s[0]) && s[1] >= '0' && s[1] <= '9')
    return 33 + atoi(s + 1);
  return -1;
}
static int decode(uint32_t w, A at, Ins* out) {
  memset(out, 0, sizeof(*out));
  uint8_t b[4];
  wr32(b, w);
  const uint8_t* p = b;
  size_t n = 4;
  uint64_t a = at;
  g->one_ok = 0;
  if (!cs_disasm_iter(g->cs, &p, &n, &a, g->one))
    return 0;
  g->one_ok = 1, g->one_at = at, g->one_w = w;
  cs_insn* x = g->one;
  out->valid = 1;
  out->at = at;
  out->w = w;
  REQUIRE(strlen(x->mnemonic) < sizeof(out->m));
  snprintf(out->m, sizeof(out->m), "%s", x->mnemonic);
  cs_regs rd, wr;
  uint8_t nr = 0, nw = 0;
  REQUIRE(cs_regs_access(g->cs, x, rd, &nr, wr, &nw) == CS_ERR_OK);
  for (int i = 0; i < nr; i++) {
    int k = regbit(rd[i]);
    if (k >= 0)
      out->rd |= BIT(k);
  }
  for (int i = 0; i < nw; i++) {
    int k = regbit(wr[i]);
    if (k >= 0)
      out->wr |= BIT(k);
  }
  out->regs = (out->rd | out->wr) & 0x7fffffff;
  for (const char* s = x->op_str; *s; s++)
    if (*s == 'x' || *s == 'w') {
      size_t n = 1 + strspn(s + 1, "0123456789");
      if (n > 1 && n <= 3 && word_bounds(x->op_str, s, n)) {
        int k = atoi(s + 1);
        if (k < 31)
          out->regs |= BIT(k);
      }
    }
  out->sp = find_word(x->op_str, "sp") != NULL || find_word(x->op_str, "wsp") != NULL;
  out->r18 = find_word(x->op_str, "x18") != NULL || find_word(x->op_str, "w18") != NULL;
  if (x->detail && x->detail->arm64.op_count > 0) {
    out->has_tgt = 1;
    out->tgt = x->detail->arm64.operands[x->detail->arm64.op_count - 1].imm;
  }
  return 1;
}
static const cs_arm64* detail(const Ins* in) {
  for (size_t i = 0; i < sizeof(g->detail_cache) / sizeof(g->detail_cache[0]); i++) {
    DetailCache* c = &g->detail_cache[i];
    if (c->valid && c->at == in->at && c->w == in->w)
      return &c->d;
  }
  {
    DetailCache* c = &g->detail_cache[g->detail_next++ % (sizeof(g->detail_cache) / sizeof(g->detail_cache[0]))];
    uint8_t b[4];
    wr32(b, in->w);
    const uint8_t* p = b;
    size_t n = sizeof(b);
    uint64_t at = (uint64_t)in->at;
    if (!(g->one_ok && g->one_at == in->at && g->one_w == in->w)) {
      g->one_ok = 0;
      if (!cs_disasm_iter(g->cs, &p, &n, &at, g->one)) {   /* analyze 把解不出的字按 udf #0 记、w 留原字：详情同当时存下的 udf #0 */
        wr32(b, 0);
        p = b, n = sizeof(b), at = (uint64_t)in->at;
        REQUIRE(cs_disasm_iter(g->cs, &p, &n, &at, g->one));
      } else
        g->one_ok = 1, g->one_at = in->at, g->one_w = in->w;
    }
    REQUIRE(g->one->detail);
    c->d = g->one->detail->arm64;
    c->at = in->at;
    c->w = in->w;
    memcpy(c->op, g->one->op_str, sizeof(c->op));
    c->valid = 1;
    return &c->d;
  }
}
static const char* operand_text(const Ins* in) {
  const cs_arm64* d = detail(in);
  for (size_t i = 0; i < sizeof(g->detail_cache) / sizeof(g->detail_cache[0]); i++)
    if (&g->detail_cache[i].d == d)
      return g->detail_cache[i].op;
  REQUIRE(0);
  return "";
}
_Static_assert(sizeof(Ins) <= 80, "per-instruction state must stay compact for very large functions");
static Ins dis(uint32_t w, A a) {
  Ins x;
  REQUIRE(decode(w, a, &x));
  return x;
}
/* Match Python _wconst, including the ORR-immediate MOV alias. */
static int wconst(A at, int* reg, uint32_t* value) {
  uint32_t w = iw(at);
  *reg = w & 31;
  if ((w & 0xffe00000) == 0x52a00000) {
    *value = ((w >> 5) & 65535) << 16;
    return 1;
  }
  if ((w & 0xffe00000) == 0x52800000) {
    *value = (w >> 5) & 65535;
    return 1;
  }
  if ((w & 0xff8003e0) == 0x320003e0) {
    Ins x;
    if (decode(w, at, &x)) {
      const char* p = strrchr(operand_text(&x), '#');
      char* end;
      if (p && p[1]) {
        unsigned long v = strtoul(p + 1, &end, 0);
        if (!*end && v <= UINT32_MAX) {
          *value = (uint32_t)v;
          return 1;
        }
      }
    }
  }
  return 0;
}
static uint32_t movz_hi(int reg, uint32_t value) {
  return 0x52a00000 | ((value >> 16) << 5) | reg;
}
/* Recognize the SDK code shape, never a game identity or fixed address. Scan
 * and collect every constructor before changing any instruction, as Python does. */
static void sdk_addr_cut(void) {
  if (!g->sdk_cut)
    return;
  typedef struct {
    A at;
    int reg;
    uint32_t value;
  } Constant;
  VEC(Constant) cs = {0};
  VEC(Pair) ctors = {0};
  for (A at = 0; at < (A)g->text; at += 4) {
    Constant c = {at, 0, 0};
    if (wconst(at, &c.reg, &c.value) &&
        (c.value == 0x3fe00000 || c.value == 0x40000000 || c.value == 0x2000000 ||
         c.value == 0x400000 || c.value == 0x200000 || c.value == 0x10000))
      PUSH(cs, c);
  }
  for (size_t i = 0; i < cs.n; i++) {
    Constant a = cs.v[i];
    if (a.value != 0x3fe00000)
      continue;
    for (size_t j = i + 1; j < cs.n && cs.v[j].at - a.at <= 0x140; j++) {
      Constant b = cs.v[j];
      if (b.value != 0x3fe00000)
        continue;
      int add = 0, store = 0, node = 0;
      for (A at = a.at; at <= b.at; at += 4) {
        Ins x;
        if (!decode(iw(at), at, &x))
          break; /* Capstone's range disassembly stops at the first invalid word. */
        int dst, src;
        char extra;
        if (at - a.at < 8 * 4 && eq(x.m, "add") &&
            sscanf(operand_text(&x), "x%d, x1, x%d%c", &dst, &src, &extra) == 2 && src == a.reg)
          add = 1;
        const char* suffix = "[x0, #0x28]";
        size_t len = strlen(operand_text(&x)), tail = strlen(suffix);
        if (at - a.at < 10 * 4 && in(x.m, "str|stp") && len >= tail &&
            eq(operand_text(&x) + len - tail, suffix))
          store = 1;
        if (eq(x.m, "mov") && eq(operand_text(&x), "w2, #0x30"))
          node = 1;
      }
      if (add && store && node) {
        Pair p = {(A)i, (A)j};
        PUSH(ctors, p);
      }
    }
  }
  for (size_t i = 0; i < ctors.n; i++) {
    Constant a = cs.v[ctors.v[i].a], b = cs.v[ctors.v[i].b];
    put(a.at, movz_hi(a.reg, 0x3e00000));
    put(b.at, movz_hi(b.reg, 0x3e00000));
    bump("sdk_node_cut");
    msg("SDK 节点区 1 GB → 62 MB：0x%" PRIx64 " / 0x%" PRIx64 "\n", a.at, b.at);
    for (size_t j = 0; j < cs.n; j++) {
      Constant c = cs.v[j];
      if (c.value != 0x40000000 || c.at <= b.at || c.at > b.at + 0x400)
        continue;
      unsigned near = 0;
      for (size_t k = 0; k < cs.n; k++) {
        Constant n = cs.v[k];
        if (n.at < c.at - 0x60 || n.at > c.at + 0x60)
          continue;
        if (n.value == 0x2000000) near |= 1;
        if (n.value == 0x400000) near |= 2;
        if (n.value == 0x200000) near |= 4;
        if (n.value == 0x10000) near |= 8;
      }
      if (near == 15) {
        put(c.at, movz_hi(c.reg, 0x2000000));
        bump("sdk_align_cut");
        msg("SDK 地址区 ≥1 GB 对齐 1 GB → 32 MB：0x%" PRIx64 "\n", c.at);
      }
    }
  }
}
static int has18(const Ins* x) {
  return x->r18;
}
static int writes(const Ins* x, int n) {
  return !!(x->wr & BIT(n));
}
static int reads(const Ins* x, int n) {
  return !!(x->rd & BIT(n));
}
static int isbr(const Ins* x) {
  return in(x->m, "b|bl|br|blr|ret|cbz|cbnz|tbz|tbnz") || pre(x->m, "b.");
}
static int direct(const Ins* x) {
  return isbr(x) && !in(x->m, "br|blr|ret");
}
static A target(const Ins* x) {
  REQUIRE(x->has_tgt);
  return x->tgt;
}
static void pick(uint64_t used, int* s, int* t) {
  *s = *t = -1;
  for (int r = 0; r < 16; r++)
    if (!(used & BIT(r))) {
      if (*s < 0)
        *s = r;
      else {
        *t = r;
        break;
      }
    }
  REQUIRE(*s >= 0 && *t >= 0);
}
/* 活跃分析（11-11 一款第一方动作游戏 / #515）：补丁岛不再往游戏 sp 以下压栈存临时寄存器，改用此处证明「之后不再被读」的寄存器当临时。
 *   游戏会把活数据放在 sp 以下（1.0.0 / 1.4.0 同一函数：变长数组开完 mov sp, x29 恢复 sp，之后照常读写，最远 sp-272），
 *   原先岛在 sp-0x90 压 16 字节盖掉它 → 下标成垃圾 → 野指针段错误。真机上 sp 以下没人写，所以只有改写后才崩。
 * 判法：从 start 起在原映像（g->orig，不受已放的跳岛影响）沿控制流往后走，每条路径上 r 先被整写（不先读）、或走到 bl / blr / ret
 *   （AAPCS：x9–x17、v16–v31 调用方保存，过调用即被改写、返回后调用方不再指望）即这条路死；读到 r、遇 br / svc / 解不出 / 出代码段 /
 *   走满预算一律当活（宁可不用）。别的改写点的岛只改写在那一点同样已证死的寄存器，与原程序语义一致，不影响本判断。
 * 读写集按操作数自己判（见 lv_get，capstone 的写集对别名不可信）；部分写（movk / bfi 类、向量按元素写 / 写高半 / 累加、带访存的向量写）当读。
 * 只在「恢复 sp 后还用 sp 以下数据」的函数里用（sp_dynamic，处数很少）：普通函数照旧写法，改写产物与旧改写器逐字节相同。 */
static int in_code(A a);
static A branch_target(uint32_t w, A a);
static const char* operand_text(const Ins* in);
#define LV_BUDGET (1 << 16)   /* 只在危险函数里用（处数很少），预算放宽 */
/* 指令摘要缓存（全程共用，按地址开放寻址）：读集 / 写集（部分写已并进读集）、种类、直接跳转目标 */
enum { LV_SEQ, LV_CALL, LV_RET, LV_STOP, LV_B, LV_COND };
typedef struct LvI { A a; Mask rd, wr; A t; uint8_t k, used; } LvI;
static int lv_simd_partial(const Ins* x) {   /* 向量写只改一部分（按元素 / 写高半 / 累加）：当读 */
  size_t n = strlen(x->m);
  return strchr(operand_text(x), '[') || (n > 1 && x->m[n - 1] == '2') ||
         in(x->m, "bif|bit|bsl|fmla|fmls|mla|mls|sdot|udot|usdot|sudot|bfdot|fmlal|fmlsl|sqrdmlah|sqrdmlsh|saba|uaba|sadalp|uadalp|"
                  "ssra|usra|srsra|ursra|sri|sli|fcmla|bfmmla|smmla|ummla|usmmla|bfmlalb|bfmlalt|smlal|umlal|smlsl|umlsl|sqdmlal|sqdmlsl|sabal|uabal|tbx");
}
static const LvI* lv_get(A a) {
  if (g->lv_n * 2 >= g->lv_cap) {   /* 扩容重排 */
    size_t oc = g->lv_cap; LvI* ot = g->lv_tab;
    g->lv_cap = oc ? oc * 2 : (1u << 16);
    g->lv_tab = zalloc(g->lv_cap * sizeof(LvI));
    g->lv_n = 0;
    for (size_t i = 0; i < oc; i++)
      if (ot[i].used) {
        size_t h = ((uint64_t)ot[i].a * 0x9E3779B97F4A7C15ull) >> 20 & (g->lv_cap - 1);
        while (g->lv_tab[h].used) h = (h + 1) & (g->lv_cap - 1);
        g->lv_tab[h] = ot[i]; g->lv_n++;
      }
    if (ot) release(ot);
  }
  size_t h = ((uint64_t)a * 0x9E3779B97F4A7C15ull) >> 20 & (g->lv_cap - 1);
  while (g->lv_tab[h].used) {
    if (g->lv_tab[h].a == a) return &g->lv_tab[h];
    h = (h + 1) & (g->lv_cap - 1);
  }
  LvI* e = &g->lv_tab[h];
  e->used = 1, e->a = a, e->t = -1, e->k = LV_STOP;
  g->lv_n++;
  if (a < 0 || (uint64_t)a + 4 > g->text || (a & 3) || !in_code(a)) return e;
  uint32_t w = u32(g->orig + a);
  Ins x;
  if (!decode(w, a, &x) || in(x.m, "svc|hvc|smc|brk|hlt|udf|eret|dcps1|dcps2|dcps3")) return e;
  /* 读写集按操作数自己判，不信 capstone 的写集：它对别名把源当写（cmp x15, #2 报「写 x15」，11-11 实测）。
   *   读 = capstone 报的读 ∪ 所有出现的寄存器（含访存基址 / 索引）；纯写 = 下面认得出的目的操作数，且不在读里。 */
  const cs_arm64* d = detail(&x);
  Mask all = 0, dst = 0;
  for (int i = 0; i < d->op_count; i++) {
    const cs_arm64_op* o = &d->operands[i];
    int k = -1;
    if (o->type == ARM64_OP_REG) k = regbit(o->reg);
    else if (o->type == ARM64_OP_MEM) {
      int b = o->mem.base ? regbit(o->mem.base) : -1, n = o->mem.index ? regbit(o->mem.index) : -1;
      if (b >= 0) all |= BIT(b);
      if (n >= 0) all |= BIT(n);
      continue;
    }
    if (k < 0) continue;
    all |= BIT(k);
    int pair = in(x.m, "ldp|ldnp|ldpsw|ldxp|ldaxp|ldiapp") ;
    if (i == 0 || (i == 1 && pair)) dst |= BIT(k);
  }
  int src_only = in(x.m, "cmp|cmn|tst|ccmp|ccmn|fcmp|fcmpe|fccmp|fccmpe|cbz|cbnz|tbz|tbnz|br|blr|ret|prfm|prfum|msr|sys|dc|ic|at|tlbi|hint|stp|stnp|stgp|st1|st2|st3|st4") ||
                 (pre(x.m, "st") && !pre(x.m, "stx") && !pre(x.m, "stlx")) || pre(x.m, "cas") || pre(x.m, "swp") || pre(x.m, "ldadd") || pre(x.m, "ldclr") ||
                 pre(x.m, "ldeor") || pre(x.m, "ldset") || pre(x.m, "ldsmax") || pre(x.m, "ldsmin") || pre(x.m, "ldumax") || pre(x.m, "ldumin");
  if (src_only) dst = 0;
  if (pre(x.m, "movk") || pre(x.m, "bf")) dst = 0;   /* movk / bfi / bfxil / bfm / bfc：保留其余位 = 读 */
  Mask vec = ~(((Mask)1 << 33) - 1);
  if ((dst & vec) && lv_simd_partial(&x)) dst &= ~vec;
  e->rd = x.rd | (all & ~dst);
  e->wr = dst & ~e->rd;
  e->k = LV_SEQ;
  if ((w & 0xfc000000u) == 0x94000000u || (w & 0xfffffc1fu) == 0xd63f0000u || pre(x.m, "blra")) e->k = LV_CALL;
  else if ((w & 0xfffffc1fu) == 0xd65f0000u || pre(x.m, "reta")) e->k = LV_RET;
  else if ((w & 0xfffffc1fu) == 0xd61f0000u || pre(x.m, "bra")) e->k = LV_STOP;   /* br：去向不定 */
  else if ((e->t = branch_target(w, a)) >= 0) e->k = (w & 0xfc000000u) == 0x14000000u ? LV_B : LV_COND;
  return e;
}
/* 调用 / 返回处视为被改写（调用方保存）的寄存器：调用 x9–x17、v16–v31；返回 x2–x17、v4–v7、v16–v31（返回值只在 x0 / x1、v0–v3） */
#define VB(n) BIT(33 + (n))
static Mask lv_range(int lo, int hi, int off) { Mask m = 0; for (int r = lo; r <= hi; r++) m |= BIT(off + r); return m; }
/* 在 start 之后仍可能被读的 cand 子集（cand 以外不判）。一遍深度优先同时判全部候选；走满预算 / br / svc / 解不出，未判定的一律当活 */
static Mask lv_live(A start, Mask cand, int budget0) {
  static TLS Mask callk, retk;
  if (!callk) { callk = lv_range(9, 17, 0) | BIT(30) | lv_range(16, 31, 33); retk = lv_range(2, 17, 0) | lv_range(4, 7, 33) | lv_range(16, 31, 33); }
  enum { SEEN = 1 << 17, ST = 1024 };
  if (!g->lv_sa) g->lv_sa = zalloc(SEEN * sizeof(A)), g->lv_sm = zalloc(SEEN * sizeof(Mask)), g->lv_sg = zalloc(SEEN * sizeof(uint32_t));
  A* sa = g->lv_sa; Mask* sm = g->lv_sm; uint32_t* sg = g->lv_sg;
  uint32_t gen = ++g->lv_gen;
  struct { A a; Mask u; } st[ST];
  int nst = 0, budget = budget0;
  Mask live = 0;
  st[nst].a = start, st[nst].u = cand, nst++;
  while (nst) {
    nst--;
    A a = st[nst].a; Mask u = st[nst].u;
    while (u) {
      if (--budget < 0) return live | cand;
      size_t h = ((uint64_t)a * 0x9E3779B97F4A7C15ull) >> 47;   /* 17 位 */
      for (int p = 0;; p++) {
        if (p == 64) return live | cand;
        size_t i = (h + p) & (SEEN - 1);
        if (sg[i] != gen) { sg[i] = gen, sa[i] = a, sm[i] = u; break; }
        if (sa[i] == a) { u &= ~sm[i]; sm[i] |= u; break; }   /* 这些候选在此点已探过 */
      }
      if (!u) break;
      const LvI* e = lv_get(a);
      if (e->k == LV_STOP) return live | cand;
      live |= e->rd & u;
      u &= ~(e->rd | e->wr);
      if (e->k == LV_CALL) { live |= u & ~callk; break; }
      if (e->k == LV_RET) { live |= u & ~retk; break; }
      if (e->k == LV_B) { a = e->t; continue; }
      if (e->k == LV_COND) {
        if (nst == ST) return live | cand;
        st[nst].a = e->t, st[nst].u = u, nst++;
      }
      a += 4;
    }
  }
  return live;
}
/* 函数里有没有「动态往下开栈」（mov sp, xN / add|sub sp, xN, #k，N 不是 sp / x29；add|sub sp, xM, xN 扩展寄存器）：变长数组 / alloca 一类。只有这类函数会在
 *   恢复 sp 之后把活数据留在 sp 以下（一款第一方动作游戏：mov sp, x29 后照读写数组）；AArch64 没有红区，普通函数编译器从不用 sp 以下。
 *   按函数起点缓存。也是「只分析不改写」模式判受影响的款的依据。 */
static int sp_dyn_word(uint32_t w) {
  if ((w & 31) != 31) return 0;
  int n = (w >> 5) & 31;
  if ((w & 0xff800000u) == 0x91000000u || (w & 0xff800000u) == 0xd1000000u) return n != 31 && n != 29;   /* add / sub 立即数写 sp，Rn 不是 sp、也不是帧指针（从 x29 恢复是收尾） */
  if ((w & 0xffe00000u) == 0x8b200000u || (w & 0xffe00000u) == 0xcb200000u) return 1;   /* add / sub 扩展寄存器写 sp（含 sub sp, sp, xN） */
  return 0;
}
/* a 处是「从帧指针恢复 sp（mov / add / sub sp, x29, #k）之后不是马上返回」：跳过随后的出栈（ldp …, [sp], #k / ldr …, [sp], #k / add sp, sp, #k）后
 *   下一条不是 ret / 尾调用 b / br，说明恢复 sp 之后代码还在走，开出来的数组此时在 sp 以下 */
static int sp_restore_mid(A a, Pair f) {
  uint32_t w = u32(g->orig + a);
  if (!((w & 31) == 31 && ((w >> 5) & 31) == 29 && ((w & 0xff800000u) == 0x91000000u || (w & 0xff800000u) == 0xd1000000u))) return 0;
  A b = a + 4;
  for (int k = 0; k < 12 && b + 4 <= f.b; k++, b += 4) {
    uint32_t v = u32(g->orig + b);
    if ((v & 0xff8003ffu) == 0x910003ffu) continue;   /* add sp, sp, #k */
    Ins y;
    if (decode(v, b, &y) && (pre(y.m, "ldp") || pre(y.m, "ldr") || pre(y.m, "ldur")) && strstr(operand_text(&y), "[sp")) continue;   /* 从 sp 出栈 */
    break;
  }
  uint32_t v = b + 4 <= (A)g->text ? u32(g->orig + b) : 0;
  return !((v & 0xfffffc1fu) == 0xd65f0000u || v == 0xd65f0bffu || v == 0xd65f0fffu || (v & 0xfc000000u) == 0x14000000u ||
           (v & 0xfffffc1fu) == 0xd61f0000u);   /* ret / retaa / retab / 尾调用 b / 经寄存器尾调用 br */
}
static Pair func_of(A at);
static int sp_dynamic(A at) {   /* 按函数起点缓存在 g->spd_*（开放寻址，值 1 / 2 = 否 / 是，0 = 空槽） */
  Pair f = func_of(at);
  if (g->spd_n * 2 >= g->spd_cap) {
    size_t oc = g->spd_cap; A* ok = g->spd_key; int8_t* ov = g->spd_val;
    g->spd_cap = oc ? oc * 2 : 4096;
    g->spd_key = zalloc(g->spd_cap * sizeof(A)); g->spd_val = zalloc(g->spd_cap); g->spd_n = 0;
    for (size_t i = 0; i < oc; i++)
      if (ov[i]) {
        size_t h = ((uint64_t)ok[i] * 0x9E3779B97F4A7C15ull >> 20) & (g->spd_cap - 1);
        while (g->spd_val[h]) h = (h + 1) & (g->spd_cap - 1);
        g->spd_key[h] = ok[i], g->spd_val[h] = ov[i], g->spd_n++;
      }
    if (ok) release(ok), release(ov);
  }
  size_t h = ((uint64_t)f.a * 0x9E3779B97F4A7C15ull >> 20) & (g->spd_cap - 1);
  while (g->spd_val[h]) {
    if (g->spd_key[h] == f.a) return g->spd_val[h] - 1;
    h = (h + 1) & (g->spd_cap - 1);
  }
  /* 危险 = 动态往下开过栈，且有一次从帧指针恢复 sp（mov / add / sub sp, x29, #k）之后不是马上返回：
   *   跳过随后的出栈（ldp …, [sp], #k / ldr …, [sp], #k / add sp, sp, #k）后下一条不是 ret / 尾调用 b，说明恢复 sp 之后代码还在走，
   *   开出来的数组此时在 sp 以下（一款第一方动作游戏：mov sp, x29; ldp x29, x30, [sp], #16; b.lt …）。普通变长数组在 sp 压低时用、收尾才恢复，不算 */
  int dyn = 0, mid = 0;
  for (A a = f.a; a + 4 <= f.b && a >= 0 && (uint64_t)a + 4 <= g->text; a += 4) {
    if (sp_dyn_word(u32(g->orig + a))) dyn = 1;
    if (sp_restore_mid(a, f)) mid = 1;
  }
  dyn = dyn && mid;
  g->spd_key[h] = f.a, g->spd_val[h] = (int8_t)(dyn + 1), g->spd_n++;
  return dyn;
}

/* 改写点 at 会不会撞上 sp 以下的活数据（#704）：只有从「恢复 sp 后还在走」的那几处（sp_restore_mid）沿控制流往后走得到的点才会——
 *   恢复点之前的点（sp 还压在数组下面，数组在 sp 以上）照旧压栈不碰任何活数据。沿原映像走：顺序 / 直接跳转 / 条件跳转两个去向 / 过调用接着走（保守），
 *   ret 与出函数（尾调用）停；遇 br / svc / 解不出（LV_STOP）或走满预算一律当危险（宁可不压栈）。sp_dynamic 为假的函数直接不危险 */
static int sp_danger(A at) {
  if (!sp_dynamic(at)) return 0;
  Pair f = func_of(at);
  size_t n = (size_t)(f.b - f.a) / 4;
  if (!n || at < f.a || at >= f.b) return 1;
  uint8_t* seen = zalloc(n);
  A* st = zalloc((2 * n + 4) * sizeof(A));   /* 每弹一条最多压两条，压过 2n 即当危险 */
  size_t ns = 0;
  int hit = 0;
  for (A a = f.a; a + 4 <= f.b && (uint64_t)a + 4 <= g->text; a += 4)
    if (sp_restore_mid(a, f)) st[ns++] = a + 4;
  while (ns && !hit) {
    A p = st[--ns];
    if (p < f.a || p >= f.b) continue;   /* 出函数：尾调用 / 落到别处，sp 状态归对方 */
    size_t i = (size_t)(p - f.a) / 4;
    if (seen[i]) continue;
    seen[i] = 1;
    if (p == at) { hit = 1; break; }
    const LvI* e = lv_get(p);
    if (e->k == LV_STOP) { hit = 1; break; }
    if (e->k == LV_RET) continue;
    if (e->k == LV_B) { st[ns++] = e->t; continue; }
    if (e->k == LV_COND) st[ns++] = e->t;
    st[ns++] = p + 4;   /* 顺序 / 条件跳转不跳 / 调用返回后 */
    if (ns > 2 * n) { hit = 1; break; }
  }
  release(seen), release(st);
  return hit;
}/* 改写点 x 之后可当临时的寄存器（#704 放宽）：通用 x0–x17、x19–x28、x30（不在本指令里），向量 v0–v31。
 *   x30 在函数中段多半已存进帧、或下一个 bl 就会覆盖（lv_live 把调用当作写 x30）；x19–x28 / v8–v15 过调用、返回都当活，只有先被整写才算死。
 *   挑的先后：x9–x17、x2–x8（与旧版同序，旧版挑得出的点产物不变），再 x0–x1、x19–x28、x30 */
static const int GP_ORDER[] = {9, 10, 11, 12, 13, 14, 15, 16, 17, 2, 3, 4, 5, 6, 7, 8, 0, 1, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30};
static Mask gp_cand(const Ins* x) {
  Mask used = x->rd | x->wr;
  for (int r = 0; r < 31; r++) if (x->regs & BIT(r)) used |= BIT(r);
  return (lv_range(0, 17, 0) | lv_range(19, 28, 0) | BIT(30) | lv_range(0, 31, 33)) & ~used;
}
static void gp_two(Mask dead, int* s, int* t) {
  *s = *t = -1;
  for (size_t i = 0; i < sizeof GP_ORDER / sizeof *GP_ORDER && *t < 0; i++)
    if (dead & BIT(GP_ORDER[i])) { if (*s < 0) *s = GP_ORDER[i]; else *t = GP_ORDER[i]; }
}
static int vec_one(Mask dead) {
  for (int n = 31; n >= 0; n--) if (dead & VB(n)) return n;
  return -1;
}
/* cand 里在 a1（与 a2，若 ≥ 0）之后都已死的：条件跳转两个去向都要死 */
static Mask dead_after(A a1, A a2, Mask cand, int budget) {
  Mask live = lv_live(a1, cand, budget);
  if (a2 >= 0) live |= lv_live(a2, cand & ~live, budget);
  return cand & ~live;
}
/* 两个在 a1（与 a2）之后都已死的通用寄存器 → 1；否则一个都已死的向量寄存器（暂存两个通用临时）→ 2，*v 给出；都没有 → 0。
 *   先按旧候选（x2–x17、v16–v31）挑：旧版挑得出的点结果不变（候选多了活跃分析走得更久，可能撞预算反而挑不出）；挑不出再放宽 */
static int pick_dead_gp2(const Ins* x, A a1, A a2, int budget, int* s, int* t, int* v) {
  Mask all = gp_cand(x), old = all & (lv_range(2, 17, 0) | lv_range(16, 31, 33));
  for (int pass = 0; pass < 2; pass++) {
    Mask dead = dead_after(a1, a2, pass ? all : old, budget);
    gp_two(dead, s, t);
    *v = -1;
    if (*t >= 0) return 1;
    if ((*v = vec_one(dead)) >= 0) return 2;
  }
  return 0;
}
static int pick_dead_any(const Ins* x, int* s, int* t, int* v, int budget) {
  return pick_dead_gp2(x, x->at + 4, -1, budget, s, t, v);
}
static uint32_t subst(const Ins* x, int s) {
  char want[160] = {0};
  size_t j = 0;
  for (size_t i = 0; operand_text(x)[i] && j + 5 < sizeof(want);) {
    if ((operand_text(x)[i] == 'x' || operand_text(x)[i] == 'w') && operand_text(x)[i + 1] == '1' && operand_text(x)[i + 2] == '8' &&
        word_bounds(operand_text(x), operand_text(x) + i, 3)) {
      j += snprintf(want + j, sizeof(want) - j, "%c%d", operand_text(x)[i], s);
      i += 3;
    } else
      want[j++] = operand_text(x)[i++];
  }
  int pos[4], n = 0;
  for (int p = 0; p <= 16; p += (p == 10 ? 6 : 5))
    if (((x->w >> p) & 31) == 18)
      pos[n++] = p;
  /* itertools.combinations orders by positions, largest cardinality first. */
  for (int k = n; k > 0; k--)
    for (int mask = 1; mask < (1 << n); mask++) {
      if (__builtin_popcount((unsigned)mask) != k)
        continue;
      uint32_t w = x->w;
      for (int i = 0; i < n; i++)
        if (mask & (1 << i))
          w = (w & ~(31u << pos[i])) | ((uint32_t)s << pos[i]);
      Ins d;
      if (decode(w, x->at, &d) && eq(d.m, x->m) && eq(operand_text(&d), want))
        return w;
    }
  fail("subst fail %" PRIx64 " %s %s", (uint64_t)x->at, x->m, operand_text(x));
  return 0;
}
static Site* site_at(A at) {
  size_t l = 0, r = g->sites.n;
  while (l < r) {
    size_t m = (l + r) / 2;
    if (g->sites.v[m].at < at)
      l = m + 1;
    else
      r = m;
  }
  return l < g->sites.n && g->sites.v[l].at == at ? g->sites.v + l : NULL;
}
static void done(A at) {
  if (at >= 0 && at < (A)g->text && !(at & 3)) {
    if (!g->consumed_map)
      g->consumed_map = zalloc((size_t)g->text / 32 + 1);
    g->consumed_map[(size_t)at / 32] |= (uint8_t)(1 << ((size_t)at / 4 % 8));
  } else
    PUSH(g->consumed_far, at);
  Site* s = site_at(at);
  if (s)
    s->done = 1;
}
static int consumed(A at) {
  if (at >= 0 && at < (A)g->text && !(at & 3))
    return g->consumed_map && (g->consumed_map[(size_t)at / 32] >> ((size_t)at / 4 % 8)) & 1;
  return contains(&g->consumed_far, at);
}
static void gatecall(void) {
  tp(30, 29);
  slot(30, 29, 3);
  emit(LDR(30, 30, 0));
  emit(LDR(29, 31, 0));
}
static void gate(const Ins* x, const char* k, int arg) {
  emit(STPRE(29, 30, 31, -16));
  gatecall();
  emit(BLR(30));
  Gate q = {here(), x->at, k, arg};
  PUSH(g->gates, q);
  emit(LDPOST(29, 30, 31, 16));
  emit(branch(here(), x->at + 4));
}
static int spdelta(const Ins* x) {
  if (!x->sp)
    return 0;
  const char* p = find_word(operand_text(x), "sp");
  if (p && p > operand_text(x) && p[-1] == '[' && detail(x)->writeback) {
    cs_arm64_op* m = NULL;
    for (int i = 0; i < detail(x)->op_count; i++)
      if (detail(x)->operands[i].type == ARM64_OP_MEM)
        m = (cs_arm64_op*)&detail(x)->operands[i];
    REQUIRE(m);
    if (strstr(p, "]!"))
      return (int)m->mem.disp;
    if (strstr(p, "], #"))
      return (int)detail(x)->operands[detail(x)->op_count - 1].imm;
  }
  REQUIRE(!pre(operand_text(x), "sp,") && !pre(operand_text(x), "wsp,"));
  return 0;
}
static int spframe(const Ins* x, uint32_t w, int dlt, int* F, uint32_t words[2], int* count) {
  *F = 16;
  *count = 1;
  words[0] = w;
  if (!x->sp)
    return 1;
  int rn = (w >> 5) & 31;
  if (((w >> 27) & 7) == 5 && !((w >> 26) & 1) && rn == 31) {
    int opc = w >> 30, mode = (w >> 23) & 7, L = (w >> 22) & 1;
    if (opc == 3 || (opc == 1 && !L))
      return 0;
    int sc = opc == 2 ? 8 : 4, im = (((w >> 15) & 127) ^ 64) - 64, a = 0;
    if (mode == 2) {
      a = im * sc;
      if (a < 0)
        return 0;
    } else if (mode == 1 || mode == 3) {
      a = mode == 3 ? dlt : 0;
      while (a < 16 - *F)
        *F += 16;
    } else
      return 0;
    int off = a + *F;
    if (off % sc || (*F + dlt) % 8 || *F + dlt < -512 || *F + dlt > 504)
      return 0;
    if (mode == 2 && off / sc > 63) {
      int size = opc == 2 ? 3 : 2, op = L ? (opc == 1 ? 2 : 1) : 0;
      for (int k = 0; k < 2; k++) {
        int rt = k ? ((w >> 10) & 31) : (w & 31);
        words[k] = 0x39000000 | ((uint32_t)size << 30) | (op << 22) |
                   (((off + k * sc) / sc) << 10) | (31 << 5) | rt;
        Ins d = dis(words[k], x->at);
        if (!pre(d.m, "ldr") && !pre(d.m, "str"))
          return 0;
      }
      *count = 2;
      return 1;
    }
    if (off / sc < -64 || off / sc > 63)
      return 0;
    words[0] = (w & ~(127u << 15) & ~(7u << 23)) | (((off / sc) & 127) << 15) | (2 << 23);
    return 1;
  }
  if (((w >> 27) & 7) == 7 && !((w >> 26) & 1) && rn == 31) {
    int size = w >> 30, sc = 1 << size;
    if (dlt) {
      /* 单寄存器 sp 写回（[sp,#d]! / [sp],#d）：访存部分平移成无写回 LDUR/STUR（前索引 a=d、
       * 后索引 a=0），sp 自身增量由块尾 LDPOST(F+d) 一并回放——同上面 pair 写回的口径 */
      int mode = (w >> 10) & 3;
      if (((w >> 24) & 3) != 0 || ((w >> 21) & 1) || (mode != 1 && mode != 3))
        return 0;
      int a = mode == 3 ? dlt : 0;
      while (a < 16 - *F)
        *F += 16;
      int off = a + *F;
      if (off < 16 || off > 255 || (*F + dlt) % 8 || *F + dlt < -512 || *F + dlt > 504)
        return 0;
      words[0] = (w & ~(3u << 10) & ~(511u << 12)) | ((uint32_t)(off & 511) << 12);
      Ins d = dis(words[0], x->at);
      if (!pre(d.m, "ldur") && !pre(d.m, "stur"))
        return 0;
      return 1;
    }
    if (((w >> 24) & 3) == 1) {
      if (size == 3 && ((w >> 22) & 3) == 2)
        return 0;
      int off = ((w >> 10) & 4095) * sc + *F;
      if (off / sc > 4095)
        return 0;
      words[0] = (w & ~(4095u << 10)) | ((off / sc) << 10);
      return 1;
    }
    if (((w >> 24) & 3) == 0 && !((w >> 21) & 1) && ((w >> 10) & 3) == 0) {
      /* 无缩放有符号偏移：负偏移（sp 下方访存）同样靠抬 F 让重编码后落在暂存帧之上 */
      int a = (((w >> 12) & 511) ^ 256) - 256;
      while (a < 16 - *F)
        *F += 16;
      int off = a + *F;
      if (off > 255 || *F > 504)
        return 0;
      words[0] = (w & ~(511u << 12)) | ((off & 511) << 12);
      return 1;
    }
    return 0;
  }
  /* add/sub xd, sp, #imm：add 补 +F、sub 补 -F；补不进原编码（移位立即数 / 越程）就原样算完再补 F */
  if ((w & 0xbf800000) == 0x91000000 && rn == 31 && (w & 31) != 31) {
    int sub = (w >> 30) & 1, off = ((w >> 10) & 4095) + (sub ? -*F : *F);
    if ((w >> 22) & 1 || off < 0 || off > 4095) {
      /* 立即数加上保存区放不下（Hades II 的 EOS NRO 0x2d89c0：add x18,sp,#0xffc）：原样算完再补 F */
      words[1] = ADDI(w & 31, w & 31, *F, 0);
      *count = 2;
      return 1;
    }
    words[0] = (w & ~(4095u << 10)) | ((uint32_t)off << 10);
    return 1;
  }
  return 0;
}
#define FMOV_DX(d, x) (0x9e670000u | ((x) << 5) | (d))      /* fmov dD, xN */
#define FMOV_XD(x, d) (0x9e660000u | ((d) << 5) | (x))      /* fmov xD, dN */
#define INS_D1(v, x) (0x4e181c00u | ((x) << 5) | (v))       /* mov vD.d[1], xN */
#define UMOV_D1(x, v) (0x4e183c00u | ((v) << 5) | (x))      /* mov xD, vN.d[1] */
/* 苹果路径 x18 普通点、危险函数里：不写游戏 sp 以下（见 lv_live）。成功返回 1；挑不出临时返回 0，调用方记缺口报红 */
static int plain_nosp(const Ins* x) {
  int P, Q, V, k = pick_dead_any(x, &P, &Q, &V, LV_BUDGET);
  if (k == 1) {   /* 两个已死的通用寄存器：P 当虚拟 x18、Q 放线程槽地址，用完不恢复 */
    uint32_t w = subst(x, P);
    tp(Q, P);
    slot(Q, P, 0);
    emit(LDR(P, Q, 0));
    emit(w);
    emit(STR(P, Q, 0));
    emit(branch(here(), x->at + 4));
    bump("x18_dead");
    return 1;
  }
  if (k == 2) {   /* 一个已死的向量寄存器：暂存两个通用临时，用完取回 */
    int S, T;
    pick(x->regs, &S, &T);
    uint32_t w = subst(x, S);
    emit(FMOV_DX(V, S));
    emit(INS_D1(V, T));
    tp(T, S);
    slot(T, S, 0);
    emit(LDR(S, T, 0));
    emit(w);
    emit(STR(S, T, 0));
    emit(FMOV_XD(S, V));
    emit(UMOV_D1(T, V));
    emit(branch(here(), x->at + 4));
    bump("x18_deadv");
    return 1;
  }
  return 0;
}
static void plain(const Ins* x) {
  /* 只在「恢复 sp 后还用 sp 以下数据」的函数里改走死寄存器（sp_dynamic）：旧写法在这些点会盖游戏数据（受影响的款 = x18_spdyn > 0），
   *   挑不出就退回旧写法、记兼容写法（x18_compat）。普通函数按 AAPCS64 sp 以下没有活数据，照旧写法——没受影响的款改写产物与旧改写器逐字节相同，改写速度不变 */
  if (!noredzone() && sp_dynamic(x->at))
    bump("x18_spdyn");
  if (!noredzone() && sp_danger(x->at)) {   /* #704：只有恢复 sp 后走得到的点才危险，恢复点之前的点照旧写法 */
    bump("x18_spdanger");
    if (plain_nosp(x))
      return;
    /* 挑不出已死的临时（v0.3.1 拿不准不停）：这一处退回旧写法（压栈），记兼容写法；只有该点恰在恢复 sp 后、sp 以下有活数据时才会踩数据 */
    bump("x18_compat");
  }
  int S, T;
  pick(x->regs, &S, &T);
  int d = spdelta(x), F, n;
  uint32_t w = subst(x, S), words[2];
  if (noredzone() && spframe(x, w, d, &F, words, &n)) {
    emit(STPRE(S, T, 31, -F));
    tp(T, S);
    slot(T, S, 0);
    emit(LDR(S, T, 0));
    for (int i = 0; i < n; i++)
      emit(words[i]);
    emit(STR(S, T, 0));
    emit(LDPOST(S, T, 31, F + d));
    emit(branch(here(), x->at + 4));
    return;
  }
  /* 安卓/鸿蒙不产 below-sp 包：sp 改写点平移不了就 fail → 记缺口（make_pack 的红比废包强） */
  if (noredzone())
    fail("RuntimeError: %" PRIx64 " %s %s：x18 改写点 sp 形态不可平移",
         (uint64_t)x->at, x->m, operand_text(x));
  /* 保留苹果路径的 sp 写回准入边界。 */
  REQUIRE(d >= -96 && d <= 400 && d % 8 == 0);
  /* 帧顶留出原 sp 下方的 128 字节。访存或运算读 sp 时，借 T 提供原 sp，
   * 把 K18 槽地址放在帧内第三个槽，原指令的立即数和索引方式都保留。 */
  F = 128 + (x->sp ? 32 : 16);
  if (x->sp) {
    REQUIRE(!detail(x)->post_index || detail(x)->operands[detail(x)->op_count - 1].type == ARM64_OP_IMM);
    REQUIRE(((w >> 5) & 31) == 31);
    w = (w & ~(31u << 5)) | ((uint32_t)T << 5);
    REQUIRE(!dis(w, x->at).sp);
  }
  emit(STPRE(S, T, 31, -F));
  tp(T, S);
  slot(T, S, 0);
  emit(LDR(S, T, 0));
  if (x->sp) {
    emit(STR(T, 31, 2));
    emit(ADDI(T, 31, F, 0));
  }
  emit(w);
  if (x->sp)
    emit(LDR(T, 31, 2));
  emit(STR(S, T, 0));
  if (F + d <= 504)
    emit(LDPOST(S, T, 31, F + d));
  else {
    /* 帧长加原写回超过 LDP 的 imm7 射程时，分开恢复寄存器和 sp。 */
    emit(LDP(S, T, 31, 0));
    emit(ADDI(31, 31, F + d, 0));
  }
  emit(branch(here(), x->at + 4));
}
static void spfrom18(const Ins* x) {
  int S, T;
  pick(x->regs, &S, &T);
  if (noredzone()) {
    emit(SUBI(31, 31, 128, 0));
    emit(STP(S, T, 31, 0));
  } else
    emit(STP(S, T, 31, -16));
  tp(T, S);
  slot(T, S, 0);
  emit(LDR(S, T, 0));
  emit(ADDI(T, 31, noredzone() ? 128 : 0, 0));
  emit(subst(x, S));
  emit(LDP(S, T, T, noredzone() ? -128 : -16));
  emit(branch(here(), x->at + 4));
}
static void cond(const Ins* x) {
  int S, T, V, k = !noredzone() && sp_danger(x->at) ? pick_dead_gp2(x, x->at + 4, target(x), LV_BUDGET, &S, &T, &V) : 0;
  if (k == 2) {   /* 两个去向之后都已死的向量寄存器：暂存两个通用临时，两个出口各自取回（#704） */
    pick(x->regs, &S, &T);
    emit(FMOV_DX(V, S));
    emit(INS_D1(V, T));
    tp(T, S);
    slot(T, S, 0);
    emit(LDR(S, T, 0));
    A taken = here() + 16;
    emit(in(x->m, "cbz|cbnz") ? ((x->w & 0xff000000) | (4 << 5) | S) : ((x->w & 0xfff80000) | (4 << 5) | S));
    emit(FMOV_XD(S, V));
    emit(UMOV_D1(T, V));
    emit(branch(here(), x->at + 4));
    REQUIRE(here() == taken);
    emit(FMOV_XD(S, V));
    emit(UMOV_D1(T, V));
    emit(branch(here(), target(x)));
    bump("x18_deadv_cond");
    return;
  }
  if (k == 1) {
    /* 两个去向之后都已死的临时：不压 sp 以下（一款第一方动作游戏 同根：危险函数里压栈会盖游戏数据） */
    tp(T, S);
    slot(T, S, 0);
    emit(LDR(S, T, 0));
    uint32_t w = in(x->m, "cbz|cbnz") ? ((x->w & 0xff000000) | (2 << 5) | S)
                                      : ((x->w & 0xfff80000) | (2 << 5) | S);
    emit(w);
    emit(branch(here(), x->at + 4));
    emit(branch(here(), target(x)));
    bump("x18_dead_cond");
    return;
  }
  pick(x->regs, &S, &T);
  stash(S, T, noredzone());
  tp(T, S);
  slot(T, S, 0);
  emit(LDR(S, T, 0));
  A taken = here() + 12;
  uint32_t w = in(x->m, "cbz|cbnz") ? ((x->w & 0xff000000) | (3 << 5) | S)
                                    : ((x->w & 0xfff80000) | (3 << 5) | S);
  emit(w);
  unstash(S, T, noredzone());
  emit(branch(here(), x->at + 4));
  REQUIRE(here() == taken);
  unstash(S, T, noredzone());
  emit(branch(here(), target(x)));
}
static void pcrel(const Ins* x) {
  int P, Q, V, k = !noredzone() && sp_danger(x->at) ? pick_dead_gp2(x, x->at + 4, -1, LV_BUDGET, &P, &Q, &V) : 0;
  if (k == 2) {   /* 已死的向量寄存器暂存两个通用临时（#704） */
    pick(x->regs, &P, &Q);
    emit(FMOV_DX(V, P));
    emit(INS_D1(V, Q));
    tp(Q, P);
    slot(Q, P, 0);
    A t = detail(x)->operands[1].imm;
    emit(adrp(P, here(), t));
    if (eq(x->m, "adr"))
      emit(ADDI(P, P, t & 4095, 0));
    emit(STR(P, Q, 0));
    emit(FMOV_XD(P, V));
    emit(UMOV_D1(Q, V));
    emit(branch(here(), x->at + 4));
    bump("x18_deadv_pcrel");
    return;
  }
  if (k == 1) {
    tp(Q, P);
    slot(Q, P, 0);
    A t = detail(x)->operands[1].imm;
    emit(adrp(P, here(), t));
    if (eq(x->m, "adr"))
      emit(ADDI(P, P, t & 4095, 0));
    emit(STR(P, Q, 0));
    emit(branch(here(), x->at + 4));
    bump("x18_dead_pcrel");
    return;
  }
  stash(0, 1, noredzone());
  tp(1, 0);
  slot(1, 0, 0);
  A t = detail(x)->operands[1].imm;
  emit(adrp(0, here(), t));
  if (eq(x->m, "adr"))
    emit(ADDI(0, 0, t & 4095, 0));
  emit(STR(0, 1, 0));
  unstash(0, 1, noredzone());
  emit(branch(here(), x->at + 4));
}
static void dynbr(const Ins* x, int link) {
  tp(16, 17);
  slot(16, 17, 0);
  emit(LDR(16, 16, 0));
  if (link) {
    A ret = x->at + 4;
    emit(adrp(30, here(), ret));
    emit(ADDI(30, 30, ret & 4095, 0));
  }
  emit(BR(16));
}
static void brcompact(const Jump* j) {
  A st = here();
  if (noredzone())
    emit(STPRE(16, 17, 31, -16));
  else {
    emit(STUR(16, 31, -16));
    emit(STUR(17, 31, -24));
  }
  tp(16, 17);
  slot(16, 17, 0);
  emit(LDR(16, 16, 0));
  emit(noredzone() ? LDR(17, 31, 1) : LDUR(17, 31, -24));
  /* bias 是下标 0 对应的表项。缺省 0：垫片仍是 base+4*i，与打开符号扩展之前逐字节相同。 */
  A origin = j->base + 4LL * j->bias;
  A pad = st + 96, delta = pad - origin, dl = delta < 0 ? -delta : delta, hi = dl >> 12,
    lo = dl & 4095;
  int n = 0;
  while (hi) {
    int h = MIN(hi, 4095);
    emit(delta >= 0 ? ADDI(16, 16, h, 1) : SUBI(16, 16, h, 1));
    hi -= h;
    n++;
  }
  if (lo) {
    emit(delta >= 0 ? ADDI(16, 16, lo, 0) : SUBI(16, 16, lo, 0));
    n++;
  }
  REQUIRE(n <= 12);
  emit(BR(16));
  while (here() < pad)
    emit(NOP);
  REQUIRE(here() == pad);
  A tails = pad + 4LL * j->count;
  for (int i = 0; i < j->count; i++)
    emit(branch(here(), tails + 8LL * i));
  for (int i = 0; i < j->count; i++) {
    emit(noredzone() ? LDRPOST(16, 31, 16) : LDUR(16, 31, -16));
    emit(branch(here(), j->base + 4LL * j->bias + 4LL * i));
  }
}
static void brtab(Jump* j) {
  sort(&j->targets);
  if (noredzone())
    emit(STPRE(16, 17, 31, -16));
  else {
    emit(STUR(16, 31, -16));
    emit(STUR(17, 31, -24));
  }
  tp(16, 17);
  slot(16, 17, 0);
  emit(LDR(16, 16, 0));
  A pads = here() + 4 * (4 * j->targets.n + 1);
  int stride = noredzone() ? 8 : 12;
  for (size_t k = 0; k < j->targets.n; k++) {
    A t = j->targets.v[k];
    emit(adrp(17, here(), t));
    emit(ADDI(17, 17, t & 4095, 0));
    emit(0xca000000 | (16 << 16) | (17 << 5) | 17);
    A off = pads + stride * k - here();
    REQUIRE(off >= -(1 << 20) && off < (1 << 20));
    emit(0xb4000000 | (((off >> 2) & 0x7ffff) << 5) | 17);
  }
  emit(0xd4200300);
  REQUIRE(here() == pads);
  for (size_t k = 0; k < j->targets.n; k++) {
    if (noredzone())
      emit(LDPOST(16, 17, 31, 16));
    else {
      emit(LDUR(16, 31, -16));
      emit(LDUR(17, 31, -24));
    }
    emit(branch(here(), j->targets.v[k]));
  }
}
static int sp_rebase(uint32_t w, int delta, uint32_t* o, int* off);
static void brrel(const Jump* j) {
  int general = j->type == 3, I = general ? j->I : 18, T = j->T, tmp1 = 16, tmp2 = 17;
  /* 表基址 / 索引 / 表项 / 基址拷贝用到 x16/x17 时不能借这两个：从 x9–x15 挑两个本跳转表没用到的（先存后恢复，不要求它们空闲） */
  if (j->uses_x16x17) {
    int got = 0;
    for (int r = 9; r <= 15 && got < 2; r++)
      if (r != j->B && r != I && r != T && r != j->cd) {
        if (got++ == 0) tmp1 = r; else tmp2 = r;
      }
  }

  if (general) {
    if (noredzone()) {
      emit(SUBI(31, 31, 32, 0));
      emit(STR(tmp1, 31, 0));
      emit(STR(tmp2, 31, 1));
    } else {
      emit(STUR(tmp1, 31, -16));
      emit(STUR(tmp2, 31, -24));
    }
    if (I == 18) {
      tp(tmp1, tmp2);
      slot(tmp1, tmp2, 0);
      emit(LDR(tmp2, tmp1, 0));
    } else
      emit(0xaa0003e0 | (I << 16) | tmp2);
    emit(noredzone() ? STR(tmp2, 31, 2) : STUR(tmp2, 31, -32));
    emit(noredzone() ? LDR(tmp1, 31, 0) : LDUR(tmp1, 31, -16));
    emit(noredzone() ? LDR(tmp2, 31, 1) : LDUR(tmp2, 31, -24));
    for (size_t k = 0; k < j->mids.n; k++) {
      uint32_t w = j->mids.v[k].w, r;
      int off;
      if ((w & 0x1f000000u) == 0x10000000u) {   /* adr / adrp（#716：取表与 br 之间夹着 adrp x0, …）：与位置有关，按原目标在补丁区重算；adr 换成 adrp + add */
        int d = w & 31;
        int64_t im = (int64_t)((((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3));
        if (im & (1 << 20))
          im -= 1 << 21;   /* 21 位有符号 */
        A at = j->mids.v[k].at, t = (w >> 31) ? (at & ~4095LL) + im * 4096 : at + im;
        emit(adrp(d, here(), t));
        if (!(w >> 31))
          emit(ADDI(d, d, t & 4095, 0));
        continue;
      }
      emit(noredzone() && j->mids.v[k].sp && sp_rebase(w, 32, &r, &off) ? r : w);   /* 安卓 / 鸿蒙块已 sub sp,#32：sp 访存偏移补回（general 里 sp_mid_ok 已核过编得出） */
    }
    emit(noredzone() ? STR(tmp1, 31, 0) : STUR(tmp1, 31, -16));
    emit(noredzone() ? STR(tmp2, 31, 1) : STUR(tmp2, 31, -24));
    emit(noredzone() ? LDR(tmp2, 31, 2) : LDUR(tmp2, 31, -32));
  } else {
    REQUIRE(j->B != 16 && j->B != 17 && j->B != 18);
    if (noredzone())
      emit(STPRE(tmp1, tmp2, 31, -16));
    else {
      emit(STUR(tmp1, 31, -16));
      emit(STUR(tmp2, 31, -24));
    }
    tp(tmp1, tmp2);
    slot(tmp1, tmp2, 0);
    emit(LDR(tmp2, tmp1, 0));
  }
  A pad = here() + 16;
  emit(adrp(tmp1, here(), pad));
  emit(ADDI(tmp1, tmp1, pad & 4095, 0));
  /* OHOS tp() needs extra words, so a general entry does not fit in 64 bytes. */
  int stride = g->ohos ? 7 : 6;
  emit(0x8b000000 | (tmp2 << 16) | ((unsigned)stride << 10) | (tmp1 << 5) | tmp1);
  emit(BR(tmp1));
  REQUIRE(here() == pad);
  for (int i = 0; i < j->count; i++) {
    int32_t e = si(j->tbl + 4LL * i);
    A t = j->tbl + e, p0 = here();
    tp(tmp1, tmp2);
    slot(tmp1, tmp2, 0);
    emit(adrp(tmp2, here(), t));
    emit(ADDI(tmp2, tmp2, t & 4095, 0));
    emit(STR(tmp2, tmp1, 0));
    if (general && j->setT) {
      uint64_t v = (uint64_t)(int64_t)e;
      emit(MOVZ(T, v & 65535, 0));
      for (int h = 1; h < 4; h++)
        emit(MOVK(T, (v >> (16 * h)) & 65535, h));
    }
    if (noredzone())
      emit(LDPOST(tmp1, tmp2, 31, general ? 32 : 16));
    else {
      emit(LDUR(tmp1, 31, -16));
      emit(LDUR(tmp2, 31, -24));
    }
    emit(branch(here(), t));
    REQUIRE(here() <= p0 + (1 << stride));
    while (here() < p0 + (1 << stride))
      emit(NOP);
  }
}
static int excl_ld(const Ins* x) {
  return in(x->m, "ldxr|ldaxr|ldxp|ldaxp|ldxrb|ldaxrb|ldxrh|ldaxrh");
}
static int excl_st(const Ins* x) {
  return in(x->m, "stxr|stlxr|stxp|stlxp|stxrb|stlxrb|stxrh|stlxrh");
}
static int conditional(const Ins* x) {
  return pre(x->m, "b.") || in(x->m, "cbz|cbnz|tbz|tbnz");
}
static Segment segment(const IV* l, int lo, int hi) {
  Segment s = {0};
  for (int i = lo; i <= hi; i++)
    PUSH(s.ins, l->v[i]);
  return s;
}
static WV find_windows(const IV* l) {
  WV out = {0};
  int *heads = zalloc(l->n * sizeof(int)), *covered = zalloc(l->n * sizeof(int));
  for (size_t i = 0; i < l->n; i++)
    heads[i] = -1;
  for (size_t i = 0; i < l->n; i++)
    if (excl_ld(l->v + i))
      for (size_t j = i + 1; j < MIN(i + 8, l->n); j++) {
        Ins* x = l->v + j;
        if (excl_st(x) || excl_ld(x) || pre(x->m, "st") || in(x->m, "b|bl|br|blr|ret"))
          break;
        if (conditional(x)) {
          A t = target(x);
          for (size_t k = 0; k < l->n; k++)
            if (l->v[k].at == t && excl_st(l->v + k) && t < l->v[i].at)
              heads[i] = (int)j;
          break;
        }
      }
  for (size_t i = 0; i < l->n; i++)
    if (excl_ld(l->v + i) && heads[i] < 0 && !covered[i]) {
      // 到配对的独占存之前遇到无条件跳转 / 返回：这个独占取不是一个 LL/SC 循环的起点（编译器把别处的「ldaxr；cbz；b」放在了
      //   两个循环之间），不成窗口，否则窗口跨过 b 吞下后面真循环的入口（11-02 普查 01002B00111A2000 main 0x104922c、010089C00DA6A000 0x86cb7c：
      //   窗口里有 b 断言失败 + 三处「branch into window」，整个模块退出码 3）。途中的另一个独占取不能当停点：怪猎 main 0x5058268
      //   「ldaxr；cmp；b.eq → 后面的 stlxr」中间夹着重试循环自己的 ldaxr，整段本来就是一个窗口（九款金样）
      size_t j = i;
      while (j < l->n && !excl_st(l->v + j) && (j == i || !in(l->v[j].m, "b|bl|br|blr|ret")))
        j++;
      if (j >= l->n || !excl_st(l->v + j) || j - i >= 16)
        continue;
      if (j + 1 < l->n && in(l->v[j + 1].m, "cbz|cbnz"))
        j++;
      Window w = {0};
      Segment s = segment(l, i, j);
      PUSH(w.seg, s);
      PUSH(out, w);
      for (size_t k = i; k <= j; k++)
        covered[k] = 1;
    }
  for (size_t i = 0; i < l->n; i++)
    if (heads[i] >= 0) {
      A t = target(l->v + heads[i]);
      for (size_t k = 0; k < out.n; k++) {
        IV* m = &out.v[k].seg.v[0].ins;
        int found = 0;
        for (size_t z = 0; z < m->n; z++)
          if (m->v[z].at == t)
            found = 1;
        if (found) {
          Segment s = segment(l, i, heads[i]);
          PUSH(out.v[k].seg, s);
          break;
        }
      }
    }
  size_t n = 0;
  for (size_t k = 0; k < out.n; k++) {
    int yes = 0;
    for (size_t s = 0; s < out.v[k].seg.n; s++)
      for (size_t i = 0; i < out.v[k].seg.v[s].ins.n; i++)
        yes |= has18(out.v[k].seg.v[s].ins.v + i);
    if (yes)
      out.v[n++] = out.v[k];
  }
  out.n = n;
  release(heads);
  release(covered);
  return out;
}
/* 窗口进 / 出岛的暂存帧：F=0 是苹果口径（sp 下借 16 字节）；F>0 用 STPRE 抬 F 再暂存，
 * 整帧落在 sp 上方（安卓 / 鸿蒙：信号 / redzone 探针会踩 sp 下方，见 redzone.S） */
static void winpro(int S, int T, int F) {
  emit(F ? STPRE(S, T, 31, -F) : STP(S, T, 31, -16));
  tp(T, S);
  slot(T, S, 0);
  emit(LDR(S, T, 0));
}
static void winpost(int S, int T, int F) {
  emit(F ? LDPOST(S, T, 31, F) : LDP(S, T, 31, -16));
}
/* add/sub xd, sp, #imm（xd≠sp、不移位）：抬 F 后 xd = 旧 sp±imm 还能按一个立即数补回；
 * rd==31 的（add/sub/mov 写 sp）一律不认——窗口里 sp 动了，winpost 的 [sp] 就找不回暂存帧 */
static int addsub_sp(uint32_t w) {
  return (w & 0x80000000) && !(w & 0x20000000) && ((w >> 23) & 0x3f) == 0x22 &&
         !((w >> 22) & 1) && (w & 31) != 31 && ((w >> 5) & 31) == 31;
}
/* 抬 sp F 后逐字重编码：sp 相对访存偏移 +F（sp_rebase；重编码后落进暂存帧 [sp,sp+16) 也拒）；
 * add/sub xd,sp,#imm 目标补 F；写回、写 sp、移位立即数、其它含 sp 形态 → 0 */
static int sp_shift(uint32_t w, int F, uint32_t* out) {
  uint32_t o;
  int off;
  if (sp_rebase(w, F, &o, &off)) {
    if (off + F < 16)
      return 0;
    *out = o;
    return 1;
  }
  if (addsub_sp(w)) {
    int imm = (int)((w >> 10) & 4095) + (((w >> 30) & 1) ? -F : F);
    if (imm < 0 || imm > 4095)
      return 0;
    *out = (w & ~(4095u << 10)) | ((uint32_t)imm << 10);
    return 1;
  }
  return 0;
}
/* 窗口抬帧量：每条 sp 指令都可平移 → F（16 的整数倍，足以让重编码后的访存全部落在暂存帧
 * 之上，上限 504=STPRE/LDPOST imm7 射程）；一条不认得 → fail，窗口记缺口，不产 below-sp 包 */
static int win_frame(const Window* w) {
  int minoff = 0;
  for (size_t k = 0; k < w->seg.n; k++)
    for (size_t i = 0; i < w->seg.v[k].ins.n; i++) {
      const Ins* x = w->seg.v[k].ins.v + i;
      if (!x->sp)
        continue;
      uint32_t o;
      int off;
      if (sp_rebase(x->w, 0, &o, &off)) {
        if (off < minoff)
          minoff = off;
      } else if (!addsub_sp(x->w))
        fail("RuntimeError: %" PRIx64 " %s %s：窗口内 sp 形态不可平移",
             (uint64_t)x->at, x->m, operand_text(x));
    }
  int F = minoff < 0 ? ((16 - minoff + 15) / 16) * 16 : 16;
  if (F > 504)
    fail("RuntimeError: 窗口内 sp 访存最深 0x%x，超出抬帧上限 0x1f8", -minoff);
  for (size_t k = 0; k < w->seg.n; k++)
    for (size_t i = 0; i < w->seg.v[k].ins.n; i++) {
      const Ins* x = w->seg.v[k].ins.v + i;
      uint32_t o;
      if (x->sp && !sp_shift(x->w, F, &o))
        fail("RuntimeError: %" PRIx64 " %s %s：窗口内 sp 访存抬 0x%x 编不进",
             (uint64_t)x->at, x->m, operand_text(x), F);
    }
  return F;
}
static void window_emit(Window* w) {
  uint64_t used = 0;
  for (size_t k = 0; k < w->seg.n; k++)
    for (size_t i = 0; i < w->seg.v[k].ins.n; i++)
      used |= w->seg.v[k].ins.v[i].regs;
  int S, T;
  pick(used, &S, &T);
  /* 安卓/鸿蒙窗口一律抬帧：暂存 STPRE 抬 F，环内 sp 指令按同一 F 重编码（TotK main 的
   * LL/SC 环里 ldr x18,[sp,#0xf0] 曾把整包打成 android-below-sp-v1 被打包器拒收）；
   * 写 sp / 写回 / 不认得的形态在 win_frame 里就 fail → 窗口记缺口，不产 below-sp 包 */
  int F = noredzone() ? win_frame(w) : 0;
  A base = here();
  winpro(S, T, F);
  A L = here() - base, p = base;
  AV entry = {0}, copies = {0}, external = {0};
  for (size_t k = 0; k < w->seg.n; k++) {
    PUSH(entry, p);
    PUSH(copies, p + L);
    p += L + 4 * w->seg.v[k].ins.n + 16;
  }
  A ext0 = p;
  for (size_t k = 0; k < w->seg.n; k++) {
    IV* l = &w->seg.v[k].ins;
    A hi = l->v[l->n - 1].at + 4;
    if (k) {
      REQUIRE(here() == entry.v[k]);
      winpro(S, T, F);
    }
    REQUIRE(here() == copies.v[k]);
    for (size_t i = 0; i < l->n; i++) {
      Ins* x = l->v + i;
      uint32_t v = has18(x) ? subst(x, S) : x->w;
      if (F && x->sp) {
        uint32_t o;
        REQUIRE(sp_shift(v, F, &o));
        v = o;
      }
      if (conditional(x)) {
        A t = target(x), nt = INT64_MIN;
        for (size_t z = 0; z < w->seg.n; z++) {
          IV* l2 = &w->seg.v[z].ins;
          if (t >= l2->v[0].at && t < l2->v[l2->n - 1].at + 4) {
            nt = copies.v[z] + t - l2->v[0].at;
            break;
          }
        }
        if (nt == INT64_MIN) {
          if (!contains(&external, t))
            PUSH(external, t);
          size_t idx = 0;
          while (external.v[idx] != t)
            idx++;
          nt = ext0 + 16 * idx;
        }
        A off = (nt - here()) >> 2;
        v = in(x->m, "tbz|tbnz") ? ((v & 0xfff8001f) | ((off & 0x3fff) << 5))
                                 : ((v & 0xff00001f) | ((off & 0x7ffff) << 5));
        Ins d = dis(v, here());
        REQUIRE(eq(d.m, x->m) && target(&d) == nt);
      } else
        REQUIRE(!in(x->m, "adr|adrp|b|bl|br|blr|ret") && !(eq(x->m, "ldr") && !strchr(operand_text(x), '[')));
      emit(v);
    }
    emit(STR(S, T, 0));
    winpost(S, T, F);
    emit(branch(here(), hi));
    emit(NOP);
  }
  REQUIRE(here() == ext0);
  for (size_t i = 0; i < external.n; i++) {
    emit(STR(S, T, 0));
    winpost(S, T, F);
    emit(branch(here(), external.v[i]));
    emit(NOP);
  }
  for (size_t k = 0; k < w->seg.n; k++)
    put(w->seg.v[k].ins.v[0].at, branch(w->seg.v[k].ins.v[0].at, entry.v[k]));
}
/* absptr 槽位的真值（#286：程序号 01E6… 的 .eh_frame CIE 没写 R 增强，FDE 指针按缺省编码 0 = 8 字节绝对地址存）。
 * 位置无关映像里这个槽由装载器按 R_AARCH64_RELATIVE 填：lld 缺省不在原位写加数（原位是 0），GNU ld 写。
 * 所以先查动态段 RELA 表（MOD0 + 4 → 动态段，DT_RELA / DT_RELASZ，映像按 vaddr 0 摊开、地址即偏移），有就取加数，没有用原位值。
 * RELR 本来就要求原位写加数，不用查 */
static int cmppair(const void* a, const void* b);
static A ehabs(A o, A v) {
  if (!g->rela_loaded) {
    g->rela_loaded = 1;
    A m0 = iw(4), dyn = m0 + si(m0 + 4), rela = -1, relasz = 0;
    for (A d = dyn; d >= 0 && (uint64_t)d + 16 <= g->len; d += 16) {
      uint64_t tag = iu64(d), val = iu64(d + 8);
      if (!tag)
        break;
      if (tag == 7)
        rela = (A)val;
      else if (tag == 8)
        relasz = (A)val;
    }
    if (rela >= 0 && relasz > 0 && (uint64_t)rela + (uint64_t)relasz <= g->len)
      for (A r = rela; r + 24 <= rela + relasz; r += 24)
        if ((iu64(r + 8) & 0xffffffffu) == 1027) {   /* R_AARCH64_RELATIVE */
          Pair p = {(A)iu64(r), (A)iu64(r + 16)};
          PUSH(g->rela, p);
        }
    if (g->rela.n > 1)
      qsort(g->rela.v, g->rela.n, sizeof(Pair), cmppair);
  }
  size_t lo = 0, hi = g->rela.n;
  while (lo < hi) {
    size_t m = (lo + hi) / 2;
    if (g->rela.v[m].a < o)
      lo = m + 1;
    else
      hi = m;
  }
  return lo < g->rela.n && g->rela.v[lo].a == o ? g->rela.v[lo].b : v;
}
static A rd(A o, int enc, int* sz) {
  int fmt = enc & 15;
  A v;
  if (fmt == 0 || fmt == 4 || fmt == 12) {   /* absptr（AArch64 指针 8 字节）/ udata8 / sdata8 */
    v = (A)iu64(o);
    *sz = 8;
    if (fmt == 0 && !(enc & 0x70))
      v = ehabs(o, v);
  } else if (fmt == 3) {
    v = iw(o);
    *sz = 4;
  } else if (fmt == 11) {
    v = si(o);
    *sz = 4;
  } else {
    fail("不支持 EH 编码 %x", enc);
    return 0;
  }
  if ((enc & 0x70) == 0x10)
    v += o;
  if ((enc & 0x70) == 0x30)
    v += g->ehs;
  return v;
}
static A ehptr(A o, int enc, int* sz) {
  int e = enc & 0x7f;
  REQUIRE((e & 0x70) == 0 || (e & 0x70) == 0x10);
  return rd(o, e, sz);
}
static uint64_t uleb(A* q) {
  uint64_t v = 0;
  int sh = 0;
  for (;;) {
    REQUIRE(*q >= 0 && (uint64_t)*q < g->len && sh < 64);
    uint8_t b = g->img[(*q)++];
    v |= (uint64_t)(b & 127) << sh;
    if (b < 128)
      return v;
    sh += 7;
  }
}
static int cmppair(const void* a, const void* b) {
  const Pair *x = a, *y = b;
  return x->a == y->a ? (x->b > y->b) - (x->b < y->b) : (x->a > y->a) - (x->a < y->a);
}
/* 函数边界的来源（模块没有 .eh_frame_hdr 时 MOD0 的起点 = 终点，原先照读起点后面的字节当 FDE 个数 → REQUIRE 中止）：
 *   ① .eh_frame_hdr 带二分表、表整个落在 MOD0 给的 [起点, 终点) 里 → 照表读（原路，产物不变）
 *   ② 有 .eh_frame_hdr、没有二分表（个数 / 表编码 = DW_EH_PE_omit 0xff，或表越出终点）→ 从它的 eh_frame_ptr 顺着 .eh_frame 本体逐条读 FDE，同一批函数
 *   ③ 没有 .eh_frame_hdr（终点 - 起点 < 4、版本不是 1、eh_frame_ptr 编码 omit）→ 没有 FDE；函数边界 = 动态符号表的函数（起点、起点 + 长度）
 *      + 直接调用目标——改写器对 FDE 覆盖不到的代码本来就按这一套分函数（func_of 的 bounds），这里整个模块都走它；统计行 eh_frame_walk / eh_frame_none */
typedef VEC(Pair) PairV;
static void eh_walk(A ef, PairV* fdes) {   /* ②：.eh_frame 从 ef 起逐条记录，FDE 记成 (-1, 位置)；遇零长终止符、或记录不像 .eh_frame 了就停 */
  for (A f = ef; f >= 0 && (uint64_t)f + 8 <= g->len;) {
    uint32_t l = iw(f);
    if (!l)
      break;
    if (l == UINT32_MAX) {   /* 64 位长度：同表路径不解析，跳过 */
      if ((uint64_t)f + 12 > g->len)
        break;
      f += 12 + (A)iu64(f + 4);
      continue;
    }
    if (l & 3 || (uint64_t)f + 4 + l > g->len)
      break;
    uint32_t id = iw(f + 4);
    if (id) {   /* FDE：CIE 指针要落回本段前面一条 CIE 上，不然已经走出 .eh_frame */
      A cie = f + 4 - (A)id;
      if (cie < ef || cie >= f || iw(cie + 4))
        break;
      Pair r = {-1, f};
      PUSH(*fdes, r);
    }
    f += 4 + (A)l;
  }
}
static void boundaries(void) {
  A m0 = iw(4);
  REQUIRE(m0 >= 0 && (uint64_t)m0 + 24 <= g->len && !memcmp(g->img + m0, "MOD0", 4));
  g->ehs = m0 + si(m0 + 16);
  A e = g->ehs, he = m0 + si(m0 + 20);
  int sz;
  PairV fdes = {0};   /* (表里的函数起点或 -1, FDE 位置) */
  int src = 0;   /* 0 = ① 表、1 = ② 本体、2 = ③ 无 */
  if (e < 0 || he - e < 4 || (uint64_t)he > g->len || g->img[e] != 1 || g->img[e + 1] == 0xff)
    src = 2;
  else {
    A q = e + 4, ef = rd(q, g->img[e + 1], &sz);
    q += sz;
    A n = -1;
    if (g->img[e + 2] != 0xff && g->img[e + 3] != 0xff) {
      n = rd(q, g->img[e + 2], &sz);
      q += sz;
      int esz;
      rd(q, g->img[e + 3], &esz);
      if (n < 0 || n > (he - q) / (2 * esz))   /* 表要整个落在 [起点, 终点) 里 */
        n = -1;
    }
    if (n >= 0)
      for (A i = 0; i < n; i++) {
        A a = rd(q, g->img[e + 3], &sz);
        q += sz;
        A f = rd(q, g->img[e + 3], &sz);
        q += sz;
        Pair r = {a, f};
        PUSH(fdes, r);
      }
    else {
      src = 1;
      eh_walk(ef, &fdes);
    }
  }
  VEC(Pair) ranges = {0};
  for (size_t i = 0; i < fdes.n; i++) {
    A a = fdes.v[i].a, f = fdes.v[i].b;
    if (a >= 0 && a < (A)g->text)
      PUSH(g->starts, a);
    if (iw(f) == 0 || iw(f) == UINT32_MAX)
      continue;
    A cie = f + 4 - iw(f + 4), p = cie + 9;
    REQUIRE(p >= 0 && (uint64_t)p < g->len);
    A aug = p;
    while ((uint64_t)p < g->len && g->img[p])
      p++;
    REQUIRE((uint64_t)p < g->len);
    p++;
    uleb(&p);
    uleb(&p);
    if (g->img[cie + 8] == 1)
      p++;
    else
      uleb(&p);
    int enc = 0;
    if (g->img[aug] == 'z') {
      uleb(&p);
      for (A k = aug + 1; g->img[k]; k++) {
        REQUIRE((uint64_t)p < g->len);
        if (g->img[k] == 'R')
          enc = g->img[p++];
        else if (g->img[k] == 'P') {
          int pe = g->img[p++];
          ehptr(p, pe, &sz);
          p += sz;
        } else if (g->img[k] == 'L')
          p++;
      }
    }
    A b = ehptr(f + 8, enc, &sz);
    int ns;
    A len = ehptr(f + 8 + sz, enc & 15, &ns);
    if (a < 0 && b < (A)g->text)   /* ②：起点取 FDE 自己的 pc_begin */
      PUSH(g->starts, b);
    if (b < (A)g->text) {
      Pair r = {b, b + len};
      PUSH(ranges, r);
      PUSH(g->bounds, b);
      if (b + len <= (A)g->text)
        PUSH(g->bounds, b + len);
    }
  }
  if (src)
    bump(src == 1 ? "eh_frame_walk" : "eh_frame_none");   /* 统计行：② / ③ 才有，常规模块统计不变 */
  if (src == 2) {   /* ③：动态符号表的函数起止进 bounds */
    A dyn = m0 + si(m0 + 4), st = -1, sy = -1;
    size_t syms = 0;
    if (dyn >= 0 && (uint64_t)dyn + 16 <= g->len)
      for (A at = dyn, end = MIN(dyn + 0x400 * 16, (A)g->len - 16); at < end; at += 16) {
        uint64_t tag = iu64(at), v = iu64(at + 8);
        if (!tag)
          break;
        if (v <= g->len && tag == 5 && st < 0)
          st = (A)v;
        if (v <= g->len && tag == 6 && sy < 0)
          sy = (A)v;
      }
    if (st >= 0 && sy >= 0 && sy < st)
      for (A at = sy; at + 24 <= st && (uint64_t)at + 24 <= g->len; at += 24) {
        uint64_t val = iu64(at + 8), size = iu64(at + 16);
        if ((g->img[at + 4] & 15) != 2 || !val || val >= g->text || (val & 3))   /* STT_FUNC、在代码段里 */
          continue;
        PUSH(g->bounds, (A)val);
        if (size && val + size <= g->text)
          PUSH(g->bounds, (A)(val + size));
        syms++;
      }
    msg("%s 没有 .eh_frame_hdr（MOD0 起点 %#llx 终点 %#llx）：函数边界改用动态符号的函数 %zu 个 + 直接调用目标\n", g->r.module, (unsigned long long)e,
        (unsigned long long)he, syms);
  } else if (src == 1)
    msg("%s .eh_frame_hdr 没有二分表：顺着 .eh_frame 本体读到 FDE %zu 条\n", g->r.module, g->starts.n);
  sort(&g->starts);
  if (ranges.n > 1)
    qsort(ranges.v, ranges.n, sizeof(Pair), cmppair);
  for (size_t i = 0; i < ranges.n; i++) {
    Pair r = ranges.v[i];
    if (g->cov.n && r.a <= g->cov.v[g->cov.n - 1].b)
      g->cov.v[g->cov.n - 1].b = MAX(g->cov.v[g->cov.n - 1].b, r.b);
    else
      PUSH(g->cov, r);
  }
  for (size_t i = 0; i < g->starts.n; i++)
    PUSH(g->bounds, g->starts.v[i]);
  for (A a = 0; a < (A)g->text; a += 4) {
    uint32_t w = iw(a);
    if ((w & 0xfc000000) == 0x94000000) {
      A t = a + 4 * ((A)((w & 0x3ffffff) ^ 0x2000000) - 0x2000000);
      if (t >= 0 && t < (A)g->text)
        PUSH(g->bounds, t);
    }
  }
  sort(&g->bounds);
}
static Pair func_of(A at) {
  int covered = 0;
  size_t lo = 0, hi = g->cov.n;   /* cov 按起点排序、互不重叠（boundaries 合并）：找最后一段起点 <= at */
  while (lo < hi) {
    size_t m = lo + (hi - lo) / 2;
    if (g->cov.v[m].a <= at)
      lo = m + 1;
    else
      hi = m;
  }
  if (lo && at < g->cov.v[lo - 1].b)
    covered = 1;
  AV* b = covered ? &g->starts : &g->bounds;
  size_t i = upper(b, at);
  /* Some NSOs have one unwind-covered tail spanning most of __text but no
   * per-function FDEs. Treating that tail as one function makes CFG analysis
   * quadratic on large modules. In that pathological case, use the existing
   * call-target/FDE boundary set, as we already do for uncovered code. */
  if (covered) {
    A a = i ? b->v[i - 1] : at;
    A end = i < b->n ? b->v[i] : (A)g->text;
    if (end - a > 16 * 1024 * 1024) {
      b = &g->bounds;
      i = upper(b, at);
      covered = 0;
    }
  }
  Pair r = {i ? b->v[i - 1] : (covered ? at : 0), i < b->n ? b->v[i] : (A)g->text};
  if (covered && !i)
    r.b = at + 4;
  return r;
}
static const char* sys_differs(uint32_t w, char* buf, size_t n) {
  if ((w & 0xff000000) == 0xd4000000) {
    int opc = (w >> 21) & 7, ll = w & 31;
    // svc / brk / hlt 放行：hlt 同 brk，两边都陷入终止（苹果 SIGILL，Switch 用户态未定义指令异常）
    if ((opc == 0 && ll == 1) || (opc == 1 && ll == 0) || (opc == 2 && ll == 0))
      return NULL;
    snprintf(buf, n, "异常类指令 %08x（hvc / smc / dcps）苹果用户态不可用", w);
    return buf;
  }
  if ((w & 0xffc00000) != 0xd5000000)
    return NULL;
  if ((w & 0xfffff01f) == 0xd503201f)
    return ((w >> 5) & 127) == 3 ? "wfi：苹果用户态 SIGILL（实测）" : NULL;
  if ((w & 0xfffff01f) == 0xd503301f &&
      in((const char*[]){"0", "1", "2", "3", "4", "5", "6", "7"}[(w >> 5) & 7], "2|4|5|6|7"))
    return NULL;
  int L = (w >> 21) & 1, op0 = (w >> 19) & 3, o1 = (w >> 16) & 7, nn = (w >> 12) & 15,
      m = (w >> 8) & 15, o2 = (w >> 5) & 7;
  if (op0 >= 2) {
    if (op0 == 3 && o1 == 3 &&
        ((nn == 4 && m == 2 && o2 == 0) || (nn == 4 && m == 4 && (o2 == 0 || o2 == 1)) ||
         (L && nn == 0 && m == 0 && o2 == 7)))
      return NULL;
    snprintf(buf, n, "%s 系统寄存器 S%d_%d_C%d_C%d_%d：不在已改写种类、也不在苹果实测等价白名单里",
             L ? "mrs" : "msr", op0, o1, nn, m, o2);
    return buf;
  }
  if (op0 == 1 && !L && o1 == 3 && nn == 7 &&
      ((o2 == 1 && (m == 14 || m == 10 || m == 11 || m == 5)) || (m == 4 && o2 == 1)))
    return NULL;
  snprintf(buf, n, "系统指令 %08x（op0=%d op1=%d CRn=%d CRm=%d op2=%d）：不在苹果实测等价白名单里",
           w, op0, o1, nn, m, o2);
  return buf;
}
static void scan(void);
#define DATA_MIN_EXC 64   /* 至少这么多 hvc/smc/dcps（苹果和 Horizon 用户态都不会执行）才算「代码段里有数据」的证据 */
static int in_code(A a) {
  size_t w = (size_t)a / 4;
  return !g->codemap || (g->codemap[w / 8] >> (w % 8)) & 1;
}
static void mark_code(A a) {
  size_t w = (size_t)a / 4;
  g->codemap[w / 8] |= (uint8_t)(1 << (w % 8));
}
/* 直接分支目标；不是分支返回 -1 */
static A branch_target(uint32_t w, A a) {
  if ((w & 0x7c000000) == 0x14000000) {   /* b / bl */
    int64_t imm = w & 0x3ffffff;
    return a + (imm - ((imm >> 25) << 26)) * 4;
  }
  if ((w & 0xff000010) == 0x54000000 || (w & 0x7e000000) == 0x34000000) {   /* b.cond / cbz / cbnz */
    int64_t imm = (w >> 5) & 0x7ffff;
    return a + (imm - ((imm >> 18) << 19)) * 4;
  }
  if ((w & 0x7e000000) == 0x36000000) {   /* tbz / tbnz */
    int64_t imm = (w >> 5) & 0x3fff;
    return a + (imm - ((imm >> 13) << 14)) * 4;
  }
  return -1;
}
static int code_ends(uint32_t w) {   /* 顺序执行到此为止：b / ret / br */
  return (w & 0xfc000000) == 0x14000000 || (w & 0xfffffc1f) == 0xd65f0000 || (w & 0xfffffc1f) == 0xd61f0000;
}
/* #108：有的游戏把大量数据放进代码段（Spelunky 2 约 338 MB，31 万条 hvc/smc/dcps、均匀分布），线性扫描把数据当指令，全成缺口，还会误改数据。
 * 只有出现足够多「不可能是代码」的指令才启用：真实代码 = .eh_frame 的函数范围 + 动态符号的函数 + 从它们出发的直接分支闭包，范围外是数据，不改写也不算缺口。
 * 没有这些指令的模块（gaps 为 0 或只有别的缺口）不进这里，产物逐字节不变 */
static void data_in_text(void) {
  size_t exc = 0;
  for (size_t i = 0; i < g->gaps.n; i++)
    exc += !!strstr(g->gaps.v[i].why, "异常类指令");
  if (exc < DATA_MIN_EXC || !g->cov.n) {
    if (exc) msg("%s 内嵌数据判定：不启用（异常类指令 %zu 条，门槛 %d；函数范围 %zu 段）\n", g->r.module, exc, DATA_MIN_EXC, g->cov.n);
    return;
  }
  size_t bytes = (size_t)g->text / 32 + 1;
  uint8_t* map = resize(NULL, bytes);
  memset(map, 0, bytes);
  uint8_t* old = g->codemap;
  g->codemap = map;
  AV seeds = {0};
  size_t fde = 0, syms = 0;
  for (size_t i = 0; i < g->cov.n; i++)
    for (A a = g->cov.v[i].a; a < g->cov.v[i].b && a + 4 <= (A)g->text; a += 4) {
      if (a >= 0) { mark_code(a); fde += 4; }
    }
  A m0 = iw(4), dyn = m0 + si(m0 + 4), st = -1, sy = -1;
  if (dyn >= 0 && (uint64_t)dyn + 16 <= g->len)
    for (A at = dyn, end = MIN(dyn + 0x400 * 16, (A)g->len - 16); at < end; at += 16) {
      uint64_t tag = iu64(at), v = iu64(at + 8);
      if (!tag) break;
      if (v <= g->len && tag == 5 && st < 0) st = (A)v;
      if (v <= g->len && tag == 6 && sy < 0) sy = (A)v;
    }
  if (st >= 0 && sy >= 0 && sy < st)
    for (A at = sy; at + 24 <= st && (uint64_t)at + 24 <= g->len; at += 24) {
      uint64_t val = iu64(at + 8);
      if ((g->img[at + 4] & 15) == 2 && val && val < g->text && !(val & 3)) { PUSH(seeds, (A)val); syms++; }   /* STT_FUNC */
    }
  for (size_t i = 0; i < g->cov.n; i++)
    for (A a = g->cov.v[i].a; a < g->cov.v[i].b && a + 4 <= (A)g->text; a += 4) {
      A t = a >= 0 ? branch_target(iw(a), a) : -1;
      if (t >= 0 && t < (A)g->text && !(t & 3) && !in_code(t)) PUSH(seeds, t);
    }
  size_t walked = 0;
  while (seeds.n) {
    A a = seeds.v[--seeds.n];
    for (int n = 0; n < 1 << 16 && a >= 0 && a + 4 <= (A)g->text && !in_code(a); n++, a += 4) {
      Ins x;
      uint32_t w = iw(a);
      if (!decode(w, a, &x)) break;
      mark_code(a); walked += 4;
      A t = branch_target(w, a);
      if (t >= 0 && t < (A)g->text && !(t & 3) && !in_code(t)) PUSH(seeds, t);
      if (code_ends(w)) break;
    }
  }
  size_t outside = 0;
  for (size_t i = 0; i < g->gaps.n; i++)
    outside += strstr(g->gaps.v[i].why, "异常类指令") && !in_code(g->gaps.v[i].at);
  size_t code = 0;
  for (A a = 0; a + 4 <= (A)g->text; a += 4) code += in_code(a) ? 4 : 0;
  if (outside * 10 < exc * 9) {   /* 这些指令大多在函数范围内：范围本身不可信，不排除，缺口照报 */
    msg("%s 内嵌数据判定：不启用（异常类指令 %zu 条，范围外只有 %zu 条）\n", g->r.module, exc, outside);
    g->codemap = old;
    return;
  }
  size_t gaps0 = g->gaps.n, sites0 = g->sites.n;
  g->gaps.n = g->sites.n = 0;
  scan();
  msg("%s 内嵌数据判定：启用；代码段 %zu 字节，真实代码 %zu（函数范围 %zu、动态符号 %zu 个、分支闭包 %zu），排除 %zu 字节；异常类指令 %zu 条（范围外 %zu）；缺口 %zu → %zu，改写点 %zu → %zu\n",
      g->r.module, (size_t)g->text, code, fde, syms, walked, (size_t)g->text - code, exc, outside, gaps0, g->gaps.n, sites0, g->sites.n);
}
static void scan(void) {
  /* NRO（romfs 里 nn::ro 装的模块，runtime/rewriter/nro_to_nso.py 转来）：text 段开头 [4, 0x80) 是 NRO 头（MOD0 偏移、
     'NRO0'、大小、段表、构建号），是数据不是指令，不扫（构建号字节会被认成 hvc 等缺口）；NSO 没有这个标记，扫描范围不变（与 patch_nso.py 同口径） */
  const A hdr = g->text >= 0x80 && !memcmp(g->img + 0x10, "NRO0", 4) ? 0x80 : 0;
  for (A a = 0; a < (A)g->text; a += 4) {
    if (a >= 4 && a < hdr) continue;
    if (!in_code(a)) continue;
    uint32_t w = iw(a);
    const char* k = NULL;
    int arg = 0;
    if ((w & 0xffe0001f) == 0xd4000001) {
      k = "svc";
      arg = (w >> 5) & 65535;
    } else if ((w & 0xffffffe0) == 0xd53bd040)
      k = "tpidr_r";
    else if ((w & 0xffffffe0) == 0xd51bd040)
      k = "tpidr_w";
    else if ((w & 0xffffffe0) == 0xd53bd060)
      k = "tpidrro_r";
    else if ((w & 0xffffffe0) == 0xd53be020) {
      k = "cntpct";
      arg = w & 31;
    } else if ((w & 0xffffffe0) == 0xd53be040) {
      k = "cntvct";
      arg = w & 31;
    } else if ((w & 0xffffffe0) == 0xd53b0020) {
      k = "ctr";
      arg = w & 31;
    } else if ((w & 0xffe0001f) == 0xd4200000 && ((w >> 5) & 65535) >= 0xb000 &&
               ((w >> 5) & 65535) <= 0xbfff) {
      gap(a, "brk", "brk #0x%x：macOS 内核截走 0xB000–0xBFFF，进程无声被杀", (w >> 5) & 65535);
      continue;
    } else {
      char why[500];
      const char* reason = sys_differs(w, why, sizeof(why));
      if (reason) {
        gap(a, "sys", "%s", reason);
        continue;
      }
      if ((w & 31) != 18 && ((w >> 5) & 31) != 18 && ((w >> 10) & 31) != 18 &&
          ((w >> 16) & 31) != 18)
        continue;
      Ins x;
      if (decode(w, a, &x) && has18(&x))
        k = "x18";
    }
    if (k) {
      Site s = {a, k, arg, 0};
      PUSH(g->sites, s);
    }
  }
}
static AV targets(const IV* l) {
  if (g->ftg_of && l->v == g->ftg_of && l->n == g->ftg_n)
    return g->ftg;   /* analyze 已为当前函数算好；调用方只读 */
  AV a = {0};
  for (size_t i = 0; i < l->n; i++)
    if (direct(l->v + i))
      PUSH(a, target(l->v + i));
  sort(&a);
  return a;
}
/* 当前函数的一次性索引（analyze 设 ftg 后调）：每个直接跳转目标的来源下标、每个寄存器被写的条数。
 * general / joinbound 原先每张跳转表都整函数扫一遍，一个函数里上万张表时是平方（#251） */
static void fn_index(const IV* l) {
  size_t nt = g->ftg.n;
  g->fsrc_at = zalloc((nt + 1) * sizeof(size_t));
  memset(g->fwrites, 0, sizeof(g->fwrites));
  size_t nsrc = 0;
  for (size_t q = 0; q < l->n; q++) {
    const Ins* x = l->v + q;
    for (int h = 0; h < 2; h++)
      for (uint64_t m = (uint64_t)(x->wr >> (64 * h)); m; m &= m - 1)
        g->fwrites[64 * h + __builtin_ctzll(m)]++;
    if (direct(x)) {
      size_t i = upper(&g->ftg, target(x));
      REQUIRE(i && g->ftg.v[i - 1] == target(x));
      g->fsrc_at[i]++;   /* 先按目标计数，下面前缀和 */
      nsrc++;
    }
  }
  for (size_t i = 0; i < nt; i++)
    g->fsrc_at[i + 1] += g->fsrc_at[i];
  g->fsrc = zalloc((nsrc ? nsrc : 1) * sizeof(int));
  size_t* fill = zalloc((nt + 1) * sizeof(size_t));
  memcpy(fill, g->fsrc_at, (nt + 1) * sizeof(size_t));
  for (size_t q = 0; q < l->n; q++)
    if (direct(l->v + q)) {
      size_t i = upper(&g->ftg, target(l->v + q)) - 1;
      g->fsrc[fill[i]++] = (int)q;   /* q 递增：每个目标的来源天然升序 */
    }
  release(fill);
}
static int fn_indexed(const IV* l) {
  return g->ftg_of && l->v == g->ftg_of && l->n == g->ftg_n && g->fsrc_at;
}
static int def(const IV* l, int end, int lo, int r) {
  for (int i = end - 1; i >= lo; i--)
    if (writes(l->v + i, r))
      return i;
  return -1;
}
static int rno(const Ins* x, int op) {
  return op < detail(x)->op_count && detail(x)->operands[op].type == ARM64_OP_REG
             ? regnum(detail(x)->operands[op].reg)
             : -1;
}
static int regimm(const Ins* x, const char* m, int r, int rr) {
  return eq(x->m, m) && rno(x, 0) == r && (rr < 0 || rno(x, 1) == rr) &&
         detail(x)->op_count == (rr < 0 ? 2 : 3) && detail(x)->operands[rr < 0 ? 1 : 2].type == ARM64_OP_IMM &&
         !strstr(operand_text(x), "lsl");
}
static int regadd(const Ins* x, int d, int a, int b, int shift) {
  return eq(x->m, "add") && rno(x, 0) == d && rno(x, 1) == a && rno(x, 2) == b &&
         detail(x)->op_count == 3 && detail(x)->operands[2].shift.value == (unsigned)shift;
}
static int ldrsw(const Ins* x, int* T, int* B, int* I) {
  if (!eq(x->m, "ldrsw") || detail(x)->op_count != 2 || detail(x)->operands[1].type != ARM64_OP_MEM)
    return 0;
  cs_arm64_op* p = (cs_arm64_op*)&detail(x)->operands[1];
  *T = rno(x, 0);
  *B = regnum(p->mem.base);
  *I = regnum(p->mem.index);
  return *T >= 0 && *B >= 0 && *I >= 0 && p->shift.type == ARM64_SFT_LSL && p->shift.value == 2 &&
         !p->mem.disp;
}
static int chain(const IV* l, int end, int r, int maxback, A* tbl, int* pageindex) {
  int lo = MAX(0, end - maxback), a = def(l, end, lo, r);
  if (a < 0 || !regimm(l->v + a, "add", r, r))
    return 0;
  int p = def(l, a, lo, r);
  if (p < 0 || !eq(l->v[p].m, "adrp") || rno(l->v + p, 0) != r)
    return 0;
  *tbl = detail(&l->v[p])->operands[1].imm + detail(&l->v[a])->operands[2].imm;
  if (pageindex)
    *pageindex = p;
  return 1;
}
/* sp 基址访存（有符号偏移 LDP/STP、无符号偏移 LDR/STR、LDUR/STUR，均不回写）的字节偏移加 delta；*off 回原偏移。认不出 / 越界回 0。
 * 跳转表分派块要搬 ldrsw…br 之间的指令：苹果块只用 sp 下方 32 字节暂存、不动 sp，安卓块先 sub sp,#32（安卓信号帧会写 sp 下方），
 * 搬来的 sp 访存在安卓上要把偏移加 32（女神异闻录5 乱战 main 0x494864–0x4948e0：取表与 br 之间编译器排了多条 stp w0,w0,[sp,#…]） */
static int sp_rebase(uint32_t w, int delta, uint32_t* o, int* off) {
  if (((w >> 5) & 31) != 31)
    return 0;
  if ((w & 0x3B800000u) == 0x29000000u) { /* LDP / STP 有符号偏移（含 LDPSW、SIMD） */
    int opc = (int)(w >> 30), v = (w >> 26) & 1, sc = v ? 4 << opc : opc == 2 ? 8 : 4;
    int imm = (int)((w >> 15) & 0x7F);
    if (imm & 0x40)
      imm -= 0x80;
    *off = imm * sc;
    if (delta % sc || imm + delta / sc < -64 || imm + delta / sc > 63)
      return 0;
    *o = (w & ~(0x7Fu << 15)) | ((uint32_t)((imm + delta / sc) & 0x7F) << 15);
    return 1;
  }
  if ((w & 0x3B000000u) == 0x39000000u) { /* LDR / STR 无符号偏移 */
    int size = (int)(w >> 30), sh = ((w >> 26) & 1) && size == 0 && ((w >> 23) & 1) ? 4 : size;
    int imm = (int)((w >> 10) & 0xFFF);
    *off = imm << sh;
    if (delta % (1 << sh) || imm + (delta >> sh) > 0xFFF)
      return 0;
    *o = (w & ~(0xFFFu << 10)) | ((uint32_t)(imm + (delta >> sh)) << 10);
    return 1;
  }
  if ((w & 0x3B200C00u) == 0x38000000u) { /* LDUR / STUR */
    int imm = (int)((w >> 12) & 0x1FF);
    if (imm & 0x100)
      imm -= 0x200;
    *off = imm;
    if (imm + delta < -256 || imm + delta > 255)
      return 0;
    *o = (w & ~(0x1FFu << 12)) | ((uint32_t)((imm + delta) & 0x1FF) << 12);
    return 1;
  }
  return 0;
}
/* 搬来的 sp 访存能不能用：只认上面三类、偏移 ≥ 0（不碰分派块的 sp 下方暂存），安卓加 32 后还编得出 */
static int sp_mid_ok(const Ins* x) {
  uint32_t o;
  int off;
  return sp_rebase(x->w, 0, &o, &off) && off >= 0 && sp_rebase(x->w, 32, &o, &off);
}
static int midok(const Ins* x) {
  return in(
      x->m,
      "ldp|ldpsw|stp|"
      "ldr|ldrb|ldrh|ldrsb|ldrsh|ldrsw|ldur|ldurb|ldurh|ldursb|ldursh|ldursw|str|strb|strh|stur|"
      "sturb|sturh|mov|movz|movk|movn|add|sub|and|orr|eor|lsl|lsr|asr|bfi|bfxil|ubfx|sbfx|ubfiz|"
      "sbfiz|sxtw|sxtb|sxth|uxtb|uxth|cmp|cmn|tst|csel|cset|csinc|madd|mul|neg|orn|bic|mvn");
}
static void jbad(char* why, size_t n, A at, const char* fmt, ...) {
  char buf[420];
  va_list a;
  va_start(a, fmt);
  vsnprintf(buf, sizeof(buf), fmt, a);
  va_end(a);
  snprintf(why, n, "jump table %" PRIx64 ": %s", (uint64_t)at, buf);
}
/* 汇合点 J 的其它入边的下标界（文明6 main 0x10f43e0 / 0x10f3d0c：分派块开头既由「cmp w10,#3 / b.hi 出界」直落进来，
 * 又由别处「cmp w10,#3 / b.ls J」跳进来）：每条跳到 J 的直接跳转都得是 b.ls / b.lo，且同块紧前（8 条内、不跨跳入点、
 * 中间不写 I、不改标志）有 cmp I,#N；返回各入边允许的项数最大值（b.ls → N+1、b.lo → N），任一条不合规或一条都没有回 -1 */
static int joinbound(const IV* l, const AV* tg, A J, int I) {
  int best = -1;
  size_t from = 0, to = l->n, ti = 0;
  int indexed = fn_indexed(l);
  if (indexed) {   /* 只看跳到 J 的那几条（结果与整函数扫相同：任一条不合规就 -1，否则取最大） */
    ti = upper(&g->ftg, J);
    if (!ti || g->ftg.v[ti - 1] != J)
      return -1;
    from = g->fsrc_at[ti - 1];
    to = g->fsrc_at[ti];
  }
  for (size_t e = from; e < to; e++) {
    size_t q = indexed ? (size_t)g->fsrc[e] : e;
    const Ins* x = l->v + q;
    if (!direct(x) || target(x) != J)
      continue;
    if (!in(x->m, "b.ls|b.lo"))
      return -1;
    int c = -1;
    for (int p = (int)q - 1; p >= 0 && p >= (int)q - 8; p--) {
      const Ins* y = l->v + p;
      if (regimm(y, "cmp", I, -1)) {
        c = (int)detail(y)->operands[1].imm + eq(x->m, "b.ls");
        break;
      }
      if (writes(y, I) || isbr(y) || has(tg, l->v[p + 1].at) || in(y->m, "cmp|cmn|tst|ccmp|ccmn") || pre(y->m, "subs") ||
          pre(y->m, "adds") || pre(y->m, "ands") || pre(y->m, "bics"))
        break;
    }
    if (c <= 0)
      return -1;
    best = MAX(best, c);
  }
  return best;
}
static int general(const IV* l, int j, Pair f, Jump* out, char* why, size_t n) {
  A A0 = l->v[j].at;
  AV tg = targets(l);
  int k = j - 1;
#define BAD(...)                   \
  do {                             \
    jbad(why, n, A0, __VA_ARGS__); \
    return 0;                      \
  } while (0)
  while (k >= 0 && !writes(l->v + k, 18)) {
    if (isbr(l->v + k) || has(&tg, l->v[k + 1].at))
      BAD("x18 来源跨基本块");
    k--;
  }
  if (k < 0)
    BAD("函数内找不到 x18 的定义");
  if (k + 1 < j && has(&tg, l->v[k + 1].at))
    BAD("x18 定义与 br 之间有跳入点");
  Ins* dx = l->v + k;
  /* 尾调用：x18 由一次从内存取数给出（ldr x18, [Xn, #imm]，或 ldp 一次取「函数指针 + 另一字」，如 IL2CPP 虚调用表项
   * {方法指针, 方法数据}，x0–x17 全占着时编译器把指针放 x18），之后不再碰 x18、br x18 跳出 */
  int ld1 = eq(dx->m, "ldr") && rno(dx, 0) == 18 && detail(dx)->op_count == 2 && detail(dx)->operands[1].type == ARM64_OP_MEM;
  int ld2 = eq(dx->m, "ldp") && operand_text(dx)[0] == 'x' && (rno(dx, 0) == 18 || rno(dx, 1) == 18) && rno(dx, 0) != rno(dx, 1) &&
            detail(dx)->op_count == 3 && detail(dx)->operands[2].type == ARM64_OP_MEM;
  const cs_arm64_op* mo = ld1 ? &detail(dx)->operands[1] : ld2 ? &detail(dx)->operands[2] : NULL;
  if (mo && regnum(mo->mem.base) != 18 && (!ld2 || regnum(mo->mem.base) >= 0) && !mo->mem.index && !detail(dx)->writeback) {   /* ldp 基址要通用寄存器（同 Python 对照实现的写法，不认 sp） */
    for (int q = k + 1; q < j; q++)
      if (reads(l->v + q, 18) || writes(l->v + q, 18))
        BAD("尾调用形态中间又碰了 x18");
    out->type = 4;
    return 1;
  }
  if (!eq(dx->m, "add") || rno(dx, 0) != 18 || detail(dx)->op_count != 3 || rno(dx, 1) < 0 ||
      rno(dx, 2) < 0 || detail(dx)->operands[2].shift.value)
    BAD("x18 最后由 %s %s 给出，不是已知形态", dx->m, operand_text(dx));
  int ka = k, r1 = rno(dx, 1), r2 = rno(dx, 2), k0 = -1, T = -1, B = -1, I = -1;
  /* 表基址可经一次 64 位寄存器拷贝到 add（女神异闻录5 乱战 main 0x494864–0x4948e0：ldrsw x9,[x10,x9,lsl#2] / mov x12,x10 /
   * mov w10,w0 / add x18,x9,x12——x10 随后被另作他用，编译器先把基址拷进 x12）。cq = 拷贝所在下标，cd = 拷贝目的寄存器 */
  int cq = -1, cd = -1, csrc = -1;
  for (int q = ka - 1; q >= 0; q--) {
    Ins* x = l->v + q;
    if (isbr(x) || has(&tg, l->v[q + 1].at))
      break;
    int t, b, i;
    if (ldrsw(x, &t, &b, &i) && ((t == r1 && b == r2) || (t == r2 && b == r1))) {
      k0 = q;
      T = t;
      B = b;
      I = i;
      break;
    }
    /* 拷贝也可在 ldrsw 之前（文明6 main 0x10f338c–0x10f33a0，6 处同形：adrp/add x18 / mov x6,x18 / ldrsw x18,[x18,x10,lsl#2] /
     * add x18,x18,x6——表项写回基址寄存器本身，编译器先把基址拷进 x6）：add 的一边是表项，另一边往前找 mov o,xB，
     * 拷贝到 ldrsw 之间不改 o / xB；ldrsw 到 add 之间不改 o 由本循环前面的扫描保证（碰到写 r1 / r2 就停） */
    if (cq < 0 && ldrsw(x, &t, &b, &i) && (t == r1 || t == r2)) {
      int o = t == r1 ? r2 : r1, pre = -1;
      for (int p2 = q - 1; o != b && o != t && p2 >= 0; p2--) {
        Ins* y = l->v + p2;
        if (isbr(y) || has(&tg, l->v[p2 + 1].at))
          break;
        if (eq(y->m, "mov") && operand_text(y)[0] == 'x' && detail(y)->op_count == 2 && rno(y, 0) == o && rno(y, 1) == b) {
          pre = p2;
          break;
        }
        if (writes(y, o) || writes(y, b))
          break;
      }
      if (pre >= 0) {
        k0 = q;
        T = t;
        B = b;
        I = i;
        cq = pre;
        cd = o;
        csrc = b;
        break;
      }
    }
    int cs = rno(x, 1);
    if (cq < 0 && eq(x->m, "mov") && operand_text(x)[0] == 'x' && detail(x)->op_count == 2 && cs >= 0 && (rno(x, 0) == r1 || rno(x, 0) == r2)) {
      cq = q;
      cd = rno(x, 0);
      csrc = cs;
      if (cd == r1)
        r1 = cs;
      else
        r2 = cs;
      continue;
    }
    if (writes(x, r1) || writes(x, r2))
      break;
  }
  if (k0 < 0)
    BAD("add x18 前同一基本块内没有配对的 ldrsw xT,[xB,xI,lsl#2]");
  if (cq >= 0 && csrc != B)
    BAD("add x18 前的寄存器拷贝不是表基址的拷贝");
  if (T == 16 || B == 16 || I == 16 || T == 17 || B == 17 || I == 17 || cd == 16 || cd == 17) {
    if (!out->x1617_ok)
      BAD("跳转表用到 x16/x17");
    out->uses_x16x17 = 1;
  }
  /* 有拷贝时：基址只要在 ldrsw 到拷贝之间不变，拷贝之后归目的寄存器（拷贝到 add 之间不写它，上面的扫描已核） */
  for (int q = k0 + 1; q < ka; q++)
    if ((T != 18 && (reads(l->v + q, T) || writes(l->v + q, T))) || ((cq < 0 || q < cq) && writes(l->v + q, B)))
      BAD("ldrsw 与 add 之间改了表项/表基址寄存器 %" PRIx64, (uint64_t)l->v[q].at);
  int setT = T != 18;
  for (int q = ka + 1; q < j; q++) {
    if (setT && reads(l->v + q, T))
      BAD("add 之后又读了表项寄存器 x%d %" PRIx64, T, (uint64_t)l->v[q].at);
    if (setT && writes(l->v + q, T))
      setT = 0;
  }
  for (int q = k0 + 1; q < j; q++)
    if (q != ka) {
      Ins* x = l->v + q;
      if ((!midok(x) && !in(x->m, "adr|adrp")) || (!strchr(operand_text(x), '[') && (pre(x->m, "ld") || pre(x->m, "st"))))   /* adr / adrp 搬过去按原目标重算（brrel） */
        BAD("中间指令不可搬移 %" PRIx64 " %s %s", (uint64_t)x->at, x->m, operand_text(x));
      /* x16 / x17 可以搬：brrel 先还原 x16 / x17 原值再执行搬来的指令，之后把它们的新值存回槽、每个落点还原后再跳（10-26 普查
       * 010095300B6A4000 / 0100C1F0051B6000：编译器把 mov/movk w16、mov w17 排在取表与 br 之间，跳转目标要读）。
       * x18 搬过去碰的是真寄存器而不是虚拟 x18 槽、sp 下方是暂存槽，这两类仍不能搬 */
      if ((x->regs & BIT(18)) || (x->sp && !sp_mid_ok(x)))
        BAD("中间指令碰 x18/sp %" PRIx64, (uint64_t)x->at);
      PUSH(out->mids, *x);
    }
  for (int q = k0; q <= j; q++) {
    if (q > k0 && has(&tg, l->v[q].at))
      BAD("跳转落进 ldrsw…br 中间");
    Site* s = site_at(l->v[q].at);
    if ((s && s->done) || consumed(l->v[q].at))
      BAD("与改写窗口重叠");
  }
  A tbl;
  int p;
  if (!chain(l, k0, B, k0 + 1, &tbl, &p))
    BAD("表基址 x%d 不是 adrp+add 给出", B);
  int same = 1, uniq = 0, inbound = 0;
  for (int q = p + 1; q <= k0; q++)
    if (isbr(l->v + q) || has(&tg, l->v[q].at))
      same = 0;
  if (fn_indexed(l)) {   /* 用函数索引：写 B 的条数直接读；外部跳入只看落在 [p+1, k0] 的目标的来源（来源下标 < p 等价于地址在 adrp 之前） */
    uniq = (int)g->fwrites[B];
    A lo = l->v[p + 1].at, hi = l->v[k0].at;
    for (size_t i = upper(&g->ftg, lo - 1); i < g->ftg.n && g->ftg.v[i] <= hi && !inbound; i++)
      if (g->fsrc_at[i] < g->fsrc_at[i + 1] && g->fsrc[g->fsrc_at[i]] < p)
        inbound = 1;
  } else
    for (size_t q = 0; q < l->n; q++) {
      if (writes(l->v + q, B))
        uniq++;
      if (direct(l->v + q) && l->v[q].at < l->v[p].at) {
        A t = target(l->v + q);
        if (t >= l->v[p + 1].at && t <= l->v[k0].at)
          inbound = 1;
      }
    }
  if (!(same || uniq == 2 || !inbound))
    BAD("表基址 x%d 的 adrp+add 与 ldrsw 之间有从建基址前的外部跳入，且函数内不唯一", B);
  int cnt = 0, joined = 0;
  for (int q = k0 - 1; q > MAX(-1, k0 - 24); q--) {
    Ins* x = l->v + q;
    if (q + 1 != k0 && has(&tg, l->v[q + 1].at)) {
      /* 跨一次汇合点：别的入边都按 joinbound 带界跳进来才继续往前找直落路径的界；项数取各路最大（每项目标下面都核在函数内） */
      int jc = joined ? -1 : joinbound(l, &tg, l->v[q + 1].at, I);
      if (jc <= 0)
        break;
      joined = jc;
      if (in(x->m, "b|br|ret")) {   /* 汇合点前一条不直落：只有跳入边 */
        cnt = jc;
        break;
      }
    }
    if (regimm(x, "cmp", I, -1)) {
      for (int qq = q + 1; qq < (int)MIN(l->n, (size_t)MAX(q + 8, k0)); qq++) {
        Ins* y = l->v + qq;
        if (has(&tg, y->at))
          break;
        if (in(y->m, "b.hi|b.hs")) {
          cnt = (int)detail(x)->operands[1].imm + eq(y->m, "b.hi");
          break;
        }
        if (writes(y, I) || isbr(y) || !midok(y) || in(y->m, "cmp|cmn|tst") ||
            (y->regs & (BIT(16) | BIT(17))) || y->sp)
          break;
      }
      if (cnt)
        break;
    }
    if (writes(x, I))
      break;
  }
  if (!cnt)
    BAD("找不到下标 x%d 的界检查 cmp+b.hi/b.hs", I);
  cnt = MAX(cnt, joined);
  REQUIRE(cnt > 0 && cnt < INT_MAX / 4);
  for (int i = 0; i < cnt; i++) {
    A t = tbl + si(tbl + 4LL * i);
    if (t < f.a || t >= f.b || t % 4)
      BAD("第 %d 项目标 0x%" PRIx64 " 不在函数内", i, (uint64_t)t);
  }
  out->type = 3;
  out->at = l->v[k0].at;
  out->B = B;
  out->T = T;
  out->I = I;
  out->cd = cd;
  out->tbl = tbl;
  out->count = cnt;
  out->setT = setT;
  for (int q = k0; q <= j; q++)
    PUSH(out->span, l->v[q].at);
  return 1;
#undef BAD
}
static int compact(const IV* l, int j, Pair f, Jump* out) {
  AV tg = targets(l);
  int lo = j;
  for (int q = j - 1; q > MAX(-1, j - 33); q--) {
    if (isbr(l->v + q) || has(&tg, l->v[q + 1].at))
      break;
    lo = q;
  }
  int a = def(l, j, lo, 18);
  if (a < 0)
    return 0;
  Ins* x = l->v + a;
  int off = rno(x, 2);
  if (off < 0 || off == 18 || !regadd(x, 18, 18, off, 2))
    return 0;
  int adr = def(l, a, lo, 18), ld = def(l, a, lo, off);
  if (adr < 0 || ld < 0 || !eq(l->v[adr].m, "adr") || rno(l->v + adr, 0) != 18)
    return 0;
  Ins* z = l->v + ld;
  int width = in(z->m, "ldrb|ldrsb") ? 256 : in(z->m, "ldrh|ldrsh") ? 65536 : 0;
  A b = detail(&l->v[adr])->operands[1].imm;
  if (!width || b < f.a || b >= f.b || b % 4)
    return 0;
  /* 缺省 bias=0：ldrsb/ldrsh 仍按无符号宽度铺垫，产物与原先逐字节相同。
   * S2A_REWRITE_SIGNED_JT=1 时只改硬件确实会得到小负偏移的形态：
   *   add …, Wm, sxtb/sxth #2，或 sxtw #2 配 ldrsb/ldrsh：低 8/16 位符号扩展后左移 2；
   *   ldrsb/ldrsh 写入 X 再 lsl #2：符号扩展进 64 位，字节 ≥128（半字 ≥32768）目标在基址之下。
   * 写入 W 再 lsl #2：W 写清掉高 32 位，高位项变成约 2^32 的正偏移，线性垫盖不住。
   * 不按 256/65536 项改写，返回 0，后面按认不出的 br x18 记缺口、不出映像（退出 3）。 */
  int bias = 0;
  if (g->signed_jt) {
    /* 已知配对才铺垫。表外组合（含 W 目的的 ldrsb/ldrsh 再 lsl #2）返回 0，后面记缺口。 */
    int ext = detail(x)->operands[2].ext;
    int xdst = operand_text(z)[0] == 'x';
    int known = 0;
    /* 无符号加载已经清零扩展；这些扩展不会引入负偏移，保持原无符号垫。 */
    if ((eq(z->m, "ldrb") && (ext == ARM64_EXT_UXTW || ext == ARM64_EXT_SXTW)) ||
        (eq(z->m, "ldrh") && (ext == ARM64_EXT_UXTW || ext == ARM64_EXT_UXTH))) {
      known = 1;
    } else if (ext == ARM64_EXT_SXTB && in(z->m, "ldrb|ldrsb")) {
      bias = -128;
      known = 1;
    } else if (ext == ARM64_EXT_SXTH && in(z->m, "ldrh|ldrsh")) {
      bias = -32768;
      known = 1;
    } else if (ext == ARM64_EXT_SXTW && eq(z->m, "ldrsb")) {
      bias = -128;
      known = 1;
    } else if (ext == ARM64_EXT_SXTW && eq(z->m, "ldrsh")) {
      bias = -32768;
      known = 1;
    } else if (ext == ARM64_EXT_INVALID && eq(z->m, "ldrb"))
      known = 1;
    else if (ext == ARM64_EXT_INVALID && eq(z->m, "ldrh"))
      known = 1;
    else if (ext == ARM64_EXT_INVALID && eq(z->m, "ldrsb") && xdst) {
      bias = -128;
      known = 1;
    } else if (ext == ARM64_EXT_INVALID && eq(z->m, "ldrsh") && xdst) {
      bias = -32768;
      known = 1;
    }
    if (!known)
      return 0;
  }
  out->type = 1;
  out->base = b;
  out->count = width;
  out->bias = bias;
  return 1;
}
static int classify(const IV* l, int j, Pair f, Jump* out, char* why, size_t n) {
  if (compact(l, j, f, out))
    return 1;
  for (int q = j - 1; q >= 0; q--) {
    Ins* x = l->v + q;
    if (pre(operand_text(x), "x18,")) {
      if (in(x->m, "ldr|ldur") && strchr(operand_text(x), '[') && !find_word(operand_text(x), "x18, lsl")) {
        out->type = 4;
        return 1;
      }
      break;
    }
  }
  if (j < 2)
    return general(l, j, f, out, why, n);
  Ins *p2 = l->v + j - 2, *p1 = l->v + j - 1;
  int T, B, I;
  if (!ldrsw(p2, &T, &B, &I) || T != 18 || I != 18 || !regadd(p1, 18, 18, B, 0))
    return general(l, j, f, out, why, n);
  if (B == 16 || B == 17) {
    snprintf(why, n, "%" PRIx64 " 相对表基址在 x%d（经典改写块借用的寄存器）", (uint64_t)l->v[j].at,
             B);
    return 0;
  }
  A tbl = 0;
  int cnt = 0;
  for (int q = j - 3; q >= 0; q--)
    if (regimm(l->v + q, "add", B, B)) {
      for (int p = q - 1; p >= MAX(0, q - 6); p--)
        if (eq(l->v[p].m, "adrp") && rno(l->v + p, 0) == B) {
          tbl = detail(&l->v[p])->operands[1].imm + detail(&l->v[q])->operands[2].imm;
          break;
        }
      if (tbl)
        break;
    }
  for (int q = j - 3; q > MAX(0, j - 8); q--)
    if (regimm(l->v + q, "cmp", 18, -1) && pre(operand_text(&l->v[q]), "w18,") && eq(l->v[q + 1].m, "b.hi")) {
      cnt = detail(&l->v[q])->operands[1].imm + 1;
      break;
    }
  if (!tbl || !cnt)
    return general(l, j, f, out, why, n);
  for (int i = 0; i < cnt; i++) {
    A t = tbl + si(tbl + 4LL * i);
    if (t < f.a || t >= f.b || t % 4) {
      snprintf(why, n, "jump table %" PRIx64 " 第 %d 项目标 0x%" PRIx64 " 不在函数内",
               (uint64_t)l->v[j].at, i, (uint64_t)t);
      return 0;
    }
  }
  AV tg = targets(l);
  if (has(&tg, p1->at) || has(&tg, l->v[j].at)) {
    snprintf(why, n, "branch into rel jump window %" PRIx64, (uint64_t)l->v[j].at);
    return 0;
  }
  out->type = 2;
  out->at = p2->at;
  out->B = B;
  out->tbl = tbl;
  out->count = cnt;
  for (int q = j - 2; q <= j; q++)
    PUSH(out->span, l->v[q].at);
  return 1;
}
static int jt_targets(const IV* l, int j, AV* out) {
  int lo = MAX(0, j - 16), add = -1, ld = -1, B = -1, I = -1;
  for (int q = j - 1; q >= lo; q--) {
    int r = rno(l->v + q, 2);
    if (r >= 0 && regadd(l->v + q, 18, 18, r, 0)) {
      add = q;
      B = r;
      break;
    }
  }
  if (add < 0)
    return 0;
  for (int q = j - 1; q >= lo; q--) {
    int t, b, i;
    if (ldrsw(l->v + q, &t, &b, &i) && t == 18 && b == B) {
      ld = q;
      I = i;
      break;
    }
  }
  if (ld < 0 || ld > add)
    return 0;
  uint64_t idx = BIT(I);
  int masked = -1, maskpos = -1, ci = -1;
  A mask = 0;
  for (int q = ld - 1; q >= lo; q--) {
    Ins* x = l->v + q;
    int r = rno(x, 0), s = rno(x, 1);
    if (eq(x->m, "mov") && r >= 0 && s >= 0 && pre(operand_text(x), "w") && (idx & BIT(r))) {
      idx |= BIT(s);
      continue;
    }
    if (eq(x->m, "and") && r >= 0 && s >= 0 && detail(x)->op_count == 3 &&
        detail(x)->operands[2].type == ARM64_OP_IMM && (idx & BIT(r)) && masked < 0) {
      masked = s;
      mask = detail(x)->operands[2].imm;
      maskpos = q;
      continue;
    }
    if (!eq(x->m, "cmp") || r < 0 || !pre(operand_text(x), "w") || detail(x)->operands[1].type != ARM64_OP_IMM)
      continue;
    if (idx & BIT(r)) {
      ci = q;
      break;
    }
    if (masked >= 0) {
      for (int p = q - 1; p >= lo; p--)
        if (writes(l->v + p, r)) {
          Ins* y = l->v + p;
          int good = eq(y->m, "and") && rno(y, 1) == masked && detail(y)->op_count == 3 &&
                     detail(y)->operands[2].type == ARM64_OP_IMM && detail(y)->operands[2].imm == mask;
          for (int z = p + 1; good && z < maskpos; z++)
            if (writes(l->v + z, masked))
              good = 0;
          if (good)
            ci = q;
          break;
        }
      if (ci >= 0)
        break;
    }
  }
  if (ci < 0)
    return 0;
  int n = 0;
  for (int q = ci + 1; q < ld; q++) {
    if (in(l->v[q].m, "b.hi|b.hs")) {
      n = detail(&l->v[ci])->operands[1].imm + eq(l->v[q].m, "b.hi");
      break;
    }
    if (isbr(l->v + q))
      break;
  }
  A tbl;
  if (!n || !chain(l, ld, B, 256, &tbl, NULL))
    return 0;
  REQUIRE(n > 0 && n < INT_MAX / 4);
  for (int i = 0; i < n; i++) {
    A t = tbl + si(tbl + 4LL * i);
    PUSH(*out, t);
  }
  return 1;
}
/* Static predecessor traversal for table base recovery. No path is invented
 * for a block that is only reachable through another indirect jump table. */
static void reachdefs_edge(const IV* l, int dst, int r, int q, int* seen, AV* result, AV* todo,
                           int* count) {
  if (q < 0 || (size_t)q >= l->n)
    return;
  Ins* x = l->v + q;
  int edge = (direct(x) && !eq(x->m, "bl") && target(x) == l->v[dst].at) ||
             (q + 1 == dst && !in(x->m, "b|br|ret"));
  if (!edge)
    return;
  (*count)++;
  if (seen[q])
    return;
  seen[q] = 1;
  if (writes(x, r)) {
    if (!contains(result, q))
      PUSH(*result, q);
  } else {
    if (q == 0 && !contains(result, -1))
      PUSH(*result, -1);
    PUSH(*todo, (A)q);
  }
}
static AV reachdefs(const IV* l, int k, int r) {
  AV result = {0}, todo = {0};
  int* seen = zalloc(l->n * sizeof(int));
  if (k == 0)
    PUSH(result, -1);
  PUSH(todo, k);
  while (todo.n) {
    int dst = (int)todo.v[--todo.n];
    int count = 0;
    if (fn_indexed(l)) {
      A at = l->v[dst].at;
      size_t i = upper(&g->ftg, at);
      if (i && g->ftg.v[i - 1] == at)
        for (size_t e = g->fsrc_at[i - 1]; e < g->fsrc_at[i]; e++)
          reachdefs_edge(l, dst, r, g->fsrc[e], seen, &result, &todo, &count);
      if (dst > 0) {
        int q = dst - 1;
        Ins* x = l->v + q;
        if (!(direct(x) && !eq(x->m, "bl") && target(x) == at))
          reachdefs_edge(l, dst, r, q, seen, &result, &todo, &count);
      }
    } else {
      for (size_t q = 0; q < l->n; q++)
        reachdefs_edge(l, dst, r, (int)q, seen, &result, &todo, &count);
    }
    if (!count && dst != k && !contains(&result, -1))
      PUSH(result, -1);
  }
  release(seen);
  release(todo.v);
  return result;
}
/* One shared visited set and value union computes copy propagation through
 * cycles. A revisited definition contributes no new value; unknowns still fail. */
static int reg_vals(const IV* l, int k, int r, int depth, Mask* seen, AV* vals, char** why) {
  AV rd = reachdefs(l, k, r);
  sort(&rd);
  if (rd.n == 1 && rd.v[0] == -1) {
    *why = format("表基址 x%d 沿控制流往回到函数头都没写（0x%" PRIx64 " 起）", r, (uint64_t)l->v[0].at);
    release(rd.v);
    return 0;
  }
  for (size_t i = 0; i < rd.n; i++) {
    if (rd.v[i] < 0)
      continue;
    int ka = (int)rd.v[i];
    if (seen[ka] & BIT(r))
      continue;
    seen[ka] |= BIT(r);
    Ins* x = l->v + ka;
    int src = rno(x, 1);
    if (eq(x->m, "mov") && detail(x)->op_count == 2 && rno(x, 0) == r && src >= 0 &&
        pre(operand_text(x), "x")) {
      if (depth <= 0) {
        *why = format("表基址 x%d 的到达定义 0x%" PRIx64 " mov %s 拷贝链超过 16 层",
                      r, (uint64_t)x->at, operand_text(x));
        release(rd.v);
        return 0;
      }
      char* nested = NULL;
      if (!reg_vals(l, ka, src, depth - 1, seen, vals, &nested)) {
        *why = format("表基址 x%d 的到达定义 0x%" PRIx64 " mov %s：%s",
                      r, (uint64_t)x->at, operand_text(x), nested);
        release(nested);
        release(rd.v);
        return 0;
      }
      continue;
    }
    if (!regimm(x, "add", r, r) || !pre(operand_text(x), "x")) {
      *why = format("表基址 x%d 的到达定义 0x%" PRIx64 " %s %s 不是 add x%d,x%d,#lo 或 mov 拷贝",
                    r, (uint64_t)x->at, x->m, operand_text(x), r, r);
      release(rd.v);
      return 0;
    }
    int p = -1;
    for (int q = ka - 1; q > MAX(-1, ka - 64); q--) {
      if (isbr(l->v + q))
        break;
      if (writes(l->v + q, r)) {
        if (eq(l->v[q].m, "adrp") && rno(l->v + q, 0) == r)
          p = q;
        break;
      }
    }
    if (p < 0) {
      *why = format("表基址 x%d 的到达定义 0x%" PRIx64 " 前同块没有 adrp x%d",
                    r, (uint64_t)x->at, r);
      release(rd.v);
      return 0;
    }
    PUSH(*vals, detail(&l->v[p])->operands[1].imm + detail(x)->operands[2].imm);
  }
  release(rd.v);
  return 1;
}
static int reg_const(const IV* l, int k, int r, A* tbl, char** why) {
  AV vals = {0};
  Mask* seen = zalloc(l->n * sizeof(*seen));
  if (!reg_vals(l, k, r, 16, seen, &vals, why)) {
    release(seen);
    release(vals.v);
    return 0;
  }
  sort(&vals);
  if (vals.n != 1) {
    REQUIRE(vals.n <= (SIZE_MAX - 1) / 22);
    char* values = zalloc(vals.n * 22 + 1);
    size_t used = 0;
    for (size_t i = 0; i < vals.n; i++) {
      A value = vals.v[i];
      used += snprintf(values + used, vals.n * 22 + 1 - used, "%s%s0x%" PRIx64,
                       i ? ", " : "", value < 0 ? "-" : "",
                       value < 0 ? 0 - (uint64_t)value : (uint64_t)value);
    }
    *why = format("表基址 x%d 有 %zu 个不同的到达值（%s）", r, vals.n,
                  vals.n ? values : "拷贝链成环、没有常量来源");
    release(values);
    release(seen);
    release(vals.v);
    return 0;
  }
  *tbl = vals.v[0];
  release(seen);
  release(vals.v);
  return 1;
}
/* Preserve linear recovery before the CFG copy-propagation fallback. */
static int jt_base(const IV* l, int k, int r, A* tbl, char** why) {
  int lo = MAX(0, k - 256), a = def(l, k, lo, r);
  *why = NULL;
  if (a >= 0 && regimm(l->v + a, "add", r, r) && pre(operand_text(&l->v[a]), "x") &&
      chain(l, k, r, 256, tbl, NULL))
    return 1;
  return reg_const(l, k, r, tbl, why);
}
static int open_read(A tbl, A base, Pair f, AV* out) {
  for (int i = 0; i < 1024 && tbl + 4LL * i >= 0 && (uint64_t)(tbl + 4LL * i) + 4 <= g->len; i++) {
    A t = base + si(tbl + 4LL * i);
    if (t < f.a || t >= f.b || t % 4)
      break;
    PUSH(*out, t);
  }
  return out->n > 0 && out->n < 1024;
}
static int jt_open(const IV* l, int j, Pair f, AV* out, char** why) {
  AV tg = targets(l);
  int k = j - 1;
  while (k >= 0 && !writes(l->v + k, 18)) {
    if (isbr(l->v + k) || has(&tg, l->v[k + 1].at))
      return 0;
    k--;
  }
  if (k < 0 || has(&tg, l->v[k + 1].at))
    return 0;
  Ins* x = l->v + k;
  int r1 = rno(x, 1), r2 = rno(x, 2);
  if (r1 < 0 || r2 < 0 || !regadd(x, 18, r1, r2, 0))
    return 0;
  int ld = -1, T = -1, B = -1;
  for (int q = k - 1; q >= 0; q--) {
    Ins* y = l->v + q;
    if (isbr(y) || has(&tg, l->v[q + 1].at))
      return 0;
    int t, b, i;
    if (ldrsw(y, &t, &b, &i) && ((t == r1 && b == r2) || (t == r2 && b == r1))) {
      ld = q;
      T = t;
      B = b;
      break;
    }
    if (writes(y, r1) || writes(y, r2))
      return 0;
  }
  if (ld < 0 || T == B || B == 18)
    return 0;
  for (int q = ld + 1; q < k; q++)
    if (writes(l->v + q, T) || writes(l->v + q, B))
      return 0;
  A tbl;
  if (!jt_base(l, ld, B, &tbl, why))
    return 0;
  return open_read(tbl, tbl, f, out);
}
static int jt_adr(const IV* l, int j, Pair f, AV* out) {
  AV tg = targets(l);
  int lo = j;
  for (int q = j - 1; q >= 0; q--) {
    if (isbr(l->v + q) || has(&tg, l->v[q + 1].at))
      break;
    lo = q;
  }
  int a = def(l, j, lo, 18);
  if (a < 0)
    return 0;
  Ins* x = l->v + a;
  int T = rno(x, 2);
  if (T < 0 || !regadd(x, 18, 18, T, 0))
    return 0;
  int d = def(l, a, lo, 18);
  if (d < 0 || !eq(l->v[d].m, "adr") || rno(l->v + d, 0) != 18)
    return 0;
  A L = detail(&l->v[d])->operands[1].imm;
  int ld = def(l, a, lo, T);
  if (ld < 0)
    return 0;
  int t, B, I;
  if (!ldrsw(l->v + ld, &t, &B, &I) || t != T || B == 18 || B == T)
    return 0;
  A tbl;
  char* why = NULL;
  if (!jt_base(l, ld, B, &tbl, &why))
    return 0;
  return open_read(tbl, L, f, out);
}
static int win_index(const WV* w, A a, int* head) {
  *head = 0;
  for (size_t k = 0; k < w->n; k++)
    for (size_t s = 0; s < w->v[k].seg.n; s++) {
      IV* l = &w->v[k].seg.v[s].ins;
      for (size_t i = 0; i < l->n; i++)
        if (l->v[i].at == a) {
          *head = i == 0;
          return k;
        }
    }
  return -1;
}
static void analyze(void) {
  VEC(Pair) funcs = {0};
  for (size_t i = 0; i < g->sites.n; i++)
    if (eq(g->sites.v[i].kind, "x18")) {
      Pair f = func_of(g->sites.v[i].at);
      PUSH(funcs, f);
    }
  if (funcs.n > 1)
    qsort(funcs.v, funcs.n, sizeof(Pair), cmppair);
  for (size_t fi = 0; fi < funcs.n; fi++) {
    Pair f = funcs.v[fi];
    if (fi && f.a == funcs.v[fi - 1].a && f.b == funcs.v[fi - 1].b)
      continue;
    REQUIRE(f.a >= 0 && f.b >= f.a && (uint64_t)f.b <= g->len);
    IV l = {0};
    size_t nins = (size_t)((f.b - f.a) / 4);
    REQUIRE(nins <= SIZE_MAX / sizeof(*l.v));
    if (nins) {
      l.v = resize(NULL, nins * sizeof(*l.v));
      l.cap = nins;
    }
    for (A a = f.a; a + 4 <= f.b; a += 4) {
      Ins x;
      /* 函数中间解不出的字（未分配编码，执行即陷入，如 0xe7ffdefe：编译器放在不返回的调用之后）按 udf #0 记，函数照样往下读：
       * 以前遇到就停，之后的 br x18 全没进跳转分析、落到 gensite 的 dynbr——拿 x16 / x17 当临时寄存器取目标，而函数内跳转表处
       * 它们常是活寄存器（朋友收集 梦想生活 main 0x136d0b4 / 0x136d140：x16 循环指针、w17 比较值，跳过去后 x16 = 目标地址，
       * 循环永不结束，11-04 维护者 手测卡加载）。udf #0 与原字一样陷入、不读写寄存器、不是跳转，块划分与寄存器分析都不受影响 */
      if (!decode(iw(a), a, &x)) {
        REQUIRE(decode(0, a, &x));
        x.w = iw(a);
      }
      PUSH(l, x);
    }
    g->ftg = targets(&l);
    g->ftg_of = l.v;
    g->ftg_n = l.n;
    fn_index(&l);
    WV ws = find_windows(&l);
    for (size_t k = 0; k < ws.n; k++) {
      PUSH(g->windows, ws.v[k]);
      for (size_t s = 0; s < ws.v[k].seg.n; s++)
        for (size_t i = 0; i < ws.v[k].seg.v[s].ins.n; i++)
          done(ws.v[k].seg.v[s].ins.v[i].at);
    }
    for (size_t j = 0; j < l.n; j++)
      if (eq(l.v[j].m, "br") && eq(operand_text(&l.v[j]), "x18")) {
        Jump jump = {0};
        jump.at = l.v[j].at;
        char why[600] = {0};
        if (!classify(&l, j, f, &jump, why, sizeof(why))) {
          jump = (Jump){0};
          jump.at = l.v[j].at;
          AV t = {0};
          char* jtwhy = NULL;
          int ok = jt_targets(&l, j, &t), op = 0;
          if (!ok) {
            t = (AV){0};
            ok = jt_open(&l, j, f, &t, &jtwhy);
            if (ok)
              op = 1;
          }
          if (!ok) {
            t = (AV){0};
            ok = jt_adr(&l, j, f, &t);
            if (ok)
              op = 1;
          }
          int bad = 0;
          for (size_t k = 0; k < t.n; k++)
            if (t.v[k] < f.a || t.v[k] >= f.b || t.v[k] % 4)
              bad++;
          if (ok && t.n && !bad) {
            jump.type = 5;
            jump.targets = t;
            jump.open = op;
          } else {
            /* 目标集也认不出：最后才试借 x9–x15 的相对表改写（排在目标集之后，已有形态的产物不变） */
            Jump retry = {0};
            char why2[600] = {0};
            retry.at = jump.at;
            retry.x1617_ok = 1;
            if (!bad && classify(&l, j, f, &retry, why2, sizeof(why2)) && retry.uses_x16x17) {
              jump = retry;
              goto recognized;
            }
            if (bad)
              gap(jump.at, "br_x18", "%s；目标集识别有 %d 项出函数", why, bad);
            else if (jtwhy)
              gap(jump.at, "br_x18", "%s；目标集识别也认不出（%s）", why, jtwhy);
            else
              gap(jump.at, "br_x18", "%s；目标集识别也认不出", why);
            done(jump.at);
            continue;
          }
        }
      recognized:
        if (jump.type == 4)
          done(jump.at);
        else if (jump.type == 2 || jump.type == 3)
          for (size_t k = 0; k < jump.span.n; k++)
            done(jump.span.v[k]);
        PUSH(g->jumps, jump);
      }
    for (size_t i = 0; i < l.n; i++)
      if (direct(l.v + i)) {
        int h, hh;
        A t = target(l.v + i);
        int dst = win_index(&ws, t, &h), src = win_index(&ws, l.v[i].at, &hh);
        if (dst >= 0 && !h && src != dst)
          gap(l.v[i].at, "window", "branch into window %" PRIx64 " → 0x%" PRIx64,
              (uint64_t)l.v[i].at, (uint64_t)t);
      }
    for (size_t j = 0; j < g->jumps.n; j++) {
      Jump* x = g->jumps.v + j;
      if (x->type != 5 || x->at < f.a || x->at >= f.b)
        continue;
      int bad = 0;
      for (size_t i = 0; i < x->targets.n; i++) {
        int h;
        if (win_index(&ws, x->targets.v[i], &h) >= 0 && !h)
          bad = 1;
      }
      if (bad)
        gap(x->at, "window", "jump table target into window %" PRIx64, (uint64_t)x->at);
    }
    g->ftg_of = NULL;
    release(g->ftg.v);
    release(g->fsrc_at);
    release(g->fsrc);
    g->ftg = (AV){0};
    g->fsrc_at = NULL;
    g->fsrc = NULL;
    release(l.v);
    release(ws.v);
  }
  /* jump_at 的二分索引：跳转只在上面加 */
  g->jidx.n = 0;
  for (size_t i = 0; i < g->jumps.n; i++) {
    Pair e = {g->jumps.v[i].at, (A)i};
    PUSH(g->jidx, e);
  }
  if (g->jidx.n > 1)
    qsort(g->jidx.v, g->jidx.n, sizeof(Pair), cmppair);
}
static Jump* jump_at(A at) {   /* 同地址多条时取下标最小的一条（同原先顺序扫的结果） */
  REQUIRE(g->jidx.n == g->jumps.n);
  size_t lo = 0, hi = g->jidx.n;
  while (lo < hi) {
    size_t m = lo + (hi - lo) / 2;
    if (g->jidx.v[m].a < at)
      lo = m + 1;
    else
      hi = m;
  }
  return lo < g->jidx.n && g->jidx.v[lo].a == at ? g->jumps.v + g->jidx.v[lo].b : NULL;
}
static void gensite(Site* s) {
  Ins x = dis(iw(s->at), s->at);
  int N = x.w & 31;
  /* 「恢复 sp 后还用 sp 以下数据」的函数里（sp_dynamic）：只有 x18 普通点走得通（plain → 挑死寄存器，不写 sp 以下）；
   *   别的生成器的块都会压 sp 以下，记缺口报红，不悄悄盖游戏数据（11-11 一款第一方动作游戏） */
  if (!noredzone() && sp_danger(s->at)) {
    int plainish = eq(s->kind, "x18") && !in(x.m, "br|blr|ret|b|bl") && !(eq(x.m, "ldr") && !strchr(operand_text(&x), '[')) &&
                   !pre(operand_text(&x), "sp, ") && !pre(operand_text(&x), "wsp, ");
    if (eq(s->kind, "x18") && in(x.m, "cbz|cbnz|tbz|tbnz")) {
      int S, T, V;
      plainish = pick_dead_gp2(&x, x.at + 4, target(&x), LV_BUDGET, &S, &T, &V) != 0;
    } else if (eq(s->kind, "x18") && in(x.m, "adr|adrp")) {
      int S, T, V;
      plainish = pick_dead_gp2(&x, x.at + 4, -1, LV_BUDGET, &S, &T, &V) != 0;
    }
    if (!plainish)   /* 别的生成器 / 挑不出临时：照旧写法生成（压栈），记兼容写法（v0.3.1 拿不准不停；cond / pcrel 走旧路时不另计） */
      bump("x18_compat");
  }
  if (N == 18 && (eq(s->kind, "tpidr_r") || eq(s->kind, "tpidrro_r"))) {
    /* 目标是 x18（#52 鬼灭之刃 2 main+0x23f5ec0 mrs x18, tpidr_el0）：线程指针取到临时寄存器，写进虚拟 x18 槽（slot 0，同 plain） */
    int S, T, U = -1;
    pick(BIT(18), &S, &T);
    for (int r = 0; r < 16 && U < 0; r++)
      if (r != S && r != T)
        U = r;
    if (noredzone()) {
      emit(SUBI(31, 31, 32, 0));
      emit(STP(S, T, 31, 0));
      emit(STUR(U, 31, 16));
    } else {
      emit(STP(S, T, 31, -16));
      emit(STUR(U, 31, -24));
    }
    tp(T, U);
    slot(T, U, eq(s->kind, "tpidr_r") ? 1 : 2);
    emit(LDR(S, T, 0));
    tp(T, U);
    slot(T, U, 0);
    emit(STR(S, T, 0));
    if (noredzone()) {
      emit(LDUR(U, 31, 16));
      emit(LDP(S, T, 31, 0));
      emit(ADDI(31, 31, 32, 0));
    } else {
      emit(LDUR(U, 31, -24));
      emit(LDP(S, T, 31, -16));
    }
    emit(branch(here(), s->at + 4));
    bump(s->kind);
    return;
  }
  if (in(s->kind, "cntpct|cntvct|ctr|tpidr_w") && N == 18)
    fail("RuntimeError: %" PRIx64 " %s %s：系统寄存器读写的 x18 须走线程槽，块未实现",
         (uint64_t)s->at, x.m, operand_text(&x));
  if (eq(s->kind, "x18")) {
    if (eq(x.m, "br")) {
      Jump* j = jump_at(s->at);
      /* 跳转分析逐字读完每个含 x18 改写点的函数，每个 br x18 要么登记 Jump、要么记缺口并标 done，走到这里没有 Jump = 分析漏点。
       * 11-01 35f42e14a 起这里按 dynbr 兜底：借 x16 / x17 取目标，目标未知也照跳。漏掉的点（朋友收集 梦想生活 0x136d0b4 / 0x136d140：
       * 函数中间解不出的字截断了分析）x16 循环指针、w17 比较值被盖，加载页死循环，产物静默错。目标未知时借用安全证明不了
       * （落点可能是本函数任一处、也可能落进多指令改写窗口中间），所以不兜底：报错、出包停下 */
      if (!j)
        fail("RuntimeError: %" PRIx64 " br x18 没经过跳转分析（分析漏点）：目标未知，不能借 x16/x17 兜底", (uint64_t)s->at);
      if (j->type == 5) {
        brtab(j);
        bump("br_tab");
        if (j->open)
          bump("br_tab_open");
      } else if (j->type == 1) {
        brcompact(j);
        bump("br");
      } else {
        dynbr(&x, 0);
        bump("br");
      }
    } else if (in(x.m, "cbz|cbnz|tbz|tbnz")) {
      cond(&x);
      bump("cond");
    } else if (in(x.m, "adr|adrp")) {
      pcrel(&x);
      bump("pcrel");
    } else if (eq(x.m, "blr") && eq(operand_text(&x), "x18")) {
      dynbr(&x, 1);
      bump("blr");
    } else if (in(x.m, "blr|ret|b|bl") || (eq(x.m, "ldr") && !strchr(operand_text(&x), '[')))
      fail("RuntimeError: %" PRIx64 " %s %s", (uint64_t)s->at, x.m, operand_text(&x));
    else if (pre(operand_text(&x), "sp, ") || pre(operand_text(&x), "wsp, ")) {
      spfrom18(&x);
      bump("sp18");
    } else {
      plain(&x);
      bump("plain");
    }
  } else if (eq(s->kind, "tpidr_r") || eq(s->kind, "tpidrro_r")) {
    int tmp = N == 16 ? 17 : 16;
    emit(noredzone() ? STRPRE(tmp, 31, -16) : STUR(tmp, 31, -16));
    tp(N, tmp);
    slot(N, tmp, eq(s->kind, "tpidr_r") ? 1 : 2);
    emit(LDR(N, N, 0));
    emit(noredzone() ? LDRPOST(tmp, 31, 16) : LDUR(tmp, 31, -16));
    emit(branch(here(), s->at + 4));
    bump(s->kind);
  } else if (eq(s->kind, "tpidr_w")) {
    int T, tmp, unused;
    pick(BIT(N), &T, &unused);
    tmp = N != 16 && T != 16 ? 16 : 17;
    if (noredzone())
      emit(STPRE(T, tmp, 31, -16));
    else {
      emit(STUR(T, 31, -16));
      emit(STUR(tmp, 31, -24));
    }
    tp(T, tmp);
    slot(T, tmp, 1);
    emit(STR(N, T, 0));
    if (noredzone())
      emit(LDPOST(T, tmp, 31, 16));
    else {
      emit(LDUR(tmp, 31, -24));
      emit(LDUR(T, 31, -16));
    }
    emit(branch(here(), s->at + 4));
    bump(s->kind);
  } else if (eq(s->kind, "ctr")) {
    emit(MOVZ(N, 0xc004, 0));
    emit(MOVK(N, 0x8444, 1));
    emit(branch(here(), s->at + 4));
    bump(s->kind);
  } else {
    gate(&x, s->kind, s->arg);
    bump(s->kind);
  }
}
/* Guarding uses the same rollback boundaries as the Python oracle. */
static void gen_window(void* w) {
  window_emit(w);
  bump("window");
  if (((Window*)w)->seg.n > 1)
    bump("window_head");
}
static void gen_jump(void* p) {
  Jump* j = p;
  A start = here();
  if (j->type < 4)
    brrel(j);
  else {
    Ins x = dis(iw(j->at), j->at);
    dynbr(&x, 0);
  }
  put(j->at, branch(j->at, start));
  bump(j->type == 2 ? "br_rel" : j->type == 3 ? "br_relg" : "br_tail");
}
static void gen_site(void* p) {
  Site* s = p;
  A start = here();
  gensite(s);
  put(s->at, branch(s->at, start));
}
/* 两岛都够不着时可在 SIGTRAP 里按原语义模拟的必改点（与 gensite 生成的块同语义：读写线程槽 KTLS / KTLR、ctr 常数）；x18 目的不收（块也不收） */
#define TRAP_IMM0 0x8000
#define TRAP_MAX 0x2000 /* brk #0x8000–0x9FFF；0xA000 是远跳（FAR_IMM），macOS 截走 0xB000–0xBFFF */
static int trap_site(Site* s) {
  if (!g->dual || !g->range_err || !in(s->kind, "tpidr_r|tpidrro_r|tpidr_w|ctr"))
    return 0;
  uint32_t w = iw(s->at);
  if ((w & 31) == 18 || g->traps.n >= TRAP_MAX)
    return 0;
  Trap t = {s->at, s->kind, (int)(w & 31), w};
  put(s->at, 0xd4200000u | ((uint32_t)(TRAP_IMM0 + g->traps.n) << 5));
  PUSH(g->traps, t);
  bump("trap");
  return 1;
}
/* 两岛都越射程的 x18 窗口 / 改写点 / 尾调用跳转：远跳模式重做一次（见 Far）。只给这几类：它们的块里没有 BL（远跳不带返回地址） */
static int far_unit(A at, void (*fn)(void*), void* arg) {
  if (!g->dual || !g->range_err)
    return 0;
  g->farjump = 1;
  int ok = unit_run(at, fn, arg, NULL);
  g->farjump = 0;
  if (ok)
    bump("far");
  return ok;
}
static void generate(void) {
  g->guarding = 1;
  for (size_t i = 0; i < g->windows.n; i++) {
    Window* w = g->windows.v + i;
    if (!unit_run(w->seg.v[0].ins.v[0].at, gen_window, w, NULL) && !far_unit(w->seg.v[0].ins.v[0].at, gen_window, w))
      gap(w->seg.v[0].ins.v[0].at, "window", "AssertionError: %s", g->error);
  }
  for (int type = 2; type <= 4; type++)
    for (size_t i = 0; i < g->jumps.n; i++) {
      Jump* j = g->jumps.v + i;
      if (j->type != type)
        continue;
      /* 尾调用（type 4）的块以寄存器跳转结束、不回原位、没有 BL：两岛都够不着时同 x18 窗口 / 改写点走远跳（#283 Core Keeper main 约 385 MB，
       * 两处 br_tail 离两个补丁岛都超 ±128 MB，原先直接记缺口、整款出不了包） */
      if (!unit_run(j->at, gen_jump, j, NULL) && !(type == 4 && far_unit(j->at, gen_jump, j)))
        gap(j->at, type == 2 ? "br_rel" : type == 3 ? "br_relg" : "br_tail", "AssertionError: %s", g->error);
    }
  for (size_t i = 0; i < g->sites.n; i++) {
    Site* s = g->sites.v + i;
    if (s->done)
      continue;
    if (!unit_run(s->at, gen_site, s, NULL) && !trap_site(s) && !(eq(s->kind, "x18") && far_unit(s->at, gen_site, s)))
      gap(s->at, s->kind, "%s%s",
          pre(g->error, "RuntimeError:") ? "" : "AssertionError: ", g->error);
  }
  g->guarding = 0;
}
/* Resolve the exported SDK function through MOD0 / .dynamic. Keep all reads
 * bounded; absent exports mean there is no aregion hook to install. */
static int dynsym(const char* name, A* value, A* size) {
  A m0 = iw(4), dyn = m0 + si(m0 + 4);
  REQUIRE(dyn >= 0 && (uint64_t)dyn <= g->len);
  A st = -1, sy = -1;
  A end = MIN(dyn + 0x400 * 16, (A)g->len - 16);
  for (A at = dyn; at < end; at += 16) {
    uint64_t tag = iu64(at), v = iu64(at + 8);
    if (!tag)
      break;
    if ((tag == 5 && st < 0) || (tag == 6 && sy < 0)) {
      REQUIRE(v <= g->len);
      if (tag == 5) st = (A)v;
      else sy = (A)v;
    }
  }
  if (st < 0 || sy < 0 || sy >= st)
    return 0;
  size_t n = strlen(name) + 1;
  for (A at = sy; at < st; at += 24) {
    REQUIRE((uint64_t)at + 24 <= g->len);
    uint32_t nm = iw(at);
    uint64_t val = iu64(at + 8), sz = iu64(at + 16);
    if ((iw(at + 4) >> 16) && val && (uint64_t)st + nm <= g->len &&
        n <= g->len - ((size_t)st + nm) && !memcmp(g->img + st + nm, name, n)) {
      if (val <= g->text && sz < 0x4000 && sz > 0 && sz <= g->text - val) {
        *value = (A)val;
        *size = (A)sz;
        return 1;
      }
      return 0;
    }
  }
  return 0;
}
static void gen_aregion(void* p) {
  A at = *(A*)p, start = here();
  emit(STPRE(29, 30, 31, -16));
  gatecall();
  emit(BLR(30));
  Gate q = {here(), at, "aregion", 0};
  PUSH(g->gates, q);
  emit(LDPOST(29, 30, 31, 16));
  emit(0xd65f03c0);
  put(at, branch(at, start));
  done(at);
  bump("sdk_aregion_ret");
}
static void sdk_aregion(void) {
  A value, size;
  if (!g->sdk_cut ||
      !dynsym("_ZN2nn2os6detail11VammManager21AllocateAddressRegionEPmm", &value, &size))
    return;
  g->guarding = 1;
  for (A at = value; at < value + size; at += 4) {
    Ins x;
    if (at + 4 > value + size || !decode(iw(at), at, &x))
      break;
    if (!eq(x.m, "ret") || operand_text(&x)[0] || consumed(at))
      continue;
    if (!unit_run(at, gen_aregion, &at, NULL))
      gap(at, "aregion", "AssertionError: %s", g->error);
  }
  g->guarding = 0;
}
/* Wide-screen recipe input is explicit; the library never discovers game data. */
/* 帧率表改指令（S2A_FPS_TSV = 产物根里的 fps.tsv，帧率能耗线 10-26；体系提升方案 D）：按构建号把社区资料指出的位置按语义改成我方的写法，
 * 改前核原字（本模块有一行不符就整组不改、记黄，见 fps_precheck）。行：c <模块> <偏移> <种类> <原字> [参数…]，种类：
 *   word <新字>                  原位换一条指令（如去双缓冲 mov w1, #1）
 *   adrp_slot <Xn>               原位写 adrp Xn, <本模块键页>
 *   ldr_slot <St> <Xn> <槽>      原位写 ldr St, [Xn, #槽×8]（32 位浮点；槽里的值由宿主 runtime/src/fps.c 填）
 *   bl_rec <Wt> <槽>             原 bl 改成「把 Wt（32 位）记进槽、再跳原目标」（补丁区跳板，x16 作临时：调用点上 IP0 本可被改写）。
 *                                用 STR Wt 不用 STRB：STRB 的偏移按字节、最大 4095，够不着键页尾部的槽（槽 2042 = +0x3fd0，10-26 反汇编核出编成了 LDRSB）
 *   veneer <体字1> … <体字n>      原位改成 B 跳板，跳板依次是这 n 条指令字、再接 b <偏移+4>（补丁区，同 bl_rec 生成）。体字须与位置无关：
 *                                不许 B / BL / ADR / ADRP / 字面量 LDR；条件跳（B.cond / CBZ / CBNZ / TBZ / TBNZ）只许落在跳板内（含末尾那条回跳），
 *                                原位那条指令的语义由表自己写进体字（如旷野之息镜头过渡首帧：首步乘 max(比率, 1)）。n 为 1–16。
 *                                两个记号由生成器按跳板位置编码：adrp:x<n> = adrp Xn, <本模块键页>（跳板里读键页槽）；
 *                                bl:<偏移> = bl <本模块偏移>（如王国之泪布料时钟：调用点先改参数再调原函数，原函数返回到跳板、跳板再回原位下一条）
 * 槽只许键页尾部 2032–2047（宽屏占 16–2031，runtime/src/widen.c）。前三种在分析前改（后面的分析看到的就是改好的代码），bl_rec 与宽屏点同在生成之后 */
#define FPS_SLOT_LO 2032
#define FPS_SLOT_HI 2047
typedef struct {
  A off, target;
  int wt, slot;
} BlRec;
static void gen_blrec(void* p) {
  BlRec* b = p;
  A start = here();
  emit(adrp(16, here(), g->key));
  emit(0xb9000000u | ((uint32_t)(b->slot * 2) << 10) | (16u << 5) | (uint32_t)b->wt); /* STR Wt, [X16, #slot*8]（imm12 按 4 字节缩放） */
  emit(branch(here(), b->target));
  put(b->off, branch(b->off, start) | 0x80000000u); /* BL 跳板：返回地址仍是原 bl 的下一条 */
}
#define FPS_VEN_MAX 16
typedef struct {
  A off;
  int n;
  uint32_t w[FPS_VEN_MAX];
  char kind[FPS_VEN_MAX]; /* 0 = 原样；'a' = adrp:x<w>（w 存寄存器号）；'l' = bl:<w>（w 存目标偏移） */
} FpsVeneer;
static void gen_fps_veneer(void* p) {
  FpsVeneer* v = p;
  A start = here();
  for (int i = 0; i < v->n; i++)
    emit(v->kind[i] == 'a' ? adrp((int)v->w[i], here(), g->key) : v->kind[i] == 'l' ? branch(here(), (A)v->w[i]) | 0x80000000u : v->w[i]);
  emit(branch(here(), v->off + 4));
  put(v->off, branch(v->off, start)); /* B，不是 BL：跳板末尾自己跳回原位下一条 */
}
/* 体字 i（共 n 条）能不能原样搬进跳板：与位置无关的指令照搬；条件跳只许落在 [0, n]（n = 末尾的回跳）。不行返回原因 */
static const char* fps_ven_check(uint32_t w, int i, int n) {
  if ((w & 0x7c000000u) == 0x14000000u) return "B / BL";
  if ((w & 0x1f000000u) == 0x10000000u) return "ADR / ADRP";
  if ((w & 0x3b000000u) == 0x18000000u) return "字面量 LDR";
  int64_t d = 0;
  if ((w & 0xff000010u) == 0x54000000u || (w & 0x7e000000u) == 0x34000000u) d = (int64_t)((int32_t)(w << 8)) >> 13; /* B.cond / CBZ / CBNZ：imm19 */
  else if ((w & 0x7e000000u) == 0x36000000u) d = (int64_t)((int32_t)(w << 13)) >> 18;                          /* TBZ / TBNZ：imm14 */
  else return NULL;
  return i + d < 0 || i + d > n ? "条件跳出了跳板" : NULL;
}
static int fps_reg(const char* s, char kind) {
  char* e;
  if (!s || s[0] != kind) return -1;
  long r = strtol(s + 1, &e, 10);
  return *e || r < 0 || r > 30 ? -1 : (int)r;
}
/* 改前先核本模块所有 c 行原字（在原始代码上、一次）：同表的行成组配合（word 跳过两条 + adrp_slot / ldr_slot 读槽），只改一半会拿游戏原来的寄存器当基址读、
 * 或步长读到垃圾值，所以全有或全无（原生层线 10-26 审出）。有一行不符：本模块的 c 行一行都不改，打一行 [黄] 列出不符的偏移、计 fps_orig_skip、不算缺口；
 * 表的运行时行（w / slot 等，runtime/src/fps.c）照常生效（维护者 10-26：版本对不上也要试，不整款放弃） */
static int fps_skip;
static int fps_precheck(FILE* f) {
  char line[512], bad[400] = "";
  int nbad = 0;
  while (fgets(line, sizeof(line), f)) {
    char* h = strchr(line, '#');
    if (h) *h = 0;
    char *t0 = strtok(line, " \t\r\n"), *mod = strtok(NULL, " \t\r\n"), *offs = strtok(NULL, " \t\r\n"), *kind = strtok(NULL, " \t\r\n"),
         *origs = strtok(NULL, " \t\r\n");
    if (!t0 || !eq(t0, "c") || !mod || !eq(mod, g->r.module) || !offs || !kind || !origs) continue;
    A off = strtoll(offs, NULL, 16);
    if (off < 0 || off % 4 || off + 4 > (A)g->text || iw(off) == (uint32_t)strtoul(origs, NULL, 16)) continue; /* 越界的行留给逐行处理记缺口 */
    size_t k = strlen(bad);
    if (k + 24 < sizeof(bad)) snprintf(bad + k, sizeof(bad) - k, "%s0x%llx", nbad ? " " : "", (unsigned long long)off);
    nbad++;
  }
  rewind(f);
  if (!nbad) return 0;
  fprintf(stderr, "[黄] %s 帧率表 %d 行原字不符（%s；版本不同或表错），本模块的改指令行整组不改\n", g->r.module, nbad, bad);
  bump("fps_orig_skip");
  return 1;
}
static void fps_rows(int phase) {
  const char* path = g->r.fps_tsv;
  if (!path || !*path) return;
  FILE* f = fopen(path, "rb");
  if (!f) {
    int error = errno;
    if (error != ENOENT) fail("无法打开帧率表：%s", strerror(error));
    msg("[黄] %s 帧率表不存在，跳过\n", g->r.module);
    return;
  }
  if (phase == 0) fps_skip = fps_precheck(f);
  if (fps_skip) { fclose(f); return; }
  char line[512];
  while (fgets(line, sizeof(line), f)) {
    char* h = strchr(line, '#');
    if (h) *h = 0;
    char *t0 = strtok(line, " \t\r\n"), *mod = strtok(NULL, " \t\r\n"), *offs = strtok(NULL, " \t\r\n"), *kind = strtok(NULL, " \t\r\n"),
         *origs = strtok(NULL, " \t\r\n"), *a1 = strtok(NULL, " \t\r\n"), *a2 = strtok(NULL, " \t\r\n"), *a3 = strtok(NULL, " \t\r\n");
    if (!t0 || !eq(t0, "c") || !mod || !eq(mod, g->r.module)) continue;
    if (!offs || !kind || !origs) { gap(0, "fps", "帧率表改指令行不全"); continue; }
    A off = strtoll(offs, NULL, 16);
    uint32_t orig = (uint32_t)strtoul(origs, NULL, 16);
    int tramp = eq(kind, "bl_rec") || eq(kind, "veneer");
    if (tramp != (phase == 1)) continue;
    if (off < 0 || off % 4 || off + 4 > (A)g->text) { gap(off, "fps", "%s 点不在代码段", kind); continue; }
    if (iw(off) != orig) { gap(off, "fps", "%s 点原字 0x%x，表里写的是 0x%x（核过整组后又被同表别的行改过）", kind, iw(off), orig); continue; }
    uint32_t nw;
    if (eq(kind, "word")) {
      if (!a1) { gap(off, "fps", "word 缺新字"); continue; }
      nw = (uint32_t)strtoul(a1, NULL, 16);
    } else if (eq(kind, "adrp_slot")) {
      int x = fps_reg(a1, 'x');
      if (x < 0) { gap(off, "fps", "adrp_slot 寄存器 %s 不认", a1 ? a1 : "-"); continue; }
      nw = adrp(x, off, g->key);
    } else if (eq(kind, "ldr_slot")) {
      int st = fps_reg(a1, 's'), x = fps_reg(a2, 'x'), slot = a3 ? atoi(a3) : -1;
      if (st < 0 || x < 0 || slot < FPS_SLOT_LO || slot > FPS_SLOT_HI) { gap(off, "fps", "ldr_slot 参数不认或槽 %d 不在 %d–%d", slot, FPS_SLOT_LO, FPS_SLOT_HI); continue; }
      nw = 0xbd400000u | ((uint32_t)(slot * 2) << 10) | ((uint32_t)x << 5) | (uint32_t)st; /* LDR St, [Xn, #slot*8]（imm12 按 4 字节缩放） */
    } else if (eq(kind, "veneer")) {
      FpsVeneer v = {off, 0, {0}, {0}};
      const char* why = NULL;
      for (char* t = a1; t && !why; t = v.n == 1 ? a2 : v.n == 2 ? a3 : strtok(NULL, " \t\r\n")) {
        if (v.n == FPS_VEN_MAX) { why = "体字超过 16 条"; break; }
        char* e;
        if (!strncmp(t, "adrp:", 5)) {
          int x = fps_reg(t + 5, 'x');
          if (x < 0) { why = "adrp: 后寄存器不认"; break; }
          v.kind[v.n] = 'a'; v.w[v.n++] = (uint32_t)x; continue;
        }
        if (!strncmp(t, "bl:", 3)) {
          unsigned long x = strtoul(t + 3, &e, 16);
          if (*e || e == t + 3 || x % 4 || x + 4 > (unsigned long)g->text) { why = "bl: 目标不在代码段"; break; }
          v.kind[v.n] = 'l'; v.w[v.n++] = (uint32_t)x; continue;
        }
        unsigned long x = strtoul(t, &e, 16);
        if (*e || x > 0xffffffffUL) { why = "体字不是 8 位十六进制"; break; }
        v.w[v.n++] = (uint32_t)x;
      }
      if (!why && !v.n) why = "没有体字";
      if (why) { gap(off, "fps", "veneer %s", why); continue; }
      int bad = -1;
      for (int i = 0; i < v.n && bad < 0; i++)
        if (!v.kind[i] && (why = fps_ven_check(v.w[i], i, v.n))) bad = i;
      if (bad >= 0) { gap(off, "fps", "veneer 第 %d 条体字 0x%08x 不能原样搬进跳板（%s）", bad + 1, v.w[bad], why); continue; }
      if (site_at(off) || consumed(off)) { gap(off, "fps", "veneer 点已是改写点"); continue; }
      g->guarding = 1;
      int ok = unit_run(off, gen_fps_veneer, &v, NULL);
      g->guarding = 0;
      if (!ok) { gap(off, "fps", "AssertionError: %s", g->error); continue; }
      done(off);
      bump("fps_veneer");
      continue;
    } else if (tramp) {
      int wt = fps_reg(a1, 'w'), slot = a2 ? atoi(a2) : -1;
      /* Wt 不许 w16：跳板第一条 adrp x16 先把它盖了，记下的会是键页地址低 32 位（原生层线 10-26 审出） */
      if (wt < 0 || wt == 16 || slot < FPS_SLOT_LO || slot > FPS_SLOT_HI || (orig & 0xfc000000u) != 0x94000000u) { gap(off, "fps", "bl_rec 参数不认（Wt 不许 w16）、槽不在范围或原字不是 BL"); continue; }
      if (site_at(off) || consumed(off)) { gap(off, "fps", "bl_rec 点已是改写点"); continue; }
      A target = off + ((int64_t)((int32_t)(orig << 6)) >> 4);
      /* 单点生成失败只撤本点、记缺口，同 patch_nso.py guarded(off, 'fps', gen) */
      BlRec b = {off, target, wt, slot};
      g->guarding = 1;
      int ok = unit_run(off, gen_blrec, &b, NULL);
      g->guarding = 0;
      if (!ok) {
        gap(off, "fps", "AssertionError: %s", g->error);
        continue;
      }
      done(off);
      bump("fps_bl_rec");
      continue;
    } else { gap(off, "fps", "不认识的种类 %s", kind); continue; }
    put(off, nw);
    char keystr[40];
    snprintf(keystr, sizeof(keystr), "fps_%s", kind);
    bump(keystr);
  }
  fclose(f);
}
/* 社区补丁双路（S2A_CPATCH_TSV，pack/cpatch.py 出；直连线 10-27，与 patch_nso.py 同语义同字节）：
 *   w <模块> <偏移> <原字> <新字>        分析前原位常写（补丁往填充区写的新代码：关着时没有入口跳过来，照样经过本改写器翻译）
 *   p <模块> <偏移> <原字> <新字> <位>   分析后编双路跳板：原字换成 B 跳板；跳板先下移 sp 再存 x16（str x16,[sp,#-16]!：存在新 sp 之上、不在 sp 以下——
 *     AArch64 没有红区，信号帧若压在客体栈上只会落在新 sp 以下；我方信号处理器另都带 SA_ONSTACK 落备用栈，两层都不踩；单测 ⑥ 每步灌乱码验），读键页槽 2046
 *     （本模块补丁位掩码，装载器按设置写），TBNZ 测本补丁的位分路，恢复 x16 后执行重定位过的原指令或补丁指令，再跳回下一条；TBNZ / LDR 不动标志位
 * 原字不符、点已被别的改写占用、指令要翻译（x18 / svc / 读写 tpidr）或解不出，记缺口 cpatch（措辞同 patch_nso.py），pack/cpatch.py 据此剔掉整份补丁重来 */
#define CP_SLOT 2046
static const char* cp_check(uint32_t w, A a) {
  if ((w & 0x7c000000u) == 0x14000000u || (w & 0xff000010u) == 0x54000000u || (w & 0x7e000000u) == 0x34000000u ||
      (w & 0x7e000000u) == 0x36000000u || (w & 0x1f000000u) == 0x10000000u)
    return NULL;
  if ((w & 0x3b000000u) == 0x18000000u) return ((w >> 26) & 1) && (w >> 30) == 3 ? "字面量编码不认" : NULL;
  Ins x = dis(w, a);
  if (!x.valid) return "解不出";
  if (has18(&x) || eq(x.m, "svc") || ((eq(x.m, "mrs") || eq(x.m, "msr")) && strstr(operand_text(&x), "tpidr"))) return "要翻译";
  return NULL;
}
static void cp_emit(uint32_t w, A a) { /* 把原在 a 的指令字 w 等价地发进跳板（PC 相对的重定位；先过 cp_check） */
  if ((w & 0x7c000000u) == 0x14000000u) { /* B / BL */
    A t = a + ((int64_t)((int32_t)(w << 6)) >> 4);
    emit(branch(here(), t) | (w & 0x80000000u));
    return;
  }
  if ((w & 0xff000010u) == 0x54000000u || (w & 0x7e000000u) == 0x34000000u || (w & 0x7e000000u) == 0x36000000u) { /* 条件跳：跳到旁边的长跳 */
    A t; uint32_t nw;
    if ((w & 0x7e000000u) == 0x36000000u) { t = a + ((int64_t)((int32_t)(w << 13)) >> 18 << 2 >> 0); nw = (w & 0xfff8001fu) | (2u << 5); }
    else { t = a + (((int64_t)((int32_t)(w << 8)) >> 13) << 2); nw = (w & 0xff00001fu) | (2u << 5); }
    emit(nw); emit(branch(here(), here() + 8)); emit(branch(here(), t));
    return;
  }
  if ((w & 0x1f000000u) == 0x10000000u) { /* ADR / ADRP */
    int rd = (int)(w & 31); int64_t imm = (int64_t)((((w >> 5) & 0x7ffffu) << 2) | ((w >> 29) & 3));
    if (imm & (1 << 20)) imm -= 1 << 21;
    if (w >> 31) { emit(adrp(rd, here(), (a & ~(A)0xfff) + (imm << 12))); return; }
    A t = a + imm; emit(adrp(rd, here(), t)); emit(ADDI((uint32_t)rd, (uint32_t)rd, (uint32_t)(t & 0xfff), 0u));
    return;
  }
  if ((w & 0x3b000000u) == 0x18000000u) { /* LDR 字面量 */
    uint32_t opc = w >> 30, v = (w >> 26) & 1, rt = w & 31; A t = a + (((int64_t)((int32_t)(w << 8)) >> 13) << 2);
    if (!v && opc == 3) return; /* PRFM：空操作 */
    if (!v) {
      static const uint32_t op[3] = {0xb9400000u, 0xf9400000u, 0xb9800000u};
      emit(adrp((int)rt, here(), t)); emit(ADDI(rt, rt, (uint32_t)(t & 0xfff), 0u)); emit(op[opc] | (rt << 5) | rt);
      return;
    }
    static const uint32_t op[3] = {0xbd400000u, 0xfd400000u, 0x3dc00000u};
    emit(STRPRE(16u, 31u, -16)); emit(adrp(16, here(), t)); emit(ADDI(16u, 16u, (uint32_t)(t & 0xfff), 0u)); emit(op[opc] | (16u << 5) | rt); emit(LDRPOST(16u, 31u, 16));
    return;
  }
  emit(w);
}
typedef struct {
  A off;
  uint32_t orig, nw;
  int bit;
} CpRow;
static void gen_cpatch(void* q) {
  CpRow* c = q;
  A off = c->off, start = here();
  int bit = c->bit;
  emit(STRPRE(16u, 31u, -16)); emit(adrp(16, here(), g->key)); emit(LDR(16u, 16u, (uint32_t)CP_SLOT));
  size_t tb = g->patch.n; emit(0);
  emit(LDRPOST(16u, 31u, 16)); cp_emit(c->orig, off); emit(branch(here(), off + 4));
  A p = here(); emit(LDRPOST(16u, 31u, 16)); cp_emit(c->nw, off); emit(branch(here(), off + 4));
  int64_t d = (p - (g->po + (A)tb * 4)) >> 2;
  REQUIRE(d < (1 << 13));
  g->patch.v[tb] = 0x37000000u | ((uint32_t)(bit >> 5) << 31) | ((uint32_t)(bit & 31) << 19) | (((uint32_t)d & 0x3fff) << 5) | 16u;
  put(off, branch(off, start));
  done(off);
  bump("cpatch_p");
}
static void cpatch_rows(int phase) {
  const char* path = g->r.cpatch_tsv;
  if (!path || !*path) return;
  FILE* f = fopen(path, "rb");
  if (!f) {
    int error = errno;
    if (error != ENOENT) fail("无法打开社区补丁表：%s", strerror(error));
    msg("[黄] %s 社区补丁表不存在，跳过\n", g->r.module);
    return;
  }
  char line[512];
  while (fgets(line, sizeof(line), f)) {
    char* h = strchr(line, '#');
    if (h) *h = 0;
    char *k = strtok(line, " \t\r\n"), *mod = strtok(NULL, " \t\r\n"), *offs = strtok(NULL, " \t\r\n"), *origs = strtok(NULL, " \t\r\n"),
         *news = strtok(NULL, " \t\r\n"), *bits = strtok(NULL, " \t\r\n");
    if (!k || !(eq(k, "w") || eq(k, "p")) || !mod || !eq(mod, g->r.module) || !offs || !origs || !news) continue;
    if (eq(k, "p") != (phase == 1)) continue;
    A off = strtoll(offs, NULL, 16);
    uint32_t orig = (uint32_t)strtoul(origs, NULL, 16), nw = (uint32_t)strtoul(news, NULL, 16);
    if (phase == 0) {
      if (off < 0 || off % 4 || off + 4 > (A)g->text) { gap(off, "cpatch", "w 点不在代码段"); continue; }
      if (iw(off) != orig) { gap(off, "cpatch", "w 点原字 0x%x，表里 0x%x", iw(off), orig); continue; }
      put(off, nw);
      bump("cpatch_w");
      continue;
    }
    if (!bits) { gap(off, "cpatch", "p 行缺位号"); continue; }
    int bit = atoi(bits);
    if (off < 0 || off % 4 || off + 4 > (A)g->text || bit < 0 || bit > 63) { gap(off, "cpatch", "p 点不在代码段或位号不在 0–63"); continue; }
    if (iw(off) != orig) { gap(off, "cpatch", "p 点原字 0x%x，表里 0x%x", iw(off), orig); continue; }
    if (site_at(off) || consumed(off)) { gap(off, "cpatch", "p 点已是改写点（宽屏点 / x18 / 跳转表等），两套改动叠在同一条指令上"); continue; }
    const char *why = cp_check(orig, off), *why2 = cp_check(nw, off);
    if (why || why2) { gap(off, "cpatch", "p 点%s%s", why ? "原指令" : "补丁指令", why ? why : why2); continue; }
    /* 单点生成失败（如补丁区离本点超 ±128 MB）只撤本点、记缺口，同 patch_nso.py guarded(off, 'cpatch', gen)；pack/cpatch.py 据缺口剔掉那份补丁重来 */
    CpRow c = {off, orig, nw, bit};
    g->guarding = 1;
    if (!unit_run(off, gen_cpatch, &c, NULL))
      gap(off, "cpatch", "AssertionError: %s", g->error);
    g->guarding = 0;
  }
  fclose(f);
}
/* 补丁包 [code] 段（补丁包_v1设计.md 12.11；一次成功线 11-02，首款马力欧激战前锋：NuCachedSource2 缓存上限 20 MB → 8 MB）：
 *   <模块> <偏移> orig=<原字节> new=<新字节，同长> [sig=<前>|<后>]（十六进制，?? 通配，点本身不写进 sig；# 起注释）
 *   文件头 build（编写时依据的主程序构建号）= 本包 code_build：按偏移打，先核原字节，不符跳过；
 *   不同：在本模块代码段按「前 sig + 原字节 + 后 sig」逐 4 字节扫，唯一命中才打，0 或多处跳过。分析前直接改字（不走双路 + 槽）。
 *   跳过记黄进改写日志；全部结果（打 / 跳过、走偏移还是特征、原因）写 <输出目录>/<模块>.code_patch.tsv */
static int cp_hex(const char* s, size_t n, uint8_t* b, uint8_t* m, int cap) { /* → 字节数；?? = 通配（m = 0）；坏写法 -1 */
  if (n % 2 || (int)(n / 2) > cap) return -1;
  for (size_t i = 0; i < n; i += 2) {
    if (s[i] == '?' && s[i + 1] == '?') { b[i / 2] = 0; if (m) m[i / 2] = 0; else return -1; continue; }
    int v[2];
    for (int k = 0; k < 2; k++) {
      char c = s[i + k];
      v[k] = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
      if (v[k] < 0) return -1;
    }
    b[i / 2] = (uint8_t)(v[0] * 16 + v[1]);
    if (m) m[i / 2] = 0xff;
  }
  return (int)(n / 2);
}
static int cp_ieq(const char* a, const char* b) { /* 构建号比较不分大小写（不用 strcasecmp：Windows 交叉构建没有） */
  for (; *a && *b; a++, b++)
    if ((*a | 0x20) != (*b | 0x20)) return 0;
  return !*a && !*b;
}
static int cp_at(A p, const uint8_t* b, const uint8_t* m, int n) { /* 映像 [p, p+n) 按掩码等于 b */
  if (p < 0 || (uint64_t)p + (uint64_t)n > g->text) return 0;
  for (int i = 0; i < n; i++)
    if ((g->img[p + i] & (m ? m[i] : 0xff)) != (b[i] & (m ? m[i] : 0xff))) return 0;
  return 1;
}
static void code_rows(void) {
  const char* path = g->r.code_patch;
  if (!path || !*path) return;
  FILE* f = fopen(path, "rb");
  if (!f) return;
  char line[1024], build[80] = "", sec[48] = "", outp[4096];
  FILE* o = NULL;
  int ln = 0, napplied = 0, nskip = 0;
  while (fgets(line, sizeof(line), f)) {
    ln++;
    char* h = strchr(line, '#');
    if (h) *h = 0;
    line[strcspn(line, "\r\n")] = 0;
    char* s = line;
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) continue;
    if (*s == '[') {
      char* z = strchr(s, ']');
      snprintf(sec, sizeof(sec), "%.*s", z ? (int)(z - s - 1) : 0, s + 1);
      continue;
    }
    if (!sec[0]) { /* 文件头：键 值 */
      char k[32], v[80];
      if (sscanf(s, "%31s %79s", k, v) == 2 && eq(k, "build")) snprintf(build, sizeof(build), "%s", v);
      continue;
    }
    if (!eq(sec, "code")) continue;
    char *mod = strtok(s, " \t"), *offs = strtok(NULL, " \t"), *t, *origs = NULL, *news = NULL, *sigs = NULL;
    while ((t = strtok(NULL, " \t"))) {
      if (!strncmp(t, "orig=", 5)) origs = t + 5;
      else if (!strncmp(t, "new=", 4)) news = t + 4;
      else if (!strncmp(t, "sig=", 4)) sigs = t + 4;
    }
    if (!mod || !eq(mod, g->r.module)) continue;
    if (!o) {
      snprintf(outp, sizeof(outp), "%s/%s.code_patch.tsv", g->r.output_dir, g->r.module);
      o = fopen(outp, "wb");
      if (!o) fail("无法写 %s：%s", outp, strerror(errno));
      fprintf(o, "# 补丁 %s；编写构建 %s、本包 %s\n偏移\t结果\t方式\t说明\n", path, build[0] ? build : "-", g->r.code_build ? g->r.code_build : "-");
    }
    uint8_t ob[64], nb[64], pre[64], prem[64], post[64], postm[64];
    int no = origs ? cp_hex(origs, strlen(origs), ob, NULL, 64) : -1, nn = news ? cp_hex(news, strlen(news), nb, NULL, 64) : -1, npre = 0, npost = 0;
    char* e = NULL;
    A off = offs ? (A)strtoll(offs, &e, 16) : -1;
    const char* bad = !offs || !e || *e ? "偏移看不懂" : no <= 0 || nn != no ? "orig / new 缺、坏或不同长" : no % 4 || off % 4 ? "不是整指令（偏移 / 长度要 4 的倍数）" : NULL;
    if (!bad && sigs) {
      char* bar = strchr(sigs, '|');
      if (!bar || (npre = cp_hex(sigs, (size_t)(bar - sigs), pre, prem, 64)) < 0 || (npost = cp_hex(bar + 1, strlen(bar + 1), post, postm, 64)) < 0) bad = "sig 看不懂";
    }
    if (bad) {
      msg("🟡 补丁 [code] 第 %d 行（%s %s）跳过：%s\n", ln, g->r.module, offs ? offs : "?", bad);
      fprintf(o, "%s\t跳过\t-\t第 %d 行：%s\n", offs ? offs : "?", ln, bad); nskip++;
      continue;
    }
    int same = build[0] && g->r.code_build && cp_ieq(build, g->r.code_build);
    A at = -1; const char* how = same ? "偏移" : "特征"; char why[160] = "";
    if (same) {
      if (cp_at(off, ob, NULL, no)) at = off;
      else snprintf(why, sizeof(why), "同构建号，偏移 %llx 处原字节对不上", (unsigned long long)off);
    } else if (!sigs) snprintf(why, sizeof(why), "构建号不同（编写 %s、本包 %s）且这行没有 sig", build[0] ? build : "-", g->r.code_build ? g->r.code_build : "-");
    else {
      int hits = 0;
      for (A p = 0; p + no <= (A)g->text; p += 4)
        if (cp_at(p, ob, NULL, no) && cp_at(p - npre, pre, prem, npre) && cp_at(p + no, post, postm, npost)) { if (!hits) at = p; hits++; }
      if (hits != 1) { snprintf(why, sizeof(why), "构建号不同，特征命中 %d 处（要唯一）", hits); at = -1; }
    }
    if (at < 0) {
      msg("🟡 补丁 [code] 第 %d 行（%s %llx）跳过：%s\n", ln, g->r.module, (unsigned long long)off, why);
      fprintf(o, "%llx\t跳过\t%s\t%s\n", (unsigned long long)off, how, why); nskip++;
      continue;
    }
    for (int i = 0; i < no; i += 4) put(at + i, u32(nb + i));
    bump("code_patch");
    napplied++;
    fprintf(o, "%llx\t已打\t%s\t%s\n", (unsigned long long)at, how, at == off ? "" : "特征定位到新偏移");
  }
  fclose(f);
  if (o) {
    fclose(o);
    msg("%s 补丁 [code]：打 %d 行、跳过 %d 行（%s）\n", g->r.module, napplied, nskip, outp);
  }
}
typedef struct {
  A off;
  uint32_t w;
  const char* kind;
  int idx;
} WideGen;
static void gen_widen(void* p) {
  WideGen* q = p;
  A off = q->off, start = here();
  if (in(q->kind, "aspdiv|aspstr|lytsz|capsz|seadasp")) {
    Ins x = dis(q->w, off);
    gate(&x, "wide", q->idx);
  } else {
    int d = q->w & 31;
    emit(adrp(d, here(), g->key));
    emit(STR(d, d, 1024 + q->idx));
    // 值槽每格 8 字节（键页 + (16 + 序号) × 8）：f2h / i2h 装整个 X（LDR Xd，偏移按 8 缩放），其余装 W（LDR Wd，偏移按 4 缩放）
    emit(in(q->kind, "f2h|i2h") ? (0xf9400000 | ((16 + q->idx) << 10) | (d << 5) | d) : (0xb9400000 | (((16 + q->idx) * 2) << 10) | (d << 5) | d));
    emit(branch(here(), off + (in(q->kind, "asp|aspcap|aspcaps") ? 8 : 4)));
  }
  put(off, branch(off, start));
}
static void widen(void) {
  if (!g->r.widen_tsv)
    return;
  FILE* f = fopen(g->r.widen_tsv, "rb");
  if (!f)
    fail("无法打开宽屏表：%s", strerror(errno));
  g->out = f;
  char line[2048];
  int rows = 0;
  // 宽屏表一个模块最多 1008 行（跳板按行号取 key 页槽位，编码放不下更多）。超了不让整个改写失败（11-05 普查：女神异闻录5R 自动宽屏表 2892 行，
  //   REQUIRE 失败 → 改写失败 → 整款出不了包）：宽屏是可选能力，本模块整张表都不用、打一行红，照常出 16:9 原生画幅的包。先数一遍再决定，不打半张表
  {
    int total = 0;
    while (fgets(line, sizeof(line), f)) {
      if (line[0] == '#' || line[0] == '\n')
        continue;
      char* name = strtok(line, "\t");
      if (name && eq(name, g->r.module))
        total++;
    }
    if (total > 1008) {
      msg("【红】%s 宽屏表 %d 行，超过一个模块 1008 行的上限：本模块不打宽屏补丁（16:9 原生画幅照常出包；表 %s）\n", g->r.module, total, g->r.widen_tsv);
      fclose(f);
      g->out = NULL;
      return;
    }
    rewind(f);
  }
  while (fgets(line, sizeof(line), f)) {
    if (line[0] == '#' || line[0] == '\n')
      continue;
    char *name = strtok(line, "\t"), *offstr = strtok(NULL, "\t"), *kind = strtok(NULL, "\t\r\n");
    if (!name || !offstr || !kind || !eq(name, g->r.module))
      continue;
    REQUIRE(++rows <= 1008);
    char* end;
    A off = strtoll(offstr, &end, 16);
    REQUIRE(!*end);
    uint32_t w = iw(off);
    Wide row = {0};
    row.idx = g->wide.n;
    row.off = off;
    row.w = w;
    snprintf(row.kind, sizeof(row.kind), "%s", kind);
    if (eq(kind, "f32") || eq(kind, "aspf") || eq(kind, "i32") || eq(kind, "restab")) {   // 数据点：装载时直接改（runtime/src/widen.c），不动代码
      PUSH(g->wide, row);
      continue;
    }
    Site* s = site_at(off);
    if (off >= (A)g->text || s || consumed(off)) {
      wskip(off, "%s 点不在可改代码里或已是改写点", kind);
      continue;
    }
    int valid = 1;
    if (in(kind, "movz|movzh")) {   // movzh：配对的显示高度（graphics/widen/scan/wide_scan.py），跳板同 movz
      if ((w & 0x7f800000) != 0x52800000 || (w & 31) == 31) {
        wskip(off, "%s 点原字 0x%x 不是 MOVZ Wd", kind, w);
        valid = 0;
      }
    } else if (eq(kind, "f2w")) {
      if ((w & 0xffe00000) != 0xd2a00000 || (w & 31) == 31) {
        wskip(off, "f2w 点原字 0x%x 不是 MOVZ Xd,#imm,LSL#16", w);
        valid = 0;
      }
    } else if (eq(kind, "f2h")) {   // f2w 配对的高半：MOVK Xd,#imm,LSL#48 → 从值槽装整个 8 字节（宽 | 高 << 32），宿主按屏高填（runtime/src/widen.c）
      if ((w & 0xffe00000) != 0xf2e00000 || (w & 31) == 31) {
        wskip(off, "f2h 点原字 0x%x 不是 MOVK Xd,#imm,LSL#48", w);
        valid = 0;
      }
    } else if (eq(kind, "i2h")) {   // 整数宽高打包的高半：MOVK Xd,#imm,LSL#32 → 同 f2h 装整个 8 字节
      if ((w & 0xffe00000) != 0xf2c00000 || (w & 31) == 31) {
        wskip(off, "i2h 点原字 0x%x 不是 MOVK Xd,#imm,LSL#32", w);
        valid = 0;
      }
    } else if (eq(kind, "asp")) {
      uint32_t w2 = iw(off + 4);
      if (((w & 0x7fffffe0) != (0x52800000 | (0x8e39 << 5)) &&
           (w & 0x7fffffe0) != (0x52800000 | (0x8e3b << 5))) ||
          (w2 & 0x7fffffe0) != (0x72a00000 | (0x3fe3 << 5)) || (w2 & 31) != (w & 31) ||
          ((w ^ w2) >> 31) || site_at(off + 4)) {
        wskip(off, "asp 点原字 0x%x 0x%x 不是 MOVZ #0x8e39 / #0x8e3b + MOVK #0x3fe3（Wd 或 Xd 同宽）",
            w, w2);
        valid = 0;
      }
    } else if (in(kind, "aspcap|aspcaps")) {   // 宽高比上限：MOVZ Wd,#lo + MOVK Wd,#hi,LSL#16 拼 19:9 / 21:9（graphics/widen/scan/wide_scan.py CAP）
      uint32_t w2 = iw(off + 4), lo = (w >> 5) & 0xffff, hi = lo == 0x1c72 ? 0x4007 : lo == 0x5555 ? 0x4015 : 0;
      if ((w & 0xffe00000) != 0x52800000 || !hi || (w2 & 0xffe0001f) != (0x72a00000 | (w & 31)) ||
          ((w2 >> 5) & 0xffff) != hi || site_at(off + 4)) {
        wskip(off, "%s 点原字 0x%x 0x%x 不是 MOVZ Wd,#0x1c72 / #0x5555 + MOVK Wd,#0x4007 / #0x4015", kind, w, w2);
        valid = 0;
      }
    } else if (eq(kind, "aspdiv")) {
      if ((w & 0xffe0fc00) != 0x1e201800) {
        wskip(off, "aspdiv 点原字 0x%x 不是 FDIV Sd", w);
        valid = 0;
      }
    } else if (eq(kind, "aspstr")) {
      if ((w & 0xffc00000) != 0xbd000000) {
        wskip(off, "aspstr 点原字 0x%x 不是 STR Sd,[Xn,#imm]", w);
        valid = 0;
      }
    } else if (in(kind, "lytsz|capsz")) {
      if ((w & 0xffc00000) != 0x2d400000 || (w & 31) == ((w >> 10) & 31)) {
        wskip(off, "%s 点原字 0x%x 不是 LDP Sa,Sb,[Xn,#imm]", kind, w);
        valid = 0;
      }
    } else if (eq(kind, "seadasp")) {   /* sead 透视投影读宽高比：LDR St,[Xn,#imm] 或 LDP Sa,Sb,[Xn,#imm]（同 patch_nso.py） */
      if ((w & 0xffc00000) != 0xbd400000 && ((w & 0xffc00000) != 0x2d400000 || (w & 31) == ((w >> 10) & 31))) {
        wskip(off, "seadasp 点原字 0x%x 不是 LDR St,[Xn,#imm] / LDP Sa,Sb,[Xn,#imm]", w);
        valid = 0;
      }
    } else {
      wskip(off, "不认识的种类 %s", kind);
      valid = 0;
    }
    if (!valid)
      continue;
    /* 单点生成失败只撤本点（wskip，不计缺口） */
    WideGen wg = {off, w, kind, row.idx};
    g->guarding = 1;
    int ok = unit_run(off, gen_widen, &wg, NULL);
    g->guarding = 0;
    if (!ok) {
      wskip(off, "%s%s", pre(g->error, "RuntimeError:") ? "" : "AssertionError: ", g->error);
      continue;
    }
    done(off);
    PUSH(g->wide, row);
    char keystr[40];
    snprintf(keystr, sizeof(keystr), "widen_%s", kind);
    bump(keystr);
  }
  REQUIRE(!ferror(f));
  fclose(f);
  g->out = NULL;
}
typedef struct {
  int kind, n, ns, base;
  A succ[2], k, copy;
  Ins ins[4];
  Mask uses, defs, live;
  int back, keep, valid;
} Node;
static uint32_t rebranch(const Ins* x, A pc, A t) {
  A off = t - pc;
  if (eq(x->m, "b"))
    return branch(pc, t);
  int tb = in(x->m, "tbz|tbnz"), bits = tb ? 14 : 19;
  REQUIRE(off >= -(1LL << (bits + 1)) && off < (1LL << (bits + 1)) && off % 4 == 0);
  uint32_t mask = (1u << bits) - 1;
  return (x->w & ~(mask << 5)) | (((off >> 2) & mask) << 5);
}
static int spin_kind(const Ins* x) {
  if (!x->valid)
    return 0;
  if (eq(x->m, "b") || conditional(x))
    return 2;
  if (in(x->m, "adr|adrp"))
    return 3;
  if (in(x->m,
         "bl|blr|br|ret|eret|svc|hvc|smc|brk|hlt|udf|mrs|msr|sys|sysl|wfe|wfi|sev|sevl|clrex|dc|ic|"
         "at|tlbi|drps|dcps1|dcps2|dcps3|blraa|blrab|blraaz|blrabz|braa|brab|braaz|brabz|retaa|"
         "retab|eretaa|eretab") ||
      pre(x->m, "st") || pre(x->m, "cas") || pre(x->m, "swp") || pre(x->m, "ldadd") ||
      pre(x->m, "ldclr") || pre(x->m, "ldeor") || pre(x->m, "ldset") || pre(x->m, "ldsmax") ||
      pre(x->m, "ldsmin") || pre(x->m, "ldumax") || pre(x->m, "ldumin"))
    return 0;
  int mem = 0;
  for (int i = 0; i < detail(x)->op_count; i++)
    if (detail(x)->operands[i].type == ARM64_OP_MEM)
      mem = 1;
  if (pre(x->m, "ld") || pre(x->m, "prfm") || pre(x->m, "prfum"))
    return mem ? 1 : 0;
  return mem ? 0 : 1;
}
static void spin_rw(const Ins* x, Mask* r, Mask* w) {
  Mask ops = 0, first = 0, rest = 0;
  int nr = 0;
  for (int i = 0; i < detail(x)->op_count; i++)
    if (detail(x)->operands[i].type == ARM64_OP_REG) {
      int b = regbit(detail(x)->operands[i].reg);
      Mask bit = b < 0 ? 0 : BIT(b);
      ops |= bit;
      if (!nr++)
        first = bit;
      else
        rest |= bit;
    }
  if (in(x->m, "cbz|cbnz|tbz|tbnz")) {
    *r = ops;
    *w = 0;
  } else if (pre(x->m, "b.")) {
    *r = BIT(32);
    *w = 0;
  } else if (eq(x->m, "b")) {
    *r = *w = 0;
  } else if (in(x->m, "cmp|cmn|tst|fcmp|fcmpe")) {
    *r = ops;
    *w = BIT(32);
  } else if (in(x->m, "ccmp|ccmn|fccmp|fccmpe")) {
    *r = ops | BIT(32);
    *w = BIT(32);
  } else if (pre(x->m, "ld") || pre(x->m, "prfm") || pre(x->m, "prfum")) {
    *r = x->rd;
    *w = x->wr | ops;
  } else {
    *r = x->rd | rest;
    *w = x->wr | first;
  }
}
static int rmw(A a, Node* n) {
  for (int i = 0; i < 4; i++)
    if (!decode(u32(g->orig + a + 4 * i), a + 4 * i, n->ins + i))
      return 0;
  Ins* l = n->ins;
  if (!in(l[0].m, "ldxr|ldaxr") || !in(l[1].m, "add|sub") || !in(l[2].m, "stxr|stlxr") ||
      !eq(l[3].m, "cbnz"))
    return 0;
  if (detail(&l[1])->op_count != 3 || detail(&l[1])->operands[2].type != ARM64_OP_IMM || strstr(operand_text(&l[1]), "lsl"))
    return 0;
  arm64_op_mem b = detail(&l[0])->operands[1].mem, b2 = detail(&l[2])->operands[2].mem;
  if (b.disp || b.index || b.base != b2.base || b2.disp)
    return 0;
  if (detail(&l[1])->operands[1].reg != detail(&l[0])->operands[0].reg ||
      detail(&l[2])->operands[1].reg != detail(&l[1])->operands[0].reg ||
      detail(&l[3])->operands[0].reg != detail(&l[2])->operands[0].reg || target(l + 3) != a)
    return 0;
  n->base = regbit(b.base);
  if (n->base < 0 || n->base >= 32)
    return 0;
  n->k = detail(&l[1])->operands[2].imm * (eq(l[1].m, "add") ? 1 : -1);
  n->uses = BIT(n->base);
  n->defs = 0;
  for (int i = 0; i < 3; i++) {
    int b = regbit(detail(&l[i])->operands[0].reg);
    if (b >= 0)
      n->defs |= BIT(b);
  }
  n->n = 4;
  n->kind = 4;
  n->succ[0] = a + 16;
  n->ns = 1;
  return 1;
}
static void prune(Node* n, int count, A T) {
  for (int i = 0; i < count; i++)
    n[i].keep = n[i].valid;
  int more = 1;
  while (more) {
    more = 0;
    for (int i = 0; i < count; i++)
      if (n[i].kind && !n[i].keep)
        for (int z = 0; z < n[i].ns; z++) {
          A sx = n[i].succ[z];
          if (sx != T && sx >= T && sx < T + 4LL * count && sx % 4 == 0 && n[(sx - T) / 4].keep) {
            n[i].keep = 1;
            more = 1;
            break;
          }
        }
  }
}
typedef struct {
  int base, version;
  A delta;
} Delta;
static int spin_walk(Node* n, int count, A T, int idx, uint8_t* on, int* ver, Delta* d, int nd,
                     int* steps, int* paths) {
  if (++*steps > 4096)
    return 0;
  Node* x = n + idx;
  int v[33];
  memcpy(v, ver, sizeof(v));
  Delta dd[256];
  REQUIRE(nd < 256);
  memcpy(dd, d, nd * sizeof(*d));
  if (x->kind == 4) {
    int k = 0;
    while (k < nd && (dd[k].base != x->base || dd[k].version != v[x->base]))
      k++;
    if (k == nd) {
      if (nd == 255)
        return 0;
      dd[nd++] = (Delta){x->base, v[x->base], 0};
    }
    dd[k].delta += x->k;
  }
  for (int r = 0; r < 33; r++)
    if (x->defs & BIT(r))
      v[r]++;
  on[idx] = 1;
  for (int z = 0; z < x->ns; z++) {
    A sx = x->succ[z];
    if (sx == T) {
      if (++*paths > 256)
        return 0;
      for (int k = 0; k < nd; k++)
        if (dd[k].delta)
          x->valid = 0;
    } else if (sx > T && sx < T + 4LL * count && n[(sx - T) / 4].keep) {
      int i = (sx - T) / 4;
      if (on[i] || !spin_walk(n, count, T, i, on, v, dd, nd, steps, paths))
        return 0;
    }
  }
  on[idx] = 0;
  return 1;
}
/* 自旋区候选先全部识别、再逐个生成（识别读当前映像，生成会改映像：两段式不能合并，否则产物变）。
 * 识别完只存紧凑节点（不带解码，10-30 出包线：动森 9.2 万个候选区 × 每区最多 129 节点 × 4 份完整解码同时驻留，C 改写器峰值 15.8 GB）；
 * 生成前按「区起点 + 4 × 节点序号 + 4 × 份序号」从原始代码重新解码前 nd 份——解码只取决于指令字与地址，节点内容与原来逐字节相同 */
typedef struct {
  int kind, n, ns, base;
  A succ[2], k, copy;
  Mask uses, defs, live;
  int back, keep, valid;
  unsigned char nd; /* ins[0..nd) 是解码过的（valid 连续），其余为零 */
} CNode;
typedef struct {
  A T;
  CNode* c;
  int count;
} SpinRegion;
static CNode* spin_pack(const Node* n, int count) {
  CNode* c = zalloc(count * sizeof(CNode));
  for (int i = 0; i < count; i++) {
    const Node* x = n + i;
    CNode* y = c + i;
    y->kind = x->kind, y->n = x->n, y->ns = x->ns, y->base = x->base;
    y->succ[0] = x->succ[0], y->succ[1] = x->succ[1], y->k = x->k, y->copy = x->copy;
    y->uses = x->uses, y->defs = x->defs, y->live = x->live;
    y->back = x->back, y->keep = x->keep, y->valid = x->valid;
    while (y->nd < 4 && x->ins[y->nd].valid)
      y->nd++;
    for (int z = y->nd; z < 4; z++) {   /* 约定成立才压：前 nd 份之后全是零（解码失败会清零、没解过的本来是零） */
      static const Ins zero;
      REQUIRE(!memcmp(x->ins + z, &zero, sizeof(Ins)));
    }
  }
  return c;
}
static Node* spin_unpack(const SpinRegion* r) {
  Node* n = zalloc(r->count * sizeof(Node));
  for (int i = 0; i < r->count; i++) {
    const CNode* y = r->c + i;
    Node* x = n + i;
    x->kind = y->kind, x->n = y->n, x->ns = y->ns, x->base = y->base;
    x->succ[0] = y->succ[0], x->succ[1] = y->succ[1], x->k = y->k, x->copy = y->copy;
    x->uses = y->uses, x->defs = y->defs, x->live = y->live;
    x->back = y->back, x->keep = y->keep, x->valid = y->valid;
    A a = r->T + 4LL * i;
    for (int z = 0; z < y->nd; z++)
      REQUIRE(decode(u32(g->orig + a + 4LL * z), a + 4LL * z, x->ins + z));
  }
  return n;
}
static int touched(A a) {
  return site_at(a) || memcmp(g->img + a, g->orig + a, 4);
}
static int spin_region(A T, A hi, SpinRegion* out) {
  int count = (hi - T) / 4 + 1;
  if (T < 0 || hi >= (A)g->text || count > 129)
    return 0;
  Node* n = zalloc(count * sizeof(Node));
  AV todo = {0};
  PUSH(todo, T);
  while (todo.n) {
    A a = todo.v[--todo.n];
    int idx = (a - T) / 4;
    if (idx < 0 || idx >= count || n[idx].kind)
      continue;
    Node* x = n + idx;
    int isrmw = a + 12 <= hi && (u32(g->orig + a) & 0x3fe00000) == 0x08400000 && rmw(a, x);
    if (!isrmw) {
      if (!decode(u32(g->orig + a), a, x->ins)) {
        x->kind = -1;
        continue;
      }
      x->kind = spin_kind(x->ins);
      x->n = 1;
      if (!x->kind) {
        x->kind = -1;
        continue;
      }
      x->succ[0] = x->kind == 2 ? target(x->ins) : a + 4;
      x->ns = x->kind == 2 && !eq(x->ins->m, "b") ? 2 : 1;
      if (x->ns == 2)
        x->succ[1] = a + 4;
      spin_rw(x->ins, &x->uses, &x->defs);
    }
    int bad = 0;
    for (int k = 0; k < x->n; k++)
      if (touched(a + 4 * k))
        bad = 1;
    if (bad) {
      x->kind = -1;
      continue;
    }
    for (int k = 0; k < x->ns; k++) {
      A sx = x->succ[k];
      if (sx == T)
        x->back = x->valid = 1;
      else if (sx > T && sx <= hi)
        PUSH(todo, sx);
    }
  }
  int back = 0;
  for (int i = 0; i < count; i++) {
    if (n[i].kind < 0)
      n[i].kind = 0;
    if (n[i].back)
      back = 1;
    if (n[i].kind == 4)
      for (int k = 1; k < 4; k++) {
        if (n[i + k].kind)
          { release(n); release(todo.v); return 0; }
        for (int j = 0; j < count; j++)
          if (n[j].kind > 0)
            for (int z = 0; z < n[j].ns; z++)
              if (n[j].succ[z] == T + 4LL * (i + k))
                { release(n); release(todo.v); return 0; }
      }
  }
  if (!back)
    { release(n); release(todo.v); return 0; }
  prune(n, count, T);
  if (!n[0].keep)
    { release(n); release(todo.v); return 0; }
  int ver[33] = {0}, steps = 0, paths = 0;
  uint8_t on[129] = {0};
  Delta delta[256];
  if (!spin_walk(n, count, T, 0, on, ver, delta, 0, &steps, &paths))
    { release(n); release(todo.v); return 0; }
  back = 0;
  for (int i = 0; i < count; i++)
    back |= n[i].valid;
  if (!back)
    { release(n); release(todo.v); return 0; }
  prune(n, count, T);
  int more = 1;
  while (more) {
    more = 0;
    for (int i = count - 1; i >= 0; i--)
      if (n[i].keep) {
        Mask outmask = 0;
        for (int z = 0; z < n[i].ns; z++) {
          A sx = n[i].succ[z];
          if (sx == T) {
            if (n[i].valid)
              outmask |= n[0].live;
          } else if (sx > T && sx < T + 4LL * count && n[(sx - T) / 4].keep)
            outmask |= n[(sx - T) / 4].live;
        }
        Mask mask = n[i].uses | (outmask & ~n[i].defs);
        if (mask != n[i].live) {
          n[i].live = mask;
          more = 1;
        }
      }
  }
  Mask all = 0;
  for (int i = 0; i < count; i++)
    if (n[i].keep)
      all |= n[i].defs;
  if (n[0].live & all)
    { release(n); release(todo.v); return 0; }
  *out = (SpinRegion){T, spin_pack(n, count), count};   /* 只留紧凑节点；识别失败的各条出口也都放掉（原先候选区的节点数组一律不放） */
  release(n);
  release(todo.v);
  return 1;
}
typedef struct {
  size_t at;
  Ins ins;
  int has;
  A info;
  int hasinfo;
} Fix;
static void spin_emit(SpinRegion* r) {
  Node* n = spin_unpack(r);   /* 生成前按原始代码还原完整节点（见 CNode），本函数末尾放掉 */
  A T = r->T;
  VEC(Fix) fixes = {0};
  AV R = {0};
  for (int i = 0; i < r->count; i++)
    if (n[i].keep)
      PUSH(R, (A)i);
  for (size_t k = 0; k < R.n; k++) {
    int i = R.v[k];
    Node* x = n + i;
    A a = T + 4LL * i;
    x->copy = here();
    if (x->kind == 4) {
      for (int z = 0; z < 3; z++)
        emit(x->ins[z].w);
      Fix f = {g->patch.n, x->ins[3], 1, a, 1};
      PUSH(fixes, f);
      emit(0);
    } else if (x->kind == 3) {
      int d = rno(x->ins, 0);
      A t = detail(&x->ins[0])->operands[1].imm;
      emit(adrp(d, here(), t));
      if (eq(x->ins[0].m, "adr"))
        emit(ADDI(d, d, t & 4095, 0));
    } else if (x->kind == 2) {
      Fix f = {g->patch.n, x->ins[0], 1, 0, 0};
      PUSH(fixes, f);
      emit(0);
    } else
      emit(x->ins[0].w);
    if (!(x->kind == 2 && eq(x->ins[0].m, "b"))) {
      A ft = a + 4 * x->n;
      if (!(k + 1 < R.n && T + 4 * R.v[k + 1] == ft)) {
        Fix f = {0};
        f.at = g->patch.n;
        f.info = ft;
        f.hasinfo = 1;
        PUSH(fixes, f);
        emit(0);
      }
    }
  }
  A pause = here();
  emit(STPRE(29, 30, 31, -16));
  gatecall();
  emit(BLR(30));
  Gate gatex = {here(), T, "spin", 0};
  PUSH(g->gates, gatex);
  emit(LDPOST(29, 30, 31, 16));
  emit(branch(here(), n[0].copy));
  AV tramp_t = {0}, tramp_at = {0};
  for (size_t k = 0; k < fixes.n; k++) {
    Fix* f = fixes.v + k;
    A pc = g->po + 4 * f->at, dst;
    uint32_t w;
    if (!f->has) {
      A t = f->info;
      dst = t >= T && t < T + 4LL * r->count && n[(t - T) / 4].keep ? n[(t - T) / 4].copy : t;
      w = branch(pc, dst);
    } else if (f->hasinfo)
      w = rebranch(&f->ins, pc, n[(f->info - T) / 4].copy);
    else {
      A t = target(&f->ins);
      int idx = (f->ins.at - T) / 4;
      if (t == T && n[idx].valid)
        dst = pause;
      else if (t != T && t >= T && t < T + 4LL * r->count && n[(t - T) / 4].keep)
        dst = n[(t - T) / 4].copy;
      else if (!eq(f->ins.m, "b")) {
        size_t z = 0;
        while (z < tramp_t.n && tramp_t.v[z] != t)
          z++;
        if (z == tramp_t.n) {
          PUSH(tramp_t, t);
          PUSH(tramp_at, here());
          emit(branch(here(), t));
        }
        dst = tramp_at.v[z];
      } else
        dst = t;
      w = rebranch(&f->ins, pc, dst);
    }
    g->patch.v[f->at] = w;
  }
  SpinSite ss = {0};
  ss.head = T;
  for (int i = 0; i < r->count; i++)
    if (n[i].valid) {
      A b = T + 4LL * i;
      Ins* x = n[i].ins;
      A st = here();
      if (eq(x->m, "b"))
        put(b, branch(b, n[0].copy));
      else {
        emit(rebranch(x, here(), n[0].copy));
        emit(branch(here(), b + 4));
        put(b, branch(b, st));
      }
      PUSH(ss.backs, b);
    }
  PUSH(g->spins, ss);
  bump("spin");
  release(n);
}
typedef struct {
  SpinRegion* r;
  uint32_t saved[129];
} SpinTry;
static void gen_spin(void* p) {
  spin_emit(((SpinTry*)p)->r);
}
static void undo_spin(void* p) {
  SpinTry* t = p;
  for (int j = 0; j < t->r->count; j++)
    put(t->r->T + 4LL * j, t->saved[j]);
}
static void spins(void) {
  if (!g->r.spin)
    return;
  AV heads = {0};
  VEC(Pair) backedges = {0};
  for (A a = 0; a < (A)g->text; a += 4) {
    if (!in_code(a)) continue;
    uint32_t w = u32(g->orig + a);
    int top = w >> 24;
    if (!(top == 0x16 || top == 0x17 || top == 0x54 || top == 0x34 || top == 0x35 || top == 0xb4 ||
          top == 0xb5 || top == 0x36 || top == 0x37 || top == 0xb6 || top == 0xb7))
      continue;
    A dd = 4;
    if (top == 0x16 || top == 0x17)
      dd = ((A)(w & 0x3ffffff) - (1 << 26)) * 4;
    else if ((top & 0x7e) == 0x36) {
      if (w & 0x40000)
        dd = ((A)((w >> 5) & 0x3fff) - (1 << 14)) * 4;
    } else if (top == 0x54) {
      if ((w & 0x800000) && !(w & 0x10))
        dd = ((A)((w >> 5) & 0x7ffff) - (1 << 19)) * 4;
    } else if (w & 0x800000)
      dd = ((A)((w >> 5) & 0x7ffff) - (1 << 19)) * 4;
    if (dd >= -512 && dd <= 0) {
      PUSH(heads, a + dd);
      Pair p = {a + dd, a};
      PUSH(backedges, p);
    }
  }
  sort(&heads);
  if (backedges.n > 1)
    qsort(backedges.v, backedges.n, sizeof(Pair), cmppair);
  VEC(SpinRegion) regions = {0};
  size_t j = 0;
  for (size_t i = 0; i < heads.n; i++) {
    A hi = heads.v[i];
    while (j < backedges.n && backedges.v[j].a < heads.v[i])
      j++;
    for (; j < backedges.n && backedges.v[j].a == heads.v[i]; j++)
      hi = MAX(hi, backedges.v[j].b);
    SpinRegion r;
    if (spin_region(heads.v[i], hi, &r))
      PUSH(regions, r);
  }
  for (size_t i = 0; i < regions.n; i++) {
    SpinRegion* r = regions.v + i;
    SpinTry t = {r, {0}};
    for (int j = 0; j < r->count; j++)
      t.saved[j] = iw(r->T + 4LL * j);
    g->guarding = 1;
    if (!unit_run(r->T, gen_spin, &t, undo_spin)) {
      /* 可选优化，不记缺口；双岛下两岛都够不着的不许无声：记进 spin_miss，出表头 SPIN_UNREACHED 与【红】汇总行 */
      if (g->dual && g->range_err)
        PUSH(g->spin_miss, r->T);
      msg("%s 自旋区 0x%" PRIx64 " 不做：%s\n", g->r.module, (uint64_t)r->T, g->error);
    }
  }
  g->guarding = 0;
  msg("%s 自旋区 %zu 个（候选头 %zu）\n", g->r.module, g->spins.n, heads.n);
}
static void hex(FILE* f, A a) {
  if (a < 0)
    fprintf(f, "-0x%" PRIx64, (uint64_t)(-a));
  else
    fprintf(f, "0x%" PRIx64, (uint64_t)a);
}
static void path(char* p, size_t n, const char* ext) {
  int k = snprintf(p, n, "%s/%s.%s", g->r.output_dir, g->r.module, ext);
  REQUIRE(k > 0 && (size_t)k < n);
}
static FILE* output(const char* ext) {
  char p[4096];
  path(p, sizeof(p), ext);
  FILE* f = fopen(p, "wb");
  if (!f)
    fail("无法写产物 %s：%s", ext, strerror(errno));
  g->out = f;
  return f;
}
static void closeout(void) {
  FILE* f = g->out;
  g->out = NULL;
  int bad = ferror(f), rc = fclose(f);
  if (bad || rc)
    fail("写产物失败：%s", strerror(errno));
}
static void remove_output(const char* ext) {
  char p[4096];
  path(p, sizeof(p), ext);
  if (remove(p) && errno != ENOENT)
    fail("无法删除旧 %s：%s", ext, strerror(errno));
}
static int cmpgap(const void* a, const void* b) {
  const Gap *x = a, *y = b;
  if (x->at != y->at)
    return (x->at > y->at) - (x->at < y->at);
  int k = strcmp(x->kind, y->kind);
  return k ? k : strcmp(x->why, y->why);
}
static int cmpbump(const void* a, const void* b) {
  return strcmp(((const Stat*)a)->key, ((const Stat*)b)->key);
}
/* 首轮零 GAP 且补丁放不进 FRONT 时按实际长度 align64KiB(补丁 + 16KiB) 整轮重做（上限 32 MiB）；自旋是可选优化，但换布局不许丢掉上一轮成功的回边 */
#define RETRY_RC (-100)
static size_t lost_spins(void) {
  size_t n = 0;
  for (size_t i = 0; i < g->spins.n; i++)
    n += g->spins.v[i].backs.n;
  g->now = n ? malloc(n * sizeof(Pair)) : NULL;
  REQUIRE(!n || g->now);
  g->nnow = 0;
  for (size_t i = 0; i < g->spins.n; i++)
    for (size_t j = 0; j < g->spins.v[i].backs.n; j++)
      g->now[g->nnow++] = (Pair){g->spins.v[i].head, g->spins.v[i].backs.v[j]};
  if (g->nnow > 1)
    qsort(g->now, g->nnow, sizeof(Pair), cmppair);
  size_t lost = 0;
  for (size_t i = 0; i < g->nreq; i++)
    lost += !bsearch(g->req + i, g->now, g->nnow, sizeof(Pair), cmppair);
  return lost;
}
#define FRONT_MAX 0x7f00000 /* 前岛上限 127 MiB：再大 text 首也够不着岛底；够不够得着由每条 B 的编码检查判（越射程即整轮改双岛），不写死 32 MiB */
static int outputs(void) {
  home();
  size_t lost = g->dual ? 0 : lost_spins();
  size_t flen = g->dual ? (g->po < 0 ? g->patch.n : g->patch2.n) * 4 : g->far ? g->patch.n * 4 : 0;   // 前岛（基址前）实长
  int capacity_short = (g->far || g->dual) && flen > g->front - 0x4000;
  size_t next_front = (flen + 0x4000 + 0xffff) & ~(size_t)0xffff;
  size_t front_max = FRONT_MAX;
  if (!g->dual && g->range_miss) {
    remove_output("patched.bin");
    msg("%s 补丁区 B 越射程，整轮按双补丁岛重做\n", g->r.module);
    g->next_dual = 1;
    g->next_front = 0;
    return RETRY_RC;
  }
  /* 双岛的前岛超容量时本轮的单元落点不作数（缺口可能就是越界落点造成的）：不看缺口，直接放大前岛重做 */
  if ((g->dual || (!g->gaps.n && !lost)) && capacity_short) {
    remove_output("patched.bin");
    if (next_front <= front_max) {
      msg("%s 补丁容量不足，重新生成：FRONT 0x%zx → 0x%zx，补丁 0x%zx\n", g->r.module, g->front, next_front, flen);
      g->next_dual = g->dual;
      g->next_front = next_front;
      return RETRY_RC;
    }
    if (!g->dual) {   /* 原布局的前岛放不下：整轮按双补丁岛重做 */
      msg("%s 补丁 0x%zx 超前岛上限 0x%zx，整轮按双补丁岛重做\n", g->r.module, flen, front_max);
      g->next_dual = 1;
      g->next_front = 0;
      return RETRY_RC;
    }
  }
  if (MKDIR(g->r.output_dir) && errno != EEXIST)
    fail("无法创建输出目录：%s", strerror(errno));
  if (g->gaps.n > 1)
    qsort(g->gaps.v, g->gaps.n, sizeof(Gap), cmpgap);
  VEC(Stat) need = {0};
  for (size_t i = 0; i < g->sites.n + g->gaps.n; i++) {
    const char* k = i < g->sites.n ? g->sites.v[i].kind : g->gaps.v[i - g->sites.n].kind;
    if (i >= g->sites.n && !in(k, "sys|brk"))
      continue;
    size_t j = 0;
    while (j < need.n && !eq(need.v[j].key, k))
      j++;
    if (j == need.n) {
      Stat s = {0};
      snprintf(s.key, sizeof(s.key), "%s", k);
      PUSH(need, s);
    }
    need.v[j].n++;
  }
  if (need.n > 1)
    qsort(need.v, need.n, sizeof(Stat), cmpbump);
  size_t total = 0;
  for (size_t i = 0; i < need.n; i++)
    total += need.v[i].n;
  FILE* f = output("gaps.tsv");
  fprintf(f, "# BUILD_ID\t%s\n# 需求\t%zu\n# 需求分类\t", g->id, total);
  for (size_t i = 0; i < need.n; i++)
    fprintf(f, "%s%s=%zu", i ? " " : "", need.v[i].key, need.v[i].n);
  fputc('\n', f);
  for (size_t i = 0; i < g->gaps.n; i++) {
    Gap* x = g->gaps.v + i;
    hex(f, x->at);
    fprintf(f, "\t%s\t%s\n", x->kind, x->why);
    msg("GAP\t%s\t0x%" PRIx64 "\t%s: %s\n", g->r.module, (uint64_t)x->at, x->kind, x->why);
  }
  closeout();
  if (g->dual) {
    char b[24];
    msg("%s 双补丁岛 PATCH2_OFF %s PATCH2_LEN 0x%zx FRONT 0x%zx trap %zu 处 自旋够不着 %zu 处\n", g->r.module, shx(b, g->po2), g->patch2.n * 4,
        g->front, g->traps.n, g->spin_miss.n);
    if (g->spin_miss.n) {
      msg("【红】%s 自旋区 %zu 处两个补丁岛都够不着、没改写：", g->r.module, g->spin_miss.n);
      for (size_t i = 0; i < g->spin_miss.n; i++)
        msg("%s0x%" PRIx64, i ? " " : "", (uint64_t)g->spin_miss.v[i]);
      msg("\n");
    }
  }
  /* 能进入重做说明原布局零 GAP：此时新增缺口属于布局重选失败 */
  int retry_gaps = !g->dual && g->retry_front && g->gaps.n;
  int layout_fatal = retry_gaps || (!g->gaps.n && (capacity_short || lost));
  msg("PFRW mod=%s need=%zu gaps=%zu fatal=%d\n", g->r.module, total, g->gaps.n, layout_fatal);
  if (g->gaps.n && !retry_gaps && (capacity_short || lost)) {
    /* 有缺口且补丁区放不下 / 丢了自旋回边：布局不成立，不出产物（gaps.tsv 留作诊断；上一轮产物不能与新输入混用）。
     *   其余有缺口的照出产物（v0.3.1 拿不准不停）：缺口点的单元已回滚、原指令不动，退出码仍是 3，出包按缺口数降级继续 */
    remove_output("patched.bin");
    remove_output("fixups.tsv");
    remove_output("gates.tsv");
    remove_output("sites.tsv");
    remove_output("widen.tsv");
    return 3;
  }
  if (layout_fatal) {
    remove_output("patched.bin");
    if (retry_gaps)
      fail("补丁布局重选后 B / ADRP 超出跳转范围，新增 %zu 个编码缺口（text 末尾 0x%zx，新 FRONT 0x%zx）；首轮零 GAP，当前布局不可用，拒绝输出",
           g->gaps.n, g->text, g->front);
    if (lost)
      fail("扩大补丁布局后丢失 %zu 条已成功的自旋回边，拒绝输出", lost);
    fail("补丁区 0x%zx 字节放不进首址前的 0x%zx（可用 0x%zx）；需要 0x%zx，布局策略上限 0x%zx", flen,
         g->front, g->front - 0x4000, next_front, front_max);
  }
  f = output("patched.bin");
  size_t padto = g->far ? g->filelen : (size_t)g->po;
  REQUIRE(padto >= g->len);
  REQUIRE(fwrite(g->img, 1, g->len, f) == g->len);
  uint8_t zeros[4096] = {0};
  for (size_t left = padto - g->len; left;) {
    size_t n = MIN(left, sizeof(zeros));
    REQUIRE(fwrite(zeros, 1, n, f) == n);
    left -= n;
  }
  for (size_t i = 0; i < g->patch.n; i++) {
    uint8_t w[4];
    wr32(w, g->patch.v[i]);
    REQUIRE(fwrite(w, 1, 4, f) == 4);
  }
  for (size_t i = 0; g->dual && i < g->patch2.n; i++) {   /* 双岛：另一个岛接在文件末尾（PATCH2_LEN 字节） */
    uint8_t w[4];
    wr32(w, g->patch2.v[i]);
    REQUIRE(fwrite(w, 1, 4, f) == 4);
  }
  closeout();
  f = output("fixups.tsv");
  fprintf(f, "# BUILD_ID\t%s\n", g->id);
  if (g->android || g->ohos) {
    const char* tgt = g->ohos ? "ohos" : "android";
    fprintf(f, "# TARGET\t%s\n# REWRITE_ABI\t%s\n", tgt,
            g->below ? (g->ohos ? "ohos-below-sp-v1" : "android-below-sp-v1")
                     : (g->ohos ? "ohos-sp-safe-v1" : "android-sp-safe-v1"));
  }
  if (!noredzone() && g->bias)
    fprintf(f, "# LOAD_BIAS\t0x%zx\n", g->bias);
  fprintf(f, "# PATCH_OFF\t");
  hex(f, g->po);
  fprintf(f, "\n# KEY_PAGE_OFF\t");
  hex(f, g->key);
  fprintf(f, "\n# KEY_PAGE_SIZE\t0x4000\n# TEXT_END\t0x%zx\n# RO_OFF\t0x%zx\n# DATA_OFF\t0x%zx\n",
          g->text, g->ro, g->data);
  if (g->far)
    fprintf(f, "# IMAGE_SIZE\t0x%zx\n# FILE_IMAGE_LEN\t0x%zx\n", g->imagesize, g->filelen);
  if (g->dual) {
    char b[24];
    fprintf(f, "# PATCH2_OFF\t%s\n# PATCH2_LEN\t0x%zx\n# TRAP_SITES\t%zu\n# SPIN_UNREACHED\t%zu\n", shx(b, g->po2), g->patch2.n * 4,
            g->traps.n, g->spin_miss.n);
    for (size_t i = 0; i < g->traps.n; i++) {   /* 序号 = 出现顺序（brk #(0x8000 + 序号)）：偏移 / 种类 / 寄存器 / 原字 */
      fprintf(f, "# TRAP\t");
      hex(f, g->traps.v[i].at);
      fprintf(f, "\t%s\t%d\t0x%08x\n", g->traps.v[i].kind, g->traps.v[i].reg, g->traps.v[i].w);
    }
    if (g->fars.n) {   /* 远跳（brk #FAR_IMM）：<从> <到>（相对基址，有符号）<E 入口 | X 出口>；装载器按 <从> 二分查 */
      fprintf(f, "# FAR_JUMPS\t%zu\n", g->fars.n);
      for (size_t i = 0; i < g->fars.n; i++)
      { char b2[24]; fprintf(f, "# FAR\t%s\t%s\t%c\n", shx(b, g->fars.v[i].from), shx(b2, g->fars.v[i].to), g->fars.v[i].entry ? 'E' : 'X'); }
    }
  }
  fprintf(f, "# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n# KEY_KTLR_IDX\t2\n# KEY_KGATE_IDX\t3\n");
  if (g->ohos)
    fprintf(f, "# KEY_TSDOFF_IDX\t4\n");
  closeout();
  f = output("gates.tsv");
  for (size_t i = 0; i < g->gates.n; i++) {
    Gate* x = g->gates.v + i;
    hex(f, x->ret);
    fprintf(f, "\t%s\t%d\t", x->kind, x->arg);
    hex(f, x->orig);
    fputc('\n', f);
  }
  closeout();
  if (g->wide.n) {
    f = output("widen.tsv");
    for (size_t i = 0; i < g->wide.n; i++) {
      Wide* x = g->wide.v + i;
      fprintf(f, "%d\t", x->idx);
      hex(f, x->off);
      fprintf(f, "\t%s\t0x%08x\n", x->kind, x->w);
    }
    closeout();
  } else
    remove_output("widen.tsv");
  f = output("sites.tsv");
  for (size_t i = 0; i < g->sites.n; i++)
    if (!g->sites.v[i].done) {
      hex(f, g->sites.v[i].at);
      fprintf(f, "\t%s\n", g->sites.v[i].kind);
    }
  for (size_t i = 0; i < g->windows.n; i++)
    for (size_t s = 0; s < g->windows.v[i].seg.n; s++) {
      IV* l = &g->windows.v[i].seg.v[s].ins;
      hex(f, l->v[0].at);
      fprintf(f, "\tW\t");
      hex(f, l->v[l->n - 1].at + 4);
      fputc('\n', f);
    }
  for (size_t i = 0; i < g->jumps.n; i++) {
    Jump* j = g->jumps.v + i;
    if (j->type == 1) {
      hex(f, j->at);
      fprintf(f, "\tJ\t");
      hex(f, j->base);
      fprintf(f, "\t%d\n", j->count);
    }
  }
  for (int type = 2; type <= 3; type++)
    for (size_t i = 0; i < g->jumps.n; i++) {
      Jump* j = g->jumps.v + i;
      if (j->type != type)
        continue;
      hex(f, j->at);
      fprintf(f, "\tJW\t");
      hex(f, type == 2 ? j->at + 12 : j->span.v[j->span.n - 1] + 4);
      fprintf(f, "\t%d\t%d\t%d\t", type == 2 ? 18 : j->I, j->count, j->B);
      hex(f, j->tbl);
      fputc('\t', f);
      for (int k = 0; k < j->count; k++) {
        if (k)
          fputc(',', f);
        hex(f, j->tbl + si(j->tbl + 4LL * k));
      }
      fputc('\n', f);
    }
  AV tails = {0};
  for (size_t i = 0; i < g->jumps.n; i++)
    if (g->jumps.v[i].type == 4)
      PUSH(tails, g->jumps.v[i].at);
  sort(&tails);
  for (size_t i = 0; i < tails.n; i++) {
    hex(f, tails.v[i]);
    fprintf(f, "\tx18\n");
    hex(f, tails.v[i]);
    fprintf(f, "\tTAIL\n");
  }
  for (size_t i = 0; i < g->jumps.n; i++) {
    Jump* j = g->jumps.v + i;
    if (j->type != 5)
      continue;
    hex(f, j->at);
    fprintf(f, "\tT\t");
    sort(&j->targets);
    for (size_t k = 0; k < j->targets.n; k++) {
      if (k)
        fputc(',', f);
      hex(f, j->targets.v[k]);
    }
    fputc('\n', f);
  }
  for (size_t i = 0; i < g->spins.n; i++) {
    SpinSite* s = g->spins.v + i;
    hex(f, s->head);
    fprintf(f, "\tS\t");
    for (size_t k = 0; k < s->backs.n; k++) {
      if (k)
        fputc(' ', f);
      hex(f, s->backs.v[k]);
    }
    fputc('\n', f);
  }
  closeout();
  msg("%s {", g->r.module);
  for (size_t i = 0; i < g->stats.n; i++)
    msg("%s'%s': %zu", i ? ", " : "", g->stats.v[i].key, g->stats.v[i].n);
  msg("} patch %zu PATCH_OFF ", g->patch.n * 4);
  if (g->log)
    hex(g->log, g->po);
  msg(" slot_refs %zu gates %zu\n", g->fixrefs, g->gates.n);
  return g->gaps.n ? 3 : 0;   /* 有缺口：产物照出、退 3（pack/stage_rewrite.sh 记降级继续；社区补丁轮按 3 认领缺口） */
}
static void load(void) {
  FILE* f = fopen(g->r.input, "rb");
  if (!f)
    fail("无法打开 NSO：%s", strerror(errno));
  g->out = f;
  REQUIRE(!fseek(f, 0, SEEK_END));
  long n = ftell(f);
  REQUIRE(n >= 256);
  REQUIRE(!fseek(f, 0, SEEK_SET));
  uint8_t* src = resize(NULL, n);
  REQUIRE(fread(src, 1, n, f) == (size_t)n);
  closeout();
  REQUIRE(!memcmp(src, "NSO0", 4));
  uint32_t fo[3], mo[3], sz[3], csz[3];
  for (int i = 0; i < 3; i++) {
    fo[i] = u32(src + 0x10 + 16 * i);
    mo[i] = u32(src + 0x14 + 16 * i);
    sz[i] = u32(src + 0x18 + 16 * i);
    csz[i] = u32(src + 0x60 + 4 * i);
    REQUIRE((uint64_t)fo[i] + csz[i] <= (uint64_t)n);
    REQUIRE(sz[i] <= INT_MAX && csz[i] <= INT_MAX);
  }
  uint32_t flags = u32(src + 12), bss = u32(src + 0x3c);
  uint64_t end = (uint64_t)mo[2] + sz[2], near = ((end + bss + 0x3fff) & ~0x3fffULL) + 0x4000;
  near = (near + 0xffff) & ~0xffffULL;
  g->far = near > 0x7000000;
  REQUIRE(end <= SIZE_MAX - 0x10000 && end + bss < UINT32_MAX);
  g->text = sz[0];
  g->ro = mo[1];
  g->data = mo[2];
  g->len = end + (g->far ? 0 : bss);
  REQUIRE(g->len >= 8 && g->text % 4 == 0);
  for (int i = 0; i < 3; i++)
    REQUIRE((uint64_t)mo[i] + sz[i] <= g->len);
  g->img = zalloc(g->len + 0x4000);
  for (int i = 0; i < 3; i++) {
    if ((flags >> i) & 1) {
      int got = LZ4_decompress_safe((const char*)src + fo[i], (char*)g->img + mo[i], csz[i], sz[i]);
      REQUIRE(got == (int)sz[i]);
    } else {
      REQUIRE(csz[i] >= sz[i]);
      memcpy(g->img + mo[i], src + fo[i], sz[i]);
    }
  }
  for (int i = 0; i < 16; i++)
    snprintf(g->id + 2 * i, 3, "%02x", src[0x40 + i]);
  g->dual = g->retry_dual;
  if (g->far) {
    A fm = (((1LL << 27) - (A)g->text - 0x100000) & ~65535LL);
    /* 带符号比（10-30 泡姆泡姆 text 0x8e64930 > 127 MB：fm 为负，原先转 size_t 后「≥ 1 MB」恒真，PATCH_OFF 变成正的 0xf70000、补丁区落进 text 中间）。
     * 单个前岛够不着整段 text（fm < 1 MB）就直接用双岛（前岛 + 键页后的后岛），同 patch_nso.py */
    if (!g->retry_front && fm < 0x100000)
      g->dual = 1;
    g->front = g->retry_front ? g->retry_front : g->dual ? 0x100000 : (size_t)MIN(0x2000000LL, fm);
    REQUIRE(g->front >= 0x100000);
    g->po = -(A)g->front;
    g->filelen = (g->len + 0x3fff) & ~0x3fffULL;
    g->key = (g->len + bss + 0x3fff) & ~0x3fffULL;
    g->imagesize = g->key + 0x4000;
    g->po2 = (g->imagesize + 0xffff) & ~0xffffULL;   /* 后岛：键页后按 64 KB 对齐（只在双岛下用） */
    g->split = g->po2 / 2;
  } else {
    /* 仅 Apple：data 起点落进 text 末尾所在的 16 KB 宿主页时，基址前移 bias 使「基址 + data」对齐宿主页；
     * 追加的键页、补丁区按同一网格对齐（同 patch_nso.py LOAD_BIAS / _al；不共页时 bias = 0，与原式相同） */
    g->bias = !noredzone() && g->data < ((g->text + 0x3fff) & ~(size_t)0x3fff) ? (0x4000 - (g->data & 0x3fff)) & 0x3fff : 0;
    g->key = ((g->len + g->bias + 0x3fff) & ~0x3fffULL) - g->bias;
    g->len += 0x4000;
    g->po = ((g->len + g->bias + 0xffff) & ~0xffffULL) - g->bias;
    /* 双岛的前岛：基址前 FRONT（映射从基址 − bias 起，前岛贴着它往前放，同一宿主页网格） */
    g->front = g->retry_front ? g->retry_front : 0x100000;
    g->po2 = -(A)(g->front + g->bias);
    g->split = g->po / 2;
  }
  REQUIRE(!(g->far && g->data < ((g->text + 0x3fff) & ~(size_t)0x3fff)));
  /* 原映像：自旋取锁分析与活跃分析（lv_get / lv_live，补丁岛挑死寄存器）都读它；放岛会就地改 g->img */
  g->orig = resize(NULL, g->len);
  memcpy(g->orig, g->img, g->len);
}
/* 自旋取锁补 acquire（11-04 1-2-Switch：游戏作业环的自旋锁取锁只用 ldxr/stxr、出循环后没有屏障就读锁内数据；ARMv8 允许这些读提前到
 *   取锁之前，Apple M 系列乱序激进，同一作业被两条线程各弹出一次而崩，真机 A57 窗口小没碰上；把取锁的 ldxr 换成 ldaxr 后 3 局 0 崩，
 *   不换 6 局全崩，见 docs/坑记录.md）。按指令形态识别，不看地址：
 *   ① ldxr（任意宽度，o0 = 0）后 8 条内有同基址的 stxr / stlxr，其后 3 条内 cbnz <状态寄存器> 回跳到 [ldxr − 16, ldxr]（重试环）；
 *   ② 存的不是零寄存器（存零 = 放锁形状）、存的寄存器不是读到的寄存器、环内没有指令改写存的寄存器（值在环外备好）；
 *   ③ 环内按读到的值回头等：cbz / cbnz <读到的寄存器> 或 b.cond 跳回 ≤ ldxr（读到非零就再等）；不回头等的是普通原子读改写 / CAS，不动；
 *   ④ 出环后顺着走（无条件 b 至多跟 3 跳、至多 12 条），先碰到的是普通读（ldr / ldp 各寻址、字面量 ldr），而不是 dmb / dsb / isb / ldar / ldapr。
 *   命中：只把这条 ldxr 置 bit 15 成 ldaxr（同寄存器同宽度、等长原地；顺序只会更严，按 ARMv8 内存模型不引入新的执行结果）。
 *   orig（开自旋改写时才有）同步改：自旋分析把它当原指令看（与 code_rows 一致）。选项 acq_off = 1 关（命令行 S2A_REWRITE_ACQ=0）。 */
static int acq_is_ldxr(uint32_t w) { return (w & 0x3FFFFC00u) == 0x085F7C00u; }
static int acq_is_stx(uint32_t w) { return (w & 0x3FE07C00u) == 0x08007C00u; }
static int acq_is_barrier(uint32_t w) { return (w & 0xFFFFF09Fu) == 0xD503309Fu; }
static int acq_is_ldar(uint32_t w) { return (w & 0x3FFFFC00u) == 0x08DFFC00u || (w & 0x3FFFFC00u) == 0x38BFC000u; }
static int acq_is_load(uint32_t w) {
  if ((w & 0x3B000000u) == 0x39000000u || (w & 0x3B200C00u) == 0x38000000u || (w & 0x3B200C00u) == 0x38000400u ||
      (w & 0x3B200C00u) == 0x38000C00u || (w & 0x3B200C00u) == 0x38200800u || (w & 0x3A000000u) == 0x28000000u)
    return (w >> 22) & 1;
  return (w & 0x3B000000u) == 0x18000000u;
}
static int acq_cb(uint32_t w, int* rt, A* d) { /* cbz / cbnz → 寄存器、相对字节 */
  if ((w & 0x7E000000u) != 0x34000000u) return 0;
  int64_t imm = (w >> 5) & 0x7FFFF; if (imm & 0x40000) imm -= 0x80000;
  *rt = (int)(w & 31); *d = (A)imm * 4; return 1;
}
static int acq_bcond(uint32_t w, A* d) {
  if ((w & 0xFF000010u) != 0x54000000u) return 0;
  int64_t imm = (w >> 5) & 0x7FFFF; if (imm & 0x40000) imm -= 0x80000;
  *d = (A)imm * 4; return 1;
}
static int acq_writes(uint32_t w) { /* 粗判整型数据处理 / 立即数搬移写的 Rd（bits 0–4）；不认的返回 −1 */
  uint32_t c = w & 0x1F000000u;
  if (c == 0x11000000u || c == 0x0B000000u || c == 0x0A000000u || c == 0x12000000u || c == 0x13000000u || c == 0x1A000000u ||
      (w & 0x1F800000u) == 0x12800000u)
    return (int)(w & 31);
  return -1;
}
static int acq_site(A i) { /* i = ldxr 的字节偏移；按上面 ①–④ 判，1 = 该升级 */
  A n = (A)g->text;
  uint32_t w = u32(g->img + i);
  int rn = (w >> 5) & 31, rt = w & 31;
  A j = -1;
  for (A k = i + 4; k <= i + 32 && k + 4 <= n; k += 4)
    if (acq_is_stx(u32(g->img + k)) && (int)((u32(g->img + k) >> 5) & 31) == rn) { j = k; break; }
  if (j < 0) return 0;
  uint32_t sw = u32(g->img + j);
  int rs = (sw >> 16) & 31, rdat = sw & 31;
  A e = -1;
  for (A k = j + 4; k <= j + 12 && k + 4 <= n; k += 4) {
    int r; A d;
    if (acq_cb(u32(g->img + k), &r, &d) && r == rs && k + d >= i - 16 && k + d <= i) { e = k + 4; break; }
  }
  if (e < 0 || rdat == 31 || rdat == rt) return 0;
  int back = 0;
  for (A k = i + 4; k < j; k += 4) {
    uint32_t x = u32(g->img + k); int r; A d;
    if (acq_writes(x) == rdat) return 0;
    if ((acq_cb(x, &r, &d) && r == rt && k + d <= i) || (acq_bcond(x, &d) && k + d <= i)) back = 1;
  }
  if (!back) return 0;
  A k = e;
  for (int step = 0, hops = 0; step < 12 && k >= 0 && k + 4 <= n; step++) {
    uint32_t x = u32(g->img + k);
    if ((x & 0xFC000000u) == 0x14000000u && hops < 3) {
      int64_t imm = x & 0x3FFFFFF; if (imm & 0x2000000) imm -= 0x4000000;
      k += (A)imm * 4; hops++; continue;
    }
    if (acq_is_barrier(x) || acq_is_ldar(x)) return 0;
    if (acq_is_load(x)) return 1;
    k += 4;
  }
  return 0;   /* 12 条内没有读（临界区只写）：不动 */
}
static void acq_upgrade(void) {
  if (g->acq_off) return;
  int n = 0;
  for (A i = 0; i + 4 <= (A)g->text; i += 4) {
    uint32_t w = u32(g->img + i);
    if (!acq_is_ldxr(w) || !acq_site(i)) continue;
    put(i, w | 0x8000u);
    if (g->orig) wr32(g->orig + i, w | 0x8000u);   /* 只有开自旋改写时才有 orig（load 时整份拷贝） */
    bump("acq_upgrade");
    if (n++ < 16) msg("自旋取锁补 acquire：0x%" PRIx64 " ldxr → ldaxr\n", i);
  }
  if (n) msg("自旋取锁补 acquire：共 %d 处%s\n", n, n > 16 ? "（上面只列前 16 处）" : "");
}
/* 独占存补 release（11-05 极品飞车热力追踪重制版 010029B0118E8000 出图停住：作业系统的续作链 / 空闲链用 16 字节标签指针，
 *   先普通 str 写节点内容（回调、参数、next），再 ldxp/stxp 把节点挂上链头，中间无屏障也不用 stlxp；ARMv8 允许链头先于节点内容
 *   被别的核看到，完成方取到链头、读到上一轮的回调 / 参数，主线程等的信号量永远没人释放）。本机 M5 Max 石蕊：普通 str → stxp 发布，
 *   读方按地址依赖读，3.3 亿次里约 0.2% 读到旧内容；换 stlxp 2.7 亿次 0 次（docs/坑记录.md）。
 *   按形态识别、不看地址：独占存（单 stxr* / 双 stxp，o0 = 0）且前 16 条内有独占取（任意宽度、带不带 acquire）＝ LL/SC 环里的存，
 *   只置 bit 15 成 stlxr* / stlxp（等长原地；release 只去掉「之前的读写晚于这次存被看见」这一种结果，按 ARMv8 内存模型不引入新的执行结果）。
 *   前面没有独占取的不动（代码段里碰巧长成这样的数据字）。orig（开自旋改写时才有）同步改。选项 rel_off = 1 关（命令行 S2A_REWRITE_REL=0）。 */
static int rel_is_stx(uint32_t w) { return (w & 0x3FE0FC00u) == 0x08007C00u || (w & 0xBFE08000u) == 0x88200000u; }   /* stxr/stxrb/stxrh、stxp（不含 CASP：bit 31 = 0） */
static int rel_is_ldx(uint32_t w) { return (w & 0x3FE00000u) == 0x08400000u || (w & 0xBFE00000u) == 0x88600000u; }   /* ldxr* / ldaxr*、ldxp / ldaxp */
static void rel_upgrade(void) {
  if (g->rel_off) return;
  int n = 0;
  for (A i = 0; i + 4 <= (A)g->text; i += 4) {
    uint32_t w = u32(g->img + i);
    if (!rel_is_stx(w)) continue;
    int ll = 0;
    for (A k = i - 4; k >= 0 && k >= i - 64; k -= 4)
      if (rel_is_ldx(u32(g->img + k))) { ll = 1; break; }
    if (!ll) continue;
    put(i, w | 0x8000u);
    if (g->orig) wr32(g->orig + i, w | 0x8000u);
    bump("rel_upgrade");
    if (n++ < 16) msg("独占存补 release：0x%" PRIx64 " %s → %s\n", i, (w >> 21) & 1 ? "stxp" : "stxr", (w >> 21) & 1 ? "stlxp" : "stlxr");
  }
  if (n) msg("独占存补 release：共 %d 处%s\n", n, n > 16 ? "（上面只列前 16 处）" : "");
}
static int attempt(const s2a_rewrite_request* r, const s2a_rewrite_options* options, FILE* log, size_t* front, int* dual,
                   Pair** carry, size_t* ncarry) {
  RW *prev = g, *ctx = calloc(1, sizeof(*ctx));
  if (!ctx)
    return 1;
  g = ctx;
  g->r = *r;
  g->retry_front = *front;
  g->retry_dual = *dual;
  g->req = *carry;
  g->nreq = *ncarry;
  g->log = log;
  g->sdk_cut = !options || options->sdk_addr_cut != 0;
  g->signed_jt = options && options->signed_jt;
  g->acq_off = options && options->acq_off;
  g->rel_off = options && options->rel_off;
  int rc = 1;
  if (!setjmp(g->err)) {
    const char* t = r->target && r->target[0] ? r->target : "apple";
    if (!in(t, "apple|ios|macos|android|ohos"))
      fail("S2A_TARGET 只认 apple / ios / macos / android / ohos：%s", t);
    g->android = eq(t, "android");
    g->ohos = eq(t, "ohos");
    int maj, min;
    cs_version(&maj, &min);
    REQUIRE(maj == 5 && min == 0);
    REQUIRE(cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &g->cs) == CS_ERR_OK);
    REQUIRE(cs_option(g->cs, CS_OPT_DETAIL, CS_OPT_ON) == CS_ERR_OK);
    g->one = cs_malloc(g->cs);
    REQUIRE(g->one);
    load();
    fps_rows(0);
    cpatch_rows(0);
    code_rows();
    acq_upgrade();
    rel_upgrade();
    sdk_addr_cut();
    boundaries();
    scan();
    data_in_text();
    analyze();
    generate();
    sdk_aregion();
    widen();
    fps_rows(1);
    cpatch_rows(1);
    spins();
    rc = outputs();
  } else
    msg("🔴 改写失败：%s\n", g->error);
  if (g->out)
    fclose(g->out);
  if (g->one)
    cs_free(g->one, 1);
  if (g->cs)
    cs_close(&g->cs);
  Alloc* a = g->allocs;
  while (a) {
    Alloc* n = a->links.next;
    free(a);
    a = n;
  }
  if (rc == RETRY_RC) {   /* 带出下一轮布局与本轮成功的自旋回边；每轮从原 NSO 重新生成所有地址相关指令 */
    free(*carry);
    *front = g->next_front;
    *dual = g->next_dual;
    if (g->dual || g->next_dual) {   /* 双岛不带自旋回边（够不着的另出表头 SPIN_UNREACHED） */
      free(g->now);
      *carry = NULL;
      *ncarry = 0;
    } else {
      *carry = g->now;
      *ncarry = g->nnow;
    }
  } else
    free(g->now);
  free(ctx);
  g = prev;
  return rc;
}
int s2a_rewrite_files_with_options(const s2a_rewrite_request* r,
                                 const s2a_rewrite_options* options, FILE* log) {
  if (!r || !r->input || !r->output_dir || !r->module || !r->module[0] || strchr(r->module, '/') ||
      strchr(r->module, '\\') || eq(r->module, ".") || eq(r->module, ".."))
    return 1;
  size_t front = 0, ncarry = 0;
  int dual = 0;
  Pair* carry = NULL;
  int rc;
  while ((rc = attempt(r, options, log, &front, &dual, &carry, &ncarry)) == RETRY_RC) {
  }
  free(carry);
  return rc;
}
int s2a_rewrite_files(const s2a_rewrite_request* r, FILE* log) {
  return s2a_rewrite_files_with_options(r, NULL, log);
}
