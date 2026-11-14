// Joy-Con 2：型号识别、SL / SR 解码、单只横握换成横握视角、左右拼成一对（竖握）。纯函数，单测 runtime/ns2pro/tests/test_joycon.c。
//   协议依据（11-10 调研，未在我方实机验证）：
//   - 广播厂商数据：m[0..1] = 53 05（公司号），m[5..6] = 7e 05（VID），m[7..8] = 产品号小端：Pro 0x2069、左 0x2067、右 0x2066
//     （ndeadly/switch2_controller_research bluetooth_interface.md、switch2mac Switch2Protocol.swift、SDL usb_ids.h）。
//   - report05 按键 32 位位表与 Pro 共用，左右各报自己的键；SL / SR：第 0 字节 0x10 = 右只 SR、0x20 = 右只 SL，
//     第 2 字节 0x10 = 左只 SR、0x20 = 左只 SL（nd hid_reports.md、switch2mac、SDL 横握左只三处一致）。
//   - 每只一根摇杆：左只在第一个摇杆字段，右只在第二个；两只都只有主校准（0x13080）。
//   - 横握：按键随朝向转（SDL 一代 SDL_hidapi_switch.c 与 services/S2A.Services/InputPump.cs RotateSideways 的逆变换一致；
//     SDL 二代没转面键，不照它）；SL / SR 当 L / R；摇杆左只 (x, y) → (−y, x)、右只 → (y, −x)；
//     六轴左只 (x, z) → (z, −x)、右只 → (−z, x)（SDL_hidapi_switch2.c）。
#include "NS2Transport.h"

ns2_kind ns2_kind_from_manufacturer(const uint8_t *m, size_t length) {
    if (!m || length < 9 || m[0] != 0x53 || m[1] != 0x05 || m[5] != 0x7e || m[6] != 0x05) return NS2_KIND_NONE;
    switch (m[7] | m[8] << 8) {
        case 0x2069: return NS2_KIND_PRO;
        case 0x2067: return NS2_KIND_JOYCON_L;
        case 0x2066: return NS2_KIND_JOYCON_R;
        default: return NS2_KIND_NONE;
    }
}

int ns2_decode_side_buttons(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 7) return 0;
    const uint8_t *b = bytes + 4;   // report05 按键字段从第 4 字节起（同 ns2_decode_input_report）
    return (b[2] & 0x20 ? NS2_SIDE_SL_L : 0) | (b[2] & 0x10 ? NS2_SIDE_SR_L : 0) |
           (b[0] & 0x20 ? NS2_SIDE_SL_R : 0) | (b[0] & 0x10 ? NS2_SIDE_SR_R : 0);
}

enum { A, B, X, Y, LS, RS, L, R, ZL, ZR, PLUS, MINUS, LEFT, UP, RIGHT, DOWN, HOME, CAPTURE };
#define BIT(n) (1ull << (n))
#define HAS(s, n) (((s) >> (n)) & 1)

void ns2_joycon_sideways(ns2_kind kind, int side_buttons, ns2_state *s) {
    if (!s || (kind != NS2_KIND_JOYCON_L && kind != NS2_KIND_JOYCON_R)) return;
    uint64_t in = s->buttons, out = 0;
    int32_t x, y;
    if (kind == NS2_KIND_JOYCON_L) {
        // 方向键当面键：上 → Y（西）、右 → X（北）、下 → A（东）、左 → B（南）；左摇杆按下照旧；Minus 当开始键、Capture 当 Home
        out |= HAS(in, UP) ? BIT(Y) : 0; out |= HAS(in, RIGHT) ? BIT(X) : 0; out |= HAS(in, DOWN) ? BIT(A) : 0; out |= HAS(in, LEFT) ? BIT(B) : 0;
        out |= HAS(in, LS) ? BIT(LS) : 0; out |= HAS(in, MINUS) ? BIT(PLUS) : 0; out |= HAS(in, CAPTURE) ? BIT(HOME) : 0;
        out |= side_buttons & NS2_SIDE_SL_L ? BIT(L) : 0; out |= side_buttons & NS2_SIDE_SR_L ? BIT(R) : 0;
        x = -s->ly; y = s->lx;
    } else {
        // 面键：X → A、A → B、B → Y、Y → X；右摇杆按下当左摇杆按下；Plus 照旧、Home 照旧
        out |= HAS(in, X) ? BIT(A) : 0; out |= HAS(in, A) ? BIT(B) : 0; out |= HAS(in, B) ? BIT(Y) : 0; out |= HAS(in, Y) ? BIT(X) : 0;
        out |= HAS(in, RS) ? BIT(LS) : 0; out |= HAS(in, PLUS) ? BIT(PLUS) : 0; out |= HAS(in, HOME) ? BIT(HOME) : 0;
        out |= side_buttons & NS2_SIDE_SL_R ? BIT(L) : 0; out |= side_buttons & NS2_SIDE_SR_R ? BIT(R) : 0;
        x = s->ry; y = -s->rx;
    }
    // 单只横握是一个小手柄：唯一的摇杆当左摇杆，右摇杆为 0
    s->buttons = out; s->lx = x; s->ly = y; s->rx = 0; s->ry = 0;
}

void ns2_joycon_raw(ns2_kind kind, int side_buttons, ns2_state *s) {
    if (!s || (kind != NS2_KIND_JOYCON_L && kind != NS2_KIND_JOYCON_R)) return;
    int left = kind == NS2_KIND_JOYCON_L;
    s->buttons &= ~(BIT(NS2_BUTTON_SL) | BIT(NS2_BUTTON_SR));
    s->buttons |= side_buttons & (left ? NS2_SIDE_SL_L : NS2_SIDE_SL_R) ? BIT(NS2_BUTTON_SL) : 0;
    s->buttons |= side_buttons & (left ? NS2_SIDE_SR_L : NS2_SIDE_SR_R) ? BIT(NS2_BUTTON_SR) : 0;
}

