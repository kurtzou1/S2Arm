using Ryujinx.Graphics.Gpu.Shader.HashTable;
using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 着色器客体代码查找表（Ryujinx PartitionedHashTable）：按「存的代码是内存里那段代码的前缀」找，内存长度未知。
    //   期望全部按构造算：每条代码放进「代码 + 随机尾巴」的内存里都该找回自己（同一个数组）；改末字节 / 截短都找不到；同内容二次登记回原条目；
    //   常驻：上游每个尺寸表都给所有更长的代码存一条「部分」条目，条目数 ≈ 代码数 × 不同尺寸数 / 2（本例约 100 万条、每条 ≥ 24 B，≥ 24 MB）；
    //   只在 2 的幂检查点存部分条目后 ≈ 代码数 × log2(最长 / 128)（本例 ≤ 2050 × 6 ≈ 1.2 万条），上限给 4 MB。
    public static class ShaderCodeTableTest
    {
        private sealed class MemAccessor : IDataAccessor
        {
            private readonly byte[] _mem;
            public MemAccessor(byte[] mem) => _mem = mem;
            public ReadOnlySpan<byte> GetSpan(int offset, int length) => _mem.AsSpan(offset, Math.Min(length, _mem.Length - offset));
        }

        public static void Run(Action<string, object, object> check)
        {
            Random rng = new(1);
            List<byte[]> codes = new();

            // 2000 条随机代码，尺寸 64 B … 8 KB、8 字节对齐、约 1000 种
            for (int i = 0; i < 2000; i++)
            {
                byte[] c = new byte[8 * (8 + (i * 7919) % 1017)];
                rng.NextBytes(c);
                codes.Add(c);
            }

            // 两族共前缀的代码：前 4096 B（正好落在检查点上）/ 前 300 B（不在检查点上）相同，之后第一个字节各不相同
            foreach (int shared in new[] { 4096, 300 })
            {
                byte[] prefix = new byte[shared];
                rng.NextBytes(prefix);

                for (int k = 0; k < 25; k++)
                {
                    byte[] c = new byte[shared + 8 * (1 + k * 13)];
                    rng.NextBytes(c);
                    prefix.CopyTo(c, 0);
                    c[shared] = (byte)k;
                    codes.Add(c);
                }
            }

            long before = GC.GetTotalMemory(true);
            PartitionedHashTable<int> table = new();

            for (int i = 0; i < codes.Count; i++)
            {
                table.Add(codes[i], i);
            }

            long retained = GC.GetTotalMemory(true) - before;
            GC.KeepAlive(table);

            int hit = 0, falseHit = 0, truncHit = 0;

            for (int i = 0; i < codes.Count; i++)
            {
                byte[] c = codes[i];
                byte[] tail = new byte[4096];
                rng.NextBytes(tail);

                byte[] mem = new byte[c.Length + tail.Length];
                c.CopyTo(mem, 0);
                tail.CopyTo(mem, c.Length);

                if (table.TryFindItem(new MemAccessor(mem), out int id, out byte[] data) && id == i && ReferenceEquals(data, c))
                {
                    hit++;
                }

                mem[c.Length - 1] ^= 0x5A;
                falseHit += table.TryFindItem(new MemAccessor(mem), out _, out _) ? 1 : 0;

                truncHit += table.TryFindItem(new MemAccessor(c.AsSpan(0, c.Length - 8).ToArray()), out _, out _) ? 1 : 0;
            }

            int n = codes.Count;
            check("着色器代码表：每条代码 + 随机尾巴的内存找回自己（同一数组）", $"{n} / {n}", $"{hit} / {n}");
            check("着色器代码表：末字节改掉找不到", $"0 / {n}", $"{falseHit} / {n}");
            check("着色器代码表：内存比代码短 8 B 找不到", $"0 / {n}", $"{truncHit} / {n}");
            check("着色器代码表：同内容新数组再登记回原条目", 7, table.GetOrAdd((byte[])codes[7].Clone(), 99999));
            check($"着色器代码表：{n} 条、约 1000 种尺寸的常驻 ≤ 4 MB（上游每尺寸存部分条目 ≥ 24 MB）", "≤ 4 MB", retained <= 4L << 20 ? "≤ 4 MB" : $"{retained / 1048576.0:F1} MB");
        }
    }
}

