using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // Switch 2 硬件音频编解码会话 hwacod（hwopus #100）：照游戏自带 sdk 里 nn::codec::hwacod::shim 的客户端顺序走一遍——
    //   转域 → #100 取客户端会话 → #3 / #2 问 ADSP 管理器 / 实例工作区 → 按 WorkBufferSizeCalculator 的公式排工作区（IO 缓冲 + 完成环）、
    //   填 0x60 字节共享内存参数 → #11 开管理会话（pid、传输内存 + 进程句柄）→ 管理会话 #0 建单流 / 多流实例 →
    //   每批几条 16 字节任务走 #10（AutoSelect 缓冲）→ 收完成事件、按完成环（服务端写序号 +4、客户端读序号 +0x44、条目 0x40 字节）读结果。
    //   期望不跑被测实现就能算出：工作区布局按反汇编出的公式算；PCM 与直调 libopus 的参考解码逐样本比（reset 处参考侧重建）；
    //   出错码按 sdk opus::hw 的转换（模块 111、描述 33–43 → OpusResult 1–11；坏包 = 4，同旧 hwopus 0x226F → 4）。
    public static unsafe partial class Program
    {
        private const int HwacodIo = 4;          // IO 缓冲块数（完成环 5 条，100 条任务绕环 20 圈）
        private const int HwacodBatch = 3;       // 一次 #10 递的任务数

        private static uint Align(uint v, uint a) => (v + a - 1) & ~(a - 1);

        // 实例参数 0x120 字节：variant 下标（1 = Opus、2 = 多流）、采样率、声道、帧长（纳秒）、流数、立体声流数、映射
        private static byte* HwacodParam(ulong kind, int rate, int ch, long frameNs, int streams, int coupled, byte[] map)
        {
            byte* p = FakeNative.Alloc(0x120);
            new Span<byte>(p, 0x120).Clear();
            *(ulong*)p = kind; *(int*)(p + 8) = rate; *(int*)(p + 12) = ch; *(long*)(p + 16) = frameNs;
            *(int*)(p + 24) = streams; *(int*)(p + 28) = coupled;
            map?.CopyTo(new Span<byte>(p + 32, map.Length));
            return p;
        }

        [SoloTest("--hwacod", Booted = true)]
        static void Hwacod()
        {
            System.Text.Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            WaitFor(() => Array.IndexOf(HorizonHost.Services, "hwopus") >= 0, 10_000);
            TestHwacod(sm);
        }

        private static void TestHwacod(uint sm)
        {
            Reply ghw = Call(sm, Msg.Cmif(1, Name8("hwopus")));
            uint hwo = ghw.Move.Count == 1 ? ghw.Move[0] : 0;

            if (hwo == 0)
            {
                Check("hwacod：取 hwopus 会话", "move 1 个会话句柄", $"move {ghw.Move.Count} 个");
                return;
            }

            Reply D(Msg m, int obj)
            {
                m.DomainObject = obj; m.Write(_tlr); Svc(0x21, FakeNative.CookieOf(hwo));
                try { return Reply.ParseDomain(_tlr); } catch (InvalidOperationException) { return Reply.Parse(_tlr); }
            }

            // 同 sdk：客户端会话走域代理（CmifDomainProxyKind），连上先转域
            Msg cv = Msg.Cmif(0); cv.Type = 5;
            int root = *(int*)Call(hwo, cv).Data;
            Reply gc = D(Msg.Cmif(100), root);
            // 出对象号在数据区（同 sdk 代理按数据区取号；Horizon 框架不改写域出头的计数，不看它）
            int client = gc.Result == 0 ? *(int*)gc.Data : 0;
            Check("hwacod：hwopus #100 取客户端会话", "结果 0x0、出对象号 ≠ 0、≠ 根对象", $"结果 0x{gc.Result:X}、出对象号{(client != 0 && client != root ? " ≠ 0、≠ 根对象" : $" {client}")}");

            if (client == 0)
            {
                return;
            }

            // 管理器参数取两个实例里最大的一种（同 opus::hw::InitializeHardwareOpusMultiStreamDecoderManager：5.1、48 kHz、20 ms）
            const int Rate = 48000;
            const long FrameNs = 20_000_000;
            byte[] m51 = { 0, 4, 1, 2, 3, 5 };
            byte* mgrParam = HwacodParam(2, Rate, 6, FrameNs, 4, 2, m51);

            Reply r3 = D(Msg.Cmif(3, Bytes((uint)HwacodIo, 1u)), client);
            Msg m2 = Msg.Cmif(2, Bytes(1u)); m2.X.Add(((ulong)mgrParam, 0x120));
            Reply r2 = D(m2, client);
            uint adspSize = r3.Result == 0 ? *(uint*)r3.Data : 0, instSize = r2.Result == 0 ? *(uint*)r2.Data : 0;
            Check("hwacod：客户端会话 #3 / #2 回 ADSP 管理器 / 实例工作区大小", "都成功、都 > 0", r3.Result == 0 && r2.Result == 0 && adspSize > 0 && instSize > 0 ? "都成功、都 > 0" : $"#3 结果 0x{r3.Result:X}、{adspSize}；#2 结果 0x{r2.Result:X}、{instSize}");

            // WorkBufferSizeCalculator：每帧样本 = ⌈帧长 × 采样率 / 1e9⌉；Opus 输入 0x600、输出 = 样本 × 声道 × 2（64 对齐）；
            //   完成环 = 4K 对齐(0x80 头 + (IO 块数 + 1) × 0x40)，排在 4K 对齐的 IO 区之后
            const int Instances = 2;
            uint samples = (uint)((FrameNs * Rate + 999_999_999) / 1_000_000_000);
            uint inSize = 0x600, outSize = Align(samples * 6 * 2, 64), stride = inSize + outSize;
            uint ioTotal = HwacodIo * stride, ringOff = Align(ioTotal, 0x1000), ringSize = Align(0xC0 + HwacodIo * 0x40, 0x1000);
            uint workSize = ringOff + ringSize;
            uint adspAligned = Align(adspSize, 64), instAligned = Align(instSize, 64);
            uint adspRingOff = Align(adspAligned + Instances * instAligned, 0x1000), tmemSize = adspRingOff + ringSize;

            byte[] shared = new byte[0x60];
            uint[] sw =
            {
                1, adspAligned, 0, Instances * instAligned, adspAligned, ringSize, adspRingOff, tmemSize,
                ioTotal, 0, ringSize, ringOff, workSize, instAligned, Instances, inSize, outSize, HwacodIo,
            };
            Buffer.BlockCopy(sw, 0, shared, 0, sw.Length * 4);

            byte* work = FakeNative.Alloc((int)workSize);
            new Span<byte>(work, (int)workSize).Clear();
            byte* ring = work + ringOff;
            *(uint*)(ring + 0x40) = 1;   // 同 HardwareAudioCodecManager::Initialize：客户端那半行置 1、读序号 0
            byte* tmemBuf = FakeNative.Alloc((int)tmemSize);
            uint tm = FakeNative.TmemCreate((ulong)tmemBuf, tmemSize, 3);

            // #11：0x60 共享参数、u32 1、传输内存大小、工作区地址 / 大小、属性位（opus::hw 管理器传 7）、u64 0；pid；复制句柄：传输内存、本进程
            Msg om = Msg.Cmif(11, Bytes(shared, 1u, 0u, (ulong)tmemSize, (ulong)work, (ulong)workSize, 7UL, 0UL));
            om.SendPid = true; om.Copy.Add(tm); om.Copy.Add(0xFFFF8001);
            Reply orr = D(om, client);
            int mgr = orr.Result == 0 ? *(int*)(orr.Data + 4) : 0;
            ushort token = orr.Result == 0 ? (ushort)*(uint*)orr.Data : (ushort)0;
            uint ev = orr.Copy.Count == 1 ? orr.Copy[0] : 0;
            Check("hwacod：#11 开管理会话", "结果 0x0、出对象号 ≠ 0、复制 1 个事件句柄", $"结果 0x{orr.Result:X}、出对象号{(mgr != 0 ? " ≠ 0" : " 0")}、复制 {orr.Copy.Count} 个{(FakeNative.KindOf(ev) == ObjKind.EventR ? "事件" : "非事件")}句柄");

            if (mgr == 0 || ev == 0)
            {
                return;
            }

            ulong evId = FakeNative.CookieOf(ev);

            // 两个实例：#0 单流 48 kHz 双声道、#1 多流 5.1（参考编码器同 hwopus 单测的两条用例）
            OpusCase[] cases =
            {
                new("hwacod 单流 48 kHz 双声道 CELT 20 ms", Rate, 2, 0, 0, null, 2, null, AppAudio, 96000, OpusAuto, 8, false, 8),
                new("hwacod 多流 48 kHz 5.1 CELT 20 ms", Rate, 6, 4, 2, m51, 6, m51, AppAudio, 256000, OpusAuto, 8, false, 9),
            };
            Reply c0 = D(MsgWithX(Msg.Cmif(0, Bytes(0u)), HwacodParam(1, Rate, 2, FrameNs, 0, 0, null)), mgr);
            Reply c1 = D(MsgWithX(Msg.Cmif(0, Bytes(1u)), HwacodParam(2, Rate, 6, FrameNs, 4, 2, m51)), mgr);
            Check("hwacod：管理会话 #0 建单流 / 多流实例", "0x0 / 0x0", $"0x{c0.Result:X} / 0x{c1.Result:X}");

            List<byte[]>[] packets = { OpusEncode(cases[0]), OpusEncode(cases[1]) };
            (short[] Pcm, int[] Samples)[] want = { OpusReference(cases[0], packets[0], true), OpusReference(cases[1], packets[1], true) };

            // 任务序列：两路交替，第 OpusResetAt 包带复位；每批 HwacodBatch 条、批末一条置「最后」
            List<(int Inst, int K)> order = new();
            for (int k = 0; k < OpusPackets; k++) { order.Add((0, k)); order.Add((1, k)); }

            HardwareTask* tasks = (HardwareTask*)FakeNative.Alloc(HwacodBatch * 16);
            int frame = (int)samples, entries = 0, metaOk = 0, sizeOk = 0, resultOk = 0, signals = 0, executeOk = 0;
            long pcmBad = 0, pcmTotal = 0;
            ushort seq = 0;
            uint readIdx = 0;

            for (int b = 0; b < order.Count; b += HwacodBatch)
            {
                int n = Math.Min(HwacodBatch, order.Count - b);
                var batch = new (int Inst, int K, int Io, ushort Seq)[n];

                for (int i = 0; i < n; i++)
                {
                    (int inst, int k) = order[b + i];
                    byte[] p = packets[inst][k];
                    byte* io = work + i * stride;
                    System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(new Span<byte>(io, 4), p.Length);
                    *(uint*)(io + 4) = 0;
                    p.CopyTo(new Span<byte>(io + 8, p.Length));
                    new Span<byte>(io + inSize, (int)outSize).Fill(0xA5);
                    tasks[i] = new HardwareTask { Token = token, Instance = (ushort)inst, IoBuffer = (ushort)i, Sequence = seq, InputSize = (uint)(8 + p.Length), Reset = (byte)(k == OpusResetAt ? 1 : 0), Last = (byte)(i == n - 1 ? 1 : 0) };
                    batch[i] = (inst, k, i, seq++);
                }

                FakeNative.Events[evId] = false;
                Msg ex = Msg.Cmif(10); ex.X.Add((0, 0)); ex.A.Add(((ulong)tasks, (ulong)(n * 16)));
                executeOk += D(ex, mgr).Result == 0 ? 1 : 0;
                signals += FakeNative.Events.TryGetValue(evId, out bool sig) && sig ? 1 : 0;

                // UpdateProcessResult：读到服务端写序号为止，读序号推进写回 +0x44
                for (int i = 0; ; i++)
                {
                    uint write = *(uint*)(ring + 4);
                    if (readIdx == write || i >= n) break;
                    byte* e = ring + 0x80 + readIdx * 0x40;
                    (int inst, int k, int ioIdx, ushort sq) = batch[i];
                    int ch = cases[inst].Ch;
                    entries++;
                    metaOk += *(ushort*)(e + 2) == inst && *(ushort*)(e + 4) == ioIdx && *(ushort*)(e + 6) == sq ? 1 : 0;
                    resultOk += *(uint*)(e + 0x14) == 0 ? 1 : 0;
                    sizeOk += *(uint*)(e + 0x10) == frame * ch * 2 && want[inst].Samples[k] == frame ? 1 : 0;
                    short* got = (short*)(work + ioIdx * stride + inSize);
                    for (int s = 0; s < frame * ch; s++) { pcmTotal++; pcmBad += got[s] != want[inst].Pcm[k * frame * ch + s] ? 1 : 0; }
                    readIdx = readIdx + 1 == HwacodIo + 1 ? 0 : readIdx + 1;
                    *(uint*)(ring + 0x44) = readIdx;
                }
            }

            int batches = (order.Count + HwacodBatch - 1) / HwacodBatch;
            Check("hwacod：#10 每批成功、完成事件每批都亮", $"{batches} / {batches} 批", $"{executeOk} / {signals} 批");
            Check("hwacod：完成环条目数与实例 / IO 块 / 序号对位", $"{order.Count} 条、对位 {order.Count}", $"{entries} 条、对位 {metaOk}");
            Check("hwacod：完成条目结果 0、输出字节 = 每帧样本 × 声道 × 2", $"{order.Count} / {order.Count}", $"{resultOk} / {sizeOk}");
            Check("hwacod：PCM 与直调 libopus 逐样本相同（含第 25 包复位）", $"{(long)OpusPackets * frame * 8} 样本、不同 0", $"{pcmTotal} 样本、不同 {pcmBad}");

            // 出错：坏包（TOC 0xFF 码 3、帧数 63 超 120 ms，libopus 判坏包）→ OpusResult 4；包头长度超出输入 → 6
            byte* io0 = work;
            byte[] bad = { 0xFF, 0xFF, 0x01, 0x02 };
            System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(new Span<byte>(io0, 4), bad.Length);
            bad.CopyTo(new Span<byte>(io0 + 8, bad.Length));
            byte* io1 = work + stride;
            System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(new Span<byte>(io1, 4), 100);
            tasks[0] = new HardwareTask { Token = token, Instance = 0, IoBuffer = 0, Sequence = seq++, InputSize = (uint)(8 + bad.Length) };
            tasks[1] = new HardwareTask { Token = token, Instance = 0, IoBuffer = 1, Sequence = seq++, InputSize = 8 + 10, Last = 1 };
            Msg exe = Msg.Cmif(10); exe.X.Add((0, 0)); exe.A.Add(((ulong)tasks, 32));
            D(exe, mgr);
            uint[] codes = new uint[2], sizes = new uint[2];
            for (int i = 0; i < 2 && readIdx != *(uint*)(ring + 4); i++)
            {
                byte* e = ring + 0x80 + readIdx * 0x40;
                codes[i] = *(uint*)(e + 0x14); sizes[i] = *(uint*)(e + 0x10);
                readIdx = readIdx + 1 == HwacodIo + 1 ? 0 : readIdx + 1;
            }
            uint Code(int opusResult) => 111u | (uint)(33 + opusResult - 1) << 9;
            Check("hwacod：坏包 / 包头长度超出输入的完成结果与输出字节", $"0x{Code(4):X} 0 / 0x{Code(6):X} 0", $"0x{codes[0]:X} {sizes[0]} / 0x{codes[1]:X} {sizes[1]}");

            // 销毁实例、关管理会话（域关对象）
            Reply d0 = D(Msg.Cmif(1, Bytes(0u)), mgr), d1 = D(Msg.Cmif(1, Bytes(1u)), mgr);
            Check("hwacod：管理会话 #1 销毁两个实例", "0x0 / 0x0", $"0x{d0.Result:X} / 0x{d1.Result:X}");
        }

        private static Msg MsgWithX(Msg m, byte* x)
        {
            m.X.Add(((ulong)x, 0x120));
            return m;
        }

        [StructLayout(LayoutKind.Sequential, Size = 16)]
        private struct HardwareTask
        {
            public ushort Token, Instance, IoBuffer, Sequence;
            public uint InputSize;
            public byte Reset, Last;
            public ushort Padding;
        }
    }
}
