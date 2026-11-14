// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
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
// 玩家 2（两只 Joy-Con 各一位玩家时槽 1 那只，#520 D）：头部同 snapshot、player = 1；只带按键 / 摇杆 / 型号（体感 / 鼠标 / 震动跟玩家 1 走）
static ns2_relay_packet second;
// 最多 4 只（#520 E，#520）：启动器另起第二个连接程序管第二组。
//   本程序是第一个时（S2A_NS2_SIDE_SOCKET）：旁路 socket 收第二个的玩家 0 / 1，发给游戏时当玩家 2 / 3；游戏给玩家 2 起的震动转回去。
//   本程序是第二个时（S2A_NS2_UPSTREAM）：不收游戏，连到第一个的旁路 socket，自己的快照照样发（对方改玩家号）
// 最多 8 组（同原机最多 8 只手柄）：第 k 组（k ≥ 1）是另起的连接程序，它自己的玩家号已是 2k / 2k+1（S2A_NS2_GROUP）
enum { HELPER_GROUPS = NS2_RELAY_PLAYERS / 2 };
static int sideListenFD = -1;
static int sideFD[HELPER_GROUPS];    // 第 k 组那个连接程序的连线（第一个连接程序才用；-1 = 没接）
static ns2_relay_packet extra[NS2_RELAY_PLAYERS];   // 其他组的玩家（照它们报的玩家号存）
static int extraDirty[NS2_RELAY_PLAYERS];           // 有新的一包要转（含 ready = 0 的收尾）
static const char *upstreamPath;
static int helperGroup;              // 本程序是第几组（0 = 第一个，收游戏）
// 收不收这台（两个连接程序别抢同一台）：exclude = 对方已占的 id；missing = 对方只有单只 Joy-Con、还在等的另一侧（留给它）
static pthread_mutex_t filterLock = PTHREAD_MUTEX_INITIALIZER;
static NSSet<NSString *> *excludedIDs;
static ns2_kind reservedKind = NS2_KIND_NONE;
static int accept_filter(ns2_kind kind, const char *identifier, void *context) {
    (void)context;
    pthread_mutex_lock(&filterLock);
    BOOL excluded = identifier && [excludedIDs containsObject:@(identifier)];
    BOOL reserved = reservedKind != NS2_KIND_NONE && kind == reservedKind;
    pthread_mutex_unlock(&filterLock);
    if (excluded || reserved) fprintf(stderr, "[NS2 Relay] 这台%s，不连：%s\n", excluded ? "已由另一个连接程序占着" : "是另一个连接程序在等的那一侧", identifier ?: "?");
    return !(excluded || reserved);
}

static void *parent_watch_main(void *context) {
    if (s2a_ns2_wait_for_parent_exit((pid_t)(intptr_t)context)) {
        if (socketPath) unlink(socketPath);
        ns2_shutdown("S2Arm launcher closed", 200);
        _exit(0);
    }
    return NULL;
}

static NSArray<NSNumber *> *player_kinds(void) {
    NSMutableArray<NSNumber *> *kinds = [NSMutableArray arrayWithObject:@(ns2_get_output_kind())];
    if (ns2_get_joycon_split()) {
        pthread_mutex_lock(&relayLock);
        uint8_t second_kind = second.kind;
        pthread_mutex_unlock(&relayLock);
        // 玩家 2 那只还没出过输入时型号未知：照槽 1 的推（玩家 1 是左只，玩家 2 就是右只，反之亦然）
        if (!second_kind) second_kind = ns2_get_output_kind() == NS2_KIND_JOYCON_L ? NS2_KIND_JOYCON_R : NS2_KIND_JOYCON_L;
        [kinds addObject:@(second_kind)];
    }
    return kinds;
}

static NSArray<NSDictionary *> *device_list(void) {
    ns2_device devices[2];
    int n = ns2_get_devices(devices);
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < n; i++) [out addObject:@{@"id": @(devices[i].identifier), @"kind": @(devices[i].kind), @"link": @(devices[i].link)}];
    return out;
}

static void emit_line(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    @synchronized ([NSFileHandle class]) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}

// 分配玩家：每只 NS2 手柄的登记手势一变就报给启动器（启动器配成玩家、排顺序；NS2Transport.h ns2_assign_gesture）
static void receive_assign(int link, ns2_kind kind, ns2_assign_gesture gesture, const char *identifier, void *context) {
    (void)context;
    emit_line(@{@"assign": @{@"link": @(link), @"kind": @(kind), @"gesture": @(gesture), @"id": @(identifier ?: "")}});
}