void ns2_joycon_raw_to_sideways(ns2_kind kind, ns2_state *s) {
    if (!s || (kind != NS2_KIND_JOYCON_L && kind != NS2_KIND_JOYCON_R)) return;
    int left = kind == NS2_KIND_JOYCON_L;
    int side = (HAS(s->buttons, NS2_BUTTON_SL) ? (left ? NS2_SIDE_SL_L : NS2_SIDE_SL_R) : 0) |
               (HAS(s->buttons, NS2_BUTTON_SR) ? (left ? NS2_SIDE_SR_L : NS2_SIDE_SR_R) : 0);
    ns2_joycon_sideways(kind, side, s);
}

void ns2_joycon_sideways_motion(ns2_kind kind, ns2_motion *m) {
    if (!m || (kind != NS2_KIND_JOYCON_L && kind != NS2_KIND_JOYCON_R)) return;
    float ax = m->acceleration_x, az = m->acceleration_z, gx = m->gyro_x, gz = m->gyro_z;
    if (kind == NS2_KIND_JOYCON_L) { m->acceleration_x = az; m->acceleration_z = -ax; m->gyro_x = gz; m->gyro_z = -gx; }
    else { m->acceleration_x = -az; m->acceleration_z = ax; m->gyro_x = -gz; m->gyro_z = gx; }
}

// 左右拼成一对（竖握，同 SDL 自动拼对与 switch2mac）：按键取并集——两只各报自己的键，SL / SR 不在 21 位按键表里，自然不映射；
//   左摇杆取左只（第一个摇杆字段），右摇杆取右只（第二个摇杆字段）；不做横握转向。
void ns2_joycon_pair_state(const ns2_state *left, const ns2_state *right, ns2_state *out) {
    if (!out) return;
    ns2_state l = left ? *left : (ns2_state){0}, r = right ? *right : (ns2_state){0};
    *out = (ns2_state){l.buttons | r.buttons, l.lx, l.ly, r.rx, r.ry};
}

// 震动包：同 Pro 的 42 字节、同一编码，但每只一个线性马达，只在 0x01 处放一块（左只取左侧值、右只取右侧值），0x11 起的第二块全 0
//   （nd hid_reports.md：Joy-Con 震动报告 42 字节，0x01–0x10 一块；SDL 对 Joy-Con 与 Pro 调同一个 HD 震动编码，不复制第二块）
void ns2_encode_rumble_for(ns2_kind kind, const ns2_vibration values[2], uint8_t sequence, float gain, uint8_t out[42]) {
    if (kind != NS2_KIND_JOYCON_L && kind != NS2_KIND_JOYCON_R) { ns2_encode_rumble(values, sequence, gain, out); return; }
    ns2_vibration one[2] = {values[kind == NS2_KIND_JOYCON_L ? 0 : 1], {0}};
    ns2_encode_rumble(one, sequence, gain, out);
    for (unsigned i = 17; i < 42; i++) out[i] = 0;
}

// 扫描策略（11-11 实机：记着左只、左只没开机时，右只长按 SYNC 也连不上——只直连记住的那只不扫描，直连 30 秒超时失败时又把扫描停掉）
int ns2_scan_wants_other_side(ns2_kind only, int only_ready, int only_failed) {
    (void)only_ready;   // 就绪与否都扫：改前要求已就绪，记住的那只没开机时直连等 30 秒，这段时间另一侧找不到
    return (only == NS2_KIND_JOYCON_L || only == NS2_KIND_JOYCON_R) && !only_failed;
}

int ns2_link_failure_stops_scan(ns2_kind failed) {
    return failed != NS2_KIND_JOYCON_L && failed != NS2_KIND_JOYCON_R;
}

ns2_kind ns2_output_kind(ns2_kind a, int a_present, ns2_kind b, int b_present) {
    int a_jc = a == NS2_KIND_JOYCON_L || a == NS2_KIND_JOYCON_R, b_jc = b == NS2_KIND_JOYCON_L || b == NS2_KIND_JOYCON_R;
    if (a_present && b_present && a_jc && b_jc && a != b) return NS2_KIND_JOYCON_PAIR;
    if (a_present) return a;
    if (b_present) return b;
    return NS2_KIND_NONE;
}
int ns2_joycon_split_wanted(ns2_kind kind, int side_buttons) {
    int want = kind == NS2_KIND_JOYCON_L ? (NS2_SIDE_SL_L | NS2_SIDE_SR_L) : kind == NS2_KIND_JOYCON_R ? (NS2_SIDE_SL_R | NS2_SIDE_SR_R) : 0;
    return want && (side_buttons & want) == want;
}
ns2_assign_gesture ns2_assign_gesture_of(ns2_kind kind, uint64_t buttons, int side_buttons) {
    int l = (buttons >> L) & 1, r = (buttons >> R) & 1;
    switch (kind) {
    case NS2_KIND_PRO: case NS2_KIND_JOYCON_PAIR: return l && r ? NS2_ASSIGN_WHOLE : NS2_ASSIGN_NONE;
    case NS2_KIND_JOYCON_L: case NS2_KIND_JOYCON_R:
        if (ns2_joycon_split_wanted(kind, side_buttons)) return NS2_ASSIGN_SINGLE;   // SL + SR 优先：横握时手指压着 SL / SR，顺带碰到肩键也算单只
        return (kind == NS2_KIND_JOYCON_L ? l : r) ? NS2_ASSIGN_HALF : NS2_ASSIGN_NONE;
    default: return NS2_ASSIGN_NONE;
    }
}

