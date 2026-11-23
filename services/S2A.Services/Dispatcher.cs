using Ryujinx.HLE;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;

namespace S2A.Services
{
    // 一个游戏会话背后的服务端。HLE 服务、sm、Horizon 服务各一种实现。
    abstract class SessionTarget
    {
        public abstract string Name { get; }

        // 处理一条消息：msg 是游戏内存里的 IPC 缓冲（原地读写）。返回值写进 x0（内核层结果，正常为 0）
        public abstract unsafe uint Process(Dispatcher d, byte* msg, int size);

        // 会话克隆（CMIF 控制命令 2 / 4）：同一个服务端再挂一个会话
        public virtual SessionTarget Clone() => this;

        // 会话根转域（CMIF 控制命令 0）：返回根对象号；null = 本会话不支持转域（报红）
        protected virtual int? ConvertToDomain() => null;

        // CMIF 控制消息（类型 5 / 6），同 Ryujinx ServerBase.Process：0 转域、3 指针缓冲大小、2 / 4 克隆会话（move 新句柄）。
        // cmd 由调用方从原始数据 SFCI 之后取。返回 true = 应答句柄已是游戏句柄（不再翻译）。
        // 控制消息不进差分 IPC 记录：真值只在 CallCmifMethod 里记，控制消息不经那里
        internal bool Control(Dispatcher d, uint cmd, IpcMessage response, Dispatcher.Streams s)
        {
            switch (cmd)
            {
                case 0: // ConvertCurrentObjectToDomain
                    {
                        int? root = ConvertToDomain();

                        if (root.HasValue)
                        {
                            FillControl(response, s, 0, root);
                            return false;
                        }

                        Red.Report("CMIF 控制命令 ConvertCurrentObjectToDomain：本会话不支持转域", Name);
                        FillControl(response, s, Red.ResultUnknownCommand, null);
                        return false;
                    }

                case 3: // QueryPointerBufferSize
                    FillControl(response, s, 0, Dispatcher.PointerBufferSize);
                    return false;

                case 2: // CloneCurrentObject
                case 4: // CloneCurrentObjectEx
                    {
                        uint h = d.NewSessionHandle(Clone());
                        response.HandleDesc = IpcHandleDesc.MakeMove((int)h);
                        FillControl(response, s, h != 0 ? 0 : Dispatcher.KernelHandleTableFull, null);
                        return true;
                    }

                default:
                    Red.Report($"CMIF 控制命令未支持 {cmd}", Name);
                    FillControl(response, s, Red.ResultUnknownCommand, null);
                    return false;
            }
        }

        private static void FillControl(IpcMessage response, Dispatcher.Streams s, long result, int? value)
        {
            response.Type = IpcMessageType.CmifResponse;
            s.Resp.SetLength(0);
            s.Writer.Write(IpcMagic.Sfco);
            s.Writer.Write(result);

            if (value.HasValue)
            {
                s.Writer.Write(value.Value);
            }
        }

        public virtual void Closed() { }

        // 分配拆账（S2A_ALLOC_TRACE=1）记账用的名字：缺省同 Name；域会话按消息里的域对象号细到对象类型（处理前取：处理后消息已是应答）
        public virtual unsafe string TraceName(byte* msg, int size) => Name;
    }

    // 影子会话对象：Ryujinx 服务 MakeObject 出的子会话先以此落进影子句柄表，写应答时换成游戏句柄
    sealed class S2ASessionObject : KAutoObject
    {
        public readonly ulong Cookie;

        public S2ASessionObject(KernelContext context, ulong cookie) : base(context)
        {
            Cookie = cookie;
        }
    }

    // 服务请求的同线程直调分发器（方案 §3-2 单一入口、接口 §3）。
    // 游戏线程经原生层 svc 跳板进来，就在本线程上解析 IPC 消息、调 Ryujinx 服务、写应答，不经 Ryujinx 的服务线程。
    // 「内核 IPC 拷贝句柄」那一步由本类做：请求里的游戏句柄换成影子句柄表里的对象，应答里的影子句柄换成游戏句柄。
    public sealed unsafe class Dispatcher
    {
        public const int PointerBufferSize = 0x8000; // 同 Ryujinx ServerBase
        public const uint KernelInvalidHandle = 0xE401;
        public const uint KernelHandleTableFull = 0xD201;

        public static Dispatcher Instance { get; private set; }

        internal Switch Device { get; }
        internal KernelContext Kernel { get; }
        internal KProcess ServerProcess { get; }   // 服务代码里的 context.Process：影子句柄表在这里
        internal KProcess GameProcess { get; }     // 游戏把 0xFFFF8001 当复制句柄递来时给服务的对象
        public GuestMemory Memory { get; }
        internal SmDirect Sm { get; }

