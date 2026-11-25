// t_nvn_mesh_emu 的夹具（见文中两处说明）；mk 不编它，单测读源码现编
#ifdef S2A_MESH_EMU
#define DM_LG_DECL() uint dm_lg = 0u;
#define DM_LG() if (++dm_lg > 4096u) break;
#else
#define DM_LG_DECL()
#define DM_LG()
#endif
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>
#include <metal_atomic>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

// ---- 单测夹具到这里为止是翻译器原样输出（网格 834e5852915bdd02 的源码头与 spvUnsafeArray）；下面两段换掉了：
//      描述符表只留一个不读的槽，阶段函数体换成「把载荷里的测试几何搬进阶段内存」（原函数体是游戏的着色逻辑）。
//      载荷字 1..480：96 个顶点各 5 字（位置 x y z w、属性 a0）；字 481..504：索引字节（每三角形 3 字节）；字 505：图元数。
//      阶段内存布局同原翻译：顶点 n 的第 c 字在 804 + (n / 32) * 672 + n % 32 + c * 32，图元数在 [2820] 的高 8 位，索引字节从字节 11284 起
struct spvDescriptorSetBuffer0
{
    constant uint* unused [[id(0)]];
};

static inline __attribute__((always_inline)) void dm_stage_body(constant spvDescriptorSetBuffer0& spvDescriptorSet0, constant uint* spvBufferSizeConstants, uint gl_SubgroupInvocationID, threadgroup spvUnsafeArray<uint, 2845>& _70)
{
    for (uint i = gl_SubgroupInvocationID; i < 480u; i += 32u) { uint n = i / 5u, c = i % 5u; _70[804u + (n / 32u) * 672u + n % 32u + c * 32u] = _70[5u + i]; }
    for (uint i = gl_SubgroupInvocationID; i < 24u; i += 32u) _70[2821u + i] = _70[485u + i];
    if (gl_SubgroupInvocationID == 0u) _70[2820] = _70[509u] << 24;
}

