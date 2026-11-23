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
#           ⑰ #749 顶点 out 接口块（紧跟 #extension 行、块带 layout）→ 每个成员一条「out … 块名_成员」，成员的 flat 挪到 out 前、highp 留在 out 后；正文「实例名 . 成员」→「块名_成员」，xvs_out.uv 不动
#           ⑱ 片元 in 块的块级 flat 加到每个成员；成员自带精度保留
#           ⑲ 匿名块（没有实例名）：成员保持原名
#           ⑳ 实例是数组 / 成员是数组 / uniform 块：整份不动（照旧由翻译报错）
#           ㉑–㉔ D-9EPN：结果不是 3.20、没开多重采样插值扩展时整词 sample → s2a_sample（3.10 原文 / ES 1.00 升版）；3.20 或开了扩展不动
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
printf '#version 320 es\n#extension GL_EXT_shader_io_blocks : enable\nlayout(location = 0) out VS_OUT {\n    highp vec2 uv;\n    flat int id;\n    vec4 col;\n} vs_out;\nvoid main() { vs_out.uv = vec2(0.0); vs_out . id = 1; vs_out.col.x = 1.0; xvs_out.uv = 0.0; }\n' > "$T/in"
printf '#version 320 es\n#extension GL_EXT_shader_io_blocks : enable\nout highp vec2 VS_OUT_uv;\nflat out int VS_OUT_id;\nout vec4 VS_OUT_col;\n\nvoid main() { VS_OUT_uv = vec2(0.0); VS_OUT_id = 1; VS_OUT_col.x = 1.0; xvs_out.uv = 0.0; }\n' > "$T/want"
ck "⑰ 顶点 out 接口块展平" rewrite vert
printf '#version 320 es\nprecision highp float;\nflat in VS_OUT { mediump vec2 uv; int k; } fs_in;\nout vec4 o;\nvoid main() { o = vec4(fs_in.uv, float(fs_in.k), 1.0); }\n' > "$T/in"
printf '#version 320 es\nprecision highp float;\nflat in mediump vec2 VS_OUT_uv;\nflat in int VS_OUT_k;\n\nout vec4 o;\nvoid main() { o = vec4(VS_OUT_uv, float(VS_OUT_k), 1.0); }\n' > "$T/want"
ck "⑱ 片元 in 块：块级 flat 加到每个成员" rewrite frag
printf '#version 320 es\nout Blk { vec2 a; };\nvoid main() { a = vec2(1.0); }\n' > "$T/in"
printf '#version 320 es\nout vec2 a;\n\nvoid main() { a = vec2(1.0); }\n' > "$T/want"
ck "⑲ 匿名块成员保持原名" rewrite vert
printf '#version 320 es\nout VS_OUT { vec2 uv; } vs_out[2];\nout B { float w[4]; } b;\nlayout(std140) uniform U { vec4 c; } u;\nvoid main() { }\n' > "$T/in"; cp "$T/in" "$T/want"
ck "⑳ 数组实例 / 数组成员 / uniform 块不动" rewrite vert
# ㉑ D-9EPN：3.10 结果里「sample」当名字用 → 整词改 s2a_sample；gl_SampleID、samples、sampler2D 不动
printf '#version 310 es\nprecision highp float;\nuniform sampler2D tex;\nout vec4 o;\nvoid main() { float sample = 1.0; int samples = gl_SampleID; o = vec4(sample) + texture(tex, vec2(sample)); }\n' > "$T/in"
printf '#version 310 es\nprecision highp float;\nuniform sampler2D tex;\nout vec4 o;\nvoid main() { float s2a_sample = 1.0; int samples = gl_SampleID; o = vec4(s2a_sample) + texture(tex, vec2(s2a_sample)); }\n' > "$T/want"
ck "㉑ 3.10 里 sample 当名字 → s2a_sample" rewrite frag
# ㉒ ES 1.00 原文（升版后同样是 3.10）也改：varying → in，sample → s2a_sample
printf 'precision mediump float;\nvarying vec2 uv;\nvoid main() { vec4 sample = vec4(uv, 0.0, 1.0); gl_FragColor = sample; }\n' > "$T/in"
"$T/es" rewrite frag < "$T/in" > "$T/got" 2> "$T/err"; n=$((n + 1))
if grep -q 'vec4 s2a_sample = vec4' "$T/got" && grep -q '= s2a_sample;' "$T/got" && ! grep -qw 'sample' "$T/got"; then echo "  过 ㉒ ES 1.00 升版后 sample 也改名"; else echo "  败 ㉒ ES 1.00 升版后 sample 也改名"; cat "$T/got"; bad=$((bad + 1)); fi
# ㉓ 3.20 里 sample 是插值限定符：不动
printf '#version 320 es\nprecision highp float;\nsample in vec4 v;\nout vec4 o;\nvoid main() { o = v; }\n' > "$T/in"; cp "$T/in" "$T/want"
ck "㉓ 3.20 的 sample 限定符不动" rewrite frag
# ㉔ 3.10 开了 GL_OES_shader_multisample_interpolation：sample 是限定符，不动
printf '#version 310 es\n#extension GL_OES_shader_multisample_interpolation : require\nprecision highp float;\nsample in vec4 v;\nout vec4 o;\nvoid main() { o = v; }\n' > "$T/in"; cp "$T/in" "$T/want"
ck "㉔ 开了多重采样插值扩展：不动" rewrite frag
# ㉕ D-45CD：「#version 320」（补成 320 es）里 sample 当名字 → 照样改 s2a_sample（原先 3.20 不改名，报 Reserved word）
printf '#version 320 es\nprecision highp float;\nout vec4 o;\nvoid main() { float sample = 2.0; o = vec4(sample); }\n' > "$T/in"
printf '#version 320 es\nprecision highp float;\nout vec4 o;\nvoid main() { float s2a_sample = 2.0; o = vec4(s2a_sample); }\n' > "$T/want"
ck "㉕ 3.20 里 sample 当名字 → s2a_sample" rewrite frag
# ㉖ 开了扩展、sample 当名字 → 改名
printf '#version 310 es\n#extension GL_OES_shader_multisample_interpolation : require\nprecision highp float;\nout vec4 o;\nvoid main() { vec4 sample = vec4(1.0); o = sample; }\n' > "$T/in"
printf '#version 310 es\n#extension GL_OES_shader_multisample_interpolation : require\nprecision highp float;\nout vec4 o;\nvoid main() { vec4 s2a_sample = vec4(1.0); o = s2a_sample; }\n' > "$T/want"
ck "㉖ 开了扩展、sample 当名字 → 改名" rewrite frag
# ㉗ 3.20 同一支里既有限定符又有名字：只改名字那处
printf '#version 320 es\nprecision highp float;\nsample in vec4 v;\nout vec4 o;\nvoid main() { float sample = 0.5; o = v * sample; }\n' > "$T/in"
printf '#version 320 es\nprecision highp float;\nsample in vec4 v;\nout vec4 o;\nvoid main() { float s2a_sample = 0.5; o = v * s2a_sample; }\n' > "$T/want"
ck "㉗ 限定符留、名字改" rewrite frag
# ㉕–㉘ D-45J6（#852）：桌面 GLSL 110 / 120 / 130 —— glslang 出 SPIR-V 拒收 140 以下的桌面版本（「Desktop shaders for Vulkan SPIR-V require version 140 or higher」）。
#   第一条版本行的版本号换成 100，按 ES 1.00 预处理、再走 ES 1.00 → 3.10 的改写（attribute / varying / gl_FragColor / texture2D）；行里别的（行首空白、注释、\r）原样
printf '#version 120\nvoid main() {}\n' > "$T/in"; printf '#version 100\nvoid main() {}\n' > "$T/want"; ck "㉕ 桌面 120 → 100" prefix
printf ' # version 110 // engine\r\nvoid main() {}\n' > "$T/in"; printf ' # version 100 // engine\r\nvoid main() {}\n' > "$T/want"; ck "㉖ 桌面 110 带注释、\\r 原样" prefix
printf '#version 130\n#version 120\n' > "$T/in"; printf '#version 100\n#version 120\n' > "$T/want"; ck "㉗ 桌面 130 → 100，只改第一条" prefix
printf '#version 140\n#version 1200\n' > "$T/in"; cp "$T/in" "$T/want"; ck "㉘a 140 不动（glslang 收）" prefix
printf '#version 1200\n' > "$T/in"; cp "$T/in" "$T/want"; ck "㉘b 1200 不动" prefix
# ㉙–㉛ D-TTP7：ES 3.x 片元用到 sampler3D / sampler2DShadow 却没写缺省精度（glslang 报 type requires declaration of default precision qualifier，NVIDIA 放过）
#   ㉙ 300 es 带 #extension：「precision highp <类型>;」补在开头预处理行（版本 + 扩展）之后，按类型表顺序（sampler3D 在 sampler2DShadow 前），只补用到的
printf '#version 300 es\n#extension GL_EXT_shadow_samplers : enable\nuniform sampler3D lut;\nuniform sampler2DShadow sm;\nvoid main() {}\n' > "$T/in"
printf '#version 310 es\n#extension GL_EXT_shadow_samplers : enable\nprecision highp sampler3D;\nprecision highp sampler2DShadow;\nuniform sampler3D lut;\nuniform sampler2DShadow sm;\nvoid main() {}\n' > "$T/want"
ck "㉙ 补用到的采样器缺省精度、在 #extension 之后" rewrite frag
#   ㉚ 已写 precision mediump sampler3D：不重复补；「sampler3DX」不是那个类型、不算用到
printf '#version 310 es\nprecision mediump sampler3D;\nuniform sampler3D lut;\nfloat sampler3DX;\nvoid main() {}\n' > "$T/in"; cp "$T/in" "$T/want"
ck "㉚ 已声明的不重复、相似名字不算" rewrite frag
#   ㉛ ES 1.00 顶点用 sampler3D（升版路）：补在版本行后、float / int 精度之前
printf 'attribute vec4 a;\nuniform sampler3D t;\nvoid main() { gl_Position = a; }\n' > "$T/in"
printf '#version 310 es\nprecision highp sampler3D;\nprecision highp float;\nprecision highp int;\nin vec4 a;\nuniform sampler3D t;\nvoid main() { gl_Position = a; }\n' > "$T/want"
ck "㉛ ES 1.00 升版路同样补" rewrite vert
#   ㉜ D-4ZBS：ES 1.00 片元拿 3.x 内建名当名字（「uniform sampler2D texture;」、函数 round、变量 flat）→ 升版前整词改 s2a_<名>；
#       texture2D 照旧改成内建 texture；「texture2D」「textures」「mytexture」不算这个词、不动
printf '#version 100\nprecision mediump float;\nvarying vec2 v;\nuniform sampler2D texture;\nfloat round(float x) { return floor(x + 0.5); }\nvoid main() { float flat = round(v.x); float textures = 1.0; float mytexture = 2.0; gl_FragColor = texture2D(texture, v) * flat * textures * mytexture; }\n' > "$T/in"
printf '#version 310 es\nprecision highp float;\nprecision highp int;\nlayout(location = 0) out vec4 s2a_FragColor;\nprecision mediump float;\nin vec2 v;\nuniform sampler2D s2a_texture;\nfloat s2a_round(float x) { return floor(x + 0.5); }\nvoid main() { float s2a_flat = s2a_round(v.x); float textures = 1.0; float mytexture = 2.0; s2a_FragColor = texture(s2a_texture, v) * s2a_flat * textures * mytexture; }\n' > "$T/want"
ck "㉜ ES 1.00 拿 3.x 内建名当名字：升版前改名" rewrite frag
#   ㉝ 反证：3.10 原文里的 texture 是内建调用，不改名
printf '#version 310 es\nprecision highp float;\nuniform sampler2D t;\nin vec2 v;\nout vec4 o;\nvoid main() { o = texture(t, v); }\n' > "$T/in"; cp "$T/in" "$T/want"
ck "㉝ 3.10 原文的 texture 是内建、不动" rewrite frag
[ $bad = 0 ] && echo "✓ t_glsl_es：$n 项全过" || { echo "✗ t_glsl_es：$n 项，失败 $bad"; exit 1; }
