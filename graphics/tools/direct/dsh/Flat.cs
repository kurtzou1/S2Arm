// 巨型着色器阶梯压平（translator/dmsh_flat.py + dmsh_build.py giant_fix 的移植，逐字同输出；t_dsh_fn.py 对照 giant_fix）。
// 设备上现编缺键时走这里：与出包同一份改形，三条路（出包库 / 链接版函数体 / 设备现编）的 MSL 一致。原理与实测见 dmsh_flat.py 文件头。
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace S2A.Dsh
{
    public static class DshFlat
    {
        const int GiantDepth = 40;   // 同 dmsh_build.py GIANT_DEPTH 缺省（设备上不读环境变量）
        abstract class Node { }
        sealed class Line : Node { public string S; public Line(string s) { S = s; } }
        sealed class If : Node { public string Cond; public List<Node> Then, Els; public If(string c, List<Node> t, List<Node> e) { Cond = c; Then = t; Els = e; } }
        sealed class Blk : Node { public string Head, Tail; public List<Node> Body; public Blk(string h, List<Node> b, string t) { Head = h; Body = b; Tail = t; } }

        static string Strip(string s) => s.Trim(' ', '\t', '\n', '\r', '\v', '\f');
        static readonly Regex s_if = new(@"^if \((.*)\)$", RegexOptions.CultureInvariant);

        static (List<Node>, int) Parse(string[] L, int i)
        {
            var o = new List<Node>();
            while (i < L.Length)
            {
                string s = Strip(L[i]);
                if (s == "}" || s.StartsWith("} while", StringComparison.Ordinal)) return (o, i);
                if (i + 1 < L.Length && Strip(L[i + 1]) == "{")
                {
                    var m = s_if.Match(s);
                    var (body, j) = Parse(L, i + 2);
                    if (j >= L.Length) throw new FormatException("unclosed block");
                    string tail = Strip(L[j]); j++;
                    if (m.Success && tail == "}")
                    {
                        List<Node> els = null;
                        if (j + 1 < L.Length && Strip(L[j]) == "else" && Strip(L[j + 1]) == "{")
                        {
                            (els, j) = Parse(L, j + 2);
                            if (j >= L.Length) throw new FormatException("unclosed else");
                            j++;
                        }
                        o.Add(new If(m.Groups[1].Value, body, els));
                    }
                    else o.Add(new Blk(s, body, tail));
                    i = j; continue;
                }
                if (s == "{")
                {
                    var (body, j) = Parse(L, i + 1);
                    if (j >= L.Length) throw new FormatException("unclosed block");
                    o.Add(new Blk("", body, Strip(L[j]))); i = j + 1; continue;
                }
                o.Add(new Line(s)); i++;
            }
            return (o, i);
        }

        static void Emit(List<Node> nodes, string ind, List<string> o)
        {
            foreach (var n in nodes)
            {
                if (n is Line l) o.Add(l.S.Length > 0 ? ind + l.S : "");
                else if (n is If f)
                {
                    o.Add($"{ind}if ({f.Cond})"); o.Add(ind + "{"); Emit(f.Then, ind + "    ", o); o.Add(ind + "}");
                    if (f.Els != null) { o.Add(ind + "else"); o.Add(ind + "{"); Emit(f.Els, ind + "    ", o); o.Add(ind + "}"); }
                }
                else
                {
                    var b = (Blk)n;
                    if (b.Head.Length > 0) o.Add(ind + b.Head);
                    o.Add(ind + "{"); Emit(b.Body, ind + "    ", o); o.Add(ind + b.Tail);
                }
            }
        }

        static readonly Regex s_cf = new(@"\breturn\b|\bbreak\b|\bcontinue\b|discard_fragment", RegexOptions.CultureInvariant);
        static readonly Regex s_lift = new(@"^(?:const\s+)?((?:float|int|uint|bool|half|short|ushort)[234]?)\s+(_\d+|s2a_g\d+)\s*=\s*(.+);$", RegexOptions.CultureInvariant);
        static readonly Regex s_decl = new(@"^(?:const\s+)?[A-Za-z_][\w<>:, ]*\s+(_\d+|s2a_g\d+)\s*(?:=|;|\[)", RegexOptions.CultureInvariant);

        static bool Stays(Node x) => x switch
        {
            Line l => !s_cf.IsMatch(l.S),
            If f => f.Then.All(Stays) && (f.Els == null || f.Els.All(Stays)),
            Blk b => b.Body.All(Stays),
            _ => false,
        };

        static List<Node> Flat(List<Node> nodes, int[] st)
        {
            var o = new List<Node>();
            foreach (var n in nodes)
            {
                if (n is Blk b) { b.Body = Flat(b.Body, st); o.Add(b); continue; }
                if (n is not If f) { o.Add(n); continue; }
                string guard = null; var cur = f;
                while (cur.Els == null && cur.Then.Count > 0 && cur.Then[^1] is If inner && inner.Els == null)
                {
                    var a = cur.Then.Take(cur.Then.Count - 1).ToList();
                    if (!a.All(Stays) || a.Any(x => x is Line l && s_decl.IsMatch(l.S) && !s_lift.IsMatch(l.S))) break;
                    var lift = new List<Node>(); var a2 = new List<Node>();
                    foreach (var x in a)
                    {
                        var m = x is Line l ? s_lift.Match(l.S) : Match.Empty;
                        if (m.Success) { lift.Add(new Line($"{m.Groups[1].Value} {m.Groups[2].Value} = {{}};")); a2.Add(new Line($"{m.Groups[2].Value} = {m.Groups[3].Value};")); }
                        else a2.Add(x);
                    }
                    string g = "s2a_g" + st[0]; st[0]++;
                    o.AddRange(lift); o.Add(new Line($"bool {g} = {(guard != null ? guard + " && " : "")}({cur.Cond});"));
                    if (a2.Count > 0) o.Add(new If(g, Flat(a2, st), null));
                    guard = g; cur = inner;
                }
                if (guard != null) o.Add(new If($"{guard} && ({cur.Cond})", Flat(cur.Then, st), cur.Els != null ? Flat(cur.Els, st) : null));
                else { f.Then = Flat(f.Then, st); if (f.Els != null) f.Els = Flat(f.Els, st); o.Add(f); }
            }
            return o;
        }

        static readonly Regex s_entry = new(@"^(?:\[\[[^\]]*\]\]\s*)*(?:fragment|vertex|kernel)\s+\S+\s+main0\w*\s*\(", RegexOptions.Multiline | RegexOptions.CultureInvariant);
        static readonly Regex s_main0 = new(@"^(?:\[\[[^\]]*\]\]\s*)*(?:fragment|vertex|kernel)\s+\S+\s+main0\s*\(", RegexOptions.Multiline | RegexOptions.CultureInvariant);

        /// <summary>同 dmsh_flat.flatten：每个 main0* 入口的尾部阶梯压平；入口解析回不到原文的照原样</summary>
        public static (string, int) Flatten(string msl)
        {
            var L = msl.Split('\n'); var res = new List<string>(); int i = 0; var st = new int[1];
            while (i < L.Length)
            {
                res.Add(L[i]);
                var em = s_entry.Match(L[i]);
                if (em.Success && em.Index == 0 && i + 1 < L.Length && L[i + 1] == "{")
                {
                    List<string> o; int j;
                    try
                    {
                        List<Node> body; (body, j) = Parse(L, i + 2);
                        if (j >= L.Length) throw new FormatException("unclosed entry");
                        o = new List<string>(); Emit(body, "    ", o);
                        if (!o.SequenceEqual(L[(i + 2)..j])) throw new FormatException("layout");
                        o = new List<string>(); Emit(Flat(body, st), "    ", o);
                    }
                    catch (FormatException) { i++; continue; }
                    res.Add("{"); res.AddRange(o); res.Add(L[j]); i = j + 1; continue;
                }
                i++;
            }
            return (string.Join("\n", res), st[0]);
        }

        /// <summary>同 dmsh_build.py entry_depth：main0 里独占一行的 { 最多套几层（函数自己的大括号算第 1 层）</summary>
        public static int EntryDepth(string msl)
        {
            var m = s_main0.Match(msl);
            if (!m.Success) return 0;
            int end = m.Index + m.Length, e = msl.IndexOf("\n}\n", end, StringComparison.Ordinal), d = 0, top = 0;
            foreach (var ln in msl[end..(e >= 0 ? e : msl.Length)].Split('\n'))
            {
                string s = Strip(ln);
                if (s == "{") { d++; top = Math.Max(top, d); }
                else if (s == "}" || s.StartsWith("} while", StringComparison.Ordinal)) d--;
            }
            return top;
        }

        /// <summary>同 dmsh_build.py giant_fix → (MSL, 压前深度, 压后深度)；不到阈值原样返回 (msl, 0, 0)</summary>
        public static (string, int, int) GiantFix(string msl)
        {
            int n = EntryDepth(msl);
            if (n < GiantDepth) return (DshOutline.Compute(msl), 0, 0);
            msl = Flatten(msl).Item1; int d = EntryDepth(msl);
            if (d >= GiantDepth) msl = s_entry.Replace(msl, m => "[[clang::optnone]] " + m.Value);
            return (DshOutline.Compute(msl), n, d);
        }
    }
}
