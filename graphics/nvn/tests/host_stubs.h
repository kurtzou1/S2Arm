// 直连层（libnvn.a）单测的宿主替身：直连层只在真宿主里链，这里给出它引用到的宿主符号（不被调用到的给空实现）。
// 用的单测：graphics/nvn/tests/t_nvn_m3.m、tests/vk_indirect_count（Vulkan 层）。宽屏核心入口的桩由 graphics/nvn/Makefile 的 widen-stubs 按 s2a_widen.h 生成（widen_stubs.inc，-I 指过去）
#import <QuartzCore/CAMetalLayer.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "s2a_gfx_mode.h"
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
int s2a_gfx_mode(void) { return S2A_GFX_DIRECT; }
// 模块名表：不 include native.h 的单测用这份粗糙替身（形状不同、ABI 无关）；include 了 native.h 的单测自己按真实类型定义
#ifndef S2A_TEST_REAL_NATIVE
void *g_mod; int g_nmod;   // 真表是 module_t *g_mod（指针，native.h）：替身同形状，g_nmod = 0 时从不解引用
void *module_of(void *p) { (void)p; return NULL; }
#endif
void s2a_backtrace(uint64_t fp) { (void)fp; }
void s2a_where(uint64_t a, char *b, size_t n) { snprintf(b, n, "%llx", (unsigned long long)a); }   // 真宿主是 runtime/src/crash.c（hle_nvn.c nvn_qlog_c 用）
// 「核」的两个入口：默认空实现；要真跑的核 / 锁序判据（t_nvn_abba.m）自己定义 S2A_TEST_OWN_CORE 后提供
#ifndef S2A_TEST_OWN_CORE
void s2a_core_block_begin(void) {} void s2a_core_block_end(void) {}
#endif
void s2a_sleep_ns(int64_t ns) { if (ns > 0) { struct timespec t = {ns / 1000000000, ns % 1000000000}; nanosleep(&t, NULL); } }   // 真宿主是 runtime/src/thread.c 的按时睡
void s2a_crash_wait_dump_register(void (*fn)(void)) { (void)fn; }
void s2a_direct_summary_register(void (*fn)(int)) { (void)fn; }
void s2a_fault_hook_register(void *fn) { (void)fn; }
void s2a_frame_presented(void) {}
void s2a_nominal_fps_set(int fps) { (void)fps; }   // 标称帧率（runtime/src/ap_host.c）：单测不接自动玩家
void s2a_guest_write_prep_register(void *fn) { (void)fn; }
uint64_t s2a_npdm_program_id(void) { return 0; }
void s2a_res_report_register(void *fn) { (void)fn; }
int s2a_screen_w(void) { return 1920; }
int s2a_screen_h(void) { return 1080; }
unsigned s2a_screen_gen(void) { return 0; } int s2a_screen_switch(int w, int h) { (void)w; (void)h; return 0; }   // 运行中换屏（runtime/src/widen.c）：单测不换
void s2a_track_write_quiet(uint64_t a, uint64_t n) { (void)a; (void)n; }
void *sw_xstack_wrap(const char *name, void *fn) { (void)name; return fn; }
// 宽屏（graphics/widen）：s2a_widen_game() = 0 时直连不调其余入口。
// 把后端源码编进同一 TU 的单测会经 widen_glue.inc 拿到真实原型，这里按原型写不了，改由它们自己给（S2A_TEST_REAL_WIDEN）
#ifndef S2A_TEST_REAL_WIDEN
// 宽屏核心入口一律弱符号：要按脚本行事的单测（tests/vk_core 的按内容判画布用例）自己给强定义的假核心，其余单测照旧拿这些桩
int s2a_widen_game(void) { return 0; } int s2a_widen_full(void) { return 0; } int s2a_widen_layout(void) { return 0; } __attribute__((weak)) int s2a_widen_init(int w, uint32_t f) { (void)w; (void)f; return -1; }
// 返回 float 的入口按原型手写：自动生成的桩返回 long，float 走浮点寄存器带回，调用方读到的是不确定值。缺省 1 同真核心没会话时；单测可改
//   （t_nvn_m3 ⑤' 无窗口满屏几何：屏宽高比 = 16:9 × k ÷ ky）
static float g_stub_widen_k = 1, g_stub_widen_ky = 1;
__attribute__((weak)) float s2a_widen_k(void) { return g_stub_widen_k; } __attribute__((weak)) float s2a_widen_ky(void) { return g_stub_widen_ky; }
__attribute__((weak)) float s2a_widen_frag_scale_y(void) { return 1; }
#define WSTUB(n) __attribute__((weak)) long n(void) { return 0; }
#include "widen_stubs.inc"   // 其余入口：make test 按 graphics/widen/export/s2a_widen.h 生成
#endif
// 测试层自动玩家（widen_glue.inc 弱引用）：轻测不链测试层
int s2a_autoplay_on(void) { return 0; }
// Mac 出图层（host_adapt.m front_metal_layer 按名字取）：离屏层，不进窗口
static CAMetalLayer *g_layer;
__attribute__((visibility("default"))) void *s2a_mac_front_layer(void) { return (__bridge void *)g_layer; }

