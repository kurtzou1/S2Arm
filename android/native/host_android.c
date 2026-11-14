#include "host_android.h"
#include "host_ui_android.h"
#include "input.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <time.h>

// s2a_console_mode_set 在 runtime/src/os.c（接口 v2.15）；与同文件其它 os.c 符号一样强引用：
// 能链接通过就说明 os.c 在，没有「只缺这一个符号」的目标（宿主单测自带桩）。
extern void s2a_console_mode_set(int docked);

static struct android_host {
    char language[64], region[4], timezone[64];
    uint32_t dpi_x, dpi_y;
    _Atomic uint32_t console_mode;
    pthread_mutex_t lease_lock;   // display reads vs the lease going away
    s2a_wsi_lease *lease;
    int registered;
    pthread_mutex_t stop_lock;    // request_stop (any core thread) vs take (main thread)
    int stop_fd, stop_requested, stop_taken, guest_entered;
    uint32_t stop_reason;
    char stop_detail[256];
} g = {.lease_lock = PTHREAD_MUTEX_INITIALIZER, .stop_lock = PTHREAD_MUTEX_INITIALIZER, .stop_fd = -1};
static pthread_mutex_t register_lock = PTHREAD_MUTEX_INITIALIZER;

#define CHECK_OUT(out)                                         \
    do {                                                       \
        if (!(out)) return S2A_HOST_E_ARGUMENT;                \
        if ((out)->size < sizeof *(out)) return S2A_HOST_E_RANGE; \
    } while (0)

static int copy_out(const char *value, char *out, size_t cap) {
    size_t n = strlen(value) + 1;
    if (!out) return S2A_HOST_E_ARGUMENT;
    if (cap < n) return S2A_HOST_E_RANGE;
    memcpy(out, value, n);
    return S2A_HOST_E_OK;
}

static int user_language(void *host, char *out, size_t cap) { (void)host; return copy_out(g.language, out, cap); }
static int user_region(void *host, char *out, size_t cap) { (void)host; return copy_out(g.region, out, cap); }
static int user_timezone(void *host, char *out, size_t cap) { (void)host; return copy_out(g.timezone, out, cap); }

static void read_meminfo(uint64_t *total, uint64_t *available) {
    *total = *available = 0;
    FILE *f = fopen("/proc/meminfo", "re");
    if (!f) return;
    char line[128];
    unsigned long long kb;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "MemTotal: %llu kB", &kb) == 1) *total = kb * 1024;
        else if (sscanf(line, "MemAvailable: %llu kB", &kb) == 1) *available = kb * 1024;
    }
    fclose(f);
}

static uint64_t resident_bytes(void) {
    unsigned long long size, resident = 0;
    FILE *f = fopen("/proc/self/statm", "re");   // pages: size resident shared ...
    if (f) {
        if (fscanf(f, "%llu %llu", &size, &resident) != 2) resident = 0;
        fclose(f);
    }
    return resident * (uint64_t)sysconf(_SC_PAGESIZE);
}

static int meminfo_query(void *host, s2a_host_meminfo *out) {
    (void)host;
    CHECK_OUT(out);
    uint64_t total, available;
    read_meminfo(&total, &available);
    if (!total) return S2A_HOST_E_INTERNAL;
    *out = (s2a_host_meminfo){
        .size = sizeof *out, .abi_version = S2A_HOST_API_ABI_VERSION,
        .total_bytes = total, .available_bytes = available, .process_rss_bytes = resident_bytes(),
    };
    return S2A_HOST_E_OK;
}

static int input_read(void *host, s2a_host_input_state *out) {
    (void)host;
    CHECK_OUT(out);
    int32_t sticks[4];
    uint64_t ns;
    uint32_t buttons = s2a_android_input_read(sticks, &ns);
    *out = (s2a_host_input_state){
        .size = sizeof *out, .abi_version = S2A_HOST_API_ABI_VERSION,
        .buttons = buttons, .sticks = {sticks[0], sticks[1], sticks[2], sticks[3]}, .timestamp_ns = ns,
    };
    return S2A_HOST_E_OK;
}

// The lease keeps VK_SURFACE_TRANSFORM_{IDENTITY,ROTATE_90,180,270}_BIT_KHR (bits 0..3), made
// from Surface.ROTATION_0..3 by window.cpp's transform_of.
static uint32_t rotation_of(uint32_t transform) {
    for (uint32_t r = 0; r < 4; r++)
        if (transform == 1u << r) return r;
    return 0;
}

