// 游戏表：答案表 shader_facts.tsv（FACTS）、顶点 / 片元配对 shader_pairs.tsv（PAIRS）、shader_map.tsv（+ .conflicts.tsv，只供 json 的 source / pc_paired 两项）。
// 读法逐条照 dmsh_build.py / dmsh_facts.py；运行时它们在 $S2A_GAME_DATA/shaders/direct/（资源包，graphics/tools/direct/direct_lib.sh 写）。
// 按目录缓存，文件修改时间或长度变了重读。
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json.Nodes;

namespace S2A.Dsh
{
    sealed class DshTables
    {
        /// <summary>键 → 答案行 JSON 原文（每次用时现解析：JsonObject 懒展开不是线程安全的，不在线程间共用节点）</summary>
        public readonly Dictionary<string, string> Facts = new(StringComparer.Ordinal);
        public readonly Dictionary<string, HashSet<string>> Pairs = new(StringComparer.Ordinal);
        /// <summary>片元键 → 它读的 user(locn) 位置（ps_inputs.tsv，direct_lib.sh 从离线库 _b.metal 抽）：包里只有库、没有片元 MSL 时 vs_pad 靠它</summary>
        public readonly Dictionary<string, long[]> PsInputs = new(StringComparer.Ordinal);
        public readonly Dictionary<string, (string Pkg, int Index)> Loc = new(StringComparer.Ordinal);
        public readonly Dictionary<string, string> PcOf = new(StringComparer.Ordinal);
        public bool HasMap;
        /// <summary>要出可读瓦片版 _bf 的片元键（bf_want.tsv，宿主规划器出；同 dmsh_build.py BF_WANT）：只在 DMSH_BF=1 时决定「只改输出映射」的变体出不出</summary>
        public readonly HashSet<string> BfWant = new(StringComparer.Ordinal);
        /// <summary>片元键 → 请求的输出类型掩码 {(无符号, 有符号)}（fout_want.tsv，graphics/tools/direct/fout_want.m；同 dmsh_build.py FOUT_WANT，见 DshFt）</summary>
        public readonly Dictionary<string, HashSet<(long U, long S)>> FoutWant = new(StringComparer.Ordinal);
        /// <summary>本款域着色器用到的曲面域 → 该域最常见的模式字（同 dmsh_build.py TESS_MODES：整包域着色器控制段的曲面模式 TessCtl 计数）；出包批量模式由调用方从包里算，设备现编为空（外壳按缺省 1）</summary>
        public readonly SortedDictionary<int, uint> TessModes = new();

        static readonly object s_lock = new();
        static string s_dir, s_stamp; static DshTables s_cur;
        static string s_failDir, s_failStamp; static DshError s_fail;

        static string Stamp(string dir)
        {
            string st = "";
            foreach (var n in new[] { "shader_facts.tsv", "shader_pairs.tsv", "shader_map.tsv", "shader_map.tsv.conflicts.tsv", "ps_inputs.tsv", "bf_want.tsv", "fout_want.tsv" })
            {
                var fi = new FileInfo(Path.Combine(dir, n));
                st += fi.Exists ? $"{n}:{fi.Length}:{fi.LastWriteTimeUtc.Ticks};" : $"{n}:-;";
            }
            return st;
        }

        /// <summary>空表：运行时补编没有离线答案表时用（翻译查询按缺省，与离线链缺表时一致）。</summary>
        public static DshTables Empty() => new DshTables();

        /// <summary>目录 dir 下的表（缓存）；答案表 / 配对表缺失按空表（11-13），表坏了才抛错</summary>
        public static DshTables Get(string dir)
        {
            lock (s_lock)
            {
                string st = Stamp(dir);
                if (s_cur != null && s_dir == dir && s_stamp == st) return s_cur;
                // 载表失败按（目录、版本戳）记下：之后每个键撞上同一份缺的 / 坏的表只抛「已报过」，不再一键一行红（10-24 直连线：旧式 Mac 局私有根没带 shader_pairs.tsv，一局 8 行）
                if (s_failDir == dir && s_failStamp == st) throw new DshError(s_fail.Status, s_fail.Detail) { Reported = true };
                DshTables t;
                try { t = Load(dir); }
                catch (DshError e) { s_failDir = dir; s_failStamp = st; s_fail = e; throw; }
                s_dir = dir; s_stamp = st; s_cur = t;
                return t;
            }
        }

