// SPDX-License-Identifier: MIT
// Copyright 2026 S2Arm contributors; EASU / RCAS port: Copyright (c) 2021 Advanced Micro Devices, Inc., Copyright (c) 2014 Michal Drobot (graphics/nvn/third_party/ffx_fsr1/LICENSE.txt)
// 直连上屏 AMD FSR 1（S2A_SCALING_FILTER=Fsr）：EASU 放大 + RCAS 锐化两遍，替换最后那次双线性缩放。挂点：nvn_present_aa.inc（解析）、nvn_mtl.m（上屏编码入口、present_now 槽忙标记、mtl_init 校验）、nvn_present_fi.inc（补帧上屏）。
// 真值：Ryujinx 的 FsrScalingFilter.cs 与两份 GLSL（compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Shaders/FsrScaling.glsl、FsrSharpening.glsl，
//   内嵌 AMD ffx_a.h / ffx_fsr1.h，MIT）。下面的 MSL 逐式抄自其中的 FsrEasuCon / FsrEasuSetF / FsrEasuTapF / FsrEasuF 与 FsrRcasCon / FsrRcasF
//   （32 位浮点路径；Ryujinx 没开 FSR_RCAS_DENOISE / FSR_RCAS_PASSTHROUGH_ALPHA，这里也没有）。版权与许可全文在着色器源码开头（随二进制带走）
//   和 graphics/nvn/third_party/ffx_fsr1/LICENSE.txt。
// 输入的色彩空间：存储原字节（sRGB 编码值，感知空间；sRGB 格式的窗口贴图经 present_raw_src 取非 sRGB 视图），与 FSR 1 对输入的要求一致，也与 Ryujinx 一致——
//   Ryujinx 的上屏贴图格式由 SurfaceFlinger.TryConvertColorFormat 定，只出 Unorm（R8G8B8A8Unorm / B8G8R8A8Unorm …），从不出 sRGB 格式，采样得到的就是编码值；
//   EASU 的输出写进同格式的中间图（8 位），RCAS 再读它。这里两张中间图都是 BGRA8Unorm。
// 锐化强度：Ryujinx 的 ScalingFilterLevel（0–100，缺省 80：ConfigurationState / 无界面版的 scaling-filter-level 缺省值；裁剪后的 compat/tree 里没有配置层，
//   只有 Window.SetScalingFilterLevel 这个入口），FsrScalingFilter.Level 下限 0.01，RCAS 的衰减档数 = 1.5 − Level × 0.01 × 1.5，FsrRcasCon 取 exp2(−档数)。
//   缺省 80 → 0.3 档 → 系数 0.8123。S2A_SCALING_FILTER_LEVEL=0…100 的整数可改（A/B 用，不进设置页），非法值起局（mtl_init）报红退出。
// 与 Ryujinx 不同的地方（各有理由）：
//   1. 取纹素：Ryujinx 用 textureGather（四次、每次三个通道），这里按整数坐标直接读 12 个纹素并钳在画面矩形里。数值相同（gather 的 12 个有用纹素就是这 12 个，
//      钳边采样器 = 坐标钳边）；直接读不依赖 gather 在纹素角上的取整，也不用先把裁剪 / 上下翻转拷成一张中间图（来源就是窗口贴图本身，省一遍全屏拷贝）。
//      Ryujinx 的 translate() 不加裁剪起点、右下越界读到裁剪外的纹素；这里起点照加、越界钳到裁剪边（同 present_blit 的 edge）。
//   2. RCAS 的图边：Ryujinx 的 texelFetch 越界未定义（它的中间图是整个交换链大小，画面外是黑边，画面贴边一圈对着黑做锐化）；这里中间图就是视口大小，越界钳边。
//   3. RCAS 里的 max / min 用 fmax / fmin 并关快速数学（MTLMathModeSafe）：某通道五个纹素全 0 时 hitMin = 0 × (1 / 0) = NaN、全 1 时 hitMax = NaN
//      （纯黑 / 纯白 / 纯原色的区域都会走到），AMD 的式子靠「一边是 NaN 取另一边」（D3D 的 max / min 规定如此）把这个通道排除出去。MSL 的 max / min
//      遇 NaN 未定义、快速数学还允许编译器假定没有 NaN，fmax / fmin 在规范里写明取另一边。这一条是按规范写的防护：M5 Pro 上改回 max / min + 快速数学，
//      单测 t_present_fsr 的纯黑 / 纯白 / 纯原色图样照样过（没测到坏）。关快速数学另有实测的理由：MTLMathModeFast 下 EASU 对 CPU 参考有像素差到 4 级
//      （96×54 → 182×102、输入是 SMAA 中档的输出：6 / 18564 像素超过 1 级，Metal 3 / 4 相同；Safe 下 0 个。docs/坑记录.md「FSR 1 着色器要关快速数学」）。
//   4. 来源比视口大出 1.25 倍以上时不走 EASU：先 4 抽头面积缩小到视口，再 RCAS。EASU 是放大核，12 个抽头的截止频率在来源的奈奎斯特，缩小时高于视口奈奎斯特的
//      内容原样折回来。CPU 参考量的读数（视口 484×272，同心圆扫频 + 辐条 + 斜边，对理想图的均方根误差，8 位刻度；docs/坑记录.md「FSR 1 缩小方向」）：
//        来源 / 视口   EASU 直接：混叠 / 边线   只双线性：混叠 / 边线   4 抽头面积：混叠 / 边线
//        1.058         64.8 / 18.1              42.6 / 17.5              31.7 / 16.5      （细节误差 EASU 11.1、双线性 22.4、面积 27.3：EASU 最锐）
//        1.252         73.8 / 17.6              48.5 / 15.9              32.2 / 14.1
//        1.587         82.6 / 15.9              58.0 / 13.9              35.7 /  9.9
//        2.116         85.9 / 16.9              63.9 / 14.3              33.9 /  6.8
//      点采样的混叠读数约 90：到 1.587 倍 EASU 直接缩已接近点采样，高倍率画出来的超采样基本丢光。1.25 倍以内（720p 的 2 倍 2560×1440 → 2420×1362 是 1.058，
//      1080p 的 1.5 倍 → 2420 宽是 1.19）混叠带窄、EASU 保细节最好，照 Ryujinx 直接走 EASU；以上走面积缩小（每个输出像素 4 个双线性样本，偏移 ±1/4 输出像素，
//      覆盖到 4 倍；面积缩小后再接 1:1 的 EASU 边线没有变好、细节误差反而大，所以不接）。
// 与抗锯齿（SMAA）的顺序：先抗锯齿、后缩放（同 MetalFX 与 Ryujinx：Window.Present 先 _effect.Run 再 _scalingFilter.Run）——走 EASU 时抗锯齿在来源尺寸做
//   （来源至多是视口的 1.25 倍，中间图至多多 56%，2560×1440 是 51.6 MB / 槽，视口尺寸 2420×1362 是 46.1 MB / 槽）。来源超过 1.25 倍时沿用现有
//   rs_aa_crop 的次序：先缩到视口、抗锯齿在视口尺寸做（来源尺寸的中间图 5120×2880 约 200 MB / 槽），再 RCAS。
// 截图 / 抓图（shot、grab_present，present_encode 的 3 号槽）不过 FSR：照旧是「抗锯齿（若开）+ 双线性」那张图，口径与选 Bilinear 时逐字节相同。
// 出图补帧（nvn_present_fi.inc）接手的帧：真帧与补出的帧各自过 FSR（4 / 5 号槽，挂在那一代补帧对象上，槽的空闲由那一代自己的命令槽信号量保证；
//   补帧对象重建时旧的一代的图延后释放，见 NvPresentFSR 的 dealloc）；补帧路径本来就不做抗锯齿，这里也不做。
// 做不了（着色器 / 管线建不出、图 / 缓冲 / 参数表分配失败）：报红一次（206 / 207），这一帧起照旧双线性。
#include <math.h>

