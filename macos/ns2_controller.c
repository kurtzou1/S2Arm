// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "ns2_controller.h"
#include "../runtime/include/s2a_pad.h"
#include "ns2_relay.h"
#include "../ios/haptic_retry.h"
#include <errno.h>
#include <stdatomic.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t relayWriteLock = PTHREAD_MUTEX_INITIALIZER;
// 按键 / 摇杆按玩家各一份（通道包头 player；直连只有玩家 0）。[0] 同改前那一份；[1..] 只走通道，就绪看 playerReady
static ns2_state input[NS2_RELAY_PLAYERS];
static int playerReady[NS2_RELAY_PLAYERS];   // [0] 不用（玩家 0 看 ready）
static ns2_motion playerMotion[NS2_RELAY_PLAYERS];   // 玩家 1 起的六轴（INPUT 包 motion，原始方向；#520 每位玩家都有体感），[0] 不用
static ns2_motion relayMotion, relayMotionLeft;   // relayMotionLeft：Joy-Con 2 拼对时左只的（INPUT 包 motion_left）
static ns2_mouse relayMouse[2];   // Joy-Con 2 光学鼠标 [0] 左只 / [1] 右只（INPUT 包 mouse，mouse_kind 标哪一只；一对时两只轮流来；旧启动器没有 → known = 0）
static uint64_t relayMouseUs[2];   // 各侧收到的时刻（超过 250 毫秒没来就当没有）
static ns2_mouse playerMouse[NS2_RELAY_PLAYERS];   // 玩家 1 起各自那只的鼠标（#520：拆开 / 别组的玩家包也带，[0] 不用）
static uint64_t playerMouseUs[NS2_RELAY_PLAYERS];
static ns2_kind relayKind[NS2_RELAY_PLAYERS];   // 通道 v2 带来的对外输出型号，按玩家（持 lock）
static ns2_status status;
static int directStarted, ready, foreground, motion_requested;
static int relayFD = -1;
static int relayLastError;   // 上次连通道失败的 errno（只在主线程连接路径读写）
static pthread_t relayThread;
static int relayThreadStarted;
static uint64_t epoch = 1;
static uint16_t back_buttons[2];
static float rumble_scale = 1;
// 游戏这一格现在的手柄样式（Ryujinx ControllerType 位；InputPump 改配后经 s2a_vpad_set_style 告诉这里；0 = 还不知道）
static _Atomic int gameStyle;

static void clear_players_locked(void) {
    memset(input, 0, sizeof input);
    memset(playerMotion, 0, sizeof playerMotion);
    memset(playerReady, 0, sizeof playerReady);
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) relayKind[p] = NS2_KIND_NONE;
}

static float rumble_amplitude(float amplitude) {
    return fminf(1, s2a_hp_feel(amplitude) * rumble_scale);
}

static void receive_input(const ns2_state *state, void *context) {
    pthread_mutex_lock(&lock);
    if (ready && foreground) input[0] = *state;
    pthread_mutex_unlock(&lock);
}

static void receive_status(ns2_status next, const char *message, void *context) {
    pthread_mutex_lock(&lock);
    status = next;
    int connected = next == NS2_STATUS_READY;
    if (ready != connected) {
        epoch++;
        memset(&input[0], 0, sizeof input[0]);
    }
    ready = connected;
    pthread_mutex_unlock(&lock);
    fprintf(stderr, "[Mac NS2] status=%d %s\n", next, message);
}

// Supplying a motion callback selects report05 in the existing transport.
static void receive_motion(const ns2_motion *motion, void *context) {
    (void)context;
    (void)motion;
}

static int connect_relay(const char *path) {
    struct sockaddr_un address = {0};
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof address.sun_path) return 0;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, length + 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof address)) {
        int error = errno;
        close(fd);
        // 开局时手柄还没连、游戏每秒重试：同一个原因只记一次，接上后再失败重新记
        if (error != relayLastError) fprintf(stderr, "[Mac NS2] Relay unavailable at %s: %s\n", path, strerror(error));
        relayLastError = error;
        return 0;
    }
    relayLastError = 0;

    pthread_mutex_lock(&lock);
    relayFD = fd;
    ready = 0;
    status = NS2_STATUS_CONNECTING;
    clear_players_locked();
    memset(&relayMotion, 0, sizeof relayMotion);
    pthread_mutex_unlock(&lock);
    return 1;
}

