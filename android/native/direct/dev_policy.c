/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#include "dev_policy.h"
#include "dev_facts.h"
#include "../nvn/nvn_vk_format.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static const struct s2a_policy_meta policy_meta[] = {
#define ITEM(id, name, class, repr, requires, consumers, off, on, other) \
    [S2A_POLICY_##id] = {name, S2A_POLICY_##class, S2A_POLICY_##repr, requires, consumers, {off, on, other}},
    S2A_DEV_POLICY_ITEMS(ITEM)
#undef ITEM
};

static int extension(const struct s2a_dev_facts *facts, const char *name) {
    if (facts->ext_state != 1) return -1;
    for (uint32_t i = 0; i < facts->n_ext; i++)
        if (!strcmp(facts->ext[i], name)) return 1;
    return 0;
}

static struct s2a_policy_item unknown(const char *why) {
    return (struct s2a_policy_item){0, S2A_POLICY_UNKNOWN, why};
}

static struct s2a_policy_item baseline(const char *why) {
    return (struct s2a_policy_item){0, S2A_POLICY_BASELINE, why};
}

static struct s2a_policy_item queried(uint64_t value, const char *evidence) {
    return (struct s2a_policy_item){value, S2A_POLICY_QUERY, evidence};
}

static struct s2a_policy_item queried_extension(const struct s2a_dev_facts *facts, const char *name) {
    int state = extension(facts, name);
    return state < 0 ? unknown(name) : queried((uint64_t)state, name);
}

static int format_flags(const struct s2a_dev_facts *facts, VkFormat format, VkFormatFeatureFlags *flags) {
    VkFormat candidate;
    for (size_t i = 0; s2a_dev_facts_format_name(i, &candidate); i++) {
        if (candidate != format) continue;
        if (!facts->fmt_have[i]) return 0;
        *flags = facts->fmt[i].optimalTilingFeatures;
        return 1;
    }
    return 0;
}

static struct s2a_policy_item bc_native(const struct s2a_dev_facts *facts) {
    uint32_t mask = 0;
    for (unsigned i = 0; i < 16; i++) {
        VkFormatFeatureFlags flags;
        /* NVN formats 0x41..0x50 are the bit order of vk_device.bc_native_mask. */
        if (!format_flags(facts, nvn_vk_format(0x41u + i), &flags))
            return unknown("BC 逐格式最优平铺采样能力缺失");
        if (flags & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) mask |= 1u << i;
    }
    return queried(mask, "BC 原生位，计算解码是其 16 位补集");
}

static struct s2a_policy_item depth_substitution(const struct s2a_dev_facts *facts) {
    const VkFormat formats[] = {VK_FORMAT_D24_UNORM_S8_UINT, VK_FORMAT_D32_SFLOAT_S8_UINT,
                                 VK_FORMAT_X8_D24_UNORM_PACK32, VK_FORMAT_D32_SFLOAT};
    VkFormatFeatureFlags flags[4];
    for (unsigned i = 0; i < 4; i++)
        if (!format_flags(facts, formats[i], &flags[i])) return unknown("D24/D32 附件格式能力缺失");
    return queried(nvn_vk_depth_subst_pick(flags[0], flags[1], flags[2], flags[3]), "D24/D32 附件格式能力");
}

static struct s2a_policy_item packed16_fallback(const struct s2a_dev_facts *facts) {
    VkFormatFeatureFlags exact[NVN_VK_P16_N] = {0}, fallback[NVN_VK_P16_N] = {0};
    for (int i = 0; i < NVN_VK_P16_N; i++) {
        VkFormat e, f;
        nvn_vk_p16_entry(i, NULL, &e, &f);
        if (f == VK_FORMAT_UNDEFINED) continue;
        int gated = e == VK_FORMAT_A1B5G5R5_UNORM_PACK16_KHR;  /* Application API 1.1 lacks maintenance5. */
        if (e == VK_FORMAT_A4B4G4R4_UNORM_PACK16_EXT) {
            int ext = extension(facts, VK_EXT_4444_FORMATS_EXTENSION_NAME);
            if (ext < 0 || (ext && !facts->have_4444)) return unknown("4444 扩展或 formatA4B4G4R4 未知");
            gated = !ext || facts->f4444.formatA4B4G4R4 != VK_TRUE;
        }
        if (!format_flags(facts, f, &fallback[i]) || (!gated && !format_flags(facts, e, &exact[i])))
            return unknown("打包 16 位精确或退回格式能力缺失");
    }
    return queried(nvn_vk_p16_fallback_pick(exact, fallback), "打包 16 位格式采样能力");
}

