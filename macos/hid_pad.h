// 兜底手柄（#934）：GameController 认不出的 Switch 样式 HID 手柄，按 HID 元素直读按键 / 摇杆 / 十字键。
// 与 front_mac.m 的槽位表对接：每只占一个玩家槽，键位走同一份 gamepad 配置（键名同 Switch 2 Pro 那一路）。
#ifndef S2A_MAC_HID_PAD_H
#define S2A_MAC_HID_PAD_H
#include <stdint.h>

enum { S2A_HID_PAD_MAX = 4 };
// buttons 位序 = front_mac.m sample_coded_state 的键名表：east south north west leftStick rightStick leftShoulder rightShoulder
//   leftTrigger rightTrigger menu options dpadLeft dpadUp dpadRight dpadDown；摇杆 -32767..32767，上 / 右为正（同 GameController）
typedef struct { uint32_t buttons; int16_t lx, ly, rx, ry; const void *id; char name[96]; } s2a_hid_pad;

// 起 IOHID 监听（只起一次，主线程调；回调在主线程跑）
void s2a_mac_hid_pad_start(void);
// 当前在线的兜底手柄，按接上顺序填进 out，返回只数
int s2a_mac_hid_pad_read(s2a_hid_pad out[S2A_HID_PAD_MAX]);
// 纯函数（单测用）：Switch 简易 HID 键号（1 起：B A Y X L R ZL ZR − + 左摇杆 右摇杆）→ buttons 位
uint32_t s2a_hid_pad_switch_button_bit(int usage);
// 纯函数（单测用）：十字键 hat 值 → dpad 位；min..max 之外（含 8 个方向后的「松开」值）= 0
uint32_t s2a_hid_pad_hat_bits(long v, long min, long max);
// 纯函数（单测用）：HID 轴原值按逻辑范围归一到 -32767..32767；invert = 反向（HID 的 Y 向下为正）
int16_t s2a_hid_pad_axis(long v, long min, long max, int invert);
#endif
