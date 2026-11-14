#!/usr/bin/env bash
# 门禁只看：android/tests/vk/* android/tests/vkhost/* android/tests/first_draw_unnorm* android/native/nvn/backend_vulkan.c android/native/nvn/backend_vulkan_clear.inc android/native/nvn/nvn_vk_bcdec.c android/native/nvn/nvn_vk_format.c android/native/nvn/nvn_vk_driver_cache.c android/native/nvn/nvn_vk_driver_cache.h android/native/direct/sha256.c android/native/direct/sha256.h graphics/nvn/gfx/nvn/nvn_fmt_expand.c graphics/nvn/gfx/nvn/nvn_backend.h graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_refl.h android/native/direct/vk_device.c android/native/direct/vk_device.h android/native/direct/gs_path.c android/native/direct/gs_path.h graphics/nvn/gfx/tex/nvn_bcdec.c graphics/nvn/gfx/nvn/include/* tests/vulkan/*
# 门禁本机：Linux 直接执行；macOS 用本机 colima 中已准备的公共 Vulkan 镜像（同 tests/shader_cases_test.sh），gate-host 不具备此环境
# 安卓 nvn_gpu_* Vulkan 后端契约（android/tests/vk/run.sh：lavapipe + Khronos validation 跑 C01–C08 + C23/C25–C27 + BC1–BC7 逐像素解码；本机约 40 秒）
# 11-01 接线：扫描分母按 tests 目录后查出原先没有门禁调它。环境没备好时 tests/vulkan/run.sh 退 75（环境未就绪），不在门禁里装环境。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
# 维护方：本机名单（tools/machine.local，不进仓库）配了 S2A_ANDROID_VK_REMOTE（如 air）→ 整步经私有 remote.sh 送那台跑，本机不起 colima 容器
#   （11-13：本机风扇，安卓的 Vulkan 契约用例改在专门的安卓专用 Mac上跑）。远端环境（PATH / NDK / docker 配置目录）由 S2A_ANDROID_VK_ENV 给，
#   配了 S2A_ANDROID_VK_LOCK 就和那台机上其他跑 run.sh 的人用同一把目录锁（mkdir 成功才跑、跑完删），没配不上锁。只在树是提交态时派（remote.sh 只收提交态），
#   已在远端里（S2A_REMOTE_NAME）不再派；没配 / 没有私有工具的（贡献者）照旧本机跑。远端每 60 秒打一行心跳：本机这头只是等 ssh，
#   门禁的无进展看门狗看日志 / CPU / 磁盘，安静 300 秒就判挂死（11-13 15:05 main 守望因此红）；等锁与跑用例都在这段心跳里（取代只在等锁时打心跳的写法）
. "$H/tools/machine.sh" 2> /dev/null || true
if [ -n "${S2A_ANDROID_VK_REMOTE:-}" ] && [ -z "${S2A_REMOTE_NAME:-}" ] && [ -f "${S2A_PRIVATE_TOOLS:-}/remote.sh" ] && [ -z "$(git -C "$H" status --porcelain 2> /dev/null)" ]; then
  cd "$H"
  # shellcheck disable=SC2086  # S2A_ANDROID_VK_ENV 是「K=V K=V」一串，按空格拆给 env
  exec env S2A_REMOTE_PRIO=2 bash "$S2A_PRIVATE_TOOLS/remote.sh" --host "$S2A_ANDROID_VK_REMOTE" --name gate-android-vk --rev HEAD --timeout 2700 -- \
    bash -c 'L=$1; shift; ( while sleep 60; do echo "安卓 Vulkan 用例在远端跑着 / 等锁（$(date +%T)）"; done ) & hb=$!; held=
      trap "kill $hb 2> /dev/null; [ -n \"\$held\" ] && rmdir \"$L\"" EXIT
      if [ -n "$L" ]; then for _ in $(seq 360); do mkdir "$L" 2> /dev/null && { held=1; break; }; sleep 5; done; [ -n "$held" ] || { echo "等不到安卓 Vulkan 用例锁 ${L}（30 分钟）"; exit 75; }; fi
      env "$@" bash tests/android_vk_test.sh' _ "${S2A_ANDROID_VK_LOCK:-}" ${S2A_ANDROID_VK_ENV:-}
fi
exec bash "$H/android/tests/vk/run.sh"
