// macos/hid_generic.h（通用 HID 手柄映射 / 让位 / 首次按键占位）的无设备单测。期望值照参考实现 nxnative（MIT）dm/host/pad_hid.h、pad_hid_mac.h 的规则手写。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE   // glibc 的 strcasestr
#endif
#include <stdio.h>
#include "hid_generic.h"

static int fails, checks;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

enum { A = 1u << 0, B = 1u << 1, X = 1u << 2, Y = 1u << 3, LS = 1u << 4, RS = 1u << 5, L = 1u << 6, R = 1u << 7, ZL = 1u << 8, ZR = 1u << 9,
       PLUS = 1u << 10, MINUS = 1u << 11, LEFT = 1u << 12, UP = 1u << 13, RIGHT = 1u << 14, DOWN = 1u << 15 };

static uint32_t press(const char *map, int usage) {   // 只按 HID 按键号 usage 一颗
    s2a_hidg h; s2a_hidg_init(&h, map); s2a_hidg_value(&h, 9, (uint32_t)usage, 1, 0, 1); return s2a_hidg_buttons(&h);
}

int main(void) {
    // 缺省按钮：八位堂 D-input 编号 1 A、2 B、4 X、5 Y、7 / 8 L / R、9 / 10 ZL / ZR、11 −、12 +、14 / 15 摇杆按下；按位置给（右 A 下 B 上 X 左 Y）
    //   1 号是八位堂的 A（下）→ 位置 B；2 号（右）→ A；4 号（左）→ Y；5 号（上）→ X
    CHECK(press(NULL, 2) == A && press(NULL, 1) == B && press(NULL, 5) == X && press(NULL, 4) == Y, "缺省四颗面键按位置");
    CHECK(press(NULL, 7) == L && press(NULL, 8) == R && press(NULL, 9) == ZL && press(NULL, 10) == ZR, "缺省肩键 / 扳机键");
    CHECK(press(NULL, 11) == MINUS && press(NULL, 12) == PLUS && press(NULL, 14) == LS && press(NULL, 15) == RS, "缺省 − + 与摇杆按下");
    CHECK(press(NULL, 3) == 0 && press(NULL, 6) == 0 && press(NULL, 13) == 0 && press(NULL, 16) == 0 && press(NULL, 32) == 0, "缺省没接的号不出键");
    { s2a_hidg h; s2a_hidg_init(&h, NULL); s2a_hidg_value(&h, 9, 2, 1, 0, 1); s2a_hidg_value(&h, 9, 1, 1, 0, 1); s2a_hidg_value(&h, 9, 2, 0, 0, 1);
      CHECK(s2a_hidg_buttons(&h) == B, "按下再松开：只剩还按着的"); }

    // 覆盖（S2A_HID_MAP / DM_HID_MAP 同一写法）：逐键替换，没写的照缺省；键名不分大小写；号 > 32、不认识的键名、缺等号的项跳过
    CHECK(press("A=1,B=2", 1) == A && press("A=1,B=2", 2) == B && press("A=1,B=2", 5) == X, "覆盖 A / B，X 照缺省");
    CHECK(press("up=3", 3) == UP && press("Plus=13", 13) == PLUS && press("plus=13", 12) == 0, "键名不分大小写；PLUS 改号后原号不再出键");
    CHECK(press("A=33", 2) == A && press("FOO=3", 3) == 0 && press("A", 2) == A && press("A=0", 2) == 0, "号越界 / 键名不认识 / 缺等号跳过；=0 关掉这颗");
    CHECK(press("ZL=6,,B=3", 6) == ZL && press("ZL=6,,B=3", 3) == B, "空项跳过、后面照读");

    // 轴：逻辑范围归一到 -32767..32767，Y 上为正；X / Y 左摇杆，Z / Rz 右摇杆；没有 Z 用 Rx / Ry
    { s2a_hidg h; s2a_hidg_init(&h, NULL); h.has[S2A_HIDG_Z] = 1; int16_t s[4];
      s2a_hidg_value(&h, 1, 0x30, 255, 0, 255); s2a_hidg_value(&h, 1, 0x31, 0, 0, 255);      // 左摇杆右上
      s2a_hidg_value(&h, 1, 0x32, 0, 0, 255); s2a_hidg_value(&h, 1, 0x35, 255, 0, 255);      // 右摇杆左下
      s2a_hidg_value(&h, 1, 0x33, 255, 0, 255); s2a_hidg_value(&h, 1, 0x34, 255, 0, 255);    // 有 Z 时 Rx / Ry 不进右摇杆
      s2a_hidg_sticks(&h, s);
      CHECK(s[0] == 32767 && s[1] == 32767 && s[2] == -32767 && s[3] == -32767, "有 Z：Z / Rz 是右摇杆，Y 上为正"); }
    { s2a_hidg h; s2a_hidg_init(&h, NULL); int16_t s[4];
      s2a_hidg_value(&h, 1, 0x33, -32768, -32768, 32767); s2a_hidg_value(&h, 1, 0x34, 32767, -32768, 32767);
      s2a_hidg_value(&h, 1, 0x32, 32767, -32768, 32767);   // 没声明 Z：Z 的值不进右摇杆
      s2a_hidg_sticks(&h, s);
      CHECK(s[0] == 0 && s[1] == 0 && s[2] == -32767 && s[3] == -32767, "没 Z：右摇杆用 Rx / Ry，Ry 最大 = 下"); }
    { s2a_hidg h; s2a_hidg_init(&h, NULL); int16_t s[4];
      s2a_hidg_value(&h, 1, 0x30, 192, 0, 256); s2a_hidg_value(&h, 1, 0x31, 5, 5, 5);   // 3/4 处 = 0.5；min == max 的坏范围 = 0
      s2a_hidg_sticks(&h, s);
      CHECK(s[0] == 16383 && s[1] == 0, "四分之三处 = 半推（0.5 × 32767 取整 16383）；坏范围归 0"); }
    CHECK(s2a_hidg_axis_of(1, 0x30) == S2A_HIDG_X && s2a_hidg_axis_of(1, 0x35) == S2A_HIDG_RZ && s2a_hidg_axis_of(2, 0xC5) == S2A_HIDG_BRAKE &&
          s2a_hidg_axis_of(2, 0xC4) == S2A_HIDG_ACCEL && s2a_hidg_axis_of(1, 0x36) == -1 && s2a_hidg_axis_of(9, 0x30) == -1, "轴用法号表");

    // hat：0 上，顺时针到 7 左上；范围外（含常见的 8 = 松开、负值）居中；min 不是 0 的照偏移算
    { static const uint32_t want[8] = {UP, UP | RIGHT, RIGHT, RIGHT | DOWN, DOWN, DOWN | LEFT, LEFT, LEFT | UP};
      int ok = 1;
      for (int v = 0; v < 8; v++) { s2a_hidg h; s2a_hidg_init(&h, NULL); s2a_hidg_value(&h, 1, 0x39, v, 0, 7); if (s2a_hidg_buttons(&h) != want[v]) ok = 0; }
      CHECK(ok, "hat 八方向");
      s2a_hidg h; s2a_hidg_init(&h, NULL);
      CHECK(s2a_hidg_buttons(&h) == 0, "初始居中");
      s2a_hidg_value(&h, 1, 0x39, 3, 0, 7); s2a_hidg_value(&h, 1, 0x39, 8, 0, 7); CHECK(s2a_hidg_buttons(&h) == 0, "8 = 居中（越过 max）");
      s2a_hidg_value(&h, 1, 0x39, 15, 0, 15); CHECK(s2a_hidg_buttons(&h) == 0, "范围内但超过 8 个方向 = 居中");
      s2a_hidg_value(&h, 1, 0x39, 1, 1, 8); CHECK(s2a_hidg_buttons(&h) == UP, "min = 1 时 1 是上");
      s2a_hidg_value(&h, 1, 0x39, 0, 1, 8); CHECK(s2a_hidg_buttons(&h) == 0, "低于 min = 居中");
      s2a_hidg_value(&h, 1, 0x39, 5, 0, 3); CHECK(s2a_hidg_buttons(&h) == 0, "高于 max（即使不到 8）= 居中"); }

    // 扳机：Brake → ZL、Accelerator → ZR，过半才按（松开在 -1，正中 0 不算）；设备没声明这根轴就不看
    { s2a_hidg h; s2a_hidg_init(&h, NULL); h.has[S2A_HIDG_BRAKE] = h.has[S2A_HIDG_ACCEL] = 1;
      CHECK(s2a_hidg_buttons(&h) == 0, "扳机松开不按");
      s2a_hidg_value(&h, 2, 0xC5, 64, 0, 255); CHECK(s2a_hidg_buttons(&h) == 0, "按下四分之一不到一半：不按");
      s2a_hidg_value(&h, 2, 0xC5, 128, 0, 255); s2a_hidg_value(&h, 2, 0xC4, 127, 0, 255);
      CHECK(s2a_hidg_buttons(&h) == ZL, "128/255 过半按 ZL；127/255 没过半");
      s2a_hidg_value(&h, 2, 0xC4, 255, 0, 255); CHECK(s2a_hidg_buttons(&h) == (ZL | ZR), "按到底 ZR");
      s2a_hidg_value(&h, 2, 0xC5, 0, 0, 255); CHECK(s2a_hidg_buttons(&h) == ZR, "松开 ZL"); }
    { s2a_hidg h; s2a_hidg_init(&h, NULL); s2a_hidg_value(&h, 2, 0xC5, 255, 0, 255); CHECK(s2a_hidg_buttons(&h) == 0, "没声明 Brake 不出 ZL"); }

    // 让位判定（注入时钟 age_us）
    CHECK(s2a_hidg_route(0, 0x18d1, 0, 1, 10000000) == S2A_HIDG_YIELD, "GameController 已列出同名：让");
    CHECK(s2a_hidg_route(0, 0x18d1, 0, 0, 0) == S2A_HIDG_TAKE, "系统不认（supportsHIDDevice 否）：刚接上就读");
    CHECK(s2a_hidg_route(0, 0x045e, 0, 0, 10000000) == S2A_HIDG_YIELD && s2a_hidg_route(0, 0x054c, 1, 0, 10000000) == S2A_HIDG_YIELD &&
          s2a_hidg_route(0, 0x057e, 0, 0, 10000000) == S2A_HIDG_YIELD, "微软 / 索尼 / 任天堂通用手柄：让，不管等多久");
    CHECK(s2a_hidg_route(0, 0x2dc8, 1, 0, 0) == S2A_HIDG_WAIT && s2a_hidg_route(0, 0x2dc8, 1, 0, 1999999) == S2A_HIDG_WAIT, "系统说认得：2 秒内等");
    CHECK(s2a_hidg_route(0, 0x2dc8, 1, 0, 2000000) == S2A_HIDG_TAKE, "满 2 秒系统还没列出：按 HID 读");
    CHECK(s2a_hidg_route(0, 0x2dc8, 1, 1, 1000000) == S2A_HIDG_YIELD && s2a_hidg_route(0, 0x2dc8, 1, 1, 60000000) == S2A_HIDG_YIELD, "等的期间或读了之后系统列出：让回去");
    // Pro 那一支行为不变：不看厂商号、不等；系统列出同名就让——同一只手柄不变成两个玩家
    CHECK(s2a_hidg_route(1, 0x057e, 1, 0, 0) == S2A_HIDG_TAKE && s2a_hidg_route(1, 0, 0, 0, 0) == S2A_HIDG_TAKE, "Pro：原厂 / 0 号厂商都立刻读");
    CHECK(s2a_hidg_route(1, 0x057e, 1, 1, 0) == S2A_HIDG_YIELD && s2a_hidg_route(1, 0, 0, 1, 5000000) == S2A_HIDG_YIELD, "Pro：系统列出同名就让（不成两个玩家）");
    CHECK(s2a_hidg_is_pro("Lic Pro Controller") && s2a_hidg_is_pro("PRO CONTROLLER") && !s2a_hidg_is_pro("Stadia Controller") && !s2a_hidg_is_pro(""), "Pro 那一支按名字");
    CHECK(s2a_hidg_jc_body_pid(0x2006, "Pro Controller") == 0x2009 && s2a_hidg_jc_body_pid(0x2007, "Wireless Pro Controller") == 0x2009, "冒用 Joy-Con 产品号的第三方 Pro：按 Pro 认");
    CHECK(s2a_hidg_jc_body_pid(0x2006, "Joy-Con (L)") == 0x2006 && s2a_hidg_jc_body_pid(0x2007, "Joy-Con (R)") == 0x2007 && s2a_hidg_jc_body_pid(0x2006, NULL) == 0x2006 &&
          s2a_hidg_jc_body_pid(0x2006, "Joy-Con Pro Controller Grip") == 0x2006 && s2a_hidg_jc_body_pid(0x2009, "Pro Controller") == 0x2009, "真 Joy-Con / 没名字 / 真 Pro：照产品号");

    // 首次按键才占位：没按过 + 没按 = 不占；按过一次之后松开也一直占；Pro 那一支接上就占
    CHECK(!s2a_hidg_joined(0, 0, 0), "没按过不占位（键盘接收器）");
    CHECK(s2a_hidg_joined(0, 0, B) && s2a_hidg_joined(1, 0, 0), "按一下就占，松开照占");
    CHECK(s2a_hidg_joined(0, 1, 0), "Pro 接上就占（行为不变）");
    { s2a_hidg h; s2a_hidg_init(&h, NULL); h.has[S2A_HIDG_ACCEL] = 1; int joined = 0;
      s2a_hidg_value(&h, 1, 0x30, 255, 0, 255); s2a_hidg_value(&h, 9, 3, 1, 0, 1);   // 推摇杆、按没接的 3 号键：都不算按键
      joined = s2a_hidg_joined(joined, 0, s2a_hidg_buttons(&h)); CHECK(!joined, "摇杆 / 没接的键不占位");
      s2a_hidg_value(&h, 2, 0xC4, 255, 0, 255); joined = s2a_hidg_joined(joined, 0, s2a_hidg_buttons(&h)); CHECK(joined, "扳机过半算按键，占位");
      s2a_hidg_value(&h, 2, 0xC4, 0, 0, 255); joined = s2a_hidg_joined(joined, 0, s2a_hidg_buttons(&h)); CHECK(joined, "松开照占"); }

    if (fails) printf("✗ t_hid_generic：%d 项里 %d 项不通\n", checks, fails); else printf("✓ t_hid_generic：%d 项全过（通用 HID 手柄映射 / 让位 / 首次按键占位）\n", checks);
    return fails ? 1 : 0;
}
