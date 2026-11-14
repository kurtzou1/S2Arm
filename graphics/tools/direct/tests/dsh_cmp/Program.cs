// S2A.Dsh 对拍：直连包记录（<pkg>/*.bin，按 shader_map.tsv 找）逐键调现编，产物与离线链目录（b-<链版本>/）比。
//   .metal 逐字节；.json 按语义（字段同、值同），比之前两边都去掉三项：chain_metal（编法记录：离线 xcrun / 本库 newLibraryWithSource）、
//   vin / fetch（_bv / _bf 两个副库的索引，本库不出，见 dsh/DshCApi.cs 文件头）。三项各自的出现次数另报。
// 用法：dsh_cmp --ref <b-目录> --pkg <包目录> --map <shader_map.tsv> --tables <答案表 / 配对表目录> --out <输出目录>
//               [--backend cli|nxgal] [--dsx <libdsx.dylib>] [--keys all|sample:<N>|file:<键清单>] [--seed-pairs] [--print-keys] [-j <并发>] [--capi]
//               [--abi-only] [--mtl-list <文件>] [--report <tsv>]
//         dsh_cmp --fn <用例.json> <结果.json> [--dsx <库>]：逐函数对照（t_dsh_fn.py）
//         dsh_cmp --neg --tables <目录> --out <目录>：导出入口的失败路径（坏阶段 / 坏键 / 截短的控制段 / 没设 S2A_GAME_DATA）各返回非 0 且打一行【红】
//   --seed-pairs：抽样时，样本里顶点着色器的配对片元不在样本里的，先把离线那份 _b.metal 拷进输出目录（vs_pad 读它）
//   --abi-only：只比 json 的 bindings 与各入口名（内置 SPIRV-Cross 后端版本不同，MSL 可以不逐字同）；--mtl-list 写「.metal 路径<TAB>入口,…」给 Metal 校验器
//   --shd <目录>（要 --capi）：设备 DM_NVN_SHDUMP 转存的 <键>.ctl / <键>.code 逐个过导出入口（阶段同宿主 dsh_miss.inc dsh_stage：NVN 头 78563412 时 SPH 字 0 第 10..13 位
//     1 顶点 4 几何 5 像素，其余计算），--keys file:<清单> 只跑清单里的；每键打一行「shd <键> <阶段> <ms> ms <分配 MB> MB rc=<rc>」（本线程托管分配，量现编吃多少内存）
//   --capi：走导出入口 s2a_dsh_compile 的本体（S2A_GAME_DATA 指向临时目录，表链过去）；不给 --ref 时只出不比，产物留在 --out（与设备首遇现编写进兜底目录 DM_MSL_FALLBACK 的同一份）
//   --cover（不给 --ref）：覆盖率度量（11-04 Switch 2 接口面全量补齐）：每键照出包（PackOut）出一遍、不比不落盘，--report 每行
//     键 / 阶段 / ok|bad / 原因 / 静态扫到的未登记 Ampere 操作码（NVN2 键：指令区逐条查 AmpereTable，不被第一处失败遮住）/ 各产物 sha256 前 16 位（名=值，按名排序）；
//     产物指纹列给「改翻译器前后同一批键产物全同」的回归核对（Maxwell 键）；.json 先去掉 xfp（翻译器指纹，改翻译器必变）再算
using S2A.Dsh;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

static unsafe class DshCmp
{
    static readonly string[] Excluded = { "chain_metal", "vin", "fetch", "fn_prefix", "fn_lib", "writes_layer", "xfp" };   // xfp：现编 json 才带的翻译器指纹（离线库不带）；其前三项：离线成批合编（dmsh_build.py unity_flush）才有，设备现编不分批
    static readonly string[] Entries = { "entry", "entry_z", "entry_geometry_capture", "entry_tf", "entry_layer", "entry_layer_z", "entry_u" };
    [DllImport("libc")] static extern int setenv(string name, string value, int overwrite);

