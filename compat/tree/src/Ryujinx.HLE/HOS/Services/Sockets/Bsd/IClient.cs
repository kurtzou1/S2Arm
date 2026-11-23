using Ryujinx.Common;
using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd
{
    [Service("bsd:s", true)]
    [Service("bsd:u", false)]
    class IClient : IpcService
    {
        private static readonly List<IPollManager> _pollManagers =
        [
            EventFileDescriptorPollManager.Instance,
            ManagedSocketPollManager.Instance
        ];

        private BsdContext _context;
        // S2Arm: the bsd client state belongs to the process (RegisterClient carries the pid). The Switch 2 SDK opens several bsd sessions
        //   for concurrency (nn::socket::detail::SetClientSessionCount / CreateClientServiceByHipc) and calls RegisterClient on one of them only;
        //   every session sends command 36 (and the monitor session StartMonitoring) with the pid first, which binds it to its process's context.
        //   Only the session that called RegisterClient disposes the context.
        private bool _registered;
        private readonly bool _isPrivileged;

        private void BindByPid(ServiceCtx context)
        {
            if (context.Request.HandleDesc is { HasPId: true })
            {
                _context ??= BsdContext.GetOrRegister(context.Request.HandleDesc.PId);
            }
        }

        private BsdContext Context(ServiceCtx context)
        {
            return _context ?? throw new InvalidOperationException("bsd: socket command on a session not bound to a process (no RegisterClient / command 36 / StartMonitoring with pid)");
        }

        public IClient(ServiceCtx context, bool isPrivileged) : base(context.Device.System.BsdServer)
        {
            _isPrivileged = isPrivileged;
        }

        private ResultCode WriteBsdResult(ServiceCtx context, int result, LinuxError errorCode = LinuxError.SUCCESS)
        {
            if (errorCode != LinuxError.SUCCESS)
            {
                if (errorCode != LinuxError.EWOULDBLOCK)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Operation failed with error {errorCode}.");
                }

                result = -1;
            }

            context.ResponseData.Write(result);
            context.ResponseData.Write((int)errorCode);

            return ResultCode.Success;
        }

        private static AddressFamily ConvertBsdAddressFamily(BsdAddressFamily family)
        {
            return family switch
            {
                BsdAddressFamily.Unspecified => AddressFamily.Unspecified,
                BsdAddressFamily.InterNetwork => AddressFamily.InterNetwork,
                BsdAddressFamily.InterNetworkV6 => AddressFamily.InterNetworkV6,
                BsdAddressFamily.Unknown => AddressFamily.Unknown,
                _ => throw new NotImplementedException(family.ToString()),
            };
        }

        private LinuxError SetResultErrno(IFileDescriptor socket, int result)
        {
            return result == 0 && !socket.Blocking ? LinuxError.EWOULDBLOCK : LinuxError.SUCCESS;
        }

        private ResultCode SocketInternal(ServiceCtx context, bool exempt)
        {
            BsdAddressFamily domain = (BsdAddressFamily)context.RequestData.ReadInt32();
            BsdSocketType type = (BsdSocketType)context.RequestData.ReadInt32();
            ProtocolType protocol = (ProtocolType)context.RequestData.ReadInt32();

            Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Creating socket with domain={domain}, type={type}, protocol={protocol}");

            BsdSocketCreationFlags creationFlags = (BsdSocketCreationFlags)((int)type >> (int)BsdSocketCreationFlags.FlagsShift);
            type &= BsdSocketType.TypeMask;

            if (domain == BsdAddressFamily.Unknown)
            {
                return WriteBsdResult(context, -1, LinuxError.EPROTONOSUPPORT);
            }
            else if ((type == BsdSocketType.Seqpacket || type == BsdSocketType.Raw) && !_isPrivileged)
            {
                if (domain != BsdAddressFamily.InterNetwork || type != BsdSocketType.Raw || protocol != ProtocolType.Icmp)
                {
                    return WriteBsdResult(context, -1, LinuxError.ENOENT);
                }
            }

            AddressFamily netDomain = ConvertBsdAddressFamily(domain);

            if (protocol == ProtocolType.IP)
            {
                if (type == BsdSocketType.Stream)
                {
                    protocol = ProtocolType.Tcp;
                }
                else if (type == BsdSocketType.Dgram)
                {
                    protocol = ProtocolType.Udp;
                }
            }

            LinuxError errno = LinuxError.SUCCESS;
            ManagedSocket newBsdSocket;

            try
            {
                // ldn_mitm assigns each peer a real LAN address and the game exchanges its payload
                // through ordinary BSD sockets. Keep internet/NIFM semantics off, but do not route
                // this mode's data sockets into the loopback-only offline network.
                bool offline = !context.Device.Configuration.EnableInternetAccess &&
                               context.Device.Configuration.MultiplayerMode != MultiplayerMode.LdnMitm;

                newBsdSocket = new ManagedSocket(netDomain, (SocketType)type, protocol, context.Device.Configuration.MultiplayerLanInterfaceId, offline)
                {
                    Blocking = !creationFlags.HasFlag(BsdSocketCreationFlags.NonBlocking),
                };
            }
            catch (SocketException exception)
            {
                LinuxError errNo = WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
                return WriteBsdResult(context, 0, errNo);
            }

            int newSockFd = Context(context).RegisterFileDescriptor(newBsdSocket);

            if (newSockFd == -1)
            {
                errno = LinuxError.EBADF;
            }

            if (exempt)
            {
                Logger.Info?.Print(LogClass.ServiceBsd, "Disconnecting exempt socket.");
                newBsdSocket.Disconnect();
            }

            return WriteBsdResult(context, newSockFd, errno);
        }

        // S2Arm: returns the bytes written (the addrlen the caller reports). A null or short addr buffer is not written
        //   (Horizon / BSD: accept / getpeername / getsockname with addr NULL leave it alone): writing 16 bytes to a
        //   zero-length buffer raised InvalidMemoryRegionException and the game aborted in nn::socket::Accept
        private int WriteSockAddr(ServiceCtx context, ulong bufferPosition, ulong bufferSize, ISocket socket, bool isRemote)
        {
            if (bufferPosition == 0 || bufferSize < (ulong)Unsafe.SizeOf<BsdSockAddr>())
            {
                return 0;
            }

            IPEndPoint endPoint = isRemote ? socket.RemoteEndPoint : socket.LocalEndPoint;

            if (endPoint != null)
            {
                context.Memory.Write(bufferPosition, BsdSockAddr.FromIPEndPoint(endPoint));
            }
            else
            {
                context.Memory.Write(bufferPosition, new BsdSockAddr());
            }

            return Unsafe.SizeOf<BsdSockAddr>();
        }

        [CommandCmif(0)]
        // Initialize(nn::socket::BsdBufferConfig config, u64 pid, u64 transferMemorySize, KObject<copy, transfer_memory>, pid) -> u32 bsd_errno
        public ResultCode RegisterClient(ServiceCtx context)
        {
            _context = BsdContext.GetOrRegister(context.Request.HandleDesc.PId);
            _registered = true;

            /*
            typedef struct  {
                u32 version;                // Observed 1 on 2.0 LibAppletWeb, 2 on 3.0.
                u32 tcp_tx_buf_size;        // Size of the TCP transfer (send) buffer (initial or fixed).
                u32 tcp_rx_buf_size;        // Size of the TCP recieve buffer (initial or fixed).
                u32 tcp_tx_buf_max_size;    // Maximum size of the TCP transfer (send) buffer. If it is 0, the size of the buffer is fixed to its initial value.
                u32 tcp_rx_buf_max_size;    // Maximum size of the TCP receive buffer. If it is 0, the size of the buffer is fixed to its initial value.
                u32 udp_tx_buf_size;        // Size of the UDP transfer (send) buffer (typically 0x2400 bytes).
                u32 udp_rx_buf_size;        // Size of the UDP receive buffer (typically 0xA500 bytes).
                u32 sb_efficiency;          // Number of buffers for each socket (standard values range from 1 to 8).
            } BsdBufferConfig;
            */

            // bsd_error
            context.ResponseData.Write(0);

            Logger.Stub?.PrintStub(LogClass.ServiceBsd);

            // Close transfer memory immediately as we don't use it.
            context.Device.System.KernelContext.Syscall.CloseHandle(context.Request.HandleDesc.ToCopy[0]);

            return ResultCode.Success;
        }

        [CommandCmif(1)]
        // StartMonitoring(u64, pid)
        public ResultCode StartMonitoring(ServiceCtx context)
        {
            ulong unknown0 = context.RequestData.ReadUInt64();

            BindByPid(context);   // S2Arm：监视会话靠这里的 pid 认进程

            Logger.Stub?.PrintStub(LogClass.ServiceBsd, new { unknown0 });

            return ResultCode.Success;
        }

        [CommandCmif(2)]
        // Socket(u32 domain, u32 type, u32 protocol) -> (i32 ret, u32 bsd_errno)
        public ResultCode Socket(ServiceCtx context)
        {
            return SocketInternal(context, false);
        }

        [CommandCmif(3)]
        // SocketExempt(u32 domain, u32 type, u32 protocol) -> (i32 ret, u32 bsd_errno)
        public ResultCode SocketExempt(ServiceCtx context)
        {
            return SocketInternal(context, true);
        }

        [CommandCmif(4)]
        // Open(u32 flags, array<unknown, 0x21> path) -> (i32 ret, u32 bsd_errno)
        public ResultCode Open(ServiceCtx context)
        {
            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x21();

            int flags = context.RequestData.ReadInt32();

            byte[] rawPath = new byte[bufferSize];

            context.Memory.Read(bufferPosition, rawPath);

            string path = Encoding.ASCII.GetString(rawPath);

            WriteBsdResult(context, -1, LinuxError.EOPNOTSUPP);

            Logger.Stub?.PrintStub(LogClass.ServiceBsd, new { path, flags });

            return ResultCode.Success;
        }

        [CommandCmif(5)]
        // Select(u32 nfds, nn::socket::timeval timeout, buffer<nn::socket::fd_set, 0x21, 0> readfds_in, buffer<nn::socket::fd_set, 0x21, 0> writefds_in, buffer<nn::socket::fd_set, 0x21, 0> errorfds_in)
        // -> (i32 ret, u32 bsd_errno, buffer<nn::socket::fd_set, 0x22, 0> readfds_out, buffer<nn::socket::fd_set, 0x22, 0> writefds_out, buffer<nn::socket::fd_set, 0x22, 0> errorfds_out)
        public ResultCode Select(ServiceCtx context)
        {
            // S2Arm: the request is { s32 nfds; (pad); timeval { s64 sec; s64 usec }; bool is_null } (libnx BsdSelectTimeval).
            // Upstream read the padding as the timeout, so every select returned at once and games that block in select spun.
            // The timeout passed on to the poll managers is in microseconds (Socket.Select unit), -1 = wait forever.
            int fdsCount = context.RequestData.ReadInt32();
            context.RequestData.ReadInt32();
            long timeoutSeconds = context.RequestData.ReadInt64();
            long timeoutMicroseconds = context.RequestData.ReadInt64();
            bool timeoutIsNull = context.RequestData.ReadBoolean();
            int timeout = timeoutIsNull ? -1
                : timeoutSeconds < 0 || timeoutMicroseconds < 0 ? 0
                : timeoutSeconds >= int.MaxValue / 1000000 ? int.MaxValue
                : (int)Math.Min(timeoutSeconds * 1000000 + timeoutMicroseconds, int.MaxValue);

            if (fdsCount < 0)
            {
                return WriteBsdResult(context, -1, LinuxError.EINVAL);
            }

            (ulong readFdsInBufferPosition, ulong readFdsInBufferSize) = context.Request.GetBufferType0x21(0);
            (ulong writeFdsInBufferPosition, ulong writeFdsInBufferSize) = context.Request.GetBufferType0x21(1);
            (ulong errorFdsInBufferPosition, ulong errorFdsInBufferSize) = context.Request.GetBufferType0x21(2);

            (ulong readFdsOutBufferPosition, ulong readFdsOutBufferSize) = context.Request.GetBufferType0x22(0);
            (ulong writeFdsOutBufferPosition, ulong writeFdsOutBufferSize) = context.Request.GetBufferType0x22(1);
            (ulong errorFdsOutBufferPosition, ulong errorFdsOutBufferSize) = context.Request.GetBufferType0x22(2);

            List<IFileDescriptor> readFds = Context(context).RetrieveFileDescriptorsFromMask(context.Memory.GetSpan(readFdsInBufferPosition, (int)readFdsInBufferSize), fdsCount);
            List<IFileDescriptor> writeFds = Context(context).RetrieveFileDescriptorsFromMask(context.Memory.GetSpan(writeFdsInBufferPosition, (int)writeFdsInBufferSize), fdsCount);
            List<IFileDescriptor> errorFds = Context(context).RetrieveFileDescriptorsFromMask(context.Memory.GetSpan(errorFdsInBufferPosition, (int)errorFdsInBufferSize), fdsCount);

            // Only descriptors below nfds participate; closed ones in that range must fail.
            if (readFds.Contains(null) || writeFds.Contains(null) || errorFds.Contains(null))
            {
                return WriteBsdResult(context, -1, LinuxError.EBADF);
            }

            int actualFdsCount = readFds.Count + writeFds.Count + errorFds.Count;

            if (fdsCount == 0 || actualFdsCount == 0)
            {
                WriteBsdResult(context, 0);

                return ResultCode.Success;
            }

            PollEvent[] events = new PollEvent[actualFdsCount];

            int index = 0;

            foreach (IFileDescriptor fd in readFds)
            {
                events[index] = new PollEvent(new PollEventData { InputEvents = PollEventTypeMask.Input }, fd);

                index++;
            }

            foreach (IFileDescriptor fd in writeFds)
            {
                events[index] = new PollEvent(new PollEventData { InputEvents = PollEventTypeMask.Output }, fd);

                index++;
            }

            foreach (IFileDescriptor fd in errorFds)
            {
                events[index] = new PollEvent(new PollEventData { InputEvents = PollEventTypeMask.Error }, fd);

                index++;
            }

            List<PollEvent>[] eventsByPollManager = new List<PollEvent>[_pollManagers.Count];

            for (int i = 0; i < eventsByPollManager.Length; i++)
            {
                eventsByPollManager[i] = [];

                foreach (PollEvent evnt in events)
                {
                    if (_pollManagers[i].IsCompatible(evnt))
                    {
                        eventsByPollManager[i].Add(evnt);
                    }
                }
            }

            int updatedCount = 0;
            int managersInUse = 0;

            for (int i = 0; i < _pollManagers.Count; i++)
            {
                if (eventsByPollManager[i].Count > 0)
                {
                    managersInUse++;
                }
            }

            // S2Arm: one kind of descriptor waits in its own manager for the whole timeout. Mixed kinds (host sockets + eventfds)
            // have no common wait primitive: poll every manager without waiting, then sleep 1 ms, until something is ready or time is up.
            long deadline = timeout < 0 ? long.MaxValue : System.Diagnostics.Stopwatch.GetTimestamp() + timeout * System.Diagnostics.Stopwatch.Frequency / 1000000;

            // S2Arm: when every descriptor is an eventfd, an offline socket or an LDN proxy socket, wait on their common change signal instead of polling
            // every 1 ms (S2ABsdWake); a host socket in the set keeps the 1 ms poll (its readiness does not signal)
            bool wakeable = true;

            // S2Arm: a single manager waits out the timeout itself only if it can wait on every descriptor it holds: an LDN proxy socket
            // has no wait (LdnProxySocket.Poll returns its current state, SocketHelpers.Select waits on host / offline sockets only), so a
            // select on LDN sockets alone returned 0 at once and the guest spun; with one in the set, wait here like mixed kinds (audit P1-24)
            bool hasLdn = false;

            foreach (PollEvent evnt in events)
            {
                wakeable &= evnt.FileDescriptor is EventFileDescriptor || (evnt.FileDescriptor is ManagedSocket ms && (ms.Socket is Proxy.OfflineSocket || ms.Socket is Ldn.UserServiceCreator.LdnRyu.Proxy.LdnProxySocket));
                hasLdn |= evnt.FileDescriptor is ManagedSocket ldn && ldn.Socket is Ldn.UserServiceCreator.LdnRyu.Proxy.LdnProxySocket;
            }

            bool managerWaits = managersInUse == 1 && !hasLdn;

            while (true)
            {
                long seen = S2ABsdWake.Version;

                for (int i = 0; i < _pollManagers.Count; i++)
                {
                    if (eventsByPollManager[i].Count > 0)
                    {
                        _pollManagers[i].Select(eventsByPollManager[i], managerWaits ? timeout : 0, out int updatedPollCount);
                        updatedCount += updatedPollCount;
                    }
                }

                // S2Arm: one clock read decides both "time is up" and how long to wait (audit #656 P2, Select half): reading it again for
                // the wait could land past the deadline and turn a negative remainder into -1 = wait forever; S2APollWaitMs gives -1 only
                // for an unlimited select and clamps a finite wait to [0, int.MaxValue]
                long now = System.Diagnostics.Stopwatch.GetTimestamp();

                if (managerWaits || updatedCount > 0 || S2AShutdown.Requested || now >= deadline)
                {
                    break;
                }

                if (wakeable)
                {
                    S2ABsdWake.Wait(seen, S2APollWaitMs(deadline, now, System.Diagnostics.Stopwatch.Frequency));
                }
                else
                {
                    System.Threading.Thread.Sleep(1);
                }
            }

            readFds.Clear();
            writeFds.Clear();
            errorFds.Clear();

            foreach (PollEvent pollEvent in events)
            {
                for (int i = 0; i < _pollManagers.Count; i++)
                {
                    if (eventsByPollManager[i].Contains(pollEvent))
                    {
                        if (pollEvent.Data.OutputEvents.HasFlag(PollEventTypeMask.Input))
                        {
                            readFds.Add(pollEvent.FileDescriptor);
                        }

                        if (pollEvent.Data.OutputEvents.HasFlag(PollEventTypeMask.Output))
                        {
                            writeFds.Add(pollEvent.FileDescriptor);
                        }

                        if (pollEvent.Data.OutputEvents.HasFlag(PollEventTypeMask.Error))
                        {
                            errorFds.Add(pollEvent.FileDescriptor);
                        }
                    }
                }
            }

            using WritableRegion readFdsOut = context.Memory.GetWritableRegion(readFdsOutBufferPosition, (int)readFdsOutBufferSize);
            using WritableRegion writeFdsOut = context.Memory.GetWritableRegion(writeFdsOutBufferPosition, (int)writeFdsOutBufferSize);
            using WritableRegion errorFdsOut = context.Memory.GetWritableRegion(errorFdsOutBufferPosition, (int)errorFdsOutBufferSize);

            Context(context).BuildMask(readFds, readFdsOut.Memory.Span);
            Context(context).BuildMask(writeFds, writeFdsOut.Memory.Span);
            Context(context).BuildMask(errorFds, errorFdsOut.Memory.Span);

            WriteBsdResult(context, updatedCount);

            return ResultCode.Success;
        }

        // S2Arm: milliseconds to wait for the change signal until the poll deadline: -1 only for an unlimited poll (deadline long.MaxValue);
        // a deadline already passed while computing waits 0, never forever (audit #656 P2: 2 ms late gave (-2) + 1 = -1, read as "forever")
        internal static int S2APollWaitMs(long deadline, long now, long frequency)
        {
            if (deadline == long.MaxValue)
            {
                return -1;
            }

            if (now >= deadline)
            {
                return 0;
            }

            return (int)System.Math.Min((deadline - now) * 1000 / frequency + 1, int.MaxValue);
        }

        [CommandCmif(6)]
        // Poll(u32 nfds, u32 timeout, buffer<unknown, 0x21, 0> fds) -> (i32 ret, u32 bsd_errno, buffer<unknown, 0x22, 0>)
        public ResultCode Poll(ServiceCtx context)
        {
            int fdsCount = context.RequestData.ReadInt32();
            int timeout = context.RequestData.ReadInt32();

            (ulong inputBufferPosition, ulong inputBufferSize) = context.Request.GetBufferType0x21();
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            (ulong outputBufferPosition, ulong outputBufferSize) = context.Request.GetBufferType0x22();
#pragma warning restore IDE0059

            if (timeout < -1 || fdsCount < 0 || (ulong)(fdsCount * 8) > inputBufferSize)
            {
                return WriteBsdResult(context, -1, LinuxError.EINVAL);
            }

            PollEvent[] events = new PollEvent[fdsCount];

            for (int i = 0; i < fdsCount; i++)
            {
                PollEventData pollEventData = context.Memory.Read<PollEventData>(inputBufferPosition + (ulong)(i * Unsafe.SizeOf<PollEventData>()));

                IFileDescriptor fileDescriptor = Context(context).RetrieveFileDescriptor(pollEventData.SocketFd);

                if (fileDescriptor == null)
                {
                    return WriteBsdResult(context, -1, LinuxError.EBADF);
                }

                // S2Arm: revents is output only (FreeBSD poll): what the game left in the input entry must not come back for a descriptor that
                // is not ready (the eventfd poll manager only writes it when something is ready). Audit #656 P1
                pollEventData.OutputEvents = 0;

                events[i] = new PollEvent(pollEventData, fileDescriptor);
            }

            List<PollEvent> discoveredEvents = [];
            List<PollEvent>[] eventsByPollManager = new List<PollEvent>[_pollManagers.Count];

            for (int i = 0; i < eventsByPollManager.Length; i++)
            {
                eventsByPollManager[i] = [];

                foreach (PollEvent evnt in events)
                {
                    if (_pollManagers[i].IsCompatible(evnt))
                    {
                        eventsByPollManager[i].Add(evnt);
                        discoveredEvents.Add(evnt);
                    }
                }
            }

            foreach (PollEvent evnt in events)
            {
                if (!discoveredEvents.Contains(evnt))
                {
                    Logger.Error?.Print(LogClass.ServiceBsd, $"Poll operation is not supported for {evnt.FileDescriptor.GetType().Name}!");

                    return WriteBsdResult(context, -1, LinuxError.EBADF);
                }
            }

            int updateCount = 0;

            LinuxError errno = LinuxError.SUCCESS;

            if (fdsCount != 0)
            {
                static bool IsUnexpectedLinuxError(LinuxError error)
                {
                    return error is not LinuxError.SUCCESS and not LinuxError.ETIMEDOUT;
                }

                // S2Arm: the service runs on the game thread that called it, with no KThread (context.Thread is null) and no HLE
                // scheduler, so upstream's wait (Syscall.SleepThread 50 ms + Thread.HandlePostSyscall until Context.Running ends)
                // threw NullReferenceException whenever nothing was ready and the timeout was not 0 (FF RESONANCE: poll on an eventfd,
                // 100 ms, the game Breaks before its first frame). Wait as Select does: poll every manager without waiting; when
                // every descriptor is an eventfd or an offline socket wait on their common change signal (S2ABsdWake), otherwise
                // sleep 1 ms; until something is ready, the timeout passes or shutdown is requested.
                long deadline = timeout == -1 ? long.MaxValue : System.Diagnostics.Stopwatch.GetTimestamp() + timeout * System.Diagnostics.Stopwatch.Frequency / 1000;

                bool wakeable = true;

                foreach (PollEvent evnt in events)
                {
                    wakeable &= evnt.FileDescriptor is EventFileDescriptor || (evnt.FileDescriptor is ManagedSocket ms && (ms.Socket is Proxy.OfflineSocket || ms.Socket is Ldn.UserServiceCreator.LdnRyu.Proxy.LdnProxySocket));
                }

                while (true)
                {
                    long seen = S2ABsdWake.Version;

                    for (int i = 0; i < eventsByPollManager.Length; i++)
                    {
                        if (eventsByPollManager[i].Count == 0)
                        {
                            continue;
                        }

                        errno = _pollManagers[i].Poll(eventsByPollManager[i], 0, out updateCount);

                        if (IsUnexpectedLinuxError(errno))
                        {
                            break;
                        }

                        if (updateCount > 0)
                        {
                            break;
                        }
                    }

                    if (updateCount > 0 || IsUnexpectedLinuxError(errno) || S2AShutdown.Requested || System.Diagnostics.Stopwatch.GetTimestamp() >= deadline)
                    {
                        break;
                    }

                    if (wakeable)
                    {
                        S2ABsdWake.Wait(seen, S2APollWaitMs(deadline, System.Diagnostics.Stopwatch.GetTimestamp(), System.Diagnostics.Stopwatch.Frequency));
                    }
                    else
                    {
                        System.Threading.Thread.Sleep(1);
                    }
                }
            }
            else if (timeout == -1)
            {
                // FIXME: If we get a timeout of -1 and there is no fds to wait on, this should kill the KProcess. (need to check that with re)
                throw new InvalidOperationException();
            }
            else
            {
                // S2Arm: no KThread to put to sleep (see above); a host wait that shutdown also ends
                S2AShutdown.Event.WaitOne(timeout);
            }

            // TODO: Spanify
            for (int i = 0; i < fdsCount; i++)
            {
                context.Memory.Write(outputBufferPosition + (ulong)(i * Unsafe.SizeOf<PollEventData>()), events[i].Data);
            }

            // In case of non blocking call timeout should not be returned.
            // S2Arm: nor for a blocking one: Horizon's bsd is FreeBSD's, whose poll returns 0 when the timeout passes (as Select
            // here does); upstream returned -1 / ETIMEDOUT, never reached there before this wait could run at all
            if (errno == LinuxError.ETIMEDOUT)
            {
                errno = LinuxError.SUCCESS;
            }

            return WriteBsdResult(context, updateCount, errno);
        }

        [CommandCmif(7)]
        // Sysctl(buffer<unknown, 0x21, 0>, buffer<unknown, 0x21, 0>) -> (i32 ret, u32 bsd_errno, u32, buffer<unknown, 0x22, 0>)
        public ResultCode Sysctl(ServiceCtx context)
        {
            WriteBsdResult(context, -1, LinuxError.EOPNOTSUPP);

            Logger.Stub?.PrintStub(LogClass.ServiceBsd);

            return ResultCode.Success;
        }

        [CommandCmif(8)]
        // Recv(u32 socket, u32 flags) -> (i32 ret, u32 bsd_errno, array<i8, 0x22> message)
        public ResultCode Recv(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            BsdSocketFlags socketFlags = (BsdSocketFlags)context.RequestData.ReadInt32();

            (ulong receivePosition, ulong receiveLength) = context.Request.GetBufferType0x22();

            WritableRegion receiveRegion = context.Memory.GetWritableRegion(receivePosition, (int)receiveLength);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            int result = -1;

            if (socket != null)
            {
                errno = socket.Receive(out result, receiveRegion.Memory.Span, socketFlags);

                if (errno == LinuxError.SUCCESS)
                {
                    SetResultErrno(socket, result);

                    receiveRegion.Dispose();
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(9)]
        // RecvFrom(u32 sock, u32 flags) -> (i32 ret, u32 bsd_errno, u32 addrlen, buffer<i8, 0x22, 0> message, buffer<nn::socket::sockaddr_in, 0x22, 0x10>)
        public ResultCode RecvFrom(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            BsdSocketFlags socketFlags = (BsdSocketFlags)context.RequestData.ReadInt32();

            (ulong receivePosition, ulong receiveLength) = context.Request.GetBufferType0x22(0);
            (ulong sockAddrOutPosition, ulong sockAddrOutSize) = context.Request.GetBufferType0x22(1);

            WritableRegion receiveRegion = context.Memory.GetWritableRegion(receivePosition, (int)receiveLength);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            int result = -1;

            if (socket != null)
            {
                errno = socket.ReceiveFrom(out result, receiveRegion.Memory.Span, receiveRegion.Memory.Span.Length, socketFlags, out IPEndPoint endPoint);

                if (errno == LinuxError.SUCCESS)
                {
                    SetResultErrno(socket, result);

                    receiveRegion.Dispose();

                    if (sockAddrOutSize != 0 && sockAddrOutSize >= (ulong)Unsafe.SizeOf<BsdSockAddr>())
                    {
                        context.Memory.Write(sockAddrOutPosition, BsdSockAddr.FromIPEndPoint(endPoint));
                    }
                    else
                    {
                        errno = LinuxError.ENOMEM;
                    }
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(10)]
        // Send(u32 socket, u32 flags, buffer<i8, 0x21, 0>) -> (i32 ret, u32 bsd_errno)
        public ResultCode Send(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            BsdSocketFlags socketFlags = (BsdSocketFlags)context.RequestData.ReadInt32();

            (ulong sendPosition, ulong sendSize) = context.Request.GetBufferType0x21();

            ReadOnlySpan<byte> sendBuffer = context.Memory.GetSpan(sendPosition, (int)sendSize);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            int result = -1;

            if (socket != null)
            {
                errno = socket.Send(out result, sendBuffer, socketFlags);

                if (errno == LinuxError.SUCCESS)
                {
                    SetResultErrno(socket, result);
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(11)]
        // SendTo(u32 socket, u32 flags, buffer<i8, 0x21, 0>, buffer<nn::socket::sockaddr_in, 0x21, 0x10>) -> (i32 ret, u32 bsd_errno)
        public ResultCode SendTo(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            BsdSocketFlags socketFlags = (BsdSocketFlags)context.RequestData.ReadInt32();

            (ulong sendPosition, ulong sendSize) = context.Request.GetBufferType0x21(0);
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x21(1);
#pragma warning restore IDE0059

            ReadOnlySpan<byte> sendBuffer = context.Memory.GetSpan(sendPosition, (int)sendSize);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            int result = -1;

            if (socket != null)
            {
                IPEndPoint endPoint = context.Memory.Read<BsdSockAddr>(bufferPosition).ToIPEndPoint();

                errno = socket.SendTo(out result, sendBuffer, sendBuffer.Length, socketFlags, endPoint);

                if (errno == LinuxError.SUCCESS)
                {
                    SetResultErrno(socket, result);
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(12)]
        // Accept(u32 socket) -> (i32 ret, u32 bsd_errno, u32 addrlen, buffer<nn::socket::sockaddr_in, 0x22, 0x10> addr)
        public ResultCode Accept(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();

            (ulong bufferPos, ulong bufferSize) = context.Request.GetBufferType0x22();

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = socket.Accept(out ISocket newSocket);

                if (newSocket == null && errno == LinuxError.SUCCESS)
                {
                    errno = LinuxError.EWOULDBLOCK;
                }
                else if (errno == LinuxError.SUCCESS)
                {
                    int newSockFd = Context(context).RegisterFileDescriptor(newSocket);

                    int addrLen = 0;

                    if (newSockFd == -1)
                    {
                        errno = LinuxError.EBADF;
                    }
                    else
                    {
                        addrLen = WriteSockAddr(context, bufferPos, bufferSize, newSocket, true);
                    }

                    WriteBsdResult(context, newSockFd, errno);

                    context.ResponseData.Write(addrLen);

                    return ResultCode.Success;
                }
            }

            return WriteBsdResult(context, -1, errno);
        }

        [CommandCmif(13)]
        // Bind(u32 socket, buffer<nn::socket::sockaddr_in, 0x21, 0x10> addr) -> (i32 ret, u32 bsd_errno)
        public ResultCode Bind(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();

#pragma warning disable IDE0059 // Remove unnecessary value assignment
            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x21();
#pragma warning restore IDE0059

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                IPEndPoint endPoint = context.Memory.Read<BsdSockAddr>(bufferPosition).ToIPEndPoint();

                errno = socket.Bind(endPoint);
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(14)]
        // Connect(u32 socket, buffer<nn::socket::sockaddr_in, 0x21, 0x10>) -> (i32 ret, u32 bsd_errno)
        public ResultCode Connect(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();

#pragma warning disable IDE0059 // Remove unnecessary value assignment
            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x21();
#pragma warning restore IDE0059

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                IPEndPoint endPoint = context.Memory.Read<BsdSockAddr>(bufferPosition).ToIPEndPoint();

                errno = socket.Connect(endPoint);
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(15)]
        // GetPeerName(u32 socket) -> (i32 ret, u32 bsd_errno, u32 addrlen, buffer<nn::socket::sockaddr_in, 0x22, 0x10> addr)
        public ResultCode GetPeerName(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();

            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x22();

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            if (socket != null)
            {
                errno = LinuxError.ENOTCONN;

                if (socket.RemoteEndPoint != null)
                {
                    errno = LinuxError.SUCCESS;

                    int addrLen = WriteSockAddr(context, bufferPosition, bufferSize, socket, true);
                    WriteBsdResult(context, 0, errno);
                    context.ResponseData.Write(addrLen);
                }
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(16)]
        // GetSockName(u32 socket) -> (i32 ret, u32 bsd_errno, u32 addrlen, buffer<nn::socket::sockaddr_in, 0x22, 0x10> addr)
        public ResultCode GetSockName(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();

            (ulong bufferPos, ulong bufferSize) = context.Request.GetBufferType0x22();

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = LinuxError.SUCCESS;

                int addrLen = WriteSockAddr(context, bufferPos, bufferSize, socket, false);
                WriteBsdResult(context, 0, errno);
                context.ResponseData.Write(addrLen);
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(17)]
        // GetSockOpt(u32 socket, u32 level, u32 option_name) -> (i32 ret, u32 bsd_errno, u32, buffer<unknown, 0x22, 0>)
        public ResultCode GetSockOpt(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            SocketOptionLevel level = (SocketOptionLevel)context.RequestData.ReadInt32();
            BsdSocketOption option = (BsdSocketOption)context.RequestData.ReadInt32();

            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x22();
            WritableRegion optionValue = context.Memory.GetWritableRegion(bufferPosition, (int)bufferSize);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = socket.GetSocketOption(option, level, optionValue.Memory.Span);

                if (errno == LinuxError.SUCCESS)
                {
                    optionValue.Dispose();
                }
            }

            ResultCode resultCode = WriteBsdResult(context, 0, errno);

            // S2Arm: the reply's third field is the option length (games pass it on to SetSockOpt; it used to be left 0)
            context.ResponseData.Write(errno == LinuxError.SUCCESS ? WinSockHelper.GetSocketOptionLength(option, level, (int)bufferSize) : 0);

            return resultCode;
        }

        [CommandCmif(18)]
        // Listen(u32 socket, u32 backlog) -> (i32 ret, u32 bsd_errno)
        public ResultCode Listen(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            int backlog = context.RequestData.ReadInt32();

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = socket.Listen(backlog);
            }
            else
            {
                Logger.Warning?.PrintMsg(LogClass.ServiceBsd, $"Invalid socket fd '{socketFd}'.");
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(19)]
        // Ioctl(u32 fd, u32 request, u32 bufcount, buffer<unknown, 0x21, 0>, buffer<unknown, 0x21, 0>, buffer<unknown, 0x21, 0>, buffer<unknown, 0x21, 0>) -> (i32 ret, u32 bsd_errno, buffer<unknown, 0x22, 0>, buffer<unknown, 0x22, 0>, buffer<unknown, 0x22, 0>, buffer<unknown, 0x22, 0>)
        public ResultCode Ioctl(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            BsdIoctl cmd = (BsdIoctl)context.RequestData.ReadInt32();
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            int bufferCount = context.RequestData.ReadInt32();
#pragma warning restore IDE0059

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                switch (cmd)
                {
                    case BsdIoctl.AtMark:
                        errno = LinuxError.SUCCESS;

#pragma warning disable IDE0059 // Remove unnecessary value assignment
                        (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x22();
#pragma warning restore IDE0059

                        // FIXME: OOB not implemented.
                        context.Memory.Write(bufferPosition, 0);
                        break;

                    default:
                        errno = LinuxError.EOPNOTSUPP;

                        Logger.Warning?.Print(LogClass.ServiceBsd, $"Unsupported Ioctl Cmd: {cmd}");
                        break;
                }
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(20)]
        // Fcntl(u32 socket, u32 cmd, u32 arg) -> (i32 ret, u32 bsd_errno)
        public ResultCode Fcntl(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            int cmd = context.RequestData.ReadInt32();
            int arg = context.RequestData.ReadInt32();

            int result = 0;
            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = LinuxError.SUCCESS;

                // F_GETFL
                if (cmd == 0x3)
                {
                    result = !socket.Blocking ? 0x800 : 0;
                }
                // F_SETFL
                else if (cmd == 0x4)
                {
                    socket.Blocking = (arg & 0x800) == 0;
                    result = 0;
                }
                else
                {
                    errno = LinuxError.EOPNOTSUPP;
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(21)]
        // SetSockOpt(u32 socket, u32 level, u32 option_name, buffer<unknown, 0x21, 0> option_value) -> (i32 ret, u32 bsd_errno)
        public ResultCode SetSockOpt(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            SocketOptionLevel level = (SocketOptionLevel)context.RequestData.ReadInt32();
            BsdSocketOption option = (BsdSocketOption)context.RequestData.ReadInt32();

            (ulong bufferPos, ulong bufferSize) = context.Request.GetBufferType0x21();

            ReadOnlySpan<byte> optionValue = context.Memory.GetSpan(bufferPos, (int)bufferSize);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = socket.SetSocketOption(option, level, optionValue);
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(22)]
        // Shutdown(u32 socket, u32 how) -> (i32 ret, u32 bsd_errno)
        public ResultCode Shutdown(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            int how = context.RequestData.ReadInt32();

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);

            if (socket != null)
            {
                errno = LinuxError.EINVAL;

                if (how is >= 0 and <= 2)
                {
                    errno = socket.Shutdown((BsdSocketShutdownFlags)how);
                }
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(23)]
        // ShutdownAllSockets(u32 how) -> (i32 ret, u32 bsd_errno)
        public ResultCode ShutdownAllSockets(ServiceCtx context)
        {
            int how = context.RequestData.ReadInt32();

            LinuxError errno = LinuxError.EINVAL;

            if (how is >= 0 and <= 2)
            {
                errno = Context(context).ShutdownAllSockets((BsdSocketShutdownFlags)how);
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(24)]
        // Write(u32 fd, buffer<i8, 0x21, 0> message) -> (i32 ret, u32 bsd_errno)
        public ResultCode Write(ServiceCtx context)
        {
            int fd = context.RequestData.ReadInt32();

            (ulong sendPosition, ulong sendSize) = context.Request.GetBufferType0x21();

            ReadOnlySpan<byte> sendBuffer = context.Memory.GetSpan(sendPosition, (int)sendSize);

            LinuxError errno = LinuxError.EBADF;
            IFileDescriptor file = Context(context).RetrieveFileDescriptor(fd);
            int result = -1;

            if (file != null)
            {
                errno = file.Write(out result, sendBuffer);

                if (errno == LinuxError.SUCCESS)
                {
                    SetResultErrno(file, result);
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(25)]
        // Read(u32 fd) -> (i32 ret, u32 bsd_errno, buffer<i8, 0x22, 0> message)
        public ResultCode Read(ServiceCtx context)
        {
            int fd = context.RequestData.ReadInt32();

            (ulong receivePosition, ulong receiveLength) = context.Request.GetBufferType0x22();

            WritableRegion receiveRegion = context.Memory.GetWritableRegion(receivePosition, (int)receiveLength);

            LinuxError errno = LinuxError.EBADF;
            IFileDescriptor file = Context(context).RetrieveFileDescriptor(fd);
            int result = -1;

            if (file != null)
            {
                errno = file.Read(out result, receiveRegion.Memory.Span);

                if (errno == LinuxError.SUCCESS)
                {
                    SetResultErrno(file, result);

                    receiveRegion.Dispose();
                }
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(26)]
        // Close(u32 fd) -> (i32 ret, u32 bsd_errno)
        public ResultCode Close(ServiceCtx context)
        {
            int fd = context.RequestData.ReadInt32();

            LinuxError errno = LinuxError.EBADF;

            if (Context(context).CloseFileDescriptor(fd))
            {
                errno = LinuxError.SUCCESS;
            }

            return WriteBsdResult(context, 0, errno);
        }

        [CommandCmif(27)]
        // DuplicateSocket(u32 fd, u64 reserved) -> (i32 ret, u32 bsd_errno)
        public ResultCode DuplicateSocket(ServiceCtx context)
        {
            int fd = context.RequestData.ReadInt32();
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            ulong reserved = context.RequestData.ReadUInt64();
#pragma warning restore IDE0059

            LinuxError errno = LinuxError.ENOENT;
            int newSockFd = -1;

            if (_isPrivileged)
            {
                errno = LinuxError.SUCCESS;

                newSockFd = Context(context).DuplicateFileDescriptor(fd);

                if (newSockFd == -1)
                {
                    errno = LinuxError.EBADF;
                }
            }

            return WriteBsdResult(context, newSockFd, errno);
        }

        [CommandCmif(29)] // 7.0.0+
        // RecvMMsg(u32 fd, u32 vlen, u32 flags, u32 reserved, nn::socket::TimeVal timeout) -> (i32 ret, u32 bsd_errno, buffer<bytes, 6> message);
        public ResultCode RecvMMsg(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            int vlen = context.RequestData.ReadInt32();
            BsdSocketFlags socketFlags = (BsdSocketFlags)context.RequestData.ReadInt32();
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            uint reserved = context.RequestData.ReadUInt32();
#pragma warning restore IDE0059
            TimeVal timeout = context.RequestData.ReadStruct<TimeVal>();

            ulong receivePosition = context.Request.ReceiveBuff[0].Position;
            ulong receiveLength = context.Request.ReceiveBuff[0].Size;

            WritableRegion receiveRegion = context.Memory.GetWritableRegion(receivePosition, (int)receiveLength);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            int result = -1;

            if (socket != null)
            {
                errno = BsdMMsgHdr.Deserialize(out BsdMMsgHdr message, receiveRegion.Memory.Span, vlen);

                if (errno == LinuxError.SUCCESS)
                {
                    errno = socket.RecvMMsg(out result, message, socketFlags, timeout);

                    if (errno == LinuxError.SUCCESS)
                    {
                        errno = BsdMMsgHdr.Serialize(receiveRegion.Memory.Span, message);
                    }
                }
            }

            if (errno == LinuxError.SUCCESS)
            {
                SetResultErrno(socket, result);
                receiveRegion.Dispose();
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(30)] // 7.0.0+
        // SendMMsg(u32 fd, u32 vlen, u32 flags) -> (i32 ret, u32 bsd_errno, buffer<bytes, 6> message);
        public ResultCode SendMMsg(ServiceCtx context)
        {
            int socketFd = context.RequestData.ReadInt32();
            int vlen = context.RequestData.ReadInt32();
            BsdSocketFlags socketFlags = (BsdSocketFlags)context.RequestData.ReadInt32();

            ulong receivePosition = context.Request.ReceiveBuff[0].Position;
            ulong receiveLength = context.Request.ReceiveBuff[0].Size;

            WritableRegion receiveRegion = context.Memory.GetWritableRegion(receivePosition, (int)receiveLength);

            LinuxError errno = LinuxError.EBADF;
            ISocket socket = Context(context).RetrieveSocket(socketFd);
            int result = -1;

            if (socket != null)
            {
                errno = BsdMMsgHdr.Deserialize(out BsdMMsgHdr message, receiveRegion.Memory.Span, vlen);

                if (errno == LinuxError.SUCCESS)
                {
                    errno = socket.SendMMsg(out result, message, socketFlags);

                    if (errno == LinuxError.SUCCESS)
                    {
                        errno = BsdMMsgHdr.Serialize(receiveRegion.Memory.Span, message);
                    }
                }
            }

            if (errno == LinuxError.SUCCESS)
            {
                SetResultErrno(socket, result);
                receiveRegion.Dispose();
            }

            return WriteBsdResult(context, result, errno);
        }

        [CommandCmif(31)] // 7.0.0+
        // EventFd(nn::socket::EventFdFlags flags, u64 initval) -> (i32 ret, u32 bsd_errno)
        public ResultCode EventFd(ServiceCtx context)
        {
            EventFdFlags flags = (EventFdFlags)context.RequestData.ReadUInt32();
            context.RequestData.BaseStream.Position += 4; // Padding
            ulong initialValue = context.RequestData.ReadUInt64();

            EventFileDescriptor newEventFile = new(initialValue, flags);

            LinuxError errno = LinuxError.SUCCESS;

            int newSockFd = Context(context).RegisterFileDescriptor(newEventFile);

            if (newSockFd == -1)
            {
                errno = LinuxError.EBADF;
            }

            return WriteBsdResult(context, newSockFd, errno);
        }

        [CommandCmif(36)] // 18.0.0+
        // S2Arm：未命名（Switch 2 SDK 的 nn::socket::Initialize 每个会话在 StartMonitoring 前发一次）：(u32 套接字配置首字, pid) -> u32，非 0 即初始化失败。
        //   宿主不按配置调资源：收下、回 0。Pokopia 首帧后发它，原先未实现回错（命令号与形状来自 Eden-NS2 bsd.cpp，GPL，只借事实，代码自写）
        public ResultCode InitializeSessionS2(ServiceCtx context)
        {
            // 审计 P2-223：配置首字原先读掉不留痕。宿主没有可按它调的套接字资源，照旧回 0，但把收到的值打一行（每会话一次，SDK 每会话只发一次）
            uint config = context.RequestData.ReadUInt32();
            Logger.Info?.Print(LogClass.ServiceBsd, $"bsd 命令 36（Switch 2 套接字会话初始化）：配置首字 0x{config:X8}，宿主不按它限制套接字资源，收下回 0");
            BindByPid(context);   // 本会话从此用本进程的描述符表（Switch 2 SDK 只在一条会话上 RegisterClient）
            context.ResponseData.Write(0u);

            return ResultCode.Success;
        }


        public override void DestroyAtExit()
        {
            if (_registered)
            {
                _context?.Dispose();
            }
        }
    }
}
