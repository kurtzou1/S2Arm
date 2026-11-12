// 整份直连出库（11-01 出包线，出库链整条挪进 C#，原 translator/dmsh_build.py + dmsh_par.py + dmsh_store.py + dmsh_mtlcache.py + c1_guard.py / cb_extent.py + lib_pack.py / lib_swap.py / ps_inputs.py）：
//   一个进程内并发做完：键表 → 翻译（S2A.Dsh，与设备首遇现编同一份代码；按内容缓存）→ 逐键收尾（反射、几何 / 曲面逐键库、影子输入 / 输出类型 / 可读瓦片变体）
//   → 编批库（Unity）+ 影子输入库 + 采样模拟变体（se_want）→ c1 / cb 两张表（C1Cb）→ 发布核验与库容器（LibPack）、ps_inputs / keys.tsv / _b_build.json / 印章。
//   原先 Python 主进程（GIL）派活收结果只能用满一核，metal 平均只吃上约 4 路；这里调度、哈希、缓存核对全在线程池里，Metal 编译由并发闸（J）限路数，不断粮。
// 用法：dsh_batch build --pkg <包目录> --profile <配置档目录> --game <程序号> --chain <链号> --inputs <配置档输入摘要> --out <Mac 输出根>
//         [--iosout <iOS 输出根>] [--publish mac|ios] [--no-mac] [--no-ios] --cas <缓存根> --dsx <libdsx> --spvc <libspvc_cli> [-j N]
//   只有整份出库、只有编批库一条路（11-01 维护者：部分出库、每键单独编库、两段式热键随迁移删除）
//         [--bf] [--export-mac <目录>] [--lock <dmsh_chain.lock>]
//   链号 / 配置档输入摘要 / 程序号 / 配置档里改翻译的行（--profile-rows 文件）由调用方（direct_lib.sh 经 dmsh_chain.py）给；产物逐字节同原 Python 链（14 个现行根对拍）。
using S2A.Dsh;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

static partial class Build   // 影响翻译产物的那段（包记录切片、逐键翻译）在 BuildXlate.cs，进翻译器指纹；本文件是编排，不进
{
    // ---------------- 参数与输入 ----------------
    static Dictionary<string, string> A;
    static string Pkg, Prof, Game, Chain, Inputs, Out, IosOut, Publish, Cas, Work;
    static bool NoMac, IosLib, BfOn;
    static int NJ;
    const int UNITY = 48;   // 编批库：每批约这么多键合成一个翻译单元（Unity.Cut）
    internal static Side MAC, IOS;
    static readonly UTF8Encoding U8 = new(false);

    // 编译约定（与原 dmsh_build.py MAC_METAL / ios_metal.py 逐字相同：记录写进每个反射 chain_metal）
    internal static readonly string[] MacMetal = { "xcrun", "-sdk", "macosx", "metal", "-c", "-w", "-fmetal-math-mode=relaxed", "-fpreserve-invariance", "-mmacosx-version-min=15.0" };
    static readonly string[] IosMetal = { "xcrun", "-sdk", "iphoneos", "metal", "-c", "-w", "-mios-version-min=18.0", "-fmetal-math-mode=relaxed", "-fpreserve-invariance" };
    internal static readonly string MacRecord = string.Join(' ', MacMetal) + "; xcrun -sdk macosx metallib";
    static readonly string IosRecord = string.Join(' ', IosMetal) + "; xcrun -sdk iphoneos metallib";

    static Dictionary<string, (string Pkg, int Idx)> Loc = new();
    static Dictionary<string, byte[]> MapRows = new(), MapConflictRows = new();
    static Dictionary<string, List<string>> FactRows = new();
    static Dictionary<string, SortedSet<string>> Pairs = new();
    static HashSet<string> BfWant = new();
    static readonly HashSet<string> Hot = new();   // 冷热分批已随两段式出包删除：恒空（Unity.MakePlan 的热键参数）
    static Dictionary<string, SortedSet<(long U, long S)>> FoutWant = new();
    static readonly ConcurrentDictionary<string, Lazy<List<byte[]>>> Packs = new();
    static SortedDictionary<int, uint> TessModes = new();
    static string ToolFp;

    static int Fail(string msg) { Console.Out.Flush(); Console.Error.WriteLine(msg); Console.Error.Flush(); return 1; }
    static void Say(string s) { lock (Console.Out) { Console.Out.WriteLine(s); Console.Out.Flush(); } }
    // 重活并行循环按序一次领一个（Parallel.ForEach 对 List 默认静态切块、对枚举攒块领：「大的先编」不成立，最大几批落进同一线程串行成长尾）
    static OrderablePartitioner<T> InOrder<T>(IEnumerable<T> s) => Partitioner.Create(s, EnumerablePartitionerOptions.NoBuffering);
    static readonly Stopwatch Clock = Stopwatch.StartNew(); static double LastPhase;
    static void Phase(string name) { var t = Clock.Elapsed.TotalSeconds; Say($"[分段] {name} {t - LastPhase:F1} 秒（累计 {t:F1}）"); LastPhase = t; }   // 各段墙钟：定位哪一段没喂满 Metal

    public static int Entry(string[] argv)
    {
        A = new Dictionary<string, string>();
        var flags = new HashSet<string>();
        for (int i = 0; i < argv.Length; i++)
        {
            if (argv[i] is "--no-mac" or "--no-ios" or "--bf") { flags.Add(argv[i]); continue; }
            if (i + 1 < argv.Length) { A[argv[i]] = argv[i + 1]; i++; }
        }
        Pkg = A["--pkg"]; Prof = A["--profile"]; Game = A["--game"]; Chain = A["--chain"]; Inputs = A["--inputs"];
        Out = Path.Combine(A["--out"], "b-" + Chain);
        IosOut = A.TryGetValue("--iosout", out var io) ? Path.Combine(io, "b-" + Chain) : null;
        Publish = A.GetValueOrDefault("--publish"); Cas = A["--cas"];
        NoMac = flags.Contains("--no-mac"); IosLib = IosOut != null && !flags.Contains("--no-ios");
        BfOn = flags.Contains("--bf") || Environment.GetEnvironmentVariable("DMSH_BF") == "1";
        Environment.SetEnvironmentVariable("DMSH_BF", BfOn ? "1" : null);   // 翻译器（S2A.Dsh）按这个环境变量决定出不出可读瓦片变体 _bf：与缓存键里的开关保持同一个值
        NJ = int.Parse(A.GetValueOrDefault("-j", "8"));
        { System.Threading.ThreadPool.GetMinThreads(out var w0, out var io0); System.Threading.ThreadPool.SetMinThreads(Math.Max(w0, NJ * 4 + Environment.ProcessorCount), io0); }   // 编译线程阻塞等子进程（各段 NJ×2）+ 两张表并发：池下限按此给足，免得任务排队等池慢慢补线程
        if (NoMac && !IosLib) return Fail("[RED] --no-mac builds only the iOS libraries: give --iosout (and not --no-ios)");
        // 给了 --lock 就必须读得到：原先读不到当空串进翻译缓存键、照常出库（11-06 时之笛第 49 版：远端编库命令的 --lock 指向已不在的旧树，没人发现）
        if (A.TryGetValue("--lock", out var lk0) && !File.Exists(lk0)) return Fail($"[RED] --lock {lk0} does not exist: the translation cache key would silently drop the tool lock");
        string lib = A["--dsx"];
        NativeLibrary.SetDllImportResolver(typeof(NxgalSpvCross).Assembly, (name, asm, path) => name == "dsx" ? NativeLibrary.Load(lib) : IntPtr.Zero);
        Directory.CreateDirectory(Out); if (IosOut != null) Directory.CreateDirectory(IosOut);
        foreach (var d in new[] { Out, IosOut }.Where(x => x != null))
        {
            var g = ReadStamp(d).GetValueOrDefault("game");
            if (g != null && g != Game) return Fail($"[RED] {d} holds the shader libraries of game {g}, not {Game}: give each game its own output directory");
        }
        Work = Path.Combine(Path.GetTempPath(), $"dshb_{Environment.ProcessId}_{Guid.NewGuid():N}"); Directory.CreateDirectory(Work);
        Spill = new BlobFile(Path.Combine(Work, "spill.dat"), compress: true); MAC = new Side(Work); IOS = IosLib ? new Side(Work) : null;
        Store.Open(Path.Combine(Cas, "dshb"));
        try { return Run(); }
        finally { try { Directory.Delete(Work, true); } catch { } }
    }

    static string Table(string name) => Path.Combine(Prof, name);

    static void LoadTables()
    {
        string map = Table("shader_map.tsv"), conf = map + ".conflicts.tsv";
        foreach (var (raw, c) in PkgRead.MapLines(map))   // 读法与出包 Vulkan 库工具共用（PkgRead.cs）
        {
            if (c.Length > 4) MapRows.TryAdd(c[3], raw);
            if (PkgRead.IsRecord(c)) Loc.TryAdd(c[3], (c[0], int.Parse(c[1])));
        }
        if (File.Exists(conf))
            foreach (var raw in PkgRead.ReadRawLines(conf))
            {
                var s = Encoding.UTF8.GetString(raw); var c = s.TrimEnd('\n').Split('\t');
                if (c.Length > 1 && !s.StartsWith('#') && !s.StartsWith("dm_", StringComparison.Ordinal)) MapConflictRows.TryAdd(c[0], raw);
            }
        foreach (var ln in File.ReadLines(Table("shader_facts.tsv")))
        {
            if (ln.Length == 0 || ln.StartsWith('#')) continue;
            int t = ln.IndexOf('\t'); var k = t < 0 ? ln : ln[..t];
            (FactRows.TryGetValue(k, out var l) ? l : FactRows[k] = new()).Add(ln);
        }
        foreach (var ln in File.ReadLines(Table("shader_pairs.tsv")))
        {
            if (ln.Trim().Length == 0 || ln.StartsWith('#')) continue;
            var c = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            (Pairs.TryGetValue(c[0], out var s) ? s : Pairs[c[0]] = new(StringComparer.Ordinal)).Add(c[1]);
        }
        if (File.Exists(Table("bf_want.tsv")))
            foreach (var ln in File.ReadLines(Table("bf_want.tsv"))) { var x = ln.Trim(); if (x.Length > 0 && !ln.TrimStart().StartsWith('#')) BfWant.Add(x); }
        if (File.Exists(Table("fout_want.tsv")))
            foreach (var ln in File.ReadLines(Table("fout_want.tsv")))
            {
                var c = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                if (c.Length == 3 && !ln.StartsWith('#')) (FoutWant.TryGetValue(c[0], out var s) ? s : FoutWant[c[0]] = new()).Add((Convert.ToInt64(c[1], 16), Convert.ToInt64(c[2], 16)));
            }
    }


    // ---------------- 翻译缓存键（输入 + 翻译器 / 工具指纹；原 Python 精确失效 dmsh_deps 不移植：C# 翻译快，Metal 编译仍按 MSL 内容寻址） ----------------
    static string Sha(byte[] b) => Convert.ToHexString(SHA256.HashData(b)).ToLowerInvariant();
    static string Sha(string s) => Sha(U8.GetBytes(s));

    static string ToolFingerprint()
    {
        var sb = new StringBuilder("dshb-xlate 1\0");
        sb.Append("xfp\0").Append(DshCompiler.Xfp).Append('\0');
        sb.Append("lock\0").Append(A.TryGetValue("--lock", out var lk) && File.Exists(lk) ? File.ReadAllText(lk) : "").Append('\0');
        sb.Append("spvc\0").Append(LibFp(A["--spvc"])).Append('\0');   // 同 libdsx：spvc_inproc 编的库构建不可复现（同一源码摘要目录、三棵工作树三种字节），按功能身份算
        sb.Append("dsx\0").Append(LibFp(A["--dsx"])).Append('\0');
        sb.Append("xc\0").Append(string.Join(' ', CliSpvCross.XC)).Append('\0');
        sb.Append("profile\0").Append(A.TryGetValue("--profile-rows", out var pr) && File.Exists(pr) ? File.ReadAllText(pr) : "").Append('\0');   // 配置档里改翻译的 nvn_* / shader_* 行（dmsh_chain.profile_rows）
        return Sha(sb.ToString());
    }

    // 单测 / 验收：只算工具指纹（--lock / --spvc / --dsx / --profile-rows 同 build），不出库。tests/nxgal_fp_test.sh 拿两棵工作树各算一次比
    internal static string ToolFpCli(string[] argv)
    {
        A = new Dictionary<string, string>();
        for (int i = 0; i + 1 < argv.Length; i += 2) A[argv[i]] = argv[i + 1];
        return ToolFingerprint();
    }

    // libdsx / spvc 动态库的功能身份：Mach-O 各节内容（段名 / 节名 / 长度 / 字节）的 sha256，不含文件头与加载命令（LC_UUID）、__LINKEDIT（符号表、调试映射、签名）。
    //   11-02 出包线：原先整文件哈希，libnxgal（11-08 前直连库即它）构建不可复现——clang 一步编译加链接时调试映射记的临时目标文件名是随机的（/var/folders/…/T/gal_core-bb1480.o），
    //   UUID、签名随之变，代码段逐字节相同；每换一棵工作树 / 重编一次，全部着色器的翻译键作废（马力欧派对 82790 支 hit 0、冷翻 784 秒）。
    //   不是 64 位 Mach-O（Linux 的 libdsx.so）照旧整文件
    internal static string LibFp(string path)
    {
        var b = File.ReadAllBytes(path);
        if (b.Length < 32 || BitConverter.ToUInt32(b, 0) != 0xfeedfacf) return Sha(b);
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        h.AppendData(U8.GetBytes("macho-sections 1\0"));
        int ncmds = BitConverter.ToInt32(b, 16), o = 32;
        for (int i = 0; i < ncmds; i++)
        {
            int cmd = BitConverter.ToInt32(b, o), size = BitConverter.ToInt32(b, o + 4);
            if (cmd == 0x19)   // LC_SEGMENT_64：段头 72 字节后接 nsects 个 80 字节的节头
            {
                int nsects = BitConverter.ToInt32(b, o + 64);
                for (int k = 0; k < nsects; k++)
                {
                    int sh = o + 72 + 80 * k;
                    string sect = U8.GetString(b, sh, 16).TrimEnd('\0'), seg = U8.GetString(b, sh + 16, 16).TrimEnd('\0');
                    long len = BitConverter.ToInt64(b, sh + 40); int off = BitConverter.ToInt32(b, sh + 48), flags = BitConverter.ToInt32(b, sh + 64);
                    h.AppendData(U8.GetBytes($"{seg},{sect},{len}\0"));
                    if ((flags & 0xff) is 0x1 or 0xc or 0x12 || off == 0) continue;   // 零填充节（S_ZEROFILL / S_GB_ZEROFILL / S_THREAD_LOCAL_ZEROFILL）文件里没有内容
                    h.AppendData(b, off, (int)len);
                }
            }
            o += size;
        }
        return Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant();
    }

