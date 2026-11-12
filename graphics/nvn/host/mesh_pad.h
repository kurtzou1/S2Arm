// 网格着色器补齐变体的源码改写（dsh_miss.inc dm_shader_vpad 用；单测 graphics/nvn/tests/t_nvn_mesh_pad.m 直接包含本文件）
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// 网格着色器的补齐（#674，11-11：一款游戏的植被网格 6d42a320e50657a3 与另一个档案里的片元 5ee0857829bbb3fd 运行期配成一对，片元读 user(locn5)、
//   网格不写，Metal 拒建：「Fragment input(s) `user(locn5)` mismatching mesh shader output type(s) or not written by mesh shader」，这对的绘制一直跳过，几何体忽隐忽现）。
//   Mac 上实验：网格不写该位置才报这句；网格按逐图元写、片元按插值或 flat 读都建得成。所以同顶点补齐（VsPadMask）的规则，按 graphics/tools/direct/dsh/MeshStage.cs
//   的写法改源码：逐顶点输出 dm_vertex_t 里加 float4 dm_pad<n> [[user(locn<n>)]]，每处 `dm_vertex_t v;` 后给它 (0,0,0,1)（硬件在那里读到的）。
//   只补逐顶点与逐图元（dm_prim_t）都没有的位置。在宿主侧改文本，不动翻译器（翻译器一改全部款的直连库要重出）。成功 0；没什么可补 3；源码不是这种写法 1
static int dm_mesh_pad_src(const char *src, uint32_t mask, char **out) {
    static const char vt[] = "struct dm_vertex_t {\n", pt[] = "struct dm_prim_t {\n", vdecl[] = "        dm_vertex_t v;\n";
    const char *v0 = strstr(src, vt), *v1 = v0 ? strstr(v0, "};\n") : NULL; if (!v0 || !v1 || !strstr(src, vdecl)) return 1;
    const char *p0 = strstr(src, pt), *p1 = p0 ? strstr(p0, "};\n") : NULL;
    uint32_t have = 0;
    for (int w = 0; w < 2; w++) {
        const char *a = w ? p0 : v0, *e = w ? p1 : v1;
        for (const char *q = a; a && e && (q = strstr(q, "[[user(locn")) && q < e; q += 11) { int l = atoi(q + 11); if (l >= 0 && l < 32) have |= 1u << l; }
    }
    uint32_t miss = mask & ~have; if (!miss) return 3;
    int nd = 0; for (const char *q = src; (q = strstr(q, vdecl)); q += sizeof vdecl - 1) nd++;
    size_t cap = strlen(src) + 64 + 48u * 32u + (size_t)nd * 64u * 32u + 1; char *o = malloc(cap), *w = o; if (!o) return 1;
    w += sprintf(w, "// s2a:vs-pad 1 %x\n", mask);
    memcpy(w, src, (size_t)(v1 - src)); w += v1 - src;
    for (int l = 0; l < 32; l++) if (miss >> l & 1) w += sprintf(w, "    float4 dm_pad%d [[user(locn%d)]];\n", l, l);
    for (const char *s = v1, *d; ; s = d + sizeof vdecl - 1) {
        if (!(d = strstr(s, vdecl))) { strcpy(w, s); break; }
        size_t len = (size_t)(d - s) + sizeof vdecl - 1; memcpy(w, s, len); w += len;
        for (int l = 0; l < 32; l++) if (miss >> l & 1) w += sprintf(w, "        v.dm_pad%d = float4(0.0, 0.0, 0.0, 1.0);\n", l);
    }
    *out = o; return 0;
}
