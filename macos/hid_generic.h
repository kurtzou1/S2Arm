// 通用 HID 手柄（GameController 不认、名字也不带「Pro Controller」的：谷歌 Stadia 蓝牙、八位堂 D-input 模式等）的纯函数：
//   按键 / 十字键 / 轴的映射、让不让给 GameController、首次按键才占槽。纯 C、不引系统头，runtime/tests/t_hid_generic.c 无设备单测；
//   macos/hid_pad.m 读设备、front_mac.m 每拍按 s2a_hidg_route 判占不占玩家位。规则照搬参考实现 nxnative（MIT）dm/host/pad_hid.h / pad_hid_mac.h：
//   - 按键按位置（右 A、下 B、上 X、左 Y，同 GameController 那一路），缺省是八位堂 D-input 编号（HID 按键号 1 A、2 B、4 X、5 Y、7 / 8 L / R、9 / 10 ZL / ZR、
//     11 −、12 +、14 / 15 左 / 右摇杆按下）；S2A_HID_MAP=A=2,B=1,…（也认参考实现的 DM_HID_MAP）逐键覆盖，键名不认识或号大于 32 的那项跳过
//   - 摇杆：X / Y 左摇杆，Z / Rz 右摇杆；没有 Z 的设备右摇杆用 Rx / Ry。HID 的 Y 向下为正，换成上为正（同 GameController）
//   - 模拟扳机 Brake / Accelerator 过半按 ZL / ZR；hat 八方向解成十字键，范围外 = 居中
//   - 让位：GameController 已列出同名手柄 → 让；微软 / 索尼 / 任天堂（系统原生认得，名字未必等于 HID 产品名）→ 让；
//     GameController 说认得（supportsHIDDevice）→ 等 2 秒，期间它没列出同名手柄才按 HID 读，之后列出了再让回去
//   - Switch Pro 协议那一支（名字带「Pro Controller」，hid_pad.m 切 0x30 完整报告 + 体感）照旧：不看厂商号、不等，GameController 列出同名就让
//   - 通用手柄首次按下（按键 / 十字键 / 扳机过半）才占玩家位：声明成 GamePad 的键盘接收器从不按，不占位（参考实现 #1657）
#ifndef S2A_MAC_HID_GENERIC_H
#define S2A_MAC_HID_GENERIC_H
#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

enum { S2A_HIDG_X, S2A_HIDG_Y, S2A_HIDG_Z, S2A_HIDG_RX, S2A_HIDG_RY, S2A_HIDG_RZ, S2A_HIDG_BRAKE, S2A_HIDG_ACCEL, S2A_HIDG_AXES };
// buttons 位序同 hid_pad.h 的 s2a_hid_pad.buttons：A(东) B(南) X(北) Y(西) 左摇杆 右摇杆 L R ZL ZR + − 左 上 右 下
enum { S2A_HIDG_A, S2A_HIDG_B, S2A_HIDG_BX, S2A_HIDG_BY, S2A_HIDG_LS, S2A_HIDG_RS, S2A_HIDG_L, S2A_HIDG_R, S2A_HIDG_ZL, S2A_HIDG_ZR,
       S2A_HIDG_PLUS, S2A_HIDG_MINUS, S2A_HIDG_LEFT, S2A_HIDG_UP, S2A_HIDG_RIGHT, S2A_HIDG_DOWN, S2A_HIDG_BUTTONS };
typedef struct {
    uint32_t held;                 // 第 u - 1 位：HID 按键号 u（1..32）按着
    int hat;                       // -1 居中，0 上，顺时针到 7 左上
    float axis[S2A_HIDG_AXES];     // -1..1（扳机松开在 -1）
    uint8_t has[S2A_HIDG_AXES];    // 设备有这根轴
    uint8_t map[S2A_HIDG_BUTTONS]; // 按键位 → HID 按键号，0 = 不接
} s2a_hidg;

