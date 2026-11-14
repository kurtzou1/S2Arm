// 缺页处模拟写指令（接口与动机见 runtime/include/s2a_emul_st.h）。编码按 Arm A64 指令集「Loads and Stores」一节逐类解码，与 emul_ld.c 对称：
// 单寄存器（立即数 / 未缩放 / 前后变址 / 寄存器偏移）、寄存器对（STP / STNP）、写释放（STLR / STLLR）、SIMD 结构写（ST1–ST4 多寄存器 / 单通道）。
// 独占（STXR / STLXR）、原子（STADD / SWP / CAS …）、带标签（STG / STGP）、写回基址与源寄存器同一寄存器等「不可预测」组合一律返回 0。
#include "s2a_emul_st.h"
#include <string.h>

static inline uint64_t bits(uint32_t v, int hi, int lo) { return (v >> lo) & ((1u << (hi - lo + 1)) - 1); }
static inline int64_t sext(uint64_t v, int n) { return (int64_t)(v << (64 - n)) >> (64 - n); }
static uint64_t rd_base(const s2a_regs *r, unsigned n) { return n == 31 ? r->sp : r->x[n]; }
static void wr_base(s2a_regs *r, unsigned n, uint64_t v) { if (n == 31) r->sp = v; else r->x[n] = v; }
static uint64_t rd_x(const s2a_regs *r, unsigned m) { return m == 31 ? 0 : r->x[m]; }   // 源 / 偏移寄存器 31 = XZR
static int allow(uint64_t ea, uint64_t len, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok) { return ea >= lo && ea + len >= ea && ea + len <= hi && (!ok || ok(ea, len)); }
// 写进别名：按对齐取最大宽度（8 / 4 / 2 / 1 字节）逐块原子存储，别的核读同一处不会读到半写（硬件对自然对齐的单寄存器写保证单次拷贝原子；
// Q / 寄存器对拆成 8 字节各自原子，与硬件一致；不对齐的段按字节写，硬件此时也不保证原子）。不用 memcpy：编译器可能拆成任意宽度
static void st_bytes(uint64_t dst, const uint8_t *src, uint64_t len) {
    while (len) {
        if (len >= 8 && !(dst & 7)) { uint64_t v; memcpy(&v, src, 8); __atomic_store_n((uint64_t *)(uintptr_t)dst, v, __ATOMIC_RELAXED); dst += 8; src += 8; len -= 8; }
        else if (len >= 4 && !(dst & 3)) { uint32_t v; memcpy(&v, src, 4); __atomic_store_n((uint32_t *)(uintptr_t)dst, v, __ATOMIC_RELAXED); dst += 4; src += 4; len -= 4; }
        else if (len >= 2 && !(dst & 1)) { uint16_t v; memcpy(&v, src, 2); __atomic_store_n((uint16_t *)(uintptr_t)dst, v, __ATOMIC_RELAXED); dst += 2; src += 2; len -= 2; }
        else { __atomic_store_n((uint8_t *)(uintptr_t)dst, *src, __ATOMIC_RELAXED); dst++; src++; len--; }
    }
}

// 一条写的完整描述：最多 4 段（ST4 多寄存器按元素交织，统一展开成字节流 buf）
typedef struct { uint64_t ea, len; uint8_t buf[64]; int wb; unsigned n; uint64_t nb; int rel; } st_t;

// 单寄存器类：opc 是写的才认（GPR opc = 00；SIMD opc 偶数，opc = 10 且 size = 00 是 Q）
static int single_store(unsigned size, unsigned V, unsigned opc, unsigned *nbytes, unsigned *scale) {
    if (V) {
        if (opc & 1) return 0;                                       // SIMD 读
        if (opc & 2) { if (size != 0) return 0; *nbytes = 16; *scale = 4; return 1; }
        *nbytes = 1u << size; *scale = size; return 1;
    }
    if (opc != 0) return 0;                                          // 读 / 预取
    *nbytes = 1u << size; *scale = size; return 1;
}
static void put_src(const s2a_regs *r, unsigned t, unsigned V, unsigned nb, uint8_t *out) {
    if (V) memcpy(out, r->v[t], nb); else { uint64_t v = rd_x(r, t); memcpy(out, &v, nb); }
}