        private readonly object _sessionLock = new();
        private SessionTarget[] _sessions = new SessionTarget[1024];
        private int _sessionCount;
        private int _freeHint;

        internal Dispatcher(Switch device, GuestMemory memory)
        {
            Device = device;
            Kernel = device.System.KernelContext;
            Memory = memory;

            // 服务进程：服务代码里 context.Process / Syscall.* 的落点（影子句柄表）。pid 取 Ryujinx 内建进程号段，不与游戏冲突
            ServerProcess = new KProcess(Kernel);
            ServerProcess.S2AInitializeForeign(Kernel.NewKipId(), new ProcessContext(memory));
            GameProcess = new KProcess(Kernel);
            GameProcess.S2AInitializeForeign(Native.ProcessId(), new ProcessContext(memory));
            Kernel.Processes.TryAdd(ServerProcess.Pid, ServerProcess);
            Kernel.Processes.TryAdd(GameProcess.Pid, GameProcess);

            Sm = new SmDirect(this);

            S2AHooks.MakeSession = &MakeSessionHook;
            S2AHooks.EventSignal = &EventSignalHook;
            S2AHooks.EventClear = &EventClearHook;
            S2AHooks.AppletOpenNative = Native.AppletOpenAdd;   // 系统小程序开着的个数报给原生停帧看门（接口 v2.18，D-Z96G）

            Instance = this;
        }

        public int OpenSessionCount { get { lock (_sessionLock) { return _sessionCount; } } }

        internal void CloseSessions()
        {
            EnterServiceThread();
            // Native has joined every guest thread before reaching here. Close each service once
            // (CMIF clones may share a target) while its kernel and native event table still exist.
            HashSet<SessionTarget> targets;
            lock (_sessionLock)
            {
                targets = new HashSet<SessionTarget>(_sessions.Where(t => t != null));
            }
            foreach (SessionTarget target in targets)
            {
                if (target is HleTarget hle) hle.Service.DestroyAtExit();
                target.Closed();
            }
            // 中途析构失败时继续保有目标引用，调用方封住会话且不再重试析构。
            lock (_sessionLock)
            {
                Array.Clear(_sessions);
                _sessionCount = _freeHint = 0;
            }
        }

        internal void Reset()
        {
            if (OpenSessionCount != 0) throw new InvalidOperationException("服务会话尚未关闭");
            // Foreign processes have no Ryujinx scheduler state: upstream Terminate() rejects
            // their Created state, so explicitly destroy their handle tables and remove them.
            ServerProcess.HandleTable.Destroy();
            GameProcess.HandleTable.Destroy();
            // A legacy service may already own the native game's PID, so TryAdd above
            // can leave that service in the table. Remove only our exact registration;
            // that service must remain for Horizon.Dispose to terminate its thread.
            Kernel.Processes.TryRemove(new KeyValuePair<ulong, KProcess>(ServerProcess.Pid, ServerProcess));
            Kernel.Processes.TryRemove(new KeyValuePair<ulong, KProcess>(GameProcess.Pid, GameProcess));
            ServerProcess.DecrementReferenceCount();
            GameProcess.DecrementReferenceCount();
            Sm.Horizon.Clear();
            if (ReferenceEquals(Instance, this)) Instance = null;
            ResetThread();
            Array.Clear(_inflight);
            _inflightNext = -1;
            lock (_alloc)
            {
                _alloc.Clear();
                _allocKeys.Clear();
                _gcSnap.Clear();
                Array.Clear(_svcKeys);
                _traceStart = GC.GetTotalAllocatedBytes();
                _gcProc = _gcThr = 0;
            }
        }

        internal static void ResetThread()
        {
            t_shadowThread = null;
            t_streams?.Reader.Dispose();
            t_streams?.Writer.Dispose();
            t_streams = null;
            t_owner = null;
            t_inflightSlot = 0;
            KernelStatic.SetKernelContext(null, null);
        }

        // ---------- 会话表（cookie = 下标 + 1） ----------

        // 即时存档重放：这条请求建的会话按存档时的 cookie 放（SnapLog.SessionCookiesOf）；那格被占了就照常按先后分配（重放会点名对不上的会话）
        internal Queue<ulong> SnapForceCookies;

        internal ulong AddSession(SessionTarget target)
        {
            lock (_sessionLock)
            {
                if (SnapForceCookies is { Count: > 0 } fq)
                {
                    ulong want = fq.Dequeue();
                    while (want > (ulong)_sessions.Length) Array.Resize(ref _sessions, _sessions.Length * 2);
                    if (want > 0 && _sessions[want - 1] == null) { _sessions[want - 1] = target; _sessionCount++; return want; }
                    Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：会话按原 cookie {want} 放，那格已被占，按先后分配");
                }
                for (int n = 0; n < _sessions.Length; n++)
                {
                    int i = (_freeHint + n) % _sessions.Length;

                    if (_sessions[i] == null)
                    {
                        _sessions[i] = target;
                        _sessionCount++;
                        _freeHint = i + 1;
                        return (ulong)i + 1;
                    }
                }

                Array.Resize(ref _sessions, _sessions.Length * 2);
                return AddSession(target);
            }
        }

