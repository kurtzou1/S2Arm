// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS buffer-mode H.264 decoder for the NVDEC picture-in/picture-out contract.
// No surface, no display reordering, no FFmpeg/private codec ABI dependency.
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    OH_AVCodec *codec;
    int width, height, hardware;
    int64_t serial;
} s2a_h264;

static int fail(const char *step, int rc) {
    fprintf(stderr, "[OHOS video] H264 failed step=%s rc=%d\n", step, rc);
    return rc ? -abs(rc) : -1;
}

void s2a_ohos_h264_close(s2a_h264 *h) {
    if (!h) return;
    if (h->codec) OH_VideoDecoder_Destroy(h->codec);
    free(h);
}

s2a_h264 *s2a_ohos_h264_open(int width, int height, int *hardware) {
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || (width | height) & 1) return NULL;
    for (int category = HARDWARE; category <= SOFTWARE; ++category) {
        OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory("video/avc", false, category);
        if (!cap) continue;
        bool ordered = OH_AVCapability_IsFeatureSupported(cap, VIDEO_DECODER_OUTPUT_IN_DECODING_ORDER);
        bool low = OH_AVCapability_IsFeatureSupported(cap, VIDEO_LOW_LATENCY);
        if (!ordered && !low) continue; // Can't return a different decoded picture as this picture.
        const char *name = OH_AVCapability_GetName(cap);
        OH_AVCodec *codec = OH_VideoDecoder_CreateByName(name);
        if (!codec) continue;
        OH_AVFormat *format = OH_AVFormat_Create();
        if (!format) { OH_VideoDecoder_Destroy(codec); return NULL; }
        bool ok = OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width) &&
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height) &&
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12) &&
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1) &&
            OH_AVFormat_SetIntValue(format, ordered ? OH_MD_KEY_VIDEO_DECODER_OUTPUT_IN_DECODING_ORDER : OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
        int rc = ok ? OH_VideoDecoder_Configure(codec, format) : -1;
        OH_AVFormat_Destroy(format);
        if (rc == AV_ERR_OK) rc = OH_VideoDecoder_Prepare(codec);
        if (rc == AV_ERR_OK) rc = OH_VideoDecoder_Start(codec);
        if (rc != AV_ERR_OK) { fail("configure/prepare/start", rc); OH_VideoDecoder_Destroy(codec); continue; }
        s2a_h264 *h = calloc(1, sizeof(*h));
        if (!h) { OH_VideoDecoder_Destroy(codec); return NULL; }
        h->codec = codec; h->width = width; h->height = height; h->hardware = category == HARDWARE;
        *hardware = h->hardware;
        fprintf(stderr,"[OHOS video] H264 decoder=%s hardware=%d ordered=%d lowLatency=%d size=%dx%d\n",name,h->hardware,ordered,low,width,height);
        return h;
    }
    fail("no_decode_order_capability", -1);
    return NULL;
}

