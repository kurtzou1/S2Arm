#!/usr/bin/env bash
# 门禁只看：runtime/src/* runtime/include/* platform/* graphics/track/* android/native/runtime/* android/native/capprobe/* android/native/*.h android/native/fps_provider.c android/core-link/*.cmake android/CMakeLists.txt android/tools/ndk_toolchain.sh android/tools/versions.sh android/docker/Dockerfile
# 安卓游戏目标的 runtime 源只编不跑（配置约 2 秒、本机 18 核并行编约 2 秒）：bash tests/android_runtime_build_test.sh
# 起因（11-12）：一笔只改 runtime/src/pack_apply.c 的提交在安卓构建里 -Werror=unused-function 编不过（iOS 专用函数没进平台条件），
#   合入前层没拦住——改 runtime/src 的支不路由到任何安卓原生编译，合进 main 后安卓出包才红。
# 做法：用固定版本的 NDK（android/tools/versions.sh 从 android/docker/Dockerfile 读）与固定版本的 CMake 按出包同一组开关
#   （pack/targets/android/package.py：game 模式、正式构建、VK 引擎 nvn_vk、静态服务层）配置 android/CMakeLists.txt，
#   编译参数一律取 CMake 导出的 compile_commands.json，不在这里另抄一份；源文件清单由 CMake 现算
#   android/core-link/Runtime.cmake 的 s2a_android_game_sources，逐个 -c 编一遍（不链接：静态服务层归档 / 编解码库不在合入前层）。
#   静态服务层用 S2A_ANDROID_LINK_PROBE 代替（CMakeLists 里与 static 分支给 game 源同一组宏 S2A_CS_STATIC=1）。
# 退出：0 全过；1 有文件编不过（打出报错）；75 环境未就绪（缺 NDK / CMake，已登记 tools/contrib_tools.tsv「Android NDK」）。
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P); cd "$R"
. android/tools/ndk_toolchain.sh
t0=$(date +%s)

NDK=$(s2a_ndk_resolve) || {
  echo "android_runtime_build：没找到 Android NDK ${S2A_ANDROID_NDK}（ANDROID_NDK_HOME / ANDROID_NDK / ANDROID_NDK_ROOT 都没设，"
  echo "  SDK 下的 ndk/${S2A_ANDROID_NDK} 也找不到，查找顺序见 android/tools/ndk_toolchain.sh 的 s2a_ndk_resolve），没跑（环境未就绪）"
  echo "  装法：$(s2a_sdkmanager_hint)"; exit 75; }
TC=$NDK/build/cmake/android.toolchain.cmake
CC=$(s2a_ndk_clang "$NDK" 29 2> /dev/null) || CC=
if [ ! -f "$TC" ] || [ -z "$CC" ] || [ ! -x "$CC" ]; then
  echo "android_runtime_build：NDK ${NDK} 不完整（缺 build/cmake/android.toolchain.cmake 或 aarch64 clang），没跑（环境未就绪）"; exit 75
fi
# CMake：优先 SDK 里的固定版本（与 NDK 同一个 SDK 根，或 ANDROID_HOME / ANDROID_SDK_ROOT），其次 PATH 上的 cmake + ninja
CMAKE= NINJA=
for d in "$NDK/../../cmake/$S2A_ANDROID_CMAKE/bin" "${ANDROID_HOME:-/nonexistent}/cmake/$S2A_ANDROID_CMAKE/bin" \
         "${ANDROID_SDK_ROOT:-/nonexistent}/cmake/$S2A_ANDROID_CMAKE/bin"; do
  [ -x "$d/cmake" ] && [ -x "$d/ninja" ] && { CMAKE=$d/cmake; NINJA=$d/ninja; break; }
done
if [ -z "$CMAKE" ]; then CMAKE=$(command -v cmake || true); NINJA=$(command -v ninja || true); fi
if [ -z "$CMAKE" ] || [ -z "$NINJA" ]; then
  echo "android_runtime_build：没找到 CMake ${S2A_ANDROID_CMAKE} + ninja（SDK 的 cmake/${S2A_ANDROID_CMAKE}/bin 或 PATH），没跑（环境未就绪）"
  echo "  装法：$(s2a_sdkmanager_hint)"; exit 75
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 源文件清单：CMake 自己求值 Runtime.cmake 的函数，一行一个
cat > "$T/list.cmake" << EOF
include("$R/android/core-link/Runtime.cmake")
s2a_android_game_sources(srcs)
list(JOIN srcs "\n" out)
file(WRITE "$T/sources.txt" "\${out}\n")
EOF
"$CMAKE" -P "$T/list.cmake"
# 链接探针源只占 S2A_ANDROID_LINK_PROBE 的位（配置不读内容、这里也不编它）
: > "$T/link_probe.c"
if ! "$CMAKE" -S android -B "$T/b" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_TOOLCHAIN_FILE="$TC" \
     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
     -DS2A_ANDROID_NATIVE_MODE=game -DS2A_ANDROID_VK_ENGINE=ON -DS2ARM_ANDROID_VK_BACKEND=nvn_vk \
     -DS2A_ANDROID_LINK_PROBE="$T/link_probe.c" > "$T/configure.log" 2>&1; then
  cat "$T/configure.log"; echo "android_runtime_build：CMake 配置 android/CMakeLists.txt 失败（见上）"; exit 1
fi

python3 - "$T/b/compile_commands.json" "$T/sources.txt" "$T/obj" "$(s2a_jobs)" "$R" << 'PY'
import concurrent.futures as cf, json, os, shlex, subprocess, sys
db, listing, objdir, jobs, root = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
srcs = [os.path.realpath(l) for l in open(listing).read().split('\n') if l.strip()]
cmds = {}
for e in json.load(open(db)):
    cmds[os.path.realpath(os.path.join(e['directory'], e['file']))] = e
missing = [s for s in srcs if s not in cmds]
if not srcs or missing:
    print('android_runtime_build：Runtime.cmake 列的源在 s2arm_android 的编译命令里找不到：'
          + ' '.join(os.path.relpath(s, root) for s in missing) if missing else 'android_runtime_build：Runtime.cmake 清单为空')
    sys.exit(1)
os.makedirs(objdir, exist_ok=True)

def build(i_src):
    i, src = i_src
    e = cmds[src]
    argv = e['arguments'] if 'arguments' in e else shlex.split(e['command'])
    k = argv.index('-o')
    argv = argv[:k + 1] + [os.path.join(objdir, f'{i}.o')] + argv[k + 2:]
    p = subprocess.run(argv, cwd=e['directory'], capture_output=True, text=True)
    return src, p.returncode, p.stdout + p.stderr

bad = []
with cf.ThreadPoolExecutor(max(1, jobs)) as ex:
    for src, rc, out in ex.map(build, enumerate(srcs)):
        if rc:
            bad.append(src)
            print(f'── 编不过：{os.path.relpath(src, root)}\n{out.rstrip()}')
if bad:
    print(f'android_runtime_build：{len(bad)}/{len(srcs)} 个文件编不过：' + ' '.join(os.path.relpath(s, root) for s in bad))
    sys.exit(1)
print(f'{len(srcs)}', file=open(os.path.join(objdir, 'count'), 'w'))
PY
echo "android_runtime_build 单测全过：$(cat "$T/obj/count") 个文件（Runtime.cmake 游戏源）用 NDK ${S2A_ANDROID_NDK} 编过，用时 $(( $(date +%s) - t0 )) 秒"