static int receive_all(int fd, void *buffer, size_t length) {
    char *cursor = buffer;
    while (length) {
        ssize_t received = recv(fd, cursor, length, 0);
        if (received <= 0) {
            if (received < 0 && errno == EINTR) continue;
            return 0;
        }
        cursor += received;
        length -= (size_t)received;
    }
    return 1;
}

static uint64_t s2a_mac_ns2_now_us(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u; }

static void *relay_read_main(void *context) {
    int fd = (int)(intptr_t)context;
    ns2_relay_packet packet;
    while (receive_all(fd, &packet, sizeof packet)) {
        if (packet.magic != NS2_RELAY_MAGIC || packet.version != NS2_RELAY_VERSION || packet.type != NS2_RELAY_INPUT) {
            if (packet.magic == NS2_RELAY_MAGIC && packet.version != NS2_RELAY_VERSION)
                fprintf(stderr, "[Mac NS2] 启动器通道版本 %u，本端 %u：断开（启动器与游戏宿主版本不一致）\n", packet.version, NS2_RELAY_VERSION);
            break;
        }
        // 超出范围的玩家号（以后的启动器 / 坏包）：丢掉这一包，通道照常（不为拿不准的包断线）
        if (packet.player >= NS2_RELAY_PLAYERS) {
            static int warned;
            if (!warned) { warned = 1; fprintf(stderr, "[Mac NS2] 通道包玩家号 %u 超出 %d 位，丢弃\n", packet.player, NS2_RELAY_PLAYERS); }
            continue;
        }
        pthread_mutex_lock(&lock);
        if (relayFD != fd) {
            pthread_mutex_unlock(&lock);
            break;
        }
        // 玩家 2 起：只存按键 / 摇杆与型号（体感 / 鼠标 / 震动 / 连接状态跟玩家 0 走，ns2_relay.h player）
        if (packet.player) {
            int p = packet.player, on = packet.ready != 0;
            playerReady[p] = on;
            input[p] = on ? packet.state : (ns2_state){0};
            relayKind[p] = on ? (ns2_kind)packet.kind : NS2_KIND_NONE;
            if (on && packet.motion_known) { playerMotion[p] = packet.motion; playerMotion[p].host_timestamp_us = s2a_mac_ns2_now_us(); }
            else if (!on) memset(&playerMotion[p], 0, sizeof playerMotion[p]);
            if (on && (packet.mouse_kind == NS2_KIND_JOYCON_L || packet.mouse_kind == NS2_KIND_JOYCON_R)) {
                const ns2_relay_mouse *m = &packet.mouse;
                playerMouse[p] = (ns2_mouse){.known = 1, .kind = (ns2_kind)packet.mouse_kind, .x = m->x, .y = m->y, .surface = m->surface, .distance = m->distance};
                playerMouseUs[p] = s2a_mac_ns2_now_us();
            } else if (!on) memset(&playerMouse[p], 0, sizeof playerMouse[p]);
            pthread_mutex_unlock(&lock);
            continue;
        }
        int connected = packet.ready != 0;
        if (ready != connected) {
            epoch++;
            memset(&input[0], 0, sizeof input[0]);
        }
        ready = connected;
        status = (ns2_status)packet.status;
        if (connected) input[0] = packet.state;
        relayKind[0] = connected ? (ns2_kind)packet.kind : NS2_KIND_NONE;
        if (packet.motion_known) relayMotion = packet.motion;
        else memset(&relayMotion, 0, sizeof relayMotion);
        // 拼对时左只的六轴（ns2_relay.h motion_left；旧启动器发 0 → 只有右只，照旧）
        if (packet.motion_known && packet.motion_left_known) {
            const ns2_relay_motion_left *l = &packet.motion_left;
            relayMotionLeft = (ns2_motion){.known = 1, .host_timestamp_us = (uint64_t)l->host_timestamp_us_hi << 32 | l->host_timestamp_us_lo,
                .acceleration_x = l->acceleration_x, .acceleration_y = l->acceleration_y, .acceleration_z = l->acceleration_z, .gyro_x = l->gyro_x, .gyro_y = l->gyro_y, .gyro_z = l->gyro_z};
        } else memset(&relayMotionLeft, 0, sizeof relayMotionLeft);
        if (connected && (packet.mouse_kind == NS2_KIND_JOYCON_L || packet.mouse_kind == NS2_KIND_JOYCON_R)) {
            const ns2_relay_mouse *m = &packet.mouse;
            int side = packet.mouse_kind == NS2_KIND_JOYCON_R;
            relayMouse[side] = (ns2_mouse){.known = 1, .kind = (ns2_kind)packet.mouse_kind, .x = m->x, .y = m->y, .surface = m->surface, .distance = m->distance};
            relayMouseUs[side] = s2a_mac_ns2_now_us();
        } else if (!connected) memset(relayMouse, 0, sizeof relayMouse);
        pthread_mutex_unlock(&lock);
    }

    pthread_mutex_lock(&lock);
    if (relayFD == fd) {
        relayFD = -1;
        ready = 0;
        status = NS2_STATUS_DISCONNECTED;
        epoch++;
        clear_players_locked();
        memset(&relayMotion, 0, sizeof relayMotion);
        memset(&relayMotionLeft, 0, sizeof relayMotionLeft);
        memset(relayMouse, 0, sizeof relayMouse);
    }
    pthread_mutex_unlock(&lock);
    close(fd);
    fprintf(stderr, "[Mac NS2] Relay connection closed\n");
    return NULL;
}

