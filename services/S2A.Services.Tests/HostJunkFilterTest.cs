using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Tools.Fs;
using Ryujinx.HLE.FileSystem;
using System;
using System.Collections.Generic;
using System.Text;
using Path = LibHac.Fs.Path;

namespace S2A.Services.Tests
{
    // #914：库在 exFAT 上，宿主新建的文件带扩展属性，系统随手在旁边生成 ._<名> 附属文件（目录读出按创建顺序，附属文件排在本体后面）。
    //   LibHac 目录存档挂载时把已提交目录 0/ 拷成工作目录 1/：拷 x 时系统已生成 1/._x，再拷 0/._x 建 1/._x → PathAlreadyExists（2002-0002），
    //   存档挂不上、游戏 Break。下面的假文件系统按这条机理模拟附属文件；期望按机理手写：不套过滤层必撞、套上（S2AHostJunkFilterFileSystem）挂载 / 写 / 提交都成，
    //   客体看到的列表与条目数里都没有附属文件
    public static partial class Program
    {
        private sealed class SidecarFs : IFileSystem
        {
            private readonly IFileSystem _b;
            public SidecarFs(IFileSystem b) { _b = b; }
            private static bool Side(in Path p, out Path side)
            {
                string s = p.ToString(); int k = s.LastIndexOf('/'); string name = s[(k + 1)..];
                side = new Path();
                if (name.Length == 0 || name.StartsWith("._", StringComparison.Ordinal)) return false;
                side.InitializeWithNormalization(Encoding.UTF8.GetBytes(s[..(k + 1)] + "._" + name + "\0")).ThrowIfFailure();
                return true;
            }
            private void MakeSide(in Path p) { if (Side(in p, out Path s)) { using (s) { _b.GetEntryType(out _, in s).IsSuccess(); if (_b.GetEntryType(out _, in s).IsFailure()) _b.CreateFile(in s, 4096).IgnoreResult(); } } }
            private void DropSide(in Path p) { if (Side(in p, out Path s)) { using (s) { if (_b.GetEntryType(out _, in s).IsSuccess()) _b.DeleteFile(in s).IgnoreResult(); } } }
            private void MoveSide(in Path a, in Path b) { if (Side(in a, out Path sa) && Side(in b, out Path sb)) { using (sa) using (sb) { if (_b.GetEntryType(out _, in sa).IsSuccess()) _b.RenameFile(in sa, in sb).IgnoreResult(); } } }
            protected override Result DoCreateFile(ref readonly Path path, long size, CreateFileOptions option) { Result r = _b.CreateFile(in path, size, option); if (r.IsSuccess()) MakeSide(in path); return r; }
            protected override Result DoCreateDirectory(ref readonly Path path) { Result r = _b.CreateDirectory(in path); if (r.IsSuccess()) MakeSide(in path); return r; }
            protected override Result DoDeleteFile(ref readonly Path path) { Result r = _b.DeleteFile(in path); if (r.IsSuccess()) DropSide(in path); return r; }
            protected override Result DoDeleteDirectory(ref readonly Path path) { Result r = _b.DeleteDirectory(in path); if (r.IsSuccess()) DropSide(in path); return r; }
            protected override Result DoDeleteDirectoryRecursively(ref readonly Path path) { Result r = _b.DeleteDirectoryRecursively(in path); if (r.IsSuccess()) DropSide(in path); return r; }
            protected override Result DoCleanDirectoryRecursively(ref readonly Path path) => _b.CleanDirectoryRecursively(in path);
            protected override Result DoRenameFile(ref readonly Path a, ref readonly Path b) { Result r = _b.RenameFile(in a, in b); if (r.IsSuccess()) MoveSide(in a, in b); return r; }
            protected override Result DoRenameDirectory(ref readonly Path a, ref readonly Path b) { Result r = _b.RenameDirectory(in a, in b); if (r.IsSuccess()) MoveSide(in a, in b); return r; }
            protected override Result DoGetEntryType(out DirectoryEntryType t, ref readonly Path path) => _b.GetEntryType(out t, in path);
            protected override Result DoOpenFile(ref UniqueRef<IFile> f, ref readonly Path path, OpenMode mode) => _b.OpenFile(ref f, in path, mode);
            protected override Result DoCommit() => _b.Commit();
            protected override Result DoOpenDirectory(ref UniqueRef<IDirectory> outDirectory, ref readonly Path path, OpenDirectoryMode mode)
            {
                using var d = new UniqueRef<IDirectory>();
                Result r = _b.OpenDirectory(ref d.Ref, in path, mode); if (r.IsFailure()) return r;
                var all = new List<DirectoryEntry>(); var buf = new DirectoryEntry[8];
                while (true) { r = d.Get.Read(out long n, buf); if (r.IsFailure()) return r; if (n == 0) break; for (int i = 0; i < n; i++) all.Add(buf[i]); }
                all.Sort((x, y) => JunkName(x).CompareTo(JunkName(y)));   // 按创建顺序：附属文件在本体之后
                outDirectory.Reset(new ListDir(all));
                return Result.Success;
            }
            private static int JunkName(DirectoryEntry e) => S2AHostJunkFilterFileSystem.IsJunk(e.Name) ? 1 : 0;
        }

