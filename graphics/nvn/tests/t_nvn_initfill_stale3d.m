// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 贴图初始内容含过期旧字节（nvn_mtl.m tex_init_fill）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。
// 背景：FF Resonance（0100B8A026F14000）64 MB 3D R8 贴图有 13,008 段旧 GPU 写区间，旧实现释放 CPU 掩码副本后改走
//   tex_bytes_gobs + gpw_zero_rect 逐段发 3D 整深度 blit（卡死 GPU 12.9 秒），且把未被覆盖的其它 Z 层整柱清零。
// 期望（按 Switch 块线性 GOB 语义手写，不由被测实现推出）：
//   ① 3D 64×16×16 R8 贴图仅首 GOB [0, 512) 有旧 GPU 写：z=0 前 8 行（512 纹素）清 0，z=1..15 全部 15,360 纹素保持 CPU 初值 0x55
//   ② 3D 64×16×16 R8 贴图含 8 段不连续旧 GOB（共 4,096 字节）：精确清零 4,096 纹素，其余 12,288 纹素保持 0x55
//   ③ 2D 64×256 R8 贴图含 16 段交替旧 GOB（偶数 8 行带）：偶数带 8,192 纹素清 0，奇数带 8,192 纹素保持 0x33
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static size_t texture_offset = 2 << 20;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 1 << 20 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL [%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
    REQUIRE(API(nvnQueueInitialize)(&queue, &qb)); REQUIRE(posix_memalign(&storage, 65536, POOL_SIZE) == 0); memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static size_t alloc_aligned(size_t bytes) {
    size_t al = 65536;
    texture_offset = (texture_offset + al - 1) / al * al;
    size_t off = texture_offset;
    REQUIRE(off + bytes <= POOL_SIZE);
    texture_offset = off + ((bytes + al - 1) / al * al);
    return off;
}
// 在存储 [off, off + 512) 上建一张 64×8 R8 贴图并 GPU 清屏，使该 512 字节 GOB 在 gpw 账本中记为旧字节
static void mark_gob_stale(const size_t *offs, int n) {
    NVNtexture ts[32]; REQUIRE(n > 0 && n <= 32);
    static const float clr[4] = {170.0f / 255.0f, 0.0f, 0.0f, 1.0f};
    NVNcopyRegion reg = {0, 0, 0, 64, 8, 1};
    begin();
    for (int i = 0; i < n; i++) {
        NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
        API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, 64, 8);
        API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R8);
        API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
        REQUIRE(API(nvnTextureBuilderGetStorageSize)(&b) == 512);
        API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)offs[i]);
        REQUIRE(API(nvnTextureInitialize)(&ts[i], &b));
        API(nvnCommandBufferClearTexture)(&commands, &ts[i], NULL, &reg, clr, 15);
    }
    submit();
    for (int i = 0; i < n; i++) API(nvnTextureFinalize)(&ts[i]);
}
static void test_3d_single_stale_gob(void) {
    phase = "① 3D 64×16×16 R8 仅首 GOB 旧字节：只清 z=0 前 8 行，z=1..15 保持 0x55";
    enum { W = 64, H = 16, D = 16 };
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_3D); API(nvnTextureBuilderSetSize3D)(&b, W, H, D);
    API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R8);
    API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    size_t bytes = API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(bytes == W * H * D);
    size_t off = alloc_aligned(bytes);
    memset((uint8_t *)storage + off, 0x55, bytes);
    mark_gob_stale(&off, 1);

    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    memset((uint8_t *)storage + READ_OFFSET, 0xA5, W * H * D);
    NVNcopyRegion whole = {0, 0, 0, W, H, D};
    NVNbufferAddress dst = API(nvnMemoryPoolGetBufferAddress)(&pool) + READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands, &t, NULL, &whole, dst, 0); submit();

    const uint8_t *p = (const uint8_t *)storage + READ_OFFSET;
    int bad_z0_stale = 0, bad_other_z = 0;
    for (int y = 0; y < 8; y++) for (int x = 0; x < W; x++) bad_z0_stale += p[y * W + x] != 0x00;
    for (int z = 1; z < D; z++) for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) bad_other_z += p[(z * H + y) * W + x] != 0x55;
    checks += 2;
    if (bad_z0_stale) { fails++; printf("FAIL %s：z=0 前 8 行 %d/512 纹素未清零（首纹素 0x%02x）\n", phase, bad_z0_stale, p[0]); }
    if (bad_other_z) { fails++; printf("FAIL %s：z=1..15 共 %d/15360 纹素被误改（z=1 首纹素 0x%02x，期望 0x55）\n", phase, bad_other_z, p[W * H]); }
    API(nvnTextureFinalize)(&t); cases++;
}
static void test_3d_fragmented_stale_gobs(void) {
    phase = "② 3D 64×16×16 R8 含 8 段不连续旧 GOB：精确清零 4,096 纹素、保留 12,288 纹素";
    enum { W = 64, H = 16, D = 16 };
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_3D); API(nvnTextureBuilderSetSize3D)(&b, W, H, D);
    API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R8);
    API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    size_t bytes = API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(bytes == W * H * D);
    size_t off = alloc_aligned(bytes);
    memset((uint8_t *)storage + off, 0x55, bytes);
    size_t gobs[8]; for (int i = 0; i < 8; i++) gobs[i] = off + (size_t)i * 2048;
    mark_gob_stale(gobs, 8);

    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    memset((uint8_t *)storage + READ_OFFSET, 0xA5, W * H * D);
    NVNcopyRegion whole = {0, 0, 0, W, H, D};
    NVNbufferAddress dst = API(nvnMemoryPoolGetBufferAddress)(&pool) + READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands, &t, NULL, &whole, dst, 0); submit();

    const uint8_t *p = (const uint8_t *)storage + READ_OFFSET;
    int zeros = 0, kept = 0, other = 0;
    for (int i = 0; i < W * H * D; i++) { if (p[i] == 0x00) zeros++; else if (p[i] == 0x55) kept++; else other++; }
    checks++;
    if (zeros != 4096 || kept != 12288 || other != 0) {
        fails++; printf("FAIL %s：清零 %d（期望 4096）、保留 %d（期望 12288）、杂值 %d（期望 0）\n", phase, zeros, kept, other);
    }
    API(nvnTextureFinalize)(&t); cases++;
}
static void test_2d_fragmented_stale_gobs(void) {
    phase = "③ 2D 64×256 R8 含 16 段交替旧 GOB：偶数 8 行带清 0、奇数带保持 0x33";
    enum { W = 64, H = 256 };
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, W, H);
    API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R8);
    API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    size_t bytes = API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(bytes == W * H);
    size_t off = alloc_aligned(bytes);
    memset((uint8_t *)storage + off, 0x33, bytes);
    size_t gobs[16]; for (int i = 0; i < 16; i++) gobs[i] = off + (size_t)i * 1024;
    mark_gob_stale(gobs, 16);

    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    memset((uint8_t *)storage + READ_OFFSET, 0xA5, W * H);
    NVNcopyRegion whole = {0, 0, 0, W, H, 1};
    NVNbufferAddress dst = API(nvnMemoryPoolGetBufferAddress)(&pool) + READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands, &t, NULL, &whole, dst, 0); submit();

    const uint8_t *p = (const uint8_t *)storage + READ_OFFSET;
    int bad_even = 0, bad_odd = 0;
    for (int y = 0; y < H; y++) {
        uint8_t want = ((y / 8) & 1) ? 0x33 : 0x00;
        for (int x = 0; x < W; x++) if (p[y * W + x] != want) { if (want) bad_odd++; else bad_even++; }
    }
    checks += 2;
    if (bad_even) { fails++; printf("FAIL %s：偶数旧带 %d/8192 纹素未清零\n", phase, bad_even); }
    if (bad_odd) { fails++; printf("FAIL %s：奇数有效带 %d/8192 纹素被误改\n", phase, bad_odd); }
    API(nvnTextureFinalize)(&t); cases++;
}
int main(void) { @autoreleasepool {
    setup();
    test_3d_single_stale_gob();
    test_3d_fragmented_stale_gobs();
    test_2d_fragmented_stale_gobs();
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue); API(nvnMemoryPoolFinalize)(&pool); API(nvnDeviceFinalize)(&device); free(storage);
    if (fails) { printf("✗ t_nvn_initfill_stale3d：%u 项检查里 %u 项不符\n", checks, fails); return 1; }
    printf("✓ t_nvn_initfill_stale3d：%u 例 %u 项检查全过（3D / 2D 碎片旧字节精确按 GOB 清零、不误清其余 Z 层）\n", cases, checks);
    return 0;
}}