// 分配完成（启动器 stdin `assign done {json}`）：split = 两只 Joy-Con 各一位玩家、first = 玩家 1 那只的 id、keep = 登记了的 id；没登记的断开（同原机）
static void apply_assignment(NSDictionary *plan) {
    ns2_set_assign_mode(0);
    NSArray<NSString *> *keep = [plan[@"keep"] isKindOfClass:NSArray.class] ? plan[@"keep"] : @[];
    ns2_device devices[2];
    int n = ns2_get_devices(devices);
    NSString *first = [plan[@"first"] isKindOfClass:NSString.class] ? plan[@"first"] : nil;
    for (int i = 0; i < n; i++) if (first && [first isEqualToString:@(devices[i].identifier)]) ns2_set_player_order(devices[i].link);
    ns2_set_joycon_split([plan[@"split"] boolValue]);
    for (int i = 0; i < n; i++) {
        NSString *identifier = @(devices[i].identifier);
        if (![keep containsObject:identifier]) ns2_disconnect_device(devices[i].identifier);
    }
    fprintf(stderr, "[NS2 Relay] 分配玩家完成：%s、玩家 1 = %s、保留 %lu 只\n", [plan[@"split"] boolValue] ? "各一位玩家" : "拼成一对",
            first.UTF8String ?: "-", (unsigned long)keep.count);
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
            @"players": @(ns2_get_joycon_split() ? 2 : 1),   // 两只 Joy-Con 各一位玩家时 2（面板标题「2 位玩家」，#520 D）
            @"kinds": player_kinds(),   // 每位玩家的型号（面板「玩家」列表；P1 起）
            @"devices": device_list(),   // 已就绪的 NS2 手柄（id、型号、链路），分配玩家按 id 认（#520 E）
        } mutableCopy];
        if (info.battery_level_known) payload[@"battery"] = @(info.battery_level);
        emit_line(payload);   // 与分配回报同一把锁写，一行一条 JSON 不交错
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

static void receive_player(int player, ns2_kind kind, const ns2_state *state, void *context) {
    (void)context;
    if (player != 1) return;
    pthread_mutex_lock(&relayLock);
    second.ready = state != NULL;
    second.status = state ? NS2_STATUS_READY : NS2_STATUS_DISCONNECTED;
    second.kind = state ? (uint8_t)kind : NS2_KIND_NONE;
    second.state = state ? *state : (ns2_state){0};
    pthread_mutex_unlock(&relayLock);
}

// 两只 Joy-Con 拆开 / 拼回（面板改设定、游戏里按 SL + SR）：照现在的状态再报一次，面板标题跟着变
static void report_players(void) {
    static int last = -1;
    int now = ns2_get_joycon_split();
    if (now == last) return;
    last = now;
    pthread_mutex_lock(&relayLock);
    ns2_status status = (ns2_status)snapshot.status;
    pthread_mutex_unlock(&relayLock);
    if (status == NS2_STATUS_READY) emit_status(status, now ? "Connected: two Joy-Con 2, one player each" : "Connected: Joy-Con 2 pair (left + right)", NULL);
}

