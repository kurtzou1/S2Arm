// B组只读窗口查询，经真实bootstrap/swnvn/计数跳板；不提供生产宏或对象替身。
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);
static void *load(const char *name) {
    void *p = h_nvnBootstrapLoader(name);
    if (!p) { fprintf(stderr, "Missing API: %s\n", name); exit(2); }
    return p;
}
#define API(name) ((NVNT_##name)load(#name))

static const uint64_t guard = UINT64_C(0x4b7e19c2d536a8f0);
static const char *query;
static unsigned checks, bad;
static int selected(const char *name) { return !query || !strcmp(query, name); }
#define CHECK(name, condition) do { \
    if (selected(name)) { checks++; if (!(condition)) { bad++; \
        fprintf(stderr, "%s:%d %s: %s\n", __FILE__, __LINE__, name, #condition); } } \
} while (0)
#define CROP "nvnWindowGetCrop"
#define NATIVE "nvnWindowGetNativeWindow"

typedef struct { uint64_t pre; NVNwindow value; uint64_t post; } window_box;
typedef struct { uint64_t pre; NVNwindowBuilder value; uint64_t post; } builder_box;
static void crop_is(const NVNwindow *window, int x, int y, int width, int height) {
    if (!selected(CROP)) return;
    struct { uint64_t pre; NVNrectangle value; uint64_t post; } out;
    unsigned char before[sizeof *window]; memcpy(before, window, sizeof before);
    memset(&out, 0xa7, sizeof out); out.pre = out.post = guard;
    API(nvnWindowGetCrop)(window, &out.value);
    CHECK(CROP, out.value.x == x); CHECK(CROP, out.value.y == y);
    CHECK(CROP, out.value.width == width); CHECK(CROP, out.value.height == height);
    CHECK(CROP, out.pre == guard); CHECK(CROP, out.post == guard);
    CHECK(CROP, !memcmp(before, window, sizeof before));
}
static void native_is(const NVNwindow *window, NVNnativeWindow expected) {
    if (!selected(NATIVE)) return;
    unsigned char before[sizeof *window]; memcpy(before, window, sizeof before);
    CHECK(NATIVE, API(nvnWindowGetNativeWindow)(window) == expected);
    CHECK(NATIVE, !memcmp(before, window, sizeof before));
}
int main(int argc, char **argv) {
    if (argc > 2 || (argc == 2 && strcmp(argv[1], CROP) && strcmp(argv[1], NATIVE))) {
        fprintf(stderr, "usage: t_nvn_b [%s|%s]\n", CROP, NATIVE); return 2;
    }
    query = argc == 2 ? argv[1] : NULL;
    // Use production Texture APIs, with lazy CPU-only texture state: no pool upload, GPU or present.
    NVNtexture textures[4]; NVNtextureBuilder tb; memset(textures, 0, sizeof textures); memset(&tb, 0, sizeof tb);
    for (int i = 0; i < 4; i++) {
        API(nvnTextureBuilderSetDefaults)(&tb);
        API(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
        API(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
        API(nvnTextureBuilderSetSize2D)(&tb, i < 2 ? 1280 : 640, i < 2 ? 720 : 360);
        if (!API(nvnTextureInitialize)(&textures[i], &tb)) return 2;
    }
    NVNtexture *first[] = {&textures[0], &textures[1]}, *second[] = {&textures[2], &textures[3]};
    builder_box b; window_box a, other;
    memset(&b, 0xa7, sizeof b); memset(&a, 0xa7, sizeof a); memset(&other, 0xa7, sizeof other);
    b.pre = b.post = a.pre = a.post = other.pre = other.post = guard;
    NVNdevice device; memset(&device, 0, sizeof device);
    API(nvnWindowBuilderSetDevice)(&b.value, &device);
    API(nvnWindowBuilderSetDefaults)(&b.value);
    API(nvnWindowBuilderSetTextures)(&b.value, 2, first);
    if (!API(nvnWindowInitialize)(&a.value, &b.value)) return 2;
    // SDK5.5 Initialize defaults to the full first texture, not zero. Constants are hand-derived;
    // do not call TextureGetWidth/GetHeight or the implementation to generate the expected result.
    crop_is(&a.value, 0, 0, 1280, 720); native_is(&a.value, NULL);
    int native_a, native_b;
    API(nvnWindowBuilderSetNativeWindow)(&b.value, &native_a);
    API(nvnWindowBuilderSetPresentInterval)(&b.value, 2);
    // 这里不提交GPU/上屏；真实对象初始化与查询经同一份生产注册表。
    API(nvnWindowBuilderSetTextures)(&b.value, 2, first);
    if (!API(nvnWindowInitialize)(&a.value, &b.value)) return 2;
    native_is(&a.value, &native_a); crop_is(&a.value, 0, 0, 1280, 720);
    API(nvnWindowSetCrop)(&a.value, 13, 29, 641, 359);
    crop_is(&a.value, 13, 29, 641, 359); native_is(&a.value, &native_a);
    API(nvnWindowSetPresentInterval)(&a.value, 3);
    if (API(nvnWindowGetPresentInterval)(&a.value) != 3) return 2;
    crop_is(&a.value, 13, 29, 641, 359); native_is(&a.value, &native_a);
    // 第二个窗口、修改builder或重设crop都不能污染第一个窗口的查询。
    API(nvnWindowBuilderSetNativeWindow)(&b.value, &native_b);
    API(nvnWindowBuilderSetTextures)(&b.value, 2, second);
    if (!API(nvnWindowInitialize)(&other.value, &b.value)) return 2;
    crop_is(&other.value, 0, 0, 640, 360);
    API(nvnWindowSetCrop)(&other.value, 7, 11, 320, 180);
    native_is(&other.value, &native_b); crop_is(&other.value, 7, 11, 320, 180);
    native_is(&a.value, &native_a); crop_is(&a.value, 13, 29, 641, 359);
    API(nvnWindowSetCrop)(&a.value, 0, 0, 1280, 720);
    crop_is(&a.value, 0, 0, 1280, 720); crop_is(&other.value, 7, 11, 320, 180);
    // SDK SetCrop: either zero dimension resets x/y and both dimensions to the first texture.
    API(nvnWindowSetCrop)(&a.value, 91, 73, 0, 200); crop_is(&a.value, 0, 0, 1280, 720);
    API(nvnWindowSetCrop)(&a.value, 13, 29, 641, 359);
    API(nvnWindowSetCrop)(&a.value, 91, 73, 200, 0); crop_is(&a.value, 0, 0, 1280, 720);
    API(nvnWindowSetCrop)(&a.value, 13, 29, 641, 359);
    // 重置builder后重新初始化同一窗口，不能返回上一次保存的状态。
    API(nvnWindowBuilderSetDefaults)(&b.value);
    API(nvnWindowBuilderSetTextures)(&b.value, 2, second);
    if (!API(nvnWindowInitialize)(&a.value, &b.value)) return 2;
    crop_is(&a.value, 0, 0, 640, 360); native_is(&a.value, NULL);
    native_is(&other.value, &native_b); crop_is(&other.value, 7, 11, 320, 180);
    CHECK(CROP, a.pre == guard && a.post == guard && other.pre == guard && other.post == guard);
    CHECK(NATIVE, a.pre == guard && a.post == guard && other.pre == guard && other.post == guard);
    CHECK(CROP, b.pre == guard && b.post == guard);
    CHECK(NATIVE, b.pre == guard && b.post == guard);

    // 原生窗口交换间隔同步（11-13，hle_nvn.c nat_itv；帧率金手指直接写系统原生窗口 +0xF14）：对象头「dnw_」且 +0xF14 是系统缺省 1 时，
    //   建窗口写进游戏要的间隔、游戏改间隔跟着写、外部改了 GetPresentInterval 读回来；对象头不认就一处都不碰。期望手写
    {
        static uint8_t nat[0x1000], raw[0x1000];
        memcpy(nat, "dnw_", 4); memcpy(nat + 0xf14, &(int32_t){1}, 4); memcpy(raw + 0xf14, &(int32_t){1}, 4);
        window_box c, d; memset(&c, 0, sizeof c); memset(&d, 0, sizeof d);
        int32_t v;
        API(nvnWindowBuilderSetDefaults)(&b.value); API(nvnWindowBuilderSetTextures)(&b.value, 2, first);
        API(nvnWindowBuilderSetNativeWindow)(&b.value, nat); API(nvnWindowBuilderSetPresentInterval)(&b.value, 2);
        if (!API(nvnWindowInitialize)(&c.value, &b.value)) return 2;
        memcpy(&v, nat + 0xf14, 4); CHECK(NATIVE, v == 2);
        API(nvnWindowSetPresentInterval)(&c.value, 3); memcpy(&v, nat + 0xf14, 4); CHECK(NATIVE, v == 3);
        memcpy(nat + 0xf14, &(int32_t){1}, 4); CHECK(NATIVE, API(nvnWindowGetPresentInterval)(&c.value) == 1);
        API(nvnWindowBuilderSetNativeWindow)(&b.value, raw);
        if (!API(nvnWindowInitialize)(&d.value, &b.value)) return 2;
        memcpy(&v, raw + 0xf14, 4); CHECK(NATIVE, v == 1); CHECK(NATIVE, API(nvnWindowGetPresentInterval)(&d.value) == 2);
    }

    for (int i = 0; i < 4; i++) API(nvnTextureFinalize)(&textures[i]);
    printf("%s t_nvn_b %s: %u assertions, %u mismatches\n", bad ? "✗" : "✓", query ? query : "window queries", checks, bad);
    return bad != 0;
}
