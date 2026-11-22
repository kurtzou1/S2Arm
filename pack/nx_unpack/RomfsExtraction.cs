// #633: 只给打过更新的 RomFS 一次明确标记的完整性降级；不改变可执行 / 控制 / DLC 分区。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;
using Path = System.IO.Path;

// #787：读坏块时的位置（文件 + 文件内偏移），包住原异常往上抛；报红处（Program.HashWhere）沿异常链取出来写进日志
internal sealed class ReadPlace : Exception { public ReadPlace(string where, Exception inner) : base(where, inner) { } }

static class RomfsExtraction {
    internal sealed record Result(int Files, long Bytes, int Parallelism, bool Bypassed, string FirstBad = null) {
        public string Manifest => Bypassed ? "integrity\tbypassed\n" : "";
        public string Warning => Bypassed ? $"🟡 原件数据哈希不符（疑改版 / 整合版），已跳过 RomFS 完整性校验解出 {Files} 个文件{(FirstBad == null ? "" : "；第一处坏块在" + FirstBad)}" : null;
    }
    sealed record Entry(string Path, long Size, long Off);
    sealed record Node(uint Parent, uint Sibling, uint ChildDir, uint ChildFile, uint Next, string Name, long Offset, long Size);
    const uint End = uint.MaxValue;
    const long PartSize = 1024L << 20;

    // 不能用消息文字，也不能只看 AggregateException 的第一项：混合 IO / 缺密钥等错误仍红。
    internal static bool IsDataHashFailure(Exception e) => e is ReadPlace r ? IsDataHashFailure(r.InnerException) : e is AggregateException a
        ? a.InnerExceptions.Count > 0 && a.InnerExceptions.All(IsDataHashFailure)
        : e is HorizonResultException h && h.ResultValue == ResultFs.NonRealDataVerificationFailed.Value;

