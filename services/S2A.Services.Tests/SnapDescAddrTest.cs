using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // 即时存档请求日志解析描述符（SnapLog.ParseDescs）也要补回 IPC 描述符丢掉的地址高位，同服务端 IpcBuffDesc / IpcPtrBuffDesc：
        //   老 SDK 只往描述符里写地址 32–35 位，36 位款窗口放在 2^36 以上那一块时，游戏地址的 36 位以上全丢（native s2a_ipc_addr39 按窗口所在块补回）。
        //   原先日志按残缺地址拷缓冲内容：一款 36 位老版本游戏起局打开显卡驱动就段错误（拷的是 16 字节的驱动路径）。
        //   夹具：手拼一条 HIPC 消息，X 描述符地址 0x7282400010、A 描述符地址 0x7282550a73，都按老 SDK 只写 32–35 位（36–38 位为 0）；
        //   补回挂一个替身：不是 0 且小于 2^36 就或上 0x7000000000（36 位款窗口在 0x7000000000 那一块）。期望按输入手算：
        //   ① X 地址 0x7282400010、长度 0x40；② A 地址 0x7282550a73、长度 0x10；③ 没挂补回（单测 / 宿主没导出）时原样：0x282400010 / 0x282550a73
        [UnmanagedCallersOnly] private static ulong FakeAddr36(ulong a) => a != 0 && a < (1UL << 36) ? a | 0x7000000000UL : a;

        [SoloTest("--snap-descs-addr")]
        private static int SnapDescAddr()
        {
            var rows = new List<(string N, string E, string A)>();
            byte[] msg = new byte[64];
            const ulong X = 0x7282400010UL, A = 0x7282550a73UL;
            BitConverter.TryWriteBytes(msg.AsSpan(0), (1u << 16) | (1u << 20));   // 1 个 X、1 个 A
            BitConverter.TryWriteBytes(msg.AsSpan(4), 0u);
            uint xa = (0x40u << 16) | (uint)(((X >> 32) & 0xF) << 12);            // X：16–31 长度、12–15 地址 32–35 位，6–8（地址 36–38 位）老 SDK 不写
            BitConverter.TryWriteBytes(msg.AsSpan(8), xa); BitConverter.TryWriteBytes(msg.AsSpan(12), (uint)(X & 0xFFFFFFFF));
            BitConverter.TryWriteBytes(msg.AsSpan(16), 0x10u);                      // A：长度低 32 位
            BitConverter.TryWriteBytes(msg.AsSpan(20), (uint)(A & 0xFFFFFFFF));                   //    地址低 32 位
            BitConverter.TryWriteBytes(msg.AsSpan(24), (uint)(((A >> 32) & 0xF) << 28));   // 28–31 地址 32–35 位；2–4（36–38 位）老 SDK 不写
            var saved = Ryujinx.HLE.S2AHooks.IpcAddr39;
            try
            {
                List<S2A.Services.SnapLog.Desc> Parse() { fixed (byte* m = msg) return S2A.Services.SnapLog.ParseDescs(m, msg.Length); }
                Ryujinx.HLE.S2AHooks.IpcAddr39 = &FakeAddr36;
                var d = Parse();
                rows.Add(("① X 描述符补回高位", $"0x{X:x} / 0x40", d.Count > 0 ? $"0x{d[0].Addr:x} / 0x{d[0].Size:x}" : "没解出"));
                rows.Add(("② A 描述符补回高位", $"0x{A:x} / 0x10", d.Count > 1 ? $"0x{d[1].Addr:x} / 0x{d[1].Size:x}" : "没解出"));
                Ryujinx.HLE.S2AHooks.IpcAddr39 = null;
                d = Parse();
                rows.Add(("③ 没挂补回时原样", "0x282400010 / 0x282550a73", d.Count > 1 ? $"0x{d[0].Addr:x} / 0x{d[1].Addr:x}" : "没解出"));
            }
            finally { Ryujinx.HLE.S2AHooks.IpcAddr39 = saved; }
            int failures = 0;
            foreach ((string n, string e, string a) in rows) { bool ok = e == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{e} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