static int relay_send(const ns2_relay_packet *packet) {
    pthread_mutex_lock(&relayWriteLock);
    pthread_mutex_lock(&lock);
    int fd = relayFD;
    pthread_mutex_unlock(&lock);
    ssize_t sent = fd < 0 ? -1 : send(fd, packet, sizeof *packet, 0);
    pthread_mutex_unlock(&relayWriteLock);
    return sent == (ssize_t)sizeof *packet;
}

static int relay_command(uint16_t type) {
    ns2_relay_packet packet = {0};
    packet.magic = NS2_RELAY_MAGIC;
    packet.version = NS2_RELAY_VERSION;
    packet.type = type;
    return relay_send(&packet);
}

static void set_relay_motion(int enabled) {
    ns2_relay_packet packet = {0};
    packet.magic = NS2_RELAY_MAGIC;
    packet.version = NS2_RELAY_VERSION;
    packet.type = NS2_RELAY_MOTION;
    packet.enabled = enabled;
    relay_send(&packet);
}

int s2a_mac_ns2_connect(void) {
    const char *scale = getenv("S2A_RUMBLE_SCALE");
    float value = scale ? strtof(scale, NULL) : 1;
    rumble_scale = isfinite(value) && value > 0 ? value : 1;
    pthread_mutex_lock(&lock);
    if (relayFD >= 0) {
        pthread_mutex_unlock(&lock);
        return 1;
    }
    if (directStarted) {
        pthread_mutex_unlock(&lock);
        return ns2_rescan();
    }
    pthread_mutex_unlock(&lock);

    const char *relayPath = getenv("S2A_NS2_SOCKET");
    if (relayPath) {
        if (!connect_relay(relayPath)) return 0;
        if (relayThreadStarted) {
            pthread_join(relayThread, NULL);
            relayThreadStarted = 0;
        }
        pthread_mutex_lock(&lock);
        int fd = relayFD;
        pthread_mutex_unlock(&lock);
        if (pthread_create(&relayThread, NULL, relay_read_main, (void *)(intptr_t)fd)) {
            pthread_mutex_lock(&lock);
            relayFD = -1;
            pthread_mutex_unlock(&lock);
            close(fd);
            return 0;
        }
        relayThreadStarted = 1;
        return 1;
    }

    ns2_set_joycon_raw(1);   // 单只 Joy-Con 报原始方向，转不转由 s2a_mac_ns2_read 按游戏样式定（同通道那头的连接程序）
    int started = ns2_start_with_motion(receive_input, receive_status, receive_motion, NULL);
    if (started) {
        pthread_mutex_lock(&lock);
        directStarted = 1;
        ns2_set_motion_enabled(motion_requested);
        pthread_mutex_unlock(&lock);
    }
    return started;
}

void s2a_mac_ns2_detach(void) {
    pthread_mutex_lock(&lock);
    int fd = relayFD;
    int threadStarted = relayThreadStarted;
    int direct = directStarted;
    relayFD = -1;
    relayThreadStarted = 0;
    directStarted = 0;
    ready = 0;
    status = NS2_STATUS_STOPPED;
    epoch++;
    clear_players_locked();
    memset(&relayMotion, 0, sizeof relayMotion);
    pthread_mutex_unlock(&lock);
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
    if (threadStarted) pthread_join(relayThread, NULL);
    if (direct) ns2_shutdown("Mac game closed", 200);
}

