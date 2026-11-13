// 客体执行环境：游戏 main 映像在 Ryujinx 的 ARMeilleure（compat/tree/src/ARMeilleure，MIT）里按 AArch64 执行，x86-64（Windows 出包机）与 arm64（Mac）都能跑。
// 只跑一个自包含的解码函数：不起 HLE 内核、不进 nnMain。地址空间（客体虚拟地址）：
//   映像 IMG（main 代码 / 只读 / 数据 + bss，重定位按 IMG 基址做）、桩页 STUB（每个导入一对「svc #序号; ret」，0 号 = 返回桩）、
//   栈 STACK、线程局部区 TLS（TPIDRRO_EL0 指它，清零）、堆 HEAP（导入的 malloc 等在这里线性分配，每次调用后按调用前的位置收回）。
// 导入函数（main 里未定义的符号）只实现解码路径真会调到的那几个 C 运行时函数；调到别的就停下、报出名字，不猜返回值。
using ARMeilleure.Memory;
using Ryujinx.Cpu;
using Ryujinx.Cpu.Jit;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;

namespace S2Arm.GameDec
{
    sealed class Guest : IDisposable
    {
        public const ulong Img = 0x0800_0000, Stub = 0x7000_0000, StubSize = 0x8_0000, Stack = 0x7100_0000, StackSize = 8 << 20, Tls = 0x7200_0000, TlsSize = 0x1_0000, Heap = 0x1_0000_0000;
        readonly MemoryBlock _backing;
        readonly MemoryManager _mm;
        readonly ICpuContext _cpu;
        readonly ulong _heapSize;
        readonly List<string> _imports = new() { "<返回>" };
        ulong _brk = Heap, _loop, _ret;
        string? _fault;
        bool _started;
        volatile bool _quit;
        (ulong Fn, ulong[] Args) _job;
        System.Threading.Thread? _worker;
        readonly System.Threading.SemaphoreSlim _go = new(0), _done = new(0);
        public bool Trace;

        public Guest(Nso m, ulong heapSize)
        {
            _heapSize = heapSize;
            ulong img = (ulong)m.Image.Length, total = img + StubSize + StackSize + TlsSize + heapSize;
            _backing = new MemoryBlock(total);
            _mm = new MemoryManager(_backing, 1ul << 39);
            ulong pa = 0;
            foreach (var (va, size) in new[] { (Img, img), (Stub, StubSize), (Stack, (ulong)StackSize), (Tls, TlsSize), (Heap, heapSize) }) { _mm.Map(va, pa, size, MemoryMapFlags.None); pa += size; }
            var image = (byte[])m.Image.Clone();
            var idx = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var r in m.Relocs)
            {
                ulong v;
                if (r.Type == Nso.R_RELATIVE) v = Img + (ulong)r.Addend;
                else if (r.Defined) v = Img + r.Value + (ulong)r.Addend;
                else
                {
                    if (!idx.TryGetValue(r.Sym, out int i)) { i = _imports.Count; idx[r.Sym] = i; _imports.Add(r.Sym); }
                    if (i >= (int)(StubSize / 8)) throw new InvalidOperationException("main 的导入符号多于桩页能放的个数");
                    v = Stub + (ulong)i * 8 + (ulong)r.Addend;
                }
                BitConverter.TryWriteBytes(image.AsSpan((int)r.Off, 8), v);
            }
            // main 自己定义并按名导出的 C 运行时分配函数（勇者斗恶龙 XI S：malloc / free / calloc / realloc / aligned_alloc 都在 main 里）也接到本工具的堆：
            //   游戏的分配器要 SDK 初始化（nn::init）后才建好，没建好 malloc 直接回空——LZ5_decompress_safe 头一件事 malloc(512 KB)，回空就返回 -1、一个导入都不调。
            //   Mac 宿主是等 SDK 初始化完再调解码器；这里不起 SDK，入口原地改成 svc #i; ret，走与导入同名函数同一套实现
            foreach (var name in Taken)
                if (m.Exports.TryGetValue(name, out ulong at) && !idx.ContainsKey(name))
                {
                    int i = _imports.Count; idx[name] = i; _imports.Add(name);
                    BitConverter.TryWriteBytes(image.AsSpan((int)at, 4), 0xD4000001u | (uint)i << 5);   // svc #i
                    BitConverter.TryWriteBytes(image.AsSpan((int)at + 4, 4), 0xD65F03C0u);             // ret
                    TakenAt.Add(name);
                }
            _mm.Write(Img, image);
            var stubs = new byte[_imports.Count * 8 + 16];
            BitConverter.TryWriteBytes(stubs.AsSpan(_imports.Count * 8), 0xD4000001u);          // 调度循环：svc #0（交回上次结果、取下一个调用）
            BitConverter.TryWriteBytes(stubs.AsSpan(_imports.Count * 8 + 4), 0xD63F0200u);      // blr x16
            BitConverter.TryWriteBytes(stubs.AsSpan(_imports.Count * 8 + 8), 0x17FFFFFEu);      // b 回到 svc #0
            _loop = Stub + (ulong)_imports.Count * 8;
            for (int i = 1; i < _imports.Count; i++)
            {
                BitConverter.TryWriteBytes(stubs.AsSpan(i * 8), 0xD4000001u | (uint)i << 5);   // svc #i
                BitConverter.TryWriteBytes(stubs.AsSpan(i * 8 + 4), 0xD65F03C0u);             // ret
            }
            _mm.Write(Stub, stubs);
            _cpu = new JitEngine(new TickSource(19_200_000)).CreateCpuContext(_mm, true);
        }

