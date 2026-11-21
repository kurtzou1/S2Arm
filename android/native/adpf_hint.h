// Android Performance Hint (ADPF): one measured worker thread, no CPU affinity
// policy. Frame correlation is by sequence: the direct shim tags every job with
// the frame it executes in, so a span can only be reported against the present
// that actually depended on it — never a present interval mistaken for work.
// 会话成员：测量线程 + 登记的常驻帧线程（两级回放的录制线程）+ 定期扫出的忙线程（API 34 setThreads），合计最多 5 条。
// 目标：本局最短周期 × 3/4（system_tuning.h）。API 35 起带 GPU 时长上报，API 36 起发负载上升信号、建图形管线会话；
// 任一符号缺就退回只报 CPU 时长的旧行为。参照 nx2android perf_android.c、BananaNative vka_perf.c、BOTWRecompAndroid（均为 MIT）。
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void s2a_adpf_set_foreground(int foreground);
void s2a_adpf_set_surface(int present);
// A queued translation job is about to execute on this thread, tagged with the
// frame sequence it belongs to. The first job of a frame opens its work span;
// later jobs of the same frame are ignored (the span is a wall-clock critical
// path, not a sum of job durations).
void s2a_adpf_work_begin(uint64_t seq);
// The frame's GPU dependency is complete (translation queue drained), before
// present/acquire pacing. Reports the recorded span only when its sequence is
// still this frame; a stale sequence means its present never happened and the
// record is dropped instead of charged to the wrong frame.
void s2a_adpf_frame_end(int64_t target_ns, uint64_t seq);
void s2a_adpf_discard(void);
// 调用线程是常驻的帧线程（录制线程起点调一次）：此后的会话一定带上它，不靠忙线程扫描的阈值。
void s2a_adpf_pin_self(void);
// GPU 时长来源（后端段完成线程调）：一段的 GPU 首尾跨度；上屏段完成时结一帧，下一次上报带上这一帧的 GPU 时长。
void s2a_adpf_gpu_segment(uint64_t gpu_ns);
void s2a_adpf_gpu_frame_end(void);

// ---- 纯函数（宿主测试直接喂输入）----
// ADPF 目标 = 本帧周期 × 3/4（不用本局最短周期，见 adpf_hint.c）。
int64_t s2a_adpf_target_ns(int64_t frame_period_ns);
// 忙线程挑选：must 里的线程先入（去重），其余按两次扫描间的 utime+stime 增量从大到小，
// 增量 ≥ 15% 一个核（wall_ns 内）且上次扫描时已在的才入，合计最多 max 条。返回条数。
struct s2a_adpf_task { int32_t tid; uint64_t ticks; };
int s2a_adpf_pick_threads(const struct s2a_adpf_task *cur, int ncur, const struct s2a_adpf_task *prev, int nprev,
                          uint64_t wall_ns, long hz, const int32_t *must, int nmust, int32_t *out, int max);
// 负载上升信号：连续 3 帧 max(工作, GPU) > 1.05 × 周期，且距上次发 ≥ 0.5 s，返回 1（该发）。
struct s2a_adpf_load { int over; uint64_t last_ns; };
int s2a_adpf_load_step(struct s2a_adpf_load *st, int64_t work_ns, int64_t gpu_ns, int64_t period_ns, uint64_t now_ns);
// The live session has successfully reported work for the recorded frame thread.
int s2a_adpf_session_active(void);
// Close an invisible renderer without changing the host lifecycle state.
void s2a_adpf_invisible(void);
void s2a_adpf_stop(void);
#ifdef S2A_ADPF_TEST
void s2a_adpf_test_reset(void);
#endif
#ifdef __cplusplus
}
#endif
