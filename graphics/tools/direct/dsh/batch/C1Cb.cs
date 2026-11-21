// 出库链移进 C#（11-01 出包线）：c1 越界核查表（translator/c1_guard.py）+ 常量读范围表（cb_extent.py）的现行出库口径（cb_extent.py --both：both_jobs / both_of / 两张表），
//   输出与旧 Python 逐字节相同。规则说明见两个 Python 文件头；这里只记移植上的语义对齐：
//   - 正则：Python str 模式的 \w \s \d \b 都是 Unicode 语义，.NET 的不完全一样，统一换成显式写法（W / S / B 三个片段）：
//     \w = 字母或数字类（str.isalnum）或 _ → [\p{L}\p{N}_]；\s = str.isspace，比 .NET \s 多 \x1c-\x1f；\d 两边都是 \p{Nd}；\b 用 W 写成前后看。
//     pattern.match(s, pos) 用 \G 锚定；fullmatch 用 ^(?:…)\z（.NET 的 $ 会放过结尾换行）。str.strip / isalnum 同样按 Python 的字符集手写。
//     ACCESS / DEFINITION / ASSIGNMENT 三条扫全文的正则改成手写扫描（占九成时间），回溯与不重叠语义的推导写在各自函数头。
//   - 区间算术按 Python 无界整数：BigInteger；// 是向下取整（区间可能倒挂：clamp(x, 10, 5) 得 (10, 5)，上界可为负），>> 是算术右移，
//     bit_length 取绝对值的位数（.NET GetBitLength 对负数按补码算，不同）。字面量照 int(t, 0)：十进制非零数带前导 0（010）是 ValueError → 整式无界。
//   - Python 递归超限（RecursionError，默认上限 1000 帧）在最内层 expression 里被吃成无界：Interval 逐帧镜像 Python 的调用深度（含 peek / take / known /
//     combine / re.fullmatch→_compile / tokens→re.sub→_compile 这些叶子调用），在同一处抛出；进 Interval 之前的帧数按出库进程池实测定标（见 PyBaseCb）。
using System;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

static class C1Cb
{
    /// <summary>反射 json bindings 数组的一项（只取两张表用到的字段）：Kind 不是字符串时为 null；Reg 缺省为 null</summary>
    public sealed record Binding(string Kind, long? Reg, string MslName);

    /// <summary>both_jobs 的一项：.metal 文件名、MSL、c1 跨度（无反射为 null）、绑定（只有带 cbuf / sbuf 的 _b.metal 才有，否则 null）</summary>
    public sealed record Job(string Name, string Msl, int? Span, List<Binding> Bindings);

    // ---- Python 正则字符类的显式写法 ----
    const string W = @"[\p{L}\p{N}_]";
    const string S = @"[\s\x1c-\x1f]";
    const string B = @"(?:(?<=" + W + @")(?!" + W + @")|(?<!" + W + @")(?=" + W + @"))";
    // \b 紧挨着已知是词字符的一侧时只剩一半：其前是词字符 → 只看后面（BR）；其后是词字符 → 只看前面（BL）。等价，且让 .NET 能按首字符快速定位候选
    const string BL = @"(?<!" + W + @")", BR = @"(?!" + W + @")";
    static bool PyIsWord(char c) => char.IsLetter(c) || char.IsNumber(c) || c == '_';
    static string BLeft(string lit) => lit.Length > 0 && PyIsWord(lit[0]) ? BL : lit.Length > 0 ? @"(?<=" + W + @")" : B;   // \b 后面紧跟 lit
    static string BRight(string lit) => lit.Length > 0 && PyIsWord(lit[^1]) ? BR : lit.Length > 0 ? @"(?=" + W + @")" : B;   // \b 前面紧挨 lit
    const RegexOptions O = RegexOptions.Compiled | RegexOptions.CultureInvariant;

    static readonly Regex Token = new(@"\G" + S + @"*(0[xX][0-9a-fA-F]+[uU]?|\d+\.\d*(?:[eE][-+]?\d+)?f?|\d+[uU]?|[A-Za-z_]" + W + @"*(?:\." + W + @"+)*|\." + W + @"+|<<|>>|<=|>=|==|!=|&&|\|\||[-+*/%&|^~!?:(),<>\[\]])", O);
    static readonly Regex AsTypeU = new(BL + @"as_type<u(?:int|short|long)>" + S + @"*\(", O);
    static readonly Regex AsType = new(BL + @"as_type<" + W + @"+>" + S + @"*\(", O);
    static readonly Regex IntLit = new(@"^(?:0[xX][0-9a-fA-F]+[uU]?|\d+[uU]?)\z", O);
    static readonly Regex FloatLit = new(@"^(?:\d+\.\d*(?:[eE][-+]?\d+)?f?)\z", O);
    static readonly Regex Ident = new(@"^(?:[A-Za-z_]" + W + @"*(?:\." + W + @"+)*)\z", O);
    static readonly Regex Temp = new(@"^(?:_\d+)\z", O);
    static readonly Regex Write = new(@"\G" + S + @"*(?:=(?!=)|[-+*/%&|^]=|<<=|>>=|\+\+|--)", O);
    static readonly Regex SlotRo = new(BL + @"s\d+", O);
    const int MAX = 65536;

