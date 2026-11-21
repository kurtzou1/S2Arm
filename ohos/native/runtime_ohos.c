// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "runtime_ohos.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// 只走运行时 ABI（runtime_ohos.h → android/native/runtime/runtime.h）：S2A_DIRECT_MODE_* 与 descriptor 上限都从那里来，不直接包含 direct/ 内部头。
int s2a_ohos_runtime_run(const struct s2a_android_runtime_request *request) {
    return s2a_android_runtime_run(request);
}

// Direct opt-in: <state>/graphics_mode holds "direct" or "auto" (one word) and the program
// directory carries graphics.v1.json from the direct pipeline. Without the mode file the
// session takes the unchanged v1 (generic) path; a bad or missing descriptor under an explicit
// direct request fails before relocation instead of silently running generic.
static char *read_small(const char *dir, const char *name, size_t limit, size_t *bytes) {
    char path[1200];
    if (!dir || snprintf(path, sizeof path, "%s/%s", dir, name) >= (int)sizeof path) return NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *data = malloc(limit + 1);
    size_t n = data ? fread(data, 1, limit + 1, f) : 0;
    fclose(f);
    if (!data || n == 0 || n > limit) { free(data); return NULL; }
    data[n] = 0;
    if (bytes) *bytes = n;
    return data;
}

int s2a_ohos_graphics_mode(const char *state_dir) {
    char *text = read_small(state_dir, "graphics_mode", 32, NULL);
    if (!text) return -1;
    text[strcspn(text, " \t\r\n")] = 0;
    int mode = !strcmp(text, "direct") ? S2A_DIRECT_MODE_DIRECT : !strcmp(text, "auto") ? S2A_DIRECT_MODE_AUTO
             : !strcmp(text, "generic") ? S2A_DIRECT_MODE_GENERIC : -2;
    free(text);
    return mode;
}

int s2a_ohos_runtime_run_selected(const struct s2a_android_runtime_request *request) {
    int mode = s2a_ohos_graphics_mode(request->services.state_dir);
    if (mode == -1) return s2a_android_runtime_run(request);
    if (mode < 0) {
        fprintf(stderr, "[s2a] graphics_mode file is not direct/auto/generic; refusing to guess\n");
        return S2A_RUNTIME_ARGUMENT;
    }
    static struct s2a_android_runtime_request_v2 v2;
    static char *descriptor;
    size_t bytes = 0;
    descriptor = read_small(request->module_dir, "graphics.v1.json", S2A_ANDROID_GRAPHICS_DESCRIPTOR_MAX_BYTES, &bytes);
    memset(&v2, 0, sizeof v2);
    v2.size = sizeof v2;
    v2.version = S2A_ANDROID_RUNTIME_ABI_V2;
    v2.mode_preference = (uint32_t)mode;
    v2.services.base = request->services;
    v2.services.base.size = S2A_ANDROID_SERVICES_REQUEST_V2_SIZE;
    v2.services.base.version = S2A_ANDROID_SERVICES_ABI_V2;
    v2.module_dir = request->module_dir;
    v2.module_names = request->module_names;
    v2.module_count = request->module_count;
    v2.program_id = request->program_id;
    v2.module_source = request->module_source;
    v2.npdm_path = request->npdm_path;
    v2.graphics.json = (const uint8_t *)descriptor;
    v2.graphics.bytes = bytes;
    fprintf(stderr, "[s2a] graphics mode request: %s, descriptor %s (%zu B)\n",
        mode == S2A_DIRECT_MODE_DIRECT ? "direct" : mode == S2A_DIRECT_MODE_AUTO ? "auto" : "generic",
        descriptor ? "present" : "absent", bytes);
    return s2a_android_runtime_run_v2(&v2);
}
int s2a_ohos_runtime_status(uint64_t session_id, struct s2a_android_runtime_status *status) {
    return s2a_android_runtime_status(session_id, status);
}
int s2a_ohos_runtime_request_stop(uint64_t session_id) {
    return s2a_android_runtime_request_stop(session_id);
}
