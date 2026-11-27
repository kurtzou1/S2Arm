// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 建贴图视图的唯一出口 mtl_view / mtl_view_sw（nvn_mtl.m）：层 / 级别范围伸出源贴图时不建（回 nil）、不让 Metal 校验 abort 整进程。直接包含生产 nvn_mtl.m。
// 期望按构造写死（源贴图形状自己建的，不跑实现也算得出）：
//   源 A：2D 数组 64x64、3 级、2 层；源 C：立方体 32x32、1 级（6 面）
//   ① A 层 1+1、级 0+3 → 建得出（1 + 1 = 2 <= 2）       ② A 层 1+2 → nil（1 + 2 = 3 > 2，同 D-K6Y5「(3) must be <= (2)」）
//   ③ A 层 2+1 → nil（2 + 1 = 3 > 2）                    ④ A 级 1+3 → nil（1 + 3 = 4 > 3）
//   ⑤ C 当 2D 取面 5（5 + 1 = 6 <= 6）→ 建得出           ⑥ C 取面 6 → nil（6 + 1 = 7 > 6）
//   ⑦ 带通道重排的同一组：A 层 0+2 建得出、层 1+2 → nil
//   ⑧ 越界只打红字、不 abort：本程序跑完 = 反证（不经出口直接 newTextureView 同一越界范围，在 Metal 校验下整进程 abort，见文件尾 S2A_VIEW_RANGE_RAW）
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
    d.textureType = MTLTextureType2DArray; d.arrayLength = 2; d.mipmapLevelCount = 3; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> a = [g_dev newTextureWithDescriptor:d];
    MTLTextureDescriptor *dc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:32 mipmapped:NO];
    dc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; dc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> c = [g_dev newTextureWithDescriptor:dc];
    if (!a || !c) { printf("FAIL setup: 建不了源贴图\n"); return 1; }
    if (getenv("S2A_VIEW_RANGE_RAW")) {   // 反证：不经出口直接建越界视图（Metal 校验下 abort，进程退出码非 0）
        id<MTLTexture> v = [a newTextureViewWithPixelFormat:a.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0, 1) slices:NSMakeRange(1, 2)];
        printf("RAW 越界视图建出来了：%s\n", v ? "是" : "否"); return 0;
    }
    VERIFY(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 3), NSMakeRange(1, 1)) != nil, "① 2D 数组 层 1+1、级 0+3：建得出");
    VERIFY(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(1, 2)) == nil, "② 层 1+2（3 > 2）：nil");
    VERIFY(mtl_view(a, a.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(2, 1)) == nil, "③ 层 2+1（3 > 2）：nil");
    VERIFY(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(1, 3), NSMakeRange(0, 1)) == nil, "④ 级 1+3（4 > 3）：nil");
    VERIFY(mtl_view(c, c.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(5, 1)) != nil, "⑤ 立方体取面 5（6 <= 6）：建得出");
    VERIFY(mtl_view(c, c.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(6, 1)) == nil, "⑥ 立方体取面 6（7 > 6）：nil");
    MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne);
    VERIFY(mtl_view_sw(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(0, 2), sw) != nil, "⑦a 重排 层 0+2：建得出");
    VERIFY(mtl_view_sw(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(1, 2), sw) == nil, "⑦b 重排 层 1+2：nil");
    VERIFY(1, "⑧ 越界都没让进程 abort（走到这里）");
    printf("%s t_nvn_view_range：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures); return failures ? 1 : 0;
} }
