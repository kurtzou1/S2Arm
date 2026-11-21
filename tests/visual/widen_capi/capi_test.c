// 宽屏核心 C 接口对拍（graphics/widen/export/s2a_widen.h，NativeAOT 发布版）。期望值全部手算：
//   屏幕宽 2346 → k = 2346/1920 = 1.221875（吸附后宽高比 2346/1080 = 2.172222）；透视投影 fovy 45°：P11 = 2.4142136、P00 = P11 ÷ (16/9) = 1.3579951 → 改写后 P00/k = 1.111403。
// 退出码 = 失败项数。
#include "s2a_widen.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails, total;
static void check(const char *name, int ok, const char *want, const char *got) {
    total++; if (!ok) fails++;
    printf("%s  %s：期望 %s → 真结果 %s\n", ok ? "过" : "【红】", name, want, got);
}
static void checki(const char *name, long want, long got) { char a[32], b[32]; snprintf(a, 32, "%ld", want); snprintf(b, 32, "%ld", got); check(name, want == got, a, b); }
static void checkf(const char *name, float want, float got) { char a[32], b[32]; snprintf(a, 32, "%.6f", want); snprintf(b, 32, "%.6f", got); check(name, fabsf(want - got) <= 1e-5f * fmaxf(1, fabsf(want)), a, b); }

static const float P00 = 1.3579951f, P11 = 2.4142136f, K = 2346.f / 1920.f;

