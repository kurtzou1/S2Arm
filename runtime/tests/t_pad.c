// 直接运行生产快照实现：短按、切源、断线、后台隔离与跨线程完整性。
#include "s2a_pad.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const int32_t zero[4];
// 仅触屏：直接调用生产写入/读取接口；覆盖 vpad 发布的全部 16 位与四轴。
// 历史 vpad 真函数的逐字段/录制对照由 support/touch_baseline_compare.py 另跑。
static void touch_only(void) {
    s2a_pad_set_active(0); s2a_pad_set_active(1);
    int32_t axes[4] = {-32767, 32767, -1, 1}, read[4];
    s2a_pad_source source;
    for (unsigned bit = 0; bit < 16; bit++) {
        uint32_t button = 1u << bit;
        s2a_pad_update(S2A_PAD_TOUCH, 1, button, axes);
        s2a_pad_update(S2A_PAD_TOUCH, 1, 0, axes);
        assert(s2a_pad_read(read, &source) == button);
        assert(source == S2A_PAD_TOUCH && !s2a_pad_has_controller());
        assert(!memcmp(read, axes, sizeof axes));
        assert(!s2a_pad_read(read, &source)); // 同一个短按只锁存一次。
    }
    // 同一读取间隔的不同短按按位并集；摇杆始终取最新一次完整四轴。
    const int32_t changed[4] = {32767, -32767, 12345, -23456};
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0x8421, axes);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, axes);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0x1248, changed);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, changed);
    s2a_pad_snapshot snapshot;
    s2a_pad_read_ex(&snapshot);
    assert(snapshot.source == S2A_PAD_TOUCH && snapshot.buttons == (0x8421 | 0x1248));
    assert(!memcmp(snapshot.axes, changed, sizeof changed));
    assert(!s2a_pad_read(read, &source));
    // 持有按钮跨多次 read/read_ex 不丢，释放后不重复锁存。
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0xffff, changed);
    for (int i = 0; i < 3; i++) {
        assert(s2a_pad_read(read, &source) == 0xffff);
        s2a_pad_read_ex(&snapshot); assert(snapshot.buttons == 0xffff);
        assert(!memcmp(snapshot.axes, changed, sizeof changed));
    }
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, zero);
    assert(!s2a_pad_read(read, &source));
    assert(!memcmp(read, zero, sizeof zero));
    s2a_pad_set_active(0); s2a_pad_set_active(1);
    puts("touch-only：16 位锁存、和弦、持有/释放、四轴与 read/read_ex 一致（生产接口向量，非触摸硬件实测）");
}
static void expect(uint32_t buttons, int32_t x, int32_t y) {
    int32_t axes[4]; assert(s2a_pad_read(axes, NULL) == buttons);
    assert(axes[0] == x && axes[1] == y && axes[2] == 0 && axes[3] == 0);
}
// 审计 P2-15：进程内重启（s2a_host_rebuild）清掉上一局的按键 / 摇杆快照、换输入纪元，但不改前后台状态：
//   活跃时清零后仍活跃（新局照收新输入）；不活跃（iOS 后台 / Mac 不走这套）时保持不活跃、写入仍被丢弃。期望手算
static void session_reset(void) {
    s2a_pad_set_active(0); s2a_pad_set_active(1);
    const int32_t held[4] = {32767, 0, 0, 0};
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0x10, held);
    s2a_pad_snapshot before, after; s2a_pad_read_ex(&before);
    assert(before.buttons == 0x10 && before.axes[0] == 32767);
    s2a_pad_session_reset();
    s2a_pad_read_ex(&after);
    assert(!after.buttons && !after.axes[0] && after.input_epoch != before.input_epoch);
    assert(after.notification_seq != before.notification_seq);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0x20, zero);
    expect(0x20, 0, 0);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, zero);
    expect(0, 0, 0);
    s2a_pad_set_active(0);
    s2a_pad_session_reset();
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0x40, zero);
    expect(0, 0, 0);
    s2a_pad_set_active(1);
    expect(0, 0, 0);
    puts("session reset：清上一局快照、换纪元、不改前后台状态");
}
static _Atomic int finished;
static _Atomic int waiting;
static uint64_t wait_sequence;
static void *waiter(void *unused) {
    (void)unused;
    atomic_store(&waiting, 1);
    assert(s2a_pad_wait(wait_sequence, s2a_pad_now_us() + 1000000));
    return NULL;
}
static void *writer(void *unused) {
    (void)unused;
    for (int i = 1; i <= 50000; i++) {
        int32_t axes[4] = {i % 32768, -(i % 32768), 0, 0};
        s2a_pad_update(S2A_PAD_BLE, 1, 0, axes);
    }
    atomic_store(&finished, 1); return NULL;
}
// #40 / 11-09 按字母：期望手写——系统 buttonA/B/X/Y 下标 0/1/2/3；「同字母」= {0,1,2,3}，「按位置」= Switch A/B/X/Y 在东/南/北/西 = 系统 B/A/Y/X = {1,0,3,2}
static void face_buttons(void) {
    assert(s2a_pad_kind("Switch Pro Controller", 0, 0) == S2A_PAD_KIND_NINTENDO);
    assert(s2a_pad_kind("Nintendo Switch Joy-Con (L/R)", 0, 0) == S2A_PAD_KIND_NINTENDO);
    assert(s2a_pad_kind("Joy-Con (L/R)", 0, 0) == S2A_PAD_KIND_NINTENDO);
    assert(s2a_pad_kind("Xbox One", 1, 0) == S2A_PAD_KIND_XBOX);
    assert(s2a_pad_kind("DualSense", 0, 1) == S2A_PAD_KIND_PLAYSTATION);
    assert(s2a_pad_kind("8BitDo Pro Controller", 0, 0) == S2A_PAD_KIND_OTHER);   // P2-213：名字里带 Pro Controller 的第三方不是任天堂
    assert(s2a_pad_kind(NULL, 0, 0) == S2A_PAD_KIND_OTHER);
    assert(s2a_pad_kind("MFi", 0, 0) == S2A_PAD_KIND_OTHER && s2a_pad_kind("HID", 0, 0) == S2A_PAD_KIND_OTHER);
    // 以后型号的字样未知：按片段不分大小写认（只认开头时第 1、3 个落到「认不出」→ 旧口径按位置，印 A 的右键变成 Switch B）
    assert(s2a_pad_kind("Switch 2 Pro Controller", 0, 0) == S2A_PAD_KIND_NINTENDO);
    assert(s2a_pad_kind("Joy-Con 2 (L)", 0, 0) == S2A_PAD_KIND_NINTENDO);
    assert(s2a_pad_kind("NINTENDO SWITCH 2 PRO CONTROLLER", 0, 0) == S2A_PAD_KIND_NINTENDO);
    assert(s2a_pad_kind("Switch Pro Controller", 1, 0) == S2A_PAD_KIND_XBOX);   // 手柄类型先于类别
    int o[4];
    // 期望手算：系统 buttonA/B/X/Y（下标 0..3）在任天堂手柄上是 东/南/北/西，其余手柄是 南/东/西/北。
    //   Switch 布局要 A/B/X/Y = 东/南/北/西，Xbox 布局要 南/东/西/北；自动 = 照字母 {0,1,2,3}
#define ORDER(k, l, a, b, c, d) do { s2a_pad_abxy_order(k, l, o); assert(o[0] == a && o[1] == b && o[2] == c && o[3] == d); } while (0)
    ORDER(S2A_PAD_KIND_NINTENDO, S2A_PAD_LAYOUT_AUTO, 0, 1, 2, 3);       // 任天堂 自动 = Switch 布局：印 A 的右键 = A
    ORDER(S2A_PAD_KIND_NINTENDO, S2A_PAD_LAYOUT_SWITCH, 0, 1, 2, 3);     // 东 = buttonA
    ORDER(S2A_PAD_KIND_NINTENDO, S2A_PAD_LAYOUT_XBOX, 1, 0, 3, 2);       // 南 = buttonB（印 B 的下键确认）、西 = buttonY、北 = buttonX
    ORDER(S2A_PAD_KIND_XBOX, S2A_PAD_LAYOUT_AUTO, 0, 1, 2, 3);           // Xbox 自动 = Xbox 布局：Xbox A（南）= Switch A
    ORDER(S2A_PAD_KIND_XBOX, S2A_PAD_LAYOUT_XBOX, 0, 1, 2, 3);
    ORDER(S2A_PAD_KIND_XBOX, S2A_PAD_LAYOUT_SWITCH, 1, 0, 3, 2);         // 东 = Xbox B、南 = Xbox A、北 = Xbox Y、西 = Xbox X
    ORDER(S2A_PAD_KIND_PLAYSTATION, S2A_PAD_LAYOUT_AUTO, 0, 1, 2, 3);    // PS 自动：× = A（#466）
    ORDER(S2A_PAD_KIND_PLAYSTATION, S2A_PAD_LAYOUT_SWITCH, 1, 0, 3, 2);  // ○ = A
    ORDER(S2A_PAD_KIND_PLAYSTATION, S2A_PAD_LAYOUT_XBOX, 0, 1, 2, 3);
    ORDER(S2A_PAD_KIND_OTHER, S2A_PAD_LAYOUT_AUTO, 0, 1, 2, 3);          // 认不出的（MFi 等，键帽同 Xbox）：照字母
    ORDER(S2A_PAD_KIND_OTHER, S2A_PAD_LAYOUT_SWITCH, 1, 0, 3, 2);
    ORDER(S2A_PAD_KIND_OTHER, S2A_PAD_LAYOUT_XBOX, 0, 1, 2, 3);
#undef ORDER
    assert(s2a_pad_layout_parse(NULL) == S2A_PAD_LAYOUT_AUTO && s2a_pad_layout_parse("auto") == S2A_PAD_LAYOUT_AUTO);
    assert(s2a_pad_layout_parse("letter") == S2A_PAD_LAYOUT_AUTO && s2a_pad_layout_parse("bogus") == S2A_PAD_LAYOUT_AUTO);   // 旧值「按字母」= 自动
    assert(s2a_pad_layout_parse("switch") == S2A_PAD_LAYOUT_SWITCH && s2a_pad_layout_parse("position") == S2A_PAD_LAYOUT_SWITCH);   // 旧值「按位置」= Switch 布局
    assert(s2a_pad_layout_parse("xbox") == S2A_PAD_LAYOUT_XBOX);
    unsetenv("S2A_PAD_FACE"); assert(s2a_pad_layout() == S2A_PAD_LAYOUT_AUTO);   // 缺省自动
    s2a_pad_layout_set(S2A_PAD_LAYOUT_XBOX); assert(s2a_pad_layout() == S2A_PAD_LAYOUT_XBOX);
    s2a_pad_layout_set(S2A_PAD_LAYOUT_SWITCH); assert(s2a_pad_layout() == S2A_PAD_LAYOUT_SWITCH);
    s2a_pad_layout_set(99); assert(s2a_pad_layout() == S2A_PAD_LAYOUT_AUTO);
}

