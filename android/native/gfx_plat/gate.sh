#!/usr/bin/env bash
# 门禁路由：android/ graphics/nvn/replay/ graphics/nvn/gfx/nvn/nvn_backend.h graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn2_cmd.h docs/直连_Vulkan回放接线表.tsv
# 门禁本机：* 交叉链接要 CMake + ninja + NDK 29.0.14206865；门禁机没有 CMake
# 安卓新图形层（docs/设计_Vulkan回放层重搭.md）的门禁钩子。两步：先核资源文件没有重复的键（见下），再是
#   新层取值（S2ARM_ANDROID_VK_BACKEND=nvk）用 NDK 交叉编译并链接出 libs2arm_android.so（诊断模式：不要 C# 服务层与编解码库；
#   链接不许有未定义符号），再核构建清单里旧回放与绘制源 0 个。证明：新层的源在安卓上能编能链，旧层没被带回来。
# 11-11 本机实测 2 秒（111 个目标文件，不走编译缓存）。
# 不在这里的（都已经有自己的入口，不重复）：
#   · 回放核心单测 native-test-nvn_replay、契约签名表 native-test-nvn_backend：通用原生单测集，按改动路由跑；
#   · nvn_gpu_* Vulkan 后端契约用例（lavapipe + 校验层）：单测 tests/android_vk_test.sh，按它文件头的「门禁只看」跑；
#   · 模拟机型档 android/tests/vk/sim_tiers.sh 只能在 Linux 跑：.github/workflows/android-vk.yml；
#   · 游戏模式的整包（C# 服务层静态链接 + APK）与真机：不在门禁里，由安卓线的真机回路证。
set -euo pipefail
cd "$(cd "$(dirname "$0")/../../.." && pwd)"   # 仓库根

# 资源文件里不许有重复的键：两支各加了同样的字符串、分别都能合进来，合在一起整包构建当场失败
# （11-11：values-zh 里 4 条重复，main 上编不出 APK；整包构建不在门禁里，这一条是它最便宜的那一刀）。
dup=$(python3 - <<'PY'
import re, glob, collections
for f in sorted(glob.glob('android/app/src/main/res/values*/*.xml')):
    c = collections.Counter(re.findall(r'<(?:string|plurals|string-array|color|dimen|bool|integer|style) name="([^"]+)"', open(f, encoding='utf-8').read()))
    d = [k for k, v in c.items() if v > 1]
    if d: print(f + '：' + '、'.join(d))
PY
)
[ -z "$dup" ] || { echo "$dup"; echo "【红】安卓门禁：资源文件里有重复的键（见上），整包构建会失败"; exit 1; }

# 旧回放与绘制源：新层取值的构建清单里一个都不许有（android/core-link/LinkSources.cmake 的 nvk 清单同一条规矩）
OLD_SOURCES='mtl_vk_shim|mtl_vk_adapter|vk_record|nvn_vk_first_draw|nvn_vk_texcache|nvn_be_android|vk_nvn_adapter|provider_vk\.c'

ndk=
# 钉版目录优先，环境变量兜底：托管 macOS 镜像把 ANDROID_NDK_HOME 设成自带的旧 NDK（27.x），
# 先认它就编不过 android/CMakeLists.txt 里 NDK 29 才认的告警选项，钉版那份装了也用不上。
for d in "${ANDROID_HOME:-}/ndk/29.0.14206865" "${ANDROID_SDK_ROOT:-}/ndk/29.0.14206865" \
         "$HOME/Library/Android/sdk/ndk/29.0.14206865" "$HOME/Android/Sdk/ndk/29.0.14206865" "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
  if [ -n "$d" ] && [ -f "$d/build/cmake/android.toolchain.cmake" ]; then ndk=$d; break; fi
done
[ -n "$ndk" ] || { echo "【红】安卓门禁：找不到 NDK 29.0.14206865（ANDROID_NDK_HOME / ANDROID_HOME/ndk / ~/Library/Android/sdk/ndk）；不跳过"; exit 1; }
source android/tools/cmake_pick.sh
s2a_cmake_pick || exit 1
cm=$S2A_CMAKE
command -v ninja > /dev/null 2>&1 || PATH=${cm%/*}:$PATH   # SDK 的 CMake 目录里带 ninja
command -v ninja > /dev/null 2>&1 || { echo "【红】安卓门禁：找不到 ninja（PATH 与 ${cm%/*} 都没有）；不跳过"; exit 1; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-android-nvk-link.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
"$cm" -S android -B "$out" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DCMAKE_BUILD_TYPE=Debug \
      -DS2A_ANDROID_NATIVE_MODE=diagnostic -DS2A_ANDROID_VK_ENGINE=ON -DS2ARM_ANDROID_VK_BACKEND=nvk > "$out/configure.log" 2>&1 \
  || { tail -20 "$out/configure.log"; echo "【红】安卓门禁：新层取值的 CMake 配置失败"; exit 1; }
"$cm" --build "$out" --target s2arm_android > "$out/build.log" 2>&1 \
  || { grep -E 'error|undefined symbol|FAILED' "$out/build.log" | head -20; echo "【红】安卓门禁：新层取值编译或链接失败（未定义符号见上）"; exit 1; }
[ -s "$out/libs2arm_android.so" ] || { echo "【红】安卓门禁：构建报成功但没有 libs2arm_android.so"; exit 1; }
objs=$(ninja -C "$out" -t targets all | grep -c '\.o: ' || true)
old=$(ninja -C "$out" -t targets all | grep '\.o: ' | grep -E "$OLD_SOURCES" || true)
[ "$objs" -ge 50 ] || { echo "【红】安卓门禁：构建清单只有 ${objs} 个目标文件，清单没读对（期望 ≥50）"; exit 1; }
if [ -n "$old" ]; then echo "$old" | head -10; echo "【红】安卓门禁：新层取值的构建里出现旧回放 / 绘制源（见上）"; exit 1; fi
echo "安卓新图形层交叉链接（nvk，诊断模式）：期望 链接成功、旧回放与绘制源 0 个 → 真结果 链接成功（目标文件 ${objs} 个）、旧源 0 个"
