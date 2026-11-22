/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#pragma once

/* Id, stable name, class, value representation, capability requirements,
 * consumers, compatibility value names.
 * Requirements are descriptive in M1. The compatibility report takes the
 * current default selections and never feeds them back into device creation. */
#define S2A_DEV_POLICY_ITEMS(X) \
    X(TEX_FMT_LIST, "tex.fmt_list", EXTENSION, CHOICE, "ext:VK_KHR_image_format_list", "vk_device.c,backend_vulkan.c", "off", "on", NULL) \
    X(TEX_MUTABLE, "tex.mutable_on_demand", CORE, CHOICE, "", "backend_vulkan.c", "off", NULL, NULL) \
    X(PASS_TILE_OPTS, "pass.tile_opts", CORE, CHOICE, "", "backend_vulkan.c,rp_pass.c", "off", NULL, NULL) \
    X(TEX_BC, "tex.bc", SEMANTIC, HEX, "format:BCn SAMPLED_IMAGE", "vk_device.c,backend_vulkan.c", NULL, NULL, NULL) \
    X(DEPTH_SUBST, "fmt.depth_subst", FACT, HEX, "format:DEPTH_STENCIL_ATTACHMENT", "nvn_vk_format.c", NULL, NULL, NULL) \
    X(PACKED16, "fmt.p16", FACT, HEX, "format:SAMPLED_IMAGE,feat:formatA4B4G4R4", "nvn_vk_format.c", NULL, NULL, NULL) \
    X(INDEX_UINT8, "idx.u8", SEMANTIC, CHOICE, "ext:VK_EXT_index_type_uint8,feat:indexTypeUint8", "vk_device.c,backend_vulkan.c", "expand", "native", NULL) \
    X(GS_PATH, "gs.path", SEMANTIC, CHOICE, "feat:geometryShader,probe:gs_occlusion", "gs_path.c,backend_vulkan.c", "compute", "hardware", NULL) \
    X(NO_ATTACH, "pass.no_attach", SEMANTIC, CHOICE, "", "backend_vulkan.c", "off", NULL, NULL) \
    X(CALIBRATED_TS, "ts.calibrated", SEMANTIC, CHOICE, "ext:calibrated_timestamps,domain:DEVICE+CLOCK_MONOTONIC", "backend_vulkan.c", "none", "khr", "ext") \
    X(DISPLAY_TIMING, "wsi.display_timing", EXTENSION, CHOICE, "ext:VK_GOOGLE_display_timing", "vk_device.c,backend_vulkan_wsi.inc", "off", "on", NULL) \
    X(STAGING, "mem.staging", EXTENSION, CHOICE, "memtype:HOST_VISIBLE+HOST_COHERENT+HOST_CACHED", "backend_vulkan.c", "coherent", "cached", NULL) \
    X(UBO_DYNAMIC, "desc.ubo_dynamic", FACT, DECIMAL, "limit:maxDescriptorSetUniformBuffersDynamic", "backend_vulkan.c", NULL, NULL, NULL) \
    X(MINMAX, "samp.minmax", SEMANTIC, CHOICE, "ext:VK_EXT_sampler_filter_minmax", "vk_device.c,backend_vulkan.c", "off", "on", NULL) \
    X(CUSTOM_BORDER, "samp.custom_border", SEMANTIC, CHOICE, "ext:VK_EXT_custom_border_color,feat:customBorderColors", "vk_device.c,backend_vulkan.c", "off", "on", NULL) \
    X(MIRROR_CLAMP, "samp.mirror_clamp", SEMANTIC, CHOICE, "ext:VK_KHR_sampler_mirror_clamp_to_edge", "vk_device.c,backend_vulkan.c", "off", "on", NULL) \
    X(MEM_IMPORT, "mem.import", EXTENSION, CHOICE, "ext:external_memory_host or AHB+queue_family_foreign", "vk_device.c", "off", "host", "ahb") \
    X(FB_COMPRESSION, "fb.compression", FACT, CHOICE, "ext:VK_EXT_image_compression_control,probe:fb_compression", "dev_policy.c", "unavailable", NULL, NULL) \
    X(FB_FETCH, "fb.fetch", EXTENSION, CHOICE, "ext:raster_order_attachment_access,format:FB_FETCH", "backend_vulkan.c", "off", NULL, NULL) \
    X(CPU_AFFINITY, "cpu.affinity", SEMANTIC, CHOICE, "sys:cpu_capacity,cpuset", "capacity_affinity.cpp", "mode0", "split", NULL) \
    X(CPU_FLOOR, "cpu.floor_group", FACT, HEX, "sys:cpu topology,cpuset", "cpu_floor.c", NULL, NULL, NULL) \
    X(GPU_TURBO, "gpu.turbo", EXTENSION, CHOICE, "sys:KGSL", "cpu_floor.c", "off", "auto", NULL) \
    X(ADPF, "perf.adpf", SEMANTIC, CHOICE, "sym:APerformanceHint_*", "adpf_hint.c", "none", "on", NULL) \
    X(SUSTAINED, "perf.sustained", SEMANTIC, CHOICE, "api:isSustainedPerformanceModeSupported", "MainActivity.java", "none", "on", NULL) \
    X(VSYNC, "vsync.source", SEMANTIC, DECIMAL, "sym:AChoreographer_*", "nvn_vsync_android.c", NULL, NULL, NULL) \
    X(PAGE_SIZE, "mem.page", FACT, DECIMAL, "sysconf:_SC_PAGESIZE", "plat_android.c", NULL, NULL, NULL)
