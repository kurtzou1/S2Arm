// 手柄输入算「用户在场」（#2159）：系统空闲计时只看键盘 / 鼠标 / 触控板，S2Arm 自己读的手柄（NS2 蓝牙直连、一代 Joy-Con 拆读、
//   兜底 HID）系统看不到，只拿手柄玩，到了「关闭显示器」的时间照样黑屏锁屏。front_mac.m 每拍采样后调 s2a_pad_activity_tick，
//   返回 1 就调一次 IOPMAssertionDeclareUserActivity（等同用户碰了一下键盘）：玩家放下手柄走开，系统照常按自己的时间锁屏，
//   不是整局都不让锁。纯 C、不引系统头，runtime/tests/t_pad_activity.c 无设备单测。
//   - 算「有动作」：任一槽按键位变化，或摇杆某轴离上次记下的位置超过 S2A_PAD_ACTIVITY_STICK（满幅 1/8）——静止手柄的读数抖动不算，
//     否则放着不动的手柄会让屏幕永远不睡
//   - 第一拍只记基准不算动作（刚连上 / 起局时的初始读数不是玩家在按）
//   - 声明后 S2A_PAD_ACTIVITY_GAP_US（5 秒）内不再声明：系统最短的关显示器时间是 1 分钟，5 秒一次足够，不必每拍进内核
#ifndef S2A_MAC_PAD_ACTIVITY_H
#define S2A_MAC_PAD_ACTIVITY_H
#include <stdint.h>
#include <string.h>

enum { S2A_PAD_ACTIVITY_SLOTS = 8, S2A_PAD_ACTIVITY_STICK = 4096 };
#define S2A_PAD_ACTIVITY_GAP_US 5000000ull
typedef struct {
    uint32_t buttons[S2A_PAD_ACTIVITY_SLOTS];
    int32_t sticks[S2A_PAD_ACTIVITY_SLOTS][4];
    uint64_t last_us;   // 上次声明的时刻；0 = 还没声明过
    int primed;
} s2a_pad_activity;

static inline int s2a_pad_activity_tick(s2a_pad_activity *a, int slots, const uint32_t *buttons, const int32_t (*sticks)[4], uint64_t now_us) {
    if (slots > S2A_PAD_ACTIVITY_SLOTS) slots = S2A_PAD_ACTIVITY_SLOTS;
    int moved = 0;
    for (int s = 0; s < slots; s++) {
        if (buttons[s] != a->buttons[s]) { a->buttons[s] = buttons[s]; moved = 1; }
        for (int i = 0; i < 4; i++) {
            int64_t d = (int64_t)sticks[s][i] - a->sticks[s][i];
            if (d > S2A_PAD_ACTIVITY_STICK || d < -S2A_PAD_ACTIVITY_STICK) { a->sticks[s][i] = sticks[s][i]; moved = 1; }
        }
    }
    if (!a->primed) { a->primed = 1; return 0; }
    if (!moved || (a->last_us && now_us - a->last_us < S2A_PAD_ACTIVITY_GAP_US)) return 0;
    a->last_us = now_us ? now_us : 1;
    return 1;
}
#endif
