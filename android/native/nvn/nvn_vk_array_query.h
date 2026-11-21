// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Vulkan lowering: make sampled array-layer bounds explicit
// using the actual image view. No new descriptor, resource, or game identity.
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct nvk_aq_id { uint32_t off, type; };
static int nvk_aq_sample(const uint32_t *w, const uint32_t *q, uint32_t bound,
                         const struct nvk_aq_id *ids, uint32_t *ft, uint32_t *vt,
                         uint32_t *image_type, uint32_t *lane, uint32_t *size_n) {
    uint32_t op = q[0] & 65535, wc = q[0] >> 16;
    if (!((op >= 87 && op <= 90) || op == 96 || op == 97) || wc < 5 || q[3] >= bound || q[4] >= bound) return 0;
    uint32_t ty = ids[q[3]].type;
    if (!ty || ty >= bound || !ids[ty].off) return 0;
    const uint32_t *t = w + ids[ty].off;
    if ((t[0] & 65535) != 27 || t[2] >= bound || !ids[t[2]].off) return 0;
    *image_type = t[2]; t = w + ids[*image_type].off;
    if ((t[0] & 65535) != 25 || t[5] != 1 || t[6] != 0 || t[7] != 1 ||
        (t[3] != 0 && t[3] != 1 && t[3] != 3)) return 0;
    *lane = t[3] == 0 ? 1 : t[3] == 1 ? 2 : 3;
    *size_n = t[3] == 0 ? 2 : 3; // cube-array size is width, height, layer count
    *vt = ids[q[4]].type;
    if (!*vt || *vt >= bound || !ids[*vt].off) return 0;
    t = w + ids[*vt].off;
    if ((t[0] & 65535) != 23 || t[3] <= *lane || t[2] >= bound || !ids[t[2]].off) return 0;
    *ft = t[2]; t = w + ids[*ft].off;
    return (t[0] & 65535) == 22 && t[2] == 32;
}