        internal SessionTarget GetSession(ulong cookie)
        {
            lock (_sessionLock)
            {
                return cookie != 0 && cookie <= (ulong)_sessions.Length ? _sessions[cookie - 1] : null;
            }
        }

        internal void RemoveSession(ulong cookie)
        {
            SessionTarget t;

            lock (_sessionLock)
            {
                if (cookie == 0 || cookie > (ulong)_sessions.Length || _sessions[cookie - 1] == null)
                {
                    return;
                }

                t = _sessions[cookie - 1];
                _sessions[cookie - 1] = null;
                _sessionCount--;
            }

            t.Closed();
        }

        // 给游戏发一个会话句柄
        internal uint NewSessionHandle(SessionTarget target)
        {
            ulong cookie = AddSession(target);
            if (SnapSwitch.Save) SnapLog.SessionCreated(cookie);   // 即时存档：新会话挂到建它的那条请求名下（请求日志按活对象收，SnapLog.cs ReqTable）
            uint h = Native.HandleNew((uint)ObjKind.Session, cookie);

            if (h == 0)
            {
                RemoveSession(cookie);
                Red.Report("原生句柄表满（会话）", target.Name);
            }

            return h;
        }

        // ---------- 单一入口 ----------

        public int Svc(SvcCtx* c)
        {
            ulong* r = c->Regs;

            EnterServiceThread();

            switch (c->Num)
            {
                case 0x1F: // ConnectToNamedPort(x1 = 名字) -> x1 = 会话句柄
                    {
                        string name = Utf8Z((byte*)r[1], 12);

                        if (name != "sm:")
                        {
                            Red.Report($"ConnectToNamedPort 未支持的端口 {name}");
                            r[0] = 0xF201; // NotFound 类：kernel NotImplemented
                            return SvcResult.Handled;
                        }

                        if (SnapSwitch.Save) SnapLog.Connect();   // 即时存档：sm: 会话的建立也进请求日志（句柄按序号打标）
                        uint h = NewSessionHandle(Sm);
                        if (SnapSwitch.Save) SnapLog.End();
                        r[0] = h != 0 ? 0u : 0xD201u; // 句柄表满：OutOfHandles
                        r[1] = h;
                        return SvcResult.Handled;
                    }

                case 0x21: // SendSyncRequest(会话)：消息在 TLR
                    _snapNum = 0x21;
                    r[0] = Request(c->Obj, c->Tlr, 0x100);
                    return SvcResult.Handled;

                case 0x22: // SendSyncRequestWithUserBuffer(x0 = 缓冲, x1 = 大小, 会话)
                    _snapNum = 0x22;
                    r[0] = Request(c->Obj, (byte*)r[0], (int)Math.Min(r[1], 0x10000));
                    return SvcResult.Handled;

                default:
                    return SvcResult.Unhandled; // 原生层报红（调用号）
            }
        }

        // 即时存档：当前请求的调用号（0x21 / 0x22），记日志用
        [ThreadStatic] private static uint _snapNum;
        // 即时存档恢复重放入口（SnapLog.Replay 调）：同生产 Svc 的会话建立 / 请求路径
        internal uint SnapConnect() { EnterServiceThread(); return NewSessionHandle(Sm); }
        internal uint SnapRequest(uint num, ulong cookie, byte* msg, int size) { EnterServiceThread(); _snapNum = num; return Request(cookie, msg, size); }

        // 服务级请求跟踪（S2A_IPC_TRACE=1，定位用，开着会分配）：每条请求打服务名、请求原始字节、应答原始字节
        internal static readonly bool TraceIpc = Environment.GetEnvironmentVariable("S2A_IPC_TRACE") == "1";

        // 每帧分配拆账（S2A_ALLOC_TRACE=1，定位用，开着会分配）：游戏线程上每条服务请求按（服务, 命令号）累计本线程分配，收局打前 20
        internal static readonly bool TraceAlloc = StartAllocTrace();

