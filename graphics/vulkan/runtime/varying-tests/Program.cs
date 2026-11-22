using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;

// Only the guest-byte/capability boundary is controlled. Decoder, linking, IR, VTG and codegen are production source.
sealed class Accessor(byte[] code, bool linked, int vertexLimit = 128, int fragmentLimit = 128, bool nativeGs = false, bool layerVertex = true, bool xfb = false, int xfbLocation = 2, AttributeType attributeType = AttributeType.Float, bool spirv15 = false, bool legacyExt = true, bool legacyNv = false) : IGpuAccessor
{
    public bool QueryHostSupportsSpirv15() => spirv15;
    public bool QueryHostSpirvLayerExt() => legacyExt;
    public bool QueryHostSpirvLayerNv() => legacyNv;
    public bool QueryHostSupportsLayerVertexTessellation() => layerVertex;
    public bool QueryTransformFeedbackEnabled() => xfb;
    public bool QueryHostSupportsTransformFeedback() => true;
    public ReadOnlySpan<byte> QueryTransformFeedbackVaryingLocations(int bufferIndex) => xfb && bufferIndex == 0 ? new byte[] {(byte)(32+xfbLocation*4),(byte)(33+xfbLocation*4),(byte)(34+xfbLocation*4),(byte)(35+xfbLocation*4)} : ReadOnlySpan<byte>.Empty;
    public int QueryTransformFeedbackStride(int bufferIndex) => xfb && bufferIndex == 0 ? 16 : 0;
    public bool QueryHostRequiresLinkedVaryingInterface() => linked;
    public int QueryHostMaximumVertexOutputComponents() => vertexLimit;
    public int QueryHostMaximumFragmentInputComponents() => fragmentLimit;
    public bool QueryHostSupportsGeometryShader() => nativeGs;
    public bool QueryHostSupportsGeometryShaderPassthrough() => nativeGs;
    public GpuGraphicsState QueryGraphicsState()
    {
        Ryujinx.Common.Memory.Array32<AttributeType> attributes = default;
        attributes[0] = attributeType;
        return new(false, InputTopology.Triangles, false, TessPatchType.Triangles, TessSpacing.EqualSpacing, false, false, false, false, false, 1f, AlphaTestOp.Always, 0f, attributes, true, default, false, false, true, false);
    }
    public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte, ulong>(code.AsSpan(checked((int)address)));
    public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
    public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
    public SetBindingPair CreateImageBinding(int count, bool isBuffer) => throw new NotSupportedException();
    public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => throw new NotSupportedException();
    public int QuerySamplerArrayLengthFromPool() => throw new NotSupportedException();
    public int QueryTextureArrayLengthFromBuffer(int index) => throw new NotSupportedException();
    public int QueryTextureArrayLengthFromPool() => throw new NotSupportedException();
}
static partial class Program
{
    const ulong Sched = 0x001F8000FC0007E0UL, Exit = 0xE30000000007000FUL;
    static ulong Ast(int location, int component = 0, int reg = 0) => 0xEFF0000000000000UL | (0xFFUL << 39) | ((ulong)(0x80 + location * 16 + component * 4) << 20) | (7UL << 16) | (0xFFUL << 8) | (uint)reg;
    static ulong Ald(int location, int component = 0, int reg = 0) => 0xEFD8000000000000UL | (0xFFUL << 39) | ((ulong)(0x80 + location * 16 + component * 4) << 20) | (7UL << 16) | (0xFFUL << 8) | (uint)reg;
    static byte[] Guest(bool fragment, ulong[] ops, int[] reads = null, int interpolation = 2)
    {
        int blocks = (ops.Length + 1 + 2) / 3;
        byte[] b = new byte[0x50 + blocks * 32];
        BinaryPrimitives.WriteUInt32LittleEndian(b, fragment ? 2u | (3u << 5) | (5u << 10) : 1u | (3u << 5) | (1u << 10));
        if (fragment)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(72), 15);
            foreach (int location in reads ?? []) b[24 + location] = (byte)(interpolation * 0x55);
        }
        for (int i = 0; i < blocks * 4; i++)
        {
            int oi = i / 4 * 3 + i % 4 - 1;
            ulong op = i % 4 == 0 ? Sched : oi < ops.Length ? ops[oi] : Exit;
            BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(0x50 + i * 8), op);
        }
        return b;
    }
    static byte[] Geometry()
    {
        var b = Guest(false, []);
        BinaryPrimitives.WriteUInt32LittleEndian(b, 1u | (3u << 5) | (4u << 10) | (1u << 24));
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(8), 1u << 24);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(12), 7u << 24);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(16), 3);
        return b;
    }
    sealed record Module(string Name, ShaderProgram Shader, uint[] MappedStorage);
    static List<Module> Translate(bool linked, int[] writes, int[] reads, string route, TargetLanguage language, int component = 0, int interpolation = 2, int vertexLimit = 128, int fragmentLimit = 128)
    {
        TranslatorContext.S2AStageIndep = linked && language == TargetLanguage.Spirv; // GLSL paired oracle keeps its existing switch; separate cases cover stage-independent mode.
        bool native = route == "native-gs";
        var options = new TranslationOptions(language, TargetApi.Vulkan, TranslationFlags.DebugMode);
        TranslatorContext Context(byte[] code, TranslationOptions? opt = null) => Translator.CreateContext(0, new Accessor(code, linked, vertexLimit, fragmentLimit, native), opt ?? options);
        var f = Context(Guest(true, reads.Select((l, i) => Ald(l, component, i)).ToArray(), reads, interpolation));
        var v = Context(Guest(false, writes.Select(l => Ast(l, component)).ToArray()));
        var result = new List<Module>();
        if (route == "vertex-a")
        {
            var a = Context(Guest(false, [Ast(31, component)]), new TranslationOptions(language, TargetApi.Vulkan, TranslationFlags.VertexA | TranslationFlags.DebugMode));
            v = Context(Guest(false, [Ald(31, component), Ast(31, component)]));
            v.SetNextStage(f);
            result.Add(new("vertex", v.Translate(a), [3]));
        }
        else if (route is "vtg" or "native-gs")
        {
            var g = Context(Geometry()); g.SetNextStage(f); v.SetNextStage(g);
            if (route == "vtg")
            {
                g.SetVertexOutputMapForGeometryAsCompute(v);
                result.Add(new("vertex-compute", v.Translate(true), []));
                result.Add(new("vertex", g.GenerateVertexPassthroughForCompute(), [3]));
                result.Add(new("geometry-compute", g.Translate(true), []));
            }
            else
            {
                result.Add(new("vertex", v.Translate(), [3]));
                result.Add(new("geometry", g.Translate(), [1, 3]));
            }
        }
        else { v.SetNextStage(f); result.Add(new("vertex", v.Translate(), [3])); }
        result.Add(new("fragment", f.Translate(), [1]));
        return result;
    }
    static byte[] Normalize(byte[] bytes, uint[] storage, int[] inverse)
    {
        var w = MemoryMarshal.Cast<byte, uint>(bytes).ToArray(); var variables = new HashSet<uint>();
        for (int i = 5; i < w.Length; i += (int)(w[i] >> 16))
            if ((w[i] & 65535) == 59 && storage.Contains(w[i + 3])) variables.Add(w[i + 2]);
        for (int i = 5; i < w.Length; i += (int)(w[i] >> 16))
            if ((w[i] & 65535) == 71 && w[i + 2] == 30 && variables.Contains(w[i + 1]))
                w[i + 3] = (uint)inverse[checked((int)w[i + 3])];
        return MemoryMarshal.AsBytes(w.AsSpan()).ToArray();
    }
    static string NormalizeGlsl(string text, uint[] storage, int[] inverse) => Regex.Replace(text, @"layout \((?<layout>[^\r\n)]*location = )(?<loc>\d+)(?<tail>[^\r\n)]*)\)(?<decl>[^;\r\n]*);", m =>
    {
        string decl = m.Groups["decl"].Value;
        bool match = storage.Contains(1u) && Regex.IsMatch(decl, @"\bin\b") || storage.Contains(3u) && Regex.IsMatch(decl, @"\bout\b");
        return match ? "layout (" + m.Groups["layout"].Value + inverse[int.Parse(m.Groups["loc"].Value)] + m.Groups["tail"].Value + ")" + decl + ";" : m.Value;
    });
    static readonly List<object> Checks = new();
    static int Failed;
    static void Check(string name, bool pass)
    {
        Checks.Add(new { name, pass }); if (!pass) Failed++;
        Console.WriteLine($"{(pass ? "PASS" : "FAIL")} {name}");
    }
    static string Output;
    static void Case(string name, int[] writes, int[] reads, string route = "direct", TargetLanguage language = TargetLanguage.Spirv, int component = 0, int interpolation = 2)
    {
        var reference = Translate(false, writes, reads, route, language, component, interpolation);
        var linked = Translate(true, writes, reads, route, language, component, interpolation);
        int[] inverse = writes.Concat(reads).Distinct().Order().ToArray();
        foreach (var pair in linked.Zip(reference))
        {
            var a = pair.First; var b = pair.Second; string stem = Path.Combine(Output, name + "-" + a.Name);
            bool same;
            if (language == TargetLanguage.Spirv)
            {
                File.WriteAllBytes(stem + ".spv", a.Shader.BinaryCode);
                same = Normalize(a.Shader.BinaryCode, a.MappedStorage, inverse).SequenceEqual(b.Shader.BinaryCode);
            }
            else
            {
                File.WriteAllText(stem + (a.Name == "fragment" ? ".frag" : a.Name == "geometry" ? ".geom" : ".vert"), a.Shader.Code);
                same = a.Shader.Code == b.Shader.Code; // GLSL retains logical locations and legacy pairing.
            }
            Check(name + "/" + a.Name + " preserves complete module except paired Location", same);
        }
    }
    static void Rejected(string name, Action action)
    {
        try { action(); Check(name, false); }
        catch (NotSupportedException e) { Check(name, e.Message.Contains("interface") || e.Message.Contains("varying")); Console.WriteLine(e.Message); }
    }
    static void DynamicCase(bool sparse, bool passthrough, int sparseLocation = 31)
    {
        TranslatorContext.S2AStageIndep = false;
        var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
        ulong indexed = (Ast(0) & ~((0x7ffUL << 20) | (0xffUL << 8))) | (1UL << 8);
        List<Module> Build(bool linked)
        {
            var v = Translator.CreateContext(0, new Accessor(Guest(false, [indexed]), linked, nativeGs: passthrough), options);
            var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(sparse ? sparseLocation : 0)], [sparse ? sparseLocation : 0]), linked, nativeGs: passthrough), options);
            var result = new List<Module>();
            if (passthrough)
            {
                var g = Translator.CreateContext(0, new Accessor(Geometry(), linked, nativeGs: true), options);
                g.SetNextStage(f); v.SetNextStage(g);
                result.Add(new("vertex", v.Translate(), [3])); result.Add(new("geometry", g.Translate(), [1, 3]));
            }
            else { v.SetNextStage(f); result.Add(new("vertex", v.Translate(), [3])); }
            result.Add(new("fragment", f.Translate(), [1]));
            return result;
        }
        var candidate = Build(true); var baseline = Build(false);
        string name = $"dynamic-{(sparse ? sparseLocation : 0)}-{passthrough}";
        foreach (var m in candidate) File.WriteAllBytes(Path.Combine(Output, name + "-" + m.Name + ".spv"), m.Shader.BinaryCode);
        foreach (var m in baseline) File.WriteAllBytes(Path.Combine(Output, name + "-legacy-" + m.Name + ".spv"), m.Shader.BinaryCode);
        Check(name + "/complete identity modules unchanged", candidate.Zip(baseline).All(p => p.First.Shader.BinaryCode.SequenceEqual(p.Second.Shader.BinaryCode)));
    }
    static Capabilities Set(Capabilities caps, string field, object value)
    {
        object boxed = caps; typeof(Capabilities).GetField(field).SetValue(boxed, value); return (Capabilities)boxed;
    }
    // Inspect the real translated modules without requiring a disassembler in the gate.
    static (string kind, uint vectorType, uint[][] instructions) ImageComponent(byte[] bytes, string variable)
    {
        uint[] words = MemoryMarshal.Cast<byte, uint>(bytes).ToArray();
        var instructions = new List<uint[]>();
        for (int i = 5; i < words.Length;)
        {
            int length = (int)(words[i] >> 16);
            if (length == 0 || i + length > words.Length) throw new InvalidDataException("Invalid SPIR-V instruction length");
            instructions.Add(words[i..(i + length)]); i += length;
        }
        uint[] named = instructions.Single(x => (x[0] & 65535) == 5 &&
            System.Text.Encoding.UTF8.GetString(MemoryMarshal.AsBytes(x.AsSpan(2))).TrimEnd('\0') == variable);
        uint[] variableInst = instructions.Single(x => (x[0] & 65535) == 59 && x[2] == named[1]);
        uint[] pointer = instructions.Single(x => (x[0] & 65535) == 32 && x[1] == variableInst[1]);
        uint[] sampled = instructions.Single(x => (x[0] & 65535) == 27 && x[1] == pointer[3]);
        uint[] image = instructions.Single(x => (x[0] & 65535) == 25 && x[1] == sampled[2]);
        uint[] component = instructions.Single(x => x.Length > 1 && x[1] == image[2] && (x[0] & 65535) is 21 or 22);
        string kind = (component[0] & 65535) == 22 ? "float" : component[3] == 0 ? "uint" : "sint";
        uint[] vector = instructions.FirstOrDefault(x => (x[0] & 65535) == 23 && x[2] == image[2] && x[3] == 4);
        return (kind, vector?[1] ?? 0, instructions.ToArray());
    }

    static void TexelNumericTypes()
    {
        var modules = Translate(false, [0], [], "vtg", TargetLanguage.Spirv);
        foreach (var (name, variable) in new[] { ("vertex-compute", "ib_data"), ("geometry-compute", "trb_data") })
        {
            byte[] bytes = modules.Single(m => m.Name == name).Shader.BinaryCode;
            File.WriteAllBytes(Path.Combine(Output, name + "-numeric.spv"), bytes);
            var (kind, vectorType, instructions) = ImageComponent(bytes, variable);
            var fetches = instructions.Where(x => (x[0] & 65535) == 95).ToArray();
            Check(name + "/" + variable + " sampled type is uint32", kind == "uint");
            Check(name + "/fetch uses uint32 vector", kind == "uint" && vectorType != 0 && fetches.Length > 0 && fetches.All(x => x[1] == vectorType));
        }
        var glsl = Translate(false, [0], [], "vtg", TargetLanguage.Glsl);
        Check("GLSL vertex index uses unsigned sampler", glsl.Single(m => m.Name == "vertex-compute").Shader.Code.Contains("usamplerBuffer ib_data"));
        Check("GLSL geometry remap uses unsigned sampler", glsl.Single(m => m.Name == "geometry-compute").Shader.Code.Contains("usamplerBuffer trb_data"));
        foreach (var m in glsl.Where(m => m.Name.EndsWith("-compute")))
            File.WriteAllText(Path.Combine(Output, m.Name + "-numeric.comp"), m.Shader.Code);
        var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
        foreach (var (type, expected) in new[] {
            (AttributeType.Float, "float"), (AttributeType.Uint, "uint"), (AttributeType.Sint, "sint"),
            (AttributeType.Uscaled, "uint"), (AttributeType.Sscaled, "sint"),
            (AttributeType.Float | AttributeType.TexelInvalidFormat, "float"),
            (AttributeType.Uscaled | AttributeType.TexelInvalidFormat, "float"),
            (AttributeType.Sscaled | AttributeType.Packed | AttributeType.TexelInvalidFormat, "float"),
            (AttributeType.Sint | AttributeType.Packed | AttributeType.TexelInvalidFormat, "sint"),
            (AttributeType.Uint | AttributeType.Packed | AttributeType.TexelInvalidFormat, "uint"),
            (AttributeType.Float | AttributeType.TexelDecode, "uint"), (AttributeType.Sint | AttributeType.TexelDecode, "uint"),
            (AttributeType.Float | AttributeType.Packed, "float"),
            (AttributeType.Uint | AttributeType.Packed, "uint"), (AttributeType.Uscaled | AttributeType.Packed, "uint"),
            (AttributeType.Float | AttributeType.Packed | AttributeType.PackedRgb10A2Signed, "uint"),
            (AttributeType.Sint | AttributeType.Packed | AttributeType.PackedRgb10A2Signed, "uint"),
            (AttributeType.Sscaled | AttributeType.Packed | AttributeType.PackedRgb10A2Signed, "sint"),
            (AttributeType.Sscaled | AttributeType.Packed | AttributeType.PackedRgb10A2Signed | AttributeType.TexelDecode, "uint") })
        {
            var accessor = new Accessor(Guest(false, [Ald(0), Ast(0)]), false, attributeType: type);
            var vertex = Translator.CreateContext(0, accessor, options);
            byte[] bytes = vertex.Translate(true).BinaryCode;
            File.WriteAllBytes(Path.Combine(Output, $"vertex-attribute-{(byte)type:x2}.spv"), bytes);
            var (kind, _, _) = ImageComponent(bytes, "vb_data0");
            Check("vertex texel " + type + " sampled type " + expected, kind == expected);
            if (type is AttributeType.Float or AttributeType.Uint or AttributeType.Sint || type == (AttributeType.Float | AttributeType.TexelDecode))
            {
                var glslOptions = new TranslationOptions(TargetLanguage.Glsl, TargetApi.Vulkan, TranslationFlags.DebugMode);
                var glslAccessor = new Accessor(Guest(false, [Ald(0), Ast(0)]), false, attributeType: type);
                string code = Translator.CreateContext(0, glslAccessor, glslOptions).Translate(true).Code;
                File.WriteAllText(Path.Combine(Output, $"vertex-attribute-{(byte)type:x2}.comp"), code);
                string sampler = expected == "uint" ? "usamplerBuffer" : expected == "sint" ? "isamplerBuffer" : "samplerBuffer";
                Check("GLSL vertex texel " + type + " uses " + sampler, code.Contains("uniform " + sampler + " vb_data0"));
            }
        }
        foreach (var type in new[] { AttributeType.Sint, AttributeType.Float | AttributeType.TexelDecode,
            AttributeType.Sint | AttributeType.Packed | AttributeType.PackedRgb10A2Signed })
        {
            var accessor = new Accessor(Guest(false, [Ald(0, 2), Ast(0)]), false, attributeType: type);
            var vertex = Translator.CreateContext(0, accessor, options);
            byte[] bytes = vertex.Translate(true).BinaryCode;
            File.WriteAllBytes(Path.Combine(Output, $"vertex-component2-{(byte)type:x2}.spv"), bytes);
            var (kind, _, _) = ImageComponent(bytes, "vb_data0");
            Check("vertex texel component2 " + type + " sampled type", kind == (type == AttributeType.Sint ? "sint" : "uint"));
        }
    }
    static int Main(string[] args)
    {
        if (args.Length != 0) return Run(args);
        string temporary = Path.Combine(Path.GetTempPath(), "s2a-varying-" + Guid.NewGuid().ToString("N"));
        try { return Run([temporary]); }
        finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
    }
    static int Run(string[] args)
    {
        Output = args[0]; Directory.CreateDirectory(Output);
        if (args.Length > 1 && args[1] == "late-interface") return LateInterfaceCases();
        if (args.Length > 1 && args[1] == "vtg-layer") return VtgLayerCase();
        if (args.Length > 1 && args[1] == "spirv-layer") return SpirvLayerCase();
        SpirvLayerCase();
        TexelNumericTypes();
        foreach (string route in new[] { "direct", "vtg", "native-gs" })
        {
            foreach (var c in new[] { ("zero", new[] { 0 }, new[] { 0 }), ("sparse", new[] { 31 }, new[] { 31 }), ("both", new[] { 0, 31 }, new[] { 0, 31 }), ("default", new[] { 0 }, new[] { 31 }), ("unconsumed", new[] { 0, 31 }, new[] { 0 }) })
                Case(route + "-" + c.Item1, c.Item2, c.Item3, route);
        }
        Case("no-input", [31], []);
        Case("component3-flat", [31], [31], component: 3, interpolation: 1);
        Case("component2-noperspective", [0, 31], [0, 31], component: 2, interpolation: 3);
        Case("vertex-a", [31], [31], "vertex-a");
        Case("glsl-sparse", [31], [31], language: TargetLanguage.Glsl);
        Case("glsl-both", [0, 31], [0, 31], language: TargetLanguage.Glsl, interpolation: 1);
        Case("glsl-native", [31], [31], "native-gs", TargetLanguage.Glsl);
        Rejected("actual 32 outputs cannot fit; no output dropped", () => Translate(true, Enumerable.Range(0, 32).ToArray(), [0], "direct", TargetLanguage.Spirv));
        // Actual SPIR-V declares Position4 + PointSize1 + ClipDistance[8] + CullDistance[1].
        Check("exact 18-component vertex budget passes", Translate(true, [31], [31], "direct", TargetLanguage.Spirv, vertexLimit: 18).Count == 2);
        Rejected("17-component vertex budget rejects", () => Translate(true, [31], [31], "direct", TargetLanguage.Spirv, vertexLimit: 17));
        Rejected("3-component fragment budget rejects vec4", () => Translate(true, [31], [31], "direct", TargetLanguage.Spirv, fragmentLimit: 3));
        // Unknown limit (0, a profile that never measured it) does not block linking; measured positive limits still do (the 17 / 3 cases above).
        //   Same contract as the direct compiler (graphics/tools/direct/tests/compiler: "linked accepts unknown/zero limit").
        Check("unknown vertex limit links without a budget check", Translate(true, [31], [31], "direct", TargetLanguage.Spirv, vertexLimit: 0).Count == 2);
        Check("unknown fragment limit links without a budget check", Translate(true, [31], [31], "direct", TargetLanguage.Spirv, fragmentLimit: 0).Count == 2);
        DynamicCase(false, false); Check("dynamic dense identity retains legacy emission", true);
        DynamicCase(false, true); Check("dynamic dense native passthrough retains legacy emission", true);
        DynamicCase(true, false, 5); Check("dynamic sparse in-range identity retains legacy emission", true);
        DynamicCase(true, true, 5); Check("dynamic sparse passthrough in-range identity retains legacy emission", true);
        Rejected("dynamic sparse beyond actual array domain is diagnosed", () => DynamicCase(true, false));
        Rejected("dynamic upstream passthrough constraint reaches final link", () => DynamicCase(true, true));
        var metal = NxGal.NxCaps.Build([0UL, 32768UL]);
        string legacyMetalKey = HostCacheCapabilities.GetIdentity(metal);
        Check("legacy Metal EXT cache identity remains unchanged",
            legacyMetalKey == "4763d53bec86ebf18bb7b2296b6b23f040d85133aa08c51639fe86e958743090");
        var noLayerRoute = Set(metal, nameof(Capabilities.S2ASpirvLayerExt), false);
        var nvLayerRoute = Set(noLayerRoute, nameof(Capabilities.S2ASpirvLayerNv), true);
        var extAndNv = Set(metal, nameof(Capabilities.S2ASpirvLayerNv), true);
        var coreLayerRoute = Set(metal, nameof(Capabilities.S2ASpirv15), true);
        Check("unsupported layer route cannot load legacy EXT cache", HostCacheCapabilities.GetIdentity(noLayerRoute) != legacyMetalKey);
        Check("NV layer route has distinct cache identity", HostCacheCapabilities.GetIdentity(nvLayerRoute) != legacyMetalKey && HostCacheCapabilities.GetIdentity(nvLayerRoute) != HostCacheCapabilities.GetIdentity(noLayerRoute));
        Check("EXT preferred over NV retains legacy cache identity", HostCacheCapabilities.GetIdentity(extAndNv) == legacyMetalKey);
        Check("SPIR-V 1.5 core has distinct cache identity", HostCacheCapabilities.GetIdentity(coreLayerRoute) != legacyMetalKey);
        Check("Metal uses Vulkan API but retains legacy policy", metal.Api == TargetApi.Vulkan && !metal.RequiresLinkedVaryingInterface);
        TranslatorContext.S2AStageIndep = true;
        var legacy = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(0)]), false), new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode));
        legacy.S2ASetStandaloneNextFragment();
        var legacyWords = MemoryMarshal.Cast<byte, uint>(legacy.Translate().BinaryCode).ToArray();
        Check("legacy standalone Metal padding still has Location31", HasLocation31(legacyWords));
        var caps = Set(metal, nameof(Capabilities.RequiresLinkedVaryingInterface), true);
        caps = Set(caps, nameof(Capabilities.MaximumVertexOutputComponents), 128);
        caps = Set(caps, nameof(Capabilities.MaximumFragmentInputComponents), 128);
        string identity = HostCacheCapabilities.GetIdentity(caps);
        Check("same effective linked caps have same cache identity", identity == HostCacheCapabilities.GetIdentity(caps));
        foreach (var field in new[] { nameof(Capabilities.RequiresLinkedVaryingInterface), nameof(Capabilities.MaximumVertexOutputComponents), nameof(Capabilities.MaximumFragmentInputComponents) })
            Check("cache identity changes: " + field, identity != HostCacheCapabilities.GetIdentity(Set(caps, field, field.StartsWith("Requires") ? false : 124)));
        bool oldSpirv = Ryujinx.Graphics.Gpu.GraphicsConfig.EnableSpirvCompilationOnVulkan;
        Ryujinx.Graphics.Gpu.GraphicsConfig.EnableSpirvCompilationOnVulkan = false;
        Check("actual GLSL selection has distinct host cache identity", identity != HostCacheCapabilities.GetIdentity(caps));
        Ryujinx.Graphics.Gpu.GraphicsConfig.EnableSpirvCompilationOnVulkan = oldSpirv;
        Check("restoring actual SPIRV selection restores identity", identity == HostCacheCapabilities.GetIdentity(caps));
        File.WriteAllText(Path.Combine(Output, "results.json"), JsonSerializer.Serialize(new { failed = Failed, checks = Checks }, new JsonSerializerOptions { WriteIndented = true }));
        return Failed == 0 ? 0 : 1;
    }
    static bool HasLocation31(uint[] w)
    {
        for (int i = 5; i < w.Length; i += (int)(w[i] >> 16)) if ((w[i] & 65535) == 71 && w[i + 2] == 30 && w[i + 3] == 31) return true;
        return false;
    }
}