// NULL: unchanged, unsupported, or allocation failure. Input is never modified.
// This does not validate arbitrary SPIR-V; the caller still supplies a valid
// module. Instruction bounds are checked before examining its operand tables.
static uint32_t *nvn_vk_array_query(const uint32_t *w, uint32_t nw, uint32_t *onw, uint32_t *count) {
    *onw = nw; *count = 0;
    if (!w || nw < 5 || w[0] != 0x07230203 || !w[3] || w[3] > 1048576) return NULL;
    uint32_t bound = w[3], samples = 0, ft0 = 0, it = 0, iv[4] = {0};
    uint32_t glsl = 0, query_cap = 0, memory_model = 0, functions = 0;
    struct nvk_aq_id *ids = calloc(bound, sizeof *ids);
    if (!ids) return NULL;
    for (uint32_t p = 5; p < nw;) {
        uint32_t wc = w[p] >> 16, op = w[p] & 65535;
        if (!wc || wc > nw - p) goto unchanged;
        if (op >= 19 && op <= 39 && wc >= 2 && w[p+1] < bound) ids[w[p+1]].off = p;
        if ((op == 21 && wc < 4) || (op == 22 && wc < 3) || (op == 23 && wc < 4) ||
            (op == 25 && wc < 9) || (op == 27 && wc < 3)) goto unchanged;
        if (op == 21 && w[p+2] == 32 && w[p+3] == 1) it = w[p+1];
        if (op == 17 && wc == 2 && w[p+1] == 50) query_cap = 1;
        if (op == 11 && wc == 6 && !memcmp(w+p+2, "GLSL.std.450", 13)) glsl = w[p+1];
        if (op == 14) memory_model++;
        if (op == 54) functions++;
        p += wc;
    }
    if (memory_model != 1 || !functions) goto unchanged;
    for (uint32_t p = 5; p < nw; p += w[p] >> 16) {
        const uint32_t *q = w+p; uint32_t wc = q[0] >> 16, op = q[0] & 65535;
        if (op == 23 && it && q[2] == it && (q[3] == 2 || q[3] == 3)) iv[q[3]] = q[1];
        if (!(op >= 19 && op <= 39) && wc >= 3 && q[1] < bound && ids[q[1]].off && q[2] < bound)
            ids[q[2]].type = q[1];
    }
    for (uint32_t p = 5; p < nw; p += w[p] >> 16) {
        uint32_t ft, vt, im, lane, sn;
        if (nvk_aq_sample(w, w+p, bound, ids, &ft, &vt, &im, &lane, &sn)) {
            if (ft0 && ft != ft0) goto unchanged;
            ft0 = ft; samples++;
        }
    }
    if (!samples || samples > 1048576) goto unchanged;
    uint64_t cap = (uint64_t)nw + (uint64_t)samples * 42 + 40;
    if (cap > UINT32_MAX || cap > SIZE_MAX / 4) goto unchanged;
    uint32_t *out = malloc((size_t)cap * 4);
    if (!out) goto unchanged;
    memcpy(out, w, 20); uint32_t n = 5, next = bound, first_fn = 1;
    uint32_t add_it = !it, add_v2 = !iv[2], add_v3 = !iv[3], add_glsl = !glsl;
    if (!it) it = next++;
    if (!iv[2]) iv[2] = next++;
    if (!iv[3]) iv[3] = next++;
    if (!glsl) glsl = next++;
    uint32_t iz = next++, io = next++, fz = next++;
#define AQ_PUT(x) out[n++] = (x)
    if (!query_cap) { AQ_PUT(2u<<16|17); AQ_PUT(50); }
    for (uint32_t p = 5; p < nw; p += w[p] >> 16) {
        const uint32_t *q = w+p; uint32_t wc = q[0] >> 16, op = q[0] & 65535;
        if (op == 14 && add_glsl) {
            AQ_PUT(6u<<16|11); AQ_PUT(glsl);
            memcpy(out+n, "GLSL.std.450", 12); n += 3; AQ_PUT(0);
        }
        if (op == 54 && first_fn) {
            if (add_it) { AQ_PUT(4u<<16|21); AQ_PUT(it); AQ_PUT(32); AQ_PUT(1); }
            for (uint32_t k = 2; k <= 3; k++) if (k == 2 ? add_v2 : add_v3) {
                AQ_PUT(4u<<16|23); AQ_PUT(iv[k]); AQ_PUT(it); AQ_PUT(k);
            }
            AQ_PUT(4u<<16|43); AQ_PUT(it); AQ_PUT(iz); AQ_PUT(0);
            AQ_PUT(4u<<16|43); AQ_PUT(it); AQ_PUT(io); AQ_PUT(1);
            AQ_PUT(4u<<16|43); AQ_PUT(ft0); AQ_PUT(fz); AQ_PUT(0);
            first_fn = 0;
        }
        uint32_t ft, vt, im, lane, sn;
        if (nvk_aq_sample(w, q, bound, ids, &ft, &vt, &im, &lane, &sn)) {
            uint32_t image = next++, size = next++, layers = next++, top = next++;
            uint32_t hi = next++, layer = next++, clamped = next++, coord = next++;
            AQ_PUT(4u<<16|100); AQ_PUT(im); AQ_PUT(image); AQ_PUT(q[3]);
            AQ_PUT(5u<<16|103); AQ_PUT(iv[sn]); AQ_PUT(size); AQ_PUT(image); AQ_PUT(iz);
            AQ_PUT(5u<<16|81); AQ_PUT(it); AQ_PUT(layers); AQ_PUT(size); AQ_PUT(sn-1);
            AQ_PUT(5u<<16|130); AQ_PUT(it); AQ_PUT(top); AQ_PUT(layers); AQ_PUT(io);
            AQ_PUT(4u<<16|111); AQ_PUT(ft); AQ_PUT(hi); AQ_PUT(top);
            AQ_PUT(5u<<16|81); AQ_PUT(ft); AQ_PUT(layer); AQ_PUT(q[4]); AQ_PUT(lane);
            AQ_PUT(8u<<16|12); AQ_PUT(ft); AQ_PUT(clamped); AQ_PUT(glsl); AQ_PUT(43); AQ_PUT(layer); AQ_PUT(fz); AQ_PUT(hi);
            AQ_PUT(6u<<16|82); AQ_PUT(vt); AQ_PUT(coord); AQ_PUT(clamped); AQ_PUT(q[4]); AQ_PUT(lane);
            memcpy(out+n, q, (size_t)wc*4); out[n+4] = coord; n += wc;
        } else { memcpy(out+n, q, (size_t)wc*4); n += wc; }
    }
#undef AQ_PUT
    out[3] = next; *onw = n; *count = samples; free(ids); return out;
unchanged:
    free(ids); return NULL;
}
