// UIKit / GameController / BLE 事件写，现有 C# HID 泵读；锁内无分配、日志或设备访问。
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "s2a_pad.h"
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define PAD_EXPORT __attribute__((visibility("default"), used))
_Static_assert(sizeof(s2a_pad_snapshot) == 56, "C# snapshot ABI requires 56 bytes");

typedef struct { int connected; uint32_t buttons, latch; int32_t axes[4]; } pad_state;
static pthread_mutex_t pad_mu = PTHREAD_MUTEX_INITIALIZER;
static pad_state pads[S2A_PAD_COUNT];
static int active;
// 触屏接管（维护者 10-24：「按钮就切到手柄，触屏就切回虚拟按键」）：连着实体手柄时屏幕被碰 → 置位，选触屏；
//   实体手柄有按键 / 摇杆动作 → 清位，选回手柄。没有实体手柄时它不起作用
static int touch_override;
static uint64_t plus_seq; static int plus_down;   // 实体手柄「+」按下序号 / 现在是否按着（s2a_pad_plus_press）
static uint64_t notification_seq, input_epoch, pending_timestamp_us, committed_seq;
static s2a_pad_latency latency;
#ifdef __APPLE__
static pthread_cond_t pad_cv = PTHREAD_COND_INITIALIZER;
static void lock(void) { pthread_mutex_lock(&pad_mu); }
#else
static pthread_cond_t pad_cv;
static pthread_once_t pad_once = PTHREAD_ONCE_INIT;
static void init_cond(void) {
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr) || pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) ||
        pthread_cond_init(&pad_cv, &attr) || pthread_condattr_destroy(&attr)) abort();
}
static void lock(void) { if (pthread_once(&pad_once, init_cond)) abort(); pthread_mutex_lock(&pad_mu); }
#endif

PAD_EXPORT uint64_t s2a_pad_now_us(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time)) abort();
    return (uint64_t)time.tv_sec * 1000000 + (uint64_t)time.tv_nsec / 1000;
}
static void notify(int input_changed) {
    notification_seq++;
    if (input_changed && !pending_timestamp_us) pending_timestamp_us = s2a_pad_now_us();
    pthread_cond_broadcast(&pad_cv);
}

