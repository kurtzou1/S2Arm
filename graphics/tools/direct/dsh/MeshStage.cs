// NVN2（Switch 2）任务 / 网格着色器 → Metal 对象 / 网格函数。移植自 上游参考实现（MIT） dm/gfx/tools/dmsh_meshstage.py（主线提交 1d4b8e82b，MIT），按我方链改写：
//   控制段 +0x56 阶段字节 6 任务（ts）/ 7 网格（ms），SPH 却读作顶点或域。翻译器把它当计算着色器翻（去掉 0x80 字节 SPH，作业 stage_memory 给阶段内存在共享内存里的位置：
//   InstEmitAmpereMem.cs AIsberd / AStageOut 按 IGpuAccessor.QueryAmpereStageMemory 读写），本文件把翻出的计算核包成 Metal 的阶段函数：包装填阶段输入、调计算核本体、把阶段输出交给 Metal。
// 阶段内存（共享内存，Memory()；本体开始时全 0）：
//   字 0       本组工作组号（ISBERD 模式 0x78）：任务 = 本次绘制起始工作组号 + 线程组号；无任务的网格同
//   INPUT      网格着色器读的、它的任务写的载荷（ISBERD 模式 0x38）。字 0 = 本组在其任务派生里的序号（硬件放的，包装填）
//   输出       任务的载荷（0xb8）：字 1 = 要派生的网格工作组数，记录从 +0x10 起；
//              或网格的属性（0xf8）：先全部顶点块（每 32 个顶点一块，SPH OMAP 开的顶点分量各 0x80 字节，一顶点一字），再全部图元块（每 32 个图元一块，逐图元 SPH 的分量各 0x80 字节）；大小按两者交错算的上界留（Memory），够放
//   图元       网格的图元字节：+3 图元数（0x88），+4 起每三角形三个索引字节（0x80）
// 接口约定：side-session-notes 22_网格着色接口约定.md（入口名、缓冲槽 29、反射字段）
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace S2A.Dsh
{
    /// <summary>任务 / 网格着色器的事实（控制段 + 整个代码区）</summary>
    internal sealed class MeshInfo
    {
        public string Kind;                 // "ts" / "ms"
        public int Threads, Payload;        // +0x58 每组线程数，+0x5a 载荷字节数
        public bool Task;                   // 网格：+0x5e 非 0 = 有任务着色器
        public int MaxV, MaxP;              // 网格：+0x60 / +0x62 最多顶点 / 图元
        public List<(int? N, int C)> Vertex = new(), Primitive = new();   // 属性区的分量顺序：(null, c) 位置分量，(n, c) 通用属性 n 的分量 c

        public JsonObject ToJson()
        {
            static JsonArray Comps(List<(int? N, int C)> l) => new(l.Select(x => (JsonNode)new JsonArray(x.N is int n ? JsonValue.Create(n) : null, JsonValue.Create(x.C))).ToArray());
            return new JsonObject { ["kind"] = Kind, ["threads"] = Threads, ["payload"] = Payload, ["task"] = Task, ["max_v"] = MaxV, ["max_p"] = MaxP, ["vertex"] = Comps(Vertex), ["primitive"] = Comps(Primitive) };
        }
        public static MeshInfo FromJson(JsonObject o)
        {
            static List<(int?, int)> Comps(JsonNode a) => a.AsArray().Select(x => (x[0] is JsonNode n ? (int?)(int)n : null, (int)x[1])).ToList();
            return new MeshInfo { Kind = (string)o["kind"], Threads = (int)o["threads"], Payload = (int)o["payload"], Task = (bool)o["task"], MaxV = (int)o["max_v"], MaxP = (int)o["max_p"], Vertex = Comps(o["vertex"]), Primitive = Comps(o["primitive"]) };
        }
    }

    internal static class MeshStage
    {
        public const int WORKGROUP = 0, INPUT = 0x10, BLOCK = 32;
        public const int METAL_MAX_VERTICES = 256, METAL_MAX_PRIMITIVES = 512;   // Metal 网格的上限
        public const int METAL_MAX_GRID = 1024;                                // 一个对象线程组能派生的网格线程组数
        public const int METAL_MAX_SHARED = 0x8000;                            // Metal 函数的线程组内存
        public const int FIRST_SLOT = 29;                                      // 宿主放「本次绘制起始工作组号」的缓冲槽（接口约定 3）
        public const int METAL_MAX_PAYLOAD = 0x4000;                           // Metal 对象→网格载荷（object_data）上限 16 KB
        public const int RELAY_SLOT = 27;                                      // 载荷中转缓冲的槽（对象 / 网格两表；同计算核溢出槽 SPILL_SLOT，网格表这一格是顶点流 11，宿主经 enc_r_vbuf 绑）
        public const int RELAY_HEAD = 8;                                       // 中转缓冲头（字，宿主写）：[0] 网格片起点（字），[1] 本次绘制任务组数，[2] 每个任务组的网格片数（= 任务线程数）

        /// <summary>载荷超 Metal 对象载荷上限：走设备内存中转（任务把载荷写进中转缓冲、object_data 只带任务组号；网格的阶段内存整段放中转缓冲里一片）。
        ///   每个任务组留「任务线程数」片，派生数钳到它：NVN2 任务常见写法是每线程决定派不派一组、ballot + popcount 得派生数（07abb052：≤ 32），超出的组不画</summary>
        public static bool Relay(MeshInfo i) => i.Payload > METAL_MAX_PAYLOAD;
        /// <summary>中转时宿主要的大小（字）：一份载荷、一片网格阶段内存（都按 16 字节对齐；任务的片数 0）</summary>
        public static (int PayloadWords, int SliceWords) RelayWords(MeshInfo i) => ((((i.Payload + 3) >> 2) + 3) & ~3, i.Kind == "ms" ? ((Memory(i).Size >> 2) + 3) & ~3 : 0);

        /// <summary>控制段阶段字节 → "ts" / "ms" / null</summary>
        public static string Kind(byte[] ctl) => ctl != null && ctl.Length > 0x56 ? ctl[0x56] switch { 6 => "ts", 7 => "ms", _ => null } : null;

        /// <summary>SPH 的 OMAP 开的分量，按属性区顺序：先位置（字节 0x35 第 4..7 位），再通用属性 n（0x36 起每属性一个半字节，第 c 位 = 分量 c）</summary>
        public static List<(int? N, int C)> SphOutputs(ReadOnlySpan<byte> sph)
        {
            var o = new List<(int?, int)>();
            for (int c = 0; c < 4; c++) if ((sph[0x35] >> (4 + c) & 1) != 0) o.Add((null, c));
            for (int n = 0; n < 32; n++) for (int c = 0; c < 4; c++) if ((sph[0x36 + n / 2] >> (4 * (n % 2) + c) & 1) != 0) o.Add((n, c));
            return o;
        }

        /// <summary>控制段 + 整个代码区（SPH、指令、网格的逐图元 SPH）→ 事实。+0x64 是逐图元 SPH 在代码区里的偏移（+0x68 第 7 位置位时）</summary>
        public static MeshInfo Info(byte[] ctl, byte[] area)
        {
            var kind = Kind(ctl) ?? throw new DshError("bad record", "控制段阶段字节不是 6 / 7");
            if (ctl.Length < 0x6c) throw new DshError("bad record", $"任务 / 网格控制段只有 0x{ctl.Length:x} 字节（要读 +0x68）");
            var i = new MeshInfo { Kind = kind, Threads = BitConverter.ToUInt16(ctl, 0x58), Payload = BitConverter.ToUInt16(ctl, 0x5a) };
            if (kind == "ms")
            {
                if (area.Length < 0x80) throw new DshError("bad record", "网格代码区不足 0x80 字节的 SPH");
                i.Task = ctl[0x5e] != 0; i.MaxV = BitConverter.ToUInt16(ctl, 0x60); i.MaxP = BitConverter.ToUInt16(ctl, 0x62);
                uint at = (ctl[0x68] & 0x80) != 0 ? BitConverter.ToUInt32(ctl, 0x64) : 0;
                if (at != 0 && at + 0x80L > area.Length) throw new DshError("bad record", $"逐图元 SPH 偏移 0x{at:x} 出了代码区");
                i.Vertex = SphOutputs(area.AsSpan(0, 0x80));
                if (at != 0) i.Primitive = SphOutputs(area.AsSpan((int)at, 0x80)).Where(c => c.N != null).ToList();
            }
            return i;
        }

        /// <summary>（翻译器要的阶段内存偏移：工作组号、输入、输出、图元字节；共享内存字节数）</summary>
        public static (int[] Lay, int Size) Memory(MeshInfo i)
        {
            int outp = INPUT + (i.Kind == "ts" && Relay(i) ? 0 : (i.Payload + 15) & ~15);   // 任务不读输入（ISBERD 0x38）：中转时不再给它留载荷大小的输入区（11-12 一款体育游戏近海任务 07abb052：55824 → 27920 字节，回到 32 KB 内）
            if (i.Kind == "ts") return (new[] { WORKGROUP, INPUT, outp, outp + i.Payload }, outp + ((i.Payload + 3) & ~3));
            int blocks = (Math.Max(Math.Max(i.MaxV, i.MaxP), 1) + BLOCK - 1) / BLOCK;
            int prim = outp + blocks * Math.Max(i.Vertex.Count + i.Primitive.Count, 1) * BLOCK * 4;
            return (new[] { WORKGROUP, INPUT, outp, prim }, prim + ((4 + 3 * Math.Max(i.MaxP, 1) + 3) & ~3));
        }

        /// <summary>指令里有自己的共享内存访问（LDS / STS / ATOMS：DecoderAmpere 的 Ampere 操作码）：会压在阶段内存上，控制段又不给它的大小</summary>
        public static bool OwnShared(ReadOnlySpan<byte> code)
        {
            for (int o = 0; o + 16 <= code.Length; o += 16)
                if ((BitConverter.ToUInt16(code[o..]) & 0xfff) is 0x984 or 0x388 or 0x988 or 0x38c or 0x98c or 0xf8c) return true;
            return false;
        }

        // 计算核、它的参数、SPIRV-Cross 排在阶段内存之前的线程变量（私有变量的初值：GlobalToStorage.TryGenerateRawStorageOp 的上次命中项 uint _N = 0u;，上游参考实现（MIT）0f510fd5），再是阶段内存（第一个 threadgroup 数组）
        static readonly Regex s_kernel = new(@"kernel\s+void\s+main0\s*\(((?:[^()]|\([^()]*\))*)\)\s*\{\s*((?:(?!threadgroup\b)[^\n{};]+;\n\s*)*)threadgroup\s+spvUnsafeArray<uint,\s*(\d+)>\s+(\w+);\n", RegexOptions.CultureInvariant);
        static readonly Regex s_name = new(@"(\w+)\s*(?:\[\[.*\]\])?$", RegexOptions.CultureInvariant);
        static readonly Regex s_attr = new(@"\s*\[\[.*\]\]$", RegexOptions.CultureInvariant);
        static readonly Regex s_thread = new(@"^(uint3?)\s+(\w+)\s*\[\[(thread_position_in_threadgroup|threadgroup_position_in_grid)\]\]$", RegexOptions.CultureInvariant);

        /// <summary>参数表按最外层逗号切</summary>
        static List<string> Params(string text)
        {
            var o = new List<string>(); int depth = 0; var cur = new StringBuilder();
            foreach (char ch in text)
            {
                if (ch == ',' && depth == 0) { o.Add(cur.ToString().Trim()); cur.Clear(); continue; }
                if (ch is '(' or '[' or '<') depth++;
                if (ch is ')' or ']' or '>') depth--;
                cur.Append(ch);
            }
            if (cur.ToString().Trim().Length > 0) o.Add(cur.ToString().Trim());
            return o;
        }

        static string Name(string p)
        {
            var m = s_name.Match(p);
            if (!m.Success) throw new DshError("mesh stage failed", "计算核参数里找不到名字：" + p);
            return m.Groups[1].Value;
        }

        /// <summary>属性区分量拼成 float4：b[k] 是字的表达式，null = 着色器不写的分量（同顶点输出的初值 0, 0, 0, 1）</summary>
        static string Component(string[] b) => "float4(" + string.Join(", ", Enumerable.Range(0, 4).Select(k => b[k] != null ? $"as_type<float>({b[k]})" : k == 3 ? "1.0" : "0.0")) + ")";

        /// <summary>{n: [分量 x / y / z / w 在 comps 里的序号或 null]}，按 n 首次出现的顺序（null = 位置）</summary>
        static List<(int? N, int?[] Idx)> Members(List<(int? N, int C)> comps)
        {
            var o = new List<(int?, int?[])>();
            foreach (var n in comps.Select(x => x.N).Distinct())
                o.Add((n, Enumerable.Range(0, 4).Select(c => { int k = comps.IndexOf((n, c)); return k >= 0 ? (int?)k : null; }).ToArray()));
            return o;
        }

        /// <summary>翻好的计算核包成对象函数 main0（ts），或网格函数 main0 与 main0_z（ms：两种深度约定，同顶点着色器 VsDepth：main0 近平面 -w、main0_z 近平面 0）</summary>
        public static string ToStage(string msl, MeshInfo i)
        {
            string kind = i.Kind;
            var m = s_kernel.Match(msl);
            if (!m.Success) throw new DshError("mesh stage failed", kind + ": 没有以阶段内存开头的 kernel main0");
            var ps = Params(m.Groups[1].Value); string local = m.Groups[2].Value.Trim(); int words = int.Parse(m.Groups[3].Value); string mem = m.Groups[4].Value;
            var names = ps.Select(Name).ToList();
            var plain = ps.Select(p => s_attr.Replace(p, "")).ToList();
            // 计算核本体改成内联函数，阶段内存由包装持有：本体里的提前返回（没东西可写的线程）回到包装，照样交输出。线程变量留在本体里：每线程调一次，同计算核
            string src = msl[..m.Index] + "static inline __attribute__((always_inline)) void dm_stage_body(" + string.Join(", ", plain.Append($"threadgroup spvUnsafeArray<uint, {words}>& {mem}")) + ")\n{\n"
                + (local.Length > 0 ? "    " + local + "\n" : "") + msl[(m.Index + m.Length)..];
            string call = "dm_stage_body(" + string.Join(", ", names.Append(mem)) + ");";
            // 线程号 / 线程组号：计算核参数里有就用它的（一个属性在函数里只能出现一次），没有就包装自己加参数
            var own = new Dictionary<string, string>();
            foreach (var p in ps) { var t = s_thread.Match(p); if (t.Success) own[t.Groups[3].Value] = t.Groups[2].Value + (t.Groups[1].Value == "uint3" ? ".x" : ""); }
            string lid = own.GetValueOrDefault("thread_position_in_threadgroup", "dm_lid"), tg = own.GetValueOrDefault("threadgroup_position_in_grid", "dm_tg");
            var extra = new List<string>();
            foreach (var (a, v) in new[] { ("thread_position_in_threadgroup", "dm_lid"), ("threadgroup_position_in_grid", "dm_tg") }) if (!own.ContainsKey(a)) extra.Add($"uint {v} [[{a}]]");
            var (lay, _) = Memory(i);
            int thr = i.Threads, pay = (i.Payload + 3) >> 2;
            int wg = lay[0] >> 2, inp = lay[1] >> 2, outw = lay[2] >> 2, prim = lay[3];
            bool relay = Relay(i);
            var (payw, slicew) = RelayWords(i);   // 中转缓冲里一份载荷 / 一片网格阶段内存的字数：与反射给宿主的同一份（Dsh.cs mesh_relay_*）
            string relayArg = $"device uint* dm_relay [[buffer({RELAY_SLOT})]]";
            string bar = "    threadgroup_barrier(mem_flags::mem_threadgroup);\n";
            string start = $"    threadgroup spvUnsafeArray<uint, {words}> {mem};\n"
                         + $"    for (uint i = {lid}; i < {words}u; i += {thr}u) {mem}[i] = 0u;\n" + bar;
            string head = relay ? "struct dm_payload_t { uint tg; };\n" : $"struct dm_payload_t {{ uint w[{Math.Max(pay, 1)}]; }};\n";
            if (relay && kind == "ms")
            {
                // 网格的阶段内存（载荷输入 + 属性 + 图元，39 KB 超 32 KB）整段放中转缓冲：片号 = 任务组号 × 任务线程数 + 本网格组在其任务派生里的序号（任务把派生数钳到线程数）。
                //   同计算核溢出（gal_spill.c）：数组引用改 device、原子转型改 device、栅栏带 mem_device
                src = src.Replace($"threadgroup spvUnsafeArray<uint, {words}>&", $"device spvUnsafeArray<uint, {words}>&").Replace("(threadgroup atomic_uint*)", "(device atomic_uint*)")
                         .Replace("mem_flags::mem_threadgroup", "mem_flags::mem_device | mem_flags::mem_threadgroup");
                bar = "    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);\n";
                start = $"    device spvUnsafeArray<uint, {words}>& {mem} = *(device spvUnsafeArray<uint, {words}>*)(dm_relay + dm_relay[0] + (dm_payload.tg * dm_relay[2] + {tg}) * {slicew}u);\n"
                      + $"    for (uint i = {lid}; i < {words}u; i += {thr}u) {mem}[i] = 0u;\n" + bar;
            }
            string sig = string.Join(", ", ps.Concat(extra));
            string first = $"constant uint* dm_first [[buffer({FIRST_SLOT})]]";   // 本次绘制起始工作组号，宿主绑（接口约定 3）
            if (kind == "ts" && relay)
                return src + "\n" + head
                    + $"[[object]] void main0({sig}, object_data dm_payload_t& dm_payload [[payload]], mesh_grid_properties dm_grid, {first}, {relayArg})\n{{\n{start}"
                    + $"    if ({lid} == 0u) {mem}[{wg}] = dm_first[0] + {tg};\n"
                    + $"{bar}    {call}\n{bar}"
                    + $"    bool dm_in = {tg} < dm_relay[1];\n"
                    + $"    device uint* dm_p = dm_relay + {RELAY_HEAD}u + {tg} * {payw}u;\n"
                    + $"    if (dm_in) for (uint i = {lid}; i < {pay}u; i += {thr}u) dm_p[i] = {mem}[{outw}u + i];\n"
                    + $"    if ({lid} == 0u) {{ dm_payload.tg = {tg}; dm_grid.set_threadgroups_per_grid(uint3(dm_in ? min({mem}[{outw + 1}], {i.Threads}u) : 0u, 1u, 1u)); }}\n}}\n";
            if (kind == "ts")
                return src + "\n" + head
                    + $"[[object]] void main0({sig}, object_data dm_payload_t& dm_payload [[payload]], mesh_grid_properties dm_grid, {first})\n{{\n{start}"
                    + $"    if ({lid} == 0u) {mem}[{wg}] = dm_first[0] + {tg};\n"
                    + $"    threadgroup_barrier(mem_flags::mem_threadgroup);\n    {call}\n    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
                    + $"    for (uint i = {lid}; i < {pay}u; i += {thr}u) dm_payload.w[i] = {mem}[{outw}u + i];\n"
                    + $"    if ({lid} == 0u) dm_grid.set_threadgroups_per_grid(uint3(min({mem}[{outw + 1}], {METAL_MAX_GRID}u), 1u, 1u));\n}}\n";
            if (i.MaxV > METAL_MAX_VERTICES || i.MaxP > METAL_MAX_PRIMITIVES) throw new DshError("mesh stage failed", $"ms: {i.MaxV} 顶点 / {i.MaxP} 图元超 Metal 网格上限（{METAL_MAX_VERTICES} / {METAL_MAX_PRIMITIVES}）");
            // 属性区（硬件排法，着色器本体自己按它算地址）：先全部顶点块（每 32 个顶点一块、只含顶点分量，块长 nv × 0x80），紧接全部图元块（每 32 个图元一块、
            //   只含逐图元分量，块长 np × 0x80）。两者不交错：网格 192226654c410372（04008E001F098000 岛上植被，19 个顶点分量、3 个图元分量、160 顶点）本体写
            //   顶点 (v >> 5) × 2432、图元 12160 + (p >> 5) × 384（12160 = 5 块 × 2432）。原先按「每块顶点 + 图元分量交错、块长 (nv + np) × 0x80」读回，
            //   第 32 个起的顶点和全部图元属性都读错位置（植被出 NaN 成黑块）；没有逐图元分量时两种排法相同
            int nv = i.Vertex.Count, np = i.Primitive.Count;
            int vstride = Math.Max(nv, 1) * BLOCK, pstride = Math.Max(np, 1) * BLOCK;   // 一块的字数
            int pbase = (Math.Max(i.MaxV, 1) + BLOCK - 1) / BLOCK * vstride;              // 图元块从全部顶点块之后起
            string[] Word(int?[] comps) => Enumerable.Range(0, 4).Select(k => comps[k] is int c ? $"{mem}[b + {c * BLOCK}u]" : null).ToArray();
            var vm = Members(i.Vertex);
            var pm = Members(i.Primitive);
            if (!vm.Any(x => x.N == null)) throw new DshError("mesh stage failed", "ms: SPH 没开位置分量");
            head += "struct dm_vertex_t {\n    float4 position [[position]];\n" + string.Concat(vm.Where(x => x.N != null).Select(x => $"    float4 a{x.N} [[user(locn{x.N})]];\n")) + "};\n"
                  + (pm.Count > 0 ? "struct dm_prim_t {\n" + string.Concat(pm.Select(x => $"    float4 p{x.N} [[user(locn{x.N})]];\n")) + "};\n" : "")
                  + $"using dm_mesh_t = metal::mesh<dm_vertex_t, {(pm.Count > 0 ? "dm_prim_t" : "void")}, {i.MaxV}, {i.MaxP}, metal::topology::triangle>;\n";
            string Block(string v) => $"{outw}u + ({v} / {BLOCK}u) * {vstride}u + {v} % {BLOCK}u";
            string PBlock(string p) => $"{outw + pbase}u + ({p} / {BLOCK}u) * {pstride}u + {p} % {BLOCK}u";
            string sets = string.Concat(vm.Select(x => $"        v.{(x.N == null ? "position" : $"a{x.N}")} = {Component(Word(x.Idx))};\n"));
            string psets = string.Concat(pm.Select(x => $"        p.p{x.N} = {Component(Word(x.Idx))};\n"));
            string Entry(string name, bool gl)
            {
                // 有任务时输入是载荷，字 0 = 本组在其任务派生里的序号（硬件放的；任务从 +4 起写，+0 不是它写的字）
                string fill = i.Task
                    ? (relay ? $"    for (uint i = {lid}; i < {pay}u; i += {thr}u) {mem}[{inp}u + i] = dm_relay[{RELAY_HEAD}u + dm_payload.tg * {payw}u + i];\n"
                             : $"    for (uint i = {lid}; i < {pay}u; i += {thr}u) {mem}[{inp}u + i] = dm_payload.w[i];\n")
                      + bar
                      + $"    if ({lid} == 0u) {{ {mem}[{wg}] = {tg}; {mem}[{inp}] = {tg}; }}\n"
                    : $"    if ({lid} == 0u) {mem}[{wg}] = dm_first[0] + {tg};\n";
                return $"[[mesh]] void {name}({sig}, dm_mesh_t dm_out" + (i.Task ? ", const object_data dm_payload_t& dm_payload [[payload]]" : $", {first}") + (relay ? ", " + relayArg : "") + $")\n{{\n{start}{fill}"
                    + $"{bar}    {call}\n{bar}"
                    + $"    uint np = min({mem}[{prim >> 2}] >> 24, {i.MaxP}u);\n"
                    + $"    if ({lid} == 0u) dm_out.set_primitive_count(np);\n"
                    + $"    for (uint n = {lid}; n < {i.MaxV}u; n += {thr}u)\n    {{\n        uint b = {Block("n")};\n        dm_vertex_t v;\n{sets}"
                    + (gl ? "        v.position.z = fma(v.position.z, 0.5, v.position.w * 0.5);\n" : "")
                    + "        dm_out.set_vertex(n, v);\n    }\n"
                    + (pm.Count > 0 ? $"    for (uint n = {lid}; n < np; n += {thr}u)\n    {{\n        uint b = {PBlock("n")};\n        dm_prim_t p;\n{psets}        dm_out.set_primitive(n, p);\n    }}\n" : "")
                    + $"    for (uint n = {lid}; n < np * 3u; n += {thr}u)\n    {{\n        uint at = {prim + 4}u + n;\n        dm_out.set_index(n, ({mem}[at >> 2] >> ((at & 3u) * 8u)) & 0xffu);\n    }}\n}}\n";
            }
            return src + "\n" + head + Entry("main0", true) + "\n" + Entry("main0_z", false);
        }
    }
}