int main(void) {
    face_buttons();
    touch_only();
    session_reset();
    s2a_pad_set_active(1);
    int32_t tilted[4] = {12345, -23456, 0, 0};
    s2a_pad_update(S2A_PAD_TOUCH, 1, 1, tilted);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, tilted);
    expect(1, 12345, -23456); expect(0, 12345, -23456); // 短按仅锁存一次。

    s2a_pad_update(S2A_PAD_BLE, 1, (1u << 2) | (1u << 16) | (1u << 20), zero);
    assert(s2a_pad_has_controller()); expect(1u << 2, 0, 0); // 额外按钮不会冒充摇杆方向。
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0xffff, tilted);
    expect(1u << 2, 0, 0); // 隐藏触控不能污染实体输入。
    s2a_pad_update(S2A_PAD_SYSTEM, 1, 1u << 3, tilted);
    expect(1u << 3, 12345, -23456);
    s2a_pad_update(S2A_PAD_BLE, 1, 1u << 1, zero);
    s2a_pad_update(S2A_PAD_BLE, 1, 0, zero);
    s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL);
    expect(0, 0, 0); // 非当前手柄的短按不能在切源后回放。
    s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL);
    assert(!s2a_pad_has_controller()); expect(0, 0, 0); // 旧触控、锁存和摇杆均已清空。

    s2a_pad_update(S2A_PAD_SYSTEM, 1, 0xffff, tilted);
    s2a_pad_set_active(0);
    s2a_pad_update(S2A_PAD_BLE, 1, 0xffff, tilted); // 后台迟到的回调无效。
    expect(0, 0, 0); assert(!s2a_pad_has_controller());
    s2a_pad_set_active(1); expect(0, 0, 0);

    // 按最后一次输入切换（维护者 10-24：按钮就切到手柄，触屏就切回虚拟按键）
    s2a_pad_set_active(0); s2a_pad_set_active(1);
    assert(!s2a_pad_prefer_touch());                 // 没有实体手柄：本来就是触屏，不算切换
    s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, zero);
    assert(s2a_pad_has_controller());                // 连上手柄 → 手柄生效（虚拟按键隐藏）
    assert(s2a_pad_prefer_touch() && !s2a_pad_has_controller());   // 碰屏幕 → 触屏接管
    assert(!s2a_pad_prefer_touch());                 // 已是触屏，再碰不重复切
    s2a_pad_update(S2A_PAD_TOUCH, 1, 1u << 4, tilted);
    expect(1u << 4, 12345, -23456);                  // 触屏按键生效，手柄虽连着也不盖住它
    s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, zero);
    assert(!s2a_pad_has_controller());               // 手柄没动作（全零）的上报不抢回
    s2a_pad_update(S2A_PAD_SYSTEM, 1, 1u << 5, zero);
    assert(s2a_pad_has_controller()); expect(1u << 5, 0, 0);   // 手柄一按 → 切回手柄，触屏残留清掉
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0xffff, tilted);
    expect(1u << 5, 0, 0);                           // 切回后隐藏的触屏不污染手柄输入
    assert(s2a_pad_prefer_touch());
    s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, tilted);
    assert(s2a_pad_has_controller());                // 摇杆动一下也算手柄动作
    assert(s2a_pad_prefer_touch());
    s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL); s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, zero);
    assert(s2a_pad_has_controller());                // 触屏接管中拔掉手柄再连：接管随之清除，重连按手柄
    s2a_pad_set_active(0); s2a_pad_set_active(1); expect(0, 0, 0);

    // 快捷菜单的手柄入口：实体手柄「+」（bit10）每按下一次新序号、按着期间不变、松开回 0；同时按别的键不算新的一下；触屏的「+」不算
    {   const uint32_t plus = 1u << 10;
        s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, zero); assert(!s2a_pad_plus_press());
        s2a_pad_update(S2A_PAD_SYSTEM, 1, plus, zero); uint64_t a = s2a_pad_plus_press(); assert(a);
        s2a_pad_update(S2A_PAD_SYSTEM, 1, plus | 1u, tilted); assert(s2a_pad_plus_press() == a);   // 按着「+」再按 A、动摇杆：还是同一下
        s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, zero); assert(!s2a_pad_plus_press());                  // 松开：1.5 秒后的复查对不上，不开菜单
        s2a_pad_update(S2A_PAD_SYSTEM, 1, plus, zero); uint64_t b2 = s2a_pad_plus_press(); assert(b2 && b2 != a);   // 再按：新的一下
        s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL); assert(!s2a_pad_plus_press());                  // 拔掉手柄 = 松开
        s2a_pad_update(S2A_PAD_BLE, 1, plus, zero); assert(s2a_pad_plus_press());                   // NS2 BLE 手柄同样认
        s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL); assert(!s2a_pad_plus_press());
        s2a_pad_update(S2A_PAD_TOUCH, 1, plus, zero); assert(!s2a_pad_plus_press());                // 虚拟键「+」不算
        s2a_pad_update(S2A_PAD_TOUCH, 1, 0, zero);
        s2a_pad_set_active(0); s2a_pad_set_active(1); expect(0, 0, 0); }
    // #276 Home（扩展位 bit16）同「+」开菜单：系统手柄 / NS2 手柄按住 Home 有序号、松开回 0；按着 Home 再按「+」还是同一下；Home 不进游戏（截掉高位）；触屏不算
    {   const uint32_t plus = 1u << 10, home = 1u << 16;
        s2a_pad_update(S2A_PAD_SYSTEM, 1, home, zero); uint64_t h = s2a_pad_plus_press(); assert(h);
        expect(0, 0, 0);                                                                             // Home 位不当成任何游戏按键
        s2a_pad_update(S2A_PAD_SYSTEM, 1, home | plus, zero); assert(s2a_pad_plus_press() == h);    // 按着 Home 再按「+」：同一下
        s2a_pad_update(S2A_PAD_SYSTEM, 1, 0, zero); assert(!s2a_pad_plus_press());
        s2a_pad_update(S2A_PAD_BLE, 1, home, zero); uint64_t h2 = s2a_pad_plus_press(); assert(h2 && h2 != h);
        s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL); assert(!s2a_pad_plus_press());
        s2a_pad_update(S2A_PAD_TOUCH, 1, home, zero); assert(!s2a_pad_plus_press());
        s2a_pad_update(S2A_PAD_TOUCH, 1, 0, zero);
        s2a_pad_set_active(0); s2a_pad_set_active(1); expect(0, 0, 0); }

    // #520 A：单只 Joy-Con 原始方向的 SL / SR（Ryujinx 24..27）进游戏；Home / Capture / C / GL / GR（16..20）与 21..23、28 起照旧截掉
    {   const uint32_t sl_sr = 0xfu << 24;
        s2a_pad_update(S2A_PAD_BLE, 1, sl_sr | 1u, zero); expect(sl_sr | 1u, 0, 0);
        s2a_pad_update(S2A_PAD_BLE, 1, (0x1fu << 16) | (0x7u << 21) | (1u << 28), zero); expect(0, 0, 0);
        s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL);
        s2a_pad_set_active(0); s2a_pad_set_active(1); expect(0, 0, 0); }

    s2a_pad_snapshot snapshot, next;
    s2a_pad_read_ex(&snapshot);
    assert(sizeof snapshot == 56 && snapshot.read_timestamp_us > 0);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, zero);
    s2a_pad_read_ex(&next);
    assert(next.notification_seq == snapshot.notification_seq); // 相同状态不唤醒。
    s2a_pad_update(S2A_PAD_BLE, 1, 0, zero);
    s2a_pad_read_ex(&snapshot);
    assert(snapshot.input_epoch != next.input_epoch);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 1, tilted);
    s2a_pad_update(S2A_PAD_BLE, 1, 0, zero);
    s2a_pad_read_ex(&next);
    assert(next.notification_seq == snapshot.notification_seq && next.input_epoch == snapshot.input_epoch);
    // 通知先于 wait 时必须立即返回，不能丢失唤醒。
    s2a_pad_wake();
    assert(s2a_pad_wait(next.notification_seq, s2a_pad_now_us() + 1000000));
    s2a_pad_read_ex(&snapshot);
    uint64_t start_us = s2a_pad_now_us();
    assert(!s2a_pad_wait(snapshot.notification_seq, start_us + 2000));
    assert(s2a_pad_now_us() >= start_us + 2000);

    wait_sequence = snapshot.notification_seq;
    pthread_t waiting_thread; assert(!pthread_create(&waiting_thread, NULL, waiter, NULL));
    while (!atomic_load(&waiting)) { struct timespec pause = {0, 100000}; nanosleep(&pause, NULL); }
    s2a_pad_set_active(0);
    assert(!pthread_join(waiting_thread, NULL));
    s2a_pad_read_ex(&next);
    assert(next.input_epoch != snapshot.input_epoch && !next.buttons);
    s2a_pad_set_active(1);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 1, zero);
    s2a_pad_update(S2A_PAD_TOUCH, 1, 0, zero);
    s2a_pad_read_ex(&snapshot);
    assert(snapshot.buttons == 1 && snapshot.host_timestamp_us > 0);
    s2a_pad_record_commit(&snapshot);
    s2a_pad_record_commit(&snapshot); // 同一通知不能重复计数。
    s2a_pad_latency measured;
    s2a_pad_get_latency(&measured, 1);
    assert(measured.samples == 1 && measured.host_total_us >= measured.read_total_us);
    s2a_pad_get_latency(&measured, 0); assert(!measured.samples);
    expect(0, 0, 0);

    int32_t stick[2];
    s2a_pad_stick(.04f, .04f, stick); assert(!stick[0] && !stick[1]);
    s2a_pad_stick(1, 0, stick); assert(stick[0] == 32767 && stick[1] == 0);
    s2a_pad_stick(-1, 1, stick); assert(stick[0] == -23170 && stick[1] == 23170);
    s2a_pad_stick(NAN, 0, stick); assert(!stick[0] && !stick[1]);

    pthread_t thread; assert(!pthread_create(&thread, NULL, writer, NULL));
    do {
        int32_t axes[4]; assert(!s2a_pad_read(axes, NULL));
        assert(axes[0] == -axes[1] && !axes[2] && !axes[3]);
    } while (!atomic_load(&finished));
    assert(!pthread_join(thread, NULL));

    // 本地多手柄槽位（s2a_slot_plan，Mac / iOS 共用）：期望值按「还在线留原槽、新来的占最小空槽、超 4 只丢弃」手算
    {
        static const char A, B, C, D, E;
        const void *prev[4] = {0}; int slot_of[5];
        const void *ab[2] = {&A, &B};
        assert(s2a_slot_plan(prev, ab, 2, 4, slot_of) == 2 && slot_of[0] == 0 && slot_of[1] == 1);   // 两只：A 槽 0、B 槽 1
        prev[0] = &A; prev[1] = &B;
        const void *b_only[1] = {&B};
        assert(s2a_slot_plan(prev, b_only, 1, 4, slot_of) == 2 && slot_of[0] == 1);   // A 断开：B 留槽 1，仍报 2 格
        prev[0] = NULL;
        const void *ba[2] = {&B, &A};
        assert(s2a_slot_plan(prev, ba, 2, 4, slot_of) == 2 && slot_of[0] == 1 && slot_of[1] == 0);   // A 接回：回槽 0
        const void *bc[2] = {&B, &C};
        assert(s2a_slot_plan(prev, bc, 2, 4, slot_of) == 2 && slot_of[0] == 1 && slot_of[1] == 0);   // A 不在时插进 C：C 占空出的槽 0
        prev[0] = &C;
        const void *bca[3] = {&B, &C, &A};
        assert(s2a_slot_plan(prev, bca, 3, 4, slot_of) == 3 && slot_of[0] == 1 && slot_of[1] == 0 && slot_of[2] == 2);   // A 再接回：落槽 2
        const void *none[4] = {0}, *five[5] = {&A, &B, &C, &D, &E};
        assert(s2a_slot_plan(none, five, 5, 4, slot_of) == 4 && slot_of[0] == 0 && slot_of[1] == 1 && slot_of[2] == 2 &&
               slot_of[3] == 3 && slot_of[4] == -1);   // 第 5 只丢弃
        assert(s2a_slot_plan(none, five, 0, 4, slot_of) == 1);   // 没有手柄：1 格（触屏 / 键盘）
    }

    const int iterations = 1000000;
    struct timespec start, end; int32_t axes[4];
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (int i = 0; i < iterations; i++) s2a_pad_read(axes, NULL);
    clock_gettime(CLOCK_MONOTONIC, &end);
    double ns = (end.tv_sec - start.tv_sec) * 1e9 + end.tv_nsec - start.tv_nsec;
    printf("✓ t_pad：生命周期、短按、完整快照、通知等待、提交统计与多手柄槽位通过；宿主快照读取 %.1f ns/次（非设备蓝牙功耗测量）\n", ns / iterations);
    return 0;
}
