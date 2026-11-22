// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 取图线程实时声明被降级的对策（graphics/nvn/gfx/nvn/rt_demote.h）。期望按规则手写：
//   没打算声明 → 不动；声明着、仍在实时档 → 不动；声明着、被降、60 秒内头一次 → 重新声明；60 秒内第二次 → 本局放弃实时、改 USER_INTERACTIVE
#include <stdio.h>
#include "../gfx/nvn/rt_demote.h"
int main(void) {
    struct { int d, rt, rec, want; const char *why; } c[] = {
        {0, 0, 0, RT_DEMOTE_NONE, "没打算声明（DM_RT=0 / 已放弃）：不动"},
        {1, 1, 0, RT_DEMOTE_NONE, "声明着、仍在实时档：不动"},
        {1, 1, 5, RT_DEMOTE_NONE, "声明着、仍在实时档（之前降过）：不动"},
        {1, 0, 0, RT_DEMOTE_REDECLARE, "被降、60 秒内头一次：重新声明"},
        {1, 0, 1, RT_DEMOTE_GIVE_UP, "60 秒内第二次被降：本局放弃实时、改 USER_INTERACTIVE"},
        {1, 0, 3, RT_DEMOTE_GIVE_UP, "60 秒内多次被降：放弃"},
    };
    int bad = 0;
    for (unsigned i = 0; i < sizeof c / sizeof *c; i++) {
        int got = rt_demote_action(c[i].d, c[i].rt, c[i].rec);
        printf("%s %s → %d（期望 %d）\n", got == c[i].want ? "✓" : "✗", c[i].why, got, c[i].want); bad += got != c[i].want;
    }
    printf("%s t_rt_demote：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
