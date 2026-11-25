// 出库链移进 C#（11-01 出包线）：Unity 模块——编批库的纯字符串部分，逐字节照搬 translator/dmsh_build.py 与 dmsh_ushare.py：
//   unity_src（拼批源码）、dmsh_ushare.share（main0_u 共用 main0 函数体）、unity_flush 里的 dg / sig / 同源合并 / 切批 / 批名 u<摘要> / 函数前缀 s<摘要>_ / 批记忆键 bid、
//   UNITY_FP 的构成、cut_batches（影子输入库按源码大小封顶）、vin_plan 的切批、bid 与编译顺序。编译、缓存、Metal 调用不在这里（Build.cs）。
// Python 语义差异的处理（逐条核过，见 PyRe）：
//   \s → Python str.isspace 的字符集（比 .NET 多 \x1c-\x1f）；\w → [\p{L}\p{N}_]（Python str.isalnum + _：不含 Mn / Pc，含 Nl / No）；\b → 按这个 \w 写的零宽断言；
//   \d → \p{Nd}；re.M 的 ^ / $、re.S 的 .、非贪婪、findall / sub 的扫描与 .NET 相同（这几条正则都不会空匹配）。替换一律用 MatchEvaluator 拼字面串（不经 $ / \g<1>）。
//   str.strip() / str.split() 用 Python 的空白集；len() 数码点（不是 UTF-16 单元）；sorted 的字符串序按码点比（PyCmp）、排序一律稳定（LINQ OrderBy）；
//   .encode() 是严格 UTF-8；int(dg, 16) % UNITY 在 UNITY = 0 时与 Python 一样抛除零（DivideByZeroException ↔ ZeroDivisionError）。
// 用法（对拍入口）：dsh_batch --unity <产物目录> <UNITY> <热键清单文件 | -> <UNITY_FP 十六进制> [影子输入库每批上限 MB，缺省 3]
//   读目录里全部 <键>_b.metal（同 unity_flush 的 src_of）与 <键>_bv.metal（同 VIN_SRC），按编译顺序（编批库大的先、再影子输入批）输出：
//     B \t 批名 \t 成员摘要（逗号分隔） \t sha256(批源码) \t sha256(bid)        —— 编批库的一批（批名 u<首键摘要>）
//     V \t 文件名 v<首键摘要>_<键数> \t 成员摘要 \t sha256(批源码) \t sha256(bid) —— 影子输入库的一批
//     K \t 键 \t fn_lib \t fn_prefix                                           —— 每键（含同源键），按键排序
//     N \t main0_u shared \t 次数
//   出错（UNITY = 0 的除零、某批没有入口）同 Python 写 ERR 行
//   dsh_batch --unity fp <CODE_FP> <unity_src 版本> <dmsh_ushare.py 路径>：打印 UNITY_FP 十六进制
// 单测入口（graphics/tools/direct/tests/t_unity.py、t_dmsh_ushare.py、t_alpha_ms.py、t_color_round_fetch.py 经 translator/dsh_batch.py 调）：
//   dsh_batch --unity share <入 MSL> <出 MSL>：Share 一支（main0_u 共用 main0 函数体），写出结果；标准输出「shared 1」或「shared 0」
//   dsh_batch --unity src <出 MSL> <摘要> <MSL 文件> [<摘要> <MSL 文件> …]：Src 拼一批，写出批源码；标准输出「shared <键数>」。某键没有入口 → 标准输出 ERR 行、退出 1
//   dsh_batch --unity cut <UNITY> <上限字节>：标准输入每行「键 \t 摘要 \t 源码大小」，按 CutBatches（无热键）切；每批一行，键逗号分隔
//   dsh_batch --unity flush <入目录> <出目录> <缓存根> [-j N]：整份出库的编批库那一步（Build.UnityFlush，只出 Mac，真 xcrun metal，按内容的编译缓存放在缓存根）。
//     入目录每键 <键>_b.metal + <键>_b.json，可带 <键>_b.plain.metal（去掉额外入口的源码 = Build.Defer）、<键>_bv.metal（影子输入源码 = Build.VinSrc）；
//     产物（_b.json / _b.metal / _b.metallib / _bv.metallib / u<摘要>.metallib）写进出目录；标准输出照出库打印 [unity] 行，另加
//     FAILED \t 键 \t 原因首行（编不过的键，按键排序）、STAT \t 计数名 \t 值（Build.Stats，按名排序）、METAL \t Metal.Summary()
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

static class Unity
{
    // ================= Python 语义的小工具 =================
    static readonly UTF8Encoding Utf8 = new(false, true);   // 严格（Python .encode() / .decode() 遇坏字节抛错），不加也不吞 BOM

    /// <summary>Python str.isspace</summary>
    public static bool PyIsSpace(char c) =>
        (c >= '\t' && c <= '\r') || (c >= '\x1c' && c <= ' ') || c == '\x85' || c == '\xa0' || c == '\u1680' || (c >= '\u2000' && c <= '\u200a')
        || c == '\u2028' || c == '\u2029' || c == '\u202f' || c == '\u205f' || c == '\u3000';