    static int Main(string[] argv)
    {
        var a = new Dictionary<string, string>();
        for (int i = 0; i < argv.Length; i++)
        {
            string k = argv[i];
            if (k is "--seed-pairs" or "--capi" or "--abi-only" or "--neg" or "--print-keys" or "--cover") a[k] = "1";
            else if (k == "--fn") { a["--fn"] = argv[++i]; a["--fn-out"] = argv[++i]; }
            else a[k] = argv[++i];
        }
        if (a.ContainsKey("--fn"))
        {
            ISpvCross nx = null;
            if (a.TryGetValue("--dsx", out var lib0)) { NativeLibrary.SetDllImportResolver(typeof(NxgalSpvCross).Assembly, (name, asm, path) => name == "dsx" ? NativeLibrary.Load(lib0) : IntPtr.Zero); nx = new NxgalSpvCross(); }
            return Fn.Run(a["--fn"], a["--fn-out"], nx);
        }
        string refDir = a.GetValueOrDefault("--ref"), pkg = a.GetValueOrDefault("--pkg"), map = a.GetValueOrDefault("--map"), tables = a["--tables"], outDir = a["--out"];
        string backend = a.GetValueOrDefault("--backend", "cli"), keysSpec = a.GetValueOrDefault("--keys", "all");
        int nj = int.Parse(a.GetValueOrDefault("-j", "6"));
        bool abiOnly = a.ContainsKey("--abi-only"), capi = a.ContainsKey("--capi"), cover = a.ContainsKey("--cover");
        DshCompiler.PackOut = !capi;   // 出包批量进程（dsh/batch）同一路径：曲面阶段可翻、写变体源码与 plain（变体不在 OutNames、不比）；--capi 照设备首遇现编
        // Both translation backends use libdsx's shared half export rewrite.
        if (a.TryGetValue("--dsx", out var rewriteLib))
            NativeLibrary.SetDllImportResolver(typeof(NxgalSpvCross).Assembly, (name, asm, path) => name == "dsx" ? NativeLibrary.Load(rewriteLib) : IntPtr.Zero);
        ISpvCross xc;
        if (backend == "nxgal")
        {
            string lib = a.GetValueOrDefault("--dsx") ?? throw new ArgumentException("--backend nxgal 要 --dsx <libdsx.dylib>");
            xc = new NxgalSpvCross();
        }
        else xc = new CliSpvCross();
        Directory.CreateDirectory(outDir);
        string work = Path.Combine(outDir, ".work"); Directory.CreateDirectory(work);
        string gameData = null;
        if (capi)
        {
            gameData = Path.Combine(work, "gd"); string d = Path.Combine(gameData, "shaders", "direct"); Directory.CreateDirectory(d);
            foreach (var n in new[] { "shader_facts.tsv", "shader_pairs.tsv", "shader_map.tsv", "shader_map.tsv.conflicts.tsv" })
                if (File.Exists(Path.Combine(tables, n))) File.Copy(Path.Combine(tables, n), Path.Combine(d, n), true);
            setenv("S2A_GAME_DATA", gameData, 1);
        }

        if (a.ContainsKey("--neg")) return Neg(tables, outDir, work, xc);
        if (a.TryGetValue("--shd", out var shd))
        {
            if (!capi) throw new ArgumentException("--shd 要 --capi");
            var only = keysSpec.StartsWith("file:") ? new HashSet<string>(File.ReadAllLines(keysSpec[5..]).Select(x => x.Trim()).Where(x => x.Length > 0)) : null;
            int bad = 0;
            foreach (var cp in Directory.GetFiles(shd, "*.ctl").OrderBy(x => x, StringComparer.Ordinal))
            {
                string key = Path.GetFileNameWithoutExtension(cp);
                if (only != null && !only.Contains(key)) continue;
                byte[] ctl = File.ReadAllBytes(cp), code = File.ReadAllBytes(Path.ChangeExtension(cp, ".code"));
                int st = 2;
                if (code.Length >= 0x34 && BitConverter.ToUInt32(code, 0) == 0x12345678)
                {
                    uint kind = BitConverter.ToUInt32(code, 0x30) >> 10 & 15;
                    st = kind == 1 ? 0 : kind == 4 ? 3 : kind == 5 ? 1 : (BitConverter.ToUInt32(code, 0x30) == 0x61 ? 0 : 2);
                }
                byte[] k8 = Encoding.UTF8.GetBytes(key + "\0"), o8 = Encoding.UTF8.GetBytes(outDir + "\0");
                long a0 = GC.GetAllocatedBytesForCurrentThread(); var t0 = Stopwatch.StartNew(); int rc;
                fixed (byte* kp = k8, cpp = code, tp = ctl, op = o8) rc = DshCApi.CompileCore(kp, st, cpp, (nuint)code.Length, tp, (nuint)ctl.Length, op, xc);
                Console.WriteLine($"shd {key} {new[] { "vs", "ps", "cs", "gs" }[st]} {t0.Elapsed.TotalMilliseconds:F1} ms {(GC.GetAllocatedBytesForCurrentThread() - a0) / 1048576.0:F1} MB rc={rc}");
                if (rc != 0) bad++;
            }
            return bad == 0 ? 0 : 1;
        }

        // ---- 键 → (包, 序号)；阶段按包名前两字（同 dmsh_build.py job_for 的 name[:2]）----
        var loc = new Dictionary<string, (string Pkg, int Idx)>();
        foreach (var ln in File.ReadLines(map))
        {
            var c = ln.Split('\t');
            if (c.Length > 4 && c[0].EndsWith(".bin")) loc.TryAdd(c[3], (c[0], int.Parse(c[1])));
        }
        var pairs = new Dictionary<string, HashSet<string>>();
        foreach (var ln in File.ReadLines(Path.Combine(tables, "shader_pairs.tsv")))
        {
            if (ln.Trim().Length == 0 || ln.StartsWith('#')) continue;
            var c = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            if (!pairs.TryGetValue(c[0], out var s)) pairs[c[0]] = s = new HashSet<string>(); s.Add(c[1]);
        }
        var all = loc.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        List<string> keys;
        if (keysSpec == "all") keys = all;
        else if (keysSpec.StartsWith("file:")) keys = File.ReadAllLines(keysSpec[5..]).Select(x => x.Trim()).Where(x => x.Length == 16).ToList();
        else if (keysSpec.StartsWith("sample:"))
        {
            // 分层抽样：几何全取，其余按 计算 / 顶点 / 片元 约 1 : 3 : 4 分（不够就全取），种子固定
            int n = int.Parse(keysSpec[7..]); var rng = new Random(20261024);
            var by = all.GroupBy(k => loc[k].Pkg[..2]).ToDictionary(g => g.Key, g => g.OrderBy(_ => rng.Next()).ToList());
            keys = new List<string>(by.GetValueOrDefault("gs", new()));
            int rest = Math.Max(0, n - keys.Count);
            foreach (var (st, part) in new[] { ("cs", 1), ("vs", 3), ("ps", 4) })
                keys.AddRange(by.GetValueOrDefault(st, new()).Take(Math.Max(1, rest * part / 8)));
            foreach (var k in by.GetValueOrDefault("ps", new()).Concat(by.GetValueOrDefault("vs", new())))   // 取整剩下的名额补片元 / 顶点
                if (keys.Count < n && !keys.Contains(k)) keys.Add(k);
            keys = keys.Take(n).OrderBy(k => k, StringComparer.Ordinal).ToList();
        }
        else throw new ArgumentException("--keys " + keysSpec);
        var keySet = new HashSet<string>(keys);
        if (cover) DshCompiler.PackMslKeep = new HashSet<string>(pairs.Values.SelectMany(v => v).Select(p => p + "_b.metal"));   // --cover：只留配对顶点要读的片元 MSL（vs_pad），其余不常驻
        if (a.ContainsKey("--print-keys"))   // 只打本次会比的键 + 它们的配对（门禁按它让离线链只出这些键当考卷，t_dsh.sh exam），不比
        {
            foreach (var k in keys.Concat(keys.SelectMany(k => pairs.GetValueOrDefault(k, new()))).Distinct().OrderBy(k => k, StringComparer.Ordinal)) Console.WriteLine(k);
            return 0;
        }
        if (a.ContainsKey("--seed-pairs"))
        {
            int seeded = 0;
            foreach (var k in keys) foreach (var p in pairs.GetValueOrDefault(k, new()))
                    if (!keySet.Contains(p) && File.Exists(Path.Combine(refDir, p + "_b.metal"))) { File.Copy(Path.Combine(refDir, p + "_b.metal"), Path.Combine(outDir, p + "_b.metal"), true); seeded++; }
            Console.WriteLine($"配对片元预置：{seeded} 份离线 _b.metal（样本外的配对）");
        }

        // ---- 包记录（同 merge_extract.split_rec：头 +0x28 控制段长、+0x2c 机器码长）----
        var packs = new ConcurrentDictionary<string, List<byte[]>>();
        List<byte[]> Records(string name) => packs.GetOrAdd(name, n =>
        {
            var d = File.ReadAllBytes(Path.Combine(pkg, n)); var sep = "BTCDBTCD"u8.ToArray(); var o = new List<byte[]>();
            int p = d.AsSpan().IndexOf(sep);
            while (p >= 0) { int q = d.AsSpan(p + 1).IndexOf(sep); q = q < 0 ? d.Length : q + p + 1; o.Add(d[p..q]); p = q < d.Length ? q : -1; }
            return o;
        });
        // 本款曲面域与各域最常见的模式（同 dmsh_build.py TESS_MODES：所有域着色器控制段的曲面模式 TessCtl.Nvn1；Counter.most_common 并列取先出现的）
        var tm = new Dictionary<int, List<(uint m, int n)>>();
        foreach (var (k, (pk, idx)) in loc)   // 按映射表顺序（同离线链 loc 的插入顺序）
        {
            if (!pk.StartsWith("ds", StringComparison.Ordinal)) continue;
            var r = Records(pk)[idx]; int ci = r.AsSpan().IndexOf(new byte[] { 0x34, 0x12, 0x76, 0x98 });
            if (ci < 0 || r.Length < ci + 0x748) continue;
            uint m = TessCtl.Nvn1(r[ci..]); int d = (int)(m & 3);
            if (!tm.TryGetValue(d, out var l)) tm[d] = l = new();
            int i = l.FindIndex(x => x.m == m); if (i < 0) l.Add((m, 1)); else l[i] = (m, l[i].n + 1);
        }
        var tt = DshTables.Get(tables); foreach (var (d, l) in tm) { var best = l[0]; foreach (var x in l) if (x.n > best.n) best = x; tt.TessModes[d] = best.m; }
        int recOdd = 0;

        var results = new ConcurrentDictionary<string, (string Status, List<string> Why)>();
        var coverCols = new ConcurrentDictionary<string, string>();   // --cover：键 → 「未登记操作码<TAB>产物指纹」
        var stats = new ConcurrentDictionary<string, int>();
        void Bump(string k) => stats.AddOrUpdate(k, 1, (_, v) => v + 1);
        var mtl = new ConcurrentBag<string>();
        var sw = Stopwatch.StartNew(); int done = 0;

        void One(string key)
        {
            var (pk, idx) = loc[key]; string stage = pk[..2];
            var rec = Records(pk)[idx];
            uint nctl = BitConverter.ToUInt32(rec, 0x28), ncode = BitConverter.ToUInt32(rec, 0x2c);
            var code = rec[0x38..(0x38 + (int)ncode)]; var ctl = rec[(0x38 + (int)ncode)..(0x38 + (int)(ncode + nctl))];
            int ci = rec.AsSpan().IndexOf(new byte[] { 0x34, 0x12, 0x76, 0x98 });
            if (ci != 0x38 + ncode || rec.Length != 0x38 + ncode + nctl) System.Threading.Interlocked.Increment(ref recOdd);   // 离线链按 find(34127698) 切，与头里的长度不一致时这里记数
            var why = new List<string>();
            try
            {
                if (capi)
                {
                    int st = Array.IndexOf(new[] { "vs", "ps", "cs", "gs", "ts", "ms" }, stage);
                    byte[] k8 = Encoding.UTF8.GetBytes(key + "\0"), o8 = Encoding.UTF8.GetBytes(outDir + "\0");
                    int rc;
                    fixed (byte* kp = k8, cp = code, tp = ctl, op = o8) rc = DshCApi.CompileCore(kp, st, cp, (nuint)code.Length, tp, (nuint)ctl.Length, op, xc);
                    if (rc != 0) throw new DshError("capi", "s2a_dsh_compile 返回 " + rc);
                }
                else
                {
                    DshCompiler.Compile(key, stage, code, ctl, outDir, xc, tables, work);
                    // 出包模式（PackOut）产物留在内存（DshCompiler.PackFiles，批量进程按键交回）：对拍要拿文件比，写到输出目录；--cover 只记各产物指纹
                    if (cover) coverCols[key] = string.Join(" ", (DshCompiler.PackFiles ?? new()).OrderBy(f => f.Key, StringComparer.Ordinal)
                        .Select(f => f.Key[16..] + "=" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(CoverText(f.Key, f.Value))))[..16]));
                    else foreach (var (n, t) in DshCompiler.PackFiles ?? new()) File.WriteAllText(Path.Combine(outDir, n), t, new UTF8Encoding(false));
                }
            }
            catch (DshError e) { why.Add("现编失败：" + e.Status + "：" + e.Detail); }
            catch (Exception e) { why.Add("现编异常：" + e.GetType().Name + "：" + e.Message.Split('\n')[0]); }
            if (cover) coverCols[key] = UnknownAmpere(stage, code, ctl) + "\t" + coverCols.GetValueOrDefault(key, "");
            else if (why.Count == 0 && refDir != null) Compare(key, why);   // 不给 --ref：只出产物不比（--capi 时产物留在 --out，同设备首遇现编写进兜底目录的那几份，可当兜底目录用）
            results[key] = (why.Count == 0 ? "ok" : "bad", why);
            foreach (var w in why) Bump(Category(w));
            int d = System.Threading.Interlocked.Increment(ref done);
            if (d % 500 == 0) Console.WriteLine($"  … {d}/{keys.Count}，{sw.Elapsed.TotalSeconds:F0} 秒");
        }

        void Compare(string key, List<string> why)
        {
            var names = DshCompiler.OutNames(key).ToList();
            foreach (var n in names)
            {
                string r = Path.Combine(refDir, n), m = Path.Combine(outDir, n);
                bool hr = File.Exists(r), hm = File.Exists(m);
                if (!hr && !hm) continue;
                if (hr != hm) { why.Add((hr ? "缺产物 " : "多产物 ") + n[16..]); continue; }
                if (n.EndsWith(".metal"))
                {
                    if (abiOnly) continue;
                    var x = File.ReadAllBytes(r); var y = File.ReadAllBytes(m);
                    if (!x.AsSpan().SequenceEqual(y)) why.Add("metal 不同 " + n[16..] + "：" + MetalDiff(Encoding.UTF8.GetString(x), Encoding.UTF8.GetString(y)));
                }
                else
                {
                    var jr = JsonNode.Parse(File.ReadAllText(r)).AsObject(); var jm = JsonNode.Parse(File.ReadAllText(m)).AsObject();
                    foreach (var ex in Excluded) { if (jr.ContainsKey(ex)) Bump("（离线 json 带 " + ex + "）"); if (jm.ContainsKey(ex)) Bump("（现编 json 带 " + ex + "）"); jr.Remove(ex); jm.Remove(ex); }
                    if (abiOnly)
                    {
                        foreach (var f in Entries.Append("bindings").Append("msl_entry_kind"))
                            if (!JsonNode.DeepEquals(jr[f], jm[f])) why.Add("json 不同 " + n[16..] + "：" + f);
                        {
                            var ents = Entries.Where(e => jm[e] != null).Select(e => (string)jm[e]).ToList();
                            if (ents.Count > 0) mtl.Add(Path.Combine(outDir, n[..^5] + ".metal") + "\t" + string.Join(",", ents));
                        }
                        continue;
                    }
                    var keysAll = jr.Select(kv => kv.Key).Union(jm.Select(kv => kv.Key)).ToList();
                    foreach (var f in keysAll) if (!JsonNode.DeepEquals(jr[f], jm[f])) why.Add("json 不同 " + n[16..] + "：" + f);
                }
            }
        }

        var ord = keys.Where(k => !pairs.ContainsKey(k)).ToList(); var last = keys.Where(k => pairs.ContainsKey(k)).ToList();   // 配对的顶点着色器要读片元的 MSL（vs_pad）：放后一批
        var po = new ParallelOptions { MaxDegreeOfParallelism = nj };
        Parallel.ForEach(ord, po, One);
        Parallel.ForEach(last, po, One);

        int ok = results.Values.Count(r => r.Status == "ok");
        Console.WriteLine($"后端 {backend}{(capi ? "（导出入口）" : "")}{(abiOnly ? "，只比 bindings 与入口名" : "")}：比了 {results.Count} 个键，一致 {ok}，不一致 {results.Count - ok}；用时 {sw.Elapsed.TotalSeconds:F0} 秒；记录头长度与 find(34127698) 不一致 {recOdd}");
        foreach (var kv in stats.OrderByDescending(kv => kv.Value)) Console.WriteLine($"  {kv.Value,6}  {kv.Key}");
        foreach (var kv in results.Where(r => r.Value.Status != "ok").OrderBy(r => r.Key).Take(12)) Console.WriteLine($"  例 {kv.Key}：{string.Join("；", kv.Value.Why.Take(3))}");
        if (a.TryGetValue("--report", out var rep))
            File.WriteAllLines(rep, results.OrderBy(r => r.Key).Select(r => r.Key + "\t" + loc[r.Key].Pkg[..2] + "\t" + r.Value.Status + "\t" + string.Join("；", r.Value.Why)
                + (cover ? "\t" + coverCols.GetValueOrDefault(r.Key, "\t") : "")));
        if (a.TryGetValue("--mtl-list", out var ml)) File.WriteAllLines(ml, mtl.OrderBy(x => x));
        try { Directory.Delete(work, true); } catch { }
        return ok == results.Count && results.Count > 0 ? 0 : 1;
    }

    // --cover 的产物指纹：.json 去掉 xfp 一项（现编 json 带的翻译器指纹，翻译器一改就变，与产物内容无关；同 Compare 的 Excluded）再算
    static string CoverText(string name, string text)
    {
        if (!name.EndsWith(".json", StringComparison.Ordinal)) return text;
        var j = JsonNode.Parse(text) as JsonObject;
        if (j == null || !j.Remove("xfp")) return text;
        return j.ToJsonString();
    }

    // --cover：NVN2 键指令区（控制段 +0x38 长，图形阶段跳过 0x80 字节 SPH）里 AmpereTable 没登记的 12 位操作码，去重升序、逗号分隔；非 NVN2 键为空。
    //   线性扫整段（不走控制流），所以一处失败不会遮住同一支里的其余缺口；登记了但某些变体在发射时才拒的不在这里，看原因列
    static string UnknownAmpere(string stage, byte[] code, byte[] ctl)
    {
        if (ctl.Length < 0x48 || BitConverter.ToUInt32(ctl, 0) != 0x98761234u || BitConverter.ToUInt32(ctl, 4) != 0xc9u) return "";
        int end = (int)Math.Min(BitConverter.ToUInt32(ctl, 0x38), (uint)code.Length), start = stage == "cs" ? 0 : 0x80;
        var miss = new SortedSet<int>();
        for (int o = start; o + 16 <= end; o += 16)
        {
            ulong lo = BitConverter.ToUInt64(code, o), hi = BitConverter.ToUInt64(code, o + 8);
            if (Ryujinx.Graphics.Shader.Instructions.AmpereTable.GetOp((ulong)(o - start), lo, hi).Name == Ryujinx.Graphics.Shader.Decoders.InstName.Invalid) miss.Add((int)(lo & 0xfff));
        }
        return string.Join(",", miss.Select(m => m.ToString("x3")));
    }

    static int Neg(string tables, string outDir, string work, ISpvCross xc)
    {
        string gd = Path.Combine(work, "gd"), d = Path.Combine(gd, "shaders", "direct"); Directory.CreateDirectory(d);
        foreach (var n in new[] { "shader_facts.tsv", "shader_pairs.tsv" }) File.Copy(Path.Combine(tables, n), Path.Combine(d, n), true);
        var ctl = new byte[0x880]; BitConverter.TryWriteBytes(ctl.AsSpan(0), 0x98761234u); var code = new byte[0x200];
        var cases = new (string Name, string Key, int Stage, int CtlLen, bool Env)[] {
            ("阶段 7", "0123456789abcdef", 7, 0x880, true), ("键不是 16 位十六进制", "../../etc/passwd", 0, 0x880, true),
            ("控制段截到 0x100", "0123456789abcdef", 1, 0x100, true), ("没设 S2A_GAME_DATA", "0123456789abcdef", 1, 0x880, false) };
        int good = 0;
        foreach (var c in cases)
        {
            if (c.Env) setenv("S2A_GAME_DATA", gd, 1); else unsetenv("S2A_GAME_DATA");
            var old = Console.Error; var cap = new StringWriter(); Console.SetError(cap);
            int rc;
            byte[] k8 = Encoding.UTF8.GetBytes(c.Key + "\0"), o8 = Encoding.UTF8.GetBytes(outDir + "\0");
            try { fixed (byte* kp = k8, cp = code, tp = ctl, op = o8) rc = DshCApi.CompileCore(kp, c.Stage, cp, (nuint)code.Length, tp, (nuint)c.CtlLen, op, xc); }
            finally { Console.SetError(old); }
            string line = cap.ToString().Trim();
            bool ok = rc != 0 && line.StartsWith("【红】") && !line.Contains('\n');
            if (ok) good++;
            Console.WriteLine($"  {(ok ? "✓" : "✗")} {c.Name}：返回 {rc}，stderr「{line}」");
        }
        // 配对表坏了（10-24 直连线；11-13 起缺表按空表，不再算失败，这里改用「表在但行格式坏」）：第一个键返回非 0 并打一行【红】，之后的键返回非 0、不再打（同一份坏表只报一次）
        string gd2 = Path.Combine(work, "gd_badpairs"), d2 = Path.Combine(gd2, "shaders", "direct"); Directory.CreateDirectory(d2);
        File.Copy(Path.Combine(tables, "shader_facts.tsv"), Path.Combine(d2, "shader_facts.tsv"), true); File.WriteAllText(Path.Combine(d2, "shader_pairs.tsv"), "only-one-column\n");
        setenv("S2A_GAME_DATA", gd2, 1);
        int good2 = 0;
        for (int i = 0; i < 2; i++)
        {
            var old = Console.Error; var cap = new StringWriter(); Console.SetError(cap);
            int rc; byte[] k8 = Encoding.UTF8.GetBytes((i == 0 ? "0123456789abcdef" : "fedcba9876543210") + "\0"), o8 = Encoding.UTF8.GetBytes(outDir + "\0");
            try { fixed (byte* kp = k8, cp = code, tp = ctl, op = o8) rc = DshCApi.CompileCore(kp, 1, cp, (nuint)code.Length, tp, (nuint)ctl.Length, op, xc); }
            finally { Console.SetError(old); }
            string line = cap.ToString().Trim();
            bool ok = rc != 0 && (i == 0 ? line.StartsWith("【红】") && line.Contains("bad pairs table") && !line.Contains('\n') : line.Length == 0);
            if (ok) good2++;
            Console.WriteLine($"  {(ok ? "✓" : "✗")} 坏配对表第 {i + 1} 个键：返回 {rc}，stderr「{line}」（期望{(i == 0 ? "一行【红】" : "不再打")}）");
        }
        // 两张表都不在（11-13 D-QW2Q：玩家导入不带 shaders/ 的 game.img）：不报「no answer table / no pairs table」，按空表照常往下编
        string gd3 = Path.Combine(work, "gd_notables"), d3 = Path.Combine(gd3, "shaders", "direct"); Directory.CreateDirectory(d3);
        setenv("S2A_GAME_DATA", gd3, 1);
        int good3 = 0;
        {
            var old = Console.Error; var cap = new StringWriter(); Console.SetError(cap);
            int rc; byte[] k8 = Encoding.UTF8.GetBytes("00112233445566ff\0"), o8 = Encoding.UTF8.GetBytes(outDir + "\0");
            try { fixed (byte* kp = k8, cp = code, tp = ctl, op = o8) rc = DshCApi.CompileCore(kp, 1, cp, (nuint)code.Length, tp, (nuint)ctl.Length, op, xc); }
            finally { Console.SetError(old); }
            string err = cap.ToString();
            bool ok = !err.Contains("no answer table") && !err.Contains("no pairs table") && err.Contains("按空答案表");
            if (ok) good3++;
            Console.WriteLine($"  {(ok ? "✓" : "✗")} 两张表都不在：返回 {rc}，不报缺表、按空表现编（stderr「{err.Trim().Replace('\n', ' ')}」）");
        }
        Console.WriteLine($"导出入口失败路径：{good + good2 + good3}/{cases.Length + 3} 例（返回非 0；坏表只报第一次；缺表按空表）");
        return good == cases.Length && good2 == 2 && good3 == 1 ? 0 : 1;
    }
    [DllImport("libc")] static extern int unsetenv(string name);

    // 分类：去掉键相关的细节，只留原因类
    static string Category(string w)
    {
        int i1 = w.IndexOf('：'), i2 = i1 < 0 ? -1 : w.IndexOf('：', i1 + 1);
        if (w.StartsWith("metal")) return i1 > 0 ? w[..i1] : w;
        if (w.StartsWith("现编")) return i2 > 0 ? w[..i2] : w;
        return w;
    }

    static string MetalDiff(string x, string y)
    {
        var a = x.Split('\n'); var b = y.Split('\n');
        int n = Math.Min(a.Length, b.Length), i = 0;
        while (i < n && a[i] == b[i]) i++;
        string ai = i < a.Length ? a[i].Trim() : "<尾>", bi = i < b.Length ? b[i].Trim() : "<尾>";
        return $"第 {i + 1} 行起（离线 {a.Length} 行 / 现编 {b.Length} 行）：离线「{Trunc(ai)}」现编「{Trunc(bi)}」";
    }
    static string Trunc(string s) => s.Length > 70 ? s[..70] + "…" : s;
}
