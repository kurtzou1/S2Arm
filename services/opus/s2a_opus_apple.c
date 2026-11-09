// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

// macOS 系统 Opus 解码垫片（AudioToolbox AudioConverter），全量覆盖 hwopus：
//   单流 1/2 声道；多流按 RFC 6716 self-delimited 拆子流，每子流一个 1/2 声道 AudioConverter，
//   再按 mapping 交织（255 = 静音声道）；8/12/16/24/48 kHz、2.5–120 ms。
// 包解析/校验/时长按 libopus 的 opus_packet_parse / opus_packet_get_nb_samples 语义逐行复刻：
//   全量替换后宿主不再链 libopus，且系统解码器对坏包静默返回 0 帧，必须自己先校验。
// 系统行为（实测）：AudioConverter 必须设 kAudioConverterPrimeInfo={0,0}（否则首包少 120 帧），
//   输入 ASBD 的 mFramesPerPacket 必须为 0（否则 2.5/10 ms 包解不出）；kAudioConverterPrimeMethod 在这条链上返回错误，不能设。
#include "s2a_opus_apple.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>

#include "opus_defines.h"

#define S2A_APPLE_MAX_FRAMES 48

typedef struct
{
    AudioConverterRef converter;
    int32_t channels; // 1 / 2
} s2a_apple_stream;

typedef struct
{
    int32_t rate;
    int32_t channels;
    int32_t streams;
    int32_t coupled;
    int32_t single;
    uint8_t mapping[256];
    s2a_apple_stream *st;
    int16_t *pcm;      // 多流子流解码暂存：2 * 每声道最大样本数
    uint8_t *repack;   // self-delimited 子流去掉长度字段后的暂存，按需增长
    int32_t repack_cap;
} s2a_apple;

typedef struct
{
    const uint8_t *data;
    int32_t length;
    int32_t frames;
    int32_t channels;
    int32_t served;
    AudioStreamPacketDescription desc;
} s2a_apple_feed;

