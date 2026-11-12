using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Path = System.IO.Path;

namespace S2A.Services
{
    // 预建 RomFS 索引（出包时生成，起局直接读）：解开的 romfs/ 目录要现建 RomFS 镜像，就得枚举十几万个文件、逐个取长度、再由 LibHac 建目录表——
    // 01006F8002326000 Mac 暖局 450 ms、iPhone 约 2.7 秒，占 S2A_Init 八成。索引记下 LibHac 建出的镜像布局：每个文件在镜像里的偏移 / 长度 / 相对路径，
    // 以及文件数据以外的全部字节（头、目录 / 文件哈希与元数据表；全零的对齐填充不存）。起局读这一个文件即可拼出同一镜像，文件读到时才打开。
    //
    // 格式（小端）："S2ARFS01" | i64 镜像长 | i32 文件数 | 文件数 × {i64 偏移, i64 长度, i32 路径偏移, i32 路径长} | i32 路径区长 | 路径区（UTF-8，相对 romfs/，/ 分隔）
    //              | i32 段数 | 段数 × {i64 偏移, i32 长度} | 各段字节依次
    public static class RomFsIndex
    {
        public const string FileName = "romfs.s2aidx";
        public const string ImageName = "romfs.img";
        public const string ImageMapName = "romfs.imgmap";
        public const string ImageOverlayDir = "romfs_overlay";
        private static ReadOnlySpan<byte> ImageMagic => "S2ARIM01"u8;
        private static ReadOnlySpan<byte> Magic => "S2ARFS01"u8;

        public static void Write(string romfsDir, string outPath) => Write(romfsDir, outPath, null);