// ---- 以下又是翻译器原样输出（同一支网格：载荷 / 顶点结构、驱动网格入口 main0 / main0_z、宿主入口 main0_mc / main0_mc_z / main0_mv）
struct dm_payload_t { uint w[800]; };
struct dm_vertex_t {
    float4 position [[position]];
    float4 a0 [[user(locn0)]];
    float4 a2 [[user(locn2)]];
    float4 a3 [[user(locn3)]];
    float4 a4 [[user(locn4)]];
    float4 a5 [[user(locn5)]];
    float4 a6 [[user(locn6)]];
    float4 a9 [[user(locn9)]];
};
using dm_mesh_t = metal::mesh<dm_vertex_t, void, 96, 32, metal::topology::triangle>;
[[mesh]] void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], constant uint* spvBufferSizeConstants [[buffer(25)]], uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]], uint dm_lid [[thread_position_in_threadgroup]], uint dm_tg [[threadgroup_position_in_grid]], dm_mesh_t dm_out, const object_data dm_payload_t& dm_payload [[payload]])
{
    threadgroup spvUnsafeArray<uint, 2845> _70;
    for (uint i = dm_lid; i < 2845u; i += 32u) _70[i] = 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = dm_lid; i < 800u; i += 32u) _70[4u + i] = dm_payload.w[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (dm_lid == 0u) { _70[0] = dm_tg; _70[4] = dm_tg; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    dm_stage_body(spvDescriptorSet0, spvBufferSizeConstants, gl_SubgroupInvocationID, _70);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint np = min(_70[2820] >> 24, 32u);
    if (dm_lid == 0u) dm_out.set_primitive_count(np);
    for (uint n = dm_lid; n < 96u; n += 32u)
    {
        uint b = 804u + (n / 32u) * 672u + n % 32u;
        dm_vertex_t v;
        v.position = float4(as_type<float>(_70[b + 0u]), as_type<float>(_70[b + 32u]), as_type<float>(_70[b + 64u]), as_type<float>(_70[b + 96u]));
        v.a0 = float4(as_type<float>(_70[b + 128u]), 0.0, 0.0, 1.0);
        v.a2 = float4(as_type<float>(_70[b + 160u]), as_type<float>(_70[b + 192u]), as_type<float>(_70[b + 224u]), 1.0);
        v.a3 = float4(as_type<float>(_70[b + 256u]), as_type<float>(_70[b + 288u]), as_type<float>(_70[b + 320u]), 1.0);
        v.a4 = float4(as_type<float>(_70[b + 352u]), 0.0, 0.0, 1.0);
        v.a5 = float4(as_type<float>(_70[b + 384u]), as_type<float>(_70[b + 416u]), as_type<float>(_70[b + 448u]), 1.0);
        v.a6 = float4(as_type<float>(_70[b + 480u]), as_type<float>(_70[b + 512u]), as_type<float>(_70[b + 544u]), 1.0);
        v.a9 = float4(as_type<float>(_70[b + 576u]), as_type<float>(_70[b + 608u]), as_type<float>(_70[b + 640u]), 1.0);
        v.position.z = fma(v.position.z, 0.5, v.position.w * 0.5);
        dm_out.set_vertex(n, v);
    }
    for (uint n = dm_lid; n < np * 3u; n += 32u)
    {
        uint at = 11284u + n;
        dm_out.set_index(n, (_70[at >> 2] >> ((at & 3u) * 8u)) & 0xffu);
    }
}

[[mesh]] void main0_z(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], constant uint* spvBufferSizeConstants [[buffer(25)]], uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]], uint dm_lid [[thread_position_in_threadgroup]], uint dm_tg [[threadgroup_position_in_grid]], dm_mesh_t dm_out, const object_data dm_payload_t& dm_payload [[payload]])
{
    threadgroup spvUnsafeArray<uint, 2845> _70;
    for (uint i = dm_lid; i < 2845u; i += 32u) _70[i] = 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = dm_lid; i < 800u; i += 32u) _70[4u + i] = dm_payload.w[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (dm_lid == 0u) { _70[0] = dm_tg; _70[4] = dm_tg; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    dm_stage_body(spvDescriptorSet0, spvBufferSizeConstants, gl_SubgroupInvocationID, _70);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint np = min(_70[2820] >> 24, 32u);
    if (dm_lid == 0u) dm_out.set_primitive_count(np);
    for (uint n = dm_lid; n < 96u; n += 32u)
    {
        uint b = 804u + (n / 32u) * 672u + n % 32u;
        dm_vertex_t v;
        v.position = float4(as_type<float>(_70[b + 0u]), as_type<float>(_70[b + 32u]), as_type<float>(_70[b + 64u]), as_type<float>(_70[b + 96u]));
        v.a0 = float4(as_type<float>(_70[b + 128u]), 0.0, 0.0, 1.0);
        v.a2 = float4(as_type<float>(_70[b + 160u]), as_type<float>(_70[b + 192u]), as_type<float>(_70[b + 224u]), 1.0);
        v.a3 = float4(as_type<float>(_70[b + 256u]), as_type<float>(_70[b + 288u]), as_type<float>(_70[b + 320u]), 1.0);
        v.a4 = float4(as_type<float>(_70[b + 352u]), 0.0, 0.0, 1.0);
        v.a5 = float4(as_type<float>(_70[b + 384u]), as_type<float>(_70[b + 416u]), as_type<float>(_70[b + 448u]), 1.0);
        v.a6 = float4(as_type<float>(_70[b + 480u]), as_type<float>(_70[b + 512u]), as_type<float>(_70[b + 544u]), 1.0);
        v.a9 = float4(as_type<float>(_70[b + 576u]), as_type<float>(_70[b + 608u]), as_type<float>(_70[b + 640u]), 1.0);
        dm_out.set_vertex(n, v);
    }
    for (uint n = dm_lid; n < np * 3u; n += 32u)
    {
        uint at = 11284u + n;
        dm_out.set_index(n, (_70[at >> 2] >> ((at & 3u) * 8u)) & 0xffu);
    }
}

#ifdef S2A_MESH_EMU
kernel void main0_mc(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], constant uint* spvBufferSizeConstants [[buffer(25)]], uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]], uint dm_lid [[thread_position_in_threadgroup]], uint dm_tg [[threadgroup_position_in_grid]], device uint* dm_xo [[buffer(28)]])
{
    threadgroup spvUnsafeArray<uint, 2845> _70;
    for (uint i = dm_lid; i < 2845u; i += 32u) _70[i] = 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint dm_e = dm_xo[dm_xo[2] + dm_tg], dm_t = dm_e >> 10, dm_j = dm_e & 1023u;
    for (uint i = dm_lid; i < 800u; i += 32u) _70[4u + i] = dm_xo[dm_xo[1] + dm_t * dm_xo[5] + i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (dm_lid == 0u) { _70[0] = dm_j; _70[4] = dm_j; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    dm_stage_body(spvDescriptorSet0, spvBufferSizeConstants, gl_SubgroupInvocationID, _70);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint np = min(_70[2820] >> 24, 32u);
    device dm_vertex_t* dm_vb = (device dm_vertex_t*)(dm_xo + dm_xo[11]) + dm_tg * 96u;
    for (uint n = dm_lid; n < 96u; n += 32u)
    {
        uint b = 804u + (n / 32u) * 672u + n % 32u;
        dm_vertex_t v;
        v.position = float4(as_type<float>(_70[b + 0u]), as_type<float>(_70[b + 32u]), as_type<float>(_70[b + 64u]), as_type<float>(_70[b + 96u]));
        v.a0 = float4(as_type<float>(_70[b + 128u]), 0.0, 0.0, 1.0);
        v.a2 = float4(as_type<float>(_70[b + 160u]), as_type<float>(_70[b + 192u]), as_type<float>(_70[b + 224u]), 1.0);
        v.a3 = float4(as_type<float>(_70[b + 256u]), as_type<float>(_70[b + 288u]), as_type<float>(_70[b + 320u]), 1.0);
        v.a4 = float4(as_type<float>(_70[b + 352u]), 0.0, 0.0, 1.0);
        v.a5 = float4(as_type<float>(_70[b + 384u]), as_type<float>(_70[b + 416u]), as_type<float>(_70[b + 448u]), 1.0);
        v.a6 = float4(as_type<float>(_70[b + 480u]), as_type<float>(_70[b + 512u]), as_type<float>(_70[b + 544u]), 1.0);
        v.a9 = float4(as_type<float>(_70[b + 576u]), as_type<float>(_70[b + 608u]), as_type<float>(_70[b + 640u]), 1.0);
        v.position.z = fma(v.position.z, 0.5, v.position.w * 0.5);
        dm_vb[n] = v;
    }
    threadgroup uint dm_ibase;
    if (dm_lid == 0u) dm_ibase = atomic_fetch_add_explicit((device atomic_uint*)(dm_xo + 13), np * 3u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    device uint* dm_ib = dm_xo + dm_xo[12] + dm_ibase; uint dm_v0 = dm_tg * 96u;
    for (uint n = dm_lid; n < np * 3u; n += 32u)
    {
        uint at = 11284u + n;
        dm_ib[n] = dm_v0 + min((_70[at >> 2] >> ((at & 3u) * 8u)) & 0xffu, 95u);
    }
}

kernel void main0_mc_z(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], constant uint* spvBufferSizeConstants [[buffer(25)]], uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]], uint dm_lid [[thread_position_in_threadgroup]], uint dm_tg [[threadgroup_position_in_grid]], device uint* dm_xo [[buffer(28)]])
{
    threadgroup spvUnsafeArray<uint, 2845> _70;
    for (uint i = dm_lid; i < 2845u; i += 32u) _70[i] = 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint dm_e = dm_xo[dm_xo[2] + dm_tg], dm_t = dm_e >> 10, dm_j = dm_e & 1023u;
    for (uint i = dm_lid; i < 800u; i += 32u) _70[4u + i] = dm_xo[dm_xo[1] + dm_t * dm_xo[5] + i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (dm_lid == 0u) { _70[0] = dm_j; _70[4] = dm_j; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    dm_stage_body(spvDescriptorSet0, spvBufferSizeConstants, gl_SubgroupInvocationID, _70);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint np = min(_70[2820] >> 24, 32u);
    device dm_vertex_t* dm_vb = (device dm_vertex_t*)(dm_xo + dm_xo[11]) + dm_tg * 96u;
    for (uint n = dm_lid; n < 96u; n += 32u)
    {
        uint b = 804u + (n / 32u) * 672u + n % 32u;
        dm_vertex_t v;
        v.position = float4(as_type<float>(_70[b + 0u]), as_type<float>(_70[b + 32u]), as_type<float>(_70[b + 64u]), as_type<float>(_70[b + 96u]));
        v.a0 = float4(as_type<float>(_70[b + 128u]), 0.0, 0.0, 1.0);
        v.a2 = float4(as_type<float>(_70[b + 160u]), as_type<float>(_70[b + 192u]), as_type<float>(_70[b + 224u]), 1.0);
        v.a3 = float4(as_type<float>(_70[b + 256u]), as_type<float>(_70[b + 288u]), as_type<float>(_70[b + 320u]), 1.0);
        v.a4 = float4(as_type<float>(_70[b + 352u]), 0.0, 0.0, 1.0);
        v.a5 = float4(as_type<float>(_70[b + 384u]), as_type<float>(_70[b + 416u]), as_type<float>(_70[b + 448u]), 1.0);
        v.a6 = float4(as_type<float>(_70[b + 480u]), as_type<float>(_70[b + 512u]), as_type<float>(_70[b + 544u]), 1.0);
        v.a9 = float4(as_type<float>(_70[b + 576u]), as_type<float>(_70[b + 608u]), as_type<float>(_70[b + 640u]), 1.0);
        dm_vb[n] = v;
    }
    threadgroup uint dm_ibase;
    if (dm_lid == 0u) dm_ibase = atomic_fetch_add_explicit((device atomic_uint*)(dm_xo + 13), np * 3u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    device uint* dm_ib = dm_xo + dm_xo[12] + dm_ibase; uint dm_v0 = dm_tg * 96u;
    for (uint n = dm_lid; n < np * 3u; n += 32u)
    {
        uint at = 11284u + n;
        dm_ib[n] = dm_v0 + min((_70[at >> 2] >> ((at & 3u) * 8u)) & 0xffu, 95u);
    }
}

vertex dm_vertex_t main0_mv(const device dm_vertex_t* dm_vb [[buffer(28)]], uint dm_vid [[vertex_id]]) { return dm_vb[dm_vid]; }
#endif