static s2a_pad_source selected(void) {
    if (touch_override) return S2A_PAD_TOUCH;
    if (pads[S2A_PAD_SYSTEM].connected) return S2A_PAD_SYSTEM;
    if (pads[S2A_PAD_BLE].connected) return S2A_PAD_BLE;
    return S2A_PAD_TOUCH;
}
void s2a_pad_update(s2a_pad_source source, int connected, uint32_t buttons, const int32_t axes[4]) {
    lock();
    if (!active || (source == S2A_PAD_TOUCH && selected() != S2A_PAD_TOUCH)) {
        pthread_mutex_unlock(&pad_mu); return;
    }
    s2a_pad_source previous = selected();
    pad_state before = pads[previous];
    pad_state *p = &pads[source];
    if (touch_override && source != S2A_PAD_TOUCH && connected && (buttons & 0xffffu || (axes && (axes[0] || axes[1] || axes[2] || axes[3]))))
        touch_override = 0;   // 实体手柄一动就切回手柄
    if (source != S2A_PAD_TOUCH) {   // 触屏的「+」是虚拟键，菜单本来就有四指长按入口
        // 「+」（bit10）或 Home（扩展位 bit16，NS2 手柄原样带、系统手柄由 ios/controller.m 补）按住都算开菜单的那一下（#276）
        int down = connected && (buttons & ((1u << 10) | (1u << 16)));
        if (down && !plus_down) plus_seq++;
        plus_down = down;
    }
    if (!connected) memset(p, 0, sizeof *p);
    else {
        // NS2 Home/Capture/C/GL/GR（16..20）不可误当成 Ryujinx 的摇杆方向位；SL / SR（Ryujinx 24..27，单只 Joy-Con 原始方向时 Mac 前端给，#520 A）放行
        buttons &= S2A_PAD_KEYS;
        p->latch |= buttons & ~p->buttons;
        p->buttons = buttons; p->connected = 1;
        memcpy(p->axes, axes, sizeof p->axes);
    }
    if (!pads[S2A_PAD_SYSTEM].connected && !pads[S2A_PAD_BLE].connected) touch_override = 0;
    s2a_pad_source next = selected();
    if (previous != next) {
        memset(&pads[S2A_PAD_TOUCH], 0, sizeof pads[S2A_PAD_TOUCH]);
        pads[next].latch = 0;
        input_epoch++;
        pending_timestamp_us = 0;
    }
    for (unsigned i = 0; i < S2A_PAD_COUNT; i++) if (i != next) pads[i].latch = 0;
    if (previous != next || before.buttons != pads[next].buttons ||
        memcmp(before.axes, pads[next].axes, sizeof before.axes)) notify(1);
    pthread_mutex_unlock(&pad_mu);
}
uint64_t s2a_pad_plus_press(void) {
    lock(); uint64_t r = plus_down ? plus_seq : 0;
    pthread_mutex_unlock(&pad_mu); return r;
}
int s2a_pad_prefer_touch(void) {
    lock();
    s2a_pad_source previous = selected();
    if (!active || previous == S2A_PAD_TOUCH) { pthread_mutex_unlock(&pad_mu); return 0; }
    touch_override = 1;
    for (unsigned i = 0; i < S2A_PAD_COUNT; i++) pads[i].latch = 0;
    memset(&pads[S2A_PAD_TOUCH], 0, sizeof pads[S2A_PAD_TOUCH]);
    input_epoch++; pending_timestamp_us = 0; notify(1);
    pthread_mutex_unlock(&pad_mu); return 1;
}
static void set_active_locked(int enabled) {
    if (active != !!enabled) {
        memset(pads, 0, sizeof pads); active = !!enabled; touch_override = 0;
        input_epoch++; pending_timestamp_us = 0; notify(1);
    }
}
void s2a_pad_set_active(int enabled) {
    lock(); set_active_locked(enabled);
    pthread_mutex_unlock(&pad_mu);
}
// 审计 P2-15：同一把锁里走一遍已有的「先停再开」，只在活跃时做，前后台状态不变
void s2a_pad_session_reset(void) {
    lock();
    if (active) { set_active_locked(0); set_active_locked(1); }
    pthread_mutex_unlock(&pad_mu);
}
int s2a_pad_has_controller(void) {
    lock(); int result = active && selected() != S2A_PAD_TOUCH;
    pthread_mutex_unlock(&pad_mu); return result;
}
uint32_t s2a_pad_read(int32_t axes[4], s2a_pad_source *source) {
    s2a_pad_snapshot snapshot;
    s2a_pad_read_ex(&snapshot);
    memcpy(axes, snapshot.axes, sizeof snapshot.axes);
    if (source) *source = (s2a_pad_source)snapshot.source;
    return snapshot.buttons;
}
PAD_EXPORT void s2a_pad_read_ex(s2a_pad_snapshot *out) {
    lock();
    s2a_pad_source current = selected();
    pad_state *p = &pads[current];
    *out = (s2a_pad_snapshot){notification_seq, input_epoch, pending_timestamp_us,
        s2a_pad_now_us(), p->buttons | p->latch, current, {0}};
    memcpy(out->axes, p->axes, sizeof p->axes);
    p->latch = 0; pending_timestamp_us = 0;
    pthread_mutex_unlock(&pad_mu);
}
PAD_EXPORT int s2a_pad_wait(uint64_t observed_seq, uint64_t deadline_us) {
    lock();
    while (notification_seq == observed_seq) {
        uint64_t now = s2a_pad_now_us();
        if (now >= deadline_us) break;
#ifdef __APPLE__
        uint64_t remaining = deadline_us - now;
        struct timespec timeout = {(time_t)(remaining / 1000000), (long)(remaining % 1000000) * 1000};
        int error = pthread_cond_timedwait_relative_np(&pad_cv, &pad_mu, &timeout);
#else
        struct timespec timeout = {(time_t)(deadline_us / 1000000), (long)(deadline_us % 1000000) * 1000};
        int error = pthread_cond_timedwait(&pad_cv, &pad_mu, &timeout);
#endif
        if (error && error != ETIMEDOUT) abort();
    }
    int changed = notification_seq != observed_seq;
    pthread_mutex_unlock(&pad_mu); return changed;
}
PAD_EXPORT void s2a_pad_wake(void) {
    lock(); notify(0); pthread_mutex_unlock(&pad_mu);
}
PAD_EXPORT void s2a_pad_record_commit(const s2a_pad_snapshot *snapshot) {
    uint64_t now = s2a_pad_now_us();
    lock();
    if (snapshot->input_epoch == input_epoch && snapshot->notification_seq != committed_seq &&
        snapshot->host_timestamp_us && snapshot->read_timestamp_us <= now) {
        uint64_t host = now - snapshot->host_timestamp_us, read = now - snapshot->read_timestamp_us;
        committed_seq = snapshot->notification_seq;
        latency.samples++; latency.host_total_us += host; latency.read_total_us += read;
        if (host > latency.host_max_us) latency.host_max_us = host;
        if (read > latency.read_max_us) latency.read_max_us = read;
    }
    pthread_mutex_unlock(&pad_mu);
}
PAD_EXPORT void s2a_pad_get_latency(s2a_pad_latency *out, int reset) {
    lock(); *out = latency;
    if (reset) memset(&latency, 0, sizeof latency);
    pthread_mutex_unlock(&pad_mu);
}
// HID 键盘区原始键态（R5，见 s2a_pad.h）：宿主前端全量替换、服务层每次 HID 提交读一次。
//   与手柄共用一把锁、一个通知序号：变化才换新并唤醒（notify(0) 不动延迟统计的时间戳），没映射进手柄按键的键也不等心跳
static uint64_t kb_keys[4]; static uint32_t kb_mods;
void s2a_kb_update(const uint64_t keys[4], uint32_t modifiers) {
    lock();
    if (memcmp(kb_keys, keys, sizeof kb_keys) || kb_mods != modifiers) {
        memcpy(kb_keys, keys, sizeof kb_keys); kb_mods = modifiers; notify(0);
    }
    pthread_mutex_unlock(&pad_mu);
}
PAD_EXPORT void s2a_kb_read(uint64_t keys_out[4], uint32_t *modifiers) {
    lock();
    memcpy(keys_out, kb_keys, sizeof kb_keys); *modifiers = kb_mods;
    pthread_mutex_unlock(&pad_mu);
}
// 手柄分类只认系统给的类别（productCategory 由苹果驱动按设备类型填，不是设备自报的名字）与手柄类型（宿主判 GCXboxGamepad / GCDualShockGamepad /
//   GCDualSenseGamepad）；不看 vendorName（审计 P2-213：第三方手柄名字里带「Pro Controller」被认成任天堂）
static int contains_nocase(const char *s, const char *word) {   // word 为小写 ASCII
    for (size_t n = strlen(word); *s; s++) if (!strncasecmp(s, word, n)) return 1;
    return 0;
}
int s2a_pad_kind(const char *category, int is_xbox, int is_playstation) {
    if (is_xbox) return S2A_PAD_KIND_XBOX;
    if (is_playstation) return S2A_PAD_KIND_PLAYSTATION;
    // 苹果给任天堂手柄的类别（macOS 26.4 系统库里实有「Switch Pro Controller」「Nintendo Switch Joy-Con (L/R)」等）；
    //   以后的型号（Switch 2 Pro、Joy-Con 2）字样未知，按片段不分大小写找，不只认开头（同 NX2Apple ShellInputs.swift ControllerFamily）。
    //   类别是系统驱动按设备类型填的，第三方手柄自报的名字在 vendorName，不在这里
    static const char *const nintendo[] = {"nintendo", "switch", "joy-con", "joycon"};
    for (size_t n = 0; category && n < sizeof nintendo / sizeof *nintendo; n++)
        if (contains_nocase(category, nintendo[n])) return S2A_PAD_KIND_NINTENDO;
    return S2A_PAD_KIND_OTHER;
}
// 按键布局（s2a_pad.h）。宿主起局按 S2A_PAD_FACE，游戏内菜单改了经 s2a_pad_layout_set 即时生效
static _Atomic int g_layout = -1;
int s2a_pad_layout_parse(const char *v) {
    if (v && (!strcmp(v, "switch") || !strcmp(v, "position"))) return S2A_PAD_LAYOUT_SWITCH;   // position：11-09 起的旧值「按位置」
    if (v && !strcmp(v, "xbox")) return S2A_PAD_LAYOUT_XBOX;
    return S2A_PAD_LAYOUT_AUTO;   // auto、旧值 letter（按字母）、空
}
int s2a_pad_layout(void) {
    int v = atomic_load(&g_layout);
    if (v < 0) { v = s2a_pad_layout_parse(getenv("S2A_PAD_FACE")); atomic_store(&g_layout, v); }
    return v;
}
void s2a_pad_layout_set(int layout) {
    atomic_store(&g_layout, layout == S2A_PAD_LAYOUT_SWITCH || layout == S2A_PAD_LAYOUT_XBOX ? layout : S2A_PAD_LAYOUT_AUTO);
}
void s2a_pad_abxy_order(int kind, int layout, int out[4]) {
    // 系统 buttonA/B/X/Y = 印 A/B/X/Y 的键：任天堂手柄在 东/南/北/西，其余（Xbox、MFi、PS 的 ×○□△、认不出的）在 南/东/西/北。
    //   自动 = 照字母（同 10-11「按键帽上印的字母」）；手动按物理位置：Switch 布局 A/B/X/Y = 东/南/北/西，Xbox 布局 = 南/东/西/北。
    //   所以「同字母」与「换一对」只看手柄是不是任天堂的那种排法：任天堂手柄选 Xbox 布局、其余手柄选 Switch 布局才换
    static const int swapped[4] = {1, 0, 3, 2}, letter[4] = {0, 1, 2, 3};
    int nintendo = kind == S2A_PAD_KIND_NINTENDO;
    int swap = layout == S2A_PAD_LAYOUT_SWITCH ? !nintendo : layout == S2A_PAD_LAYOUT_XBOX ? nintendo : 0;
    memcpy(out, swap ? swapped : letter, sizeof letter);
}
void s2a_pad_stick(float x, float y, int32_t axes[2]) {
    float radius = hypotf(x, y);
    if (!isfinite(radius) || radius <= .08f) { axes[0] = axes[1] = 0; return; }
    float scale = (fminf(radius, 1) - .08f) / (.92f * radius);
    axes[0] = (int32_t)lroundf(x * scale * 32767);
    axes[1] = (int32_t)lroundf(y * scale * 32767);
}
// 本地多手柄槽位计划（Mac macos/front_mac.m 与 iOS ios/controller.m 共用；纯逻辑，不持有对象：单测直接喂身份指针，不碰 GameController）。
//   prev 是上一轮的槽位身份（max 项，NULL = 空槽），live 是本次在线的手柄（顺序 = 连接顺序）。
//   slot_of[j] 写第 j 只该占的槽（-1 = 超过 max 只，不参与）；返回占用到的最高槽位 + 1（至少 1：槽 0 总留给键盘 / 鼠标）。
//   断开的手柄下一轮不在 live 里 → 槽空出来；重连时按「最小空槽」占回去（中间没插别的就回到原槽）。
int s2a_slot_plan(const void *const *prev, const void *const *live, int count, int max, int *slot_of) {
    for (int j = 0; j < count; j++) {
        slot_of[j] = -1;
        for (int i = 0; i < max; i++) if (prev[i] && prev[i] == live[j]) { slot_of[j] = i; break; }   // 还在原槽
    }
    for (int j = 0; j < count; j++) {
        if (slot_of[j] >= 0) continue;
        for (int i = 0; i < max; i++) {
            int taken = 0;
            for (int k = 0; k < count; k++) if (slot_of[k] == i) { taken = 1; break; }   // 本轮已被别人占
            if (taken) continue;
            if (prev[i]) {
                int still_alive = 0;
                for (int k = 0; k < count; k++) if (live[k] == prev[i]) { still_alive = 1; break; }
                if (still_alive) continue;   // 原占用者还在，别抢它的槽
            }
            slot_of[j] = i; break;
        }
    }
    int top = 1;
    for (int j = 0; j < count; j++) if (slot_of[j] + 1 > top) top = slot_of[j] + 1;
    return top;
}
