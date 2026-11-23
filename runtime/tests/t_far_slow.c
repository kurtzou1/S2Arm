// t_far_slow：Mac「地址空间不够这款」提示条的触发判据（far_slow.h s2a_far_slow_step）。期望手写：
//   ① 开局一阵（2368 次、之后 0 次，11-22 一款格斗游戏的读数）不触发  ② 每秒 2 万次连续 3 秒：第 3 秒回 1、只这一次
//   ③ 中间断一秒（低于门槛）连续数清零，要重新数满 3 秒  ④ 19999 次 / 秒不算达标
#include "../src/far_slow.h"
#include <stdio.h>
int main(void) {
    int bad = 0, k = 0, hits = 0;
    uint64_t a[] = {2368, 0, 0, 0, 0, 0}; for (unsigned i = 0; i < 6; i++) hits += s2a_far_slow_step(&k, a[i]);
    if (hits) { printf("✗ ① 开局一阵不该触发\n"); bad++; }
    k = 0; int when = -1, n = 0; for (int i = 0; i < 6; i++) if (s2a_far_slow_step(&k, 20000)) { n++; if (when < 0) when = i; }
    if (when != 2 || n != 1) { printf("✗ ② 应在第 3 秒触发一次，得第 %d 次、共 %d 次\n", when + 1, n); bad++; }
    k = 0; uint64_t b[] = {30000, 30000, 100, 30000, 30000, 30000}; when = -1; for (int i = 0; i < 6; i++) if (s2a_far_slow_step(&k, b[i]) && when < 0) when = i;
    if (when != 5) { printf("✗ ③ 断一秒后应在第 6 秒触发，得第 %d 秒\n", when + 1); bad++; }
    k = 0; hits = 0; for (int i = 0; i < 6; i++) hits += s2a_far_slow_step(&k, 19999);
    if (hits) { printf("✗ ④ 19999 次 / 秒不算达标\n"); bad++; }
    printf("%s t_far_slow：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