        private sealed class ListDir : IDirectory
        {
            private readonly List<DirectoryEntry> _e; private int _i;
            public ListDir(List<DirectoryEntry> e) { _e = e; }
            protected override Result DoRead(out long n, Span<DirectoryEntry> buf) { n = 0; while (n < buf.Length && _i < _e.Count) buf[(int)n++] = _e[_i++]; return Result.Success; }
            protected override Result DoGetEntryCount(out long n) { n = _e.Count; return Result.Success; }
        }

        private static string NameOf(DirectoryEntry e) { ReadOnlySpan<byte> n = e.Name; int z = n.IndexOf((byte)0); return Encoding.UTF8.GetString(z < 0 ? n : n[..z]); }

        private static Path P(string s) { var p = new Path(); p.InitializeWithNormalization(Encoding.UTF8.GetBytes(s + "\0")).ThrowIfFailure(); return p; }

        // 一份「从 exFAT 搬来的库」里的目录存档：已提交目录 0/ 里有 a.bin 和它的附属文件
        private static IFileSystem MovedSave()
        {
            var mem = new InMemoryFileSystem();
            foreach (string d in new[] { "/0" }) { using Path p = P(d); mem.CreateDirectory(in p).ThrowIfFailure(); }
            foreach (string f in new[] { "/0/a.bin", "/0/._a.bin", "/._0" }) { using Path p = P(f); mem.CreateFile(in p, 16).ThrowIfFailure(); }
            return new SidecarFs(mem);
        }

        private static List<string> Names(IFileSystem fs, string dir, out long count)
        {
            using Path p = P(dir); using var d = new UniqueRef<IDirectory>();
            fs.OpenDirectory(ref d.Ref, in p, OpenDirectoryMode.All).ThrowIfFailure();
            d.Get.GetEntryCount(out count).ThrowIfFailure();
            var names = new List<string>(); var buf = new DirectoryEntry[2];   // 小缓冲：过滤要跨多次读凑满
            while (true) { d.Get.Read(out long n, buf).ThrowIfFailure(); if (n == 0) break; for (int i = 0; i < n; i++) names.Add(NameOf(buf[i])); }
            names.Sort(StringComparer.Ordinal); return names;
        }

        [SoloTest("--host-junk-filter")]
        private static int HostJunkFilter()
        {
            int fail = 0;
            void Expect(string what, object want, object got) { bool ok = Equals(want, got); if (!ok) fail++; Console.WriteLine($"{(ok ? "✓" : "✗")} {what}：期望 {want} → 实际 {got}"); }

            foreach (var (name, junk) in new[] { ("._a.bin", true), ("._", true), (".DS_Store", true), ("desktop.ini", true), ("Thumbs.db", true), ("a.bin", false), (".lock", false), ("_", false), (".DS_Store2", false) })
                Expect($"IsJunk({name})", junk, S2AHostJunkFilterFileSystem.IsJunk(Encoding.UTF8.GetBytes(name + "\0")));

            using (var raw = new DirectorySaveDataFileSystem(MovedSave(), null))
                Expect("不套过滤层：目录存档挂载（0/ 拷成 1/）", ResultFs.PathAlreadyExists.Value.ToStringWithName(), raw.Initialize(true, false, true, null, null).ToStringWithName());

            IFileSystem moved = MovedSave(), filtered = new S2AHostJunkFilterFileSystem(moved);
            using (var save = new DirectorySaveDataFileSystem(filtered, null))
            {
                Expect("套过滤层：挂载", Result.Success.ToStringWithName(), save.Initialize(true, false, true, null, null).ToStringWithName());
                using (Path f = P("/b.bin")) Expect("套过滤层：写新文件", Result.Success.ToStringWithName(), save.CreateFile(in f, 8).ToStringWithName());
                Expect("套过滤层：提交（1/ 拷回 0/）", Result.Success.ToStringWithName(), save.Commit().ToStringWithName());
            }
            Expect("客体看到的 0/", "a.bin,b.bin", string.Join(",", Names(filtered, "/0", out long c0)));
            Expect("客体看到的 0/ 条目数", 2L, c0);
            Expect("宿主上 0/ 照样有附属文件（只是不给客体看）", true, Names(moved, "/0", out _).Contains("._a.bin"));
            Expect("客体看到的根目录不含 ._0", false, Names(filtered, "/", out _).Contains("._0"));
            Console.WriteLine($"host-junk-filter：{(fail == 0 ? "全过" : $"{fail} 项不符")}");
            return fail == 0 ? 0 : 1;
        }
    }
}
