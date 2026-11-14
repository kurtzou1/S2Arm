using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;

namespace S2A.Services
{
    // FPSLocker 帧率配置的运行时部分（11-12 维护者：帧率补丁能打的都打上）：出包时 pack/fpslocker.py 把每构建号一份的 FPSLocker YAML 拆成
    //   静态部分（汇编 / 字节写入，编进包、跟「60 帧」开关）与这里的 fpslocker.json（ALL_FPS：按目标帧率定期写的地址与值）。
    //   本线程每秒看一次「60 帧」此刻是否真在生效（s2a_fps_live）：生效时按 60 帧求值写一遍；从生效变成不生效时按 30 帧写一遍（多数配置是帧时间 / 帧率上限公式，写回原帧率）。
    //   地址 [MAIN|HEAP|ALIAS, 偏移, 偏移…]：区基址 + 第一个偏移，之后每级先读 8 字节指针再加下一个偏移（FPSLocker 同义；VARIABLE 出包时已换成 MAIN 偏移）。
    //   读写复用金手指的内存适配（只读已映射页、只写可写页）；地址没就绪（堆还没分配）跳过这一条、下一秒再试。
    //   表达式按 FPSLocker FORMAT.md：FPS_TARGET / FRAMETIME_TARGET / VSYNC_TARGET / FPS_LOCK_TARGET、四则与括号、TruncDec 与常用数学函数
    public static unsafe class FpsLocker
    {
        private static Thread _thread;

        public static void Start()
        {
            if (_thread != null) return;
            try { _ = Imports.s2a_cpatch_tables_dir(); }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return; }   // 没有原生核心（单测 / 工具宿主）
            _thread = new Thread(Wait) { Name = "S2A.FpsLocker", IsBackground = true, Priority = ThreadPriority.BelowNormal };
            _thread.Start();
        }

        // 服务起来时主程序可能还没装载（表目录还没登记）：每秒找一次 fpslocker.json，找到才加载；这款没有就一直闲着（每秒一次 stat）
        private static void Wait()
        {
            for (; ; Thread.Sleep(1000))
            {
                string dir = Marshal.PtrToStringUTF8((IntPtr)Imports.s2a_cpatch_tables_dir());
                if (string.IsNullOrEmpty(dir)) continue;
                string path = Path.Combine(dir, "fpslocker.json");
                if (!File.Exists(path)) continue;
                List<Entry> entries;
                try { entries = Load(File.ReadAllText(path)); }
                catch (Exception e) { Console.Error.WriteLine($"【红】FPSLocker：读不了 {path}：{e.Message}"); return; }
                if (entries.Count == 0) return;
                Console.Error.WriteLine($"FPSLocker：{entries.Count} 条帧率写入，跟 60 帧开关");
                Run(entries);
                return;
            }
        }

        public sealed class Entry
        {
            public string Type = "", ValueType = "", CompareType = "", CompareValueType = "";
            public List<JsonElement> Address = new(), CompareAddress;
            public JsonElement Value, CompareValue;
        }

        public static List<Entry> Load(string json)
        {
            var list = new List<Entry>();
            using var doc = JsonDocument.Parse(json);
            foreach (var unit in doc.RootElement.GetProperty("units").EnumerateArray())
                foreach (var e in unit.GetProperty("all_fps").EnumerateArray())
                {
                    var x = new Entry { Type = e.GetProperty("type").GetString() ?? "" };
                    if (e.TryGetProperty("value_type", out var vt)) x.ValueType = vt.GetString() ?? "";
                    if (e.TryGetProperty("address", out var a)) foreach (var v in a.EnumerateArray()) x.Address.Add(v.Clone());
                    if (e.TryGetProperty("value", out var val)) x.Value = val.Clone();
                    if (e.TryGetProperty("compare_address", out var ca)) { x.CompareAddress = new(); foreach (var v in ca.EnumerateArray()) x.CompareAddress.Add(v.Clone()); }
                    if (e.TryGetProperty("compare_type", out var ct)) x.CompareType = ct.GetString() ?? "";
                    if (e.TryGetProperty("compare_value_type", out var cvt)) x.CompareValueType = cvt.GetString() ?? "";
                    if (e.TryGetProperty("compare_value", out var cv)) x.CompareValue = cv.Clone();
                    list.Add(x);
                }
            return list;
        }

        private static void Run(List<Entry> entries)
        {
            bool was = false;
            var process = new Cheats.GameProcess();
            for (; ; Thread.Sleep(1000))
            {
                bool live;
                try { live = Imports.s2a_fps_live() != 0; } catch (Exception) { return; }
                if (!live && !was) continue;
                double target = live ? 60 : 30;
                int ok = 0, skip = 0;
                foreach (var e in entries)
                {
                    try { if (Apply(process, e, target)) ok++; else skip++; }
                    catch (Exception) { skip++; }   // 地址没就绪 / 读写落空：这一条下一秒再试
                }
                if (live != was) Console.Error.WriteLine($"FPSLocker：按 {target} 帧写 {ok} 条（{skip} 条地址未就绪）");
                was = live;
            }
        }

