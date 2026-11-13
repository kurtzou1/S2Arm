// 游戏自带解码器的 Windows / 跨平台工具模式（11-05 维护者：Oodle / LZ5 包最终要在 Windows 上自己解，不长期靠 Mac）：
//   Mac 上 runtime/src/oodle_tool.c 是在 Apple 芯片上原生执行游戏 main 里的解码函数；这里用 Ryujinx ARMeilleure 执行同一段游戏代码，
//   解出的字节与 Mac 宿主一致（对照：tests/gamedec_test.sh 用 Mac 宿主解出的块逐字节比），Windows 出包机（x86-64）与 Mac 都能跑。
// 用法（与 Mac 宿主工具模式同一协议，translator/uepak.py OodleHost 直接起它）：
//   gamedec <产物根>                      DM_OODLE_SERVE=1：stdin 每请求 u64 压缩长 u64 原长 + 压缩字节 → stdout u64 解出长（0 = 失败）+ 字节；stdin 结束即退出（有失败退 1）
//   gamedec --verify <产物根> <对照目录>   对照目录里 index.tsv（序号、压缩长、原长、来源）+ <序号>.c / .r：逐块解、逐字节比，打印通过 / 失败数与耗时
// 产物根 = 标准布局（<根>/exefs/main 是游戏原样的 NSO）。解码器：main 导出 LZ5_decompress_safe 就用它；否则按 Mac 同一规则定位 Oodle（Locate.cs）。
using System;
using System.Diagnostics;
using System.IO;

namespace S2Arm.GameDec
{
    sealed class Decoder : IDisposable
    {
        public readonly string Name; public readonly ulong Off;
        readonly Guest _g; readonly int _kind; readonly Locate? _L; readonly ulong _scratch, _base; int _need;
        const ulong ScratchSize = 16 << 20;

        public Decoder(string root)
        {
            var m = Nso.Load(Path.Combine(root, "exefs", "main"));
            _g = new Guest(m, 1ul << 30) { Trace = Environment.GetEnvironmentVariable("GAMEDEC_TRACE") == "1" };
            if (m.Exports.TryGetValue("LZ5_decompress_safe", out ulong lz5)) { _kind = 3; Off = lz5; Name = "LZ5_decompress_safe"; }
            else
            {
                _L = Locate.Run(m);
                Console.Error.WriteLine($"Oodle 定位：OodleLZ_Decompress main+{_L.Decompress:x}（候选 {_L.NDecompress}）、DecodeSome main+{_L.DecSome:x}（{_L.NDecSome}）、MemorySizeNeeded main+{_L.Msn:x}（{_L.NMsn}）、Create main+{_L.Create:x}（{_L.NCreate}）");
                _kind = _L.Pick(out string why);
                if (_kind <= 0) throw new InvalidOperationException("认不出游戏自带的 Oodle 解码器——" + why);
                Console.Error.WriteLine("Oodle 工具模式：" + why);
                Off = _kind == 1 ? _L.Decompress : _L.DecSome;
                Name = _kind == 1 ? "OodleLZ_Decompress" : "OodleLZDecoder_MemorySizeNeeded / Create / DecodeSome";
            }
            _scratch = _g.Alloc(ScratchSize, 64);
            _base = _g.Mark;
            Console.Error.WriteLine($"解码器：{Name} 在 main+{Off:x}（ARMeilleure 执行；main 导入 {_g.Imports - _g.TakenAt.Count} 个，用到的 C 运行时函数在本工具里实现{(_g.TakenAt.Count > 0 ? $"；接管 main 自带的分配函数 {string.Join(" / ", _g.TakenAt)}" : "")}）");
        }

        // 解一块 → 解出长度（≠ raw.Length 即失败）
        public long Run(ReadOnlySpan<byte> comp, Span<byte> raw)
        {
            try
            {
                ulong c = _g.Alloc((ulong)Math.Max(comp.Length, 1)), r = _g.Alloc((ulong)raw.Length + 0x10000);
                _g.Write(c, comp);
                long got = _kind switch
                {
                    3 => comp.Length > int.MaxValue || raw.Length > int.MaxValue ? -1 : (int)(uint)_g.Call(Guest.Img + Off, c, r, (ulong)comp.Length, (ulong)raw.Length),
                    1 => (long)_g.Call(Guest.Img + Off, c, (ulong)comp.Length, r, (ulong)raw.Length, 1, 0, 0, 0, 0, 0, 0, _scratch, ScratchSize, 3),   // fuzzSafe、不查 CRC、不打印、不分线程
                    _ => Api(c, comp.Length, r, raw.Length),
                };
                if (got == raw.Length) _g.Read(r, raw);
                return got;
            }
            finally { _g.Release(_base); }
        }

