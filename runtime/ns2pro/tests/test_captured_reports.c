#include "NS2Transport.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// 真实公开 BLE 通知，来源沿用 ns2pro-bridge 的 MotionAccessoryTests.swift；并非生成的设备样本。
// Real public BLE notifications retained from ns2pro-bridge MotionAccessoryTests.swift, not generated device samples.
// https://github.com/ndeadly/switch2_controller_research/blob/master/captures/nrf52840/btle_procon2_motion_0x000A.pcapng
// report05, handle 0x000a, frame 2147.
static const uint8_t report05[] = {
    0xa3, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xaf, 0x47, 0x84, 0x2f, 0x38, 0x85, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x2f, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0xb7, 0xab, 0x02, 0x00, 0x0a, 0x00, 0xa7, 0xff,
    0x4d, 0x02, 0x35, 0x10, 0xee, 0xff, 0x03, 0x00, 0x14, 0x00,
    0x00, 0x00, 0x00
};

// https://github.com/ndeadly/switch2_controller_research/blob/master/captures/nrf52840/btle_procon2_pairing_decrypted.pcapng
// report09, handle 0x000e, frame 514.
static const uint8_t report09[] = {
    0x01, 0x1c, 0x00, 0x00, 0x00, 0xb3, 0xc7, 0x84, 0x32, 0x98,
    0x83, 0x38, 0x00, 0x00, 0x28, 0x17, 0x80, 0x01, 0x0f, 0x43,
    0xfb, 0xff, 0x7d, 0xff, 0x3f, 0x10, 0x00, 0xe8, 0x00, 0xe0,
    0xf4, 0x20, 0xd0, 0xf9, 0x3f, 0xfb, 0xff, 0x06, 0x40, 0x01,
    0xe0, 0xf4, 0x0e, 0xc8, 0xfc, 0x5f, 0xfd, 0x5f, 0x03, 0x80,
    0x01, 0xb8, 0xe9, 0x3b, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00
};

int main(void) {
    ns2_raw_input input;
    assert(sizeof report05 == 63 && sizeof report09 == 63);
    assert(ns2_decode_input_report(5, report05, sizeof report05, &input));
    assert(input.buttons == 0);
    assert(input.lx == 1967 && input.ly == 2116);
    assert(input.rx == 2095 && input.ry == 2131);
    assert(ns2_decode_input_report(9, report09, sizeof report09, &input));
    assert(input.buttons == 0);
    assert(input.lx == 1971 && input.ly == 2124);
    assert(input.rx == 2098 && input.ry == 2105);

    ns2_motion motion;
    assert(ns2_decode_report05_motion(report05, sizeof report05, &motion));
    assert(motion.known && motion.report_counter == 3747);
    assert(motion.device_timestamp_us == 175031 && motion.host_timestamp_us == 0);
    assert(fabsf(motion.acceleration_z - 4149.f * 8.f / 32767.f) < 0.00001f);
    assert(fabsf(motion.gyro_x - -18.f * 2000.f / 32767.f) < 0.0001f);

    // Joy-Con 2 光学鼠标块（0x10 起 8 字节，小端）：抓包是 Pro 手柄、这段全 0，改几个字节当 Joy-Con 2 的读数
    ns2_mouse mouse;
    assert(ns2_decode_report05_mouse(report05, sizeof report05, &mouse));
    assert(mouse.known && mouse.x == 0 && mouse.y == 0 && mouse.distance == 0);
    uint8_t joycon05[sizeof report05];
    memcpy(joycon05, report05, sizeof joycon05);
    const uint8_t block[8] = {0xfe, 0xff, 0x34, 0x12, 0x05, 0x00, 0x06, 0x0c};   // 0x16 = 6 不算进距离（实机读数）
    memcpy(joycon05 + 0x10, block, sizeof block);
    assert(ns2_decode_report05_mouse(joycon05, sizeof joycon05, &mouse));
    assert(mouse.x == -2 && mouse.y == 0x1234 && mouse.surface == 5 && mouse.distance == 12);
    assert(!ns2_decode_report05_mouse(joycon05, sizeof joycon05 - 1, &mouse));
    assert(!mouse.known && mouse.x == 0 && mouse.distance == 0);

    ns2_info info = {0};
    assert(ns2_decode_report05_accessories(report05, sizeof report05, &info));
    assert(info.headset_connected_known && !info.headset_connected);
    assert(ns2_decode_report09_accessories(report09, sizeof report09, &info));
    assert(info.nfc_state_known && info.nfc_state == 0);
    assert(info.headset_state_known && info.headset_state == 0);

    // 对抓包截断后必须清空旧输入，避免误将残留按钮或体感当作新报告。
    // Truncating a captured frame must clear old values instead of retaining stale input or motion.
    assert(!ns2_decode_input_report(9, report09, sizeof report09 - 1, &input));
    assert(input.buttons == 0 && input.lx == 0 && input.ry == 0);
    assert(!ns2_decode_input_report(7, report05, sizeof report05, &input));
    assert(!ns2_decode_report05_motion(report05, sizeof report05 - 1, &motion));
    assert(!motion.known && motion.report_counter == 0 && motion.acceleration_z == 0);
    assert(!ns2_decode_report09_accessories(report09, sizeof report09 - 1, &info));
    assert(!info.nfc_state_known && !info.headset_state_known);
    puts("captured BLE report regression passed");
    return 0;
}
