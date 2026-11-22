using System.Buffers.Binary;
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Ryujinx.Common.Utilities
{
    public static class NetworkHelpers
    {
        private static (IPInterfaceProperties, UnicastIPAddressInformation) GetLocalInterface(NetworkInterface adapter, bool isPreferred)
        {
            IPInterfaceProperties properties = adapter.GetIPProperties();

            if (isPreferred || (properties.GatewayAddresses.Count > 0 && properties.DnsAddresses.Count > 0))
            {
                foreach (UnicastIPAddressInformation info in properties.UnicastAddresses)
                {
                    // Only accept an IPv4 address
                    if (info.Address.GetAddressBytes().Length == 4)
                    {
                        return (properties, info);
                    }
                }
            }

            return (null, null);
        }

        public static (IPInterfaceProperties, UnicastIPAddressInformation) GetLocalInterface(string lanInterfaceId = "0")
        {
            if (!NetworkInterface.GetIsNetworkAvailable())
            {
                return (null, null);
            }

            IPInterfaceProperties targetProperties = null;
            UnicastIPAddressInformation targetAddressInfo = null;

            NetworkInterface[] interfaces = NetworkInterface.GetAllNetworkInterfaces();

            string guid = lanInterfaceId;
            bool hasPreference = guid != "0";

            foreach (NetworkInterface adapter in interfaces)
            {
                bool isPreferred = adapter.Id == guid;

                // Ignore loopback and non IPv4 capable interface.
                if (isPreferred || (targetProperties == null && adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback && adapter.Supports(NetworkInterfaceComponent.IPv4)))
                {
                    (IPInterfaceProperties properties, UnicastIPAddressInformation info) = GetLocalInterface(adapter, isPreferred);

                    if (properties != null)
                    {
                        targetProperties = properties;
                        targetAddressInfo = info;

                        if (isPreferred || !hasPreference)
                        {
                            break;
                        }
                    }
                }
            }

            return (targetProperties, targetAddressInfo);
        }

        // Pick the local IPv4 address the OS would actually use for a target. Enumeration order is
        // not a route: machines can have Ethernet, Wi-Fi and VPN adapters on the same subnet, and
        // only the target route identifies the source address that can reach the peer.
        public static (IPInterfaceProperties properties, UnicastIPAddressInformation address) GetLocalInterfaceForTarget(
            string lanInterfaceId,
            IPAddress remoteAddress)
        {
            if (remoteAddress != null && remoteAddress.AddressFamily != AddressFamily.InterNetwork)
            {
                remoteAddress = null;
            }

            if (remoteAddress != null && IPAddress.IsLoopback(remoteAddress))
            {
                var loopback = FindInterfaceByAddress(IPAddress.Loopback);
                return loopback.properties != null ? loopback : (null, null);
            }

            NetworkInterface[] interfaces = NetworkInterface.GetAllNetworkInterfaces();
            NetworkInterface preferred = string.IsNullOrEmpty(lanInterfaceId) || lanInterfaceId == "0"
                ? null
                : Array.Find(interfaces, adapter => adapter.Id == lanInterfaceId);
            UnicastIPAddressInformation preferredAddress = GetIpv4Unicast(preferred);

            if (remoteAddress != null)
            {
                IPAddress source = ProbeRouteSource(remoteAddress, preferredAddress?.Address);
                if (source != null)
                {
                    var routed = FindInterfaceByAddress(source);
                    NetworkInterface routedAdapter = FindAdapterByAddress(source);
                    if (routed.properties != null && (!IsLocalTarget(remoteAddress) || !IsTunnel(routedAdapter)))
                    {
                        return routed;
                    }
                }

                // An explicit interface remains authoritative while it is active. This also covers
                // targets for which a connect-only UDP probe cannot expose a source address.
                if (preferredAddress != null && preferred is { OperationalStatus: OperationalStatus.Up })
                {
                    return (preferred.GetIPProperties(), preferredAddress);
                }
            }
            else if (preferredAddress != null && preferred is { OperationalStatus: OperationalStatus.Up })
            {
                return (preferred.GetIPProperties(), preferredAddress);
            }

            // A route probe resolves the usual "which adapter wins?" ambiguity without sending
            // traffic. Before a peer is known, the system default route is the strongest signal,
            // but a VPN source must be rejected for a LAN room. If there is no usable default
            // route, score every physical gateway source instead of trusting enumeration order.
            IPAddress defaultSource = null;
            if (remoteAddress == null)
            {
                IPAddress routedSource = ProbeRouteSource(DefaultRouteProbeTarget, null);
                if (!IsTunnel(FindAdapterByAddress(routedSource)))
                {
                    defaultSource = routedSource;
                }

                defaultSource ??= ProbeLanGatewaySource(interfaces);
            }
            else
            {
                defaultSource = ProbeRouteSource(remoteAddress, null);
            }

            if (defaultSource != null)
            {
                var routed = FindInterfaceByAddress(defaultSource);
                NetworkInterface routedAdapter = FindAdapterByAddress(defaultSource);
                if (routed.properties != null &&
                    (remoteAddress == null
                        ? !IsTunnel(routedAdapter)
                        : !IsLocalTarget(remoteAddress) || !IsTunnel(routedAdapter)))
                {
                    return routed;
                }
            }

            return SelectBestLocalInterface(interfaces, remoteAddress, preferredAddress?.Address);
        }

        // The probe must use a non-zero destination port: macOS rejects connect() on a UDP socket
        // whose destination port is 0 (EADDRNOTAVAIL). Any non-zero port performs the same route
        // lookup without sending a packet.
        private const int RouteProbePort = 9;
        private static readonly IPAddress DefaultRouteProbeTarget = new(new byte[] { 192, 0, 2, 1 });

        internal readonly record struct LanRouteCandidate(
            IPAddress Source,
            bool IsUp,
            bool IsTunnel,
            bool IsPhysical,
            bool IsWired,
            bool SharesGatewaySubnet,
            bool IsLinkLocal);

        // Rank every discovered source deterministically. A machine can have an arbitrary number
        // of wired, wireless, virtual and tunnel adapters; the first one enumerated is not a
        // reliable answer. The default-route probe remains authoritative when it yields a LAN
        // adapter, while this score handles machines whose default route is a VPN.
        internal static IPAddress SelectBestLanRouteCandidate(IReadOnlyList<LanRouteCandidate> candidates)
        {
            LanRouteCandidate best = default;
            int bestScore = int.MinValue;
            bool hasBest = false;

            foreach (LanRouteCandidate candidate in candidates)
            {
                if (candidate.Source == null ||
                    candidate.Source.Equals(IPAddress.Any) ||
                    candidate.Source.Equals(IPAddress.None))
                {
                    continue;
                }

                int score = 0;
                score += candidate.IsUp ? 1000 : -10000;
                score += candidate.IsTunnel ? -5000 : 0;
                score += candidate.IsPhysical ? 100 : 0;
                score += candidate.IsWired ? 20 : 0;
                score += candidate.SharesGatewaySubnet ? 400 : 0;
                score += candidate.IsLinkLocal ? -2000 : 0;

                if (!hasBest ||
                    score > bestScore ||
                    (score == bestScore && CompareIpv4(candidate.Source, best.Source) < 0))
                {
                    best = candidate;
                    bestScore = score;
                    hasBest = true;
                }
            }

            return hasBest && best.IsUp && !best.IsTunnel ? best.Source : null;
        }

        public static IPAddress ProbeRouteSource(IPAddress remoteAddress, IPAddress preferredSource)
        {
            if (remoteAddress == null ||
                remoteAddress.Equals(IPAddress.Any) ||
                remoteAddress.Equals(IPAddress.None))
            {
                return null;
            }

            try
            {
                using Socket socket = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);

                if (preferredSource != null)
                {
                    socket.Bind(new IPEndPoint(preferredSource, 0));
                }

                socket.Connect(remoteAddress, RouteProbePort);

                return socket.LocalEndPoint is IPEndPoint endpoint ? endpoint.Address : null;
            }
            catch (SocketException)
            {
                return null;
            }
            catch (ObjectDisposedException)
            {
                return null;
            }
        }

        // The OS route to a LAN gateway says which adapter carries local traffic while no peer
        // address is known yet. Collect and rank all candidates so the result does not depend on
        // the number of adapters or the order NetworkInterface happens to enumerate them in.
        private static IPAddress ProbeLanGatewaySource(NetworkInterface[] interfaces)
        {
            List<LanRouteCandidate> candidates = [];

            foreach (NetworkInterface adapter in interfaces)
            {
                if (adapter.OperationalStatus != OperationalStatus.Up ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    IsTunnel(adapter))
                {
                    continue;
                }

                foreach (GatewayIPAddressInformation gatewayInfo in adapter.GetIPProperties().GatewayAddresses)
                {
                    IPAddress gateway = gatewayInfo.Address;
                    if (gateway.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(gateway))
                    {
                        continue;
                    }

                    IPAddress source = ProbeRouteSource(gateway, null);
                    if (source == null)
                    {
                        continue;
                    }

                    NetworkInterface sourceAdapter = FindAdapterByAddress(source);
                    UnicastIPAddressInformation sourceAddress = FindIpv4Unicast(sourceAdapter, source);
                    if (sourceAddress == null)
                    {
                        continue;
                    }

                    NetworkInterfaceType type = sourceAdapter.NetworkInterfaceType;
                    bool isPhysical = IsPhysicalLanAdapter(type);
                    bool isWired = type is NetworkInterfaceType.Ethernet or
                        NetworkInterfaceType.GigabitEthernet;

                    candidates.Add(new LanRouteCandidate(
                        source,
                        sourceAdapter.OperationalStatus == OperationalStatus.Up,
                        IsTunnel(sourceAdapter),
                        isPhysical,
                        isWired,
                        IsSameSubnet(sourceAddress, gateway),
                        sourceAddress.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal)));
                }
            }

            return SelectBestLanRouteCandidate(candidates);
        }

        private static (IPInterfaceProperties properties, UnicastIPAddressInformation address) FindInterfaceByAddress(IPAddress address)
        {
            if (address == null)
            {
                return (null, null);
            }

            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                UnicastIPAddressInformation unicast = FindIpv4Unicast(adapter, address);
                if (unicast != null)
                {
                    return (adapter.GetIPProperties(), unicast);
                }
            }

            return (null, null);
        }

        private static NetworkInterface FindAdapterByAddress(IPAddress address)
        {
            if (address == null)
            {
                return null;
            }

            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (FindIpv4Unicast(adapter, address) != null)
                {
                    return adapter;
                }
            }

            return null;
        }

        private static UnicastIPAddressInformation FindIpv4Unicast(NetworkInterface adapter, IPAddress address)
        {
            if (adapter == null || address == null || !adapter.Supports(NetworkInterfaceComponent.IPv4))
            {
                return null;
            }

            foreach (UnicastIPAddressInformation info in adapter.GetIPProperties().UnicastAddresses)
            {
                if (info.Address.AddressFamily == AddressFamily.InterNetwork && info.Address.Equals(address))
                {
                    return info;
                }
            }

            return null;
        }

        private static UnicastIPAddressInformation GetIpv4Unicast(NetworkInterface adapter)
        {
            if (adapter == null || !adapter.Supports(NetworkInterfaceComponent.IPv4))
            {
                return null;
            }

            foreach (UnicastIPAddressInformation info in adapter.GetIPProperties().UnicastAddresses)
            {
                if (info.Address.AddressFamily == AddressFamily.InterNetwork)
                {
                    return info;
                }
            }

            return null;
        }

        private static (IPInterfaceProperties properties, UnicastIPAddressInformation address) SelectBestLocalInterface(
            NetworkInterface[] interfaces,
            IPAddress remoteAddress,
            IPAddress preferredAddress)
        {
            IPInterfaceProperties bestProperties = null;
            UnicastIPAddressInformation bestAddress = null;
            int bestScore = int.MinValue;

            foreach (NetworkInterface adapter in interfaces)
            {
                if (adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                UnicastIPAddressInformation address = GetIpv4Unicast(adapter);
                if (address == null)
                {
                    continue;
                }

                IPInterfaceProperties properties = adapter.GetIPProperties();
                int score = 0;

                if (adapter.OperationalStatus == OperationalStatus.Up) score += 100;
                if (properties.GatewayAddresses.Count > 0) score += 40;
                if (properties.DnsAddresses.Count > 0) score += 10;
                if (IsPhysicalLanAdapter(adapter.NetworkInterfaceType)) score += 80;
                if (IsTunnel(adapter)) score -= 500;
                if (address.Address.Equals(preferredAddress)) score += 10000;

                if (remoteAddress != null && IsSameSubnet(address, remoteAddress))
                {
                    score += 1000;
                }

                if (address.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                {
                    score -= 200;
                }

                if (score > bestScore)
                {
                    bestScore = score;
                    bestProperties = properties;
                    bestAddress = address;
                }
            }

            return (bestProperties, bestAddress);
        }

        private static bool IsSameSubnet(UnicastIPAddressInformation local, IPAddress remote)
        {
            if (local.IPv4Mask == null)
            {
                return false;
            }

            byte[] localBytes = local.Address.GetAddressBytes();
            byte[] remoteBytes = remote.GetAddressBytes();
            byte[] mask = local.IPv4Mask.GetAddressBytes();

            for (int i = 0; i < localBytes.Length; i++)
            {
                if ((localBytes[i] & mask[i]) != (remoteBytes[i] & mask[i]))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool IsPhysicalLanAdapter(NetworkInterfaceType type)
        {
            return type is NetworkInterfaceType.Ethernet or
                NetworkInterfaceType.GigabitEthernet or
                NetworkInterfaceType.Wireless80211;
        }

        private static int CompareIpv4(IPAddress left, IPAddress right)
        {
            byte[] leftBytes = left.GetAddressBytes();
            byte[] rightBytes = right.GetAddressBytes();

            for (int i = 0; i < leftBytes.Length; i++)
            {
                int comparison = leftBytes[i].CompareTo(rightBytes[i]);
                if (comparison != 0)
                {
                    return comparison;
                }
            }

            return 0;
        }

        private static bool IsTunnel(NetworkInterface adapter)
        {
            if (adapter == null)
            {
                return false;
            }

            string name = adapter.Name ?? string.Empty;
            return adapter.NetworkInterfaceType is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp ||
                   name.StartsWith("utun", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("tun", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("ipsec", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("ppp", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsLocalTarget(IPAddress address)
        {
            if (address.Equals(IPAddress.Broadcast) || address.Equals(IPAddress.None))
            {
                return true;
            }

            byte[] bytes = address.GetAddressBytes();
            if (bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 169 && bytes[1] == 254))
            {
                return true;
            }

            return (bytes[0] & 0xF0) == 0xE0;
        }

        public static bool SupportsDynamicDns()
        {
            return RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        }

        public static uint ConvertIpv4Address(IPAddress ipAddress)
        {
            return BinaryPrimitives.ReadUInt32BigEndian(ipAddress.GetAddressBytes());
        }

        public static uint ConvertIpv4Address(string ipAddress)
        {
            return ConvertIpv4Address(IPAddress.Parse(ipAddress));
        }

        public static IPAddress ConvertUint(uint ipAddress)
        {
            return new IPAddress(new byte[] { (byte)((ipAddress >> 24) & 0xFF), (byte)((ipAddress >> 16) & 0xFF), (byte)((ipAddress >> 8) & 0xFF), (byte)(ipAddress & 0xFF) });
        }
    }
}
