# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
cmake_minimum_required(VERSION 3.16)
project(s2arm_ohos_native LANGUAGES C ASM)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS" OR NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    message(FATAL_ERROR "Use the official OHOS arm64-v8a toolchain; no Android ABI emulation")
endif()
get_filename_component(S2A_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
include("${S2A_ROOT}/android/core-link/Runtime.cmake")
s2a_android_game_sources(S2A_CORE_SOURCES)
# OHOS keeps the managed ABI but selects its bounded fresh-slot reader.
list(REMOVE_ITEM S2A_CORE_SOURCES "${S2A_ROOT}/android/native/runtime/tracking/readonly_copy.c")
add_library(s2arm_ohos_native STATIC
    ${S2A_CORE_SOURCES}
    "${S2A_ROOT}/android/native/memory.c"
    "${S2A_ROOT}/android/native/guest_signal.c"
    "${S2A_ROOT}/android/native/module.c"
    "${S2A_ROOT}/android/native/screen_metrics.c"
    "${S2A_ROOT}/android/native/system_tuning.c"   # frame-period cap / present note used by hle_nvn.c
    "${S2A_ROOT}/android/native/game_touch.c"
    "${S2A_ROOT}/runtime/src/fps.c"   # upstream 60 FPS table runtime (same as iOS host)
    fps_ohos.c guest_read.c plat_ohos.c tsd_ohos.c runtime_ohos.c signed_module.c ohos_h264.c upstream_glue_ohos.c)
# 共享安卓源码里的 <android/log.h> / <sys/system_properties.h> 由鸿蒙兼容头接到 hilog / 环境变量。
target_include_directories(s2arm_ohos_native BEFORE PRIVATE "${CMAKE_CURRENT_LIST_DIR}/compat_android")
target_include_directories(s2arm_ohos_native PRIVATE
    "${S2A_ROOT}" "${S2A_ROOT}/runtime/src" "${S2A_ROOT}/runtime/include" "${S2A_ROOT}/shared" "${S2A_ROOT}/android/native")
target_compile_features(s2arm_ohos_native PRIVATE c_std_11)
target_compile_definitions(s2arm_ohos_native PRIVATE _GNU_SOURCE)
target_compile_options(s2arm_ohos_native PRIVATE
    -Wall -Wextra -Werror=implicit-function-declaration -Werror=incompatible-pointer-types
    -ffunction-sections -fdata-sections -fno-emulated-tls)   # SVC/VM 的线程变量在游戏线程热路径上，musl 有原生 TLS
set_target_properties(s2arm_ohos_native PROPERTIES POSITION_INDEPENDENT_CODE ON)
# HostApi/input/WSI lease and s2a_android_services_* are real integration inputs.
# The final shared library links each exactly once, with --no-undefined.
target_link_libraries(s2arm_ohos_native PUBLIC dl)

# Direct mode: shared NVN frontend (graphics/nvn) + the S2Arm Vulkan backend shared with Android
# (android/native/{direct,nvn}). Only the window/log seams differ (compat_android/,
# VK_OHOS_surface). Selection still happens before relocation; generic stays the default.
option(S2A_OHOS_DIRECT "Build the NVN->Vulkan direct backend into the OHOS engine" ON)
if(S2A_OHOS_DIRECT)
    set(A "${S2A_ROOT}/android/native")
    set(G "${S2A_ROOT}/graphics/nvn")
    # 直连后端源清单与安卓同源（LinkSources.cmake 的 s2a_android_direct_sources），只追加鸿蒙专属文件。
    include("${S2A_ROOT}/android/core-link/LinkSources.cmake")
    # Shared upstream replay backend; old graphics backend stays out of this package.
    set(S2A_OHOS_VK_BACKEND "nvk")
    s2a_android_nvk_sources(s2a_direct_rel)
    list(REMOVE_ITEM s2a_direct_rel native/gfx_plat/plat_nvn.c native/gfx_plat/plat_nvn_vk.c native/nvn/nvn_vsync_android.c)
    set(S2A_OHOS_DIRECT_BACKEND)
    # O-2：上游安卓专有的显示节拍源（AChoreographer）鸿蒙不编。
    list(REMOVE_ITEM s2a_direct_rel native/nvn/nvn_vsync_android.c)
    foreach(src IN LISTS s2a_direct_rel)
        list(APPEND S2A_OHOS_DIRECT_BACKEND "${S2A_ROOT}/android/${src}")
    endforeach()
    # 与上游 android/CMakeLists.txt 的直连段同一份清单（v0.1.0）；只追加鸿蒙专属文件。
        set(P "${CMAKE_CURRENT_LIST_DIR}/gfx_plat")
        list(APPEND S2A_OHOS_DIRECT_BACKEND
            ${A}/gfx_plat/provider_nvk.c ${A}/direct/profile_compose.c ${A}/redlog.c
            ${P}/plat_nvn.c ${P}/plat_nvn_vk.c ${P}/vsync.c
            # 安卓 plat_nvn.c 里混着的前端宿主入口（nvn_diag_path / dm_opmode / s2a_nvn_prof / s2a_nvn_render_cond）：
            # 原样编进来，平台接口四个名字改名让给鸿蒙版（给上游的反馈：这几项不该放在平台件里）。
            ${A}/gfx_plat/plat_nvn.c
            # SDK 主版本 / 游戏自带驱动的 NVN API 版本：与安卓、苹果同一份 nvn_drvinfo.inc（同安卓 CMakeLists 的 VK 引擎段）
            ${A}/nvn/nvn_drvinfo_android.c
            "${CMAKE_CURRENT_LIST_DIR}/direct_ohos.c"
            "${CMAKE_CURRENT_LIST_DIR}/native_buffer_pool.c")
        set_source_files_properties(${A}/nvn/nvn_drvinfo_android.c PROPERTIES COMPILE_OPTIONS "-Wno-error")
        set_source_files_properties(${A}/gfx_plat/plat_nvn.c PROPERTIES COMPILE_DEFINITIONS
            "nvn_plat_log=s2a_aplat_log;nvn_plat_flag=s2a_aplat_flag;nvn_plat_dir=s2a_aplat_dir;nvn_plat_safepoint=s2a_aplat_safepoint")
    set(s2a_nvn_names "${G}/gfx/nvn/names.txt")
    add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/nvn_names_android.c"
        COMMAND "${CMAKE_COMMAND}" -D "NAMES=${s2a_nvn_names}"
                -D "OUT=${CMAKE_CURRENT_BINARY_DIR}/nvn_names_android.c"
                -P "${A}/nvn/gen_nvn_names.cmake"
        DEPENDS "${s2a_nvn_names}" "${A}/nvn/gen_nvn_names.cmake"
        VERBATIM)
    set(S2A_OHOS_DIRECT_FRONTEND
        ${A}/nvn/portable.c ${A}/nvn/s2a_vp_alias.c ${G}/gfx/nvn/hle_nvn.c ${G}/gfx/nvn/nvn2.c ${G}/gfx/nvn/nvn_fps.c
        "${CMAKE_CURRENT_BINARY_DIR}/nvn_names_android.c"
        ${A}/nvn/vk_engine_host_shim.c ${A}/nvn/shader_survey.c)
    add_library(s2arm_ohos_direct STATIC ${S2A_OHOS_DIRECT_BACKEND} ${S2A_OHOS_DIRECT_FRONTEND})
    # Optional Huawei SDK headers; XEngine is loaded only for an explicitly enabled session.
    set(S2A_HMS_INCLUDE "${CMAKE_SYSROOT}/../../../hms/native/sysroot/usr/include")
    if(EXISTS "${S2A_HMS_INCLUDE}/xengine/xeg_vulkan_spatial_upscale.h")
        target_include_directories(s2arm_ohos_direct SYSTEM PRIVATE "${S2A_HMS_INCLUDE}")
    endif()
    target_include_directories(s2arm_ohos_direct BEFORE PRIVATE "${CMAKE_CURRENT_LIST_DIR}/compat_android")
    target_include_directories(s2arm_ohos_direct PRIVATE
        "${S2A_ROOT}" "${G}/gfx/nvn" "${G}/gfx/nvn/include" "${G}" "${G}/host" "${G}/gfx/tex"
        "${A}/nvn" "${A}/nvn/compat" "${A}/direct" "${A}" "${S2A_ROOT}/runtime/src" "${S2A_ROOT}/runtime/include"
        "${S2A_ROOT}/graphics/vulkan/nvn" "${S2A_ROOT}/graphics/track" "${G}/replay")
    # BC 软解（Maleoon 没有 textureCompressionBC）用 nvn_bc.h；实现由引擎已链接的 nvn 传输库（link_engine --nvn）提供。
    target_compile_definitions(s2arm_ohos_direct PRIVATE _GNU_SOURCE S2A_ANDROID_VK_ENGINE=1 S2A_ANDROID_VK_BACKEND_NVN_VK=1)
        target_compile_definitions(s2arm_ohos_direct PRIVATE S2A_ANDROID_VK_BACKEND_NVK=1)
    target_compile_options(s2arm_ohos_direct PRIVATE -fno-emulated-tls)  # 回放热路径上 emutls 占约 3.6%，musl 有原生 TLS
    target_compile_options(s2arm_ohos_direct PRIVATE -Wno-missing-field-initializers -ffunction-sections -fdata-sections)
    # 回放在单线程上跑满：使用工具链默认 ISA 和 O3；保留帧指针给 PC 采样。
    target_compile_options(s2arm_ohos_direct PRIVATE -O3 -fno-omit-frame-pointer)
    set_source_files_properties(${S2A_OHOS_DIRECT_FRONTEND} PROPERTIES COMPILE_OPTIONS "-Wno-error")
    set_target_properties(s2arm_ohos_direct PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()
