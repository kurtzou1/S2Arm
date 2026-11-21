// 整台设备能力形态档下的建设备核对（宿主；假驱动 fake_vk.c 按 S2A_CAPS_SHAPE 回答，run.sh 对三档各跑一遍）。
//   被测是生产代码原样：android/native/direct/vk_device.c（能力 → 启用）、device_caps.c（启用 → s2a-device-caps-v1）、
//   nvn_vk_format.c（深度替换选择）、gs_path.c（几何着色器路径：能力闸先于 capprobe 判定）、
//   backend_vulkan.c 的 array_query_default（run.sh 原样摘出来编进本文件）。
//   期望值只从形态档数据按规则算（扩展列没列、特性位、格式特性位），不调被测函数求期望。
// 用法：S2A_CAPS_SHAPE=<adreno|mali|conservative> vk_device_shape_test <caps JSON 输出路径>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "caps_shape.h"
#include "vk_device.h"
#include "device_caps.h"

// backend_vulkan.c 的 array_query_default 读 g.dev：摘出来的原文接在这个 g 上
static struct { struct s2a_vk_device *dev; } g;
#include "array_query_default.inc"
// capprobe 判定固定为「支持」（收益闸放行）：几何着色器开不开只剩能力闸——设备不支持就必须关
const char *s2a_capprobe_gs_occ_state(void) { return "caps-shape-test:supported"; }

static int fails;
#define EXPECT(cond, ...) do { if (!(cond)) { fails++; printf("FAIL: [%s] ", cs_shape()->name); printf(__VA_ARGS__); printf("\n"); } } while (0)