        static DshTables Load(string dir)
        {
            var t = new DshTables();
            string facts = Path.Combine(dir, "shader_facts.tsv"), pairs = Path.Combine(dir, "shader_pairs.tsv"), map = Path.Combine(dir, "shader_map.tsv");
            // 两张表不在 = 空表（全部按缺省答、没有配对）：表只是加速 / 校准，缺了照样编得出（11-13 D-QW2Q：玩家导入不带 shaders/ 的 game.img，
            //   缺 shader_facts.tsv 时原先每个键都报「no answer table」，一局现编 0 成 453 败、整局黑屏；同 11-06 疯狂兔子，当时只在出包端补空表）。
            //   表在但坏（行格式不对）仍报错：那是产物坏了，不能按缺省悄悄跑
            if (!File.Exists(facts)) Console.Error.WriteLine("[dsh] " + facts + " 不存在：按空答案表（全部缺省）现编");
            if (!File.Exists(pairs)) Console.Error.WriteLine("[dsh] " + pairs + " 不存在：按空配对表现编");
            // dmsh_facts.load：key<TAB>JSON，空行与 # 行跳过，后出现的覆盖先出现的
            foreach (var raw in File.Exists(facts) ? File.ReadLines(facts) : Array.Empty<string>())
            {
                if (raw.Trim().Length == 0 || raw.StartsWith('#')) continue;
                int tab = raw.IndexOf('\t');
                if (tab < 0) throw new DshError("bad answer table", "行没有制表符：" + raw[..Math.Min(raw.Length, 60)]);
                string js = raw[(tab + 1)..]; JsonNode.Parse(js).AsObject();   // 坏行在载表时就报
                t.Facts[raw[..tab]] = js;
            }
            // PAIRS：顶点键 → 配对的片元键；空行与 # 行跳过，每行恰两列（空白分隔）
            foreach (var raw in File.Exists(pairs) ? File.ReadLines(pairs) : Array.Empty<string>())
            {
                if (raw.Trim().Length == 0 || raw.StartsWith('#')) continue;
                var c = raw.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                if (c.Length != 2) throw new DshError("bad pairs table", "行不是两列：" + raw[..Math.Min(raw.Length, 60)]);
                if (!t.Pairs.TryGetValue(c[0], out var s)) t.Pairs[c[0]] = s = new HashSet<string>(StringComparer.Ordinal);
                s.Add(c[1]);
            }
            // ps_inputs.tsv：片元键<TAB>逗号分隔的 locn（可空）；没有这张表 = 只认同目录里的片元 _b.metal（同离线链）
            string psin = Path.Combine(dir, "ps_inputs.tsv");
            if (File.Exists(psin))
                foreach (var raw in File.ReadLines(psin))
                {
                    if (raw.Length == 0 || raw.StartsWith('#')) continue;
                    var c = raw.Split('\t');
                    if (c.Length != 2) throw new DshError("bad ps inputs table", "行不是两列：" + raw[..Math.Min(raw.Length, 60)]);
                    t.PsInputs[c[0]] = c[1].Length == 0 ? Array.Empty<long>() : Array.ConvertAll(c[1].Split(','), long.Parse);
                }
            // bf_want.tsv：每行一个键（去首尾空白），空行与（去前导空白后）# 开头的行跳过；没有这张表 = 空
            string bfw = Path.Combine(dir, "bf_want.tsv");
            if (File.Exists(bfw))
                foreach (var raw in File.ReadLines(bfw))
                    if (raw.Trim().Length > 0 && !raw.TrimStart().StartsWith('#')) t.BfWant.Add(raw.Trim());
            // fout_want.tsv：「键 无符号掩码hex 有符号掩码hex」（空白分隔），恰三列且不以 # 开头的行才算；没有这张表 = 空
            string fw = Path.Combine(dir, "fout_want.tsv");
            if (File.Exists(fw))
                foreach (var raw in File.ReadLines(fw))
                {
                    var c = raw.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                    if (c.Length != 3 || raw.StartsWith('#')) continue;
                    long u, s;
                    try { u = Convert.ToInt64(c[1], 16); s = Convert.ToInt64(c[2], 16); }
                    catch (Exception e) when (e is FormatException || e is OverflowException) { throw new DshError("bad fout table", "掩码不是十六进制：" + raw[..Math.Min(raw.Length, 60)]); }
                    if (!t.FoutWant.TryGetValue(c[0], out var set)) t.FoutWant[c[0]] = set = new HashSet<(long, long)>();
                    set.Add((u, s));
                }
            // loc / pc_of（dmsh_build.py 模块级那两段）：第 4 列键首次出现定包名与序号、第 5 列定 pc_paired；冲突表第 2 列覆盖 pc_paired
            if (File.Exists(map))
            {
                t.HasMap = true;
                foreach (var ln in File.ReadLines(map))
                {
                    var c = ln.Split('\t');
                    if (c.Length > 4 && c[0].EndsWith(".bin", StringComparison.Ordinal))
                    {
                        t.PcOf.TryAdd(c[3], c[4]);
                        if (!t.Loc.ContainsKey(c[3])) t.Loc[c[3]] = (c[0], int.Parse(c[1]));
                    }
                }
                string conf = map + ".conflicts.tsv";
                if (File.Exists(conf))
                    foreach (var ln in File.ReadLines(conf))
                    {
                        var c = ln.Split('\t');
                        if (c.Length > 1 && !ln.StartsWith('#') && !ln.StartsWith("dm_", StringComparison.Ordinal) && t.PcOf.ContainsKey(c[0])) t.PcOf[c[0]] = c[1];
                    }
            }
            return t;
        }
    }
}