        // 局可能被墙钟上限直接杀掉、走不到收局：开着时每 30 秒打一次汇总
        private static bool StartAllocTrace()
        {
            if (Environment.GetEnvironmentVariable("S2A_ALLOC_TRACE") != "1")
            {
                return false;
            }

            _traceStart = GC.GetTotalAllocatedBytes(true);

            new System.Threading.Thread(() =>
            {
                // 线程池工作线程的循环在运行时里挂不了点：每秒往线程池投 8 个探针任务，取到探针的工作线程 Tick 一次，
                // 两次探针之间它执行的全部工作项的分配就记到它名下（「线程池」）
                // 10-26 加密到每 100 ms 投 16 个：每秒 8 个时空闲后才被唤起的工作线程常常整段没取到探针，它的分配落进核对差额
                for (int tick = 1; ; tick++)
                {
                    System.Threading.Thread.Sleep(100);

                    for (int i = 0; i < 16; i++)
                    {
                        System.Threading.ThreadPool.UnsafeQueueUserWorkItem(static _ => Ryujinx.Common.S2AThreadAlloc.Tick("线程池"), null);
                    }

                    if (tick % 300 == 0)
                    {
                        Ryujinx.Common.S2AThreadAlloc.Tick("拆账打印");
                        // 每批都列全部（10-22：中间批只打前 20，MARK 后增量里前一批没列出的项被当成从 0 涨起，读成假大户）
                        Console.Error.WriteLine(AllocSummary(all: true));
                    }
                }
            }) { IsBackground = true, Name = "S2A.AllocTrace" }.Start();

            return true;
        }
        private static readonly Dictionary<string, (long Bytes, long Calls)> _alloc = new();
        private static long _traceStart;

        // CMIF 域消息的目标对象号：SFCI 头前 16 字节是域头（u8 请求类型 1 = SendMessage、u8 入对象数、u16 数据长、u32 对象号）；
        // 不是域消息（找不到 SFCI 或前面不是域头）返回 0。只对已知是域的会话调用
        internal static int DomainObjectId(byte* msg, int size)
        {
            for (int i = 16; i + 12 <= Math.Min(size, 0x100); i += 4)
            {
                if (*(uint*)(msg + i) == 0x49434653)
                {
                    return msg[i - 16] == 1 ? *(int*)(msg + i - 12) : 0;
                }
            }

            return 0;
        }

        private static long CommandId(byte* msg, int size)
        {
            int type = (int)(*(uint*)msg & 0xFFFF);

            if (type >= 0x10)
            {
                return type - 0x10;   // TIPC
            }

            for (int i = 0; i + 12 <= Math.Min(size, 0x100); i += 4)
            {
                if (*(uint*)(msg + i) == 0x49434653)   // "SFCI"
                {
                    // nvdrv Ioctl 系（#1 / #11 / #12）：原始数据是 fd、ioctl 号，拆账带上 ioctl 号（高 32 位）
                    uint cmd = *(uint*)(msg + i + 8);
                    return i + 24 <= size ? (long)*(uint*)(msg + i + 20) << 32 | cmd : cmd;
                }
            }

            return -1;   // 关会话等无 CMIF 头的请求
        }

        // 账目名按（服务, 命令号）缓存：拆账自己每次请求拼一个字符串会落在计量区间外，成了「各线程之和对不上整进程」的差额（约 20 KB/s）
        private static readonly Dictionary<(string, long), string> _allocKeys = new();
        private static readonly string[] _svcKeys = new string[0x100];

        private static void AllocAccount(string name, long cmd, long bytes)
        {
            string key;

            lock (_alloc)
            {
                if (!_allocKeys.TryGetValue((name, cmd), out key))
                {
                    uint id = (uint)cmd, sub = (uint)((ulong)cmd >> 32);
                    key = name.Contains("NvDrv") && id is 1 or 11 or 12 ? $"{name} #{id} ioctl 0x{sub:X8}" : $"{name} #{(cmd < 0 ? -1 : id)}";
                    _allocKeys[(name, cmd)] = key;
                }
            }

            AllocAccountKey(key, bytes);
        }

        private static void AllocAccountKey(string key, long bytes)
        {
            lock (_alloc)
            {
                _alloc.TryGetValue(key, out (long Bytes, long Calls) e);
                _alloc[key] = (e.Bytes + bytes, e.Calls + 1);
            }
        }

        // 按 GC 间隔拆账（10-23 测试出包线：加载 / 开局期一次 gen1 晋升 13–20 MB、停顿 13–38 ms，20 秒一次的累计表对不上是哪一次 GC）：
        //   NxFrames 每打一行 [gc] 调一次（只在 S2A_ALLOC_TRACE=1 时挂上，Compose），列本次与上次 GC 之间游戏线程各服务请求的分配增量（≥ 64 KB 的全列）、长驻线程合计、整进程
        private static readonly Dictionary<string, long> _gcSnap = new();
        private static long _gcProc, _gcThr;

