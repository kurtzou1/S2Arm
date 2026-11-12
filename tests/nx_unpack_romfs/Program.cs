// 真 LibHac RomFsBuilder + IVFC；哈希由 SHA256 独立计算，预期字节取自本测试原始输入。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Reflection;
using System.Threading;
using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;
using IVFC = LibHac.Tools.FsSystem.IntegrityVerificationStorage;
using Path = System.IO.Path;

static class T {
    static int checks, failures;
    static readonly string Root = Path.Combine(Path.GetTempPath(), "s2arm-romfs-test-" + Guid.NewGuid().ToString("N"));
    static void Check(bool ok, string name) { checks++; if (!ok) failures++; Console.WriteLine($"{(ok ? "通" : "不通")} {name}"); }
    static Exception Error(Action action) { try { action(); return null; } catch (Exception e) { return e; } }
    sealed class Fixture {
        public readonly Dictionary<string, byte[]> Expected;
        public readonly byte[] Bytes, Hashes;
        public const int Block = 0x1000;
        public int Strict, None;
        public Fixture(bool small = false, bool empty = false, bool caseDirs = false) {
            Expected = new() { ["/big.bin"] = Enumerable.Range(0, small ? 64 : 0x9500).Select(i => (byte)(i * 13 + 7)).ToArray(),
                ["/sub/more"] = Enumerable.Range(0, small ? 31 : 0x5111).Select(i => (byte)(i * 7 + 3)).ToArray(), ["/zero"] = Array.Empty<byte>() };
            if (empty) Expected.Clear();
            if (caseDirs) Expected = new() { ["/A/one"] = new byte[] { 1, 2, 3 }, ["/a/two"] = new byte[] { 4, 5, 6 } };
            var builder = new RomFsBuilder();
            foreach (var e in Expected) builder.AddFile(e.Key, new StorageFile(new MemoryStorage(e.Value), OpenMode.Read));
            using var storage = builder.Build(); storage.GetSize(out long length).ThrowIfFailure();
            Bytes = new byte[(length + Block - 1) / Block * Block];
            storage.Read(0, Bytes.AsSpan(0, (int)length)).ThrowIfFailure();
            Hashes = new byte[Bytes.Length / Block * 32];
            Rehash();
        }
        public void ShiftFileRecords(int gap) {
            int meta = (int)H(0x38), metaSize = (int)H(0x40);
            Bytes.AsSpan(meta, metaSize).CopyTo(Bytes.AsSpan(meta + gap)); Array.Clear(Bytes, meta, gap); H(0x40, metaSize + gap);
            void ShiftPointer(int offset) { uint id = BinaryPrimitives.ReadUInt32LittleEndian(Bytes.AsSpan(offset)); if (id != uint.MaxValue) U(offset, id + (uint)gap); }
            for (int p = (int)H(0x28); p < H(0x28) + H(0x30); p += 4) ShiftPointer(p);
            for (int p = (int)H(0x18); p < H(0x18) + H(0x20);) {
                ShiftPointer(p + 12); p += (24 + (int)BinaryPrimitives.ReadUInt32LittleEndian(Bytes.AsSpan(p + 20)) + 3) & ~3;
            }
            for (int p = meta + gap; p < meta + metaSize + gap;) {
                ShiftPointer(p + 4); ShiftPointer(p + 24); p += (32 + (int)BinaryPrimitives.ReadUInt32LittleEndian(Bytes.AsSpan(p + 28)) + 3) & ~3;
            }
        }
        public void Rehash() { for (int i = 0; i < Bytes.Length / Block; i++) SHA256.HashData(Bytes.AsSpan(i * Block, Block)).CopyTo(Hashes.AsSpan(i * 32)); }
        public IStorage Open(IntegrityCheckLevel level) {
            if (level == IntegrityCheckLevel.None) Interlocked.Increment(ref None); else Interlocked.Increment(ref Strict);
            var ivfc = new IVFC(new IntegrityVerificationInfo { Data = new MemoryStorage(Bytes), BlockSize = Block, Type = IntegrityStorageType.RomFs },
                new MemoryStorage(Hashes), level, true);
            return new CachedStorage(ivfc, Block, 4, false);
        }
        public long H(int p) => BinaryPrimitives.ReadInt64LittleEndian(Bytes.AsSpan(p));
        public void H(int p, long v) => BinaryPrimitives.WriteInt64LittleEndian(Bytes.AsSpan(p), v);
        public void U(int p, uint v) => BinaryPrimitives.WriteUInt32LittleEndian(Bytes.AsSpan(p), v);
        public void TamperData(int index) { Bytes[H(0x48) + index] ^= 0x5a; Expected["/big.bin"][index] ^= 0x5a; }
        public bool Exact(string output) => Directory.GetFiles(output, "*", System.IO.SearchOption.AllDirectories).Length == Expected.Count &&
            Expected.All(e => File.ReadAllBytes(Path.Combine(output, e.Key.TrimStart('/'))).SequenceEqual(e.Value));
    }
    sealed class ReadFault : IStorage {
        readonly IStorage inner;
        public ReadFault(IStorage inner) { this.inner = inner; }
        public override Result Read(long offset, Span<byte> destination) {
            if (offset <= 0x8000 && offset + destination.Length > 0x8000) throw new IOException("synthetic None payload IO failure");
            return inner.Read(offset, destination);
        }
        public override Result GetSize(out long size) => inner.GetSize(out size);
        public override Result Flush() => inner.Flush();
        public override Result SetSize(long size) => throw new NotSupportedException();
        public override Result Write(long offset, ReadOnlySpan<byte> source) => throw new NotSupportedException();
        public override Result OperateRange(Span<byte> output, OperationId id, long offset, long size, ReadOnlySpan<byte> input) => throw new NotSupportedException();
        public override void Dispose() { inner.Dispose(); base.Dispose(); }
    }
    static RomfsExtraction.Result Extract(Fixture fixture, string name, bool patched = true) =>
        RomfsExtraction.Extract(fixture.Open, Path.Combine(Root, name, "romfs"), patched, partSize: 0x3000, parallelism: 3);
    static void Bad(string name, Action<Fixture> corrupt) {
        var fixture = new Fixture(); corrupt(fixture); string parent = Path.Combine(Root, name);
        Exception e = Error(() => { var result = Extract(fixture, name); P.WriteResourceManifest(Path.Combine(parent, "unpack.tsv"), "title_id\tfixture\n", result); });
        Check(e is InvalidDataException && fixture.None == 1 && !Directory.Exists(Path.Combine(parent, "romfs")) &&
            !File.Exists(Path.Combine(parent, "unpack.tsv")) && Directory.GetDirectories(parent).Length == 0, name + "：None 结构仍红、无成功产物 / 清单 / 暂存");
    }
    // ExeFS 使用真实 PFS0 + 严格 IVFC，经生产 ReadAll 读取，不把 RomFS 的 disabled 分支冒充 ExeFS。
    static void ExefsNegative() {
        byte[] expected = Enumerable.Range(0, 0x6000).Select(i => (byte)(i * 19)).ToArray();
        var builder = new PartitionFileSystemBuilder(); builder.AddFile("main", new StorageFile(new MemoryStorage(expected), OpenMode.Read));
        using var source = builder.Build(PartitionFileSystemType.Standard); source.GetSize(out long length).ThrowIfFailure();
        byte[] bytes = new byte[(length + 0xfff) & ~0xfffL]; source.Read(0, bytes.AsSpan(0, (int)length)).ThrowIfFailure();
        byte[] hashes = new byte[bytes.Length / 0x1000 * 32];
        for (int i = 0; i < bytes.Length / 0x1000; i++) SHA256.HashData(bytes.AsSpan(i * 0x1000, 0x1000)).CopyTo(hashes.AsSpan(i * 32));
        byte[] Read() {
            using var iv = new IVFC(new IntegrityVerificationInfo { Data = new MemoryStorage(bytes), BlockSize = 0x1000, Type = IntegrityStorageType.PartitionFs },
                new MemoryStorage(hashes), IntegrityCheckLevel.ErrorOnInvalid, true);
            using var cache = new CachedStorage(iv, 0x1000, 4, false);
            using var fs = new PartitionFileSystem(); fs.Initialize(cache).ThrowIfFailure();
            try { return (byte[])typeof(P).GetMethod("ReadAll", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { fs, "/main" }); }
            catch (TargetInvocationException e) { System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(e.InnerException).Throw(); throw; }
        }
        Check(Read().SequenceEqual(expected), "真实 ExeFS PFS0：生产 ReadAll 正常字节对照");
        bytes[0x4321] ^= 0x71;
        Exception error = Error(() => Read());
        Check(error is HorizonResultException && RomfsExtraction.IsDataHashFailure(error), "真实 ExeFS PFS0：即使同为 2002-4604，生产 ReadAll 仍抛出，不进入 RomFS 降级");
    }
    static int Comparison() {
        Directory.CreateDirectory(Root);
        try {
            foreach (bool tamper in new[] { false, true }) {
                var fixture = new Fixture(); if (tamper) fixture.TamperData(0x4321);
                string dst = Path.Combine(Root, tamper ? "bad" : "good");
                Exception error = Error(() => {
#if EXACT_BASELINE
                    if (Baseline.Extract(() => fixture.Open(IntegrityCheckLevel.ErrorOnInvalid), dst) != 0) throw new IOException("baseline returned failure");
#else
                    RomfsExtraction.Extract(fixture.Open, Path.Combine(dst, "romfs"), true);
#endif
                });
                Check(error == null && fixture.Exact(Path.Combine(dst, "romfs")), (tamper ? "tampered" : "normal") + ": expected full exact bytes; actual " + (error == null ? "success" : error.ToString()));
            }
        } finally { Directory.Delete(Root, true); }
        return failures == 0 ? 0 : 1;
    }
    static int Main(string[] args) {
        if (args.Contains("--comparison")) return Comparison();
        Directory.CreateDirectory(Root);
        try {
            ExefsNegative();
            var normal = new Fixture(); var nr = Extract(normal, "normal");
            string normalManifest = Path.Combine(Root, "normal", "unpack.tsv");
            P.WriteResourceManifest(normalManifest, "title_id\tfixture\n", nr);
            Check(normal.Exact(Path.Combine(Root, "normal", "romfs")) && !nr.Bypassed && normal.None == 0 &&
                !File.ReadAllText(normalManifest).Contains("integrity"), "正常：字节不变、严格通过、不标 bypassed");
            var bad = new Fixture(); bad.TamperData(0x4321);
            // 修前真实接口：同一 IVFC、同一 RomFsFile.Read；必须是精确 2002-4604，不以任意异常充数。
            Exception before = Error(() => {
                using var fs = new RomFsFileSystem(bad.Open(IntegrityCheckLevel.ErrorOnInvalid)); using var file = new UniqueRef<IFile>();
                fs.OpenFile(ref file.Ref, "/big.bin"u8, OpenMode.Read).ThrowIfFailure();
                file.Get.Read(out _, 0x4000, new byte[0x1000], ReadOption.None).ThrowIfFailure();
            });
            Check(RomfsExtraction.IsDataHashFailure(before), "修前严格文件读取：真实 IVFC 抛 2002-4604");
            var br = Extract(bad, "tampered"); var captured = new StringWriter(); TextWriter previous = Console.Out;
            try { Console.SetOut(captured); P.WriteResourceManifest(Path.Combine(Root, "tampered", "unpack.tsv"), "title_id\tfixture\n", br); }
            finally { Console.SetOut(previous); }
            Check(br.Bypassed && bad.Exact(Path.Combine(Root, "tampered", "romfs")) && br.Files == 3 && br.Bytes == bad.Expected.Sum(e => (long)e.Value.Length),
                "数据块篡改：整分区降级后所有文件精确等于篡改后预期（含跨块 / 多任务 / 零长）");
            // #787：黄字末尾点名第一处坏块（只有 /big.bin 被篡改；并行哪一份先撞上坏块不定，只核到文件名与「文件内偏移」）
            Check(captured.ToString().StartsWith("🟡 原件数据哈希不符（疑改版 / 整合版），已跳过 RomFS 完整性校验解出 3 个文件；第一处坏块在文件 romfs/big.bin，文件内偏移 ") &&
                captured.ToString().EndsWith(Environment.NewLine) && captured.ToString().Split('\n').Length == 2 &&
                File.ReadAllText(Path.Combine(Root, "tampered", "unpack.tsv")) == "title_id\tfixture\nintegrity\tbypassed\n", "生产清单写入：一行黄（点名坏块所在文件）+ unpack.tsv integrity=bypassed");
            var small = new Fixture(small: true); small.TamperData(7); var sr = Extract(small, "shared-block");
            Check(sr.Bypassed && small.Exact(Path.Combine(Root, "shared-block", "romfs")), "数据 / 头 / 目录共享 IVFC 块：结构合法仍能降级");
            var baseOnly = new Fixture(); baseOnly.TamperData(0x4321); Exception baseError = Error(() => Extract(baseOnly, "base-only", patched: false));
            Check(RomfsExtraction.IsDataHashFailure(baseError) && baseOnly.None == 0 && !Directory.Exists(Path.Combine(Root, "base-only", "romfs")), "非更新分区：仍严格，不扩展降级范围");
            var alias = new Fixture();
            // 第二文件 more 与 big 的前缀共用同一数据区；目录表可读，不能额外要求数据互斥。
            int fileMeta = (int)alias.H(0x38); int nextFile = (32 + (int)BinaryPrimitives.ReadUInt32LittleEndian(alias.Bytes.AsSpan(fileMeta + 28)) + 3) & ~3;
            alias.H(fileMeta + nextFile + 8, 0);
            alias.Expected["/sub/more"] = alias.Expected["/big.bin"].Take(alias.Expected["/sub/more"].Length).ToArray();
            var ar = Extract(alias, "data-alias");
            Check(ar.Bypassed && alias.Exact(Path.Combine(Root, "data-alias", "romfs")), "合法数据别名：允许两个文件共用同一 payload extent");
            var empty = new Fixture(empty: true); empty.Bytes[0x100] ^= 0x55;
            var er = Extract(empty, "empty");
            Check(er.Bypassed && er.Files == 0 && er.Bytes == 0 && empty.Exact(Path.Combine(Root, "empty", "romfs")), "空 RomFS：合法空 root / 零文件仍可读");
            var front = new Fixture(); int cursor = 0x50;
            foreach (int field in new[] { 8, 0x18, 0x28, 0x38 }) {
                int old = (int)front.H(field), size = (int)front.H(field + 8);
                front.Bytes.AsSpan(old, size).CopyTo(front.Bytes.AsSpan(cursor)); front.H(field, cursor); cursor += size;
            }
            var fr = Extract(front, "front-metadata");
            Check(cursor <= 0x200 && fr.Bypassed && front.Exact(Path.Combine(Root, "front-metadata", "romfs")), "合法布局变体：四张 metadata 表在 payload 前仍可读");
            var interrupted = new Fixture(); interrupted.TamperData(0x4321);
            string interruptedRoot = Path.Combine(Root, "payload-io"), interruptedOut = Path.Combine(interruptedRoot, "romfs");
            Exception interruptedError = Error(() => {
                var result = RomfsExtraction.Extract(level => level == IntegrityCheckLevel.None ? new ReadFault(interrupted.Open(level)) : interrupted.Open(level),
                    interruptedOut, true, partSize: 0x3000, parallelism: 3);
                P.WriteResourceManifest(Path.Combine(interruptedRoot, "unpack.tsv"), "title_id\tfixture\n", result);
            });
            Check(interruptedError is AggregateException && !RomfsExtraction.IsDataHashFailure(interruptedError) &&
                !Directory.Exists(interruptedOut) && !File.Exists(Path.Combine(interruptedRoot, "unpack.tsv")) && Directory.GetDirectories(interruptedRoot).Length == 0,
                "None 并发 payload IO 失败：worker 收尾、清掉全部前缀、没有成功清单");
            var rerun = RomfsExtraction.Extract(interrupted.Open, interruptedOut, true, partSize: 0x3000, parallelism: 3);
            Check(rerun.Bypassed && interrupted.Exact(interruptedOut), "失败后同一目标目录干净复跑：所有 bytes 精确，不残留旧片段");
            var padding = new Fixture(); padding.H(0x40, padding.H(0x40) + 4); padding.Rehash();
            var paddingStrict = Extract(padding, "table-padding-strict");
            Check(!paddingStrict.Bypassed && padding.Exact(Path.Combine(Root, "table-padding-strict", "romfs")), "表尾 padding：LibHac 严格正控接受合法未使用容量");
            padding.TamperData(0x4321); var paddingFallback = Extract(padding, "table-padding-fallback");
            Check(paddingFallback.Bypassed && padding.Exact(Path.Combine(Root, "table-padding-fallback", "romfs")), "表尾 padding + 数据篡改：不把 padding 当作损坏记录");
            var caseDirs = new Fixture(caseDirs: true); var caseStrict = Extract(caseDirs, "case-dirs-strict");
            Check(!caseStrict.Bypassed && caseDirs.Exact(Path.Combine(Root, "case-dirs-strict", "romfs")), "目录大小写不同、完整文件路径不冲突：LibHac 严格正控");
            caseDirs.Bytes[0x100] ^= 0x55; var caseFallback = Extract(caseDirs, "case-dirs-fallback");
            Check(caseFallback.Bypassed && caseDirs.Exact(Path.Combine(Root, "case-dirs-fallback", "romfs")), "目录大小写不同：降级沿用原来的完整文件路径判重边界");
            var sparse = new Fixture();
            sparse.ShiftFileRecords(8);
            sparse.Rehash(); var sparseStrict = Extract(sparse, "sparse-strict");
            Check(!sparseStrict.Bypassed && sparse.Exact(Path.Combine(Root, "sparse-strict", "romfs")), "稀疏记录 ID：表前留 8 字节，更新所有引用，LibHac 严格正控");
            sparse.TamperData(0x4321); var sparseFallback = Extract(sparse, "sparse-fallback");
            Check(sparseFallback.Bypassed && sparse.Exact(Path.Combine(Root, "sparse-fallback", "romfs")), "稀疏记录 ID + 数据篡改：按引用解析，不要求记录稠密");
            var unalignedTable = new Fixture(); int oldTable = (int)unalignedTable.H(0x38), tableSize = (int)unalignedTable.H(0x40);
            unalignedTable.Bytes.AsSpan(oldTable, tableSize).CopyTo(unalignedTable.Bytes.AsSpan(oldTable + 1)); unalignedTable.H(0x38, oldTable + 1); unalignedTable.Rehash();
            var utStrict = Extract(unalignedTable, "unaligned-table-strict");
            Check(!utStrict.Bypassed && unalignedTable.Exact(Path.Combine(Root, "unaligned-table-strict", "romfs")), "表绝对偏移 +1：LibHac 严格正控接受可读布局");
            unalignedTable.TamperData(0x4321); var utFallback = Extract(unalignedTable, "unaligned-table-fallback");
            Check(utFallback.Bypassed && unalignedTable.Exact(Path.Combine(Root, "unaligned-table-fallback", "romfs")), "表绝对偏移 +1：降级不额外要求绝对对齐");
            var shortPadding = new Fixture(); shortPadding.H(0x20, shortPadding.H(0x20) - 1); shortPadding.Rehash();
            var spStrict = Extract(shortPadding, "short-padding-strict");
            Check(!spStrict.Bypassed && shortPadding.Exact(Path.Combine(Root, "short-padding-strict", "romfs")), "末记录少一字节 padding：LibHac 严格正控接受实际内容完整");
            shortPadding.TamperData(0x4321); var spFallback = Extract(shortPadding, "short-padding-fallback");
            Check(spFallback.Bypassed && shortPadding.Exact(Path.Combine(Root, "short-padding-fallback", "romfs")), "末记录少一字节 padding：降级按实际记录范围核对");
            var unalignedIds = new Fixture(); unalignedIds.ShiftFileRecords(1); unalignedIds.Rehash();
            Exception uiStrict = Error(() => Extract(unalignedIds, "unaligned-ids-strict"));
            Check(uiStrict is IndexOutOfRangeException && unalignedIds.None == 0, "非对齐记录 ID +1：真实 LibHac 结构解析拒绝，不伪称合法布局");
            unalignedIds.Bytes[0x100] ^= 0x55;
            Exception uiFallback = Error(() => Extract(unalignedIds, "unaligned-ids-fallback"));
            Check(uiFallback is InvalidDataException && !Directory.Exists(Path.Combine(Root, "unaligned-ids-fallback", "romfs")), "非对齐记录 ID +1 / 坏哈希：None 结构校验仍拒绝，不发布产物");
            int keyOpens = 0; Exception keyError = Error(() => RomfsExtraction.Extract(level => {
                keyOpens++; throw new LibHac.Common.Keys.MissingKeyException("synthetic missing key");
            }, Path.Combine(Root, "missing-key", "romfs"), true));
            Check(keyError is LibHac.Common.Keys.MissingKeyException && keyOpens == 1, "真实 MissingKeyException 类型：立即失败、不开 None");
            Bad("header-size", f => f.H(0, 0x51));
            Bad("header-range", f => f.H(0x18, long.MaxValue));
            Bad("table-overlap", f => f.H(0x18, f.H(8)));
            Bad("directory-name-size", f => f.U((int)f.H(0x18) + 20, uint.MaxValue));
            Bad("directory-cycle", f => f.U((int)f.H(0x18) + 8, 0));
            Bad("directory-parent", f => f.U((int)f.H(0x18) + 24, 0x7fffffff));
            Bad("hash-chain-cycle", f => f.U((int)f.H(0x18) + 16, 0));
            Bad("file-range", f => f.H((int)f.H(0x38) + 16, long.MaxValue));
            Bad("file-metadata-overlap", f => f.H((int)f.H(0x38) + 8, f.H(0x18) - f.H(0x48)));
            Bad("wrong-key-equivalent", f => Array.Fill(f.Bytes, (byte)0xa5));
            var exact = new HorizonResultException(ResultFs.NonRealDataVerificationFailed.Value);
            Check(RomfsExtraction.IsDataHashFailure(new AggregateException(exact, new AggregateException(exact))) &&
                !RomfsExtraction.IsDataHashFailure(new AggregateException(exact, new IOException("disk"))) &&
                !RomfsExtraction.IsDataHashFailure(new IOException("VerificationFailed 2002-4604", exact)) &&
                !RomfsExtraction.IsDataHashFailure(new HorizonResultException(ResultFs.RomNonRealDataVerificationFailed.Value)),
                "分类：只收精确结果及全同类 aggregate，不吞混合 / 文字 / 其他哈希错误");
            int attempts = 0; string failed = Path.Combine(Root, "retry-fails", "romfs");
            Exception retryError = Error(() => RomfsExtraction.Extract(level => { attempts++; throw level == IntegrityCheckLevel.ErrorOnInvalid ? exact : new IOException("retry failed"); }, failed, true));
            Check(retryError is IOException && attempts == 2 && !Directory.Exists(failed) && Directory.GetDirectories(Path.GetDirectoryName(failed)).Length == 0,
                "None 再失败：只尝试一次、不发布成功产物");
            attempts = 0; Exception missing = Error(() => RomfsExtraction.Extract(level => { attempts++; throw new IOException("ticket/key/open failed"); }, Path.Combine(Root, "other", "romfs"), true));
            Check(missing is IOException && attempts == 1, "其他打开错误：不降级");
            string occupied = Path.Combine(Root, "occupied", "romfs"); Directory.CreateDirectory(occupied); File.WriteAllText(Path.Combine(occupied, "sentinel"), "keep");
            Exception occupiedError = Error(() => RomfsExtraction.Extract(normal.Open, occupied, true));
            Check(occupiedError is IOException && File.ReadAllText(Path.Combine(occupied, "sentinel")) == "keep", "已有输出：拒绝覆盖，原内容保持");
        } finally { Directory.Delete(Root, true); }
        Console.WriteLine($"{(failures == 0 ? "✓" : "✗")} nx_unpack RomFS：{checks} 项，不通 {failures}");
        return failures == 0 ? 0 : 1;
    }
}
