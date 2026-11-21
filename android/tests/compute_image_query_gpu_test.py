#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁手动：要 Vulkan 测试容器环境（读 S2A_VK_LAYER_DIR / lavapipe），宿主直接跑 KeyError；该接进 android/tests/vk/run.sh 还是 tests/android_vk_test.sh 待 owner 定（改 vk 夹具须在 CI 同版本容器跑整套）
"""Run the original SPIR-V image-size fixture with lavapipe and Vulkan validation."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'android/core-link'))
import link_symbols
import host_link


def main():
    ndk = link_symbols.find_ndk()
    if not ndk:
        raise RuntimeError('requires pinned NDK 29 Vulkan headers')
    layers = Path(os.environ['S2A_VK_LAYER_DIR'])
    if not (layers / 'VkLayer_khronos_validation.json').is_file():
        raise RuntimeError('requires Khronos validation layer')
    icd = Path(os.environ.get('S2A_LAVAPIPE_ICD', '/usr/share/vulkan/icd.d/lvp_icd.json'))
    if not icd.is_file():
        raise RuntimeError('requires lavapipe ICD')
    with tempfile.TemporaryDirectory(prefix='s2a-image-query-') as tmp:
        out = Path(tmp)
        for name in ('vulkan', 'vk_video'):
            (out / name).symlink_to(ndk / 'toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include' / name)
        inc = [out, *(ROOT / p for p in ('graphics/nvn/gfx/nvn', 'graphics/nvn/gfx/nvn/include',
               'graphics/nvn/gfx/tex', 'graphics/nvn/replay', 'android/native', 'android/native/nvn', 'android/native/direct', 'android/native/gfx_plat', 'runtime/include'))]
        sources = ('android/tests/vk/t_compute_image_query.c', 'android/native/nvn/backend_vulkan.c',
                   'graphics/nvn/replay/rp_res.c', 'graphics/nvn/replay/nvn_unimpl.c',
                   'android/native/direct/vk_device.c', 'android/native/direct/gs_path.c',
                   'android/native/capprobe/capprobe_host.c', 'android/native/nvn/nvn_vk_format.c',
                   'graphics/nvn/gfx/nvn/nvn_fmt_expand.c', 'android/native/nvn/nvn_vk_bcdec.c',
                   'android/native/nvn/nvn_vk_driver_cache.c', 'android/native/direct/sha256.c',
                   'android/native/nvn/nvn_vk_program_result.c', 'android/native/direct/jv.c', 'android/native/direct/json.c')
        cmd = [os.environ.get('CC', 'cc'), '-std=c11', '-O1', '-D_POSIX_C_SOURCE=200809L',
               '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-ffunction-sections',
               '-fdata-sections', '-DS2A_ANDROID_VK_BACKEND_NVN_VK=1', *('-I' + str(p) for p in inc),
               *(str(ROOT / p) for p in sources), '-Wl,--gc-sections', '-lvulkan', '-lpthread', '-lm', '-o', str(out / 'test')]
        host_link.run(cmd, check=True, timeout=120)
        env = dict(os.environ, VK_DRIVER_FILES=str(icd), VK_ICD_FILENAMES=str(icd),
                   VK_LAYER_PATH=str(layers), VK_INSTANCE_LAYERS='VK_LAYER_KHRONOS_validation')
        result = subprocess.run([str(out / 'test')], env=env, capture_output=True, text=True, timeout=60)
        print(result.stdout, end=''); print(result.stderr, end='', file=sys.stderr)
        if result.returncode or 'Validation Error' in result.stderr:
            raise RuntimeError('GPU readback or Vulkan validation failed')
        negative = subprocess.run([str(out / 'test')], env=dict(env, S2A_IMAGE_QUERY_WRONG_VIEW='1'),
                                  capture_output=True, text=True, timeout=60)
        if not negative.returncode or 'actual == width' not in negative.stderr or 'Validation Error' in negative.stderr:
            raise RuntimeError(f'wrong-view negative control failed: {negative.stderr}')
        print('PASS: wrong view failed the width assertion')


if __name__ == '__main__':
    main()
