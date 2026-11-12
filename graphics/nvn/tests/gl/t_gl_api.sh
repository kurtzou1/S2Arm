#!/bin/bash
# GL 层接口补齐单测（t_gl_api.m 文件头写了测什么、期望怎么算）：合成 GLSL → 出包工具 gl_shaders.py 出库 → 生产 GL 各片打成静态库 → 从 gl_lookup 取真实实现在真 Metal 设备上跑、GPU 读回核对。
# 公共后端用 t_gl_stubs.inc 的替身（同 t_gl_min）。要 glslangValidator 与 spirv-cross（Homebrew），缺了报红退出 1。
# 反证：GL_API_SRC=<另一份 graphics/nvn/gfx/gl 目录> 用那份 GL 源码编库跑同一套断言（补齐前的源码应在每组「取不到」处红）。
set -u
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../../.." && pwd); NV=$R/graphics/nvn
. "$R/tools/toolchain.sh" || exit 2
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
for t in glslangValidator spirv-cross; do command -v $t > /dev/null || { echo "✗ t_gl_api：没有 ${t}（brew install glslang spirv-cross）"; exit 1; }; done
SRC=${GL_API_SRC:-$NV/gfx/gl}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/cap" "$T/lib" "$T/o"
for name in tri api_inst api_uni api_vol texture api_es300 api_samparr api_bool; do
    for s in vert frag; do k=$(shasum -a 256 "$H/$name.$s" | cut -c1-16); cp "$H/$name.$s" "$T/cap/$k.$s"; done
done
"$PY" "$NV/../../translator/gl_shaders.py" "$T/cap" "$T/lib" > "$T/lib.log" 2>&1 || { echo "✗ t_gl_api：出库失败"; cat "$T/lib.log"; exit 1; }
CF=(-std=gnu11 -fobjc-arc -O1 -g -Wall -Wno-unused-function -Wno-unused-variable -I"$NV/gfx/nvn/include" -I"$NV/host" -I"$R/runtime/include")
for f in "$SRC"/*.m; do clang "${CF[@]}" -c "$f" -o "$T/o/$(basename "$f" .m).o" || { echo "✗ t_gl_api：编译失败（${f}）"; exit 1; }; done
ar rcs "$T/libgl.a" "$T"/o/*.o
clang "${CF[@]}" -o "$T/t_gl_api" "$H/t_gl_api.m" "$T/libgl.a" "$NV/gfx/nvn/nvn_fps.c" "$NV/gfx/tex/nvn_bcdec.c" $(python3 "$R/tools/weak_link_decl.py" flags nvntest) -framework Metal -framework Foundation || { echo "✗ t_gl_api：编译失败"; exit 1; }
S2A_WIDEN_DIRECT=0 MTL_DEBUG_LAYER=1 T_GL_DIR=$H DM_MSL_DIR=$T/lib "$T/t_gl_api"; rc=$?
# GLB 入口（客体线程进来、调 Metal 的重活）函数体必须整个包在 @autoreleasepool 里（gl_int.h GLB 注释）：漏了就逐帧漏命令缓冲连带贴图，L 组只覆盖到几个入口，这里逐个核
bad=$(grep -n '^GLB(' "$SRC"/*.m | grep -v ') { @autoreleasepool {' || true)
if [ -n "$bad" ]; then echo "✗ t_gl_api：以下 GLB 入口函数体没包 @autoreleasepool"; echo "$bad"; rc=1; fi
# 栈上参数（gl_tex.m glTexSubImage3D / gl_fb.m glBlitFramebuffer 注释）：整数 / 指针第 9 个起、浮点第 9 个起在栈上。游戏（标准 AAPCS64）每个占 8 字节一格，
#   Apple ARM64 按自然大小紧排：凡是窄于 8 字节的栈上参数，宿主就读错位。按签名全量扫：栈上整数参数必须是指针或 64 位类型、栈上浮点必须是 double
stack_bad=$("$PY" -I - "$SRC" <<'PYEOF'
import glob, os, re, sys
rx = re.compile(r'^GLB?\((\w+),\s*[^,]+?,\s*([^)]*)\)\s*\{', re.M)
WIDE = re.compile(r'\*|\b(uint64_t|int64_t|GLsizeiptr|GLintptr|GLuint64|GLint64|intptr_t|uintptr_t|size_t)\b')
FLT = re.compile(r'\b(GLfloat|GLclampf|float|GLdouble|GLclampd|double)\b')
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.m'))):
    s = open(f, encoding='utf-8').read()
    for m in rx.finditer(s):
        ps = [p.strip() for p in m.group(2).split(',') if p.strip() and p.strip() != 'void']
        ints = [p for p in ps if '*' in p or not FLT.search(p)]; flts = [p for p in ps if '*' not in p and FLT.search(p)]
        bad = [p for p in ints[8:] if not WIDE.search(p)] + [p for p in flts[8:] if not re.search(r'\b(double|GLdouble|GLclampd)\b', p)]
        if bad: print(f'{os.path.basename(f)}:{s[:m.start()].count(chr(10)) + 1} {m.group(1)} 栈上参数窄于 8 字节：{", ".join(bad)}')
PYEOF
)
if [ -n "$stack_bad" ]; then echo "✗ t_gl_api：以下 GL 入口的栈上参数会和游戏错位（改成 64 位声明、函数体里取低位）"; echo "$stack_bad"; rc=1
else echo "✓ t_gl_api：GL 入口栈上参数全部按 8 字节一格声明"; fi
exit $rc
