// 兜底手柄（#934）：GameController 认不出的 HID 手柄，按 HID 元素直读按键 / 摇杆 / 十字键（名字带「Pro Controller」的另走 Switch Pro 协议；
//   其余通用手柄按位置映射，规则与让位判定在 hid_generic.h）。
// 与 front_mac.m 的槽位表对接：每只占一个玩家槽，键位走同一份 gamepad 配置（键名同 Switch 2 Pro 那一路）。
#ifndef S2A_MAC_HID_PAD_H
#define S2A_MAC_HID_PAD_H
#include <stddef.h>
#include <stdint.h>
#include "s2a_pad.h"
#include "hid_generic.h"
#include "hid_pro_parse.h"   // s2a_pro_cal 与纯解析（启动器共用）

enum { S2A_HID_PAD_MAX = 8 };   // 设备表：GameController 已列出（让位）的通用手柄也占一格，比玩家数留宽
// buttons 位序 = front_mac.m sample_coded_state 的键名表：east south north west leftStick rightStick leftShoulder rightShoulder
//   leftTrigger rightTrigger menu options dpadLeft dpadUp dpadRight dpadDown；摇杆 -32767..32767，上 / 右为正（同 GameController）
//   pro / vid / gc_hint / age_us：给 front_mac.m 每拍调 s2a_hidg_route 判占不占位（gc_hint = supportsHIDDevice 的答复，age_us = 接上多久）
typedef struct { uint32_t buttons; int16_t lx, ly, rx, ry; const void *id; char name[96]; int pro, vid, gc_hint; uint64_t age_us; } s2a_hid_pad;

