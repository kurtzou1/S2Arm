using Ryujinx.Common.Logging;
using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnMitm;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator
{
    /// <summary>
    /// Keeps both LAN transports available in automatic mode. Room scans identify the protocol
    /// that can reach each peer before the game connects.
    /// </summary>
    internal sealed class LdnAutoClient : INetworkClient
    {
        private readonly HleConfiguration _configuration;
        private readonly INetworkClient _mitm;
        private readonly INetworkClient _ryu;
        private readonly object _sync = new();
        private readonly Dictionary<string, INetworkClient> _roomSources = new();

        private INetworkClient _selected;

        public LdnAutoClient(HleConfiguration configuration)
            : this(
                configuration,
                new LdnMitmClient(configuration),
                new LdnMasterProxyClient(
                    ResolveRyuServer(configuration?.MultiplayerLdnServer),
                    S2AHooks.LdnPort,
                    configuration))
        {
        }

        // Automatic mode can start before a LAN relay has been elected, in which case
        // MultiplayerLdnServer is the empty string (not null). `??` does not cover that,
        // and LdnMasterProxyClient treats an empty address as invalid and throws while
        // constructing, taking the whole dual-protocol client down. Fall back on any
        // null/empty value so automatic mode can always construct both channels.
        internal static string ResolveRyuServer(string server)
        {
            return string.IsNullOrEmpty(server) ? "127.0.0.1" : server;
        }

        internal LdnAutoClient(
            HleConfiguration configuration,
            INetworkClient mitm,
            INetworkClient ryu)
        {
            _configuration = configuration;
            _mitm = mitm;
            _ryu = ryu;

            _mitm.NetworkChange += ForwardNetworkChange;
            _ryu.NetworkChange += ForwardNetworkChange;
        }

        public ProxyConfig Config
        {
            get
            {
                lock (_sync)
                {
                    return _selected?.Config ?? default;
                }
            }
        }

        public bool NeedsRealId => true;

        public event EventHandler<NetworkChangeEventArgs> NetworkChange;

        public void DisconnectNetwork()
        {
            lock (_sync)
            {
                if (_selected != null)
                {
                    _selected.DisconnectNetwork();
                    return;
                }
            }

            _mitm.DisconnectNetwork();
            _ryu.DisconnectNetwork();
        }

        public void DisconnectAndStop()
        {
            _mitm.DisconnectAndStop();
            _ryu.DisconnectAndStop();
        }

        public NetworkError Connect(ConnectRequest request)
        {
            INetworkClient target = SourceFor(request.NetworkInfo);
            Select(target);

            NetworkError error = target.Connect(request);
            if (error == NetworkError.None)
            {
                return error;
            }

            INetworkClient fallback = Other(target);
            Logger.Warning?.PrintMsg(
                LogClass.ServiceLdn,
                $"Auto LDN {Name(target)} connect failed ({error}); retrying with {Name(fallback)}");

            target.DisconnectNetwork();
            Select(fallback);
            return fallback.Connect(request);
        }

        public NetworkError ConnectPrivate(ConnectPrivateRequest request)
        {
            INetworkClient target = PreferredHostClient();
            Select(target);
            return target.ConnectPrivate(request);
        }

        public ResultCode Reject(DisconnectReason disconnectReason, uint nodeId)
        {
            lock (_sync)
            {
                return (_selected ?? _mitm).Reject(disconnectReason, nodeId);
            }
        }

        public NetworkInfo[] Scan(ushort channel, ScanFilter scanFilter)
        {
            Task<NetworkInfo[]> mitmTask = Task.Run(() => SafeScan(_mitm, channel, scanFilter, "ldn_mitm"));
            Task<NetworkInfo[]> ryuTask = Task.Run(() => SafeScan(_ryu, channel, scanFilter, "RyuLDN"));

            Task.WaitAll(mitmTask, ryuTask);

            NetworkInfo[] mitmRooms = mitmTask.Result;
            NetworkInfo[] ryuRooms = ryuTask.Result;
            List<NetworkInfo> merged = [];
            HashSet<string> seen = [];

            lock (_sync)
            {
                _roomSources.Clear();

                AddRooms(merged, seen, mitmRooms, _mitm);
                AddRooms(merged, seen, ryuRooms, _ryu);

            }

            Logger.Info?.PrintMsg(
                LogClass.ServiceLdn,
                $"Auto LDN scan: ldn_mitm={mitmRooms.Length}, RyuLDN={ryuRooms.Length}, merged={merged.Count}");

            return merged.ToArray();
        }

        public void SetGameVersion(ReadOnlySpan<byte> versionString)
        {
            _mitm.SetGameVersion(versionString);
            _ryu.SetGameVersion(versionString);
        }

        public void SetStationAcceptPolicy(AcceptPolicy acceptPolicy)
        {
            _mitm.SetStationAcceptPolicy(acceptPolicy);
            _ryu.SetStationAcceptPolicy(acceptPolicy);
        }

        public void SetAdvertiseData(byte[] data)
        {
            _mitm.SetAdvertiseData(data);
            _ryu.SetAdvertiseData(data);
        }

        public bool CreateNetwork(CreateAccessPointRequest request, byte[] advertiseData)
        {
            INetworkClient target = PreferredHostClient();
            Select(target);
            Logger.Info?.PrintMsg(
                LogClass.ServiceLdn,
                $"Auto LDN host selection: target={Name(target)}");
            Console.Error.WriteLine($"[S2A 联机] Auto LDN host selection: target={Name(target)}");

            if (target.CreateNetwork(request, advertiseData))
            {
                return true;
            }

            INetworkClient fallback = Other(target);
            Logger.Warning?.PrintMsg(
                LogClass.ServiceLdn,
                $"Auto LDN {Name(target)} host creation failed; retrying with {Name(fallback)}");

            target.DisconnectNetwork();
            Select(fallback);
            return fallback.CreateNetwork(request, advertiseData);
        }

        public bool CreateNetworkPrivate(CreateAccessPointPrivateRequest request, byte[] advertiseData)
        {
            INetworkClient target = PreferredHostClient();
            Select(target);

            if (target.CreateNetworkPrivate(request, advertiseData))
            {
                return true;
            }

            INetworkClient fallback = Other(target);
            Logger.Warning?.PrintMsg(
                LogClass.ServiceLdn,
                $"Auto LDN {Name(target)} private host creation failed; retrying with {Name(fallback)}");

            target.DisconnectNetwork();
            Select(fallback);
            return fallback.CreateNetworkPrivate(request, advertiseData);
        }

        public void Dispose()
        {
            _mitm.NetworkChange -= ForwardNetworkChange;
            _ryu.NetworkChange -= ForwardNetworkChange;
            _mitm.Dispose();
            _ryu.Dispose();
        }

        private static NetworkInfo[] SafeScan(
            INetworkClient client,
            ushort channel,
            ScanFilter scanFilter,
            string name)
        {
            try
            {
                return client.Scan(channel, scanFilter);
            }
            catch (Exception ex)
            {
                Logger.Warning?.PrintMsg(LogClass.ServiceLdn, $"Auto LDN {name} scan failed: {ex.Message}");
                return [];
            }
        }

        private void AddRooms(
            List<NetworkInfo> merged,
            HashSet<string> seen,
            NetworkInfo[] rooms,
            INetworkClient source)
        {
            foreach (NetworkInfo room in rooms)
            {
                string key = RoomKey(room);
                if (seen.Add(key))
                {
                    merged.Add(room);
                }

                _roomSources.TryAdd(key, source);
            }
        }

        private INetworkClient SourceFor(in NetworkInfo networkInfo)
        {
            string key = RoomKey(networkInfo);

            lock (_sync)
            {
                if (_roomSources.TryGetValue(key, out INetworkClient source))
                {
                    return source;
                }

                return PreferredHostClientLocked();
            }
        }

        private INetworkClient PreferredHostClient()
        {
            lock (_sync)
            {
                return PreferredHostClientLocked();
            }
        }

        private INetworkClient PreferredHostClientLocked()
        {
            return _mitm;
        }

        private INetworkClient Other(INetworkClient target)
        {
            return target == _mitm ? _ryu : _mitm;
        }

        private string Name(INetworkClient client)
        {
            return client == _mitm ? "ldn_mitm" : "RyuLDN";
        }

        private void Select(INetworkClient target)
        {
            lock (_sync)
            {
                _selected = target;

                if (_configuration == null)
                {
                    return;
                }

                if (target == _mitm)
                {
                    _configuration.MultiplayerMode = MultiplayerMode.LdnMitm;
                    _configuration.MultiplayerLdnServer = string.Empty;
                }
                else
                {
                    _configuration.MultiplayerMode = MultiplayerMode.LdnRyu;
                    if (string.IsNullOrEmpty(_configuration.MultiplayerLdnServer))
                    {
                        _configuration.MultiplayerLdnServer = "127.0.0.1";
                    }
                }
            }
        }

        private void ForwardNetworkChange(object sender, NetworkChangeEventArgs args)
        {
            lock (_sync)
            {
                if (_selected != sender)
                {
                    return;
                }
            }

            NetworkChange?.Invoke(this, args);
        }

        private static string RoomKey(in NetworkInfo networkInfo)
        {
            Span<byte> bytes = stackalloc byte[Marshal.SizeOf<NetworkId>()];
            MemoryMarshal.Write(bytes, in networkInfo.NetworkId);
            return Convert.ToHexString(bytes);
        }
    }
}
