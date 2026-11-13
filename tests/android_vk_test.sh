#!/usr/bin/env bash
# 门禁只看：android/tests/vk/* android/tests/vkhost/* android/tests/first_draw_unnorm* android/native/nvn/backend_vulkan.c android/native/nvn/backend_vulkan_clear.inc android/native/nvn/nvn_vk_bcdec.c android/native/nvn/nvn_vk_format.c android/native/nvn/nvn_vk_driver_cache.c android/native/nvn/nvn_vk_driver_cache.h android/native/direct/sha256.c android/native/direct/sha256.h graphics/nvn/gfx/nvn/nvn_fmt_expand.c graphics/nvn/gfx/nvn/nvn_backend.h graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_refl.h android/native/direct/vk_device.c android/native/direct/vk_device.h android/native/direct/gs_path.c android/native/direct/gs_path.h graphics/nvn/gfx/tex/nvn_bcdec.c graphics/nvn/gfx/nvn/include/* tests/vulkan/*
# 门禁本机：Linux 直接执行；macOS 用本机 colima 中已准备的公共 Vulkan 镜像（同 tests/shader_cases_test.sh），gate-host 不具备此环境
# 安卓 nvn_gpu_* Vulkan 后端契约（android/tests/vk/run.sh：lavapipe + Khronos validation 跑 C01–C08 + C23/C25–C27 + BC1–BC7 逐像素解码；本机约 40 秒）
# 11-01 接线：扫描分母按 tests 目录后查出原先没有门禁调它。环境没备好时 tests/vulkan/run.sh 退 75（环境未就绪），不在门禁里装环境。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$H/android/tests/vk/run.sh"
