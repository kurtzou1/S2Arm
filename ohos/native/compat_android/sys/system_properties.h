// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS build of the shared Android direct backend: debug properties come from the
// process environment instead ("debug.s2a.trace" -> DEBUG_S2A_TRACE). Unset = empty.
#pragma once
#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define PROP_VALUE_MAX 92
#define PROP_NAME_MAX 32
static inline int __system_property_get(const char *name, char *value) {
    value[0] = 0;
    if (!name) return 0;
    // 名字都是字面量：按指针缓存，热路径不再每次大写转换 + getenv
    static struct { const char *name; const char *v; } cache[64];
    const unsigned slot = (unsigned)(((uintptr_t)name >> 3) & 63);
    const char *v;
    if (cache[slot].name == name) v = cache[slot].v;
    else {
        char key[96]; size_t i = 0;
        for (; name[i] && i + 1 < sizeof key; i++) key[i] = name[i] == '.' ? '_' : (char)toupper((unsigned char)name[i]);
        key[i] = 0;
        v = getenv(key);
        cache[slot].name = name; cache[slot].v = v;
    }
    if (!v) return 0;
    size_t n = strlen(v); if (n >= PROP_VALUE_MAX) n = PROP_VALUE_MAX - 1;
    memcpy(value, v, n); value[n] = 0;
    return (int)n;
}
