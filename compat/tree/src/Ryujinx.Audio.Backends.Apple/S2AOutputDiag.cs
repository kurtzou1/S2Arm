using Ryujinx.Audio.Renderer.Dsp;
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Audio.Backends.Apple
{
    // S2Arm: output diagnostics for the CoreAudio sessions (device fed by DeviceBufferPump: buffers go out as soon as samples are queued).
    // - Always on, allocation-free on the audio threads: per-session counters, and every 10 s one "[声] …" line from a reporter thread:
    //   buffers handed back (callbacks), frames submitted / played, starvations (the device played its last buffer and the next one came
    //   later: that stretch is silence; < 1 s counts as 断供 = a gap in the middle of the stream, longer as 停流 = the stream paused),
    //   longest starvation, smallest in-flight after a hand-back, longest gap between hand-backs, plus the renderer's dropped periods
    //   (AudioProcessor skip) and worst period lateness.
    //   NOTE (10-21): 断供 counts hand-backs that left nothing in flight. AudioQueue takes everything queued at each device IO cycle,
    //   so with a producer one period ahead that is about once per IO cycle and says nothing about real gaps.
    //   Real gaps = 真缺口: since the session started the device plays rate frames per wall-clock second; whenever the frames submitted
    //   fall behind that, the device played silence for the difference (only the growth beyond the largest shortfall so far counts, so
    //   the constant output latency is not counted). 10-22: acnh on Mac / iPhone delivered 41.8–47.8 万 of 48 万 frames per 10 s, the
    //   shortfall matching the renderer's dropped periods × 240. (A processing tap on the queue output, tried 10-21, never sees this:
    //   it read 0 short cycles while half the frames were missing, so it was removed.)
    // - S2A_AUDIO_WAV=<path>: every byte submitted to CoreAudio is copied into a preallocated ring and written by a writer thread to
    //   <path>.<session>.wav (16-bit PCM header, sizes rewritten after each write so a crashed run still reads); every 真缺口 is
    //   written as that many frames of silence before the next buffer, so the file follows what the device played (holes = gaps,
    //   steps at their edges = pops). Beside it <path>.<session>.tsv: one line
    //   per hand-back (c: µs, frames, frames in flight after, GC count code, GC pause µs) and per submit (q: same columns).
    // Called by the pump under its lock (one writer at a time).
    internal sealed class S2AOutputDiag
    {
        // S2Arm (10-27 #495 音频恢复计时)：t_audio 的时钟。mach_absolute_time 与 native / gfx 侧的 clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        //   同一时基（都从开机起、不含睡眠），换算 ns = ticks * numer / denom（arm64 numer/denom = 125/3，x86_64 = 1/1）。
        //   这里输出 ms：t_audio_ms = ticks * numer / denom / 1e6（内部取到 µs，日志带三位小数）。取不到时基
        //   （非 Apple 平台 / 单测）就返回 0，打点自动跳过，行为不变。
        [DllImport("libc", EntryPoint = "mach_absolute_time")]
        private static extern ulong MachAbsoluteTime();

        [DllImport("libc", EntryPoint = "mach_timebase_info")]
        private static extern int MachTimebase(out MachTimebaseInfo info);

        [StructLayout(LayoutKind.Sequential)]
        private struct MachTimebaseInfo
        {
            public uint Numer;
            public uint Denom;
        }

        private static readonly double MsPerTick = InitMsPerTick();

        private static double InitMsPerTick()
        {
            try
            {
                if (MachTimebase(out MachTimebaseInfo tb) == 0 && tb.Numer != 0 && tb.Denom != 0)
                {
                    return (double)tb.Numer / tb.Denom / 1_000_000.0;
                }
            }
            catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException || e is BadImageFormatException)
            {
                // 非 Apple 平台（单测 / 别的宿主）：没有 mach 时钟，t_audio 不打
            }

            return 0;
        }

        /// <summary>
        /// Absolute now in µs on the mach_absolute_time clock (same source as the native side's CLOCK_UPTIME_RAW), 0 when unavailable.
        /// </summary>
        private static long MachUs() => MsPerTick > 0 ? (long)(MachAbsoluteTime() * MsPerTick * 1000.0) : 0;

        // S2Arm (10-25 开发浮层)：每 10 秒把本会话累计真缺口（ms）与本窗渲染丢周期交给宿主（runtime/src/hud.c）。没有宿主库（单测 / 别的宿主）就不报
        [System.Runtime.InteropServices.DllImport("s2a_native")] private static extern void s2a_hud_audio(int session, long gapMsTotal, long skipped);
        private static bool _hudGone;
        private static void HudAudio(int session, long gapMsTotal, long skipped)
        {
            if (_hudGone)
            {
                return;
            }

            try
            {
                s2a_hud_audio(session, gapMsTotal, skipped);
            }
            catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException)
            {
                _hudGone = true;
            }
        }

        private const int MaxSessions = 8;
        private static readonly S2AOutputDiag[] _all = new S2AOutputDiag[MaxSessions];
        private static int _nextIndex = -1;
        private static int _reporterStarted;
        private static long _repFreezeSeq;
        private static readonly string _wavBase = DocPath(Environment.GetEnvironmentVariable("S2A_AUDIO_WAV"));
        private readonly ManualResetEventSlim _closed = new(false);
        private Thread _writer;
        private int _disposed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            _started = false;
            lock (_all)
                for (int i = 0; i < _all.Length; i++)
                    if (ReferenceEquals(_all[i], this)) Volatile.Write(ref _all[i], null);
            _closed.Set();
            _writer?.Join();
            _closed.Dispose();
        }

        // A relative S2A_AUDIO_WAV lands in Documents, same rule as frames.tsv (graphics/metal/cs NxColdStart.Doc): S2A_DOCS if set,
        // else the app container's Documents on iOS (the process' working directory there is not writable: 10-22 a relative name
        // wrote nothing on the device) and the working directory on Mac
        private static string DocPath(string p)
        {
            if (string.IsNullOrEmpty(p) || Path.IsPathRooted(p))
            {
                return p;
            }

            string d = Environment.GetEnvironmentVariable("S2A_DOCS");

            if (string.IsNullOrEmpty(d))
            {
                d = OperatingSystem.IsIOS() ? Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) : Directory.GetCurrentDirectory();
            }

            return Path.Combine(d, p);
        }

        public readonly int Index;
        private readonly int _bytesPerFrame;
        private readonly int _channels;
        private readonly int _rate;
        private readonly int _bitsPerSample;

        private long _callbacks;
        private long _framesSubmitted;
        private long _framesPlayed;
        private long _underruns;
        private long _pauses;
        private long _maxStarveTicks;
        private long _minInFlight = long.MaxValue;
        private long _maxGapTicks;
        // S2Arm (11-03 太鼓 iPhone 断续): 交还迟到 = 两次交还相隔超过一拉（放回提前量）+ 5 ms：设备照网格拉，回调却晚送到。真缺口按「已交 vs 墙钟」
        //   只数超过开局最大落后量的增长，开局 300 ms 落后之后每秒一次 40–55 ms 的断口一次都不数（11-03 测试设备1 太鼓：真缺口 0、录屏每秒断 55 ms），
        //   这里直接数回调晚到；次数和最晚超出一拉多少 ms 进 10 秒行
        private long _lateBursts, _repLateBursts, _maxLateOverTicks;
        // S2Arm (10-25 数码宝贝 Mac 欠载)：设备交还时机。提交时按「已在途 + 本块」连续播放推出本块应播完的时刻，压进定长环（设备按提交顺序交还）；
        //   交还时弹出，记「实际交还 − 应播完」= 设备输出延迟（交还比真正播完晚多少）。游戏按释放补数：这段延迟越长，游戏越晚拿到空缓冲
        private const int LatRing = 128;
        private readonly long[] _latDue = new long[LatRing];
        private int _latW, _latR;
        private long _latMin = long.MaxValue, _latMax, _latSum, _latN;
        private long _lastCallbackTicks;
        // S2Arm (10-27 #495 音频恢复计时)：空档（回调间隔 ≥ GapMs）之后第一笔成功回调的绝对时刻（mach µs，日志按 ms 打）与该次空档长度（ticks）。
        //   只在恢复时写一次，由 reporter 线程打一行后清 seq（不每 10 秒刷）；回调线程只写字段，不分配、不做 IO。
        private const int GapMs = 500;
        private static readonly long GapTicks = GapMs * Stopwatch.Frequency / 1000;
        private long _recoverUs, _recoverGapTicks;
        private int _recoverSeq, _repRecoverSeq;
        // Hand-back that left nothing in flight (0: not starving)
        private long _starveSince;
        private bool _started;
        // 真缺口: wall clock and submitted frames at the first submit after start, largest shortfall so far, gap frames total
        private long _clockStart, _clockFrames, _maxShort, _gapFrames, _repGapFrames;

        // Reporter's snapshot of the previous line (deltas per 10 s)
        private long _repCallbacks, _repSubmitted, _repPlayed, _repUnderruns, _repPauses;
        // 欠载补垫（DeviceBufferPump.OnCushion，游戏线程上调）：只做原子记数，10 秒汇报时打一行
        private int _cushions, _repCushions, _lastCushionFrames;
        private long _lastCushionZeroTicks, _lastCushionLate;
        // S2Arm (11-02): 放回提前量（PlaybackCredit：交还之外再提前算作已播的帧数，= 实测设备一次拉取），回调线程写、汇报线程读
        private long _leadFrames;
        public void SetLead(long frames) => Volatile.Write(ref _leadFrames, frames);
        public void OnCushion(int frames, long zeroTicks, long lateFrames)
        {
            Volatile.Write(ref _lastCushionFrames, frames);
            Volatile.Write(ref _lastCushionZeroTicks, zeroTicks);
            Volatile.Write(ref _lastCushionLate, lateFrames);
            Interlocked.Increment(ref _cushions);
        }

        // WAV ring: written under the pump lock, drained by the writer thread
        private readonly byte[] _ring;
        private long _ringWritten;
        private long _ringRead;
        private long _ringDropped;

        private struct Ev { public long T; public int A; public int B; public int G; public long P; }
        private const int EvCap = 1 << 16;
        private readonly Ev[] _cbEv;
        private readonly Ev[] _enqEv;
        private long _cbEvW, _cbEvR, _enqEvW, _enqEvR;

        private S2AOutputDiag(int index, int bytesPerFrame, int channels, int rate, int bitsPerSample)
        {
            Index = index;
            _bytesPerFrame = bytesPerFrame;
            _channels = channels;
            _rate = rate;
            _bitsPerSample = bitsPerSample;

            if (!string.IsNullOrEmpty(_wavBase))
            {
                // 4 s of audio
                _ring = new byte[bytesPerFrame * rate * 4];
                _cbEv = new Ev[EvCap];
                _enqEv = new Ev[EvCap];
                _writer = new Thread(WriterLoop) { IsBackground = true, Name = $"S2A.AudioWav.{index}" };
                _writer.Start();
            }
        }

        public static S2AOutputDiag Create(int bytesPerFrame, int channels, int rate, int bitsPerSample)
        {
            int index = Interlocked.Increment(ref _nextIndex);
            S2AOutputDiag d = new(index, bytesPerFrame, channels, rate, bitsPerSample);

            lock (_all)
            {
                for (int slot = 0; slot < MaxSessions; slot++)
                    if (_all[slot] == null)
                    {
                        Volatile.Write(ref _all[slot], d);
                        break;
                    }
            }

            // S2Arm 11-07: player builds (S2A_DEV_FACILITIES=0, exported by the native host from Info.plist S2ADevFacilities) do not start the 10 s reporter thread
            if (Environment.GetEnvironmentVariable("S2A_DEV_FACILITIES") != "0" && Interlocked.Exchange(ref _reporterStarted, 1) == 0)
            {
                new Thread(ReporterLoop) { IsBackground = true, Name = "S2A.AudioDiag" }.Start();
            }

            Console.Error.WriteLine($"[声] 输出会话 #{index}：{channels} 声道 {rate} Hz {bitsPerSample} 位{(_wavBase != null ? $"，写 {_wavBase}.{index}.wav" : "")}");

            return d;
        }

        public void SetStarted(bool started)
        {
            _started = started;
            _starveSince = 0;
            _clockStart = 0;
            _maxShort = 0;
        }

        /// <summary>
        /// A buffer of <paramref name="data"/> was submitted; <paramref name="inFlightBefore"/> bytes were in flight before it.
        /// </summary>
        public void OnSubmit(ReadOnlySpan<byte> data, long inFlightBefore)
        {
            long now = Stopwatch.GetTimestamp();
            int frames = data.Length / _bytesPerFrame;

            if (_started && inFlightBefore == 0 && _starveSince != 0)
            {
                long starved = now - _starveSince;

                if (starved < Stopwatch.Frequency)
                {
                    _underruns++;

                    if (starved > _maxStarveTicks)
                    {
                        _maxStarveTicks = starved;
                    }
                }
                else
                {
                    _pauses++;
                }
            }

            _starveSince = 0;

            if (_started)
            {
                if (_clockStart == 0)
                {
                    _clockStart = now;
                    _clockFrames = _framesSubmitted;
                }
                else
                {
                    long shortfall = (now - _clockStart) * _rate / Stopwatch.Frequency - (_framesSubmitted - _clockFrames);

                    if (shortfall > _maxShort)
                    {
                        _gapFrames += shortfall - _maxShort;

                        if (_ring != null)
                        {
                            WriteSilence((int)(shortfall - _maxShort));
                        }

                        _maxShort = shortfall;
                    }
                }
            }

            _framesSubmitted += frames;

            if (_latW - _latR < LatRing)
            {
                _latDue[_latW++ % LatRing] = now + (inFlightBefore + data.Length) / _bytesPerFrame * Stopwatch.Frequency / _rate;
            }

            if (_ring != null)
            {
                WriteRing(data);
                PutEv(_enqEv, ref _enqEvW, Volatile.Read(ref _enqEvR), now, frames, (int)((inFlightBefore + data.Length) / _bytesPerFrame));
            }
        }

        /// <summary>
        /// The device handed back a buffer of <paramref name="bytes"/>; <paramref name="inFlightAfter"/> bytes are still in flight.
        /// </summary>
        public void OnReturned(int bytes, long inFlightAfter)
        {
            long now = Stopwatch.GetTimestamp();

            long gapTicks = _lastCallbackTicks == 0 ? 0 : now - _lastCallbackTicks;

            if (gapTicks > _maxGapTicks)
            {
                _maxGapTicks = gapTicks;
            }

            long lead = Volatile.Read(ref _leadFrames);

            if (lead > 0 && gapTicks > 0)
            {
                long over = gapTicks - (lead * Stopwatch.Frequency / _rate + Stopwatch.Frequency / 200);

                if (over > 0)
                {
                    _lateBursts++;
                    _maxLateOverTicks = Math.Max(_maxLateOverTicks, over + Stopwatch.Frequency / 200);
                }
            }

            if (gapTicks >= GapTicks)
            {
                // S2Arm (10-27 #495 音频恢复计时)：这一段静了 ≥ GapMs，本笔回调 = 设备重新出声的瞬间。记绝对时刻供与
                //   回前台 / 首帧等 native 打点对齐（同一时钟基准），空档长度一并留下，免得靠 10 秒窗口里的最大间隔反推
                Volatile.Write(ref _recoverGapTicks, gapTicks);
                Volatile.Write(ref _recoverUs, MachUs());
                Interlocked.Increment(ref _recoverSeq);
            }

            _lastCallbackTicks = now;
            _callbacks++;

            if (bytes > 0 && _latR < _latW)
            {
                long late = now - _latDue[_latR++ % LatRing];

                if (late < _latMin) _latMin = late;
                if (late > _latMax) _latMax = late;
                _latSum += late;
                _latN++;
            }
            _framesPlayed += bytes / _bytesPerFrame;

            if (_started && bytes > 0)
            {
                // S2Arm (10-22 杂音): 最少在途含 0——原先只记非零的最小值，在途每个游戏缓冲归零一次（输出端欠载）被漏掉，
                // 「最少在途 240」是假象（见 10-22 acnh/mk8d 掐边喂）。判据要靠它看在途下限，必须把归零算进去。
                long framesAfter = inFlightAfter / _bytesPerFrame;

                if (framesAfter < _minInFlight)
                {
                    _minInFlight = framesAfter;
                }

                if (inFlightAfter == 0)
                {
                    _starveSince = now;
                }
            }

            if (_ring != null)
            {
                PutEv(_cbEv, ref _cbEvW, Volatile.Read(ref _cbEvR), now, bytes / _bytesPerFrame, (int)(inFlightAfter / _bytesPerFrame));
            }
        }

        private void WriteSilence(int frames)
        {
            Span<byte> zero = stackalloc byte[4096];
            zero.Clear();
            long bytes = (long)frames * _bytesPerFrame;
            int chunk = zero.Length / _bytesPerFrame * _bytesPerFrame;

            while (bytes > 0)
            {
                int n = (int)Math.Min(bytes, chunk);
                WriteRing(zero[..n]);
                bytes -= n;
            }
        }

        private static void PutEv(Ev[] ring, ref long w, long r, long t, int a, int b)
        {
            if (w - r >= ring.Length)
            {
                return;
            }

            ring[w % ring.Length] = new Ev { T = t, A = a, B = b, G = GC.CollectionCount(0) + GC.CollectionCount(1) * 1000 + GC.CollectionCount(2) * 1000000, P = (long)GC.GetTotalPauseDuration().TotalMicroseconds };
            Volatile.Write(ref w, w + 1);
        }

        private static void DrainEv(StreamWriter tw, Ev[] ring, ref long r, long w, char kind)
        {
            for (; r < w; r++)
            {
                Ev e = ring[r % ring.Length];
                tw.Write(kind); tw.Write('\t'); tw.Write(e.T * 1_000_000 / Stopwatch.Frequency); tw.Write('\t'); tw.Write(e.A); tw.Write('\t'); tw.Write(e.B); tw.Write('\t'); tw.Write(e.G); tw.Write('\t'); tw.WriteLine(e.P);
            }
        }

        private void WriteRing(ReadOnlySpan<byte> data)
        {
            long written = _ringWritten;
            long free = _ring.Length - (written - Volatile.Read(ref _ringRead));

            if (data.Length > free)
            {
                _ringDropped += data.Length;
                return;
            }

            int pos = (int)(written % _ring.Length);
            int first = Math.Min(data.Length, _ring.Length - pos);

            data[..first].CopyTo(_ring.AsSpan(pos));
            data[first..].CopyTo(_ring.AsSpan(0));

            Volatile.Write(ref _ringWritten, written + data.Length);
        }

        private void WriterLoop()
        {
            string path = $"{_wavBase}.{Index}.wav";

            try
            {
                using FileStream fs = new(path, FileMode.Create, FileAccess.Write, FileShare.Read);
                using StreamWriter tw = new($"{_wavBase}.{Index}.tsv");

                WriteHeader(fs, 0);

                long dataBytes = 0;

                while (true)
                {
                    bool closing = _closed.Wait(100);

                    long er = _cbEvR; DrainEv(tw, _cbEv, ref er, Volatile.Read(ref _cbEvW), 'c'); Volatile.Write(ref _cbEvR, er);
                    er = _enqEvR; DrainEv(tw, _enqEv, ref er, Volatile.Read(ref _enqEvW), 'q'); Volatile.Write(ref _enqEvR, er);
                    tw.Flush();

                    long written = Volatile.Read(ref _ringWritten);
                    long read = _ringRead;

                    if (written == read)
                    {
                        if (closing) break;
                        continue;
                    }

                    while (read < written)
                    {
                        int pos = (int)(read % _ring.Length);
                        int n = (int)Math.Min(written - read, _ring.Length - pos);

                        fs.Write(_ring, pos, n);
                        read += n;
                    }

                    dataBytes += written - _ringRead;
                    Volatile.Write(ref _ringRead, read);

                    fs.Seek(0, SeekOrigin.Begin);
                    WriteHeader(fs, dataBytes);
                    fs.Seek(0, SeekOrigin.End);
                    fs.Flush();
                    if (closing) break;
                }
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[声] 【红】写 {path} 失败：{e.Message}");
            }
        }

        private void WriteHeader(Stream s, long dataBytes)
        {
            Span<byte> h = stackalloc byte[44];
            uint data = (uint)Math.Min(dataBytes, uint.MaxValue - 36);
            int blockAlign = _channels * _bitsPerSample / 8;

            "RIFF"u8.CopyTo(h);
            BitConverter.TryWriteBytes(h[4..], 36 + data);
            "WAVEfmt "u8.CopyTo(h[8..]);
            BitConverter.TryWriteBytes(h[16..], 16);
            BitConverter.TryWriteBytes(h[20..], (ushort)(_bitsPerSample == 32 ? 3 : 1));
            BitConverter.TryWriteBytes(h[22..], (ushort)_channels);
            BitConverter.TryWriteBytes(h[24..], _rate);
            BitConverter.TryWriteBytes(h[28..], _rate * blockAlign);
            BitConverter.TryWriteBytes(h[32..], (ushort)blockAlign);
            BitConverter.TryWriteBytes(h[34..], (ushort)_bitsPerSample);
            "data"u8.CopyTo(h[36..]);
            BitConverter.TryWriteBytes(h[40..], data);

            s.Write(h);
        }


        private static void ReporterLoop()
        {
            while (true)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("声音诊断"); // S2Arm: per-thread allocation accounting
                Thread.Sleep(10_000);

                // S2Arm (11-13 失焦误报): frozen now, or frozen at any time in this window: the renderer was paused on purpose
                long freezeSeq = Interlocked.Read(ref Ryujinx.Audio.Integration.S2AGuestFreeze.Seq);
                bool frozenWindow = Ryujinx.Audio.Integration.S2AGuestFreeze.Frozen != 0 || freezeSeq != _repFreezeSeq;
                _repFreezeSeq = freezeSeq;

                long skipped = Interlocked.Exchange(ref AudioProcessor.S2ASkippedPeriods, 0);
                long lateNs = Interlocked.Exchange(ref AudioProcessor.S2AMaxLateNs, 0);
                HudAudio(-1, 0, skipped);   // 渲染丢周期是整个渲染器的，不分会话：单报一次

                for (int i = 0; i < MaxSessions; i++)
                {
                    S2AOutputDiag d = Volatile.Read(ref _all[i]);

                    if (d == null)
                    {
                        continue;
                    }

                    long cb = d._callbacks, sub = d._framesSubmitted, pl = d._framesPlayed, und = d._underruns, pau = d._pauses, gap = d._gapFrames;

                    // S2Arm (10-27 #495)：空档恢复只打一次（seq 变了才打），不等聚合行、也不会每 10 秒重复。
                    //   值本身是恢复瞬间的时刻，与打点延迟无关：按 t_audio 与 native 打点对齐，不是按日志出现顺序
                    int rs = Volatile.Read(ref d._recoverSeq);

                    if (rs != d._repRecoverSeq)
                    {
                        d._repRecoverSeq = rs;
                        long ru = Volatile.Read(ref d._recoverUs);

                        if (ru > 0)
                        {
                            Console.Error.WriteLine($"[声] 输出 #{d.Index} 恢复：t_audio={ru / 1000.0:F3} ms，空档 {Volatile.Read(ref d._recoverGapTicks) * 1000.0 / Stopwatch.Frequency:F0} ms（空档后首次成功回调；mach_absolute_time 基准 = native CLOCK_UPTIME_RAW）");
                        }
                    }

                    if (cb == d._repCallbacks && sub == d._repSubmitted)
                    {
                        // S2Arm (10-23): 播过声、开着播，却 10 秒零回调零交设备 = 设备停了 / 没声音。之前这里直接跳过，「完全没声」在日志里一行都不留。
                        //   只对播过声的会话报（cb > 0）：游戏开着却从没送过声音的会话（动森 #1）不算
                        if (d._started && cb > 0 && frozenWindow)
                        {
                            Console.Error.WriteLine($"[声] 输出 #{d.Index} 10 秒：客机冻结中（失焦 / 后台，渲染按设计暂停），回调 0 次不算停播");
                        }
                        else if (d._started && cb > 0)
                        {
                            Console.Error.WriteLine($"[声] 【红】输出 #{d.Index} 10 秒：播过声、开着播，这 10 秒回调 0 次、交设备 0 帧（设备停了或游戏不再送声音）");
                        }

                        continue;
                    }

                    long minInFlight = d._minInFlight;
                    double maxStarveMs = d._maxStarveTicks * 1000.0 / Stopwatch.Frequency;
                    double maxGapMs = d._maxGapTicks * 1000.0 / Stopwatch.Frequency;

                    d._maxStarveTicks = 0;
                    d._minInFlight = long.MaxValue;
                    d._maxGapTicks = 0;
                    long lb = d._lateBursts;
                    double lateOverMs = d._maxLateOverTicks * 1000.0 / Stopwatch.Frequency;
                    d._maxLateOverTicks = 0;
                    double tf = 1000.0 / Stopwatch.Frequency;
                    string lat = d._latN > 0 ? $"；交还相对连续播完 最少 {d._latMin * tf:F1} / 平均 {d._latSum * tf / d._latN:F1} / 最多 {d._latMax * tf:F1} ms（负 = 提前）" : "";
                    d._latMin = long.MaxValue; d._latMax = 0; d._latSum = 0; d._latN = 0;

                    Console.Error.WriteLine(
                        $"[声] 输出 #{d.Index} 10 秒：回调 {cb - d._repCallbacks} 次，交设备 {sub - d._repSubmitted} 帧、播完 {pl - d._repPlayed} 帧，" +
                        $"账上在途归零 {und - d._repUnderruns} 次（最长 {maxStarveMs:F1} ms；设备交还早于播完，归零时设备内部仍有缓冲，断音看真缺口与交还迟到）、停流 {pau - d._repPauses} 次，回调后最少在途 {(minInFlight == long.MaxValue ? -1 : minInFlight)} 帧，" +
                        $"回调最长间隔 {maxGapMs:F1} ms；渲染丢周期 {skipped}、周期最晚 {lateNs / 1e6:F1} ms；真缺口 {gap - d._repGapFrames} 帧（{(gap - d._repGapFrames) * 1000.0 / d._rate:F1} ms）；放回提前量 {Volatile.Read(ref d._leadFrames)} 帧；交还迟到 {lb - d._repLateBursts} 次（最多比一拉晚 {lateOverMs:F1} ms）{lat}{(d._ring != null ? $"；wav 丢 {d._ringDropped} B" : "")}");

                    HudAudio(d.Index, gap * 1000 / d._rate, 0);

                    int cu = Volatile.Read(ref d._cushions);
                    if (cu != d._repCushions)
                    {
                        Console.Error.WriteLine($"[声] 输出 #{d.Index} 10 秒：中途欠载补垫 {cu - d._repCushions} 次（最近一次在途归零 {Volatile.Read(ref d._lastCushionZeroTicks) * 1000.0 / Stopwatch.Frequency:F1} ms 后才有新数据、设备播放时钟已越过已交声音末尾 {Volatile.Read(ref d._lastCushionLate) * 1000.0 / d._rate:F1} ms，先补 {Volatile.Read(ref d._lastCushionFrames) * 1000.0 / d._rate:F0} ms 静音重建缓冲垫）");
                        d._repCushions = cu;
                    }

                    d._repCallbacks = cb;
                    d._repSubmitted = sub;
                    d._repPlayed = pl;
                    d._repUnderruns = und;
                    d._repPauses = pau;
                    d._repGapFrames = gap;
                    d._repLateBursts = lb;
                }
            }
        }
    }
}