    static readonly TimeSpan[] PublishRetryDelays = {
        TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(500),
        TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30)
    };

    static bool IsAccessDenied(Exception e) => e is UnauthorizedAccessException ||
        e is IOException && (e.HResult == unchecked((int)0x80070005) || e.HResult == unchecked((int)0x80070020));

    static void Publish(string stage, string destination, Action<string, string> move,
                        bool windows, Action<TimeSpan> wait = null) {
        Action<TimeSpan> pause = wait ?? (delay => Thread.Sleep(delay));
        try { move(stage, destination); }
        catch (Exception e) when (windows && IsAccessDenied(e)) {
            // 与 pack/orch/dirrename.py 对齐：等待 Windows 杀软 / 索引器释放新写文件的句柄。
            Exception lastDenied = e;
            foreach (TimeSpan delay in PublishRetryDelays) {
                pause(delay);
                try { move(stage, destination); return; }
                catch (Exception retry) when (IsAccessDenied(retry)) { lastDenied = retry; }
            }
            // 保留底层异常供错误分类器识别，同时把可操作路径和建议交给玩家。
            throw new IOException($"RomFS 目录发布退避重试 {PublishRetryDelays.Length} 次仍被拒绝：{stage}（最近一次错误：{lastDenied.Message}）。请等待文件扫描结束后重试，或将游戏库目录加入杀毒软件排除列表。", lastDenied);
        }
    }

    internal static void TestPublish(string root) {
        if (Directory.Exists(root) || File.Exists(root)) throw new IOException("测试目录已存在（不覆盖）");
        TimeSpan[] expectedRetries = {
            TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(500),
            TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4),
            TimeSpan.FromSeconds(8), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30)
        };
        if (!PublishRetryDelays.SequenceEqual(expectedRetries) ||
            !IsAccessDenied(new IOException("synthetic sharing violation", unchecked((int)0x80070020))))
            throw new InvalidDataException("Windows 发布退避表或 ERROR_SHARING_VIOLATION 分类与 dirrename.py 不一致");
        byte[] block = new byte[64 * 1024];
        if (OperatingSystem.IsWindows()) {
            string lockedStage = Path.Combine(root, "locked-stage"), lockedDestination = Path.Combine(root, "locked-published");
            Directory.CreateDirectory(lockedStage);
            File.WriteAllBytes(Path.Combine(lockedStage, "payload.bin"), block);
            using var blocker = new FileStream(Path.Combine(lockedStage, "payload.bin"), FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite); // 故意不授予 FileShare.Delete，令 Windows 真正拒绝目录改名。
            int lockedMoves = 0, lockDeniedHResult = 0;
            TimeSpan lockedWait = TimeSpan.Zero;
            TimeSpan releaseAfter = TimeSpan.FromMilliseconds(150);
            void LockedMove(string from, string to) {
                lockedMoves++;
                try { Directory.Move(from, to); }
                catch (Exception e) { if (lockedMoves == 1) lockDeniedHResult = e.HResult; throw; }
            }
            void WaitAndRelease(TimeSpan delay) {
                Thread.Sleep(delay);
                lockedWait += delay;
                if (lockedWait >= releaseAfter) blocker.Dispose();
            }
            Publish(lockedStage, lockedDestination, LockedMove, windows: true, wait: WaitAndRelease);
            if (lockedMoves < 2 || !IsAccessDenied(new IOException("test", lockDeniedHResult)) || lockedWait < releaseAfter ||
                Directory.Exists(lockedStage) || !File.Exists(Path.Combine(lockedDestination, "payload.bin")))
                throw new InvalidDataException("真实 Windows 文件句柄等待后未能发布");
            Console.WriteLine($"🟢 Windows 同盘句柄测试：真实 Directory.Move 初次拒绝 0x{lockDeniedHResult:X8}；固定等待至少 {releaseAfter.TotalMilliseconds:F0} ms 后释放句柄并发布成功");
        } else Console.WriteLine("🟡 Windows 同盘句柄对照：非 Windows 跳过");
        byte[] expected = { 0x53, 0x32, 0x41, 0x00, 0x7f };

        string oldStage = Path.Combine(root, "old-stage"), oldDestination = Path.Combine(root, "old-published");
        Directory.CreateDirectory(oldStage);
        File.WriteAllBytes(Path.Combine(oldStage, "payload.bin"), expected);
        int oldMoves = 0;
        void DenyFirstMove(string from, string to) {
            if (++oldMoves == 1) throw new IOException("synthetic access denied", unchecked((int)0x80070005));
            Directory.Move(from, to);
        }
        try {
            Publish(oldStage, oldDestination, DenyFirstMove, windows: false,
                wait: _ => throw new InvalidDataException("非 Windows 不应等待重试"));
            throw new InvalidDataException("非 Windows 负对照应原样抛出首次拒绝");
        } catch (IOException e) when (e.Message == "synthetic access denied") { }
        if (oldMoves != 1 || !Directory.Exists(oldStage) || Directory.Exists(oldDestination))
            throw new InvalidDataException("非 Windows 负对照没有证明一次拒绝后原样失败");
        Console.WriteLine("🟢 负对照：windows=false 的直接发布遇一次 E_ACCESSDENIED 即原样失败，不等待、不 flush");

        string deniedStage = Path.Combine(root, "denied-stage"), deniedDestination = Path.Combine(root, "denied-published");
        Directory.CreateDirectory(deniedStage);
        File.WriteAllBytes(Path.Combine(deniedStage, "payload.bin"), expected);
        int deniedMoves = 0, deniedWaits = 0;
        TimeSpan deniedWaited = TimeSpan.Zero;
        void AlwaysDeny(string from, string to) {
            deniedMoves++;
            throw new IOException("synthetic persistent access denied", unchecked((int)0x80070005));
        }
        try {
            Publish(deniedStage, deniedDestination, AlwaysDeny, windows: true,
                wait: delay => { deniedWaits++; deniedWaited += delay; });
            throw new InvalidDataException("持续访问拒绝不应被吞掉");
        } catch (IOException e) when (e.Message.Contains("RomFS 目录发布退避重试")) {
            if (!e.Message.Contains(deniedStage) || !e.Message.Contains("加入杀毒软件排除列表"))
                throw new InvalidDataException("最终拒绝错误未包含目录路径和杀软排除建议", e);
        }
        if (deniedMoves != 10 || deniedWaits != PublishRetryDelays.Length ||
            deniedWaited != TimeSpan.FromMilliseconds(60_800) || !Directory.Exists(deniedStage) || Directory.Exists(deniedDestination))
            throw new InvalidDataException("持续访问拒绝未保留暂存目录或被错误吞掉");
        Console.WriteLine("🟢 合成负控：持续拒绝 → 按 dirrename 重试 9 次（总等待 60.8 秒）后报红；提示路径和杀软排除，暂存保留、目标未创建");
    }

    internal static Result Extract(Func<IntegrityCheckLevel, IStorage> open, string destination, bool patched,
                                   long partSize = PartSize, int parallelism = 0) {
        if (partSize <= 0) throw new ArgumentOutOfRangeException(nameof(partSize));
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("RomFS 输出已存在（不覆盖）");
        string parent = Path.GetDirectoryName(Path.GetFullPath(destination));
        Directory.CreateDirectory(parent);
        string stage = Path.Combine(parent, ".romfs-extract-" + Guid.NewGuid().ToString("N"));
        try {
            Result result;
            try { result = Attempt(open, stage, IntegrityCheckLevel.ErrorOnInvalid, partSize, parallelism); }
            catch (Exception e) when (IsDataHashFailure(e)) {
                // Parallel.For 抛出前已收齐 worker；所有视图已 Dispose，才能清掉失败前缀并整分区重读。
                if (Directory.Exists(stage)) Directory.Delete(stage, true);
                string first = (e is AggregateException g ? g.InnerExceptions.ToArray() : new[] { e }).OfType<ReadPlace>().Select(r => r.Message).FirstOrDefault();
                result = Attempt(open, stage, IntegrityCheckLevel.None, partSize, parallelism) with { Bypassed = true, FirstBad = first };
            }
            Publish(stage, destination, Directory.Move, OperatingSystem.IsWindows());
            return result;
        } finally {
            if (Directory.Exists(stage)) Directory.Delete(stage, true);
        }
    }

    // 镜像形态（缺省，S2A_ROMFS_IMAGE=0 关）：合并后的 RomFS 不拆成散文件，直接写一份标准 RomFS 镜像 <产物根>/romfs.std。
    //   与「先解成 romfs/ 再 services/romfs_index.sh --std 建镜像」逐字节相同：同一个 LibHac RomFsBuilder、同样按相对路径 Ordinal 排序加文件、
    //   同样跳过宿主垃圾名（IsHostJunk，同 services RomFsIndex.IsHostJunk）。完整性降级、只差大小写报红、不覆盖已有输出都与目录形态同一口径。
    //   open == null：程序没有资源分区，写一份空 RomFS（对应目录形态的空 romfs/）。
    internal const string ImageName = "romfs.std";
    internal static Result ExtractImage(Func<IntegrityCheckLevel, IStorage> open, string destination, bool patched,
                                        long chunkSize = ImageChunk, int parallelism = 0) {
        if (chunkSize <= 0) throw new ArgumentOutOfRangeException(nameof(chunkSize));
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("RomFS 镜像输出已存在（不覆盖）");
        string parent = Path.GetDirectoryName(Path.GetFullPath(destination));
        Directory.CreateDirectory(parent);
        string stage = Path.Combine(parent, ".romfs-image-" + Guid.NewGuid().ToString("N"));
        try {
            Result result;
            try { result = AttemptImage(open, stage, IntegrityCheckLevel.ErrorOnInvalid, chunkSize, parallelism); }
            catch (Exception e) when (open != null && IsDataHashFailure(e)) {
                File.Delete(stage);
                string first = (e is AggregateException g ? g.InnerExceptions.ToArray() : new[] { e }).OfType<ReadPlace>().Select(r => r.Message).FirstOrDefault();
                result = AttemptImage(open, stage, IntegrityCheckLevel.None, chunkSize, parallelism) with { Bypassed = true, FirstBad = first };
            }
            File.Move(stage, destination);
            return result;
        } finally {
            if (File.Exists(stage)) File.Delete(stage);
        }
    }
    // 8 MB 一块：读的路数 × 2 块在途，28 路也只占约 450 MB
    const long ImageChunk = 8L << 20;

    // 同 services/S2A.Services/RomFsIndex.cs IsHostJunk：目录形态下这些名字不进镜像，这里也不进，两种形态才逐字节相同
    internal static bool IsHostJunk(string path) {
        string name = path[(path.LastIndexOf('/') + 1)..];
        return name == ".DS_Store" || name.StartsWith("._", StringComparison.Ordinal);
    }

    // 测试钩子：每写一块报（偏移、长度）；产品里为 null
    internal static Action<long, int> ImageWriteObserved;

    // 读多路并行、写按偏移从前到后（#1970）：原先每路各写自己那段，一个 13 GB 文件同时在十几处往后写。Windows NTFS 在有效数据长度之后写时
    //   要先把中间补零，慢盘（移动硬盘）上退化成十几路寻道 + 补零，0100F3400332C000 一单 4.5 小时没写完；同一台机器旧的散文件形态 50 分钟。
    //   块号按顺序领（领号即占一个缓冲），写的一侧总在等最小的未写块、它一定已被领走在读，所以不会互相等死；在途最多「读的路数 × 2」块
    static Result AttemptImage(Func<IntegrityCheckLevel, IStorage> open, string stage, IntegrityCheckLevel level,
                               long chunkSize, int parallelism) {
        var files = (open == null ? new List<Entry>() : ListEntries(open, level)).Where(e => !IsHostJunk(e.Path))
            .OrderBy(e => e.Path, StringComparer.Ordinal).ToList();
        using var views = new ThreadLocal<RomFsFileSystem>(() => new RomFsFileSystem(open(level)), true);
        try {
            var builder = new RomFsBuilder();
            foreach (Entry e in files) builder.AddFile(e.Path, new ViewFile(views, e.Path, e.Size));
            using IStorage image = builder.Build();
            image.GetSize(out long total).ThrowIfFailure();
            int parts = checked((int)Math.Max(1, (total + chunkSize - 1) / chunkSize));
            int workers = Math.Min(parts, parallelism <= 0 ? Environment.ProcessorCount : parallelism);
            int window = Math.Min(parts, workers * 2);
            var free = new System.Collections.Concurrent.ConcurrentBag<byte[]>();
            for (int i = 0; i < window; i++) free.Add(new byte[(int)Math.Min(chunkSize, total)]);
            var slots = new SemaphoreSlim(window);
            var done = new (byte[] Buf, int Len)?[parts];
            var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
            var gate = new object();
            using var cts = new CancellationTokenSource();
            int next = -1;
            bool big = total >= 1L << 30;
            if (big) Console.WriteLine($"资源镜像：{total >> 20} MB，{workers} 路读、按顺序写");
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var readers = Enumerable.Range(0, workers).Select(_ => Task.Run(() => {
                try {
                    while (true) {
                        slots.Wait(cts.Token);
                        int k = Interlocked.Increment(ref next);
                        if (k >= parts) { slots.Release(); return; }
                        free.TryTake(out byte[] buffer);
                        long lo = k * chunkSize; int n = (int)Math.Min(chunkSize, total - lo);
                        for (int at = 0; at < n;) {
                            int m = Math.Min(4 << 20, n - at);
                            image.Read(lo + at, buffer.AsSpan(at, m)).ThrowIfFailure(); at += m;
                        }
                        lock (gate) { done[k] = (buffer, n); Monitor.PulseAll(gate); }
                    }
                } catch (OperationCanceledException) when (cts.IsCancellationRequested) {
                } catch (Exception e) {
                    errors.Enqueue(e); cts.Cancel();
                    lock (gate) Monitor.PulseAll(gate);
                }
            })).ToArray();
            try {
                using var handle = File.OpenHandle(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None, FileOptions.None, total);
                int shown = 0;
                for (int k = 0; k < parts; k++) {
                    (byte[] Buf, int Len) got;
                    lock (gate) {
                        while (done[k] == null && errors.IsEmpty) Monitor.Wait(gate);
                        if (done[k] == null) break;
                        got = done[k].Value; done[k] = null;
                    }
                    long lo = k * chunkSize;
                    RandomAccess.Write(handle, got.Buf.AsSpan(0, got.Len), lo);
                    ImageWriteObserved?.Invoke(lo, got.Len);
                    free.Add(got.Buf); slots.Release();
                    int pct = big ? (int)((lo + got.Len) * 10 / total) : 0;
                    if (pct > shown) { shown = pct; double sec = clock.Elapsed.TotalSeconds;
                        Console.WriteLine($"资源镜像：已写 {(lo + got.Len) >> 20} / {total >> 20} MB（{pct * 10}%，{sec:F0} 秒，{((lo + got.Len) >> 20) / Math.Max(sec, 0.001):F1} MB/s）"); }
                }
            } finally {
                cts.Cancel();
                lock (gate) Monitor.PulseAll(gate);
                Task.WaitAll(readers.Select(t => t.ContinueWith(_ => { })).ToArray());
            }
            if (!errors.IsEmpty) throw new AggregateException(errors);
            return new Result(files.Count, files.Sum(e => e.Size), workers, false);
        } finally { foreach (var fs in views.Values) fs.Dispose(); }
    }

    // 镜像里一个文件的数据：每个线程从自己的那份 RomFS 视图按路径读（LibHac 的读视图带缓存、不跨线程共用）；读坏块时同目录形态包上位置
    sealed class ViewFile : IFile {
        readonly ThreadLocal<RomFsFileSystem> views; readonly string path; readonly long size;
        public ViewFile(ThreadLocal<RomFsFileSystem> views, string path, long size) { this.views = views; this.path = path; this.size = size; }
        protected override LibHac.Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option) {
            bytesRead = 0;
            int want = (int)Math.Max(0, Math.Min(destination.Length, size - offset));
            if (want == 0) return LibHac.Result.Success;
            using var file = new UniqueRef<IFile>();
            views.Value.OpenFile(ref file.Ref, path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            file.Get.GetSize(out long now).ThrowIfFailure();
            if (now != size) throw new InvalidDataException("RomFS 文件长度在读取时改变");
            while (bytesRead < want) {
                long got;
                try { file.Get.Read(out got, offset + bytesRead, destination[(int)bytesRead..want], ReadOption.None).ThrowIfFailure(); }
                catch (Exception x) when (x is not ReadPlace) { throw new ReadPlace($"文件 romfs{path}，文件内偏移 {offset + bytesRead}（读 {want - bytesRead} 字节）", x); }
                if (got <= 0 || got > want - bytesRead) throw new IOException("RomFS 文件未完整读出");
                bytesRead += got;
            }
            return LibHac.Result.Success;
        }
        protected override LibHac.Result DoGetSize(out long size) { size = this.size; return LibHac.Result.Success; }
        protected override LibHac.Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => ResultFs.WriteUnpermitted.Value;
        protected override LibHac.Result DoFlush() => LibHac.Result.Success;
        protected override LibHac.Result DoSetSize(long size) => ResultFs.WriteUnpermitted.Value;
        protected override LibHac.Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
            => ResultFs.NotImplemented.Value;
    }

    // 列条目（严格：LibHac 遍历；None：先自己核结构再列）；目录形态与镜像形态共用，两种形态看到的是同一份文件表
    static List<Entry> ListEntries(Func<IntegrityCheckLevel, IStorage> open, IntegrityCheckLevel level) {
        using IStorage storage = open(level);
        if (level == IntegrityCheckLevel.None) return ReadDirectory(storage);
        using var fs = new RomFsFileSystem(storage);
        var entries = new List<Entry>(); long offset = 0;
        void Walk(string dir) {
            var all = fs.EnumerateEntries(dir, "*", SearchOptions.Default).ToList();
            foreach (var e in all.Where(e => e.Type == DirectoryEntryType.File).OrderBy(e => e.Name, StringComparer.Ordinal)) {
                entries.Add(new Entry(e.FullPath, e.Size, offset)); offset = checked(offset + e.Size);
            }
            foreach (var e in all.Where(e => e.Type == DirectoryEntryType.Directory).OrderBy(e => e.Name, StringComparer.Ordinal)) Walk(e.FullPath + "/");
        }
        Walk("/");
        if (entries.Select(e => e.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != entries.Count)
            throw new InvalidDataException("RomFS 资源里有只差大小写的路径");
        return entries;
    }

    static Result Attempt(Func<IntegrityCheckLevel, IStorage> open, string stage, IntegrityCheckLevel level,
                          long partSize, int parallelism) {
        List<Entry> entries = ListEntries(open, level);
        Directory.CreateDirectory(stage);
        foreach (Entry e in entries) {
            string dst = Path.Combine(stage, e.Path.TrimStart('/'));
            Directory.CreateDirectory(Path.GetDirectoryName(dst));
            // 每次尝试都是独立空目录；失败后的重试不复用任何稀疏尾部或已完成的块。
            using var f = new FileStream(dst, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite);
            f.SetLength(e.Size);
        }
        long total = entries.Sum(e => e.Size);
        int parts = checked((int)Math.Max(1, total / partSize + (total % partSize == 0 ? 0 : 1)));
        int workers = Math.Min(parts, parallelism <= 0 ? Environment.ProcessorCount : parallelism);
        var offsets = entries.Select(e => e.Off).ToArray();
        using var views = new ThreadLocal<RomFsFileSystem>(() => new RomFsFileSystem(open(level)), true);
        try {
            Parallel.For(0, parts, new ParallelOptions { MaxDegreeOfParallelism = workers }, k => {
                long lo = k * partSize, hi = lo + Math.Min(partSize, total - lo);
                byte[] buffer = new byte[4 << 20];
                int i = Array.BinarySearch(offsets, lo); if (i < 0) i = ~i - 1; if (i < 0) i = 0;
                for (; i < entries.Count && entries[i].Off < hi; i++) {
                    Entry e = entries[i];
                    long from = Math.Max(lo, e.Off), to = Math.Min(hi, e.Off + e.Size);
                    if (from >= to) continue;
                    using var file = new UniqueRef<IFile>();
                    views.Value.OpenFile(ref file.Ref, e.Path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                    file.Get.GetSize(out long size).ThrowIfFailure();
                    if (size != e.Size) throw new InvalidDataException("RomFS 文件长度在读取时改变");
                    using var dst = new FileStream(Path.Combine(stage, e.Path.TrimStart('/')), FileMode.Open, FileAccess.Write, FileShare.ReadWrite, 1);
                    dst.Position = from - e.Off;
                    for (long p = from; p < to;) {
                        int want = (int)Math.Min(buffer.Length, to - p);
                        long got;
                        try { file.Get.Read(out got, p - e.Off, buffer.AsSpan(0, want), ReadOption.None).ThrowIfFailure(); }
                        catch (Exception x) when (x is not ReadPlace) { throw new ReadPlace($"文件 romfs{e.Path}，文件内偏移 {p - e.Off}（读 {want} 字节）", x); }
                        if (got <= 0 || got > want) throw new IOException("RomFS 文件未完整读出");
                        dst.Write(buffer, 0, (int)got); p += got;
                    }
                }
            });
        } finally { foreach (var fs in views.Values) fs.Dispose(); }
        return new Result(entries.Count, total, workers, false);
    }

    // None 只免数据块哈希，不免结构校验。先核范围、链接与目录树，再让 LibHac 按原格式开文件。
    // 数据可以在目录表前；不要求某个生成器的布局，零长文件可恰在数据区末端。
    static List<Entry> ReadDirectory(IStorage storage) {
        static InvalidDataException Bad() => new("RomFS 头 / 目录表无效；不能跳过结构校验");
        storage.GetSize(out long length).ThrowIfFailure();
        byte[] header = new byte[0x50]; storage.Read(0, header).ThrowIfFailure();
        long H(int p) => BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(p));
        if (H(0) != 0x50 || H(0x48) < 0x50 || H(0x48) > length) throw Bad();
        var ranges = new List<(long Start, long Size)> { (0, 0x50) };
        byte[] Table(int p, bool hash) {
            long off = H(p), size = H(p + 8);
            if (off < 0x50 || off > length || size < 0 || size > length - off || size > int.MaxValue ||
                (hash && (size == 0 || (size & 3) != 0))) throw Bad();
            if (ranges.Any(r => size > 0 && r.Size > 0 && off < r.Start + r.Size && r.Start < off + size)) throw Bad();
            ranges.Add((off, size));
            byte[] data = new byte[(int)size]; storage.Read(off, data).ThrowIfFailure(); return data;
        }
        byte[] db = Table(8, true), dm = Table(0x18, false), fb = Table(0x28, true), fm = Table(0x38, false);
        static uint U(byte[] b, int p) => BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(p));
        var utf8 = new UTF8Encoding(false, true);
        // 表中的 ID 是显式偏移，不要求记录稠密排列；未引用的容量 / padding 不当作新记录。
        Dictionary<uint, Node> ParseBuckets(byte[] buckets, byte[] table, bool directory) {
            var nodes = new Dictionary<uint, Node>();
            var spans = new List<(int Start, int End)>(); int fixedSize = directory ? 24 : 32;
            Node ReadNode(uint id) {
                if (id > int.MaxValue || (id & 3) != 0 || table.Length < fixedSize || id > table.Length - fixedSize) throw Bad();
                int p = (int)id; uint nameLength = U(table, p + fixedSize - 4);
                if (nameLength > table.Length - p - fixedSize) throw Bad();
                int end = checked(p + fixedSize + (int)nameLength);
                if (end > table.Length) throw Bad();
                string name;
                try { name = utf8.GetString(table, p + fixedSize, (int)nameLength); }
                catch (DecoderFallbackException) { throw Bad(); }
                if ((name.Length == 0 && (!directory || p != 0)) || name is "." or ".." || name.IndexOfAny(new[] { '/', '\\', '\0' }) >= 0) throw Bad();
                long off = directory ? 0 : BinaryPrimitives.ReadInt64LittleEndian(table.AsSpan(p + 8));
                long size = directory ? 0 : BinaryPrimitives.ReadInt64LittleEndian(table.AsSpan(p + 16));
                if (!directory) {
                    if (off < 0 || size < 0 || off > length - H(0x48) || size > length - H(0x48) - off) throw Bad();
                    long start = H(0x48) + off;
                    if (ranges.Any(r => size > 0 && start < r.Start + r.Size && r.Start < start + size)) throw Bad();
                }
                spans.Add((p, end));
                return new Node(U(table, p), U(table, p + 4), directory ? U(table, p + 8) : End,
                    directory ? U(table, p + 12) : End, U(table, p + fixedSize - 8), name, off, size);
            }
            for (int p = 0; p < buckets.Length; p += 4) {
                for (uint id = U(buckets, p); id != End; id = nodes[id].Next) {
                    if (nodes.ContainsKey(id)) throw Bad();   // 哈希链环 / 一个记录被重复引用
                    nodes.Add(id, ReadNode(id));
                }
            }
            int previousEnd = 0;
            foreach (var span in spans.OrderBy(x => x.Start)) {
                if (span.Start < previousEnd) throw Bad();
                previousEnd = span.End;
            }
            return nodes;
        }
        var dirs = ParseBuckets(db, dm, true); var files = ParseBuckets(fb, fm, false);
        if (!dirs.TryGetValue(0, out var root) || root.Parent != 0 || root.Name.Length != 0 || root.Sibling != End) throw Bad();
        var seenDirs = new HashSet<uint> { 0 }; var seenFiles = new HashSet<uint>();
        var paths = new HashSet<string>(StringComparer.Ordinal);
        var filePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var stack = new Stack<(uint Id, string Path)>(); stack.Push((0, "/"));
        var listed = new List<(string Path, long Size)>();
        while (stack.Count > 0) {
            var (id, path) = stack.Pop(); Node dir = dirs[id];
            for (uint child = dir.ChildDir; child != End; child = dirs[child].Sibling) {
                if (!dirs.TryGetValue(child, out var d) || d.Parent != id || !seenDirs.Add(child)) throw Bad();
                string full = path + d.Name;
                if (!paths.Add(full)) throw Bad();
                stack.Push((child, full + "/"));
            }
            for (uint child = dir.ChildFile; child != End; child = files[child].Sibling) {
                if (!files.TryGetValue(child, out var f) || f.Parent != id || !seenFiles.Add(child)) throw Bad();
                string full = path + f.Name;
                if (!paths.Add(full) || !filePaths.Add(full)) throw Bad();
                listed.Add((full, f.Size));
            }
        }
        if (seenDirs.Count != dirs.Count || seenFiles.Count != files.Count) throw Bad();
        long offset = 0; var entries = new List<Entry>();
        foreach (var f in listed.OrderBy(f => f.Path, StringComparer.Ordinal)) {
            entries.Add(new Entry(f.Path, f.Size, offset)); offset = checked(offset + f.Size);
        }
        return entries;
    }
}
