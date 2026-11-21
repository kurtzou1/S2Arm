// 系统手柄（GCController）存活判定与断开延迟确认——纯逻辑，不含 UIKit / GameController 依赖，
//   放在头里是为了能在 Mac 宿主上单测（runtime/tests/t_pad_liveness.c）。
//
// 为什么不用 GCController.controllers 快照判活：那是快照、有延迟。iOS 上第三方 BLE 手柄连接抖动 /
//   重新枚举时，快照会短暂不含当前手柄；旧实现据此立刻把 valueChangedHandler 摘成 nil 并
//   s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL)，实体手柄所有按键在共享内存里就一直是 0，直到下一次
//   Connect 通知重新接入——真机实测「-」键约 1 秒延迟（屏幕虚拟手柄走 TOUCH 源，不经这条路，所以即时）。
//   对象自身的 extendedGamepad 是「此刻是否可用」的状态，不受快照延迟影响，改以它为准。
//   但只看它对真断开没有出口（#1952）：Xbox 手柄关机后旧 GCController 的 extendedGamepad 仍非 nil，断开通知后一直判「可用」，
//   不清旧对象，再连上时系统给的是新对象、只能排玩家 2。所以「不在快照里」也算可疑：不立刻清，走下面同一套延迟确认，
//   复查时仍不在快照里才清；抖动期 handler 与共享内存照旧，抖动保护不变。
//
// 为什么断开要延迟确认：同一次抖动会让 Disconnect / Connect 两条通知都触发 selectSystem。立刻清零等于
//   把 200ms 内的重连也当成真断开，白白断流一次。第一次发现不可用只排一次复查，复查仍不可用才清零。
#ifndef S2A_PAD_LIVENESS_H
#define S2A_PAD_LIVENESS_H

#include <stdbool.h>

// 断开复查延迟：覆盖 iOS 上 BLE 手柄重枚举的典型抖动窗口，又远小于人可感知的 1 秒。
#define S2A_SYSTEM_RECHECK_MS 200

typedef enum {
    S2A_SYS_NONE = 0,   // 没有当前对象、也没有可用候选：什么都不做
    S2A_SYS_PUBLISH,    // 当前对象仍可用：刷新一次共享内存（不清零、不摘 handler）
    S2A_SYS_DEFER,      // 首次发现不可用：保留 handler 与共享内存状态，排一次延迟复查
    S2A_SYS_CLEAR,      // 确认不可用（或已切后台）：清零共享内存并摘 handler
    S2A_SYS_ATTACH,     // 快照里有另一个可用对象：摘旧 handler、装新 handler
} s2a_sys_action;

typedef struct {
    bool foreground;      // App 在前台
    bool has_current;     // _system != nil
    bool current_alive;   // _system.extendedGamepad != nil
    bool current_listed;  // _system 在 GCController.controllers 快照里
    bool candidate_ready; // 快照里找到另一个 extendedGamepad 非 nil 的对象
    bool may_clear;       // 本次是延迟复查（true）还是即时判定（false）
} s2a_sys_state;

static inline s2a_sys_action s2a_system_action(s2a_sys_state s) {
    if (!s.foreground) return s.has_current ? S2A_SYS_CLEAR : S2A_SYS_NONE;  // 切后台：原行为就是立刻摘掉
    if (s.has_current && s.current_alive && s.current_listed) return S2A_SYS_PUBLISH;   // 对象自身可用且在快照里
    if (s.candidate_ready) return S2A_SYS_ATTACH;
    if (!s.has_current) return S2A_SYS_NONE;
    return s.may_clear ? S2A_SYS_CLEAR : S2A_SYS_DEFER;
}

#endif
