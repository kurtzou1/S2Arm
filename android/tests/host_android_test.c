#include "host_android.h"
#include "screen_metrics.h"
#include "input.h"
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

// 接口 v2.15 链接桩：宿主单测不链 runtime/src/os.c，必须以定义满足 host_android.c 的强引用；
// 此桩镜像其契约（-1 = 平台壳没设过）。验的是 set_console_mode 有没有转调 s2a_console_mode_set；
// os.c 与服务层这半由 LifecycleTest 覆盖。
static _Atomic int t_console_mode = -1;
void s2a_console_mode_set(int docked) { atomic_store(&t_console_mode, docked ? 1 : 0); }
int s2a_console_mode(void) { return atomic_load(&t_console_mode); }

static int failures;
static unsigned writer_epoch = 17;
unsigned s2a_android_guest_writers_epoch(void) { return writer_epoch; }
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static void retain(void *w) { (void)w; }
static void release(void *w) { (void)w; }
static const struct s2a_wsi_window_ops ops = {retain, release};

// A core thread asking the shell to end the session.
struct stop_call { const s2a_host_api_v1 *api; uint32_t reason; const char *detail; };
static void *stop_thread(void *p) {
    struct stop_call *c = p;
    c->api->stop->request_stop(c->api->host, c->reason, c->detail);
    return NULL;
}

