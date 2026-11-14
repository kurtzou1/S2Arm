// Mac Joy-Con / Pro：GameController 不暴露 GCMotion，六轴走 HID 标准全报告（0x30）。
// 与 front_mac.m 的 s2a_pad_read_motion 对接；单位同 s2a_pad_motion（g、度/秒，NS2 原始坐标约定由本文件按握持近似映射）。
#ifndef S2A_JOYCON_IMU_H
#define S2A_JOYCON_IMU_H
#include "../runtime/include/s2a_pad.h"

// 游戏要六轴时打开（发 enable IMU + input mode 0x30）；关掉恢复 0x3F。shared 打开，尽量不抢 GameController 按键。
void s2a_joycon_imu_set_enabled(int enabled);

// 读左右最新样本（好几只时取最先接上的左只 / 右只）。返回位掩码：bit0=左、bit1=右（含 Pro 当「右」单源）。out_l / out_r 可为 NULL。
int s2a_joycon_imu_read(s2a_pad_motion *out_l, s2a_pad_motion *out_r);

// 一代 Joy-Con / Pro 的 HID 震动（GameController 不给 haptics 时）：which bit0 = 左只、bit1 = 右只、bit2 = Pro；pair = 左右两侧。返回实际发到的位
int s2a_joycon_rumble(int which, const s2a_pad_vibration pair[2]);

// D2（#520）：一代 Joy-Con 按设备读按键 / 摇杆（两只被 macOS 合成一个时也各算一位玩家）。缺省关；开了手柄出全报告 0x30
void s2a_joycon_pad_set_enabled(int enabled);
// 按设备 id 读（多套一代 Joy-Con 各算各的）：id = 序列号（蓝牙地址），没有时 LocationID（loc-十六进制）；启动器 Gen1HIDWatcher.deviceID 同一套
typedef struct { char id[64]; int pid; } s2a_joycon_info;
int s2a_joycon_list(s2a_joycon_info *out, int max);   // 现在接着的（按接上的先后），返回几只
// 按键 / 摇杆同 s2a_joycon1_decode（横握视角），side 是这只的 SL / SR / 肩键。没有 / 250 毫秒没新报告回 0。pid 可 NULL
int s2a_joycon_pad_read_id(const char *id, uint32_t *buttons, int32_t sticks[4], int *side, int *pid);
// 最近一笔标准全报告的原始字节（给 s2a_joycon1_pair_decode 拼一对）；没有 / 太旧回 0
int s2a_joycon_pad_raw_id(const char *id, uint8_t raw[S2A_JC1_RAW]);
int s2a_joycon_imu_read_id(const char *id, s2a_pad_motion *out);   // 这一只的六轴（体感开着时）
int s2a_joycon_rumble_id(const char *id, const s2a_pad_vibration pair[2]);   // 这一只的 HID 震动；没这只回 0

#endif
