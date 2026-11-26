#!/usr/bin/env bash
# 门禁覆盖：android/tests/caps_shape/* android/tests/devprofiles/* android/tests/vk/profiles/devices/* android/native/direct/vk_device.c android/native/direct/vk_device.h android/native/direct/device_caps.c android/native/direct/dev_facts.c android/native/direct/dev_facts.h android/native/direct/dev_policy* android/native/direct/gs_path.c android/native/nvn/nvn_vk_format.c android/native/nvn/backend_vulkan.c tools/devprofile_lint.py
# 接线：android/test.sh 调本脚本（钩子 android/gate.sh，改 android/ 任一文件都会跑）
# 整台设备能力形态档（#1749：不读厂商号，只看能力）：依赖设备能力的宿主测试在每份设备档案（android/tests/devprofiles/*.json）下各跑一遍。
#   档的定义与来源见 shapes.py 文件头；假驱动 fake_vk.c 按 S2A_CAPS_SHAPE 选档回答，生产代码原样编进来。
#   每档：建设备 + 能力断言 + 设备事实落盘核对（vk_device_shape_test.c）；生成的设备档案和该档档案文件逐字段比（shapes.py compare）；
#   两台真机档再把本构建打出的 caps 和 devices/*.json 逐项比（shapes.py oracle）。
#   回读闭环：各档生成的档案原样当形态档再跑一遍，第二代必须与第一代逐字段相同（生成的档案能被本测试直接读）。
#   负对照：把能力判断改坏（只改临时副本），对应档必须红在预期原因上；漏抓就整步红。
# 新测试接入：在下面 SHAPE_TESTS 加一行「名字 命令…」，命令里用 ${S2A_CAPS_SHAPE} / ${S2A_CAPS_SHAPE_OUT}，退出码非 0 = 该档红。
# 宿主 cc 即可，不要 NDK / 设备 / Vulkan 库；本机约 10 秒。
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
fresh_src() {   # 被测源的临时副本（负对照只改副本）
  cp "$repo/android/native/direct/vk_device.c" "$repo/android/native/direct/gs_path.c" "$repo/android/native/direct/dev_facts.c" "$repo/android/native/direct/device_caps.c" "$out/src/"
  cp "$repo/android/native/direct/dev_policy.c" "$out/src/"
  extract "$repo/android/native/nvn/backend_vulkan.c" array_query_default "$out/src/array_query_default.inc"
}
fresh_src
# vk_device.c 的两个弱引用（平台表面扩展表 / 自定义驱动）本测试不提供，保持「没有」：macOS 链接器要显式放行弱的未定义符号
weak=()
[ "$(uname -s)" = Darwin ] && read -r -a weak <<< "$(python3 "$repo/tools/weak_link_decl.py" flags capshape)"   # 放行清单唯一来源：vk_device.c 里的「弱链接[capshape]」登记
build() {   # $1 输出名 [$2 假驱动头所在目录] [$3 用例源]：用 $out/src 里可能被改坏的副本
  "${CC:-cc}" ${weak[@]+"${weak[@]}"} -std=gnu11 -O1 -Wall -Wextra -Werror -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 -DS2A_DEV_FACTS_TEST=1 \
    -I "${2:-$out}" -I "$out/src" -I "$here" -I "$repo/android/native/direct" -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" \
    -I "$repo/android/tests/vkhost" -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
    -I "$repo/android/native" -I "$repo/android/native/capprobe" \
    "${3:-$here/vk_device_shape_test.c}" "$here/fake_vk.c" "$out/src/vk_device.c" "$out/src/gs_path.c" "$out/src/dev_facts.c" \
    "$out/src/dev_policy.c" \
    "$out/src/device_caps.c" "$repo/android/native/direct/sha256.c" "$repo/android/native/nvn/nvn_vk_format.c" -o "$out/$1"
}
build test

