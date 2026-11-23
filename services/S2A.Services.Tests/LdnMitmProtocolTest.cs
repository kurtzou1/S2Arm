using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnMitm;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnMitm.Proxy;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnMitm.Types;
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // ldn_mitm 的通用线协议回归：不按游戏 / 程序号分支，期望值来自网络字节序与原版 accept 后立即登记站点的行为。
        [SoloTest("--ldn-mitm-protocol")]
        private static int LdnMitmProtocolTest()
        {
            int failures = 0;

            void Expect(bool ok, string name, string actual)
            {
                Console.WriteLine($"{(ok ? "通过" : "【红】")} {name}：{actual}");
                if (!ok)
                {
                    failures++;
                }
            }

            // ① 192.168.5.26/24 的广播地址必须是 192.168.5.255；IPAddress 字节是网络序，不能按宿主机序解释。
            MethodInfo broadcast = typeof(LanDiscovery).GetMethod(
                "GetBroadcastAddress", BindingFlags.NonPublic | BindingFlags.Static)
                ?? throw new MissingMethodException(nameof(LanDiscovery), "GetBroadcastAddress");
            IPAddress broadcastActual = (IPAddress)broadcast.Invoke(
                null, [IPAddress.Parse("192.168.5.26"), IPAddress.Parse("255.255.255.0")])!;
            Expect(broadcastActual.Equals(IPAddress.Parse("192.168.5.255")),
                "IPv4 广播地址按网络字节序计算", broadcastActual.ToString());

            // ② 原版房主在 TCP accept 后立即 link 站点；C# 不能等到收到 Connect 才登记，否则加入握手超时 / 快速断开。
            LanProtocol acceptProtocol = new(null!);
            int acceptedCount = 0;
            acceptProtocol.Accept += _ => Interlocked.Increment(ref acceptedCount);

            using (LdnProxyTcpServer server = new(acceptProtocol, IPAddress.Loopback, 0))
            {
                Expect(server.Start(), "测试 TCP 房主可监听", server.Endpoint?.ToString() ?? "未启动");
                int port = ((IPEndPoint)server.Endpoint!).Port;

                using TcpClient client = new();
                client.Connect(IPAddress.Loopback, port);

                long deadline = Environment.TickCount64 + 2000;
                while (Environment.TickCount64 < deadline && Volatile.Read(ref acceptedCount) == 0)
                {
                    Thread.Sleep(10);
                }

                Expect(Volatile.Read(ref acceptedCount) == 1,
                    "TCP accept 后立即登记站点", $"accepted={Volatile.Read(ref acceptedCount)}");
            }

            // ③ TCP 是字节流：Connect 包任意分片后仍要还原成一个 NodeInfo。
            LanProtocol readProtocol = new(null!);
            NodeInfo received = default;
            int connectPackets = 0;
            readProtocol.Connect += (info, _, _) =>
            {
                received = info;
                Interlocked.Increment(ref connectPackets);
            };

            CaptureSocket capture = new();
            NodeInfo sent = new() { NodeId = 3, IsConnected = 1 };
            Expect(readProtocol.SendPacket(capture, LanPacketType.Connect,
                MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(ref sent, 1)).ToArray()) == 0,
                "构造 Connect 测试包", "发送成功");

            byte[] framed = new byte[capture.Data.Length + 8];
            capture.Data.CopyTo(framed, 8);
            byte[] receiveBuffer = new byte[LanProtocol.BufferSize];
            int bufferEnd = 0;
            readProtocol.Read(ref receiveBuffer, ref bufferEnd, framed, 8, 5);
            readProtocol.Read(ref receiveBuffer, ref bufferEnd, framed, 13, capture.Data.Length - 5);

            Expect(Volatile.Read(ref connectPackets) == 1 && received.NodeId == sent.NodeId && received.IsConnected == sent.IsConnected,
                "Connect 包跨 TCP 分片完整还原",
                $"packets={Volatile.Read(ref connectPackets)}, nodeId={received.NodeId}, connected={received.IsConnected}");

            // ⑤ 加入方收到房主主动断开时必须上报一次远端掉线；本地 Dispose / DisconnectAndStop 不得误报。
            LanProtocol disconnectProtocol = new(null!);
            int remoteDisconnects = 0;
            disconnectProtocol.ClientDisconnected += _ => Interlocked.Increment(ref remoteDisconnects);

            using (TcpListener remoteListener = new(IPAddress.Loopback, 0))
            {
                remoteListener.Start();
                int remotePort = ((IPEndPoint)remoteListener.LocalEndpoint).Port;
                using LdnProxyTcpClient client = new(disconnectProtocol, IPAddress.Loopback, remotePort);

                Expect(client.Connect(), "加入方 TCP 可连接测试房主", client.IsConnected ? "已连接" : "未连接");

                using TcpClient remoteAccepted = remoteListener.AcceptTcpClient();
                remoteAccepted.Close();

                long deadline = Environment.TickCount64 + 2000;
                while (Environment.TickCount64 < deadline && Volatile.Read(ref remoteDisconnects) == 0)
                {
                    Thread.Sleep(10);
                }

                int remoteDisconnectCount = Volatile.Read(ref remoteDisconnects);
                client.DisconnectAndStop();
                Thread.Sleep(50);

                Expect(remoteDisconnectCount == 1 && Volatile.Read(ref remoteDisconnects) == 1,
                    "远端断开只上报一次，主动关闭不重复误报",
                    $"远端断开时={remoteDisconnectCount}, 主动关闭后={Volatile.Read(ref remoteDisconnects)}");
            }

            // ④ Connect 是共享事件：包必须只完成它所属 TCP 连接的站点，不能把所有已连接站点改成同一个 NodeInfo。
            LanProtocol multiProtocol = new(null!);
            List<LdnProxyTcpSession> accepted = [];
            object acceptedLock = new();
            multiProtocol.Accept += session =>
            {
                lock (acceptedLock)
                {
                    accepted.Add(session);
                }
            };

            int AcceptedCount()
            {
                lock (acceptedLock)
                {
                    return accepted.Count;
                }
            }

            LdnProxyTcpSession AcceptedAt(int index)
            {
                lock (acceptedLock)
                {
                    return accepted[index];
                }
            }

            using (LdnProxyTcpServer multiServer = new(multiProtocol, IPAddress.Loopback, 0))
            {
                Expect(multiServer.Start(), "多站点测试 TCP 房主可监听", multiServer.Endpoint?.ToString() ?? "未启动");
                int port = ((IPEndPoint)multiServer.Endpoint!).Port;

                using TcpClient client1 = new();
                using TcpClient client2 = new();
                client1.Connect(IPAddress.Loopback, port);
                client2.Connect(IPAddress.Loopback, port);

                long deadline = Environment.TickCount64 + 2000;
                while (Environment.TickCount64 < deadline && AcceptedCount() < 2)
                {
                    Thread.Sleep(10);
                }

                if (AcceptedCount() == 2)
                {
                    NodeInfo info1 = new() { NodeId = 1, IsConnected = 1, Ipv4Address = 0x0100007F };
                    NodeInfo info2 = new() { NodeId = 2, IsConnected = 1, Ipv4Address = 0x0200007F };
                    LdnProxyTcpSession session1 = AcceptedAt(0);
                    LdnProxyTcpSession session2 = AcceptedAt(1);
                    EndPoint endpoint1 = session1.Socket.RemoteEndPoint!;
                    EndPoint endpoint2 = session2.Socket.RemoteEndPoint!;

                    multiProtocol.HandleConnect(info1, endpoint1);
                    multiProtocol.HandleConnect(info2, endpoint2);

                    Expect(session1.HandshakeComplete && session2.HandshakeComplete &&
                           session1.NodeInfo.NodeId == info1.NodeId &&
                           session2.NodeInfo.NodeId == info2.NodeId &&
                           session1.NodeInfo.Ipv4Address == info1.Ipv4Address &&
                           session2.NodeInfo.Ipv4Address == info2.Ipv4Address,
                        "两个站点的 Connect 状态与 NodeInfo 按远端 endpoint 隔离",
                        $"handshake={session1.HandshakeComplete}/{session2.HandshakeComplete}, " +
                        $"node={session1.NodeInfo.NodeId}/{session2.NodeInfo.NodeId}, " +
                        $"ip={session1.NodeInfo.Ipv4Address:X8}/{session2.NodeInfo.Ipv4Address:X8}");
                }
                else
                {
                    Expect(false, "两个 TCP 客户端均被房主接受", $"accepted={AcceptedCount()}");
                }
            }

            return failures == 0 ? 0 : 1;
        }

        private sealed class CaptureSocket : ILdnSocket
        {
            public byte[] Data { get; private set; }

            public bool SendPacketAsync(EndPoint endpoint, byte[] buffer)
            {
                Data = buffer;
                return true;
            }

            public bool Start() => true;
            public bool Stop() => true;
            public void Dispose() { }
        }
    }
}