int main(void) {
    struct s2a_android_host_config c = {"zh-Hans-CN", "", "Asia/Shanghai", 526, 527, 0};
    struct s2a_android_host_config bad = c;
    bad.region = "CHN";
    CHECK(s2a_android_host_register(&bad) == S2A_HOST_E_ARGUMENT);
    bad = c; bad.console_mode = 2;
    CHECK(s2a_android_host_register(&bad) == S2A_HOST_E_ARGUMENT);
    bad = c; bad.timezone = "";
    CHECK(s2a_android_host_register(&bad) == S2A_HOST_E_ARGUMENT);
    CHECK(s2a_android_host_register(NULL) == S2A_HOST_E_ARGUMENT && s2a_host_get() == NULL);
    uint32_t reason = 99;
    char detail[16];
    CHECK(s2a_android_host_stop_fd() < 0 && !s2a_android_host_take_stop(&reason, detail, sizeof detail));

    CHECK(s2a_android_host_register(&c) == S2A_HOST_E_OK);
    const s2a_host_api_v1 *api = s2a_host_get();
    CHECK(api && api->capabilities == (S2A_HOST_CAP_USER | S2A_HOST_CAP_MEMINFO | S2A_HOST_CAP_INPUT | S2A_HOST_CAP_DISPLAY
                                       | S2A_HOST_CAP_STOP));
    if (!api) return 1;
    CHECK(!api->ui && !api->decode && api->stop);

    // user: frozen at the first registration; a recreated Activity does not change it.
    struct s2a_android_host_config later = {"en-US", "US", "America/New_York", 1, 1, 1};
    CHECK(s2a_android_host_register(&later) == S2A_HOST_E_OK && s2a_host_get() == api);
    char buf[64];
    CHECK(api->user->language(api->host, buf, sizeof buf) == 0 && !strcmp(buf, "zh-Hans-CN"));
    CHECK(api->user->region(api->host, buf, sizeof buf) == 0 && !strcmp(buf, ""));
    CHECK(api->user->timezone(api->host, buf, sizeof buf) == 0 && !strcmp(buf, "Asia/Shanghai"));
    CHECK(api->user->timezone(api->host, buf, 13) == S2A_HOST_E_RANGE);   // no room for the NUL
    CHECK(api->user->language(api->host, NULL, 64) == S2A_HOST_E_ARGUMENT);

    // meminfo
    s2a_host_meminfo m = {.size = sizeof m};
    CHECK(api->meminfo->query(api->host, &m) == 0);
    CHECK(m.size == sizeof m && m.abi_version == S2A_HOST_API_ABI_VERSION);
    CHECK(m.total_bytes > 0 && m.available_bytes > 0 && m.available_bytes <= m.total_bytes);
    CHECK(m.process_rss_bytes > 0 && m.process_rss_bytes < m.total_bytes && m.gpu_bytes == 0);
    s2a_host_meminfo small = {.size = sizeof small - 8};
    CHECK(api->meminfo->query(api->host, &small) == S2A_HOST_E_RANGE);
    CHECK(api->meminfo->query(api->host, NULL) == S2A_HOST_E_ARGUMENT);

    // input: a caller with a longer (newer) struct gets the v1 prefix and its size back.
    struct { s2a_host_input_state v1; uint64_t newer; } in = {.v1 = {.size = sizeof in}, .newer = 7};
    const int32_t sticks[4] = {100, -200, 32767, -32768};
    s2a_android_input_set(0x15, sticks);
    CHECK(api->input->read(api->host, &in.v1) == 0);
    CHECK(in.v1.size == sizeof in.v1 && in.v1.buttons == 0x15 && in.v1.sticks[1] == -200 && in.v1.sticks[3] == -32768);
    CHECK(in.v1.timestamp_ns > 0 && in.newer == 7);
    uint64_t first_time = in.v1.timestamp_ns;
    s2a_android_input_reset();
    in.v1.size = sizeof in.v1;
    CHECK(api->input->read(api->host, &in.v1) == 0 && in.v1.buttons == 0 && in.v1.timestamp_ns >= first_time);

    // display: no lease yet -> zeros; then the lease's current revision; HOME keeps the last size.
    s2a_host_display_info d = {.size = sizeof d};
    CHECK(api->display->info(api->host, &d) == 0 && d.width == 0 && d.refresh_mhz == 0 && d.dpi_x == 526 && d.dpi_y == 527);
    int screen_w, screen_h;
    CHECK(!s2a_android_screen_metrics(&screen_w, &screen_h));
    s2a_wsi_lease *lease = s2a_wsi_create(1, &ops);
    int window;
    const int32_t insets[4] = {0};
    uint64_t changes = 99;
    CHECK(s2a_android_host_lifecycle(&changes) == -1);   // no lease registered yet
    s2a_android_host_set_lease(lease);
    s2a_wsi_set_foreground(lease, 1);
    CHECK(s2a_android_host_lifecycle(&changes) == 1 && changes == 1);   // the shell's lifecycle, no render thread involved
    uint64_t first=s2a_android_host_backing_progress(0,1), deadline;
    CHECK(first && s2a_android_host_backing_decision(first)==0);
    CHECK(!s2a_android_host_backing_progress(0,1));
    CHECK(s2a_android_host_backing_progress(first,1)==first);
    CHECK(s2a_android_host_backing_progress(first,0)==first);
    CHECK(s2a_android_host_backing_decision(first)==3);
    CHECK(s2a_android_host_backing_admission(writer_epoch,&deadline) && deadline>0);
    uint64_t next=s2a_android_host_backing_progress(0,1);
    CHECK(next && next!=first && !s2a_android_host_backing_progress(first,0));
    writer_epoch=19;
    CHECK(!s2a_android_host_backing_progress(next,1));
    CHECK(!s2a_android_host_backing_admission(writer_epoch,&deadline));
    uint64_t clock_owner=s2a_android_host_backing_progress(0,1);
    CHECK(clock_owner && s2a_android_host_backing_decision(next)==3);
    writer_epoch=0; CHECK(!s2a_android_host_backing_progress(0,1)); writer_epoch=19;
    s2a_wsi_offer(lease, &window);
    s2a_wsi_update(lease, 2712, 1220, 8, insets, 120.0f);   // ROTATE_270
    d.size = sizeof d;
    CHECK(api->display->info(api->host, &d) == 0 && d.width == 2712 && d.height == 1220 && d.rotation == 3 && d.refresh_mhz == 120000);
    CHECK(s2a_android_screen_metrics(&screen_w, &screen_h));
    CHECK(screen_w == 2400 && screen_h == 1080); // 2712 / 1220 → even normalized width
    s2a_wsi_update(lease, 1220, 2712, 1, insets, 59.94f);
    CHECK(s2a_android_screen_metrics(&screen_w, &screen_h) && screen_w == 2400 && screen_h == 1080);
    CHECK(api->display->info(api->host, &d) == 0 && d.width == 1220 && d.rotation == 0 && d.refresh_mhz == 59940);
    CHECK(s2a_wsi_revoke(lease, 1000) == 0);
    CHECK(api->display->info(api->host, &d) == 0 && d.width == 1220 && d.height == 2712);
    s2a_android_host_unset_lease((s2a_wsi_lease *)&window);   // not the current one: ignored
    CHECK(api->display->info(api->host, &d) == 0 && d.width == 1220);
    s2a_wsi_set_foreground(lease, 0);
    CHECK(s2a_android_host_lifecycle(&changes) == 0 && changes == 2);
    CHECK(s2a_android_host_backing_decision(clock_owner)==0);
    CHECK(s2a_android_host_backing_admission(writer_epoch,&deadline) && deadline==UINT64_MAX);
    s2a_wsi_set_foreground(lease,1);
    CHECK(s2a_android_host_backing_decision(clock_owner)==0);
    CHECK(s2a_android_host_backing_admission(writer_epoch,&deadline) && deadline<UINT64_MAX);
    CHECK(s2a_android_host_backing_progress(clock_owner,0)==clock_owner);
    CHECK(s2a_android_host_backing_decision(clock_owner)==3);
    CHECK(s2a_android_host_backing_admission(writer_epoch,&deadline));
    s2a_android_host_unset_lease(lease);
    CHECK(s2a_android_host_lifecycle(NULL) == -1);
    s2a_wsi_destroy(lease);
    CHECK(api->display->info(api->host, &d) == 0 && d.width == 0 && d.height == 0);

    // console mode: BootSpec's at first, then only set_console_mode.
    CHECK(s2a_android_host_console_mode() == 0);
    CHECK(api->display->set_console_mode(api->host, 2) == S2A_HOST_E_ARGUMENT && s2a_android_host_console_mode() == 0);
    CHECK(s2a_console_mode() == -1);   // 注册与无效值都不转给服务层（v2.15：运行时写者唯一）
    CHECK(api->display->set_console_mode(api->host, 1) == 0 && s2a_android_host_console_mode() == 1);
    CHECK(s2a_console_mode() == 1);   // 运行中切主机转给服务层（接口 v2.15；改前 -1）

    // 前后台冻结策略：退后台一律冻结（不看游戏的失焦暂停开关，#855）；停机已开始后迟到的 onPause 不再冻结，
    // 否则收尾线程等客机线程退出会卡到硬预算超时。
    CHECK(s2a_android_foreground_action(0, 0, 0) == S2A_ANDROID_FOREGROUND_FREEZE);   // 退后台一律冻（#855：游戏关了失焦暂停也冻）
    CHECK(s2a_android_foreground_action(0, 0, 1) == S2A_ANDROID_FOREGROUND_KEEP);
    CHECK(s2a_android_foreground_action(0, 1, 0) == S2A_ANDROID_FOREGROUND_KEEP);
    CHECK(s2a_android_foreground_action(0, 1, 1) == S2A_ANDROID_FOREGROUND_KEEP);
    CHECK(s2a_android_foreground_action(1, 0, 1) == S2A_ANDROID_FOREGROUND_UNFREEZE);
    CHECK(s2a_android_foreground_action(1, 0, 0) == S2A_ANDROID_FOREGROUND_KEEP);
    // 时序：onPause 冻结 → stopGame 放开 → 迟到的 onPause 不得再冻结。
    int frozen = 0, freezes = 0, unfreezes = 0, stop_started = 0;
    int action = s2a_android_foreground_action(0, stop_started, frozen);
    if (action == S2A_ANDROID_FOREGROUND_FREEZE) { frozen = 1; freezes++; }
    stop_started = 1;
    if (frozen) { frozen = 0; unfreezes++; }   // stopGame 的 foreground_unfreeze()
    action = s2a_android_foreground_action(0, stop_started, frozen);
    if (action == S2A_ANDROID_FOREGROUND_FREEZE) { frozen = 1; freezes++; }
    CHECK(freezes == 1 && unfreezes == 1 && !frozen);

    // stop: nothing pending; a core thread's request wakes the fd and is taken once; later ones are
    // ignored; the detail is cut at a UTF-8 boundary.
    int fd = s2a_android_host_stop_fd();
    struct pollfd pfd = {.fd = fd, .events = POLLIN};
    CHECK(fd >= 0 && poll(&pfd, 1, 0) == 0 && !s2a_android_host_take_stop(&reason, detail, sizeof detail));
    struct stop_call call = {api, S2A_HOST_STOP_DEVICE_LOST, "vkQueueSubmit: 设备丢失"};
    pthread_t t;
    pthread_create(&t, NULL, stop_thread, &call);
    CHECK(poll(&pfd, 1, 1000) == 1 && (pfd.revents & POLLIN));
    pthread_join(t, NULL);
    struct stop_call again = {api, S2A_HOST_STOP_ERROR, "later"};
    stop_thread(&again);
    CHECK(s2a_android_host_take_stop(&reason, detail, sizeof detail) == 1 && reason == S2A_HOST_STOP_DEVICE_LOST);
    CHECK(!strcmp(detail, "vkQueueSubmit: "));   // 16 bytes: "设" (3 bytes) does not fit whole
    CHECK(poll(&pfd, 1, 0) == 0 && !s2a_android_host_take_stop(&reason, detail, sizeof detail));
    stop_thread(&again);
    CHECK(poll(&pfd, 1, 0) == 0);

    if (failures) return 1;
    printf("android host api: user / meminfo (%llu MiB total, %llu MiB available, %llu MiB resident) / input / display / stop ok\n",
           (unsigned long long)(m.total_bytes >> 20), (unsigned long long)(m.available_bytes >> 20),
           (unsigned long long)(m.process_rss_bytes >> 20));
    return 0;
}