    static string ShaderKey(string key, string pkg, byte[] rec)
    {
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Add(string s) { h.AppendData(U8.GetBytes(s)); h.AppendData(new byte[] { 0 }); }
        h.AppendData(rec); h.AppendData(new byte[] { 0 });
        h.AppendData(MapRows.GetValueOrDefault(key, U8.GetBytes("missing"))); h.AppendData(MapConflictRows.GetValueOrDefault(key, Array.Empty<byte>())); h.AppendData(new byte[] { 0 });
        Add(FactRows.TryGetValue(key, out var fr) ? string.Join('\n', fr) : "missing");
        Add(ToolFp); Add(pkg);
        Add(string.Join(',', Pairs.GetValueOrDefault(key) ?? new SortedSet<string>()));
        Add($"{(BfOn ? 1 : 0)}{(BfWant.Contains(key) ? 1 : 0)}{string.Join(';', (FoutWant.GetValueOrDefault(key) ?? new()).Select(x => $"{x.U:x},{x.S:x}"))}");
        return Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant();
    }

    // ---------------- 键与结果 ----------------
    static List<string> Keys;
    static readonly ConcurrentDictionary<string, string> Digest = new();
    static readonly ConcurrentDictionary<string, (string St, string Why)> XlSt = new();
    static readonly ConcurrentDictionary<string, Dictionary<string, string>> BOM = new();   // 键 → 翻译产物（后缀 → 文本）
    internal static BlobFile Spill;   // 待编源码（Defer / VinSrc）的落盘处，Entry / 编批库单测入口按工作目录开
    internal static readonly TextStore Defer = new();   // 键 → 不带额外入口的源码（null：没有）：留给编批库
    static readonly ConcurrentDictionary<string, Dictionary<string, string>> VarSrc = new();
    internal static readonly TextStore VinSrc = new();
    internal static readonly ConcurrentDictionary<string, long> Stats = new();
    internal static void Count(string what, long n = 1) => Stats.AddOrUpdate(what, n, (_, v) => v + n);
    static long N(string what) => Stats.GetValueOrDefault(what);
    static int CacheHits;

    static int Run()
    {
        LoadTables();
        Keys = Loc.Keys.OrderBy(x => x, StringComparer.Ordinal).ToList();
        // 曲面：本款域着色器用到的各域与其最常见模式（同 dmsh_build.py TESS_MODES：控制段 GL 枚举经 TessCtl 打成模式字，按映射表顺序，并列取先出现的）
        var tm = new Dictionary<int, List<(uint m, int n)>>();
        foreach (var (k, (pk, idx)) in Loc)
        {
            if (!pk.StartsWith("ds", StringComparison.Ordinal)) continue;
            var r = Records(pk)[idx]; int ci = r.AsSpan().IndexOf(new byte[] { 0x34, 0x12, 0x76, 0x98 });
            if (ci < 0) continue;
            uint m;
            if (Nvn2.Is(r[ci..])) m = Nvn2.TessMode(r[ci..]);   // Switch 2：模式在 NVN2 控制段 +0x58..（Nvn2.TessMode）
            else if (r.Length < ci + 0x748) continue;
            else m = TessCtl.Nvn1(r[ci..]);   // Switch 1：+0x738 / +0x73c / +0x744（TessCtl.Nvn1）
            int d = (int)(m & 3);
            if (!tm.TryGetValue(d, out var l)) tm[d] = l = new();
            int i = l.FindIndex(x => x.m == m); if (i < 0) l.Add((m, 1)); else l[i] = (m, l[i].n + 1);
        }
        var tt = DshTables.Get(Prof); foreach (var (d, l) in tm) { var best = l[0]; foreach (var x in l) if (x.n > best.n) best = x; tt.TessModes[d] = best.m; TessModes[d] = best.m; }
        ToolFp = ToolFingerprint();
        foreach (var k in Keys.Where(k => !Loc.ContainsKey(k))) XlSt[k] = ("translation failed", "not in shader_map.tsv");
        Parallel.ForEach(Keys.Where(Loc.ContainsKey), new ParallelOptions { MaxDegreeOfParallelism = NJ * 2 }, k =>
        {
            var (pk, idx) = Loc[k]; var d = ShaderKey(k, pk, Records(pk)[idx]);
            if (pk.StartsWith("hs", StringComparison.Ordinal)) d = Sha(d + " tess " + string.Join(' ', TessModes.Select(x => $"{x.Key}:0x{x.Value:x}")));
            Digest[k] = d;
        });
        foreach (var k in Keys.Where(k => Pairs.ContainsKey(k) && Digest.ContainsKey(k)))
            Digest[k] = Sha(Digest[k] + "\0" + string.Join(',', Pairs[k].Select(p => Digest.TryGetValue(p, out var pd) ? pd : Loc.ContainsKey(p) ? ShaderKey(p, Loc[p].Pkg, Records(Loc[p].Pkg)[Loc[p].Idx]) : "missing")));
        foreach (var d in new[] { Out, IosOut }.Where(x => x != null))   // 上一次留下的印章先去掉，出完再写
            if (File.Exists(Path.Combine(d, "inputs.tsv"))) File.Delete(Path.Combine(d, "inputs.tsv"));

        Metal.Init(NoMac ? null : (MacMetal, MacRecord, "macosx"), IosLib ? (IosMetal, IosRecord, "iphoneos") : null, Work, NJ);
        Phase("读表 / 键摘要");
        Translate(); Packs.Clear(); var res = Finish(); Phase("翻译与逐键收尾");   // 着色器包记录只在键摘要与翻译里读：翻完即放（审计 #1417 P1-77：原先留到进程结束）
        bool flushed = Defer.Count > 0;
        var c1cb = Task.Run(C1CbFill);   // 两张表：编批库期间并发算（批库只往反射写库名，不动两张表读的 MSL / c1 / 绑定）
        if (flushed)
        {
            var failed = UnityFlush(); Phase("编批库");
            if (Metal.Tally(Say) is { } none) { Say(none); return 1; }
            res = res.Select(r => failed.TryGetValue(r.Key, out var e) ? (r.Key, "metal failed", e, (PyDict)null) : r).ToList();
            Say($"unity batches: {N("unity batches")} batches of {N("unity keys")} keys compiled as one unit each; {N("unity reused batches")} batches ({N("unity reused keys")} keys) and {N("vin reused batches")} shadow-input batches ({N("vin reused keys")} keys) taken whole from earlier builds (their members' code unchanged); {N("unity fallback batches")} batches ({N("unity fallback keys")} keys) built key by key, "
              + $"{failed.Count} keys still failing; {N("unity same MSL keys")} keys with the MSL of another key took its library; {N("unity main0_u shared")} main0_u entry points compiled on main0's body (dmsh_ushare.py)");
        }
        SeFinish(); Phase("采样模拟变体");
        // 待编源码（Defer / VinSrc，spill.dat）只在编批库里读，到这里已没人用：就地放掉，不叠在后面「两张表收尾 / 发布打包」的盘峰值上（v0.2.4 出包空间：怪猎崛起 827 MB）
        Say(WorkUsage()); Spill.Close();
        Summaries(res);
        var bj = new StringBuilder("[");
        for (int i = 0; i < res.Count; i++) { if (i > 0) bj.Append(", "); bj.Append("{\"key\": ").Append(JStr(res[i].Key)).Append(", \"st\": ").Append(JStr(res[i].St)).Append(", \"err\": ").Append(JStr(res[i].Why)).Append('}'); }
        File.WriteAllText(Path.Combine(Out, "_b_build.json"), bj.Append(']').ToString(), U8);
        foreach (var d in new[] { Out, IosOut }.Where(x => x != null)) WriteStamp(d, Game, Inputs);
        Say($"library stamp: game {Game}, inputs {Inputs}");
        Phase("汇总 / 印章");
        // 两张表收尾放在发布之前（v0.2.4 出包空间）：它和发布里的 ps_inputs 表是 Mac 侧源码（*.metal）最后的读者，读完源码那份就地放掉，
        //   容器打包写盘时不再和它叠在一起（怪猎崛起 Mac 侧 3.4 GB 里多半是源码）。要导出逐键产物（--export-mac，考卷 / 对拍）时源码留着
        c1cb.Wait(); Phase("等两张表");
        C1CbFinal(); Phase("两张表收尾");
        bool export = A.TryGetValue("--export-mac", out var ex);
        int rc = PublishAll(export ? null : MAC.DropText); Phase("发布打包");
        if (rc != 0) return rc;
        if (export) { MAC.Export(ex); Phase("导出 Mac 逐键产物（只考卷 / 对拍）"); }   // 考卷冻结 / 全量对拍用（direct_lib.sh S2A_DIRECT_KEEP）
        var (kept, dropped) = Store.Compact(); Say($"store: {kept} entries kept, {dropped} dropped"); Phase("整理缓存仓");
        return 0;
    }

    // ---------------- 翻译（命中缓存的取缓存，其余进程内并发翻） ----------------
    static void Translate()
    {
        ISpvCross xc = XlateSetup();
        // 命中只判、不留：收尾到哪个键再从仓里读哪个键（审计 #1417 P1-77：原先全部命中键的翻译文本在收尾开始前装进 BOM，大款热缓存时常驻随键数涨）
        var misses = new ConcurrentBag<string>(); var hits = new ConcurrentDictionary<string, byte>(StringComparer.Ordinal);
        Parallel.ForEach(Keys.Where(Digest.ContainsKey), new ParallelOptions { MaxDegreeOfParallelism = NJ * 2 }, k =>
        {
            var e = Store.Get("xl/" + Digest[k]);
            if (e != null && e.ContainsKey("_b.json")) { hits[k] = 0; XlSt[k] = ("ok", ""); Interlocked.Increment(ref CacheHits); }
            else misses.Add(k);
        });
        Count("cache hit", CacheHits); Count("cache miss", misses.Count);
        var dir = Path.Combine(Work, "dsh"); Directory.CreateDirectory(dir);
        void One(string key) => XlateOne(key, dir, xc);
        // 翻译与逐键收尾同一个工作线程接着做（同原 dmsh_par 分片：一个键翻完就编它的变体 / 几何 / 曲面库，翻译与 Metal 重叠；原先翻完全部再收尾，Metal 晚起 40 多秒）。
        //   NJ×2 路：一半在等 Metal 闸时另一半照常翻译。配对的顶点着色器读片元的 MSL（vs_pad）：放后一波
        var po = new ParallelOptions { MaxDegreeOfParallelism = NJ * 2 };
        var ms = misses.OrderBy(x => x, StringComparer.Ordinal).ToList(); var miss = new HashSet<string>(ms, StringComparer.Ordinal);
        using var tk = new Ticker("直连库·翻译与收尾", Keys.Count);
        void Both(string k)
        {
            if (miss.Contains(k)) One(k);
            else if (hits.ContainsKey(k))
            {
                var e = Store.Get("xl/" + Digest[k]);   // 同一进程里前面判过命中：仓只增不删，读不到就是仓坏了，照翻译失败记这一键（不当命中漏掉）
                if (e != null && e.ContainsKey("_b.json")) BOM[k] = e.ToDictionary(x => x.Key, x => U8.GetString(x.Value));
                else XlSt[k] = ("translation failed", "cache entry vanished after the hit check");
            }
            var f = FinishOne(k); if (f.St == "ok" && f.Refl != null) FinFlags[k] = SumFlags(f.Refl);
            Fin[k] = (f.Key, f.St, f.Why, null); BOM.TryRemove(k, out _); VarSrc.TryRemove(k, out _); tk.Step();
        }   // 收尾后翻译产物即放（之后只读 Side / VarSrc / Defer；配对顶点读片元从 Side 读）：原先全部键的产物留到进程结束，异度3 2.7 GB
        Parallel.ForEach(InOrder(Keys.Where(k => !Pairs.ContainsKey(k))), po, Both);
        Parallel.ForEach(InOrder(Keys.Where(k => Pairs.ContainsKey(k))), po, Both);
        foreach (var k in ms)
        {
            var why = XlSt[k].Why;
            // 本链不支持的 NVN 结构：整份停住（direct_lib.sh gap 认这几行、退 3，本款走通用）
            if (why.StartsWith("vertex shader of shader type 0 without a VertexB part", StringComparison.Ordinal) || why.StartsWith("compute code area", StringComparison.Ordinal)) { Say($"[RED] {k}: {why}"); Environment.Exit(1); }
            if (why.StartsWith("vertex shader without a main0 main function", StringComparison.Ordinal)) { Say($"[RED] {why} ({k})"); Environment.Exit(1); }
            // 原生库缺导出 / 缺库是出包机环境缺件，不是这一支的内容缺口：整份报红（11-05 Windows 出包机巫师3：Windows 小库 nxgal.dll 没有 nxgal_dmsh_xc_tess，22 支外壳 / 域着色器各记一行缺键、整单照绿）
            if (why.StartsWith("EntryPointNotFoundException", StringComparison.Ordinal) || why.StartsWith("DllNotFoundException", StringComparison.Ordinal)) { Say($"[RED] 原生库缺件（出包机环境，不是游戏内容）：{why}（{k}）"); Environment.Exit(1); }
        }
        Say($"dsh_batch：{ms.Count} 个键，成 {ms.Count(k => XlSt[k].St == "ok")}，败 {ms.Count(k => XlSt[k].St != "ok")}");
    }

