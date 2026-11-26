// SPDX-License-Identifier: Apache-2.0
// 预热清单的身份索引（nvn_vk_prog_warm.c find_locked / ix_*）：与参照模型逐步对拍。
// 参照模型按清单的规则手写（不调被测实现）：已有身份 uses+1、刷新最近使用；新身份在满额时淘汰 uses 最低、
//   同 uses 里最久没用的那一条（同分取下标最小），换成新身份（uses=1）；没满就追加。每次 note 之后，
//   池里每个身份的 contains 都要与模型的「在不在」一致。身份前 4 字节（索引的家位）只取 4 种值，逼出长冲突链与回移。
#include "nvn_vk_prog_warm.h"
#include "nvn_plat.h"
#include "direct/compile_request.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { LIMIT = 64, POOL = 300, OPS = 20000 };
const char *nvn_plat_dir(int which) { (void)which; return NULL; }
int nvn_plat_flag(const char *name, int fallback) { return !strcmp(name, "nvk_warm_max") ? LIMIT : fallback; }
void nvn_plat_log(int level, const char *category, const char *message) { (void)level; (void)category; (void)message; }
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) { memset(out, 0, sizeof *out); return -1; }

static uint8_t pool[POOL][32];
static struct { int id; uint32_t uses; uint64_t last; } m[LIMIT];
static int mn; static uint64_t mrank;
static void model_note(int id) {
    uint64_t rank = ++mrank;
    for (int i = 0; i < mn; i++) if (m[i].id == id) { m[i].uses++; m[i].last = rank; return; }
    if (mn >= LIMIT) {
        int cold = 0;
        for (int i = 1; i < mn; i++)
            if (m[i].uses < m[cold].uses || (m[i].uses == m[cold].uses && m[i].last < m[cold].last)) cold = i;
        m[cold].id = id; m[cold].uses = 1; m[cold].last = rank;
        return;
    }
    m[mn].id = id; m[mn].uses = 1; m[mn].last = rank; mn++;
}
static int model_has(int id) { for (int i = 0; i < mn; i++) if (m[i].id == id) return 1; return 0; }

int main(void) {
    uint64_t x = 0x243f6a8885a308d3ull;
    for (int i = 0; i < POOL; i++) {
        for (int b = 0; b < 32; b++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; pool[i][b] = (uint8_t)x; }
        const uint32_t home = (uint32_t)(i % 4) * 0x40u;   // 家位只有 4 种，在表里彼此隔开（挨着的话四条链连成一串，下一次插入总会补上删出的洞，回移写错也看不出）
        memcpy(pool[i], &home, 4);
        pool[i][31] |= 1;   // 不全零
    }
    nvk_prog_warm_reset();   // 上限按 flag（LIMIT）重读
    unsigned bad = 0, checks = 0;
    for (int op = 0; op < OPS; op++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        const int id = (int)(x % 1000u) < 700 ? (int)(x % 40u) : (int)(x % POOL);   // 七成落在 40 个热点身份上，余下全池
        struct nvk_prog_rec r; memset(&r, 0, sizeof r);
        memcpy(r.identity, pool[id], 32); r.stage_mask = 3;
        nvk_prog_warm_note(&r);
        model_note(id);
        for (int i = 0; i < POOL; i++) {
            checks++;
            if (nvk_prog_warm_contains(pool[i]) != model_has(i) && bad++ < 8)
                fprintf(stderr, "FAIL: op %d identity %d: contains %d, model %d\n", op, i, nvk_prog_warm_contains(pool[i]), model_has(i));
        }
    }
    printf("prog warm index: %d ops, %u contains checks, %u differ\n", OPS, checks, bad);
    return bad ? 1 : 0;
}
