// 整台设备能力形态档（shapes.py 出的三档）在 C 侧的样子；假驱动 fake_vk.c 按 S2A_CAPS_SHAPE 选一档回答 Vulkan 查询。
#pragma once
#include <stdint.h>
#include <vulkan/vulkan.h>

struct cs_fmt { int32_t format; uint32_t linear, optimal, buffer; };
struct cs_shape {
    const char *name;
    VkPhysicalDeviceProperties props;
    VkPhysicalDeviceFeatures features;
    // 扩展特性结构里的位（shapes.py EXT_FEATURES；di* = 描述符索引支持位）
    int shaderDrawParameters, timelineSemaphore, indexTypeUint8, customBorderColors, customBorderColorWithoutFormat,
        vertexAttributeInstanceRateDivisor, formatA4B4G4R4, depthClipControl,
        diRuntimeArray, diPartiallyBound, diSampledNonUniform, diStorageNonUniform, diVariableCount, diSampledUpdateAfterBind;
    int driver_id;
    const char *driver_name;
    uint64_t max_alloc;
    uint32_t subgroup_size;
    uint32_t n_heap; struct { uint64_t size; uint32_t flags; } heaps[VK_MAX_MEMORY_HEAPS];
    uint32_t n_type; struct { uint32_t flags, heap; } types[VK_MAX_MEMORY_TYPES];
    uint32_t n_queue; struct { uint32_t flags, count; } queues[8];
    uint32_t n_ext; const char *const *ext;
    uint32_t n_fmt; const struct cs_fmt *fmt;
};

// fake_vk.c：本进程选中的档（S2A_CAPS_SHAPE 不认识就退出 2）
const struct cs_shape *cs_shape(void);
int cs_has_ext(const struct cs_shape *s, const char *name);
VkFormatProperties cs_format(const struct cs_shape *s, VkFormat f);
// 假驱动在 vkCreateDevice 时核「启用的 ⊆ 支持的」（真驱动在这里回 FEATURE_NOT_PRESENT / EXTENSION_NOT_PRESENT）；不符时这里写原因
extern char cs_create_device_why[256];
extern uint32_t cs_enabled_ext_count;
extern const char *cs_enabled_ext[32];
