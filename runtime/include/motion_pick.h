#ifndef S2A_MOTION_PICK_H
#define S2A_MOTION_PICK_H
// 玩家 1 的六轴来源仲裁（纯函数，单测 runtime/tests/t_motion_pick.c）
//   输入来源（runtime/src/pad.c 的 s2a_pad_source）+ 三路各自有没有样本 → 这一帧该读哪一路。
//   规矩（11-15 维护者改）：有体感样本的手柄优先，不看触屏在不在操作；两只手柄都在时按谁在驱动输入分先后；
//   手柄都给不出样本（没接 / 系统不给体感）才用手机陀螺仪。
//   两台刚体的角速度绝不混合：换源由宿主丢一帧（known = 0）让服务层重建姿态。
enum { S2A_MOTION_NONE = 0, S2A_MOTION_PHONE, S2A_MOTION_GC, S2A_MOTION_NS2 };
//   input_source 用 s2a_pad_source 的原值：0 = 触屏（S2A_PAD_TOUCH）、1 = NS2 Pro BLE、2 = 系统手柄。
//   三个 known 非 0 表示那一路这一帧有可用样本。返回 S2A_MOTION_*。
int s2a_motion_pick(int input_source, int ns2_known, int gc_known, int phone_known);
// 手柄体感「有没有」按新鲜样本判（玩家反馈：无陀螺仪的夹持手柄，系统也给 GCMotion 对象却不出样本，或只出一帧就停；
//   旧判据「收到过一帧就永远算有」让仲裁一直选手柄、手机陀螺仪轮不到）：收到过、且最近一帧不超过 S2A_MOTION_STALE_MS 才算有
#include <stdint.h>
#define S2A_MOTION_STALE_MS 500
int s2a_motion_fresh(int ever, uint64_t sample_us, uint64_t now_us);
// 空样本：加速度、角速度六个值全是精确 0 → 1。真传感器静止也有 1 g 重力和噪声，做不到；是传感器没开时系统照样回调的空样本（#2142 D-Q99N），不算新鲜样本
int s2a_motion_blank(const float accel[3], const float gyro[3]);
// 提示用：系统给了体感对象（capable = 1），却从 last_ok_us 起超过 S2A_MOTION_SILENT_MS 没有新鲜样本 → 1（当作这只手柄没体感，提示一次）。
//   last_ok_us = 最近一次有新鲜样本、或开始等样本（游戏刚要六轴 / 刚换手柄）的时刻；宽限期内不判，免得传感器刚开的一瞬误报
#define S2A_MOTION_SILENT_MS 2000
int s2a_motion_pad_silent(int capable, uint64_t last_ok_us, uint64_t now_us);
#endif
