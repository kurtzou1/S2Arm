#!/usr/bin/env python3
"""Host contract for production 3D buffer/image copy bounds; Vulkan calls are recorded only."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'android/native/nvn/backend_vulkan.c').read_text()
def function(signature):
    start = src.index(signature)
    brace = src.index('{', start)
    depth, pos = 1, brace + 1
    while depth:
        depth += (src[pos] == '{') - (src[pos] == '}')
        pos += 1
    return src[start:pos]

preamble = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#define NVN_TEXTURE_TARGET_3D 3
#define NVN_GPU_OK 0
#define NVN_GPU_E_ARG 1
#define NVN_GPU_E_ORDER 2
#define NVN_GPU_E_UNSUPPORTED 3
#define VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL 1
#define VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 2
#define VK_IMAGE_LAYOUT_GENERAL 3
#define REF_TEX 1
#define REF_BUF 2
typedef struct { int xoffset,yoffset,zoffset,width,height,depth; } NVNcopyRegion;
typedef struct { int32_t x,y,z; } VkOffset3D;
typedef struct { uint32_t width,height,depth; } VkExtent3D;
typedef struct { uint32_t aspectMask,mipLevel,baseArrayLayer,layerCount; } VkImageSubresourceLayers;
typedef struct { uint64_t bufferOffset; uint32_t bufferRowLength,bufferImageHeight; VkImageSubresourceLayers imageSubresource; VkOffset3D imageOffset; VkExtent3D imageExtent; } VkBufferImageCopy;
typedef struct { uint8_t channels, bytes, bw, bh, kind, srgb, depth, stencil; uint8_t expand; } nvn_fmt_info;   /* 同 graphics/nvn/gfx/nvn/nvn_fmt_info.h */
struct nvn_gpu_tex_s { uint32_t w,h,depth,levels,target,layers,format,nvn_format,aspect; int image; int bc_decoded; };   /* bc_decoded：压缩贴图现解；本测试的贴图都不是 */
struct nvn_gpu_buf_s { int buffer; uint64_t size; };
struct nvn_gpu_cmd_s { int sticky,in_pass,cb; };
typedef struct nvn_gpu_tex_s *nvn_gpu_tex;
typedef struct nvn_gpu_buf_s *nvn_gpu_buf;
typedef struct nvn_gpu_cmd_s *nvn_gpu_cmd;
static int copies; static VkBufferImageCopy last;
#define VK_IMAGE_ASPECT_DEPTH_BIT 2
static int nvn_vk_format_substituted(uint32_t f) { (void)f; return 0; }   /* #398 D24 换 D32：本测试的贴图都不换存储 */
static int rc_is(int got, int expected) { return got == expected; }
static void set_sticky(struct nvn_gpu_cmd_s *c, int rc, const char *why, ...) { (void)why; c->sticky = rc; }
static uint32_t fmt_bpp(uint32_t fmt) { (void)fmt; return 4; }
static int nvn_fmt_info_of(uint32_t fmt, nvn_fmt_info *out) { (void)fmt; (void)out; return 0; }
static int nvn_fmt_expand_target(uint32_t f, uint32_t *target, int *bpp) { (void)f; (void)target; (void)bpp; return 0; }
static int buf_range(struct nvn_gpu_buf_s *b, uint64_t off, uint64_t n) { return off <= b->size && n <= b->size-off; }
static void full_barrier(struct nvn_gpu_cmd_s *c) { (void)c; }
static void image_barrier(struct nvn_gpu_cmd_s *c, struct nvn_gpu_tex_s *t, int l) { (void)c; (void)t; (void)l; }
static void cmd_ref(struct nvn_gpu_cmd_s *c, void *p, int type) { (void)c; (void)p; (void)type; }
static void vkCmdCopyBufferToImage(int cb, int b, int i, int layout, uint32_t n, const VkBufferImageCopy *r) { (void)cb; (void)b; (void)i; (void)layout; (void)n; copies++; last=*r; }
static void vkCmdCopyImageToBuffer(int cb, int i, int layout, int b, uint32_t n, const VkBufferImageCopy *r) { (void)cb; (void)i; (void)layout; (void)b; (void)n; copies++; last=*r; }
'''
production = '\n'.join(function(x) for x in (
    'static int copy_region(', 'static int check_copy_params(',
    'static void copy_buf_tex_impl(', 'void nvn_gpu_copy_buf_tex(', 'void nvn_gpu_copy_tex_buf('))   # copy_buf_tex_impl：#422 起 nvn_gpu_copy_buf_tex 是它的薄壳
main = r'''
static int check_case(int direction, unsigned layer, const NVNcopyRegion *region, int expected, const char *name) {
    struct nvn_gpu_tex_s t = {.w=4,.h=4,.depth=4,.levels=3,.target=NVN_TEXTURE_TARGET_3D,.layers=1};
    struct nvn_gpu_buf_s b = {.size=128}; struct nvn_gpu_cmd_s c = {0};
    copies = 0; memset(&last, 0, sizeof last);
    if (direction == 0) nvn_gpu_copy_buf_tex(&c, &b, 0, 8, 32, &t, 1, layer, region);
    else nvn_gpu_copy_tex_buf(&c, &t, 1, layer, region, &b, 0, 8, 32);
    if (expected) {
        if (c.sticky != NVN_GPU_OK || copies != 1 || last.imageOffset.z != (int)layer ||
            last.imageExtent.width != 2 || last.imageExtent.height != 2 ||
            last.imageExtent.depth != (uint32_t)(region && region->depth > 0 ? region->depth : 1)) {
            fprintf(stderr, "%s direction=%d: expected valid copy, sticky=%d calls=%d\n", name, direction, c.sticky, copies); return 1;
        }
    } else if (c.sticky != NVN_GPU_E_ARG || copies != 0) {
        fprintf(stderr, "%s direction=%d: expected E_ARG and no Vulkan copy, sticky=%d calls=%d\n", name, direction, c.sticky, copies); return 1;
    }
    return 0;
}
int main(void) {
    NVNcopyRegion two_slices = {.depth=2}; int errors = 0;
    for (int dir=0; dir<2; dir++) {
        errors += check_case(dir, 1, NULL, 1, "last mip slice");
        errors += check_case(dir, 2, NULL, 0, "slice beyond mip");
        errors += check_case(dir, 0, &two_slices, 1, "two slices end at mip limit");
        errors += check_case(dir, 1, &two_slices, 0, "depth crosses mip limit");
    }
    if (errors) return 1;
    puts("3D copy mip depth bounds: both directions and valid controls passed"); return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='copy-3d-depth-') as path:
    d = Path(path)
    (d / 'test.c').write_text(preamble + production + main)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', str(d / 'test.c'), '-o', str(d / 'test')], check=True)
    subprocess.run([str(d / 'test')], check=True)