        internal static bool Apply(Cheats.GameProcess p, Entry e, double target)
        {
            if (e.Type is "compare" or "evaluate_compare")
            {
                ulong ca = Resolve(p, e.CompareAddress);
                double cur = ReadAs(p, ca, e.CompareValueType);
                double want = e.Type == "evaluate_compare" ? Eval(Str(e.CompareValue), target) : Num(e.CompareValue);
                bool hit = e.CompareType switch { "<" => cur < want, "<=" => cur <= want, ">" => cur > want, ">=" => cur >= want, "==" => cur == want, "!=" => cur != want, _ => false };
                if (!hit) return true;
            }
            ulong a = Resolve(p, e.Address);
            var values = new List<double>();
            if (e.Value.ValueKind == JsonValueKind.Array) foreach (var v in e.Value.EnumerateArray()) values.Add(e.Type.StartsWith("evaluate") ? Eval(Str(v), target) : Num(v));
            else values.Add(e.Type.StartsWith("evaluate") ? Eval(Str(e.Value), target) : Num(e.Value));
            int size = Size(e.ValueType);
            for (int i = 0; i < values.Count; i++) WriteAs(p, a + (ulong)(i * size), e.ValueType, values[i]);
            return true;
        }

        private static string Str(JsonElement v) => v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText();
        private static double Num(JsonElement v) => v.ValueKind == JsonValueKind.Number ? v.GetDouble() : double.Parse(v.GetString() ?? "0", CultureInfo.InvariantCulture);

        internal static ulong Resolve(Cheats.GameProcess p, List<JsonElement> addr)
        {
            Cheats.Layout* l = Cheats.Imports.s2a_layout_get();
            string region = addr[0].GetString();
            ulong a = region switch
            {
                "MAIN" => Cheats.Imports.s2a_main_base(),
                "HEAP" => l->HeapBase,
                "ALIAS" => l->AliasBase,
                _ => throw new InvalidDataException("地址区 " + region),
            };
            if (a == 0) throw new InvalidOperationException("区基址未就绪");
            for (int i = 1; i < addr.Count; i++)
            {
                if (i > 1) a = p.ReadMemory<ulong>(a);
                a += (ulong)addr[i].GetInt64();
            }
            return a;
        }

        private static int Size(string t) => t switch { "int8" or "uint8" => 1, "int16" or "uint16" => 2, "int32" or "uint32" or "float" => 4, _ => 8 };

        private static double ReadAs(Cheats.GameProcess p, ulong a, string t) => t switch
        {
            "int8" => p.ReadMemory<sbyte>(a), "uint8" => p.ReadMemory<byte>(a), "int16" => p.ReadMemory<short>(a), "uint16" => p.ReadMemory<ushort>(a),
            "int32" => p.ReadMemory<int>(a), "uint32" => p.ReadMemory<uint>(a), "int64" => p.ReadMemory<long>(a), "uint64" => p.ReadMemory<ulong>(a),
            "float" => p.ReadMemory<float>(a), "double" => p.ReadMemory<double>(a), _ => throw new InvalidDataException("类型 " + t),
        };

        private static void WriteAs(Cheats.GameProcess p, ulong a, string t, double v)
        {
            switch (t)
            {
                case "int8": p.WriteMemory(a, (sbyte)v); break;
                case "uint8": p.WriteMemory(a, (byte)v); break;
                case "int16": p.WriteMemory(a, (short)v); break;
                case "uint16": p.WriteMemory(a, (ushort)v); break;
                case "int32": p.WriteMemory(a, (int)v); break;
                case "uint32": p.WriteMemory(a, (uint)v); break;
                case "int64": p.WriteMemory(a, (long)v); break;
                case "uint64": p.WriteMemory(a, (ulong)v); break;
                case "float": p.WriteMemory(a, (float)v); break;
                case "double": p.WriteMemory(a, v); break;
                default: throw new InvalidDataException("类型 " + t);
            }
        }

        // ---- 表达式（FPSLocker 用 TinyExpr：数字、全局量、+ - * / ^、括号、函数）----
        public static double Eval(string s, double fpsTarget)
        {
            var g = new Dictionary<string, double>(StringComparer.Ordinal)
            {
                ["FPS_TARGET"] = fpsTarget,
                ["FRAMETIME_TARGET"] = 1000 / fpsTarget,
                ["VSYNC_TARGET"] = Math.Max(1, Math.Floor(60 / fpsTarget)),
                ["FPS_LOCK_TARGET"] = fpsTarget == 60 ? fpsTarget + 2 : fpsTarget,   // 目标等于刷新率时 +2（FORMAT.md：避免人为限帧抖动）
            };
            int i = 0;
            double v = Expr(s, ref i, g);
            Skip(s, ref i);
            if (i != s.Length) throw new FormatException("表达式多余内容：" + s[i..]);
            return v;
        }

