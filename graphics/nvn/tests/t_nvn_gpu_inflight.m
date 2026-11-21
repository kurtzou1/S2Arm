// GPU error attribution step 1 (nvn_mtl.m qf_put / qf_note / qf_take): the program sets a commit ran, listed once each, kept across the table's growth, emptied at commit.
// The expected sets are built here from the draw sequences the test feeds (a plain array and a linear search), not by the code under test. Also prints the per-draw cost.
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { NSH = 4000 };
static NvShader *g_sh[NSH];
static NvProg *prog(int vs, int fs, int gs) { NvProg *p = [NvProg new]; p->sh[0] = g_sh[vs]; p->sh[1] = fs >= 0 ? g_sh[fs] : nil; p->sh[2] = gs >= 0 ? g_sh[gs] : nil; return p; }
static uint64_t key_of(int i) { return 0xa000000000000000ull + (uint64_t)i * 0x10001ull; }   // the key written into shader i below, as qf_hex must read it back
// Does the set hold exactly these entries (each once)?
static int same(const qf_set *q, const qf_ent *want, uint32_t n) {
    if (!q || q->n != n) return 0;
    for (uint32_t i = 0; i < n; i++) { int hits = 0; for (uint32_t j = 0; j < q->n; j++) hits += q->e[j].a == want[i].a && q->e[j].b == want[i].b && q->e[j].kind == want[i].kind; if (hits != 1) return 0; }
    return 1;
}

int main(void) {
    @autoreleasepool {
        for (int i = 0; i < NSH; i++) { g_sh[i] = [NvShader new]; snprintf(g_sh[i]->key, sizeof g_sh[i]->key, "%016llx_b", (unsigned long long)key_of(i)); }
        static qf_ent want[4000];

        // ① 600 programs, each drawn 3 times in a row, the whole sequence twice: 600 vertex / fragment pairs
        NSMutableArray *P = [NSMutableArray array]; for (int i = 0; i < 600; i++) [P addObject:prog(i, 2000 + i, -1)];
        for (int r = 0; r < 2; r++) for (int i = 0; i < 600; i++) for (int k = 0; k < 3; k++) qf_note(P[i]);
        for (int i = 0; i < 600; i++) want[i] = (qf_ent){key_of(i), key_of(2000 + i), 0};
        qf_set *q = qf_take();
        VERIFY(same(q, want, 600), "600 programs drawn 3600 times: listed once each (%u entries)", q ? q->n : 0); free(q);

        // ② the next commit starts empty: 5 programs → 5 entries
        for (int i = 0; i < 5; i++) qf_note(P[i]);
        q = qf_take(); for (int i = 0; i < 5; i++) want[i] = (qf_ent){key_of(i), key_of(2000 + i), 0};
        VERIFY(same(q, want, 5), "the following commit lists only its own 5 programs (%u entries)", q ? q->n : 0); free(q);

        // ③ growth past the first table (512 entries): 1800 programs alternating with one repeated program, nothing lost or doubled
        NvProg *rep = prog(1999, 3999, -1); NSMutableArray *B = [NSMutableArray array]; for (int i = 0; i < 1800; i++) [B addObject:prog(i, 2000 + (i % 1000), -1)];
        for (int i = 0; i < 1800; i++) { qf_note(B[i]); qf_note(rep); }
        uint32_t n = 0; for (int i = 0; i < 1800; i++) { qf_ent e = {key_of(i), key_of(2000 + (i % 1000)), 0}; int dup = 0; for (uint32_t j = 0; j < n; j++) dup |= want[j].a == e.a && want[j].b == e.b; if (!dup) want[n++] = e; }
        want[n++] = (qf_ent){key_of(1999), key_of(3999), 0};
        q = qf_take();
        VERIFY(same(q, want, n), "1800 programs + 1 repeated across table growth: %u expected, %u listed, each once", n, q ? q->n : 0); free(q);

        // ④ a geometry stage and a compute dispatch: kind 2 and kind 5 entries beside the pair
        NvProg *g = prog(10, 2010, 3000);
        qf_note(g); qf_note_cs(g_sh[3500]); qf_note(g); qf_note_cs(g_sh[3500]);
        want[0] = (qf_ent){key_of(10), key_of(2010), 0}; want[1] = (qf_ent){key_of(3000), 0, 2}; want[2] = (qf_ent){key_of(3500), 0, 5};
        q = qf_take();
        VERIFY(same(q, want, 3), "a geometry stage and a compute shader are listed with their kinds (%u entries)", q ? q->n : 0); free(q);

        // ⑤ cost: 3000 draws a commit over 300 programs. Typical: 10 draws of a program in a row. Worst: no two consecutive draws share a program
        NSMutableArray *C = [NSMutableArray array]; for (int i = 0; i < 300; i++) [C addObject:prog(i, 2000 + i, -1)];
        double best[2] = {1e30, 1e30};
        for (int rep2 = 0; rep2 < 20; rep2++) for (int m = 0; m < 2; m++) {
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            for (int d = 0; d < 3000; d++) qf_note(C[m ? (d * 7) % 300 : d / 10]);
            qf_set *x = qf_take(); free(x);
            double us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000.0; if (us < best[m]) best[m] = us;
        }
        size_t mem = (size_t)g_qf_cap * 8 + (size_t)(g_qf_cap / 2) * (sizeof(qf_ent) + 2 * sizeof(void *));
        printf("COST 3000 draws over 300 programs, commit included: typical (10 in a row) %.1f µs, worst (none in a row) %.1f µs; table %u slots = %zu KB kept, per-commit copy %zu KB (300 entries)\n",
               best[0], best[1], g_qf_cap, mem / 1024, (sizeof(qf_set) + 300 * sizeof(qf_ent)) / 1024);
        VERIFY(best[1] < 1000, "worst case stays under 1 ms per 3000 draws (%.1f µs)", best[1]);

        printf("%s t_nvn_gpu_inflight: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
        return failures != 0;
    }
}
