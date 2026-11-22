using LibHac.Fs.Fsa;
using LibHac.Fs.Shim;
using System;
using System.IO;
using System.Linq;
using System.Text;
using AccUserId = Ryujinx.HLE.HOS.Services.Account.Acc.UserId;
using AccountManager = Ryujinx.HLE.HOS.Services.Account.Acc.AccountManager;

namespace S2A.Services.Tests
{
    // 本地玩家（#623，LocalPlayer.cs）：玩家给的三步验收，在真 Horizon 存档服务上走一遍（不要游戏数据：一个合成程序号，
    //   Ryujinx 对全零控制数据建缺省大小的账号存档）。每一「局」按 Application.Register / 收局的顺序：选用户 → 建存档 → 存档位置读入 →（游戏存档）→ 退出写回。
    //   期望按规则手写：存档按用户号隔离；第一个玩家 = 存档位置记的用户号（这里是缺省用户），另一个玩家 = 平台给的用户号；两人的存档位置与摘要文件各自一份
    public static partial class Program
    {
        [SoloTest("--local-players", Booted = true)]
        private static void LocalPlayers()
        {
            const ulong Pid = 0x0100000000623000;
            const string P2 = "5a1e0b7c3d9f4e2a8b6c1d0e9f8a7b6c";
            var acc = Host.Device.System.AccountManager;
            var hc = Host.Device.System.LibHacHorizonManager.RyujinxClient;
            string root = Ryujinx.Common.Configuration.AppDataManager.BaseDirPath;
            string t = Path.Combine(Path.GetTempPath(), $"s2a_local_players_{Environment.ProcessId}");
            if (Directory.Exists(t)) Directory.Delete(t, true);
            var dflt = AccountManager.DefaultUserId;
            var p2 = new AccUserId(P2);
            string f1 = Path.Combine(t, "SaveData"), f2 = Path.Combine(t, "SaveData-Hong");
            string st1 = Path.Combine(root, "savedata-state.txt"), st2 = Path.Combine(root, $"savedata-state-{P2}.txt");
            byte[] oldSave = new byte[2048]; new Random(23).NextBytes(oldSave);
            byte[] hongSave = new byte[1024]; new Random(24).NextBytes(hongSave);
            byte[] laterSave = new byte[1536]; new Random(25).NextBytes(laterSave);

            string Dir(string name, byte[] data)
            {
                string d = Path.Combine(t, name), f = Path.Combine(d, "0", "progress.sav");
                Directory.CreateDirectory(Path.GetDirectoryName(f)); File.WriteAllBytes(f, data);
                return d;
            }
            // 读某个用户这款的账号存档里的进度文件；没有存档 / 没有文件 → null
            byte[] Read(AccUserId user)
            {
                if (LibHac.Fs.Shim.SaveData.MountSaveData(hc.Fs, "s2alp"u8, new LibHac.Ncm.ApplicationId(Pid), user.ToLibHac()).IsFailure()) return null;
                try
                {
                    if (hc.Fs.OpenFile(out LibHac.Fs.FileHandle h, "s2alp:/0/progress.sav"u8, LibHac.Fs.OpenMode.Read).IsFailure()) return null;
                    hc.Fs.GetFileSize(out long size, h).ThrowIfFailure();
                    byte[] buf = new byte[size];
                    hc.Fs.ReadFile(h, 0, buf).ThrowIfFailure();
                    hc.Fs.CloseFile(h);
                    return buf;
                }
                finally { hc.Fs.Unmount("s2alp"u8); }
            }
            string Is(byte[] b, byte[] want, string label) => b == null ? "无存档" : b.AsSpan().SequenceEqual(want) ? label : $"{b.Length} 字节别的内容";
            // 一局的开头：同 Application.Register 的顺序（Saves.Dir() 为空的正常起局）
            void Launch(string player, string name, string folder)
            {
                Environment.SetEnvironmentVariable("S2A_PLAYER_USER", player);
                Environment.SetEnvironmentVariable("S2A_PLAYER_NAME", name);
                Environment.SetEnvironmentVariable("S2A_SAVE_FOLDER", folder);
                if (!LocalPlayer.Select(Host.Device, Pid)) SaveFolder.SelectUser(Host.Device, Pid);
                Ryujinx.HLE.Loaders.Processes.ProcessLoaderHelper.EnsureSaveData(Host.Device, new LibHac.Ncm.ApplicationId(Pid),
                    new LibHac.Common.BlitStruct<LibHac.Ns.ApplicationControlProperty>(1)).ThrowIfFailure();
                SaveFolder.ReadIn(Host.Device, Pid);
            }
            // 游戏在这一局里存档（整份账号存档换成 data，同游戏写完提交）
            void Played(byte[] data) => Saves.SeedFrom(Host.Device, Pid, [("account", Dir("played" + data.Length, data))]);
            long red0 = Red.Total;

            // 升级前：一个人玩，没有玩家（平台不给 S2A_PLAYER_USER），进度 oldSave，退出写回 SaveData
            acc.OpenUser(dflt);
            Launch(null, null, f1);
            Played(oldSave);
            SaveFolder.WriteBack(Host.Device);

            // ① 升级后什么都不选（平台不给）→ 照旧缺省用户、原进度；建过玩家后平台给 first → 同一个用户、同一份进度
            Launch(null, null, f1);
            string u1a = acc.LastOpenedUser.UserId.ToString(); byte[] s1a = Read(dflt);
            Launch(LocalPlayer.First, null, f1);
            string u1b = acc.LastOpenedUser.UserId.ToString(); byte[] s1b = Read(dflt);
            Check("本地玩家①：升级后不选 / 选第一个玩家 → 原用户原进度", $"{dflt} 原进度 / {dflt} 原进度",
                $"{u1a} {Is(s1a, oldSave, "原进度")} / {u1b} {Is(s1b, oldSave, "原进度")}");
            // 第一个玩家又玩了一段、没正常退出（iOS 在后台把 App 杀掉，不写回）：存档位置里是旧的，数据根里是新的 laterSave
            Played(laterSave);

            // ② 新建第二个玩家、开同一款：新用户、名字进资料、从头开始（账号存档是空的）；存档后退出，写回她自己的 SaveData-Hong
            Launch(P2, "Hong", f2);
            string u2 = acc.LastOpenedUser.UserId.ToString(), n2 = acc.LastOpenedUser.Name; byte[] fresh = Read(p2);
            Played(hongSave);
            SaveFolder.WriteBack(Host.Device);
            string userInF2 = File.Exists(Path.Combine(f2, "user")) ? File.ReadAllText(Path.Combine(f2, "user")).Trim() : "缺";
            byte[] inF2 = File.Exists(Path.Combine(f2, "save/0/progress.sav")) ? File.ReadAllBytes(Path.Combine(f2, "save/0/progress.sav")) : null;
            byte[] inF1 = File.Exists(Path.Combine(f1, "save/0/progress.sav")) ? File.ReadAllBytes(Path.Combine(f1, "save/0/progress.sav")) : null;
            Check("本地玩家②：新玩家从头开始，存档写回她自己的文件夹，第一个玩家的文件夹不动",
                $"{P2} Hong 无存档；SaveData-Hong 她的进度 user={P2}、她的摘要文件在；SaveData 旧写回",
                $"{u2} {n2} {Is(fresh, hongSave, "已有她的进度")}；SaveData-Hong {Is(inF2, hongSave, "她的进度")} user={userInF2}、她的摘要文件{(File.Exists(st2) ? "在" : "不在")}；SaveData {Is(inF1, oldSave, "旧写回")}");

            // ③ 退出重开 App：用户表在数据根 system/Profiles.json（另起一个账号管理器读同一份 = 重开后读到的）。
            //   切回第一个玩家 = 他没写回的那段新进度（不被存档位置里的旧档盖掉，靠摘要文件按玩家分）；切到第二个玩家 = 她刚存的
            var reopened = new AccountManager(hc, null);
            string table = $"{(reopened.GetAllUsers().Any(u => u.UserId == dflt) ? "有" : "没有")}缺省用户、{P2}:{reopened.GetAllUsers().FirstOrDefault(u => u.UserId == p2)?.Name ?? "缺"}";
            Launch(LocalPlayer.First, null, f1);
            string u3a = acc.LastOpenedUser.UserId.ToString(); byte[] s3a = Read(dflt);
            Launch(P2, "Hong", f2);
            string u3b = acc.LastOpenedUser.UserId.ToString(); byte[] s3b = Read(p2);
            Check("本地玩家③：重开后用户表还在；切回第一个玩家 = 他的最新进度，切到第二个玩家 = 她刚存的；全程报红 +0",
                $"有缺省用户、{P2}:Hong；{dflt} 他的最新进度 / {P2} 她的进度；报红 +0",
                $"{table}；{u3a} {Is(s3a, laterSave, "他的最新进度")} / {u3b} {Is(s3b, hongSave, "她的进度")}；报红 +{Red.Total - red0}");

            Environment.SetEnvironmentVariable("S2A_LOCAL_PLAYERS",
                """[{"user":"first","folder":"SaveData"},{"user":"5a1e0b7c3d9f4e2a8b6c1d0e9f8a7b6c","name":"Hong","folder":"SaveData-Hong"}]""");
            Launch(LocalPlayer.First, null, f1);
            LocalPlayer.MarkPlayerUsed(p2);
            Saves.SeedFrom(Host.Device, Pid, [("account", Dir("coop2", oldSave))], p2);
            SaveFolder.WriteBack(Host.Device);
            Check("同屏结束后两位玩家的目录各自写回", "P1 / P2",
                Is(File.ReadAllBytes(Path.Combine(f1, "save/0/progress.sav")), laterSave, "P1") + " / " +
                Is(File.ReadAllBytes(Path.Combine(f2, "save/0/progress.sav")), oldSave, "P2"));
            Environment.SetEnvironmentVariable("S2A_LOCAL_PLAYERS", null);

            // 第一个玩家的存档位置没记用户号（还没写回过）：回缺省用户，不沿用上一局的第二个玩家；
            // 名字截到 32 字节 UTF-8（Switch 昵称上限），不截半个字；认不出的玩家号报红、按没给处理
            Directory.Delete(f1, true); File.Delete(st1);
            Launch(LocalPlayer.First, null, f1);
            string u4 = acc.LastOpenedUser.UserId.ToString();
            Environment.SetEnvironmentVariable("S2A_PLAYER_NAME", "一二三四五六七八九十甲"); string cut = LocalPlayer.Name();
            Environment.SetEnvironmentVariable("S2A_PLAYER_USER", "zz"); long redZ = Red.Total; string bad = LocalPlayer.Requested() ?? "没给";
            Check("本地玩家：第一个玩家没记用户号回缺省用户 / 名字截 32 字节 / 认不出的玩家号", $"{dflt} / 一二三四五六七八九十 / 没给、报红 +1",
                $"{u4} / {cut} / {bad}、报红 +{Red.Total - redZ}");

            foreach (string v in new[] { "S2A_PLAYER_USER", "S2A_PLAYER_NAME", "S2A_SAVE_FOLDER" }) Environment.SetEnvironmentVariable(v, null);
            acc.OpenUser(dflt);
            foreach (string f in new[] { st1, st2 }) File.Delete(f);
            Directory.Delete(t, true);
        }
    }
}