    static bool PyIsSpace(char c) => char.IsWhiteSpace(c) || (c >= '\x1c' && c <= '\x1f');
    static string PyStrip(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && PyIsSpace(s[a])) a++;
        while (b > a && PyIsSpace(s[b - 1])) b--;
        return s.Substring(a, b - a);
    }

    // 按绑定名生成的三条 / 两条正则（extents / unwritten），同名复用
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, Regex[]> NameRx = new();
    static Regex[] CbRx(string name) => NameRx.GetOrAdd("c\0" + name, n => new[] {
        new Regex(BLeft(name) + Regex.Escape(name) + BRight(name), O),
        new Regex(@"\(\*spvDescriptorSet0\." + Regex.Escape(name) + @"\)\._m0\[([^\]]+)\]", O),
        new Regex(BLeft(name) + Regex.Escape(name) + S + @"*\[\[id\(", O) });
    static Regex[] SbRx(string name) => NameRx.GetOrAdd("s\0" + name, n => new[] {
        new Regex(@"\(\*" + Regex.Escape(name) + BRight(name), O),
        new Regex(Regex.Escape(name) + BRight(name), O) });

    sealed class PyValueError : Exception { }
    sealed class PyIndexError : Exception { }

    struct Iv
    {
        public BigInteger? L, H;
        public Iv(BigInteger? l, BigInteger? h) { L = l; H = h; }
    }
    static readonly Iv Unb = default;

    static readonly Dictionary<string, int> Binary = new()
    {
        ["||"] = 1, ["&&"] = 2, ["|"] = 3, ["^"] = 4, ["&"] = 5, ["=="] = 6, ["!="] = 6, ["<"] = 7, [">"] = 7, ["<="] = 7, [">="] = 7,
        ["<<"] = 8, [">>"] = 8, ["+"] = 9, ["-"] = 9, ["*"] = 10, ["/"] = 10, ["%"] = 10,
    };

    /// <summary>c1_guard.tokens：抛 PyValueError 同 Python 的 ValueError</summary>
    static List<string> Tokens(string text)
    {
        text = AsTypeU.Replace(text, "as_type_u(");
        text = AsType.Replace(text, "as_type(");
        var o = new List<string>(); int i = 0;
        while (i < text.Length)
        {
            var m = Token.Match(text, i);
            if (!m.Success)
            {
                for (int k = i; k < text.Length; k++) if (!PyIsSpace(text[k])) throw new PyValueError();
                break;
            }
            o.Add(m.Groups[1].Value); i = m.Index + m.Length;
        }
        return o;
    }

    /// <summary>int(t.rstrip("uU"), 0)：十进制非零数不许前导 0（Python 先把 Unicode 十进制数字转成 ASCII 再判）</summary>
    static BigInteger ParseInt(string t)
    {
        t = t.TrimEnd('u', 'U');
        if (t.Length > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X')) return BigInteger.Parse("0" + t.Substring(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
        BigInteger v = BigInteger.Zero; bool lead0 = CharUnicodeInfo.GetDecimalDigitValue(t[0]) == 0;
        foreach (char c in t)
        {
            int d = CharUnicodeInfo.GetDecimalDigitValue(c);
            if (d < 0) throw new PyValueError();
            if (lead0 && d != 0) throw new PyValueError();
            v = v * 10 + d;
        }
        return v;
    }

    static bool Known(BigInteger? a) => a.HasValue;
    static bool Known(BigInteger? a, BigInteger? b) => a.HasValue && b.HasValue;
    static bool Known(BigInteger? a, BigInteger? b, BigInteger? c, BigInteger? d) => a.HasValue && b.HasValue && c.HasValue && d.HasValue;
    static BigInteger Min(BigInteger a, BigInteger b) => a <= b ? a : b;
    static BigInteger Max(BigInteger a, BigInteger b) => a >= b ? a : b;
    static BigInteger FloorDiv(BigInteger a, BigInteger b)
    {
        var q = BigInteger.DivRem(a, b, out var r);
        return (r != 0 && (r.Sign < 0) != (b.Sign < 0)) ? q - 1 : q;
    }
    static BigInteger Shl(BigInteger a, BigInteger n) => n > int.MaxValue ? (a.IsZero ? a : throw new OverflowException("<< 位数过大")) : a << (int)n;
    static BigInteger Shr(BigInteger a, BigInteger n) => n > int.MaxValue ? (a.Sign < 0 ? BigInteger.MinusOne : BigInteger.Zero) : a >> (int)n;
    static long BitLength(BigInteger a) => (long)BigInteger.Abs(a).GetBitLength();

    /// <summary>Python 默认递归上限（出库链没改过 setrecursionlimit）。帧数 &gt; 它就抛 RecursionError</summary>
    const int PyLimit = 1000;
    /// <summary>出库进程池工作进程（run_both：pool.imap → mapstar → both_of）里进 Interval.expression 之前已有的帧：常量读下标走 both_of → extents（9），
    ///   c1 下标走 both_of → judge_source → genexpr → proven（11）。11-01 用一元负号链定标：进程池里 extents 路径 m=981 个负号起翻无界、980 有界，
    ///   该处最深一帧是 9 + 11 + m（re.fullmatch→_compile）；c1 路径 979 起翻；串行直调时各少 6 帧（只影响进程池以外的用法）</summary>
    const int PyBaseCb = 9, PyBaseC1 = 11;
    static int maxFrames;
    /// <summary>本进程所有 Interval 到过的最深镜像帧数（不含进 Interval 之前的帧；对拍时看离上限多远）</summary>
    public static int MaxFrames => Volatile.Read(ref maxFrames);

    /// <summary>c1_guard.Interval：方法与 Python 一一对应，求值顺序、memo、深度上限都照搬</summary>
    sealed class Interval
    {
        readonly Dictionary<string, (string Kind, string Text)> definitions;
        readonly Dictionary<string, Iv> memo = new();
        readonly Dictionary<string, object> tokCache;
        readonly int lim;   // PyLimit - 进 Interval 之前的帧
        int depth, frames, top;
        List<string> toks; int pos;
        public Interval(Dictionary<string, (string, string)> defs, Dictionary<string, object> tc, int pyBase) { definitions = defs; tokCache = tc; lim = PyLimit - pyBase; }

        // 镜像 Python 进一层函数（Enter，配 Leave）或一次 k 层深的叶子调用（Probe）：越过上限抛 RecursionError 同款（InsufficientExecutionStackException，被最内层 Expression 接住）
        void Enter() { if (++frames > top) { top = frames; if (top > lim) { frames--; top--; throw new InsufficientExecutionStackException(); } } }
        void Leave() => frames--;
        void Probe(int k) { if (frames + k > top) { if (frames + k > lim) throw new InsufficientExecutionStackException(); top = frames + k; } }
        public void Done() { int t = top, cur; while (t > (cur = Volatile.Read(ref maxFrames)) && Interlocked.CompareExchange(ref maxFrames, t, cur) != cur) { } }

        Iv Variable(string name)
        {
            Enter();
            try
            {
                if (memo.TryGetValue(name, out var mv)) return mv;
                if (!definitions.TryGetValue(name, out var def) || depth > 32) return Unb;
                memo[name] = Unb;
                depth++;
                Iv value;
                try { value = Expression(def.Text); }
                finally { depth--; }
                if (def.Kind == "bool") value = new Iv(0, 1);
                else if (def.Kind.StartsWith('u')) { Probe(1); if (!(Known(value.L) && value.L.Value >= 0)) value = new Iv(0, null); }   // known()
                memo[name] = value;
                return value;
            }
            finally { Leave(); }
        }

        public Iv Expression(string text)
        {
            Enter();
            try
            {
                // tokens 是纯函数：同一份 MSL 内按文本缓存（结果或 ValueError）
                Probe(3);   // tokens → re.sub → _compile
                if (!tokCache.TryGetValue(text, out var tk))
                {
                    try { tk = Tokens(text); } catch (PyValueError) { tk = null; }
                    tokCache[text] = tk;
                }
                if (tk == null) throw new PyValueError();
                toks = (List<string>)tk; pos = 0;
                var value = Ternary();
                if (pos != toks.Count) return Unb;
                return value;
            }
            catch (Exception e) when (e is PyValueError || e is PyIndexError || e is InsufficientExecutionStackException) { return Unb; }
            finally { Leave(); }
        }

        string Peek() { Probe(1); return pos < toks.Count ? toks[pos] : null; }
        string Take(string want = null)
        {
            Probe(1);
            if (pos >= toks.Count) throw new PyIndexError();
            var t = toks[pos];
            if (want != null && t != want) throw new PyValueError();
            pos++;
            return t;
        }

        Iv Ternary()
        {
            Enter();
            try
            {
                var cond = Binary_(1);
                if (Peek() != "?") return cond;
                Take("?"); var a = Ternary(); Take(":"); var b = Ternary();
                Probe(1);   // known()
                return new Iv(Known(a.L, b.L) ? Min(a.L.Value, b.L.Value) : null, Known(a.H, b.H) ? Max(a.H.Value, b.H.Value) : null);
            }
            finally { Leave(); }
        }

        Iv Binary_(int level)
        {
            Enter();
            try
            {
                var left = Unary();
                while (Peek() is string p && Binary.TryGetValue(p, out int lv) && lv >= level)
                {
                    var op = Take(); var right = Binary_(Binary[op] + 1);
                    Probe(op is "||" or "&&" or "==" or "!=" or "<" or ">" or "<=" or ">=" ? 1 : 2);   // combine（除比较外再调 known）
                    left = Combine(op, left, right);
                }
                return left;
            }
            finally { Leave(); }
        }

        static Iv Combine(string op, Iv a, Iv b)
        {
            BigInteger? al = a.L, ah = a.H, bl = b.L, bh = b.H;
            switch (op)
            {
                case "||": case "&&": case "==": case "!=": case "<": case ">": case "<=": case ">=": return new Iv(0, 1);
                case "+": return new Iv(Known(al, bl) ? al + bl : null, Known(ah, bh) ? ah + bh : null);
                case "-": return new Iv(Known(al, bh) ? al - bh : null, Known(ah, bl) ? ah - bl : null);
                case "*":
                {
                    if (!Known(al, ah, bl, bh)) return Unb;
                    BigInteger p0 = al.Value * bl.Value, p1 = al.Value * bh.Value, p2 = ah.Value * bl.Value, p3 = ah.Value * bh.Value;
                    return new Iv(Min(Min(p0, p1), Min(p2, p3)), Max(Max(p0, p1), Max(p2, p3)));
                }
                case "/": case ">>": case "<<":
                    if (!Known(al, ah, bl, bh) || bl != bh || bl < 0 || (op == "/" && bl == 0)) return Unb;
                    if (op == "<<") return new Iv(Shl(al.Value, bl.Value), Shl(ah.Value, bl.Value));
                    if (op == ">>") return new Iv(Shr(al.Value, bl.Value), Shr(ah.Value, bl.Value));
                    return al >= 0 ? new Iv(FloorDiv(al.Value, bl.Value), FloorDiv(ah.Value, bl.Value)) : Unb;
                case "%":
                    if (!Known(bl, bh) || bl != bh || bl <= 0) return Unb;
                    return Known(al) && al >= 0 ? new Iv(0, bl - 1) : new Iv(-(bl - 1), bl - 1);
                case "&":
                {
                    BigInteger? cap = null;
                    foreach (var x in new[] { a, b })
                        if (Known(x.L, x.H) && x.L >= 0) cap = cap.HasValue ? Min(cap.Value, x.H.Value) : x.H;
                    return cap.HasValue ? new Iv(0, cap) : Unb;
                }
                case "|": case "^":
                    if (!Known(al, ah, bl, bh) || al < 0 || bl < 0) return Unb;
                    return new Iv(0, (BigInteger.One << (int)BitLength(Max(ah.Value, bh.Value))) - 1);
            }
            return Unb;
        }

        Iv Unary()
        {
            Enter();
            try
            {
                var t = Peek();
                if (t == "-") { Take(); var v = Unary(); Probe(1); return new Iv(Known(v.H) ? -v.H : null, Known(v.L) ? -v.L : null); }
                if (t == "+") { Take(); return Unary(); }
                if (t == "!") { Take(); Unary(); return new Iv(0, 1); }
                if (t == "~" || t == "*") { Take(); Unary(); return Unb; }
                var p = Primary();
                return Postfix(p);
            }
            finally { Leave(); }
        }

        Iv Postfix(Iv value)
        {
            Enter();
            try
            {
                while (Peek() is string p && (p == "[" || p.StartsWith('.')))
                {
                    if (Take() == "[") { Ternary(); Take("]"); }
                    value = Unb;
                }
                return value;
            }
            finally { Leave(); }
        }

        Iv Primary()
        {
            Enter();
            try
            {
                var t = Take();
                if (t == "(") { var v = Ternary(); Take(")"); return v; }
                Probe(2);   // re.fullmatch → _compile
                if (IntLit.IsMatch(t)) { var v = ParseInt(t); return new Iv(v, v); }
                if (FloatLit.IsMatch(t)) return Unb;
                if (!Ident.IsMatch(t)) throw new PyValueError();
                if (Peek() == "(")
                {
                    Take("(");
                    var args = new List<Iv>();
                    if (Peek() != ")")
                    {
                        args.Add(Ternary());
                        while (Peek() == ",") { Take(","); args.Add(Ternary()); }
                    }
                    Take(")");
                    return Call(t, args);
                }
                if (Temp.IsMatch(t))
                {
                    var save = (toks, pos);
                    try { return Variable(t); }
                    finally { (toks, pos) = save; }
                }
                if (t == "true" || t == "false") return new Iv(0, 1);
                return Unb;
            }
            finally { Leave(); }
        }

        Iv Call(string name, List<Iv> args)
        {
            Enter();
            try
            {
                if (name == "as_type_u" && args.Count == 1) return new Iv(0, null);
                if ((name == "int" || name == "uint" || name == "short" || name == "ushort" || name == "long" || name == "ulong") && args.Count == 1)
                {
                    var (l, h) = (args[0].L, args[0].H);
                    if (name.StartsWith('u')) { Probe(1); if (!(Known(l) && l >= 0)) return new Iv(0, null); }
                    return new Iv(l, h);
                }
                if (name == "min" && args.Count == 2)
                {
                    Probe(1);
                    BigInteger? al = args[0].L, ah = args[0].H, bl = args[1].L, bh = args[1].H;
                    BigInteger? hs = ah.HasValue && bh.HasValue ? Min(ah.Value, bh.Value) : ah ?? bh;
                    return new Iv(Known(al, bl) ? Min(al.Value, bl.Value) : null, hs);
                }
                if (name == "max" && args.Count == 2)
                {
                    Probe(1);
                    BigInteger? al = args[0].L, ah = args[0].H, bl = args[1].L, bh = args[1].H;
                    BigInteger? ls = al.HasValue && bl.HasValue ? Max(al.Value, bl.Value) : al ?? bl;
                    return new Iv(ls, Known(ah, bh) ? Max(ah.Value, bh.Value) : null);
                }
                if (name == "clamp" && args.Count == 3) return new Iv(args[1].L, args[2].H);
                return Unb;
            }
            finally { Leave(); }
        }
    }

    /// <summary>c1_guard.c1_span_of：反射文本（字节）→ 共享 c1 库给它的字节数；解析不了 → null</summary>
    static int? C1SpanOf(JsonElement? refl)
    {
        if (refl == null) return null;
        var r = refl.Value;
        if (r.ValueKind != JsonValueKind.Object) throw new InvalidDataException("反射 json 不是对象（Python 在 .get 上崩）");
        long length;
        if (!r.TryGetProperty("c1", out var c1)) length = 0;
        else
        {
            switch (c1.ValueKind)
            {
                case JsonValueKind.String: { var s = c1.GetString(); long n = 0; foreach (char ch in s) if (!char.IsLowSurrogate(ch)) n++; length = n; break; }   // len 数码位
                case JsonValueKind.Array: length = c1.GetArrayLength(); break;
                case JsonValueKind.Object: length = c1.EnumerateObject().Select(p => p.Name).Distinct().Count(); break;
                case JsonValueKind.Null: case JsonValueKind.False: length = 0; break;
                case JsonValueKind.Number: if (c1.GetDouble() == 0) { length = 0; break; } return null;   // 非零数 len() → TypeError
                default: return null;   // true
            }
            length /= 2;
        }
        return (int)((length + 255) / 256 * 256 + 256);
    }

    static JsonElement? ParseJson(byte[] bytes)
    {
        try { using var d = JsonDocument.Parse(bytes); return d.RootElement.Clone(); }
        catch (Exception e) when (e is JsonException || e is ArgumentException) { return null; }
    }

    /// <summary>Python 的假值：null / false / 0 / "" / [] / {}</summary>
    static bool Falsy(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.False => true,
        JsonValueKind.Number => e.GetDouble() == 0,
        JsonValueKind.String => e.GetString().Length == 0,
        JsonValueKind.Array => e.GetArrayLength() == 0,
        JsonValueKind.Object => !e.EnumerateObject().Any(),
        _ => false,
    };

    /// <summary>反射 json 的 bindings 数组 → Binding 列表（`or []`：缺省 / null / 空 → 空表）</summary>
    public static List<Binding> BindingsOf(JsonElement refl)
    {
        var o = new List<Binding>();
        if (!refl.TryGetProperty("bindings", out var bs) || Falsy(bs)) return o;
        foreach (var b in bs.EnumerateArray())
        {
            if (b.ValueKind != JsonValueKind.Object) throw new InvalidDataException("bindings 项不是对象");
            string kind = b.TryGetProperty("kind", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString() : null;
            long? reg = null;
            // reg 可以是 null：追不到单一槽的动态句柄数组（<阶段>_t…_cb0_40000000，array<…>）按设计不出槽，宿主按名字认（nvn_refl.m NVN_RB_TEXD / SAMPD），
            //   同旧 Python b.get('reg') 的 None（11-02 马力欧派对 超级巨星 6370 支，这里抛「reg 不是整数」致整份出库 rc=134）
            if (b.TryGetProperty("reg", out var r) && r.ValueKind != JsonValueKind.Null)
            {
                if (r.ValueKind != JsonValueKind.Number || !r.TryGetInt64(out long rv)) throw new InvalidDataException("reg 不是整数");
                reg = rv;
            }
            string msl = b.TryGetProperty("msl_name", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() : null;
            o.Add(new Binding(kind, reg, msl));
        }
        return o;
    }

    public static string KeyOf(string name) => name.EndsWith("_b.metal", StringComparison.Ordinal) ? name[..^"_b.metal".Length] : name[..^6];

    static readonly UTF8Encoding StrictUtf8 = new(false, true);

    /// <summary>一支 .metal 两张表输入的签名（同 BothJobs 取 span / 绑定的口径；MSL 按字节 sha256，不留文本）：出库主进程比后台遍与收尾遍哪些要重算（11-02 出包内存）</summary>
    public static string SigOf(string name, byte[] metal, byte[] json)
    {
        var refl = json != null ? ParseJson(json) : null;
        int? span = json != null ? C1SpanOf(refl) : null;
        List<Binding> bindings = null;
        if (name.EndsWith("_b.metal", StringComparison.Ordinal) && refl is JsonElement r && r.ValueKind == JsonValueKind.Object)
        {
            var bs = BindingsOf(r);
            if (bs.Any(b => b.Kind == "cbuf" || b.Kind == "sbuf")) bindings = bs;
        }
        return Convert.ToHexString(SHA256.HashData(metal)) + "\0" + span + "\0" + string.Join("\0", (bindings ?? new()).Select(b => $"{b.Kind}\t{b.Reg}\t{b.MslName}"));
    }

    /// <summary>cb_extent.both_jobs：{文件名: 字节}（库的 Mac 侧）→ 每个 .metal 一项，按文件名（码位序）排</summary>
    public static List<Job> BothJobs(IReadOnlyDictionary<string, byte[]> files)
    {
        var jobs = new List<Job>();
        foreach (var n in files.Keys.Where(n => n.EndsWith(".metal", StringComparison.Ordinal)).OrderBy(n => n, StringComparer.Ordinal))
        {
            files.TryGetValue(KeyOf(n) + "_b.json", out var text);
            jobs.Add(JobOf(n, files[n], text));
        }
        return jobs;
    }
    /// <summary>一支 .metal 的任务（BothJobs 的单个；Cli 逐支读文件时直接用，不把全部 MSL 先读进内存）</summary>
    public static Job JobOf(string n, byte[] metal, byte[] text)
    {
        var refl = text != null ? ParseJson(text) : null;
        int? span = text != null ? C1SpanOf(refl) : null;
        List<Binding> bindings = null;
        if (n.EndsWith("_b.metal", StringComparison.Ordinal) && refl is JsonElement r && r.ValueKind == JsonValueKind.Object)
        {
            var bs = BindingsOf(r);
            if (bs.Any(b => b.Kind == "cbuf" || b.Kind == "sbuf")) bindings = bs;
        }
        return new Job(n, StrictUtf8.GetString(metal), span, bindings);
    }

    /// <summary>c1_guard.ASSIGNMENT 的 finditer（逐个匹配的临时量名），手写扫描：正则版占了整段九成时间（开头是后看的三路分支，.NET 每个位置都试）。
    ///   原式 (?&lt;![\w.])(_\d+)\s*(?:&lt;&lt;|&gt;&gt;|[-+*/%&amp;|^])?=(?!=) | (?&lt;![\w.])(_\d+)\s*(?:\+\+|--) | (?:\+\+|--)\s*(_\d+)\b：
    ///   \d+、\s* 回溯变短后下一个字符仍是数字 / 空白，后面都接不上，所以只需取最长；同一位置按分支顺序试，匹配后从匹配尾继续（不重叠）</summary>
    static IEnumerable<string> Assignments(string s)
    {
        int n = s.Length, i = 0;
        while (i < n)
        {
            int j = s.AsSpan(i).IndexOfAny('_', '+', '-');   // 三个分支的首字符，其余位置都不可能起匹配
            if (j < 0) yield break;
            i += j;
            char c = s[i];
            if (c == '_' && i + 1 < n && char.IsDigit(s[i + 1]) && !(i > 0 && (PyIsWord(s[i - 1]) || s[i - 1] == '.')))
            {
                int d = i + 1; while (d < n && char.IsDigit(s[d])) d++;
                int k = d; while (k < n && PyIsSpace(s[k])) k++;
                int end = -1;
                // 分支一：可选运算符后接 = 且其后不是 =；运算符可有可无（先试有）
                int op = k < n && k + 1 < n && ((s[k] == '<' && s[k + 1] == '<') || (s[k] == '>' && s[k + 1] == '>')) ? 2 : k < n && "-+*/%&|^".IndexOf(s[k]) >= 0 ? 1 : 0;
                if (op > 0 && k + op < n && s[k + op] == '=' && !(k + op + 1 < n && s[k + op + 1] == '=')) end = k + op + 1;
                else if (k < n && s[k] == '=' && !(k + 1 < n && s[k + 1] == '=')) end = k + 1;
                // 分支二：++ / --
                else if (k + 1 < n && (s[k] == '+' || s[k] == '-') && s[k + 1] == s[k]) end = k + 2;
                if (end >= 0) { yield return s.Substring(i, d - i); i = end; continue; }
            }
            if ((c == '+' || c == '-') && i + 1 < n && s[i + 1] == c)
            {
                // 分支三：++ / -- 后接（空白）_数字，且数字后不是词字符
                int k = i + 2; while (k < n && PyIsSpace(s[k])) k++;
                if (k + 1 < n && s[k] == '_' && char.IsDigit(s[k + 1]))
                {
                    int d = k + 1; while (d < n && char.IsDigit(s[d])) d++;
                    if (!(d < n && PyIsWord(s[d]))) { yield return s.Substring(k, d - k); i = d; continue; }
                }
            }
            i++;
        }
    }

    static readonly string[] Kw = { "uint", "int", "ushort", "short", "ulong", "long", "bool" };

    /// <summary>c1_guard.DEFINITION 的 findall（\b(u?int|u?short|u?long|bool)\s+(_\d+)\s*=\s*([^;]+);），手写：从「空白后的 _数字」往回认类型词（正则版在每个可能的类型词首字母试）。
    ///   回溯分析：\s+、_\d+、= 前的 \s* 都只能取最长；类型词带 u 而 u 前是词字符时，从 i 起头也过不了 \b，整个不匹配；
    ///   = 后 \s* 取最长，若紧跟 ; 则退一个空白给 [^;]+（文本是那个空白），没有空白则不匹配；匹配不重叠</summary>
    static IEnumerable<(string Kind, string Name, string Text)> Definitions(string s)
    {
        int n = s.Length, last = 0;
        for (int u = s.IndexOf('_'); u >= 0; u = u + 1 < n ? s.IndexOf('_', u + 1) : -1)
        {
            if (u == 0 || u + 1 >= n || !char.IsDigit(s[u + 1]) || !PyIsSpace(s[u - 1])) continue;
            int k = u - 1; while (k > 0 && PyIsSpace(s[k - 1])) k--;   // 类型词后的空白 [k, u)
            string kw = null;
            foreach (var t in Kw) if (k >= t.Length && string.CompareOrdinal(s, k - t.Length, t, 0, t.Length) == 0) { kw = t; break; }
            if (kw == null) continue;
            int a = k - kw.Length;
            if (a < last || (a > 0 && PyIsWord(s[a - 1]))) continue;
            int d = u + 1; while (d < n && char.IsDigit(s[d])) d++;
            int w = d; while (w < n && PyIsSpace(s[w])) w++;
            if (w >= n || s[w] != '=') continue;
            int eq = w; w++; while (w < n && PyIsSpace(s[w])) w++;
            int t0, semi;
            if (w < n && s[w] != ';') { semi = s.IndexOf(';', w); if (semi < 0) continue; t0 = w; }
            else if (w < n && w > eq + 1) { semi = w; t0 = w - 1; }
            else continue;
            yield return (kw, s.Substring(u, d - u), s.Substring(t0, semi - t0));
            last = semi + 1;
        }
    }

    /// <summary>c1_guard.definitions_of：只在声明处写过的整数临时量 → (类型, 定义式)</summary>
    static Dictionary<string, (string, string)> DefinitionsOf(string source)
    {
        var writes = new Dictionary<string, int>();
        foreach (var name in Assignments(source)) writes[name] = writes.GetValueOrDefault(name) + 1;
        var decls = new Dictionary<string, HashSet<(string, string)>>();
        var counts = new Dictionary<string, int>();
        foreach (var (kind, name, text) in Definitions(source))
        {
            if (!decls.TryGetValue(name, out var set)) decls[name] = set = new();
            set.Add((kind, PyStrip(text)));
            counts[name] = counts.GetValueOrDefault(name) + 1;
        }
        var o = new Dictionary<string, (string, string)>();
        foreach (var (name, d) in decls)
            if (d.Count == 1 && writes.GetValueOrDefault(name) == counts[name]) o[name] = d.First();
        return o;
    }

    sealed class Ctx
    {
        public readonly string Source;
        Dictionary<string, (string, string)> defs;
        public readonly Dictionary<string, object> TokCache = new();
        public Ctx(string s) { Source = s; }
        public Dictionary<string, (string, string)> Defs => defs ??= DefinitionsOf(Source);
        public Iv Eval(string index, int pyBase) { var iv = new Interval(Defs, TokCache, pyBase); var r = iv.Expression(index); iv.Done(); return r; }
    }

    static bool Proven(Ctx c, string index, int? span)
    {
        var v = c.Eval(index, PyBaseC1);
        return span != null && Known(v.L, v.H) && v.L >= 0 && 16 * (v.H + 1) <= span;
    }

    /// <summary>c1_guard.ACCESS 的 findall（\b[a-z]+_c1\)\._m0\[([^\]]+)\]），手写：按定长尾巴 "_c1)._m0[" 找（正则版要在每个小写词头试 [a-z]+ 再回溯）。
    ///   匹配的 [a-z]+ 必是尾巴前最长的小写串（再往里起头时前一字符是小写字母，\b 不成立），其前不能是词字符；下标取到第一个 ]、至少一个字符；匹配不重叠</summary>
    static IEnumerable<string> Accesses(string s)
    {
        const string tail = "_c1)._m0[";
        int last = 0;
        for (int p = s.IndexOf(tail, StringComparison.Ordinal); p >= 0; p = s.IndexOf(tail, p + 1, StringComparison.Ordinal))
        {
            int a = p; while (a > 0 && s[a - 1] >= 'a' && s[a - 1] <= 'z') a--;
            if (a == p || a < last || (a > 0 && PyIsWord(s[a - 1]))) continue;
            int q = p + tail.Length, e = s.IndexOf(']', q);
            if (e <= q) continue;   // 没有 ] 或下标为空
            yield return s.Substring(q, e - q);
            last = e + 1;
        }
    }

    /// <summary>c1_guard.judge_source：有 c1 读没证明在界内 → 键，否则 null</summary>
    static string JudgeSource(string name, Ctx c, int? span)
    {
        var accesses = new HashSet<string>();
        foreach (var index in Accesses(c.Source)) accesses.Add(index);
        if (accesses.Count == 0) return null;
        foreach (var index in accesses) if (!Proven(c, index, span)) return KeyOf(name);
        return null;
    }

    /// <summary>cb_extent.extents：{reg: 字节}</summary>
    static SortedDictionary<long, BigInteger> Extents(Ctx c, List<Binding> bindings)
    {
        var o = new SortedDictionary<long, BigInteger>();
        string source = c.Source;
        foreach (var b in bindings)
        {
            if (b.Kind != "cbuf" || b.Reg == null) continue;
            var rx = CbRx(b.MslName ?? throw new InvalidDataException("cbuf 绑定缺 msl_name"));
            int uses = rx[0].Count(source);
            var reads = new List<string>();
            foreach (Match m in rx[1].Matches(source)) reads.Add(m.Groups[1].Value);
            int declared = rx[2].Count(source);
            if (uses != reads.Count + declared) continue;
            BigInteger? high = -1;
            foreach (var index in new HashSet<string>(reads))
            {
                var v = c.Eval(index, PyBaseCb);
                if (!Known(v.L, v.H) || v.L < 0) { high = null; break; }
                high = Max(high.Value, v.H.Value);
            }
            if (high == null || 16 * (high + 1) >= MAX) continue;
            o[b.Reg.Value] = 16 * (high.Value + 1);
        }
        return o;
    }

    /// <summary>cb_extent.unwritten：从不写的 sbuf 槽，升序去重</summary>
    static List<long> Unwritten(string source, List<Binding> bindings)
    {
        var o = new SortedSet<long>();
        foreach (var b in bindings)
        {
            if (b.Kind != "sbuf" || b.Reg == null) continue;
            string name = "spvDescriptorSet0." + (b.MslName ?? throw new InvalidDataException("sbuf 绑定缺 msl_name"));
            var rx = SbRx(name); bool ok = true;
            foreach (Match m in rx[0].Matches(source))
            {
                int j = m.Index + m.Length;
                if ((m.Index > 0 && source[m.Index - 1] == '&') || !source.AsSpan(j).StartsWith(")._m0[", StringComparison.Ordinal)) { ok = false; break; }
                j += ")._m0".Length; int depth = 0;
                while (j < source.Length)
                {
                    char ch = source[j];
                    if (ch == '[') depth++;
                    else if (ch == ']') depth--;
                    else if (depth == 0 && !(ch == '.' || PyIsWord(ch))) break;
                    j++;
                }
                if (Write.Match(source, j).Success) { ok = false; break; }
            }
            if (ok && rx[1].Count(source) == rx[0].Count(source)) o.Add(b.Reg.Value);
        }
        return o.ToList();
    }

    /// <summary>cb_extent.both_of：(c1 结论：键或 null, 常量读范围表的行或 null)；definitions_of 每份 MSL 最多算一次</summary>
    public static (string C1, string Row) BothOf(string name, string msl, int? span, List<Binding> bindings)
    {
        var c = new Ctx(msl);
        string c1 = JudgeSource(name, c, span);
        if (bindings == null || bindings.Count == 0) return (c1, null);
        var toks = Extents(c, bindings).Select(kv => $"{kv.Key}:{kv.Value}").Concat(Unwritten(msl, bindings).Select(r => $"s{r}")).ToList();
        return (c1, toks.Count > 0 ? name[..^"_b.metal".Length] + "\t" + string.Join(" ", toks) : null);
    }

    public static (string C1, string Row) BothOf(Job j) => BothOf(j.Name, j.Msl, j.Span, j.Bindings);

    /// <summary>全部任务并行跑 BothOf（结果按任务顺序；替 Python 的 multiprocessing 池）</summary>
    public static (string C1, string Row)[] BothAll(IReadOnlyList<Job> jobs, int nj)
    {
        var res = new (string, string)[jobs.Count];
        Parallel.For(0, jobs.Count, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, nj) }, i => res[i] = BothOf(jobs[i]));
        return res;
    }

    /// <summary>两张表（cb_extent.run_both 的收尾：c1_guard.write_table + cb_extent.write_table）→ 两行摘要。head：dmsh_chain.table_head</summary>
    public static string[] WriteTables(IReadOnlyList<(string C1, string Row)> res, string head, string c1Out, string cbOut)
    {
        string stamp = DateTimeOffset.Now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);   // isoformat(timespec="seconds")
        var keys = res.Where(r => r.C1 != null).Select(r => r.C1).ToList();
        var rows = res.Where(r => r.Row != null).Select(r => r.Row).ToList();
        var sb = new StringBuilder();
        sb.Append(head).Append(' ').Append(stamp).Append('\n');
        foreach (var k in keys) sb.Append(k).Append('\n');
        WriteFile(c1Out, sb.ToString());
        long slots = rows.Sum(r => (long)r.Count(ch => ch == ':')), ro = rows.Sum(r => (long)SlotRo.Count(r.Split('\t', 2)[1]));
        sb.Clear();
        sb.Append(head).Append(' ').Append(stamp).Append('\n');
        sb.Append("# shader key, then reg:bytes for each uniform slot whose reads stay inside its first bytes, and s<reg> for each storage slot it never writes (cb_extent.py)\n");
        foreach (var r in rows) sb.Append(r).Append('\n');
        WriteFile(cbOut, sb.ToString());
        return new[] { $"not proven bounded: {keys.Count} shaders", $"bounded uniform reads: {slots} slots; storage slots never written: {ro}; {rows.Count} shaders" };
    }

    static void WriteFile(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
        File.WriteAllBytes(path, new UTF8Encoding(false).GetBytes(text));
    }

    /// <summary>对拍入口：dsh_batch --c1cb &lt;目录&gt; [-j N] [--tables &lt;c1 tsv&gt; &lt;cb tsv&gt; &lt;表头&gt;]
    ///   目录里的 .metal / .json（dsh_batch 翻译产物）→ 每个 .metal 一行「文件名 \t c1 结论或空 \t cb 行或空」，按文件名排；
    ///   给 --tables 时另写两张表、摘要两行进标准错误</summary>
    public static int Cli(string[] argv)
    {
        if (argv.Length < 1) { Console.Error.WriteLine("用法：dsh_batch --c1cb <目录> [-j N] [--tables <c1 tsv> <cb tsv> <表头>]"); return 2; }
        string dir = argv[0]; int nj = Environment.ProcessorCount; string[] tables = null; Ticker tk = null;
        for (int i = 1; i < argv.Length; i++)
        {
            if (argv[i] == "-j" && i + 1 < argv.Length) nj = int.Parse(argv[++i], CultureInfo.InvariantCulture);
            else if (argv[i] == "--tables" && i + 3 < argv.Length) { tables = argv[(i + 1)..(i + 4)]; i += 3; }
            else if (argv[i] == "--tick" && i + 3 < argv.Length)   // 出包进度：--tick <阶段> <此前已算> <全遍支数>（Build.C1CbChild 分批接力）
            { tk = new Ticker(argv[i + 1], int.Parse(argv[i + 3], CultureInfo.InvariantCulture), int.Parse(argv[i + 2], CultureInfo.InvariantCulture), activity: false); i += 3; }
            else { Console.Error.WriteLine($"C1Cb：不认识的参数 {argv[i]}"); return 2; }
        }
        // 逐支读（11-02 出包内存）：原先先把目录里全部 .metal / .json 读进字典、再一次性建出全部任务（每个带整段 MSL），8 万键款子进程 13 GB；现在只列名字，并行循环里每支才读自己的两份
        var metals = Directory.GetFiles(dir).Select(Path.GetFileName).Where(n => n.EndsWith(".metal", StringComparison.Ordinal) && !n.StartsWith("._", StringComparison.Ordinal)).OrderBy(n => n, StringComparer.Ordinal).ToList();
        var jobs = metals;
        Job Load(string n) { var j = Path.Combine(dir, KeyOf(n) + "_b.json"); return JobOf(n, File.ReadAllBytes(Path.Combine(dir, n)), File.Exists(j) ? File.ReadAllBytes(j) : null); }
        // 逐文件接住异常（Python 同样会抛的情形：<< 位数过大等）记成「!异常」行，对拍两边都这样记；出库路径（BothAll）照常抛
        var res = new (string C1, string Row)[jobs.Count]; var err = new string[jobs.Count];
        Parallel.For(0, jobs.Count, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, nj) }, i =>
        {
            try { res[i] = BothOf(Load(jobs[i])); } catch (Exception e) when (e is OverflowException || e is OutOfMemoryException) { err[i] = "!" + e.GetType().Name; }
            tk?.Step();
        });
        tk?.Dispose();
        var outw = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false), 1 << 20) { NewLine = "\n" };
        for (int i = 0; i < jobs.Count; i++) outw.Write(jobs[i] + "\t" + (err[i] ?? res[i].C1 ?? "") + "\t" + (err[i] != null ? "" : res[i].Row ?? "") + "\n");
        outw.Flush();
        if (err.Any(e => e != null)) { Console.Error.WriteLine($"C1Cb：{err.Count(e => e != null)} 个文件抛异常，不写表"); return 1; }
        if (tables != null) foreach (var s in WriteTables(res, tables[2], tables[0], tables[1])) Console.Error.WriteLine(s);
        Console.Error.WriteLine($"C1Cb：{jobs.Count} 个 .metal，Interval 最深 {MaxFrames} 帧（进程池里 Python 上限约 {PyLimit - PyBaseC1}～{PyLimit - PyBaseCb}）");
        return 0;
    }
}