// 缺省映射 + 覆盖串（NAME=号，逗号分隔）
static inline void s2a_hidg_init(s2a_hidg *h, const char *map) {
    static const char *const names[S2A_HIDG_BUTTONS] = {"A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "PLUS", "MINUS", "LEFT", "UP", "RIGHT", "DOWN"};
    static const uint8_t def[S2A_HIDG_BUTTONS] = {2, 1, 5, 4, 14, 15, 7, 8, 9, 10, 12, 11};
    memset(h, 0, sizeof *h); h->hat = -1; memcpy(h->map, def, sizeof def);
    h->axis[S2A_HIDG_BRAKE] = h->axis[S2A_HIDG_ACCEL] = -1;
    for (const char *s = map; s && *s; s = strchr(s, ',') ? strchr(s, ',') + 1 : "") {
        const char *eq = strchr(s, '='), *end = strchr(s, ',');
        if (!eq || (end && eq > end)) continue;
        int u = atoi(eq + 1);
        for (int b = 0; b < S2A_HIDG_BUTTONS; b++)
            if ((size_t)(eq - s) == strlen(names[b]) && !strncasecmp(s, names[b], (size_t)(eq - s)) && u >= 0 && u <= 32) h->map[b] = (uint8_t)u;
    }
}
// HID 用法页 / 用法号 → 轴序号；-1 = 不是手柄轴（GenericDesktop 0x30..0x35 = X Y Z Rx Ry Rz；Simulation 0xC5 刹车、0xC4 油门）
static inline int s2a_hidg_axis_of(uint32_t page, uint32_t usage) {
    if (page == 1 && usage >= 0x30 && usage <= 0x35) return S2A_HIDG_X + (int)(usage - 0x30);
    if (page == 2 && usage == 0xC5) return S2A_HIDG_BRAKE;
    if (page == 2 && usage == 0xC4) return S2A_HIDG_ACCEL;
    return -1;
}
static inline float s2a_hidg_norm(long v, long min, long max) { return max > min ? (float)(2.0 * (double)(v - min) / (double)(max - min) - 1.0) : 0; }
static inline int s2a_hidg_hat(long v, long min, long max) { return v >= min && v <= max && v - min < 8 ? (int)(v - min) : -1; }
// 一个 HID 元素的值进状态（用法页 9 = 按键，GenericDesktop 0x39 = hat，其余按轴）
static inline void s2a_hidg_value(s2a_hidg *h, uint32_t page, uint32_t usage, long v, long min, long max) {
    if (page == 9) { if (usage >= 1 && usage <= 32) { uint32_t bit = 1u << (usage - 1); h->held = v ? h->held | bit : h->held & ~bit; } return; }
    if (page == 1 && usage == 0x39) { h->hat = s2a_hidg_hat(v, min, max); return; }
    int a = s2a_hidg_axis_of(page, usage);
    if (a >= 0) h->axis[a] = s2a_hidg_norm(v, min, max);
}
static inline uint32_t s2a_hidg_buttons(const s2a_hidg *h) {
    static const uint32_t hat[8] = {1u << S2A_HIDG_UP, 1u << S2A_HIDG_UP | 1u << S2A_HIDG_RIGHT, 1u << S2A_HIDG_RIGHT, 1u << S2A_HIDG_RIGHT | 1u << S2A_HIDG_DOWN,
                                    1u << S2A_HIDG_DOWN, 1u << S2A_HIDG_DOWN | 1u << S2A_HIDG_LEFT, 1u << S2A_HIDG_LEFT, 1u << S2A_HIDG_LEFT | 1u << S2A_HIDG_UP};
    uint32_t m = 0;
    for (int b = 0; b < S2A_HIDG_BUTTONS; b++) if (h->map[b] && (h->held >> (h->map[b] - 1) & 1)) m |= 1u << b;
    if (h->hat >= 0 && h->hat < 8) m |= hat[h->hat];
    if (h->has[S2A_HIDG_BRAKE] && h->axis[S2A_HIDG_BRAKE] > 0) m |= 1u << S2A_HIDG_ZL;
    if (h->has[S2A_HIDG_ACCEL] && h->axis[S2A_HIDG_ACCEL] > 0) m |= 1u << S2A_HIDG_ZR;
    return m;
}
static inline int16_t s2a_hidg_i16(float f) { if (f < -1) f = -1; if (f > 1) f = 1; return (int16_t)(f * 32767.0f); }
// lx ly rx ry，-32767..32767、上 / 右为正；死区交给玩家键位配置那一层（front_mac.m map_pad_inputs），这里不另加
static inline void s2a_hidg_sticks(const s2a_hidg *h, int16_t s[4]) {
    int z = h->has[S2A_HIDG_Z];
    s[0] = s2a_hidg_i16(h->axis[S2A_HIDG_X]); s[1] = s2a_hidg_i16(-h->axis[S2A_HIDG_Y]);
    s[2] = s2a_hidg_i16(h->axis[z ? S2A_HIDG_Z : S2A_HIDG_RX]); s[3] = s2a_hidg_i16(-h->axis[z ? S2A_HIDG_RZ : S2A_HIDG_RY]);
}

// 走 Switch Pro 协议那一支（hid_pad.m 切 0x30 完整报告、体感）：名字带「Pro Controller」，大小写不敏感
static inline int s2a_hidg_is_pro(const char *name) { return name && strcasestr(name, "Pro Controller") != NULL; }
// 北通宙斯 NS 模式上报 Nintendo 的 VID/PID。完整蓝牙地址只用于核对前缀。
static inline int s2a_hidg_is_betop_ns(int vid, int pid, const char *transport, const char *address) {
    if (vid != 0x057e || pid != 0x2009 || !transport || strcasecmp(transport, "Bluetooth") ||
        !address || strlen(address) != 17) return 0;
    const char separator = address[2];
    if (separator != ':' && separator != '-') return 0;
    for (int i = 0; i < 17; i++) {
        if (i % 3 == 2 ? address[i] != separator : !isxdigit((unsigned char)address[i])) return 0;
    }
    return !strncasecmp(address, "00:90:E0", 8) || !strncasecmp(address, "00-90-E0", 8);
}
// 一代机身认法（joycon_imu.m 六轴轴向、拆不拆单只都照它）：产品号报左 / 右 Joy-Con（0x2006 / 0x2007）、名字却是「Pro Controller」且不带 Joy-Con 的
//   是冒用 Joy-Con 产品号的第三方 Pro（D-52Z8：0x2006 + 「Pro Controller」被按左只侧握换算六轴，体感瞄准反向）：按 Pro（0x2009）认；其余照产品号
static inline int s2a_hidg_jc_body_pid(int pid, const char *name) {
    if ((pid == 0x2006 || pid == 0x2007) && s2a_hidg_is_pro(name) && !strcasestr(name, "Joy-Con")) return 0x2009;
    return pid;
}
// 系统原生认得的厂商：微软 / 索尼 / 任天堂
static inline int s2a_hidg_native_vendor(int vid) { return vid == 0x045e || vid == 0x054c || vid == 0x057e; }
#define S2A_HIDG_GC_WAIT_US 2000000ull   // GameController 说认得时等它列出的时长（同参考实现 HIDPAD_GC_WAIT）
enum { S2A_HIDG_YIELD = 0, S2A_HIDG_TAKE = 1, S2A_HIDG_WAIT = 2 };
// 这一拍这只 HID 手柄占不占玩家位：pro = s2a_hidg_is_pro；gc_hint = supportsHIDDevice 的答复；gc_listed = GameController 这一拍列着同名手柄；
//   age_us = 接上多久（调用方给时钟，单测注入）
static inline int s2a_hidg_route(int pro, int vid, int gc_hint, int gc_listed, uint64_t age_us) {
    if (gc_listed) return S2A_HIDG_YIELD;               // 同一只不变成两个玩家（Pro 那一支原来就这样）
    if (pro) return S2A_HIDG_TAKE;                       // Pro 那一支行为不变：不看厂商号、不等（macOS 27 上原厂一代 Pro 系统也认不出，#934）
    if (s2a_hidg_native_vendor(vid)) return S2A_HIDG_YIELD;
    if (gc_hint && age_us < S2A_HIDG_GC_WAIT_US) return S2A_HIDG_WAIT;
    return S2A_HIDG_TAKE;
}
// 首次按键才占位：joined 一旦为 1 就一直是 1（断开重接从 0 起）；Pro 那一支照旧接上就占
static inline int s2a_hidg_joined(int joined, int pro, uint32_t buttons) { return joined || pro || buttons != 0; }
#endif