static float g_present_fsr_level = 80;   // Ryujinx ScalingFilterLevel
static float g_present_fsr_con;          // FsrRcasCon：exp2(−档数)
enum { FSR_SLOT_FI_MID = 4, FSR_SLOT_FI_REAL = 5, FSR_SLOTS = 6 };   // 0–2 出图槽；3 抓图（不过 FSR，不建）；4 / 5 出图补帧的补出帧 / 真帧

// S2A_SCALING_FILTER_LEVEL：0…100 的整数；返回 -1 = 非法
static int present_fsr_level_parse(const char *e) {
    if (!e || !*e) return -1;
    int v = 0;
    for (const char *p = e; *p; p++) { if (*p < '0' || *p > '9' || p - e >= 3) return -1; v = v * 10 + (*p - '0'); }
    return v <= 100 ? v : -1;
}
static float present_fsr_stops(float level) { if (level < 0.01f) level = 0.01f; return 1.5f - (level * 0.01f * 1.5f); }   // FsrScalingFilter.cs：Level 下限 0.01；1.5f - (Level * 0.01f * 1.5f)
// 起局（mtl_init）就核：滤镜选了 Fsr、级别又非法，不等第一次上屏。滤镜值本身的合法性照旧由 present_options 在首次上屏编码时核（上游行为，不动）
static void present_fsr_env_check(void) {
    const char *f = getenv("S2A_SCALING_FILTER"), *e = getenv("S2A_SCALING_FILTER_LEVEL");
    if (f && !strcmp(f, "Fsr") && e && present_fsr_level_parse(e) < 0) MDIE("【红】 invalid S2A_SCALING_FILTER_LEVEL=%s（只接受 0–100 的整数）", e);
}
static void present_fsr_options(void) {   // present_options 认出 Fsr 时调一次
    const char *e = getenv("S2A_SCALING_FILTER_LEVEL");
    if (e) { int v = present_fsr_level_parse(e); if (v < 0) MDIE("【红】 invalid S2A_SCALING_FILTER_LEVEL=%s（只接受 0–100 的整数）", e); g_present_fsr_level = (float)v; }
    float stops = present_fsr_stops(g_present_fsr_level);
    g_present_fsr_con = exp2f(-stops);
    MLOG("直连上屏 FSR 1：EASU 放大 + RCAS 锐化，锐化级别 %.0f（S2A_SCALING_FILTER_LEVEL %s；RCAS 衰减 %.3f 档，系数 %.4f）", g_present_fsr_level, e ? "给的" : "没给，缺省 80", stops, g_present_fsr_con);
}

