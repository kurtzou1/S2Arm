using System;
using System.Diagnostics;
using System.IO;

// 用法：romfs_index <游戏数据根> [--list <RomFS 清单>]   → 读 <根>/romfs/，写 <根>/romfs.s2aidx
//   --list：出包期由 graphics/nvn/tools/romfs_list.py sizes 写的清单（字节数\t相对路径），给了就不再枚举目录、逐个打开取长度
// 用法二：romfs_index --std <RomFS 目录> <清单或 -> <输出文件> <偏移> [--consume]   → 标准 RomFS 写进输出文件的偏移处（IMG v1 的 RomFS 段，pack/img.py 调），标准输出打印写入字节数
//   --consume：每个原件写进去就删掉（出包写 IMG 边写边释放解包，#746）
if ((args.Length == 5 || args.Length == 6 && args[5] == "--consume") && args[0] == "--std")
{
    long n = S2A.Services.RomFsIndex.WriteStandard(args[1], args[2] == "-" ? null : args[2], args[3], long.Parse(args[4]), args.Length == 6);
    if (S2A.Services.RomFsIndex.ConsumeSkipped > 0)   // 删不掉的留着（#793 / #796）：说一句，不算失败
        Console.Error.WriteLine($"🟡 边写边腾有 {S2A.Services.RomFsIndex.ConsumeSkipped} 个解包文件删不掉，留着照常写完（第一个：{S2A.Services.RomFsIndex.ConsumeFirstError}）；出包收尾再清，这次峰值多占它们的大小");
    Console.WriteLine(n);
    return 0;
}
if (!(args.Length == 1 || args.Length == 3 && args[1] == "--list") || !Directory.Exists(Path.Combine(args[0], "romfs")))
{
    Console.Error.WriteLine("用法：romfs_index <游戏数据根（含 romfs/）> [--list <RomFS 清单>]");
    return 2;
}

Stopwatch sw = Stopwatch.StartNew();
string outPath = Path.Combine(args[0], S2A.Services.RomFsIndex.FileName);
S2A.Services.RomFsIndex.Write(Path.Combine(args[0], "romfs"), outPath, args.Length == 3 ? args[2] : null);
Console.Error.WriteLine($"🟢 RomFS 索引 {outPath}：{new FileInfo(outPath).Length} 字节，用时 {sw.ElapsedMilliseconds} ms");
return 0;
