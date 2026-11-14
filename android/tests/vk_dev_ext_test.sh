#!/usr/bin/env bash
# 设备 / 实例扩展查询的宿主单测：从 vk_device.c（缺省本仓的；可传别的路径做修前对照）摘出 extension_state 编进替身。
#   摘不到 extension_state 时（修前的代码只有 has_device_extension / has_instance_extension）按修前语义包一层：回 0 / 1，没有「未知」。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
src=${1:-$repo/android/native/direct/vk_device.c}
. "$repo/android/tools/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo 'NDK 29 missing' >&2; exit 2; }
tag=$(s2a_ndk_prebuilt_tag "$ndk") || exit 2
hdr="$ndk/toolchains/llvm/prebuilt/$tag/sysroot/usr/include"
[ -f "$hdr/vulkan/vulkan_core.h" ] || { echo 'NDK 29 Vulkan headers missing' >&2; exit 2; }
mkdir -p "$repo/build/vk-dev-ext"
out=$(mktemp -d "$repo/build/vk-dev-ext/run.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/ndk"; cp -R "$hdr/vulkan" "$hdr/vk_video" "$out/ndk/"
extract() {   # $1 源文件 $2 函数名 $3 输出 → 0 摘到
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); m = re.search(r'^static int ' + sys.argv[2] + r'\(.*?\) \{\n', s, re.M)
if not m: sys.exit(1)
i = m.end(); depth = 1
while depth:
    c = s[i]; depth += (c == '{') - (c == '}'); i += 1
open(sys.argv[3], 'w').write(s[m.start():i] + '\n')
PY
}
if ! extract "$src" extension_state "$out/snippet.inc"; then
  extract "$src" has_instance_extension "$out/snippet.inc" || { echo '摘不到 has_instance_extension' >&2; exit 2; }
  extract "$src" has_device_extension "$out/snippet.b" || { echo '摘不到 has_device_extension' >&2; exit 2; }
  cat "$out/snippet.b" >> "$out/snippet.inc"
  printf 'static int extension_state(VkPhysicalDevice p, const char *name, char *why, size_t n) { (void)why; (void)n; return p ? has_device_extension(p, name) : has_instance_extension(name); }\n' >> "$out/snippet.inc"
fi
build() { cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -I "$out/ndk" -I "$out" "$repo/android/tests/vk_dev_ext_test.c" -o "$out/$1"; }
build test
"$out/test"
[ "${1:-}" ] && exit 0   # 给了别的源文件：只跑那一份（修前对照），不做负控
neg() {   # $1 名字 $2 原文 $3 替换 $4 期望的 FAIL 文本
  python3 - "$out/snippet.inc" "$2" "$3" <<'PY'
import sys; p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, a; open(p, 'w').write(s.replace(a, b))
PY
  build mutant
  if "$out/mutant" > "$out/mutant.log" 2>&1; then echo "FAIL: negative control escaped ($1)" >&2; exit 1; fi
  grep -q "$4" "$out/mutant.log" || { cat "$out/mutant.log" >&2; exit 1; }
  echo "PASS: negative control detects $1"
  extract "$src" extension_state "$out/snippet.inc"
}
neg '第二次取数结果不检查' 'if (r != VK_SUCCESS || got > count) {' 'if (0) {' 'FAIL: second enumeration fails'
neg 'VK_INCOMPLETE 不重取' 'if (r == VK_INCOMPLETE) { free(ext); continue; }' '' 'FAIL: list grows between calls'
neg '实例查询走设备枚举' 'VkResult r = physical ? vkEnumerateDeviceExtensionProperties(physical, NULL, &count, NULL) : vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);' 'VkResult r = vkEnumerateDeviceExtensionProperties(physical, NULL, &count, NULL);' 'FAIL: instance query used the wrong enumerator'
neg '分配失败当不支持' 'if (!ext) { snprintf(why, why_n, "分配 %u 项失败（第 %d 轮）", count, round); return -1; }' 'if (!ext) return 0;' 'FAIL: allocation fails'
