// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS: Apple QoS names used only by the shared frontend's statistics lines. No QoS is
// applied here; OHOS thread priority goes through the host's own QoS seam (libqos).
#pragma once
#include <pthread.h>
typedef int pthread_qos_class_t;
typedef int qos_class_t;
#define QOS_CLASS_USER_INTERACTIVE 0x21
#define QOS_CLASS_UNSPECIFIED 0
static inline int pthread_set_qos_class_self_np(pthread_qos_class_t c, int p) { (void)c; (void)p; return 0; }
static inline int pthread_get_qos_class_np(pthread_t t, qos_class_t *c, int *p) { (void)t; if (c) *c = QOS_CLASS_UNSPECIFIED; if (p) *p = 0; return 0; }
