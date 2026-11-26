// 即时存档（开关在原生层 runtime/src/snapsw.c：苹果端缺省开、S2A_SNAP_MODE=0 关；恢复局 S2A_SNAP_RESTORE）：服务请求的压缩日志与恢复时重放。
//   存档模式（能存、非恢复）：每条服务请求（去掉无状态高频命令、写盘 / 提交类）记下整条消息与输入缓冲内容；
//     原生层同时记句柄创建 / 关闭的有序日志（thread.c hlog），每条请求建的句柄按请求序号打标。
//   恢复（S2A_SNAP_RESTORE）：B 正常起好服务层后，原生层恢复完内存与游戏自建的句柄，调 S2A_SnapReplay 按序重放；
//     每条请求前让原生层按 A 的值强制分配本条会建的句柄，请求后按日志穿插执行关闭——会话 cookie、句柄值、域对象号都与 A 一致。
//     消息与输入 / 输出缓冲放进窗口里的暂存区（服务按游戏地址读写，描述符地址只有 39 位），不碰已恢复的游戏内存。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Ryujinx.Audio.Renderer.Server;

namespace S2A.Services
{
    // 开关单放一个小类：热路径（每条请求）只读这里的布尔值，开关关着时不触发 SnapLog 的静态初始化（日志缓冲、字典等一概不建）
    //   开关值不在这里读环境变量，读原生层的唯一定义处（runtime/src/snapshot.c s2a_snap_saving / s2a_snap_mode），三层同一个判定
    internal static class SnapSwitch
    {
        [DllImport("s2a_native")] private static extern int s2a_snap_saving();
        [DllImport("s2a_native")] private static extern int s2a_snap_mode();
        [DllImport("s2a_native")] private static extern int s2a_snap_logging();
        // 能存 / 存档或恢复：每次现读原生层（snapsw.c）。原先是静态只读、进程里第一局定死——第一局因地址关了快照（s2a_snap_disable）时，
        //   同一进程里之后的恢复局（游戏库「回到这一刻」、进程内重启）读到的仍是「关」，服务层数据根（DataRoot）没登记，
        //   恢复核对报「服务层数据根与快照时不同（当前 空）」停下（11-22 实测）。开关只在每局起服务层 / 重建时读，现读不在热路径上
        internal static bool CanSave => Read(s2a_snap_saving);   // 起局带了存档开关（恢复局也可以带：回到那一刻之后还能再存）
        internal static bool Any => Read(s2a_snap_mode);         // 存档或恢复
        private static bool Read(Func<int> f)
        {
            try { return f() != 0; }
            catch (DllNotFoundException) { return false; }
            catch (EntryPointNotFoundException) { return false; }
        }
        // 正在记请求日志：普通局开局即记；恢复局重放时不记，重放完把快照里的日志接上当开头后再记（SnapLog.Replay 末尾置）。热路径每条请求读一次
        internal static volatile bool Save;

        // 没链原生层（服务层单测用托管假原生层，没有 s2a_native 库 / 入口）：存不了快照，开关按关
        static SnapSwitch()
        {
            try { Save = s2a_snap_logging() != 0; }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }
    }

    // 服务请求日志（内存里）：新写的进尾巴，尾巴满 1 MB 压成一块（Deflate 最快档；三款实测请求日志压到 1/4 左右）。存盘 = 「SLZ1」+ 各块（原长、压后长、数据）；
    //   读回认头，没有头的是旧快照的原样日志
    internal sealed class ReqLog
    {
        private const int ChunkRaw = 1 << 20;
        private static readonly byte[] Magic = "SLZ1"u8.ToArray();
        private readonly MemoryStream _tail = new();
        private readonly List<(int Raw, byte[] Z)> _chunks = new();
        private long _raw, _z;
        public readonly BinaryWriter W;
        public ReqLog() { W = new BinaryWriter(_tail); }
        public long Length => _raw + _tail.Length;    // 原始字节
        public long Stored => _z + _tail.Length;      // 内存里实际占的
        public void Seal(bool force = false)
        {
            W.Flush();
            if (_tail.Length == 0 || (!force && _tail.Length < ChunkRaw)) return;
            byte[] z = Deflate(_tail.GetBuffer(), (int)_tail.Length);
            _chunks.Add(((int)_tail.Length, z)); _raw += _tail.Length; _z += z.Length; _tail.SetLength(0);
        }
        public void Reset() { W.Flush(); _tail.SetLength(0); _chunks.Clear(); _raw = _z = 0; }
        public void SaveTo(string path)
        {
            Seal(force: true);
            using var f = File.Create(path); var w = new BinaryWriter(f);
            w.Write(Magic);
            foreach (var (raw, z) in _chunks) { w.Write(raw); w.Write(z.Length); w.Write(z); }
            w.Flush();
        }
        public static byte[] Load(byte[] file)
        {
            if (file.Length < 4 || !file.AsSpan(0, 4).SequenceEqual(Magic)) return file;
            var r = new BinaryReader(new MemoryStream(file, 4, file.Length - 4)); var o = new MemoryStream();
            while (r.BaseStream.Position < r.BaseStream.Length)
            {
                int raw = r.ReadInt32(), zl = r.ReadInt32(); byte[] z = r.ReadBytes(zl);
                using var ds = new System.IO.Compression.DeflateStream(new MemoryStream(z), System.IO.Compression.CompressionMode.Decompress);
                long before = o.Length; ds.CopyTo(o);
                if (o.Length - before != raw) throw new InvalidDataException($"请求日志块解开长度不对（期望 {raw}，实得 {o.Length - before}）");
            }
            return o.ToArray();
        }
        private static byte[] Deflate(byte[] b, int n)
        {
            var o = new MemoryStream(n / 3 + 64);
            using (var ds = new System.IO.Compression.DeflateStream(o, System.IO.Compression.CompressionLevel.Fastest, leaveOpen: true)) ds.Write(b, 0, n);
            return o.ToArray();
        }
    }

    internal static unsafe class SnapLog
    {
        internal static bool On => SnapSwitch.Save;
        private static int _maxSeq = -1;

        // 日志按「完成」的先后写（请求开始时把消息记在本线程，处理完才追加）：几条线程的请求在服务层里交错，按开始先后重放，
        //   域对象号、句柄的建与关先后都可能和存档那局不同（一款 Switch 2 游戏：后开始的 OpenFile 先拿到对象号 5、关掉后先开始的 OpenDirectory 才拿到 5）。
        //   存档那一刻还没完成的请求不在日志里：恢复时游戏线程从入口重发它。
        // EntFailed：当时服务回了错误码的请求，只记序号、不重放（没建任何服务状态；B 里文件系统已是快照那一刻的样子，A 当时「文件不存在」的打开在 B 里会成功，多出一个域对象）
        // EntObjs：紧跟在它那条请求后面，这条请求交出的域对象号；重放时按这些号分配
        private const uint EntReq = 1, EntConnect = 2, EntFailed = 4, EntObjs = 5;
        [ThreadStatic] private static byte[] _pending;          // 本线程正在处理、要进日志的请求（开始时序列化，完成时追加）
        [ThreadStatic] private static List<int> _pendingIds;    // 它交出的域对象号
        [ThreadStatic] private static bool _pendingTipc;        // 它是 TIPC 请求（应答的结果码是原始数据第 1 个字，没有 CMIF 应答头）
        private static readonly object _lock = new();
        // 请求日志 = 条目表（ReqTable）：大小跟此刻活着的服务对象走，不随游玩时长涨（真机大乱斗原先 8 分钟 128 MB）。存盘照旧分块压缩（ReqLog）
        private static readonly ReqTable _tab = NewTable();
        private static ReqTable NewTable()
        {
            var t = new ReqTable();
            t.HasLiveHandles = s => s2a_snap_seq_live(s) != 0;
            t.Unuse = u => s2a_snap_handle_unuse(u);
            t.Forget = s => s2a_snap_hlog_forget(s);
            t.Gone = k => { _lastNifm.Remove(k); if (k.Obj != 0) return; foreach (var key in new List<ReqTable.Key>(_lastNifm.Keys)) if (key.Cookie == k.Cookie) _lastNifm.Remove(key); _lastUpdate.Remove(k.Cookie); foreach (var key in new List<(ulong, uint, uint)>(_lastMm.Keys)) if (key.Item1 == k.Cookie) _lastMm.Remove(key);
                foreach (var key in new List<(ulong, uint, uint)>(_lastNvWait.Keys)) if (key.Item1 == k.Cookie) _lastNvWait.Remove(key);
                if (_nvCookies.Remove(k.Cookie)) _nvMapped.Clear(); };
            return t;
        }
        [ThreadStatic] private static ReqTable.Key _pendingKey;
        [ThreadStatic] private static int _pendingClose;               // 1 = 关会话消息、2 = 关域对象
        [ThreadStatic] private static List<ulong> _pendingSessions;    // 这条请求建出的新会话
        [ThreadStatic] private static List<(uint Uid, int Creator)> _pendingUses;   // 这条请求消息里递的句柄：原生层建它的那条日志编号、建它的请求序号（-1 = 不是请求建的）
        [ThreadStatic] private static int[] _pendingNvMap;             // 这条是通道 MapCommandBuffer、要映射的 nvmap 句柄（成功后记成已映射）
        [ThreadStatic] private static int _connectSeq;                 // sm 会话建立那一条的序号 + 1（Connect … End() 之间建的会话归它）；0 = 不在（线程静态没法给初值）
        private const uint EntMeta = 7;                                // 存盘末尾的元数据（ReqTable.WriteMeta）：重放跳过，恢复局读回来接着收
        private static int _seq, _dropped, _kept, _bigLogged;
        private static long _nextReport = 16L << 20;
        private static readonly Dictionary<string, long> _bytesBy = new(); private static readonly Dictionary<string, int> _countBy = new();
        private static readonly Dictionary<string, int> _dropBy = new();