void s2a_mac_ns2_disconnect(void) {
    pthread_mutex_lock(&lock);
    int relay = relayFD >= 0;
    pthread_mutex_unlock(&lock);
    if (relay) relay_command(NS2_RELAY_DISCONNECT);
    s2a_mac_ns2_detach();
}

void s2a_mac_ns2_focus(int focused) {
    pthread_mutex_lock(&lock);
    int changed = foreground != !!focused;
    if (changed) {
        foreground = !!focused;
        epoch++;
        memset(input, 0, sizeof input);   // 只清这一拍的读数；玩家 2 起的就绪 / 型号不动（下一包就回来）
    }
    int relay = relayFD >= 0;
    int motion = motion_requested && foreground;
    pthread_mutex_unlock(&lock);
    if (changed) {
        if (relay) set_relay_motion(motion);
        else ns2_set_motion_enabled(motion);
        if (!foreground) {
            if (relay) relay_command(NS2_RELAY_STOP_RUMBLE);
            else ns2_stop_rumble();
        }
    }
}

// 单只 Joy-Con（#520 A）：传输层报原始方向（ns2_set_joycon_raw），这里按游戏这一格的样式定——
//   游戏用的是这只那一侧的单只样式（JoyLeft / JoyRight）就原样给，由游戏按 NpadJoyHoldType 自己转竖 / 横（同真机）；
//   双 Joy-Con（InputPump 只在游戏不收 Pro 时报它，ReportedStyle）也原样给：真机是双手模式只接一侧、直握（11-11 实机：一款体育游戏的球类项目）；
//   否则（游戏收 Pro、宿主扮 Pro / 掌机）转成横握视角，同改前
enum { STYLE_JOYCON_PAIR = 1 << 2, STYLE_JOYCON_LEFT = 1 << 3, STYLE_JOYCON_RIGHT = 1 << 4 };   // Ryujinx ControllerType
enum { KEY_SL_LEFT = 1u << 24, KEY_SR_LEFT = 1u << 25, KEY_SL_RIGHT = 1u << 26, KEY_SR_RIGHT = 1u << 27 };   // Ryujinx ControllerKeys
int s2a_mac_ns2_raw_wanted(ns2_kind kind, int style) {
    return (kind == NS2_KIND_JOYCON_L && (style == STYLE_JOYCON_LEFT || style == STYLE_JOYCON_PAIR)) ||
           (kind == NS2_KIND_JOYCON_R && (style == STYLE_JOYCON_RIGHT || style == STYLE_JOYCON_PAIR));
}
int s2a_mac_ns2_single_style(ns2_kind kind) {
    return kind == NS2_KIND_JOYCON_L ? STYLE_JOYCON_LEFT : kind == NS2_KIND_JOYCON_R ? STYLE_JOYCON_RIGHT : 0;
}
uint32_t s2a_mac_ns2_shape(ns2_kind kind, int raw, ns2_state *s) {
    if (kind != NS2_KIND_JOYCON_L && kind != NS2_KIND_JOYCON_R) return 0;
    if (!raw) { ns2_joycon_raw_to_sideways(kind, s); return 0; }
    int left = kind == NS2_KIND_JOYCON_L;
    uint32_t keys = (s->buttons >> NS2_BUTTON_SL & 1 ? (left ? KEY_SL_LEFT : KEY_SL_RIGHT) : 0) |
                    (s->buttons >> NS2_BUTTON_SR & 1 ? (left ? KEY_SR_LEFT : KEY_SR_RIGHT) : 0);
    s->buttons &= ~((1ull << NS2_BUTTON_SL) | (1ull << NS2_BUTTON_SR));
    return keys;
}
void s2a_mac_ns2_set_game_style(int style) { atomic_store(&gameStyle, style); }
// 玩家 player（1 起）所在那一格的样式（front_mac.m 照槽位转过来）：单只 Joy-Con 照它定原始方向还是转横握，规则同玩家 1（s2a_mac_ns2_raw_wanted）。
//   没报过（0）= 转横握，同改前
static _Atomic int playerStyle[NS2_RELAY_PLAYERS];   // [0]：多手柄时玩家 0 占的那一格（0 = 照 gameStyle）
void s2a_mac_ns2_set_player_style(int player, int style) { if (player >= 0 && player < NS2_RELAY_PLAYERS) atomic_store(&playerStyle[player], style); }
static ns2_kind kind_locked(void) { return !ready ? NS2_KIND_NONE : relayFD >= 0 ? relayKind[0] : ns2_get_output_kind(); }
// 玩家 0 的样式：多手柄时照它占的那一格（宿主照槽位转来，playerStyle[0]），单手柄 / 没报时照游戏给 P1 的那一格（gameStyle，同改前）
static int style_of(int player) {
    if (player > 0) return atomic_load(&playerStyle[player]);
    int slot = atomic_load(&playerStyle[0]);
    return slot ? slot : atomic_load(&gameStyle);
}
int s2a_mac_ns2_raw_now(void) { return s2a_mac_ns2_raw_wanted(s2a_mac_ns2_kind(), style_of(0)); }