    // ---------------- 逐键收尾 ----------------
    static readonly string[] VAR = { "_bv.metal", "_bv.json", "_bf.metal", "_bf.json", "_ft.metal", "_ft.json" };
    static PyDict Json(string text) => (PyDict)Py.FromJson(JsonNode.Parse(text));
    static PyDict BoJson(string key, string sfx) { var v = Json(BOM[key][sfx]); v.Remove("xfp"); return v; }
    internal static void PutJson(Side sd, string name, PyDict v) => sd.Put(name, U8.GetBytes(Py.Dumps(v)));
    // 同一份反射 json 的「读 → 改 → 写回」按名字串行（编批库真并行：一批回填 fn_lib、另一批退回逐键删字段、影子输入库失败删 vin 可能落在同一键上，原先无锁、后写的盖掉前写的；
    //   先 Has 后 Text 之间被别的批 Drop 掉就对 null 解析、整次崩）。拿到锁时已被删掉（编不过的键）就跳过（合入线 11-02 对照 #3）
    static readonly ConcurrentDictionary<string, object> JsonLocks = new(StringComparer.Ordinal);
    static object JsonLock(Side sd, string name) => JsonLocks.GetOrAdd((ReferenceEquals(sd, IOS) ? "i/" : "m/") + name, _ => new object());
    static void EditJson(Side sd, string name, Action<PyDict> edit)
    {
        lock (JsonLock(sd, name)) { var t = sd.Text(name); if (t == null) return; var v = Json(t); edit(v); PutJson(sd, name, v); }
    }
    static PyDict With(PyDict v, string k, object x) { var d = new PyDict(v); d[k] = x; return d; }
    static void WriteRefl(string key, PyDict refl)
    {
        PutJson(MAC, key + "_b.json", With(refl, "chain_metal", MacRecord));
        if (IosLib) PutJson(IOS, key + "_b.json", With(refl, "chain_metal", IosRecord));
    }
    static void PutRefl(string name, PyDict meta)
    {
        PutJson(MAC, name, With(meta, "chain_metal", MacRecord));
        if (IosLib) PutJson(IOS, name, With(meta, "chain_metal", IosRecord));
    }
    sealed class SideFail : Exception { public readonly string Side; public SideFail(string side, string msg) : base(msg) { Side = side; } }
    static void LibBoth(string lk, string msl)   // <lk>.metallib 两侧各编一份（编不过抛 SideFail，说哪一侧）
    {
        if (!NoMac) { try { MAC.Put(lk + ".metallib", Metal.Compile("mac", msl, lk)); } catch (CompileError e) { throw new SideFail("mac", e.Message); } }
        if (IosLib) { try { IOS.Put(lk + ".metallib", Metal.Compile("ios", msl, lk)); } catch (CompileError e) { throw new SideFail("ios", e.Message); } }
    }
    internal static string VarLib(string key, string sfx, string text)   // <key><sfx>.metallib 两侧；→ null 或编不过的原因（库拿掉）
    {
        try
        {
            if (!NoMac) MAC.Put(key + sfx + ".metallib", Metal.Compile("mac", text, key + sfx));
            if (IosLib) IOS.Put(key + sfx + ".metallib", Metal.Compile("ios", text, key + sfx));
            return null;
        }
        catch (CompileError e) { MAC.Drop(key + sfx + ".metallib"); IOS?.Drop(key + sfx + ".metallib"); return Trunc(e.Message, 160); }
    }
    internal static string Trunc(string s, int n) => s.Length <= n ? s : s[..n];

    // #1429 验收（#1414 可写内存读写顺序）：每键翻译产物里的 <键>_astmem_kept（S2A.Dsh Compile 记：AstOptimizer 因中间有写 / 原子 / 屏障而没传播的次数，
    //   旧代码在这些处会传播，即输出变化点）。随产物进缓存仓，命中缓存的键照样计入；汇总行无条件打：「kept 0」= 跑到了新代码没碰上，「uncounted」> 0 = 有键的产物不带计数
    static void AstMemCount(Dictionary<string, string> f)
    {
        if (!f.TryGetValue(DshCompiler.AstMemKept, out var v)) { Count("astmem uncounted"); return; }
        int n = int.Parse(v, System.Globalization.CultureInfo.InvariantCulture); Count("astmem counted"); Count("astmem kept", n); if (n > 0) Count("astmem keys");
    }

    static (string Key, string St, string Why, PyDict Refl) FinishOne(string key)
    {
        var (st, why) = XlSt.GetValueOrDefault(key, ("translation failed", "not translated"));
        if (st != "ok") return (key, st, Trunc(why, 160), null);
        var have = BOM[key]; AstMemCount(have);
        VarSrc[key] = VAR.Where(have.ContainsKey).ToDictionary(s => s, s => have[s]);
        var refl = BoJson(key, "_b.json"); var stage = (string)refl["stage"];
        if (stage == "gs")
        {
            if (refl.TryGetValue("gs_slice", out var gsl) && Truthy(gsl)) { WriteRefl(key, refl); return (key, "ok", "", refl); }
            try
            {
                // _bgs<i> / _bgc：直通几何快路（Dsh.cs GeometryFinish），只有标直通、本体不写输出的几何着色器才有
                foreach (var sfx in new[] { "_bg0", "_b", "_bg1", "_bg2", "_bg3", "_bg4", "_bgv", "_bgs0", "_bgs1", "_bgs2", "_bgs3", "_bgs4", "_bgc" })
                {
                    if (sfx.StartsWith("_bgs", StringComparison.Ordinal) || sfx == "_bgc") { if (!have.ContainsKey(sfx + ".metal")) continue; }
                    MAC.Put(key + sfx + ".metal", U8.GetBytes(have[sfx + ".metal"])); LibBoth(key + sfx, have[sfx + ".metal"]);
                    PutRefl(key + sfx + ".json", BoJson(key, sfx + ".json"));
                }
            }
            catch (SideFail e) { return (key, "geometry failed", Trunc(e.Message, 160), null); }
            Defer[key] = null;   // 它的 _b 也随批编（原链整份出库时几何键走缓存命中路径一样进编批库，_b.metallib 取批库、反射写批库名）；没有去掉额外入口的备用源码
            return (key, "ok", "", refl);
        }
        if (stage is "hs" or "ds")
        {
            foreach (var kv in (PyDict)((PyDict)refl["tess"])["variants"])
            {
                var lk = (string)((PyDict)kv.Value)["library"]; var t = have[lk[16..] + ".metal"];
                try { LibBoth(lk, t); }
                catch (SideFail e) { return (key, e.Side == "mac" ? "metal failed" : "iOS metal failed", Trunc(e.Message, 160), null); }
                MAC.Put(lk + ".metal", U8.GetBytes(t));
            }
            if (MAC.Has(key + "_b.metal")) Defer[key] = null;   // 同几何键：原链整份出库走缓存命中路径，曲面键的 _b 也随批编（_b.metallib 取批库、反射写批库名）
            WriteRefl(key, refl);
            return (key, "ok", "", refl);
        }
        var srcB = have["_b.metal"]; var plain = have.GetValueOrDefault("_b.plain.metal");
        Defer[key] = plain;   // 库随它那一批编（UnityFlush）；编不过时退回逐键、再不行去掉额外入口
        MAC.Put(key + "_b.metal", U8.GetBytes(srcB));
        return (key, "ok", "", Variants(key, refl));
    }
    static bool PyIn(string x, object c) => c switch { string s => s.Contains(x, StringComparison.Ordinal), PyDict d => d.ContainsKey(x), System.Collections.IList l => l.Cast<object>().Any(e => e is string es && es == x), _ => false };   // Python 的 x in c
    static bool Truthy(object v) => v switch { null => false, bool b => b, string s => s.Length > 0, PyNum n => n.Text != "0" && n.Text != "0.0", long l => l != 0, int i => i != 0, _ => true };

    static PyDict Variants(string key, PyDict refl)
    {
        var v = VarSrc.GetValueOrDefault(key) ?? new();
        foreach (var sfx in new[] { "_bv", "_ft", "_bf" }) { MAC.Drop(key + sfx + ".metallib"); IOS?.Drop(key + sfx + ".metallib"); }
        refl.Remove("vin"); refl.Remove("fetch");
        var st = (string)refl["stage"];
        if (st == "vs") VinBuild(key, refl, v);
        if (st == "ps") { FtBuild(key, v); BfBuild(key, refl, v); }
        WriteRefl(key, refl);
        return refl;
    }
    static void VinBuild(string key, PyDict refl, Dictionary<string, string> v)
    {
        if (!v.ContainsKey("_bv.metal"))
        {
            var why = v.TryGetValue("_bv.json", out var bj) && Json(bj).TryGetValue("vin_fail", out var vf) ? vf as string : null;
            if (!string.IsNullOrEmpty(why)) { Count("vin not generated"); Say($"[RED] {key}: no shadow-input library ({why}): its integer inputs keep the CPU conversion"); }
            return;
        }
        var shadows = (System.Collections.IList)((PyDict)Json(v["_bv.json"])["vin"])["shadow"]; var text = v["_bv.metal"];
        Count("vin generated");
        VinSrc[key] = text;   // 随编批库同池按批编（UnityFlush），函数挂在它那一批的前缀下
        refl["vin"] = new PyDict { ["entry"] = "main0", ["entry_z"] = "main0_z", ["shadow"] = shadows };
        Count("vin inputs", shadows.Count); Count("vin float only", shadows.Cast<object>().Count(s => !PyIn("sint", s) && !PyIn("uint", s)));
    }
    static void FtBuild(string key, Dictionary<string, string> v)
    {
        var m = v.TryGetValue("_ft.json", out var fj) ? Json(fj) : null;
        if (m == null || m.Count == 0) return;
        if (m.TryGetValue("ft_covered", out var cv) && Truthy(cv)) { Count("ft covered"); return; }
        if ((m.TryGetValue("ft_fail", out var ff) && Truthy(ff)) || !v.ContainsKey("_ft.metal")) { Count("ft failed"); return; }
        var e = VarLib(key, "_ft", v["_ft.metal"]);
        if (e != null) { Count("ft failed"); Console.Error.WriteLine($"[RED] {key}: typed-output variants {Py.Dumps(m["want"])} failed to build: {e}"); return; }
        Count("ft libs"); Count("ft entries", ((System.Collections.IList)m["want"]).Count);
    }
    static void BfBuild(string key, PyDict refl, Dictionary<string, string> v)
    {
        if (!v.ContainsKey("_bf.metal")) return;
        Count("bf generated");
        if (VarLib(key, "_bf", v["_bf.metal"]) != null) return;
        refl["fetch"] = Json(v["_bf.json"]);
    }

    static readonly ConcurrentDictionary<string, (string Key, string St, string Why, PyDict Refl)> Fin = new(StringComparer.Ordinal);
    // 汇总两项（没解出槽 / 不认识的绑定种类）收尾时就按反射算好，只留两个标志：原先 Fin 给每键留整份解析后的反射（装箱对象图）只为最后这两个计数（同 Python res 只留状态 / 原因），
    //   随键数与绑定数涨（11-02 Spare-host 16 GB 马力欧派对 82790 键，翻译段就到 phys_footprint 39 GB）
    static readonly ConcurrentDictionary<string, (bool NoReg, bool Unk)> FinFlags = new(StringComparer.Ordinal);
    static readonly HashSet<string> SlotK = new() { "cbuf", "samp", "samp_tex", "tex", "img", "tbuf", "sbuf", "ubo_ptr", "sbuf_ubo", "tex_ubo", "tbuf_ubo", "img_ubo", "samp_ubo", "samp_id" };
    static IEnumerable<PyDict> Binds(PyDict x) => x.TryGetValue("bindings", out var b) && b is System.Collections.IList l ? l.OfType<PyDict>() : Enumerable.Empty<PyDict>();
    // 追不到单一槽的动态句柄数组（名字以 _cb0_40000000 结尾、类型 array<…>）按设计不出槽、kind 可为 tex / ?，宿主按名字认成 NVN_RB_TEXD / SAMPD（nvn_refl.m），不算没解出 / 不认识
    //   （11-02 马力欧派对 超级巨星 6370 支全是这一形状，原先两项都报 6370）
    static bool Dyn(PyDict b) => b.GetValueOrDefault("msl_name") is string n && n.EndsWith("_cb0_40000000", StringComparison.Ordinal) && b.GetValueOrDefault("msl_type") is string t && t.StartsWith("array<", StringComparison.Ordinal);
    static (bool, bool) SumFlags(PyDict x) =>
        (Binds(x).Any(b => !Dyn(b) && SlotK.Contains(b.GetValueOrDefault("kind") as string ?? "") && (!b.TryGetValue("reg", out var g) || g == null)),
         Binds(x).Any(b => !Dyn(b) && (b.GetValueOrDefault("kind") as string) == "?"));   // 逐键收尾结果（Translate 里随翻译做）
    static List<(string Key, string St, string Why, PyDict Refl)> Finish() =>   // 按原先顺序排：非配对键在前、配对的顶点着色器在后（_b_build.json、汇总行）
        Keys.Where(k => !Pairs.ContainsKey(k)).Concat(Keys.Where(k => Pairs.ContainsKey(k))).Select(k => Fin[k]).ToList();

