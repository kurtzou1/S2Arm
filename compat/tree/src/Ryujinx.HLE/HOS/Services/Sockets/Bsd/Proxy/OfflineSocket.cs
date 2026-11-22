using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl;
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy
{
    /// <summary>
    /// S2Arm: a socket of a console that is not connected to any network (internet access disabled).
    /// The Switch socket stack (FreeBSD-derived) then only has the loopback interface: creating, binding and polling sockets works,
    /// loopback UDP is delivered locally, and anything that needs a route to another host fails the way FreeBSD fails without a route
    /// (connect / sendto: ENETUNREACH). No host socket is ever opened, so the host OS sees no network activity
    /// (on iOS the first network access raises the "allow wireless data" prompt over the game).
    /// TCP over loopback works between sockets of the same console (S2Arm, D-BE82: asio's select interrupter listens on 127.0.0.1, connects to
    /// itself and accepts, then wakes its own select by writing a byte; a refused connect made a racing game assert at start): a connect to a
    /// listening local port makes a connected pair (the server end waits in the listener's accept queue), and each end's writes are the other
    /// end's byte stream. A loopback connect to a port nobody listens on is refused (ECONNREFUSED), as FreeBSD does.
    /// </summary>
    class OfflineSocket : ISocketImpl
    {
        // Ephemeral port range of FreeBSD (net.inet.ip.portrange.first / last)
        private const int EphemeralFirst = 49152;
        private const int EphemeralLast = 65535;

        // Receive buffer of a UDP socket (Switch default udp_rx_buf_size 0xA500): datagrams beyond it are dropped, as a full socket buffer does
        private const int ReceiveBufferBytes = 0xA500;

        // One lock for the whole offline network: guards the port table and every socket's state, and is the wait / wake primitive for blocking
        // receive / accept and select / poll (a loopback datagram or a close wakes all waiters, which re-check their own condition).
        private static readonly object _network = new();

        // S2Arm: shutdown wakes selects waiting on the offline network (Ryujinx.Common.S2AShutdown)
        static OfflineSocket()
        {
            S2AShutdown.OnRequest(() =>
            {
                lock (_network)
                {
                    Monitor.PulseAll(_network);
                }
            });
        }
        private static readonly Dictionary<(ProtocolType, int), OfflineSocket> _ports = new();
        private static int _nextEphemeral = EphemeralFirst;

        private readonly Queue<(byte[] Data, IPEndPoint From)> _receiveQueue = new();
        private int _queuedBytes;
        private readonly Dictionary<SocketOptionName, int> _options = new();
        private bool _listening;
        private int _backlog;
        // TCP over loopback: the other end of this connection, the bytes written to this end by the peer, and (listening) the connected
        //   server ends waiting for Accept
        private const int StreamBufferBytes = 0x40000;
        private OfflineSocket _peer;
        private readonly List<byte> _stream = new();
        private readonly Queue<OfflineSocket> _acceptQueue = new();
        private bool _readShutdown;
        private bool _writeShutdown;
        private bool _closed;

        public EndPoint RemoteEndPoint { get; private set; }

        public EndPoint LocalEndPoint { get; private set; }

        public bool Connected { get; private set; }

        public bool IsBound { get; private set; }

        public AddressFamily AddressFamily { get; }

        public SocketType SocketType { get; }

        public ProtocolType ProtocolType { get; }

        public bool Blocking { get; set; } = true;

        public int Available
        {
            get
            {
                lock (_network)
                {
                    return SocketType == SocketType.Stream ? _stream.Count : _receiveQueue.Count > 0 ? _receiveQueue.Peek().Data.Length : 0;
                }
            }
        }

        public OfflineSocket(AddressFamily addressFamily, SocketType socketType, ProtocolType protocolType)
        {
            if (addressFamily != AddressFamily.InterNetwork && addressFamily != AddressFamily.InterNetworkV6)
            {
                throw new SocketException((int)SocketError.AddressFamilyNotSupported);
            }

            if (socketType != SocketType.Stream && socketType != SocketType.Dgram)
            {
                throw new SocketException((int)SocketError.SocketNotSupported);
            }

            AddressFamily = addressFamily;
            SocketType = socketType;
            ProtocolType = protocolType;
        }

        // The peer of a loopback TCP connection closed or shut down its sending side: reads return end of stream once the bytes are drained
        private bool PeerGone => _peer != null && (_peer._closed || _peer._writeShutdown);

        // Readable: a datagram is queued / stream bytes are waiting / the peer is gone (end of stream) / a connection waits to be accepted,
        //   or the read side is shut down / closed (a read returns at once)
        public bool Readable => _closed || _readShutdown ||
            (_listening ? _acceptQueue.Count > 0 : SocketType == SocketType.Stream ? _stream.Count > 0 || PeerGone : _receiveQueue.Count > 0);

        // Writable: a UDP socket always has send buffer space; a TCP socket once connected and while the peer's buffer has room
        //   (a peer that is gone reports writable too, so the write returns its error at once)
        public bool Writable => SocketType == SocketType.Dgram ? !_writeShutdown :
            Connected && (_writeShutdown || _peer == null || _peer._closed || _peer._readShutdown || _peer._stream.Count < StreamBufferBytes);

        private static bool IsLocal(IPAddress address)
        {
            return IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any);
        }

        // S2Arm（#1285 取证）：离线网络上返回给游戏的错误记前 32 次（哪个操作、什么错）。DOOM 离线时反复建 UDP 套接字、绑 27016 后立刻关、
        //   游戏记 InitPort -1，日志里看不出是哪一步回了错
        private static int _errorsLogged;
        private static SocketException Error(SocketError error, [System.Runtime.CompilerServices.CallerMemberName] string op = "")
        {
            if (Interlocked.Increment(ref _errorsLogged) <= 32)
            {
                Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Offline console: {op} returns {error} to the game");
            }

            return new SocketException((int)error);
        }

        // Caller holds _network
        private int AllocatePort()
        {
            for (int i = 0; i <= EphemeralLast - EphemeralFirst; i++)
            {
                int port = _nextEphemeral;

                _nextEphemeral = port == EphemeralLast ? EphemeralFirst : port + 1;

                if (!_ports.ContainsKey((ProtocolType, port)))
                {
                    return port;
                }
            }

            throw Error(SocketError.AddressAlreadyInUse);
        }

        // Caller holds _network
        private void BindLocked(IPEndPoint localEndPoint)
        {
            if (_closed)
            {
                throw Error(SocketError.NotSocket);
            }

            if (IsBound)
            {
                throw Error(SocketError.InvalidArgument);
            }

            if (!IsLocal(localEndPoint.Address))
            {
                throw Error(SocketError.AddressNotAvailable);
            }

            int port = localEndPoint.Port == 0 ? AllocatePort() : localEndPoint.Port;

            if (_ports.ContainsKey((ProtocolType, port)))
            {
                throw Error(SocketError.AddressAlreadyInUse);
            }

            _ports[(ProtocolType, port)] = this;
            LocalEndPoint = new IPEndPoint(localEndPoint.Address, port);
            IsBound = true;
        }

        // Caller holds _network. An unbound socket that sends gets an ephemeral port on the wildcard address (FreeBSD in_pcbbind on first use)
        private void EnsureBoundLocked()
        {
            if (!IsBound)
            {
                BindLocked(new IPEndPoint(AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any, 0));
            }
        }

        public void Bind(EndPoint localEP)
        {
            lock (_network)
            {
                BindLocked((IPEndPoint)localEP);
            }
        }

        public void Connect(EndPoint remoteEP)
        {
            IPEndPoint remote = (IPEndPoint)remoteEP;

            lock (_network)
            {
                if (SocketType == SocketType.Stream)
                {
                    if (Connected)
                    {
                        throw Error(SocketError.IsConnected);
                    }

                    if (IsLocal(remote.Address))
                    {
                        // FreeBSD queues up to 3/2 of the backlog (sonewconn: so_qlen > 3 * so_qlimit / 2 refuses)
                        if (_ports.TryGetValue((ProtocolType, remote.Port), out OfflineSocket listener) && listener._listening && !listener._closed &&
                            listener._acceptQueue.Count <= 3 * Math.Max(listener._backlog, 1) / 2)
                        {
                            EnsureBoundLocked();

                            IPAddress loopback = IPAddress.IsLoopback(remote.Address) ? remote.Address : (AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Loopback : IPAddress.Loopback);
                            OfflineSocket server = new(listener.AddressFamily, SocketType.Stream, ProtocolType)
                            {
                                LocalEndPoint = new IPEndPoint(loopback, remote.Port),
                                RemoteEndPoint = new IPEndPoint(loopback, ((IPEndPoint)LocalEndPoint).Port),
                                IsBound = true,
                                Connected = true,
                                _peer = this,
                            };

                            _peer = server;
                            RemoteEndPoint = new IPEndPoint(loopback, remote.Port);
                            Connected = true;
                            listener._acceptQueue.Enqueue(server);

                            Monitor.PulseAll(_network);
                            S2ABsdWake.Signal();

                            return;
                        }

                        Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Offline: TCP loopback connect to port {remote.Port} refused (nobody listens there)");

                        throw Error(SocketError.ConnectionRefused);
                    }

                    throw Error(SocketError.NetworkUnreachable);
                }

                if (!IsLocal(remote.Address))
                {
                    throw Error(SocketError.NetworkUnreachable);
                }

                EnsureBoundLocked();
                RemoteEndPoint = new IPEndPoint(IPAddress.IsLoopback(remote.Address) ? remote.Address : IPAddress.Loopback, remote.Port);
                Connected = true;
            }
        }

        public void Disconnect(bool reuseSocket)
        {
            lock (_network)
            {
                RemoteEndPoint = null;
                Connected = false;
            }
        }

        public void Listen(int backlog)
        {
            lock (_network)
            {
                if (SocketType != SocketType.Stream)
                {
                    throw Error(SocketError.OperationNotSupported);
                }

                EnsureBoundLocked();
                _listening = true;
                _backlog = backlog;
            }
        }

        public ISocketImpl Accept()
        {
            lock (_network)
            {
                if (!_listening)
                {
                    throw Error(SocketError.InvalidArgument);
                }

                // Only sockets of this console connect (over loopback): accept takes the next of those, or waits for one
                while (_acceptQueue.Count == 0 && !_closed && !S2AShutdown.Requested)
                {
                    if (!Blocking)
                    {
                        throw Error(SocketError.WouldBlock);
                    }

                    Monitor.Wait(_network);
                }

                if (S2AShutdown.Requested)
                {
                    throw Error(SocketError.Interrupted);
                }

                if (_acceptQueue.Count > 0)
                {
                    return _acceptQueue.Dequeue();
                }

                throw Error(SocketError.ConnectionAborted);
            }
        }

        public int Send(ReadOnlySpan<byte> buffer)
        {
            return Send(buffer, SocketFlags.None);
        }

        public int Send(ReadOnlySpan<byte> buffer, SocketFlags flags)
        {
            int sent = Send(buffer, flags, out SocketError error);

            return error == SocketError.Success ? sent : throw Error(error);
        }

        public int Send(ReadOnlySpan<byte> buffer, SocketFlags flags, out SocketError socketError)
        {
            lock (_network)
            {
                if (!Connected)
                {
                    socketError = SocketType == SocketType.Dgram ? SocketError.DestinationAddressRequired : SocketError.NotConnected;

                    return -1;
                }

                return SocketType == SocketType.Stream ? StreamSendLocked(buffer, out socketError) : SendToLocked(buffer, (IPEndPoint)RemoteEndPoint, out socketError);
            }
        }

        public int SendTo(ReadOnlySpan<byte> buffer, SocketFlags flags, EndPoint remoteEP)
        {
            lock (_network)
            {
                if (SocketType == SocketType.Stream)
                {
                    throw Error(Connected ? SocketError.IsConnected : SocketError.NotConnected);
                }

                int sent = SendToLocked(buffer, (IPEndPoint)remoteEP, out SocketError error);

                return error == SocketError.Success ? sent : throw Error(error);
            }
        }

        // Caller holds _network. TCP over loopback: append to the peer's stream; a blocking send waits for room until everything is written,
        //   a non-blocking one writes what fits (WouldBlock when nothing fits). A peer that closed or stopped reading: connection reset (EPIPE side)
        private int StreamSendLocked(ReadOnlySpan<byte> buffer, out SocketError socketError)
        {
            int sent = 0;

            while (true)
            {
                if (_writeShutdown)
                {
                    socketError = SocketError.Shutdown;

                    return -1;
                }

                if (_peer == null || _peer._closed || _peer._readShutdown)
                {
                    socketError = SocketError.ConnectionReset;

                    return sent > 0 ? sent : -1;
                }

                int room = StreamBufferBytes - _peer._stream.Count;

                if (room > 0)
                {
                    int n = Math.Min(room, buffer.Length - sent);

                    _peer._stream.AddRange(buffer.Slice(sent, n).ToArray());
                    sent += n;

                    Monitor.PulseAll(_network);
                    S2ABsdWake.Signal();
                }

                if (sent == buffer.Length)
                {
                    socketError = SocketError.Success;

                    return sent;
                }

                if (!Blocking)
                {
                    socketError = sent > 0 ? SocketError.Success : SocketError.WouldBlock;

                    return sent > 0 ? sent : -1;
                }

                if (S2AShutdown.Requested)
                {
                    socketError = SocketError.Interrupted;

                    return sent > 0 ? sent : -1;
                }

                Monitor.Wait(_network);
            }
        }

        // Caller holds _network. UDP only.
        private int SendToLocked(ReadOnlySpan<byte> buffer, IPEndPoint remote, out SocketError socketError)
        {
            if (_writeShutdown)
            {
                socketError = SocketError.Shutdown;

                return -1;
            }

            if (remote.Address.Equals(IPAddress.Broadcast))
            {
                // FreeBSD: broadcast needs SO_BROADCAST (EACCES), and no up interface can broadcast (lo0 cannot): ENETUNREACH
                socketError = _options.GetValueOrDefault(SocketOptionName.Broadcast) == 0 ? SocketError.AccessDenied : SocketError.NetworkUnreachable;

                return -1;
            }

            if (!IsLocal(remote.Address))
            {
                socketError = SocketError.NetworkUnreachable;

                return -1;
            }

            EnsureBoundLocked();

            IPEndPoint from = new(IPAddress.IsLoopback(remote.Address) ? remote.Address : IPAddress.Loopback, ((IPEndPoint)LocalEndPoint).Port);

            if (_ports.TryGetValue((ProtocolType, remote.Port), out OfflineSocket target) && target.Accepts(from) &&
                target._queuedBytes + buffer.Length <= ReceiveBufferBytes)
            {
                target._receiveQueue.Enqueue((buffer.ToArray(), from));
                target._queuedBytes += buffer.Length;

                Monitor.PulseAll(_network);
                S2ABsdWake.Signal();   // S2Arm: mixed selects (eventfd + offline socket) wait on this
            }

            socketError = SocketError.Success;

            return buffer.Length;
        }

        // Caller holds _network. A connected UDP socket only takes datagrams from its peer.
        private bool Accepts(IPEndPoint from)
        {
            return !_closed && !_readShutdown && (!Connected || RemoteEndPoint.Equals(from));
        }

        public int Receive(Span<byte> buffer)
        {
            return Receive(buffer, SocketFlags.None);
        }

        public int Receive(Span<byte> buffer, SocketFlags flags)
        {
            EndPoint from = null;

            return ReceiveFrom(buffer, flags, ref from);
        }

        public int Receive(Span<byte> buffer, SocketFlags flags, out SocketError socketError)
        {
            try
            {
                socketError = SocketError.Success;

                return Receive(buffer, flags);
            }
            catch (SocketException exception)
            {
                socketError = exception.SocketErrorCode;

                return -1;
            }
        }

        public int ReceiveFrom(Span<byte> buffer, SocketFlags flags, ref EndPoint remoteEP)
        {
            lock (_network)
            {
                int timeout = _options.GetValueOrDefault(SocketOptionName.ReceiveTimeout);
                long sdeadline = timeout > 0 ? Environment.TickCount64 + timeout : long.MaxValue;

                if (SocketType == SocketType.Stream)
                {
                    if (_listening || !Connected)
                    {
                        throw Error(SocketError.NotConnected);
                    }

                    // TCP over loopback: wait for bytes, end of stream (peer gone: 0) or our own shutdown / close
                    while (_stream.Count == 0 && !PeerGone && !_readShutdown && !_closed && !S2AShutdown.Requested)
                    {
                        if (!Blocking)
                        {
                            throw Error(SocketError.WouldBlock);
                        }

                        long sleft = sdeadline - Environment.TickCount64;

                        if (sleft <= 0)
                        {
                            throw Error(SocketError.WouldBlock);
                        }

                        Monitor.Wait(_network, sdeadline == long.MaxValue ? Timeout.Infinite : (int)Math.Min(sleft, int.MaxValue));
                    }

                    if (S2AShutdown.Requested)
                    {
                        throw Error(SocketError.Interrupted);
                    }

                    int got = Math.Min(_stream.Count, buffer.Length);

                    for (int i = 0; i < got; i++)
                    {
                        buffer[i] = _stream[i];
                    }

                    if (!flags.HasFlag(SocketFlags.Peek) && got > 0)
                    {
                        _stream.RemoveRange(0, got);

                        Monitor.PulseAll(_network);   // room for a blocked sender
                        S2ABsdWake.Signal();
                    }

                    remoteEP = RemoteEndPoint;

                    return got;
                }
                long deadline = timeout > 0 ? Environment.TickCount64 + timeout : long.MaxValue;

                while (_receiveQueue.Count == 0 && !_readShutdown && !_closed && !S2AShutdown.Requested)
                {
                    if (!Blocking)
                    {
                        throw Error(SocketError.WouldBlock);
                    }

                    long left = deadline - Environment.TickCount64;

                    if (left <= 0)
                    {
                        throw Error(SocketError.WouldBlock);
                    }

                    Monitor.Wait(_network, deadline == long.MaxValue ? Timeout.Infinite : (int)Math.Min(left, int.MaxValue));
                }

                if (S2AShutdown.Requested)
                {
                    throw Error(SocketError.Interrupted);
                }

                if (_receiveQueue.Count == 0)
                {
                    return 0;
                }

                (byte[] data, IPEndPoint from) = flags.HasFlag(SocketFlags.Peek) ? _receiveQueue.Peek() : _receiveQueue.Dequeue();

                if (!flags.HasFlag(SocketFlags.Peek))
                {
                    _queuedBytes -= data.Length;
                }

                // A datagram longer than the buffer is truncated, the rest is discarded (UDP semantics)
                int length = Math.Min(data.Length, buffer.Length);

                data.AsSpan(0, length).CopyTo(buffer);
                remoteEP = from;

                return length;
            }
        }

        public bool Poll(int microSeconds, SelectMode mode)
        {
            lock (_network)
            {
                long deadline = microSeconds < 0 ? long.MaxValue : Environment.TickCount64 + microSeconds / 1000;

                while (!S2AShutdown.Requested)
                {
                    bool ready = mode switch
                    {
                        SelectMode.SelectRead => Readable,
                        SelectMode.SelectWrite => Writable,
                        _ => false,
                    };

                    long left = deadline - Environment.TickCount64;

                    if (ready || left <= 0)
                    {
                        return ready;
                    }

                    Monitor.Wait(_network, deadline == long.MaxValue ? Timeout.Infinite : (int)Math.Min(left, int.MaxValue));
                }

                throw Error(SocketError.Interrupted);
            }
        }

        /// <summary>
        /// Select over offline sockets: keeps in each list only the ready sockets, waiting up to <paramref name="microSeconds"/> (-1 = forever)
        /// for at least one to become ready. Offline sockets never have a pending error, so the error list is always emptied.
        /// </summary>
        public static void Select(List<OfflineSocket> read, List<OfflineSocket> write, List<OfflineSocket> error, int microSeconds)
        {
            lock (_network)
            {
                long deadline = microSeconds < 0 ? long.MaxValue : Environment.TickCount64 + microSeconds / 1000;

                while (!S2AShutdown.Requested && !read.Exists(s => s.Readable) && !write.Exists(s => s.Writable))
                {
                    long left = deadline - Environment.TickCount64;

                    if (left <= 0)
                    {
                        break;
                    }

                    Monitor.Wait(_network, deadline == long.MaxValue ? Timeout.Infinite : (int)Math.Min(left, int.MaxValue));
                }

                read.RemoveAll(s => !s.Readable);
                write.RemoveAll(s => !s.Writable);
                error.Clear();
            }
        }

        public void GetSocketOption(SocketOptionLevel optionLevel, SocketOptionName optionName, byte[] optionValue)
        {
            int value;

            lock (_network)
            {
                value = optionName switch
                {
                    SocketOptionName.Type => (int)SocketType,
                    SocketOptionName.Error => 0,
                    SocketOptionName.AcceptConnection => _listening ? 1 : 0,
                    SocketOptionName.ReceiveBuffer when !_options.ContainsKey(optionName) => ReceiveBufferBytes,
                    _ => _options.GetValueOrDefault(optionName),
                };
            }

            Array.Clear(optionValue);
            BitConverter.GetBytes(value).AsSpan(0, Math.Min(sizeof(int), optionValue.Length)).CopyTo(optionValue);
        }

        public void SetSocketOption(SocketOptionLevel optionLevel, SocketOptionName optionName, int optionValue)
        {
            lock (_network)
            {
                _options[optionName] = optionValue;
            }
        }

        public void SetSocketOption(SocketOptionLevel optionLevel, SocketOptionName optionName, object optionValue)
        {
            SetSocketOption(optionLevel, optionName, optionValue is LingerOption linger ? (linger.Enabled ? 1 : 0) : Convert.ToInt32(optionValue));
        }

        public void Shutdown(SocketShutdown how)
        {
            lock (_network)
            {
                if (!Connected)
                {
                    throw Error(SocketError.NotConnected);
                }

                _readShutdown |= how != SocketShutdown.Send;
                _writeShutdown |= how != SocketShutdown.Receive;

                Monitor.PulseAll(_network);
                S2ABsdWake.Signal();
            }
        }

        public void Close()
        {
            lock (_network)
            {
                if (_closed)
                {
                    return;
                }

                _closed = true;

                if (IsBound && _ports.TryGetValue((ProtocolType, ((IPEndPoint)LocalEndPoint).Port), out OfflineSocket owner) && owner == this)
                {
                    _ports.Remove((ProtocolType, ((IPEndPoint)LocalEndPoint).Port));
                }

                _receiveQueue.Clear();
                _queuedBytes = 0;
                _stream.Clear();

                // Connections nobody accepted are reset (their connecting ends see end of stream / reset)
                while (_acceptQueue.Count > 0)
                {
                    OfflineSocket pending = _acceptQueue.Dequeue();

                    pending._closed = true;
                }

                Monitor.PulseAll(_network);
                S2ABsdWake.Signal();
            }
        }

        public void Dispose()
        {
            Close();
        }
    }
}
