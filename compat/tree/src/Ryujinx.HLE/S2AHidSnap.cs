// S2A: 本文件为 S2A 新增（非 Ryujinx 原版）。
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Common;
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE
{
    /// <summary>
    /// 即时存档：HID 共享内存里触屏 / 鼠标 / 键盘 / 手势四个环存取。恢复时 HID 共享内存不按快照恢复内容，由服务重放新建一块，
    /// 环的采样号从 0 重新数；游戏内存里记着的「上次读到的采样号」是快照那一刻的大数，按「采样号比上次大才是新输入」判的游戏
    /// 把恢复后的每次触摸都当旧数据丢掉（#2199 陷阵之志：回到这一刻后触屏必失效，摇杆按当前状态读、不看采样号，所以正常）。
    /// 这四个环只是采样历史、不含设置，原样放回后各设备按环里最后一条的采样号 + 1 接着写（TouchDevice / MouseDevice / KeyboardDevice，
    /// 手势见 GestureDevice 的起始采样号）。手柄那几块带接法 / 样式等设置，由请求重放按当前手柄建，不在这里动。恢复在请求重放之后
    /// </summary>
    public static class S2AHidSnap
    {
        private const uint Magic = 0x31444948u;   // "HID1"

        public static void Save(Switch device, BinaryWriter w) => Save(ref device.Hid.SharedMemory, w);

        /// <returns>放回的环个数；格式不对回 -1（共享内存不动）</returns>
        public static int Restore(Switch device, BinaryReader r) => Restore(ref device.Hid.SharedMemory, r);

        internal static void Save(ref SharedMemory m, BinaryWriter w)
        {
            w.Write(Magic);
            Put(w, ref m.TouchScreen); Put(w, ref m.Mouse); Put(w, ref m.Keyboard); Put(w, ref m.Gesture);
        }

        internal static int Restore(ref SharedMemory m, BinaryReader r)
        {
            if (r.ReadUInt32() != Magic) return -1;
            byte[] t = Take(r, ref m.TouchScreen), mo = Take(r, ref m.Mouse), k = Take(r, ref m.Keyboard), g = Take(r, ref m.Gesture);
            if (t == null || mo == null || k == null || g == null) return -1;   // 先全读完、长度都对上再写：格式不对时一块都不改
            Set(t, ref m.TouchScreen); Set(mo, ref m.Mouse); Set(k, ref m.Keyboard); Set(g, ref m.Gesture);
            return 4;
        }

        private static Span<byte> Bytes<T>(ref RingLifo<T> ring) where T : unmanaged, ISampledDataStruct => MemoryMarshal.AsBytes(MemoryMarshal.CreateSpan(ref ring, 1));

        private static void Put<T>(BinaryWriter w, ref RingLifo<T> ring) where T : unmanaged, ISampledDataStruct
        {
            Span<byte> b = Bytes(ref ring); w.Write(b.Length); w.Write(b);
        }

        private static byte[] Take<T>(BinaryReader r, ref RingLifo<T> ring) where T : unmanaged, ISampledDataStruct
        {
            int n = r.ReadInt32(); if (n != Bytes(ref ring).Length) return null;
            byte[] b = r.ReadBytes(n); return b.Length == n ? b : null;
        }

        private static void Set<T>(byte[] b, ref RingLifo<T> ring) where T : unmanaged, ISampledDataStruct => b.CopyTo(Bytes(ref ring));
    }
}
