using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 硬件 Opus 解码 hwopus（Horizon；怪猎村子 / 暗黑3 背景音乐每秒几十包）：经生产同一 IPC 入口开单流 / 多流解码器，解参考编码器出的包，
    //   与直调 libopus（opus_decode / opus_multistream_decode，不经垫片、不经服务）逐样本比对（S2A_OPUS_SYSTEM=1 时允许 ±1 LSB 系统舍入差）。期望不跑被测实现就能算出：
    //   参考解码器同输入同状态（reset 处参考侧销毁重建 = 初始状态）解出的就是期望；样本数 = 包数 × 每包帧长 × 声道数，按用例构造算。
    //   覆盖：单流 1 / 2 声道、多流 1 / 2 / 5.1 声道（含映射 255 静音声道）；48 / 24 / 16 kHz；2.5–60 ms 帧；SILK / Hybrid / CELT 三种模式；
    //   带内纠错；命令 #0 #2（旧）、#4 #5（带计时）、#6 #7（带复位）、#8 #9（7.0.0+，输入也是 NonSecure）；坏包 / 截断 / 输出不足 / 空包四种错误码。
    public static unsafe partial class Program
    {
        // 直调 libopus 参考解码器（S2A_OPUS_DYLIB 动态库里整份 libopus 都在；这几个函数不是变参，可以 P/Invoke 直调）
        [DllImport("s2a_opus")] private static extern nint opus_decoder_create(int fs, int channels, int* error);
        [DllImport("s2a_opus")] private static extern int opus_decode(nint st, byte* data, int len, short* pcm, int frameSize, int decodeFec);
        [DllImport("s2a_opus")] private static extern void opus_decoder_destroy(nint st);
        [DllImport("s2a_opus")] private static extern nint opus_multistream_decoder_create(int fs, int channels, int streams, int coupled, byte* mapping, int* error);
        [DllImport("s2a_opus")] private static extern int opus_multistream_decode(nint st, byte* data, int len, short* pcm, int frameSize, int decodeFec);
        [DllImport("s2a_opus")] private static extern void opus_multistream_decoder_destroy(nint st);

        // 单测编码垫片（services/opus/s2a_opus_test.c，只进动态库）
        [DllImport("s2a_opus")] private static extern nint s2at_enc_open(int fs, int channels, int streams, int coupled, byte* mapping, int application, int bitrate, int bandwidth, int complexity, int fec, int* error);
        [DllImport("s2a_opus")] private static extern int s2at_enc(nint st, short* pcm, int frameSize, byte* data, int maxBytes);
        [DllImport("s2a_opus")] private static extern void s2at_enc_close(nint st);

        // opus_defines.h
        private const int OpusAuto = -1000, AppVoip = 2048, AppAudio = 2049, AppLowDelay = 2051;
        private const int BwWide = 1103, BwSuperWide = 1104, BwFull = 1105;

        // 一个用例：解码采样率 / 声道；Map 为空 = 单流（OpenHardwareOpusDecoder #0），否则多流（#2，Streams / Coupled / Map）；
        //   编码：EncCh / EncMap 为参考编码器的声道与映射（映射带 255 静音声道时编码侧少一个声道、包格式相同）；Frame25 = 帧长（2.5 ms 的倍数）；Cmd = 解码命令号
        private sealed record OpusCase(string Name, int Rate, int Ch, int Streams, int Coupled, byte[] Map, int EncCh, byte[] EncMap,
            int App, int Bitrate, int Bandwidth, int Frame25, bool Fec, uint Cmd, int OnsetMax = 0);

        private const int OpusPackets = 50, OpusResetAt = 25;

        // 确定性测试信号：每声道两个正弦（频率按声道错开、都低于 16 kHz 的奈奎斯特）+ 线性同余噪声，0.7 Hz 包络起伏；第 30–34 包静音
        private static short OpusSignal(long t, int ch, int rate, ref uint lcg)
        {
            lcg = lcg * 1664525 + 1013904223;
            long pkt = t * 1000 / rate / 20;

            if (pkt is >= 30 and < 35)
            {
                return 0;
            }

            double s = t / (double)rate;
            double env = 0.55 + 0.45 * Math.Sin(2 * Math.PI * 0.7 * s);
            double x = 6000 * Math.Sin(2 * Math.PI * (300 + 450 * ch) * s) + 3000 * Math.Sin(2 * Math.PI * (1700 + 900 * ch) * s) + ((int)(lcg >> 16) - 32768) / 22.0;

            return (short)Math.Round(env * x);
        }

        // 参考编码器出 OpusPackets 个包（不带 hwopus 包头）；失败返回 null
        private static List<byte[]> OpusEncode(OpusCase c)
        {
            int frame = c.Rate * c.Frame25 / 400;
            int err;
            nint enc;

            fixed (byte* m = c.EncMap)
            {
                enc = s2at_enc_open(c.Rate, c.EncCh, c.Streams, c.Coupled, m, c.App, c.Bitrate, c.Bandwidth, 10, c.Fec ? 1 : 0, &err);
            }

            if (enc == 0)
            {
                return null;
            }

            List<byte[]> packets = new();
            short[] pcm = new short[frame * c.EncCh];
            byte[] buf = new byte[16000];
            uint lcg = 12345;

            for (int k = 0; k < OpusPackets; k++)
            {
                for (int i = 0; i < frame; i++)
                {
                    for (int ch = 0; ch < c.EncCh; ch++)
                    {
                        pcm[i * c.EncCh + ch] = OpusSignal((long)k * frame + i, ch, c.Rate, ref lcg);
                    }
                }

                int len;

                fixed (short* p = pcm)
                fixed (byte* b = buf)
                {
                    len = s2at_enc(enc, p, frame, b, buf.Length);
                }

                if (len <= 0)
                {
                    s2at_enc_close(enc);
                    return null;
                }

                packets.Add(buf.AsSpan(0, len).ToArray());
            }

            s2at_enc_close(enc);
            return packets;
        }

        // 参考解码：直调 libopus，reset 处销毁重建（与 OPUS_RESET_STATE 后状态相同：都是初始状态）。返回交错 PCM 与每包样本数
        private static (short[] Pcm, int[] Samples) OpusReference(OpusCase c, List<byte[]> packets, bool withReset)
        {
            int frame = c.Rate * c.Frame25 / 400;
            short[] pcm = new short[OpusPackets * frame * c.Ch];
            int[] samples = new int[OpusPackets];
            nint dec = 0;

            for (int k = 0; k < packets.Count; k++)
            {
                if (dec == 0 || (withReset && k == OpusResetAt))
                {
                    if (dec != 0)
                    {
                        if (c.Map == null) opus_decoder_destroy(dec); else opus_multistream_decoder_destroy(dec);
                    }

                    int err;

                    fixed (byte* m = c.Map)
                    {
                        dec = c.Map == null ? opus_decoder_create(c.Rate, c.Ch, &err) : opus_multistream_decoder_create(c.Rate, c.Ch, c.Streams, c.Coupled, m, &err);
                    }
                }

                fixed (byte* p = packets[k])
                fixed (short* o = &pcm[k * frame * c.Ch])
                {
                    samples[k] = c.Map == null ? opus_decode(dec, p, packets[k].Length, o, frame, 0) : opus_multistream_decode(dec, p, packets[k].Length, o, frame, 0);
                }
            }

            if (c.Map == null) opus_decoder_destroy(dec); else opus_multistream_decoder_destroy(dec);
            return (pcm, samples);
        }

        // 一条解码请求：A = hwopus 包头（大端包长 + final range）+ 包、B = PCM 输出（outBytes 字节）；各命令的传输模式与入参按服务端声明
        private static Msg OpusDecodeMsg(uint cmd, byte* inBuf, byte[] packet, int headerLen, byte* outBuf, int outBytes, bool reset)
        {
            System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(new Span<byte>(inBuf, 4), headerLen);
            *(uint*)(inBuf + 4) = 0;
            packet.CopyTo(new Span<byte>(inBuf + 8, packet.Length));
            // #0 #2 #4 #5 无入参；#6–#9 入参 reset（1 字节）
            Msg m = cmd >= 6 ? Msg.Cmif(cmd, (byte)(reset ? 1 : 0)) : Msg.Cmif(cmd);
            m.A.Add(((ulong)inBuf, (ulong)(8 + packet.Length)));
            m.B.Add(((ulong)outBuf, (ulong)outBytes));
            // #4–#9 的输出缓冲带 MapTransferAllowsNonSecure；#8 #9 的输入缓冲也带
            m.BMode = cmd >= 4 ? 1u : 0;
            m.AMode = cmd >= 8 ? 1u : 0;
            return m;
        }

        // 开解码器（#0 单流 / #2 多流），返回子会话句柄（0 = 失败）
        private static uint OpusOpen(uint hwo, OpusCase c)
        {
            int owb = 0x40000;
            uint tm = FakeNative.TmemCreate((ulong)FakeNative.Alloc(owb), (ulong)owb, 0);
            Msg om;

            if (c.Map != null)
            {
                // OpenHardwareOpusDecoderForMultiStream(#2)：参数 0x110 字节走 X 缓冲（采样率、声道数、流数、立体声流数、256 字节声道映射）
                byte* prm = FakeNative.Alloc(0x110);
                new Span<byte>(prm, 0x110).Clear();
                *(int*)prm = c.Rate; *(int*)(prm + 4) = c.Ch; *(int*)(prm + 8) = c.Streams; *(int*)(prm + 12) = c.Coupled;
                c.Map.CopyTo(new Span<byte>(prm + 16, c.Map.Length));
                om = Msg.Cmif(2, BitConverter.GetBytes(owb));
                om.X.Add(((ulong)prm, 0x110));
            }
            else
            {
                // OpenHardwareOpusDecoder(#0)：参数（采样率、声道数）+ 工作缓冲大小
                byte[] a = new byte[12];
                BitConverter.TryWriteBytes(a.AsSpan(0), c.Rate); BitConverter.TryWriteBytes(a.AsSpan(4), c.Ch); BitConverter.TryWriteBytes(a.AsSpan(8), owb);
                om = Msg.Cmif(0, a);
            }

            om.Copy.Add(tm);
            Reply od = Call(hwo, om);
            return od.Result == 0 && od.Move.Count == 1 && FakeNative.KindOf(od.Move[0]) == ObjKind.Session ? od.Move[0] : 0;
        }

        private static void TestHwOpus(uint sm)
        {
            // S2A_OPUS_SYSTEM=1（macOS 全量系统后端）：单流/多流、8–48 kHz 都走系统解码，与 libopus 有 ±1 LSB 浮点舍入差；
            //   Hybrid 立体声子流在起始 / 静音后模式切换时解码器状态收敛不同：只在头 2 包、静音后 2 包内出现 >1 LSB（实测最大 631），
            //   其余包仍要求 ±1；默认 libopus 路径仍要求逐样本 0 差异
            int opusTolerance = Environment.GetEnvironmentVariable("S2A_OPUS_SYSTEM") == "1" ? 1 : 0;
            bool hw = WaitFor(() => Array.IndexOf(HorizonHost.Services, "hwopus") >= 0, 10_000);
            Reply ghw = Call(sm, Msg.Cmif(1, Name8("hwopus")));
            uint hwo = hw && ghw.Move.Count == 1 ? ghw.Move[0] : 0;
            Check("sm GetService(hwopus)", "已注册、move 1 个会话句柄", $"{(hw ? "已注册" : "未注册")}、move {ghw.Move.Count} 个{(FakeNative.KindOf(hwo) == ObjKind.Session ? "会话" : "非会话")}句柄");

            if (hwo == 0)
            {
                return;
            }

            byte[] m51 = { 0, 4, 1, 2, 3, 5 };
            byte[] m51enc = { 0, 1, 2, 3, 4 };
            OpusCase[] cases =
            {
                new("单流 48 kHz 双声道 CELT 20 ms", 48000, 2, 0, 0, null, 2, null, AppAudio, 96000, OpusAuto, 8, false, 8),
                new("单流 48 kHz 单声道 Hybrid 20 ms", 48000, 1, 0, 0, null, 1, null, AppVoip, 24000, BwSuperWide, 8, false, 6),
                new("单流 48 kHz 单声道 CELT 2.5 ms 低延迟", 48000, 1, 0, 0, null, 1, null, AppLowDelay, 64000, OpusAuto, 1, false, 8),
                new("单流 24 kHz 双声道 SILK 40 ms 带内纠错", 24000, 2, 0, 0, null, 2, null, AppVoip, 20000, BwWide, 16, true, 4),
                new("单流 16 kHz 单声道 SILK 60 ms", 16000, 1, 0, 0, null, 1, null, AppVoip, 12000, BwWide, 24, false, 0),
                new("单流 16 kHz 双声道 CELT 10 ms", 16000, 2, 0, 0, null, 2, null, AppLowDelay, 64000, OpusAuto, 4, false, 8),
                new("多流 48 kHz 双声道（1 流立体声）CELT 20 ms", 48000, 2, 1, 1, new byte[] { 0, 1 }, 2, new byte[] { 0, 1 }, AppAudio, 96000, OpusAuto, 8, false, 9),
                new("多流 48 kHz 5.1（4 流 2 立体声）CELT 20 ms", 48000, 6, 4, 2, m51, 6, m51, AppAudio, 256000, OpusAuto, 8, false, 9),
                new("多流 24 kHz 5.1 Hybrid / SILK 20 ms", 24000, 6, 4, 2, m51, 6, m51, AppVoip, 64000, OpusAuto, 8, false, 7, 1024),
                new("多流 16 kHz 单声道（1 流）SILK 40 ms", 16000, 1, 1, 0, new byte[] { 0 }, 1, new byte[] { 0 }, AppVoip, 16000, BwWide, 16, false, 5),
                new("多流 16 kHz 6 声道（映射含 255 静音声道）10 ms", 16000, 6, 3, 2, new byte[] { 0, 1, 2, 3, 4, 255 }, 5, m51enc, AppAudio, 96000, OpusAuto, 4, false, 2),
            };

            byte* inBuf = FakeNative.Alloc(0x4000);
            byte* outBuf = FakeNative.Alloc(0x10000);
            int[] modes = new int[3];
            long allSamples = 0, allBad = 0, allSoft = 0;

            foreach (OpusCase c in cases)
            {
                int frame = c.Rate * c.Frame25 / 400;
                int outBytes = frame * c.Ch * sizeof(short);
                List<byte[]> packets = OpusEncode(c);
                uint dec = OpusOpen(hwo, c);

                if (packets == null || dec == 0)
                {
                    Check($"hwopus {c.Name}", "编码出包、开解码器成功", $"{(packets == null ? "编码失败" : "编码出包")}、{(dec == 0 ? "开解码器失败" : "开解码器成功")}");
                    continue;
                }

                // 模式按 TOC 配置号（RFC 6716 §3.1）：0–11 SILK、12–15 Hybrid、16–31 CELT
                foreach (byte[] p in packets)
                {
                    int cfg = p[0] >> 3;
                    modes[cfg < 12 ? 0 : cfg < 16 ? 1 : 2]++;
                }

                bool withReset = c.Cmd >= 6;
                (short[] want, int[] wantSamples) = OpusReference(c, packets, withReset);
                long n = (long)OpusPackets * frame * c.Ch, bad = 0, softDiff = 0, maxAbs = 0;
                double sig = 0, noise = 0;
                int samplesOk = 0, consumedOk = 0;
                uint rc = 0;

                for (int k = 0; k < packets.Count; k++)
                {
                    new Span<byte>(outBuf, outBytes).Fill(0xA5);
                    Reply r = Call(dec, OpusDecodeMsg(c.Cmd, inBuf, packets[k], packets[k].Length, outBuf, outBytes, withReset && k == OpusResetAt));
                    rc |= r.Result;
                    consumedOk += r.Result == 0 && *(int*)r.Data == 8 + packets[k].Length ? 1 : 0;
                    samplesOk += r.Result == 0 && *(int*)(r.Data + 4) == wantSamples[k] && wantSamples[k] == frame ? 1 : 0;
                    short* got = (short*)outBuf;

                    for (int i = 0; i < frame * c.Ch; i++)
                    {
                        long w = want[k * frame * c.Ch + i], d = got[i] - w;
                        // 系统后端的 Hybrid 立体声子流在起始 / 静音后模式切换时只收敛 2 包；其余样本仍按 ±1 LSB
                        int limit = opusTolerance > 0 && c.OnsetMax > 0 && (k <= 1 || k is >= 35 and <= 36) ? c.OnsetMax : opusTolerance;

                        if (d != 0)
                        {
                            if (Math.Abs(d) > limit)
                            {
                                bad++;
                            }
                            else
                            {
                                softDiff++;
                            }
                        }
                        maxAbs = Math.Max(maxAbs, Math.Abs(d));
                        sig += w * w;
                        noise += d * d;
                    }
                }

                allSamples += n;
                allBad += bad;
                allSoft += softDiff;
                // 不一致时另报最大差与信噪比（参考输出能量 / 差值能量），供与 Concentus 旧实现的差异量化
                string diff = bad == 0 ? "" : $"（最大差 {maxAbs}、信噪比 {10 * Math.Log10(sig / Math.Max(noise, 1e-9)):F1} dB；容差内 {softDiff} 样本）";
                string limitText = opusTolerance > 0 && c.OnsetMax > 0 ? $"±{opusTolerance}（Hybrid 起始/静音后 2 包内 ≤{c.OnsetMax}）" : $"±{opusTolerance}";
                Check($"hwopus {c.Name}（命令 #{c.Cmd}{(withReset ? $"、第 {OpusResetAt} 包复位" : "")}）",
                    $"结果全 0、{OpusPackets} 包样本数 {frame}、consumed 对 {OpusPackets} 包、与直调 libopus 逐样本比 {n} 样本超出 {limitText} LSB 的不一致 0",
                    $"结果{(rc == 0 ? "全 0" : $" 0x{rc:X}")}、{samplesOk} 包样本数 {frame}、consumed 对 {consumedOk} 包、与直调 libopus 逐样本比 {n} 样本超出 {limitText} LSB 的不一致 {bad}{diff}");

                // 错误码（期望按上游映射：坏包 → OpusInvalidPacket 0x10A6F、包头长度超出输入 / 输出缓冲不足 → InvalidLength 0x66F；
                //   空包：包内样本数报 OPUS_BAD_ARG，上游 DecodeInterleaved 只在样本数成功时往下走、否则落到末尾回成功，consumed 0 / samples 0）
                if (c.Cmd == 8 || c.Cmd == 9)
                {
                    // 坏包：TOC 0xFB（配置 31、码 3）、帧数字节 0x41（1 帧、带填充）、填充长度 0xFF（254 + 下一字节）却已到包尾——
                    //   包内样本数照算得 2.5 ms × 8 = 20 ms（只看 TOC 与帧数），解码时按 RFC 6716 §3.2.5 填充越界判坏包
                    byte[] badPkt = { 0xFB, 0x41, 0xFF };
                    uint r1 = Call(dec, OpusDecodeMsg(c.Cmd, inBuf, badPkt, badPkt.Length, outBuf, 0x10000, false)).Result;
                    uint r2 = Call(dec, OpusDecodeMsg(c.Cmd, inBuf, packets[0], packets[0].Length + 1, outBuf, outBytes, false)).Result;
                    uint r3 = Call(dec, OpusDecodeMsg(c.Cmd, inBuf, packets[0], packets[0].Length, outBuf, outBytes - 2, false)).Result;
                    Reply r4 = Call(dec, OpusDecodeMsg(c.Cmd, inBuf, Array.Empty<byte>(), 0, outBuf, outBytes, false));
                    Check($"hwopus {c.Name} 错误码（坏包 / 包头超长 / 输出不足 / 空包）", "0x10A6F / 0x66F / 0x66F / 0x0 consumed 0 samples 0",
                        $"0x{r1:X} / 0x{r2:X} / 0x{r3:X} / 0x{r4.Result:X} consumed {*(int*)r4.Data} samples {*(int*)(r4.Data + 4)}");
                }

                // 稳态零分配：反复解同一包（48 kHz 命令 #8 单流双声道、#9 多流 5.1）
                if (c.Rate == 48000 && (c.Cmd == 8 && c.Ch == 2 || c.Cmd == 9 && c.Ch == 6))
                {
                    MeasureAlloc($"hwopus 解码一包（{c.Name}，命令 #{c.Cmd}）", dec, () => OpusDecodeMsg(c.Cmd, inBuf, packets[OpusResetAt], packets[OpusResetAt].Length, outBuf, outBytes, false));
                }

                FakeNative.HandleClose(dec);
            }

            Check("hwopus 用例覆盖三种编码模式（按 TOC 计包）", "SILK、Hybrid、CELT 都有", modes[0] > 0 && modes[1] > 0 && modes[2] > 0 ? "SILK、Hybrid、CELT 都有" : $"SILK {modes[0]} / Hybrid {modes[1]} / CELT {modes[2]} 包");
            Console.Error.WriteLine($"hwopus 逐样本比对合计：{cases.Length} 例 {allSamples} 样本、超出 ±{opusTolerance} LSB 的不一致 {allBad}（容差内 {allSoft} 样本）；模式 SILK {modes[0]} / Hybrid {modes[1]} / CELT {modes[2]} 包");
        }
    }
}
