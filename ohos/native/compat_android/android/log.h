// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS build of the shared Android direct backend: <android/log.h> subset.
// Lines go to the host log (fd 2, same sink as LOG) and to HiLog with the S2Arm domain.
#pragma once
#include <stdarg.h>
#include <stdio.h>
#include <hilog/log.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { ANDROID_LOG_UNKNOWN = 0, ANDROID_LOG_DEFAULT, ANDROID_LOG_VERBOSE, ANDROID_LOG_DEBUG,
       ANDROID_LOG_INFO, ANDROID_LOG_WARN, ANDROID_LOG_ERROR, ANDROID_LOG_FATAL, ANDROID_LOG_SILENT };
static inline int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap) {
    char line[1024];
    int n = vsnprintf(line, sizeof line, fmt, ap);
    if (n < 0) return n;
    LogLevel level = prio >= ANDROID_LOG_FATAL ? LOG_FATAL : prio == ANDROID_LOG_ERROR ? LOG_ERROR
                   : prio == ANDROID_LOG_WARN ? LOG_WARN : prio == ANDROID_LOG_INFO ? LOG_INFO : LOG_DEBUG;
    OH_LOG_Print(LOG_APP, level, 0x5332, tag ? tag : "S2Arm", "%{public}s", line);
    fprintf(stderr, "[%s] %s\n", tag ? tag : "S2Arm", line);
    return n;
}
__attribute__((format(printf, 3, 4)))
static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = __android_log_vprint(prio, tag, fmt, ap);
    va_end(ap);
    return n;
}
static inline int __android_log_write(int prio, const char *tag, const char *text) {
    return __android_log_print(prio, tag, "%s", text ? text : "");
}
#ifdef __cplusplus
}
#endif