static int simd_multi(uint32_t i, const s2a_regs *r, st_t *s) {
    unsigned Q = bits(i, 30, 30), wb = bits(i, 23, 23), m = bits(i, 20, 16), opcode = bits(i, 15, 12), size = bits(i, 11, 10), n = bits(i, 9, 5), t = bits(i, 4, 0);
    if (bits(i, 22, 22) || bits(i, 21, 21)) return 0;               // L = 0：写
    if (!wb && m != 0) return 0;
    unsigned rpt, selem;
    switch (opcode) {
        case 0: rpt = 1; selem = 4; break;
        case 2: rpt = 4; selem = 1; break;
        case 4: rpt = 1; selem = 3; break;
        case 6: rpt = 3; selem = 1; break;
        case 7: rpt = 1; selem = 1; break;
        case 8: rpt = 1; selem = 2; break;
        case 10: rpt = 2; selem = 1; break;
        default: return 0;
    }
    if (size == 3 && !Q && selem != 1) return 0;
    unsigned eb = 1u << size, rb = Q ? 16 : 8, elems = rb / eb, total = rb * rpt * selem;
    s->ea = rd_base(r, n); s->len = total; s->wb = wb; s->n = n; s->nb = m == 31 ? total : rd_x(r, m);
    uint64_t off = 0;
    for (unsigned rr = 0; rr < rpt; rr++)
        for (unsigned e = 0; e < elems; e++)
            for (unsigned k = 0; k < selem; k++) { memcpy(s->buf + off, &r->v[(t + rr + k) % 32][e * eb], eb); off += eb; }
    return 1;
}

static int simd_single(uint32_t i, const s2a_regs *r, st_t *s) {
    unsigned Q = bits(i, 30, 30), wb = bits(i, 23, 23), R = bits(i, 21, 21), m = bits(i, 20, 16), opcode = bits(i, 15, 13), S = bits(i, 12, 12), size = bits(i, 11, 10), n = bits(i, 9, 5), t = bits(i, 4, 0);
    if (bits(i, 22, 22)) return 0;                                   // L = 0：写
    if (!wb && m != 0) return 0;
    unsigned scale = opcode >> 1, selem = ((opcode & 1) << 1 | R) + 1, index = 0;
    switch (scale) {
        case 3: return 0;                                            // 复制（LDnR）只有读
        case 0: index = Q << 3 | S << 2 | size; break;
        case 1: if (size & 1) return 0; index = Q << 2 | S << 1 | (size >> 1); break;
        case 2: if (size & 2) return 0; if (!(size & 1)) index = Q << 1 | S; else { if (S) return 0; index = Q; scale = 3; } break;
    }
    unsigned eb = 1u << scale, total = eb * selem;
    s->ea = rd_base(r, n); s->len = total; s->wb = wb; s->n = n; s->nb = m == 31 ? total : rd_x(r, m);
    for (unsigned k = 0; k < selem; k++) memcpy(s->buf + k * eb, &r->v[(t + k) % 32][index * eb], eb);
    return 1;
}

