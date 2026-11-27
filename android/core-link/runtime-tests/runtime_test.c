#include "oodle_fixture.h"
// 真实生产组合层与共享 guest 入口；core / SDK 端点明确使用合成夹具。
// 本 host 夹具不验证 guest 指令执行、VM、Android 信号或 GPU。
#include "runtime.h"
#include "guest_main.h"
#include "s2a_hostapi.h"
#include "direct/selection.h"
#include "direct/attempt.h"
#include "direct/graphics.h"
#include "direct_session.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Existing ordering cases exercise the generic mode; direct selection has its
// own real-Bionic fixture in runtime/direct-vk-tests/session_test.c.
// vk-prepare（#274）：手动 Vulkan 直连准备失败（如本包没有有效 direct-vulkan.txt）→ 报红一次、不装载模块。
static int is(const char *s);
int s2a_android_vk_session_prepare(const struct s2a_wsi_api *api, const char *game, const char *state) {
    (void)api; assert(game && state); return is("vk-prepare") ? EINVAL : 0;
}
int s2a_android_vk_skip_module(const char *name) { assert(name); return 0; }
void s2a_nro_table_load(const char *dir) { assert(dir); }
void s2a_caps_apply(const char *dir) { (void)dir; }
void s2a_game_defaults_apply(const char *dir, const char *caps) { (void)dir; (void)caps; }
void s2a_fps_start(const char *dir) { assert(dir); }

