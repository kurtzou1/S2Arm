// 直连出库的 C# 常驻进程（11-01 出包线：整条出库链在这一个进程里，替掉 Python 的 dmsh_build.py / dmsh_par.py 等，见 Build.cs 文件头）：
//   dsh_batch build …：整份出库（direct_lib.sh ④ 调；用法见 Build.cs）
//   dsh_batch --xfp：打印翻译器指纹（S2A.Dsh 全部源码 + Ryujinx 着色器翻译器，进出库缓存键）
//   dsh_batch --unity / --libpack / --c1cb …：编批库、库容器、两张表各自的单测入口（见 Unity.cs / LibPack.cs / C1Cb.cs 的 Cli）
//   spirv-cross 走进程内库（translator/spvc_inproc.py 编的 libspvc_cli：链锁那份命令行源码原样编成库，与命令行逐字节同、不每支起进程）
using S2A.Dsh;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

static class DshBatch
{
    static int Main(string[] argv)
    {
        // 输出固定 UTF-8（中文 Windows 缺省 GBK，调用方按 UTF-8 读成乱码，#165）；直接换写入器，没有控制台的进程也成立
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true });
        Console.SetError(new StreamWriter(Console.OpenStandardError(), new System.Text.UTF8Encoding(false)) { AutoFlush = true });
        if (argv.Length == 1 && argv[0] == "--xfp") { Console.WriteLine(DshCompiler.Xfp); return 0; }
        if (argv.Length == 3 && argv[0] == "--outline-file")
        {
            string source = File.ReadAllText(argv[1]), output = DshOutline.Compute(source);
            File.WriteAllText(argv[2], output, new System.Text.UTF8Encoding(false));
            Console.WriteLine(output == source ? "outlined 0" : "outlined 1"); return 0;
        }
        if (argv.Length >= 1 && argv[0] == "--tool-fp") { Console.WriteLine(Build.ToolFpCli(argv[1..])); return 0; }   // 验收：整份工具指纹（翻译键里那一项）
        if (argv.Length == 2 && argv[0] == "--lib-fp") { Console.WriteLine(Build.LibFp(argv[1])); return 0; }   // 单测：直连库 libdsx 进翻译键的功能身份（tests/nxgal_fp_test.sh）
        if (argv.Length >= 1 && argv[0] == "build") return Build.Entry(argv[1..]);
        if (argv.Length >= 1 && argv[0] == "--c1cb") return C1Cb.Cli(argv[1..]);
        if (argv.Length == 3 && argv[0] == "--spvc-file") return InprocSpvCross.FileCli(argv[1], argv[2]);   // 单测：线程池线程上翻一支 SPIR-V（tests/spvc_deep_stack_test.sh）
        if (argv.Length >= 1 && argv[0] == "--libpack") return LibPack.Cli(argv[1..]);
        if (argv.Length >= 2 && argv[0] == "--win-relative")   // 单测：Windows 版 Metal 编译器参数里带空格 / 非 ASCII 的路径改成相对工作区（Metal.WinRelative，t_metal_nospace.py ⑥）
        {
            try { foreach (var x in Metal.WinRelative(argv[2..], argv[1])) Console.WriteLine(x); return 0; }
            catch (InvalidOperationException e) { Console.WriteLine("stop: " + e.Message); return 2; }
        }
        if (argv.Length >= 3 && argv[0] == "--metal-compile") return Metal.CompileCli(argv[1..]);   // 单测：盘写满整次停、普通编不过只记这一支（graphics/tools/direct/tests/t_metal_nospace.py）
        if (argv.Length == 1 && argv[0] == "--compiler-why") { Console.Out.Write(Metal.CompilerWhy(Console.In.ReadToEnd()) ?? ""); return 0; }   // 单测：编译器 stderr → 出库清单记的那一句（Metal.CompilerWhy）
        if (argv.Length >= 1 && argv[0] == "--unity") return Unity.Cli(argv[1..]);
        Console.Error.WriteLine("用法：dsh_batch build … | --xfp | --unity … | --libpack … | --c1cb …（见 Program.cs 文件头）"); return 2;
    }
}

/// <summary>spirv-cross 命令行在进程内（libspvc_cli spvc_cli_run_mem，同 spvc_inproc.run 那份库）：参数与 CliSpvCross 相同，SPIR-V 与 MSL 都在内存里进出</summary>
sealed unsafe class InprocSpvCross : ISpvCross
{
    readonly delegate* unmanaged<int, byte**, byte*, nuint, byte**, nuint*, byte**, nuint*, int> _run;
    readonly delegate* unmanaged<byte*, void> _free;
    public InprocSpvCross(string lib)
    {
        var h = NativeLibrary.Load(lib);
        _run = (delegate* unmanaged<int, byte**, byte*, nuint, byte**, nuint*, byte**, nuint*, int>)NativeLibrary.GetExport(h, "spvc_cli_run_mem");
        _free = (delegate* unmanaged<byte*, void>)NativeLibrary.GetExport(h, "spvc_cli_free");
    }
    public string Msl(byte[] spv, out string err) => Run(spv, true, out err);
    public string Glsl450(byte[] spv, out string err) => Run(spv, false, out err);
    // 单测入口（tests/spvc_deep_stack_test.sh）：在线程池线程上翻一支，同出库 Translate 的 Parallel.ForEach；翻成功返回 0。
    //   嵌套深的着色器不栈溢出靠的是 dsh_batch.csproj 的 System.Threading.DefaultStackSize = 64 MB（#57），它对线程池线程同样生效
    public static int FileCli(string lib, string spvPath)
    {
        var xc = new InprocSpvCross(lib); var spv = File.ReadAllBytes(spvPath);
        var (msl, err) = Task.Run(() => { var m = xc.Msl(spv, out var e); return (m, e); }).Result;
        Console.WriteLine(msl != null ? $"msl {msl.Length} chars" : $"spirv-cross failed: {err}");
        return msl != null ? 0 : 1;
    }
    string Run(byte[] spv, bool msl, out string err)   // 输入输出都在内存（spvc_cli_run_mem：命令行里 "mem:in" / "mem:out"，spvc_cli/shim.h）
    {
        var args = new List<string> { "spirv-cross" };
        if (msl) { args.AddRange(CliSpvCross.XC); args.Add("mem:in"); } else { args.Add("mem:in"); args.Add("--version"); args.Add("450"); }
        args.Add("--output"); args.Add("mem:out");
        var bufs = args.Select(x => Marshal.StringToCoTaskMemUTF8(x)).ToArray();
        try
        {
            var argvp = stackalloc byte*[bufs.Length];
            for (int i = 0; i < bufs.Length; i++) argvp[i] = (byte*)bufs[i];
            byte* e = null, o = null; nuint n = 0, on = 0; int rc;
            fixed (byte* sp = spv) rc = _run(bufs.Length, argvp, sp, (nuint)spv.Length, &o, &on, &e, &n);
            string es = e != null ? System.Text.Encoding.UTF8.GetString(e, (int)n) : "", os = o != null ? System.Text.Encoding.UTF8.GetString(o, (int)on) : "";
            if (e != null) _free(e);
            if (o != null) _free(o);
            if (rc != 0) { err = es.Trim(); return null; }
            err = null; return os.Replace("\r\n", "\n").Replace('\r', '\n');   // 同 Python 文本读的通用换行
        }
        finally { foreach (var b in bufs) Marshal.FreeCoTaskMem(b); }
    }
}
