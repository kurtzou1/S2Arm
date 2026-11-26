// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 安卓 / 鸿蒙地址窗口的最大值（唯一来源，不分平台可见）：平台实现先按它整块保留（android/native/runtime/platform/vawin_android.inc），
// 起局时 svc_mem 用 s2a_layout_need 算出本款跨度再 s2a_window_trim 收缩；布局预算（layout_android.inc）与宿主用例都引用它，
// 改窗口只改这一处。非安卓由 vawin.c 按本款跨度预留，不用这个值。
#pragma once
#define S2A_WIN_SIZE (72ull << 30)   // 63 GiB 别名区 + 栈区 2 GiB（Horizon 真值）+ 堆 + 模块放得下（layout_android.inc）
