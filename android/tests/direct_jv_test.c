// SPDX-License-Identifier: Apache-2.0
// s2a_jv_scan 字符串收尾改用 memchr + 反斜杠串奇偶（jv.c jv_str_end）：与原逐字节扫描逐项对拍。
// 参照实现 ref_scan 原样抄自改动前的 jv.c（反斜杠吃掉下一个字节），期望值不依赖被测实现。
// 对拍面：小字母表（引号、反斜杠、括号、逗号、空白、普通字符）上长度 0..10 的全部串（7^0+…+7^10 ≈ 3.3 千万个太多，
//   取长度 ≤ 8 全枚举 + 长度 9..64 伪随机 20 万个），每个串从每个起点各扫一次，返回值与 out_end 都要一致。
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "direct/jv.h"

static int ref_scan(const char *p, const char *end, const char **out_end) {
    p = s2a_jv_ws(p, end);
    if (p >= end) return -1;
    if (*p == '"') {
        p++;
        while (p < end) {
            if (*p == '\\') { p += 2; continue; }
            if (*p == '"') { *out_end = p + 1; return 0; }
            p++;
        }
        return -1;
    }
    if (*p == '{' || *p == '[') {
        char open = *p, close = open == '{' ? '}' : ']';
        int depth = 0;
        while (p < end) {
            if (*p == '"') {
                p++;
                while (p < end && *p != '"') { if (*p == '\\') p++; p++; }
                if (p < end) p++;
                continue;
            }
            if (*p == open) depth++;
            else if (*p == close) { depth--; if (!depth) { *out_end = p + 1; return 0; } }
            p++;
        }
        return -1;
    }
    while (p < end && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') p++;
    *out_end = p;
    return 0;
}

static const char ALPHA[] = "\"\\{}[] a";
enum { NA = sizeof ALPHA - 1 };
static unsigned long g_cases, g_fail;

static void check(const char *buf, size_t n) {
    for (size_t at = 0; at <= n; at++) {
        const char *e1 = NULL, *e2 = NULL;
        int r1 = ref_scan(buf + at, buf + n, &e1), r2 = s2a_jv_scan(buf + at, buf + n, &e2);
        g_cases++;
        if (r1 != r2 || (r1 == 0 && e1 != e2)) {
            if (g_fail++ < 8) printf("FAIL: jv scan differs on \"%.*s\" from %zu: ref %d/%td new %d/%td\n", (int)n, buf, at,
                                     r1, r1 ? (ptrdiff_t)-1 : e1 - buf, r2, r2 ? (ptrdiff_t)-1 : e2 - buf);
        }
    }
}

int main(void) {
    char buf[80];
    // 长度 ≤ 8 全枚举（8 个字符的字母表：8^8 ≈ 1677 万串太多，取 ≤ 7：约 240 万串）
    for (int len = 0; len <= 7; len++) {
        unsigned long total = 1; for (int i = 0; i < len; i++) total *= NA;
        for (unsigned long k = 0; k < total; k++) {
            unsigned long v = k;
            for (int i = 0; i < len; i++) { buf[i] = ALPHA[v % NA]; v /= NA; }
            check(buf, (size_t)len);
        }
    }
    // 长度 9..64 伪随机（xorshift，固定种子）
    uint64_t x = 0x9e3779b97f4a7c15ull;
    for (int k = 0; k < 200000; k++) {
        int len = 9 + (int)(k % 56);
        for (int i = 0; i < len; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; buf[i] = ALPHA[x % NA]; }
        check(buf, (size_t)len);
    }
    // 长串：base64 式长字符串内容（合成程序 JSON 里的 SPIR-V）收尾位置正确
    {
        static char big[1 << 16]; size_t n = 0;
        big[n++] = '{'; memcpy(big + n, "\"spirv\":\"", 9); n += 9;
        for (int i = 0; i < 60000; i++) big[n++] = "ABCDEFGHabcdefgh0123+/"[i % 22];
        big[n++] = '"'; big[n++] = '}';
        check(big, n);
    }
    printf("direct jv scan: %lu cases, %lu differ\n", g_cases, g_fail);
    return g_fail ? 1 : 0;
}
