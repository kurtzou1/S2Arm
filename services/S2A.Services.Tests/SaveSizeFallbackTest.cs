using LibHac.Fs.Fsa;
using System;

namespace S2A.Services.Tests
{
    // 控制数据有标题、存档尺寸全为 0（某款 Switch 2 游戏导入后固定段全零：游戏开存档 2002-1002 自己中止、起局黑屏）：
    //   EnsureSaveData 照样补账号存档（ProcessLoaderHelper S2Arm 段）。期望按规则手写：之后按当前用户挂账号存档成功、存档归属号 = 程序号
    public static partial class Program
    {
        [SoloTest("--save-size-fallback", Booted = true)]
        private static void SaveSizeFallback()
        {
            const ulong Pid = 0x0400A3A01EE4C000;
            var hc = Host.Device.System.LibHacHorizonManager.RyujinxClient;
            var nacp = new LibHac.Common.BlitStruct<LibHac.Ns.ApplicationControlProperty>(1);
            byte[] title = "Title Only"u8.ToArray();
            for (int i = 0; i < 16; i++) title.CopyTo(nacp.ByteSpan.Slice(i * 0x300));   // 16 个语言槽只有名字，其余全 0
            var r = Ryujinx.HLE.Loaders.Processes.ProcessLoaderHelper.EnsureSaveData(Host.Device, new LibHac.Ncm.ApplicationId(Pid), nacp);
            var user = Host.Device.System.AccountManager.LastOpenedUser.UserId.ToLibHac();
            bool mounted = LibHac.Fs.Shim.SaveData.MountSaveData(hc.Fs, "s2asz"u8, new LibHac.Ncm.ApplicationId(Pid), user).IsSuccess();
            if (mounted) hc.Fs.Unmount("s2asz"u8);
            Check("只有标题的控制数据：补账号存档，挂得上", "建存档成功 / 挂上", $"{(r.IsSuccess() ? "建存档成功" : r.ToStringWithName())} / {(mounted ? "挂上" : "挂不上")}");
        }
    }
}
