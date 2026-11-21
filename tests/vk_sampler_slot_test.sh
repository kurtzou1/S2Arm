#!/bin/bash
# 门禁显卡：共享（建 Metal 设备在本机显卡上跑、不按显示时钟判：取共享显卡锁，与按显示时钟判的独占步错开；11-20 读写锁）
# 门禁覆盖：graphics/tools/spirv_msl.py graphics/metal/gal_vkx.m tests/vk_sampler_slot_test.sh
# Vulkan / GLSL 前端的采样器槽（审计 1101 18:00 P1-19，约 5 秒，要 glslangValidator 与 Metal）：bash tests/vk_sampler_slot_test.sh
# 一支片元着色器：绑定 0 独立采样器、绑定 1 组合采样器、绑定 2 独立纹理。改写后的下标同时是纹理下标和采样器下标，组合采样器要越过两个游标。
#   期望（按规则手算，不跑被测实现）：s:0.0=0（采样器 0）→ c:0.1=1（纹理游标 0、采样器游标 1，取 1，两个游标都到 2）→ t:0.2=2，资源表「s:0.0=0 c:0.1=1 t:0.2=2」；
#   出包（spirv_msl.translate）与设备（gal_vkx.m s2a_vk_xlate）两边资源表都等于它，两边翻出的 MSL 本机 Metal 都编得出。
#   改前：组合采样器只取纹理游标 = 0，和独立采样器同为采样器 0，资源表「s:0.0=0 c:0.1=0 t:0.2=1」，MSL 采样器下标重复、Metal 编不出
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
command -v glslangValidator > /dev/null || { echo "✗ vk_sampler_slot：没有 glslangValidator"; exit 2; }
. "$H/tools/toolchain.sh" > /dev/null 2>&1 || exit 2
WANT="s:0.0=0 c:0.1=1 t:0.2=2"
cat > "$T/x.frag" <<'EOF'
#version 450
layout(set = 0, binding = 0) uniform sampler s0;
layout(set = 0, binding = 1) uniform sampler2D cs;
layout(set = 0, binding = 2) uniform texture2D t2;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o;
void main() { o = texture(cs, uv) + texture(sampler2D(t2, s0), uv); }
EOF
glslangValidator -V -S frag "$T/x.frag" -o "$T/x.spv" > "$T/gv.log" 2>&1 || { echo "✗ glslangValidator 失败：$(tail -2 "$T/gv.log")"; exit 1; }
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
# 出包：spirv_msl.translate → (键, 阶段, 资源表, MSL 列表, 路径)
python3 - "$H" "$T" <<'PY' > "$T/py.out" 2> "$T/py.err"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools')); import spirv_msl
t = sys.argv[2]; key, stage, res, msls, _ = spirv_msl.translate(os.path.join(t, 'x.spv'), t, t)
print(' '.join(res) if isinstance(res, list) else res); open(os.path.join(t, 'py.metal'), 'w').write(msls[0] if isinstance(msls[0], str) and '\n' in msls[0] else open(msls[0]).read())
PY
[ -s "$T/py.out" ] || { echo "✗ spirv_msl.translate 出错：$(tail -3 "$T/py.err")"; exit 1; }
ck "出包 spirv_msl 资源表" "$WANT" "$(head -1 "$T/py.out")"
xcrun -sdk macosx metal -c "$T/py.metal" -o "$T/py.air" 2> "$T/py.metalerr"; ck "出包翻出的 MSL 本机 Metal 编得出" 0 $?
# 设备：gal_vkx.m s2a_vk_xlate（同 tests/vk_xlate/t_vk_xlate.sh 的编法）
make -s -C "$H/graphics/dsx" "$H/build/dsx/mac/libspvc.a" > /dev/null || { echo "✗ libspvc 编不过"; exit 1; }
cat > "$T/d.m" <<'EOF'
#import <Foundation/Foundation.h>
#include <stdio.h>
int s2a_vk_xlate(const uint32_t *code, size_t nwords, const char *key, char **msl, char **msl_d, char *res, size_t rescap, int *stage, char *err, size_t errcap);
int main(int argc, char **argv) { @autoreleasepool {
    NSData *d = [NSData dataWithContentsOfFile:@(argv[1])]; char *msl = NULL, *msl_d = NULL, res[512] = "", err[512] = ""; int stage = 0;
    if (s2a_vk_xlate(d.bytes, d.length / 4, "0000000000000000", &msl, &msl_d, res, sizeof res, &stage, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    printf("%s\n", res); FILE *f = fopen(argv[2], "w"); fputs(msl, f); fclose(f); return 0;
} }
EOF
clang -std=gnu11 -O1 -fobjc-arc -I"$H/graphics/third_party/spirv_cross" -o "$T/d" "$T/d.m" "$H/graphics/metal/gal_vkx.m" "$H/build/dsx/mac/libspvc.a" -lc++ -framework Metal -framework Foundation 2> "$T/cc.log" \
  || { echo "✗ 设备执行器编不过：$(head -3 "$T/cc.log")"; exit 1; }
"$T/d" "$T/x.spv" "$T/dev.metal" > "$T/dev.out" 2> "$T/dev.err" || { echo "✗ s2a_vk_xlate 出错：$(cat "$T/dev.err")"; bad=1; }
ck "设备 gal_vkx 资源表" "$WANT" "$(head -1 "$T/dev.out")"
xcrun -sdk macosx metal -c "$T/dev.metal" -o "$T/dev.air" 2> "$T/dev.metalerr"; ck "设备翻出的 MSL 本机 Metal 编得出" 0 $?
[ $bad = 0 ] && echo "vk_sampler_slot：全过" || echo "vk_sampler_slot：有失败"; exit $bad