static int display_info(void *host, s2a_host_display_info *out) {
    (void)host;
    CHECK_OUT(out);
    struct s2a_wsi_state s = {0};
    pthread_mutex_lock(&g.lease_lock);
    if (g.lease) s2a_wsi_peek(g.lease, &s);
    pthread_mutex_unlock(&g.lease_lock);
    *out = (s2a_host_display_info){
        .size = sizeof *out, .abi_version = S2A_HOST_API_ABI_VERSION,
        .width = s.width > 0 ? (uint32_t)s.width : 0, .height = s.height > 0 ? (uint32_t)s.height : 0,
        .refresh_mhz = s.refresh_hz > 0 ? (uint32_t)(s.refresh_hz * 1000.0f + 0.5f) : 0,
        .rotation = rotation_of(s.transform), .dpi_x = g.dpi_x, .dpi_y = g.dpi_y,
    };
    return S2A_HOST_E_OK;
}

static int set_console_mode(void *host, uint32_t mode) {
    (void)host;
    if (mode > 1) return S2A_HOST_E_ARGUMENT;
    atomic_store(&g.console_mode, mode);
    // 接口 v2.15（缺口扫描族 2）：运行中切掌机 / 主机转给服务层——服务层每拍读 s2a_console_mode()，
    // 变了调 ChangeDockedModeState。宿主状态与服务层同时更新，运行时写者仍只有这一个。
    s2a_console_mode_set(mode);
    return S2A_HOST_E_OK;
}

// Copies at most n - 1 bytes of text, cut so that no UTF-8 sequence is split.
static void copy_utf8(char *out, size_t n, const char *text) {
    size_t len = strlen(text);
    if (len >= n) {
        len = n - 1;
        while (len && ((unsigned char)text[len] & 0xC0) == 0x80) len--;
    }
    memcpy(out, text, len);
    out[len] = 0;
}

static void request_stop(void *host, uint32_t reason, const char *detail) {
    (void)host;
    pthread_mutex_lock(&g.stop_lock);
    int first = !g.stop_requested;
    int startup = first && !g.guest_entered;
    if (first) {
        g.stop_requested = 1;
        g.stop_reason = reason;
        copy_utf8(g.stop_detail, sizeof g.stop_detail, detail ? detail : "");
    }
    pthread_mutex_unlock(&g.stop_lock);
    // The same stop lock excludes future guest admission. Only pre-guest startup may be
    // cancelled here; a running guest still requires the existing park/drain shutdown order.
    if (startup) {
        pthread_mutex_lock(&g.lease_lock);
        if (g.lease) s2a_wsi_stop(g.lease);
        pthread_mutex_unlock(&g.lease_lock);
    }
    if (first) s2a_android_ui_stop();
    uint64_t one = 1;
    if (first && write(g.stop_fd, &one, sizeof one) < 0) { /* EAGAIN: already readable */ }
}

#define TABLE(type) {.size = sizeof(type), .abi_version = S2A_HOST_API_ABI_VERSION}
static const s2a_host_user_v1 user_table = {TABLE(s2a_host_user_v1), user_language, user_region, user_timezone};
static const s2a_host_meminfo_v1 meminfo_table = {TABLE(s2a_host_meminfo_v1), meminfo_query};
static const s2a_host_input_v1 input_table = {TABLE(s2a_host_input_v1), input_read};
static const s2a_host_display_v1 display_table = {TABLE(s2a_host_display_v1), display_info, set_console_mode};
static const s2a_host_stop_v1 stop_table = {TABLE(s2a_host_stop_v1), request_stop};
static s2a_host_api_v1 api = {
    .hdr = TABLE(s2a_host_api_v1),
    .capabilities = S2A_HOST_CAP_USER | S2A_HOST_CAP_MEMINFO | S2A_HOST_CAP_INPUT | S2A_HOST_CAP_DISPLAY | S2A_HOST_CAP_STOP,
    .host = &g,
    .user = &user_table, .meminfo = &meminfo_table, .input = &input_table, .display = &display_table,
    .stop = &stop_table,
};

int s2a_android_host_register(const struct s2a_android_host_config *c) {
    if (!c || !c->language || !c->region || !c->timezone || !c->language[0] || !c->timezone[0]
        || (c->region[0] && strlen(c->region) != 2) || c->console_mode > 1) return S2A_HOST_E_ARGUMENT;
    if (strlen(c->language) >= sizeof g.language || strlen(c->timezone) >= sizeof g.timezone) return S2A_HOST_E_RANGE;
    pthread_mutex_lock(&register_lock);
    int rc = S2A_HOST_E_OK;
    if (!g.registered) {   // published by s2a_host_register (release store), read only after it
        api.ui = s2a_android_ui_table();
        if (api.ui) api.capabilities |= S2A_HOST_CAP_UI;
        strcpy(g.language, c->language);
        strcpy(g.region, c->region);
        strcpy(g.timezone, c->timezone);
        g.dpi_x = c->dpi_x;
        g.dpi_y = c->dpi_y;
        atomic_store(&g.console_mode, c->console_mode);
        if (g.stop_fd < 0) g.stop_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        rc = g.stop_fd < 0 ? S2A_HOST_E_INTERNAL : s2a_host_register(&api);
        g.registered = rc == S2A_HOST_E_OK;
    }
    pthread_mutex_unlock(&register_lock);
    return rc;
}

