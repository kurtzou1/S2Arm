using Ryujinx.Memory;
using System;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    // S2Arm：Joy-Con 2 光学鼠标传感器（Jcms）的状态缓冲（hid 3110 / 3111 = 交出 / 收回缓冲，3112 / 3113 = 开始 / 停止取样）。
    // 游戏 SDK 的 nn::hid::InitializeJcms(void* buffer, size_t size) 把一块缓冲做成传输内存交给 hid（形状同 320 EnableNpadImu），
    //   之后 GetJcmsState(s) 直接读这块缓冲、不再发命令；hid 不写，缓冲一直是 0，游戏就认为连着的手柄不是 Joy-Con 2
    //   （一款体育游戏要 Joy-Con 2 的项目会一直提示「请重新连接 Joy-Con 2」）。
    // 格式读自随游戏的 SDK 反汇编（公开资料只有命令名）：
    //   格子 idx = npadId × 2 + 类型（0 = 左只、1 = 右只），npadId 0–7，每格 0x2c8 字节 = Ryujinx RingLifo 版面：
    //   +0x00 未用、+0x08 缓冲格数 17、+0x10 最新一笔的槽号、+0x18 有效笔数（≤16）、+0x20 起 17 × 0x28（u64 顺序锁 + 0x20 字节状态）。
    //   顺序锁：读方见到奇数（正在写）就重读、读前读后不等也重读——写成奇数会让读方一直重读、游戏主线程卡死（实机 11-12：出图停在第 882 帧），
    //   所以写时先写奇数、写完状态再写偶数（= 取样序号 × 2）；读方另要求相邻两笔的取样序号差 1。
    //   状态：+0x00 u64 距上一笔的时间（纳秒；游戏把它累加成总时长）、+0x08 u64 取样序号、+0x10 s32 X 位移、+0x14 s32 Y 位移（每笔的增量，游戏逐笔累加）、
    //   +0x18 u32 属性：bit0 = 已连接（游戏靠它判断是不是 Joy-Con 2）、bit1 = 贴在桌面上（离开桌面时游戏累计离地时间）。
    // 宿主读的是手柄报告里的绝对坐标（16 位、会回绕），这里换成增量；没有鼠标读数（旧启动器）时照样写已连接、位移 0。
    public sealed class NpadJcms
    {
        public const int NpadCount = 8;
        public const int SlotSize = 0x2c8;
        public const int SlotCount = NpadCount * 2;
        public const ulong MinimumSize = SlotCount * SlotSize; // 0x2c80
        private const int MaxEntries = 17;
        private const int EntrySize = 0x28;
        private const int EntriesOffset = 0x20;
        public const uint AttributeConnected = 1;
        public const uint AttributeOnSurface = 2;
        private const ulong DefaultDeltaNs = 8_000_000;

        private readonly object _lock = new();
        private IVirtualMemoryManager _memory;
        private ulong _address;
        private readonly ulong[] _samplingNumber = new ulong[SlotCount];
        private readonly ulong[] _index = new ulong[SlotCount];
        private readonly ulong[] _count = new ulong[SlotCount];
        private readonly ulong[] _lastTimestampUs = new ulong[SlotCount];
        private readonly short[] _lastX = new short[SlotCount], _lastY = new short[SlotCount];
        private readonly bool[] _positionKnown = new bool[SlotCount];
        private readonly bool[] _connected = new bool[SlotCount];

        public bool Active { get { lock (_lock) return _memory != null; } }
        public bool Started { get; set; }

        public static int SlotIndex(int npadId, int type) => npadId * 2 + type;
        public static ulong SlotOffset(int slot) => (ulong)slot * SlotSize;

        public void Register(IVirtualMemoryManager memory, ulong address)
        {
            lock (_lock)
            {
                _memory = memory;
                _address = address;
                Array.Clear(_connected);
                Array.Clear(_samplingNumber);
                Array.Clear(_index);
                Array.Clear(_count);
                Array.Clear(_lastTimestampUs);
                Array.Clear(_positionKnown);
                Span<byte> zero = stackalloc byte[SlotSize];
                BitConverter.TryWriteBytes(zero[0x08..], (ulong)MaxEntries);
                for (int slot = 0; slot < SlotCount; slot++)
                {
                    memory.Write(address + SlotOffset(slot), zero);
                }
            }
        }

        public void Unregister()
        {
            lock (_lock)
            {
                _memory = null;
                _address = 0;
                Array.Clear(_connected);
                Started = false;
            }
        }

        // 一侧的读数：present = 这一侧连着 Joy-Con 2；known = 有鼠标读数（x / y 是手柄报告的绝对坐标），onSurface = 贴在桌面上
        public struct Side
        {
            public bool Present, Known, OnSurface;
            public short X, Y;
        }

        // 一笔读数（单侧，旧接口）：npadId 0–7、type 0 = 左只 / 1 = 右只。bothSides：手柄样式是一对时另一侧也写已连接、位移 0
        public void Push(int npadId, int type, bool known, short x, short y, bool onSurface, ulong timestampUs, bool bothSides = false)
        {
            Side mine = new() { Present = true, Known = known, X = x, Y = y, OnSurface = onSurface }, none = default;
            Push(npadId, type == 0 ? mine : none, type == 1 ? mine : none, timestampUs, bothSides);
        }

        // 左右两侧各一份：连着的那侧写它自己的读数；pair（手柄样式是一对）时没连的那侧也写已连接、位移 0（游戏左右两侧都查）。
        //   不再连着的格写成未连接，游戏不会把别的手柄也当成 Joy-Con 2
        public void Push(int npadId, in Side left, in Side right, ulong timestampUs, bool pair = false)
        {
            lock (_lock)
            {
                if (_memory == null || npadId < 0 || npadId >= NpadCount)
                {
                    return;
                }

                bool anySide = left.Present || right.Present;
                int l = left.Present || (pair && anySide) ? SlotIndex(npadId, 0) : -1;
                int r = right.Present || (pair && anySide) ? SlotIndex(npadId, 1) : -1;
                for (int i = 0; i < SlotCount; i++)
                {
                    if (_connected[i] && i != l && i != r)
                    {
                        WriteEntry(i, 0, 0, 0, 0);
                        _positionKnown[i] = false;
                        _lastTimestampUs[i] = 0;
                        _connected[i] = false;
                    }
                }

                if (l >= 0) WriteSide(l, left, timestampUs);
                if (r >= 0) WriteSide(r, right, timestampUs);
            }
        }

        private void WriteSide(int slot, in Side side, ulong timestampUs)
        {
            _connected[slot] = true;

            int dx = 0, dy = 0;
            if (side.Known)
            {
                if (_positionKnown[slot])
                {
                    dx = (short)(side.X - _lastX[slot]);
                    dy = (short)(side.Y - _lastY[slot]);
                }
                _lastX[slot] = side.X;
                _lastY[slot] = side.Y;
                _positionKnown[slot] = true;
            }
            else
            {
                _positionKnown[slot] = false;
            }

            ulong last = _lastTimestampUs[slot];
            ulong deltaNs = last != 0 && timestampUs > last ? (timestampUs - last) * 1000 : DefaultDeltaNs;
            _lastTimestampUs[slot] = timestampUs;

            uint attributes = AttributeConnected | (side.Known && side.OnSurface ? AttributeOnSurface : 0);
            WriteEntry(slot, deltaNs, dx, dy, attributes);
        }

        // 手柄断开：已连接的格写一笔未连接
        public void Disconnect()
        {
            lock (_lock)
            {
                if (_memory == null)
                {
                    return;
                }

                for (int i = 0; i < SlotCount; i++)
                {
                    if (_connected[i])
                    {
                        WriteEntry(i, 0, 0, 0, 0);
                        _positionKnown[i] = false;
                        _lastTimestampUs[i] = 0;
                        _connected[i] = false;
                    }
                }
            }
        }

        private void WriteEntry(int slot, ulong deltaNs, int dx, int dy, uint attributes)
        {
            ulong slotAddress = _address + SlotOffset(slot);
            ulong index = (_index[slot] + 1) % MaxEntries;
            ulong sampling = ++_samplingNumber[slot];

            Span<byte> entry = stackalloc byte[EntrySize];
            BitConverter.TryWriteBytes(entry[0x00..], sampling * 2);   // 顺序锁（偶数 = 写完）
            BitConverter.TryWriteBytes(entry[0x08..], deltaNs);        // 状态 +0x00
            BitConverter.TryWriteBytes(entry[0x10..], sampling);       // 状态 +0x08
            BitConverter.TryWriteBytes(entry[0x18..], dx);             // 状态 +0x10
            BitConverter.TryWriteBytes(entry[0x1c..], dy);             // 状态 +0x14
            BitConverter.TryWriteBytes(entry[0x20..], attributes);     // 状态 +0x18
            ulong entryAddress = slotAddress + EntriesOffset + index * EntrySize;
            _memory.Write(entryAddress, sampling * 2 - 1);   // 先标「正在写」（奇数）
            Thread.MemoryBarrier();
            _memory.Write(entryAddress + 8, entry[8..]);
            Thread.MemoryBarrier();
            _memory.Write(entryAddress, sampling * 2);

            // 先写这一笔、再推进槽号与笔数（读方先读槽号与笔数再读样本）
            Thread.MemoryBarrier();
            _index[slot] = index;
            _memory.Write(slotAddress + 0x10, index);
            if (_count[slot] < MaxEntries - 1)
            {
                _count[slot]++;
                _memory.Write(slotAddress + 0x18, _count[slot]);
            }
        }
    }
}