static const char *mode;
static char trace[2048];
static int service_calls, guest_calls, stop_calls, argc_calls, guest_entered;
static char g_v2_state[512];
static pthread_t boot_thread;
static const uint64_t session = 37, pid = 0x0100000000001234ull;
static void record(const char *s) { assert(strlen(trace)+strlen(s)+2 < sizeof trace); strcat(trace,s); strcat(trace," "); }
static int is(const char *s) { return !strcmp(mode,s); }
static void stop(void *host, uint32_t reason, const char *detail) {
    assert(host == &stop_calls && detail && (reason == S2A_HOST_STOP_ERROR || reason == S2A_HOST_STOP_USER)); stop_calls = 1;
}
static const s2a_host_stop_v1 stop_table = {{sizeof stop_table,S2A_HOST_API_ABI_VERSION},stop};
static const s2a_host_api_v1 host = {{sizeof host,S2A_HOST_API_ABI_VERSION},S2A_HOST_CAP_STOP,&stop_calls,NULL,NULL,NULL,NULL,NULL,NULL,&stop_table};
const s2a_host_api_v1 *s2a_host_get(void) { return &host; }
// 此夹具只验证组合顺序；真正的 HostApi 同锁并发由 stop_admission_test.c 验证。
int s2a_android_host_stop_requested(void) { return stop_calls; }
int s2a_android_host_try_enter_guest(void) { if (stop_calls || guest_entered) return 0; guest_entered = 1; return 1; }
int s2a_window_ok(void) { record("window"); return !is("window"); }
int s2a_selfcheck(void) { record("selfcheck"); return !is("selfcheck"); }
const char *s2a_selfcheck_hint(void) { return "fixture selfcheck rejection"; }
int s2a_android_guest_writers_init(void) { record("writers-init"); return is("writers-init"); }
int s2a_track_runtime_prepare(void) { record("track-prepare"); return is("track-prepare"); }
int s2a_android_tracking_vm_prepare(void) { record("vm-prepare"); return is("vm-prepare"); }
int s2a_android_runtime_signals_prepare(void) { record("signals"); return is("signals"); }
void s2a_crash_install(void) { record("crash"); }
void s2a_term_install(void) { record("term"); }
void s2a_det_init(void) { record("det"); }
void load_modules(const char *dir, const char **names, int n) {
    assert(!strcmp(dir,"/frozen/modules") && n == 2 && !strcmp(names[0],"main") && !strcmp(names[1],"sdk"));
    record("load"); if (is("stop-load")) assert(!s2a_android_runtime_request_stop(session));
}
void load_modules_from_source(const struct s2a_loader_source *source, const char **names, int count) {
    assert(is("source-ready") && source==(const struct s2a_loader_source *)0x789 && count==2 && !strcmp(names[0],"main"));
    record("load");
}
unsigned s2a_unresolved_count(void) { return is("unresolved"); }
uint64_t s2a_mem_init(const char *npdm) { assert(!strcmp(npdm,is("source-ready") ? "/verified/input/main.npdm" : "/frozen/modules/main.npdm")); record("memory"); return is("stack") ? 3 : 0x10000; }
uint64_t s2a_program_id(void) { return is("identity") ? pid+1 : pid; }
int s2a_android_services_start(const struct s2a_android_services_request *r, struct s2a_android_services_status *s) {
    assert(r->session_id==session && r->native_owner==(void *)0x123 && r->host_api==&host);
    assert((!strcmp(r->state_dir,"/persistent/session") ||
            (g_v2_state[0] && !strcmp(r->state_dir,g_v2_state))) && r->console_mode==1);
    service_calls++; record("services");
    *s=(struct s2a_android_services_status){sizeof *s,S2A_ANDROID_SERVICES_ABI,session,S2A_SERVICES_READY,0};
    if (is("service-fail")) { s->state=S2A_SERVICES_FAILED; s->error=S2A_SERVICES_INITIALIZE; return s->error; }
    if (is("false-ready")) s->state=S2A_SERVICES_STARTING;
    if (is("service-session")) s->session_id++;
    if (is("service-size")) s->size--;
    if (is("service-version")) s->version++;
    if (is("service-error")) s->error=S2A_SERVICES_GPU;
    if (is("stop-services")) assert(!s2a_android_runtime_request_stop(session));
    return 0;
}
int s2a_android_services_request_stop(uint64_t id, struct s2a_android_services_status *s) {
    assert(id==session); s->state=S2A_SERVICES_STOP_REQUESTED; record("services-stop"); return 0;
}
void sw_xstack_thread_init(uint64_t host_top, uint64_t guest_top) {
    assert(host_top && !(host_top&15) && guest_top==0x10000); record("xstack");
}
void s2a_det_set_ord(int n) { assert(n==0); record("ordinal"); }
void s2a_det_acquire(void) { record("acquire"); }
void sw_call_on_stack(void (*fn)(void), uint64_t sp) { assert(sp==0x10000); record("switch"); fn(); }
uint32_t s2a_thread_main_init(void) { record("thread"); return 71; }
void s2a_boot_mark(const char *s) { assert(s && *s); }
static void libc0(void) { record("libc0"); }
static void nnos(uint64_t handle,uint64_t zero) { assert(handle==71 && !zero); record("nnos"); }
static void libc1(void) { record("libc1"); }
static void sdk(void) { record("sdk"); }
static void startup(void) { record("startup"); }
static void libc2(void) { record("libc2"); }
void run_module_inits(void) { record("inits"); }
static void args_count(void *n) { assert((uintptr_t)n==2); argc_calls++; record("argc"); }
static void args_values(void *p) { char **v=p; assert(!strcmp(v[0],"one") && !strcmp(v[1],"two")); record("argv"); }
static void nnmain(void) {
    if (!is("args")) { assert(!pthread_equal(pthread_self(),boot_thread)); struct s2a_android_runtime_status s; assert(!s2a_android_runtime_status(session,&s) && s.state==S2A_RUNTIME_GUEST_RUNNING); }
    guest_calls++; record("nnMain");
}
void s2a_host_shutdown(const char *why) { assert(!strcmp(why,"nnMain 返回")); record("shutdown"); }
void *guest_sym(const char *name) {
    if (is("sdk-missing") && !strcmp(name,"nninitStartup")) return NULL;
    if (!strcmp(name,"_init_libc0")) return libc0;
    if (!strcmp(name,"nnosInitialize")) return nnos;
    if (!strcmp(name,"_init_libc1")) return libc1;
    if (!strcmp(name,"nninitInitializeSdkModule")) return sdk;
    if (!strcmp(name,"nninitStartup")) return startup;
    if (!strcmp(name,"_init_libc2")) return libc2;
    if (!strcmp(name,"nnMain")) return nnmain;
    if (!strcmp(name,"_ZN2nn2os11SetHostArgcEi")) return args_count;
    if (!strcmp(name,"_ZN2nn2os11SetHostArgvEPPc")) return args_values;
    assert(!"unexpected SDK symbol"); return NULL;
}
// ---------- C1：runtime v2 / 选择事务 ----------
static int g_provider_available, g_provider_prepares, g_frontend_ready, g_v2_services, g_v2_seen_direct;
static int32_t tp_activate(void *c) { (void)c; return 0; }
static int32_t tp_stop(void *c) { (void)c; return 0; }
static int32_t tp_query(void *c, s2a_direct_status_v1 *o) { (void)c; return s2a_direct_status_init(o); }
static int32_t tp_poll(void *c, uint32_t b) { (void)c; return b <= 10 ? 0 : -1; }
static int32_t tp_destroy(void *c) { (void)c; return 0; }
static int t_available(void) { return g_provider_available; }
// 描述文件 closure 校正：provider 看到的就是 runtime 校正后的描述。
static char g_seen_closure[128];
static int g_seen_profile_count = -1;
#ifndef S2A_TEST_NO_CLOSURE_STUB
// 桩：本引擎编译器的身份。默认与 build_descriptor 写的相同，v2-closure-stale 改成另一个。
static const char *g_engine_closure = "ryujinx-2026.10-dsh1";
int32_t s2a_direct_compiler_closure_v1(char *out, int32_t capacity) {
    const int32_t n = (int32_t)strlen(g_engine_closure);
    if (!out || capacity <= n) return 0;
    memcpy(out, g_engine_closure, (size_t)n + 1);
    return n;
}
#endif
static int32_t t_prepare(const struct s2a_graphics_descriptor_v1 *d, uint64_t sess, const char *state,
                         void *user, struct s2a_direct_api_v1 *table, char profile[72],
                         struct s2a_direct_counts *counts, char *why, size_t why_size) {
    (void)state; (void)user; (void)why; (void)why_size;
    g_provider_prepares++;
    snprintf(g_seen_closure, sizeof g_seen_closure, "%s", d->translator_closure);
    g_seen_profile_count = (int)d->profile_count;
    table->size = S2A_DIRECT_TABLE_SIZE;
    table->version = S2A_DIRECT_ABI;
    table->session = sess;
    table->context = table;
    table->activate = tp_activate; table->request_stop = tp_stop; table->query = tp_query;
    table->poll = tp_poll; table->destroy = tp_destroy;
    snprintf(profile, 72, "%s", d->profile_hashes[0]);
    counts->devices = counts->queues = counts->workers = counts->consumers = 1;
    return 0;
}
static const struct s2a_direct_provider t_provider = { "host-fixture", t_available, t_prepare, NULL };
const struct s2a_direct_provider *s2a_direct_provider_default(void) { return &t_provider; }
int s2a_direct_frontend_ready(void) { return g_frontend_ready; }
int s2a_android_services_start_v2(const struct s2a_android_services_request_v2 *r,
                                  struct s2a_android_services_status *s) {
    assert(r->base.version == S2A_ANDROID_SERVICES_ABI_V2 && r->flags == 0);
    g_v2_services++;
    if (g_v2_seen_direct) {
        assert(r->graphics && r->graphics_mode == S2A_GRAPHICS_DIRECT && r->graphics->session == session);
    } else {
        assert(!r->graphics && r->graphics_mode == S2A_GRAPHICS_GENERIC);
    }
    return s2a_android_services_start(&r->base, s);
}
static char descriptor_json[2048];
static size_t descriptor_bytes;
static void build_descriptor(void) {
    char hash[65]; memset(hash, 'a', 64); hash[64] = 0;
    snprintf(descriptor_json, sizeof descriptor_json,
        "{\"schema\":\"s2a-graphics-v1\",\"titleId\":\"0100000000001234\","
        "\"gameContentRoot\":\"sha256-%s\",\"moduleSetDigest\":\"sha256-%s\","
        "\"frontend\":\"nvn\",\"backend\":\"vulkan-direct\",\"directABI\":1,"
        "\"translatorClosure\":\"ryujinx-2026.10-dsh1\",\"sourceParserVersion\":1,"
        "\"profiles\":[{\"profileHash\":\"sha256-%s\"}],\"files\":[],"
        "\"runtimeCompilerABI\":\"s2a-direct-compile-v1\"}", hash, hash, hash);
    descriptor_bytes = strlen(descriptor_json);
}