int main(void) {
    // ---------- 只管界面层（动森形状） ----------
    checki("init：第二层生效 → 只管界面层（1）", S2A_WIDEN_UI, s2a_widen_init(2346, 1080, S2A_WIDEN_GAME));
    checkf("k = 2346/1920", K, s2a_widen_k());
    checki("界面层模式：渲染目标不放宽", 1568, s2a_widen_texture(2, 1568, 720, 1, S2A_WIDEN_USE_RT));
    s2a_widen_texture(1, 1920, 1080, 1, S2A_WIDEN_USE_RT);
    s2a_widen_texture(3, 600, 300, 1, S2A_WIDEN_USE_RT);

    s2a_widen_targets(1, 0);   // 快判（10-24）：界面层模式按视口判原生宽——1564×720（≈ 屏幕比）进核心，1280×720（16:9）与 1000×600 不进、区域里的小视口进
    checki("快判：视口 1564×720 → 进核心", 1, s2a_widen_viewport(0, 1564, 720, 1));
    checki("快判：视口 1280×720（16:9）→ 跳过", 0, s2a_widen_viewport(0, 1280, 720, 1));
    checki("快判：视口 600×300（落在已认出的 1564 区域里、宽高不过半 = 界面子视口）→ 进核心", 1, s2a_widen_viewport(0, 600, 300, 1));
    checki("快判：视口 1000×600（宽过半，不是子视口）→ 跳过", 0, s2a_widen_viewport(0, 1000, 600, 1));
    float *guest = aligned_alloc(256, 768); memset(guest, 0, 768);
    const float proj[16] = { P00, 0, 0, 0, 0, P11, 0, 0, 0, 0, -1.0002f, -0.20002f, 0, 0, -1, 0 };
    memcpy(guest, proj, sizeof proj);
    float *scratch = aligned_alloc(256, 768);
    int32_t hm = s2a_widen_shader(0, "0:0,1,2,3", 0), ho = s2a_widen_shader(0, "1:20", 0), hp = s2a_widen_shader(0, "1:20", S2A_WIDEN_SH_PUSH);
    check("着色器句柄 > 0", hm > 0 && ho > 0 && hp > 0, "> 0", hm > 0 ? "> 0" : "≤ 0");

    s2a_widen_draw_in in = { .vp_w = 600, .vp_h = 300, .target_scale = 1, .shader = { hm }, .flags = S2A_WIDEN_DRAW_COLOR };
    s2a_widen_draw_out out;
    s2a_widen_targets(3, 0); s2a_widen_cbuf_bind(0, 0, guest, 768);
    checki("离屏界面贴图（600×300 没放宽）→ 原样", S2A_WIDEN_KEEP, s2a_widen_draw(&in, &out));
    checki("  常量零拷贝（原值）", 0, s2a_widen_cbuf_emit(0, 0, scratch, 768));
    s2a_widen_tex atlas = { 7, 1024, 1024, 1, 0 };   // 界面层 / 读改写投影的层都采图集；不采贴图的纯色层见下「纯色全画布层」
    s2a_widen_targets(2, 0); s2a_widen_cbuf_bind(0, 0, guest, 768);
    in.vp_w = 1568; in.vp_h = 720; in.tex = &atlas; in.ntex = 1;
    checki("原生宽目标（1568×720）读到改写投影 → Hor", S2A_WIDEN_HOR, s2a_widen_draw(&in, &out));
    checki("  出数 1 处", 1, s2a_widen_cbuf_emit(0, 0, scratch, 768));
    checkf("  暂存区 [0] = P00/k", P00 / K, scratch[0]);
    checkf("  游戏内存 [0] 没被写", P00, guest[0]);
    checki("暂存区不够 → 0", 0, s2a_widen_cbuf_emit(0, 0, scratch, 64));

    // 规则 A：上屏 1 前最后一笔采样 2 → 出图目标 2；之后画 2：第一笔合成（ScaleK），第二笔没读改写矩阵 = 界面层原宽居中（x 142.5、宽 1283）
    s2a_widen_tex t2 = { 2, 1568, 720, 1, 0 };
    in.shader[0] = ho; in.tex = &t2; in.ntex = 1; in.vp_w = 1564;
    s2a_widen_targets(1, 0); s2a_widen_cbuf_bind(0, 1, guest, 768); s2a_widen_draw(&in, &out);
    s2a_widen_crop crop = { 0, 0, 0, 0, 0, 0 }; s2a_widen_present(1, &crop);
    in.tex = &atlas; in.ntex = 1; in.vp_w = 1568;
    s2a_widen_targets(2, 0);
    checki("规则 A：本帧第一次画出图目标 = 合成（ScaleK）", S2A_WIDEN_SCALEK, s2a_widen_draw(&in, &out));
    int m = s2a_widen_draw(&in, &out);
    float x = 0, w = 1568; s2a_widen_map_viewport(m, &x, &w);
    char got[64]; snprintf(got, 64, "%d %.1f %.0f", m, x, w);
    check("规则 A：第二笔界面层原宽居中", m == S2A_WIDEN_CENTER && fabsf(x - 142.5f) < 0.01f && fabsf(w - 1283) < 0.01f, "3 142.5 1283", got);
    // 纯色全画布层（不能外推、不采贴图）：按原样铺满——画法 KEEP、出数 0
    in.tex = NULL; in.ntex = 0;
    checki("纯色全画布层（不能外推）→ 原样（0）", S2A_WIDEN_KEEP, s2a_widen_draw(&in, &out));
    checki("  出数 0（原值）", 0, s2a_widen_cbuf_emit(0, 1, scratch, 768));
    checki("  画法输出标「出数全 0」（调用方可不调出数）", S2A_WIDEN_OUT_NO_EMIT, (int)(out.flags & S2A_WIDEN_OUT_NO_EMIT));
    {   // 出数状态版本（10-24）：绑定内容变了（扫描改了命中表）→ 版本变；同内容再绑 → 不变
        int64_t g0 = s2a_widen_state_gen(); s2a_widen_cbuf_bind(0, 1, guest, 768); int64_t g1 = s2a_widen_state_gen();
        float keep = guest[0]; guest[0] = P00 * 0.5f; s2a_widen_cbuf_bind(0, 1, guest, 768); int64_t g2 = s2a_widen_state_gen(); guest[0] = keep; s2a_widen_cbuf_bind(0, 1, guest, 768);
        checki("状态版本：同内容再绑 → 不变", 1, g1 == g0); checki("状态版本：内容变了 → 变", 1, g2 != g1);
    }
    // 收缩外推（顶点能外推、片元只采 8×8 小图）：Hor + 外推量 1 − 1/k、门限² ((1 − 0.003)/k)²、收缩量 1 − 1/k
    s2a_widen_tex small = { 9, 8, 8, 1, 0 };
    in.shader[0] = hp; in.tex = &small; in.ntex = 1;
    checki("收缩外推：原宽居中层改 Hor", S2A_WIDEN_HOR, s2a_widen_draw(&in, &out));
    float e = 0.997f / K;
    checkf("  push.x 外推量", 1 - 1 / K, out.push[0]); checkf("  push.y 门限²", e * e, out.push[1]); checkf("  push.z 收缩量", 1 - 1 / K, out.push[2]); checkf("  push.w", 0, out.push[3]);
    checkf("  片元倍率（原生宽目标）", 1, out.frag_scale_x);

    // 稳态零分配：前 2000 笔预热，再量 20000 笔（两个目标交替、两个槽绑定 / 出数、每 50 笔上屏一次）
    uint64_t a0 = 0;
    for (int i = 0; i < 22000; i++) {
        if (i == 2000) a0 = s2a_widen_alloc_bytes();
        int odd = i & 1;
        s2a_widen_targets(odd ? 3 : 2, 0);
        s2a_widen_cbuf_bind(0, 0, guest, 768); s2a_widen_cbuf_bind(0, 1, guest, 768);
        in.shader[0] = hm; in.tex = &t2; in.ntex = 1; in.vp_w = odd ? 600 : 1568; in.vp_h = odd ? 300 : 720;
        int mm = s2a_widen_draw(&in, &out);
        float vx = 0, vw = in.vp_w; s2a_widen_map_viewport(mm, &vx, &vw);
        int32_t sx = 0, sw = 1568; s2a_widen_map_scissor(mm, &sx, &sw);
        s2a_widen_cbuf_emit(0, 0, scratch, 768); s2a_widen_cbuf_emit(0, 1, scratch, 768);
        if (i % 50 == 49) s2a_widen_present(1, &crop);
    }
    checki("NativeAOT 发布版：稳态 20000 笔绘制托管分配字节", 0, (long)(s2a_widen_alloc_bytes() - a0));

    // ---------- 整套放宽 ----------
    checki("init：第三层表验过 → 整套放宽（2）", S2A_WIDEN_ALL, s2a_widen_init(2346, 1080, S2A_WIDEN_FULL));
    checki("1280×720 渲染目标放宽到 1280·k = 1564", 1564, s2a_widen_texture(5, 1280, 720, 1, S2A_WIDEN_USE_RT));
    checki("游戏内存池贴图（不带 RT）不放宽", 1280, s2a_widen_texture(6, 1280, 720, 1, 0));
    checki("第 1 级视图宽 = 1564 >> 1 = 782", 782, s2a_widen_view(7, 5, 1, 640));
    checki("拷贝区域换算 x 640 → round(640·1564/1280) = 782", 782, s2a_widen_map_x(5, 640));
    checki("派发组数：16×16 铺 80×45 → ⌈1564/16⌉ = 98", 98, s2a_widen_groups_x(80, 45, 1280, 1564, 720));
    s2a_widen_crop c2 = { 0, 1280, 0, 720, 16, 9 };
    s2a_widen_present(5, &c2);
    snprintf(got, 64, "%d %d %.4f", c2.left, c2.right, c2.aspect_x);
    check("上屏裁剪：右 1280 → 1564、宽高比 9 × 2.172222", c2.left == 0 && c2.right == 1564 && fabsf(c2.aspect_x - 9 * 2346.f / 1080.f) < 1e-3f, "0 1564 19.5500", got);
    checki("init：都没有 → 留黑边（3）", S2A_WIDEN_PILLAR, s2a_widen_init(2346, 1080, 0));
    checki("留黑边：上屏返回 1", 1, s2a_widen_present(0, NULL));
    checki("init：屏宽 1920 → 关（0）", S2A_WIDEN_OFF, s2a_widen_init(1920, 1080, S2A_WIDEN_GAME));

    char rep[4096]; s2a_widen_report(rep, sizeof rep); printf("%s\n", rep);
    {   // 报告按缓冲截断不切在 UTF-8 字符中间（报告含中文；host.log 留下半个汉字时，iOS 诊断包整份日志被解成乱码）。
        //   期望按 UTF-8 规则手写：每个缓冲大小取一次，结尾 0 之前是完整的 UTF-8（首字节说明的后续字节数都在），且是整行的前缀
        int full = (int)strlen(rep), bad_cap = 0, bad_pfx = 0;
        for (int cap = 1; cap <= full + 1; cap++) {
            char b[4096]; memset(b, 0x55, sizeof b); s2a_widen_report(b, cap);
            int n = (int)strlen(b), i = 0;
            if (n > cap - 1 || memcmp(b, rep, (size_t)n)) { bad_pfx = cap; break; }
            while (i < n) { unsigned char c = (unsigned char)b[i]; int k = c < 0x80 ? 1 : (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 0;
                if (!k || i + k > n) { bad_cap = cap; break; } for (int j = 1; j < k; j++) if (((unsigned char)b[i + j] & 0xC0) != 0x80) { bad_cap = cap; break; } if (bad_cap) break; i += k; }
            if (bad_cap) break;
        }
        char why[64]; snprintf(why, sizeof why, "整行 %d 字节；坏缓冲 %d / 非前缀 %d", full, bad_cap, bad_pfx);
        check("报告按缓冲截断：每种大小都是完整 UTF-8、整行前缀", full > 0 && !bad_cap && !bad_pfx, "坏 0 / 非前缀 0", why);
    }
    printf("\n共 %d 项，失败 %d 项\n", total, fails);
    return fails;
}
