using System;
using System.Collections.Generic;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Tamper;

namespace S2A.Services.Tests
{
    // 金手指（Cheats.cs）：期望按 Atmosphere 金手指格式手写，不跑被测实现推期望
    public static unsafe class CheatsTest
    {
        private static int Mapped(ulong va, ulong size) => 1;
        private static int QueryReadExec(ulong va, MemInfo* info) { info->Base = va & ~0xFFFUL; info->Size = 0x1000; info->Perm = 5; return 0; }   // 读 + 执行、不可写（代码页）

        private sealed class Fake : ITamperedProcess
        {
            public readonly List<(ulong va, ulong v)> Writes = new();
            public ProcessState State => ProcessState.Started;
            public bool TamperedCodeMemory { get; set; }
            public readonly Dictionary<ulong, ulong> Mem = new();
            public T ReadMemory<T>(ulong va) where T : unmanaged
            {
                ulong v = Mem.TryGetValue(va, out ulong x) ? x : 0; T r = default;
                System.Runtime.CompilerServices.Unsafe.CopyBlockUnaligned(ref System.Runtime.CompilerServices.Unsafe.As<T, byte>(ref r), ref System.Runtime.CompilerServices.Unsafe.As<ulong, byte>(ref v), (uint)System.Runtime.CompilerServices.Unsafe.SizeOf<T>());
                return r;
            }
            public void WriteMemory<T>(ulong va, T value) where T : unmanaged => Writes.Add((va, Convert.ToUInt64(value)));
            public void PauseProcess() { }
            public void ResumeProcess() { }
        }

