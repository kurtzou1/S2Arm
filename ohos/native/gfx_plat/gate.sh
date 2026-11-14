#!/usr/bin/env bash
# 门禁路由：ohos/ graphics/nvn/replay/ graphics/nvn/gfx/nvn/nvn_vsync.h graphics/nvn/third_party/vulkan-headers/
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cc=${CC:-cc}
for source in plat_nvn.c plat_nvn_vk.c vsync.c; do
  "$cc" -std=c11 -Wall -Wextra -Werror -fsyntax-only \
    -I "$here/stub" -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
    -I "$repo/graphics/nvn/replay" -I "$repo/graphics/nvn/gfx/nvn" \
    "$here/$source"
done
echo 'PASS: OHOS platform syntax, 3 translation units (host stubs; not a device/link test)'
