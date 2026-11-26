#!/usr/bin/env bash
# 安卓主机套件里只在 macOS 上能跑的三段（11-26：安卓整套 android/test.sh 改由 Linux 门禁机跑之后，这三段留给苹果门禁机）。
#   ① graphics/track 的 READFLUSH 精确回归（Darwin 分支；Linux 分支 tracking-precise / vm-mirror 在 android/test.sh 里）
#   ② APK 内存装载器（macOS ARM64 + 真实 Apple TSD 夹具）
#   ③ 纹理读回夹具的 macOS 变体（mac_vm_adapter.c 编 dylib；Linux 变体在 android/test.sh 里跑）
# 与 android/test.sh 同一套前置（输出目录、Python、门禁步骤函数）。非 macOS 宿主直接报错退出：这里的段在别处跑不了。
[ -n "${GATE2_PAR:-}" ] || renice 15 -p $$ > /dev/null 2>&1 || true
set -euo pipefail
android_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$android_dir/.." && pwd)
if [ "$(uname -s)" != Darwin ]; then echo '【红】android/test_darwin_only.sh 只在 macOS 上跑（其余段见 android/test.sh）' >&2; exit 2; fi
source "$repo_dir/tools/_timeout.sh"
source "$android_dir/tools/host_out.sh"
out=$(s2a_host_out) || { echo '【红】建不出主机测试输出目录（S2A_HOST_OUT_ROOT / TMPDIR 不可写）' >&2; exit 1; }
trap 'rm -rf "$out"' EXIT
if [ "${S2A_PY+x}" ]; then
    PY=$S2A_PY
elif [ ! "${PY+x}" ]; then
    PY="$HOME/.s2arm/venv/bin/python3"
fi
export PY S2A_PY="$PY"
source "$android_dir/tools/gate_step.sh"
s2a_gate_step bash "$repo_dir/graphics/track/tests/drain_readflush/build_run.sh" "$out/drain-readflush"
s2a_gate_step "$PY" "$android_dir/core-link/runtime-tests/apk-loader/run.py" --out "$out/apk-loader"
s2a_gate_step "$PY" "$android_dir/core-link/runtime-tests/readonly-copy/texture_read_test.py"
