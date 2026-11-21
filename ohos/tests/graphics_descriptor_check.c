// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Feeds real graphics.v1.json files (argv) to the native consumer used before relocation
// (android/native/direct/graphics.c) and prints the parsed identity or the exact rejection.
#include <stdio.h>
#include <stdlib.h>
#include "graphics.h"

int main(int argc, char **argv) {
    int bad = 0;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { printf("FAIL %s: cannot open\n", argv[i]); bad = 1; continue; }
        static unsigned char buf[1 << 20];
        size_t n = fread(buf, 1, sizeof buf, f); fclose(f);
        struct s2a_graphics_descriptor_v1 d; char why[160] = "";
        int rc = s2a_graphics_descriptor_parse(buf, n, &d, why, sizeof why);
        if (rc) { printf("FAIL %s: rc=%d %s\n", argv[i], rc, why); bad = 1; continue; }
        char key[65], kwhy[96] = "";
        int k = s2a_direct_implementation_key(&d, d.profile_hashes[0], key, kwhy, sizeof kwhy);
        printf("ok   %s: title=%s abi=%u profiles=%u closure=%s key=%s\n", argv[i], d.title_id, d.direct_abi,
               d.profile_count, d.translator_closure, k ? kwhy : key);
        if (k) bad = 1;
    }
    return bad;
}
