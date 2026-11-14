// 仅测试链接用：共享 NVN 前端的宿主/诊断依赖最小实现。不是正式 HLE 服务层。
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <time.h>
#include "native.h"
#include "graphics/nvn/host/dm.h"
#include "graphics/nvn/host/front.h"
#include "graphics/nvn/host/game_profile.h"

uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
uint64_t guest_ns(void) { return now_ns(); }
module_t *module_of(const void *p) { (void)p; return NULL; }
int front_screen_max_fps(void) { return 60; }
static s2a_nvn_profile g_profile;
const s2a_nvn_profile *s2a_nvn_prof(void) { return &g_profile; }
void dm_backtrace(uint64_t fp) { (void)fp; }
int dm_detclock_enabled(void) { return 0; }
void dm_guest_write_prepare(void *addr, size_t len) { (void)addr; (void)len; }
void dm_fault_hook_register(int (*fn)(void *, int, void *)) { (void)fn; }
void dm_guest_write_prep_register(void (*fn)(void *, size_t)) { (void)fn; }
void dm_shader_miss(const uint8_t key[8], uint64_t code, const void *control) { (void)key; (void)code; (void)control; }
void dm_shader_mesh_hold(uint64_t code, const void *control) { (void)code; (void)control; }
void dm_shader_mesh_hold_key(const uint8_t key[8], uint64_t code, const void *control) { (void)key; (void)code; (void)control; }
void s2a_core_block_begin(void) {}
void s2a_core_block_end(void) {}
void s2a_direct_fail(const char *why) { if (why) fprintf(stderr, "[nvn-test] direct fail: %s\n", why); }
void nvn_big_entry(void) {}
void nvn_prof_entry(void) {}
void nvn_unimpl_entry(void) { fprintf(stderr, "[nvn-test] unimplemented entry\n"); }
void dm_guest_frame_tick(void) {}
uint64_t g_t0_ns;
