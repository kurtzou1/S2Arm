#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$repo/android/tools/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo 'NDK 29 missing' >&2; exit 2; }
grep -q '^Pkg.Revision = 29\.0\.14206865$' "$ndk/source.properties" || { echo 'NDK 29.0.14206865 required' >&2; exit 2; }
tag=$(s2a_ndk_prebuilt_tag "$ndk") || exit 2
hdr="$ndk/toolchains/llvm/prebuilt/$tag/sysroot/usr/include"
[ -f "$hdr/vulkan/vulkan_core.h" ] || { echo 'NDK 29 Vulkan headers missing' >&2; exit 2; }
mkdir -p "$repo/build/c883-unit"
out=$(mktemp -d "$repo/build/c883-unit/run.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/ndk"
cp -R "$hdr/vulkan" "$out/ndk/"
cp -R "$hdr/vk_video" "$out/ndk/"
cc -std=c11 -Wall -Wextra -Werror -I "$out/ndk" -I "$repo/android/native/nvn" "$repo/android/tests/nvk_shown_timing_test.c" -o "$out/test"
"$out/test"
# Negative control: discard the first partial response, exactly the bug under test.
python3 - "$repo/android/native/nvn/backend_vulkan_timing.h" "$out/backend_vulkan_timing.h" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
a = 'for (uint32_t i = 0; i < n; i++) {'
b = 'for (uint32_t i = (r == VK_INCOMPLETE ? n : 0); i < n; i++) {'
assert s.count(a) == 1
pathlib.Path(sys.argv[2]).write_text(s.replace(a, b))
PY
cc -std=c11 -Wall -Wextra -Werror -I "$out/ndk" -I "$out" "$repo/android/tests/nvk_shown_timing_test.c" -o "$out/mutant"
if "$out/mutant" > "$out/mutant.log" 2>&1; then echo 'FAIL: negative control escaped' >&2; exit 1; fi
if ! grep -q 'FAIL: VK_INCOMPLETE consumes partial records exactly once before next batch' "$out/mutant.log"; then cat "$out/mutant.log" >&2; exit 1; fi
echo 'PASS: negative control detects discarded VK_INCOMPLETE records'
# Negative controls for the over-100 ms count: threshold off by one (>=), and counting over all submitted frames instead of returned samples.
mut() {   # $1 name, $2 from, $3 to, $4 expected FAIL text
  python3 - "$repo/android/native/nvn/backend_vulkan_timing.h" "$out/backend_vulkan_timing.h" "$2" "$3" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text(); a, b = sys.argv[3], sys.argv[4]
assert s.count(a) == 1, a
pathlib.Path(sys.argv[2]).write_text(s.replace(a, b))
PY
  cc -std=c11 -Wall -Wextra -Werror -I "$out/ndk" -I "$out" "$repo/android/tests/nvk_shown_timing_test.c" -o "$out/mutant"
  if "$out/mutant" > "$out/mutant.log" 2>&1; then echo "FAIL: negative control escaped ($1)" >&2; exit 1; fi
  if ! grep -q "$4" "$out/mutant.log"; then cat "$out/mutant.log" >&2; exit 1; fi
  echo "PASS: negative control detects $1"
}
mut 'threshold >= 100 ms' 'over += gaps[i] > 100000000ull;' 'over += gaps[i] >= 100000000ull;' 'FAIL: two gaps strictly over 100 ms'
mut 'missing field when empty' '间隔最大= 间隔>100ms=；原因=%s' '间隔最大=；原因=%s' 'FAIL: disabled log has an empty over-100ms field'
