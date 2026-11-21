#!/usr/bin/env bash
# 支持范围下限（物理设备 Vulkan 1.1+）的宿主单测：从 vk_device.c 摘出 physical_api_floor / fail 编进测试，
#   另核 s2a_vk_device_create 在取物理设备属性之后、建 VkDevice 之前调了它，以及外壳认原因用的英文短语与原生原因串一致。
#   三个负对照：下限放宽到 1.0、建设备里不调、外壳短语与原生串对不上，都必须红。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
src=$repo/android/native/direct/vk_device.c
java=$repo/android/app/src/main/java/org/s2arm/android/PlayerError.java
. "$repo/android/tools/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo 'NDK 29 missing' >&2; exit 2; }
tag=$(s2a_ndk_prebuilt_tag "$ndk") || exit 2
hdr="$ndk/toolchains/llvm/prebuilt/$tag/sysroot/usr/include"
[ -f "$hdr/vulkan/vulkan_core.h" ] || { echo 'NDK 29 Vulkan headers missing' >&2; exit 2; }
mkdir -p "$repo/build/vk-api-floor"
out=$(mktemp -d "$repo/build/vk-api-floor/run.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/ndk"; cp -R "$hdr/vulkan" "$hdr/vk_video" "$out/ndk/"
cp "$src" "$out/vk_device.c"; cp "$java" "$out/PlayerError.java"
extract() {   # $1 源文件 $2 函数名 → 追加到 snippet.inc
  python3 - "$1" "$2" "$out/snippet.inc" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); m = re.search(r'^(static )?int ' + sys.argv[2] + r'\(.*?\) \{\n', s, re.M)
if not m: sys.exit('摘不到 ' + sys.argv[2])
i = m.end(); depth = 1
while depth:
    c = s[i]; depth += (c == '{') - (c == '}'); i += 1
open(sys.argv[3], 'a').write(s[m.start():i] + '\n')
PY
}
contract() {   # 建设备调了下限检查；外壳认的两个短语都在原生原因串里
  python3 - "$out/vk_device.c" "$out/PlayerError.java" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); j = open(sys.argv[2]).read()
m = re.search(r'^int s2a_vk_device_create\(.*?^\}', s, re.M | re.S)
if not m: sys.exit('FAIL: s2a_vk_device_create not found')
body = m.group(0)
props = body.find('vkGetPhysicalDeviceProperties(out->physical, &out->properties);')
call = body.find('if (physical_api_floor(out->properties.apiVersion, why, why_size)) return -1;')
dev = body.find('vkCreateDevice(')
if props < 0 or call < 0 or dev < 0 or not props < call < dev:
    sys.exit('FAIL: device create does not check the physical apiVersion between properties and vkCreateDevice')
for name in ('VK_GPU_10', 'VK_LOADER_BELOW_11'):
    t = re.search(name + r'\s*=\s*"([^"]+)"', j)
    if not t: sys.exit('FAIL: PlayerError has no ' + name)
    if '"' + t.group(1) not in s: sys.exit('FAIL: PlayerError.' + name + ' "' + t.group(1) + '" is not a native reason prefix')
print('PASS: device create checks the floor; shell phrases match native reasons')
PY
}
build() { : > "$out/snippet.inc"; extract "$out/vk_device.c" fail; extract "$out/vk_device.c" physical_api_floor
  cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -I "$out/ndk" -I "$out" "$repo/android/tests/vk_api_floor_test.c" -o "$out/$1"; }
build test; "$out/test"; contract
neg() {   # $1 名字 $2 文件 $3 原文 $4 替换 $5 期望的 FAIL 文本
  cp "$out/$2" "$out/$2.orig"
  python3 - "$out/$2" "$3" "$4" <<'PY'
import sys; p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, a; open(p, 'w').write(s.replace(a, b))
PY
  if { build mutant && "$out/mutant" && contract; } > "$out/mutant.log" 2>&1; then echo "FAIL: negative control escaped ($1)" >&2; exit 1; fi
  grep -q "$5" "$out/mutant.log" || { cat "$out/mutant.log" >&2; exit 1; }
  echo "PASS: negative control detects $1"
  mv "$out/$2.orig" "$out/$2"
}
neg '下限放宽到 1.0' vk_device.c 'if (api >= VK_API_VERSION_1_1) return 0;' 'if (api >= VK_API_VERSION_1_0) return 0;' 'FAIL: Vulkan 1.0.61 GPU rejected'
neg '建设备不查物理设备版本' vk_device.c '    if (physical_api_floor(out->properties.apiVersion, why, why_size)) return -1;
' '' 'FAIL: device create does not check'
neg '外壳短语与原生串不一致' PlayerError.java 'VK_GPU_10 = "GPU supports only Vulkan 1.0"' 'VK_GPU_10 = "GPU only supports Vulkan 1.0"' 'is not a native reason prefix'
