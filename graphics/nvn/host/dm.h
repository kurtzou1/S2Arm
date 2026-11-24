// 上游 dm/host/dm.h 的替身（直连图形层 gfx/nvn 用；改动见 docs/直连图形层_改动清单.md）：
//   宿主公共部分（LOG / die / now_ns / module_t / module_of / 线程槽）取 S2Arm 原生层自己的 native.h，
//   其余声明照上游原文（MIT，© seedds），实现由 S2Arm 原生层（runtime/src/dmhost.c）与适配层（graphics/nvn/host_adapt.m）给。
#pragma once
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../runtime/src/native.h"
#include "game_profile.h"
static inline const char *dm_main_build(void) { return s2a_main_build_id(); }
int dm_sdk_major(void);
#define DM_SDK_OLD(major) ((major) > 0 && (major) <= 10)   // SDK 10 and older: NVN API 53, the shared-font address points at the TTF itself
int dm_main_imports(const char *prefix);   // main imports a symbol whose name starts with prefix (loader.c)
// Gate dispatch: rewritten svc / timer reads come in through the common entry, ret_addr = the return point of that gate block, regs points to the saved x0..x30
uint64_t gate_dispatch(uint64_t ret_addr, uint64_t *regs);
// Observation gates (rewriter OBS tables in the profiles' patches.py, applied by patch_nso.py; numbering matches): read-only callbacks, called on a gate hit once attached
enum { OBS_MOVIE_RING_LINK = 19, OBS_MOVIE_RING_UNLINK = 20,   // Metroid Dread 2.1.0's movie request ring (hle_movie.c)
       OBS_UE_MALLOC = 21,                                       // DRAGON QUEST VII Reimagined 1.2.0: Unreal's allocator object just made (hle_uemalloc.c)
       OBS_MAX = 22 };