    // ---------------- 编批库 / 两张表 / 发布：接 Unity.cs、C1Cb.cs、LibPack.cs（移植中，接入点） ----------------
    internal static Dictionary<string, string> UnityFlush()
    {
        // 同原 dmsh_build.py unity_flush：按内容切批（Unity.MakePlan，与 Python 逐字节同的切法 / 批名 / 批源码）、同源键共用一份库、编不过的批退回逐键（再不行去掉额外入口）；
        //   影子输入库排在同一个池里、编批库后面，编批库真有编不过的键时按真名单重切重编。一批的「拼源码 → 查缓存 → 编译 → 回填」全在工作线程里，Metal 路数由 Metal 的闸限
        var tg = new List<(string T, Side Sd)>(); if (!NoMac) tg.Add(("mac", MAC)); if (IosLib) tg.Add(("ios", IOS));
        var dirs = IosLib ? new[] { MAC, IOS } : new[] { MAC };
        // 待编源码按需从 Side 读（_b.metal 字节），用时才解码；退回逐键去掉额外入口后换了源码的那几支记在 srcOver。原先整份解码成 UTF-16 常驻（随键数线性）
        var deferKeys = Defer.Keys.ToList();
        var srcOver = new ConcurrentDictionary<string, byte[]>(StringComparer.Ordinal);
        byte[] SrcB(string k) => srcOver.TryGetValue(k, out var b) ? b : MAC.Get(k + "_b.metal");
        string Text(string k) => U8.GetString(SrcB(k));
        long vinCap = Unity.VinBatchMax(Environment.GetEnvironmentVariable("DMSH_VIN_BATCH_MB") ?? "3");
        // 编批库每批源码封顶（MB，0 = 只按键数切）：宿主用到一支就把它所在的整批建成 Metal 库，库的字节与 Metal 内部占用都落在 4 GB 以下的低区；
        //   11-05 时之笛第十二版测试设备1：首帧前预热 259 支映射了 116 段批库 394 MB、Metal 内部 1529 MB，低区开局只剩 110 MB，进 3D 崩在分配失败
        long unityCap = Unity.VinBatchMax(Environment.GetEnvironmentVariable("DMSH_UNITY_BATCH_MB") ?? "0.5");
        IReadOnlyDictionary<string, string> vinSrc = VinSrc;   // 落盘的视图，取值才读（原先整份拷进字典）
        var plan = Unity.MakePlan(new TextView(deferKeys, SrcB), Hot, UNITY, vinSrc, vinCap, unityCap: unityCap);
        var dgMemo = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
        string Dg(string k) => dgMemo.GetOrAdd(k, x => Unity.Dg(Text(x)));   // 按当前源码；同一份只算一次（换源码时作废，见 srcOver 处）
        List<string> Group(string k) => plan.Same.TryGetValue(k, out var l) ? new[] { k }.Concat(l).ToList() : new List<string> { k };
        Count("unity same MSL keys", plan.Same.Values.Sum(l => l.Count));
        // 按成员复用以前编过的批库（11-02 维护者「已经有的缓存为什么不能复用」）：批库按整批源码寻址，一批里一支变了整批重编、批里没变的几十支陪编；
        //   翻译器改一条指令只动 3% 的支，现行切法下仍要重编约一半的批。这里先查每个代表键「上次编进了哪一批」（批成员索引，Unity.ReuseIndex），
        //   那一批的库还在、键在批里的那段源码与现在逐字节同、批里过半成员仍在用，就整批拿来（库里多出的已不用的函数无害：宿主按 fn_prefix 取函数）；
        //   其余键照原切法切批编译。判据只认输出字节（成员段摘要），不靠声明改了什么
        var reuse = Unity.ReuseIndex.Pick(plan.Reps, tg.Select(x => x.T).ToList(), Metal.IdentHex, k => Dg(k), k => Text(k), "u");
        // 封顶时旧批只在索引记了整批源码量、且不超上限时拿来：没记的是封顶前编的大批，拿回来运行时照样整批建库
        if (unityCap > 0) foreach (var n in reuse.Where(kv => kv.Value.Size < 0 || kv.Value.Size > unityCap).Select(kv => kv.Key).ToList()) { reuse.Remove(n); Count("unity reuse over cap"); }
        var units = plan.Order;
        if (reuse.Count > 0)
        {
            while (true)   // 剩下的键照原切法重切；新批名与拿来的批同名时（批首键换了批）不拿那一批，重切
            {
                var covered = new HashSet<string>(reuse.Values.SelectMany(r => r.Keys), StringComparer.Ordinal);
                var rest = deferKeys.Where(k => !covered.Contains(plan.Rep(k))).ToList();
                var p2 = Unity.MakePlan(new TextView(rest, SrcB), Hot, UNITY, null, vinCap, unityCap: unityCap);
                var clash = p2.Batches.Select(b => "u" + Dg(b[0])).Where(reuse.ContainsKey).ToList();
                if (clash.Count == 0) { units = p2.Order; break; }
                foreach (var n in clash) reuse.Remove(n);
            }
        }
        var vinReuse = Unity.ReuseIndex.Pick(plan.Reps.Where(vinSrc.ContainsKey).ToList(), tg.Select(x => x.T).ToList(), Metal.IdentHex, k => Dg(k) + "_" + Unity.Sha256Hex(vinSrc[k])[..16], k => vinSrc[k], "v", k => Dg(k));
        var vinCovered = new HashSet<string>(vinReuse.Values.SelectMany(r => r.Keys), StringComparer.Ordinal);
        var vinReps = plan.Reps.Where(k => !vinCovered.Contains(k)).ToList();
        var vinPlanOrder = vinCovered.Count == 0 ? plan.VinOrder : Unity.VinPlan(vinReps, Hot, UNITY, Dg, vinSrc, vinCap).Order;
        var failed = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
        void Put(List<string> ks, string name)
        {
            foreach (var (_, sd) in tg) foreach (var k in ks) foreach (var m in Group(k)) sd.Alias(name + ".metallib", m + "_b.metallib");   // 指向批库那份字节，不另写
            foreach (var sd in dirs) foreach (var k in ks) foreach (var m in Group(k))
            {
                bool wl = Text(k).Contains("render_target_array_index", StringComparison.Ordinal);   // 宿主原先读库字节判它；批库里还有别的键（nvn_mtl.m shader_load）
                EditJson(sd, m + "_b.json", v => { v["fn_prefix"] = "s" + Dg(k) + "_"; v["fn_lib"] = name; v["writes_layer"] = wl; });
            }
        }
        string BuildBatch(List<string> ks, string name)   // → null，或编不过的原因
        {
            var src = Unity.Src(ks.Select(k => (Dg(k), Text(k))), out int shared); Count("unity main0_u shared", shared);
            var at = new Dictionary<string, string>();
            foreach (var (t, sd) in tg)
                try { sd.Put(name + ".metallib", Metal.Compile(t, src, name, out var mk)); at[t] = mk; }
                catch (CompileError e) { return $"{t}: {Trunc(e.Message, 160)}"; }
            Unity.ReuseIndex.Record("u", name, at, Metal.IdentHex, ks.Select(k => (Dg(k), Dg(k), Text(k))).ToList());   // 记下这批的成员：下次翻译器改了、这些键 MSL 没变就整批拿来
            return null;
        }
        void OneBatch(List<string> ks)
        {
            var name = "u" + Dg(ks[0]); var why = BuildBatch(ks, name);
            if (why == null) { Put(ks, name); Count("unity batches"); Count("unity keys", ks.Count); return; }
            var end = new List<(string What, int N)>(); void End(string w) { int i = end.FindIndex(x => x.What == w); if (i < 0) end.Add((w, 1)); else end[i] = (w, end[i].N + 1); }
            foreach (var k in ks)
            {
                var e1 = BuildBatch(new() { k }, "u" + Dg(k));
                if (e1 != null && Defer.TryGetValue(k, out var plain) && !string.IsNullOrEmpty(plain))   // 去掉额外入口（同源键一起）
                {
                    var pb = U8.GetBytes(plain); srcOver[k] = pb; dgMemo.TryRemove(k, out _);
                    foreach (var m in Group(k))
                    {
                        MAC.Put(m + "_b.metal", pb);
                        foreach (var sd in dirs) { EditJson(sd, m + "_b.json", v => { foreach (var f in new[] { "entry_layer", "entry_layer_z", "layer_from", "entry_u", "u_mask" }) v.Remove(f); }); }
                    }
                    e1 = BuildBatch(new() { k }, "u" + Dg(k)); End(e1 == null ? "built without extra entry points" : "failed");
                }
                else End(e1 != null ? "failed" : "built alone");
                if (e1 == null) { Put(new() { k }, "u" + Dg(k)); continue; }
                foreach (var m in Group(k)) { failed[m] = e1; foreach (var sd in dirs) foreach (var x in new[] { "_b.json", "_b.metal", "_b.metallib" }) { if (x == "_b.json") lock (JsonLock(sd, m + x)) sd.Drop(m + x); else sd.Drop(m + x); } }
            }
            Count("unity fallback batches"); Count("unity fallback keys", ks.Count);
            var first = why.Trim().Split('\n')[0]; Say($"[unity] batch {name} ({ks.Count} keys) does not compile as one unit, built key by key: " + string.Join(", ", end.Select(x => $"{x.N} {x.What}"))
                + $" (batch error: {(why.Trim().Length > 0 ? Trunc(first, 200) : "?")})");
        }
        var vinBuilt = new ConcurrentDictionary<string, bool>(StringComparer.Ordinal);
        string VinBuild(List<string> kk)
        {
            var src = Unity.Src(kk.Select(k => (Dg(k), vinSrc[k])), out _);
            var libs = new Dictionary<string, byte[]>(); var at = new Dictionary<string, string>(); var vn = Unity.VinFile(Dg(kk[0]), kk.Count)[..^6];
            foreach (var (t, _) in tg) try { libs[t] = Metal.Compile(t, src, vn, out var mk); at[t] = mk; } catch (CompileError e) { return $"{t}: {Trunc(e.Message, 160)}"; }
            foreach (var (t, sd) in tg) foreach (var k in kk) foreach (var m in Group(k)) sd.Put(m + "_bv.metallib", libs[t]);
            Unity.ReuseIndex.Record("v", vn, at, Metal.IdentHex, kk.Select(k => (Dg(k) + "_" + Unity.Sha256Hex(vinSrc[k])[..16], Dg(k), vinSrc[k])).ToList());
            return null;
        }
        void VinDrop(string k, string why)
        {
            foreach (var m in Group(k))
            {
                foreach (var sd in dirs) { sd.Drop(m + "_bv.metallib"); EditJson(sd, m + "_b.json", v => v.Remove("vin")); }
                Count("vin failed");
            }
            Say($"[RED] {k}: the shadow-input library does not compile ({Trunc(why, 120)}): its integer inputs keep the CPU conversion");
        }
        void VinOne(List<string> kk)
        {
            bool ok = VinBuild(kk) == null; vinBuilt[string.Join(',', kk)] = ok;
            if (ok) return;
            foreach (var k in kk) { var w = VinBuild(new() { k }); if (w != null) VinDrop(k, w); }
        }
        void Reused(Unity.ReuseIndex.Hit h, bool vin)   // 拿来的一批：库按批放进各侧，回填同编出来的一样
        {
            var libs = new Dictionary<string, byte[]>();
            foreach (var (t, _) in tg) { var lib = Metal.Cached(t, h.Mtl[t]); if (lib == null) break; libs[t] = lib; }
            if (libs.Count != tg.Count)   // 选中后到读之前库条目坏了 / 被淘汰：这些键照常编（同名冲突只在批首键 MSL 摘要撞上已不在用的旧批名时才有，不另防）
            {
                Say($"[unity] reused batch {h.Name} is gone from the cache, building its {h.Keys.Count} keys again");
                if (vin) VinOne(h.Keys); else OneBatch(h.Keys);
                return;
            }
            if (vin) { foreach (var (t, sd) in tg) foreach (var k in h.Keys) foreach (var m in Group(k)) sd.Put(m + "_bv.metallib", libs[t]); vinBuilt[string.Join(',', h.Keys)] = true; Count("vin reused batches"); Count("vin reused keys", h.Keys.Count); return; }
            foreach (var (t, sd) in tg) sd.Put(h.Name + ".metallib", libs[t]);
            Put(h.Keys, h.Name); Count("unity reused batches"); Count("unity reused keys", h.Keys.Count);
        }
        // 进度按待编源码 MB 计，不按批数：Metal 编译耗时与源码字节成正比（11-04 Spare-host 实测 0.14 → 7.6 → 24.5 秒 / 0.06 → 12 → 39 MB），批又是大的先编，
        //   按批数外推把开头的大批当常态（Pokopia 2,696 批：头 105 批是批数的 4%、字节的 17%，编到这里报「还剩 11 小时」，按字节与实测吞吐折算约 2.2 小时）。拿来的批不编、不计
        int Mb(long n) => (int)Math.Max(1, (n + (1 << 20) - 1) >> 20);
        var jobs = reuse.Values.Select(h => (Run: (Action)(() => Reused(h, false)), Mb: 0)).Concat(vinReuse.Values.Select(h => (Run: (Action)(() => Reused(h, true)), Mb: 0)))
            .Concat(units.Select(b => (Run: (Action)(() => OneBatch(b)), Mb: Mb(b.Sum(k => plan.Len[k]))))).Concat(vinPlanOrder.Select(b => (Run: (Action)(() => VinOne(b)), Mb: Mb(b.Sum(k => Unity.PyLen(vinSrc[k])))))).ToList();
        using var tk = new Ticker("直连库·编批库（MB）", jobs.Sum(j => j.Mb));
        Parallel.ForEach(InOrder(jobs), new ParallelOptions { MaxDegreeOfParallelism = NJ * 2 }, j => { j.Run(); tk.Step(j.Mb); });   // 大的先编；拼源码与回填在多出的那些线程里做，Metal 不断粮
        var vinOrder = vinPlanOrder;
        if (!failed.IsEmpty)
        {
            var fs = new HashSet<string>(failed.Keys, StringComparer.Ordinal);
            var (_, order) = Unity.VinPlan(vinReps, Hot, UNITY, Dg, vinSrc, vinCap, fs);
            foreach (var m in fs) foreach (var sd in dirs) sd.Drop(m + "_bv.metallib");
            Parallel.ForEach(InOrder(order.Where(b => !vinBuilt.ContainsKey(string.Join(',', b)))), new ParallelOptions { MaxDegreeOfParallelism = NJ * 2 }, VinOne);
            vinOrder = order;
        }
        Count("vin batches", vinOrder.Count(b => vinBuilt.GetValueOrDefault(string.Join(',', b))) + vinReuse.Values.Count(h => vinBuilt.GetValueOrDefault(string.Join(',', h.Keys))));
        return new Dictionary<string, string>(failed, StringComparer.Ordinal);
    }
    // c1 越界核查表 + 常量读范围表（C1Cb，原 c1_guard.py / cb_extent.py --both）：编批库期间在 Mac 侧快照上并发算一遍；收尾按最终的 Mac 侧再出任务，
    //   MSL / c1 长度 / 绑定都没变的直接用快照那遍的结果（编批库只往反射写库名；退回逐键去掉额外入口的那几支 MSL 变了，照常重算）
    static Dictionary<string, (string Sig, (string C1, string Row) R)> C1CbSnap;
    //   照原 Python（dmsh_build.py 后台 / 收尾两遍都起 cb_extent.py 子进程、先把 Mac 侧写成文件）：两遍都在子进程里算（dsh_batch --c1cb <目录>），
    //   工作内存与大对象随子进程退出整块归还；主进程只留每支的签名（MSL 字节摘要 + span + 绑定）与结果行。原先在主进程里算，快照签名带整段 MSL 文本（UTF-16）留到收尾
    static string C1CbJson(string n) => C1Cb.KeyOf(n) + "_b.json";
    // 分批（11-08 巫师3 Windows 出包机三次盘满，rc=127 死在收尾）：这一步把每支 MSL 明文写进临时目录再交子进程，巫师3 约 3 万键、明文近百 GB。子进程逐支独立分析（C1Cb.Cli 每支一个任务），
    //   按累计字节切批（缺省 256 MB，S2A_C1CB_CHUNK_MB，0 = 每支一批），一批跑完删目录，临时盘峰值 = 一批。原缺省 4 GB 对玩家等于不切：怪猎崛起后台遍
    //   整份 2.08 GB 一次落盘、正叠在编批库的盘峰值上（v0.2.4 出包空间）；后台遍与编批库并发，多起几次子进程不进墙钟
    static Dictionary<string, (string C1, string Row)> C1CbChild(IReadOnlyList<string> names, string tag, Dictionary<string, string> sigs)
    {
        var res = new Dictionary<string, (string C1, string Row)>(StringComparer.Ordinal);
        long limit = long.TryParse(Environment.GetEnvironmentVariable("S2A_C1CB_CHUNK_MB"), out var mb) && mb >= 0 ? mb * 1000000 : 256000000L;
        var cur = new List<string>(); long bytes = 0; int part = 0;
        void Flush() { if (cur.Count == 0) return; foreach (var kv in C1CbChunk(cur, tag + part++, sigs)) res[kv.Key] = kv.Value; cur = new List<string>(); bytes = 0; }
        foreach (var n in names) { var m = MAC.Get(n); if (m == null) continue; if (cur.Count > 0 && bytes + m.Length > limit) Flush(); cur.Add(n); bytes += m.Length; }
        Flush();
        return res;
    }
    static Dictionary<string, (string C1, string Row)> C1CbChunk(IReadOnlyList<string> names, string tag, Dictionary<string, string> sigs)
    {
        var res = new Dictionary<string, (string C1, string Row)>(StringComparer.Ordinal);
        if (names.Count == 0) return res;
        var dir = Path.Combine(Work, "c1cb_" + tag); Directory.CreateDirectory(dir);
        try
        {
            foreach (var n in names)
            {
                var m = MAC.Get(n); var j = MAC.Get(C1CbJson(n)); if (m == null) continue;
                File.WriteAllBytes(Path.Combine(dir, n), m); if (j != null) File.WriteAllBytes(Path.Combine(dir, C1CbJson(n)), j);
                if (sigs != null) sigs[n] = C1Cb.SigOf(n, m, j);
            }
            var self = Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "dotnet" ? new[] { Environment.ProcessPath, typeof(Build).Assembly.Location } : new[] { Environment.ProcessPath };
            var psi = new ProcessStartInfo(self[0]) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
            foreach (var x in self[1..].Concat(new[] { "--c1cb", dir, "-j", NJ.ToString() })) psi.ArgumentList.Add(x);
            using var p = Process.Start(psi); var e = p.StandardError.ReadToEndAsync();
            string ln;
            while ((ln = p.StandardOutput.ReadLine()) != null)
            {
                var c = ln.Split('\t'); if (c.Length < 3) continue;
                res[c[0]] = (c[1].Length > 0 ? c[1] : null, c[2].Length > 0 ? string.Join("\t", c[2..]) : null);   // 子进程把 null 打成空串（C1 是键名、行非空，空串即 null）
            }
            p.WaitForExit(); var err = e.Result;
            if (p.ExitCode != 0) throw new InvalidOperationException($"两张表子进程失败（{p.ExitCode}）：{Trunc(err.Trim(), 600)}");
            return res;
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
    static List<string> C1CbNames() => MAC.Names().Where(n => n.EndsWith(".metal", StringComparison.Ordinal)).OrderBy(n => n, StringComparer.Ordinal).ToList();   // = C1Cb.BothJobs 的任务与次序
    static void C1CbFill()
    {
        double t0 = Clock.Elapsed.TotalSeconds;
        var names = C1CbNames(); var sigs = new Dictionary<string, string>(StringComparer.Ordinal);
        Dictionary<string, (string C1, string Row)> r;
        // 后台遍只是预算，失败不算整次失败（同 Python 打黄字、收尾全算）：快照置空，收尾遍按最终产物重算（合入线 11-02 对照 #4）
        try { r = C1CbChild(names, "bg", sigs); }
        catch (Exception e) { C1CbSnap = null; Say($"[YELLOW] c1 / cb tables: the background pass failed, the final pass computes them all: {Trunc(e.Message, 300)}"); return; }
        C1CbSnap = names.Where(r.ContainsKey).ToDictionary(n => n, n => (sigs[n], r[n]), StringComparer.Ordinal);
        Say($"[分段] 两张表后台遍：{names.Count} 支，第 {t0:F1} 秒起、用 {Clock.Elapsed.TotalSeconds - t0:F1} 秒");
    }
    static void C1CbFinal()
    {
        var names = C1CbNames(); var res = new (string C1, string Row)[names.Count]; var redo = new List<string>();
        for (int i = 0; i < names.Count; i++)
            if (C1CbSnap != null && C1CbSnap.TryGetValue(names[i], out var c) && c.Sig == C1Cb.SigOf(names[i], MAC.Get(names[i]), MAC.Get(C1CbJson(names[i])))) res[i] = c.R; else redo.Add(names[i]);
        var rr = C1CbChild(redo, "final", null);
        for (int i = 0; i < names.Count; i++) if (rr.TryGetValue(names[i], out var x)) res[i] = x;
        var lines = C1Cb.WriteTables(res, TableHead(Out), Table("c1_full.tsv"), Table("cb_extent.tsv"));
        Say($"c1_full.tsv: {lines[0]}"); Say($"cb_extent.tsv: {lines[1]}"); Count("c1cb recomputed", redo.Count);
    }
    static string WorkUsage()
    {
        static string M(long b) => $"{b / 1048576.0:F0} MB";
        string S(string n, Side sd) { if (sd == null) return ""; var (b, t, tr) = sd.Usage(); return $"；{n} 侧 库与反射 {M(b)}、源码 {M(t)}（原 {M(tr)}）"; }
        return $"临时数据：（盘上，压缩后）待编源码 {M(Spill.Length)}（原 {M(Spill.RawLength)}）" + S("Mac", MAC) + S("iOS", IOS);
    }

    static int PublishAll(Action sourcesDone)   // 发布那一侧核验、打包成 lib.NNN.pak + lib.idx、ps_inputs / keys.tsv（LibPack.Publish）；没给发布侧（手工出库、单测）就两侧按键导出到各自输出目录
    {
        if (IosOut != null && Publish != null)
        {
            var w = new StringWriter();
            var err = LibPack.Publish(MAC.All, IOS?.All, NoMac, Publish, IosOut, Chain, w, sourcesDone);
            foreach (var l in w.ToString().Split('\n').Where(l => l.Length > 0)) Say(l);
            if (err != null) { Say(err); return 1; }
        }
        else { MAC.Export(Out); if (IOS != null) IOS.Export(IosOut); }
        return 0;
    }

    // ---------------- 采样模拟变体（缺口族 31：跑局见过的键预编进库，种类 51） ----------------
    static void SeFinish()
    {
        var f = Table("se_want.tsv");
        var want = File.Exists(f) ? File.ReadLines(f).Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith('#')).ToList() : new List<string>();
        Count("se wanted", want.Count);
        Parallel.ForEach(InOrder(want.Where(k => MAC.Has(k + "_b.metal"))), new ParallelOptions { MaxDegreeOfParallelism = NJ * 2 }, k =>
        {
            string s0 = MAC.Text(k + "_b.metal"), v;
            try { v = DshCompiler.FsRd(s0); }
            catch (Exception e) { Count("se failed"); Say($"[RED] {k}: no sampler-emulation variant (S2A.Dsh FsRd: {e.GetType().Name}: {e.Message.Split('\n')[0]}): the device compiles it at first use"); return; }
            if (v == s0) { Count("se nothing to emulate"); return; }
            var e2 = VarLib(k, "_se", v);
            if (e2 != null) { Count("se failed"); Say($"[RED] {k}: the sampler-emulation variant does not compile ({Trunc(e2, 120)}): the device compiles it at first use"); }
            else Count("se built");
        });
    }

    // ---------------- 汇总 ----------------
    static void Summaries(List<(string Key, string St, string Why, PyDict Refl)> res)
    {
        var st = res.GroupBy(r => r.St).ToDictionary(g => g.Key, g => g.Count());
        Say($"shaders {res.Count}: ok {st.GetValueOrDefault("ok")}, " + string.Join(", ", st.Where(x => x.Key != "ok").Select(x => $"{x.Key} {x.Value}")));
        Say($"shader cache: hit {N("cache hit")}, rebuilt {N("cache miss")}");
        Say($"ast mem order kept: {N("astmem kept")} in {N("astmem keys")} keys (counted {N("astmem counted")} keys, uncounted {N("astmem uncounted")})");
        Say($"variant cache{(BfOn ? "" : " (readable-tile _bf off, DMSH_BF unset)")}: generated {N("bf generated")}");
        Say($"typed-output variants (ft_finish, fout_want.tsv {FoutWant.Values.Sum(s => s.Count)} requests): {N("ft entries")} entry points in {N("ft libs")} libraries, {N("ft covered")} covered by main0_u or nothing integer after the colour filter, {N("ft failed")} libraries failed");
        Say($"sampler-emulation variants (<key>_se, se_want.tsv {N("se wanted")} keys): built {N("se built")}, nothing to emulate {N("se nothing to emulate")}, failed {N("se failed")}");
        Say($"shadow-input libraries (<key>_bv, S2A.Dsh DshVin): {N("vin generated")} generated ({N("vin batches")} batches), {N("vin failed")} failed to compile, {N("vin not generated")} not generated; {N("vin inputs")} integer inputs shadowed, {N("vin float only")} of them with no other-sign shadow (attribute indices ran out)");
        Say(Metal.Summary());
        var ok = res.Where(r => r.St == "ok" && FinFlags.ContainsKey(r.Key)).Select(r => FinFlags[r.Key]).ToList();
        int noreg = ok.Count(x => x.NoReg), unk = ok.Count(x => x.Unk);
        Say($"shaders with a binding whose slot was not decoded {noreg}, with an unrecognized binding kind {unk} (loading them at run time prints [RED] lines)");
        foreach (var lvl in st.Keys.Where(k => k != "ok"))
            foreach (var g in res.Where(r => r.St == lvl).GroupBy(r => r.Why).OrderByDescending(g => g.Count()).Take(10)) Say($"  [{lvl}] {g.Count(),5}  {g.Key}");
    }

    // ---------------- 小工具 ----------------
    internal static string JStr(string s) => Py.Dumps(s);
    static Dictionary<string, string> ReadStamp(string lib)
    {
        var p = Path.Combine(lib, "inputs.tsv"); var d = new Dictionary<string, string>();
        if (!File.Exists(p)) return d;
        foreach (var l in File.ReadLines(p)) { int t = l.IndexOf('\t'); if (t > 0 && !l.StartsWith('#')) d[l[..t]] = l[(t + 1)..]; }
        return d;
    }
    // 印章另记出这份库的翻译器指纹 xfp（DshCompiler.Xfp）与工具锁摘要 lock（--lock 文件字节 sha256 前 16 位，没给 --lock 记 none）：
    //   direct_lib.sh 出库后拿出包树自己算的 dmsh_chain.xlate_fp() / 锁摘要逐项比，不等报红。出库命令可经 DSH_BATCH_CMD 换成别处的现成程序
    //   （11-06 时之笛第 49 版：Windows 出包机上 11-06 14:09 按旧树编的 dsh_batch.exe 给 2ce17db8c 出库，键里的 Xfp 是旧的，41971 支全命中旧缓存，翻译器改动没进包），
    //   只有核产物才不依赖调用链里每一层都守规矩。宿主 nvn_mtl.m 只读 game / inputs 两行，多两行不影响
    static void WriteStamp(string lib, string game, string digest)
    {
        var tmp = Path.Combine(lib, "inputs.tsv.tmp");
        string lockFp = A.TryGetValue("--lock", out var lk) ? Sha(File.ReadAllBytes(lk))[..16] : "none";
        File.WriteAllText(tmp, $"# the game and the profile inputs this library was built from (dm/gfx/tools/dmsh_chain.py inputs), and the translator / tool lock that built it\ngame\t{game}\ninputs\t{digest}\nxfp\t{DshCompiler.Xfp}\nlock\t{lockFp}\n", U8);
        File.Move(tmp, Path.Combine(lib, "inputs.tsv"), true);
    }
    internal static string TableHead(string lib) => $"# chain {Path.GetFileName(Path.TrimEndingDirectorySeparator(lib))} inputs {ReadStamp(lib).GetValueOrDefault("inputs", "none")}";
    internal static string OutDir => Out; internal static string IosOutDir => IosOut; internal static string PublishSide => Publish; internal static bool IosLibOn => IosLib; internal static bool NoMacOn => NoMac;
    internal static int Jobs => NJ; internal static string ProfileTable(string n) => Table(n); internal static string ChainV => Chain;
}

/// <summary>出库的一侧（Mac / iOS）：文件名 → 字节，只在内存（同原 dmsh_out.Side）</summary>
/// <summary>追加写的数据文件（出包工作目录里，进程退出即删）：各线程原子预留偏移、各写各的段，不加锁；按 (偏移, 长度) 读回。
/// 出库的全部产物与待编源码只在这里存一份、内存只留索引（11-02：8 万键款原先全留内存，16 GB 机器换页卡死；也不按键写小文件——10-31 马车8 一遍开 74.6 万次文件）</summary>
sealed class BlobFile
{
    // 每段先压缩再落盘（v0.2.6：0400A3A01EE4C000 冷出，9.9 万支的 MSL 源码原样堆在这里 23 GB，峰值随支数线性涨；同类文本 zlib 约 3.5 倍）。
    //   段 = 1 字节标记（0 原样 / 1 zlib）+ 4 字节原长 + 数据；不到 MinZ 字节的小段（反射 json 等）原样存，省压缩开销
    const int MinZ = 512;
    //   只压文本（compress = true：MSL 源码、待编源码）。库与反射不压：发布打包单线程逐个读库，解压让它从 10 秒变 32 秒（怪猎崛起两局同负载对比），省下的不值
    readonly Microsoft.Win32.SafeHandles.SafeFileHandle h; readonly bool z; long tail, raw;
    public BlobFile(string path, bool compress) { z = compress; h = File.OpenHandle(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, FileOptions.DeleteOnClose); }
    public long Length => Interlocked.Read(ref tail);   // 盘上字节（压缩后）
    public long RawLength => Interlocked.Read(ref raw);   // 写进来的原始字节
    public void Close() => h.Dispose();   // DeleteOnClose：文件随之删掉，之后再读抛 ObjectDisposedException
    public (long Off, int Len) Write(ReadOnlySpan<byte> b)
    {
        byte[] rec;
        if (!z || b.Length < MinZ) { rec = new byte[5 + b.Length]; b.CopyTo(rec.AsSpan(5)); }
        else
        {
            var ms = new MemoryStream(b.Length / 3 + 64); ms.Write(new byte[5]);
            using (var z = new ZLibStream(ms, CompressionLevel.Fastest, leaveOpen: true)) z.Write(b);
            rec = ms.ToArray(); rec[0] = 1;
        }
        BitConverter.TryWriteBytes(rec.AsSpan(1, 4), b.Length);
        Interlocked.Add(ref raw, b.Length);
        long off = Interlocked.Add(ref tail, rec.Length) - rec.Length; RandomAccess.Write(h, rec, off); return (off, rec.Length);
    }
    public byte[] Read((long Off, int Len) e)
    {
        var rec = new byte[e.Len];
        for (int got = 0; got < e.Len;) { int n = RandomAccess.Read(h, rec.AsSpan(got), e.Off + got); if (n <= 0) throw new IOException("出库数据文件读不全"); got += n; }
        int len = BitConverter.ToInt32(rec, 1);
        if (rec[0] == 0) return rec.AsSpan(5, len).ToArray();
        var b = new byte[len];
        using (var z = new ZLibStream(new MemoryStream(rec, 5, rec.Length - 5), CompressionMode.Decompress))
            for (int got = 0; got < len;) { int n = z.Read(b, got, len - got); if (n <= 0) throw new IOException("出库数据文件解压不全"); got += n; }
        return b;
    }
}

/// <summary>一侧（Mac / iOS）的出库产物：文件名 → 字节，字节在 BlobFile 里、内存只留索引；同一个字节数组放进多个名字（批库给同批各键）只写一份。
/// 源码（*.metal）与库 / 反射分两个文件存：源码最后的读者（两张表收尾、发布里的 ps_inputs）读完即 DropText 整份放掉，不等进程退出（v0.2.4 出包空间）。
/// Get 每次读回新数组（调用方自己的）；DropText 之后再取源码抛错（名字照旧在，核齐全只看名字）</summary>
sealed class Side
{
    readonly BlobFile bf, tx; volatile bool txGone; readonly ConcurrentDictionary<string, (long, int)> f = new(StringComparer.Ordinal);
    readonly System.Runtime.CompilerServices.ConditionalWeakTable<byte[], System.Runtime.CompilerServices.StrongBox<(long, int)>> seen = new(), seenTx = new();
    public Side(string dir) { bf = new BlobFile(Path.Combine(dir, $"side_{Guid.NewGuid():N}.dat"), compress: false); tx = new BlobFile(Path.Combine(dir, $"side_{Guid.NewGuid():N}.src.dat"), compress: true); }
    static bool IsText(string n) => n.EndsWith(".metal", StringComparison.Ordinal);
    BlobFile Of(string n) { if (!IsText(n)) return bf; if (txGone) throw new InvalidOperationException($"源码已放（DropText 之后）还在取 {n}"); return tx; }
    public byte[] Get(string n) => f.TryGetValue(n, out var e) ? Of(n).Read(e) : null;
    public string Text(string n) { var b = Get(n); return b == null ? null : Encoding.UTF8.GetString(b); }
    public bool Has(string n) => f.ContainsKey(n);
    public void Put(string n, byte[] b)
    {
        var (file, sn) = IsText(n) ? (Of(n), seenTx) : (bf, seen);
        if (!sn.TryGetValue(b, out var box)) { box = new(file.Write(b)); sn.AddOrUpdate(b, box); }
        f[n] = box.Value;
    }
    public void Drop(string n) => f.TryRemove(n, out _);
    /// <summary>to 指向 from 已有的那份字节（不再写一遍）；from 不在 → false。批库给同批各键（Build.UnityFlush Put）：原先 Get 出新数组再 Put，
    /// 同一份批库在数据文件里多写一遍（v0.2.6：0400A3A01EE4C000 冷出到编批库 11.5 GB 时盘涨约 3 倍于批库量，这是其中一倍）</summary>
    public bool Alias(string from, string to) { if (!f.TryGetValue(from, out var e) || IsText(from) != IsText(to)) return false; f[to] = e; return true; }
    public void DropText() { txGone = true; tx.Close(); }
    public (long Bin, long Text, long TextRaw) Usage() => (bf.Length, tx.Length, tx.RawLength);
    public List<string> Names() => f.Keys.ToList();
    public IReadOnlyDictionary<string, byte[]> All => new View(this);
    public void Export(string dir)
    {
        Directory.CreateDirectory(dir);
        var own = new System.Text.RegularExpressions.Regex(@"\A(?:[0-9a-f]{16}_|u[0-9a-f]{16}\.metallib\z)");   // 出库产物的文件名（同原 dmsh_out.OWN，re.match 锚在开头）
        foreach (var p in Directory.GetFiles(dir)) { var n = Path.GetFileName(p); if (own.IsMatch(n) && !f.ContainsKey(n)) File.Delete(p); }
        foreach (var n in f.Keys.OrderBy(x => x, StringComparer.Ordinal)) File.WriteAllBytes(Path.Combine(dir, n), Get(n));
    }
    sealed class View : IReadOnlyDictionary<string, byte[]>   // 只读视图：取值才读盘（发布打包 / 核验逐个取用即丢）
    {
        readonly Side s; public View(Side side) { s = side; }
        public byte[] this[string k] => s.Get(k) ?? throw new KeyNotFoundException(k);
        public IEnumerable<string> Keys => s.f.Keys;
        public IEnumerable<byte[]> Values => s.f.Keys.Select(s.Get);
        public int Count => s.f.Count;
        public bool ContainsKey(string k) => s.f.ContainsKey(k);
        public bool TryGetValue(string k, out byte[] v) { v = s.Get(k); return v != null; }
        public IEnumerator<KeyValuePair<string, byte[]>> GetEnumerator() { foreach (var k in s.f.Keys) yield return new(k, s.Get(k)); }
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }
}

/// <summary>键 → 源码文本（可为 null），文本以 UTF-8 存在 Build.Spill（同 Python 的 str 每字符 1 字节，且不常驻）；取值才读回解码</summary>
sealed class TextStore : IReadOnlyDictionary<string, string>
{
    readonly ConcurrentDictionary<string, (long, int)> f = new(StringComparer.Ordinal);   // 长度 -1 = null
    public string this[string k]
    {
        get { var e = f[k]; return e.Item2 < 0 ? null : Encoding.UTF8.GetString(Build.Spill.Read(e)); }
        set => f[k] = value == null ? (0, -1) : Build.Spill.Write(Encoding.UTF8.GetBytes(value));
    }
    public IEnumerable<string> Keys => f.Keys;
    public IEnumerable<string> Values => f.Keys.Select(k => this[k]);
    public int Count => f.Count;
    public bool ContainsKey(string k) => f.ContainsKey(k);
    public bool TryGetValue(string k, out string v) { if (f.ContainsKey(k)) { v = this[k]; return true; } v = null; return false; }
    public IEnumerator<KeyValuePair<string, string>> GetEnumerator() { foreach (var k in f.Keys) yield return new(k, this[k]); }
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}

/// <summary>出包进度（格式同 tools/progress.py：时刻\t阶段\t已完成\t总数，S2A_PROGRESS 指的文件，1 秒限频，最后一项必写）</summary>
sealed class Ticker : IDisposable
{
    readonly string stage, path; readonly int total; int done; long last;
    bool disposed;
    public Ticker(string stage, int total)
    {
        this.stage = stage; this.total = Math.Max(total, 0); path = Environment.GetEnvironmentVariable("S2A_PROGRESS");
        Write(true); PublishActivity(false);
    }
    public void Step(int n = 1) { int d = Interlocked.Add(ref done, n); Write(d >= total); }
    void Write(bool force)
    {
        if (string.IsNullOrEmpty(path) || total == 0) return;
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        lock (this)
        {
            if (disposed) return;
            if (!force && now - last < 1) return;
            last = now; File.AppendAllText(path, $"{now}\t{stage}\t{Math.Min(done, total)}\t{total}\n");
        }
    }
    void PublishActivity(bool ending)
    {
        if (string.IsNullOrEmpty(path) || Build.Jobs <= 0) return;
        lock (this)
        {
            // Two columns: old four-column readers ignore this optional activity record.
            // No timer runs in the build tree: periodic observation belongs to the parent worker,
            // so an idle/deadlocked child cannot keep nostall alive by writing its own heartbeat.
            var data = new { schema = 1, pid = Environment.ProcessId, stage, target = Build.Jobs,
                pool = Build.Jobs * 2, state = ending ? "ended" : "active" };
            try { File.AppendAllText(path, "#dsh_activity\t" + System.Text.Json.JsonSerializer.Serialize(data) + "\n"); }
            catch (IOException) { }   // Optional telemetry must not change compilation results.
            catch (UnauthorizedAccessException) { }
        }
    }
    public void Dispose()
    {
        lock (this) { if (disposed) return; disposed = true; PublishActivity(true); }
    }
}

sealed class CompileError : Exception { public CompileError(string m) : base(m) { } }

/// <summary>Metal 编译（同原 dmsh_mtlcache.py：按「编译约定 + 编译器身份 + MSL」内容寻址；并发闸限同时在编的路数；编不过先查环境、再重试一次）</summary>
static class Metal
{
    static readonly Dictionary<string, (string[] Cmd, string Sdk, byte[] Ident)> T = new();
    static string Work; static SemaphoreSlim Gate;
    static readonly ConcurrentDictionary<string, long> St = new();
    static readonly ConcurrentBag<(double S, string Target, int Bytes)> Times = new();
    public static void Init((string[] Cmd, string Rec, string Sdk)? mac, (string[] Cmd, string Rec, string Sdk)? ios, string work, int jobs)
    {
        Work = work; Gate = new SemaphoreSlim(jobs);
        foreach (var (name, t) in new[] { ("mac", mac), ("ios", ios) })
            if (t is { } v) { T[name] = (v.Cmd, v.Sdk, SHA256.HashData(Encoding.UTF8.GetBytes("dshb-mtl 2\0" + v.Rec + "\0" + CompilerId(v.Sdk)))); BuildPch(name, v.Cmd); }
    }
    // 预编头（11-06 出包速度线，Spare-host 实测）：每份 MSL 的描述符结构体里有贴图成员，前端每个编译单元都要现实例化一遍 metal 标准库的贴图类模板
    //   （texture2d / texture2d_array / texturecube … 每种 19–38 毫秒，194 KB 那支前端 163 毫秒里占 111）；模块缓存只存声明、不存实例化。
    //   出库开头每个目标用同一套编译约定建一份预编头（下面这些类型先实例化好，约 1 秒），之后每次编译 -include-pch 复用：
    //   Spare-host 30 支 4.13 → 1.67 秒，产物 .air 逐字节相同（本机另核 600 支）——所以缓存键（Ident）不带它，换不换预编头都命中同一份库。
    //   预编头绑定模块缓存目录（clang 按编译选项哈希定缓存路径，建与用必须同一个 -fmodules-cache-path）。建不出（如编译器不认）就不带、照旧编；
    //   带预编头编不过的那支第二次不带重编（同原「编不过重试一次」），不把预编头的问题算成着色器编不过。S2A_METAL_PCH=0 关掉（对照用）
    static readonly ConcurrentDictionary<string, string[]> Pch = new();
    // 熔断：同一次出库里某个目标带预编头编不过（去掉预编头重编成了）已有 PchTrip 支、带预编头编成的一支都没有 = 这台机器的预编头整体用不了，
    //   本次出库对这个目标关掉预编头，不再每支编两遍（11-09 外部分析报「Windows 上预编头完全失效」：Windows 出包机实测 430 支 0 支重编、未复现，熔断作安全阀）
    const int PchTrip = 8;
    const string PchPrelude = "#include <metal_stdlib>\n#include <simd/simd.h>\nusing namespace metal;\n"
        + "struct s2a_pch_force {\n"   // 类型取自出库 MSL 实际出现的拼法（马车8 / 旷野之息 1.4 万份统计），多放的只在建预编头时花时间
        + "  texture2d<float> a; texture2d_array<float> b; texturecube<float> c; texturecube_array<float> d; texture3d<float> e;\n"
        + "  depth2d<float> f; depth2d_array<float> g; depthcube<float> h; depthcube_array<float> i;\n"
        + "  texture2d<uint> j; texture2d<int> k; texture2d_ms<float> l; texture_buffer<float> m;\n"
        + "  texture2d<float, access::write> n; texture2d<float, access::read> o; texture2d<float, access::read_write> p;\n"
        // 11-06：spvDepthCast（深度采样）在模板函数里把贴图当 device 一致性实例化（memory_coherence_device，与上面缺省的 threadgroup 是另一份实例），
        //   每支用到的批每次编译重做 31–70 毫秒；Spare-host 喷射战士3 真实合批 6 批编译 1833 → 1528 毫秒，产物 .air 逐字节相同
        + "  texture2d<float, access::sample, memory_coherence::memory_coherence_device> q; texture2d_array<float, access::sample, memory_coherence::memory_coherence_device> r;\n"
        + "  texturecube<float, access::sample, memory_coherence::memory_coherence_device> s; texturecube_array<float, access::sample, memory_coherence::memory_coherence_device> t;\n"
        + "  texture3d<float, access::sample, memory_coherence::memory_coherence_device> u; depth2d<float, access::sample, memory_coherence::memory_coherence_device> v;\n"
        + "  depth2d_array<float, access::sample, memory_coherence::memory_coherence_device> w; depthcube<float, access::sample, memory_coherence::memory_coherence_device> x;\n"
        + "  depthcube_array<float, access::sample, memory_coherence::memory_coherence_device> y;\n};\n";
    static void BuildPch(string name, string[] cmd)
    {
        if (Environment.GetEnvironmentVariable("S2A_METAL_PCH") == "0") return;
        var sw = Stopwatch.StartNew();
        var dir = Path.Combine(Work, "pch-" + name); Directory.CreateDirectory(dir);
        string h = Path.Combine(dir, "s2a_pre.h"), pch = Path.Combine(dir, "s2a_pre.pch"), mc = "-fmodules-cache-path=" + Path.Combine(dir, "mcache");
        File.WriteAllText(h, PchPrelude);
        var (rc, err) = Exec(Native(cmd).Where(a => a != "-c").Concat(new[] { mc, "-x", "metal-header", h, "-o", pch }).ToArray());
        if (rc == 0 && File.Exists(pch)) { Pch[name] = new[] { mc, "-include-pch", pch }; Note($"[分段] {name} 预编头 {sw.Elapsed.TotalSeconds:F1} 秒"); }
        else Note($"🟡 {name} 预编头没建成（rc={rc}：{Trunc(CompilerWhy(err) ?? err, 200)}），本次不带预编头编");
    }
    static string Trunc(string s, int n) => s == null || s.Length <= n ? s : s[..n];
    static void Note(string s) { lock (Console.Out) { Console.Out.WriteLine(s); Console.Out.Flush(); } }   // 同 Build.Say
    // Windows（#1100 W6，11-04 Windows 出包线）：没有 xcrun，用苹果官方 Metal Developer Tools for Windows 的 metal.exe / metallib.exe（玩家自己用 Apple ID 下载安装，
    //   许可不许随包分发，见 docs/研究/Windows_Metal编译器核验.md）。目录缺省 C:\Program Files\Metal Developer Tools\bin，S2A_METAL_BIN 可改。
    //   参数照 Mac 同一份编译约定（-c -w -fmetal-math-mode=relaxed -fpreserve-invariance + 平台最低版本号，#788 核过 730 支全过），只换掉 xcrun -sdk <平台> 前缀；
    //   编译器身份按 Windows 工具的版本串算（缓存与 Mac 天然分开）；反射里的 chain_metal 照旧记规范配方，不按平台变（维护者 11-03 #788：编译器版本只 note、不进链号）
    internal static readonly string WinBin = OperatingSystem.IsWindows()
        ? (Environment.GetEnvironmentVariable("S2A_METAL_BIN") is { Length: > 0 } b ? b : @"C:\Program Files\Metal Developer Tools\bin") : null;
    /// <summary>xcrun -sdk &lt;sdk&gt; &lt;工具&gt; 参数… → 本机实际命令行（Windows 换成 &lt;WinBin&gt;\&lt;工具&gt;.exe 参数…）</summary>
    internal static string[] Tool(string sdk, string tool, params string[] args) =>
        WinBin == null ? new[] { "xcrun", "-sdk", sdk, tool }.Concat(args).ToArray() : new[] { Path.Combine(WinBin, tool + ".exe") }.Concat(args).ToArray();
    /// <summary>编译约定数组（xcrun -sdk &lt;sdk&gt; metal 参数…）→ 本机实际命令行</summary>
    internal static string[] Native(string[] cmd) => WinBin == null ? cmd : Tool(cmd[2], cmd[3], cmd[4..]);
    static string Run(params string[] a)   // → 标准输出
    {
        var psi = new ProcessStartInfo(a[0]) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var x in a[1..]) psi.ArgumentList.Add(x);
        using var p = Process.Start(psi); var e = p.StandardError.ReadToEndAsync(); var o = p.StandardOutput.ReadToEnd(); p.WaitForExit(); _ = e.Result; p.StandardOutput.Dispose(); p.StandardError.Dispose(); return o;
    }
    static string CompilerId(string sdk)
    {
        var tools = Run(Tool(sdk, "metal", "--version")) + Run(Tool(sdk, "metallib", "--version"));
        if (WinBin != null) return "windows " + sdk + "\n" + System.Text.RegularExpressions.Regex.Replace(tools, @"(?m)^InstalledDir:.*\n?", "");   // Windows 没有 SDK 版本可读：平台名 + 两个工具的版本串
        return System.Text.RegularExpressions.Regex.Replace(tools, @"(?m)^InstalledDir:.*\n?", "") + Run("xcrun", "-sdk", sdk, "--show-sdk-version") + Run("xcrun", "-sdk", sdk, "--show-sdk-build-version");
    }
    // name：源文件名（不带 .metal），按它编。有全局构造函数的源码，库里嵌着文件名（_GLOBAL__sub_I_<name>.metal）：这种库按「名 + 源码」缓存，
    //   其余（库里没有文件名）按源码缓存、同源的键共用；查时先源码键、再名键
    public static byte[] Compile(string target, string msl, string name) => Compile(target, msl, name, out _);
    /// <summary>编译身份（编译约定 + 编译器版本）的十六进制：批成员索引按它分键，换编译器不拿旧库</summary>
    public static string IdentHex(string target) => Convert.ToHexString(T[target].Ident).ToLowerInvariant()[..16];
    /// <summary>取缓存仓里一份库（批成员索引给的键）；没有 → null。命中记作复用</summary>
    public static byte[] Cached(string target, string key)
    {
        var e = key != null && key.StartsWith("mtl/" + target + "/", StringComparison.Ordinal) ? Store.Get(key) : null;
        if (e == null || !e.TryGetValue("lib", out var lib)) return null;
        St.AddOrUpdate(target + " reused", 1, (_, v) => v + 1); return lib;
    }
    // key：这份库在缓存仓里的键（命中或新写入的那个）
    public static byte[] Compile(string target, string msl, string name, out string key)
    {
        var (cmd, sdk, ident) = T[target];
        var src = Encoding.UTF8.GetBytes(msl);
        string Key(byte[] mid)   // = sha256(ident ‖ mid ‖ src)：分段喂，不拼整块（原 Concat().ToArray() 逐字节枚举再复制整段 MSL，每次编译两遍、都进大对象堆）
        {
            using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); h.AppendData(ident); h.AppendData(mid); h.AppendData(src);
            return "mtl/" + target + "/" + Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant();
        }
        var fname = Encoding.UTF8.GetBytes(name + ".metal");
        string kSrc = Key(new byte[] { 0 }), kNamed = null;
        key = kSrc; var hit = Store.Get(kSrc);
        if (hit == null) { kNamed = Key(Encoding.UTF8.GetBytes("\0" + name + "\0")); key = kNamed; hit = Store.Get(kNamed); }
        if (hit != null) { St.AddOrUpdate(target + " reused", 1, (_, v) => v + 1); return hit["lib"]; }
        var dir = Path.Combine(Work, $"{target}-{Guid.NewGuid():N}"); Directory.CreateDirectory(dir);
        string m = Path.Combine(dir, name + ".metal"), air = Path.Combine(dir, name + ".air"), lib = Path.Combine(dir, name + ".metallib");
        File.WriteAllBytes(m, src);
        Gate.Wait();
        var sw = Stopwatch.StartNew();
        bool withPch = false;
        try
        {
            for (int attempt = 1; ; attempt++)
            {
                var pre = attempt == 1 && Pch.TryGetValue(target, out var p) ? p : Array.Empty<string>();   // 第二次不带预编头（见 BuildPch 注）
                if (attempt == 1) withPch = pre.Length > 0;
                var (rc, err) = Exec(Native(cmd).Concat(pre).Concat(new[] { m, "-o", air }).ToArray());
                if (rc == 0) (rc, err) = Exec(Tool(sdk, "metallib", air, "-o", lib));
                if (rc == 0)
                {
                    if (attempt == 1 && withPch) St.AddOrUpdate(target + " pch ok", 1, (_, v) => v + 1);
                    if (attempt == 2) St.AddOrUpdate(target + " retried", 1, (_, v) => v + 1);
                    if (attempt == 2 && withPch && St.AddOrUpdate(target + " pch failed", 1, (_, v) => v + 1) >= PchTrip && St.GetValueOrDefault(target + " pch ok") == 0 && Pch.TryRemove(target, out _))
                        Note($"🟡 {target} 预编头连续 {PchTrip} 支带着编不过、去掉才编成，一支带着编成的都没有：本次出库不再带预编头（免得每支编两遍）");
                    break;
                }
                var bad = EnvProblem() ?? DiskFull(err) ?? OpenFail(err);
                if (bad != null) throw new InvalidOperationException($"Metal 编译环境坏了（{bad}），不是这支着色器编不过");
                if (attempt == 2)
                {
                    // 逐支编不过只记这一支，不在这里整次停（审计 P1-150：原先「连败 64 支、编成 0」就停，热缓存上复用几千支照样被停掉整份直连库）。
                    //   编译器整体用不了由编库收尾 Tally 的「编成 + 复用 = 0」判；环境类（盘满 / 打不开文件 / 工作区没了）上面已整次停
                    St.AddOrUpdate(target + " failed", 1, (_, v) => v + 1);
                    throw new CompileError(CompilerWhy(err) ?? $"exit status {rc}: {err.Trim()} (Command '{string.Join(' ', cmd)} {m} -o {air}')");   // 原话放前面：汇总只留前 160 字符，命令回显占满就看不到原因（#165）
                }   // 原话放前面：汇总只留前 160 字符，命令回显占满就看不到原因（#165）
            }
            var data = File.ReadAllBytes(lib);
            key = data.AsSpan().IndexOf(fname) >= 0 ? kNamed : kSrc;
            Store.Put(key, new Dictionary<string, byte[]> { ["lib"] = data });
            St.AddOrUpdate(target + " compiled", 1, (_, v) => v + 1); Times.Add((sw.Elapsed.TotalSeconds, target, src.Length));
            return data;
        }
        finally { Gate.Release(); try { Directory.Delete(dir, true); } catch { } }
    }
    // 编不过的一句（出库清单 / 普查「直连编不过」列读它，截 160 字）：编译器的 error 行，去掉临时目录路径只留「文件名:行:列: error: …」；没有 error 行回 null（用整串）。
    //   11-02：原先命令行在前，160 字被 xcrun 参数占满，究极4 315 支编不过一支原文都没留下
    internal static string CompilerWhy(string err)
    {
        var ls = (err ?? "").Split('\n').Select(l => l.Trim()).Where(l => l.Contains(" error: ", StringComparison.Ordinal))
            .Select(l => System.Text.RegularExpressions.Regex.Replace(l, @"^\S*/", "")).ToList();
        return ls.Count > 0 ? string.Join("; ", ls) : null;
    }
    static (int, string) Exec(string[] a)
    {
        // 只接 stderr、同步读：metal / metallib 成功时 stdout 无输出；原先 stdout 同步读 + stderr 异步读，异步完成要池线程，编译线程又都占着池线程 → 饥饿
        //   macOS 走 posix_spawn（Spawn）：Process.Start 在本进程里 fork，fork 期间 macOS 分配器（xzone）锁住全进程的 malloc，翻译线程全停在 _xzm_fork_lock_wait（11-02 sample 实证；
        //   本进程常驻约 5 GB，马车8 一局 1.4 万次 fork，Spare-host 翻译段 CPU 只用到 3.1 / 8 核）
        if (OperatingSystem.IsMacOS()) return Spawn.Run(a);
        var psi = new ProcessStartInfo(a[0]) { RedirectStandardError = true, UseShellExecute = false };
        string[] args = a[1..];
        if (WinBin != null && args.Any(WinUnsafe)) { args = WinRelative(args, Work); psi.WorkingDirectory = Work; }
        foreach (var x in args) psi.ArgumentList.Add(x);
        using var p = Process.Start(psi);
        var err = p.StandardError.ReadToEnd(); p.StandardError.Dispose(); p.WaitForExit();   // 显式关管道：Process.Dispose 不关重定向的流，每次漏一个描述符等 GC（实测 1000 次 25→1059），mk8d 编到上限 Too many open files
        return (p.ExitCode, err);
    }
    // 苹果官方 Windows 版 metal.exe / metallib.exe 会把参数里的空格再拆开，引号挡不住（#257：用户名带空格「C:\Users\<带空格的用户名>」时工作区在
    //   AppData 下，每支都报 no such file 'C:\Users\<用户名前半>'，一个键都没出；11-09 Windows 出包机实测按参数整体传、源文件 / 输出 / 模块缓存 / metallib 输出
    //   四种带空格全失败，工作目录设成带空格的目录、参数只写相对路径则全过）。所以带空格的路径参数（含 -xxx=<路径>）改成相对工作区 Work 的写法、
    //   工作目录设为 Work；我方建的段名（<目标>-<guid>、pch-<目标>）不带空格。相对之后仍带空格（文件不在工作区下）就直说，不交给编译器去拆
    //   11-09 外部报告（中文用户名「C:\Users\<中文>」，S2Arm 0.1.7）：短入口 %LOCALAPPDATA%\S2A\j\<短号> 把中文带进路径，metallib.exe 用 ANSI 代码页开文件，
    //   「LLVM ERROR: Error opening …（没有此 Unicode 字符可以映射到的字符）」，一支 metallib 都没出。Windows 出包机（代码页 936）实测：中文绝对路径 metal 过、
    //   metallib 失败；经中文路径下的联接同样失败；工作目录设成中文 / 联接目录、参数只写相对路径则两者都过。所以非 ASCII 与空格同样处理
    internal static bool WinUnsafe(string x) => x.Any(ch => ch == ' ' || ch > 127);
    internal static string[] WinRelative(string[] args, string cwd) => args.Select(x =>
    {
        if (!WinUnsafe(x)) return x;
        int eq = x.StartsWith('-') ? x.IndexOf('=') : -1;
        string head = eq >= 0 ? x[..(eq + 1)] : "", path = eq >= 0 ? x[(eq + 1)..] : x;
        if (!Path.IsPathFullyQualified(path)) return x;
        string rel = Path.GetRelativePath(cwd, path);
        if (WinUnsafe(rel) || Path.IsPathRooted(rel))
            throw new InvalidOperationException($"Metal 编译器（Windows 版）不认带空格或非 ASCII 字符的路径，而 {path} 不在出库工作区 {cwd} 下，没法改成相对路径");
        return head + rel;
    }).ToArray();
    // 盘写满（#265）：编译器写 .air / .metallib 时报 ENOSPC。原先按「这一支编不过、其余照出」记，写满后每支都失败、出一份残缺的库还退 0（失败当成功）；
    //   归进上面「编译环境坏了」整次停，原话带上 No space left on device，出包作业的错误分类（pack/jobs/errors.py）据此报 disk_full
    static readonly System.Text.RegularExpressions.Regex NoSpace = new(@"No space left on device|\bENOSPC\b|There is not enough space on the disk|\bDisk full\b", System.Text.RegularExpressions.RegexOptions.Compiled);
    internal static string DiskFull(string err) => err != null && NoSpace.IsMatch(err) ? "磁盘写满：No space left on device" : null;
    // 编译器打不开自己的输入 / 输出（LLVM ERROR: Error opening …）是路径 / 权限问题，换哪支着色器都一样，归「编译环境坏了」整次停（11-09 外部报告：
    //   原先逐支记编不过，1364 支全败照退 0，出了一个没有着色器库的包）
    internal static string OpenFail(string err) => err != null && err.Contains("LLVM ERROR: Error opening", StringComparison.Ordinal)
        ? "编译器打不开文件：" + Trunc(err.Trim().Split('\n')[0], 200) : null;
    /// <summary>单测入口（dsh_batch --metal-compile &lt;工作目录&gt; &lt;源文件&gt;）：按 Mac 编译约定走一次真实的 Init + Compile + 编库收尾 Tally → 0 编成 / 1 有编不过的 / 2 整次停（编译环境坏了，或一份库都没出）</summary>
    internal static int CompileCli(string[] a)
    {
        Store.Open(Path.Combine(a[0], "store")); Init((Build.MacMetal, Build.MacRecord, "macosx"), null, a[0], 1);
        try
        {
            string last = null;
            foreach (var src in a[1..])
                try { Compile("mac", File.ReadAllText(src), Path.GetFileNameWithoutExtension(src)); } catch (CompileError e) { last = e.Message; }
            Console.WriteLine(last == null ? "ok" : "compile error: " + last); Console.WriteLine(Summary());
            if (Tally(_ => { }) is { } none) { Console.WriteLine("stop: " + none); return 2; }   // 同出库：编库收尾判「编成 + 复用 = 0」整次停
            return last == null ? 0 : 1;
        }
        catch (InvalidOperationException e) { Console.WriteLine("stop: " + e.Message); return 2; }
    }
    static string EnvProblem()
    {
        try { _ = Directory.GetCurrentDirectory(); } catch (Exception e) { return $"当前工作目录已不存在（{e.Message}）"; }
        // 不按整卷剩余判「环境坏了」（审计 #1417 P1-78）：同一卷上别的出库把剩余压到 1 GB 以下时，本款任意一支编不过就整单停；
        //   盘真写满时编译器自己报写失败，由 Compile 里的 DiskFull 认出、整次停（#265）
        return Directory.Exists(Work) ? null : $"工作区 {Work} 不在";
    }
    /// <summary>编库阶段收尾（编批库后）：每个目标「成功 N / 复用 / 失败 M」一行；某个目标有编不过的、却一份库都没出（编成 + 复用 = 0）→ 回红行（整次失败），否则 null</summary>
    public static string Tally(Action<string> say)
    {
        string bad = null;
        foreach (var t in T.Keys)
        {
            long ok = St.GetValueOrDefault(t + " compiled"), re = St.GetValueOrDefault(t + " reused"), no = St.GetValueOrDefault(t + " failed");
            say($"[直连库] {t} Metal 库：编成 {ok} / 复用 {re} / 编不过 {no}");
            if (no > 0 && ok + re == 0) bad ??= $"[RED] {t} Metal 库一份都没出（编不过 {no} 支、编成 0、复用 0）：编译器在这台机器上用不了，不发布没有着色器库的包";
        }
        return bad;
    }
    public static string Summary()
    {
        var parts = T.Keys.Select(t => $"{t} {St.GetValueOrDefault(t + " reused")} reused, {St.GetValueOrDefault(t + " compiled")} compiled, {St.GetValueOrDefault(t + " failed")} failed" + (St.GetValueOrDefault(t + " retried") > 0 ? $", {St[t + " retried"]} retried" : ""));
        var ts = Times.Select(x => x.S).OrderBy(x => x).ToList();
        var dist = ts.Count == 0 ? "" : $"; compile seconds: {ts.Count} compiles, sum {ts.Sum():F0} s, p50 {ts[ts.Count / 2]:F1} / p90 {ts[(int)(ts.Count * 0.9)]:F1} / max {ts[^1]:F1}";
        return "Metal cache: " + string.Join("; ", parts) + dist;
    }
}

