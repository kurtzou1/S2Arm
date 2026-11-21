// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Opt-in signed-app query; no decoder, media submission, or rendering changes.
#include <dlfcn.h>
#include <multimedia/player_framework/native_avcapability.h>
static void *codec_caps_probe_thread(void *arg) {
    (void)arg;
    void *lib = dlopen("libnative_media_codecbase.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "[OHOS codec facts] unavailable: %s\n", dlerror()); return NULL; }
    OH_AVCapability *(*get)(const char *, bool, OH_AVCodecCategory) = dlsym(lib, "OH_AVCodec_GetCapabilityByCategory");
    const char *(*name)(OH_AVCapability *) = dlsym(lib, "OH_AVCapability_GetName");
    bool (*hardware)(OH_AVCapability *) = dlsym(lib, "OH_AVCapability_IsHardware");
    OH_AVErrCode (*rates)(OH_AVCapability *, int32_t, int32_t, OH_AVRange *) = dlsym(lib, "OH_AVCapability_GetVideoFrameRateRangeForSize");
    if (!get || !name || !hardware || !rates) {
        fprintf(stderr, "[OHOS codec facts] unavailable: required capability API missing\n");
        dlclose(lib); return NULL;
    }
    // Use the platform's own AV1 MIME; do not infer it from another OS.
    const char **av1_mime = dlsym(lib, "OH_AVCODEC_MIMETYPE_VIDEO_AV1");
    const char *mime[] = {av1_mime && *av1_mime ? *av1_mime : "video/av01", "video/avc", "video/hevc"};
    fprintf(stderr, "[OHOS codec facts] AV1 MIME source=%s value=%s\n",
        av1_mime && *av1_mime ? "platform_symbol" : "fallback_unverified", mime[0]);
    for (unsigned i = 0; i < sizeof mime / sizeof *mime; ++i) {
        for (int category = HARDWARE; category <= SOFTWARE; ++category) {
            OH_AVCapability *cap = get(mime[i], false, (OH_AVCodecCategory)category);
            if (!cap) { fprintf(stderr, "[OHOS codec facts] mime=%s category=%d capability=NULL\n", mime[i], category); continue; }
            OH_AVRange range = {0};
            int rc = rates(cap, 1920, 1080, &range);
            const char *codec_name = name(cap);
            fprintf(stderr, "[OHOS codec facts] mime=%s category=%d name=%s hardware=%d 1080pRateRc=%d range=%d..%d\n",
                mime[i], category, codec_name ? codec_name : "(null)", hardware(cap), rc, range.minVal, range.maxVal);
        }
    }
    fprintf(stderr, "[OHOS codec facts] complete; scope=capability_only; no_decoder_created\n");
    dlclose(lib);
    return NULL;
}
