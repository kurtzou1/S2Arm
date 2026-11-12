// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#include "ns2_relay.h"
#include "ns2_parent_watch.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static dispatch_source_t terminateSource;
static dispatch_source_t interruptSource;
static dispatch_source_t acceptSource;
static dispatch_source_t relayTimer;
static int listenFD = -1;
static int clientFD = -1;
static const char *socketPath;
static pthread_mutex_t relayLock = PTHREAD_MUTEX_INITIALIZER;
static ns2_relay_packet snapshot;

static void *parent_watch_main(void *context) {
    if (s2a_ns2_wait_for_parent_exit((pid_t)(intptr_t)context)) {
        if (socketPath) unlink(socketPath);
        ns2_shutdown("S2Arm launcher closed", 200);
        _exit(0);
    }
    return NULL;
}

static void emit_status(ns2_status status, const char *message, void *context) {
    (void)context;
    @autoreleasepool {
        pthread_mutex_lock(&relayLock);
        int wasReady = snapshot.ready;
        snapshot.status = status;
        snapshot.ready = status == NS2_STATUS_READY;
        snapshot.kind = (uint8_t)ns2_get_output_kind();
        if (wasReady != snapshot.ready) {
            snapshot.epoch++;
            memset(&snapshot.state, 0, sizeof snapshot.state);
            memset(&snapshot.motion, 0, sizeof snapshot.motion);
            snapshot.motion_known = 0;
        }
        pthread_mutex_unlock(&relayLock);

        ns2_info info = {0};
        ns2_get_info(&info);
        NSMutableDictionary *payload = [@{
            @"status": @(status),
            @"message": message ? [NSString stringWithUTF8String:message] ?: @"" : @"",
            @"name": info.name[0] ? [NSString stringWithUTF8String:info.name] ?: @"" : @"",
            @"identifier": info.identifier[0] ? [NSString stringWithUTF8String:info.identifier] ?: @"" : @"",
            @"kind": @(ns2_get_output_kind()),   // ns2_kind：1 Pro、2 Joy-Con 左、3 右、4 左右一对（启动器面板标题，#520）
        } mutableCopy];
        if (info.battery_level_known) payload[@"battery"] = @(info.battery_level);
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!data) return;
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static void receive_input(const ns2_state *state, void *context) {
    (void)context;
    ns2_kind kind = ns2_get_output_kind();   // 拼对 / 拆对不一定伴随状态变化，跟着输入刷新
    pthread_mutex_lock(&relayLock);
    if (snapshot.ready) snapshot.state = *state;
    snapshot.kind = (uint8_t)kind;
    pthread_mutex_unlock(&relayLock);
}

static void receive_motion(const ns2_motion *motion, void *context) {
    (void)context;
    pthread_mutex_lock(&relayLock);
    snapshot.motion = *motion;
    snapshot.motion_known = motion->known;
    pthread_mutex_unlock(&relayLock);
}

static void stop_client(int fd) {
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
}

static void drop_client(int fd) {
    int current = -1;
    pthread_mutex_lock(&relayLock);
    if (clientFD == fd) {
        current = clientFD;
        clientFD = -1;
    }
    pthread_mutex_unlock(&relayLock);
    stop_client(current);
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

static void *client_main(void *context) {
    int fd = (int)(intptr_t)context;
    ns2_relay_packet packet;
    while (receive_all(fd, &packet, sizeof packet)) {
        if (packet.magic != NS2_RELAY_MAGIC || packet.version != NS2_RELAY_VERSION) {
            fprintf(stderr, "[NS2 Relay] 游戏端通道版本 %u，本端 %u：断开（启动器与游戏宿主版本不一致）\n", packet.version, NS2_RELAY_VERSION);
            break;
        }
        switch (packet.type) {
        case NS2_RELAY_RUMBLE:
            ns2_send_pair_lease(packet.vibration, packet.duration_ms);
            break;
        case NS2_RELAY_MOTION:
            ns2_set_motion_enabled(packet.enabled);
            break;
        case NS2_RELAY_STOP_RUMBLE:
            ns2_stop_rumble();
            break;
        case NS2_RELAY_DISCONNECT:
            ns2_set_motion_enabled(0);
            ns2_stop_rumble();
            ns2_shutdown("Disconnected from S2Arm controller settings", 750);
            unlink(socketPath);
            exit(0);
        default:
            break;
        }
    }
    pthread_mutex_lock(&relayLock);
    int owned = clientFD == fd;
    if (owned) clientFD = -1;
    pthread_mutex_unlock(&relayLock);
    if (owned) {
        ns2_set_motion_enabled(0);
        ns2_stop_rumble();
    }
    close(fd);
    return NULL;
}

static void send_snapshot(void) {
    int fd;
    ns2_relay_packet packet;
    pthread_mutex_lock(&relayLock);
    fd = clientFD;
    packet = snapshot;
    pthread_mutex_unlock(&relayLock);
    if (fd < 0) return;
    // Joy-Con 2 拼成一对：左只的六轴放进 INPUT 包的 motion_left（motion 是右只的，ns2_relay.h）
    ns2_motion left = {0};
    if (packet.ready) ns2_get_motion_left(&left);
    packet.motion_left_known = left.known ? 1 : 0;
    if (left.known) packet.motion_left = (ns2_relay_motion_left){left.acceleration_x, left.acceleration_y, left.acceleration_z, left.gyro_x, left.gyro_y, left.gyro_z,
        (uint32_t)left.host_timestamp_us, (uint32_t)(left.host_timestamp_us >> 32)};

    // Joy-Con 2 光学鼠标：放进 INPUT 包的 mouse（ns2_relay.h；旧宿主不读这段）。只有一份位置：拼成一对、两只都有读数时一包左一包右轮流
    //   （mouse_kind 标是哪一只；坐标是绝对值，宿主按一侧各自求差，轮流只是每侧取样减半）
    static unsigned mouseTurn;
    ns2_mouse mouse = {0}, sides[2] = {{0}};
    if (packet.ready) { ns2_get_mouse_side(0, &sides[0]); ns2_get_mouse_side(1, &sides[1]); }
    if (sides[0].known && sides[1].known) mouse = sides[mouseTurn++ & 1];
    else mouse = sides[1].known ? sides[1] : sides[0];
    packet.mouse_kind = mouse.known ? (uint8_t)mouse.kind : 0;
    if (mouse.known) packet.mouse = (ns2_relay_mouse){mouse.x, mouse.y, mouse.surface, mouse.distance};

    ssize_t sent = send(fd, &packet, sizeof packet, MSG_DONTWAIT);
    if (sent != (ssize_t)sizeof packet) drop_client(fd);
}

static int create_listener(const char *path) {
    struct sockaddr_un address = {0};
    size_t length = strlen(path);
    if (length == 0) {
        errno = EINVAL;
        return -1;
    }
    if (length >= sizeof address.sun_path) {
        errno = ENAMETOOLONG;
        return -1;
    }
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, length + 1);
    mode_t previous = umask(077);
    int failed = bind(fd, (struct sockaddr *)&address, sizeof address) ||
        listen(fd, 2) || chmod(path, 0600);
    umask(previous);
    if (failed) {
        close(fd);
        unlink(path);
        return -1;
    }
    return fd;
}

static void start_relay(const char *path) {
    listenFD = create_listener(path);
    if (listenFD < 0) {
        fprintf(stderr, "[NS2 Relay] Could not listen on %s: %s\n", path, strerror(errno));
        emit_status(NS2_STATUS_ERROR, strerror(errno), NULL);
        exit(1);
    }

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)listenFD, 0, queue);
    dispatch_source_set_event_handler(acceptSource, ^{
        int fd = accept(listenFD, NULL, NULL);
        if (fd < 0) return;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        pthread_mutex_lock(&relayLock);
        int previous = clientFD;
        clientFD = fd;
        memset(&snapshot.motion, 0, sizeof snapshot.motion);
        snapshot.motion_known = 0;
        pthread_mutex_unlock(&relayLock);
        stop_client(previous);
        pthread_t thread;
        if (!pthread_create(&thread, NULL, client_main, (void *)(intptr_t)fd)) pthread_detach(thread);
        else drop_client(fd);
    });
    dispatch_resume(acceptSource);

    relayTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(relayTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 8 * NSEC_PER_MSEC,
                              NSEC_PER_MSEC);
    dispatch_source_set_event_handler(relayTimer, ^{ send_snapshot(); });
    dispatch_resume(relayTimer);
}

