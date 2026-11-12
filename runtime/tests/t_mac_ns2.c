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
    assert(!s2a_mac_ns2_read(&input) && !starts);
    s2a_mac_ns2_set_motion_enabled(1); // A game can request sensors before connection.
    assert(s2a_mac_ns2_connect() && starts == 1 && imu);
    s2a_mac_ns2_focus(1);
    status_callback(NS2_STATUS_READY, "test connected", NULL);
    assert(s2a_mac_ns2_kind() == NS2_KIND_JOYCON_L);   // 直连模式：型号取传输层的对外输出形态
    uint64_t session = s2a_mac_ns2_rumble_session();
    assert(session);
    // Physical Nintendo A, left stick up, and full independent right stick.
    ns2_state physical = {.buttons=1, .lx=-32767, .ly=32767, .rx=12345, .ry=-23456};
    input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input) && !memcmp(&input, &physical, sizeof input));
    s2a_mac_ns2_set_back_buttons(1u << 6, 1u << 7); // GL -> L; GR -> R.
    physical.buttons = (1ull << NS2_TEST_BUTTON_GL) | (1ull << NS2_TEST_BUTTON_GR) | 1;
    input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input));
    assert((input.buttons & 0xffff) == ((1u << 6) | (1u << 7) | 1));
    physical.buttons = 1; input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input) && (input.buttons & 0xffff) == 1);
    physical.buttons = 1ull << NS2_TEST_BUTTON_GL; input_callback(&physical, NULL);
    s2a_mac_ns2_set_back_buttons(1, 0); // Remapping a held paddle takes effect immediately.
    assert(s2a_mac_ns2_read(&input) && (input.buttons & 0xffff) == 1);
    s2a_mac_ns2_set_back_buttons(0, 0);
    assert(s2a_mac_ns2_read(&input) && !(input.buttons & 0xffff));
    physical.buttons = (1ull << 16) | (1ull << 17) | (1ull << 18);
    input_callback(&physical, NULL);
    assert(s2a_mac_ns2_read(&input) && !(input.buttons & 0xffff));
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
    assert(stops && !imu && !s2a_mac_ns2_rumble_session() && !s2a_mac_ns2_read(&input));
    assert(!s2a_mac_ns2_read_motion(&motion));
    s2a_mac_ns2_set_rumble_pair(session, pair); assert(sends == 1);
    s2a_mac_ns2_focus(1);
    assert(imu);
    assert(s2a_mac_ns2_rumble_session() != session);
    s2a_mac_ns2_set_rumble_pair(session, pair); assert(sends == 1);
    status_callback(NS2_STATUS_DISCONNECTED, "test disconnect", NULL);
    assert(!s2a_mac_ns2_read(&input) && !s2a_mac_ns2_rumble_session());
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
    for (int i = 0; i < 100 && !s2a_mac_ns2_read(&input); i++) usleep(1000);
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
    for (int i = 0; i < 100 && !(s2a_mac_ns2_read(&input) && input.buttons == 2); i++) usleep(1000);
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