// 玩家 player 的手柄状态（多手柄各占一个槽位，front_mac.m sample_input）。玩家 0 同改前（直连 / 通道都有、单只 Joy-Con 按游戏样式整形）；
//   玩家 1 起只来自通道，单只 Joy-Con 按它那一格的样式整形（s2a_mac_ns2_set_player_style；同玩家 1 一套规则，拆开的两只握法一致）
int s2a_mac_ns2_read_player(int player, ns2_state *state, uint32_t *side_keys, ns2_kind *kind_out) {
    if (player < 0 || player >= NS2_RELAY_PLAYERS) {
        *state = (ns2_state){0};
        if (side_keys) *side_keys = 0;
        if (kind_out) *kind_out = NS2_KIND_NONE;
        return 0;
    }
    pthread_mutex_lock(&lock);
    int available = foreground && (player ? relayFD >= 0 && playerReady[player] : ready);
    *state = available ? input[player] : (ns2_state){0};
    ns2_kind kind = !available ? NS2_KIND_NONE : player ? relayKind[player] : kind_locked();
    if (state->buttons & (1ull << 19)) state->buttons |= back_buttons[0];
    if (state->buttons & (1ull << 20)) state->buttons |= back_buttons[1];
    pthread_mutex_unlock(&lock);
    int raw = s2a_mac_ns2_raw_wanted(kind, style_of(player));
    uint32_t keys = s2a_mac_ns2_shape(kind, raw, state);
    if (side_keys) *side_keys = keys;
    if (kind_out) *kind_out = kind;
    return available;
}

// 玩家 player 连着没有（不看前后台）：分槽用——窗口失焦时读数清零，但这位玩家仍占着槽，免得服务层把他的格子拆掉
int s2a_mac_ns2_player_present(int player) {
    if (player < 0 || player >= NS2_RELAY_PLAYERS) return 0;
    pthread_mutex_lock(&lock);
    int present = player ? relayFD >= 0 && playerReady[player] : ready;
    pthread_mutex_unlock(&lock);
    return present;
}

int s2a_mac_ns2_read(ns2_state *state, uint32_t *side_keys) { return s2a_mac_ns2_read_player(0, state, side_keys, NULL); }

void s2a_mac_ns2_set_back_buttons(uint16_t left, uint16_t right) {
    pthread_mutex_lock(&lock);
    back_buttons[0] = left;
    back_buttons[1] = right;
    pthread_mutex_unlock(&lock);
}

int s2a_mac_ns2_relay_due(ns2_status status, const char *relay) {
    return relay && *relay && status == NS2_STATUS_IDLE && access(relay, F_OK) == 0;
}

ns2_kind s2a_mac_ns2_kind(void) {
    pthread_mutex_lock(&lock);
    ns2_kind kind = kind_locked();
    pthread_mutex_unlock(&lock);
    return kind;
}

const char *s2a_mac_ns2_kind_name(ns2_kind kind) {
    switch (kind) {
        case NS2_KIND_JOYCON_L: return "Joy-Con 2 (L)";
        case NS2_KIND_JOYCON_R: return "Joy-Con 2 (R)";
        case NS2_KIND_JOYCON_PAIR: return "Joy-Con 2 (L + R)";
        case NS2_KIND_PRO: return "Switch 2 Pro";
        default: return "Switch 手柄";   // 没连 / 还不知道型号（不分代）
    }
}

ns2_status s2a_mac_ns2_status(void) {
    pthread_mutex_lock(&lock);
    ns2_status value = status;
    pthread_mutex_unlock(&lock);
    return value;
}