        [DllImport("s2a_native")] private static extern void s2a_snap_hctx(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_seq_live(int seq);      // runtime/src/thread.c：第 seq 条建的句柄还有活着的吗
        [DllImport("s2a_native")] private static extern void s2a_snap_hlog_forget(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_handle_use(uint h, out uint uid);   // 钉住建句柄 h 的那条日志，回建它的请求序号
        [DllImport("s2a_native")] private static extern void s2a_snap_handle_unuse(uint uid);  // 第 seq 条从请求日志删了：它建 / 关句柄的两条一起删
        [DllImport("s2a_native")] private static extern int s2a_nro_known(byte* sha);    // runtime/src/loader.c：这个 NRO 在不在包里
        private const int NroHead = 0x1000;   // 种类 6 记的 NRO 头长（NRO 头 + MOD0 偏移在头 0x10 字节里，段表在 0x20 起）   // runtime/src/snapsw.c：句柄日志跟着停
        [DllImport("s2a_native")] private static extern int s2a_snap_replay_begin(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_replay_end(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_need_handle(uint h);
        [DllImport("s2a_native")] private static extern void s2a_snap_hcommit(int seq);

        // ---------- HIPC 描述符 ----------
        internal struct Desc { public int Kind; public int Off; public ulong Addr; public ulong Size; }   // Kind：0 X、1 A、2 B、3 W、4 C
        // 地址照服务端（IpcBuffDesc / IpcPtrBuffDesc）过一遍 FixIpcAddr（native s2a_ipc_addr39）：老 SDK 只往描述符里写地址 32–35 位，36 位款窗口放在
        //   2^36 以上那一块时游戏地址的高位全丢；macOS 别名区伸到 2^39 之上时第 39 位也丢。原先这里只按原始位拼，记日志时按残缺地址拷缓冲内容，
        //   一款 36 位老版本游戏起局打开显卡驱动（路径 16 字节在 subsdk0 只读区）就段错误；服务端那一路补过、不崩，崩在旁边记日志这一路。C 接收描述符带 48 位地址，不丢位
        internal static List<Desc> ParseDescs(byte* msg, int size)
        {
            var d = new List<Desc>();
            uint w0 = *(uint*)msg, w1 = *(uint*)(msg + 4);
            int nx = (int)((w0 >> 16) & 0xF), na = (int)((w0 >> 20) & 0xF), nb = (int)((w0 >> 24) & 0xF), nw = (int)((w0 >> 28) & 0xF);
            int dw = (int)(w1 & 0x3FF), recv = (int)((w1 >> 10) & 0xF), off = 8;
            if ((w1 >> 31) != 0) { uint w2 = *(uint*)(msg + 8); off += 4 + (int)(w2 & 1) * 8 + 4 * (int)(((w2 >> 1) & 0xF) + ((w2 >> 5) & 0xF)); }
            for (int i = 0; i < nx; i++, off += 8)
            {
                uint a = *(uint*)(msg + off), b = *(uint*)(msg + off + 4);
                ulong addr = Ryujinx.HLE.S2AHooks.FixIpcAddr(b | ((ulong)((a >> 12) & 0xF) << 32) | ((ulong)((a >> 6) & 0x7) << 36));
                d.Add(new Desc { Kind = 0, Off = off, Addr = addr, Size = a >> 16 });
            }
            for (int k = 1; k <= 3; k++)
            {
                int n = k == 1 ? na : k == 2 ? nb : nw;
                for (int i = 0; i < n; i++, off += 12)
                {
                    uint s0 = *(uint*)(msg + off), a0 = *(uint*)(msg + off + 4), f = *(uint*)(msg + off + 8);
                    ulong addr = Ryujinx.HLE.S2AHooks.FixIpcAddr(a0 | ((ulong)((f >> 28) & 0xF) << 32) | ((ulong)((f >> 2) & 0x7) << 36));
                    d.Add(new Desc { Kind = k, Off = off, Addr = addr, Size = s0 | ((ulong)((f >> 24) & 0xF) << 32) });
                }
            }
            int c = recv > 2 ? recv - 2 : recv == 2 ? 1 : 0, coff = off + dw * 4;
            for (int i = 0; i < c && coff + 8 <= size; i++, coff += 8)
            {
                uint lo = *(uint*)(msg + coff), hi = *(uint*)(msg + coff + 4);
                d.Add(new Desc { Kind = 4, Off = coff, Addr = lo | ((ulong)(hi & 0xFFFF) << 32), Size = hi >> 16 });
            }
            return d;
        }
        // 参数本身是游戏内存指针的命令（不走描述符）：nn::ro 的 LoadNro（命令 0：pid、NRO 地址、长度、bss 地址、长度）与 LoadNrr（2 / 10：pid、NRR 地址、长度）。
        //   游戏装完会把放原文件的内存还掉，恢复时那块不可访问（一款大游戏：重放 LoadNro 在 ParseNro 读原文件崩）——记日志时把内容一起记下（种类 5），
        //   重放时放进暂存区、把参数里的地址改成暂存区地址（SetAddr 种类 5 = 改写消息里那个 u64）
        private static void AddRawPointers(List<Desc> ds, string n, long cmd, byte* msg, int size)
        {
            if (!n.Contains("IRoInterface")) return;
            uint c = (uint)cmd; if (c != 0 && c != 2 && c != 10) return;
            for (int o = 8; o + 16 + 24 <= size; o += 4)
            {
                if (*(uint*)(msg + o) != 0x49434653u) continue;   // CMIF 头 "SFCI"，参数在头后 16 字节
                int arg = o + 16; ulong addr = *(ulong*)(msg + arg + 8), len = *(ulong*)(msg + arg + 16);
                // 包里有的 NRO（按 SHA-256 认，nro_modules.tsv）：恢复时按哈希映射改写映像、不读原文件内容，只记头（段长等）+ 哈希（种类 6），
                //   不抄整个模块——真机大乱斗一条 4–12 MB、8 分钟 63 MB；只有包里没有的（游戏现拼的）照旧整份记
                int kind = 5;
                if (c == 0 && addr != 0 && len != 0 && len <= (1ul << 24))
                {
                    byte[] sha = System.Security.Cryptography.SHA256.HashData(new ReadOnlySpan<byte>((void*)addr, (int)len));
                    fixed (byte* h = sha) if (s2a_nro_known(h) == 1) kind = 6;
                }
                if (addr != 0 && len != 0 && len <= (1ul << 24)) ds.Add(new Desc { Kind = kind, Off = arg + 8, Addr = addr, Size = len });
                return;
            }
        }
        private static void SetAddr(byte* msg, Desc x, ulong a)
        {
            uint* p = (uint*)(msg + x.Off);
            if (x.Kind == 5 || x.Kind == 6) { *(ulong*)(msg + x.Off) = a; return; }
            switch (x.Kind)
            {
                case 0: p[0] = (p[0] & ~((0xFu << 12) | (0x7u << 6))) | (uint)(((a >> 32) & 0xF) << 12) | (uint)(((a >> 36) & 0x7) << 6); p[1] = (uint)a; break;
                case 4: p[0] = (uint)a; p[1] = (p[1] & 0xFFFF0000u) | (uint)((a >> 32) & 0xFFFF); break;
                default: p[1] = (uint)a; p[2] = (p[2] & ~((0xFu << 28) | (0x7u << 2))) | (uint)(((a >> 32) & 0xF) << 28) | (uint)(((a >> 36) & 0x7) << 2); break;
            }
        }

        // ---------- 过滤：无状态高频 / 由别处整块恢复的 / 写盘提交（重放会把旧内容写回盘） ----------
        internal static string TargetName(SessionTarget t, byte* msg, int size)
        {
            if (t is HleTarget h && h.Service.S2AIsDomain)
            {
                for (int i = 16; i + 12 <= Math.Min(size, 0x100); i += 4)
                    if (*(uint*)(msg + i) == 0x49434653) { int id = (int)*(uint*)(msg + i - 12); return h.Service.S2ADomainObjectFullName(id) ?? t.Name; }
            }
            return t.TraceName(msg, size);
        }
        // nvdrv 的 Ioctl（命令 1 / 11 / 12 / 13）：设备操作号在原始参数里（fd u32、ioctl 号 u32，紧跟 CMIF 头）。host1x 通道的 Submit（ioctl 类型 0x00、序号 0x01，低 16 位 0x0001；同类型的 Ctrl 设备只用 0x14–0x1b，不会撞）
        //   是「提交工作」（视频解码 / 图像处理），不是建状态：重放它要读游戏早已释放的命令缓冲（一款大游戏：重放 Submit 读已还的内存崩）。不进日志——
        //   丢掉后解码器参考帧可能缺，视频到下一个关键帧才干净（同 NVN 视频那条的取舍）；建映射等留状态的 ioctl 照常重放
        private static bool DropNvSubmit(string n, long cmd, byte* msg, int size)
        {
            uint c = (uint)cmd; if (!n.Contains("INvDrvServices") || !(c == 1 || c == 11 || c == 12 || c == 13)) return false;
            for (int o = 8; o + 16 + 8 <= size; o += 4)
            {
                if (*(uint*)(msg + o) != 0x49434653u) continue;   // CMIF 头 "SFCI"
                uint ioc = *(uint*)(msg + o + 16 + 4); return (ioc & 0xFFFF) == 0x0001;   // 11-17 前误写 0x4801（那是通道的 0x48 / 0x01 建状态命令，被错丢）
            }
            return false;
        }
        internal static bool StateGetterQueryRulesOn = true;   // 单测负对照用：关掉就公共状态的纯查询照常进日志
        internal static bool BinderQueryRulesOn = true;   // 单测负对照用：关掉就 HOSBinderDriverServer 的纯查询事务照常进日志
        // HOSBinderDriverServer 的 TransactParcel（0）/ TransactParcelAuto（3）：紧跟 CMIF 头 "SFCI"（16 字节）是 binderId(s32)、code(u32)、flags(u32)。
        //   IGraphicBufferProducer 的纯只读查询事务不改任何服务状态、不建句柄：Query（9）、GetBufferInfo（16）、GetBufferHistory（17，nn::vi::ListFrameHistory）。
        //   HOSBinderDriverServer 会话整局常驻，按活对象收不会淘汰；每帧调 GetBufferHistory 的游戏（如 FF Resonance、巫师 3）跑 ~2.5 小时日志可涨到 ~250 MB / SOH 383 MB，
        //   撞托管堆上限触发持续 GC 抖动卡死整局。Connect / SetPreallocatedBuffer / RequestBuffer / DequeueBuffer / QueueBuffer / CancelBuffer 等改状态事务照常记、照常重放
        internal static bool DropBinderQuery(string n, long cmd, byte* msg, int size)
        {
            if (!BinderQueryRulesOn) return false;
            uint c = (uint)cmd;
            if (!n.Contains("HOSBinderDriver") || !(c == 0 || c == 3)) return false;
            for (int o = 8; o + 16 + 8 <= size; o += 4)
            {
                if (*(uint*)(msg + o) != 0x49434653u) continue;   // CMIF 头 "SFCI"
                uint code = *(uint*)(msg + o + 16 + 4);
                return code == 9 || code == 16 || code == 17;     // Query / GetBufferInfo / GetBufferHistory
            }
            return false;
        }
        internal static bool AudioQueueRulesOn = true;   // 单测负对照用：关掉就 AudioOut / AudioIn 的队列命令照常进日志
        internal static bool Drop(string n, long cmd)
        {
            uint c = (uint)cmd;
            if (n.Contains("IHidServer") && (c == 200 || c == 214)) return true;                     // 震动查询 / 震动发送
            if (n.Contains(".Fs.") && n.EndsWith("IStorage") && (c == 0 || c == 1 || c == 2 || c == 3)) return true;   // 文件系统的读 / 写 / 刷 / 改长（AM 的 IStorage 同名，cmd 0 是建读写器，不能丢）
            if (n.EndsWith("IFile") && (c == 0 || c == 1 || c == 2 || c == 3)) return true;
            if (n.EndsWith("IFileSystem") && (c <= 6 || c == 10 || c == 13)) return true;             // 建删改名 / 提交（写盘）
            if (n.Contains("AudioRenderer") && !n.Contains("Manager") && c == 4) return true;                                  // RequestUpdate：渲染器整块另存
            if (AudioQueueRulesOn && n.Contains("AudioOut") && !n.Contains("Manager") && (c == 3 || (c >= 5 && c <= 11))) return true;              // 缓冲队列：AudioOut 队列另存（audout.bin，AudioOutSave）
            if (AudioQueueRulesOn && n.Contains("AudioIn") && !n.Contains("Manager") && (c == 0 || c == 3 || (c >= 5 && c <= 11) || c == 13 || c == 14)) return true;   // 同上：AudioIn 队列另存（audin.bin）；Start / Stop / 取事件 / 设增益照常重放
            // 音频设备的纯查询（设备名列表 / 取音量 / 当前设备名 / 声道数，含 Auto 版）：不改服务状态，重放只为重建状态，不进日志（一款大游戏：
            //   重放 #10 取当前设备名时按 A 的接收表写回报内存区无效）。设音量（1 / 7）改状态、取系统事件（4 / 11 / 12）建句柄，照常重放
            if (n.Contains("AudioDevice") && (c == 0 || c == 2 || c == 3 || c == 5 || c == 6 || c == 8 || c == 10 || c == 13)) return true;
            // 每帧都发、不留状态的：不进日志，否则日志随游玩时长线性涨（实测一款大游戏 200 秒 2.2 万条、约 8 MB，一小时约 300 MB 常驻内存）
            if (n.EndsWith("ICommonStateGetter") && c == 50) return true;                                  // IsVrModeEnabled：纯查询
            // 公共状态的其余纯查询：取运行模式（5）/ 性能模式（6）/ 启动模式（8）/ 焦点（9）/ 缺省分辨率（60）/ HDCP 状态（62）/ 内置屏类型（68）/ 当前性能配置（91）/ 平台区域（300）——
            //   只往回复里写值，不改状态、不建句柄。有的游戏每帧都查（D-4FFR：一款足球游戏每帧取性能模式，28 分钟 25.8 万条、97 MB，占请求日志近八成，
            //   托管堆涨到 GC 反复跑、出帧停住）。取事件（0 / 13 / 61）、收消息（1）、设置类（10 / 51–54 / 66 / 130 / 900）照常记
            if (StateGetterQueryRulesOn && n.EndsWith("ICommonStateGetter") && (c == 5 || c == 6 || c == 8 || c == 9 || c == 60 || c == 62 || c == 68 || c == 91 || c == 300)) return true;
            if (n.EndsWith("DatabaseServiceImpl") && c == 0) return true;                                 // 头像库 IsUpdated：纯查询
            if (n.Contains("IHidServer") && (c == 201 || c == 206)) return true;                          // 发震动（单 / 多）：只输出
            // 取握持方式 GetNpadJoyHoldType（121）：纯查询，只往回复写值。有的游戏每帧都查（D-3F4A：一款动作游戏 110002 条、32 MB，占请求日志 99%）；设握持方式（120）照常记
            if (n.Contains("IHidServer") && c == 121) return true;
            if (n.EndsWith("HardwareOpusDecoder") && c != 1 && c != 3 && c <= 9) return true;            // Opus 解码：只解这一段，留下的只有解码器内部预测（下一段自愈）；建 / 设上下文（1 / 3）照常
            //   ↑ 只认解码器对象本身：原先按「名字含」判，把解码器管理器（HardwareOpusDecoderManager，4 / 8 号建解码器）也丢了，恢复后游戏解码时对象找不到、自己中止（一款 Switch 2 游戏）
            // 网络套接字的等待 / 读取（Select 5、Poll 6、Recv 8、RecvFrom 9、Read 25）：不改服务状态，网络连接也没法跨进程接上；进了日志，恢复时在全新的
            //   套接字上重放会一条条等到超时（一款 Switch 2 游戏：网络线程的 Poll 重放 310 条用了 642 秒）。建套接字 / 连接 / 接受（分配编号）照常记、照常重放
            if (n.EndsWith(".Bsd.IClient") && (c == 5 || c == 6 || c == 8 || c == 9 || c == 25)) return true;
            // 套接字的纯查询（GetPeerName 15、GetSockName 16、GetSockOpt 17）：不改服务状态。一款 Switch 2 游戏恢复后网络线程轮询 GetSockOpt（非阻塞连接的结果），
            //   十几秒 33 万条、日志涨到 128 MB 把低区占满、托管堆分配失败
            if (n.EndsWith(".Bsd.IClient") && (c == 15 || c == 16 || c == 17)) return true;
            // 时钟请求 mm:u 的取值（GetOld 3、Get 7）：纯查询，游戏每帧都发（真机大乱斗每帧一对，和 SetAndWait 一起占日志一成）
            if (n.StartsWith("mm:") && (c == 3 || c == 7)) return true;
            // 以下按「对恢复没有作用的纯查询 / 只输出」不记（维护者 11-19 定的请求日志分类第 3 类）：重放只为重建服务状态，这些不改状态、不建句柄
            //   时区：取 / 列地点名、读时区规则、规则版本、时间换算（ToCalendarTime* 100 / 101、ToPosixTime* 201 / 202）；设地点（1）、取事件句柄（20）照常
            if (n.Contains("ITimeZoneService") && (c == 0 || c == 2 || c == 3 || c == 4 || c == 5 || c == 6 || c == 100 || c == 101 || c == 201 || c == 202)) return true;
            //   文件系统：存储 / 文件的取大小（4）、区间操作（5）；文件系统的取条目类型（7）、空闲 / 总空间（11 / 12）、时间戳（14）
            if (n.Contains(".Fs.") && n.EndsWith("IStorage") && (c == 4 || c == 5)) return true;
            if (n.EndsWith("IFile") && (c == 4 || c == 5)) return true;
            if (n.EndsWith("IFileSystem") && (c == 7 || c == 11 || c == 12 || c == 14)) return true;
            //   日志服务的写日志（0）：只输出；设目的地（1）照常
            if (n.EndsWith("LmLogger") && c == 0) return true;
            //   共享字体：取载入状态 / 字号 / 共享内存偏移 / 按优先级列字体 / 取字体信息（1 / 2 / 3 / 5 / 6）；取共享内存句柄（4）照常
            if (n.EndsWith("ISharedFontManager") && (c == 1 || c == 2 || c == 3 || c == 5 || c == 6)) return true;
            //   网络连接请求 nifm IRequest 的取结果（1）：只回结果码。取请求状态（0）只有 Submit 之后第一次改状态（清挂起、发事件），由 NifmLast 按对象只留最后一对；
            //   取事件句柄（2）、取消（3）、提交（4）、设选项（11）照常记（D-NXYJ：哈迪斯离线轮询 nifm，开局 40 秒请求日志 128 MB / 63.8 万条，托管堆每 30 秒涨约 200 MB 到 abort）
            if (NifmRulesOn && n.EndsWith("Nifm.StaticService.IRequest") && c == 1) return true;
            return false;
        }
        internal static bool NifmRulesOn = true;   // 单测负对照用：关掉就 nifm IRequest 的提交 / 查询照常进主日志
        internal const string NifmRequest = "Nifm.StaticService.IRequest";
        // nifm IRequest 每个对象只留最后一对「提交（4）+ 其后第一次取请求状态（0）」，存档时接在日志末尾（同 _lastMm）。离线时提交把请求置「挂起」，
        //   之后第一次取状态清挂起、发事件；再取只读。哈迪斯离线一直重新提交（Ryujinx IRequest.cs 注释：SubmitNetworkRequest 循环），每轮一对都记，
        //   2 分钟撞总上限、这一局即时存档被关（11-26 Mac 实测 29 万条 / 96 MB）。对象的最终状态只由最后一次提交与它之后的第一次取状态决定，前面的对可以丢
        private static readonly Dictionary<ReqTable.Key, (byte[] Submit, byte[] State)> _lastNifm = new();
        // 持 _lock 调。回 true = 这条由本规则收下（不进主日志）；make 只在要留这条时才调（序列化）
        internal static bool NifmLast(string n, long cmd, ReqTable.Key key, Func<byte[]> make)
        {
            if (!NifmRulesOn || !n.EndsWith(NifmRequest)) return false;
            uint c = (uint)cmd;
            if (c == 4) { _lastNifm[key] = (make(), null); return true; }
            if (c != 0) return false;
            if (_lastNifm.TryGetValue(key, out var p) && p.State == null) _lastNifm[key] = (p.Submit, make());   // 提交后第一次：改状态，留
            return true;   // 其余取状态只读：不记
        }
        // 存档时接在末尾的 nifm 条目（按对象：提交、它之后第一次取状态）
        internal static IEnumerable<byte[]> NifmTail() { foreach (var kv in _lastNifm) { yield return kv.Value.Submit; if (kv.Value.State != null) yield return kv.Value.State; } }
        internal static void NifmReset() => _lastNifm.Clear();
        // 请求日志总上限（维护者 11-19「快照日志要有界」）：规则管不到的高频请求兜底。超了这一局放弃即时存档——红行、清空日志、停止记录，
        //   不删条目（删了重放会错）。日志大小因此不超过 LogCapBytes + 一条
        internal static long LogCapBytes = 96L << 20;
        [DllImport("s2a_native")] private static extern void s2a_snap_disable(int why);
        private const int SnapOffLogCap = 2;   // runtime/src/native.h S2A_SNAP_OFF_LOGCAP
        private static bool _capped;
        internal static bool Capped => _capped;
        internal static bool CapReached(ReqTable tab, long cap) => tab.Bytes > cap;   // 纯判定，单测直接用
        // 持 _lock 调：超上限就放弃本局即时存档。回 true = 已放弃（调用方本条不记）
        private static bool CapLocked()
        {
            if (!CapReached(_tab, LogCapBytes)) return false;
            if (!_capped)
            {
                _capped = true;
                var top = new List<KeyValuePair<string, long>>(_bytesBy); top.Sort((x, y) => y.Value.CompareTo(x.Value));
                var sb = new StringBuilder(); for (int i = 0; i < Math.Min(5, top.Count); i++) sb.Append($"{top[i].Key} {top[i].Value >> 10} KB×{_countBy[top[i].Key]}；");
                Console.Error.WriteLine($"[s2a] 【红】即时存档：服务请求日志超过上限 {LogCapBytes >> 20} MB（{_tab.Count} 条），这一局放弃即时存档、清空日志、不再记（游戏照常玩）。占地最多：{sb}");
                SnapSwitch.Save = false;
                _tab.Clear(); _lastUpdate.Clear(); _lastMm.Clear(); _lastNvWait.Clear(); _lastNifm.Clear();
                try { s2a_snap_disable(SnapOffLogCap); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
            }
            return true;
        }

        // 请求开始（游戏线程上，处理前）：回本条序号，不记回 -1
        internal static int Begin(uint num, ulong cookie, SessionTarget t, byte* msg, int size, long cmd)
        {
            string n = TargetName(t, msg, size);
            if (n.Contains("AudioRenderer") && !n.Contains("Manager") && (uint)cmd == 4)
            {
                // 渲染器 RequestUpdate：每会话只留最后一条（恢复时先重放它把效果 / 混音的托管对象建出来，再整块拷回渲染器缓冲）
                //   每秒约 200 次、每条约 100 KB：序列化进本会话复用的流、原地覆盖（11-23 Mac 实测快照开时托管分配 50 MB/s 里 99.7% 是这一类，GC 二代每秒约 1 次）
                lock (_lock)
                {
                    if (!_lastUpdate.TryGetValue(cookie, out MemoryStream ms)) _lastUpdate[cookie] = ms = new MemoryStream();
                    Serialize(-1, num, cookie, cmd, n, msg, size, ms); _dropped++;
                }
                s2a_snap_hctx(-3); return -1;
            }
            if (n.StartsWith("mm:") && ((uint)cmd == 2 || (uint)cmd == 6) && MmRequestId(msg, size) is uint rid)
            {
                // 时钟请求 SetAndWait（旧版 2、新版 6）：同一会话同一请求号只有最后一次设的值有效，每会话每请求号只留最后一条（同上面渲染器的做法，存档时接在日志末尾）
                byte[] e = Serialize(-1, num, cookie, cmd, n, msg, size);
                lock (_lock) { _lastMm[(cookie, (uint)cmd, rid)] = e; _dropped++; }
                s2a_snap_hctx(-3); return -1;
            }
            if (n.StartsWith("mm:") && ((uint)cmd == 1 || (uint)cmd == 5) && MmRequestId(msg, size) is uint fid)
                lock (_lock) { _lastMm.Remove((cookie, 2u, fid)); _lastMm.Remove((cookie, 6u, fid)); }   // Finalize 了这个请求号：之前留的最后一次设值作废（Finalize 本身照常进日志）
            _pendingNvMap = null;
            if (NvRule(n, num, cookie, cmd, msg, size)) { lock (_lock) { _dropped++; _dropBy[n + "#" + (uint)cmd] = _dropBy.GetValueOrDefault(n + "#" + (uint)cmd) + 1; } s2a_snap_hctx(-3); return -1; }
            if (Drop(n, cmd) || DropNvSubmit(n, cmd, msg, size) || DropBinderQuery(n, cmd, msg, size)) { lock (_lock) { _dropped++; _dropBy[n + "#" + (uint)cmd] = _dropBy.GetValueOrDefault(n + "#" + (uint)cmd) + 1; } s2a_snap_hctx(-3); return -1; }
            if (NifmRulesOn && n.EndsWith(NifmRequest) && ((uint)cmd == 0 || (uint)cmd == 4))
            {
                ReqTable.Key nk = TargetKey(cookie, msg, size, out _);
                lock (_lock) { if (!_capped) NifmLast(n, cmd, nk, () => Serialize(-1, num, cookie, cmd, n, msg, size)); _dropped++; _dropBy[n + "#" + (uint)cmd] = _dropBy.GetValueOrDefault(n + "#" + (uint)cmd) + 1; }
                s2a_snap_hctx(-3); return -1;
            }
            lock (_lock)
            {
                if (_capped || CapLocked()) { s2a_snap_hctx(-3); return -1; }
                int seq = _seq++; _kept++;
                _pending = Serialize(seq, num, cookie, cmd, n, msg, size); _pendingIds?.Clear(); _pendingTipc = size >= 4 && (*(uint*)msg & 0xFFFF) >= 0x10;
                _pendingKey = TargetKey(cookie, msg, size, out _pendingClose); _pendingSessions?.Clear();
                // 消息里复制 / 移交的游戏句柄：这条要留着，重放它时句柄得建得出来——钉住建它的日志（移交的处理完就关了，所以在处理前钉）
                _pendingUses?.Clear();
                foreach (uint h in HandlesIn(msg, size)) { int cr = s2a_snap_handle_use(h, out uint uid); if (uid != 0 || cr >= 0) (_pendingUses ??= new()).Add((uid, cr)); }
                { string k = n + "#" + (uint)cmd; _bytesBy[k] = _bytesBy.GetValueOrDefault(k) + _pending.Length; _countBy[k] = _countBy.GetValueOrDefault(k) + 1; }
                if (_tab.Bytes >= _nextReport)
                {   // 日志每翻一倍（16 MB 起）点名占地最多的 5 类：恢复后日志暴涨要知道是谁
                    _nextReport = Math.Max(_nextReport * 2, 16L << 20);
                    var top = new List<KeyValuePair<string, long>>(_bytesBy); top.Sort((x, y) => y.Value.CompareTo(x.Value));
                    var sb = new StringBuilder(); for (int i = 0; i < Math.Min(5, top.Count); i++) sb.Append($"{top[i].Key} {top[i].Value >> 10} KB×{_countBy[top[i].Key]}；");
                    Console.Error.WriteLine($"[s2a] 【黄】即时存档：服务请求日志已 {_tab.Bytes >> 20} MB（{_tab.Count} 条，按活对象收），历来占地最多：{sb}");
                }
                if (_pending.Length > (4 << 20) && _bigLogged++ < 8) Console.Error.WriteLine($"[s2a] 【黄】即时存档：请求日志一条就 {_pending.Length >> 20} MB（{n}#{(uint)cmd}，第 {seq} 条；日志共 {_tab.Bytes >> 20} MB）");
                s2a_snap_hctx(seq);
                return seq;
            }
        }
        private static readonly Dictionary<ulong, MemoryStream> _lastUpdate = new();   // 会话 → 最后一条 RequestUpdate（复用流，长度 = 条目长）
        private static readonly Dictionary<(ulong, uint, uint), byte[]> _lastMm = new();
        private static readonly Dictionary<(ulong, uint, uint), byte[]> _lastNvWait = new();   // (会话, fd, 事件槽) → 最后一次 EventWaitAsync
        private static readonly HashSet<int> _nvMapped = new();                                 // 已有一条留在日志里的 MapCommandBuffer 映射过的 nvmap 句柄
        private static readonly HashSet<ulong> _nvCookies = new();

        // nvdrv 的 Ioctl（命令 1 / 11 / 12）：fd、ioctl 号、输入参数（A 缓冲，没有就 X 缓冲；同服务端 GetBufferType0x21(0) 的取法）
        private static bool NvIoctlOf(string n, long cmd, byte* msg, int size, List<Desc> ds, out uint fd, out uint ioc, out byte* arg, out int argLen)
        {
            fd = ioc = 0; arg = null; argLen = 0;
            uint c = (uint)cmd; if (!n.Contains("INvDrvServices") || !(c == 1 || c == 11 || c == 12)) return false;
            int o = 8; for (; o + 16 + 8 <= size; o += 4) if (*(uint*)(msg + o) == 0x49434653u) break;
            if (o + 16 + 8 > size) return false;
            fd = *(uint*)(msg + o + 16); ioc = *(uint*)(msg + o + 20);
            Desc? pick = null;
            foreach (Desc x in ds) if (x.Kind == 1 && x.Size > 0) { pick = x; break; }
            if (pick == null) foreach (Desc x in ds) if (x.Kind == 0) { pick = x; break; }
            if (pick is Desc d && d.Addr != 0) { arg = (byte*)d.Addr; argLen = (int)Math.Min(d.Size, 1u << 20); }
            return true;
        }
        // nvdrv 按语义收住的几类（维护者 11-19 请求日志分类；对照 compat 的 NvHostCtrlDeviceFile / NvHostChannelDeviceFile 实现）：回 true = 不进日志
        //   EventWaitAsync（类型 0x00、号 0x1E；参数 {Fence 8, Timeout 4, Value 4}，异步时 Value 就是事件槽）：每 (会话, fd, 槽) 只留最后一条，存档时接在日志末尾；
        //     同槽的 EventSignal 0x1C / EventRegister 0x1F（先注销）/ EventUnregister 0x20、EventKill 0x21（按位）让之前留的那条作废（挂上 / 触发或取消成对抵消）
        //   通道 UnmapCommandBuffer（0x00 / 0x0A）：服务端是空操作（映射地址不回收），不改状态，不记
        //   通道 MapCommandBuffer（0x00 / 0x09）：句柄已映射过的，服务端只回旧地址、不改状态——要映射的句柄全都已有一条留在日志里的映射时不记；
        //     nvmap Free（0x01 / 0x05）、关 fd、会话收掉时把句柄从「已映射」里拿掉（之后同号的新句柄要重新映射，那条照常记）
        private static bool NvRule(string n, uint num, ulong cookie, long cmd, byte* msg, int size)
        {
            if (!n.Contains("INvDrvServices")) return false;
            if ((uint)cmd == 2)
            {   // Close(fd)：这个 fd 上留的等待作废；保守起见已映射集合清空（之后的映射照常记）
                int o = 8; for (; o + 16 + 4 <= size; o += 4) if (*(uint*)(msg + o) == 0x49434653u) break;
                uint cfd = o + 16 + 4 <= size ? *(uint*)(msg + o + 16) : uint.MaxValue;
                lock (_lock) NvClose(cookie, cfd);
                return false;
            }
            List<Desc> ds = ParseDescs(msg, size);
            if (!NvIoctlOf(n, cmd, msg, size, ds, out uint fd, out uint ioc, out byte* arg, out int len)) return false;
            int r; int[] hs;
            lock (_lock) r = NvStep(cookie, fd, ioc, new ReadOnlySpan<byte>(arg, arg == null ? 0 : len), () => Serialize(-1, num, cookie, cmd, n, msg, size), out hs);
            _pendingNvMap = hs;
            return r != 0;
        }
        internal static bool NvRulesOn = true;   // 单测负对照用：关掉就全照常进日志
        internal static void NvClose(ulong cookie, uint fd)
        {
            _nvMapped.Clear();
            foreach (var k in new List<(ulong, uint, uint)>(_lastNvWait.Keys)) if (k.Item1 == cookie && k.Item2 == fd) _lastNvWait.Remove(k);
        }
        // 一条 nvdrv Ioctl 按上面的规则走一步（持 _lock 调；记录时和恢复后重建表共用）。回 0 = 照常进日志（是新映射时 map 给出要映射的句柄，成功后记成已映射）、
        //   1 = 不记、2 = 已作为该槽最后一条 EventWaitAsync 收下（entry() 取序列化好的这一条）
        internal static int NvStep(ulong cookie, uint fd, uint ioc, ReadOnlySpan<byte> arg, Func<byte[]> entry, out int[] map)
        {
            map = null;
            _nvCookies.Add(cookie);
            if (!NvRulesOn) return 0;
            uint typ = (ioc >> 8) & 0xFF, nr = ioc & 0xFF;
            if (typ == 0x00 && nr == 0x0A) return 1;
            if (typ == 0x00 && nr == 0x1E && arg.Length >= 16) { _lastNvWait[(cookie, fd, BitConverter.ToUInt32(arg[12..]))] = entry(); return 2; }
            if (typ == 0x00 && (nr == 0x1C || nr == 0x1F || nr == 0x20) && arg.Length >= 4) _lastNvWait.Remove((cookie, fd, BitConverter.ToUInt32(arg) & 0xFFFF));
            if (typ == 0x00 && nr == 0x21 && arg.Length >= 8)
            {
                ulong m = BitConverter.ToUInt64(arg);
                for (uint i = 0; i < 64; i++) if ((m & (1UL << (int)i)) != 0) _lastNvWait.Remove((cookie, fd, i));
            }
            if (typ == 0x01 && nr == 0x05 && arg.Length >= 4) _nvMapped.Remove(BitConverter.ToInt32(arg));
            if (typ == 0x00 && nr == 0x09 && arg.Length >= 12)
            {
                int cnt = BitConverter.ToInt32(arg); if (cnt <= 0 || 12 + (long)cnt * 8 > arg.Length) return 0;
                int[] hs = new int[cnt]; bool all = true;
                for (int i = 0; i < cnt; i++) { hs[i] = BitConverter.ToInt32(arg[(12 + i * 8)..]); if (!_nvMapped.Contains(hs[i])) all = false; }
                if (all) return 1;
                map = hs;
            }
            return 0;
        }
        internal static void NvMapped(int[] hs) { if (hs != null) foreach (int h in hs) _nvMapped.Add(h); }
        internal static int NvWaitsKept => _lastNvWait.Count;
        internal static void NvReset() { _lastNvWait.Clear(); _nvMapped.Clear(); _nvCookies.Clear(); }
        private static long _savedRaw, _savedZ;
        // 消息特殊头里复制 / 移交的游戏句柄（同重放时 s2a_snap_need_handle 的取法；伪句柄不算）
        private static List<uint> HandlesIn(byte* msg, int size)
        {
            var hs = new List<uint>(); if (size < 12) return hs;
            uint w1 = *(uint*)(msg + 4); if ((w1 >> 31) == 0) return hs;
            uint w2 = *(uint*)(msg + 8); int pid = (int)(w2 & 1), nh = (int)(((w2 >> 1) & 0xF) + ((w2 >> 5) & 0xF));
            for (int i = 0; i < nh && 12 + pid * 8 + i * 4 + 4 <= size; i++) { uint h = *(uint*)(msg + 12 + pid * 8 + i * 4); if (h != 0 && h < 0xFFFF8000u) hs.Add(h); }
            return hs;
        }
        // mm:u SetAndWait 的请求号：CMIF 头「SFCI」后 16 字节起的第 1 个 u32
        private static uint? MmRequestId(byte* msg, int size)
        {
            for (int o = 8; o + 16 + 4 <= size; o += 4) if (*(uint*)(msg + o) == 0x49434653u) return *(uint*)(msg + o + 16);
            return null;
        }
        // 分配账（每 30 秒结一次，请求序列化分配满 64 MB 才报一行【黄】）：每类请求序列化实际分配的字节（含只留最后一条 / 规则不记但先序列化的），对照进程托管总分配
        private static readonly Dictionary<string, (long B, int C)> _allocBy = new(); private static readonly object _allocLock = new();
        private static long _allocT0, _allocG0;
        // into 给了：写进这个流（先清空、复用它的缓冲），回 null；没给：回新数组
        private static byte[] Serialize(int seq, uint num, ulong cookie, long cmd, string n, byte* msg, int size, MemoryStream into = null)
        {
            long a0 = GC.GetAllocatedBytesForCurrentThread();
            byte[] e = SerializeCore(seq, num, cookie, cmd, n, msg, size, into);
            long a = GC.GetAllocatedBytesForCurrentThread() - a0, now = System.Diagnostics.Stopwatch.GetTimestamp();
            string k = n + "#" + (uint)cmd; string line = null;
            lock (_allocLock)
            {
                var v = _allocBy.GetValueOrDefault(k); _allocBy[k] = (v.B + a, v.C + 1);
                if (_allocT0 == 0) { _allocT0 = now; _allocG0 = GC.GetTotalAllocatedBytes(); }
                else if (now - _allocT0 >= 30 * System.Diagnostics.Stopwatch.Frequency)
                {
                    long g = GC.GetTotalAllocatedBytes(), sum = 0; double sec = (now - _allocT0) / (double)System.Diagnostics.Stopwatch.Frequency;
                    var top = new List<KeyValuePair<string, (long B, int C)>>(_allocBy); top.Sort((x, y) => y.Value.B.CompareTo(x.Value.B));
                    foreach (var kv in top) sum += kv.Value.B;
                    var sb = new StringBuilder(); for (int i = 0; i < Math.Min(5, top.Count); i++) sb.Append($"{top[i].Key} {top[i].Value.B >> 10} KB×{top[i].Value.C}；");
                    if (sum >= 64L << 20) line = $"[s2a] 【黄】即时存档分配账：近 {sec:F0} 秒托管总分配 {(g - _allocG0) >> 20} MB，其中请求序列化 {sum >> 20} MB（门槛 64 MB）；前 5 类：{sb}";
                    _allocBy.Clear(); _allocT0 = now; _allocG0 = g;
                }
            }
            if (line != null) Console.Error.WriteLine(line);
            return e;
        }
        private static byte[] SerializeCore(int seq, uint num, ulong cookie, long cmd, string n, byte* msg, int size, MemoryStream into)
        {
            List<Desc> ds = ParseDescs(msg, size);
            AddRawPointers(ds, n, cmd, msg, size);
            var ms = into ?? new MemoryStream(); ms.SetLength(0); var w = new BinaryWriter(ms);
            w.Write(EntReq); w.Write(seq); w.Write(num); w.Write(cookie); w.Write(cmd); w.Write(n);
            w.Write(size); w.Write(new ReadOnlySpan<byte>(msg, size));
            w.Write(ds.Count);
            foreach (Desc x in ds)
            {
                if (x.Kind == 6)
                {   // 头 NroHead 字节 + SHA-256（32 字节）
                    int head = (int)Math.Min(x.Size, NroHead);
                    w.Write(x.Kind); w.Write(x.Off); w.Write(x.Addr); w.Write(x.Size); w.Write(head + 32);
                    w.Write(new ReadOnlySpan<byte>((void*)x.Addr, head)); w.Write(System.Security.Cryptography.SHA256.HashData(new ReadOnlySpan<byte>((void*)x.Addr, (int)x.Size)));
                    continue;
                }
                bool input = x.Kind == 0 || x.Kind == 1 || x.Kind == 3 || x.Kind == 5;
                int len = input ? (int)Math.Min(x.Size, 1u << 24) : 0;
                w.Write(x.Kind); w.Write(x.Off); w.Write(x.Addr); w.Write(x.Size); w.Write(len);
                if (len > 0 && x.Addr != 0) w.Write(new ReadOnlySpan<byte>((void*)x.Addr, len)); else if (len > 0) w.Write(new byte[len]);
            }
            w.Flush(); return into != null ? null : ms.ToArray();
        }
        internal static void End() { s2a_snap_hctx(-2); _connectSeq = 0; }
        internal static void OutObjects(List<int> ids)
        {
            if (_pending != null) (_pendingIds ??= new()).AddRange(ids);
        }
        // 处理完（消息缓冲已是应答）：按完成先后追加；失败的只记序号
        internal static void End(int seq, byte* msg, int size)
        {
            s2a_snap_hctx(-2);
            byte[] e = _pending; _pending = null;
            if (seq < 0 || e == null) return;
            bool ok = ReplyResult(msg, size, _pendingTipc) == 0;
            lock (_lock)
            {
                ReqTable.Key key = _pendingKey;
                if (ok)
                {
                    if (_pendingIds is { Count: > 0 } ids)
                    {
                        var ms = new MemoryStream(); var w = new BinaryWriter(ms); w.Write(e); w.Write(EntObjs); w.Write(seq); w.Write(ids.Count); foreach (int id in ids) w.Write(id); w.Flush();
                        _tab.Add(seq, ms.ToArray(), key);
                        foreach (int id in ids) _tab.Created(seq, new ReqTable.Key(key.Cookie, id));   // 交出的域对象：同会话里的对象号
                    }
                    else _tab.Add(seq, e, key);
                    if (_pendingSessions != null) foreach (ulong c in _pendingSessions) _tab.Created(seq, new ReqTable.Key(c, 0));
                    if (_pendingUses != null) foreach (var (uid, cr) in _pendingUses) _tab.Use(seq, uid, cr);
                    NvMapped(_pendingNvMap);
                }
                else
                {
                    var ms = new MemoryStream(); var w = new BinaryWriter(ms); w.Write(EntFailed); w.Write(seq); w.Flush(); _tab.Add(seq, ms.ToArray(), key);
                    if (_pendingUses != null) foreach (var (uid, _) in _pendingUses) s2a_snap_handle_unuse(uid);   // 当时失败的不重放：不用钉
                }
                _pendingUses?.Clear();
                if (_pendingClose == 2) _tab.Close(key);   // 关域对象：它和发给它的、建它的一起收（关会话由句柄关闭那一刻收，SessionClosed）
                s2a_snap_hcommit(seq);   // 原生层句柄日志：此后的关闭记在这条之后（与重放先后一致）
            }
            _pendingSessions?.Clear();
            _pendingIds?.Clear();
            _pendingNvMap = null;
        }
        // 应答的结果码：按 HIPC 头算出这条应答的原始数据段（头 2 个字、特殊头、各类描述符之后，长度 = 头里记的字数），只在段里取——
        //   原先在消息缓冲前 0x100 字节里找 "SFCO"，TIPC 应答（sm 取服务等）没有 CMIF 应答头，就读到了同一线程缓冲里上一条应答留下的结果码：
        //   上一条失败、这条成功也记成失败，恢复时不重放，这条建的会话（如 hid）在 B 里没有（大金刚第 125 条）。
        //   TIPC：原始数据第 1 个字就是结果码；CMIF：段里 "SFCO" 头后第 8 字节；没有原始数据的（关对象）按成功算
        internal static uint ReplyResult(byte* msg, int size, bool tipc)
        {
            if (size < 8) return 0;
            uint w0 = *(uint*)msg, w1 = *(uint*)(msg + 4);
            int nx = (int)(w0 >> 16) & 0xF, na = (int)(w0 >> 20) & 0xF, nb = (int)(w0 >> 24) & 0xF, nw = (int)(w0 >> 28) & 0xF;
            int raw = (int)(w1 & 0x3FF) * 4, off = 8;
            if ((w1 >> 31) != 0)
            {
                if (size < off + 4) return 0;
                uint sh = *(uint*)(msg + off); off += 4 + ((sh & 1) != 0 ? 8 : 0) + 4 * (int)(((sh >> 1) & 0xF) + ((sh >> 5) & 0xF));
            }
            off += nx * 8 + (na + nb + nw) * 12;
            int end = Math.Min(size, off + raw);
            if (raw == 0 || off + 4 > end) return 0;
            if (tipc) return *(uint*)(msg + off);
            for (int i = off; i + 12 <= end; i += 4)   // 段内逐字找（对齐填充长短不假设）
                if (*(uint*)(msg + i) == 0x4F434653u) return *(uint*)(msg + i + 8);
            return 0;
        }
        internal static int Connect()
        {
            lock (_lock)
            {
                int seq = _seq++; _kept++;
                var ms = new MemoryStream(); var w = new BinaryWriter(ms); w.Write(EntConnect); w.Write(seq); w.Flush();
                _tab.Add(seq, ms.ToArray(), new ReqTable.Key(0, 0));   // sm 会话的建立：目标是「根」（永不关）；建出的会话由 SessionCreated 挂到这条
                _connectSeq = seq + 1; s2a_snap_hctx(seq); s2a_snap_hcommit(seq); return seq;
            }
        }

        // 会话建出 / 关掉（Dispatcher.NewSessionHandle / HandleClosed 调）：建出的挂到正在处理的那条请求（或 sm 建立那条）名下；关掉的连同它的域对象一起收
        internal static void SessionCreated(ulong cookie)
        {
            if (_pending != null) (_pendingSessions ??= new()).Add(cookie);
            else if (_connectSeq > 0) lock (_lock) _tab.Created(_connectSeq - 1, new ReqTable.Key(cookie, 0));
        }
        internal static void SessionClosed(ulong cookie) { lock (_lock) _tab.CloseSession(cookie); }

        // 请求的目标（会话 cookie + 域对象号，非域 0）与是不是关闭：关会话（消息类型 2 / TIPC 0xF）→ 1；域请求头类型 2（关域对象）→ 2。
        //   域请求头在原始数据段 16 字节对齐处（字节 0 = 类型：1 发消息、2 关；+4 = 对象号）；非域会话那里是 CMIF 头 "SFCI" 的 'S'，不会是 1 / 2
        internal static ReqTable.Key TargetKey(ulong cookie, byte* msg, int size, out int close)
        {
            close = 0; if (size < 8) return new ReqTable.Key(cookie, 0);
            uint w0 = *(uint*)msg, w1 = *(uint*)(msg + 4); int type = (int)(w0 & 0xFFFF);
            if (type == 2 || type == 0xF) { close = 1; return new ReqTable.Key(cookie, 0); }
            if (type >= 0x10) return new ReqTable.Key(cookie, 0);
            int nx = (int)(w0 >> 16) & 0xF, na = (int)(w0 >> 20) & 0xF, nb = (int)(w0 >> 24) & 0xF, nw = (int)(w0 >> 28) & 0xF, off = 8;
            if ((w1 >> 31) != 0) { uint sh = *(uint*)(msg + off); off += 4 + ((sh & 1) != 0 ? 8 : 0) + 4 * (int)(((sh >> 1) & 0xF) + ((sh >> 5) & 0xF)); }
            off += nx * 8 + (na + nb + nw) * 12; int dh = (off + 15) & ~15;
            if (dh + 8 > size || (w1 & 0x3FF) == 0) return new ReqTable.Key(cookie, 0);
            byte dt = msg[dh];
            if (dt == 1 || dt == 2) { if (dt == 2) close = 2; return new ReqTable.Key(cookie, *(int*)(msg + dh + 4)); }
            return new ReqTable.Key(cookie, 0);
        }

        // 服务层实际用的 Ryujinx 数据根（Exports.cs 起服务层时定：配置里的状态目录 / S2A_RYU_DATA / 缺省），快照按它找玩家存档树
        internal static string DataRoot;
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapDataRoot")]
        private static int DataRootOut(byte* buf, int n)
        {
            if (DataRoot == null || n <= 0) return -1;
            byte[] b = System.Text.Encoding.UTF8.GetBytes(DataRoot);
            if (b.Length + 1 > n) return -1;
            new ReadOnlySpan<byte>(b).CopyTo(new Span<byte>(buf, n)); buf[b.Length] = 0; return b.Length;
        }

        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapLogSave")]
        private static int Save(byte* path)
        {
            try
            {
                string p = Marshal.PtrToStringUTF8((IntPtr)path);
                lock (_lock)
                {
                    var outLog = new ReqLog();
                    foreach (var kv in _tab.InOrder()) outLog.W.Write(kv.Value);
                    foreach (var kv in _lastUpdate) { byte[] e = kv.Value.ToArray(); BitConverter.TryWriteBytes(new Span<byte>(e, 4, 4), _seq++); outLog.W.Write(e); }
                    foreach (var kv in _lastMm) { byte[] e = (byte[])kv.Value.Clone(); BitConverter.TryWriteBytes(new Span<byte>(e, 4, 4), _seq++); outLog.W.Write(e); }
                    foreach (var kv in _lastNvWait) { byte[] e = (byte[])kv.Value.Clone(); BitConverter.TryWriteBytes(new Span<byte>(e, 4, 4), _seq++); outLog.W.Write(e); }
                    foreach (byte[] ne in NifmTail()) { byte[] e = (byte[])ne.Clone(); BitConverter.TryWriteBytes(new Span<byte>(e, 4, 4), _seq++); outLog.W.Write(e); }
                    outLog.W.Write(EntMeta); outLog.W.Write(0); _tab.WriteMeta(outLog.W);
                    outLog.SaveTo(p); _savedRaw = outLog.Length; _savedZ = outLog.Stored;
                }
                SaveSyncpoints(Path.Combine(Path.GetDirectoryName(p) ?? ".", "syncpt.bin"));
                SaveAppletMessages(Path.Combine(Path.GetDirectoryName(p) ?? ".", "applet.bin"));
                SaveHidRings(Path.Combine(Path.GetDirectoryName(p) ?? ".", "hid.bin"));
                var sb = new StringBuilder();
                foreach (var kv in _dropBy) sb.Append(kv.Key).Append('×').Append(kv.Value).Append(' ');
                Console.Error.WriteLine($"[s2a] 即时存档：服务请求日志 活着的 {_tab.Count} 条（历来记过 {_kept} 条，其余随对象关闭收掉）、原始 {_savedRaw / 1024} KB、压后 {_savedZ / 1024} KB；不记的 {_dropped} 条（{sb}）");
                return 0;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档：写服务请求日志失败 {e.Message}"); return -1; }
        }

        // 进程内重建开新一局：请求日志从头记（上一局的请求不能留在新一局的日志里）；要恢复时先不记，重放完接上快照日志后再记
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapSessionReset")]
        private static int SessionReset(int restoring)
        {
            lock (_lock) { _capped = false; _lastNifm.Clear(); _tab.Clear(); _seq = 0; _kept = 0; _dropped = 0; _maxSeq = -1; _dropBy.Clear(); _lastUpdate.Clear(); _lastMm.Clear(); _lastNvWait.Clear(); _nvMapped.Clear(); _nvCookies.Clear(); }
            SnapSwitch.Save = SnapSwitch.CanSave && restoring == 0;
            return 0;
        }

        // 同步点状态（syncpt.bin，与 ipc.bin 同目录）：host1x 通道的 Submit 不进日志，它推上去的同步点计数单独存、重放后抬回去（Ryujinx.HLE.S2ASyncptSnap）。
        //   旧快照没有这个文件：照旧恢复、记一行黄（视频类等同步点的会每步等满 1 秒）
        private static void SaveSyncpoints(string file)
        {
            if (Host.Device is not Ryujinx.HLE.Switch dev) return;
            using var w = new BinaryWriter(File.Create(file));
            Ryujinx.HLE.S2ASyncptSnap.Save(dev, w);
        }
        private static void RestoreSyncpoints(string file)
        {
            if (Host.Device is not Ryujinx.HLE.Switch dev) return;
            if (!File.Exists(file)) { Console.Error.WriteLine("[s2a] 【黄】即时存档恢复：快照没有同步点状态（旧快照），同步点计数从重放结果接着走"); return; }
            using var r = new BinaryReader(File.OpenRead(file));
            int raised = Ryujinx.HLE.S2ASyncptSnap.Restore(dev, r);
            Console.Error.WriteLine(raised < 0 ? "[s2a] 【红】即时存档恢复：同步点状态格式不对，没接上" : $"[s2a] 即时存档恢复：同步点计数接回快照时的值（抬了 {raised} 个）");
        }

        // 小程序消息队列（applet.bin）：宿主事件入队的消息不在请求日志里，存档那一刻没被取走的单独存、重放后放回（Ryujinx.HLE.S2AAppletSnap）。旧快照没有：照旧恢复
        private static void SaveAppletMessages(string file)
        {
            if (Host.Device is not Ryujinx.HLE.Switch dev) return;
            using var w = new BinaryWriter(File.Create(file));
            int n = Ryujinx.HLE.S2AAppletSnap.Save(dev, w);
            if (n > 0) Console.Error.WriteLine($"[s2a] 即时存档：小程序消息队列里还有 {n} 条没取走，已存");
        }
        private static void RestoreAppletMessages(string file)
        {
            if (Host.Device is not Ryujinx.HLE.Switch dev || !File.Exists(file)) return;
            using var r = new BinaryReader(File.OpenRead(file));
            int n = Ryujinx.HLE.S2AAppletSnap.Restore(dev, r);
            Console.Error.WriteLine(n < 0 ? "[s2a] 【红】即时存档恢复：小程序消息队列格式不对，没接上" : $"[s2a] 即时存档恢复：小程序消息队列接回快照那一刻（{n} 条）");
        }

        // HID 共享内存的触屏 / 鼠标 / 键盘 / 手势环（hid.bin）：恢复时共享内存由重放新建、采样号从 0 重数，游戏按快照里记的采样号判新旧，
        //   触屏全被当旧数据丢掉（#2199）。存档存四个环、重放后放回（Ryujinx.HLE.S2AHidSnap）。旧快照没有：照旧恢复、记一行黄
        private static void SaveHidRings(string file)
        {
            if (Host.Device is not Ryujinx.HLE.Switch dev) return;
            using var w = new BinaryWriter(File.Create(file));
            Ryujinx.HLE.S2AHidSnap.Save(dev, w);
        }
        private static void RestoreHidRings(string file)
        {
            if (Host.Device is not Ryujinx.HLE.Switch dev) return;
            if (!File.Exists(file)) { Console.Error.WriteLine("[s2a] 【黄】即时存档恢复：快照没有 HID 环（旧快照），触屏 / 手势采样号从 0 重数，按采样号判新输入的游戏恢复后触屏可能没反应"); return; }
            using var r = new BinaryReader(File.OpenRead(file));
            int n = Ryujinx.HLE.S2AHidSnap.Restore(dev, r);
            Console.Error.WriteLine(n < 0 ? "[s2a] 【红】即时存档恢复：HID 环格式不对，没接上" : $"[s2a] 即时存档恢复：HID 触屏 / 鼠标 / 键盘 / 手势 {n} 个环接回快照那一刻，采样号接着数");
            int p = Ryujinx.HLE.S2AHidSnap.NpadsRestored;
            if (n >= 0) Console.Error.WriteLine(p > 0 ? $"[s2a] 即时存档恢复：{p} 只手柄的输入环采样号接回快照那一刻，接着数"
                : p == 0 ? "[s2a] 【黄】即时存档恢复：快照没有手柄采样号（旧快照），按采样号判新输入的游戏恢复后摇杆可能要过一阵才有反应"
                : "[s2a] 【红】即时存档恢复：手柄采样号段格式不对，没接上");
        }

        // ---------- 恢复：重放 ----------
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapReplay")]
        private static int Replay(byte* path, ulong scratch, ulong scratchSize)
        {
            int n = 0, bad = 0, skipped = 0, diverged = 0; string cur_ = "";   // 正在重放的那条（服务名#命令号），出错时说清是哪条
            try
            {
                Dispatcher d = Dispatcher.Instance;
                byte[] all = ReqLog.Load(File.ReadAllBytes(Marshal.PtrToStringUTF8((IntPtr)path)));   // 分块压缩的解开；旧快照原样
                Ryujinx.HLE.S2AHooks.SnapReplayUndo.Clear(); Ryujinx.HLE.S2AHooks.SnapReplaying = true;
                Dictionary<int, int[]> outIds = OutIdsOf(all); Dictionary<int, ulong[]> outCookies = SessionCookiesOf(all); int forcedLeft = 0; Ryujinx.HLE.S2AHooks.SnapForceDomainIdMiss = 0; Ryujinx.Horizon.S2AHorizonHooks.SnapForceDomainIdMiss = 0;
                var r = new BinaryReader(new MemoryStream(all));
                long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
                while (r.BaseStream.Position < r.BaseStream.Length)
                {
                    uint kind = r.ReadUInt32(); int seq = r.ReadInt32(); if (seq > _maxSeq) _maxSeq = seq;
                    if (kind == EntMeta) break;   // 末尾的元数据：不是请求
                    s2a_snap_replay_begin(seq);
                    d.SnapForceCookies = outCookies.TryGetValue(seq, out ulong[] wantc) ? new Queue<ulong>(wantc) : null;
                    if (kind == EntConnect) { d.SnapConnect(); d.SnapForceCookies = null; s2a_snap_replay_end(seq); n++; continue; }
                    if (kind == EntFailed) { s2a_snap_replay_end(seq); skipped++; continue; }   // 当时失败的：不重放，这条之后的关闭照常
                    if (kind == EntObjs) { int c = r.ReadInt32(); r.BaseStream.Seek(4L * c, SeekOrigin.Current); continue; }   // 已在预扫里取走
                    uint num = r.ReadUInt32(); ulong cookie = r.ReadUInt64(); long cmd = r.ReadInt64(); string name = r.ReadString();
                    int size = r.ReadInt32(); byte[] msgb = r.ReadBytes(size);
                    int nd = r.ReadInt32();
                    // 暂存区：消息放 4 KB 对齐的开头（同 A 的对齐，CMIF 填充一致），缓冲依次往后
                    cur_ = $"{name}#{(uint)cmd}";
                    ulong cur = scratch, msgAddr = cur; cur += ((ulong)size + 0xFFF) & ~0xFFFul;
                    new ReadOnlySpan<byte>(msgb).CopyTo(new Span<byte>((void*)msgAddr, size));
                    for (int i = 0; i < nd; i++)
                    {
                        Desc x = new() { Kind = r.ReadInt32(), Off = r.ReadInt32(), Addr = r.ReadUInt64(), Size = r.ReadUInt64() };
                        int len = r.ReadInt32(); byte[] data = len > 0 ? r.ReadBytes(len) : null;
                        if (x.Addr == 0) continue;
                        // 长度 0 但有地址的（接收表的空缓冲等）也改指暂存区：服务层照样按这个地址做内存追踪核对，留着 A 的原地址在 B 里可能无效（一款大游戏，iPhone 地址档）
                        if (x.Size == 0) { SetAddr((byte*)msgAddr, x, cur); continue; }
                        ulong need = (x.Size + 0xFFF) & ~0xFFFul;
                        if (cur + need > scratch + scratchSize) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：重放第 {seq} 条 {name}#{(uint)cmd} 缓冲 {x.Size} 字节放不下暂存区"); bad++; continue; }
                        new Span<byte>((void*)cur, (int)Math.Min(x.Size, int.MaxValue)).Clear();
                        if (data != null && x.Kind == 6)
                        {   // 包里有的 NRO：放头、其余留零，哈希交给 LoadNro（S2AHooks.SnapNroHash，它按哈希映射改写映像）
                            new ReadOnlySpan<byte>(data, 0, data.Length - 32).CopyTo(new Span<byte>((void*)cur, data.Length - 32));
                            Ryujinx.HLE.S2AHooks.SnapNroHash = data[^32..];
                        }
                        else if (data != null) new ReadOnlySpan<byte>(data).CopyTo(new Span<byte>((void*)cur, data.Length));
                        SetAddr((byte*)msgAddr, x, cur); cur += need;
                    }
                    // 请求里拷贝 / 移交的游戏句柄：没放进表的先放（游戏建的句柄延后放，见 thread.c g_defer）
                    {
                        uint w1 = *(uint*)(msgAddr + 4);
                        if ((w1 >> 31) != 0)
                        {
                            uint w2 = *(uint*)(msgAddr + 8); int pid = (int)(w2 & 1), nh = (int)(((w2 >> 1) & 0xF) + ((w2 >> 5) & 0xF));
                            for (int i = 0; i < nh; i++) { uint h = *(uint*)(msgAddr + 12 + (ulong)pid * 8 + (ulong)i * 4); if (h != 0 && h < 0xFFFF8000u) s2a_snap_need_handle(h); }
                        }
                    }
                    Ryujinx.HLE.S2AHooks.SnapForceDomainIds = outIds.TryGetValue(seq, out int[] want) ? new Queue<int>(want) : null;
                    Ryujinx.Horizon.S2AHorizonHooks.SnapForceDomainIds = Ryujinx.HLE.S2AHooks.SnapForceDomainIds;   // 同一个队列：这条请求的目标是 HLE 域还是 Horizon 域，谁分对象谁取
                    bool tipc = (*(uint*)msgAddr & 0xFFFF) >= 0x10;   // 处理前看请求头的类型（处理完缓冲已是应答）
                    uint rc = d.SnapRequest(num, cookie, (byte*)msgAddr, size);
                    forcedLeft += Ryujinx.HLE.S2AHooks.SnapForceDomainIds?.Count ?? 0; Ryujinx.HLE.S2AHooks.SnapForceDomainIds = null; Ryujinx.Horizon.S2AHorizonHooks.SnapForceDomainIds = null;
                    forcedLeft += d.SnapForceCookies?.Count ?? 0; d.SnapForceCookies = null;
                    if (rc != 0) { bad++; if (bad <= 20) Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：重放第 {seq} 条 {name}#{(uint)cmd} 回 0x{rc:X}"); }
                    else if (ReplyResult((byte*)msgAddr, size, tipc) is uint cr && cr != 0)
                    {   // 日志里的都是 A 当时成功的（失败的记成 EntFailed 不重放）：B 里回了错误码 = 两边状态分岔，点名这条（后面对象号可能跟着错位）
                        diverged++; if (diverged <= 20) Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：重放第 {seq} 条 {name}#{(uint)cmd} A 当时成功、这里回 0x{cr:X}");
                    }
                    if (s2a_snap_replay_end(seq) != 0) bad++;
                    n++;
                }
                Ryujinx.HLE.S2AHooks.SnapReplaying = false;
                int forcedMiss = Ryujinx.HLE.S2AHooks.SnapForceDomainIdMiss + Ryujinx.Horizon.S2AHorizonHooks.SnapForceDomainIdMiss;
                if (forcedLeft > 0 || forcedMiss > 0)
                    Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：域对象 / 会话按原号分配 没用上 {forcedLeft} 个、原号被占 {forcedMiss} 个（对象号可能和存档时不同）");
                // 重放里为「当时打开成功、快照前已删」的路径建的空占位：按建的反序删掉，文件系统回到快照那一刻（删不掉的 = 游戏此刻还开着它，留着）
                int ph = Ryujinx.HLE.S2AHooks.SnapReplayUndo.Count, kept = 0;
                for (int i = ph - 1; i >= 0; i--) if (!Ryujinx.HLE.S2AHooks.SnapReplayUndo[i]()) kept++;
                Ryujinx.HLE.S2AHooks.SnapReplayUndo.Clear();
                if (ph > 0) Console.Error.WriteLine($"[s2a] 即时存档恢复：重放时为已删路径建空占位 {ph} 个，重放完删掉 {ph - kept} 个（还开着、留下 {kept} 个）");
                double ms = (System.Diagnostics.Stopwatch.GetTimestamp() - t0) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                Console.Error.WriteLine($"[s2a] 即时存档恢复：服务请求重放 {n} 条，{ms:F1} ms，异常 {bad} 条（当时失败、不重放 {skipped} 条；A 成功这里失败 {diverged} 条）");
                RestoreSyncpoints(Path.Combine(Path.GetDirectoryName(Marshal.PtrToStringUTF8((IntPtr)path)) ?? ".", "syncpt.bin"));
                RestoreAppletMessages(Path.Combine(Path.GetDirectoryName(Marshal.PtrToStringUTF8((IntPtr)path)) ?? ".", "applet.bin"));
                RestoreHidRings(Path.Combine(Path.GetDirectoryName(Marshal.PtrToStringUTF8((IntPtr)path)) ?? ".", "hid.bin"));
                if (bad == 0 && SnapSwitch.CanSave)
                {   // 恢复局接着记：快照里的日志整份当开头，序号接着编（同原生层的句柄日志接续，thread.c s2a_snap_hlog_continue）
                    lock (_lock) { RebuildTable(all); _seq = _maxSeq + 1; _kept = n; }
                    SnapSwitch.Save = true;
                }
                return bad;
            }
            catch (Exception e) { Ryujinx.HLE.S2AHooks.SnapReplaying = false; Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：重放第 {n} 条后出错（正在重放 {cur_}）{e}"); return -1; }
        }

        // 预扫：序号 → 存档那局这条请求交出的域对象号
        private static Dictionary<int, int[]> OutIdsOf(byte[] all)
        {
            var m = new Dictionary<int, int[]>(); var r = new BinaryReader(new MemoryStream(all));
            while (r.BaseStream.Position < r.BaseStream.Length)
            {
                uint kind = r.ReadUInt32(); int seq = r.ReadInt32();
                if (kind == EntMeta) break;
                if (kind == EntReq) SkipEntryBody(r);
                else if (kind == EntObjs) { int c = r.ReadInt32(); var ids = new int[c]; for (int i = 0; i < c; i++) ids[i] = r.ReadInt32(); m[seq] = ids; }
            }
            return m;
        }
        // 每条请求建出的会话在存档时的 cookie（元数据里「建出的对象」中对象号 0 的那些）。日志按活对象收过：中间开了又关的会话不在了，
        //   重放时按先后分配的 cookie 会比存档时小，后面发给原 cookie 的请求就找不到会话——重放这条时让它建的会话用回原 cookie（Dispatcher.SnapForceCookies）。
        //   旧快照没有元数据：日志是全的，按先后分配本来就对得上
        private static Dictionary<int, ulong[]> SessionCookiesOf(byte[] all)
        {
            var m = new Dictionary<int, ulong[]>(); var r = new BinaryReader(new MemoryStream(all));
            while (r.BaseStream.Position < r.BaseStream.Length)
            {
                uint kind = r.ReadUInt32(); int seq = r.ReadInt32();
                if (kind == EntMeta)
                {
                    int ne = r.ReadInt32();
                    for (int i = 0; i < ne; i++)
                    {
                        int s = r.ReadInt32(); r.ReadUInt64(); r.ReadInt32(); int nc = r.ReadInt32(); var cs = new List<ulong>();
                        for (int j = 0; j < nc; j++) { ulong c = r.ReadUInt64(); int obj = r.ReadInt32(); if (obj == 0) cs.Add(c); }
                        int nu = r.ReadInt32(); r.BaseStream.Seek(4L * nu, SeekOrigin.Current); int nd = r.ReadInt32(); r.BaseStream.Seek(4L * nd, SeekOrigin.Current);   // 句柄依赖（这里用不着）
                        if (cs.Count > 0) m[s] = cs.ToArray();
                    }
                    break;
                }
                if (kind == EntReq) SkipEntryBody(r);
                else if (kind == EntObjs) { int c = r.ReadInt32(); r.BaseStream.Seek(4L * c, SeekOrigin.Current); }
            }
            return m;
        }

        // 恢复局接着记：快照里的条目按序号放回条目表，元数据（目标、建出的对象、已关但还收不掉的）照原样接上，之后照同一口径收；
        //   没有元数据的是存档时接在末尾的「只留最后一条」（渲染器 RequestUpdate、时钟 SetAndWait）：放回各自的表，下次存照样只留一条
        private static void RebuildTable(byte[] all)
        {
            _tab.Clear(); _lastNvWait.Clear(); _nvMapped.Clear(); _nvCookies.Clear(); _lastNifm.Clear();
            var r = new BinaryReader(new MemoryStream(all)); var parts = new SortedDictionary<int, (int Start, int End, long Cmd, ulong Cookie, string Name)>();
            int metaAt = -1;
            while (r.BaseStream.Position < r.BaseStream.Length)
            {
                int start = (int)r.BaseStream.Position; uint kind = r.ReadUInt32(); int seq = r.ReadInt32();
                if (kind == EntMeta) { metaAt = (int)r.BaseStream.Position; break; }
                long cmd = 0; ulong cookie = 0; string name = "";
                if (kind == EntReq)
                {
                    long body = r.BaseStream.Position; r.ReadUInt32(); cookie = r.ReadUInt64(); cmd = r.ReadInt64(); name = r.ReadString();
                    r.BaseStream.Position = body; SkipEntryBody(r);
                }
                else if (kind == EntObjs) { int c = r.ReadInt32(); r.BaseStream.Seek(4L * c, SeekOrigin.Current); }
                int end = (int)r.BaseStream.Position;
                if (kind == EntObjs && parts.TryGetValue(seq, out var p0)) parts[seq] = (p0.Start, end, p0.Cmd, p0.Cookie, p0.Name);   // 同一条请求的交出对象号接在它后面
                else parts[seq] = (start, end, cmd, cookie, name);
            }
            var targets = new Dictionary<int, (ReqTable.Key T, List<ReqTable.Key> C)>(); var closed = new List<ReqTable.Key>();
            var deps = new Dictionary<int, (List<uint> U, List<int> D)>();
            if (metaAt >= 0)
            {
                r.BaseStream.Position = metaAt; int ne = r.ReadInt32();
                for (int i = 0; i < ne; i++)
                {
                    int seq = r.ReadInt32(); var t = new ReqTable.Key(r.ReadUInt64(), r.ReadInt32()); int nc = r.ReadInt32(); var cs = new List<ReqTable.Key>();
                    for (int j = 0; j < nc; j++) cs.Add(new ReqTable.Key(r.ReadUInt64(), r.ReadInt32()));
                    targets[seq] = (t, cs);
                    var us = new List<uint>(); int nu = r.ReadInt32(); for (int j = 0; j < nu; j++) us.Add(r.ReadUInt32());
                    var ds = new List<int>(); int nd = r.ReadInt32(); for (int j = 0; j < nd; j++) ds.Add(r.ReadInt32());
                    if (us.Count > 0 || ds.Count > 0) deps[seq] = (us, ds);
                }
                int ncl = r.ReadInt32(); for (int i = 0; i < ncl; i++) closed.Add(new ReqTable.Key(r.ReadUInt64(), r.ReadInt32()));
            }
            foreach (var kv in parts)
            {
                byte[] bytes = all[kv.Value.Start..kv.Value.End];
                string n = kv.Value.Name; uint c = (uint)kv.Value.Cmd;
                if (n.Contains("INvDrvServices") && NvEntryOf(bytes, out uint fd, out uint ioc, out byte[] arg))
                {   // 同记录时的规则接着算：按槽最后一条收回按槽表；旧快照里本该不记的（Unmap、重复映射）这次存档起不再带
                    int nr = NvStep(kv.Value.Cookie, fd, ioc, arg, () => bytes, out int[] hs);
                    if (nr == 2 && !targets.ContainsKey(kv.Key)) continue;
                    if (nr == 1 && !targets.ContainsKey(kv.Key)) continue;
                    NvMapped(hs);
                }
                if (targets.TryGetValue(kv.Key, out var tc)) { _tab.Add(kv.Key, bytes, tc.T); continue; }
                if (n.Contains("AudioRenderer") && !n.Contains("Manager") && c == 4) { var ms = new MemoryStream(); ms.Write(bytes); _lastUpdate[kv.Value.Cookie] = ms; continue; }
                if (n.StartsWith("mm:") && (c == 2 || c == 6) && bytes.Length > 0 && MmRequestIdOf(bytes) is uint rid) { _lastMm[(kv.Value.Cookie, c, rid)] = bytes; continue; }
                if ((c == 0 || c == 4) && n.EndsWith(NifmRequest) && NifmLast(n, c, NifmKeyOf(bytes, kv.Value.Cookie), () => bytes)) continue;   // nifm 提交 / 取状态：回到按对象只留最后一对的表（按原顺序：先提交、后取状态）
                _tab.Add(kv.Key, bytes, new ReqTable.Key(0, 0));   // 旧快照（没有元数据）：挂在根上，不收（大小定在快照那一刻）
            }
            foreach (var kv in targets) foreach (ReqTable.Key ck in kv.Value.C) _tab.Created(kv.Key, ck);
            foreach (var kv in deps) _tab.Restore(kv.Key, kv.Value.U, kv.Value.D);
            foreach (ReqTable.Key k in closed) _tab.Close(k);
        }
        // 序列化好的一条（EntReq）的目标（会话 + 域对象，同记录时 TargetKey）
        private static ReqTable.Key NifmKeyOf(byte[] e, ulong cookie)
        {
            var r = new BinaryReader(new MemoryStream(e)); r.ReadUInt32(); r.ReadInt32(); r.ReadUInt32(); r.ReadUInt64(); r.ReadInt64(); r.ReadString();
            int size = r.ReadInt32(); byte[] msg = r.ReadBytes(size);
            fixed (byte* m = msg) return TargetKey(cookie, m, msg.Length, out _);
        }
        // 序列化好的一条（EntReq）里 mm:u SetAndWait 的请求号：消息原文里 CMIF 头后第 1 个 u32
        private static uint? MmRequestIdOf(byte[] e)
        {
            var r = new BinaryReader(new MemoryStream(e)); r.ReadUInt32(); r.ReadInt32(); r.ReadUInt32(); r.ReadUInt64(); r.ReadInt64(); r.ReadString();
            int size = r.ReadInt32(); byte[] msg = r.ReadBytes(size);
            fixed (byte* m = msg) return MmRequestId(m, msg.Length);
        }

        // 序列化好的一条（EntReq）里 nvdrv Ioctl 的 fd、ioctl 号、输入参数（取法同 NvIoctlOf：A 缓冲有长度用 A，否则 X）；不是 Ioctl 回 false
        private static bool NvEntryOf(byte[] e, out uint fd, out uint ioc, out byte[] arg)
        {
            fd = ioc = 0; arg = Array.Empty<byte>();
            var r = new BinaryReader(new MemoryStream(e));
            if (r.ReadUInt32() != EntReq) return false;
            r.ReadInt32(); r.ReadUInt32(); r.ReadUInt64(); long cmd = r.ReadInt64(); r.ReadString();
            if (!(cmd == 1 || cmd == 11 || cmd == 12)) return false;
            int size = r.ReadInt32(); byte[] msg = r.ReadBytes(size);
            int o = 8; for (; o + 16 + 8 <= size; o += 4) if (BitConverter.ToUInt32(msg, o) == 0x49434653u) break;
            if (o + 16 + 8 > size) return false;
            fd = BitConverter.ToUInt32(msg, o + 16); ioc = BitConverter.ToUInt32(msg, o + 20);
            int nd = r.ReadInt32(); byte[] x = null, a = null;
            for (int i = 0; i < nd; i++)
            {
                int kind = r.ReadInt32(); r.ReadInt32(); r.ReadUInt64(); ulong sz = r.ReadUInt64(); int len = r.ReadInt32(); byte[] d = r.ReadBytes(len);
                if (kind == 1 && sz > 0 && a == null) a = d; else if (kind == 0 && x == null) x = d;
            }
            arg = a ?? x ?? Array.Empty<byte>(); return true;
        }

        private static void SkipEntryBody(BinaryReader r)
        {
            r.ReadUInt32(); r.ReadUInt64(); r.ReadInt64(); r.ReadString();
            int size = r.ReadInt32(); r.BaseStream.Seek(size, SeekOrigin.Current);
            int nd = r.ReadInt32();
            for (int i = 0; i < nd; i++) { r.ReadInt32(); r.ReadInt32(); r.ReadUInt64(); r.ReadUInt64(); int len = r.ReadInt32(); r.BaseStream.Seek(len, SeekOrigin.Current); }
        }

        // ---------- 音频渲染器：整块存 / 拷回 + 块内指针平移 ----------
        // 音频渲染器工作缓冲（整块拷 + 平移块内指针）按 Ryujinx 这几个结构的大小排布：布局指纹 = 各结构名 + 大小 + 托管标量个数。
        //   同 C 侧 snapfmt.h 的布局指纹：存档记进清单，恢复前比，不同即拒绝。局限：字段换序但大小不变时这一版看不出（NativeAOT 下字段偏移反射不可靠）
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapAudioFp")]
        private static ulong AudioFp()
        {
            ulong h = 1469598103934665603ul;
            void Mix(string name, int size) { foreach (char c in name) h = (h ^ c) * 0x100000001b3ul; h = (h ^ (ulong)size) * 0x100000001b3ul; }
            Mix("VoiceState", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Common.VoiceState>());
            Mix("VoiceInfo", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Voice.VoiceInfo>());
            Mix("VoiceChannelResource", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Voice.VoiceChannelResource>());
            Mix("MixInfo", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Mix.MixInfo>());
            Mix("MemoryPoolInfo", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.MemoryPool.MemoryPoolInfo>());
            Mix("BiquadFilterState", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Dsp.State.BiquadFilterState>());
            Mix("SplitterState", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Splitter.SplitterState>());
            Mix("scalars", AudioRenderSystem.S2ASnapScalarCount);
            return h;
        }

        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapAudioSave")]
        private static int AudioSave(byte* path)
        {
            try
            {
                var m = Ryujinx.Horizon.Audio.AudioManagers.S2ALast?.AudioRendererManager;
                using var w = new BinaryWriter(File.Create(Marshal.PtrToStringUTF8((IntPtr)path)));
                if (m == null) { w.Write(0); return 0; }
                int n = 0;
                lock (m.S2ASessionLock)   // 工作线程停在两次处理之间
                {
                    System.Threading.Thread.Sleep(20);   // 内联 DSP 在会话锁外执行：等手上这一拍做完
                    foreach (var r in m.S2ASessions) if (r != null && r.S2ASnapBuffer.Ptr != IntPtr.Zero) n++;
                    w.Write(n);
                    foreach (var r in m.S2ASessions)
                    {
                        if (r == null || r.S2ASnapBuffer.Ptr == IntPtr.Zero) continue;
                        lock (r.S2ALock)
                        {
                            var (ptr, size) = r.S2ASnapBuffer;
                            w.Write(r.S2ASessionId); w.Write((ulong)ptr); w.Write(size); w.Write(new ReadOnlySpan<byte>((void*)ptr, size));
                            ulong[] sc = r.S2ASnapScalars(); w.Write(sc.Length); foreach (ulong v in sc) w.Write(v);
                        }
                    }
                }
                Console.Error.WriteLine($"[s2a] 即时存档：音频渲染器 {n} 个会话已存");
                AudioOutSave(Path.Combine(Path.GetDirectoryName(Marshal.PtrToStringUTF8((IntPtr)path)) ?? ".", "audout.bin"));
                return 0;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档：存音频渲染器失败 {e}"); return -1; }
        }

        // audout 缓冲队列（audout.bin，与 audio.bin 同目录）：游戏自己混音、经 audout 送 PCM 的（如一款格斗大作），队列命令（追加 / 取已交还 / 计数 / 冲刷）不进请求日志，
        //   队列在这里另存：每个会话的已交还未取走、未交还（按放的顺序）缓冲与已播采样数（Ryujinx.Audio AudioDeviceSession.S2ARestore）。
        //   会话由请求重放按原顺序重建（同会话号）。旧快照没有这个文件：照旧恢复、记一行黄
        private static void AudioOutSave(string file)
        {
            var mg = Ryujinx.Horizon.Audio.AudioManagers.S2ALast;
            var list = new List<(int, ((ulong, ulong, ulong)[], (ulong, ulong, ulong)[], ulong, bool))>();
            if (mg?.AudioOutputManager is { } om) lock (om.S2ASessionLock) { var ss = om.S2ASessions; for (int i = 0; i < ss.Length; i++) if (ss[i] != null) list.Add((i, ss[i].S2ASnapshot())); }
            QueueSave(file, "audout", list);
            var inl = new List<(int, ((ulong, ulong, ulong)[], (ulong, ulong, ulong)[], ulong, bool))>();
            if (mg?.AudioInputManager is { } im) lock (im.S2ASessionLock) { var ss = im.S2ASessions; for (int i = 0; i < ss.Length; i++) if (ss[i] != null) inl.Add((i, ss[i].S2ASnapshot())); }
            QueueSave(Path.Combine(Path.GetDirectoryName(file) ?? ".", "audin.bin"), "audin", inl);
        }
        private static void QueueSave(string file, string kind, List<(int, ((ulong, ulong, ulong)[], (ulong, ulong, ulong)[], ulong, bool))> list)
        {
            using var w = new BinaryWriter(File.Create(file));
            w.Write(list.Count);
            int bufs = 0;
            foreach (var (i, q) in list)
            {
                w.Write(i); w.Write(q.Item3); w.Write(q.Item4);
                w.Write(q.Item1.Length); foreach (var b in q.Item1) { w.Write(b.Item1); w.Write(b.Item2); w.Write(b.Item3); }
                w.Write(q.Item2.Length); foreach (var b in q.Item2) { w.Write(b.Item1); w.Write(b.Item2); w.Write(b.Item3); }
                bufs += q.Item1.Length + q.Item2.Length;
            }
            Console.Error.WriteLine($"[s2a] 即时存档：{kind} {list.Count} 个会话、队列里 {bufs} 个缓冲已存");
        }
        private static int AudioOutRestore(string file)
        {
            var mg = Ryujinx.Horizon.Audio.AudioManagers.S2ALast;
            int bad = QueueRestore(file, "audout", i => { var om = mg?.AudioOutputManager; if (om == null) return null; lock (om.S2ASessionLock) { var ss = om.S2ASessions; return i < ss.Length && ss[i] != null ? (ss[i].S2ARestore) : null; } });
            bad += QueueRestore(Path.Combine(Path.GetDirectoryName(file) ?? ".", "audin.bin"), "audin", i => { var im = mg?.AudioInputManager; if (im == null) return null; lock (im.S2ASessionLock) { var ss = im.S2ASessions; return i < ss.Length && ss[i] != null ? (ss[i].S2ARestore) : null; } });
            return bad;
        }
        private static int QueueRestore(string file, string kind, Func<int, Func<(ulong, ulong, ulong)[], (ulong, ulong, ulong)[], ulong, int>> find)
        {
            if (!File.Exists(file)) { Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：快照没有 {kind} 队列（旧快照），{kind} 会话从空队列开始"); return 0; }
            using var r = new BinaryReader(File.OpenRead(file));
            int n = r.ReadInt32(), ok = 0, bad = 0, again = 0;
            static (ulong, ulong, ulong)[] Bufs(BinaryReader r) { var a = new (ulong, ulong, ulong)[r.ReadInt32()]; for (int k = 0; k < a.Length; k++) a[k] = (r.ReadUInt64(), r.ReadUInt64(), r.ReadUInt64()); return a; }
            for (int k = 0; k < n; k++)
            {
                int i = r.ReadInt32(); ulong played = r.ReadUInt64(); r.ReadBoolean();
                var released = Bufs(r); var pending = Bufs(r);
                var restore = find(i);
                if (restore == null) { bad++; Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：{kind} 会话 {i} 在恢复局里没有（重放没重建）"); continue; }
                int got = restore(released, pending, played);
                if (got < 0) { bad++; Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：{kind} 会话 {i} 队列不空或放不下，没接上"); continue; }
                ok++; again += got;
                if (got != pending.Length) Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：{kind} 会话 {i} 在途缓冲 {pending.Length} 个只追加上 {got} 个");
            }
            Console.Error.WriteLine($"[s2a] 即时存档恢复：{kind} {ok}/{n} 个会话队列接上（重新追加在途缓冲 {again} 个）");
            return bad;
        }

        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapAudioRestore")]
        private static int AudioRestore(byte* path)
        {
            try
            {
                var m = Ryujinx.Horizon.Audio.AudioManagers.S2ALast?.AudioRendererManager;
                using var r = new BinaryReader(File.OpenRead(Marshal.PtrToStringUTF8((IntPtr)path)));
                int n = r.ReadInt32(), ok = 0, bad = 0; long moved = 0;
                lock (m.S2ASessionLock)
                {
                    for (int k = 0; k < n; k++)
                    {
                        int id = r.ReadInt32(); ulong old = r.ReadUInt64(); int size = r.ReadInt32(); byte[] data = r.ReadBytes(size);
                        int ns = r.ReadInt32(); ulong[] sc = new ulong[ns]; for (int i = 0; i < ns; i++) sc[i] = r.ReadUInt64();
                        AudioRenderSystem sys = null;
                        foreach (var x in m.S2ASessions) if (x != null && x.S2ASessionId == id) sys = x;
                        if (sys == null || sys.S2ASnapBuffer.Size != size) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：音频渲染器会话 {id} 在 B 里{(sys == null ? "没有" : $"大小不同（{sys.S2ASnapBuffer.Size} ≠ {size}）")}"); bad++; continue; }
                        lock (sys.S2ALock)
                        {
                            ulong nw = (ulong)sys.S2ASnapBuffer.Ptr; byte* p = (byte*)nw;
                            new ReadOnlySpan<byte>(data).CopyTo(new Span<byte>(p, size));
                            // 块内绝对指针（混音效果顺序表、分路器目的地链、内存池地址信息）：落在 A 的块范围里的 8 字节对齐值按基址差平移
                            for (int o = 0; o + 8 <= size; o += 8) { ulong v = *(ulong*)(p + o); if (v >= old && v < old + (ulong)size) { *(ulong*)(p + o) = v - old + nw; moved++; } }
                            sys.S2ARestoreScalars(sc);
                            sys.S2AForceEffectReinit();
                        }
                        ok++;
                    }
                }
                Console.Error.WriteLine($"[s2a] 即时存档恢复：音频渲染器 {ok}/{n} 个会话拷回，块内指针平移 {moved} 处{(bad > 0 ? $"，失败 {bad}" : "")}");
                bad += AudioOutRestore(Path.Combine(Path.GetDirectoryName(Marshal.PtrToStringUTF8((IntPtr)path)) ?? ".", "audout.bin"));
                return bad;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：音频渲染器拷回失败 {e}"); return -1; }
        }
    }
}