// 启动器 stdin 的命令（一行一条，launchers NS2LauncherController）：assign start / cancel / done {json}（分配玩家）、exclude / missing（两个连接程序别抢同一台）。
//   认不出的行记一笔、照常跑；stdin 关了（启动器退出）就不再读
static void *stdin_main(void *context) {
    (void)context;
    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        if (!strncmp(line, "exclude", 7)) {   // exclude id id …：另一个连接程序占着的，不连
            NSMutableSet *ids = [NSMutableSet set];
            for (NSString *part in [[[NSString stringWithUTF8String:line + 7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@" "])
                if (part.length) [ids addObject:part];
            pthread_mutex_lock(&filterLock); excludedIDs = ids; pthread_mutex_unlock(&filterLock);
            continue;
        }
        if (!strncmp(line, "missing", 7)) {   // missing L / R / none：另一个连接程序还在等的那一侧 Joy-Con，留给它
            const char *k = line + 7; while (*k == ' ') k++;
            pthread_mutex_lock(&filterLock);
            reservedKind = *k == 'L' ? NS2_KIND_JOYCON_L : *k == 'R' ? NS2_KIND_JOYCON_R : NS2_KIND_NONE;
            pthread_mutex_unlock(&filterLock);
            continue;
        }
        if (!strncmp(line, "assign start", 12)) { ns2_set_assign_mode(1); ns2_rescan(); continue; }   // 分配中继续搜，好接更多手柄
        if (!strncmp(line, "assign cancel", 13)) { ns2_set_assign_mode(0); continue; }
        if (!strncmp(line, "assign done ", 12)) {
            NSData *json = [[NSString stringWithUTF8String:line + 12] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *plan = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
            if ([plan isKindOfClass:NSDictionary.class]) apply_assignment(plan);
            else { ns2_set_assign_mode(0); fprintf(stderr, "[NS2 Relay] 分配结果读不懂，照原样：%s", line); }
            continue;
        }
        fprintf(stderr, "[NS2 Relay] 启动器命令认不出：%s", line);
    }
    return NULL;
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

static int create_listener(const char *path);
// 第一个连接程序：把游戏给第 group 组的命令转给管那组的连接程序（玩家号照原样，对方自己认）；那组没接就丢
static void forward_side(const ns2_relay_packet *packet, int group) {
    if (group < 1 || group >= HELPER_GROUPS) return;
    pthread_mutex_lock(&relayLock);
    int fd = sideFD[group];
    pthread_mutex_unlock(&relayLock);
    if (fd < 0) return;
    if (send(fd, packet, sizeof *packet, MSG_DONTWAIT) != (ssize_t)sizeof *packet) fprintf(stderr, "[NS2 Relay] 转给第 %d 组连接程序失败\n", group + 1);
}

// 第一个连接程序：读别组连接程序送来的快照（玩家号已是 2k / 2k+1），记下来由 send_snapshot 照转给游戏；第一包认出它是第几组
static void *side_main(void *context) {
    int fd = (int)(intptr_t)context, group = -1;
    ns2_relay_packet packet;
    while (receive_all(fd, &packet, sizeof packet)) {
        if (packet.magic != NS2_RELAY_MAGIC || packet.version != NS2_RELAY_VERSION || packet.type != NS2_RELAY_INPUT) continue;
        int p = packet.player, g = p / 2;
        if (g < 1 || g >= HELPER_GROUPS || (group >= 0 && g != group)) continue;
        pthread_mutex_lock(&relayLock);
        if (group < 0) {
            group = g;
            int previous = sideFD[g]; sideFD[g] = fd;
            if (previous >= 0 && previous != fd) shutdown(previous, SHUT_RDWR);
            fprintf(stderr, "[NS2 Relay] 第 %d 组连接程序接上（玩家 %d / %d）\n", g + 1, 2 * g + 1, 2 * g + 2);
        }
        extra[p] = packet;   // 体感、鼠标照带（每位玩家都有，#520）
        extra[p].motion_left_known = 0;
        extraDirty[p] = 1;
        pthread_mutex_unlock(&relayLock);
    }
    pthread_mutex_lock(&relayLock);
    if (group >= 0) {
        if (sideFD[group] == fd) sideFD[group] = -1;
        for (int p = group * 2; p < group * 2 + 2; p++)
            if (extra[p].ready) { extra[p].ready = 0; extra[p].status = NS2_STATUS_DISCONNECTED; memset(&extra[p].state, 0, sizeof extra[p].state); extraDirty[p] = 1; }
    }
    pthread_mutex_unlock(&relayLock);
    close(fd);
    fprintf(stderr, "[NS2 Relay] 第 %d 组连接程序断开\n", group + 1);
    return NULL;
}

static void start_side(const char *path) {
    sideListenFD = create_listener(path);
    if (sideListenFD < 0) { fprintf(stderr, "[NS2 Relay] 旁路 socket 开不了（%s）：只管一组手柄\n", strerror(errno)); return; }
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)sideListenFD, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_event_handler(source, ^{
        int fd = accept(sideListenFD, NULL, NULL);
        if (fd < 0) return;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        pthread_t thread;   // 第几组等第一包再认（side_main）
        if (!pthread_create(&thread, NULL, side_main, (void *)(intptr_t)fd)) pthread_detach(thread);
        else close(fd);
    });
    dispatch_resume(source);
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
            if (!upstreamPath && packet.player >= 2) { forward_side(&packet, packet.player / 2); break; }   // 别组的玩家：转给管那组的连接程序
            ns2_send_pair_lease(packet.vibration, packet.duration_ms);
            break;
        case NS2_RELAY_MOTION:
            ns2_set_motion_enabled(packet.enabled);
            break;
        case NS2_RELAY_STOP_RUMBLE:
            ns2_stop_rumble();
            if (!upstreamPath) for (int g = 1; g < HELPER_GROUPS; g++) forward_side(&packet, g);
            break;
        case NS2_RELAY_DISCONNECT:
            if (!upstreamPath) for (int g = 1; g < HELPER_GROUPS; g++) forward_side(&packet, g);
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
    // 两只 Joy-Con 各一位玩家：玩家 2 那包跟着发；拼回一对 / 断开时补一包 ready = 0，宿主才会收掉玩家 2 的槽
    int split = ns2_get_joycon_split();
    report_players();
    ns2_relay_packet player2;
    pthread_mutex_lock(&relayLock);
    fd = clientFD;
    packet = snapshot;
    if (!split && second.ready) { second.ready = 0; second.kind = NS2_KIND_NONE; memset(&second.state, 0, sizeof second.state); second.status = NS2_STATUS_DISCONNECTED; }
    static int secondSent;   // 上一拍发过玩家 2：拆开期间每拍发，结束后再发一包收尾（ready = 0）
    int sendSecond = split || secondSent;
    secondSent = split;
    player2 = second;
    pthread_mutex_unlock(&relayLock);
    // 拆开时玩家 2 的六轴（#520：每位玩家都有体感）
    if (split) {
        ns2_motion m = {0};
        ns2_get_partner_motion(&m);
        player2.motion = m; player2.motion_known = m.known ? 1 : 0;
        // 玩家 2 那只的光学鼠标（#520：两人各拿一只的项目，玩家 2 也要滑得动、游戏认得它是 Joy-Con 2）
        ns2_mouse pm = {0};
        if (player2.ready && (player2.kind == NS2_KIND_JOYCON_L || player2.kind == NS2_KIND_JOYCON_R)) ns2_get_mouse_side(player2.kind == NS2_KIND_JOYCON_R, &pm);
        player2.mouse_kind = pm.known ? (uint8_t)pm.kind : 0;
        if (pm.known) player2.mouse = (ns2_relay_mouse){pm.x, pm.y, pm.surface, pm.distance};
    }
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
    if (split) mouse = sides[packet.kind == NS2_KIND_JOYCON_R];   // 各一位玩家：玩家 1 只带自己那只的鼠标
    else if (sides[0].known && sides[1].known) mouse = sides[mouseTurn++ & 1];
    else mouse = sides[1].known ? sides[1] : sides[0];
    packet.mouse_kind = mouse.known ? (uint8_t)mouse.kind : 0;
    if (mouse.known) packet.mouse = (ns2_relay_mouse){mouse.x, mouse.y, mouse.surface, mouse.distance};

    ssize_t sent = send(fd, &packet, sizeof packet, MSG_DONTWAIT);
    if (sent != (ssize_t)sizeof packet) { drop_client(fd); return; }
    if (sendSecond) {
        sent = send(fd, &player2, sizeof player2, MSG_DONTWAIT);
        if (sent != (ssize_t)sizeof player2) { drop_client(fd); return; }
    }
    // 别组的玩家（玩家号 2 起）：连着就每拍发，断了补一包 ready = 0
    for (int p = 2; p < NS2_RELAY_PLAYERS; p++) {
        ns2_relay_packet x;
        pthread_mutex_lock(&relayLock);
        int due = extraDirty[p] || extra[p].ready;
        x = extra[p]; extraDirty[p] = 0;
        pthread_mutex_unlock(&relayLock);
        if (!due || x.magic != NS2_RELAY_MAGIC) continue;
        if (send(fd, &x, sizeof x, MSG_DONTWAIT) != (ssize_t)sizeof x) { drop_client(fd); return; }
    }
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

// 第二个连接程序：连到第一个的旁路 socket（连不上 / 断了每秒再试），之后它就是本程序的「游戏端」
static void connect_upstream(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_source_t retry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(retry, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(retry, ^{
        pthread_mutex_lock(&relayLock); int have = clientFD >= 0; pthread_mutex_unlock(&relayLock);
        if (have) return;
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        if (strlen(upstreamPath) >= sizeof address.sun_path) return;
        strcpy(address.sun_path, upstreamPath);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        if (connect(fd, (struct sockaddr *)&address, sizeof address)) { close(fd); return; }
        pthread_mutex_lock(&relayLock); clientFD = fd; pthread_mutex_unlock(&relayLock);
        pthread_t thread;
        if (!pthread_create(&thread, NULL, client_main, (void *)(intptr_t)fd)) pthread_detach(thread);
        fprintf(stderr, "[NS2 Relay] 第 %d 组连接程序：已接到第一个（本组 = 游戏的玩家 %d / %d）\n", helperGroup + 1, 2 * helperGroup + 1, 2 * helperGroup + 2);
    });
    dispatch_resume(retry);
    relayTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(relayTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 8 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(relayTimer, ^{ send_snapshot(); });
    dispatch_resume(relayTimer);
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

// 启动器「记住这台设备」（#521）：S2A_NS2_REMEMBER_DEVICE=1 时取本机蓝牙地址交给传输层，长按 SYNC 连上的手柄会记住这台 Mac。
//   绑定写在真正持有 BLE 连接的这个进程里。读不到地址就跳过绑定、照旧可用，记一行日志
static void configure_bonding(void) {
    const char *wanted = getenv("S2A_NS2_REMEMBER_DEVICE");
    if (!wanted || strcmp(wanted, "1")) return;
    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSString *text = IOBluetoothHostController.defaultController.addressAsString;   // "aa-bb-cc-dd-ee-ff"
    uint8_t host[6];
    if (!ns2_parse_bt_address(text.UTF8String, host)) {
        fprintf(stderr, "[NS2 Relay] 记住这台设备：读不到本机蓝牙地址（%s），这次不写入绑定，手柄照常可用\n", text.UTF8String ?: "空");
        return;
    }
    fprintf(stderr, "[NS2 Relay] 记住这台设备：本机蓝牙地址已取得（%.0f ms）\n", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6);
    ns2_set_bond_host(host);
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
        upstreamPath = getenv("S2A_NS2_UPSTREAM");
        if (upstreamPath && !*upstreamPath) upstreamPath = NULL;
        if (!upstreamPath && (!socketPath || !*socketPath)) {
            fprintf(stderr, "[NS2 Relay] S2A_NS2_SOCKET is required\n");
            return 1;
        }
        memset(&snapshot, 0, sizeof snapshot);
        snapshot.magic = NS2_RELAY_MAGIC;
        snapshot.version = NS2_RELAY_VERSION;
        snapshot.type = NS2_RELAY_INPUT;
        // 第几组：第一个连接程序是 0；另起的由启动器给 S2A_NS2_GROUP（1–7），玩家号 2k / 2k+1
        const char *group = getenv("S2A_NS2_GROUP");
        helperGroup = group ? atoi(group) : 0;
        if (helperGroup < 0 || helperGroup >= HELPER_GROUPS) helperGroup = 0;
        for (int g = 0; g < HELPER_GROUPS; g++) sideFD[g] = -1;
        snapshot.player = (uint8_t)(helperGroup * 2);
        second = snapshot;
        second.player = (uint8_t)(helperGroup * 2 + 1);

        terminateSource = install_shutdown_signal(SIGTERM);
        interruptSource = install_shutdown_signal(SIGINT);
        pthread_t parentWatch;
        if (!pthread_create(&parentWatch, NULL, parent_watch_main, (void *)(intptr_t)getppid()))
            pthread_detach(parentWatch);
        if (upstreamPath) connect_upstream();
        else {
            start_relay(socketPath);
            const char *side = getenv("S2A_NS2_SIDE_SOCKET");
            if (side && *side) start_side(side);
        }
        ns2_set_accept_filter(accept_filter);
        configure_bonding();
        ns2_set_player_callback(receive_player);
        ns2_set_assign_callback(receive_assign);
        pthread_t commandThread;
        if (!pthread_create(&commandThread, NULL, stdin_main, NULL)) pthread_detach(commandThread);
        ns2_set_joycon_raw(1);   // 单只 Joy-Con 报原始方向（通道 v2），游戏宿主按游戏样式决定转不转（macos/ns2_controller.c，#520 A）
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
