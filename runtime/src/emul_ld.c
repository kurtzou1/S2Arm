// 缺页处模拟读指令（接口与动机见 runtime/include/s2a_emul_ld.h）。编码按 Arm A64 指令集「Loads and Stores」一节逐类解码；
// 不认识的、写类、独占 / 原子、架构上「不可预测」的组合一律返回 0，由调用方走老路（整页回写后重执行），不会读错。
#include "s2a_emul_ld.h"
#include <string.h>

static inline uint64_t bits(uint32_t v, int hi, int lo) { return (v >> lo) & ((1u << (hi - lo + 1)) - 1); }
static inline int64_t sext(uint64_t v, int n) { return (int64_t)(v << (64 - n)) >> (64 - n); }

static uint64_t rd_base(const s2a_regs *r, unsigned n) { return n == 31 ? r->sp : r->x[n]; }
static void wr_base(s2a_regs *r, unsigned n, uint64_t v) { if (n == 31) r->sp = v; else r->x[n] = v; }
static uint64_t rd_x(const s2a_regs *r, unsigned m) { return m == 31 ? 0 : r->x[m]; }   // 偏移寄存器 31 = XZR
static void wr_x(s2a_regs *r, unsigned t, uint64_t v) { if (t != 31) r->x[t] = v; }    // 目标寄存器 31 = XZR（丢弃）

// 越出 [lo, hi)（含溢出）或回调拒绝 = 不模拟
static int allow(uint64_t ea, uint64_t len, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok) { return ea >= lo && ea + len >= ea && ea + len <= hi && (!ok || ok(ea, len)); }

static uint64_t ld_le(uint64_t a, unsigned n) { uint64_t v = 0; memcpy(&v, (const void *)(uintptr_t)a, n); return v; }

// GPR 单寄存器读：size 0..3，opc 01 零扩展 / 10 符号扩展到 64 位 / 11 符号扩展到 32 位
static int gpr_load(s2a_regs *r, unsigned t, uint64_t src, unsigned size, unsigned opc) {
    unsigned n = 1u << size; uint64_t v = ld_le(src, n);
    if (opc == 1) { wr_x(r, t, v); return 1; }
    if (opc == 2) { wr_x(r, t, size == 3 ? v : (uint64_t)sext(v, (int)n * 8)); return 1; }
    if (opc == 3) { wr_x(r, t, (uint32_t)sext(v, (int)n * 8)); return 1; }
    return 0;
}
// SIMD 单寄存器读：n 字节进 V[t] 低位，其余清零
static void simd_load(s2a_regs *r, unsigned t, uint64_t src, unsigned n) { memset(r->v[t], 0, 16); memcpy(r->v[t], (const void *)(uintptr_t)src, n); }

// 单寄存器类：判出 GPR / SIMD、字节数，opc 不是读的返回 0
static int single_kind(unsigned size, unsigned V, unsigned opc, unsigned *nbytes, unsigned *scale) {
    if (V) {
        if (!(opc & 1)) return 0;                                    // SIMD 写
        if (opc & 2) { if (size != 0) return 0; *nbytes = 16; *scale = 4; return 1; }   // Q（128 位）
        *nbytes = 1u << size; *scale = size; return 1;
    }
    if (opc == 0) return 0;                                          // 写
    if (size == 3 && opc >= 2) return 0;                             // PRFM / 未分配
    if (size == 2 && opc == 3) return 0;
    *nbytes = 1u << size; *scale = size; return 1;
}

