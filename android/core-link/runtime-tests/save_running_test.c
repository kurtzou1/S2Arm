// 安卓主 guest 运行态发布（#961）的宿主验收：真实 HostApi / stop owner（host_android.c）、
// Android runtime.c、共用 guest_main.c / session.c / direct_prompt.c 一起编链；
// managed 服务、fault、tracking、SDK 与存档服务出口是受控替身，不代表设备验收。
// 只经既有接口观测（共用会话状态、存档原子态轮询、HostApi 停止），不引用被测的新接缝，
// 所以修前树上同一份夹具照样编链，红在行为断言上。
#define S2A_ENTRY_FIXTURE 1
#define main stop_fixture_main
#define sw_call_on_stack fixture_sw_call_on_stack
#define s2a_thread_main_init fixture_thread_main_init
#define s2a_det_acquire fixture_det_acquire
#include "stop_admission_test.c"
#undef s2a_det_acquire
#undef s2a_thread_main_init
#undef sw_call_on_stack
#undef main

#include "s2a_session.h"
#include "s2a_direct_prompt.h"
#include "capprobe/capprobe.h"
#include "dguard_android.h"
#include <android/log.h> // 实际 NDK 头；下面的替身按它的声明定义

static const char *test_case;
static int is(const char *name) { return !strcmp(test_case, name); }
static int registered, attached, probed, tracked, sdk_entered;
static int state_in_admission = -1, state_after_child = -1;
static int seen_state = -1, seen_poll = -1, seen_calls = -1, seen_stop = -1;
static int provider_calls;

// 静态并入同一 DSO 的服务出口（--exclude-libs 下不可见）：与生产 direct_prompt.c 的弱引用同一链接方式。
__attribute__((visibility("hidden"))) int S2A_SaveAtomicState(void) {
    provider_calls++;
    return is("safe") ? 0 : 2;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag; (void)fmt; return 1;
}
int s2a_android_session_log_start(const char *dir, uint64_t id) { assert(dir && id == session); return 0; }
int s2a_android_docs_bind(const char *dir) { assert(dir); return 0; }
int s2a_capprobe_ensure(void) { return -1; } // 夹具无能力探针，按不支持处理
int s2a_android_dguard_launch(uint64_t id, const char *dir, unsigned abi) {
    (void)id; (void)dir; (void)abi; assert(!"fixture is generic only"); return -1;
}
uint32_t s2a_thread_main_init(void) { registered = 1; return fixture_thread_main_init(); }
int s2a_android_fault_thread_init(void) { assert(registered); return 0; }
int s2a_android_fault_thread_ready(void) { assert(registered); return 1; }
int32_t s2a_android_services_attach_thread(uint64_t id, struct s2a_android_services_status *s) {
    assert(registered && id == session && s2a_android_runtime_session() == session);
    attached = 1;
    *s = (struct s2a_android_services_status){sizeof *s, S2A_ANDROID_SERVICES_ABI, session, S2A_SERVICES_READY, 0};
    return is("attach-fail") ? -5 : 0;
}
int s2a_android_fault_probe(void) { assert(attached); probed = 1; return 0; }
unsigned s2a_android_fault_unsupported_record(void) { return 0; }
int s2a_track_runtime_ready(void) {
    assert(attached && probed);
    tracked = 1;
    // 逐线程准入（主 / 子线程共用）里不得发布：子线程也走这里。
    if (state_in_admission < 0) state_in_admission = s2a_host_session_state();
    return !is("track-fail");
}

static void host_request_stop(void) {
    const s2a_host_api_v1 *api = s2a_host_get();
    api->stop->request_stop(api->host, S2A_HOST_STOP_DEVICE_LOST, "fixture stop");
}