static OSStatus s2a_apple_feed_cb(AudioConverterRef converter, UInt32 *ioNumberDataPackets,
                                  AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription,
                                  void *userData)
{
    (void)converter;

    s2a_apple_feed *feed = userData;

    if (feed->served)
    {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    if (outDataPacketDescription != NULL)
    {
        feed->desc.mStartOffset = 0;
        feed->desc.mVariableFramesInPacket = feed->frames;
        feed->desc.mDataByteSize = feed->length;
        *outDataPacketDescription = &feed->desc;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = (UInt32)feed->channels;
    ioData->mBuffers[0].mDataByteSize = (UInt32)feed->length;
    ioData->mBuffers[0].mData = (void *)feed->data;
    *ioNumberDataPackets = 1;
    feed->served = 1;

    return noErr;
}

// libopus opus_packet_get_samples_per_frame
static int32_t s2a_apple_frame_samples(const uint8_t *data, int32_t fs)
{
    int32_t audiosize;

    if (data[0] & 0x80)
    {
        audiosize = (data[0] >> 3) & 0x3;
        audiosize = (fs << audiosize) / 400;
    }
    else if ((data[0] & 0x60) == 0x60)
    {
        audiosize = (data[0] & 0x08) ? fs / 50 : fs / 100;
    }
    else
    {
        audiosize = (data[0] >> 3) & 0x3;

        if (audiosize == 3)
        {
            audiosize = fs * 60 / 1000;
        }
        else
        {
            audiosize = (fs << audiosize) / 100;
        }
    }

    return audiosize;
}

// libopus parse_size
static int32_t s2a_apple_parse_size(const uint8_t *data, int32_t len, int16_t *size)
{
    if (len < 1)
    {
        *size = -1;
        return -1;
    }
    else if (data[0] < 252)
    {
        *size = data[0];
        return 1;
    }
    else if (len < 2)
    {
        *size = -1;
        return -1;
    }

    *size = (int16_t)(4 * data[1] + data[0]);
    return 2;
}

// libopus opus_packet_parse_impl 的等价实现。header_end 为 self-delimited 长度字段前的偏移，
// payload_offset 为长度字段后的偏移：重打包 = [0, header_end) + [payload_offset, packet_offset)。
static int32_t s2a_apple_parse_packet(const uint8_t *data, int32_t len, int self_delimited,
                                      uint8_t *out_toc, const uint8_t *frames[S2A_APPLE_MAX_FRAMES],
                                      int16_t size[S2A_APPLE_MAX_FRAMES], int32_t *payload_offset,
                                      int32_t *packet_offset, int32_t *header_end)
{
    int32_t i;
    int32_t bytes;
    int32_t count;
    int32_t cbr;
    uint8_t ch;
    uint8_t toc;
    int32_t framesize;
    int32_t last_size;
    int32_t pad = 0;
    const uint8_t *data0 = data;

    if (size == NULL || len < 0)
    {
        return OPUS_BAD_ARG;
    }

    if (len == 0)
    {
        return OPUS_INVALID_PACKET;
    }

    framesize = s2a_apple_frame_samples(data, 48000);

    cbr = 0;
    toc = *data++;
    len--;
    last_size = len;

    switch (toc & 0x3)
    {
        case 0:
            count = 1;
            break;

        case 1:
            count = 2;
            cbr = 1;

            if (!self_delimited)
            {
                if (len & 0x1)
                {
                    return OPUS_INVALID_PACKET;
                }

                last_size = len / 2;
                size[0] = (int16_t)last_size;
            }
            break;

        case 2:
            count = 2;
            bytes = s2a_apple_parse_size(data, len, size);

            if (bytes < 0)
            {
                return OPUS_INVALID_PACKET;
            }

            len -= bytes;

            if (size[0] < 0 || size[0] > len)
            {
                return OPUS_INVALID_PACKET;
            }

            data += bytes;
            last_size = len - size[0];
            break;

        default:
            if (len < 1)
            {
                return OPUS_INVALID_PACKET;
            }

            ch = *data++;
            count = ch & 0x3F;

            if (count <= 0 || framesize * (int32_t)count > 5760)
            {
                return OPUS_INVALID_PACKET;
            }

            len--;

            if (ch & 0x40)
            {
                int32_t p;

                do
                {
                    int32_t tmp;

                    if (len <= 0)
                    {
                        return OPUS_INVALID_PACKET;
                    }

                    p = *data++;
                    len--;
                    tmp = p == 255 ? 254 : p;
                    len -= tmp;
                    pad += tmp;
                } while (p == 255);
            }

            if (len < 0)
            {
                return OPUS_INVALID_PACKET;
            }

            cbr = !(ch & 0x80);

            if (!cbr)
            {
                last_size = len;

                for (i = 0; i < count - 1; i++)
                {
                    bytes = s2a_apple_parse_size(data, len, size + i);

                    if (bytes < 0)
                    {
                        return OPUS_INVALID_PACKET;
                    }

                    len -= bytes;

                    if (size[i] < 0 || size[i] > len)
                    {
                        return OPUS_INVALID_PACKET;
                    }

                    data += bytes;
                    last_size -= bytes + size[i];
                }

                if (last_size < 0)
                {
                    return OPUS_INVALID_PACKET;
                }
            }
            else if (!self_delimited)
            {
                last_size = len / count;

                if (last_size * count != len)
                {
                    return OPUS_INVALID_PACKET;
                }

                for (i = 0; i < count - 1; i++)
                {
                    size[i] = (int16_t)last_size;
                }
            }
            break;
    }

    if (header_end != NULL)
    {
        *header_end = (int32_t)(data - data0);
    }

    if (self_delimited)
    {
        bytes = s2a_apple_parse_size(data, len, size + count - 1);

        if (bytes < 0)
        {
            return OPUS_INVALID_PACKET;
        }

        len -= bytes;

        if (size[count - 1] < 0 || size[count - 1] > len)
        {
            return OPUS_INVALID_PACKET;
        }

        data += bytes;

        if (cbr)
        {
            if (size[count - 1] * count > len)
            {
                return OPUS_INVALID_PACKET;
            }

            for (i = 0; i < count - 1; i++)
            {
                size[i] = size[count - 1];
            }
        }
        else if (bytes + size[count - 1] > last_size)
        {
            return OPUS_INVALID_PACKET;
        }
    }
    else
    {
        if (last_size > 1275)
        {
            return OPUS_INVALID_PACKET;
        }

        size[count - 1] = (int16_t)last_size;
    }

    if (payload_offset != NULL)
    {
        *payload_offset = (int32_t)(data - data0);
    }

    for (i = 0; i < count; i++)
    {
        if (frames != NULL)
        {
            frames[i] = data;
        }

        data += size[i];
    }

    if (packet_offset != NULL)
    {
        *packet_offset = pad + (int32_t)(data - data0);
    }

    if (out_toc != NULL)
    {
        *out_toc = toc;
    }

    return count;
}

int32_t s2a_apple_packet_samples(const uint8_t *data, int32_t len, int32_t rate)
{
    int32_t count;
    int32_t samples;

    if (len < 1)
    {
        return OPUS_BAD_ARG;
    }

    count = data[0] & 0x3;

    if (count == 0)
    {
        count = 1;
    }
    else if (count != 3)
    {
        count = 2;
    }
    else if (len < 2)
    {
        return OPUS_INVALID_PACKET;
    }
    else
    {
        count = data[1] & 0x3F;
    }

    samples = count * s2a_apple_frame_samples(data, rate);

    // 不能超过 120 ms（libopus 同款判断）
    if (samples * 25 > rate * 3)
    {
        return OPUS_INVALID_PACKET;
    }

    return samples;
}

static int32_t s2a_apple_rate_ok(int32_t rate)
{
    return rate == 8000 || rate == 12000 || rate == 16000 || rate == 24000 || rate == 48000;
}

static AudioConverterRef s2a_apple_converter_new(int32_t rate, int32_t channels)
{
    AudioStreamBasicDescription input = {0};
    AudioStreamBasicDescription output = {0};

    input.mSampleRate = rate;
    input.mFormatID = kAudioFormatOpus;
    input.mChannelsPerFrame = (UInt32)channels;
    input.mFramesPerPacket = 0;

    output.mSampleRate = rate;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    output.mBytesPerPacket = (UInt32)channels * sizeof(int16_t);
    output.mFramesPerPacket = 1;
    output.mBytesPerFrame = (UInt32)channels * sizeof(int16_t);
    output.mChannelsPerFrame = (UInt32)channels;
    output.mBitsPerChannel = 16;

    AudioConverterRef converter = NULL;

    if (AudioConverterNew(&input, &output, &converter) != noErr)
    {
        return NULL;
    }

    // 只设 PrimeInfo：kAudioConverterPrimeMethod 在 Opus 解码链上会返回错误（实测），默认方法 + lead=0 已足够；
    //   不关掉预卷时首包只出 840 帧，hwopus 的 outSamples 会与包内样本数对不上
    AudioConverterPrimeInfo primeInfo = {0, 0};

    if (AudioConverterSetProperty(converter, kAudioConverterPrimeInfo, sizeof primeInfo, &primeInfo) != noErr)
    {
        AudioConverterDispose(converter);
        return NULL;
    }

    return converter;
}

static void s2a_apple_free(s2a_apple *handle)
{
    int32_t s;

    if (handle == NULL)
    {
        return;
    }

    if (handle->st != NULL)
    {
        for (s = 0; s < handle->streams; s++)
        {
            if (handle->st[s].converter != NULL)
            {
                AudioConverterDispose(handle->st[s].converter);
            }
        }
    }

    free(handle->st);
    free(handle->pcm);
    free(handle->repack);
    free(handle);
}

void *s2a_apple_open(int32_t rate, int32_t channels, int32_t streams, int32_t coupled, const uint8_t *mapping, int32_t *err)
{
    s2a_apple *handle;
    int32_t s;
    int32_t single = mapping == NULL;

    *err = OPUS_BAD_ARG;

    if (!s2a_apple_rate_ok(rate) || channels < 1)
    {
        return NULL;
    }

    if (single)
    {
        // libopus 单流解码器只接受 1/2 声道
        if (channels > 2)
        {
            return NULL;
        }

        streams = 1;
        coupled = 0;
    }
    else
    {
        if (channels > 255 || streams < 1 || coupled < 0 || coupled > streams || streams > 255 - coupled)
        {
            return NULL;
        }

        if (streams + coupled > 255)
        {
            return NULL;
        }

        for (s = 0; s < channels; s++)
        {
            if (mapping[s] != 255 && mapping[s] >= streams + coupled)
            {
                return NULL;
            }
        }
    }

    handle = calloc(1, sizeof *handle);

    if (handle == NULL)
    {
        *err = OPUS_ALLOC_FAIL;
        return NULL;
    }

    handle->rate = rate;
    handle->channels = channels;
    handle->streams = streams;
    handle->coupled = coupled;
    handle->single = single;

    if (!single)
    {
        memcpy(handle->mapping, mapping, (size_t)channels);
    }

    handle->st = calloc((size_t)streams, sizeof *handle->st);

    if (handle->st == NULL)
    {
        s2a_apple_free(handle);
        *err = OPUS_ALLOC_FAIL;
        return NULL;
    }

    for (s = 0; s < streams; s++)
    {
        int32_t sc = single ? channels : (s < coupled ? 2 : 1);

        handle->st[s].channels = sc;
        handle->st[s].converter = s2a_apple_converter_new(rate, sc);

        if (handle->st[s].converter == NULL)
        {
            s2a_apple_free(handle);
            *err = OPUS_INTERNAL_ERROR;
            return NULL;
        }
    }

    if (!single)
    {
        int32_t max_samples = rate / 25 * 3;   // 120 ms

        handle->pcm = malloc((size_t)max_samples * 2 * sizeof(int16_t));

        if (handle->pcm == NULL)
        {
            s2a_apple_free(handle);
            *err = OPUS_ALLOC_FAIL;
            return NULL;
        }
    }

    *err = OPUS_OK;
    return handle;
}

// 解一个标准（非 self-delimited）Opus 包，输出 samples 帧交错 PCM；失败返回负错误码
static int32_t s2a_apple_decode_stream(s2a_apple_stream *stream, const uint8_t *data, int32_t len, int16_t *pcm, int32_t samples)
{
    s2a_apple_feed feed = {data, len, samples, stream->channels, 0};
    AudioBufferList output = {0};

    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = (UInt32)stream->channels;
    output.mBuffers[0].mDataByteSize = (UInt32)(samples * stream->channels * sizeof(int16_t));
    output.mBuffers[0].mData = pcm;

    UInt32 frames = (UInt32)samples;
    OSStatus status = AudioConverterFillComplexBuffer(stream->converter, s2a_apple_feed_cb, &feed, &frames, &output, NULL);

    if (status != noErr || frames != (UInt32)samples)
    {
        return OPUS_INTERNAL_ERROR;
    }

    return samples;
}

static int32_t s2a_apple_reserve(s2a_apple *handle, int32_t need)
{
    uint8_t *grown;

    if (need <= handle->repack_cap)
    {
        return 1;
    }

    grown = realloc(handle->repack, (size_t)need);

    if (grown == NULL)
    {
        return 0;
    }

    handle->repack = grown;
    handle->repack_cap = need;
    return 1;
}

int32_t s2a_apple_decode(void *p, const uint8_t *data, int32_t len, int16_t *pcm, int32_t frame_size)
{
    s2a_apple *handle = p;
    int16_t sizes[S2A_APPLE_MAX_FRAMES];
    const uint8_t *sub[S2A_APPLE_MAX_FRAMES];
    int32_t sub_len[S2A_APPLE_MAX_FRAMES];
    int32_t header_end[S2A_APPLE_MAX_FRAMES];
    int32_t payload_offset[S2A_APPLE_MAX_FRAMES];
    int32_t samples = -1;
    int32_t s;
    int32_t c;
    int32_t off;
    int32_t rem;

    if (handle == NULL || data == NULL || pcm == NULL || len <= 0 || frame_size <= 0)
    {
        return OPUS_BAD_ARG;
    }

    if (handle->single)
    {
        int32_t count = s2a_apple_parse_packet(data, len, 0, NULL, NULL, sizes, NULL, NULL, NULL);

        if (count < 0)
        {
            return count;
        }

        samples = s2a_apple_packet_samples(data, len, handle->rate);

        if (samples < 0)
        {
            return samples;
        }

        if (frame_size < samples)
        {
            return OPUS_BUFFER_TOO_SMALL;
        }

        return s2a_apple_decode_stream(&handle->st[0], data, len, pcm, samples);
    }

    // 多流：先按 libopus opus_multistream_packet_validate 的语义整体校验，再逐子流解码
    off = 0;
    rem = len;

    for (s = 0; s < handle->streams; s++)
    {
        int32_t pkt_off = 0;
        int32_t pay_off = 0;
        int32_t hdr_end = 0;
        int32_t tmp;

        if (rem <= 0)
        {
            return OPUS_INVALID_PACKET;
        }

        if (s2a_apple_parse_packet(data + off, rem, s != handle->streams - 1, NULL, NULL, sizes,
                                   &pay_off, &pkt_off, &hdr_end) < 0)
        {
            return OPUS_INVALID_PACKET;
        }

        tmp = s2a_apple_packet_samples(data + off, pkt_off, handle->rate);

        if (tmp < 0)
        {
            return tmp;
        }

        if (s != 0 && samples != tmp)
        {
            return OPUS_INVALID_PACKET;
        }

        samples = tmp;
        sub[s] = data + off;
        sub_len[s] = pkt_off;
        header_end[s] = hdr_end;
        payload_offset[s] = pay_off;
        off += pkt_off;
        rem -= pkt_off;
    }

    if (frame_size < samples)
    {
        return OPUS_BUFFER_TOO_SMALL;
    }

    for (s = 0; s < handle->streams; s++)
    {
        const uint8_t *src = sub[s];
        int32_t src_len = sub_len[s];
        int32_t ret;

        if (s != handle->streams - 1)
        {
            // self-delimited 子流：去掉最后的长度字段，还原标准包
            int32_t head = header_end[s];
            int32_t tail = sub_len[s] - payload_offset[s];
            int32_t need = head + tail;

            if (!s2a_apple_reserve(handle, need))
            {
                return OPUS_ALLOC_FAIL;
            }

            memcpy(handle->repack, sub[s], (size_t)head);
            memcpy(handle->repack + head, sub[s] + payload_offset[s], (size_t)tail);
            src = handle->repack;
            src_len = need;
        }

        ret = s2a_apple_decode_stream(&handle->st[s], src, src_len, handle->pcm, samples);

        if (ret < 0)
        {
            return ret;
        }

        if (s < handle->coupled)
        {
            for (c = 0; c < handle->channels; c++)
            {
                int32_t i;

                if (handle->mapping[c] == s * 2)
                {
                    for (i = 0; i < samples; i++)
                    {
                        pcm[i * handle->channels + c] = handle->pcm[i * 2];
                    }
                }
                else if (handle->mapping[c] == s * 2 + 1)
                {
                    for (i = 0; i < samples; i++)
                    {
                        pcm[i * handle->channels + c] = handle->pcm[i * 2 + 1];
                    }
                }
            }
        }
        else
        {
            for (c = 0; c < handle->channels; c++)
            {
                int32_t i;

                if (handle->mapping[c] == s + handle->coupled)
                {
                    for (i = 0; i < samples; i++)
                    {
                        pcm[i * handle->channels + c] = handle->pcm[i];
                    }
                }
            }
        }
    }

    for (c = 0; c < handle->channels; c++)
    {
        if (handle->mapping[c] == 255)
        {
            int32_t i;

            for (i = 0; i < samples; i++)
            {
                pcm[i * handle->channels + c] = 0;
            }
        }
    }

    return samples;
}

void s2a_apple_reset(void *p)
{
    s2a_apple *handle = p;
    int32_t s;

    if (handle != NULL)
    {
        for (s = 0; s < handle->streams; s++)
        {
            AudioConverterReset(handle->st[s].converter);
        }
    }
}

void s2a_apple_close(void *p)
{
    s2a_apple_free(p);
}