int s2a_emul_class(uint32_t i) {
    unsigned size = bits(i, 31, 30), V = bits(i, 26, 26), opc = bits(i, 23, 22), nb, sc;
    if (bits(i, 29, 27) == 7 && bits(i, 25, 24) == 1) return single_kind(size, V, opc, &nb, &sc) ? 1 : 8;
    if (bits(i, 29, 27) == 7 && bits(i, 25, 24) == 0) {
        if (!bits(i, 21, 21)) return single_kind(size, V, opc, &nb, &sc) ? 2 : 8;
        if (bits(i, 11, 10) == 2) return single_kind(size, V, opc, &nb, &sc) ? 3 : 8;
        return (i & 0x3FFFFC00u) == 0x38BFC000u ? 5 : 6;          // LDAPR / 原子
    }
    if (bits(i, 29, 27) == 5 && !bits(i, 25, 25)) return bits(i, 22, 22) ? 4 : 8;   // 寄存器对
    if (bits(i, 29, 24) == 8) return bits(i, 23, 23) ? (bits(i, 22, 22) ? 5 : 8) : (bits(i, 22, 22) ? 6 : 8);   // 载入获取 / 独占
    if (!bits(i, 31, 31) && bits(i, 29, 23) >= 0x18 && bits(i, 29, 23) <= 0x1B) return bits(i, 22, 22) ? 7 : 8;
    return 0;
}

static int simd_multi(uint32_t i, s2a_regs *r, uint64_t delta, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out) {
    unsigned Q = bits(i, 30, 30), wb = bits(i, 23, 23), m = bits(i, 20, 16), opcode = bits(i, 15, 12), size = bits(i, 11, 10), n = bits(i, 9, 5), t = bits(i, 4, 0);
    if (!bits(i, 22, 22) || bits(i, 21, 21)) return 0;
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
    uint64_t ea = rd_base(r, n);
    if (ea_out) *ea_out = ea;
    if (len_out) *len_out = total;
    if (!allow(ea, total, lo, hi, ok)) return 0;
    uint8_t nv[32][16]; memcpy(nv, r->v, sizeof nv);
    for (unsigned k = 0; k < rpt * selem; k++) memset(nv[(t + k) % 32], 0, 16);   // 整寄存器写：Q=0 时高 64 位清零
    uint64_t off = 0;
    for (unsigned rr = 0; rr < rpt; rr++)
        for (unsigned e = 0; e < elems; e++)
            for (unsigned s = 0; s < selem; s++) {
                unsigned reg = (t + rr + s) % 32;
                memcpy(&nv[reg][e * eb], (const void *)(uintptr_t)(ea + delta + off), eb);
                off += eb;
            }
    memcpy(r->v, nv, sizeof nv);
    if (wb) wr_base(r, n, ea + (m == 31 ? total : rd_x(r, m)));
    return 1;
}

static int simd_single(uint32_t i, s2a_regs *r, uint64_t delta, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out) {
    unsigned Q = bits(i, 30, 30), wb = bits(i, 23, 23), R = bits(i, 21, 21), m = bits(i, 20, 16), opcode = bits(i, 15, 13), S = bits(i, 12, 12), size = bits(i, 11, 10), n = bits(i, 9, 5), t = bits(i, 4, 0);
    if (!bits(i, 22, 22)) return 0;
    if (!wb && m != 0) return 0;
    unsigned scale = opcode >> 1, selem = ((opcode & 1) << 1 | R) + 1, index = 0; int rep = 0;
    switch (scale) {
        case 3: if (S) return 0; rep = 1; scale = size; break;
        case 0: index = Q << 3 | S << 2 | size; break;
        case 1: if (size & 1) return 0; index = Q << 2 | S << 1 | (size >> 1); break;
        case 2: if (size & 2) return 0; if (!(size & 1)) index = Q << 1 | S; else { if (S) return 0; index = Q; scale = 3; } break;
    }
    unsigned eb = 1u << scale, total = eb * selem;
    uint64_t ea = rd_base(r, n);
    if (ea_out) *ea_out = ea;
    if (len_out) *len_out = total;
    if (!allow(ea, total, lo, hi, ok)) return 0;
    uint8_t nv[32][16]; memcpy(nv, r->v, sizeof nv);
    for (unsigned s = 0; s < selem; s++) {
        unsigned reg = (t + s) % 32; const void *src = (const void *)(uintptr_t)(ea + delta + (uint64_t)s * eb);
        if (rep) { unsigned rb = Q ? 16 : 8; memset(nv[reg], 0, 16); for (unsigned o = 0; o < rb; o += eb) memcpy(&nv[reg][o], src, eb); }
        else memcpy(&nv[reg][index * eb], src, eb);
    }
    memcpy(r->v, nv, sizeof nv);
    if (wb) wr_base(r, n, ea + (m == 31 ? total : rd_x(r, m)));
    return 1;
}

