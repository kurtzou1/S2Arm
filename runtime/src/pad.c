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
// 系统手柄列表里的这只是不是 NS2 手柄（s2a_pad.h s2a_pad_is_ns2）：同 s2a_pad_kind 只看系统填的类别。
//   苹果给 NS2 手柄的类别字样未知（11-13 还没实机看到），按二代型号字样的片段找（下表）；认不出就当别的手柄照读（宁可多一位玩家，不丢手柄）
int s2a_pad_is_ns2(const char *category) {
    static const char *const ns2[] = {"switch 2", "joy-con 2", "joycon 2"};
    for (size_t n = 0; category && n < sizeof ns2 / sizeof *ns2; n++)
        if (contains_nocase(category, ns2[n])) return 1;
    return 0;
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
static int order_match(const s2a_pad_order_entry *e, int ns2_player, const char *name, int index) {
    if (ns2_player == S2A_PAD_ORDER_GEN1 || ns2_player == S2A_PAD_ORDER_GEN1_PAIR)   // 一代单只 / 按设备的一对：照设备 id 比
        return e->ns2_player == ns2_player && name && !strcmp(e->name, name);
    if (ns2_player != -1) return e->ns2_player == ns2_player;   // 通道玩家号、键盘：照号比
    return e->ns2_player == -1 && e->index == index && name && !strcmp(e->name, name);   // 系统手柄：-1（键盘是 -2，不能混）
}
int s2a_pad_order_rank(const s2a_pad_order *order, int ns2_player, const char *name, int index) {
    if (!order) return S2A_PAD_ORDER_UNLISTED;
    for (int i = 0; i < order->count && i < S2A_PAD_ORDER_MAX; i++) if (order_match(&order->entry[i], ns2_player, name, index)) return i;
    for (int i = 0; i < order->dropped_count && i < S2A_PAD_ORDER_MAX; i++) if (order_match(&order->dropped[i], ns2_player, name, index)) return S2A_PAD_ORDER_DROPPED;
    return S2A_PAD_ORDER_UNLISTED;
}
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

static uint8_t jc1_amp(float amp) {
    if (!(amp > 0)) return 0;
    if (amp > 1) amp = 1;
    float e = amp > 0.23f ? log2f(amp * 8.7f) * 32.f : amp > 0.12f ? log2f(amp * 17.f) * 16.f : ((log2f(amp) * 32.f) - 96.f) / (4.f - 2.f * amp);
    return e < 0 ? 0 : e > 100 ? 100 : (uint8_t)lroundf(e);
}
void s2a_joycon1_rumble_encode(s2a_pad_vibration v, uint8_t out[4]) {
    float hi_hz = v.high_hz > 81.75f ? (v.high_hz < 1252.f ? v.high_hz : 1252.f) : 320.f, lo_hz = v.low_hz > 40.875f ? (v.low_hz < 626.f ? v.low_hz : 626.f) : 160.f;
    if (!(v.high_hz > 0)) hi_hz = 320.f;
    if (!(v.low_hz > 0)) lo_hz = 160.f;
    uint16_t hf = (uint16_t)((lroundf(log2f(hi_hz / 10.f) * 32.f) - 0x60) * 4);
    uint8_t lf = (uint8_t)(lroundf(log2f(lo_hz / 10.f) * 32.f) - 0x40);
    uint8_t hf_amp = (uint8_t)(jc1_amp(v.high_amp) * 2);
    uint16_t lf_amp = (uint16_t)(jc1_amp(v.low_amp) / 2 + 64);
    out[0] = (uint8_t)(hf & 0xff);
    out[1] = (uint8_t)(hf_amp + ((hf >> 8) & 0xff));
    out[2] = (uint8_t)(lf + ((lf_amp >> 8) & 0xff));
    out[3] = (uint8_t)(lf_amp & 0xff);
}

// 一代 Joy-Con / Pro HID 报告解析（s2a_pad.h s2a_joycon1_decode；按键对应照 #592 decode_pad，Co-authored-by lucaAce1024）
enum { JC1_E = 1u << 0, JC1_S = 1u << 1, JC1_N = 1u << 2, JC1_W = 1u << 3, JC1_LS = 1u << 4, JC1_RS = 1u << 5, JC1_L = 1u << 6, JC1_R = 1u << 7,
       JC1_ZL = 1u << 8, JC1_ZR = 1u << 9, JC1_PLUS = 1u << 10, JC1_MINUS = 1u << 11, JC1_DL = 1u << 12, JC1_DU = 1u << 13, JC1_DR = 1u << 14, JC1_DD = 1u << 15 };
static int32_t jc1_axis(unsigned raw) { int v = ((int)raw - 2048) * 16; return v > 32767 ? 32767 : v < -32767 ? -32767 : v; }
int s2a_joycon1_decode(int pid, const uint8_t *report, size_t length, uint32_t *buttons, int32_t sticks[4], int *side) {
    if (!report || !buttons || !sticks || !side) return 0;
    *buttons = 0; *side = 0; for (int i = 0; i < 4; i++) sticks[i] = 0;
    size_t off = length && (report[0] == 0x30 || report[0] == 0x3f) ? 1 : 0;   // IOHID 有时把报告号放在第一个字节
    int full = off ? report[0] == 0x30 : length >= 48;
    if (!full) {   // 简单报告 0x3F：byte1 = 四个方向 / 面键 + SL（bit4）SR（bit5），byte2 = − + LS RS Home Capture L/R ZL/ZR；摇杆是八方向帽，不读
        if (length < off + 2) return 0;
        uint8_t b1 = report[off], b2 = report[off + 1];
        uint32_t out = 0;
        if (pid == 0x2006) { if (b1 & 0x01) out |= JC1_E; if (b1 & 0x02) out |= JC1_N; if (b1 & 0x04) out |= JC1_S; if (b1 & 0x08) out |= JC1_W; }   // 横握：下 A、右 X、左 B、上 Y
        else { if (b1 & 0x01) out |= JC1_E; if (b1 & 0x02) out |= JC1_N; if (b1 & 0x04) out |= JC1_S; if (b1 & 0x08) out |= JC1_W; }
        if (b1 & 0x10) { out |= JC1_L; *side |= S2A_JC1_SIDE_SL; }
        if (b1 & 0x20) { out |= JC1_R; *side |= S2A_JC1_SIDE_SR; }
        if (b2 & 0x01) out |= JC1_MINUS;
        if (b2 & 0x02) out |= JC1_PLUS;
        if (b2 & 0x04) out |= JC1_LS;
        if (b2 & 0x08) out |= JC1_RS;
        if (b2 & 0x40) { out |= pid == 0x2007 ? JC1_R : JC1_L; *side |= S2A_JC1_SIDE_SHOULDER; }
        if (b2 & 0x80) out |= pid == 0x2007 ? JC1_ZR : JC1_ZL;
        *buttons = out;
        return 1;
    }
    if (length < off + 11) return 0;
    const uint8_t *b = report + off + 2, *ls = report + off + 5, *rs = report + off + 8;   // timer、电量之后：按键 3 字节、左右摇杆各 3 字节
    unsigned lx = ls[0] | (ls[1] & 0x0f) << 8, ly = ls[1] >> 4 | ls[2] << 4, rx = rs[0] | (rs[1] & 0x0f) << 8, ry = rs[1] >> 4 | rs[2] << 4;
    uint32_t out = 0;
    if (pid == 0x2009) {
        if (b[0] & 0x01) out |= JC1_W; if (b[0] & 0x02) out |= JC1_N; if (b[0] & 0x04) out |= JC1_S; if (b[0] & 0x08) out |= JC1_E;
        if (b[0] & 0x40) out |= JC1_R; if (b[0] & 0x80) out |= JC1_ZR;
        if (b[1] & 0x01) out |= JC1_MINUS; if (b[1] & 0x02) out |= JC1_PLUS; if (b[1] & 0x04) out |= JC1_RS; if (b[1] & 0x08) out |= JC1_LS;
        if (b[2] & 0x01) out |= JC1_DD; if (b[2] & 0x02) out |= JC1_DU; if (b[2] & 0x04) out |= JC1_DR; if (b[2] & 0x08) out |= JC1_DL;
        if (b[2] & 0x40) out |= JC1_L; if (b[2] & 0x80) out |= JC1_ZL;
        if ((b[0] & 0x40) && (b[2] & 0x40)) *side |= S2A_JC1_SIDE_SHOULDER;
        sticks[0] = jc1_axis(lx); sticks[1] = jc1_axis(ly); sticks[2] = jc1_axis(rx); sticks[3] = jc1_axis(ry);   // 原始值往上变大，s2a_pad.h 约定上为正：不取反（同 NS2Transport.m calibrated_axis）
    } else if (pid == 0x2006) {   // 左只横握：十字键当 ABXY（下 A、右 B、上 X、左 Y），SL / SR 当 L / R
        if (b[2] & 0x01) out |= JC1_E; if (b[2] & 0x04) out |= JC1_S; if (b[2] & 0x02) out |= JC1_N; if (b[2] & 0x08) out |= JC1_W;
        if (b[2] & 0x40) { out |= JC1_L; *side |= S2A_JC1_SIDE_SHOULDER; }
        if (b[2] & 0x80) out |= JC1_ZL;
        if (b[2] & 0x20) { out |= JC1_L; *side |= S2A_JC1_SIDE_SL; }
        if (b[2] & 0x10) { out |= JC1_R; *side |= S2A_JC1_SIDE_SR; }
        if (b[1] & 0x01) out |= JC1_MINUS; if (b[1] & 0x08) out |= JC1_LS; if (b[1] & 0x20) out |= JC1_PLUS;   // Capture 当 +（单只没有 +）
        sticks[0] = jc1_axis(lx); sticks[1] = jc1_axis(ly);
    } else if (pid == 0x2007) {   // 右只：面键照原样（横握由游戏 HoldType 解释），SL / SR 当 L / R
        if (b[0] & 0x08) out |= JC1_E; if (b[0] & 0x04) out |= JC1_S; if (b[0] & 0x02) out |= JC1_N; if (b[0] & 0x01) out |= JC1_W;
        if (b[0] & 0x40) { out |= JC1_R; *side |= S2A_JC1_SIDE_SHOULDER; }
        if (b[0] & 0x80) out |= JC1_ZR;
        if (b[0] & 0x20) { out |= JC1_L; *side |= S2A_JC1_SIDE_SL; }
        if (b[0] & 0x10) { out |= JC1_R; *side |= S2A_JC1_SIDE_SR; }
        if (b[1] & 0x02) out |= JC1_PLUS; if (b[1] & 0x04) out |= JC1_RS; if (b[1] & 0x10) out |= JC1_MINUS;   // Home 当 −（单只没有 −）
        sticks[2] = jc1_axis(rx); sticks[3] = jc1_axis(ry);
    } else return 0;
    *buttons = out;
    return 1;
}
void s2a_joycon1_pair_decode(const uint8_t *left, const uint8_t *right, uint32_t *buttons, int32_t sticks[4]) {
    static const uint8_t idle[S2A_JC1_RAW] = {0, 0, 0, 0, 0, 0x00, 0x08, 0x80, 0x00, 0x08, 0x80};   // 没按、两个摇杆居中（2048）
    if (!left) left = idle;
    if (!right) right = idle;
    uint8_t report[49] = {0x30, right[0], right[1], right[2], (uint8_t)(left[3] | right[3]), left[4],
                          left[5], left[6], left[7], right[8], right[9], right[10]};
    int side;
    if (!s2a_joycon1_decode(0x2009, report, sizeof report, buttons, sticks, &side)) { *buttons = 0; for (int i = 0; i < 4; i++) sticks[i] = 0; }
}