int main(int argc,char **argv) {
    assert(argc==2); mode=argv[1]; boot_thread=pthread_self();
    const char *test_tmp = getenv("S2A_TEST_TMP");
    if (!test_tmp || !*test_tmp) test_tmp = getenv("TMPDIR");
    snprintf(g_v2_state, sizeof g_v2_state, "%s/s2a-runtime-v2-XXXXXX", test_tmp && *test_tmp ? test_tmp : "/tmp");
    assert(mkdtemp(g_v2_state) != NULL);
    if (is("args")) {
        char *v[]={"one","two"}; struct s2a_guest_main_args args={0x10000,2,v}; s2a_guest_main(&args);
        assert(argc_calls==1 && guest_calls==1);
        assert(!strcmp(trace,"xstack ordinal acquire switch thread libc0 nnos libc1 sdk startup libc2 inits argc argv nnMain shutdown "));
    } else if (!strncmp(mode, "v2-", 3)) {
        const char *names[]={"main","sdk"};
        struct s2a_android_runtime_request r={
            .services={sizeof r.services,S2A_ANDROID_SERVICES_ABI,session,(void *)0x123,&host,"/frozen/game",g_v2_state,(void *)0x456,1,0},
            .module_dir="/frozen/modules",.module_names=names,.module_count=2,.program_id=pid};
        build_descriptor();
        struct s2a_android_runtime_request_v2 r2;
        memset(&r2, 0, sizeof r2);
        r2.size = sizeof r2;
        r2.version = S2A_ANDROID_RUNTIME_ABI_V2;
        r2.mode_preference = S2A_DIRECT_MODE_AUTO;
        r2.services.base = r.services;
        r2.services.base.version = S2A_ANDROID_SERVICES_ABI_V2;
        r2.services.base.size = S2A_ANDROID_SERVICES_REQUEST_V2_SIZE;
        r2.module_dir = r.module_dir; r2.module_names = r.module_names; r2.module_count = r.module_count;
        r2.program_id = r.program_id;

        int expect_generic = 1, expect_frontend_fail = 0, expect_invalid = 0, expect_manual_direct_fail = 0;
        struct s2a_graphics_descriptor_v1 parsed;
        char why[128];
        assert(!s2a_graphics_descriptor_parse((const uint8_t *)descriptor_json, descriptor_bytes, &parsed, why, sizeof why));
        char key[65];
        assert(!s2a_direct_implementation_key(&parsed, parsed.profile_hashes[0], key, why, sizeof why));

        if (is("v2-generic")) {
            // AUTO + 无描述：不大意创建 provider。
        } else if (is("v2-direct") || is("v2-direct-manual") || is("v2-leftover") ||
                   is("v2-closure-stale") || is("v2-closure-same") || is("v2-closure-nostub")) {
#ifndef S2A_TEST_NO_CLOSURE_STUB
            if (is("v2-closure-stale")) g_engine_closure = "s2a-dc1-engine-new";
#endif
            g_provider_available = 1;
            g_frontend_ready = 1;
            g_v2_seen_direct = 1;
            expect_generic = 0;
            r2.graphics.json = (const uint8_t *)descriptor_json;
            r2.graphics.bytes = descriptor_bytes;
            if (is("v2-direct-manual")) r2.mode_preference = S2A_DIRECT_MODE_DIRECT;
            if (is("v2-leftover")) {
                struct s2a_direct_attempt_v1 at;
                memset(&at, 0, sizeof at);
                memcpy(at.attempt_id, "0123456789abcdef0123456789abcdef", 32);
                memcpy(at.implementation_key, key, 64);
                at.session = session; at.phase = S2A_ATTEMPT_PREPARED;
                snprintf(at.reason, sizeof at.reason, "leftover from a killed direct run");
                assert(s2a_direct_attempt_write(g_v2_state, &at) == S2A_ATTEMPT_OK);
                expect_generic = 1;
                g_v2_seen_direct = 0;
                g_frontend_ready = 0;
            }
        } else if (is("v2-frontend-missing")) {
            g_provider_available = 1;
            expect_frontend_fail = 1;
            expect_generic = 0;
            r2.graphics.json = (const uint8_t *)descriptor_json;
            r2.graphics.bytes = descriptor_bytes;
        } else if (is("v2-manual-direct-no-descriptor")) {
            expect_manual_direct_fail = 1;
            expect_generic = 0;
            r2.mode_preference = S2A_DIRECT_MODE_DIRECT;
        } else if (is("v2-bad-descriptor")) {
            g_provider_available = 1;
            r2.graphics.json = (const uint8_t *)"{bad";
            r2.graphics.bytes = 4;
        } else if (is("v2-manual-bad-descriptor")) {
            expect_manual_direct_fail = 1;
            expect_generic = 0;
            r2.mode_preference = S2A_DIRECT_MODE_DIRECT;
            r2.graphics.json = (const uint8_t *)"{bad";
            r2.graphics.bytes = 4;
        } else if (is("v2-title-mismatch") || is("v2-manual-title-mismatch")) {
            g_provider_available = 1;
            g_frontend_ready = 1;
            static char wrong_title[2048];
            memcpy(wrong_title, descriptor_json, descriptor_bytes + 1);
            char *title = strstr(wrong_title, "\"titleId\":\"");
            assert(title && title[11] == '0');
            title[11] = '1';
            r2.graphics.json = (const uint8_t *)wrong_title;
            r2.graphics.bytes = descriptor_bytes;
            if (is("v2-manual-title-mismatch")) {
                expect_manual_direct_fail = 1;
                expect_generic = 0;
                r2.mode_preference = S2A_DIRECT_MODE_DIRECT;
            }
        } else if (is("v2-invalid")) {
            expect_invalid = 1;
        } else assert(!"unknown v2 mode");

        if (expect_invalid) {
            struct s2a_android_runtime_request_v2 bad = r2;
            bad.size = 8; assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            bad = r2; bad.version = 1; assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            bad = r2; bad.mode_preference = 3; assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            bad = r2; bad.services.graphics = (const s2a_direct_api_v1 *)&bad;
            assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            bad = r2; bad.services.flags = 1; assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            bad = r2; bad.services.graphics_mode = 1; assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            bad = r2; bad.graphics.bytes = 4; assert(s2a_android_runtime_run_v2(&bad) == S2A_RUNTIME_ARGUMENT);
            assert(!*trace && !stop_calls && !g_v2_services);
            printf("PASS %s: %s\n", mode, trace); return 0;
        }

        int rc = s2a_android_runtime_run_v2(&r2);
        if (expect_manual_direct_fail) {
            assert(rc == S2A_RUNTIME_DIRECT && !strstr(trace, "load") && !guest_calls && !g_v2_services);
            // 坏描述在进入会话前就被拒：不创建 device、不写 attempt、不需要停止回调。
            if (is("v2-manual-bad-descriptor") || is("v2-manual-title-mismatch")) assert(!stop_calls && !*trace);
            else assert(stop_calls);
        } else if (expect_frontend_fail) {
            assert(rc == S2A_RUNTIME_DIRECT && stop_calls && !strstr(trace, "load") && !guest_calls && !g_v2_services);
            const struct s2a_direct_selection *sel = s2a_direct_selection_current();
            assert(sel && sel->decision == S2A_DIRECT_DECISION_DIRECT && g_provider_prepares == 1);
            assert(s2a_direct_attempt_pending(g_v2_state, key));
        } else {
            assert(rc == S2A_RUNTIME_RETURNED && guest_calls == 1 && g_v2_services == 1);
            const struct s2a_direct_selection *sel = s2a_direct_selection_current();
            assert(sel);
            if (expect_generic) {
                assert(sel->decision == S2A_DIRECT_DECISION_GENERIC && g_provider_prepares == 0);
            } else {
                assert(sel->decision == S2A_DIRECT_DECISION_DIRECT && g_provider_prepares == 1);
                assert(sel->counts.devices == 1 && sel->counts.queues == 1 && sel->counts.workers == 1);
                // 期望值手写。过期：用引擎身份并丢弃离线库。相同或没有桩：描述原样不动。
                // 【红】那一行由 run.py 在 stderr 里核对。
                if (is("v2-closure-stale")) assert(!strcmp(g_seen_closure, "s2a-dc1-engine-new") && g_seen_profile_count == 0);
                if (is("v2-closure-same") || is("v2-closure-nostub"))
                    assert(!strcmp(g_seen_closure, "ryujinx-2026.10-dsh1") && g_seen_profile_count == 1);
                // 正常收局必须清掉 attempt 锁（方案 §10：正常 Stop 才可清，异常清理不能清）。
                // `63ec50c7` 把清理移到 guest join 之后、shutdown 收尾之前；返回时锁已经不在了。
                // 这里同时验证“已经清过再清一次”是幂等的，不把正常收局误报成遗留锁。
                assert(!s2a_direct_attempt_pending(g_v2_state, key));
                assert(s2a_direct_attempt_clear(g_v2_state, key) == S2A_ATTEMPT_OK);
            }
        }
    } else {
        const char *names[]={"main","sdk"};
        struct s2a_android_runtime_request r={
            .services={sizeof r.services,S2A_ANDROID_SERVICES_ABI,session,(void *)0x123,&host,"/frozen/game","/persistent/session",(void *)0x456,1,0},
            .module_dir="/frozen/modules",.module_names=names,.module_count=2,.program_id=pid};
        if (is("invalid")) r.module_count=17;
        if (is("source-ready") || is("source-no-npdm") || is("source-relative-npdm")) {
            r.module_dir=NULL; r.module_source=(const struct s2a_loader_source *)0x789;
            r.npdm_path=is("source-no-npdm") ? NULL : is("source-relative-npdm") ? "relative/main.npdm" : "/verified/input/main.npdm";
        }
        char long_path[1024]; memset(long_path,'x',sizeof long_path); long_path[0]='/'; long_path[sizeof long_path-1]=0;
        if (is("long-path")) r.module_dir=long_path;
        int rc=s2a_android_runtime_run(&r);
        if (is("invalid") || is("long-path") || is("source-no-npdm") || is("source-relative-npdm")) { assert(rc==S2A_RUNTIME_ARGUMENT && !*trace && !stop_calls); }
        else {
            struct s2a_android_runtime_status s; assert(!s2a_android_runtime_status(session,&s) && s.error==rc);
            uint32_t expected_phase = guest_calls ? S2A_RUNTIME_GUEST_RUNNING : is("stop-services") ? S2A_RUNTIME_SERVICES_READY :
                (strstr(trace,"writers-init") ? S2A_RUNTIME_MEMORY_READY : S2A_RUNTIME_LOADING);
            assert(s.last_phase==expected_phase); // Failed/StopRequested也必须保留实际进度。
            assert(s2a_android_runtime_status(session+1,&s)==S2A_RUNTIME_ARGUMENT);
            assert(s2a_android_runtime_run(&r)==S2A_RUNTIME_ALREADY_USED && stop_calls==1);
            if (is("ready") || is("source-ready")) {
                assert(rc==S2A_RUNTIME_RETURNED && service_calls==1 && guest_calls==1 && !argc_calls);
                #ifdef S2A_ENTRY_FIXTURE
                assert(!strcmp(trace,"window selfcheck signals crash term det load memory writers-init track-prepare vm-prepare services thread xstack ordinal acquire switch libc0 nnos libc1 sdk startup libc2 inits nnMain shutdown "));
#else
                assert(!strcmp(trace,"window selfcheck signals crash term det load memory writers-init track-prepare vm-prepare services xstack ordinal acquire switch thread libc0 nnos libc1 sdk startup libc2 inits nnMain shutdown "));
#endif
            } else {
                assert(!guest_calls && !strstr(trace,"xstack") && !argc_calls);
                if (is("window")) assert(rc==S2A_RUNTIME_WINDOW && !service_calls && !strstr(trace,"load"));
                else if (is("selfcheck")) assert(rc==S2A_RUNTIME_SELFCHECK && !service_calls && !strstr(trace,"load"));
                else if (is("writers-init") || is("track-prepare") || is("vm-prepare")) assert(rc==S2A_RUNTIME_TRACKING && !service_calls);
                else if (is("signals")) assert(rc==S2A_RUNTIME_SIGNALS && !service_calls && !strstr(trace,"load"));
                else if (is("unresolved")) assert(rc==S2A_RUNTIME_IMPORT && !service_calls && !strstr(trace,"memory"));
                else if (is("stack") || is("identity")) assert(rc==S2A_RUNTIME_MEMORY && !service_calls);
                else if (is("sdk-missing")) assert(rc==S2A_RUNTIME_SDK && !service_calls);
                else if (is("stop-load") || is("stop-services")) assert(rc==S2A_RUNTIME_STOP && s.state==S2A_RUNTIME_STOP_REQUESTED);
                else if (is("vk-prepare")) assert(rc==S2A_RUNTIME_SERVICES && s.state==S2A_RUNTIME_FAILED && s.services_error==EINVAL &&
                                                  !service_calls && !strstr(trace,"load"));
                else assert(rc==S2A_RUNTIME_SERVICES && service_calls==1);
            }
        }
    }
    printf("PASS %s: %s\n",mode,trace); return 0;
}