void gate_obs_set(int id, void (*fn)(const uint64_t *regs));
int gate_obs_present(int id);
uint64_t guest_ns(void);              // Guest clock (runtime/src/os.c; does not advance while frozen, guest_clock_freeze)
int dm_detclock_enabled(void);
void dm_guest_clock_advanced(void);
void guest_clock_freeze(int on);
void guest_clock_freeze_for(int reason, int on);   // Freeze by reason (1 background, 2 system keyboard); see runtime/src/os.c
void dm_guest_frame_tick(void);        // Called on every present (hle_nvn.c): when DM_DETCLOCK is on, advances the guest clock by one fixed step
uint64_t dm_nvn_frame_count(void);
uint64_t dm_nvn_sub_cpu_ns(void);     // Cumulative CPU nanoseconds of submit (excluding present)
void dm_backtrace(uint64_t fp);
void crash_watch_progress(uint32_t tick, const char *stage);
void crash_watch_frame(void);
void crash_watch_pregame_done(void);
uint64_t crash_watch_progress_count(void);
void crash_dump_now(const char *why);   // Dump state on demand (threads + graphics wait points), without exiting
// Diagnostic switches: read once from environment variables when main starts (getenv takes the libc global environment lock, and on a hot path it would make all guest threads queue up)
extern uint64_t g_t0_ns;   // Host start time (now_ns), used for relative times in the log
extern struct dm_flags { int thr, svc, fs, movie, dbg, imports, bootprof; } g_flag;
void *objmap_get(const void *guest); void objmap_put(const void *guest, void *host); void *objmap_del(const void *guest);
void hle_signal_system_event(void *g);   // hle_thread.c: signal a service-layer SystemEvent (any thread)
void hle_bind_system_event(void *g, int autoclear);   // On a guest thread, bind a guest SystemEvent to a kernel event
void hle_clear_system_event(void *g);    // hle_thread.c: clear a bound service-layer SystemEvent (any thread)
// Page fault hook / hook before the host writes guest memory (crash.c; used for write-protect dirty page tracking)
void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uc));
void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len));
void dm_res_report_register(void (*fn)(uint32_t tick, const char *why));   // Resource count callback (registered by the graphics layer): called every 250 ticks, when the loading screen has been dismissed, and on exit when the record is full
void (*dm_res_report_cb(void))(uint32_t tick, const char *why);   // Get the registered resource count callback (null if not registered)
void dm_guest_write_prepare(void *addr, size_t len);
// Graphics lifecycle (hle_nvn.c), called by the iOS front end when entering and leaving the background.
// 进后台分两段：suspend 只关 / 开入口门闸，必须能在 UIKit 通知里立即返回；
// drain 在有后台执行时间的工作队列上等旧调用退出并排空 GPU。
void dm_gfx_suspend(int on);
void dm_gfx_suspend_drain(void);
// Close the direct submit gate at a fresh guest startup boundary; return an error if any API call is already in flight. This does not drain or submit work.
int dm_gfx_guest_start_hold(void);
// S2Arm：游戏线程在图形层里阻塞等 GPU / 上屏 / 管线前后放开 / 取回虚拟核（runtime/src/thread.c，可嵌套、非游戏线程空操作）；直连层等待点各加一行，见 docs/直连图形层_改动清单.md
void s2a_core_block_begin(void); void s2a_core_block_end(void);
// S2Arm：ProgramSetShaders 时库里没有的键登记进待编表，提交线程第一次用到时 dm_shader_miss_late 现编（graphics/nvn/host/dsh_miss.inc，§12.3 s2a_dsh_compile）
void dm_shader_miss(const uint8_t key[8], uint64_t code, const void *control); int dm_shader_miss_late(const char *k16, uint64_t code, const void *control); int dm_shader_reuse(const char *k16);   // control：在用控制段（Switch 2 NVN2 键在这里登记，dsh_miss.inc）
// 着色器补料（graphics/nvn/host/dsh_salvage.inc）：kind 1 不在映射表 / 2 现编失败 / 4 管线建不起来 / 8 补齐变体做不了；存进 wire/<号>/shader_miss/ 随诊断包带走
void dm_shader_salvage(const char *k16, int kind, uint64_t code, const void *control, const char *why);
int dm_shader_fout(const uint8_t key[8], uint64_t code, const void *control, uint32_t umask, uint32_t smask, char *path, size_t n);
int dm_shader_fout_fresh(const char *key16, uint32_t umask, uint32_t smask);   // S2Arm：兜底目录里这个变体能不能直接用（同翻译链、不比源码旧）   // S2Arm：片元输出逐位置定类型的变体源码（graphics/nvn/host/dsh_miss.inc）
// S2Arm（#800）：采样器归约变体源码 <键>_se.metal（graphics/nvn/host/dsh_miss.inc，S2A.Dsh FsRd）：成功 0、没有能改的采样 3、做不了 1；_fresh = 兜底目录里那份能直接用；
//   _snap = 提交线程上把控制段 + 代码区整份拷下给后台用（*code / *control 指进返回的那块，调用方 free；NULL = 认不出）
int dm_shader_se(const uint8_t key[8], uint64_t code, const void *control, char *path, size_t n);
int dm_shader_vpad(const uint8_t key[8], uint64_t code, const void *control, uint32_t mask, char *path, size_t n);   // 顶点补齐变体（dsh_miss.inc）
int dm_shader_vpad_cached(const uint8_t key[8], int st, uint32_t mask, char *path, size_t n);   // 顶点（st 0）/ 网格（st 5）着色器控制段过期时，用本机同链源码或包里的客体输入出补齐变体（dsh_miss.inc）
int dm_shader_base_cached(const uint8_t key[8], int st, char *path, size_t n);   // #770 任务 / 网格着色器本机基础源码（dsh_miss.inc）
int dm_shader_se_cached(const uint8_t key[8], int st, char *path, size_t n);   // 片元（st 1）/ 计算（st 2）控制段过期时，用本机同链源码或包里的客体输入出采样器模拟变体（dsh_miss.inc）
int dm_shader_refresh(const char *k16);   // 翻译器换了之后本机现编过的键按单支重译（dsh_miss.inc）：1 本来就是本机的、2 重译后源码没变、3 变了、0 做不了
enum { DM_RF_STATS = 6 };
void dm_shader_refresh_stats(uint64_t out[DM_RF_STATS]);   // 本局重译 [0] 没变、[1] 变了；做不了按原因：[2] 没有客体输入、[3] 补料核不过、[4] 翻译失败、[5] 阶段认不出 / 没有翻译器（预热收尾行）
int mtl_guest_input(const uint8_t key[8], int st, uint8_t **buf, uint32_t *nctl, uint32_t *ncode);   // 包里这支的客体输入（nvn_mtl.m，库容器种类 56）：0 取到（调用方 free）、1 没有、-1 段坏了
int dm_shader_se_fresh(const char *key16);
void *dm_shader_snap(uint64_t code, const void *control, uint64_t *code_out, const void **control_out);
int dm_shader_retrans(const uint8_t key[8], uint64_t code, const void *control);   // 出包库计算着色器按本机翻译器重出源码 <键>_b.metal（dsh_miss.inc，v0.4.1 重译抢跑）：成功 0、做不了 1
void mtl_se_stats(uint64_t out[2]);   // S2Arm（#800，nvn_mtl.m se_done）：采样器归约变体 [0] 本局在设备上编好的着色器数、[1] 编不出的（收局汇总行）
void mtl_vp_stats(uint64_t out[2]);   // S2Arm（nvn_mtl.m vp_done）：顶点补齐变体 [0] 本局在设备上编好的、[1] 编不出的
void mtl_libact_stats(uint64_t out[6]);   // D-92BW（nvn_mtl.m）：预热后放掉的着色器 / 之后补回次数 / 补回合计 ns / 最长 ns / 补回失败 / 库切片高位区在用字节
void mtl_hybrid_pkg_stats(uint64_t out[7]);   // S2Arm（nvn_hybrid.inc hybrid_pkg_base）：随包拉取基础管线 [0] 命中、[1] 包里没有这一对、[2] 有文件查不中、[3] 当场解压的份数、[4] 解压合计纳秒、
                                               //   [5] 开局首查预热（hybrid_pkg_warm）0 没做 / 1 查中 / 2 没查中、[6] 预热耗时纳秒
void mtl_shmap_rt_add(const char *key, const char *stage); int mtl_shmap_known(const char *key); int mtl_shlib_has(const char *key);
#define DM_BLOCK_BEGIN() s2a_core_block_begin()
#define DM_BLOCK_END() s2a_core_block_end()
void dm_gfx_enter(void); void dm_gfx_leave(void);   // hle_nvn.c: the gate dm_gfx_suspend closes, for graphics layers other than NVN (dm/gfx/vk)
void dm_gfx_shot_at(long k, const char *path);
void dm_shot_written(const char *path, int ok);   // The graphics side finished writing a screenshot to disk (diag.c: DM_TICK_HOLD=E:SHOT unfreezes on this)
void dm_host_shutdown(const char *why);   // Graceful exit (crash.c): stop background threads and audio, drain graphics, then _exit(0); used by SIGTERM and the iOS App termination callback   // graphics side: screenshot of the k-th frame after the current presented frame (nvn_mtl.m)