static struct s2a_policy_item feature_path(const struct s2a_dev_facts *facts, const char *name,
                                           int seen, VkBool32 supported, const char *feature) {
    int ext = extension(facts, name);
    if (ext < 0) return unknown(name);
    if (!ext) return queried(0, name);
    return seen ? queried(supported == VK_TRUE, feature) : unknown(feature);
}

static struct s2a_policy_item calibrated_timestamps(const struct s2a_dev_facts *facts) {
    int khr = extension(facts, VK_KHR_CALIBRATED_TIMESTAMPS_EXTENSION_NAME);
    int ext = extension(facts, VK_EXT_CALIBRATED_TIMESTAMPS_EXTENSION_NAME);
    return khr == 0 && ext == 0 ? queried(0, "KHR/EXT 校准时间戳扩展均无")
                                : unknown("需有效扩展与 DEVICE/CLOCK_MONOTONIC 时间域");
}

static struct s2a_policy_item staging(const struct s2a_dev_facts *facts) {
    const VkMemoryPropertyFlags coherent = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const VkMemoryPropertyFlags cached = coherent | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    int has_coherent = 0;
    for (uint32_t i = 0; i < facts->memory.memoryTypeCount; i++) {
        VkMemoryPropertyFlags flags = facts->memory.memoryTypes[i].propertyFlags;
        if ((flags & cached) == cached) return unknown("暂存优先 cached，实际类型需缓冲 memoryTypeBits");
        if ((flags & coherent) == coherent) has_coherent = 1;
    }
    return has_coherent ? queried(0, "无 coherent+cached 候选") : unknown("缺少 coherent 暂存类型");
}

static struct s2a_policy_item memory_import(const struct s2a_dev_facts *facts) {
    /* vulkan_android.h declares this name only in platform builds. */
    int ahb = extension(facts, "VK_ANDROID_external_memory_android_hardware_buffer");
    int foreign = extension(facts, VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME);
    if (ahb < 0 || foreign < 0) return unknown("AHB 或 foreign 队列族扩展未知");
    /* Default request in vk_device.c only. The report precedes vkCreateDevice. */
    return queried(ahb && foreign ? 2 : 0, "AHB 与 foreign 配对，host import 缺省不请求");
}

