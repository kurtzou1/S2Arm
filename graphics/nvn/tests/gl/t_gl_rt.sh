#!/bin/bash
# GL 层运行时兜底单测（t_gl_rt.m 文件头写了测什么、期望怎么算）：出包工具 gl_shaders.py 只把 tri.* 出进离线库 → 生产 GL 各片 + libglx（graphics/nvn/Makefile glx-mac：gl_xlate.c + glslang）
#   + libnxgal 那份 SPIRV-Cross（graphics/metal libspvc.a）→ 真 Metal 设备上两遍进程（共用一个 DM_MSL_FALLBACK 缓存目录）。约 10 秒（glslang 第一次构建另算，按脚本缓存）。
# 要 glslangValidator 与 spirv-cross（Homebrew，出离线库用）、cmake 与 ninja（第一次构建 glslang）。公共后端用 t_gl_stubs.inc 的替身（同 t_gl_min / t_gl_api）
set -u
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../../.." && pwd); NV=$R/graphics/nvn
. "$R/tools/toolchain.sh" || exit 2
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
for t in glslangValidator spirv-cross; do command -v $t > /dev/null || { echo "✗ t_gl_rt：没有 ${t}（brew install glslang spirv-cross）"; exit 1; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/cap" "$T/lib" "$T/o" "$T/fb"
for s in vert frag; do k=$(shasum -a 256 "$H/tri.$s" | cut -c1-16); cp "$H/tri.$s" "$T/cap/$k.$s"; done
"$PY" "$NV/../../translator/gl_shaders.py" "$T/cap" "$T/lib" > "$T/lib.log" 2>&1 || { echo "✗ t_gl_rt：出库失败"; cat "$T/lib.log"; exit 1; }
# 就绪判定用的三个游戏数据目录（<目录>/shaders/direct/gl/）：只有表头（空输入出库）、tri 的表 + 库、同一张表没有库
mkdir -p "$T/empty_in" "$T/gd_lib/shaders/direct" "$T/gd_nolib/shaders/direct/gl"
"$PY" "$NV/../../translator/gl_shaders.py" "$T/empty_in" "$T/gd_empty/shaders/direct" > "$T/empty.log" 2>&1 || { echo "✗ t_gl_rt：空输入出表失败"; cat "$T/empty.log"; exit 1; }
cp -R "$T/lib/gl" "$T/gd_lib/shaders/direct/gl"; cp "$T/lib/gl/gl_shaders.tsv" "$T/gd_nolib/shaders/direct/gl/"
make -s -C "$NV" glx-mac > "$T/glx.log" 2>&1 || { echo "✗ t_gl_rt：libglx 编不出"; tail -5 "$T/glx.log"; exit 1; }
make -s -C "$R/graphics/dsx" "$R/build/dsx/mac/libspvc.a" > "$T/spvc.log" 2>&1 || { echo "✗ t_gl_rt：SPIRV-Cross 库编不出"; tail -5 "$T/spvc.log"; exit 1; }
CF=(-std=gnu11 -fobjc-arc -O1 -g -Wall -Wno-unused-function -I"$NV/gfx/nvn/include" -I"$NV/host" -I"$R/runtime/include")
for f in "$NV"/gfx/gl/*.m; do clang "${CF[@]}" -c "$f" -o "$T/o/$(basename "$f" .m).o" || { echo "✗ t_gl_rt：编译失败（${f}）"; exit 1; }; done
ar rcs "$T/libgl.a" "$T"/o/*.o
clang "${CF[@]}" -o "$T/t_gl_rt" "$H/t_gl_rt.m" "$T/libgl.a" "$R/build/nvn/mac/libglx.a" "$R/build/dsx/mac/libspvc.a" "$NV/gfx/nvn/nvn_fps.c" "$NV/gfx/tex/nvn_bcdec.c" \
  $(python3 "$R/tools/weak_link_decl.py" flags nvntest) -lc++ -framework Metal -framework Foundation || { echo "✗ t_gl_rt：链接失败"; exit 1; }
rc=0
for pass in 1 2; do
  T_GD_EMPTY=$T/gd_empty T_GD_LIB=$T/gd_lib T_GD_NOLIB=$T/gd_nolib T_GL_RT_PASS=$pass S2A_WIDEN_DIRECT=0 T_GL_DIR=$H DM_MSL_DIR=$T/lib DM_MSL_FALLBACK=$T/fb "$T/t_gl_rt" > "$T/p$pass.log" 2>&1 || rc=1
  grep -E "^(  过|  败|[A-E] |✓|✗)" "$T/p$pass.log"; grep -q "^✓ t_gl_rt 第 $pass 遍" "$T/p$pass.log" || { rc=1; grep -E "\[gl\]" "$T/p$pass.log" | tail -8; }
done
[ $rc = 0 ] && echo "✓ t_gl_rt：两遍全过" || echo "✗ t_gl_rt：有失败"
exit $rc
