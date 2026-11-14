// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "../../macos/ns2_controller.h"
#include "../../macos/ns2_relay.h"
#include "../../ios/haptic_retry.h"
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static ns2_state_callback input_callback;
static ns2_status_callback status_callback;
static ns2_motion sample;
static ns2_vibration sent[2];
static int starts, scans, stops, shutdowns, sends, imu;
static ns2_kind output_kind = NS2_KIND_JOYCON_L;   // 直连模式的对外输出型号（#520）
// NS2 input report 0x30: GL is bit 19 and GR is bit 20
// (switch2_controller_research bluetooth_interface.md).
enum { NS2_TEST_BUTTON_GL = 19, NS2_TEST_BUTTON_GR = 20 };
int ns2_start_with_motion(ns2_state_callback input, ns2_status_callback status, ns2_motion_callback motion, void *context) {
    assert(motion && !context);
    starts++; input_callback = input; status_callback = status; return 1;
}
int ns2_rescan(void) { scans++; return 1; }
int ns2_shutdown(const char *reason, unsigned timeout) {
    shutdowns++; status_callback(NS2_STATUS_STOPPED, reason, NULL); return 1;
}
void ns2_stop_rumble(void) { stops++; }
void ns2_set_motion_enabled(int enabled) { imu = enabled; }
void ns2_get_motion(ns2_motion *out) { *out = sample; }
void ns2_get_motion_left(ns2_motion *out) { *out = (ns2_motion){0}; }   // 没拼对：左只没有读数（拼对左右两路由 launchers/macos/Tests/input_test.m 经启动器通道测）
void ns2_get_mouse_side(int side, ns2_mouse *out) { (void)side; *out = (ns2_mouse){0}; }   // Joy-Con 2 光学鼠标：这里没有读数（通道左右鼠标由 launchers/macos/Tests/input_test.m 测）
ns2_kind ns2_get_output_kind(void) { return output_kind; }
// #520 A：直连也开原始方向；单只 Joy-Con 在游戏不用单只样式时由宿主转横握（真实现在 NS2JoyCon.c，这里只记次数）
static int joycon_raw, sideways_calls, sideways_motion_calls;
void ns2_set_joycon_raw(int raw) { joycon_raw = raw; }
void ns2_joycon_raw_to_sideways(ns2_kind kind, ns2_state *state) { sideways_calls++; }
void ns2_joycon_sideways_motion(ns2_kind kind, ns2_motion *motion) { if (kind == NS2_KIND_JOYCON_L || kind == NS2_KIND_JOYCON_R) sideways_motion_calls++; }
void ns2_send_pair_lease(const ns2_vibration pair[2], unsigned duration) {
    assert(duration == 1000); memcpy(sent, pair, sizeof sent); sends++;
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
static int make_listener(const char *path) {
    struct sockaddr_un address = {0};
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, path);
    assert(!bind(fd, (struct sockaddr *)&address, sizeof address));
    assert(!listen(fd, 1));
    return fd;
}
int main(void) {
    ns2_state input;
    s2a_pad_motion motion;
    unsetenv("S2A_NS2_SOCKET");
    unsetenv("S2A_RUMBLE_SCALE");
    assert(!s2a_mac_ns2_read(&input, NULL) && !starts);
    s2a_mac_ns2_set_motion_enabled(1); // A game can request sensors before connection.
    assert(s2a_mac_ns2_connect() && starts == 1 && imu);
    s2a_mac_ns2_focus(1);
    status_callback(NS2_STATUS_READY, "test connected", NULL);
    assert(s2a_mac_ns2_kind() == NS2_KIND_JOYCON_L);   // 直连模式：型号取传输层的对外输出形态
    assert(joycon_raw);   // 直连同样让传输层报原始方向（#520 A）
    // 单只左 Joy-Con、游戏还没告诉样式（扮 Pro）：读一次就转横握；游戏用 JoyconLeft 时不转
    { ns2_state probe = {.buttons = 1}; input_callback(&probe, NULL); uint32_t side = 0;
      assert(s2a_mac_ns2_read(&input, &side) && sideways_calls == 1 && !s2a_mac_ns2_raw_now());
      s2a_mac_ns2_set_game_style(1 << 3);
      assert(s2a_mac_ns2_read(&input, &side) && sideways_calls == 1 && s2a_mac_ns2_raw_now());
      s2a_mac_ns2_set_game_style(0); }
    output_kind = NS2_KIND_PRO;   // 以下按 Pro 手柄测原样直通（Pro 不整形）
    uint64_t session = s2a_mac_ns2_rumble_session();
    assert(session);
    // Physical Nintendo A, left stick up, and full independent right stick.
    ns2_state physical = {.buttons=1, .lx=-32767, .ly=32767, .rx=12345, .ry=-23456};
    input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input, NULL) && !memcmp(&input, &physical, sizeof input));
    s2a_mac_ns2_set_back_buttons(1u << 6, 1u << 7); // GL -> L; GR -> R.
    physical.buttons = (1ull << NS2_TEST_BUTTON_GL) | (1ull << NS2_TEST_BUTTON_GR) | 1;
    input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input, NULL));
    assert((input.buttons & 0xffff) == ((1u << 6) | (1u << 7) | 1));
    physical.buttons = 1; input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input, NULL) && (input.buttons & 0xffff) == 1);
    physical.buttons = 1ull << NS2_TEST_BUTTON_GL; input_callback(&physical, NULL);
    s2a_mac_ns2_set_back_buttons(1, 0); // Remapping a held paddle takes effect immediately.
    assert(s2a_mac_ns2_read(&input, NULL) && (input.buttons & 0xffff) == 1);
    s2a_mac_ns2_set_back_buttons(0, 0);
    assert(s2a_mac_ns2_read(&input, NULL) && !(input.buttons & 0xffff));
    physical.buttons = (1ull << 16) | (1ull << 17) | (1ull << 18);
    input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input, NULL) && !(input.buttons & 0xffff));
    sample = (ns2_motion){.known=1, .host_timestamp_us=123456,
        .acceleration_x=.1f, .acceleration_y=.2f, .acceleration_z=1,
        .gyro_x=90, .gyro_y=-45, .gyro_z=180};
    assert(s2a_mac_ns2_read_motion(&motion));
    assert(motion.host_timestamp_us == 123456 && motion.gyro_x == 90 && motion.gyro_y == -45);
    assert(motion.gyro_z == 180 && motion.acceleration_z == 1);
    const s2a_pad_vibration pair[2] = {{.2f, 160, .3f, 320}, {.4f, 80, .5f, 640}};
    s2a_mac_ns2_set_rumble_pair(session, pair);
    assert(sends == 1 && sent[0].low_amp == s2a_hp_feel(.2f) && sent[1].high_freq == 640);
    s2a_mac_ns2_focus(0);
    assert(stops && !imu && !s2a_mac_ns2_rumble_session() && !s2a_mac_ns2_read(&input, NULL));
    assert(!s2a_mac_ns2_read_motion(&motion));
    s2a_mac_ns2_set_rumble_pair(session, pair); assert(sends == 1);
    s2a_mac_ns2_focus(1);
    assert(imu);
    assert(s2a_mac_ns2_rumble_session() != session);
    s2a_mac_ns2_set_rumble_pair(session, pair); assert(sends == 1);
    status_callback(NS2_STATUS_DISCONNECTED, "test disconnect", NULL);
    assert(!s2a_mac_ns2_read(&input, NULL) && !s2a_mac_ns2_rumble_session());
    assert(s2a_mac_ns2_connect() && scans == 1 && starts == 1);
    status_callback(NS2_STATUS_READY, "test reconnect", NULL);
    assert(s2a_mac_ns2_rumble_session() != session);
    s2a_mac_ns2_set_motion_enabled(0); assert(!imu && !s2a_mac_ns2_read_motion(&motion));
    s2a_mac_ns2_disconnect(); assert(shutdowns == 1 && !s2a_mac_ns2_rumble_session());
    assert(s2a_mac_ns2_connect() && starts == 2);
    s2a_mac_ns2_disconnect(); assert(shutdowns == 2);

    char socket_path[96];
    snprintf(socket_path, sizeof socket_path, "/tmp/s2arm-ns2-test-%d.sock", getpid());
    int listener = make_listener(socket_path);
    setenv("S2A_NS2_SOCKET", socket_path, 1);
    setenv("S2A_RUMBLE_SCALE", "0.7", 1);
    assert(s2a_mac_ns2_connect());
    int relay = accept(listener, NULL, NULL);
    assert(relay >= 0);

    ns2_relay_packet packet = {
        .magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT,
        .epoch = 9, .state = {.buttons = 1, .lx = -123, .ly = 456}, .ready = 1,
        .status = NS2_STATUS_READY,
        .motion = {.known = 1, .host_timestamp_us = 777, .gyro_x = 12, .gyro_z = 34},
        .motion_known = 1,
    };
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    for (int i = 0; i < 100 && !s2a_mac_ns2_read(&input, NULL); i++) usleep(1000);
    assert(input.buttons == 1 && input.lx == -123 && input.ly == 456);
    assert(s2a_mac_ns2_status() == NS2_STATUS_READY);

    s2a_mac_ns2_set_motion_enabled(1);
    memset(&packet, 0, sizeof packet);
    assert(receive_all(relay, &packet, sizeof packet));
    assert(packet.magic == NS2_RELAY_MAGIC && packet.type == NS2_RELAY_MOTION && packet.enabled);
    packet = (ns2_relay_packet){
        .magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT,
        .ready = 1, .status = NS2_STATUS_READY,
        .motion = {.known = 1, .host_timestamp_us = 888, .gyro_y = 56},
        .motion_known = 1,
    };
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    for (int i = 0; i < 100; i++) {
        if (s2a_mac_ns2_read_motion(&motion) && motion.host_timestamp_us == 888) break;
        usleep(1000);
    }
    assert(motion.host_timestamp_us == 888 && motion.gyro_y == 56);

    uint64_t relay_session = s2a_mac_ns2_rumble_session();
    assert(relay_session);
    s2a_mac_ns2_set_rumble_pair(relay_session, pair);
    memset(&packet, 0, sizeof packet);
    assert(receive_all(relay, &packet, sizeof packet));
    assert(packet.type == NS2_RELAY_RUMBLE && packet.duration_ms == 1000);
    assert(fabsf(packet.vibration[0].low_amp - s2a_hp_feel(.2f) * .7f) < .0001f);
    assert(fabsf(packet.vibration[1].high_amp - .7f) < .0001f && packet.vibration[1].high_freq == 640);
    setenv("S2A_RUMBLE_SCALE", "1.8", 1);
    assert(s2a_mac_ns2_connect());
    s2a_mac_ns2_set_rumble_pair(relay_session, pair);
    assert(receive_all(relay, &packet, sizeof packet));
    assert(packet.vibration[0].low_amp == 1 && packet.vibration[0].low_freq == 160);
    unsetenv("S2A_RUMBLE_SCALE");

    // 震动按玩家（#520 E）：两只 Joy-Con 拆开时，玩家 2（右只）的震动只到第 1 侧；玩家 1（左只）的照旧在第 0 侧，两份合在同一包、不互相盖掉
    packet = (ns2_relay_packet){.magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT, .ready = 1, .status = NS2_STATUS_READY, .kind = NS2_KIND_JOYCON_L};
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    packet.player = 1; packet.kind = NS2_KIND_JOYCON_R;
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    for (int i = 0; i < 100 && !s2a_mac_ns2_player_present(1); i++) usleep(1000);
    assert(s2a_mac_ns2_player_present(1));
    for (int i = 0; i < 100 && s2a_mac_ns2_kind() != NS2_KIND_JOYCON_L; i++) usleep(1000);
    // 玩家 2 起的单只 Joy-Con 照它那一格的样式（#520：拆开的两只握法一致，同玩家 1）：没报样式 → 转横握；那一格是双 Joy-Con → 原样给、不转；
    //   负对照：那一格扮 Pro → 照旧转横握
    {
        ns2_state st; uint32_t sk; ns2_kind k;
        int before = sideways_calls;
        assert(s2a_mac_ns2_read_player(1, &st, &sk, &k) && k == NS2_KIND_JOYCON_R && sideways_calls == before + 1);
        s2a_mac_ns2_set_player_style(1, 1 << 2);   // JoyconPair
        assert(s2a_mac_ns2_read_player(1, &st, &sk, &k) && sideways_calls == before + 1);
        s2a_mac_ns2_set_player_style(1, 1 << 0);   // ProController
        assert(s2a_mac_ns2_read_player(1, &st, &sk, &k) && sideways_calls == before + 2);
        s2a_mac_ns2_set_player_style(1, 0);
    }
    // 玩家 2 那包带的鼠标（#520：两人各拿一只，玩家 2 也要滑得动）：照它那只的那一侧给；负对照：没带鼠标的玩家只报在、没读数
    {
        ns2_relay_packet pm = (ns2_relay_packet){.magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT, .ready = 1, .status = NS2_STATUS_READY,
            .kind = NS2_KIND_JOYCON_R, .player = 1, .mouse_kind = NS2_KIND_JOYCON_R, .mouse = {.x = 321, .y = -5}};
        assert(send(relay, &pm, sizeof pm, 0) == sizeof pm);
        s2a_pad_mouse ms[2] = {{0}};
        for (int i = 0; i < 100 && !(s2a_mac_ns2_read_mouse_player(1, ms) && ms[1].known && ms[1].x == 321); i++) usleep(1000);
        assert(ms[1].known && ms[1].x == 321 && ms[1].y == -5 && ms[0].side == 0xff);
        pm.mouse_kind = 0;
        assert(send(relay, &pm, sizeof pm, 0) == sizeof pm);
    }
    s2a_mac_ns2_stop_rumble(s2a_mac_ns2_rumble_session());   // 清掉前面几项留下的玩家 1 震动
    memset(&packet, 0, sizeof packet);
    assert(receive_all(relay, &packet, sizeof packet) && packet.type == NS2_RELAY_STOP_RUMBLE);
    s2a_pad_vibration p2[2] = {{.low_amp = .4f, .low_hz = 160, .high_amp = .4f, .high_hz = 320}, {0}};
    s2a_mac_ns2_set_rumble_player(1, p2);
    memset(&packet, 0, sizeof packet);
    assert(receive_all(relay, &packet, sizeof packet) && packet.type == NS2_RELAY_RUMBLE);
    assert(packet.vibration[1].low_amp > 0 && packet.vibration[0].low_amp == 0);   // 只震右只那一侧
    s2a_pad_vibration p1[2] = {{.low_amp = .3f, .low_hz = 160, .high_amp = 0, .high_hz = 320}, {.low_amp = .3f, .low_hz = 160}};
    s2a_mac_ns2_set_rumble_pair(s2a_mac_ns2_rumble_session(), p1);
    assert(receive_all(relay, &packet, sizeof packet) && packet.type == NS2_RELAY_RUMBLE);
    assert(packet.vibration[0].low_amp > 0 && packet.vibration[1].low_amp > 0);   // 玩家 1 的左只 + 玩家 2 的右只一起
    // 第二组（玩家 3）：单独一包、头部 player = 2，第一组的两侧不受影响
    packet = (ns2_relay_packet){.magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT, .ready = 1, .status = NS2_STATUS_READY, .kind = NS2_KIND_PRO, .player = 2};
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    for (int i = 0; i < 100 && !s2a_mac_ns2_player_present(2); i++) usleep(1000);
    assert(s2a_mac_ns2_player_present(2));
    s2a_mac_ns2_set_rumble_player(2, p2);
    memset(&packet, 0, sizeof packet);
    assert(receive_all(relay, &packet, sizeof packet) && packet.type == NS2_RELAY_RUMBLE && packet.player == 2);
    assert(packet.vibration[0].low_amp > 0 && packet.vibration[1].low_amp == 0);   // Pro：两侧照游戏给的（这里只给了左侧）
    s2a_mac_ns2_set_rumble_player(NS2_RELAY_PLAYERS + 3, p2);   // 负对照：超范围玩家号不发
    // 体感按玩家（#520）：玩家 3 的六轴只出在玩家 3，玩家 1 的不被盖掉；负对照：没连的玩家 4、超范围、玩家 0 走原来的 read_motion
    packet = (ns2_relay_packet){.magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT, .ready = 1, .status = NS2_STATUS_READY, .kind = NS2_KIND_PRO, .player = 2,
        .motion = {.known = 1, .host_timestamp_us = 999, .gyro_x = 77, .acceleration_z = 1}, .motion_known = 1};
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    s2a_pad_motion m3 = {0};
    for (int i = 0; i < 100 && !(s2a_mac_ns2_read_motion_player(2, &m3) && m3.gyro_x == 77); i++) usleep(1000);
    assert(m3.gyro_x == 77 && m3.acceleration_z == 1);
    assert(!s2a_mac_ns2_read_motion_player(3, &m3) && !s2a_mac_ns2_read_motion_player(NS2_RELAY_PLAYERS, &m3) && !s2a_mac_ns2_read_motion_player(0, &m3));
    assert(!s2a_mac_ns2_read_motion(&motion) || motion.gyro_x != 77);

    s2a_mac_ns2_detach();
    assert(shutdowns == 2); // Closing a game socket leaves the physical relay alive.
    shutdown(relay, SHUT_RDWR);
    close(relay);
    close(listener);

    listener = make_listener(socket_path);
    assert(s2a_mac_ns2_connect());
    relay = accept(listener, NULL, NULL);
    assert(relay >= 0);

    // The launcher helper restarts while the game keeps running: the game reattaches to the new relay.
    close(relay);
    close(listener);
    for (int i = 0; i < 100 && s2a_mac_ns2_status() != NS2_STATUS_DISCONNECTED; i++) usleep(1000);
    assert(s2a_mac_ns2_status() == NS2_STATUS_DISCONNECTED);
    listener = make_listener(socket_path);
    assert(s2a_mac_ns2_connect());
    relay = accept(listener, NULL, NULL);
    assert(relay >= 0);
    packet = (ns2_relay_packet){
        .magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT,
        .epoch = 10, .state = {.buttons = 2}, .ready = 1, .status = NS2_STATUS_READY,
    };
    assert(send(relay, &packet, sizeof packet, 0) == sizeof packet);
    for (int i = 0; i < 100 && !(s2a_mac_ns2_read(&input, NULL) && input.buttons == 2); i++) usleep(1000);
    assert(input.buttons == 2);
    s2a_mac_ns2_disconnect();
    memset(&packet, 0, sizeof packet);
    assert(receive_all(relay, &packet, sizeof packet));
    assert(packet.magic == NS2_RELAY_MAGIC && packet.type == NS2_RELAY_DISCONNECT);
    close(relay);
    close(listener);
    unlink(socket_path);
    unsetenv("S2A_NS2_SOCKET");

    puts("✓ t_mac_ns2：direct and relay input, motion, paired rumble, detach, reconnect, helper restart, explicit disconnect");
}
