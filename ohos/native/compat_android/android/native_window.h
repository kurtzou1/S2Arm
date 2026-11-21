// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS build of the shared Android direct backend: the WSI lease hands out OHNativeWindow*.
#pragma once
#include <stdint.h>
#include <native_window/external_window.h>
typedef OHNativeWindow ANativeWindow;
#if defined(S2A_ANDROID_VK_BACKEND_NVK)
#include "nvn_plat_vk.h"
#endif
static inline int32_t s2a_ohos_window_geometry(ANativeWindow *w, int which) {
#if defined(S2A_ANDROID_VK_BACKEND_NVK)
    uint32_t width = 0, height = 0;
    if (!nvn_plat_window_size(w, &width, &height)) return 0;
    return (int32_t)(which ? height : width);
#else
    int32_t height = 0, width = 0;
    if (!w || OH_NativeWindow_NativeWindowHandleOpt(w, GET_BUFFER_GEOMETRY, &height, &width) != 0) return 0;
    return which ? height : width;
#endif
}
static inline int32_t ANativeWindow_getWidth(ANativeWindow *w) { return s2a_ohos_window_geometry(w, 0); }
static inline int32_t ANativeWindow_getHeight(ANativeWindow *w) { return s2a_ohos_window_geometry(w, 1); }
// 上游 B3 输出尺寸出图（debug.s2a.buffer_geometry=1，默认关）用它改缓冲尺寸。鸿蒙暂不接（O-2 清单），
// 恒报失败，调用方按“改尺寸失败”走原尺寸路径。可对应 OH_NativeWindow_NativeWindowHandleOpt(SET_BUFFER_GEOMETRY)。
static inline int32_t ANativeWindow_setBuffersGeometry(ANativeWindow *w, int32_t width, int32_t height, int32_t format) {
    (void)w; (void)width; (void)height; (void)format; return -1;
}
