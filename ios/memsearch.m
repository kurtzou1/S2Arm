// 诊断：局内数值搜索（11-13 金手指堆偏移根修，找游戏数据在本局堆里的真实位置，与金手指按真机写的偏移对比）。缺省什么都不做。
//   往 App 容器 Documents/memsearch.txt 写一行命令（devicectl copy to），本线程每秒看一次文件改时间，变了就执行：
//     find <十进制值>   扫游戏堆（s2a_mem_guest_split 的 [堆起点, +已用]）里等于该值的 4 字节（4 对齐），记下全部命中
//     next <十进制值>   在上次命中里留下现在等于该值的
//   结果写 Documents/memsearch_out.txt：命中数，前 200 个「堆+偏移 = 值」，以及离 S2A_MEMSEARCH_REF（缺省 0x5C27B318，奥德赛 9999 Coins Save 1）最近的几处与差值。
//   只读常驻页（mincore），读一律经 vm_read_overwrite（页被写跟踪改成不可读也只是读失败，不崩），不在游戏线程上跑。
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
void s2a_mem_guest_split(uint64_t *heap_lo, uint64_t *heap_len, uint64_t *alias_lo, uint64_t *alias_len, uint64_t *phys);

static uint32_t *g_hit; static size_t g_nhit, g_chit;
static NSString *docs(NSString *n) { return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:n]; }
static int rd(uint64_t a, void *out, size_t n) { vm_size_t got = 0; return vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)out, &got) == KERN_SUCCESS && got == n; }

static void find(uint64_t lo, uint64_t len, uint32_t v) {
    g_nhit = 0;
    static uint8_t buf[1 << 20]; static char vec[(1 << 20) / 16384 + 1];
    for (uint64_t off = 0; off < len; off += sizeof buf) {
        size_t n = (size_t)(len - off < sizeof buf ? len - off : sizeof buf);
        if (mincore((void *)(lo + off), n, vec)) continue;
        for (size_t p = 0; p < n; p += 16384) {
            if (!(vec[p / 16384] & 1)) continue;
            size_t m = n - p < 16384 ? n - p : 16384;
            if (!rd(lo + off + p, buf, m)) continue;
            for (size_t i = 0; i + 4 <= m; i += 4) {
                uint32_t x; memcpy(&x, buf + i, 4);
                if (x != v) continue;
                if (g_nhit == g_chit) { size_t c = g_chit ? g_chit * 2 : 1 << 16; uint32_t *q = realloc(g_hit, c * sizeof *q); if (!q) return; g_hit = q; g_chit = c; }
                g_hit[g_nhit++] = (uint32_t)(off + p + i);
            }
        }
    }
}
static void next(uint64_t lo, uint32_t v) {
    size_t k = 0;
    for (size_t i = 0; i < g_nhit; i++) { uint32_t x; if (rd(lo + g_hit[i], &x, 4) && x == v) g_hit[k++] = g_hit[i]; }
    g_nhit = k;
}
static void report(uint64_t lo, const char *cmd) {
    FILE *f = fopen(docs(@"memsearch_out.txt").fileSystemRepresentation, "w"); if (!f) return;
    const char *e = getenv("S2A_MEMSEARCH_REF"); uint64_t ref = e ? strtoull(e, NULL, 0) : 0x5C27B318;
    fprintf(f, "命令 %s\n堆起点 %#llx\n命中 %zu 处\n", cmd, (unsigned long long)lo, g_nhit);
    for (size_t i = 0; i < g_nhit && i < 200; i++) { uint32_t x = 0; rd(lo + g_hit[i], &x, 4); fprintf(f, "堆+%#x = %u（离参考 %+lld）\n", g_hit[i], x, (long long)g_hit[i] - (long long)ref); }
    fclose(f);
}
static void *loop(void *arg) {
    (void)arg; struct timespec last = {0};
    for (;;) {
        sleep(1);
        struct stat st; const char *p = docs(@"memsearch.txt").fileSystemRepresentation;
        if (stat(p, &st) || (st.st_mtimespec.tv_sec == last.tv_sec && st.st_mtimespec.tv_nsec == last.tv_nsec)) continue;
        last = st.st_mtimespec;
        char line[64] = {0}; FILE *f = fopen(p, "r"); if (!f) continue; if (!fgets(line, sizeof line, f)) line[0] = 0; fclose(f);
        line[strcspn(line, "\r\n")] = 0;
        uint64_t lo = 0, len = 0, alo, alen, phys; s2a_mem_guest_split(&lo, &len, &alo, &alen, &phys);
        unsigned long v = 0;
        if (!lo || !len) continue;
        if (sscanf(line, "find %lu", &v) == 1) find(lo, len, (uint32_t)v);
        else if (sscanf(line, "next %lu", &v) == 1) next(lo, (uint32_t)v);
        else continue;
        report(lo, line);
        NSLog(@"局内数值搜索：%s → %zu 处", line, g_nhit);
    }
    return NULL;
}
__attribute__((constructor)) static void memsearch_start(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:docs(@"memsearch.on")]) return;   // 只有放了 Documents/memsearch.on 的 App 才起这个线程
    pthread_t t; pthread_create(&t, NULL, loop, NULL); pthread_detach(t);
}