/// <summary>内容寻址仓（翻译产物 xl/、Metal 库 mtl/）：一条一个文件，按摘要前两位分目录，写入先临时文件再改名；整份出库收尾只留本次用到的（同原 dmsh_store compact）</summary>
static class Store
{
    static string Root; static readonly ConcurrentDictionary<string, byte> Used = new();
    public static void Open(string root) { Root = root; Directory.CreateDirectory(root); }
    static string PathOf(string key) { var h = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant(); return Path.Combine(Root, h[..2], h + ".e"); }
    public static bool Exists(string key) { var p = PathOf(key); if (!File.Exists(p)) return false; Used[p] = 0; return true; }
    public static Dictionary<string, byte[]> Get(string key)
    {
        var p = PathOf(key); Used[p] = 0;
        byte[] d; try { d = File.ReadAllBytes(p); } catch (IOException) { return null; } catch (UnauthorizedAccessException) { return null; }
        try
        {
            // 落盘格式 DSZ1 + zlib(DSE1 整串，含末尾校验)：不是 DSZ1 的（旧未压缩条目）当没有、重新翻译（11-08 维护者：不留兼容读法）
            if (d.Length < 4 || Encoding.ASCII.GetString(d, 0, 4) != "DSZ1") return null;
            using (var zs = new ZLibStream(new MemoryStream(d, 4, d.Length - 4), CompressionMode.Decompress)) using (var ms = new MemoryStream()) { zs.CopyTo(ms); d = ms.ToArray(); }
            var o = new Dictionary<string, byte[]>(StringComparer.Ordinal); int i = 0;
            int Int() { int v = BitConverter.ToInt32(d, i); i += 4; return v; }
            var magic = Encoding.ASCII.GetString(d, 0, 4); i = 4; if (magic != "DSE1") return null;
            int n = Int();
            for (int k = 0; k < n; k++) { int nl = Int(); var name = Encoding.UTF8.GetString(d, i, nl); i += nl; int bl = Int(); o[name] = d[i..(i + bl)]; i += bl; }
            var want = Encoding.UTF8.GetString(d, i, d.Length - i - 32); i = d.Length - 32;
            if (want != key || !SHA256.HashData(d.AsSpan(0, d.Length - 32)).SequenceEqual(d[(d.Length - 32)..])) return null;   // 键核对 + 整条校验：坏了当没有
            return o;
        }
        catch { return null; }
    }
    public static void Put(string key, Dictionary<string, byte[]> files)
    {
        var p = PathOf(key); Used[p] = 0; Directory.CreateDirectory(Path.GetDirectoryName(p));
        var tmp = p + $".tmp{Environment.ProcessId}.{Environment.CurrentManagedThreadId}";
        // 边写边算校验（同一串字节：DSE1、项数、逐项 名长 名 字节长 字节、键，末尾 32 字节 sha256）：原先拼进 MemoryStream 再 ToArray 整块复制，大库每次多一份大对象
        // 11-08 整条压缩（维护者）：文件 = 「DSZ1」+ zlib(上面那串)。巫师3 直连缓存 125.5 GB 里约 89% 是 MSL 明文（_b / _b.plain / _bv 三种变体各存整份，只差几百字节），
        //   抽样两条实测 deflate 压到 6% / 13%；只出包机读写这个仓（dsh_batch），设备端 App 不含本类
        using (var fs = File.Create(tmp))
        using (var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        {
            fs.Write("DSZ1"u8);
            using var zs = new ZLibStream(fs, CompressionLevel.Optimal, leaveOpen: true);
            void W(ReadOnlySpan<byte> b) { zs.Write(b); h.AppendData(b); }
            void I(int v) { Span<byte> b = stackalloc byte[4]; BitConverter.TryWriteBytes(b, v); W(b); }
            W("DSE1"u8); I(files.Count);
            foreach (var (n, b) in files.OrderBy(x => x.Key, StringComparer.Ordinal)) { var nb = Encoding.UTF8.GetBytes(n); I(nb.Length); W(nb); I(b.Length); W(b); }
            W(Encoding.UTF8.GetBytes(key));
            zs.Write(h.GetHashAndReset());
        }
        // 11-05 Windows 出包机极品飞车：同仓并发出包（多单 / 本单多线程编到同一键），Windows 覆盖改名撞上目标正被别人读或替换 → UnauthorizedAccessException，整单出库失败。
        //   仓按键寻址：目标已有一条键对、校验过的条目就是别人先写成了，丢掉自己这份；还没有就稍等重试，三次仍不行照抛（真权限 / 盘问题不吞）
        for (int attempt = 1; ; attempt++)
        {
            try { File.Move(tmp, p, true); return; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                if (Get(key) != null) { try { File.Delete(tmp); } catch { } return; }
                if (attempt == 3) { try { File.Delete(tmp); } catch { } throw; }
                System.Threading.Thread.Sleep(200 * attempt);
            }
        }
    }
    // 整理：只收旧 Python 仓、给本次用到的条目刷新修改时间（早于一天才刷，命中不改写条目），不删任何条目——淘汰按容量预算 LRU 另做：
    //   开发机 tools/gc.sh → tools/direct_cache_lru.py（cache/direct 下全部款合计超 S2A_DIRECT_CACHE_BUDGET_GB 才按修改时间删最久没用的，在跑的款不动），
    //   玩家机 pack/jobs/cache_retention.py（盘紧才淘汰冷条目）。11-02 出包线：原先「本次没用到的全删」，同款在两棵树 / 两个提交 / iOS 与 Mac 间交替出包时互删
    //   （马力欧派对 16:40 一单删 66359 条）；维护者「存储换时间」：放 2T、超预算才按最久没用淘汰
    public static (int Kept, int Dropped) Compact()
    {
        int kept = 0, dropped = 0;
        var now = DateTime.UtcNow;
        // 旧 Python 仓（dmsh_store.py）留在同一仓根的 256 个分片 NN.pack 与 .inuse：新仓不读，不删就永远占盘（全部款约 65 GB），首次整理时收掉
        foreach (var f in Directory.EnumerateFiles(Root))
        {
            var n = Path.GetFileName(f);
            if (n == ".inuse" || System.Text.RegularExpressions.Regex.IsMatch(n, @"\A[0-9a-f]{2}\.pack\z")) { try { File.Delete(f); dropped++; } catch { } }
        }
        foreach (var f in Directory.EnumerateFiles(Root, "*.e", SearchOption.AllDirectories))
        {
            kept++;
            if (Used.ContainsKey(f)) try { if (File.GetLastWriteTimeUtc(f) < now.AddDays(-1)) File.SetLastWriteTimeUtc(f, now); } catch { }   // LRU 的「最近用过」：早于一天才刷，命中不改写条目（t_dmsh_reuse ②）
        }
        return (kept, dropped);
    }
}

/// <summary>macOS 上不 fork 起子进程（posix_spawnp）：stdin / stdout 照继承、stderr 接回读完，其余描述符一律不带进子进程（CLOEXEC_DEFAULT），
/// 信号掩码清空、处理方式全回缺省，环境取本进程 .NET 侧的一份——与 Process.Start（只重定向 stderr）给子进程的东西一致。→ (退出码, stderr)</summary>
static unsafe class Spawn
{
    [DllImport("libc", SetLastError = true)] static extern int posix_spawnp(out int pid, string file, IntPtr* fa, IntPtr* attr, IntPtr* argv, IntPtr* envp);
    [DllImport("libc")] static extern int posix_spawn_file_actions_init(IntPtr* fa);
    [DllImport("libc")] static extern int posix_spawn_file_actions_destroy(IntPtr* fa);
    [DllImport("libc")] static extern int posix_spawn_file_actions_adddup2(IntPtr* fa, int fd, int newfd);
    [DllImport("libc")] static extern int posix_spawn_file_actions_addinherit_np(IntPtr* fa, int fd);
    [DllImport("libc")] static extern int posix_spawnattr_init(IntPtr* attr);
    [DllImport("libc")] static extern int posix_spawnattr_destroy(IntPtr* attr);
    [DllImport("libc")] static extern int posix_spawnattr_setflags(IntPtr* attr, short flags);
    [DllImport("libc")] static extern int posix_spawnattr_setsigmask(IntPtr* attr, uint* mask);
    [DllImport("libc")] static extern int posix_spawnattr_setsigdefault(IntPtr* attr, uint* sigs);
    [DllImport("libc", SetLastError = true)] static extern int pipe(int* fds);
    [DllImport("libc")] static extern int close(int fd);
    [DllImport("libc", SetLastError = true)] static extern int waitpid(int pid, int* status, int options);
    const short SETSIGDEF = 0x04, SETSIGMASK = 0x08, CLOEXEC_DEFAULT = 0x4000;   // <spawn.h>（CLOEXEC_DEFAULT 是 Apple 扩展）
    const int EINTR = 4;
    static readonly Lazy<IntPtr[]> Env = new(() =>   // 出库期间不改环境（DMSH_BF 在 Init 前设好）：只拼一次
    {
        var l = new List<IntPtr>();
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) l.Add(Marshal.StringToCoTaskMemUTF8($"{e.Key}={e.Value}"));
        l.Add(IntPtr.Zero); return l.ToArray();
    });
    public static (int, string) Run(string[] a)
    {
        var argv = new IntPtr[a.Length + 1];
        for (int i = 0; i < a.Length; i++) argv[i] = Marshal.StringToCoTaskMemUTF8(a[i]);
        int* fds = stackalloc int[2]; IntPtr fa, attr; int pid, rc;
        if (pipe(fds) != 0) throw new IOException($"pipe 失败（errno {Marshal.GetLastPInvokeError()}）");
        posix_spawn_file_actions_init(&fa); posix_spawnattr_init(&attr);
        try
        {
            posix_spawn_file_actions_addinherit_np(&fa, 0); posix_spawn_file_actions_addinherit_np(&fa, 1); posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
            uint none = 0, all = ~((1u << (9 - 1)) | (1u << (17 - 1)));   // 除 SIGKILL / SIGSTOP 外全回缺省
            posix_spawnattr_setsigmask(&attr, &none); posix_spawnattr_setsigdefault(&attr, &all);
            posix_spawnattr_setflags(&attr, (short)(SETSIGDEF | SETSIGMASK | CLOEXEC_DEFAULT));
            fixed (IntPtr* av = argv, ev = Env.Value) rc = posix_spawnp(out pid, a[0], &fa, &attr, av, ev);
        }
        finally { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr); close(fds[1]); foreach (var x in argv) Marshal.FreeCoTaskMem(x); }
        if (rc != 0) { close(fds[0]); throw new System.ComponentModel.Win32Exception(rc, $"posix_spawnp {a[0]} 失败（errno {rc}）"); }
        string err;
        using (var r = new StreamReader(new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle((IntPtr)fds[0], true), FileAccess.Read, 1), Encoding.UTF8)) err = r.ReadToEnd();
        int st;
        while (waitpid(pid, &st, 0) < 0) if (Marshal.GetLastPInvokeError() != EINTR) throw new IOException($"waitpid {pid} 失败（errno {Marshal.GetLastPInvokeError()}）");
        return ((st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f), err);
    }
}

/// <summary>键 → 源码文本的只读视图：底下存 UTF-8 字节，每次取值才解码、不留文本（编批库切批用，11-02 出包内存）</summary>
sealed class TextView : IReadOnlyDictionary<string, string>
{
    readonly List<string> keys; readonly HashSet<string> has; readonly Func<string, byte[]> get;
    public TextView(List<string> keys, Func<string, byte[]> bytesOf) { this.keys = keys; has = new(keys, StringComparer.Ordinal); get = bytesOf; }
    public string this[string k] => has.Contains(k) ? Encoding.UTF8.GetString(get(k)) : throw new KeyNotFoundException(k);
    public IEnumerable<string> Keys => keys;
    public IEnumerable<string> Values => keys.Select(k => this[k]);
    public int Count => keys.Count;
    public bool ContainsKey(string k) => has.Contains(k);
    public bool TryGetValue(string k, out string v) { if (has.Contains(k)) { v = this[k]; return true; } v = null; return false; }
    public IEnumerator<KeyValuePair<string, string>> GetEnumerator() { foreach (var k in keys) yield return new(k, this[k]); }
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}
