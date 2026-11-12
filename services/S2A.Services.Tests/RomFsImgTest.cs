// SPDX-License-Identifier: Apache-2.0
// 单一 IMG v1（pack/img.py 的布局，RomFsIndex.OpenImg）：服务层从 game.img 读 RomFS。夹具现造，期望 = 夹具文件本身（逐字节比）：
//   ① 没有界面覆盖层：OpenImg 交出标准 RomFS 段，LibHac RomFsFileSystem 逐文件读回与源目录相同
//   ② 有覆盖层（romfs_overlay/a/s.txt）：读到覆盖层那份（长度不同也行），其余文件仍读 IMG
//   ③ 文件长度不等于头里的整个文件长（推到一半）→ 没有 romfs/ 时抛、有 romfs/ 时 null（审计 P1-170）；④ 格式号 2 → 抛（起局失败、说清要更新 S2Arm）
//   ⑤ 旁边有 game.imgmap + romfs.s2aidx（pack/img.py convert 写）→ 走单文件镜像同一条预建路径（IndexedStorage，不重建目录表）：覆盖层文件读覆盖版、其余读 IMG 原件；
//      偏移表记的镜像长与 game.img 不符（过期）→ 退回现建，读出的内容照样对
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Path = System.IO.Path;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.FsSystem.RomFs;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // IMG v1 夹具（同 pack/img.py：头一页 + 标准 RomFS 段 + romfs.list 一条 + 目录表）
        static void WriteImgFixture(string romDir, string imgPath, uint format, IReadOnlyList<string> rels)
        {
            const int page = 16384;
            File.WriteAllBytes(imgPath, new byte[page]);
            long rl = RomFsIndex.WriteStandard(romDir, null, imgPath, page);
            byte[] list = Encoding.UTF8.GetBytes(string.Join("", System.Linq.Enumerable.Select(rels, r => r + "\n")));
            long lo = (page + rl + page - 1) / page * page;
            long to = (lo + list.Length + page - 1) / page * page;
            byte[] name = Encoding.UTF8.GetBytes("romfs.list");
            using (FileStream f = new(imgPath, FileMode.Open, FileAccess.Write))
            {
                f.Position = lo; f.Write(list);
                // 目录表：2 个槽，槽 0 放 romfs.list（哈希值只要非 0；服务层按名线性扫）
                using BinaryWriter w = new(f, Encoding.UTF8, leaveOpen: true);
                f.Position = to;
                w.Write(2); w.Write(1);
                w.Write(1UL); w.Write(lo); w.Write((long)list.Length); w.Write(0); w.Write(name.Length);
                w.Write(new byte[32]);
                w.Write(name);
                long tl = f.Position - to, total = f.Position;
                f.Position = 0;
                w.Write("S2AIMG01"u8.ToArray()); w.Write(format); w.Write(0u); w.Write(Encoding.ASCII.GetBytes("0100ABCD00000000")); w.Write(new byte[64]);
                w.Write((long)page); w.Write(rl); w.Write(to); w.Write(tl); w.Write(total);
            }
        }

        static byte[] ReadRom(LibHac.Fs.IStorage s, string path)
        {
            RomFsFileSystem fs = new(s);
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            f.Get.GetSize(out long n).ThrowIfFailure();
            byte[] b = new byte[n];
            f.Get.Read(out long got, 0, b).ThrowIfFailure();
            return b;
        }

        [SoloTest("--romfs-img")]
        private static int RomFsImgTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_romfs_img_{Environment.ProcessId}");
            if (Directory.Exists(root)) Directory.Delete(root, true);
            string rom = Path.Combine(root, "src", "romfs"), game = Path.Combine(root, "game");
            Directory.CreateDirectory(Path.Combine(rom, "a")); Directory.CreateDirectory(game);
            Random rnd = new(7);
            byte[] big = new byte[70000]; rnd.NextBytes(big);
            var files = new Dictionary<string, byte[]> { ["a/big.bin"] = big, ["a/s.txt"] = "hello"u8.ToArray(), ["top.dat"] = new byte[] { 1, 2, 3 } };
            foreach (var kv in files) File.WriteAllBytes(Path.Combine(rom, kv.Key), kv.Value);
            var rels = new List<string>(files.Keys); rels.Sort(StringComparer.Ordinal);
            string img = Path.Combine(game, RomFsIndex.ImgName);
            int bad = 0;
            void Ck(bool ok, string what) { Console.WriteLine($"{(ok ? "✓" : "✗")} {what}"); if (!ok) bad++; }
            try
            {
                WriteImgFixture(rom, img, 1, rels);
                var s1 = RomFsIndex.OpenImg(game);
                bool all = s1 != null; foreach (var kv in files) all &= s1 != null && ReadRom(s1, "/" + kv.Key).AsSpan().SequenceEqual(kv.Value);
                Ck(all, "① 没有覆盖层：标准 RomFS 段逐文件读回与源目录相同");
                Directory.CreateDirectory(Path.Combine(game, RomFsIndex.ImageOverlayDir, "a"));
                File.WriteAllBytes(Path.Combine(game, RomFsIndex.ImageOverlayDir, "a", "s.txt"), "overlay!!"u8.ToArray());
                var s2 = RomFsIndex.OpenImg(game);
                Ck(s2 != null && Encoding.UTF8.GetString(ReadRom(s2, "/a/s.txt")) == "overlay!!" && ReadRom(s2, "/a/big.bin").AsSpan().SequenceEqual(big),
                    "② 有覆盖层：a/s.txt 读覆盖层那份（长度不同），a/big.bin 仍读 IMG");
                Directory.Delete(Path.Combine(game, RomFsIndex.ImageOverlayDir), true);
                using (FileStream f = new(img, FileMode.Append)) f.WriteByte(0);
                // 审计 P1-170：长度不符、旁边没有 romfs/ → 抛（资源没传完，起局失败，宿主说「请重新装到 iPhone」）；有 romfs/ → null（退回读目录）
                string why3 = null; try { RomFsIndex.OpenImg(game); } catch (InvalidDataException e) { why3 = e.Message; }
                Ck(why3 != null && why3.Contains("没传完"), $"③ 长度与头里的整个文件长不符（推到一半）、没有 romfs/ → 抛：{why3}");
                bool hadRomfs = Directory.Exists(Path.Combine(game, "romfs")); Directory.CreateDirectory(Path.Combine(game, "romfs"));
                Ck(RomFsIndex.OpenImg(game) == null, "③b 长度不符、旁边有 romfs/ → null（退回读目录）");
                if (!hadRomfs) Directory.Delete(Path.Combine(game, "romfs"));
                string game2 = Path.Combine(root, "game2"); Directory.CreateDirectory(game2);   // 前面打开的句柄只许读，格式号 2 的夹具另放一个目录
                WriteImgFixture(rom, Path.Combine(game2, RomFsIndex.ImgName), 2, rels);
                string why = null; try { RomFsIndex.OpenImg(game2); } catch (InvalidDataException e) { why = e.Message; }
                Ck(why != null && why.Contains("格式号 2"), $"④ 格式号 2 → 抛：{why}");
                // ⑤ 预建偏移表：IMG 是原件，索引建在覆盖后的 romfs 上
                string game3 = Path.Combine(root, "game3"), patched = Path.Combine(root, "patched", "romfs"); Directory.CreateDirectory(game3);
                string img3 = Path.Combine(game3, RomFsIndex.ImgName); WriteImgFixture(rom, img3, 1, rels);
                foreach (var kv in files) { Directory.CreateDirectory(Path.GetDirectoryName(Path.Combine(patched, kv.Key))); File.WriteAllBytes(Path.Combine(patched, kv.Key), kv.Value); }
                File.WriteAllBytes(Path.Combine(patched, "a", "s.txt"), "overlay!!"u8.ToArray());
                RomFsIndex.Write(patched, Path.Combine(game3, RomFsIndex.FileName));
                Directory.CreateDirectory(Path.Combine(game3, RomFsIndex.ImageOverlayDir, "a"));
                File.WriteAllBytes(Path.Combine(game3, RomFsIndex.ImageOverlayDir, "a", "s.txt"), "overlay!!"u8.ToArray());
                byte[] idx = File.ReadAllBytes(Path.Combine(game3, RomFsIndex.FileName));   // "S2ARFS01" | i64 | i32 n | n × {i64,i64,i32 po,i32 pl} | i32 | 路径区
                int n = BitConverter.ToInt32(idx, 16), pathBase = 20 + n * 24 + 4;
                long total3 = new FileInfo(img3).Length;
                byte[] hdr = new byte[136]; using (var fh = File.OpenRead(img3)) fh.ReadExactly(hdr);
                long ro = BitConverter.ToInt64(hdr, 96), rl = BitConverter.ToInt64(hdr, 104);
                long[] offs = new long[n];
                using (var fs3 = File.OpenRead(img3))
                {
                    byte[] seg = new byte[rl]; fs3.Position = ro; fs3.ReadExactly(seg);
                    RomFsFileSystem rfs = new(new MemoryStorage(seg));
                    for (int i = 0; i < n; i++)
                    {
                        int po = BitConverter.ToInt32(idx, 20 + i * 24 + 16), pl = BitConverter.ToInt32(idx, 20 + i * 24 + 20);
                        string rel = Encoding.UTF8.GetString(idx, pathBase + po, pl);
                        if (rel == "a/s.txt") { offs[i] = -1; continue; }
                        rfs.FileTable.TryOpenFile("/" + rel, out RomFileInfo info);
                        offs[i] = ro + rfs.Header.DataOffset + info.Offset;
                    }
                }
                void WriteMap(long len)
                {
                    using var w = new BinaryWriter(File.Create(Path.Combine(game3, RomFsIndex.ImgMapName)));
                    w.Write("S2ARIM01"u8.ToArray()); w.Write(len); w.Write(n); foreach (long o in offs) w.Write(o);
                }
                WriteMap(total3);
                var s5 = RomFsIndex.OpenImg(game3);
                bool right5 = s5 != null && Encoding.UTF8.GetString(ReadRom(s5, "/a/s.txt")) == "overlay!!" && ReadRom(s5, "/a/big.bin").AsSpan().SequenceEqual(big)
                              && ReadRom(s5, "/top.dat").AsSpan().SequenceEqual(files["top.dat"]);
                Ck(s5?.GetType().Name == "IndexedStorage" && right5, $"⑤ 有 game.imgmap + romfs.s2aidx → 预建路径（{s5?.GetType().Name}），覆盖层读覆盖版、其余读 IMG 原件");
                WriteMap(total3 + 1);
                var s6 = RomFsIndex.OpenImg(game3);
                Ck(s6 != null && s6.GetType().Name != "IndexedStorage" && Encoding.UTF8.GetString(ReadRom(s6, "/a/s.txt")) == "overlay!!" && ReadRom(s6, "/a/big.bin").AsSpan().SequenceEqual(big),
                   $"⑤ 偏移表过期（镜像长不符）→ 退回现建（{s6?.GetType().Name}），内容照样对");
            }
            finally { Directory.Delete(root, true); }
            Console.WriteLine($"{(bad == 0 ? "✓" : "✗")} RomFS 单一 IMG：{bad} 项不符");
            return bad == 0 ? 0 : 1;
        }
    }
}
