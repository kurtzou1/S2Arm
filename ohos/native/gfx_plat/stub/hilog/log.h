// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
// Host syntax gate only. Production builds must use the OHOS SDK headers.
typedef enum { LOG_APP = 0 } LogType;
typedef enum { LOG_INFO = 4, LOG_WARN = 5, LOG_ERROR = 6 } LogLevel;
int OH_LOG_Print(LogType type, LogLevel level, unsigned int domain, const char* tag,
                 const char* fmt, ...);