        public static string AllocSinceLastGc()
        {
            lock (_alloc)
            {
                List<(string Key, long D)> items = new();
                long sum = 0;
                foreach (KeyValuePair<string, (long Bytes, long Calls)> kv in _alloc)
                {
                    long d = kv.Value.Bytes - (_gcSnap.TryGetValue(kv.Key, out long s) ? s : 0);
                    _gcSnap[kv.Key] = kv.Value.Bytes;
                    if (d > 0) { sum += d; items.Add((kv.Key, d)); }
                }

                long proc = GC.GetTotalAllocatedBytes(true), thr = Ryujinx.Common.S2AThreadAlloc.Total();
                StringBuilder sb = new($"[分配·GC间隔] 整进程 {(proc - _gcProc) / 1024} KB；游戏线程服务请求 {sum / 1024} KB；长驻线程 {(thr - _gcThr) / 1024} KB（渲染线程见下行）");
                _gcProc = proc; _gcThr = thr;
                foreach ((string k, long d) in items.OrderByDescending(x => x.D))
                {
                    if (d < 65536) break;
                    sb.Append($"\n[分配·GC间隔]   {k}：{d / 1024} KB");
                }

                return sb.ToString();
            }
        }

        internal static void AllocAccountBetween(long bytes) => AllocAccountKey("游戏线程·两次系统调用之间（直连回调：宽屏导出等，细分见 [分配·线程] 宽屏导出·*）", bytes);

        internal static void AllocAccountSvc(uint num, long bytes) => AllocAccountKey(_svcKeys[num & 0xFF] ??= $"系统调用 0x{num:X2}", bytes);

        // all：关停时的最后一份列全部账目（只打前 20 时小项不出现，会被读成 0；10-20 拆账截断误读）
        internal static string AllocSummary(bool all = false)
        {
            lock (_alloc)
            {
                long total = 0;

                foreach ((long b, _) in _alloc.Values)
                {
                    total += b;
                }

                StringBuilder sb = new($"[分配] 游戏线程服务请求共 {total / 1024} KB（全进程 {GC.GetTotalAllocatedBytes() / 1024} KB）；{(all ? $"全部 {_alloc.Count} 项" : "前 20")}：");

                foreach (KeyValuePair<string, (long Bytes, long Calls)> kv in _alloc.OrderByDescending(kv => kv.Value.Bytes).Take(all ? int.MaxValue : 20))
                {
                    sb.Append($"\n[分配]   {kv.Key}：{kv.Value.Bytes / 1024} KB / {kv.Value.Calls} 次（{kv.Value.Bytes / Math.Max(1, kv.Value.Calls)} B/次）");
                }

                long proc = GC.GetTotalAllocatedBytes(true) - _traceStart, threads = Ryujinx.Common.S2AThreadAlloc.Total();
                sb.Append($"\n[分配·核对] 开拆账以来 整进程 {proc / 1024} KB；游戏线程（全部系统调用）{total / 1024} KB + 长驻线程 {threads / 1024} KB = {(total + threads) / 1024} KB；差额 {(proc - total - threads) / 1024} KB（{(proc == 0 ? 0 : 100.0 * (proc - total - threads) / proc):F1}%，未挂点的线程：线程池等）");
                sb.Append('\n').Append("[分配·线程] 长驻线程每圈分配（游戏线程见上，渲染线程见 frames.tsv alloc_gpu_b）：\n").Append(Ryujinx.Common.S2AThreadAlloc.Summary());

                return sb.ToString();
            }
        }

        // 在途请求登记（收局诊断，10-21 暗黑2 29/50 局收局「还有 1 个系统调用在 C# 里没回」，原生层只知道个数）：
        // 每条线程第一次进来领一个槽，处理前记会话 / 命令号 / 开始时刻、处理后清空；收局时 InflightSummary 列出还没回的。
        // 槽里只放已有对象的引用和数，稳态不分配
        private struct Inflight { public SessionTarget T; public long Cmd; public long Since; public string Thread; }
        private const int MaxInflight = 256;
        private static readonly Inflight[] _inflight = new Inflight[MaxInflight];
        private static int _inflightNext = -1;
        [ThreadStatic] private static int t_inflightSlot;   // 0 = 还没领（槽号存 +1）

        private static int InflightSlot()
        {
            int s = t_inflightSlot - 1;

            if (s < 0)
            {
                s = System.Threading.Interlocked.Increment(ref _inflightNext);
                t_inflightSlot = s + 1;
                _inflight[s < MaxInflight ? s : MaxInflight - 1].Thread = System.Threading.Thread.CurrentThread.Name ?? $"tid {Environment.CurrentManagedThreadId}";
            }

            return s < MaxInflight ? s : -1;
        }

        // 收局时还没回的请求：「服务 命令 N（已等 X ms，线程 T）」，没有返回 null
        public static string InflightSummary()
        {
            StringBuilder sb = null;
            long now = System.Diagnostics.Stopwatch.GetTimestamp();

            for (int i = 0; i < MaxInflight; i++)
            {
                Inflight f = _inflight[i];

                if (f.T == null)
                {
                    continue;
                }

                (sb ??= new StringBuilder()).Append(sb.Length == 0 ? "" : "；").Append($"{f.T.Name} 命令 {f.Cmd}（已等 {(now - f.Since) * 1000 / System.Diagnostics.Stopwatch.Frequency} ms，线程 {f.Thread}）");
            }

            return sb?.ToString();
        }