#define EXPORT __attribute__((visibility("default"), used))
uint64_t s2a_mac_ns2_rumble_session(void) {
    pthread_mutex_lock(&lock);
    uint64_t session = ready && foreground ? epoch : 0;
    pthread_mutex_unlock(&lock);
    return session;
}

// 震动按玩家（#520 E，Joy-Con 2 不是 P1 时没震动）：每位玩家最近一份存着，合成左右两侧再发——
//   一对 / Pro 两侧照游戏给的；拆开的单只 Joy-Con 只占自己那一侧（左只第 0 侧、右只第 1 侧，传输层按链路分侧），取两路里强的那份
//   （单只扮成横握 Pro 时游戏两侧都给）。两位玩家都在震时各震各的那只，不会互相盖掉
static s2a_pad_vibration playerRumble[NS2_RELAY_PLAYERS][2];
static float vibration_strength(s2a_pad_vibration v) { return v.low_amp + v.high_amp; }
// group：第几组（连接程序那一边一组 = 一只 Pro 或一对 / 拆开的两只 Joy-Con；第二组由第二个连接程序管，见 #520）
static void compose_rumble_locked(int group, ns2_vibration pair[2]) {
    s2a_pad_vibration side[2] = {{0}};
    for (int p = group * 2; p < group * 2 + 2 && p < NS2_RELAY_PLAYERS; p++) {
        int present = p ? relayFD >= 0 && playerReady[p] : ready;
        if (!present) continue;
        ns2_kind kind = p ? relayKind[p] : kind_locked();
        const s2a_pad_vibration *v = playerRumble[p];
        if (kind == NS2_KIND_JOYCON_L || kind == NS2_KIND_JOYCON_R) {
            s2a_pad_vibration strong = vibration_strength(v[0]) >= vibration_strength(v[1]) ? v[0] : v[1];
            side[kind == NS2_KIND_JOYCON_R] = strong;
        } else if (p == group * 2) { side[0] = v[0]; side[1] = v[1]; }
    }
    for (int i = 0; i < 2; i++)
        pair[i] = (ns2_vibration){rumble_amplitude(side[i].low_amp), side[i].low_hz, rumble_amplitude(side[i].high_amp), side[i].high_hz};
}
static void send_rumble_pair(const ns2_vibration pair[2], int relay, int group) {
    if (relay) {
        ns2_relay_packet packet = {0};
        packet.player = (uint8_t)(group * 2);   // 第二组：第一个连接程序转给第二个
        packet.magic = NS2_RELAY_MAGIC;
        packet.version = NS2_RELAY_VERSION;
        packet.type = NS2_RELAY_RUMBLE;
        packet.duration_ms = 1000;
        memcpy(packet.vibration, pair, sizeof packet.vibration);
        relay_send(&packet);
    } else if (!group) {
        ns2_send_pair_lease(pair, 1000);   // 直连只有一组
    }
}
// 玩家 player 的震动（宿主 front_mac.m s2a_pad_set_rumble_slot：P1 以外的槽位走这里；P1 仍走会话号那一路）
void s2a_mac_ns2_set_rumble_player(int player, const s2a_pad_vibration values[2]) {
    if (player < 0 || player >= NS2_RELAY_PLAYERS) return;
    ns2_vibration pair[2];
    pthread_mutex_lock(&lock);
    int accepted = ready && foreground;
    int group = player / 2;
    if (accepted) { playerRumble[player][0] = values[0]; playerRumble[player][1] = values[1]; compose_rumble_locked(group, pair); }
    int relay = relayFD >= 0;
    pthread_mutex_unlock(&lock);
    if (accepted) send_rumble_pair(pair, relay, group);
}

void s2a_mac_ns2_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]) {
    pthread_mutex_lock(&lock);
    int accepted = ready && foreground && session == epoch;
    pthread_mutex_unlock(&lock);
    if (accepted) s2a_mac_ns2_set_rumble_player(0, values);
}

void s2a_mac_ns2_stop_rumble(uint64_t session) {
    pthread_mutex_lock(&lock);
    if (session == epoch) memset(playerRumble, 0, sizeof playerRumble);
    int accepted = session == epoch;
    int relay = relayFD >= 0;
    pthread_mutex_unlock(&lock);
    if (!accepted) return;
    if (relay) relay_command(NS2_RELAY_STOP_RUMBLE);
    else ns2_stop_rumble();
}

