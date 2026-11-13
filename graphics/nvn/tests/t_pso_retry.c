// 编译服务失败的管线重试节奏（graphics/nvn/gfx/nvn/nvn_pso_retry.h）：帧号由用例给，期望值按规则手算，不跑 pso_get_vs。
// ① 第 1 / 2 / 3 次失败后隔 30 / 120 / 480 帧再试 ② 连续第 4 次失败不再试（返回 0），之后也不再试 ③ fails = 0 不是失败，不排重试
// ④ 打包：失败次数与帧号互不串位（帧号取到 2^56 − 1）
// ⑤ #618 形态推演：同一对每次重试都失败，从第 1766 帧起整局 10 分钟（36000 帧）只试 4 次就停；改前每 30 帧一次 ≈ 1200 次
// ⑥ 巫师3 形态：失败一次、第一次重试编出来，只多等 30 帧
#include <stdio.h>
#include "nvn_pso_retry.h"

static int n, bad;
#define CHECK(c, ...) do { n++; if (!(c)) { bad++; printf("没过 "); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    // ①
    CHECK(pso_retry_at(1000, 1) == 1030, "① 第 1 次失败 → %llu，期望 1030", (unsigned long long)pso_retry_at(1000, 1));
    CHECK(pso_retry_at(1000, 2) == 1120, "① 第 2 次失败 → %llu，期望 1120", (unsigned long long)pso_retry_at(1000, 2));
    CHECK(pso_retry_at(1000, 3) == 1480, "① 第 3 次失败 → %llu，期望 1480", (unsigned long long)pso_retry_at(1000, 3));
    // ②
    CHECK(pso_retry_at(1000, 4) == 0, "② 第 4 次失败应不再试，得 %llu", (unsigned long long)pso_retry_at(1000, 4));
    CHECK(pso_retry_at(1000, 9) == 0 && pso_retry_at(1000, 255) == 0, "② 超过上限也不再试");
    // ③
    CHECK(pso_retry_at(1000, 0) == 0, "③ fails = 0 不排重试");
    // ④
    uint64_t big = (1ull << 56) - 1, v = pso_retry_pack(big, 3);
    CHECK(pso_retry_frame(v) == big && pso_retry_fails(v) == 3, "④ 打包 帧 %llu 次 %u", (unsigned long long)pso_retry_frame(v), pso_retry_fails(v));
    v = pso_retry_pack(1766 + 30, 1);
    CHECK(pso_retry_frame(v) == 1796 && pso_retry_fails(v) == 1, "④ 打包小值");
    // ⑤：调用方规则——当前帧 ≥ 重试帧才再建；失败就 fails+1 重排，返回 0 就进失败名单
    uint64_t f = 1766, end = f + 36000; unsigned fails = 0, tries = 0; uint64_t at = f; int given_up = 0;
    for (; f < end; f++) {
        if (given_up || f < at) continue;
        tries++; fails++; at = pso_retry_at(f, fails);
        if (!at) given_up = 1;
    }
    CHECK(given_up && tries == PSO_RETRY_MAX, "⑤ #618 形态 10 分钟试 %u 次，期望 %d 次后停", tries, PSO_RETRY_MAX);
    // ⑥
    at = pso_retry_at(500, 1);
    CHECK(at == 530, "⑥ 巫师3 形态只多等 30 帧，得 %llu", (unsigned long long)(at - 500));
    printf("%s t_pso_retry：%d 项，没过 %d\n", bad ? "✗" : "✓", n, bad);
    return bad != 0;
}
