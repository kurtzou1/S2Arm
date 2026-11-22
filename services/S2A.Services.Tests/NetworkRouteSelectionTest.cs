using Ryujinx.Common.Utilities;
using System;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--network-route-selection")]
        private static int NetworkRouteSelection()
        {
            var local = NetworkHelpers.GetLocalInterfaceForTarget("0", IPAddress.Loopback);
            bool loopbackSelected = local.address?.Address.Equals(IPAddress.Loopback) == true;
            var fallback = NetworkHelpers.GetLocalInterfaceForTarget("interface-that-does-not-exist", IPAddress.Loopback);
            bool fallbackSelected = fallback.address?.Address.Equals(IPAddress.Loopback) == true;

            // Negative control: the old enumeration-order API deliberately skips loopback, so it
            // cannot satisfy this target-based contract even when the new API does.
            var legacy = NetworkHelpers.GetLocalInterface("0");
            bool legacyWouldMissLoopback = legacy.Item2 == null || !legacy.Item2.Address.Equals(IPAddress.Loopback);

            // macOS rejects connect() on a UDP socket with destination port 0 (EADDRNOTAVAIL), so the
            // probe uses a non-zero port; it must resolve a route to loopback on every platform.
            IPAddress probe = NetworkHelpers.ProbeRouteSource(IPAddress.Loopback, null);
            bool probeWorks = IPAddress.IsLoopback(probe);

            // No peer address yet (a host advertises its address before anyone joins): selection
            // still has to come back with a real IPv4 whenever one exists, without throwing.
            bool hasNonLoopbackIPv4 = false;
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                foreach (UnicastIPAddressInformation unicast in adapter.GetIPProperties().UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily == AddressFamily.InterNetwork &&
                        !IPAddress.IsLoopback(unicast.Address))
                    {
                        hasNonLoopbackIPv4 = true;
                        break;
                    }
                }

                if (hasNonLoopbackIPv4)
                {
                    break;
                }
            }

            var noTarget = NetworkHelpers.GetLocalInterfaceForTarget("0", null);
            bool noTargetSelected = !hasNonLoopbackIPv4 || noTarget.address != null;

            // Candidate selection must handle any number of adapters and must not depend on
            // NetworkInterface enumeration order. The wired same-subnet candidate is the expected
            // winner; moving it between positions must not change the answer.
            NetworkHelpers.LanRouteCandidate[] candidates =
            [
                new(IPAddress.Parse("192.168.5.29"), true, false, false, false, false, false),
                new(IPAddress.Parse("169.254.10.20"), true, false, true, false, false, true),
                new(IPAddress.Parse("10.8.0.6"), true, true, false, false, true, false),
                new(IPAddress.Parse("192.168.5.28"), true, false, true, false, true, false),
                new(IPAddress.Parse("192.168.5.26"), true, false, true, true, true, false),
            ];
            IPAddress expectedCandidate = IPAddress.Parse("192.168.5.26");
            IPAddress forwardCandidate = NetworkHelpers.SelectBestLanRouteCandidate(candidates);
            Array.Reverse(candidates);
            IPAddress reverseCandidate = NetworkHelpers.SelectBestLanRouteCandidate(candidates);
            IPAddress singleCandidate = NetworkHelpers.SelectBestLanRouteCandidate(
                [new(IPAddress.Parse("192.168.5.26"), true, false, true, true, true, false)]);
            bool candidateSelection = forwardCandidate.Equals(expectedCandidate) &&
                                      reverseCandidate.Equals(expectedCandidate) &&
                                      singleCandidate.Equals(expectedCandidate);

            Console.WriteLine(
                $"network-route-selection: loopback={local.address?.Address}, fallback={fallback.address?.Address}, " +
                $"legacy={legacy.Item2?.Address}, probe={probe}, noTarget={noTarget.address?.Address}, " +
                $"candidate={forwardCandidate}/{reverseCandidate}/{singleCandidate}, " +
                $"checks={loopbackSelected}/{fallbackSelected}/{legacyWouldMissLoopback}/{probeWorks}/{noTargetSelected}/{candidateSelection}");
            return loopbackSelected && fallbackSelected && legacyWouldMissLoopback && probeWorks && noTargetSelected && candidateSelection ? 0 : 1;
        }
    }
}