        public int Imports => _imports.Count - 1;
        static readonly string[] Taken = { "malloc", "free", "calloc", "realloc", "aligned_alloc", "memalign", "_Znwm", "_Znam", "_ZdlPv", "_ZdaPv", "_ZdlPvm", "_ZdaPvm" };
        public readonly List<string> TakenAt = new();   // main 里被接管的分配函数（导出名）
        public void Write(ulong va, ReadOnlySpan<byte> data) => _mm.Write(va, data);
        public void Read(ulong va, Span<byte> data) => _mm.Read(va, data);
        public ulong Mark => _brk;
        public void Release(ulong mark) => _brk = mark;
        public ulong Alloc(ulong n, ulong align = 16)
        {
            ulong a = (_brk + align - 1) & ~(align - 1);
            if (a + n > Heap + _heapSize) throw new OutOfMemoryException($"客体堆不够：要 {n} 字节，已用 {_brk - Heap} / {_heapSize}");
            _brk = a + n; return a;
        }

        // 调客体函数 fn（AAPCS64：前 8 个整数参数走 x0–x7，其余每个 8 字节依次放栈上）→ x0。
        //   ARMeilleure 的翻译器在最后一个执行线程退出时整体收掉，不能每次调用进出一次 Execute：常驻一个执行线程停在调度循环（桩页末尾）里，
        //   每到 svc #0 交回上一次的 x0、取下一个调用摆好参数（x16 = 入口），blr 过去；出错时（未实现的导入、未定义指令）把这次调用判失败、线程照常回到循环
        public ulong Call(ulong fn, params ulong[] args)
        {
            if (_worker == null)
            {
                _worker = new System.Threading.Thread(() =>
                {
                    var ctx = _cpu.CreateExecutionContext(new ExceptionCallbacks(null, OnBreak, null, OnSvc, OnUndefined));
                    ctx.TpidrroEl0 = (long)Tls; ctx.TpidrEl0 = (long)Tls; ctx.SetX(31, (Stack + StackSize - 0x100) & ~0xFul);
                    _cpu.Execute(ctx, _loop);
                }, 64 << 20) { IsBackground = true, Name = "gamedec 客体" };
                _worker.Start();
            }
            _fault = null; _job = (fn, args);
            _go.Release(); _done.Wait();
            if (_fault != null) throw new InvalidOperationException(_fault);
            return _ret;
        }

        void Dispatch(IExecutionContext ctx)   // svc #0：上一次调用返回到这里
        {
            if (_started) { _ret = ctx.GetX(0); _done.Release(); }
            _started = true;
            if (!_quit) _go.Wait();
            if (_quit) { ctx.StopRunning(); ctx.SetX(16, Stub + 12); return; }   // 收尾：停止运行，blr 到一条 ret 桩（1 号导入桩的 ret），执行循环在下一个回跳处退出
            var (fn, args) = _job;
            int stackArgs = Math.Max(0, args.Length - 8);
            ulong sp = (Stack + StackSize - 0x100 - (ulong)stackArgs * 8) & ~0xFul;
            for (int i = 0; i < args.Length; i++)
                if (i < 8) ctx.SetX(i, args[i]);
                else _mm.Write(sp + (ulong)(i - 8) * 8, BitConverter.GetBytes(args[i]));
            ctx.SetX(31, sp); ctx.SetX(16, fn);
        }

