using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy;
using System;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // ldn_mitm 的游戏数据面：房间控制协议走 11452，游戏随后按 GetIpv4Address 建 BSD socket 与对端通信。
        // 无联网权限仍是默认，但 LdnMitm 不能因此拿到只有回环的 OfflineSocket。
        [SoloTest("--ldn-mitm-host-sockets", Booted = true)]
        private static void LdnMitmHostSockets()
        {
            MultiplayerMode originalMode = Host.Device.Configuration.MultiplayerMode;
            bool originalInternet = Host.Device.Configuration.EnableInternetAccess;
            uint sm = SmSession();
            uint bsd = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
            Msg reg = Msg.Cmif(0, new byte[0x30]);
            reg.SendPid = true;
            reg.Copy.Add(0xFFFF8001);
            Call(bsd, reg);

            int CreateAndInspect(out int hostDelta)
            {
                int before = HostInetSockets();
                Reply reply = Call(bsd, Msg.Cmif(2, Bytes(2, 2, 17)));   // AF_INET / SOCK_DGRAM / UDP
                int fd = *(int*)reply.Data;
                hostDelta = fd >= 0 ? HostInetSockets() - before : -1;

                if (fd >= 0)
                {
                    ISocket socket = BsdContext.GetContext(FakeNative.GamePid)!.RetrieveSocket(fd)!;
                    ManagedSocket managed = (ManagedSocket)socket;

                    if (managed.Socket is not (OfflineSocket or DefaultSocket))
                    {
                        throw new InvalidOperationException($"unexpected socket implementation: {managed.Socket.GetType().Name}");
                    }

                    bool expected = managed.Socket switch
                    {
                        DefaultSocket => Host.Device.Configuration.MultiplayerMode == MultiplayerMode.LdnMitm,
                        OfflineSocket => Host.Device.Configuration.MultiplayerMode == MultiplayerMode.Disabled,
                        _ => false,
                    };

                    if (!expected)
                    {
                        throw new InvalidOperationException($"socket implementation does not match mode: {Host.Device.Configuration.MultiplayerMode} -> {managed.Socket.GetType().Name}");
                    }
                }

                if (fd >= 0)
                {
                    Call(bsd, Msg.Cmif(26, Bytes(fd)));
                }

                return fd;
            }

            try
            {
                Host.Device.Configuration.MultiplayerMode = MultiplayerMode.Disabled;
                int offlineFd = CreateAndInspect(out int offlineDelta);

                Host.Device.Configuration.MultiplayerMode = MultiplayerMode.LdnMitm;
                int ldnFd = CreateAndInspect(out int ldnDelta);

                Check("ldn_mitm：Disabled 负对照仍是离线 socket；LdnMitm 游戏 socket 是宿主局域网 socket",
                    "True/True/True/True/False",
                    $"{offlineFd >= 0}/{ldnFd >= 0}/{offlineDelta == 0}/{ldnDelta == 1}/{Host.Device.Configuration.EnableInternetAccess}");
            }
            finally
            {
                Host.Device.Configuration.MultiplayerMode = originalMode;
                Host.Device.Configuration.EnableInternetAccess = originalInternet;
                FakeNative.HandleClose(bsd);
                FakeNative.HandleClose(sm);
            }
        }
    }
}