// 起 IOHID 监听（只起一次，主线程调；回调在主线程跑）
void s2a_mac_hid_pad_start(void);
// 当前在线的兜底手柄，按接上顺序填进 out，返回只数；通用手柄第一次按键之前不列（s2a_hidg_joined）
int s2a_mac_hid_pad_read(s2a_hid_pad out[S2A_HID_PAD_MAX]);
// 补给系统手柄槽位的北通摇杆；按同一个 IORegistry 设备匹配。
// 返回轴数：宙斯蓝牙 2、鲲鹏20 NS USB 4；过期或缺样返回 0。
int s2a_mac_hid_betop_sticks(uint64_t entry, int16_t sticks[4]);
// 兜底手柄的体感（11-16，第三方 Switch 模式手柄：八位堂 / 盖世小鸡等自带陀螺仪、GameController 不认的）：id = s2a_hid_pad.id；
//   有近 200 ms 内的六轴样本回 1（从 0x30 完整报告的 IMU 解出，同一代 Pro 的 Switch Pro 协议），否则回 0
int s2a_mac_hid_pad_motion(const void *id, s2a_pad_motion *out);
// 补满采样：一次取走这一拍累积的全部 IMU 样本（消费式、时间升序，最多 max 条），
//   返回 >=0 条数；-1 = 这个 id 不是兜底 HID 设备。单笔接口仍读最新一份。
int s2a_mac_hid_pad_motion_burst(const void *id, s2a_pad_motion *out, int max);
// 启动设置「体感」开关（S2A_MOTION=0 → front_mac.m s2a_pad_set_motion_enabled 一并调它）：关着时兜底手柄的六轴不交给游戏（#1383：原先只管系统手柄 / NS2 / 一代 Joy-Con，兜底 HID 照交）
void s2a_mac_hid_pad_set_motion_enabled(int enabled);
int s2a_mac_hid_pad_motion_enabled(void);   // 当前开关（单测读）
// 纯函数（单测用）：这一份兜底手柄六轴能不能交给游戏——体感开着、有样本（motion_us 非 0）、样本不超过 200 ms
static inline int s2a_hid_pad_motion_ok(int enabled, unsigned long long now_us, unsigned long long motion_us) {
    return enabled && motion_us && now_us - motion_us < 200000;
}
// 纯函数（单测）：0x30 完整报告（首字节报告号）→ 最后一组 IMU 样本换成 NS2 坐标（g、度/秒；同 joycon_imu.m 的 Pro / 右 Joy-Con 映射）。报告太短回 0
int s2a_pro_imu(const uint8_t *r, size_t n, s2a_pad_motion *out);
// 纯函数（单测用）：Switch 简易 HID 键号（1 起：B A Y X L R ZL ZR − + 左摇杆 右摇杆）→ buttons 位
uint32_t s2a_hid_pad_switch_button_bit(int usage);
// 纯函数（单测用）：十字键 hat 值 → dpad 位；min..max 之外（含 8 个方向后的「松开」值）= 0
uint32_t s2a_hid_pad_hat_bits(long v, long min, long max);
// 纯函数（单测用）：HID 轴原值按逻辑范围归一到 -32767..32767；invert = 反向（HID 的 Y 向下为正）
int16_t s2a_hid_pad_axis(long v, long min, long max, int invert);
// Switch Pro 协议（#934 11-15：PowerA 授权手柄在简易 HID 模式下声明的摇杆量程远大于实际值，换算后只有满量程的几分之一、摇杆慢五六倍；
//   灯一直闪是没人发点灯子命令）：连上时像 Steam 一样发子命令切完整报告（0x30）、点玩家灯、读出厂摇杆校准，之后按 0x30 报告直读。
//   校准：中心与上 / 下行程（12 位）；读不到出厂校准用缺省（中心 2048、行程起点 1003，随读数放大，#1264）
void s2a_pro_cal_default(s2a_pro_cal *c);
// 纯函数（单测用）：SPI 0x603D 起 18 字节（左 9 + 右 9，两边字段次序不同）→ 左 / 右摇杆校准；空值或中心 / 行程不合理时回 0 不改
int s2a_pro_cal_parse(const uint8_t d[18], s2a_pro_cal *l, s2a_pro_cal *r);
// 纯函数（单测用）：12 位摇杆值按校准归一到 -32767..32767（上 / 右为正）
int16_t s2a_pro_axis(int v, int center, int above, int below);
int16_t s2a_pro_axis_grow(int v, int center, uint16_t *above, uint16_t *below);   // 离中心超过记下的行程就放大行程，再换算
// 纯函数（单测用）：一条 0x30 / 0x21 输入报告（含报告号）→ buttons 位（同 s2a_hid_pad 的位序）与四个摇杆值；不是这两种报告回 0
int s2a_pro_parse(const uint8_t *r, size_t n, s2a_pro_cal *l, s2a_pro_cal *rc, uint32_t *buttons, int16_t ax[4]);   // 有效厂校固定行程；只有缺厂校的默认校准随读数扩大
// 纯函数（单测用）：第 slot 个玩家（0 起）的玩家灯参数：点前 slot + 1 盏
uint8_t s2a_pro_player_lights(int slot);
// ---- Xbox 有线手柄 GIP 协议 ----
// 纯函数（单测用）：一条 0x20 GIP 输入报告（含报告号）→ buttons 位（同 s2a_hid_pad 的位序）与四个摇杆值（-32768..32767，上/右为正）；不是 GIP 输入报告回 0
int s2a_gip_parse(const uint8_t *r, size_t n, uint32_t *buttons, int16_t ax[4]);
// 纯函数（单测用）：GIP 数据包若置有 ACK 标志（r[1] & 0x10），组出 13 字节 ACK 应答包并回 13；否则回 0
int s2a_gip_ack(const uint8_t *r, size_t n, uint8_t ack[13]);
// 纯函数（单测用）：判断 VID / PID 是否为已知的微软或兼容有线 Xbox GIP 手柄
int s2a_is_xbox_gip(int vid, int pid);
// 启动器中继（S2A_XBOX_GIP_SOCKET）：应用一条 128 字节中继报文（有效回 1，无效回 0）；清空中继槽位；从已连 fd 读到断开为止
int s2a_mac_hid_pad_apply_xbox_relay(const void *packet, size_t len);
void s2a_mac_hid_pad_clear_xbox_relay(void);
int s2a_mac_hid_pad_read_xbox_relay_fd(int fd);
#if defined(__APPLE__)
#include <IOKit/IOTypes.h>
// 检查 USB 设备树下是否已有系统加载的 HID 子节点（IOHIDInterface / IOHIDDevice），避免抢占已由系统 / GameController 认领的手柄
int s2a_usb_has_hid_child(io_service_t dev);
#endif
#endif