// 着色器源码。开头的版权与许可声明随源码字符串编进二进制（MIT：声明要跟着每一份拷贝走）
static const char k_present_fsr_msl[] =
    "// AMD FidelityFX Super Resolution 1.0 (EASU + RCAS), ported to the Metal Shading Language from ffx_a.h / ffx_fsr1.h as\n"
    "// embedded in Ryujinx (Ryujinx.Graphics.Vulkan/Effects/Shaders/FsrScaling.glsl, FsrSharpening.glsl).\n"
    "//\n"
    "// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.\n"
    "// Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    "// of this software and associated documentation files(the \"Software\"), to deal\n"
    "// in the Software without restriction, including without limitation the rights\n"
    "// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell\n"
    "// copies of the Software, and to permit persons to whom the Software is\n"
    "// furnished to do so, subject to the following conditions :\n"
    "// The above copyright notice and this permission notice shall be included in\n"
    "// all copies or substantial portions of the Software.\n"
    "// THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
    "// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
    "// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE\n"
    "// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
    "// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
    "// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN\n"
    "// THE SOFTWARE.\n"
    "//\n"
    "// MIT LICENSE\n"
    "// Copyright (c) 2014 Michal Drobot (for concepts used in \"FLOAT APPROXIMATIONS\").\n"
    "// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation\n"
    "// files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy,\n"
    "// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the\n"
    "// Software is furnished to do so, subject to the following conditions:\n"
    "// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the\n"
    "// Software.\n"
    "// THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE\n"
    "// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR\n"
    "// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,\n"
    "// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n"
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V fsr_vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    // ffx_a.h
    "static float APrxLoRcpF1(float a) { return as_type<float>(uint(0x7ef07ebb) - as_type<uint>(a)); }\n"
    "static float APrxLoRsqF1(float a) { return as_type<float>(uint(0x5f347d74) - (as_type<uint>(a) >> uint(1))); }\n"
    "static float APrxMedRcpF1(float a) { float b = as_type<float>(uint(0x7ef19fff) - as_type<uint>(a)); return b * (-b * a + 2.0); }\n"
    // 面积缩小（来源超过视口 1.25 倍时代替 EASU）：4 个双线性样本，偏移 ±1/4 输出像素；裁剪 / 翻转 / 钳边同 present_blit 的 Crop
    "struct Down { float4 rect; float4 edge; float4 tap; };\n"
    "fragment float4 fsr_down(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Down& c [[buffer(0)]]) {\n"
    "  float2 uv = in.uv * c.rect.zw + c.rect.xy;\n"
    "  float3 a = t.sample(s, clamp(uv + c.tap.xy * float2(-1, -1), c.edge.xy, c.edge.zw)).rgb;\n"
    "  a += t.sample(s, clamp(uv + c.tap.xy * float2( 1, -1), c.edge.xy, c.edge.zw)).rgb;\n"
    "  a += t.sample(s, clamp(uv + c.tap.xy * float2(-1,  1), c.edge.xy, c.edge.zw)).rgb;\n"
    "  a += t.sample(s, clamp(uv + c.tap.xy * float2( 1,  1), c.edge.xy, c.edge.zw)).rgb;\n"
    "  return float4(a * 0.25, 1); }\n"
    // EASU。con0 = FsrEasuCon 的 con0（con1–con3 只是四次 gather 的位置，直接读纹素用不着）；src = 画面在来源里的矩形（x, y, w, h，纹素）；flip.x = 来源上下颠倒存
    "struct Easu { float4 con0; int4 src; int4 flip; };\n"
    "static float3 fsr_load(texture2d<float> t, constant Easu& c, int2 q) {\n"
    "  q = clamp(q, int2(0), c.src.zw - 1);\n"
    "  if (c.flip.x != 0) q.y = c.src.w - 1 - q.y;\n"
    "  return t.read(uint2(q + c.src.xy)).rgb; }\n"
    "static void FsrEasuTapF(thread float3& aC, thread float& aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {\n"
    "  float2 v;\n"
    "  v.x = (off.x * ( dir.x)) + (off.y * dir.y);\n"
    "  v.y = (off.x * (-dir.y)) + (off.y * dir.x);\n"
    "  v *= len;\n"
    "  float d2 = v.x * v.x + v.y * v.y;\n"
    "  d2 = min(d2, clp);\n"
    "  float wB = float(2.0 / 5.0) * d2 + float(-1.0);\n"
    "  float wA = lob * d2 + float(-1.0);\n"
    "  wB *= wB;\n"
    "  wA *= wA;\n"
    "  wB = float(25.0 / 16.0) * wB + float(-(25.0 / 16.0 - 1.0));\n"
    "  float w = wB * wA;\n"
    "  aC += c * w; aW += w; }\n"
    // w：这个 2x2 角的双线性权（原式由四个布尔挑出 (1-x)(1-y) / x(1-y) / (1-x)y / xy）
    "static void FsrEasuSetF(thread float2& dir, thread float& len, float w, float lA, float lB, float lC, float lD, float lE) {\n"
    "  float dc = lD - lC;\n"
    "  float cb = lC - lB;\n"
    "  float lenX = max(abs(dc), abs(cb));\n"
    "  lenX = APrxLoRcpF1(lenX);\n"
    "  float dirX = lD - lB;\n"
    "  dir.x += dirX * w;\n"
    "  lenX = saturate(abs(dirX) * lenX);\n"
    "  lenX *= lenX;\n"
    "  len += lenX * w;\n"
    "  float ec = lE - lC;\n"
    "  float ca = lC - lA;\n"
    "  float lenY = max(abs(ec), abs(ca));\n"
    "  lenY = APrxLoRcpF1(lenY);\n"
    "  float dirY = lE - lA;\n"
    "  dir.y += dirY * w;\n"
    "  lenY = saturate(abs(dirY) * lenY);\n"
    "  lenY *= lenY;\n"
    "  len += lenY * w; }\n"
    "fragment float4 fsr_easu(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant Easu& c [[buffer(0)]]) {\n"
    "  float2 pp = floor(in.p.xy) * c.con0.xy + c.con0.zw;\n"
    "  float2 fp = floor(pp);\n"
    "  pp -= fp;\n"
    "  int2 sp = int2(fp);\n"
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    "  float3 b = fsr_load(t, c, sp + int2(0, -1)), cc = fsr_load(t, c, sp + int2(1, -1));\n"
    "  float3 e = fsr_load(t, c, sp + int2(-1, 0)), f = fsr_load(t, c, sp), g = fsr_load(t, c, sp + int2(1, 0)), h = fsr_load(t, c, sp + int2(2, 0));\n"
    "  float3 i = fsr_load(t, c, sp + int2(-1, 1)), j = fsr_load(t, c, sp + int2(0, 1)), k = fsr_load(t, c, sp + int2(1, 1)), l = fsr_load(t, c, sp + int2(2, 1));\n"
    "  float3 n = fsr_load(t, c, sp + int2(0, 2)), o = fsr_load(t, c, sp + int2(1, 2));\n"
    "  float bL = b.b * 0.5 + (b.r * 0.5 + b.g), cL = cc.b * 0.5 + (cc.r * 0.5 + cc.g);\n"
    "  float eL = e.b * 0.5 + (e.r * 0.5 + e.g), fL = f.b * 0.5 + (f.r * 0.5 + f.g), gL = g.b * 0.5 + (g.r * 0.5 + g.g), hL = h.b * 0.5 + (h.r * 0.5 + h.g);\n"
    "  float iL = i.b * 0.5 + (i.r * 0.5 + i.g), jL = j.b * 0.5 + (j.r * 0.5 + j.g), kL = k.b * 0.5 + (k.r * 0.5 + k.g), lL = l.b * 0.5 + (l.r * 0.5 + l.g);\n"
    "  float nL = n.b * 0.5 + (n.r * 0.5 + n.g), oL = o.b * 0.5 + (o.r * 0.5 + o.g);\n"
    "  float2 dir = float2(0.0);\n"
    "  float len = 0.0;\n"
    "  FsrEasuSetF(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);\n"
    "  FsrEasuSetF(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);\n"
    "  FsrEasuSetF(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);\n"
    "  FsrEasuSetF(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);\n"
    "  float2 dir2 = dir * dir;\n"
    "  float dirR = dir2.x + dir2.y;\n"
    "  bool zro = dirR < float(1.0 / 32768.0);\n"
    "  dirR = APrxLoRsqF1(dirR);\n"
    "  dirR = zro ? 1.0 : dirR;\n"
    "  dir.x = zro ? 1.0 : dir.x;\n"
    "  dir *= float2(dirR);\n"
    "  len = len * 0.5;\n"
    "  len *= len;\n"
    "  float stretch = (dir.x * dir.x + dir.y * dir.y) * APrxLoRcpF1(max(abs(dir.x), abs(dir.y)));\n"
    "  float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 + -0.5 * len);\n"
    "  float lob = 0.5 + float((1.0 / 4.0 - 0.04) - 0.5) * len;\n"
    "  float clp = APrxLoRcpF1(lob);\n"
    "  float3 min4 = min(min(min(f, g), j), k);\n"
    "  float3 max4 = max(max(max(f, g), j), k);\n"
    "  float3 aC = float3(0.0);\n"
    "  float aW = 0.0;\n"
    "  FsrEasuTapF(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, b);\n"
    "  FsrEasuTapF(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, cc);\n"
    "  FsrEasuTapF(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, i);\n"
    "  FsrEasuTapF(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, j);\n"
    "  FsrEasuTapF(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, f);\n"
    "  FsrEasuTapF(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, e);\n"
    "  FsrEasuTapF(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, k);\n"
    "  FsrEasuTapF(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, l);\n"
    "  FsrEasuTapF(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, h);\n"
    "  FsrEasuTapF(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, g);\n"
    "  FsrEasuTapF(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, o);\n"
    "  FsrEasuTapF(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, n);\n"
    "  return float4(min(max4, max(min4, aC * float3(1.0 / aW))), 1.0); }\n"
    // RCAS。con.x = FsrRcasCon 的 exp2(-sharpness)。fmax / fmin：一边是 NaN 取另一边（见文件头第 3 条）
    "struct Rcas { float4 con; };\n"
    "fragment float4 fsr_rcas(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant Rcas& c [[buffer(0)]]) {\n"
    "  int2 sp = int2(in.p.xy), hi = int2(int(t.get_width()), int(t.get_height())) - 1;\n"
    //    b
    //  d e f
    //    h
    "  float3 b = t.read(uint2(clamp(sp + int2( 0, -1), int2(0), hi))).rgb;\n"
    "  float3 d = t.read(uint2(clamp(sp + int2(-1,  0), int2(0), hi))).rgb;\n"
    "  float3 e = t.read(uint2(clamp(sp, int2(0), hi))).rgb;\n"
    "  float3 f = t.read(uint2(clamp(sp + int2( 1,  0), int2(0), hi))).rgb;\n"
    "  float3 h = t.read(uint2(clamp(sp + int2( 0,  1), int2(0), hi))).rgb;\n"
    "  float3 mn4 = fmin(fmin(fmin(b, d), f), h);\n"
    "  float3 mx4 = fmax(fmax(fmax(b, d), f), h);\n"
    "  float2 peakC = float2(1.0, -1.0 * 4.0);\n"
    "  float3 hitMin = fmin(mn4, e) * (float3(1.0) / (float3(4.0) * mx4));\n"
    "  float3 hitMax = (peakC.x - fmax(mx4, e)) * (float3(1.0) / (float3(4.0) * mn4 + peakC.y));\n"
    "  float3 lobe3 = fmax(-hitMin, hitMax);\n"
    "  float lobe = fmax(float(-(0.25 - (1.0 / 16.0))), fmin(fmax(lobe3.r, fmax(lobe3.g, lobe3.b)), 0.0)) * c.con.x;\n"
    "  float rcpL = APrxMedRcpF1(4.0 * lobe + 1.0);\n"
    "  return float4((lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL, 1.0); }\n";