namespace S2A.Services.Tests
{
    // 着色器代码表新旧差分对拍（10-21 维护者：整体重写要证明与上游等价）：真实语料 = 产物根里 Ryujinx 磁盘缓存的全部客体代码（guest.toc / guest.data），
    //   同时灌进新表（Ryujinx 树内）与上游原版副本（UpstreamHashTable/），逐样本比 TryFindItem：是否命中、命中哪一项、命中数据长度。
    //   另用暴力判据（按前 64 字节分组后逐条比字节，不经两张表）算「内存里能匹配的已存代码集合」，三方比：真实语料轮新表 = 上游 = 暴力；
    //   造前缀对轮（A 是 B 的前缀）新表 = 暴力且取最长，上游在这类样本上会漏报（二分落到 B 的部分条目后找不回 A），只报数。
    //   语料目录：S2A_SHCODE_CORPUS（冒号分隔的 shcache/<程序号> 目录），缺省01006F8002326000 + 一款第一方动作冒险游戏现行产物根；目录不在就报「无语料」（行里看得见，不会静默变绿）。
    public static class ShaderCodeTableDiffTest
    {
        private sealed class MemAccessor : Ryujinx.Graphics.Gpu.Shader.HashTable.IDataAccessor
        {
            private readonly byte[] _mem;
            public MemAccessor(byte[] mem) => _mem = mem;
            public ReadOnlySpan<byte> GetSpan(int offset, int length) => _mem.AsSpan(offset, Math.Min(length, _mem.Length - offset));
        }

        private static List<byte[]> ReadCorpus(string dir)
        {
            byte[] toc = System.IO.File.ReadAllBytes(System.IO.Path.Combine(dir, "guest.toc"));
            using System.IO.FileStream data = System.IO.File.OpenRead(System.IO.Path.Combine(dir, "guest.data"));
            List<byte[]> codes = new();

            for (int at = 32; at + 16 <= toc.Length; at += 16)
            {
                uint offset = BitConverter.ToUInt32(toc, at), codeSize = BitConverter.ToUInt32(toc, at + 4), cb1Size = BitConverter.ToUInt32(toc, at + 8);
                byte[] code = new byte[codeSize];
                data.Seek(offset + cb1Size, System.IO.SeekOrigin.Begin);
                int alg = data.ReadByte();
                System.IO.Stream s = alg switch
                {
                    0 => data,
                    1 => new System.IO.Compression.DeflateStream(data, System.IO.Compression.CompressionMode.Decompress, true),
                    2 => new System.IO.Compression.BrotliStream(data, System.IO.Compression.CompressionMode.Decompress, true),
                    _ => throw new System.IO.InvalidDataException($"压缩算法 {alg}"),
                };
                s.ReadExactly(code);

                if (s != data)
                {
                    s.Dispose();
                }

                codes.Add(code);
            }

            return codes;
        }

        // 暴力判据的分组键：前 64 字节的 FNV-1a（与被测实现无关；碰撞只多比几条）
        private static ulong Key64(ReadOnlySpan<byte> b)
        {
            ulong h = 14695981039346656037UL;

            for (int i = 0; i < 64; i++)
            {
                h = (h ^ b[i]) * 1099511628211UL;
            }

            return h;
        }

        public static void Run(Action<string, object, object> check)
        {
            string env = Environment.GetEnvironmentVariable("S2A_SHCODE_CORPUS");
            string home = Environment.GetEnvironmentVariable("HOME") ?? "";
            List<(string Name, string Dir)> corpora = new();

            if (env != null)
            {
                foreach (string d in env.Split(':', StringSplitOptions.RemoveEmptyEntries))
                {
                    corpora.Add((System.IO.Path.GetFileName(d), d));
                }
            }
            else
            {
                foreach ((string g, string tid) in new[] { ("acnh", "01006f8002326000"), ("botw", "01007ef00011e000") })
                {
                    string roots = System.IO.Path.Combine(Environment.GetEnvironmentVariable("S2A_RUN_ROOT") ?? System.IO.Path.Combine(home, ".s2arm/run"), "s2arm/roots");
                    string ptr = System.IO.Path.Combine(roots, g + "@现行");   // 现行是指针文件，内容 = 版本目录名（pack/orch/current.py）；没有 = 无语料跳过
                    corpora.Add((g, System.IO.Path.Combine(roots, System.IO.File.Exists(ptr) ? System.IO.File.ReadAllText(ptr).Trim() : g + "@无现行", "shaders/shcache", tid)));
                }
            }

            foreach ((string name, string dir) in corpora)
            {
                if (!System.IO.File.Exists(System.IO.Path.Combine(dir, "guest.toc")))
                {
                    check($"着色器代码表新旧对拍 {name}", "无语料（跳过）", "无语料（跳过）");
                    Console.Error.WriteLine($"着色器代码表新旧对拍：{name} 无语料 {dir}");
                    continue;
                }

                long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
                RunCorpus(check, name, ReadCorpus(dir));
                Console.Error.WriteLine($"着色器代码表新旧对拍 {name}：{System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalSeconds:F1} 秒");
            }
        }

