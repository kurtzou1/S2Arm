// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 可编程混合（graphics/dsx/gal_colorround.c gal_color_round_pb_msl 门控版，#674）的文本面：每个 float4 颜色输出带开关常量与门控读入、return 前门控混合，
//   整数 / 没有颜色输出的不加；附件 0 的第二源取输出 1。期望手写；行为面（混合结果）由 t_pblend_gpu 在真 Metal 上核。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gal_colorround.h"

static int checks, fails;
#define CHECK(c, what) do { checks++; int ok_ = !!(c); fails += !ok_; printf("%s %s\n", ok_ ? "通" : "不通", what); } while (0)

#define HEAD "#include <metal_stdlib>\n\nusing namespace metal;\n\n"
static const char *k_fu = HEAD "struct main0_out\n{\n    float4 a [[color(0)]];\n    uint4 b [[color(1)]];\n};\n\n"
"fragment main0_out main0(float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n    out.a = float4(1.0);\n    out.b = uint4(2u);\n    return out;\n}\n\n";
static const char *k_ff = HEAD "struct main0_out\n{\n    float4 a [[color(0)]];\n    float4 b [[color(1)]];\n};\n\n"
"fragment main0_out main0(float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n    out.a = float4(1.0);\n    out.b = float4(0.5);\n    return out;\n}\n\n";
static const char *k_u = HEAD "struct main0_out\n{\n    uint4 b [[color(0)]];\n};\n\n"
"fragment main0_out main0(float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n    out.b = uint4(2u);\n    return out;\n}\n\n";

static int count(const char *s, const char *w) { int n = 0; for (const char *q = strstr(s, w); q; q = strstr(q + 1, w)) n++; return n; }

int main(void) {
    char why[256];
    char *a = gal_color_round_pb_msl(k_fu, "main0", why);
    CHECK(a && count(a, "constant bool s2a_pb0_c [[function_constant(110)]];") == 1 && !strstr(a, "s2a_pb1_c"),
          "float 附件 0 + uint 附件 1：只给附件 0 开关常量（编号 110）");
    CHECK(a && count(a, "float4 s2a_dst0 [[color(0), function_constant(s2a_pb0)]]") == 1 && !strstr(a, "s2a_dst1"), "读入参数随常量门控、只有附件 0");
    CHECK(a && count(a, "if (s2a_pb0) out.a = s2a_pblend(out.a, s2a_dst0, float4(0.0f), s2a_pb, 0u);") == 1,
          "return 前门控混合一次；没有 float 输出 1 时第二源为 0");
    CHECK(a && count(a, "constant S2APBlend& s2a_pb [[buffer(27)]]") == 1 && !strstr(a, "s2a_half_mask") && count(a, "if (s2a_pb.mask & ") == 2,
          "27 号槽换成 S2APBlend、量化行读 s2a_pb.mask（附件 0 两行）");
    char *b = gal_color_round_pb_msl(k_ff, "main0", why);
    CHECK(b && count(b, "if (s2a_pb0) out.a = s2a_pblend(out.a, s2a_dst0, out.b, s2a_pb, 0u);") == 1 &&
          count(b, "if (s2a_pb1) out.b = s2a_pblend(out.b, s2a_dst1, float4(0.0f), s2a_pb, 1u);") == 1,
          "两个 float 输出：附件 0 的第二源取输出 1，附件 1 没有第二源");
    CHECK(b && strstr(b, "s2a_pblend(out.a") < strstr(b, "s2a_pblend(out.b"), "附件 0 先混合（取到输出 1 的原值）");
    char *c = gal_color_round_pb_msl(k_u, "main0", why);
    CHECK(c && !strcmp(c, k_u), "只有整数输出：原样不改");
    why[0] = 0; CHECK(a && !gal_color_round_pb_msl(a, "main0", why) && *why, "改写过的再改写：报错（27 号槽已占）");
    // gal 渲染器（gal_prog.m）的宿主在 27 号槽只绑 uint 位图、不做可编程混合：gal 版不带开关常量和 S2APBlend
    char *g = gal_color_round_msl(k_ff, "main0", why);
    CHECK(g && count(g, "constant uint& s2a_half_mask [[buffer(27)]]") == 1 && !strstr(g, "S2APBlend") && !strstr(g, "s2a_pb") &&
          count(g, "if (s2a_half_mask & ") == 4, "gal 版：27 号槽仍是 uint 位图、无可编程混合（两附件各两行量化）");
    free(a); free(b); free(c); free(g);
    printf("%s t_pblend_rewrite：%d 项，不通 %d\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
}