        private uint Request(ulong cookie, byte* msg, int size)
        {
            int slot = InflightSlot();

            if (slot < 0)
            {
                return RequestCore(cookie, msg, size);
            }

            ref Inflight f = ref _inflight[slot];
            f.Cmd = CommandId(msg, size);
            f.Since = System.Diagnostics.Stopwatch.GetTimestamp();

            try
            {
                return RequestCore(cookie, msg, size, ref f);
            }
            finally
            {
                System.Threading.Volatile.Write(ref f.T, null);
            }
        }

        private uint RequestCore(ulong cookie, byte* msg, int size)
        {
            Inflight none = default;

            return RequestCore(cookie, msg, size, ref none);
        }

        private uint RequestCore(ulong cookie, byte* msg, int size, ref Inflight f)
        {
            // 代行内核：请求带进程号（特殊头 HasPId）时，内核把发送方的真实进程号写进去（游戏 SDK 只留占位）
            uint* w = (uint*)msg;

            if ((w[1] >> 31) != 0 && (w[2] & 1) != 0)
            {
                *(ulong*)(msg + 12) = GameProcess.Pid;
            }

            SessionTarget t = GetSession(cookie);

            if (t == null)
            {
                Red.Report("SendSyncRequest 的会话不在 C# 会话表", $"cookie={cookie}");
                return KernelInvalidHandle;
            }

            System.Threading.Volatile.Write(ref f.T, t);

            if (SnapSwitch.Save)
            {
                int seq = SnapLog.Begin(_snapNum, cookie, t, msg, size, CommandId(msg, size));
                try { return RequestCoreTail(t, msg, size); }
                finally { SnapLog.End(seq, msg, size); }   // 处理后消息缓冲已是应答：失败的这条记成「当时失败」，恢复时不重放
            }

            return RequestCoreTail(t, msg, size);
        }

        private uint RequestCoreTail(SessionTarget t, byte* msg, int size)
        {

            if (TraceAlloc)
            {
                // 处理前取：处理后消息缓冲已是应答
                long cmd = CommandId(msg, size);
                string name = t.TraceName(msg, size);
                long a0 = GC.GetAllocatedBytesForCurrentThread();
                uint r = t.Process(this, msg, size);
                AllocAccount(name, cmd, GC.GetAllocatedBytesForCurrentThread() - a0);
                return r;
            }

            if (!TraceIpc)
            {
                return t.Process(this, msg, size);
            }

            string req = Convert.ToHexString(new ReadOnlySpan<byte>(msg, Math.Min(size, 0x60)));
            uint rc = t.Process(this, msg, size);
            Console.Error.WriteLine($"[IPC] {t.Name} 请求 {req}");
            Console.Error.WriteLine($"[IPC] {t.Name} 应答 rc=0x{rc:X} {Convert.ToHexString(new ReadOnlySpan<byte>(msg, Math.Min(size, 0x60)))}");
            return rc;
        }

        public void HandleClosed(uint kind, ulong cookie)
        {
            if ((ObjKind)kind == ObjKind.Session)
            {
                RemoveSession(cookie);
                if (SnapSwitch.Save) SnapLog.SessionClosed(cookie);   // 即时存档：会话关了，它和它的域对象的请求、建它的那条从请求日志收掉
            }
        }

        // ---------- 句柄翻译（代行内核 IPC 的句柄拷贝） ----------

        // 请求里的游戏句柄 → 影子句柄表里的对象
        internal uint TranslateRequestHandles(IpcHandleDesc desc)
        {
            if (desc == null)
            {
                return 0;
            }

            int copies = desc.ToCopy.Length;
            int count = copies + desc.ToMove.Length;
            // HIPC carries at most 15 copy and 15 move handles. Publish only once
            // every translation succeeds; a rejected request must not reach HLE.
            Span<int> shadow = stackalloc int[count];
            Span<ulong> retainedEvents = stackalloc ulong[count];
            for (int i = 0; i < count; i++)
            {
                uint handle = (uint)(i < copies ? desc.ToCopy[i] : desc.ToMove[i - copies]);
                uint result = ToShadow(handle, out shadow[i], out retainedEvents[i]);
                if (result != 0)
                {
                    // These objects have not been delivered to the service. Undo
                    // only the handles and native event references from this request.
                    for (int j = 0; j < i; j++)
                    {
                        if (shadow[j] != 0) ServerProcess.HandleTable.CloseHandle(shadow[j]);
                        if (retainedEvents[j] != 0) Native.EventRelease(retainedEvents[j]);
                    }
                    return result;
                }
            }

            shadow[..copies].CopyTo(desc.ToCopy);
            shadow[copies..].CopyTo(desc.ToMove);
            return 0;
        }