        // listPath：出包期 RomFS 清单（graphics/nvn/tools/romfs_list.py sizes 写出：每行「字节数\t相对路径」，普通文件、/ 分隔）。
        //   给了就不再枚举目录、逐个打开取长度（火纹 27 万文件约 20 秒）：仓库里 RomFS 目录遍历只在 romfs_list.py 一处（tools/romfs_walk_lint.py 守）。
        //   清单与目录同一时刻盘点（产物根里没有软链，roots.sh 拒收），集合与长度同 EnumerateFiles + OpenRead().Length；没给照旧现枚举（运行期 / 单测）。
        public static void Write(string romfsDir, string outPath, string listPath)
        {
            string root = Path.GetFullPath(romfsDir);
            List<string> rel = new();
            List<long> size = new();
            Dictionary<string, long> listed = null;

            if (listPath != null)
            {
                listed = new(StringComparer.Ordinal);

                foreach (string line in File.ReadLines(listPath, Encoding.UTF8))
                {
                    int tab = line.IndexOf('\t');

                    if (tab <= 0 || !long.TryParse(line.AsSpan(0, tab), out long n) || n < 0 || !listed.TryAdd(line[(tab + 1)..], n))
                    {
                        throw new InvalidDataException($"RomFS 索引：清单行不认识：{line}");
                    }
                }

                rel.AddRange(listed.Keys);
            }
            else
            {
                foreach (string f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
                {
                    if (IsHostJunk(f)) continue;
                    rel.Add(Path.GetRelativePath(root, f).Replace('\\', '/'));
                }
            }

            rel.Sort(StringComparer.Ordinal);
            RomFsBuilder builder = new();

            foreach (string r in rel)
            {
                long n;

                if (listed != null)
                {
                    n = listed[r];
                }
                else
                {
                    // Measure the same target that IndexedStorage/LazyHostFile reads.
                    using FileStream content = File.OpenRead(Path.Combine(root, r));
                    n = content.Length;
                }

                size.Add(n);
                builder.AddFile("/" + r, new SizeOnlyFile(n));
            }

            IStorage image = builder.Build();
            image.GetSize(out long total).ThrowIfFailure();
            RomFsFileSystem fs = new(image);
            long dataOffset = fs.Header.DataOffset;

            List<(long Off, long Len, int Idx)> files = new(rel.Count);

            for (int i = 0; i < rel.Count; i++)
            {
                if (!fs.FileTable.TryOpenFile("/" + rel[i], out RomFileInfo info) || info.Length != size[i])
                {
                    throw new InvalidDataException($"RomFS 索引：建出的镜像里找不到 /{rel[i]} 或长度不符");
                }

                // 零长度文件没有数据可读，不进区间表（它的偏移与下一个文件相同）
                if (info.Length > 0)
                {
                    files.Add((dataOffset + info.Offset, info.Length, i));
                }
            }

            files.Sort((a, b) => a.Off.CompareTo(b.Off));

            // 文件数据以外的区间：从镜像里读出（文件是只给长度的空文件，这些区间不含文件数据），全零的不存
            List<(long Off, byte[] Data)> segs = new();
            long pos = 0;

            void Gap(long from, long to)
            {
                const int Chunk = 1 << 20;

                for (long o = from; o < to; o += Chunk)
                {
                    byte[] b = new byte[(int)Math.Min(Chunk, to - o)];
                    image.Read(o, b).ThrowIfFailure();

                    if (Array.Exists(b, x => x != 0))
                    {
                        segs.Add((o, b));
                    }
                }
            }

            foreach ((long off, long len, _) in files)
            {
                if (off < pos)
                {
                    throw new InvalidDataException("RomFS 索引：文件区间重叠");
                }

                Gap(pos, off);
                pos = off + len;
            }

            Gap(pos, total);

            using BinaryWriter w = new(File.Create(outPath + ".tmp"));
            w.Write(Magic);
            w.Write(total);
            w.Write(files.Count);
            MemoryStream paths = new();

            foreach ((long off, long len, int idx) in files)
            {
                byte[] p = Encoding.UTF8.GetBytes(rel[idx]);
                w.Write(off);
                w.Write(len);
                w.Write((int)paths.Length);
                w.Write(p.Length);
                paths.Write(p);
            }

            w.Write((int)paths.Length);
            w.Write(paths.GetBuffer(), 0, (int)paths.Length);
            w.Write(segs.Count);

            foreach ((long off, byte[] data) in segs)
            {
                w.Write(off);
                w.Write(data.Length);
            }

            foreach ((_, byte[] data) in segs)
            {
                w.Write(data);
            }

            w.Close();
            File.Move(outPath + ".tmp", outPath, overwrite: true);
        }

        // IMG v1 的 RomFS 段（单一 IMG 方案，v0.3.0）：把 romfsDir 的真实文件建成 Switch 标准 RomFS（LibHac RomFsBuilder，与 hactool / nxdumptool 的 romfs.bin 同一种布局），
        //   写进 outPath 的 offset 处（文件须已存在；不落临时副本）。→ 写入的字节数。文件集合与排序同 Write（清单给了就不枚举目录）
        /// <summary>consume：边写边释放原件——某个文件的数据读到末尾（标准 RomFS 段按顺序整读、每个文件只读一遍）就关句柄、删掉它（#746：
        ///   v0.3.0 起写 game.img 时解包出来的 RomFS 和 IMG 同时在盘上，峰值多一整份游戏大小，256 GB 的 Mac 出不了 40 GB 级的游戏）。
        ///   只有出包写 IMG 用（pack/img.py convert --consume）；写到一半失败，原件已经删了一部分，调用方负责让这款下次重新解包</summary>
        public static long WriteStandard(string romfsDir, string listPath, string outPath, long offset, bool consume = false)
        {
            string root = Path.GetFullPath(romfsDir);
            List<string> rel = new();
            if (listPath != null)
            {
                foreach (string line in File.ReadLines(listPath, Encoding.UTF8))
                {
                    int tab = line.IndexOf('\t');
                    if (tab <= 0) throw new InvalidDataException($"RomFS 清单行不认识：{line}");
                    rel.Add(line[(tab + 1)..]);
                }
            }
            else
            {
                foreach (string f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
                    if (!IsHostJunk(f)) rel.Add(Path.GetRelativePath(root, f).Replace('\\', '/'));
            }
            rel.Sort(StringComparer.Ordinal);
            RomFsBuilder builder = new();
            // LazyHostFile：按需打开、句柄缓存（最多同时开 128 个）——9.9 万文件的游戏一次全开会超出文件句柄上限
            foreach (string r in rel)
            {
                string full = Path.Combine(root, r);
                long length = new FileInfo(full).Length;
                LazyHostFile file = new(full, length);
                builder.AddFile("/" + r, consume ? new ConsumingFile(file, full, length) : file);
            }
            IStorage image = builder.Build();
            image.GetSize(out long total).ThrowIfFailure();
            using (FileStream o = new(outPath, FileMode.Open, FileAccess.Write, FileShare.None, 1 << 20))
            {
                o.Position = offset;
                byte[] buf = new byte[1 << 22];
                for (long pos = 0; pos < total;)
                {
                    int n = (int)Math.Min(buf.Length, total - pos);
                    image.Read(pos, buf.AsSpan(0, n)).ThrowIfFailure();
                    o.Write(buf, 0, n); pos += n;
                }
            }
            LazyHostFile.CloseAll();
            return total;
        }

        /// <summary>WriteStandard consume 用：读到文件末尾就关句柄、去掉只读属性、删掉（长度 0 的文件不会被读到，留着，几乎不占空间）</summary>
        private sealed class ConsumingFile : IFile
        {
            private readonly LazyHostFile _inner;
            private readonly string _path;
            private readonly long _size;
            private bool _gone;

            public ConsumingFile(LazyHostFile inner, string path, long size)
            {
                _inner = inner;
                _path = path;
                _size = size;
            }

            protected override Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option)
            {
                Result rc = _inner.Read(out bytesRead, offset, destination, option);
                if (rc.IsSuccess() && !_gone && offset + bytesRead >= _size)
                {
                    _gone = true;
                    _inner.Release();
                    File.SetAttributes(_path, FileAttributes.Normal);
                    File.Delete(_path);
                }

                return rc;
            }

            protected override Result DoGetSize(out long size)
            {
                size = _size;
                return Result.Success;
            }

            protected override Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoFlush() => Result.Success;
            protected override Result DoSetSize(long size) => ResultFs.WriteUnpermitted.Value;

            protected override Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
                => ResultFs.NotImplemented.Value;
        }

        public static IStorage Open(string romfsDir, string indexPath, string overlayDir = null) =>
            new IndexedStorage(Path.GetFullPath(romfsDir), File.ReadAllBytes(indexPath), indexPath, OverlayFiles(overlayDir), null, null);

        // 单文件镜像（pack/romfs_image.py）：romfs.img + romfs.imgmap + 索引齐全且镜像长度对得上才用；没有或长度不符（推到一半）→ null，调用方退回目录布局或报红
        public static IStorage OpenImage(string programDir)
        {
            string image = Path.Combine(programDir, ImageName), map = Path.Combine(programDir, ImageMapName), index = Path.Combine(programDir, FileName);
            if (!File.Exists(image) || !File.Exists(map) || !File.Exists(index)) return null;
            byte[] raw = File.ReadAllBytes(map);
            if (raw.Length < 20 || !raw.AsSpan(0, 8).SequenceEqual(ImageMagic)) throw new InvalidDataException($"RomFS 镜像对照表格式不对：{map}");
            long length = BitConverter.ToInt64(raw, 8);
            int count = BitConverter.ToInt32(raw, 16);
            if (raw.Length != 20 + count * 8L) throw new InvalidDataException($"RomFS 镜像对照表长度不对：{map}");
            var handle = File.OpenHandle(image, FileMode.Open, FileAccess.Read, FileShare.Read, FileOptions.RandomAccess);
            if (RandomAccess.GetLength(handle) != length)
            {
                handle.Dispose();
                return null;
            }
            long[] offsets = new long[count];
            Buffer.BlockCopy(raw, 20, offsets, 0, count * 8);
            return new IndexedStorage(Path.GetFullPath(Path.Combine(programDir, "romfs")), File.ReadAllBytes(index), index,
                OverlayFiles(Path.Combine(programDir, ImageOverlayDir)), handle, offsets);
        }

        // 单一 IMG v1（pack/img.py，v0.3.0）：<程序目录>/game.img。头：0 "S2AIMG01" | 8 u32 格式号 | 96/104 RomFS 段偏移 / 长 | 112/120 目录表偏移 / 长 | 128 整个文件长。
        //   RomFS 段是 Switch 标准 RomFS，LibHac 原生读。没有界面覆盖层 → 直接交这段（零额外开销）；有覆盖层 → 按目录表里的 romfs.list 重建虚拟 RomFS，
        //   被覆盖的文件读覆盖层（同旧镜像的覆盖层语义）。文件不在 → null；长度不等于头里的整个文件长（推到一半）→ 旁边有 romfs/ 时 null（调用方退回读目录），
        //   没有就抛（资源没传完，起局失败、宿主说「请重新装到 iPhone」；审计 P1-170）；
        //   魔数 / 格式号不认识 → 抛（起局失败、说清原因，不读坏数据）。格式号只在布局真变时加一，新壳必须保留读旧号的分支
        public const string ImgName = "game.img";
        // IMG 旁的派生偏移表（pack/img.py convert 写）：格式同 romfs.imgmap（"S2ARIM01" | i64 镜像长 = game.img 整个文件长 | i32 条数 | 条数 × i64），
        //   按 romfs.s2aidx 的文件顺序给每个文件在 game.img 里的绝对偏移，-1 = 读界面覆盖层。和 romfs.s2aidx 一起在就走单文件镜像同一条预建路径（IndexedStorage），
        //   起局不重建 RomFS 目录表（11-11 真机对比：有覆盖层时 RomFsBuilder 重建约 10 万条目 138.6 ms，预建路径 7.9 ms）
        public const string ImgMapName = "game.imgmap";
        private static ReadOnlySpan<byte> ImgMagic => "S2AIMG01"u8;
        public static IStorage OpenImg(string programDir)
        {
            string path = Path.Combine(programDir, ImgName);
            if (!File.Exists(path)) return null;
            var h = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.Read, FileOptions.RandomAccess);
            byte[] hdr = new byte[136];
            if (RandomAccess.Read(h, hdr, 0) != hdr.Length || !hdr.AsSpan(0, 8).SequenceEqual(ImgMagic)) { h.Dispose(); throw new InvalidDataException($"不是 S2Arm 资源包 IMG：{path}"); }
            uint fmt = BitConverter.ToUInt32(hdr, 8);
            if (fmt != 1) { h.Dispose(); throw new InvalidDataException($"资源包 IMG 格式号 {fmt}，这个 S2Arm 只认 1：请更新 S2Arm（{path}）"); }
            long ro = BitConverter.ToInt64(hdr, 96), rl = BitConverter.ToInt64(hdr, 104), to = BitConverter.ToInt64(hdr, 112), tl = BitConverter.ToInt64(hdr, 120), total = BitConverter.ToInt64(hdr, 128);
            if (RandomAccess.GetLength(h) != total || rl <= 0)
            {
                long have = RandomAccess.GetLength(h); h.Dispose();
                // 推到一半（审计 P1-170）：旁边还有旧形态的 romfs/ 目录就退回读它（同单文件镜像不完整时）；没有就是资源确实没传完，
                //   物理上起不了：抛错让会话失败，宿主按事实归到「游戏文件缺失，请在电脑上重新装到 iPhone」（init_fail.c），不再报「缺 romfs/」后照样起空数据
                if (Directory.Exists(Path.Combine(programDir, "romfs"))) { Red.Report($"资源包 IMG 不完整（{have} / {total} 字节，多半推到一半），这局改读 romfs/ 目录", path); return null; }
                throw new InvalidDataException($"资源包 IMG 没传完（{have} / {total} 字节）：请在电脑上的 S2Arm 里对这款游戏重新「装到 iPhone」（{path}）");
            }
            Dictionary<string, string> overlay = OverlayFiles(Path.Combine(programDir, ImageOverlayDir));
            string map = Path.Combine(programDir, ImgMapName), index = Path.Combine(programDir, FileName);
            if (File.Exists(map) && File.Exists(index))
            {
                byte[] raw = File.ReadAllBytes(map);
                int count = raw.Length >= 20 ? BitConverter.ToInt32(raw, 16) : -1;
                if (count >= 0 && raw.AsSpan(0, 8).SequenceEqual(ImageMagic) && BitConverter.ToInt64(raw, 8) == total && raw.Length == 20 + count * 8L)
                {
                    long[] offsets = new long[count];
                    Buffer.BlockCopy(raw, 20, offsets, 0, count * 8);
                    return new IndexedStorage(Path.GetFullPath(Path.Combine(programDir, "romfs")), File.ReadAllBytes(index), index, overlay, h, offsets);
                }
                // 偏移表和这份 IMG 对不上（换过 IMG 没换表）：照下面现建，慢但对
            }
            IStorage romfs = new HandleRange(h, ro, rl);
            if (overlay == null) return romfs;
            byte[] list = ImgEntry(h, to, tl, "romfs.list") ?? throw new InvalidDataException($"资源包 IMG 缺 romfs.list，叠不了界面覆盖层：{path}");
            RomFsFileSystem fs = new(romfs);
            long data = fs.Header.DataOffset;
            RomFsBuilder builder = new();
            foreach (string rel in Encoding.UTF8.GetString(list).Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                if (overlay.TryGetValue(rel, out string over)) { builder.AddFile("/" + rel, new LazyHostFile(over, new FileInfo(over).Length)); continue; }
                if (!fs.FileTable.TryOpenFile("/" + rel, out RomFileInfo info)) throw new InvalidDataException($"资源包 IMG 的 RomFS 段里找不到 /{rel}（romfs.list 与段不符）：{path}");
                builder.AddFile("/" + rel, new RangeFile(romfs, data + info.Offset, info.Length));
            }
            return builder.Build();
        }

