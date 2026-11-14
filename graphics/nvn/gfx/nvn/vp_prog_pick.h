// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// #674 (11-12): which guest program holds the code / control of the shader a padded variant is made from.
//   prog_stage_of looks for the shader's key among the *live* control sections of one program. A draw's program
//   is not always the one that shader was bound from: bind_stages makes a host stand-in (serial only, no stages),
//   and a mesh draw's S.prog is the fragment stage's program while its mesh shader came from stage 4's bind.
//   In both cases vp_ask used to take code = 0 and report "the game no longer holds its control section",
//   vp_done pinned the variant to SE_FAIL and the caller put the pair on the failed list for the whole run.
//   Pick the program from the per-stage binds when the primary has no such stage. Pure C, no Metal / ObjC here,
//   so the choice can be tested offline (graphics/nvn/tests/t_vp_prog_pick.c, same pattern as host/mesh_pad.h).
#ifndef S2A_VP_PROG_PICK_H
#define S2A_VP_PROG_PICK_H
#include <stdint.h>
#include <string.h>

// stage_of(prog, key, md) -> that program's stage index whose live key is key, or -1; md = the 8-byte key.
// bst(st) -> the program bound for graphics stage st, or NULL (nvn_mtl.m S.bst, 5 stages).
typedef int (*vp_stage_of_fn)(const void *prog, const char *key, uint8_t md[8], void *ctx);
typedef const void *(*vp_bst_fn)(unsigned st, void *ctx);

// -> the program whose sd[*at_out] supplies the code / control; NULL when none holds it (*at_out = -1, md = 0).
//   The primary is tried first so the ordinary single-program case is unchanged; then the per-stage binds in
//   order. A program already tried (NULL, or the primary itself) is skipped. Only a *live* key match counts:
//   prog_stage_of itself refuses a control section the game has since reused.
static inline const void *vp_pick_prog(const void *primary, vp_bst_fn bst, unsigned nbst, const char *key,
                                       uint8_t md[8], vp_stage_of_fn stage_of, void *ctx, int *at_out) {
    uint8_t m[8];
    int at = primary ? stage_of(primary, key, m, ctx) : -1;
    if (at >= 0) { memcpy(md, m, 8); *at_out = at; return primary; }
    for (unsigned st = 0; st < nbst; st++) {
        const void *q = bst ? bst(st, ctx) : NULL;
        if (!q || q == primary) continue;
        unsigned prior = 0; int seen = 0;
        for (; prior < st; prior++) if (bst(prior, ctx) == q) { seen = 1; break; }
        if (seen) continue;
        at = stage_of(q, key, m, ctx);
        if (at >= 0) { memcpy(md, m, 8); *at_out = at; return q; }
    }
    memset(md, 0, 8); *at_out = -1; return NULL;
}
#endif
