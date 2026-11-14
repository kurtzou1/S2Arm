using System;
using System.IO;
using System.Security.Cryptography;

namespace S2A.Services.Tests
{
    // 资源包缺的系统数据运行时用内置合成件补（诊断#3d2d3e / #5a5ee9：#886 之前出的包没有 0806，招募改名一确认就 Break）。
    // 期望手写，取自 Python 生成器 pack/sysdata_synth.py（不跑被测实现推）：0806 合成件 18 个文件，其中 0.txt 74 字节、sha256 be684329…；
    //   0802 合成件 6 个文件；不认识的号 → null；游戏资源包自带的 systemdata/<号>/ 优先于合成件
    public static class SystemDataSynthTest
    {
        public static void Run(Action<string, object, object> check)
        {
            string tmp = Path.Combine(Path.GetTempPath(), "s2a-synth-" + Guid.NewGuid().ToString("N"));
            try
            {
                string d806 = Host.SynthSystemData(0x0100000000000806UL, tmp);
                check("0806 资源包缺：解出合成件目录", true, d806 != null && Directory.Exists(d806));
                check("0806 合成件文件数", 18, d806 == null ? -1 : Directory.GetFiles(d806, "*", SearchOption.AllDirectories).Length);
                string f0 = d806 == null ? null : Path.Combine(d806, "0.txt");
                check("0806 0.txt 大小", 74L, f0 != null && File.Exists(f0) ? new FileInfo(f0).Length : -1L);
                check("0806 0.txt 内容 = Python 生成器", "be684329dc1c58db001fa709a2d05cc4aa108095e8da4de1a017959ce6930f3d",
                      f0 != null && File.Exists(f0) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(f0))).ToLowerInvariant() : "缺");
                check("再要一次：同一目录，不重解", d806, Host.SynthSystemData(0x0100000000000806UL, tmp));
                string d802 = Host.SynthSystemData(0x0100000000000802UL, tmp);
                check("0802 合成件文件数", 6, d802 == null ? -1 : Directory.GetFiles(d802, "*", SearchOption.AllDirectories).Length);
                check("不认识的号 → null", null, Host.SynthSystemData(0x0100000000000999UL, tmp));

                // 游戏资源包自带的优先：SystemDataRoot 下有 0806 → 用它；没有的号 → 走回退
                string game = Path.Combine(tmp, "game-systemdata"), own = Path.Combine(game, "0100000000000806");
                Directory.CreateDirectory(own);
                string rootWas = Ryujinx.HLE.S2AHooks.SystemDataRoot; var fallbackWas = Ryujinx.HLE.S2AHooks.SystemDataFallback;
                try
                {
                    Ryujinx.HLE.S2AHooks.SystemDataRoot = game;
                    Ryujinx.HLE.S2AHooks.SystemDataFallback = id => Host.SynthSystemData(id, tmp);
                    check("资源包自带 0806：用自带的", own, Ryujinx.HLE.S2AHooks.SystemDataDir(0x0100000000000806UL));
                    check("资源包没有 0823：用合成件", Path.Combine(tmp, "systemdata-synth", "0100000000000823"), Ryujinx.HLE.S2AHooks.SystemDataDir(0x0100000000000823UL));
                }
                finally
                {
                    Ryujinx.HLE.S2AHooks.SystemDataRoot = rootWas; Ryujinx.HLE.S2AHooks.SystemDataFallback = fallbackWas;
                }
            }
            finally
            {
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
            }
        }
    }
}
