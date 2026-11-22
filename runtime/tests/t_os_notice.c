// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 系统版本提示（ios/os_notice.h）：只有 18.0.x 提示（期望手写：诊断库 18.0 / 18.0.1 上屏局 46 崩 42、18.1 起 549 崩 1）；
//   接线断言读 ios/app.m 原文（UIKit 在 Mac 宿主上编不了）：开局入口按它判、一次性标记、只有「知道了」、点了照常开局
#include "../../ios/os_notice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks, fails;
static void check(int ok, const char *what) { checks++; if (!ok) { fails++; printf("✗ %s\n", what); } }
int main(int argc, char **argv) {
    check(s2a_os_18_0_affected(18, 0), "18.0 / 18.0.1（minor 0）提示");
    check(!s2a_os_18_0_affected(18, 1) && !s2a_os_18_0_affected(18, 6), "18.1、18.6 不提示");
    check(!s2a_os_18_0_affected(17, 0) && !s2a_os_18_0_affected(27, 0) && !s2a_os_18_0_affected(26, 0), "17.0、26.0、27.0 不提示");
    if (argc != 2) { printf("用法：t_os_notice <ios/app.m>\n"); return 2; }
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    static char src[1 << 22]; size_t n = fread(src, 1, sizeof src - 1, f); fclose(f); src[n] = 0;
    check(strstr(src, "s2a_os_18_0_affected(v.majorVersion, v.minorVersion)") != NULL, "接线：开局入口按系统主 / 次版本判");
    check(strstr(src, "boolForKey:@\"S2AOS180NoticeShown\"") && strstr(src, "setBool:YES forKey:@\"S2AOS180NoticeShown\""), "接线：一次性（看过记下）");
    check(strstr(src, "S2AL(@\"common.gotIt\") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {\n            [ud setBool:YES forKey:@\"S2AOS180NoticeShown\"]; library_play_now(g, sd);") != NULL, "接线：只有「知道了」，点了照常开局");
    printf("%s t_os_notice：%d 项，%d 项不符\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
}