        // IMG 目录表里按名取一条（目录表只在起局时读一次、条目少，线性扫即可；按路径 O(1) 查的算法见 pack/img.py find）
        private static byte[] ImgEntry(Microsoft.Win32.SafeHandles.SafeFileHandle h, long to, long tl, string name)
        {
            byte[] t = new byte[tl]; RandomAccess.Read(h, t, to);
            int slots = BitConverter.ToInt32(t, 0), slot = 32, pbase = 8 + slots * slot;
            byte[] want = Encoding.UTF8.GetBytes(name);
            for (int i = 0; i < slots; i++)
            {
                int o = 8 + i * slot;
                if (BitConverter.ToUInt64(t, o) == 0) continue;
                long off = BitConverter.ToInt64(t, o + 8), len = BitConverter.ToInt64(t, o + 16);
                int po = BitConverter.ToInt32(t, o + 24), pl = BitConverter.ToInt32(t, o + 28);
                if (t.AsSpan(pbase + po, pl).SequenceEqual(want)) { byte[] b = new byte[len]; RandomAccess.Read(h, b, off); return b; }
            }
            return null;
        }

        // 文件句柄上的一段只读区间：RandomAccess 按偏移读，多线程安全、不经 FileStream 读位置（同 IndexedStorage 读镜像的做法）
        private sealed class HandleRange : IStorage
        {
            private readonly Microsoft.Win32.SafeHandles.SafeFileHandle _h; private readonly long _off, _len;
            public HandleRange(Microsoft.Win32.SafeHandles.SafeFileHandle h, long off, long len) { _h = h; _off = off; _len = len; }
            public override Result Read(long offset, Span<byte> destination)
            {
                if (offset < 0 || offset + destination.Length > _len) return ResultFs.OutOfRange.Value;
                for (int got = 0; got < destination.Length;)
                {
                    int n = RandomAccess.Read(_h, destination[got..], _off + offset + got);
                    if (n <= 0) return ResultFs.OutOfRange.Value;
                    got += n;
                }
                return Result.Success;
            }
            public override Result GetSize(out long size) { size = _len; return Result.Success; }
            public override Result Write(long offset, ReadOnlySpan<byte> source) => ResultFs.WriteUnpermitted.Value;
            public override Result Flush() => Result.Success;
            public override Result SetSize(long size) => ResultFs.WriteUnpermitted.Value;
            public override Result OperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer) => ResultFs.NotImplemented.Value;
        }