        private static void Skip(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        private static double Expr(string s, ref int i, Dictionary<string, double> g)
        {
            double v = Term(s, ref i, g);
            for (; ; )
            {
                Skip(s, ref i);
                if (i < s.Length && (s[i] == '+' || s[i] == '-')) { char op = s[i++]; double r = Term(s, ref i, g); v = op == '+' ? v + r : v - r; }
                else return v;
            }
        }

        private static double Term(string s, ref int i, Dictionary<string, double> g)
        {
            double v = Power(s, ref i, g);
            for (; ; )
            {
                Skip(s, ref i);
                if (i < s.Length && (s[i] == '*' || s[i] == '/' || s[i] == '%')) { char op = s[i++]; double r = Power(s, ref i, g); v = op == '*' ? v * r : op == '/' ? v / r : v % r; }
                else return v;
            }
        }

        private static double Power(string s, ref int i, Dictionary<string, double> g)
        {
            double v = Unary(s, ref i, g);
            Skip(s, ref i);
            if (i < s.Length && s[i] == '^') { i++; return Math.Pow(v, Power(s, ref i, g)); }
            return v;
        }

        private static double Unary(string s, ref int i, Dictionary<string, double> g)
        {
            Skip(s, ref i);
            if (i < s.Length && s[i] == '-') { i++; return -Unary(s, ref i, g); }
            if (i < s.Length && s[i] == '+') { i++; return Unary(s, ref i, g); }
            return Atom(s, ref i, g);
        }

        private static double Atom(string s, ref int i, Dictionary<string, double> g)
        {
            Skip(s, ref i);
            if (i >= s.Length) throw new FormatException("表达式不完整");
            if (s[i] == '(') { i++; double v = Expr(s, ref i, g); Skip(s, ref i); if (i >= s.Length || s[i] != ')') throw new FormatException("缺右括号"); i++; return v; }
            if (char.IsDigit(s[i]) || s[i] == '.')
            {
                int j = i;
                if (s[i] == '0' && i + 1 < s.Length && (s[i + 1] == 'x' || s[i + 1] == 'X')) { j = i + 2; while (j < s.Length && Uri.IsHexDigit(s[j])) j++; double h = Convert.ToInt64(s[(i + 2)..j], 16); i = j; return h; }
                while (j < s.Length && (char.IsDigit(s[j]) || s[j] == '.' || s[j] == 'e' || s[j] == 'E' || ((s[j] == '-' || s[j] == '+') && (s[j - 1] == 'e' || s[j - 1] == 'E')))) j++;
                double n = double.Parse(s[i..j], CultureInfo.InvariantCulture); i = j; return n;
            }
            if (char.IsLetter(s[i]) || s[i] == '_')
            {
                int j = i; while (j < s.Length && (char.IsLetterOrDigit(s[j]) || s[j] == '_')) j++;
                string name = s[i..j]; i = j; Skip(s, ref i);
                if (i < s.Length && s[i] == '(')
                {
                    i++; var args = new List<double>();
                    Skip(s, ref i);
                    if (i < s.Length && s[i] == ')') i++;
                    else for (; ; ) { args.Add(Expr(s, ref i, g)); Skip(s, ref i); if (i < s.Length && s[i] == ',') { i++; continue; } if (i < s.Length && s[i] == ')') { i++; break; } throw new FormatException("函数参数没闭合"); }
                    return name switch
                    {
                        "TruncDec" => Math.Truncate(args[0] * Math.Pow(10, args[1])) / Math.Pow(10, args[1]),
                        "floor" => Math.Floor(args[0]), "ceil" => Math.Ceiling(args[0]), "round" => Math.Round(args[0], MidpointRounding.AwayFromZero),
                        "abs" => Math.Abs(args[0]), "sqrt" => Math.Sqrt(args[0]), "pow" => Math.Pow(args[0], args[1]),
                        "min" => Math.Min(args[0], args[1]), "max" => Math.Max(args[0], args[1]), "log" or "ln" => Math.Log(args[0]), "log10" => Math.Log10(args[0]),
                        "exp" => Math.Exp(args[0]), "fac" => throw new FormatException("不支持 fac"),
                        _ => throw new FormatException("函数 " + name),
                    };
                }
                if (g.TryGetValue(name, out var gv)) return gv;
                if (name == "pi") return Math.PI;
                if (name == "e") return Math.E;
                throw new FormatException("变量 " + name);
            }
            throw new FormatException("表达式看不懂：" + s[i..]);
        }

        internal static class Imports
        {
            private const string Lib = "s2a_native";
            [DllImport(Lib)] public static extern byte* s2a_cpatch_tables_dir();
            [DllImport(Lib)] public static extern int s2a_fps_live();
        }
    }
}
