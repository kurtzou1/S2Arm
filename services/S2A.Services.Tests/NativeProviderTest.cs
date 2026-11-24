using System;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [UnmanagedCallersOnly] private static ulong ProviderStaleTick() => 7;
        private static ulong LanProgram;
        private static ushort LanPort;
        private static int LanHosting, LanStops;
        [UnmanagedCallersOnly] private static int ProviderLanStart(ulong id, ushort port) { LanProgram = id; LanPort = port; return 0; }
        [UnmanagedCallersOnly] private static void ProviderLanHosting(int on) => LanHosting = on;
        [UnmanagedCallersOnly] private static void ProviderLanStop() => LanStops++;

        private static void LanRegistrationTest(Action<bool, string> expect)
        {
            expect(Native.LanDiscovery == null, "旧按名导出不再自动登记 LAN");
            long red = Red.Total;
            expect(!Native.RegisterLanDiscovery(null) && Red.Total == red + 1 && Native.LanDiscovery == null, "空登记报红且不发布");
            var p = (LanDiscoveryV1*)NativeMemory.AllocZeroed((nuint)sizeof(LanDiscoveryV1));
            *p = new() { Abi = 2, Start = &ProviderLanStart, SetHosting = &ProviderLanHosting, Stop = &ProviderLanStop };
            red = Red.Total;
            expect(!Native.RegisterLanDiscovery(p) && Red.Total == red + 1 && Native.LanDiscovery == null, "错误 ABI 报红且不发布");
            p->Abi = 1; p->Stop = null;
            expect(!Native.RegisterLanDiscovery(p) && Native.LanDiscovery == null, "不完整函数表拒绝");
            p->Stop = &ProviderLanStop;
            expect(Native.RegisterLanDiscovery(p) && Native.RegisterLanDiscovery(p) && Native.LanDiscovery == p, "完整表发布且同指针幂等");
            LanDiscoveryV1 other = *p;
            expect(!Native.RegisterLanDiscovery(&other) && Native.LanDiscovery == p, "运行期替换拒绝且保留原表");
            expect(p->Start(0x0100123456789ABC, 41234) == 0 && LanProgram == 0x0100123456789ABC && LanPort == 41234, "ABI 传实际程序号与端口 / 0 成功");
            p->SetHosting(1); p->Stop(); p->Stop();
            expect(LanHosting == 1 && LanStops == 2 && p->Start(7, 54321) == 0 && LanProgram == 7 && LanPort == 54321, "hosting / 重复 stop / restart 调用契约");
        }

        // 补满采样（#2146）的批量体感源：平台装配登记，同 LAN 的规则（空报红、同指针幂等、不可替换）；不按名找导出
        private static void MotionBurstRegistrationTest(Action<bool, string> expect)
        {
            expect(Native.MotionBurst == 0, "批量体感源缺省未登记（ControllerFeedback 走单笔路径）");
            long red = Red.Total;
            expect(!Native.RegisterMotionBurst(0) && Red.Total == red + 1 && Native.MotionBurst == 0, "空登记报红且不发布");
            nint a = (nint)0x1000, b = (nint)0x2000;
            expect(Native.RegisterMotionBurst(a) && Native.RegisterMotionBurst(a) && Native.MotionBurst == a, "登记发布且同指针幂等");
            red = Red.Total;
            expect(!Native.RegisterMotionBurst(b) && Red.Total == red + 1 && Native.MotionBurst == a, "替换拒绝、报红且保留原登记");
        }

        private static int NativeLegacyProviderTest()
        {
            Native.UseLinked();
            Native.UseLinked();
            bool ok = Native.Ready && Native.GuestTick != null && Native.GuestTick() == 0xABC &&
                Native.DetMode != null && Native.DetMode() == 37 && Native.DetHostWrite != null &&
                Native.Far != null && Native.Far->Lo == 0x5000 && Native.Far->Dir == (nint)0x9876 &&
                Native.LanDiscovery == null;
            Console.WriteLine($"主程序符号域：tick、确定性、远端描述符；LAN 不按名绑定 {(ok ? "✓" : "✗")}");
            return ok ? 0 : 1;
        }

        // #1422：同一句柄先被无参兜底绑过、随后被显式 owner「升级」。兜底遇到不成对的组会悄悄清零，
        // 升级时必须把显式模式的成对检查补跑一遍并抛错，否则显式模式的严格性被绕过。
        // 独立进程：绑定是进程级 latch，前面的用例已经把状态占住了。
        private static int NativeProviderUpgradeTest(string halfPath)
        {
            nint half = NativeLibrary.Load(halfPath);
            int failures = 0;
            void Expect(bool condition, string name)
            {
                Console.WriteLine($"{name}: {(condition ? "✓" : "✗")}");
                if (!condition) failures++;
            }

            Native.UseLinked(half, false);   // 兜底：确定性半组被清零，不抛
            Expect(Native.Ready && Native.DetMode == null && Native.DetHostWrite == null,
                "兜底绑定半组时清零且不抛");

            bool rejected = false;
            try { Native.UseLinked(half, true); } catch (InvalidOperationException) { rejected = true; }
            Expect(rejected && Native.DetMode == null && Native.DetHostWrite == null,
                "同句柄兜底→显式升级：成对检查补跑并抛错");
            return failures == 0 ? 0 : 1;
        }

        // #1422：平台装配用 RegisterFallbackOwner 登记兜底 owner 之后，无参 UseLinked() 应该绑到它
        // （而不是主程序句柄），随后显式 owner 的「升级」仍要补跑成对检查。
        private static int NativeProviderRegisteredFallbackTest(string halfPath)
        {
            nint half = NativeLibrary.Load(halfPath);
            int failures = 0;
            void Expect(bool condition, string name)
            {
                Console.WriteLine($"{name}: {(condition ? "✓" : "✗")}");
                if (!condition) failures++;
            }

            Native.RegisterFallbackOwner(half, true);
            Native.UseLinked();   // 兜底：应绑 half（不是主程序句柄）
            Expect(Native.Ready && Native.DetMode == null && Native.DetHostWrite == null,
                "登记的兜底 owner 生效且半组清零");

            bool rejected = false;
            try { Native.UseLinked(half, true); } catch (InvalidOperationException) { rejected = true; }
            Expect(rejected, "登记兜底→显式 owner 升级：成对检查照旧补跑");
            return failures == 0 ? 0 : 1;
        }

        private static int NativeProviderTest(string halfPath, string fullPath, string emptyPath, bool emptyOnly)
        {
            nint half = NativeLibrary.Load(halfPath);
            nint full = NativeLibrary.Load(fullPath);
            nint empty = NativeLibrary.Load(emptyPath);
            Native.GuestTick = &ProviderStaleTick;
            FarDesc* fallback = Native.Far;
            int failures = 0;
            void Expect(bool condition, string name)
            {
                Console.WriteLine($"{name}: {(condition ? "✓" : "✗")}");
                if (!condition) failures++;
            }

            if (emptyOnly)
            {
                Native.UseLinked(empty);
                Expect(Native.Ready && Native.GuestTick == null && Native.DetMode == null && Native.DetHostWrite == null &&
                    Native.LanDiscovery == null && Native.Far == fallback && Native.Far != null && Native.Far->Dir == 0,
                    "缺失可选导出清除旧槽并保留零远端描述符");
                return failures == 0 ? 0 : 1;
            }

            bool emptyOwnerRejected = false;
            try { Native.UseLinked(0); } catch (ArgumentException) { emptyOwnerRejected = true; }
            Expect(emptyOwnerRejected && !Native.Ready, "空 provider 被拒且未发布");
            bool rejected = false;
            try { Native.UseLinked(half); } catch (InvalidOperationException) { rejected = true; }
            Expect(rejected && !Native.Ready && Native.GuestTick != null && Native.GuestTick() == 7 && Native.Far == fallback,
                "确定性半组拒绝且不发布任何槽");
            Native.UseLinked(full);
            Native.UseLinked(full);
            Expect(Native.Ready && Native.DetMode != null && Native.DetMode() == 37 && Native.DetHostWrite != null &&
                Native.GuestTick != null && Native.GuestTick() == 0xABC && Native.Far != null && Native.Far->Lo == 0x5000 && Native.Far->Dir == (nint)0x9876,
                "同一 provider 的 tick、确定性和远端描述符发布；重复绑定幂等");
            LanRegistrationTest(Expect);
            MotionBurstRegistrationTest(Expect);
            bool changedRejected = false;
            try { Native.UseLinked(empty); } catch (InvalidOperationException) { changedRejected = true; }
            Expect(changedRejected && Native.GuestTick != null && Native.GuestTick() == 0xABC && Native.Far != null &&
                Native.Far->Lo == 0x5000 && Native.LanDiscovery != null,
                "更换 provider 被拒且原有槽不变");
            return failures == 0 ? 0 : 1;
        }
    }
}
