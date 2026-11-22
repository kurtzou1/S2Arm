// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.IO;
using System.Linq;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;

namespace S2A.Services.Tests
{
    // #662 本地多人：主机模式下 2 号手柄加入时，游戏拉起选用户小程序（psel 模式 0 UserSelector），UiSettings 偏移 8 起是
    //   invalid_uid_list（8 个 Uid，libnx PselUiSettings），列出已在玩的用户。宿主选用户对话框总回当前用户（1 号），
    //   游戏不收、立刻重开，2 秒 20 多次，玩家看到「按了没反应」。真机上 2 号玩家会选或新建另一个用户。
    //   期望照真机语义手写：当前用户在名单里 → 回一个不在名单里的已有用户；没有就像 UserCreator 一样新建一个（账户表里有、用户数 +1）；
    //   再问一次同样的名单，回同一个已有用户、不再新建；名单把它也列上 → 再新建一个不同的。
    //   负对照：名单为空、或名单里只有别的用户（不含当前用户）→ 照旧回当前用户，不建用户
    public static unsafe partial class Program
    {
        [SoloTest("--acc-psel-invalid-list", Booted = true)]
        private static void AccountSelectInvalidList()
        {
            var system = Host.Device.System;
            var users = system.AccountManager;
            UserId current = users.LastOpenedUser.UserId;

            long prompt = 0;
            string answer = null;
            (string Result, UserId Uid) Psel(params UserId[] invalid)
            {
                var normal = new AppletSession();
                AppletSession game = normal.GetConsumer();
                game.Push(new byte[0x20]);   // 公共参数
                byte[] ui = new byte[0xA0];  // nn::account::UiSettings：模式 0，偏移 8 起 invalid_uid_list
                for (int i = 0; i < invalid.Length; i++)
                {
                    MemoryStream m = new();
                    invalid[i].Write(new BinaryWriter(m));
                    m.ToArray().CopyTo(ui, 8 + 16 * i);
                }
                game.Push(ui);
                new PlayerSelectApplet(system).Start(normal, new AppletSession());
                if (prompt != 0)
                {
                    TextInput.Answer(prompt, answer != null, answer);
                    prompt = 0;
                }
                byte[] r = null;
                if (!System.Threading.SpinWait.SpinUntil(() => game.TryPop(out r), 2000) || r.Length < 0x18) return ("无完整回包", UserId.Null);
                return ($"长 0x{r.Length:X}、结果 0x{BitConverter.ToUInt64(r, 0):X}", new UserId(r[8..0x18]));
            }
            string Who(UserId id, params (string Name, UserId Id)[] known)
            {
                foreach (var (name, k) in known) if (id == k) return name;
                return users.GetAllUsers().Any(u => u.UserId == id) ? "账户表里的其他用户" : id.IsNull ? "全零" : "账户表里没有";
            }

            int before = users.GetAllUsers().Count();
            Check("夹具只有当前用户", "1", before.ToString());

            var a = Psel(current);
            Check("名单含当前用户、没有别的用户 → 新建一个", "长 0x18、结果 0x0、账户表里的其他用户、用户数 +1",
                $"{a.Result}、{Who(a.Uid, ("当前用户", current))}、用户数 +{users.GetAllUsers().Count() - before}");
            string name = users.GetAllUsers().FirstOrDefault(u => u.UserId == a.Uid)?.Name ?? "";
            Check("新建用户的昵称是 PlayerN", "True", name.StartsWith("Player").ToString());

            var b = Psel(current);
            Check("同样的名单再问 → 回刚才那个用户、不再新建", "长 0x18、结果 0x0、上次的用户、用户数 +1",
                $"{b.Result}、{Who(b.Uid, ("当前用户", current), ("上次的用户", a.Uid))}、用户数 +{users.GetAllUsers().Count() - before}");

            var c = Psel(current, a.Uid);
            Check("名单含当前用户和上次的用户 → 再新建一个不同的", "长 0x18、结果 0x0、账户表里的其他用户、用户数 +2",
                $"{c.Result}、{Who(c.Uid, ("当前用户", current), ("上次的用户", a.Uid))}、用户数 +{users.GetAllUsers().Count() - before}");

            var n1 = Psel();
            Check("负对照：名单为空 → 当前用户", "长 0x18、结果 0x0、当前用户", $"{n1.Result}、{Who(n1.Uid, ("当前用户", current))}");
            var n2 = Psel(a.Uid);
            Check("负对照：名单不含当前用户 → 当前用户", "长 0x18、结果 0x0、当前用户", $"{n2.Result}、{Who(n2.Uid, ("当前用户", current))}");
            Check("负对照不建用户", "+2", $"+{users.GetAllUsers().Count() - before}");

            // 启动器的玩家名单只定顺序：名单里的人排前面，名单外原有的用户（上面新建的两个 PlayerN）照样给游戏看到，存档不丢
            string NameOf(UserId id) => users.GetAllUsers().First(u => u.UserId == id).Name;
            string legacy = string.Join(",", new[] { a.Uid, c.Uid }.OrderBy(id => id.ToString(), StringComparer.Ordinal).Select(NameOf));   // 名单外的按用户号排
            const string second = "123456789abcdef0123456789abcdef0";
            string roster = """[{"user":"first","name":"One","folder":"SaveData"},{"user":"123456789abcdef0123456789abcdef0","name":"Two","folder":"SaveData-Two"}]""";
            Environment.SetEnvironmentVariable("S2A_LOCAL_PLAYERS", roster);
            Environment.SetEnvironmentVariable("S2A_PLAYER_USER", "first");
            LocalPlayer.Select(Host.Device, 1);
            TextInput.BeginHook = (_, _) => 0; // Headless host.
            var chosen = Psel(current);
            Check("第二位玩家使用启动器已有用户号", second, chosen.Uid.ToString());
            string[] offered = null;
            TextInput.BeginHook = (id, json) =>
            {
                using var request = System.Text.Json.JsonDocument.Parse(json);
                offered = request.RootElement.GetProperty("localPlayers").EnumerateArray().Select(n => n.GetString()).ToArray();
                prompt = id;
                return 1;
            };
            answer = "0";
            Check("唯一可选的已有用户仍在列表中", second, Psel(current).Uid.ToString());
            Check("列表过滤已在玩的用户、名单里的排前面、名单外原有用户排后面", "Two," + legacy, string.Join(",", offered));
            answer = "1";
            Check("可手动选择第二个已有用户", second, Psel().Uid.ToString());
            answer = null;
            Check("取消创建得到 NS 的取消结果", "长 0x18、结果 0x27C", Psel(current, chosen.Uid, a.Uid, c.Uid).Result);
            Check("无可选用户直接进入创建", "0", offered.Length.ToString());
            answer = "new:Three";
            string stored = null;
            var store = LocalPlayer.StorePlayer;
            LocalPlayer.StorePlayer = (uid, nickname, folder) => stored = uid;
            try
            {
                var created = Psel(current);
                Check("列表还有已有用户时可以选择创建，返回持久化的 UID", "True",
                    (!created.Uid.IsNull && created.Uid.ToString() == stored).ToString());
                string next = roster[..^1] + ",{\"user\":\"" + stored + "\",\"name\":\"Three\",\"folder\":\"SaveData-Three\"}]";
                Environment.SetEnvironmentVariable("S2A_LOCAL_PLAYERS", next);
                LocalPlayer.Select(Host.Device, 1);
                answer = "0";
                Check("再次起局，按同一排除名单取回原来的 UID", stored, Psel(current, chosen.Uid).Uid.ToString());
                Environment.SetEnvironmentVariable("S2A_LOCAL_PLAYERS", """[{"user":"first","name":"One","folder":"SaveData"}]""");
                LocalPlayer.Select(Host.Device, 1);
                answer = "0";
                Check("名单只剩一个玩家：照样给列表（名单外的用户不藏），选第一行是名单里那个", current.ToString(), Psel().Uid.ToString());
                Check("名单只剩一个玩家：列表 = 名单里的人 + 名单外原有的全部用户", users.GetAllUsers().Count().ToString(), offered.Length.ToString());
                Check("名单只剩一个玩家：名单里的人排第一", "One", offered[0]);
                // 无选人界面（无人值守）：走原来的应答，新建的临时用户不记进本机玩家列表
                TextInput.BeginHook = (_, _) => 0;
                stored = null;
                int had = users.GetAllUsers().Count();
                var all = users.GetAllUsers().Select(u => u.UserId).ToArray();
                var headless = Psel(all);
                Check("无选人界面、人人都在名单里：照旧新建一个用户", $"{had + 1}、账户表里的其他用户", $"{users.GetAllUsers().Count()}、{Who(headless.Uid)}");
                Check("无选人界面：不写本机玩家列表", "True", (stored == null).ToString());
                Check("多人加入后主用户身份", current.ToString(), users.LastOpenedUser.UserId.ToString());
            }
            finally
            {
                TextInput.BeginHook = null;
                LocalPlayer.StorePlayer = store;
                LocalPlayer.ResetSession();
                Environment.SetEnvironmentVariable("S2A_PLAYER_USER", null);
                Environment.SetEnvironmentVariable("S2A_LOCAL_PLAYERS", null);
            }

            while (system.AppletState.Messages.TryDequeue(out _)) { }
        }
    }
}
