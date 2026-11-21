#!/usr/bin/env bash
# 门禁覆盖：android/tests/caps_shape/* android/tests/vk/profiles/devices/* android/native/direct/vk_device.c android/native/direct/vk_device.h android/native/direct/device_caps.c android/native/direct/gs_path.c android/native/nvn/nvn_vk_format.c android/native/nvn/backend_vulkan.c
# 接线：android/test.sh 调本脚本（钩子 android/gate.sh，改 android/ 任一文件都会跑）
# 整台设备能力形态档（#1749：不读厂商号，只看能力）：依赖设备能力的宿主测试在 Adreno / Mali / 保守三档下各跑一遍。
#   档的定义与来源见 shapes.py 文件头；假驱动 fake_vk.c 按 S2A_CAPS_SHAPE 选档回答，生产代码原样编进来。
#   每档：建设备 + 能力断言（vk_device_shape_test.c）；两台真机档再把本构建打出的 caps 和 devices/*.json 逐项比（shapes.py oracle）。
#   负对照：把能力判断改坏（只改临时副本），对应档必须红在预期原因上；漏抓就整步红。
# 新测试接入：在下面 SHAPE_TESTS 加一行「名字 命令…」，命令里用 ${S2A_CAPS_SHAPE} / ${S2A_CAPS_SHAPE_OUT}，退出码非 0 = 该档红。
# 宿主 cc 即可，不要 NDK / 设备 / Vulkan 库；本机约 5 秒。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
here="$repo/android/tests/caps_shape"
mkdir -p "$repo/build/caps-shape"
out=$(mktemp -d "$repo/build/caps-shape/run.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
"${PY:-python3}" "$here/shapes.py" header "$out/caps_shapes_gen.h"
shapes=$("${PY:-python3}" "$here/shapes.py" names)

extract() {   # $1 源文件 $2 函数名 $3 输出：原样摘出「static int 名(void) { … }」
  "${PY:-python3}" - "$1" "$2" "$3" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); m = re.search(r'^static int ' + sys.argv[2] + r'\(void\) \{\n', s, re.M)
if not m: sys.exit('摘不到 %s（%s）' % (sys.argv[2], sys.argv[1]))
i = m.end(); depth = 1
while depth:
    depth += (s[i] == '{') - (s[i] == '}'); i += 1
open(sys.argv[3], 'w').write(s[m.start():i] + '\n')
PY
}
mkdir -p "$out/src"
cp "$repo/android/native/direct/vk_device.c" "$repo/android/native/direct/gs_path.c" "$out/src/"
extract "$repo/android/native/nvn/backend_vulkan.c" array_query_default "$out/src/array_query_default.inc"
# vk_device.c 的两个弱引用（平台表面扩展表 / 自定义驱动）本测试不提供，保持「没有」：macOS 链接器要显式放行弱的未定义符号
weak=()
[ "$(uname -s)" = Darwin ] && read -r -a weak <<< "$(python3 "$repo/tools/weak_link_decl.py" flags capshape)"   # 放行清单唯一来源：vk_device.c 里的「弱链接[capshape]」登记
build() {   # $1 输出名：用 $out/src 里的（可能被改坏的）副本
  "${CC:-cc}" ${weak[@]+"${weak[@]}"} -std=gnu11 -O1 -Wall -Wextra -Werror -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 \
    -I "$out" -I "$out/src" -I "$here" -I "$repo/android/native/direct" -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" \
    -I "$repo/android/tests/vkhost" -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
    -I "$repo/android/native" -I "$repo/android/native/capprobe" \
    "$here/vk_device_shape_test.c" "$here/fake_vk.c" "$out/src/vk_device.c" "$out/src/gs_path.c" \
    "$repo/android/native/direct/device_caps.c" "$repo/android/native/nvn/nvn_vk_format.c" -o "$out/$1"
}
build test