# 按档跑的宿主测试（名字 命令…）
SHAPE_TESTS=(
  'vk_device|mkdir -p "$S2A_CAPS_SHAPE_OUT.files" && S2A_TEST_FILES_DIR="$S2A_CAPS_SHAPE_OUT.files" S2A_CAPS_SHAPE=$S2A_CAPS_SHAPE "$out/test" "$S2A_CAPS_SHAPE_OUT" "$S2A_CAPS_SHAPE_OUT.profile.json" 2>"$S2A_CAPS_SHAPE_OUT.log"'
  'policy_summary|count=$(grep -c "【策略】v1" "$S2A_CAPS_SHAPE_OUT.log" || true); if [ "$count" != 1 ]; then echo "FAIL: [$S2A_CAPS_SHAPE] 策略启动摘要：期望 1 条 → 实测 $count 条"; exit 1; fi'
  'device_profile|"${PY:-python3}" "$here/shapes.py" compare "$S2A_CAPS_SHAPE" "$S2A_CAPS_SHAPE_OUT.profile.json"'
  'real_device_oracle|case $S2A_CAPS_SHAPE in adreno-8xx-qcom|mali-g710-r32p1) "${PY:-python3}" "$here/shapes.py" oracle "$S2A_CAPS_SHAPE" "$S2A_CAPS_SHAPE_OUT";; *) echo "PASS: [$S2A_CAPS_SHAPE] 没有真机 caps 读数（合成档），不比";; esac'
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
awk '/【事实】/ { print "  摘要样例：" $0; exit }' "$out"/caps-*.json.log   # 不用 grep | head：pipefail 下 head 先退，grep 吃 SIGPIPE 整步退 141（Linux 上必现）

"${PY:-python3}" "$here/shapes.py" policy-header "$out/policy_archives_gen.h"
build policy "$out" "$here/t_dev_policy.c"
for shape in adreno-8xx-qcom mali-g710-r32p1 minimal-1.1 lavapipe; do
  S2A_CAPS_SHAPE=$shape "$out/policy" > "$out/$shape.policy" 2> "$out/$shape.policy.log" \
    || { cat "$out/$shape.policy.log"; exit 1; }
  diff -u "$repo/android/tests/devprofiles/$shape.policy.golden" "$out/$shape.policy"
  grep '策略 L0' "$out/$shape.policy.log"
done

neg_policy() {
  fresh_src
  "${PY:-python3}" - "$out/src/dev_policy.c" "$2" "$3" <<'PY'
import sys
from pathlib import Path
path, before, after = Path(sys.argv[1]), *sys.argv[2:]
source = path.read_text(encoding='utf-8')
assert source.count(before) == 1, before
path.write_text(source.replace(before, after), encoding='utf-8')
PY
  build policy-neg "$out" "$here/t_dev_policy.c"
  if S2A_CAPS_SHAPE=$4 "$out/policy-neg" > "$out/policy-neg.log" 2>&1; then
    echo "FAIL: 策略负对照 $1 漏抓"; exit 1
  fi
  echo '【负对照开始】'; neg_hit=0; grep -F "$5" "$out/policy-neg.log" || neg_hit=$?; echo '【负对照结束】'   # 反证按设计红出的 FAIL 不进门禁红步摘要（11-23）
  if [ "$neg_hit" != 0 ]; then
    echo "FAIL: 策略负对照 $1 红因不符"; cat "$out/policy-neg.log"; exit 1
  fi
  echo "PASS: 策略负对照 $1 红在 $5"
}
neg_policy '缺扩展仍开格式列表' \
  'item[S2A_POLICY_TEX_FMT_LIST] = queried_extension(facts, VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME);' \
  'item[S2A_POLICY_TEX_FMT_LIST] = queried(1, VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME);' \
  minimal-1.1 'tex.fmt_list 与现状选择不同'
neg_policy '枚举失败当成未列出' 'if (facts->ext_state != 1) return -1;' 'if (facts->ext_state != 1) return 0;' \
  adreno-8xx-qcom 'tex.fmt_list 枚举失败须保留未证'
neg_policy '按厂商号改变选择' \
  'item[S2A_POLICY_TEX_FMT_LIST] = queried_extension(facts, VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME);' \
  'item[S2A_POLICY_TEX_FMT_LIST] = facts->props.vendorID == UINT32_MAX ? queried(0, "identity") : queried_extension(facts, VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME);' \
  adreno-8xx-qcom 'tex.fmt_list 不读身份字段'
fresh_src

# 回读闭环：各档生成的档案原样放进一个新的档案目录当形态档，再建设备、再生成，第二代与第一代逐字段比（期望 = 第一代文件本身）
mkdir -p "$out/rt/profiles"
for shape in $shapes; do cp "$out/caps-$shape.json.profile.json" "$out/rt/profiles/rt-$shape.json"; done
S2A_DEVPROFILES="$out/rt/profiles" "${PY:-python3}" "$here/shapes.py" header "$out/rt/caps_shapes_gen.h"
build test-rt "$out/rt"
for shape in $shapes; do
  mkdir -p "$out/rt/files-$shape"
  S2A_TEST_FILES_DIR="$out/rt/files-$shape" S2A_CAPS_SHAPE=rt-$shape "$out/test-rt" "$out/rt/caps-$shape.json" "$out/rt/gen2-$shape.json" > "$out/rt/$shape.out" 2>&1 \
    || { echo "【红】回读闭环：rt-$shape 建设备红"; cat "$out/rt/$shape.out"; exit 1; }
  S2A_DEVPROFILES="$out/rt/profiles" "${PY:-python3}" "$here/shapes.py" compare rt-$shape "$out/rt/gen2-$shape.json" \
    || { echo "【红】回读闭环：rt-$shape 第二代档案和第一代不同"; exit 1; }
done
echo "PASS: 回读闭环 $(echo $shapes | wc -w | tr -d ' ') 档：生成的设备档案直接当形态档读，第二代与第一代逐字段相同"
for shape in $shapes; do   # 摘要行每进程每代只打一次：测试里第二次调挂点不许再打
  c=$(grep -c "【事实】v1" "$out/caps-$shape.json.log" || true)
  [ "$c" = 1 ] || { echo "【红】$shape 档日志里【事实】行 $c 条（期望 1）"; exit 1; }
done
echo "PASS: 每档日志里【事实】行恰好 1 条（第二次建设备不刷屏）"

# 版本门槛变体：已转正扩展不列名时按设备版本记；1.0 设备不挂扩展查询链（测试里另核 Features2 / Properties2 调用 0 次）
"${PY:-python3}" "$here/shapes.py" variants "$out/var/profiles"
S2A_DEVPROFILES="$out/var/profiles" "${PY:-python3}" "$here/shapes.py" header "$out/var/caps_shapes_gen.h"
build test-var "$out/var"
for v in $(S2A_DEVPROFILES="$out/var/profiles" "${PY:-python3}" "$here/shapes.py" names); do
  mkdir -p "$out/var/files-$v"
  S2A_TEST_FILES_DIR="$out/var/files-$v" S2A_CAPS_SHAPE=$v "$out/test-var" "$out/var/caps-$v.json" "$out/var/gen-$v.json" > "$out/var/$v.out" 2>&1 \
    || { echo "【红】版本门槛变体 $v 建设备 / 断言红"; cat "$out/var/$v.out"; exit 1; }
  "${PY:-python3}" "$here/shapes.py" check-variant "$v" "$out/var/gen-$v.json"
done
# 变体负对照：改坏 dev_facts.c 副本、按变体档重编，指定变体必须红在指定字样上。$1 名字 $2 原文 $3 改成 $4 变体 $5 红因里必须有的字
neg_var() {
  "${PY:-python3}" - "$out/src/dev_facts.c" "$2" "$3" <<'PY'
import sys; p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, '负对照原文不唯一 / 找不到：' + a; open(p, 'w').write(s.replace(a, b))
PY
  build test-var-neg "$out/var"
  rm -rf "$out/var/files-neg"; mkdir -p "$out/var/files-neg"
  if S2A_TEST_FILES_DIR="$out/var/files-neg" S2A_CAPS_SHAPE=$4 "$out/test-var-neg" "$out/var/caps-neg.json" "$out/var/gen-neg.json" > "$out/var/neg.out" 2>&1; then
    echo "【红】变体负对照漏抓：$1 —— $4 照样绿"; cat "$out/var/neg.out"; exit 1
  fi
  grep -q "$5" "$out/var/neg.out" || { echo "【红】变体负对照红错了地方：$1 —— 红因里没有「$5」"; cat "$out/var/neg.out"; exit 1; }
  echo "PASS: 变体负对照 $1 → $4 红（$(grep -m1 FAIL "$out/var/neg.out")）"
  fresh_src
}
# 4444 特性结构没转正：1.3 设备没列 VK_EXT_4444_formats 也挂进链 = 规范不允许，假驱动判红
neg_var '1.3 没列 VK_EXT_4444_formats 也挂 4444 结构' 'if ((f->have_4444 = listed(f, "VK_EXT_4444_formats"))) LINK(chain, &f->f4444);' \
  'if ((f->have_4444 = listed(f, "VK_EXT_4444_formats") || f->props.apiVersion >= VK_API_VERSION_1_3)) LINK(chain, &f->f4444);' v-api13-noext '4444 特性结构'
# 应用只申请 1.1：按设备版本（而不是有效版本）判转正功能 → 1.3 设备上挂 1.2 的 timeline 结构、查 1.3 的 A4B4G4R4 格式，假驱动判红
neg_var '按设备版本判转正功能（不看应用申请的 1.1）' 'const uint32_t api = s2a_vk_effective_api(f->props.apiVersion);' 'const uint32_t api = f->props.apiVersion;' v-api13-noext '超出有效版本'
neg_var '1.0 也挂扩展查询链' 'f->have_core11 = f->props.apiVersion >= VK_API_VERSION_1_1;' 'f->have_core11 = 1;' v-api10 '1.0 设备现查仍调了 Features2'

# 负对照：$1 名字 $2 改哪份副本 $3 原文 $4 改成 $5 必须红的档（空格分隔） $6 红因里必须有的字
neg_n=0
neg() {
  "${PY:-python3}" - "$out/src/$2" "$3" "$4" <<'PY'
import sys; p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, '负对照原文不唯一 / 找不到：' + a; open(p, 'w').write(s.replace(a, b))
PY
  build mutant
  for shape in $5; do
    rm -rf "$out/mutant.files"; mkdir -p "$out/mutant.files"
    if S2A_TEST_FILES_DIR="$out/mutant.files" S2A_CAPS_SHAPE=$shape "$out/mutant" "$out/mutant.json" "$out/mutant.profile.json" > "$out/mutant.log" 2>&1; then
      echo "【红】负对照漏抓：$1 —— $shape 档照样绿"; cat "$out/mutant.log"; exit 1
    fi
    grep -q "$6" "$out/mutant.log" || { echo "【红】负对照红错了地方：$1 —— $shape 档的红因里没有「$6」"; cat "$out/mutant.log"; exit 1; }
    echo "PASS: 负对照 $1 → $shape 档红（$(grep -m1 FAIL "$out/mutant.log")）"
    neg_n=$((neg_n + 1))
  done
  fresh_src
}
neg '不看扩展就开格式列表' vk_device.c \
  'out->image_format_list_enabled = has_device_extension(out->physical, "VK_KHR_image_format_list");' \
  'out->image_format_list_enabled = 1;' minimal-1.1 'VK_KHR_image_format_list'
neg 'BC 原生采样位不查' vk_device.c \
  'if (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)' 'if (0)' adreno-8xx-qcom 'bc_native_mask'
neg '裁剪距离不看支持就开' vk_device.c \
  'enabled_features.shaderClipDistance = features.shaderClipDistance;' 'enabled_features.shaderClipDistance = VK_TRUE;' 'mali-g710-r32p1 minimal-1.1' 'shaderClipDistance'
neg '几何着色器只看判定不看能力' gs_path.c 'const char *why = "hw-missing";
    if (hw_geometry_shader) {' 'const char *why = "hw-missing";
    if (1) {' minimal-1.1 'geometryShader'
neg '数组层夹取缺省对谁都开' array_query_default.inc \
  'return g.dev->properties.vendorID == 0x19E5u && !strncmp(g.dev->driver_name, "Maleoon", 7);' 'return 1;' 'adreno-8xx-qcom mali-g710-r32p1 minimal-1.1' 'array_query_default'
neg '查询链不看扩展就挂 index_type_uint8' vk_device.c 'if (has_u8) { *tail = &index_u8;' 'if (has_u8 || 1) { *tail = &index_u8;' minimal-1.1 'index_type_uint8 特性结构'
neg '摘要改回读 scaling_max_freq' dev_facts.c 'cpufreq/cpuinfo_max_freq", sysfs_root(), i);' 'cpufreq/scaling_max_freq", sysfs_root(), i);' adreno-8xx-qcom 'scaling_max_freq 一变摘要就变'
neg '只留 1 代' dev_facts.c '        closedir(d);
        for (int i = 0; i < n_doomed; i++) {' '        closedir(d);
        if (keep[0] && n_doomed < 16) snprintf(doomed[n_doomed++], 32, "%s", keep);
        for (int i = 0; i < n_doomed; i++) {' adreno-8xx-qcom '被删了（应留最近 2 代）'
neg '摘要行不按代去重' dev_facts.c 'if (!digest[0] || strncmp(g_logged_digest, digest, 16)) {' 'if (1) {' adreno-8xx-qcom '第二次建设备又打了【事实】行'
# 后端在应用 1.1 下的两处入口：驱动属性（1.2 核心 / VK_KHR_driver_properties）、能力表里的 A4B4G4R4 格式（1.3 核心 / VK_EXT_4444_formats）
neg '驱动属性不看有效版本和扩展就查' vk_device.c 'if (s2a_vk_effective_api(out->properties.apiVersion) >= VK_API_VERSION_1_2 ||' 'if (1 || s2a_vk_effective_api(out->properties.apiVersion) >= VK_API_VERSION_1_2 ||' minimal-1.1 'driver properties'
neg '能力表不看 4444 启用就查 A4B4G4R4' device_caps.c 'js_bool(d->formats_4444_enabled && optimal_all(d, k_r4g4b4a4,' 'js_bool(optimal_all(d, k_r4g4b4a4,' minimal-1.1 'A4B4G4R4 格式查询'
echo "PASS: 负对照 11 种改法、$neg_n 档次全部按预期变红"

# 设备事实负对照：dev_facts.c 漏记一组扩展特性（只改副本）→ 生成的档案和档案文件逐字段比必须红在那一项上；
#   漏查一个格式 → 建设备时 vk_device.c 查到的格式不在事实里，比对红在该格式上
neg_profile() {   # $1 名字 $2 原文 $3 改成 $4 档 $5 红因里必须有的字
  "${PY:-python3}" - "$out/src/dev_facts.c" "$2" "$3" <<'PY'
import sys; p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, '负对照原文不唯一 / 找不到：' + a; open(p, 'w').write(s.replace(a, b))
PY
  build mutant
  rm -rf "$out/mutant.files"; mkdir -p "$out/mutant.files"
  S2A_TEST_FILES_DIR="$out/mutant.files" S2A_CAPS_SHAPE=$4 "$out/mutant" "$out/mutant.json" "$out/mutant.profile.json" > "$out/mutant.log" 2>&1 || true
  if "${PY:-python3}" "$here/shapes.py" compare "$4" "$out/mutant.profile.json" > "$out/mutant.cmp" 2>&1; then
    echo "【红】设备事实负对照漏抓：$1 —— $4 档比对照样绿"; cat "$out/mutant.cmp"; exit 1
  fi
  grep -q "$5" "$out/mutant.cmp" || { echo "【红】设备事实负对照红错了地方：$1 —— 比对红因里没有「$5」"; cat "$out/mutant.cmp"; exit 1; }
  echo "PASS: 设备事实负对照 $1 → $4 档比对红（$(grep -m1 "$5" "$out/mutant.cmp" | sed "s/^ *//")）"
  fresh_src
}
neg_profile '漏记时间线信号量特性' 'if ((f->have_timeline = listed(f, "VK_KHR_timeline_semaphore") || api >= VK_API_VERSION_1_2)) LINK(chain, &f->timeline);' \
  'f->have_timeline = 0;' adreno-8xx-qcom 'features.timelineSemaphore'
neg_profile '漏查 BC7 格式' 'if (k_formats[i].f == VK_FORMAT_A4B4G4R4_UNORM_PACK16 && !f->have_4444_fmt) continue;' \
  'if ((k_formats[i].f == VK_FORMAT_A4B4G4R4_UNORM_PACK16 && !f->have_4444_fmt) || k_formats[i].f == VK_FORMAT_BC7_UNORM_BLOCK) continue;' mali-g710-r32p1 'VK_FORMAT_BC7_UNORM_BLOCK'
echo "PASS: 设备事实负对照 2 种改法全部按预期变红"