// Copies the actual padded decoder output to tightly packed Y/U/V owned by the caller.
// Return false on unsupported or inconsistent layouts; never produce a success blank frame.
static int copy_output(s2a_h264 *h, OH_AVBuffer *buffer, uint8_t *dst, int capacity) {
    OH_AVCodecBufferAttr a;
    if (OH_AVBuffer_GetBufferAttr(buffer, &a) != AV_ERR_OK) return fail("output_attr", -1);
    if (a.pts != h->serial || a.offset < 0 || a.size <= 0) return fail("output_identity", -1);
    OH_AVFormat *f = OH_VideoDecoder_GetOutputDescription(h->codec);
    if (!f) return fail("output_description", -1);
    int width=0,height=0,stride=0,slice=0,pixel=0;
    // WIDTH/HEIGHT are allocation hints. PIC_WIDTH/PIC_HEIGHT describe decoded output.
    // Read independently so a missing key cannot hide other geometry in diagnostics.
    unsigned keys=0;
    if (OH_AVFormat_GetIntValue(f, OH_MD_KEY_VIDEO_PIC_WIDTH, &width)) keys|=1;
    if (OH_AVFormat_GetIntValue(f, OH_MD_KEY_VIDEO_PIC_HEIGHT, &height)) keys|=2;
    if (OH_AVFormat_GetIntValue(f, OH_MD_KEY_VIDEO_STRIDE, &stride)) keys|=4;
    if (OH_AVFormat_GetIntValue(f, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &slice)) keys|=8;
    if (OH_AVFormat_GetIntValue(f, OH_MD_KEY_PIXEL_FORMAT, &pixel)) keys|=16;
    OH_AVFormat_Destroy(f);
    int w=h->width, ht=h->height;
    if (h->serial==1) fprintf(stderr,"[OHOS video] H264 output keys=%u pic=%dx%d expected=%dx%d stride=%d slice=%d pixel=%d offset=%d size=%d capacity=%d\n",
        keys,width,height,w,ht,stride,slice,pixel,a.offset,a.size,OH_AVBuffer_GetCapacity(buffer));
    if (keys!=31 || width!=w || height!=ht || stride<w || slice<ht || stride>32768 || slice>32768 || (stride|slice)&1)
        return fail("output_geometry", -1);
    if (pixel!=AV_PIXEL_FORMAT_NV12 && pixel!=AV_PIXEL_FORMAT_NV21 && pixel!=AV_PIXEL_FORMAT_YUVI420)
        return fail("output_pixel_format", pixel);
    int64_t plane=(int64_t)stride*slice, need=plane+plane/2;
    int srcCapacity=OH_AVBuffer_GetCapacity(buffer);
    uint8_t *src=OH_AVBuffer_GetAddr(buffer);
    if (!src || need>srcCapacity-a.offset || need>a.size || (int64_t)w*ht*3/2>capacity)
        return fail("output_bounds", -1);
    src+=a.offset;
    for (int y=0;y<ht;y++) memcpy(dst+(size_t)y*w,src+(size_t)y*stride,w);
    uint8_t *u=dst+(size_t)w*ht, *v=u+(size_t)w*ht/4;
    if (pixel==AV_PIXEL_FORMAT_YUVI420) {
        for(int y=0;y<ht/2;y++) {
            memcpy(u+(size_t)y*w/2,src+plane+(size_t)y*stride/2,w/2);
            memcpy(v+(size_t)y*w/2,src+plane+plane/4+(size_t)y*stride/2,w/2);
        }
    } else {
        int swap=pixel==AV_PIXEL_FORMAT_NV21;
        for(int y=0;y<ht/2;y++) for(int x=0;x<w/2;x++) {
            u[(size_t)y*w/2+x]=src[plane+(size_t)y*stride+2*x+swap];
            v[(size_t)y*w/2+x]=src[plane+(size_t)y*stride+2*x+1-swap];
        }
    }
    if(h->serial==1) fprintf(stderr,"[OHOS video] H264 first frame=%dx%d stride=%d slice=%d pixel=%d bytes=%d\n",w,ht,stride,slice,pixel,a.size);
    return 0;
}

int s2a_ohos_h264_decode(s2a_h264 *h, const uint8_t *data, int length, uint8_t *i420, int capacity) {
    if(!h || !data || length<=0 || !i420) return fail("arguments", -1);
    uint32_t index=0;
    int rc=OH_VideoDecoder_QueryInputBuffer(h->codec,&index,2000000);
    if(rc!=AV_ERR_OK) return fail("input_wait",rc);
    OH_AVBuffer *input=OH_VideoDecoder_GetInputBuffer(h->codec,index);
    if(!input || length>OH_AVBuffer_GetCapacity(input) || !OH_AVBuffer_GetAddr(input)) return fail("input_capacity",-1);
    memcpy(OH_AVBuffer_GetAddr(input),data,length);
    OH_AVCodecBufferAttr attr={0}; attr.pts=++h->serial;attr.size=length;
    rc=OH_AVBuffer_SetBufferAttr(input,&attr);
    if(rc==AV_ERR_OK) rc=OH_VideoDecoder_PushInputBuffer(h->codec,index);
    if(rc!=AV_ERR_OK) return fail("input_submit",rc);
    // A stream-change notification consumes no picture; it is explicitly bounded.
    for(int n=0;n<4;n++) {
        rc=OH_VideoDecoder_QueryOutputBuffer(h->codec,&index,2000000);
        if(rc==AV_ERR_STREAM_CHANGED) continue;
        if(rc!=AV_ERR_OK) return fail("output_wait",rc);
        OH_AVBuffer *output=OH_VideoDecoder_GetOutputBuffer(h->codec,index);
        int result=output ? copy_output(h,output,i420,capacity) : fail("output_buffer",-1);
        rc=OH_VideoDecoder_FreeOutputBuffer(h->codec,index);
        return result ? result : (rc==AV_ERR_OK ? 0 : fail("output_free",rc));
    }
    return fail("stream_change_limit",-1);
}
