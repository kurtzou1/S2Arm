// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 系统版本提示（纯判断，Mac 宿主单测 runtime/tests/t_os_notice.c）。
//   iOS / iPadOS 18.0、18.0.1（及其它 18.0.x）上，游戏画面第一次全屏上屏后高概率在系统的 GPU 完成回调里断言闪退（诊断库：18.0.x 上屏局 46 崩 42，
//   18.1 起 549 崩 1；栈上没有本 App 代码），18.1 系统已修。开局前提示一次「升级系统」，不拦（app.m library_play）。
#ifndef S2A_OS_NOTICE_H
#define S2A_OS_NOTICE_H
static inline int s2a_os_18_0_affected(long major, long minor) { return major == 18 && minor == 0; }
#endif
