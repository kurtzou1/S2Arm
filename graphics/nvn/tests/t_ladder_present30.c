// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 档位梯子压回 30 帧档时直连出图封顶 30（#1766）：一款游戏的社区帧率补丁改的设定游戏只在起局读一次（交换间隔起局设成 1）。梯子压回时只撤了补丁，
//   游戏逻辑回到按 30 帧算，出图仍按游戏的间隔 1 跑 60 → 两倍速。修法：降档原因 4（runtime/src/fps.c s2a_fps_hold）时 graphics/nvn hle_nvn.c 出图至少隔 2 拍。
// 链生产 fps.c 与直连库，不打桩。出图节拍 60 Hz、游戏间隔 1（缺省，游戏没设过别的）。期望手算：
//   ① 梯子放开：出图 60 / 1 = 60 帧、显示链接 60
//   ② 梯子压回 30 帧档（s2a_fps_hold(1)）：降档原因 4；出图 60 / 2 = 30 帧、显示链接 30
//   ③ 再放开（s2a_fps_hold(0)）：回 60、60
// 反证：hle_nvn.c 的 cap30 改回只看 video_cap → ② 红（仍 60）
#include <stdio.h>
void nvn_present_config(int hz, int display_mode);
int nvn_present_fps(void), nvn_game_fps(void), s2a_fps_cap_reason(void);
void s2a_fps_hold(int hold);
static int fails;
static void ck(const char *what, int want_reason, int want_fps, int want_link) {
    int r = s2a_fps_cap_reason(), f = nvn_present_fps(), l = nvn_game_fps(), ok = r == want_reason && f == want_fps && l == want_link;
    printf("%s %s：降档原因 %d（期望 %d）、出图 %d 帧（期望 %d）、显示链接 %d（期望 %d）\n", ok ? "✓" : "✗", what, r, want_reason, f, want_fps, l, want_link);
    fails += !ok;
}
int main(void) {
    nvn_present_config(60, 0);
    ck("① 梯子放开", 0, 60, 60);
    s2a_fps_hold(1); ck("② 梯子压回 30 帧档", 4, 30, 30);
    s2a_fps_hold(0); ck("③ 再放开", 0, 60, 60);
    printf("%s t_ladder_present30：%s\n", fails ? "✗" : "✓", fails ? "有失败" : "全过");
    return fails != 0;
}
