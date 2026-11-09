// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#ifndef S2A_OPUS_APPLE_H
#define S2A_OPUS_APPLE_H

#include <stdint.h>

// macOS 系统 Opus 解码垫片（AudioToolbox AudioConverter），覆盖 hwopus 的全部形态：
// 单流 1/2 声道；多流（self-delimited 子流拆包 + 每子流 1/2 声道解码 + 映射交织，含 255 静音）；
// 8/12/16/24/48 kHz、2.5–120 ms。mapping == NULL 表示单流。
void *s2a_apple_open(int32_t rate, int32_t channels, int32_t streams, int32_t coupled, const uint8_t *mapping, int32_t *err);
int32_t s2a_apple_decode(void *p, const uint8_t *data, int32_t len, int16_t *pcm, int32_t frame_size);
void s2a_apple_reset(void *p);
void s2a_apple_close(void *p);

// 与 libopus opus_packet_get_nb_samples 同语义：返回每声道样本数，或 OPUS_BAD_ARG / OPUS_INVALID_PACKET
int32_t s2a_apple_packet_samples(const uint8_t *data, int32_t len, int32_t rate);

#endif
