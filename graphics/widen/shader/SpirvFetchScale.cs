// 通用宽屏 · 整数取图 / 尺寸查询的分轴倍率。新翻译器为 Y 使用独立辅助函数，读 render_scale_y，保留原分辨率倍率；
// 下文移除 y 调用仅用于旧 1x 录像，X 的缩放下标 / 绑定分析沿用。Ryujinx 为分辨率缩放在片元着色器里生成两个辅助函数：
//   TexelFetchScale(坐标分量, 缩放下标, 分量号)：整数取图 / 读图像的坐标 × support_buffer.render_scale[1 + 缩放下标]（负值走「按真实片元坐标插值」：⌊客体坐标⌋·k + mod(片元坐标, k) = 真实像素）；
//   TextureSizeUnscale(尺寸分量, 缩放下标)：textureSize 的结果 ÷ |缩放|。
// 两者都不分轴（x、y 同乘一个缩放）。这里把 y 分量那次调用换成「直接取参数」（分量号常量 = 1 的取图缩放；参数来自尺寸向量第 1 分量的尺寸反缩放），只剩横向缩放；
// 同时记下每个缩放下标对应的贴图绑定号，包装层按所绑贴图的放宽比逐次写 render_scale[1 + 下标]。这样所有片元程序都按客体坐标画（render_scale[0] = k）：
// 片元坐标、屏幕尺寸、区域矩形 / 瓦片数等客体像素常量一律原样，换算只在贴图访问处发生（同 Ryujinx 分辨率缩放的做法）。
// exact = 着色器里每次 2D 整数取图 / 读图像的坐标都经过缩放、且绑定号认得出、辅助函数调用的分量都认得出；否则这个程序仍按真实像素坐标画（旧约定，见 WidenRenderer）。
// Ryujinx 的函数参数一律是局部变量指针（GenerateCall：GetLocalPointer），常量参数先存进局部变量：分量号 / 缩放下标按「最近一次存进该指针的常量」读。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    public static class SpirvFetchScale
    {
        const int OpTypeInt = 21, OpTypeImage = 25, OpTypeSampledImage = 27, OpConstant = 43, OpFunction = 54, OpFunctionParameter = 55, OpFunctionEnd = 56, OpFunctionCall = 57,
            OpVariable = 59, OpLoad = 61, OpStore = 62, OpAccessChain = 65, OpInBoundsAccessChain = 66, OpDecorate = 71, OpCompositeConstruct = 80, OpCompositeExtract = 81,
            OpCopyObject = 83, OpSampledImage = 86, OpIAdd = 128, OpISub = 130, OpImageFetch = 95, OpImageRead = 98, OpImageWrite = 99, OpImage = 100, OpImageQuerySizeLod = 103, OpImageQuerySize = 104, OpBitcast = 124;
        const int DecBinding = 33, StorageUniform = 2, Dim2D = 1;
        const int DimNeverScaled1D = 0, DimNeverScaled3D = 2, DimNeverScaledCube = 3, DimNeverScaledBuffer = 5, DimNeverScaledSubpass = 6;   // SPIR-V Dim：宿主从不缩放的几类（Rect = 4 不在内）
        // 标签（值或指针）：取图缩放的结果分量（缩放下标、分量号）、由它拼成的坐标向量（缩放下标）、尺寸查询结果向量（绑定号）、取出的尺寸分量（绑定号、分量号）
        enum T : byte { None, FetchComp, FetchVec, SizeVec, SizeComp }
        readonly record struct Tag(T Kind, int A, int B, uint Origin = 0);

        /// <summary>改 y 分量的缩放调用。返回改后的 SPIR-V（没改返回原数组）；scales = (render_scale 下标 = 1 + 缩放下标, 绑定号, 是存储图像) 去重表；
        /// yPatched = 换掉的调用数；exact 见文件头。</summary>
        public static byte[] PatchY(byte[] spv, int renderScaleMember, out (int Index, int Binding, bool Image)[] scales, out int yPatched, out bool exact)
            => PatchY(spv, renderScaleMember, out scales, out yPatched, out exact, requireSizeTable: false);

        public static byte[] PatchY(byte[] spv, int renderScaleMember, out (int Index, int Binding, bool Image)[] scales, out int yPatched, out bool exact, bool requireSizeTable)
            => PatchY(spv, renderScaleMember, out scales, out yPatched, out exact, requireSizeTable, out _);

        // Resolution proof is independent of PatchY's original wide-screen exact
        // contract. Failure here is a capability result, never a translation veto.
        public static bool AnalyzeSizeTable(byte[] spv, int renderScaleMember,
            out (int Index, int Binding, bool Image)[] scales, out string[] reasons)
        {
            PatchY(spv, renderScaleMember, out scales, out _, out bool exact, requireSizeTable: true, out reasons);
            return exact;
        }

        public static byte[] PatchY(byte[] spv, int renderScaleMember, out (int Index, int Binding, bool Image)[] scales, out int yPatched, out bool exact, bool requireSizeTable, out string[] reasons)
        {
            scales = Array.Empty<(int, int, bool)>(); yPatched = 0; exact = true;
            reasons = Array.Empty<string>();
            var proofReasons = new List<string>();
            void Reason(string reason) { if (!proofReasons.Contains(reason)) proofReasons.Add(reason); }
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) { exact = false; reasons = ["invalid_spirv"]; return spv; }
            uint[] w = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
            if (w[0] != 0x07230203) { exact = false; reasons = ["invalid_spirv"]; return spv; }
            var binding = new Dictionary<uint, int>(); var intTypes = new HashSet<uint>(); var consts = new Dictionary<uint, int>(); var uniforms = new HashSet<uint>();
            var descriptorSets = new Dictionary<uint, int>();
            var imgDim = new Dictionary<uint, int>();   // 图像 / 采样图像类型 → Dim
            var imageFacts = new Dictionary<uint, (uint SampleType, uint Format, uint Sampled)>();
            var scalarTypes = new HashSet<uint>();
            var helpers = new Dictionary<uint, int>();  // 读 render_scale[动态下标] 的函数 → 参数个数
            var yHelpers = new HashSet<uint>();
            var exactHelpers = new HashSet<uint>();
            uint fn = 0; int fnParams = 0; bool fnScale = false;
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) { exact = false; reasons = ["invalid_spirv"]; return spv; }
                switch (op)
                {
                    case 15: if (requireSizeTable && n >= 3 && w[i + 1] == 3) Reason("geometry_stage"); break; // OpEntryPoint Geometry
                    case OpDecorate:
                        if (n >= 4 && w[i + 2] == DecBinding) binding[w[i + 1]] = (int)w[i + 3];
                        if (n >= 4 && w[i + 2] == 34) descriptorSets[w[i + 1]] = (int)w[i + 3];
                        break;
                    case OpTypeInt: if (n >= 4 && w[i + 2] == 32) { intTypes.Add(w[i + 1]); scalarTypes.Add(w[i + 1]); } break;
                    case 22: if (n == 3 && w[i + 2] == 32) scalarTypes.Add(w[i + 1]); break; // OpTypeFloat
                    case OpTypeImage:
                        if (n >= 9)
                        {
                            imgDim[w[i + 1]] = (int)w[i + 3] | (w[i + 5] != 0 ? 0x100 : 0) | (w[i + 6] != 0 ? 0x200 : 0);
                            imageFacts[w[i + 1]] = (w[i + 2], w[i + 8], w[i + 7]);
                        }
                        break;
                    case OpTypeSampledImage:
                        if (n >= 3 && imgDim.TryGetValue(w[i + 2], out int d0)) imgDim[w[i + 1]] = d0;
                        if (n >= 3 && imageFacts.TryGetValue(w[i + 2], out var sf)) imageFacts[w[i + 1]] = sf;
                        break;
                    case OpConstant: if (n == 4 && intTypes.Contains(w[i + 1])) consts[w[i + 2]] = (int)w[i + 3]; break;
                    case OpVariable: if (n >= 4 && w[i + 3] == StorageUniform) uniforms.Add(w[i + 2]); break;
                    case OpFunction: fn = w[i + 2]; fnParams = 0; fnScale = false; break;
                    case OpFunctionParameter: fnParams++; break;
                    case OpAccessChain: case OpInBoundsAccessChain:
                        // Exact helpers access ivec4 texture_sizes[index][axis].
                        if (fn != 0 && n == 7 && uniforms.Contains(w[i + 3]) && binding.TryGetValue(w[i + 3], out int ts) && ts == 0
                            && consts.TryGetValue(w[i + 4], out int tm) && tm == 12 && !consts.ContainsKey(w[i + 5])) { fnScale = true; exactHelpers.Add(fn); }
                        // support_buffer（绑定 0 的 Uniform 变量）第 renderScaleMember 个成员、下标不是常量 = render_scale[1 + 缩放下标]
                        if (fn != 0 && n == 6 && uniforms.Contains(w[i + 3]) && binding.TryGetValue(w[i + 3], out int sb) && sb == 0
                            && consts.TryGetValue(w[i + 4], out int m) && m == renderScaleMember && !consts.ContainsKey(w[i + 5])) fnScale = true;
                        if (fn != 0 && n == 6 && uniforms.Contains(w[i + 3]) && binding.TryGetValue(w[i + 3], out int sy) && sy == 0
                            && consts.TryGetValue(w[i + 4], out int my) && my == WidenShaders.RenderScaleYMember && !consts.ContainsKey(w[i + 5])) { fnScale = true; yHelpers.Add(fn); }
                        break;
                    case OpFunctionEnd: if (fn != 0 && fnScale) helpers[fn] = fnParams; fn = 0; break;
                }
                i += n;
            }
            var tag = new Dictionary<uint, Tag>(); var stored = new Dictionary<uint, int>();   // 指针 → 最近一次存进去的整数常量
            var img = new Dictionary<uint, (int Binding, uint Type, int Set)>();   // 图像类的值 → 来自哪个变量的绑定号、类型
            var outScales = new List<(int, int, bool)>(); var replace = new List<int>();
            var unscaledSizes = new HashSet<uint>();
            var queriedSizes = new HashSet<uint>();
            var extractedSizes = new HashSet<uint>();
            void AddScale(int index, int b, bool image) { if (!outScales.Contains((index, b, image))) outScales.Add((index, b, image)); }
            bool Is2D(uint type) => imgDim.TryGetValue(type, out int d) && (d & 0xff) == Dim2D;
            bool NeverScaled(uint type) => imgDim.TryGetValue(type, out int d) && (d & 0xff) is DimNeverScaled1D or DimNeverScaled3D or DimNeverScaledCube or DimNeverScaledBuffer or DimNeverScaledSubpass;
            void CheckImage(uint value, bool storage = false)
            {
                if (!requireSizeTable) return;
                if (!img.TryGetValue(value, out var fact)) { Reason("unknown_or_dynamic_image_binding"); return; }
                if (fact.Set != 0) Reason("unsupported_or_unknown_descriptor_set");
                // 认得出的非二维（1D / 3D / 立方体 / 缓冲 / 子遍输入）：宿主从不缩放这类存储（nvn_rscale.inc rs_eligible 只缩二维 / 二维数组 / 矩形），按原尺寸访问就是对的。
                //   单独记成 never_scaled_image_type（照旧不进尺寸表、照旧 legacy_1x：1 倍时绑定逐字节不变）；内部分辨率按它判这支的取图倍率路径可用（nvn_mtl.m rs_ok）。
                //   矩形（Dim Rect）宿主会缩，照旧要证；类型认不出的照旧记 non_2d_or_unknown_image_type
                if (!imgDim.ContainsKey(fact.Type)) { Reason("non_2d_or_unknown_image_type"); return; }
                if (NeverScaled(fact.Type)) { Reason("never_scaled_image_type"); return; }
                if (!Is2D(fact.Type)) Reason("non_2d_or_unknown_image_type");
                if (!imageFacts.TryGetValue(fact.Type, out var image) || !scalarTypes.Contains(image.SampleType)
                    || image.Format > 41 || image.Sampled is < 1 or > 2 || storage && image.Format == 0)
                    Reason("unknown_image_format_or_sample_type");
            }
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (op == OpFunction) fn = w[i + 2];
                if (op == OpFunctionEnd) fn = 0;
                // An exact helper calls old helpers only on its zero-table branch.
                // Its parameter values are not call-site constants; analyze callers.
                if (fn != 0 && helpers.ContainsKey(fn)) { i += n; continue; }
                switch (op)
                {
                    case OpStore:
                        if (n >= 3)
                        {
                            if (tag.TryGetValue(w[i + 2], out Tag t)) tag[w[i + 1]] = t; else tag.Remove(w[i + 1]);
                            if (consts.TryGetValue(w[i + 2], out int c)) stored[w[i + 1]] = c; else stored.Remove(w[i + 1]);
                        }
                        break;
                    case OpLoad:
                        if (n >= 4)
                        {
                            if (tag.TryGetValue(w[i + 3], out Tag t)) tag[w[i + 2]] = t;
                            if (binding.TryGetValue(w[i + 3], out int b)) img[w[i + 2]] = (b, w[i + 1], descriptorSets.TryGetValue(w[i + 3], out int ds) ? ds : -1);
                            else if (img.TryGetValue(w[i + 3], out var iv)) img[w[i + 2]] = iv;
                        }
                        break;
                    case OpCopyObject: case OpBitcast:
                        if (n >= 4) { if (tag.TryGetValue(w[i + 3], out Tag t)) tag[w[i + 2]] = t; if (img.TryGetValue(w[i + 3], out var iv)) img[w[i + 2]] = iv; }
                        break;
                    case OpIAdd: case OpISub:
                        // 缩放后的坐标再加 / 减偏移（texelFetch 带运行时偏移：巫师3 光照遍按 BitFieldSExtract 出的偏移逐像素取邻点）：偏移不缩放，同 Ryujinx 分辨率缩放
                        if (n >= 5 && (tag.TryGetValue(w[i + 3], out Tag ia) && ia.Kind == T.FetchComp || tag.TryGetValue(w[i + 4], out ia) && ia.Kind == T.FetchComp))
                        {
                            tag[w[i + 2]] = ia;
                            if (requireSizeTable) { exact = false; Reason("post_scale_integer_offset"); }
                        }
                        break;
                    case OpSampledImage: if (n >= 5 && img.TryGetValue(w[i + 3], out var si)) img[w[i + 2]] = (si.Binding, w[i + 1], si.Set); break;
                    case OpImage: if (n >= 4 && img.TryGetValue(w[i + 3], out var ii)) img[w[i + 2]] = (ii.Binding, w[i + 1], ii.Set); break;
                    case OpImageQuerySizeLod: case OpImageQuerySize:
                        if (n >= 4) CheckImage(w[i + 3]);
                        if (n >= 4 && img.TryGetValue(w[i + 3], out var qi) && (!requireSizeTable || Is2D(qi.Type))) tag[w[i + 2]] = new Tag(T.SizeVec, qi.Binding, 0);
                        else if (requireSizeTable && n >= 4 && !img.ContainsKey(w[i + 3])) exact = false;
                        if (requireSizeTable && n >= 4 && !(img.TryGetValue(w[i + 3], out var qn) && NeverScaled(qn.Type))) queriedSizes.Add(w[i + 2]);   // 宿主从不缩放的类型：尺寸查询返回的就是原尺寸，不要求分量证明
                        break;
                    case OpCompositeExtract:
                        if (n == 5 && tag.TryGetValue(w[i + 3], out Tag sv) && sv.Kind == T.SizeVec)
                        {
                            tag[w[i + 2]] = new Tag(T.SizeComp, sv.A, (int)w[i + 4], w[i + 2]);
                            extractedSizes.Add(w[i + 3]);
                            if (w[i + 4] < 2) unscaledSizes.Add(w[i + 2]);
                        }
                        break;
                    case OpCompositeConstruct:
                    {
                        int s = -1, components = 0;
                        for (int j = 3; j < n; j++)
                            if (tag.TryGetValue(w[i + j], out Tag ct) && ct.Kind == T.FetchComp)
                            {
                                if (s >= 0 && s != ct.A) exact = false;
                                if (requireSizeTable && ct.B != j - 3) Reason("fetch_axis_mismatch");
                                s = ct.A; components |= 1 << ct.B;
                            }
                        if (s >= 0 && (!requireSizeTable || components == 3)) tag[w[i + 2]] = new Tag(T.FetchVec, s, 0);
                        break;
                    }
                    case OpFunctionCall:
                        if (n >= 4 && helpers.TryGetValue(w[i + 3], out int np) && np == n - 4)
                        {
                            bool isExactHelper = exactHelpers.Contains(w[i + 3]);
                            if (isExactHelper && np == 5)
                            {
                                if (!stored.TryGetValue(w[i + 5], out int smp) || !stored.TryGetValue(w[i + 6], out int comp) || comp is < 0 or > 1
                                    || !stored.TryGetValue(w[i + 8], out int abi) || abi != 2) { exact = false; break; }
                                tag[w[i + 2]] = new Tag(T.FetchComp, smp, comp);
                            }
                            else if (isExactHelper && np == 4)
                            {
                                if (!stored.TryGetValue(w[i + 5], out int smp) || !stored.TryGetValue(w[i + 6], out int comp)
                                    || !tag.TryGetValue(w[i + 4], out Tag at) || at.Kind != T.SizeComp || comp != at.B) { exact = false; break; }
                                unscaledSizes.Remove(at.Origin);
                                AddScale(1 + smp, at.A, false);
                            }
                            else if (requireSizeTable) { exact = false; Reason("legacy_scale_helper"); }
                            else if (np == 3)
                            {
                                // 取图缩放（片元版）：参数 = 坐标分量、缩放下标、分量号（0 = x、1 = y）
                                if (!stored.TryGetValue(w[i + 5], out int smp) || !stored.TryGetValue(w[i + 6], out int comp)) { exact = false; break; }
                                tag[w[i + 2]] = new Tag(T.FetchComp, smp, comp);
                                if (comp == 1 && !yHelpers.Contains(w[i + 3])) replace.Add(i);
                            }
                            else if (np == 2)
                            {
                                // 尺寸反缩放：参数 = 尺寸分量、缩放下标；分量号看参数来自尺寸向量的第几个分量
                                if (!stored.TryGetValue(w[i + 5], out int smp) || !tag.TryGetValue(w[i + 4], out Tag at) || at.Kind != T.SizeComp) { exact = false; break; }
                                unscaledSizes.Remove(at.Origin);
                                if (at.B == 1 && !yHelpers.Contains(w[i + 3])) replace.Add(i); else if (at.B == 0) AddScale(1 + smp, at.A, false);
                            }
                            else exact = false;
                        }
                        break;
                    case OpImageFetch: case OpImageRead:
                        if (n >= 5) CheckImage(w[i + 3], op == OpImageRead);
                        if (n >= 5 && img.TryGetValue(w[i + 3], out var fi) && Is2D(fi.Type))
                        {
                            if (requireSizeTable && op == OpImageFetch && n > 5 && (w[i + 5] & (8u | 16u | 32u)) != 0) { exact = false; Reason("image_fetch_offset"); }
                            if (tag.TryGetValue(w[i + 4], out Tag ft) && ft.Kind == T.FetchVec) AddScale(1 + ft.A, fi.Binding, op == OpImageRead);
                            else exact = false;   // 2D 整数取图没经过缩放（无绑定 / 数组 / 无辅助函数）：按客体坐标会读错
                        }
                        else if (n >= 5 && !img.ContainsKey(w[i + 3])) exact = false;   // 认不出图像来源
                        break;
                    case OpImageWrite:
                        // 宽屏旧约定（scale_exact）照旧：Ryujinx 不缩放写图像，写 2D 图像的程序按真实像素画。
                        //   尺寸表判定（requireSizeTable）不因写图像判不精确：宿主对存储图像槽一律保持原尺寸（nvn_rscale_ops.inc rs_pre_images / rs_pre_draw：
                        //   绑上图像槽的缩放图在用它的绘制 / 派发之前换回原尺寸），写的坐标按游戏纹素就是对的；读的贴图照旧逐次要证（11-22 D-ZR6V：计算着色器几乎都写图像，
                        //   原先整支 legacy_1x，读到放大的深度就整遍退回原尺寸）
                        if (!requireSizeTable && n >= 4 && (!img.TryGetValue(w[i + 1], out var wi) || Is2D(wi.Type))) exact = false;   // Ryujinx 不缩放写图像
                        break;
                    case 87: case 88: case 89: case 90: case 91: case 92: case 93: case 94: // sampled image operations
                    case 96: case 97: // gathers
                        if (n >= 5) CheckImage(w[i + 3]);
                        break;
                }
                i += n;
            }
            if (requireSizeTable && unscaledSizes.Count != 0) { exact = false; Reason("size_component_without_exact_helper"); }
            if (requireSizeTable && !queriedSizes.IsSubsetOf(extractedSizes)) { exact = false; Reason("size_vector_without_component_proof"); }
            if (!exact && proofReasons.Count == 0) Reason("unproven_fetch_or_size_helper");
            if (requireSizeTable && proofReasons.Count != 0) exact = false;
            reasons = proofReasons.ToArray();
            scales = outScales.ToArray();
            if (replace.Count == 0) return spv;
            // y 分量调用 → OpLoad 结果类型 结果 参数0（参数是局部变量指针：取它的值 = 不缩放）；指令变短，其后整体前移（SPIR-V 没有绝对偏移）
            var o = new List<uint>(w.Length); int r = 0;
            for (int i = 0; i < w.Length;)
            {
                int n = i < 5 ? 5 : (int)(w[i] >> 16);
                if (r < replace.Count && replace[r] == i) { o.Add((4u << 16) | OpLoad); o.Add(w[i + 1]); o.Add(w[i + 2]); o.Add(w[i + 4]); r++; yPatched++; }
                else for (int j = 0; j < n; j++) o.Add(w[i + j]);
                i += n;
            }
            return MemoryMarshal.AsBytes(CollectionsMarshal.AsSpan(o)).ToArray();
        }
    }
}
