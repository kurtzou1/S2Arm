// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// #674 (11-12): padded-variant program choice (graphics/nvn/gfx/nvn/vp_prog_pick.h).
//   Expectations are worked out by hand, not by running the implementation under test: a program with the
//   shader's live key is picked from the draw's primary program first, else from the programs each graphics
//   stage was bound from. The mesh draw of run 88b7b382 (0.3.0) had a serial-only stand-in as S.prog and its
//   mesh shader in stage 4's bind: the old single-program lookup returned -1, the variant was pinned to
//   SE_FAIL and the pair's draws were skipped for the whole run.
#include <stdio.h>
#include <string.h>
#include "vp_prog_pick.h"

static int bad, checks;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); bad += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); } while (0)

// A fake program: the keys of its stages. A serial-only stand-in has nstage = 0.
typedef struct { const char *name; const char *keys[6]; unsigned nstage; int calls; } fake_prog;
static int fake_stage_of(const void *prog, const char *key, uint8_t md[8], void *ctx) {
    (void)ctx; fake_prog *p = (fake_prog *)prog; p->calls++;
    for (unsigned i = 0; i < p->nstage; i++)
        if (!strcmp(p->keys[i], key)) { for (int b = 0; b < 8; b++) md[b] = (uint8_t)(key[b] + i); return (int)i; }
    memset(md, 0, 8); return -1;
}
static const void *fake_bst(unsigned st, void *ctx) {
    fake_prog **tab = (fake_prog **)ctx; return st < 5 ? tab[st] : NULL;
}
static uint8_t expect_md(const char *key, int stage) { return (uint8_t)(key[0] + stage); }
static void reset(fake_prog *p) { p->calls = 0; }

int main(void) {
    const char *VS  = "6d42a320e50657a3_b";   // #674: the mesh / vertex shader that failed in 88b7b382
    const char *FS  = "5ee0857829bbb3fd_b";
    fake_prog alone   = {"alone",   {VS, FS, "", "", "", ""}, 2, 0};
    fake_prog standin = {"standin", {"", "", "", "", "", ""}, 0, 0};
    fake_prog frag    = {"frag",    {FS, "", "", "", "", ""}, 1, 0};
    fake_prog mesh    = {"mesh",    {"", "", "", "", VS, ""}, 5, 0};
    fake_prog vertex  = {"vertex",  {VS, "", "", "", "", ""}, 1, 0};

    // 1: the ordinary case is unchanged - primary holds the shader, the per-stage binds are not consulted.
    {
        fake_prog *tab[5] = {NULL, NULL, NULL, NULL, NULL};
        uint8_t md[8]; int at = 99;
        const void *got = vp_pick_prog(&alone, fake_bst, 5, VS, md, fake_stage_of, tab, &at);
        CHECK(got == &alone && at == 0 && md[0] == expect_md(VS, 0), "1 primary holds the shader: picks primary at stage 0, md from its key");
        CHECK(alone.calls == 1, "1 no per-stage programs looked up when primary already matched");
        reset(&alone);
    }
    // 2: the #674 case - a combined program is a stand-in (no stages); the mesh shader is in stage 4's bind.
    {
        fake_prog *tab[5] = {NULL, &frag, NULL, NULL, &mesh};
        uint8_t md[8]; int at = 99;
        const void *got = vp_pick_prog(&standin, fake_bst, 5, VS, md, fake_stage_of, tab, &at);
        CHECK(got == &mesh && at == 4 && md[0] == expect_md(VS, 4), "2 combined stand-in: falls back to stage 4's program, md from that stage");
        CHECK(fake_stage_of(&standin, VS, (uint8_t[8]){0}, NULL) == -1, "2 old single-program lookup would have failed here (regression target)");
        reset(&standin); reset(&frag); reset(&mesh);
    }
    // 3: a draw's program is the fragment one while the vertex shader came from stage 0's bind.
    {
        fake_prog *tab[5] = {&vertex, &frag, NULL, NULL, NULL};
        uint8_t md[8]; int at = 99;
        const void *got = vp_pick_prog(&frag, fake_bst, 5, VS, md, fake_stage_of, tab, &at);
        CHECK(got == &vertex && at == 0, "3 fragment-stage program: falls back to the vertex stage's program");
        reset(&frag); reset(&vertex);
    }
    // 4: NULL binds and a repeated program neither crash nor get looked up twice.
    {
        fake_prog *tab[5] = {NULL, &frag, &frag, NULL, &mesh};
        uint8_t md[8]; int at = 99;
        const void *got = vp_pick_prog(&standin, fake_bst, 5, VS, md, fake_stage_of, tab, &at);
        CHECK(got == &mesh && at == 4, "4 NULL / duplicate binds skipped, still finds the mesh program");
        CHECK(frag.calls == 1, "4 a repeated program is looked up only once");
        reset(&standin); reset(&frag); reset(&mesh);
    }
    // 5: nobody holds a live key -> no program, stage -1, zero md. vp_build then reports the real reason.
    {
        fake_prog *tab[5] = {NULL, &frag, NULL, NULL, NULL};
        uint8_t md[8]; memset(md, 0xaa, 8); int at = 99;
        const void *got = vp_pick_prog(&standin, fake_bst, 5, "deadbeefdeadbeef_b", md, fake_stage_of, tab, &at);
        int zero = 1; for (int i = 0; i < 8; i++) zero &= md[i] == 0;
        CHECK(got == NULL && at == -1 && zero, "5 no live control anywhere: NULL, at -1, md zeroed");
        reset(&standin); reset(&frag);
    }
    // 6: no primary at all (frame replay / a program finalized since its bind) -> per-stage binds still work.
    {
        fake_prog *tab[5] = {NULL, &vertex, NULL, NULL, NULL};
        uint8_t md[8]; int at = 99;
        const void *got = vp_pick_prog(NULL, fake_bst, 5, VS, md, fake_stage_of, tab, &at);
        CHECK(got == &vertex && at == 0, "6 NULL primary: still picks the per-stage program");
        reset(&vertex);
    }
    printf("%d checks, %d failed\n", checks, bad);
    if (bad) printf("✗ t_vp_prog_pick：%d 项不通（共 %d 项）\n", bad, checks);
    else printf("✓ t_vp_prog_pick：%d 项全过\n", checks);   // 列车按结论行判（tests/t_result_lint）
    return bad != 0;
}
