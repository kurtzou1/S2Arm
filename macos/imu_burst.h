// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 补满采样（#2146）：0x30 全报告一包 3 组 IMU（组间 5 ms）。游戏每条六轴记录固定按 5 ms 积分，
//   所以交给游戏的条数必须等于真实流逝时间 ÷ 5 ms，否则幅度就跟着包率变：
//   - 改前每拍只给最后一组，16 ms 的动作按 5 ms 积分，幅度只有约 1/3；
//   - 一包 3 组照单全收、按收包时刻倒推 5 / 10 ms，包密时（如 8 ms 一包）每 8 ms 给 15 ms，幅度放大约 1.9 倍，
//     相邻包间隔小于 10 ms 时时间戳还会倒退（服务层 AddMotionState 见倒退就整个重建姿态，视角跳）。
// 这里按记账时钟入队：每来一包，只收「上次记到的时刻」到「收包时刻」之间装得下的组数（每组 5 ms，至多 3 组，取最新的），
//   时间戳 = 记账时钟逐组 +5 ms，严格单调、组间恰 5 ms、条数 × 5 ms = 真实流逝（包疏于 15 ms 时数据本身只够 15 ms，按数据给）。
//   扎堆到达的包（上一包晚到、紧接着下一包）记账为 0 组，下一包再补；断流超过 3 组的时长不补（没有数据）。
// 取走时丢掉比「现在」早 S2A_IMU_BURST_STALE_US 的样本：单笔路径接管期间、或服务层一拍迟到时攒下的旧样本不一次吐给游戏。
// 纯函数，无锁：调用方持自己的锁（joycon_imu.m g_mu / hid_pad.m g_mu）。单测 launchers/macos/Tests/input_test.m。
#ifndef S2A_IMU_BURST_H
#define S2A_IMU_BURST_H
#include <stdint.h>
#include "../runtime/include/s2a_pad.h"   // s2a_pad_motion

#define S2A_IMU_BURST_CAP 12
#define S2A_IMU_BURST_STEP_US 5000ull
#define S2A_IMU_BURST_STALE_US 40000ull

typedef struct {
    s2a_pad_motion q[S2A_IMU_BURST_CAP];
    int head, len;
    uint64_t clock_us;   // 已记账到的时刻（最后入队那组的时间戳）；0 = 还没收过包
} s2a_imu_burst;

static inline void s2a_imu_burst_push1(s2a_imu_burst *b, s2a_pad_motion s) {
    b->q[(b->head + b->len) % S2A_IMU_BURST_CAP] = s;
    if (b->len < S2A_IMU_BURST_CAP) b->len++;
    else b->head = (b->head + 1) % S2A_IMU_BURST_CAP;   // 满了丢最旧
}

// 一包 3 组（g[0] 最旧、g[2] 最新）在 recv_us 收到：按记账时钟入队，返回这包入队的组数（0..3）
static inline int s2a_imu_burst_push(s2a_imu_burst *b, const s2a_pad_motion g[3], uint64_t recv_us) {
    const uint64_t span = 3 * S2A_IMU_BURST_STEP_US;
    if (recv_us < span) return 0;
    if (!b->clock_us || recv_us < b->clock_us || recv_us - b->clock_us > span) b->clock_us = recv_us - span;   // 首包 / 断流：从收包前 15 ms 起记
    int k = (int)((recv_us - b->clock_us) / S2A_IMU_BURST_STEP_US);
    if (k > 3) k = 3;
    for (int j = 0; j < k; j++) {
        s2a_pad_motion s = g[3 - k + j];
        b->clock_us += S2A_IMU_BURST_STEP_US;
        s.host_timestamp_us = b->clock_us;
        s2a_imu_burst_push1(b, s);
    }
    return k;
}

// 取走（消费式、时间升序，至多 max 条）；比 now_us 早 S2A_IMU_BURST_STALE_US 以上的样本丢掉不交
static inline int s2a_imu_burst_drain(s2a_imu_burst *b, s2a_pad_motion *out, int max, uint64_t now_us) {
    int n = 0;
    while (b->len > 0) {
        s2a_pad_motion s = b->q[b->head];
        if (n >= max && s.host_timestamp_us + S2A_IMU_BURST_STALE_US >= now_us) break;
        b->head = (b->head + 1) % S2A_IMU_BURST_CAP; b->len--;
        if (s.host_timestamp_us + S2A_IMU_BURST_STALE_US < now_us) continue;
        out[n++] = s;
    }
    return n;
}

static inline void s2a_imu_burst_reset(s2a_imu_burst *b) { b->head = b->len = 0; b->clock_us = 0; }

#endif
