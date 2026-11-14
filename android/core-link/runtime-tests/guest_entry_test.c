#include "oodle_fixture.h"
// 真实共享 guest_main 的 Android 准入顺序；fault状态/SDK端点明确为合成，实际fault机制由其独立测试覆盖。
#include "guest_main.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static const char *mode;
static int init, xstack, ready, entered, ordinal, registered, modules, glslc, finished, shutdown, published;
int s2a_android_fault_thread_init(void) { assert(registered==1 && !init && !xstack && !entered); init=1; return !strcmp(mode,"init-fail") ? ENOMEM : 0; }
int s2a_android_fault_thread_ready(void) { assert(init && xstack && !entered); ready=1; return strcmp(mode,"ready-fail")!=0; }
int s2a_android_runtime_enter_guest_thread(void) { assert(init && xstack && ready); return 0; }
void sw_xstack_thread_init(uint64_t host,uint64_t guest) { assert(init && !xstack && host && guest==0x10000); xstack=1; }
void s2a_det_set_ord(int n) { assert(ready && !n); ordinal=1; }
void s2a_det_acquire(void) { assert(ordinal); }
// 主 guest 发布运行态：逐线程准入之后、进 SDK 之前恰好一次（#961）。
int s2a_android_runtime_publish_running(void) { assert(ready && ordinal && !entered && !published); published=1; return 0; }
void sw_call_on_stack(void (*fn)(void),uint64_t sp) { assert(init && xstack && ready && ordinal && published && sp==0x10000); entered=1; puts("SDK_ENTRY"); fflush(stdout); fn(); }
uint32_t s2a_thread_main_init(void) { assert(!registered && !init && !entered); registered++; return 71; }
uint32_t s2a_thread_current(void) { assert(registered==1 && entered); return 71; }
void s2a_boot_mark(const char *why) { assert(why); }
void run_module_inits(void) { assert(entered && !modules); modules=1; }
void s2a_glslc_tool_maybe(void) { assert(modules && !glslc && !shutdown); glslc=1; }
int32_t s2a_direct_finish(int normal) { assert(entered && normal==1 && !finished && !shutdown); finished=1; return 0; }
void s2a_host_shutdown(const char *why) { assert(!strcmp(why,"nnMain 返回") && finished && !shutdown); shutdown=1; }
static void empty(void) { assert(entered); }
static void nnos(uint64_t h,uint64_t z) { assert(h==71 && !z && entered); }
void *guest_sym(const char *name) { return !strcmp(name,"nnosInitialize") ? (void *)nnos : (void *)empty; }
int main(int argc,char **argv) {
    assert(argc==2); mode=argv[1]; struct s2a_guest_main_args args={0x10000,0,NULL};
    s2a_guest_main(&args); assert(init && xstack && ready && entered && modules && glslc && finished && shutdown); puts("PASS actual shared Android entry"); return 0;
}
