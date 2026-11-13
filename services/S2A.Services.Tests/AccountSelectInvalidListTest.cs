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
                if (!game.TryPop(out byte[] r) || r.Length < 0x18) return ("无完整回包", UserId.Null);
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

            while (system.AppletState.Messages.TryDequeue(out _)) { }
        }
    }
}