static int decode(uint32_t i, const s2a_regs *r, st_t *s) {
    memset(s, 0, sizeof *s);
    unsigned size = bits(i, 31, 30), V = bits(i, 26, 26), opc = bits(i, 23, 22), n = bits(i, 9, 5), t = bits(i, 4, 0), nb, sc;
    // 单寄存器，无符号立即数偏移
    if (bits(i, 29, 27) == 7 && bits(i, 25, 24) == 1) {
        if (!single_store(size, V, opc, &nb, &sc)) return 0;
        s->ea = rd_base(r, n) + (bits(i, 21, 10) << sc); s->len = nb; put_src(r, t, V, nb, s->buf); return 1;
    }
    if (bits(i, 29, 27) == 7 && bits(i, 25, 24) == 0) {
        if (!bits(i, 21, 21)) {   // 未缩放 / 后变址 / 非特权 / 前变址（imm9）
            unsigned idx = bits(i, 11, 10);
            if (!single_store(size, V, opc, &nb, &sc)) return 0;
            int64_t imm = sext(bits(i, 20, 12), 9); uint64_t base = rd_base(r, n);
            int wb = idx == 1 || idx == 3;
            if (wb && !V && n == t && n != 31) return 0;             // 写回基址与源同一寄存器：不可预测
            s->ea = idx == 1 ? base : base + (uint64_t)imm; s->len = nb; put_src(r, t, V, nb, s->buf);
            if (wb) { s->wb = 2; s->n = n; s->nb = base + (uint64_t)imm; }
            return 1;
        }
        if (bits(i, 11, 10) == 2) {   // 寄存器偏移
            if (!single_store(size, V, opc, &nb, &sc)) return 0;
            unsigned m = bits(i, 20, 16), opt = bits(i, 15, 13), S = bits(i, 12, 12);
            uint64_t off = rd_x(r, m);
            switch (opt) { case 2: off = (uint32_t)off; break; case 3: break; case 6: off = (uint64_t)(int64_t)(int32_t)off; break; case 7: break; default: return 0; }
            s->ea = rd_base(r, n) + (off << (S ? sc : 0)); s->len = nb; put_src(r, t, V, nb, s->buf); return 1;
        }
        return 0;   // 原子（STADD / SWP / CAS …）：不模拟
    }
    // 寄存器对：STP / STNP（偏移 / 前后变址），L = 0
    if (bits(i, 29, 27) == 5 && !bits(i, 25, 25) && !bits(i, 22, 22)) {   // idx = bits 25:23：000 STNP、001 后变址、010 偏移、011 前变址
        unsigned idx = bits(i, 25, 23), t2 = bits(i, 14, 10), eb;
        if (V) { if (size == 3) return 0; eb = 4u << size; }
        else { if (size == 1 || size == 3) return 0; eb = size == 2 ? 8 : 4; }   // size 01 = STGP（带标签）：不模拟
        int64_t imm = sext(bits(i, 21, 15), 7) * (int64_t)eb; uint64_t base = rd_base(r, n);
        int wb = idx == 1 || idx == 3;
        if (wb && !V && n != 31 && (n == t || n == t2)) return 0;
        s->ea = idx == 1 ? base : base + (uint64_t)imm; s->len = 2 * eb;
        put_src(r, t, V, eb, s->buf); put_src(r, t2, V, eb, s->buf + eb);
        if (wb) { s->wb = 2; s->n = n; s->nb = base + (uint64_t)imm; }
        return 1;
    }
    // STLR / STLLR（写释放，无偏移）：bits 31:30 size、29:24 = 001000、23 = 1、22 L = 0、21 = 0、20:16 = 11111、15 o0、14:10 = 11111
    if ((i & 0x3FFF7C00u) == 0x089F7C00u) {
        nb = 1u << size; s->ea = rd_base(r, n); s->len = nb; put_src(r, t, 0, nb, s->buf); s->rel = 1; return 1;
    }
    // SIMD 结构写：ST1–ST4 多寄存器 / 单通道（含后变址）
    if (bits(i, 31, 31) == 0 && (bits(i, 29, 23) == 0x18 || bits(i, 29, 23) == 0x19)) return simd_multi(i, r, s);
    if (bits(i, 31, 31) == 0 && (bits(i, 29, 23) == 0x1A || bits(i, 29, 23) == 0x1B)) return simd_single(i, r, s);
    return 0;
}

int s2a_emul_store_decode(uint32_t insn, const s2a_regs *r, uint64_t *ea_out, uint64_t *len_out) {
    st_t s; int h = decode(insn, r, &s);
    if (ea_out) *ea_out = h ? s.ea : 0;
    if (len_out) *len_out = h ? s.len : 0;
    return h;
}

int s2a_emul_store_regs(uint32_t insn, s2a_regs *r, uint64_t delta, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out) {
    st_t s; int h = decode(insn, r, &s);
    if (ea_out) *ea_out = h ? s.ea : 0;
    if (len_out) *len_out = h ? s.len : 0;
    if (!h || !allow(s.ea, s.len, lo, hi, ok)) return 0;
    if (s.rel) __atomic_thread_fence(__ATOMIC_RELEASE);
    st_bytes(s.ea + delta, s.buf, s.len);
    // SIMD 结构写：wb = 1，偏移来自 nb（立即数 = 总长、或寄存器）；单寄存器 / 对：wb = 2，nb 已是新基址
    if (s.wb == 1) wr_base(r, s.n, s.ea + s.nb);
    else if (s.wb == 2) wr_base(r, s.n, s.nb);
    return 1;
}

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))   // 苹果 ucontext 版；安卓的信号上下文拷贝在 emul_sp.c
#include <sys/ucontext.h>
int s2a_emul_store(void *ucv, uint64_t fault_addr, uint8_t *dst, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out) {
    ucontext_t *uc = ucv; _STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss; _STRUCT_ARM_NEON_STATE64 *ns = &uc->uc_mcontext->__ns;
    if (!dst) return 0;
    uint32_t insn = *(const uint32_t *)(uintptr_t)ss->__pc;
    s2a_regs r;
    for (int k = 0; k < 29; k++) r.x[k] = ss->__x[k];
    r.x[29] = ss->__fp; r.x[30] = ss->__lr; r.sp = ss->__sp;
    for (int k = 0; k < 32; k++) memcpy(r.v[k], &ns->__v[k], 16);
    uint64_t page = fault_addr & ~0x3FFFull;
    if (!s2a_emul_store_regs(insn, &r, (uint64_t)(uintptr_t)dst - fault_addr, page, page + 0x4000, ok, ea_out, len_out)) return 0;
    for (int k = 0; k < 29; k++) ss->__x[k] = r.x[k];
    ss->__fp = r.x[29]; ss->__lr = r.x[30]; ss->__sp = r.sp;
    ss->__pc += 4;
    return 1;
}
#endif
