using LibHac.Ns;
using Ryujinx.Common;
using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.Common.Utilities;
using Ryujinx.Cpu;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnMitm;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using Ryujinx.Horizon.Common;
using Ryujinx.Memory;
using System;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator
{
    class IUserLocalCommunicationService : IpcService, IDisposable
    {
        public INetworkClient NetworkClient { get; private set; }

        private const int NifmRequestID = 90;
        private const string DefaultIPAddress = "127.0.0.1";
        private const string DefaultSubnetMask = "255.255.255.0";
        private const bool IsDevelopment = false;

        private static bool LdnAutoRequested =>
            !string.Equals(Environment.GetEnvironmentVariable("S2A_LDN_MITM"), "1", StringComparison.Ordinal) &&
            string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_LDN_SERVER")) &&
            !string.Equals(Environment.GetEnvironmentVariable("S2A_LDN_AUTO"), "0", StringComparison.Ordinal) &&
            !S2AHooks.LdnPlatformDiscovery;   // 宿主这一局走了平台局域网发现（iOS）：照旧 RyuLDN，不建双协议自动客户端

        internal static MultiplayerMode SelectAutoMode(MultiplayerMode mode, Func<bool> switchRoomFound)
        {
            if (!LdnAutoRequested || mode == MultiplayerMode.LdnMitm)
            {
                return mode;
            }

            if (mode == MultiplayerMode.Disabled)
            {
                return MultiplayerMode.LdnMitm;
            }

            try
            {
                return switchRoomFound() ? MultiplayerMode.LdnMitm : mode;
            }
            catch (Exception ex)
            {
                Logger.Warning?.Print(LogClass.ServiceLdn, $"Auto LDN Switch probe failed, keeping RyuLDN: {ex.Message}");
                return mode;
            }
        }

        private readonly KEvent _stateChangeEvent;
        private int _stateChangeEventHandle;

        private NetworkState _state;
        private DisconnectReason _disconnectReason;
        private ResultCode _nifmResultCode;
        private bool _unavailableReported;
        private bool _metadataMissingReported;
        // S2Arm: Initialize succeeded without touching the network (S2AHooks.LdnDeferInit): the first Scan / OpenAccessPoint / OpenStation
        // runs the host's on-demand LAN start and builds the real client (S2AActivateLan)
        private bool _s2aLanDeferred;

        private AccessPoint _accessPoint;
        private Station _station;

        public IUserLocalCommunicationService(ServiceCtx context)
        {
            _stateChangeEvent = new KEvent(context.Device.System.KernelContext);
            _state = NetworkState.None;
            _disconnectReason = DisconnectReason.None;
        }

        private ushort CheckDevelopmentChannel(ushort channel)
        {
            return (ushort)(!IsDevelopment ? 0 : channel);
        }

        private SecurityMode CheckDevelopmentSecurityMode(SecurityMode securityMode)
        {
            return !IsDevelopment ? SecurityMode.Retail : securityMode;
        }

        // S2Arm: the process metadata the nacp checks below read can be absent (a game
        // whose process entry was never registered). A missing entry is an environment
        // defect, not a valid state: report it once and let every caller fail closed.
        private bool TryGetControlProperty(ServiceCtx context, out ApplicationControlProperty controlProperty)
        {
            var processResult = context.Device.Processes.GetProcess(context.ClientProcessId);
            controlProperty = processResult?.ApplicationControlProperties ?? default;
            if (processResult == null && !_metadataMissingReported)
            {
                _metadataMissingReported = true;
                S2AHooks.Red?.Invoke("ldn: caller process metadata missing, reporting failure");
            }
            return processResult != null;
        }

        private bool CheckLocalCommunicationIdPermission(ServiceCtx context, ulong localCommunicationIdChecked)
        {
            // TODO: Call nn::arp::GetApplicationControlProperty here when implemented.
            if (!TryGetControlProperty(context, out ApplicationControlProperty controlProperty))
            {
                return false;
            }

            foreach (ulong localCommunicationId in controlProperty.LocalCommunicationId)
            {
                if (localCommunicationId == localCommunicationIdChecked)
                {
                    Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,"CheckLocalCommumicationIdPermission: Checked!");
                    return true;
                }
            }
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,"CheckLocalCommumicationIdPermission: Check failed!");
            return false;
        }

        [CommandCmif(0)]
        // GetState() -> s32 state
        public ResultCode GetState(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                context.ResponseData.Write((int)NetworkState.Error);
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,$"GetState: _nifmResultCode = {_nifmResultCode.ToString()}");
                return ResultCode.Success;
            }

            // NOTE: Returns ResultCode.InvalidArgument if _state is null, doesn't occur in our case.
            context.ResponseData.Write((int)_state);

            return ResultCode.Success;
        }

        public void SetState()
        {
            _stateChangeEvent.WritableEvent.Signal();
        }

        public void SetState(NetworkState state)
        {
            _state = state;

            SetState();
        }

        [CommandCmif(1)]
        // GetNetworkInfo() -> buffer<network_info<0x480>, 0x1a>
        public ResultCode GetNetworkInfo(ServiceCtx context)
        {
            ulong bufferPosition = context.Request.RecvListBuff[0].Position;

            MemoryHelper.FillWithZeros(context.Memory, bufferPosition, 0x480);

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,$"GetNetworkInfo: _nifmResultCode = {_nifmResultCode.ToString()}");
                return _nifmResultCode;
            }

            ResultCode resultCode = GetNetworkInfoImpl(out NetworkInfo networkInfo);
            if (resultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,$"GetState: resultCode = {resultCode.ToString()}");
                return resultCode;
            }

            ulong infoSize = MemoryHelper.Write(context.Memory, bufferPosition, networkInfo);

            context.Response.PtrBuff[0] = context.Response.PtrBuff[0].WithSize(infoSize);

            return ResultCode.Success;
        }

        private ResultCode GetNetworkInfoImpl(out NetworkInfo networkInfo)
        {
            if (_state == NetworkState.StationConnected)
            {
                networkInfo = _station.NetworkInfo;
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,"GetNetworkInfoImpl: _station");
            }
            else if (_state == NetworkState.AccessPointCreated)
            {
                networkInfo = _accessPoint.NetworkInfo;
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,"GetNetworkInfoImpl: _accessPoint");
            }
            else
            {
                networkInfo = new NetworkInfo();
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,"GetNetworkInfoImpl: Invalid state!");
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,$"GetNetworkInfoImpl: networkInfo = {networkInfo}");
                return ResultCode.InvalidState;
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn,$"GetNetworkInfoImpl: networkInfo = {networkInfo}");
            return ResultCode.Success;
        }

        private NodeLatestUpdate[] GetNodeLatestUpdateImpl(int count)
        {
            if (_state == NetworkState.StationConnected)
            {
                return _station.LatestUpdates.ConsumeLatestUpdate(count);
            }
            else if (_state == NetworkState.AccessPointCreated)
            {
                return _accessPoint.LatestUpdates.ConsumeLatestUpdate(count);
            }
            else
            {
                return [];
            }
        }

        [CommandCmif(2)]
        // GetIpv4Address() -> (u32 ip_address, u32 subnet_mask)
        public ResultCode GetIpv4Address(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                return _nifmResultCode;
            }

            // NOTE: Return ResultCode.InvalidArgument if ip_address and subnet_mask are null, doesn't occur in our case.

            if (_state is NetworkState.AccessPointCreated or NetworkState.StationConnected)
            {
                ProxyConfig config = _state switch
                {
                    NetworkState.AccessPointCreated => _accessPoint.Config,
                    NetworkState.StationConnected => _station.Config,

                    _ => default
                };

                if (config.ProxyIp == 0)
                {
                    // ldn_mitm advertises a real LAN address. Use the same address the control
                    // channel selected, otherwise a second enumeration can hand the game en0 while
                    // the room TCP connection is bound to en8.
                    IPAddress ldnAddress = (NetworkClient as LdnMitmClient)?.LocalAddress;
                    (_, UnicastIPAddressInformation unicastAddress) = NetworkHelpers.GetLocalInterfaceForTarget(
                        context.Device.Configuration.MultiplayerLanInterfaceId,
                        ldnAddress);

                    if (unicastAddress == null)
                    {
                        context.ResponseData.Write(NetworkHelpers.ConvertIpv4Address(DefaultIPAddress));
                        context.ResponseData.Write(NetworkHelpers.ConvertIpv4Address(DefaultSubnetMask));
                    }
                    else
                    {
                        Logger.NetLog?.Print(LogClass.ServiceLdn, $"Console's LDN IP is \"{unicastAddress.Address}\".");

                        context.ResponseData.Write(NetworkHelpers.ConvertIpv4Address(unicastAddress.Address));
                        context.ResponseData.Write(NetworkHelpers.ConvertIpv4Address(unicastAddress.IPv4Mask));
                    }
                }
                else
                {
                    Logger.NetLog?.Print(LogClass.ServiceLdn, $"LDN obtained proxy IP.");

                    context.ResponseData.Write(config.ProxyIp);
                    context.ResponseData.Write(config.ProxySubnetMask);
                }
            }
            else
            {
                return ResultCode.InvalidArgument;
            }

            return ResultCode.Success;
        }

        [CommandCmif(3)]
        // GetDisconnectReason() -> u16 disconnect_reason
        public ResultCode GetDisconnectReason(ServiceCtx context)
        {
            // NOTE: Returns ResultCode.InvalidArgument if _disconnectReason is null, doesn't occur in our case.

            context.ResponseData.Write((short)_disconnectReason);
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetDisconnectReason: {_disconnectReason}");
            return ResultCode.Success;
        }

        public void SetDisconnectReason(DisconnectReason reason)
        {
            if (_state != NetworkState.Initialized)
            {
                _disconnectReason = reason;

                SetState(NetworkState.Initialized);
            }
        }

        [CommandCmif(4)]
        // GetSecurityParameter() -> bytes<0x20, 1> security_parameter
        public ResultCode GetSecurityParameter(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetSecurityParameter: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            ResultCode resultCode = GetNetworkInfoImpl(out NetworkInfo networkInfo);
            if (resultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetSecurityParameter: resultCode = {resultCode}");
                return resultCode;
            }

            SecurityParameter securityParameter = new()
            {
                Data = new Array16<byte>(),
                SessionId = networkInfo.NetworkId.SessionId,
            };

            context.ResponseData.WriteStruct(securityParameter);
            
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetSecurityParameter: securityParameter = {securityParameter}");
            return ResultCode.Success;
        }

        [CommandCmif(5)]
        // GetNetworkConfig() -> bytes<0x20, 8> network_config
        public ResultCode GetNetworkConfig(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetNetworkConfig: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            ResultCode resultCode = GetNetworkInfoImpl(out NetworkInfo networkInfo);
            if (resultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetNetworkConfig: resultCode = {resultCode}");
                return resultCode;
            }

            NetworkConfig networkConfig = new()
            {
                IntentId = networkInfo.NetworkId.IntentId,
                Channel = networkInfo.Common.Channel,
                NodeCountMax = networkInfo.Ldn.NodeCountMax,
                LocalCommunicationVersion = networkInfo.Ldn.Nodes[0].LocalCommunicationVersion,
                Reserved2 = new Array10<byte>(),
            };

            context.ResponseData.WriteStruct(networkConfig);
            
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetNetworkConfig: networkConfig = {networkConfig}");

            return ResultCode.Success;
        }

        [CommandCmif(100)]
        // AttachStateChangeEvent() -> handle<copy>
        public ResultCode AttachStateChangeEvent(ServiceCtx context)
        {
            if (_stateChangeEventHandle == 0 && context.Process.HandleTable.GenerateHandle(_stateChangeEvent.ReadableEvent, out _stateChangeEventHandle) != Result.Success)
            {
                throw new InvalidOperationException("Out of handles!");
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_stateChangeEventHandle);

            // Returns ResultCode.InvalidArgument if handle is null, doesn't occur in our case since we already throw an Exception.

            return ResultCode.Success;
        }

        [CommandCmif(101)]
        // GetNetworkInfoLatestUpdate() -> (buffer<network_info<0x480>, 0x1a>, buffer<node_latest_update, 0xa>)
        public ResultCode GetNetworkInfoLatestUpdate(ServiceCtx context)
        {
            ulong bufferPosition = context.Request.RecvListBuff[0].Position;

            MemoryHelper.FillWithZeros(context.Memory, bufferPosition, 0x480);

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetNetworkInfoLatestUpdate: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            ResultCode resultCode = GetNetworkInfoImpl(out NetworkInfo networkInfo);
            if (resultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"GetNetworkInfoLatestUpdate: resultCode = {resultCode}");
                return resultCode;
            }

            // S2Arm: NodeLatestUpdate array goes to RecvListBuff[1], not RecvListBuff[0] (which is for NetworkInfo).
            // The signature is (buffer<network_info, 0x1a>, buffer<node_latest_update, 0xa>), so the second buffer
            // is the node update array. When RecvListBuff[1] doesn't exist (buffer not passed), skip writing the array.
            if (context.Request.RecvListBuff.Count > 1)
            {
                ulong outputPosition = context.Request.RecvListBuff[1].Position;
                ulong outputSize = context.Request.RecvListBuff[1].Size;

                ulong latestUpdateSize = (ulong)Marshal.SizeOf<NodeLatestUpdate>();
                int count = (int)(outputSize / latestUpdateSize);

                NodeLatestUpdate[] latestUpdate = GetNodeLatestUpdateImpl(count);

                MemoryHelper.FillWithZeros(context.Memory, outputPosition, (int)outputSize);

                foreach (NodeLatestUpdate node in latestUpdate)
                {
                    MemoryHelper.Write(context.Memory, outputPosition, node);

                    outputPosition += latestUpdateSize;
                }
            }

            ulong infoSize = MemoryHelper.Write(context.Memory, bufferPosition, networkInfo);

            context.Response.PtrBuff[0] = context.Response.PtrBuff[0].WithSize(infoSize);

            return ResultCode.Success;
        }

        [CommandCmif(102)]
        // Scan(u16 channel, bytes<0x60, 8> scan_filter) -> (u16 count, buffer<network_info, 0x22>)
        public ResultCode Scan(ServiceCtx context)
        {
            return ScanImpl(context);
        }

        [CommandCmif(103)]
        // ScanPrivate(u16 channel, bytes<0x60, 8> scan_filter) -> (u16 count, buffer<network_info, 0x22>)
        public ResultCode ScanPrivate(ServiceCtx context)
        {
            return ScanImpl(context, true);
        }

        private ResultCode ScanImpl(ServiceCtx context, bool isPrivate = false)
        {
            ushort channel = (ushort)context.RequestData.ReadUInt64();
            ScanFilter scanFilter = context.RequestData.ReadStruct<ScanFilter>();

            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x22(0);

            S2AActivateLan(context);   // S2Arm: a deferred Initialize starts the local network on the first scan

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ScanImpl: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (!isPrivate)
            {
                channel = CheckDevelopmentChannel(channel);
            }

            ResultCode resultCode = ResultCode.InvalidArgument;

            if (bufferSize != 0)
            {
                if (bufferPosition != 0)
                {
                    ScanFilterFlag scanFilterFlag = scanFilter.Flag;

                    if (!scanFilterFlag.HasFlag(ScanFilterFlag.NetworkType) || scanFilter.NetworkType <= NetworkType.All)
                    {
                        if (scanFilterFlag.HasFlag(ScanFilterFlag.Ssid))
                        {
                            if (scanFilter.Ssid.Length <= 31)
                            {
                                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ScanImpl: resultCode = {resultCode}");
                                return resultCode;
                            }
                        }

                        if (!scanFilterFlag.HasFlag(ScanFilterFlag.MacAddress))
                        {
                            if (scanFilterFlag > ScanFilterFlag.All)
                            {
                                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ScanImpl: resultCode = {resultCode}");
                                return resultCode;
                            }

                            if (_state - 3 >= NetworkState.AccessPoint)
                            {
                                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "ScanImpl: Invalid state!");
                                resultCode = ResultCode.InvalidState;
                            }
                            else
                            {
                                if (scanFilter.NetworkId.IntentId.LocalCommunicationId == -1 && NetworkClient.NeedsRealId)
                                {
                                    // TODO: Call nn::arp::GetApplicationControlProperty here when implemented.
                                    if (!TryGetControlProperty(context, out ApplicationControlProperty controlProperty))
                                    {
                                        return ResultCode.InvalidObject;
                                    }
                                    scanFilter.NetworkId.IntentId.LocalCommunicationId = (long)controlProperty.LocalCommunicationId[0];
                                }

                                RefreshOpenNetworkClient(context);

                                resultCode = ScanInternal(context.Memory, channel, scanFilter, bufferPosition, bufferSize, out ulong counter);

                                context.ResponseData.Write(counter);
                            }
                        }
                        else
                        {
                            throw new NotSupportedException();
                        }
                    }
                }
            }
            
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ScanImpl: resultCode = {resultCode}");
            return resultCode;
        }

        private ResultCode ScanInternal(IVirtualMemoryManager memory, ushort channel, ScanFilter scanFilter, ulong bufferPosition, ulong bufferSize, out ulong counter)
        {
            ulong networkInfoSize = (ulong)Marshal.SizeOf<NetworkInfo>();
            ulong maxGames = bufferSize / networkInfoSize;

            MemoryHelper.FillWithZeros(memory, bufferPosition, (int)bufferSize);

            NetworkInfo[] availableGames = NetworkClient.Scan(channel, scanFilter);

            counter = 0;

            foreach (NetworkInfo networkInfo in availableGames)
            {
                MemoryHelper.Write(memory, bufferPosition + (networkInfoSize * counter), networkInfo);

                if (++counter >= maxGames)
                {
                    break;
                }
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ScanInternal: availableGames = {availableGames}");
            return ResultCode.Success;
        }

        [CommandCmif(104)] // 5.0.0+
        // SetWirelessControllerRestriction(u32 wireless_controller_restriction)
        public ResultCode SetWirelessControllerRestriction(ServiceCtx context)
        {
            // NOTE: Return ResultCode.InvalidArgument if an internal IPAddress is null, doesn't occur in our case.

            uint wirelessControllerRestriction = context.RequestData.ReadUInt32();

            if (wirelessControllerRestriction > 1)
            {
                return ResultCode.InvalidArgument;
            }

            if (_state != NetworkState.Initialized)
            {
                return ResultCode.InvalidState;
            }

            // NOTE: WirelessControllerRestriction value is used for the btm service in SetWlanMode call.
            //       Since we use our own implementation we can do nothing here.

            return ResultCode.Success;
        }

        [CommandCmif(106)] // 20.0.0+
        // SetProtocol
        public ResultCode SetProtocol(ServiceCtx context)
        {
            uint protocolValue =  context.RequestData.ReadUInt32();

            // On NX only input value 1 or 3 is allowed, with an error being thrown otherwise.
            // S2Arm (LDN G12): that error is the guest's InvalidArgument result, not a host exception out of the service. Every station
            // on the RyuLdn relay speaks the same protocol, so a valid value changes nothing else (complete, not a stub).

            if (protocolValue != 1 && protocolValue != 3)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"SetProtocol: invalid protocol value {protocolValue}");

                return ResultCode.InvalidArgument;
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"SetProtocol: protocolValue = {protocolValue}");

            return ResultCode.Success;
        }

        [CommandCmif(200)]
        // OpenAccessPoint()
        public ResultCode OpenAccessPoint(ServiceCtx context)
        {
            S2AActivateLan(context);   // S2Arm: a deferred Initialize starts the local network on the first room / station

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"OpenAccessPoint: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (_state != NetworkState.Initialized)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "OpenAccessPoint: Invalid state!");
                return ResultCode.InvalidState;
            }

            CloseStation();
            RefreshNetworkClient(context);

            SetState(NetworkState.AccessPoint);

            _accessPoint = new AccessPoint(this);

            // NOTE: Calls nifm service and return related result codes.
            //       Since we use our own implementation we can return ResultCode.Success.

            return ResultCode.Success;
        }

        [CommandCmif(201)]
        // CloseAccessPoint()
        public ResultCode CloseAccessPoint(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"CloseAccessPoint: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (_state is NetworkState.AccessPoint or NetworkState.AccessPointCreated)
            {
                DestroyNetworkImpl(DisconnectReason.DestroyedByUser);
            }
            else
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "CloseAccessPoint: Invalid state!");
                return ResultCode.InvalidState;
            }

            SetState(NetworkState.Initialized);

            return ResultCode.Success;
        }

        private void CloseAccessPoint()
        {
            _accessPoint?.Dispose();
            _accessPoint = null;
        }

        [CommandCmif(202)]
        // CreateNetwork(bytes<0x44, 2> security_config, bytes<0x30, 1> user_config, bytes<0x20, 8> network_config)
        public ResultCode CreateNetwork(ServiceCtx context)
        {
            return CreateNetworkImpl(context);
        }

        [CommandCmif(203)]
        // CreateNetworkPrivate(bytes<0x44, 2> security_config, bytes<0x20, 1> security_parameter, bytes<0x30, 1>, bytes<0x20, 8> network_config, buffer<unknown, 9> address_entry, int count)
        public ResultCode CreateNetworkPrivate(ServiceCtx context)
        {
            return CreateNetworkImpl(context, true);
        }

        public ResultCode CreateNetworkImpl(ServiceCtx context, bool isPrivate = false)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"CreateNetworkImpl: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            SecurityConfig securityConfig = context.RequestData.ReadStruct<SecurityConfig>();
            SecurityParameter securityParameter = isPrivate ? context.RequestData.ReadStruct<SecurityParameter>() : new SecurityParameter();

            UserConfig userConfig = context.RequestData.ReadStruct<UserConfig>();

            context.RequestData.BaseStream.Seek(4, SeekOrigin.Current); // Alignment?
            NetworkConfig networkConfig = context.RequestData.ReadStruct<NetworkConfig>();

            if (networkConfig.IntentId.LocalCommunicationId == -1 && NetworkClient.NeedsRealId)
            {
                // TODO: Call nn::arp::GetApplicationControlProperty here when implemented.
                if (!TryGetControlProperty(context, out ApplicationControlProperty controlProperty))
                {
                    return ResultCode.InvalidObject;
                }
                networkConfig.IntentId.LocalCommunicationId = (long)controlProperty.LocalCommunicationId[0];
            }

            bool isLocalCommunicationIdValid = CheckLocalCommunicationIdPermission(context, (ulong)networkConfig.IntentId.LocalCommunicationId);
            if (!isLocalCommunicationIdValid && NetworkClient.NeedsRealId)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "CreateNetworkImpl: Invalid object!");
                return ResultCode.InvalidObject;
            }

            networkConfig.Channel = CheckDevelopmentChannel(networkConfig.Channel);
            securityConfig.SecurityMode = CheckDevelopmentSecurityMode(securityConfig.SecurityMode);

            if (networkConfig.NodeCountMax <= LdnConst.NodeCountMax)
            {
                if ((((ulong)networkConfig.LocalCommunicationVersion) & 0x80000000) == 0)
                {
                    if (securityConfig.SecurityMode <= SecurityMode.Retail)
                    {
                        if (securityConfig.Passphrase.Length <= LdnConst.PassphraseLengthMax)
                        {
                            if (_state == NetworkState.AccessPoint)
                            {
                                RefreshOpenNetworkClient(context);

                                if (isPrivate)
                                {
                                    ulong bufferPosition = context.Request.PtrBuff[0].Position;
                                    ulong bufferSize = context.Request.PtrBuff[0].Size;

                                    byte[] addressListBytes = new byte[bufferSize];

                                    context.Memory.Read(bufferPosition, addressListBytes);

                                    AddressList addressList = MemoryMarshal.Cast<byte, AddressList>(addressListBytes)[0];

                                    // S2Arm: the backend's result goes back to the game (upstream dropped it and always answered Success)
                                    ResultCode created = _accessPoint.CreateNetworkPrivate(securityConfig, securityParameter, userConfig, networkConfig, addressList);

                                    if (created != ResultCode.Success)
                                    {
                                        return created;
                                    }

                                    Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"CreateNetworkImpl: Created private network! " +
                                        $"| securityConfig = {securityConfig} | securityParameter = {securityParameter} " +
                                        $"| userConfig = {userConfig} | networkConfig = {networkConfig} | addressList = {addressList}");
                                }
                                else
                                {
                                    ResultCode created = _accessPoint.CreateNetwork(securityConfig, userConfig, networkConfig);

                                    if (created != ResultCode.Success)
                                    {
                                        return created;
                                    }

                                    Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"CreateNetworkImpl: Created network! " +
                                        $"| securityConfig = {securityConfig} | userConfig = {userConfig} | networkConfig = {networkConfig}");
                                }

                                return ResultCode.Success;
                            }
                            else
                            {
                                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "CreateNetworkImpl: Invalid state!");
                                return ResultCode.InvalidState;
                            }
                        }
                    }
                }
            }

            return ResultCode.InvalidArgument;
        }

        [CommandCmif(204)]
        // DestroyNetwork()
        public ResultCode DestroyNetwork(ServiceCtx context)
        {
            return DestroyNetworkImpl(DisconnectReason.DestroyedByUser);
        }

        private ResultCode DestroyNetworkImpl(DisconnectReason disconnectReason)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"DestroyNetworkImpl: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (disconnectReason - 3 <= DisconnectReason.DisconnectedByUser)
            {
                if (_state == NetworkState.AccessPointCreated)
                {
                    CloseAccessPoint();

                    SetState(NetworkState.AccessPoint);

                    return ResultCode.Success;
                }

                CloseAccessPoint();

                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "DestroyNetworkImpl: Invalid state!");
                return ResultCode.InvalidState;
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "DestroyNetworkImpl: Invalid argument!");
            return ResultCode.InvalidArgument;
        }

        [CommandCmif(205)]
        // Reject(u32 node_id)
        public ResultCode Reject(ServiceCtx context)
        {
            uint nodeId = context.RequestData.ReadUInt32();

            return RejectImpl(DisconnectReason.Rejected, nodeId);
        }

        private ResultCode RejectImpl(DisconnectReason disconnectReason, uint nodeId)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"RejectImpl: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (_state != NetworkState.AccessPointCreated)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "RejectImpl: Invalid state!");
                return ResultCode.InvalidState; // Must be network host to reject nodes.
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"RejectImpl: disconnectReason = {disconnectReason} | nodeId = {nodeId}");
            return NetworkClient.Reject(disconnectReason, nodeId);
        }

        [CommandCmif(206)]
        // SetAdvertiseData(buffer<advertise_data, 0x21>)
        public ResultCode SetAdvertiseData(ServiceCtx context)
        {
            (ulong bufferPosition, ulong bufferSize) = context.Request.GetBufferType0x21(0);

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"SetAdvertiseData: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (bufferSize is 0 or > LdnConst.AdvertiseDataSizeMax)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "SetAdvertiseData: Invalid argument!");
                return ResultCode.InvalidArgument;
            }

            if (_state is NetworkState.AccessPoint or NetworkState.AccessPointCreated)
            {
                byte[] advertiseData = new byte[bufferSize];

                context.Memory.Read(bufferPosition, advertiseData);
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"SetAdvertiseData: advertiseData = {advertiseData}");
                return _accessPoint.SetAdvertiseData(advertiseData);
            }
            else
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "SetAdvertiseData: Invalid state!");
                return ResultCode.InvalidState;
            }
        }

        [CommandCmif(207)]
        // SetStationAcceptPolicy(u8 accept_policy)
        public ResultCode SetStationAcceptPolicy(ServiceCtx context)
        {
            AcceptPolicy acceptPolicy = (AcceptPolicy)context.RequestData.ReadByte();

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"SetStationAcceptPolicy: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (acceptPolicy > AcceptPolicy.WhiteList)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "SetStationAcceptPolicy: Invalid argument!");
                return ResultCode.InvalidArgument;
            }

            if (_state is NetworkState.AccessPoint or NetworkState.AccessPointCreated)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"SetStationAcceptPolicy: acceptPolicy = {acceptPolicy}");
                return _accessPoint.SetStationAcceptPolicy(acceptPolicy);
            }
            else
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "SetStationAcceptPolicy: Invalid state!");
                return ResultCode.InvalidState;
            }
        }

        [CommandCmif(208)]
        // AddAcceptFilterEntry(bytes<6, 1> mac_address)
        public ResultCode AddAcceptFilterEntry(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"AddAcceptFilterEntry: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            // S2Arm (LDN G12): only an access point keeps an accept filter (nn::ldn: InvalidState otherwise); the host enforces it
            if (_accessPoint == null || (_state != NetworkState.AccessPoint && _state != NetworkState.AccessPointCreated))
            {
                return ResultCode.InvalidState;
            }

            _accessPoint.AddAcceptFilterEntry(context.RequestData.ReadBytes(6));

            return ResultCode.Success;
        }

        [CommandCmif(209)]
        // ClearAcceptFilter()
        public ResultCode ClearAcceptFilter(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ClearAcceptFilter: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            // S2Arm (LDN G12): same state rule as AddAcceptFilterEntry
            if (_accessPoint == null || (_state != NetworkState.AccessPoint && _state != NetworkState.AccessPointCreated))
            {
                return ResultCode.InvalidState;
            }

            _accessPoint.ClearAcceptFilter();

            return ResultCode.Success;
        }

        [CommandCmif(300)]
        // OpenStation()
        public ResultCode OpenStation(ServiceCtx context)
        {
            S2AActivateLan(context);   // S2Arm: a deferred Initialize starts the local network on the first room / station

            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"OpenStation: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (_state != NetworkState.Initialized)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "OpenStation: Invalid state!");
                return ResultCode.InvalidState;
            }

            CloseAccessPoint();
            RefreshNetworkClient(context);

            SetState(NetworkState.Station);

            _station?.Dispose();
            _station = new Station(this);

            // NOTE: Calls nifm service and returns related result codes.
            //       Since we use our own implementation we can return ResultCode.Success.
            
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"OpenStation: _station = {_station}");

            return ResultCode.Success;
        }

        [CommandCmif(301)]
        // CloseStation()
        public ResultCode CloseStation(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"CloseStation: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (_state is NetworkState.Station or NetworkState.StationConnected)
            {
                DisconnectImpl(DisconnectReason.DisconnectedByUser);
            }
            else
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "CloseStation: Invalid state!");
                return ResultCode.InvalidState;
            }

            SetState(NetworkState.Initialized);
            
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "CloseStation: Closed.");
            return ResultCode.Success;
        }

        private void CloseStation()
        {
            _station?.Dispose();
            _station = null;
        }

        [CommandCmif(302)]
        // Connect(bytes<0x44, 2> security_config, bytes<0x30, 1> user_config, u32 local_communication_version, u32 option_unknown, buffer<network_info<0x480>, 0x19>)
        public ResultCode Connect(ServiceCtx context)
        {
            return ConnectImpl(context);
        }

        [CommandCmif(303)]
        // ConnectPrivate(bytes<0x44, 2> security_config, bytes<0x20, 1> security_parameter, bytes<0x30, 1> user_config, u32 local_communication_version, u32 option_unknown, bytes<0x20, 8> network_config)
        public ResultCode ConnectPrivate(ServiceCtx context)
        {
            return ConnectImpl(context, true);
        }

        private ResultCode ConnectImpl(ServiceCtx context, bool isPrivate = false)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ConnectImpl: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            SecurityConfig securityConfig = context.RequestData.ReadStruct<SecurityConfig>();
            SecurityParameter securityParameter = isPrivate ? context.RequestData.ReadStruct<SecurityParameter>() : new SecurityParameter();

            UserConfig userConfig = context.RequestData.ReadStruct<UserConfig>();
            uint localCommunicationVersion = context.RequestData.ReadUInt32();
            uint optionUnknown = context.RequestData.ReadUInt32();

            NetworkConfig networkConfig = new();
            NetworkInfo networkInfo = new();

            if (isPrivate)
            {
                context.RequestData.ReadUInt32(); // Padding.

                networkConfig = context.RequestData.ReadStruct<NetworkConfig>();
            }
            else
            {
                ulong bufferPosition = context.Request.PtrBuff[0].Position;
                ulong bufferSize = context.Request.PtrBuff[0].Size;

                byte[] networkInfoBytes = new byte[bufferSize];

                context.Memory.Read(bufferPosition, networkInfoBytes);

                networkInfo = MemoryMarshal.Read<NetworkInfo>(networkInfoBytes);
            }

            if (networkInfo.NetworkId.IntentId.LocalCommunicationId == -1 && NetworkClient.NeedsRealId)
            {
                // TODO: Call nn::arp::GetApplicationControlProperty here when implemented.
                if (!TryGetControlProperty(context, out ApplicationControlProperty controlProperty))
                {
                    return ResultCode.InvalidObject;
                }
                networkInfo.NetworkId.IntentId.LocalCommunicationId = (long)controlProperty.LocalCommunicationId[0];
            }

            bool isLocalCommunicationIdValid = CheckLocalCommunicationIdPermission(context, (ulong)networkInfo.NetworkId.IntentId.LocalCommunicationId);
            if (!isLocalCommunicationIdValid && NetworkClient.NeedsRealId)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "ConnectImpl: Invalid object!");
                return ResultCode.InvalidObject;
            }

            securityConfig.SecurityMode = CheckDevelopmentSecurityMode(securityConfig.SecurityMode);

            ResultCode resultCode = ResultCode.InvalidArgument;

            if (securityConfig.SecurityMode - 1 <= SecurityMode.Debug)
            {
                if (optionUnknown <= 1 && (localCommunicationVersion >> 15) == 0 && securityConfig.PassphraseSize <= 64)
                {
                    resultCode = ResultCode.VersionTooLow;
                    if (localCommunicationVersion >= 0)
                    {
                        resultCode = ResultCode.VersionTooHigh;
                        if (localCommunicationVersion <= short.MaxValue)
                        {
                            if (_state != NetworkState.Station)
                            {
                                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "ConnectImpl: Invalid state!");
                                resultCode = ResultCode.InvalidState;
                            }
                            else
                            {
                                RefreshOpenNetworkClient(context);

                                if (isPrivate)
                                {
                                    resultCode = _station.ConnectPrivate(securityConfig, securityParameter, userConfig, localCommunicationVersion, optionUnknown, networkConfig);
                                    Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ConnectImpl: Private connection established! " +
                                        $"| securityConfig = {securityConfig} | securityParameter = {securityParameter} | userConfig = {userConfig} " +
                                        $"| localCommunicationVersion = {localCommunicationVersion} | optionUnknown = {optionUnknown} | networkConfig = {networkConfig}");
                                }
                                else
                                {
                                    resultCode = _station.Connect(securityConfig, userConfig, localCommunicationVersion, optionUnknown, networkInfo);
                                    Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ConnectImpl: Connection established! " +
                                        $"| securityConfig = {securityConfig} | userConfig = {userConfig} " +
                                        $"| localCommunicationVersion = {localCommunicationVersion} | optionUnknown = {optionUnknown} | networkConfig = {networkConfig}");
                                }
                            }
                        }
                    }
                }
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"ConnectImpl: resultCode = {resultCode}");

            return resultCode;
        }

        [CommandCmif(304)]
        // Disconnect()
        public ResultCode Disconnect(ServiceCtx context)
        {
            return DisconnectImpl(DisconnectReason.DisconnectedByUser);
        }

        private ResultCode DisconnectImpl(DisconnectReason disconnectReason)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"DisconnectImpl: _nifmResultCode = {_nifmResultCode}");
                return _nifmResultCode;
            }

            if (disconnectReason <= DisconnectReason.DisconnectedBySystem)
            {
                if (_state == NetworkState.StationConnected)
                {
                    SetState(NetworkState.Station);

                    CloseStation();

                    _disconnectReason = disconnectReason;

                    Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"DisconnectImpl: _disconnectReason = {_disconnectReason}");
                    return ResultCode.Success;
                }

                CloseStation();

                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "DisconnectImpl: Invalid state!");
                return ResultCode.InvalidState;
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "DisconnectImpl: Invalid argument!");
            return ResultCode.InvalidArgument;
        }

        [CommandCmif(400)]
        // InitializeOld(pid)
        public ResultCode InitializeOld(ServiceCtx context)
        {
            return InitializeImpl(context, context.Process.Pid, NifmRequestID);
        }

        [CommandCmif(401)]
        // Finalize()
        public ResultCode Finalize(ServiceCtx context)
        {
            if (_nifmResultCode != ResultCode.Success)
            {
                Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"Finalize: _disconnectReason = {_disconnectReason}");
                return _nifmResultCode;
            }

            // NOTE: Use true when its called in nn::ldn::detail::ISystemLocalCommunicationService
            ResultCode resultCode = FinalizeImpl(false);
            if (resultCode == ResultCode.Success)
            {
                SetDisconnectReason(DisconnectReason.None);
            }

            if (_stateChangeEventHandle != 0)
            {
                context.Process.HandleTable.CloseHandle(_stateChangeEventHandle);
                _stateChangeEventHandle = 0;
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"Finalize: resultCode = {resultCode}");
            return resultCode;
        }

        private ResultCode FinalizeImpl(bool isCausedBySystem)
        {
            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, "FinalizeImpl");
            DisconnectReason disconnectReason;

            switch (_state)
            {
                case NetworkState.None:
                    return ResultCode.Success;
                case NetworkState.AccessPoint:
                    {
                        CloseAccessPoint();

                        break;
                    }
                case NetworkState.AccessPointCreated:
                    {
                        if (isCausedBySystem)
                        {
                            disconnectReason = DisconnectReason.DestroyedBySystem;
                        }
                        else
                        {
                            disconnectReason = DisconnectReason.DestroyedByUser;
                        }

                        DestroyNetworkImpl(disconnectReason);

                        break;
                    }
                case NetworkState.Station:
                    {
                        CloseStation();

                        break;
                    }
                case NetworkState.StationConnected:
                    {
                        if (isCausedBySystem)
                        {
                            disconnectReason = DisconnectReason.DisconnectedBySystem;
                        }
                        else
                        {
                            disconnectReason = DisconnectReason.DisconnectedByUser;
                        }

                        DisconnectImpl(disconnectReason);

                        break;
                    }
            }

            SetState(NetworkState.None);

            NetworkClient?.Dispose();
            NetworkClient = null;
            S2ANetworkClientServer = null;
            _s2aLanDeferred = false;

            return ResultCode.Success;
        }

        [CommandCmif(402)] // 7.0.0+
        // Initialize(u64 ip_addresses, pid)
        public ResultCode Initialize(ServiceCtx context)
        {
            _ = new IPAddress(context.RequestData.ReadUInt32());
            _ = new IPAddress(context.RequestData.ReadUInt32());

            // NOTE: It seems the guest can get ip_address and subnet_mask from nifm service and pass it through the initialize.
            //       This calls InitializeImpl() twice: The first time with NIFM_REQUEST_ID, and if it fails, a second time with nifm_request_id = 1.

            return InitializeImpl(context, context.Process.Pid, NifmRequestID);
        }

        public ResultCode InitializeImpl(ServiceCtx context, ulong pid, int nifmRequestId)
        {
            ResultCode resultCode = ResultCode.InvalidArgument;

            if (nifmRequestId <= 255)
            {
                if (_state != NetworkState.Initialized)
                {
                    if (S2AHooks.LdnDeferInit?.Invoke() == true)
                    {
                        // S2Arm: many games initialize ldn:u at boot and never play locally; starting discovery / the relay / the ldn_mitm sockets here
                        // asked every such player for the local-network permission. Succeed with no neighbours; the first scan / room / station starts it
                        Logger.Info?.PrintMsg(LogClass.ServiceLdn, "Initializing with the local network deferred to the first scan / access point / station");
                        NetworkClient = new LdnDisabledClient();
                        _s2aLanDeferred = true;
                        resultCode = ResultCode.Success;
                        _nifmResultCode = resultCode;
                    }
                    else
                    {
                        resultCode = S2AStartNetwork(context);
                    }

                    if (resultCode == ResultCode.Success)
                    {
                        SetState(NetworkState.Initialized);
                    }
                }
            }

            Logger.NetLog?.PrintMsg(LogClass.ServiceLdn, $"InitializeImpl: resultCode = {resultCode}");
            return resultCode;
        }

        // S2Arm: the host picks / starts the multiplayer mode (LdnInitializing: LAN discovery + relay, or ldn_mitm), then the client for it is built.
        // Initialize runs this directly, or the first Scan / OpenAccessPoint / OpenStation after a deferred Initialize (S2AActivateLan)
        private ResultCode S2AStartNetwork(ServiceCtx context)
        {
            S2AHooks.LdnInitializing?.Invoke();

            // NOTE: Service calls nn::ldn::detail::NetworkInterfaceManager::NetworkInterfaceMonitor::Initialize() with nifmRequestId as argument,
            //       then it stores the result code of it in a global variable. Since we use our own implementation, we can just check the connection
            //       and return related error codes.
            MultiplayerMode mode = context.Device.Configuration.MultiplayerMode;
            ResultCode resultCode;

            // S2Arm: with multiplayer disabled the service reports unavailable without touching
            // the network, so the host's interfaces are not queried either
            if ((mode == MultiplayerMode.Disabled && !LdnAutoRequested) ||
                System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable())
            {
                Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"Initializing with multiplayer mode: {mode}");
                resultCode = CreateNetworkClient(context, mode);
            }
            else
            {
                // NOTE: Service returns different ResultCode here related to the nifm ResultCode.
                resultCode = ResultCode.DeviceDisabled;
            }

            _nifmResultCode = resultCode;
            return resultCode;
        }

        // S2Arm: first local-wireless use after a deferred Initialize. A failure (no network, discovery unavailable, metadata missing) lands in
        // _nifmResultCode, so this call and the later ones report it the way a failed Initialize would have
        private void S2AActivateLan(ServiceCtx context)
        {
            if (!_s2aLanDeferred)
            {
                return;
            }

            _s2aLanDeferred = false;
            NetworkClient?.DisconnectAndStop();
            NetworkClient = null;
            if (S2AStartNetwork(context) != ResultCode.Success)
            {
                NetworkClient = new LdnDisabledClient();
            }
        }

        // S2Arm: the RyuLDN server the current client was built for (null for the other modes); tests read it
        internal string S2ANetworkClientServer { get; private set; }

        private ResultCode CreateNetworkClient(ServiceCtx context, MultiplayerMode mode)
        {
            S2ANetworkClientServer = null;

            if (!LdnAutoRequested && mode == MultiplayerMode.Disabled)
            {
                // S2Arm: local wireless discovery / multiplayer is unavailable. Return
                // the service's own result code and report once, instead of handing a
                // client forward whose later calls dereference missing game metadata.
                if (!_unavailableReported)
                {
                    _unavailableReported = true;
                    S2AHooks.Red?.Invoke("ldn: local wireless unavailable, reporting DeviceNotAvailable");
                }
                return ResultCode.DeviceNotAvailable;
            }

            // TODO: Call nn::arp::GetApplicationLaunchProperty here when implemented.
            // S2Arm: read the metadata before constructing the client: a missing process
            // entry must fail the call without leaving a half-created client behind.
            if (!TryGetControlProperty(context, out ApplicationControlProperty controlProperty))
            {
                return ResultCode.InvalidState;
            }

            if (LdnAutoRequested)
            {
                try
                {
                    Logger.Info?.PrintMsg(
                        LogClass.ServiceLdn,
                        $"Auto LDN branch: envAuto={Environment.GetEnvironmentVariable("S2A_LDN_AUTO")}, " +
                        $"envMitm={Environment.GetEnvironmentVariable("S2A_LDN_MITM")}, " +
                        $"envServer={Environment.GetEnvironmentVariable("S2A_LDN_SERVER")}, " +
                        $"mode={mode}, configServer={context.Device.Configuration.MultiplayerLdnServer}");
                    NetworkClient = new LdnAutoClient(context.Device.Configuration);
                    S2ANetworkClientServer = context.Device.Configuration.MultiplayerLdnServer;
                    NetworkClient.SetGameVersion(controlProperty.DisplayVersion);
                    return ResultCode.Success;
                }
                catch (Exception ex)
                {
                    Logger.Error?.Print(LogClass.ServiceLdn, $"Could not initialize automatic LDN: {ex.Message}");
                    S2AHooks.Red?.Invoke($"ldn: automatic LAN is unavailable, {ex.Message}");
                    return ResultCode.DeviceNotAvailable;
                }
            }

            switch (mode)
            {
                case MultiplayerMode.LdnRyu:
                    try
                    {
                        string ldnServer = context.Device.Configuration.MultiplayerLdnServer
                                           ?? throw new InvalidOperationException("Cannot initialize RyuLDN with a null Multiplayer server.");

                        if (!IPAddress.TryParse(ldnServer, out IPAddress ipAddress))
                        {
                            ipAddress = Dns.GetHostEntry(ldnServer).AddressList[0];
                        }

                        NetworkClient = new LdnMasterProxyClient(ipAddress.ToString(), S2AHooks.LdnPort, context.Device.Configuration);
                        S2ANetworkClientServer = ldnServer;
                    }
                    catch (Exception ex)
                    {
                        Logger.Error?.Print(LogClass.ServiceLdn, "Could not locate RyuLDN server. Defaulting to stubbed wireless.");
                        S2AHooks.Red?.Invoke($"ldn: RyuLDN server {context.Device.Configuration.MultiplayerLdnServer} not resolvable, multiplayer falls back to nobody nearby");
                        Logger.Error?.Print(LogClass.ServiceLdn, ex.Message);
                        NetworkClient = new LdnDisabledClient();
                    }

                    break;
                case MultiplayerMode.LdnMitm:
                    try
                    {
                        NetworkClient = new LdnMitmClient(context.Device.Configuration);
                    }
                    catch (Exception ex)
                    {
                        Logger.Error?.Print(LogClass.ServiceLdn, $"Could not initialize ldn_mitm: {ex.Message}");
                        S2AHooks.Red?.Invoke($"ldn: ldn_mitm unavailable, {ex.Message}");
                        return ResultCode.DeviceNotAvailable;
                    }
                    break;
            }

            NetworkClient.SetGameVersion(controlProperty.DisplayVersion);

            return ResultCode.Success;
        }

        // S2Arm: the host can re-point the RyuLDN server while the game is initialized but idle (LAN relay election, Host.SetLdnServer).
        // Applied at the next OpenAccessPoint / OpenStation, i.e. right before the game creates or looks for a network: the client is only
        // swapped in state Initialized (nothing created or joined), and before AccessPoint / Station subscribe to its NetworkChange event
        // S2Arm: same, for a scan / create / connect issued while a station or access point is already open but nothing is joined or created yet
        // (audit #723 P1: LAN discovery starts at the first Initialize, so the game can open its station / access point on the local relay before
        // the Bonjour election resolves; a station scans many times inside one OpenStation, so waiting for the next Open* never re-points it).
        // The open Station / AccessPoint is rebuilt on the new client: it subscribed to the old client's NetworkChange.
        private void RefreshOpenNetworkClient(ServiceCtx context)
        {
            if (context.Device.Configuration.MultiplayerMode != MultiplayerMode.LdnRyu)
            {
                return;
            }

            string server = context.Device.Configuration.MultiplayerLdnServer;

            if (string.IsNullOrEmpty(server) || server == S2ANetworkClientServer)
            {
                return;
            }

            switch (_state)
            {
                case NetworkState.Initialized:
                    RefreshNetworkClient(context);
                    break;
                case NetworkState.Station:
                    _station?.Dispose();
                    _station = null;
                    RefreshNetworkClient(context);
                    _station = new Station(this);
                    break;
                case NetworkState.AccessPoint:
                    // S2A（审计 #748 P1）：接入点不重建，广告数据留在原对象上；只换订阅（旧客户端由 RefreshNetworkClient 断开停掉）
                    _accessPoint?.S2AUnbindClient();
                    RefreshNetworkClient(context);
                    _accessPoint?.S2ABindClient();
                    break;
            }
        }

        private void RefreshNetworkClient(ServiceCtx context)
        {
            if (context.Device.Configuration.MultiplayerMode != MultiplayerMode.LdnRyu)
            {
                return;
            }

            string server = context.Device.Configuration.MultiplayerLdnServer;

            if (string.IsNullOrEmpty(server) || server == S2ANetworkClientServer)
            {
                return;
            }

            Logger.Info?.PrintMsg(LogClass.ServiceLdn, $"RyuLDN server changed {S2ANetworkClientServer ?? "(none)"} -> {server}, reconnecting");
            NetworkClient?.DisconnectAndStop();
            NetworkClient = null;
            CreateNetworkClient(context, MultiplayerMode.LdnRyu);
        }

        public void Dispose()
        {
            _station?.Dispose();
            _station = null;

            _accessPoint?.Dispose();
            _accessPoint = null;

            NetworkClient?.DisconnectAndStop();
            NetworkClient = null;
        }
    }
}