// 主线程逐线程准入全部通过之后、进 SDK 之前的确定性插入点。
void s2a_det_acquire(void) {
    assert(registered && attached && probed && tracked && !sdk_entered);
    unsigned generation = s2a_session_generation();
    if (is("stop-before-publish")) host_request_stop();
    if (is("session-failed")) assert(s2a_session_service_failed(generation) == 0);
    if (is("already-running")) assert(s2a_session_running(generation) == 0);
    if (is("child-admission")) {
        // 子线程准入与主线程共用这条入口；它不能顺带发布运行态。
        assert(s2a_android_runtime_enter_guest_thread() == 0);
        state_after_child = s2a_host_session_state();
    }
    fixture_det_acquire();
}

void sw_call_on_stack(void (*fn)(void), uint64_t sp) {
    sdk_entered = 1;
    seen_state = s2a_host_session_state();
    seen_poll = s2a_save_atomic_poll();
    seen_calls = provider_calls;
    seen_stop = s2a_android_host_stop_requested();
    if (is("stop-after-publish")) host_request_stop();
    fixture_sw_call_on_stack(fn, sp);
}

struct expect { const char *name; int fatal, sdk, state, poll, calls, stop; };
static const struct expect expects[] = {
    // state：进 SDK 时（fatal 例为致命退出时）的共用会话状态；stop：同一时刻 HostApi 是否已接受停止
    {"startup",             0, 1, S2A_SESSION_RUNNING,  2, 1, 0},
    {"safe",                0, 1, S2A_SESSION_RUNNING,  0, 1, 0},
    {"child-admission",     0, 1, S2A_SESSION_RUNNING,  2, 1, 0},
    {"already-running",     0, 1, S2A_SESSION_RUNNING,  2, 1, 0},
    {"stop-after-publish",  0, 1, S2A_SESSION_RUNNING,  2, 1, 0},
    {"stop-before-publish", 1, 0, S2A_SESSION_STARTING, 0, 0, 1},
    {"session-failed",      1, 0, S2A_SESSION_FAILED,   0, 0, 1},
    {"attach-fail",         1, 0, S2A_SESSION_STARTING, 0, 0, 1},
    {"track-fail",          1, 0, S2A_SESSION_STARTING, 0, 0, 1},
};
static const struct expect *expected(void) {
    for (size_t i = 0; i < sizeof expects / sizeof expects[0]; i++)
        if (is(expects[i].name)) return &expects[i];
    return NULL;
}
static int report(int fatal, int state, int stop) {
    const struct expect *e = expected();
    int poll = sdk_entered ? seen_poll : 0, calls = provider_calls;
    int admission_ok = e->fatal || state_in_admission == S2A_SESSION_STARTING;
    int child_ok = !is("child-admission") || state_after_child == S2A_SESSION_STARTING;
    printf("case=%s fatal=%d/%d sdk=%d/%d state=%d/%d poll=%d/%d calls=%d/%d stop=%d/%d "
           "admission_state=%d child_state=%d\n",
           test_case, fatal, e->fatal, sdk_entered, e->sdk, state, e->state, poll, e->poll,
           calls, e->calls, stop, e->stop, state_in_admission, state_after_child);
    fflush(stdout);
    return fatal != e->fatal || sdk_entered != e->sdk || state != e->state || poll != e->poll ||
           calls != e->calls || stop != e->stop || !admission_ok || !child_ok;
}

// die() 在 S2A_CRASH_QUIET=1 下走 _exit(70)；在这里记下致命退出那一刻的状态再判定。
void __real__exit(int);
void __wrap__exit(int code) {
    int bad = code != 70 || report(1, s2a_host_session_state(), s2a_android_host_stop_requested());
    __real__exit(bad);
}

int main(int argc, char **argv) {
    assert(argc == 2); test_case = argv[1];
    assert(expected());
    struct s2a_android_host_config config = {"en-US", "US", "UTC", 160, 160, 0};
    assert(!s2a_android_host_register(&config));
    assert(s2a_host_session_state() == S2A_SESSION_STARTING);
    release_entry = 1;
    boot(NULL);
    assert(registered && attached && probed && tracked);
    if (is("stop-after-publish") && result != S2A_RUNTIME_STOP) return 1;
    return report(0, seen_state, seen_stop);
}
