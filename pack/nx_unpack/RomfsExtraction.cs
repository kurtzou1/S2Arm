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
            catch (Exception e) when (patched && IsDataHashFailure(e)) {
                // Parallel.For 抛出前已收齐 worker；所有视图已 Dispose，才能清掉失败前缀并整分区重读。
                if (Directory.Exists(stage)) Directory.Delete(stage, true);
                string first = (e is AggregateException g ? g.InnerExceptions.ToArray() : new[] { e }).OfType<ReadPlace>().Select(r => r.Message).FirstOrDefault();
                result = Attempt(open, stage, IntegrityCheckLevel.None, partSize, parallelism) with { Bypassed = true, FirstBad = first };
            }
            Directory.Move(stage, destination);
            return result;
        } finally {
            if (Directory.Exists(stage)) Directory.Delete(stage, true);
        }
    }

    static Result Attempt(Func<IntegrityCheckLevel, IStorage> open, string stage, IntegrityCheckLevel level,
                          long partSize, int parallelism) {
        List<Entry> entries;
        using (IStorage storage = open(level)) {
            if (level == IntegrityCheckLevel.None) entries = ReadDirectory(storage);
            else {
                using var fs = new RomFsFileSystem(storage);
                entries = new List<Entry>(); long offset = 0;
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
            }
        }
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