static int popcount16(uint32_t m) { int n = 0; for (int i = 0; i < 16; i++) n += (m >> i) & 1; return n; }

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "用法：S2A_CAPS_SHAPE=<档> %s <caps JSON 输出>\n", argv[0]); return 2; }
    const struct cs_shape *s = cs_shape();
    struct s2a_vk_device d;
    char why[256] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) {
        printf("FAIL: [%s] 建设备失败：%s%s%s\n", s->name, why, cs_create_device_why[0] ? "；假驱动：" : "", cs_create_device_why);
        return 1;
    }

    // 格式列表（C2，保 Adreno UBWC 那条）：设备列出 VK_KHR_image_format_list 才走列表模式，没列出走自由 MUTABLE
    const int fmt_list = cs_has_ext(s, "VK_KHR_image_format_list");
    EXPECT(d.image_format_list_enabled == fmt_list, "image_format_list_enabled=%d，形态档列出扩展=%d", d.image_format_list_enabled, fmt_list);
    // 自定义边框色（C3）：扩展 + customBorderColors 特性都有才开；没开时后端就近取内置档
    const int border = cs_has_ext(s, "VK_EXT_custom_border_color") && s->customBorderColors;
    EXPECT(d.custom_border_enabled == border, "custom_border_enabled=%d，期望 %d", d.custom_border_enabled, border);
    // 描述符索引：扩展列出、1.1 设备、四位支持位齐全才整组启用
    const int di = cs_has_ext(s, "VK_EXT_descriptor_indexing") && s->props.apiVersion >= VK_API_VERSION_1_1 &&
                   s->diRuntimeArray && s->diPartiallyBound && s->diSampledNonUniform && s->diStorageNonUniform;
    EXPECT(d.descriptor_indexing_enabled == di, "descriptor_indexing_enabled=%d，期望 %d", d.descriptor_indexing_enabled, di);
    // BC 路由（C6）：逐格式查原生采样位，缺的走计算解码；两者互补
    static const VkFormat bc[] = { VK_FORMAT_BC1_RGBA_UNORM_BLOCK, VK_FORMAT_BC1_RGBA_SRGB_BLOCK, VK_FORMAT_BC2_UNORM_BLOCK, VK_FORMAT_BC2_SRGB_BLOCK,
                                   VK_FORMAT_BC3_UNORM_BLOCK, VK_FORMAT_BC3_SRGB_BLOCK, VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_BC4_SNORM_BLOCK,
                                   VK_FORMAT_BC5_UNORM_BLOCK, VK_FORMAT_BC5_SNORM_BLOCK, VK_FORMAT_BC6H_UFLOAT_BLOCK, VK_FORMAT_BC6H_SFLOAT_BLOCK,
                                   VK_FORMAT_BC7_UNORM_BLOCK, VK_FORMAT_BC7_SRGB_BLOCK };
    int bc_sampled = 0;
    for (size_t i = 0; i < sizeof bc / sizeof *bc; i++) bc_sampled += !!(cs_format(s, bc[i]).optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT);
    const int bc_all = bc_sampled == (int)(sizeof bc / sizeof *bc), bc_none = bc_sampled == 0;
    EXPECT(bc_all || bc_none, "形态档的 BC 格式一半有一半没有（%d/14），本测试的期望只覆盖全有 / 全无", bc_sampled);
    EXPECT(d.bc_native_mask == (bc_all ? 0xffffu : 0u), "bc_native_mask=0x%04x，形态档 BC %s", d.bc_native_mask, bc_all ? "全有" : "全无");
    EXPECT(d.bc_decode_mask == (~d.bc_native_mask & 0xffffu) && popcount16(d.bc_native_mask) + popcount16(d.bc_decode_mask) == 16,
           "bc_decode_mask=0x%04x 不是原生位的补集", d.bc_decode_mask);
    // 深度替换（C1）：D24S8 不能当深度模板附件、D32S8 能 → 换 D32S8
    const VkFormatFeatureFlags att = VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    const int d24_subst = !(cs_format(s, VK_FORMAT_D24_UNORM_S8_UINT).optimalTilingFeatures & att) &&
                          (cs_format(s, VK_FORMAT_D32_SFLOAT_S8_UINT).optimalTilingFeatures & att);
    EXPECT(((d.depth_subst_mask & 1u) != 0) == d24_subst, "depth_subst_mask=0x%x，期望 D24S8 替换=%d", d.depth_subst_mask, d24_subst);
    // 着色器能力位（C4 / C5）：有就启用、没有不启用；64 位与曲面细分本后端从不启用
    EXPECT(d.core_features.shaderInt16 == s->features.shaderInt16, "shaderInt16 启用=%u，支持=%u", d.core_features.shaderInt16, s->features.shaderInt16);
    EXPECT(d.core_features.shaderStorageImageReadWithoutFormat == s->features.shaderStorageImageReadWithoutFormat,
           "shaderStorageImageReadWithoutFormat 启用=%u，支持=%u", d.core_features.shaderStorageImageReadWithoutFormat, s->features.shaderStorageImageReadWithoutFormat);
    EXPECT(d.core_features.vertexPipelineStoresAndAtomics == s->features.vertexPipelineStoresAndAtomics,
           "vertexPipelineStoresAndAtomics 启用=%u，支持=%u", d.core_features.vertexPipelineStoresAndAtomics, s->features.vertexPipelineStoresAndAtomics);
    EXPECT(d.core_features.shaderClipDistance == s->features.shaderClipDistance, "shaderClipDistance 启用=%u，支持=%u",
           d.core_features.shaderClipDistance, s->features.shaderClipDistance);
    EXPECT(!d.core_features.shaderFloat64 && !d.core_features.shaderInt64 && !d.core_features.tessellationShader,
           "64 位 / 曲面细分不该启用（%u %u %u）", d.core_features.shaderFloat64, d.core_features.shaderInt64, d.core_features.tessellationShader);
    // 几何着色器（#1456 / #1482）：判定已放行，开不开 = 设备支不支持
    EXPECT(d.core_features.geometryShader == s->features.geometryShader, "geometryShader 启用=%u，支持=%u（判定放行）",
           d.core_features.geometryShader, s->features.geometryShader);
    // 数组层夹取缺省（N1）：三档都不是要它的驱动，缺省必须关（开了每次数组采样白多一次尺寸查询和夹取）
    g.dev = &d;
    EXPECT(array_query_default() == 0, "array_query_default()=%d：%s 档不该缺省开数组层夹取", array_query_default(), s->name);

    // 启用 → caps JSON（编译器 profile 的唯一来源）：限值原样进 JSON
    static char json[16384]; size_t len = 0;
    EXPECT(s2a_vk_device_caps_json(&d, json, sizeof json, &len) == 0, "s2a_vk_device_caps_json 失败");
    char want[96];
    snprintf(want, sizeof want, "\"maxComputeSharedMemorySize\":%u,", s->props.limits.maxComputeSharedMemorySize);
    EXPECT(strstr(json, want) != NULL, "caps JSON 里没有 %s", want);
    snprintf(want, sizeof want, "\"maxPerStageDescriptorUniformBuffers\":%u,", s->props.limits.maxPerStageDescriptorUniformBuffers);
    EXPECT(strstr(json, want) != NULL, "caps JSON 里没有 %s", want);
    snprintf(want, sizeof want, "\"shaderStorageImageReadWithoutFormat\":%s}", s->features.shaderStorageImageReadWithoutFormat ? "true" : "false");
    EXPECT(strstr(json, want) != NULL, "caps JSON 里没有 %s", want);
    FILE *f = fopen(argv[1], "w");
    if (!f || fwrite(json, 1, len, f) != len || fclose(f)) { printf("FAIL: [%s] 写不了 %s\n", s->name, argv[1]); return 1; }

    if (fails) return 1;
    printf("PASS: [%s] 建设备 + 17 项能力断言（格式列表=%d 自定义边框=%d 描述符索引=%d BC 原生=0x%04x D24 换 D32=%d Int16=%u 无格式读=%u 顶点存储=%u 几何=%u 数组层夹取缺省=0；启用扩展 %u 个）\n",
           s->name, d.image_format_list_enabled, d.custom_border_enabled, d.descriptor_indexing_enabled, d.bc_native_mask,
           d24_subst, d.core_features.shaderInt16, d.core_features.shaderStorageImageReadWithoutFormat,
           d.core_features.vertexPipelineStoresAndAtomics, d.core_features.geometryShader, cs_enabled_ext_count);
    return 0;
}