static pthread_mutex_t g_fsr_mu = PTHREAD_MUTEX_INITIALIZER;   // 管线的一次性建立、尺寸记录：出图线程与补帧队列都会进来
static id<MTLRenderPipelineState> g_fsr_pso[3];   // 0 面积缩小 1 EASU 2 RCAS（目标都是 BGRA8Unorm 的中间图）
static int g_fsr_state;                           // 0 没建过 1 好了 -1 建不出（已报红，不再试）
// 关快速数学：RCAS 的式子要 IEEE 的 NaN（文件头第 3 条）；顺带让 GPU 与 CPU 参考的逐像素差只剩舍入
static id<MTLLibrary> present_fsr_library(const char *src, NSError **e) {
    MTLCompileOptions *co = [MTLCompileOptions new]; co.mathMode = MTLMathModeSafe;
    return [g_dev newLibraryWithSource:@(src) options:co error:e];
}
static id<MTLRenderPipelineState> present_fsr_pso(id<MTLLibrary> lib, NSString *fs, NSError **e) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"fsr_vs"]; pd.fragmentFunction = [lib newFunctionWithName:fs];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (!pd.vertexFunction || !pd.fragmentFunction) return nil;
    return [g_dev newRenderPipelineStateWithDescriptor:pd error:e];
}
static int present_fsr_pipelines(void) {
    pthread_mutex_lock(&g_fsr_mu);
    if (!g_fsr_state) {
        NSError *e = nil; id<MTLLibrary> lib = present_fsr_library(k_present_fsr_msl, &e);
        NSString *names[3] = {@"fsr_down", @"fsr_easu", @"fsr_rcas"}; int ok = lib != nil;
        for (int i = 0; ok && i < 3; i++) { g_fsr_pso[i] = present_fsr_pso(lib, names[i], &e); ok = g_fsr_pso[i] != nil; }
        if (!ok) RED_ONCE(207, "FSR：着色器 / 管线建不出（%s），上屏照旧双线性", e ? e.localizedDescription.UTF8String : "函数缺失");
        g_fsr_state = ok ? 1 : -1;
    }
    int r = g_fsr_state > 0;
    pthread_mutex_unlock(&g_fsr_mu);
    return r;
}