int s2a_dev_policy_derive(const struct s2a_dev_policy_inputs *inputs, struct s2a_dev_policy *out) {
    if (!inputs || !inputs->facts || !out) return -1;
    const struct s2a_dev_facts *facts = inputs->facts;
    if (facts->n_ext > S2A_DEV_FACTS_MAX_EXT || facts->memory.memoryTypeCount > VK_MAX_MEMORY_TYPES) return -1;
    struct s2a_policy_item *item = out->items;
    item[S2A_POLICY_TEX_FMT_LIST] = queried_extension(facts, VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME);
    item[S2A_POLICY_TEX_MUTABLE] = baseline("当前无按需重建路径");
    item[S2A_POLICY_PASS_TILE_OPTS] = baseline("Vulkan TILE_MEMORY 能力位未置");
    item[S2A_POLICY_TEX_BC] = bc_native(facts);
    item[S2A_POLICY_DEPTH_SUBST] = depth_substitution(facts);
    item[S2A_POLICY_PACKED16] = packed16_fallback(facts);
    item[S2A_POLICY_INDEX_UINT8] = feature_path(facts, VK_EXT_INDEX_TYPE_UINT8_EXTENSION_NAME,
        facts->have_index_u8, facts->index_u8.indexTypeUint8, "indexTypeUint8");
    item[S2A_POLICY_GS_PATH] = facts->features.geometryShader ? unknown("缺 GS+遮挡实测判定")
                                                            : queried(0, "geometryShader=0");
    item[S2A_POLICY_NO_ATTACH] = baseline("零附件能力已撤回");
    item[S2A_POLICY_CALIBRATED_TS] = calibrated_timestamps(facts);
    item[S2A_POLICY_DISPLAY_TIMING] = baseline("display_timing 属性缺省关");
    item[S2A_POLICY_STAGING] = staging(facts);
    item[S2A_POLICY_UBO_DYNAMIC] = queried(facts->props.limits.maxDescriptorSetUniformBuffersDynamic,
                                           "limits.maxDescriptorSetUniformBuffersDynamic");
    item[S2A_POLICY_MINMAX] = queried_extension(facts, VK_EXT_SAMPLER_FILTER_MINMAX_EXTENSION_NAME);
    item[S2A_POLICY_CUSTOM_BORDER] = feature_path(facts, VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME,
        facts->have_border, facts->border.customBorderColors, "customBorderColors");
    item[S2A_POLICY_MIRROR_CLAMP] = queried_extension(facts, VK_KHR_SAMPLER_MIRROR_CLAMP_TO_EDGE_EXTENSION_NAME);
    item[S2A_POLICY_MEM_IMPORT] = memory_import(facts);
    item[S2A_POLICY_FB_COMPRESSION] = extension(facts, VK_EXT_IMAGE_COMPRESSION_CONTROL_EXTENSION_NAME) == 0
        ? queried(0, VK_EXT_IMAGE_COMPRESSION_CONTROL_EXTENSION_NAME) : unknown("缺附件压缩实测");
    item[S2A_POLICY_FB_FETCH] = baseline("Vulkan 未发布 FB_FETCH 能力");
    item[S2A_POLICY_CPU_AFFINITY] = unknown("需游戏线程允许核掩码及容量");
    item[S2A_POLICY_CPU_FLOOR] = unknown("需托底线程的运行时核组");
    item[S2A_POLICY_GPU_TURBO] = facts->kgsl == 0 ? queried(0, "KGSL 节点缺失") : unknown("缺 KGSL 实际锁频判定");
    item[S2A_POLICY_ADPF] = facts->adpf == 0 ? queried(0, "ADPF 符号不齐") : unknown("缺 ADPF 会话创建结果");
    item[S2A_POLICY_SUSTAINED] = unknown("未查询持续性能模式是否可用");
    item[S2A_POLICY_VSYNC] = facts->vsync_api < 0 ? unknown("Choreographer 入口未知")
                                                 : queried((uint64_t)facts->vsync_api, "Choreographer 可用最高入口档");
    item[S2A_POLICY_PAGE_SIZE] = facts->page_size <= 0 ? unknown("sysconf 页大小未知")
                                                      : queried((uint64_t)facts->page_size, "_SC_PAGESIZE");
    return 0;
}

const struct s2a_policy_meta *s2a_dev_policy_meta(enum s2a_policy_id id) {
    return (unsigned)id < S2A_POLICY_COUNT ? &policy_meta[id] : NULL;
}

const struct s2a_policy_item *s2a_dev_policy_get(const struct s2a_dev_policy *policy, enum s2a_policy_id id) {
    return policy && s2a_dev_policy_meta(id) ? &policy->items[id] : NULL;
}

int s2a_dev_policy_summary(const struct s2a_dev_policy *policy, const char *digest, char *out, size_t cap) {
    if (!policy || !digest || !out || !cap) return -1;
    int n = snprintf(out, cap, "【策略】v1 fp=%.16s mode=compat-default", digest[0] ? digest : "unknown");
    if (n < 0 || (size_t)n >= cap) return -1;
    size_t used = (size_t)n;
    for (enum s2a_policy_id id = 0; id < S2A_POLICY_COUNT; id++) {
        const struct s2a_policy_item *item = s2a_dev_policy_get(policy, id);
        const struct s2a_policy_meta *meta = s2a_dev_policy_meta(id);
        if (item->basis == S2A_POLICY_UNKNOWN) {
            n = snprintf(out + used, cap - used, " %s=未证", meta->name);
        } else if (meta->representation == S2A_POLICY_HEX) {
            n = snprintf(out + used, cap - used, " %s=0x%" PRIx64, meta->name, item->value);
        } else if (meta->representation == S2A_POLICY_DECIMAL) {
            n = snprintf(out + used, cap - used, " %s=%" PRIu64, meta->name, item->value);
        } else {
            if (item->value >= sizeof meta->values / sizeof meta->values[0] || !meta->values[item->value]) return -1;
            n = snprintf(out + used, cap - used, " %s=%s", meta->name, meta->values[item->value]);
        }
        if (n < 0 || (size_t)n >= cap - used) return -1;
        used += (size_t)n;
    }
    return 0;
}
