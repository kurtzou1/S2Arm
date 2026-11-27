using System;
using System.Collections.Generic;
using System.Numerics;
using System.Text.RegularExpressions;

namespace S2A.Services
{
    // 控制数据是导入时合成的（Switch 2 的 NUP / 主机导出目录都不带控制分区，合成件只声明美式英语）时，从 RomFS 文件路径推游戏支持哪些语言（D-7FZ6）。
    //   起因：支持表未知时 GetDesiredLanguage 原样交宿主主语言（#465）；0400486024DEC000 不支持泰语，泰语系统下拿到泰语码，首帧前读空指针崩。
    //   推出的表交 Ryujinx.HLE.S2AHooks.RomFsTitleLanguages，GetDesiredLanguage 照真表走「不支持就按退路选」；推不出（-1）照旧 #465。
    //
    // 规则（只认「语言槽」，防文件名里碰巧出现的字母组合）：
    //   ① 只认完整的「区域码 + 语言码」形状（下表 Codes），两侧不能紧挨字母或数字（路径分隔、_ . - 才算边界）；
    //   ② 一个路径里某个码换成占位得到模板；区域目录中性化：同一路径里紧跟小写字母 / 分隔符之后、单独成词的两字母区域码（regionCN/CNch 的 CN）也换成占位；
    //   ③ 同一模板下有 ≥ MinCodesPerSlot 种不同语言码，这个模板才是语言槽；只有落在语言槽里的码算支持；
    //   ④ Excluded 下的路径不看：游戏内嵌软键盘（nn::swkbd）的资源随 SDK 带全部语言，与游戏本身支持哪些语言无关（01006F8002326000 只在这里有 EUpt，NACP 不声明葡语）。
    // 11-26 对账（维护者 Mac 游戏库完整 RomFS 清单 × 原件 NACP）：01006F8002326000 / 0100000000010000 / 0100152000022000 / 01006BB00C6F0000 / 01007EF00011E000 / 010015100B514000 六款逐位一致；
    //   第三方款与归档打包的款一个语言槽都没有（不出表，照旧 #465）。
    internal static class RomFsLanguages
    {
        // 区域码 + 语言码 → 支持语言位（= Ryujinx TitleLanguage 枚举值：美式英语 0 … 波兰语 16、泰语 17）
        internal static readonly (string Code, int Bit)[] Codes =
        {
            ("USen", 0), ("EUen", 1), ("JPja", 2), ("EUfr", 3), ("EUde", 4), ("USes", 5), ("EUes", 6), ("EUit", 7), ("EUnl", 8), ("USfr", 9),
            ("EUpt", 10), ("EUru", 11), ("KRko", 12), ("TWzh", 13), ("CNzh", 14), ("USpt", 15), ("EUpl", 16), ("THth", 17),
            // 变体写法：01006BB00C6F0000 的 RomFS（regionKR/KRkr、regionTW/TWch、regionCN/CNch，原件 NACP 声明韩 / 繁 / 简）
            ("KRkr", 12), ("TWch", 13), ("CNch", 14),
        };

        internal const int MinCodesPerSlot = 3;

        internal static readonly string[] Excluded = { "Swkbd/" };

        private static readonly Regex Token = new(@"(?<![A-Za-z0-9])(" + string.Join("|", Array.ConvertAll(Codes, c => c.Code)) + @")(?![A-Za-z0-9])", RegexOptions.CultureInvariant);

        private static readonly Dictionary<string, int> Index = BuildIndex();

        private static readonly Regex[] CodeAt = Array.ConvertAll(Codes, c => new Regex(@"(?<![A-Za-z0-9])" + c.Code + @"(?![A-Za-z0-9])", RegexOptions.CultureInvariant));

        private static readonly Regex[] RegionAt = Array.ConvertAll(Codes, c => new Regex(@"(?:(?<=[a-z/_.\-])|^)" + c.Code.Substring(0, 2) + @"(?![A-Za-z0-9])", RegexOptions.CultureInvariant));

        private static Dictionary<string, int> BuildIndex()
        {
            Dictionary<string, int> d = new(StringComparer.Ordinal);
            for (int i = 0; i < Codes.Length; i++) d[Codes[i].Code] = i;
            return d;
        }

        /// <summary>RomFS 里的文件相对路径（/ 分隔）→ 支持语言位（TitleLanguage 位）；认不出返回 0。slots = 语言槽个数</summary>
        internal static int Detect(IEnumerable<string> paths, out int slots)
        {
            Dictionary<string, ulong> templates = new(StringComparer.Ordinal);   // 模板 → 出现过的码（Codes 下标位图）
            foreach (string raw in paths)
            {
                string p = raw.TrimStart('/');
                if (Array.Exists(Excluded, e => p.StartsWith(e, StringComparison.Ordinal))) continue;
                ulong seen = 0;
                foreach (Match m in Token.Matches(p)) seen |= 1ul << Index[m.Groups[1].Value];
                for (ulong rest = seen; rest != 0; rest &= rest - 1)
                {
                    int i = BitOperations.TrailingZeroCount(rest);
                    string t = RegionAt[i].Replace(CodeAt[i].Replace(p, "\0"), "\u0001");
                    templates[t] = templates.GetValueOrDefault(t) | (1ul << i);
                }
            }
            ulong lang = 0;
            slots = 0;
            foreach (ulong v in templates.Values)
            {
                if (BitOperations.PopCount(v) < MinCodesPerSlot) continue;
                lang |= v;
                slots++;
            }
            int bits = 0;
            for (ulong rest = lang; rest != 0; rest &= rest - 1) bits |= 1 << Codes[BitOperations.TrailingZeroCount(rest)].Bit;
            return bits;
        }

        /// <summary>支持语言位 → 「美式英语、日语…」（日志用）</summary>
        internal static string Names(int bits)
        {
            List<string> n = new();
            for (int b = 0; b <= (int)Ryujinx.HLE.HOS.SystemState.TitleLanguage.Thai; b++)
                if ((bits >> b & 1) != 0) n.Add(((Ryujinx.HLE.HOS.SystemState.TitleLanguage)b).ToString());
            return string.Join(" ", n);
        }
    }
}