        private uint ToShadow(uint h, out int shadow, out ulong retainedEvent)
        {
            shadow = 0;
            retainedEvent = 0;
            // Upstream KServerSession treats a literal zero as an empty handle.
            // That is distinct from translating a nonzero invalid handle to zero.
            if (h == 0) return 0;

            uint kind;
            ulong cookie;

            if (Native.HandleGet(h, &kind, &cookie) == 0)
            {
                Red.Report("服务请求递来无效句柄", $"0x{h:X}");
                return KernelInvalidHandle;
            }

            KAutoObject obj;

            switch ((ObjKind)kind)
            {
                case ObjKind.Tmem:
                    {
                        ulong addr, size;
                        uint perm;
                        Native.TmemGet(h, &addr, &size, &perm);
                        KTransferMemory tm = new(Kernel);
                        tm.S2AInitializeForeign(GameProcess, addr, size, (KMemoryPermission)perm);
                        obj = tm;
                        break;
                    }

                case ObjKind.Process:
                    obj = GameProcess;
                    break;

                case ObjKind.EventR:
                case ObjKind.EventW:
                    {
                        // 服务可能跨请求持有游戏递来的事件：先 retain（接口 v2.1），影子 KEvent 不释放，随服务生命周期
                        Native.EventRetain(cookie);
                        retainedEvent = cookie;
                        KEvent ev = new(Kernel);
                        ev.ReadableEvent.S2ANativeEvent = cookie;
                        obj = (ObjKind)kind == ObjKind.EventR ? ev.ReadableEvent : ev.WritableEvent;
                        break;
                    }

                default:
                    Red.Report($"服务请求递来未支持的句柄种类 {(ObjKind)kind}");
                    return KernelInvalidHandle;
            }

            uint result = (uint)ServerProcess.HandleTable.GenerateHandle(obj, out shadow).ErrorCode;
            if (result != 0 && retainedEvent != 0)
            {
                Native.EventRelease(retainedEvent);
                retainedEvent = 0;
            }
            return result;
        }

        // 应答里的影子句柄 → 游戏句柄。返回内核结果（0 = 成功）：失败时游戏的 SendSyncRequest 收到它，不收到这份应答（审计 #1534 P1-52）。
        //   同上游 KServerSession.Reply：move 句柄无论成败都从服务端表移除（失败后其余 move 句柄 CloseHandle）；
        //   失败时本次已发给游戏的新句柄全部收回，移交没成的子会话按「句柄被关」移出会话表（客户端句柄关了，会话就关了）
        internal uint TranslateResponseHandles(IpcHandleDesc desc)
        {
            if (desc == null)
            {
                return 0;
            }

            int copies = desc.ToCopy.Length;
            int count = copies + desc.ToMove.Length;
            // HIPC 最多 15 个 copy、15 个 move：全部翻译成功才写回描述符
            Span<uint> native = stackalloc uint[count];
            Span<ulong> movedSessions = stackalloc ulong[count];
            uint result = 0;

            for (int i = 0; i < count; i++)
            {
                bool move = i >= copies;
                int sh = move ? desc.ToMove[i - copies] : desc.ToCopy[i];
                native[i] = 0;
                movedSessions[i] = 0;

                if (sh == 0)
                {
                    continue;
                }

                if (result == 0)
                {
                    result = ToNative(sh, out native[i]);
                }

                if (move)
                {
                    if (native[i] == 0 && ServerProcess.HandleTable.GetObject<KAutoObject>(sh) is S2ASessionObject so)
                    {
                        movedSessions[i] = so.Cookie;
                    }

                    ServerProcess.HandleTable.CloseHandle(sh);
                }
            }

            if (result != 0)
            {
                for (int i = 0; i < count; i++)
                {
                    if (native[i] != 0)
                    {
                        Native.HandleClose(native[i]);
                    }
                    else if (movedSessions[i] != 0)
                    {
                        RemoveSession(movedSessions[i]);
                    }
                }

                return result;
            }

            for (int i = 0; i < count; i++)
            {
                if (i < copies)
                {
                    desc.ToCopy[i] = (int)native[i];
                }
                else
                {
                    desc.ToMove[i - copies] = (int)native[i];
                }
            }

            return 0;
        }