        // 出错：这次调用判失败（_fault），客体栈与寄存器重摆、跳回调度循环（x30 = 循环入口，桩里的 ret 回去）
        void Stop(IExecutionContext ctx, string why) { _fault ??= why; ctx.SetX(30, _loop); ctx.SetX(0, 0); }
        void OnBreak(IExecutionContext ctx, ulong address, int imm) => Fatal($"客体执行到断点 brk #{imm}（main+{address - Img:x}）");
        void OnUndefined(IExecutionContext ctx, ulong address, int opcode) => Fatal($"客体执行到未定义指令 {opcode:x8}（main+{address - Img:x}）");
        bool _wedged;   // 执行线程停在 Fatal 里了：收尾不再等它（#854）
        void Fatal(string why) { _fault ??= why; _wedged = true; _done.Release(); System.Threading.Thread.Sleep(System.Threading.Timeout.Infinite); }   // 断点 / 未定义指令后没法安全接着跑：交回失败，执行线程就此停住

        void OnSvc(IExecutionContext ctx, ulong address, int imm)
        {
            if (imm == 0) { Dispatch(ctx); return; }   // 调度循环
            if (imm >= _imports.Count) { Stop(ctx, $"客体执行了 svc #{imm:x}（main+{address - Img:x}）：游戏代码在调系统服务，解码路径不该走到"); return; }
            string name = _imports[imm];
            if (Trace) Console.Error.WriteLine($"  导入 {name}(x0={ctx.GetX(0):x}, x1={ctx.GetX(1):x}, x2={ctx.GetX(2):x}) 自 x30={ctx.GetX(30) - Img:x}");
            ulong a0 = ctx.GetX(0), a1 = ctx.GetX(1), a2 = ctx.GetX(2);
            try
            {
                switch (name)
                {
                    case "memcpy": case "memmove": Copy(a0, a1, a2); break;   // x0 原样返回
                    case "memset": Fill(a0, (byte)a1, a2); break;
                    case "memcmp": ctx.SetX(0, (ulong)(long)Compare(a0, a1, a2)); break;
                    case "strlen": ctx.SetX(0, Strlen(a0)); break;
                    case "malloc": case "_Znwm": case "_Znam": ctx.SetX(0, Alloc(Math.Max(a0, 1))); break;
                    case "calloc": { ulong n = Math.Max(a0 * a1, 1); ulong p = Alloc(n); Fill(p, 0, n); ctx.SetX(0, p); break; }
                    case "aligned_alloc": case "memalign": ctx.SetX(0, Alloc(Math.Max(a1, 1), Math.Max(a0, 16))); break;
                    case "realloc": { ulong p = Alloc(Math.Max(a1, 1)); if (a0 != 0) Copy(p, a0, Math.Min(a1, _brk - a0)); ctx.SetX(0, p); break; }
                    case "free": case "_ZdlPv": case "_ZdaPv": case "_ZdlPvm": case "_ZdaPvm": break;   // 线性堆：调用结束整体收回
                    default: Stop(ctx, $"解码路径调到了未实现的导入函数 {name}（main 里没定义；本工具只实现 C 运行时的内存函数）"); break;
                }
            }
            catch (Exception e) { Stop(ctx, $"导入函数 {name} 出错：{e.Message}"); }
        }

        void Copy(ulong dst, ulong src, ulong n) { if (n == 0) return; var t = new byte[n]; _mm.Read(src, t); _mm.Write(dst, t); }
        void Fill(ulong dst, byte v, ulong n) { if (n == 0) return; var t = new byte[n]; if (v != 0) Array.Fill(t, v); _mm.Write(dst, t); }
        int Compare(ulong a, ulong b, ulong n) { var x = new byte[n]; var y = new byte[n]; _mm.Read(a, x); _mm.Read(b, y); return x.AsSpan().SequenceCompareTo(y); }
        ulong Strlen(ulong a) { ulong n = 0; var c = new byte[1]; for (; ; n++) { _mm.Read(a + n, c); if (c[0] == 0) return n; } }

        // 收尾：让常驻执行线程退出执行循环（Execute 返回、翻译器执行线程计数归零才收后台翻译线程），再释放翻译器与后备内存。
        //   不收的话 Windows 上进程解完不退（11-05 Windows 出包机：LZ5 对照 0.8 秒解完，进程挂到被杀；后台线程停在客体里，翻译器的线程还在）
        public void Dispose()
        {
            if (_worker == null || _wedged) return;   // 停住的执行线程等不回来：不白等 10 秒，翻译器交给进程退出（Program.Main 出错即 Environment.Exit）
            _quit = true; _go.Release();
            if (!_worker.Join(10_000)) return;   // 客体卡在别处退不出来：不释放仍在用的翻译器，交给进程退出
            _cpu.Dispose(); _backing.Dispose();
        }
    }
}
