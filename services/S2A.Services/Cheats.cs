using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Tamper;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace S2A.Services
{
    // 金手指（11-09 B 方案）：玩家导入的 Atmosphere 格式 txt 放 $S2A_DOCS/cheats/（按游戏的文档根，多款容器 = Documents/games/<游戏号>），
    //   开关存同目录 enabled.txt（每行「文件名/条目名」），缺省全关；界面（ios/vpad_cheats.m）只改这两样，本线程每秒看一次改动时间就重载。
    // 指令编译与执行复用 Ryujinx 的 AtmosphereCompiler（完整 Atmosphere 指令集）；进程适配层换成 S2Arm 的游戏内存：
    //   读 = 已映射才读，写 = 页权限可写才写（代码页在苹果上是签名只读页，硬写会崩，改代码类条目记「改代码，不支持」并停用该条）。
    // 文件名是 16 位十六进制时按 Atmosphere 惯例当主程序构建号前 16 位，和本包主程序不符整份跳过（版本不对的地址写进去会把游戏写坏）。
    // 主代码（{…} 段）只在同文件有任一条开着时随之执行。每轮结果写 status.txt（「文件名/条目名<TAB>状态」）给界面显示。
    // 编进包的条目（11-12：出包时 pack/cpatch.py 把改代码的条目编成双路 + 槽，runtime/src/cpatch.c）：开关交原生层 s2a_cpatch_cheat，状态「生效中（编进游戏）」；
    //   同一条里写可写内存的行（主代码清 bss 等）照旧每帧由 Tamper 执行，写只读代码页的行已由包里的改动接管，这里跳过不报「改代码」。
    public static unsafe class Cheats
    {
        private const int TickMs = 1000 / 12;   // Atmosphere 每轮间隔 83 ms（Ryujinx TamperMachine 同值）
        private const int ReloadEveryTicks = 12;
        private static long _keys;
        private static Thread _thread;
        private static readonly HashSet<string> _native = new(StringComparer.Ordinal);   // 上次交原生层开着的编进包条目：文件删了 / 改名后要关掉

        public struct Entry
        {
            public string File, Name; public bool Master; public List<string> Lines;
            public string Key => File + "/" + Name;
        }

        // 一号手柄（或掌机）当前按键，输入泵每次提交 HID 后写（KeyPressConditional 用）
        public static void SetKeys(ControllerKeys keys) => Volatile.Write(ref _keys, (long)keys);

        // 解析一份 Atmosphere 金手指文本：[名字] 开普通条目，{名字} 开主代码，其余非空行是指令。格式坏（括号不闭合）整份作废返回 null
        public static List<Entry> Parse(string file, string text)
        {
            var list = new List<Entry>();
            Entry cur = default;
            foreach (string raw in text.Split('\n'))
            {
                string line = raw.Trim();
                if (line.Length == 0) continue;
                char open = line[0];
                if (open == '[' || open == '{')
                {
                    char close = open == '[' ? ']' : '}';
                    if (line.Length < 2 || line[^1] != close) return null;
                    if (cur.Lines != null && cur.Lines.Count > 0) list.Add(cur);
                    cur = new Entry { File = file, Name = line[1..^1].Trim(), Master = open == '{', Lines = new List<string>() };
                    if (cur.Name.Length == 0) cur.Name = cur.Master ? "主代码" : "未命名";
                }
                else
                {
                    cur.Lines ??= new List<string>();
                    if (cur.Name == null) cur = new Entry { File = file, Name = "未命名", Lines = cur.Lines };
                    cur.Lines.Add(line);
                }
            }
            if (cur.Lines != null && cur.Lines.Count > 0) list.Add(cur);
            return list;
        }

        // 文件名（去扩展名）是 16 位十六进制 → 必须是本包主程序构建号的前 16 位；不是十六进制名的文件不判（玩家自己起的名字）
        public static bool BuildMatches(string stem, string buildId)
        {
            if (stem.Length != 16) return true;
            foreach (char c in stem) if (!Uri.IsHexDigit(c)) return true;
            return !string.IsNullOrEmpty(buildId) && buildId.StartsWith(stem, StringComparison.OrdinalIgnoreCase);
        }

        public static void Start()
        {
            // 目录只经原生层 s2a_cheats_dir：有金手指界面的宿主（ios/vpad_cheats.m）装载时登记才回目录（文档根按 s2a_docs.h 唯一取法，与面板同一口径），
            //   没登记（Mac / 安卓）回空串 → 不起线程、不碰用户文稿夹。平台差异在平台层登记，这里不判平台
            if (_thread != null) return;
            string dir;
            // 没有原生核心（服务层单测、只带 C# 的工具宿主）= 没有金手指宿主，等同于没登记，不是错误
            try { dir = Marshal.PtrToStringUTF8((IntPtr)Imports.s2a_cheats_dir()); }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return; }
            if (string.IsNullOrEmpty(dir)) return;
            _thread = new Thread(() => Run(dir)) { Name = "S2A.Cheats", IsBackground = true, Priority = ThreadPriority.BelowNormal };
            _thread.Start();
        }

        private sealed class Item
        {
            public Entry Entry; public ITamperProgram Code; public string Status; public bool Off;
        }

        private static void Run(string dir)
        {
            var programs = new List<Item>();
            string seen = null;
            for (int tick = 0; ; tick++)
            {
                if (tick % ReloadEveryTicks == 0)
                {
                    string now = Stamp(dir);
                    if (now != seen)
                    {
                        seen = now;
                        try { programs = Load(dir); }
                        catch (Exception e) { Console.Error.WriteLine($"【红】金手指：重载失败 {e.GetType().Name}: {e.Message}"); programs = new List<Item>(); }
                        WriteStatus(dir, programs);
                        // 主程序还没装载（基址 0）：下一轮（约 1 秒后）再重载一次，不等玩家改文件
                        if (programs.Exists(p => p.Status == "游戏未装载")) seen = null;
                    }
                }
                bool any = false, changed = false;
                var keys = (ControllerKeys)Volatile.Read(ref _keys);
                foreach (Item p in programs)
                {
                    if (p.Off || p.Code == null || !p.Code.IsEnabled) continue;
                    any = true;
                    try
                    {
                        p.Code.Process.TamperedCodeMemory = false;
                        p.Code.Execute(keys);
                    }
                    catch (TamperExecutionException e) when (!p.Code.Process.TamperedCodeMemory)
                    {
                        // 起局早期游戏还没分配到目标地址，读写落空属正常：只记状态，不停用
                        if (p.Status != "地址未就绪") { p.Status = "地址未就绪"; changed = true; Console.Error.WriteLine($"金手指：{p.Entry.Key} {e.Message}"); }
                        continue;
                    }
                    catch (TamperExecutionException) { }   // 写到不可写页：下面按「改代码」停用
                    catch (Exception e)
                    {
                        p.Off = true; p.Status = "执行出错"; changed = true;
                        Console.Error.WriteLine($"【红】金手指：{p.Entry.Key} 执行出错，已停用：{e.GetType().Name}: {e.Message}");
                    }
                    if (p.Code.Process.TamperedCodeMemory)
                    {
                        p.Off = true; p.Status = "改代码，不支持"; changed = true;
                        Console.Error.WriteLine($"金手指：{p.Entry.Key} 要改代码页（苹果上是签名只读页），已停用");
                    }
                    else if (p.Status == "地址未就绪") { p.Status = "生效中"; changed = true; }
                }
                if (changed) WriteStatus(dir, programs);
                Thread.Sleep(any ? TickMs : TickMs * ReloadEveryTicks / 2);
                if (!any) tick += ReloadEveryTicks / 2 - 1;
            }
        }

        // 玩家可改的文件（*.txt，不含本线程自己写的 status.txt）的名字 + 改动时间签名：增删改任一份都变；目录不在 = 空串。
        //   不看目录自身的改动时间——写 status.txt（临时文件改名）会动目录时间，看它就会每秒自己触发一次重载（11-09 真机实测）
        private static string Stamp(string dir)
        {
            if (!Directory.Exists(dir)) return "";
            var parts = new List<string>();
            foreach (string f in Directory.EnumerateFiles(dir, "*.txt"))
            {
                string n = Path.GetFileName(f);
                if (n == "status.txt") continue;
                parts.Add(n + "@" + File.GetLastWriteTimeUtc(f).Ticks);
            }
            parts.Sort(StringComparer.Ordinal);
            return string.Join("|", parts);
        }

        private static List<Item> Load(string dir)
        {
            var programs = new List<Item>();
            if (!Directory.Exists(dir)) return programs;
            string enabledPath = Path.Combine(dir, "enabled.txt");
            var enabled = new HashSet<string>(File.Exists(enabledPath) ? File.ReadAllLines(enabledPath) : Array.Empty<string>(), StringComparer.Ordinal);
            enabled.Remove("");
            string buildId = Marshal.PtrToStringUTF8((IntPtr)Imports.s2a_main_build_id()) ?? "";
            Layout* l = Imports.s2a_layout_get();
            ulong exe = Imports.s2a_main_base();
            var process = new GameProcess();
            var files = new List<string>(Directory.EnumerateFiles(dir, "*.txt"));
            files.Sort(StringComparer.Ordinal);
            int nfiles = 0;
            seenNative = new HashSet<string>(StringComparer.Ordinal);
            foreach (string path in files)
            {
                string name = Path.GetFileName(path);
                if (name == "enabled.txt" || name == "status.txt") continue;
                nfiles++;
                string stem = Path.GetFileNameWithoutExtension(path);
                List<Entry> entries = Parse(name, File.ReadAllText(path));
                if (entries == null) { programs.Add(new Item { Entry = new Entry { File = name, Name = "*" }, Status = "格式不对", Off = true }); continue; }
                bool match = BuildMatches(stem, buildId) && (entries.Count == 0 || HeaderMatches(File.ReadAllText(path), buildId));
                bool fileOn = false;
                foreach (Entry e in entries) if (!e.Master && enabled.Contains(e.Key)) fileOn = true;
                entries = entries.FindAll(x => x.Master).Concat(entries.FindAll(x => !x.Master)).ToList();   // 主代码排在同文件普通条目之前执行（Atmosphere 约定），其余保持文件顺序
                foreach (Entry e in entries)
                {
                    var p = new Item { Entry = e };
                    bool on = e.Master ? fileOn : enabled.Contains(e.Key);
                    bool packed = match && exe != 0 && l != null && ToNative(e, on);
                    if (!match) { p.Status = "版本不符"; p.Off = true; }
                    else if (!on) p.Status = "关";
                    else if (exe == 0 || l == null) { p.Status = "游戏未装载"; p.Off = true; }
                    else
                    {
                        var compiler = new AtmosphereCompiler(MainVirtual, l->HeapBase, l->AliasBase, l->AslrBase, packed ? new GameProcess { Packed = true } : process);
                        p.Code = compiler.Compile(e.Key, e.Lines);
                        if (p.Code == null) { p.Status = "指令有误"; p.Off = true; }
                        else { p.Code.IsEnabled = true; p.Status = packed ? "生效中（编进游戏）" : "生效中"; }
                    }
                    programs.Add(p);
                }
            }
            foreach (string k in _native.Except(seenNative).ToList()) { int s = k.IndexOf('/'); ToNative(new Entry { File = k[..s], Name = k[(s + 1)..] }, false); }
            int n = 0; foreach (Item p in programs) if (p.Code != null) n++;
            Console.Error.WriteLine($"金手指：{nfiles} 份文件、{programs.Count} 条，开着 {n} 条（主程序构建号 {buildId}）");
            return programs;
        }

        private static HashSet<string> seenNative = new(StringComparer.Ordinal);

        // 文件头 [… BID=<构建号>] 写了构建号的（公开库的文件多这样写）：与本包主程序不符就整份不判（文件名不是构建号时靠它）
        public static bool HeaderMatches(string text, string buildId)
        {
            int nl = text.IndexOf('\n'); string head = nl < 0 ? text : text[..nl];
            int i = head.IndexOf("BID=", StringComparison.OrdinalIgnoreCase);
            if (i < 0) return true;
            int j = i + 4; while (j < head.Length && Uri.IsHexDigit(head[j])) j++;
            string bid = head[(i + 4)..j];
            return bid.Length < 16 || (!string.IsNullOrEmpty(buildId) && buildId.StartsWith(bid[..16], StringComparison.OrdinalIgnoreCase));
        }

        // 交原生层开关这条（编进包的才认）→ 编进包了
        private static bool ToNative(Entry e, bool on)
        {
            int r;
            byte[] f = Encoding.UTF8.GetBytes(e.File + "\0"), n = Encoding.UTF8.GetBytes(e.Name + "\0");
            try { fixed (byte* pf = f, pn = n) r = Imports.s2a_cpatch_cheat(pf, pn, on ? 1 : 0); }
            catch (Exception x) when (x is DllNotFoundException or EntryPointNotFoundException) { return false; }
            if (r == 1) { seenNative.Add(e.Key); if (on) _native.Add(e.Key); else _native.Remove(e.Key); }
            return r == 1;
        }

        private static void WriteStatus(string dir, List<Item> programs)
        {
            if (!Directory.Exists(dir)) return;
            var sb = new StringBuilder();
            foreach (Item p in programs) sb.Append(p.Entry.Key).Append('\t').Append(p.Status).Append('\n');
            string path = Path.Combine(dir, "status.txt"), tmp = path + ".tmp";
            try { File.WriteAllText(tmp, sb.ToString()); File.Move(tmp, path, true); }
            catch (IOException e) { Console.Error.WriteLine($"金手指：写 status.txt 失败 {e.Message}"); }
        }

        // 「main」区（Atmosphere 区号 0）：偏移按 Horizon 排布算——main 后面首尾相接 subsdk0..N、sdk（各自映像尾 4 KB 对齐），超出 main 的落进后面的模块；
        //   我们的模块按 2 MB 对齐各自摆放（runtime/src/loader.c），直接加 main 基址会写到别的模块的别处（11-13 实测：一款的帧率金手指写 main+0x24191F4，
        //   是 sdk 里的变量，原先落到 sdk 另一处）。编译时 main 区基址交虚拟基址 MainVirtual，读写时经原生层 s2a_main_region_va 换成该模块的真实地址。
        //   虚拟区间在 2^56 起，远高于任何真实用户态地址（< 2^47）；从游戏内存读出来的指针都是真实地址，不会落进虚拟区间被误换
        internal const ulong MainVirtual = 1UL << 56, MainSpan = 1UL << 40;   // Atmosphere 偏移 40 位
        internal static Func<ulong, ulong> MainVa = off => Imports.s2a_main_region_va(off);   // 单测换成假排布

        // 游戏内存适配：只读已映射页、只写可写页（MemoryPermission 位：1 读、2 写、4 执行）
        internal sealed class GameProcess : ITamperedProcess
        {
            // main 区虚拟地址 → 真实地址；换不出（超出起局模块 / 前面有没装的模块）按没映射报，界面显示「地址未就绪」、不写别处
            private static ulong Real(ulong va)
            {
                if (va - MainVirtual >= MainSpan) return va;
                ulong r = MainVa(va - MainVirtual);
                if (r == 0) throw new TamperExecutionException($"main 区偏移 0x{va - MainVirtual:X} 不在起局模块里");
                return r;
            }

            public ProcessState State => ProcessState.Started;
            public bool TamperedCodeMemory { get; set; }
            public bool Packed;   // 这条编进了包：写只读代码页的行已由包里的改动接管，静默跳过


            // 写到不可写页（苹果上的代码页是签名只读页）：先置 TamperedCodeMemory 再抛——Run 里按它的异常过滤在 finally 之前求值，
            //   放在 finally 里置位，过滤看到的还是 false，会误判成「地址未就绪」（11-09 真机实测）
            private bool Check(ulong va, ulong size, bool write)
            {
                if (Native.MemMapped == null || Native.MemMapped(va, size) != 1)
                    throw new TamperExecutionException($"Unmapped memory access of {size} bytes at 0x{va:X16}");
                if (!write) return true;
                MemInfo a, b;
                Native.MemQuery(va, &a); Native.MemQuery(va + size - 1, &b);
                if ((a.Perm & 2) == 0 || (b.Perm & 2) == 0)
                {
                    if (Packed) return false;
                    TamperedCodeMemory = true;
                    throw new TamperExecutionException($"Write to non-writable memory at 0x{va:X16}");
                }
                return true;
            }

            public T ReadMemory<T>(ulong va) where T : unmanaged
            {
                va = Real(va);
                Check(va, (ulong)Unsafe.SizeOf<T>(), false);
                return Dispatcher.Instance.Memory.Read<T>(va);
            }

            public void WriteMemory<T>(ulong va, T value) where T : unmanaged
            {
                va = Real(va);
                if (!Check(va, (ulong)Unsafe.SizeOf<T>(), true)) return;
                Dispatcher.Instance.Memory.Write(va, value);
                // 每个写入地址首次写时记一行（至多 64 个，换算后的真实地址）：指针链金手指落到哪里只有运行时知道，排查「写成功但没效果」靠它对照宿主对象地址
                lock (Written) if (Written.Count < 64 && Written.Add(va)) Console.Error.WriteLine($"金手指：写 0x{va:X} {Unsafe.SizeOf<T>()} 字节");
            }
            private static readonly HashSet<ulong> Written = new HashSet<ulong>();

            public void PauseProcess() => Console.Error.WriteLine("金手指：暂停进程指令不支持，已忽略");
            public void ResumeProcess() { }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Layout   // runtime/include/s2a_native.h s2a_layout 前 12 项（逐字段一致）
        {
            public ulong WinBase, WinSize, AliasBase, AliasSize, HeapBase, HeapSize, StackBase, StackSize, TlsioBase, TlsioSize, AslrBase, AslrSize;
        }

        internal static class Imports
        {
            private const string Lib = "s2a_native";
            [DllImport(Lib)] public static extern Layout* s2a_layout_get();
            [DllImport(Lib)] public static extern ulong s2a_main_base();
            [DllImport(Lib)] public static extern ulong s2a_main_region_va(ulong off);
            [DllImport(Lib)] public static extern byte* s2a_main_build_id();
            [DllImport(Lib)] public static extern byte* s2a_cheats_dir();
            [DllImport(Lib)] public static extern int s2a_cpatch_cheat(byte* file, byte* name, int on);
        }
    }
}
