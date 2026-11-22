/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#include "caps_shape.h"
#include "dev_facts.h"
#include "dev_policy.h"
#include "vk_device.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

struct policy_archive {
    const char *name;
    int ext_unknown, index_known, border_known, packed_known;
    long page_size;
    int kgsl, adpf, vsync;
    const VkFormat *unknown_formats;
};
#include "policy_archives_gen.h"

static unsigned checks, failures;
#define EXPECT(cond, ...) do { \
    checks++; \
    if (!(cond)) { failures++; fprintf(stderr, "FAIL: [%s] ", cs_shape()->name); \
        fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } \
} while (0)

/* The existing fixture allows GS when the device can execute it. The new
 * report still cannot interpret that verdict from M0's raw facts alone. */
const char *s2a_capprobe_gs_occ_state(void) { return "caps-shape-test:supported"; }
const char *s2a_android_gpu_driver_files_dir(void) { return NULL; }

static int restore_archive_facts(struct s2a_dev_facts *facts) {
    for (size_t i = 0; i < sizeof policy_archives / sizeof policy_archives[0]; i++) {
        const struct policy_archive *a = &policy_archives[i];
        if (strcmp(a->name, cs_shape()->name)) continue;
        if (a->ext_unknown) facts->ext_state = -1;
        if (!a->index_known) facts->have_index_u8 = 0;
        if (!a->border_known) facts->have_border = 0;
        if (!a->packed_known) facts->have_4444 = 0;
        facts->page_size = a->page_size;
        facts->kgsl = a->kgsl;
        facts->adpf = a->adpf;
        facts->vsync_api = a->vsync;
        VkFormat fmt;
        for (size_t j = 0; s2a_dev_facts_format_name(j, &fmt); j++) {
            for (const VkFormat *missing = a->unknown_formats; *missing != VK_FORMAT_UNDEFINED; missing++) {
                if (fmt == *missing) { facts->fmt_have[j] = 0; break; }
            }
        }
        return 1;
    }
    return 0;
}

static void match_current(const struct s2a_dev_policy *p, enum s2a_policy_id id, uint64_t expected) {
    const struct s2a_policy_item *val = s2a_dev_policy_get(p, id);
    if (val->basis == S2A_POLICY_UNKNOWN) return;  /* The archive golden checks which inputs are missing. */
    EXPECT(val->value == expected, "%s 与现状选择不同：期望 0x%" PRIx64 " → 实测 0x%" PRIx64,
           s2a_dev_policy_meta(id)->name, expected, val->value);
}

static void check_current(const struct s2a_dev_policy *p, const struct s2a_vk_device *d) {
    match_current(p, S2A_POLICY_TEX_FMT_LIST, d->image_format_list_enabled);
    match_current(p, S2A_POLICY_TEX_BC, d->bc_native_mask);
    match_current(p, S2A_POLICY_DEPTH_SUBST, d->depth_subst_mask);
    match_current(p, S2A_POLICY_PACKED16, d->p16_fallback_mask);
    match_current(p, S2A_POLICY_INDEX_UINT8, d->index_type_uint8_enabled);
    match_current(p, S2A_POLICY_GS_PATH, d->core_features.geometryShader);
    match_current(p, S2A_POLICY_DISPLAY_TIMING, d->has_display_timing);
    match_current(p, S2A_POLICY_UBO_DYNAMIC, d->properties.limits.maxDescriptorSetUniformBuffersDynamic);
    match_current(p, S2A_POLICY_MINMAX, d->sampler_minmax_enabled);
    match_current(p, S2A_POLICY_CUSTOM_BORDER, d->custom_border_enabled);
    match_current(p, S2A_POLICY_MIRROR_CLAMP, d->sampler_mirror_clamp_enabled);
    match_current(p, S2A_POLICY_MEM_IMPORT, d->ahb_import_enabled ? 2 : d->external_memory_host_enabled);
}

int main(void) {
    struct s2a_vk_device device;
    char why[256] = "";
    if (s2a_vk_device_create(&device, why, sizeof why)) {
        fprintf(stderr, "FAIL: [%s] 建设备失败：%s\n", cs_shape()->name, why);
        return 1;
    }
    static struct s2a_dev_facts facts;
    if (s2a_dev_facts_collect(device.physical, &facts) || !restore_archive_facts(&facts)) return 1;

    const struct s2a_dev_policy_inputs inputs = {.facts = &facts};
    struct s2a_dev_policy policy, altered;
    if (s2a_dev_policy_derive(&inputs, &policy)) return 1;
    check_current(&policy, &device);
    EXPECT(policy.items[S2A_POLICY_PASS_TILE_OPTS].value == 0, "pass.tile_opts 缺省应保持关");

    facts.props.vendorID = UINT32_MAX;
    facts.props.deviceID = UINT32_MAX;
    facts.props.driverVersion = UINT32_MAX;
    facts.props.deviceType = VK_PHYSICAL_DEVICE_TYPE_OTHER;
    facts.driver_id = -1;
    memset(facts.props.deviceName, 0, sizeof facts.props.deviceName);
    memset(facts.props.pipelineCacheUUID, 0, sizeof facts.props.pipelineCacheUUID);
    memset(facts.driver_name, 0, sizeof facts.driver_name);
    memset(facts.model, 0, sizeof facts.model);
    memset(facts.manufacturer, 0, sizeof facts.manufacturer);
    memset(facts.soc_model, 0, sizeof facts.soc_model);
    memset(facts.android_release, 0, sizeof facts.android_release);
    if (s2a_dev_policy_derive(&inputs, &altered)) return 1;
    for (enum s2a_policy_id id = 0; id < S2A_POLICY_COUNT; id++) {
        const struct s2a_policy_item *a = s2a_dev_policy_get(&policy, id);
        const struct s2a_policy_item *b = s2a_dev_policy_get(&altered, id);
        EXPECT(a->evidence && b->evidence && a->basis == b->basis && a->value == b->value && !strcmp(a->evidence, b->evidence),
               "%s 不读身份字段：换身份后推导改变", s2a_dev_policy_meta(id)->name);
    }

    facts.index_u8.indexTypeUint8 = VK_FALSE;
    if (s2a_dev_policy_derive(&inputs, &altered)) return 1;
    if (facts.have_index_u8) {
        EXPECT(altered.items[S2A_POLICY_INDEX_UINT8].basis == S2A_POLICY_QUERY &&
               altered.items[S2A_POLICY_INDEX_UINT8].value == 0, "idx.u8 有扩展但特性关闭时须 expand");
    }
    facts.ext_state = -1;
    if (s2a_dev_policy_derive(&inputs, &altered)) return 1;
    EXPECT(altered.items[S2A_POLICY_TEX_FMT_LIST].basis == S2A_POLICY_UNKNOWN, "tex.fmt_list 枚举失败须保留未证");
    EXPECT(altered.items[S2A_POLICY_INDEX_UINT8].basis == S2A_POLICY_UNKNOWN, "idx.u8 枚举失败须保留未证");
    EXPECT(altered.items[S2A_POLICY_MEM_IMPORT].basis == S2A_POLICY_UNKNOWN, "mem.import 枚举失败须保留未证");
    (void)s2a_vk_device_destroy(&device, 1);
    if (failures) return 1;

    char line[1536];
    if (s2a_dev_policy_summary(&policy, "", line, sizeof line)) return 1;
    puts(line);
    fprintf(stderr, "PASS: [%s] 策略 L0 %u 项检查，0 项红\n", cs_shape()->name, checks);
    return 0;
}