        // 存储上的一段当成只读文件（重建虚拟 RomFS 时，IMG 里没被覆盖的文件）
        private sealed class RangeFile : IFile
        {
            private readonly IStorage _s; private readonly long _off, _len;
            public RangeFile(IStorage s, long off, long len) { _s = s; _off = off; _len = len; }
            protected override Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option)
            {
                int n = (int)Math.Max(0, Math.Min(destination.Length, _len - offset));
                bytesRead = n;
                return n == 0 ? Result.Success : _s.Read(_off + offset, destination[..n]);
            }
            protected override Result DoGetSize(out long size) { size = _len; return Result.Success; }
            protected override Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoFlush() => Result.Success;
            protected override Result DoSetSize(long size) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer) => ResultFs.NotImplemented.Value;
        }

        public enum Source { Image, Directory, Missing }

        // 起局读哪份 RomFS（审计 P1-151）：镜像可用 → 镜像；镜像文件在却用不了（长度与对照表不符 = 推到一半，或对照表 / 索引缺）且没有 romfs/ 可退 →
        //   起局失败（与对照表魔数不对同一条：抛 InvalidDataException，会话回失败），不再只报红后带着空的游戏数据开局；有 romfs/ → 退回目录（调用方报红说明没用这份镜像）
        public static Source Decide(bool imageOpened, bool imageFileExists, bool romfsDirExists, string programDir)
        {
            if (imageOpened) return Source.Image;
            if (imageFileExists && !romfsDirExists)
                throw new InvalidDataException($"RomFS 单文件镜像不完整（长度与对照表不符或缺对照表 / 索引，多半推到一半），也没有 romfs/ 可退：{programDir}；请重新装到 iPhone");
            return romfsDirExists ? Source.Directory : Source.Missing;
        }

        // macOS 垃圾（同 pack/pack.py、graphics/nvn/tools/romfs_list.py）：不进资源包，也就不能进镜像，否则游戏枚举到就读不到
        internal static bool IsHostJunk(string path)
        {
            string name = Path.GetFileName(path);
            return name == ".DS_Store" || name.StartsWith("._", StringComparison.Ordinal);
        }

        // 界面布局覆盖层 <产物根>/ui_overlay/romfs/（Windows 编排 uilayout，pack/orch/stages.py）：读方覆盖层优先——
        //   同相对路径的文件读覆盖层那份（索引里的长度本就按覆盖层算）。只有几十个文件，起局一次盘点成表；没有覆盖层 → null
        internal static Dictionary<string, string> OverlayFiles(string overlayDir)
        {
            if (string.IsNullOrEmpty(overlayDir) || !Directory.Exists(overlayDir)) return null;
            string full = Path.GetFullPath(overlayDir);
            Dictionary<string, string> map = new(StringComparer.Ordinal);
            foreach (string f in Directory.EnumerateFiles(full, "*", SearchOption.AllDirectories))
            {
                if (IsHostJunk(f)) continue;
                map[Path.GetRelativePath(full, f).Replace('\\', '/')] = f;
            }
            return map.Count == 0 ? null : map;
        }

        // 镜像 = 有序区间表（文件 / 元数据段），区间之间是全零填充
        private sealed class IndexedStorage : IStorage
        {
            private readonly string _root;
            private readonly byte[] _idx;
            private readonly long _size;
            private readonly long[] _start;     // 各区间起点（升序）
            private readonly long[] _len;
            private readonly int[] _ref;        // ≥ 0：文件号；< 0：~段号
            private readonly int[] _pathOff, _pathLen;
            private readonly int _pathBase;
            private readonly int[] _segData;    // 段字节在 _idx 里的位置
            private readonly LazyHostFile[] _files;
            private readonly long[] _fileLen;

            private readonly Dictionary<string, string> _overlay;   // RomFS 相对路径 → 覆盖层文件（OverlayFiles），null = 无覆盖层
            private readonly Microsoft.Win32.SafeHandles.SafeFileHandle _image;   // 单文件镜像；null = 目录布局
            private readonly long[] _imageOffset;   // 文件号 → 镜像偏移，-1 = 在覆盖层

            public IndexedStorage(string root, byte[] idx, string where, Dictionary<string, string> overlay, Microsoft.Win32.SafeHandles.SafeFileHandle image, long[] imageOffset)
            {
                _root = root;
                _overlay = overlay;
                _image = image;
                _imageOffset = imageOffset;
                _idx = idx;

                if (idx.Length < 24 || !idx.AsSpan(0, 8).SequenceEqual(Magic))
                {
                    throw new InvalidDataException($"RomFS 索引格式不对：{where}");
                }

                int p = 8;
                _size = BitConverter.ToInt64(idx, p); p += 8;
                int nf = BitConverter.ToInt32(idx, p); p += 4;
                long[] fOff = new long[nf], fLen = new long[nf];
                _pathOff = new int[nf];
                _pathLen = new int[nf];

                for (int i = 0; i < nf; i++)
                {
                    fOff[i] = BitConverter.ToInt64(idx, p);
                    fLen[i] = BitConverter.ToInt64(idx, p + 8);
                    _pathOff[i] = BitConverter.ToInt32(idx, p + 16);
                    _pathLen[i] = BitConverter.ToInt32(idx, p + 20);
                    p += 24;
                }

                int pathBytes = BitConverter.ToInt32(idx, p); p += 4;
                _pathBase = p;
                p += pathBytes;
                int ns = BitConverter.ToInt32(idx, p); p += 4;
                long[] sOff = new long[ns];
                int[] sLen = new int[ns];

                for (int i = 0; i < ns; i++)
                {
                    sOff[i] = BitConverter.ToInt64(idx, p);
                    sLen[i] = BitConverter.ToInt32(idx, p + 8);
                    p += 12;
                }

                _segData = new int[ns];

                for (int i = 0; i < ns; i++)
                {
                    _segData[i] = p;
                    p += sLen[i];
                }

                // 合并成一张升序区间表（文件与段互不重叠，两表各自已升序）
                int n = nf + ns;
                _start = new long[n];
                _len = new long[n];
                _ref = new int[n];

                for (int i = 0, a = 0, b = 0; i < n; i++)
                {
                    if (b >= ns || (a < nf && fOff[a] < sOff[b]))
                    {
                        (_start[i], _len[i], _ref[i]) = (fOff[a], fLen[a], a);
                        a++;
                    }
                    else
                    {
                        (_start[i], _len[i], _ref[i]) = (sOff[b], sLen[b], ~b);
                        b++;
                    }
                }

                _files = new LazyHostFile[nf];
                _fileLen = fLen;

                if (imageOffset != null && imageOffset.Length != nf)
                {
                    throw new InvalidDataException($"RomFS 镜像对照表 {imageOffset.Length} 项，索引 {nf} 个文件：{where}");
                }
            }

            public override Result Read(long offset, Span<byte> destination)
            {
                if (offset < 0 || offset + destination.Length > _size)
                {
                    return ResultFs.OutOfRange.Value;
                }

                // 第一个可能相交的区间：起点 ≤ offset 的最后一个
                int i = Array.BinarySearch(_start, offset);
                i = i >= 0 ? i : Math.Max(0, ~i - 1);

                while (!destination.IsEmpty)
                {
                    if (i >= _start.Length || offset < _start[i])
                    {
                        // 区间之前（或之间）的填充
                        long next = i < _start.Length ? _start[i] : _size;
                        int z = (int)Math.Min(destination.Length, next - offset);
                        destination[..z].Clear();
                        destination = destination[z..];
                        offset += z;
                        continue;
                    }

                    long end = _start[i] + _len[i];

                    if (offset >= end)
                    {
                        i++;
                        continue;
                    }

                    int count = (int)Math.Min(destination.Length, end - offset);
                    long inner = offset - _start[i];

                    if (_ref[i] >= 0 && _image != null && _imageOffset[_ref[i]] >= 0)
                    {
                        // 读不满就是镜像被截短，回失败，不补零当完整（同下面目录布局）
                        long at = _imageOffset[_ref[i]] + inner;
                        Span<byte> left = destination[..count];

                        try
                        {
                            while (!left.IsEmpty)
                            {
                                int got = RandomAccess.Read(_image, left, at);
                                if (got <= 0) return ResultFs.HostFileDataCorrupted.Value;
                                left = left[got..];
                                at += got;
                            }
                        }
                        catch (IOException e) when (e.HResult == LazyHostFile.EFault)
                        {
                            // 目标是游戏内存、读盘期间页被写保护：内核往里写直接 EFAULT（#602：iPad 读 romfs.img「Bad address」→ 游戏 Break 退出）。
                            //   同目录布局（LazyHostFile）那条：剩下的部分先读进宿主中转缓冲、报一次写再拷
                            if (!LazyHostFile.ReadViaBounce(_image, left, at, "RomFS 镜像", out long got) || got != left.Length)
                                return ResultFs.HostFileDataCorrupted.Value;
                        }
                    }
                    else if (_ref[i] >= 0)
                    {
                        Result r = File(_ref[i], out LazyHostFile file);

                        if (r.IsSuccess())
                        {
                            r = file.Read(out long got, inner, destination[..count], ReadOption.None);

                            // 区间按索引长度划定：读不满就是宿主文件与镜像对不上（审计 #1534 P1-6），回失败，不补零当完整
                            if (r.IsSuccess() && got != count)
                            {
                                r = ResultFs.HostFileDataCorrupted.Value;
                            }
                        }

                        if (r.IsFailure())
                        {
                            return r;
                        }
                    }
                    else
                    {
                        _idx.AsSpan(_segData[~_ref[i]] + (int)inner, count).CopyTo(destination);
                    }

                    destination = destination[count..];
                    offset += count;
                    i++;
                }

                return Result.Success;
            }

            private Result File(int f, out LazyHostFile h)
            {
                h = _files[f];

                if (h == null)
                {
                    // 多个 IStorage 会话并发读（各自加锁，HleTarget）：只让一个新建的进表，输的那份丢掉（还没打开过，无句柄）
                    string rel = Encoding.UTF8.GetString(_idx, _pathBase + _pathOff[f], _pathLen[f]);
                    string full = Path.GetFullPath(Path.Combine(_root, rel));

                    // 拼完必须仍在 romfs/ 下（审计 #1534 P1-5）：索引被改成 ../ 或绝对路径就拒绝这次打开，
                    //   码同 LibHac 路径规范化里 .. 越过根（DirectoryUnobtainable）
                    if (!full.StartsWith(Path.TrimEndingDirectorySeparator(_root) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                    {
                        Red.Report("RomFS 索引里的路径走出游戏 romfs/，拒绝打开", $"{rel} → {full}");
                        return ResultFs.DirectoryUnobtainable.Value;
                    }

                    if (_overlay != null && _overlay.TryGetValue(rel, out string over)) full = over;

                    h = System.Threading.Interlocked.CompareExchange(ref _files[f], new LazyHostFile(full, _fileLen[f]), null) ?? _files[f];
                }

                return Result.Success;
            }

            public override void Dispose()
            {
                _image?.Dispose();
                base.Dispose();
            }

            public override Result GetSize(out long size)
            {
                size = _size;
                return Result.Success;
            }

            public override Result Write(long offset, ReadOnlySpan<byte> source) => ResultFs.WriteUnpermitted.Value;
            public override Result Flush() => Result.Success;
            public override Result SetSize(long size) => ResultFs.WriteUnpermitted.Value;

            public override Result OperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
                => ResultFs.NotImplemented.Value;
        }

        // 只给长度的文件（建镜像布局用，读出全零）
        private sealed class SizeOnlyFile : IFile
        {
            private readonly long _size;

            public SizeOnlyFile(long size) => _size = size;

            protected override Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option)
            {
                int n = (int)Math.Max(0, Math.Min(destination.Length, _size - offset));
                destination[..n].Clear();
                bytesRead = n;
                return Result.Success;
            }

            protected override Result DoGetSize(out long size)
            {
                size = _size;
                return Result.Success;
            }

            protected override Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoFlush() => Result.Success;
            protected override Result DoSetSize(long size) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
                => ResultFs.NotImplemented.Value;
        }
    }
}
