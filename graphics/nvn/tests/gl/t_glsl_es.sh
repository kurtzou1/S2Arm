#!/bin/bash
# GLSL 改写层单测（graphics/nvn/gfx/gl/gl_glsl_es.c：出包离线链 gl_shaders.py 与宿主运行时兜底 gl_xlate.c 共用的一份实现）。约 1 秒，不要 GPU / glslang。
# 编它的命令行入口（S2A_GLSL_ES_MAIN，同 gl_shaders.py 的用法），喂手写输入、比手写期望（期望按 GLSL ES 规范与改写规则逐字写出，不跑被测实现）：
#   prefix ①「#version 320\r\n」→ 补「 es」、保留 \r；②「  #  version  300  」行尾空白去掉、补 es；③ 第一条已带 es → 整份不动（后面的 310 core / 3000 不替它改）；④ 只改第一处
#          ⑫ #749 版本号后跟 // 注释 → es 插在注释前；⑬ 跟 /* */ 注释同；⑭「310 core\r\n」→「310 es\r\n」；⑮「300 compatibility」→「300 es」；⑯「310 cores」「3100」不动
#   rewrite ⑤ ES 1.00 顶点（无版本行）：头三行 + attribute → in、varying → out，「myattribute」「attributes」不动
#           ⑥ ES 1.00 片元（#version 100 行去掉）：varying → in、gl_FragColor → s2a_FragColor 并声明 location 0、texture2D / textureCube / texture2DProj / texture2DLodEXT 改名、
#              gl_FragData [ 1 ] → s2a_FragData1 并声明 location 1、gl_FragDepthEXT → gl_FragDepth；「texture2Dx(」不动
#           ⑦ #version 300 es → 310 es，版本行之前的空行丢掉，其余原样
#           ⑧ 片元没写 gl_FragColor 时不加输出声明
#           ⑨ 「out highp vec4 gl_Position;」整句删（数码宝贝内置精灵着色器），「out vec4 gl_PositionX;」不动
#           ⑩ textureOffset 偏移是变量 → texture(s, (P) + vec2(off) / vec2(textureSize(s, 0)))；常量 ivec2(1, -1) 不动；textureLodOffset 变量 → textureLod(…, int(l)) 形式
#           ⑪ 括号不配 → 退 1、stderr「unbalanced parentheses」（gl_shaders.py 原 call_args 同句）
set -u
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0; n=0
cc -O1 -Wall -Wextra -Werror -DS2A_GLSL_ES_MAIN "$R/graphics/nvn/gfx/gl/gl_glsl_es.c" -o "$T/es" || { echo "✗ t_glsl_es：编不过"; exit 1; }
ck() {   # ck <名> <模式参数…> ：stdin 之外的输入在 $T/in，期望在 $T/want
    n=$((n + 1)); local name=$1; shift
    if "$T/es" "$@" < "$T/in" > "$T/got" 2> "$T/err" && cmp -s "$T/got" "$T/want"; then echo "  过 $name"
    else echo "  败 $name"; diff <(cat -A "$T/want" 2> /dev/null || cat -v "$T/want") <(cat -A "$T/got" 2> /dev/null || cat -v "$T/got") | head -20; cat "$T/err"; bad=$((bad + 1)); fi
}
printf '#version 320\r\nvoid main() {}\n' > "$T/in"; printf '#version 320 es\r\nvoid main() {}\n' > "$T/want"; ck "① 320 补 es、保留 \\r" prefix
printf '  #  version  300  \nvoid main() {}\n' > "$T/in"; printf '  #  version  300 es\nvoid main() {}\n' > "$T/want"; ck "② 行首空白保留、行尾空白去掉" prefix
printf '#version 300 es\n#version 310 core\n#version 3000\n' > "$T/in"; cp "$T/in" "$T/want"; ck "③ 第一条已带 es：整份不动" prefix
printf '// x\n#version 310\n#version 320\n' > "$T/in"; printf '// x\n#version 310 es\n#version 320\n' > "$T/want"; ck "④ 只改第一处" prefix
printf '#version 310 // engine shader\nvoid main() {}\n' > "$T/in"; printf '#version 310 es // engine shader\nvoid main() {}\n' > "$T/want"; ck "⑫ 版本号后跟 // 注释：es 插在注释前" prefix
printf '#version 300 /* a */\nvoid main() {}\n' > "$T/in"; printf '#version 300 es /* a */\nvoid main() {}\n' > "$T/want"; ck "⑬ 版本号后跟 /* */ 注释" prefix
printf '#version 310 core\r\nvoid main() {}\n' > "$T/in"; printf '#version 310 es\r\nvoid main() {}\n' > "$T/want"; ck "⑭ core → es、保留 \\r" prefix
printf '#version 300 compatibility\nvoid main() {}\n' > "$T/in"; printf '#version 300 es\nvoid main() {}\n' > "$T/want"; ck "⑮ compatibility → es" prefix
printf '#version 310 cores\n' > "$T/in"; cp "$T/in" "$T/want"; ck "⑯a 310 cores（不是 core 这个词）不动" prefix
printf '#version 3100\n' > "$T/in"; cp "$T/in" "$T/want"; ck "⑯b 3100 不动" prefix
printf 'attribute vec4 a_pos;\nvarying vec2 v_uv;\nfloat myattribute; float attributes;\nvoid main() { v_uv = a_pos.xy; gl_Position = a_pos; }\n' > "$T/in"
printf '#version 310 es\nprecision highp float;\nprecision highp int;\nin vec4 a_pos;\nout vec2 v_uv;\nfloat myattribute; float attributes;\nvoid main() { v_uv = a_pos.xy; gl_Position = a_pos; }\n' > "$T/want"
ck "⑤ ES 1.00 顶点" rewrite vert
printf '#version 100\nprecision mediump float;\nvarying vec2 v;\nuniform sampler2D t; uniform samplerCube c;\nvoid main() { gl_FragColor = texture2D(t, v) + textureCube (c, vec3(v, 1.0)) + texture2DProj(t, vec3(v, 1.0)) + texture2DLodEXT(t, v, 0.0) + texture2Dx(v);\n  gl_FragData [ 1 ] = vec4(1.0); gl_FragDepthEXT = 0.5; }\n' > "$T/in"
printf '#version 310 es\nprecision highp float;\nprecision highp int;\nlayout(location = 0) out vec4 s2a_FragColor;\nlayout(location = 1) out vec4 s2a_FragData1;\nprecision mediump float;\nin vec2 v;\nuniform sampler2D t; uniform samplerCube c;\nvoid main() { s2a_FragColor = texture(t, v) + texture(c, vec3(v, 1.0)) + textureProj(t, vec3(v, 1.0)) + textureLod(t, v, 0.0) + texture2Dx(v);\n  s2a_FragData1 = vec4(1.0); gl_FragDepth = 0.5; }\n' > "$T/want"
ck "⑥ ES 1.00 片元（#version 100）" rewrite frag
printf '\n\n#version 300 es\nprecision mediump float;\nin vec2 v; out vec4 o;\nvoid main() { o = vec4(v, 0.0, 1.0); }\n' > "$T/in"
printf '#version 310 es\nprecision mediump float;\nin vec2 v; out vec4 o;\nvoid main() { o = vec4(v, 0.0, 1.0); }\n' > "$T/want"
ck "⑦ 300 es → 310 es" rewrite frag
printf 'varying vec2 v;\nvoid main() { }\n' > "$T/in"; printf '#version 310 es\nprecision highp float;\nprecision highp int;\nin vec2 v;\nvoid main() { }\n' > "$T/want"
ck "⑧ 片元没写颜色不加输出" rewrite frag
printf '#version 320 es\nin vec4 p;\n  out highp vec4 gl_Position ;\nout vec4 gl_PositionX;\nvoid main() { gl_Position = p; }\n' > "$T/in"
printf '#version 320 es\nin vec4 p;\n\nout vec4 gl_PositionX;\nvoid main() { gl_Position = p; }\n' > "$T/want"
ck "⑨ gl_Position 重声明删掉" rewrite vert
printf '#version 320 es\nvoid f(ivec2 k) { a = textureOffset(s, uv, k); b = textureOffset(s, uv, ivec2(1, -1)); c = textureLodOffset(s, uv, l, k); }\n' > "$T/in"
printf '#version 320 es\nvoid f(ivec2 k) { a = texture(s, (uv) + vec2(k) / vec2(textureSize(s, 0))); b = textureOffset(s, uv, ivec2(1, -1)); c = textureLod(s, (uv) + vec2(k) / vec2(textureSize(s, int(l))), l); }\n' > "$T/want"
ck "⑩ 非常量纹理偏移" rewrite frag
n=$((n + 1)); printf '#version 320 es\nvoid f() { a = textureOffset(s, uv, k; }\n' > "$T/in"
if ! "$T/es" rewrite frag < "$T/in" > /dev/null 2> "$T/err" && grep -qx 'unbalanced parentheses' "$T/err"; then echo "  过 ⑪ 括号不配报错"; else echo "  败 ⑪ 括号不配报错：$(cat "$T/err")"; bad=$((bad + 1)); fi
[ $bad = 0 ] && echo "✓ t_glsl_es：$n 项全过" || { echo "✗ t_glsl_es：$n 项，失败 $bad"; exit 1; }