EXPORT void s2a_mac_ns2_set_motion_enabled(int enabled) {
    pthread_mutex_lock(&lock);
    motion_requested = !!enabled;
    int relay = relayFD >= 0;
    int active = motion_requested && foreground;
    pthread_mutex_unlock(&lock);
    if (relay) {
        set_relay_motion(active);
    } else {
        ns2_set_motion_enabled(active);
    }
}

static s2a_pad_motion pad_motion(const ns2_motion *m) {
    return (s2a_pad_motion){m->host_timestamp_us, m->acceleration_x, m->acceleration_y, m->acceleration_z, m->gyro_x, m->gyro_y, m->gyro_z};
}

// Joy-Con 2 左右拼成一对：out[0] 左只、out[1] 右只，返回 2；只有一路（Pro / 单只 / 旧启动器）时 out[0] 是它、返回 1；没有返回 0
EXPORT int s2a_mac_ns2_read_motion_pair(s2a_pad_motion out[2]) {
    ns2_motion left = {0}, right = {0};
    pthread_mutex_lock(&lock);
    if (ready && foreground && motion_requested) {
        if (relayFD >= 0) { right = relayMotion; left = relayMotionLeft; }
        else { ns2_get_motion(&right); ns2_get_motion_left(&left); }
    }
    pthread_mutex_unlock(&lock);
    out[0] = out[1] = (s2a_pad_motion){0};
    if (!right.known) return 0;
    if (!left.known) { out[0] = pad_motion(&right); return 1; }
    out[0] = pad_motion(&left);
    out[1] = pad_motion(&right);
    return 2;
}


// Joy-Con 2 光学鼠标，左右各一份：连着 Joy-Con 2（单只 / 一对）就返回有几侧（游戏靠它认 Joy-Con 2，没有鼠标读数也照报；窗口失焦也照报，
//   免得样式来回切、游戏收到手柄重配）。out[0] 左只、out[1] 右只，side 填好；单只时只有那一侧（另一侧 side = 0xff）。
//   读数取通道 / 直连最近一笔（各侧 250 毫秒内），失焦时不给
EXPORT int s2a_mac_ns2_read_mouse_pair(s2a_pad_mouse out[2]) {
    if (!out) return 0;
    out[0] = out[1] = (s2a_pad_mouse){0};
    ns2_mouse mouse[2] = {{0}};
    pthread_mutex_lock(&lock);
    int on = ready, live = ready && foreground;
    uint64_t now = s2a_mac_ns2_now_us();
    for (int side = 0; side < 2; side++) {
        if (live && relayFD >= 0) { if (now - relayMouseUs[side] <= 250000) mouse[side] = relayMouse[side]; }
        else if (live) ns2_get_mouse_side(side, &mouse[side]);
    }
    pthread_mutex_unlock(&lock);
    if (!on) return 0;
    ns2_kind kind = s2a_mac_ns2_kind();
    int has[2] = {kind == NS2_KIND_JOYCON_L || kind == NS2_KIND_JOYCON_PAIR, kind == NS2_KIND_JOYCON_R || kind == NS2_KIND_JOYCON_PAIR};
    int n = 0;
    for (int side = 0; side < 2; side++) {
        out[side].side = has[side] ? (uint8_t)side : 0xff;
        if (!has[side]) continue;
        n++;
        out[side].host_timestamp_us = now;
        if (mouse[side].known) { out[side].known = 1; out[side].x = mouse[side].x; out[side].y = mouse[side].y; out[side].distance = mouse[side].distance; }
    }
    return n;
}