        public static void Run(Action<string, object, object> check)
        {
            const string text = "{主代码}\n580F0000 01234567\n\n[无限金钱]\n04000000 00000010 0000002A\n[ 跳高 ]\n04000000 00000020 00000001\n04000000 00000024 00000002\n";
            var e = Cheats.Parse("0123456789ABCDEF.txt", text);
            check("金手指 解析：三段（主代码 + 两条）", 3, e.Count);
            check("金手指 解析：主代码段名 / 标记", ("主代码", true), (e[0].Name, e[0].Master));
            check("金手指 解析：条目名去空白、键 = 文件名/条目名", "0123456789ABCDEF.txt/跳高", e[2].Key);
            check("金手指 解析：第三段两行指令", 2, e[2].Lines.Count);
            check("金手指 解析：方括号不闭合整份作废", true, Cheats.Parse("a.txt", "[坏\n04000000 00000010 00000001\n") == null);
            check("金手指 解析：段外开头的指令归「未命名」", "未命名", Cheats.Parse("a.txt", "04000000 00000010 00000001\n")[0].Name);

            check("金手指 构建号：16 位十六进制名与主程序前 16 位一致（大小写不敏感）", true, Cheats.BuildMatches("0123456789abcdef", "0123456789ABCDEF00112233"));
            check("金手指 构建号：16 位十六进制名不一致 → 不符", false, Cheats.BuildMatches("0123456789ABCDEE", "0123456789ABCDEF00112233"));
            check("金手指 构建号：拿不到主程序构建号 → 不符", false, Cheats.BuildMatches("0123456789ABCDEF", ""));
            check("金手指 构建号：玩家自起的文件名不判", true, Cheats.BuildMatches("塞满金币", "0123456789ABCDEF"));

            // 指令 0（存常量）：04000000 00000010 0000002A = 4 字节、main 区、偏移 0x10、值 0x2A → 写到 主程序基址 + 0x10
            var fake = new Fake();
            const ulong exe = 0x8000000000UL;
            ITamperProgram p = new AtmosphereCompiler(exe, 0x9000000000UL, 0, 0, fake).Compile("t", e[1].Lines);
            check("金手指 编译：存常量指令编译成功", true, p != null);
            p.IsEnabled = true;
            p.Execute((ControllerKeys)0);
            check("金手指 执行：写到主程序基址 + 0x10、值 42", "8000000010=42", fake.Writes.Count == 1 ? $"{fake.Writes[0].va:X}={fake.Writes[0].v}" : $"写了 {fake.Writes.Count} 次");
            // 指令 1（条件）+ 0（存常量）+ 2（结束条件）：主程序 +0x10 处 4 字节 > 3 才把 1 写到 +0x20（期望按 Atmosphere 格式手算：1TMC00AA AAAAAAAA VVVVVVVV，C=1 是「大于」）
            //   覆盖 Ryujinx 原 dynamic 写法改成的整数运算（CondGT / Value / Pointer 取值）
            string[] cond = { "14010000 00000010 00000003", "04000000 00000020 00000001", "20000000" };
            foreach ((ulong v, int writes) in new[] { (5UL, 1), (2UL, 0) })
            {
                var f = new Fake(); f.Mem[exe + 0x10] = v;
                ITamperProgram c = new AtmosphereCompiler(exe, 0x9000000000UL, 0, 0, f).Compile("cond", cond);
                c.IsEnabled = true; c.Execute((ControllerKeys)0);
                check($"金手指 条件：+0x10 = {v} 时 > 3 {(writes == 1 ? "成立、写 +0x20" : "不成立、不写")}", writes == 1 ? "8000000020=1" : "不写",
                    f.Writes.Count == 1 ? $"{f.Writes[0].va:X}={f.Writes[0].v}" : f.Writes.Count == 0 ? "不写" : $"写了 {f.Writes.Count} 次");
            }
            // 游戏内存适配：写到不可写页 → 异常过滤（Run 里 when (!TamperedCodeMemory)）求值时标志已置上，才判得出「改代码，不支持」而不是「地址未就绪」
            {
                var oldMapped = Native.MemMapped; var oldQuery = Native.MemQuery;
                Native.MemMapped = &Mapped; Native.MemQuery = &QueryReadExec;
                var gp = new Cheats.GameProcess(); bool seen = false, threw = false;
                try { gp.WriteMemory<uint>(0x10000, 1); }
                catch (Ryujinx.HLE.Exceptions.TamperExecutionException) when (Observe(gp, ref seen)) { }
                catch (Ryujinx.HLE.Exceptions.TamperExecutionException) { threw = true; }
                Native.MemMapped = oldMapped; Native.MemQuery = oldQuery;
                check("金手指 写代码页：抛执行异常、过滤求值时已标记改代码", (true, true), (seen || threw, seen));
            }
            // 编进包的条目（11-12）：写只读代码页的行由包里的改动接管 → 静默跳过、不抛、不标改代码
            {
                var oldMapped = Native.MemMapped; var oldQuery = Native.MemQuery;
                Native.MemMapped = &Mapped; Native.MemQuery = &QueryReadExec;
                var gp = new Cheats.GameProcess { Packed = true }; bool threw = false;
                try { gp.WriteMemory<uint>(0x10000, 1); } catch (Ryujinx.HLE.Exceptions.TamperExecutionException) { threw = true; }
                Native.MemMapped = oldMapped; Native.MemQuery = oldQuery;
                check("金手指 编进包：写代码页跳过（不抛、不标改代码）", (false, false), (threw, gp.TamperedCodeMemory));
            }
            // main 区按 Horizon 排布换算（11-13）：假排布 main 映像 0x173C000 字节、真实基址 0x1000000000；sdk 紧接其后（Horizon 偏移 0x173C000 起 0xCFB000 字节）、真实基址 0x2000000000。
            //   「04000000 024191F4 00000001」写 main 区 +0x24191F4 → 期望落 sdk 内 0x24191F4 − 0x173C000 = 0xCDD1F4 → 真实地址 0x2000CDD1F4（手算）；
            //   main 内 +0x10 → 0x1000000010；超出 sdk（+0x2437000）→ 不写任何地址、按「地址未就绪」报（不标改代码）。写只读页时异常信息带真实地址，借它读出落点
            {
                var oldMapped = Native.MemMapped; var oldQuery = Native.MemQuery; var oldVa = Cheats.MainVa;
                Native.MemMapped = &Mapped; Native.MemQuery = &QueryReadExec;
                Cheats.MainVa = off => off < 0x173C000 ? 0x1000000000UL + off : off - 0x173C000 < 0xCFB000 ? 0x2000000000UL + (off - 0x173C000) : 0;
                string Land(string line)
                {
                    var gp = new Cheats.GameProcess();
                    ITamperProgram q = new AtmosphereCompiler(Cheats.MainVirtual, 0, 0, 0, gp).Compile("m", new[] { line });
                    q.IsEnabled = true; gp.TamperedCodeMemory = false;
                    try { q.Execute((ControllerKeys)0); return "没写"; }
                    catch (Ryujinx.HLE.Exceptions.TamperExecutionException x) { return gp.TamperedCodeMemory ? x.Message[(x.Message.LastIndexOf("0x") + 2)..].TrimStart('0') : "地址未就绪"; }
                }
                var got = (Land("04000000 024191F4 00000001"), Land("04000000 00000010 00000001"), Land("04000000 02437000 00000001"));
                Native.MemMapped = oldMapped; Native.MemQuery = oldQuery; Cheats.MainVa = oldVa;
                check("金手指 main 区按 Horizon 排布：超出 main 落进 sdk、main 内照旧、超出起局模块不写", ($"{0x2000CDD1F4UL:X}", "1000000010", "地址未就绪"), got);
            }
            // 文件头 BID（公开库写法 [游戏名 … BID=2607A74F5DF7754C]）：与主程序前 16 位比
            check("金手指 文件头构建号：一致", true, Cheats.HeaderMatches("[D v1 BID=2607A74F5DF7754C]\n[a]\n", "2607a74f5df7754cc0357b5d"));
            check("金手指 文件头构建号：不一致 → 不符", false, Cheats.HeaderMatches("[D v1 BID=2607A74F5DF7754D]\n", "2607A74F5DF7754CC0357B5D"));
            check("金手指 文件头构建号：没写 → 不判", true, Cheats.HeaderMatches("[无限血]\n04000000 00000010 00000001\n", "2607A74F5DF7754C"));
            // NativeAOT 运行时指令（services/aot/rd.xml）要覆盖 Ryujinx Tamper 里全部泛型操作 / 条件 × 4 种宽度：期望 = 反射枚举出来的那一组，少一个就是真机「missing native code」
            var want = new List<string>();
            foreach (Type t in typeof(AtmosphereCompiler).Assembly.GetTypes())
                if (t.IsGenericTypeDefinition && (typeof(Ryujinx.HLE.HOS.Tamper.Operations.IOperation).IsAssignableFrom(t) || typeof(Ryujinx.HLE.HOS.Tamper.Conditions.ICondition).IsAssignableFrom(t)))
                    foreach (string w in new[] { "Byte", "UInt16", "UInt32", "UInt64" }) want.Add($"{t.FullName}[[System.{w},System.Private.CoreLib]]");
            string dir = AppContext.BaseDirectory, rdPath = null;   // 从测试程序目录往上找仓库里的 services/aot/rd.xml
            for (int up = 0; up < 10 && dir != null && rdPath == null; up++, dir = System.IO.Path.GetDirectoryName(dir.TrimEnd('/')))
                if (System.IO.File.Exists(System.IO.Path.Combine(dir, "services/aot/rd.xml"))) rdPath = System.IO.Path.Combine(dir, "services/aot/rd.xml");
            string rd = rdPath != null ? System.IO.File.ReadAllText(rdPath) : "";
            var missing = want.FindAll(x => !rd.Contains($"Name=\"{x}\""));
            check("金手指 AOT 运行时指令覆盖全部泛型操作 / 条件 × 4 宽度", $"{want.Count} 个、缺 0", $"{want.Count} 个、缺 {missing.Count}{(missing.Count > 0 ? "：" + missing[0] : "")}");
            // NativeAOT 不支持 C# dynamic（compat 补丁 tamper-no-dynamic 已换成整数运算）：升级上游后若又带回来，真机执行即抛异常
            var dyn = new List<string>();
            if (rdPath != null)
            {
                string tamper = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(rdPath))), "compat/tree/src/Ryujinx.HLE/HOS/Tamper");
                foreach (string f in System.IO.Directory.EnumerateFiles(tamper, "*.cs", System.IO.SearchOption.AllDirectories))
                    if (System.IO.File.ReadAllText(f).Contains("(dynamic)")) dyn.Add(System.IO.Path.GetFileName(f));
            }
            check("金手指 Ryujinx 金手指源码不含 (dynamic)", "仓库可读、0 处", rdPath == null ? "找不到仓库" : $"仓库可读、{dyn.Count} 处{(dyn.Count > 0 ? "：" + string.Join(",", dyn) : "")}");
            // FPSLocker 表达式（FORMAT.md 口径，手算）：60 帧时帧时间 16.667、0.945×帧时间 15.75；目标等于刷新率时上限 +2；TruncDec 截两位
            check("FPSLocker 表达式：0.945 * FRAMETIME_TARGET @60", "15.75", FpsLocker.Eval("0.945 * FRAMETIME_TARGET", 60).ToString("0.00", System.Globalization.CultureInfo.InvariantCulture));
            check("FPSLocker 表达式：FPS_LOCK_TARGET @60 / @30", (62.0, 30.0), (FpsLocker.Eval("FPS_LOCK_TARGET", 60), FpsLocker.Eval("FPS_LOCK_TARGET", 30)));
            check("FPSLocker 表达式：TruncDec(FRAMETIME_TARGET, 2) @30", 33.33, FpsLocker.Eval("TruncDec(FRAMETIME_TARGET, 2)", 30));
            check("FPSLocker 表达式：VSYNC_TARGET @60 / @30、优先级与括号", (1.0, 2.0, 7.0), (FpsLocker.Eval("VSYNC_TARGET", 60), FpsLocker.Eval("VSYNC_TARGET", 30), FpsLocker.Eval("1 + 2 * (4 - 1)", 60)));
            var fl = FpsLocker.Load("{\"units\":[{\"id\":\"fps:a\",\"all_fps\":[{\"type\":\"evaluate_write\",\"address\":[\"MAIN\",68358836],\"value_type\":\"float\",\"value\":\"0.945 * FRAMETIME_TARGET\"},{\"type\":\"write\",\"address\":[\"HEAP\",16,8],\"value_type\":\"int32\",\"value\":[1,2]}]}]}");
            check("FPSLocker 配置读取：条数 / 第二条地址级数 / 值是列表", (2, 3, System.Text.Json.JsonValueKind.Array), (fl.Count, fl[1].Address.Count, fl[1].Value.ValueKind));
            check("金手指 编译：坏指令回 null（界面显示「指令有误」）", true,
                new AtmosphereCompiler(exe, 0, 0, 0, fake).Compile("bad", new[] { "ZZZZ" }) == null);
        }

        private static bool Observe(Cheats.GameProcess p, ref bool seen) { seen = p.TamperedCodeMemory; return true; }
    }
}