@interface NvPresentFSR : NSObject {
@public
    id<MTLTexture> mid, output;    // mid：EASU 的输出，或面积缩小的落点（开着抗锯齿又走面积缩小时落点是抗锯齿的输入图，不建它）；output：RCAS 的输出
    id<MTLBuffer> con[2];          // Metal 4：两遍各自的常量（同一命令缓冲里不能共用一份）
    id tab[2];
    NSUInteger ow, oh; BOOL m4, has_mid;
    NSArray<id<MTLResource>> *resources;
    BOOL busy;                     // g_pq_mu 护；只由 GPU 完成回调清（0–2 号槽；4 / 5 号槽由补帧的命令槽信号量保证空闲，不用它）
    BOOL owned;                    // 挂在某一代补帧对象上（4 / 5 号槽）：随那一代释放，图等用过它的提交做完再出驻留集
}
@end
@implementation NvPresentFSR
// 补帧对象整个重建（游戏画面尺寸变了，fi_get）时旧的一代被放掉，它最后那两次上屏提交可能还在 GPU 上：图不能当场出驻留集（Metal 4 的命令缓冲不保留资源），
//   交给 defer_obj_release——下一次游戏提交做完才摘（同一条命令队列先进先出，那时这一代的提交都已做完）
- (void)dealloc { if (owned) for (id<MTLResource> r in resources) defer_obj_release(r); }
@end
static NvPresentFSR *g_present_fsr_slots[FSR_SLOTS];   // 0–2 出图槽。4 / 5（出图补帧）不放这里：挂在那一代补帧对象上（present_fsr_slot_get）
// 出图补帧的两个槽按「代」归属：补帧对象重建时新旧两代各有自己的一组命令槽信号量，旧的一代还可能有任务在跑（旧输入拷贝的完成回调里才派任务）、
//   有提交在途。两代共用一份全局槽的话，新的一代会改写 / 重建旧的一代还在用的图和常量缓冲。挂在 owner（NvPresentFI）上，各用各的：
//   同一代里 4 号槽只被 1 号命令槽用、5 号只被 2 号用，那个命令槽的信号量保证上一次提交做完才编下一次
static char g_fsr_owner_key[2];
static NvPresentFSR *present_fsr_slot_get(int slot, id owner) { return owner ? objc_getAssociatedObject(owner, &g_fsr_owner_key[slot - FSR_SLOT_FI_MID]) : g_present_fsr_slots[slot]; }
static void present_fsr_slot_set(int slot, id owner, NvPresentFSR *f) {
    if (owner) objc_setAssociatedObject(owner, &g_fsr_owner_key[slot - FSR_SLOT_FI_MID], f, OBJC_ASSOCIATION_RETAIN); else g_present_fsr_slots[slot] = f;
}
// 本槽的两张图（尺寸 / 后端变了才重建）；nil = 分配不出（已报红）。调用方已等过本槽上一次提交做完
static NvPresentFSR *present_fsr_prepare(int slot, id owner, NSUInteger ow, NSUInteger oh, BOOL m4, BOOL need_mid) {
    NvPresentFSR *old = present_fsr_slot_get(slot, owner);
    if (old && old->ow == ow && old->oh == oh && old->m4 == m4 && (old->has_mid || !need_mid)) return old;
    static NSUInteger fail_w[FSR_SLOTS], fail_h[FSR_SLOTS];   // 这个尺寸分配失败过：不逐帧重试
    if (fail_w[slot] == ow && fail_h[slot] == oh) return nil;
    NvPresentFSR *f = [NvPresentFSR new];
    f->ow = ow; f->oh = oh; f->m4 = m4; f->has_mid = need_mid; f->owned = owner != nil;
    NSMutableArray *res = [NSMutableArray array]; int ok = 1;
    f->output = present_aa_texture(MTLPixelFormatBGRA8Unorm, ow, oh, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    if (f->output) [res addObject:f->output]; else ok = 0;
    if (need_mid) { f->mid = present_aa_texture(MTLPixelFormatBGRA8Unorm, ow, oh, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget); if (f->mid) [res addObject:f->mid]; else ok = 0; }
    NSError *error = nil;
    for (int i = 0; ok && m4 && i < 2; i++) {
        f->con[i] = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; f->tab[i] = tab_new(1, 1, 1, &error);
        if (f->con[i]) [res addObject:f->con[i]];
        if (!f->con[i] || !f->tab[i]) ok = 0;
    }
    if (!ok) { RED_ONCE(208, "FSR：图 / 缓冲 / 参数表分配失败（视口 %lux%lu%s%s），上屏照旧双线性", (unsigned long)ow, (unsigned long)oh, error ? "：" : "", error ? error.localizedDescription.UTF8String : ""); fail_w[slot] = ow; fail_h[slot] = oh; return nil; }
    if (old) { for (id<MTLResource> r in old->resources) res_remove(r); old->resources = nil; }   // 本槽空闲（见上）：当场摘
    f->resources = res;
    for (id<MTLResource> r in res) res_add(r);
    present_fsr_slot_set(slot, owner, f);
    return f;
}
// 每种「来源 → 视口」的组合首次出现记一行（真机上据此确认 FSR 在跑、走的是哪条路）
static void present_fsr_note(NSUInteger cw, NSUInteger ch, NSUInteger ow, NSUInteger oh, BOOL down, BOOL aa, BOOL m4, int slot) {
    enum { N = 16 }; static uint64_t seen[N][5]; static int n;
    uint64_t key[5] = {cw, ch, ow, oh, (uint64_t)(down | aa << 1 | m4 << 2 | (slot >= FSR_SLOT_FI_MID) << 3)};
    pthread_mutex_lock(&g_fsr_mu);
    int hit = 0; for (int i = 0; i < n && !hit; i++) hit = !memcmp(seen[i], key, sizeof key);
    int add = !hit && n < N;   // 记满 16 种之后的新组合不记也不打（否则逐帧刷日志）
    if (add) memcpy(seen[n++], key, sizeof key);
    int full = add && n == N;
    pthread_mutex_unlock(&g_fsr_mu);
    if (!add) return;
    MLOG("直连上屏 FSR：%lux%lu → %lux%lu，%s（%s%s%s）%s", (unsigned long)cw, (unsigned long)ch, (unsigned long)ow, (unsigned long)oh,
         down ? (aa ? "面积缩小 → 抗锯齿 → RCAS（来源超过视口 1.25 倍，不走 EASU）" : "面积缩小 → RCAS（来源超过视口 1.25 倍，不走 EASU）") : aa ? "抗锯齿 → EASU → RCAS" : "EASU → RCAS",
         m4 ? "Metal 4" : "Metal 3", slot >= FSR_SLOT_FI_MID ? "，出图补帧" : "", slot == FSR_SLOT_FI_MID ? "的补出帧" : slot == FSR_SLOT_FI_REAL ? "的真帧" : "",
         full ? "；尺寸组合已记满 16 种，之后的不再记" : "");
}

// 一遍全屏三角：tex 经 pso 画进 dst，con 是这一遍的常量。vp = NULL：画满整张（中间图）；给了 vp：只画这块视口、其余清成黑（最后那次上屏）
static int present_fsr_pass3(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> pso, id<MTLTexture> tex, id<MTLTexture> dst, const void *con, size_t n, const pf_vp *vp) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    int bars = vp && !(vp->x == 0 && vp->y == 0 && vp->w == (double)dst.width && vp->h == (double)dst.height);
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = bars ? MTLLoadActionClear : MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    if (!en) { MLOG("【红】 FSR：建不出渲染编码器（Metal 3）"); return 0; }
    if (vp) [en setViewport:(MTLViewport){vp->x, vp->y, vp->w, vp->h, 0, 1}];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:tex atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
    [en setFragmentBytes:con length:n atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [en endEncoding];
    return 1;
}
API_AVAILABLE(macos(26.0), ios(26.0)) static inline id m4_render_on(id cb, id d);   // nvn_mtl.m，定义在本文件之后
API_AVAILABLE(macos(26.0), ios(26.0))
static int present_fsr_pass4(id cb, id<MTLRenderPipelineState> pso, id<MTLTexture> tex, id<MTLTexture> dst, const void *con, size_t n, id<MTLBuffer> buf, id table, const pf_vp *vp) {
    id rp = pass_desc(); MTLRenderPassColorAttachmentDescriptor *ca = [rp colorAttachments][0];
    int bars = vp && !(vp->x == 0 && vp->y == 0 && vp->w == (double)dst.width && vp->h == (double)dst.height);
    ca.texture = dst; ca.loadAction = bars ? MTLLoadActionClear : MTLLoadActionDontCare; ca.storeAction = MTLStoreActionStore; ca.clearColor = MTLClearColorMake(0, 0, 0, 1);
    id en = m4_render_on(cb, rp);
    if (!en) { MLOG("【红】 FSR：建不出渲染编码器（Metal 4）"); return 0; }
    enc_full_barrier_begin(en);
    enc_r_table(en, table, MTLRenderStageFragment);
    tab_tex(table, tex, 0); tab_samp(table, g_blit_samp, 0);
    memcpy(buf.contents, con, n); tab_buf(table, buf, 0, 0);
    if (vp) [en setViewport:(MTLViewport){vp->x, vp->y, vp->w, vp->h, 0, 1}];
    [en setRenderPipelineState:pso];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    enc_end_on(en, YES);
    return 1;
}
typedef struct { float con0[4]; int32_t src[4]; int32_t flip[4]; } fsr_easu_con;
typedef struct { float rect[4], edge[4], tap[4]; } fsr_down_con;
typedef struct { float con[4]; } fsr_rcas_con;
// FsrEasuCon 的 con0：输入视口 iw×ih（= 输入图大小），输出 ow×oh
static void present_fsr_easu_con0(float con0[4], NSUInteger iw, NSUInteger ih, NSUInteger ow, NSUInteger oh) {
    con0[0] = (float)iw * (1.0f / (float)ow);
    con0[1] = (float)ih * (1.0f / (float)oh);
    con0[2] = 0.5f * (float)iw * (1.0f / (float)ow) - 0.5f;
    con0[3] = 0.5f * (float)ih * (1.0f / (float)oh) - 0.5f;
}
// 来源比视口大出 1.25 倍以上（两轴都不小于视口、任一轴超过）：走面积缩小，不走 EASU（文件头第 4 条）
static int present_fsr_down(NSUInteger cw, NSUInteger ch, NSUInteger ow, NSUInteger oh) { return cw >= ow && ch >= oh && (cw * 4 > ow * 5 || ch * 4 > oh * 5); }

// src（裁剪 crop、可上下颠倒）过 FSR 画进 dst。返回 1 = 编好了；0 = 编码失败（这一帧不上屏，同原路径的 0）；-1 = FSR 做不了（已报红，或裁剪非法：调用方照原路径走）。
//   aa：这条路上要不要先做抗锯齿（出图补帧的两个槽传 0）。uvb / table：Metal 4 最后那次 1:1 上屏拷贝用的裁剪参数缓冲与参数表（Metal 3 传 nil）。
//   owner：出图补帧的两个槽传这一代的补帧对象（槽挂在它上面，present_fsr_slot_get）；出图槽传 nil
static int present_fsr_encode(id cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], int slot, BOOL flip, BOOL m4, int aa, id<MTLBuffer> uvb, id table, id owner) {
    NSUInteger cx = 0, cy = 0, cw = src.width, ch = src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0] < 0 || crop[1] < 0 || crop[2] <= 0 || crop[3] <= 0 || (uint64_t)crop[0] + crop[2] > src.width || (uint64_t)crop[1] + crop[3] > src.height) return -1;   // present_blit 照旧报红
        cx = crop[0]; cy = crop[1]; cw = crop[2]; ch = crop[3];
    }
    if (m4) { if (@available(macOS 26.0, iOS 26.0, *)) {} else return -1; }
    double ca = s2a_cpatch_present_aspect();   // 自适应画幅补丁开着：视口按当前画幅拉满（同 present_blit / present_fx_for）
    pf_vp pv = ca > 0 ? pf_viewport(dst.width, dst.height, ca, 1) : pf_viewport(dst.width, dst.height, cw, ch);
    NSUInteger ow = (NSUInteger)pv.w, oh = (NSUInteger)pv.h;
    if (!ow || !oh || !present_fsr_pipelines()) return -1;
    BOOL down = present_fsr_down(cw, ch, ow, oh) != 0;
    if ((owner != nil) != (slot >= FSR_SLOT_FI_MID)) return -1;   // 补帧的槽必须带它那一代的对象，出图槽不带
    NvPresentFSR *f = present_fsr_prepare(slot, owner, ow, oh, m4, !(down && aa));
    if (!f) return -1;
    present_pipeline(dst.pixelFormat);   // g_blit_samp（面积缩小的取样器；另两遍不取样）
    NvPresentAA *s = nil; int ac[4] = {0, 0, (int)ow, (int)oh};
    if (aa && !(s = present_aa_prepare(slot, src, down ? ac : crop))) return 0;   // 抗锯齿自己建不出：同原路径，这一帧不上（它已报红）
    present_fsr_note(cw, ch, ow, oh, down, aa != 0, m4, slot);
    id<MTLTexture> raw = present_raw_src(src), img;
    #define FSR_PASS(k, pso, tex, to, c) (m4 ? ({ int r_ = 0; if (@available(macOS 26.0, iOS 26.0, *)) r_ = present_fsr_pass4(cb, pso, tex, to, &(c), sizeof(c), f->con[k], f->tab[k], NULL); r_; }) : present_fsr_pass3(cb, pso, tex, to, &(c), sizeof(c), NULL))
    if (down) {
        // 面积缩小：来源 → 视口尺寸（开着抗锯齿就落在抗锯齿的输入图上，抗锯齿在视口尺寸做）
        fsr_down_con d = {{(float)cx / src.width, (float)cy / src.height, (float)cw / src.width, (float)ch / src.height},
                          {(cx + 0.5f) / src.width, (cy + 0.5f) / src.height, (cx + cw - 0.5f) / src.width, (cy + ch - 0.5f) / src.height},
                          {0.25f * (float)cw / ((float)src.width * (float)ow), 0.25f * (float)ch / ((float)src.height * (float)oh), 0, 0}};
        if (flip) { d.rect[1] += d.rect[3]; d.rect[3] = -d.rect[3]; }
        id<MTLTexture> to = s ? s->input : f->mid;
        if (!FSR_PASS(0, g_fsr_pso[0], raw, to, d)) return 0;
        if (s && !present_aa_encode(cb, s, m4)) return 0;
        img = s ? s->output : to;
    } else {
        fsr_easu_con e = {{0}, {(int32_t)cx, (int32_t)cy, (int32_t)cw, (int32_t)ch}, {flip ? 1 : 0, 0, 0, 0}};
        present_fsr_easu_con0(e.con0, cw, ch, ow, oh);
        id<MTLTexture> from = raw;
        if (s) {   // 先抗锯齿（来源尺寸）：裁剪 / 翻转由抗锯齿的输入拷贝做掉，EASU 读它的输出
            int ok = m4 ? present_blit_m4(cb, src, s->input, crop, s->cropUV, s->cropTable, flip, 0) : present_blit(cb, src, s->input, crop, flip, 0);
            if (!ok || !present_aa_encode(cb, s, m4)) return 0;
            from = s->output; e.src[0] = e.src[1] = 0; e.flip[0] = 0;
        }
        if (!FSR_PASS(0, g_fsr_pso[1], from, f->mid, e)) return 0;
        img = f->mid;
    }
    fsr_rcas_con r = {{g_present_fsr_con, 0, 0, 0}};
    if (!FSR_PASS(1, g_fsr_pso[2], img, f->output, r)) return 0;
    #undef FSR_PASS
    // 视口尺寸的结果 1:1 拷进画布，就用上面算出的那个视口。不经 present_blit：它会拿取整后的 ow×oh 再算一次视口，画幅差落在 1% 判据边上时两次结果不同
    //   （1267×720 → 1920×1080：头一次 9,0 1901×1080，再算一次 1920/1080 ÷ 1901/1080 = 1.00999 就成了铺满，画面被拉宽）。着色器与取样器是上屏拷贝的那一套，
    //   present crop / present viewport 两行日志照它的格式记（真机屏幕级验收 screen_check.py 读后一行）
    id<MTLRenderPipelineState> blit_pso = present_pso(dst.pixelFormat);   // PR3c 按目标格式取槽：旧单槽时上面抗锯齿的输入拷贝（BGRA8 中间图）会把 g_blit_pso 换成中间图格式的、这里要重建回画布格式——多槽后两格式并存互不挤占
    if (!blit_pso) return 0;   // 死槽防御（HDR 槽建不出、负缓存）：present_now 已把层回退 SDR 基线，正常路径到不了这里
    { static uint64_t last[10]; uint64_t meta[10] = {src.width, src.height, cx, cy, cw, ch, dst.width, dst.height, (uint64_t)pv.x << 32 | (uint64_t)pv.y, (uint64_t)pv.w << 32 | (uint64_t)pv.h};
      pthread_mutex_lock(&g_fsr_mu); int changed = memcmp(meta, last, sizeof meta) != 0; if (changed) memcpy(last, meta, sizeof meta); pthread_mutex_unlock(&g_fsr_mu);
      if (changed) { MLOG("present crop: source texture %lux%lu, valid %lu,%lu %lux%lu → target %lux%lu", (unsigned long)src.width, (unsigned long)src.height,
                          (unsigned long)cx, (unsigned long)cy, (unsigned long)cw, (unsigned long)ch, (unsigned long)dst.width, (unsigned long)dst.height);
                     MLOG("present viewport %.0f,%.0f %.0fx%.0f / canvas %.0fx%.0f (game image %lux%lu)", pv.x, pv.y, pv.w, pv.h, (double)dst.width, (double)dst.height, (unsigned long)src.width, (unsigned long)src.height); } }
    // 末段走上屏拷贝的着色器（Crop：rect / edge / mode / xf 共 16 浮点）：后 8 个是 HDR 上屏模式参数，与 present_blit 同一份填法；
    //   只给前 8 个时 Metal 3 校验断言（片元参数 64 字节、只绑了 32），Metal 4 槽缓冲后半留着上一次上屏的旧参数
    float uv[16] = {0, 0, 1, 1, 0.5f / (float)ow, 0.5f / (float)oh, ((float)ow - 0.5f) / (float)ow, ((float)oh - 0.5f) / (float)oh};
    present_hdr_uv(uv + 8, src, dst, YES);
    if (m4) { int r_ = 0; if (@available(macOS 26.0, iOS 26.0, *)) r_ = present_fsr_pass4(cb, blit_pso, f->output, dst, uv, sizeof uv, uvb, table, &pv); return r_; }
    return present_fsr_pass3(cb, blit_pso, f->output, dst, uv, sizeof uv, &pv);
}