// 玩家 player（1 起）当 P1 时的 Joy-Con 2 鼠标（#520：拆开后分配成 P1 的是另一只）：游戏靠它认 Joy-Con 2，照这只的型号报哪一侧在；
//   读数照通道带来的那一侧（mouse_kind 标哪一只，各侧 250 毫秒内），没有就只报在、不给位移
EXPORT int s2a_mac_ns2_read_mouse_player(int player, s2a_pad_mouse out[2]) {
    if (!out) return 0;
    out[0] = out[1] = (s2a_pad_mouse){0};
    if (player <= 0 || player >= NS2_RELAY_PLAYERS) return player == 0 ? s2a_mac_ns2_read_mouse_pair(out) : 0;
    pthread_mutex_lock(&lock);
    int on = relayFD >= 0 && playerReady[player], live = on && foreground;
    ns2_kind kind = on ? relayKind[player] : NS2_KIND_NONE;
    uint64_t now = s2a_mac_ns2_now_us();
    ns2_mouse mouse[2] = {{0}};
    for (int side = 0; side < 2; side++) if (live && now - relayMouseUs[side] <= 250000) mouse[side] = relayMouse[side];
    if (live && now - playerMouseUs[player] <= 250000 && playerMouse[player].known)   // 这位玩家自己那包带来的（拆开 / 别组）优先
        mouse[playerMouse[player].kind == NS2_KIND_JOYCON_R] = playerMouse[player];
    pthread_mutex_unlock(&lock);
    int has[2] = {kind == NS2_KIND_JOYCON_L || kind == NS2_KIND_JOYCON_PAIR, kind == NS2_KIND_JOYCON_R || kind == NS2_KIND_JOYCON_PAIR};
    int n = 0;
    for (int side = 0; side < 2; side++) {
        out[side].side = has[side] ? (uint8_t)side : 0xff;
        if (!has[side]) continue;
        n++;
        out[side].host_timestamp_us = now;
        if (mouse[side].known) { out[side].known = 1; out[side].x = mouse[side].x; out[side].y = mouse[side].y; out[side].distance = mouse[side].distance; }
    }
    return n;
}
// 玩家 player 的手柄型号（不看前后台：失焦时分槽 / 配格不变）；没连回 NONE
ns2_kind s2a_mac_ns2_player_kind(int player) {
    if (player < 0 || player >= NS2_RELAY_PLAYERS) return NS2_KIND_NONE;
    pthread_mutex_lock(&lock);
    ns2_kind kind = player ? (relayFD >= 0 && playerReady[player] ? relayKind[player] : NS2_KIND_NONE) : kind_locked();
    pthread_mutex_unlock(&lock);
    return kind;
}
int s2a_mac_ns2_player_raw(int player) {
    if (player <= 0 || player >= NS2_RELAY_PLAYERS) return player == 0 && s2a_mac_ns2_raw_now();
    pthread_mutex_lock(&lock);
    ns2_kind kind = relayFD >= 0 && playerReady[player] ? relayKind[player] : NS2_KIND_NONE;
    pthread_mutex_unlock(&lock);
    return s2a_mac_ns2_raw_wanted(kind, style_of(player));
}

EXPORT int s2a_mac_ns2_read_motion(s2a_pad_motion *out) {
    ns2_motion sample = {0};
    ns2_kind kind = NS2_KIND_NONE;
    pthread_mutex_lock(&lock);
    if (ready && foreground && motion_requested) {
        if (relayFD >= 0) sample = relayMotion;
        else ns2_get_motion(&sample);
        kind = kind_locked();
    }
    pthread_mutex_unlock(&lock);
    // 单只 Joy-Con 的六轴同按键：游戏用单只样式就原样给，否则换成横握视角（传输层原始方向时不转）
    if (!s2a_mac_ns2_raw_wanted(kind, style_of(0))) ns2_joycon_sideways_motion(kind, &sample);
    *out = (s2a_pad_motion){0};
    if (!sample.known) return 0;
    *out = pad_motion(&sample);
    return 1;
}

// 玩家 player（1 起）的六轴（#520：每位玩家都有体感）：通道包带来的，单只 Joy-Con 同它的按键（照它那一格的样式原样给或转横握）；
//   玩家 0 用 s2a_mac_ns2_read_motion / _pair。没有 / 250 毫秒没更新回 0
EXPORT int s2a_mac_ns2_read_motion_player(int player, s2a_pad_motion *out) {
    if (!out || player <= 0 || player >= NS2_RELAY_PLAYERS) return 0;
    ns2_motion sample = {0};
    ns2_kind kind = NS2_KIND_NONE;
    pthread_mutex_lock(&lock);
    if (foreground && motion_requested && relayFD >= 0 && playerReady[player] && s2a_mac_ns2_now_us() - playerMotion[player].host_timestamp_us <= 250000) {
        sample = playerMotion[player]; kind = relayKind[player];
    }
    pthread_mutex_unlock(&lock);
    *out = (s2a_pad_motion){0};
    if (!sample.known) return 0;
    if (!s2a_mac_ns2_raw_wanted(kind, style_of(player))) ns2_joycon_sideways_motion(kind, &sample);
    *out = pad_motion(&sample);
    return 1;
}