    /// <summary>Python str.strip()</summary>
    public static string PyStrip(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && PyIsSpace(s[a])) a++;
        while (b > a && PyIsSpace(s[b - 1])) b--;
        return a == 0 && b == s.Length ? s : s.Substring(a, b - a);
    }

    /// <summary>Python str.split()（无参：按空白串切、丢空段）</summary>
    public static List<string> PySplit(string s)
    {
        var o = new List<string>(); int i = 0, n = s.Length;
        while (true)
        {
            while (i < n && PyIsSpace(s[i])) i++;
            if (i >= n) return o;
            int j = i; while (j < n && !PyIsSpace(s[j])) j++;
            o.Add(s.Substring(i, j - i)); i = j;
        }
    }

    /// <summary>Python len(str)：码点数</summary>
    public static long PyLen(string s)
    {
        long n = s.Length;
        for (int i = 0; i + 1 < s.Length; i++) if (char.IsHighSurrogate(s[i]) && char.IsLowSurrogate(s[i + 1])) { n--; i++; }
        return n;
    }

    /// <summary>Python 的字符串序（按码点）：UTF-16 下代理对排在 U+E000–U+FFFF 之后</summary>
    public sealed class PyCmp : IComparer<string>
    {
        public static readonly PyCmp I = new();
        static int W(char c) => c < '\ud800' ? c : c >= '\ue000' ? c - 0x800 : c + 0x2000;
        public int Compare(string a, string b)
        {
            int n = Math.Min(a.Length, b.Length);
            for (int i = 0; i < n; i++) if (a[i] != b[i]) return W(a[i]) - W(b[i]);
            return a.Length - b.Length;
        }
    }

    const string PS = @"[\t\n\x0B\f\r\x1C-\x1F \x85\xA0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]";   // Python \s（str）
    const string PW = @"[\p{L}\p{N}_]";                                                                         // Python \w（str）
    const string PB = "(?:(?<=" + PW + ")(?!" + PW + ")|(?<!" + PW + ")(?=" + PW + "))";                        // Python \b

    /// <summary>Python re 源串 → .NET 正则：只换字符类外的 \s \w \b \d（这里的几条正则在 [...] 里不用它们，用到就抛错，免得悄悄换错）</summary>
    public static Regex PyRe(string pat, RegexOptions o = RegexOptions.None)
    {
        var sb = new StringBuilder(); bool cls = false;
        for (int i = 0; i < pat.Length; i++)
        {
            char c = pat[i];
            if (c == '\\' && i + 1 < pat.Length)
            {
                char d = pat[++i];
                if ("swbdSWBD".IndexOf(d) >= 0)
                {
                    if (cls || char.IsUpper(d)) throw new ArgumentException("PyRe：不支持的转义 \\" + d + "（字符类内或大写）：" + pat);
                    sb.Append(d == 's' ? PS : d == 'w' ? PW : d == 'b' ? PB : @"\p{Nd}");
                }
                else sb.Append(c).Append(d);
                continue;
            }
            if (c == '[' && !cls) { cls = true; sb.Append(c); if (i + 1 < pat.Length && pat[i + 1] == '^') sb.Append(pat[++i]); if (i + 1 < pat.Length && pat[i + 1] == ']') sb.Append(pat[++i]); continue; }
            if (c == ']' && cls) cls = false;
            sb.Append(c);
        }
        return new Regex(sb.ToString(), o | RegexOptions.CultureInvariant | RegexOptions.Compiled);
    }

    public static string Sha256Hex(string s) => Convert.ToHexStringLower(SHA256.HashData(Utf8.GetBytes(s)));
    public static string Sha256Hex(byte[] b) => Convert.ToHexStringLower(SHA256.HashData(b));

    // ================= dmsh_ushare.share =================
    static readonly Regex SigA = PyRe(@"^((?:\[\[[^\]]*\]\]\s*)*)fragment main0_out main0\((.*)\)\n\{\n", RegexOptions.Multiline);
    static readonly Regex SigU = PyRe(@"^((?:\[\[[^\]]*\]\]\s*)*)fragment main0_out_u main0_u\((.*)\)\n\{\n", RegexOptions.Multiline);
    static readonly Regex RetU = PyRe(@"return (main0_out_u\{[^;]*\});");
    static readonly Regex G = PyRe(@"\bs2a_g(\d+)\b");
    static readonly Regex Braces = PyRe(@"//[^\n]*|/\*.*?\*/|""(?:\\.|[^""\\])*""|'(?:\\.|[^'\\])*'|[{}]", RegexOptions.Singleline);
    static readonly Regex AttrStrip = PyRe(@"\s*\[\[[^\]]*\]\]");
    static readonly Regex AmpStar = PyRe(@"[&*]");
    static readonly Regex Attr = PyRe(@"\[\[[^\]]*\]\]\s*");
    static readonly Regex Word1 = PyRe(@"\A\w+\z");

    readonly record struct Entry(int Start, string Attrs, string Params, int BodyStart, int Close);

    static Entry? FindEntry(string msl, Regex sig)   // dmsh_ushare._entry
    {
        var m = sig.Match(msl);
        if (!m.Success) return null;
        int depth = 1, end = m.Index + m.Length;
        for (var t = Braces.Match(msl, end); t.Success; t = t.NextMatch())
        {
            if (t.Value == "{") depth++;
            else if (t.Value == "}")
            {
                depth--;
                if (depth == 0)
                    return string.CompareOrdinal(msl, t.Index, "}\n", 0, 2) == 0 && t.Index + 2 <= msl.Length
                        ? new Entry(m.Index, m.Groups[1].Value, m.Groups[2].Value, end, t.Index) : null;
            }
        }
        return null;
    }

    static List<string> SplitParams(string ps)   // dmsh_ushare._split
    {
        var o = new List<string>(); int d = 0; var cur = new StringBuilder();
        foreach (char ch in ps)
        {
            if ("<([".IndexOf(ch) >= 0) d++;
            else if (">)]".IndexOf(ch) >= 0) d--;
            if (ch == ',' && d == 0) { o.Add(PyStrip(cur.ToString())); cur.Clear(); }
            else cur.Append(ch);
        }
        string last = PyStrip(cur.ToString());
        if (last.Length > 0) o.Add(last);
        return o;
    }

    static string Renum(string t)   // dmsh_ushare._renum
    {
        var mp = new Dictionary<string, int>(StringComparer.Ordinal);
        return G.Replace(t, m =>
        {
            string k = m.Groups[1].Value;
            if (!mp.TryGetValue(k, out int v)) mp[k] = v = mp.Count;
            return "s2a_g" + v.ToString(CultureInfo.InvariantCulture);
        });
    }

    static string Attrs(string a, bool optnone) => string.Concat(Attr.Matches(a).Select(x => x.Value).Where(x => x.Contains("optnone", StringComparison.Ordinal) == optnone));

    /// <summary>dmsh_ushare.share：→ 送编译器的源码；shared = 是否共用了 main0 的函数体。参数串里有空段（Python p.split()[-1] 抛 IndexError）时同样抛错</summary>
    public static string Share(string msl, out bool shared)
    {
        shared = false;
        var a0 = FindEntry(msl, SigA); var u0 = FindEntry(msl, SigU);
        if (a0 is not Entry a || u0 is not Entry u || u.Start < a.Close) return msl;
        string body = msl.Substring(a.BodyStart, a.Close - a.BodyStart), ubody = msl.Substring(u.BodyStart, u.Close - u.BodyStart);
        var rets = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match m in RetU.Matches(ubody)) rets.Add(m.Groups[1].Value);
        if (rets.Count != 1 || a.Params != u.Params) return msl;
        string ret = rets.First();
        if (Renum(ubody) != Renum(body.Replace("return out;", "return " + ret + ";", StringComparison.Ordinal))) return msl;
        var ps = SplitParams(a.Params);
        var plain = ps.Select(p => PyStrip(AttrStrip.Replace(p, _ => ""))).ToList();
        var args = plain.Select(p => { var w = PySplit(p); if (w.Count == 0) throw new IndexOutOfRangeException("list index out of range"); return AmpStar.Replace(w[^1], _ => ""); }).ToList();
        if (!args.All(x => Word1.IsMatch(x))) return msl;
        string keep = Attrs(a.Attrs, true), entryAttr = Attrs(a.Attrs, false);
        string call = "main0_impl(" + string.Join(", ", args) + ")";
        string impl = keep + "static main0_out main0_impl(" + string.Join(", ", plain) + ")\n{\n" + body + "}\n\n";
        string thin = entryAttr + "fragment main0_out main0(" + a.Params + ")\n{\n    return " + call + ";\n}\n";
        string uAttr = Attrs(u.Attrs, false);
        string thinU = uAttr + "fragment main0_out_u main0_u(" + u.Params + ")\n{\n    main0_out out = " + call + ";\n    return " + ret + ";\n}\n";
        shared = true;
        return string.Concat(msl.Substring(0, a.Start), impl, thin, msl.Substring(a.Close + 2, u.Start - (a.Close + 2))) + thinU + msl.Substring(u.Close + 2);
    }

    // ================= unity_src =================
    // 全局行：头文件 / pragma / using，以及函数常量声明（同编号各键只能声明一次）：S2A_AT 那一行（FsAlphaMs / FsFout）、可编程混合开关 s2a_pb<n>_c 那一行（gal_colorround.c，#674）
    static readonly Regex UG = PyRe(@"^\s*(#\s*include\s*<[^>]+>|#\s*pragma\s+(?:METAL|clang)\b.*|using\s+namespace\s+metal\s*;|constant int S2A_AT \[\[function_constant\(100\)\]\];.*|constant bool s2a_pb\d_c \[\[function_constant\(11\d\)\]\];.*)\s*$", RegexOptions.Multiline);
    // 入口：fragment / vertex / kernel，以及任务 / 网格着色器的 [[object]] void / [[mesh]] void（MeshStage.cs 出的形式；11-05 时之笛第十二版批量合编不认，抛 no entry point）
    static readonly Regex UE = PyRe(@"^((?:\[\[[^\]]*\]\]\s*)*(?:fragment|vertex|kernel|\[\[(?:object|mesh)\]\])\s+.*?\b)(main0\w*)(\s*\()", RegexOptions.Multiline);
    static readonly Regex Define = PyRe(@"^\s*#\s*define\s+(\w+)", RegexOptions.Multiline);
    static readonly Regex SigRe = PyRe(@"^\s*(?:#\s*include\s*<[^>]+>|#\s*pragma\s+METAL\b.*)$", RegexOptions.Multiline);

    static int HeadRank(string l) => l.StartsWith("#pragma", StringComparison.Ordinal) ? 0 : l.StartsWith("#include", StringComparison.Ordinal) ? 1 : l.StartsWith("constant ", StringComparison.Ordinal) ? 3 : 2;

    /// <summary>unity_src：[(摘要, MSL)] → 一个翻译单元（各键进自己的 namespace n&lt;摘要&gt;、入口改名 s&lt;摘要&gt;_&lt;入口&gt;，全局行在顶部各一次）。
    /// shared：其中共用了 main0 函数体的键数（UNITY_STATS['main0_u shared']）。某键没有入口时抛 ArgumentException（消息同 Python ValueError）</summary>
    public static string Src(IEnumerable<(string Key, string Msl)> items, out int shared)
    {
        shared = 0;
        var head = new HashSet<string>(StringComparer.Ordinal); var body = new StringBuilder();
        foreach (var (key, t0) in items)
        {
            string t = Share(t0, out bool sh);
            if (sh) shared++;
            foreach (Match m in UG.Matches(t)) head.Add(PyStrip(m.Groups[1].Value));
            int n = 0;
            string t2 = UE.Replace(UG.Replace(t, _ => ""), m =>
            {
                n++;
                return m.Groups[1].Value + m.Groups[2].Value + " [[host_name(\"s" + key + "_" + m.Groups[2].Value + "\")]]" + m.Groups[3].Value;
            });
            if (n == 0) throw new ArgumentException(key + ": no entry point");
            var defs = new List<string>(); var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (Match m in Define.Matches(t)) if (seen.Add(m.Groups[1].Value)) defs.Add(m.Groups[1].Value);
            body.Append("namespace n").Append(key).Append(" {\n").Append(t2).Append("\n}\n");
            foreach (var d in defs) body.Append("#undef ").Append(d).Append('\n');
        }
        var hs = head.OrderBy(HeadRank).ThenBy(l => l, PyCmp.I);
        return string.Join("\n", hs) + "\n" + body.ToString();
    }

    /// <summary>变体（_se 采样模拟 / _vp 顶点补齐）合编一批的源码（Build.VarBatches）：函数前缀 = s<着色器键>_（宿主 nvn_mtl.m se_packed / vp_pack 按键算得出、不用另记）。
    /// 不叫 main0… 的两个标记函数 Src 不改名、同批几键会重名，先改名再合：折行标记核 s2a_se_fold → main0_fold（成 s<键>_main0_fold），
    /// 补齐掩码 dm_vp_mask_<十六进制> → main0_vpmask_<十六进制>（成 s<键>_main0_vpmask_<十六进制>）</summary>
    public static string VarSrc(IEnumerable<(string Key, string Msl)> items) =>
        Src(items.Select(x => (x.Key, x.Msl.Replace("kernel void s2a_se_fold()", "kernel void main0_fold()", StringComparison.Ordinal)
                                           .Replace("vertex float4 dm_vp_mask_", "vertex float4 main0_vpmask_", StringComparison.Ordinal))), out _);

    // ================= 摘要、签名、批名 =================
    /// <summary>unity_flush dg：sha256(MSL 的 UTF-8) 十六进制前 16 位</summary>
    public static string Dg(string msl) => Sha256Hex(msl).Substring(0, 16);
    /// <summary>unity_flush sig：全局 #include / #pragma METAL 行（去首尾空白、去重、按码点排序）</summary>
    public static string[] Sig(string msl)
    {
        var s = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match m in SigRe.Matches(msl)) s.Add(PyStrip(m.Value));
        var a = s.ToArray(); Array.Sort(a, PyCmp.I); return a;
    }
    static bool SameSig(string[] a, string[] b) => a.Length == b.Length && a.AsSpan().SequenceEqual(b);
    public static string BatchName(string dg) => "u" + dg;          // 批库名（含退回逐键时的单键批）
    public static string FnPrefix(string dg) => "s" + dg + "_";     // 键的函数前缀（json fn_prefix）
    public static string VinFile(string firstDg, int n) => "v" + firstDg + "_" + n.ToString(CultureInfo.InvariantCulture) + ".metal";

    /// <summary>UNITY_FP = sha256(CODE_FP + \0 + unity_src 的版本 + \0 + dmsh_ushare.py 字节)。C# 侧传自己的代码指纹与版本串即可</summary>
    public static byte[] UnityFp(string codeFp, string unitySrcVersion, byte[] ushareSource)
    {
        var ms = new MemoryStream();
        ms.Write(Utf8.GetBytes(codeFp)); ms.WriteByte(0); ms.Write(Utf8.GetBytes(unitySrcVersion)); ms.WriteByte(0); ms.Write(ushareSource);
        return SHA256.HashData(ms.ToArray());
    }
    /// <summary>编批库一批的批记忆键：UNITY_FP + '\0'.join(各键摘要)（UNITY_FP 与首个摘要之间没有分隔，照旧）</summary>
    public static byte[] Bid(byte[] unityFp, IEnumerable<string> dgs) => [.. unityFp, .. Utf8.GetBytes(string.Join("\0", dgs))];
    /// <summary>影子输入库一批：UNITY_FP + \0vin\0 + '\0'.join(摘要 + sha256(_bv MSL)[:16])</summary>
    public static byte[] VinBid(byte[] unityFp, IEnumerable<(string Dg, string Vin)> ks) =>
        [.. unityFp, .. "\0vin\0"u8, .. Utf8.GetBytes(string.Join("\0", ks.Select(x => x.Dg + Sha256Hex(x.Vin).Substring(0, 16))))];
    /// <summary>VIN_BATCH_MAX = int(float(DMSH_VIN_BATCH_MB 或 '3') * (1 &lt;&lt; 20))</summary>
    public static long VinBatchMax(string mb)
    {
        string s = string.IsNullOrEmpty(mb) ? "3" : PyStrip(mb).Replace("_", "");
        return (long)Math.Truncate(double.Parse(s, NumberStyles.Float, CultureInfo.InvariantCulture) * (1 << 20));
    }

    // ================= 切批 =================
    static bool Div(string dg, int unity) => ulong.Parse(dg, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture) % (ulong)Math.Abs((long)unity) == 0;   // unity = 0 抛除零

    /// <summary>unity_flush 的切批：ks 已按 (非热, 摘要) 排好；热冷不混、签名不同、摘要 % UNITY == 0、满 4 × UNITY 键处起新批（判断顺序与短路同 Python）；
    /// cap &gt; 0 时本批源码累计（码点数）到 cap 也起新批（11-05 时之笛：运行时用一支就把整批建成 Metal 库，批越大低区占得越多）</summary>
    public static List<List<string>> Cut(IReadOnlyList<string> ks, ISet<string> hot, int unity, Func<string, string> dg, Func<string, string[]> sig, Func<string, long> size = null, long cap = 0)
    {
        var batches = new List<List<string>>(); var cur = new List<string>(); long n = 0;
        foreach (var k in ks)
        {
            long b = cap > 0 ? size(k) : 0;
            if (cur.Count > 0 && (hot.Contains(k) != hot.Contains(cur[0]) || !SameSig(sig(k), sig(cur[0])) || Div(dg(k), unity) || cur.Count >= 4L * unity || (cap > 0 && n + b > cap))) { batches.Add(cur); cur = new(); n = 0; }
            cur.Add(k); n += b;
        }
        if (cur.Count > 0) batches.Add(cur);
        return batches;
    }

    /// <summary>cut_batches：同上但不看签名，另加本批源码累计（码点数）到 cap 起新批（cap = 0 不按大小切）</summary>
    public static List<List<string>> CutBatches(IReadOnlyList<string> ks, ISet<string> hot, int unity, Func<string, string> dg, Func<string, long> size, long cap)
    {
        var batches = new List<List<string>>(); var cur = new List<string>(); long n = 0;
        foreach (var k in ks)
        {
            long b = size(k);
            if (cur.Count > 0 && (hot.Contains(k) != hot.Contains(cur[0]) || Div(dg(k), unity) || cur.Count >= 4L * unity || (cap != 0 && n + b > cap))) { batches.Add(cur); cur = new(); n = 0; }
            cur.Add(k); n += b;
        }
        if (cur.Count > 0) batches.Add(cur);
        return batches;
    }

    // ================= 整份计划（unity_flush + vin_plan 的纯计算部分）=================
    public sealed class Plan
    {
        public Dictionary<string, string> DgOf;                 // 键 → 摘要（全部键）
        public List<string> Reps;                               // 同源代表键，按 (非热, 摘要) 排（unity_flush 的 ks_all）
        public Dictionary<string, List<string>> Same;           // 代表 → 与它 MSL 逐字节相同的其它键（只含有成员的组；顺序同 Python same[c]）
        public List<List<string>> Batches;                      // 编批库各批（代表键），按切出顺序
        public List<List<string>> Order;                        // 同上，按编译顺序（源码码点数大的先、稳定）
        public List<List<string>> VinBatches;                   // 影子输入库各批（cut_batches 切出顺序）
        public List<List<string>> VinOrder;                     // 同上，按编译顺序（_bv 源码大的先、稳定）
        public Dictionary<string, long> Len;                    // 键 → _b 源码码点数（全部键；编批库进度按它算待编量）
        public string Name(List<string> b) => BatchName(DgOf[b[0]]);
        public string VinName(List<string> b) => VinFile(DgOf[b[0]], b.Count);
        public string Prefix(string key) => FnPrefix(DgOf[key]);
        Dictionary<string, string> rep;
        /// <summary>键的同源代表（自己就是代表或不在任何同源组里 → 自己）</summary>
        public string Rep(string key)
        {
            if (rep == null) { var r = new Dictionary<string, string>(StringComparer.Ordinal); foreach (var (c, l) in Same) foreach (var m in l) r[m] = c; rep = r; }
            return rep.TryGetValue(key, out var c2) ? c2 : key;
        }
    }

    // ================= 批成员索引：按成员复用以前编过的批库 =================
    /// <summary>每编成一批（编批库 u / 影子输入库 v），给每个成员记一条「ub&lt;种类&gt;/&lt;目标&gt;/&lt;编译身份&gt;/&lt;成员号&gt;」→ 批名、库在缓存仓里的键、成员数、成员段摘要。
    /// 下次出库（翻译器改了、多数支 MSL 没变）按代表键查：各目标都指向同一批、成员段摘要与现在逐字节同、库还在、批里过半成员仍在用 → 整批拿来不编。
    /// 成员段摘要 = 这支单独拼一批时的源码（全局行 + 它那段命名空间 + #undef）的 sha256：批源码里它那段由它自己的 MSL 按 Src 现在的写法生成，
    /// 拼法（Share / 入口改名）改了摘要就变、不拿旧库，不靠人工版本号。过半门槛限住库里不再用的函数（至多与在用的一样多），也限住陪编的键（不超过真变的）</summary>
    public static class ReuseIndex
    {
        public sealed class Hit { public string Name; public List<string> Keys; public Dictionary<string, string> Mtl; public int N; public long Size = -1; }   // Size：整批源码码点数（索引里没记 = -1，封顶前编的旧批）
        static string IdxKey(string kind, string target, string ident, string id) => "ub" + kind + "/" + target + "/" + ident + "/" + id;
        static string S(byte[] b) => Utf8.GetString(b);
        static byte[] B(string s) => Utf8.GetBytes(s);
        public static string Blk(string ns, string text)
        {
            try { return Sha256Hex(Src(new[] { (ns, text) }, out _)); }
            catch (Exception e) when (e is ArgumentException or IndexOutOfRangeException or DecoderFallbackException) { return null; }
        }
        /// <summary>members：(成员号, 命名空间摘要, 源码)；mtlKeys：目标 → 这批库在缓存仓里的键</summary>
        public static void Record(string kind, string name, Dictionary<string, string> mtlKeys, Func<string, string> ident, List<(string Id, string Ns, string Text)> members)
        {
            var blk = members.Select(m => Blk(m.Ns, m.Text)).ToList();
            string size = members.Sum(m => PyLen(m.Text)).ToString(CultureInfo.InvariantCulture);
            foreach (var (t, mk) in mtlKeys)
                for (int i = 0; i < members.Count; i++)
                    if (blk[i] != null) Store.Put(IdxKey(kind, t, ident(t), members[i].Id), new() { ["b"] = B(name), ["m"] = B(mk), ["n"] = B(members.Count.ToString(CultureInfo.InvariantCulture)), ["x"] = B(blk[i]), ["s"] = B(size) });
        }
        /// <summary>→ 批名 → 拿来的一批（Keys = 现在归它的代表键，按 reps 的次序）。kind u：批名即库名，同名只留键多的一组；kind v：库按键各放一份，名字只作分组</summary>
        public static Dictionary<string, Hit> Pick(IReadOnlyList<string> reps, List<string> targets, Func<string, string> ident, Func<string, string> id, Func<string, string> text, string kind, Func<string, string> ns = null)
        {
            ns ??= id;
            var res = new Dictionary<string, Hit>(StringComparer.Ordinal);
            if (targets.Count == 0 || reps.Count == 0) return res;
            var got = new (string G, string Name, Dictionary<string, string> M, int N, long Sz)?[reps.Count];
            System.Threading.Tasks.Parallel.For(0, reps.Count, i =>
            {
                var k = reps[i]; string name = null, blk = null; int n = 0; long sz = -1; var ms = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var t in targets)
                {
                    var e = Store.Get(IdxKey(kind, t, ident(t), id(k)));
                    if (e == null || !e.ContainsKey("b") || !e.ContainsKey("m") || !e.ContainsKey("n") || !e.ContainsKey("x")) return;
                    var nm = S(e["b"]); var x = S(e["x"]);
                    if ((name != null && nm != name) || (blk != null && x != blk)) return;
                    name = nm; blk = x; ms[t] = S(e["m"]); n = int.Parse(S(e["n"]), CultureInfo.InvariantCulture); sz = e.ContainsKey("s") ? long.Parse(S(e["s"]), CultureInfo.InvariantCulture) : -1;
                }
                if (Blk(ns(k), text(k)) != blk) return;
                got[i] = (name + "\0" + string.Join("\0", targets.Select(t => ms[t])), name, ms, n, sz);
            });
            var groups = new Dictionary<string, Hit>(StringComparer.Ordinal);
            for (int i = 0; i < reps.Count; i++)
                if (got[i] is { } g)
                {
                    if (!groups.TryGetValue(g.G, out var h)) groups[g.G] = h = new Hit { Name = g.Name, Mtl = g.M, N = g.N, Size = g.Sz, Keys = new() };
                    h.Keys.Add(reps[i]);
                }
            foreach (var (gk, h) in groups.OrderByDescending(x => x.Value.Keys.Count).ThenBy(x => x.Key, StringComparer.Ordinal))
            {
                if (h.Keys.Count * 2 < h.N) continue;   // 过半成员已不在用：重编更省（库里少带废函数）
                var rk = kind == "u" ? h.Name : gk;
                if (res.ContainsKey(rk)) continue;
                if (targets.All(t => h.Mtl[t].StartsWith("mtl/" + t + "/", StringComparison.Ordinal) && Store.Exists(h.Mtl[t]))) res[rk] = h;   // 库在用时才读（Build Reused），不在这里整批读进内存
            }
            return res;
        }
    }

    /// <summary>src：键 → _b MSL（unity_flush 的 src_of / DEFER 的键）；vin：键 → _bv MSL（VIN_SRC，可空）；failed：编批库编不过的键（vin_plan 跳过）。
    /// unity = 0 时与 Python 一样在切批处抛 DivideByZeroException（只有相邻两键冷热、签名都相同时才走到取模）</summary>
    public static Plan MakePlan(IReadOnlyDictionary<string, string> src, ISet<string> hot, int unity, IReadOnlyDictionary<string, string> vin = null, long vinCap = 3 << 20, ISet<string> failed = null, long unityCap = 0)
    {
        var p = new Plan { DgOf = new(StringComparer.Ordinal), Same = new(StringComparer.Ordinal) };
        // 每键源码只取一次：摘要（前 16 位）、整段 sha256（同源去重的键）、码点数（编译顺序）当场算好，不留源码文本（src 可以是按需解码的视图，11-02 出包内存）
        var full = new Dictionary<string, string>(StringComparer.Ordinal); var len = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var kv in src) { var h = Sha256Hex(kv.Value); full[kv.Key] = h; p.DgOf[kv.Key] = h.Substring(0, 16); len[kv.Key] = PyLen(kv.Value); }
        p.Len = len;
        string dg(string k) => p.DgOf[k];
        var sigs = new Dictionary<string, string[]>(StringComparer.Ordinal);
        string[] sig(string k) { if (!sigs.TryGetValue(k, out var s)) sigs[k] = s = Sig(src[k]); return s; }
        var first = new Dictionary<string, string>(StringComparer.Ordinal);   // 整段 sha256 → 该源码的第一个键（= 原先按源码文本去重：整段摘要相同即文本相同）
        foreach (var k in src.Keys.OrderBy(k => !hot.Contains(k)).ThenBy(dg, PyCmp.I).ThenBy(k => k, PyCmp.I))
        {
            if (!first.TryGetValue(full[k], out var c)) first[full[k]] = c = k;
            if (c != k) { if (!p.Same.TryGetValue(c, out var l)) p.Same[c] = l = new(); l.Add(k); }
        }
        // Python sorted(set(...))：摘要相同的两份不同源码（16 位十六进制撞车）时 Python 的次序随集合散列而定，这里按键补一级使结果确定
        p.Reps = first.Values.OrderBy(k => !hot.Contains(k)).ThenBy(dg, PyCmp.I).ThenBy(k => k, PyCmp.I).ToList();
        p.Batches = Cut(p.Reps, hot, unity, dg, sig, k => len[k], unityCap);
        p.Order = p.Batches.OrderBy(b => -b.Sum(k => len[k])).ToList();
        (p.VinBatches, p.VinOrder) = VinPlan(p.Reps, hot, unity, dg, vin ?? new Dictionary<string, string>(), vinCap, failed);
        return p;
    }

    /// <summary>vin_plan 的切批：reps 中有 _bv 源码、不在 failed 里的键（顺序同 reps）按 cut_batches 切；→ (切出顺序, 编译顺序：_bv 源码码点数大的先、稳定)。
    /// 编批库退回逐键、去掉额外入口后某键的 _b 源码变了（unity_flush 里 src_of[k] = DEFER[k]），Python 的 dg 随之按新源码重算：dg 传「按当前源码算」的函数即同语义</summary>
    public static (List<List<string>> Batches, List<List<string>> Order) VinPlan(IReadOnlyList<string> reps, ISet<string> hot, int unity, Func<string, string> dg,
        IReadOnlyDictionary<string, string> vin, long cap, ISet<string> failed = null)
    {
        var ks = reps.Where(k => vin.ContainsKey(k) && (failed == null || !failed.Contains(k))).ToList();
        var b = CutBatches(ks, hot, unity, dg, k => PyLen(vin[k]), cap);
        return (b, b.OrderBy(x => -x.Sum(k => PyLen(vin[k]))).ToList());
    }

    // ================= 对拍入口 =================
    public static int Cli(string[] argv)
    {
        if (argv.Length == 4 && argv[0] == "fp") { Console.WriteLine(Convert.ToHexStringLower(UnityFp(argv[1], argv[2], File.ReadAllBytes(argv[3])))); return 0; }
        if (argv.Length == 3 && argv[0] == "share")
        {
            File.WriteAllBytes(argv[2], Utf8.GetBytes(Share(Utf8.GetString(File.ReadAllBytes(argv[1])), out bool one)));
            Console.Out.Write("shared " + (one ? 1 : 0) + "\n"); return 0;
        }
        if (argv.Length >= 4 && argv.Length % 2 == 0 && argv[0] == "src")
        {
            var items = new List<(string, string)>();
            for (int i = 2; i < argv.Length; i += 2) items.Add((argv[i], Utf8.GetString(File.ReadAllBytes(argv[i + 1]))));
            string s;
            try { s = Src(items, out int n); Console.Out.Write("shared " + n + "\n"); }
            catch (ArgumentException e) { Console.Out.Write("ERR\t" + e.Message + "\n"); return 1; }
            File.WriteAllBytes(argv[1], Utf8.GetBytes(s)); return 0;
        }
        if (argv.Length >= 4 && argv.Length % 2 == 0 && argv[0] == "var-src")   // 变体合编一批的源码（宿主单测 t_nvn_red / t_nvn_vpad 包内批库那一路用）
        {
            var items = new List<(string, string)>();
            for (int i = 2; i < argv.Length; i += 2) items.Add((argv[i], Utf8.GetString(File.ReadAllBytes(argv[i + 1]))));
            try { File.WriteAllBytes(argv[1], Utf8.GetBytes(VarSrc(items))); return 0; }
            catch (ArgumentException e) { Console.Out.Write("ERR\t" + e.Message + "\n"); return 1; }
        }
        if (argv.Length == 3 && argv[0] == "cut")
        {
            var ks = new List<string>(); var dgs = new Dictionary<string, string>(StringComparer.Ordinal); var sz = new Dictionary<string, long>(StringComparer.Ordinal);
            for (string l; (l = Console.In.ReadLine()) != null;)
            {
                var c = l.Split('\t'); if (c.Length != 3) continue;
                ks.Add(c[0]); dgs[c[0]] = c[1]; sz[c[0]] = long.Parse(c[2], CultureInfo.InvariantCulture);
            }
            var bs = CutBatches(ks, new HashSet<string>(), int.Parse(argv[1], CultureInfo.InvariantCulture), k => dgs[k], k => sz[k], long.Parse(argv[2], CultureInfo.InvariantCulture));
            foreach (var b in bs) Console.Out.Write(string.Join(",", b) + "\n");
            return 0;
        }
        if ((argv.Length == 4 || argv.Length == 6) && argv[0] == "flush") return FlushFixture(argv[1], argv[2], argv[3], argv.Length == 6 && argv[4] == "-j" ? int.Parse(argv[5], CultureInfo.InvariantCulture) : 4);
        if (argv.Length < 4 || argv.Length > 5) { Console.Error.WriteLine("用法：dsh_batch --unity <产物目录> <UNITY> <热键清单 | -> <UNITY_FP 十六进制> [影子输入库每批 MB]"); return 2; }
        var t0 = System.Diagnostics.Stopwatch.StartNew();
        string dir = argv[0]; int unity = int.Parse(argv[1], CultureInfo.InvariantCulture);
        var hot = new HashSet<string>(StringComparer.Ordinal);
        if (argv[2] != "-") foreach (var l in File.ReadAllLines(argv[2])) { var k = PyStrip(l); if (k.Length > 0) hot.Add(k); }
        byte[] fp = Convert.FromHexString(argv[3]);
        long cap = VinBatchMax(argv.Length > 4 ? argv[4] : null);
        var src = new Dictionary<string, string>(StringComparer.Ordinal); var vin = new Dictionary<string, string>(StringComparer.Ordinal);
        var files = Directory.GetFiles(dir);
        var lk = new object();
        System.Threading.Tasks.Parallel.ForEach(files, f =>
        {
            string n = Path.GetFileName(f);
            if (n.Length != 16 + 8 && n.Length != 16 + 9) return;
            string k = n.Substring(0, 16), sfx = n.Substring(16);
            if (sfx != "_b.metal" && sfx != "_bv.metal") return;
            string t = Utf8.GetString(File.ReadAllBytes(f));
            lock (lk) (sfx == "_b.metal" ? src : vin)[k] = t;
        });
        long tRead = t0.ElapsedMilliseconds;
        var o = new StringWriter { NewLine = "\n" };
        Plan p;
        try { p = MakePlan(src, hot, unity, vin, cap); }
        catch (DivideByZeroException) { Console.Out.Write("ERR\tZeroDivisionError\n"); return 0; }
        int shared = 0;
        // 编批库在前（大的先）、影子输入批在后：同 unity_flush 池的提交顺序；各批拼源码彼此独立，并行算、按序输出
        var jobs = p.Order.Select(b => (V: false, B: b)).Concat(p.VinOrder.Select(b => (V: true, B: b))).ToList();
        var lines = new string[jobs.Count]; var sh = new int[jobs.Count];
        System.Threading.Tasks.Parallel.For(0, jobs.Count, i =>
        {
            var (v, b) = jobs[i];
            string name = v ? p.VinName(b) : p.Name(b);
            string dgs = string.Join(",", b.Select(k => p.DgOf[k]));
            try
            {
                string s = Src(b.Select(k => (p.DgOf[k], v ? vin[k] : src[k])), out sh[i]);
                byte[] bid = v ? VinBid(fp, b.Select(k => (p.DgOf[k], vin[k]))) : Bid(fp, b.Select(k => p.DgOf[k]));
                lines[i] = (v ? "V\t" : "B\t") + name + "\t" + dgs + "\t" + Sha256Hex(s) + "\t" + Sha256Hex(bid);
            }
            catch (ArgumentException e) { lines[i] = "ERR\t" + name + "\t" + e.Message; }
            catch (IndexOutOfRangeException) { lines[i] = "ERR\t" + name + "\tIndexError"; }
        });
        foreach (var l in lines) o.Write(l + "\n");
        shared = sh.Sum();
        var lib = new Dictionary<string, (string Lib, string Pre)>(StringComparer.Ordinal);
        foreach (var b in p.Batches) foreach (var k in b) foreach (var m in p.Same.TryGetValue(k, out var l) ? l.Prepend(k) : [k]) lib[m] = (p.Name(b), p.Prefix(k));
        foreach (var k in lib.Keys.OrderBy(k => k, PyCmp.I)) o.Write("K\t" + k + "\t" + lib[k].Lib + "\t" + lib[k].Pre + "\n");
        o.Write("N\tmain0_u shared\t" + shared + "\n");
        var stdout = Console.OpenStandardOutput(); var bytes = Utf8.GetBytes(o.ToString()); stdout.Write(bytes); stdout.Flush();
        Console.Error.WriteLine($"unity：{src.Count} 键（_bv {vin.Count}），{p.Batches.Count} 批 + 影子输入 {p.VinBatches.Count} 批；读 {tRead} ms，计划 + 拼源码 {t0.ElapsedMilliseconds - tRead} ms");
        return 0;
    }

    /// <summary>--unity flush：跑 Build 里真正的编批库那一步（不另写一份）。Build 的并发数、Mac 编译约定与 UnityFlush 不对外，按名取（只在这个单测入口里）</summary>
    static int FlushFixture(string inDir, string outDir, string cas, int nj)
    {
        const System.Reflection.BindingFlags F = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static;
        T Priv<T>(string n) => (T)typeof(Build).GetField(n, F).GetValue(null);
        typeof(Build).GetField("NJ", F).SetValue(null, nj);
        string work = Path.Combine(Path.GetTempPath(), $"dshb_unity_{Environment.ProcessId}_{Guid.NewGuid():N}"); Directory.CreateDirectory(work);
        try
        {
            Store.Open(cas);
            if (Metal.Init((Priv<string[]>("MacMetal"), Priv<string>("MacRecord"), "macosx"), null, work, nj) is { } broken) { Console.Error.WriteLine(broken); return 1; }
            Build.Spill = new BlobFile(Path.Combine(work, "spill.dat"), compress: true); Build.MAC = new Side(work);
            foreach (var f in Directory.GetFiles(inDir).OrderBy(x => x, StringComparer.Ordinal))
            {
                string n = Path.GetFileName(f); if (n.Length < 17 || n[16] != '_') continue;
                string k = n[..16], sfx = n[16..];
                if (sfx is "_b.metal" or "_b.json") Build.MAC.Put(n, File.ReadAllBytes(f));
                else if (sfx == "_bv.metal") Build.VinSrc[k] = Utf8.GetString(File.ReadAllBytes(f));
            }
            foreach (var n in Build.MAC.Names().Where(n => n.EndsWith("_b.metal", StringComparison.Ordinal)))
            {
                string k = n[..16], plain = Path.Combine(inDir, k + "_b.plain.metal");
                Build.Defer[k] = File.Exists(plain) ? Utf8.GetString(File.ReadAllBytes(plain)) : null;
            }
            var failed = (Dictionary<string, string>)typeof(Build).GetMethod("UnityFlush", F).Invoke(null, null);
            Build.MAC.Export(outDir);
            var o = new StringBuilder();
            foreach (var k in failed.Keys.OrderBy(x => x, StringComparer.Ordinal)) o.Append("FAILED\t").Append(k).Append('\t').Append(PyStrip(failed[k]).Split('\n')[0]).Append('\n');
            foreach (var kv in Build.Stats.OrderBy(x => x.Key, StringComparer.Ordinal)) o.Append("STAT\t").Append(kv.Key).Append('\t').Append(kv.Value).Append('\n');
            o.Append("METAL\t").Append(Metal.Summary()).Append('\n');
            lock (Console.Out) { Console.Out.Write(o.ToString()); Console.Out.Flush(); }
            return 0;
        }
        finally { try { Directory.Delete(work, true); } catch { } }
    }
}