int s2a_emul_load_regs(uint32_t i, s2a_regs *r, uint64_t delta, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out) {
    if (ea_out) *ea_out = 0;
    if (len_out) *len_out = 0;
    unsigned size = bits(i, 31, 30), V = bits(i, 26, 26), opc = bits(i, 23, 22), n = bits(i, 9, 5), t = bits(i, 4, 0), nb, sc;

    // 单寄存器，无符号立即数偏移
    if (bits(i, 29, 27) == 7 && bits(i, 25, 24) == 1) {
        if (!single_kind(size, V, opc, &nb, &sc)) return 0;
        uint64_t ea = rd_base(r, n) + (bits(i, 21, 10) << sc);
        if (ea_out) *ea_out = ea;
        if (len_out) *len_out = nb;
        if (!allow(ea, nb, lo, hi, ok)) return 0;
        if (V) simd_load(r, t, ea + delta, nb); else if (!gpr_load(r, t, ea + delta, size, opc)) return 0;
        return 1;
    }
    if (bits(i, 29, 27) == 7 && bits(i, 25, 24) == 0) {
        if (!bits(i, 21, 21)) {   // 未缩放 / 后变址 / 非特权 / 前变址（imm9）
            unsigned idx = bits(i, 11, 10);
            if (!single_kind(size, V, opc, &nb, &sc)) return 0;
            int64_t imm = sext(bits(i, 20, 12), 9); uint64_t base = rd_base(r, n), ea = idx == 1 ? base : base + (uint64_t)imm;
            int wb = idx == 1 || idx == 3;
            if (wb && !V && n == t && n != 31) return 0;             // 回写基址与目标同一寄存器：不可预测
            if (ea_out) *ea_out = ea;
            if (len_out) *len_out = nb;
            if (!allow(ea, nb, lo, hi, ok)) return 0;
            if (V) simd_load(r, t, ea + delta, nb); else if (!gpr_load(r, t, ea + delta, size, opc)) return 0;
            if (wb) wr_base(r, n, base + (uint64_t)imm);
            return 1;
        }
        if (bits(i, 11, 10) == 2) {   // 寄存器偏移
            if (!single_kind(size, V, opc, &nb, &sc)) return 0;
            unsigned m = bits(i, 20, 16), opt = bits(i, 15, 13), S = bits(i, 12, 12);
            uint64_t off = rd_x(r, m);
            switch (opt) { case 2: off = (uint32_t)off; break; case 3: break; case 6: off = (uint64_t)(int64_t)(int32_t)off; break; case 7: break; default: return 0; }
            uint64_t ea = rd_base(r, n) + (off << (S ? sc : 0));
            if (ea_out) *ea_out = ea;
            if (len_out) *len_out = nb;
            if (!allow(ea, nb, lo, hi, ok)) return 0;
            if (V) simd_load(r, t, ea + delta, nb); else if (!gpr_load(r, t, ea + delta, size, opc)) return 0;
            return 1;
        }
        if ((i & 0x3FFFFC00u) == 0x38BFC000u) {   // LDAPR：基址读 + 获取语义
            nb = 1u << size; uint64_t ea = rd_base(r, n);
            if (ea_out) *ea_out = ea;
            if (len_out) *len_out = nb;
            if (!allow(ea, nb, lo, hi, ok)) return 0;
            wr_x(r, t, ld_le(ea + delta, nb)); __atomic_thread_fence(__ATOMIC_ACQUIRE); return 1;
        }
        return 0;   // 原子（LDADD / CAS / SWP …）：不模拟
    }
    // 寄存器对：LDP / LDPSW / LDNP（偏移 / 前后变址）
    if (bits(i, 29, 27) == 5 && !bits(i, 25, 25) && bits(i, 22, 22)) {   // idx = bits 25:23：000 LDNP、001 后变址、010 偏移、011 前变址
        unsigned idx = bits(i, 25, 23), t2 = bits(i, 14, 10), eb; int sx = 0;
        if (V) { if (size == 3) return 0; eb = 4u << size; }
        else { if (size == 3 || (size == 1 && idx == 0)) return 0; eb = size == 2 ? 8 : 4; sx = size == 1; }
        if (t == t2) return 0;                                       // 读同一寄存器两次：不可预测
        int64_t imm = sext(bits(i, 21, 15), 7) * (int64_t)eb; uint64_t base = rd_base(r, n), ea = idx == 1 ? base : base + (uint64_t)imm;
        int wb = idx == 1 || idx == 3;
        if (wb && !V && n != 31 && (n == t || n == t2)) return 0;
        if (ea_out) *ea_out = ea;
        if (len_out) *len_out = 2 * eb;
        if (!allow(ea, 2 * eb, lo, hi, ok)) return 0;
        if (V) { simd_load(r, t, ea + delta, eb); simd_load(r, t2, ea + delta + eb, eb); }
        else {
            uint64_t a = ld_le(ea + delta, eb), b = ld_le(ea + delta + eb, eb);
            if (sx) { a = (uint64_t)sext(a, 32); b = (uint64_t)sext(b, 32); }
            wr_x(r, t, a); wr_x(r, t2, b);
        }
        if (wb) wr_base(r, n, base + (uint64_t)imm);
        return 1;
    }
    // LDAR / LDLAR（载入获取，无偏移）
    if ((i & 0x3FFF7C00u) == 0x08DF7C00u) {
        nb = 1u << size; uint64_t ea = rd_base(r, n);
        if (ea_out) *ea_out = ea;
        if (len_out) *len_out = nb;
        if (!allow(ea, nb, lo, hi, ok)) return 0;
        wr_x(r, t, ld_le(ea + delta, nb)); __atomic_thread_fence(__ATOMIC_ACQUIRE); return 1;
    }
    // SIMD 结构读：LD1–LD4 多寄存器 / 单通道 / 复制（含后变址）
    if (bits(i, 31, 31) == 0 && (bits(i, 29, 23) == 0x18 || bits(i, 29, 23) == 0x19)) return simd_multi(i, r, delta, lo, hi, ok, ea_out, len_out);
    if (bits(i, 31, 31) == 0 && (bits(i, 29, 23) == 0x1A || bits(i, 29, 23) == 0x1B)) return simd_single(i, r, delta, lo, hi, ok, ea_out, len_out);
    return 0;
}

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))   // 苹果 ucontext 版；安卓的信号上下文拷贝在 emul_sp.c
#include <sys/ucontext.h>
int s2a_emul_load(void *ucv, uint64_t fault_addr, const uint8_t *src, s2a_emul_ok_fn ok) {
    ucontext_t *uc = ucv; _STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss; _STRUCT_ARM_NEON_STATE64 *ns = &uc->uc_mcontext->__ns;
    if (!src) return 0;
    uint32_t insn = *(const uint32_t *)(uintptr_t)ss->__pc;
    s2a_regs r;
    for (int k = 0; k < 29; k++) r.x[k] = ss->__x[k];
    r.x[29] = ss->__fp; r.x[30] = ss->__lr; r.sp = ss->__sp;
    for (int k = 0; k < 32; k++) memcpy(r.v[k], &ns->__v[k], 16);
    uint64_t page = fault_addr & ~0x3FFFull;
    if (!s2a_emul_load_regs(insn, &r, (uint64_t)(uintptr_t)src - fault_addr, page, page + 0x4000, ok, NULL, NULL)) return 0;
    for (int k = 0; k < 29; k++) ss->__x[k] = r.x[k];
    ss->__fp = r.x[29]; ss->__lr = r.x[30]; ss->__sp = r.sp;
    for (int k = 0; k < 32; k++) memcpy(&ns->__v[k], r.v[k], 16);
    ss->__pc += 4;
    return 1;
}
#endif