        // 一轮对拍：codes 全进新旧两张表；sources 里的每条代码派生 ①②③ 样本，再加 randoms 条 ④ 随机串。
        //   返回（样本数、新表命中数、新表≠暴力、上游≠暴力、前缀对样本数、前缀对里新表没取最长、上游命中不在合法集，首例）
        private static (int Samples, int Hits, int NewBad, int OldBad, int Ambiguous, int AmbNewBad, int AmbOldBad, string First) Sweep(
            List<byte[]> codes, IEnumerable<int> sources, int randoms, Random rng, bool withOld)
        {
            // withOld = false：不建上游旧表（它登记是平方级的，九千 / 一万四千条要 7–60 秒、随机器负载涨，门禁里拖到单测超时）
            Upstream.PartitionedHashTable<int> oldTable = withOld ? new() : null;
            Ryujinx.Graphics.Gpu.Shader.HashTable.PartitionedHashTable<int> newTable = new();
            Dictionary<ulong, List<int>> groups = new();
            int samples = 0, hits = 0, newBad = 0, oldBad = 0, ambiguous = 0, ambNewBad = 0, ambOldBad = 0;
            string first = null;

            for (int i = 0; i < codes.Count; i++)
            {
                int newId = newTable.GetOrAdd(codes[i], i), oldId = withOld ? oldTable.GetOrAdd(codes[i], i) : newId;

                if (oldId != newId)
                {
                    newBad++;
                    first ??= $"登记去重：第 {i} 条上游回 #{oldId}、新回 #{newId}";
                }

                if (newId == i)
                {
                    ulong key = Key64(codes[i]);
                    (groups.TryGetValue(key, out List<int> l) ? l : groups[key] = new()).Add(i);
                }
            }

            void Probe(byte[] mem, string kind)
            {
                samples++;
                int io = 0; byte[] dO = null;
                bool ho = withOld && oldTable.TryFindItem(new MemAccessor(mem), out io, out dO);
                bool hn = newTable.TryFindItem(new MemAccessor(mem), out int iN, out byte[] dN);
                hits += hn ? 1 : 0;

                // 暴力判据：能匹配的已存代码（code == mem[..code.Length]），取最长
                int count = 0, longest = -1;

                if (mem.Length >= 64 && groups.TryGetValue(Key64(mem), out List<int> cand))
                {
                    foreach (int c in cand)
                    {
                        if (codes[c].Length <= mem.Length && mem.AsSpan(0, codes[c].Length).SequenceEqual(codes[c]))
                        {
                            count++;
                            longest = longest < 0 || codes[c].Length > codes[longest].Length ? c : longest;
                        }
                    }
                }

                bool newOk = hn == (count > 0) && (!hn || (iN == longest && ReferenceEquals(dN, codes[longest])));
                bool oldOk = !withOld || ho == (count > 0) && (!ho || dO.Length == codes[io].Length && mem.AsSpan(0, dO.Length).SequenceEqual(dO)) && (count != 1 || !ho || io == longest);
                string desc = $"{kind}（长 {mem.Length}）：暴力 {count} 条{(count > 0 ? $"、最长 #{longest} 长 {codes[longest].Length}" : "")}；上游 {(ho ? $"#{io} 长 {dO.Length}" : "未中")}、新 {(hn ? $"#{iN} 长 {dN.Length}" : "未中")}";

                if (count >= 2)
                {
                    ambiguous++;
                    ambNewBad += newOk ? 0 : 1;
                    ambOldBad += oldOk ? 0 : 1;
                }
                else
                {
                    newBad += newOk ? 0 : 1;
                    oldBad += oldOk ? 0 : 1;
                }

                if (!newOk || !oldOk)
                {
                    first ??= desc;
                }
            }

            foreach (int i in sources)
            {
                byte[] c = codes[i];

                // ① 原样；② 接 4 KB 随机尾巴
                Probe(c, "原样");
                byte[] tail = new byte[c.Length + 4096];
                c.CopyTo(tail, 0);
                rng.NextBytes(tail.AsSpan(c.Length));
                Probe(tail, "接尾巴");

                // ③ 截短 1 B；截到各检查点 −1 / 0 / +1；第 64 B 后某处起换成随机字节（同头部的近邻）
                Probe(c[..^1], "截短 1 B");

                for (int cp = 128; cp < c.Length; cp <<= 1)
                {
                    for (int d = -1; d <= 1; d++)
                    {
                        if (cp + d < c.Length)
                        {
                            Probe(c[..(cp + d)], $"截到检查点 {cp}{d:+0;-0;+0}");
                        }
                    }
                }

                byte[] near = (byte[])tail.Clone();
                rng.NextBytes(near.AsSpan(64 + rng.Next(c.Length - 64)));
                Probe(near, "同头部近邻");
            }

            // ④ 随机字节串：长 1 B … 64 KB
            for (int k = 0; k < randoms; k++)
            {
                byte[] r = new byte[1 + rng.Next(65536)];
                rng.NextBytes(r);
                Probe(r, "随机");
            }

            return (samples, hits, newBad, oldBad, ambiguous, ambNewBad, ambOldBad, first);
        }

