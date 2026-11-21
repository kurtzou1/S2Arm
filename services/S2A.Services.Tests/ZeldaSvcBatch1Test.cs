// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2A.Services;
using System;
using System.IO;
using System.Text;

namespace S2A.Services.Tests
{
    // 0400486024DEC000（Switch 2，0400486024DEC000）开局服务缺口第一批：nifm 101、pctl 1101、lm 3。
    //   线上格式取自0400486024DEC000 sdk 客户端代理（CmifProxy 虚表 → 发送助手的头字、数据偏移、缓冲类型）；期望值按格式与真机语义手写，不跑被测实现：
    //   - nifm IGeneralService 101（GetCurrentNetworkProfile V2）：域消息、无入数据、C 缓冲 0x1b4；本机无联网权限 = 没有当前网络 → 同命令 5 回 NoInternetConnection（2110-0300），不报红
    //   - pctl IParentalControlService 1101（CheckAgcPermissionUnderMinimumAge）：入数据 Uid 0x10、无 pid、回 1 字节；没设家长控制 → 0（游戏表里 0 = "success"），不报红
    //   - lm ILogger 3（DevNotify）：入数据 0x28 字节头、In|AutoSelect 缓冲放正文；回 0、不报红
    public static unsafe partial class Program
    {
        static uint SmSession()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            return (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
        }

        static Reply DomainCall(uint session, Msg m, int obj)
        {
            m.DomainObject = obj;
            m.Write(_tlr);
            Svc(0x21, FakeNative.CookieOf(session));
            return Reply.ParseDomain(_tlr);
        }

        [SvcCase]
        private static void ZeldaNifm101Offline()
        {
            uint sm = SmSession();
            Reply gn = Call(sm, Msg.Cmif(1, Name8("nifm:u")));
            uint nif = gn.Move.Count == 1 ? gn.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(nif, cd).Data;
            Msg cgs = Msg.Cmif(5, Bytes(0UL)); cgs.SendPid = true;
            int gs = *(int*)DomainCall(nif, cgs, root).Data;

            long red0 = Red.Total;
            byte* prof = FakeNative.Alloc(0x1b4);
            Msg m = Msg.Cmif(101); m.C.Add(((ulong)prof, 0x1b4));
            uint rc = DomainCall(nif, m, gs).Result;
            uint noNet = (300u << 9) | 110;
            Check("nifm IGeneralService 101 GetCurrentNetworkProfile(V2)，离线：结果 NoInternetConnection、不报红", $"0x{noNet:X}、红 +0", $"0x{rc:X}、红 +{Red.Total - red0}");
        }

        [SvcCase]
        private static void NifmSubmitOfflineOnHoldThenError()
        {
            // #1823：离线时（没开联网）真机对提交的请求先回 OnHold、发请求事件，之后稳定回 Error。原先直接回 Error，
            //   会反复提交、等请求离开 OnHold 的游戏在 IPC 上空转。期望按真机时序手写：提交前 1（Error）、提交后第一次 2（OnHold）、
            //   之后 1；再提交一次又是先 2 后 1
            uint sm = SmSession();
            uint nif = Call(sm, Msg.Cmif(1, Name8("nifm:u"))).Move[0];
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(nif, cd).Data;
            Msg cgs = Msg.Cmif(5, Bytes(0UL)); cgs.SendPid = true;
            int gs = *(int*)DomainCall(nif, cgs, root).Data;
            int req = *(int*)DomainCall(nif, Msg.Cmif(4, Bytes(2u)), gs).Data;   // CreateRequest(version 2)
            int State() => *(int*)DomainCall(nif, Msg.Cmif(0), req).Data;        // GetRequestState
            int before = State();
            DomainCall(nif, Msg.Cmif(4), req);                                    // Submit
            int s1 = State(), s2 = State(), s3 = State();
            DomainCall(nif, Msg.Cmif(4), req);
            int t1 = State(), t2 = State();
            Check("nifm IRequest 离线：提交前 / 提交后三次 / 再提交后两次的状态", "1 / 2 1 1 / 2 1", $"{before} / {s1} {s2} {s3} / {t1} {t2}");
        }

        [SoloTest("--pctl-real-application", Booted = true)]
        private static void ZeldaPctl1101()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_pctl_test_{Environment.ProcessId}");
            try
            {
                // Application.Register also registers GPU memory and LibHac state.
                // Run in a fresh host, independently of optional game registration in Run().
                WriteApplicationFixture(root);
                Application.Register(Host.Device, root);
                bool registered = Host.Device.Processes.TryGetProcess(Native.ProcessId(), out var process);
                Check("pctl 前提：真实应用登记的 PID / ProgramId", $"0x51 / 0x{HomebrewFixtureProgramId:X}",
                    registered ? $"0x{process.ProcessId:X} / 0x{process.ProgramId:X}" : "进程元数据未登记");

                uint sm = SmSession();
                uint pf = Call(sm, Msg.Cmif(1, Name8("pctl"))).Move[0];
                Msg cs = Msg.Cmif(0, Bytes(0UL)); cs.SendPid = true;
                Reply r = Call(pf, cs);
                uint svc = r.Move.Count == 1 ? r.Move[0] : 0;

                long red0 = Red.Total;
                Reply a = Call(svc, Msg.Cmif(1101, Bytes(0x1122334455667788UL, 0x99AABBCCDDEEFF00UL)));
                byte status = a.Result == 0 ? a.Data[0] : (byte)0xFF;
                Check("pctl 1101 CheckAgcPermissionUnderMinimumAge，没设家长控制：结果 0、状态 0、不报红", "0x0、0、红 +0", $"0x{a.Result:X}、{status}、红 +{Red.Total - red0}");
                FakeNative.HandleClose(svc);
                FakeNative.HandleClose(pf);
                FakeNative.HandleClose(sm);
            }
            finally
            {
                Directory.Delete(root, true);
            }
        }

        [SvcCase]
        private static void ZeldaLm3DevNotify()
        {
            bool up = WaitFor(() => Array.IndexOf(HorizonHost.Services, "lm") >= 0, 10_000);
            uint sm = SmSession();
            uint lm = up ? Call(sm, Msg.Cmif(1, Name8("lm"))).Move[0] : 0;
            Msg ol = Msg.Cmif(0, Bytes(0UL)); ol.SendPid = true;
            Reply o = Call(lm, ol);
            uint logger = o.Move.Count == 1 ? o.Move[0] : 0;

            long red0 = Red.Total;
            byte[] text = Encoding.UTF8.GetBytes("zelda devnotify\0");
            byte* tp = FakeNative.Alloc(0x40);
            text.CopyTo(new Span<byte>(tp, text.Length));
            Msg m = Msg.Cmif(3, new byte[0x28]); m.A.Add(((ulong)tp, (ulong)text.Length)); m.X.Add((0, 0));   // In|AutoSelect：Horizon 服务端要 A 与 X 两个描述符都在、取非空的那个
            uint rc = Call(logger, m).Result;
            Check("lm ILogger 3 DevNotify（0x28 字节头 + 正文缓冲）：结果 0、不报红", "0x0、红 +0", $"0x{rc:X}、红 +{Red.Total - red0}");
        }
    }
}