void s2a_android_host_set_lease(s2a_wsi_lease *lease) {
    pthread_mutex_lock(&g.lease_lock);
    g.lease = lease;
    pthread_mutex_unlock(&g.lease_lock);
}

void s2a_android_host_unset_lease(s2a_wsi_lease *lease) {
    pthread_mutex_lock(&g.lease_lock);
    if (g.lease == lease) g.lease = NULL;
    pthread_mutex_unlock(&g.lease_lock);
}

__attribute__((visibility("default"))) int s2a_android_host_lifecycle(uint64_t *changes) {
    pthread_mutex_lock(&g.lease_lock);
    int rc = g.lease ? s2a_wsi_lifecycle(g.lease, changes) : -1;
    pthread_mutex_unlock(&g.lease_lock);
    return rc;
}

// 拆线程（托管运行时设）：原生收局据此决定收局诊断的位置 / 是否限时（单线程保持基线顺序与行为）
static _Atomic int g_threaded;
__attribute__((visibility("default"))) void s2a_android_host_set_threaded(int on) { atomic_store(&g_threaded, on ? 1 : 0); }
int s2a_android_host_threaded(void) { return atomic_load(&g_threaded); }

// Only adapters: the lease serializes deadlines with the shell lifecycle writes.
__attribute__((weak)) unsigned s2a_android_guest_writers_epoch(void);
__attribute__((visibility("default"))) uint64_t s2a_android_host_backing_progress(uint64_t owner, int advance) {
    pthread_mutex_lock(&g.lease_lock);
    unsigned writer = s2a_android_guest_writers_epoch ? s2a_android_guest_writers_epoch() : 0;
    uint64_t result = g.lease ? s2a_wsi_backing_progress(g.lease, writer, owner, advance) : 0;
    pthread_mutex_unlock(&g.lease_lock);
    return result;
}
__attribute__((visibility("default"))) int s2a_android_host_backing_decision(uint64_t owner) {
    pthread_mutex_lock(&g.lease_lock);
    int result = g.lease ? s2a_wsi_backing_decision(g.lease, owner) : 3; // revoked
    pthread_mutex_unlock(&g.lease_lock);
    return result;
}
int s2a_android_host_backing_admission(unsigned writer, uint64_t *deadline) {
    pthread_mutex_lock(&g.lease_lock);
    int result = g.lease ? s2a_wsi_backing_admission(g.lease, writer, deadline) : 0;
    pthread_mutex_unlock(&g.lease_lock);
    return result;
}

uint32_t s2a_android_host_console_mode(void) { return atomic_load(&g.console_mode); }

int s2a_android_host_stop_fd(void) { return g.stop_fd; }

int s2a_android_host_stop_requested(void) {
    pthread_mutex_lock(&g.stop_lock);
    int requested = g.stop_requested;
    pthread_mutex_unlock(&g.stop_lock);
    return requested;
}

int s2a_android_host_try_enter_guest(void) {
    // 必须由当前进程实际注册的 Android HostApi 所有者接管停止与准入。
    if (s2a_host_get() != &api) return 0;
    pthread_mutex_lock(&g.stop_lock);
    int enter = !g.stop_requested && !g.guest_entered;
    if (enter) g.guest_entered = 1;
    pthread_mutex_unlock(&g.stop_lock);
    return enter;
}

int s2a_android_host_publish_running(int (*publish)(void)) {
    pthread_mutex_lock(&g.stop_lock);
    int rc = g.stop_requested ? 1 : publish();
    pthread_mutex_unlock(&g.stop_lock);
    return rc;
}

int s2a_android_host_take_stop(uint32_t *reason, char *detail, size_t n) {
    uint64_t count;
    if (g.stop_fd >= 0 && read(g.stop_fd, &count, sizeof count) < 0) { /* EAGAIN: nothing new */ }
    pthread_mutex_lock(&g.stop_lock);
    int take = g.stop_requested && !g.stop_taken;
    if (take) {
        g.stop_taken = 1;
        *reason = g.stop_reason;
        if (n) copy_utf8(detail, n, g.stop_detail);
    }
    pthread_mutex_unlock(&g.stop_lock);
    return take;
}