        private static void RunCorpus(Action<string, object, object> check, string name, List<byte[]> corpus)
        {
            Random rng = new(7);

            // 第一轮：只用真实语料，每条代码派生全部样本 + 2000 条随机串。期望新表 = 暴力（语料里若天然有前缀对，单列在前缀对计数里）
            var a = Sweep(corpus, System.Linq.Enumerable.Range(0, corpus.Count), 2000, rng, false);
            check($"着色器代码表新旧对拍 {name} 真实语料：{corpus.Count} 条、{a.Samples} 个样本（新表命中 {a.Hits}）新表≠暴力",
                "0", a.NewBad == 0 ? "0" : $"{a.NewBad}（首例 {a.First}）");
            // 上游对照只取每 16 条一条（确定性子集）：新表替换上游时已全量对拍过（10-21 shader-lazy），门禁里留同口径对照防两边语义走偏；
            //   上游登记平方级，全量要 7–60 秒（负载越高越慢，拖到单测超时），子集 1/16 条 ≈ 1/256 的登记量
            List<byte[]> sub = new();
            for (int i = 0; i < corpus.Count; i += 16) sub.Add(corpus[i]);
            var o = Sweep(sub, System.Linq.Enumerable.Range(0, sub.Count), 200, rng, true);
            check($"着色器代码表新旧对拍 {name} 上游对照子集：{sub.Count} 条（每 16 条取 1）、{o.Samples} 个样本 新表≠暴力 / 上游≠暴力",
                "0 / 0", $"{o.NewBad} / {o.OldBad}{(o.NewBad + o.OldBad > 0 ? $"（首例 {o.First}）" : "")}");
            check($"着色器代码表新旧对拍 {name} 真实语料：天然前缀对样本 {a.Ambiguous} / {o.Ambiguous} 个，新表取最长 / 上游命中合法 不符", "0 / 0", $"{a.AmbNewBad} / {o.AmbOldBad}");

            // 第二轮 ⑤：语料里抽 200 条 A，各接 8 … 1024 B 随机字节成 B（A 是 B 的前缀），一起进表；样本只从这 400 条派生。
            //   期望新表 = 暴力（含前缀对取最长）；不建上游表（上游在这类样本上二分可能漏报 A，已在 10-21 替换时记录，不判）
            List<byte[]> codes = new(corpus);
            List<int> pairs = new();

            for (int k = 0; k < 200; k++)
            {
                int i = rng.Next(corpus.Count);
                byte[] b = new byte[corpus[i].Length + 8 * rng.Next(1, 129)];
                rng.NextBytes(b);
                corpus[i].CopyTo(b, 0);
                pairs.Add(i);
                pairs.Add(codes.Count);
                codes.Add(b);
            }

            var p = Sweep(codes, pairs, 0, rng, false);
            check($"着色器代码表新旧对拍 {name} 造前缀对：200 对、{p.Samples} 个样本（前缀对 {p.Ambiguous} 个）新表≠暴力（含取最长）",
                "0", p.NewBad + p.AmbNewBad == 0 ? "0" : $"{p.NewBad + p.AmbNewBad}（首例 {p.First}）");
        }
    }
}
