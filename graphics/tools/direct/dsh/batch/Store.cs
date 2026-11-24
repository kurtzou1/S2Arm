// 内容寻址缓存仓（11-24 从 Build.cs 原样挪出）：苹果整份直连出库（dsh_batch，翻译产物 xl/、Metal 库 mtl/）与安卓离线 Vulkan 库（dsh_vklib，逐键产物 vk/）共用这一份实现。
//   两边各自的工程把本文件编进来（dsh_batch 按目录收，dsh_vklib 在工程文件里点名引），仓根同为 <缓存根>/store/dshb，键前缀分开。
//   本文件只管怎么存取，不决定产物内容，不进翻译器指纹（S2A.Dsh 的 DshXfpInput）与 Vulkan 侧指纹（VkFp）。
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

/// <summary>内容寻址仓（翻译产物 xl/、Metal 库 mtl/）：一条一个文件，按摘要前两位分目录，写入先临时文件再改名；整份出库收尾只留本次用到的（同原 dmsh_store compact）</summary>
static class Store
{
    static string Root; static readonly ConcurrentDictionary<string, byte> Used = new();
    public static void Open(string root) { Root = root; Directory.CreateDirectory(root); }
    static string PathOf(string key) { var h = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant(); return Path.Combine(Root, h[..2], h + ".e"); }
    public static bool Exists(string key) { var p = PathOf(key); if (!File.Exists(p)) return false; Used[p] = 0; return true; }
    public static Dictionary<string, byte[]> Get(string key)
    {
        var p = PathOf(key); Used[p] = 0;
        byte[] d; try { d = File.ReadAllBytes(p); } catch (IOException) { return null; } catch (UnauthorizedAccessException) { return null; }
        try
        {
            // 落盘格式 DSZ1 + zlib(DSE1 整串，含末尾校验)：不是 DSZ1 的（旧未压缩条目）当没有、重新翻译（11-08 维护者：不留兼容读法）
            if (d.Length < 4 || Encoding.ASCII.GetString(d, 0, 4) != "DSZ1") return null;
            using (var zs = new ZLibStream(new MemoryStream(d, 4, d.Length - 4), CompressionMode.Decompress)) using (var ms = new MemoryStream()) { zs.CopyTo(ms); d = ms.ToArray(); }
            var o = new Dictionary<string, byte[]>(StringComparer.Ordinal); int i = 0;
            int Int() { int v = BitConverter.ToInt32(d, i); i += 4; return v; }
            var magic = Encoding.ASCII.GetString(d, 0, 4); i = 4; if (magic != "DSE1") return null;
            int n = Int();
            for (int k = 0; k < n; k++) { int nl = Int(); var name = Encoding.UTF8.GetString(d, i, nl); i += nl; int bl = Int(); o[name] = d[i..(i + bl)]; i += bl; }
            var want = Encoding.UTF8.GetString(d, i, d.Length - i - 32); i = d.Length - 32;
            if (want != key || !SHA256.HashData(d.AsSpan(0, d.Length - 32)).SequenceEqual(d[(d.Length - 32)..])) return null;   // 键核对 + 整条校验：坏了当没有
            return o;
        }
        catch { return null; }
    }
    public static void Put(string key, Dictionary<string, byte[]> files)
    {
        var p = PathOf(key); Used[p] = 0; Directory.CreateDirectory(Path.GetDirectoryName(p));
        var tmp = p + $".tmp{Environment.ProcessId}.{Environment.CurrentManagedThreadId}";
        // 边写边算校验（同一串字节：DSE1、项数、逐项 名长 名 字节长 字节、键，末尾 32 字节 sha256）：原先拼进 MemoryStream 再 ToArray 整块复制，大库每次多一份大对象
        // 11-08 整条压缩（维护者）：文件 = 「DSZ1」+ zlib(上面那串)。巫师3 直连缓存 125.5 GB 里约 89% 是 MSL 明文（_b / _b.plain / _bv 三种变体各存整份，只差几百字节），
        //   抽样两条实测 deflate 压到 6% / 13%；只出包机读写这个仓（dsh_batch），设备端 App 不含本类
        using (var fs = File.Create(tmp))
        using (var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        {
            fs.Write("DSZ1"u8);
            using var zs = new ZLibStream(fs, CompressionLevel.Optimal, leaveOpen: true);
            void W(ReadOnlySpan<byte> b) { zs.Write(b); h.AppendData(b); }
            void I(int v) { Span<byte> b = stackalloc byte[4]; BitConverter.TryWriteBytes(b, v); W(b); }
            W("DSE1"u8); I(files.Count);
            foreach (var (n, b) in files.OrderBy(x => x.Key, StringComparer.Ordinal)) { var nb = Encoding.UTF8.GetBytes(n); I(nb.Length); W(nb); I(b.Length); W(b); }
            W(Encoding.UTF8.GetBytes(key));
            zs.Write(h.GetHashAndReset());
        }
        // 11-05 Windows 出包机极品飞车：同仓并发出包（多单 / 本单多线程编到同一键），Windows 覆盖改名撞上目标正被别人读或替换 → UnauthorizedAccessException，整单出库失败。
        //   仓按键寻址：目标已有一条键对、校验过的条目就是别人先写成了，丢掉自己这份；还没有就稍等重试，三次仍不行照抛（真权限 / 盘问题不吞）
        for (int attempt = 1; ; attempt++)
        {
            try { File.Move(tmp, p, true); return; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                if (Get(key) != null) { try { File.Delete(tmp); } catch { } return; }
                if (attempt == 3) { try { File.Delete(tmp); } catch { } throw; }
                System.Threading.Thread.Sleep(200 * attempt);
            }
        }
    }
    // 整理：只收旧 Python 仓、给本次用到的条目刷新修改时间（早于一天才刷，命中不改写条目），不删任何条目——淘汰按容量预算 LRU 另做：
    //   开发机 tools/gc.sh → tools/direct_cache_lru.py（cache/direct 下全部款合计超 S2A_DIRECT_CACHE_BUDGET_GB 才按修改时间删最久没用的，在跑的款不动），
    //   玩家机 pack/jobs/cache_retention.py（盘紧才淘汰冷条目）。11-02 出包线：原先「本次没用到的全删」，同款在两棵树 / 两个提交 / iOS 与 Mac 间交替出包时互删
    //   （马力欧派对 16:40 一单删 66359 条）；维护者「存储换时间」：放 2T、超预算才按最久没用淘汰
    public static (int Kept, int Dropped) Compact()
    {
        int kept = 0, dropped = 0;
        var now = DateTime.UtcNow;
        // 旧 Python 仓（dmsh_store.py）留在同一仓根的 256 个分片 NN.pack 与 .inuse：新仓不读，不删就永远占盘（全部款约 65 GB），首次整理时收掉
        foreach (var f in Directory.EnumerateFiles(Root))
        {
            var n = Path.GetFileName(f);
            if (n == ".inuse" || System.Text.RegularExpressions.Regex.IsMatch(n, @"\A[0-9a-f]{2}\.pack\z")) { try { File.Delete(f); dropped++; } catch { } }
        }
        foreach (var f in Directory.EnumerateFiles(Root, "*.e", SearchOption.AllDirectories))
        {
            kept++;
            if (Used.ContainsKey(f)) try { if (File.GetLastWriteTimeUtc(f) < now.AddDays(-1)) File.SetLastWriteTimeUtc(f, now); } catch { }   // LRU 的「最近用过」：早于一天才刷，命中不改写条目（t_dmsh_reuse ②）
        }
        return (kept, dropped);
    }
}

/// <summary>出库工具里原生库 / 可执行文件的功能身份（苹果 dsh_batch 的 --dsx / --spvc 与安卓 dsh_vklib 的 --dsx / --spirv-cross 进缓存键用同一种算法）</summary>
static class ToolLib
{
    // libdsx / spvc 动态库的功能身份：Mach-O 各节内容（段名 / 节名 / 长度 / 字节）的 sha256，不含文件头与加载命令（LC_UUID）、__LINKEDIT（符号表、调试映射、签名）。
    //   11-02 出包线：原先整文件哈希，libnxgal（11-08 前直连库即它）构建不可复现——clang 一步编译加链接时调试映射记的临时目标文件名是随机的（/var/folders/…/T/gal_core-bb1480.o），
    //   UUID、签名随之变，代码段逐字节相同；每换一棵工作树 / 重编一次，全部着色器的翻译键作废（马力欧派对 82790 支 hit 0、冷翻 784 秒）。
    //   不是 64 位 Mach-O（Linux 的 libdsx.so）照旧整文件
    internal static string Fp(string path)
    {
        var b = File.ReadAllBytes(path);
        if (b.Length < 32 || BitConverter.ToUInt32(b, 0) != 0xfeedfacf) return Convert.ToHexString(SHA256.HashData(b)).ToLowerInvariant();
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        h.AppendData(Encoding.UTF8.GetBytes("macho-sections 1\0"));
        int ncmds = BitConverter.ToInt32(b, 16), o = 32;
        for (int i = 0; i < ncmds; i++)
        {
            int cmd = BitConverter.ToInt32(b, o), size = BitConverter.ToInt32(b, o + 4);
            if (cmd == 0x19)   // LC_SEGMENT_64：段头 72 字节后接 nsects 个 80 字节的节头
            {
                int nsects = BitConverter.ToInt32(b, o + 64);
                for (int k = 0; k < nsects; k++)
                {
                    int sh = o + 72 + 80 * k;
                    string sect = Encoding.UTF8.GetString(b, sh, 16).TrimEnd('\0'), seg = Encoding.UTF8.GetString(b, sh + 16, 16).TrimEnd('\0');
                    long len = BitConverter.ToInt64(b, sh + 40); int off = BitConverter.ToInt32(b, sh + 48), flags = BitConverter.ToInt32(b, sh + 64);
                    h.AppendData(Encoding.UTF8.GetBytes($"{seg},{sect},{len}\0"));
                    if ((flags & 0xff) is 0x1 or 0xc or 0x12 || off == 0) continue;   // 零填充节（S_ZEROFILL / S_GB_ZEROFILL / S_THREAD_LOCAL_ZEROFILL）文件里没有内容
                    h.AppendData(b, off, (int)len);
                }
            }
            o += size;
        }
        return Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant();
    }
}