# 按档跑的宿主测试（名字 命令…）
SHAPE_TESTS=(
  'vk_device|S2A_CAPS_SHAPE=$S2A_CAPS_SHAPE "$out/test" "$S2A_CAPS_SHAPE_OUT" 2>"$S2A_CAPS_SHAPE_OUT.log"'
  'real_device_oracle|case $S2A_CAPS_SHAPE in adreno|mali) "${PY:-python3}" "$here/shapes.py" oracle "$S2A_CAPS_SHAPE" "$S2A_CAPS_SHAPE_OUT";; *) echo "PASS: [$S2A_CAPS_SHAPE] 没有真机档（派生档），不比";; esac'
)
rc=0; n=0
for shape in $shapes; do
  for t in "${SHAPE_TESTS[@]}"; do
    name=${t%%|*}; cmd=${t#*|}; n=$((n + 1))
    if ! S2A_CAPS_SHAPE=$shape S2A_CAPS_SHAPE_OUT="$out/caps-$shape.json" out=$out here=$here bash -c "$cmd"; then
      echo "FAIL: 形态档 $shape 下 $name 红"; rc=1
    fi
  done
done
[ $rc = 0 ] || { echo "【红】整台设备能力形态档：有档红（上面 FAIL 行）"; exit 1; }
echo "PASS: 形态档 $(echo $shapes | wc -w | tr -d ' ') 档 × ${#SHAPE_TESTS[@]} 项 = $n 次全绿（${shapes}）"

# 负对照：$1 名字 $2 改哪份副本 $3 原文 $4 改成 $5 必须红的档（空格分隔） $6 红因里必须有的字
neg_n=0
neg() {
  "${PY:-python3}" - "$out/src/$2" "$3" "$4" <<'PY'
import sys; p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, '负对照原文不唯一 / 找不到：' + a; open(p, 'w').write(s.replace(a, b))
PY
  build mutant
  for shape in $5; do
    if S2A_CAPS_SHAPE=$shape "$out/mutant" "$out/mutant.json" > "$out/mutant.log" 2>&1; then
      echo "【红】负对照漏抓：$1 —— $shape 档照样绿"; cat "$out/mutant.log"; exit 1
    fi
    grep -q "$6" "$out/mutant.log" || { echo "【红】负对照红错了地方：$1 —— $shape 档的红因里没有「$6」"; cat "$out/mutant.log"; exit 1; }
    echo "PASS: 负对照 $1 → $shape 档红（$(grep -m1 FAIL "$out/mutant.log")）"
    neg_n=$((neg_n + 1))
  done
  cp "$repo/android/native/direct/vk_device.c" "$repo/android/native/direct/gs_path.c" "$out/src/"
  extract "$repo/android/native/nvn/backend_vulkan.c" array_query_default "$out/src/array_query_default.inc"
}
neg '不看扩展就开格式列表' vk_device.c \
  'out->image_format_list_enabled = has_device_extension(out->physical, "VK_KHR_image_format_list");' \
  'out->image_format_list_enabled = 1;' conservative 'VK_KHR_image_format_list'
neg 'BC 原生采样位不查' vk_device.c \
  'if (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)' 'if (0)' adreno 'bc_native_mask'
neg '裁剪距离不看支持就开' vk_device.c \
  'enabled_features.shaderClipDistance = features.shaderClipDistance;' 'enabled_features.shaderClipDistance = VK_TRUE;' 'mali conservative' 'shaderClipDistance'
neg '几何着色器只看判定不看能力' gs_path.c 'const char *why = "hw-missing";
    if (hw_geometry_shader) {' 'const char *why = "hw-missing";
    if (1) {' conservative 'geometryShader'
neg '数组层夹取缺省对谁都开' array_query_default.inc \
  'return g.dev->properties.vendorID == 0x19E5u && !strncmp(g.dev->driver_name, "Maleoon", 7);' 'return 1;' 'adreno mali conservative' 'array_query_default'
echo "PASS: 负对照 6 种改法、$neg_n 档次全部按预期变红"
