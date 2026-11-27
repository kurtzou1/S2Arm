#include "oodle_fixture.h"
// 真实 HostApi + runtime + 共享 guest 入口的并发验收；只有 core / SDK / services 为合成端点。
// 包装 pthread_create 只控制新 guest 线程调度，不替换停止锁、eventfd 或生产准入。
#include "runtime.h"
#include "host_android.h"
#include "direct_session.h"
#include <assert.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint64_t session = 37, program = 0x0100000000001234ull;
// This fixture covers stop linearization in generic mode; no direct renderer.
int s2a_android_vk_session_prepare(const struct s2a_wsi_api *api, const char *game, const char *state) {
    (void)api; assert(game && state); return 0;
}
int s2a_android_vk_skip_module(const char *name) { assert(name); return 0; }
// 本夹具覆盖 generic 模式的停止线性化；vk-direct-nvn 这一例专门打开
// 「vk-direct 实验开关 + NVN 客体」这个必然黑屏的组合，验证 runtime 在起局前准确报红。
static int g_vk_direct_nvn;
int s2a_gfx_mode(void) { return g_vk_direct_nvn ? 1 : 0; }
int s2a_android_vk_nvn_guest(void) { return g_vk_direct_nvn ? 1 : 0; }
void s2a_nro_table_load(const char *dir) { assert(dir); }
void s2a_caps_apply(const char *dir) { (void)dir; }
void s2a_game_defaults_apply(const char *dir, const char *caps) { (void)dir; (void)caps; }
void s2a_fps_start(const char *dir) { assert(dir); }
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int created, release_entry, sdk_started, release_sdk, result;
static int admitted_first;
static _Atomic int sdk_calls, stop_calls;
static void *(*entry)(void *);
static void *entry_args;
int __real_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
static void *delayed_entry(void *unused) {
    (void)unused;
    pthread_mutex_lock(&lock);
    created = 1; pthread_cond_broadcast(&changed);
    while (!release_entry) pthread_cond_wait(&changed, &lock);
    pthread_mutex_unlock(&lock);
    return entry(entry_args);
}
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*fn)(void *), void *args) {
    entry = fn; entry_args = args;
    return __real_pthread_create(thread, attr, delayed_entry, NULL);
}
int s2a_window_ok(void) { return 1; }
int s2a_selfcheck(void) { return 1; }
const char *s2a_selfcheck_hint(void) { return "fixture"; }
int s2a_android_guest_writers_init(void) { return 0; }
int s2a_track_runtime_prepare(void) { return 0; }
int s2a_android_tracking_vm_prepare(void) { return 0; }
int s2a_android_runtime_signals_prepare(void) { return 0; }
void s2a_crash_install(void) { }
void s2a_term_install(void) { }
void s2a_det_init(void) { }
void load_modules(const char *dir, const char **names, int n) { assert(!strcmp(dir,"/modules") && n==1 && !strcmp(names[0],"main")); }
void load_modules_from_source(const struct s2a_loader_source *source,const char **names,int count) {
    (void)source; (void)names; (void)count; assert(!"unexpected asset source in stop fixture");
}
unsigned s2a_unresolved_count(void) { return 0; }
uint64_t s2a_mem_init(const char *npdm) { assert(!strcmp(npdm,"/modules/main.npdm")); return 0x10000; }
uint64_t s2a_program_id(void) { return program; }
int s2a_android_services_start(const struct s2a_android_services_request *r, struct s2a_android_services_status *s) {
    assert(r->session_id==session && r->host_api==s2a_host_get());
    *s=(struct s2a_android_services_status){sizeof *s,1,session,S2A_SERVICES_READY,0}; return 0;
}
int s2a_android_services_request_stop(uint64_t id, struct s2a_android_services_status *s) {
    assert(id==session && s2a_android_host_stop_requested());
    atomic_fetch_add(&stop_calls,1); s->state=S2A_SERVICES_STOP_REQUESTED; return 0;
}
void sw_xstack_thread_init(uint64_t host_top, uint64_t guest_top) { assert(host_top && guest_top==0x10000); }
void s2a_det_set_ord(int ordinal) { assert(!ordinal); }
void s2a_det_acquire(void) { }
void sw_call_on_stack(void (*fn)(void), uint64_t sp) { assert(sp==0x10000); fn(); }
uint32_t s2a_thread_main_init(void) { atomic_fetch_add(&sdk_calls,1); return 71; }
// 以下三个是 main 上就缺的夹具替身（guest_main.c / host_android.c 强引用），补上后 run_stop_admission.py
// 才能在这台机器上编链起来：主线程句柄、出包期 GLSLC 工具入口、掌机/主机模式切换。本夹具不需要真实实现。
uint32_t s2a_thread_current(void) { return 71; }   // guest_main 要求非 0（主线程登记）
void s2a_glslc_tool_maybe(void) { }
void s2a_console_mode_set(int docked) { (void)docked; }
void s2a_boot_mark(const char *s) { assert(s && *s); }
static void libc0(void) {
    pthread_mutex_lock(&lock); sdk_started=1; pthread_cond_broadcast(&changed);
    while (admitted_first && !release_sdk) pthread_cond_wait(&changed,&lock);
    pthread_mutex_unlock(&lock);
}
static void nnos(uint64_t handle,uint64_t zero) { assert(handle==71 && !zero); }
static void empty(void) { }
void run_module_inits(void) { }
void s2a_host_shutdown(const char *why) { assert(!strcmp(why,"nnMain 返回")); }
void *guest_sym(const char *name) {
    if (!strcmp(name,"_init_libc0")) return libc0;
    if (!strcmp(name,"nnosInitialize")) return nnos;
    return empty;
}
static void *boot(void *unused) {
    (void)unused; const char *names[]={"main"};
    struct s2a_android_runtime_request r={
        .services={sizeof r.services,1,session,(void *)1,s2a_host_get(),"/game","/state",(void *)2,0,0},
        .module_dir="/modules",.module_names=names,.module_count=1,.program_id=program};
    result=s2a_android_runtime_run(&r); return NULL;
}
static void host_stop(void) {
    const s2a_host_api_v1 *api=s2a_host_get();
    api->stop->request_stop(api->host,S2A_HOST_STOP_DEVICE_LOST,"GPU failed after Ready");
}
static void pending(void) {
    struct pollfd p={s2a_android_host_stop_fd(),POLLIN,0};
    assert(poll(&p,1,0)==1 && (p.revents&POLLIN));
    assert(s2a_android_host_stop_requested());
}
int main(int argc,char **argv) {
    assert(argc==2 && !s2a_android_host_try_enter_guest());
    struct s2a_android_host_config config={"en-US","US","UTC",160,160,0};
    assert(!s2a_android_host_register(&config));
    if (!strcmp(argv[1],"vk-direct-nvn")) {
        // services v2 + 选择器是 generic（frozen_direct=0）+ vk-direct 开关开 + 客体问过 nvnBootstrapLoader：
        // runtime 必须在起局前拒绝（S2A_RUNTIME_DIRECT），且一条 SDK 入口都不执行。
        g_vk_direct_nvn = 1;
        const char *names[]={"main"};
        struct s2a_android_runtime_request_v2 r2;
        memset(&r2, 0, sizeof r2);
        r2.size = sizeof r2; r2.version = S2A_ANDROID_RUNTIME_ABI_V2;
        r2.services.base.size = sizeof r2.services; r2.services.base.version = S2A_ANDROID_SERVICES_ABI_V2;
        r2.services.base.session_id = session; r2.services.base.native_owner = (void *)1;
        r2.services.base.host_api = s2a_host_get();
        r2.services.base.game_data_dir = "/game"; r2.services.base.state_dir = "/state";
        r2.services.base.lease_api = (void *)2;
        r2.module_dir = "/modules"; r2.module_names = names; r2.module_count = 1; r2.program_id = program;
        int rc=s2a_android_runtime_run_v2(&r2);
        printf("vk-direct-nvn: rc=%d expect=%d sdk_entries=%d\n",rc,S2A_RUNTIME_DIRECT,atomic_load(&sdk_calls)); fflush(stdout);
        assert(rc==S2A_RUNTIME_DIRECT);
        assert(atomic_load(&sdk_calls)==0);          // 起局前拒绝：没有任何 guest SDK 入口被执行
        assert(!s2a_android_host_try_enter_guest());
        printf("PASS vk-direct-nvn: rejected before relocation, no SDK entry\n");
        return 0;
    }
    if (!strcmp(argv[1],"latch")) {
        host_stop(); pending(); assert(!s2a_android_host_try_enter_guest());
    } else {
        admitted_first=!strcmp(argv[1],"admitted-first");
        pthread_t worker; assert(!__real_pthread_create(&worker,NULL,boot,NULL));
        pthread_mutex_lock(&lock);
        while (!created) pthread_cond_wait(&changed,&lock);
        if (admitted_first) {
            release_entry=1; pthread_cond_broadcast(&changed);
            while (!sdk_started) pthread_cond_wait(&changed,&lock);
        }
        pthread_mutex_unlock(&lock);
        if (!strcmp(argv[1],"runtime-stop")) assert(!s2a_android_runtime_request_stop(session));
        else host_stop();
        // HostApi 已接受停止，UI 尚未消费 eventfd；故意此时才放 guest 入口。
        pending();
        struct s2a_android_runtime_status s;
        assert(!s2a_android_runtime_status(session,&s));
        assert(s.state==S2A_RUNTIME_STOP_REQUESTED && s.last_phase==(admitted_first ? S2A_RUNTIME_GUEST_RUNNING : S2A_RUNTIME_SERVICES_READY));
        pthread_mutex_lock(&lock); release_entry=release_sdk=1; pthread_cond_broadcast(&changed); pthread_mutex_unlock(&lock);
        assert(!pthread_join(worker,NULL));
        printf("observed %s: result=%d sdk_entries=%d\n",argv[1],result,atomic_load(&sdk_calls)); fflush(stdout);
        assert(atomic_load(&sdk_calls)==admitted_first);
        assert(!s2a_android_runtime_status(session,&s) && s.state==S2A_RUNTIME_STOP_REQUESTED);
        assert(result==S2A_RUNTIME_STOP);
        assert(atomic_load(&stop_calls)==(!strcmp(argv[1],"runtime-stop")));
        assert(!s2a_android_host_try_enter_guest());
    }
    pending();
    uint32_t reason=99; char detail[256];
    assert(s2a_android_host_take_stop(&reason,detail,sizeof detail)==1);
    assert(reason==(!strcmp(argv[1],"runtime-stop") ? S2A_HOST_STOP_USER : S2A_HOST_STOP_DEVICE_LOST));
    assert(!s2a_android_host_take_stop(&reason,detail,sizeof detail));
    assert(s2a_android_host_stop_requested() && !s2a_android_host_try_enter_guest());
    printf("PASS %s: sdk_entries=%d; stop latched before UI take\n",argv[1],atomic_load(&sdk_calls));
    return 0;
}

#ifndef S2A_ENTRY_FIXTURE
int s2a_android_fault_thread_ready(void) { assert(!"unexpected Android thread gate"); return 0; }
int s2a_android_fault_probe(void) { assert(!"unexpected Android fault probe"); return -1; }
int s2a_track_runtime_ready(void) { assert(!"unexpected Android tracking gate"); return 0; }
int32_t s2a_android_services_attach_thread(uint64_t id, struct s2a_android_services_status *s) {
    (void)id; (void)s; assert(!"unexpected managed thread attach"); return -1;
}
#endif

// 本夹具只跑 v1 stop/admission；merged runtime 的 v2 入口不应被调用。
int s2a_android_services_start_v2(const struct s2a_android_services_request_v2 *r,
                                  struct s2a_android_services_status *s) {
    (void)r; (void)s; assert(!"unexpected v2 service start in stop-admission fixture"); return -1;
}

#ifndef S2A_SHUTDOWN_FIXTURE
int s2a_android_services_status(uint64_t id, struct s2a_android_services_status *s) {
    (void)id; (void)s; assert(!"unexpected cleanup query in sequence fixture"); return -1;
}
#endif
