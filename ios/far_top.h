// 远端缺页点表取前 N（ios/diagcollect.m 诊断包用；runtime/tests/t_far_top.c 测）。纯 C、不依赖 Foundation。
//   输入 = runtime/src/far.c s2a_far_report 写的点表：首行注释，其后每行「模块\t偏移\t次数\t类别\t代执行失败」，按哈希槽顺序（崩溃处理里写，不能排序）。
//   输出 = 原表头 + 一行总计（总点数、总缺页、前 N 点占比，千分之一精度）+ 按次数降序的前 N 行（次数相同按原顺序）；读不到 / 没有数据行回 NULL。调用方 free
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef struct { uint64_t n; size_t at; char *line; } s2a_far_row;
static int s2a_far_row_cmp(const void *a, const void *b) {
    const s2a_far_row *x = a, *y = b;
    if (x->n != y->n) return x->n < y->n ? 1 : -1;
    return x->at < y->at ? -1 : x->at > y->at;
}
static inline char *s2a_far_top(const char *path, int top) {
    FILE *f = fopen(path, "r"); if (!f) return NULL;
    s2a_far_row *rows = NULL; size_t nr = 0, cap = 0; char buf[512], head[512] = "# 模块\t偏移\t次数\t类别\t代执行失败\n"; uint64_t total = 0;
    while (fgets(buf, sizeof buf, f)) {
        if (buf[0] == '#') { snprintf(head, sizeof head, "%s", buf); continue; }
        char *t1 = strchr(buf, '\t'), *t2 = t1 ? strchr(t1 + 1, '\t') : NULL; if (!t2) continue;
        uint64_t n = strtoull(t2 + 1, NULL, 10);
        if (nr == cap) { size_t c = cap ? cap * 2 : 256; s2a_far_row *r = realloc(rows, c * sizeof *r); if (!r) break; rows = r; cap = c; }
        size_t l = strlen(buf); if (!l || buf[l - 1] != '\n') { if (l + 1 < sizeof buf) { buf[l] = '\n'; buf[l + 1] = 0; } }
        rows[nr].n = n; rows[nr].at = nr; rows[nr].line = strdup(buf); if (!rows[nr].line) break; nr++; total += n;
    }
    fclose(f);
    if (!nr) { free(rows); return NULL; }
    qsort(rows, nr, sizeof *rows, s2a_far_row_cmp);
    size_t k = top > 0 && (size_t)top < nr ? (size_t)top : nr; uint64_t kept = 0; for (size_t i = 0; i < k; i++) kept += rows[i].n;
    unsigned permil = total ? (unsigned)((kept * 1000 + total / 2) / total) : 1000;
    size_t sz = strlen(head) + 160; for (size_t i = 0; i < k; i++) sz += strlen(rows[i].line);
    char *out = malloc(sz), *p = out;
    if (out) {
        p += sprintf(p, "%s", head);
        p += sprintf(p, "# 共 %zu 点、缺页 %llu 次；以下前 %zu 点占 %u.%u%%\n", nr, (unsigned long long)total, k, permil / 10, permil % 10);
        for (size_t i = 0; i < k; i++) p += sprintf(p, "%s", rows[i].line);
    }
    for (size_t i = 0; i < nr; i++) free(rows[i].line); free(rows);
    return out;
}
