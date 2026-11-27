using System;
using System.IO;
using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    // D-7FZ6：合成控制数据时从 RomFS 推支持语言（RomFsLanguages）+ GetDesiredLanguage 用推出的表（IApplicationFunctions.UseRomFsLanguages）。
    //   夹具 data/romfs_lang/<程序号>.txt：从各款完整 RomFS 文件清单裁出的语言槽（每款覆盖全部认出的码），外加干扰行
    //   （0400486024DEC000 零星出现的 EUen 行；01006F8002326000 的 Swkbd/ 软键盘资源，那里有 NACP 不声明的 EUpt）。
    //   期望：前三款 = 原件 NACP 的 SupportedLanguageFlag（11-26 维护者 Mac 读出）；0400486024DEC000 / 040074A01BF12000 没有原件 NACP，
    //   期望是规则对完整清单的结果，并经 Mac 实局对过（前者泰语崩、另 7 种语言进得去；后者泰语、英语、葡语进得去）。
    public static class RomFsLanguagesTest
    {
        public static void Run(Action<string, object, object> check)
        {
            string dir = Path.Combine(AppContext.BaseDirectory, "data", "romfs_lang");
            string Derived(string id) => $"0x{RomFsLanguages.Detect(File.ReadAllLines(Path.Combine(dir, id + ".txt")), out _):X5}";
            check("RomFS 推语言：0100000000010000 = NACP 0x7bff", "0x07BFF", Derived("0100000000010000"));
            check("RomFS 推语言：01006BB00C6F0000 变体码 KRkr / TWch / CNch + 区域目录 regionXX = NACP 0x7bff", "0x07BFF", Derived("01006BB00C6F0000"));
            check("RomFS 推语言：01006F8002326000 Swkbd/ 的 EUpt 不算 = NACP 0x7bff", "0x07BFF", Derived("01006F8002326000"));
            check("RomFS 推语言：0400486024DEC000 16 种含波兰语、没有泰语", "0x1FBFF", Derived("0400486024DEC000"));
            check("RomFS 推语言：040074A01BF12000 含泰语、没有葡语（EUpt）", "0x3FBFF", Derived("040074A01BF12000"));

            // 防误判：同一模板不满 3 种码不算；嵌在词里的不算；Swkbd/ 下再多也不算
            check("RomFS 推语言：两种码一个模板 / 嵌在词里 / 只在 Swkbd/ → 都认不出", "0 / 0 / 0", string.Join(" / ",
                RomFsLanguages.Detect(new[] { "Msg/USen.sarc", "Msg/JPja.sarc", "Model/USen_body.bfres" }, out _),
                RomFsLanguages.Detect(new[] { "a/xUSen/b", "a/xJPja/b", "a/xEUfr/b", "a/USenx/b", "a/JPjax/b", "a/EUfrx/b" }, out _),
                RomFsLanguages.Detect(new[] { "Swkbd/message/USen/a", "Swkbd/message/JPja/a", "Swkbd/message/EUfr/a" }, out _)));
            check("RomFS 推语言：三种码一个模板 → 美 / 日 / 法（位 0、2、3）、语言槽 1", "0x0000D / 1",
                $"0x{RomFsLanguages.Detect(new[] { "/Msg/USen.sarc", "/Msg/JPja.sarc", "/Msg/EUfr.sarc", "Model/USen_body.bfres" }, out int s):X5} / {s}");

            // 什么时候用推出的表：合成件（版本 ?）或没声明已知语言，推出了，且玩家没显式指定；真 NACP / 推不出 / 显式指定 都不用
            check("用推出的表：合成件 / 位为 0 / 真 NACP 0x3005 / 推不出 / 合成件 + 显式指定", "True / True / False / False / False", string.Join(" / ",
                IApplicationFunctions.UseRomFsLanguages(1, "?", 0x1FBFF, false), IApplicationFunctions.UseRomFsLanguages(0, "", 0x1FBFF, false),
                IApplicationFunctions.UseRomFsLanguages(0x3005, "1.0.2", 0x1FBFF, false), IApplicationFunctions.UseRomFsLanguages(1, "?", -1, false),
                IApplicationFunctions.UseRomFsLanguages(1, "?", 0x1FBFF, true)));

            // 选出的语言（五步退路，SystemLocale.TitleFallback：主语言 → 美式英语 → 英式英语）：0400486024DEC000 的表下泰语系统 → 美式英语（第 3 步），简中 → 简中；
            //   040074A01BF12000 的表下泰语 → 泰语（第 1 步）
            string Sel(SystemLanguage host, int supported)
            {
                TitleLanguage h = Enum.Parse<TitleLanguage>(host.ToString());
                TitleLanguage[] fb = SystemLocale.TitleFallback(host);
                int p = IApplicationFunctions.PickDesiredLanguage(h, supported, fb);
                return $"{(TitleLanguage)p}（{IApplicationFunctions.LanguageStep(h, p, fb)}）";
            }
            check("推出的表选语言：0x1fbff + 泰语 / 0x1fbff + 简中 / 0x3fbff + 泰语",
                "AmericanEnglish（第 3 步：英语） / SimplifiedChinese（第 1 步：宿主主语言） / Thai（第 1 步：宿主主语言）",
                $"{Sel(SystemLanguage.Thai, 0x1FBFF)} / {Sel(SystemLanguage.SimplifiedChinese, 0x1FBFF)} / {Sel(SystemLanguage.Thai, 0x3FBFF)}");
        }
    }
}
