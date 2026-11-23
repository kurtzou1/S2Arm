using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using System;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        [SoloTest("--ldn-auto-ryu-server-fallback")]
        private static int LdnAutoRyuServerFallback()
        {
            // Automatic mode can construct the dual-protocol client before a LAN relay
            // has been elected. MultiplayerLdnServer is then the empty string, not null.
            // The empty address must fall back to loopback or LdnMasterProxyClient throws
            // "An invalid IP address was specified" and takes the whole client down.
            string fromEmpty = LdnAutoClient.ResolveRyuServer(string.Empty);
            string fromNull = LdnAutoClient.ResolveRyuServer(null);
            string fromReal = LdnAutoClient.ResolveRyuServer("192.168.31.77");

            bool ok = fromEmpty == "127.0.0.1" && fromNull == "127.0.0.1" && fromReal == "192.168.31.77";
            Console.WriteLine(
                $"ldn-auto-ryu-server-fallback: empty={fromEmpty}, null={fromNull}, real={fromReal}");
            return ok ? 0 : 1;
        }

        [SoloTest("--ldn-auto-mode-selection")]
        private static int LdnAutoModeSelection()
        {
            NetworkInfo ryuRoom = Room(0x11);
            NetworkInfo mitmRoom = Room(0x22);

            FakeLdnNetworkClient ryu = new([ryuRoom]);
            FakeLdnNetworkClient mitm = new([mitmRoom]);
            using (LdnAutoClient auto = new(null, mitm, ryu))
            {
                NetworkInfo[] rooms = auto.Scan(0, default);
                bool merged = rooms.Length == 2;

                auto.Connect(new ConnectRequest { NetworkInfo = ryuRoom });
                auto.Connect(new ConnectRequest { NetworkInfo = mitmRoom });

                bool routed = ryu.ConnectCount == 1 && mitm.ConnectCount == 1;
                Console.WriteLine(
                    $"ldn-auto-mode-selection: merged={merged}, ryuConnects={ryu.ConnectCount}, mitmConnects={mitm.ConnectCount}");

                if (!merged || !routed)
                {
                    return 1;
                }
            }

            FakeLdnNetworkClient defaultRyu = new([]);
            FakeLdnNetworkClient defaultMitm = new([]);
            using (LdnAutoClient auto = new(null, defaultMitm, defaultRyu))
            {
                auto.CreateNetwork(default, []);
                if (defaultMitm.CreateCount != 1 || defaultRyu.CreateCount != 0)
                {
                    Console.WriteLine("ldn-auto-mode-selection: no discovered Ryu peer did not default to ldn_mitm");
                    return 1;
                }
            }

            FakeLdnNetworkClient seenRyu = new([ryuRoom]);
            FakeLdnNetworkClient seenMitm = new([]);
            using (LdnAutoClient auto = new(null, seenMitm, seenRyu))
            {
                auto.Scan(0, default);
                auto.CreateNetwork(default, []);
                if (seenMitm.CreateCount != 1 || seenRyu.CreateCount != 0)
                {
                    Console.WriteLine("ldn-auto-mode-selection: host creation did not default to ldn_mitm");
                    return 1;
                }
            }

            return 0;
        }

        private static NetworkInfo Room(byte session)
        {
            NetworkInfo info = new();
            info.NetworkId.IntentId.LocalCommunicationId = 0x01000BF0152FA000;
            info.NetworkId.SessionId[0] = session;
            info.Common.Ssid.Length = 4;
            info.Common.Ssid.Name[0] = (byte)'s';
            info.Common.Ssid.Name[1] = (byte)'2';
            info.Common.Ssid.Name[2] = (byte)'a';
            info.Common.Ssid.Name[3] = (byte)'r';
            info.Ldn.NodeCount = 1;
            return info;
        }

        private sealed class FakeLdnNetworkClient : INetworkClient
        {
            private readonly NetworkInfo[] _rooms;

            public FakeLdnNetworkClient(NetworkInfo[] rooms)
            {
                _rooms = rooms;
            }

            public ProxyConfig Config => default;
            public bool NeedsRealId => true;
            public int ConnectCount { get; private set; }
            public int CreateCount { get; private set; }

            public event EventHandler<NetworkChangeEventArgs> NetworkChange
            {
                add { }
                remove { }
            }

            public void DisconnectNetwork() { }
            public void DisconnectAndStop() { }

            public NetworkError Connect(ConnectRequest request)
            {
                ConnectCount++;
                return NetworkError.None;
            }

            public NetworkError ConnectPrivate(ConnectPrivateRequest request)
            {
                ConnectCount++;
                return NetworkError.None;
            }

            public ResultCode Reject(DisconnectReason disconnectReason, uint nodeId)
            {
                return ResultCode.Success;
            }

            public NetworkInfo[] Scan(ushort channel, ScanFilter scanFilter)
            {
                return _rooms;
            }

            public void SetGameVersion(ReadOnlySpan<byte> versionString) { }
            public void SetStationAcceptPolicy(AcceptPolicy acceptPolicy) { }
            public void SetAdvertiseData(byte[] data) { }

            public bool CreateNetwork(CreateAccessPointRequest request, byte[] advertiseData)
            {
                CreateCount++;
                return true;
            }

            public bool CreateNetworkPrivate(CreateAccessPointPrivateRequest request, byte[] advertiseData)
            {
                CreateCount++;
                return true;
            }

            public void Dispose() { }
        }
    }
}
