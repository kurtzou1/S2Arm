#pragma once
#include <stdint.h>
#include <string.h>
#include "nvn_obj.h"

typedef struct {
    const void *vs, *fs; uint32_t cfmt[8], dfmt, sfmt, samples, blend_en, chmask; uint8_t a2c, fc, at, msoff; blend_st blend[8];
    // at / msoff (gap families 34 / 37, 11-01): the fragment main0 / main0_u specialized with S2A_AT = the NVN alpha function (1 NEVER … 7 GEQUAL; 0 = no alpha test) and S2A_MSOFF
    //   (multisampling off on a multisampled target). They take the last two padding bytes after fc: size and layout unchanged, a key with both 0 is byte for byte the key recorded before
    // fc: the fragment function is the shader's sampler-emulation variant specialized with these SE_* bits (nvn_red.h; nvn_mtl.m se_fn), 0 = the library's main0. It takes a byte of what
    //   was a 32-bit a2c holding 0 / 1: the layout and size are unchanged, so an fc 0 key is byte for byte the key recorded before (pso_user.tsv / pso_manifest.tsv R lines, the pipeline
    //   archive, pso_seed.py's length check)
    va_st attr[16]; vs_st stream[16];
    uint8_t lmap[8]; const void *fsfn;
} pso_key;

// Dual-source blending: a normal pass whose attachment 0 blends with a SRC1 factor (NVNblendFunc SRC1_COLOR … ONE_MINUS_SRC1_ALPHA, 0x10–0x13, nvn.h) reads the fragment shader's second
//   colour output as source 1 (Maxwell; Ryujinx StateUpdater sets DualSourceBlendEnable from the same four factors and its translator then declares outputs 0 / 1 as location 0 index 0 / 1).
//   Metal takes source 1 only from [[color(0), index(1)]] and only on attachment 0, and refuses the pipeline when the fragment function has none ("does not write to render target color(0),
//   index(1) that is required for blending", 11-02 Skyward Sword HD). The library's main0 declares output 1 as [[color(1)]] (the translation does not know the blend state), so such a pipeline
//   needs the typed-output entry with PSO_FOUT_DUAL (S2A.Dsh FsTyped). Bit 16 of the fragment output need (bits 0–7 unsigned, 8–15 signed integer outputs), i.e. signed-mask bit 8 in the
//   variant names main0_t<u>_<s> / <key>_t<u>_<s>.metal and in fout_want.tsv. Shared by nvn_mtl.m (pso_fout_need) and graphics/tools/direct/fout_want.m (requests from recorded keys)
#define PSO_FOUT_DUAL (1u << 16)
static inline int pso_blend_src1(uint32_t f) { return f >= 0x10 && f <= 0x13; }
static inline int pso_dual_source(const pso_key *k, int merged) {
    if (merged || !k->cfmt[0] || !(k->blend_en & 1)) return 0;   // a merged pass's targets map through lmap and take a _bf fragment function: not handled here
    const blend_st *b = &k->blend[0];
    return pso_blend_src1(b->src_rgb) || pso_blend_src1(b->dst_rgb) || pso_blend_src1(b->src_a) || pso_blend_src1(b->dst_a);
}

// Programmable blending (#674): Maxwell's SET_BLEND_FLOAT_OPTION.ZERO_TIMES_ANYTHING_IS_ZERO, which the NVN driver sets at init, makes every factor × colour product in the blender 0 when
//   either factor is 0 (0 × NaN / ±Inf = 0); Metal's fixed-function blender follows IEEE (0 × NaN = NaN). The targets a pipeline wants blended by the fragment shader instead: floating-point,
//   blending on, some channel written; not on a merged pass (lmap) or a multisampled one. The shader side (graphics/dsx/gal_colorround.c) gives each float4 output n a function constant
//   s2a_pb<n>_c (GAL_PB_FC0 + n) that turns on reading the target and blending from the state in slot 27; nvn_mtl.m pso_pb_eff narrows this to what the fragment shader can do
static inline int pso_pb_fmt(uint32_t f) { return f == 25 || f == 65 || f == 115 || f == 92 || f == 55 || f == 105 || f == 125; }   // MTLPixelFormat R16 / RG16 / RGBA16Float, RG11B10Float, R32 / RG32 / RGBA32Float
static inline uint32_t pso_pb_want(const pso_key *k, int merged) {
    if (merged || k->samples > 1) return 0;
    uint32_t m = 0;
    for (int i = 0; i < 8; i++) if (k->cfmt[i] && (k->blend_en >> i & 1) && (k->chmask >> (4 * i) & 15u) && pso_pb_fmt(k->cfmt[i])) m |= 1u << i;
    return m;
}

typedef struct {
    uint8_t kind, fbmask;
    int8_t fx[32];
} pso_fz_desc;

typedef struct { char vs[24], fs[24]; uint8_t vs_stage, fs_stage, merged, fz; pso_fz_desc fz_desc; pso_key k; } pso_skey;

static inline void pso_skey_from(const pso_key *k, NvShader *vs, NvShader *fs, int merged, const pso_fz_desc *fz, pso_skey *out) {
    memset(out, 0, sizeof *out);
    memcpy(&out->k, k, sizeof out->k);
    out->k.vs = out->k.fs = out->k.fsfn = NULL;
    if (vs) { memcpy(out->vs, vs->key, sizeof out->vs); out->vs_stage = (uint8_t)vs->stage; }
    if (fs) { memcpy(out->fs, fs->key, sizeof out->fs); out->fs_stage = (uint8_t)fs->stage; }
    out->merged = merged != 0;
    out->fz = k->fsfn != NULL;
    if (fz) memcpy(&out->fz_desc, fz, sizeof out->fz_desc);
}

static inline void pso_skey_hex(const pso_skey *key, char *out) {
    static const char hex[] = "0123456789abcdef";
    const uint8_t *p = (const uint8_t *)key;
    for (size_t i = 0; i < sizeof *key; i++) { out[i * 2] = hex[p[i] >> 4]; out[i * 2 + 1] = hex[p[i] & 15]; }
    out[sizeof *key * 2] = 0;
}

static inline int pso_skey_parse(const char *hex, pso_skey *out) {
    size_t n = sizeof *out * 2;
    if (!hex || strlen(hex) != n) return -1;
    uint8_t *p = (uint8_t *)out;
    for (size_t i = 0; i < n; i += 2) {
        int a = hex[i] >= '0' && hex[i] <= '9' ? hex[i] - '0' : hex[i] >= 'a' && hex[i] <= 'f' ? hex[i] - 'a' + 10 : hex[i] >= 'A' && hex[i] <= 'F' ? hex[i] - 'A' + 10 : -1;
        int b = hex[i + 1] >= '0' && hex[i + 1] <= '9' ? hex[i + 1] - '0' : hex[i + 1] >= 'a' && hex[i + 1] <= 'f' ? hex[i + 1] - 'a' + 10 : hex[i + 1] >= 'A' && hex[i + 1] <= 'F' ? hex[i + 1] - 'A' + 10 : -1;
        if (a < 0 || b < 0) return -1;
        p[i / 2] = (uint8_t)(a << 4 | b);
    }
    return 0;
}