        // Decoder 三件套（同 oodle_tool.c dec_run_api）：工作内存按「不限压缩器、不限原长」问一次大小，每块 Create 在上面、DecodeSome 循环到解满
        long Api(ulong c, long cl, ulong r, long rl)
        {
            if (_need == 0)
            {
                _need = (int)(uint)_g.Call(Guest.Img + _L!.Msn, unchecked((ulong)-1L), unchecked((ulong)-1L));
                Console.Error.WriteLine($"Oodle 工具模式：MemorySizeNeeded(-1, -1) = {_need} 字节");
                if (_need <= 0 || (ulong)_need + 64 > ScratchSize) throw new InvalidOperationException($"OodleLZDecoder_MemorySizeNeeded 返回 {_need}");
            }
            ulong dec = _g.Call(Guest.Img + _L!.Create, unchecked((ulong)-1L), (ulong)rl, _scratch, (ulong)_need + 64);
            if (dec == 0) return -3;
            ulong outp = _g.Alloc(16); long pos = 0, cpos = 0; int rounds = 0; var o = new byte[16];
            while (pos < rl)
            {
                _g.Write(outp, new byte[16]);
                uint ok = (uint)_g.Call(Guest.Img + _L.DecSome, dec, outp, r, (ulong)pos, (ulong)rl, (ulong)(rl - pos), c + (ulong)cpos, (ulong)(cl - cpos), 1, 0, 0, 3);
                if (ok == 0) return -4;
                _g.Read(outp, o); int done = BitConverter.ToInt32(o, 0), used = BitConverter.ToInt32(o, 4);
                if (done <= 0 || used < 0 || cpos + used > cl || ++rounds > 1_000_000) return -5;
                pos += done; cpos += used;
            }
            return pos;
        }

        public void Dispose() => _g.Dispose();
    }

    static class Program
    {
        static int Main(string[] a)
        {
            try
            {
                if (a.Length == 3 && a[0] == "--verify") return Verify(a[1], a[2]);
                if (a.Length == 1 && Environment.GetEnvironmentVariable("DM_OODLE_SERVE") is { Length: > 0 }) return Serve(a[0]);
                Console.Error.WriteLine("用法：gamedec <产物根>（DM_OODLE_SERVE=1）| gamedec --verify <产物根> <对照目录>");
                return 2;
            }
            // 出错立即结束进程（#854）：客体执行到未定义指令 / 断点后执行线程停住、翻译器收不掉，它的线程会把进程拖着不退——
            //   调用方（translator/uepak.py OodleHost）一直等这个请求的回话，Windows 出包停在「抽取 0/4」三个多小时。退出后调用方读到文件尾即报错，带出这里的原因
            catch (Exception e) { Console.Error.WriteLine("【红】gamedec：" + e.Message); Console.Error.Flush(); Environment.Exit(1); return 1; }
        }

        static bool ReadAll(Stream s, Span<byte> b) { while (b.Length > 0) { int k = s.Read(b); if (k <= 0) return false; b = b[k..]; } return true; }

        static int Serve(string root)
        {
            using var d = new Decoder(root);
            using var stdin = Console.OpenStandardInput(); using var stdout = Console.OpenStandardOutput();
            var hdr = new byte[16]; long n = 0, bad = 0;
            Console.Error.WriteLine($"DM_OODLE_SERVE：{d.Name} 在 main+{d.Off:x}，等 stdin 上的请求");
            while (ReadAll(stdin, hdr))
            {
                ulong cl = BitConverter.ToUInt64(hdr, 0), rl = BitConverter.ToUInt64(hdr, 8);
                if (cl > 1ul << 32 || rl > 1ul << 32) throw new InvalidDataException($"请求太大（{cl:x} → {rl:x}）");
                var comp = new byte[cl]; var raw = new byte[rl];
                if (!ReadAll(stdin, comp)) throw new InvalidDataException("请求被截断");
                long got = d.Run(comp, raw);
                ulong outLen = got == (long)rl ? rl : 0;
                if (outLen == 0 && rl != 0 && bad++ < 8) Console.Error.WriteLine($"【红】DM_OODLE_SERVE：第 {n} 个请求（{cl} → {rl} 字节）失败（解码器返回 {got}）");
                stdout.Write(BitConverter.GetBytes(outLen)); if (outLen != 0) stdout.Write(raw); stdout.Flush();
                n++;
            }
            Console.Error.WriteLine($"DM_OODLE_SERVE：{n} 个请求，{bad} 个失败");
            return bad != 0 ? 1 : 0;
        }

        static int Verify(string root, string refDir)
        {
            using var d = new Decoder(root);
            int ok = 0, bad = 0; long raw = 0; var sw = Stopwatch.StartNew();
            foreach (var line in File.ReadAllLines(Path.Combine(refDir, "index.tsv")))
            {
                var f = line.Split('\t'); if (f.Length < 3) continue;
                var comp = File.ReadAllBytes(Path.Combine(refDir, f[0] + ".c")); var want = File.ReadAllBytes(Path.Combine(refDir, f[0] + ".r"));
                var got = new byte[long.Parse(f[2])];
                long n = d.Run(comp, got);
                if (n == want.Length && got.AsSpan().SequenceEqual(want)) { ok++; raw += n; }
                else if (bad++ < 5) Console.Error.WriteLine($"不通 第 {f[0]} 块（{comp.Length} → {want.Length}）：解码器返回 {n}{(n == want.Length ? "，字节不同" : "")}");
            }
            Console.WriteLine($"{(bad == 0 ? "✓" : "✗")} gamedec 对照：{ok} 块逐字节相同、{bad} 块不同（共 {ok + bad} 块，{raw / 1048576.0:F1} MB，{sw.Elapsed.TotalSeconds:F1} 秒；解码器 {d.Name}）");
            return bad == 0 && ok > 0 ? 0 : 1;
        }
    }
}
