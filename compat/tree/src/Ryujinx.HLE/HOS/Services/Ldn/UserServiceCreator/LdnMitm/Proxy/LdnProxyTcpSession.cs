using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using System.Net;
using System.Net.Sockets;

namespace Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnMitm.Proxy
{
    internal class LdnProxyTcpSession : NetCoreServer.TcpSession
    {
        private readonly LanProtocol _protocol;

        internal int NodeId;
        internal NodeInfo NodeInfo;
        internal bool HandshakeComplete { get; private set; }

        private byte[] _buffer;
        private int _bufferEnd;

        public LdnProxyTcpSession(LdnProxyTcpServer server, LanProtocol protocol) : base(server)
        {
            _protocol = protocol;
            _protocol.Connect += OnConnect;
            _buffer = new byte[LanProtocol.BufferSize];
            OptionSendBufferSize = LanProtocol.TcpTxBufferSize;
            OptionReceiveBufferSize = LanProtocol.TcpRxBufferSize;
            OptionSendBufferLimit = LanProtocol.TxBufferSizeMax;
            OptionReceiveBufferLimit = LanProtocol.RxBufferSizeMax;
        }

        public void OverrideInfo()
        {
            NodeInfo.NodeId = (byte)NodeId;
            NodeInfo.IsConnected = (byte)(HandshakeComplete && IsConnected ? 1 : 0);
        }

        // Socket.RemoteEndPoint throws ObjectDisposedException once the socket is gone; every
        // diagnostic line must go through here so logging can never take down the receive thread.
        private string SafeRemoteEp()
        {
            try
            {
                return Socket.RemoteEndPoint?.ToString() ?? "(null)";
            }
            catch (System.ObjectDisposedException)
            {
                return "(disposed)";
            }
        }

        protected override void OnConnected()
        {
            Logger.Info?.PrintMsg(LogClass.ServiceLdn, "LdnProxyTCPSession connected!");
            Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"[DIAG] TCP OnConnected remote={SafeRemoteEp()}");
            _protocol.InvokeAccept(this);
        }

        protected override void OnDisconnected()
        {
            Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"[DIAG] TCP OnDisconnected remote={SafeRemoteEp()} handshake={HandshakeComplete} node={NodeId}");
            Logger.Info?.PrintMsg(LogClass.ServiceLdn, "LdnProxyTCPSession disconnected!");

            _protocol.InvokeDisconnectStation(this);
        }

        protected override void OnReceived(byte[] buffer, long offset, long size)
        {
            Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"[DIAG] TCP OnReceived {size} bytes from {SafeRemoteEp()}");
            _protocol.Read(ref _buffer, ref _bufferEnd, buffer, (int)offset, (int)size, this.Socket.RemoteEndPoint, this);
        }

        protected override void OnError(SocketError error)
        {
            Logger.Error?.PrintMsg(LogClass.ServiceLdn, $"LdnProxyTCPSession caught an error with code {error}");

            Dispose();
        }

        protected override void Dispose(bool disposingManagedResources)
        {
            _protocol.Connect -= OnConnect;
            base.Dispose(disposingManagedResources);
        }

        private void OnConnect(NodeInfo info, EndPoint endPoint, LdnProxyTcpSession via)
        {
            Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"[DIAG] OnConnect fired on node={NodeId}: frameEP={endPoint} sessionEP={SafeRemoteEp()} via={(via != null ? $"session#{via.NodeId}" : "null")}");
            try
            {
                // LanProtocol.Connect is shared by every accepted station. A frame that arrived on
                // a known TCP session (via != null) belongs to that session alone — route by object
                // identity. Endpoint equality is only the fallback for callers that pass no session
                // (unit tests, UDP-originated frames); compare values, tolerating IPv4-mapped IPv6
                // spellings of the same peer that a dual-stack socket can report.
                bool mine;
                if (via != null)
                {
                    mine = ReferenceEquals(via, this);
                }
                else if (endPoint != null)
                {
                    mine = EndPointMatches(endPoint, Socket.RemoteEndPoint);
                }
                else
                {
                    mine = false;
                }

                if (!mine)
                {
                    Logger.Warning?.PrintMsg(LogClass.ServiceLdn, $"[DIAG] OnConnect DROPPED (not this session's frame): frameEP={endPoint} sessionEP={SafeRemoteEp()}");
                    return;
                }

                NodeInfo = info;
                HandshakeComplete = true;
                Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"[DIAG] OnConnect ACCEPTED node={NodeId}: handshake complete, invoking StationConnected");
                _protocol.InvokeStationConnected(this);
            }
            catch (System.ObjectDisposedException)
            {
                Logger.Error?.PrintMsg(LogClass.ServiceLdn, $"LdnProxyTCPSession was disposed. [IP: {NodeInfo.Ipv4Address}]");

                _protocol.InvokeDisconnectStation(this);
            }
        }

        // Value comparison of two endpoints, treating IPv4-mapped IPv6 (::ffff:a.b.c.d) and plain
        // IPv4 (a.b.c.d) as the same peer. EndPoint.Equals is strict about address family, so a
        // dual-stack accept socket could report the same client in two spellings across calls.
        private static bool EndPointMatches(EndPoint a, EndPoint b)
        {
            if (a == null || b == null)
            {
                return false;
            }

            if (a is not IPEndPoint ipa || b is not IPEndPoint ipb)
            {
                return a.Equals(b);
            }

            return ipa.Port == ipb.Port && AddressMatches(ipa.Address, ipb.Address);
        }

        private static bool AddressMatches(IPAddress a, IPAddress b)
        {
            if (a.Equals(b))
            {
                return true;
            }

            if (a.IsIPv4MappedToIPv6 && b.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
            {
                return a.MapToIPv4().Equals(b);
            }

            if (b.IsIPv4MappedToIPv6 && a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
            {
                return b.MapToIPv4().Equals(a);
            }

            return false;
        }
    }
}
