// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace S2A.Dsh
{
    /// <summary>Bound the optimizer's function size, without changing the dispatch or its control flow.
    /// Only the line-oriented SPIRV-Cross compute dialect is accepted. Unknown syntax leaves the source alone.</summary>
    public static class DshOutline
    {
        const int KernelLines = 8192, MinLines = 128, MaxLines = 6000;
        const string Id = @"[A-Za-z_]\w*";
        static readonly Regex Entry = new(@"^kernel void main0\((.*)\)$", RegexOptions.CultureInvariant);
        static readonly Regex Decl = new(@"^(?<type>(?:(?:constant|device|threadgroup|thread|const)\s+)*" + Id + @"(?:<[^<>;{}]+>)?\s*[*&]?)\s+(?<name>" + Id + @")\s*(?<end>=|;|$)", RegexOptions.CultureInvariant);
        static readonly Regex Word = new(@"\b" + Id + @"\b", RegexOptions.CultureInvariant);
        static readonly Regex Exit = new(@"\b(return|break|continue|goto|discard_fragment|threadgroup_barrier|simdgroup_barrier|simd_\w*|quad_\w*)\b", RegexOptions.CultureInvariant);
        static readonly Regex Attribute = new(@"\s*\[\[[^\]]*\]\]", RegexOptions.CultureInvariant);
        sealed record Variable(string Name, string Type, int Line, Block Scope);
        sealed class Block
        {
            public int Start, End;
            public Block Parent;
            public List<Block> Children = new();
            public bool Conditional;
        }

        static List<string> Parameters(string text)
        {
            var parts = new List<string>(); int start = 0, depth = 0;
            for (int i = 0; i < text.Length; i++)
            {
                if (text[i] == '<') depth++;
                if (text[i] == '>') depth--;
                if (text[i] == ',' && depth == 0) { parts.Add(text[start..i].Trim()); start = i + 1; }
            }
            parts.Add(text[start..].Trim()); return parts;
        }

        static bool Ancestor(Block outer, Block inner)
        {
            for (var b = inner; b != null; b = b.Parent) if (b == outer) return true;
            return false;
        }

        static string Parameter(Variable v)
        {
            // References retain storage identity, including when another helper takes a pointer by reference.
            string type = v.Type;
            if (type.EndsWith('*')) return type + " thread& " + v.Name;
            if (!Regex.IsMatch(type, @"\b(constant|device|threadgroup|thread)\b")) type = "thread " + type;
            return type.TrimEnd('&').TrimEnd() + "& " + v.Name;
        }

        /// <summary>Outline disjoint closed if bodies in a large main0 compute entry.
        /// Entry attributes, barriers, exits, local lifetimes and branch conditions remain at their original call sites.</summary>
        public static string Compute(string msl)
        {
            if (msl.Length < KernelLines || msl.Contains("s2a_outline_", StringComparison.Ordinal) || msl.Contains("/*", StringComparison.Ordinal)) return msl;
            var lines = msl.Split('\n');
            var code = lines.Select(line => line.Contains("//", StringComparison.Ordinal) ? line[..line.IndexOf("//", StringComparison.Ordinal)] : line).ToArray();
            // Macros outside the entry can hide references to its locals (or change name lookup after extraction).
            // Only the generator's standard includes / diagnostic pragmas need no preprocessor analysis.
            foreach (string line in code)
                if (line.Contains("%:", StringComparison.Ordinal) || line.Contains('#') && !Regex.IsMatch(line,
                    @"^\s*#\s*(?:include\s*<(?:metal_stdlib|metal_atomic|simd/simd\.h)>|pragma\s+clang\s+diagnostic\s+(?:push|pop|ignored\s+""[^""]*""))\s*$")) return msl;
            int entry = -1; Match signature = Match.Empty;
            for (int i = 0; i < lines.Length; i++)
            {
                var m = Entry.Match(code[i].TrimEnd());
                if (!m.Success) continue;
                if (entry >= 0) return msl;
                entry = i; signature = m;
            }
            if (entry < 0 || entry + 1 >= lines.Length || lines[entry + 1] != "{") return msl;
            var root = new Block { Start = entry + 1 }; var current = root;
            var blocks = new List<Block>(); var variables = new Dictionary<string, Variable>(StringComparer.Ordinal);
            bool Add(string declaration, int line, Block scope)
            {
                var m = Decl.Match(declaration);
                if (!m.Success || variables.ContainsKey(m.Groups["name"].Value)) return false;
                string name = m.Groups["name"].Value, type = m.Groups["type"].Value.Trim();
                // A const pointer has different reference semantics, and raw C arrays need declarator rewriting.
                if (type.Contains('*') && !Regex.IsMatch(type, @"^(constant|device|threadgroup|thread)\s+(?:const\s+)?\w+\s*\*$")) return false;
                int depth = 0;
                foreach (char c in declaration[(m.Index + m.Length)..])
                {
                    if (c is '(' or '[' or '{') depth++;
                    if (c is ')' or ']' or '}') depth--;
                    if (c == ',' && depth == 0) return false; // Multiple declarators are outside this dialect.
                }
                variables.Add(name, new Variable(name, type, line, scope)); return true;
            }
            foreach (string p in Parameters(signature.Groups[1].Value))
                if (!Add(Attribute.Replace(p, ""), entry, root)) return msl;
            int end = -1;
            for (int i = entry + 2; i < lines.Length; i++)
            {
                string s = code[i].Trim();
                // Generated sources need no strings, block comments or directives inside an entry.
                // Reject instead of interpreting braces/identifiers inside another language construct.
                if (s.Contains("/*", StringComparison.Ordinal) || s.Contains('"') || s.StartsWith('#')) return msl;
                if (s == "{")
                {
                    var b = new Block { Start = i, Parent = current, Conditional = code[i - 1].TrimStart().StartsWith("if (", StringComparison.Ordinal) };
                    current.Children.Add(b); blocks.Add(b); current = b; continue;
                }
                if (s == "}" || s.StartsWith("} while (", StringComparison.Ordinal))
                {
                    current.End = i;
                    if (current == root) { end = i; break; }
                    current = current.Parent; continue;
                }
                // Initializers may contain {} but may not open a control-flow scope on the same line.
                if (s.StartsWith("if ", StringComparison.Ordinal) || s is "else" or "do" || s.StartsWith("while (", StringComparison.Ordinal))
                {
                    if (i + 1 >= lines.Length || lines[i + 1].Trim() != "{") return msl;
                    continue;
                }
                if (s.StartsWith("for ", StringComparison.Ordinal) || s.StartsWith("switch ", StringComparison.Ordinal) || Regex.IsMatch(s, @"^(?:case\b|default\s*:|" + Id + @"\s*:(?!:))")) return msl;
                var decl = Decl.Match(s);
                if (decl.Success) { if (!Add(s, i, current)) return msl; continue; }
                // Restrict other lines to generated expressions/statements. This rejects unsupported declarations,
                // including raw arrays, volatile values, multi-declarators and declarations in loop headers.
                if (Regex.IsMatch(s, @"^(?:const\s+|volatile\s+|thread\s+|threadgroup\s+|device\s+|constant\s+|" + Id + @"\s+" + Id + @"\b)") && !s.StartsWith("return", StringComparison.Ordinal)) return msl;
                if (s.Contains('{') || s.Contains('}')) return msl;
            }
            if (end < 0 || end - entry < KernelLines) return msl;
            string body = string.Join("\n", code[(entry + 2)..end]);
            foreach (var v in variables.Values.Where(v => v.Type.EndsWith('*')))
                if (Regex.IsMatch(body, @"\b" + Regex.Escape(v.Name) + @"\s*(?:=(?!=)|\+=|-=|\+\+|--)") || Regex.IsMatch(body, @"(?:\+\+|--)\s*\b" + Regex.Escape(v.Name) + @"\b")) return msl;
            var sharedLocals = variables.Values.Where(v => Regex.IsMatch(v.Type, @"\bthreadgroup\b")).ToList();
            var selected = new List<(Block B, List<Variable> Captures)>();
            foreach (var b in blocks.Where(b => b.Conditional && b.End - b.Start > MinLines && b.End - b.Start <= MaxLines + 1).OrderByDescending(b => b.End - b.Start).ThenBy(b => b.Start))
            {
                if (selected.Any(x => b.Start < x.B.End && x.B.Start < b.End)) continue;
                string text = string.Join("\n", code[(b.Start + 1)..b.End]);
                if (Exit.IsMatch(text)) continue;
                if (sharedLocals.Any(v => v.Line > b.Start && v.Line < b.End)) continue;
                var captures = new Dictionary<string, Variable>(StringComparer.Ordinal); bool valid = true;
                foreach (Match word in Word.Matches(text))
                {
                    // A struct member is not a reference to a same-named local variable.
                    int before = word.Index - 1; while (before >= 0 && char.IsWhiteSpace(text[before])) before--;
                    if (before >= 0 && text[before] == '.') continue;
                    if (!variables.TryGetValue(word.Value, out var v)) continue;
                    if (v.Line > b.Start && v.Line < b.End) continue;
                    if (v.Line >= b.Start || !Ancestor(v.Scope, b)) { valid = false; break; }
                    captures.TryAdd(v.Name, v);
                }
                if (valid) selected.Add((b, captures.Values.OrderBy(v => v.Name, StringComparer.Ordinal).ToList()));
            }
            if (selected.Count == 0) return msl;
            selected.Sort((a, b) => a.B.Start.CompareTo(b.B.Start));
            var helpers = new StringBuilder(); var calls = new Dictionary<int, (int End, string Call)>();
            for (int i = 0; i < selected.Count; i++)
            {
                var (b, captures) = selected[i]; string name = "s2a_outline_" + i;
                helpers.Append("static __attribute__((noinline)) void ").Append(name).Append('(').AppendJoin(", ", captures.Select(Parameter)).Append(")\n{\n");
                for (int j = b.Start + 1; j < b.End; j++) helpers.Append(lines[j]).Append('\n');
                helpers.Append("}\n\n");
                string indent = lines[b.Start][..(lines[b.Start].Length - lines[b.Start].TrimStart().Length)];
                calls[b.Start + 1] = (b.End, indent + "    " + name + "(" + string.Join(", ", captures.Select(v => v.Name)) + ");");
            }
            var output = new StringBuilder();
            for (int i = 0; i < lines.Length; i++)
            {
                if (i == entry) output.Append(helpers);
                if (calls.TryGetValue(i, out var edit)) { output.Append(edit.Call).Append('\n'); i = edit.End - 1; continue; }
                output.Append(lines[i]); if (i + 1 < lines.Length) output.Append('\n');
            }
            return output.ToString();
        }
    }
}
