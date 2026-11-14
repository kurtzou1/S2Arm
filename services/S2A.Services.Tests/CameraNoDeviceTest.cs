// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Kernel.Process;
using System;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace S2A.Services.Tests
{
    // 诊断 #0148a6：Switch 2 摄像头会话（nn::camera::sdk::CreateCameraContext 给游戏的句柄）按「接口有、没插摄像头的主机」答。
    // 期望值照 nxnative dm/host/hle_sf.c camera_answer（MIT）手写，不跑被测实现推：命令 3 / 4 成功；21 成功并复制 1 个事件句柄；
    //   29（QueryDeviceConnection）与其它命令回 0x7c4（没检测到摄像头设备）；都不报红
    static unsafe class CameraNoDeviceTest
    {
        static int _events;
        static ulong EvCreate(uint* r, uint* w) { _events++; if (r != null) *r = 0x8100u + (uint)_events; return 0xE000u + (ulong)_events; }
        static uint EvDup(ulong ev) => 0x9000;

        static void Set(object o, string field, object v) =>
            o.GetType().GetField($"<{field}>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(o, v);

        [SoloTest("--camera-no-device")]
        public static int Run()
        {
            var d = (Dispatcher)RuntimeHelpers.GetUninitializedObject(typeof(Dispatcher));
            var device = (Switch)RuntimeHelpers.GetUninitializedObject(typeof(Switch));
            Set(device, "Configuration", RuntimeHelpers.GetUninitializedObject(typeof(HleConfiguration)));
            Set(d, "Device", device);
            var server = new KProcess(null);
            server.HandleTable.Initialize(32);
            Set(d, "ServerProcess", server);
            var target = new CameraNoDevice();
            var create = Native.EventCreate; var dup = Native.EventDupRead;
            int cases = 0, failures = 0;
            long red0 = Red.Total;
            try
            {
                Native.EventCreate = &EvCreate; Native.EventDupRead = &EvDup;
                void Case(uint cmd, uint expected, int copies)
                {
                    cases++;
                    byte* buffer = stackalloc byte[0x100];
                    Msg.Cmif(cmd).Write(buffer);
                    uint kr = target.Process(d, buffer, 0x100);
                    Reply r = Reply.Parse(buffer);
                    bool ok = kr == 0 && r.Result == expected && r.Copy.Count == copies && r.Move.Count == 0;
                    if (!ok) failures++;
                    Console.WriteLine($"{(ok ? "✓" : "✗")} 摄像头会话 命令 {cmd}：期望 结果 0x{expected:x}、复制句柄 {copies} → 内核 0x{kr:x}、结果 0x{r.Result:x}、复制 {r.Copy.Count}、移交 {r.Move.Count}");
                }
                Case(3, 0, 0);       // 打开设备
                Case(21, 0, 1);      // 摄像头事件：永不触发的事件读端
                Case(29, 0x7c4, 0);  // QueryDeviceConnection：没插
                Case(7, 0x7c4, 0);   // 其它命令
                Case(21, 0, 1);      // 再取一次事件：同一个事件再发读端
                Case(4, 0, 0);       // 关闭
            }
            finally { Native.EventCreate = create; Native.EventDupRead = dup; }
            cases++;
            bool once = _events == 1, quiet = Red.Total == red0;
            if (!(once && quiet)) failures++;
            Console.WriteLine($"{(once && quiet ? "✓" : "✗")} 摄像头会话：原生事件只建 1 个（实 {_events}）、报红 +0（实 +{Red.Total - red0}）");
            Console.WriteLine($"{(failures == 0 ? "✓" : "✗")} camera-no-device：{cases - failures}/{cases} 项符合");
            return failures == 0 ? 0 : 1;
        }
    }
}