#if defined(__ANDROID__) && !defined(S2A_ENTRY_FIXTURE)
// 独立 ARM64 探针不是应用进程：不建立 session 私有日志，也不接真实线程/fault 后端
// （那些由应用内钳制与 C4 专测负责）。
int s2a_android_session_log_start(const char *state_dir, uint64_t session) {
    (void)state_dir; (void)session; return 0;
}
uint32_t s2a_thread_current(void) { return 71; }
int s2a_android_fault_thread_init(void) { return 0; }
#endif

#if defined(__ANDROID__) && !defined(S2A_ENTRY_FIXTURE)
// 独立 ARM64 探针：线程门与 attach 用明确夹具，不冒充真实 fault/VM。
int s2a_android_fault_thread_ready(void) { record("thread-gate"); return 1; }
int s2a_android_fault_probe(void) { record("fault-probe"); return 0; }
int s2a_track_runtime_ready(void) { record("track-ready"); return 1; }
int32_t s2a_android_services_attach_thread(uint64_t id, struct s2a_android_services_status *s) {
    assert(id == session);
    *s = (struct s2a_android_services_status){sizeof *s, S2A_ANDROID_SERVICES_ABI, id, S2A_SERVICES_READY, 0};
    record("attach");
    return 0;
}
#elif !defined(S2A_ENTRY_FIXTURE)
int s2a_android_fault_thread_ready(void) { assert(!"unexpected Android thread gate"); return 0; }
int s2a_android_fault_probe(void) { assert(!"unexpected Android fault probe"); return -1; }
int s2a_track_runtime_ready(void) { assert(!"unexpected Android tracking gate"); return 0; }
int32_t s2a_android_services_attach_thread(uint64_t id, struct s2a_android_services_status *s) {
    (void)id; (void)s; assert(!"unexpected managed thread attach"); return -1;
}
#endif

#ifndef S2A_SHUTDOWN_FIXTURE
int s2a_android_services_status(uint64_t id, struct s2a_android_services_status *s) {
    (void)id; (void)s; assert(!"unexpected cleanup query in sequence fixture"); return -1;
}
#endif
