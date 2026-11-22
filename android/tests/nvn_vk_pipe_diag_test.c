// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 计算管线现建慢行文本（nvn_vk_pipe_diag.h）：前缀不变，后面带计算阶段键与出库标记。
#include <stdio.h>
#include <string.h>

#include "nvn_vk_pipe_diag.h"

static int fails;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); fails++; } } while (0)

int main(void) {
    const uint8_t key[8] = {0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef}, zero[8] = {0};
    uint8_t digest[32] = {0xaa, 0xbb, 0xcc, 0xdd};
    char b[200];
    // 期望（手算）：现编 = 前缀 + 键 16 位十六进制 + 「现编」；出库 = 再带摘要前 4 字节；键全零写「键 -」
    nvn_vk_compute_pipe_line(b, sizeof b, 12.34, key, 0, digest);
    CHECK(!strcmp(b, "计算管线编译 12.3 毫秒 键 0123456789abcdef 现编"), "live line: %s", b);
    nvn_vk_compute_pipe_line(b, sizeof b, 104.7, key, 1, digest);
    CHECK(!strcmp(b, "计算管线编译 104.7 毫秒 键 0123456789abcdef 出库 摘要 aabbccdd…"), "lib line: %s", b);
    nvn_vk_compute_pipe_line(b, sizeof b, 5.0, zero, 0, digest);
    CHECK(!strcmp(b, "计算管线编译 5.0 毫秒 键 - 现编"), "no-key line: %s", b);
    CHECK(!strncmp(b, "计算管线编译 5.0 毫秒", strlen("计算管线编译 5.0 毫秒")), "prefix stays parseable by the hitch scripts");
    // 缓冲放不下：不越界、始终以 0 结尾
    char tiny[24]; memset(tiny, 'x', sizeof tiny);
    nvn_vk_compute_pipe_line(tiny, sizeof tiny, 12.34, key, 1, digest);
    CHECK(memchr(tiny, 0, sizeof tiny) != NULL, "truncated line is NUL-terminated");
    printf("nvn_vk_pipe_diag: %s\n", fails ? "FAIL" : "all checks passed");
    return fails ? 1 : 0;
}
