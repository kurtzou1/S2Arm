// 网格着色器补齐变体（#674）：graphics/nvn/host/mesh_pad.h dm_mesh_pad_src 的源码改写 + Metal 真建管线。
// 期望（按规则手算，不跑被测实现）：
//   ① 掩码只有 locn5：dm_vertex_t 里加 1 行 dm_pad5、两处「dm_vertex_t v;」后各 1 行 (0,0,0,1) 赋值、文件头「// s2a:vs-pad 1 20」
//   ② 掩码 locn3 + locn7（3 是逐顶点、7 是逐图元，都已写）：没什么可补，回 3
//   ③ 掩码 3 + 5 + 7：只补 5
//   ④ 源码里没有 dm_vertex_t：回 1
//   ⑤ Metal：未补的网格配读 locn5 的片元 → 拒建，原话同作者日志「user(locn5) mismatching mesh shader output …」；补齐后 → 建成（负对照与正结果）
#import <Metal/Metal.h>
#include "mesh_pad.h"
static int bad, checks;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); bad += !ok_; printf("%s ", ok_ ? "✓" : "✗"); printf(__VA_ARGS__); printf("\n"); } while (0)
static int count(const char *s, const char *needle) { int n = 0; for (const char *q = s; (q = strstr(q, needle)); q += strlen(needle)) n++; return n; }
// 翻译器（graphics/tools/direct/dsh/MeshStage.cs）的网格写法：逐顶点 dm_vertex_t、逐图元 dm_prim_t、两个入口各一处 dm_vertex_t v;
static const char MESH[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct dm_vertex_t {\n    float4 position [[position]];\n    float4 a3 [[user(locn3)]];\n};\n"
    "struct dm_prim_t {\n    float4 p7 [[user(locn7)]];\n};\n"
    "using dm_mesh_t = metal::mesh<dm_vertex_t, dm_prim_t, 3, 1, metal::topology::triangle>;\n"
    "[[mesh]] void main0(dm_mesh_t dm_out, uint lid [[thread_index_in_threadgroup]])\n{\n"
    "    if (lid == 0u) dm_out.set_primitive_count(1);\n"
    "    for (uint n = lid; n < 3u; n += 1u)\n    {\n        dm_vertex_t v;\n        v.position = float4(float(n), 0.0, 0.0, 1.0);\n        v.a3 = float4(0.25);\n        dm_out.set_vertex(n, v);\n    }\n"
    "    for (uint n = lid; n < 1u; n += 1u)\n    {\n        dm_prim_t p;\n        p.p7 = float4(0.5);\n        dm_out.set_primitive(n, p);\n    }\n"
    "    for (uint n = lid; n < 3u; n += 1u) dm_out.set_index(n, n);\n}\n"
    "[[mesh]] void main0_z(dm_mesh_t dm_out, uint lid [[thread_index_in_threadgroup]])\n{\n"
    "    if (lid == 0u) dm_out.set_primitive_count(1);\n"
    "    for (uint n = lid; n < 3u; n += 1u)\n    {\n        dm_vertex_t v;\n        v.position = float4(float(n), 0.0, 0.5, 1.0);\n        v.a3 = float4(0.25);\n        dm_out.set_vertex(n, v);\n    }\n"
    "    for (uint n = lid; n < 3u; n += 1u) dm_out.set_index(n, n);\n}\n";
// 另一个档案里的片元：只读 user(locn5)（同作者日志的 5ee0857829bbb3fd，ps_inputs.tsv「5」）
static const char FRAG[] = "#include <metal_stdlib>\nusing namespace metal;\nstruct main0_in { float4 m_5 [[user(locn5)]]; };\n"
                           "fragment float4 main0(main0_in in [[stage_in]]) { return in.m_5; }\n";
static id<MTLRenderPipelineState> build(id<MTLDevice> d, const char *mesh, NSString **why) {
    NSError *e = nil; id<MTLLibrary> ml = [d newLibraryWithSource:@(mesh) options:nil error:&e], fl = [d newLibraryWithSource:@(FRAG) options:nil error:&e];
    if (!ml || !fl) { *why = e.localizedDescription; return nil; }
    MTLMeshRenderPipelineDescriptor *m = [MTLMeshRenderPipelineDescriptor new];
    m.meshFunction = [ml newFunctionWithName:@"main0"]; m.fragmentFunction = [fl newFunctionWithName:@"main0"]; m.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> p = [d newRenderPipelineStateWithMeshDescriptor:m options:MTLPipelineOptionNone reflection:nil error:&e];
    *why = p ? @"" : e.localizedDescription; return p;
}
int main(void) { @autoreleasepool {
    char *o = NULL;
    int rc = dm_mesh_pad_src(MESH, 1u << 5, &o);
    CHECK(rc == 0 && o, "① 掩码 locn5：改写成功（rc %d）", rc);
    if (o) {
        const char *v0 = strstr(o, "struct dm_vertex_t {\n"), *v1 = v0 ? strstr(v0, "};\n") : NULL, *pad = strstr(o, "    float4 dm_pad5 [[user(locn5)]];\n");
        CHECK(!strncmp(o, "// s2a:vs-pad 1 20\n", 19), "① 文件头「// s2a:vs-pad 1 20」");
        CHECK(pad && v0 && pad > v0 && pad < v1 && count(o, "dm_pad5 [[user(locn5)]]") == 1, "① dm_vertex_t 里恰好加 1 行 dm_pad5");
        CHECK(count(o, "        dm_vertex_t v;\n        v.dm_pad5 = float4(0.0, 0.0, 0.0, 1.0);\n") == 2, "① 两处 dm_vertex_t v; 后各一行 (0,0,0,1)");
        size_t want = strlen(MESH) + strlen("// s2a:vs-pad 1 20\n") + strlen("    float4 dm_pad5 [[user(locn5)]];\n") + 2 * strlen("        v.dm_pad5 = float4(0.0, 0.0, 0.0, 1.0);\n");
        CHECK(count(o, "dm_pad") == 3 && strlen(o) == want, "① 别处一字不动（长度 %zu = 原文 + 头 + 1 行声明 + 2 行赋值 = %zu）", strlen(o), want);
    }
    char *o2 = NULL; rc = dm_mesh_pad_src(MESH, (1u << 3) | (1u << 7), &o2);
    CHECK(rc == 3 && !o2, "② 掩码 locn3 + locn7（逐顶点、逐图元都已写）：没什么可补，回 3（实得 %d）", rc);
    char *o3 = NULL; rc = dm_mesh_pad_src(MESH, (1u << 3) | (1u << 5) | (1u << 7), &o3);
    CHECK(rc == 0 && o3 && count(o3, "dm_pad5") == 3 && count(o3, "dm_pad3") == 0 && count(o3, "dm_pad7") == 0 && !strncmp(o3, "// s2a:vs-pad 1 a8\n", 19), "③ 掩码 3 + 5 + 7：只补 5、头里掩码 a8");
    char *o4 = NULL; rc = dm_mesh_pad_src("[[mesh]] void main0() {}\n", 1u << 5, &o4);
    CHECK(rc == 1 && !o4, "④ 没有 dm_vertex_t 的源码：回 1（实得 %d）", rc);
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (![d supportsFamily:MTLGPUFamilyApple7] && ![d supportsFamily:MTLGPUFamilyMac2]) printf("－ 这台 GPU 没有网格管线，⑤ 不跑\n");
    else {
        NSString *why = nil; id p0 = build(d, MESH, &why);
        CHECK(!p0 && [why containsString:@"user(locn5)"] && [why containsString:@"not written by mesh shader"], "⑤ 未补：拒建，原话「%s」", why.UTF8String);
        id p1 = o ? build(d, o, &why) : nil;
        CHECK(p1 != nil, "⑤ 补齐后：建成%s%s", p1 ? "" : "失败：", p1 ? "" : why.UTF8String);
    }
    free(o); free(o3);
    printf("%s t_nvn_mesh_pad：%d 项，%d 项不过\n", bad ? "✗" : "✓", checks, bad);
    return bad ? 1 : 0;
} }
