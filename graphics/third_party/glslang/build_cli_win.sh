#!/bin/bash
# Windows 出包机（Windows 出包机，Git Bash）用的 glslangValidator 命令行：直连库 OpenGL 款离线翻译（translator/gl_shaders.py，GLSL → SPIR-V）要它，
#   Mac 用 Homebrew 的同版本，Windows 没有 Homebrew，用同一份官方源码编（11-05 Windows 出包线：Windows 出包机普查 OpenGL 款直连库原先整支出不了）。
# 用法：bash graphics/third_party/glslang/build_cli_win.sh → 最后一行输出 glslangValidator.exe 路径（Windows 写法）。Windows 出包机上编好后拷进 R:\s2a\deps\glslang-<版本>\、
#   加进机器环境 R:\s2a\bin\tianyan_env.cmd 的 PATH（11-05 已装 16.6.0）；pack/orch/oneclick_win.py --check 核版本与 build.sh 一致。
# 版本与 sha256 只钉在 build.sh 一处（这里按行读出，不另写一份）；ENABLE_HLSL=OFF、ENABLE_OPT=OFF（gl_shaders.py 不带优化参数，SPIR-V 与带 SPIRV-Tools 的构建同），
#   只编命令行（glslang-standalone 目标），不出单测。编译器用 PATH 上的 clang / clang++（Windows 出包机 D:\tools\LLVM，机器环境 tianyan_env.cmd 放进 PATH）、生成器 Ninja。
# 产物按「本脚本 + build.sh 版本行 + 编译器版本」缓存在 ${S2A_GLSLANG_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/glslang}/win-cli-<版本>-<摘要>/，命中秒过。
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/../../.." && pwd)
VER=$(sed -n 's/^VER=\([^;]*\);.*/\1/p' "$H/build.sh"); SHA=$(sed -n 's/^VER=[^;]*; *SHA=\([0-9a-f]*\).*/\1/p' "$H/build.sh")
[ -n "$VER" ] && [ ${#SHA} = 64 ] || { echo "🔴 glslang：$H/build.sh 里读不出 VER / SHA" >&2; exit 1; }
for t in cmake ninja clang clang++; do command -v $t > /dev/null || { echo "🔴 glslang：PATH 上没有 ${t}（Windows 出包机先 call R:\\s2a\\bin\\tianyan_env.cmd）" >&2; exit 1; }; done
source "$ROOT/android/tools/fetch_source.sh"
C=${S2A_GLSLANG_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/glslang}
# 缓存根可能是 Windows 写法（S2A_RUN_ROOT=D:\s2a\run）：GNU tar 把「D:」当远程主机名，解压报 Cannot open（Windows 出包机首编时撞上；
#   原先那台出包机的缓存 11-05 手工编过、一直命中，没走到解压）。在 Git Bash 里统一转成 /d/s2a/… 写法；tar 再加 --force-local 兜底
command -v cygpath > /dev/null && C=$(cygpath -u "$C"); mkdir -p "$C"
ID=$( { cat "$0"; echo "$VER $SHA"; clang++ --version | head -1; } | sha256sum | cut -c1-12)
OUT=$C/win-cli-$VER-$ID; EXE=$OUT/glslangValidator.exe
[ -s "$EXE" ] && { cygpath -m "$EXE"; exit 0; }
# 几单同时首编同一键时排队
until mkdir "$C/.lock-win" 2> /dev/null; do p=$(cat "$C/.lock-win/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock-win"; sleep 0.5; done
echo $$ > "$C/.lock-win/pid"; trap 'rm -rf "$C/.lock-win"' EXIT
if [ ! -s "$EXE" ]; then
  TGZ=$(s2a_source_fetch "glslang-$VER.tar.gz" "https://github.com/KhronosGroup/glslang/archive/refs/tags/$VER.tar.gz" "$SHA") || { echo "🔴 glslang：取不到源码包" >&2; exit 1; }
  W=$OUT.tmp; rm -rf "$W"; mkdir -p "$W/src"
  command -v cygpath > /dev/null && TGZ=$(cygpath -u "$TGZ")
  tar --force-local -xzf "$TGZ" -C "$W/src" --strip-components 1
  WM=$(cygpath -m "$W")
  cmake -S "$WM/src" -B "$WM/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DBUILD_SHARED_LIBS=OFF \
      -DENABLE_HLSL=OFF -DENABLE_OPT=OFF -DENABLE_GLSLANG_BINARIES=ON -DGLSLANG_TESTS=OFF -DBUILD_EXTERNAL=OFF -DENABLE_PCH=OFF -DGLSLANG_ENABLE_INSTALL=OFF \
      -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DCMAKE_POLICY_DEFAULT_CMP0091=NEW > "$W/cmake.log" 2>&1 \
    && cmake --build "$WM/build" --target glslang-standalone -j "${J:-8}" > "$W/build.log" 2>&1 || { echo "🔴 glslang：Windows 命令行构建失败（$W/*.log）" >&2; tail -5 "$W"/*.log >&2; exit 1; }
  B=$(find "$W/build" -name glslangValidator.exe | head -1); [ -n "$B" ] || { echo "🔴 glslang：构建完没找到 glslangValidator.exe" >&2; exit 1; }
  mkdir -p "$OUT"; cp "$B" "$EXE.part"; mv "$EXE.part" "$EXE"; rm -rf "$W"
fi
cygpath -m "$EXE"