static dispatch_source_t install_shutdown_signal(int signo) {
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signo, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        if (relayTimer) dispatch_source_cancel(relayTimer);
        if (listenFD >= 0) close(listenFD);
        if (socketPath) unlink(socketPath);
        ns2_shutdown("S2Arm controller disconnected", 750);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ exit(0); });
    });
    signal(signo, SIG_IGN);
    dispatch_resume(source);
    return source;
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        socketPath = getenv("S2A_NS2_SOCKET");
        if (!socketPath || !*socketPath) {
            fprintf(stderr, "[NS2 Relay] S2A_NS2_SOCKET is required\n");
            return 1;
        }
        memset(&snapshot, 0, sizeof snapshot);
        snapshot.magic = NS2_RELAY_MAGIC;
        snapshot.version = NS2_RELAY_VERSION;
        snapshot.type = NS2_RELAY_INPUT;

        terminateSource = install_shutdown_signal(SIGTERM);
        interruptSource = install_shutdown_signal(SIGINT);
        pthread_t parentWatch;
        if (!pthread_create(&parentWatch, NULL, parent_watch_main, (void *)(intptr_t)getppid()))
            pthread_detach(parentWatch);
        start_relay(socketPath);
        if (!ns2_start_with_motion(receive_input, emit_status, receive_motion, NULL)) {
            emit_status(NS2_STATUS_ERROR, "Could not start the controller connection", NULL);
            close(listenFD);
            unlink(socketPath);
            return 1;
        }
        ns2_set_motion_enabled(0);
        dispatch_main();
    }
    return 0;
}