        private uint ToNative(int sh, out uint h)
        {
            h = 0;
            KAutoObject obj = ServerProcess.HandleTable.GetObject<KAutoObject>(sh);

            switch (obj)
            {
                case S2ASessionObject so:
                    h = Native.HandleNew((uint)ObjKind.Session, so.Cookie);
                    break;

                case KReadableEvent re:
                    h = EventHandleFor(re);
                    break;

                case KSharedMemory shm:
                    if (shm.S2APageList.Nodes.Count != 1)
                    {
                        Red.Report($"共享内存后备不连续（{shm.S2APageList.Nodes.Count} 段），应答句柄翻译失败");
                        return KernelInvalidHandle;
                    }

                    h = SharedMemoryHandleFor(shm);
                    break;

                case null:
                    Red.Report("服务应答里的句柄不在影子句柄表，应答翻译失败", $"0x{sh:X}");
                    return KernelInvalidHandle;

                default:
                    Red.Report($"服务应答递出未支持的对象 {obj.GetType().Name}，应答翻译失败");
                    return KernelInvalidHandle;
            }

            if (h == 0)
            {
                // 支持的种类发不出游戏句柄 = 原生句柄表满：同 Horizon 目标进程句柄表满（HandleTableFull，描述 105）
                Red.Report($"服务应答给游戏发句柄失败（原生句柄表满），对象 {obj.GetType().Name}");
                return KernelHandleTableFull;
            }

            return 0;
        }

        internal static uint EventHandleFor(KReadableEvent re)
        {
            if (re.S2ANativeEvent != 0)
            {
                // 同一事件再次交给游戏（复制句柄）：给已绑定的原生事件再发一个读端句柄
                return Native.EventDupRead(re.S2ANativeEvent);
            }

            uint hr = 0;
            ulong ev = Native.EventCreate(&hr, null);

            if (ev == 0)
            {
                return 0;   // 原生句柄表满：不绑定，调用方按发句柄失败处理
            }

            re.S2ANativeEvent = ev;

            if (re.IsSignaled())
            {
                Native.EventSignal(ev);
            }

            return hr;
        }

        private uint SharedMemoryHandleFor(KSharedMemory shm)
        {
            KPageList pages = shm.S2APageList;   // 调用方（ToNative）已核过只有一段
            KPageNode node = pages.Nodes.First.Value;
            ulong offset = node.Address - DramMemoryMap.DramBase;
            byte* host = (byte*)Device.Memory.GetPointer(offset, node.PagesCount * KPageTableBase.PageSize);

            return Native.ShmemWrap(host, node.PagesCount * KPageTableBase.PageSize);
        }

        // ---------- Ryujinx 挂钩 ----------

        private static int MakeSessionHook(IpcService obj)
        {
            Dispatcher d = Instance;
            ulong cookie = d.AddSession(new HleTarget(obj));
            if (SnapSwitch.Save) SnapLog.SessionCreated(cookie);   // HLE 服务交出的非域对象也是新会话：挂到正在处理的那条请求名下（请求日志按活对象收、重放按原 cookie 分配）
            d.ServerProcess.HandleTable.GenerateHandle(new S2ASessionObject(d.Kernel, cookie), out int sh);
            return sh;
        }

        private static void EventSignalHook(ulong ev) => Native.EventSignal(ev);

        private static void EventClearHook(ulong ev) => Native.EventClear(ev);

        // ---------- 工具 ----------

        internal static string Utf8Z(byte* p, int max)
        {
            int n = 0;

            while (n < max && p[n] != 0)
            {
                n++;
            }

            return System.Text.Encoding.ASCII.GetString(p, n);
        }

        // 游戏线程第一次进服务代码时挂一个影子 KThread（属服务进程），之后 KernelStatic.GetCurrentProcess() 即服务进程，
        // 与 Ryujinx 服务线程上的语义相同（服务里的 Syscall.CloseHandle / GetProcessId 等落到影子句柄表）
        [ThreadStatic] private static KThread t_shadowThread;
        [ThreadStatic] private static Dispatcher t_owner;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal void EnterServiceThread()
        {
            if (!ReferenceEquals(t_owner, this))
            {
                ResetThread();
                t_owner = this;
            }
            if (t_shadowThread == null)
            {
                KThread t = new(Kernel);
                t.S2ASetOwner(ServerProcess);
                KernelStatic.SetKernelContext(Kernel, t);
                t_shadowThread = t;
            }
        }

        // 每个游戏线程一套请求 / 应答数据流（服务代码经 BinaryReader / BinaryWriter 读写原始数据），首次进 C# 建一次
        [ThreadStatic] private static Streams t_streams;

        internal sealed class Streams
        {
            public readonly MemoryStream Req = new(0x200);
            public readonly MemoryStream Resp = new(0x200);
            public readonly BinaryReader Reader;
            public readonly BinaryWriter Writer;
            public readonly IpcMessage Request = new();
            public readonly IpcMessage Response = new();
            public readonly ServiceCtx Context = new(null, null, null, null, null, null, null, null);

            public Streams()
            {
                Reader = new BinaryReader(Req);
                Writer = new BinaryWriter(Resp);
            }
        }

        internal static Streams ThreadStreams
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            get => t_streams ??= new Streams();
        }
    }
}
