// 系统编译服务建渲染管线失败（XPC 连接中断 / 超时，pso_err_transient）后的重试节奏（pso_get_vs 用；纯函数，帧号由调用方给，单测 graphics/nvn/tests/t_pso_retry.c）。
// 10-26 巫师3：35 局里只一局、低地址区剩 40 MB 那一刻失败，同一对别的局都编得出——真暂时性，隔 30 帧再试就好。
// 11-13 #618 诊断包（M1 Max，0400486024DEC000，三局）：失败的总是同一对着色器（一局 b9759612b84c3390 / f6572281a9ae23fd、另一局 15733d238be5f91b / d669c3d74280357c，
//   各 8 次以上，红行封顶 8 条），每次建 4 ms 内就断（Metal 内部已重试多次）——编译服务在这一对上确定性崩溃。原来每 30 帧再试、整局不停：每次都让系统编译服务崩一回，
//   同时在编的别的管线跟着断（同一刻的任务 / 网格管线一起被拒），这一对的绘制也从没画出来过。
// 节奏：第 n 次失败后隔 30·4^(n-1) 帧（30 / 120 / 480）再试；连续失败 PSO_RETRY_MAX 次 = 编译服务编不了这一对，调用方放进失败名单、报红、整局不再试。
//   巫师3 那种一次性失败第一次重试就编出来，不受影响。
#pragma once
#include <stdint.h>

enum { PSO_RETRY_FRAMES = 30, PSO_RETRY_MAX = 4 };
#define PSO_RETRY_FRAME_MASK ((1ull << 56) - 1)

// fails：这一对连续失败的次数（含这一次，≥ 1）。返回下次重试的帧号；0 = 不再试
static inline uint64_t pso_retry_at(uint64_t now, unsigned fails) {
    if (fails == 0 || fails >= PSO_RETRY_MAX) return 0;
    return now + ((uint64_t)PSO_RETRY_FRAMES << (2 * (fails - 1)));
}
// 重试表的一格：高 8 位失败次数、低 56 位重试帧号（一个 NSNumber 存下，不加第二张表）
static inline uint64_t pso_retry_pack(uint64_t at, unsigned fails) { return (uint64_t)(fails & 0xff) << 56 | (at & PSO_RETRY_FRAME_MASK); }
static inline uint64_t pso_retry_frame(uint64_t v) { return v & PSO_RETRY_FRAME_MASK; }
static inline unsigned pso_retry_fails(uint64_t v) { return (unsigned)(v >> 56); }
