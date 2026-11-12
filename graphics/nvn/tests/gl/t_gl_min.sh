#!/bin/bash
# OpenGL 前端最小绘制路径单测（t_gl_min.m 文件头写了测什么、期望怎么算）：合成 GLSL → 出包工具 gl_shaders.py 出库 → 只经 EGL / GL 接口画一帧、读回核对
# 要 glslangValidator 与 spirv-cross（Homebrew），缺了报红退出 1。公共后端用 t_gl_min.m 里的替身（不链宿主 / libnvn / 宽屏库；宽屏核心也是替身，几秒跑完）。
set -u
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../../.." && pwd); NV=$R/graphics/nvn
. "$R/tools/toolchain.sh" || exit 2
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
for t in glslangValidator spirv-cross; do command -v $t > /dev/null || { echo "✗ t_gl_min：没有 ${t}（brew install glslang spirv-cross）"; exit 1; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/cap" "$T/lib"
for name in tri fan texture cube; do
    for s in vert frag; do k=$(shasum -a 256 "$H/$name.$s" | cut -c1-16); cp "$H/$name.$s" "$T/cap/$k.$s"; done
done
for s in shadow.vert shadow_raw.frag shadow.frag shadow_cube.frag; do k=$(shasum -a 256 "$H/$s" | cut -c1-16); cp "$H/$s" "$T/cap/$k.${s##*.}"; done
k=$(shasum -a 256 "$H/depth.vert" | cut -c1-16); cp "$H/depth.vert" "$T/cap/$k.vert"
k=$(shasum -a 256 "$H/cull.vert" | cut -c1-16); cp "$H/cull.vert" "$T/cap/$k.vert"
mkdir -p "$T/romfs/shaders"; cp "$H/texture100.vs" "$H/texture100.fs" "$T/romfs/shaders/"   # ES 1.00、按扩展名收（.vs / .fs），不经抓取
"$PY" "$NV/../../translator/gl_shaders.py" "$T/cap" "$T/romfs" "$T/lib" > "$T/lib.log" 2>&1 || { echo "✗ t_gl_min：出库失败"; cat "$T/lib.log"; exit 1; }
# GL 各片先打成静态库再链（同宿主链 libnvn.a 的方式）：哪片没被引用、整片被链接器丢掉，这里就取不到它的入口（gl_int.h「分片锚」）
CF=(-std=gnu11 -fobjc-arc -O1 -g -Wall -Wno-unused-function -I"$NV/gfx/nvn/include" -I"$NV/host" -I"$R/runtime/include")
mkdir -p "$T/o"; for f in "$NV"/gfx/gl/*.m; do
    # Gen/Create 与默认纹理各用自己的测试钩子，互不覆盖；产品构建不含替换。
    ALLOC=(-Dcalloc=t_gl_calloc)
    [ "$(basename "$f")" = gl_tex.m ] && ALLOC=(-Dcalloc=t_gl_tex_calloc -Dfree=t_gl_tex_free)
    clang "${CF[@]}" "${ALLOC[@]}" -c "$f" -o "$T/o/$(basename "$f" .m).o" || { echo "✗ t_gl_min：编译失败（${f}）"; exit 1; }
done
ar rcs "$T/libgl.a" "$T"/o/*.o
clang "${CF[@]}" -o "$T/t_gl_min" "$H/t_gl_min.m" "$T/libgl.a" "$NV/gfx/nvn/nvn_fps.c" "$NV/gfx/tex/nvn_bcdec.c" $(python3 "$R/tools/weak_link_decl.py" flags nvntest) -framework Metal -framework Foundation || { echo "✗ t_gl_min：编译失败"; exit 1; }
# 登记段核对：测试程序里 swgl / swglb 的字节数 = 各片 .o 之和（不管测试调没调到那片的入口，哪片被丢都红）
"$PY" -I "$R/tools/reg_sections.py" "$T/t_gl_min" "$T"/o/*.o > "$T/reg.log" || { echo "✗ t_gl_min：有分片没被链进来（gl_int.h「分片锚」）"; cat "$T/reg.log"; exit 1; }
S2A_WIDEN_DIRECT=0 T_GL_DIR=$H DM_MSL_DIR=$T/lib "$T/t_gl_min" || exit 1
# 宽屏第三层那一遍（S2A_WIDEN_DIRECT=1，替身核心按整套放宽回答）；上一遍是关（=0，10-26 起缺省开）时，与现状逐像素一致
S2A_WIDEN_DIRECT=1 T_GL_WIDEN=1 T_GL_DIR=$H DM_MSL_DIR=$T/lib "$T/t_gl_min"
